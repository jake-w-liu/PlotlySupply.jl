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
	# Also applies the default Cartesian axis styling (see api.jl).
	_apply_default_template!(p)
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

# ── savefig: formats, options and validation ────────────────────────

const _SAVEFIG_FORMATS = ("png", "jpeg", "tiff", "svg", "pdf", "eps", "html", "json")
# Formats drawn by plotly.js in the hidden Electron export window.
const _RENDERER_FORMATS = ("png", "jpeg", "tiff", "svg", "pdf", "eps")
# Formats captured as one image from the export window (TIFF is encoded from
# the PNG capture).
const _IMAGE_FORMATS = ("png", "jpeg", "tiff", "svg")
const _RASTER_FORMATS = ("png", "jpeg", "tiff")
const _EXPORT_KW = (
	:width,
	:height,
	:scale,
	:units,
	:dpi,
	:deterministic,
	:background,
	:tight,
	:timeout,
	:fonts,
)
const _EXPORT_FONT_MODES = (:auto, :embed, :outline)
# JPEG quality passed to canvas.toDataURL: Chromium's default, which
# plotly.js's toImage used by passing none (the export window's toDataURL
# with no quality and with 0.92 gave identical bytes), now stated explicitly
# so the documented quality does not depend on the browser default.
const _JPEG_QUALITY = 0.92
# Resolution of a TIFF export that gives neither `dpi` nor `scale`: TIFF is the
# raster format journals ask for, and 300 dpi is their usual minimum for
# figures (a 96-dpi TIFF would be unusable for print).
const _DEFAULT_TIFF_DPI = 300.0
# plotly.js declares layout.width/height with `min: 10` and silently replaces
# smaller values by its 700 x 450 default, so smaller export sizes are rejected.
const _PLOTLY_MIN_LAYOUT_PX = 10.0
# Export size used when neither the keywords nor layout.width/height give one
# (the 1.x default).
const _DEFAULT_EXPORT_WIDTH_PX = 700.0
const _DEFAULT_EXPORT_HEIGHT_PX = 500.0
# Bound on each renderer step (drawing, printToPDF, Ghostscript). It is large
# enough for multi-million-point figures and exists so a figure that can never
# finish drawing (e.g. a map style that never loads) cannot hold the export
# window, and its lock, forever.
const _DEFAULT_EXPORT_TIMEOUT_S = 300.0
const _TRANSPARENT_BACKGROUND = "rgba(0,0,0,0)"
# JSON has no NaN/Infinity. plotly.js treats `null` in data arrays as a gap,
# exactly like a non-finite number, so non-finite values are written as null.
const _JSON_NONFINITE_AS_NULL = (allownan = true, nan = "null", inf = "null", ninf = "null")

struct _ExportOptions
	width::Float64          # layout width in CSS px
	height::Float64         # layout height in CSS px
	scale::Float64          # user magnification (1 when absent)
	dpi::Union{Nothing,Float64}
	deterministic::Bool
	background::Union{Nothing,String}
	tight::Bool
	timeout::Float64        # seconds per renderer step
	units::Symbol           # unit the caller gave sizes in (:px, :in, :cm, :mm, :pt)
	scale_given::Bool       # `scale` was passed explicitly
	fonts::Symbol           # :auto, :embed or :outline (pdf/eps text)
end

struct _PreparedRendererExport
	data_js::String
	layout_js::String
	config_js::String
	options::_ExportOptions
end

struct _PreparedDocumentExport
	plot::Plot
	options::_ExportOptions
end

struct _CapturedPDF
	tempdir::String
	path::String
	owner_state::Union{Nothing,_ExportState}
end

_CapturedPDF(tempdir::String, path::String) =
	_CapturedPDF(tempdir, path, nothing)

# Raised when a renderer step exceeds `timeout`; the export window is retired
# because the page may still be busy with the abandoned figure.
struct _ExportTimeoutError <: Exception
	message::String
end

Base.showerror(io::IO, err::_ExportTimeoutError) = print(io, err.message)

# Unsupported formats keep raising `ErrorException`, as in 1.x.
function _validate_export_format(fmt::AbstractString)
	name = lowercase(String(fmt))
	name == "jpg" && return "jpeg"
	name == "tif" && return "tiff"
	name in _SAVEFIG_FORMATS || error(
		"savefig: unsupported export format $(repr(name)). Supported: " *
		"png, jpeg (or jpg), tiff (or tif), svg, pdf, eps, html, json.",
	)
	return name
end

function _filename_export_format(
	filename::AbstractString,
	format::Union{Nothing,AbstractString},
)
	ext = lowercase(splitext(filename)[2])
	inferred = isempty(ext) ? "png" : String(lstrip(ext, '.'))
	fmt = isnothing(format) ? inferred : String(format)
	return _validate_export_format(fmt)
end

function _normalize_export_number(name::Symbol, value)
	value isa Real && !(value isa Bool) ||
		throw(ArgumentError("savefig: `$name` must be a positive, finite, non-Bool real number; got $(repr(value))."))
	number = try
		Float64(value)
	catch
		throw(ArgumentError("savefig: `$name` must be representable as a finite number."))
	end
	isfinite(number) && number > 0 ||
		throw(ArgumentError("savefig: `$name` must be a positive, finite, non-Bool real number; got $(repr(value))."))
	return number
end

function _export_flag(kwargs, name::Symbol, default::Bool)
	value = get(kwargs, name, default)
	value isa Bool ||
		throw(ArgumentError("savefig: `$name` must be true or false; got $(repr(value))."))
	return value
end

function _normalize_export_timeout(value)
	value === nothing && return _DEFAULT_EXPORT_TIMEOUT_S
	(value isa Real && !(value isa Bool)) ||
		throw(ArgumentError("savefig: `timeout` must be a positive number of seconds; got $(repr(value))."))
	seconds = Float64(value)
	# The renderer enforces the bound with a browser timer, whose delay is a
	# signed 32-bit millisecond count.
	isfinite(seconds) && 0 < seconds <= _SYNCPLOT_MAX_STARTUP_TIMEOUT_SECONDS ||
		throw(ArgumentError(
			"savefig: `timeout` must be positive, finite and at most " *
			"$(_SYNCPLOT_MAX_STARTUP_TIMEOUT_SECONDS) s; got $(value).",
		))
	return seconds
end

const _CSS_HEX_COLOUR = r"^#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"
const _CSS_FUNCTIONAL_COLOUR =
	r"^(?:rgba?|hsla?|hsva?)\(\s*[-+0-9.e%]+\s*(?:,\s*[-+0-9.e%]+\s*){2,3}\)$"

function _is_export_colour(colour::String)
	occursin(_CSS_HEX_COLOUR, colour) && return true
	occursin(_CSS_FUNCTIONAL_COLOUR, lowercase(colour)) && return true
	return occursin(r"^[A-Za-z]+$", colour) &&
		   haskey(PlotlyBase.Colors.color_names, lowercase(colour))
end

function _normalize_export_background(background)
	background === nothing && return nothing
	text = if background isa Symbol
		String(background)
	elseif background isa AbstractString
		String(strip(background))
	else
		throw(ArgumentError(
			"savefig: `background` must be a colour string, a Symbol such as " *
			":white or :transparent, or nothing; got $(typeof(background)).",
		))
	end
	lowercase(text) in ("transparent", "none") && return _TRANSPARENT_BACKGROUND
	_is_export_colour(text) || throw(ArgumentError(
		"savefig: `background` $(repr(background)) is not a colour; use a CSS " *
		"name (\"white\"), \"#rrggbb\", \"rgb(r,g,b)\"/\"rgba(r,g,b,a)\" or :transparent.",
	))
	return text
end

# layout.width/height when they hold a size plotly.js would honour, else `default`.
function _layout_export_px(p::Plot, key::Symbol, default::Float64)
	value = get(p.layout.fields, key, nothing)
	value isa Real && !(value isa Bool) || return default
	number = Float64(value)
	isfinite(number) && number >= _PLOTLY_MIN_LAYOUT_PX || return default
	return number
end

function _export_length(p::Plot, kwargs, key::Symbol, units::Symbol, default::Float64)
	value = get(kwargs, key, nothing)
	value === nothing && return _layout_export_px(p, key, default)
	number = _normalize_export_number(key, value)
	px = _physical_to_px(number, units)
	isfinite(px) || throw(ArgumentError("savefig: `$key` is too large."))
	px >= _PLOTLY_MIN_LAYOUT_PX || throw(ArgumentError(
		"savefig: `$key` = $(value) $(units) is $(px) px, below plotly.js's " *
		"$(Int(_PLOTLY_MIN_LAYOUT_PX)) px layout minimum.",
	))
	return px
end

# Size of a figure that carries no layout.width/height and gets no size
# keyword: the active style's default figure size (publication-style's
# `_style_default_figure_size`, CSS px), else the 1.x default 700 x 500 px.
function _export_default_size()
	isdefined(@__MODULE__, :_style_default_figure_size) ||
		return (_DEFAULT_EXPORT_WIDTH_PX, _DEFAULT_EXPORT_HEIGHT_PX)
	size = Base.invokelatest(_style_default_figure_size)
	valid(x) = x isa Real && !(x isa Bool) && isfinite(x) && x >= _PLOTLY_MIN_LAYOUT_PX
	size isa Tuple{Real,Real} && valid(size[1]) && valid(size[2]) || throw(ArgumentError(
		"savefig: the active style's default figure size $(repr(size)) is not a pair " *
		"of finite sizes of at least $(Int(_PLOTLY_MIN_LAYOUT_PX)) px.",
	))
	return (Float64(size[1]), Float64(size[2]))
end

function _normalize_export_fonts(value)
	value === nothing && return :auto
	value isa Symbol && value in _EXPORT_FONT_MODES && return value
	throw(ArgumentError(
		"savefig: `fonts` must be :auto, :embed or :outline; got $(repr(value)).",
	))
end

function _normalize_export_options(p::Plot, kwargs)
	for key in keys(kwargs)
		key in _EXPORT_KW || throw(ArgumentError(
			"savefig: unsupported keyword argument `$key`. Supported: format, " *
			"$(join(_EXPORT_KW, ", ")).",
		))
	end
	units = get(kwargs, :units, :px)
	units isa Symbol || throw(ArgumentError(
		"savefig: `units` must be :px, :in, :cm, :mm or :pt; got $(repr(units)).",
	))
	_export_units_per_inch(units, "savefig")
	default_width, default_height = _export_default_size()
	width = _export_length(p, kwargs, :width, units, default_width)
	height = _export_length(p, kwargs, :height, units, default_height)

	scale_value = get(kwargs, :scale, nothing)
	scale = scale_value === nothing ? 1.0 : _normalize_export_number(:scale, scale_value)
	dpi_value = get(kwargs, :dpi, nothing)
	dpi = dpi_value === nothing ? nothing : _validated_export_dpi(dpi_value, "savefig")
	dpi !== nothing && scale_value !== nothing && throw(ArgumentError(
		"savefig: pass either `dpi` or `scale`, not both (`dpi` sets the raster " *
		"scale to dpi / 96).",
	))
	# Every magnification a format of this call can use: `scale` for all
	# formats (and the 300-dpi TIFF default when neither is given), or dpi / 96
	# for raster and 1 for vector output.
	scales = if dpi !== nothing
		(dpi / _CSS_PX_PER_INCH, 1.0)
	elseif scale_value === nothing
		(scale, _DEFAULT_TIFF_DPI / _CSS_PX_PER_INCH)
	else
		(scale,)
	end
	for factor in scales, (name, size) in (("width", width), ("height", height))
		scaled = size * factor
		isfinite(scaled) || throw(ArgumentError(
			"savefig: $(name) * scale must be finite; got $(size) * $(factor).",
		))
		scaled >= 1 || throw(ArgumentError(
			"savefig: $(name) * scale must be at least 1 px; got $(scaled).",
		))
	end

	tight = _export_flag(kwargs, :tight, false)
	# `tight_layout!` comes from the sci style extension (sci/style.jl); a build
	# without it must fail here, before any file is touched.
	tight && !isdefined(@__MODULE__, :tight_layout!) && throw(ArgumentError(
		"savefig: `tight = true` requires `tight_layout!`, which this build does not define.",
	))

	return _ExportOptions(
		width,
		height,
		scale,
		dpi,
		_export_flag(kwargs, :deterministic, true),
		_normalize_export_background(get(kwargs, :background, nothing)),
		tight,
		_normalize_export_timeout(get(kwargs, :timeout, nothing)),
		units,
		scale_value !== nothing,
		_normalize_export_fonts(get(kwargs, :fonts, nothing)),
	)
