using Base64
using Printf: @sprintf

# Decode percent-escapes into raw bytes. Decoding into a String of per-byte
# `Char`s (the old approach) corrupts multi-byte UTF-8 sequences in SVG text;
# emitting the bytes preserves the original UTF-8 exactly.
function _urldecode_bytes(s::AbstractString)
	out = UInt8[]
	i = firstindex(s)
	stop = lastindex(s)
	while i <= stop
		c = s[i]
		if c == '%' && i + 2 <= stop
			push!(out, parse(UInt8, s[(i+1):(i+2)]; base = 16))
			i += 3
		else
			append!(out, codeunits(string(c)))
			i = nextind(s, i)
		end
	end
	return out
end

"""
	make_subplots(; kwargs...)

PlotlyJS-style subplot constructor. Forwards `kwargs` to `PlotlyBase.Subplots`
(e.g. `rows`, `cols`, `shared_xaxes`, `specs`, `column_widths`) and returns a
`Plot` with the package default template and Cartesian axis styling applied.
For the MATLAB-like helper that returns a mutable canvas, see [`subplots`](@ref).
"""
function make_subplots(; kwargs...)
	fig = plot(Layout(Subplots(; kwargs...)))
	p = _plot_obj(fig)
	_apply_default_template!(p)
	_apply_default_cartesian_axes!(p)
	_refresh!(fig)
	return fig
end

"""
	mgrid(arrays...)

Build broadcasted coordinate grids from 1-D `arrays`, NumPy `mgrid`-style. For
inputs of lengths `(n₁, n₂, …)` returns a vector of arrays each of shape
`(n₁, n₂, …)`, where the `i`-th output varies along its `i`-th dimension. The
element type of each input is preserved.

```julia
X, Y = mgrid(1:3, 1:2)   # X[i,j] = i, Y[i,j] = j
```
"""
function mgrid(arrays...)
	lengths = collect(length.(arrays))
	ones_vec = ones(Int, length(arrays))
	grids = map(eachindex(arrays)) do i
		repeats = copy(lengths)
		repeats[i] = 1

		shape = copy(ones_vec)
		shape[i] = lengths[i]
		# `repeat(...; outer)` preserves the element type (the old `.* ones(...)`
		# trick force-promoted integer inputs to Float64 and yielded Vector{Any}).
		repeat(reshape(collect(arrays[i]), shape...); outer = repeats)
	end
	return collect(grids)
end

function _savefig_html(io::IO, p::Plot)
	show(
		io,
		MIME("text/html"),
		p;
		include_mathjax = "cdn",
		include_plotlyjs = "cdn",
		full_html = true,
	)
	return nothing
end

const _EXPORT_KW = Set((:height, :width, :scale))

function _export_image(io::IO, ec, win, divid::String, p::Plot, fmt::String; kwargs...)
	for k in keys(kwargs)
		k in _EXPORT_KW || error("Unsupported keyword argument: $k. Supported: height, width, scale.")
	end
	height = get(kwargs, :height, 500)
	width = get(kwargs, :width, 700)
	scale = get(kwargs, :scale, 1)

	data_js = _json_js(p.data)
	layout_js = _json_js(p.layout)
	config_js = _json_js(p.config)
	divid_js = _json_js(divid)

	js = """
(async function() {
  const div = document.getElementById($divid_js);
  await Plotly.react(div, $data_js, $layout_js, $config_js);
  const url = await Plotly.toImage(div, {format: "$fmt", width: $width, height: $height, scale: $scale});
  return url;
})();
"""
	data_url = Base.invokelatest(() -> ec.run(win, js))

	if fmt == "svg"
		# SVG returns data:image/svg+xml,<url-encoded-svg>
		prefix = "data:image/svg+xml,"
		if startswith(data_url, prefix)
			write(io, _urldecode_bytes(data_url[length(prefix)+1:end]))
		else
			# Fallback: might be base64 encoded
			prefix_b64 = "data:image/svg+xml;base64,"
			if startswith(data_url, prefix_b64)
				write(io, base64decode(data_url[length(prefix_b64)+1:end]))
			else
				write(io, data_url)
			end
		end
	else
		# PNG/JPEG/WebP return data:<mime>;base64,<data>
		idx = findfirst(";base64,", data_url)
		if idx !== nothing
			b64_start = last(idx) + 1
			write(io, base64decode(data_url[b64_start:end]))
		else
			error("Unexpected data URL format from Plotly.toImage for format '$fmt'")
		end
	end
	return nothing
end

