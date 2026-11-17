# PlotlySupply 2.0 3-D plotting: every 3-D constructor and mutator
# (plot_surface, plot_scatter3d, plot_quiver3d, plot_mesh3d, plot_isosurface,
# plot_volume, plot_streamtube, plot_polygons3d, plot_wireframe,
# plot_segments3d), the camera (`view!`), per-cell scene options (`scene!`)
# and 3-D annotations (`annotate!(fig, x, y, z, text)`).
#
# Public names that are new in 2.0 are exported from this file; the older
# names are exported from PlotlySupply.jl. Untyped-first-argument mutators
# that must run as one renderer transaction on `Plot`/`SyncPlot` are listed in
# `_SCI_SCENE3D_MUTATORS` (api.jl splices that tuple into the transactional
# wrapper registry). `plot_surface!`, `plot_scatter3d!`, `plot_quiver3d!`,
# `plot_mesh3d!`, `plot_isosurface!`, `plot_volume!`, `plot_streamtube!` and
# `annotate!` are already in the main registry list, so they are not repeated
# here (a second entry would install the same wrapper method twice).

export plot_polygons3d, plot_polygons3d!, plot_wireframe, plot_wireframe!,
	plot_segments3d, plot_segments3d!, view!, scene!

const _SCI_SCENE3D_MUTATORS = (
	:view!,
	:scene!,
	:plot_polygons3d!,
	:plot_wireframe!,
	:plot_segments3d!,
)

#region 3-D text: _label3d

# Scene axis titles, scene tick labels and scatter3d text are drawn by WebGL
# (vectorize-text). That renderer understands only <b>, <i>, <sub>, <sup> and
# <br> and neither typesets MathJax nor decodes HTML entities, so TeX inside
# `$…$` is converted here to those tags and Unicode.

const _LABEL3D_BOLD_MATH_MACROS = Set(["mathbf", "boldsymbol", "bm", "pmb"])
const _LABEL3D_BOLD_TEXT_MACROS = Set(["textbf"])
const _LABEL3D_ITALIC_MATH_MACROS = Set(["mathit"])
const _LABEL3D_ITALIC_TEXT_MACROS = Set(["textit", "emph"])

# Names of unsupported macros that have already produced a warning, so each
# one warns once per session.
const _LABEL3D_WARNED = Set{String}()
const _LABEL3D_WARNED_LOCK = ReentrantLock()

function _label3d_warn_unsupported(name::String)
	first_time = lock(_LABEL3D_WARNED_LOCK) do
		name in _LABEL3D_WARNED && return false
		push!(_LABEL3D_WARNED, name)
		return true
	end
	first_time && @warn(
		"3-D scene text is drawn by WebGL, which cannot typeset TeX: `\\$(name)` " *
		"is shown as written. Supported in 3-D axis titles, tick labels and " *
		"scatter3d text: Greek letters and common symbols, `_{…}`, `^{…}`, " *
		"`\\mathbf`/`\\textbf` (bold), `\\mathit`/`\\textit` (italic), " *
		"`\\mathrm`/`\\text` (upright), `\\frac`, `\\sqrt` and accents.",
	)
	return nothing
end

"""
	_label3d(s::AbstractString) -> String

Label text for WebGL-drawn 3-D text (scene axis titles, scene tick labels and
scatter3d point text). Text outside `\$…\$` is kept (`\\\$` gives a literal
dollar, newlines become `<br>`). Inside math: `\\mathbf{x}`/`\\textbf{x}` →
`<b>x</b>`, `\\mathit`/`\\textit` → `<i>…</i>`, `_{…}`/`_x` → `<sub>`,
`^{…}` → `<sup>`, Greek letters and common symbols → Unicode, `\\mathrm`,
`\\text` and the other font macros are unwrapped, `\\frac{a}{b}` → `a/b`,
`\\sqrt{x}` → `√x`. An unsupported macro is shown as written and warns once
per macro name. With mathtext disabled (`set_default_mathtext!(false)`) the
text is used literally.
"""
function _label3d(s::AbstractString)::String
	str = String(s)
	isempty(str) && return str
	_MATHTEXT_SETTINGS[].enabled || return _mathtext_newlines_to_br(str)
	isvalid(str) || throw(ArgumentError("mathtext: label is not valid UTF-8: $(repr(str))."))
	segments = _mathtext_segments(collect(str), str)
	out = IOBuffer()
	for (kind, content) in segments
		if kind === :text
			print(out, _mathtext_plain(collect(content); dollar = "\$"))
		else
			cur = _TexPlainCursor(collect(content), 1)
			print(out, _label3d_until!(cur, false))
		end
	end
	return _mathtext_newlines_to_br(String(take!(out)))
end

function _label3d_until!(cur::_TexPlainCursor, in_group::Bool)
	out = IOBuffer()
	while !_tex_plain_done(cur)
		c = cur.chars[cur.pos]
		if c == '}'
			cur.pos += 1
			in_group && return String(take!(out))
			print(out, '}')
		elseif c == '{'
			cur.pos += 1
			print(out, _label3d_until!(cur, true))
		elseif c == '^' || c == '_'
			cur.pos += 1
			tag = c == '^' ? "sup" : "sub"
			print(out, "<", tag, ">", _label3d_arg!(cur), "</", tag, ">")
		elseif c == '\\'
			print(out, _label3d_control!(cur))
		else
			cur.pos += 1
			print(out, _tex_plain_char(c))
		end
	end
	return String(take!(out))
end

function _label3d_arg!(cur::_TexPlainCursor)
	_tex_plain_skip_spaces!(cur)
	_tex_plain_done(cur) && return ""
	c = cur.chars[cur.pos]
	if c == '{'
		cur.pos += 1
		return _label3d_until!(cur, true)
	elseif c == '\\'
		return _label3d_control!(cur)
	end
	cur.pos += 1
	return _tex_plain_char(c)
end

function _label3d_control!(cur::_TexPlainCursor)
	n = length(cur.chars)
	cur.pos += 1
	cur.pos > n && return "\\"
	c = cur.chars[cur.pos]
	if !_mathtext_isletter(c)
		cur.pos += 1
		return get(_TEX_PLAIN_CONTROL_SYMBOLS, c, string(c))
	end
	stop = cur.pos
	while stop < n && _mathtext_isletter(cur.chars[stop + 1])
		stop += 1
	end
	name = String(cur.chars[cur.pos:stop])
	cur.pos = stop + 1
	return _label3d_macro!(cur, name)
end

function _label3d_macro!(cur::_TexPlainCursor, name::String)
	symbol = get(_TEX_PLAIN_SYMBOLS, name, nothing)
	symbol === nothing || return symbol
	if name in _TEX_PLAIN_FUNCTION_NAMES
		next = _tex_plain_done(cur) ? ' ' : cur.chars[cur.pos]
		return (next == '\\' || _mathtext_isletter(next)) ? name * " " : name
	end
	name in _TEX_PLAIN_IGNORED && return ""
	name in _LABEL3D_BOLD_MATH_MACROS && return "<b>" * _label3d_arg!(cur) * "</b>"
	name in _LABEL3D_BOLD_TEXT_MACROS && return "<b>" * _tex_plain_raw_arg!(cur) * "</b>"
	name in _LABEL3D_ITALIC_MATH_MACROS && return "<i>" * _label3d_arg!(cur) * "</i>"
	name in _LABEL3D_ITALIC_TEXT_MACROS && return "<i>" * _tex_plain_raw_arg!(cur) * "</i>"
	name in _TEX_PLAIN_FONT_MACROS && return _label3d_arg!(cur)
	name in _TEX_PLAIN_TEXT_MACROS && return _tex_plain_raw_arg!(cur)
	if name == "mathbb"
		arg = _label3d_arg!(cur)
		return get(_TEX_PLAIN_BLACKBOARD, arg, arg)
	elseif name in _TEX_PLAIN_DELIMITER_SIZES
		_tex_plain_skip_spaces!(cur)
		!_tex_plain_done(cur) && cur.chars[cur.pos] == '.' && (cur.pos += 1)
		return ""
	elseif haskey(_TEX_PLAIN_ACCENTS, name)
		mark = _TEX_PLAIN_ACCENTS[name]
		arg = _label3d_arg!(cur)
		length(arg) == 1 && return arg * mark
		name in ("overline", "underline", "bar") && return join(string(ch, mark) for ch in arg)
		return arg
	elseif name in ("frac", "dfrac", "tfrac", "cfrac")
		numerator = _label3d_arg!(cur)
		denominator = _label3d_arg!(cur)
		return _tex_plain_operand(numerator) * "/" * _tex_plain_operand(denominator)
	elseif name == "sqrt"
		_tex_plain_skip_spaces!(cur)
		index = ""
		if !_tex_plain_done(cur) && cur.chars[cur.pos] == '['
			close = findnext(==(']'), cur.chars, cur.pos)
			if close !== nothing
				inner = _TexPlainCursor(cur.chars[(cur.pos + 1):(close - 1)], 1)
				index = _label3d_until!(inner, false)
				cur.pos = close + 1
			end
		end
		radicand = _tex_plain_operand(_label3d_arg!(cur))
		index == "3" && return "∛" * radicand
		index == "4" && return "∜" * radicand
		isempty(index) && return "√" * radicand
		return "<sup>" * index * "</sup>√" * radicand
	elseif name == "not"
		return _label3d_arg!(cur) * "̸"
	elseif name in ("color", "label", "phantom", "hphantom", "vphantom", "tag", "end")
		_tex_plain_raw_arg!(cur)
		return ""
	elseif name == "textcolor"
		_tex_plain_raw_arg!(cur)
		return _label3d_arg!(cur)
	elseif name == "begin"
		environment = _tex_plain_raw_arg!(cur)
		environment in ("array", "tabular") && _tex_plain_raw_arg!(cur)
		return ""
	elseif name == "unicode"
		arg = strip(_tex_plain_raw_arg!(cur))
		code = (startswith(arg, "x") || startswith(arg, "X")) ?
			tryparse(UInt32, arg[2:end]; base = 16) : tryparse(UInt32, arg; base = 10)
		(code !== nothing && code != 0 && isvalid(Char, code)) && return string(Char(code))
		return "\\unicode{" * arg * "}"
	end
	_label3d_warn_unsupported(name)
	out = IOBuffer()
	print(out, '\\', name)
	while !_tex_plain_done(cur) && cur.chars[cur.pos] == '{'
		cur.pos += 1
		print(out, '{', _label3d_until!(cur, true), '}')
	end
	return String(take!(out))
end

#endregion

#region Validation helpers

# Unknown keywords raise an ArgumentError naming them; `show` on a mutator gets
# a dedicated message because it is a constructor-only keyword.
function _s3_reject_kwargs(who::AbstractString, kwargs)
	isempty(kwargs) && return nothing
	names = collect(keys(kwargs))
	if :show in names
		throw(ArgumentError(
			"$(who): `show` is a constructor keyword; a mutator updates an " *
			"existing figure in place (display it with `display(fig)` or open " *
			"a window with `to_syncplot(fig)`).",
		))
	end
	plural = length(names) == 1 ? "" : "s"
	throw(ArgumentError(
		"$(who): unsupported keyword$(plural) " *
		join(("`$(name)`" for name in names), ", ") *
		"; see `?$(who)` for the accepted keywords.",
	))
end

_s3_is_real(value) = value isa Real && !(value isa Bool)

function _s3_finite_real(value, who::AbstractString, name::AbstractString)
	(_s3_is_real(value) && isfinite(value)) || throw(ArgumentError(
		"$(who): `$(name)` must be a finite real number; got $(repr(value)).",
	))
	return Float64(value)
end

function _s3_unit_interval(value, who::AbstractString, name::AbstractString)
	v = _s3_finite_real(value, who, name)
	0 <= v <= 1 || throw(ArgumentError(
		"$(who): `$(name)` must lie in [0, 1]; got $(repr(value)).",
	))
	return v
end

function _s3_positive(value, who::AbstractString, name::AbstractString)
	v = _s3_finite_real(value, who, name)
	v > 0 || throw(ArgumentError("$(who): `$(name)` must be positive; got $(repr(value))."))
	return v
end

function _s3_nonnegative(value, who::AbstractString, name::AbstractString)
	v = _s3_finite_real(value, who, name)
	v >= 0 || throw(ArgumentError("$(who): `$(name)` must be >= 0; got $(repr(value))."))
	return v
end

# A colour keyword: "" (unset) or a colour plotly understands (validated with
# `_color_hex`). The user's spelling is kept so traces carry what was given.
function _s3_color(value, who::AbstractString, name::AbstractString)
	value isa Symbol && (value = String(value))
	value isa AbstractString || throw(ArgumentError(
		"$(who): `$(name)` must be a colour string or Symbol; got $(typeof(value)).",
	))
	text = String(strip(value))
	isempty(text) && return ""
	_color_hex(text; who = "$(who) (`$(name)`)")
	return text
end

function _s3_choice(value, choices, who::AbstractString, name::AbstractString)
	value isa Symbol && (value = String(value))
	(value isa AbstractString && String(value) in choices) || throw(ArgumentError(
		"$(who): `$(name)` must be one of $(join(repr.(choices), ", ")); got $(repr(value)).",
	))
	return String(value)
end

# `colorbar_title_side`: :top, :right or :bottom (strings are accepted too).
function _s3_title_side(value, who::AbstractString)
	side = value isa AbstractString ? Symbol(value) : value
	(side isa Symbol && side in _CBAR_TITLE_SIDES) || throw(ArgumentError(
		"$(who): `colorbar_title_side` must be :top, :right or :bottom; got $(repr(value)).",
	))
	return side
end

const _S3_ASPECTMODES = ("auto", "cube", "data", "manual")
const _S3_LINE_DASHES = ("solid", "dot", "dash", "longdash", "dashdot", "longdashdot")
const _S3_MARKER_SYMBOLS = (
	"circle", "circle-open", "cross", "diamond", "diamond-open", "square", "square-open", "x",
)
const _S3_TEXTPOSITIONS = (
	"top left", "top center", "top right", "middle left", "middle center",
	"middle right", "bottom left", "bottom center", "bottom right",
)

function _s3_aspectmode(value, who::AbstractString)
	value === nothing && return nothing
	value isa Symbol && (value = String(value))
	value isa AbstractString && isempty(value) && return nothing
	return _s3_choice(value, _S3_ASPECTMODES, who, "aspectmode")
end

function _s3_dash(value, who::AbstractString)
	value isa Symbol && (value = String(value))
	value isa AbstractString || throw(ArgumentError(
		"$(who): `dash` must be a string; got $(typeof(value)).",
	))
	isempty(value) && return ""
	return _s3_choice(value, _S3_LINE_DASHES, who, "dash")
end

# A scatter3d `mode`: "" (default "lines"), "none", or "+"-joined parts of
# "lines", "markers" and "text".
function _s3_mode(value, who::AbstractString)
	value isa Symbol && (value = String(value))
	value isa AbstractString || throw(ArgumentError(
		"$(who): `mode` must be a string; got $(typeof(value)).",
	))
	mode = String(value)
	isempty(mode) && return "lines"
	mode == "none" && return mode
	for part in split(mode, '+')
		part in ("lines", "markers", "text") || throw(ArgumentError(
			"$(who): `mode` must be \"none\" or a \"+\"-joined combination of " *
			"\"lines\", \"markers\" and \"text\"; got $(repr(mode)).",
		))
	end
	return mode
end

# `view = (elev, azim)` in degrees, or `nothing`.
function _s3_view(view, who::AbstractString)
	view === nothing && return nothing
	((view isa Tuple || view isa AbstractVector) && length(view) == 2) ||
		throw(ArgumentError(
			"$(who): `view` must be `nothing` or `(elev, azim)` in degrees; got $(repr(view)).",
		))
	elev = _s3_finite_real(view[1], who, "view[1] (elevation)")
	azim = _s3_finite_real(view[2], who, "view[2] (azimuth)")
	return (elev, azim)
end

# Scene axis range in data units: `nothing` for the automatic sentinel, else
# a validated 2-element `Any[lo, hi]` (real bounds must differ).
function _s3_range(range, who::AbstractString, name::AbstractString)
	checked = _checked_range(range, who, name)
	checked === nothing && return nothing
	lo, hi = checked
	if lo isa Real && hi isa Real
		(lo isa Bool || hi isa Bool) && throw(ArgumentError(
			"$(who): `$(name)` bounds must be numbers; got $(repr(range)).",
		))
		lo == hi && throw(ArgumentError(
			"$(who): `$(name)` bounds must differ; got $(repr(range)).",
		))
	end
	return checked
end

function _s3_scene_axis_type(layout, scenekey::Symbol, axiskey::Symbol)
	scene = get(layout.fields, scenekey, nothing)
	axis = _cmn_mapping_get(scene, axiskey)
	value = _cmn_mapping_get(axis, :type)
	return value isa AbstractString ? String(value) : ""
end

# Convert a checked range to what plotly stores: log10 exponents on a log
# scene axis (bounds must be positive data values), unchanged otherwise.
function _s3_stored_range(layout, scenekey::Symbol, axiskey::Symbol, checked, who::AbstractString, name::AbstractString)
	checked === nothing && return nothing
	layout === nothing && return checked
	_s3_scene_axis_type(layout, scenekey, axiskey) == "log" || return checked
	for bound in checked
		(_s3_is_real(bound) && bound > 0) || throw(ArgumentError(
			"$(who): `$(name)` bounds on a logarithmic scene axis are data values " *
			"and must be positive; got $(repr(checked)).",
		))
	end
	return Any[log10(checked[1]), log10(checked[2])]
end

# Lighting keyword: `:default`/`nothing` (plotly's shading), `:flat`
# (unshaded, matplotlib-like) or a NamedTuple/Dict of plotly lighting fields.
const _S3_LIGHTING_KEYS = (:ambient, :diffuse, :specular, :roughness, :fresnel, :vertexnormalsepsilon, :facenormalsepsilon)
const _S3_FLAT_LIGHTING = (ambient = 1.0, diffuse = 0.0, specular = 0.0, roughness = 1.0, fresnel = 0.0)

function _s3_lighting(lighting, who::AbstractString; surface::Bool = false)
	(lighting === nothing || lighting === :default) && return (nothing, false)
	lighting === :flat && return (attr(; pairs(_S3_FLAT_LIGHTING)...), true)
	allowed = surface ? _S3_LIGHTING_KEYS[1:5] : _S3_LIGHTING_KEYS
	if lighting isa NamedTuple || lighting isa AbstractDict
		fields = Dict{Symbol, Any}()
		for (key, value) in pairs(lighting)
			name = Symbol(key)
			name in allowed || throw(ArgumentError(
				"$(who): unknown `lighting` field $(repr(name)); allowed: $(join(allowed, ", ")).",
			))
			fields[name] = _s3_nonnegative(value, who, "lighting.$(name)")
		end
		return (attr(; fields...), false)
	end
	throw(ArgumentError(
		"$(who): `lighting` must be :default, :flat, or a NamedTuple of plotly " *
		"lighting fields ($(join(allowed, ", "))); got $(repr(lighting)).",
	))
end

# Data arrays that plotly cannot draw are rejected up front (type-driven, no
# scan of the values).
function _s3_check_numeric_array(values, who::AbstractString, name::AbstractString)
	eltype(values) <: Complex && throw(ArgumentError(
		"$(who): `$(name)` has complex elements, which plotly cannot draw; pass " *
		"abs.(v), real.(v), imag.(v) or angle.(v).",
	))
	return values
end

# Boolean masks serialize as JSON true/false, which plotly treats as
# categories; send them as 0/1 instead. Every 3-D coordinate, vector and value
# array goes through this (#92). Other arrays are returned as the same object
# (lazy payloads keep their identity).
_s3_plottable(values) = (values isa AbstractArray && eltype(values) <: Bool) ? UInt8.(values) : values

# Every element must be a real number (non-finite values are allowed and
# become gaps or holes); arrays typed with a real element type need no scan.
function _s3_real_elements(values, who::AbstractString, name::AbstractString)
	T = eltype(values)
	(T <: Real && !(T <: Bool) && T !== Union{}) && return nothing
	for (index, value) in pairs(values)
		(value isa Real) || throw(ArgumentError(
			"$(who): `$(name)[$(index)]` must be a real number; got $(repr(value)).",
		))
	end
	return nothing
end

function _s3_all_finite(values, who::AbstractString, name::AbstractString)
	for (index, value) in pairs(values)
		(_s3_is_real(value) && isfinite(value)) || throw(ArgumentError(
			"$(who): `$(name)[$(index)]` must be a finite real number; got $(repr(value)).",
		))
	end
	return nothing
end

#endregion

#region Scene options shared by every 3-D constructor and mutator

struct _S3Options
	xrange::Any
	yrange::Any
	zrange::Any
	xlabel::String
	ylabel::String
	zlabel::String
	aspectmode::Union{Nothing, String}
	perspective::Union{Nothing, Bool}
	grid::Union{Nothing, Bool}
	showaxis::Union{Nothing, Bool}
	title::String
	width::Real
	height::Real
	fontsize::Real
	view::Union{Nothing, NTuple{2, Float64}}
end

# Validate the common scene keywords before anything is written. `fig` is the
# figure a mutator will update (its scene axis types decide how ranges are
# stored) or `nothing` for a constructor. `nothing` values mean "unchanged".
function _s3_options(
	who::AbstractString,
	fig;
	xrange = nothing,
	yrange = nothing,
	zrange = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = nothing,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	title::AbstractString = "",
	width = 0,
	height = 0,
	fontsize = 0,
	view = nothing,
	scenekey::Symbol = :scene,
)
	layout = fig === nothing ? nothing : _plot_layout(fig)
	ranges = map(((:xaxis, xrange, "xrange"), (:yaxis, yrange, "yrange"), (:zaxis, zrange, "zrange"))) do (axis, range, name)
		_s3_stored_range(layout, scenekey, axis, _s3_range(range, who, name), who, name)
	end
	_require_size_option(width, who, "width")
	_require_size_option(height, who, "height")
	_require_size_option(fontsize, who, "fontsize")
	isempty(title) || _label(title)
	return _S3Options(
		ranges[1],
		ranges[2],
		ranges[3],
		_label3d(xlabel),
		_label3d(ylabel),
		_label3d(zlabel),
		_s3_aspectmode(aspectmode, who),
		perspective,
		grid,
		showaxis,
		String(title),
		width,
		height,
		fontsize,
		_s3_view(view, who),
	)
end

# Constructor defaults: labels "x"/"y"/"z", and Bool options that only write
# when they differ from plotly's default.
function _s3_constructor_options(
	who::AbstractString;
	xrange,
	yrange,
	zrange,
	xlabel::AbstractString,
	ylabel::AbstractString,
	zlabel::AbstractString,
	aspectmode,
	perspective::Bool,
	grid::Bool,
	showaxis::Bool,
	title::AbstractString,
	width,
	height,
	fontsize,
	view,
)
	return _s3_options(
		who,
		nothing;
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		xlabel = isempty(xlabel) ? "x" : xlabel,
		ylabel = isempty(ylabel) ? "y" : ylabel,
		zlabel = isempty(zlabel) ? "z" : zlabel,
		aspectmode = aspectmode === nothing ? "auto" : aspectmode,
		perspective = perspective ? nothing : false,
		grid = grid ? nothing : false,
		showaxis = showaxis ? nothing : false,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		view = view,
	)
end

# The empty-scene layout every constructor starts from.
_s3_constructor_layout() = Layout(
	scene = attr(
		xaxis = attr(zeroline = false),
		yaxis = attr(zeroline = false),
		zaxis = attr(zeroline = false),
	),
)

# What PlotlySupply set automatically in a scene before a 3-D call, so the
# call may update it (`_s3_scene_state`, `_s3_finish_scene!`): `pinned`, a
# manual aspect equal to the equal-unit ("data") ratios of the current spans
# (written for explicit ranges or by `view!`); `auto_camera`, a camera without
# an eye or with the eye at the automatic distance for the current box and
# viewport; `auto_ticks`, per axis, an `nticks` that is unset or equal to the
# automatic count of `_s3_auto_nticks`. A cube-shaped manual aspect is never
# taken as pinned (a user's (1, 1, 1) cannot be told apart), and a user's
# `nticks` equal to the automatic count is taken as automatic.
struct _S3SceneState
	pinned::Bool
	auto_camera::Bool
	auto_ticks::NTuple{3, Bool}
end

const _S3_NEW_SCENE = _S3SceneState(false, true, (true, true, true))

# Write the validated options. Constructors apply the default template;
# mutators keep the figure's template and only refresh the legend. The camera
# (`view`) is applied last because its automatic distance depends on the
# figure size and the scene aspect.
function _s3_apply_options!(
	fig,
	opts::_S3Options,
	who::AbstractString;
	constructor::Bool,
	scenekey::Symbol = :scene,
	state::Union{Nothing, _S3SceneState} = nothing,
)
	_apply_figure_title!(fig, opts.title)
	scene = Dict{Symbol, Any}()
	opts.aspectmode === nothing || (scene[:aspectmode] = opts.aspectmode)
	opts.perspective === nothing || (scene[:camera] = attr(
		projection = attr(type = opts.perspective ? "perspective" : "orthographic"),
	))
	for (key, label, range) in (
		(:xaxis, opts.xlabel, opts.xrange),
		(:yaxis, opts.ylabel, opts.yrange),
		(:zaxis, opts.zlabel, opts.zrange),
	)
		axis = Dict{Symbol, Any}()
		isempty(label) || (axis[:title] = attr(text = label))
		opts.grid === nothing || (axis[:showgrid] = opts.grid)
		opts.showaxis === nothing || (axis[:visible] = opts.showaxis)
		range === nothing || (axis[:range] = range)
		isempty(axis) || (scene[key] = attr(; axis...))
	end
	isempty(scene) || _merge_scene_layout_attr!(_plot_layout(fig), scenekey, attr(; scene...))
	_apply_figure_size!(fig, who; width = opts.width, height = opts.height)
	# A legend first created by an append gets the box of the figure's own
	# template (dark on plotly_dark), as in the other families (X13).
	constructor ? _apply_default_template!(fig) :
		_apply_default_legend!(fig; _figure_legend_defaults(fig)...)
	_apply_figure_fontsize!(fig, who, opts.fontsize)
	(opts.view === nothing && state === nothing) && return nothing
	target = _cell_target(fig; who = who)
	(target.kind === :scene && target.scenekey === scenekey) || return nothing
	if state !== nothing
		# An aspect mode given now replaces what was pinned automatically.
		opts.aspectmode === nothing || (state = _S3SceneState(false, state.auto_camera, state.auto_ticks))
		_s3_finish_scene!(fig, target, state; frame = opts.view === nothing)
	end
	opts.view === nothing ||
		_s3_apply_view!(fig, target, _S3ViewParams(opts.view[1], opts.view[2], :auto, :z, nothing, 1.0))
	state === nothing || _s3_finish_ticks!(fig, target, state)
	return nothing
