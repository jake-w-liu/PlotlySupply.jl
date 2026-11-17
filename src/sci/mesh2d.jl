# PlotlySupply 2.0 scientific-plotting extensions: plot_polygons, plot_pcolormesh, plot_tripcolor, plot_triplot, plot_tricontour.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_MESH2D_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# How a per-cell coloured mesh is drawn (spec F22-F25):
# - Colours are computed in Julia: the cell values go through
#   `_apply_color_norm` (crange / cmid / colornorm / levels) and are quantised
#   into `ncolors` bins (or the `levels` bands). Every non-empty bin becomes ONE
#   `scatter` trace with `fill = "toself"` whose polygon rings are separated by
#   `_GAP` (JSON null), so the trace count is bounded by `ncolors` while the
#   payload stays O(vertices).
# - An invisible carrier scatter (`_colorbar_carrier_trace`) draws the colour
#   bar with the same stops and limits the cells were sampled from.
# - Raster paths (`plot_pcolormesh` on a rectilinear grid, `plot_tripcolor`
#   with `shading = :gouraud`) emit one `heatmap` trace mapped by plotly
#   through the same stops and limits.
# - Line paths (`plot_triplot`, `plot_tricontour`) emit `_GAP`-separated
#   `scatter` lines.
#
# SubplotFigure methods delegate through `_subplot_delegate_mutator!`. The
# delegate runs the mutator on an empty scratch figure, so `_mesh2d_subplot!`
# first copies into that scratch what the mutator must read from the target
# cell (its axis types, the figure's colour axes) and tells it the cell's x
# axis id for the equal-aspect anchor and the cell's default trace colour.

const _SCI_MESH2D_MUTATORS = (
	:plot_polygons!,
	:plot_pcolormesh!,
	:plot_tripcolor!,
	:plot_triplot!,
	:plot_tricontour!,
)

export plot_polygons, plot_polygons!, plot_pcolormesh, plot_pcolormesh!
export plot_tripcolor, plot_tripcolor!, plot_triplot, plot_triplot!
export plot_tricontour, plot_tricontour!

# matplotlib's default colormap; spec F22 makes it the default of the mesh
# family (`""` selects the figure template's sequential colorscale instead).
const _MESH2D_DEFAULT_COLORSCALE = "Viridis"

# Each non-empty colour bin is one plotly trace. 1024 bins already exceed the
# number of distinguishable steps along any 8-bit sRGB colormap path (at most
# 3 x 255 channel changes); more bins only add traces and export time.
const _MESH2D_MAX_NCOLORS = 1024

# Width (px) of the stroke drawn in each cell's own fill colour when
# `edgewidth == 0`. Adjacent anti-aliased SVG fills leave hairline seams of
# background between cells; a sub-pixel stroke in the fill colour closes them
# (checked by eye on exported PNGs, see test/sci_mesh2d.jl notes).
const _MESH2D_SEAM_WIDTH = 0.5

# Upper bound of the gouraud raster's longer side (pixels). 2048^2 cells is a
# ~4 Mpx heatmap whose JSON payload is already tens of MB; larger rasters
# exceed what the export renderer handles in reasonable time.
const _MESH2D_MAX_RESOLUTION = 2048

# Size (px) of the invisible hover markers placed at cell centroids. Hover
# picking uses plotly's `hoverdistance`, not the marker size.
const _MESH2D_HOVER_MARKER_SIZE = 4

# plotly.js `line.dash` names, plus the matplotlib shorthands.
const _MESH2D_DASH_NAMES = ("solid", "dot", "dash", "longdash", "dashdot", "longdashdot")
const _MESH2D_DASH_ALIASES = Dict("-" => "solid", "--" => "dash", ":" => "dot", "-." => "dashdot")
const _MESH2D_DASH_LIST = r"^\s*\d+(\.\d+)?(px|%)?(\s*,\s*\d+(\.\d+)?(px|%)?)*\s*$"

const _MESH2D_COLORAXIS_KEY = r"^coloraxis([2-9]|[1-9][0-9]+)?$"

# ---------------------------------------------------------------------------
# Drawing target
# ---------------------------------------------------------------------------

# What a mesh mutator needs to know beyond the figure it writes to. On a plain
# Plot/SyncPlot every field is `nothing` (everything is read from `fig`). The
# SubplotFigure path fills it from the target cell because the mutator runs on
# the delegate's empty scratch figure:
# - `anchor_xref`: x axis id the equal-aspect `scaleanchor` must name;
# - `color_index`: 1-based position of the new uniform-colour trace in the
#   cell's colour cycle;
# - `defaults`: the layout whose template supplies default colours/scales;
# - `coloraxis_write`: set by the mutator to the colour-axis fields it wrote,
#   so the SubplotFigure path can publish colour axes the delegate does not
#   transplant (it copies only `layout.coloraxis`).
mutable struct _Mesh2dTarget
	anchor_xref::Union{Nothing, String}
	color_index::Union{Nothing, Int}
	defaults::Any
	coloraxis_write::Union{Nothing, Tuple{String, Dict{Symbol, Any}}}
end

_Mesh2dTarget() = _Mesh2dTarget(nothing, nothing, nothing, nothing)

# ---------------------------------------------------------------------------
# Keyword and scalar validation
# ---------------------------------------------------------------------------

function _mesh2d_reject_extra(who::AbstractString, extra)
	isempty(extra) && return nothing
	names = collect(keys(extra))
	:show in names && throw(ArgumentError(
		"$(who): mutators do not take `show`; the mesh is added to the figure " *
		"you pass (display it, or call `to_syncplot(fig)` for a window).",
	))
	for name in (:row, :col, :secondary_y)
		name in names && throw(ArgumentError(
			"$(who): `$(name)` selects a SubplotFigure cell; a Plot or SyncPlot " *
			"has a single cell, so omit it.",
		))
	end
	throw(ArgumentError(
		"$(who): unsupported keyword argument(s) " *
		"$(join(("`$(name)`" for name in names), ", ")).",
	))
end

_mesh2d_is_real(v) = v isa Real && !(v isa Bool)

function _mesh2d_bool(value, who::AbstractString, name::AbstractString)
	value isa Bool || throw(ArgumentError(
		"$(who): `$(name)` must be true or false; got $(repr(value)).",
	))
	return value
end

function _mesh2d_optional_bool(value, who::AbstractString, name::AbstractString)
	(value === nothing || value isa Bool) || throw(ArgumentError(
		"$(who): `$(name)` must be true, false or nothing; got $(repr(value)).",
	))
	return value
end

function _mesh2d_nonnegative(value, who::AbstractString, name::AbstractString)
	(_mesh2d_is_real(value) && isfinite(value) && value >= 0) || throw(ArgumentError(
		"$(who): `$(name)` must be a finite number >= 0; got $(repr(value)).",
	))
	return Float64(value)
end

function _mesh2d_opacity(value, who::AbstractString)
	(_mesh2d_is_real(value) && isfinite(value) && 0 <= value <= 1) || throw(ArgumentError(
		"$(who): `opacity` must be a number in [0, 1]; got $(repr(value)).",
	))
	return Float64(value)
end

function _mesh2d_text(value, who::AbstractString, name::AbstractString)
	value isa AbstractString || throw(ArgumentError(
		"$(who): `$(name)` must be a string; got $(repr(value)).",
	))
	return value
end

# Colour keyword: "" = automatic; "face"/"none" (matplotlib) = the cell's own
# fill colour; anything else is parsed (so typos raise) and normalised.
function _mesh2d_color(value, who::AbstractString, name::AbstractString; allow_face::Bool = false)
	(value isa AbstractString || value isa Symbol) || throw(ArgumentError(
		"$(who): `$(name)` must be a colour string or Symbol; got $(repr(value)).",
	))
	text = strip(String(value))
	isempty(text) && return ""
	if allow_face && lowercase(text) in ("face", "none")
		return ""
	end
	return _color_hex(text; who = "$(who) (`$(name)`)")
end

function _mesh2d_dash(value, who::AbstractString)
	(value isa AbstractString || value isa Symbol) || throw(ArgumentError(
		"$(who): `dash` must be a string; got $(repr(value)).",
	))
	text = strip(String(value))
	isempty(text) && return ""
	haskey(_MESH2D_DASH_ALIASES, text) && return _MESH2D_DASH_ALIASES[text]
	lowercase(text) in _MESH2D_DASH_NAMES && return lowercase(text)
	occursin(_MESH2D_DASH_LIST, text) && return String(text)
	throw(ArgumentError(
		"$(who): unknown `dash` $(repr(String(value))); use one of " *
		"$(join(repr.(_MESH2D_DASH_NAMES), ", ")), a matplotlib code " *
		"(\"-\", \"--\", \":\", \"-.\") or a dash length list such as \"5px,3px\".",
	))
end

function _mesh2d_ncolors(value, who::AbstractString)
	(value isa Integer && !(value isa Bool) && 1 <= value <= _MESH2D_MAX_NCOLORS) || throw(ArgumentError(
		"$(who): `ncolors` must be an integer in 1:$(_MESH2D_MAX_NCOLORS); got $(repr(value)).",
	))
	return Int(value)
end

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

# Cells as closed polygon rings: ring `i` holds the vertices
# `x[offsets[i]:(offsets[i+1] - 1)]` (first vertex not repeated).
struct _Mesh2dRings
	x::Vector{Float64}
	y::Vector{Float64}
	offsets::Vector{Int}
end

_mesh2d_ncells(r::_Mesh2dRings) = length(r.offsets) - 1

# Node coordinates: finite real numbers.
function _mesh2d_coords(v, who::AbstractString, name::AbstractString)
	(v isa AbstractVector || v isa Tuple) || throw(ArgumentError(
		"$(who): `$(name)` must be a vector of finite numbers; got $(typeof(v)).",
	))
	out = Vector{Float64}(undef, length(v))
	for (i, x) in enumerate(v)
		(_mesh2d_is_real(x) && isfinite(x)) || throw(ArgumentError(
			"$(who): `$(name)` must contain finite real numbers; entry $(i) is $(repr(x)).",
		))
		out[i] = Float64(x)
	end
	return out
end

# One node index of a connectivity entry, 1-based. Integral floats (as read
# from text files) are accepted; anything else is an error.
@inline function _mesh2d_index(v, nnodes::Int, who::AbstractString, name::AbstractString, cell::Int)
	index = if v isa Integer && !(v isa Bool)
		v
	elseif _mesh2d_is_real(v) && isfinite(v) && isinteger(v)
		Int(v)
	else
		throw(ArgumentError(
			"$(who): `$(name)` must hold integer node indices; cell $(cell) has $(repr(v)).",
		))
	end
	if !(1 <= index <= nnodes)
		hint = index == 0 ? " Indices are 1-based (add 1 to 0-based connectivity)." : ""
		throw(ArgumentError(
			"$(who): `$(name)` cell $(cell) refers to node $(index), outside 1:$(nnodes).$(hint)",
		))
	end
	return Int(index)
end

# Connectivity as a flat index list plus offsets. `cells` is an `ncells x k`
# matrix or a vector of index vectors/tuples. `arity` fixes `k` (3 for
# triangles); otherwise every cell needs at least 3 nodes.
function _mesh2d_connectivity(
	cells,
	nnodes::Int,
	who::AbstractString;
	name::AbstractString = "cells",
	arity::Union{Nothing, Int} = nothing,
)
	if cells isa AbstractMatrix
		ncells, k = size(cells)
		if arity !== nothing && k != arity
			hint = size(cells, 1) == arity ? " (got $(ncells)x$(k); pass the transpose)" : ""
			throw(ArgumentError(
				"$(who): `$(name)` must be an N x $(arity) matrix of node indices; got size $(size(cells))$(hint).",
			))
		end
		ncells == 0 || k >= 3 || throw(ArgumentError(
			"$(who): every cell needs at least 3 nodes; `$(name)` has $(k) column(s).",
		))
		indices = Vector{Int}(undef, ncells * k)
		pos = 0
		for i in 1:ncells, j in 1:k
			pos += 1
			indices[pos] = _mesh2d_index(cells[i, j], nnodes, who, name, i)
		end
		offsets = collect(1:k:(ncells * k + 1))
		return indices, offsets
	elseif cells isa AbstractVector
		offsets = Vector{Int}(undef, length(cells) + 1)
		offsets[1] = 1
		total = 0
		for (i, cell) in enumerate(cells)
			(cell isa AbstractVector || cell isa Tuple) || throw(ArgumentError(
				"$(who): `$(name)` entry $(i) must be a vector of node indices; got $(typeof(cell)).",
			))
			k = length(cell)
			if arity !== nothing
				k == arity || throw(ArgumentError(
					"$(who): `$(name)` entry $(i) has $(k) nodes; every cell needs exactly $(arity).",
				))
			else
				k >= 3 || throw(ArgumentError(
					"$(who): `$(name)` entry $(i) has $(k) node(s); every cell needs at least 3.",
				))
			end
			total += k
			offsets[i + 1] = total + 1
		end
		indices = Vector{Int}(undef, total)
		pos = 0
		for (i, cell) in enumerate(cells), v in cell
			pos += 1
			indices[pos] = _mesh2d_index(v, nnodes, who, name, i)
		end
		return indices, offsets
	end
	throw(ArgumentError(
		"$(who): `$(name)` must be an N x k integer matrix or a vector of index vectors; got $(typeof(cells)).",
	))
end

function _mesh2d_rings_from_nodes(x::Vector{Float64}, y::Vector{Float64}, indices::Vector{Int}, offsets::Vector{Int})
	return _Mesh2dRings(x[indices], y[indices], offsets)
end

# Explicit polygons: `px[i]`, `py[i]` are the vertex coordinates of polygon i.
function _mesh2d_rings_from_polygons(px::AbstractVector, py::AbstractVector, who::AbstractString)
	length(px) == length(py) || throw(ArgumentError(
		"$(who): `px` has $(length(px)) polygons but `py` has $(length(py)).",
	))
	offsets = Vector{Int}(undef, length(px) + 1)
	offsets[1] = 1
	total = 0
	for i in eachindex(px, py)
		a, b = px[i], py[i]
		((a isa AbstractVector || a isa Tuple) && (b isa AbstractVector || b isa Tuple)) || throw(ArgumentError(
			"$(who): polygon $(i) must be given as two coordinate vectors; got $(typeof(a)) and $(typeof(b)).",
		))
		length(a) == length(b) || throw(ArgumentError(
			"$(who): polygon $(i) has $(length(a)) x and $(length(b)) y coordinates.",
		))
		length(a) >= 3 || throw(ArgumentError(
			"$(who): polygon $(i) has $(length(a)) vertices; a polygon needs at least 3.",
		))
		total += length(a)
		offsets[i + 1] = total + 1
	end
	xs = Vector{Float64}(undef, total)
	ys = Vector{Float64}(undef, total)
	pos = 0
	for i in eachindex(px, py)
		for (u, v) in zip(px[i], py[i])
			(_mesh2d_is_real(u) && isfinite(u) && _mesh2d_is_real(v) && isfinite(v)) || throw(ArgumentError(
				"$(who): polygon $(i) has a non-finite or non-real vertex ($(repr(u)), $(repr(v))).",
			))
			pos += 1
			xs[pos] = Float64(u)
			ys[pos] = Float64(v)
		end
	end
	return _Mesh2dRings(xs, ys, offsets)
