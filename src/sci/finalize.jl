# Figure-level normalisation applied after PlotlySupply builds or mutates a
# figure: fixes that depend on the whole figure rather than on one call.
#
# `_finalize_figure!(fig)` is idempotent, never overrides an explicit user
# setting, reads the figure through `_plot_layout`/`_plot_obj` and writes only
# through `relayout!`/`restyle!`, so it works on a `Plot`, a `SyncPlot` and the
# staged figures used inside PlotlySupply's transactions. It writes nothing when
# nothing changes. Rules (decision D10):
#
# - M1: roots of shared-axis (`matches`) groups state `autorange = true`.
# - M2: Cartesian axes that carry a field trace are "sticky": the autorange is
#   clipped to the union of the field extents (brick edges) and the data of the
#   other traces, so plotly adds no padding.
# - M3: equal-aspect cells are fitted into their cell (or the figure is sized
#   to the field) and their colorbars hug the fitted plot area.
# - M4: several colorbars on the same plot area are placed side by side.
#
# The trace convention the field functions follow is the `meta` marker below
# (`_FIELD_META`, `_FIELD_META_LOOSE`).

const _FIN_AXIS_KEY = r"^[xy]axis([2-9]|[1-9][0-9]+)?$"

_fin_is_axis_key(key) = key isa Symbol && occursin(_FIN_AXIS_KEY, String(key))

# Layout key of an axis reference: "x" -> :xaxis, "y3" -> :yaxis3; `nothing`
# for anything that is not a Cartesian axis reference.
function _fin_axis_key(ref)
	(ref isa AbstractString || ref isa Symbol) || return nothing
	m = match(r"^([xy])([2-9]|[1-9][0-9]+)?$", String(ref))
	m === nothing && return nothing
	return Symbol(m.captures[1], "axis", something(m.captures[2], ""))
end

# Axis reference of a layout key: :xaxis -> "x", :yaxis3 -> "y3".
function _fin_axis_ref(key::Symbol)
	name = String(key)
	return string(name[1], name[6:end])
end

_fin_field(mapping, key::Symbol) =
	mapping isa AbstractDict ? get(mapping, key, nothing) :
	mapping isa PlotlyBase.PlotlyAttribute ? get(mapping.fields, key, nothing) :
	nothing

# A fixed axis range: two bounds. Anything else leaves the axis autoranging.
function _fin_has_range(axis)
	range = _fin_field(axis, :range)
	return (range isa AbstractVector || range isa Tuple) && length(range) == 2
end

# Root axis keys of the `matches` groups of `layout`: the axes other axes are
# matched to, directly or through a chain (x -> x3 -> x5 has root :xaxis5). A
# reference to something that is not a Cartesian axis is ignored, as plotly.js
# ignores it; a cyclic chain has no root and is skipped.
function _fin_match_roots(layout::Layout)
	fields = layout.fields
	roots = Set{Symbol}()
	for (key, axis) in fields
		_fin_is_axis_key(key) || continue
		target = _fin_axis_key(_fin_field(axis, :matches))
		target === nothing && continue
		root = _fin_match_root(fields, key)
		root === nothing || root === key || push!(roots, root)
	end
	return roots
end

# The root of the `matches` chain that starts at `key` (`key` itself when it
# matches nothing); `nothing` for a cyclic chain.
function _fin_match_root(fields::AbstractDict, key::Symbol)
	seen = Set{Symbol}((key,))
	root = key
	while true
		next = _fin_axis_key(_fin_field(get(fields, root, nothing), :matches))
		next === nothing && return root
		next in seen && return nothing
		push!(seen, next)
		root = next
	end
end

# plotly.js 2.35.2: in a figure with several `matches` groups (shared axes),
# giving the root of ONE group a fixed range makes the OTHER groups stop
# autoranging: their axes fall back to plotly's empty-axis ranges ([-1, 6] on x,
# [-1, 4] on y), so the data is cropped or shown with blank space. A root that
# states `autorange` explicitly is not affected. (Reproduced with a plain
# PlotlyBase figure: 2 x 2 grid, x matched per column, y per row, range set on
# one x root; the y axes of the heatmap row came out as [-1, 4]. With
# `autorange = true` on the roots every axis ranges over its data again.)
#
# Returns the `relayout!` updates that state `autorange = true` on every group
# root that has neither a range nor an `autorange` entry of its own.
function _fin_match_group_updates(layout::Layout)
	updates = Dict{Symbol, Any}()
	fields = layout.fields
	for root in _fin_match_roots(layout)
		axis = get(fields, root, nothing)
		_fin_has_range(axis) && continue
		_fin_field(axis, :autorange) === nothing || continue
		updates[Symbol(root, :_autorange)] = true
	end
	return updates
end

# ---------------------------------------------------------------------------
# Field traces (the contract published to the field functions)
# ---------------------------------------------------------------------------

"""
	_FIELD_META = "plotlysupply:field"

`trace.meta` of a trace that draws a field with sticky axis edges (the
default, `tight = true`). The native plotly field types (`heatmap`, `contour`,
`histogram2d`, `histogram2dcontour`, `image`) are fields without it; any other
trace type (the polygon/mesh traces of plot_pcolormesh, plot_tripcolor,
plot_polygons) is a field only with this marker.
"""
const _FIELD_META = "plotlysupply:field"

"""
	_FIELD_META_LOOSE = "plotlysupply:field:loose"

`trace.meta` of a field drawn with `tight = false`: both of its axes keep
plotly's ordinary (padded) autorange, even when a tight field shares them.
"""
const _FIELD_META_LOOSE = "plotlysupply:field:loose"

const _FIN_NATIVE_FIELD_TYPES = ("heatmap", "contour", "histogram2d", "histogram2dcontour", "image")

function _fin_trace_type(trace::GenericTrace)
	value = get(trace.fields, :type, "scatter")
	(value isa AbstractString || value isa Symbol) || return ""
	return String(value)
end

"""
	_fin_field_kind(trace) -> :tight | :loose | nothing

How `_finalize_figure!` treats `trace` (see `_FIELD_META`): `:tight` for a
field with sticky edges, `:loose` for a field drawn with `tight = false`,
`nothing` for every other trace.
"""
function _fin_field_kind(trace)
	trace isa GenericTrace || return nothing
	meta = get(trace.fields, :meta, nothing)
	if meta isa AbstractString
		meta == _FIELD_META_LOOSE && return :loose
		meta == _FIELD_META && return :tight
	end
	return _fin_trace_type(trace) in _FIN_NATIVE_FIELD_TYPES ? :tight : nothing
end

# Hidden traces (`visible = false` or "legendonly") take no part in plotly's
# autorange, so they take no part here either.
function _fin_visible(trace::GenericTrace)
	value = get(trace.fields, :visible, true)
	value === false && return false
	(value isa AbstractString || value isa Symbol) && String(value) == "legendonly" &&
		return false
	return true
end

_fin_isreal(value) = value isa Real && !(value isa Bool)
_fin_isfinite_real(value) = _fin_isreal(value) && isfinite(value)

_fin_string(value) =
	(value isa AbstractString || value isa Symbol) ? String(value) : nothing

# ---------------------------------------------------------------------------
# Extents in data units: `(lo, hi)`, `nothing` (no data) or `:unsupported`
# (the trace occupies the axis in a way this module does not compute, which
# turns the sticky range off for that axis).
# ---------------------------------------------------------------------------

# l-values (log10 on a log axis) of a coordinate vector that must be entirely
# numeric; `nothing` when an entry is not a finite (positive on log) number.
function _fin_lvalues(values, islog::Bool)
	out = Float64[]
	for value in values
		_fin_isfinite_real(value) || return nothing
		x = Float64(value)
		if islog
			x > 0 || return nothing
			x = log10(x)
		end
		push!(out, x)
	end
	return out
end

_fin_from_l(lo::Float64, hi::Float64, islog::Bool) =
	islog ? (exp10(lo), exp10(hi)) : (lo, hi)

