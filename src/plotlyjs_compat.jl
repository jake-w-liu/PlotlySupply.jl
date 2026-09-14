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
	fig = plot(_plotlysupply_subplot_layout(Subplots(; kwargs...)))
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

function _invoke_plot_add_trace!(
	p::Plot,
	trace::GenericTrace;
	kw...,
)
	return invoke(
		PlotlyBase.add_trace!,
		Tuple{Plot,GenericTrace},
		p,
		trace;
		kw...,
	)
end

function PlotlyBase.add_trace!(
	p::_RefreshablePlot,
	trace::GenericTrace;
	kw...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_invoke_plot_add_trace!(current, trace; kw...)
	end
end

function PlotlyBase.add_trace!(sp::SyncPlot, trace::GenericTrace; kw...)
	return _mutate_and_refresh_syncplot!(
		sp;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_invoke_plot_add_trace!(current, trace; kw...)
	end
end

function PlotlyBase.redraw!(sp::SyncPlot)
	prepare = function (target, current)
		commit = () -> current
		return (
			script = _plotlyjs_command_script(target, :redraw),
			operation = "redraw",
			commit = commit,
		)
	end
	_syncplot_transaction!(sp, prepare)
	return sp
end

function PlotlyBase.purge!(sp::SyncPlot)
	prepare = (target, current) ->
		_prepare_purge_transaction(target, current)
	_syncplot_transaction!(sp, prepare)
	return sp
end

function _require_open_syncplot_image_window(sp::SyncPlot)
	return _require_open_syncplot_window(sp)
end

function _syncplot_to_image_script(sp::SyncPlot, kwargs)
	divid_js = _json_js(getfield(sp, :divid))
	options_js = _json_js(kwargs)
	return """
(async function() {
  if (typeof Plotly === "undefined" || typeof Plotly.toImage !== "function") {
    throw new Error("Plotly.toImage is unavailable in the SyncPlot window");
  }
  const div = document.getElementById($divid_js);
  if (!div) throw new Error("SyncPlot plot div was not found");
  return await Plotly.toImage(div, $options_js);
})()
"""
end

function _syncplot_download_image_script(sp::SyncPlot, kwargs)
	divid_js = _json_js(getfield(sp, :divid))
	options_js = _json_js(kwargs)
	return """
(async function() {
  if (typeof Plotly === "undefined" || typeof Plotly.downloadImage !== "function") {
    throw new Error("Plotly.downloadImage is unavailable in the SyncPlot window");
  }
  const div = document.getElementById($divid_js);
  if (!div) throw new Error("SyncPlot plot div was not found");
  await Plotly.downloadImage(div, $options_js);
  return null;
})()
"""
end

function PlotlyBase.to_image(sp::SyncPlot; kwargs...)
	_require_open_syncplot_image_window(sp)
	js = _syncplot_to_image_script(sp, kwargs)
	ec = _syncplot_backend(sp)
	result = Base.invokelatest(() -> ec.run(getfield(sp, :window), js))
	result isa AbstractString || error(
		"Plotly.toImage returned a non-string result of type $(typeof(result))",
	)
	return String(result)
end

function PlotlyBase.download_image(sp::SyncPlot; kwargs...)
	_require_open_syncplot_image_window(sp)
	js = _syncplot_download_image_script(sp, kwargs)
	ec = _syncplot_backend(sp)
	Base.invokelatest(() -> ec.run(getfield(sp, :window), js))
	return nothing
end

const _SYNCPLOT_MISSING_CREATION_SPEC_ERROR =
	"Cannot clone this SyncPlot because its original window options are unavailable. " *
	"Copy `sp.plot`, then call `to_syncplot(plot; width=..., height=..., " *
	"title=..., show=..., autoplay=..., timeout_s=...)` with explicit window options."

struct _SyncPlotModelDeepcopyContext end
const _SYNCPLOT_MODEL_DEEPCOPY_CONTEXT = _SyncPlotModelDeepcopyContext()
const _SYNCPLOT_MODEL_REFERENCE_ERROR =
	"Cannot clone a SyncPlot whose plot model contains a SyncPlot reference."
const _SYNCPLOT_NESTED_DEEPCOPY_ERROR =
	"Cannot deepcopy a SyncPlot as part of another object because native " *
	"window creation cannot be rolled back if a later deepcopy operation fails. " *
	"Deepcopy the SyncPlot directly instead."

function _syncplot_creation_spec(sp::SyncPlot)
	spec = getfield(sp, :_resources).creation_spec
	spec === nothing &&
		throw(ArgumentError(_SYNCPLOT_MISSING_CREATION_SPEC_ERROR))
	return spec
end

function _create_syncplot_clone(
	sp::SyncPlot,
	plot_clone::Plot,
	spec::_SyncPlotCreationSpec,
)
	return _create_syncplot_window(
		_syncplot_backend(sp),
		plot_clone;
		app = sp.app,
		width = spec.width,
		height = spec.height,
		title = spec.title,
		show = spec.show,
		autoplay = spec.autoplay,
		timeout_s = spec.timeout_s,
	)
end

function _clone_syncplot(sp::SyncPlot)
	spec = _syncplot_creation_spec(sp)
	stackdict = IdDict()
	stackdict[_SYNCPLOT_MODEL_DEEPCOPY_CONTEXT] = sp
	plot_clone = try
		_clone_plot_model(sp.plot, stackdict)
	finally
		delete!(stackdict, _SYNCPLOT_MODEL_DEEPCOPY_CONTEXT)
	end
	return _create_syncplot_clone(sp, plot_clone, spec)
end

Base.copy(sp::SyncPlot) = _clone_syncplot(sp)
PlotlyBase.fork(sp::SyncPlot) = _clone_syncplot(sp)
Base.deepcopy(sp::SyncPlot) = _clone_syncplot(sp)

function Base.deepcopy_internal(sp::SyncPlot, stackdict::IdDict)
	haskey(stackdict, _SYNCPLOT_MODEL_DEEPCOPY_CONTEXT) &&
		throw(ArgumentError(_SYNCPLOT_MODEL_REFERENCE_ERROR))
	throw(ArgumentError(_SYNCPLOT_NESTED_DEEPCOPY_ERROR))
end

function _mutate_syncplot_clone!(
	mutator::Function,
	sp::SyncPlot,
	args...;
	kwargs...,
)
	out = _clone_syncplot(sp)
	try
		mutator(out, args...; kwargs...)
		return out
	catch
		try
			close(out)
		catch cleanup_error
			@warn "Failed to close a SyncPlot clone after mutation failed." exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		rethrow()
	end
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
	:redraw,
	:purge,
	:react,
)
	f_bang = Symbol(f, "!")
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; kwargs...)
		return _mutate_syncplot_clone!(
			PlotlyBase.$f_bang,
			sp,
			args...;
			kwargs...,
		)
	end
