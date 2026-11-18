# Shared primitives for the `src/sci/*.jl` extension files and for the core
# constructors in api.jl. Kept dependency-free so every other file can use it
# (Dates is a standard library: date bounds of one-sided axis limits).

import Dates

# Gap marker for PlotlySupply-generated multi-segment traces (quiver shafts,
# segment collections, polygon rings, wireframes). Plotly treats JSON `null`
# exactly like a non-finite number (a gap, since `connectgaps` defaults to
# false), but unlike `NaN` it survives every strict-JSON serializer.
const _GAP = nothing

# Tick presets accepted wherever tick values are (`xticks!`/`yticks!`, the
# `xticks`/`yticks` keywords): `:decades` labels a logarithmic axis at powers of
# ten only, with unlabelled minor ticks; `:auto` restores Plotly's automatic
# ticks. Family validators pass a preset through to `_apply_ticks!` unchanged.
const _TICK_PRESETS = (:decades, :auto)
_is_tick_preset(value) = value isa Symbol && value in _TICK_PRESETS

# `[0, 0]` (or `(0, 0)`) is the package-wide "automatic range" sentinel;
# `nothing` and `[nothing, nothing]` are accepted as explicit synonyms.
function _is_auto_range(range)
	range === nothing && return true
	(range isa AbstractVector || range isa Tuple) || return false
	length(range) == 2 || return false
	lower, upper = range[1], range[2]
	(lower === nothing && upper === nothing) && return true
	return lower isa Real && upper isa Real &&
		!(lower isa Bool) && !(upper isa Bool) &&
		iszero(lower) && iszero(upper)
end

# Validate a user-supplied axis/colour range and return it as a 2-element
# vector, or `nothing` when it is the automatic sentinel. `who` names the
# calling function and `name` the keyword, for the error message.
#
# Rejected (ArgumentError, nothing is written by the caller): anything but a
# 2-element vector/tuple, `Bool` bounds, non-finite numbers and equal bounds
# (an empty axis; also for the axis keywords of every family, G33). A reversed
# range (`upper < lower`) is valid: it flips the axis, as matplotlib's
# `set_xlim(hi, lo)`. Bounds are not otherwise typed here: date axes take
# strings or dates, and callers check what their axis or colour scale needs
# (`_require_axis_range`, `_apply_axis_range!`).
#
# One-sided limits (lead decision D11): with `partial = true` (axis ranges)
# one bound may be `nothing` - `(lo, nothing)` fixes the start of the axis and
# `(nothing, hi)` its end (matplotlib `set_xlim(left = lo)`), the other end
# autoranges; the result keeps the `nothing`. `(nothing, nothing)` is the
# automatic sentinel. An open bound is spelled `nothing`; `missing` is an
# ArgumentError. Without `partial` (colour ranges) a `nothing`/`missing` bound
# is an ArgumentError.
function _checked_range(
	range,
	who::AbstractString,
	name::AbstractString;
	partial::Bool = false,
)
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
		if bound === nothing || bound === missing
			partial || throw(ArgumentError(
				"$(who): `$(name)`: partial ranges are not supported; give both " *
				"bounds, or [0, 0] / `nothing` for an automatic range. Got $(repr(range)).",
			))
			bound === missing && throw(ArgumentError(
				"$(who): `$(name)`: an open bound of a one-sided limit is written " *
				"`nothing`, e.g. (0, nothing); got $(repr(range)).",
			))
			continue
		end
		bound isa Bool &&
			throw(ArgumentError(
				"$(who): `$(name)` range bounds must be numbers (or date/category " *
				"values), not Bool; got $(repr(range)).",
			))
		bound isa Real && !isfinite(bound) &&
			throw(ArgumentError(
				"$(who): `$(name)` bounds must be finite; got $(repr(range)).",
			))
	end
	isequal(lower, upper) &&
		throw(ArgumentError(
			"$(who): `$(name)`: the range bounds must differ; got $(repr(range)) " *
			"(use [0, 0] or `nothing` for an automatic range).",
		))
	return Any[lower, upper]
end

# Whether a range returned by `_checked_range(...; partial = true)` is a
# one-sided limit (exactly one bound is `nothing`).
_is_one_sided_range(checked) =
	checked !== nothing && (checked[1] === nothing || checked[2] === nothing)

# plotly.js date strings (lib/dates.js `dateTime2ms`): a year, then optional
# month, day, hour, minutes and seconds with a fraction, `T` or a space before
# the time, and an optional time-zone suffix, which plotly.js ignores.
const _PLOTLY_DATE_PATTERN = r"^\s*(\d{4})(?:-(\d{1,2})(?:-(\d{1,2})(?:[ Tt](\d{1,2})(?::(\d{2})(?::(\d{2})(\.\d+)?)?)?(?:[Zz]|[+\-]\d{2}(?::?\d{2})?)?)?)?)?\s*$"