# Extent of a heatmap (`bricks = true`) or contour (`bricks = false`) along
# `letter`, with `n` z samples in that direction. This follows plotly.js
# 2.35.2 `makeBoundArray` and the heatmap autorange, which reads the first and
# last bound: `n + 1` or more coordinates are brick edges, `n` coordinates are
# centres (edges half a step outside, midpoints between), fewer are
# extrapolated with the last step; on a log axis the same happens to log10 of
# the coordinates (probe p3: centres 1, 2, 10, 50, 1000 on a log axis give the
# range [-0.1505, 3.6505]). Without coordinates the field starts at `x0` with
# step `dx` (defaults 0 and 1). A contour spans its nodes.
function _fin_grid_extent(fields, letter::Char, islog::Bool, n::Int, bricks::Bool)
	n >= 1 || return nothing
	coords = get(fields, Symbol(letter), nothing)
	coords isa Tuple && (coords = collect(coords))
	scaled = _fin_string(get(fields, Symbol(letter, "type"), nothing)) == "scaled"
	if !scaled && coords isa AbstractVector && length(coords) >= 2
		c = _fin_lvalues(coords, islog)
		c === nothing && return :unsupported
		m = length(c)
		if !bricks
			first_l, last_l = c[1], c[min(m, n)]
		elseif m >= n + 1
			first_l, last_l = c[1], c[n + 1]
		else
			first_l = 1.5 * c[1] - 0.5 * c[2]
			last_l = 1.5 * c[m] - 0.5 * c[m - 1]
			if m < n
				step = last_l - 0.5 * (c[m - 1] + c[m])
				last_l += step * (n - m)
			end
		end
		lo, hi = minmax(first_l, last_l)
		return _fin_from_l(lo, hi, islog)
	end
	(coords === nothing || scaled || (coords isa AbstractVector && length(coords) <= 1)) ||
		return :unsupported
	# x0/dx are data values that plotly converts differently on log axes;
	# such fields keep the ordinary autorange.
	islog && return :unsupported
	start = (!scaled && coords isa AbstractVector && length(coords) == 1) ?
		coords[1] : get(fields, Symbol(letter, "0"), 0)
	step = get(fields, Symbol("d", letter), 1)
	(_fin_isfinite_real(start) && _fin_isfinite_real(step)) || return :unsupported
	v0 = Float64(start)
	dv = step == 0 ? 1.0 : Float64(step)
	return bricks ?
		minmax(v0 - 0.5 * dv, v0 + dv * (n - 0.5)) :
		minmax(v0, v0 + dv * (n - 1))
end

# An image: pixel `i` (0-based) is centred on `x0 + i * dx` (plotly defaults
# 0 and 1), so the extent is half a pixel beyond the outer centres (probe p3:
# a 5 x 3 image spans x = [-0.5, 4.5], y = [2.5, -0.5]).
function _fin_image_extent(fields, letter::Char, islog::Bool)
	islog && return :unsupported
	n = _cmn_grid_count(get(fields, :z, nothing), letter, false)
	n === nothing && return :unsupported
	n >= 1 || return nothing
	start = get(fields, Symbol(letter, "0"), 0)
	step = get(fields, Symbol("d", letter), 1)
	(_fin_isfinite_real(start) && _fin_isfinite_real(step)) || return :unsupported
	v0 = Float64(start)
	dv = Float64(step)
	return minmax(v0 - 0.5 * dv, v0 + dv * (n - 0.5))
end

# Data extent of a scatter-type trace: its finite coordinates (positive ones
# on a log axis, as plotly drops the rest), the implicit `x0 + i dx`
# coordinates, and 0 for `fill = "tozerox"/"tozeroy"`. Error bars extend the
# data in a way not computed here.
function _fin_scatter_extent(fields, letter::Char, islog::Bool)
	error_bars = get(fields, Symbol("error_", letter), nothing)
	_is_layout_mapping(error_bars) && _cmn_mapping_get(error_bars, :visible) !== false &&
		return :unsupported
	values = get(fields, Symbol(letter), nothing)
	values === nothing && (values = _cmn_implicit_coordinates(fields, letter))
	values === nothing && return nothing
	(values isa AbstractVector || values isa Tuple || values isa Base.Generator) ||
		return :unsupported
	lo, hi = Inf, -Inf
	for value in values
		(value === nothing || value === missing) && continue
		_fin_isreal(value) || return :unsupported
		x = Float64(value)
		isfinite(x) || continue
		islog && x <= 0 && continue
		lo = min(lo, x)
		hi = max(hi, x)
	end
	lo <= hi || return nothing
	if !islog && _fin_string(get(fields, :fill, nothing)) == "tozero$(letter)"
		lo = min(lo, 0.0)
		hi = max(hi, 0.0)
	end
	return (lo, hi)
end

function _fin_trace_extent(trace::GenericTrace, letter::Char, islog::Bool)
	fields = trace.fields
	type_name = _fin_trace_type(trace)
	if type_name == "heatmap" || type_name == "contour"
		n = _cmn_grid_count(get(fields, :z, nothing), letter, get(fields, :transpose, false) === true)
		n === nothing && return :unsupported
		return _fin_grid_extent(fields, letter, islog, n, type_name == "heatmap")
	elseif type_name == "image"
		return _fin_image_extent(fields, letter, islog)
	elseif type_name == "scatter" || type_name == "scattergl"
		return _fin_scatter_extent(fields, letter, islog)
	end
	# histogram2d(contour) bins, bars, boxes, ...: not computed here.
	return :unsupported
end

# Data-referenced layout shapes (line/rect/circle) and annotations on axis
# `ref`: plotly includes them in the autorange, so the sticky range does too.
# Path shapes, pixel-sized shapes and any such item on a log axis are not
# computed here.
function _fin_layout_item_extent(layout::Layout, ref::String, letter::Char, islog::Bool)
	lo, hi = Inf, -Inf
	ref_key = Symbol(letter, "ref")
	for (container, keys) in (
		(:shapes, (Symbol(letter, "0"), Symbol(letter, "1"))),
		(:annotations, (Symbol(letter),)),
	)
		items = get(layout.fields, container, nothing)
		(items isa AbstractVector || items isa Tuple) || continue
		for item in items
			_is_layout_mapping(item) || continue
			_cmn_mapping_get(item, :visible) === false && continue
			_fin_string(_cmn_mapping_get(item, ref_key, string(letter))) == ref || continue
			islog && return :unsupported
			if container === :shapes
				default_type = _cmn_mapping_get(item, :path) === nothing ? "rect" : "path"
				_fin_string(_cmn_mapping_get(item, :type, default_type)) in ("rect", "line", "circle") ||
					return :unsupported
				_fin_string(_cmn_mapping_get(item, Symbol(letter, "sizemode"))) == "pixel" &&
					return :unsupported
			end
			for key in keys
				value = _cmn_mapping_get(item, key)
				_fin_isfinite_real(value) || return :unsupported
				lo = min(lo, Float64(value))
				hi = max(hi, Float64(value))
			end
		end
	end
	return lo <= hi ? (lo, hi) : nothing
end

# What the traces put on one Cartesian axis.
mutable struct _FinAxisAcc
	tight::Bool
	loose::Bool
	unsupported::Bool
	image_x::Union{Nothing, Symbol}   # on a y axis: the x axis of an image trace
	lo::Float64
	hi::Float64
end
_FinAxisAcc() = _FinAxisAcc(false, false, false, nothing, Inf, -Inf)

function _fin_acc_extend!(acc::_FinAxisAcc, extent)
	if extent === :unsupported
		acc.unsupported = true
	elseif extent isa Tuple
		acc.lo = min(acc.lo, extent[1])
		acc.hi = max(acc.hi, extent[2])
	end
	return acc
end

_fin_axis_type(layout::Layout, key::Symbol) =
	something(_fin_string(_cmn_mapping_get(get(layout.fields, key, nothing), :type)), "-")

function _fin_collect_axes(p::Plot)
	layout = p.layout
	accs = Dict{Symbol, _FinAxisAcc}()
	cache = Dict{Any, Union{Nothing, String}}()
	for trace in p.data
		trace isa GenericTrace || continue
		_cmn_trace_kind(trace, cache) == "xy" || continue
		_fin_visible(trace) || continue
		kind = _fin_field_kind(trace)
		is_image = _fin_trace_type(trace) == "image"
		xkey = _fin_axis_key(get(trace.fields, :xaxis, "x"))
		ykey = _fin_axis_key(get(trace.fields, :yaxis, "y"))
		for (letter, key) in (('x', xkey), ('y', ykey))
			key === nothing && continue
			acc = get!(_FinAxisAcc, accs, key)
			kind === :tight && (acc.tight = true)
			kind === :loose && (acc.loose = true)
			letter == 'y' && is_image && xkey !== nothing && (acc.image_x = xkey)
			acc.unsupported && continue
			axis_type = _fin_axis_type(layout, key)
			if !(axis_type in ("-", "linear", "log"))
				acc.unsupported = true
				continue
			end
			_fin_acc_extend!(acc, _fin_trace_extent(trace, letter, axis_type == "log"))
		end
	end
	for (key, acc) in accs
		acc.unsupported && continue
		_fin_acc_extend!(acc, _fin_layout_item_extent(
			layout,
			_fin_axis_ref(key),
			String(key)[1],
			_fin_axis_type(layout, key) == "log",
		))
	end
	return accs
end

# ---------------------------------------------------------------------------
# M2: sticky ranges
# ---------------------------------------------------------------------------

