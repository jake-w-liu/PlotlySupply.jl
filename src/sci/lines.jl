# PlotlySupply 2.0 scientific-plotting extensions: plot_band, segment collections, ECDF/KDE/complex-plane plots.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_LINES_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# Every plot here draws on Cartesian axes and shares the scatter family's
# machinery in api.jl (`_scat_*` validation, `_scat_trace`, `_scatter_impl!`,
# `_apply_cartesian_plot_options!`, `_scat_subplot_delegate!`). Each public
# function validates all input before its first write and throws
# `ArgumentError("<function>: ...")` on bad input.

const _SCI_LINES_MUTATORS = (
	:plot_band!,
	:plot_segments!,
	:plot_vlines!,
	:plot_hlines!,
	:plot_ecdf!,
	:plot_kde!,
	:plot_complex!,
)

export plot_band, plot_band!
export plot_segments, plot_segments!, plot_vlines, plot_vlines!, plot_hlines, plot_hlines!
export plot_ecdf, plot_ecdf!, plot_kde, plot_kde!
export plot_complex, plot_complex!

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# The figure keywords of every plot in this file travel as one NamedTuple:
# `(; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
# yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
# height, fontsize)`.

function _lines_validate_figure(fig, who::AbstractString, secondary_y::Bool, figure)
	_scat_validate_cartesian_options(
		fig,
		who;
		ykey = _scat_twin_key(fig, secondary_y),
		xrange = figure.xrange,
		yrange = figure.yrange,
		xscale = figure.xscale,
		yscale = figure.yscale,
		width = figure.width,
		height = figure.height,
		fontsize = figure.fontsize,
		grid = figure.grid,
		xticks = figure.xticks,
		xticklabels = figure.xticklabels,
		yticks = figure.yticks,
		yticklabels = figure.yticklabels,
	)
	return nothing
end

# Axis types ("log", "linear", "-" for unset, ...) the x axis and the target y
# axis end up with after this call, for data checks that depend on them.
function _lines_axis_types(fig, secondary_y::Bool, figure)
	layout = _plot_layout(fig)
	xtype = isempty(figure.xscale) ? _axis_type(layout, :xaxis) : String(figure.xscale)
	ykey = _scat_twin_key(fig, secondary_y)
	ytype = !isempty(figure.yscale) ? String(figure.yscale) :
		ykey === nothing ? "-" : _axis_type(layout, ykey)
	return xtype, ytype
end

# First write of a call: the twin y axis of `secondary_y = true`. Also returns
# the legend state before the call (`_scat_legend_state`), for
# `_lines_apply_figure!`.
function _lines_target_axis!(fig, who::AbstractString, secondary_y::Bool)
	legend_state = _scat_legend_state(fig)
	secondary_y || return :yaxis, "", legend_state
	ykey = _ensure_twin_y!(fig; who = who)
	return ykey, _cmn_axis_ref(ykey; who = who), legend_state
end

function _lines_apply_figure!(
	fig,
	who::AbstractString,
	constructor::Bool,
	ykey::Symbol,
	figure,
	legend_state::Symbol,
)
	# A constructor's `grid = true` keeps the template grid; a mutator applies
	# any non-nothing `grid` (so `true` re-enables a grid switched off earlier).
	constructor || _apply_cartesian_grid_override!(fig, figure.grid, who)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = figure.xlabel,
		ylabel = figure.ylabel,
		# `[nothing, nothing]` is an automatic range, as for `xrange!`.
		xrange = _scat_range_arg(figure.xrange),
		yrange = _scat_range_arg(figure.yrange),
		width = figure.width,
		height = figure.height,
		grid = constructor ? figure.grid : nothing,
		fontsize = figure.fontsize,
		title = figure.title,
		xscale = figure.xscale,
		yscale = figure.yscale,
		xticks = figure.xticks,
		xticklabels = figure.xticklabels,
		yticks = figure.yticks,
		yticklabels = figure.yticklabels,
		xtickformat = figure.xtickformat,
		ytickformat = figure.ytickformat,
		equalar = figure.equalar,
		ykey = ykey,
		apply_template = constructor,
		who = who,
	)
	# A legend created by this call, or one still at its automatic corner, goes
	# to the corner with the least data.
	_scat_place_legend!(fig, legend_state)
	return nothing
end

_lines_new_figure() = Plot(GenericTrace[], _default_cartesian_layout())

_lines_show(fig, show::Bool, figure) =
	_scat_maybe_show(fig, show, figure.width, figure.height, figure.title)

# The position suffix of an error message; built only when a check fails (a
# string per value would cost ~200 B per point on million-point calls, perf-02).
_lines_at(position) = position === nothing ? "" : " at position $(position)"

function _lines_check_value(value, who::AbstractString, name::Symbol, axis_type::AbstractString, position)
	(value isa Real && !(value isa Bool) && isfinite(value)) || throw(ArgumentError(
		"$(who): `$(name)` must hold finite real numbers; got $(repr(value))$(_lines_at(position)).",
	))
	axis_type == "log" && value <= 0 && throw(ArgumentError(
		"$(who): `$(name)` values must be positive on a logarithmic axis; got " *
		"$(value)$(_lines_at(position)).",
	))
	return nothing
end

# `value` (a number, used `m` times, or a vector of length `m`) as finite
# Float64 coordinates. Positions where `mask` is false are not drawn: they may
# hold anything and become NaN.
function _lines_float_values(
	value,
	m::Int,
	who::AbstractString,
	name::Symbol,
	axis_type::AbstractString,
	mask::Union{Nothing, Vector{Bool}} = nothing,
)
	if !(value isa AbstractVector)
		_lines_check_value(value, who, name, axis_type, nothing)
		return fill(Float64(value), m)
	end
	out = Vector{Float64}(undef, m)
	for (position, entry) in enumerate(value)
		if mask !== nothing && !mask[position]
			out[position] = entry isa Real && !(entry isa Bool) ? Float64(entry) : NaN
			continue
		end
		_lines_check_value(entry, who, name, axis_type, position)
		out[position] = Float64(entry)
	end
	return out
end

# A coordinate that may be one number (repeated) or a vector.
function _lines_require_number_or_vector(value, who::AbstractString, name::Symbol)
	(value isa Real && !(value isa Bool)) && return nothing
	value isa AbstractVector && return nothing
	value isa AbstractArray && _scat_require_vector(value, who, name)
	throw(ArgumentError(
		"$(who): `$(name)` must be a real number or a vector; got $(typeof(value)).",
	))
end

# Finite sample values of one series, sorted: NaN and `missing` are dropped,
# infinite and non-real values throw, an empty result throws.
function _lines_sample(values, who::AbstractString, name::Symbol, series::Int, n_series::Int)
	label = n_series > 1 ? "`$(name)` (series $(series))" : "`$(name)`"
	sample = Float64[]
	sizehint!(sample, length(values))
	for entry in values
		entry === missing && continue
		entry isa Complex && _scat_complex_error(who, name)
		(entry isa Real && !(entry isa Bool)) || throw(ArgumentError(
			"$(who): $(label) must hold real numbers; got $(repr(entry)).",
		))
		isnan(entry) && continue
		isfinite(entry) || throw(ArgumentError(
			"$(who): $(label) holds $(entry); infinite values have no place on the axis.",
		))
		push!(sample, Float64(entry))
	end
	isempty(sample) && throw(ArgumentError(
		"$(who): $(label) has no finite values (NaN and missing values are dropped).",
	))
	return sort!(sample)