# Milliseconds since 1970-01-01 (plotly.js's numeric date units) of a date
# bound: a `Date`, a `DateTime`, a plotly.js date string, or a number (already
# milliseconds). An unreadable value is an ArgumentError naming `who`/`name`.
function _date_bound_ms(bound, who::AbstractString, name::AbstractString)
	_is_plain_real(bound) && return Float64(bound)
	epoch = Dates.DateTime(1970, 1, 1)
	bound isa Dates.DateTime && return Float64(Dates.value(bound - epoch))
	bound isa Dates.Date && return Float64(Dates.value(Dates.DateTime(bound) - epoch))
	m = bound isa AbstractString ? match(_PLOTLY_DATE_PATTERN, bound) : nothing
	m === nothing && throw(ArgumentError(
		"$(who): `$(name)`: $(repr(bound)) is not a date; a bound on a date axis " *
		"is a Date, a DateTime, a \"yyyy-mm-dd[ HH:MM[:SS]]\" string or " *
		"milliseconds since 1970.",
	))
	part(i, default) = m.captures[i] === nothing ? default : parse(Int, m.captures[i])
	fields = (part(1, 0), part(2, 1), part(3, 1), part(4, 0), part(5, 0), part(6, 0))
	valid = 1 <= fields[2] <= 12 && 1 <= fields[3] <= Dates.daysinmonth(fields[1], fields[2]) &&
		fields[4] <= 23 && fields[5] <= 59 && fields[6] <= 59
	valid || throw(ArgumentError(
		"$(who): `$(name)`: $(repr(bound)) is not a valid calendar date and time.",
	))
	fraction = m.captures[7] === nothing ? 0.0 : parse(Float64, m.captures[7])
	return Float64(Dates.value(Dates.DateTime(fields...) - epoch)) + 1000 * fraction
end

# The fixed bound of a one-sided limit in the units plotly.js reads in
# `autorangeoptions.minallowed/maxallowed`: log10 of the (positive) data value
# on a log axis, milliseconds on a date axis (plotly.js 2.35.2 ignores a date
# string there: render probe p04 autoranged a date axis with
# `minallowed = "2020-01-01"` to 2000-2001, and honoured 1577836800000), the
# number itself on linear and category axes. On an autotyped axis a number is
# kept and a date value converted.
function _axis_limit_bound(axis_type::AbstractString, bound, who::AbstractString, name::AbstractString)
	if axis_type == "log"
		(_is_plain_real(bound) && bound > 0) || throw(ArgumentError(
			"$(who): `$(name)` bounds on a logarithmic axis are data values and " *
			"must be positive; got $(repr(bound)).",
		))
		return log10(Float64(bound))
	elseif axis_type == "date" || (axis_type == "-" && !(bound isa Real))
		return _date_bound_ms(bound, who, name)
	end
	_is_plain_real(bound) || throw(ArgumentError(
		"$(who): `$(name)` bounds on a $(axis_type) axis must be numbers; got $(repr(bound)).",
	))
	return bound
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

# Figure title of a constructor's `title` keyword: the placement `title!`
# gives it (Z28: centred over the plot area, `xref = "paper"`, pinned 10 px
# below the top of the figure with `yref = "container"`, `yanchor = "top"` and
# `automargin`, so the plot area moves down instead of overlapping it), not
# plotly's template position at the left. An empty title leaves the layout
# untouched. The label is converted first (`_label`), so an invalid label
# raises the converter's own `ArgumentError` before anything is written.
function _apply_figure_title!(fig, title::AbstractString)
	isempty(title) && return nothing
	_label(title)
	_text_figure_title!(fig, title, :center, 0.0, false, (0, 0))
	return nothing
end

# Title of the primary x or y axis; an empty label leaves the axis untouched.
function _apply_axis_title!(fig, letter::Symbol, label::AbstractString)
	return _apply_axis_title_to_key!(fig, _axis_layout_key(letter), label)
end

# `_apply_axis_title!` for any Cartesian axis `key` (e.g. a twin y axis).
function _apply_axis_title_to_key!(fig, key::Symbol, label::AbstractString)
	isempty(label) && return nothing
	relayout!(fig; Symbol(key, :_title_text) => _label(label))
	return nothing
end

# Plotly Cartesian axis types accepted by the `xscale` / `yscale` keywords.
# These are the complete `layout.xaxis.type` enumeration of plotly.js.
const _AXIS_SCALE_TYPES = ("linear", "log", "date", "category", "multicategory", "-")

# Axis types whose `range` plotly.js reads as numbers: positions on linear
# axes, log10 exponents on log axes, 0-based category indices on category
# axes. Date axes (and autotyped "-" axes, which may become date axes) also
# take date strings.
const _NUMERIC_RANGE_AXIS_TYPES = ("linear", "log", "category", "multicategory")

_axis_range_name(letter::Symbol) = letter === :x ? "xrange" : "yrange"
_axis_scale_name(letter::Symbol) = letter === :x ? "xscale" : "yscale"

# The `range` stored on axis `key`, if it is a 2-element vector/tuple, and
# whether it is in effect (`autorange` unset or `false`).
function _stored_axis_range(layout::Layout, key::Symbol)
	entry = get(layout.fields, key, nothing)
	stored = _cmn_mapping_get(entry, :range)
	((stored isa AbstractVector || stored isa Tuple) && length(stored) == 2) ||
		return (nothing, false)
	autorange = _cmn_mapping_get(entry, :autorange)
	return (stored, autorange === nothing || autorange === false)
end