end

function _mesh2d_check_log(values::AbstractVector{Float64}, axis_type::AbstractString, who::AbstractString, letter::Char)
	axis_type == "log" || return nothing
	for v in values
		v > 0 || throw(ArgumentError(
			"$(who): the $(letter) axis is logarithmic, so every $(letter) coordinate must be positive; got $(v).",
		))
	end
	return nothing
end

# Mask of drawn triangles: `nothing` (all) or one Bool per triangle (`true`
# hides it, as in matplotlib).
function _mesh2d_mask(mask, ncells::Int, who::AbstractString)
	mask === nothing && return nothing
	(mask isa AbstractVector && all(m -> m isa Bool, mask)) || throw(ArgumentError(
		"$(who): `mask` must be nothing or a vector of Bool (true hides a triangle); got $(typeof(mask)).",
	))
	length(mask) == ncells || throw(ArgumentError(
		"$(who): `mask` has $(length(mask)) entries for $(ncells) triangles.",
	))
	return BitVector(mask)
end

# Keep the cells whose mask entry is false.
function _mesh2d_select_cells(indices::Vector{Int}, offsets::Vector{Int}, keep)
	keep === nothing && return indices, offsets
	new_indices = Int[]
	new_offsets = Int[1]
	for i in eachindex(keep)
		keep[i] || continue
		append!(new_indices, view(indices, offsets[i]:(offsets[i + 1] - 1)))
		push!(new_offsets, length(new_indices) + 1)
	end
	return new_indices, new_offsets
end

# Area centroid of every ring (vertex mean for a degenerate ring).
function _mesh2d_centroids(r::_Mesh2dRings)
	n = _mesh2d_ncells(r)
	cx = Vector{Float64}(undef, n)
	cy = Vector{Float64}(undef, n)
	for i in 1:n
		lo, hi = r.offsets[i], r.offsets[i + 1] - 1
		# Shift to the first vertex: keeps the shoelace sums well conditioned
		# for cells far from the origin.
		x0, y0 = r.x[lo], r.y[lo]
		area = 0.0
		sx = 0.0
		sy = 0.0
		mx = 0.0
		my = 0.0
		scale = 0.0
		for k in lo:hi
			k1 = k == hi ? lo : k + 1
			xa, ya = r.x[k] - x0, r.y[k] - y0
			xb, yb = r.x[k1] - x0, r.y[k1] - y0
			cross = xa * yb - xb * ya
			area += cross
			sx += (xa + xb) * cross
			sy += (ya + yb) * cross
			mx += xa
			my += ya
			scale = max(scale, abs(xa), abs(ya))
		end
		nv = hi - lo + 1
		if abs(area) > 1e-12 * max(scale, eps())^2
			cx[i] = x0 + sx / (3 * area)
			cy[i] = y0 + sy / (3 * area)
		else
			cx[i] = x0 + mx / nv
			cy[i] = y0 + my / nv
		end
	end
	return cx, cy
end

# Ring coordinates grouped by `groups[i]` (0 = not drawn): each ring is closed
# by repeating its first vertex (so the stroke draws the last edge) and rings
# are separated by `_GAP`. O(vertices).
function _mesh2d_group_coords(r::_Mesh2dRings, groups::AbstractVector{Int}, ngroups::Int)
	counts = zeros(Int, ngroups)
	lengths = zeros(Int, ngroups)
	for i in 1:_mesh2d_ncells(r)
		g = groups[i]
		g == 0 && continue
		counts[g] += 1
		lengths[g] += r.offsets[i + 1] - r.offsets[i] + 1
	end
	xs = Vector{Vector{Union{Nothing, Float64}}}(undef, ngroups)
	ys = Vector{Vector{Union{Nothing, Float64}}}(undef, ngroups)
	for g in 1:ngroups
		total = counts[g] == 0 ? 0 : lengths[g] + counts[g] - 1
		xs[g] = Vector{Union{Nothing, Float64}}(undef, total)
		ys[g] = Vector{Union{Nothing, Float64}}(undef, total)
	end
	pos = zeros(Int, ngroups)
	for i in 1:_mesh2d_ncells(r)
		g = groups[i]
		g == 0 && continue
		X = xs[g]
		Y = ys[g]
		p = pos[g]
		if p > 0
			p += 1
			X[p] = _GAP
			Y[p] = _GAP
		end
		lo, hi = r.offsets[i], r.offsets[i + 1] - 1
		for k in lo:hi
			p += 1
			X[p] = r.x[k]
			Y[p] = r.y[k]
		end
		p += 1
		X[p] = r.x[lo]
		Y[p] = r.y[lo]
		pos[g] = p
	end
	return xs, ys, counts
end

# Unique undirected edges of the given cells as one `_GAP`-separated polyline
# set: `(x, y, nedges)`.
function _mesh2d_unique_edges(x::Vector{Float64}, y::Vector{Float64}, indices::Vector{Int}, offsets::Vector{Int})
	nnodes = length(x)
	keys_ = Vector{Int}(undef, length(indices))
	n = 0
	for i in 1:(length(offsets) - 1)
		lo, hi = offsets[i], offsets[i + 1] - 1
		for k in lo:hi
			a = indices[k]
			b = indices[k == hi ? lo : k + 1]
			a == b && continue
			u, v = minmax(a, b)
			n += 1
			keys_[n] = (u - 1) * nnodes + (v - 1)
		end
	end
	resize!(keys_, n)
	sort!(keys_)
	unique!(keys_)
	ne = length(keys_)
	ex = Vector{Union{Nothing, Float64}}(undef, max(3 * ne - 1, 0))
	ey = Vector{Union{Nothing, Float64}}(undef, max(3 * ne - 1, 0))
	p = 0
	for (j, key) in enumerate(keys_)
		u = key ÷ nnodes + 1
		v = key % nnodes + 1
		if j > 1
			p += 1
			ex[p] = _GAP
			ey[p] = _GAP
		end
		p += 1
		ex[p] = x[u]
		ey[p] = y[u]
		p += 1
		ex[p] = x[v]
		ey[p] = y[v]
	end
	return ex, ey, ne
end

# ---------------------------------------------------------------------------
# Colour mapping
# ---------------------------------------------------------------------------

# Everything needed to colour cells (Julia-sampled bins) or a heatmap (plotly
# mapping) consistently with one colour bar.
struct _Mesh2dColourMap
	tvals::Vector{Float64}                       # colour value per entry (log10 under :log), NaN = not drawn
	cmin::Union{Nothing, Float64}                # colour limits in colour units, `nothing` = no finite data
	cmax::Union{Nothing, Float64}
	stops::Vector{Vector{Any}}                   # colorscale the colours are sampled from
	band_edges::Union{Nothing, Vector{Float64}}  # `levels` boundaries in colour units
	log::Bool
	coloraxis::Union{Nothing, String}
	showscale::Bool
	colorbar::Any                                # attr(...) or nothing
end

_mesh2d_layout_source(fig, target::_Mesh2dTarget) =
	target.defaults === nothing ? fig : target.defaults

# Expanded stops of a colorscale keyword; `""` selects the figure template's
# heatmap colorscale.
function _mesh2d_stops(colorscale, source, who::AbstractString)
	if _is_unset_colorscale(colorscale)
		layout = _colour_layout(source)
		template_source = haskey(layout.fields, :template) ? layout : nothing
		return _template_colorscale(template_source)
	end
	return _colorscale_stops(colorscale; who = who)
end

# Explicit numeric limits already stored on a colour axis, or `nothing`.
function _mesh2d_coloraxis_limits(fig, id::String)
	axis = get(_plot_layout(fig).fields, Symbol(id), nothing)
	axis === nothing && return nothing
	lo = _cmn_mapping_get(axis, :cmin)
	hi = _cmn_mapping_get(axis, :cmax)
	(_mesh2d_is_real(lo) && _mesh2d_is_real(hi) && isfinite(lo) && isfinite(hi) && lo < hi) ||
		return nothing
	return (Float64(lo), Float64(hi))
end

# Colour value of one entry: missing / non-finite -> NaN (not drawn).
function _mesh2d_tvalue(v, who::AbstractString, i::Int)
	v === missing && return NaN
	v === nothing && return NaN
	_mesh2d_is_real(v) || throw(ArgumentError(
		"$(who): colour values must be real numbers or missing; entry $(i) is $(repr(v)).",
	))
	return isfinite(v) ? Float64(v) : NaN
end

function _mesh2d_check_values(values, n::Int, who::AbstractString, what::AbstractString)
	(values isa AbstractVector) || throw(ArgumentError(
		"$(who): `values` must be a vector; got $(typeof(values)).",
	))
	length(values) == n || throw(ArgumentError(
		"$(who): `values` has $(length(values)) entries for $(n) $(what).",
	))
	for (i, v) in enumerate(values)
		_mesh2d_tvalue(v, who, i)
	end
	return values
end

"""
	_mesh2d_colour(fig, target, values; colorscale, crange, cmid, colornorm, levels,
	               showscale, colorbar_title, colorbar_title_side, colorbar_ticks,
	               colorbar_ticklabels, coloraxis, who) -> _Mesh2dColourMap

Resolve the colour keywords of a mesh call against `values` (one per cell or
node; `missing`/NaN/±Inf are not drawn). The limits default to the finite
extrema of the values (plotly's `zmid` symmetry when only `cmid` is given; a
constant field gets `±0.5` like plotly). With a `coloraxis` that already has
numeric limits and an automatic `crange`, those limits are reused (a shared
norm, as matplotlib's `Normalize` keeps its first autoscale).
"""
function _mesh2d_colour(
	fig,
	target::_Mesh2dTarget,
	values::AbstractVector;
	colorscale,
	crange,
	cmid,
	colornorm,
	levels,
	showscale,
	colorbar_title,
	colorbar_title_side::Symbol,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	who::AbstractString,
)
	norm_kind = _normalize_colornorm(colornorm, who)
	axis_id = coloraxis === nothing ? nothing : _normalize_coloraxis(coloraxis, who)
	_mesh2d_optional_bool(showscale, who, "showscale")
	title = _mesh2d_text(colorbar_title, who, "colorbar_title")
	(colorbar_ticklabels === nothing || colorbar_ticklabels isa AbstractVector || colorbar_ticklabels isa Tuple) ||
		throw(ArgumentError(
			"$(who): `colorbar_ticklabels` must be nothing or a vector; got $(typeof(colorbar_ticklabels)).",
		))
	stops0 = _mesh2d_stops(colorscale, _mesh2d_layout_source(fig, target), who)
	effective_crange = crange
	if axis_id !== nothing && _is_auto_range(crange) && levels === nothing
		limits = _mesh2d_coloraxis_limits(fig, axis_id)
		if limits !== nothing
			effective_crange = norm_kind === :log ? [exp10(limits[1]), exp10(limits[2])] : [limits[1], limits[2]]
		end
	end
	norm = _apply_color_norm(
		values;
		crange = effective_crange,
		cmid = cmid,
		colornorm = norm_kind,
		levels = levels,
		stops = stops0,
		ticks = colorbar_ticks,
		ticklabels = colorbar_ticklabels,
		who = who,
	)
	tvals = Vector{Float64}(undef, length(values))
	for (i, v) in enumerate(norm.values)
		tvals[i] = _mesh2d_tvalue(v, who, i)
	end
	cmin, cmax = norm.cmin, norm.cmax
	if cmin === nothing
		extent = _finite_extrema(tvals)
		if extent !== nothing
			lo, hi = extent
			if norm.cmid !== nothing
				# plotly `zmid`: the automatic range is made symmetric about it.
				half = max(hi - norm.cmid, norm.cmid - lo)
				lo, hi = norm.cmid - half, norm.cmid + half
			end
			if lo == hi
				# plotly.js widens a degenerate colour range by ±0.5.
				lo -= 0.5
				hi += 0.5
			end
			cmin, cmax = lo, hi
		end
	end
	stops = norm.stops isa AbstractString ? _colorscale_stops(norm.stops; who = who) : norm.stops
	band_edges = nothing
	if levels !== nothing
		boundaries = Float64.(collect(levels))
		band_edges = norm_kind === :log ? log10.(boundaries) : boundaries
	end
	ticktext = if colorbar_ticklabels !== nothing
		String[_label(string(label)) for label in colorbar_ticklabels]
	else
		norm.ticktext
	end
	# X1: the title on `colorbar_title_side`; a math title becomes an
	# annotation in `_mesh2d_finish!` (`_colorbar_math_titles!`).
	colorbar = _field2d_colorbar(
		title,
		colorbar_title_side,
		who;
		ticks = norm.tickvals,
		ticklabels = ticktext,
	)
	return _Mesh2dColourMap(
		tvals,
		cmin === nothing ? nothing : Float64(cmin),
		cmax === nothing ? nothing : Float64(cmax),
		stops,
		band_edges,
		norm_kind === :log,
		axis_id,
		showscale === nothing ? true : showscale,
		colorbar,
	)
end

# Bin of every entry and the colour of every bin. Uniform bins split
# [cmin, cmax] into `ncolors` equal parts coloured at their centres; `levels`
# bands are coloured with their band colour. Values outside the limits take
# the end bins (matplotlib's default under/over colours are the colormap
# ends). Returns `(bins, colours)` with bin 0 for entries that are not drawn.
function _mesh2d_bins(cm::_Mesh2dColourMap, ncolors::Int)
	n = length(cm.tvals)
	bins = zeros(Int, n)
	cm.cmin === nothing && return bins, String[]
	lo, hi = cm.cmin, cm.cmax
	if cm.band_edges !== nothing
		edges = cm.band_edges
		k = length(edges) - 1
		span = edges[end] - edges[1]
		centres = [((edges[b] + edges[b + 1]) / 2 - edges[1]) / span for b in 1:k]
		colours = _sample_colorscale(cm.stops, centres)
		for i in 1:n
			v = cm.tvals[i]
			isnan(v) && continue
			bins[i] = clamp(searchsortedlast(edges, v), 1, k)
		end
		return bins, colours
	end
	colours = _sample_colorscale(cm.stops, [(b - 0.5) / ncolors for b in 1:ncolors])
	width = hi - lo
	for i in 1:n
		v = cm.tvals[i]
		isnan(v) && continue
		t = clamp((v - lo) / width, 0.0, 1.0)
		bins[i] = min(floor(Int, t * ncolors), ncolors - 1) + 1
	end
	return bins, colours
end