end

# Magnification used for `fmt`: `dpi` sets the raster resolution (scale =
# dpi / 96) and leaves vector output at its physical size; a TIFF without
# `dpi` or `scale` is drawn at 300 dpi.
function _format_scale(options::_ExportOptions, fmt::AbstractString)
	if options.dpi === nothing
		fmt == "tiff" && !options.scale_given && return _DEFAULT_TIFF_DPI / _CSS_PX_PER_INCH
		return options.scale
	end
	return fmt in _RASTER_FORMATS ? options.dpi / _CSS_PX_PER_INCH : 1.0
end

# Resolution recorded in a raster file (PNG pHYs, JPEG JFIF density, TIFF
# X/YResolution): `dpi` when given, else 96 * scale whenever the size has a
# physical meaning (a TIFF, or `units` other than :px); `nothing` (no
# metadata, as in 1.x) for a pixel-sized PNG/JPEG.
function _format_dpi(options::_ExportOptions, fmt::AbstractString)
	fmt in _RASTER_FORMATS || return nothing
	options.dpi === nothing || return options.dpi
	(fmt == "tiff" || options.units !== :px) || return nothing
	return _CSS_PX_PER_INCH * _format_scale(options, fmt)
end

# Device pixels of a raster export of `fmt`: the layout size times the
# format's scale, rounded to the nearest pixel.
_format_pixels(options::_ExportOptions, fmt::AbstractString) = (
	_raster_pixels(options.width, _format_scale(options, fmt)),
	_raster_pixels(options.height, _format_scale(options, fmt)),
)

# ── savefig: the export copy ─────────────────────────────────────────
# The caller's figure is never mutated: `tight` runs on a deep copy, and
# backgrounds and deterministic trace uids are written into the freshly
# lowered JSON objects that are serialized for the renderer.

# `pan = false` for HTML/JSON documents: their scene cameras are not panned
# (centre at the box centre, the pivot of interactive rotation, Z43).
function _export_source(p::Plot, options::_ExportOptions; pan::Bool = true)
	options.tight || return _finalize_export_copy(p, options; pan = pan)
	options.tight || return p
	export_copy = _clone_plot_model(p)
	tight_layout!(export_copy)
	_finalize_figure!(export_copy; size = (options.width, options.height))
	_s3_refit_scenes!(export_copy, p, (options.width, options.height); pan = pan)
	return export_copy
end

function _lowered_get(object::AbstractDict, key::Symbol, default = nothing)
	haskey(object, key) && return object[key]
	haskey(object, String(key)) && return object[String(key)]
	return default
end

# Set `key`, removing a String spelling of the same key so the JSON output
# never carries it twice.
function _lowered_set!(object::AbstractDict, key::Symbol, value)
	haskey(object, String(key)) && delete!(object, String(key))
	object[key] = value
	return object
end

# Replace the nested object at `key` by a shallow copy (so objects the caller
# still owns are never written) and return the copy.
function _lowered_child!(object::AbstractDict, key::Symbol)
	child = _lowered_get(object, key)
	copied = child isa AbstractDict ? Dict{Any,Any}(child) : Dict{Any,Any}()
	_lowered_set!(object, key, copied)
	return copied
end

const _BACKGROUND_SUBPLOT_KEY = r"^(?:scene|polar|ternary|geo|smith)[0-9]*$"
# Trace type => (attribute naming its subplot, default subplot).
const _BACKGROUND_SUBPLOT_TRACES = Dict{String,Tuple{Symbol,String}}(
	"scatter3d" => (:scene, "scene"),
	"surface" => (:scene, "scene"),
	"mesh3d" => (:scene, "scene"),
	"cone" => (:scene, "scene"),
	"streamtube" => (:scene, "scene"),
	"volume" => (:scene, "scene"),
	"isosurface" => (:scene, "scene"),
	"scatterpolar" => (:subplot, "polar"),
	"scatterpolargl" => (:subplot, "polar"),
	"barpolar" => (:subplot, "polar"),
	"scatterternary" => (:subplot, "ternary"),
	"scattergeo" => (:geo, "geo"),
	"choropleth" => (:geo, "geo"),
	"scattersmith" => (:subplot, "smith"),
)

# `background` paints the figure (paper) background. `:transparent` also
# clears the plot area and every 3-D scene, polar, ternary, geo and smith
# background, so nothing opaque remains behind the data.
function _apply_export_background!(layout::AbstractDict, data::AbstractVector, background::String)
	_lowered_set!(layout, :paper_bgcolor, background)
	background == _TRANSPARENT_BACKGROUND || return layout
	_lowered_set!(layout, :plot_bgcolor, background)
	subplots = Set{String}()
	for key in keys(layout)
		name = string(key)
		occursin(_BACKGROUND_SUBPLOT_KEY, name) && push!(subplots, name)
	end
	for trace in data
		trace isa AbstractDict || continue
		spec = get(_BACKGROUND_SUBPLOT_TRACES, string(_lowered_get(trace, :type, "scatter")), nothing)
		spec === nothing && continue
		reference = _lowered_get(trace, spec[1], spec[2])
		reference isa AbstractString && occursin(_BACKGROUND_SUBPLOT_KEY, reference) &&
			push!(subplots, String(reference))
	end
	for name in subplots
		_lowered_set!(_lowered_child!(layout, Symbol(name)), :bgcolor, background)
	end
	return layout
end

# plotly.js derives SVG ids and colorbar classes from each trace's random
# `uid`. Fixed uids ("t0", "t1", …, skipping any uid the user set) make
# repeated exports byte-identical.
function _assign_export_uids!(data::AbstractVector)
	used = Set{String}()
	for trace in data
		trace isa AbstractDict || continue
		uid = _lowered_get(trace, :uid)
		uid === nothing || push!(used, string(uid))
	end
	counter = 0
	for trace in data
		trace isa AbstractDict || continue
		_lowered_get(trace, :uid) === nothing || continue
		candidate = "t$(counter)"
		while candidate in used
			counter += 1
			candidate = "t$(counter)"
		end
		counter += 1
		push!(used, candidate)
		_lowered_set!(trace, :uid, candidate)
	end
	return data
end

function _prepare_renderer_export(
	p::Plot,
	kwargs;
	options::Union{Nothing,_ExportOptions} = nothing,
	source::Union{Nothing,Plot} = nothing,
)
	resolved = options === nothing ? _normalize_export_options(p, kwargs) : options
	figure = source === nothing ? _export_source(p, resolved) : source
	data = Any[PlotlyBase.JSON.lower(trace) for trace in figure.data]
	layout = PlotlyBase.JSON.lower(figure.layout)
	resolved.background === nothing ||
		_apply_export_background!(layout, data, resolved.background)
	resolved.deterministic && _assign_export_uids!(data)
	_scat_export_line_simplify!(data)
	return _PreparedRendererExport(
		_json_js(data),
		_json_js(layout),
		_json_js(figure.config),
		resolved,
	)
end

function _prepare_document_export(
	p::Plot,
	kwargs;
	options::Union{Nothing,_ExportOptions} = nothing,
	source::Union{Nothing,Plot} = nothing,
)
	resolved = options === nothing ? _normalize_export_options(p, kwargs) : options
	figure = source === nothing ? _export_source(p, resolved; pan = false) : source
	return _PreparedDocumentExport(figure, resolved)
end

# Validate everything for `formats` (keywords, Ghostscript for EPS and for
# `fonts = :outline` PDF) and build the export copy once. Nothing is drawn and
# no destination is touched.
function _prepare_export(p::Plot, formats, kwargs)
	options = _normalize_export_options(p, kwargs)
	("eps" in formats || ("pdf" in formats && options.fonts === :outline)) &&
		_ghostscript_command()
	wants_renderer = any(in(_RENDERER_FORMATS), formats)
	wants_document = any(in(("html", "json")), formats)
	source = _export_source(p, options; pan = wants_renderer)
	# A document keeps its scene centres; with scenes it needs its own copy.
	document_source = (wants_renderer && wants_document &&
		any(key -> key isa Symbol && occursin(_S3_SCENE_KEY, String(key)), keys(p.layout.fields))) ?
		_export_source(p, options; pan = false) : source
	renderer = wants_renderer ?
		_prepare_renderer_export(p, kwargs; options = options, source = source) : nothing
	document = wants_document ?
		_prepare_document_export(p, kwargs; options = options, source = document_source) : nothing
	return (renderer = renderer, document = document)
end

function _prepare_savefig(p::Plot, fmt::String, kwargs)
	prepared = _prepare_export(p, (fmt,), kwargs)
	return fmt in _RENDERER_FORMATS ? prepared.renderer : prepared.document
end

# ── savefig: HTML and JSON ──────────────────────────────────────────

# JSON for inline <script> blocks of a standalone HTML page. Besides writing
# non-finite numbers as null, every "<", ">" and "&" becomes a \u escape:
# those characters can only occur inside JSON strings, where the escape
# decodes to the same character, and without them no user text can form
# "</script>", "<!--" or "<script" and change how the HTML parser ends the
# block. U+2028/U+2029 are escaped for pre-ES2019 JavaScript parsers.
function _json_html(x)
	json = PlotlyBase.JSON.json(x; _JSON_NONFINITE_AS_NULL...)
	return replace(
		json,
		"<" => "\\u003c",
		">" => "\\u003e",
		"&" => "\\u0026",
		" " => "\\u2028",
		" " => "\\u2029",
	)
end

function _html_attribute(text::AbstractString)
	return replace(
		String(text),
		"&" => "&amp;",
		"<" => "&lt;",
		">" => "&gt;",
		"\"" => "&quot;",
		"'" => "&#39;",
	)
end

# CSS size of the figure div: layout.width/height in px when they are valid
# plotly sizes, else `default` (the figure then fills the page).
function _html_css_length(value, default::String)
	value isa Real && !(value isa Bool) || return default
	number = Float64(value)
	isfinite(number) && number >= _PLOTLY_MIN_LAYOUT_PX || return default
	return string(number, "px")
end