_is_plain_real(v) = v isa Real && !(v isa Bool) && isfinite(v)

# ── One-sided axis limits (lead decision D11) ───────────────────────────────
# A one-sided limit is stored as an autoranging axis (`autorange = true`, or
# `"reversed"` on a reversed axis) whose fixed end is an `autorangeoptions`
# limit: `minallowed` (the data minimum) or `maxallowed` (the data maximum), in
# the axis's range units (log10 exponents on a log axis; measured: a log axis
# with `minallowed = -1` starts at 0.1). plotly.js 2.35.2 also has native
# partial ranges (`range = [lo, null]`, `autorange = "max"`), and they draw
# correctly in a live window, but they do not survive `Plotly.toImage` (every
# `savefig`): plotly writes the computed range back into the layout next to
# the partial `autorange`, and the clone that toImage re-plots sees a full
# range with `autorange = "max"`, which plotly treats as invalid and replaces
# by a full autorange (render probes p01/p02 in the axes wave-4 scratch: the
# native form lost both limits in the PNG, the limit form kept them on linear,
# log and reversed axes). The limit form follows later data on the open end.
const _AXIS_LIMIT_OPTION_KEYS = (:minallowed, :maxallowed)
# The autorange clip keys (the sticky field signature of `_finalize_figure!`)
# that a one-sided limit replaces: a clip left on the open end would freeze it
# at the data extent of the moment.
const _AXIS_CLIP_OPTION_KEYS = (:clipmin, :clipmax, :include)
const _REVERSED_AUTORANGES = ("reversed", "min reversed", "max reversed")

# The fixed ends `(minallowed, maxallowed)` stored on axis `key` (range units;
# `nothing` for an open end); `(nothing, nothing)` when the axis has a fixed
# range (`autorange = false`), where plotly.js ignores them.
function _stored_axis_limits(layout::Layout, key::Symbol)
	entry = get(layout.fields, key, nothing)
	_cmn_mapping_get(entry, :autorange) === false && return (nothing, nothing)
	options = _cmn_mapping_get(entry, :autorangeoptions)
	lower = _cmn_mapping_get(options, :minallowed)
	upper = _cmn_mapping_get(options, :maxallowed)
	return (_is_plain_real(lower) ? lower : nothing, _is_plain_real(upper) ? upper : nothing)
end

# Whether Cartesian axis `key` is drawn reversed (decreasing left to right or
# bottom to top): a reversed `autorange`, a decreasing numeric range in effect,
# or a y axis carrying an image trace with `autorange` unset (plotly.js
# reverses those by default).
function _axis_is_reversed(fig, key::Symbol)
	p = _cmn_plot(fig)
	entry = get(p.layout.fields, key, nothing)
	auto = _cmn_mapping_get(entry, :autorange)
	auto isa Symbol && (auto = String(auto))
	auto isa AbstractString && return auto in _REVERSED_AUTORANGES
	stored = _cmn_mapping_get(entry, :range)
	if auto !== true && (stored isa AbstractVector || stored isa Tuple) && length(stored) == 2
		return _is_plain_real(stored[1]) && _is_plain_real(stored[2]) && stored[2] < stored[1]
	end
	(auto === nothing && String(key)[1] == 'y') || return false
	ref = _cmn_axis_ref(key)
	for trace in p.data
		trace isa GenericTrace || continue
		string(get(trace.fields, :type, "")) == "image" || continue
		trace_ref = get(trace.fields, :yaxis, "y")
		(trace_ref isa AbstractString || trace_ref isa Symbol) &&
			String(trace_ref) == ref && return true
	end
	return false
end

# Whether plotly.js ties the range of axis `key` to another axis by an aspect
# constraint: a `scaleanchor` on it or naming it, or an image trace on it
# (plotly.js anchors image axes by default). plotly.js 2.35.2 ignores
# `autorangeoptions` limits on such an axis while it enforces the constraint
# (measured: an equal-aspect heatmap on x = 0..9 with `minallowed = -3` kept
# x at [-0.5, 9.5]), so a one-sided limit there is resolved to a full range.
function _axis_aspect_linked(p::Plot, key::Symbol)
	fields = p.layout.fields
	ref = _cmn_axis_ref(key)
	anchor = _cmn_mapping_get(get(fields, key, nothing), :scaleanchor)
	(anchor isa AbstractString || anchor isa Symbol) && return true
	for (other, axis) in fields
		(other isa Symbol || other isa AbstractString) || continue
		occursin(_CMN_AXIS_KEY_PATTERN, String(other)) || continue
		target = _cmn_mapping_get(axis, :scaleanchor)
		(target isa AbstractString || target isa Symbol) && String(target) == ref && return true
	end
	field = String(key)[1] == 'x' ? :xaxis : :yaxis
	default_ref = String(key)[1] == 'x' ? "x" : "y"
	for trace in p.data
		trace isa GenericTrace || continue
		string(get(trace.fields, :type, "")) == "image" || continue
		trace_ref = get(trace.fields, field, default_ref)
		(trace_ref isa AbstractString || trace_ref isa Symbol) &&
			String(trace_ref) == ref && return true
	end
	return false
end

