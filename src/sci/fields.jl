# PlotlySupply 2.0 scientific-plotting extensions: plot_matrix, plot_streamlines.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_FIELDS_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# Both functions build on the 2-D field helpers next to plot_heatmap in api.jl
# (`_heatmap_add!`, `_field2d_*`), so the `U[ix, iy]` matrix convention, the
# input validation and the figure options are shared with plot_heatmap,
# plot_contour and plot_quiver.

export plot_matrix, plot_matrix!, plot_streamlines, plot_streamlines!

const _SCI_FIELDS_MUTATORS = (:plot_matrix!, :plot_streamlines!)

#region plot_matrix (spec F28)

# Up to this many rows/columns every index gets its own tick; beyond it
# plotly's automatic ticks keep the labels from overlapping.
const _MATRIX_MAX_INDEX_TICKS = 30

function _matrix_labels(labels, n::Int, who::AbstractString, name::AbstractString, what::AbstractString)
	labels === nothing && return nothing
	(labels isa AbstractVector || labels isa Tuple) || throw(ArgumentError(
		"$(who): `$(name)` must be a vector of $(what) labels; got $(typeof(labels)).",
	))
	isempty(labels) && return nothing
	length(labels) == n || throw(ArgumentError(
		"$(who): `$(name)` needs one label per $(what) ($(n)); got $(length(labels)).",
	))
	return String[label isa AbstractString ? String(label) : string(label) for label in labels]
end

function _matrix_add!(
	fig,
	who::AbstractString,
	A::AbstractMatrix;
	constructor::Bool,
	xlabels,
	ylabels,
	annotate::Bool,
	fmt::AbstractString,
	text,
	textsize,
	colorscale,
	crange,
	cmid,
	colorbar_title::AbstractString,
	colorbar_title_side,
	xlabel::AbstractString,
	ylabel::AbstractString,
	title::AbstractString,
	equalar::Bool,
	tight,
	width,
	height,
	fontsize,
	grid,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	secondary_y::Bool = false,
)
	nrows, ncols = size(A)
	# Tick keywords (G30): `xticks` replaces the index ticks (columns sit at
	# x = 1..ncols); `xticklabels` alone labels the index ticks, like
	# `xlabels`, which it cannot be combined with. Likewise for y and rows.
	for (letter, labels, values, tick_labels) in (
		("x", xlabels, xticks, xticklabels),
		("y", ylabels, yticks, yticklabels),
	)
		(labels !== nothing && (values !== nothing || tick_labels !== nothing)) &&
			throw(ArgumentError(
				"$(who): pass either `$(letter)labels` (one label per " *
				"$(letter == "x" ? "column" : "row")) or `$(letter)ticks`/" *
				"`$(letter)ticklabels`, not both.",
			))
	end
	x_name, y_name = "xlabels", "ylabels"
	if xticks === nothing && xticklabels !== nothing
		xlabels, xticklabels, x_name = xticklabels, nothing, "xticklabels"
	end
	if yticks === nothing && yticklabels !== nothing
		ylabels, yticklabels, y_name = yticklabels, nothing, "yticklabels"
	end
	column_labels = _matrix_labels(xlabels, ncols, who, x_name, "column")
	row_labels = _matrix_labels(ylabels, nrows, who, y_name, "row")
	if text !== nothing
		(text isa AbstractArray && ndims(text) == 2 && size(text) == size(A)) ||
			throw(ArgumentError(
				"$(who): `text` must be a matrix of cell labels with size(A) = " *
				"$(size(A)), indexed text[row, column]; got " *
				"$(text isa AbstractArray ? "size $(size(text))" : typeof(text)).",
			))
	elseif annotate
		(!isempty(strip(fmt)) && !occursin('}', fmt)) || throw(ArgumentError(
			"$(who): `fmt` must be a d3 number format such as \".2f\" or \".3g\"; " *
			"got $(repr(fmt)).",
		))
	end
	template = text !== nothing ? "" : annotate ? "%{z:$(fmt)}" : ""
	ticks(n, labels) =
		labels !== nothing || n <= _MATRIX_MAX_INDEX_TICKS ? (1:n) : nothing
	# Column j is x = j, row i is y = i with the y axis pointing down, so A is
	# drawn as printed (A[1, 1] top left). The heatmap convention U[ix, iy]
	# is A with its dimensions swapped: a lazy, non-recursive PermutedDimsArray
	# (`transpose` would recurse into the entries and fails on strings).
	_heatmap_add!(
		fig,
		who,
		1:ncols,
		1:nrows,
		PermutedDimsArray(A, (2, 1));
		constructor = constructor,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = [0, 0],
		yrange = [0, 0],
		zrange = [0, 0],
		crange = crange,
		cmid = cmid,
		colornorm = :linear,
		levels = nothing,
		colorscale = colorscale,
		showscale = nothing,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		colorbar_ticks = nothing,
		colorbar_ticklabels = nothing,
		coloraxis = nothing,
		text = text === nothing ? nothing : PermutedDimsArray(text, (2, 1)),
		texttemplate = template,
		textsize = textsize,
		origin = "upper",
		xgap = 0,
		ygap = 0,
		xticks = xticks === nothing ? ticks(ncols, column_labels) : xticks,
		xticklabels = xticks === nothing ? column_labels : xticklabels,
		xtickformat = xtickformat,
		yticks = yticks === nothing ? ticks(nrows, row_labels) : yticks,
		yticklabels = yticks === nothing ? row_labels : yticklabels,
		ytickformat = ytickformat,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		equalar = equalar,
		tight = tight,
		xscale = "",
		yscale = "",
		secondary_y = secondary_y,
	)
	return nothing
end

