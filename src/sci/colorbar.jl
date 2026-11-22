# PlotlySupply 2.0 scientific-plotting extensions: per-cell colorbar placement, colorbar!, shared_colorbar!.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_COLORBAR_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# `colorbar!` and `shared_colorbar!` rewrite EXISTING traces. The registry's
# append-only fast path shares existing trace roots with the live figure, so
# neither is registered: their Plot/SyncPlot methods run
# `_transactional_high_level_plot_mutation!` with unregistered implementations
# (always fully staged, one renderer transaction) and their SubplotFigure
# methods run `_transactional_subplot_mutation!`.

const _SCI_COLORBAR_MUTATORS = ()

export colorbar!, shared_colorbar!

# ── Geometry constants ──────────────────────────────────────────────────────

# Gap between a cell's plot area and its colorbar, in paper fractions (spec F5).
const _CBAR_CELL_PAD = 0.01
# Gap between the right-most cell and a bar shared by several cells (spec F7).
const _CBAR_SHARED_PAD = 0.02
# Distance below the cell where a `side = :bottom` bar starts, in paper
# fractions (spec F6). It is the initial placement only, and marks the bar
# as placed by this package: `_finalize_figure!` moves such a bar below the
# x tick labels and axis title it measures, into room it reserves (D12).
const _CBAR_BOTTOM_OFFSET = 0.12
# Thickness of the bars PlotlySupply places, in px (spec F5); plotly's 30 px
# default is out of proportion next to a subplot cell.
const _CBAR_CELL_THICKNESS = 12
# plotly.js 2.35 colorbar defaults, needed to put a title annotation next to
# a bar whose geometry was not written explicitly.
const _CBAR_DEFAULT_THICKNESS = 30.0
const _CBAR_DEFAULT_XPAD = 10.0
const _CBAR_DEFAULT_FONT_SIZE = 12.0
# Average advance of a tick-label glyph as a multiple of the font size
# (proportional sans-serif digits); only used to estimate how far a
# `title_side = :right` annotation must sit from the bar.
const _CBAR_CHAR_EM = 0.6
# Height of one line of tick labels as a multiple of the font size.
const _CBAR_LINE_EM = 1.4

const _CBAR_SIDES = (:right, :bottom)
const _CBAR_TITLE_SIDES = (:top, :right, :bottom)
# plotly.js `colorbar.exponentformat` values.
const _CBAR_EXPONENT_FORMATS = ("none", "e", "E", "power", "SI", "B")
# `colorbar!(...; offset)` values (Z56).
const _CBAR_OFFSETS = (:auto, :always, :none)
# `offset = :auto`: plotly.js takes a common 10^k out of the tick labels when
# |k| > `minexponent` (axes.js autoTickRound, k = floor(log10 of the largest
# |range end|)); 4 gives k <= -5 or k >= 5, close to matplotlib's
# ScalarFormatter (k <= -5 or k >= 6, `_AXES_OFFSET_LIMITS`).
const _CBAR_OFFSET_MIN_EXPONENT = 4
# Owner prefix of the annotations that carry math colorbar titles.
const _CBAR_TITLE_ANNOTATION_PREFIX = "plotlysupply:colorbar_title:"

# Trace types whose colour scale and colorbar live on the trace itself
# (`trace.colorbar`, `trace.showscale`, `trace.coloraxis`). Other traces carry
# them on `marker` (scatter, bar, carrier traces, …) or `line` (parcoords).
const _CBAR_ROOT_TRACE_TYPES = (
	"heatmap",
	"contour",
	"contourcarpet",
	"histogram2d",
	"histogram2dcontour",
	"surface",
	"mesh3d",
	"cone",
	"streamtube",
	"volume",
	"isosurface",
	"choropleth",
	"choroplethmapbox",
	"choroplethmap",
	"densitymapbox",
	"densitymap",
)
const _CBAR_CONTOUR_TYPES = ("contour", "contourcarpet", "histogram2dcontour")

# The placement keys `_finalize_figure!` writes on a bar it owns.
const _CBAR_FINALIZE_KEYS = (:x, :y, :xanchor, :yanchor, :xref, :yref, :xpad, :ypad, :len, :lenmode)

# Colorbar keys that position a bar. `shared_colorbar!` carries the other
# settings (ticks, number format, thickness, …) of the bars it removes over
# to the shared bar, never these.
const _CBAR_GEOMETRY_KEYS = (
	:x, :y, :xanchor, :yanchor, :xref, :yref, :xpad, :ypad,
	:len, :lenmode, :orientation,
)

# Set while the SubplotFigure delegate runs a mutator on its scratch figure.
# Math colorbar titles are then left on the traces and converted by
# `_place_cell_colorbars!` once the bars sit next to their target cell.
const _CBAR_DEFER_MATH_TITLES = Base.ScopedValues.ScopedValue(false)

# ── Small mapping helpers ───────────────────────────────────────────────────

_cbar_attr(fields::Dict{Symbol,Any}) = PlotlyBase.PlotlyAttribute(fields)

# Make the mapping stored under `key` in `container` (layout or coloraxis
# fields) equal `fields`. An existing Dict/IdDict/PlotlyAttribute there that
# can hold them (Symbol keys only, values of any type) is updated in place,
# like the layout mutators do: the transactions run on a staged clone of the
# layout, so another reference to that object inside the layout (e.g. under
# `meta`) keeps pointing at the committed value. Anything else is replaced by
# a new attribute wrapping `fields`.
function _cbar_store_mapping!(
	container::AbstractDict,
	key::Symbol,
	fields::Dict{Symbol,Any},
)
	target = _builtin_layout_mapping_fields(get(container, key, nothing))
	if target !== nothing && target !== fields && Symbol <: keytype(target) &&
			valtype(target) === Any && all(name -> name isa Symbol, keys(target))
		for name in collect(keys(target))
			haskey(fields, name) || delete!(target, name)
		end
		merge!(target, fields)
		return nothing
	end
	container[key] = _cbar_attr(fields)
	return nothing
end

# Write colorbar `bar` into coloraxis `id` (whose current fields, shallow
# copied, are `axis`), both in place where possible (`_cbar_store_mapping!`).
function _cbar_store_coloraxis!(
	p::Plot,
	id::AbstractString,
	axis::Dict{Symbol,Any},
	bar::Dict{Symbol,Any},
)
	_cbar_store_mapping!(axis, :colorbar, bar)
	_cbar_store_mapping!(p.layout.fields, Symbol(id), axis)
	return nothing
end

function _cbar_string(fields::AbstractDict, key::Symbol, default::String)
	value = get(fields, key, nothing)
	(value isa AbstractString || value isa Symbol) || return default
	return String(value)
end

function _cbar_real(fields::AbstractDict, key::Symbol, default)
	value = get(fields, key, nothing)
	(value isa Real && !(value isa Bool) && isfinite(value)) || return default
	return Float64(value)
end

_cbar_trace_type(trace::GenericTrace) = string(get(trace.fields, :type, "scatter"))

function _cbar_coloraxis_ref(value)
	(value isa AbstractString || value isa Symbol) || return nothing
	id = String(value)
	return occursin(_COLORAXIS_ID_REGEX, id) ? id : nothing
end

# Whether `values` (possibly nested) holds at least one finite number, i.e.
# is mapped through a colour scale rather than listing colours.
function _cbar_has_numbers(values)
	values isa AbstractArray || return false
	for value in values
		value isa AbstractArray && _cbar_has_numbers(value) && return true
		(value isa Real && !(value isa Bool) && isfinite(value)) && return true
	end
	return false
end

function _cbar_real_extrema(values)
	lo = Inf
	hi = -Inf
	for value in values
		value isa Bool && continue
		isfinite(value) || continue
		v = Float64(value)
		v < lo && (lo = v)
		v > hi && (hi = v)
	end
	return isfinite(lo) ? (lo, hi) : nothing
end

# Floating-point colour data (Z83): Base's vectorized `extrema` (about 1 ms
# for 4e6 values, against 7-9 ms for a filtering loop) is the answer when
# both ends are finite, as NaN propagates through it and ±Inf would be an
# end; otherwise one branch-free pass skips NaN and ±Inf as above. A permuted
# array (an image's lazy C x W x H `z`) has the extrema of its parent.
function _cbar_real_extrema(values::AbstractArray{T}) where {T <: Base.IEEEFloat}
	isempty(values) && return nothing
	lo, hi = extrema(values)
	isfinite(lo) && isfinite(hi) && return (Float64(lo), Float64(hi))
	lo = T(Inf)
	hi = T(-Inf)
	@inbounds @simd for i in eachindex(values)
		x = values[i]
		finite = isfinite(x)
		lo = min(lo, ifelse(finite, x, T(Inf)))
		hi = max(hi, ifelse(finite, x, T(-Inf)))
	end
	return isfinite(lo) ? (Float64(lo), Float64(hi)) : nothing
end
_cbar_real_extrema(values::PermutedDimsArray{T}) where {T <: Base.IEEEFloat} =
	_cbar_real_extrema(parent(values))

# Z83: within one call (a colorbar mutation, a `_finalize_figure!` run) each
# colour array is scanned once: `_cbar_extrema` keeps its results by array
# identity while `_CBAR_EXTREMA_MEMO` holds a dictionary. Nothing in such a
# call changes colour data in place (new data comes as new arrays), and the
# memo ends with the call, so it cannot go stale.
const _CBAR_EXTREMA_MEMO = Base.ScopedValues.ScopedValue{Union{Nothing, IdDict{Any, Any}}}(nothing)

function _cbar_with_extrema_memo(f)
	_CBAR_EXTREMA_MEMO[] === nothing || return f()
	return Base.ScopedValues.with(f, _CBAR_EXTREMA_MEMO => IdDict{Any, Any}())
end

# Finite (min, max) of possibly nested colour data (matrices, vectors of rows,
# `nothing` gaps); `nothing` when there is no finite number.
function _cbar_extrema(values)
	values isa AbstractArray || return _cbar_extrema_scan(values)
	memo = _CBAR_EXTREMA_MEMO[]
	memo === nothing && return _cbar_extrema_scan(values)
	return get!(() -> _cbar_extrema_scan(values), memo, values)
end

function _cbar_extrema_scan(values)
	values isa AbstractArray{<:Real} && return _cbar_real_extrema(values)
	values isa Real && return _cbar_real_extrema((values,))
	(values isa AbstractArray || values isa Tuple || values isa Base.Generator) ||
		return nothing
	result = nothing
	for item in values
		part = _cbar_extrema(item)
		part === nothing && continue
		result = result === nothing ? part :
			(min(result[1], part[1]), max(result[2], part[2]))
	end
	return result
end

# ── Coloured traces ─────────────────────────────────────────────────────────

# Where one trace keeps its colour scale: `container` is `:root`, `:marker` or
# `:line`; `coloraxis` the shared axis it is bound to (or `nothing`); `shows`
# whether it draws a colorbar of its own.
struct _CbarSlot
	index::Int
	container::Symbol
	coloraxis::Union{Nothing,String}
	shows::Bool
end

function _cbar_slot(trace, index::Int)
	trace isa GenericTrace || return nothing
	fields = trace.fields
	type_name = _cbar_trace_type(trace)
	if type_name in _CBAR_ROOT_TRACE_TYPES
		# A mesh3d without `intensity` is drawn in one flat colour.
		type_name == "mesh3d" && !haskey(fields, :intensity) && return nothing
		# Contours with `coloring = "none"` are drawn in `line.color`; plotly
		# gives them no colour scale and no colorbar.
		if type_name in _CBAR_CONTOUR_TYPES
			coloring = _cmn_mapping_get(get(fields, :contours, nothing), :coloring)
			(coloring isa AbstractString || coloring isa Symbol) &&
				String(coloring) == "none" && return nothing
		end
		axis = _cbar_coloraxis_ref(get(fields, :coloraxis, nothing))
		shows = axis === nothing && get(fields, :showscale, true) !== false
		return _CbarSlot(index, :root, axis, shows)
	end
	for container in (:marker, :line)
		mapping = get(fields, container, nothing)
		_is_layout_mapping(mapping) || continue
		axis = _cbar_coloraxis_ref(_cmn_mapping_get(mapping, :coloraxis))
		(axis !== nothing || _cbar_has_numbers(_cmn_mapping_get(mapping, :color))) ||
			continue
		shows = axis === nothing && _cmn_mapping_get(mapping, :showscale) === true
		return _CbarSlot(index, container, axis, shows)
	end
	return nothing
end

function _cbar_slot_bar(trace::GenericTrace, slot::_CbarSlot)
	slot.container === :root && return get(trace.fields, :colorbar, nothing)
	return _cmn_mapping_get(get(trace.fields, slot.container, nothing), :colorbar)