# Remove an `autorangeoptions` mapping left empty, so `_finalize_figure!` does
# not mistake it for user autorange options.
function _drop_empty_autorangeoptions!(fig, key::Symbol)
	options = _cmn_mapping_get(get(_cmn_layout(fig).fields, key, nothing), :autorangeoptions)
	mapping = options isa PlotlyBase.PlotlyAttribute ? options.fields : options
	(mapping isa AbstractDict && isempty(mapping)) &&
		_cmn_delete_layout_fields!(fig, key, (:autorangeoptions,))
	return nothing
end

function _delete_axis_options!(fig, key::Symbol, names::Tuple{Vararg{Symbol}})
	_cmn_delete_layout_fields!(fig, key, names; nested = :autorangeoptions)
	_drop_empty_autorangeoptions!(fig, key)
	return nothing
end

"""
	_write_axis_range!(fig, key, value; reversed = _axis_is_reversed(fig, key), members = (key,))

Write the range of Cartesian axis `key` (a `matches` root when `members`
lists its group). `value` is in the axis's range units (log10 on a log axis):

- `nothing`: automatic range; the axis keeps its direction (`autorange =
  "reversed"` when it was reversed), its range and every one-sided limit of
  the group are removed;
- `[a, b]`: a fixed range (`autorange = false`; `b < a` flips the axis); the
  group's one-sided limits are removed, and so is the autorange clip of
  `_finalize_figure!` (its exact signature, `_fin_sticky_clip`), so the
  finalizer reads the range as the user's and never resets it;
- `[a, nothing]` / `[nothing, b]`: a one-sided limit (D11) fixing the start /
  end of the axis: `autorange = true` (or `"reversed"`), and on every member
  `autorangeoptions.minallowed` / `maxallowed` (the start is the maximum of a
  reversed axis) in place of earlier limits and of the finalizer's autorange
  clip (plotly.js does not share `autorangeoptions` across a `matches`
  group). Other `autorangeoptions` the user set are kept.
"""
function _write_axis_range!(
	fig,
	key::Symbol,
	value;
	reversed::Bool = _axis_is_reversed(fig, key),
	members = (key,),
)
	auto_value = reversed ? "reversed" : true
	if value === nothing
		_cmn_merge_layout_key!(fig, key, Dict{Symbol, Any}(:autorange => auto_value))
		_cmn_delete_layout_fields!(fig, key, (:range,))
		for member in members
			_delete_axis_options!(fig, member, _AXIS_LIMIT_OPTION_KEYS)
		end
	elseif _is_one_sided_range(value)
		start, stop = value[1], value[2]
		fixed_min, fixed_max = reversed ? (stop, start) : (start, stop)
		limit = fixed_min === nothing ?
			Dict{Symbol, Any}(:maxallowed => fixed_max) :
			Dict{Symbol, Any}(:minallowed => fixed_min)
		_cmn_merge_layout_key!(fig, key, Dict{Symbol, Any}(:autorange => auto_value))
		_cmn_delete_layout_fields!(fig, key, (:range,))
		for member in members
			_drop_finalizer_clip!(fig, member)
			_cmn_delete_layout_fields!(
				fig,
				member,
				_AXIS_LIMIT_OPTION_KEYS;
				nested = :autorangeoptions,
			)
			_cmn_merge_layout_key!(
				fig,
				member,
				Dict{Symbol, Any}(:autorangeoptions => attr(; limit...));
				nested = (:autorangeoptions,),
			)
		end
	else
		_cmn_merge_layout_key!(
			fig,
			key,
			Dict{Symbol, Any}(:range => Any[value[1], value[2]], :autorange => false),
		)
		for member in members
			_drop_finalizer_clip!(fig, member)
			_delete_axis_options!(fig, member, _AXIS_LIMIT_OPTION_KEYS)
		end
	end
	return nothing
end

# Remove the autorange clip `_finalize_figure!` wrote on axis `key` (only its
# exact signature, `_fin_sticky_clip`; user `autorangeoptions` stay). A clip
# left next to a one-sided limit would freeze the open end at the data extent
# of the moment; next to a fixed range equal to it, the finalizer would read
# the range as its own pin and could reset it.
function _drop_finalizer_clip!(fig, key::Symbol)
	entry = get(_cmn_layout(fig).fields, key, nothing)
	_fin_sticky_clip(entry) === nothing && return nothing
	_delete_axis_options!(fig, key, _AXIS_CLIP_OPTION_KEYS)
	return nothing
end