function _export_pdf(io::IO, ec, win, divid::String, p::Plot; kwargs...)
	for k in keys(kwargs)
		k in _EXPORT_KW || error("Unsupported keyword argument: $k. Supported: height, width, scale.")
	end
	height = get(kwargs, :height, 500)
	width = get(kwargs, :width, 700)
	scale = get(kwargs, :scale, 1)

	data_js = _json_js(p.data)
	layout_js = _json_js(p.layout)
	config_js = _json_js(p.config)
	divid_js = _json_js(divid)

	# Render the plot at the scaled dimensions so it fills the (scaled) PDF page
	# — otherwise `scale>1` enlarges the page but not the plot, leaving blank space.
	js_render = """
(async function() {
  var div = document.getElementById($divid_js);
  var layout = Object.assign({}, $layout_js, {width: $(width * scale), height: $(height * scale)});
  await Plotly.react(div, $data_js, layout, $config_js);
  if (!document.getElementById('__ps_print_css')) {
    var style = document.createElement('style');
    style.id = '__ps_print_css';
    style.textContent = '@page { margin: 0 !important; } @media print { html, body { margin: 0 !important; padding: 0 !important; } }';
    document.head.appendChild(style);
  }
  return 'ok';
})();
"""
	Base.invokelatest(() -> ec.run(win, js_render))

	# Use Electron's printToPDF for vector output with selectable text.
	# printToPDF is an async main-process API, so we write to a temp file
	# and poll for completion.
	app = Base.invokelatest(() -> getfield(win, :app))
	win_id = Base.invokelatest(() -> getfield(win, :id))
	tmpfile = tempname() * ".pdf"
	tmpfile_js = _json_js(tmpfile)

	# Page size in inches (Electron printToPDF pageSize uses inches)
	page_w_in = @sprintf("%.6f", width * scale / 96.0)
	page_h_in = @sprintf("%.6f", height * scale / 96.0)

	js_pdf = """
	global.__ps_pdf_done = false;
	global.__ps_pdf_err = null;
	require('electron').BrowserWindow.fromId($win_id)
		.webContents.printToPDF({
			printBackground: true,
			preferCSSPageSize: true,
			margins: { marginType: 'custom', top: 0, bottom: 0, left: 0, right: 0 },
			pageSize: { width: $page_w_in, height: $page_h_in }
		})
		.then(function(buf) {
			require('fs').writeFileSync($tmpfile_js, buf);
			global.__ps_pdf_done = true;
		})
		.catch(function(err) {
			global.__ps_pdf_err = err.toString();
			global.__ps_pdf_done = true;
		});
	'started'
	"""
	Base.invokelatest(() -> ec.run(app, js_pdf))

	# Poll for completion (up to 15 seconds)
	for _ in 1:300
		done = Base.invokelatest(() -> ec.run(app, "global.__ps_pdf_done"))
		done === true && break
		sleep(0.05)
	end

	err = Base.invokelatest(() -> ec.run(app, "global.__ps_pdf_err"))
	if err !== nothing && err !== false && err != ""
		rm(tmpfile; force = true)
		error("printToPDF failed: $err")
	end

	if !isfile(tmpfile)
		error("printToPDF timed out or failed to write PDF")
	end

	pdf_data = read(tmpfile)
	rm(tmpfile; force = true)
	write(io, pdf_data)
	return nothing
end

"""
	savefig(filename, fig; format=nothing, kwargs...)
	savefig(fig, filename; kwargs...)
	savefig(io::IO, fig; format="png", kwargs...)
	savefig(fig; format="png", kwargs...) -> Vector{UInt8}

Export a `Plot`, `SyncPlot`, or `SubplotFigure` to a file, stream, or byte
vector. When a `filename` is given and `format` is `nothing`, the format is
inferred from the extension (defaulting to `png`).

Supported formats: `"png"`, `"jpeg"`, `"svg"`, `"pdf"`, `"html"`, `"json"`.
`html` and `json` are produced in-process and need no external dependency;
`png`/`jpeg`/`svg`/`pdf` are rendered through PlotlySupply's internal Electron
export window (so they require a working Electron, but no Kaleido/Python).

# Keyword Arguments
- `format`: Override the output format (otherwise inferred from the extension).
- `width`, `height`: Image size in pixels (raster/SVG/PDF; default `700`×`500`).
- `scale`: Resolution multiplier for raster output / page-size multiplier for PDF.
"""
function savefig(io::IO, p::Plot; format::AbstractString = "png", kwargs...)
	fmt = lowercase(String(format))
	fmt == "html" && return _savefig_html(io, p)
	fmt == "json" && return (PlotlyBase.JSON.print(io, p); nothing)
	fmt == "eps" && error("EPS export is not supported. Use \"svg\" or \"pdf\" instead.")

	ec, app, win, divid = _ensure_export_window()
	if fmt == "pdf"
		_export_pdf(io, ec, win, divid, p; kwargs...)
	else
		_export_image(io, ec, win, divid, p, fmt; kwargs...)
	end
	return nothing