end

# Store `bar` as the slot's colorbar. Containers are replaced, never mutated:
# a nested `marker` may be shared with the caller's input.
function _cbar_set_slot_bar!(trace::GenericTrace, slot::_CbarSlot, bar::Dict{Symbol,Any})
	fields = trace.fields
	if slot.container === :root
		fields[:colorbar] = _cbar_attr(bar)
	else
		container = _symbol_dict(get(fields, slot.container, nothing))
		container[:colorbar] = _cbar_attr(bar)
		fields[slot.container] = _cbar_attr(container)
	end
	return nothing
end

# The colour data plotly maps through the slot's scale, or `nothing` when it
# is computed by plotly (histogram2d counts, streamtube magnitudes, a
# densitymap without `z`).
function _cbar_slot_values(trace::GenericTrace, slot::_CbarSlot)
	fields = trace.fields
	if slot.container === :root
		type_name = _cbar_trace_type(trace)
		type_name in ("histogram2d", "histogram2dcontour", "streamtube") && return nothing
		if type_name == "surface"
			haskey(fields, :surfacecolor) && return fields[:surfacecolor]
			return get(fields, :z, nothing)
		elseif type_name == "mesh3d"
			return get(fields, :intensity, nothing)
		elseif type_name in ("volume", "isosurface")
			return get(fields, :value, nothing)
		elseif type_name == "cone"
			# Cones are coloured by the vector norm.
			u = get(fields, :u, nothing)
			v = get(fields, :v, nothing)
			w = get(fields, :w, nothing)
			(u isa AbstractArray && v isa AbstractArray && w isa AbstractArray) ||
				return nothing
			return [
				sqrt(Float64(a)^2 + Float64(b)^2 + Float64(c)^2)
				for (a, b, c) in zip(u, v, w)
				if a isa Real && b isa Real && c isa Real
			]
		end
		return get(fields, :z, nothing)
	end
	return _cmn_mapping_get(get(fields, slot.container, nothing), :color)
end

# Colour range of a slot for layout estimates: explicit limits first, else
# the data extrema.
function _cbar_slot_range(trace::GenericTrace, slot::_CbarSlot)
	source = slot.container === :root ?
		trace.fields :
		_symbol_dict(get(trace.fields, slot.container, nothing))
	for (lo_key, hi_key) in ((:zmin, :zmax), (:cmin, :cmax))
		lo = _cbar_real(source, lo_key, nothing)
		hi = _cbar_real(source, hi_key, nothing)
		(lo !== nothing && hi !== nothing) && return (lo, hi)
	end
	values = _cbar_slot_values(trace, slot)
	return values === nothing ? nothing : _cbar_extrema(values)
end

function _cbar_trace_kind(trace::GenericTrace)
	try
		return first(_trace_subplot_kind(trace))
	catch err
		err isa ArgumentError || rethrow()
		return nothing
	end
end

# The plot area a trace draws in: `key` names it ("x3" for Cartesian axes —
# every grid cell and inset has its own x axis —, "scene2", "polar", …) and
# `xdomain`/`ydomain` are its paper fractions.
function _cbar_trace_region(p::Plot, trace::GenericTrace)
	fields = trace.fields
	layout = p.layout
	kind = _cbar_trace_kind(trace)
	if kind == "xy"
		xref = string(get(fields, :xaxis, "x"))
		yref = string(get(fields, :yaxis, "y"))
		xdomain = something(
			_layout_axis_domain(layout, _axis_layout_key(xref, :x)),
			(0.0, 1.0),
		)
		ydomain = _cmn_y_axis_domain(layout, _axis_layout_key(yref, :y))
		return (key = xref, xdomain = xdomain, ydomain = ydomain)
	elseif kind == "domain"
		domain = get(fields, :domain, nothing)
		xdomain = something(_domain_tuple(_cmn_mapping_get(domain, :x)), (0.0, 1.0))
		ydomain = something(_domain_tuple(_cmn_mapping_get(domain, :y)), (0.0, 1.0))
		key = "domain:$(xdomain[1]),$(xdomain[2])|$(ydomain[1]),$(ydomain[2])"
		return (key = key, xdomain = xdomain, ydomain = ydomain)
	elseif kind !== nothing
		ref_key = kind == "scene" ? :scene : kind == "geo" ? :geo : :subplot
		ref = string(get(fields, ref_key, kind))
		domain = _layout_subplot_domain(layout, Symbol(ref))
		domain === nothing &&
			return (key = ref, xdomain = (0.0, 1.0), ydomain = (0.0, 1.0))
		return (key = ref, xdomain = domain[1], ydomain = domain[2])
	end
	return (key = "paper", xdomain = (0.0, 1.0), ydomain = (0.0, 1.0))
end

function _cbar_union(regions)
	x0 = minimum(region.xdomain[1] for region in regions)
	x1 = maximum(region.xdomain[2] for region in regions)
	y0 = minimum(region.ydomain[1] for region in regions)
	y1 = maximum(region.ydomain[2] for region in regions)
	return ((x0, x1), (y0, y1))
end

function _cbar_push_region!(regions::Vector{Any}, region)
	any(existing -> existing.key == region.key, regions) || push!(regions, region)
	return regions
end

# Regions of all traces bound to coloraxis `id`, and of those bound before
# `start_index`.
function _cbar_coloraxis_regions(p::Plot, id::String, start_index::Int)
	all_regions = Any[]
	old_regions = Any[]
	for index in eachindex(p.data)
		trace = p.data[index]
		slot = _cbar_slot(trace, index)
		(slot === nothing || slot.coloraxis != id) && continue
		region = _cbar_trace_region(p, trace)
		_cbar_push_region!(all_regions, region)
		index < start_index && _cbar_push_region!(old_regions, region)
	end
	return all_regions, old_regions
end

# The trace references of a SubplotFigure cell (primary and secondary axes).
function _cbar_cell_refs(p::Plot, row::Int, col::Int, who::AbstractString)
	grid_ref = p.layout.subplots.grid_ref
	(checkbounds(Bool, grid_ref, row, col) &&
		isassigned(grid_ref, row, col) &&
		!isempty(grid_ref[row, col])) || throw(ArgumentError(
		"$(who): subplot cell ($(row), $(col)) is empty.",
	))
	return grid_ref[row, col]
end

function _cbar_ref_default(key::Symbol, kind::String)
	key === :xaxis && return "x"
	key === :yaxis && return "y"
	key === :scene && return "scene"
	key === :geo && return "geo"
	key === :subplot && return kind
	return nothing
end

# Indices of the traces drawn in the SubplotFigure cells `cells` ((row, col)
# pairs): traces routed to a cell's primary or secondary axes or scene/polar/…
# reference, and traces in the insets registered for the cell.
function _cbar_cell_trace_indices(sf::SubplotFigure, p::Plot, cells, who::AbstractString)
	cell_refs = Any[_cbar_cell_refs(p, r, c, who) for (r, c) in cells]
	insets = [
		inset for inset in getfield(sf, :insets)
		if any(cell -> cell == (inset.row, inset.col), cells)
	]
	indices = Int[]
	for index in eachindex(p.data)
		trace = p.data[index]
		trace isa GenericTrace || continue
		inside = any(refs -> _cbar_trace_in_refs(trace, refs), cell_refs)
		if !inside && !isempty(insets) && _cbar_trace_kind(trace) == "xy"
			xref = string(get(trace.fields, :xaxis, "x"))
			yref = string(get(trace.fields, :yaxis, "y"))
			inside = any(inset -> inset.xref == xref && inset.yref == yref, insets)
		end
		inside && push!(indices, index)
	end
	return indices
end

# Whether `trace` is routed to one of the subplot references `refs`.
function _cbar_trace_in_refs(trace::GenericTrace, refs)
	fields = trace.fields
	kind = _cbar_trace_kind(trace)
	for ref in refs
		ref_kind = String(ref.subplot_kind)
		kind == ref_kind || continue
		matched = true
		for (key, value) in ref.trace_kwargs.fields
			if key === :domain
				domain = get(fields, :domain, nothing)
				matched =
					_domain_tuple(_cmn_mapping_get(domain, :x)) ==
					_domain_tuple(_cmn_mapping_get(value, :x)) &&
					_domain_tuple(_cmn_mapping_get(domain, :y)) ==
					_domain_tuple(_cmn_mapping_get(value, :y))
			else
				actual = get(fields, key, _cbar_ref_default(key, ref_kind))
				matched =
					(actual isa AbstractString || actual isa Symbol) &&
					(value isa AbstractString || value isa Symbol) &&
					String(actual) == String(value)
			end
			matched || break
		end
		matched && return true
	end
	return false
end

# ── Placement ───────────────────────────────────────────────────────────────

# Colorbar geometry next to a plot area: `:right` is a vertical bar left-
# anchored `pad` to the right of the area, as tall as the area; `:bottom` a
# horizontal bar centred below it, as wide as the area. The padding along the
# bar is 0 (plotly's default 10 px at each end would make the coloured bar
# 20 px shorter than the plot area it labels).
function _cbar_placement(side::Symbol, xdomain, ydomain, pad::Float64)
	if side === :right
		return Dict{Symbol,Any}(
			:orientation => "v",
			:x => xdomain[2] + pad,
			:xanchor => "left",
			:y => (ydomain[1] + ydomain[2]) / 2,
			:yanchor => "middle",
			:len => ydomain[2] - ydomain[1],
			:lenmode => "fraction",
			:ypad => 0,
		)
	end
	return Dict{Symbol,Any}(
		:orientation => "h",
		:x => (xdomain[1] + xdomain[2]) / 2,
		:xanchor => "center",
		:y => ydomain[1] - _CBAR_BOTTOM_OFFSET,
		:yanchor => "top",
		:len => xdomain[2] - xdomain[1],
		:lenmode => "fraction",
		:xpad => 0,
	)
end

function _cbar_region_placement(side::Symbol, regions)
	xdomain, ydomain = _cbar_union(regions)
	pad = length(regions) == 1 ? _CBAR_CELL_PAD : _CBAR_SHARED_PAD
	return _cbar_placement(side, xdomain, ydomain, pad)
end

# Whether `bar` sits at `placement` (`len = false`: at any length).
function _cbar_placement_matches(bar::AbstractDict, placement::AbstractDict; len::Bool = true)
	for key in (len ? (:x, :y, :len) : (:x, :y))
		value = _cbar_real(bar, key, nothing)
		(value !== nothing && isapprox(value, placement[key]; atol = 1e-9)) ||
			return false
	end
	for key in (:xanchor, :yanchor)
		haskey(bar, key) && _cbar_string(bar, key, "") != placement[key] &&
			return false
	end
	return _cbar_string(bar, :orientation, "v") == placement[:orientation]
end

"""
	_place_cell_colorbars!(p::Plot, start_index::Int)

Place the colorbars of the traces `p.data[start_index:end]` that the
SubplotFigure delegate just routed to a cell (spec F5). Every such trace that
draws its own colorbar and has no `colorbar.x` gets a bar next to its plot
area: `x = xdomain[2] + 0.01` (`xanchor = "left"`), `y` = middle of the area
(`yanchor = "middle"`), `len` = the area height (`lenmode = "fraction"`) and
`thickness = 12` px; keys the trace already sets are kept, and a horizontal
bar (`orientation = "h"`) goes below the area instead. Scene, polar, geo and
map cells use their layout domain, domain traces their `domain`.

Traces bound to a shared `coloraxis` draw no bar of their own: the bar of
`layout.<coloraxis>` is placed next to the union of all cells that use it,
unless it was placed explicitly (a bar sitting where this function put it for
the previous set of cells is moved). Math colorbar titles of the placed bars
are then drawn as annotations (plotly.js 2.35 cannot typeset them there).
"""
function _place_cell_colorbars!(p::Plot, start_index::Int)
	start_index > length(p.data) && return nothing
	coloraxes = String[]
	for index in start_index:length(p.data)
		trace = p.data[index]
		slot = _cbar_slot(trace, index)
		slot === nothing && continue
		if slot.coloraxis !== nothing
			slot.coloraxis in coloraxes || push!(coloraxes, slot.coloraxis)
			continue
		end
		slot.shows || continue
		existing = _cbar_slot_bar(trace, slot)
		bar = _symbol_dict(existing)
		# A bar `_finalize_figure!` placed (e.g. on the scratch figure of the
		# SubplotFigure delegate) is placed again for the cell.
		owned = _fin_bar_owned(bar)
		(_cmn_mapping_get(existing, :x) === nothing || owned) || continue
		if owned
			for key in _CBAR_FINALIZE_KEYS
				delete!(bar, key)
			end
		end
		region = _cbar_trace_region(p, trace)
		side = _cbar_string(bar, :orientation, "v") == "h" ? :bottom : :right
		for (key, value) in _cbar_placement(
			side,
			region.xdomain,
			region.ydomain,
			_CBAR_CELL_PAD,
		)
			haskey(bar, key) || (bar[key] = value)
		end
		haskey(bar, :thickness) || (bar[:thickness] = _CBAR_CELL_THICKNESS)
		_cbar_set_slot_bar!(trace, slot, bar)
	end
	for id in coloraxes
		_cbar_auto_place_coloraxis!(p, id, start_index)
	end
	_cbar_convert_math_titles!(p, start_index:length(p.data), coloraxes)
	return nothing
