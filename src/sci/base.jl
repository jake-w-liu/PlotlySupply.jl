# Shared primitives for the `src/sci/*.jl` extension files and for the core
# constructors in api.jl. Kept dependency-free so every other file can use it.

# Gap marker for PlotlySupply-generated multi-segment traces (quiver shafts,
# segment collections, polygon rings, wireframes). Plotly treats JSON `null`
# exactly like a non-finite number (a gap, since `connectgaps` defaults to
# false), but unlike `NaN` it survives every strict-JSON serializer.
const _GAP = nothing

# `[0, 0]` (or `(0, 0)`) is the package-wide "automatic range" sentinel;
# `nothing` is accepted as an explicit synonym.
function _is_auto_range(range)
	range === nothing && return true
	(range isa AbstractVector || range isa Tuple) || return false
	length(range) == 2 || return false
	lower, upper = range[1], range[2]
	return lower isa Real && upper isa Real && iszero(lower) && iszero(upper)
end

# Validate a user-supplied axis/colour range and return it as a 2-element
# vector, or `nothing` when it is the automatic sentinel. `who` names the
# calling function and `name` the keyword, for the error message.
function _checked_range(range, who::AbstractString, name::AbstractString)
	_is_auto_range(range) && return nothing
	(range isa AbstractVector || range isa Tuple) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a 2-element vector or tuple; got $(typeof(range)).",
		))
	length(range) == 2 ||
		throw(ArgumentError(
			"$(who): `$(name)` must have exactly 2 elements (lower, upper); got $(length(range)).",
		))
	lower, upper = range[1], range[2]
	for bound in (lower, upper)
		bound isa Real && !isfinite(bound) &&
			throw(ArgumentError(
				"$(who): `$(name)` bounds must be finite; got $(repr(range)).",
			))
	end
	return Any[lower, upper]
end

# Figure and axis titles are stored in Plotly's canonical nested form so later
# `relayout!(fig; title_x = ..., title_font_size = ...)` edits merge instead of
# hitting a bare String. Returns `nothing` for an empty title (nothing is
# written to the layout).
function _title_attr(text::AbstractString)
	isempty(text) && return nothing
	return attr(text = String(text))
end

# ── Figure-option primitives ────────────────────────────────────────────────
# Every constructor and mutator applies its common keywords (`title`, `xlabel`,
# `xscale`, `xrange`, `width`, `fontsize`, `grid`, …) through these helpers so
# the behaviour is identical across plot families. They address the PRIMARY
# Cartesian axes (`xaxis`/`yaxis`): those are the axes a constructor creates,
# the axes a mutator's traces are appended to, and the axes the SubplotFigure
# delegate transplants into the target cell. Each helper validates before it
# writes and writes nested keys, so existing styling (title position, fonts,
# tick settings) is merged rather than replaced.

_axis_layout_key(letter::Symbol) =
	letter === :x ? :xaxis :
	letter === :y ? :yaxis :
	throw(ArgumentError("axis letter must be :x or :y; got $(repr(letter))."))

function _require_size_option(value, who::AbstractString, name::AbstractString)
	(value isa Real && !(value isa Bool) && isfinite(value) && value >= 0) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a non-negative finite number " *
			"(0 means automatic); got $(repr(value)).",
		))
	return value
end

# `width` / `height` in CSS pixels; 0 leaves the dimension automatic.
function _apply_figure_size!(fig, who::AbstractString; width = 0, height = 0)
	_require_size_option(width, who, "width")
	_require_size_option(height, who, "height")
	width > 0 && relayout!(fig, width = width)
	height > 0 && relayout!(fig, height = height)
	return nothing
end

# Global font size in pixels; 0 keeps the template default.
function _apply_figure_fontsize!(fig, who::AbstractString, fontsize)
	_require_size_option(fontsize, who, "fontsize")
	fontsize > 0 && relayout!(fig, font_size = fontsize)
	return nothing
end

# Figure title; an empty title leaves the layout untouched.
function _apply_figure_title!(fig, title::AbstractString)
	isempty(title) && return nothing
	relayout!(fig, title_text = _label(title))
	return nothing
end

# Title of the primary x or y axis; an empty label leaves the axis untouched.
function _apply_axis_title!(fig, letter::Symbol, label::AbstractString)
	isempty(label) && return nothing
	key = _axis_layout_key(letter)
	relayout!(fig; Symbol(key, :_title_text) => _label(label))
	return nothing
end

# Plotly Cartesian axis types accepted by the `xscale` / `yscale` keywords.
# These are the complete `layout.xaxis.type` enumeration of plotly.js.
const _AXIS_SCALE_TYPES = ("linear", "log", "date", "category", "multicategory", "-")