end

# The scene state a Plot-level mutator records before it adds traces
# (`_s3_finish_scene!`), or `nothing` when there is nothing to finish: inside
# the SubplotFigure delegate (the staged figure is empty; `_s3_subplot!`
# finishes the real cell) or when `fig` holds no 3-D scene yet.
function _s3_mutator_state(fig, who::AbstractString)
	_S3_CELL_CONTEXT[] === nothing || return nothing
	isempty(_plot_data(fig)) && return _S3_NEW_SCENE
	target = _cell_target(fig; who = who)
	(target.kind === :scene && target.scenekey === :scene) || return nothing
	return _s3_scene_state(fig, target)
end

# `show = true` opens an Electron window sized like the figure; 960×720 and
# the "PlotlySupply" window title are the defaults every other constructor
# uses (`_maybe_show` in api.jl).
function _s3_show(fig, show::Bool, opts::_S3Options)
	show || return fig
	return to_syncplot(
		fig;
		width = opts.width > 0 ? opts.width : 960,
		height = opts.height > 0 ? opts.height : 720,
		title = isempty(opts.title) ? "PlotlySupply" : opts.title,
	)
end

#endregion

#region Docstring building blocks

# Every 3-D docstring lists each keyword with its type, default and meaning.
# The keyword groups shared by several functions are generated here; the
# function-specific parts are raw strings, so `$…$` and TeX macros in them
# need no escaping.

const _S3_TEXT3D_DOC = raw"""Scene axis titles and tick labels are drawn by WebGL, which cannot typeset TeX: `$…$` is converted to Unicode and `<b>`/`<i>`/`<sub>`/`<sup>` (`$x_1$` gives x with a subscript 1, `$\mathbf{b}$` a bold b, `$\lambda^2$` λ with a superscript 2, `$\alpha$` α); an unsupported macro is shown as written and warns once."""

const _S3_FRAMING_DOC = raw"""plotly.js sizes an "auto"/"data" scene by the extent of its data and ignores explicit axis ranges, so a scene with a range is written as `aspectmode = "manual"` with the proportions of the axis spans: equal units for "data", and for "auto" the same unless one span exceeds four times another (then a cube). Ratios pinned this way (other than a cube) are updated when later 3-D calls add data. A perspective scene without a camera gets plotly's default camera direction at the automatic distance of [`view!`](@ref), which fits the scene box and room for its tick labels into its viewport (the figure size, else 700×500 px, and the cell domain); later 3-D calls keep such an automatic distance up to date. In a subplot cell, axes with automatic ticks get a tick count that suits the cell size (see [`view!`](@ref))."""

const _S3_OPACITY_LINE_DOC = raw"""translucent scatter3d lines were observed to make other 3-D traces in the same scene vanish, so a line with `opacity < 1` is drawn in the opaque colour it would have over the scene background (`paper_bgcolor` and `scene.bgcolor`, from the layout or the template). Over coloured faces this is an approximation."""

function _s3_scene_doc(constructor::Bool, aspectmode::AbstractString)
	if constructor
		return """
		# Scene keywords

		- `xlabel::AbstractString = ""`, `ylabel::AbstractString = ""`,
		  `zlabel::AbstractString = ""`: axis titles (`""` gives "x", "y" and "z").
		  $(_S3_TEXT3D_DOC)
		- `xrange = [0, 0]`, `yrange = [0, 0]`, `zrange = [0, 0]`: axis ranges
		  `[lo, hi]` (vector or tuple) in data units; `[0, 0]` is automatic.
		- `aspectmode = $(aspectmode)`: "auto", "cube", "data" or "manual" (set the
		  ratios with [`scene!`](@ref)). $(_S3_FRAMING_DOC)
		- `perspective::Bool = true`: `false` selects an orthographic projection.
		- `grid::Bool = true`: `false` hides the grid lines.
		- `showaxis::Bool = true`: `false` hides the axes.
		- `view = nothing`: `(elev, azim)` camera angles in degrees, as
		  [`view!`](@ref).
		- `title::AbstractString = ""`: figure title (TeX is typeset by MathJax).
		- `width::Real = 0`, `height::Real = 0`: figure size in px (0: automatic).
		- `fontsize::Real = 0`: base font size (0: the template's).
		- `show::Bool = false`: open the figure in an Electron window and return the
		  `SyncPlot` instead of the `Plot`.
		"""
	end
	return """
	# Scene keywords

	Keywords left at their defaults keep the existing scene.

	- `xlabel::AbstractString = ""`, `ylabel::AbstractString = ""`,
	  `zlabel::AbstractString = ""`: new axis titles. $(_S3_TEXT3D_DOC)
	- `xrange = [0, 0]`, `yrange = [0, 0]`, `zrange = [0, 0]`: axis ranges
	  `[lo, hi]` in data units, also on a logarithmic scene axis.
	- `aspectmode = nothing`: "auto", "cube", "data" or "manual". $(_S3_FRAMING_DOC)
	- `perspective::Union{Nothing, Bool} = nothing`: `true`/`false` selects a
	  perspective/orthographic projection.
	- `grid::Union{Nothing, Bool} = nothing`: show or hide the grid lines.
	- `showaxis::Union{Nothing, Bool} = nothing`: show or hide the axes.
	- `view = nothing`: `(elev, azim)` camera angles in degrees, as
	  [`view!`](@ref).
	- `title::AbstractString = ""`, `width::Real = 0`, `height::Real = 0`,
	  `fontsize::Real = 0`: figure title, size in px and base font size. On a
	  `SubplotFigure` cell `title`, `width` and `height` belong to the whole
	  figure and are ignored with a warning.
	- `row::Integer`, `col::Integer` (`SubplotFigure` only; default: the active
	  cell): the target cell, which must be a 3-D scene
	  (`Spec(kind = "scene")`); it becomes the active cell.
	- `secondary_y::Bool = false` (`SubplotFigure` only): accepted for
	  uniformity with the 2-D mutators; a scene has no secondary y axis, so
	  `true` throws.

	`show` is a constructor keyword: passing it to a mutator throws an
	`ArgumentError`, as does any unknown keyword.
	"""
end

function _s3_color_doc(colorscale_default::AbstractString, note::AbstractString)
	text = """
	# Colour keywords

	- `colorscale = $(colorscale_default)`: the colormap: a name (plotly's
	  "Viridis", matplotlib's "viridis", "plasma", "coolwarm", …; a "_r" suffix
	  reverses it), a vector of colours, `(t, colour)` stops or a `ColorScheme`.
	  Unknown names throw.
	- `crange = [0, 0]`: colour limits `[lo, hi]`; `[0, 0]` is automatic.
	- `cmid = nothing`: the value at the middle of the colormap (diverging data).
	- `colornorm = :linear`: `:linear` or `:log` (log10 colour mapping with
	  decade ticks).
	- `levels = nothing`: k+1 increasing boundaries for k discrete colour bands.
	- `showscale::Union{Nothing, Bool} = nothing`: show or hide the colorbar
	  (`nothing`: plotly's default).
	- `colorbar_title::AbstractString = ""`: colorbar title (TeX is typeset by
	  MathJax; a `\$…\$` title is drawn as a layout annotation named
	  `"plotlysupply:colorbar_title:<scene or coloraxis id>:<side>"` next to the
	  bar, because plotly.js misplaces MathJax colorbar titles).
	- `colorbar_title_side = :top`: where the title sits: `:top`, `:right`
	  (rotated along the bar, right of the tick labels) or `:bottom`. Other
	  values throw, even without a title.
	- `colorbar_ticks = nothing`, `colorbar_ticklabels = nothing`: colorbar tick
	  positions (data values) and their labels.
	- `coloraxis = nothing`: `:shared` (= "coloraxis") or "coloraxis2", …:
	  traces on the same colour axis share one colour scale and colorbar, and the
	  scale keywords are written to `layout.<coloraxis>`.
	"""
	return isempty(note) ? text : text * "\n" * note * "\n"
end

const _S3_CONSTRUCTOR_RETURNS_DOC = "# Returns\n\nThe new `Plot`, or its `SyncPlot` window with `show = true`."
const _S3_MUTATOR_RETURNS_DOC = "# Returns\n\n`nothing` when `fig` is a `Plot` or `SyncPlot` (updated in place); `sf` when it is a `SubplotFigure`."

# Assemble a docstring: `head` (signatures and description), the function's
# own `keywords`, the colour keywords (when `colour`), the scene keywords,
# the return value and a runnable `example`.
function _s3_doc(
	head::AbstractString,
	keywords::AbstractString;
	constructor::Bool,
	example::AbstractString,
	colour::Bool = false,
	colorscale_default::AbstractString = "\"\"",
	colour_note::AbstractString = "",
	aspectmode::AbstractString = "\"auto\"",
)
	parts = String[rstrip(head)]
	isempty(strip(keywords)) || push!(parts, "# Keywords\n\n" * rstrip(keywords))
	colour && push!(parts, rstrip(_s3_color_doc(colorscale_default, colour_note)))
	push!(parts, rstrip(_s3_scene_doc(constructor, aspectmode)))
	push!(parts, constructor ? _S3_CONSTRUCTOR_RETURNS_DOC : _S3_MUTATOR_RETURNS_DOC)
	push!(parts, "# Examples\n\n```julia\nusing PlotlySupply\n" * rstrip(example) * "\n```")
	return join(parts, "\n\n") * "\n"
end

# The common introduction of a mutator docstring.
_s3_mutator_head(signatures::AbstractString, what::AbstractString, constructor::AbstractString) =
	rstrip(signatures) * "\n\n" *
	"Add $(what) to `fig`: a `Plot`, a `SyncPlot` (its window is updated) or a " *
	"`SubplotFigure`, whose 3-D scene cell is chosen with `row`/`col`. Takes the " *
	"keywords of [`$(constructor)`](@ref) except `show`, and the same data layout."

#endregion

#region Colour keywords (C20/C21)

struct _S3ColorSpec
	trace::Dict{Symbol, Any}
	axis::Union{Nothing, String}
	axis_fields::Dict{Symbol, Any}
end

_S3ColorSpec() = _S3ColorSpec(Dict{Symbol, Any}(), nothing, Dict{Symbol, Any}())

# Resolve the colour keywords of one coloured trace. `values` are the colour
# data (`nothing` when plotly computes them, e.g. the vector norm of cones);
# when `values_key` is given the (possibly log-transformed) values are written
# there. With a `coloraxis` the scale, limits and colorbar go to
# `layout.<coloraxis>` instead of the trace.
function _s3_color_spec(
	values,
	who::AbstractString;
	values_key::Union{Nothing, Symbol} = nothing,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	log_unsupported::AbstractString = "",
)
	# Validated even without a title, so a typo never passes silently.
	title_side = _s3_title_side(colorbar_title_side, who)
	title = _colorbar_title_attr(colorbar_title, title_side; who = who)
	norm = _normalize_colornorm(colornorm, who)
	if norm === :log && !isempty(log_unsupported)
		throw(ArgumentError("$(who): colornorm=:log is not supported here: $(log_unsupported)"))
	end
	res = _apply_color_norm(
		values;
		crange = crange,
		cmid = cmid,
		colornorm = norm,
		levels = levels,
		stops = colorscale,
		ticks = colorbar_ticks,
		ticklabels = colorbar_ticklabels,
		who = who,
	)
	trace = Dict{Symbol, Any}()
	(values_key !== nothing && values !== nothing) && (trace[values_key] = res.values)
	fields = Dict{Symbol, Any}()
	(res.stops isa AbstractString && isempty(res.stops)) || (fields[:colorscale] = res.stops)
	res.cmin === nothing || (fields[:cmin] = res.cmin)
	res.cmax === nothing || (fields[:cmax] = res.cmax)
	res.cmid === nothing || (fields[:cmid] = res.cmid)
	showscale === nothing || (fields[:showscale] = showscale)
	# User tick labels may contain TeX (the colorbar is SVG, so MathJax works);
	# generated log/levels labels are already plotly HTML.
	ticktext = res.ticktext
	if colorbar_ticklabels !== nothing && ticktext !== nothing
		ticktext = String[_label(label) for label in ticktext]
	end
	colorbar = _colorbar_attr(ticks = res.tickvals, ticklabels = ticktext, who = who)
	if title !== nothing
		# `title.side` comes from `colorbar_title_side`; a math title is moved
		# to an annotation by `_colorbar_math_titles!` once the trace is placed.
		bar = colorbar === nothing ? Dict{Symbol, Any}() : _symbol_dict(colorbar)
		bar[:title] = title
		colorbar = attr(; bar...)
	end
	colorbar === nothing || (fields[:colorbar] = colorbar)
	if coloraxis === nothing
		merge!(trace, fields)
		return _S3ColorSpec(trace, nothing, Dict{Symbol, Any}())
	end
	id = _normalize_coloraxis(coloraxis, who)
	trace[:coloraxis] = id
	return _S3ColorSpec(trace, id, fields)
end

# True when any colour-scale keyword differs from its default; used to reject
# them next to a uniform colour.
function _s3_colormap_requested(; colorscale, crange, cmid, colornorm, levels, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who::AbstractString)
	return !_is_unset_colorscale(colorscale) ||
		!_is_auto_range(crange) ||
		cmid !== nothing ||
		!(colornorm === :linear || colornorm == "linear") ||
		levels !== nothing ||
		!isempty(colorbar_title) ||
		_s3_title_side(colorbar_title_side, who) !== :top ||
		colorbar_ticks !== nothing ||
		colorbar_ticklabels !== nothing ||
		coloraxis !== nothing
end

#endregion

#region Default colours and the scene background

# A SubplotFigure cell mutation runs the mutator on an empty staging figure
# (`_subplot_delegate_mutator_impl!`). This context, set by `_s3_subplot!` for
# the duration of that call, lets the mutator see the real figure: default
# trace colours count the traces already in it, and translucent lines are
# blended over the target cell's scene background.
struct _S3CellContext
	plot::Plot
	scenekey::Symbol
	offset::Int
end

const _S3_CELL_CONTEXT = Base.ScopedValues.ScopedValue{Union{Nothing, _S3CellContext}}(nothing)

# Default colour of the `index`-th trace: from `fig`'s colorway/template, or
# from the package default template when `fig` is `nothing` (constructors).
function _s3_default_color(fig, index::Integer)
	context = _S3_CELL_CONTEXT[]
	context === nothing || return _default_trace_color(context.plot, context.offset + index)
	source = fig === nothing ? Layout(template = _resolve_template(_DEFAULT_TEMPLATE[])) : fig
	return _default_trace_color(source, index)
end

# Opaque colour a 3-D scene shows behind its content: `scene.bgcolor` (layout,
# then template) composited over `paper_bgcolor` (layout, then template, then
# white). Used to pre-blend translucent 3-D lines (ADDENDUM B2).
function _s3_scene_background(fig, scenekey::Symbol)
	context = _S3_CELL_CONTEXT[]
	if context !== nothing
		layout = context.plot.layout
		scenekey = context.scenekey
	elseif fig === nothing
		layout = Layout(template = _resolve_template(_DEFAULT_TEMPLATE[]))
	else
		layout = _plot_layout(fig)
	end
	template = _template_object(get(layout.fields, :template, nothing))
	template_layout = template === nothing ? nothing : template.layout
	paper = get(layout.fields, :paper_bgcolor, nothing)
	paper === nothing && template_layout !== nothing && (paper = _field(template_layout, :paper_bgcolor))
	paper isa Union{AbstractString, Symbol} || (paper = "#ffffff")
	base = _blend_over(paper, 1.0, "#ffffff"; who = "scene background")
	scene_bg = _cmn_mapping_get(get(layout.fields, scenekey, nothing), :bgcolor)
	if scene_bg === nothing && template_layout !== nothing
		scene_bg = _cmn_mapping_get(_field(template_layout, :scene), :bgcolor)
	end
	scene_bg isa Union{AbstractString, Symbol} || return base
	return _blend_over(scene_bg, 1.0, base; who = "scene background")
end

# Opaque line colour for `color` drawn at `opacity` over the scene background.
function _s3_line_color(color::AbstractString, opacity::Float64, fig, scenekey::Symbol, who::AbstractString)
	opacity >= 1 && return color
	return _blend_over(color, opacity, _s3_scene_background(fig, scenekey); who = who)
end

#endregion

#region Camera: view!

# plotly.js draws a perspective scene with a vertical field of view of π/4
# (gl-plot3d `fovy`, checked in the bundled plotly.min.js), so π/8 is the
# half angle.
const _S3_HALF_FOVY = π / 8
# The automatic camera distance keeps this many font sizes free on each side
# of the viewport for the tick labels and axis titles drawn outside the scene
# box (one line of tick labels, its offset and one line of axis title; checked
# by render at 700×500 px). A tiny viewport keeps at least _S3_MIN_FILL of its
# half-size for the box.
const _S3_LABEL_PAD_FONTS = 3.0
const _S3_MIN_FILL = 0.5
# plotly.js's default font size (layout.font.size).
const _S3_DEFAULT_FONT_SIZE = 12.0
# Viewport assumed when the layout sets no size: savefig's default export size
# and the margins PlotlyBase's `Layout()` writes (l50 r50 t60 b50).
const _S3_DEFAULT_SIZE = (700.0, 500.0)
const _S3_DEFAULT_MARGIN = (l = 50.0, r = 50.0, t = 60.0, b = 50.0)
# An orthographic scene is framed independently of the eye distance
# (plotly.js projects with ortho(-w/h, w/h, -1, 1)); 2 keeps the eye outside
# any scene box whose largest aspect ratio is 1.
const _S3_ORTHO_DISTANCE = 2.0
# Elevations at or beyond this magnitude look straight down/up the vertical
# axis, where (0, 0, 1) cannot be the camera's up vector.
const _S3_VERTICAL_ELEVATION = 89.9
const _S3_TRACE_TYPES = ("scatter3d", "surface", "mesh3d", "cone", "streamtube", "isosurface", "volume")

function _s3_number_field(mapping, key::Symbol, default::Float64; positive::Bool = false)
	value = _cmn_mapping_get(mapping, key)
	_s3_is_real(value) && isfinite(value) || return default
	(positive ? value > 0 : value >= 0) || return default
	return Float64(value)
end

# Pixel size of the scene's viewport: the plot area (figure size minus
# margins) times the scene's domain fractions.
function _s3_viewport(fig, target::_CellTarget)
	fields = _cmn_layout(fig).fields
	width = _s3_number_field(fields, :width, _S3_DEFAULT_SIZE[1]; positive = true)
	height = _s3_number_field(fields, :height, _S3_DEFAULT_SIZE[2]; positive = true)
	margin = get(fields, :margin, nothing)
	left = _s3_number_field(margin, :l, _S3_DEFAULT_MARGIN.l)
	right = _s3_number_field(margin, :r, _S3_DEFAULT_MARGIN.r)
	top = _s3_number_field(margin, :t, _S3_DEFAULT_MARGIN.t)
	bottom = _s3_number_field(margin, :b, _S3_DEFAULT_MARGIN.b)
	plot_width = max(width - left - right, 1.0)
	plot_height = max(height - top - bottom, 1.0)
	return (
		max(plot_width * (target.xdomain[2] - target.xdomain[1]), 1.0),
		max(plot_height * (target.ydomain[2] - target.ydomain[1]), 1.0),
	)
end

# Extend `bounds` (lo, hi) with the finite numbers in `values` (nested arrays
# are walked; log axes use log10 of the positive values, as plotly does).
function _s3_extend_bounds!(bounds::Vector{Float64}, values, log_axis::Bool)
	values isa AbstractArray || return nothing
	for value in values
		if value isa AbstractArray
			_s3_extend_bounds!(bounds, value, log_axis)
		elseif _s3_is_real(value)
			x = Float64(value)
			if log_axis
				x > 0 || continue
				x = log10(x)
			end
			isfinite(x) || continue
			x < bounds[1] && (bounds[1] = x)
			x > bounds[2] && (bounds[2] = x)
		end
	end
	return nothing
end

_s3_trace_in_scene(trace, id::String) =
	trace isa GenericTrace &&
	String(get(trace.fields, :type, "")) in _S3_TRACE_TYPES &&
	String(get(trace.fields, :scene, "scene")) == id

# `aspectmode` of a scene layout entry ("auto" when unset, plotly's default).
function _s3_scene_aspectmode(scene)
	value = _cmn_mapping_get(scene, :aspectmode)
	return value isa Union{AbstractString, Symbol} ? String(value) : "auto"
end

# The manual aspect ratios of a scene (plotly.js defaults each to 1).
_s3_manual_ratio(scene) =
	[_s3_number_field(_cmn_mapping_get(scene, :aspectratio), key, 1.0; positive = true) for key in (:x, :y, :z)]

# (lo, hi) of an explicit numeric scene-axis range in plotly's axis units
# (log10 exponents on a log axis), or `nothing` when the axis autoranges.
function _s3_explicit_range(axis_fields)
	explicit = _cmn_mapping_get(axis_fields, :range)
	((explicit isa AbstractVector || explicit isa Tuple) && length(explicit) == 2) || return nothing
	all(b -> _s3_is_real(b) && isfinite(b), explicit) || return nothing
	explicit[1] == explicit[2] && return nothing
	return (Float64(explicit[1]), Float64(explicit[2]))
end

_s3_has_explicit_range(scene) =
	any(axis -> _s3_explicit_range(_cmn_mapping_get(scene, axis)) !== nothing, (:xaxis, :yaxis, :zaxis))

# Data extent (lo, hi) of scene axis `d` (1 = x, 2 = y, 3 = z) in axis units:
# the finite values of the scene's 3-D traces (log10 of the positive ones on a
# log axis) and the positions of its visible annotations (already in axis
# units), which plotly.js gl3d both counts. `nothing` without a finite value.
function _s3_data_bounds(p::Plot, scenekey::Symbol, d::Int)
	scene = get(p.layout.fields, scenekey, nothing)
	axis = (:xaxis, :yaxis, :zaxis)[d]
	coordinate = (:x, :y, :z)[d]
	log_axis = _cmn_mapping_get(_cmn_mapping_get(scene, axis), :type) == "log"
	bounds = [Inf, -Inf]
	id = String(scenekey)
	for trace in p.data
		_s3_trace_in_scene(trace, id) || continue
		_s3_extend_bounds!(bounds, get(trace.fields, coordinate, nothing), log_axis)
	end
	annotations = _cmn_mapping_get(scene, :annotations)
	if annotations isa AbstractVector
		for item in annotations
			_cmn_mapping_get(item, :visible) === false && continue
			_s3_extend_bounds!(bounds, Any[_cmn_mapping_get(item, coordinate)], false)
		end
	end
	return bounds[1] <= bounds[2] ? (bounds[1], bounds[2]) : nothing
end

# Drawn span of each scene axis in plotly's axis units: an explicit range as
# given, else the data extent padded by 1/32 of itself on each side, or 2 for
# a single value (plotly.js gl3d autorange: `lo -= P/32, hi += P/32`, then
# `lo == hi` widens to ±1). `nothing` when some axis has neither.
function _s3_scene_spans(p::Plot, scenekey::Symbol)
	scene = get(p.layout.fields, scenekey, nothing)
	spans = zeros(3)
	for (d, axis) in enumerate((:xaxis, :yaxis, :zaxis))
		explicit = _s3_explicit_range(_cmn_mapping_get(scene, axis))
		if explicit !== nothing
			spans[d] = abs(explicit[2] - explicit[1])
			continue
		end
		bounds = _s3_data_bounds(p, scenekey, d)
		bounds === nothing && return nothing
		extent = bounds[2] - bounds[1]
		spans[d] = extent > 0 ? extent * 17 / 16 : 2.0
	end
	return spans
end

# Aspect ratios (largest 1) that give the scene's drawn spans the proportions
# `mode` asks for: "data" equal units on all axes, "auto" the same unless one
# span exceeds four times another, then a cube (plotly.js's rule). `nothing`
# when the spans are unknown.
function _s3_derived_aspect(p::Plot, scenekey::Symbol, mode::AbstractString)
	spans = _s3_scene_spans(p, scenekey)
	spans === nothing && return nothing
	largest = maximum(spans)
	mode == "auto" && largest / minimum(spans) > 4 && return ones(3)
	return spans ./ largest
end

# The scene's aspect ratios `a` (largest 1 for automatic modes) and whether
# they were derived from the data (`aspectmode` "auto"/"data"), in which case
# a camera that depends on them pins them with `aspectmode = "manual"`.
function _s3_effective_aspect(p::Plot, scenekey::Symbol)
	scene = get(p.layout.fields, scenekey, nothing)
	mode = _s3_scene_aspectmode(scene)
	mode == "manual" && return (_s3_manual_ratio(scene), false)
	mode == "cube" && return (ones(3), false)
	derived = _s3_derived_aspect(p, scenekey, mode)
	derived === nothing && return (ones(3), false)
	return (derived, true)