# The interval (data units, also on a log axis; `log_axis` makes a clip or
# field extent that is not positive unusable) that axes `members` (one
# `matches` group) show when plotly autoranges them, and whether it is still
# to be widened by the default margin:
# - the autorange clip on `key` (`_finalize_figure!`'s sticky field range or a
#   user clip), exact;
# - else, for a group the finalizer would pin (a tight field, no loose field,
#   every extent computed: `_fin_collect_axes`), the extent it would clip to
#   (field edges, not cell centres; overlays padded, `_fin_padded_extent`),
#   exact;
# - else the data extent of the group (`_axis_data_extent`), to be widened;
# - `nothing` when the group has no data.
function _axis_group_view_extent(fig, key::Symbol, members, log_axis::Bool)
	p = _cmn_plot(fig)
	layout = p.layout
	options = _cmn_mapping_get(get(layout.fields, key, nothing), :autorangeoptions)
	clip_lo = _cmn_mapping_get(options, :clipmin)
	clip_hi = _cmn_mapping_get(options, :clipmax)
	if _is_plain_real(clip_lo) && _is_plain_real(clip_hi) && clip_lo < clip_hi &&
		(!log_axis || clip_lo > 0)
		return ((Float64(clip_lo), Float64(clip_hi)), false)
	end
	accs = _fin_collect_axes(p)
	acc = _FinAxisAcc()
	for member in members
		macc = get(accs, member, nothing)
		macc === nothing && continue
		acc.tight |= macc.tight
		acc.loose |= macc.loose
		acc.unsupported |= macc.unsupported
		acc.lo = min(acc.lo, macc.lo)
		acc.hi = max(acc.hi, macc.hi)
		acc.flo = min(acc.flo, macc.flo)
		acc.fhi = max(acc.fhi, macc.fhi)
	end
	if acc.tight && !acc.loose && !acc.unsupported && isfinite(acc.lo) && isfinite(acc.hi) &&
		acc.lo < acc.hi && (!log_axis || acc.lo > 0)
		return (_fin_padded_extent(acc, log_axis), false)
	end
	lower, upper = Inf, -Inf
	for member in members
		e = _axis_data_extent(fig, member)
		e === nothing && continue
		lower = min(lower, e[1])
		upper = max(upper, e[2])
	end
	lower <= upper || return (nothing, true)
	return ((lower, upper), true)
end

# A one-sided `value` (range units) for axis `key` of group `members`: kept as
# it is, unless the group is tied by an aspect constraint (see
# `_axis_aspect_linked`), where it becomes a full range whose open end comes
# from the data when the call runs (`_axis_group_view_extent`): the autorange
# clip of a field axis or the field edges united with the other data, else the
# data extent of the group widened by 5 % of its span on that side
# (matplotlib's default axes margin, so markers at the edge stay whole).
function _resolve_constrained_limit(fig, key::Symbol, value, reversed::Bool, members, who::AbstractString, name::AbstractString)
	p = _cmn_plot(fig)
	any(member -> _axis_aspect_linked(p, member), members) || return value
	layout = p.layout
	log_axis = _axis_type(layout, key) == "log"
	extent, padded = _axis_group_view_extent(fig, key, members, log_axis)
	extent === nothing && throw(ArgumentError(
		"$(who): `$(name)` = $(repr(Tuple(value))) is a one-sided limit on an axis " *
		"with a locked aspect ratio, where plotly.js cannot autorange one end; the " *
		"open end is taken from the data on the axis, and it has none yet. Add the " *
		"data first, or give both bounds.",
	))
	lower, upper = log_axis ? (log10(extent[1]), log10(extent[2])) : extent
	if padded
		margin = 0.05 * (upper - lower)
		lower -= margin
		upper += margin
	end
	start, stop = value[1], value[2]
	fixed_min, fixed_max = reversed ? (stop, start) : (start, stop)
	lo = fixed_min === nothing ? lower : Float64(fixed_min)
	hi = fixed_max === nothing ? upper : Float64(fixed_max)
	lo < hi || throw(ArgumentError(
		"$(who): `$(name)` = $(repr(Tuple(value))) leaves no room for the data: " *
		"the open end, taken from the data, is not beyond the fixed bound; give " *
		"both bounds.",
	))
	return reversed ? Any[hi, lo] : Any[lo, hi]
end

# A one-sided `value` (range units) whose fixed bound lies beyond every data
# value already on the axes `members` would show an axis without data (the
# open end autoranges to the data on the far side of the fixed end, so the
# axis also flips; render probe p05). That is an ArgumentError. The data is
# what the group shows (`_axis_group_view_extent`: a field reaches its cell
# edges, not only its cell centres). An axis without numeric data yet (or a
# date axis) is not checked.
function _require_limit_meets_data(fig, key::Symbol, value, reversed::Bool, members, who::AbstractString, name::AbstractString)
	log_axis = _axis_type(_cmn_layout(fig), key) == "log"
	extent, _ = _axis_group_view_extent(fig, key, members, log_axis)
	extent === nothing && return nothing
	lower, upper = extent
	if log_axis
		lower, upper = log10(lower), log10(upper)
	end
	start, stop = value[1], value[2]
	fixed_min, fixed_max = reversed ? (stop, start) : (start, stop)
	beyond = (fixed_min !== nothing && _is_plain_real(fixed_min) && fixed_min > upper) ||
		(fixed_max !== nothing && _is_plain_real(fixed_max) && fixed_max < lower)
	beyond && throw(ArgumentError(
		"$(who): `$(name)` fixes one end of the axis beyond all of its data; no " *
		"data would be visible. Give both bounds for an empty region, or fix the " *
		"other end.",
	))
	return nothing
end