# Axis scale of the primary x or y axis. `""` leaves the axis type unchanged.
# A logarithmic axis gets power-of-ten tick labels (10², not "100" / "1µ")
# unless an exponent format was already chosen.
function _apply_axis_scale!(
	fig,
	letter::Symbol,
	scale::AbstractString,
	who::AbstractString,
)
	isempty(scale) && return nothing
	name = letter === :x ? "xscale" : "yscale"
	scale in _AXIS_SCALE_TYPES ||
		throw(ArgumentError(
			"$(who): `$(name)` must be one of $(join(repr.(_AXIS_SCALE_TYPES), ", ")) " *
			"or \"\" (unchanged); got $(repr(scale)).",
		))
	key = _axis_layout_key(letter)
	relayout!(fig; Symbol(key, :_type) => String(scale))
	if scale == "log"
		axis = get(_plot_layout(fig).fields, key, nothing)
		existing = axis === nothing ? nothing : get(axis, :exponentformat, nothing)
		(existing === nothing || (existing isa AbstractDict && isempty(existing))) &&
			relayout!(fig; Symbol(key, :_exponentformat) => "power")
	end
	return nothing
end

# Range of the primary x or y axis, given in DATA units on every axis type.
# Plotly stores the range of a logarithmic axis as log10 exponents, so the
# bounds are converted there (non-positive bounds are an error). The automatic
# sentinel (`[0, 0]`, `(0, 0)`, `nothing`) leaves the axis autoranging. Apply
# the axis scale before the range so the conversion sees the final axis type.
function _apply_axis_range!(
	fig,
	letter::Symbol,
	range,
	who::AbstractString,
)
	name = letter === :x ? "xrange" : "yrange"
	checked = _checked_range(range, who, name)
	checked === nothing && return nothing
	key = _axis_layout_key(letter)
	layout = _plot_layout(fig)
	value = _axis_type(layout, key) == "log" ?
		_to_axis_range(layout, key, checked; who = "$(who) (`$(name)`)") :
		checked
	relayout!(
		fig;
		Symbol(key, :_range) => value,
		Symbol(key, :_autorange) => false,
	)
	return nothing
end

# Grid visibility of the primary axes. `nothing` leaves the grid unchanged,
# `true` / `false` switch both axes, and `:x`, `:y`, `:both`, `:none` select
# which axes show grid lines.
function _apply_axis_grid!(fig, grid, who::AbstractString)
	grid === nothing && return nothing
	show_x, show_y = if grid isa Bool
		(grid, grid)
	elseif grid === :both
		(true, true)
	elseif grid === :none
		(false, false)
	elseif grid === :x
		(true, false)
	elseif grid === :y
		(false, true)
	else
		throw(ArgumentError(
			"$(who): `grid` must be true, false, nothing, :x, :y, :both or :none; " *
			"got $(repr(grid)).",
		))
	end
	relayout!(fig, xaxis_showgrid = show_x, yaxis_showgrid = show_y)
	return nothing
end

function _require_axis_scale(scale::AbstractString, who::AbstractString, name::AbstractString)
	(isempty(scale) || scale in _AXIS_SCALE_TYPES) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be one of $(join(repr.(_AXIS_SCALE_TYPES), ", ")) " *
			"or \"\" (unchanged); got $(repr(scale)).",
		))
	return scale
end

function _require_grid_option(grid, who::AbstractString)
	(grid === nothing || grid isa Bool || grid in (:x, :y, :both, :none)) ||
		throw(ArgumentError(
			"$(who): `grid` must be true, false, nothing, :x, :y, :both or :none; " *
			"got $(repr(grid)).",
		))
	return grid
end

# Range check that also knows the axis type the call will end up with: the
# requested `scale` when one is given, otherwise the axis's current type.
function _require_axis_range(
	fig,
	letter::Symbol,
	range,
	scale::AbstractString,
	who::AbstractString,
)
	name = letter === :x ? "xrange" : "yrange"
	checked = _checked_range(range, who, name)
	checked === nothing && return nothing
	key = _axis_layout_key(letter)
	final_type = isempty(scale) ? _axis_type(_plot_layout(fig), key) : scale
	if final_type == "log"
		for bound in checked
			(bound isa Real && bound > 0) ||
				throw(ArgumentError(
					"$(who): `$(name)` bounds on a logarithmic axis are data values " *
					"and must be positive; got $(repr(range)).",
				))
		end
	end
	return checked
end

# Validate the common Cartesian keywords of a constructor or mutator without
# touching the figure. Call this before the first write; the `_apply_*`
# helpers above then cannot fail half-way.
function _validate_cartesian_options(
	fig,
	who::AbstractString;
	xrange = nothing,
	yrange = nothing,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid = nothing,
)
	_require_axis_scale(xscale, who, "xscale")
	_require_axis_scale(yscale, who, "yscale")
	_require_axis_range(fig, :x, xrange, xscale, who)
	_require_axis_range(fig, :y, yrange, yscale, who)
	_require_size_option(width, who, "width")
	_require_size_option(height, who, "height")
	_require_size_option(fontsize, who, "fontsize")
	_require_grid_option(grid, who)
	return nothing
end