# The colour-axis layout fields of a colour map (written to
# `layout.<coloraxis>`), or `nothing` when the map is not bound to one or has
# no limits.
function _mesh2d_coloraxis_fields(cm::_Mesh2dColourMap, showscale_given::Bool)
	(cm.coloraxis === nothing || cm.cmin === nothing) && return nothing
	fields = Dict{Symbol, Any}(
		:colorscale => cm.stops,
		:cmin => cm.cmin,
		:cmax => cm.cmax,
	)
	showscale_given && (fields[:showscale] = cm.showscale)
	cm.colorbar === nothing || (fields[:colorbar] = cm.colorbar)
	return fields
end

# Write the colour axis of `cm` (if any) and remember it for the SubplotFigure
# path.
function _mesh2d_write_coloraxis!(fig, target::_Mesh2dTarget, cm::_Mesh2dColourMap, showscale_given::Bool)
	fields = _mesh2d_coloraxis_fields(cm, showscale_given)
	fields === nothing && return nothing
	_cmn_merge_layout_key!(fig, Symbol(cm.coloraxis), fields; nested = (:colorbar,))
	target.coloraxis_write = (cm.coloraxis, fields)
	return nothing
end

# Colour bar carrier of Julia-sampled colours, or `nothing` without limits.
function _mesh2d_carrier(cm::_Mesh2dColourMap, who::AbstractString)
	cm.cmin === nothing && return nothing
	if cm.coloraxis !== nothing
		return _colorbar_carrier_trace(; cmin = cm.cmin, cmax = cm.cmax, coloraxis = cm.coloraxis, who = who)
	end
	return _colorbar_carrier_trace(;
		stops = cm.stops,
		cmin = cm.cmin,
		cmax = cm.cmax,
		showscale = cm.showscale,
		colorbar = cm.colorbar,
		who = who,
	)
end

# Hover label of a colour value (raw data value, so log norms show data).
const _MESH2D_VALUE_HOVER = "(%{x:.4g}, %{y:.4g}): %{customdata:.4g}<extra></extra>"

# One heatmap trace on a grid. `xs`/`ys` are cell centres or edges; `Z` is
# `nx x ny` in colour units (NaN = gap); `raw` (same shape) feeds the hover
# value under a log norm. `transpose = false` with rows indexed by y keeps z,
# customdata and plotly's hover indices aligned.
function _mesh2d_heatmap_trace(
	xs::AbstractVector{Float64},
	ys::AbstractVector{Float64},
	Z::AbstractMatrix{Float64},
	raw::Union{Nothing, AbstractMatrix{Float64}},
	cm::_Mesh2dColourMap;
	opacity::Float64,
	hover::Bool,
	tight::Bool,
)
	nx, ny = size(Z)
	rows = Vector{Vector{Union{Nothing, Float64}}}(undef, ny)
	for j in 1:ny
		row = Vector{Union{Nothing, Float64}}(undef, nx)
		for i in 1:nx
			v = Z[i, j]
			row[i] = isnan(v) ? _GAP : v
		end
		rows[j] = row
	end
	fields = Dict{Symbol, Any}(
		:x => collect(xs),
		:y => collect(ys),
		:z => rows,
		:transpose => false,
		:zsmooth => false,
		:name => "",
		:showlegend => false,
	)
	if cm.coloraxis !== nothing
		fields[:coloraxis] = cm.coloraxis
	else
		fields[:colorscale] = cm.stops
		fields[:showscale] = cm.cmin !== nothing && cm.showscale
		if cm.cmin !== nothing
			fields[:zmin] = cm.cmin
			fields[:zmax] = cm.cmax
			fields[:zauto] = false
		end
		cm.colorbar === nothing || (fields[:colorbar] = cm.colorbar)
	end
	opacity < 1 && (fields[:opacity] = opacity)
	if !hover
		fields[:hoverinfo] = "skip"
	elseif cm.log && raw !== nothing
		fields[:customdata] = [
			Union{Nothing, Float64}[isnan(raw[i, j]) ? _GAP : raw[i, j] for i in 1:nx] for j in 1:ny
		]
		fields[:hovertemplate] = _MESH2D_VALUE_HOVER
	else
		fields[:hovertemplate] = "(%{x:.4g}, %{y:.4g}): %{z:.4g}<extra></extra>"
	end
	# D10: the raster draws the field (sticky axis range unless `tight = false`).
	_field2d_mark_field!(fields, tight)
	return GenericTrace("heatmap", fields)
end

# ---------------------------------------------------------------------------
# Figure options (D7 primitives)
# ---------------------------------------------------------------------------

# Validate the common figure keywords and resolve the drawing cell; nothing is
# written. Returns `(cell, xtype, ytype)` where the axis types are the ones the
# call ends with (the requested scale, else the current axis type).
function _mesh2d_prepare_figure(fig, who::AbstractString, fo)
	for (name, value) in (("xscale", fo.xscale), ("yscale", fo.yscale))
		value isa AbstractString || throw(ArgumentError(
			"$(who): `$(name)` must be a string such as \"log\" (\"\" leaves the axis type unchanged); got $(repr(value)).",
		))
	end
	_validate_cartesian_options(
		fig,
		who;
		xrange = fo.xrange,
		yrange = fo.yrange,
		xscale = fo.xscale,
		yscale = fo.yscale,
		width = fo.width,
		height = fo.height,
		fontsize = fo.fontsize,
		grid = fo.grid,
	)
	_mesh2d_bool(fo.equalar, who, "equalar")
	# Run the label pipeline once now so an invalid label fails before any
	# write (`_label` is idempotent; the primitives apply it again).
	for (name, text) in (("title", fo.title), ("xlabel", fo.xlabel), ("ylabel", fo.ylabel))
		_label(_mesh2d_text(text, who, name))
	end
	cell = _cell_target(fig; who = who)
	cell.kind === :xy || throw(ArgumentError(
		"$(who): the figure is a :$(cell.kind) figure; mesh plots draw on Cartesian x/y axes.",
	))
	layout = _plot_layout(fig)
	xtype = isempty(fo.xscale) ? _axis_type(layout, :xaxis) : String(fo.xscale)
	ytype = isempty(fo.yscale) ? _axis_type(layout, :yaxis) : String(fo.yscale)
	return cell, xtype, ytype
end

# Apply the common figure keywords after the traces (indices `first_new:end`)
# were pushed, then the field finish (`_field2d_finish!`: math colorbar titles
# of the new traces and of `coloraxis`, X1; `_finalize_figure!`, D10). Line
# widths already follow the style (`_field2d_style_linewidth`), so no style
# pass runs here: fill traces draw cell outlines whose width is `edgewidth`.
function _mesh2d_finish!(
	fig,
	target::_Mesh2dTarget,
	who::AbstractString,
	fo,
	cell::_CellTarget;
	constructor::Bool,
	first_new::Int,
	coloraxis = nothing,
)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = fo.xlabel,
		ylabel = fo.ylabel,
		xrange = fo.xrange,
		yrange = fo.yrange,
		width = fo.width,
		height = fo.height,
		# Constructors: `true` keeps the template grid. Mutators: `nothing`
		# leaves the grid alone and any explicit value is applied below.
		grid = constructor ? fo.grid : nothing,
		fontsize = fo.fontsize,
		title = fo.title,
		xscale = fo.xscale,
		yscale = fo.yscale,
		apply_template = constructor,
		refresh = false,
		who = who,
	)
	constructor || _apply_axis_grid!(fig, fo.grid, who)
	if fo.equalar
		anchor = target.anchor_xref === nothing ? cell.xref : target.anchor_xref
		_apply_equal_aspect!(
			fig,
			_CellTarget(:xy, cell.row, cell.col, cell.xkey, cell.ykey, anchor, cell.yref, :none, cell.xdomain, cell.ydomain);
			who = who,
		)
	end
	_field2d_finish!(fig, first_new; coloraxis = coloraxis)
	constructor || _refresh!(fig)
	return nothing
end

# A fresh constructor figure: Cartesian axes plus the package template, so
# default colours and colorscales come from the template the figure gets.
# `show` is checked first so a bad value fails before any work.
function _mesh2d_new_figure(show, who::AbstractString)
	_mesh2d_bool(show, who, "show")
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_apply_default_template!(fig)
	return fig
end

# The constructor result: the Plot, or a window showing it (the figure size
# and title, which the mesh call has validated, size and name the window).
function _mesh2d_show(fig, show::Bool, fo)
	show || return fig
	return to_syncplot(
		fig;
		width = fo.width > 0 ? fo.width : _SYNCPLOT_DEFAULT_WIDTH,
		height = fo.height > 0 ? fo.height : _SYNCPLOT_DEFAULT_HEIGHT,
		title = isempty(fo.title) ? _SYNCPLOT_DEFAULT_TITLE : fo.title,
	)
end

# Default fill colour of a new uniform-colour trace.
function _mesh2d_default_color(fig, target::_Mesh2dTarget)
	index = target.color_index === nothing ? length(_plot_data(fig)) + 1 : target.color_index
	return _default_trace_color(_mesh2d_layout_source(fig, target), index)
end

# ---------------------------------------------------------------------------
# SubplotFigure path
# ---------------------------------------------------------------------------

_mesh2d_trace_ref(trace, key::Symbol, default::String) =
	trace isa GenericTrace ? String(get(trace.fields, key, default)) : default

# Copy into the delegate's scratch figure what the mutator reads from the
# target cell: the axis types (log axes convert ranges and are validated) and
# the figure's colour axes (shared limits).
function _mesh2d_seed_scratch!(staged, live::Plot, cell::_CellTarget)
	for (source_key, scratch_key) in ((cell.xkey, :xaxis), (cell.ykey, :yaxis))
		axis = get(live.layout.fields, source_key, nothing)
		fields = Dict{Symbol, Any}()
		for name in (:type, :exponentformat)
			value = _cmn_mapping_get(axis, name)
			value === nothing || (fields[name] = value)
		end
		isempty(fields) || _cmn_merge_layout_key!(staged, scratch_key, fields)
	end
	scratch = _plot_layout(staged)
	for (key, value) in live.layout.fields
		occursin(_MESH2D_COLORAXIS_KEY, String(key)) || continue
		scratch.fields[Symbol(key)] = deepcopy(value)
	end
	return nothing
end

# `coloraxis = "coloraxis2"` and higher (validated again by the mutator).
_mesh2d_numbered_coloraxis(value) =
	(value isa AbstractString || value isa Symbol) &&
	occursin(r"^coloraxis([2-9]|[1-9][0-9]+)$", strip(String(value)))