end

# The box plotly.js draws for the scene, in the units of the camera: the
# manual ratios, a unit cube for "cube", and for "auto"/"data" the data
# extents (1 for a single value) divided by their geometric mean over the axes
# of the same type, with "auto" falling back to the cube when one exceeds four
# times another (gl3d scene layout, plotly.js 2.35.2). Unlike
# `_s3_effective_aspect` it predicts an unpinned "auto"/"data" scene exactly.
# `nothing` when the data cannot tell.
function _s3_drawn_box(p::Plot, scenekey::Symbol)
	scene = get(p.layout.fields, scenekey, nothing)
	mode = _s3_scene_aspectmode(scene)
	mode == "manual" && return _s3_manual_ratio(scene)
	mode == "cube" && return ones(3)
	extents = zeros(3)
	types = String[]
	for (d, axis) in enumerate((:xaxis, :yaxis, :zaxis))
		bounds = _s3_data_bounds(p, scenekey, d)
		bounds === nothing && return nothing
		extents[d] = bounds[2] > bounds[1] ? bounds[2] - bounds[1] : 1.0
		axis_type = _cmn_mapping_get(_cmn_mapping_get(scene, axis), :type)
		push!(types, axis_type isa AbstractString && !isempty(axis_type) ? String(axis_type) : "linear")
	end
	box = map(1:3) do d
		group = [extents[k] for k in 1:3 if types[k] == types[d]]
		extents[d] / prod(group)^(1 / length(group))
	end
	mode == "auto" && maximum(box) / minimum(box) > 4 && return ones(3)
	return box
end

# Largest font size that the scene's labels use: layout.font.size and the
# scene axes' tick and title fonts (plotly.js's 12 when none is set).
function _s3_label_font_size(p::Plot, scenekey::Symbol)
	size = _s3_number_field(_cmn_mapping_get(p.layout.fields, :font), :size, _S3_DEFAULT_FONT_SIZE; positive = true)
	scene = get(p.layout.fields, scenekey, nothing)
	for axis in (:xaxis, :yaxis, :zaxis)
		fields = _cmn_mapping_get(scene, axis)
		for font in (_cmn_mapping_get(fields, :tickfont), _cmn_mapping_get(_cmn_mapping_get(fields, :title), :font))
			size = max(size, _s3_number_field(font, :size, 0.0))
		end
	end
	return size
end

_s3_dot(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
_s3_cross(a, b) = (a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1])
_s3_norm(a) = sqrt(_s3_dot(a, a))

# The camera's up vector (plotly.js's default (0, 0, 1) when unset or zero).
function _s3_camera_up(camera)
	up = _s3_vector3(_cmn_mapping_get(camera, :up))
	return _s3_norm(up) > 0 ? (up[1], up[2], up[3]) : (0.0, 0.0, 1.0)
end

# Camera distance at which the scene box `box` (the full side lengths; gl-plot3d
# scales each axis range to `aspectratio[d]` and centres it on the camera
# centre) fits the target's viewport, less the label padding, in a perspective
# view from the unit `direction` (centre to eye) with up vector `up`, divided
# by `zoom`. The box is centred on the scene origin; `center` is the camera
# centre the eye looks at. A pinhole camera at center + d·v with right vector r
# and true up u puts the box corner at offset q from `center` at
# x = (q·r) / ((d - q·v) tan(fovy/2) w/h) and
# y = (q·u) / ((d - q·v) tan(fovy/2)) in normalised device coordinates, so
# |x| ≤ limit_x and |y| ≤ limit_y bound d from below for every corner; the
# largest bound is the tightest distance that shows the whole box. When `up` is
# parallel to `direction` (no defined roll) the box's bounding sphere is fitted
# into the smaller of the two half-angles instead.
function _s3_auto_distance(fig, target::_CellTarget, box, direction, up, zoom::Float64 = 1.0; center = (0.0, 0.0, 0.0))
	p = _cmn_plot(fig)
	width, height = _s3_viewport(fig, target)
	pad = _S3_LABEL_PAD_FONTS * _s3_label_font_size(p, target.scenekey)
	limit_x = max(1 - 2 * pad / width, _S3_MIN_FILL)
	limit_y = max(1 - 2 * pad / height, _S3_MIN_FILL)
	tan_half = tan(_S3_HALF_FOVY)
	ratio = width / height
	v = direction ./ _s3_norm(direction)
	right = _s3_cross(.-v, up)
	right_norm = _s3_norm(right)
	if !(right_norm > 1e-9 * _s3_norm(up))
		radius = 0.5 * sqrt(sum(abs2, box)) + _s3_norm(center)
		half_angle = atan(min(limit_x * ratio, limit_y) * tan_half)
		return radius / sin(half_angle) / zoom
	end
	r = right ./ right_norm
	u = _s3_cross(r, .-v)
	distance = 0.0
	for sx in (-0.5, 0.5), sy in (-0.5, 0.5), sz in (-0.5, 0.5)
		q = (sx * box[1] - center[1], sy * box[2] - center[2], sz * box[3] - center[3])
		depth = _s3_dot(q, v)
		distance = max(
			distance,
			depth + abs(_s3_dot(q, r)) / (tan_half * ratio * limit_x),
			depth + abs(_s3_dot(q, u)) / (tan_half * limit_y),
		)
	end
	return distance / zoom
end

_s3_vector3(mapping, default::Float64 = 0.0) = [
	(value = _cmn_mapping_get(mapping, key); (_s3_is_real(value) && isfinite(value)) ? Float64(value) : default)
	for key in (:x, :y, :z)
]

function _s3_scene_state(fig, target::_CellTarget)
	p = _cmn_plot(fig)
	key = target.scenekey
	scene = get(p.layout.fields, key, nothing)
	pinned = false
	if _s3_scene_aspectmode(scene) == "manual"
		derived = _s3_derived_aspect(p, key, "data")
		pinned = derived !== nothing && !all(isone, derived) &&
			isapprox(_s3_manual_ratio(scene), derived; rtol = 1e-9)
	end
	camera = _cmn_mapping_get(scene, :camera)
	eye = _cmn_mapping_get(camera, :eye)
	auto_camera = eye === nothing
	if !auto_camera
		box = _s3_drawn_box(p, key)
		offset = _s3_vector3(eye, NaN) .- _s3_vector3(_cmn_mapping_get(camera, :center))
		current = sqrt(sum(abs2, offset))
		auto_camera = box !== nothing && isfinite(current) && current > 0 && isapprox(
			current,
			_s3_auto_distance(
				fig, target, box, offset ./ current, _s3_camera_up(camera);
				center = _s3_vector3(_cmn_mapping_get(camera, :center)),
			);
			rtol = 1e-9,
		)
	end
	counts = _s3_auto_nticks(fig, target)
	auto_ticks = ntuple(3) do d
		nticks = _cmn_mapping_get(_cmn_mapping_get(scene, (:xaxis, :yaxis, :zaxis)[d]), :nticks)
		nticks === nothing || (counts !== nothing && _s3_is_real(nticks) && nticks == counts[d])
	end
	return _S3SceneState(pinned, auto_camera, auto_ticks)
end

# plotly.js gives a 3-D axis with automatic ticks `nticks || clamp(L / 40, 4, 9)`
# ticks, where L is the axis length in pixels it computes from the size of the
# whole figure canvas (gl3d tick_marks and gl-axes pixel range, plotly.js
# 2.35.2). A scene in a subplot cell is much smaller than that canvas, so its
# short edges get four to nine labels that overlap. A scene whose domain is
# smaller than the plot area therefore gets nticks = clamp(floor(L / 40), 2, 9)
# per axis from the axis's projected length L in its own viewport (the
# centre line of the scene box, seen from its camera); 40 px per tick and the
# upper bound 9 are plotly.js's own, 2 keeps both ends of a short axis
# labelled. `nothing` for a full-size scene or when the camera cannot tell.
const _S3_TICK_SPACING_PX = 40.0
const _S3_MIN_CELL_TICKS = 2
const _S3_MAX_AUTO_TICKS = 9

function _s3_auto_nticks(fig, target::_CellTarget)
	full = target.xdomain[2] - target.xdomain[1] >= 1 - 1e-9 && target.ydomain[2] - target.ydomain[1] >= 1 - 1e-9
	full && return nothing
	p = _cmn_plot(fig)
	box = _s3_drawn_box(p, target.scenekey)
	box === nothing && return nothing
	lengths = _s3_axis_pixel_lengths(fig, target, box)
	lengths === nothing && return nothing
	return map(lengths) do length_px
		clamp(floor(Int, length_px / _S3_TICK_SPACING_PX), _S3_MIN_CELL_TICKS, _S3_MAX_AUTO_TICKS)
	end
end

# Projected length in viewport pixels of the scene box's centre line along each
# axis (the box has side lengths `box` and is centred on the scene origin),
# with the scene's camera (plotly.js's default eye (1.25, 1.25, 1.25) when
# unset) and projection: perspective with the vertical field of view
# 2·_S3_HALF_FOVY, or orthographic ortho(-w/h, w/h, -1, 1). `nothing` when the
# camera is degenerate or a point lies behind a perspective eye.
function _s3_axis_pixel_lengths(fig, target::_CellTarget, box)
	p = _cmn_plot(fig)
	camera = _cmn_mapping_get(get(p.layout.fields, target.scenekey, nothing), :camera)
	orthographic = _cmn_mapping_get(_cmn_mapping_get(camera, :projection), :type) == "orthographic"
	eye_value = _cmn_mapping_get(camera, :eye)
	eye = eye_value === nothing ? [1.25, 1.25, 1.25] : _s3_vector3(eye_value, NaN)
	offset = eye .- _s3_vector3(_cmn_mapping_get(camera, :center))
	distance = _s3_norm(offset)
	(isfinite(distance) && distance > 0) || return nothing
	v = offset ./ distance
	up = _s3_camera_up(camera)
	right = _s3_cross(.-v, up)
	right_norm = _s3_norm(right)
	right_norm > 1e-9 * _s3_norm(up) || return nothing
	r = right ./ right_norm
	u = _s3_cross(r, .-v)
	width, height = _s3_viewport(fig, target)
	ratio = width / height
	tan_half = tan(_S3_HALF_FOVY)
	function project(point)
		q = point .- eye
		x, y, depth = _s3_dot(q, r), _s3_dot(q, u), -_s3_dot(q, v)
		orthographic && return (x / ratio * width / 2, y * height / 2)
		depth > 0 || return nothing
		return (x / (depth * tan_half * ratio) * width / 2, y / (depth * tan_half) * height / 2)
	end
	lengths = zeros(3)
	for d in 1:3
		half = zeros(3)
		half[d] = box[d] / 2
		a, b = project(half), project(.-half)
		(a === nothing || b === nothing) && return nothing
		lengths[d] = hypot(a[1] - b[1], a[2] - b[2])
	end
	return lengths
end

# A user's tick placement (tick values, a tick step or a non-automatic tick
# mode) makes plotly.js ignore `nticks`.
function _s3_user_ticks(axis_fields)
	mode = _cmn_mapping_get(axis_fields, :tickmode)
	(mode !== nothing && mode != "auto") && return true
	return _cmn_mapping_get(axis_fields, :tickvals) !== nothing || _cmn_mapping_get(axis_fields, :dtick) !== nothing
end

# Write the automatic tick counts of `_s3_auto_nticks` on the axes whose
# `nticks` was automatic before the 3-D call (`state`) and whose ticks the user
# does not place.
function _s3_finish_ticks!(fig, target::_CellTarget, state::_S3SceneState)
	counts = _s3_auto_nticks(fig, target)
	counts === nothing && return nothing
	p = _cmn_plot(fig)
	scene = get(p.layout.fields, target.scenekey, nothing)
	updates = Dict{Symbol, Any}()
	for (d, axis) in enumerate((:xaxis, :yaxis, :zaxis))
		state.auto_ticks[d] || continue
		fields = _cmn_mapping_get(scene, axis)
		_s3_user_ticks(fields) && continue
		_cmn_mapping_get(fields, :nticks) == counts[d] && continue
		updates[axis] = attr(nticks = counts[d])
	end
	isempty(updates) || _merge_scene_layout_attr!(p.layout, target.scenekey, attr(; updates...))
	return nothing
end

# Direction of plotly.js's default camera eye (1.25, 1.25, 1.25).
const _S3_DEFAULT_EYE_DIRECTION = (1.0, 1.0, 1.0) ./ sqrt(3.0)

# After a 3-D call changed a scene (`state` taken before it):
# 1. aspect: plotly.js scales "auto"/"data" scenes by the data extents and
#    ignores explicit axis ranges, which distorts a scene with a range. Such a
#    scene is written as `aspectmode = "manual"` with the ratios of the drawn
#    spans (equal units for "data"); a scene pinned before is re-derived.
# 2. camera (`frame`): a perspective camera without an eye, or at the
#    automatic distance, is moved to the automatic distance for the new box
#    and the scene's viewport, keeping its direction (plotly's default
#    direction when it had none), so the scene neither overflows its domain
#    (plotly's fixed default eye clips elongated and narrow scenes) nor goes
#    stale when data is added.
function _s3_finish_scene!(fig, target::_CellTarget, state::_S3SceneState; frame::Bool = true)
	p = _cmn_plot(fig)
	key = target.scenekey
	scene = get(p.layout.fields, key, nothing)
	mode = _s3_scene_aspectmode(scene)
	pin_mode = (mode in ("auto", "data") && _s3_has_explicit_range(scene)) ? mode :
		(mode == "manual" && state.pinned) ? "data" : nothing
	if pin_mode !== nothing
		derived = _s3_derived_aspect(p, key, pin_mode)
		derived === nothing || _merge_scene_layout_attr!(p.layout, key, attr(
			aspectmode = "manual",
			aspectratio = attr(x = derived[1], y = derived[2], z = derived[3]),
		))
	end
	(frame && state.auto_camera) || return nothing
	scene = get(p.layout.fields, key, nothing)
	camera = _cmn_mapping_get(scene, :camera)
	_cmn_mapping_get(_cmn_mapping_get(camera, :projection), :type) == "orthographic" && return nothing
	box = _s3_drawn_box(p, key)
	box === nothing && return nothing
	center = _s3_vector3(_cmn_mapping_get(camera, :center))
	eye = _cmn_mapping_get(camera, :eye)
	offset = eye === nothing ? fill(NaN, 3) : _s3_vector3(eye, NaN) .- center
	current = sqrt(sum(abs2, offset))
	direction = (isfinite(current) && current > 0) ? offset ./ current : collect(_S3_DEFAULT_EYE_DIRECTION)
	position = center .+ _s3_auto_distance(fig, target, box, direction, _s3_camera_up(camera); center = center) .* direction
	_merge_scene_layout_attr!(p.layout, key, attr(
		camera = attr(eye = attr(x = position[1], y = position[2], z = position[3])),
	))
	return nothing
end

struct _S3ViewParams
	elev::Float64
	azim::Float64
	distance::Union{Symbol, Float64}
	up::Symbol
	projection::Union{Nothing, String}
	zoom::Float64
end

function _s3_view_params(who::AbstractString; elev, azim, distance, up, projection, zoom)
	elevation = _s3_finite_real(elev, who, "elev")
	azimuth = _s3_finite_real(azim, who, "azim")
	if distance !== :auto
		_s3_is_real(distance) || throw(ArgumentError(
			"$(who): `distance` must be :auto or a positive number; got $(repr(distance)).",
		))
		distance = _s3_positive(distance, who, "distance")
	end
	up isa AbstractString && (up = Symbol(up))
	up in (:x, :y, :z) || throw(ArgumentError(
		"$(who): `up` (the vertical axis) must be :x, :y or :z; got $(repr(up)).",
	))
	projection === nothing ||
		(projection = _s3_choice(projection, ("perspective", "orthographic"), who, "projection"))
	return _S3ViewParams(elevation, azimuth, distance, up, projection, _s3_positive(zoom, who, "zoom"))
end

# matplotlib `view_init(elev, azim, vertical_axis=up)`: the direction from the
# scene centre to the eye, and the camera's up vector, rolled so `up` is the
# vertical axis (matplotlib `_roll_to_vertical`).
function _s3_camera_vectors(params::_S3ViewParams)
	ce, se = cosd(params.elev), sind(params.elev)
	ca, sa = cosd(params.azim), sind(params.azim)
	direction = (ce * ca, ce * sa, se)
	up = if abs(params.elev) >= _S3_VERTICAL_ELEVATION
		params.elev > 0 ? (-ca, -sa, 0.0) : (ca, sa, 0.0)
	else
		(0.0, 0.0, 1.0)
	end
	roll(v) = params.up === :z ? v : params.up === :y ? (v[2], v[3], v[1]) : (v[3], v[1], v[2])
	return roll(direction), roll(up)
end

function _s3_apply_view!(fig, target::_CellTarget, params::_S3ViewParams)
	p = _cmn_plot(fig)
	key = target.scenekey
	scene = get(p.layout.fields, key, nothing)
	camera = _cmn_mapping_get(scene, :camera)
	projection = params.projection
	if projection === nothing
		current = _cmn_mapping_get(_cmn_mapping_get(camera, :projection), :type)
		projection = current == "orthographic" ? "orthographic" : "perspective"
	end
	direction, up = _s3_camera_vectors(params)
	scene_fields = Dict{Symbol, Any}()
	if projection == "orthographic"
		distance = params.distance === :auto ? _S3_ORTHO_DISTANCE : params.distance
		if params.zoom != 1
			# The orthographic image scales with the scene box (plotly's own
			# wheel zoom multiplies aspectratio), so zoom scales the aspect
			# ratios, normalised first so repeated calls do not compound.
			aspect, _ = _s3_effective_aspect(p, key)
			aspect = aspect ./ maximum(aspect) .* params.zoom
			scene_fields[:aspectmode] = "manual"
			scene_fields[:aspectratio] = attr(x = aspect[1], y = aspect[2], z = aspect[3])
		end
	elseif params.distance === :auto
		aspect, from_data = _s3_effective_aspect(p, key)
		center = _cmn_mapping_get(camera, :center)
		distance = _s3_auto_distance(
			fig, target, aspect, direction, up, params.zoom;
			center = [_s3_number_field_signed(center, axis) for axis in (:x, :y, :z)],
		)
		if from_data
			scene_fields[:aspectmode] = "manual"
			scene_fields[:aspectratio] = attr(x = aspect[1], y = aspect[2], z = aspect[3])
		end
	else
		distance = params.distance / params.zoom
	end
	center = _cmn_mapping_get(camera, :center)
	c = [_s3_number_field_signed(center, axis) for axis in (:x, :y, :z)]
	camera_fields = Dict{Symbol, Any}(
		:eye => attr(
			x = c[1] + distance * direction[1],
			y = c[2] + distance * direction[2],
			z = c[3] + distance * direction[3],
		),
		:up => attr(x = up[1], y = up[2], z = up[3]),
	)
	params.projection === nothing || (camera_fields[:projection] = attr(type = projection))
	scene_fields[:camera] = attr(; camera_fields...)
	_merge_scene_layout_attr!(p.layout, key, attr(; scene_fields...))
	return nothing
end

function _s3_number_field_signed(mapping, key::Symbol)
	value = _cmn_mapping_get(mapping, key)
	return (_s3_is_real(value) && isfinite(value)) ? Float64(value) : 0.0
end

function _s3_scene_target(fig, who::AbstractString; row = nothing, col = nothing)
	target = _cell_target(fig; row = row, col = col, who = who)
	target.kind === :scene || throw(ArgumentError(
		"$(who): the target is a :$(target.kind) subplot, not a 3-D scene.",
	))
	return target
end

@doc raw"""
	view!(fig; elev = 30, azim = -60, distance = :auto, up = :z, projection = nothing,
	      zoom = 1, row = nothing, col = nothing) -> fig

Point the camera of a 3-D scene like matplotlib's `ax.view_init(elev, azim)`.
The camera sits in the direction
`(cosd(elev) * cosd(azim), cosd(elev) * sind(azim), sind(elev))` from the scene
centre (the eye is `distance` times that unit vector from the camera centre),
looks at the centre, and keeps the z axis pointing up (with `up = :y` or `:x`
the components are rolled so that axis is vertical, like matplotlib's
`vertical_axis`). matplotlib's default
view `elev = 30, azim = -60` puts the camera on the +x, -y, +z side. At
`(90, -90)` you look straight down with +x to the right and +y up; at `(0, 0)`
you look along -x with +y to the right and +z up. Near-vertical views
(`|elev| ≥ 89.9`) use the horizontal up vector `∓(cosd(azim), sind(azim), 0)`,
which gives exactly that top view. `fig` is a `Plot` or `SyncPlot` with a 3-D
scene, or a `SubplotFigure`. Every 3-D constructor and mutator also accepts
`view = (elev, azim)`.

Without `view!` a perspective scene keeps plotly's default direction (eye
along (1, 1, 1)) at the automatic distance described under `distance`.

# Keywords

- `elev::Real = 30`: elevation above the horizontal plane, in degrees.
- `azim::Real = -60`: azimuth from the +x axis towards +y, in degrees.
- `distance = :auto`: `:auto` puts the camera as close as it can be while
  all eight corners of the scene box, seen in perspective from this
  direction, stay inside the scene's viewport (`layout.width`/`height`, else
  700×500 px, `layout.margin` and the cell domain) less a border of three
  font sizes (`layout.font.size` or the largest scene axis font, else 12 px)
  on each side for the tick labels and axis titles. For the "auto" and
  "data" aspect modes the data proportions are then pinned with
  `aspectmode = "manual"` so the framing stays right. The 3-D constructors
  and mutators, `scene!` and `annotate!` recompute an automatic distance
  (with `zoom = 1`) and such pinned proportions (other than a cube) when they
  change the scene. A positive number is the distance in plotly's normalised
  scene units and is kept.
- `up = :z`: the vertical axis, `:x`, `:y` or `:z` (matplotlib
  `vertical_axis`).
- `projection = nothing`: "perspective" or "orthographic"; `nothing` keeps the
  scene's projection.
- `zoom::Real = 1`: positive; divides the distance of a perspective view. An
  orthographic image does not depend on the distance, so there `zoom` scales
  the scene box (the aspect ratios) instead.
- `row::Integer`, `col::Integer` (`SubplotFigure` only; default: the active
  cell): the scene to point. Only that scene's camera changes.

Unknown keywords throw an `ArgumentError`.

In a scene smaller than the plot area (a subplot cell), axes whose ticks are
automatic get `nticks` from their length on screen (about one tick per 40 px,
2 to 9), because plotly.js counts ticks from the size of the whole figure and
would crowd a small scene with overlapping labels. `view!`, the 3-D
constructors and mutators, `scene!` and `annotate!` update these counts; a
count set with `scene!(; nticks)`, tick values or a tick step is kept.

# Returns

`fig` (`sf` for a `SubplotFigure`).

# Examples

```julia
using PlotlySupply
fig = plot_surface(rand(10, 20))
view!(fig; elev = 20, azim = 30)
view!(fig; elev = 90, azim = -90, projection = "orthographic")   # top view, +y up

sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene")])
plot_surface!(sf, rand(5, 5); row = 1, col = 1)
plot_surface!(sf, rand(5, 5); row = 1, col = 2)
view!(sf; row = 1, col = 2, elev = 10, azim = 0, zoom = 1.2)
```
"""
function view!(
	fig;
	elev = 30,
	azim = -60,
	distance = :auto,
	up = :z,
	projection = nothing,
	zoom = 1,
	row = nothing,
	col = nothing,
	kwargs...,
)
	who = "view!"
	_s3_reject_kwargs(who, kwargs)
	params = _s3_view_params(who; elev, azim, distance, up, projection, zoom)
	target = _s3_scene_target(fig, who; row, col)
	state = _s3_scene_state(fig, target)
	_s3_apply_view!(fig, target, params)
	_s3_finish_ticks!(fig, target, state)
	_refresh!(fig)
	return fig
end

function view!(sf::SubplotFigure; row = nothing, col = nothing, kwargs...)
	impl = staged -> begin
		view!(_S3SubplotCell(staged); row = row, col = col, kwargs...)
		return staged
	end
	return _transactional_subplot_mutation!(impl, sf, ())
end

# A staged SubplotFigure seen through the untyped `view!`/`scene!`/`annotate!`
# bodies: the layout is the staged plot's and `_cell_target` resolves cells.
struct _S3SubplotCell
	sf::SubplotFigure
end

_plot_obj(cell::_S3SubplotCell) = _cmn_plot(cell.sf)
_cmn_plot(cell::_S3SubplotCell) = _cmn_plot(cell.sf)
_cell_target(cell::_S3SubplotCell; kwargs...) = _cell_target(cell.sf; kwargs...)
_refresh!(cell::_S3SubplotCell) = _refresh!(getfield(cell.sf, :fig))

#endregion

#region scene!

function _s3_ticks(ticks, labels, who::AbstractString, letter::Char)
	ticks === nothing && labels === nothing && return nothing
	ticks === nothing && throw(ArgumentError(
		"$(who): `$(letter)ticklabels` need `$(letter)ticks` of the same length.",
	))
	values = _checked_real_vector(ticks, who, "$(letter)ticks")
	fields = Dict{Symbol, Any}(:tickmode => "array", :tickvals => values)
	if labels !== nothing
		(labels isa AbstractVector || labels isa Tuple) || throw(ArgumentError(
			"$(who): `$(letter)ticklabels` must be a vector of strings; got $(typeof(labels)).",
		))
		length(labels) == length(values) || throw(ArgumentError(
			"$(who): $(length(labels)) `$(letter)ticklabels` for $(length(values)) `$(letter)ticks`.",
		))
		fields[:ticktext] = String[
			label isa AbstractString ? _label3d(label) : throw(ArgumentError(
				"$(who): `$(letter)ticklabels` entries must be strings; got $(repr(label)).",
			)) for label in labels
		]
	end
	return fields