"""
	_fin_sticky_clip(axis_attr) -> (lo, hi) | nothing

The clip `_finalize_figure!` wrote on an axis: its signature is an
`autorangeoptions` holding exactly `clipmin = lo`, `clipmax = hi` and
`include = [lo, hi]` (data units, also on a log axis). Any other
`autorangeoptions` was set by the user and returns `nothing`.
"""
function _fin_sticky_clip(axis)
	opts = _fin_field(axis, :autorangeoptions)
	opts isa PlotlyBase.PlotlyAttribute && (opts = opts.fields)
	opts isa AbstractDict || return nothing
	length(opts) == 3 || return nothing
	lo = _cmn_mapping_get(opts, :clipmin)
	hi = _cmn_mapping_get(opts, :clipmax)
	include = _cmn_mapping_get(opts, :include)
	(_fin_isfinite_real(lo) && _fin_isfinite_real(hi) && lo < hi) || return nothing
	(include isa AbstractVector && length(include) == 2 &&
		_fin_isreal(include[1]) && _fin_isreal(include[2]) &&
		include[1] == lo && include[2] == hi) || return nothing
	return (Float64(lo), Float64(hi))
end

_fin_sticky_signature(lo::Float64, hi::Float64) =
	attr(clipmin = lo, clipmax = hi, include = [lo, hi])

function _fin_range_pair(range)
	(range isa AbstractVector || range isa Tuple) && length(range) == 2 || return nothing
	(_fin_isfinite_real(range[1]) && _fin_isfinite_real(range[2])) || return nothing
	return (Float64(range[1]), Float64(range[2]))
end

_fin_close(a::Float64, b::Float64, scale::Float64) = abs(a - b) <= 1e-9 * max(scale, 1e-300)

# How the range of axis `axis` (a group root) is decided:
# - `(:auto, reversed)`: plotly autoranges it (`autorange` true or "reversed",
#   or neither `autorange` nor `range` given; an image trace reverses a y axis
#   by default, `implicit_reversed`);
# - `(:pinned, reversed)`: `_finalize_figure!` fixed it to its own clip (see
#   `_fin_sticky_updates!`);
# - `(:explicit, false)`: anything else - a user range, `autorange = false`,
#   "min"/"max" partial autoranges. Never touched.
function _fin_axis_mode(axis, clip, islog::Bool, implicit_reversed::Bool)
	auto = _fin_field(axis, :autorange)
	range = _fin_field(axis, :range)
	auto === true && return (:auto, false)
	_fin_string(auto) == "reversed" && return (:auto, true)
	auto === nothing && range === nothing && return (:auto, implicit_reversed)
	if auto === false && clip !== nothing
		pair = _fin_range_pair(range)
		if pair !== nothing
			lo, hi = islog ? (log10(clip[1]), log10(clip[2])) : clip
			scale = abs(hi - lo)
			_fin_close(pair[1], lo, scale) && _fin_close(pair[2], hi, scale) && return (:pinned, false)
			_fin_close(pair[1], hi, scale) && _fin_close(pair[2], lo, scale) && return (:pinned, true)
		end
	end
	return (:explicit, false)
end

# Axes tied by an aspect constraint: `scaleanchor` in either direction, and
# the y axis of an image trace without a `scaleanchor` entry (plotly.js 2.35.2
# anchors it to its x axis by default and constrains both to the domain).
function _fin_aspect_axes(layout::Layout, accs)
	linked = Set{Symbol}()
	for (key, axis) in layout.fields
		_fin_is_axis_key(key) || continue
		target = _fin_axis_key(_fin_field(axis, :scaleanchor))
		target === nothing && continue
		push!(linked, key)
		push!(linked, target)
	end
	for (key, acc) in accs
		acc.image_x === nothing && continue
		_fin_field(get(layout.fields, key, nothing), :scaleanchor) === nothing || continue
		push!(linked, key)
		push!(linked, acc.image_x)
	end
	return linked
end

# The sticky-range updates (`relayout!` keys) of a figure.
#
# An autoranging axis group (`matches` root and members) whose traces include
# a tight field, no loose field and nothing whose extent is not computed here
# gets the signature `autorangeoptions = {clipmin = lo, clipmax = hi,
# include = [lo, hi]}` on every member: [lo, hi] is the union of the field
# extents and of all other data on the group. plotly then autoranges to exactly
# [lo, hi] (render probe p3: linear, log in data units, reversed, matched).
#
# On an aspect-constrained group plotly.js 2.35.2 re-derives the autorange
# from the padded data extremes while it enforces the constraint, ignoring
# the clip (probe p7: heatmap + one marker outside, clip [-0.05, 5.5] gave
# x = [-0.05, 2.725]). There the root is pinned instead: `autorange = false`
# and `range` = the clip (log10 on a log axis, descending when it was
# reversed), next to the same signature, which marks the range as ours.
#
# A group that stops qualifying gets the signature removed and, if pinned, its
# autorange back. User ranges and user `autorangeoptions` are never touched.
function _fin_sticky_updates!(updates::Dict{Symbol, Any}, p::Plot)
	layout = p.layout
	fields = layout.fields
	accs = _fin_collect_axes(p)
	groups = Dict{Symbol, Vector{Symbol}}()
	for key in union(keys(accs), (k for k in keys(fields) if _fin_is_axis_key(k)))
		root = _fin_match_root(fields, key)
		root === nothing && continue
		members = get!(Vector{Symbol}, groups, root)
		key in members || push!(members, key)
		root in members || push!(members, root)
	end
	aspect = _fin_aspect_axes(layout, accs)
	for (root, members) in groups
		root_axis = get(fields, root, nothing)
		any(m -> (axis = get(fields, m, nothing);
			_fin_field(axis, :autorangeoptions) !== nothing && _fin_sticky_clip(axis) === nothing),
			members) && continue
		islog = _fin_axis_type(layout, root) == "log"
		any(m -> (_fin_axis_type(layout, m) == "log") != islog, members) && continue
		acc = _FinAxisAcc()
		for member in members
			macc = get(accs, member, nothing)
			macc === nothing && continue
			acc.tight |= macc.tight
			acc.loose |= macc.loose
			acc.unsupported |= macc.unsupported
			macc.image_x === nothing || (acc.image_x = macc.image_x)
			acc.lo = min(acc.lo, macc.lo)
			acc.hi = max(acc.hi, macc.hi)
		end
		clip = _fin_sticky_clip(root_axis)
		implicit_reversed = String(root)[1] == 'y' && acc.image_x !== nothing
		mode, reversed = _fin_axis_mode(root_axis, clip, islog, implicit_reversed)
		mode === :explicit && continue
		sticky = acc.tight && !acc.loose && !acc.unsupported &&
			isfinite(acc.lo) && isfinite(acc.hi) && acc.lo < acc.hi &&
			(!islog || acc.lo > 0)
		if sticky
			lo, hi = acc.lo, acc.hi
			for member in members
				_fin_sticky_clip(get(fields, member, nothing)) == (lo, hi) && continue
				updates[Symbol(member, :_autorangeoptions)] = _fin_sticky_signature(lo, hi)
			end
			if any(in(aspect), members)
				l, h = islog ? (log10(lo), log10(hi)) : (lo, hi)
				want = reversed ? [h, l] : [l, h]
				_fin_field(root_axis, :autorange) === false ||
					(updates[Symbol(root, :_autorange)] = false)
				_fin_range_pair(_fin_field(root_axis, :range)) == (want[1], want[2]) ||
					(updates[Symbol(root, :_range)] = want)
			elseif mode === :pinned
				updates[Symbol(root, :_autorange)] = reversed ? "reversed" : true
				updates[Symbol(root, :_range)] = nothing
			end
		else
			for member in members
				_fin_sticky_clip(get(fields, member, nothing)) === nothing && continue
				updates[Symbol(member, :_autorangeoptions)] = nothing
			end
			if mode === :pinned
				updates[Symbol(root, :_autorange)] = reversed ? "reversed" : true
				updates[Symbol(root, :_range)] = nothing
			end
		end
	end
	return updates
end

# ---------------------------------------------------------------------------
# Writing (transaction-aware)
# ---------------------------------------------------------------------------

# Where `_finalize_figure!` writes. `readonly` holds the trace objects it must
# not write: on the append-only fast path the traces that existed before the
# mutation are the live ones. `clone_readonly` (export copies) replaces such a
# trace by a private clone instead.
struct _FinContext
	target::Any
	p::Plot
	sf::Union{Nothing, SubplotFigure}
	readonly::Union{Nothing, Base.IdSet{Any}}
	clone_readonly::Bool
	size::Union{Nothing, NTuple{2, Float64}}
end

_fin_trace_writable(ctx::_FinContext, index::Int) =
	ctx.readonly === nothing || ctx.clone_readonly || !(ctx.p.data[index] in ctx.readonly)

function _fin_restyle!(ctx::_FinContext, index::Int, updates::Dict{Symbol, Any})
	isempty(updates) && return nothing
	trace = ctx.p.data[index]
	if ctx.readonly !== nothing && trace in ctx.readonly
		ctx.clone_readonly || throw(ArgumentError(
			"_finalize_figure!: trace $(index) is shared with the live figure and cannot be written here.",
		))
		ctx.p.data[index] = _clone_trace_for_mutation(trace, IdDict{Any, Any}())
	end
	target = ctx.target
	# Keyword updates: `colorbar_x` addresses the nested path (a Dict update
	# would store the literal key `colorbar_x`).
	if target isa SyncPlot
		restyle!(target, index; updates...)
	else
		restyle!(_plot_obj(target), index; updates...)
	end
	return nothing