"""
	_savefig_html(io::IO, p::Plot; background = nothing)

Write `p` as a standalone HTML page. The page embeds the bundled plotly.js
$(_PLOTLYJS_VERSION) that desktop plots and image exports render with (so it
draws exactly like them and needs no network for plotly.js) and loads MathJax
2.7.9 from its CDN when it is opened. Non-finite numbers become `null` and
every embedded JSON blob is escaped so user text cannot end the inline script.
"""
function _savefig_html(io::IO, p::Plot; background::Union{Nothing,String} = nothing)
	lowered = PlotlyBase.JSON.lower(p)
	data = lowered[:data]
	layout = lowered[:layout]
	frames = lowered[:frames]
	config = lowered[:config]
	background === nothing || _apply_export_background!(layout, data, background)
	get!(config, :responsive, true)

	base_url_line = ""
	if p.config.showLink === true || p.config.showEditInChartStudio === true
		url = something(p.config.plotlyServerURL, "https://plot.ly")
		base_url_line = "window.PLOTLYENV.BASE_URL = $(_json_html(url));\n"
	else
		for key in (:plotlyServerURL, :linkText, :showLink)
			haskey(config, key) && delete!(config, key)
		end
	end

	then_frames = isempty(frames) ? "" :
		".then(function () { return Plotly.addFrames(gd, $(_json_html(frames))); })" *
		".then(function () { return Plotly.animate(gd, null); })"
	div_width = _html_css_length(_lowered_get(layout, :width), "100%")
	div_height = _html_css_length(_lowered_get(layout, :height), "100%")
	divid = string(p.divid)
	# The same patched Plotly.js that desktop plots and image exports use, so
	# the saved page draws mathematical legends and text exactly like them.
	plotlyjs_script = _compatible_plotlyjs_inline_script()

	print(
		io,
		"""
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <style>html, body { margin: 0; padding: 0; height: 100%; }</style>
  <script type="text/javascript">window.PlotlyConfig = {MathJaxConfig: 'local'};</script>
$(_mathjax_head_html())
$(plotlyjs_script)
</head>
<body>
  <div id="$(_html_attribute(divid))" class="plotly-graph-div" style="height:$(div_height); width:$(div_width);"></div>
  <script type="text/javascript">
window.PLOTLYENV = window.PLOTLYENV || {};
$(base_url_line)(function () {
  var gd = document.getElementById($(_json_html(divid)));
  if (!gd) { return; }
  Plotly.newPlot(gd, $(_json_html(data)), $(_json_html(layout)), $(_json_html(config)))$(then_frames);
})();
  </script>
</body>
</html>
""",
	)
	return nothing
end

function _savefig_json(io::IO, p::Plot; background::Union{Nothing,String} = nothing)
	if background === nothing
		PlotlyBase.JSON.json(io, p; _JSON_NONFINITE_AS_NULL...)
	else
		lowered = PlotlyBase.JSON.lower(p)
		_apply_export_background!(lowered[:layout], lowered[:data], background)
		PlotlyBase.JSON.json(io, lowered; _JSON_NONFINITE_AS_NULL...)
	end
	return nothing
end

function _document_bytes(fmt::String, prepared::_PreparedDocumentExport)
	buffer = IOBuffer()
	background = prepared.options.background
	if fmt == "html"
		_savefig_html(buffer, prepared.plot; background = background)
	else
		_savefig_json(buffer, prepared.plot; background = background)
	end
	return take!(buffer)
end

# ── savefig: renderer scripts ───────────────────────────────────────

# Wrap the async renderer `body` (which may use `div`) so it always settles:
# with its result, with `{error: message}` when it throws, or with
# `{error, timeout: true}` once `timeout_s` elapses. A settled promise
# releases the Electron request (and with it the export lock) even when
# plotly.js never finishes drawing.
function _guarded_export_script(divid::String, timeout_s::Float64, body::String)
	timeout_ms = _json_js(round(Int64, timeout_s * 1000))
	timeout_text = _json_js("drawing the figure did not finish within $(timeout_s) s")
	return """
(async function() {
  const div = document.getElementById($(_json_js(divid)));
  if (!div) { return {error: 'the export plot div was not found'}; }
  let timer = null;
  const deadline = new Promise(function(resolve) {
    timer = setTimeout(function() { resolve({__plotlysupply_timeout: true}); }, $timeout_ms);
  });
  const work = (async function() {
$body
  })();
  work.catch(function() {});
  try {
    const result = await Promise.race([work, deadline]);
    if (result && result.__plotlysupply_timeout === true) {
      return {error: $timeout_text, timeout: true};
    }
    return result;
  } catch (err) {
    return {error: String((err && err.message) || err)};
  } finally {
    clearTimeout(timer);
  }
})();
"""
end

# Each export starts from a purged div and `Plotly.newPlot`, so no state
# (axis constraints, colorbar groups, transforms, animations) of an earlier,
# unrelated export can leak into this one.
const _EXPORT_RESET_DIV_JS = """
    div.style.transform = '';
    div.style.transformOrigin = '';
    div.style.width = '';
    div.style.height = '';
    Plotly.purge(div);
"""

function _check_renderer_result(result, what::AbstractString)
	result isa AbstractDict || return result
	haskey(result, "error") || return result
	message = string(result["error"])
	if get(result, "timeout", false) === true
		throw(_ExportTimeoutError(
			"savefig: $(message) while $(what); pass a larger `timeout` " *
			"(seconds) to savefig if the figure is just slow to draw.",
		))
	end
	error("savefig: plotly.js failed while $(what): $(message)")
end

# Size, in UTF-16 code units, above which a rendered image is fetched from the
# export window in slices of this size. One ElectronCall reply takes time
# that grows faster than its length (measured: 2 Mi characters 0.05 s, 8 Mi
# 0.6 s, 32 Mi 7.7 s, 140 Mi 153 s) and a 170-Mi-character reply (the SVG of a
# 10^6-marker scatter) crashed the renderer with a V8 out-of-memory error;
# 2 Mi-character slices were the fastest measured (~40 MiB/s).
const _RENDERER_RESULT_CHUNK = 2^21

# The end of an image script: a `result` string up to one slice long is
# returned as it is; a longer one is kept in the page and its length returned,
# for `_fetch_renderer_result`.
const _RENDERER_RESULT_HANDOFF_JS = """
    if (typeof result !== 'string' || result.length <= $(_RENDERER_RESULT_CHUNK)) { return result; }
    window.__plotlysupplyExportResult = result;
    window.__plotlysupplyExportResultPos = 0;
    return {resultLength: result.length};
"""

# The next slice of the kept result as `[text, done]`; the last slice also
# releases it. A slice never ends between the two halves of a UTF-16
# surrogate pair (a lone half would not survive the JSON reply).
const _FETCH_RESULT_SLICE_JS = """
(function() {
  const s = window.__plotlysupplyExportResult;
  if (typeof s !== 'string') {
    return {error: 'the rendered image is no longer held by the export window'};
  }
  const start = window.__plotlysupplyExportResultPos || 0;
  let stop = Math.min(s.length, start + $(_RENDERER_RESULT_CHUNK));
  if (stop < s.length) {
    const unit = s.charCodeAt(stop - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) { stop -= 1; }
  }
  const done = stop >= s.length;
  if (done) {
    delete window.__plotlysupplyExportResult;
    delete window.__plotlysupplyExportResultPos;
  } else {
    window.__plotlysupplyExportResultPos = stop;
  }
  return [s.slice(start, stop), done];
})()
"""

# Fetch a rendered image of `total` UTF-16 code units that the image script
# kept in the export window, slice by slice.
function _fetch_renderer_result(ec, win, total, fmt::String)
	(total isa Real && !(total isa Bool) && isinteger(total) && total > _RENDERER_RESULT_CHUNK) || error(
		"savefig: the renderer reported an invalid $(fmt) image length $(repr(total)).",
	)
	# Every slice but the last holds at least _RENDERER_RESULT_CHUNK - 1 units.
	max_slices = cld(Int(total), _RENDERER_RESULT_CHUNK - 1) + 1
	io = IOBuffer()
	for _ in 1:max_slices
		reply = _check_renderer_result(
			Base.invokelatest(() -> ec.run(win, _FETCH_RESULT_SLICE_JS)),
			"fetching the rendered $(fmt) image",
		)
		(reply isa AbstractVector && length(reply) == 2 && reply[1] isa AbstractString &&
		 reply[2] isa Bool) || error(
			"savefig: unexpected reply while fetching the rendered $(fmt) image: " *
			"$(summary(reply)).",
		)
		write(io, reply[1])
		reply[2] && return String(take!(io))
		isempty(reply[1]) &&
			error("savefig: the export window returned an empty slice of the $(fmt) image.")
	end
	error("savefig: the rendered $(fmt) image did not arrive in $(max_slices) slices.")
end

# Draw the figure once with `Plotly.toImage` on the plain figure object (it
# lays the figure out in its own hidden div; drawing into the export div
# first would draw everything twice). svg is returned as the SVG markup, a
# raster as a data URL; a result longer than `_RENDERER_RESULT_CHUNK` is
# fetched in slices.
# Raster formats are rasterized here, not by toImage: toImage sizes its canvas
# as width*scale and the canvas truncates that to an integer (6.35 cm at
# 300 dpi, 749.9999999999999, would give 749 px). The SVG is drawn onto a canvas of exactly
# `_format_pixels` device pixels instead, so the pixel count is the nearest
# integer and the drawing fills it. JPEG has no alpha: transparent areas are
# composited onto white (a bare canvas would encode them black). A TIFF is
# captured as PNG and encoded in Julia.
function _capture_image_data_url(
	ec,
	win,
	divid::String,
	prepared::_PreparedRendererExport,
	fmt::String,
)
	options = prepared.options
	scale = _format_scale(options, fmt)
	width_js = _json_js(options.width)
	height_js = _json_js(options.height)
	raster = fmt != "svg"
	pixels_w, pixels_h = raster ? _format_pixels(options, fmt) : (0, 0)
	draw = """
$(_EXPORT_RESET_DIV_JS)
    // A result an earlier export left behind (its fetch failed) is dropped.
    delete window.__plotlysupplyExportResult;
    delete window.__plotlysupplyExportResultPos;
    const scale = $(_json_js(scale));
    const layout = Object.assign({}, $(prepared.layout_js), {width: $width_js, height: $height_js});
    const config = Object.assign({}, $(prepared.config_js));
    // WebGL canvases (3-D scenes, maps) are embedded as bitmaps; give them
    // proportionally more pixels at a raster scale above 1 (plotly.js accepts
    // plotGlPixelRatio in [1, 4] and defaults to 2).
    if ($(_json_js(raster)) && scale > 1 && config.plotGlPixelRatio == null) {
      config.plotGlPixelRatio = Math.min(4, 2 * scale);
    }
    const figure = {data: $(prepared.data_js), layout: layout, config: config};
"""
	body = if !raster
		# imageDataOnly: the SVG markup itself, not plotly.js's
		# encodeURIComponent data URL, which is up to three times longer.
		draw * """
    const result = await Plotly.toImage(figure, {
      format: 'svg', width: $width_js, height: $height_js, scale: scale, imageDataOnly: true
    });
$(_RENDERER_RESULT_HANDOFF_JS)
"""
	else
		draw * """
    const svg = await Plotly.toImage(figure, {
      format: 'svg', width: $width_js, height: $height_js, scale: 1, imageDataOnly: true
    });
    const pixelsW = $(_json_js(pixels_w));
    const pixelsH = $(_json_js(pixels_h));
    // Give the SVG an intrinsic size of exactly pixelsW x pixelsH (its viewBox,
    // the layout in CSS px, is stretched to it by at most half a pixel), so it
    // is drawn 1:1. Drawn from its fractional layout size instead, Chromium
    // leaves the edge rows and columns of the canvas partly transparent.
    const root = /<svg\\b[^>]*>/.exec(svg);
    if (!root) { throw new Error('the exported SVG has no <svg> element'); }
    let tag = root[0]
      .replace(/(\\s)width="[^"]*"/, function(m, space) { return space + 'width="' + pixelsW + '"'; })
      .replace(/(\\s)height="[^"]*"/, function(m, space) { return space + 'height="' + pixelsH + '"'; });
    if (!/\\sviewBox="/.test(tag)) {
      tag = tag.slice(0, -1) + ' viewBox="0 0 ' + $width_js + ' ' + $height_js + '">';
    }
    tag = tag.slice(0, -1) + ' preserveAspectRatio="none">';
    const sized = svg.slice(0, root.index) + tag + svg.slice(root.index + root[0].length);
    const canvas = document.createElement('canvas');
    canvas.width = pixelsW;
    canvas.height = pixelsH;
    const ctx = canvas.getContext('2d');
    if (!ctx || canvas.width !== pixelsW || canvas.height !== pixelsH) {
      return 'data:,';
    }
    const url = URL.createObjectURL(new Blob([sized], {type: 'image/svg+xml;charset=utf-8'}));
    try {
      const img = new Image();
      await new Promise(function(resolve, reject) {
        img.onload = resolve;
        img.onerror = function() { reject(new Error('the exported SVG could not be decoded as an image')); };
        img.src = url;
      });
      if ($(_json_js(fmt == "jpeg"))) {
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(0, 0, pixelsW, pixelsH);
      }
      ctx.drawImage(img, 0, 0, pixelsW, pixelsH);
    } finally {
      URL.revokeObjectURL(url);
    }
    const result = $(fmt == "jpeg" ?
		"canvas.toDataURL('image/jpeg', $(_JPEG_QUALITY))" : "canvas.toDataURL('image/png')");
$(_RENDERER_RESULT_HANDOFF_JS)
"""
	end
	js = _guarded_export_script(divid, options.timeout, body)
	result = Base.invokelatest(() -> ec.run(win, js))
	reply = _check_renderer_result(result, "rendering the $(fmt) image")
	data_url = reply isa AbstractDict && haskey(reply, "resultLength") ?
		_fetch_renderer_result(ec, win, reply["resultLength"], fmt) : reply
	data_url isa AbstractString ||
		error("Plotly.toImage returned a non-string value for format '$fmt'")
	if data_url == "data:,"
		error(
			"savefig: the renderer returned an empty $(fmt) image (\"data:,\"). " *
			"The requested canvas is $(pixels_w) x $(pixels_h) px (width*scale x " *
			"height*scale), which exceeds the renderer's canvas limit; reduce " *
			"width, height, scale or dpi.",
		)
	end
	# ElectronCall normally returns String. This conversion is zero-copy for
	# String and preserves compatibility with other AbstractString adapters.
	return String(data_url)