end

function _cbar_auto_place_coloraxis!(p::Plot, id::String, start_index::Int)
	key = Symbol(id)
	axis = get(p.layout.fields, key, nothing)
	_cmn_mapping_get(axis, :showscale) === false && return nothing
	all_regions, old_regions = _cbar_coloraxis_regions(p, id, start_index)
	isempty(all_regions) && return nothing
	bar = _symbol_dict(_cmn_mapping_get(axis, :colorbar))
	side = _cbar_string(bar, :orientation, "v") == "h" ? :bottom : :right
	if haskey(bar, :x)
		# Placed before: move it only if it sits where this function put it
		# for the previous cells (a bar the user placed stays).
		isempty(old_regions) && return nothing
		_cbar_placement_matches(
			bar,
			_cbar_region_placement(side, old_regions),
		) || return nothing
	end
	merge!(bar, _cbar_region_placement(side, all_regions))
	haskey(bar, :thickness) || (bar[:thickness] = _CBAR_CELL_THICKNESS)
	_cbar_store_coloraxis!(p, id, _symbol_dict(axis), bar)
	return nothing
end

# ── Math titles as annotations ──────────────────────────────────────────────
#
# plotly.js 2.35.2 typesets a MathJax colorbar title rotated by 90° beside the
# bar for title.side "top"/"bottom" and draws it unrotated and unclipped by
# the margins for "right" (verified by rendering every side). Such titles are
# drawn as a paper-referenced annotation next to the bar instead, named
# "plotlysupply:colorbar_title:<area>:<side>" (<area> is the plot-area key of
# `_cbar_trace_region`, or the coloraxis id) so later calls replace it.

_cbar_is_math(text) =
	text isa AbstractString &&
	length(text) >= 2 &&
	startswith(text, '$') &&
	endswith(text, '$')

function _cbar_title_text(bar::AbstractDict)
	title = get(bar, :title, nothing)
	title isa AbstractString && return String(title)
	text = _cmn_mapping_get(title, :text)
	return text isa AbstractString ? String(text) : nothing
end

function _cbar_title_side(bar::AbstractDict)
	side = _cmn_mapping_get(get(bar, :title, nothing), :side)
	(side isa AbstractString || side isa Symbol) || return :top
	symbol = Symbol(side)
	return symbol in _CBAR_TITLE_SIDES ? symbol : :top
end

_cbar_title_owner(key::AbstractString) = _CBAR_TITLE_ANNOTATION_PREFIX * key

function _cbar_annotations_without(p::Plot, owner::AbstractString)
	existing = get(p.layout.fields, :annotations, nothing)
	kept = Any[]
	existing === nothing && return kept
	existing isa AbstractVector || throw(ArgumentError(
		"colorbar title: layout.annotations must be a vector; got $(typeof(existing)).",
	))
	for item in existing
		_cmn_name_matches(_cmn_item_name(item), owner) && continue
		push!(kept, item)
	end
	return kept
end

function _cbar_find_title_annotation(p::Plot, key::AbstractString)
	existing = get(p.layout.fields, :annotations, nothing)
	existing isa AbstractVector || return nothing
	owner = _cbar_title_owner(key)
	prefix = owner * ":"
	for item in existing
		name = _cmn_item_name(item)
		(name isa AbstractString && startswith(name, prefix)) || continue
		side = Symbol(String(name)[(ncodeunits(prefix) + 1):end])
		side in _CBAR_TITLE_SIDES || continue
		text = _cmn_mapping_get(item, :text)
		text isa AbstractString || continue
		return (text = String(text), side = side)
	end
	return nothing
end

function _cbar_remove_title_annotation!(p::Plot, key::AbstractString)
	existing = get(p.layout.fields, :annotations, nothing)
	existing isa AbstractVector || return nothing
	owner = _cbar_title_owner(key)
	any(item -> _cmn_name_matches(_cmn_item_name(item), owner), existing) ||
		return nothing
	p.layout.fields[:annotations] = _cbar_annotations_without(p, owner)
	return nothing
end

function _cbar_font_size(p::Plot, bar::AbstractDict)
	size = _cmn_mapping_get(get(bar, :tickfont, nothing), :size)
	(size isa Real && !(size isa Bool) && isfinite(size) && size > 0) &&
		return Float64(size)
	size = _cmn_mapping_get(get(p.layout.fields, :font, nothing), :size)
	(size isa Real && !(size isa Bool) && isfinite(size) && size > 0) &&
		return Float64(size)
	return _CBAR_DEFAULT_FONT_SIZE
end

# Widest tick label of a bar, in characters: its `ticktext`, its `tickvals`
# or `dtick`, else plotly's automatic ticks over `range` (see
# `_fin_tick_chars`; a 300 px bar is assumed for the tick count).
function _cbar_tick_chars(bar::AbstractDict, range)
	range === nothing && !haskey(bar, :ticktext) && !haskey(bar, :tickvals) && return 3
	lo, hi = range === nothing ? (NaN, NaN) : range
	return _fin_tick_chars(bar, lo, hi, 300.0, false, true)
end

# Geometry of a bar for title annotations, or `nothing` when it cannot be
# located in paper coordinates (pixel lengths, or a horizontal bar left at
# plotly's default position).
function _cbar_geometry(p::Plot, bar::AbstractDict, range)
	_cbar_string(bar, :lenmode, "fraction") == "fraction" || return nothing
	_cbar_string(bar, :thicknessmode, "pixels") == "pixels" || return nothing
	horizontal = _cbar_string(bar, :orientation, "v") == "h"
	if horizontal
		(haskey(bar, :y) && haskey(bar, :yanchor)) || return nothing
	end
	font_size = _cbar_font_size(p, bar)
	return (
		horizontal = horizontal,
		x = _cbar_real(bar, :x, horizontal ? 0.5 : 1.02),
		y = _cbar_real(bar, :y, 0.5),
		len = _cbar_real(bar, :len, 1.0),
		thickness = _cbar_real(bar, :thickness, _CBAR_DEFAULT_THICKNESS),
		xanchor = _cbar_string(bar, :xanchor, horizontal ? "center" : "left"),
		yanchor = _cbar_string(bar, :yanchor, "middle"),
		xpad = _cbar_real(bar, :xpad, _CBAR_DEFAULT_XPAD),
		ypad = _cbar_real(bar, :ypad, 10.0),
		ticklen = _fin_tick_len(bar),
		font_size = font_size,
		tick_px = _cbar_tick_chars(bar, range) * _CBAR_CHAR_EM * font_size,
	)
end

# (low, high) paper extent of a bar of length `len` anchored at `position`.
function _cbar_span(position::Float64, len::Float64, anchor::String)
	anchor in ("middle", "center") && return (position - len / 2, position + len / 2)
	anchor in ("top", "right") && return (position - len, position)
	return (position, position + len)
end

function _cbar_title_annotation(name::String, text::String, side::Symbol, g)
	fields = Dict{Symbol,Any}(
		:name => name,
		:text => text,
		:xref => "paper",
		:yref => "paper",
		:showarrow => false,
	)
	if !g.horizontal
		lo, hi = _cbar_span(g.y, g.len, g.yanchor)
		# Pixel offset from `x` to the bar's left edge for the bar's anchor.
		anchor_shift = g.xanchor == "center" ? -g.thickness / 2 :
			g.xanchor == "right" ? -g.thickness : 0.0
		fields[:x] = g.x
		fields[:xanchor] = "left"
		if side === :right
			# Beside the tick labels: bar, ticks, the 3 px label offset,
			# the labels and a 4 px gap.
			fields[:xshift] = anchor_shift + g.xpad + g.thickness + g.ticklen + 3 + g.tick_px + 4
			fields[:y] = (lo + hi) / 2
			fields[:yanchor] = "middle"
			fields[:textangle] = -90
		else
			# Clear of the end tick label, which is centred on the end of
			# the coloured bar (`ypad` px inside the bar's extent) and so
			# reaches half a text line past it.
			clear = 2 + max(0.0, 0.5 * _CBAR_LINE_EM * g.font_size - g.ypad)
			fields[:xshift] = anchor_shift + g.xpad
			fields[:y] = side === :top ? hi : lo
			fields[:yanchor] = side === :top ? "bottom" : "top"
			fields[:yshift] = side === :top ? clear : -clear
		end
	else
		lo, hi = _cbar_span(g.x, g.len, g.xanchor)
		# Pixel offsets from `y` to the bar's top and bottom edges.
		top_shift = g.yanchor == "top" ? 0.0 :
			g.yanchor == "middle" ? g.thickness / 2 : g.thickness
		bottom_shift = top_shift - g.thickness
		fields[:y] = g.y
		if side === :right
			fields[:x] = hi
			fields[:xanchor] = "left"
			fields[:xshift] = 2
			fields[:yanchor] = "middle"
			fields[:yshift] = top_shift - g.thickness / 2
		else
			fields[:x] = (lo + hi) / 2
			fields[:xanchor] = "center"
			if side === :top
				fields[:yanchor] = "bottom"
				fields[:yshift] = top_shift + 2
			else
				# Below the tick labels, which sit under a horizontal bar.
				fields[:yanchor] = "top"
				fields[:yshift] = bottom_shift - _CBAR_LINE_EM * g.font_size - 2
			end
		end
	end
	return _cbar_attr(fields)
end

function _cbar_upsert_title_annotation!(
	p::Plot,
	key::AbstractString,
	text::AbstractString,
	side::Symbol,
	geometry,
)
	owner = _cbar_title_owner(key)
	kept = _cbar_annotations_without(p, owner)
	push!(
		kept,
		_cbar_title_annotation(owner * ":" * String(side), String(text), side, geometry),
	)
	p.layout.fields[:annotations] = kept
	return nothing
end

# Convert math titles of the bars of traces `indices` and of the coloraxes
# `coloraxes` into annotations.
function _cbar_convert_math_titles!(p::Plot, indices, coloraxes)
	for index in indices
		trace = p.data[index]
		slot = _cbar_slot(trace, index)
		(slot === nothing || !slot.shows) && continue
		bar = _symbol_dict(_cbar_slot_bar(trace, slot))
		text = _cbar_title_text(bar)
		_cbar_is_math(text) || continue
		geometry = _cbar_geometry(p, bar, _cbar_slot_range(trace, slot))
		geometry === nothing && continue
		side = _cbar_title_side(bar)
		delete!(bar, :title)
		_cbar_set_slot_bar!(trace, slot, bar)
		_cbar_upsert_title_annotation!(
			p,
			_cbar_trace_region(p, trace).key,
			text,
			side,
			geometry,
		)
	end
	for id in coloraxes
		key = Symbol(id)
		axis = get(p.layout.fields, key, nothing)
		_is_layout_mapping(axis) || continue
		_cmn_mapping_get(axis, :showscale) === false && continue
		bar = _symbol_dict(_cmn_mapping_get(axis, :colorbar))
		text = _cbar_title_text(bar)
		_cbar_is_math(text) || continue
		geometry = _cbar_geometry(p, bar, _cbar_coloraxis_range(p, id))
		geometry === nothing && continue
		side = _cbar_title_side(bar)
		delete!(bar, :title)
		_cbar_store_coloraxis!(p, id, _symbol_dict(axis), bar)
		_cbar_upsert_title_annotation!(p, id, text, side, geometry)
	end
	return nothing
end

# Colour range of a coloraxis for layout estimates.
function _cbar_coloraxis_range(p::Plot, id::String)
	axis = _symbol_dict(get(p.layout.fields, Symbol(id), nothing))
	lo = _cbar_real(axis, :cmin, nothing)
	hi = _cbar_real(axis, :cmax, nothing)
	(lo !== nothing && hi !== nothing) && return (lo, hi)
	result = nothing
	for index in eachindex(p.data)
		trace = p.data[index]
		slot = _cbar_slot(trace, index)
		(slot === nothing || slot.coloraxis != id) && continue
		values = _cbar_slot_values(trace, slot)
		part = values === nothing ? nothing : _cbar_extrema(values)
		part === nothing && continue
		result = result === nothing ? part :
			(min(result[1], part[1]), max(result[2], part[2]))
	end
	return result
