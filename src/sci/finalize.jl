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
# plotly.js 2.35.2 also never resets its "explicit range seen" flag between
# groups (cartesian layout defaults: `"autorange"===p&&null===d&&T&&(d=!1)`),
# so a later group root without `autorange` is taken as fixed once an earlier
# axis had a range (Y37). Every group root therefore states `autorange`.
#
# Returns the `relayout!` updates that state `autorange` on every group root
# that has no `autorange` entry of its own: `false` for a root with a fixed
# two-element range, `true` otherwise. A root that neither the layout nor a
# trace of `data` has does not exist for plotly.js (it ignores the `matches`
# reference) and is not created.
function _fin_match_group_updates(layout::Layout, data = ())
	updates = Dict{Symbol, Any}()
	fields = layout.fields
	referenced = Set{Symbol}()
	for trace in data
		trace isa GenericTrace || continue
		for key in (:xaxis, :yaxis)
			axis = _fin_axis_key(_fin_string(get(trace.fields, key, nothing)))
			axis === nothing || push!(referenced, axis)
		end
	end
	for root in _fin_match_roots(layout)
		(haskey(fields, root) || root in referenced) || continue
		axis = get(fields, root, nothing)
		_fin_field(axis, :autorange) === nothing || continue
		updates[Symbol(root, :_autorange)] = !_fin_has_range(axis)
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

# Whether every entry of a coordinate vector is a finite number (positive on
# a log axis). A function barrier that copies nothing: `values` comes out of a
# trace's `Dict{Symbol, Any}`, and collecting it there boxed every element (a
# million-point heatmap axis allocated about 30 MB per scan, K8).
function _fin_all_lvalues(values, islog::Bool)
	for value in values
		_fin_isfinite_real(value) || return false
		islog && !(value > 0) && return false
	end
	return true
end

# l-value (log10 on a log axis) of the `k`-th (1-based) entry of a coordinate
# vector that `_fin_all_lvalues` accepted.
function _fin_lvalue_at(values::AbstractVector, k::Int, islog::Bool)
	x = Float64(values[firstindex(values) + k - 1])
	return islog ? log10(x) : x
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
		_fin_all_lvalues(coords, islog) || return :unsupported
		m = length(coords)
		c(k) = _fin_lvalue_at(coords, k, islog)
		if !bricks
			first_l, last_l = c(1), c(min(m, n))
		elseif m >= n + 1
			first_l, last_l = c(1), c(n + 1)
		else
			first_l = 1.5 * c(1) - 0.5 * c(2)
			last_l = 1.5 * c(m) - 0.5 * c(m - 1)
			if m < n
				step = last_l - 0.5 * (c(m - 1) + c(m))
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
# a 5 x 3 image spans x = [-0.5, 4.5], y = [2.5, -0.5]). The pixel counts come
# from `z` (a C x W x H array as `plot_image` stores it, nested rows of
# pixels) or from the header of a PNG `source` (Z40).
function _fin_image_extent(fields, letter::Char, islog::Bool)
	islog && return :unsupported
	pixels = _field2d_image_size(fields)
	n = pixels === nothing ? _cmn_grid_count(get(fields, :z, nothing), letter, false) :
		(letter == 'x' ? pixels[1] : pixels[2])
	n === nothing && return :unsupported
	n >= 1 || return nothing
	start = get(fields, Symbol(letter, "0"), 0)
	step = get(fields, Symbol("d", letter), 1)
	(_fin_isfinite_real(start) && _fin_isfinite_real(step)) || return :unsupported
	v0 = Float64(start)
	dv = Float64(step)
	return minmax(v0 - 0.5 * dv, v0 + dv * (n - 0.5))
end

# (lo, hi) of the finite values (positive ones when `islog`), `nothing` when
# there is none, `:unsupported` for a value that is not a real number. A
# function barrier: `values` comes out of a trace's `Dict{Symbol, Any}`, and
# iterating it there would box every element (a million-point range then
# allocates hundreds of MB).
_fin_values_extent(values, islog::Bool) = _fin_values_extent_loop(values, islog)

function _fin_values_extent_loop(values, islog::Bool)
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
	return lo <= hi ? (lo, hi) : nothing
end

# Floating-point coordinates on a linear axis: the vectorized scan the
# colour ranges use (same result: finite values only, `nothing` without any).
_fin_values_extent(values::AbstractArray{<:Base.IEEEFloat}, islog::Bool) =
	islog ? _fin_values_extent_loop(values, true) : _cbar_real_extrema(values)

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
	extent = _fin_values_extent(values, islog)
	extent isa Tuple || return extent
	lo, hi = extent
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

# What the traces put on one Cartesian axis. The flags and `image_x` are
# collected for every axis; the extents only when first asked for
# (`get(::_FinAxes, key, default)`, Z81).
mutable struct _FinAxisAcc
	tight::Bool
	loose::Bool
	unsupported::Bool
	image_x::Union{Nothing, Symbol}   # on a y axis: the x axis of an image trace
	# Drawn extent of everything on the axis (data units): what plotly
	# autoranges to.
	lo::Float64
	hi::Float64
	# Extent of the field traces alone (data units); the rest is overlays.
	flo::Float64
	fhi::Float64
	# The extent a sticky field range covers (D16): the fields, the anchor
	# points of overlays that carry them (`_fin_anchor_extent`) and the drawn
	# extent of every other overlay.
	alo::Float64
	ahi::Float64
	scanned::Bool
	# (index in `p.data`, field kind) of the visible traces on the axis.
	traces::Vector{Tuple{Int, Union{Nothing, Symbol}}}
end
_FinAxisAcc() = _FinAxisAcc(false, false, false, nothing, Inf, -Inf, Inf, -Inf, Inf, -Inf, true,
	Tuple{Int, Union{Nothing, Symbol}}[])

# `extent` is the drawn extent, `anchor` the extent of the anchor points.
function _fin_acc_extend!(acc::_FinAxisAcc, extent, field::Bool = false, anchor = extent)
	if extent isa Tuple
		acc.lo = min(acc.lo, extent[1])
		acc.hi = max(acc.hi, extent[2])
		if field
			acc.flo = min(acc.flo, extent[1])
			acc.fhi = max(acc.fhi, extent[2])
		end
	end
	if anchor === :unsupported
		acc.unsupported = true
	elseif anchor isa Tuple
		acc.alo = min(acc.alo, anchor[1])
		acc.ahi = max(acc.ahi, anchor[2])
	end
	return acc
end

# The extents of the Cartesian axes of a plot: the flags of every axis,
# extents computed per axis on first use and kept for the plot as it is.
# Valid while the traces, the axis types and the data-referenced shapes and
# annotations stay as they are: `_fin_run!` keeps one for the whole run, whose
# writes (ranges, autorange options, domains, colorbar placements, margins,
# the size, paper-referenced annotations) change none of them.
struct _FinAxes
	p::Plot
	accs::Dict{Symbol, _FinAxisAcc}
end

Base.keys(axes::_FinAxes) = keys(axes.accs)
Base.haskey(axes::_FinAxes, key) = haskey(axes.accs, key)

function Base.get(axes::_FinAxes, key, default)
	acc = get(axes.accs, key, nothing)
	acc === nothing && return default
	acc.scanned || _fin_scan_axis!(axes.p, key, acc)
	return acc
end

# The flag records of every axis (extents not computed).
_fin_axis_records(axes::_FinAxes) = axes.accs
_fin_axis_records(accs::AbstractDict) = accs

# Overlays (lines, markers, arrows, shapes) that reach past the field get this
# share of the view's span as padding on that side only, so arrowheads, line
# caps and markers at the frame are not cut off (D10 review, hm_06); the field
# side stays exactly at the field edge. 2.5 % is ~9 px on a 350 px axis, the
# size of a default quiver arrowhead and of a 10 px marker's radius.
const _FIN_OVERLAY_PAD = 0.025

_fin_axis_type(layout::Layout, key::Symbol) =
	something(_fin_string(_cmn_mapping_get(get(layout.fields, key, nothing), :type)), "-")

# D16: the extent of an overlay's anchor points along `letter` (quiver
# positions, streamline seed grid), from `trace.meta` key
# `plotlysupply_anchor_extent` = (xmin, xmax, ymin, ymax) in data units;
# `nothing` when the trace carries none or it is not four finite numbers in
# order (positive on a log axis), so the drawn extent is used.
const _FIN_ANCHOR_META_KEY = "plotlysupply_anchor_extent"

function _fin_anchor_extent(trace::GenericTrace, letter::Char, islog::Bool)
	meta = get(trace.fields, :meta, nothing)
	meta isa PlotlyBase.PlotlyAttribute && (meta = meta.fields)
	meta isa AbstractDict || return nothing
	value = get(meta, _FIN_ANCHOR_META_KEY, nothing)
	value === nothing && (value = get(meta, Symbol(_FIN_ANCHOR_META_KEY), nothing))
	(value isa AbstractVector || value isa Tuple) && length(value) == 4 || return nothing
	all(_fin_isfinite_real, value) || return nothing
	lo, hi = letter == 'x' ? (value[1], value[2]) : (value[3], value[4])
	lo <= hi || return nothing
	islog && lo <= 0 && return nothing
	return (Float64(lo), Float64(hi))
end

function _fin_collect_axes(p::Plot)
	layout = p.layout
	accs = Dict{Symbol, _FinAxisAcc}()
	cache = Dict{Any, Union{Nothing, String}}()
	for (index, trace) in enumerate(p.data)
		trace isa GenericTrace || continue
		_cmn_trace_kind(trace, cache) == "xy" || continue
		_fin_visible(trace) || continue
		kind = _fin_field_kind(trace)
		is_image = _fin_trace_type(trace) == "image"
		xkey = _fin_axis_key(get(trace.fields, :xaxis, "x"))
		ykey = _fin_axis_key(get(trace.fields, :yaxis, "y"))
		for (letter, key) in (('x', xkey), ('y', ykey))
			key === nothing && continue
			acc = get!(accs, key) do
				_FinAxisAcc(false, false, false, nothing, Inf, -Inf, Inf, -Inf, Inf, -Inf, false,
					Tuple{Int, Union{Nothing, Symbol}}[])
			end
			kind === :tight && (acc.tight = true)
			kind === :loose && (acc.loose = true)
			letter == 'y' && is_image && xkey !== nothing && (acc.image_x = xkey)
			acc.unsupported && continue
			if !(_fin_axis_type(layout, key) in ("-", "linear", "log"))
				acc.unsupported = true
				continue
			end
			push!(acc.traces, (index, kind))
		end
	end
	return _FinAxes(p, accs)
end

# The extents of axis `key` (a data scan of the traces on it).
function _fin_scan_axis!(p::Plot, key::Symbol, acc::_FinAxisAcc)
	acc.scanned = true
	acc.unsupported && return acc
	layout = p.layout
	letter = String(key)[1]
	islog = _fin_axis_type(layout, key) == "log"
	for (index, kind) in acc.traces
		trace = p.data[index]
		extent = _fin_trace_extent(trace, letter, islog)
		anchor = kind === nothing ? _fin_anchor_extent(trace, letter, islog) : nothing
		_fin_acc_extend!(acc, extent, kind !== nothing, anchor === nothing ? extent : anchor)
		acc.unsupported && return acc
	end
	_fin_acc_extend!(acc, _fin_layout_item_extent(layout, _fin_axis_ref(key), letter, islog))
	return acc
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
	for (key, acc) in _fin_axis_records(accs)
		acc.image_x === nothing && continue
		_fin_field(get(layout.fields, key, nothing), :scaleanchor) === nothing || continue
		push!(linked, key)
		push!(linked, acc.image_x)
	end
	return linked
end

# The sticky view of an axis group: the union of the field extents and the
# overlays' anchor extents (D16: an overlay with anchor points counts them,
# not its glyphs; any other overlay its drawn extent), padded by
# `_FIN_OVERLAY_PAD` of the span on each side where an overlay reaches past
# the fields (in log10 units on a log axis). Data units.
function _fin_padded_extent(acc::_FinAxisAcc, islog::Bool)
	lo, hi = acc.alo, acc.ahi
	(isfinite(acc.flo) && isfinite(acc.fhi)) || return (lo, hi)
	tol(v) = 1e-12 * max(abs(v), 1.0)
	l(v) = islog ? log10(v) : v
	span = l(hi) - l(lo)
	span > 0 || return (lo, hi)
	pad = _FIN_OVERLAY_PAD * span
	lo_out = lo < acc.flo - tol(acc.flo)
	hi_out = hi > acc.fhi + tol(acc.fhi)
	new_lo = lo_out ? (islog ? exp10(log10(lo) - pad) : lo - pad) : lo
	new_hi = hi_out ? (islog ? exp10(log10(hi) + pad) : hi + pad) : hi
	return (new_lo, new_hi)
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
function _fin_sticky_updates!(updates::Dict{Symbol, Any}, p::Plot, accs = _fin_collect_axes(p))
	layout = p.layout
	fields = layout.fields
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
		records = _fin_axis_records(accs)
		acc = _FinAxisAcc()
		for member in members
			macc = get(records, member, nothing)
			macc === nothing && continue
			acc.tight |= macc.tight
			acc.loose |= macc.loose
			acc.unsupported |= macc.unsupported
			macc.image_x === nothing || (acc.image_x = macc.image_x)
		end
		clip = _fin_sticky_clip(root_axis)
		implicit_reversed = String(root)[1] == 'y' && acc.image_x !== nothing
		mode, reversed = _fin_axis_mode(root_axis, clip, islog, implicit_reversed)
		mode === :explicit && continue
		# Extents are scanned only for the groups that can be sticky (Z81).
		if acc.tight && !acc.loose && !acc.unsupported
			for member in members
				macc = get(accs, member, nothing)
				macc === nothing && continue
				acc.unsupported |= macc.unsupported
				acc.alo = min(acc.alo, macc.alo)
				acc.ahi = max(acc.ahi, macc.ahi)
				acc.flo = min(acc.flo, macc.flo)
				acc.fhi = max(acc.fhi, macc.fhi)
			end
		end
		sticky = acc.tight && !acc.loose && !acc.unsupported &&
			isfinite(acc.alo) && isfinite(acc.ahi) && acc.alo < acc.ahi &&
			(!islog || acc.alo > 0)
		if sticky
			lo, hi = _fin_padded_extent(acc, islog)
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
	# The traces of the figure before the mutation, in order (`live`).
	before::Union{Nothing, Vector{Any}}
	insets::Vector{Any}                 # `_fin_insets`
	inset_hosts::Set{Symbol}            # x axes of the cells hosting an inset
	grid::Base.RefValue{Any}            # `_fin_grid_layout` cache
	# Trace bars this run placed without our mark (`release`): their mark
	# was dropped here, not by the mutation (`_room_vacated!`).
	released::Set{Int}
end

# The layout of the bare subplot grid (`_plotlysupply_subplot_layout`): the
# grid rectangle of every cell. Computed once per finalize.
function _fin_grid_layout(ctx::_FinContext)
	ctx.grid[] === nothing && (ctx.grid[] = _plotlysupply_subplot_layout(ctx.p.layout.subplots))
	return ctx.grid[]
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

# Characters (at the tick font size) of plotly's label of the decade 10^p on
# a log axis (plotly.js 2.35.2 axes.js formatLog with whole-decade ticks):
# "10<sup>−p</sup>" drawn at 1.25 font sizes, the exponent at 70 %, for
# exponentformat "power" (and "SI"/"B" past 10^14 / 10^-15); "1e−p" for
# "e"/"E" past 10^±2; a number of at most three digits with an SI suffix
# ("100µ", "10k") for "SI"/"B" past 10^±minexponent; else the plain number
# ("none": 10^-15 is "0.000000000000001").
function _fin_log_label_chars(p::Int, format::AbstractString, minexponent::Float64)
	si = format == "SI" || format == "B"
	if format == "power" || (si && (p > 14 || p < -15))
		p == 0 && return 2
		p == 1 && return 3
		return ceil(Int, 1.25 * (2 + 0.7 * (ndigits(abs(p)) + (p < 0 ? 1 : 0))))
	elseif (format == "e" || format == "E") && abs(p) > 2
		return 3 + ndigits(abs(p))
	elseif si && abs(p) > minexponent
		return 4
	end
	return _fin_number_chars(exp10(p), max(0, -p))
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
		tickformat = _cmn_mapping_get(mapping, :tickformat)
		decades = floor(Int, lo):ceil(Int, hi)
		# A d3 `tickformat` writes the plain numbers.
		(tickformat isa AbstractString && !isempty(tickformat)) &&
			return maximum(e -> _fin_number_chars(exp10(e), max(0, -e)), decades) + extra
		format = something(_fin_string(_cmn_mapping_get(mapping, :exponentformat)), "B")
		minexponent = _cmn_mapping_get(mapping, :minexponent)
		minexponent = _fin_isfinite_real(minexponent) ? Float64(minexponent) : 3.0
		return maximum(e -> _fin_log_label_chars(e, format, minexponent), decades) + extra
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
	text = _fin_title_text(mapping)
	isempty(text) && return 0.0
	size = _fin_mapping_font_size(_cmn_mapping_get(mapping, :title), :font, round(1.2 * font))
	# Every further line of a multi-line title adds one line height.
	lines = 1 + count(_FIN_LINE_BREAK, text)
	return _FIN_TITLE_BASE + _FIN_TITLE_PER_PX * size + (lines - 1) * _FIN_LINE_EM * size