end

function _write_image_data_url!(io::IO, data_url::String, fmt::String)
	if fmt == "svg"
		prefix = "data:image/svg+xml,"
		if startswith(data_url, "<svg")
			# The markup itself (`imageDataOnly`), as the capture script returns it.
			write(io, data_url)
		elseif startswith(data_url, prefix)
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

# Decode a captured data URL and apply the per-format post-processing: the
# resolution (`_format_dpi`) in the PNG pHYs chunk / JPEG JFIF density / TIFF
# tags, TIFF encoding of the PNG capture, stable SVG ids for `deterministic`,
# and an SVG width/height in the caller's physical `units`.
function _finalize_image(data_url::String, fmt::String, options::_ExportOptions)
	buffer = IOBuffer()
	_write_image_data_url!(buffer, data_url, fmt == "tiff" ? "png" : fmt)
	bytes = take!(buffer)
	dpi = _format_dpi(options, fmt)
	if fmt == "png"
		# The capture script already refuses a canvas of any other size.
		dpi === nothing || (bytes = _png_set_phys(bytes, dpi))
	elseif fmt == "tiff"
		width, height, channels, pixels = _png_decode(bytes)
		expected = _format_pixels(options, fmt)
		(width, height) == expected || error(
			"savefig: the renderer drew a $(width) x $(height) px image; expected " *
			"$(expected[1]) x $(expected[2]) px.",
		)
		bytes = _tiff_encode(width, height, channels, pixels, dpi)
	elseif fmt == "jpeg"
		dpi === nothing || (bytes = _jpeg_set_density(bytes, dpi))
	elseif fmt == "svg"
		svg = String(bytes)
		options.deterministic && (svg = _svg_canonical_root(_svg_stable_ids(svg)))
		if options.units !== :px
			scale = _format_scale(options, fmt)
			svg = _svg_set_physical_size(svg, options.width * scale, options.height * scale, options.units)
		end
		bytes = collect(codeunits(svg))
	end
	return bytes
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
	error(
		"printToPDF timed out after $(timeout)s; pass a larger `timeout` " *
		"(seconds) to savefig.",
	)
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

# Chromium printToPDF encodes SVG linearGradient fills as PDF shading
# patterns, which some viewers render as a flat end color. Expand every
# colorbar gradient fill into discrete flat rects instead. It runs right after
# `Plotly.newPlot` on a purged div, so only the current figure's colorbars
# exist and nothing from an earlier export is left in the printed DOM.
const _FLATTEN_COLORBAR_GRADIENTS_JS = """
    (function flattenColorbarGradients() {
      var NS = 'http://www.w3.org/2000/svg';
      function parseCol(c) {
        c = (c || '').trim();
        if (c.charAt(0) === '#') {
          var h = c.slice(1);
          if (h.length === 3) h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
          var v = parseInt(h.slice(0, 6), 16);
          return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
        }
        var i0 = c.indexOf('('), i1 = c.indexOf(')');
        if (i0 > -1 && i1 > i0) {
          var p = c.slice(i0 + 1, i1).split(',');
          return [+p[0], +p[1], +p[2]];
        }
        return [0, 0, 0];
      }
      function sample(stops, t) {
        if (t <= stops[0][0]) return stops[0];
        if (t >= stops[stops.length - 1][0]) return stops[stops.length - 1];
        for (var i = 0; i < stops.length - 1; i++) {
          var a = stops[i], b = stops[i + 1];
          if (t >= a[0] && t <= b[0]) {
            var u = b[0] > a[0] ? (t - a[0]) / (b[0] - a[0]) : 0;
            var A = parseCol(a[1]), B = parseCol(b[1]);
            return [t, 'rgb(' + Math.round(A[0] + u * (B[0] - A[0])) + ',' +
                   Math.round(A[1] + u * (B[1] - A[1])) + ',' +
                   Math.round(A[2] + u * (B[2] - A[2])) + ')',
                   a[2] + u * (b[2] - a[2])];
          }
        }
        return stops[stops.length - 1];
      }
      div.querySelectorAll('.cbfills *').forEach(function(el) {
        var fv = (el.style && el.style.fill) || el.getAttribute('fill') || '';
        var ui = fv.indexOf('url('), hi = fv.indexOf('#', ui), ei = fv.indexOf(')', hi);
        if (ui === -1 || hi === -1 || ei === -1) return;
        var id = fv.slice(hi + 1, ei).split('"').join('').split("'").join('');
        var lg = document.getElementById(id);
        if (!lg || lg.tagName.toLowerCase() !== 'lineargradient') return;
        var stops = [];
        lg.querySelectorAll('stop').forEach(function(s) {
          var off = s.getAttribute('offset') || '0';
          off = off.indexOf('%') > -1 ? parseFloat(off) / 100 : parseFloat(off);
          var col = s.getAttribute('stop-color') || s.style.stopColor ||
                    (getComputedStyle(s).stopColor);
          var op = s.getAttribute('stop-opacity');
          if (op === null && s.style && s.style.stopOpacity) op = s.style.stopOpacity;
          stops.push([off, col, op === null ? 1 : parseFloat(op)]);
        });
        if (stops.length < 2) return;
        stops.sort(function(a, b) { return a[0] - b[0]; });
        var bb = el.getBBox();
        var units = lg.getAttribute('gradientUnits') || 'objectBoundingBox';
        var x1 = parseFloat(lg.getAttribute('x1') || '0'),
            y1 = parseFloat(lg.getAttribute('y1') || '0'),
            x2 = parseFloat(lg.getAttribute('x2') || '0'),
            y2 = parseFloat(lg.getAttribute('y2') || '0');
        if (units !== 'userSpaceOnUse') {
          x1 = bb.x + x1 * bb.width; x2 = bb.x + x2 * bb.width;
          y1 = bb.y + y1 * bb.height; y2 = bb.y + y2 * bb.height;
        }
        var vert = Math.abs(y2 - y1) >= Math.abs(x2 - x1);
        var N = 128, g = document.createElementNS(NS, 'g');
        for (var i = 0; i < N; i++) {
          var sc = sample(stops, (i + 0.5) / N);
          var r = document.createElementNS(NS, 'rect');
          if (vert) {
            var ya = y1 + (i / N) * (y2 - y1), yb = y1 + ((i + 1) / N) * (y2 - y1);
            r.setAttribute('x', bb.x); r.setAttribute('width', bb.width);
            r.setAttribute('y', Math.min(ya, yb));
            r.setAttribute('height', Math.abs(yb - ya) + 0.3);
          } else {
            var xa = x1 + (i / N) * (x2 - x1), xb = x1 + ((i + 1) / N) * (x2 - x1);
            r.setAttribute('y', bb.y); r.setAttribute('height', bb.height);
            r.setAttribute('x', Math.min(xa, xb));
            r.setAttribute('width', Math.abs(xb - xa) + 0.3);
          }
          r.setAttribute('fill', sc[1]);
          if (sc[2] < 1) r.setAttribute('fill-opacity', sc[2]);
          g.appendChild(r);
        }
        el.parentNode.insertBefore(g, el);
        el.remove();
      });
    })();
"""

