# Figure-level normalisation applied after PlotlySupply builds or mutates a
# figure: fixes that depend on the whole figure rather than on one call.
#
# `_finalize_figure!(fig)` is idempotent, never overrides an explicit user
# setting, reads the figure through `_plot_layout`/`_plot_obj` and writes only
# through `relayout!`, so it works on a `Plot`, a `SyncPlot` and the staged
# figures used inside PlotlySupply's transactions.

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
		seen = Set{Symbol}((key,))
		root = target
		while true
			root in seen && (root = nothing; break)
			push!(seen, root)
			next = _fin_axis_key(_fin_field(get(fields, root, nothing), :matches))
			next === nothing && break
			root = next
		end
		root === nothing || push!(roots, root)
	end
	return roots
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

"""
	_finalize_figure!(fig) -> nothing

Normalise the figure after a PlotlySupply constructor or mutator changed it.
Currently: every root axis of a shared-axis (`matches`) group that has neither
a range nor an `autorange` entry gets `autorange = true`, which keeps
plotly.js from collapsing the group to its empty-axis range when another group
has a fixed range. Explicit ranges and `autorange` values are never changed.
"""
function _finalize_figure!(fig)
	updates = _fin_match_group_updates(_plot_layout(fig))
	isempty(updates) || relayout!(fig; updates...)
	return nothing
end