end

# Line breaks plotly.js draws (svg_text_utils: `<br>`, `<br/>`, `<br />`) and
# the distance of the lines, in font sizes (svg_text_utils LINE_SPACING).
const _FIN_LINE_BREAK = r"<br\s*/?>"i
const _FIN_LINE_EM = 1.3

function _fin_tick_len(mapping)
	_fin_string(_cmn_mapping_get(mapping, :ticks)) == "outside" || return 0.0
	len = _cmn_mapping_get(mapping, :ticklen)
	return _fin_isfinite_real(len) && len >= 0 ? Float64(len) : 5.0
end

_fin_automargin(axis) = (v = _cmn_mapping_get(axis, :automargin);
	v === true || (v isa AbstractString && !isempty(v) && v != "false"))

# [lo, hi] in l-units shown by an axis: its fixed range, the sticky clip, or
# the data extent collected for it with plotly's autorange padding; `nothing`
# when unknown.
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
	islog && acc.lo <= 0 && return nothing
	lo, hi = islog ? (log10(acc.lo), log10(acc.hi)) : (acc.lo, acc.hi)
	# plotly.js pads the autorange of padded traces (scatter, bars) by 5 % of
	# the axis length on each side, which can add a longer tick label (data
	# up to 975 shows a "1000" tick).
	pad = _FIN_AUTORANGE_PAD * (hi - lo)
	return (lo - pad, hi + pad)
end

const _FIN_AUTORANGE_PAD = 0.05

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
# writes `xref = "paper"` explicitly next to a left-anchored fractional
# vertical bar, and `yref = "paper"` next to a top-anchored fractional
# horizontal one (plotly's default refs, so the mark changes nothing drawn).
function _fin_bar_owned(bar::Dict{Symbol, Any})
	_cbar_string(bar, :lenmode, "") == "fraction" || return false
	_fin_bar_vertical(bar) && return _cbar_string(bar, :xref, "") == "paper" &&
		_cbar_string(bar, :xanchor, "") == "left" && _cbar_real(bar, :x, nothing) !== nothing
	return _cbar_string(bar, :yref, "") == "paper" && _cbar_string(bar, :yanchor, "") == "top" &&
		_cbar_real(bar, :y, nothing) !== nothing
end

_fin_bar_unplaced(bar::Dict{Symbol, Any}) =
	!haskey(bar, :x) && !haskey(bar, :y) && !haskey(bar, :len)

# Pixel width of a vertical colorbar box from its anchor: x padding, bar,
# ticks, tick labels and a title on its right side. `len_px` overrides the
# bar length the tick labels are estimated for.
function _fin_bar_width(layout::Layout, item::_FinBar, Hp::Float64; len_px = nothing)
	bar = item.bar
	font = _fin_font_size(layout)
	thickness = _cbar_string(bar, :thicknessmode, "pixels") == "pixels" ?
		_cbar_real(bar, :thickness, _CBAR_DEFAULT_THICKNESS) : _CBAR_DEFAULT_THICKNESS
	xpad = _cbar_real(bar, :xpad, _CBAR_DEFAULT_XPAD)
	len = len_px !== nothing ? Float64(len_px) :
		_cbar_string(bar, :lenmode, "fraction") == "fraction" ?
		_cbar_real(bar, :len, 1.0) * Hp : _cbar_real(bar, :len, Hp)
	ypad = _cbar_real(bar, :ypad, 10.0)
	lo, hi = item.range === nothing ? (NaN, NaN) : item.range
	chars = _fin_tick_chars(bar, lo, hi, max(len - 2ypad, 1.0), false, true)
	# An offset (`colorbar!(...; offset)`): the last label carries "×10^k".
	chars > 0 && _cbar_string(bar, :showexponent, "") == "last" &&
		_cbar_string(bar, :exponentformat, "") == "power" && (chars += _FIN_BAR_OFFSET_CHARS)
	tickfont = _fin_mapping_font_size(bar, :tickfont, font)
	labels = chars == 0 ? 0.0 : chars * 0.6 * tickfont + 5.5
	width = xpad + thickness + _fin_tick_len(bar) + labels
	title = _cmn_mapping_get(bar, :title)
	side = _fin_string(_cmn_mapping_get(title, :side))
	text = title isa AbstractString ? title : _cmn_mapping_get(title, :text)
	if side == "right" && text isa AbstractString && !isempty(text)
		width += 1.4 * _fin_mapping_font_size(title, :font, font) + 4
	else
		# A math title drawn beside the bar as an annotation.
		key = item.coloraxis !== nothing ? item.coloraxis : item.own === nothing ? nothing : item.own.key
		annotation = key === nothing ? nothing : _fin_right_title_annotation(layout, key)
		annotation === nothing ||
			(width += _FIN_MATH_TITLE_EM * _fin_mapping_font_size(annotation, :font, font) + 4)
	end
	return width
end

# Characters "×10^k" adds to a tick label: "×10" and a superscript exponent
# of up to two characters at about half width.
const _FIN_BAR_OFFSET_CHARS = 4

# Width of a -90 deg MathJax colorbar title, in font sizes: rendered at the
# default 12 px, `$E_z$`, `$|J_s|$`, `$|E|^2$` and `$\frac{a}{b}$` measured
# 13.5, 16, 18 and 19 px wide.
const _FIN_MATH_TITLE_EM = 1.6

# The right-side math title annotation of the bar keyed `key` (coloraxis id
# or plot-area key, see `_cbar_title_owner`), or `nothing`.
function _fin_right_title_annotation(layout::Layout, key::AbstractString)
	annotations = get(layout.fields, :annotations, nothing)
	annotations isa AbstractVector || return nothing
	name = _cbar_title_owner(key) * ":right"
	for item in annotations
		_cmn_item_name(item) == name && return item
	end
	return nothing
end

# The insets of a figure as `(row, col, xkey, ykey, xref, yref, xdomain,
# ydomain)`: the SubplotFigure's records, or, for its plot alone (an export
# copy), every Cartesian axis pair no subplot grid cell uses whose domains lie
# inside a grid cell's (that cell is its host).
function _fin_insets(p::Plot, sf)
	if sf !== nothing
		return Any[(row = i.row, col = i.col, xkey = i.xkey, ykey = i.ykey, xref = i.xref, yref = i.yref,
			xdomain = i.xdomain, ydomain = i.ydomain) for i in getfield(sf, :insets)]
	end
	layout = p.layout
	grid_ref = layout.subplots.grid_ref
	used = Set{Symbol}()
	cells = Tuple{Int, Int, Symbol, Symbol}[]
	for r in axes(grid_ref, 1), c in axes(grid_ref, 2)
		(isassigned(grid_ref, r, c) && !isempty(grid_ref[r, c])) || continue
		for (i, entry) in enumerate(grid_ref[r, c])
			fields = entry.trace_kwargs.fields
			xkey = _fin_axis_key(_fin_string(get(fields, :xaxis, nothing)))
			ykey = _fin_axis_key(_fin_string(get(fields, :yaxis, nothing)))
			xkey === nothing || push!(used, xkey)
			ykey === nothing || push!(used, ykey)
			i == 1 && xkey !== nothing && ykey !== nothing && push!(cells, (r, c, xkey, ykey))
		end
	end
	found = Any[]
	isempty(cells) && return found
	for (key, axis) in layout.fields
		(_fin_is_axis_key(key) && String(key)[1] == 'x' && !(key in used) && _fin_is_base_axis(layout, key)) ||
			continue
		ykey = _fin_axis_key(_cmn_mapping_get(axis, :anchor))
		(ykey === nothing || ykey in used) && continue
		xd = _layout_axis_domain(layout, key)
		yd = _layout_axis_domain(layout, ykey)
		(xd === nothing || yd === nothing) && continue
		for (r, c, hx, hy) in cells
			hxd = _layout_axis_domain(layout, hx)
			hyd = _layout_axis_domain(layout, hy)
			(hxd === nothing || hyd === nothing) && continue
			(xd[1] >= hxd[1] - 1e-9 && xd[2] <= hxd[2] + 1e-9 && yd[1] >= hyd[1] - 1e-9 && yd[2] <= hyd[2] + 1e-9) ||
				continue
			push!(found, (row = r, col = c, xkey = key, ykey = ykey, xref = _fin_axis_ref(key),
				yref = _fin_axis_ref(ykey), xdomain = xd, ydomain = yd))
			break
		end
	end
	return found
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
# trace order, with the area order and the area regions. Coloraxis bars are
# listed under the area of their first trace.
function _fin_collect_bars(p::Plot, insets)
	by_area = Dict{String, Vector{_FinBar}}()
	order = String[]
	regions = Dict{String, Any}()
	coloraxis_areas = Dict{String, Vector{String}}()
	coloraxis_ranges = Dict{String, Tuple{Float64, Float64}}()
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
		# A trace without a bar of its own needs no colour range.
		range = (slot.coloraxis !== nothing || slot.shows) ? _cbar_slot_range(trace, slot) : nothing
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
	return by_area, order, regions
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
		# restyle! stores `nothing` for a cleared key (the display resets it);
		# drop it from the trace.
		cleared = [key for (key, value) in changes if value === nothing]
		if !isempty(cleared)
			fields = ctx.p.data[item.index].fields
			holder = item.slot.container === :root ? fields : get(fields, item.slot.container, nothing)
			bar = holder isa AbstractDict ? get(holder, :colorbar, nothing) : nothing
			if bar isa AbstractDict
				for key in cleared
					haskey(bar, key) && bar[key] === nothing && delete!(bar, key)
				end
			end
		end
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
	for (key, acc) in _fin_axis_records(accs)
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
	for inset in ctx.insets
		inset.xkey === xkey && inset.ykey === ykey && return (inset.xdomain, inset.ydomain)
	end
	sub.rows * sub.cols > 1 && return nothing
	(xkey === :xaxis && ykey === :yaxis) || return nothing
	inset_keys = Set{Symbol}()
	for inset in ctx.insets
		push!(inset_keys, inset.xkey, inset.ykey)
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
# reference area: part of the right margin at the paper edge, else up to the
# tick labels of the plot area to its right (`_fin_right_neighbour`, at the
# grid positions), or to the paper edge when there is none.
# `area_cache` keeps the plot areas per positions layout for one fit (Z82).
function _fin_right_allowance(layout::Layout, accs, ref, grid_layout, Wp::Float64, Hp::Float64;
		area_cache::IdDict{Any, Any} = IdDict{Any, Any}())
	if ref[1][2] >= 1 - 1e-6
		return max(0.0, _fin_margins_base(layout).r - _FIN_AUTOMARGIN_EXTRA - 4)
	end
	positions = something(grid_layout[], layout)
	areas = get!(() -> _fin_plot_area_boxes(positions), area_cache, positions)
	neighbour = _fin_right_neighbour(layout, accs, ref[1], ref[2], Hp; positions = positions, areas = areas)
	neighbour === nothing && return (1.0 - ref[1][2]) * Wp
	return max(0.0, (neighbour.x - ref[1][2]) * Wp - neighbour.push - 4)
end

# Figure px size used for the fit: the export size, the layout size, or the
# size an export without one gets (the active style's figure size, else the
# package default 700 x 500) for a side the layout leaves open.
function _fin_figure_size(ctx::_FinContext, layout::Layout)
	ctx.size === nothing || return ctx.size
	return _fin_layout_size(layout)
end

function _fin_layout_size(layout::Layout)
	w = get(layout.fields, :width, nothing)
	h = get(layout.fields, :height, nothing)
	W0, H0 = _style_default_figure_size()
	return (
		_fin_isfinite_real(w) && w > 0 ? Float64(w) : Float64(W0),
		_fin_isfinite_real(h) && h > 0 ? Float64(h) : Float64(H0),
	)
end

# Whether M3a may size the figure (Z67): it has no size, or exactly the size
# a sized (journal) style writes into every new figure (`_apply_style_layout!`,
# within half a px); that size is the style's default, not a choice for this
# figure, and M3a only removes the blank rows (or columns) around the fitted
# cell, so the column width a journal style sets is kept for a wide field.
function _fin_size_is_free(layout::Layout)
	w = get(layout.fields, :width, nothing)
	h = get(layout.fields, :height, nothing)
	w === nothing && h === nothing && return true
	(_fin_isfinite_real(w) && _fin_isfinite_real(h)) || return false
	_active_style().width > 0 || return false
	W0, H0 = _style_default_figure_size()
	return abs(w - W0) <= 0.5 && abs(h - H0) <= 0.5
end

# Single figures without a size (decision D10 M3a): the default width, the
# height derived from the field aspect; a tall field keeps the default height
# and derives the width. Bounds: height 200..default, width 300..default (px)
# at the 700 x 500 default, scaled down with a smaller default; whatever the
# bounds cut off is absorbed by the domain fit.
const _FIN_MIN_FIGURE_HEIGHT = 200.0
const _FIN_MIN_FIGURE_WIDTH = 300.0

# Bias (px) by which a fitted x domain exceeds the plot width it needs, so that
# plotly's exactness guard (`constrain = "domain"`) always shrinks x, toward
# its colorbar (`constraintoward = "right"`), and never y: the bar length then
# equals the plot height exactly even when the margin estimate is a few px off.
_fin_bias(w::Float64) = 0.025 * w + 4.0

# The fitted domains and bar placements of every equal-aspect cell. A cell
# is fitted inside its reference area less the room (px per side, `reduce`)
# its other decorations take there (`_room_fit_reduction`); `push` (px per
# paper edge) grows the margin estimates for the decorations beyond the
# paper (`_room_edge_needs`). The plot box and its colorbars of a single
# figure are centred in the figure, its y tick labels included.
function _fin_fit_cells(ctx::_FinContext, layout::Layout, accs, bars_by_area, W::Float64, H::Float64;
		reduce = Dict{Symbol, Dict{Symbol, Float64}}(), push = nothing)
	results = Dict{Tuple{Symbol, Symbol}, Any}()
	grid_layout = ctx.grid
	cells = _fin_aspect_cells(layout, accs)
	isempty(cells) && return results
	domains = Dict{Symbol, NTuple{2, Float64}}()
	placed = Dict{Tuple{Symbol, Symbol}, Any}()
	# Nothing is written during the fit, so the plot areas of a positions
	# layout hold for all cells and both passes.
	area_cache = IdDict{Any, Any}()
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
		push === nothing || (margins = _room_grow_margins(margins, push))
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
			# The trace bars of this cell (by area key = x ref) that are ours to move.
			hug = _fin_hug_items(ctx, layout, bars_by_area, xkey, ykey)
			pad_px = _FIN_CBAR_PAD * Wp
			widths = [_fin_bar_width(layout, item, Hp) for item in hug]
			bars_px = isempty(hug) ? 0.0 : pad_px + sum(widths) + _FIN_CBAR_GAP * (length(hug) - 1)
			allow = _fin_right_allowance(layout, accs, ref, grid_layout, Wp, Hp; area_cache = area_cache)
			room = max(0.0, bars_px - allow)
			red = get(reduce, xkey, nothing)
			fref = red === nothing ? ref : ((ref[1][1] + red[:left] / Wp, ref[1][2]),
				(ref[2][1] + red[:bottom] / Hp, ref[2][2] - red[:top] / Hp))
			rw = (fref[1][2] - fref[1][1]) * Wp
			rh = (fref[2][2] - fref[2][1]) * Hp
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
			x0 = fref[1][1] * Wp + free / 2
			if layout.subplots.rows * layout.subplots.cols == 1 && ref == ((0.0, 1.0), (0.0, 1.0))
				# Single figure: centre the visible group (y tick labels and
				# title, plot box, colorbars) in the figure [-l, Wp + r].
				labels = _fin_left_decoration(layout, accs, ykey, ((rh - h) / 2 / Hp, (rh + h) / 2 / Hp), Hp)
				group = labels + w + bars_px
				x0 = clamp((Wp + margins.r - margins.l) / 2 - group / 2 + labels - bias, 0.0, free)
			end
			y0 = fref[2][1] * Hp + (rh - h) / 2
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
					:len => _room_bar_len(item.bar, _room_span(_fin_domain(layout, ykey)), yd[2] - yd[1];
						floor = _room_min_bar_len(_fin_font_size(layout), item.bar, Hp)),
					:lenmode => "fraction", :ypad => 0,
				))
				push!(boxes, (x, width))
				x += (width + _FIN_CBAR_GAP) / Wp
			end
			placed[(xkey, ykey)] = (xdomain = xd, ydomain = yd, box = ((x0 + bias) / Wp, xd[2]), hug = hug,
				placements = placements, bar_boxes = boxes, free_px = free, slack_px = rh - h)
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