end

# Samples of a one-series (`x` a vector of values) or several-series (`x` a
# vector of vectors) call.
function _lines_samples(x, who::AbstractString)
	_scat_require_vector(x, who, :x)
	if _is_nested_series(x; who = who)
		n = length(x)
		return [_lines_sample(series, who, :x, index, n) for (index, series) in enumerate(x)]
	end
	return [_lines_sample(x, who, :x, 1, 1)]
end

# ---------------------------------------------------------------------------
# plot_band
# ---------------------------------------------------------------------------

# Per-series inputs of a band call: `x`, `lower`, `upper` and `where` are each
# shared by every band or nested (one entry per band).
function _band_series(x, lower, upper, where, who::AbstractString)
	_scat_require_vector(x, who, :x)
	_lines_require_number_or_vector(lower, who, :lower)
	_lines_require_number_or_vector(upper, who, :upper)
	(where === nothing || where isa AbstractVector) || throw(ArgumentError(
		"$(who): `where` must be nothing, a Bool vector or a vector of Bool vectors " *
		"(one per band); got $(typeof(where)).",
	))
	inputs = ((x, :x), (lower, :lower), (upper, :upper), (where, :where))
	nested = map(input -> _is_nested_series(input[1]; who = who), inputs)
	counts = [length(input[1]) for (input, flag) in zip(inputs, nested) if flag]
	n = isempty(counts) ? 1 : first(counts)
	all(==(n), counts) || throw(ArgumentError(
		"$(who): nested " *
		join(["`$(input[2])` ($(length(input[1])) series)" for (input, flag) in zip(inputs, nested) if flag], ", ") *
		" must hold the same number of bands.",
	))
	per_band(value, flag) = flag ? collect(value) : fill(value, n)
	return n,
		per_band(x, nested[1]),
		per_band(lower, nested[2]),
		per_band(upper, nested[3]),
		per_band(where, nested[4])
end

function _band_mask(where, m::Int, who::AbstractString, band::Int)
	where === nothing && return nothing
	where isa AbstractVector || throw(ArgumentError(
		"$(who): `where` for band $(band) must be a Bool vector; got $(typeof(where)).",
	))
	length(where) == m || throw(ArgumentError(
		"$(who): `where` for band $(band) has $(length(where)) entries but `x` has $(m).",
	))
	mask = Vector{Bool}(undef, m)
	for (position, flag) in enumerate(where)
		flag isa Bool || throw(ArgumentError(
			"$(who): `where` entries must be true or false; got $(repr(flag)) at " *
			"position $(position).",
		))
		mask[position] = flag
	end
	return mask
end

# Closed polygon of one band: for each run of consecutive points where `mask`
# is true (all points when `mask === nothing`), the upper edge left to right
# and the lower edge back. Rings are separated by `_GAP`; `closed` repeats each
# ring's first point so a drawn edge goes all the way round.
function _band_polygon(
	x::Vector{Float64},
	lower::Vector{Float64},
	upper::Vector{Float64},
	mask::Union{Nothing, Vector{Bool}},
	closed::Bool,
)
	m = length(x)
	runs = UnitRange{Int}[]
	position = 1
	while position <= m
		if mask === nothing || mask[position]
			stop = position
			while stop < m && (mask === nothing || mask[stop + 1])
				stop += 1
			end
			push!(runs, position:stop)
			position = stop + 1
		else
			position += 1
		end
	end
	total = sum(run -> 2 * length(run) + closed, runs; init = 0) + max(length(runs) - 1, 0)
	T = length(runs) > 1 ? Union{Nothing, Float64} : Float64
	px = Vector{T}(undef, total)
	py = Vector{T}(undef, total)
	index = 0
	for (ring, run) in enumerate(runs)
		if ring > 1
			index += 1
			px[index] = _GAP
			py[index] = _GAP
		end
		for k in run
			index += 1
			px[index] = x[k]
			py[index] = upper[k]
		end
		for k in reverse(run)
			index += 1
			px[index] = x[k]
			py[index] = lower[k]
		end
		if closed
			index += 1
			px[index] = x[first(run)]
			py[index] = upper[first(run)]
		end
	end
	return px, py
end

function _band_impl!(
	fig,
	x,
	lower,
	upper;
	who::AbstractString,
	constructor::Bool,
	secondary_y::Bool = false,
	color = "",
	opacity::Real = 0.25,
	edgecolor = "",
	linewidth::Real = 0,
	hatch::AbstractString = "",
	where = nothing,
	legend = "",
	showlegend = nothing,
	figure,
)
	n, xs, lowers, uppers, wheres = _band_series(x, lower, upper, where, who)
	fill_opacity = _scat_unit_interval(opacity, who, "opacity")
	edge = _scat_color(edgecolor, who, "edgecolor")
	edge_width = _scat_nonnegative(linewidth, who, "linewidth")
	_lines_validate_figure(fig, who, secondary_y, figure)
	xtype, ytype = _lines_axis_types(fig, secondary_y, figure)
	n_existing = _scat_existing_count(fig)
	# A band takes none of the active style's per-trace defaults: its outline
	# width is the `linewidth` keyword (0: no outline) and it has no dash or
	# markers, so `_scat_apply_style!` is not called for it.
	styles = _scat_series_styles(
		n,
		who;
		color = color,
		legend = legend,
		showlegend = showlegend,
	)
	traces = Vector{GenericTrace}(undef, n)
	# A constructor's figure has no template yet (`_apply_default_template!`
	# runs after the traces), so its default colours come from the layout a new
	# figure gets: the active style's colorway, not plotly's.
	colour_source = constructor && any(isempty(st.color) for st in styles) ? _s3_new_figure_layout() : fig
	for band in 1:n
		xi = xs[band]
		_scat_check_values(xi, who, :x)
		m = length(xi)
		for (value, name) in ((lowers[band], :lower), (uppers[band], :upper))
			value isa AbstractVector && length(value) != m && throw(ArgumentError(
				"$(who): `$(name)`$(n > 1 ? " of band $(band)" : "") has " *
				"$(length(value)) values but `x` has $(m).",
			))
		end
		mask = _band_mask(wheres[band], m, who, band)
		xv = _lines_float_values(xi, m, who, :x, xtype, mask)
		lv = _lines_float_values(lowers[band], m, who, :lower, ytype, mask)
		uv = _lines_float_values(uppers[band], m, who, :upper, ytype, mask)
		px, py = _band_polygon(xv, lv, uv, mask, edge_width > 0)

		style = styles[band]
		band_color = isempty(style.color) ? _scat_default_color(colour_source, n_existing + band) : style.color
		line_color = isempty(edge) ? band_color : edge
		fields = Dict{Symbol, Any}(
			:x => px,
			:y => py,
			:mode => "lines",
			:fill => "toself",
			:fillcolor => _rgba(band_color, fill_opacity; who = who),
			:line => attr(color = line_color, width = edge_width),
			:hoverinfo => "skip",
			:name => isempty(style.name) ? "" : _label(style.name),
		)
		pattern = _hatch_pattern(hatch; color = line_color, who = who)
		pattern === nothing || (fields[:fillpattern] = pattern)
		style.showlegend === nothing || (fields[:showlegend] = style.showlegend)
		traces[band] = GenericTrace("scatter", fields)
	end

	ykey, yref, legend_state = _lines_target_axis!(fig, who, secondary_y)
	for trace in traces
		isempty(yref) || (trace.fields[:yaxis] = yref)
		push!(_plot_data(fig), trace)
	end
	_lines_apply_figure!(fig, who, constructor, ykey, figure, legend_state)
	return nothing