# EPS has no transparency, and Ghostscript's eps2write either renders a page
# with transparency to one bitmap or (-dNOTRANSPARENCY, which savefig uses)
# paints every translucent colour at full strength. Before the EPS page is
# printed, every translucent fill, stroke and text colour is therefore
# replaced by its blend over the background it is drawn on: the subplot's
# plot background inside a cartesian plot area, else the paper background
# (a translucent background is itself blended over white paper). Element and
# group `opacity` is folded into those colours. Images (heatmaps) are
# composited onto that background at their opacity, which also makes
# transparent pixels (NaN cells) the background colour. What is NOT
# reproduced: translucent marks over other marks (they cover them instead of
# letting them show through) and translucent gradient stops other than
# colorbars. Elements in <defs>/<clipPath>/<mask>/<pattern>/<marker>/<symbol>
# are never touched (MathJax glyph paths in <defs> take the colour of the
# <use> that draws them).
const _FLATTEN_TRANSLUCENCY_JS = """
    await (async function flattenTranslucency() {
      var XLINK = 'http://www.w3.org/1999/xlink';
      var probe = document.createElement('canvas').getContext('2d');
      function parse(value) {
        if (!value || value === 'none' || value.indexOf('url(') !== -1) return null;
        var m = /^rgba?\\(([^)]*)\\)\$/.exec(value.trim());
        if (!m) {
          probe.fillStyle = '#000000';
          probe.fillStyle = value;
          var norm = String(probe.fillStyle);
          if (norm.charAt(0) === '#') {
            var v = parseInt(norm.slice(1, 7), 16);
            return [(v >> 16) & 255, (v >> 8) & 255, v & 255, 1];
          }
          m = /^rgba?\\(([^)]*)\\)\$/.exec(norm);
          if (!m) return null;
        }
        var p = m[1].split(/[\\s,\\/]+/).filter(function(s) { return s.length > 0; });
        if (p.length < 3) return null;
        var a = 1;
        if (p.length > 3) {
          a = parseFloat(p[3]);
          if (p[3].indexOf('%') !== -1) a = a / 100;
          if (!isFinite(a)) a = 1;
        }
        return [parseFloat(p[0]), parseFloat(p[1]), parseFloat(p[2]), Math.max(0, Math.min(1, a))];
      }
      function over(top, alpha, base) {
        return [0, 1, 2].map(function(i) { return Math.round(top[i] * alpha + base[i] * (1 - alpha)); });
      }
      function css(rgb) { return 'rgb(' + rgb[0] + ', ' + rgb[1] + ', ' + rgb[2] + ')'; }
      var full = div._fullLayout || {};
      var paperColour = parse(full.paper_bgcolor || '#ffffff') || [255, 255, 255, 1];
      var paper = over(paperColour, paperColour[3], [255, 255, 255]);
      var areas = [];
      div.querySelectorAll('.bglayer rect.bg').forEach(function(rect) {
        var style = getComputedStyle(rect);
        var colour = parse(style.fill);
        if (!colour) return;
        var alpha = colour[3] * parseFloat(style.fillOpacity || '1');
        areas.push({box: rect.getBoundingClientRect(), colour: over(colour, alpha, paper)});
      });
      function backgroundAt(el) {
        var b = el.getBoundingClientRect();
        var x = b.left + b.width / 2, y = b.top + b.height / 2;
        for (var i = areas.length - 1; i >= 0; i--) {
          var r = areas[i].box;
          if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return areas[i].colour;
        }
        return paper;
      }
      var memo = new Map();
      var translucentNodes = [];
      function chainOpacity(node) {
        if (!node || node === div || node.nodeType !== 1) return 1;
        if (memo.has(node)) return memo.get(node);
        var own = parseFloat(getComputedStyle(node).opacity);
        if (!isFinite(own)) own = 1;
        if (own < 1) translucentNodes.push(node);
        var value = own * chainOpacity(node.parentNode);
        memo.set(node, value);
        return value;
      }
      var hidden = 'defs, clipPath, mask, pattern, marker, symbol';
      var changes = [];
      div.querySelectorAll('path, rect, circle, ellipse, line, polyline, polygon, text, tspan, textPath, use').forEach(function(el) {
        if (el.closest(hidden)) return;
        var style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return;
        var group = chainOpacity(el);
        var base = null;
        var change = {el: el};
        [['fill', 'fillOpacity'], ['stroke', 'strokeOpacity']].forEach(function(pair) {
          var colour = parse(style[pair[0]]);
          if (!colour) return;
          var opacity = parseFloat(style[pair[1]]);
          var alpha = colour[3] * (isFinite(opacity) ? opacity : 1) * group;
          if (alpha >= 1) return;
          if (alpha <= 0) { change[pair[0]] = 'none'; return; }
          if (base === null) base = backgroundAt(el);
          change[pair[0]] = css(over(colour, alpha, base));
        });
        if (change.fill !== undefined || change.stroke !== undefined) changes.push(change);
      });
      var images = [];
      div.querySelectorAll('image').forEach(function(el) {
        if (el.closest(hidden)) return;
        var style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return;
        images.push({el: el, alpha: chainOpacity(el), base: backgroundAt(el)});
      });
      changes.forEach(function(change) {
        if (change.fill !== undefined) { change.el.style.fill = change.fill; change.el.style.fillOpacity = '1'; }
        if (change.stroke !== undefined) { change.el.style.stroke = change.stroke; change.el.style.strokeOpacity = '1'; }
      });
      for (var k = 0; k < images.length; k++) {
        var item = images[k];
        var href = item.el.getAttribute('href') || item.el.getAttributeNS(XLINK, 'href');
        if (!href) continue;
        try {
          var img = new Image();
          await new Promise(function(resolve, reject) {
            img.onload = resolve;
            img.onerror = function() { reject(new Error('image')); };
            img.src = href;
          });
          if (!img.naturalWidth || !img.naturalHeight) continue;
          var canvas = document.createElement('canvas');
          canvas.width = img.naturalWidth;
          canvas.height = img.naturalHeight;
          var ctx = canvas.getContext('2d');
          ctx.fillStyle = css(item.base);
          ctx.fillRect(0, 0, canvas.width, canvas.height);
          ctx.globalAlpha = Math.max(0, Math.min(1, item.alpha));
          ctx.imageSmoothingEnabled = false;
          ctx.drawImage(img, 0, 0);
          var flattened = canvas.toDataURL('image/png');
          await new Promise(function(resolve) {
            item.el.addEventListener('load', resolve, {once: true});
            item.el.addEventListener('error', resolve, {once: true});
            item.el.setAttribute('href', flattened);
            if (item.el.hasAttributeNS(XLINK, 'href')) item.el.setAttributeNS(XLINK, 'xlink:href', flattened);
          });
        } catch (err) {
          // A cross-origin image cannot be read back; it keeps its own pixels.
        }
      }
      translucentNodes.forEach(function(node) { node.style.opacity = '1'; });
    })();
"""

# Draw the figure for printing: laid out at width x height and magnified by
# `scale` with a CSS transform, so a PDF `scale` enlarges the page and its
# content uniformly, exactly like the png/jpeg/svg `scale`. With
# `flatten_translucency` (the EPS page) translucent colours are blended over
# their background first (`_FLATTEN_TRANSLUCENCY_JS`).
function _pdf_render_script(
	divid::String,
	prepared::_PreparedRendererExport;
	flatten_translucency::Bool = false,
)
	options = prepared.options
	scale_js = _json_js(_format_scale(options, "pdf"))
	body = """
$(_EXPORT_RESET_DIV_JS)
    const scale = $scale_js;
    const width = $(_json_js(options.width));
    const height = $(_json_js(options.height));
    // The div is exactly the figure size: it clips its overflow, and the
    // print viewport (the page, width*scale x height*scale) would otherwise
    // size it, cutting off the figure whenever scale < 1.
    div.style.width = width + 'px';
    div.style.height = height + 'px';
    const layout = Object.assign({}, $(prepared.layout_js), {width: width, height: height});
    const config = Object.assign({}, $(prepared.config_js));
    // WebGL canvases (3-D scenes, maps) are bitmaps that the transform below
    // enlarges, so draw them with proportionally more pixels; plotly.js
    // accepts plotGlPixelRatio in [1, 4] and defaults to 2.
    if (scale > 1 && config.plotGlPixelRatio == null) {
      config.plotGlPixelRatio = Math.min(4, 2 * scale);
    }
    await Plotly.newPlot(div, $(prepared.data_js), layout, config);
$(_FLATTEN_COLORBAR_GRADIENTS_JS)
$(flatten_translucency ? _FLATTEN_TRANSLUCENCY_JS : "")
    if (scale !== 1) {
      div.style.transformOrigin = '0 0';
      div.style.transform = 'scale(' + scale + ')';
    }
    if (!document.getElementById('__ps_print_css')) {
      var style = document.createElement('style');
      style.id = '__ps_print_css';
      style.textContent = '@page { margin: 0 !important; } @media print { html, body { margin: 0 !important; padding: 0 !important; } }';
      document.head.appendChild(style);
    }
    return 'ok';
"""
	return _guarded_export_script(divid, options.timeout, body)
end

function _remove_failed_pdf_tempdir(tempdir::String, owner_state)
	try
		rm(tempdir; recursive = true, force = true)
		if owner_state !== nothing
			lock(owner_state.lock) do
				delete!(owner_state.owned_pdf_tempdirs, tempdir)
			end
		end
	catch cleanup_error
		@warn "Failed to remove a printToPDF temp directory." tempdir exception = (
			cleanup_error,
			catch_backtrace(),
		)
	end
	return nothing
end

function _capture_pdf_file(
	ec,
	app,
	win,
	divid::String,
	prepared::_PreparedRendererExport,
	job_id::String;
	timeout_s::Real = prepared.options.timeout,
	owner_state::Union{Nothing,_ExportState} = nothing,
	flatten_translucency::Bool = false,
)
	options = prepared.options
	script = _pdf_render_script(divid, prepared; flatten_translucency = flatten_translucency)
	result = Base.invokelatest(() -> ec.run(win, script))
	result = _check_renderer_result(result, "drawing the PDF page")
	result == "ok" ||
		error("savefig: unexpected result from the PDF render step: $(repr(result))")

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

	# Electron's printToPDF pageSize is in inches; Chromium prints 96 CSS px
	# to the inch. The figure is the magnified layout; the printed page is a
	# little larger (whole points, `_pdf_request_points`) and `_finalize_pdf`
	# crops it to the figure exactly.
	scale = _format_scale(options, "pdf")
	points_per_px = 72 / _CSS_PX_PER_INCH
	page_w_in = _json_js(_pdf_request_points(options.width * scale * points_per_px) / 72)
	page_h_in = _json_js(_pdf_request_points(options.height * scale * points_per_px) / 72)

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

	try
		result = Base.invokelatest(() -> ec.run(app, js_pdf))
		result == "started" ||
			error("printToPDF job '$job_id' failed to start (result: $result)")
		_wait_for_pdf_job(ec, app, job_id; timeout_s = timeout_s)
		isfile(tmpfile) ||
			error("printToPDF completed without writing its private output file")
	catch
		try
			_delete_pdf_job(ec, app, job_id)
		catch cleanup_error
			@warn "Failed to remove a failed printToPDF job state." job_id exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		_remove_failed_pdf_tempdir(tempdir, owner_state)
		rethrow()
	end

	try
		_delete_pdf_job(ec, app, job_id)
	catch
		_remove_failed_pdf_tempdir(tempdir, owner_state)
		rethrow()
	end
	return _CapturedPDF(tempdir, tmpfile, owner_state)
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

# Run `f(captured)` and then remove the captured PDF's private directory. If
# `f` fails, removal is still attempted (a removal failure is only logged so
# the original error surfaces); an unremoved directory stays registered with
# its export state and is reclaimed at exit.
function _consume_captured_pdf(f, captured::_CapturedPDF; tempdir_remover = nothing)
	result = try
		f(captured)
	catch
		try
			_remove_captured_pdf_tempdir!(captured, tempdir_remover)
		catch cleanup_error
			@warn "Failed to remove a captured PDF after its post-processing failed." tempdir = captured.tempdir exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		rethrow()
	end
	_remove_captured_pdf_tempdir!(captured, tempdir_remover)
	return result
end

# Page size of the pdf/eps output in points (1 CSS px = 72/96 pt).
function _pdf_page_points(options::_ExportOptions)
	factor = _format_scale(options, "pdf") * 72 / _CSS_PX_PER_INCH
	return (options.width * factor, options.height * factor)
end

function _ghostscript_available()
	try
		_ghostscript_command()
		return true
	catch err
		err isa ArgumentError || rethrow()
		return false
	end
end

# Final PDF bytes: the exact page box; text converted to outlines for
# `fonts = :outline`, and for `fonts = :auto` when Chromium wrote Type 3 fonts
# (it does for every non-TrueType font, e.g. CFF/OpenType fonts such as STIX);
# blanked creation/modification dates when deterministic. Ghostscript runs in
# `workdir` (the capture's private directory).
function _finalize_pdf(
	bytes::Vector{UInt8},
	options::_ExportOptions;
	workdir::Union{Nothing,AbstractString} = nothing,
)
	width_pt, height_pt = _pdf_page_points(options)
	bytes = _pdf_set_page_box(bytes, width_pt, height_pt)
	outline = options.fonts === :outline
	if options.fonts === :auto
		type3 = _pdf_type3_fonts(bytes)
		if !isempty(type3)
			if _ghostscript_available()
				outline = true
			else
				@warn "savefig(pdf): the PDF holds Type 3 fonts ($(join(type3, ", "))), " *
					  "which some journal checks reject, and Ghostscript (`gs`), which " *
					  "fonts = :auto uses to convert them to outlines, is not on PATH. " *
					  "Install Ghostscript, or use a TrueType font (e.g. Arial, Times New " *
					  "Roman, Liberation, DejaVu), or pass fonts = :embed to silence this." maxlog = 1
			end
		end
	end
	if outline
		workdir === nothing &&
			throw(ArgumentError("savefig(pdf): outlining text needs a work directory."))
		source = joinpath(workdir, "page-text.pdf")
		target = joinpath(workdir, "page-outlined.pdf")
		write(source, bytes)
		_pdf_outline_text(source, target; timeout_s = options.timeout)
		bytes = _pdf_set_page_box(read(target), width_pt, height_pt)
	end
	options.deterministic && (bytes = _pdf_blank_dates(bytes))
	return bytes
end

# EPS from its own capture (drawn with translucent colours blended over their
# background): exact page box, Ghostscript eps2write (text as outlines unless
# `fonts = :embed`), the bounding box set to the whole page, blank dates.
function _finalize_eps(captured::_CapturedPDF, options::_ExportOptions)
	width_pt, height_pt = _pdf_page_points(options)
	pdf_path = joinpath(captured.tempdir, "page.pdf")
	write(pdf_path, _pdf_set_page_box(read(captured.path), width_pt, height_pt))
	eps_path = joinpath(captured.tempdir, "output.eps")
	_pdf_to_eps(pdf_path, eps_path; timeout_s = options.timeout, outline = options.fonts !== :embed)
	bytes = _eps_set_bounding_box(read(eps_path), width_pt, height_pt)
	options.deterministic && (bytes = _eps_blank_dates(bytes))
	return bytes