end

function _fin_relayout!(ctx::_FinContext, updates::Dict{Symbol, Any})
	isempty(updates) && return false
	relayout!(ctx.target; updates...)
	return true
end

# ---------------------------------------------------------------------------
# Pixel estimates (M3/M4): margins, tick labels, colorbar widths
# ---------------------------------------------------------------------------

# plotly.js 2.35.2 `layout.margin` defaults.
const _FIN_PLOTLY_MARGIN = (l = 80.0, r = 80.0, t = 100.0, b = 80.0)
# With a positive margin, an automargin push of P px (labels, titles, colour
# bars reaching P px past the plot area) makes the margin P + 12 px (render
# probe p6: y labels needing 53 px at margin 0 gave l = 65 for margins 20..60;
# probe p4: a colorbar reaching 90.4 px past the plot gave r = 102).
const _FIN_AUTOMARGIN_EXTRA = 12.0
# Measured px of an axis title (font size f) added to the tick-label push:
# 15.5 + 0.7 f (probe p5: f = 10, 14, 20, 28 added 22, 25, 29, 35 px).
const _FIN_TITLE_BASE = 15.5
const _FIN_TITLE_PER_PX = 0.7
# Gap between the plot area of an equal-aspect cell and its colorbar, as a
# fraction of the plot-area width (the subplot cell value, spec F5).
const _FIN_CBAR_PAD = 0.01
# Gap between two colorbars placed side by side, in px.
const _FIN_CBAR_GAP = 6.0

function _fin_margins_base(layout::Layout)
	margin = get(layout.fields, :margin, nothing)
	get_side(side, default) = (v = _cmn_mapping_get(margin, side);
		_fin_isfinite_real(v) && v >= 0 ? Float64(v) : default)
	return (
		l = get_side(:l, _FIN_PLOTLY_MARGIN.l),
		r = get_side(:r, _FIN_PLOTLY_MARGIN.r),
		t = get_side(:t, _FIN_PLOTLY_MARGIN.t),
		b = get_side(:b, _FIN_PLOTLY_MARGIN.b),
	)
end

function _fin_font_size(layout::Layout)
	size = _cmn_mapping_get(get(layout.fields, :font, nothing), :size)
	return _fin_isfinite_real(size) && size > 0 ? Float64(size) : 12.0
end

function _fin_mapping_font_size(mapping, key::Symbol, default::Float64)
	size = _cmn_mapping_get(_cmn_mapping_get(mapping, key), :size)
	return _fin_isfinite_real(size) && size > 0 ? Float64(size) : default
end

# Visible characters of a tick or title text: HTML tags, `$` delimiters and
# TeX braces/scripts dropped, a TeX command counted as one glyph.
function _fin_text_chars(text)
	s = text isa AbstractString ? String(text) : string(text)
	s = replace(s, r"<[^>]*>" => "", r"\\[A-Za-z]+" => "x", r"[\$\{\}\^_]" => "")
	return length(s)
end

# Characters of a tick label of value `v` printed with `decimals` decimals
# (plotly's default exponent format abbreviates 10^4 and up as k, M, G).
function _fin_number_chars(v::Float64, decimals::Int)
	a = abs(v)
	sign = v < 0 ? 1 : 0
	if a >= 1e4
		digits = floor(Int, log10(a)) + 1
		return sign + (digits - 1) % 3 + 2
	end
	whole = a < 1 ? 1 : floor(Int, log10(a)) + 1
	return sign + whole + (decimals > 0 ? decimals + 1 : 0)
end

# Rough plotly tick step: about one tick per 40 px on a vertical axis and per
# 80 px on a horizontal one (4 to 10 ticks), rounded up to 1, 2 or 5 x 10^k.
function _fin_nice_step(span::Float64, len_px::Float64, vertical::Bool)
	count = clamp(len_px / (vertical ? 40.0 : 80.0), 4.0, 9.0) + 1
	rough = span / count
	rough > 0 || return 1.0
	base = exp10(floor(log10(rough)))
	for mult in (1.0, 2.0, 5.0, 10.0)
		mult * base >= rough * (1 - 1e-9) && return mult * base
	end
	return 10.0 * base
end

# Widest tick label (characters) of an axis or colorbar mapping showing
# [lo, hi] (l-units: log10 on a log axis) over `len_px`.
function _fin_tick_chars(mapping, lo::Float64, hi::Float64, len_px::Float64, islog::Bool, vertical::Bool)
	_cmn_mapping_get(mapping, :showticklabels) === false && return 0
	text = _cmn_mapping_get(mapping, :ticktext)
	if (text isa AbstractVector || text isa Tuple) && !isempty(text)
		return maximum(_fin_text_chars, text)
	end
	extra = 0
	for key in (:tickprefix, :ticksuffix)
		affix = _cmn_mapping_get(mapping, key)
		affix isa AbstractString && (extra += _fin_text_chars(affix))
	end
	values = _cmn_mapping_get(mapping, :tickvals)
	if (values isa AbstractVector || values isa Tuple) && !isempty(values)
		reals = [Float64(v) for v in values if _fin_isfinite_real(v)]
		isempty(reals) && return 4 + extra
		decimals = maximum(v -> v == round(v) ? 0 : clamp(ceil(Int, -log10(abs(v - round(v)) + eps())), 0, 6), reals)
		return maximum(v -> _fin_number_chars(v, decimals), reals) + extra
	end
	(isfinite(lo) && isfinite(hi) && hi > lo) || return 4 + extra
	if islog
		return maximum(e -> _fin_number_chars(exp10(e), max(0, -e)), floor(Int, lo):ceil(Int, hi)) + extra
	end
	dtick = _cmn_mapping_get(mapping, :dtick)
	step = _fin_isfinite_real(dtick) && dtick > 0 ? Float64(dtick) :
		_fin_nice_step(hi - lo, max(len_px, 1.0), vertical)
	decimals = max(0, -floor(Int, log10(step) + 1e-9))
	chars = 1
	first = ceil(lo / step - 1e-9)
	count = 0
	k = first
	while k * step <= hi + 1e-9 * step && count < 60
		chars = max(chars, _fin_number_chars(k * step, decimals))
		k += 1
		count += 1
	end
	return chars + extra
end

_fin_title_text(mapping) = begin
	title = _cmn_mapping_get(mapping, :title)
	text = title isa AbstractString ? title : _cmn_mapping_get(title, :text)
	text isa AbstractString ? text : ""
end

function _fin_title_push(mapping, font::Float64)
	isempty(_fin_title_text(mapping)) && return 0.0
	size = _fin_mapping_font_size(_cmn_mapping_get(mapping, :title), :font, round(1.2 * font))
	return _FIN_TITLE_BASE + _FIN_TITLE_PER_PX * size
end

function _fin_tick_len(mapping)
	_fin_string(_cmn_mapping_get(mapping, :ticks)) == "outside" || return 0.0
	len = _cmn_mapping_get(mapping, :ticklen)
	return _fin_isfinite_real(len) && len >= 0 ? Float64(len) : 5.0
end

_fin_automargin(axis) = (v = _cmn_mapping_get(axis, :automargin);
	v === true || (v isa AbstractString && !isempty(v) && v != "false"))

# [lo, hi] in l-units shown by an axis: its fixed range, the sticky clip, or
# the data extent collected for it; `nothing` when unknown.
function _fin_shown_range(layout::Layout, key::Symbol, accs)
	fields = layout.fields
	root = something(_fin_match_root(fields, key), key)
	axis = get(fields, root, nothing)
	islog = _fin_axis_type(layout, key) == "log"
	auto = _fin_field(axis, :autorange)
	pair = _fin_range_pair(_fin_field(axis, :range))
	if pair !== nothing && (auto === false || auto === nothing)
		return minmax(pair[1], pair[2])
	end
	clip = _fin_sticky_clip(axis)
	if clip !== nothing
		return islog ? (log10(clip[1]), log10(clip[2])) : clip
	end
	acc = get(accs, key, nothing)
	(acc === nothing || !(acc.lo < acc.hi)) && return nothing
	islog && return acc.lo > 0 ? (log10(acc.lo), log10(acc.hi)) : nothing
	return (acc.lo, acc.hi)
end

_fin_domain(layout::Layout, key::Symbol) =
	something(_layout_axis_domain(layout, key), (0.0, 1.0))