# M3, M4 and D12 updates: the room the decorations of every plot area need
# (`_room_build`), the equal-aspect cells fitted inside it, the size of a
# single equal-aspect figure, and the decorations placed in their room.
# Returns whether anything was written.
function _fin_fit!(ctx::_FinContext, accs = _fin_collect_axes(ctx.p))
	p = ctx.p
	layout = p.layout
	bars = _fin_collect_bars(p, ctx.insets)
	wrote = false
	W, H = _fin_figure_size(ctx, layout)
	wrote |= _fin_wrap_axis_titles!(ctx, accs, W, H)
	plan, fits = _fin_plan_and_fit(ctx, accs, bars, W, H)
	# M3a: a single figure without a size is sized to its equal-aspect cell.
	if ctx.size === nothing && ctx.sf === nothing && layout.subplots.rows * layout.subplots.cols == 1 &&
			_fin_size_is_free(layout) && haskey(fits, (:xaxis, :yaxis)) && length(fits) == 1
		fit = fits[(:xaxis, :yaxis)]
		# Wide field: keep the width and drop the blank rows above and below
		# the plot box; tall field: keep the height and drop the blank columns.
		# The bounds are for the 700 x 500 default; a smaller (journal) size
		# scales them.
		newW, newH = W, H
		if fit.slack_px > 1
			low = min(H, _FIN_MIN_FIGURE_HEIGHT * min(1.0, H / _DEFAULT_EXPORT_HEIGHT_PX))
			newH = clamp(round(H - fit.slack_px), low, H)
		elseif fit.free_px > 1
			low = min(W, _FIN_MIN_FIGURE_WIDTH * min(1.0, W / _DEFAULT_EXPORT_WIDTH_PX))
			newW = clamp(round(W - fit.free_px), low, W)
		end
		size_updates = Dict{Symbol, Any}(:width => round(Int, newW), :height => round(Int, newH))
		wrote |= _fin_relayout!(ctx, size_updates)
		W, H = Float64(round(Int, newW)), Float64(round(Int, newH))
		wrote |= _fin_wrap_axis_titles!(ctx, accs, W, H)
		plan, fits = _fin_plan_and_fit(ctx, accs, bars, W, H)
	end
	layout_updates = plan.updates
	# M3b: fitted domains and hugging bars.
	for ((xkey, ykey), fit) in fits
		all(item -> _fin_item_writable(ctx, item), fit.hug) || continue
		for (key, dom) in ((xkey, fit.xdomain), (ykey, fit.ydomain))
			current = _layout_axis_domain(layout, key)
			_fin_layout_value_changed(current, dom) && (layout_updates[Symbol(key, :_domain)] = [dom[1], dom[2]])
		end
		_fin_layout_value_changed(_cmn_mapping_get(get(layout.fields, xkey, nothing), :constraintoward), "right") &&
			(layout_updates[Symbol(xkey, :_constraintoward)] = "right")
		for (item, placement) in zip(fit.hug, fit.placements)
			plan.wrote |= _fin_place_bar!(ctx, layout_updates, item, placement)
			push!(plan.moved, (item, placement))
		end
		area = get(plan.areas, xkey, nothing)
		area === nothing || (area.final = (fit.box, fit.ydomain))
	end
	# D12: plot areas give up the room their decorations need; every owner
	# places its decorations in it.
	isempty(fits) || _room_assign_slots!(plan)
	_room_write_domains!(plan)
	for owner in _ROOM_OWNERS
		_room_place!(plan, Val(owner))
	end
	# A mutation that bound traces which existed before it to a coloraxis
	# after the coloraxis bar was placed for its other traces (a 3-D
	# `shared_coloraxis = true` call in a cell links the surfaces already in
	# the figure last): a bar still at that placement moves next to all of
	# the plot areas using the coloraxis, as `shared_colorbar!` places it.
	for (id, rebound) in _fin_rebound_coloraxes(ctx)
		axis = get(layout.fields, Symbol(id), nothing)
		_cmn_mapping_get(axis, :showscale) === false && continue
		bar = _symbol_dict(_cmn_mapping_get(axis, :colorbar))
		haskey(bar, :x) || continue
		side = _cbar_string(bar, :orientation, "v") == "h" ? :bottom : :right
		all_regions, _ = _cbar_coloraxis_regions(p, id, 1)
		others = Any[]
		for (index, trace) in enumerate(p.data)
			index in rebound && continue
			slot = _cbar_slot(trace, index)
			(slot === nothing || slot.coloraxis != id) && continue
			_cbar_push_region!(others, _cbar_trace_region(p, trace))
		end
		(isempty(others) || length(others) == length(all_regions)) && continue
		_cbar_placement_matches(bar, _cbar_region_placement(side, others)) || continue
		target = _cbar_region_placement(side, all_regions)
		item = _FinBar(0, nothing, id, bar, nothing, others[1], false)
		plan.wrote |= _fin_place_bar!(ctx, layout_updates, item, target)
		push!(plan.moved, (item, target))
	end
	wrote |= plan.wrote
	# Math titles drawn as annotations follow their bars; panel titles follow
	# the cells whose x domain changes here.
	annotations = _fin_title_annotations(p, plan.moved, plan.annotations)
	annotations = _fin_follow_panel_titles(layout, layout_updates, annotations)
	# A math title beside the bar (`title_side = :right`) is an annotation,
	# which plotly does not count in the margins: grow `margin.r` to fit it.
	needed = _fin_title_margin(layout, annotations === nothing ? get(layout.fields, :annotations, nothing) : annotations,
		W, plan.margins)
	if needed !== nothing
		current = _cmn_mapping_get(get(layout.fields, :margin, nothing), :r)
		(_fin_isfinite_real(current) && current >= needed) || (layout_updates[:margin_r] = needed)
	end
	_room_margin_updates!(plan)
	if annotations !== nothing
		existing = get(layout.fields, :annotations, nothing)
		(existing isa AbstractVector && length(existing) == length(annotations) &&
			all(i -> isequal(_symbol_dict(existing[i]), _symbol_dict(annotations[i])), eachindex(annotations))) ||
			(layout_updates[:annotations] = annotations)
	end
	wrote |= _fin_relayout!(ctx, layout_updates)
	wrote |= _fin_thin_bar_ticks!(ctx, plan.Wp, plan.Hp)
	wrote |= _fin_place_figure_annotations!(ctx, accs, W, H)
	return wrote
end

# ---------------------------------------------------------------------------
# W5: axis titles longer than the figure
# ---------------------------------------------------------------------------

# Line break `_fin_wrap_axis_titles!` writes. A user's line breaks are `<br>`
# (`_label` turns "\n" into it); plotly.js breaks lines at both. Every pass
# first joins the lines at this break again, then wraps for the current size.
const _FIN_WRAP_BREAK = "<br />"
# Px a wrapped title keeps from the figure edges, and the mean glyph width
# (font sizes) the wrap assumes: a little above DejaVu Sans' (render probe
# W5: 26 characters of the optical_infra y title at 13 px drew 155 px long,
# 0.46 em), so a wrapped line fits.
const _FIN_WRAP_PAD = 4.0
const _FIN_WRAP_CHAR_EM = 0.55
# Markup other than line breaks: such a title is left as written.
const _FIN_WRAP_MARKUP = r"<(?!br\s*/?>)"i

# `line` broken between words into lines of at most `max_chars` characters
# (a longer word keeps a line of its own).
function _fin_wrap_line(line::AbstractString, max_chars::Int)
	_fin_text_chars(line) <= max_chars && return String(line)
	lines = String[]
	current = ""
	for word in split(line, ' '; keepempty = false)
		candidate = isempty(current) ? String(word) : current * " " * word
		if isempty(current) || _fin_text_chars(candidate) <= max_chars
			current = candidate
		else
			push!(lines, current)
			current = String(word)
		end
	end
	isempty(current) || push!(lines, current)
	return join(lines, _FIN_WRAP_BREAK)
end

# `text` with every line (between the user's breaks, which are kept as
# written) wrapped at `max_chars`.
function _fin_wrap_title(text::AbstractString, max_chars::Int)
	out = IOBuffer()
	start = 1
	for m in eachmatch(_FIN_LINE_BREAK, text)
		print(out, _fin_wrap_line(SubString(text, start, prevind(text, m.offset)), max_chars), m.match)
		start = m.offset + ncodeunits(m.match)
	end
	print(out, _fin_wrap_line(SubString(text, start), max_chars))
	return String(take!(out))
end

# W5: a plain axis title longer than the figure can show along its axis
# (centred on the axis, `_FIN_WRAP_PAD` from the figure edges, figure
# `W` x `H` px) is broken into lines between words; a title that fits again
# (a larger export, a shorter text) is joined again. Math (`$…$`) and styled
# titles are left as written.
function _fin_wrap_axis_titles!(ctx::_FinContext, accs, W::Float64, H::Float64)
	layout = ctx.p.layout
	font = _fin_font_size(layout)
	# The margins with the push of the axis labels (a `tight_layout!` margin
	# of 4 px puts the plot area where the labels end, not at 4 px:
	# optical_cividis wrapped a title that fits).
	m = _fin_margins(layout, accs, W, H, Dict{Symbol, NTuple{2, Float64}}(), Any[])
	Wp, Hp = max(W - m.l - m.r, 1.0), max(H - m.t - m.b, 1.0)
	updates = Dict{Symbol, Any}()
	wrapped_keys = Symbol[]
	for (key, axis) in layout.fields
		(key isa Symbol && _fin_is_axis_key(key)) || continue
		_cmn_mapping_get(axis, :visible) === false && continue
		text = _fin_title_text(axis)
		(isempty(text) || occursin('$', text) || occursin(_FIN_WRAP_MARKUP, text)) && continue
		plain = replace(text, _FIN_WRAP_BREAK => " ")
		size = _fin_mapping_font_size(_cmn_mapping_get(axis, :title), :font, round(1.2 * font))
		vertical = String(key)[1] == 'y'
		d = vertical ? _cmn_y_axis_domain(layout, key) : _fin_domain(layout, key)
		centre = vertical ? m.b + (d[1] + d[2]) / 2 * Hp : m.l + (d[1] + d[2]) / 2 * Wp
		extent = vertical ? H : W
		room = 2 * min(centre, extent - centre) - 2 * _FIN_WRAP_PAD
		max_chars = max(1, floor(Int, room / (_FIN_WRAP_CHAR_EM * size)))
		wrapped = _fin_wrap_title(plain, max_chars)
		wrapped == plain || push!(wrapped_keys, key)
		wrapped == text && continue
		title = _cmn_mapping_get(axis, :title)
		if title isa AbstractString
			updates[Symbol(key, :_title)] = Dict{Symbol, Any}(:text => wrapped)
			wrapped == plain || (updates[Symbol(key, :_title_standoff)] = _FIN_WRAP_STANDOFF)
			continue
		end
		updates[Symbol(key, :_title_text)] = wrapped
		# plotly.js 2.35.2 (axes.js drawTitle) moves a left or top title out
		# by its extra lines only when `title.standoff` is set; without it
		# they run into the tick labels. Ours goes with our breaks.
		standoff = _cmn_mapping_get(title, :standoff)
		if wrapped != plain
			standoff === nothing && (updates[Symbol(key, :_title_standoff)] = _FIN_WRAP_STANDOFF)
		elseif _fin_isfinite_real(standoff) && standoff == _FIN_WRAP_STANDOFF
			updates[Symbol(key, :_title_standoff)] = nothing
		end
	end
	wrote = _fin_relayout!(ctx, updates)
	# Export copies only (`size` given): a margin grown on the figure itself
	# would outlive the wrap (a later font or size change joins the lines
	# again; composite_2x2 kept a 155 px left margin).
	ctx.size === nothing && return wrote
	return _fin_wrap_margins!(ctx, accs, wrapped_keys, Hp) || wrote
end

# plotly.js's automargin does not count the extra lines of a wrapped title
# in full (render probe W5: from a 4 px `tight_layout!` margin the third line
# ran over the tick labels): on an export copy, a wrapped title at the left or
# bottom paper edge gets the margin its axis labels need (`_fin_y_labels_px` /
# `_fin_x_labels_px`, which count the lines) plus `_FIN_WRAP_PAD`. Like every
# margin the finalizer writes, it only grows.
function _fin_wrap_margins!(ctx::_FinContext, accs, keys::Vector{Symbol}, Hp::Float64)
	isempty(keys) && return false
	layout = ctx.p.layout
	base = _fin_margins_base(layout)
	need = Dict{Symbol, Float64}()
	for key in keys
		axis = get(layout.fields, key, nothing)
		vertical = String(key)[1] == 'y'
		side = something(_fin_string(_cmn_mapping_get(axis, :side)), vertical ? "left" : "bottom")
		side in ("left", "bottom") || continue
		anchor = _fin_axis_key(_cmn_mapping_get(axis, :anchor, vertical ? "x" : "y"))
		anchor === nothing && continue
		# The axis is drawn at its anchor's start: only one at the paper edge
		# pushes the margin.
		edge = vertical ? _fin_domain(layout, anchor)[1] : _cmn_y_axis_domain(layout, anchor)[1]
		edge <= 1e-9 || continue
		px = vertical ? _fin_y_labels_px(layout, accs, key, _cmn_y_axis_domain(layout, key), Hp) :
			_fin_x_labels_px(layout, key)
		letter = vertical ? :l : :b
		need[letter] = max(get(need, letter, 0.0), px + _FIN_WRAP_PAD)
	end
	updates = Dict{Symbol, Any}()
	for (letter, px) in need
		have = getfield(base, letter)
		px > have + 0.5 && (updates[Symbol(:margin_, letter)] = ceil(px))
	end
	return _fin_relayout!(ctx, updates)
end

# `title.standoff` (px between tick labels and title) written with wrapped
# lines: plotly's base gap (axes.js: 10 px plus half a font size).
const _FIN_WRAP_STANDOFF = 10.0

# ---------------------------------------------------------------------------
# Z11 (G76): automatic ticks of short colorbars
# ---------------------------------------------------------------------------

# Least distance (font sizes) between the tick labels of a vertical colorbar;
# the labels of a horizontal bar keep one font size between them.
const _FIN_BAR_TICK_SPACING_EM = 2.0

# `(automatic, ours)`: whether the ticks of `bar` are plotly's automatic ones,
# and whether its `nticks` is ours (written with an explicit `tickmode =
# "auto"` by `_fin_thin_bar_ticks!`; an `nticks` set without it is the user's).
function _fin_bar_tick_state(bar::Dict{Symbol, Any})
	mode = _cbar_string(bar, :tickmode, "")
	nticks = get(bar, :nticks, nothing)
	mode == "auto" && _fin_isfinite_real(nticks) && return (true, true)
	values = get(bar, :tickvals, nothing)
	explicit = (values isa AbstractVector || values isa Tuple) && !isempty(values)
	automatic = mode in ("", "auto") && (nticks === nothing || isequal(nticks, 0)) &&
		get(bar, :dtick, nothing) === nothing && !explicit
	return (automatic, false)
end

# `nticks` that keeps the automatic tick labels of `item`'s bar apart at the
# length it is drawn with (plot area `Wp` x `Hp` px), or `nothing` when
# plotly's own count does. plotly.js 2.35.2 (axes.js prepTicks) asks a
# colorbar for clamp(length / m, 4, 9) + 1 ticks, m = 40 px for a vertical
# bar (axis id "y…") and 80 px for a horizontal one: at least 5 ticks, which
# a short bar cannot hold. With `nticks = n` the tick step is at least the
# colour range / n, so the labels are at least length / n px apart.
function _fin_bar_nticks(layout::Layout, item::_FinBar, Wp::Float64, Hp::Float64)
	bar = item.bar
	vertical = _fin_bar_vertical(bar)
	span = vertical ? Hp : Wp
	len = _cbar_string(bar, :lenmode, "fraction") == "fraction" ? _cbar_real(bar, :len, 1.0) * span :
		_cbar_real(bar, :len, span)
	# The bar's axis runs between the pads at both ends (default 10 px).
	axis_px = len - 2 * _cbar_real(bar, vertical ? :ypad : :xpad, 10.0)
	axis_px > 0 || return nothing
	font = _fin_mapping_font_size(bar, :tickfont, _fin_font_size(layout))
	spacing = if vertical
		_FIN_BAR_TICK_SPACING_EM * font
	else
		lo, hi = item.range === nothing ? (NaN, NaN) : item.range
		max(_fin_tick_chars(bar, lo, hi, axis_px, false, false), 1) * 0.6 * font + font
	end
	default = clamp(axis_px / (vertical ? 40.0 : 80.0), 4.0, 9.0) + 1
	# Two ticks at least: a bar shows where its colour range starts and how it grows.
	wanted = max(2, floor(Int, axis_px / spacing))
	return wanted < default ? wanted : nothing
