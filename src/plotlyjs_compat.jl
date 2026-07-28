using Base64

@inline function _hex_nibble(byte::UInt8)
	0x30 <= byte <= 0x39 && return byte - 0x30
	0x41 <= byte <= 0x46 && return byte - 0x41 + 0x0a
	0x61 <= byte <= 0x66 && return byte - 0x61 + 0x0a
	throw(ArgumentError("invalid hexadecimal digit in percent escape: $(Char(byte))"))
end

# Decode percent-escapes into raw bytes. Work directly on UTF-8 code units so
# non-ASCII SVG text is preserved without allocating one temporary String per
# character. The first pass validates escapes and computes the exact output
# length; the second fills one right-sized result buffer.
function _urldecode_bytes(s::AbstractString)
	bytes = codeunits(s)
	n = length(bytes)
	output_length = 0
	i = 1
	while i <= n
		if bytes[i] == 0x25 && i + 2 <= n # '%'
			_hex_nibble(bytes[i + 1])
			_hex_nibble(bytes[i + 2])
			i += 3
		else
			i += 1
		end
		output_length += 1
	end

	out = Vector{UInt8}(undef, output_length)
	i = 1
	j = 1
	while i <= n
		if bytes[i] == 0x25 && i + 2 <= n # '%'
			hi = _hex_nibble(bytes[i + 1])
			lo = _hex_nibble(bytes[i + 2])
			@inbounds out[j] = (hi << 4) | lo
			i += 3
		else
			@inbounds out[j] = bytes[i]
			i += 1
		end
		j += 1
	end
	return out
end

const _BASE64_DECODE_CHUNK_BYTES = 64 * 1024

@inline function _is_base64_byte(byte::UInt8)
	return 0x41 <= byte <= 0x5a ||
		   0x61 <= byte <= 0x7a ||
		   0x30 <= byte <= 0x39 ||
		   byte == 0x2b ||
		   byte == 0x2f
end

# Validate the complete payload before writing any decoded bytes. Besides
# producing clearer errors than Base64DecodePipe, this keeps the destination
# unchanged when a malformed character occurs late in a large payload.
function _validate_base64_payload(payload::Union{String, SubString{String}})
	bytes = codeunits(payload)
	n = length(bytes)
	n == 0 && return nothing
	n % 4 == 0 || throw(ArgumentError("malformed base64 payload"))

	padding = bytes[n] == 0x3d ? 1 : 0 # '='
	if padding == 1 && bytes[n - 1] == 0x3d
		padding = 2
	end

	@inbounds for i in 1:(n - padding)
		_is_base64_byte(bytes[i]) ||
			throw(ArgumentError("malformed base64 payload"))
	end
	return nothing
end

function _write_base64_payload!(
	io::IO,
	payload::Union{String, SubString{String}},
)
	_validate_base64_payload(payload)
	isempty(payload) && return nothing

	decoded = Base64DecodePipe(IOBuffer(payload))
	# Bound temporary memory independently of image size while retaining enough
	# data per write to avoid excessive small-I/O overhead.
	buffer = Vector{UInt8}(
		undef,
		min(_BASE64_DECODE_CHUNK_BYTES, ncodeunits(payload)),
	)
	while !eof(decoded)
		n = readbytes!(decoded, buffer, length(buffer))
		n == 0 && break
		write(io, buffer)
	end
	return nothing
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
const _SAVEFIG_FORMATS = ("png", "jpeg", "svg", "pdf", "html", "json")
const _PDF_COPY_CHUNK_BYTES = 64 * 1024

struct _ExportOptions
	width::Float64
	height::Float64
	scale::Float64
	scaled_width::Float64
	scaled_height::Float64
	width_js::String
	height_js::String
	scale_js::String
	scaled_width_js::String
	scaled_height_js::String
end

struct _PreparedRendererExport
	data_js::String
	layout_js::String
	config_js::String
	options::_ExportOptions
end

struct _CapturedPDF
	tempdir::String
	path::String
	owner_state::Union{Nothing,_ExportState}
end

_CapturedPDF(tempdir::String, path::String) =
	_CapturedPDF(tempdir, path, nothing)

function _validate_export_format(fmt::String)
	fmt == "eps" && error("EPS export is not supported. Use \"svg\" or \"pdf\" instead.")
	fmt in _SAVEFIG_FORMATS ||
		error("Unsupported export format '$fmt'. Supported: $(join(_SAVEFIG_FORMATS, ", ")).")
	return fmt