# Estimated px margins of a figure W x H: the layout margins grown by the
# automargin pushes of the tick labels and titles of the axes on the left and
# bottom edges of the paper, and by colorbars reaching past its right edge
# (`bars`: (x, xanchor, width_px) in paper fractions/px). `domains` overrides
# axis domains (fitted values not written yet).
function _fin_margins(layout::Layout, accs, W::Float64, H::Float64, domains, bars)
	base = _fin_margins_base(layout)
	font = _fin_font_size(layout)
	fields = layout.fields
	push_l = 0.0
	push_b = 0.0
	Hp = max(H - base.t - base.b, 1.0)
	Wp = max(W - base.l - base.r, 1.0)
	domain_of(key) = get(domains, key, _fin_domain(layout, key))
	for (key, axis) in fields
		_fin_is_axis_key(key) || continue
		_cmn_mapping_get(axis, :visible) === false && continue
		_fin_automargin(axis) || continue
		_fin_string(_cmn_mapping_get(axis, :overlaying)) === nothing ||
			_fin_string(_cmn_mapping_get(axis, :overlaying)) == "free" || continue
		letter = String(key)[1]
		anchor = _fin_axis_key(_cmn_mapping_get(axis, :anchor, letter == 'y' ? "x" : "y"))
		anchor === nothing && continue
		tickfont = _fin_mapping_font_size(axis, :tickfont, font)
		shown = _fin_shown_range(layout, key, accs)
		lo, hi = shown === nothing ? (NaN, NaN) : shown
		islog = _fin_axis_type(layout, key) == "log"
		dom = domain_of(key)
		if letter == 'y'
			something(_fin_string(_cmn_mapping_get(axis, :side)), "left") == "left" || continue
			domain_of(anchor)[1] <= 0.005 || continue
			chars = _fin_tick_chars(axis, lo, hi, (dom[2] - dom[1]) * Hp, islog, true)
			push = chars * 0.6 * tickfont + _fin_tick_len(axis) + 2 + _fin_title_push(axis, font)
			push_l = max(push_l, push)
		else
			something(_fin_string(_cmn_mapping_get(axis, :side)), "bottom") == "bottom" || continue
			domain_of(anchor)[1] <= 0.005 || continue
			showlabels = _cmn_mapping_get(axis, :showticklabels) !== false
			push = (showlabels ? 1.4 * tickfont + 1 : 0.0) + _fin_tick_len(axis) + _fin_title_push(axis, font)
			push_b = max(push_b, push)
		end
	end
	grow(m, push) = push <= 0 ? m : (m > 0 ? max(m, push + _FIN_AUTOMARGIN_EXTRA) : max(m, push))
	l = grow(base.l, push_l)
	b = grow(base.b, push_b)
	t = base.t
	r = base.r
	for _ in 1:4
		Wp = max(W - l - r, 1.0)
		overflow = 0.0
		for bar in bars
			left = bar.x * Wp - (bar.xanchor == "center" ? bar.width / 2 : bar.xanchor == "right" ? bar.width : 0.0)
			overflow = max(overflow, left + bar.width - Wp)
		end
		r = grow(base.r, overflow)
	end
	return (l = l, r = r, t = t, b = b)
end

# ---------------------------------------------------------------------------
# Colorbars (M3 hugging, M4 side by side)
# ---------------------------------------------------------------------------

# One colorbar drawn on a plot area: a trace's own bar (`index`, `slot`) or a
# coloraxis bar (`coloraxis`).
struct _FinBar
	index::Int
	slot::Union{Nothing, _CbarSlot}
	coloraxis::Union{Nothing, String}
	bar::Dict{Symbol, Any}
	range::Union{Nothing, Tuple{Float64, Float64}}
	# The plot area the trace is drawn in (`_cbar_trace_region`); for a trace
	# in an inset the bar is listed under the inset's host cell instead.
	own::Any
	inset::Bool
end

_fin_bar_vertical(bar::Dict{Symbol, Any}) = _cbar_string(bar, :orientation, "v") == "v"

# Placement keys `_finalize_figure!` owns on a bar it placed: it always
# writes `xref = "paper"` explicitly next to a left-anchored fractional bar.
_fin_bar_owned(bar::Dict{Symbol, Any}) =
	_cbar_string(bar, :xref, "") == "paper" &&
	_cbar_string(bar, :xanchor, "") == "left" &&
	_cbar_string(bar, :lenmode, "") == "fraction" &&
	_cbar_real(bar, :x, nothing) !== nothing

_fin_bar_unplaced(bar::Dict{Symbol, Any}) =
	!haskey(bar, :x) && !haskey(bar, :y) && !haskey(bar, :len)

# Pixel width of a vertical colorbar box from its anchor: x padding, bar,
# ticks, tick labels and a title on its right side.
function _fin_bar_width(layout::Layout, item::_FinBar, Hp::Float64)
	bar = item.bar
	font = _fin_font_size(layout)
	thickness = _cbar_string(bar, :thicknessmode, "pixels") == "pixels" ?
		_cbar_real(bar, :thickness, _CBAR_DEFAULT_THICKNESS) : _CBAR_DEFAULT_THICKNESS
	xpad = _cbar_real(bar, :xpad, _CBAR_DEFAULT_XPAD)
	len = _cbar_string(bar, :lenmode, "fraction") == "fraction" ?
		_cbar_real(bar, :len, 1.0) * Hp : _cbar_real(bar, :len, Hp)
	ypad = _cbar_real(bar, :ypad, 10.0)
	lo, hi = item.range === nothing ? (NaN, NaN) : item.range
	chars = _fin_tick_chars(bar, lo, hi, max(len - 2ypad, 1.0), false, true)
	tickfont = _fin_mapping_font_size(bar, :tickfont, font)
	labels = chars == 0 ? 0.0 : chars * 0.6 * tickfont + 5.5
	width = xpad + thickness + _fin_tick_len(bar) + labels
	title = _cmn_mapping_get(bar, :title)
	side = _fin_string(_cmn_mapping_get(title, :side))
	text = title isa AbstractString ? title : _cmn_mapping_get(title, :text)
	if side == "right" && text isa AbstractString && !isempty(text)
		width += 1.4 * _fin_mapping_font_size(title, :font, font) + 4
	end
	return width
end

# The host cell of an inset (`_cbar_trace_region`-like), `nothing` when its
# grid cell cannot be resolved.
function _fin_inset_host_region(p::Plot, inset)
	grid_ref = p.layout.subplots.grid_ref
	(checkbounds(Bool, grid_ref, inset.row, inset.col) &&
		isassigned(grid_ref, inset.row, inset.col) &&
		!isempty(grid_ref[inset.row, inset.col])) || return nothing
	fields = first(grid_ref[inset.row, inset.col]).trace_kwargs.fields
	xref = _fin_string(get(fields, :xaxis, nothing))
	yref = _fin_string(get(fields, :yaxis, nothing))
	xkey = _fin_axis_key(xref)
	ykey = _fin_axis_key(yref)
	(xkey === nothing || ykey === nothing) && return nothing
	return (
		key = xref,
		xdomain = _fin_domain(p.layout, xkey),
		ydomain = _cmn_y_axis_domain(p.layout, ykey),
	)
end

# The colorbars of a figure grouped by plot area (`_cbar_trace_region` key;
# the bar of a trace in an inset is listed under the inset's host cell), in
# trace order. Coloraxis bars are listed under the area of their first trace;
# `areas` maps a coloraxis id to all area keys it is drawn for.
function _fin_collect_bars(p::Plot, sf = nothing)
	by_area = Dict{String, Vector{_FinBar}}()
	order = String[]
	regions = Dict{String, Any}()
	coloraxis_areas = Dict{String, Vector{String}}()
	coloraxis_ranges = Dict{String, Tuple{Float64, Float64}}()
	insets = sf === nothing ? () : getfield(sf, :insets)
	for index in eachindex(p.data)
		trace = p.data[index]
		trace isa GenericTrace || continue
		_fin_visible(trace) || continue
		slot = _cbar_slot(trace, index)
		slot === nothing && continue
		own = _cbar_trace_region(p, trace)
		region = own
		in_inset = false
		if !isempty(insets) && _cbar_trace_kind(trace) == "xy"
			xref = string(get(trace.fields, :xaxis, "x"))
			yref = string(get(trace.fields, :yaxis, "y"))
			for inset in insets
				(inset.xref == xref && inset.yref == yref) || continue
				host = _fin_inset_host_region(p, inset)
				host === nothing && break
				region = host
				in_inset = true
				break
			end
		end
		regions[region.key] = region
		range = _cbar_slot_range(trace, slot)
		if slot.coloraxis !== nothing
			areas = get!(Vector{String}, coloraxis_areas, slot.coloraxis)
			if isempty(areas)
				push!(get!(() -> (push!(order, region.key); _FinBar[]), by_area, region.key),
					_FinBar(index, nothing, slot.coloraxis, Dict{Symbol, Any}(), nothing, own, false))
			end
			region.key in areas || push!(areas, region.key)
			if range !== nothing
				old = get(coloraxis_ranges, slot.coloraxis, range)
				coloraxis_ranges[slot.coloraxis] = (min(old[1], range[1]), max(old[2], range[2]))
			end
			continue
		end
		slot.shows || continue
		bar = _symbol_dict(_cbar_slot_bar(trace, slot))
		push!(get!(() -> (push!(order, region.key); _FinBar[]), by_area, region.key),
			_FinBar(index, slot, nothing, bar, range, own, in_inset))
	end
	# Resolve coloraxis bars: their settings live in the layout.
	for key in order
		items = by_area[key]
		for (i, item) in enumerate(items)
			item.coloraxis === nothing && continue
			axis = get(p.layout.fields, Symbol(item.coloraxis), nothing)
			if _cmn_mapping_get(axis, :showscale) === false
				items[i] = _FinBar(0, nothing, nothing, Dict{Symbol, Any}(), nothing, item.own, false)
				continue
			end
			lo = _cmn_mapping_get(axis, :cmin)
			hi = _cmn_mapping_get(axis, :cmax)
			range = (_fin_isfinite_real(lo) && _fin_isfinite_real(hi)) ? (Float64(lo), Float64(hi)) :
				get(coloraxis_ranges, item.coloraxis, nothing)
			items[i] = _FinBar(item.index, nothing, item.coloraxis,
				_symbol_dict(_cmn_mapping_get(axis, :colorbar)), range, item.own, false)
		end
		filter!(item -> item.slot !== nothing || item.coloraxis !== nothing, items)
	end
	return by_area, order, regions, coloraxis_areas