end

# Thin the automatic ticks of every short colorbar (`_fin_bar_nticks`) and
# drop the `nticks` written earlier for a bar that is long enough again.
# Bars with ticks of their own (values, a step or a user `nticks`) are left
# alone.
function _fin_thin_bar_ticks!(ctx::_FinContext, Wp::Float64, Hp::Float64)
	by_area, order, _ = _fin_collect_bars(ctx.p, ctx.insets)
	updates = Dict{Symbol, Any}()
	wrote = false
	for key in order, item in by_area[key]
		_fin_item_writable(ctx, item) || continue
		automatic, ours = _fin_bar_tick_state(item.bar)
		automatic || continue
		n = _fin_bar_nticks(ctx.p.layout, item, Wp, Hp)
		change = if n !== nothing
			Dict{Symbol, Any}(:tickmode => "auto", :nticks => n)
		elseif ours
			Dict{Symbol, Any}(:tickmode => nothing, :nticks => nothing)
		else
			continue
		end
		wrote |= _fin_place_bar!(ctx, updates, item, change)
	end
	wrote |= _fin_relayout!(ctx, updates)
	return wrote
end

# Z47: whole-figure annotations (`annotate!(...; coords = :figure)`) are
# shifted by the margins (`_figure_annotations_place!`): re-place them for
# the margins this pass leaves, at the size the figure is finalized for.
function _fin_place_figure_annotations!(ctx::_FinContext, accs, W::Float64, H::Float64)
	layout = ctx.p.layout
	existing = get(layout.fields, :annotations, nothing)
	existing isa AbstractVector || return false
	any(item -> _figure_annotation_spec(item) !== nothing, existing) || return false
	annotations = collect(Any, existing)
	new_b = _figure_annotations_place!(ctx.p, annotations; size = (W, H), accs = accs)
	updates = Dict{Symbol, Any}()
	all(i -> isequal(_symbol_dict(existing[i]), _symbol_dict(annotations[i])), eachindex(annotations)) ||
		(updates[:annotations] = annotations)
	new_b === nothing || (updates[:margin_b] = new_b)
	return _fin_relayout!(ctx, updates)
end

# The room plan and the equal-aspect fits of a figure W x H px. Equal-aspect
# cells are fitted inside the room their other decorations leave; a cell the
# fit cannot handle (unknown ranges, a domain outside its cell, overlaying
# axes) is laid out like any other plot area.
function _fin_plan_and_fit(ctx::_FinContext, accs, bars, W::Float64, H::Float64)
	layout = ctx.p.layout
	aspect = Dict{Symbol, Symbol}()
	for (xkey, ykey, _) in _fin_aspect_cells(layout, accs)
		aspect[xkey] = ykey
	end
	plan = _room_build(ctx, accs, bars, W, H, aspect)
	fits = Dict{Tuple{Symbol, Symbol}, Any}()
	isempty(aspect) && return plan, fits
	fits = _fin_fit_cells(ctx, layout, accs, bars[1], W, H; reduce = _room_fit_reduction(plan),
		push = _room_edge_needs(plan))
	unfitted = [xkey for (xkey, ykey) in aspect if !haskey(fits, (xkey, ykey))]
	if !isempty(unfitted)
		for xkey in unfitted
			delete!(aspect, xkey)
		end
		plan = _room_build(ctx, accs, bars, W, H, aspect)
	end
	return plan, fits
end

# Coloraxis id => indices of the traces this mutation bound to it that
# existed before it (same index in `ctx.before`) with another or no colour
# axis. Empty without the pre-mutation traces.
function _fin_rebound_coloraxes(ctx::_FinContext)
	out = Dict{String, Set{Int}}()
	ctx.before === nothing && return out
	data = ctx.p.data
	for (index, old) in enumerate(ctx.before)
		index <= length(data) || break
		new = data[index]
		(old isa GenericTrace && new isa GenericTrace) || continue
		id = _fin_string(get(new.fields, :coloraxis, nothing))
		id === nothing && continue
		_fin_string(get(old.fields, :coloraxis, nothing)) == id && continue
		push!(get!(Set{Int}, out, id), index)
	end
	return out
end

# Width (px) of what a y axis draws beside its plot area (tick labels, ticks
# and title; the automargin push of `_fin_margins`), 0 when hidden.
function _fin_y_labels_px(layout::Layout, accs, ykey::Symbol, dy, Hp::Float64)
	axis = get(layout.fields, ykey, nothing)
	_cmn_mapping_get(axis, :visible) === false && return 0.0
	font = _fin_font_size(layout)
	shown = _fin_shown_range(layout, ykey, accs)
	lo, hi = shown === nothing ? (NaN, NaN) : shown
	chars = _fin_tick_chars(axis, lo, hi, (dy[2] - dy[1]) * Hp, _fin_axis_type(layout, ykey) == "log", true)
	tickfont = _fin_mapping_font_size(axis, :tickfont, font)
	return chars * 0.6 * tickfont + _fin_tick_len(axis) + 2 + _fin_title_push(axis, font)
end

# Height (px) of what an x axis draws beside its plot area: one line of tick
# labels (taller for the power-format labels of a log axis), ticks and title;
# 0 when hidden.
function _fin_x_labels_px(layout::Layout, xkey::Symbol)
	axis = get(layout.fields, xkey, nothing)
	_cmn_mapping_get(axis, :visible) === false && return 0.0
	font = _fin_font_size(layout)
	tickfont = _fin_mapping_font_size(axis, :tickfont, font)
	labels = _cmn_mapping_get(axis, :showticklabels) === false ? 0.0 :
		(_fin_axis_type(layout, xkey) == "log" ? 1.8 : 1.4) * tickfont + 1
	return labels + _fin_tick_len(axis) + _fin_title_push(axis, font)
end

# Width (px) of what an axis draws left of its plot area: tick labels, ticks
# and title; 0 for an axis on the right side or hidden.
function _fin_left_decoration(layout::Layout, accs, ykey::Symbol, dy, Hp::Float64)
	axis = get(layout.fields, ykey, nothing)
	something(_fin_string(_cmn_mapping_get(axis, :side)), "left") == "left" || return 0.0
	return _fin_y_labels_px(layout, accs, ykey, dy, Hp)
end

const _FIN_DOMAIN_SUBPLOT = r"^(scene|polar|ternary|geo|mapbox|map|smith)([2-9]|[1-9][0-9]+)?$"

# The plot areas of `positions` (`domains` overriding axis domains): per
# base x axis `(dx, dy, ykey)`, per domain subplot (scene, polar, ...)
# `(dx, dy, nothing)`.
function _fin_plot_area_boxes(positions::Layout, domains = Dict{Symbol, NTuple{2, Float64}}())
	domain_of(key) = haskey(domains, key) ? domains[key] : _layout_axis_domain(positions, key)
	boxes = Tuple{Any, Any, Union{Nothing, Symbol}}[]
	for (key, axis) in positions.fields
		key isa Symbol || continue
		if _fin_is_axis_key(key)
			(String(key)[1] == 'x' && _fin_is_base_axis(positions, key)) || continue
			dx = domain_of(key)
			ykey = _fin_axis_key(_cmn_mapping_get(axis, :anchor, "y"))
			(dx === nothing || ykey === nothing) && continue
			push!(boxes, (dx, something(domain_of(ykey), (0.0, 1.0)), ykey))
		elseif occursin(_FIN_DOMAIN_SUBPLOT, String(key))
			domain = _layout_subplot_domain(positions, key)
			domain === nothing && continue
			push!(boxes, (domain[1], domain[2], nothing))
		end
	end
	return boxes
end

# The nearest other plot area to the right of the area `xd` x `yd` among
# those overlapping it vertically (Cartesian cells and domain subplots such
# as scenes): `(x = paper x where it starts, push = px its y axis draws left
# of it)`, or `nothing` for the rightmost area. Domains and anchors are read
# from `positions` (with `domains` overriding axis domains), axis styles from
# `layout`. `areas` is `_fin_plot_area_boxes(positions, domains)`, passed in
# when several cells are checked against the same positions (Z82).
function _fin_right_neighbour(layout::Layout, accs, xd, yd, Hp::Float64;
		positions::Layout = layout, domains = Dict{Symbol, NTuple{2, Float64}}(),
		areas = _fin_plot_area_boxes(positions, domains))
	nearest = nothing
	push = 0.0
	for (dx, dy, ykey) in areas
		(dx[1] >= xd[2] - 1e-9 && dy[1] < yd[2] - 1e-9 && dy[2] > yd[1] + 1e-9) || continue
		this_push = ykey === nothing ? 0.0 : _fin_left_decoration(layout, accs, ykey, dy, Hp)
		if nearest === nothing || dx[1] < nearest - 1e-9
			nearest = dx[1]
			push = this_push
		elseif abs(dx[1] - nearest) <= 1e-9
			push = max(push, this_push)
		end
	end
	return nearest === nothing ? nothing : (x = nearest, push = push)
end

# ---------------------------------------------------------------------------
# D12: room reservation
#
# Every decoration PlotlySupply places next to a plot area (colorbars here;
# legends, panel titles and labels by their owners through the same calls)
# gets its own room: taken from the plot area's grid cell (its domain
# shrinks) when the gap to the neighbouring cell is too small, or from the
# figure margin at the paper edge, never from a neighbour.
#
# Contract for other owners (decision D12, CONTRACT.md):
# - measure: `_finalize_figure!` calls `_room_requests!(plan, Val(owner))` for
#   every owner in `_ROOM_OWNERS`; a provider calls `_request_room!` once per
#   decoration it has in `plan.p`.
# - place: after the solve it calls `_room_place!(plan, Val(owner))`; the
#   provider reads `_room_slot(plan, owner, key)` (and `_room_domain`) and
#   writes only through `_room_relayout!` / `_room_annotations!`.
# Both fall back to doing nothing, so an owner without a provider is a no-op.
# ---------------------------------------------------------------------------

const _ROOM_OWNERS = (:colorbar, :legend_titles, :grid_titles, :annotate)
const _ROOM_SIDES = (:top, :bottom, :left, :right)
const _ROOM_OPPOSITE = Dict(:top => :bottom, :bottom => :top, :left => :right, :right => :left)
# Gap (px) between the axis labels and the first decoration on a side, and
# between two decorations stacked on one side.
const _ROOM_GAP = 4.0
# Extra px between drawn axis labels and a decoration: the label estimates
# run a pixel or two short of what plotly draws (measured: x tick labels plus
# title 50.2 px against 48.1 estimated; a bar's tick labels within 1 px).
const _ROOM_LABEL_PAD = 4.0
# How far (font sizes) the glyphs of a plain title on top of a horizontal
# colorbar rise above the bar's `y` (measured: 4 px at 12 px).
const _FIN_HBAR_TITLE_RISE = 0.35
# A plot area gives up at most this share of its grid cell's width (left +
# right) or height (top + bottom); a decoration needing more overlaps. Two
# thirds: a 2 x 2 grid with two-line panel titles, panel labels, x and y
# titles, a cell legend, a colorbar and a figure legend at the IEEE
# single-column size (336 x 252 px) needs 62 % between its rows.
const _ROOM_MAX_SHARE = 2 / 3
# Height of a MathJax colorbar title drawn above or below a horizontal bar,
# in font sizes (`$|E|^2$` and `$\frac{a}{b}$` render about 1.6 em tall).
const _FIN_MATH_TITLE_H = 1.8

"""
	_RoomRequest

One decoration's claim on a side of a plot area (see `_request_room!`).
"""
struct _RoomRequest
	area::Symbol
	side::Symbol
	px::Float64
	owner::Symbol
	key::String
	order::Int
	anchored::Bool
	margin_pushed::Bool
end

const _RoomBox = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}

# A plot area: a Cartesian cell (`key` = its x axis key, `ykey` its y axis)
# or a domain subplot such as a scene (`key` = :scene2). `grid`: a subplot
# grid cell; `ref` its grid rectangle (paper; `nothing` outside a grid, set
# by `_room_set_refs!`); `current` its domains now, `final` after the solve.
# `managed`: its domains lie inside `ref` and may be shrunk; `aspect`: an
# equal-aspect cell fitted by `_fin_fit_cells`; `frozen`: a decoration of it
# cannot be moved in this pass (the append-only fast path shares its trace),
# so nothing of it changes. `own`: px its axes draw on each side.
mutable struct _RoomArea
	key::Symbol
	ykey::Union{Nothing, Symbol}
	kind::Symbol
	grid::Bool
	ref::Union{Nothing, _RoomBox}
	current::_RoomBox
	final::_RoomBox
	managed::Bool
	aspect::Bool
	frozen::Bool
	own::Dict{Symbol, Float64}
	room::Dict{Symbol, Float64}
	writable::Dict{Symbol, Bool}
end

"""
	_RoomPlan

The state of one room-reservation pass of `_finalize_figure!`. Providers read
`plan.p` (the figure; never write it), `plan.W`/`plan.H` (figure px),
`plan.Wp`/`plan.Hp` (estimated px of the paper's plot region) and
`plan.font` (layout font size), and use `_request_room!`, `_room_slot`,
`_room_domain`, `_room_relayout!` and `_room_annotations!`.
"""
mutable struct _RoomPlan
	ctx::_FinContext
	p::Plot
	layout::Layout
	accs::Any
	W::Float64
	H::Float64
	Wp::Float64
	Hp::Float64
	font::Float64
	margins::Any
	areas::Dict{Symbol, _RoomArea}
	area_order::Vector{Symbol}
	requests::Vector{_RoomRequest}
	slots::Dict{Tuple{Symbol, String}, Vector{Any}}
	updates::Dict{Symbol, Any}
	annotations::Union{Nothing, Vector{Any}}
	bars::Any
	aspect::Dict{Symbol, Symbol}
	skip_bars::Set{Int}
	bar_items::Dict{String, Any}
	vacated::Set{Tuple{Symbol, Symbol}}
	moved::Vector{Tuple{_FinBar, Dict{Symbol, Any}}}
	wrote::Bool
end

_room_requests!(plan, ::Val) = nothing
_room_place!(plan, ::Val) = nothing

"""
	_request_room!(plan, area::Symbol, side::Symbol, px::Real; owner::Symbol,
		key::AbstractString, order::Integer = 20, anchored::Bool = false,
		margin_pushed::Bool = false)

Claim `px` (CSS px, >= 0: the decoration's depth perpendicular to `side`,
its padding included, the axis' own labels excluded) on `side` (`:top`,
`:bottom`, `:left`, `:right`) of plot area `area` (an x axis key such as
`:xaxis3`, a domain subplot key such as `:scene2`, or `:figure` for a
decoration outside the whole grid). `key` names the decoration (unique per
owner); `order` stacks decorations on one side, nearest the axes first
(colorbars use 10, legends 20; equal orders keep the request order);
`anchored` states that the decoration sits where the last placement put it
relative to the current domain (the evidence that a shrunk domain is
PlotlySupply's); `margin_pushed` that plotly grows the figure margin for it
by itself (colorbars, legends); otherwise the engine raises `layout.margin`
at the paper edge. A request for an area the figure does not have is
ignored.
"""
function _request_room!(plan, area::Symbol, side::Symbol, px::Real; owner::Symbol, key::AbstractString,
		order::Integer = 20, anchored::Bool = false, margin_pushed::Bool = false)
	side in _ROOM_SIDES || throw(ArgumentError(
		"_request_room!: `side` must be :top, :bottom, :left or :right; got $(repr(side)).",
	))
	(px isa Real && !(px isa Bool) && isfinite(px) && px >= 0) || throw(ArgumentError(
		"_request_room!: `px` must be a finite number >= 0; got $(repr(px)).",
	))
	(area === :figure || haskey(plan.areas, area)) || return nothing
	push!(plan.requests, _RoomRequest(area, side, Float64(px), owner, String(key), Int(order), anchored,
		margin_pushed))
	return nothing
end

"""
	_room_slot(plan, owner::Symbol, key::AbstractString) -> slot | nothing

Where the decoration `key` of `owner` goes after the solve: a named tuple
`(area, side, px, edge, offset, domain_x, domain_y, release)`. `edge` is the
paper coordinate of the area's edge on `side` (final domains); `offset` the
px from it to where the decoration starts (the axis labels and the
decorations nearer the axes already counted, plus `_ROOM_GAP` each);
`release` whether the area's domain on that side is the user's (place the
decoration without an ownership mark). `nothing` for an unknown request. A
decoration requested on several areas has one slot per area
(`_room_slots`).
"""
function _room_slot(plan, owner::Symbol, key::AbstractString)
	slots = get(plan.slots, (owner, String(key)), nothing)
	(slots === nothing || isempty(slots)) && return nothing
	return first(slots)
end

_room_slots(plan, owner::Symbol, key::AbstractString) = get(plan.slots, (owner, String(key)), Any[])