end

function _normalize_export_number(name::Symbol, value)
	value isa Real && !(value isa Bool) ||
		throw(ArgumentError("$name must be a positive, finite, non-Bool real number"))
	number = try
		Float64(value)
	catch
		throw(ArgumentError("$name must be representable as a finite number"))
	end
	isfinite(number) && number > 0 ||
		throw(ArgumentError("$name must be a positive, finite, non-Bool real number"))
	return number
end

function _normalize_export_options(kwargs)
	for k in keys(kwargs)
		k in _EXPORT_KW ||
			throw(ArgumentError("Unsupported keyword argument: $k. Supported: height, width, scale."))
	end
	width = _normalize_export_number(:width, get(kwargs, :width, 700))
	height = _normalize_export_number(:height, get(kwargs, :height, 500))
	scale = _normalize_export_number(:scale, get(kwargs, :scale, 1))
	scaled_width = width * scale
	scaled_height = height * scale
	isfinite(scaled_width) && scaled_width > 0 ||
		throw(ArgumentError("width * scale must be finite and positive"))
	isfinite(scaled_height) && scaled_height > 0 ||
		throw(ArgumentError("height * scale must be finite and positive"))

	# JSON is the only interpolation path for caller-controlled numeric values.
	# Construct these strings during preflight, before opening a destination or
	# creating/accessing an Electron export window.
	return _ExportOptions(
		width,
		height,
		scale,
		scaled_width,
		scaled_height,
		_json_js(width),
		_json_js(height),
		_json_js(scale),
		_json_js(scaled_width),
		_json_js(scaled_height),
	)
end

function _prepare_renderer_export(p::Plot, kwargs)
	options = _normalize_export_options(kwargs)
	return _PreparedRendererExport(
		_json_js(p.data),
		_json_js(p.layout),
		_json_js(p.config),
		options,
	)
end

function _capture_image_data_url(
	ec,
	win,
	divid::String,
	prepared::_PreparedRendererExport,
	fmt::String,
)
	options = prepared.options
	format_js = _json_js(fmt)
	divid_js = _json_js(divid)

	js = """
(async function() {
  const div = document.getElementById($divid_js);
  await Plotly.react(div, $(prepared.data_js), $(prepared.layout_js), $(prepared.config_js));
  const url = await Plotly.toImage(div, {
    format: $format_js,
    width: $(options.width_js),
    height: $(options.height_js),
    scale: $(options.scale_js)
  });
  return url;
})();
"""
	data_url = Base.invokelatest(() -> ec.run(win, js))
	data_url isa AbstractString ||
		error("Plotly.toImage returned a non-string value for format '$fmt'")
	# ElectronCall normally returns String. This conversion is zero-copy for
	# String and preserves compatibility with other AbstractString adapters.
	return String(data_url)
end

function _write_image_data_url!(io::IO, data_url::String, fmt::String)
	if fmt == "svg"
		prefix = "data:image/svg+xml,"
		if startswith(data_url, prefix)
			payload = SubString(data_url, ncodeunits(prefix) + 1)
			write(io, _urldecode_bytes(payload))
		else
			prefix_b64 = "data:image/svg+xml;base64,"
			if startswith(data_url, prefix_b64)
				payload = SubString(data_url, ncodeunits(prefix_b64) + 1)
				_write_base64_payload!(io, payload)
			else
				error("Unexpected data URL format from Plotly.toImage for format 'svg'")
			end
		end
	else
		prefix = "data:image/$fmt;base64,"
		startswith(data_url, prefix) ||
			error("Unexpected data URL format from Plotly.toImage for format '$fmt'")
		payload = SubString(data_url, ncodeunits(prefix) + 1)
		_write_base64_payload!(io, payload)
	end
	return nothing
end

function _export_image(io::IO, ec, win, divid::String, p::Plot, fmt::String; kwargs...)
	prepared = _prepare_renderer_export(p, kwargs)
	data_url = lock(_EXPORT_STATE.lock) do
		_capture_image_data_url(ec, win, divid, prepared, fmt)
	end
	_write_image_data_url!(io, data_url, fmt)
	return nothing
end