# How the one-sided limits stored on axis `key` change when its type becomes
# `new_type` (as `_axis_range_for_scale` for the range): `(:keep, nothing)`,
# `(:set, Dict(:minallowed => v, ...))` converted between log10 exponents and
# data values, or `(:drop, nothing)` when a limit has no meaning on the new
# type.
function _axis_limits_for_scale(layout::Layout, key::Symbol, new_type::AbstractString)
	old_log = _axis_type(layout, key) == "log"
	new_log = new_type == "log"
	old_log == new_log && return (:keep, nothing)
	entry = get(layout.fields, key, nothing)
	# plotly.js ignores the limits of an axis with a fixed range.
	_cmn_mapping_get(entry, :autorange) === false && return (:keep, nothing)
	options = _cmn_mapping_get(entry, :autorangeoptions)
	converted = Dict{Symbol, Any}()
	for name in _AXIS_LIMIT_OPTION_KEYS
		v = _cmn_mapping_get(options, name)
		v === nothing && continue
		_is_plain_real(v) || return (:drop, nothing)
		if old_log
			new_type in ("linear", "-") || return (:drop, nothing)
			converted[name] = exp10(Float64(v))
		else
			v > 0 || return (:drop, nothing)
			converted[name] = log10(Float64(v))
		end
	end
	isempty(converted) && return (:keep, nothing)
	return (:set, converted)
end

# The one-sided limits of axis `key` in data units, for error messages.
function _stored_limits_text(layout::Layout, key::Symbol)
	lower, upper = _stored_axis_limits(layout, key)
	if _axis_type(layout, key) == "log"
		lower === nothing || (lower = exp10(Float64(lower)))
		upper === nothing || (upper = exp10(Float64(upper)))
	end
	return "(minimum = $(repr(lower)), maximum = $(repr(upper)))"
end

# How the range stored on axis `key` must change when its type becomes
# `new_type`, so it keeps showing the same DATA interval: plotly.js stores a
# log axis's range as log10 exponents, so switching between log and a linear
# ("linear" or autotyped "-") axis converts the bounds (`exp10` / `log10`).
# Returns `(:keep, nothing)` (no range, or no log/linear switch),
# `(:set, value)` or `(:drop, nothing)` when the range has no meaning on the
# new axis (non-positive or non-numeric bounds on a log axis, a log10 range
# on a date/category axis).
function _axis_range_for_scale(layout::Layout, key::Symbol, new_type::AbstractString)
	old_log = _axis_type(layout, key) == "log"
	new_log = new_type == "log"
	old_log == new_log && return (:keep, nothing)
	stored, _ = _stored_axis_range(layout, key)
	stored === nothing && return (:keep, nothing)
	lower, upper = stored[1], stored[2]
	numeric = _is_plain_real(lower) && _is_plain_real(upper)
	if old_log
		(numeric && new_type in ("linear", "-")) || return (:drop, nothing)
		return (:set, Float64[exp10(Float64(lower)), exp10(Float64(upper))])
	end
	(numeric && lower > 0 && upper > 0) || return (:drop, nothing)
	return (:set, Float64[log10(Float64(lower)), log10(Float64(upper))])
end

# The stored range of axis `key` in data units, for error messages.
function _stored_range_text(layout::Layout, key::Symbol)
	stored, _ = _stored_axis_range(layout, key)
	stored === nothing && return "nothing"
	if _axis_type(layout, key) == "log" &&
		_is_plain_real(stored[1]) && _is_plain_real(stored[2])
		return repr((exp10(Float64(stored[1])), exp10(Float64(stored[2]))))
	end
	return repr(Tuple(stored))
end

# Axis scale of the primary x or y axis. `""` leaves the axis type unchanged.
# A logarithmic axis gets power-of-ten tick labels (10², not "100" / "1µ")
# unless an exponent format was already chosen.
#
# An explicit range keeps its DATA interval across a switch between a log and
# a linear axis: plotly.js stores log ranges as exponents, so [0, 3] on a log
# axis becomes [1, 1000] on the linear axis and vice versa. A range that has no
# meaning on the new type (non-positive bounds on a log axis, a log10 range on
# a date/category axis) is removed, so the axis autoranges;
# `_validate_cartesian_options` rejects that case unless the same call sets a
# new range. Annotations and shapes placed on the axis are not converted.
function _apply_axis_scale!(
	fig,
	letter::Symbol,
	scale::AbstractString,
	who::AbstractString,
)
	isempty(scale) && return nothing
	return _apply_axis_scale_to_key!(
		fig,
		_axis_layout_key(letter),
		scale,
		who;
		name = _axis_scale_name(letter),
	)
end