"""
	_room_domain(plan, area::Symbol) -> ((x0, x1), (y0, y1)) | nothing

Final paper domains of plot area `area` after the solve.
"""
_room_domain(plan, area::Symbol) = (a = get(plan.areas, area, nothing); a === nothing ? nothing : a.final)

"""
	_room_relayout!(plan, key::Symbol, value)

Queue a layout write (`relayout!` key such as `:legend2_y`) for the one
relayout of this pass; a value equal to the current one is dropped.
"""
function _room_relayout!(plan, key::Symbol, value)
	_fin_layout_value_changed(_room_current(plan.layout, key), value) || return nothing
	plan.updates[key] = value
	return nothing
end

"""
	_room_annotations!(plan) -> Vector{Any}

The layout annotations as one mutable vector shared by all owners of this
pass (copied from the layout on first use); edit or replace your own named
items in it. It is written back only if it differs from the layout's.
"""
function _room_annotations!(plan)
	if plan.annotations === nothing
		existing = get(plan.layout.fields, :annotations, nothing)
		plan.annotations = existing isa AbstractVector ? collect(Any, existing) : Any[]
	end
	return plan.annotations
end

# Current layout value at a `relayout!` key path (`:legend2_y` -> legend2.y).
function _room_current(layout::Layout, key::Symbol)
	value = layout.fields
	for part in split(String(key), '_')
		value = _cmn_mapping_get(value, Symbol(part))
		value === nothing && return nothing
	end
	return value
end

"""
	_room_text_width(text, fontsize) -> px
	_room_text_height(text, fontsize) -> px

Generous size estimates of a label: HTML tags and `\$` dropped, a TeX
command as one glyph, 0.6 em per character, the widest `<br>` line; 1.4 em
per line, 2.2 em for a line of a math text with fractions, sums, integrals
or scripts.
"""
function _room_text_width(text, fontsize::Real)
	s = text isa AbstractString ? String(text) : string(text)
	lines = split(s, r"<br\s*/?>"i)
	return maximum(line -> _fin_text_chars(line), lines) * 0.6 * Float64(fontsize)
end

function _room_text_height(text, fontsize::Real)
	s = text isa AbstractString ? String(text) : string(text)
	isempty(s) && return 0.0
	math = occursin('$', s)
	total = 0.0
	for line in split(s, r"<br\s*/?>"i)
		tall = math && occursin(r"\\frac|\\dfrac|\\sum|\\int|\^|_", line)
		total += (tall ? 2.2 : 1.4) * Float64(fontsize)
	end
	return total
end

_room_box(xd, yd) = (xd === nothing || yd === nothing) ? nothing :
	((Float64(xd[1]), Float64(xd[2])), (Float64(yd[1]), Float64(yd[2])))

_room_inside(cur, ref) = _fin_within(cur[1], ref[1]) && _fin_within(cur[2], ref[2])

function _room_edge(box, side::Symbol)
	side === :right && return box[1][2]
	side === :left && return box[1][1]
	side === :top && return box[2][2]
	return box[2][1]
end

_room_px(plan, side::Symbol) = side === :left || side === :right ? plan.Wp : plan.Hp

# Px a side's own axis labels take, with `_ROOM_LABEL_PAD` when there are any.
_room_label_px(own::Real) = own > 0 ? Float64(own) + _ROOM_LABEL_PAD : 0.0

# Plot-area key of a `_cbar_trace_region` key: "x3" -> :xaxis3, "scene2" ->
# :scene2; `nothing` for paper/domain-trace regions.
function _room_region_area(key::AbstractString)
	occursin(r"^x([2-9]|[1-9][0-9]+)?$", key) && return _fin_axis_key(key)
	return occursin(_FIN_DOMAIN_SUBPLOT, key) ? Symbol(key) : nothing
end

# A y axis title is drawn beyond the push `_fin_title_push` estimates for it
# (plotly lets it reach into the automargin extra): its box ends
# 14.5 + 1.35 f px past the tick labels for a title font of f px (probe p29,
# plotly.js 2.35.2: f = 10, 14, 20, 28 gave 28.0, 33.4, 41.5, 52.3 px).
# A side facing another cell, or a decoration beyond the title, needs that.
function _room_y_title_overhang(layout::Layout, ykey::Symbol)
	axis = get(layout.fields, ykey, nothing)
	(_cmn_mapping_get(axis, :visible) === false || isempty(_fin_title_text(axis))) && return 0.0
	font = _fin_font_size(layout)
	size = _fin_mapping_font_size(_cmn_mapping_get(axis, :title), :font, round(1.2 * font))
	return max(0.0, 14.5 + 1.35 * size - _fin_title_push(axis, font))
end

# Px the axes of a Cartesian area draw on each side.
function _room_own_extents(plan::_RoomPlan, xkey::Symbol, ykey::Symbol, cur)
	layout = plan.layout
	own = Dict{Symbol, Float64}(side => 0.0 for side in _ROOM_SIDES)
	own[:left] = _fin_left_decoration(layout, plan.accs, ykey, cur[2], plan.Hp)
	own[:left] > 0 && (own[:left] += _room_y_title_overhang(layout, ykey))
	xaxis = get(layout.fields, xkey, nothing)
	if something(_fin_string(_cmn_mapping_get(xaxis, :side)), "bottom") == "top"
		own[:top] = _fin_x_labels_px(layout, xkey)
	else
		own[:bottom] = _fin_x_labels_px(layout, xkey)
	end
	yaxis = get(layout.fields, ykey, nothing)
	something(_fin_string(_cmn_mapping_get(yaxis, :side)), "left") == "right" &&
		(own[:right] = _fin_y_labels_px(layout, plan.accs, ykey, cur[2], plan.Hp) +
			_room_y_title_overhang(layout, ykey))
	xref, yref = _fin_axis_ref(xkey), _fin_axis_ref(ykey)
	# Overlaying axes: a twin y axis on the right, a secondary x axis on top.
	for (key, axis) in layout.fields
		_fin_is_axis_key(key) || continue
		over = _fin_string(_cmn_mapping_get(axis, :overlaying))
		over === nothing && continue
		letter = String(key)[1]
		if letter == 'y' && over == yref &&
				something(_fin_string(_cmn_mapping_get(axis, :side)), "left") == "right"
			own[:right] = max(own[:right], _fin_y_labels_px(layout, plan.accs, key, cur[2], plan.Hp) +
				_room_y_title_overhang(layout, key))
		elseif letter == 'x' && over == xref &&
				something(_fin_string(_cmn_mapping_get(axis, :side)), "bottom") == "top"
			own[:top] = max(own[:top], _fin_x_labels_px(layout, key))
		end
	end
	return own
end

function _room_new_area(key::Symbol, ykey, kind::Symbol, grid::Bool, cur)
	return _RoomArea(key, ykey, kind, grid, nothing, cur, cur, false, false, false,
		Dict{Symbol, Float64}(side => 0.0 for side in _ROOM_SIDES),
		Dict{Symbol, Float64}(side => 0.0 for side in _ROOM_SIDES),
		Dict{Symbol, Bool}(side => false for side in _ROOM_SIDES))
end

function _room_add_xy_area!(plan::_RoomPlan, xkey::Symbol, ykey::Symbol, grid::Bool)
	haskey(plan.areas, xkey) && return nothing
	layout = plan.layout
	cur = (_fin_domain(layout, xkey), _cmn_y_axis_domain(layout, ykey))
	area = _room_new_area(xkey, ykey, :xy, grid, cur)
	area.aspect = get(plan.aspect, xkey, nothing) === ykey
	area.own = _room_own_extents(plan, xkey, ykey, cur)
	if area.aspect
		# The colorbars the fit places against the plot box come first on
		# the right.
		hug = _fin_hug_items(plan.ctx, layout, plan.bars[1], xkey, ykey)
		if !isempty(hug)
			widths = [_fin_bar_width(layout, item, plan.Hp) for item in hug]
			area.own[:right] += _FIN_CBAR_PAD * plan.Wp + sum(widths) + _FIN_CBAR_GAP * (length(hug) - 1)
		end
	end
	plan.areas[xkey] = area
	push!(plan.area_order, xkey)
	return nothing
end

function _room_add_domain_area!(plan::_RoomPlan, key::Symbol, grid::Bool)
	haskey(plan.areas, key) && return nothing
	domain = _layout_subplot_domain(plan.layout, key)
	# Outside a grid a subplot without a domain fills the plot area
	# (plotly.js's default domain); a grid places every cell itself.
	domain === nothing && !grid && plan.layout.subplots.rows * plan.layout.subplots.cols == 1 &&
		(domain = ((0.0, 1.0), (0.0, 1.0)))
	domain === nothing && return nothing
	plan.areas[key] = _room_new_area(key, nothing, :domain, grid, _room_box(domain[1], domain[2]))
	push!(plan.area_order, key)
	return nothing
end

# The plot areas: the subplot grid's cells, then any other plot area
# carrying a colorbar (the axes or scene of a plain figure).
function _room_collect_areas!(plan::_RoomPlan)
	layout = plan.layout
	sub = layout.subplots
	grid_ref = sub.grid_ref
	in_grid = sub.rows * sub.cols > 1
	for r in axes(grid_ref, 1), c in axes(grid_ref, 2)
		(isassigned(grid_ref, r, c) && !isempty(grid_ref[r, c])) || continue
		entry = first(grid_ref[r, c])
		fields = entry.trace_kwargs.fields
		if String(entry.subplot_kind) == "xy"
			xkey = _fin_axis_key(_fin_string(get(fields, :xaxis, nothing)))
			ykey = _fin_axis_key(_fin_string(get(fields, :yaxis, nothing)))
			(xkey === nothing || ykey === nothing) && continue
			_room_add_xy_area!(plan, xkey, ykey, in_grid)
		else
			name = nothing
			for k in (:scene, :geo, :subplot)
				name = _fin_string(get(fields, k, nothing))
				name === nothing || break
			end
			(name === nothing || !occursin(_FIN_DOMAIN_SUBPLOT, name)) && continue
			_room_add_domain_area!(plan, Symbol(name), in_grid)
		end
	end
	_, order, _ = plan.bars
	for region_key in order
		key = _room_region_area(region_key)
		(key === nothing || haskey(plan.areas, key)) && continue
		if _fin_is_axis_key(key)
			ykey = _fin_axis_key(_cmn_mapping_get(get(layout.fields, key, nothing), :anchor, "y"))
			ykey === nothing || _room_add_xy_area!(plan, key, ykey, false)
		else
			_room_add_domain_area!(plan, key, false)
		end
	end
	return plan
end

# Grid rectangles and the `managed` flag (an area inside its rectangle that
# hosts no inset and is not fitted for equal aspect).
function _room_set_refs!(plan::_RoomPlan)
	sub = plan.layout.subplots
	sub.rows * sub.cols > 1 || return plan
	grid = _fin_grid_layout(plan.ctx)
	for key in plan.area_order
		a = plan.areas[key]
		a.grid || continue
		if a.kind === :xy
			a.ref = _room_box(_layout_axis_domain(grid, a.key), _layout_axis_domain(grid, a.ykey))
		else
			d = _layout_subplot_domain(grid, a.key)
			a.ref = d === nothing ? nothing : _room_box(d[1], d[2])
		end
		a.managed = a.ref !== nothing && !(a.key in plan.ctx.inset_hosts) && !a.aspect && _room_inside(a.current, a.ref)
	end
	return plan
end

# Sides that lost a colorbar of ours in this mutation (`ctx.before`): their
# shrink was ours, so the area may widen again.
function _room_vacated!(plan::_RoomPlan)
	ctx = plan.ctx
	ctx.before === nothing && return plan
	data = plan.p.data
	for (index, old) in enumerate(ctx.before)
		(old isa GenericTrace && _fin_visible(old)) || continue
		index in ctx.released && continue
		slot = _cbar_slot(old, index)
		(slot === nothing || slot.coloraxis !== nothing || !slot.shows) && continue
		bar = _symbol_dict(_cbar_slot_bar(old, slot))
		_fin_bar_owned(bar) || continue
		vertical = _fin_bar_vertical(bar)
		new = index <= length(data) ? data[index] : nothing
		if new isa GenericTrace && _fin_visible(new)
			nslot = _cbar_slot(new, index)
			if nslot !== nothing && nslot.shows && nslot.coloraxis === nothing
				nbar = _symbol_dict(_cbar_slot_bar(new, nslot))
				(_fin_bar_vertical(nbar) == vertical && (_fin_bar_owned(nbar) || _fin_bar_unplaced(nbar))) && continue
			end
		end
		area = _room_region_area(_room_trace_region_key(plan, old))
		(area === nothing || !haskey(plan.areas, area)) && continue
		push!(plan.vacated, (area, vertical ? :right : :bottom))
	end
	return plan
end

# The region key a trace's colorbar is listed under (an inset's host cell for
# a trace in an inset), as `_fin_collect_bars` lists it.
function _room_trace_region_key(plan::_RoomPlan, trace::GenericTrace)
	if !isempty(plan.ctx.insets) && _cbar_trace_kind(trace) == "xy"
		xref = string(get(trace.fields, :xaxis, "x"))
		yref = string(get(trace.fields, :yaxis, "y"))
		for inset in plan.ctx.insets
			(inset.xref == xref && inset.yref == yref) || continue
			host = _fin_inset_host_region(plan.p, inset)
			host === nothing || return host.key
		end
	end
	return _cbar_trace_region(plan.p, trace).key
end

# The neighbouring grid areas across `side` of area `a` at the smallest
# distance: `(gap = paper fraction, keys = their keys)`, or `nothing` at the
# paper edge (or outside a grid).
function _room_neighbour(plan::_RoomPlan, a::_RoomArea, side::Symbol)
	a.ref === nothing && return nothing
	rx, ry = a.ref
	best = Inf
	found = Symbol[]
	for key in plan.area_order
		b = plan.areas[key]
		(b === a || b.ref === nothing) && continue
		bx, by = b.ref
		if side === :right || side === :left
			(by[1] < ry[2] - 1e-9 && by[2] > ry[1] + 1e-9) || continue
			d = side === :right ? bx[1] - rx[2] : rx[1] - bx[2]
		else
			(bx[1] < rx[2] - 1e-9 && bx[2] > rx[1] + 1e-9) || continue
			d = side === :top ? by[1] - ry[2] : ry[1] - by[2]
		end
		d >= -1e-9 || continue
		if d < best - 1e-12
			best = d
			empty!(found)
			push!(found, key)
		elseif abs(d - best) <= 1e-12
			push!(found, key)
		end
	end
	isfinite(best) || return nothing
	return (gap = max(best, 0.0), keys = found)
end

# Whether a shrunk `side` of a managed area is PlotlySupply's (D12 rule): an
# anchored request on it, or a colorbar of ours removed from it by this
# mutation (direct evidence), or another managed area of its alignment group
# (same grid edge) with direct evidence shrunk to the same edge. Domains the
# user narrowed (no decoration of ours sits against them) are kept.
function _room_evidence(plan::_RoomPlan, a::_RoomArea, side::Symbol)
	direct(b) = (b.key, side) in plan.vacated ||
		any(r -> r.area === b.key && r.side === side && r.anchored, plan.requests)
	direct(a) && return true
	ref_edge = _room_edge(a.ref, side)
	cur_edge = _room_edge(a.current, side)
	for key in plan.area_order
		b = plan.areas[key]
		(b !== a && b.managed && b.ref !== nothing) || continue
		abs(_room_edge(b.ref, side) - ref_edge) <= 1e-9 || continue
		abs(_room_edge(b.current, side) - cur_edge) <= 1e-9 || continue
		direct(b) && return true
	end
	return false
end

# A side shrunk for axis labels (Z71) carries no request; the evidence that
# the shrink is ours is that it is no deeper than what the labels on that
# side of its alignment group (same grid edge) take, padded, or than the room
# solved now (2 px tolerance): what an earlier pass wrote, also after the
# labels got smaller (a font change, a shorter title), when the side is
# given back. A deeper shrink is the user's.
function _room_label_evidence(plan::_RoomPlan, a::_RoomArea, side::Symbol)
	sign = side === :left || side === :bottom ? 1.0 : -1.0
	shrink = sign * (_room_edge(a.current, side) - _room_edge(a.ref, side)) * _room_px(plan, side)
	shrink > 0 || return false
	ref_edge = _room_edge(a.ref, side)
	limit = 0.0
	for b in values(plan.areas)
		(b.managed && b.ref !== nothing) || continue
		abs(_room_edge(b.ref, side) - ref_edge) <= 1e-9 || continue
		limit = max(limit, _room_label_px(b.own[side]))
	end
	# A side without labels in its group has no label shrink to recognise
	# (its requests have evidence of their own, `_room_evidence`).
	limit > 0 || return false
	a.own[side] > 0 && (limit = max(limit, a.room[side]))
	return shrink <= limit + 2.0
end