end

# ── savefig: rendering ──────────────────────────────────────────────

# Draw every renderer format of one call in the export window while holding
# its lock. Images are captured first so a failure leaves no PDF behind. pdf
# and eps are printed separately (the EPS page has its translucent colours
# blended, `_FLATTEN_TRANSLUCENCY_JS`); if a later print fails, the earlier
# capture's directory is removed before the error propagates.
function _capture_renderer_outputs(
	state::_ExportState,
	ec,
	app,
	win,
	divid::String,
	prepared::_PreparedRendererExport,
	image_formats::Vector{String},
	pdf_formats::Vector{String},
	pdf_timeout_s::Real,
)
	urls = Dict{String,String}()
	for fmt in image_formats
		urls[fmt] = _capture_image_data_url(ec, win, divid, prepared, fmt)
	end
	captures = Pair{String,_CapturedPDF}[]
	try
		for fmt in pdf_formats
			job_id = _next_pdf_job_id_locked!(state)
			captured = _capture_pdf_file(
				ec,
				app,
				win,
				divid,
				prepared,
				job_id;
				timeout_s = pdf_timeout_s,
				owner_state = state,
				flatten_translucency = fmt == "eps",
			)
			push!(captures, fmt => captured)
		end
	catch
		_discard_captured_pdfs(captures)
		rethrow()
	end
	return (urls, captures)
end

# Remove the private directories of captures that will not be consumed.
function _discard_captured_pdfs(captures)
	for (_, captured) in captures
		try
			_remove_captured_pdf_tempdir!(captured, nothing)
		catch cleanup_error
			@warn "Failed to remove an unused printToPDF capture." tempdir = captured.tempdir exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
	end
	return nothing
end

# Produce the bytes of every format in `formats` (each drawn once). Decoding,
# post-processing and Ghostscript run after the export lock is released.
function _export_outputs(
	formats,
	renderer::Union{Nothing,_PreparedRendererExport},
	document::Union{Nothing,_PreparedDocumentExport};
	state::_ExportState = _EXPORT_STATE,
	ec = nothing,
	window_timeout_s::Real = 10.0,
	pdf_timeout_s::Union{Nothing,Real} = nothing,
)
	outputs = Dict{String,Vector{UInt8}}()
	for fmt in formats
		fmt in ("html", "json") || continue
		document isa _PreparedDocumentExport ||
			throw(ArgumentError("document export was not prepared"))
		outputs[fmt] = _document_bytes(fmt, document)
	end
	image_formats = String[fmt for fmt in _IMAGE_FORMATS if fmt in formats]
	pdf_formats = String[fmt for fmt in ("pdf", "eps") if fmt in formats]
	isempty(image_formats) && isempty(pdf_formats) && return outputs
	renderer isa _PreparedRendererExport ||
		throw(ArgumentError("renderer export was not prepared"))
	options = renderer.options
	pdf_timeout = pdf_timeout_s === nothing ? options.timeout : pdf_timeout_s

	urls, captures = _with_export_window(
		state;
		ec = ec,
		timeout_s = window_timeout_s,
	) do backend, app, win, divid
		try
			_capture_renderer_outputs(
				state,
				backend,
				app,
				win,
				divid,
				renderer,
				image_formats,
				pdf_formats,
				pdf_timeout,
			)
		catch err
			# The page may still be drawing the abandoned figure.
			err isa _ExportTimeoutError &&
				_retire_export_window_locked!(state; throw_errors = false)
			rethrow()
		end
	end

	for (index, (fmt, captured)) in enumerate(captures)
		try
			_consume_captured_pdf(captured) do pdf
				outputs[fmt] = fmt == "pdf" ?
					_finalize_pdf(read(pdf.path), options; workdir = pdf.tempdir) :
					_finalize_eps(pdf, options)
			end
		catch
			_discard_captured_pdfs(captures[(index + 1):end])
			rethrow()
		end
	end
	for fmt in image_formats
		outputs[fmt] = _finalize_image(urls[fmt], fmt, options)
	end
	return outputs
end

function _savefig_prepared(
	io::IO,
	p::Plot,
	fmt::String,
	prepared;
	state::_ExportState = _EXPORT_STATE,
	ec = nothing,
	window_timeout_s::Real = 10.0,
	pdf_timeout_s::Union{Nothing,Real} = nothing,
)
	renderer = prepared isa _PreparedRendererExport ? prepared : nothing
	document = if prepared isa _PreparedDocumentExport
		prepared
	elseif prepared === nothing && fmt in ("html", "json")
		_prepare_document_export(p, NamedTuple())
	else
		nothing
	end
	outputs = _export_outputs(
		(fmt,),
		renderer,
		document;
		state = state,
		ec = ec,
		window_timeout_s = window_timeout_s,
		pdf_timeout_s = pdf_timeout_s,
	)
	# User-controlled I/O happens after the renderer lock is released.
	write(io, outputs[fmt])
	return nothing
end

# ── savefig: files ──────────────────────────────────────────────────

# Resolve the file a savefig destination really names: symbolic links are
# followed (so the link survives and its target is written), and the
# destination must be a regular file or not exist, inside an existing directory.
function _resolve_savefig_target(filename::AbstractString)
	target = abspath(filename)
	hops = 0
	while islink(target)
		# Same bound as the kernel's MAXSYMLINKS on Linux.
		hops += 1
		hops > 40 && throw(ArgumentError(
			"savefig: too many levels of symbolic links: $(repr(filename))",
		))
		link = readlink(target)
		target = isabspath(link) ? link : normpath(joinpath(dirname(target), link))
	end
	isdir(target) &&
		throw(ArgumentError("savefig destination is a directory: $filename"))
	ispath(target) && !isfile(target) && throw(ArgumentError(
		"savefig: destination exists and is not a regular file: $(repr(filename))",
	))
	parent = dirname(target)
	isdir(parent) || throw(ArgumentError(
		"savefig: destination directory does not exist: $(repr(parent))",
	))
	return target
end

# Create a new, uniquely named file in `parent` with O_EXCL and mode 0o666, so
# the operating system applies the umask exactly as for an ordinary new file.
function _create_exclusive_temp(parent::AbstractString)
	flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL
	for _ in 1:100
		path = tempname(parent; cleanup = false)
		file = try
			Base.Filesystem.open(path, flags, 0o666)
		catch err
			err isa Base.IOError && err.code == Base.UV_EEXIST && continue
			rethrow()
		end
		return (path, file)
	end
	error("savefig: could not create a unique temporary file in $(repr(parent))")
end

# Fail before anything is drawn when a file cannot be created in the
# directory of `target` (read-only directory or file system, missing
# permission): the same exclusive temp file the final write uses is created
# and removed again.
function _check_savefig_writable(target::String)
	parent = dirname(target)
	path, file = try
		_create_exclusive_temp(parent)
	catch err
		(err isa Base.IOError || err isa SystemError) || rethrow()
		throw(ArgumentError(
			"savefig: cannot write to the destination directory $(repr(parent)): " *
			sprint(showerror, err),
		))
	end
	close(file)
	rm(path; force = true)
	return target
end

# Publish `bytes` at `target` with one rename from a temp file in the same
# directory. An existing file keeps its permission bits; a new file gets the
# umask-derived mode of an ordinary new file.
function _publish_atomically(
	target::String,
	bytes::AbstractVector{UInt8};
	renamer = Base.Filesystem.rename,
)
	existing_mode = isfile(target) ? (filemode(target) & 0o7777) : nothing
	temp_path, file = _create_exclusive_temp(dirname(target))
	try
		try
			write(file, bytes)
		finally
			close(file)
		end
		existing_mode === nothing || chmod(temp_path, existing_mode)
		# Avoid `mv(...; force=true)`: its fallback can remove the old target
		# before a later copy/rename error.
		Base.invokelatest(renamer, temp_path, target)
	catch
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
	pdf_timeout_s::Union{Nothing,Real} = nothing,
	renamer = Base.Filesystem.rename,
)
	target = _resolve_savefig_target(filename)
	buffer = IOBuffer()
	_savefig_prepared(
		buffer,
		p,
		fmt,
		prepared;
		state = state,
		ec = ec,
		window_timeout_s = window_timeout_s,
		pdf_timeout_s = pdf_timeout_s,
	)
	_publish_atomically(target, take!(buffer); renamer = renamer)
	return filename
end

_export_plot(p::Plot) = p
_export_plot(sp::SyncPlot) = sp.plot

function _savefig_filename(
	filename::AbstractString,
	p::Union{Plot,SyncPlot},
	format::Union{Nothing,AbstractString},
	kwargs;
	state::_ExportState = _EXPORT_STATE,
	ec = nothing,
)
	fmt = _filename_export_format(filename, format)
	plot = _export_plot(p)
	target = _resolve_savefig_target(filename)
	prepared = _prepare_savefig(plot, fmt, kwargs)
	_check_savefig_writable(target)
	return _savefig_atomic(
		filename,
		plot,
		fmt,
		prepared;
		state = state,
		ec = ec,
	)
end

function _savefig_many(
	filenames::AbstractVector,
	p::Union{Plot,SyncPlot},
	kwargs;
	state::_ExportState = _EXPORT_STATE,
	ec = nothing,
)
	haskey(kwargs, :format) && throw(ArgumentError(
		"savefig: `format` cannot be combined with a vector of file names; " *
		"each format is taken from its file extension.",
	))
	isempty(filenames) && throw(ArgumentError("savefig: no file names given."))
	for filename in filenames
		filename isa AbstractString || throw(ArgumentError(
			"savefig: file names must be strings; got $(typeof(filename)).",
		))
	end
	names = String[String(filename) for filename in filenames]
	formats = String[_filename_export_format(name, nothing) for name in names]
	targets = String[_resolve_savefig_target(name) for name in names]
	allunique(targets) || throw(ArgumentError(
		"savefig: the same destination appears more than once in $(repr(names)).",
	))
	plot = _export_plot(p)
	distinct = unique(formats)
	prepared = _prepare_export(plot, distinct, kwargs)
	foreach(_check_savefig_writable, unique(targets))
	outputs = _export_outputs(
		distinct,
		prepared.renderer,
		prepared.document;
		state = state,
		ec = ec,
	)
	for (target, fmt) in zip(targets, formats)
		_publish_atomically(target, outputs[fmt])
	end
	return names
end