end

"""
	_colorbar_title_attr(title::AbstractString, side::Symbol = :top; who) -> Union{Nothing,PlotlyAttribute}

Colorbar title for a constructor's `colorbar_title` / `colorbar_title_side`
keywords: `attr(text = _label(title), side = "top" | "right" | "bottom")`, or
`nothing` for an empty title. `side` must be `:top`, `:right` or `:bottom`
(`ArgumentError` otherwise). A math title is typeset wrongly by plotly.js in
that position, so after adding the traces call
[`_colorbar_math_titles!`](@ref) to draw it as an annotation.
"""
function _colorbar_title_attr(
	title::AbstractString,
	side::Symbol = :top;
	who::AbstractString = "_colorbar_title_attr",
)
	side in _CBAR_TITLE_SIDES || throw(ArgumentError(
		"$(who): `colorbar_title_side` must be :top, :right or :bottom; got $(repr(side)).",
	))
	isempty(title) && return nothing
	return attr(text = _label(title), side = String(side))
end

"""
	_colorbar_math_titles!(fig, trace_indices; coloraxes = ())

Draw the math colorbar titles of the traces `trace_indices` (and of the
listed coloraxis ids) as annotations next to their bars, leaving plain
titles untouched. Constructors call it for the traces they added. Inside the
SubplotFigure delegate it does nothing: the delegate converts the titles
after placing the bars in the target cell.
"""
function _colorbar_math_titles!(fig, trace_indices; coloraxes = ())
	_CBAR_DEFER_MATH_TITLES[] && return nothing
	p = _plot_obj(fig)
	ids = String[]
	for id in coloraxes
		normalized = _normalize_coloraxis(id, "_colorbar_math_titles!")
		normalized in ids || push!(ids, normalized)
	end
	_cbar_convert_math_titles!(p, trace_indices, ids)
	return nothing
end

# ── colorbar! ───────────────────────────────────────────────────────────────

function _colorbar_options(
	who::AbstractString;
	title::AbstractString,
	side::Symbol,
	len::Real,
	thickness::Real,
	x,
	y,
	ticks,
	ticklabels,
	tickformat::AbstractString,
	exponentformat::AbstractString,
	outlinewidth,
	title_side::Symbol,
	offset = nothing,
)
	side in _CBAR_SIDES || throw(ArgumentError(
		"$(who): `side` must be :right or :bottom; got $(repr(side)).",
	))
	(offset === nothing || (offset isa Symbol && offset in _CBAR_OFFSETS)) || throw(ArgumentError(
		"$(who): `offset` must be :auto, :always, :none or nothing; got $(repr(offset)).",
	))
	if offset === :auto || offset === :always
		(isempty(tickformat) && isempty(exponentformat)) || throw(ArgumentError(
			"$(who): `offset` writes the tick label format (`exponentformat = \"power\"`); " *
			"it cannot be combined with `tickformat` or `exponentformat`.",
		))
		ticklabels === nothing || throw(ArgumentError(
			"$(who): `offset` scales the tick labels; it cannot be combined with `ticklabels`.",
		))
	end
	title_side in _CBAR_TITLE_SIDES || throw(ArgumentError(
		"$(who): `title_side` must be :top, :right or :bottom; got $(repr(title_side)).",
	))
	len_value = _optional_size(len, who, "len")
	thickness_value = _optional_size(thickness, who, "thickness")
	x_value = _optional_position(x, who, "x")
	y_value = _optional_position(y, who, "y")
	tick_values, tick_labels = _cbar_tick_options(ticks, ticklabels, who)
	(isempty(exponentformat) || exponentformat in _CBAR_EXPONENT_FORMATS) ||
		throw(ArgumentError(
			"$(who): `exponentformat` must be one of " *
			"$(join(repr.(_CBAR_EXPONENT_FORMATS), ", ")); got $(repr(exponentformat)).",
		))
	outline = nothing
	if outlinewidth !== nothing
		(outlinewidth isa Real && !(outlinewidth isa Bool) &&
			isfinite(outlinewidth) && outlinewidth >= 0) || throw(ArgumentError(
			"$(who): `outlinewidth` must be a finite number ≥ 0 or nothing; " *
			"got $(repr(outlinewidth)).",
		))
		outline = Float64(outlinewidth)
	end
	return (
		title = isempty(title) ? nothing : _label(title),
		title_side = title_side,
		side = side,
		len = Float64(len_value),
		thickness = Float64(thickness_value),
		x = x_value === nothing ? nothing : Float64(x_value),
		y = y_value === nothing ? nothing : Float64(y_value),
		ticks = tick_values,
		ticklabels = tick_labels,
		tickformat = String(tickformat),
		exponentformat = String(exponentformat),
		outlinewidth = outline,
		offset = offset,
	)
end

function _cbar_option_placement(opts, xdomain, ydomain, pad::Float64)
	placement = _cbar_placement(opts.side, xdomain, ydomain, pad)
	opts.len > 0 && (placement[:len] = opts.len)
	opts.x === nothing || (placement[:x] = opts.x)
	opts.y === nothing || (placement[:y] = opts.y)
	return placement
end

# `keep`: the bar may stay where `_finalize_figure!` placed it (false when
# the call names the cell to place it next to).
function _cbar_apply_options!(bar::Dict{Symbol,Any}, opts, placement::AbstractDict; keep::Bool = true)
	explicit = !keep || opts.x !== nothing || opts.y !== nothing
	if !explicit && _fin_bar_owned(bar) && _fin_bar_vertical(bar) == (opts.side === :right)
		# `_finalize_figure!` placed this bar in the room it reserved next to
		# its plot area; it stays there (the finalize pass re-places it). Its
		# length is `len`, or the area's extent (`_room_bar_len`).
		bar[:orientation] = placement[:orientation]
		bar[:len] = placement[:len]
		bar[:lenmode] = "fraction"
	else
		# A position given here (or a new side) takes the bar out of
		# `_finalize_figure!`'s hands: drop its ownership mark (`xref` /
		# `yref = "paper"`, see `_fin_bar_owned`; plotly's default anyway).
		for key in (:xref, :yref)
			_cbar_string(bar, key, "") == "paper" && delete!(bar, key)
		end
		merge!(bar, placement)
	end
	if opts.thickness > 0
		bar[:thickness] = opts.thickness
		bar[:thicknessmode] = "pixels"
	end
	_cbar_apply_ticks!(bar, opts.ticks, opts.ticklabels)
	if opts.offset === :none
		# Only an offset written here (`showexponent = "last"`) is removed.
		if _cbar_string(bar, :showexponent, "") == "last"
			delete!(bar, :showexponent)
			delete!(bar, :minexponent)
			_cbar_string(bar, :exponentformat, "") == "power" && delete!(bar, :exponentformat)
		end
	elseif opts.offset !== nothing
		# One "×10^k" on the last (top / right) tick label, the others
		# scaled by 10^-k (plotly.js axes.js tickText: `showexponent`).
		# Explicit labels or a d3 format would hide it.
		bar[:exponentformat] = "power"
		bar[:showexponent] = "last"
		bar[:minexponent] = opts.offset === :always ? 0 : _CBAR_OFFSET_MIN_EXPONENT
		delete!(bar, :tickformat)
		delete!(bar, :ticktext)
	end
	isempty(opts.tickformat) || (bar[:tickformat] = opts.tickformat)
	isempty(opts.exponentformat) || (bar[:exponentformat] = opts.exponentformat)
	opts.outlinewidth === nothing || (bar[:outlinewidth] = opts.outlinewidth)
	return bar
end

# Write (or keep and re-place) the title of the bar `bar` of plot area /
# coloraxis `key`. `shows` is whether the bar is drawn; a hidden bar keeps
# its title on the bar (nothing would be visible either way).
function _cbar_apply_title!(
	p::Plot,
	bar::Dict{Symbol,Any},
	key::AbstractString,
	title::Union{Nothing,String},
	title_side::Symbol,
	shows::Bool,
	range,
)
	if !shows
		# A hidden bar draws nothing. The title annotation named after `key`
		# belongs to the bar shown in the same plot area (a mirrored mesh:
		# `plot_pcolormesh!(...; showscale=false)`), so it is never touched.
		title === nothing && return nothing
		existing = get(bar, :title, nothing)
		fields = existing isa AbstractString ?
			Dict{Symbol,Any}(:text => existing) :
			_symbol_dict(existing)
		fields[:text] = title
		fields[:side] = String(title_side)
		bar[:title] = _cbar_attr(fields)
		return nothing
	end
	if title !== nothing
		geometry = _cbar_is_math(title) ?
			_cbar_geometry(p, bar, range) :
			nothing
		if geometry !== nothing
			delete!(bar, :title)
			_cbar_upsert_title_annotation!(p, key, title, title_side, geometry)
		else
			existing = get(bar, :title, nothing)
			fields = existing isa AbstractString ?
				Dict{Symbol,Any}(:text => existing) :
				_symbol_dict(existing)
			fields[:text] = title
			fields[:side] = String(title_side)
			bar[:title] = _cbar_attr(fields)
			_cbar_remove_title_annotation!(p, key)
		end
		return nothing
	end
	# No new title: an annotation title follows the (possibly moved) bar.
	found = _cbar_find_title_annotation(p, key)
	found === nothing && return nothing
	geometry = _cbar_geometry(p, bar, range)
	if geometry === nothing
		_cbar_remove_title_annotation!(p, key)
		fields = _symbol_dict(get(bar, :title, nothing))
		fields[:text] = found.text
		fields[:side] = String(found.side)
		bar[:title] = _cbar_attr(fields)
	else
		_cbar_upsert_title_annotation!(p, key, found.text, found.side, geometry)
	end
	return nothing
end

function _colorbar_slots(p::Plot, indices, who::AbstractString, empty_message::AbstractString)
	slots = _CbarSlot[]
	for index in indices
		slot = _cbar_slot(p.data[index], index)
		slot === nothing || push!(slots, slot)
	end
	isempty(slots) && throw(ArgumentError("$(who): $(empty_message)"))
	return slots
end

const _CBAR_NO_COLOUR_HINT =
	"(heatmap, contour, surface, histogram2d, colour-mapped markers, …)"

# Keywords a colorbar call does not take (`show` included: a mutator never
# opens a window), rejected with an ArgumentError naming the function before
# anything changes. `cell_hint` says how the call selects cells instead.
function _cbar_reject_keywords(who::AbstractString, kwargs, cell_hint::AbstractString = "")
	isempty(kwargs) && return nothing
	names = join(("`$(key)`" for key in keys(kwargs)), ", ")
	hints = String[]
	haskey(kwargs, :show) &&
		push!(hints, "mutators do not take `show`; display the figure with `display(fig)`")
	any(key -> key in (:row, :col, :secondary_y, :inset), keys(kwargs)) && !isempty(cell_hint) &&
		push!(hints, cell_hint)
	throw(ArgumentError(
		"$(who): unsupported keyword argument(s) $(names)" *
		(isempty(hints) ? "" : " ($(join(hints, "; ")))") * ".",
	))
end

function _colorbar_edit_coloraxis!(
	p::Plot,
	id::String,
	opts,
	region,
	who::AbstractString,
)
	regions, _ = _cbar_coloraxis_regions(p, id, length(p.data) + 1)
	isempty(regions) && throw(ArgumentError(
		"$(who): no trace uses coloraxis $(repr(id)); bind traces to it " *
		"first (e.g. `coloraxis=:shared` or `shared_colorbar!`).",
	))
	if region === nothing
		xdomain, ydomain = _cbar_union(regions)
		pad = length(regions) == 1 ? _CBAR_CELL_PAD : _CBAR_SHARED_PAD
	else
		xdomain, ydomain = region
		pad = _CBAR_CELL_PAD
	end
	key = Symbol(id)
	axis = _symbol_dict(get(p.layout.fields, key, nothing))
	bar = _symbol_dict(get(axis, :colorbar, nothing))
	# fields-01: data-unit ticks on a log colour scale (color.jl).
	log = any(p.data) do trace
		slot = _cbar_slot(trace, 0)
		slot !== nothing && slot.coloraxis == id &&
			_colour_log_carrier(_cbar_slot_values(trace, slot), get(trace.fields, :customdata, nothing))
	end
	opts = _colour_log_bar_options(opts, log, who)
	_cbar_apply_options!(bar, opts, _cbar_option_placement(opts, xdomain, ydomain, pad); keep = region === nothing)
	_cbar_apply_title!(
		p,
		bar,
		id,
		opts.title,
		opts.title_side,
		get(axis, :showscale, true) !== false,
		_cbar_coloraxis_range(p, id),
	)
	_cbar_store_coloraxis!(p, id, axis, bar)
	return nothing