# Px from the grid edge of `a` on `side` to the neighbours `keys`, an
# equal-aspect neighbour counted from where its fit drew it (`current`; a fit
# that leaves slack ends short of its grid edge).
function _room_fitted_gap(plan::_RoomPlan, a::_RoomArea, side::Symbol, keys)
	edge = _room_edge(a.ref, side)
	opposite = _ROOM_OPPOSITE[side]
	gap = minimum(keys) do k
		b = plan.areas[k]
		abs(edge - _room_edge(b.aspect ? b.current : b.ref, opposite))
	end
	return gap * _room_px(plan, side)
end

# Whether the axis labels of a grid cell reach into the gap the neighbour
# needs (Z71): a figure without requests is solved only then.
function _room_labels_overflow(plan::_RoomPlan)
	need = _room_needs(plan, _room_by_side(plan))
	for key in plan.area_order
		a = plan.areas[key]
		_room_flexible(a) || continue
		for side in _ROOM_SIDES
			a.own[side] > 0 || continue
			a.aspect && continue
			nb = _room_neighbour(plan, a, side)
			nb === nothing && continue
			facing = maximum(need[(k, _ROOM_OPPOSITE[side])] for k in nb.keys)
			gap = any(k -> plan.areas[k].aspect, nb.keys) ? _room_fitted_gap(plan, a, side, nb.keys) :
				nb.gap * _room_px(plan, side)
			need[(key, side)] > gap - facing - _ROOM_GAP && return true
		end
	end
	return false
end

# The requests per (area, side), nearest the axes first (`order`, then the
# request order).
function _room_by_side(plan::_RoomPlan)
	out = Dict{Tuple{Symbol, Symbol}, Vector{_RoomRequest}}()
	for request in plan.requests
		push!(get!(Vector{_RoomRequest}, out, (request.area, request.side)), request)
	end
	for list in values(out)
		sort!(list; by = r -> r.order, alg = MergeSort)
	end
	return out
end

# Px every side of every area needs: its axis labels plus its requests.
function _room_needs(plan::_RoomPlan, by_side)
	need = Dict{Tuple{Symbol, Symbol}, Float64}()
	for (key, a) in plan.areas, side in _ROOM_SIDES
		total = _room_label_px(a.own[side])
		for request in get(by_side, (key, side), ())
			total += _ROOM_GAP + request.px
		end
		need[(key, side)] = total
	end
	return need
end

# Whether the solve may take room from an area: a grid cell inside its
# rectangle (or fitted for equal aspect) whose decorations can all move.
_room_flexible(a::_RoomArea) = (a.managed || a.aspect) && !a.frozen && a.ref !== nothing

# Room per side of every grid area and the final domains. A side with
# requests, or with axis labels facing another cell, takes
# `need - allowance`: the allowance is the gap to the
# neighbouring cells minus what they need on the facing side; when they
# take room there too (that would leave less than half the gap), the two
# split what they need beyond the gap in proportion to their spans. Areas with
# the same grid edge get the same room (rows keep a common top and bottom,
# columns a common left and right); an area gives up at most
# `_ROOM_MAX_SHARE` of its grid cell. The right side of an equal-aspect cell
# is the fit's.
function _room_solve!(plan::_RoomPlan)
	by_side = _room_by_side(plan)
	need = _room_needs(plan, by_side)
	group = Dict{Tuple{Symbol, Float64}, Float64}()
	for key in plan.area_order
		a = plan.areas[key]
		_room_flexible(a) || continue
		for side in _ROOM_SIDES
			# A side with requests, or with axis labels that may not fit in
			# the gap to the neighbour (Z71: a y title between two cells).
			(haskey(by_side, (key, side)) || a.own[side] > 0) || continue
			a.aspect && side === :right && continue
			nb = _room_neighbour(plan, a, side)
			nb === nothing && continue
			opposite = _ROOM_OPPOSITE[side]
			gap = nb.gap * _room_px(plan, side)
			facing = maximum(need[(k, opposite)] for k in nb.keys)
			movers = all(k -> _room_flexible(plan.areas[k]), nb.keys)
			if haskey(by_side, (key, side))
				shares = movers && all(k -> haskey(by_side, (k, opposite)), nb.keys)
				# `_ROOM_GAP` is kept between the last decoration and what the
				# neighbour draws on the facing side.
				allowance = shares ? max(gap - facing - _ROOM_GAP, gap / 2) : max(gap - facing - _ROOM_GAP, 0.0)
				room = need[(key, side)] - allowance
			else
				# Labels only. A neighbour taking room for requests on the
				# facing side already leaves these labels their px (its
				# allowance subtracts them); two label sides split the gap.
				# Never on an equal-aspect cell: room there rescales its fit
				# (audit_d, chama_a5: one panel of a row drawn smaller).
				a.aspect && continue
				# An equal-aspect neighbour does not move for these labels,
				# and the gap counts from where its fit drew it.
				fitted = any(k -> plan.areas[k].aspect, nb.keys)
				label_gap = fitted ? _room_fitted_gap(plan, a, side, nb.keys) : gap
				allowance = if !fitted && movers && all(k -> haskey(by_side, (k, opposite)), nb.keys)
					label_gap - _ROOM_GAP
				elseif !fitted && movers
					max(label_gap - facing - _ROOM_GAP, (label_gap - _ROOM_GAP) / 2)
				else
					max(label_gap - facing - _ROOM_GAP, 0.0)
				end
				# Room only when the unpadded estimate overflows: labels a
				# pixel or two inside the pad leave their cell alone.
				a.own[side] - allowance > 0 || continue
				room = need[(key, side)] - allowance
			end
			room > 0 || continue
			g = (side, round(_room_edge(a.ref, side); digits = 9))
			group[g] = max(get(group, g, 0.0), room)
		end
	end
	for key in plan.area_order
		a = plan.areas[key]
		for side in _ROOM_SIDES
			a.room[side] = 0.0
			a.writable[side] = false
		end
		a.aspect || (a.final = a.current)
		_room_flexible(a) || continue
		for side in _ROOM_SIDES
			a.aspect && side === :right && continue
			a.room[side] = get(group, (side, round(_room_edge(a.ref, side); digits = 9)), 0.0)
		end
		for (s1, s2, span) in ((:left, :right, (a.ref[1][2] - a.ref[1][1]) * plan.Wp),
				(:bottom, :top, (a.ref[2][2] - a.ref[2][1]) * plan.Hp))
			total = a.room[s1] + a.room[s2]
			limit = _ROOM_MAX_SHARE * span
			if total > limit
				a.room[s1] *= limit / total
				a.room[s2] *= limit / total
			end
		end
		a.managed || continue
		edges = Dict{Symbol, Float64}()
		for side in _ROOM_SIDES
			ref_edge = _room_edge(a.ref, side)
			cur_edge = _room_edge(a.current, side)
			a.writable[side] = abs(cur_edge - ref_edge) <= 1e-9 || _room_evidence(plan, a, side) ||
				_room_label_evidence(plan, a, side)
			sign = side === :left || side === :bottom ? 1.0 : -1.0
			edges[side] = a.writable[side] ? ref_edge + sign * a.room[side] / _room_px(plan, side) : cur_edge
		end
		# A domain the user set never inverts.
		(edges[:left] < edges[:right] && edges[:bottom] < edges[:top]) || continue
		a.final = ((edges[:left], edges[:right]), (edges[:bottom], edges[:top]))
	end
	return plan
end

# The slot of every request: edge of the area's final domain, offset past
# its axis labels and the decorations nearer the axes; figure-level
# decorations go outside every area touching that paper edge.
function _room_assign_slots!(plan::_RoomPlan)
	by_side = _room_by_side(plan)
	empty!(plan.slots)
	for ((key, side), list) in by_side
		key === :figure && continue
		a = plan.areas[key]
		edge = _room_edge(a.final, side)
		release = a.managed && !a.writable[side] &&
			abs(_room_edge(a.current, side) - _room_edge(a.ref, side)) > 1e-9
		offset = _room_label_px(a.own[side]) + _ROOM_GAP
		for request in list
			push!(get!(Vector{Any}, plan.slots, (request.owner, request.key)), (area = key, side = side,
				px = request.px, edge = edge, offset = offset, domain_x = a.final[1], domain_y = a.final[2],
				release = release))
			offset += request.px + _ROOM_GAP
		end
	end
	need = _room_needs(plan, by_side)
	for side in _ROOM_SIDES
		list = get(by_side, (:figure, side), nothing)
		list === nothing && continue
		paper = side === :right || side === :top ? 1.0 : 0.0
		offset = 0.0
		for key in plan.area_order
			a = plan.areas[key]
			_room_neighbour(plan, a, side) === nothing || continue
			inside = abs(_room_edge(a.final, side) - paper) * _room_px(plan, side)
			offset = max(offset, need[(key, side)] - inside)
		end
		offset += _ROOM_GAP
		for request in list
			push!(get!(Vector{Any}, plan.slots, (request.owner, request.key)), (area = :figure, side = side,
				px = request.px, edge = paper, offset = offset, domain_x = (0.0, 1.0), domain_y = (0.0, 1.0),
				release = false))
			offset += request.px + _ROOM_GAP
		end
	end
	return plan
end

# Px each paper edge needs beyond the plot region for the decorations of
# the areas at that edge (what plotly's automargin, or
# `_room_margin_updates!`, gives them).
function _room_edge_needs(plan::_RoomPlan)
	by_side = _room_by_side(plan)
	need = _room_needs(plan, by_side)
	out = Dict{Symbol, Float64}(side => 0.0 for side in _ROOM_SIDES)
	for key in plan.area_order, side in _ROOM_SIDES
		haskey(by_side, (key, side)) || continue
		a = plan.areas[key]
		_room_neighbour(plan, a, side) === nothing || continue
		paper = side === :right || side === :top ? 1.0 : 0.0
		inside = abs(_room_edge(a.final, side) - paper) * _room_px(plan, side)
		out[side] = max(out[side], need[(key, side)] - inside)
	end
	for side in _ROOM_SIDES
		list = get(by_side, (:figure, side), nothing)
		list === nothing && continue
		out[side] += sum(r.px + _ROOM_GAP for r in list)
	end
	return out
end

# Margins grown by the px `push` the paper edges need (`_fin_margins` rule).
function _room_grow_margins(margins, push)
	grow(m, p) = p <= 0 ? m : (m > 0 ? max(m, p + _FIN_AUTOMARGIN_EXTRA) : max(m, p))
	return (l = grow(margins.l, get(push, :left, 0.0)), r = grow(margins.r, get(push, :right, 0.0)),
		t = grow(margins.t, get(push, :top, 0.0)), b = grow(margins.b, get(push, :bottom, 0.0)))
end

function _room_new_plan(ctx::_FinContext, accs, bars, W::Float64, H::Float64, margins, aspect, skip)
	layout = ctx.p.layout
	return _RoomPlan(ctx, ctx.p, layout, accs, W, H, max(W - margins.l - margins.r, 1.0),
		max(H - margins.t - margins.b, 1.0), _fin_font_size(layout), margins, Dict{Symbol, _RoomArea}(),
		Symbol[], _RoomRequest[], Dict{Tuple{Symbol, String}, Vector{Any}}(), Dict{Symbol, Any}(), nothing,
		bars, aspect, skip, Dict{String, Any}(), Set{Tuple{Symbol, Symbol}}(),
		Tuple{_FinBar, Dict{Symbol, Any}}[], false)
end

# The plan of a figure W x H (`aspect`: x axis => y axis of the equal-aspect
# cells the fit handles): areas, the requests of every owner, solve. Built
# again with the margins grown by what the paper edges need, so px offsets
# convert to paper fractions with the plot size plotly will use. A figure
# without requests is not solved (nothing changes).
function _room_build(ctx::_FinContext, accs, bars, W::Float64, H::Float64, aspect::Dict{Symbol, Symbol})
	layout = ctx.p.layout
	margins = _fin_margins(layout, accs, W, H, Dict{Symbol, NTuple{2, Float64}}(), Any[])
	skip = Set{Int}()
	for (xkey, ykey) in aspect, item in _fin_hug_items(ctx, layout, bars[1], xkey, ykey)
		push!(skip, item.index)
	end
	plan = nothing
	for pass in 1:2
		plan = _room_new_plan(ctx, accs, bars, W, H, margins, aspect, skip)
		_room_collect_areas!(plan)
		_room_vacated!(plan)
		for owner in _ROOM_OWNERS
			_room_requests!(plan, Val(owner))
		end
		_room_set_refs!(plan)
		(isempty(plan.requests) && isempty(plan.vacated) && !_room_labels_overflow(plan)) && return plan
		for _ in 1:4
			_room_solve!(plan)
			_room_assign_slots!(plan)
			_room_freeze!(plan) || break
		end
		pass == 2 && break
		grown = _room_grow_margins(margins, _room_edge_needs(plan))
		grown == margins && break
		margins = grown
	end
	return plan
end

"""
	_room_plan(fig; size = nothing) -> _RoomPlan

Measure and solve the room of `fig` without writing anything (introspection
for tests): `plan.requests`, `_room_slot(plan, owner, key)`,
`_room_domain(plan, area)`. `size` is the figure size (px) to plan for.
"""
function _room_plan(fig; size = nothing)
	ctx = _fin_context(fig, nothing, size, false)
	accs = _fin_collect_axes(ctx.p)
	bars = _fin_collect_bars(ctx.p, ctx.insets)
	W, H = _fin_figure_size(ctx, ctx.p.layout)
	plan, _ = _fin_plan_and_fit(ctx, accs, bars, W, H)
	return plan
end

# Room (px) the decorations of each equal-aspect cell take on its top,
# bottom and left, which `_fin_fit_cells` fits the cell inside.
function _room_fit_reduction(plan::_RoomPlan)
	out = Dict{Symbol, Dict{Symbol, Float64}}()
	for key in plan.area_order
		a = plan.areas[key]
		a.aspect || continue
		any(side -> a.room[side] > 0, _ROOM_SIDES) || continue
		out[key] = copy(a.room)
	end
	return out
end

# Queue the domain writes of the managed areas whose final domains differ.
function _room_write_domains!(plan::_RoomPlan)
	for key in plan.area_order
		a = plan.areas[key]
		(a.managed && !a.frozen) || continue
		a.final == a.current && continue
		if a.kind === :xy
			for (axis, fin) in ((a.key, a.final[1]), (a.ykey, a.final[2]))
				_fin_layout_value_changed(_layout_axis_domain(plan.layout, axis), fin) || continue
				plan.updates[Symbol(axis, :_domain)] = [fin[1], fin[2]]
			end
		else
			dom = _layout_subplot_domain(plan.layout, a.key)
			for (i, letter) in ((1, "x"), (2, "y"))
				fin = a.final[i]
				current = dom === nothing ? nothing : dom[i]
				_fin_layout_value_changed(current, fin) || continue
				plan.updates[Symbol(a.key, :_domain_, letter)] = [fin[1], fin[2]]
			end
		end
	end
	return plan
end

# Raise `layout.margin` where a decoration plotly does not push the margin
# for (`margin_pushed = false`) reaches past the paper edge; a margin already
# large enough (the user's, or one this pass raises) is kept.
function _room_margin_updates!(plan::_RoomPlan)
	any(r -> !r.margin_pushed, plan.requests) || return plan
	base = _fin_margins_base(plan.layout)
	need = Dict{Symbol, Float64}()
	for request in plan.requests
		request.margin_pushed && continue
		for slot in _room_slots(plan, request.owner, request.key)
			(slot.area === request.area && slot.side === request.side) || continue
			if slot.area !== :figure
				_room_neighbour(plan, plan.areas[slot.area], slot.side) === nothing || continue
			end
			paper = slot.side in (:right, :top) ? 1.0 : 0.0
			inside = abs(slot.edge - paper) * _room_px(plan, slot.side)
			need[slot.side] = max(get(need, slot.side, 0.0), slot.offset + slot.px + _ROOM_GAP - inside)
		end
	end
	for (side, px) in need
		letter = Symbol(String(side)[1])
		key = Symbol(:margin_, letter)
		current = _cmn_mapping_get(get(plan.layout.fields, :margin, nothing), letter)
		have = _fin_isfinite_real(current) ? Float64(current) : getfield(base, letter)
		queued = get(plan.updates, key, nothing)
		_fin_isfinite_real(queued) && (have = max(have, Float64(queued)))
		px > have + 0.5 && (plan.updates[key] = ceil(px))
	end
	return plan
end

# ---------------------------------------------------------------------------
# Colorbars as a room owner
# ---------------------------------------------------------------------------