"""
	savefig(fig, filename::AbstractString; kwargs...) -> filename
	savefig(filename::AbstractString, fig; format = nothing, kwargs...) -> filename
	savefig(fig, filenames::AbstractVector{<:AbstractString}; kwargs...) -> Vector{String}
	savefig(io::IO, fig; format = nothing, kwargs...)
	savefig(fig; format = "png", kwargs...) -> Vector{UInt8}

Export a `Plot`, `SyncPlot` or `SubplotFigure` to a file, several files, a
stream, or a byte vector. The caller's figure is never modified.

# Formats
`"png"`, `"jpeg"` (`".jpg"` is accepted), `"tiff"` (`".tif"` is accepted),
`"svg"`, `"pdf"`, `"eps"`, `"html"`, `"json"`. With a file name the format
comes from the extension (no extension means png) unless `format` is given;
for a stream or bytes it defaults to `"png"`. png/jpeg/tiff/svg/pdf are drawn
by plotly.js in a hidden Electron window (no Kaleido or Python needed); eps is
converted from a PDF print by Ghostscript (`gs` must be on `PATH`); html and
json are written in-process. JSON and HTML write non-finite numbers (`NaN`,
`±Inf`) as `null`, which plotly.js draws as a gap. An html file embeds the
bundled plotly.js renderer (about 4.5 MB) and loads MathJax from its CDN when
mathematical text is present.

What each file contains:
- png: 8-bit RGBA of exactly `round(width * scale)` x `round(height * scale)`
  pixels.
- jpeg: Chromium's baseline JPEG (quality 0.92, lossy); transparent areas are
  white.
- tiff: baseline TIFF 6.0 with lossless LZW compression, 8-bit RGB (RGBA with
  unassociated alpha when a pixel is translucent, e.g. `background =
  :transparent`) and XResolution/YResolution in dots per inch. It is drawn at
  300 dpi unless `dpi` or `scale` says otherwise.
- svg: plotly.js's SVG. Text is `<text>` in the figure's font, which is not
  embedded (the viewer needs the font); LaTeX labels are glyph paths. With
  physical `units` the root `width`/`height` carry the unit (`"88mm"`), else
  CSS px; the `viewBox` is the layout in CSS px.
- pdf: Chromium's vector PDF on a page of exactly `width x height` (times
  `scale`) points. Paths stay vector, transparency is kept, images (heatmaps,
  3-D/WebGL scenes) are embedded losslessly, and LaTeX labels are glyph
  paths. Text: see `fonts`.
- eps: Ghostscript `eps2write` (PostScript level 2) of a PDF print, vector,
  with `%%BoundingBox` = the whole page. EPS has no transparency: every
  translucent colour is replaced by its blend over the background it is drawn
  on (the plot area, else the paper; a translucent background is blended over
  white) and translucent images are composited onto it, so a 30 % band prints
  light, as in the PDF. A translucent mark drawn over another mark covers it
  instead of letting it show through; export pdf to keep true transparency.

# Keyword arguments
- `format::Union{Nothing,AbstractString} = nothing`: output format, overriding
  the extension. Not allowed with a vector of file names.
- `width`, `height::Real`: figure size in `units`. Default: the figure's
  `layout.width`/`layout.height` when set, else the active style's default
  figure size (journal styles set one), else 700 x 500 px. The size must be
  at least 10 px (plotly.js's layout minimum).
- `units::Symbol = :px`: unit of `width`/`height`: `:px` (CSS pixel, 1/96 in),
  `:in`, `:cm`, `:mm` or `:pt` (1/72 in). The pdf/eps page is exact in points
  for any size; a raster gets the nearest whole number of pixels.
- `scale::Real = 1`: uniform magnification. png/jpeg/tiff get `scale` times
  more pixels; svg/pdf/eps get a `scale` times larger page with the same
  layout (text, markers and lines grow with it).
- `dpi::Real`: raster resolution in dots per inch, an alternative to `scale`
  (passing both is an error). png/jpeg/tiff are drawn at `scale = dpi/96` and
  record the resolution (PNG `pHYs` chunk, JPEG JFIF density, TIFF
  resolution tags), so `width = 3.5, units = :in, dpi = 300` gives a
  1050-px-wide image that prints 3.5 in wide. Without `dpi`, png/jpeg record
  `96 * scale` dpi when `units` is physical (none for `:px`, as in 1.x), and
  tiff always records its resolution. Vector formats keep their physical size
  and ignore `dpi`.
- `fonts::Symbol = :auto`: text in pdf and eps. pdf: `:auto` keeps text as
  text in subset-embedded TrueType (CID) fonts when the figure's fonts are
  TrueType (Arial, Times New Roman, Verdana, Liberation, DejaVu, …); Chromium
  can embed other fonts (CFF/OpenType-PS such as STIX or Latin Modern) only
  as Type 3 fonts, which many journal checks reject, so then the whole page's
  text is converted to outlines with Ghostscript (without Ghostscript the Type
  3 fonts are kept and a warning names them). `:embed` keeps Chromium's fonts
  as they are; `:outline` always draws text as outlines (needs Ghostscript).
  eps: text is always outlines (no font in the file) unless `:embed`, which
  lets Ghostscript embed Type 3/Type 42 fonts. Outlined text prints the same
  but cannot be selected or searched.
- `deterministic::Bool = true`: make repeated exports of the same figure
  byte-identical: blank the PDF creation/modification dates and the EPS
  creation date, and give SVG/PDF elements fixed ids (`uid`s are set on the
  export copy only). PNG, JPEG and TIFF output is deterministic by nature.
- `background = nothing`: figure background. `nothing` keeps the figure's own
  colours; a colour (`"white"`, `:black`, `"#ffeedd"`, `"rgba(0,0,0,0.5)"`)
  sets the paper background; `:transparent` clears the paper, plot-area and
  3-D scene/polar/ternary/geo backgrounds (useful for png and svg).
- `tight::Bool = false`: apply [`tight_layout!`](@ref) to the export copy, which
  trims the margins to the labels.
- `timeout::Real = $(Int(_DEFAULT_EXPORT_TIMEOUT_S))`: seconds allowed for each
  renderer step (drawing the figure, printing the PDF, running Ghostscript)
  before the export fails with a timeout error.

`html` and `json` validate every keyword but ignore the size, resolution and
renderer options; `background` and `tight` apply to all formats.

A file is written atomically: the output goes to a temporary file in the same
directory, which then replaces the destination in one rename. A symbolic link
is followed and its target replaced, an existing file keeps its permission
bits, and a new file gets the usual mode for new files (umask applied).
With several file names every distinct format is rendered once, everything is
validated before anything is drawn, and the files are published one by one.

LaTeX labels are typeset by MathJax 2.7 in the font chosen with
[`set_default_mathtext!`](@ref)`(; font = ...)`, one of `"Latin-Modern"` (the
default), `"TeX"`, `"STIX-Web"`, `"Asana-Math"`, `"Neo-Euler"`,
`"Gyre-Pagella"` and `"Gyre-Termes"`. When no font is set that way, the
environment variable `PLOTLYSUPPLY_MATHJAX_SVG_FONT` (same names) is used. The
font applies to html and image export and to live windows. Under
Latin-Modern, `\\mathcal` draws Latin Modern's script letters, and
`\\boldsymbol{\\nabla}`, `\\boldsymbol{\\partial}` and `\\boldsymbol{\\ell}` stay
upright-regular (the font has no bold glyphs for them; `font = "TeX"` has).

# Errors
`ArgumentError` for unknown keywords, invalid values, a missing or unwritable
destination directory, or EPS (or `fonts = :outline` pdf) without
Ghostscript, before anything is drawn or any file is touched;
`ErrorException` for an unsupported format or a renderer failure.

```julia
fig = plot_scatter(1:10, rand(10); xlabel = "x", ylabel = "y")
savefig(fig, "figure.pdf"; width = 88, height = 66, units = :mm)
savefig(fig, "figure.tif"; width = 88, height = 66, units = :mm, dpi = 600)
savefig(fig, "figure.png"; width = 3.5, height = 2.5, units = :in, dpi = 300)
savefig(fig, ["figure.svg", "figure.eps"]; background = :transparent)
savefig(fig, "figure-outlined.pdf"; fonts = :outline)
bytes = savefig(fig; format = "svg")
```
"""
function savefig(
	io::IO,
	p::Plot;
	format::Union{Nothing,AbstractString} = nothing,
	kwargs...,
)
	fmt = _validate_export_format(format === nothing ? "png" : format)
	prepared = _prepare_savefig(p, fmt, kwargs)
	return _savefig_prepared(io, p, fmt, prepared)
end

savefig(io::IO, sp::SyncPlot; kwargs...) = savefig(io, sp.plot; kwargs...)

function savefig(p::Union{Plot,SyncPlot}; kwargs...)
	io = IOBuffer()
	savefig(io, p; kwargs...)
	return take!(io)
end

function savefig(
	filename::AbstractString,
	p::Union{Plot,SyncPlot};
	format::Union{Nothing,AbstractString} = nothing,
	kwargs...,
)
	return _savefig_filename(filename, p, format, kwargs)
end

savefig(p::Union{Plot,SyncPlot}, filename::AbstractString; kwargs...) =
	savefig(filename, p; kwargs...)

savefig(p::Union{Plot,SyncPlot}, filenames::AbstractVector; kwargs...) =
	_savefig_many(filenames, p, kwargs)

"""
	savejson(sp::SyncPlot, filename::AbstractString)

Write the JSON figure specification of `sp`'s plot to `filename` (which must
end in `.json`), atomically and with non-finite numbers written as `null`.
Returns `sp.plot`.
"""
function PlotlyBase.savejson(sp::SyncPlot, filename::AbstractString)
	lowercase(splitext(filename)[2]) == ".json" || throw(ArgumentError(
		"savejson: the file name must end in .json; use savefig for other formats.",
	))
	savefig(filename, sp.plot; format = "json")
	return sp.plot
end
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
	# Rebuild the window from the committed model (`_prepare_redraw_transaction`).
	_syncplot_transaction!(sp, _prepare_redraw_transaction)
	return sp
end

function PlotlyBase.purge!(sp::SyncPlot)
	prepare = (target, current) ->
		_prepare_purge_transaction(target, current)
	_syncplot_transaction!(sp, prepare)
	return sp
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
	_require_open_syncplot_window(sp)
	js = _syncplot_to_image_script(sp, kwargs)
	# The capture reads the live page directly: bring it up to date first (a
	# page built with an older `set_default_mathtext!(; font,
	# inherit_text_font)` is reloaded, a desynchronized renderer is rebuilt
	# from the committed model). The model itself is not changed.
	_syncplot_refresh_page!(sp)
	ec = _syncplot_backend(sp)
	result = Base.invokelatest(() -> ec.run(getfield(sp, :window), js))
	result isa AbstractString || error(
		"Plotly.toImage returned a non-string result of type $(typeof(result))",
	)
	return String(result)
end

function PlotlyBase.download_image(sp::SyncPlot; kwargs...)
	_require_open_syncplot_window(sp)
	js = _syncplot_download_image_script(sp, kwargs)
	# As in `to_image`: capture an up-to-date page, never a stale one.
	_syncplot_refresh_page!(sp)
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
		# `row`/`col`/`secondary_y`/`inset`/`show` would become layout
		# attributes (Y31).
		_verb_reject_cell_keywords($(String(f)), kwargs)
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

# PlotlyBase's shape/image verbs on a Plot or SyncPlot. `row`/`col` keep
# PlotlyBase's grid selection ("all", an index or a vector of indices) but are
# validated first: PlotlyBase only logs a bad string, raises a bare error for
# an index past the grid and places items on non-Cartesian cells with
# nonsense axis references. `show`, `secondary_y`, `inset`, `xref`/`yref`
# (set from the cell) and bad coordinates are ArgumentErrors; PlotlyBase wrote
# them into the shape (G26). Everything is validated before the figure
# changes.
for f in (:add_hrect!, :add_hline!, :add_vrect!, :add_vline!, :add_shape!, :add_layout_image!)
	who = String(f)
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; row = "all", col = "all", kwargs...)
		_verb_reject_cell_keywords($who, kwargs)
		key, direction, items = _verb_layout_items($(QuoteNode(f)), $who, args, kwargs)
		_verb_plot_cell_refs(sp.plot, row, col, $who)
		return _mutate_and_refresh_syncplot!(
			sp;
			mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
		) do current
			targets = _verb_plot_cell_refs(current, row, col, $who)
			_verb_append_layout_items!(current.layout, key, direction, items, targets)
		end
	end

	@eval function PlotlyBase.$f(
		p::_RefreshablePlot,
		args...;
		row = "all",
		col = "all",
		kwargs...,
	)
		_verb_reject_cell_keywords($who, kwargs)
		key, direction, items = _verb_layout_items($(QuoteNode(f)), $who, args, kwargs)
		_verb_plot_cell_refs(p, row, col, $who)
		return _transactional_full_plot_mutation!(
			p;
			mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
		) do current
			targets = _verb_plot_cell_refs(current, row, col, $who)
			_verb_append_layout_items!(current.layout, key, direction, items, targets)
		end
	end
end

function PlotlyBase.add_recession_bands!(sp::SyncPlot; kwargs...)
	_verb_reject_cell_keywords("add_recession_bands!", kwargs)
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
	_verb_reject_cell_keywords("add_recession_bands!", kwargs)
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