end

function _colorbar_edit_slots!(p::Plot, slots::Vector{_CbarSlot}, opts, who::AbstractString)
	axis_ids = String[]
	for slot in slots
		if slot.coloraxis !== nothing
			slot.coloraxis in axis_ids || push!(axis_ids, slot.coloraxis)
			continue
		end
		trace = p.data[slot.index]
		region = _cbar_trace_region(p, trace)
		bar = _symbol_dict(_cbar_slot_bar(trace, slot))
		# fields-01: data-unit ticks on a log colour scale (color.jl).
		slot_opts = _colour_log_bar_options(
			opts,
			_colour_log_carrier(_cbar_slot_values(trace, slot), get(trace.fields, :customdata, nothing)),
			who,
		)
		_cbar_apply_options!(
			bar,
			slot_opts,
			_cbar_option_placement(slot_opts, region.xdomain, region.ydomain, _CBAR_CELL_PAD),
		)
		_cbar_apply_title!(
			p,
			bar,
			region.key,
			opts.title,
			opts.title_side,
			slot.shows,
			_cbar_slot_range(trace, slot),
		)
		_cbar_set_slot_bar!(trace, slot, bar)
	end
	for id in axis_ids
		_colorbar_edit_coloraxis!(p, id, opts, nothing, who)
	end
	return nothing
end

function _colorbar_impl!(
	fig;
	row = nothing,
	col = nothing,
	coloraxis = nothing,
	options...,
)
	who = "colorbar!"
	(row === nothing && col === nothing) || throw(ArgumentError(
		"$(who): `row`/`col` select a SubplotFigure cell; a single figure has " *
		"one cell, so omit them.",
	))
	opts = _colorbar_options(who; options...)
	p = _plot_obj(fig)
	if coloraxis === nothing
		slots = _colorbar_slots(
			p,
			eachindex(p.data),
			who,
			"the figure has no coloured trace $(_CBAR_NO_COLOUR_HINT).",
		)
		_colorbar_edit_slots!(p, slots, opts, who)
	else
		_colorbar_edit_coloraxis!(
			p,
			_normalize_coloraxis(coloraxis, who),
			opts,
			nothing,
			who,
		)
	end
	_refresh!(fig)
	return nothing
end

function _colorbar_subplot_impl!(
	sf::SubplotFigure;
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	coloraxis = nothing,
	options...,
)
	who = "colorbar!"
	opts = _colorbar_options(who; options...)
	target = _cell_target(sf; row = row, col = col, who = who)
	r, c = target.row, target.col
	p = _plot_obj(sf.fig)
	if coloraxis === nothing
		slots = _colorbar_slots(
			p,
			_cbar_cell_trace_indices(sf, p, ((r, c),), who),
			who,
			"subplot cell ($(r), $(c)) has no coloured trace $(_CBAR_NO_COLOUR_HINT).",
		)
		_colorbar_edit_slots!(p, slots, opts, who)
	else
		region = row === nothing ? nothing : (target.xdomain, target.ydomain)
		_colorbar_edit_coloraxis!(
			p,
			_normalize_coloraxis(coloraxis, who),
			opts,
			region,
			who,
		)
	end
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

"""
	colorbar!(fig; coloraxis=nothing, title="", title_side=:top, side=:right,
		len=0, thickness=0, x=nothing, y=nothing, ticks=nothing,
		ticklabels=nothing, tickformat="", exponentformat="", outlinewidth=nothing,
		offset=nothing)
	colorbar!(sf::SubplotFigure; row=nothing, col=nothing, coloraxis=nothing, ...)

Edit the colorbars that already exist in a figure.

# Targets
- `coloraxis=nothing`: every coloured trace — heatmap, contour, surface,
  mesh3d with `intensity`, histogram2d, volume, choropleth, …, and traces with
  a numeric `marker.color` (including invisible colorbar carrier traces) — of
  the figure (`Plot`/`SyncPlot`) or of one cell (`SubplotFigure`: the cell
  `row`/`col`, both or neither, default the active cell, which becomes
  active). A trace bound to a shared coloraxis edits that coloraxis' bar
  instead (placed next to all cells that use it).
- `coloraxis=:shared` / `"coloraxis2"`: the bar of `layout.<coloraxis>`,
  placed next to all cells whose traces use it, or next to cell `row`/`col`
  when given (SubplotFigure).
- Nothing coloured found (or no trace uses the coloraxis): `ArgumentError`,
  nothing changes.

# Keywords
- `title::AbstractString=""`: bar title (LaTeX/mathtext via [`mathtext`](@ref));
  `""` keeps the current title.
- `title_side::Symbol=:top`: `:top`, `:right` (rotated, beside the tick
  labels) or `:bottom`; applied with a new `title`. Plotly.js 2.35 cannot
  typeset a math (`\$…\$`) colorbar title on any side, so a math title is drawn
  as an annotation next to the bar (named
  `"plotlysupply:colorbar_title:<area>:<side>"`); its distance for `:right`
  is estimated from the tick-label width. The annotation follows later
  `colorbar!` moves but not `relayout!`/`restyle!` edits of the bar.
- `side::Symbol=:right`: `:right` gives a vertical bar right of the plot
  area (past a right-side y axis' labels) and as tall as it; `:bottom` a
  horizontal bar below the cell's x tick labels and x title, centred on the
  cell and as wide as it. Every figure update reserves room for the bar,
  its tick labels and its title (decision D12): when the gap to the
  neighbouring cell is too small the cell's domain shrinks on that side
  (cells sharing that grid edge shrink alike, at most half the cell), at the
  figure edge the margin grows; a cell whose domain you set yourself keeps
  it. Bars of one cell sit side by side. A bar placed this way stays where
  it is on later calls without `x` or `y` (pass `side` again to keep a
  bottom bar at the bottom: the default is `:right`); a vertical bar is
  never drawn shorter than three lines of tick labels plus a title above or
  below it (at most the plot height).
- `len::Real=0`: bar length as a paper fraction, centred on the cell (`0`:
  the cell's extent, following it when its domain changes).
- `thickness::Real=0`: bar thickness in px (`0`: unchanged).
- `x`, `y`: explicit bar position (paper fractions) overriding `side`'s.
- `ticks`: tick values in colour units; `ticklabels` (requires `ticks`, same
  length) their labels, rendered through mathtext. On a logarithmic colour
  scale (`colornorm = :log`) the ticks are data values, as the constructors'
  `colorbar_ticks`: positive, placed at their log10 and labelled `10^k` (or
  by `ticklabels`).
- `tickformat::AbstractString=""`: d3 format such as `".2f"`;
  `exponentformat::AbstractString=""`: `"none"`, `"e"`, `"E"`, `"power"`,
  `"SI"` or `"B"`; `outlinewidth`: outline width in px (`nothing`: unchanged).
- `offset=nothing`: one common factor for the tick labels, like
  matplotlib's offset text: `:auto` takes 10^k out of the labels when the
  largest end of the colour range has |k| ≥ 5 (k = ⌊log10⌋; plotly.js
  decides at every draw, so it follows later range changes), `:always`
  whenever k ≠ 0; the labels show the scaled values and only the last (top
  or right) one carries "×10^k" (`exponentformat = "power"`, `showexponent =
  "last"`, `minexponent`). It replaces an earlier `tickformat` or tick
  label text and cannot be combined with `tickformat`, `exponentformat` or
  `ticklabels`. `:none` removes such an offset; `nothing` leaves it.

Short bars (a cell of a wide equal-aspect field, `len` small) get fewer
automatic ticks: every figure update sets `nticks` (with `tickmode =
"auto"`) so that the labels stay two font sizes apart (horizontal bars: one
font size between labels), and removes it when the bar is long enough
again. Bars with `ticks`, a `dtick` or an `nticks` of your own keep them
(the mark of a thinned bar is the `tickmode = "auto"` written with its
`nticks`: to set `nticks` on such a bar with `restyle!`, clear `tickmode` in
the same call). A bar always shows two tick labels at least: when the
thinned automatic ticks would label the range once or not at all (plotly
labels only multiples of its rounded step: range 0.1 to 0.9 with `nticks = 2`
shows 0.5 alone), the two values are written as `tickvals` next to the
`nticks` (`tickmode = "array"`; the `nticks` is the mark and is ignored by
plotly.js in that mode), and removed again with it. Ticks given with
`ticks`, `restyle!` or `shared_colorbar!` replace them.

All options are validated first (`ArgumentError`); the change is applied in
one transaction (a live window redraws once). Returns `nothing` for a
`Plot`/`SyncPlot` and `sf` for a `SubplotFigure`.

# Example
```julia
sf = subplots(1, 2; sync=false)
plot_heatmap!(sf, rand(10, 10); row=1, col=1)
plot_heatmap!(sf, rand(10, 10); row=1, col=2)
colorbar!(sf; row=1, col=2, title="\\\$|E|^2\\\$", title_side=:right)
colorbar!(sf; row=1, col=1, side=:bottom, ticks=[0, 0.5, 1])
```
"""
function colorbar!(
	fig::Union{Plot,SyncPlot};
	row = nothing,
	col = nothing,
	coloraxis = nothing,
	title::AbstractString = "",
	title_side::Symbol = :top,
	side::Symbol = :right,
	len::Real = 0,
	thickness::Real = 0,
	x = nothing,
	y = nothing,
	ticks = nothing,
	ticklabels = nothing,
	tickformat::AbstractString = "",
	exponentformat::AbstractString = "",
	outlinewidth = nothing,
	offset = nothing,
	kwargs...,
)
	_cbar_reject_keywords("colorbar!", kwargs,
		"a single figure has one cell; omit the cell keywords")
	# One colour-range scan per array for the call and its finalizer (Z83).
	return _cbar_with_extrema_memo(() -> _transactional_high_level_plot_mutation!(
		_colorbar_impl!,
		fig;
		row, col, coloraxis, title, title_side, side, len, thickness, x, y,
		ticks, ticklabels, tickformat, exponentformat, outlinewidth, offset,
	))
end

function colorbar!(
	sf::SubplotFigure;
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	coloraxis = nothing,
	title::AbstractString = "",
	title_side::Symbol = :top,
	side::Symbol = :right,
	len::Real = 0,
	thickness::Real = 0,
	x = nothing,
	y = nothing,
	ticks = nothing,
	ticklabels = nothing,
	tickformat::AbstractString = "",
	exponentformat::AbstractString = "",
	outlinewidth = nothing,
	offset = nothing,
	kwargs...,
)
	_cbar_reject_keywords("colorbar!", kwargs,
		"select the cell with `row`/`col`; an inset's bar is edited through its host cell")
	# One colour-range scan per array for the call and its finalizer (Z83).
	return _cbar_with_extrema_memo(() -> _transactional_subplot_mutation!(
		_colorbar_subplot_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS;
		row, col, coloraxis, title, title_side, side, len, thickness, x, y,
		ticks, ticklabels, tickformat, exponentformat, outlinewidth, offset,
	))
end

# ── shared_colorbar! ────────────────────────────────────────────────────────

# `ticks` (colour units) and `ticklabels` (same length, as `_label` text) of
# a bar, checked: `(values, labels)`, each `nothing` when not given.
function _cbar_tick_options(ticks, ticklabels, who::AbstractString)
	tick_values = ticks === nothing ? nothing : _checked_real_vector(ticks, who, "ticks")
	tick_labels = nothing
	if ticklabels !== nothing
		tick_values === nothing && throw(ArgumentError(
			"$(who): `ticklabels` need `ticks` of the same length.",
		))
		(ticklabels isa AbstractVector || ticklabels isa Tuple) || throw(ArgumentError(
			"$(who): `ticklabels` must be a vector; got $(typeof(ticklabels)).",
		))
		length(ticklabels) == length(tick_values) || throw(ArgumentError(
			"$(who): $(length(ticklabels)) `ticklabels` for $(length(tick_values)) `ticks`.",
		))
		# tm-cbar-math-ticklabels-hang: plotly.js 2.35.2 never finishes
		# MathJax colorbar tick labels (every export waited for its timeout),
		# so their math is drawn as Unicode with <sup>/<sub> (`_label_plain`).
		tick_labels = String[_label_plain(string(label)) for label in ticklabels]
	end
	return tick_values, tick_labels
end