end

function _s3_aspectratio(ratio, who::AbstractString)
	ratio === nothing && return nothing
	values = if ratio isa NamedTuple
		Set(keys(ratio)) == Set((:x, :y, :z)) || throw(ArgumentError(
			"$(who): `aspectratio` as a NamedTuple needs exactly the fields x, y, z; got $(keys(ratio)).",
		))
		(ratio.x, ratio.y, ratio.z)
	elseif (ratio isa Tuple || ratio isa AbstractVector) && length(ratio) == 3
		Tuple(ratio)
	else
		throw(ArgumentError(
			"$(who): `aspectratio` must be (x, y, z) or (x = …, y = …, z = …); got $(repr(ratio)).",
		))
	end
	a = map(((v, n),) -> _s3_positive(v, who, "aspectratio.$(n)"), zip(values, ("x", "y", "z")))
	return attr(x = a[1], y = a[2], z = a[3])
end

@doc raw"""
	scene!(fig; kwargs...) -> fig

Style one 3-D scene: its aspect ratio (matplotlib `set_box_aspect`), axes,
grid, panes and ticks (`set_axis_off`, `set_xticks`, …). Only the target scene
changes, and keywords left at their defaults leave it as it is. `fig` is a
`Plot` or `SyncPlot` with a 3-D scene, or a `SubplotFigure`.

# Keywords

- `aspectratio = nothing`: `(x, y, z)` or `(x = …, y = …, z = …)`, positive;
  sets `aspectmode = "manual"`.
- `aspectmode = nothing`: "auto", "cube", "data" or "manual". plotly.js
  ignores explicit axis ranges in "auto" and "data", so with a range they are
  written as `aspectmode = "manual"` with the proportions of the axis spans
  (equal units for "data"), as in the 3-D constructors; a camera at
  [`view!`](@ref)'s automatic distance is re-framed for the changed scene.
- `nticks::Integer = 0`: about how many ticks each axis gets (0: automatic).
- `showbackground::Union{Nothing, Bool} = nothing`: show or hide the axis
  panes.
- `backgroundcolor = ""`: colour of the panes; it also turns them on unless
  `showbackground = false`.
- `showgrid::Union{Nothing, Bool} = nothing`: show or hide the grid lines.
- `showticklabels::Union{Nothing, Bool} = nothing`: show or hide the tick
  labels.
- `showaxis::Union{Nothing, Bool} = nothing`: show or hide the axes.
- `xlabel::AbstractString = ""`, `ylabel::AbstractString = ""`,
  `zlabel::AbstractString = ""`: axis titles. Scene axis titles and tick
  labels are drawn by WebGL, which cannot typeset TeX: `$…$` is converted to
  Unicode and `<b>`/`<i>`/`<sub>`/`<sup>` (`$x_1$` gives x with a subscript
  1, `$\mathbf{b}$` a bold b, `$\lambda^2$` λ with a superscript 2); an
  unsupported macro is shown as written and warns once.
- `xrange = [0, 0]`, `yrange = [0, 0]`, `zrange = [0, 0]`: axis ranges
  `[lo, hi]` in data units, also on a logarithmic axis (`[0, 0]`: unchanged).
- `xticks = nothing`, `yticks = nothing`, `zticks = nothing`: tick positions
  (data values).
- `xticklabels = nothing`, `yticklabels = nothing`, `zticklabels = nothing`:
  labels for those ticks (strings, one per tick; TeX is converted as for the
  titles).
- `row::Integer`, `col::Integer` (`SubplotFigure` only; default: the active
  cell): the scene to style.

Unknown keywords throw an `ArgumentError`.

# Returns

`fig` (`sf` for a `SubplotFigure`).

# Examples

```julia
using PlotlySupply
fig = plot_surface(rand(20, 10))
scene!(fig; aspectratio = (2, 1, 0.5), showbackground = false,
       xticks = [0, 10, 19], xticklabels = ["\$0\$", "\$\\pi\$", "\$2\\pi\$"],
       zlabel = "\$\\lambda^2\$")
```
"""
function scene!(
	fig;
	aspectratio = nothing,
	aspectmode = nothing,
	nticks::Integer = 0,
	showbackground::Union{Nothing, Bool} = nothing,
	backgroundcolor = "",
	showgrid::Union{Nothing, Bool} = nothing,
	showticklabels::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xticks = nothing,
	yticks = nothing,
	zticks = nothing,
	xticklabels = nothing,
	yticklabels = nothing,
	zticklabels = nothing,
	row = nothing,
	col = nothing,
	kwargs...,
)
	who = "scene!"
	_s3_reject_kwargs(who, kwargs)
	target = _s3_scene_target(fig, who; row, col)
	key = target.scenekey
	layout = _cmn_layout(fig)
	ratio = _s3_aspectratio(aspectratio, who)
	mode = _s3_aspectmode(aspectmode, who)
	if ratio !== nothing
		(mode === nothing || mode == "manual") || throw(ArgumentError(
			"$(who): `aspectratio` needs aspectmode \"manual\"; got aspectmode = $(repr(mode)).",
		))
		mode = "manual"
	end
	nticks >= 0 || throw(ArgumentError("$(who): `nticks` must be >= 0 (0 = automatic); got $(nticks)."))
	background = _s3_color(backgroundcolor, who, "backgroundcolor")
	axes = (
		(:xaxis, 'x', xlabel, xrange, xticks, xticklabels),
		(:yaxis, 'y', ylabel, yrange, yticks, yticklabels),
		(:zaxis, 'z', zlabel, zrange, zticks, zticklabels),
	)
	scene = Dict{Symbol, Any}()
	mode === nothing || (scene[:aspectmode] = mode)
	ratio === nothing || (scene[:aspectratio] = ratio)
	for (axis, letter, label, range, ticks, ticklabels) in axes
		fields = Dict{Symbol, Any}()
		isempty(label) || (fields[:title] = attr(text = _label3d(label)))
		stored = _s3_stored_range(layout, key, axis, _s3_range(range, who, "$(letter)range"), who, "$(letter)range")
		stored === nothing || (fields[:range] = stored)
		tick_fields = _s3_ticks(ticks, ticklabels, who, letter)
		tick_fields === nothing || merge!(fields, tick_fields)
		nticks > 0 && (fields[:nticks] = Int(nticks))
		showgrid === nothing || (fields[:showgrid] = showgrid)
		showticklabels === nothing || (fields[:showticklabels] = showticklabels)
		showaxis === nothing || (fields[:visible] = showaxis)
		if isempty(background)
			showbackground === nothing || (fields[:showbackground] = showbackground)
		else
			fields[:backgroundcolor] = background
			fields[:showbackground] = showbackground === nothing ? true : showbackground
		end
		isempty(fields) || (scene[axis] = attr(; fields...))
	end
	state = _s3_scene_state(fig, target)
	# An aspect set now replaces what was pinned automatically; a tick count
	# given now is the user's.
	(mode === nothing) || (state = _S3SceneState(false, state.auto_camera, state.auto_ticks))
	nticks > 0 && (state = _S3SceneState(state.pinned, state.auto_camera, (false, false, false)))
	isempty(scene) || _merge_scene_layout_attr!(layout, key, attr(; scene...))
	_s3_finish_scene!(fig, target, state)
	_s3_finish_ticks!(fig, target, state)
	_refresh!(fig)
	return fig
end

function scene!(sf::SubplotFigure; row = nothing, col = nothing, kwargs...)
	impl = staged -> begin
		scene!(_S3SubplotCell(staged); row = row, col = col, kwargs...)
		return staged
	end
	return _transactional_subplot_mutation!(impl, sf, ())
end

#endregion

#region 3-D annotate!

const _S3_ANNOTATION_XANCHORS = ("auto", "left", "center", "right")
const _S3_ANNOTATION_YANCHORS = ("auto", "top", "middle", "bottom")
# Scene-annotation attributes passed through unchanged (plotly.js
# `layout.scene.annotations[*]`); everything else is rejected.
const _S3_ANNOTATION_PASSTHROUGH = (
	:align, :arrowcolor, :arrowhead, :arrowside, :arrowsize, :arrowwidth, :ax, :ay,
	:bgcolor, :bordercolor, :borderpad, :borderwidth, :captureevents, :height,
	:hovertext, :opacity, :standoff, :startarrowhead, :startarrowsize,
	:startstandoff, :textangle, :valign, :visible, :width, :xshift, :yshift,
)

@doc raw"""
	annotate!(fig, x::Real, y::Real, z::Real, text::AbstractString; kwargs...) -> fig

Label the point `(x, y, z)` of a 3-D scene with `text`. The coordinates are
data values, also on logarithmic scene axes. The label is a scene annotation:
it stays attached to the point while the scene rotates, and TeX in `$…$` is
typeset by MathJax (unlike the WebGL-drawn axis titles). Annotating the same
point with the same text again replaces that label instead of adding a copy.
`fig` is a `Plot` or `SyncPlot` with a 3-D scene, or a `SubplotFigure`.

# Keywords

- `row::Integer`, `col::Integer` (`SubplotFigure` only; default: the active
  cell): the scene to annotate.
- `fontsize::Real = 0`: font size in px (0: the figure's).
- `color = ""`: text colour.
- `xanchor = "center"`: "auto", "left", "center" or "right".
- `yanchor = "middle"`: "auto", "top", "middle" or "bottom".
- `showarrow::Bool = false`: draw an arrow from the label to the point (the
  label is then offset by `ax`, `ay` px).
- Other plotly scene-annotation attributes are passed through: `align`,
  `arrowcolor`, `arrowhead`, `arrowside`, `arrowsize`, `arrowwidth`, `ax`,
  `ay`, `bgcolor`, `bordercolor`, `borderpad`, `borderwidth`,
  `captureevents`, `height`, `hovertext`, `opacity`, `standoff`,
  `startarrowhead`, `startarrowsize`, `startstandoff`, `textangle`, `valign`,
  `visible`, `width`, `xshift`, `yshift`. Any other keyword throws an
  `ArgumentError`.

# Returns

`fig` (`sf` for a `SubplotFigure`).

# Examples

```julia
using PlotlySupply
fig = plot_scatter3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0]; mode = "markers")
annotate!(fig, 1.0, 1.0, 1.0, "\$\\mathbf{p}_1\$"; fontsize = 16, color = "red")
annotate!(fig, 0.0, 0.0, 0.0, "origin"; showarrow = true, ax = 30, ay = -30)
```
"""
function annotate!(
	fig,
	x::Real,
	y::Real,
	z::Real,
	text::AbstractString;
	row = nothing,
	col = nothing,
	fontsize::Real = 0,
	color = "",
	xanchor = "center",
	yanchor = "middle",
	showarrow::Bool = false,
	kwargs...,
)
	who = "annotate!"
	target = _s3_scene_target(fig, who; row, col)
	point = (
		_s3_finite_real(x, who, "x"),
		_s3_finite_real(y, who, "y"),
		_s3_finite_real(z, who, "z"),
	)
	_require_size_option(fontsize, who, "fontsize")
	text_color = _s3_color(color, who, "color")
	layout = _cmn_layout(fig)
	# plotly.js places scene annotations in axis range units, which are log10
	# exponents on a logarithmic axis; the point is given in data units.
	position = ntuple(3) do d
		axis = (:xaxis, :yaxis, :zaxis)[d]
		_s3_scene_axis_type(layout, target.scenekey, axis) == "log" || return point[d]
		point[d] > 0 || throw(ArgumentError(
			"$(who): `$("xyz"[d])` = $(point[d]) must be positive on the logarithmic scene $(axis).",
		))
		return log10(point[d])
	end
	entry = Dict{Symbol, Any}(
		:x => position[1],
		:y => position[2],
		:z => position[3],
		:text => _label(String(text)),
		:showarrow => showarrow,
		:xanchor => _s3_choice(xanchor, _S3_ANNOTATION_XANCHORS, who, "xanchor"),
		:yanchor => _s3_choice(yanchor, _S3_ANNOTATION_YANCHORS, who, "yanchor"),
		:name => "annotate3d:($(point[1]),$(point[2]),$(point[3])):$(text)",
	)
	font = Dict{Symbol, Any}()
	fontsize > 0 && (font[:size] = fontsize)
	isempty(text_color) || (font[:color] = text_color)
	isempty(font) || (entry[:font] = attr(; font...))
	for (key, value) in kwargs
		key in _S3_ANNOTATION_PASSTHROUGH || throw(ArgumentError(
			"$(who): unsupported keyword `$(key)` for a 3-D annotation; accepted: " *
			join(_S3_ANNOTATION_PASSTHROUGH, ", ") * ".",
		))
		entry[key] = value
	end
	scene = get(layout.fields, target.scenekey, nothing)
	existing = _cmn_mapping_get(scene, :annotations)
	(existing === nothing || existing isa AbstractVector) || throw(ArgumentError(
		"$(who): $(target.scenekey).annotations must be a vector; got $(typeof(existing)).",
	))
	kept = Any[]
	if existing !== nothing
		for item in existing
			_cmn_mapping_get(item, :name) == entry[:name] && continue
			push!(kept, item)
		end
	end
	push!(kept, attr(; entry...))
	# Scene annotations count in plotly's scene extent (camera framing).
	state = _s3_scene_state(fig, target)
	_merge_scene_layout_attr!(layout, target.scenekey, attr(annotations = kept))
	_s3_finish_scene!(fig, target, state)
	_s3_finish_ticks!(fig, target, state)
	_refresh!(fig)
	return fig
end

function annotate!(
	sf::SubplotFigure,
	x::Real,
	y::Real,
	z::Real,
	text::AbstractString;
	row = nothing,
	col = nothing,
	kwargs...,
)
	impl = staged -> begin
		annotate!(_S3SubplotCell(staged), x, y, z, text; row = row, col = col, kwargs...)
		return staged
	end
	return _transactional_subplot_mutation!(impl, sf, ())
end

#endregion

#region Constructor / mutator plumbing

function _s3_write_coloraxis!(fig, spec::_S3ColorSpec)
	spec.axis === nothing && return nothing
	key = Symbol(spec.axis)
	if isempty(spec.axis_fields)
		# A trace may reference a colour axis that has no settings yet; give it
		# an empty entry so the reference is never dangling.
		haskey(_cmn_layout(fig).fields, key) ||
			relayout!(_cmn_relayout_target(fig); (key => attr(),)...)
	else
		_cmn_merge_layout_key!(fig, key, spec.axis_fields; nested = (:colorbar,))
	end
	return nothing
end

# Draw the math colorbar titles of the traces `first_index:end` and of the
# colour axes of `specs` as annotations (X1). Run after the options, because
# the annotation offsets depend on the font size. Inside the SubplotFigure
# delegate `_colorbar_math_titles!` does nothing: the delegate converts the
# titles once the bars are placed in the cell. A colour axis given a new
# plain title loses the annotation an earlier math title left.
function _s3_colorbar_titles!(fig, first_index::Int, specs)
	ids = String[]
	for spec in specs
		(spec.axis === nothing || spec.axis in ids) && continue
		push!(ids, spec.axis)
		title = _cmn_mapping_get(get(spec.axis_fields, :colorbar, nothing), :title)
		title === nothing && continue
		_cbar_is_math(_cmn_mapping_get(title, :text)) ||
			_cbar_remove_title_annotation!(_plot_obj(fig), spec.axis)
	end
	_colorbar_math_titles!(fig, first_index:length(_plot_data(fig)); coloraxes = ids)
	return nothing
end

# Style defaults (X10) for the line traces a scatter3d, wireframe or
# segments3d call adds: `explicit` names the keywords that are never filled
# from the active `PlotStyle` (see `_apply_style_trace_defaults!`), and
# `fallback_width` is written where neither the caller nor the style set a
# line width.
struct _S3StyleRequest
	explicit::Tuple{Vararg{Symbol}}
	fallback_width::Union{Nothing, Float64}
end

# scatter3d takes every style default; `mode` counts as set when given.
_s3_scatter3d_style(mode) = _S3StyleRequest(mode === nothing ? () : (:mode,), nothing)

# Wireframes and segments are line collections (matplotlib styles them with
# `lines.linewidth` only, not with the property cycle): only the style's line
# width applies, else 1 px as in 1.x; an explicit `linewidth` (0 = plotly's
# default) is kept.
_s3_collection_style(linewidth) = _S3StyleRequest(
	linewidth === nothing ? (:dash, :marker_size, :marker_symbol, :mode) :
		(:linewidth, :dash, :marker_size, :marker_symbol, :mode),
	linewidth === nothing ? 1.0 : nothing,
)

function _s3_apply_style!(fig, first_index::Int, request::_S3StyleRequest)
	data = _plot_data(fig)
	indices = first_index:length(data)
	_apply_style_trace_defaults!(fig, indices; explicit = request.explicit)
	request.fallback_width === nothing && return nothing
	for index in indices
		fields = data[index].fields
		line = _symbol_dict(get(fields, :line, nothing))
		_style_value_unset(get(line, :width, nothing)) || continue
		line[:width] = request.fallback_width
		fields[:line] = attr(; line...)
	end
	return nothing
end

function _s3_construct(
	traces::Vector{GenericTrace},
	specs,
	opts::_S3Options,
	who::AbstractString,
	show::Bool;
	style::Union{Nothing, _S3StyleRequest} = nothing,
)
	fig = Plot(traces, _s3_constructor_layout())
	foreach(spec -> _s3_write_coloraxis!(fig, spec), specs)
	style === nothing || _s3_apply_style!(fig, 1, style)
	_s3_apply_options!(fig, opts, who; constructor = true, state = _S3_NEW_SCENE)
	_s3_colorbar_titles!(fig, 1, specs)
	return _s3_show(fig, show, opts)
end

function _s3_append!(
	fig,
	traces::Vector{GenericTrace},
	specs,
	opts::_S3Options,
	who::AbstractString;
	style::Union{Nothing, _S3StyleRequest} = nothing,
)
	state = _s3_mutator_state(fig, who)
	first_index = length(_plot_data(fig)) + 1
	append!(_plot_data(fig), traces)
	foreach(spec -> _s3_write_coloraxis!(fig, spec), specs)
	style === nothing || _s3_apply_style!(fig, first_index, style)
	_s3_apply_options!(fig, opts, who; constructor = false, state)
	_s3_colorbar_titles!(fig, first_index, specs)
	_refresh!(fig)
	return nothing
end

# Index (1-based) the next trace appended to `fig` will have; 1 for a new figure.
_s3_next_index(fig) = fig === nothing ? 1 : length(_plot_data(fig)) + 1

# Flatten an N-d data array to the 1-D list plotly expects (a no-copy reshape
# for arrays and views); vectors are returned unchanged.
_s3_flat(values::AbstractVector) = values
_s3_flat(values::AbstractArray) = vec(values)

function _s3_array(values, who::AbstractString, name::AbstractString)
	values isa AbstractArray || throw(ArgumentError(
		"$(who): `$(name)` must be an array of numbers; got $(typeof(values)).",
	))
	_s3_check_numeric_array(values, who, name)
	return values
end

# A uniform colour given as a String/Symbol ("" = unset) or, for keywords
# that historically took per-series vectors, the first entry of a vector.
function _s3_uniform_color(color, who::AbstractString, name::AbstractString = "color")
	if color isa AbstractVector
		isempty(color) && return ""
		color = first(color)
	end
	return _s3_color(color, who, name)
end

_s3_two_stop(color::AbstractString) = Vector{Any}[Any[0, color], Any[1, color]]

#endregion

#region Surface

function _s3_surface_grid(X, Y, Z, who::AbstractString)
	_s3_array(Z, who, "Z")
	ndims(Z) == 2 || throw(ArgumentError(
		"$(who): `Z` must be a matrix; got a $(ndims(Z))-dimensional array.",
	))
	m, n = size(Z)
	for (name, grid, count, what) in (("X", X, m, "rows"), ("Y", Y, n, "columns"))
		_s3_array(grid, who, name)
		if ndims(grid) == 1
			length(grid) == count || throw(ArgumentError(
				"$(who): `$(name)` has $(length(grid)) values but `Z` has $(count) $(what) " *
				"(Z[i, j] is drawn at (X[i], Y[j])).",
			))
		elseif ndims(grid) == 2
			size(grid) == size(Z) || throw(ArgumentError(
				"$(who): `$(name)` is $(join(size(grid), "×")) but `Z` is $(m)×$(n); a " *
				"coordinate matrix must match `Z`.",
			))
		else
			throw(ArgumentError(
				"$(who): `$(name)` must be a vector or a matrix; got a $(ndims(grid))-dimensional array.",
			))
		end
	end
	return _s3_plottable(X), _s3_plottable(Y), _s3_plottable(Z)
end

# Grid-line positions of one surface axis for `edges=true`: plotly draws
# surface contour lines at `start:size:end`, so the grid must be rectilinear
# and uniformly spaced along that axis.
function _s3_edge_levels(grid, along::Int, count::Int, who::AbstractString, name::AbstractString)
	values = if ndims(grid) == 1
		grid
	else
		for j in axes(grid, 3 - along), i in axes(grid, along)
			reference = along == 1 ? grid[i, firstindex(grid, 2)] : grid[firstindex(grid, 1), i]
			value = along == 1 ? grid[i, j] : grid[j, i]
			value == reference || throw(ArgumentError(
				"$(who): `edges=true` needs a rectilinear grid (`$(name)` constant along " *
				"each grid line); draw curvilinear grid lines with `plot_wireframe!`.",
			))
		end
		along == 1 ? view(grid, :, firstindex(grid, 2)) : view(grid, firstindex(grid, 1), :)
	end
	count >= 2 || throw(ArgumentError("$(who): `edges=true` needs at least 2 grid lines along `$(name)`."))
	first_value = Float64(first(values))
	step = (Float64(last(values)) - first_value) / (count - 1)
	(isfinite(step) && step != 0) || throw(ArgumentError(
		"$(who): `edges=true` needs finite, distinct `$(name)` grid values.",
	))
	for (k, value) in enumerate(values)
		# 1e-6 of a step: exact grids built from ranges pass, measured or
		# perturbed grids (which plotly cannot reproduce) are rejected.
		abs(Float64(value) - (first_value + (k - 1) * step)) <= 1e-6 * abs(step) || throw(ArgumentError(
			"$(who): `edges=true` needs uniformly spaced `$(name)` grid values; draw " *
			"non-uniform grid lines with `plot_wireframe!`.",
		))
	end
	lo = min(first_value, Float64(last(values)))
	hi = max(first_value, Float64(last(values)))
	# The end is nudged by 1e-3 step so rounding cannot drop the last line.
	return (lo, hi + 1e-3 * abs(step), abs(step))
end

function _s3_surface_trace(
	fig,
	X,
	Y,
	Z;
	surfacecolor,
	color,
	opacity,
	lighting,
	edges::Bool,
	edgecolor,
	edgewidth,
	colorscale,
	crange,
	cmid,
	colornorm,
	levels,
	showscale,
	colorbar_title,
	colorbar_title_side,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	shared_coloraxis::Bool,
	who::AbstractString,
)
	x, y, z = _s3_surface_grid(X, Y, Z, who)
	# `color` is either a colour (uniform surface) or, as in 1.x, a colour
	# array (alias of `surfacecolor`).
	uniform = ""
	if color isa AbstractArray && !(color isa AbstractVector{<:AbstractString})
		if !isempty(color)
			(surfacecolor === nothing || isempty(surfacecolor)) || throw(ArgumentError(
				"$(who): pass the colour array as `surfacecolor` or `color`, not both.",
			))
			surfacecolor = color
		end
	else
		uniform = _s3_uniform_color(color, who)
	end
	(surfacecolor !== nothing && isempty(surfacecolor)) && (surfacecolor = nothing)
	if surfacecolor !== nothing
		_s3_array(surfacecolor, who, "surfacecolor")
		size(surfacecolor) == size(Z) || throw(ArgumentError(
			"$(who): `surfacecolor` is $(join(size(surfacecolor), "×")) but `Z` is $(join(size(Z), "×")).",
		))
		surfacecolor = _s3_plottable(surfacecolor)
	end
	alpha = _s3_unit_interval(opacity, who, "opacity")
	light, _ = _s3_lighting(lighting, who; surface = true)
	if shared_coloraxis && coloraxis !== nothing && _normalize_coloraxis(coloraxis, who) != "coloraxis"
		throw(ArgumentError(
			"$(who): `shared_coloraxis=true` uses \"coloraxis\"; it conflicts with coloraxis = $(repr(coloraxis)).",
		))
	end
	axis = shared_coloraxis ? "coloraxis" : coloraxis
	fields = Dict{Symbol, Any}(:x => x, :y => y, :z => z)
	spec = _S3ColorSpec()
	if !isempty(uniform)
		surfacecolor === nothing || throw(ArgumentError(
			"$(who): a uniform `color` cannot be combined with `surfacecolor`.",
		))
		_s3_colormap_requested(; colorscale, crange, cmid, colornorm, levels, colorbar_title,
			colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis = axis, who) && throw(ArgumentError(
			"$(who): a uniform `color` cannot be combined with colour-scale keywords " *
			"(colorscale, crange, cmid, colornorm, levels, colorbar_*, coloraxis, shared_coloraxis).",
		))
		fields[:colorscale] = _s3_two_stop(uniform)
		fields[:showscale] = false
	else
		norm = _normalize_colornorm(colornorm, who)
		values = surfacecolor !== nothing ? surfacecolor : (norm === :log ? z : nothing)
		spec = _s3_color_spec(
			values,
			who;
			values_key = :surfacecolor,
			colorscale,
			crange,
			cmid,
			colornorm = norm,
			levels,
			showscale,
			colorbar_title,
			colorbar_title_side,
			colorbar_ticks,
			colorbar_ticklabels,
			coloraxis = axis,
		)
		merge!(fields, spec.trace)
	end
	alpha < 1 && (fields[:opacity] = alpha)
	light === nothing || (fields[:lighting] = light)
	if edges
		line_color = _s3_color(edgecolor, who, "edgecolor")
		isempty(line_color) && (line_color = "black")
		width = _s3_finite_real(edgewidth, who, "edgewidth")
		# plotly.js limits surface contour widths to 1–16 px.
		1 <= width <= 16 || throw(ArgumentError(
			"$(who): `edgewidth` must lie in [1, 16] px for surface edges; got $(repr(edgewidth)).",
		))
		m, n = size(Z)
		contours = Dict{Symbol, Any}()
		for (key, grid, along, count, name) in ((:x, X, 1, m, "X"), (:y, Y, 2, n, "Y"))
			lo, hi, step = _s3_edge_levels(grid, along, count, who, name)
			contours[key] = attr(
				show = true,
				start = lo,
				var"end" = hi,
				size = step,
				color = line_color,
				width = width,
				highlight = false,
			)
		end
		fields[:contours] = attr(; contours...)
	end
	return GenericTrace("surface"; fields...), spec