# Window options for a SyncPlot built from `sps`: it is shown (and autoplays)
# when any input with known options was, and waits for startup as long as the
# most patient input. Inputs without recorded options (e.g. a SyncPlot wrapped
# by hand) do not constrain it; with none known, `to_syncplot`'s defaults apply.
function _syncplot_concat_window_options(sps::Tuple{Vararg{SyncPlot}})
	specs = _SyncPlotCreationSpec[]
	for sp in sps
		spec = getfield(sp, :_resources).creation_spec
		spec === nothing || push!(specs, spec)
	end
	isempty(specs) && return NamedTuple()
	return (
		show = any(spec -> spec.show, specs),
		autoplay = any(spec -> spec.autoplay, specs),
		timeout_s = maximum(spec -> spec.timeout_s, specs),
	)
end

function Base.hcat(sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(
		hcat(plots...);
		app = _syncplot_app(sps),
		_syncplot_concat_window_options(sps)...,
	)
end

function Base.vcat(sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(
		vcat(plots...);
		app = _syncplot_app(sps),
		_syncplot_concat_window_options(sps)...,
	)
end

function Base.hvcat(rows::Tuple{Vararg{Int}}, sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(
		hvcat(rows, plots...);
		app = _syncplot_app(sps),
		_syncplot_concat_window_options(sps)...,
	)
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

Re-render `p`'s window from the Julia-side model, in place, and return `p`.

- On a [`SyncPlot`](@ref), or a `Plot` currently shown in one, the window is
  rebuilt from the model's data, layout, config and frames (`Plotly.purge`
  then `Plotly.newPlot`; frames are re-added without starting playback). Edits
  made directly to the model, which bypass the mutating verbs — e.g.
  `sp.plot.data[1][:y] = [9, 9, 9]` or `sp.plot.layout[:title] = "new"` —
  therefore appear in the window. Interactive zoom/pan in the window is reset
  to the model's axis ranges. The model itself is not changed.
- On a `Plot` that is not shown in a window it is a no-op.
- On a [`SubplotFigure`](@ref) it acts on the figure it wraps (window or
  plain `Plot`, as above) and returns the `SubplotFigure`.

A closed window throws an `InvalidStateException`. When plotly.js fails, the
error is thrown and the usual renderer recovery applies: the window is rebuilt
from the model at once or, if that fails too, marked desynchronized and rebuilt
by the next update.

# Example
```julia
sp = to_syncplot(Plot(scatter(y = [1, 2, 3])))
sp.plot.data[1][:y] = [3, 2, 1]   # direct model edit, not yet visible
redraw!(sp)                       # the window now shows [3, 2, 1]
```
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
as a `String` (a data URL unless `imageDataOnly = true`). Keyword arguments
are passed to `Plotly.toImage` unchanged (`format`, `width`, `height`,
`scale`, `imageDataOnly`, `setBackground`).

Before capturing, the page is brought up to date without changing the Julia
model: a page built before a [`set_default_mathtext!`](@ref) `font` or
`inherit_text_font` change is reloaded with the new MathJax configuration, and
a renderer left desynchronized by a failed update is rebuilt from `sp.plot`.
If that reload or rebuild fails, its error is thrown and nothing is captured.
Throws an `InvalidStateException` when the window is closed, and an
`ErrorException` when plotly.js returns something other than a string.

For files, prefer [`savefig`](@ref), which does not need an open window.
"""
to_image

"""
	download_image(sp::SyncPlot; kwargs...)

Trigger a browser-style download of `sp`'s rendered image via
`Plotly.downloadImage` in its Electron window. Keyword arguments are passed to
`Plotly.downloadImage` unchanged (`format`, `width`, `height`, `scale`,
`filename`). The page is brought up to date first, exactly as in
[`to_image`](@ref). Returns `nothing`; throws an `InvalidStateException` when
the window is closed.
"""
download_image

# ── Trace and subplot helpers ───────────────────────────────────────

"""
	add_trace!(p::Union{Plot,SyncPlot}, trace::GenericTrace; row = 1, col = 1, secondary_y = false)
	add_trace!(sf::SubplotFigure, trace::GenericTrace; row = nothing, col = nothing, secondary_y = false)

Add `trace` to `p`, routed to the subplot cell at `row`/`col`; with
`secondary_y = true` it goes to that cell's secondary y-axis (the subplot grid
must have been created with a secondary-y spec). Returns `p`.

On a `Plot` or [`SyncPlot`](@ref), `row`/`col` default to the first cell. On a
[`SubplotFigure`](@ref) they default to the active cell (see
[`subplot!`](@ref)), must be given together, and the trace type must match the
cell kind (e.g. a `scatter3d` needs a 3-D scene cell); the cell then becomes the
active cell. A `SubplotFigure` call returns `sf`.
"""
add_trace!

const _VERB_PLOT_CELLS_DOC = """
On a `Plot` or [`SyncPlot`](@ref), `row`/`col` select cells of its subplot
grid: `"all"` (the default), an index or a vector of indices; the item is
added once per selected Cartesian (x/y) cell, on that cell's axes (blank and
non-Cartesian cells are skipped). An index outside the grid, a single
non-Cartesian cell, `show`, `secondary_y`, `inset`, `xref`/`yref` (set from
the cell) and invalid coordinates are `ArgumentError`s, and the figure is left
unchanged. On a [`SubplotFigure`](@ref) the call targets the active cell (or
`row`/`col`, `secondary_y`, `inset`); see that method's documentation.
"""

"""
	add_shape!(p, shape; row = "all", col = "all")

Add a layout [`Shape`](@ref) (or `attr(...)`, or a vector of them) to `p` in
data coordinates of the selected cells' axes; an `xref`/`yref` of `"paper"`
or `"… domain"` on the shape becomes a fraction of each cell. Returns `p`.

$(_VERB_PLOT_CELLS_DOC)
"""
add_shape!

"""
	add_hline!(p, y; row = "all", col = "all", kwargs...)

Add a horizontal line [`Shape`](@ref) at data value `y` (a vector adds one
line per entry) across the full width of each selected cell; `kwargs` are
shape attributes (`line_color`, `line_dash`, ...). Returns `p`.

$(_VERB_PLOT_CELLS_DOC)
"""
add_hline!

"""
	add_vline!(p, x; row = "all", col = "all", kwargs...)

Add a vertical line [`Shape`](@ref) at data value `x` (a vector adds one line
per entry) across the full height of each selected cell; `kwargs` are shape
attributes. Returns `p`.

$(_VERB_PLOT_CELLS_DOC)
"""
add_vline!

"""
	add_hrect!(p, y0, y1; row = "all", col = "all", kwargs...)

Add a horizontal band [`Shape`](@ref) between data values `y0` and `y1`
across the full width of each selected cell; `kwargs` are shape attributes
(`fillcolor`, `opacity`, `line_width`, ...). Returns `p`.

$(_VERB_PLOT_CELLS_DOC)
"""
add_hrect!

"""
	add_vrect!(p, x0, x1; row = "all", col = "all", kwargs...)

Add a vertical band [`Shape`](@ref) between data values `x0` and `x1` across
the full height of each selected cell; `kwargs` are shape attributes.
Returns `p`.

$(_VERB_PLOT_CELLS_DOC)
"""
add_vrect!

"""
	add_layout_image!(p, image; row = "all", col = "all")

Add a layout image (e.g. `attr(source = "...", x = 0, y = 1, sizex = 0.3,
sizey = 0.3, xanchor = "left", yanchor = "top")`) to `p`, with `x`, `y`,
`sizex`, `sizey` as fractions of each selected cell's plot area. Returns `p`.

$(_VERB_PLOT_CELLS_DOC)
"""
add_layout_image!

"""
	add_recession_bands!(p; kwargs...)
	add_recession_bands!(sf::SubplotFigure; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)

Shade US recession bands (vertical spans) on a time-series `Plot` or
[`SyncPlot`](@ref); `kwargs` are forwarded to the generated band shapes.
`show`, `row`, `col`, `secondary_y` and `inset` are `ArgumentError`s on a
`Plot`/`SyncPlot` (it has no cells to select).

Returns the layout's complete shape vector after the update (existing shapes
followed by the new bands), or `nothing`, leaving the figure unchanged, when no
trace has date `x` values. The [`SubplotFigure`](@ref) method marks the
selected cells and returns `sf`; see its own documentation.
"""
add_recession_bands!

# ── Layout object updaters ──────────────────────────────────────────

# The layout objects of one family are `name`, `name2`, `name3`, … (plotly's
# subplot ids); the generated text spells them as separate code spans so the
# number is part of the name (`scene2`), not glued after a closing backtick.
for (fn, name, desc) in (
	(:update_xaxes!, "xaxis", "x-axis"),
	(:update_yaxes!, "yaxis", "y-axis"),
	(:update_polars!, "polar", "polar"),
	(:update_scenes!, "scene", "3D scene"),
	(:update_ternaries!, "ternary", "ternary"),
	(:update_geos!, "geo", "geographic"),
	(:update_mapboxes!, "mapbox", "mapbox"),
)
	subplot_note = if fn in (:update_geos!, :update_mapboxes!)
		"On a [`SubplotFigure`](@ref) `sf` the update applies to the `$(name)` " *
		"object of ONE cell: the cell given by `row`/`col` (pass both) or, " *
		"without them, the active cell, which then becomes the active cell; " *
		"call it on `sf.fig` to update every `$(name)` object of the grid. " *
		"Returns `sf`."
	else
		secondary = fn === :update_yaxes! ?
			" (`secondary_y = true`: its secondary y axis)" : ""
		"On a [`SubplotFigure`](@ref) `sf`, without `row`/`col` every " *
		"`$(name)` object of the figure is updated (the active cell is " *
		"unchanged); with `row` and `col` (pass both) only that cell's " *
		"`$(name)` object$(secondary) is updated and the cell becomes the " *
		"active cell. Returns `sf`."
	end
	doc = """
		$(fn)(p, with::PlotlyAttribute = attr(); kwargs...)
		$(fn)(sf::SubplotFigure, with::PlotlyAttribute = attr(); row = nothing, col = nothing, kwargs...)

	Merge the attribute update `with` and `kwargs` (Plotly attributes of the
	object, nested ones with underscores: `title_text = "t"`) into every
	$(desc) layout object (`$(name)`, `$(name)2`, `$(name)3`, …) of `p`, which
	may be a `Plot`, a `Layout` or a [`SyncPlot`](@ref) (a `SyncPlot` is redrawn
	in one renderer transaction). Returns `p`. `row`/`col` select a cell only
	on a `SubplotFigure`.

	$(subplot_note) A cell of another kind is an `ArgumentError`, and the
	figure is left unchanged. See the `SubplotFigure` method's own
	documentation for the details.
	"""
	@eval @doc $doc $fn
end

for (fn, name) in (
	(:update_annotations!, "annotations"),
	(:update_images!, "images"),
	(:update_shapes!, "shapes"),
)
	doc = """
		$(fn)(p::Union{Plot,SyncPlot}, with::PlotlyAttribute = attr(); kwargs...)
		$(fn)(layout::Layout, with::PlotlyAttribute; kwargs...)
		$(fn)(sf::SubplotFigure, with::PlotlyAttribute = attr(); row = nothing, col = nothing, kwargs...)

	Merge the attribute update `with` and `kwargs` into every entry of the
	`$(name)` layout array of `p` (a [`SyncPlot`](@ref) is redrawn in one
	renderer transaction) and return `p`. On a bare `Layout` the `with`
	argument is required and the call returns `nothing`. `row`/`col` select a
	cell only on a `SubplotFigure`.

	On a [`SubplotFigure`](@ref) `sf`, without `row`/`col` every entry is
	updated; with `row` and `col` (pass both) only the entries placed on that
	Cartesian cell's axes (`xref` and `yref` both name one of them) are updated
	and the cell becomes the active cell; a non-Cartesian cell is an
	`ArgumentError`. Returns `sf`. See the `SubplotFigure` method's own
	documentation for the details.
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