end

"""
	plot_band(x, lower, upper; kwargs...) -> Plot (or SyncPlot with `show = true`)

Filled band between `lower` and `upper` over `x` (matplotlib `fill_between`).
Each band is one closed polygon trace (`fill = "toself"`), so bands stay in
call order in the legend and can be added before or after the lines they
surround. Error bands: `plot_band(x, y .- e, y .+ e)`.

#### Data

- `x`: vector of finite real numbers.
- `lower`, `upper`: vectors with one value per `x`, or numbers (a constant
  edge), e.g. `plot_band(x, 0, y)`.
- Several bands: pass a vector of vectors in `x`, `lower`, `upper` and/or
  `where` (one entry per band); the others are shared.
- Values must be finite (and positive on a logarithmic axis) wherever the band
  is drawn; points excluded by `where` may hold anything.

#### Keywords

- `where = nothing`: a `Bool` vector, one entry per `x`: the band is drawn
  only over runs of consecutive `true` points (one polygon ring per run, as in
  matplotlib without `interpolate`).
- `color = ""`: band colour (`""`: the next colorway colour), any colour
  [`plot_scatter`](@ref) takes (grey levels such as `"0.35"`, Colors.jl
  `Colorant`s); a vector gives one colour per band. `opacity = 0.25`: fill
  opacity in [0, 1].
- `edgecolor = ""`, `linewidth = 0`: outline colour (default: the band colour)
  and width in px (`0`: no outline).
- `hatch = ""`: hatch pattern over the fill (`"/"`, `"\\\\"`, `"x"`, `"-"`,
  `"|"`, `"+"`, `"."`, repeated for density), in the outline colour.
- `legend = ""`, `showlegend = nothing`: legend name and visibility (scalar or
  one per band). Bands show no hover labels.
- `title`, `xlabel`, `ylabel`, `xscale`, `yscale`, `xrange`, `yrange`,
  `xticks`, `xticklabels`, `yticks`, `yticklabels`, `xtickformat`,
  `ytickformat`, `equalar = false`, `grid = true`, `width`, `height`,
  `fontsize`, `show = false`: as for [`plot_scatter`](@ref) (ranges in data
  units with the semantics of [`xrange!`](@ref), tick presets
  `:decades`/`:auto`).

A band takes none of the active [`PlotStyle`](@ref)'s per-trace defaults (its
outline is the `linewidth` keyword). A legend created on a figure holding a
band stays at the default corner.

#### Example

```julia
x = range(0, 10; length = 200)
y = sin.(x)
fig = plot_band(x, y .- 0.2, y .+ 0.2; legend = "±0.2", color = "steelblue")
plot_scatter!(fig, x, y; legend = "sin", color = "steelblue")
```
"""
function plot_band(
	x,
	lower,
	upper;
	color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	opacity::Real = 0.25,
	edgecolor::Union{AbstractString, Symbol, Colors.Colorant} = "",
	linewidth::Real = 0,
	hatch::AbstractString = "",
	where::Union{Nothing, AbstractVector} = nothing,
	legend::Union{AbstractString, AbstractVector} = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	fig = _lines_new_figure()
	_band_impl!(fig, x, lower, upper; who = "plot_band", constructor = true,
		color, opacity, edgecolor, linewidth, hatch, where, legend, showlegend, figure)
	return _lines_show(fig, show, figure)
end

"""
	plot_band!(fig, x, lower, upper; kwargs...) -> nothing (SubplotFigure: the figure)

Add filled band(s) to an existing `Plot`, [`SyncPlot`](@ref) or
`SubplotFigure` cell (see [`plot_band`](@ref) for data and keywords). Takes
every keyword of `plot_band` except `show` (an `ArgumentError`), plus
`secondary_y = false` (draw against a secondary y axis, created on first use
on a `Plot`/`SyncPlot`) and `row`/`col`/`inset` (`SubplotFigure` only: the cell,
or inset `k` of [`inset!`](@ref)). `grid =
nothing` (the default here) keeps the current grid.

#### Example

```julia
x = 0:0.1:5; y = sin.(x); σ = 0.1 .+ 0.05 .* x
fig = plot_scatter(x, y; legend = "mean")
plot_band!(fig, x, y .- σ, y .+ σ; legend = "±σ")
```
"""
function plot_band!(
	fig,
	x,
	lower,
	upper;
	color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	opacity::Real = 0.25,
	edgecolor::Union{AbstractString, Symbol, Colors.Colorant} = "",
	linewidth::Real = 0,
	hatch::AbstractString = "",
	where::Union{Nothing, AbstractVector} = nothing,
	legend::Union{AbstractString, AbstractVector} = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	who = "plot_band!"
	secondary_y = _scat_mutator_options(who, kwargs)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	_band_impl!(fig, x, lower, upper; who, constructor = false, secondary_y,
		color, opacity, edgecolor, linewidth, hatch, where, legend, showlegend, figure)
	_refresh!(fig)
	return nothing
end

# ---------------------------------------------------------------------------
# plot_segments / plot_vlines / plot_hlines
# ---------------------------------------------------------------------------

# One trace of `n` separate line segments (x0[k], y0[k]) -> (x1[k], y1[k]):
# coordinates [x0₁, x1₁, gap, x0₂, x1₂, gap, ...] (length 3n).
function _segments_impl!(
	fig,
	x0,
	y0,
	x1,
	y1;
	who::AbstractString,
	constructor::Bool,
	names::NTuple{4, Symbol} = (:x0, :y0, :x1, :y1),
	secondary_y::Bool = false,
	color = "",
	linewidth::Real = 0,
	dash::AbstractString = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	figure,
)
	coordinates = (x0, y0, x1, y1)
	for (value, name) in zip(coordinates, names)
		_lines_require_number_or_vector(value, who, name)
	end
	lengths = [(length(value), name) for (value, name) in zip(coordinates, names) if value isa AbstractVector]
	n = isempty(lengths) ? 1 : first(lengths)[1]
	all(entry -> entry[1] == n, lengths) || throw(ArgumentError(
		"$(who): " * join(["`$(name)` has $(m)" for (m, name) in lengths], ", ") *
		" values; vectors must have the same length (numbers are repeated).",
	))
	_lines_validate_figure(fig, who, secondary_y, figure)
	xtype, ytype = _lines_axis_types(fig, secondary_y, figure)
	axis_types = (xtype, ytype, xtype, ytype)
	values = [
		_lines_float_values(value, n, who, name, axis_type)
		for (value, name, axis_type) in zip(coordinates, names, axis_types)
	]
	style = only(_scat_series_styles(
		1,
		who;
		mode = "lines",
		dash = dash,
		color = color,
		legend = legend,
		linewidth = linewidth,
		opacity = opacity,
		showlegend = showlegend,
	))
	sx = Vector{Union{Nothing, Float64}}(undef, 3n)
	sy = Vector{Union{Nothing, Float64}}(undef, 3n)
	for k in 1:n
		sx[3k - 2] = values[1][k]
		sy[3k - 2] = values[2][k]
		sx[3k - 1] = values[3][k]
		sy[3k - 1] = values[4][k]
		sx[3k] = _GAP
		sy[3k] = _GAP
	end

	ykey, yref, legend_state = _lines_target_axis!(fig, who, secondary_y)
	data = _plot_data(fig)
	push!(
		data,
		_scat_trace(Dict{Symbol, Any}(:x => sx, :y => sy), "scatter", style, who; yref = yref),
	)
	# A segment collection takes the style's line width and dash cycle (unless
	# `linewidth`/`dash` are given) but no cycle markers on its end points.
	_scat_apply_style!(fig, length(data); explicit = _SCAT_STYLE_NO_MARKERS)
	_lines_apply_figure!(fig, who, constructor, ykey, figure, legend_state)
	return nothing
end

const _SEGMENTS_STYLE_DOC = """
- `color = ""`: line colour (`""`: the next colorway colour; grey levels such
  as `"0.35"` and Colors.jl `Colorant`s are accepted); `linewidth = 0`
  (px, `0`: the active [`PlotStyle`](@ref)'s line width, else plotly's);
  `dash = ""` (`"dash"`, `"dot"`, ..., as for [`plot_scatter`](@ref); `""`:
  the style's dash cycle, else solid); `opacity = 1`. The style's marker
  cycle does not apply (no markers on the end points).
- `legend = ""`, `showlegend = nothing`: one legend entry for the whole
  collection.
- `title`, `xlabel`, `ylabel`, `xscale`, `yscale`, `xrange`, `yrange`,
  `xticks`, `xticklabels`, `yticks`, `yticklabels`, `xtickformat`,
  `ytickformat`, `equalar = false`, `grid = true`, `width`, `height`,
  `fontsize`, `show = false`: as for `plot_scatter` (ranges in data units
  with the semantics of [`xrange!`](@ref), tick presets `:decades`/`:auto`;
  a new legend avoids the data).
"""

"""
	plot_segments(x0, y0, x1, y1; kwargs...) -> Plot (or SyncPlot with `show = true`)

Collection of separate straight segments from `(x0[k], y0[k])` to
`(x1[k], y1[k])` (matplotlib `LineCollection`), drawn as ONE trace: the
coordinates are `[x0₁, x1₁, gap, x0₂, x1₂, gap, ...]`, so a million segments
cost one trace and one legend entry.

#### Data

`x0`, `y0`, `x1`, `y1`: vectors of equal length or numbers (repeated for every
segment), finite real values (positive on a logarithmic axis). A length
mismatch is an `ArgumentError`.

#### Keywords

$(_SEGMENTS_STYLE_DOC)

#### Example

```julia
θ = range(0, π; length = 12)
fig = plot_segments(zeros(12), zeros(12), cos.(θ), sin.(θ); color = "gray", equalar = true)
```
"""
function plot_segments(
	x0,
	y0,
	x1,
	y1;
	color::Union{AbstractString, Symbol, Colors.Colorant} = "",
	linewidth::Real = 0,
	dash::AbstractString = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	fig = _lines_new_figure()
	_segments_impl!(fig, x0, y0, x1, y1; who = "plot_segments", constructor = true,
		color, linewidth, dash, opacity, legend, showlegend, figure)
	return _lines_show(fig, show, figure)
end

"""
	plot_segments!(fig, x0, y0, x1, y1; kwargs...) -> nothing (SubplotFigure: the figure)

Add a segment collection (see [`plot_segments`](@ref)) to an existing `Plot`,
[`SyncPlot`](@ref) or `SubplotFigure` cell. Takes every keyword of
`plot_segments` except `show`, plus `secondary_y = false` and `row`/`col`/`inset`
(`SubplotFigure` only: the cell, or inset `k` of [`inset!`](@ref)); `grid = nothing` keeps the current grid.
"""
function plot_segments!(
	fig,
	x0,
	y0,
	x1,
	y1;
	color::Union{AbstractString, Symbol, Colors.Colorant} = "",
	linewidth::Real = 0,
	dash::AbstractString = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	who = "plot_segments!"
	secondary_y = _scat_mutator_options(who, kwargs)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	_segments_impl!(fig, x0, y0, x1, y1; who, constructor = false, secondary_y,
		color, linewidth, dash, opacity, legend, showlegend, figure)
	_refresh!(fig)
	return nothing
end

"""
	plot_vlines(x, ymin, ymax; kwargs...) -> Plot (or SyncPlot with `show = true`)

Vertical lines at `x` from `ymin` to `ymax` (matplotlib `vlines`), drawn as one
segment trace (see [`plot_segments`](@ref)). `x` is a vector or a number;
`ymin`/`ymax` are vectors of the same length or numbers shared by every line.
These are data lines: for a reference line spanning the whole axis use
`vline!`.

#### Keywords

$(_SEGMENTS_STYLE_DOC)

#### Example

```julia
f = [1.0, 2.5, 4.0]; w = [0.3, 1.0, 0.6]
fig = plot_vlines(f, 0, w; linewidth = 2, xlabel = "frequency", ylabel = "weight")
```
"""
function plot_vlines(
	x,
	ymin,
	ymax;
	color::Union{AbstractString, Symbol, Colors.Colorant} = "",
	linewidth::Real = 0,
	dash::AbstractString = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	fig = _lines_new_figure()
	_segments_impl!(fig, x, ymin, x, ymax; who = "plot_vlines", constructor = true,
		names = (:x, :ymin, :x, :ymax), color, linewidth, dash, opacity, legend,
		showlegend, figure)
	return _lines_show(fig, show, figure)
end

"""
	plot_vlines!(fig, x, ymin, ymax; kwargs...) -> nothing (SubplotFigure: the figure)

Add vertical lines (see [`plot_vlines`](@ref)) to an existing `Plot`,
[`SyncPlot`](@ref) or `SubplotFigure` cell. Takes every keyword of
`plot_vlines` except `show`, plus `secondary_y = false` and `row`/`col`/`inset`
(`SubplotFigure` only: the cell, or inset `k` of [`inset!`](@ref)); `grid = nothing` keeps the current grid.
"""
function plot_vlines!(
	fig,
	x,
	ymin,
	ymax;
	color::Union{AbstractString, Symbol, Colors.Colorant} = "",
	linewidth::Real = 0,
	dash::AbstractString = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	who = "plot_vlines!"
	secondary_y = _scat_mutator_options(who, kwargs)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	_segments_impl!(fig, x, ymin, x, ymax; who, constructor = false, secondary_y,
		names = (:x, :ymin, :x, :ymax), color, linewidth, dash, opacity, legend,
		showlegend, figure)
	_refresh!(fig)
	return nothing
end

"""
	plot_hlines(y, xmin, xmax; kwargs...) -> Plot (or SyncPlot with `show = true`)

Horizontal lines at `y` from `xmin` to `xmax` (matplotlib `hlines`), drawn as
one segment trace (see [`plot_segments`](@ref)). `y` is a vector or a number;
`xmin`/`xmax` are vectors of the same length or numbers shared by every line.
For a reference line spanning the whole axis use `hline!`.

#### Keywords

$(_SEGMENTS_STYLE_DOC)

#### Example

```julia
fig = plot_hlines([1, 2, 3], 0, [5, 3, 4]; color = "black", linewidth = 3)
```
"""
function plot_hlines(
	y,
	xmin,
	xmax;
	color::Union{AbstractString, Symbol, Colors.Colorant} = "",
	linewidth::Real = 0,
	dash::AbstractString = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	fig = _lines_new_figure()
	_segments_impl!(fig, xmin, y, xmax, y; who = "plot_hlines", constructor = true,
		names = (:xmin, :y, :xmax, :y), color, linewidth, dash, opacity, legend,
		showlegend, figure)
	return _lines_show(fig, show, figure)
end

"""
	plot_hlines!(fig, y, xmin, xmax; kwargs...) -> nothing (SubplotFigure: the figure)

Add horizontal lines (see [`plot_hlines`](@ref)) to an existing `Plot`,
[`SyncPlot`](@ref) or `SubplotFigure` cell. Takes every keyword of
`plot_hlines` except `show`, plus `secondary_y = false` and `row`/`col`/`inset`
(`SubplotFigure` only: the cell, or inset `k` of [`inset!`](@ref)); `grid = nothing` keeps the current grid.
"""
function plot_hlines!(
	fig,
	y,
	xmin,
	xmax;
	color::Union{AbstractString, Symbol, Colors.Colorant} = "",
	linewidth::Real = 0,
	dash::AbstractString = "",
	opacity::Real = 1,
	legend::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	who = "plot_hlines!"
	secondary_y = _scat_mutator_options(who, kwargs)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	_segments_impl!(fig, xmin, y, xmax, y; who, constructor = false, secondary_y,
		names = (:xmin, :y, :xmax, :y), color, linewidth, dash, opacity, legend,
		showlegend, figure)
	_refresh!(fig)
	return nothing
end

# ---------------------------------------------------------------------------
# plot_ecdf / plot_kde
# ---------------------------------------------------------------------------

const _ECDF_STATS = (:proportion, :count)

function _ecdf_impl!(
	fig,
	x;
	who::AbstractString,
	constructor::Bool,
	secondary_y::Bool = false,
	complementary::Bool = false,
	stat::Symbol = :proportion,
	color = "",
	dash = "",
	linewidth = 0,
	legend = "",
	showlegend = nothing,
	figure,
)
	samples = _lines_samples(x, who)
	stat in _ECDF_STATS || throw(ArgumentError(
		"$(who): `stat` must be :proportion or :count; got $(repr(stat)).",
	))
	n = length(samples)
	styles = _scat_series_styles(
		n,
		who;
		mode = "lines",
		dash = dash,
		color = color,
		legend = legend,
		linewidth = linewidth,
		showlegend = showlegend,
		line_shape = "hv",
	)
	_lines_validate_figure(fig, who, secondary_y, figure)
	xtype, _ = _lines_axis_types(fig, secondary_y, figure)
	if xtype == "log"
		for (series, sample) in enumerate(samples)
			first(sample) > 0 || throw(ArgumentError(
				"$(who): `x`$(n > 1 ? " (series $(series))" : "") holds " *
				"$(first(sample)); values must be positive on a logarithmic axis.",
			))
		end
	end

	ykey, yref, legend_state = _lines_target_axis!(fig, who, secondary_y)
	for (series, sample) in enumerate(samples)
		m = length(sample)
		ex = Vector{Float64}(undef, m + 1)
		ey = Vector{Float64}(undef, m + 1)
		ex[1] = sample[1]
		ex[2:end] = sample
		total = stat === :count ? m : 1
		for k in 0:m
			below = stat === :count ? k : k / m
			ey[k + 1] = complementary ? total - below : below
		end
		push!(
			_plot_data(fig),
			_scat_trace(
				Dict{Symbol, Any}(:x => ex, :y => ey),
				"scatter",
				styles[series],
				who;
				yref = yref,
			),
		)
	end
	# Step curves take the style's line width and dash cycle, not its markers.
	data = _plot_data(fig)
	_scat_apply_style!(fig, (length(data) - n + 1):length(data); explicit = _SCAT_STYLE_NO_MARKERS)
	_lines_apply_figure!(fig, who, constructor, ykey, figure, legend_state)
	return nothing
end

const _ECDF_DOC_KEYWORDS = """
- `complementary = false`: draw `1 - F(x)` (or `n - count`) instead.
- `stat = :proportion`: `:proportion` (0 to 1) or `:count` (0 to n).
- `color = ""`, `dash = ""`, `linewidth = 0`, `legend = ""`,
  `showlegend = nothing`: line style, each a scalar or one entry per series
  (as for [`plot_scatter`](@ref)); unset `dash`/`linewidth` take the active
  [`PlotStyle`](@ref)'s dash cycle and line width (never its markers).
- `title`, `xlabel`, `ylabel`, `xscale`, `yscale`, `xrange`, `yrange`,
  `xticks`, `xticklabels`, `yticks`, `yticklabels`, `xtickformat`,
  `ytickformat`, `equalar = false`, `grid`, `width`, `height`, `fontsize`:
  as for `plot_scatter` (ranges in data units with the semantics of
  [`xrange!`](@ref), tick presets `:decades`/`:auto`; a new legend avoids the
  data).
"""

"""
	plot_ecdf(x; kwargs...) -> Plot (or SyncPlot with `show = true`)

Empirical cumulative distribution function of the sample `x` (matplotlib
`ecdf`): a step line (`line_shape = "hv"`) through `x = [x₍₁₎; sort(x)]`,
`y = [0; (1:n)/n]`, so it rises by `1/n` at each value and ends at 1.

#### Data

`x`: vector of real numbers, or a vector of vectors (one ECDF per sample).
`NaN` and `missing` values are dropped; infinite values and an empty sample
are an `ArgumentError`.

#### Keywords

$(_ECDF_DOC_KEYWORDS)- `show = false`: open the figure in a window.

#### Example

```julia
fig = plot_ecdf([randn(200), randn(200) .+ 1]; legend = ["a", "b"], xlabel = "value")
```
"""
function plot_ecdf(
	x;
	complementary::Bool = false,
	stat::Symbol = :proportion,
	color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	dash::Union{AbstractString, AbstractVector} = "",
	linewidth::Union{Real, AbstractVector} = 0,
	legend::Union{AbstractString, AbstractVector} = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	fig = _lines_new_figure()
	_ecdf_impl!(fig, x; who = "plot_ecdf", constructor = true, complementary, stat,
		color, dash, linewidth, legend, showlegend, figure)
	return _lines_show(fig, show, figure)
end

"""
	plot_ecdf!(fig, x; kwargs...) -> nothing (SubplotFigure: the figure)

Add ECDF step line(s) (see [`plot_ecdf`](@ref)) to an existing `Plot`,
[`SyncPlot`](@ref) or `SubplotFigure` cell. Takes every keyword of
`plot_ecdf` except `show`, plus `secondary_y = false` and `row`/`col`/`inset`
(`SubplotFigure` only: the cell, or inset `k` of [`inset!`](@ref)); `grid = nothing` keeps the current grid.
"""
function plot_ecdf!(
	fig,
	x;
	complementary::Bool = false,
	stat::Symbol = :proportion,
	color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	dash::Union{AbstractString, AbstractVector} = "",
	linewidth::Union{Real, AbstractVector} = 0,
	legend::Union{AbstractString, AbstractVector} = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	who = "plot_ecdf!"
	secondary_y = _scat_mutator_options(who, kwargs)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	_ecdf_impl!(fig, x; who, constructor = false, secondary_y, complementary, stat,
		color, dash, linewidth, legend, showlegend, figure)
	_refresh!(fig)
	return nothing
end

# Linear-interpolation quantile of a sorted sample (Hyndman-Fan type 7, the
# default of R, NumPy and Statistics.quantile).
function _kde_quantile(sorted::Vector{Float64}, p::Float64)
	h = (length(sorted) - 1) * p + 1
	lo = floor(Int, h)
	hi = min(lo + 1, length(sorted))
	return sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo])
end

# Kernel bandwidth: a positive number as given, or a normal-reference rule.
# :silverman = 0.9 min(σ, IQR/1.34) n^(-1/5) (Silverman 1986, eq. 3.31; σ is
# used when the IQR is 0); :scott = (4/3)^(1/5) σ n^(-1/5) ≈ 1.06 σ n^(-1/5)
# (Scott 1992). σ is the sample standard deviation.
function _kde_bandwidth(sorted::Vector{Float64}, bandwidth, who::AbstractString, label::AbstractString)
	if bandwidth isa Real && !(bandwidth isa Bool)
		(isfinite(bandwidth) && bandwidth > 0) || throw(ArgumentError(
			"$(who): a numeric `bandwidth` must be finite and > 0; got $(repr(bandwidth)).",
		))
		return Float64(bandwidth)
	end
	bandwidth in (:silverman, :scott) || throw(ArgumentError(
		"$(who): `bandwidth` must be :silverman, :scott or a positive number; got " *
		"$(repr(bandwidth)).",
	))
	n = length(sorted)
	n >= 2 || throw(ArgumentError(
		"$(who): the $(repr(bandwidth)) bandwidth of $(label) needs at least 2 finite " *
		"values; got $(n). Pass a numeric `bandwidth`.",
	))
	mean = sum(sorted) / n
	sigma = sqrt(sum(value -> (value - mean)^2, sorted) / (n - 1))
	spread, factor = if bandwidth === :scott
		sigma, (4 / 3)^(1 / 5)
	else
		iqr = _kde_quantile(sorted, 0.75) - _kde_quantile(sorted, 0.25)
		(iqr > 0 ? min(sigma, iqr / 1.34) : sigma), 0.9
	end
	spread > 0 || throw(ArgumentError(
		"$(who): $(label) has zero spread, so the $(repr(bandwidth)) bandwidth is 0; " *
		"pass a numeric `bandwidth`.",
	))
	return factor * spread * n^(-1 / 5)
end

# Gaussian kernel density of `sorted` on the ascending `grid`, summed directly.
# A point more than 40 bandwidths away contributes exp(-800) == 0.0 in Float64,
# so skipping those points (a moving window over the sorted sample) gives the
# same result as the full O(n * npoints) sum.
function _kde_density(sorted::Vector{Float64}, bandwidth::Float64, grid::Vector{Float64})
	n = length(sorted)
	scale = 1 / (n * bandwidth * sqrt(2π))
	reach = 40 * bandwidth
	density = similar(grid)
	lo = 1
	for (j, g) in enumerate(grid)
		while lo <= n && sorted[lo] < g - reach
			lo += 1
		end
		total = 0.0
		k = lo
		while k <= n && sorted[k] <= g + reach
			z = (g - sorted[k]) / bandwidth
			total += exp(-0.5 * z * z)
			k += 1
		end
		density[j] = total * scale
	end
	return density
end

function _kde_impl!(
	fig,
	x;
	who::AbstractString,
	constructor::Bool,
	secondary_y::Bool = false,
	bandwidth = :silverman,
	npoints::Integer = 512,
	cut::Real = 3,
	fill::Bool = false,
	color = "",
	dash = "",
	linewidth = 0,
	legend = "",
	showlegend = nothing,
	figure,
)
	samples = _lines_samples(x, who)
	(npoints isa Bool || npoints < 2) && throw(ArgumentError(
		"$(who): `npoints` must be an integer >= 2; got $(repr(npoints)).",
	))
	(cut isa Bool || !isfinite(cut) || cut < 0) && throw(ArgumentError(
		"$(who): `cut` must be a finite number >= 0 (bandwidths beyond the data); " *
		"got $(repr(cut)).",
	))
	n = length(samples)
	bandwidths = [
		_kde_bandwidth(sample, bandwidth, who, n > 1 ? "`x` (series $(series))" : "`x`")
		for (series, sample) in enumerate(samples)
	]
	styles = _scat_series_styles(
		n,
		who;
		mode = "lines",
		dash = dash,
		color = color,
		legend = legend,
		linewidth = linewidth,
		showlegend = showlegend,
		fill = fill ? "tozeroy" : "",
	)
	_lines_validate_figure(fig, who, secondary_y, figure)
	xtype, _ = _lines_axis_types(fig, secondary_y, figure)
	if xtype == "log"
		# A logarithmic x axis cannot show the curve below 0: the evaluation
		# grid must stay positive.
		for (series, (sample, h)) in enumerate(zip(samples, bandwidths))
			lower = first(sample) - cut * h
			lower > 0 || throw(ArgumentError(
				"$(who): on a logarithmic x axis the curve of `x`" *
				"$(n > 1 ? " (series $(series))" : "") would start at $(lower) <= 0 " *
				"(minimum $(first(sample)) minus `cut` = $(cut) bandwidths of $(h)); " *
				"pass a smaller `cut` or use a linear axis.",
			))
		end
	end

	# Data spanning most of the Float64 range (or a bandwidth that overflows)
	# puts the evaluation grid's ends outside it: an ArgumentError naming the
	# function, not Base's `range` error.
	for (series, (sample, h)) in enumerate(zip(samples, bandwidths))
		lower, upper = first(sample) - cut * h, last(sample) + cut * h
		isfinite(lower) && isfinite(upper) || throw(ArgumentError(
			"$(who): the curve of `x`$(n > 1 ? " (series $(series))" : "") would span [$(lower), $(upper)] " *
			"(the data range plus `cut` = $(cut) bandwidths of $(h)), which is not finite in Float64; " *
			"rescale the data or pass a finite `bandwidth`.",
		))
	end
	curves = map(zip(samples, bandwidths)) do (sample, h)
		grid = collect(range(first(sample) - cut * h, last(sample) + cut * h; length = Int(npoints)))
		return grid, _kde_density(sample, h, grid)
	end
	ykey, yref, legend_state = _lines_target_axis!(fig, who, secondary_y)
	for (series, (grid, density)) in enumerate(curves)
		push!(
			_plot_data(fig),
			_scat_trace(
				Dict{Symbol, Any}(:x => grid, :y => density),
				"scatter",
				styles[series],
				who;
				yref = yref,
			),
		)
	end
	# Dense curves (`npoints` samples) take the style's line width and dash
	# cycle, not its markers, which would hide the curve.
	data = _plot_data(fig)
	_scat_apply_style!(fig, (length(data) - n + 1):length(data); explicit = _SCAT_STYLE_NO_MARKERS)
	_lines_apply_figure!(fig, who, constructor, ykey, figure, legend_state)
	return nothing
end

const _KDE_DOC_KEYWORDS = """
- `bandwidth = :silverman`: kernel standard deviation: `:silverman`
  (`0.9 min(σ, IQR/1.34) n^(-1/5)`, σ when the IQR is 0), `:scott`
  (`(4/3)^(1/5) σ n^(-1/5) ≈ 1.06 σ n^(-1/5)`) or a positive number in data
  units. σ is the sample standard deviation. (SciPy's `gaussian_kde` uses
  other factors under the same names.) The rules need at least 2 values with
  non-zero spread.
- `npoints = 512`: number of evaluation points (>= 2), evenly spaced from
  `minimum(x) - cut * bandwidth` to `maximum(x) + cut * bandwidth`;
  `cut = 3` (>= 0). On a logarithmic x axis the grid must stay positive
  (otherwise an `ArgumentError` asks for a smaller `cut`).
- `fill = false`: fill the area under the curve (`fill = "tozeroy"`).
- `color = ""`, `dash = ""`, `linewidth = 0`, `legend = ""`,
  `showlegend = nothing`: line style, each a scalar or one entry per series
  (as for [`plot_scatter`](@ref)); unset `dash`/`linewidth` take the active
  [`PlotStyle`](@ref)'s dash cycle and line width (never its markers).
- `title`, `xlabel`, `ylabel`, `xscale`, `yscale`, `xrange`, `yrange`,
  `xticks`, `xticklabels`, `yticks`, `yticklabels`, `xtickformat`,
  `ytickformat`, `equalar = false`, `grid`, `width`, `height`, `fontsize`:
  as for `plot_scatter` (ranges in data units with the semantics of
  [`xrange!`](@ref), tick presets `:decades`/`:auto`; a new legend avoids the
  data).
"""

"""
	plot_kde(x; kwargs...) -> Plot (or SyncPlot with `show = true`)

Gaussian kernel density estimate of the sample `x`:
`f(t) = Σᵢ φ((t - xᵢ)/h) / (n h)` with the standard normal density `φ`,
evaluated on an even grid (it integrates to 1 over the real line).

#### Data

`x`: vector of real numbers, or a vector of vectors (one curve per sample).
`NaN` and `missing` values are dropped; infinite values and an empty sample
are an `ArgumentError`.

#### Keywords

$(_KDE_DOC_KEYWORDS)- `show = false`: open the figure in a window.

#### Example

```julia
fig = plot_kde(randn(1000); fill = true, legend = "N(0, 1) sample", xlabel = "x")
```
"""
function plot_kde(
	x;
	bandwidth::Union{Symbol, Real} = :silverman,
	npoints::Integer = 512,
	cut::Real = 3,
	fill::Bool = false,
	color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	dash::Union{AbstractString, AbstractVector} = "",
	linewidth::Union{Real, AbstractVector} = 0,
	legend::Union{AbstractString, AbstractVector} = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	fig = _lines_new_figure()
	_kde_impl!(fig, x; who = "plot_kde", constructor = true, bandwidth, npoints, cut,
		fill, color, dash, linewidth, legend, showlegend, figure)
	return _lines_show(fig, show, figure)
end

"""
	plot_kde!(fig, x; kwargs...) -> nothing (SubplotFigure: the figure)

Add kernel density curve(s) (see [`plot_kde`](@ref)) to an existing `Plot`,
[`SyncPlot`](@ref) or `SubplotFigure` cell. Takes every keyword of `plot_kde`
except `show`, plus `secondary_y = false` and `row`/`col`/`inset` (`SubplotFigure`
only: the cell, or inset `k` of [`inset!`](@ref)); `grid = nothing` keeps the current grid.
"""
function plot_kde!(
	fig,
	x;
	bandwidth::Union{Symbol, Real} = :silverman,
	npoints::Integer = 512,
	cut::Real = 3,
	fill::Bool = false,
	color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	dash::Union{AbstractString, AbstractVector} = "",
	linewidth::Union{Real, AbstractVector} = 0,
	legend::Union{AbstractString, AbstractVector} = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	who = "plot_kde!"
	secondary_y = _scat_mutator_options(who, kwargs)
	figure = (; xlabel, ylabel, xrange, yrange, xscale, yscale, xticks, xticklabels,
		yticks, yticklabels, xtickformat, ytickformat, equalar, grid, title, width,
		height, fontsize)
	_kde_impl!(fig, x; who, constructor = false, secondary_y, bandwidth, npoints, cut,
		fill, color, dash, linewidth, legend, showlegend, figure)
	_refresh!(fig)
	return nothing
end

# ---------------------------------------------------------------------------
# plot_complex
# ---------------------------------------------------------------------------

# The unit circle is a 361-point polyline (1° steps): it departs from the true
# circle by at most 1 - cos(π/360) ≈ 3.8e-5 of the radius. It is a trace rather
# than a layout shape so it follows the series into SubplotFigure cells.
const _COMPLEX_UNIT_CIRCLE_POINTS = 361
# Neutral mid-grey (matplotlib "tab:gray"), dashed, 1 px: visible on light
# and dark templates without competing with the data.
const _COMPLEX_UNIT_CIRCLE_COLOR = "#7f7f7f"

function _complex_unit_circle_trace(yref::AbstractString)
	angles = range(0, 2π; length = _COMPLEX_UNIT_CIRCLE_POINTS)
	fields = Dict{Symbol, Any}(
		:x => cos.(angles),
		:y => sin.(angles),
		:mode => "lines",
		:name => "unit circle",
		:line => attr(color = _COMPLEX_UNIT_CIRCLE_COLOR, width = 1, dash = "dash"),
		:showlegend => false,
		:hoverinfo => "skip",
	)
	isempty(yref) || (fields[:yaxis] = String(yref))
	return GenericTrace("scatter", fields)
end

function _complex_parts_flat(z, who::AbstractString)
	T = eltype(z)
	if !(isconcretetype(T) && T <: Number)
		for (position, value) in enumerate(z)
			(value isa Number || value === missing) || throw(ArgumentError(
				"$(who): `z` must hold numbers (complex or real); got $(repr(value)) at " *
				"position $(position).",
			))
		end
	end
	return real.(z), imag.(z)
end

# Real and imaginary parts of `z` (a vector, or a vector of vectors for several
# series).
function _complex_parts(z, who::AbstractString)
	_scat_require_vector(z, who, :z)
	_is_nested_series(z; who = who) || return _complex_parts_flat(z, who)
	xs = Vector{Any}(undef, length(z))
	ys = Vector{Any}(undef, length(z))
	for (index, series) in enumerate(z)
		xs[index], ys[index] = _complex_parts_flat(series, who)
	end
	return xs, ys
end

function _complex_impl!(fig, z; who::AbstractString, constructor::Bool, unit_circle::Bool, kwargs...)
	x, y = _complex_parts(z, who)
	extra = unit_circle ?
		(target, yref) -> push!(_plot_data(target), _complex_unit_circle_trace(yref)) :
		nothing
	# `mode = nothing` draws markers; the unit circle (added after the series)
	# keeps its own fixed style.
	_scatter_impl!(fig, x, y; who, constructor, default_mode = "markers", extra_traces = extra, kwargs...)
	return nothing
end

"""
	plot_complex(z; kwargs...) -> Plot (or SyncPlot with `show = true`)

Complex numbers in the complex plane: real part on x, imaginary part on y
(Argand diagram), with equal axis scales and axes labelled "Re" and "Im".
The other plot functions reject complex data and point here.

#### Data

`z`: vector of numbers (complex or real; `missing` leaves a gap), or a vector
of vectors (one series each).

#### Keywords

- `mode = nothing`, `dash`, `color`, `legend`, `linewidth`, `line_shape`,
  `simplify`, `marker_size`, `marker_symbol`, `marker_color`, `marker_line_color`,
  `marker_line_width`, `opacity`, `showlegend`, `fill`, `fillcolor`,
  `markevery`, `text`, `textposition`, `textsize`, `clip`: as for
  [`plot_scatter`](@ref) (per-series keywords take a scalar or one entry per
  series; unset ones take the active [`PlotStyle`](@ref)'s per-trace
  defaults). `mode = nothing` draws markers.
- `unit_circle = false`: add the unit circle (dashed grey, no legend entry or
  hover) after the series.
- `equalar = true`: one unit on x spans as many pixels as one unit on y.
- `xlabel = "Re"`, `ylabel = "Im"`, `title`, `xrange`, `yrange`, `xticks`,
  `xticklabels`, `yticks`, `yticklabels`, `xtickformat`, `ytickformat`,
  `grid = true`, `width`, `height`, `fontsize`, `show = false`: as for
  `plot_scatter` (ranges with the semantics of [`xrange!`](@ref)).
- There is no `xscale`/`yscale`: the complex plane has linear axes (a log
  scale cannot show zero or negative parts, and would break `equalar`).

#### Example

```julia
roots = cispi.(2 .* (0:6) ./ 7)
fig = plot_complex(roots; unit_circle = true, legend = "7th roots of unity")
```
"""
function plot_complex(
	z;
	unit_circle::Bool = false,
	mode::Union{Nothing, AbstractString, AbstractVector} = nothing,
	dash::Union{AbstractString, AbstractVector} = "",
	color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	marker_size::Union{Real, AbstractVector} = 0,
	marker_symbol::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	marker_line_color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	marker_line_width::Union{Real, AbstractVector} = 0,
	linewidth::Union{Real, AbstractVector} = 0,
	opacity::Union{Real, AbstractVector} = 1,
	markevery = nothing,
	line_shape::Union{AbstractString, AbstractVector} = "",
	simplify::Union{Nothing, Bool, AbstractVector} = nothing,
	fill::Union{AbstractString, AbstractVector} = "",
	fillcolor::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	text = nothing,
	textposition::AbstractString = "",
	textsize::Real = 0,
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	clip::Bool = true,
	xlabel::AbstractString = "Re",
	ylabel::AbstractString = "Im",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = true,
	grid::Union{Nothing, Bool, Symbol} = true,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	fig = _lines_new_figure()
	_complex_impl!(fig, z; who = "plot_complex", constructor = true, unit_circle,
		mode, dash, color, legend, marker_size, marker_symbol, marker_color,
		marker_line_color, marker_line_width, linewidth, opacity, markevery,
		line_shape, simplify, fill, fillcolor, text, textposition, textsize, showlegend, clip,
		xlabel, ylabel, xrange, yrange, xticks, xticklabels, yticks, yticklabels,
		xtickformat, ytickformat, equalar, grid, title, width, height, fontsize)
	return _scat_maybe_show(fig, show, width, height, title)
end

"""
	plot_complex!(fig, z; kwargs...) -> nothing (SubplotFigure: the figure)

Add complex-plane series (see [`plot_complex`](@ref)) to an existing `Plot`,
[`SyncPlot`](@ref) or `SubplotFigure` cell. Takes every keyword of
`plot_complex` except `show`, plus `secondary_y = false` and `row`/`col`/`inset`
(`SubplotFigure` only: the cell, or inset `k` of [`inset!`](@ref)). Defaults differ where they would overwrite the
figure: `xlabel = ""`, `ylabel = ""` and `equalar = false` leave the axes as
they are, and `grid = nothing` keeps the current grid.
"""
function plot_complex!(
	fig,
	z;
	unit_circle::Bool = false,
	mode::Union{Nothing, AbstractString, AbstractVector} = nothing,
	dash::Union{AbstractString, AbstractVector} = "",
	color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	marker_size::Union{Real, AbstractVector} = 0,
	marker_symbol::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	marker_line_color::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	marker_line_width::Union{Real, AbstractVector} = 0,
	linewidth::Union{Real, AbstractVector} = 0,
	opacity::Union{Real, AbstractVector} = 1,
	markevery = nothing,
	line_shape::Union{AbstractString, AbstractVector} = "",
	simplify::Union{Nothing, Bool, AbstractVector} = nothing,
	fill::Union{AbstractString, AbstractVector} = "",
	fillcolor::Union{AbstractString, Symbol, Colors.Colorant, AbstractVector} = "",
	text = nothing,
	textposition::AbstractString = "",
	textsize::Real = 0,
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	clip::Bool = true,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	who = "plot_complex!"
	secondary_y = _scat_mutator_options(who, kwargs)
	_complex_impl!(fig, z; who, constructor = false, secondary_y, unit_circle,
		mode, dash, color, legend, marker_size, marker_symbol, marker_color,
		marker_line_color, marker_line_width, linewidth, opacity, markevery,
		line_shape, simplify, fill, fillcolor, text, textposition, textsize, showlegend, clip,
		xlabel, ylabel, xrange, yrange, xticks, xticklabels, yticks, yticklabels,
		xtickformat, ytickformat, equalar, grid, title, width, height, fontsize)
	_refresh!(fig)
	return nothing
end

# ---------------------------------------------------------------------------
# SubplotFigure methods (target cell: `row`/`col`, else the active cell)
# ---------------------------------------------------------------------------

for (name, arity) in (
	(:plot_band!, 3),
	(:plot_segments!, 4),
	(:plot_vlines!, 3),
	(:plot_hlines!, 3),
	(:plot_ecdf!, 1),
	(:plot_kde!, 1),
	(:plot_complex!, 1),
)
	@eval function $name(
		sf::SubplotFigure,
		args::Vararg{Any, $arity};
		row::Union{Nothing, Integer} = nothing,
		col::Union{Nothing, Integer} = nothing,
		secondary_y::Bool = false,
		kwargs...,
	)
		return _scat_subplot_delegate!(
			sf,
			$name,
			args...;
			row = row,
			col = col,
			secondary_y = secondary_y,
			kwargs...,
		)
	end
end