end

const _SYNCPLOT_DEFINED_LAYOUT_UPDATERS = Set((
	:update_xaxes!,
	:update_yaxes!,
	:update_polars!,
	:update_mapboxes!,
))

for (f, _) in vcat(PlotlyBase._layout_obj_updaters, PlotlyBase._layout_vector_updaters)
	f in _SYNCPLOT_DEFINED_LAYOUT_UPDATERS && continue
	preserve_layout_vector =
		f === :update_annotations! ? :annotations :
		f === :update_shapes! ? :shapes :
		f === :update_images! ? :images :
		nothing
	@eval function PlotlyBase.$f(
		sp::SyncPlot,
		with::PlotlyBase.PlotlyAttribute = attr();
		kwargs...,
	)
		return _mutate_and_refresh_syncplot!(
			sp;
			mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
			preserve_layout_vector = $(
				QuoteNode(preserve_layout_vector)
			),
		) do current
			PlotlyBase.$f(current.layout, with; kwargs...)
		end
	end
end

const _REFRESHABLE_DEFINED_LAYOUT_UPDATERS = Set((
	:update_xaxes!,
	:update_yaxes!,
	:update_polars!,
	:update_geos!,
	:update_mapboxes!,
	:update_scenes!,
	:update_ternaries!,
	:update_annotations!,
	:update_shapes!,
	:update_images!,
))