# `bar` with the explicit `ticks`/`ticklabels` of `opts` (no change without
# `ticks`): an `nticks` `_finalize_figure!` wrote for automatic ticks
# (`_fin_bar_tick_state`) goes with them.
function _cbar_apply_ticks!(bar::Dict{Symbol, Any}, ticks, ticklabels)
	ticks === nothing && return bar
	_fin_bar_tick_state(bar)[2] && delete!(bar, :nticks)
	bar[:tickmode] = "array"
	bar[:tickvals] = ticks
	if ticklabels === nothing
		delete!(bar, :ticktext)
	else
		bar[:ticktext] = ticklabels
	end
	return bar
end

function _shared_colorbar_options(
	who::AbstractString;
	colorscale,
	crange,
	cmid,
	title::AbstractString,
	len::Real,
	side::Symbol,
	coloraxis,
	title_side::Symbol,
	ticks = nothing,
	ticklabels = nothing,
)
	side in _CBAR_SIDES || throw(ArgumentError(
		"$(who): `side` must be :right or :bottom; got $(repr(side)).",
	))
	title_side in _CBAR_TITLE_SIDES || throw(ArgumentError(
		"$(who): `title_side` must be :top, :right or :bottom; got $(repr(title_side)).",
	))
	(len isa Real && !(len isa Bool) && isfinite(len) && len > 0) || throw(ArgumentError(
		"$(who): `len` (fraction of the selected cells' extent) must be a " *
		"positive finite number; got $(repr(len)).",
	))
	scale = _is_unset_colorscale(colorscale) ? nothing :
		_resolve_colorscale(colorscale; who = who)
	range = _checked_range(crange, who, "crange")
	limits = nothing
	if range !== nothing
		(range[1] isa Real && range[2] isa Real && !(range[1] isa Bool) &&
			!(range[2] isa Bool)) || throw(ArgumentError(
			"$(who): `crange` bounds must be numbers; got $(repr(crange)).",
		))
		range[1] < range[2] || throw(ArgumentError(
			"$(who): `crange` must be increasing (lower < upper); got $(repr(crange)).",
		))
		limits = (Float64(range[1]), Float64(range[2]))
	end
	mid = nothing
	if cmid !== nothing
		(cmid isa Real && !(cmid isa Bool) && isfinite(cmid)) || throw(ArgumentError(
			"$(who): `cmid` must be a finite number or nothing; got $(repr(cmid)).",
		))
		# With an explicit `crange`, `cmid` is a two-slope remap of the
		# colour scale (F4), which needs it strictly inside the range.
		(limits === nothing || limits[1] < cmid < limits[2]) || throw(ArgumentError(
			"$(who): `cmid` = $(cmid) must lie strictly inside `crange` = " *
			"$(repr(crange)).",
		))
		mid = Float64(cmid)
	end
	tick_values, tick_labels = _cbar_tick_options(ticks, ticklabels, who)
	return (
		scale = scale,
		limits = limits,
		cmid = mid,
		ticks = tick_values,
		ticklabels = tick_labels,
		title = isempty(title) ? nothing : _label(title),
		title_side = title_side,
		len = Float64(len),
		side = side,
		coloraxis = _normalize_coloraxis(coloraxis, who),
	)
end

# The colour scale (and reversal) the first coloured trace that sets one uses.
function _shared_colorbar_first_scale(p::Plot, slots::Vector{_CbarSlot})
	for slot in slots
		trace = p.data[slot.index]
		source = slot.container === :root ?
			trace.fields :
			_symbol_dict(get(trace.fields, slot.container, nothing))
		if slot.coloraxis !== nothing
			axis = _symbol_dict(get(p.layout.fields, Symbol(slot.coloraxis), nothing))
			haskey(axis, :colorscale) || continue
			return (
				scale = axis[:colorscale],
				reversescale = get(axis, :reversescale, false) === true,
			)
		end
		haskey(source, :colorscale) || continue
		return (
			scale = source[:colorscale],
			reversescale = get(source, :reversescale, false) === true,
		)
	end
	return nothing
end

# Fully expanded `[t, "#RRGGBB"]` stops of a stored colour scale, or `nothing`
# when it is unset or not a scale this package can interpret (then it is
# treated as "unknown" and never compared).
function _cbar_scale_stops(scale, reversescale::Bool)
	_is_unset_colorscale(scale) && return nothing
	stops = try
		_colorscale_stops(scale; who = "shared_colorbar!")
	catch err
		err isa ArgumentError || rethrow()
		return nothing
	end
	return reversescale ? _reverse_stops(stops) : stops
end

function _cbar_same_stops(a, b)
	length(a) == length(b) || return false
	for (sa, sb) in zip(a, b)
		isapprox(Float64(sa[1]), Float64(sb[1]); atol = 1e-9) || return false
		_color_hex(sa[2]) == _color_hex(sb[2]) || return false
	end
	return true
end

function _cbar_slot_source(trace::GenericTrace, slot::_CbarSlot)
	slot.container === :root && return trace.fields
	return _symbol_dict(get(trace.fields, slot.container, nothing))
end

# A trace that is not bound to a coloraxis and whose own colour scale has one
# colour everywhere (e.g. `plot_quiver3d(...; color=...)` cones) shows a flat
# colour, not a colour mapping; `shared_colorbar!` leaves it alone.
function _cbar_slot_is_flat(trace::GenericTrace, slot::_CbarSlot)
	slot.coloraxis === nothing || return false
	source = _cbar_slot_source(trace, slot)
	stops = _cbar_scale_stops(
		get(source, :colorscale, nothing),
		get(source, :reversescale, false) === true,
	)
	(stops === nothing || isempty(stops)) && return false
	first_colour = _color_hex(stops[1][2])
	return all(stop -> _color_hex(stop[2]) == first_colour, stops)
end

# An invisible colorbar carrier made by `_colorbar_carrier_trace`: its colour
# limits are `marker.color = [cmin, cmax]` and the colours it labels were
# sampled in Julia, so they cannot follow a new range or scale.
function _cbar_is_carrier(trace::GenericTrace)
	fields = trace.fields
	_cbar_trace_type(trace) == "scatter" || return false
	get(fields, :hoverinfo, nothing) == "skip" || return false
	for key in (:x, :y)
		values = get(fields, key, nothing)
		(values isa AbstractVector && length(values) == 1 && only(values) === _GAP) ||
			return false
	end
	colours = _cmn_mapping_get(get(fields, :marker, nothing), :color)
	return colours isa AbstractVector && length(colours) == 2 &&
		all(v -> v isa Real && !(v isa Bool) && isfinite(v), colours)
end

# (limits, scale, indices) of the carriers among `slots`: the union of the
# limits they were drawn with (`marker.color`; a build the shared limits
# differ from is recoloured, `_colour_recolour_plans`), the scale
# `(scale, reversescale, stops)` from the marker or the coloraxis they are
# bound to (`nothing` when unset; carriers drawn with different scales cannot
# share one bar), and their trace indices.
function _shared_colorbar_carrier_spec(p::Plot, slots::Vector{_CbarSlot}, who::AbstractString)
	limits = nothing
	scale = nothing
	indices = Int[]
	for slot in slots
		trace = p.data[slot.index]
		_cbar_is_carrier(trace) || continue
		push!(indices, slot.index)
		colours = _cmn_mapping_get(get(trace.fields, :marker, nothing), :color)
		carrier_limits = (Float64(colours[1]), Float64(colours[2]))
		limits = limits === nothing ? carrier_limits :
			(min(limits[1], carrier_limits[1]), max(limits[2], carrier_limits[2]))
		source = slot.coloraxis === nothing ?
			_cbar_slot_source(trace, slot) :
			_symbol_dict(get(p.layout.fields, Symbol(slot.coloraxis), nothing))
		raw = get(source, :colorscale, nothing)
		reversed = get(source, :reversescale, false) === true
		stops = _cbar_scale_stops(raw, reversed)
		stops === nothing && continue
		if scale === nothing
			scale = (scale = raw, reversescale = reversed, stops = stops)
		elseif !_cbar_same_stops(scale.stops, stops)
			throw(ArgumentError(
				"$(who): the colorbar carrier traces were drawn with different colour " *
				"scales. Their colours are fixed when the figure is built, so they " *
				"cannot share one bar; rebuild those plots with a common `colorscale`.",
			))
		end
	end
	return (limits = limits, scale = scale, indices = indices)
end

# Non-geometry settings of the bars that `shared_colorbar!` removes, for the
# shared bar: the first bar's settings (number format, thickness, …), its
# title (`nothing` when none), and the union of the explicit ticks of all
# bars (`tickvals` sorted, the first label of a value winning; labelled
# bars take precedence over unlabelled ones). Log-scaled panels thus keep
# their decade labels on the shared bar.
function _shared_colorbar_carried(p::Plot, slots::Vector{_CbarSlot})
	settings = Dict{Symbol,Any}()
	title = nothing
	labelled = Dict{Float64,Any}()
	unlabelled = Float64[]
	first_bar = true
	for slot in slots
		slot.coloraxis === nothing || continue
		trace = p.data[slot.index]
		bar = _symbol_dict(_cbar_slot_bar(trace, slot))
		if title === nothing
			text = _cbar_title_text(bar)
			if text !== nothing && !isempty(text)
				title = (text = text, side = _cbar_title_side(bar))
			elseif slot.shows
				found = _cbar_find_title_annotation(p, _cbar_trace_region(p, trace).key)
				found === nothing || (title = found)
			end
		end
		# Two tick values the finalizer wrote for a short bar are not the
		# user's ticks (`_fin_bar_tick_state`).
		tickvals = _fin_bar_tick_state(bar)[2] ? nothing : get(bar, :tickvals, nothing)
		if tickvals isa AbstractVector && !isempty(tickvals) &&
				all(v -> v isa Real && !(v isa Bool) && isfinite(v), tickvals)
			ticktext = get(bar, :ticktext, nothing)
			if ticktext isa AbstractVector && length(ticktext) == length(tickvals)
				for (value, label) in zip(tickvals, ticktext)
					get!(labelled, Float64(value), label)
				end
			else
				append!(unlabelled, Float64.(tickvals))
			end
		end
		if first_bar && !isempty(bar)
			# An `nticks` the finalizer wrote to thin the ticks of this (short)
			# cell bar (`_fin_bar_tick_state`: `tickmode = "auto"` + `nticks`)
			# is not a setting of the user's: copied without its mark it would
			# stay on the shared bar as if it were, however long that bar is.
			thinned = _fin_bar_tick_state(bar)[2]
			for (key, value) in bar
				key in _CBAR_GEOMETRY_KEYS && continue
				key in (:title, :tickvals, :ticktext, :tickmode) && continue
				thinned && key === :nticks && continue
				settings[key] = value
			end
			first_bar = false
		end
	end
	if !isempty(labelled)
		values = sort!(collect(keys(labelled)))
		settings[:tickmode] = "array"
		settings[:tickvals] = values
		settings[:ticktext] = Any[labelled[v] for v in values]
	elseif !isempty(unlabelled)
		settings[:tickmode] = "array"
		settings[:tickvals] = sort!(unique(unlabelled))
	end
	return (settings = settings, title = title)
end

# The colour norm trace `trace` (slot `slot`) was drawn with (fields-03):
# `(:levels, boundaries)` for the stepped scale `levels` writes (one colour
# per band, two stops at each inner boundary, the bar ticked at the
# boundaries), `(:log, nothing)` for a bar labelled as `colornorm = :log`
# labels it (`_log_tick_label` at log10 positions), else `(:linear, nothing)`.
# A trace already bound to a coloraxis is drawn with the axis' scale and bar.
function _cbar_slot_norm(p::Plot, trace::GenericTrace, slot::_CbarSlot)
	if slot.coloraxis !== nothing
		holder = get(p.layout.fields, Symbol(slot.coloraxis), nothing)
		bar = _cmn_mapping_get(holder, :colorbar)
	else
		holder = slot.container === :root ? trace.fields : get(trace.fields, slot.container, nothing)
		bar = _cbar_slot_bar(trace, slot)
	end
	ticks = _cmn_mapping_get(bar, :tickvals)
	labels = _cmn_mapping_get(bar, :ticktext)
	numeric(v) = v isa AbstractVector && !isempty(v) && all(x -> x isa Real && !(x isa Bool) && isfinite(x), v)
	# A log bar labels the decades 0 and 1 "1" and "10", as plotly's log axes
	# (numerics-11): labels that are all plain numbers ("1", "10" at 0 and 1,
	# a user's linear bar) mark a log bar only on a trace carrying log10 data.
	if numeric(ticks) && labels isa AbstractVector && length(labels) == length(ticks) &&
			all(i -> labels[i] isa AbstractString && labels[i] == _log_tick_label(10.0^Float64(ticks[i])),
				eachindex(ticks)) &&
			(any(label -> occursin("<sup>", label), labels) ||
			 _colour_log_carrier(_cbar_slot_values(trace, slot), get(trace.fields, :customdata, nothing)))
		return (:log, nothing)
	end
	scale = _cmn_mapping_get(holder, :colorscale)
	if scale isa AbstractVector && length(scale) >= 4 && numeric(ticks) && length(ticks) >= 2
		positions = Float64[]
		for stop in scale
			(stop isa AbstractVector || stop isa Tuple) && length(stop) == 2 && stop[1] isa Real ||
				return (:linear, nothing)
			push!(positions, Float64(stop[1]))
		end
		stepped = any(i -> positions[i] == positions[i + 1], 1:(length(positions) - 1))
		edges = unique(positions)
		lo, hi = Float64(first(ticks)), Float64(last(ticks))
		if stepped && hi > lo && length(edges) == length(ticks) &&
				all(i -> isapprox(edges[i], (Float64(ticks[i]) - lo) / (hi - lo); atol = 1e-9), eachindex(edges))
			return (:levels, Float64.(ticks))
		end
	end
	return (:linear, nothing)