function _pdf_status_field(status, name::Symbol)
	if status isa AbstractDict
		haskey(status, String(name)) && return status[String(name)]
		haskey(status, name) && return status[name]
	elseif status isa NamedTuple && hasproperty(status, name)
		return getproperty(status, name)
	end
	return nothing
end

function _wait_for_pdf_job(ec, app, job_id::String; timeout_s::Real)
	timeout = _export_timeout_seconds(timeout_s, "printToPDF")
	job_id_js = _json_js(job_id)
	status_js = """
(function() {
  const jobs = global.__plotlysupply_pdf_jobs;
  const job = jobs && jobs.get($job_id_js);
  return job === undefined ? null : {done: job.done, error: job.error};
})()
"""
	start_ns = time_ns()
	while (time_ns() - start_ns) / 1.0e9 < timeout
		status = Base.invokelatest(() -> ec.run(app, status_js))
		status === nothing &&
			error("printToPDF job '$job_id' disappeared before completion")
		if _pdf_status_field(status, :done) === true
			err = _pdf_status_field(status, :error)
			if err !== nothing && err !== false && err != ""
				error("printToPDF failed: $err")
			end
			return nothing
		end
		elapsed = (time_ns() - start_ns) / 1.0e9
		remaining = timeout - elapsed
		remaining > 0 && sleep(min(0.05, remaining))
	end
	error("printToPDF timed out after $(timeout)s")
end

function _delete_pdf_job(ec, app, job_id::String)
	job_id_js = _json_js(job_id)
	js = """
(function() {
  const jobs = global.__plotlysupply_pdf_jobs;
  return jobs ? jobs.delete($job_id_js) : false;
})()
"""
	Base.invokelatest(() -> ec.run(app, js))
	return nothing
end

function _capture_pdf_file(
	ec,
	app,
	win,
	divid::String,
	prepared::_PreparedRendererExport,
	job_id::String;
	timeout_s::Real = 15.0,
	owner_state::Union{Nothing,_ExportState} = nothing,
)
	options = prepared.options
	divid_js = _json_js(divid)

	# Render the plot at the scaled dimensions so it fills the (scaled) PDF page
	# — otherwise `scale>1` enlarges the page but not the plot, leaving blank space.
	js_render = """
(async function() {
  var div = document.getElementById($divid_js);
  var layout = Object.assign({}, $(prepared.layout_js), {
    width: $(options.scaled_width_js),
    height: $(options.scaled_height_js)
  });
  await Plotly.react(div, $(prepared.data_js), layout, $(prepared.config_js));
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

	win_id = Base.invokelatest(() -> getfield(win, :id))
	tempdir = mktempdir(; prefix = "plotlysupply-pdf-")
	if owner_state !== nothing
		lock(owner_state.lock) do
			push!(owner_state.owned_pdf_tempdirs, tempdir)
		end
	end
	tmpfile = joinpath(tempdir, "output.pdf")
	tmpfile_js = _json_js(tmpfile)
	job_id_js = _json_js(job_id)

	# Page size in inches (Electron printToPDF pageSize uses inches)
	page_w_in = _json_js(options.scaled_width / 96.0)
	page_h_in = _json_js(options.scaled_height / 96.0)

	js_pdf = """