for (f, _) in vcat(
	PlotlyBase._layout_obj_updaters,
	PlotlyBase._layout_vector_updaters,
)
	f in _REFRESHABLE_DEFINED_LAYOUT_UPDATERS && continue
	@eval function PlotlyBase.$f(
		p::_RefreshablePlot,
		with::PlotlyBase.PlotlyAttribute = attr();
		kwargs...,
	)
		return _transactional_full_plot_mutation!(
			p;
			mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
		) do current
			PlotlyBase.$f(current.layout, with; kwargs...)
		end
	end
end

for f in (:add_hrect!, :add_hline!, :add_vrect!, :add_vline!, :add_shape!, :add_layout_image!)
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; kwargs...)
		return _mutate_and_refresh_syncplot!(
			sp;
			mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
		) do current
			PlotlyBase.$f(current.layout, args...; kwargs...)
		end
	end

	@eval function PlotlyBase.$f(
		p::_RefreshablePlot,
		args...;
		kwargs...,
	)
		return _transactional_full_plot_mutation!(
			p;
			mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
		) do current
			PlotlyBase.$f(current.layout, args...; kwargs...)
		end
	end
end

function PlotlyBase.add_recession_bands!(sp::SyncPlot; kwargs...)
	new_shapes = Ref{Any}(nothing)
	_mutate_and_refresh_syncplot!(
		sp;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		bands = PlotlyBase._recession_band_shapes(
			current;
			kwargs...,
		)
		bands === nothing && return nothing
		old_shapes = current.layout[:shapes]
		new_shapes[] =
			isempty(old_shapes) ? bands : vcat(old_shapes, bands)
		PlotlyBase.relayout!(
			current.layout;
			shapes = new_shapes[],
		)
	end
	return new_shapes[]
end

function PlotlyBase.add_recession_bands!(
	p::_RefreshablePlot;
	kwargs...,
)
	new_shapes = Ref{Any}(nothing)
	_transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		bands = PlotlyBase._recession_band_shapes(current; kwargs...)
		bands === nothing && return nothing
		old_shapes = current.layout[:shapes]
		new_shapes[] =
			isempty(old_shapes) ? bands : vcat(old_shapes, bands)
		PlotlyBase.relayout!(
			current.layout;
			shapes = new_shapes[],
		)
	end
	return new_shapes[]
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

#region Re-exported PlotlyBase API docstrings
# Attach docstrings to names re-exported from PlotlyBase (and MeshGrid) for
# PlotlyJS compatibility, so `?name` and the generated API reference cover the
# full exported surface.

for (fn, desc) in (
	(:bar, "bar chart"),
	(:barpolar, "polar bar (wind-rose)"),
	(:box, "box-and-whisker"),
	(:candlestick, "candlestick financial"),
	(:carpet, "carpet coordinate-system"),
	(:choropleth, "geographic choropleth"),
	(:choroplethmapbox, "Mapbox-tiled choropleth"),
	(:cone, "3D cone vector-field"),
	(:contour, "2D contour"),
	(:contourcarpet, "contour over a `carpet` coordinate system"),
	(:densitymapbox, "density heatmap on Mapbox tiles"),
	(:funnel, "funnel"),
	(:funnelarea, "funnel-area"),
	(:heatmap, "heatmap"),
	(:heatmapgl, "WebGL heatmap"),
	(:histogram, "histogram"),
	(:histogram2d, "2D histogram"),
	(:histogram2dcontour, "2D histogram contour"),
	(:icicle, "icicle (hierarchical partition)"),
	(:image, "image"),
	(:indicator, "indicator/gauge card"),
	(:isosurface, "3D isosurface"),
	(:mesh3d, "3D mesh"),
	(:ohlc, "OHLC financial"),
	(:parcats, "parallel-categories"),
	(:parcoords, "parallel-coordinates"),
	(:pie, "pie"),
	(:pointcloud, "WebGL point-cloud"),
	(:sankey, "Sankey diagram"),
	(:scatter, "scatter/line"),
	(:scatter3d, "3D scatter/line"),
	(:scattercarpet, "scatter over a `carpet` coordinate system"),
	(:scattergeo, "geographic scatter"),
	(:scattergl, "WebGL scatter"),
	(:scattermapbox, "scatter on Mapbox tiles"),
	(:scatterpolar, "polar scatter"),
	(:scatterpolargl, "WebGL polar scatter"),
	(:scatterternary, "ternary scatter"),
	(:splom, "scatter-plot matrix"),
	(:streamtube, "3D streamtube"),
	(:sunburst, "sunburst (hierarchical partition)"),
	(:surface, "3D surface"),
	(:table, "table"),
	(:treemap, "treemap (hierarchical partition)"),
	(:violin, "violin"),
	(:volume, "3D volume"),
	(:waterfall, "waterfall"),
)
	doc = """
		$(fn)(; kwargs...)
		$(fn)(fields::AbstractDict; kwargs...)

	Construct a $(desc) trace — equivalent to `GenericTrace("$(fn)"; kwargs...)`.
	Keyword arguments or `fields` become trace attributes; see the
	[plotly.js `$(fn)` reference](https://plotly.com/julia/reference/$(fn)/).
	"""
	@eval @doc $doc $fn
end

# ── Attribute containers and core types ─────────────────────────────

"""
	attr(; kwargs...)
	attr(fields::AbstractDict; kwargs...)
	attr(nt::NamedTuple)

Build a nested `PlotlyAttribute` object — e.g.
`Layout(xaxis = attr(title = "x", range = [0, 1]))`. Fields are accessible
dynamically (`a.title`).
"""
attr

"""
	GenericTrace(kind::AbstractString; kwargs...)
	GenericTrace(kind::AbstractString, fields::AbstractDict; kwargs...)

Generic trace of arbitrary plotly.js `kind`. The trace constructors
(`scatter`, `bar`, `heatmap`, …) build these; fields are accessible
dynamically (`tr.x` reads/writes the `x` attribute).
"""
GenericTrace

"""
	Layout(; kwargs...)
	Layout(fields::AbstractDict; kwargs...)

Figure layout object (axes, title, margins, legend, shapes, …). Nested
attributes are built with [`attr`](@ref), e.g.
`Layout(title = "Hi", xaxis = attr(range = [0, 1]))`.
"""
Layout

"""
	AbstractTrace

Abstract supertype of all trace objects; concrete traces are
[`GenericTrace`](@ref) instances.
"""
AbstractTrace

"""
	AbstractLayout

Abstract supertype of layout-level objects such as [`Layout`](@ref) and
[`Shape`](@ref).
"""
AbstractLayout

"""
	PlotlyFrame

Animation frame: a `Dict`-backed container of frame attributes (`data`,
`layout`, `name`, …) passed to `plot(...; frames = [...])`. Build frames with
[`frame`](@ref).
"""
PlotlyFrame

"""
	Shape(kind::AbstractString; kwargs...)
	Shape(kind::AbstractString, fields::AbstractDict; kwargs...)

Layout shape of `kind` — `"line"`, `"rect"`, `"circle"`, or `"path"`. Add one
with [`add_shape!`](@ref) or the [`add_hline!`](@ref), [`add_vline!`](@ref),
[`add_hrect!`](@ref), and [`add_vrect!`](@ref) helpers.
"""
Shape

"""
	Template(; data = Dict(), layout = attr())
	Template(data, layout::Layout)

Plotly template holding default `data` attributes per trace type and a default
`layout`. Built-ins are accessible through [`templates`](@ref), e.g.
`templates[:plotly_dark]`; apply one with `set_template!`.
"""
Template

"""
	Cycler(values::AbstractVector)
	Cycler(x)

Container that cycles through `values` on indexing (`c[i]` wraps around) —
used internally for per-trace attribute cycling.
"""
Cycler

# ── Figure update verbs (PlotlyJS API) ──────────────────────────────

"""
	fork(p::Plot)

Return a copy of `p` (deep-copied `data`, copied `layout`). The non-mutating
update verbs (`restyle`, `relayout`, `update`, `addtraces`, `deletetraces`,
`movetraces`, `extendtraces`, `prependtraces`, `redraw`, `react`) are `fork`
plus their `!` counterpart applied to the copy.
"""
fork

"""
	frame(fields = Dict{Symbol,Any}(); kwargs...)

Build a [`PlotlyFrame`](@ref) animation frame from `fields` and keyword
attributes.
"""
frame

"""
	restyle(p::Plot, args...; kwargs...)

Non-mutating [`restyle!`](@ref): apply the trace update to a [`fork`](@ref)ed
copy of `p` and return it.
"""
restyle

"""
	relayout(p::Plot, args...; kwargs...)

Non-mutating [`relayout!`](@ref): apply the layout update to a [`fork`](@ref)ed
copy of `p` and return it.
"""
relayout

"""
	update(p::Plot, update = Dict(); layout::Layout = p.layout, kwargs...)
	update(p::Plot, ind, update = Dict(); layout::Layout = p.layout, kwargs...)

Non-mutating [`update!`](@ref): apply `restyle!` and `relayout!` to a
[`fork`](@ref)ed copy of `p` and return it.
"""
update

"""
	addtraces(p::Plot, traces::AbstractTrace...)

Non-mutating [`addtraces!`](@ref): append `traces` to a [`fork`](@ref)ed copy
of `p` and return it.
"""
addtraces

"""
	deletetraces(p::Plot, inds::Int...)

Non-mutating [`deletetraces!`](@ref): delete the traces at `inds` from a
[`fork`](@ref)ed copy of `p` and return it.
"""
deletetraces

"""
	movetraces(p::Plot, to_end::Int...)
	movetraces(p::Plot, src::AbstractVector{Int}, dest::AbstractVector{Int})

Non-mutating [`movetraces!`](@ref): reorder the traces of a [`fork`](@ref)ed
copy of `p` and return it.
"""
movetraces

"""
	extendtraces(p::Plot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)

Non-mutating [`extendtraces!`](@ref): extend existing trace attributes on a
[`fork`](@ref)ed copy of `p` and return it.
"""
extendtraces

"""
	prependtraces(p::Plot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)

Non-mutating [`prependtraces!`](@ref): prepend data to existing trace
attributes on a [`fork`](@ref)ed copy of `p` and return it.
"""
prependtraces

"""
	redraw(p::Plot)

Non-mutating [`redraw!`](@ref): returns a [`fork`](@ref)ed copy of `p`.
"""
redraw

"""
	react(p::Plot, data::AbstractVector{<:AbstractTrace}, layout::Layout)

Non-mutating [`react!`](@ref): replace `data` and `layout` on a [`fork`](@ref)ed
copy of `p` and return it.
"""
react

"""
	purge!(p)

Empty `p`: remove all traces and reset the layout to a blank `Layout`. On a
[`SyncPlot`](@ref) the open window is cleared as well.
"""
purge!

"""
	react!(p, data::AbstractVector{<:AbstractTrace}, layout::Layout)
	react!(p::SyncPlot, p2::Plot)

Replace the `data` and `layout` of `p` in place (plotly.js `Plotly.react`
semantics). On a [`SyncPlot`](@ref) the open window is updated.
"""
react!

"""
	redraw!(p)

Redraw `p` in place. On a `Plot` this is a no-op; on a [`SyncPlot`](@ref) it
refreshes the open Electron window from the Julia-side model.
"""
redraw!

"""
	savejson(p::Plot, filename::AbstractString)

Write `p`'s JSON figure specification to `filename`.
"""
savejson

"""
	to_image(sp::SyncPlot; kwargs...)

Render `sp` in its Electron window via `Plotly.toImage` and return the image
as a data-URL `String`. Keyword arguments map to `Plotly.toImage` options
(`format`, `width`, `height`, `scale`).
"""
to_image

"""
	download_image(sp::SyncPlot; kwargs...)

Trigger a browser-style download of `sp`'s rendered image via
`Plotly.downloadImage` in its Electron window. Keyword arguments map to
`Plotly.downloadImage` options (`format`, `width`, `height`, `scale`,
`filename`).
"""
download_image

# ── Trace and subplot helpers ───────────────────────────────────────

"""
	add_trace!(p, trace::GenericTrace; row = 1, col = 1, secondary_y = false)

Add `trace` to `p`, routed to the subplot cell at `row`/`col` (with
`secondary_y = true` for a secondary-y axis). Works on `Plot` and
[`SyncPlot`](@ref); returns `p`.
"""
add_trace!

"""
	add_shape!(p, shape; row = "all", col = "all")

Add a layout [`Shape`](@ref) to `p`. `row`/`col` restrict the shape to a
subplot cell; `"all"` applies it to every cell. Returns `p`.
"""
add_shape!

"""
	add_hline!(p, y; row = "all", col = "all", kwargs...)

Add a horizontal line [`Shape`](@ref) at `y` to `p`. `row`/`col` restrict it
to a subplot cell. Returns `p`.
"""
add_hline!

"""
	add_vline!(p, x; row = "all", col = "all", kwargs...)

Add a vertical line [`Shape`](@ref) at `x` to `p`. `row`/`col` restrict it to
a subplot cell. Returns `p`.
"""
add_vline!

"""
	add_hrect!(p, y0, y1; row = "all", col = "all", kwargs...)

Add a horizontal rectangle [`Shape`](@ref) spanning `y0`–`y1` (full x-range)
to `p`. `row`/`col` restrict it to a subplot cell. Returns `p`.
"""
add_hrect!

"""
	add_vrect!(p, x0, x1; row = "all", col = "all", kwargs...)

Add a vertical rectangle [`Shape`](@ref) spanning `x0`–`x1` (full y-range) to
`p`. `row`/`col` restrict it to a subplot cell. Returns `p`.
"""
add_vrect!

"""
	add_layout_image!(p, image; row = "all", col = "all")

Add a layout image (e.g. `attr(source = "...", x = ..., y = ...)`) to `p`.
`row`/`col` restrict it to a subplot cell. Returns `p`.
"""
add_layout_image!

"""
	add_recession_bands!(p; kwargs...)

Shade recession bands (vertical spans) on a time-series `Plot` or
[`SyncPlot`](@ref); `kwargs` are forwarded to the generated band shapes.
Returns the added shapes.
"""
add_recession_bands!

# ── Layout object updaters ──────────────────────────────────────────

for (fn, objs, desc) in (
	(:update_xaxes!, "`xaxis`", "x-axis"),
	(:update_yaxes!, "`yaxis`", "y-axis"),
	(:update_polars!, "`polar`", "polar"),
	(:update_scenes!, "`scene`", "3D scene"),
	(:update_ternaries!, "`ternary`", "ternary"),
	(:update_geos!, "`geo`", "geographic"),
	(:update_mapboxes!, "`mapbox`", "mapbox"),
)
	doc = """
		$(fn)(p, with::PlotlyAttribute = attr(); kwargs...)

	Apply the attribute update `with`/`kwargs` to every $(objs)-family layout
	object ($(objs), $(objs)2, …) of the $(desc) subplots in `p`, which may be a
	`Plot` or `Layout`; `SyncPlot` is supported for `update_xaxes!`,
	`update_yaxes!`, and `update_polars!`.
	"""
	@eval @doc $doc $fn
end

for (fn, objs) in (
	(:update_annotations!, "`annotations`"),
	(:update_images!, "`images`"),
	(:update_shapes!, "`shapes`"),
)
	doc = """
		$(fn)(p, with::PlotlyAttribute = attr(); kwargs...)

	Apply the attribute update `with`/`kwargs` to every entry of the
	$(objs) layout array of `p` (`Plot` or `Layout`).
	"""
	@eval @doc $doc $fn
end

# ── Colors, templates, grids ────────────────────────────────────────

"""
	colors

Registry of built-in color scales. Access a scale by name — `colors.inferno`
or `colors[:inferno]` — or list families via `colors.sequential`,
`colors.diverging`, `colors.cyclical`, `colors.discrete`, and `colors.all`.
"""
colors

"""
	templates

Registry of built-in `Template`s. `templates.available` lists template names,
`templates[:plotly_dark]` returns the `Template`, and `templates.default`
gets/sets the default template name.
"""
templates

"""
	meshgrid(x, y)
	meshgrid(x, y, z)

Build 2D or 3D coordinate grids from coordinate vectors `x`, `y` (and `z`),
re-exported from MeshGrid.jl.
"""
meshgrid

"""
	json(args...; kwargs...)

Serialize to JSON — re-exported from `JSON.jl` via PlotlyBase; e.g.
`json(p, 2)` pretty-prints a figure's JSON specification.
"""
json

"""
	L"..."

LaTeX string literal macro (re-exported from LaTeXStrings.jl) —
`L"\\sin(x)"` produces a string rendered as math in labels, titles, and
annotations.
"""
var"@L_str"

#endregion