# `_apply_axis_scale!` for any Cartesian axis `key` (e.g. a twin y axis);
# `name` is the keyword named in errors.
function _apply_axis_scale_to_key!(
	fig,
	key::Symbol,
	scale::AbstractString,
	who::AbstractString;
	name::AbstractString = "scale",
)
	isempty(scale) && return nothing
	scale in _AXIS_SCALE_TYPES ||
		throw(ArgumentError(
			"$(who): `$(name)` must be one of $(join(repr.(_AXIS_SCALE_TYPES), ", ")) " *
			"or \"\" (unchanged); got $(repr(scale)).",
		))
	action, converted = _axis_range_for_scale(_plot_layout(fig), key, scale)
	limit_action, limits = _axis_limits_for_scale(_plot_layout(fig), key, scale)
	relayout!(fig; Symbol(key, :_type) => String(scale))
	if action === :set
		relayout!(fig; Symbol(key, :_range) => converted)
	elseif action === :drop
		relayout!(fig; Symbol(key, :_autorange) => true)
		_cmn_delete_layout_fields!(fig, key, (:range,))
	end
	# One-sided limits (D11) are in range units too.
	if limit_action === :set
		_cmn_merge_layout_key!(
			fig,
			key,
			Dict{Symbol, Any}(:autorangeoptions => attr(; limits...));
			nested = (:autorangeoptions,),
		)
	elseif limit_action === :drop
		_delete_axis_options!(fig, key, _AXIS_LIMIT_OPTION_KEYS)
	end
	if scale == "log"
		axis = get(_plot_layout(fig).fields, key, nothing)
		existing = axis === nothing ? nothing : _cmn_mapping_get(axis, :exponentformat)
		(existing === nothing || (existing isa AbstractDict && isempty(existing))) &&
			relayout!(fig; Symbol(key, :_exponentformat) => "power")
	end
	return nothing
end

# Bound types an axis of type `axis_type` can take in its range: numbers on
# linear/log/category axes, anything `_checked_range` accepted (date strings,
# dates, numbers) on date and autotyped axes.
function _require_range_bound_types(checked, axis_type::AbstractString, who::AbstractString, name::AbstractString)
	axis_type in _NUMERIC_RANGE_AXIS_TYPES || return nothing
	all(b -> b === nothing || b isa Real, checked) ||
		throw(ArgumentError(
			"$(who): `$(name)` bounds on a $(axis_type) axis must be numbers" *
			(axis_type == "category" ? " (0-based category positions)" : "") *
			"; got $(repr(Tuple(checked))).",
		))
	return nothing
end

# Range of the primary x or y axis, given in DATA units on every axis type.
# Plotly stores the range of a logarithmic axis as log10 exponents, so the
# bounds are converted there (non-positive bounds are an error). The automatic
# sentinel (`[0, 0]`, `(0, 0)`, `nothing`) leaves the axis untouched. A
# reversed range (`upper < lower`) flips the axis. Linear, log and category
# axes need numeric bounds; date and autotyped axes keep strings/dates as
# given (never numerically converted).
#
# Call order: the range may be applied before or after the traces are added
# (it does not depend on the data); apply the axis scale of the same call
# first (`_apply_axis_scale!`), so the conversion sees the final axis type. On
# an axis that is already logarithmic (an earlier constructor or `xscale`)
# the range is converted without repeating the scale.
function _apply_axis_range!(
	fig,
	letter::Symbol,
	range,
	who::AbstractString,
)
	return _apply_axis_range_to_key!(
		fig,
		_axis_layout_key(letter),
		range,
		who;
		name = _axis_range_name(letter),
	)
end

# `checked` (from `_checked_range(...; partial = true)`, not the sentinel) in
# the units plotly.js stores for an axis of type `axis_type`: log10 on a log
# axis; the fixed bound of a one-sided limit as `_axis_limit_bound` gives it;
# the bounds of a full range on other axes as given.
function _axis_range_store_value(checked, axis_type::AbstractString, who::AbstractString, name::AbstractString)
	if _is_one_sided_range(checked)
		return Any[b === nothing ? nothing : _axis_limit_bound(axis_type, b, who, name) for b in checked]
	end
	axis_type == "log" || return checked
	(_is_plain_real(checked[1]) && _is_plain_real(checked[2])) || throw(ArgumentError(
		"$(who): `$(name)` bounds on a logarithmic axis are data values and " *
		"must be positive numbers; got $(repr(Tuple(checked))).",
	))
	return Any[_axis_limit_bound(axis_type, b, who, name) for b in checked]
end

"""
	_apply_axis_range_to_key!(fig, key, range, who; name = "range")

THE range encoder of the package (D11, Z38): every Cartesian range a
constructor keyword (`xrange`/`yrange`), a mutator or `xrange!`/`yrange!`
sets goes through it. `range` is in DATA units on every axis type, as the
user gave it: `nothing`/`[0, 0]`/`(nothing, nothing)` leave the axis alone, a
full range `(lo, hi)` fixes it (`hi < lo` flips it), a one-sided limit
`(lo, nothing)` / `(nothing, hi)` fixes one end. The bounds are checked
(`_checked_range`, numbers on linear/log/category axes, positive on a log
axis) and converted to plotly's range units: log10 on a log axis, epoch
milliseconds for the fixed bound of a one-sided limit on a date axis (a date
string there makes plotly.js 2.35.2 fall back to its empty-axis range), the
0-based position on a category axis.

The write follows `matches`: the range goes to the root of the axis's group
(the only axis plotly.js reads it from) and one-sided limits to every member.
A one-sided limit is `autorange = true` (`"reversed"` on a reversed axis)
with `autorangeoptions.minallowed`/`maxallowed` (`_write_axis_range!`), the
form that survives `savefig` (plotly.js's native partial ranges do not). On an
axis tied by an aspect constraint, where plotly.js ignores those options, the
open end is taken from the data when the call runs and the range is pinned
(`_resolve_constrained_limit`); a fixed bound beyond all data on the axis is
an `ArgumentError`. A full range replaces earlier one-sided limits.
"""
function _apply_axis_range_to_key!(
	fig,
	key::Symbol,
	range,
	who::AbstractString;
	name::AbstractString = "range",
)
	checked = _checked_range(range, who, name; partial = true)
	checked === nothing && return nothing
	root = _axes_match_root(fig, key, who)
	axis_type = _axis_type(_plot_layout(fig), root)
	_require_range_bound_types(checked, axis_type, who, name)
	_write_axis_group_range!(fig, root, _axis_range_store_value(checked, axis_type, who, name), who, name)
	return nothing