end

# `shared_coloraxis=true` on a mutator: every surface of the figure that has
# no colour axis of its own (and is not uniformly coloured) joins "coloraxis".
# Without an explicit colorscale the shared axis keeps the colorscale the
# first linked surface already had, instead of falling back to the template.
function _s3_link_shared_surfaces!(p::Plot, colorscale_given::Bool)
	layout = p.layout
	shared = get(layout.fields, :coloraxis, nothing)
	inherit = !colorscale_given && _cmn_mapping_get(shared, :colorscale) === nothing
	inherited = nothing
	for trace in p.data
		(trace isa GenericTrace && get(trace.fields, :type, "") == "surface") || continue
		current = get(trace.fields, :coloraxis, nothing)
		(current === nothing || current == "coloraxis") || continue
		scale = get(trace.fields, :colorscale, nothing)
		if scale isa AbstractVector && length(scale) >= 2 && get(trace.fields, :showscale, true) === false
			colours = Set(stop[2] for stop in scale if stop isa AbstractVector && length(stop) == 2)
			length(colours) == 1 && continue  # uniform `color` surface
		end
		if inherit && inherited === nothing && scale !== nothing && !(scale isa AbstractString && isempty(scale))
			inherited = scale
		end
		trace.fields[:coloraxis] = "coloraxis"
	end
	if inherited !== nothing
		fields = Dict{Symbol, Any}(:colorscale => inherited)
		_cmn_merge_layout_key!(p, :coloraxis, fields)
	end
	return nothing
end

function plot_surface(
	X::AbstractArray,
	Y::AbstractArray,
	Z::AbstractArray;
	surfacecolor = nothing,
	color = "",
	opacity::Real = 1,
	lighting = :default,
	edges::Bool = false,
	edgecolor = "black",
	edgewidth::Real = 1,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	shared_coloraxis::Bool = false,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = "auto",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_surface"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	trace, spec = _s3_surface_trace(nothing, X, Y, Z; surfacecolor, color, opacity, lighting, edges,
		edgecolor, edgewidth, colorscale, crange, cmid, colornorm, levels, showscale, colorbar_title,
		colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, shared_coloraxis, who)
	return _s3_construct(GenericTrace[trace], (spec,), opts, who, show)
end

function plot_surface(Z::AbstractArray; kwargs...)
	ndims(Z) == 2 || throw(ArgumentError(
		"plot_surface: `Z` must be a matrix; got a $(ndims(Z))-dimensional array.",
	))
	return plot_surface(0:(size(Z, 1) - 1), 0:(size(Z, 2) - 1), Z; kwargs...)
end

function plot_surface!(
	fig,
	X::AbstractArray,
	Y::AbstractArray,
	Z::AbstractArray;
	surfacecolor = nothing,
	color = "",
	opacity::Real = 1,
	lighting = :default,
	edges::Bool = false,
	edgecolor = "black",
	edgewidth::Real = 1,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	shared_coloraxis::Bool = false,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = nothing,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	kwargs...,
)
	who = "plot_surface!"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	trace, spec = _s3_surface_trace(fig, X, Y, Z; surfacecolor, color, opacity, lighting, edges,
		edgecolor, edgewidth, colorscale, crange, cmid, colornorm, levels, showscale, colorbar_title,
		colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, shared_coloraxis, who)
	state = _s3_mutator_state(fig, who)
	first_index = length(_plot_data(fig)) + 1
	append!(_plot_data(fig), GenericTrace[trace])
	_s3_write_coloraxis!(fig, spec)
	shared_coloraxis && _s3_link_shared_surfaces!(_plot_obj(fig), !_is_unset_colorscale(colorscale))
	_s3_apply_options!(fig, opts, who; constructor = false, state)
	_s3_colorbar_titles!(fig, first_index, (spec,))
	_refresh!(fig)
	return nothing
end

function plot_surface!(fig, Z::AbstractArray; kwargs...)
	ndims(Z) == 2 || throw(ArgumentError(
		"plot_surface!: `Z` must be a matrix; got a $(ndims(Z))-dimensional array.",
	))
	return plot_surface!(fig, 0:(size(Z, 1) - 1), 0:(size(Z, 2) - 1), Z; kwargs...)
end

const _S3_SURFACE_KEYWORDS_DOC = raw"""
- `surfacecolor = nothing`: array of the size of `Z` with the values that
  colour the surface (default: the heights `Z`).
- `color = ""`: one colour (String or Symbol) for the whole surface, drawn
  without a colorbar; it cannot be combined with `surfacecolor` or the colour
  keywords. A numeric array is accepted as an alias of `surfacecolor`.
- `opacity::Real = 1`: surface opacity in [0, 1].
- `lighting = :default`: `:default` (plotly's shading), `:flat` (unshaded,
  like matplotlib) or a NamedTuple of plotly lighting fields (`ambient`,
  `diffuse`, `specular`, `roughness`, `fresnel`; each ≥ 0).
- `edges::Bool = false`: draw the grid lines on the surface. They are plotly
  surface contours, so the grid must be rectilinear and uniformly spaced; use
  [`plot_wireframe!`](@ref) for other grids.
- `edgecolor = "black"`: colour of the edges.
- `edgewidth::Real = 1`: width of the edges in px, 1–16.
- `shared_coloraxis::Bool = false`: put the surface on the shared colour axis
  "coloraxis" (it cannot be combined with another `coloraxis`), so several
  surfaces share one colour range and colorbar. [`plot_surface!`](@ref) also
  moves the figure's other surfaces onto that axis; without a `colorscale`
  the axis keeps the colormap the first of them had.
"""

@doc _s3_doc(
	raw"""
		plot_surface(X, Y, Z; kwargs...) -> Plot
		plot_surface(Z; kwargs...) -> Plot

	Surface of the matrix `Z`: `Z[i, j]` is the height at `(X[i], Y[j])`. `X`
	and `Y` are vectors of lengths `size(Z, 1)` and `size(Z, 2)`, or matrices of
	the size of `Z` (ndgrid layout, `X = [x for x in xs, y in ys]`, so
	curvilinear grids work); `plot_surface(Z)` uses `0:size(Z, 1)-1` and
	`0:size(Z, 2)-1`. Non-finite heights leave holes and Boolean arrays are
	drawn as 0/1. `zrange` sets the z axis; the colour limits are `crange`.
	""",
	_S3_SURFACE_KEYWORDS_DOC;
	constructor = true,
	colour = true,
	example = raw"""
	xs = range(-2, 2; length = 41)
	ys = range(-1, 1; length = 21)
	Z = [exp(-x^2 - 4y^2) for x in xs, y in ys]   # Z[i, j] at (xs[i], ys[j])
	fig = plot_surface(xs, ys, Z; colorscale = "viridis", edges = true,
	                   xlabel = "\$x_1\$", ylabel = "\$x_2\$", view = (25, -50))
	""",
) plot_surface

@doc _s3_doc(
	_s3_mutator_head(
		raw"""
			plot_surface!(fig, X, Y, Z; kwargs...)
			plot_surface!(fig, Z; kwargs...)
		""",
		"a surface",
		"plot_surface",
	),
	_S3_SURFACE_KEYWORDS_DOC;
	constructor = false,
	colour = true,
	example = raw"""
	fig = plot_surface(rand(10, 10); colorscale = "Hot")
	plot_surface!(fig, rand(10, 10) .+ 2; shared_coloraxis = true)   # one colorbar for both

	sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene")])
	plot_surface!(sf, rand(10, 10); row = 1, col = 2, view = (60, 30))
	""",
) plot_surface!

#endregion

#region scatter3d

function _s3_point_labels(text, count::Int, who::AbstractString)
	text === nothing && return nothing
	text isa AbstractString && return _label3d(text)
	text isa AbstractVector || throw(ArgumentError(
		"$(who): `text` must be a string or a vector with one label per point; got $(typeof(text)).",
	))
	length(text) == count || throw(ArgumentError(
		"$(who): `text` has $(length(text)) labels for $(count) points.",
	))
	return String[_label3d(label isa AbstractString ? label : string(label)) for label in text]
end

# Colour keywords given as Symbols (`:red`) are handled as strings.
_s3_color_text(value::Symbol) = String(value)
_s3_color_text(value::AbstractString) = value
_s3_color_text(value::AbstractVector) = String[String(c) for c in value]

function _s3_check_lengths(who::AbstractString, pairs::Pair...)
	count = length(last(first(pairs)))
	for (name, values) in pairs
		length(values) == count || throw(ArgumentError(
			"$(who): " * join(("`$(n)`" for (n, _) in pairs), ", ") * " must have the same length; " *
			"got " * join((string(length(v)) for (_, v) in pairs), ", ") * ".",
		))
	end
	return count
end

function _s3_scatter3d_trace(
	fig,
	index::Int,
	x,
	y,
	z;
	mode,
	color,
	legend,
	marker_size,
	marker_symbol,
	marker_color,
	linewidth,
	dash,
	opacity,
	text,
	textposition,
	textsize,
	showlegend,
	scenekey::Symbol,
	who::AbstractString,
)
	for (name, values) in (("x", x), ("y", y), ("z", z))
		values isa AbstractVector || throw(ArgumentError(
			"$(who): `$(name)` must be a vector (or a vector of per-series vectors); got $(typeof(values)).",
		))
		_s3_check_numeric_array(values, who, name)
	end
	count = _s3_check_lengths(who, "x" => x, "y" => y, "z" => z)
	labels = _s3_point_labels(text, count, who)
	trace_mode = _s3_mode(mode, who)
	if labels !== nothing && !occursin("text", trace_mode)
		trace_mode = trace_mode == "none" ? "text" : trace_mode * "+text"
	end
	line_color = _s3_color(color, who, "color")
	point_color = _s3_color(marker_color, who, "marker_color")
	alpha = _s3_unit_interval(opacity, who, "opacity")
	if alpha < 1
		# Translucent scatter3d lines break other 3-D traces in the scene, so
		# the colour is blended over the scene background instead (ADDENDUM B2).
		base = isempty(line_color) ? _s3_default_color(fig, index) : line_color
		line_color = _s3_line_color(base, alpha, fig, scenekey, who)
		isempty(point_color) || (point_color = _s3_line_color(point_color, alpha, fig, scenekey, who))
	end
	size_value = _s3_nonnegative(marker_size, who, "marker_size")
	width_value = _s3_nonnegative(linewidth, who, "linewidth")
	symbol = marker_symbol isa Symbol ? String(marker_symbol) : String(marker_symbol)
	isempty(symbol) || _s3_choice(symbol, _S3_MARKER_SYMBOLS, who, "marker_symbol")
	dash_value = _s3_dash(dash, who)
	position = textposition isa Symbol ? String(textposition) : String(textposition)
	isempty(position) || _s3_choice(position, _S3_TEXTPOSITIONS, who, "textposition")
	text_size = _s3_nonnegative(textsize, who, "textsize")

	line = Dict{Symbol, Any}(:color => line_color)
	width_value > 0 && (line[:width] = linewidth)
	isempty(dash_value) || (line[:dash] = dash_value)
	fields = Dict{Symbol, Any}(
		:x => _s3_plottable(x),
		:y => _s3_plottable(y),
		:z => _s3_plottable(z),
		:mode => trace_mode,
		:line => attr(; line...),
		:name => String(legend),
	)
	marker = Dict{Symbol, Any}()
	size_value > 0 && (marker[:size] = marker_size)
	isempty(symbol) || (marker[:symbol] = symbol)
	isempty(point_color) || (marker[:color] = point_color)
	isempty(marker) || (fields[:marker] = attr(; marker...))
	if labels !== nothing
		fields[:text] = labels
		isempty(position) || (fields[:textposition] = position)
		text_size > 0 && (fields[:textfont] = attr(size = textsize))
	end
	showlegend === nothing || (fields[:showlegend] = showlegend)
	return GenericTrace("scatter3d"; fields...)
end

function _s3_scatter3d_traces(
	fig,
	x,
	y,
	z;
	mode,
	color,
	legend,
	marker_size,
	marker_symbol,
	marker_color,
	linewidth,
	dash,
	opacity,
	text,
	textposition,
	textsize,
	showlegend,
	who::AbstractString,
)
	for (name, values) in (("x", x), ("y", y), ("z", z))
		eltype(values) <: Complex && _s3_check_numeric_array(values, who, name)
	end
	mode === nothing && (mode = "")
	color = _s3_color_text(color)
	marker_color = _s3_color_text(marker_color)
	z_nested, x_nested = _nested_coordinate_mode(z, x, :z, :x)
	_, y_nested = _nested_coordinate_mode(z, y, :z, :y)
	start = _s3_next_index(fig)
	if !z_nested
		single_mode = _first_or_empty(mode)
		return GenericTrace[_s3_scatter3d_trace(
			fig,
			start,
			x,
			y,
			z;
			mode = isempty(single_mode) ? "lines" : single_mode,
			color = _first_or_empty(color),
			legend = _first_or_empty(legend),
			marker_size = _scalar_or_first(marker_size, 0),
			marker_symbol = _first_or_empty(marker_symbol),
			marker_color = _first_or_empty(marker_color),
			linewidth = _scalar_or_first(linewidth, 0),
			dash = _first_or_empty(dash),
			opacity = _scalar_or_first(opacity, 1),
			text = text,
			textposition = _first_or_empty(textposition),
			textsize = _scalar_or_first(textsize, 0),
			showlegend = _scalar_or_first(showlegend, nothing),
			scenekey = :scene,
			who,
		)]
	end
	n = length(z)
	modes = _series_kwarg_vector(mode, n, "lines", String)
	colors = _series_kwarg_vector(color, n, "", String)
	legends = _series_kwarg_vector(legend, n, "", String)
	sizes = _series_kwarg_vector(marker_size, n, 0, Real)
	symbols = _series_kwarg_vector(marker_symbol, n, "", String)
	marker_colors = _series_kwarg_vector(marker_color, n, "", String)
	widths = _series_kwarg_vector(linewidth, n, 0, Real)
	dashes = _series_kwarg_vector(dash, n, "", String)
	alphas = _series_kwarg_vector(opacity, n, 1, Real)
	positions = _series_kwarg_vector(textposition, n, "", String)
	text_sizes = _series_kwarg_vector(textsize, n, 0, Real)
	visibility = _series_kwarg_vector(showlegend, n, nothing, Union{Nothing, Bool})
	texts = if text === nothing || text isa AbstractString
		fill(text, n)
	elseif _is_nested_series(text)
		Any[k <= length(text) ? text[k] : nothing for k in 1:n]
	else
		throw(ArgumentError(
			"$(who): with several series `text` must be a string or a vector of per-series label vectors.",
		))
	end
	traces = Vector{GenericTrace}(undef, n)
	for (k, series) in enumerate(eachindex(z))
		traces[k] = _s3_scatter3d_trace(
			fig,
			start + k - 1,
			x_nested ? x[series] : x,
			y_nested ? y[series] : y,
			z[series];
			mode = isempty(modes[k]) ? "lines" : modes[k],
			color = colors[k],
			legend = legends[k],
			marker_size = sizes[k],
			marker_symbol = symbols[k],
			marker_color = marker_colors[k],
			linewidth = widths[k],
			dash = dashes[k],
			opacity = alphas[k],
			text = texts[k],
			textposition = positions[k],
			textsize = text_sizes[k],
			showlegend = visibility[k],
			scenekey = :scene,
			who,
		)
	end
	return traces
end