(function() {
  if (!global.__plotlysupply_pdf_jobs) {
    global.__plotlysupply_pdf_jobs = new Map();
  }
  const jobs = global.__plotlysupply_pdf_jobs;
  const key = $job_id_js;
  if (jobs.has(key)) return 'duplicate';
  const job = {done: false, error: null};
  jobs.set(key, job);
  function fail(err) {
    const current = jobs.get(key);
    if (current === job) {
      current.error = String(err);
      current.done = true;
    }
  }
  try {
    const browserWindow = require('electron').BrowserWindow.fromId($win_id);
    if (!browserWindow) throw new Error('export BrowserWindow no longer exists');
    browserWindow.webContents.printToPDF({
      printBackground: true,
      preferCSSPageSize: true,
      margins: { marginType: 'custom', top: 0, bottom: 0, left: 0, right: 0 },
      pageSize: { width: $page_w_in, height: $page_h_in }
    }).then(function(buf) {
      const current = jobs.get(key);
      if (current !== job) return;
      try {
        require('fs').writeFileSync($tmpfile_js, buf);
        current.done = true;
      } catch (err) {
        fail(err);
      }
    }).catch(fail);
  } catch (err) {
    fail(err);
  }
  return 'started';
})()
"""

	job_start_attempted = false
	try
		job_start_attempted = true
		result = Base.invokelatest(() -> ec.run(app, js_pdf))
		result == "started" ||
			error("printToPDF job '$job_id' failed to start (result: $result)")
		_wait_for_pdf_job(ec, app, job_id; timeout_s = timeout_s)
		isfile(tmpfile) ||
			error("printToPDF completed without writing its private output file")
	catch
		if job_start_attempted
			try
				_delete_pdf_job(ec, app, job_id)
			catch cleanup_error
				@warn "Failed to remove a failed printToPDF job state." job_id exception = (
					cleanup_error,
					catch_backtrace(),
				)
			end
		end
		try
			rm(tempdir; recursive = true, force = true)
			if owner_state !== nothing
				lock(owner_state.lock) do
					delete!(owner_state.owned_pdf_tempdirs, tempdir)
				end
			end
		catch cleanup_error
			@warn "Failed to remove a failed printToPDF temp directory." tempdir exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		rethrow()
	end

	try
		_delete_pdf_job(ec, app, job_id)
	catch
		try
			rm(tempdir; recursive = true, force = true)
			if owner_state !== nothing
				lock(owner_state.lock) do
					delete!(owner_state.owned_pdf_tempdirs, tempdir)
				end
			end
		catch cleanup_error
			@warn "Failed to remove a printToPDF temp directory after job-state cleanup failed." tempdir exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		rethrow()
	end
	return _CapturedPDF(tempdir, tmpfile, owner_state)
end

function _copy_pdf_file_chunked!(io::IO, path::String)
	open(path, "r") do input
		buffer = Vector{UInt8}(undef, _PDF_COPY_CHUNK_BYTES)
		while !eof(input)
			n = readbytes!(input, buffer, _PDF_COPY_CHUNK_BYTES)
			n == 0 && break
			write(io, @view buffer[1:n])
		end
	end
	return nothing
end

function _remove_captured_pdf_tempdir!(
	captured::_CapturedPDF,
	tempdir_remover,
)
	if tempdir_remover === nothing
		rm(captured.tempdir; recursive = true, force = true)
	else
		Base.invokelatest(tempdir_remover, captured.tempdir)
	end
	if captured.owner_state !== nothing
		lock(captured.owner_state.lock) do
			delete!(
				captured.owner_state.owned_pdf_tempdirs,
				captured.tempdir,
			)
		end
	end
	return nothing
end

function _write_captured_pdf!(
	io::IO,
	captured::_CapturedPDF;
	tempdir_remover = nothing,
)
	try
		_copy_pdf_file_chunked!(io, captured.path)
	catch
		try
			_remove_captured_pdf_tempdir!(captured, tempdir_remover)
		catch cleanup_error
			@warn "Failed to remove a captured PDF after its destination write failed." tempdir = captured.tempdir exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		rethrow()
	end
	_remove_captured_pdf_tempdir!(captured, tempdir_remover)
	return nothing
end

function _export_pdf(io::IO, ec, win, divid::String, p::Plot; kwargs...)
	prepared = _prepare_renderer_export(p, kwargs)
	app = Base.invokelatest(() -> getfield(win, :app))
	state = _EXPORT_STATE
	captured = lock(state.lock) do
		job_id = _next_pdf_job_id_locked!(state)
		_capture_pdf_file(
			ec,
			app,
			win,
			divid,
			prepared,
			job_id;
			owner_state = state,
		)
	end
	_write_captured_pdf!(io, captured)
	return nothing
end

function _prepare_savefig(p::Plot, fmt::String, kwargs)
	fmt in ("html", "json") && return nothing
	return _prepare_renderer_export(p, kwargs)
end

function _savefig_prepared(
	io::IO,
	p::Plot,
	fmt::String,
	prepared;
	state::_ExportState = _EXPORT_STATE,
	ec = nothing,
	window_timeout_s::Real = 10.0,
	pdf_timeout_s::Real = 15.0,
)
	fmt == "html" && return _savefig_html(io, p)
	fmt == "json" && return (PlotlyBase.JSON.print(io, p); nothing)
	prepared isa _PreparedRendererExport ||
		throw(ArgumentError("renderer export was not prepared"))

	if fmt == "pdf"
		captured = _with_export_window(
			state;
			ec = ec,
			timeout_s = window_timeout_s,
		) do backend, app, win, divid
			job_id = _next_pdf_job_id_locked!(state)
			_capture_pdf_file(
				backend,
				app,
				win,
				divid,
				prepared,
				job_id;
				timeout_s = pdf_timeout_s,
				owner_state = state,
			)
		end
		# This user-controlled I/O is deliberately outside the renderer lock.
		_write_captured_pdf!(io, captured)
	else
		data_url = _with_export_window(
			state;
			ec = ec,
			timeout_s = window_timeout_s,
		) do backend, app, win, divid
			_capture_image_data_url(backend, win, divid, prepared, fmt)
		end
		# Decoding and user-controlled I/O are deliberately outside the lock.
		_write_image_data_url!(io, data_url, fmt)
	end
	return nothing
end

function _savefig_atomic(
	filename::AbstractString,
	p::Plot,
	fmt::String,
	prepared;
	state::_ExportState = _EXPORT_STATE,
	ec = nothing,
	window_timeout_s::Real = 10.0,
	pdf_timeout_s::Real = 15.0,
	renamer = Base.Filesystem.rename,
)
	target = abspath(filename)
	isdir(target) &&
		throw(ArgumentError("savefig destination is a directory: $filename"))
	parent = dirname(target)
	temp_path, temp_io = mktemp(parent; cleanup = false)
	try
		_savefig_prepared(
			temp_io,
			p,
			fmt,
			prepared;
			state = state,
			ec = ec,
			window_timeout_s = window_timeout_s,
			pdf_timeout_s = pdf_timeout_s,
		)
		flush(temp_io)
		close(temp_io)
		# The temp file is in the destination directory, so one filesystem
		# rename is the commit. Avoid `mv(...; force=true)`: its fallback can
		# remove the old target before a later copy/rename error.
		Base.invokelatest(renamer, temp_path, target)
	catch
		if isopen(temp_io)
			try
				close(temp_io)
			catch cleanup_error
				@warn "Failed to close an unpublished savefig temp file." temp_path exception = (
					cleanup_error,
					catch_backtrace(),
				)
			end
		end
		try
			rm(temp_path; force = true)
		catch cleanup_error
			@warn "Failed to remove an unpublished savefig temp file." temp_path exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		rethrow()
	end
	return filename
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
	fmt = _validate_export_format(lowercase(String(format)))
	prepared = _prepare_savefig(p, fmt, kwargs)
	return _savefig_prepared(io, p, fmt, prepared)
end

savefig(io::IO, sp::SyncPlot; kwargs...) = savefig(io, sp.plot; kwargs...)

function savefig(p::Union{Plot, SyncPlot}; kwargs...)
	io = IOBuffer()
	savefig(io, p; kwargs...)
	return take!(io)
end

function _filename_export_format(
	filename::AbstractString,
	format::Union{Nothing,AbstractString},
)
	ext = lowercase(splitext(filename)[2])
	inferred = isempty(ext) ? "png" : String(lstrip(ext, '.'))
	fmt = isnothing(format) ? inferred : lowercase(String(format))
	return _validate_export_format(fmt)
end

function _savefig_filename(
	filename::AbstractString,
	p::Union{Plot,SyncPlot},
	format::Union{Nothing,AbstractString},
	kwargs;
	state::_ExportState = _EXPORT_STATE,
	ec = nothing,
)
	fmt = _filename_export_format(filename, format)
	plot = p isa SyncPlot ? p.plot : p
	prepared = _prepare_savefig(plot, fmt, kwargs)
	return _savefig_atomic(
		filename,
		plot,
		fmt,
		prepared;
		state = state,
		ec = ec,
	)
end

function savefig(
	filename::AbstractString,
	p::Union{Plot, SyncPlot};
	format::Union{Nothing, AbstractString} = nothing,
	kwargs...,
)
	return _savefig_filename(filename, p, format, kwargs)
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
	_plotlyjs_command!(sp, :redraw)
	return sp
end

function PlotlyBase.purge!(sp::SyncPlot)
	_do_purge!(sp.plot)
	_plotlyjs_command!(sp, :purge)
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
	@eval function PlotlyBase.$f(
		sp::SyncPlot,
		with::PlotlyBase.PlotlyAttribute = attr();
		kwargs...,
	)
		PlotlyBase.$f(sp.plot.layout, with; kwargs...)
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
