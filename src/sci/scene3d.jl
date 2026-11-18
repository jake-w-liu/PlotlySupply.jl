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

# A colour keyword: "" (unset) or a colour, checked and converted by the
# package's colour-keyword parser `_color_option` (Z63). The user's spelling
# is kept so traces carry what was given, except where plotly.js would not
# read it: a matplotlib grey level ("0.35") and a Colors.jl `Colorant` are
# written as `_color_option` gives them ("#595959", or "rgba(…)" with an alpha
# channel). Surrounding blanks are dropped. A 3-D colour keyword names one
# colour, so a number (a colour-scale value to `_color_option`) is an error.
function _s3_color(value, who::AbstractString, name::AbstractString)
	(value isa AbstractString || value isa Symbol || value isa Colors.Colorant) || throw(ArgumentError(
		"$(who): `$(name)` must be a colour string, Symbol or Colors.jl Colorant; got $(typeof(value)).",
	))
	value isa Colors.Colorant || (value = String(strip(String(value))))
	return String(_color_option(value; who = who, name = name))
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
# A validated scene range keyword: `nothing` (automatic), two bounds, or a
# one-sided limit (D11) with `nothing` for the open end, which the 3-D calls
# resolve against the scene's data once it is in the figure
# (`_s3_resolve_range`).
function _s3_range(range, who::AbstractString, name::AbstractString)
	checked = _checked_range(range, who, name; partial = true)
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
# scene axis (bounds must be positive data values), unchanged otherwise. The
# open (`nothing`) end of a one-sided limit stays open.
function _s3_stored_range(layout, scenekey::Symbol, axiskey::Symbol, checked, who::AbstractString, name::AbstractString)
	checked === nothing && return nothing
	layout === nothing && return checked
	_s3_scene_axis_type(layout, scenekey, axiskey) == "log" || return checked
	for bound in checked
		bound === nothing && continue
		(_s3_is_real(bound) && bound > 0) || throw(ArgumentError(
			"$(who): `$(name)` bounds on a logarithmic scene axis are data values " *
			"and must be positive; got $(repr(checked)).",
		))
	end
	return Any[b === nothing ? nothing : log10(b) for b in checked]
end

# A stored scene range (`_s3_stored_range`) as written on scene `scenekey` of
# `fig`, whose data it applies to is already in the figure: a full range as
# it is, a one-sided limit as the full range `_axes_scene_limit_range` makes
# of it (the open end from the data, as `zrange!` does).
function _s3_resolve_range(fig, scenekey::Symbol, letter::Char, stored, who::AbstractString)
	(stored === nothing || !_is_one_sided_range(stored)) && return stored
	return _axes_scene_limit_range(fig, scenekey, letter, stored, who)
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
# an eye or with the eye and centre the scene's framing mark records for an
# automatic camera (`_s3_auto_camera`); `auto_ticks`, per axis, an `nticks`
# that is unset or equal to the count the mark records as written by
# PlotlySupply. A cube-shaped manual aspect is never taken as pinned (a user's
# (1, 1, 1) cannot be told apart).
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
	for (key, letter, label, range) in (
		(:xaxis, 'x', opts.xlabel, opts.xrange),
		(:yaxis, 'y', opts.ylabel, opts.yrange),
		(:zaxis, 'z', opts.zlabel, opts.zrange),
	)
		axis = Dict{Symbol, Any}()
		isempty(label) || (axis[:title] = attr(text = label))
		opts.grid === nothing || (axis[:showgrid] = opts.grid)
		opts.showaxis === nothing || (axis[:visible] = opts.showaxis)
		range = _s3_resolve_range(fig, scenekey, letter, range, who)
		range === nothing || (axis[:range] = range)
		isempty(axis) || (scene[key] = attr(; axis...))
	end
	isempty(scene) || _merge_scene_layout_attr!(_plot_layout(fig), scenekey, attr(; scene...))
	_apply_figure_size!(fig, who; width = opts.width, height = opts.height)
	# A legend first created by an append gets the box of the figure's own
	# template (dark on plotly_dark), as in the other families (X13).
	constructor ? _apply_default_template!(fig; fresh = true) :
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

const _S3_FRAMING_DOC = raw"""plotly.js sizes an "auto"/"data" scene by the extent of its data and ignores explicit axis ranges, so a scene with a range is written as `aspectmode = "manual"` with the proportions of the axis spans: equal units for "data", and for "auto" the same unless one span exceeds four times another (then a cube). Ratios pinned this way (other than a cube) are updated when later 3-D calls add data. A perspective scene without a camera gets plotly's default camera direction at the automatic distance of [`view!`](@ref), which fits the scene box with its tick labels and axis titles into its viewport (the figure size, else the style's default figure size, and the cell domain); later PlotlySupply calls and `savefig` keep such an automatic camera up to date. In a subplot cell, axes with automatic ticks get a tick count that suits the cell size, and scene tick labels are drawn at the requested font size (see [`view!`](@ref)). The framing also keeps the labels clear of each other: the offsets of tick labels and axis titles from the box (constants of plotly.js, which PlotlySupply's Plotly.js asset reads per scene from `layout.meta`) are pulled in as far as the labels stay apart; when the axis titles of a scene still cannot be kept apart, PlotlySupply draws them itself as paper annotations named `plotlysupply:scene3d:<scene>:title:<x|y|z>` along the projected axes (wrapped at a space or set smaller if need be; the scene's own title then holds a blank and its text is kept in the scene's `plotlysupply` record), and the end tick labels of two axes that meet at a box corner and overlap there are resolved by dropping one end tick of one axis (its tick values are written, recorded, and derived again after every change; ticks you place yourself are never touched). A user camera, `view!` with a `distance`, or a figure rendered by a Plotly.js without PlotlySupply's patch keeps plotly.js's own offsets and titles."""

const _S3_OPACITY_LINE_DOC = raw"""translucent scatter3d lines were observed to make other 3-D traces in the same scene vanish, so a line with `opacity < 1` or a colour with an alpha channel is drawn in the opaque colour it would have over the scene background (`paper_bgcolor` and `scene.bgcolor`, from the layout or the template). Over coloured faces this is an approximation."""

const _S3_COLOR_VALUES_DOC = raw"""Colour keywords take a CSS colour (`"red"`, `"#1f77b4"`, `"rgba(31,119,180,0.5)"`, `"#1f77b480"`) or a matplotlib grey level (`"0.35"`) as a String or Symbol, or a Colors.jl colour. Lines, edges, arrows and markers are always drawn opaque: """ * _S3_OPACITY_LINE_DOC

const _S3_OUTSIDE_RANGE_DOC = raw"""A scene draws only what lies inside its axis ranges. With a fixed range (`xrange`/`yrange`/`zrange`, [`scene!`](@ref)) plotly.js cuts lines and arrows at the faces of the box (an arrow that crosses a face loses its head) and hides markers, point labels and scene annotations outside it, where matplotlib would draw them beyond the axes. To show such content, widen the range to include it and keep the proportions of the box with `scene!(fig; aspectratio = …)`."""