# The trace colorbars of an equal-aspect cell that are ours to move: drawn
# on its axes, vertical, unplaced, placed by us, or at the cell default.
function _fin_hug_items(ctx::_FinContext, layout::Layout, bars_by_area, xkey::Symbol, ykey::Symbol)
	hug = _FinBar[]
	for item in get(bars_by_area, _fin_axis_ref(xkey), _FinBar[])
		item.slot === nothing && continue
		trace = ctx.p.data[item.index]
		string(get(trace.fields, :yaxis, "y")) == _fin_axis_ref(ykey) || continue
		_fin_bar_vertical(item.bar) || continue
		cell_default = _cbar_placement(:right, _fin_domain(layout, xkey), _fin_domain(layout, ykey), _CBAR_CELL_PAD)
		(_fin_bar_unplaced(item.bar) || _fin_bar_owned(item.bar) ||
			_cbar_placement_matches(item.bar, cell_default; len = false)) || continue
		push!(hug, item)
	end
	return hug
end

_room_bar_key(item::_FinBar) = item.coloraxis !== nothing ? "coloraxis:$(item.coloraxis)" : "bar:$(item.index)"

# Plot areas whose legend plotly.js 2.35.2 does not move again when an
# automargin push redraws a geo or map figure (render probe Z49: the legend
# kept its place for the first margins and ran into the bar placed for the
# grown ones; with the margin set beforehand both match).
const _FIN_MARGIN_FIRST_SUBPLOT = r"^(geo|map|mapbox)([2-9]|[1-9][0-9]+)?$"

# The math title annotation of a bar (`_cbar_find_title_annotation`).
function _fin_bar_title_annotation(p::Plot, item::_FinBar)
	key = item.coloraxis !== nothing ? item.coloraxis : item.own === nothing ? nothing : item.own.key
	key === nothing && return nothing
	return _cbar_find_title_annotation(p, key)
end

# Px a horizontal bar's title reaches above its `y` (`title_side = :top`): a
# math title annotation drawn above it, or the glyphs of a plain title (in
# plotly's colorbar box, which they overhang a little).
function _fin_hbar_above(plan, item::_FinBar)
	text = _cbar_title_text(item.bar)
	if text !== nothing
		isempty(text) && return 0.0
		title = get(item.bar, :title, nothing)
		something(_fin_string(_cmn_mapping_get(title, :side)), "top") == "top" || return 0.0
		return _FIN_HBAR_TITLE_RISE * _fin_mapping_font_size(title, :font, plan.font)
	end
	found = _fin_bar_title_annotation(plan.p, item)
	(found === nothing || found.side !== :top) && return 0.0
	return _FIN_MATH_TITLE_H * plan.font + 4
end

# Depth (px) of a horizontal colorbar: bar, outside ticks, one line of tick
# labels below it, and a title above or below it (plain, or a math title
# drawn as an annotation).
function _fin_hbar_depth(plan, item::_FinBar)
	bar = item.bar
	font = plan.font
	thickness = _cbar_string(bar, :thicknessmode, "pixels") == "pixels" ?
		_cbar_real(bar, :thickness, _CBAR_DEFAULT_THICKNESS) : _CBAR_DEFAULT_THICKNESS
	tickfont = _fin_mapping_font_size(bar, :tickfont, font)
	labels = _cmn_mapping_get(bar, :showticklabels) === false ? 0.0 : _CBAR_LINE_EM * tickfont + 2
	depth = thickness + _fin_tick_len(bar) + labels
	text = _cbar_title_text(bar)
	if text !== nothing && !isempty(text)
		side = something(_fin_string(_cmn_mapping_get(get(bar, :title, nothing), :side)), "top")
		side in ("top", "bottom") &&
			(depth += _CBAR_LINE_EM * _fin_mapping_font_size(get(bar, :title, nothing), :font, font) + 4)
		depth += _fin_hbar_above(plan, item)
	else
		found = _fin_bar_title_annotation(plan.p, item)
		found !== nothing && found.side in (:top, :bottom) && (depth += _FIN_MATH_TITLE_H * font + 4)
	end
	return depth
end

# Whether a trace bar is ours to place on `side` of its area: unplaced,
# carrying our ownership mark, or at the default placement next to its own
# plot area (`_place_cell_colorbars!`, `colorbar!` without a position).
function _room_bar_auto(item::_FinBar, side::Symbol)
	bar = item.bar
	(_fin_bar_unplaced(bar) || _fin_bar_owned(bar)) && return true
	item.own === nothing && return false
	return _cbar_placement_matches(bar, _cbar_placement(side, item.own.xdomain, item.own.ydomain, _CBAR_CELL_PAD);
		len = false)
end

# Length (paper) of a trace bar of ours next to a plot area whose extent
# along the bar goes from `current` to `final` (paper spans): a `len` other
# than the current extent is the user's (`colorbar!(...; len)`) and is kept;
# otherwise the bar follows the area. Never shorter than `floor`
# (`_room_min_bar_len`), which counts as ours too.
function _room_bar_len(bar::AbstractDict, current::Float64, final::Float64; floor::Float64 = 0.0)
	len = _cbar_real(bar, :len, nothing)
	ours = len === nothing || !(len > 0) || _cbar_string(bar, :lenmode, "fraction") != "fraction" ||
		isapprox(len, current; atol = 1e-9) || isapprox(len, max(current, floor); atol = 1e-9)
	return max(ours ? final : Float64(len), floor)
end

# Tick label lines a vertical bar's body keeps at least. plotly.js 2.35.2
# gives an automatic colorbar axis at least five tick intervals
# (`constrain(_length / 40, 4, 9) + 1`), rounded to a 1-2-5 step: three labels
# on a typical range, drawn over each other on a body shorter than three
# label lines (G63 at 5.25 x 2 in).
const _ROOM_MIN_BAR_LINES = 3

# Shortest length (paper, of `extent_px` px) a vertical bar is drawn with: a
# title above or below it takes its height from the bar's length, and plotly
# fails on a bar left without length ("Something went wrong with axis
# scaling", G63). Room for the title and `_ROOM_MIN_BAR_LINES` tick label
# lines is kept.
function _room_min_bar_len(font::Float64, bar::AbstractDict, extent_px::Float64)
	need = _ROOM_MIN_BAR_LINES * _CBAR_LINE_EM * _fin_mapping_font_size(bar, :tickfont, font) + 2
	text = _cbar_title_text(bar)
	if text !== nothing && !isempty(text)
		title = get(bar, :title, nothing)
		side = something(_fin_string(_cmn_mapping_get(title, :side)), "top")
		side in ("top", "bottom") && (need += _CBAR_LINE_EM * _fin_mapping_font_size(title, :font, font) + 4)
	end
	return min(need / max(extent_px, 1.0), 1.0)
end

_room_span(d) = Float64(d[2] - d[1])

# A coloraxis bar where `shared_colorbar!`/`_place_cell_colorbars!` put it
# next to `regions`: centred on them, at the shared or cell pad, as long as
# the regions or shorter.
function _room_shared_matches(bar::AbstractDict, regions, side::Symbol)
	xdomain, ydomain = _cbar_union(regions)
	for pad in (_CBAR_SHARED_PAD, _CBAR_CELL_PAD)
		placement = _cbar_placement(side, xdomain, ydomain, pad)
		_cbar_string(bar, :orientation, "v") == placement[:orientation] || return false
		ok = true
		for key in (:x, :y)
			value = _cbar_real(bar, key, nothing)
			(value !== nothing && isapprox(value, placement[key]; atol = 1e-9)) || (ok = false)
		end
		for key in (:xanchor, :yanchor)
			haskey(bar, key) && _cbar_string(bar, key, "") != placement[key] && (ok = false)
		end
		len = _cbar_real(bar, :len, nothing)
		ok && len !== nothing && len <= placement[:len] + 1e-9 && return true
	end
	return false
end

# Tolerance of `_room_bar_anchored`: px (the axis-label estimates of two
# runs differ by a pixel or so), and the share of the bar's px offset from
# the edge (the offset was converted to paper with the plot height of its
# run; other decorations growing the margins since change that height).
const _ROOM_ANCHOR_TOL = 2.0
const _ROOM_ANCHOR_SHARE = 0.5

# Px of the paper's plot region at the size the figure itself is finalized
# for (its layout size, else the default). An export copy (`ctx.size`) is
# planned for another size, but the placements it inherits were made for
# this one; the margins (px) are taken as equal at both sizes.
function _room_design_px(plan)
	plan.ctx.size === nothing && return plan.Wp, plan.Hp
	W0, H0 = _fin_layout_size(plan.layout)
	return max(plan.Wp + W0 - plan.W, 1.0), max(plan.Hp + H0 - plan.H, 1.0)
end

# Whether a bar of ours sits where the first decoration of `side` goes for
# the CURRENT domain (`edge`; `own` px of axis labels; `pad` the paper pad of
# a vertical bar): its px offset from the edge matches within
# `_ROOM_ANCHOR_TOL` px plus `_ROOM_ANCHOR_SHARE` of that offset. This is the
# evidence that a shrunk side is ours; a domain the user moved leaves the bar
# off that spot (a vertical bar right of an area without right-side labels,
# offset 0, must match exactly).
function _room_bar_anchored(plan, item::_FinBar, side::Symbol, edge::Float64, own::Float64, pad::Float64)
	_fin_bar_owned(item.bar) || return false
	Wd, Hd = _room_design_px(plan)
	if side === :right
		depth = _room_label_px(own)
		at = (_cbar_real(item.bar, :x, NaN) - edge - pad) * Wd
	else
		depth = _room_label_px(own) + _ROOM_GAP + _fin_hbar_above(plan, item)
		at = (edge - _cbar_real(item.bar, :y, NaN)) * Hd
	end
	return abs(at - depth) <= _ROOM_ANCHOR_TOL + _ROOM_ANCHOR_SHARE * depth
end

function _room_requests!(plan::_RoomPlan, ::Val{:colorbar})
	by_area, order, _ = plan.bars
	layout = plan.layout
	for region_key in order
		area_key = _room_region_area(region_key)
		area_key === nothing && continue
		a = get(plan.areas, area_key, nothing)
		a === nothing && continue
		items = by_area[region_key]
		for side in (:right, :bottom)
			group = _FinBar[item for item in items if item.coloraxis === nothing &&
				!(item.index in plan.skip_bars) && _fin_bar_vertical(item.bar) == (side === :right) &&
				_room_bar_auto(item, side)]
			isempty(group) && continue
			# Host bars nearest the axes, then the bars of its insets.
			group = [filter(item -> !item.inset, group); filter(item -> item.inset, group)]
			# A lone bar left at plotly's default right of a plot area at the
			# paper edge stays there.
			keep_default = side === :right && length(group) == 1 && !group[1].inset &&
				_fin_bar_unplaced(group[1].bar) && a.current[1][2] >= 1 - 1e-9 && a.own[:right] == 0
			anchored = _room_bar_anchored(plan, group[1], side, _room_edge(a.current, side), a.own[side],
				_CBAR_CELL_PAD)
			span = _room_span(a.current[2])
			lead = keep_default ? 0.02 * plan.Wp : _CBAR_CELL_PAD * plan.Wp
			# Z49: the margin of a map's bar is reserved here (with plotly's
			# automargin extra), so plotly never grows it.
			reserve = occursin(_FIN_MARGIN_FIRST_SUBPLOT, String(area_key))
			for item in group
				key = _room_bar_key(item)
				plan.bar_items[key] = (item = item, side = side, keep_default = keep_default)
				px = side === :right ?
					_fin_bar_width(layout, item, plan.Hp; len_px = _room_bar_len(item.bar, span, span) * plan.Hp) +
					max(0.0, lead - _ROOM_GAP) :
					_fin_hbar_depth(plan, item)
				reserve && (px += _FIN_AUTOMARGIN_EXTRA)
				_request_room!(plan, area_key, side, px; owner = :colorbar, key = key, order = 10,
					anchored = anchored, margin_pushed = !reserve)
			end
		end
	end
	for region_key in order, item in by_area[region_key]
		item.coloraxis === nothing && continue
		entry = _room_coloraxis_entry(plan, item)
		entry === nothing && continue
		key = _room_bar_key(item)
		plan.bar_items[key] = entry
		# Our bar goes beyond the union of its areas: an area of the axis that
		# is not at the union's edge (it was, before more areas joined the
		# axis) needs no room for it, so its shrink on that side was ours.
		if _fin_bar_owned(item.bar)
			for k in entry.areas
				k in entry.edge_areas || push!(plan.vacated, (k, entry.side))
			end
		end
		for k in entry.edge_areas
			reserve = occursin(_FIN_MARGIN_FIRST_SUBPLOT, String(k))
			_request_room!(plan, k, entry.side, entry.px + (reserve ? _FIN_AUTOMARGIN_EXTRA : 0.0); owner = :colorbar,
				key = key, order = 10, anchored = entry.anchored, margin_pushed = !reserve)
		end
	end
	return nothing
end

# A coloraxis bar (`shared_colorbar!`, a shared axis placed per cell) that is
# ours to place: one bar next to the union of the areas using the axis,
# requesting room on the areas at that union's edge; `nothing` otherwise.
function _room_coloraxis_entry(plan::_RoomPlan, item::_FinBar)
	side = _fin_bar_vertical(item.bar) ? :right : :bottom
	regions, _ = _cbar_coloraxis_regions(plan.p, item.coloraxis, 1)
	isempty(regions) && return nothing
	unplaced = _fin_bar_unplaced(item.bar)
	(_fin_bar_owned(item.bar) || unplaced || _room_shared_matches(item.bar, regions, side)) || return nothing
	areas = Symbol[]
	for region in regions
		k = _room_region_area(region.key)
		(k === nothing || !haskey(plan.areas, k)) && return nothing
		push!(areas, k)
	end
	xdomain, ydomain = _cbar_union(regions)
	edge = side === :right ? xdomain[2] : ydomain[1]
	edge_areas = Symbol[k for k in areas if abs(_room_edge(plan.areas[k].current, side) - edge) <= 1e-9]
	isempty(edge_areas) && return nothing
	own = maximum(plan.areas[k].own[side] for k in edge_areas)
	# A lone unplaced bar at the paper edge stays at plotly's default.
	keep_default = unplaced && side === :right && edge >= 1 - 1e-9 && own == 0
	extent = side === :right ? ydomain[2] - ydomain[1] : xdomain[2] - xdomain[1]
	extent > 0 || return nothing
	ratio = clamp(_cbar_real(item.bar, :len, extent) / extent, 0.05, 1.0)
	pad = length(regions) == 1 ? _CBAR_CELL_PAD : _CBAR_SHARED_PAD
	anchored = _room_bar_anchored(plan, item, side, edge, own, pad)
	if side === :right
		# The bar keeps the pad it was placed with: a per-cell placement uses
		# the cell pad, `shared_colorbar!` the shared one.
		other = pad == _CBAR_CELL_PAD ? _CBAR_SHARED_PAD : _CBAR_CELL_PAD
		x = _cbar_real(item.bar, :x, nothing)
		if !anchored && _room_bar_anchored(plan, item, side, edge, own, other)
			pad = other
			anchored = true
		elseif !anchored && !_fin_bar_owned(item.bar) && x !== nothing && !isapprox(x, edge + pad; atol = 1e-9) &&
				isapprox(x, edge + other; atol = 1e-9)
			pad = other
		end
		keep_default && (pad = 0.02)
		px = _fin_bar_width(plan.layout, item, plan.Hp; len_px = ratio * extent * plan.Hp) +
			max(0.0, pad * plan.Wp - _ROOM_GAP)
	else
		px = _fin_hbar_depth(plan, item)
	end
	return (item = item, side = side, areas = areas, edge_areas = edge_areas, pad = pad, ratio = ratio, px = px,
		anchored = anchored, keep_default = keep_default)
end