"""
	plot_matrix(A::AbstractMatrix; kwargs...)

Draw a matrix as printed: `A[i, j]` is the cell in row `i` (counted from the
top) and column `j` (from the left), each cell annotated with its value. Rows
are y = 1, 2, ... downwards and columns x = 1, 2, ...; this is a heatmap of
`permutedims(A)` with a reversed y axis (note the difference from
[`plot_heatmap`](@ref), whose `U[ix, iy]` puts the first index on x). Real
entries; NaN/`missing` cells are empty, Bool is drawn as 0/1, complex throws.

#### Keywords
- `xlabels = nothing`, `ylabels = nothing`: one tick label per column / row
  (strings or numbers; LaTeX in `\$...\$` allowed). Without labels, matrices
  with up to $(_MATRIX_MAX_INDEX_TICKS) columns/rows get a tick per index.
- `xticks = nothing`, `xticklabels = nothing`, `xtickformat = ""`, `yticks`,
  `yticklabels`, `ytickformat`: explicit ticks as for
  [`plot_heatmap`](@ref); column `j` sits at x = j and row `i` at y = i.
  `xticks` replaces the index ticks; `xticklabels` alone labels them (one
  per column, the same as `xlabels`, which it cannot be combined with).
- `annotate::Bool = true`: write each value into its cell using `fmt`.
- `fmt = ".2f"`: d3 number format of the annotations (e.g. `".3g"`, `".0%"`).
- `text = nothing`: per-cell labels `text[i, j]` (same size as `A`) that
  replace the formatted values; `<br>` breaks lines.
- `textsize::Real = 0`: annotation font size (0 = automatic). plotly picks a
  contrasting text colour per cell.
- `colorscale = "RdBu_r"`, `crange = [0, 0]`, `cmid = nothing`,
  `colorbar_title = ""`, `colorbar_title_side = :top`: colour mapping and
  colorbar title as for [`plot_heatmap`](@ref) (e.g. `crange = (-1, 1)` or
  `cmid = 0` for a correlation matrix).
- `xlabel = ""`, `ylabel = ""`, `title = ""`.
- `equalar::Bool = true`: square cells.
- `tight::Bool = true`: autoranged axes fit the cell edges without padding;
  `false` restores plotly's padded autorange (as for [`plot_heatmap`](@ref)).
- `grid = true` (template grid, hidden under the cells), `width = 0`,
  `height = 0`, `fontsize = 0`, `show::Bool = false`.

Returns a `Plot` (a `SyncPlot` when `show = true`).

# Example
```julia
C = [1.0 0.8 -0.2; 0.8 1.0 0.1; -0.2 0.1 1.0]
fig = plot_matrix(C; xlabels = ["a", "b", "c"], ylabels = ["a", "b", "c"],
	crange = (-1, 1), colorbar_title = "r")
```
"""
function plot_matrix(
	A::AbstractMatrix;
	xlabels = nothing,
	ylabels = nothing,
	annotate::Bool = true,
	fmt::AbstractString = ".2f",
	text = nothing,
	textsize::Real = 0,
	colorscale = "RdBu_r",
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	equalar::Bool = true,
	tight = true,
	grid::Union{Nothing, Bool, Symbol} = true,
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	fig = _field2d_new_figure()
	_matrix_add!(
		fig,
		"plot_matrix",
		A;
		constructor = true,
		xlabels = xlabels,
		ylabels = ylabels,
		annotate = annotate,
		fmt = fmt,
		text = text,
		textsize = textsize,
		colorscale = colorscale,
		crange = crange,
		cmid = cmid,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		equalar = equalar,
		tight = tight,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		xticks = xticks,
		xticklabels = xticklabels,
		xtickformat = xtickformat,
		yticks = yticks,
		yticklabels = yticklabels,
		ytickformat = ytickformat,
	)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_matrix!(fig, A::AbstractMatrix; secondary_y = false, kwargs...)
	plot_matrix!(sf::SubplotFigure, A::AbstractMatrix; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)

Append a matrix plot (see [`plot_matrix`](@ref) for the layout and the
keywords; `show` is not accepted and throws an `ArgumentError`) to `fig`, a
`Plot` or `SyncPlot`, or to a cell of a `SubplotFigure` (`row`/`col`
together, default: the active cell; `secondary_y` targets the cell's
secondary y axis; `inset = k` targets the `k`-th inset from
[`inset!`](@ref)). The target y axis is reversed so row 1
is at the top; `grid = nothing` keeps the grid. On a `SubplotFigure`,
`title`, `width` and `height` are ignored with a warning.

On a `Plot`/`SyncPlot`, `secondary_y = true` draws on the figure's secondary
y axis (created on first use on the right, overlaying the primary one, as for
[`plot_scatter!`](@ref)); `ylabel`, `yscale`, `yrange` and the y tick keywords
then address that axis, and `equalar` locks its aspect to the x axis (kept
by widening the twin's range: the twin shares the primary axis's domain).

Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
sf = subplots(1, 2; sync = false)
plot_matrix!(sf, [1 2; 3 4]; row = 1, col = 2, fmt = "d")
```
"""
function plot_matrix!(
	fig,
	A::AbstractMatrix;
	xlabels = nothing,
	ylabels = nothing,
	annotate::Bool = true,
	fmt::AbstractString = ".2f",
	text = nothing,
	textsize::Real = 0,
	colorscale = "RdBu_r",
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	equalar::Bool = true,
	tight = true,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	secondary_y = _field2d_reject_keywords("plot_matrix!", kwargs)
	_matrix_add!(
		fig,
		"plot_matrix!",
		A;
		constructor = false,
		xlabels = xlabels,
		ylabels = ylabels,
		annotate = annotate,
		fmt = fmt,
		text = text,
		textsize = textsize,
		colorscale = colorscale,
		crange = crange,
		cmid = cmid,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		equalar = equalar,
		tight = tight,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		xticks = xticks,
		xticklabels = xticklabels,
		xtickformat = xtickformat,
		yticks = yticks,
		yticklabels = yticklabels,
		ytickformat = ytickformat,
		secondary_y = secondary_y,
	)
	_refresh!(fig)
	return nothing
end

function plot_matrix!(
	sf::SubplotFigure,
	A::AbstractMatrix;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	equalar::Bool = true,
	kwargs...,
)
	return _field2d_subplot!(
		sf,
		plot_matrix!,
		(A,);
		row = row,
		col = col,
		secondary_y = secondary_y,
		equalar = equalar,
		kwargs...,
	)
end

#endregion

#region plot_streamlines (spec F29)

# Integration and seeding constants (matplotlib's streamplot defaults):
# - RK4 step of half a grid cell (spec F29);
# - an occupancy mask of 30 x 30 cells at density 1;
# - streamlines shorter than 0.1 domain widths are dropped (minlength);
# - integration stops where the speed falls below 1e-12 of the field's
#   largest speed (a stagnation point; relative, so the units of U and V do
#   not matter);
# - colorby = :speed quantises colours into 32 bins (one trace per bin).
const _STREAMLINE_STEP = 0.5
const _STREAMLINE_MASK_PER_DENSITY = 30
const _STREAMLINE_MIN_LENGTH = 0.1
const _STREAMLINE_SPEED_FLOOR = 1e-12
const _STREAMLINE_COLOR_BINS = 32

# numerics-04, numerics-05: the field is integrated in AXIS units (decades on
# a log axis, as plot_quiver draws its vectors, D13), scaled per axis so that
# one unit is one mean grid cell ("index" coordinates ξ = (X - X₁) * s, with
# s = (n - 1) / (Xₙ - X₁)). The direction (u s_x, v s_y) is then continuous
# across cells of different sizes (a non-uniform grid), and the bilinear
# field is evaluated in the cell that contains the point. On a grid uniform
# in axis units ξ is the grid index, so cells are found without a search.
struct _StreamGrid
	x::Vector{Float64}          # node coordinates in data units
	y::Vector{Float64}
	X::Vector{Float64}          # node coordinates in axis units
	Y::Vector{Float64}
	xlog::Bool
	ylog::Bool
	uniform_x::Bool             # nodes evenly spaced in axis units
	uniform_y::Bool
	sx::Float64                 # index units per axis unit
	sy::Float64
	U::Matrix{Float64}
	V::Matrix{Float64}
	speed_floor::Float64
end

# Evenly spaced within 1e-9 of the span (grids made by `range`, also through
# exp10 for a log axis, are; the residue is far below a drawn pixel).
function _stream_uniform(X::Vector{Float64})
	n = length(X)
	h = (X[n] - X[1]) / (n - 1)
	tol = 1e-9 * (X[n] - X[1])
	return all(i -> abs(X[i] - (X[1] + (i - 1) * h)) <= tol, 1:n)
end

function _stream_grid(xs::Vector{Float64}, ys::Vector{Float64}, xlog::Bool, ylog::Bool,
	U::Matrix{Float64}, V::Matrix{Float64}, speed_floor::Float64)
	X = xlog ? log10.(xs) : xs
	Y = ylog ? log10.(ys) : ys
	return _StreamGrid(
		xs, ys, X, Y, xlog, ylog, _stream_uniform(X), _stream_uniform(Y),
		(length(X) - 1) / (X[end] - X[1]), (length(Y) - 1) / (Y[end] - Y[1]),
		U, V, speed_floor,
	)
end

# The 0-based cell `i0` that contains index coordinate `g` of an axis
# (nodes `A` in axis units) and the fraction `f` of the way across it.
function _stream_cell(A::Vector{Float64}, uniform::Bool, s::Float64, g::Float64)
	n1 = length(A) - 1
	if uniform
		i0 = min(floor(Int, g), n1 - 1)
		return i0, g - i0
	end
	a = A[1] + g / s
	i = clamp(searchsortedlast(A, a), 1, n1)
	return i - 1, (a - A[i]) / (A[i + 1] - A[i])
end

mutable struct _StreamMask
	n::Int
	occupied::Matrix{Bool}
	current::Tuple{Int, Int}
	trajectory::Vector{Tuple{Int, Int}}
end

_stream_float(value) = value === missing ? NaN : Float64(value)

function _stream_axis(v, who::AbstractString, name::AbstractString, log_axis::Bool)
	_field2d_check_coordinates(v, who, name; log_axis = log_axis)
	all(value -> value isa Real, v) || throw(ArgumentError(
		"$(who): `$(name)` must contain numbers (a streamline grid is numeric).",
	))
	length(v) >= 2 || throw(ArgumentError(
		"$(who): `$(name)` needs at least 2 grid points; got $(length(v)).",
	))
	out = Float64[Float64(value) for value in v]
	all(i -> out[i] < out[i + 1], 1:(length(out) - 1)) || throw(ArgumentError(
		"$(who): `$(name)` must be strictly increasing.",
	))
	return out
end

# Bilinear field value at index coordinates (gi, gj) (see `_StreamGrid`).
# Returns (unit direction in index space..., data speed) or `nothing` outside
# the grid, at a gap (NaN/missing) or at a stagnation point.
function _stream_velocity(g::_StreamGrid, gi::Float64, gj::Float64)
	nx1 = length(g.x) - 1
	ny1 = length(g.y) - 1
	(0.0 <= gi <= nx1 && 0.0 <= gj <= ny1) || return nothing
	i0, fx = _stream_cell(g.X, g.uniform_x, g.sx, gi)
	j0, fy = _stream_cell(g.Y, g.uniform_y, g.sy, gj)
	w00 = (1 - fx) * (1 - fy)
	w10 = fx * (1 - fy)
	w01 = (1 - fx) * fy
	w11 = fx * fy
	@inbounds begin
		u = w00 * g.U[i0 + 1, j0 + 1] + w10 * g.U[i0 + 2, j0 + 1] +
			w01 * g.U[i0 + 1, j0 + 2] + w11 * g.U[i0 + 2, j0 + 2]
		v = w00 * g.V[i0 + 1, j0 + 1] + w10 * g.V[i0 + 2, j0 + 1] +
			w01 * g.V[i0 + 1, j0 + 2] + w11 * g.V[i0 + 2, j0 + 2]
		# Axis units per index unit: the cell's own width on an evenly
		# spaced axis (the grid index), the mean cell otherwise.
		cell_x = g.uniform_x ? g.X[i0 + 2] - g.X[i0 + 1] : 1 / g.sx
		cell_y = g.uniform_y ? g.Y[j0 + 2] - g.Y[j0 + 1] : 1 / g.sy
	end
	(isfinite(u) && isfinite(v)) || return nothing
	speed = hypot(u, v)
	speed <= g.speed_floor && return nothing
	wi = u / cell_x
	wj = v / cell_y
	magnitude = hypot(wi, wj)
	(magnitude > 0 && isfinite(magnitude)) || return nothing
	return (wi / magnitude, wj / magnitude, speed)
end

# Largest t in [0, h] with (gi, gj) + t (di, dj) inside the grid.
function _stream_edge_step(gi, gj, di, dj, h, nx1, ny1)
	t = h
	di > 0 && (t = min(t, (nx1 - gi) / di))
	di < 0 && (t = min(t, -gi / di))
	dj > 0 && (t = min(t, (ny1 - gj) / dj))
	dj < 0 && (t = min(t, -gj / dj))
	return max(t, 0.0)
end

_stream_mask_cell(mask::_StreamMask, gi, gj, nx1, ny1) = (
	round(Int, gi / nx1 * (mask.n - 1)) + 1,
	round(Int, gj / ny1 * (mask.n - 1)) + 1,
)

# Move the trajectory into mask cell `cell`; `false` when another streamline
# (or this one, earlier) already occupies it.
function _stream_mask_enter!(mask, cell::Tuple{Int, Int})
	mask === nothing && return true
	cell == mask.current && return true
	mask.occupied[cell...] && return false
	mask.occupied[cell...] = true
	push!(mask.trajectory, cell)
	mask.current = cell
	return true
end

# Integrate one direction (`sign` = +1 forward, -1 backward) from (gi, gj),
# appending the new index-space points. Returns the arc length in domain
# units (the grid scaled to the unit square).
function _stream_integrate!(
	points::Vector{NTuple{2, Float64}},
	g::_StreamGrid,
	mask,
	gi::Float64,
	gj::Float64,
	sign::Float64,
	maxlength::Float64,
)
	nx1 = length(g.x) - 1
	ny1 = length(g.y) - 1
	h = _STREAMLINE_STEP
	total = 0.0
	# Each accepted step advances at least `min_step` domain units, so the
	# loop ends after maxlength / min_step steps at the latest.
	min_step = 1e-3 * h / max(nx1, ny1)
	max_steps = ceil(Int, maxlength / min_step) + 1
	for _ in 1:max_steps
		k1 = _stream_velocity(g, gi, gj)
		k1 === nothing && break
		d1i, d1j = sign * k1[1], sign * k1[2]
		k2 = _stream_velocity(g, gi + h / 2 * d1i, gj + h / 2 * d1j)
		k3 = k2 === nothing ? nothing :
			_stream_velocity(g, gi + h / 2 * sign * k2[1], gj + h / 2 * sign * k2[2])
		k4 = k3 === nothing ? nothing :
			_stream_velocity(g, gi + h * sign * k3[1], gj + h * sign * k3[2])
		final = false
		if k4 === nothing
			# The step leaves the grid or meets a gap: close to the edge,
			# finish with an Euler step onto the boundary; otherwise stop.
			t = _stream_edge_step(gi, gj, d1i, d1j, h, nx1, ny1)
			(t < h && t > 0) || break
			ni = clamp(gi + t * d1i, 0.0, Float64(nx1))
			nj = clamp(gj + t * d1j, 0.0, Float64(ny1))
			final = true
		else
			ni = gi + h / 6 * sign * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1])
			nj = gj + h / 6 * sign * (k1[2] + 2 * k2[2] + 2 * k3[2] + k4[2])
			if !(0.0 <= ni <= nx1 && 0.0 <= nj <= ny1)
				# Every stage lay inside the grid but the combined step leaves
				# it (a curved path along an edge): end on the boundary with an
				# Euler step, as at a stage outside the grid (matplotlib's
				# streamplot does the same).
				t = _stream_edge_step(gi, gj, d1i, d1j, h, nx1, ny1)
				t > 0 || break
				ni = clamp(gi + t * d1i, 0.0, Float64(nx1))
				nj = clamp(gj + t * d1j, 0.0, Float64(ny1))
				final = true
			end
		end
		step = hypot((ni - gi) / nx1, (nj - gj) / ny1)
		(final || step >= min_step) || break
		total + step > maxlength && break
		mask === nothing ||
			_stream_mask_enter!(mask, _stream_mask_cell(mask, ni, nj, nx1, ny1)) ||
			break
		push!(points, (ni, nj))
		total += step
		gi, gj = ni, nj
		final && break
	end
	return total
end

# One streamline through the index point (gi, gj), in flow order, or
# `nothing` when it is shorter than the minimum length.
function _stream_trace_line(
	g::_StreamGrid,
	mask,
	gi::Float64,
	gj::Float64,
	direction::Symbol,
	maxlength::Float64,
)
	nx1 = length(g.x) - 1
	ny1 = length(g.y) - 1
	seed_cell = mask === nothing ? (0, 0) : _stream_mask_cell(mask, gi, gj, nx1, ny1)
	if mask !== nothing
		mask.occupied[seed_cell...] && return nothing
		empty!(mask.trajectory)
		mask.current = seed_cell
		mask.occupied[seed_cell...] = true
		push!(mask.trajectory, seed_cell)
	end
	backward = NTuple{2, Float64}[]
	forward = NTuple{2, Float64}[]
	total = 0.0
	if direction in (:both, :backward)
		total += _stream_integrate!(backward, g, mask, gi, gj, -1.0, maxlength)
	end
	if direction in (:both, :forward)
		mask === nothing || (mask.current = seed_cell)
		total += _stream_integrate!(forward, g, mask, gi, gj, 1.0, maxlength)
	end
	if total < _STREAMLINE_MIN_LENGTH
		if mask !== nothing
			for cell in mask.trajectory
				mask.occupied[cell...] = false
			end
		end
		return nothing
	end
	return vcat(reverse!(backward), [(gi, gj)], forward)
end

# Mask cells in a spiral from the boundary inwards (matplotlib's seeding).
function _stream_spiral(n::Int)
	order = Tuple{Int, Int}[]
	lo_x, hi_x, lo_y, hi_y = 1, n, 1, n
	while lo_x <= hi_x && lo_y <= hi_y
		for i in lo_x:hi_x
			push!(order, (i, lo_y))
		end
		for j in (lo_y + 1):hi_y
			push!(order, (hi_x, j))
		end
		if lo_y < hi_y
			for i in (hi_x - 1):-1:lo_x
				push!(order, (i, hi_y))
			end
		end
		if lo_x < hi_x
			for j in (hi_y - 1):-1:(lo_y + 1)
				push!(order, (lo_x, j))
			end
		end
		lo_x += 1
		hi_x -= 1
		lo_y += 1
		hi_y -= 1
	end
	return order
end

# Index coordinate of data value `value` on an axis (nodes `A` in axis
# units) and back (see `_StreamGrid`).
function _stream_to_index(A::Vector{Float64}, uniform::Bool, s::Float64, log_axis::Bool, value::Float64)
	a = log_axis ? log10(value) : value
	uniform || return (a - A[1]) * s
	i0 = clamp(searchsortedlast(A, a), 1, length(A) - 1)
	return (i0 - 1) + (a - A[i0]) / (A[i0 + 1] - A[i0])
end

function _stream_to_data(A::Vector{Float64}, uniform::Bool, s::Float64, log_axis::Bool, g::Float64)
	a = if uniform
		i0 = min(floor(Int, g), length(A) - 2)
		A[i0 + 1] + (g - i0) * (A[i0 + 2] - A[i0 + 1])
	else
		A[1] + g / s
	end
	return log_axis ? exp10(a) : a
end

function _stream_seeds(seeds, g::_StreamGrid, who::AbstractString)
	points = if seeds isa AbstractMatrix
		size(seeds, 2) == 2 || throw(ArgumentError(
			"$(who): a `seeds` matrix must have 2 columns (x, y); got size $(size(seeds)).",
		))
		[(seeds[k, 1], seeds[k, 2]) for k in axes(seeds, 1)]
	elseif seeds isa AbstractVector
		map(seeds) do point
			((point isa Tuple || point isa AbstractVector) && length(point) == 2) ||
				throw(ArgumentError(
					"$(who): each seed must be an (x, y) pair; got $(repr(point)).",
				))
			(point[1], point[2])
		end
	else
		throw(ArgumentError(
			"$(who): `seeds` must be a vector of (x, y) points or a k×2 matrix; " *
			"got $(typeof(seeds)).",
		))
	end
	out = NTuple{2, Float64}[]
	for (xs, ys) in points
		(xs isa Real && ys isa Real && !(xs isa Bool) && !(ys isa Bool) &&
			isfinite(xs) && isfinite(ys)) || throw(ArgumentError(
			"$(who): seed coordinates must be finite numbers; got ($(repr(xs)), $(repr(ys))).",
		))
		(g.x[1] <= xs <= g.x[end] && g.y[1] <= ys <= g.y[end]) || throw(ArgumentError(
			"$(who): seed ($(xs), $(ys)) lies outside the grid " *
			"[$(g.x[1]), $(g.x[end])] × [$(g.y[1]), $(g.y[end])].",
		))
		push!(out, (
			_stream_to_index(g.X, g.uniform_x, g.sx, g.xlog, Float64(xs)),
			_stream_to_index(g.Y, g.uniform_y, g.sy, g.ylog, Float64(ys)),
		))
	end
	return out
end

# Index-space streamlines of the field.
function _stream_lines(g::_StreamGrid, density::Float64, seeds, direction::Symbol, maxlength::Float64, who::AbstractString)
	lines = Vector{Vector{NTuple{2, Float64}}}()
	if seeds === nothing
		n = max(1, round(Int, _STREAMLINE_MASK_PER_DENSITY * density))
		mask = _StreamMask(n, falses(n, n), (0, 0), Tuple{Int, Int}[])
		nx1 = length(g.x) - 1
		ny1 = length(g.y) - 1
		for (mi, mj) in _stream_spiral(n)
			mask.occupied[mi, mj] && continue
			gi = n == 1 ? nx1 / 2 : (mi - 1) / (n - 1) * nx1
			gj = n == 1 ? ny1 / 2 : (mj - 1) / (n - 1) * ny1
			line = _stream_trace_line(g, mask, Float64(gi), Float64(gj), direction, maxlength)
			line === nothing || push!(lines, line)
		end
	else
		for (gi, gj) in _stream_seeds(seeds, g, who)
			line = _stream_trace_line(g, nothing, gi, gj, direction, maxlength)
			line === nothing || push!(lines, line)
		end
	end
	return lines
end

# Index of the point that carries a streamline's arrow: the first point at
# half the arc length (never the first point, which has no predecessor).
function _stream_arrow_index(line::Vector{NTuple{2, Float64}})
	m = length(line)
	m < 2 && return 0
	lengths = zeros(m)
	for k in 2:m
		lengths[k] = lengths[k - 1] + hypot(line[k][1] - line[k - 1][1], line[k][2] - line[k - 1][2])
	end
	half = lengths[end] / 2
	for k in 2:m
		lengths[k] >= half && return k
	end
	return m
end

# Finite colour values of the traces bound to colour axis `id` of `fig` that
# has no limits yet (`z` of heatmaps and contours; a log-norm carrier stores
# log10 of its data there, given back as data under `colornorm = :log`);
# empty when the axis has limits (`_mesh2d_colour` takes those) or no trace.
function _stream_coloraxis_values(fig, id::String, colornorm)
	_mesh2d_coloraxis_limits(fig, id) === nothing || return Float64[]
	log = colornorm === :log || colornorm == "log"
	values = Float64[]
	for trace in _plot_data(fig)
		get(trace.fields, :coloraxis, nothing) == id || continue
		z = get(trace.fields, :z, nothing)
		z isa AbstractArray || continue
		for v in z
			(v isa Real && !(v isa Bool) && isfinite(v)) || continue
			push!(values, log ? exp10(Float64(v)) : Float64(v))
		end
	end
	return values
end

# The traces of one streamlines call and the colour map of `colorby =
# :speed` (`nothing` without it): `(traces, cm)`.
function _streamlines_traces(
	fig,
	x,
	y,
	U,
	V,
	who::AbstractString;
	xlog::Bool,
	ylog::Bool,
	density,
	seeds,
	maxlength,
	direction,
	arrows::Bool,
	arrowsize,
	color,
	colorby,
	colorscale,
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale = nothing,
	colorbar_title::AbstractString,
	colorbar_title_side::Symbol,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	linewidth,
	legend::AbstractString,
)
	(density isa Real && !(density isa Bool) && isfinite(density) && density > 0) ||
		throw(ArgumentError("$(who): `density` must be a finite number > 0; got $(repr(density))."))
	(maxlength isa Real && !(maxlength isa Bool) && isfinite(maxlength) && maxlength > 0) ||
		throw(ArgumentError("$(who): `maxlength` must be a finite number > 0; got $(repr(maxlength))."))
	(direction isa Symbol || direction isa AbstractString) || throw(ArgumentError(
		"$(who): `direction` must be :forward, :backward or :both; got $(repr(direction)).",
	))
	direction_value = Symbol(lowercase(strip(String(direction))))
	direction_value in (:forward, :backward, :both) || throw(ArgumentError(
		"$(who): `direction` must be :forward, :backward or :both; got $(repr(direction)).",
	))
	(colorby isa Symbol || colorby isa AbstractString) || throw(ArgumentError(
		"$(who): `colorby` must be :none or :speed; got $(repr(colorby)).",
	))
	colorby_value = Symbol(lowercase(strip(String(colorby))))
	colorby_value in (:none, :speed) || throw(ArgumentError(
		"$(who): `colorby` must be :none or :speed; got $(repr(colorby)).",
	))
	_field2d_nonnegative(arrowsize, who, "arrowsize")
	_field2d_nonnegative(linewidth, who, "linewidth")
	colour = _field2d_color_string(color, who, "color")
	by_speed = colorby_value === :speed
	by_speed && !isempty(colour) && throw(ArgumentError(
		"$(who): `color` sets one colour and conflicts with colorby = :speed.",
	))
	if !by_speed
		# fields-05: the colour keywords colour by speed; without it they
		# would be silently ignored.
		given = String[]
		_is_unset_colorscale(colorscale) || push!(given, "`colorscale`")
		_is_auto_range(crange) || push!(given, "`crange`")
		(colornorm === :linear || colornorm == "linear") || push!(given, "`colornorm`")
		for (name, value) in (
			(:cmid, cmid), (:levels, levels), (:showscale, showscale),
			(:colorbar_ticks, colorbar_ticks), (:colorbar_ticklabels, colorbar_ticklabels),
			(:coloraxis, coloraxis),
		)
			value === nothing || push!(given, "`$(name)`")
		end
		isempty(given) || throw(ArgumentError(
			"$(who): $(join(given, ", ")) $(length(given) == 1 ? "applies" : "apply") " *
			"to colorby = :speed; got colorby = :none.",
		))
	end

	xs = _stream_axis(x, who, "x", xlog)
	ys = _stream_axis(y, who, "y", ylog)
	Uf = _field2d_matrix(U, who, "U")
	Vf = _field2d_matrix(V, who, "V")
	_field2d_check_shape(xs, ys, Uf, who; allow_edges = false)
	size(Vf) == size(Uf) || throw(ArgumentError(
		"$(who): U and V must have the same size (length(x), length(y)) = " *
		"$((length(xs), length(ys))); got $(size(Uf)) and $(size(Vf)).",
	))
	Ugrid = Float64[_stream_float(value) for value in Uf]
	Vgrid = Float64[_stream_float(value) for value in Vf]
	largest = 0.0
	for k in eachindex(Ugrid, Vgrid)
		speed = hypot(Ugrid[k], Vgrid[k])
		isfinite(speed) && (largest = max(largest, speed))
	end
	grid = _stream_grid(xs, ys, xlog, ylog, Ugrid, Vgrid, _STREAMLINE_SPEED_FLOOR * largest)
	lines = largest > 0 ?
		_stream_lines(grid, Float64(density), seeds, direction_value, Float64(maxlength), who) :
		Vector{Vector{NTuple{2, Float64}}}()
	isempty(lines) && @warn(
		"$(who): no streamline could be drawn (the field is zero, NaN or the " *
		"seeds lie at stagnation points).",
	)

	name = isempty(legend) ? "" : _label(legend)
	mode = arrows && arrowsize > 0 ? "lines+markers" : "lines"
	# `linewidth = 0`: the style's width, else 1 px (thinner than plotly's
	# 2 px line default, like matplotlib's streamplot).
	line_width = linewidth > 0 ? linewidth : _field2d_style_linewidth(1)
	function line_trace(px, py, sizes, line_colour, first::Bool)
		fields = Dict{Symbol, Any}(
			:x => px,
			:y => py,
			:mode => mode,
			:hoverinfo => "skip",
			:name => first ? name : "",
			:showlegend => first && !isempty(name),
		)
		line = Dict{Symbol, Any}(:width => line_width)
		isempty(line_colour) || (line[:color] = line_colour)
		fields[:line] = attr(; line...)
		if mode == "lines+markers"
			# A per-point `marker.size` array makes plotly.js treat the trace
			# as a bubble chart, whose markers default to opacity 0.7 and a
			# 1 px outline in the background colour: hollow-looking arrowheads
			# (D10 M5). Arrowheads are solid in the line colour: full opacity
			# and no outline (the marker colour defaults to the line colour).
			marker = Dict{Symbol, Any}(
				:symbol => "arrow",
				:angleref => "previous",
				:size => sizes,
				:opacity => 1,
				:line => attr(width = 0),
			)
			isempty(line_colour) || (marker[:color] = line_colour)
			fields[:marker] = attr(; marker...)
		end
		return scatter(; fields...)
	end
	data_x(point) = _stream_to_data(grid.X, grid.uniform_x, grid.sx, grid.xlog, point[1])
	data_y(point) = _stream_to_data(grid.Y, grid.uniform_y, grid.sy, grid.ylog, point[2])
	# D16: the anchor extent of the streamlines is the field grid they are
	# integrated on (every line and seed lies inside it).
	anchors = (xs[1], xs[end], ys[1], ys[end])

	if !by_speed
		px = Union{Nothing, Float64}[]
		py = Union{Nothing, Float64}[]
		sizes = Float64[]
		for line in lines
			arrow = _stream_arrow_index(line)
			for (k, point) in enumerate(line)
				push!(px, data_x(point))
				push!(py, data_y(point))
				push!(sizes, k == arrow ? Float64(arrowsize) : 0.0)
			end
			push!(px, _GAP)
			push!(py, _GAP)
			push!(sizes, 0.0)
		end
		return _field2d_mark_anchors!(GenericTrace[line_trace(px, py, sizes, colour, true)], anchors...), nothing
	end

	# colorby = :speed: every segment takes the colour bin of its mean speed
	# under the colour norm of the keywords (`crange`, `cmid`, `colornorm`,
	# `levels`, `coloraxis`: the mesh family's, as plot_quiver's `colorby`,
	# fields-05); runs of equal bins become polylines of that bin's trace.
	speeds = [
		[something(_stream_velocity(grid, point...), (0.0, 0.0, NaN))[3] for point in line]
		for line in lines
	]
	segment_speed(ls, k) = isfinite(ls[k]) && isfinite(ls[k + 1]) ? (ls[k] + ls[k + 1]) / 2 :
		isfinite(ls[k]) ? ls[k] : ls[k + 1]
	segment_speeds = Float64[segment_speed(ls, k) for ls in speeds for k in 1:(length(ls) - 1)]
	# The segment colours are fixed here: joining a colour axis without limits
	# (a heatmap of the speed with plotly's automatic range), the limits must
	# also cover the values the axis already shows, or the bar would take the
	# streamlines' range and clip the field.
	shared = coloraxis !== nothing && _is_auto_range(crange) && levels === nothing ?
		_stream_coloraxis_values(fig, _normalize_coloraxis(coloraxis, who), colornorm) : Float64[]
	cm = _mesh2d_colour(
		fig,
		_Mesh2dTarget(),
		isempty(shared) ? segment_speeds : vcat(segment_speeds, shared);
		colorscale = colorscale,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		levels = levels,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
		who = who,
	)
	segment_bin, colours = _mesh2d_bins(cm, _STREAMLINE_COLOR_BINS)
	if isempty(colours)
		# No finite speed to colour by: one empty trace, no colorbar.
		return _field2d_mark_anchors!(
			GenericTrace[line_trace(Union{Nothing, Float64}[], Union{Nothing, Float64}[], Float64[], "", true)],
			anchors...,
		), cm
	end
	nbins = length(colours)
	bin_x = [Union{Nothing, Float64}[] for _ in 1:nbins]
	bin_y = [Union{Nothing, Float64}[] for _ in 1:nbins]
	bin_sizes = [Float64[] for _ in 1:nbins]
	offset = 0
	for line in lines
		m = length(line)
		arrow = _stream_arrow_index(line)
		# A segment without a colour value (no finite speed, or a speed the
		# norm cannot show, e.g. 0 under `:log`) takes the lowest bin, so the
		# line stays whole.
		segment_bins = [max(segment_bin[offset + k], 1) for k in 1:(m - 1)]
		offset += m - 1
		first_segment = 1
		while first_segment <= m - 1
			b = segment_bins[first_segment]
			last_segment = first_segment
			while last_segment < m - 1 && segment_bins[last_segment + 1] == b
				last_segment += 1
			end
			for k in first_segment:(last_segment + 1)
				push!(bin_x[b], data_x(line[k]))
				push!(bin_y[b], data_y(line[k]))
				# The arrow point needs its predecessor in the same run.
				push!(bin_sizes[b], k == arrow && k > first_segment ? Float64(arrowsize) : 0.0)
			end
			push!(bin_x[b], _GAP)
			push!(bin_y[b], _GAP)
			push!(bin_sizes[b], 0.0)
			first_segment = last_segment + 1
		end
	end
	traces = GenericTrace[]
	group_bins = Int[]
	for b in 1:nbins
		isempty(bin_x[b]) && continue
		push!(traces, line_trace(bin_x[b], bin_y[b], bin_sizes[b], colours[b], isempty(traces)))
		push!(group_bins, b)
	end
	isempty(traces) && push!(
		traces,
		line_trace(Union{Nothing, Float64}[], Union{Nothing, Float64}[], Float64[], "", true),
	)
	_field2d_mark_anchors!(traces, anchors...)
	carrier = _mesh2d_carrier(cm, who)
	carrier === nothing || push!(traces, carrier)
	# O3: the bins are recorded so a shared colour axis can recolour them.
	cm.band_edges === nothing && !isempty(group_bins) &&
		_colour_mark_bins!(traces[1:length(group_bins)], group_bins, cm.tvals, cm.cmin, cm.cmax,
			length(colours), colours, carrier; auto = cm.auto)
	return traces, cm
end

function _streamlines_add!(
	fig,
	who::AbstractString,
	x,
	y,
	U,
	V;
	constructor::Bool,
	density,
	seeds,
	maxlength,
	direction,
	arrows::Bool,
	arrowsize,
	color,
	colorby,
	colorscale,
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale = nothing,
	colorbar_title::AbstractString,
	colorbar_title_side,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	linewidth,
	legend::AbstractString,
	xlabel::AbstractString,
	ylabel::AbstractString,
	title::AbstractString,
	xrange,
	yrange,
	xscale::AbstractString,
	yscale::AbstractString,
	xticks,
	xticklabels,
	xtickformat::AbstractString,
	yticks,
	yticklabels,
	ytickformat::AbstractString,
	width,
	height,
	fontsize,
	grid,
	equalar::Bool,
	secondary_y::Bool = false,
)
	xrange = _field2d_checked_range(xrange, who, "xrange")
	yrange = _field2d_checked_range(yrange, who, "yrange")
	twin_key = _scat_twin_key(fig, secondary_y)
	_field2d_validate_cartesian(
		fig,
		who;
		ykey = twin_key,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
	)
	_field2d_validate_ticks(
		fig,
		who;
		xticks = xticks,
		xticklabels = xticklabels,
		xtickformat = xtickformat,
		yticks = yticks,
		yticklabels = yticklabels,
		ytickformat = ytickformat,
		xscale = xscale,
		yscale = yscale,
		ykey = twin_key,
	)
	title_side = _field2d_title_side(colorbar_title_side, who)
	traces, cm = _streamlines_traces(
		fig,
		x,
		y,
		U,
		V,
		who;
		xlog = _field2d_log_axis(fig, :x, xscale),
		ylog = _field2d_log_axis(fig, twin_key, yscale),
		density = density,
		seeds = seeds,
		maxlength = maxlength,
		direction = direction,
		arrows = arrows,
		arrowsize = arrowsize,
		color = color,
		colorby = colorby,
		colorscale = colorscale,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		levels = levels,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
		linewidth = linewidth,
		legend = legend,
	)
	ykey, yref = _stats_target_y!(fig, secondary_y, who)
	_stats_bind_y!(traces, yref)
	first_new = length(_plot_data(fig)) + 1
	append!(_plot_data(fig), traces)
	cm === nothing || _mesh2d_write_coloraxis!(fig, _Mesh2dTarget(), cm, showscale !== nothing)
	_field2d_apply_options!(
		fig,
		who;
		constructor = constructor,
		title = title,
		xlabel = xlabel,
		ylabel = ylabel,
		xscale = xscale,
		yscale = yscale,
		xrange = xrange,
		yrange = yrange,
		xticks = xticks,
		xticklabels = xticklabels,
		xtickformat = xtickformat,
		yticks = yticks,
		yticklabels = yticklabels,
		ytickformat = ytickformat,
		origin = "",
		equalar = equalar,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		ykey = ykey,
	)
	# The width already follows the style (`_field2d_style_linewidth`); the
	# style's dash/marker cycle would dash the speed bins differently and
	# replace the arrowheads, so it is not applied.
	_field2d_finish!(fig, first_new)
	return nothing
end

"""
	plot_streamlines(x, y, U, V; kwargs...)

Draw streamlines of the 2-D vector field `(U, V)` given on the grid `x` × `y`
(numeric, strictly increasing, possibly non-uniform). `U[ix, iy]` and
`V[ix, iy]` are the components at `(x[ix], y[iy])`, so both have size
`(length(x), length(y))`; a mismatch throws an `ArgumentError`. NaN/`missing`
entries mark regions without flow.

The field is interpolated bilinearly and integrated with RK4 steps of half a
grid cell along the flow direction; a streamline stops at the grid edge, at a
gap, at a stagnation point (speed below 1e-12 of the largest speed), when it
runs into another streamline, or after `maxlength`. Without `seeds`, start
points are spread matplotlib-style: an occupancy grid of
`round(30 * density)` cells per side is visited in a spiral from the boundary
inwards and every free cell starts a streamline; streamlines shorter than 0.1
domain widths are dropped.

Axis limits (lead decision D16): on their own (no field on their axes) the
axes span what the streamlines draw plus a 2.5 % pad on each side, so the
arrowheads at the frame stay whole. Over a field (e.g. a heatmap of the same grid) they count
with their grid `x` × `y`, as matplotlib's `streamplot` does: a grid inside
the field keeps the axes tight on the field, and an arrowhead that reaches
past the frame is clipped; a grid beyond the field widens the axes to it
(plus a 2.5 % pad). Pass an explicit `xrange`/`yrange` to show the edge
arrowheads whole. Each line trace stores the grid extent in
`meta.plotlysupply_anchor_extent = [xmin, xmax, ymin, ymax]`.

#### Keywords
- `density::Real = 1`: streamline spacing (2 draws about twice as many).
- `seeds = nothing`: explicit start points, a vector of `(x, y)` pairs or a
  k×2 matrix inside the grid; each draws a full streamline (no occupancy
  grid).
- `maxlength::Real = 4`: maximal length per direction in domain widths (the
  grid scaled to a unit square).
- `direction = :both`: integrate `:forward`, `:backward` or `:both` from each
  start point.
- `arrows::Bool = true`, `arrowsize::Real = 8`: one arrowhead (marker size in
  pixels) at the middle of each streamline, pointing downstream.
- `color = ""`: one colour for all lines and arrowheads (default: the
  template's first colour); not with `colorby = :speed`. Arrowheads are solid
  (opacity 1, no outline) in their line's colour.
- `colorby = :none`: `:speed` colours each segment by the local speed
  `hypot(U, V)` (in $(_STREAMLINE_COLOR_BINS) colour bins, one trace each) and
  adds a colorbar.
- Colour by speed (`colorby = :speed`; passing one of these without it throws
  an `ArgumentError`), as for [`plot_quiver`](@ref)'s `colorby` and the mesh
  family: `colorscale = ""` (template default when unset), `crange = [0, 0]`
  (colour limits; automatic: the speed range, or the limits of an existing
  `coloraxis`), `cmid = nothing`, `colornorm = :linear` (`:log`: LogNorm),
  `levels = nothing` (discrete bands), `showscale = nothing`,
  `colorbar_ticks`/`colorbar_ticklabels` (data values), `coloraxis = nothing`
  (a shared colour axis id such as `:shared`, which [`shared_colorbar!`](@ref)
  and other fields can join); `colorbar_title = ""` (mathtext; a `\$...\$`
  title is drawn as a typeset annotation beside the bar),
  `colorbar_title_side = :top` (`:top`, `:right` or `:bottom`, also as a
  String).
- `linewidth::Real = 0`: line width in px; `0` takes the active style's line
  width ([`with_style`](@ref)) and else 1 px. `legend = ""` (legend name;
  unnamed streamlines have no legend entry).
- `equalar::Bool = false`, `xlabel`, `ylabel`, `title`, `xrange`, `yrange`
  (axis limits in data units, also on log axes; `[0, 0]` or `nothing`:
  automatic), `xscale`, `yscale`, `xticks`, `xticklabels`, `xtickformat`,
  `yticks`, `yticklabels`, `ytickformat`, `grid = true`, `width`, `height`,
  `fontsize`: as for [`plot_heatmap`](@ref). On a log axis the streamlines are
  integrated in decades, so they follow the field as drawn.
- `show::Bool = false`: open a window and return a `SyncPlot`.

Returns a `Plot` (a `SyncPlot` when `show = true`).

# Example
```julia
x = range(-2, 2; length = 41)
y = range(-1, 1; length = 21)
U = [-yi for xi in x, yi in y]                # U[ix, iy]: a vortex
V = [xi for xi in x, yi in y]
fig = plot_streamlines(x, y, U, V; colorby = :speed, equalar = true,
	colorbar_title = "speed")
```
"""
function plot_streamlines(
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray,
	V::AbstractArray;
	density::Real = 1,
	seeds = nothing,
	maxlength::Real = 4,
	direction::Union{Symbol, AbstractString} = :both,
	arrows::Bool = true,
	arrowsize::Real = 8,
	color = "",
	colorby::Union{Symbol, AbstractString} = :none,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	linewidth::Real = 0,
	legend::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	equalar::Bool = false,
	show::Bool = false,
)
	fig = _field2d_new_figure()
	_streamlines_add!(
		fig,
		"plot_streamlines",
		x,
		y,
		U,
		V;
		constructor = true,
		density = density,
		seeds = seeds,
		maxlength = maxlength,
		direction = direction,
		arrows = arrows,
		arrowsize = arrowsize,
		color = color,
		colorby = colorby,
		colorscale = colorscale,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		levels = levels,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
		linewidth = linewidth,
		legend = legend,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		xticks = xticks,
		xticklabels = xticklabels,
		xtickformat = xtickformat,
		yticks = yticks,
		yticklabels = yticklabels,
		ytickformat = ytickformat,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		equalar = equalar,
	)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_streamlines!(fig, x, y, U, V; secondary_y = false, kwargs...)
	plot_streamlines!(sf::SubplotFigure, x, y, U, V; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)

Append streamlines (see [`plot_streamlines`](@ref) for the arguments and
keywords; `show` is not accepted and throws an `ArgumentError`) to `fig`, a
`Plot` or `SyncPlot`, or to a cell of a `SubplotFigure` (`row`/`col`
together, default: the active cell; `secondary_y` targets the cell's
secondary y axis; `inset = k` targets the cell's `k`-th inset from
[`inset!`](@ref) instead). `grid = nothing` keeps the grid; `xrange`/`yrange`
set the target axes' limits (on a log axis in data units), `[0, 0]` or
`nothing` leaves them as they are. On a `SubplotFigure`, `title`, `width` and
`height` are ignored with a warning.

On a `Plot`/`SyncPlot`, `secondary_y = true` draws on the figure's secondary
y axis (created on first use on the right, overlaying the primary one, as for
[`plot_scatter!`](@ref)); `ylabel`, `yscale`, `yrange` and the y tick keywords
then address that axis, and `equalar` locks its aspect to the x axis (kept
by widening the twin's range: the twin shares the primary axis's domain).

Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
x = range(-1, 1; length = 30)
U = [xi for xi in x, yi in x]                 # saddle: (x, -y)
V = [-yi for xi in x, yi in x]
fig = plot_heatmap(x, x, hypot.(U, V))
plot_streamlines!(fig, x, x, U, V; color = "white")
```
"""
function plot_streamlines!(
	fig,
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray,
	V::AbstractArray;
	density::Real = 1,
	seeds = nothing,
	maxlength::Real = 4,
	direction::Union{Symbol, AbstractString} = :both,
	arrows::Bool = true,
	arrowsize::Real = 8,
	color = "",
	colorby::Union{Symbol, AbstractString} = :none,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	linewidth::Real = 0,
	legend::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	equalar::Bool = false,
	kwargs...,
)
	secondary_y = _field2d_reject_keywords("plot_streamlines!", kwargs)
	_streamlines_add!(
		fig,
		"plot_streamlines!",
		x,
		y,
		U,
		V;
		constructor = false,
		density = density,
		seeds = seeds,
		maxlength = maxlength,
		direction = direction,
		arrows = arrows,
		arrowsize = arrowsize,
		color = color,
		colorby = colorby,
		colorscale = colorscale,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		levels = levels,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
		linewidth = linewidth,
		legend = legend,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		xticks = xticks,
		xticklabels = xticklabels,
		xtickformat = xtickformat,
		yticks = yticks,
		yticklabels = yticklabels,
		ytickformat = ytickformat,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		equalar = equalar,
		secondary_y = secondary_y,
	)
	_refresh!(fig)
	return nothing
end

# The streamlines are integrated in axis units (decades on a log axis); the
# delegate's scratch figure carries the target cell's axis types
# (`_SUBPLOT_SEEDED_AXIS_KEYS`), so the Plot-level mutator integrates them
# exactly as on a single figure with those axes (Y3).
function plot_streamlines!(
	sf::SubplotFigure,
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray,
	V::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	equalar::Bool = false,
	kwargs...,
)
	return _field2d_subplot!(
		sf,
		plot_streamlines!,
		(x, y, U, V);
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		equalar = equalar,
		kwargs...,
	)
end

#endregion