end

savefig(io::IO, sp::SyncPlot; kwargs...) = savefig(io, sp.plot; kwargs...)

function savefig(p::Union{Plot, SyncPlot}; kwargs...)
	io = IOBuffer()
	savefig(io, p; kwargs...)
	return take!(io)
end

function savefig(
	filename::AbstractString,
	p::Union{Plot, SyncPlot};
	format::Union{Nothing, AbstractString} = nothing,
	kwargs...,
)
	ext = lowercase(splitext(filename)[2])
	fmt = isnothing(format) ? (isempty(ext) ? "png" : lstrip(ext, '.')) : lowercase(String(format))

	open(filename, "w") do io
		savefig(io, p; format = fmt, kwargs...)
	end
	return filename
end

savefig(p::Union{Plot, SyncPlot}, filename::AbstractString; kwargs...) =
	savefig(filename, p; kwargs...)

PlotlyBase.savejson(sp::SyncPlot, fn::String) = PlotlyBase.savejson(sp.plot, fn)
PlotlyBase.trace_map(sp::SyncPlot, axis) = PlotlyBase.trace_map(sp.plot, axis)
PlotlyBase._is3d(sp::SyncPlot) = PlotlyBase._is3d(sp.plot)

Base.size(sp::SyncPlot) = size(sp.plot)

function PlotlyBase.add_trace!(sp::SyncPlot, trace::GenericTrace; kw...)
	PlotlyBase.add_trace!(sp.plot, trace; kw...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.redraw!(sp::SyncPlot)
	PlotlyBase.redraw!(sp.plot)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.purge!(sp::SyncPlot)
	PlotlyBase.purge!(sp.plot)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

PlotlyBase.to_image(sp::SyncPlot; kwargs...) = PlotlyBase.to_image(sp.plot; kwargs...)
PlotlyBase.download_image(sp::SyncPlot; kwargs...) = PlotlyBase.download_image(sp.plot; kwargs...)

function _clone_syncplot(sp::SyncPlot)
	return to_syncplot(deepcopy(sp.plot); app = sp.app)
end

for f in (
	:restyle,
	:relayout,
	:update,
	:addtraces,
	:deletetraces,
	:movetraces,
	:extendtraces,
	:prependtraces,
	:react,
)
	f_bang = Symbol(f, "!")
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; kwargs...)
		out = _clone_syncplot(sp)
		PlotlyBase.$f_bang(out, args...; kwargs...)
		return out
	end
end

const _SYNCPLOT_DEFINED_LAYOUT_UPDATERS = Set((:update_xaxes!, :update_yaxes!, :update_polars!))

for (f, _) in vcat(PlotlyBase._layout_obj_updaters, PlotlyBase._layout_vector_updaters)
	f in _SYNCPLOT_DEFINED_LAYOUT_UPDATERS && continue
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; kwargs...)
		PlotlyBase.$f(sp.plot, args...; kwargs...)
		_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
		return sp
	end
end

for f in (:add_hrect!, :add_hline!, :add_vrect!, :add_vline!, :add_shape!, :add_layout_image!)
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; kwargs...)
		PlotlyBase.$f(sp.plot, args...; kwargs...)
		_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
		return sp
	end
end

function PlotlyBase.add_recession_bands!(sp::SyncPlot; kwargs...)
	new_shapes = PlotlyBase.add_recession_bands!(sp.plot; kwargs...)
	PlotlyBase.relayout!(sp, shapes = new_shapes)
	return new_shapes
end

function _syncplot_app(sps::Tuple{Vararg{SyncPlot}})
	for sp in sps
		sp.app === nothing || return sp.app
	end
	return nothing
end

function Base.hcat(sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(hcat(plots...); app = _syncplot_app(sps))
end

function Base.vcat(sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(vcat(plots...); app = _syncplot_app(sps))
end

function Base.hvcat(rows::Tuple{Vararg{Int}}, sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(hvcat(rows, plots...); app = _syncplot_app(sps))
end