function plot_scatter3d(
	x::AbstractVector,
	y::AbstractVector,
	z::AbstractVector;
	mode::Union{Nothing, AbstractString, AbstractVector{<:AbstractString}} = nothing,
	color::Union{AbstractString, Symbol, AbstractVector{<:Union{AbstractString, Symbol}}} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	marker_size::Union{Real, AbstractVector{<:Real}} = 0,
	marker_symbol::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	marker_color::Union{AbstractString, Symbol, AbstractVector{<:Union{AbstractString, Symbol}}} = "",
	linewidth::Union{Real, AbstractVector{<:Real}} = 0,
	dash::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	opacity::Union{Real, AbstractVector{<:Real}} = 1,
	text = nothing,
	textposition::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	textsize::Union{Real, AbstractVector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = "auto",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_scatter3d"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	traces = _s3_scatter3d_traces(nothing, x, y, z; mode, color, legend, marker_size, marker_symbol,
		marker_color, linewidth, dash, opacity, text, textposition, textsize, showlegend, who)
	return _s3_construct(traces, (), opts, who, show; style = _s3_scatter3d_style(mode))
end

function plot_scatter3d!(
	fig,
	x::AbstractVector,
	y::AbstractVector,
	z::AbstractVector;
	mode::Union{Nothing, AbstractString, AbstractVector{<:AbstractString}} = nothing,
	color::Union{AbstractString, Symbol, AbstractVector{<:Union{AbstractString, Symbol}}} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	marker_size::Union{Real, AbstractVector{<:Real}} = 0,
	marker_symbol::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	marker_color::Union{AbstractString, Symbol, AbstractVector{<:Union{AbstractString, Symbol}}} = "",
	linewidth::Union{Real, AbstractVector{<:Real}} = 0,
	dash::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	opacity::Union{Real, AbstractVector{<:Real}} = 1,
	text = nothing,
	textposition::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	textsize::Union{Real, AbstractVector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = nothing,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	kwargs...,
)
	who = "plot_scatter3d!"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	traces = _s3_scatter3d_traces(fig, x, y, z; mode, color, legend, marker_size, marker_symbol,
		marker_color, linewidth, dash, opacity, text, textposition, textsize, showlegend, who)
	return _s3_append!(fig, traces, (), opts, who; style = _s3_scatter3d_style(mode))
end

const _S3_SCATTER3D_KEYWORDS_DOC = raw"""
- `mode = nothing`: "lines", "markers", "lines+markers", "text", "none" or
  another "+"-joined combination (`nothing` and `""` mean "lines"; when
  `mode` is not given, a `PlotStyle` with a marker cycle adds markers).
- `color = ""`: line colour (String or Symbol; the markers use it too unless
  `marker_color` is set); `""` takes the next colorway colour.
- `legend = ""`: legend name.
- `showlegend = nothing`: `true`/`false` shows or hides the legend entry.
- `linewidth = 0`: line width in px (0: the active `PlotStyle`'s, else
  plotly's default).
- `dash = ""`: "solid", "dot", "dash", "longdash", "dashdot" or
  "longdashdot" (`""`: the style's dash cycle, else solid).
- `marker_size = 0`: marker size in px (0: the style's, else plotly's
  default).
- `marker_symbol = ""`: "circle", "circle-open", "cross", "diamond",
  "diamond-open", "square", "square-open" or "x" (`""`: the style's marker
  cycle, else plotly's default).
- `marker_color = ""`: marker colour (String or Symbol).
- `opacity = 1`: in [0, 1]; """ * _S3_OPACITY_LINE_DOC * raw""" Markers are blended the same way.
- `text = nothing`: point labels, one string per point or one string for all
  points; adds "text" to `mode`. They are drawn by WebGL like the axis
  titles, so TeX is converted as described below.
- `textposition = ""`: "top left", "top center", "top right", "middle left",
  "middle center", "middle right", "bottom left", "bottom center" or
  "bottom right" (`""`: plotly's default).
- `textsize = 0`: label font size in px (0: the figure's).

`mode`, `color`, `legend`, `showlegend`, `linewidth`, `dash`, `marker_size`,
`marker_symbol`, `marker_color`, `opacity`, `textposition` and `textsize` also
take a vector with one entry per series (missing entries take the default,
extra entries are ignored); with several series `text` is a vector of
per-series label vectors.

Under a `PlotStyle` (`set_default_style!`/`with_style`) the unset line width, dash,
marker size and marker symbol of each trace are filled from the style; the
dash and marker cycles continue across `plot_scatter3d!` calls and, in a
`SubplotFigure`, across the whole figure.
"""

@doc _s3_doc(
	raw"""
		plot_scatter3d(x, y, z; kwargs...) -> Plot

	3-D lines and/or markers through the points `(x[k], y[k], z[k])` (vectors of
	equal length). Several series: `z` is a vector of vectors (an untyped `Any[]`
	whose elements are all vectors counts too), and `x` and `y` are each either
	one vector shared by every series or a vector of vectors with one entry per
	series.
	""",
	_S3_SCATTER3D_KEYWORDS_DOC;
	constructor = true,
	example = raw"""
	t = range(0, 4π; length = 200)
	fig = plot_scatter3d(cos.(t), sin.(t), t; color = "royalblue", linewidth = 4,
	                     dash = "dash", legend = "helix", zlabel = "\$\\theta\$")
	plot_scatter3d!(fig, [1.0, 1.0], [0.0, 0.0], [0.0, 4π]; mode = "markers",
	                text = ["start", "end"], marker_size = 6, color = :red)
	""",
) plot_scatter3d

@doc _s3_doc(
	_s3_mutator_head(
		raw"""
			plot_scatter3d!(fig, x, y, z; kwargs...)
		""",
		"3-D lines and/or markers",
		"plot_scatter3d",
	),
	_S3_SCATTER3D_KEYWORDS_DOC;
	constructor = false,
	example = raw"""
	fig = plot_surface(rand(10, 10))
	plot_scatter3d!(fig, 0:9, 0:9, ones(10); mode = "lines+markers", color = "black",
	                opacity = 0.5, legend = "diagonal")
	""",
) plot_scatter3d!

#endregion

#region quiver3d (cones and arrows)

const _S3_CONE_SIZEMODES = ("scaled", "absolute", "raw")
const _S3_CONE_ANCHORS = ("tip", "tail", "cm", "center")

# Origins and components of a vector field, flattened to vectors. Every
# element must be a real number; a vector with a non-finite origin or
# component cannot be drawn and is skipped with one warning (as `plot_quiver`
# does), so a single bad sample does not blank the whole trace. When nothing
# is skipped the (flattened) inputs are returned as given.
function _s3_vector_field(who::AbstractString, arrays::Pair...)
	for (name, values) in arrays
		_s3_array(values, who, name)
	end
	_s3_check_lengths(who, arrays...)
	flat = map(((name, values),) -> _s3_flat(_s3_plottable(values)), arrays)
	for ((name, _), values) in zip(arrays, flat)
		for (index, value) in pairs(values)
			_s3_is_real(value) || throw(ArgumentError(
				"$(who): `$(name)[$(index)]` must be a real number; got $(repr(value)).",
			))
		end
	end
	count = length(first(flat))
	keep = [k for k in 1:count if all(values -> isfinite(values[firstindex(values) + k - 1]), flat)]
	length(keep) == count && return flat
	@warn "$(who): skipped $(count - length(keep)) vector(s) with non-finite origins or components."
	return map(values -> values[firstindex(values) .+ keep .- 1], flat)
end

function _s3_quiver3d_traces(
	fig,
	x,
	y,
	z,
	u,
	v,
	w;
	style,
	sizemode,
	sizeref,
	anchor,
	headsize,
	linewidth,
	color,
	legend,
	colorscale,
	crange,
	cmid,
	colornorm,
	levels,
	showscale,
	colorbar_title,
	colorbar_title_side,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	who::AbstractString,
)
	px, py, pz, vx, vy, vz = _s3_vector_field(who, "x" => x, "y" => y, "z" => z, "u" => u, "v" => v, "w" => w)
	style isa AbstractString && (style = Symbol(style))
	style in (:cone, :arrow) || throw(ArgumentError(
		"$(who): `style` must be :cone or :arrow; got $(repr(style)).",
	))
	uniform = _s3_uniform_color(color, who)
	name = String(legend)
	if !isempty(uniform) && !_is_unset_colorscale(colorscale)
		# 1.x accepted `color` together with `colorscale` and drew the uniform
		# colour, so that combination keeps working; the name is still checked.
		_resolve_colorscale(colorscale; who)
		@warn "$(who): `colorscale` is ignored because `color` sets one uniform colour."
		colorscale = ""
	end
	colormap = _s3_colormap_requested(; colorscale, crange, cmid, colornorm, levels, colorbar_title,
		colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
	if !isempty(uniform) && colormap
		throw(ArgumentError(
			"$(who): a uniform `color` cannot be combined with colour-scale keywords " *
			"(crange, cmid, colornorm, levels, colorbar_*, coloraxis).",
		))
	end
	if style === :cone
		(headsize === nothing && linewidth === nothing) || throw(ArgumentError(
			"$(who): `headsize` and `linewidth` apply to style=:arrow; cones are sized " *
			"with `sizemode`/`sizeref`.",
		))
		mode = sizemode === nothing ? "scaled" : _s3_choice(sizemode, _S3_CONE_SIZEMODES, who, "sizemode")
		# sizeref is always written: plotly.js has no usable default for "raw"
		# (cones break without it), and 1 keeps 1.x's cone size for unit fields
		# ("scaled" with sizeref s draws what "absolute" with s drew when the
		# largest norm is 1). 0 is not "hide" for cones, so it is rejected.
		ref = sizeref === nothing ? 1 : _s3_positive(sizeref, who, "sizeref")
		fields = Dict{Symbol, Any}(
			:x => px, :y => py, :z => pz, :u => vx, :v => vy, :w => vz,
			:sizemode => mode,
			:sizeref => ref,
			:anchor => anchor === nothing ? "cm" : _s3_choice(anchor, _S3_CONE_ANCHORS, who, "anchor"),
		)
		spec = _S3ColorSpec()
		if isempty(uniform)
			spec = _s3_color_spec(nothing, who; colorscale, crange, cmid, colornorm, levels, showscale,
				colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis,
				log_unsupported = "cone colours are computed by plotly from the vector norms.")
			merge!(fields, spec.trace)
		else
			# A cone trace has one colour scale, so a uniform colour is a flat scale.
			fields[:colorscale] = _s3_two_stop(uniform)
			fields[:showscale] = false
		end
		isempty(name) || (fields[:name] = name; fields[:showlegend] = true)
		return GenericTrace[GenericTrace("cone"; fields...)], (spec,)
	end
	# style = :arrow: an opaque shaft line plus a cone head per vector.
	colormap && throw(ArgumentError(
		"$(who): style=:arrow draws single-colour arrows; set `color` instead of colour-scale keywords.",
	))
	(sizemode === nothing && sizeref === nothing && anchor === nothing) || throw(ArgumentError(
		"$(who): `sizemode`, `sizeref` and `anchor` apply to style=:cone; arrows are drawn " *
		"at their data length with heads of `headsize`.",
	))
	# Default head: a quarter of the arrow, as in the spec (F34).
	head = headsize === nothing ? 0.25 : _s3_positive(headsize, who, "headsize")
	head < 1 || throw(ArgumentError("$(who): `headsize` must lie in (0, 1); got $(repr(headsize))."))
	width = linewidth === nothing ? 0.0 : _s3_nonnegative(linewidth, who, "linewidth")
	arrow_color = isempty(uniform) ? _s3_default_color(fig, _s3_next_index(fig)) : uniform
	return _arrow3d_traces(px, py, pz, vx, vy, vz; color = arrow_color, linewidth = width,
		headsize = head, legend = name), ()
end

"""
	_arrow3d_traces(x, y, z, u, v, w; color, linewidth, headsize, legend) -> Vector{GenericTrace}

Arrows from `(x, y, z)` to `(x, y, z) + (u, v, w)` in data units: one
scatter3d shaft trace (segments from the tail to the base of the head,
separated by `_GAP`) and one cone trace with a head per arrow (`anchor =
"tip"`, `sizemode = "raw"`, `sizeref = headsize`, so each head is `headsize`
of its arrow's length). Zero vectors draw nothing.
"""
function _arrow3d_traces(x, y, z, u, v, w; color::AbstractString, linewidth::Real, headsize::Float64, legend::AbstractString = "")
	keep = [k for k in eachindex(x, y, z, u, v, w) if u[k] != 0 || v[k] != 0 || w[k] != 0]
	n = length(keep)
	sx = Vector{Union{Nothing, Float64}}(undef, 3n)
	sy = similar(sx)
	sz = similar(sx)
	tips = (Vector{Float64}(undef, n), Vector{Float64}(undef, n), Vector{Float64}(undef, n))
	vectors = (Vector{Float64}(undef, n), Vector{Float64}(undef, n), Vector{Float64}(undef, n))
	for (m, k) in enumerate(keep)
		base = 3(m - 1)
		for (column, p, d) in ((sx, x, u), (sy, y, v), (sz, z, w))
			column[base + 1] = Float64(p[k])
			column[base + 2] = Float64(p[k]) + (1 - headsize) * Float64(d[k])
			column[base + 3] = _GAP
		end
		for (axis, p, d) in ((1, x, u), (2, y, v), (3, z, w))
			tips[axis][m] = Float64(p[k]) + Float64(d[k])
			vectors[axis][m] = Float64(d[k])
		end
	end
	line = Dict{Symbol, Any}(:color => color)
	linewidth > 0 && (line[:width] = linewidth)
	shaft = GenericTrace(
		"scatter3d";
		x = sx, y = sy, z = sz,
		mode = "lines",
		line = attr(; line...),
		name = String(legend),
		showlegend = !isempty(legend),
	)
	heads = GenericTrace(
		"cone";
		x = tips[1], y = tips[2], z = tips[3],
		u = vectors[1], v = vectors[2], w = vectors[3],
		anchor = "tip",
		sizemode = "raw",
		sizeref = headsize,
		colorscale = _s3_two_stop(color),
		showscale = false,
		showlegend = false,
		name = String(legend),
	)
	return GenericTrace[shaft, heads]
end

function plot_quiver3d(
	x::AbstractArray,
	y::AbstractArray,
	z::AbstractArray,
	u::AbstractArray,
	v::AbstractArray,
	w::AbstractArray;
	style = :cone,
	sizemode = nothing,
	sizeref = nothing,
	anchor = nothing,
	headsize = nothing,
	linewidth = nothing,
	color::Union{AbstractString, Symbol, AbstractVector{<:AbstractString}} = "",
	legend::AbstractString = "",
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = "auto",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_quiver3d"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	traces, specs = _s3_quiver3d_traces(nothing, x, y, z, u, v, w; style, sizemode, sizeref, anchor,
		headsize, linewidth, color, legend, colorscale, crange, cmid, colornorm, levels, showscale,
		colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
	return _s3_construct(traces, specs, opts, who, show)
end

function plot_quiver3d!(
	fig,
	x::AbstractArray,
	y::AbstractArray,
	z::AbstractArray,
	u::AbstractArray,
	v::AbstractArray,
	w::AbstractArray;
	style = :cone,
	sizemode = nothing,
	sizeref = nothing,
	anchor = nothing,
	headsize = nothing,
	linewidth = nothing,
	color::Union{AbstractString, Symbol, AbstractVector{<:AbstractString}} = "",
	legend::AbstractString = "",
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = nothing,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	kwargs...,
)
	who = "plot_quiver3d!"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	traces, specs = _s3_quiver3d_traces(fig, x, y, z, u, v, w; style, sizemode, sizeref, anchor,
		headsize, linewidth, color, legend, colorscale, crange, cmid, colornorm, levels, showscale,
		colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
	return _s3_append!(fig, traces, specs, opts, who)
end

const _S3_QUIVER3D_KEYWORDS_DOC = raw"""
- `style = :cone`: `:cone` draws plotly cones; `:arrow` draws arrows (a line
  shaft and a cone head) from each point to point + vector, in data units.
- `sizemode = "scaled"` (cones): how `sizeref` sizes the cones. "scaled":
  relative to the spacing of the points, independent of the magnitude of the
  field; "absolute": `sizeref` is in units of the largest vector norm; "raw":
  each cone is `sizeref` times its vector's length in data units.
- `sizeref = 1` (cones): positive size factor (see `sizemode`).
- `anchor = "cm"` (cones): the part of each cone placed at its point: "cm"
  (the centre of mass, plotly's default: cones are centred on the points
  rather than starting there), "center", "tail" (the vector starts at the
  point, like a matplotlib quiver) or "tip".
- `headsize = 0.25` (arrows): length of the head as a fraction of the arrow,
  in (0, 1).
- `linewidth = nothing` (arrows): shaft width in px (`nothing`: plotly's
  default).
- `color = ""`: one colour (String or Symbol) for every cone or arrow; a
  vector of colours is accepted for compatibility and its first entry is
  used. With `""` cones are coloured by their vector norm through the colour
  keywords and arrows take the next colorway colour. Arrows have one colour,
  so the colour keywords apply to cones only. A `color` combined with
  `colorscale` wins, as in 1.x, with a warning that `colorscale` is ignored;
  combined with the other colour keywords it throws.
- `legend::AbstractString = ""`: legend name.
"""

const _S3_QUIVER3D_HEAD_DOC = raw"""
The vector `(u[k], v[k], w[k])` is drawn at the point `(x[k], y[k], z[k])`
(vectors or arrays of equal length, flattened in memory order). A vector whose
position or components are not finite cannot be drawn and is skipped with a
warning. By default each cone is centred on its point (`anchor = "cm"`);
`anchor = "tail"` starts the vectors at the points.
"""

@doc _s3_doc(
	raw"""
		plot_quiver3d(x, y, z, u, v, w; kwargs...) -> Plot

	3-D vector field as cones or arrows.
	""" * "\n" * _S3_QUIVER3D_HEAD_DOC,
	_S3_QUIVER3D_KEYWORDS_DOC;
	constructor = true,
	colour = true,
	colour_note = "`colornorm = :log` is not available: plotly computes the cone colours from the vector norms.",
	example = raw"""
	g = [-1.0, 0.0, 1.0]
	x = [a for a in g, b in g, c in g]; y = [b for a in g, b in g, c in g]; z = [c for a in g, b in g, c in g]
	fig = plot_quiver3d(x, y, z, -y, x, fill(0.3, size(x)); colorscale = "viridis", anchor = "tail")
	plot_quiver3d!(fig, [0.0], [0.0], [1.5], [0.0], [0.0], [-1.0]; style = :arrow, color = "red")
	""",
) plot_quiver3d

@doc _s3_doc(
	_s3_mutator_head(
		raw"""
			plot_quiver3d!(fig, x, y, z, u, v, w; kwargs...)
		""",
		"a 3-D vector field",
		"plot_quiver3d",
	) * "\n\n" * _S3_QUIVER3D_HEAD_DOC,
	_S3_QUIVER3D_KEYWORDS_DOC;
	constructor = false,
	colour = true,
	colour_note = "`colornorm = :log` is not available: plotly computes the cone colours from the vector norms.",
	example = raw"""
	fig = plot_scatter3d([0.0, 1.0], [0.0, 0.0], [0.0, 0.0]; color = "black")
	plot_quiver3d!(fig, [0.0, 1.0], [0.0, 0.0], [0.0, 0.0], [0.0, 0.0], [0.0, 0.0], [1.0, 2.0];
	               style = :arrow, headsize = 0.2, linewidth = 4, legend = "force")
	""",
) plot_quiver3d!

#endregion

#region Line traces with gaps (edges, wireframes, segments)

function _s3_line_style(color, linewidth, dash, opacity, fig, scenekey::Symbol, who::AbstractString; default_color::AbstractString)
	line_color = _s3_color(color, who, "color")
	isempty(line_color) && (line_color = default_color)
	# `nothing`: the width comes from the active style (`_s3_collection_style`).
	width = linewidth === nothing ? 0.0 : _s3_nonnegative(linewidth, who, "linewidth")
	dash_value = _s3_dash(dash, who)
	alpha = _s3_unit_interval(opacity, who, "opacity")
	line = Dict{Symbol, Any}(:color => _s3_line_color(line_color, alpha, fig, scenekey, who))
	width > 0 && (line[:width] = width)
	isempty(dash_value) || (line[:dash] = dash_value)
	return attr(; line...)
end

# One scatter3d trace drawing the segments `(a, b)` (1-based vertex indices)
# of the vertex lists `x`, `y`, `z`, separated by `_GAP`.
function _s3_segment_trace(x, y, z, edges; line, legend::AbstractString = "", hover::Bool = true)
	n = length(edges)
	sx = Vector{Union{Nothing, Float64}}(undef, 3n)
	sy = similar(sx)
	sz = similar(sx)
	for (m, (a, b)) in enumerate(edges)
		base = 3(m - 1)
		sx[base + 1], sy[base + 1], sz[base + 1] = _s3_gap_value(x[a]), _s3_gap_value(y[a]), _s3_gap_value(z[a])
		sx[base + 2], sy[base + 2], sz[base + 2] = _s3_gap_value(x[b]), _s3_gap_value(y[b]), _s3_gap_value(z[b])
		sx[base + 3] = sy[base + 3] = sz[base + 3] = _GAP
	end
	fields = Dict{Symbol, Any}(
		:x => sx, :y => sy, :z => sz,
		:mode => "lines",
		:line => line,
		:name => String(legend),
		:showlegend => !isempty(legend),
	)
	hover || (fields[:hoverinfo] = "skip")
	return GenericTrace("scatter3d"; fields...)
end

# Non-finite coordinates become gaps (`_GAP`, JSON null) rather than NaN,
# which strict JSON cannot carry.
# A Bool element is 0/1, as `_s3_plottable` draws Bool arrays.
_s3_gap_value(value) = (value isa Real && isfinite(value)) ? Float64(value) : _GAP

"""
	_mesh_edge_trace(x, y, z, faces; color, width, who) -> GenericTrace

Edges of polygonal faces as one opaque scatter3d trace. `faces` iterates over
vectors of 1-based vertex indices (triangles or polygons); each polygon
contributes its boundary edges only (no fan diagonals), and an edge shared by
two faces is drawn once.
"""
function _mesh_edge_trace(x, y, z, faces; color::AbstractString, width::Real, who::AbstractString)
	seen = Set{Tuple{Int, Int}}()
	edges = Tuple{Int, Int}[]
	for face in faces
		k = length(face)
		for m in 1:k
			a = Int(face[m])
			b = Int(face[m == k ? 1 : m + 1])
			a == b && continue
			key = a < b ? (a, b) : (b, a)
			key in seen && continue
			push!(seen, key)
			push!(edges, key)
		end
	end
	line = Dict{Symbol, Any}(:color => color)
	width > 0 && (line[:width] = width)
	return _s3_segment_trace(x, y, z, edges; line = attr(; line...), hover = false)
end

function _s3_edge_style(edgecolor, edgewidth, who::AbstractString)
	color = _s3_color(edgecolor, who, "edgecolor")
	width = _s3_nonnegative(edgewidth, who, "edgewidth")
	return color, width
end

#endregion

#region mesh3d

function _require_mesh_indices(indices, name::Symbol, vertex_count::Int, who::AbstractString)
	(indices isa AbstractVector || indices isa Tuple) || throw(ArgumentError(
		"$(who): `$name` must be a one-dimensional index collection.",
	))
	for (position, index) in enumerate(indices)
		(index isa Integer && !(index isa Bool) && 0 <= index < vertex_count) || throw(ArgumentError(
			"$(who): `$name[$position]` must be a zero-based integer " *
			"between 0 and $(vertex_count - 1); got $(repr(index)).",
		))
	end
	return length(indices)
end

function _s3_mesh3d_traces(
	fig,
	x,
	y,
	z;
	i,
	j,
	k,
	intensity,
	intensitymode,
	facecolor,
	color,
	opacity,
	flatshading,
	lighting,
	edges::Bool,
	edgecolor,
	edgewidth,
	legend,
	colorscale,
	crange,
	cmid,
	colornorm,
	levels,
	showscale,
	colorbar_title,
	colorbar_title_side,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	who::AbstractString,
)
	for (name, values) in (("x", x), ("y", y), ("z", z))
		_s3_array(values, who, name)
	end
	px, py, pz = _s3_flat(_s3_plottable(x)), _s3_flat(_s3_plottable(y)), _s3_flat(_s3_plottable(z))
	vertex_count = length(px)
	(length(py) == vertex_count && length(pz) == vertex_count) || throw(ArgumentError(
		"$(who): x, y, z must share length; got $(length(px)), $(length(py)), $(length(pz)).",
	))
	alpha = _s3_unit_interval(opacity, who, "opacity")
	fields = Dict{Symbol, Any}(:x => px, :y => py, :z => pz)
	present = (i !== nothing, j !== nothing, k !== nothing)
	face_count = nothing
	if any(present) && !all(present)
		throw(ArgumentError(
			"$(who): triangle indices `i`, `j`, and `k` must be supplied together or all omitted.",
		))
	elseif all(present)
		lengths = (
			_require_mesh_indices(i, :i, vertex_count, who),
			_require_mesh_indices(j, :j, vertex_count, who),
			_require_mesh_indices(k, :k, vertex_count, who),
		)
		lengths[1] == lengths[2] == lengths[3] || throw(ArgumentError(
			"$(who): i, j, k must share length; got $(join(lengths, ", ")).",
		))
		face_count = lengths[1]
		fields[:i] = i
		fields[:j] = j
		fields[:k] = k
	end
	uniform = _s3_uniform_color(color, who)
	colormap = _s3_colormap_requested(; colorscale, crange, cmid, colornorm, levels, colorbar_title,
		colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
	spec = _S3ColorSpec()
	if intensity !== nothing
		(isempty(uniform) && facecolor === nothing) || throw(ArgumentError(
			"$(who): `intensity` colours the mesh through the colour scale; do not also pass `color`/`facecolor`.",
		))
		_s3_array(intensity, who, "intensity")
		values = _s3_flat(intensity)
		count = length(values)
		requested = _s3_choice(intensitymode === nothing ? "" : intensitymode, ("", "vertex", "cell"), who, "intensitymode")
		mode = if requested == "cell" || (requested == "" && count != vertex_count && count == face_count)
			face_count === nothing && throw(ArgumentError(
				"$(who): per-face `intensity` needs explicit triangles (`i`, `j`, `k`).",
			))
			count == face_count || throw(ArgumentError(
				"$(who): `intensity` has $(count) values for $(face_count) faces.",
			))
			"cell"
		else
			count == vertex_count || throw(ArgumentError(
				"$(who): `intensity` must match x/y/z in length (per vertex)" *
				(face_count === nothing ? "" : " or the number of faces ($(face_count))") *
				"; got $(count) and $(vertex_count).",
			))
			"vertex"
		end
		spec = _s3_color_spec(_s3_plottable(values), who; values_key = :intensity, colorscale, crange,
			cmid, colornorm, levels, showscale, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis)
		merge!(fields, spec.trace)
		mode == "cell" && (fields[:intensitymode] = "cell")
	else
		colormap && throw(ArgumentError(
			"$(who): colour-scale keywords need `intensity` (values per vertex or per face).",
		))
		(intensitymode === nothing || intensitymode == "") || throw(ArgumentError(
			"$(who): `intensitymode` needs `intensity`.",
		))
		if facecolor !== nothing
			isempty(uniform) || throw(ArgumentError("$(who): pass `color` or `facecolor`, not both."))
			face_count === nothing && throw(ArgumentError(
				"$(who): `facecolor` needs explicit triangles (`i`, `j`, `k`).",
			))
			(facecolor isa AbstractVector && length(facecolor) == face_count) || throw(ArgumentError(
				"$(who): `facecolor` must be a vector with one colour per face ($(face_count)).",
			))
			fields[:facecolor] = String[_s3_color(c, who, "facecolor") for c in facecolor]
		end
		isempty(uniform) || (fields[:color] = uniform)
	end
	light, flat = _s3_lighting(lighting, who)
	light === nothing || (fields[:lighting] = light)
	flatshading === nothing || flatshading isa Bool || throw(ArgumentError(
		"$(who): `flatshading` must be true, false or nothing; got $(repr(flatshading)).",
	))
	shading = flatshading === nothing ? (flat ? true : nothing) : flatshading
	shading === nothing || (fields[:flatshading] = shading)
	alpha < 1 && (fields[:opacity] = alpha)
	name = String(legend)
	isempty(name) || (fields[:name] = name; fields[:showlegend] = true)
	traces = GenericTrace[GenericTrace("mesh3d"; fields...)]
	if edges
		face_count === nothing && throw(ArgumentError(
			"$(who): `edges=true` needs explicit triangles (`i`, `j`, `k`).",
		))
		line_color, line_width = _s3_edge_style(edgecolor, edgewidth, who)
		isempty(line_color) && (line_color = "black")
		triangles = ((Int(i[m]) + 1, Int(j[m]) + 1, Int(k[m]) + 1) for m in 1:face_count)
		push!(traces, _mesh_edge_trace(px, py, pz, triangles; color = line_color, width = line_width, who))
	end
	return traces, (spec,)
end

function plot_mesh3d(
	x::AbstractArray,
	y::AbstractArray,
	z::AbstractArray;
	i = nothing,
	j = nothing,
	k = nothing,
	intensity = nothing,
	intensitymode = nothing,
	facecolor = nothing,
	color = "",
	opacity::Real = 1,
	flatshading = nothing,
	lighting = :default,
	edges::Bool = false,
	edgecolor = "black",
	edgewidth::Real = 1,
	legend::AbstractString = "",
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = "auto",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_mesh3d"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	traces, specs = _s3_mesh3d_traces(nothing, x, y, z; i, j, k, intensity, intensitymode, facecolor,
		color, opacity, flatshading, lighting, edges, edgecolor, edgewidth, legend, colorscale, crange,
		cmid, colornorm, levels, showscale, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels,
		coloraxis, who)
	return _s3_construct(traces, specs, opts, who, show)
end

function plot_mesh3d!(
	fig,
	x::AbstractArray,
	y::AbstractArray,
	z::AbstractArray;
	i = nothing,
	j = nothing,
	k = nothing,
	intensity = nothing,
	intensitymode = nothing,
	facecolor = nothing,
	color = "",
	opacity::Real = 1,
	flatshading = nothing,
	lighting = :default,
	edges::Bool = false,
	edgecolor = "black",
	edgewidth::Real = 1,
	legend::AbstractString = "",
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = nothing,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	kwargs...,
)
	who = "plot_mesh3d!"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	traces, specs = _s3_mesh3d_traces(fig, x, y, z; i, j, k, intensity, intensitymode, facecolor,
		color, opacity, flatshading, lighting, edges, edgecolor, edgewidth, legend, colorscale, crange,
		cmid, colornorm, levels, showscale, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels,
		coloraxis, who)
	return _s3_append!(fig, traces, specs, opts, who)
end

const _S3_MESH3D_KEYWORDS_DOC = raw"""
- `i = nothing`, `j = nothing`, `k = nothing`: 0-based vertex indices of the
  triangles (plotly's convention; give all three or none: without them plotly
  triangulates the points itself).
- `intensity = nothing`: colour values, one per vertex or one per triangle
  (then `intensitymode = "cell"` is chosen automatically).
- `intensitymode = nothing`: "vertex" or "cell", to decide when the vertex and
  triangle counts are equal.
- `facecolor = nothing`: a vector with one colour per triangle.
- `color = ""`: one colour (String or Symbol) for the whole mesh.
- `opacity::Real = 1`: in [0, 1].
- `flatshading = nothing`: `true` shades every triangle flat (`nothing`:
  plotly's default, or `true` with `lighting = :flat`).
- `lighting = :default`: `:default` (plotly's shading), `:flat` (unshaded,
  like matplotlib) or a NamedTuple of plotly lighting fields (`ambient`,
  `diffuse`, `specular`, `roughness`, `fresnel`, `vertexnormalsepsilon`,
  `facenormalsepsilon`; each ≥ 0).
- `edges::Bool = false`: also draw every triangle edge once, as a second,
  opaque line trace (needs `i`, `j`, `k`).
- `edgecolor = "black"`: colour of the edges.
- `edgewidth::Real = 1`: width of the edges in px (0: plotly's default).
- `legend::AbstractString = ""`: legend name.
"""

const _S3_MESH3D_HEAD_DOC = raw"""
The vertices are `(x[n], y[n], z[n])` (vectors, or arrays flattened in memory
order). Colours come from `intensity` (through the colour keywords),
`facecolor` or `color`, at most one of them. For polygons with 1-based
connectivity and per-face values see [`plot_polygons3d`](@ref).
"""

@doc _s3_doc(
	raw"""
		plot_mesh3d(x, y, z; kwargs...) -> Plot

	Triangle mesh.
	""" * "\n" * _S3_MESH3D_HEAD_DOC,
	_S3_MESH3D_KEYWORDS_DOC;
	constructor = true,
	colour = true,
	colour_note = "The colour keywords need `intensity`.",
	example = raw"""
	x = [0.0, 1, 0, 0]; y = [0.0, 0, 1, 0]; z = [0.0, 0, 0, 1]
	fig = plot_mesh3d(x, y, z; i = [0, 0, 0, 1], j = [1, 1, 2, 2], k = [2, 3, 3, 3],
	                  facecolor = ["red", "green", "blue", "gold"], edges = true)
	""",
) plot_mesh3d

@doc _s3_doc(
	_s3_mutator_head(
		raw"""
			plot_mesh3d!(fig, x, y, z; kwargs...)
		""",
		"a triangle mesh",
		"plot_mesh3d",
	) * "\n\n" * _S3_MESH3D_HEAD_DOC,
	_S3_MESH3D_KEYWORDS_DOC;
	constructor = false,
	colour = true,
	colour_note = "The colour keywords need `intensity`.",
	example = raw"""
	fig = plot_scatter3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0])
	plot_mesh3d!(fig, [0.0, 1, 0], [0.0, 0, 1], [0.0, 0, 0]; i = [0], j = [1], k = [2],
	             intensity = [1.0], colorscale = "plasma", opacity = 0.8)
	""",
) plot_mesh3d!

#endregion

#region Volumetric fields: isosurface, volume, streamtube

# Point lists for gridded 3-D fields. Two forms:
# - points: every array has the same length (N-d arrays need the same size)
#   and is flattened in memory order;
# - grid: `x`, `y`, `z` are the axis vectors and every field array is
#   `length(x)×length(y)×length(z)` (`field[i, j, k]` at `(x[i], y[j], z[k])`);
#   the coordinates are expanded to full point lists.
function _s3_field_points(who::AbstractString, coordinates::NTuple{3, Any}, fields::Pair...)
	names = ("x", "y", "z")
	for (name, values) in zip(names, coordinates)
		_s3_array(values, who, name)
	end
	for (name, values) in fields
		_s3_array(values, who, name)
	end
	coordinates = map(_s3_plottable, coordinates)
	fields = map(field -> first(field) => _s3_plottable(last(field)), fields)
	all_arrays = (coordinates..., map(last, fields)...)
	count = length(first(all_arrays))
	if all(a -> length(a) == count, all_arrays)
		shape = nothing
		for a in all_arrays
			ndims(a) > 1 || continue
			shape === nothing && (shape = size(a))
			size(a) == shape || throw(ArgumentError(
				"$(who): arrays of the same length must also have the same shape; got " *
				join((join(size(b), "×") for b in all_arrays), ", ") * ".",
			))
		end
		return map(_s3_flat, coordinates), map(f -> _s3_flat(last(f)), fields)
	end
	grid_shape = map(length, coordinates)
	if all(c -> ndims(c) == 1, coordinates) && all(f -> ndims(last(f)) == 3 && size(last(f)) == grid_shape, fields)
		nx, ny, nz = grid_shape
		total = nx * ny * nz
		gx = Vector{Float64}(undef, total)
		gy = similar(gx)
		gz = similar(gx)
		x, y, z = coordinates
		n = 0
		for kz in 1:nz, jy in 1:ny, ix in 1:nx
			n += 1
			gx[n] = x[firstindex(x) + ix - 1]
			gy[n] = y[firstindex(y) + jy - 1]
			gz[n] = z[firstindex(z) + kz - 1]
		end
		return (gx, gy, gz), map(f -> _s3_flat(last(f)), fields)
	end
	field_names = join(("`$(name)`" for (name, _) in fields), ", ")
	throw(ArgumentError(
		"$(who): expected x, y, z and $(field_names) with one value per point (same " *
		"lengths), or axis vectors x, y, z with $(field_names) of size " *
		"length(x)×length(y)×length(z); got sizes " *
		join((join(size(a), "×") for a in all_arrays), ", ") * ".",
	))
end

function _s3_field3d_trace(
	kind::AbstractString,
	x,
	y,
	z,
	value;
	isomin,
	isomax,
	surface_count,
	opacity,
	caps,
	colorscale,
	crange,
	cmid,
	colornorm,
	levels,
	showscale,
	colorbar_title,
	colorbar_title_side,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	who::AbstractString,
)
	(px, py, pz), (values,) = _s3_field_points(who, (x, y, z), "value" => value)
	fields = Dict{Symbol, Any}(:x => px, :y => py, :z => pz, :value => _s3_plottable(values))
	lo = isomin === nothing ? nothing : _s3_finite_real(isomin, who, "isomin")
	hi = isomax === nothing ? nothing : _s3_finite_real(isomax, who, "isomax")
	(lo !== nothing && hi !== nothing && !(lo < hi)) && throw(ArgumentError(
		"$(who): `isomin` must be less than `isomax`; got $(lo) and $(hi).",
	))
	lo === nothing || (fields[:isomin] = isomin)
	hi === nothing || (fields[:isomax] = isomax)
	(surface_count isa Integer && !(surface_count isa Bool) && surface_count >= 0) || throw(ArgumentError(
		"$(who): `surface_count` must be an integer >= 0 (0 = plotly's default); got $(repr(surface_count)).",
	))
	surface_count > 0 && (fields[:surface_count] = surface_count)
	alpha = _s3_unit_interval(opacity, who, "opacity")
	alpha < 1 && (fields[:opacity] = alpha)
	if caps !== nothing
		caps isa Bool || throw(ArgumentError("$(who): `caps` must be true, false or nothing; got $(repr(caps))."))
		fields[:caps] = attr(x = attr(show = caps), y = attr(show = caps), z = attr(show = caps))
	end
	spec = _s3_color_spec(nothing, who; colorscale, crange, cmid, colornorm, levels, showscale,
		colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis,
		log_unsupported = "plotly computes the $(kind) levels from the raw values; pass log10.(value) instead.")
	merge!(fields, spec.trace)
	return GenericTrace(kind; fields...), spec
end

for (fn, fn!, kind, default_opacity) in (
	(:plot_isosurface, :plot_isosurface!, "isosurface", 1.0),
	(:plot_volume, :plot_volume!, "volume", 0.1),
)
	@eval begin
		function $fn(
			x::AbstractArray,
			y::AbstractArray,
			z::AbstractArray,
			value::AbstractArray;
			isomin = nothing,
			isomax = nothing,
			surface_count::Integer = 0,
			opacity::Real = $default_opacity,
			caps = nothing,
			colorscale = "",
			crange = [0, 0],
			cmid = nothing,
			colornorm = :linear,
			levels = nothing,
			showscale::Union{Nothing, Bool} = nothing,
			colorbar_title::AbstractString = "",
			colorbar_title_side = :top,
			colorbar_ticks = nothing,
			colorbar_ticklabels = nothing,
			coloraxis = nothing,
			xrange = [0, 0],
			yrange = [0, 0],
			zrange = [0, 0],
			xlabel::AbstractString = "",
			ylabel::AbstractString = "",
			zlabel::AbstractString = "",
			aspectmode = "auto",
			perspective::Bool = true,
			grid::Bool = true,
			showaxis::Bool = true,
			title::AbstractString = "",
			width::Real = 0,
			height::Real = 0,
			fontsize::Real = 0,
			view = nothing,
			show::Bool = false,
			kwargs...,
		)
			who = $(String(fn))
			_s3_reject_kwargs(who, kwargs)
			opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
				aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
			trace, spec = _s3_field3d_trace($kind, x, y, z, value; isomin, isomax, surface_count,
				opacity, caps, colorscale, crange, cmid, colornorm, levels, showscale, colorbar_title,
				colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
			return _s3_construct(GenericTrace[trace], (spec,), opts, who, show)
		end

		function $fn!(
			fig,
			x::AbstractArray,
			y::AbstractArray,
			z::AbstractArray,
			value::AbstractArray;
			isomin = nothing,
			isomax = nothing,
			surface_count::Integer = 0,
			opacity::Real = $default_opacity,
			caps = nothing,
			colorscale = "",
			crange = [0, 0],
			cmid = nothing,
			colornorm = :linear,
			levels = nothing,
			showscale::Union{Nothing, Bool} = nothing,
			colorbar_title::AbstractString = "",
			colorbar_title_side = :top,
			colorbar_ticks = nothing,
			colorbar_ticklabels = nothing,
			coloraxis = nothing,
			xrange = [0, 0],
			yrange = [0, 0],
			zrange = [0, 0],
			xlabel::AbstractString = "",
			ylabel::AbstractString = "",
			zlabel::AbstractString = "",
			aspectmode = nothing,
			perspective::Union{Nothing, Bool} = nothing,
			grid::Union{Nothing, Bool} = nothing,
			showaxis::Union{Nothing, Bool} = nothing,
			title::AbstractString = "",
			width::Real = 0,
			height::Real = 0,
			fontsize::Real = 0,
			view = nothing,
			kwargs...,
		)
			who = $(String(fn!))
			_s3_reject_kwargs(who, kwargs)
			opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
				aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
			trace, spec = _s3_field3d_trace($kind, x, y, z, value; isomin, isomax, surface_count,
				opacity, caps, colorscale, crange, cmid, colornorm, levels, showscale, colorbar_title,
				colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
			return _s3_append!(fig, GenericTrace[trace], (spec,), opts, who)
		end
	end
end

function _s3_streamtube_trace(
	x,
	y,
	z,
	u,
	v,
	w;
	sizeref,
	colorscale,
	crange,
	cmid,
	colornorm,
	levels,
	showscale,
	colorbar_title,
	colorbar_title_side,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	who::AbstractString,
)
	(px, py, pz), (fu, fv, fw) = _s3_field_points(who, (x, y, z), "u" => u, "v" => v, "w" => w)
	fields = Dict{Symbol, Any}(:x => px, :y => py, :z => pz, :u => fu, :v => fv, :w => fw)
	ref = _s3_nonnegative(sizeref, who, "sizeref")
	ref > 0 && (fields[:sizeref] = sizeref)
	spec = _s3_color_spec(nothing, who; colorscale, crange, cmid, colornorm, levels, showscale,
		colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis,
		log_unsupported = "streamtube colours are computed by plotly from the vector norms.")
	merge!(fields, spec.trace)
	return GenericTrace("streamtube"; fields...), spec
end

function plot_streamtube(
	x::AbstractArray,
	y::AbstractArray,
	z::AbstractArray,
	u::AbstractArray,
	v::AbstractArray,
	w::AbstractArray;
	sizeref::Real = 0,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = "auto",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_streamtube"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	trace, spec = _s3_streamtube_trace(x, y, z, u, v, w; sizeref, colorscale, crange, cmid, colornorm,
		levels, showscale, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
	return _s3_construct(GenericTrace[trace], (spec,), opts, who, show)
end

function plot_streamtube!(
	fig,
	x::AbstractArray,
	y::AbstractArray,
	z::AbstractArray,
	u::AbstractArray,
	v::AbstractArray,
	w::AbstractArray;
	sizeref::Real = 0,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = nothing,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	kwargs...,
)
	who = "plot_streamtube!"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	trace, spec = _s3_streamtube_trace(x, y, z, u, v, w; sizeref, colorscale, crange, cmid, colornorm,
		levels, showscale, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
	return _s3_append!(fig, GenericTrace[trace], (spec,), opts, who)
end

const _S3_FIELD_LAYOUT_DOC = raw"""
The field is sampled on a grid, given in one of two forms: every argument has
one entry per point (vectors, or arrays of one shape such as `ndgrid` 3-D
arrays, flattened in memory order), or `x`, `y`, `z` are axis vectors and the
field arrays have size `length(x)×length(y)×length(z)`, with `A[i, j, k]` at
`(x[i], y[j], z[k])`. Other shapes throw an `ArgumentError`.
"""

for (fn, fn!, kind, default_opacity, what, example) in (
	(
		:plot_isosurface, :plot_isosurface!, "isosurface", 1.0, "an isosurface",
		raw"""
		g = range(-1, 1; length = 20)
		V = [x^2 + y^2 + z^2 for x in g, y in g, z in g]   # V[i, j, k] at (g[i], g[j], g[k])
		fig = plot_isosurface(g, g, g, V; isomin = 0.3, isomax = 0.8, surface_count = 3,
		                      colorscale = "plasma", caps = false)
		""",
	),
	(
		:plot_volume, :plot_volume!, "volume", 0.1, "a volume rendering",
		raw"""
		g = range(-1, 1; length = 20)
		V = [exp(-4(x^2 + y^2 + z^2)) for x in g, y in g, z in g]
		fig = plot_volume(g, g, g, V; isomin = 0.1, surface_count = 15, opacity = 0.2,
		                  colorscale = "viridis")
		""",
	),
)
	keywords = """
	- `isomin = nothing`, `isomax = nothing`: the range of values drawn
	  (`nothing`: the data range); `isomin < isomax`.
	- `surface_count::Integer = 0`: number of iso-surfaces (0: plotly's default).
	- `opacity::Real = $(default_opacity)`: in [0, 1].
	- `caps = nothing`: `false` hides the caps where the field meets the grid
	  boundary (`nothing`: plotly's default).
	"""
	note = "`colornorm = :log` is not available: plotly computes the levels from the raw values (pass `log10.(value)`)."
	head = "\t$(fn)(x, y, z, value; kwargs...) -> Plot\n\n" *
		"3-D $(kind) of the scalar field `value`.\n\n" * _S3_FIELD_LAYOUT_DOC
	ctor_doc = _s3_doc(head, keywords; constructor = true, colour = true, colour_note = note, example)
	mutator_head = _s3_mutator_head("\t$(fn!)(fig, x, y, z, value; kwargs...)", what, String(fn)) *
		"\n\n" * _S3_FIELD_LAYOUT_DOC
	mutator_example = "fig = plot_scatter3d([-1.0, 1.0], [-1.0, 1.0], [-1.0, 1.0]; mode = \"markers\")\n" *
		replace(example, "fig = $(fn)(" => "$(fn!)(fig, ")
	mutator_doc = _s3_doc(mutator_head, keywords; constructor = false, colour = true, colour_note = note,
		example = mutator_example)
	@eval @doc $ctor_doc $fn
	@eval @doc $mutator_doc $fn!
end

const _S3_STREAMTUBE_KEYWORDS_DOC = raw"""
- `sizeref::Real = 0`: scale of the tube diameter (0: plotly's default).
"""

const _S3_STREAMTUBE_HEAD_DOC = raw"""
The tubes start at plotly's default seed points, the interior grid points of
the plane `y = minimum(y)`, so only flow that leaves that plane is drawn; they
are coloured by the vector norm.
""" * "\n" * _S3_FIELD_LAYOUT_DOC

@doc _s3_doc(
	raw"""
		plot_streamtube(x, y, z, u, v, w; kwargs...) -> Plot

	Streamtubes of the vector field `(u, v, w)`.
	""" * "\n" * _S3_STREAMTUBE_HEAD_DOC,
	_S3_STREAMTUBE_KEYWORDS_DOC;
	constructor = true,
	colour = true,
	colour_note = "`colornorm = :log` is not available: plotly computes the colours from the vector norms.",
	example = raw"""
	g = range(-1, 1; length = 8)
	U = [-y for x in g, y in g, z in g]; V = [x for x in g, y in g, z in g]; W = fill(0.2, 8, 8, 8)
	fig = plot_streamtube(g, g, g, U, V, W; sizeref = 0.5, colorscale = "viridis")
	""",
) plot_streamtube

@doc _s3_doc(
	_s3_mutator_head(
		raw"""
			plot_streamtube!(fig, x, y, z, u, v, w; kwargs...)
		""",
		"streamtubes",
		"plot_streamtube",
	) * "\n\n" * _S3_STREAMTUBE_HEAD_DOC,
	_S3_STREAMTUBE_KEYWORDS_DOC;
	constructor = false,
	colour = true,
	colour_note = "`colornorm = :log` is not available: plotly computes the colours from the vector norms.",
	example = raw"""
	g = range(-1, 1; length = 8)
	U = [-y for x in g, y in g, z in g]; V = [x for x in g, y in g, z in g]; W = fill(0.2, 8, 8, 8)
	fig = plot_scatter3d([0.0], [0.0], [-1.0]; mode = "markers")
	plot_streamtube!(fig, g, g, g, U, V, W; colorscale = "plasma", showscale = false)
	""",
) plot_streamtube!

#endregion

#region polygons3d

# Explicit polygons (each a k×3 matrix of vertex coordinates, k ≥ 3): shared
# vertices are merged by exact coordinate, so adjacent faces share edges.
function _s3_explicit_polygons(faces, who::AbstractString)
	faces isa AbstractVector || throw(ArgumentError(
		"$(who): `faces` must be a vector of k×3 coordinate matrices; got $(typeof(faces)).",
	))
	isempty(faces) && throw(ArgumentError("$(who): `faces` is empty; pass at least one polygon."))
	index = Dict{NTuple{3, Float64}, Int}()
	xs, ys, zs = Float64[], Float64[], Float64[]
	polygons = Vector{Vector{Int}}(undef, length(faces))
	for (f, face) in enumerate(faces)
		(face isa AbstractMatrix && size(face, 2) == 3 && size(face, 1) >= 3) || throw(ArgumentError(
			"$(who): face $(f) must be a k×3 matrix of vertex coordinates with k ≥ 3; got " *
			(face isa AbstractArray ? join(size(face), "×") * " $(typeof(face))" : string(typeof(face))) * ".",
		))
		face = _s3_plottable(face)
		ids = Vector{Int}(undef, size(face, 1))
		for (r, row) in enumerate(axes(face, 1))
			point = ntuple(3) do c
				value = face[row, firstindex(face, 2) + c - 1]
				(_s3_is_real(value) && isfinite(value)) || throw(ArgumentError(
					"$(who): face $(f) vertex $(r) has a non-finite or non-real coordinate $(repr(value)).",
				))
				# `+ 0.0` turns -0.0 into 0.0 so both merge into one vertex.
				Float64(value) + 0.0
			end
			ids[r] = get!(index, point) do
				push!(xs, point[1])
				push!(ys, point[2])
				push!(zs, point[3])
				length(xs)
			end
		end
		polygons[f] = ids
	end
	return xs, ys, zs, polygons
end

# Indexed polygons: vertex vectors plus faces as an nf×k matrix or a vector of
# index vectors (1-based, k ≥ 3).
function _s3_indexed_polygons(x, y, z, faces, who::AbstractString)
	for (name, values) in (("x", x), ("y", y), ("z", z))
		_s3_array(values, who, name)
	end
	x, y, z = _s3_plottable(x), _s3_plottable(y), _s3_plottable(z)
	for (name, values) in (("x", x), ("y", y), ("z", z))
		_s3_all_finite(values, who, name)
	end
	n = _s3_check_lengths(who, "x" => x, "y" => y, "z" => z)
	rows = if faces isa AbstractMatrix
		size(faces, 2) >= 3 || throw(ArgumentError(
			"$(who): a face matrix needs at least 3 columns (vertices per face); got $(size(faces, 2)).",
		))
		(view(faces, r, :) for r in axes(faces, 1))
	elseif faces isa AbstractVector
		faces
	else
		throw(ArgumentError(
			"$(who): `faces` must be an nf×k index matrix or a vector of index vectors; got $(typeof(faces)).",
		))
	end
	polygons = Vector{Vector{Int}}()
	for (f, face) in enumerate(rows)
		(face isa AbstractVector && length(face) >= 3) || throw(ArgumentError(
			"$(who): face $(f) must list at least 3 vertex indices; got $(repr(face)).",
		))
		ids = Vector{Int}(undef, length(face))
		for (m, index) in enumerate(face)
			(index isa Integer && !(index isa Bool) && 1 <= index <= n) || throw(ArgumentError(
				"$(who): face $(f) has vertex index $(repr(index)); indices are 1-based and must lie in 1:$(n).",
			))
			ids[m] = Int(index)
		end
		push!(polygons, ids)
	end
	isempty(polygons) && throw(ArgumentError("$(who): `faces` is empty; pass at least one polygon."))
	return _s3_flat(x), _s3_flat(y), _s3_flat(z), polygons
end

function _s3_polygons3d_traces(
	fig,
	x,
	y,
	z,
	polygons::Vector{Vector{Int}},
	values;
	color,
	opacity,
	lighting,
	edgecolor,
	edgewidth,
	legend,
	colorscale,
	crange,
	cmid,
	colornorm,
	levels,
	showscale,
	colorbar_title,
	colorbar_title_side,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	who::AbstractString,
)
	alpha = _s3_unit_interval(opacity, who, "opacity")
	light, flat = _s3_lighting(lighting, who)
	line_color, line_width = _s3_edge_style(edgecolor, edgewidth, who)
	uniform = _s3_uniform_color(color, who)
	keep = trues(length(polygons))
	face_values = nothing
	if values !== nothing
		isempty(uniform) || throw(ArgumentError(
			"$(who): `values` colour the faces through the colour scale; do not also pass `color`.",
		))
		(values isa AbstractVector && length(values) == length(polygons)) || throw(ArgumentError(
			"$(who): `values` must be a vector with one value per face ($(length(polygons))); got " *
			(values isa AbstractVector ? "$(length(values)) values." : "$(typeof(values))."),
		))
		_s3_check_numeric_array(values, who, "values")
		log_norm = _normalize_colornorm(colornorm, who) === :log
		auto_limits = _is_auto_range(crange)
		face_values = values
		for (f, value) in enumerate(values)
			_s3_is_real(value) || throw(ArgumentError(
				"$(who): `values[$(f)]` must be a real number; got $(repr(value)).",
			))
			# Faces without a colour value are not filled (their edges are
			# still drawn), like masked cells in matplotlib.
			(isfinite(value) && !(log_norm && auto_limits && value <= 0)) || (keep[f] = false)
		end
	else
		(colorscale !== nothing || _s3_colormap_requested(; colorscale = "", crange, cmid, colornorm, levels,
			colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)) && throw(ArgumentError(
			"$(who): colour-scale keywords need per-face `values`.",
		))
		isempty(uniform) && (uniform = _s3_default_color(fig, _s3_next_index(fig)))
	end
	triangle_count = sum(f -> keep[f] ? length(polygons[f]) - 2 : 0, eachindex(polygons); init = 0)
	ti = Vector{Int}(undef, triangle_count)
	tj = similar(ti)
	tk = similar(ti)
	intensity = face_values === nothing ? nothing : Vector{Float64}(undef, triangle_count)
	t = 0
	for (f, ids) in enumerate(polygons)
		keep[f] || continue
		for m in 2:(length(ids) - 1)
			t += 1
			# Fan triangulation from the first vertex (0-based for plotly);
			# assumes planar, roughly convex polygons.
			ti[t] = ids[1] - 1
			tj[t] = ids[m] - 1
			tk[t] = ids[m + 1] - 1
			intensity === nothing || (intensity[t] = Float64(face_values[f]))
		end
	end
	fields = Dict{Symbol, Any}(:x => x, :y => y, :z => z, :i => ti, :j => tj, :k => tk)
	spec = _S3ColorSpec()
	if intensity === nothing
		fields[:color] = uniform
	else
		spec = _s3_color_spec(intensity, who; values_key = :intensity,
			colorscale = colorscale === nothing ? "Viridis" : colorscale, crange, cmid, colornorm, levels,
			showscale, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis)
		merge!(fields, spec.trace)
		fields[:intensitymode] = "cell"
	end
	light === nothing || (fields[:lighting] = light)
	flat && (fields[:flatshading] = true)
	alpha < 1 && (fields[:opacity] = alpha)
	name = String(legend)
	isempty(name) || (fields[:name] = name; fields[:showlegend] = true)
	traces = GenericTrace[GenericTrace("mesh3d"; fields...)]
	if !isempty(line_color) && line_width > 0
		push!(traces, _mesh_edge_trace(x, y, z, polygons; color = line_color, width = line_width, who))
	end
	return traces, (spec,)
end

function plot_polygons3d end

function plot_polygons3d! end

for (positional, prepare) in (
	((:faces,), :(_s3_explicit_polygons(faces, who))),
	((:x, :y, :z, :faces), :(_s3_indexed_polygons(x, y, z, faces, who))),
)
	typed = positional == (:faces,) ? [:(faces::AbstractVector)] :
		[:(x::AbstractVector), :(y::AbstractVector), :(z::AbstractVector), :faces]
	@eval begin
		function plot_polygons3d(
			$(typed...),
			values = nothing;
			color = "",
			opacity::Real = 1,
			lighting = :flat,
			edgecolor = "black",
			edgewidth::Real = 1,
			legend::AbstractString = "",
			colorscale = nothing,
			crange = [0, 0],
			cmid = nothing,
			colornorm = :linear,
			levels = nothing,
			showscale::Union{Nothing, Bool} = nothing,
			colorbar_title::AbstractString = "",
			colorbar_title_side = :top,
			colorbar_ticks = nothing,
			colorbar_ticklabels = nothing,
			coloraxis = nothing,
			xrange = [0, 0],
			yrange = [0, 0],
			zrange = [0, 0],
			xlabel::AbstractString = "",
			ylabel::AbstractString = "",
			zlabel::AbstractString = "",
			aspectmode = "data",
			perspective::Bool = true,
			grid::Bool = true,
			showaxis::Bool = true,
			title::AbstractString = "",
			width::Real = 0,
			height::Real = 0,
			fontsize::Real = 0,
			view = nothing,
			show::Bool = false,
			kwargs...,
		)
			who = "plot_polygons3d"
			_s3_reject_kwargs(who, kwargs)
			opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
				aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
			px, py, pz, polygons = $prepare
			traces, specs = _s3_polygons3d_traces(nothing, px, py, pz, polygons, values; color, opacity,
				lighting, edgecolor, edgewidth, legend, colorscale, crange, cmid, colornorm, levels,
				showscale, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
			return _s3_construct(traces, specs, opts, who, show)
		end

		function plot_polygons3d!(
			fig,
			$(typed...),
			values = nothing;
			color = "",
			opacity::Real = 1,
			lighting = :flat,
			edgecolor = "black",
			edgewidth::Real = 1,
			legend::AbstractString = "",
			colorscale = nothing,
			crange = [0, 0],
			cmid = nothing,
			colornorm = :linear,
			levels = nothing,
			showscale::Union{Nothing, Bool} = nothing,
			colorbar_title::AbstractString = "",
			colorbar_title_side = :top,
			colorbar_ticks = nothing,
			colorbar_ticklabels = nothing,
			coloraxis = nothing,
			xrange = [0, 0],
			yrange = [0, 0],
			zrange = [0, 0],
			xlabel::AbstractString = "",
			ylabel::AbstractString = "",
			zlabel::AbstractString = "",
			aspectmode = nothing,
			perspective::Union{Nothing, Bool} = nothing,
			grid::Union{Nothing, Bool} = nothing,
			showaxis::Union{Nothing, Bool} = nothing,
			title::AbstractString = "",
			width::Real = 0,
			height::Real = 0,
			fontsize::Real = 0,
			view = nothing,
			kwargs...,
		)
			who = "plot_polygons3d!"
			_s3_reject_kwargs(who, kwargs)
			opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
				aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
			px, py, pz, polygons = $prepare
			traces, specs = _s3_polygons3d_traces(fig, px, py, pz, polygons, values; color, opacity,
				lighting, edgecolor, edgewidth, legend, colorscale, crange, cmid, colornorm, levels,
				showscale, colorbar_title, colorbar_title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who)
			return _s3_append!(fig, traces, specs, opts, who)
		end
	end
end

const _S3_POLYGONS3D_KEYWORDS_DOC = raw"""
- `color = ""`: one colour (String or Symbol) for every face when no `values`
  are given (`""`: the next colorway colour).
- `opacity::Real = 1`: in [0, 1].
- `lighting = :flat`: `:flat` (unshaded, like matplotlib), `:default`
  (plotly's shading) or a NamedTuple of plotly lighting fields.
- `edgecolor = "black"`: colour of the polygon boundaries (`""`: none). Only
  the polygon edges are drawn, not the triangulation diagonals, each edge once
  as an opaque line trace.
- `edgewidth::Real = 1`: width of the edges in px (0: none).
- `legend::AbstractString = ""`: legend name.
"""

const _S3_POLYGONS3D_HEAD_DOC = raw"""
`faces` is either a vector of k×3 coordinate matrices (one row per vertex,
k ≥ 3; vertices with identical coordinates are merged, so neighbouring faces
share their edges), or, with vertex vectors `x`, `y`, `z`, an nf×k matrix or a
vector of vectors of 1-based vertex indices. Polygons are fan-triangulated
from their first vertex, so they should be planar and convex. `values` (one
number per face) colours the faces through the colour keywords; a face whose
value is NaN (or ≤ 0 with `colornorm = :log` and an automatic `crange`) is
left unfilled, while its edges are still drawn.
"""

const _S3_POLYGONS3D_COLOUR_NOTE = "The colour keywords need `values`; `colorscale = nothing` uses \"Viridis\"."

const _S3_CUBE_EXAMPLE = raw"""
x = [0.0, 1, 1, 0, 0, 1, 1, 0]; y = [0.0, 0, 1, 1, 0, 0, 1, 1]; z = [0.0, 0, 0, 0, 1, 1, 1, 1]
faces = [1 2 3 4; 5 6 7 8; 1 2 6 5; 2 3 7 6; 3 4 8 7; 4 1 5 8]   # the unit cube, 1-based
"""

@doc _s3_doc(
	raw"""
		plot_polygons3d(faces, values = nothing; kwargs...) -> Plot
		plot_polygons3d(x, y, z, faces, values = nothing; kwargs...) -> Plot

	Filled 3-D polygons (matplotlib `Poly3DCollection`), such as the faces of a
	finite-element mesh coloured per face.
	""" * "\n" * _S3_POLYGONS3D_HEAD_DOC,
	_S3_POLYGONS3D_KEYWORDS_DOC;
	constructor = true,
	colour = true,
	colorscale_default = "nothing",
	colour_note = _S3_POLYGONS3D_COLOUR_NOTE,
	aspectmode = "\"data\"",
	example = _S3_CUBE_EXAMPLE * raw"""
	fig = plot_polygons3d(x, y, z, faces, 1.0:6.0; colorscale = "viridis", colorbar_title = "face")
	square = [0.0 0 2; 1 0 2; 1 1 2; 0 1 2]                          # one k×3 coordinate matrix
	plot_polygons3d!(fig, [square]; color = "orange", opacity = 0.5)
	""",
) plot_polygons3d

@doc _s3_doc(
	_s3_mutator_head(
		raw"""
			plot_polygons3d!(fig, faces, values = nothing; kwargs...)
			plot_polygons3d!(fig, x, y, z, faces, values = nothing; kwargs...)
		""",
		"filled 3-D polygons",
		"plot_polygons3d",
	) * "\n\n" * _S3_POLYGONS3D_HEAD_DOC,
	_S3_POLYGONS3D_KEYWORDS_DOC;
	constructor = false,
	colour = true,
	colorscale_default = "nothing",
	colour_note = _S3_POLYGONS3D_COLOUR_NOTE,
	example = _S3_CUBE_EXAMPLE * raw"""
	fig = plot_polygons3d(x, y, z, faces; color = "lightgray")
	plot_polygons3d!(fig, x, y, z .+ 1.5, faces, [1.0, 2, NaN, 4, 5, 6]; colorscale = "plasma")
	""",
) plot_polygons3d!

#endregion

#region Wireframes and 3-D segments

# Line positions along one grid dimension: every `stride`-th index plus the
# last one (matplotlib `plot_wireframe`); stride 0 draws none.
function _s3_stride_lines(count::Int, stride::Int)
	stride == 0 && return Int[]
	lines = collect(1:stride:count)
	last(lines) == count || push!(lines, count)
	return lines
end

_s3_grid_value(grid, i::Int, j::Int, along::Int) =
	ndims(grid) == 1 ? grid[firstindex(grid) + (along == 1 ? i : j) - 1] :
	grid[firstindex(grid, 1) + i - 1, firstindex(grid, 2) + j - 1]

function _s3_wire_point!(sx, sy, sz, t::Int, X, Y, Z, i::Int, j::Int)
	sx[t] = _s3_gap_value(_s3_grid_value(X, i, j, 1))
	sy[t] = _s3_gap_value(_s3_grid_value(Y, i, j, 2))
	sz[t] = _s3_gap_value(Z[firstindex(Z, 1) + i - 1, firstindex(Z, 2) + j - 1])
	return nothing
end

function _s3_wireframe_trace(fig, X, Y, Z; rstride, cstride, color, linewidth, dash, opacity, legend, who::AbstractString)
	X, Y, Z = _s3_surface_grid(X, Y, Z, who)
	for (name, values) in (("X", X), ("Y", Y), ("Z", Z))
		_s3_real_elements(values, who, name)
	end
	for (name, stride) in (("rstride", rstride), ("cstride", cstride))
		(stride isa Integer && !(stride isa Bool) && stride >= 0) || throw(ArgumentError(
			"$(who): `$(name)` must be an integer >= 0; got $(repr(stride)).",
		))
	end
	(rstride == 0 && cstride == 0) && throw(ArgumentError(
		"$(who): `rstride` and `cstride` cannot both be 0 (nothing would be drawn).",
	))
	line = _s3_line_style(color, linewidth, dash, opacity, fig, :scene, who; default_color = "black")
	m, n = size(Z)
	rows = _s3_stride_lines(m, Int(rstride))
	cols = _s3_stride_lines(n, Int(cstride))
	total = length(rows) * (n + 1) + length(cols) * (m + 1)
	sx = Vector{Union{Nothing, Float64}}(undef, total)
	sy = similar(sx)
	sz = similar(sx)
	t = 0
	for i in rows
		for j in 1:n
			t += 1
			_s3_wire_point!(sx, sy, sz, t, X, Y, Z, i, j)
		end
		t += 1
		sx[t] = sy[t] = sz[t] = _GAP
	end
	for j in cols
		for i in 1:m
			t += 1
			_s3_wire_point!(sx, sy, sz, t, X, Y, Z, i, j)
		end
		t += 1
		sx[t] = sy[t] = sz[t] = _GAP
	end
	name = String(legend)
	return GenericTrace(
		"scatter3d";
		x = sx, y = sy, z = sz,
		mode = "lines",
		line = line,
		name = name,
		showlegend = !isempty(name),
	)
end

function plot_wireframe(
	X::AbstractArray,
	Y::AbstractArray,
	Z::AbstractArray;
	rstride::Integer = 1,
	cstride::Integer = 1,
	color = "black",
	linewidth::Union{Nothing, Real} = nothing,
	dash = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = "auto",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_wireframe"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	trace = _s3_wireframe_trace(nothing, X, Y, Z; rstride, cstride, color, linewidth, dash, opacity, legend, who)
	return _s3_construct(GenericTrace[trace], (), opts, who, show; style = _s3_collection_style(linewidth))
end

function plot_wireframe!(
	fig,
	X::AbstractArray,
	Y::AbstractArray,
	Z::AbstractArray;
	rstride::Integer = 1,
	cstride::Integer = 1,
	color = "black",
	linewidth::Union{Nothing, Real} = nothing,
	dash = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	zlabel::AbstractString = "",
	aspectmode = nothing,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	view = nothing,
	kwargs...,
)
	who = "plot_wireframe!"
	_s3_reject_kwargs(who, kwargs)
	opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
		aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
	trace = _s3_wireframe_trace(fig, X, Y, Z; rstride, cstride, color, linewidth, dash, opacity, legend, who)
	return _s3_append!(fig, GenericTrace[trace], (), opts, who; style = _s3_collection_style(linewidth))
end

function _s3_pair_segments(x0, y0, z0, x1, y1, z1, who::AbstractString)
	for (name, values) in (("x0", x0), ("y0", y0), ("z0", z0), ("x1", x1), ("y1", y1), ("z1", z1))
		_s3_array(values, who, name)
		_s3_real_elements(values, who, name)
	end
	n = _s3_check_lengths(who, "x0" => x0, "y0" => y0, "z0" => z0, "x1" => x1, "y1" => y1, "z1" => z1)
	return vcat(vec(x0), vec(x1)), vcat(vec(y0), vec(y1)), vcat(vec(z0), vec(z1)), [(m, n + m) for m in 1:n]
end

function _s3_indexed_segments(x, y, z, edges, who::AbstractString)
	for (name, values) in (("x", x), ("y", y), ("z", z))
		_s3_array(values, who, name)
		_s3_real_elements(values, who, name)
	end
	n = _s3_check_lengths(who, "x" => x, "y" => y, "z" => z)
	size(edges, 2) == 2 || throw(ArgumentError(
		"$(who): `edges` must be an ne×2 matrix of 1-based vertex indices; got $(join(size(edges), "×")).",
	))
	pairs = Vector{Tuple{Int, Int}}(undef, size(edges, 1))
	for (m, r) in enumerate(axes(edges, 1))
		a, b = edges[r, firstindex(edges, 2)], edges[r, firstindex(edges, 2) + 1]
		for index in (a, b)
			(!(index isa Bool) && 1 <= index <= n) || throw(ArgumentError(
				"$(who): edge $(m) has vertex index $(repr(index)); indices are 1-based and must lie in 1:$(n).",
			))
		end
		pairs[m] = (Int(a), Int(b))
	end
	return _s3_flat(x), _s3_flat(y), _s3_flat(z), pairs
end

function plot_segments3d end

function plot_segments3d! end

for (typed, prepare) in (
	(
		[:(x0::AbstractArray), :(y0::AbstractArray), :(z0::AbstractArray),
			:(x1::AbstractArray), :(y1::AbstractArray), :(z1::AbstractArray)],
		:(_s3_pair_segments(x0, y0, z0, x1, y1, z1, who)),
	),
	(
		[:(x::AbstractArray), :(y::AbstractArray), :(z::AbstractArray), :(edges::AbstractMatrix{<:Integer})],
		:(_s3_indexed_segments(x, y, z, edges, who)),
	),
)
	@eval begin
		function plot_segments3d(
			$(typed...);
			color = "#999999",
			linewidth::Union{Nothing, Real} = nothing,
			dash = "",
			opacity::Real = 1,
			legend::AbstractString = "",
			xrange = [0, 0],
			yrange = [0, 0],
			zrange = [0, 0],
			xlabel::AbstractString = "",
			ylabel::AbstractString = "",
			zlabel::AbstractString = "",
			aspectmode = "auto",
			perspective::Bool = true,
			grid::Bool = true,
			showaxis::Bool = true,
			title::AbstractString = "",
			width::Real = 0,
			height::Real = 0,
			fontsize::Real = 0,
			view = nothing,
			show::Bool = false,
			kwargs...,
		)
			who = "plot_segments3d"
			_s3_reject_kwargs(who, kwargs)
			opts = _s3_constructor_options(who; xrange, yrange, zrange, xlabel, ylabel, zlabel,
				aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
			px, py, pz, pairs = $prepare
			line = _s3_line_style(color, linewidth, dash, opacity, nothing, :scene, who; default_color = "#999999")
			trace = _s3_segment_trace(px, py, pz, pairs; line, legend)
			return _s3_construct(GenericTrace[trace], (), opts, who, show; style = _s3_collection_style(linewidth))
		end

		function plot_segments3d!(
			fig,
			$(typed...);
			color = "#999999",
			linewidth::Union{Nothing, Real} = nothing,
			dash = "",
			opacity::Real = 1,
			legend::AbstractString = "",
			xrange = [0, 0],
			yrange = [0, 0],
			zrange = [0, 0],
			xlabel::AbstractString = "",
			ylabel::AbstractString = "",
			zlabel::AbstractString = "",
			aspectmode = nothing,
			perspective::Union{Nothing, Bool} = nothing,
			grid::Union{Nothing, Bool} = nothing,
			showaxis::Union{Nothing, Bool} = nothing,
			title::AbstractString = "",
			width::Real = 0,
			height::Real = 0,
			fontsize::Real = 0,
			view = nothing,
			kwargs...,
		)
			who = "plot_segments3d!"
			_s3_reject_kwargs(who, kwargs)
			opts = _s3_options(who, fig; xrange, yrange, zrange, xlabel, ylabel, zlabel,
				aspectmode, perspective, grid, showaxis, title, width, height, fontsize, view)
			px, py, pz, pairs = $prepare
			line = _s3_line_style(color, linewidth, dash, opacity, fig, :scene, who; default_color = "#999999")
			trace = _s3_segment_trace(px, py, pz, pairs; line, legend)
			return _s3_append!(fig, GenericTrace[trace], (), opts, who; style = _s3_collection_style(linewidth))
		end
	end
end

const _S3_LINE_KEYWORDS_DOC = raw"""
- `linewidth = nothing`: line width in px: `nothing` takes the active
  `PlotStyle`'s line width, else 1; 0 gives plotly's default. (The style's
  dash and marker cycles do not apply to these line collections.)
- `dash = ""`: "solid", "dot", "dash", "longdash", "dashdot" or
  "longdashdot" (`""`: solid).
- `opacity::Real = 1`: in [0, 1]; """ * _S3_OPACITY_LINE_DOC * "\n" * raw"""
- `legend::AbstractString = ""`: legend name.
"""

const _S3_WIREFRAME_KEYWORDS_DOC = raw"""
- `rstride::Integer = 1`, `cstride::Integer = 1`: draw every `rstride`-th
  line of constant `i` and every `cstride`-th line of constant `j` (the last
  line is always drawn); 0 skips that direction.
- `color = "black"`: line colour (String or Symbol).
""" * _S3_LINE_KEYWORDS_DOC

const _S3_WIREFRAME_HEAD_DOC = raw"""
`X` and `Y` are vectors or matrices of the size of `Z`, as in
[`plot_surface`](@ref) (curvilinear grids work). All lines form one trace;
non-finite values leave gaps.
"""

@doc _s3_doc(
	raw"""
		plot_wireframe(X, Y, Z; kwargs...) -> Plot

	Grid lines of the surface `Z[i, j]` at `(X[i], Y[j])` (matplotlib
	`plot_wireframe`).
	""" * "\n" * _S3_WIREFRAME_HEAD_DOC,
	_S3_WIREFRAME_KEYWORDS_DOC;
	constructor = true,
	example = raw"""
	xs = range(-1, 1; length = 21)
	Z = [x^2 - y^2 for x in xs, y in xs]
	fig = plot_wireframe(xs, xs, Z; rstride = 2, cstride = 2, color = "steelblue")
	""",
) plot_wireframe

@doc _s3_doc(
	_s3_mutator_head(
		raw"""
			plot_wireframe!(fig, X, Y, Z; kwargs...)
		""",
		"a wireframe (for example the ghost of an undeformed mesh, with `opacity = 0.35`)",
		"plot_wireframe",
	) * "\n\n" * _S3_WIREFRAME_HEAD_DOC,
	_S3_WIREFRAME_KEYWORDS_DOC;
	constructor = false,
	example = raw"""
	xs = range(-1, 1; length = 11)
	Z = [x^2 - y^2 for x in xs, y in xs]
	fig = plot_surface(xs, xs, Z .+ 0.3; colorscale = "viridis")
	plot_wireframe!(fig, xs, xs, Z; opacity = 0.35, legend = "undeformed")
	""",
) plot_wireframe!

const _S3_SEGMENTS_KEYWORDS_DOC = raw"""
- `color = "#999999"`: line colour (String or Symbol).
""" * _S3_LINE_KEYWORDS_DOC

const _S3_SEGMENTS_HEAD_DOC = raw"""
The segments run from `(x0[k], y0[k], z0[k])` to `(x1[k], y1[k], z1[k])`, or
between the vertices `edges[m, 1]` and `edges[m, 2]` (1-based) of `x`, `y`,
`z`. All segments form one line trace; a non-finite end point leaves its
segment out.
"""

@doc _s3_doc(
	raw"""
		plot_segments3d(x0, y0, z0, x1, y1, z1; kwargs...) -> Plot
		plot_segments3d(x, y, z, edges; kwargs...) -> Plot

	Unconnected 3-D line segments (matplotlib `Line3DCollection`), such as mesh
	edges or a reference box.
	""" * "\n" * _S3_SEGMENTS_HEAD_DOC,
	_S3_SEGMENTS_KEYWORDS_DOC;
	constructor = true,
	example = raw"""
	x = [0.0, 1, 1, 0]; y = [0.0, 0, 1, 1]; z = zeros(4)
	fig = plot_segments3d(x, y, z, [1 2; 2 3; 3 4; 4 1]; color = "gray", dash = "dash")
	""",
) plot_segments3d

@doc _s3_doc(
	_s3_mutator_head(
		raw"""
			plot_segments3d!(fig, x0, y0, z0, x1, y1, z1; kwargs...)
			plot_segments3d!(fig, x, y, z, edges; kwargs...)
		""",
		"unconnected 3-D line segments",
		"plot_segments3d",
	) * "\n\n" * _S3_SEGMENTS_HEAD_DOC,
	_S3_SEGMENTS_KEYWORDS_DOC;
	constructor = false,
	example = raw"""
	fig = plot_surface(rand(5, 5))
	plot_segments3d!(fig, [0.0, 4.0], [0.0, 0.0], [0.0, 0.0], [0.0, 4.0], [4.0, 4.0], [1.0, 1.0];
	                 color = :black, linewidth = 3)
	""",
) plot_segments3d!

#endregion

#region SubplotFigure methods

# Run a 3-D mutator in a SubplotFigure cell. The delegate
# (`_subplot_delegate_mutator_impl!`) runs the mutator on an empty staging
# figure and routes its traces and scene settings to the cell; everything that
# needs the real cell is done here, on the whole staged figure, inside one
# transaction: the cell's aspect and automatic camera (`_s3_finish_scene!`,
# which depend on all of the cell's data and its domain), `view`, a colour
# axis other than "coloraxis" (the delegate only transplants the first one),
# `shared_coloraxis` (existing surfaces join the shared axis) and the colorbar
# title annotations the delegate cannot see. Ranges on a logarithmic cell
# scene are converted here because the staging figure cannot see the cell's
# axis types. The full staging copies the model graph, not the data payloads.
function _s3_subplot!(
	sf::SubplotFigure,
	mutator::Function,
	who::AbstractString,
	args...;
	row = nothing,
	col = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	haskey(kwargs, :show) && _s3_reject_kwargs(who, (show = kwargs[:show],))
	options = Dict{Symbol, Any}(kwargs)
	view_value = pop!(options, :view, nothing)
	view_angles = _s3_view(view_value, who)
	shared = get(options, :shared_coloraxis, false) === true
	axis_value = get(options, :coloraxis, nothing)
	extra_axis = axis_value === nothing ? nothing : _normalize_coloraxis(axis_value, who)
	extra_axis == "coloraxis" && (extra_axis = nothing)
	secondary_y && throw(ArgumentError(
		"$(who): a 3-D scene has no secondary y axis; drop `secondary_y = true`.",
	))
	target = _s3_scene_target(sf, who; row, col)
	current = _cmn_plot(sf)
	layout = current.layout
	for (key, axis) in ((:xrange, :xaxis), (:yrange, :yaxis), (:zrange, :zaxis))
		haskey(options, key) || continue
		checked = _s3_range(options[key], who, String(key))
		checked === nothing && continue
		options[key] = _s3_stored_range(layout, target.scenekey, axis, checked, who, String(key))
	end
	context = _S3CellContext(current, target.scenekey, length(current.data))
	# A plain colorbar title for a colour axis whose earlier math title is an
	# annotation: the staging figure cannot see that annotation, so it is
	# removed here.
	axis_id = shared ? "coloraxis" :
		axis_value === nothing ? nothing : _normalize_coloraxis(axis_value, who)
	title_value = get(options, :colorbar_title, "")
	retitle = axis_id !== nothing && title_value isa AbstractString && !isempty(title_value) &&
		!_cbar_is_math(_label(title_value))
	colorscale_given = !_is_unset_colorscale(get(options, :colorscale, ""))
	explicit_mode = get(options, :aspectmode, nothing) !== nothing
	impl = staged -> begin
		state = _s3_scene_state(staged, _s3_scene_target(staged, who; row, col))
		# An aspect mode given now replaces what was pinned automatically.
		explicit_mode && (state = _S3SceneState(false, state.auto_camera, state.auto_ticks))
		captured = Ref{Any}(nothing)
		wrapped = function (tmp, inner_args...; inner_kwargs...)
			result = mutator(tmp, inner_args...; inner_kwargs...)
			extra_axis === nothing ||
				(captured[] = get(_plot_layout(tmp).fields, Symbol(extra_axis), nothing))
			return result
		end
		# The style's dash/marker cycle continues over the whole figure (X10).
		_with_style_trace_offset(staged) do
			_subplot_delegate_mutator_impl!(staged, wrapped, args...; row, col, secondary_y, options...)
		end
		if extra_axis !== nothing
			fields = captured[] === nothing ? Dict{Symbol, Any}() : _symbol_dict(captured[])
			_s3_write_coloraxis!(staged, _S3ColorSpec(Dict{Symbol, Any}(), extra_axis, fields))
			# The delegate converted the math titles before this axis had its
			# colorbar settings.
			_colorbar_math_titles!(staged, (); coloraxes = (extra_axis,))
		end
		retitle && _cbar_remove_title_annotation!(_cmn_plot(staged), axis_id)
		shared && _s3_link_shared_surfaces!(_cmn_plot(staged), colorscale_given)
		cell = _s3_scene_target(staged, who)
		_s3_finish_scene!(staged, cell, state; frame = view_angles === nothing)
		if view_angles !== nothing
			params = _S3ViewParams(view_angles[1], view_angles[2], :auto, :z, nothing, 1.0)
			_s3_apply_view!(staged, cell, params)
		end
		_s3_finish_ticks!(staged, cell, state)
		_refresh!(getfield(staged, :fig))
		return staged
	end
	return Base.ScopedValues.with(_S3_CELL_CONTEXT => context) do
		_transactional_subplot_mutation!(impl, sf, _SUBPLOT_SELECTION_METADATA_FIELDS)
	end
end

plot_surface!(sf::SubplotFigure, X::AbstractArray, Y::AbstractArray, Z::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_surface!, "plot_surface!", X, Y, Z; kwargs...)
plot_surface!(sf::SubplotFigure, Z::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_surface!, "plot_surface!", Z; kwargs...)
plot_scatter3d!(sf::SubplotFigure, x::AbstractVector, y::AbstractVector, z::AbstractVector; kwargs...) =
	_s3_subplot!(sf, plot_scatter3d!, "plot_scatter3d!", x, y, z; kwargs...)
plot_quiver3d!(sf::SubplotFigure, x::AbstractArray, y::AbstractArray, z::AbstractArray,
	u::AbstractArray, v::AbstractArray, w::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_quiver3d!, "plot_quiver3d!", x, y, z, u, v, w; kwargs...)
plot_mesh3d!(sf::SubplotFigure, x::AbstractArray, y::AbstractArray, z::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_mesh3d!, "plot_mesh3d!", x, y, z; kwargs...)
plot_isosurface!(sf::SubplotFigure, x::AbstractArray, y::AbstractArray, z::AbstractArray, value::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_isosurface!, "plot_isosurface!", x, y, z, value; kwargs...)
plot_volume!(sf::SubplotFigure, x::AbstractArray, y::AbstractArray, z::AbstractArray, value::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_volume!, "plot_volume!", x, y, z, value; kwargs...)
plot_streamtube!(sf::SubplotFigure, x::AbstractArray, y::AbstractArray, z::AbstractArray,
	u::AbstractArray, v::AbstractArray, w::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_streamtube!, "plot_streamtube!", x, y, z, u, v, w; kwargs...)
plot_polygons3d!(sf::SubplotFigure, faces::AbstractVector, values = nothing; kwargs...) =
	_s3_subplot!(sf, plot_polygons3d!, "plot_polygons3d!", faces, values; kwargs...)
plot_polygons3d!(sf::SubplotFigure, x::AbstractVector, y::AbstractVector, z::AbstractVector, faces, values = nothing; kwargs...) =
	_s3_subplot!(sf, plot_polygons3d!, "plot_polygons3d!", x, y, z, faces, values; kwargs...)
plot_wireframe!(sf::SubplotFigure, X::AbstractArray, Y::AbstractArray, Z::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_wireframe!, "plot_wireframe!", X, Y, Z; kwargs...)
plot_segments3d!(sf::SubplotFigure, x0::AbstractArray, y0::AbstractArray, z0::AbstractArray,
	x1::AbstractArray, y1::AbstractArray, z1::AbstractArray; kwargs...) =
	_s3_subplot!(sf, plot_segments3d!, "plot_segments3d!", x0, y0, z0, x1, y1, z1; kwargs...)
plot_segments3d!(sf::SubplotFigure, x::AbstractArray, y::AbstractArray, z::AbstractArray,
	edges::AbstractMatrix{<:Integer}; kwargs...) =
	_s3_subplot!(sf, plot_segments3d!, "plot_segments3d!", x, y, z, edges; kwargs...)

#endregion