end

# Write `value` (plotly range units, from `_axis_range_store_value`; `nothing`
# for an automatic range) on the `matches` group whose root is `root`: the
# group-aware half of `_apply_axis_range_to_key!`, shared with `xrange!` /
# `yrange!` (`_axes_range!`), which check and convert the bounds themselves.
function _write_axis_group_range!(fig, root::Symbol, value, who::AbstractString, name::AbstractString)
	members = _axes_match_members(fig, root, who)
	reversed = _axis_is_reversed(fig, root)
	if _is_one_sided_range(value)
		_require_limit_meets_data(fig, root, value, reversed, members, who, name)
		value = _resolve_constrained_limit(fig, root, value, reversed, members, who, name)
	end
	_write_axis_range!(fig, root, value; reversed = reversed, members = members)
	return nothing
end

# After an aspect constraint was added (equal aspect), turn the one-sided
# limits of the axes that are now aspect-linked into full ranges (plotly.js
# ignores the limits there; see `_axis_aspect_linked`). `groups` holds
# `(root, members)` pairs: an axis and its `matches` group (`(key, (key,))`
# for an axis on its own). The open end comes from the data, as in
# `_resolve_constrained_limit`.
function _resolve_linked_limits!(fig, groups, who::AbstractString)
	p = _cmn_plot(fig)
	for (root, members) in groups
		any(member -> _axis_aspect_linked(p, member), members) || continue
		lower, upper = _stored_axis_limits(p.layout, root)
		(lower === nothing && upper === nothing) && continue
		reversed = _axis_is_reversed(fig, root)
		start, stop = reversed ? (upper, lower) : (lower, upper)
		value = Any[start, stop]
		_is_one_sided_range(value) && (value = _resolve_constrained_limit(
			fig, root, value, reversed, members, who, "range",
		))
		_write_axis_range!(fig, root, value; reversed = reversed, members = members)
	end
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
# A scale switch that would drop an explicit range (see `_apply_axis_scale!`)
# is an error unless this call sets a new range.
function _require_axis_range(
	fig,
	letter::Symbol,
	range,
	scale::AbstractString,
	who::AbstractString,
)
	return _require_axis_range_for_key(
		fig,
		_axis_layout_key(letter),
		range,
		scale,
		who;
		name = _axis_range_name(letter),
	)
end

# `_require_axis_range` for any Cartesian axis `key` (e.g. a twin y axis);
# `name` is the range keyword named in errors.
function _require_axis_range_for_key(
	fig,
	key::Symbol,
	range,
	scale::AbstractString,
	who::AbstractString;
	name::AbstractString = "range",
)
	letter = String(key)[1]
	checked = _checked_range(range, who, name; partial = true)
	layout = _plot_layout(fig)
	final_type = isempty(scale) ? _axis_type(layout, key) : String(scale)
	if checked === nothing
		if !isempty(scale)
			action, _ = _axis_range_for_scale(layout, key, final_type)
			_, active = _stored_axis_range(layout, key)
			(action === :drop && active) && throw(ArgumentError(
				"$(who): the current $(letter) range $(_stored_range_text(layout, key)) " *
				"cannot be shown on a $(repr(final_type)) axis" *
				(final_type == "log" ? " (log-axis bounds must be positive numbers)" : "") *
				"; pass a new `$(name)` in the same call, or clear the range first " *
				"with `$(letter)range!(fig, nothing)`.",
			))
			limit_action, _ = _axis_limits_for_scale(layout, key, final_type)
			limit_action === :drop && throw(ArgumentError(
				"$(who): the current one-sided $(letter) limit $(_stored_limits_text(layout, key)) " *
				"cannot be shown on a $(repr(final_type)) axis" *
				(final_type == "log" ? " (log-axis bounds must be positive numbers)" : "") *
				"; pass a new `$(name)` in the same call, or clear the limit first " *
				"with `$(letter)range!(fig, nothing)`.",
			))
		end
		return nothing
	end
	_require_range_bound_types(checked, final_type, who, name)
	if final_type == "log"
		for bound in checked
			bound === nothing && continue
			bound > 0 ||
				throw(ArgumentError(
					"$(who): `$(name)` bounds on a logarithmic axis are data values " *
					"and must be positive; got $(repr(range)).",
				))
		end
	end
	# The fixed bound of a one-sided limit must convert (dates are read here).
	_is_one_sided_range(checked) && _axis_range_store_value(checked, final_type, who, name)
	return checked
end

# Validate the common Cartesian keywords of a constructor or mutator without
# touching the figure. Call this before the first write; the `_apply_*`
# helpers above then cannot fail half-way. Ranges are DATA units on every
# axis type (positive on a log axis); see `_checked_range` for the shapes that
# are rejected.
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