end

# Write `placement` into bar `item` (only the keys that change).
function _fin_place_bar!(ctx::_FinContext, layout_updates::Dict{Symbol, Any}, item::_FinBar, placement::Dict{Symbol, Any})
	changes = Dict{Symbol, Any}()
	for (key, value) in placement
		current = get(item.bar, key, nothing)
		same = value isa Real && current isa Real ? isapprox(Float64(current), Float64(value); atol = 1e-9) :
			isequal(current, value)
		same || (changes[key] = value)
	end
	isempty(changes) && return false
	if item.coloraxis !== nothing
		for (key, value) in changes
			layout_updates[Symbol(item.coloraxis, "_colorbar_", key)] = value
		end
	else
		prefix = item.slot.container === :root ? "colorbar_" : "$(item.slot.container)_colorbar_"
		_fin_restyle!(ctx, item.index, Dict{Symbol, Any}(Symbol(prefix, key) => value for (key, value) in changes))
	end
	return true
end

_fin_item_writable(ctx::_FinContext, item::_FinBar) =
	item.coloraxis !== nothing || _fin_trace_writable(ctx, item.index)

# ---------------------------------------------------------------------------
# M3: equal-aspect cells
# ---------------------------------------------------------------------------

# Equal-aspect cells: (xkey, ykey, w_over_h) where w_over_h is the plot-box
# width/height per unit of (x range span / y range span) in l-units.
function _fin_aspect_cells(layout::Layout, accs)
	cells = Tuple{Symbol, Symbol, Float64}[]
	fields = layout.fields
	ratio_of(axis) = (s = _cmn_mapping_get(axis, :scaleratio); _fin_isfinite_real(s) && s > 0 ? Float64(s) : 1.0)
	for (key, axis) in fields
		_fin_is_axis_key(key) || continue
		target = _fin_axis_key(_fin_field(axis, :scaleanchor))
		target === nothing && continue
		letter = String(key)[1]
		String(target)[1] == letter && continue
		if letter == 'y'
			# y unit = s * x unit in px: w/h = (rx/ry) / s
			push!(cells, (target, key, 1 / ratio_of(axis)))
		else
			# x unit = s * y unit in px: w/h = s * rx/ry
			push!(cells, (key, target, ratio_of(axis)))
		end
	end
	for (key, acc) in accs
		acc.image_x === nothing && continue
		_fin_field(get(fields, key, nothing), :scaleanchor) === nothing || continue
		push!(cells, (acc.image_x, key, 1.0))
	end
	return unique(cells)
end

_fin_is_base_axis(layout::Layout, key::Symbol) =
	(o = _fin_string(_cmn_mapping_get(get(layout.fields, key, nothing), :overlaying));
	o === nothing || o == "free")

# Reference area (paper fractions) an equal-aspect cell is fitted into: its
# subplot grid cell (recomputed from `layout.subplots`), its inset record, or
# the whole paper for the primary axes of a figure without other plot areas.
function _fin_reference(ctx::_FinContext, layout::Layout, xkey::Symbol, ykey::Symbol, grid_layout)
	sub = layout.subplots
	if sub.rows * sub.cols > 1
		ref_layout = grid_layout[]
		if ref_layout === nothing
			ref_layout = _plotlysupply_subplot_layout(sub)
			grid_layout[] = ref_layout
		end
		xd = _layout_axis_domain(ref_layout, xkey)
		yd = _layout_axis_domain(ref_layout, ykey)
		xd !== nothing && yd !== nothing && return (xd, yd)
	end
	if ctx.sf !== nothing
		for inset in getfield(ctx.sf, :insets)
			inset.xkey === xkey && inset.ykey === ykey && return (inset.xdomain, inset.ydomain)
		end
	end
	sub.rows * sub.cols > 1 && return nothing
	(xkey === :xaxis && ykey === :yaxis) || return nothing
	inset_keys = Set{Symbol}()
	if ctx.sf !== nothing
		for inset in getfield(ctx.sf, :insets)
			push!(inset_keys, inset.xkey, inset.ykey)
		end
	end
	for (key, axis) in layout.fields
		_fin_is_axis_key(key) || continue
		(key in (:xaxis, :yaxis) || key in inset_keys) && continue
		_fin_is_base_axis(layout, key) || continue
		# Another plot area with its own domain shares the paper.
		_layout_axis_domain(layout, key) === nothing || return nothing
	end
	return ((0.0, 1.0), (0.0, 1.0))
end

_fin_within(d::NTuple{2, Float64}, ref::NTuple{2, Float64}) =
	d[1] >= ref[1] - 1e-6 && d[2] <= ref[2] + 1e-6 && d[1] < d[2]

# Horizontal room (px) a colorbar may take beyond the right edge of a cell's
# reference area: part of the right margin at the paper edge, half the gap to
# the next cell otherwise.
function _fin_right_allowance(layout::Layout, ref, grid_layout, Wp::Float64)
	if ref[1][2] >= 1 - 1e-6
		return max(0.0, _fin_margins_base(layout).r - _FIN_AUTOMARGIN_EXTRA - 4)
	end
	ref_layout = grid_layout[]
	gap = 1.0 - ref[1][2]
	if ref_layout !== nothing
		for (key, axis) in ref_layout.fields
			_fin_is_axis_key(key) && String(key)[1] == 'x' || continue
			xd = _layout_axis_domain(ref_layout, key)
			xd === nothing && continue
			xd[1] >= ref[1][2] - 1e-9 || continue
			anchor = _fin_axis_key(_cmn_mapping_get(axis, :anchor))
			yd = anchor === nothing ? nothing : _layout_axis_domain(ref_layout, anchor)
			yd === nothing || (yd[1] < ref[2][2] && yd[2] > ref[2][1]) || continue
			gap = min(gap, xd[1] - ref[1][2])
		end
	end
	return max(0.0, 0.5 * gap * Wp)
end

# Figure px size used for the fit: the export size, the layout size, or the
# package export defaults for a size the layout leaves open.
function _fin_figure_size(ctx::_FinContext, layout::Layout)
	ctx.size === nothing || return ctx.size
	w = get(layout.fields, :width, nothing)
	h = get(layout.fields, :height, nothing)
	return (
		_fin_isfinite_real(w) && w > 0 ? Float64(w) : _DEFAULT_EXPORT_WIDTH_PX,
		_fin_isfinite_real(h) && h > 0 ? Float64(h) : _DEFAULT_EXPORT_HEIGHT_PX,
	)
end

# Single figures without a size (decision D10 M3a): the default width, the
# height derived from the field aspect; a tall field keeps the default height
# and derives the width. Bounds: height 200..default, width 300..default (px);
# whatever the bounds cut off is absorbed by the domain fit.
const _FIN_MIN_FIGURE_HEIGHT = 200.0
const _FIN_MIN_FIGURE_WIDTH = 300.0

# Bias (px) by which a fitted x domain exceeds the plot width it needs, so that
# plotly's exactness guard (`constrain = "domain"`) always shrinks x, toward
# its colorbar (`constraintoward = "right"`), and never y: the bar length then
# equals the plot height exactly even when the margin estimate is a few px off.
_fin_bias(w::Float64) = 0.025 * w + 4.0