function _s3_scene_doc(constructor::Bool, aspectmode::AbstractString)
	if constructor
		return """
		# Scene keywords

		- `xlabel::AbstractString = ""`, `ylabel::AbstractString = ""`,
		  `zlabel::AbstractString = ""`: axis titles (`""` gives "x", "y" and "z").
		  $(_S3_TEXT3D_DOC)
		- `xrange = [0, 0]`, `yrange = [0, 0]`, `zrange = [0, 0]`: axis ranges
		  `[lo, hi]` (vector or tuple) in data units; `[0, 0]` is automatic. A
		  one-sided limit such as `(0, nothing)` fixes one end; the other is
		  the data's end widened by 1/32 of its extent, as `zrange!` gives it.
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
	  `[lo, hi]` in data units, also on a logarithmic scene axis. A one-sided
	  limit such as `(0, nothing)` fixes one end; the other is the end of all
	  the scene's data (this call's included) widened by 1/32 of its extent,
	  as `zrange!` gives it.
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

# The layout a 3-D constructor gives its new figure before the call's own
# options: the active `PlotStyle`'s template and colorway (`_s3_construct`
# runs `_apply_default_template!`). Colours a constructor resolves before
# the figure exists (`fig === nothing`) are read from it.
function _s3_new_figure_layout()
	scratch = Plot(GenericTrace[], _s3_constructor_layout())
	_apply_default_template!(scratch; fresh = true)
	return scratch.layout
end

# Default colour of the `index`-th trace: from `fig`'s colorway/template, or
# from the layout a new figure gets when `fig` is `nothing` (constructors).
function _s3_default_color(fig, index::Integer)
	context = _S3_CELL_CONTEXT[]
	context === nothing || return _default_trace_color(context.plot, context.offset + index)
	return _default_trace_color(fig === nothing ? _s3_new_figure_layout() : fig, index)
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
		layout = _s3_new_figure_layout()
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

# Opaque line colour for `color` drawn at `opacity` over the scene background
# (ADDENDUM B2). plotly.js draws translucent 3-D lines and markers wrongly (a
# translucent scatter3d trace blanks other traces of the scene), so a colour
# with an alpha channel ("rgba(…)", "#RRGGBBAA", a Colorant with alpha) is
# blended the same way, its alpha times `opacity`. "" stays "" (unset).
function _s3_line_color(color::AbstractString, opacity::Float64, fig, scenekey::Symbol, who::AbstractString)
	isempty(color) && return color
	(opacity >= 1 && _parse_color(color, who)[4] >= 1) && return color
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
# The smallest share of the region the box is given when tick labels and axis
# titles do not fit around a larger one (their offsets are fixed in px, so a
# small cell needs a small box: a title cut off by the viewport is worse).
const _S3_FAR_FILL = 0.4
# plotly.js's default font size (layout.font.size).
const _S3_DEFAULT_FONT_SIZE = 12.0
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

# The figure size (px) scenes are framed for when it is not the layout's: the
# export size while `_s3_finalize_scenes!` frames an export copy.
const _S3_EXPORT_SIZE = Base.ScopedValues.ScopedValue{Union{Nothing, NTuple{2, Float64}}}(nothing)
# `(plot, area)` while `_s3_finalize_scenes!` frames `plot`: its
# `_s3_plot_area`, computed once per run (the run writes nothing it depends on).
const _S3_AREA = Base.ScopedValues.ScopedValue{Any}(nothing)
# Data extents (`_s3_data_bounds`) already scanned during one
# `_s3_finalize_scenes!` run, keyed by (objectid(plot), scene key, axis): the
# run does not change data, and the framing reads each extent many times.
const _S3_BOUNDS_CACHE = Base.ScopedValues.ScopedValue{Union{Nothing, Dict{Tuple{UInt, Symbol, Int}, Any}}}(nothing)

# Figure size and margins (px) the scenes of `p` are drawn with: the size of
# `_S3_EXPORT_SIZE`, else the layout's `width`/`height`, else the active
# style's default figure size (`_style_default_figure_size`, also savefig's
# default); the layout margins (plotly.js's defaults where unset) grown by
# plotly.js's auto-margin for the tick labels and titles of Cartesian axes on
# the paper edges (`_fin_margins`, the estimate `_finalize_figure!` uses) and
# for vertical colorbars right of the plot area
# (`_s3_colorbar_right_margin`). A live window auto-margins like an export.
function _s3_plot_area(p::Plot)
	cached = _S3_AREA[]
	cached !== nothing && cached[1] === p && return cached[2]
	fields = p.layout.fields
	size = _S3_EXPORT_SIZE[]
	if size === nothing
		default_width, default_height = _figure_default_size(p)
		size = (
			_s3_number_field(fields, :width, Float64(default_width); positive = true),
			_s3_number_field(fields, :height, Float64(default_height); positive = true),
		)
	end
	width, height = size
	margins = _fin_margins(p.layout, _fin_collect_axes(p), width, height, Dict{Symbol, Any}(), ())
	right = _s3_colorbar_right_margin(p, width, margins.l, margins.r)
	return (width = width, height = height, l = margins.l, r = right, t = margins.t, b = margins.b)
end

# Pixel size of the scene's viewport: the plot area (`_s3_plot_area`: figure
# size minus margins) times the scene's domain fractions.
function _s3_viewport(fig, target::_CellTarget)
	area = _s3_plot_area(_cmn_plot(fig))
	plot_width = max(area.width - area.l - area.r, 1.0)
	plot_height = max(area.height - area.t - area.b, 1.0)
	return (
		max(plot_width * (target.xdomain[2] - target.xdomain[1]), 1.0),
		max(plot_height * (target.ydomain[2] - target.ydomain[1]), 1.0),
	)
end

# plotly.js's automargin pad (px) around a pushing component.
const _S3_AUTOMARGIN_PAD = 12.0
# Gap (px) between a colorbar and its tick labels.
const _S3_CBAR_LABEL_GAP = 4.0

# Width (px) of a vertical colorbar's box as plotly.js's auto-margin sees it:
# 2 xpad + thickness + half the outline + outside tick marks + the gap and the
# longest tick label (`_S3_CHAR_EM` per character; the bar's own tick text or
# values, else the end labels of 4 to 10 linear ticks over `range`, 4
# characters when it is unknown), or a top or bottom title (plus 2 xpad) when
# that is wider. A
# right-side title adds 1.4 of its font size. `nothing` for a horizontal bar.
function _s3_colorbar_width(bar, range, font::Float64)
	fields = bar === nothing ? Dict{Symbol, Any}() : _symbol_dict(bar)
	_cbar_string(fields, :orientation, "v") == "v" || return nothing
	thickness = _cbar_string(fields, :thicknessmode, "pixels") == "pixels" ?
		_cbar_real(fields, :thickness, _CBAR_DEFAULT_THICKNESS) : _CBAR_DEFAULT_THICKNESS
	tickfont = _s3_number_field(get(fields, :tickfont, nothing), :size, font; positive = true)
	chars = if get(fields, :showticklabels, true) === false
		0
	else
		text = get(fields, :ticktext, nothing)
		values = get(fields, :tickvals, nothing)
		if (text isa AbstractVector || text isa Tuple) && !isempty(text)
			maximum(t -> _s3_visible_chars(string(t)), text)
		elseif (values isa AbstractVector || values isa Tuple) && !isempty(values)
			maximum(v -> length(string(v)), values)
		elseif range !== nothing && range[2] > range[1]
			_s3_linear_tick_chars(range[1], range[2], 4:10)
		else
			4
		end
	end
	marks = _cbar_string(fields, :ticks, "") == "outside" ? _cbar_real(fields, :ticklen, _S3_DEFAULT_TICKLEN) : 0.0
	width = 2 * _cbar_real(fields, :xpad, _CBAR_DEFAULT_XPAD) + thickness + _cbar_real(fields, :outlinewidth, 1.0) / 2 +
		marks + (chars > 0 ? _S3_CBAR_LABEL_GAP + chars * _S3_CHAR_EM * tickfont : 0.0)
	title = get(fields, :title, nothing)
	text = title isa AbstractString ? title : _cmn_mapping_get(title, :text)
	if text isa AbstractString && !isempty(text)
		title_size = _s3_number_field(title isa AbstractString ? nothing : _cmn_mapping_get(title, :font), :size, font; positive = true)
		side = title isa AbstractString ? nothing : _cmn_mapping_get(title, :side)
		if side == "right"
			width += 1.4 * title_size
		else
			width = max(width, _s3_visible_chars(text) * _S3_CHAR_EM * title_size + 2 * _cbar_real(fields, :xpad, _CBAR_DEFAULT_XPAD))
		end
	end
	return width
end

# Right margin (px) of a figure `W` px wide (left margin `left`, layout right
# margin `right`) once plotly.js's auto-margin has made room for its vertical
# paper-anchored colorbars (traces' own bars and those of the coloraxes the
# traces use): a bar at `x` (plotly's default 1.02, left-anchored) whose box is
# w px wide ends x·Wp + w px right of the left edge of the plot area, of width
# Wp = W - left - r, and plotly widens r until that is at most Wp + r - 12.
# Checked on a render: a 700x500 surface with a 0.1–1 colorbar is drawn with
# r ≈ 95 px; this estimate gives 97.7 px. Horizontal and container-anchored
# bars are not counted.
function _s3_colorbar_right_margin(p::Plot, W::Float64, left::Float64, right::Float64)
	font = _s3_number_field(_cmn_mapping_get(p.layout.fields, :font), :size, _S3_DEFAULT_FONT_SIZE; positive = true)
	bars = Tuple{Any, Any}[]
	axis_ranges = Dict{String, Any}()
	for (index, trace) in enumerate(p.data)
		slot = _cbar_slot(trace, index)
		slot === nothing && continue
		range = _cbar_slot_range(trace, slot)
		if slot.coloraxis !== nothing
			known = get(axis_ranges, slot.coloraxis, nothing)
			axis_ranges[slot.coloraxis] = known === nothing ? range :
				range === nothing ? known : (min(known[1], range[1]), max(known[2], range[2]))
		elseif slot.shows
			push!(bars, (_cbar_slot_bar(trace, slot), range))
		end
	end
	for (id, range) in axis_ranges
		axis = get(p.layout.fields, Symbol(id), nothing)
		_cmn_mapping_get(axis, :showscale) === false && continue
		lo, hi = _cmn_mapping_get(axis, :cmin), _cmn_mapping_get(axis, :cmax)
		(_s3_is_real(lo) && _s3_is_real(hi) && isfinite(lo) && isfinite(hi) && lo < hi) && (range = (Float64(lo), Float64(hi)))
		push!(bars, (_cmn_mapping_get(axis, :colorbar), range))
	end
	placed = Tuple{Float64, Float64, String}[]
	for (bar, range) in bars
		fields = bar === nothing ? Dict{Symbol, Any}() : _symbol_dict(bar)
		_cbar_string(fields, :xref, "paper") == "paper" || continue
		width = _s3_colorbar_width(bar, range, font)
		width === nothing && continue
		push!(placed, (_cbar_real(fields, :x, 1.02), width, _cbar_string(fields, :xanchor, "left")))
	end
	isempty(placed) && return right
	r = right
	# Each round moves r towards the fixed point by a factor |x - 1| < 1.
	for _ in 1:20
		plot_width = max(W - left - r, 1.0)
		need = right
		for (x, width, anchor) in placed
			start = x * plot_width - (anchor == "center" ? width / 2 : anchor == "right" ? width : 0.0)
			need = max(need, start + width + _S3_AUTOMARGIN_PAD - plot_width)
		end
		abs(need - r) <= 0.01 && return need
		r = need
	end
	return r
end

# The tick step plotly.js's automatic linear ticks use for `count` ticks over
# `span` (axes.autoTicks with Lib.roundUp, plotly.js 2.35.2): the power of ten
# b at or below span/count (floor of log(·)/LN10, as plotly computes it) times
# the first of 2, 5 and 10 strictly above span/count/b, so 2 gives 5 and 1
# gives 2.
function _s3_plotly_tick_step(span::Float64, count::Real)
	rough = span / count
	base = 10.0^floor(log(rough) / log(10.0))
	ratio = rough / base
	return base * (ratio < 2 ? 2.0 : ratio < 5 ? 5.0 : 10.0)
end

# Longest end label (characters) of the linear ticks plotly.js puts on
# [lo, hi] for each tick count in `counts` (`_s3_plotly_tick_step`).
function _s3_linear_tick_chars(lo::Float64, hi::Float64, counts)
	chars = 1
	for count in counts
		step = _s3_plotly_tick_step(hi - lo, count)
		first_tick = ceil(lo / step - 1e-9) * step
		last_tick = floor(hi / step + 1e-9) * step
		first_tick <= last_tick || continue
		chars = max(chars, _s3_tick_text_chars(first_tick, step), _s3_tick_text_chars(last_tick, step))
	end
	return chars
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
# Inside `_s3_finalize_scenes!` each extent is scanned once (`_S3_BOUNDS_CACHE`).
function _s3_data_bounds(p::Plot, scenekey::Symbol, d::Int)
	cache = _S3_BOUNDS_CACHE[]
	cache === nothing && return _s3_scan_bounds(p, scenekey, d)
	return get!(() -> _s3_scan_bounds(p, scenekey, d), cache, (objectid(p), scenekey, d))
end

function _s3_scan_bounds(p::Plot, scenekey::Symbol, d::Int)
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
	ratio = width / height
	frame = _s3_camera_frame(direction, up)
	if frame === nothing
		radius = 0.5 * sqrt(sum(abs2, box)) + _s3_norm(center)
		half_angle = atan(min(limit_x * ratio, limit_y) * tan(_S3_HALF_FOVY))
		return radius / sin(half_angle) / zoom
	end
	return _s3_box_distance(box, center, frame, ratio, limit_x, limit_y) / zoom
end

# Camera frame (v, r, u) of a view from `direction` (centre to eye, any
# length) with up vector `up`: the unit direction, screen right and screen
# up. `nothing` when `up` is parallel to `direction` (no defined roll).
function _s3_camera_frame(direction, up)
	# Tuples throughout: the framing search evaluates this frame hundreds of
	# times and a vector would allocate in every dot product.
	direction = (Float64(direction[1]), Float64(direction[2]), Float64(direction[3]))
	up = (Float64(up[1]), Float64(up[2]), Float64(up[3]))
	v = direction ./ _s3_norm(direction)
	right = _s3_cross(.-v, up)
	right_norm = _s3_norm(right)
	right_norm > 1e-9 * _s3_norm(up) || return nothing
	r = right ./ right_norm
	return (v, r, _s3_cross(r, .-v))
end

# Smallest distance from `center` at which a perspective camera with frame
# `frame` shows the box (side lengths `box`, centred on the origin) within
# `limit_x`/`limit_y` of the viewport's half-sizes (aspect `ratio` = w/h).
# Pinhole model: the corner at offset q from `center` lands at
# x = (q·r) / ((d - q·v) tan(fovy/2) w/h) and y = (q·u) / ((d - q·v) tan(fovy/2))
# in normalised device coordinates, so |x| ≤ limit_x and |y| ≤ limit_y bound d
# from below for every corner; the largest bound is the tightest distance.
function _s3_box_distance(box, center, frame, ratio::Float64, limit_x::Float64, limit_y::Float64)
	v, r, u = frame
	tan_half = tan(_S3_HALF_FOVY)
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
	return distance
end

# ── Tick labels and axis titles of an exported scene ─────────────────────────
#
# gl-axes (bundled plotly.js 2.35.2: `axes.draw`, `getCubeProperties` and the
# text shader) draws each axis's tick labels and title along one edge of the
# scene box, chosen from the view, and pushes them out of the box along the
# edge's minor direction: by the tick length of the axis it moves along when
# the axis draws tick marks, by `tickPad` = 18 more for the tick labels (when
# shown) and by `labelPad` = 30 more for the title, in units of
# 1/(2 tan(fovy/2)) ≈ 1.21 px at the depth of the scene centre. Text is
# centred on its anchor. A tick label runs along the screen direction of the
# axis it is pushed along (horizontal when it is pushed along two or none); a
# title whose raw text is longer than four characters runs along its own axis,
# a shorter one is horizontal. The viewport clips all of it.
# `_s3_export_distance` keeps it inside.
const _S3_GL_TICK_PAD = 18.0
const _S3_GL_LABEL_PAD = 30.0
# gl-axes's tick length of an axis without tick marks (plotly.js passes
# `ticklen` only with `ticks`), and plotly.js's `ticklen` default.
const _S3_GL_TICK_LENGTH = 10.0
const _S3_DEFAULT_TICKLEN = 5.0
# Advance of one label character in font sizes: digits of the sans-serif
# faces plotly.js falls back to are 0.556 em and rendered axis titles average
# 0.51-0.53 em (measured on 700x500 exports), so 0.56 bounds both; and the gl
# text line spacing in font sizes.
const _S3_CHAR_EM = 0.56
const _S3_LINE_EM = 1.25
# Free pixels kept between a label and the viewport edge.
const _S3_LABEL_MARGIN_PX = 2.0

# ── Label pads ───────────────────────────────────────────────────────────────
#
# gl-axes pushes tick labels out of the box by `tickPad` and axis titles by a
# further `labelPad` (module constants 18 and 30 in plotly.js 2.35.2, which no
# layout attribute reaches). The Plotly.js asset PlotlySupply renders with
# (`src/plotlyjs_compat_asset.jl`) reads them per scene from
# `layout.meta["plotlysupply:gl3d"][scene key] = [tickPad, labelPad]`, so a
# small scene can pull its labels in; a renderer without that patch (a plain
# PlotlyBase display) ignores the record and draws the constants. The model
# reads the same record (the constants without it).
const _S3_PADS_KEY = Symbol("plotlysupply:gl3d")
const _S3_GL_DEFAULT_PADS = (_S3_GL_TICK_PAD, _S3_GL_LABEL_PAD)

function _s3_pads_record(layout::Layout)
	meta = get(layout.fields, :meta, nothing)
	meta isa AbstractDict || meta isa PlotlyBase.PlotlyAttribute || return nothing
	record = _cmn_mapping_get(meta, _S3_PADS_KEY)
	return record isa AbstractDict ? record : nothing
end

# The (tickPad, labelPad) pair, in gl-axes units, recorded for scene `key`;
# gl-axes's constants without a valid record.
function _s3_scene_pads(p::Plot, key::Symbol)
	record = _s3_pads_record(p.layout)
	record === nothing && return _S3_GL_DEFAULT_PADS
	raw = _cmn_mapping_get(record, key)
	((raw isa AbstractVector || raw isa Tuple) && length(raw) == 2 &&
		all(v -> _s3_is_real(v) && isfinite(v) && v >= 0, raw)) || return _S3_GL_DEFAULT_PADS
	return (Float64(raw[1]), Float64(raw[2]))
end

# Record `pads` for scene `key` in `layout.meta` (only this key of `meta`; a
# `meta` that is not a mapping is the user's and is left alone). The default
# constants are recorded by removing the entry. Returns whether the layout
# changed.
function _s3_write_pads!(layout::Layout, key::Symbol, pads::NTuple{2, Float64})
	meta = get(layout.fields, :meta, nothing)
	holder = meta isa PlotlyBase.PlotlyAttribute ? meta.fields : meta
	(holder === nothing || holder isa AbstractDict) || return false
	record = _s3_pads_record(layout)
	current = record === nothing ? nothing : _cmn_mapping_get(record, key)
	if pads == _S3_GL_DEFAULT_PADS
		current === nothing && return false
		_cmn_mapping_delete!(record, (key,))
		if isempty(record)
			delete!(holder, _S3_PADS_KEY)
			isempty(holder) && delete!(layout.fields, :meta)
		end
		return true
	end
	same = (current isa AbstractVector || current isa Tuple) && length(current) == 2 &&
		all(i -> _s3_is_real(current[i]) && current[i] == pads[i], 1:2)
	same && return false
	if holder === nothing
		holder = Dict{Any, Any}()
		layout.fields[:meta] = holder
	end
	record === nothing && (record = Dict{Any, Any}(); holder[_S3_PADS_KEY] = record)
	record[key] = Float64[pads[1], pads[2]]
	return true
end

# The labels gl-axes draws for one scene axis. `ticklen` is the tick length
# gl-axes uses when another axis's labels are pushed along this one;
# `tick_lo`/`tick_hi` are the outermost labelled ticks as fractions of the
# box edge.
struct _S3AxisLabels
	visible::Bool
	marks::Bool
	ticklen::Float64
	ticks_shown::Bool
	tick_size::Float64
	tick_chars::Int
	tick_lo::Float64
	tick_hi::Float64
	title_size::Float64
	title_chars::Int
	title_lines::Int
	title_along::Bool
	tick_pad::Float64
	label_pad::Float64
	title_text::String
	title_own::Bool
end

# Characters a label shows: HTML tags (<b>, <sub>, ...) count as nothing, an
# entity as one character.
_s3_visible_chars(text::AbstractString) =
	length(replace(replace(text, r"<[^>]*>" => ""), r"&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);" => "x"))

# JavaScript string length (UTF-16 code units), which gl-axes compares with 4.
_s3_js_length(text::AbstractString) =
	# `c::Char`: an untyped closure compiles `isvalid(::Any)`, which loading ElectronCall
	# (it brings URIs.isvalid(::URI)) invalidates together with everything above it
	# (the second export of a session recompiled for 0.7 s).
	sum((c::Char) -> (isvalid(c) && codepoint(c) > 0xFFFF) ? 2 : 1, text; init = 0)

# Characters of plotly.js's tick label for `value` on a linear axis with tick
# step `step`: sign, integer digits and as many decimals as the step needs (an
# upper bound: plotly drops trailing zeros). The default exponentformat "B"
# writes values from 10⁴ and steps below 10⁻³ with an SI suffix ("10k",
# "100μ"): four characters and the sign.
function _s3_tick_text_chars(value::Float64, step::Float64)
	decimals = max(-floor(Int, log10(step) + 1e-9), 0)
	magnitude = abs(value)
	(magnitude >= 1e4 || decimals > 3) && return 4 + (value < 0)
	digits = magnitude >= 1 ? floor(Int, log10(magnitude)) + 1 : 1
	return (value < 0) + digits + (decimals > 0 ? decimals + 1 : 0)
end

# Longest category label of scene axis `d`: the string values of the scene's
# traces (at least one character).
function _s3_category_chars(p::Plot, scenekey::Symbol, d::Int)
	coordinate = (:x, :y, :z)[d]
	id = String(scenekey)
	chars = 1
	for trace in p.data
		_s3_trace_in_scene(trace, id) || continue
		values = get(trace.fields, coordinate, nothing)
		values isa AbstractArray || continue
		for value in values
			value isa AbstractString && (chars = max(chars, _s3_visible_chars(value)))
		end
	end
	return chars
end

# The range plotly.js gives scene axis `d` (`fields` its layout entry): the
# explicit one, else its autorange (the data extent padded by 1/32 of it on
# each side, ±1 around a single value, reversed for `autorange =
# "reversed"`); `nothing` without numeric data.
function _s3_axis_range(p::Plot, scenekey::Symbol, d::Int, fields)
	range = _s3_explicit_range(fields)
	range === nothing || return range
	bounds = _s3_data_bounds(p, scenekey, d)
	bounds === nothing && return nothing
	pad = (bounds[2] - bounds[1]) / 32
	range = bounds[2] > bounds[1] ? (bounds[1] - pad, bounds[2] + pad) : (bounds[1] - 1.0, bounds[1] + 1.0)
	_cmn_mapping_get(fields, :autorange) == "reversed" && (range = (range[2], range[1]))
	return range
end

# The tick labels plotly.js draws on scene axis `d` (`fields` its layout
# entry): the outermost labelled ticks as fractions of the box edge, and the
# longest label in characters. The axis range is `_s3_axis_range`. User tick
# values (and their tick text) are taken as given. On a linear axis the ticks
# are the multiples of the step (from `tick0`) inside the range: the user's
# `dtick`, else `_s3_plotly_tick_step` for each tick count plotly.js may use
# (`nticks`, else 4 to 9). Log, date and category axes are taken to have ticks
# at both ends, five ("0.001", "100k"), eleven ("Jan 1, 2024") and the longest
# category's characters long. A reversed axis counts both of its mirror
# placements. (0.5, 0.5, 0) when no tick is labelled.
function _s3_tick_extent(p::Plot, scenekey::Symbol, d::Int, fields)
	axis_type = _cmn_mapping_get(fields, :type)
	log_axis = axis_type == "log"
	range = _s3_axis_range(p, scenekey, d, fields)
	function result(first, last, chars)
		chars > 0 || return (0.5, 0.5, 0)
		(range !== nothing && range[1] > range[2]) || return (first, last, chars)
		return (min(first, 1 - last), max(last, 1 - first), chars)
	end
	values = _cmn_mapping_get(fields, :tickvals)
	if (values isa AbstractVector || values isa Tuple) && !isempty(values)
		text = _cmn_mapping_get(fields, :ticktext)
		chars = (text isa AbstractVector || text isa Tuple) && !isempty(text) ?
			maximum(t -> _s3_visible_chars(string(t)), text) : maximum(v -> length(string(v)), values)
		range === nothing && return result(0.0, 1.0, chars)
		first, last = Inf, -Inf
		for value in values
			(_s3_is_real(value) && isfinite(value)) || continue
			x = Float64(value)
			if log_axis
				x > 0 || continue
				x = log10(x)
			end
			f = (x - range[1]) / (range[2] - range[1])
			-1e-9 <= f <= 1 + 1e-9 || continue
			first, last = min(first, f), max(last, f)
		end
		return first <= last ? result(first, last, chars) : (0.5, 0.5, 0)
	end
	log_axis && return result(0.0, 1.0, 5)
	axis_type == "date" && return result(0.0, 1.0, 11)
	(range === nothing || axis_type == "category") && return result(0.0, 1.0, _s3_category_chars(p, scenekey, d))
	lo, hi = minmax(range[1], range[2])
	span = hi - lo
	dtick = _cmn_mapping_get(fields, :dtick)
	steps = if _s3_is_real(dtick) && isfinite(dtick) && dtick > 0
		Float64[dtick]
	else
		nticks = _cmn_mapping_get(fields, :nticks)
		counts = (_s3_is_real(nticks) && isinteger(nticks) && nticks >= 1) ? (Int(nticks):Int(nticks)) :
			(_S3_MIN_PLOTLY_TICKS:_S3_MAX_AUTO_TICKS)
		map(count -> _s3_plotly_tick_step(span, count), counts)
	end
	tick0 = _cmn_mapping_get(fields, :tick0)
	origin = (_s3_is_real(tick0) && isfinite(tick0)) ? Float64(tick0) : 0.0
	first, last, chars = Inf, -Inf, 0
	for step in steps
		first_tick = origin + ceil((lo - origin) / step - 1e-9) * step
		last_tick = origin + floor((hi - origin) / step + 1e-9) * step
		first_tick <= last_tick || continue
		chars = max(chars, _s3_tick_text_chars(first_tick, step), _s3_tick_text_chars(last_tick, step))
		a = (first_tick - range[1]) / (range[2] - range[1])
		b = (last_tick - range[1]) / (range[2] - range[1])
		first, last = min(first, a, b), max(last, a, b)
	end
	return first <= last ? result(clamp(first, 0.0, 1.0), clamp(last, 0.0, 1.0), chars) : (0.5, 0.5, 0)
end

# Drawn size (px) of a gl-axes tick label with font size `size`: gl-axes
# scales the glyphs of a tick by its `fontSize`/12 and again by `tickSize`, and
# plotly.js sets both to `tickfont.size`, so a 24 px tick font draws 48 px
# labels (checked by render).
const _S3_GL_TEXT_REFERENCE_SIZE = 12.0
_s3_tick_text_size(size::Float64) = size * size / _S3_GL_TEXT_REFERENCE_SIZE

# The text axis `d` of `scene` (a layout entry) is titled with, and whether
# PlotlySupply draws it: its layout title, or, where the title is
# `_S3_TITLE_HIDDEN` because PlotlySupply draws it as an annotation
# (`_s3_apply_titles!`), the text its mark kept.
function _s3_title_source(scene, d::Int)
	fields = _cmn_mapping_get(scene, (:xaxis, :yaxis, :zaxis)[d])
	title = _cmn_mapping_get(fields, :title)
	raw = title isa AbstractString ? title : _cmn_mapping_get(title, :text)
	mark = _s3_mark(scene)
	(mark !== nothing && raw == _S3_TITLE_HIDDEN && !isempty(mark.titles[d])) && return mark.titles[d], true
	return raw, false
end

# The labels of the three axes of scene `scenekey` as plotly.js lays them out:
# an untitled axis is titled with its letter, a title's font size defaults to
# round(1.2 × layout.font.size) and a tick font's to layout.font.size (12).
function _s3_axis_labels(p::Plot, scenekey::Symbol; pads = _s3_scene_pads(p, scenekey), tick_override = nothing)
	font = _s3_number_field(_cmn_mapping_get(p.layout.fields, :font), :size, _S3_DEFAULT_FONT_SIZE; positive = true)
	scene = get(p.layout.fields, scenekey, nothing)
	return ntuple(3) do d
		fields = _cmn_mapping_get(scene, (:xaxis, :yaxis, :zaxis)[d])
		visible = _cmn_mapping_get(fields, :visible) !== false
		ticks = _cmn_mapping_get(fields, :ticks)
		marks = visible && ticks isa Union{AbstractString, Symbol} && String(ticks) in ("outside", "inside")
		ticklen = marks ? _s3_number_field(fields, :ticklen, _S3_DEFAULT_TICKLEN) : _S3_GL_TICK_LENGTH
		shown = visible && _cmn_mapping_get(fields, :showticklabels) !== false
		tick_size = _s3_number_field(_cmn_mapping_get(fields, :tickfont), :size, font; positive = true)
		title = _cmn_mapping_get(fields, :title)
		raw, own_title = _s3_title_source(scene, d)
		text = raw === nothing ? string("xyz"[d]) : string(raw)
		title_font = title isa AbstractString ? nothing : _cmn_mapping_get(title, :font)
		title_size = _s3_number_field(title_font, :size, round(1.2 * font); positive = true)
		lines = split(replace(text, r"<br\s*/?>"i => "\n"), '\n')
		tick_lo, tick_hi, tick_chars = !shown ? (0.5, 0.5, 0) : (tick_override !== nothing && haskey(tick_override, d)) ? tick_override[d] :
			_s3_tick_extent(p, scenekey, d, fields)
		_S3AxisLabels(
			visible,
			marks,
			ticklen,
			shown,
			_s3_tick_text_size(tick_size),
			tick_chars,
			tick_lo,
			tick_hi,
			title_size,
			visible ? maximum(_s3_visible_chars, lines) : 0,
			length(lines),
			_s3_js_length(text) > 4,
			pads[1],
			pads[2],
			text,
			own_title,
		)
	end
end

# Box corner `index` (0–7; bit d - 1 set: the high end of axis d) of a box
# with side lengths `box` centred on the origin (gl-axes's corner order).
_s3_corner(box, index::Int) = ntuple(d -> (index >> (d - 1)) & 1 == 1 ? box[d] / 2 : -box[d] / 2, 3)

# gl-axes `getCubeProperties` for a camera at `eye` in front of the whole box
# (side lengths `box`, centred on the origin; `project` maps a point to screen
# coordinates): per axis, the corner bits (of the other two axes) of the box
# edge its labels are drawn along, and the axis sign, -1 where the corner
# nearest the eye is at the axis's high end. For each axis the front corner
# is on the face the eye is outside of, and when the eye is level with both
# faces on the one that projects larger; the label edges hang off the lowest
# screen corner other than the front and back corners.
function _s3_cube_edges(box, eye, project)
	front = 0
	for a in 1:3
		if -box[a] / 2 <= eye[a] <= box[a] / 2
			m, s = mod1(a + 2, 3), mod1(a + 1, 3)
			function face_area(level)
				z = level << (a - 1)
				pts = map(i -> project(_s3_corner(box, i)), (z, z + (1 << (s - 1)), z + (1 << (m - 1)), z + (1 << (m - 1)) + (1 << (s - 1))))
				tri(p1, p2, p3) = abs((p2[1] - p1[1]) * (p3[2] - p1[2]) - (p2[2] - p1[2]) * (p3[1] - p1[1]))
				return tri(pts[1], pts[2], pts[3]) + tri(pts[1], pts[3], pts[4])
			end
			face_area(0) > face_area(1) && (front |= 1 << (a - 1))
		elseif eye[a] > box[a] / 2
			front |= 1 << (a - 1)
		end
	end
	back = 7 ⊻ front
	screen = [project(_s3_corner(box, i)) for i in 0:7]
	lowest = -1
	for i in 0:7
		(i == front || i == back) && continue
		(lowest < 0 || screen[lowest + 1][2] > screen[i + 1][2]) && (lowest = i)
	end
	left = -1
	for a in 0:2
		n = lowest ⊻ (1 << a)
		(n == front || n == back) && continue
		left < 0 && (left = n)
		screen[n + 1][1] < screen[left + 1][1] && (left = n)
	end
	right = -1
	for a in 0:2
		n = lowest ⊻ (1 << a)
		(n == front || n == back || n == left) && continue
		right < 0 && (right = n)
		screen[n + 1][1] > screen[right + 1][1] && (right = n)
	end
	edges = zeros(Int, 3)
	axis_of(bit) = trailing_zeros(bit) + 1
	edges[axis_of(left ⊻ lowest)] = lowest & left
	edges[axis_of(lowest ⊻ right)] = lowest & right
	other = 7 ⊻ right
	if other == front || other == back
		other = 7 ⊻ left
		edges[axis_of(right ⊻ other)] = other & right
	else
		edges[axis_of(left ⊻ other)] = other & left
	end
	return edges, ntuple(a -> (front >> (a - 1)) & 1 == 1 ? -1 : 1, 3)
end

# A text rectangle as its four corners: centred on screen point `at`, running
# along the unit screen direction `along` for 2 `half_len` and across it for
# 2 `half_thick`.
function _s3_text_quad(at, along, half_len::Float64, half_thick::Float64)
	(dx, dy), (nx, ny) = along, (-along[2], along[1])
	return ntuple(4) do k
		sl = k in (1, 4) ? -half_len : half_len
		st = k <= 2 ? -half_thick : half_thick
		(at[1] + sl * dx + st * nx, at[2] + sl * dy + st * ny)
	end
end

# Whether two convex quadrilaterals (four corners each) overlap by more than
# `tolerance` px along every separating axis candidate (separating-axis test).
function _s3_quads_intersect(a, b; tolerance::Float64 = 0.0)
	for quad in (a, b), k in 1:4
		p, q = quad[k], quad[mod1(k + 1, 4)]
		nx, ny = p[2] - q[2], q[1] - p[1]
		lo_a, hi_a, lo_b, hi_b = Inf, -Inf, Inf, -Inf
		for point in a
			t = point[1] * nx + point[2] * ny
			lo_a, hi_a = min(lo_a, t), max(hi_a, t)
		end
		for point in b
			t = point[1] * nx + point[2] * ny
			lo_b, hi_b = min(lo_b, t), max(hi_b, t)
		end
		scale = hypot(nx, ny)
		scale > 0 || continue
		(hi_a - lo_b <= tolerance * scale || hi_b - lo_a <= tolerance * scale) && return false
	end
	return true
end

# What plotly.js draws of the scene seen from center + distance·v (camera
# frame `frame` = (v, r, u)) in a `width`×`height` px viewport, in px from the
# viewport centre with y up: the eight box corners, and per drawn axis the
# rectangles of its outermost tick labels and of its title. `spans` are the
# axis spans in data units (a tick label runs along the screen direction
# gl-axes measures for one data unit), or `nothing`.
function _s3_label_layout(box, center, frame, distance::Float64, width::Float64, height::Float64, labels, spans)
	corners, quads, _ = _s3_label_layout_tagged(box, center, frame, distance, width, height, labels, spans)
	return corners, quads
end

# `_s3_label_layout` with, per rectangle, the axis (1-3) and kind (`:tick` or
# `:title`) it belongs to.
function _s3_label_layout_tagged(box, center, frame, distance::Float64, width::Float64, height::Float64, labels, spans; own = nothing)
	own === nothing && (own = any(label -> label.title_own, labels))
	v, r, u = frame
	eye = center .+ distance .* v
	tan_half = tan(_S3_HALF_FOVY)
	ratio = width / height
	# The shader divides by max(w, 1e-4) (w: depth in front of the eye).
	function project(point, min_depth::Float64 = 1e-9)
		q = point .- eye
		depth = max(-_s3_dot(q, v), min_depth)
		return (_s3_dot(q, r) / (depth * tan_half * ratio) * width / 2, _s3_dot(q, u) / (depth * tan_half) * height / 2)
	end
	corners = [project(_s3_corner(box, i)) for i in 0:7]
	quads = NTuple{4, NTuple{2, Float64}}[]
	tags = Tuple{Int, Symbol}[]
	any(label -> label.visible, labels) || return corners, quads, tags, _S3Title[]
	geoms = Any[nothing, nothing, nothing]
	edges, signs = _s3_cube_edges(box, eye, project)
	# World length of one gl-axes pad unit: depth of the scene origin over the
	# viewport height (gl-axes: pixelRatio · w / drawingBufferHeight).
	unit = max(_s3_dot(eye, v), 1e-9) / height
	function screen_direction(at, axis::Int)
		step = zeros(3)
		step[axis] = (spans === nothing || !(spans[axis] > 0)) ? box[axis] * 1e-3 : box[axis] / spans[axis]
		a, b = project(at, 1e-4), project(at .+ step, 1e-4)
		len = hypot(b[1] - a[1], b[2] - a[2])
		return len > 0 ? ((b[1] - a[1]) / len, (b[2] - a[2]) / len) : (1.0, 0.0)
	end
	for a in 1:3
		label = labels[a]
		label.visible || continue
		edge = zeros(3)
		minor = zeros(3)
		for o in 1:3
			o == a && continue
			high = (edges[a] >> (o - 1)) & 1 == 1
			edge[o] = high ? box[o] / 2 : -box[o] / 2
			minor[o] = high ? (signs[o] > 0 ? 0.0 : 1.0) : (signs[o] > 0 ? -1.0 : 0.0)
		end
		offset = zeros(3)
		if label.marks
			for o in 1:3
				offset[o] += minor[o] * max(labels[o].ticklen, 0.0) * unit
			end
		end
		low, high = copy(edge), copy(edge)
		low[a], high[a] = -box[a] / 2, box[a] / 2
		geoms[a] = (project(low), project(high))
		if label.ticks_shown
			offset .+= (label.tick_pad * unit) .* minor
			pushed = findall(!iszero, minor)
			for (end_tag, fraction) in ((:tick_lo, label.tick_lo), (:tick_hi, label.tick_hi))
				at = copy(edge)
				at[a] = (fraction - 0.5) * box[a]
				at .+= offset
				along = length(pushed) == 1 ? screen_direction(at, pushed[1]) : (1.0, 0.0)
				if label.tick_chars > 0
					push!(quads, _s3_text_quad(
						project(at), along, 0.5 * label.tick_chars * _S3_CHAR_EM * label.tick_size, 0.5 * label.tick_size,
					))
					push!(tags, (a, end_tag))
				end
			end
		end
		label.title_chars > 0 || continue
		own && continue
		offset .+= (label.label_pad * unit) .* minor
		at = (low .+ high) ./ 2 .+ offset
		along = label.title_along ? screen_direction(at, a) : (1.0, 0.0)
		thick = label.title_size * (1 + _S3_LINE_EM * (label.title_lines - 1))
		push!(quads, _s3_text_quad(project(at), along, 0.5 * label.title_chars * _S3_CHAR_EM * label.title_size, 0.5 * thick))
		push!(tags, (a, :title))
	end
	placed = _S3Title[]
	if own
		centroid = (sum(first, corners) / 8, sum(last, corners) / 8)
		placed, title_quads, _ = _s3_place_titles_laddered(labels, geoms, copy(quads), centroid)
		for (title, quad) in zip(placed, title_quads)
			push!(quads, quad)
			push!(tags, (title.axis, :title))
		end
	end
	return corners, quads, tags, placed
end

# ── Axis titles drawn by PlotlySupply ────────────────────────────────────────
#
# gl-axes draws each axis title at a fixed pad from its edge, along the edge,
# and lets titles run over each other and over tick labels when the scene is
# small or the titles are long. When the titles of a scene cannot be kept
# apart that way (`_s3_fit_with_pads`), PlotlySupply draws them itself: the
# scene's own title is replaced by `_S3_TITLE_HIDDEN` (the text is kept in
# the scene's mark) and a paper annotation named
# `plotlysupply:scene3d:<scene>:title:<letter>` is written at the projected
# middle of the axis edge, rotated along it, pushed out until it clears the
# tick labels, and, when titles still meet, slid, wrapped at a space or set
# smaller (`_S3_OWN_LADDER`).
const _S3_TITLE_HIDDEN = " "
const _S3_OWN_LADDER = ((1.0, false), (1.0, true), (0.9, true), (0.8, true), (0.7, true))
const _S3_OWN_STEP_PX = 2.0
const _S3_OWN_MAX_PUSH_PX = 400.0
# An edge that projects shorter than this many title font sizes carries its
# title horizontally.
const _S3_OWN_MIN_EDGE_FONTS = 2.0

struct _S3Title
	axis::Int
	center::NTuple{2, Float64}
	angle::Float64
	size::Float64
	text::String
	lines::Int
end

# `text` broken in two lines at the space (outside HTML tags and `$…$`)
# nearest its middle, as `(text with <br>, longest line's characters)`;
# `nothing` without a usable space.
function _s3_wrap_title(text::AbstractString)
	occursin(r"<br\s*/?>"i, text) && return nothing
	spaces = Int[]
	in_tag = false
	in_math = false
	for (index, char) in pairs(text)
		if char == '<'
			in_tag = true
		elseif char == '>'
			in_tag = false
		elseif char == '$'
			in_math = !in_math
		elseif char == ' ' && !in_tag && !in_math
			push!(spaces, index)
		end
	end
	isempty(spaces) && return nothing
	total = _s3_visible_chars(text)
	best = argmin(index -> abs(_s3_visible_chars(text[1:prevind(text, index)]) - total / 2), spaces)
	first_line = text[1:prevind(text, best)]
	second_line = text[nextind(text, best):end]
	(isempty(strip(first_line)) || isempty(strip(second_line))) && return nothing
	return string(first_line, "<br>", second_line), max(_s3_visible_chars(first_line), _s3_visible_chars(second_line))
end

# The titles of the scene drawn at `scale` times their font sizes (`wrap`:
# wrapped where possible) around the tick-label rectangles `ticks`, from the
# projected edge ends `geoms` of the axes (`labels` as `_s3_axis_labels`) and
# the box's centroid on screen: `(titles, quads, ok)` where `ok` says that no
# title meets a tick label or another title.
function _s3_place_titles(labels, geoms, ticks, centroid, scale::Float64, wrap::Bool)
	titles = _S3Title[]
	quads = NTuple{4, NTuple{2, Float64}}[]
	for a in 1:3
		label = labels[a]
		(label.visible && label.title_chars > 0 && geoms[a] !== nothing) || continue
		lo, hi = geoms[a]
		text, chars, lines = label.title_text, label.title_chars, label.title_lines
		if wrap && lines == 1
			wrapped = _s3_wrap_title(text)
			wrapped === nothing || ((text, chars) = wrapped; lines = 2)
		end
		size = label.title_size * scale
		half_len = 0.5 * chars * _S3_CHAR_EM * size
		half_thick = 0.5 * size * (1 + _S3_LINE_EM * (lines - 1))
		dx, dy = hi[1] - lo[1], hi[2] - lo[2]
		edge = hypot(dx, dy)
		center = ((lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2)
		if label.title_along && edge >= _S3_OWN_MIN_EDGE_FONTS * size
			t = (dx / edge, dy / edge)
			(t[1] < -1e-9 || (abs(t[1]) <= 1e-9 && t[2] < 0)) && (t = (-t[1], -t[2]))
			n = (-t[2], t[1])
		else
			t = (1.0, 0.0)
			n = (center[1] - centroid[1], center[2] - centroid[2])
			len = hypot(n[1], n[2])
			n = len > 1e-9 ? (n[1] / len, n[2] / len) : (0.0, 1.0)
		end
		(n[1] * (center[1] - centroid[1]) + n[2] * (center[2] - centroid[2]) < 0) && (n = (-n[1], -n[2]))
		push_px = half_thick + 2.0
		at = center
		quad = nothing
		while true
			at = (center[1] + push_px * n[1], center[2] + push_px * n[2])
			quad = _s3_text_quad(at, t, half_len, half_thick)
			push_px >= _S3_OWN_MAX_PUSH_PX && break
			any(tick -> _s3_quads_intersect(quad, tick; tolerance = _S3_LABEL_TOUCH_PX), ticks) || break
			push_px += _S3_OWN_STEP_PX
		end
		push!(titles, _S3Title(a, at, rad2deg(atan(t[2], t[1])), size, text, lines))
		push!(quads, quad)
	end
	ok = all(quad -> !any(tick -> _s3_quads_intersect(quad, tick; tolerance = _S3_LABEL_TOUCH_PX), ticks), quads)
	for i in eachindex(quads), j in (i + 1):length(quads)
		_s3_quads_intersect(quads[i], quads[j]; tolerance = _S3_LABEL_TOUCH_PX) && (ok = false)
	end
	return titles, quads, ok
end

# `_s3_place_titles` down `_S3_OWN_LADDER` until one placement is clear (the
# last one otherwise): `(titles, quads, ok)`.
function _s3_place_titles_laddered(labels, geoms, ticks, centroid)
	result = nothing
	for (scale, wrap) in _S3_OWN_LADDER
		result = _s3_place_titles(labels, geoms, ticks, centroid, scale, wrap)
		result[3] && break
	end
	return result
end

# Pan steps and tolerance (px) for centring an exported scene's drawing.
const _S3_PAN_ROUNDS = 40
const _S3_PAN_MIN_STEP = 1 / 64
# Steps of `_s3_export_camera` that pull its lower distance bound closer while the
# drawing still fits at it, and the factor of each.
const _S3_NEAR_ROUNDS = 60
const _S3_NEAR_STEP = 0.8
# Relative width of the distance bracket at which the search stops: the drawing
# then differs from the closest fit by well under 0.2 % of the viewport.
const _S3_DISTANCE_RTOL = 2e-4
const _S3_PAN_TOLERANCE_PX = 0.5

# ── Legends over a scene ─────────────────────────────────────────────────────
#
# A legend box placed over a scene's viewport (a SubplotFigure cell legend
# sits at its cell's top right, inside the cell) would cover the drawing,
# which fills the viewport. The framing fits the drawing into the part of the
# viewport the legends leave free (`_s3_free_region`).

# Rectangles (left, top, right, bottom; figure px from the top-left corner)
# of the legends of `p` placed in the plot area `area` (`_s3_plot_area`): a
# legend with numeric `x` and `y` in paper units (the plot area) or
# container units (the figure), anchored as plotly.js resolves `xanchor`
# (default "left"; "auto": "right" from x >= 2/3, "center" above 1/3) and
# `yanchor` (default "auto": "bottom" up to y <= 1/3, "middle" below 2/3,
# else "top"; plotly.js lib anchor_utils), sized by `_legend_box_size`.
# Legends at plotly's default position (no `x`/`y`) sit outside the plot
# area and are not listed; neither are hidden or empty legends.
function _s3_legend_rects(p::Plot, area)
	rects = NTuple{4, Float64}[]
	get(p.layout.fields, :showlegend, true) === false && return rects
	plot_w = max(area.width - area.l - area.r, 1.0)
	plot_h = max(area.height - area.t - area.b, 1.0)
	for (key, value) in p.layout.fields
		(key isa Symbol && occursin(r"^legend\d*$", String(key))) || continue
		box = _symbol_dict(value)
		x, y = _legend_real(get(box, :x, nothing)), _legend_real(get(box, :y, nothing))
		(x === nothing || y === nothing) && continue
		size = _legend_box_size(p, String(key))
		size === nothing && continue
		w, h = Float64(size[1]), Float64(size[2])
		X = string(get(box, :xref, "paper")) == "container" ? x * area.width : area.l + x * plot_w
		Y = string(get(box, :yref, "paper")) == "container" ? (1 - y) * area.height : area.t + (1 - y) * plot_h
		xa, ya = string(get(box, :xanchor, "left")), string(get(box, :yanchor, "auto"))
		left = (xa == "right" || (xa == "auto" && x >= 2 / 3)) ? X - w :
			(xa == "center" || (xa == "auto" && 1 / 3 < x < 2 / 3)) ? X - w / 2 : X
		top = (ya == "bottom" || (ya == "auto" && y <= 1 / 3)) ? Y - h :
			(ya == "middle" || (ya == "auto" && 1 / 3 < y < 2 / 3)) ? Y - h / 2 : Y
		push!(rects, (left, top, left + w, top + h))
	end
	return rects
end

# The part of the `width`×`height` px viewport of `target` that the scene's
# drawing may use, as (xmin, xmax, ymin, ymax) px from the viewport centre
# with y up: the viewport less `_S3_LABEL_MARGIN_PX` per side, less each
# legend over it (`_s3_legend_rects`). A legend is cut off along the side
# that leaves the drawing (`drawing` = its width and height) the larger
# scale; a cut that would leave less than `_S3_MIN_FILL` of the viewport's
# width or height is not made (the legend then overlaps, as before).
function _s3_free_region(p::Plot, target::_CellTarget, width::Float64, height::Float64, drawing)
	m = _S3_LABEL_MARGIN_PX
	region = (-width / 2 + m, width / 2 - m, -height / 2 + m, height / 2 - m)
	area = _s3_plot_area(p)
	plot_w = max(area.width - area.l - area.r, 1.0)
	plot_h = max(area.height - area.t - area.b, 1.0)
	cx = area.l + plot_w * target.xdomain[1] + width / 2
	cy = area.t + plot_h * (1 - target.ydomain[2]) + height / 2
	dw, dh = max(Float64(drawing[1]), 1e-9), max(Float64(drawing[2]), 1e-9)
	scale(r) = min((r[2] - r[1]) / dw, (r[4] - r[3]) / dh)
	for (left, top, right, bottom) in _s3_legend_rects(p, area)
		x0, x1 = left - cx, right - cx
		y0, y1 = cy - bottom, cy - top
		(x1 > region[1] && x0 < region[2] && y1 > region[3] && y0 < region[4]) || continue
		best = nothing
		for candidate in (
			(region[1], min(region[2], x0 - m), region[3], region[4]),   # left of the legend
			(max(region[1], x1 + m), region[2], region[3], region[4]),   # right of it
			(region[1], region[2], region[3], min(region[4], y0 - m)),   # below it
			(region[1], region[2], max(region[3], y1 + m), region[4]),   # above it
		)
			(candidate[2] - candidate[1] >= _S3_MIN_FILL * width &&
				candidate[4] - candidate[3] >= _S3_MIN_FILL * height) || continue
			(best === nothing || scale(candidate) > scale(best)) && (best = candidate)
		end
		best === nothing || (region = best)
	end
	return region
end

# Camera of an exported scene: the distance from the camera centre (along the
# unit `direction`, up vector `up`) and the camera centre at which the scene
# box (side lengths `box`, centred on the origin) and the tick labels and axis
# titles plotly.js draws around it (`_s3_label_layout`) are as large as they
# can be inside the part of the target's viewport the drawing may use
# (`_s3_free_region`: `_S3_LABEL_MARGIN_PX` from its edges, clear of legends
# over it). With `pan` the camera centre moves across the view from `center`
# until the drawing is centred in that region (labels often hang off one side
# of the box); without it `center` is kept. The distance is found by
# bisection between one closer than any that fits (the bare box overflows
# the region) and the one at which the bare box fills `_S3_FAR_FILL` of the
# region (labels that do not fit even then get the latter). When `up` is
# parallel to `direction`:
# `_s3_auto_distance` and `center`.
function _s3_export_camera(fig, target::_CellTarget, box, direction, up; center, pan::Bool, zoom::Float64 = 1.0, pads = nothing, own::Bool = false)
	c0 = (Float64(center[1]), Float64(center[2]), Float64(center[3]))
	frame = _s3_camera_frame(direction, up)
	frame === nothing && return (_s3_auto_distance(fig, target, box, direction, up, zoom; center = c0), c0)
	p = _cmn_plot(fig)
	width, height = _s3_viewport(fig, target)
	ratio = width / height
	labels = pads === nothing ? _s3_axis_labels(p, target.scenekey) : _s3_axis_labels(p, target.scenekey; pads = pads)
	spans = _s3_scene_spans(p, target.scenekey)
	v, r, u = frame
	function extent(c, distance)
		corners, quads, _ = _s3_label_layout_tagged(box, c, frame, distance, width, height, labels, spans; own = own)
		xmin, xmax, ymin, ymax = Inf, -Inf, Inf, -Inf
		for point in corners
			xmin, xmax = min(xmin, point[1]), max(xmax, point[1])
			ymin, ymax = min(ymin, point[2]), max(ymax, point[2])
		end
		for quad in quads, point in quad
			xmin, xmax = min(xmin, point[1]), max(xmax, point[1])
			ymin, ymax = min(ymin, point[2]), max(ymax, point[2])
		end
		return (xmin, xmax, ymin, ymax)
	end
	# The region the drawing may use, chosen for the drawing's proportions at
	# the distance where the bare box fills the viewport (less the margin).
	full_x = max(1 - 2 * _S3_LABEL_MARGIN_PX / width, _S3_MIN_FILL)
	full_y = max(1 - 2 * _S3_LABEL_MARGIN_PX / height, _S3_MIN_FILL)
	e0 = extent(c0, _s3_box_distance(box, c0, frame, ratio, full_x, full_y))
	region = _s3_free_region(p, target, width, height, (e0[2] - e0[1], e0[4] - e0[3]))
	goal_x, goal_y = (region[1] + region[2]) / 2, (region[3] + region[4]) / 2
	# The camera centre for `distance` and whether the drawing then fits.
	# Moving the camera across the view moves each point on screen by the move
	# over the point's depth; moving it by the pixels the drawing is off centre
	# (from the region's centre) at the depth of the scene origin converges in
	# a few rounds.
	function place(distance, start = c0)
		c = start
		e = extent(c, distance)
		if pan
			off(e) = ((e[1] + e[2]) / 2 - goal_x, (e[3] + e[4]) / 2 - goal_y)
			for _ in 1:_S3_PAN_ROUNDS
				off_x, off_y = off(e)
				max(abs(off_x), abs(off_y)) <= _S3_PAN_TOLERANCE_PX && break
				world_per_px = 2 * tan(_S3_HALF_FOVY) * (_s3_dot(c, v) + distance) / height
				# Close to the box the step can overshoot (points near or behind
				# the eye move far on screen): halve it until the drawing is
				# nearer the goal.
				scale = 1.0
				moved = false
				while scale >= _S3_PAN_MIN_STEP
					c2 = c .+ (scale * off_x * world_per_px) .* r .+ (scale * off_y * world_per_px) .* u
					e2 = extent(c2, distance)
					(ox, oy) = off(e2)
					if hypot(ox, oy) < hypot(off_x, off_y)
						c, e, moved = c2, e2, true
						break
					end
					scale /= 2
				end
				moved || break
			end
		end
		return c, e[1] >= region[1] && e[2] <= region[2] && e[3] >= region[3] && e[4] <= region[4]
	end
	# Distance bounds (a region narrowed by a legend is a fraction `share` of
	# the full one). Closer than `near` nothing fits: without `pan` a box
	# corner seen from `center` leaves the viewport less the margin, which
	# holds the region; with `pan` the box (which holds the scene origin, seen
	# at the view centre) spans more than the region, as some corner is
	# farther than the region's width from the view centre. At `far` the bare
	# box fills `_S3_FAR_FILL` of the region.
	share_x = min((region[2] - region[1]) / width / full_x, 1.0)
	share_y = min((region[4] - region[3]) / height / full_y, 1.0)
	near = pan ? _s3_box_distance(box, c0, frame, ratio, 2 * full_x * share_x, 2 * full_y * share_y) :
		_s3_box_distance(box, c0, frame, ratio, full_x, full_y)
	far = _s3_box_distance(box, c0, frame, ratio, _S3_FAR_FILL * share_x, _S3_FAR_FILL * share_y)
	# The fitted distance and camera centre, before `zoom`.
	function fitted()
		far <= near && return (near, first(place(near)))
		c_far, fits_far = place(far)
		fits_far || return (far, c_far)
		# `near` is an estimate of a distance too close to fit; where the
		# drawing still fits there (a panned drawing may use the region more
		# fully than the estimate allows) it is the new `far` and the estimate
		# moves closer.
		c_near, fits_near = place(near, c_far)
		for _ in 1:_S3_NEAR_ROUNDS
			fits_near || break
			(far, c_far) = (near, c_near)
			near *= _S3_NEAR_STEP
			c_near, fits_near = place(near, c_far)
		end
		fits_near && return (far, c_far)
		# The box shrinks towards the centre as the camera backs away while
		# the label offsets stay fixed in pixels, so the drawing fits from one
		# distance on.
		for _ in 1:60
			mid = (near + far) / 2
			c_mid, fits_mid = place(mid, c_far)
			fits_mid ? ((far, c_far) = (mid, c_mid)) : (near = mid)
			far - near <= _S3_DISTANCE_RTOL * far && break
		end
		return (far, c_far)
	end
	distance, c = fitted()
	zoom == 1 && return (distance, c)
	# `zoom` divides the fitted distance; the drawing is centred again there.
	distance /= zoom
	return (distance, first(place(distance, c)))
end

_s3_vector3(mapping, default::Float64 = 0.0) = [
	(value = _cmn_mapping_get(mapping, key); (_s3_is_real(value) && isfinite(value)) ? Float64(value) : default)
	for key in (:x, :y, :z)
]

# ── Framing mark ──────────────────────────────────────────────────────────────
#
# What PlotlySupply wrote on a scene to frame it is recorded on the scene as
# `scene.plotlysupply` (plotly.js ignores the key; checked on a render and
# through `relayout`): whether the camera is automatic, the `view!` zoom,
# whether the camera centre is PlotlySupply's to move (`pan`), the eye and
# centre last written, the tick counts written (0: none) and, per axis, the
# tick font size asked for and the size written for it
# (`_s3_compensate_tick_fonts!`). A camera, tick count or tick font that no
# longer matches its record was set by someone else and is kept. Scenes
# without the mark (figures built without PlotlySupply's 3-D functions) are
# never re-framed.
const _S3_MARK_KEY = :plotlysupply

struct _S3Mark
	auto::Bool
	zoom::Float64
	pan::Bool
	eye::Union{Nothing, NTuple{3, Float64}}
	center::NTuple{3, Float64}
	nticks::NTuple{3, Int}
	font::NTuple{3, Float64}
	font_written::NTuple{3, Float64}
	titles::NTuple{3, String}
	tickvals::NTuple{3, Tuple{Vararg{Float64}}}
end

Base.:(==)(a::_S3Mark, b::_S3Mark) = all(name -> getfield(a, name) == getfield(b, name), fieldnames(_S3Mark))

const _S3_ORIGIN = (0.0, 0.0, 0.0)
const _S3_NEW_MARK = _S3Mark(true, 1.0, true, nothing, _S3_ORIGIN, (0, 0, 0), _S3_ORIGIN, _S3_ORIGIN, ("", "", ""), ((), (), ()))

# The mark of a scene layout entry, or `nothing`. Malformed entries (edited by
# hand) read as their defaults.
function _s3_mark(scene)
	raw = _cmn_mapping_get(scene, _S3_MARK_KEY)
	raw === nothing && return nothing
	field(key) = _cmn_mapping_get(raw, key)
	function triple(key)
		value = field(key)
		((value isa AbstractVector || value isa Tuple) && length(value) == 3 &&
			all(v -> _s3_is_real(v) && isfinite(v), value)) || return nothing
		return (Float64(value[1]), Float64(value[2]), Float64(value[3]))
	end
	counts = triple(:nticks)
	counts = counts === nothing ? (0, 0, 0) :
		map(n -> (isinteger(n) && 0 <= n <= typemax(Int32)) ? Int(n) : 0, counts)
	zoom = field(:zoom)
	zoom = (_s3_is_real(zoom) && isfinite(zoom) && zoom > 0) ? Float64(zoom) : 1.0
	return _S3Mark(
		field(:auto) === true,
		zoom,
		field(:pan) === true,
		triple(:eye),
		something(triple(:center), _S3_ORIGIN),
		counts,
		something(triple(:fontsize), _S3_ORIGIN),
		something(triple(:fontwritten), _S3_ORIGIN),
		_s3_mark_titles(field(:titles)),
		_s3_mark_tickvals(field(:tickvals)),
	)
end

# The three title texts of a mark's `titles` entry (empty where absent).
function _s3_mark_titles(value)
	(value isa AbstractVector || value isa Tuple) && length(value) == 3 || return ("", "", "")
	return ntuple(i -> value[i] isa AbstractString ? String(value[i]) : "", 3)
end

# The tick values of a mark's `tickvals` entry (none where absent).
function _s3_mark_tickvals(value)
	(value isa AbstractVector || value isa Tuple) && length(value) == 3 || return ((), (), ())
	return ntuple(3) do i
		list = value[i]
		((list isa AbstractVector || list isa Tuple) && all(v -> _s3_is_real(v) && isfinite(v), list)) ?
			Tuple(Float64(v) for v in list) : ()
	end
end

# Write `mark` on scene `key` of `layout`; returns whether it changed.
function _s3_write_mark!(layout::Layout, key::Symbol, mark::_S3Mark)
	_s3_mark(get(layout.fields, key, nothing)) == mark && return false
	value = attr(
		auto = mark.auto,
		zoom = mark.zoom,
		pan = mark.pan,
		eye = mark.eye === nothing ? Float64[] : collect(mark.eye),
		center = collect(mark.center),
		nticks = collect(mark.nticks),
		fontsize = collect(mark.font),
		fontwritten = collect(mark.font_written),
		titles = collect(mark.titles),
		tickvals = [collect(t) for t in mark.tickvals],
	)
	_merge_scene_layout_attr!(layout, key, attr(; _S3_MARK_KEY => value))
	return true
end

# The scene's mark (a new one when it has none) with the fields in `changes`
# replaced.
function _s3_marked(scene; changes...)
	mark = something(_s3_mark(scene), _S3_NEW_MARK)
	values = Dict{Symbol, Any}(name => getfield(mark, name) for name in fieldnames(_S3Mark))
	for (name, value) in changes
		values[name] = value
	end
	return _S3Mark((values[name] for name in fieldnames(_S3Mark))...)
end

_s3_same_point(a, b) = isapprox(collect(Float64, a), collect(Float64, b); rtol = 1e-9, atol = 1e-12)

# Whether the scene's camera is automatic: it has no eye (plotly's default
# camera, unless the mark says the user fixed it), or its eye and centre are
# the ones the mark records for an automatic camera.
function _s3_auto_camera(scene)
	camera = _cmn_mapping_get(scene, :camera)
	eye = _cmn_mapping_get(camera, :eye)
	mark = _s3_mark(scene)
	eye === nothing && return mark === nothing || mark.auto
	(mark === nothing || !mark.auto || mark.eye === nothing) && return false
	_s3_same_point(_s3_vector3(eye, NaN), mark.eye) || return false
	return _s3_same_point(_s3_vector3(_cmn_mapping_get(camera, :center)), mark.center)
end

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
	mark = _s3_mark(scene)
	auto_ticks = ntuple(3) do d
		nticks = _cmn_mapping_get(_cmn_mapping_get(scene, (:xaxis, :yaxis, :zaxis)[d]), :nticks)
		nticks === nothing && return true
		return mark !== nothing && mark.nticks[d] > 0 && _s3_is_real(nticks) && nticks == mark.nticks[d]
	end
	return _S3SceneState(pinned, _s3_auto_camera(scene), auto_ticks)
end

# plotly.js gives a 3-D axis with automatic ticks `nticks || clamp(L / 40, 4, 9)`
# ticks, where L is the axis length in pixels it computes from the size of the
# whole figure canvas (gl3d tick_marks and gl-axes pixel range, plotly.js
# 2.35.2). A scene in a subplot cell is much smaller than that canvas, so its
# short edges get four to nine labels that overlap. A scene whose domain is
# smaller than the plot area therefore gets nticks = clamp(floor(L / 40), 2, 9)
# per axis from the axis's projected length L in its own viewport (the
# centre line of the scene box, seen from its camera); 40 px per tick and the
# upper bound 9 are plotly.js's own. plotly.js rounds the step span/nticks up
# (`_s3_plotly_tick_step`), so a low count can leave one label on an axis (a
# span of 4.25 with 2 ticks gets the step 5 and the single label 0); such a
# linear axis gets the smallest larger count that labels two ticks, as long
# as the labels stay apart along the axis (`_s3_cell_tick_count`). `nothing`
# for a full-size scene none of whose axes is shorter than four ticks' worth
# (plotly.js's own lower bound; a short axis of a small figure gets the counts
# too) or when the camera cannot tell. `false` for a full-size scene that
# keeps plotly.js's own count (counts this module wrote earlier are removed).
const _S3_TICK_SPACING_PX = 40.0
const _S3_MIN_CELL_TICKS = 2
const _S3_MAX_AUTO_TICKS = 9
# plotly.js's lower bound of that automatic count (a full-size scene).
const _S3_MIN_PLOTLY_TICKS = 4

function _s3_auto_nticks(fig, target::_CellTarget)
	full = target.xdomain[2] - target.xdomain[1] >= 1 - 1e-9 && target.ydomain[2] - target.ydomain[1] >= 1 - 1e-9
	p = _cmn_plot(fig)
	box = _s3_drawn_box(p, target.scenekey)
	box === nothing && return nothing
	lengths = _s3_axis_pixel_lengths(fig, target, box)
	lengths === nothing && return nothing
	# A scene that fills the figure keeps plotly.js's count unless an axis is
	# so short in px that plotly.js's lower bound of four ticks (and its
	# canvas-based length, which grows with the export scale) crowds it (a
	# scene in a single-column figure).
	full && all(L -> floor(Int, L / _S3_TICK_SPACING_PX) >= _S3_MIN_PLOTLY_TICKS, lengths) && return false
	scene = get(p.layout.fields, target.scenekey, nothing)
	font = _s3_number_field(_cmn_mapping_get(p.layout.fields, :font), :size, _S3_DEFAULT_FONT_SIZE; positive = true)
	return map(1:3) do d
		count = clamp(floor(Int, lengths[d] / _S3_TICK_SPACING_PX), _S3_MIN_CELL_TICKS, _S3_MAX_AUTO_TICKS)
		fields = _cmn_mapping_get(scene, (:xaxis, :yaxis, :zaxis)[d])
		return _s3_cell_tick_count(p, target.scenekey, d, fields, lengths[d], count, font)
	end
end

# The tick count for linear scene axis `d` (`fields` its layout entry, about
# `length_px` long in its viewport) starting from `count`: `count` when
# plotly.js labels at least two ticks with it, else the smallest larger count
# up to `_S3_MAX_AUTO_TICKS` that does, provided that consecutive labels of
# that count are at least the widest of them plus one character apart along
# the axis (`_S3_CHAR_EM` per character at the drawn tick size); `count` when
# no such count exists or the axis is log, date or category or has no range.
function _s3_cell_tick_count(p::Plot, scenekey::Symbol, d::Int, fields, length_px::Float64, count::Int, font::Float64)
	_cmn_mapping_get(fields, :type) in (nothing, "-", "linear") || return count
	range = _s3_axis_range(p, scenekey, d, fields)
	range === nothing && return count
	lo, hi = minmax(range[1], range[2])
	span = hi - lo
	(isfinite(span) && span > 0) || return count
	char_px = _S3_CHAR_EM * _s3_tick_text_size(_s3_number_field(_cmn_mapping_get(fields, :tickfont), :size, font; positive = true))
	for n in count:_S3_MAX_AUTO_TICKS
		step = _s3_plotly_tick_step(span, n)
		first_tick = ceil(lo / step - 1e-9) * step
		last_tick = floor(hi / step + 1e-9) * step
		labels = first_tick <= last_tick ? round(Int, (last_tick - first_tick) / step) + 1 : 0
		if n > count
			chars = labels > 0 ? max(_s3_tick_text_chars(first_tick, step), _s3_tick_text_chars(last_tick, step)) : 1
			step / span * length_px >= (chars + 1) * char_px || return count
		end
		labels >= 2 && return n
	end
	return count
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
# does not place, and record them in the scene's mark. Returns whether it
# wrote.
function _s3_finish_ticks!(fig, target::_CellTarget, state::_S3SceneState)
	counts = _s3_auto_nticks(fig, target)
	counts === nothing && return false
	p = _cmn_plot(fig)
	scene = get(p.layout.fields, target.scenekey, nothing)
	updates = Dict{Symbol, Any}()
	mark = something(_s3_mark(scene), _S3_NEW_MARK)
	recorded = collect(mark.nticks)
	if counts === false
		# plotly.js's own count: take back the counts written for a smaller scene.
		removed = false
		for (d, axis) in enumerate((:xaxis, :yaxis, :zaxis))
			recorded[d] > 0 || continue
			fields = _cmn_mapping_get(scene, axis)
			if _cmn_mapping_get(fields, :nticks) == recorded[d]
				_cmn_mapping_delete!(fields, (:nticks,))
				removed = true
			end
			recorded[d] = 0
		end
		marked = _s3_write_mark!(p.layout, target.scenekey,
			_s3_marked(get(p.layout.fields, target.scenekey, nothing); nticks = Tuple(recorded)))
		return removed | marked
	end
	for (d, axis) in enumerate((:xaxis, :yaxis, :zaxis))
		state.auto_ticks[d] || continue
		fields = _cmn_mapping_get(scene, axis)
		(_s3_user_ticks(fields) && !_s3_ours_tickvals(mark, d, fields)) && continue
		recorded[d] = counts[d]
		_cmn_mapping_get(fields, :nticks) == counts[d] && continue
		updates[axis] = attr(nticks = counts[d])
	end
	isempty(updates) || _merge_scene_layout_attr!(p.layout, target.scenekey, attr(; updates...))
	marked = _s3_write_mark!(p.layout, target.scenekey,
		_s3_marked(get(p.layout.fields, target.scenekey, nothing); nticks = Tuple(recorded)))
	return !isempty(updates) || marked
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
	_s3_frame_camera!(fig, target)
	return nothing
end

# ── Corner tick labels ───────────────────────────────────────────────────────
#
# Two axes whose label edges meet at a box corner each end a tick there, and
# the two tick labels can lie on each other (the z tick "-1" on the x tick
# "-0.5" at the bottom-left corner of a radiation pattern). Where the end tick
# labels of two axes of the framed scene (linear axes with automatic ticks)
# intersect, `_s3_trim_corner_ticks!` writes the tick values of the axis with
# more ticks, as the multiples of plotly.js's step `_s3_plotly_tick_step`
# inside its range for the tick count the 40 px rule gives, without that end
# tick; the written values are recorded in the scene's mark (`tickvals`) and
# are PlotlySupply's as long as they equal the record: the next pass starts
# from the automatic ticks again, so data or size changes never leave a
# stale trim, and a tick placement of the user's is never touched.

# Whether the tick values of axis `d` (layout entry `fields`) are the ones
# `_s3_trim_corner_ticks!` wrote (the mark's record).
function _s3_ours_tickvals(mark::_S3Mark, d::Int, fields)
	record = mark.tickvals[d]
	current = _cmn_mapping_get(fields, :tickvals)
	return !isempty(record) && current isa AbstractVector && length(current) == length(record) &&
		all(i -> current[i] == record[i], eachindex(record))
end

# The ticks plotly.js's step puts inside `range` (ascending) for `count`.
function _s3_nice_ticks(range, count::Int)
	lo, hi = Float64(range[1]), Float64(range[2])
	(isfinite(lo) && isfinite(hi) && hi > lo) || return (Float64[], 0.0)
	step = _s3_plotly_tick_step(hi - lo, max(count, 1))
	first_index = ceil(Int, lo / step - 1e-9)
	last_index = floor(Int, hi / step + 1e-9)
	return [round(k * step; sigdigits = 12) for k in first_index:last_index], step
end

# `(lo, hi, chars)` of the tick labels at `values` (ascending, step `step`) on
# an axis with `range`: the `_s3_tick_extent` triple.
function _s3_ticks_extent(values, step::Float64, range)
	isempty(values) && return (0.5, 0.5, 0)
	span = range[2] - range[1]
	lo, hi = (values[1] - range[1]) / span, (values[end] - range[1]) / span
	chars = max(_s3_tick_text_chars(values[1], step), _s3_tick_text_chars(values[end], step))
	return (clamp(lo, 0.0, 1.0), clamp(hi, 0.0, 1.0), chars)
end

function _s3_trim_corner_ticks!(p::Plot, target::_CellTarget)
	key = target.scenekey
	layout = p.layout
	scene = get(layout.fields, key, nothing)
	camera = _cmn_mapping_get(scene, :camera)
	_cmn_mapping_get(_cmn_mapping_get(camera, :projection), :type) == "orthographic" && return false
	box = _s3_drawn_box(p, key)
	box === nothing && return false
	mark = something(_s3_mark(scene), _S3_NEW_MARK)
	eye_value = _cmn_mapping_get(camera, :eye)
	eye_value === nothing && return false
	center = _s3_vector3(_cmn_mapping_get(camera, :center))
	offset = _s3_vector3(eye_value, NaN) .- center
	distance = _s3_norm(offset)
	(isfinite(distance) && distance > 0) || return false
	frame = _s3_camera_frame(offset ./ distance, _s3_camera_up(camera))
	frame === nothing && return false
	axes = (:xaxis, :yaxis, :zaxis)
	lengths = _s3_axis_pixel_lengths(p, target, box)
	lengths === nothing && return false
	values = Vector{Union{Nothing, Vector{Float64}}}(nothing, 3)
	steps = zeros(3)
	ranges = Vector{Any}(nothing, 3)
	for d in 1:3
		fields = _cmn_mapping_get(scene, axes[d])
		(_s3_user_ticks(fields) && !_s3_ours_tickvals(mark, d, fields)) && continue
		_cmn_mapping_get(fields, :type) in (nothing, "-", "linear") || continue
		(_cmn_mapping_get(fields, :visible) === false || _cmn_mapping_get(fields, :showticklabels) === false) && continue
		range = _s3_axis_range(p, key, d, fields)
		(range === nothing || !(range[1] < range[2])) && continue
		nticks = _cmn_mapping_get(fields, :nticks)
		count = (_s3_is_real(nticks) && isinteger(nticks) && nticks >= 1) ? Int(nticks) :
			clamp(floor(Int, lengths[d] / _S3_TICK_SPACING_PX), _S3_MIN_PLOTLY_TICKS, _S3_MAX_AUTO_TICKS)
		list, step = _s3_nice_ticks(range, count)
		length(list) >= 2 || continue
		values[d], steps[d], ranges[d] = list, step, range
	end
	trimmed = Set{Int}()
	width, height = _s3_viewport(p, target)
	spans = _s3_scene_spans(p, key)
	for _ in 1:6
		overrides = Dict{Int, NTuple{3, Any}}(d => _s3_ticks_extent(values[d], steps[d], ranges[d]) for d in 1:3 if values[d] !== nothing)
		length(overrides) >= 2 || break
		labels = _s3_axis_labels(p, key; tick_override = overrides)
		_, quads, tags, _ = _s3_label_layout_tagged(box, Tuple(center), frame, distance, width, height, labels, spans)
		is_tick(t) = tags[t][2] in (:tick_lo, :tick_hi)
		hit = nothing
		for i in eachindex(quads), j in (i + 1):length(quads)
			(tags[i][1] != tags[j][1] && is_tick(i) && is_tick(j) &&
				_s3_quads_intersect(quads[i], quads[j]; tolerance = _S3_LABEL_TOUCH_PX)) || continue
			hit = (i, j)
			break
		end
		hit === nothing && break
		choices = [t for t in hit if values[tags[t][1]] !== nothing && length(values[tags[t][1]]) >= 3]
		isempty(choices) && break
		pick = argmax(t -> (length(values[tags[t][1]]), tags[t][1]), choices)
		d = tags[pick][1]
		tags[pick][2] == :tick_lo ? popfirst!(values[d]) : pop!(values[d])
		push!(trimmed, d)
	end
	wrote = false
	new_marks = collect(Tuple{Vararg{Float64}}, mark.tickvals)
	updates = Dict{Symbol, Any}()
	for d in 1:3
		fields = _cmn_mapping_get(scene, axes[d])
		current = _cmn_mapping_get(fields, :tickvals)
		same(list) = current isa AbstractVector && length(current) == length(list) && all(i -> current[i] == list[i], eachindex(list))
		if d in trimmed
			same(values[d]) || (updates[axes[d]] = attr(tickvals = values[d]))
			new_marks[d] = Tuple(values[d])
		elseif !isempty(mark.tickvals[d])
			# Ours from an earlier pass and no longer needed (or replaced by the
			# user): the automatic ticks again.
			if same(mark.tickvals[d])
				_cmn_mapping_delete!(fields, (:tickvals,))
				wrote = true
			end
			new_marks[d] = ()
		end
	end
	isempty(updates) || (_merge_scene_layout_attr!(layout, key, attr(; updates...)); wrote = true)
	wrote |= _s3_write_mark!(layout, key, _s3_marked(get(layout.fields, key, nothing); tickvals = Tuple(new_marks)))
	return wrote
end

# ── Label pad choice ─────────────────────────────────────────────────────────
#
# gl-axes's constant pads (18 and 30 units, about 22 and 36 px) are made for
# one-line labels in a large scene; in a grid cell they cost most of the
# viewport. `_s3_pad_candidates` lists smaller pads, from the least that holds
# one tick label's half length (the labels are pushed along the axis they
# run along) and a title line past it, to the constants; `_s3_fit_with_pads`
# frames the scene with each in turn and keeps the first whose axis titles
# touch no other label, falling back to the one with the fewest collisions.
# One unit is 1/(2 tan(fovy/2)) px at the depth of the scene centre.
const _S3_PAD_UNIT_PX = 1 / (2 * tan(_S3_HALF_FOVY))
const _S3_PAD_GAP_PX = 3.0
const _S3_PAD_STEPS = (1.0, 1.4, 2.0, 2.8)
# Overlap (px) between two label rectangles that still counts as apart.
const _S3_LABEL_TOUCH_PX = 1.0

function _s3_pad_candidates(labels)
	tick_half = 0.0
	title_half = 0.0
	for label in labels
		label.visible || continue
		label.ticks_shown && (tick_half = max(tick_half, 0.5 * label.tick_chars * _S3_CHAR_EM * label.tick_size))
		title_half = max(title_half, 0.5 * label.title_size * (1 + _S3_LINE_EM * (label.title_lines - 1)))
	end
	tick_px = tick_half + _S3_PAD_GAP_PX
	title_px = tick_half + title_half + 2 * _S3_PAD_GAP_PX
	tp0, lp0 = tick_px / _S3_PAD_UNIT_PX, title_px / _S3_PAD_UNIT_PX
	out = NTuple{2, Float64}[]
	for m in _S3_PAD_STEPS
		pads = (min(m * tp0, _S3_GL_TICK_PAD), min(m * lp0, _S3_GL_LABEL_PAD))
		pads = (round(pads[1]; digits = 3), round(pads[2]; digits = 3))
		(isempty(out) || pads != out[end]) && push!(out, pads)
		pads == _S3_GL_DEFAULT_PADS && return out
	end
	push!(out, _S3_GL_DEFAULT_PADS)
	return out
end

# Number of pairs of label rectangles of the drawing at camera centre `c`,
# distance `distance`, that overlap where one of them is an axis title.
function _s3_title_collisions(box, c, frame, distance::Float64, width::Float64, height::Float64, labels, spans; own::Bool = false)
	_, quads, tags, _ = _s3_label_layout_tagged(box, c, frame, distance, width, height, labels, spans; own = own)
	count = 0
	for i in eachindex(quads), j in (i + 1):length(quads)
		(tags[i][2] == :title || tags[j][2] == :title) || continue
		_s3_quads_intersect(quads[i], quads[j]; tolerance = _S3_LABEL_TOUCH_PX) && (count += 1)
	end
	return count
end

# `(distance, camera centre, pads, own)` of `_s3_export_camera` with the best of
# the pads of `_s3_pad_candidates` (see above); when every one of them leaves
# titles colliding, the smallest tick pad with the titles drawn by PlotlySupply
# (`own`, see "Axis titles drawn by PlotlySupply") if that collides less. `up`
# parallel to `direction` has no label model: the constants.
function _s3_fit_with_pads(fig, target::_CellTarget, box, direction, up; center, pan::Bool, zoom::Float64 = 1.0)
	frame = _s3_camera_frame(direction, up)
	if frame === nothing
		distance, c = _s3_export_camera(fig, target, box, direction, up; center, pan, zoom, pads = _S3_GL_DEFAULT_PADS)
		return distance, c, _S3_GL_DEFAULT_PADS, false
	end
	p = _cmn_plot(fig)
	width, height = _s3_viewport(fig, target)
	spans = _s3_scene_spans(p, target.scenekey)
	candidates = _s3_pad_candidates(_s3_axis_labels(p, target.scenekey; pads = _S3_GL_DEFAULT_PADS))
	best = nothing
	for pads in candidates
		distance, c = _s3_export_camera(fig, target, box, direction, up; center, pan, zoom, pads)
		labels = _s3_axis_labels(p, target.scenekey; pads)
		collisions = _s3_title_collisions(box, c, frame, distance, width, height, labels, spans)
		(best === nothing || collisions < best[1]) && (best = (collisions, distance, c, pads, false))
		collisions == 0 && break
	end
	if best[1] > 0
		own_pads = (candidates[1][1], _S3_GL_LABEL_PAD)
		distance, c = _s3_export_camera(fig, target, box, direction, up; center, pan, zoom, pads = own_pads, own = true)
		labels = _s3_axis_labels(p, target.scenekey; pads = own_pads)
		collisions = _s3_title_collisions(box, c, frame, distance, width, height, labels, spans; own = true)
		collisions < best[1] && (best = (collisions, distance, c, own_pads, true))
	end
	return best[2], best[3], best[4], best[5]
end

# Write the titles of the scene as the fit at (`look_at`, `distance`) decided
# (`own`: drawn by PlotlySupply). Returns whether the layout changed.
function _s3_set_titles!(p::Plot, target::_CellTarget, box, direction, up, look_at, distance::Float64, pads, own::Bool)
	labels = _s3_axis_labels(p, target.scenekey; pads = pads)
	placed = nothing
	frame = own ? _s3_camera_frame(direction, up) : nothing
	if frame !== nothing
		width, height = _s3_viewport(p, target)
		_, _, _, placed = _s3_label_layout_tagged(box, look_at, frame, distance, width, height, labels,
			_s3_scene_spans(p, target.scenekey); own = true)
	end
	return _s3_apply_titles!(p, target, labels, placed)
end

# Make the titles of scene `target` as `placed` says: the `_S3Title`s PlotlySupply draws as annotations (the scene's own titles are replaced by `_S3_TITLE_HIDDEN`, their text kept in the mark), or, with `placed === nothing`, the scene's own titles (restored from the mark; annotations removed). `labels` are the scene's `_s3_axis_labels`. A title the user changed since (its text is no longer `_S3_TITLE_HIDDEN`) is theirs and shown as it is. Returns whether the layout changed.
function _s3_apply_titles!(p::Plot, target::_CellTarget, labels, placed)
	key = target.scenekey
	layout = p.layout
	scene = get(layout.fields, key, nothing)
	mark = something(_s3_mark(scene), _S3_NEW_MARK)
	axes = (:xaxis, :yaxis, :zaxis)
	letters = ("x", "y", "z")
	mine = Dict{Int, _S3Title}()
	placed === nothing || foreach(t -> mine[t.axis] = t, placed)
	titles = ["", "", ""]
	updates = Dict{Symbol, Any}()
	fonts = Vector{Any}(nothing, 3)
	for d in 1:3
		fields = _cmn_mapping_get(scene, axes[d])
		title = _cmn_mapping_get(fields, :title)
		raw = title isa AbstractString ? title : _cmn_mapping_get(title, :text)
		fonts[d] = title isa AbstractString ? nothing : _cmn_mapping_get(title, :font)
		if haskey(mine, d)
			titles[d] = labels[d].title_text
			raw == _S3_TITLE_HIDDEN || (updates[axes[d]] = attr(title = attr(text = _S3_TITLE_HIDDEN)))
		elseif raw == _S3_TITLE_HIDDEN && !isempty(mark.titles[d])
			updates[axes[d]] = attr(title = attr(text = mark.titles[d]))
		end
	end
	prefix = string("plotlysupply:scene3d:", key, ":")
	existing = get(layout.fields, :annotations, nothing)
	kept = Any[]
	old = Any[]
	if existing isa AbstractVector
		for item in existing
			name = _cmn_mapping_get(item, :name)
			push!((name isa AbstractString && startswith(name, prefix)) ? old : kept, item)
		end
	end
	new = Any[]
	if !isempty(mine)
		area = _s3_plot_area(p)
		width, height = _s3_viewport(p, target)
		plot_w = max(area.width - area.l - area.r, 1.0)
		plot_h = max(area.height - area.t - area.b, 1.0)
		cx = area.l + plot_w * target.xdomain[1] + width / 2
		cy = area.t + plot_h * (1 - target.ydomain[2]) + height / 2
		for t in placed
			font = Dict{Symbol, Any}(:size => round(t.size; digits = 3))
			for name in (:color, :family)
				value = _cmn_mapping_get(fonts[t.axis], name)
				value isa AbstractString && (font[name] = String(value))
			end
			push!(new, Dict{Symbol, Any}(
				:name => string(prefix, "title:", letters[t.axis]),
				:xref => "paper", :yref => "paper",
				:x => round((cx + t.center[1] - area.l) / plot_w; digits = 6),
				:y => round(1 - (cy - t.center[2] - area.t) / plot_h; digits = 6),
				:text => t.text,
				:showarrow => false,
				:xanchor => "center", :yanchor => "middle", :align => "center",
				:textangle => round(-t.angle; digits = 2),
				:font => font,
			))
		end
	end
	changed = !isempty(updates)
	isempty(updates) || _merge_scene_layout_attr!(layout, key, attr(; updates...))
	if !(length(old) == length(new) && all(i -> old[i] == new[i], eachindex(new)))
		combined = vcat(kept, new)
		isempty(combined) ? delete!(layout.fields, :annotations) : (layout.fields[:annotations] = combined)
		changed = true
	end
	marked = _s3_write_mark!(layout, key, _s3_marked(get(layout.fields, key, nothing); titles = Tuple(titles)))
	return changed | marked
end



# Move a perspective camera to the automatic distance for the scene's box and
# viewport, keeping its direction (plotly's default direction without an eye)
# and up vector, and record it in the scene's mark as automatic. Without
# `fit_labels` the quick estimate `_s3_auto_distance` (a border of three font
# sizes for the labels, at the mark's zoom) is used and the centre is kept:
# 3-D calls write it at once, and `_s3_finalize_scenes!` refines it. With
# `fit_labels` the camera is placed by `_s3_export_camera` (box, tick labels
# and axis titles fill the viewport clear of legends over it, then the mark's
# zoom); when the mark owns
# the camera centre (`pan`; a centre at the origin is taken as owned) the fit
# starts from the origin and, with `pan`, moves the centre to centre the
# drawing; a centre the user set is kept. A centre that ends at the origin is
# removed. Returns whether the layout changed (an eye or centre that moves by
# less than 1e-6 of the distance is not rewritten).
function _s3_frame_camera!(fig, target::_CellTarget; fit_labels::Bool = false, pan::Bool = false)
	p = _cmn_plot(fig)
	key = target.scenekey
	scene = get(p.layout.fields, key, nothing)
	camera = _cmn_mapping_get(scene, :camera)
	_cmn_mapping_get(_cmn_mapping_get(camera, :projection), :type) == "orthographic" && return false
	box = _s3_drawn_box(p, key)
	box === nothing && return false
	mark = something(_s3_mark(scene), _S3_NEW_MARK)
	center = _s3_vector3(_cmn_mapping_get(camera, :center))
	eye = _cmn_mapping_get(camera, :eye)
	offset = eye === nothing ? fill(NaN, 3) : _s3_vector3(eye, NaN) .- center
	current = sqrt(sum(abs2, offset))
	direction = (isfinite(current) && current > 0) ? offset ./ current : collect(_S3_DEFAULT_EYE_DIRECTION)
	up = _s3_camera_up(camera)
	owned_center = all(iszero, center) || (mark.pan && _s3_same_point(center, mark.center))
	look_at = Tuple(center)
	if fit_labels
		start = owned_center ? _S3_ORIGIN : look_at
		distance, look_at, pads, own = _s3_fit_with_pads(fig, target, box, direction, up;
			center = start, pan = pan && owned_center, zoom = mark.zoom)
		pads_written = _s3_write_pads!(p.layout, key, pads)
		pads_written |= _s3_set_titles!(p, target, box, direction, up, look_at, distance, pads, own)
	else
		pads_written = false
		distance = _s3_auto_distance(fig, target, box, direction, up, mark.zoom; center = center)
	end
	position = look_at .+ distance .* direction
	moved = !isapprox(collect(look_at), center; rtol = 1e-6, atol = 1e-9 * distance)
	same_eye = eye !== nothing && isapprox(_s3_vector3(eye, NaN), collect(position); rtol = 1e-6)
	if !moved && same_eye
		# Unchanged: only make sure the mark records the camera as it is.
		return _s3_write_mark!(p.layout, key, _s3_marked(get(p.layout.fields, key, nothing); auto = true,
			pan = owned_center, eye = Tuple(_s3_vector3(eye, NaN)), center = Tuple(center))) | pads_written
	end
	fields = Dict{Symbol, Any}(:eye => attr(x = position[1], y = position[2], z = position[3]))
	at_origin = all(iszero, look_at)
	(moved && !at_origin) && (fields[:center] = attr(x = look_at[1], y = look_at[2], z = look_at[3]))
	_merge_scene_layout_attr!(p.layout, key, attr(camera = attr(; fields...)))
	if moved && at_origin
		_cmn_mapping_delete!(_cmn_mapping_get(get(p.layout.fields, key, nothing), :camera), (:center,))
	end
	_s3_write_mark!(p.layout, key, _s3_marked(get(p.layout.fields, key, nothing); auto = true,
		pan = owned_center, eye = Tuple(position), center = Tuple(look_at)))
	return true
end

# The scene `key` of `p` as a cell target: its layout domain (plotly's
# [0, 1] where unset).
function _s3_layout_target(p::Plot, key::Symbol)
	domain = _cmn_mapping_get(get(p.layout.fields, key, nothing), :domain)
	function bounds(axis)
		d = _cmn_mapping_get(domain, axis)
		ok = (d isa AbstractVector || d isa Tuple) && length(d) == 2 &&
			all(v -> _s3_is_real(v) && isfinite(v), d) && d[1] < d[2]
		return ok ? (Float64(d[1]), Float64(d[2])) : (0.0, 1.0)
	end
	return _CellTarget(:scene, 1, 1, :xaxis, :yaxis, "x", "y", key, bounds(:x), bounds(:y))
end

const _S3_SCENE_KEY = r"^scene([2-9]|[1-9][0-9]+)?$"
const _S3_REFIT_ROUNDS = 4

# ── Tick fonts ────────────────────────────────────────────────────────────────
#
# gl3d draws a scene tick label `tickfont.size`²/12 px large
# (`_s3_tick_text_size`), a 2-D tick label and any axis title (2-D or scene)
# `size` px. So that a scene's tick labels come out the size the style, a
# `set_fonts!` call or the user asked for (`s` px, like the 2-D panels next to
# them), a framed scene's axes get `tickfont.size = sqrt(12 s)`; the mark
# records `s` and the size written. The size asked for is the axis's
# `tickfont.size` unless it is the size PlotlySupply wrote, else
# `layout.font.size`, else the template's, else plotly's 12.
function _s3_base_font_size(p::Plot)
	size = _cmn_mapping_get(_cmn_mapping_get(p.layout.fields, :font), :size)
	(_s3_is_real(size) && isfinite(size) && size > 0) && return Float64(size)
	template = _template_object(get(p.layout.fields, :template, nothing))
	if template !== nothing
		size = _cmn_mapping_get(_field(template.layout, :font), :size)
		(_s3_is_real(size) && isfinite(size) && size > 0) && return Float64(size)
	end
	return _S3_DEFAULT_FONT_SIZE
end

# Write the compensated tick font sizes of scene `key` (see above) and record
# them in its mark; returns whether the layout changed.
function _s3_compensate_tick_fonts!(p::Plot, key::Symbol)
	scene = get(p.layout.fields, key, nothing)
	mark = something(_s3_mark(scene), _S3_NEW_MARK)
	base = _s3_base_font_size(p)
	asked = zeros(3)
	written = zeros(3)
	updates = Dict{Symbol, Any}()
	for (d, axis) in enumerate((:xaxis, :yaxis, :zaxis))
		current = _cmn_mapping_get(_cmn_mapping_get(_cmn_mapping_get(scene, axis), :tickfont), :size)
		given = _s3_is_real(current) && isfinite(current) && current > 0
		asked[d] = if given && mark.font_written[d] > 0 && isapprox(current, mark.font_written[d]; rtol = 1e-9)
			mark.font[d]
		else
			given ? Float64(current) : base
		end
		written[d] = sqrt(_S3_GL_TEXT_REFERENCE_SIZE * asked[d])
		# plotly draws an axis without a tick font at layout.font.size.
		drawn = given ? Float64(current) : base
		isapprox(drawn, written[d]; rtol = 1e-9) && continue
		updates[axis] = attr(tickfont = attr(size = written[d]))
	end
	isempty(updates) || _merge_scene_layout_attr!(p.layout, key, attr(; updates...))
	marked = _s3_write_mark!(p.layout, key, _s3_marked(get(p.layout.fields, key, nothing);
		font = Tuple(asked), font_written = Tuple(written)))
	return !isempty(updates) || marked
end

# ── Framing at finalize and export time ──────────────────────────────────────

# Frame scene `key` of `p` (see `_s3_finalize_scenes!`); returns whether the
# layout changed.
function _s3_frame_scene!(p::Plot, key::Symbol, pan::Bool)
	wrote = _s3_compensate_tick_fonts!(p, key)
	target = _s3_layout_target(p, key)
	state = _s3_scene_state(p, target)
	if !state.auto_camera
		# Titles drawn by PlotlySupply belong to the camera it framed: a camera
		# of the user's gets the scene's own titles back.
		mark = _s3_mark(get(p.layout.fields, key, nothing))
		(mark !== nothing && any(!isempty, mark.titles)) &&
			(wrote |= _s3_apply_titles!(p, target, _s3_axis_labels(p, key), nothing))
	end
	any(state.auto_ticks) || state.auto_camera || return wrote
	# The framing places the tick labels of the current counts, and the counts
	# follow the framing: repeat until neither changes (two rounds in
	# practice; the bound stops an alternation).
	for _ in 1:_S3_REFIT_ROUNDS
		changed = state.auto_camera && _s3_frame_camera!(p, target; fit_labels = true, pan = pan)
		changed |= any(state.auto_ticks) && _s3_finish_ticks!(p, target, state)
		changed |= state.auto_camera && _s3_trim_corner_ticks!(p, target)
		changed || break
		wrote = true
	end
	return wrote
end

"""
	_s3_finalize_scenes!(p::Plot, size = nothing; pan = true) -> Bool

