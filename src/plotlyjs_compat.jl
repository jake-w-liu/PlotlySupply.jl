using Base64
using Printf: @sprintf

_urldecode(s::AbstractString) =
	replace(s, r"%([0-9A-Fa-f]{2})" => m -> Char(parse(UInt8, m[2:3]; base = 16)))

# ── Minimal JPEG-in-PDF generator ───────────────────────────────────

const _ICC_PROFILE_SIG = UInt8[0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F,
	0x46, 0x49, 0x4C, 0x45, 0x00]  # "ICC_PROFILE\0"

function _jpeg_dimensions(data::Vector{UInt8})
	i = 1
	while i < length(data) - 8
		if data[i] != 0xFF
			i += 1
			continue
		end
		marker = data[i+1]
		# SOF0 or SOF2 — contains image dimensions
		if marker == 0xC0 || marker == 0xC2
			h = Int(data[i+5]) << 8 | Int(data[i+6])
			w = Int(data[i+7]) << 8 | Int(data[i+8])
			return (w, h)
		elseif marker == 0xD8 || marker == 0xD9 || marker == 0x01 || (0xD0 <= marker <= 0xD7)
			i += 2
		else
			seg_len = Int(data[i+2]) << 8 | Int(data[i+3])
			i += 2 + seg_len
		end
	end
	error("Could not parse JPEG dimensions from SOF marker")
end

function _extract_jpeg_icc(data::Vector{UInt8})
	chunks = Dict{Int,Vector{UInt8}}()
	n_chunks = 0
	i = 1
	while i < length(data) - 1
		if data[i] != 0xFF
			i += 1
			continue
		end
		marker = data[i+1]
		if marker == 0xD8 || marker == 0xD9 || marker == 0x01 || (0xD0 <= marker <= 0xD7)
			i += 2
		elseif marker == 0xDA  # SOS — start of scan, no more metadata
			break
		else
			i + 3 > length(data) && break
			seg_len = Int(data[i+2]) << 8 | Int(data[i+3])
			# APP2 with ICC_PROFILE signature
			if marker == 0xE2 && seg_len >= 16 &&
					i + 17 <= length(data) &&
					data[i+4:i+15] == _ICC_PROFILE_SIG
				chunk_num = Int(data[i+16])
				n_chunks = Int(data[i+17])
				# ICC data starts after the 14-byte header (sig + seq + count)
				chunks[chunk_num] = data[i+18:i+1+seg_len]
			end
			i += 2 + seg_len
		end
	end
	isempty(chunks) && return nothing
	icc = UInt8[]
	for j in 1:n_chunks
		haskey(chunks, j) || return nothing  # missing chunk
		append!(icc, chunks[j])
	end
	return icc
end

function _write_jpeg_pdf(io::IO, jpeg::Vector{UInt8}, img_w::Int, img_h::Int,
		page_w::Float64, page_h::Float64)
	pw = @sprintf("%.4f", page_w)
	ph = @sprintf("%.4f", page_h)
	icc = _extract_jpeg_icc(jpeg)

	content = "q $pw 0 0 $ph 0 0 cm /Img Do Q"
	content_bytes = Vector{UInt8}(content)

	# Build objects, tracking byte offsets for xref
	buf = IOBuffer()
	write(buf, "%PDF-1.4\n")
	write(buf, UInt8[0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

	offsets = Int[]

	# 1: Catalog
	push!(offsets, position(buf))
	write(buf, "1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n")

	# 2: Pages
	push!(offsets, position(buf))
	write(buf, "2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n")

	# 3: Page
	push!(offsets, position(buf))
	write(buf, "3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 $pw $ph]")
	write(buf, "/Contents 4 0 R/Resources<</XObject<</Img 5 0 R>>>>>>\nendobj\n")

	# 4: Content stream
	push!(offsets, position(buf))
	write(buf, "4 0 obj\n<</Length $(length(content_bytes))>>\nstream\n")
	write(buf, content_bytes)
	write(buf, "\nendstream\nendobj\n")

	# 5: Image XObject — use ICCBased colorspace if ICC profile found
	push!(offsets, position(buf))
	write(buf, "5 0 obj\n<</Type/XObject/Subtype/Image")
	write(buf, "/Width $img_w/Height $img_h")
	if icc !== nothing
		write(buf, "/ColorSpace[/ICCBased 6 0 R]")
	else
		write(buf, "/ColorSpace/DeviceRGB")
	end
	write(buf, "/BitsPerComponent 8")
	write(buf, "/Filter/DCTDecode/Length $(length(jpeg))>>\nstream\n")
	write(buf, jpeg)
	write(buf, "\nendstream\nendobj\n")

	if icc !== nothing
		# 6: ICC profile stream
		push!(offsets, position(buf))
		write(buf, "6 0 obj\n<</Length $(length(icc))/N 3/Alternate/DeviceRGB>>\nstream\n")
		write(buf, icc)
		write(buf, "\nendstream\nendobj\n")
	end

	# Cross-reference table
	xref_pos = position(buf)
	n_objs = length(offsets) + 1
	write(buf, "xref\n0 $n_objs\n")
	write(buf, "0000000000 65535 f\r\n")
	for off in offsets
		write(buf, @sprintf("%010d 00000 n\r\n", off))
	end

	# Trailer
	write(buf, "trailer\n<</Size $n_objs/Root 1 0 R>>\n")
	write(buf, "startxref\n$xref_pos\n%%EOF\n")

	write(io, take!(buf))
	return nothing
end

function make_subplots(; kwargs...)
	fig = plot(Layout(Subplots(; kwargs...)))
	p = _plot_obj(fig)
	_apply_default_template!(p)
	_apply_default_cartesian_axes!(p)
	_refresh!(fig)
	return fig
end

function mgrid(arrays...)
	lengths = collect(length.(arrays))
	ones_vec = ones(Int, length(arrays))
	out = []
	for i in eachindex(arrays)
		repeats = copy(lengths)
		repeats[i] = 1

		shape = copy(ones_vec)
		shape[i] = lengths[i]
		push!(out, reshape(arrays[i], shape...) .* ones(repeats...))
	end
	return out
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
			svg_text = _urldecode(data_url[length(prefix)+1:end])
			write(io, svg_text)
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

	# Render the plot with explicit dimensions in the export window
	js_render = """
(async function() {
  var div = document.getElementById($divid_js);
  var layout = Object.assign({}, $layout_js, {width: $width, height: $height});
  await Plotly.react(div, $data_js, layout, $config_js);
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
			margins: { marginType: 'none' },
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