end

# Members of one shared colour axis must be drawn with one colour norm: the
# axis maps every member through one continuous range, so a `levels` panel
# next to a continuous one, or a log panel next to a linear one, would be
# recoloured wrongly (fields-03). Throws before anything changes.
function _shared_colorbar_check_norms(p::Plot, slots::Vector{_CbarSlot}, who::AbstractString)
	first_norm = nothing
	first_index = 0
	for slot in slots
		trace = p.data[slot.index]
		trace isa GenericTrace || continue
		# Contours colour by their own levels and get the shared limits.
		_cbar_is_banded_contour(trace, slot) && continue
		norm = _cbar_slot_norm(p, trace, slot)
		if first_norm === nothing
			first_norm, first_index = norm, slot.index
			continue
		end
		norm == first_norm && continue
		describe(n) = n[1] === :levels ? "levels $(n[2])" : n[1] === :log ? "colornorm = :log" :
			"a continuous linear scale"
		throw(ArgumentError(
			"$(who): trace $(first_index) is drawn with $(describe(first_norm)) and trace " *
			"$(slot.index) with $(describe(norm)); one colour axis maps every member through one " *
			"norm. Build the panels with the same `levels`/`colornorm`, or give them separate colorbars.",
		))
	end
	return nothing
end

function _shared_colorbar_apply!(
	p::Plot,
	slots::Vector{_CbarSlot},
	regions,
	opts,
	who::AbstractString,
)
	id = opts.coloraxis
	_shared_colorbar_check_norms(p, slots, who)
	carriers = _shared_colorbar_carrier_spec(p, slots, who)
	carried = _shared_colorbar_carried(p, slots)
	# Colour limits: explicit, centred automatic (cmid), the limits colorbar
	# carriers were drawn with, or the global finite extrema of the colour
	# data. When any trace's colour data is computed by plotly (histogram2d
	# counts, …) the limits stay automatic: plotly ranges a coloraxis over
	# every trace bound to it.
	limits = opts.limits
	if carriers.limits !== nothing
		opts.cmid === nothing || throw(ArgumentError(
			"$(who): `cmid` would rescale the colorbar carrier traces, whose " *
			"colours are fixed at $(carriers.limits[1])..$(carriers.limits[2]); omit it.",
		))
		# O3: the shared limits are the given `crange`, else the extent of
		# every member (the carriers' limits included); the carrier builds
		# drawn for other limits are recoloured for them below.
		if limits === nothing
			extent = _colour_members_extent(p, slots)
			limits = extent === nothing ? carriers.limits :
				(min(extent[1], carriers.limits[1]), max(extent[2], carriers.limits[2]))
		end
	end
	if carriers.scale !== nothing && opts.scale !== nothing
		requested = _cbar_scale_stops(opts.scale.scale, opts.scale.reversescale)
		(requested === nothing || _cbar_same_stops(requested, carriers.scale.stops)) ||
			throw(ArgumentError(
				"$(who): `colorscale` differs from the scale the colorbar carrier " *
				"traces were drawn with; their colours cannot be recoloured. Omit " *
				"`colorscale` or rebuild those plots with it.",
			))
	end
	# Filled/line contours are given the shared scale and limits instead of
	# the coloraxis (see `_cbar_is_banded_contour`).
	banded = [slot for slot in slots if _cbar_is_banded_contour(p.data[slot.index], slot)]
	bound = [slot for slot in slots if !(slot in banded)]
	if limits === nothing && (opts.cmid === nothing || !isempty(banded))
		data_range = _shared_colorbar_data_range(p, slots)
		if data_range !== nothing
			if opts.cmid === nothing
				limits = data_range
			else
				# plotly's cmid: the smallest range centred on cmid that holds
				# the data, written out so the contours get the same one.
				radius = max(data_range[2] - opts.cmid, opts.cmid - data_range[1])
				radius > 0 && (limits = (opts.cmid - radius, opts.cmid + radius))
			end
		end
	end
	isempty(banded) || limits !== nothing || throw(ArgumentError(
		"$(who): filled contours need explicit colour limits to share a colour " *
		"scale, but here plotly would compute them (histogram counts or " *
		"constant data). Pass `crange=[cmin, cmax]`.",
	))
	scale = if opts.scale !== nothing
		(scale = opts.scale.scale, reversescale = opts.scale.reversescale)
	elseif carriers.scale !== nothing
		(scale = carriers.scale.scale, reversescale = carriers.scale.reversescale)
	else
		_shared_colorbar_first_scale(p, slots)
	end
	if scale === nothing
		# The scale the traces were drawn with: plotly's coloraxis would
		# otherwise pick its automatic sequential/diverging palette by the
		# sign of the data, recolouring every panel; contours and the
		# coloraxis must also name the same scale explicitly.
		first_slot = isempty(bound) ? first(banded) : first(bound)
		scale = (
			scale = _cbar_default_scale(p, _cbar_trace_type(p.data[first_slot.index])),
			reversescale = false,
		)
	end
	if opts.cmid !== nothing && opts.limits !== nothing
		# Two-slope norm (F4): the scale's middle colour moves to `cmid`.
		mid_at = (opts.cmid - limits[1]) / (limits[2] - limits[1])
		if mid_at != 0.5
			stops = _cbar_scale_stops(scale.scale, scale.reversescale)
			stops === nothing && throw(ArgumentError(
				"$(who): `cmid` with an explicit `crange` remaps the colour " *
				"scale, but the scale $(repr(scale.scale)) cannot be interpreted; " *
				"pass `colorscale`.",
			))
			scale = (scale = _two_slope_stops(stops, mid_at), reversescale = false)
		end
	end

	# O3 (fields-08): carrier builds drawn for other limits are recoloured
	# for the shared ones (all checked before the first is changed).
	if limits !== nothing && !isempty(carriers.indices)
		shared = (Float64(limits[1]), Float64(limits[2]))
		plans = _colour_recolour_plans(p, carriers.indices, shared,
			carriers.scale === nothing ? nothing : carriers.scale.stops, who)
		for (k, plan) in plans
			_colour_recolour!(p, k, plan, shared)
		end
	end

	# Rebind every coloured trace; its own bar disappears with it.
	removed_areas = String[]
	for slot in slots
		trace = p.data[slot.index]
		slot.shows && push!(removed_areas, _cbar_trace_region(p, trace).key)
		if slot in banded
			_cbar_set_banded_scale!(trace, scale, limits)
		elseif slot.container === :root
			trace.fields[:coloraxis] = id
			delete!(trace.fields, :showscale)
			delete!(trace.fields, :colorbar)
		else
			container = _symbol_dict(get(trace.fields, slot.container, nothing))
			container[:coloraxis] = id
			delete!(container, :showscale)
			delete!(container, :colorbar)
			trace.fields[slot.container] = _cbar_attr(container)
		end
	end
	for area in unique(removed_areas)
		_cbar_remove_title_annotation!(p, area)
	end

	xdomain, ydomain = _cbar_union(regions)
	placement = _cbar_placement(opts.side, xdomain, ydomain, _CBAR_SHARED_PAD)
	extent = opts.side === :right ? ydomain[2] - ydomain[1] : xdomain[2] - xdomain[1]
	placement[:len] = opts.len * extent

	key = Symbol(id)
	if isempty(bound)
		# Only contours: the first one draws the shared bar (its scale and
		# limits are those of every other contour).
		holder = first(banded)
		trace = p.data[holder.index]
		bar = _symbol_dict(get(trace.fields, :colorbar, nothing))
		_shared_colorbar_fill_bar!(p, bar, placement, carried, opts, _cbar_trace_region(p, trace).key, limits)
		trace.fields[:showscale] = true
		trace.fields[:colorbar] = _cbar_attr(bar)
		return nothing
	end
	axis = _symbol_dict(get(p.layout.fields, key, nothing))
	if scale !== nothing && !(scale.scale isa AbstractString && isempty(scale.scale))
		axis[:colorscale] = scale.scale
		if scale.reversescale
			axis[:reversescale] = true
		else
			delete!(axis, :reversescale)
		end
	end
	for name in (:cmin, :cmax, :cmid, :cauto)
		delete!(axis, name)
	end
	if limits !== nothing
		axis[:cmin] = limits[1]
		axis[:cmax] = limits[2]
	elseif opts.cmid !== nothing
		axis[:cmid] = opts.cmid
	end
	axis[:showscale] = true
	bar = _symbol_dict(get(axis, :colorbar, nothing))
	range = limits !== nothing ? limits : _cbar_coloraxis_range(p, id)
	_shared_colorbar_fill_bar!(p, bar, placement, carried, opts, id, range)
	_cbar_store_coloraxis!(p, id, axis, bar)
	return nothing
end

# Geometry, carried settings and title of the shared bar `bar`, whose title
# annotation (for a math title) is named after `key`.
function _shared_colorbar_fill_bar!(p::Plot, bar::Dict{Symbol,Any}, placement, carried, opts, key, range)
	# Settings already on the shared bar win over those carried from the
	# removed per-trace bars.
	for (name, value) in carried.settings
		haskey(bar, name) || (bar[name] = value)
	end
	merge!(bar, placement)
	haskey(bar, :thickness) || (bar[:thickness] = _CBAR_CELL_THICKNESS)
	_cbar_apply_ticks!(bar, opts.ticks, opts.ticklabels)
	title, title_side = opts.title, opts.title_side
	if title === nothing && carried.title !== nothing &&
			_cbar_title_text(bar) === nothing &&
			_cbar_find_title_annotation(p, key) === nothing
		title, title_side = carried.title.text, carried.title.side
	end
	_cbar_apply_title!(p, bar, key, title, title_side, true, range)
	return bar
end

# (min, max) over the colour limits of all `slots`: a member's explicit
# limits (`zmin`/`zmax`, `cmin`/`cmax`, or those of the coloraxis it is bound
# to) where it has them, else the finite extrema of its colour data; `nothing`
# when plotly computes a member's data without explicit limits (histogram
# counts, …) or the result is constant/empty.
function _shared_colorbar_data_range(p::Plot, slots::Vector{_CbarSlot})
	lo = Inf
	hi = -Inf
	for slot in slots
		trace = p.data[slot.index]
		part = _cbar_slot_explicit_limits(p, trace, slot)
		if part === nothing
			values = _cbar_slot_values(trace, slot)
			values === nothing && return nothing
			part = _cbar_extrema(values)
			part === nothing && continue
		end
		lo = min(lo, part[1])
		hi = max(hi, part[2])
	end
	return (isfinite(lo) && lo < hi) ? (lo, hi) : nothing
end

# Explicit colour limits of a slot: `zmin`/`zmax` or `cmin`/`cmax` on the
# trace (or its marker/line), else `cmin`/`cmax` of the coloraxis it is bound
# to; `nothing` when the limits are automatic.
function _cbar_slot_explicit_limits(p::Plot, trace::GenericTrace, slot::_CbarSlot)
	source = slot.container === :root ?
		trace.fields :
		_symbol_dict(get(trace.fields, slot.container, nothing))
	for (lo_key, hi_key) in ((:zmin, :zmax), (:cmin, :cmax))
		lo = _cbar_real(source, lo_key, nothing)
		hi = _cbar_real(source, hi_key, nothing)
		(lo !== nothing && hi !== nothing && lo < hi) && return (lo, hi)
	end
	if slot.coloraxis !== nothing
		axis = _symbol_dict(get(p.layout.fields, Symbol(slot.coloraxis), nothing))
		lo = _cbar_real(axis, :cmin, nothing)
		hi = _cbar_real(axis, :cmax, nothing)
		(lo !== nothing && hi !== nothing && lo < hi) && return (lo, hi)
	end
	return nothing