Frame the 3-D scenes PlotlySupply manages (those with a framing mark, see
`_s3_mark`) for the figure size `size = (width, height)` px, or, when `size`
is `nothing`, for the layout's size (else the active style's default figure
size, `_style_default_figure_size`). `_finalize_figure!` runs it after every
PlotlySupply mutation (`size` = `nothing`) and on the export copy `savefig`
renders (`size` = the export size), and the 3-D constructors run it on the
figure they return, so the live window, a `savefig` at the layout size and a
`savefig` at any other size show the same framing for their size.

Per scene, in its viewport (`_s3_viewport`: the plot area left by the
margins and plotly.js's auto-margin, times the scene domain):
- the tick fonts are compensated for gl3d's quadratic tick text size
  (`_s3_compensate_tick_fonts!`);
- an automatic perspective camera (`_s3_auto_camera`) is moved, along its
  direction and with its up vector, to the closest distance at which the
  scene box and the tick labels and axis titles plotly.js draws around it
  fill the viewport, clear of any legend placed over it
  (`_s3_export_camera`, `_s3_free_region`), divided by the `view!` zoom; with
  `pan` a camera centre PlotlySupply owns moves so that the drawing is
  centred (labels often hang off one side of the box), a user's centre is
  kept;
- the automatic tick counts of a scene smaller than the plot area
  (`_s3_auto_nticks`) are recomputed.
User cameras, user tick counts and tick placements, orthographic cameras and
scenes without the mark are left alone. Running it twice writes nothing the
second time. Returns whether anything was written. Throws an `ArgumentError`
for a `size` that is not two positive finite numbers.
"""
function _s3_finalize_scenes!(p::Plot, size = nothing; pan::Bool = true)
	frame_size = if size === nothing
		nothing
	else
		((size isa Tuple || size isa AbstractVector) && length(size) == 2 &&
			all(v -> _s3_is_real(v) && isfinite(v) && v > 0, size)) || throw(ArgumentError(
			"_s3_finalize_scenes!: `size` must be (width, height) in px; got $(repr(size)).",
		))
		(Float64(size[1]), Float64(size[2]))
	end
	scenes = Symbol[]
	for (key, value) in p.layout.fields
		(key isa Symbol && occursin(_S3_SCENE_KEY, String(key)) && _s3_mark(value) !== nothing) || continue
		push!(scenes, key)
	end
	isempty(scenes) && return false
	sort!(scenes; by = String)
	return Base.ScopedValues.with(
		_S3_EXPORT_SIZE => frame_size,
		_S3_BOUNDS_CACHE => Dict{Tuple{UInt, Symbol, Int}, Any}(),
		_S3_AREA => nothing,
	) do
		area = _s3_plot_area(p)
		Base.ScopedValues.with(_S3_AREA => (p, area)) do
			wrote = false
			for key in scenes
				wrote |= _s3_frame_scene!(p, key, pan)
			end
			wrote
		end
	end
end

"""
	_s3_refit_scenes!(target::Plot, reference::Plot, size; pan = true) -> Bool

Re-frame the 3-D scenes of `target` for an export at `size = (width, height)`
px: `_s3_finalize_scenes!(target, size; pan)`. `target` is the figure about
to be rendered: a copy of `reference` (the figure as the user built it) with
a layout of its own, which is written in place; `reference` is not changed.
`_finalize_figure!` already does this on the export copy `savefig` renders,
so on such a copy this writes nothing. With `pan = false` camera centres
PlotlySupply moved return to the origin. Returns whether anything was
written. Throws an `ArgumentError` for a `size` that is not two positive
finite numbers or a `target` that shares `reference`'s layout.
"""
function _s3_refit_scenes!(target::Plot, reference::Plot, size; pan::Bool = true)
	((size isa Tuple || size isa AbstractVector) && length(size) == 2 &&
		all(v -> _s3_is_real(v) && isfinite(v) && v > 0, size)) || throw(ArgumentError(
		"_s3_refit_scenes!: `size` must be (width, height) in px; got $(repr(size)).",
	))
	target.layout === reference.layout && throw(ArgumentError(
		"_s3_refit_scenes!: `target` must have its own layout (it is written in place).",
	))
	return _s3_finalize_scenes!(target, size; pan = pan)
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
	# A camera centre PlotlySupply moved (`pan`, recorded in the mark) goes
	# back to the origin: `distance` is measured from the box centre, and an
	# automatic camera is centred again by the framing. A centre the user set
	# is kept and stays theirs.
	old = something(_s3_mark(scene), _S3_NEW_MARK)
	c = [_s3_number_field_signed(_cmn_mapping_get(camera, :center), axis) for axis in (:x, :y, :z)]
	owned_center = all(iszero, c) || (old.pan && _s3_same_point(c, old.center))
	owned_center && (c = zeros(3))
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
		distance = _s3_auto_distance(fig, target, aspect, direction, up, params.zoom; center = c)
		if from_data
			scene_fields[:aspectmode] = "manual"
			scene_fields[:aspectratio] = attr(x = aspect[1], y = aspect[2], z = aspect[3])
		end
	else
		distance = params.distance / params.zoom
	end
	written = (c[1] + distance * direction[1], c[2] + distance * direction[2], c[3] + distance * direction[3])
	camera_fields = Dict{Symbol, Any}(
		:eye => attr(x = written[1], y = written[2], z = written[3]),
		:up => attr(x = up[1], y = up[2], z = up[3]),
	)
	params.projection === nothing || (camera_fields[:projection] = attr(type = projection))
	scene_fields[:camera] = attr(; camera_fields...)
	_merge_scene_layout_attr!(p.layout, key, attr(; scene_fields...))
	owned_center && _cmn_mapping_delete!(_cmn_mapping_get(get(p.layout.fields, key, nothing), :camera), (:center,))
	# The mark: an automatic perspective camera is re-framed (at this zoom) by
	# later calls and exports; a fixed distance or an orthographic view is
	# the user's.
	automatic = projection == "perspective" && params.distance === :auto
	_s3_write_mark!(p.layout, key, _s3_marked(get(p.layout.fields, key, nothing);
		auto = automatic,
		zoom = params.zoom,
		pan = owned_center,
		eye = automatic ? written : nothing,
		center = Tuple(c),
	))
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
	      zoom = 1, row = nothing, col = nothing) -> nothing
	view!(sf::SubplotFigure; row = nothing, col = nothing, kwargs...) -> sf

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
  the scene box, seen in perspective from this direction, and the tick
  labels and axis titles plotly.js draws around it stay inside the scene's
  viewport: the figure size (`layout.width`/`height`, else the active style's
  default figure size, which is also `savefig`'s default), less the margins
  (`layout.margin` grown by plotly's auto-margin for colorbars and Cartesian
  tick labels), times the cell domain. The camera centre then moves across
  the view so that this drawing is centred (labels often hang off one side
  of the box), unless you set a centre of your own. For the "auto" and
  "data" aspect modes the data proportions are pinned with
  `aspectmode = "manual"` so the framing stays right. The framing is kept up
  to date: every later PlotlySupply call on the figure (3-D or not: new
  data, titles, fonts, `figsize!`, colorbars, ...) frames the scene again for
  its current viewport (with this call's `zoom`), and `savefig` frames it for
  the export size, so the live window, an export at the layout size and an
  export at any other size show the same framing. A legend placed over the
  scene (a subplot cell's legend sits at the cell's top right) is kept clear:
  the drawing fills the part of the viewport beside or below it. A positive
  number is the distance in plotly's normalised scene units from the camera
  centre (the box centre, unless you set a centre of your own) and is kept,
  as is a camera you set with `relayout!`.
- `up = :z`: the vertical axis, `:x`, `:y` or `:z` (matplotlib
  `vertical_axis`).
- `projection = nothing`: "perspective" or "orthographic"; `nothing` keeps the
  scene's projection.
- `zoom::Real = 1`: positive; divides the distance of a perspective view
  (also the automatic one, which already fills the viewport: `zoom > 1` crops
  the drawing at the viewport edge, `zoom < 1` leaves a border). An
  orthographic image does not depend on the distance, so there `zoom` scales
  the scene box (the aspect ratios) instead; orthographic scenes are not
  re-framed.
- `row::Integer`, `col::Integer` (`SubplotFigure` only; default: the active
  cell): the scene to point. Only that scene's camera changes.

Unknown keywords throw an `ArgumentError`.

In a scene smaller than the plot area (a subplot cell), axes whose ticks are
automatic get `nticks` from their length on screen (about one tick per 40 px,
2 to 9), because plotly.js counts ticks from the size of the whole figure and
would crowd a small scene with overlapping labels. plotly.js rounds the tick
step up, so a low count can leave a single labelled tick; a linear axis then
gets the smallest higher count (up to 9) that labels two, as long as
neighbouring labels stay at least one character apart. These counts are
updated with the framing; a count set with `scene!(; nticks)`, tick values
or a tick step is kept.

plotly.js draws a scene's tick labels `tickfont.size`²/12 px large (a 2-D
tick label `tickfont.size` px), so PlotlySupply writes `sqrt(12 s)` for the
tick font size `s` that the style, `set_fonts!` or you asked for, and scene
tick labels come out the same size as 2-D ones.

# Returns

`nothing` for a `Plot` or `SyncPlot` (the figure is changed in place), `sf`
for a `SubplotFigure`.

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
	return nothing
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
	scene!(fig; kwargs...) -> nothing
	scene!(sf::SubplotFigure; row = nothing, col = nothing, kwargs...) -> sf

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
  A one-sided limit such as `(0, nothing)` fixes one end; the other is the
  end of the scene's data widened by 1/32 of its extent, as `zrange!` gives
  it (an `ArgumentError` when the scene has no data on that axis yet).
- `xticks = nothing`, `yticks = nothing`, `zticks = nothing`: tick positions
  (data values).
- `xticklabels = nothing`, `yticklabels = nothing`, `zticklabels = nothing`:
  labels for those ticks (strings, one per tick; TeX is converted as for the
  titles).
- `row::Integer`, `col::Integer` (`SubplotFigure` only; default: the active
  cell): the scene to style.

Unknown keywords throw an `ArgumentError`.

# Returns

`nothing` for a `Plot` or `SyncPlot` (the figure is changed in place), `sf`
for a `SubplotFigure`.

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
		stored = _s3_resolve_range(fig, key, letter, stored, who)
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
	return nothing
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

A label at a point outside the scene's axis ranges is not drawn: plotly.js
hides scene annotations outside the box, where matplotlib draws text beyond
the axes. To show it, widen the range to include the point and keep the
proportions of the box with `scene!(fig; aspectratio = …)`.

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
		# Colour keywords are checked like every other colour (Z63).
		entry[key] = endswith(String(key), "color") ? _s3_color(value, who, String(key)) : value
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
	# Inside the SubplotFigure delegate (`_S3_CELL_CONTEXT`) the scratch
	# figure's colour axis replaces the figure's key by key, so a colorbar
	# written here would drop the bar the finalizer placed: `_s3_subplot!`
	# styles the merged axis instead.
	_S3_CELL_CONTEXT[] === nothing && _s3_style_coloraxis_bar!(fig, key)
	return nothing
end

# The colour axis `key`'s colorbar takes the active style's colorbar defaults
# (tick and title font sizes, outline and tick widths) where it leaves them
# unset, as a trace's own colorbar does (`_apply_style_trace_defaults!`
# skips traces bound to a colour axis, and a mutator's new colour axis was
# not there when the figure was styled). Placement keys are left as they are.
function _s3_style_coloraxis_bar!(fig, key::Symbol)
	defaults = _style_colorbar_trace_defaults(_figure_style(fig))
	isempty(defaults) && return nothing
	layout = _cmn_layout(fig)
	haskey(layout.fields, key) || return nothing
	filled, changed = _style_fill_nested(layout.fields[key],
		Dict{Symbol, Any}(:colorbar => defaults), "layout.$(key)", "_s3_write_coloraxis!")
	changed && (layout.fields[key] = filled)
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

# The style request of a 3-D call whose traces take no line or marker styling
# from the style (surfaces, meshes, cones, polygons and their edges): every
# line/marker keyword counts as explicit, so `_apply_style_trace_defaults!`
# gives the new traces only the style's colorbar defaults (tick and title font
# sizes, outline), as the 2-D colour plots get them.
const _S3_NO_LINE_STYLE = _S3StyleRequest(_STYLE_TRACE_DEFAULT_KEYWORDS, nothing)

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
	markevery = nothing,
)
	fig = Plot(traces, _s3_constructor_layout())
	foreach(spec -> _s3_write_coloraxis!(fig, spec), specs)
	_s3_apply_style!(fig, 1, something(style, _S3_NO_LINE_STYLE))
	_s3_split_markevery!(_plot_data(fig), 1, markevery)
	_s3_apply_options!(fig, opts, who; constructor = true, state = _S3_NEW_SCENE)
	_s3_colorbar_titles!(fig, 1, specs)
	# Constructors do not run `_finalize_figure!`; frame the scene as it would.
	_s3_finalize_scenes!(fig)
	return _s3_show(fig, show, opts)
end

function _s3_append!(
	fig,
	traces::Vector{GenericTrace},
	specs,
	opts::_S3Options,
	who::AbstractString;
	style::Union{Nothing, _S3StyleRequest} = nothing,
	markevery = nothing,
)
	state = _s3_mutator_state(fig, who)
	first_index = length(_plot_data(fig)) + 1
	append!(_plot_data(fig), traces)
	foreach(spec -> _s3_write_coloraxis!(fig, spec), specs)
	_s3_apply_style!(fig, first_index, something(style, _S3_NO_LINE_STYLE))
	_s3_split_markevery!(_plot_data(fig), first_index, markevery)
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
	# Validated also when `edges = false` (an invalid colour is an error
	# whether or not it is drawn).
	line_color = _s3_color(edgecolor, who, "edgecolor")
	if edges
		isempty(line_color) && (line_color = "black")
		line_color = _s3_line_color(line_color, 1.0, fig, :scene, who)
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
	_s3_apply_style!(fig, first_index, _S3_NO_LINE_STYLE)
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
- `color = ""`: one colour for the whole surface, drawn
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

""" * _S3_COLOR_VALUES_DOC * "\n"

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

# A colour keyword of `who` (`name`) as text: Symbols (`:red`) are handled as
# strings, Colorants as `_color_hex` writes them, and a vector (one colour per
# series) element by element. The text is validated where it is used
# (`_s3_color`); anything else is an `ArgumentError`.
_s3_color_text(value::AbstractVector, who::AbstractString, name::AbstractString) =
	String[_s3_color_text_scalar(c, who, "$(name)[$(i)]") for (i, c) in enumerate(value)]
_s3_color_text(value, who::AbstractString, name::AbstractString) = _s3_color_text_scalar(value, who, name)

_s3_color_text_scalar(value::Symbol, ::AbstractString, ::AbstractString) = String(value)
_s3_color_text_scalar(value::AbstractString, ::AbstractString, ::AbstractString) = String(value)
_s3_color_text_scalar(value::Colors.Colorant, who::AbstractString, name::AbstractString) =
	_color_hex(value; who = "$(who): `$(name)`")
_s3_color_text_scalar(value, who::AbstractString, name::AbstractString) = throw(ArgumentError(
	"$(who): `$(name)` must be a colour string, Symbol or Colors.jl Colorant (or a vector " *
	"of them, one per series); got $(typeof(value)).",
))

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

# matplotlib marker codes that have a scatter3d symbol: plotly.js draws only
# the eight `_S3_MARKER_SYMBOLS` in 3-D ("x" is both a code and a symbol).
const _S3_MATPLOTLIB_MARKERS = Dict{String, String}(
	"o" => "circle",
	"." => "circle",
	"s" => "square",
	"D" => "diamond",
	"d" => "diamond",
	"+" => "cross",
	"P" => "cross",
	"x" => "x",
	"X" => "x",
)

# `marker_symbol`: a scatter3d symbol or a matplotlib code; "" stays "".
function _s3_marker_symbol(value, who::AbstractString)
	(value isa AbstractString || value isa Symbol) || throw(ArgumentError(
		"$(who): `marker_symbol` must be a string or Symbol; got $(typeof(value)).",
	))
	name = String(value)
	isempty(name) && return ""
	name in _S3_MARKER_SYMBOLS && return name
	mapped = get(_S3_MATPLOTLIB_MARKERS, name, nothing)
	mapped === nothing || return mapped
	throw(ArgumentError(
		"$(who): `marker_symbol` must be one of $(join(repr.(_S3_MARKER_SYMBOLS), ", ")) or a " *
		"matplotlib code with a 3-D equivalent ($(join(sort!(collect(keys(_S3_MATPLOTLIB_MARKERS))), " "))); " *
		"got $(repr(name)). plotly.js draws no other marker symbol in a 3-D scene.",
	))
end

_s3_is_open_symbol(symbol::AbstractString) = endswith(symbol, "-open")

# The hollow variant of a scatter3d symbol; "cross" and "x" have none (they
# are drawn as strokes) and an open symbol is its own.
function _s3_open_symbol(symbol::AbstractString)
	(symbol in ("cross", "x") || _s3_is_open_symbol(symbol)) && return String(symbol)
	return symbol * "-open"
end

# `mode` with `flag` ("markers", "text") added; "none" becomes the flag.
function _s3_add_mode_flag(mode::AbstractString, flag::AbstractString)
	mode == "none" && return String(flag)
	flag in split(mode, '+') && return String(mode)
	return mode * "+" * flag
end

# The `marker` fields of one scatter3d trace (spec F17 in plotly.js gl3d
# terms). `series` is the series colour (the resolved line colour; "" when
# nothing needs it); `face` and `edge` are the validated `marker_color`
# ("none": hollow) and `marker_line_color` ("": unset), already blended.
# gl3d draws a marker as a glyph and `marker.line` as an outline around it
# (checked on renders): an open glyph is drawn in `marker.color`, so a hollow
# marker gets its edge colour there and no outline unless
# `marker_line_width` asks for one, which thickens the ring.
function _s3_marker_attr(; series::AbstractString, face::AbstractString, edge::AbstractString,
	edge_width::Float64, size, symbol::AbstractString, point::Bool)
	hollow = face == "none"
	face_given = !isempty(face) && !hollow
	hollow && (symbol = _s3_open_symbol(isempty(symbol) ? "circle" : symbol))
	marker = Dict{Symbol, Any}()
	if size > 0
		marker[:size] = size
	elseif point
		marker[:size] = _CMN_POINT_MARKER_SIZE
	end
	isempty(symbol) || (marker[:symbol] = symbol)
	line = Dict{Symbol, Any}()
	if !isempty(symbol) && _s3_is_open_symbol(symbol)
		stroke = !isempty(edge) ? edge : face_given ? face : series
		isempty(stroke) || (marker[:color] = stroke)
		if edge_width > 0
			isempty(stroke) || (line[:color] = stroke)
			line[:width] = edge_width
		end
	elseif face_given
		marker[:color] = face
		outline = isempty(edge) ? series : edge
		isempty(outline) || (line[:color] = outline)
		line[:width] = edge_width > 0 ? edge_width : _CMN_DEFAULT_MARKER_EDGE_WIDTH
	elseif !isempty(edge) || edge_width > 0
		outline = isempty(edge) ? series : edge
		isempty(outline) || (line[:color] = outline)
		line[:width] = edge_width > 0 ? edge_width : _CMN_DEFAULT_MARKER_EDGE_WIDTH
	end
	isempty(line) || (marker[:line] = attr(; line...))
	return marker
end

# A built scatter3d trace and the 1-based points that keep their markers
# (`markevery`; `nothing`: every point).
struct _S3ScatterTrace
	trace::GenericTrace
	markevery::Union{Nothing, Vector{Int}}
end

# Whether `markevery` makes a trace of this `mode` two traces
# (`_s3_split_markevery!`): the mode draws something besides the markers.
_s3_markevery_splits(mode::AbstractString) = any(!=("markers"), split(mode, '+'))

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
	marker_line_color,
	marker_line_width,
	markevery,
	linewidth,
	dash,
	opacity,
	text,
	textposition,
	textsize,
	showlegend,
	resolve_color::Bool,
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
	labels === nothing || (trace_mode = _s3_add_mode_flag(trace_mode, "text"))
	marks = markevery === nothing ? nothing :
		_markevery_fields(markevery, count; who = who)[:selectedpoints] .+ 1
	marks === nothing || (trace_mode = _s3_add_mode_flag(trace_mode, "markers"))
	line_color = _s3_color(color, who, "color")
	hollow = marker_color isa Union{AbstractString, Symbol} && lowercase(strip(String(marker_color))) == "none"
	face = hollow ? "none" : _s3_color(marker_color, who, "marker_color")
	edge = _s3_color(marker_line_color, who, "marker_line_color")
	alpha = _s3_unit_interval(opacity, who, "opacity")
	size_value = _s3_nonnegative(marker_size, who, "marker_size")
	edge_width = _s3_nonnegative(marker_line_width, who, "marker_line_width")
	width_value = _s3_nonnegative(linewidth, who, "linewidth")
	symbol = _s3_marker_symbol(marker_symbol, who)
	point = String(marker_symbol) == "."
	dash_value = _s3_dash(dash, who)
	position = textposition isa Symbol ? String(textposition) : String(textposition)
	isempty(position) || _s3_choice(position, _S3_TEXTPOSITIONS, who, "textposition")
	text_size = _s3_nonnegative(textsize, who, "textsize")

	# Translucent scatter3d lines and markers break other 3-D traces in the
	# scene, so `opacity` and colours with an alpha channel are blended over
	# the scene background instead (ADDENDUM B2). The series colour is
	# written when a marker edge or a hollow marker needs it, and when
	# `markevery` splits a series (`resolve_color` for the other series of
	# such a call), so both traces of the series and later series keep their
	# colours.
	resolve = resolve_color || hollow || !isempty(face) || !isempty(edge) || edge_width > 0 ||
		(marks !== nothing && _s3_markevery_splits(trace_mode))
	if isempty(line_color) && (alpha < 1 || resolve)
		line_color = _s3_default_color(fig, index)
	end
	line_color = _s3_line_color(line_color, alpha, fig, scenekey, who)
	hollow || (face = _s3_line_color(face, alpha, fig, scenekey, who))
	edge = _s3_line_color(edge, alpha, fig, scenekey, who)

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
	marker = _s3_marker_attr(; series = line_color, face, edge, edge_width,
		size = size_value > 0 ? marker_size : 0, symbol, point)
	isempty(marker) || (fields[:marker] = attr(; marker...))
	if labels !== nothing
		fields[:text] = labels
		isempty(position) || (fields[:textposition] = position)
		text_size > 0 && (fields[:textfont] = attr(size = textsize))
	end
	showlegend === nothing || (fields[:showlegend] = showlegend)
	return _S3ScatterTrace(GenericTrace("scatter3d"; fields...), marks)
end

# Replace each trace `data[first_index + k - 1]` that has `marks[k]` (points
# that keep their markers) by what `markevery` draws. With lines or text: the
# trace without markers (every point, no legend entry), followed by a trace
# of the kept points with the same line and marker style that carries the
# legend entry (so it shows line and marker, as in matplotlib); its points are
# separated by gaps, so it draws no line, and it has no hover of its own.
# Otherwise the trace keeps only those points. Run after the style defaults,
# so both traces share the series' cycle position. Returns the number of
# traces added.
function _s3_split_markevery!(data::AbstractVector, first_index::Int, marks)
	marks === nothing && return 0
	added = 0
	for (k, kept) in enumerate(marks)
		kept === nothing && continue
		position = first_index + k - 1 + added
		fields = data[position].fields
		flags = split(String(fields[:mode]), '+')
		rest = filter(!=("markers"), flags)
		if isempty(rest)
			subset = copy(fields)
			for key in (:x, :y, :z)
				subset[key] = fields[key][kept]
			end
			data[position] = GenericTrace(subset)
			continue
		end
		has_lines = "lines" in flags
		base = copy(fields)
		base[:mode] = join(rest, '+')
		base[:showlegend] = false
		delete!(base, :marker)
		marked = copy(fields)
		for key in (:text, :textposition, :textfont)
			delete!(marked, key)
		end
		marked[:mode] = has_lines ? "lines+markers" : "markers"
		has_lines || delete!(marked, :line)
		marked[:hoverinfo] = "skip"
		for key in (:x, :y, :z)
			values = fields[key]
			if has_lines
				gapped = Vector{Union{Nothing, Float64}}(undef, 2length(kept))
				for (m, point) in enumerate(kept)
					gapped[2m - 1] = _s3_gap_value(values[point])
					gapped[2m] = _GAP
				end
				marked[key] = gapped
			else
				marked[key] = values[kept]
			end
		end
		data[position] = GenericTrace(base)
		insert!(data, position + 1, GenericTrace(marked))
		added += 1
	end
	return added
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
	marker_line_color,
	marker_line_width,
	markevery,
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
	color = _s3_color_text(color, who, "color")
	marker_color = _s3_color_text(marker_color, who, "marker_color")
	marker_line_color = _s3_color_text(marker_line_color, who, "marker_line_color")
	z_nested, x_nested = _nested_coordinate_mode(z, x, :z, :x)
	_, y_nested = _nested_coordinate_mode(z, y, :z, :y)
	start = _s3_next_index(fig)
	if !z_nested
		single_mode = _first_or_empty(mode)
		built = _s3_scatter3d_trace(
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
			marker_line_color = _first_or_empty(marker_line_color),
			marker_line_width = _scalar_or_first(marker_line_width, 0),
			markevery,
			linewidth = _scalar_or_first(linewidth, 0),
			dash = _first_or_empty(dash),
			opacity = _scalar_or_first(opacity, 1),
			text = text,
			textposition = _first_or_empty(textposition),
			textsize = _scalar_or_first(textsize, 0),
			showlegend = _scalar_or_first(showlegend, nothing),
			resolve_color = false,
			scenekey = :scene,
			who,
		)
		marks = built.markevery === nothing ? nothing : Union{Nothing, Vector{Int}}[built.markevery]
		return GenericTrace[built.trace], marks
	end
	n = length(z)
	modes = _series_kwarg_vector(mode, n, "lines", String)
	colors = _series_kwarg_vector(color, n, "", String)
	legends = _series_kwarg_vector(legend, n, "", String)
	sizes = _series_kwarg_vector(marker_size, n, 0, Real)
	symbols = _series_kwarg_vector(marker_symbol, n, "", String)
	marker_colors = _series_kwarg_vector(marker_color, n, "", String)
	edge_colors = _series_kwarg_vector(marker_line_color, n, "", String)
	edge_widths = _series_kwarg_vector(marker_line_width, n, 0, Real)
	# As in plot_scatter: with several series a vector gives one entry per
	# series and anything else applies to every series.
	every = markevery isa AbstractVector ? _series_kwarg_vector(markevery, n, nothing, Any) : fill(markevery, n)
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
	series_modes = String[isempty(modes[k]) ? "lines" : modes[k] for k in 1:n]
	# A series that `markevery` splits into two traces shifts the default
	# colours of the later series, so every series of such a call gets its
	# default colour written explicitly.
	resolve = any(1:n) do k
		every[k] === nothing && return false
		trace_mode = _s3_mode(series_modes[k], who)
		texts[k] === nothing || (trace_mode = _s3_add_mode_flag(trace_mode, "text"))
		return _s3_markevery_splits(_s3_add_mode_flag(trace_mode, "markers"))
	end
	traces = Vector{GenericTrace}(undef, n)
	marks = Vector{Union{Nothing, Vector{Int}}}(nothing, n)
	for (k, series) in enumerate(eachindex(z))
		built = _s3_scatter3d_trace(
			fig,
			start + k - 1,
			x_nested ? x[series] : x,
			y_nested ? y[series] : y,
			z[series];
			mode = series_modes[k],
			color = colors[k],
			legend = legends[k],
			marker_size = sizes[k],
			marker_symbol = symbols[k],
			marker_color = marker_colors[k],
			marker_line_color = edge_colors[k],
			marker_line_width = edge_widths[k],
			markevery = every[k],
			linewidth = widths[k],
			dash = dashes[k],
			opacity = alphas[k],
			text = texts[k],
			textposition = positions[k],
			textsize = text_sizes[k],
			showlegend = visibility[k],
			resolve_color = resolve,
			scenekey = :scene,
			who,
		)
		traces[k] = built.trace
		marks[k] = built.markevery
	end
	return traces, (all(isnothing, marks) ? nothing : marks)
end

function plot_scatter3d(
	x::AbstractVector,
	y::AbstractVector,
	z::AbstractVector;
	mode::Union{Nothing, AbstractString, AbstractVector{<:AbstractString}} = nothing,
	color = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	marker_size::Union{Real, AbstractVector{<:Real}} = 0,
	marker_symbol::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	marker_color = "",
	marker_line_color = "",
	marker_line_width::Union{Real, AbstractVector{<:Real}} = 0,
	markevery = nothing,
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
	traces, marks = _s3_scatter3d_traces(nothing, x, y, z; mode, color, legend, marker_size, marker_symbol,
		marker_color, marker_line_color, marker_line_width, markevery, linewidth, dash, opacity, text,
		textposition, textsize, showlegend, who)
	return _s3_construct(traces, (), opts, who, show; style = _s3_scatter3d_style(mode), markevery = marks)
end

function plot_scatter3d!(
	fig,
	x::AbstractVector,
	y::AbstractVector,
	z::AbstractVector;
	mode::Union{Nothing, AbstractString, AbstractVector{<:AbstractString}} = nothing,
	color = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	marker_size::Union{Real, AbstractVector{<:Real}} = 0,
	marker_symbol::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	marker_color = "",
	marker_line_color = "",
	marker_line_width::Union{Real, AbstractVector{<:Real}} = 0,
	markevery = nothing,
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
	traces, marks = _s3_scatter3d_traces(fig, x, y, z; mode, color, legend, marker_size, marker_symbol,
		marker_color, marker_line_color, marker_line_width, markevery, linewidth, dash, opacity, text,
		textposition, textsize, showlegend, who)
	return _s3_append!(fig, traces, (), opts, who; style = _s3_scatter3d_style(mode), markevery = marks)
end

const _S3_SCATTER3D_KEYWORDS_DOC = raw"""
- `mode = nothing`: "lines", "markers", "lines+markers", "text", "none" or
  another "+"-joined combination (`nothing` and `""` mean "lines"; when
  `mode` is not given, a `PlotStyle` with a marker cycle adds markers).
- `color = ""`: line colour (the markers use it too unless `marker_color`
  is set); `""` takes the next colorway colour.
- `legend = ""`: legend name.
- `showlegend = nothing`: `true`/`false` shows or hides the legend entry.
- `linewidth = 0`: line width in px (0: the active `PlotStyle`'s, else
  plotly's default).
- `dash = ""`: "solid", "dot", "dash", "longdash", "dashdot" or
  "longdashdot" (`""`: the style's dash cycle, else solid).
- `marker_size = 0`: marker size in px (0: the style's, else plotly's
  default).
- `marker_symbol = ""`: "circle", "circle-open", "cross", "diamond",
  "diamond-open", "square", "square-open" or "x" (plotly.js draws no other
  symbol in 3-D), or the matplotlib code of one of them: "o" and "."
  (circle; "." is 4 px unless `marker_size` is set), "s" (square), "D" and
  "d" (diamond), "+" and "P" (cross), "x" and "X" (x). `""`: the style's
  marker cycle, else plotly's default circle.
- `marker_color = ""`: marker face colour (`""`: the series colour, i.e.
  `color`, else the colorway colour). `"none"` draws hollow markers: the
  symbol becomes its "-open" variant (a circle when unset; "cross" and "x"
  stay as they are) in `marker_line_color`, else the series colour. A face
  colour gets an outline in `marker_line_color`, else the series colour,
  1.5 px wide, as matplotlib draws `markerfacecolor = "white"`.
- `marker_line_color = ""`, `marker_line_width = 0`: colour and width in px
  of the marker outline (matplotlib `markeredgecolor`/`markeredgewidth`);
  either one alone draws an outline, in the series colour or 1.5 px wide. On
  an open symbol a width thickens the ring.
- `markevery = nothing`: markers only at some points (`mode` gains
  "markers"): an integer step `k` (points `1:k:n`), a range or vector of
  1-based indices, or a `Bool` mask. scatter3d cannot hide single markers,
  so a series whose mode also draws lines or text becomes two traces: that
  part over every point without a legend entry, then the marked points with
  the same line and marker style, which carry the legend entry (line and
  marker, as in matplotlib) and draw no line between them. A markers-only
  series just keeps the marked points. Both traces get the series' colour
  and style-cycle entries, and every series of such a call gets its default
  colour written out; the extra trace still counts for the colorway and
  style cycles of traces that later calls add.
- `opacity = 1`: in [0, 1]; """ * _S3_OPACITY_LINE_DOC * raw""" Markers and their outlines are blended the same way.
- `text = nothing`: point labels, one string per point or one string for all
  points; adds "text" to `mode`. They are drawn by WebGL like the axis
  titles, so TeX is converted as described below.
- `textposition = ""`: "top left", "top center", "top right", "middle left",
  "middle center", "middle right", "bottom left", "bottom center" or
  "bottom right" (`""`: plotly's default).
- `textsize = 0`: label font size in px (0: the figure's).

`mode`, `color`, `legend`, `showlegend`, `linewidth`, `dash`, `marker_size`,
`marker_symbol`, `marker_color`, `marker_line_color`, `marker_line_width`,
`opacity`, `textposition` and `textsize` also take a vector with one entry
per series (missing entries take the default, extra entries are ignored);
with several series `text` is a vector of per-series label vectors and a
vector `markevery` gives one entry per series (`nothing`, a step, indices or
a mask), while any other `markevery` applies to every series.

""" * _S3_COLOR_VALUES_DOC * raw"""

""" * _S3_OUTSIDE_RANGE_DOC * raw"""

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
	# Shaft and head share one opaque colour (ADDENDUM B2).
	arrow_color = _s3_line_color(arrow_color, 1.0, fig, :scene, who)
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
	color = "",
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
	color = "",
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
- `color = ""`: one colour for every cone or arrow; a
  vector of colours is accepted for compatibility and its first entry is
  used. With `""` cones are coloured by their vector norm through the colour
  keywords and arrows take the next colorway colour. Arrows have one colour,
  so the colour keywords apply to cones only. A `color` combined with
  `colorscale` wins, as in 1.x, with a warning that `colorscale` is ignored;
  combined with the other colour keywords it throws.
- `legend::AbstractString = ""`: legend name.

""" * _S3_COLOR_VALUES_DOC * " Cones (`style = :cone`) are surfaces, not lines: their `color` is written to the one-colour colour scale as given, alpha channel included, without blending.\n\n" *
	_S3_OUTSIDE_RANGE_DOC * "\n"

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

# Edge colour and width of mesh3d/polygons3d faces; a translucent edge colour
# is blended over the scene background (`_s3_line_color`). `default` replaces
# an unset colour ("" keeps it unset).
function _s3_edge_style(edgecolor, edgewidth, fig, who::AbstractString; default::AbstractString = "")
	color = _s3_color(edgecolor, who, "edgecolor")
	isempty(color) && (color = default)
	width = _s3_nonnegative(edgewidth, who, "edgewidth")
	return _s3_line_color(color, 1.0, fig, :scene, who), width
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
	# Validated also when `edges = false`.
	_s3_color(edgecolor, who, "edgecolor")
	if edges
		face_count === nothing && throw(ArgumentError(
			"$(who): `edges=true` needs explicit triangles (`i`, `j`, `k`).",
		))
		line_color, line_width = _s3_edge_style(edgecolor, edgewidth, fig, who; default = "black")
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
- `color = ""`: one colour for the whole mesh.
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

""" * _S3_COLOR_VALUES_DOC * "\n"

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
	line_color, line_width = _s3_edge_style(edgecolor, edgewidth, fig, who)
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
- `color = ""`: one colour for every face when no `values`
  are given (`""`: the next colorway colour).
- `opacity::Real = 1`: in [0, 1].
- `lighting = :flat`: `:flat` (unshaded, like matplotlib), `:default`
  (plotly's shading) or a NamedTuple of plotly lighting fields.
- `edgecolor = "black"`: colour of the polygon boundaries (`""`: none). Only
  the polygon edges are drawn, not the triangulation diagonals, each edge once
  as an opaque line trace.
- `edgewidth::Real = 1`: width of the edges in px (0: none).
- `legend::AbstractString = ""`: legend name.

""" * _S3_COLOR_VALUES_DOC * "\n"

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

""" * _S3_COLOR_VALUES_DOC * "\n\n" * _S3_OUTSIDE_RANGE_DOC * "\n"

const _S3_WIREFRAME_KEYWORDS_DOC = raw"""
- `rstride::Integer = 1`, `cstride::Integer = 1`: draw every `rstride`-th
  line of constant `i` and every `cstride`-th line of constant `j` (the last
  line is always drawn); 0 skips that direction.
- `color = "black"`: line colour.
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
- `color = "#999999"`: line colour.
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
	# One-sided limits (D11) are resolved against the whole cell's data after
	# the delegate added the new traces (its staging figure holds only those).
	limits = Tuple{Char, Symbol, Any}[]
	for (key, axis) in ((:xrange, :xaxis), (:yrange, :yaxis), (:zrange, :zaxis))
		haskey(options, key) || continue
		checked = _s3_range(options[key], who, String(key))
		checked === nothing && continue
		stored = _s3_stored_range(layout, target.scenekey, axis, checked, who, String(key))
		if _is_one_sided_range(stored)
			push!(limits, (String(axis)[1], axis, stored))
			delete!(options, key)
		else
			options[key] = stored
		end
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
		# `delegate_who` names the public mutator in the delegate's own errors
		# and warnings (`wrapped` is a closure).
		_with_style_trace_offset(staged) do
			_subplot_delegate_mutator_impl!(staged, wrapped, args...; row, col, secondary_y,
				delegate_who = who, options...)
		end
		if extra_axis !== nothing
			fields = captured[] === nothing ? Dict{Symbol, Any}() : _symbol_dict(captured[])
			_s3_write_coloraxis!(staged, _S3ColorSpec(Dict{Symbol, Any}(), extra_axis, fields))
			# The delegate converted the math titles before this axis had its
			# colorbar settings.
			_colorbar_math_titles!(staged, (); coloraxes = (extra_axis,))
		end
		# The style's colorbar defaults, on the merged colour axis (see
		# `_s3_write_coloraxis!`).
		axis_id === nothing || _s3_style_coloraxis_bar!(staged, Symbol(axis_id))
		retitle && _cbar_remove_title_annotation!(_cmn_plot(staged), axis_id)
		shared && _s3_link_shared_surfaces!(_cmn_plot(staged), colorscale_given)
		cell = _s3_scene_target(staged, who)
		for (letter, axis, stored) in limits
			value = _axes_scene_limit_range(staged, cell.scenekey, letter, stored, who)
			_merge_scene_layout_attr!(_cmn_layout(staged), cell.scenekey,
				attr(; axis => attr(range = value)))
		end
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