# The fitted domains and bar placements of every equal-aspect cell.
function _fin_fit_cells(ctx::_FinContext, layout::Layout, accs, bars_by_area, W::Float64, H::Float64)
	results = Dict{Tuple{Symbol, Symbol}, Any}()
	grid_layout = Ref{Any}(nothing)
	cells = _fin_aspect_cells(layout, accs)
	isempty(cells) && return results
	domains = Dict{Symbol, NTuple{2, Float64}}()
	placed = Dict{Tuple{Symbol, Symbol}, Any}()
	# Two passes: the margins depend on where the fitted cells and bars end up.
	for pass in 1:2
		bar_boxes = Any[]
		moved = Set{Int}(item.index for (_, fit) in placed for item in fit.hug)
		for (key, items) in bars_by_area
			for item in items
				_fin_bar_vertical(item.bar) || continue
				item.slot !== nothing && item.index in moved && continue
				x = _cbar_real(item.bar, :x, 1.02)
				push!(bar_boxes, (x = x, xanchor = _cbar_string(item.bar, :xanchor, "left"),
					width = _fin_bar_width(layout, item, H)))
			end
		end
		for (_, fit) in placed
			for (x, width) in fit.bar_boxes
				push!(bar_boxes, (x = x, xanchor = "left", width = width))
			end
		end
		margins = _fin_margins(layout, accs, W, H, domains, bar_boxes)
		Wp = W - margins.l - margins.r
		Hp = H - margins.t - margins.b
		(Wp > 20 && Hp > 20) || return results
		for (xkey, ykey, w_per) in cells
			(_fin_is_base_axis(layout, xkey) && _fin_is_base_axis(layout, ykey)) || continue
			rx = _fin_shown_range(layout, xkey, Dict{Symbol, _FinAxisAcc}())
			ry = _fin_shown_range(layout, ykey, Dict{Symbol, _FinAxisAcc}())
			(rx === nothing || ry === nothing) && continue
			# Only fixed (user or pinned) ranges are known before rendering.
			for key in (xkey, ykey)
				root = something(_fin_match_root(layout.fields, key), key)
				axis = get(layout.fields, root, nothing)
				auto = _fin_field(axis, :autorange)
				(auto === false || (auto === nothing && _fin_has_range(axis))) || (rx = nothing)
			end
			rx === nothing && continue
			ratio = w_per * (rx[2] - rx[1]) / (ry[2] - ry[1])
			(isfinite(ratio) && ratio > 0) || continue
			ref = _fin_reference(ctx, layout, xkey, ykey, grid_layout)
			ref === nothing && continue
			(_fin_within(_fin_domain(layout, xkey), ref[1]) && _fin_within(_fin_domain(layout, ykey), ref[2])) ||
				continue
			area = _fin_axis_ref(xkey) * "/" * _fin_axis_ref(ykey)
			# The trace bars of this cell (by area key = x ref) that are ours to move.
			hug = _FinBar[]
			for item in get(bars_by_area, _fin_axis_ref(xkey), _FinBar[])
				item.slot === nothing && continue
				trace = ctx.p.data[item.index]
				string(get(trace.fields, :yaxis, "y")) == _fin_axis_ref(ykey) || continue
				_fin_bar_vertical(item.bar) || continue
				cell_default = _cbar_placement(:right, _fin_domain(layout, xkey), _fin_domain(layout, ykey), _CBAR_CELL_PAD)
				(_fin_bar_unplaced(item.bar) || _fin_bar_owned(item.bar) ||
					_cbar_placement_matches(item.bar, cell_default)) || continue
				push!(hug, item)
			end
			pad_px = _FIN_CBAR_PAD * Wp
			widths = [_fin_bar_width(layout, item, Hp) for item in hug]
			allow = _fin_right_allowance(layout, ref, grid_layout, Wp)
			room = isempty(hug) ? 0.0 : max(0.0, pad_px + sum(widths) + _FIN_CBAR_GAP * (length(hug) - 1) - allow)
			rw = (ref[1][2] - ref[1][1]) * Wp
			rh = (ref[2][2] - ref[2][1]) * Hp
			Wa = rw - room
			(Wa > 20 && rh > 20) || continue
			if Wa - _fin_bias(rh * ratio) >= rh * ratio
				h = rh
				w = rh * ratio
			else
				w = Wa / 1.025 - 4.0 / 1.025
				h = w / ratio
			end
			bias = _fin_bias(w)
			free = max(0.0, rw - (w + bias + room))
			x0 = ref[1][1] * Wp + free / 2
			y0 = ref[2][1] * Hp + (rh - h) / 2
			xd = (x0 / Wp, (x0 + w + bias) / Wp)
			yd = (y0 / Hp, (y0 + h) / Hp)
			domains[xkey] = xd
			domains[ykey] = yd
			boxes = Tuple{Float64, Float64}[]
			placements = Dict{Symbol, Any}[]
			x = xd[2] + _FIN_CBAR_PAD
			for (item, width) in zip(hug, widths)
				push!(placements, Dict{Symbol, Any}(
					:x => x, :xanchor => "left", :xref => "paper",
					:y => (yd[1] + yd[2]) / 2, :yanchor => "middle",
					:len => yd[2] - yd[1], :lenmode => "fraction", :ypad => 0,
				))
				push!(boxes, (x, width))
				x += (width + _FIN_CBAR_GAP) / Wp
			end
			placed[(xkey, ykey)] = (xdomain = xd, ydomain = yd, hug = hug, placements = placements,
				bar_boxes = boxes, free_px = free, slack_px = rh - h)
		end
		pass == 2 && (results = placed)
	end
	return results
end

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

function _fin_layout_value_changed(current, value)
	if value isa Tuple || value isa AbstractVector
		pair = _fin_range_pair(current)
		pair === nothing && return true
		return !(isapprox(pair[1], value[1]; atol = 1e-9) && isapprox(pair[2], value[2]; atol = 1e-9))
	elseif value isa Real && current isa Real
		return !isapprox(Float64(current), Float64(value); atol = 1e-9)
	end
	return !isequal(current, value)
end

# M3 and M4 updates: equal-aspect cells, the size of a single equal-aspect
# figure, colorbars side by side. Returns whether anything was written.
function _fin_fit!(ctx::_FinContext)
	p = ctx.p
	layout = p.layout
	accs = _fin_collect_axes(p)
	bars_by_area, area_order, regions, _ = _fin_collect_bars(p, ctx.sf)
	layout_updates = Dict{Symbol, Any}()
	wrote = false
	W, H = _fin_figure_size(ctx, layout)
	fits = _fin_fit_cells(ctx, layout, accs, bars_by_area, W, H)
	# M3a: a single figure without a size is sized to its equal-aspect cell.
	if ctx.size === nothing && ctx.sf === nothing && layout.subplots.rows * layout.subplots.cols == 1 &&
			get(layout.fields, :width, nothing) === nothing && get(layout.fields, :height, nothing) === nothing &&
			haskey(fits, (:xaxis, :yaxis)) && length(fits) == 1
		fit = fits[(:xaxis, :yaxis)]
		# Wide field: keep the width and drop the blank rows above and below
		# the plot box; tall field: keep the height and drop the blank columns.
		newW, newH = W, H
		if fit.slack_px > 1
			newH = clamp(round(H - fit.slack_px), _FIN_MIN_FIGURE_HEIGHT, H)
		elseif fit.free_px > 1
			newW = clamp(round(W - fit.free_px), _FIN_MIN_FIGURE_WIDTH, W)
		end
		layout_updates[:width] = round(Int, newW)
		layout_updates[:height] = round(Int, newH)
		wrote |= _fin_relayout!(ctx, layout_updates)
		empty!(layout_updates)
		W, H = Float64(round(Int, newW)), Float64(round(Int, newH))
		layout = p.layout
		fits = _fin_fit_cells(ctx, layout, accs, bars_by_area, W, H)
	end
	# M3b: fitted domains and hugging bars.
	hugged = Set{Int}()
	hug_end = Dict{String, Any}()    # area key => (x, width_px, placement) of its last hugging bar
	moved = Tuple{_FinBar, Dict{Symbol, Any}}[]
	for ((xkey, ykey), fit) in fits
		all(item -> _fin_item_writable(ctx, item), fit.hug) || continue
		for (key, dom) in ((xkey, fit.xdomain), (ykey, fit.ydomain))
			current = _layout_axis_domain(layout, key)
			_fin_layout_value_changed(current, dom) && (layout_updates[Symbol(key, :_domain)] = [dom[1], dom[2]])
		end
		_fin_layout_value_changed(_cmn_mapping_get(get(layout.fields, xkey, nothing), :constraintoward), "right") &&
			(layout_updates[Symbol(xkey, :_constraintoward)] = "right")
		for (item, placement, box) in zip(fit.hug, fit.placements, fit.bar_boxes)
			wrote |= _fin_place_bar!(ctx, layout_updates, item, placement)
			push!(moved, (item, placement))
			push!(hugged, item.index)
			hug_end[_fin_axis_ref(xkey)] = (box[1], box[2], placement)
		end
	end
	# M4: the other bars of a plot area (and those of its insets) go to the
	# right of the first one, side by side.
	margins = _fin_margins(layout, accs, W, H, Dict{Symbol, NTuple{2, Float64}}(), Any[])
	Wp = max(W - margins.l - margins.r, 1.0)
	Hp = max(H - margins.t - margins.b, 1.0)
	for key in area_order
		items = [item for item in bars_by_area[key] if item.slot !== nothing &&
			!(item.index in hugged) && _fin_bar_vertical(item.bar)]
		isempty(items) && continue
		region = regions[key]
		last_hug = get(hug_end, key, nothing)
		(length(items) + (last_hug === nothing ? 0 : 1) >= 2 || any(item -> item.inset, items)) || continue
		own_default = item -> _cbar_placement(:right, item.own.xdomain, item.own.ydomain, _CBAR_CELL_PAD)
		is_auto = item -> _fin_bar_unplaced(item.bar) || _fin_bar_owned(item.bar) ||
			_cbar_placement_matches(item.bar, own_default(item))
		hosts = [item for item in items if !item.inset]
		lead = nothing
		template = nothing
		if last_hug !== nothing
			cursor = last_hug[1] + (last_hug[2] + _FIN_CBAR_GAP) / Wp
			template = last_hug[3]
		elseif !isempty(hosts)
			lead = hosts[1]
			template = lead.bar
			cursor = _cbar_real(lead.bar, :x, 1.02) + (_fin_bar_width(layout, lead, Hp) + _FIN_CBAR_GAP) / Wp
		else
			cursor = region.xdomain[2] + _CBAR_CELL_PAD
		end
		for item in items
			item === lead && continue
			(is_auto(item) && _fin_item_writable(ctx, item)) || continue
			placement = Dict{Symbol, Any}(:x => cursor, :xanchor => "left", :xref => "paper", :lenmode => "fraction")
			if item.inset
				# Level with its inset.
				default = own_default(item)
				for k in (:y, :yanchor, :len, :ypad)
					placement[k] = default[k]
				end
			else
				for k in (:y, :yanchor, :len, :ypad)
					template !== nothing && haskey(template, k) && (placement[k] = template[k])
				end
				haskey(placement, :len) || (placement[:len] = 1.0)
			end
			wrote |= _fin_place_bar!(ctx, layout_updates, item, placement)
			push!(moved, (item, placement))
			cursor += (_fin_bar_width(layout, item, Hp) + _FIN_CBAR_GAP) / Wp
		end
	end
	# Math titles drawn as annotations follow their bars.
	annotations = _fin_title_annotations(p, moved)
	# A math title beside the bar (`title_side = :right`) is an annotation,
	# which plotly does not count in the margins: grow `margin.r` to fit it.
	needed = _fin_title_margin(layout, annotations === nothing ? get(layout.fields, :annotations, nothing) : annotations,
		W, margins)
	if needed !== nothing
		current = _cmn_mapping_get(get(layout.fields, :margin, nothing), :r)
		(_fin_isfinite_real(current) && current >= needed) || (layout_updates[:margin_r] = needed)
	end
	annotations === nothing || (layout_updates[:annotations] = annotations)
	wrote |= _fin_relayout!(ctx, layout_updates)
	return wrote