# The placement of colorbar `key` after the solve, `nothing` to leave it
# (no slot, a frozen area, plotly's default kept).
function _room_colorbar_placement(plan::_RoomPlan, key::String, entry)
	entry.keep_default && return nothing
	slots = _room_slots(plan, :colorbar, key)
	isempty(slots) && return nothing
	any(slot -> slot.area !== :figure && plan.areas[slot.area].frozen, slots) && return nothing
	item = entry.item
	if item.coloraxis !== nothing
		finals = [plan.areas[k].final for k in entry.areas]
		x0 = minimum(f[1][1] for f in finals)
		x1 = maximum(f[1][2] for f in finals)
		y0 = minimum(f[2][1] for f in finals)
		y1 = maximum(f[2][2] for f in finals)
		release = any(slot -> slot.release, slots)
		if entry.side === :right
			x = maximum(slot.edge + (slot.offset - _ROOM_GAP) / plan.Wp for slot in slots) + entry.pad
			return Dict{Symbol, Any}(:x => x, :xanchor => "left", :xref => release ? nothing : "paper",
				:y => (y0 + y1) / 2, :yanchor => "middle",
				:len => max(entry.ratio * (y1 - y0), _room_min_bar_len(plan.font, item.bar, plan.Hp)), :lenmode => "fraction",
				:ypad => 0)
		end
		low = argmin(slot -> slot.edge - slot.offset / plan.Hp, slots)
		return _room_hbar_placement(plan, item, low.edge, low.offset, (x0 + x1) / 2, entry.ratio * (x1 - x0),
			release)
	end
	slot = first(slots)
	if slot.side === :right
		x = slot.edge + (slot.offset - _ROOM_GAP) / plan.Wp + _CBAR_CELL_PAD
		placement = Dict{Symbol, Any}(:x => x, :xanchor => "left", :xref => slot.release ? nothing : "paper",
			:lenmode => "fraction", :ypad => 0)
		if item.inset
			# Level with its inset.
			default = _cbar_placement(:right, item.own.xdomain, item.own.ydomain, _CBAR_CELL_PAD)
			placement[:y] = default[:y]
			placement[:yanchor] = default[:yanchor]
			placement[:len] = _room_bar_len(item.bar, default[:len], default[:len];
				floor = _room_min_bar_len(plan.font, item.bar, plan.Hp))
		else
			yd = slot.domain_y
			placement[:y] = (yd[1] + yd[2]) / 2
			placement[:yanchor] = "middle"
			placement[:len] = _room_bar_len(item.bar, _room_span(plan.areas[slot.area].current[2]), _room_span(yd);
				floor = _room_min_bar_len(plan.font, item.bar, plan.Hp))
		end
		return placement
	end
	xd = slot.domain_x
	len = _room_bar_len(item.bar, _room_span(plan.areas[slot.area].current[1]), _room_span(xd))
	return _room_hbar_placement(plan, item, slot.edge, slot.offset, (xd[1] + xd[2]) / 2, len, slot.release)
end

# A horizontal bar `offset` px below `edge` (paper), centred on `xc`: its
# box top, under a math title annotation drawn above it.
function _room_hbar_placement(plan::_RoomPlan, item::_FinBar, edge::Float64, offset::Float64, xc::Float64,
		len::Float64, release::Bool)
	return Dict{Symbol, Any}(
		:y => edge - (offset + _fin_hbar_above(plan, item)) / plan.Hp, :yanchor => "top",
		:yref => release ? nothing : "paper", :x => xc, :xanchor => "center", :len => len,
		:lenmode => "fraction", :xpad => 0, :ypad => 0,
	)
end

# Same position as now: leave the bar untouched (our mark is compared only
# when the placement releases the bar).
function _room_same_place(bar::AbstractDict, placement::AbstractDict)
	for (key, value) in placement
		key in (:xref, :yref) && value !== nothing && continue
		current = get(bar, key, nothing)
		same = value isa Real && current isa Real ? isapprox(Float64(current), Float64(value); atol = 1e-9) :
			isequal(current, value)
		same || return false
	end
	return true
end

# Areas of colorbars that would move but cannot be written in this pass
# (traces shared with the live figure on the append-only fast path) are
# frozen. Returns whether any area was newly frozen.
function _room_freeze!(plan::_RoomPlan)
	changed = false
	for (key, entry) in plan.bar_items
		_fin_item_writable(plan.ctx, entry.item) && continue
		placement = _room_colorbar_placement(plan, key, entry)
		(placement === nothing || _room_same_place(entry.item.bar, placement)) && continue
		for slot in _room_slots(plan, :colorbar, key)
			slot.area === :figure && continue
			a = plan.areas[slot.area]
			a.frozen && continue
			a.frozen = true
			changed = true
		end
	end
	return changed
end

function _room_place!(plan::_RoomPlan, ::Val{:colorbar})
	for (key, entry) in plan.bar_items
		item = entry.item
		_fin_item_writable(plan.ctx, item) || continue
		placement = _room_colorbar_placement(plan, key, entry)
		placement === nothing && continue
		_room_same_place(item.bar, placement) && !_room_needs_mark(plan, key, item, placement) && continue
		plan.wrote |= _fin_place_bar!(plan.ctx, plan.updates, item, placement)
		push!(plan.moved, (item, placement))
		mark = entry.side === :right ? :xref : :yref
		item.coloraxis === nothing && get(placement, mark, nothing) === nothing && push!(plan.ctx.released, item.index)
	end
	return nothing
end

# A bar already where it goes, next to a side of a grid cell that is shrunk
# for it, gets our ownership mark: it is the evidence later passes need to
# keep (or undo) that shrink (`_room_evidence`). Bars of unshrunk cells are
# left without it.
function _room_needs_mark(plan::_RoomPlan, key::String, item::_FinBar, placement::AbstractDict)
	mark = haskey(placement, :yref) ? :yref : :xref
	get(placement, mark, nothing) == "paper" || return false
	_cbar_string(item.bar, mark, "") == "paper" && return false
	for slot in _room_slots(plan, :colorbar, key)
		slot.area === :figure && continue
		a = plan.areas[slot.area]
		a.ref === nothing && continue
		abs(_room_edge(a.final, slot.side) - _room_edge(a.ref, slot.side)) > 1e-9 && return true
	end
	return false
end

# ---------------------------------------------------------------------------
# Grid titles (Z20): `subplots(...; x_title, y_title)` draws them as paper
# annotations named `plotlysupply:grid_title:x` (below the bottom row) and
# `plotlysupply:grid_title:y` (left of the left column, rotated -90 deg).
# Each takes a `:figure` request on its side, nearest the axes: it is placed
# past the outermost axis labels on that paper edge, and the margin grows to
# hold it (annotations do not push plotly's automargin).
# ---------------------------------------------------------------------------

const _FIN_GRID_TITLE_PREFIX = "plotlysupply:grid_title:"

# "x" / "y" for a grid title annotation, else `nothing`.
function _fin_grid_title_letter(item)
	name = _cmn_mapping_get(item, :name)
	(name isa AbstractString && startswith(name, _FIN_GRID_TITLE_PREFIX)) || return nothing
	letter = name[(ncodeunits(_FIN_GRID_TITLE_PREFIX) + 1):end]
	return letter in ("x", "y") ? letter : nothing
end

function _room_requests!(plan, ::Val{:grid_titles})
	annotations = get(plan.layout.fields, :annotations, nothing)
	annotations isa AbstractVector || return nothing
	for item in annotations
		letter = _fin_grid_title_letter(item)
		letter === nothing && continue
		_cmn_mapping_get(item, :visible) === false && continue
		text = _cmn_mapping_get(item, :text)
		(text isa AbstractString && !isempty(text)) || continue
		px = _room_text_height(text, _fin_mapping_font_size(item, :font, plan.font))
		_request_room!(plan, :figure, letter == "x" ? :bottom : :left, px;
			owner = :grid_titles, key = letter, order = 5)
	end
	return nothing
end

function _room_place!(plan, ::Val{:grid_titles})
	any(r -> r.owner === :grid_titles, plan.requests) || return nothing
	annotations = _room_annotations!(plan)
	for (i, item) in enumerate(annotations)
		letter = _fin_grid_title_letter(item)
		letter === nothing && continue
		slot = _room_slot(plan, :grid_titles, letter)
		slot === nothing && continue
		fields = _symbol_dict(item)
		shift = -round(slot.offset; digits = 2)
		if letter == "x"
			fields[:y] = slot.edge
			fields[:yref] = "paper"
			fields[:yanchor] = "top"
			fields[:yshift] = shift
		else
			fields[:x] = slot.edge
			fields[:xref] = "paper"
			fields[:xanchor] = "right"
			fields[:xshift] = shift
		end
		isequal(_symbol_dict(item), fields) || (annotations[i] = _cbar_attr(fields))
	end
	return nothing
end

# The layout annotations (`base`, else the layout's) with the math title of
# every moved bar redrawn for its new placement; `base` (`nothing` included)
# when no title annotation changes.
function _fin_title_annotations(p::Plot, moved, base = nothing)
	isempty(moved) && return base
	existing = base === nothing ? get(p.layout.fields, :annotations, nothing) : base
	existing isa AbstractVector || return base
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
	return changed ? result : base
end

const _FIN_PANEL_TITLE_NAME = r"^plotlysupply:title!?:(\d+):(\d+)(:.*)?$"

# `annotations` (the layout's when `nothing`) with every panel title
# (`title!(fig, text; row, col)`) of a cell whose x domain `layout_updates`
# changes moved with the domain: a title at the old domain's left edge,
# centre or right edge (by its `xanchor`) goes to the new one; a title the
# user moved elsewhere stays. `annotations` unchanged (`nothing` included)
# when no title moves.
function _fin_follow_panel_titles(layout::Layout, layout_updates::Dict{Symbol, Any}, annotations)
	changes = Dict{Symbol, Tuple{NTuple{2, Float64}, NTuple{2, Float64}}}()
	for (key, value) in layout_updates
		m = match(r"^(xaxis\d*)_domain$", String(key))
		m === nothing && continue
		(value isa AbstractVector && length(value) == 2 && all(_fin_isfinite_real, value)) || continue
		xkey = Symbol(m.captures[1])
		old = something(_layout_axis_domain(layout, xkey), (0.0, 1.0))
		changes[xkey] = (old, (Float64(value[1]), Float64(value[2])))
	end
	isempty(changes) && return annotations
	items = annotations === nothing ? get(layout.fields, :annotations, nothing) : annotations
	(items isa AbstractVector && !isempty(items)) || return annotations
	grid_ref = layout.subplots.grid_ref
	result = collect(Any, items)
	changed = false
	for (i, item) in enumerate(result)
		name = _cmn_item_name(item)
		name isa AbstractString || continue
		m = match(_FIN_PANEL_TITLE_NAME, name)
		m === nothing && continue
		row = parse(Int, m.captures[1])
		col = parse(Int, m.captures[2])
		(checkbounds(Bool, grid_ref, row, col) && isassigned(grid_ref, row, col) &&
			!isempty(grid_ref[row, col])) || continue
		xkey = _fin_axis_key(_fin_string(get(first(grid_ref[row, col]).trace_kwargs.fields, :xaxis, nothing)))
		(xkey === nothing || !haskey(changes, xkey)) && continue
		old, new = changes[xkey]
		_fin_string(_cmn_mapping_get(item, :xref, "paper")) == "paper" || continue
		x = _cmn_mapping_get(item, :x)
		_fin_isfinite_real(x) || continue
		anchor = something(_fin_string(_cmn_mapping_get(item, :xanchor, "auto")), "auto")
		at(d) = anchor == "left" ? d[1] : anchor == "right" ? d[2] : (d[1] + d[2]) / 2
		isapprox(Float64(x), at(old); atol = 1e-9) || continue
		isapprox(at(new), at(old); atol = 1e-12) && continue
		moved = _symbol_dict(item)
		moved[:x] = at(new)
		result[i] = _cbar_attr(moved)
		changed = true
	end
	return changed ? result : annotations
end

# Right margin (px) that fits every right-side math colorbar title, or
# `nothing` when there is none. The title is a -90 deg annotation `xshift` px
# right of its paper `x`, `_FIN_MATH_TITLE_EM` font sizes wide.
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
		edge = (Float64(x) - 1) * Wp + Float64(shift) + _FIN_MATH_TITLE_EM * size + 4
		needed = max(something(needed, 0.0), ceil(edge))
	end
	(needed === nothing || needed <= 0) && return nothing
	return needed
end

"""
	_finalize_figure!(fig; live = nothing, size = nothing) -> Bool

Normalise the figure after a PlotlySupply constructor or mutator changed it
(decision D10); returns whether anything was written.

- M1: every root axis of a shared-axis (`matches`) group without an
  `autorange` entry gets one: `true`, or `false` when it has a range
  (plotly.js 2.35 otherwise collapses a group, or carries one group's fixed
  range over to the next, Y37).
- M2: axes that carry a field trace (`_fin_field_kind`) and autorange get the
  sticky clip (`_fin_sticky_clip`), or are pinned to it on an equal-aspect
  cell (`autorange = false`; a reversed axis gets a descending `range`); data
  of other traces beyond the field widens it by `_FIN_OVERLAY_PAD` of the
  span on that side; see `_fin_sticky_updates!`.
- M3: equal-aspect cells are fitted into their grid cell (inset, or paper),
  less the room their other decorations take (D12), their x axis shrinks
  toward its colorbar (`constraintoward = "right"`), and their colorbars are
  placed against the fitted plot area with the same height. A single figure
  without a width or height is sized to the field; the plot box, its y tick
  labels and its colorbars of a single figure are centred.
- M4/D12 (room reservation, `_room_build`): every decoration placed next to
  a plot area (colorbars here; legends, titles and labels through the
  `_room_requests!`/`_room_place!` providers of their owners) gets its own
  room: the plot area's grid cell gives up what the gap to its neighbour
  cannot hold (cells sharing that grid edge alike, at most half the cell),
  and at the paper edge the margin takes it. Colorbars of a plot area go
  side by side right of its tick labels (vertical) or below its x tick
  labels and title (horizontal); the bar of a trace in an inset goes right
  of the host cell, level with the inset; a coloraxis bar goes next to all
  of its plot areas. A shrunk side widens again when its decorations go.
  Only a domain inside its grid cell is changed, and a shrunk one only with
  evidence that the shrink is ours (D12). A coloraxis bar placed before the
  mutation bound existing traces to it moves next to all of its plot areas.
  The right margin grows to fit a math colorbar title drawn beside its bar.
  The fit and the room solve run again after a pass that wrote (at most
  `_FIN_FIT_ROUNDS`), so a second call writes nothing.
- M5: the 3-D scenes PlotlySupply manages are framed for the final domains
  and margins, at `size` when given (`_s3_finalize_scenes!`: camera
  distance, tick counts and tick font sizes).

Explicit user settings (ranges, `autorangeoptions`, domains outside the cell,
placed colorbars) are never changed. `live` holds the traces of the live
figure: those are not written (the append-only fast path shares them), and a
cell whose colorbar would need such a write is left as it is. `size` is the
export size (px) to fit for.
"""
function _finalize_figure!(fig; live = nothing, size = nothing)
	return _fin_run!(fig, live, size, false)
end

# Colour ranges are scanned once per run (Z83, `_cbar_with_extrema_memo`).
_fin_run!(fig, live, size, clone_readonly::Bool) =
	_cbar_with_extrema_memo(() -> _fin_run_scoped!(fig, live, size, clone_readonly))

function _fin_run_scoped!(fig, live, size, clone_readonly::Bool)
	ctx = _fin_context(fig, live, size, clone_readonly)
	p = ctx.p
	updates = _fin_match_group_updates(p.layout, p.data)
	# One collection for the run (Z81): no write of the run changes an extent
	# (see `_FinAxes`).
	accs = _fin_collect_axes(p)
	_fin_sticky_updates!(updates, p, accs)
	# Log-axis tick labels and long axis titles at this figure size
	# (W7/Z70/W5, src/sci/axes.jl).
	_axes_finalize_updates!(updates, p, _fin_figure_size(ctx, p.layout), accs)
	wrote = _fin_relayout!(ctx, updates)
	# The fit and the room solve read what they write (a bar's length changes
	# its tick-label estimate, fitted domains the margins): a pass that wrote
	# runs again, so that the next `_finalize_figure!` writes nothing.
	for _ in 1:_FIN_FIT_ROUNDS
		_fin_fit!(ctx, accs) || break
		wrote = true
	end
	# M5: 3-D scenes are framed for the final domains and margins, at the
	# export size when there is one (scene3d.jl; layout writes only).
	_s3_finalize_scenes!(p, ctx.size) && (wrote = true)
	return wrote
end

# Passes of `_fin_fit!` per finalize run; a figure converges in two or three.
const _FIN_FIT_ROUNDS = 4

# The `_FinContext` of a finalize run (see `_fin_run!`).
function _fin_context(fig, live, size, clone_readonly::Bool)
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
	sf = fig isa SubplotFigure ? fig : nothing
	insets = _fin_insets(p, sf)
	hosts = Set{Symbol}()
	for inset in insets
		host = _fin_inset_host_region(p, inset)
		host === nothing || push!(hosts, _fin_axis_key(host.key))
	end
	return _FinContext(target, p, sf, readonly, clone_readonly, checked_size,
		live === nothing ? nothing : collect(Any, live), insets, hosts, Ref{Any}(nothing), Set{Int}())
end

"""
	_finalize_export_copy(p::Plot, options; pan = true) -> Plot

The figure `savefig` renders: `p` itself when `_finalize_figure!` has nothing
to change for the export size `options.width` x `options.height`, otherwise a
copy (private layout; traces shared except those it writes, which are cloned)
re-fitted for that size, its 3-D scene cameras and tick counts included
(`_s3_refit_scenes!`; `pan = false` keeps every camera centre, for HTML/JSON
documents whose rotation pivot is the centre, Z43). `p` is never mutated.
"""
function _finalize_export_copy(p::Plot, options; pan::Bool = true)
	copy_plot = Plot(copy(p.data), deepcopy(p.layout), p.frames; config = p.config)
	size = (options.width, options.height)
	wrote = _fin_run!(copy_plot, p.data, size, true)
	wrote |= _s3_refit_scenes!(copy_plot, p, size; pan = pan)
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
