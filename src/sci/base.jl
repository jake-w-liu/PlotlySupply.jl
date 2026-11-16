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