end

# The layout annotations with the math title of every moved bar redrawn for
# its new placement; `nothing` when no title annotation changes.
function _fin_title_annotations(p::Plot, moved)
	isempty(moved) && return nothing
	existing = get(p.layout.fields, :annotations, nothing)
	existing isa AbstractVector || return nothing
	result = collect(Any, existing)
	changed = false
	for (item, placement) in moved
		key = item.coloraxis !== nothing ? item.coloraxis : item.own.key
		found = _cbar_find_title_annotation(p, key)
		found === nothing && continue
		bar = merge(item.bar, placement)
		geometry = _cbar_geometry(p, bar, item.range)
		geometry === nothing && continue
		name = _cbar_title_owner(key) * ":" * String(found.side)
		fresh = _cbar_title_annotation(name, found.text, found.side, geometry)
		for (i, old) in enumerate(result)
			_cmn_item_name(old) == name || continue
			if !isequal(_symbol_dict(old), _symbol_dict(fresh))
				# Keep settings the user added to the annotation (font, ...).
				merged = _symbol_dict(old)
				merge!(merged, _symbol_dict(fresh))
				result[i] = _cbar_attr(merged)
				changed = true
			end
			break
		end
	end
	return changed ? result : nothing
end

# Right margin (px) that fits every right-side math colorbar title, or
# `nothing` when there is none. The title is a -90 deg annotation `xshift` px
# right of its paper `x`; its rendered width is taken as 1.6 font sizes.
function _fin_title_margin(layout::Layout, annotations, W::Float64, margins)
	(annotations isa AbstractVector && !isempty(annotations)) || return nothing
	font = _fin_font_size(layout)
	Wp = max(W - margins.l - margins.r, 1.0)
	needed = nothing
	for item in annotations
		name = _cmn_item_name(item)
		(name isa AbstractString && startswith(name, _CBAR_TITLE_ANNOTATION_PREFIX) &&
			endswith(name, ":right")) || continue
		x = _cmn_mapping_get(item, :x)
		shift = _cmn_mapping_get(item, :xshift, 0)
		(_fin_isfinite_real(x) && _fin_isfinite_real(shift)) || continue
		size = _fin_mapping_font_size(item, :font, font)
		edge = (Float64(x) - 1) * Wp + Float64(shift) + 1.6 * size + 4
		needed = max(something(needed, 0.0), ceil(edge))
	end
	(needed === nothing || needed <= 0) && return nothing
	return needed
end

"""
	_finalize_figure!(fig; live = nothing, size = nothing) -> Bool

Normalise the figure after a PlotlySupply constructor or mutator changed it
(decision D10); returns whether anything was written.

- M1: every root axis of a shared-axis (`matches`) group that has neither a
  range nor an `autorange` entry gets `autorange = true` (plotly.js otherwise
  collapses the group when another group has a fixed range).
- M2: axes that carry a field trace (`_fin_field_kind`) and autorange get the
  sticky clip (`_fin_sticky_clip`), or are pinned to it on an equal-aspect
  cell; see `_fin_sticky_updates!`.
- M3: equal-aspect cells are fitted into their grid cell (inset, or paper),
  their x axis shrinks toward its colorbar (`constraintoward = "right"`), and
  their colorbars are placed against the fitted plot area with the same
  height. A single figure without a width or height is sized to the field.
- M4: further colorbars on the same plot area are placed side by side.

Explicit user settings (ranges, `autorangeoptions`, domains outside the cell,
placed colorbars) are never changed. `live` holds the traces of the live
figure: those are not written (the append-only fast path shares them), and a
cell whose colorbar would need such a write is left as it is. `size` is the
export size (px) to fit for.
"""
function _finalize_figure!(fig; live = nothing, size = nothing)
	return _fin_run!(fig, live, size, false)
end

function _fin_run!(fig, live, size, clone_readonly::Bool)
	p = fig isa SubplotFigure ? _plot_obj(getfield(fig, :fig)) : _plot_obj(fig)
	target = fig isa SubplotFigure ? getfield(fig, :fig) : fig
	readonly = live === nothing ? nothing : Base.IdSet{Any}(live)
	checked_size = if size === nothing
		nothing
	else
		(length(size) == 2 && all(v -> _fin_isfinite_real(v) && v > 0, size)) || throw(ArgumentError(
			"_finalize_figure!: `size` must be (width, height) in px; got $(repr(size)).",
		))
		(Float64(size[1]), Float64(size[2]))
	end
	ctx = _FinContext(target, p, fig isa SubplotFigure ? fig : nothing, readonly, clone_readonly, checked_size)
	updates = _fin_match_group_updates(p.layout)
	_fin_sticky_updates!(updates, p)
	wrote = _fin_relayout!(ctx, updates)
	wrote |= _fin_fit!(ctx)
	return wrote
end

"""
	_finalize_export_copy(p::Plot, options) -> Plot

The figure `savefig` renders: `p` itself when `_finalize_figure!` has nothing
to change for the export size `options.width` x `options.height`, otherwise a
copy (private layout; traces shared except those it writes, which are cloned)
re-fitted for that size. `p` is never mutated.
"""
function _finalize_export_copy(p::Plot, options)
	copy_plot = Plot(copy(p.data), deepcopy(p.layout), p.frames; config = p.config)
	wrote = _fin_run!(copy_plot, p.data, (options.width, options.height), true)
	return wrote ? copy_plot : p
end

"""
	_fin_needs_full_staging(fig) -> Bool

Whether a mutation of `fig` may need `_finalize_figure!` to write traces that
already exist: the colorbars of an equal-aspect cell move whenever its fit
changes, which the append-only fast path cannot stage (it then leaves the
cell as it was until the next fully staged mutation or export). Figures with
an equal-aspect cell should take the full staging path.
"""
function _fin_needs_full_staging(fig)
	p = fig isa SubplotFigure ? _plot_obj(getfield(fig, :fig)) : _plot_obj(fig)
	return !isempty(_fin_aspect_cells(p.layout, _fin_collect_axes(p)))
end