# Run a mesh mutator `impl(fig, target, args...; constructor = false, kwargs...)`
# on one cell (or, with `inset = k`, one inset) of a SubplotFigure through
# `_subplot_delegate_mutator!`. `_finalize_figure!` is never run on the
# delegate's scratch figure (`_FIELD2D_DEFER_FINALIZE`): its extents would be
# the new traces' only. A plain call takes the delegate's append-only fast
# path, which finalizes the figure itself (field-layout contract, CONTRACT.md
# §4). A numbered colour axis or an explicit `xrange`/`yrange` needs work on
# the real figure after the transplant, so those calls run as one fully
# staged transaction that also finalizes explicitly: the ranges go to the
# root of the cell axis's `matches` group (plotly.js ignores a range on a
# matched axis; a shared-x cell rendered 0..3 instead of xrange = (0, 5)),
# in data units converted for a log axis (`_field2d_cell_ranges!`).
function _mesh2d_subplot!(
	impl::Function,
	sf::SubplotFigure,
	who::AbstractString,
	args...;
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	_mesh2d_bool(secondary_y, who, "secondary_y")
	haskey(kwargs, :show) && throw(ArgumentError(
		"$(who): mutators do not take `show`; the SubplotFigure is shown by " *
		"`subplots(...; sync=true)` (or `display(sf)`).",
	))
	forwarded = values(kwargs)
	xr = _field2d_checked_range(get(forwarded, :xrange, nothing), who, "xrange")
	yr = _field2d_checked_range(get(forwarded, :yrange, nothing), who, "yrange")
	forwarded = Base.structdiff(forwarded, NamedTuple{(:xrange, :yrange)})
	numbered = _mesh2d_numbered_coloraxis(get(forwarded, :coloraxis, nothing))
	metadata_lock = getfield(sf, :_lock)
	lock(metadata_lock)
	try
		cell = _cell_target(sf; row = row, col = col, secondary_y = secondary_y, inset = inset, who = who)
		cell.kind === :xy || throw(ArgumentError(
			"$(who): subplot cell ($(cell.row), $(cell.col)) is a :$(cell.kind) cell; " *
			"mesh plots draw on Cartesian x/y axes.",
		))
		live = _cmn_plot(sf)
		in_cell = count(
			trace -> _mesh2d_trace_ref(trace, :xaxis, "x") == cell.xref &&
				_mesh2d_trace_ref(trace, :yaxis, "y") == cell.yref,
			live.data,
		)
		target = _Mesh2dTarget(cell.xref, in_cell + 1, live.layout, nothing)
		mutator = function (staged, margs...; mkwargs...)
			target.coloraxis_write = nothing
			_mesh2d_seed_scratch!(staged, live, cell)
			return impl(staged, target, margs...; constructor = false, mkwargs...)
		end
		if numbered || xr !== nothing || yr !== nothing
			# X51 workaround (kept): the delegate transplants `layout.coloraxis`
			# only. A numbered colour axis is merged into the staged figure
			# inside the same (fully staged) transaction, so a failure leaves
			# no partial state. Its math colorbar title is converted after the
			# merge (the delegate's conversion ran before the axis existed).
			_transactional_subplot_mutation!(sf, _SUBPLOT_SELECTION_METADATA_FIELDS) do staged_sf
				first_new = length(_cmn_plot(staged_sf).data) + 1
				Base.ScopedValues.with(_FIELD2D_DEFER_FINALIZE => true) do
					_subplot_delegate_mutator_impl!(
						staged_sf,
						mutator,
						args...;
						row = cell.row,
						col = cell.col,
						secondary_y = secondary_y,
						inset = inset,
						forwarded...,
					)
				end
				written = target.coloraxis_write
				if written !== nothing
					id, fields = written
					_cmn_merge_layout_key!(staged_sf, Symbol(id), fields; nested = (:colorbar,))
					p = _cmn_plot(staged_sf)
					_colorbar_math_titles!(p, first_new:length(p.data); coloraxes = (id,))
				end
				_field2d_cell_ranges!(staged_sf, cell, xr, yr, who)
				_finalize_figure!(_StagedPlotMutation(_cmn_plot(staged_sf)))
				return staged_sf
			end
		else
			Base.ScopedValues.with(_FIELD2D_DEFER_FINALIZE => true) do
				_subplot_delegate_mutator!(
					sf,
					mutator,
					args...;
					row = cell.row,
					col = cell.col,
					secondary_y = secondary_y,
					inset = inset,
					forwarded...,
				)
			end
		end
	finally
		unlock(metadata_lock)
	end
	return sf
end

# ---------------------------------------------------------------------------
# Cell meshes (plot_polygons and the flat paths of pcolormesh / tripcolor)
# ---------------------------------------------------------------------------

# Draw `rings` coloured by `values` (or in one colour when `values` is
# nothing). Validates every keyword before the first write.
function _mesh2d_draw_cells!(
	fig,
	target::_Mesh2dTarget,
	rings::_Mesh2dRings,
	values,
	fo,
	cell::_CellTarget;
	who::AbstractString,
	constructor::Bool,
	color,
	colorscale,
	crange,
	cmid,
	colornorm,
	levels,
	ncolors,
	edgecolor,
	edgewidth,
	opacity,
	hatch,
	showscale,
	colorbar_title,
	colorbar_title_side::Symbol,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	hover,
	legend,
	tight::Bool,
	extra_traces::Vector{GenericTrace} = GenericTrace[],
)
	ncells = _mesh2d_ncells(rings)
	edge = _mesh2d_color(edgecolor, who, "edgecolor"; allow_face = true)
	width = _mesh2d_nonnegative(edgewidth, who, "edgewidth")
	alpha = _mesh2d_opacity(opacity, who)
	_mesh2d_bool(hover, who, "hover")
	legend_text = _mesh2d_text(legend, who, "legend")
	hatch isa AbstractString || throw(ArgumentError("$(who): `hatch` must be a string; got $(repr(hatch))."))
	pattern = _hatch_pattern(hatch; color = edge, who = who)
	bins_count = _mesh2d_ncolors(ncolors, who)

	traces = GenericTrace[]
	hover_trace = nothing
	cm = nothing
	if values === nothing
		# Uniform colour: one trace, legend support. The colour-mapping
		# keywords would silently do nothing here, so they are errors.
		for (name, unset) in (
			("crange", _is_auto_range(crange)),
			("cmid", cmid === nothing),
			("levels", levels === nothing),
			("colornorm", colornorm in (:linear, "linear")),
			("showscale", showscale === nothing || showscale === false),
			("colorbar_title", colorbar_title == ""),
			("colorbar_title_side", colorbar_title_side === :top),
			("colorbar_ticks", colorbar_ticks === nothing),
			("colorbar_ticklabels", colorbar_ticklabels === nothing),
			("coloraxis", coloraxis === nothing),
		)
			unset || throw(ArgumentError(
				"$(who): `$(name)` maps cell values to colours; pass one value per cell " *
				"(or drop `$(name)` for a uniform-colour mesh).",
			))
		end
		fill = _mesh2d_color(color, who, "color")
		isempty(fill) && (fill = _mesh2d_default_color(fig, target))
		groups = fill!(Vector{Int}(undef, ncells), 1)
		xs, ys, counts = _mesh2d_group_coords(rings, groups, 1)
		if counts[1] > 0 || !isempty(legend_text)
			push!(traces, _mesh2d_fill_trace(xs[1], ys[1], fill, edge, width, alpha, pattern, legend_text, tight))
		end
		if hover && ncells > 0
			cx, cy = _mesh2d_centroids(rings)
			hover_trace = _mesh2d_hover_trace(cx, cy, collect(1:ncells), "cell %{customdata}<extra></extra>")
		end
	else
		isempty(legend_text) || throw(ArgumentError(
			"$(who): `legend` names a uniform-colour mesh; a colour-mapped mesh is " *
			"explained by its colour bar (use `legend_entry!` for a separate entry).",
		))
		fill_color = _mesh2d_color(color, who, "color")
		isempty(fill_color) || throw(ArgumentError(
			"$(who): `color` is the fill of a uniform-colour mesh; with `values` the " *
			"colours come from `colorscale` (drop `color` or `values`).",
		))
		_mesh2d_check_values(values, ncells, who, "cells")
		cm = _mesh2d_colour(
			fig,
			target,
			values;
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
			who,
		)
		bins, colours = _mesh2d_bins(cm, bins_count)
		xs, ys, counts = _mesh2d_group_coords(rings, bins, length(colours))
		for b in eachindex(colours)
			counts[b] == 0 && continue
			push!(traces, _mesh2d_fill_trace(xs[b], ys[b], colours[b], edge, width, alpha, pattern, "", tight))
		end
		# Cells without a colour (NaN) keep an explicit outline, as in
		# matplotlib where only their face is masked.
		if !isempty(edge) && width > 0
			nan_groups = Int[bins[i] == 0 ? 1 : 0 for i in 1:ncells]
			nx_, ny_, ncount = _mesh2d_group_coords(rings, nan_groups, 1)
			if ncount[1] > 0
				push!(traces, GenericTrace("scatter", Dict{Symbol, Any}(
					:x => nx_[1],
					:y => ny_[1],
					:mode => "lines",
					:line => attr(color = edge, width = width, simplify = false),
					:hoverinfo => "skip",
					:showlegend => false,
					:name => "",
				)))
			end
		end
		carrier = _mesh2d_carrier(cm, who)
		carrier === nothing || push!(traces, carrier)
		if hover
			drawn = findall(!=(0), bins)
			if !isempty(drawn)
				cx, cy = _mesh2d_centroids(rings)
				raw = Float64[_mesh2d_tvalue(values[i], who, i) for i in drawn]
				hover_trace = _mesh2d_hover_trace(cx[drawn], cy[drawn], raw, _MESH2D_VALUE_HOVER)
			end
		end
	end
	append!(traces, extra_traces)
	hover_trace === nothing || push!(traces, hover_trace)

	# --- writes ---------------------------------------------------------------
	first_new = length(_plot_data(fig)) + 1
	append!(_plot_data(fig), traces)
	cm === nothing || _mesh2d_write_coloraxis!(fig, target, cm, showscale !== nothing)
	_mesh2d_finish!(
		fig, target, who, fo, cell;
		constructor = constructor,
		first_new = first_new,
		coloraxis = cm === nothing ? nothing : cm.coloraxis,
	)
	return nothing
end

# A fill trace draws the field (D10): `meta` marks it tight or loose.
function _mesh2d_fill_trace(xs, ys, fill::String, edge::String, width::Float64, alpha::Float64, pattern, legend::AbstractString, tight::Bool)
	stroke_width = width > 0 ? width : _MESH2D_SEAM_WIDTH
	fields = Dict{Symbol, Any}(
		:x => xs,
		:y => ys,
		:mode => "lines",
		:fill => "toself",
		:fillcolor => fill,
		# `simplify = false`: plotly's path simplification may drop vertices
		# of sub-pixel cells, which would open holes in a dense mesh.
		:line => attr(
			color = isempty(edge) ? fill : edge,
			width = stroke_width,
			simplify = false,
		),
		:hoverinfo => "skip",
		:name => isempty(legend) ? "" : _label(legend),
		:showlegend => !isempty(legend),
	)
	alpha < 1 && (fields[:opacity] = alpha)
	pattern === nothing || (fields[:fillpattern] = pattern)
	_field2d_mark_field!(fields, tight)
	return GenericTrace("scatter", fields)
end

function _mesh2d_hover_trace(cx::AbstractVector{Float64}, cy::AbstractVector{Float64}, data::AbstractVector, template::String)
	return GenericTrace("scatter", Dict{Symbol, Any}(
		:x => collect(cx),
		:y => collect(cy),
		:mode => "markers",
		:marker => attr(size = _MESH2D_HOVER_MARKER_SIZE, opacity = 0),
		:customdata => collect(data),
		:hovertemplate => template,
		:showlegend => false,
		:name => "",
	))
end

# The figure keywords every mesh function takes, as one NamedTuple. The axis
# ranges are normalised as for the other field functions (X23): `[0, 0]`,
# `nothing` and `[nothing, nothing]` become `nothing` (automatic, the axis is
# left alone); partial, equal or Bool bounds throw.
_mesh2d_figure_options(
	who::AbstractString;
	title = "",
	xlabel = "",
	ylabel = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale = "",
	yscale = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid,
	equalar = true,
) = (;
	title,
	xlabel,
	ylabel,
	xrange = _field2d_checked_range(xrange, who, "xrange"),
	yrange = _field2d_checked_range(yrange, who, "yrange"),
	xscale,
	yscale,
	width,
	height,
	fontsize,
	grid,
	equalar,
)

# ---------------------------------------------------------------------------
# plot_polygons
# ---------------------------------------------------------------------------

# Element kind of the first positional argument: `:polygons` (vectors of
# coordinates), `:nodes` (numbers) or `:empty`.
function _mesh2d_first_kind(a::AbstractVector, who::AbstractString)
	T = eltype(a)
	T <: Real && !(T <: Bool) && return :nodes
	T <: AbstractVector && return :polygons
	isempty(a) && return :empty
	if all(e -> e isa AbstractVector || e isa Tuple, a)
		return :polygons
	elseif all(_mesh2d_is_real, a)
		return :nodes
	end
	throw(ArgumentError(
		"$(who): the first argument must be node x coordinates (numbers) or a vector " *
		"of polygon x-coordinate vectors; got a mixture ($(T)).",
	))
end

_mesh2d_is_cells(c) = c isa AbstractMatrix || (c isa AbstractVector && !isempty(c) && all(e -> e isa AbstractVector || e isa Tuple, c))

function _mesh2d_polygons_impl!(
	fig,
	target::_Mesh2dTarget,
	a::AbstractVector,
	b::AbstractVector,
	c = nothing,
	d = nothing;
	constructor::Bool,
	color = "",
	colorscale = _MESH2D_DEFAULT_COLORSCALE,
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	ncolors = 256,
	edgecolor = "",
	edgewidth = 0,
	opacity = 1,
	hatch = "",
	showscale = nothing,
	colorbar_title = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	hover = false,
	legend = "",
	tight = true,
	title = "",
	xlabel = "",
	ylabel = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale = "",
	yscale = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid = constructor ? true : nothing,
	equalar = true,
	extra...,
)
	who = constructor ? "plot_polygons" : "plot_polygons!"
	_mesh2d_reject_extra(who, extra)
	fo = _mesh2d_figure_options(who; title, xlabel, ylabel, xrange, yrange, xscale, yscale, width, height, fontsize, grid, equalar)
	cell, xtype, ytype = _mesh2d_prepare_figure(fig, who, fo)
	title_side = _field2d_title_side(colorbar_title_side, who)
	_mesh2d_bool(tight, who, "tight")
	kind = _mesh2d_first_kind(a, who)
	if kind === :empty
		kind = _mesh2d_is_cells(c) || (c isa AbstractVector && isempty(c) && d !== nothing) ? :nodes : :polygons
	end
	if kind === :polygons
		d === nothing || throw(ArgumentError(
			"$(who): explicit polygons take (px, py[, values]); got a fourth positional argument.",
		))
		rings = _mesh2d_rings_from_polygons(a, b, who)
		values = c
	else
		c === nothing && throw(ArgumentError(
			"$(who): node coordinates need connectivity: plot_polygons(x, y, cells[, values]).",
		))
		x = _mesh2d_coords(a, who, "x")
		y = _mesh2d_coords(b, who, "y")
		length(x) == length(y) || throw(ArgumentError(
			"$(who): `x` has $(length(x)) nodes but `y` has $(length(y)).",
		))
		indices, offsets = _mesh2d_connectivity(c, length(x), who)
		rings = _mesh2d_rings_from_nodes(x, y, indices, offsets)
		values = d
	end
	_mesh2d_check_log(rings.x, xtype, who, 'x')
	_mesh2d_check_log(rings.y, ytype, who, 'y')
	_mesh2d_draw_cells!(
		fig, target, rings, values, fo, cell;
		who, constructor, color, colorscale, crange, cmid, colornorm, levels, ncolors,
		edgecolor, edgewidth, opacity, hatch, showscale, colorbar_title,
		colorbar_title_side = title_side, colorbar_ticks, colorbar_ticklabels, coloraxis,
		hover, legend, tight,
	)
	return nothing
end

"""
	plot_polygons(px, py, values = nothing; kwargs...) -> Plot
	plot_polygons(x, y, cells, values = nothing; kwargs...) -> Plot

Draw filled polygons, each coloured by its own value through a colormap (a
matplotlib `PolyCollection` / a flat finite-element field), or all in one
colour.

#### Arguments
- `px, py::AbstractVector`: explicit polygons; `px[i]`, `py[i]` are the vertex
  coordinates of polygon `i` (at least 3 vertices, finite; the ring is closed
  automatically).
- `x, y::AbstractVector{<:Real}`: node coordinates (finite).
- `cells`: connectivity, **1-based** node indices: an `ncells x k` integer
  matrix (`k >= 3`, e.g. triangles or quads) or a vector of index vectors
  (polygons of any size >= 3). Integral floats are accepted; an index outside
  `1:length(x)` throws (`0` hints at 0-based input).
- `values`: `nothing` (uniform colour) or one value per polygon/cell
  (`AbstractVector`, `missing`/`NaN`/`±Inf` cells are not drawn, like
  matplotlib's masked cells).

#### Keywords
Colour (only with `values`):
- `colorscale = "Viridis"`: any colormap name (case-insensitive, `"_r"`
  reverses), colour vector or `(t, colour)` stops; `""` uses the figure
  template's sequential scale.
- `crange = [0, 0]`: colour limits `(lo, hi)` (vector or tuple); `[0, 0]` is
  automatic: the finite extrema of the drawn values (a constant field gets
  `value ± 0.5`, as plotly does).
- `cmid::Union{Nothing,Real} = nothing`: diverging midpoint. With an automatic
  `crange` the range is made symmetric about it (plotly `zmid`); with an
  explicit `crange` the colormap is warped so its centre sits at `cmid`
  (matplotlib `TwoSlopeNorm`).
- `colornorm::Symbol = :linear`: `:linear` or `:log` (values `<= 0` are not
  drawn unless an explicit positive `crange` floors them; colour bar ticks on
  decades labelled `10^k`).
- `levels = nothing`: `k + 1` increasing boundaries for `k` discrete colour
  bands (matplotlib `BoundaryNorm`); excludes `crange` and `cmid`.
- `ncolors::Integer = 256`: number of colour bins (1-1024) the values are
  quantised into; each non-empty bin is one plotly trace. Ignored with `levels`
  (the bands are the bins).
- `showscale::Union{Nothing,Bool} = nothing`: draw the colour bar (default on).
- `colorbar_title::AbstractString = ""`, `colorbar_ticks = nothing` (tick
  values in data units), `colorbar_ticklabels = nothing` (same length as the
  ticks).
- `coloraxis = nothing`: `:shared` (= `"coloraxis"`) or `"coloraxisN"` binds
  the colour bar to `layout.<coloraxis>`; this call writes its colorscale and
  limits there. When that axis already has limits and `crange` is automatic,
  they are reused, so several calls share one norm (as a shared matplotlib
  `Normalize`). Polygon colours are fixed when drawn: pass the same
  `colorscale` to every call that shares an axis.

Uniform colour (only without `values`):
- `color = ""`: fill colour (String or Symbol); `""` takes the next colour of
  the figure's colour cycle.
- `legend::AbstractString = ""`: legend name (unnamed meshes are hidden from
  the legend).

Style:
- `edgecolor = ""`: edge colour; `""`, `"face"` and `"none"` draw edges in each
  cell's fill colour.
- `edgewidth::Real = 0`: edge width in px. With `0` a 0.5 px stroke in the
  fill colour closes the anti-aliasing seams between adjacent cells.
- `opacity::Real = 1`: opacity in [0, 1] of every fill trace.
- `hatch::AbstractString = ""`: matplotlib hatch (`"/"`, `"\\\\"`, `"x"`, `"-"`,
  `"|"`, `"+"`, `"."`, repeated for density) drawn over the fill in
  `edgecolor` (plotly picks a contrasting colour when it is empty).
- `hover::Bool = false`: add invisible markers at the cell centroids whose
  hover label shows the cell value (or the cell index without `values`).
  Costs one marker per cell.

Figure:
- `equalar::Bool = true`: equal data aspect (`yaxis.scaleanchor`); `false`
  leaves the axes as they are.
- `title`, `xlabel`, `ylabel::AbstractString = ""` (mathtext labels),
  `xrange`, `yrange = [0, 0]` (data units, also on log axes), `xscale`,
  `yscale = ""` (`"linear"`, `"log"`, ...; on a log axis every coordinate must
  be positive), `width`, `height`, `fontsize::Real = 0` (0 = automatic),
  `grid = true` (`false`, `:x`, `:y`, `:both`, `:none`).
- `show::Bool = false`: open a window and return a `SyncPlot`.

#### Plotly encoding
Each non-empty colour bin is one `scatter` trace (`fill = "toself"`, rings
separated by gaps); an invisible carrier `scatter` draws the colour bar with
the stops and limits the cells were coloured from. Values outside the limits
take the end colours.

Returns a `Plot` (a `SyncPlot` with `show = true`).

#### Example
```julia
x = [0.0, 1.0, 2.0, 0.0, 1.0, 2.0]
y = [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
quads = [1 2 5 4; 2 3 6 5]                    # 1-based node indices
fig = plot_polygons(x, y, quads, [0.2, 0.9]; colorbar_title = "T",
                    edgecolor = "black", edgewidth = 1)
plot_polygons([[3.0, 4.0, 3.5]], [[0.0, 0.0, 1.0]])   # one triangle, one colour
```
"""
function plot_polygons(a::AbstractVector, b::AbstractVector, c = nothing, d = nothing; show = false, kwargs...)
	fig = _mesh2d_new_figure(show, "plot_polygons")
	_mesh2d_polygons_impl!(fig, _Mesh2dTarget(), a, b, c, d; constructor = true, kwargs...)
	return _mesh2d_show(fig, show, _mesh2d_show_options(; kwargs...))
end

_mesh2d_show_options(; width = 0, height = 0, title = "", kwargs...) = (; width, height, title)

"""
	plot_polygons!(fig, px, py, values = nothing; kwargs...) -> nothing
	plot_polygons!(fig, x, y, cells, values = nothing; kwargs...) -> nothing
	plot_polygons!(sf::SubplotFigure, ...; row = nothing, col = nothing, secondary_y = false, kwargs...) -> sf

Add polygons to an existing figure. `fig` is a `Plot` or a `SyncPlot` (one
renderer transaction; a failing call leaves the figure unchanged). On a
`SubplotFigure` the polygons go to cell (`row`, `col`) (both or neither;
default: the active cell), on its secondary y axis with `secondary_y = true`;
the cell's own colour bar is placed next to it.

Takes the arguments and keywords of [`plot_polygons`](@ref) except `show`
(passing it throws an `ArgumentError`). Differences:
- `grid = nothing` leaves the grid unchanged; any explicit value is applied.
- `equalar = true` (re)applies the equal aspect to the target axes; `false`
  leaves them as they are.
- `title`/`width`/`height` on a SubplotFigure are figure-level and ignored
  with a warning (set them on `subplots` or with `relayout!`).

Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a SubplotFigure.

#### Example
```julia
fig = plot_polygons([[0.0, 1.0, 1.0, 0.0]], [[0.0, 0.0, 1.0, 1.0]]; color = "lightgray")
plot_polygons!(fig, [[0.25, 0.75, 0.5]], [[0.25, 0.25, 0.75]], [3.0];
               colorscale = "magma", crange = (0, 5))
```
"""
function plot_polygons!(fig, a::AbstractVector, b::AbstractVector, c = nothing, d = nothing; kwargs...)
	return _mesh2d_polygons_impl!(fig, _Mesh2dTarget(), a, b, c, d; constructor = false, kwargs...)
end

function plot_polygons!(
	sf::SubplotFigure,
	a::AbstractVector,
	b::AbstractVector,
	c = nothing,
	d = nothing;
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	return _mesh2d_subplot!(
		_mesh2d_polygons_impl!, sf, "plot_polygons!", a, b, c, d;
		row, col, secondary_y, inset, kwargs...,
	)
end

# ---------------------------------------------------------------------------
# plot_pcolormesh
# ---------------------------------------------------------------------------

# Cell values of a (possibly node-valued) C on an m x n node grid: C of size
# (m-1, n-1) is per cell; (m, n) is per node and each cell gets the mean of its
# 4 corners (a non-finite or missing corner leaves the cell undrawn).
function _mesh2d_cell_values(C::AbstractMatrix, m::Int, n::Int, who::AbstractString)
	if size(C) == (m - 1, n - 1)
		out = Matrix{Any}(undef, m - 1, n - 1)
		for j in 1:(n - 1), i in 1:(m - 1)
			out[i, j] = C[i, j]
		end
		for (k, v) in enumerate(out)
			_mesh2d_tvalue(v, who, k)
		end
		return out
	elseif size(C) == (m, n)
		node = Matrix{Float64}(undef, m, n)
		for j in 1:n, i in 1:m
			node[i, j] = _mesh2d_tvalue(C[i, j], who, (j - 1) * m + i)
		end
		out = Matrix{Any}(undef, m - 1, n - 1)
		for j in 1:(n - 1), i in 1:(m - 1)
			out[i, j] = (node[i, j] + node[i + 1, j] + node[i + 1, j + 1] + node[i, j + 1]) / 4
		end
		return out
	end
	throw(ArgumentError(
		"$(who): `C` must be $(m - 1)x$(n - 1) (one value per cell) or $(m)x$(n) " *
		"(one value per node) for a $(m)x$(n) node grid; got $(size(C, 1))x$(size(C, 2)).",
	))
end

# Quad cells of an m x n node grid, in the column-major order of `C`.
function _mesh2d_quad_cells(m::Int, n::Int)
	ncells = (m - 1) * (n - 1)
	indices = Vector{Int}(undef, 4 * ncells)
	offsets = collect(1:4:(4 * ncells + 1))
	p = 0
	for j in 1:(n - 1), i in 1:(m - 1)
		n00 = (j - 1) * m + i
		indices[p + 1] = n00
		indices[p + 2] = n00 + 1
		indices[p + 3] = n00 + 1 + m
		indices[p + 4] = n00 + m
		p += 4
	end
	return indices, offsets
end

function _mesh2d_strictly_monotonic(v::Vector{Float64})
	length(v) < 2 && return false
	increasing = all(i -> v[i] < v[i + 1], 1:(length(v) - 1))
	increasing && return true
	return all(i -> v[i] > v[i + 1], 1:(length(v) - 1))
end

function _mesh2d_pcolormesh_impl!(
	fig,
	target::_Mesh2dTarget,
	X::AbstractArray,
	Y::AbstractArray,
	C::AbstractMatrix;
	constructor::Bool,
	colorscale = _MESH2D_DEFAULT_COLORSCALE,
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	ncolors = 256,
	edgecolor = "",
	edgewidth = 0,
	opacity = 1,
	hatch = "",
	showscale = nothing,
	colorbar_title = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	hover = false,
	tight = true,
	title = "",
	xlabel = "",
	ylabel = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale = "",
	yscale = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid = constructor ? true : nothing,
	equalar = true,
	extra...,
)
	who = constructor ? "plot_pcolormesh" : "plot_pcolormesh!"
	_mesh2d_reject_extra(who, extra)
	fo = _mesh2d_figure_options(who; title, xlabel, ylabel, xrange, yrange, xscale, yscale, width, height, fontsize, grid, equalar)
	cell, xtype, ytype = _mesh2d_prepare_figure(fig, who, fo)
	title_side = _field2d_title_side(colorbar_title_side, who)
	_mesh2d_bool(tight, who, "tight")
	vector_form = X isa AbstractVector
	if vector_form
		Y isa AbstractVector || throw(ArgumentError(
			"$(who): pass `x, y` as two vectors or `X, Y` as two matrices; got $(typeof(X)) and $(typeof(Y)).",
		))
		xv = _mesh2d_coords(X, who, "x")
		yv = _mesh2d_coords(Y, who, "y")
		m, n = length(xv), length(yv)
	else
		(X isa AbstractMatrix && Y isa AbstractMatrix) || throw(ArgumentError(
			"$(who): pass `x, y` as two vectors or `X, Y` as two matrices; got $(typeof(X)) and $(typeof(Y)).",
		))
		size(X) == size(Y) || throw(ArgumentError(
			"$(who): `X` is $(size(X, 1))x$(size(X, 2)) but `Y` is $(size(Y, 1))x$(size(Y, 2)); they must match.",
		))
		m, n = size(X)
	end
	(m >= 2 && n >= 2) || throw(ArgumentError(
		"$(who): the node grid must be at least 2x2; got $(m)x$(n).",
	))
	cellvals = _mesh2d_cell_values(C, m, n, who)
	edge = _mesh2d_color(edgecolor, who, "edgecolor"; allow_face = true)
	edge_width = _mesh2d_nonnegative(edgewidth, who, "edgewidth")
	hatch isa AbstractString || throw(ArgumentError("$(who): `hatch` must be a string; got $(repr(hatch))."))

	# A rectilinear grid without edges or hatching is one heatmap: exact
	# colours, no seams, O(1) traces.
	if vector_form && edge_width == 0 && isempty(hatch) && xtype != "log" && ytype != "log" &&
			_mesh2d_strictly_monotonic(xv) && _mesh2d_strictly_monotonic(yv)
		_mesh2d_ncolors(ncolors, who)
		alpha = _mesh2d_opacity(opacity, who)
		_mesh2d_bool(hover, who, "hover")
		vals = vec(cellvals)
		cm = _mesh2d_colour(
			fig, target, vals;
			colorscale, crange, cmid, colornorm, levels, showscale, colorbar_title,
			colorbar_title_side = title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who,
		)
		Z = reshape(copy(cm.tvals), m - 1, n - 1)
		raw = reshape(Float64[_mesh2d_tvalue(v, who, k) for (k, v) in enumerate(vals)], m - 1, n - 1)
		xe, ye = xv, yv
		if xe[1] > xe[end]
			xe = reverse(xe)
			Z = Z[end:-1:1, :]
			raw = raw[end:-1:1, :]
		end
		if ye[1] > ye[end]
			ye = reverse(ye)
			Z = Z[:, end:-1:1]
			raw = raw[:, end:-1:1]
		end
		trace = _mesh2d_heatmap_trace(xe, ye, Z, raw, cm; opacity = alpha, hover = hover, tight = tight)
		first_new = length(_plot_data(fig)) + 1
		push!(_plot_data(fig), trace)
		_mesh2d_write_coloraxis!(fig, target, cm, showscale !== nothing)
		_mesh2d_finish!(
			fig, target, who, fo, cell;
			constructor = constructor,
			first_new = first_new,
			coloraxis = cm.coloraxis,
		)
		return nothing
	end

	if vector_form
		xs = Vector{Float64}(undef, m * n)
		ys = Vector{Float64}(undef, m * n)
		for j in 1:n, i in 1:m
			xs[(j - 1) * m + i] = xv[i]
			ys[(j - 1) * m + i] = yv[j]
		end
	else
		xs = _mesh2d_coords(vec(X), who, "X")
		ys = _mesh2d_coords(vec(Y), who, "Y")
	end
	indices, offsets = _mesh2d_quad_cells(m, n)
	rings = _mesh2d_rings_from_nodes(xs, ys, indices, offsets)
	_mesh2d_check_log(rings.x, xtype, who, 'x')
	_mesh2d_check_log(rings.y, ytype, who, 'y')
	_mesh2d_draw_cells!(
		fig, target, rings, vec(cellvals), fo, cell;
		who, constructor, color = "", colorscale, crange, cmid, colornorm, levels, ncolors,
		edgecolor, edgewidth, opacity, hatch, showscale, colorbar_title,
		colorbar_title_side = title_side, colorbar_ticks, colorbar_ticklabels, coloraxis,
		hover, legend = "", tight,
	)
	return nothing
end

"""
	plot_pcolormesh(X::AbstractMatrix, Y::AbstractMatrix, C::AbstractMatrix; kwargs...) -> Plot
	plot_pcolormesh(x::AbstractVector, y::AbstractVector, C::AbstractMatrix; kwargs...) -> Plot

Pseudocolour plot of a (curvilinear) quadrilateral grid, as matplotlib
`pcolormesh(X, Y, C, shading = "flat")`.

#### Arguments
- `X, Y`: `m x n` node coordinates (finite, same size, never transposed).
  Cell `(i, j)` is the quad `(X[i,j], Y[i,j])`, `(X[i+1,j], Y[i+1,j])`,
  `(X[i+1,j+1], Y[i+1,j+1])`, `(X[i,j+1], Y[i,j+1])`.
- `x, y`: vector form, `X[i,j] = x[i]`, `Y[i,j] = y[j]` (the `A[ix, iy]`
  convention of `plot_heatmap`).
- `C`: `(m-1) x (n-1)` cell values, or `m x n` node values; each cell then
  gets the mean of its 4 corner values (this differs from matplotlib's
  `shading = "nearest"`, which centres cells on the nodes). `missing`, `NaN`
  and `±Inf` cells are not drawn. Any other size throws.

To mirror a half-plane mesh, call it twice: `plot_pcolormesh!(fig, -X, Y, C)`.

#### Keywords
The colour, style and figure keywords of [`plot_polygons`](@ref)
(`colorscale = "Viridis"`, `crange`, `cmid`, `colornorm`, `levels`,
`ncolors = 256`, `showscale`, `colorbar_title`, `colorbar_ticks`,
`colorbar_ticklabels`, `coloraxis`, `edgecolor`, `edgewidth = 0`,
`opacity = 1`, `hatch`, `hover = false`, `equalar = true`, `title`, `xlabel`,
`ylabel`, `xrange`, `yrange`, `xscale`, `yscale`, `width`, `height`,
`fontsize`, `grid = true`, `show = false`), without `color` and `legend`
(`C` always colours the cells).

#### Plotly encoding
The vector form with strictly monotonic `x`, `y`, `edgewidth = 0`, no
`hatch` and linear axes is one `heatmap` trace with the node coordinates as
cell edges (exact colours, `ncolors` unused). Every other case is drawn as
polygons (see [`plot_polygons`](@ref)).

Returns a `Plot` (a `SyncPlot` with `show = true`).

#### Example
```julia
r = range(1.0, 2.0; length = 9)
θ = range(0.0, π; length = 33)
X = [ri * cos(t) for ri in r, t in θ]
Y = [ri * sin(t) for ri in r, t in θ]
C = [sin(3t) / ri for ri in r[1:end-1], t in θ[1:end-1]]
fig = plot_pcolormesh(X, Y, C; colorscale = "RdBu_r", cmid = 0, colorbar_title = "f")
plot_pcolormesh!(fig, -X, Y, C; colorscale = "RdBu_r", cmid = 0, showscale = false)
```
"""
function plot_pcolormesh(X::AbstractArray, Y::AbstractArray, C::AbstractMatrix; show = false, kwargs...)
	fig = _mesh2d_new_figure(show, "plot_pcolormesh")
	_mesh2d_pcolormesh_impl!(fig, _Mesh2dTarget(), X, Y, C; constructor = true, kwargs...)
	return _mesh2d_show(fig, show, _mesh2d_show_options(; kwargs...))
end

"""
	plot_pcolormesh!(fig, X, Y, C; kwargs...) -> nothing
	plot_pcolormesh!(fig, x, y, C; kwargs...) -> nothing
	plot_pcolormesh!(sf::SubplotFigure, ...; row = nothing, col = nothing, secondary_y = false, kwargs...) -> sf

Add a pseudocolour mesh to an existing `Plot`, `SyncPlot` (one renderer
transaction; a failing call leaves the figure unchanged) or SubplotFigure cell
(`row`/`col`, default the active cell; `secondary_y = true` for the cell's
secondary y axis). Arguments and keywords as [`plot_pcolormesh`](@ref) except
`show` (an `ArgumentError`); `grid = nothing` leaves the grid unchanged.

Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a SubplotFigure.

#### Example
```julia
X = [i + 0.1j for i in 0:4, j in 0:3]
Y = [j + 0.0i for i in 0:4, j in 0:3]
fig = plot_pcolormesh(X, Y, rand(4, 3))
plot_pcolormesh!(fig, -X, Y, rand(4, 3); showscale = false)   # mirrored copy
```
"""
function plot_pcolormesh!(fig, X::AbstractArray, Y::AbstractArray, C::AbstractMatrix; kwargs...)
	return _mesh2d_pcolormesh_impl!(fig, _Mesh2dTarget(), X, Y, C; constructor = false, kwargs...)
end

function plot_pcolormesh!(
	sf::SubplotFigure,
	X::AbstractArray,
	Y::AbstractArray,
	C::AbstractMatrix;
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	return _mesh2d_subplot!(
		_mesh2d_pcolormesh_impl!, sf, "plot_pcolormesh!", X, Y, C;
		row, col, secondary_y, inset, kwargs...,
	)
end

# ---------------------------------------------------------------------------
# Triangulations (tripcolor, triplot, tricontour)
# ---------------------------------------------------------------------------

# Validated triangulation: node coordinates, the ntri x 3 connectivity as a
# flat list, and the drawn-triangle mask (`nothing` = all drawn).
struct _Mesh2dTri
	x::Vector{Float64}
	y::Vector{Float64}
	indices::Vector{Int}   # 3 per triangle
	ntri::Int
	keep::Union{Nothing, BitVector}
end

function _mesh2d_triangulation(x, y, triangles, mask, who::AbstractString)
	xv = _mesh2d_coords(x, who, "x")
	yv = _mesh2d_coords(y, who, "y")
	length(xv) == length(yv) || throw(ArgumentError(
		"$(who): `x` has $(length(xv)) nodes but `y` has $(length(yv)).",
	))
	indices, offsets = _mesh2d_connectivity(triangles, length(xv), who; name = "triangles", arity = 3)
	ntri = length(offsets) - 1
	hidden = _mesh2d_mask(mask, ntri, who)
	keep = hidden === nothing ? nothing : .!hidden
	return _Mesh2dTri(xv, yv, indices, ntri, keep)
end

_mesh2d_tri_drawn(t::_Mesh2dTri, i::Int) = t.keep === nothing || t.keep[i]

# Indices/offsets of the drawn triangles.
function _mesh2d_tri_cells(t::_Mesh2dTri)
	return _mesh2d_select_cells(t.indices, collect(1:3:(3 * t.ntri + 1)), t.keep)
end

function _mesh2d_tri_check_log(t::_Mesh2dTri, xtype, ytype, who)
	_mesh2d_check_log(t.x, xtype, who, 'x')
	_mesh2d_check_log(t.y, ytype, who, 'y')
	return nothing
end

# One edges trace (unique undirected edges of the drawn triangles).
function _mesh2d_edges_trace(t::_Mesh2dTri; color::String, width::Float64, dash::String, opacity::Float64, legend::AbstractString)
	indices, offsets = _mesh2d_tri_cells(t)
	ex, ey, _ = _mesh2d_unique_edges(t.x, t.y, indices, offsets)
	line = Dict{Symbol, Any}(:color => color, :width => width)
	isempty(dash) || (line[:dash] = dash)
	fields = Dict{Symbol, Any}(
		:x => ex,
		:y => ey,
		:mode => "lines",
		:line => attr(line),
		:hoverinfo => "skip",
		:name => isempty(legend) ? "" : _label(legend),
		:showlegend => !isempty(legend),
	)
	opacity < 1 && (fields[:opacity] = opacity)
	return GenericTrace("scatter", fields)
end

# Barycentric rasterisation of node values `v` (colour units, NaN allowed) over
# the drawn triangles onto a grid of pixel centres whose longer side has
# `resolution` pixels. Pixels outside every drawn triangle are NaN. Returns
# `(xc, yc, Z)` with `Z[i, j]` the value at `(xc[i], yc[j])`.
function _mesh2d_gouraud_raster(t::_Mesh2dTri, v::Vector{Float64}, resolution::Int, who::AbstractString)
	xmin = ymin = Inf
	xmax = ymax = -Inf
	for i in 1:t.ntri
		_mesh2d_tri_drawn(t, i) || continue
		for k in (3i - 2):(3i)
			node = t.indices[k]
			xmin = min(xmin, t.x[node])
			xmax = max(xmax, t.x[node])
			ymin = min(ymin, t.y[node])
			ymax = max(ymax, t.y[node])
		end
	end
	isfinite(xmin) || return Float64[], Float64[], Matrix{Float64}(undef, 0, 0)
	dx, dy = xmax - xmin, ymax - ymin
	has_area = false
	for tri in 1:t.ntri
		_mesh2d_tri_drawn(t, tri) || continue
		a, b, c = t.indices[3tri - 2], t.indices[3tri - 1], t.indices[3tri]
		if (t.x[b] - t.x[a]) * (t.y[c] - t.y[a]) != (t.x[c] - t.x[a]) * (t.y[b] - t.y[a])
			has_area = true
			break
		end
	end
	(has_area && dx > 0 && dy > 0) || throw(ArgumentError(
		"$(who): the drawn triangles have no area (every triangle is degenerate); shading = :gouraud cannot rasterise them.",
	))
	h = max(dx, dy) / resolution
	nx = max(1, round(Int, dx / h))
	ny = max(1, round(Int, dy / h))
	hx, hy = dx / nx, dy / ny
	# Plain loops, not comprehensions: a closure capturing the reassigned
	# `xmin`/`ymin` would box them and make this whole function type-unstable.
	xc = Vector{Float64}(undef, nx)
	yc = Vector{Float64}(undef, ny)
	for i in 1:nx
		xc[i] = xmin + (i - 0.5) * hx
	end
	for j in 1:ny
		yc[j] = ymin + (j - 0.5) * hy
	end
	Z = fill(NaN, nx, ny)
	for tri in 1:t.ntri
		_mesh2d_tri_drawn(t, tri) || continue
		a, b, c = t.indices[3tri - 2], t.indices[3tri - 1], t.indices[3tri]
		xa, ya, xb, yb, xc_, yc_ = t.x[a], t.y[a], t.x[b], t.y[b], t.x[c], t.y[c]
		den = (yb - yc_) * (xa - xc_) + (xc_ - xb) * (ya - yc_)
		den == 0 && continue   # degenerate triangle: covers no pixel centre
		i0 = max(1, ceil(Int, (min(xa, xb, xc_) - xmin) / hx + 0.5))
		i1 = min(nx, floor(Int, (max(xa, xb, xc_) - xmin) / hx + 0.5))
		j0 = max(1, ceil(Int, (min(ya, yb, yc_) - ymin) / hy + 0.5))
		j1 = min(ny, floor(Int, (max(ya, yb, yc_) - ymin) / hy + 0.5))
		va, vb, vc = v[a], v[b], v[c]
		# Relative tolerance so pixel centres on a shared edge count as inside.
		tol = -1e-12
		for j in j0:j1, i in i0:i1
			px, py = xc[i], yc[j]
			l1 = ((yb - yc_) * (px - xc_) + (xc_ - xb) * (py - yc_)) / den
			l2 = ((yc_ - ya) * (px - xc_) + (xa - xc_) * (py - yc_)) / den
			l3 = 1 - l1 - l2
			(l1 >= tol && l2 >= tol && l3 >= tol) || continue
			Z[i, j] = l1 * va + l2 * vb + l3 * vc
		end
	end
	return xc, yc, Z
end

function _mesh2d_tripcolor_impl!(
	fig,
	target::_Mesh2dTarget,
	x::AbstractVector,
	y::AbstractVector,
	triangles,
	values::AbstractVector;
	constructor::Bool,
	shading = :flat,
	mask = nothing,
	resolution = 400,
	values_at = :auto,
	edges = false,
	edgecolor = "rgba(0,0,0,0.35)",
	edgewidth = 0.5,
	colorscale = _MESH2D_DEFAULT_COLORSCALE,
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	ncolors = 256,
	showscale = nothing,
	colorbar_title = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	opacity = 1,
	hover = false,
	tight = true,
	title = "",
	xlabel = "",
	ylabel = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale = "",
	yscale = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid = constructor ? true : nothing,
	equalar = true,
	extra...,
)
	who = constructor ? "plot_tripcolor" : "plot_tripcolor!"
	_mesh2d_reject_extra(who, extra)
	fo = _mesh2d_figure_options(who; title, xlabel, ylabel, xrange, yrange, xscale, yscale, width, height, fontsize, grid, equalar)
	cell, xtype, ytype = _mesh2d_prepare_figure(fig, who, fo)
	title_side = _field2d_title_side(colorbar_title_side, who)
	_mesh2d_bool(tight, who, "tight")
	(shading isa Symbol || shading isa AbstractString) || throw(ArgumentError(
		"$(who): `shading` must be :flat or :gouraud; got $(repr(shading)).",
	))
	shade = Symbol(lowercase(String(shading)))
	shade in (:flat, :gouraud) || throw(ArgumentError(
		"$(who): `shading` must be :flat or :gouraud; got $(repr(shading)).",
	))
	(values_at isa Symbol && values_at in (:auto, :nodes, :cells)) || throw(ArgumentError(
		"$(who): `values_at` must be :auto, :nodes or :cells; got $(repr(values_at)).",
	))
	_mesh2d_bool(edges, who, "edges")
	edge = _mesh2d_color(edgecolor, who, "edgecolor"; allow_face = true)
	edge_width = _mesh2d_nonnegative(edgewidth, who, "edgewidth")
	tri = _mesh2d_triangulation(x, y, triangles, mask, who)
	_mesh2d_tri_check_log(tri, xtype, ytype, who)
	nnodes = length(tri.x)
	(values isa AbstractVector) || throw(ArgumentError("$(who): `values` must be a vector; got $(typeof(values))."))
	at = if values_at === :auto
		length(values) == nnodes ? :nodes :
		length(values) == tri.ntri ? :cells :
		throw(ArgumentError(
			"$(who): `values` has $(length(values)) entries; expected one per node ($(nnodes)) " *
			"or one per triangle ($(tri.ntri)).",
		))
	else
		values_at
	end
	expected = at === :nodes ? nnodes : tri.ntri
	_mesh2d_check_values(values, expected, who, at === :nodes ? "nodes" : "triangles")

	if shade === :flat
		cell_values = if at === :nodes
			nodev = Float64[_mesh2d_tvalue(v, who, i) for (i, v) in enumerate(values)]
			Float64[
				(nodev[tri.indices[3i - 2]] + nodev[tri.indices[3i - 1]] + nodev[tri.indices[3i]]) / 3
				for i in 1:tri.ntri if _mesh2d_tri_drawn(tri, i)
			]
		else
			Any[values[i] for i in 1:tri.ntri if _mesh2d_tri_drawn(tri, i)]
		end
		indices, offsets = _mesh2d_tri_cells(tri)
		rings = _mesh2d_rings_from_nodes(tri.x, tri.y, indices, offsets)
		_mesh2d_draw_cells!(
			fig, target, rings, cell_values, fo, cell;
			who, constructor, color = "", colorscale, crange, cmid, colornorm, levels, ncolors,
			edgecolor = edges ? edgecolor : "", edgewidth = edges ? edge_width : 0,
			opacity, hatch = "", showscale, colorbar_title, colorbar_title_side = title_side,
			colorbar_ticks, colorbar_ticklabels, coloraxis, hover, legend = "", tight,
		)
		return nothing
	end

	# Gouraud: one value per node, interpolated linearly inside each triangle.
	at === :nodes || throw(ArgumentError(
		"$(who): shading = :gouraud interpolates node values; `values` must have one entry per node ($(nnodes)).",
	))
	(xtype == "log" || ytype == "log") && throw(ArgumentError(
		"$(who): shading = :gouraud rasterises in linear data space; use shading = :flat on logarithmic axes.",
	))
	(resolution isa Integer && !(resolution isa Bool) && 2 <= resolution <= _MESH2D_MAX_RESOLUTION) ||
		throw(ArgumentError(
			"$(who): `resolution` must be an integer in 2:$(_MESH2D_MAX_RESOLUTION); got $(repr(resolution)).",
		))
	_mesh2d_ncolors(ncolors, who)
	alpha = _mesh2d_opacity(opacity, who)
	_mesh2d_bool(hover, who, "hover")
	# Only nodes of drawn triangles set the automatic colour limits.
	used = falses(nnodes)
	for i in 1:tri.ntri
		_mesh2d_tri_drawn(tri, i) || continue
		used[tri.indices[3i - 2]] = used[tri.indices[3i - 1]] = used[tri.indices[3i]] = true
	end
	used_values = Any[used[i] ? values[i] : NaN for i in 1:nnodes]
	cm = _mesh2d_colour(
		fig, target, used_values;
		colorscale, crange, cmid, colornorm, levels, showscale, colorbar_title,
		colorbar_title_side = title_side, colorbar_ticks, colorbar_ticklabels, coloraxis, who,
	)
	xc, yc, Z = _mesh2d_gouraud_raster(tri, cm.tvals, Int(resolution), who)
	traces = GenericTrace[]
	if !isempty(xc)
		raw = cm.log ? map(v -> isnan(v) ? NaN : exp10(v), Z) : nothing
		push!(traces, _mesh2d_heatmap_trace(xc, yc, Z, raw, cm; opacity = alpha, hover = hover, tight = tight))
	end
	if edges && edge_width > 0
		push!(traces, _mesh2d_edges_trace(tri; color = isempty(edge) ? "rgba(0,0,0,0.35)" : edge, width = edge_width, dash = "", opacity = 1.0, legend = ""))
	end
	first_new = length(_plot_data(fig)) + 1
	append!(_plot_data(fig), traces)
	_mesh2d_write_coloraxis!(fig, target, cm, showscale !== nothing)
	_mesh2d_finish!(
		fig, target, who, fo, cell;
		constructor = constructor,
		first_new = first_new,
		coloraxis = cm.coloraxis,
	)
	return nothing
end

"""
	plot_tripcolor(x, y, triangles, values; kwargs...) -> Plot

Pseudocolour plot of an unstructured triangular mesh (matplotlib `tripcolor`).

#### Arguments
- `x, y::AbstractVector{<:Real}`: node coordinates (finite).
- `triangles`: **1-based** connectivity, an `ntri x 3` integer matrix or a
  vector of 3-element index vectors.
- `values::AbstractVector`: one value per node or one per triangle (see
  `values_at`); `missing`/`NaN`/`±Inf` entries are not drawn.

#### Keywords
- `shading::Symbol = :flat`:
  - `:flat` colours each triangle uniformly: per-triangle values as given,
    per-node values averaged over the 3 vertices. Drawn as polygons (see
    [`plot_polygons`](@ref); `ncolors` applies).
  - `:gouraud` interpolates node values linearly inside each triangle
    (barycentric, in the colour norm's units, so `:log` interpolates
    log10 values) and draws the result as one `heatmap` raster (`zsmooth =
    false`) whose pixels outside the drawn triangles are empty. Needs node
    values and linear axes.
- `mask = nothing`: `AbstractVector{Bool}` with one entry per triangle;
  `true` hides that triangle (no fill, no edges, and it does not set the
  automatic colour limits).
- `resolution::Integer = 400`: gouraud raster size: pixels along the longer
  side of the drawn mesh's bounding box (2-2048); the other side keeps square
  pixels.
- `values_at::Symbol = :auto`: `:nodes`, `:cells` (per triangle) or `:auto`
  (node values when the length equals the node count, else per triangle, as
  matplotlib).
- `edges::Bool = false`: draw the triangle edges with `edgecolor =
  "rgba(0,0,0,0.35)"` and `edgewidth::Real = 0.5` (px).
- Colour keywords as [`plot_polygons`](@ref): `colorscale = "Viridis"`,
  `crange`, `cmid`, `colornorm`, `levels`, `ncolors = 256` (flat only),
  `showscale`, `colorbar_title`, `colorbar_ticks`, `colorbar_ticklabels`,
  `coloraxis`. Automatic limits are the extrema of the drawn values.
- `opacity::Real = 1`, `hover::Bool = false` (flat: centroid markers;
  gouraud: the raster's own hover).
- Figure keywords as [`plot_polygons`](@ref): `equalar = true`, `title`,
  `xlabel`, `ylabel`, `xrange`, `yrange`, `xscale`, `yscale`, `width`,
  `height`, `fontsize`, `grid = true`, `show = false`.

Returns a `Plot` (a `SyncPlot` with `show = true`).

#### Example
```julia
x = [0.0, 1.0, 0.0, 1.0, 0.5]
y = [0.0, 0.0, 1.0, 1.0, 0.5]
tri = [1 2 5; 2 4 5; 4 3 5; 3 1 5]
fig = plot_tripcolor(x, y, tri, x .+ y; shading = :gouraud, edges = true,
                     mask = [false, false, false, true], colorscale = "cividis")
plot_tripcolor(x, y, tri, [1.0, 2.0, 3.0, 4.0]; colorbar_title = "per triangle")
```
"""
function plot_tripcolor(x::AbstractVector, y::AbstractVector, triangles, values::AbstractVector; show = false, kwargs...)
	fig = _mesh2d_new_figure(show, "plot_tripcolor")
	_mesh2d_tripcolor_impl!(fig, _Mesh2dTarget(), x, y, triangles, values; constructor = true, kwargs...)
	return _mesh2d_show(fig, show, _mesh2d_show_options(; kwargs...))
end

"""
	plot_tripcolor!(fig, x, y, triangles, values; kwargs...) -> nothing
	plot_tripcolor!(sf::SubplotFigure, x, y, triangles, values; row = nothing, col = nothing, secondary_y = false, kwargs...) -> sf

Add a triangular pseudocolour mesh to an existing `Plot`, `SyncPlot` (one
renderer transaction; a failing call leaves the figure unchanged) or
SubplotFigure cell (`row`/`col`, default the active cell). Arguments and
keywords as [`plot_tripcolor`](@ref) except `show` (an `ArgumentError`);
`grid = nothing` leaves the grid unchanged.

Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a SubplotFigure.

#### Example
```julia
x = [0.0, 1.0, 0.0, 1.0]; y = [0.0, 0.0, 1.0, 1.0]
tri = [1 2 3; 2 4 3]
fig = plot_triplot(x, y, tri)
plot_tripcolor!(fig, x, y, tri, [0.0, 1.0, 1.0, 2.0]; shading = :gouraud)
```
"""
function plot_tripcolor!(fig, x::AbstractVector, y::AbstractVector, triangles, values::AbstractVector; kwargs...)
	return _mesh2d_tripcolor_impl!(fig, _Mesh2dTarget(), x, y, triangles, values; constructor = false, kwargs...)
end

function plot_tripcolor!(
	sf::SubplotFigure,
	x::AbstractVector,
	y::AbstractVector,
	triangles,
	values::AbstractVector;
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	return _mesh2d_subplot!(
		_mesh2d_tripcolor_impl!, sf, "plot_tripcolor!", x, y, triangles, values;
		row, col, secondary_y, inset, kwargs...,
	)
end

function _mesh2d_triplot_impl!(
	fig,
	target::_Mesh2dTarget,
	x::AbstractVector,
	y::AbstractVector,
	triangles;
	constructor::Bool,
	color = "black",
	linewidth = 0,
	dash = "",
	opacity = 1,
	mask = nothing,
	legend = "",
	title = "",
	xlabel = "",
	ylabel = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale = "",
	yscale = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid = constructor ? true : nothing,
	equalar = true,
	extra...,
)
	who = constructor ? "plot_triplot" : "plot_triplot!"
	_mesh2d_reject_extra(who, extra)
	fo = _mesh2d_figure_options(who; title, xlabel, ylabel, xrange, yrange, xscale, yscale, width, height, fontsize, grid, equalar)
	cell, xtype, ytype = _mesh2d_prepare_figure(fig, who, fo)
	line_color = _mesh2d_color(color, who, "color")
	isempty(line_color) && (line_color = _mesh2d_default_color(fig, target))
	line_width = _mesh2d_nonnegative(linewidth, who, "linewidth")
	# `linewidth = 0`: the style's line width (X10), else 0.5 px.
	line_width > 0 || (line_width = Float64(_field2d_style_linewidth(0.5)))
	line_dash = _mesh2d_dash(dash, who)
	alpha = _mesh2d_opacity(opacity, who)
	legend_text = _mesh2d_text(legend, who, "legend")
	isempty(legend_text) || _label(legend_text)
	tri = _mesh2d_triangulation(x, y, triangles, mask, who)
	_mesh2d_tri_check_log(tri, xtype, ytype, who)
	trace = _mesh2d_edges_trace(tri; color = line_color, width = line_width, dash = line_dash, opacity = alpha, legend = legend_text)
	first_new = length(_plot_data(fig)) + 1
	push!(_plot_data(fig), trace)
	_mesh2d_finish!(fig, target, who, fo, cell; constructor = constructor, first_new = first_new)
	return nothing
end

"""
	plot_triplot(x, y, triangles; kwargs...) -> Plot

Draw the edges of a triangular mesh (matplotlib `triplot`): every undirected
edge once, as one line trace.

#### Arguments
- `x, y::AbstractVector{<:Real}`: node coordinates (finite).
- `triangles`: **1-based** `ntri x 3` integer matrix or vector of 3-element
  index vectors.

#### Keywords
- `color = "black"`: line colour (String or Symbol; `""` takes the next colour
  of the figure's colour cycle).
- `linewidth::Real = 0.5`: line width in px.
- `dash = ""`: `"solid"`, `"dot"`, `"dash"`, `"longdash"`, `"dashdot"`,
  `"longdashdot"`, a matplotlib code (`"-"`, `"--"`, `":"`, `"-."`) or a length
  list such as `"5px,3px"`.
- `opacity::Real = 1`, `mask = nothing` (one Bool per triangle, `true` hides
  its edges unless a drawn triangle shares them), `legend::AbstractString =
  ""` (legend name; unnamed traces are hidden from the legend).
- Figure keywords as [`plot_polygons`](@ref): `equalar = true`, `title`,
  `xlabel`, `ylabel`, `xrange`, `yrange`, `xscale`, `yscale`, `width`,
  `height`, `fontsize`, `grid = true`, `show = false`.

Returns a `Plot` (a `SyncPlot` with `show = true`).

#### Example
```julia
x = [0.0, 1.0, 0.0, 1.0]; y = [0.0, 0.0, 1.0, 1.0]
fig = plot_triplot(x, y, [1 2 3; 2 4 3]; color = "gray", legend = "mesh")
```
"""
function plot_triplot(x::AbstractVector, y::AbstractVector, triangles; show = false, kwargs...)
	fig = _mesh2d_new_figure(show, "plot_triplot")
	_mesh2d_triplot_impl!(fig, _Mesh2dTarget(), x, y, triangles; constructor = true, kwargs...)
	return _mesh2d_show(fig, show, _mesh2d_show_options(; kwargs...))
end

"""
	plot_triplot!(fig, x, y, triangles; kwargs...) -> nothing
	plot_triplot!(sf::SubplotFigure, x, y, triangles; row = nothing, col = nothing, secondary_y = false, kwargs...) -> sf

Add triangle-mesh edges to an existing `Plot`, `SyncPlot` (one renderer
transaction) or SubplotFigure cell, e.g. over a [`plot_tripcolor`](@ref).
Keywords as [`plot_triplot`](@ref) except `show` (an `ArgumentError`);
`grid = nothing` leaves the grid unchanged.

Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a SubplotFigure.

#### Example
```julia
x = [0.0, 1.0, 0.0, 1.0]; y = [0.0, 0.0, 1.0, 1.0]; tri = [1 2 3; 2 4 3]
fig = plot_tripcolor(x, y, tri, [1.0, 2.0])
plot_triplot!(fig, x, y, tri; color = "white", linewidth = 1)
```
"""
function plot_triplot!(fig, x::AbstractVector, y::AbstractVector, triangles; kwargs...)
	return _mesh2d_triplot_impl!(fig, _Mesh2dTarget(), x, y, triangles; constructor = false, kwargs...)
end

function plot_triplot!(
	sf::SubplotFigure,
	x::AbstractVector,
	y::AbstractVector,
	triangles;
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	return _mesh2d_subplot!(
		_mesh2d_triplot_impl!, sf, "plot_triplot!", x, y, triangles;
		row, col, secondary_y, inset, kwargs...,
	)
end

# ---------------------------------------------------------------------------
# plot_tricontour
# ---------------------------------------------------------------------------

# "Nice" contour levels strictly inside (lo, hi), at most `n` of them: the
# multiples of the smallest step m * 10^e (m in 1, 2, 2.5, 5, 10 - matplotlib's
# MaxNLocator steps) that leaves at most `n` multiples inside the range.
# Starting one decade below range/n guarantees the first step has more than
# `n` multiples or at least one; consecutive steps grow by at most 2.5x, and a
# range holding two multiples of one step holds at least one of the next, so
# the chosen step always yields between 1 and `n` levels.
function _mesh2d_nice_levels(lo::Float64, hi::Float64, n::Int)
	e0 = floor(Int, log10((hi - lo) / n)) - 1
	for e in e0:(e0 + 2), m in (1.0, 2.0, 2.5, 5.0)
		# k * m / 10^-e keeps decimal steps exact (0.1 * 3 would not be).
		level(k) = e < 0 ? k * m / exp10(-e) : k * m * exp10(e)
		step = level(1)
		# Multiples beyond 2^53 steps from zero are not representable apart;
		# such a range is far below the resolution of its own offset.
		max(abs(lo), abs(hi)) / step < 2.0^53 || break
		kmin = floor(Int, lo / step) + 1
		kmax = ceil(Int, hi / step) - 1
		# Candidates are kmin:kmax minus at most one rounding casualty per
		# end; skip a step with far too many without materialising them.
		kmax - kmin + 1 > n + 2 && continue
		out = Float64[level(k) for k in kmin:kmax if lo < level(k) < hi]
		length(out) <= n && !isempty(out) && return out
	end
	# Only reached when the offset swamps the range: n even levels inside it.
	return unique!(Float64[lo + (hi - lo) * k / (n + 1) for k in 1:n])
end

# Label text of a contour level: up to 6 significant digits, no trailing ".0".
function _mesh2d_level_text(v::Float64)
	r = round(v; sigdigits = 6)
	r == 0 && return "0"
	isinteger(r) && abs(r) < 1e15 && return string(Int(r))
	return string(r)
end

# Contour levels: an integer n gives at most n "nice" levels strictly inside
# the finite data range (none for a constant field); a vector is used as given
# (finite, strictly increasing).
function _mesh2d_contour_levels(levels, v::Vector{Float64}, who::AbstractString)
	if levels isa Integer && !(levels isa Bool)
		levels >= 1 || throw(ArgumentError("$(who): an integer `levels` is a count and must be >= 1; got $(levels)."))
		extent = _finite_extrema(v)
		extent === nothing && return Float64[]
		lo, hi = extent
		lo == hi && return Float64[]
		return _mesh2d_nice_levels(lo, hi, Int(levels))
	end
	out = _checked_real_vector(levels, who, "levels")
	isempty(out) && throw(ArgumentError("$(who): `levels` must not be empty."))
	all(i -> out[i] < out[i + 1], 1:(length(out) - 1)) || throw(ArgumentError(
		"$(who): `levels` must be strictly increasing; got $(repr(levels)).",
	))
	return out
end

# Marching triangles for one level: segments whose endpoints are identified by
# the mesh edge they lie on, joined into polylines through shared edges.
# Returns a vector of polylines, each `(xs, ys)`.
function _mesh2d_contour_lines(t::_Mesh2dTri, v::Vector{Float64}, level::Float64)
	nnodes = length(t.x)
	edge_key(a, b) = a < b ? (a - 1) * nnodes + (b - 1) : (b - 1) * nnodes + (a - 1)
	seg_keys = Tuple{Int, Int}[]
	points = Dict{Int, Tuple{Float64, Float64}}()
	function crossing!(a, b)
		key = edge_key(a, b)
		if !haskey(points, key)
			s = (level - v[a]) / (v[b] - v[a])
			points[key] = (t.x[a] + s * (t.x[b] - t.x[a]), t.y[a] + s * (t.y[b] - t.y[a]))
		end
		return key
	end
	for tri in 1:t.ntri
		_mesh2d_tri_drawn(t, tri) || continue
		n = (t.indices[3tri - 2], t.indices[3tri - 1], t.indices[3tri])
		va, vb, vc = v[n[1]], v[n[2]], v[n[3]]
		(isnan(va) || isnan(vb) || isnan(vc)) && continue
		above = (va >= level, vb >= level, vc >= level)
		nabove = count(above)
		(nabove == 0 || nabove == 3) && continue
		# The odd vertex out is alone on its side; the contour crosses its two edges.
		lone = nabove == 1 ? findfirst(above) : findfirst(!, above)
		p = n[lone]
		q = n[mod1(lone + 1, 3)]
		r = n[mod1(lone + 2, 3)]
		push!(seg_keys, (crossing!(p, q), crossing!(p, r)))
	end
	isempty(seg_keys) && return Tuple{Vector{Float64}, Vector{Float64}}[]
	# Join segments: each crossing point belongs to at most two segments in a
	# manifold mesh; walk the chains.
	incident = Dict{Int, Vector{Int}}()
	for (s, (k1, k2)) in enumerate(seg_keys)
		push!(get!(incident, k1, Int[]), s)
		push!(get!(incident, k2, Int[]), s)
	end
	used = falses(length(seg_keys))
	lines = Tuple{Vector{Float64}, Vector{Float64}}[]
	other(s, key) = seg_keys[s][1] == key ? seg_keys[s][2] : seg_keys[s][1]
	function next_segment(key, from)
		for s in incident[key]
			(s != from && !used[s]) && return s
		end
		return 0
	end
	# Start open chains at ends (points with one incident segment) first, then
	# closed loops anywhere.
	starts = Int[]
	for (key, segs) in incident
		length(segs) == 1 && push!(starts, key)
	end
	sort!(starts)
	function walk!(start_key)
		chain = Int[start_key]
		key = start_key
		from = 0
		while true
			s = next_segment(key, from)
			s == 0 && break
			used[s] = true
			key = other(s, key)
			push!(chain, key)
			from = s
		end
		length(chain) >= 2 || return nothing
		push!(lines, ([points[k][1] for k in chain], [points[k][2] for k in chain]))
		return nothing
	end
	for key in starts
		any(s -> !used[s], incident[key]) && walk!(key)
	end
	for s in eachindex(seg_keys)
		used[s] && continue
		walk!(seg_keys[s][1])
	end
	return lines
end

# Arc-length midpoint of a polyline and its length.
function _mesh2d_polyline_midpoint(xs::Vector{Float64}, ys::Vector{Float64})
	total = 0.0
	for k in 1:(length(xs) - 1)
		total += hypot(xs[k + 1] - xs[k], ys[k + 1] - ys[k])
	end
	half = total / 2
	run = 0.0
	for k in 1:(length(xs) - 1)
		seg = hypot(xs[k + 1] - xs[k], ys[k + 1] - ys[k])
		if run + seg >= half && seg > 0
			s = (half - run) / seg
			return xs[k] + s * (xs[k + 1] - xs[k]), ys[k] + s * (ys[k + 1] - ys[k]), total
		end
		run += seg
	end
	return xs[1], ys[1], total
end

function _mesh2d_tricontour_impl!(
	fig,
	target::_Mesh2dTarget,
	x::AbstractVector,
	y::AbstractVector,
	triangles,
	values::AbstractVector;
	constructor::Bool,
	levels = 10,
	color = "",
	colorscale = _MESH2D_DEFAULT_COLORSCALE,
	crange = [0, 0],
	linewidth = 0,
	dash = "",
	opacity = 1,
	showlabels = false,
	label_fontsize = 0,
	mask = nothing,
	title = "",
	xlabel = "",
	ylabel = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale = "",
	yscale = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid = constructor ? true : nothing,
	equalar = true,
	extra...,
)
	who = constructor ? "plot_tricontour" : "plot_tricontour!"
	_mesh2d_reject_extra(who, extra)
	fo = _mesh2d_figure_options(who; title, xlabel, ylabel, xrange, yrange, xscale, yscale, width, height, fontsize, grid, equalar)
	cell, xtype, ytype = _mesh2d_prepare_figure(fig, who, fo)
	tri = _mesh2d_triangulation(x, y, triangles, mask, who)
	_mesh2d_tri_check_log(tri, xtype, ytype, who)
	nnodes = length(tri.x)
	_mesh2d_check_values(values, nnodes, who, "nodes")
	v = Float64[_mesh2d_tvalue(val, who, i) for (i, val) in enumerate(values)]
	# Only nodes of drawn triangles set integer levels.
	used = falses(nnodes)
	for i in 1:tri.ntri
		_mesh2d_tri_drawn(tri, i) || continue
		used[tri.indices[3i - 2]] = used[tri.indices[3i - 1]] = used[tri.indices[3i]] = true
	end
	level_values = _mesh2d_contour_levels(levels, Float64[used[i] ? v[i] : NaN for i in 1:nnodes], who)
	fixed_color = _mesh2d_color(color, who, "color")
	line_width = _mesh2d_nonnegative(linewidth, who, "linewidth")
	# `linewidth = 0`: the style's line width (X10), else 1 px.
	line_width > 0 || (line_width = Float64(_field2d_style_linewidth(1)))
	line_dash = _mesh2d_dash(dash, who)
	alpha = _mesh2d_opacity(opacity, who)
	_mesh2d_bool(showlabels, who, "showlabels")
	label_size = _mesh2d_nonnegative(label_fontsize, who, "label_fontsize")
	limits = _checked_range(crange, who, "crange")
	if limits !== nothing
		(_mesh2d_is_real(limits[1]) && _mesh2d_is_real(limits[2]) && limits[1] < limits[2]) || throw(ArgumentError(
			"$(who): `crange` must be (lo, hi) with lo < hi; got $(repr(crange)).",
		))
	end
	level_colours = if !isempty(fixed_color)
		fill(fixed_color, length(level_values))
	else
		stops = _mesh2d_stops(colorscale, _mesh2d_layout_source(fig, target), who)
		lo, hi = limits !== nothing ? (Float64(limits[1]), Float64(limits[2])) :
			isempty(level_values) ? (0.0, 1.0) : (first(level_values), last(level_values))
		ts = Float64[hi > lo ? clamp((L - lo) / (hi - lo), 0.0, 1.0) : 0.5 for L in level_values]
		isempty(ts) ? String[] : _sample_colorscale(stops, ts)
	end

	traces = GenericTrace[]
	label_x = Float64[]
	label_y = Float64[]
	label_text = String[]
	label_colour = String[]
	for (k, level) in enumerate(level_values)
		lines = _mesh2d_contour_lines(tri, v, level)
		isempty(lines) && continue
		total = sum(length(l[1]) for l in lines) + length(lines) - 1
		xs = Vector{Union{Nothing, Float64}}(undef, total)
		ys = Vector{Union{Nothing, Float64}}(undef, total)
		p = 0
		longest = 0
		longest_length = -1.0
		for (j, (lx, ly)) in enumerate(lines)
			if j > 1
				p += 1
				xs[p] = _GAP
				ys[p] = _GAP
			end
			for q in eachindex(lx)
				p += 1
				xs[p] = lx[q]
				ys[p] = ly[q]
			end
			if showlabels
				_, _, len = _mesh2d_polyline_midpoint(lx, ly)
				if len > longest_length
					longest_length = len
					longest = j
				end
			end
		end
		text = _mesh2d_level_text(level)
		line = Dict{Symbol, Any}(:color => level_colours[k], :width => line_width)
		isempty(line_dash) || (line[:dash] = line_dash)
		fields = Dict{Symbol, Any}(
			:x => xs,
			:y => ys,
			:mode => "lines",
			:line => attr(line),
			:name => "",
			:showlegend => false,
			:hovertemplate => "$(text)<extra></extra>",
		)
		alpha < 1 && (fields[:opacity] = alpha)
		push!(traces, GenericTrace("scatter", fields))
		if showlabels
			mx, my, _ = _mesh2d_polyline_midpoint(lines[longest]...)
			push!(label_x, mx)
			push!(label_y, my)
			push!(label_text, text)
			push!(label_colour, level_colours[k])
		end
	end
	if showlabels && !isempty(label_x)
		font = Dict{Symbol, Any}(:color => label_colour, :shadow => "auto")
		label_size > 0 && (font[:size] = label_size)
		push!(traces, GenericTrace("scatter", Dict{Symbol, Any}(
			:x => label_x,
			:y => label_y,
			:text => label_text,
			:mode => "text",
			:textposition => "middle center",
			:textfont => attr(font),
			:hoverinfo => "skip",
			:showlegend => false,
			:name => "",
			:cliponaxis => false,
		)))
	end
	first_new = length(_plot_data(fig)) + 1
	append!(_plot_data(fig), traces)
	_mesh2d_finish!(fig, target, who, fo, cell; constructor = constructor, first_new = first_new)
	return nothing
end

"""
	plot_tricontour(x, y, triangles, values; kwargs...) -> Plot

Contour lines of a field given at the nodes of a triangular mesh
(matplotlib `tricontour`), by marching triangles: a node counts as above a
level when its value is `>= level`, and each crossing is interpolated linearly
along the triangle edge. Segments are joined into polylines through shared
mesh edges.

#### Arguments
- `x, y::AbstractVector{<:Real}`: node coordinates (finite).
- `triangles`: **1-based** `ntri x 3` integer matrix or vector of 3-element
  index vectors.
- `values::AbstractVector`: one value per node; triangles touching a
  `missing`/`NaN`/`±Inf` value are skipped.

#### Keywords
- `levels = 10`: an integer `n` (at most `n` round levels, the multiples of
  the smallest step `{1, 2, 2.5, 5} x 10^k` that leaves at most `n` of them
  strictly inside the range of the drawn nodes' values, like matplotlib's
  `MaxNLocator`; none for a constant field) or a strictly increasing vector of
  levels.
- `color = ""`: one colour for every level; `""` colours each level from
  `colorscale = "Viridis"` (`""`: the template's scale) by its position in
  `crange` (default: from the lowest to the highest level).
- `linewidth::Real = 1` (px), `dash = ""` (as [`plot_triplot`](@ref)),
  `opacity::Real = 1`.
- `showlabels::Bool = false`: label each level once, at the arc-length
  midpoint of its longest polyline, in the level's colour with a contrasting
  halo; `label_fontsize::Real = 0` (0 = template size).
- `mask = nothing`: one Bool per triangle, `true` hides it.
- Figure keywords as [`plot_polygons`](@ref): `equalar = true`, `title`,
  `xlabel`, `ylabel`, `xrange`, `yrange`, `xscale`, `yscale`, `width`,
  `height`, `fontsize`, `grid = true`, `show = false`.

#### Plotly encoding
One `scatter` line trace per level that crosses the mesh (polylines separated
by gaps, hover shows the level), plus one `mode = "text"` trace holding the
labels. Labels are a trace rather than annotations so they follow the data
into SubplotFigure cells and onto log axes.

Returns a `Plot` (a `SyncPlot` with `show = true`).

#### Example
```julia
n = 21
xs = [i / (n - 1) for i in 0:n-1, j in 0:n-1]
ys = [j / (n - 1) for i in 0:n-1, j in 0:n-1]
idx = LinearIndices((n, n))
tri = vcat([[idx[i, j] idx[i+1, j] idx[i+1, j+1]; idx[i, j] idx[i+1, j+1] idx[i, j+1]]
            for i in 1:n-1 for j in 1:n-1]...)
f = vec(sin.(3xs) .* cos.(2ys))
fig = plot_tripcolor(vec(xs), vec(ys), tri, f; shading = :gouraud)
plot_tricontour!(fig, vec(xs), vec(ys), tri, f; levels = -0.75:0.25:0.75,
                 color = "black", showlabels = true)
```
"""
function plot_tricontour(x::AbstractVector, y::AbstractVector, triangles, values::AbstractVector; show = false, kwargs...)
	fig = _mesh2d_new_figure(show, "plot_tricontour")
	_mesh2d_tricontour_impl!(fig, _Mesh2dTarget(), x, y, triangles, values; constructor = true, kwargs...)
	return _mesh2d_show(fig, show, _mesh2d_show_options(; kwargs...))
end

"""
	plot_tricontour!(fig, x, y, triangles, values; kwargs...) -> nothing
	plot_tricontour!(sf::SubplotFigure, x, y, triangles, values; row = nothing, col = nothing, secondary_y = false, kwargs...) -> sf

Add triangular-mesh contour lines to an existing `Plot`, `SyncPlot` (one
renderer transaction) or SubplotFigure cell, e.g. over a
[`plot_tripcolor`](@ref). Keywords as [`plot_tricontour`](@ref) except `show`
(an `ArgumentError`); `grid = nothing` leaves the grid unchanged.

Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a SubplotFigure.

#### Example
```julia
x = [0.0, 1.0, 0.0, 1.0]; y = [0.0, 0.0, 1.0, 1.0]; tri = [1 2 3; 2 4 3]
v = [0.0, 1.0, 1.0, 2.0]
fig = plot_tripcolor(x, y, tri, v; shading = :gouraud)
plot_tricontour!(fig, x, y, tri, v; levels = [0.5, 1.0, 1.5], color = "white")
```
"""
function plot_tricontour!(fig, x::AbstractVector, y::AbstractVector, triangles, values::AbstractVector; kwargs...)
	return _mesh2d_tricontour_impl!(fig, _Mesh2dTarget(), x, y, triangles, values; constructor = false, kwargs...)
end

function plot_tricontour!(
	sf::SubplotFigure,
	x::AbstractVector,
	y::AbstractVector,
	triangles,
	values::AbstractVector;
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	return _mesh2d_subplot!(
		_mesh2d_tricontour_impl!, sf, "plot_tricontour!", x, y, triangles, values;
		row, col, secondary_y, inset, kwargs...,
	)
end