end

# Contours coloured by band or line (`contours.coloring` "fill", the
# default, or "lines"). plotly.js 2.35.2 derives a contour's colour limits
# from its own levels and writes them back to a coloraxis it is bound to, so
# such contours on a shared coloraxis are drawn with wrong colours (and a
# heatmap on the same axis loses the axis' scale). They keep their own
# colour settings instead: the shared scale, `zmin`/`zmax` = the shared
# limits, no bar of their own.
function _cbar_is_banded_contour(trace::GenericTrace, slot::_CbarSlot)
	slot.container === :root || return false
	_cbar_trace_type(trace) in _CBAR_CONTOUR_TYPES || return false
	coloring = _cmn_mapping_get(get(trace.fields, :contours, nothing), :coloring)
	(coloring isa AbstractString || coloring isa Symbol) || return true
	return String(coloring) in ("fill", "lines")
end

function _cbar_set_banded_scale!(trace::GenericTrace, scale, limits)
	fields = trace.fields
	delete!(fields, :coloraxis)
	delete!(fields, :colorbar)
	fields[:showscale] = false
	fields[:colorscale] = scale.scale
	if scale.reversescale
		fields[:reversescale] = true
	else
		delete!(fields, :reversescale)
	end
	delete!(fields, :zmid)
	fields[:zauto] = false
	fields[:zmin] = limits[1]
	fields[:zmax] = limits[2]
	return nothing
end

# The colour scale plotly gives a trace of type `type_name` that sets none:
# the template's default for that trace type, else the template's
# `layout.colorscale.sequential`. Without a template plotly's own default is
# not known here, so Viridis is used; any explicit scale keeps the contours
# and the coloraxis in agreement, which is what matters.
function _cbar_default_scale(p::Plot, type_name::String)
	template = get(p.layout.fields, :template, nothing)
	if template isa PlotlyBase.Template
		defaults = get(template.data, Symbol(type_name), nothing)
		if defaults isa AbstractVector && !isempty(defaults)
			scale = _cmn_mapping_get(first(defaults), :colorscale)
			_is_unset_colorscale(scale) || return scale
		end
		sequential = _cmn_mapping_get(
			get(_template_layout_fields(template), :colorscale, nothing),
			:sequential,
		)
		_is_unset_colorscale(sequential) || return sequential
	end
	return _resolve_colorscale("viridis"; who = "shared_colorbar!").scale
end

# The coloured traces `shared_colorbar!` binds among `indices`: flat-coloured
# traces (see `_cbar_slot_is_flat`) are left alone.
function _shared_colorbar_slots(p::Plot, indices, who::AbstractString, empty_message::AbstractString)
	slots = _CbarSlot[]
	for index in indices
		slot = _cbar_slot(p.data[index], index)
		slot === nothing && continue
		_cbar_slot_is_flat(p.data[index], slot) && continue
		push!(slots, slot)
	end
	isempty(slots) && throw(ArgumentError("$(who): $(empty_message)"))
	return slots
end

function _shared_colorbar_impl!(
	fig;
	cells = :all,
	options...,
)
	who = "shared_colorbar!"
	cells === :all || throw(ArgumentError(
		"$(who): `cells` selects SubplotFigure cells; a single figure has one " *
		"cell, so omit it (or pass :all).",
	))
	opts = _shared_colorbar_options(who; options...)
	p = _plot_obj(fig)
	slots = _shared_colorbar_slots(
		p,
		eachindex(p.data),
		who,
		"the figure has no coloured trace $(_CBAR_NO_COLOUR_HINT).",
	)
	regions = Any[]
	for slot in slots
		_cbar_push_region!(regions, _cbar_trace_region(p, p.data[slot.index]))
	end
	_shared_colorbar_apply!(p, slots, regions, opts, who)
	_refresh!(fig)
	return nothing
end

function _shared_colorbar_cells(sf::SubplotFigure, cells, who::AbstractString)
	cells === :all && return :all
	(cells isa AbstractVector || cells isa Tuple) || throw(ArgumentError(
		"$(who): `cells` must be :all or a vector of (row, col) tuples; got " *
		"$(repr(cells)).",
	))
	isempty(cells) && throw(ArgumentError("$(who): `cells` must not be empty."))
	out = Tuple{Int,Int}[]
	for cell in cells
		(cell isa Tuple && length(cell) == 2 &&
			all(v -> v isa Integer && !(v isa Bool), cell)) || throw(ArgumentError(
			"$(who): every entry of `cells` must be a (row, col) tuple of " *
			"integers; got $(repr(cell)).",
		))
		r, c = Int(cell[1]), Int(cell[2])
		(1 <= r <= sf.rows && 1 <= c <= sf.cols) || throw(ArgumentError(
			"$(who): cell ($(r), $(c)) is outside the $(sf.rows)×$(sf.cols) grid.",
		))
		(r, c) in out || push!(out, (r, c))
	end
	return out
end

function _shared_colorbar_subplot_impl!(
	sf::SubplotFigure;
	cells = :all,
	options...,
)
	who = "shared_colorbar!"
	selected = _shared_colorbar_cells(sf, cells, who)
	opts = _shared_colorbar_options(who; options...)
	p = _plot_obj(sf.fig)
	regions = Any[]
	if selected === :all
		slots = _shared_colorbar_slots(
			p,
			eachindex(p.data),
			who,
			"the figure has no coloured trace $(_CBAR_NO_COLOUR_HINT).",
		)
		for slot in slots
			_cbar_push_region!(regions, _cbar_trace_region(p, p.data[slot.index]))
		end
	else
		for (r, c) in selected
			target = _cell_target(sf; row = r, col = c, who = who)
			push!(regions, (
				key = "cell:$(r):$(c)",
				xdomain = target.xdomain,
				ydomain = target.ydomain,
			))
		end
		slots = _shared_colorbar_slots(
			p,
			_cbar_cell_trace_indices(sf, p, selected, who),
			who,
			"the selected cells have no coloured trace $(_CBAR_NO_COLOUR_HINT).",
		)
	end
	_shared_colorbar_apply!(p, slots, regions, opts, who)
	_refresh!(sf.fig)
	return sf
end

"""
	shared_colorbar!(fig; colorscale="", crange=[0, 0], cmid=nothing, title="",
		title_side=:top, len=0.75, side=:right, coloraxis="coloraxis",
		ticks=nothing, ticklabels=nothing)
	shared_colorbar!(sf::SubplotFigure; cells=:all, ...)

Give several panels one colour scale and one colorbar. Every colour-mapped
trace — heatmap, contour, surface, mesh3d with `intensity`, histogram2d,
volume, cone, choropleth, …, traces with a numeric `marker.color`/
`line.color`, and invisible colorbar carrier traces — of the selected cells
(including their insets) is bound to the shared `coloraxis`, and its own
`showscale`/colorbar are removed. Flat-coloured traces (a colour scale with
one colour, e.g. `plot_quiver3d(...; color="red")` cones) and contours with
`contours.coloring = "none"` are left as they are.

The removed bars' settings carry over to the shared bar unless it already
has them: the first bar's number format, thickness, … and title (unless
`title` is given), and the union of all bars' explicit ticks (so log-scaled
panels keep their decade labels).

Filled and line contours (`contours.coloring` `"fill"`, the default, or
`"lines"`) are not bound to the coloraxis: plotly.js 2.35 recomputes a bound
contour's colour limits from its levels, which miscolours the contours and
every heatmap on the same axis. They get the shared scale, `zmin`/`zmax` =
the shared limits and no bar of their own instead, so they match the shared
bar; contours of plotly-computed data (`histogram2dcontour`) therefore need
an explicit `crange`. When only such contours are selected, the first one
draws the shared bar and `layout.<coloraxis>` is not used.

Colorbar carrier traces (polygon fills, binned streamlines, … whose colours
were sampled in Julia) cannot be recoloured: with an automatic `crange` and
`colorscale` the shared bar uses the limits and scale they were drawn with,
and a different explicit `crange`/`colorscale`, a `cmid`, or carriers drawn
with different limits or scales throw an `ArgumentError`.

# Keywords
- `cells=:all` (SubplotFigure only): `:all`, or a vector of `(row, col)`
  tuples.
- `colorscale=""`: any colour scale `colormap` accepts; `""` keeps the scale
  of the carriers, else of the first trace that sets one, else the scale the
  traces were drawn with (the template's default for the first trace's type,
  else its sequential scale; written out so binding does not switch the
  panels to plotly's automatic diverging palette).
- `crange=[0, 0]`: colour limits `[cmin, cmax]` (increasing). `[0, 0]` uses
  the carriers' limits, else the global finite min/max of the traces' colour
  data (z, surfacecolor, intensity, value, cone norms, marker colours); when
  a trace's colour data is computed by plotly (histogram2d counts,
  streamtube magnitudes) the limits are left to plotly, which ranges a
  coloraxis over every bound trace.
- `cmid=nothing`: with an automatic `crange`, the centre of the colour range
  (plotly `cmid`; with filled contours selected the centred range, `cmid` ±
  the largest distance to the data, is written out as `cmin`/`cmax`). With an
  explicit `crange` it must lie strictly inside it (`ArgumentError`
  otherwise) and remaps the colour scale in two slopes (as `cmid` does for a
  single trace): the scale's middle colour sits at `cmid`.
- `title=""`, `title_side=:top`: bar title (mathtext) and its side, as in
  [`colorbar!`](@ref) (math titles become an annotation).
- `len::Real=0.75`: bar length as a fraction of the selected cells' extent.
- `side::Symbol=:right`: `:right` puts a vertical bar right of the
  right-most selected cells, centred on the cells' vertical extent;
  `:bottom` a horizontal bar below the lowest cells' x tick labels and
  titles, centred on their horizontal extent. Room for the bar is reserved
  (see [`colorbar!`](@ref)).
- `coloraxis="coloraxis"`: the shared axis id (`:shared` means
  `"coloraxis"`; `"coloraxis2"`, … are allowed).
- `ticks=nothing`, `ticklabels=nothing`: tick values in colour units and
  their labels (requires `ticks`, same length), as in [`colorbar!`](@ref);
  they replace the ticks carried over from the removed bars.

No coloured trace in the selection is an `ArgumentError`. The call is
validated first and applied in one transaction. Returns `nothing` for a
`Plot`/`SyncPlot` and `sf` for a `SubplotFigure`.
`plot_surface(...; shared_coloraxis=true)` remains an alias for binding
surfaces to `"coloraxis"`.

# Example
```julia
sf = subplots(1, 3; sync=false)
for c in 1:3
	plot_heatmap!(sf, c .* rand(20, 20); row=1, col=c)
end
shared_colorbar!(sf; title="Intensity", colorscale="viridis")
```
"""
function shared_colorbar!(
	fig::Union{Plot,SyncPlot};
	cells = :all,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	title::AbstractString = "",
	title_side::Symbol = :top,
	len::Real = 0.75,
	side::Symbol = :right,
	coloraxis::Union{AbstractString,Symbol} = "coloraxis",
	ticks = nothing,
	ticklabels = nothing,
	kwargs...,
)
	_cbar_reject_keywords("shared_colorbar!", kwargs,
		"a single figure has one cell; omit the cell keywords")
	# One colour-range scan per array for the call and its finalizer (Z83).
	return _cbar_with_extrema_memo(() -> _transactional_high_level_plot_mutation!(
		_shared_colorbar_impl!,
		fig;
		cells, colorscale, crange, cmid, title, title_side, len, side, coloraxis, ticks, ticklabels,
	))
end

function shared_colorbar!(
	sf::SubplotFigure;
	cells = :all,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	title::AbstractString = "",
	title_side::Symbol = :top,
	len::Real = 0.75,
	side::Symbol = :right,
	coloraxis::Union{AbstractString,Symbol} = "coloraxis",
	ticks = nothing,
	ticklabels = nothing,
	kwargs...,
)
	_cbar_reject_keywords("shared_colorbar!", kwargs,
		"select cells with `cells=[(row, col), …]`")
	# One colour-range scan per array for the call and its finalizer (Z83).
	return _cbar_with_extrema_memo(() -> _transactional_subplot_mutation!(
		_shared_colorbar_subplot_impl!,
		sf,
		();
		cells, colorscale, crange, cmid, title, title_side, len, side, coloraxis, ticks, ticklabels,
	))
end
