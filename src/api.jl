_plot_obj(fig::Plot) = fig

function _plot_obj(fig)
	if hasproperty(fig, :plot)
		p = getproperty(fig, :plot)
		if p isa Plot
			return p
		end
	end
	throw(ArgumentError("Expected a PlotlyBase.Plot or a SyncPlot-like object with a `plot::Plot` field."))
end

_plot_data(fig) = _plot_obj(fig).data
_plot_layout(fig) = _plot_obj(fig).layout

function _refresh!(fig)
	p = _plot_obj(fig)
	react!(p, p.data, p.layout)
	_plotlyjs_refresh!(fig, p.data, p.layout)
	return nothing
end

const _VALID_TEMPLATES = (
	:plotly_white,
	:plotly_dark,
	:plotly,
	:ggplot2,
	:seaborn,
	:simple_white,
	:presentation,
	:xgridoff,
	:ygridoff,
	:gridon,
)

const _DEFAULT_TEMPLATE = Ref{Symbol}(:plotly_white)
const _VALID_LEGEND_POSITIONS = (
	:topright,
	:top,
	:topleft,
	:right,
	:center,
	:left,
	:bottomright,
	:bottom,
	:bottomleft,
	:outside_right,
	:outside_left,
	:outside_top,
	:outside_bottom,
)
const _DEFAULT_LEGEND_POSITION = Ref{Symbol}(:topright)
const _DEFAULT_LEGEND_INSET = Ref{Tuple{Float64, Float64}}((0.02, 0.03))
const _DEFAULT_LEGEND_BGCOLOR = Ref("rgba(255,255,255,0.72)")
const _DEFAULT_LEGEND_BORDERCOLOR = Ref("rgba(0,0,0,0.15)")
const _DEFAULT_LEGEND_BORDERWIDTH = Ref{Float64}(1.0)

_normalize_template(template) = begin
	template_sym = Symbol(template)
	if template_sym in _VALID_TEMPLATES
		return template_sym
	end
	@warn "Unrecognized template $(repr(template)); falling back to :plotly_white." valid = _VALID_TEMPLATES
	return :plotly_white
end

function _normalize_legend_position(position)
	pos_raw = lowercase(String(position))
	pos_raw = replace(pos_raw, "-" => "_", " " => "_")
	pos = Symbol(pos_raw)
	pos = if pos in (:top_right, :upperright, :upper_right)
		:topright
	elseif pos in (:top_left, :upperleft, :upper_left)
		:topleft
	elseif pos in (:bottom_right, :lowerright, :lower_right)
		:bottomright
	elseif pos in (:bottom_left, :lowerleft, :lower_left)
		:bottomleft
	elseif pos in (:outside, :outside_right, :right_outside, :outsideright, :outerright)
		:outside_right
	elseif pos in (:outside_left, :left_outside, :outsideleft, :outerleft)
		:outside_left
	elseif pos in (:outside_top, :top_outside, :outsidetop, :outertop)
		:outside_top
	elseif pos in (:outside_bottom, :bottom_outside, :outsidebottom, :outerbottom)
		:outside_bottom
	else
		pos
	end
	if pos in _VALID_LEGEND_POSITIONS
		return pos
	end
	@warn "Unrecognized legend position $(repr(position)); falling back to :topright." valid = _VALID_LEGEND_POSITIONS
	return :topright
end

"""
	get_default_template()

Return the package-wide default Plotly template symbol used by high-level constructors.
"""
get_default_template() = _DEFAULT_TEMPLATE[]

"""
	get_default_legend_position()

Return the package-wide default legend position used by high-level constructors.
"""
get_default_legend_position() = _DEFAULT_LEGEND_POSITION[]

"""
	set_default_template!(template = "plotly_white")

Set the package-wide default Plotly template used by high-level constructors.
Invalid values fall back to `:plotly_white`.
"""
function set_default_template!(template = "plotly_white")
	_DEFAULT_TEMPLATE[] = _normalize_template(template)
	return _DEFAULT_TEMPLATE[]
end

"""
	set_default_legend_position!(position = :topright)

Set the package-wide default legend position. Accepted symbols are
`:topright`, `:top`, `:topleft`, `:right`, `:center`, `:left`, `:bottomright`,
`:bottom`, `:bottomleft`, and the outside placements `:outside_right`,
`:outside_left`, `:outside_top`, and `:outside_bottom`. Hyphen/space/alias
forms (e.g. `"top-left"`, `"upper right"`, `:outside`) are normalized, and an
unrecognized value warns and falls back to `:topright`.
"""
function set_default_legend_position!(position = :topright)
	_DEFAULT_LEGEND_POSITION[] = _normalize_legend_position(position)
	return _DEFAULT_LEGEND_POSITION[]
end

function _apply_default_template!(fig)
	relayout!(fig, template = _DEFAULT_TEMPLATE[])
	_apply_default_legend!(fig)
	return nothing
end

function _cartesian_axis_style(; title_text::String = "", tick0 = nothing)
	d = Dict{Symbol, Any}(
		:title_text => title_text,
		:zeroline => false,
		:showline => true,
		:mirror => true,
		:ticks => "outside",
		:automargin => true,
	)
	tick0 === nothing || (d[:tick0] = tick0)
	return attr(; d...)
end

function _default_cartesian_layout(
	;
	title::String = "",
	xlabel::String = "",
	ylabel::String = "",
	x_tick0 = nothing,
	y_tick0 = nothing,
)
	return Layout(
		title = title,
		yaxis = _cartesian_axis_style(title_text = ylabel, tick0 = y_tick0),
		xaxis = _cartesian_axis_style(title_text = xlabel, tick0 = x_tick0),
	)
end

function _apply_default_cartesian_axes!(fig)
	layout_keys = keys(_plot_layout(fig).fields)
	if any(startswith(String(k), "xaxis") for k in layout_keys)
		update_xaxes!(
			fig,
			zeroline = false,
			showline = true,
			mirror = true,
			ticks = "outside",
			automargin = true,
		)
	end
	if any(startswith(String(k), "yaxis") for k in layout_keys)
		update_yaxes!(
			fig,
			zeroline = false,
			showline = true,
			mirror = true,
			ticks = "outside",
			automargin = true,
		)
	end
	return nothing
end

# Apply axis ranges to a 3D `scene` (not the top-level Cartesian axes, which a
# 3D plot does not use). `relayout!` merges into the existing scene, so each
# axis range is set without clobbering titles/aspectmode or the other axes.
function _apply_scene_ranges!(fig; xrange, yrange, zrange)
	if !all(xrange .== [0, 0])
		relayout!(fig, scene = attr(xaxis = attr(range = xrange)))
	end
	if !all(yrange .== [0, 0])
		relayout!(fig, scene = attr(yaxis = attr(range = yrange)))
	end
	if !all(zrange .== [0, 0])
		relayout!(fig, scene = attr(zaxis = attr(range = zrange)))
	end
	return nothing
end

"""
	SubplotFigure

A MATLAB-like subplot canvas returned by [`subplots`](@ref). It wraps the
underlying `Plot`/`SyncPlot` together with the grid shape and the currently
active cell. Select a cell with [`subplot!`](@ref), append to it with the
`plot_*!` mutating constructors, and adjust per-cell axes with [`xlabel!`](@ref)
/ `ylabel!` / `xrange!` / `yrange!`. Property access forwards to the wrapped
figure (e.g. `sf.plot`, `sf.layout`, `sf.data`).
"""
mutable struct SubplotFigure
	fig::Union{Plot, SyncPlot}
	rows::Int
	cols::Int
	current_row::Int
	current_col::Int
	per_subplot_legends::Bool
	legend_position::Symbol
	legend_inset::Tuple{Float64, Float64}
	legend_bgcolor::String
	legend_bordercolor::String
	legend_borderwidth::Float64
end

function Base.getproperty(sf::SubplotFigure, name::Symbol)
	if name === :fig ||
		name === :rows ||
		name === :cols ||
		name === :current_row ||
		name === :current_col ||
		name === :per_subplot_legends ||
		name === :legend_position ||
		name === :legend_inset ||
		name === :legend_bgcolor ||
		name === :legend_bordercolor ||
		name === :legend_borderwidth
		return getfield(sf, name)
	end

	fig = getfield(sf, :fig)
	if name === :plot
		return fig isa Plot ? fig : getproperty(fig, :plot)
	end
	if hasproperty(fig, name)
		return getproperty(fig, name)
	end
	return getfield(sf, name)
end

function Base.propertynames(sf::SubplotFigure, private::Bool = false)
	return (fieldnames(SubplotFigure)..., propertynames(getfield(sf, :fig), private)...)
end

function _symbol_dict(x)
	d = Dict{Symbol, Any}()
	if x isa PlotlyBase.PlotlyAttribute
		for (k, v) in x.fields
			d[Symbol(k)] = v
		end
	elseif x isa AbstractDict
		for (k, v) in x
			d[Symbol(k)] = v
		end
	end
	return d
end

function _domain_tuple(x)
	if x isa Tuple && length(x) == 2
		return (Float64(x[1]), Float64(x[2]))
	elseif x isa AbstractVector && length(x) == 2
		return (Float64(x[1]), Float64(x[2]))
	end
	return nothing
end

function _axis_layout_key(axis_ref::AbstractString, axis::Symbol)
	suffix = replace(axis_ref, r"^[xy]" => "")
	return Symbol((axis === :x ? "xaxis" : "yaxis") * suffix)
end

function _layout_axis_domain(layout::Layout, key::Symbol)
	entry = _symbol_dict(get(layout.fields, key, nothing))
	return _domain_tuple(get(entry, :domain, nothing))
end

function _layout_subplot_domain(layout::Layout, key::Symbol)
	entry = _symbol_dict(get(layout.fields, key, nothing))
	domain = _symbol_dict(get(entry, :domain, nothing))
	xdom = _domain_tuple(get(domain, :x, nothing))
	ydom = _domain_tuple(get(domain, :y, nothing))
	(xdom === nothing || ydom === nothing) && return nothing
	return (xdom, ydom)
end

function _trace_subplot_key_domain(p::Plot, trace::GenericTrace)
	fields = trace.fields

	if haskey(fields, :xaxis) || haskey(fields, :yaxis)
		xaxis = String(get(fields, :xaxis, "x"))
		yaxis = String(get(fields, :yaxis, "y"))
		xdom = _layout_axis_domain(p.layout, _axis_layout_key(xaxis, :x))
		ydom = _layout_axis_domain(p.layout, _axis_layout_key(yaxis, :y))
		(xdom === nothing || ydom === nothing) && return nothing
		return ("xy:" * xaxis * "|" * yaxis, (xdom, ydom))
	end

	if haskey(fields, :scene)
		scene_ref = String(get(fields, :scene, "scene"))
		domain = _layout_subplot_domain(p.layout, Symbol(scene_ref))
		domain === nothing && return nothing
		return ("scene:" * scene_ref, domain)
	end

	if haskey(fields, :subplot)
		subplot_ref = String(get(fields, :subplot, "polar"))
		domain = _layout_subplot_domain(p.layout, Symbol(subplot_ref))
		domain === nothing && return nothing
		return ("subplot:" * subplot_ref, domain)
	end

	return nothing
end

_legend_id(i::Int) = i == 1 ? "legend" : "legend$(i)"
_legend_symbol(i::Int) = i == 1 ? :legend : Symbol("legend$(i)")

function _trace_has_legend_label(trace::GenericTrace)
	name = get(trace.fields, :name, nothing)
	if name === nothing || ismissing(name)
		return false
	end
	if name isa AbstractString
		return !isempty(strip(name))
	end
	return true
end

_trace_showlegend(trace::GenericTrace) = get(trace.fields, :showlegend, false) == true
_trace_will_showlegend(trace::GenericTrace) =
	haskey(trace.fields, :showlegend) ? _trace_showlegend(trace) : _trace_has_legend_label(trace)

function _legend_anchor(
	xdom::Tuple{Float64, Float64},
	ydom::Tuple{Float64, Float64},
	legend_inset::Tuple{Float64, Float64},
	legend_position::Symbol,
)
	xpad = clamp(legend_inset[1], 0.0, 0.49)
	ypad = clamp(legend_inset[2], 0.0, 0.49)
	xleft = xdom[1] + (xdom[2] - xdom[1]) * xpad
	xright = xdom[2] - (xdom[2] - xdom[1]) * xpad
	xcenter = 0.5 * (xdom[1] + xdom[2])
	ybottom = ydom[1] + (ydom[2] - ydom[1]) * ypad
	ytop = ydom[2] - (ydom[2] - ydom[1]) * ypad
	ycenter = 0.5 * (ydom[1] + ydom[2])
	# Outside offsets are a *fixed* paper delta (the inset pad itself), not scaled
	# by the subplot domain width — otherwise a small subplot pushes the legend
	# only a hair outside its domain (into the neighbour). For a full-figure
	# domain (0,1) this matches the previous behaviour exactly.
	xoutside_right = xdom[2] + xpad
	xoutside_left = xdom[1] - xpad
	youtside_top = ydom[2] + ypad
	youtside_bottom = ydom[1] - ypad

	if legend_position == :top
		return xcenter, ytop, "center", "top"
	elseif legend_position == :topleft
		return xleft, ytop, "left", "top"
	elseif legend_position == :right
		return xright, ycenter, "right", "middle"
	elseif legend_position == :center
		return xcenter, ycenter, "center", "middle"
	elseif legend_position == :left
		return xleft, ycenter, "left", "middle"
	elseif legend_position == :bottomright
		return xright, ybottom, "right", "bottom"
	elseif legend_position == :bottom
		return xcenter, ybottom, "center", "bottom"
	elseif legend_position == :bottomleft
		return xleft, ybottom, "left", "bottom"
	elseif legend_position == :outside_right
		return xoutside_right, ytop, "left", "top"
	elseif legend_position == :outside_left
		return xoutside_left, ytop, "right", "top"
	elseif legend_position == :outside_top
		return xcenter, youtside_top, "center", "bottom"
	elseif legend_position == :outside_bottom
		return xcenter, youtside_bottom, "center", "top"
	end

	return xright, ytop, "right", "top"
end

function _legend_layout(
	existing,
	x::Float64,
	y::Float64;
	xanchor::String,
	yanchor::String,
	legend_bgcolor::String,
	legend_bordercolor::String,
	legend_borderwidth::Float64,
	overwrite::Bool = true,
)
	d = _symbol_dict(existing)
	if overwrite
		d[:x] = x
		d[:y] = y
		d[:xanchor] = xanchor
		d[:yanchor] = yanchor
		d[:bgcolor] = legend_bgcolor
		d[:bordercolor] = legend_bordercolor
		d[:borderwidth] = legend_borderwidth
	else
		get!(d, :x, x)
		get!(d, :y, y)
		get!(d, :xanchor, xanchor)
		get!(d, :yanchor, yanchor)
		get!(d, :bgcolor, legend_bgcolor)
		get!(d, :bordercolor, legend_bordercolor)
		get!(d, :borderwidth, legend_borderwidth)
	end
	return attr(; d...)
end

function _apply_subplot_legends!(
	p::Plot;
	legend_position::Symbol,
	legend_inset::Tuple{Float64, Float64},
	legend_bgcolor::String,
	legend_bordercolor::String,
	legend_borderwidth::Float64,
)
	legend_order = String[]
	legend_ids = Dict{String, Int}()
	domains = Dict{String, Tuple{Tuple{Float64, Float64}, Tuple{Float64, Float64}}}()

	for trace in p.data
		key_domain = _trace_subplot_key_domain(p, trace)
		key_domain === nothing && continue
		key, domain = key_domain

		if !haskey(legend_ids, key)
			push!(legend_order, key)
			legend_ids[key] = length(legend_order)
			domains[key] = domain
		end

		trace.fields[:legend] = _legend_id(legend_ids[key])
		if !haskey(trace.fields, :showlegend)
			trace.fields[:showlegend] = _trace_has_legend_label(trace)
		end
	end

	for key in legend_order
		legend_index = legend_ids[key]
		xdom, ydom = domains[key]
		x, y, xanchor, yanchor = _legend_anchor(xdom, ydom, legend_inset, legend_position)
		legend_sym = _legend_symbol(legend_index)
		p.layout.fields[legend_sym] = _legend_layout(
			get(p.layout.fields, legend_sym, nothing),
			x,
			y;
			xanchor = xanchor,
			yanchor = yanchor,
			legend_bgcolor = legend_bgcolor,
			legend_bordercolor = legend_bordercolor,
			legend_borderwidth = legend_borderwidth,
		)
	end
	if any(_trace_showlegend(trace) for trace in p.data)
		p.layout.fields[:showlegend] = true
	end

	return p
end

function _apply_default_legend!(
	fig;
	position::Union{Symbol, AbstractString} = _DEFAULT_LEGEND_POSITION[],
	inset::Tuple{<:Real, <:Real} = _DEFAULT_LEGEND_INSET[],
	bgcolor::String = _DEFAULT_LEGEND_BGCOLOR[],
	bordercolor::String = _DEFAULT_LEGEND_BORDERCOLOR[],
	borderwidth::Real = _DEFAULT_LEGEND_BORDERWIDTH[],
	overwrite::Bool = false,
	showlegend::Union{Nothing, Bool} = nothing,
)
	p = _plot_obj(fig)
	legend_position = _normalize_legend_position(position)
	legend_inset = (Float64(inset[1]), Float64(inset[2]))
	x, y, xanchor, yanchor = _legend_anchor((0.0, 1.0), (0.0, 1.0), legend_inset, legend_position)

	# Only write a styled legend block when a legend will actually show (a trace
	# with a name/showlegend), one already exists, or the caller forces it
	# (`overwrite=true`, i.e. an explicit `set_legend!`). This keeps empty
	# canvases and unnamed single-trace figures free of stray legend layout.
	if overwrite || haskey(p.layout.fields, :legend) || any(_trace_will_showlegend(trace) for trace in p.data)
		p.layout.fields[:legend] = _legend_layout(
			get(p.layout.fields, :legend, nothing),
			x,
			y;
			xanchor = xanchor,
			yanchor = yanchor,
			legend_bgcolor = bgcolor,
			legend_bordercolor = bordercolor,
			legend_borderwidth = Float64(borderwidth),
			overwrite = overwrite,
		)
	end
	if showlegend isa Bool
		# Explicit caller override (e.g. force a legend for a single unnamed trace).
		p.layout.fields[:showlegend] = showlegend
	elseif !haskey(p.layout.fields, :showlegend) && any(_trace_will_showlegend(trace) for trace in p.data)
		p.layout.fields[:showlegend] = true
	end
	return p
end

"""
	set_legend!(fig; position=:topright, showlegend=nothing, kwargs...)

Set legend placement and styling with simple position symbols such as
`:top`, `:topright`, `:left`, `:bottomleft`, or `:outside_right`. Accepted
positions also include `:bottom`, `:right`, `:center`, `:topleft`,
`:bottomright`, `:outside_left`, `:outside_top`, and `:outside_bottom`.

Pass `showlegend=true` to force the legend visible (useful for a single,
unnamed trace), or `showlegend=false` to hide it.

# Keyword Arguments
- `position`: Symbolic legend placement (see above).
- `inset`: Relative `(x, y)` padding from the plot edges.
- `bgcolor` / `bordercolor` / `borderwidth`: Legend box styling.
- `showlegend`: Force legend visibility (`true`/`false`), or leave `nothing` to auto-detect.
"""
function set_legend!(
	fig::Union{Plot, SyncPlot};
	position::Union{Symbol, AbstractString} = get_default_legend_position(),
	inset::Tuple{<:Real, <:Real} = _DEFAULT_LEGEND_INSET[],
	bgcolor::String = _DEFAULT_LEGEND_BGCOLOR[],
	bordercolor::String = _DEFAULT_LEGEND_BORDERCOLOR[],
	borderwidth::Real = _DEFAULT_LEGEND_BORDERWIDTH[],
	showlegend::Union{Nothing, Bool} = nothing,
)
	_apply_default_legend!(
		fig;
		position = position,
		inset = inset,
		bgcolor = bgcolor,
		bordercolor = bordercolor,
		borderwidth = borderwidth,
		overwrite = true,
		showlegend = showlegend,
	)
	_refresh!(fig)
	return fig
end

function set_legend!(
	sf::SubplotFigure;
	position::Union{Symbol, AbstractString} = sf.legend_position,
	inset::Tuple{<:Real, <:Real} = sf.legend_inset,
	bgcolor::String = sf.legend_bgcolor,
	bordercolor::String = sf.legend_bordercolor,
	borderwidth::Real = sf.legend_borderwidth,
)
	if sf.per_subplot_legends
		subplot_legends!(
			sf;
			position = position,
			legend_inset = inset,
			legend_bgcolor = bgcolor,
			legend_bordercolor = bordercolor,
			legend_borderwidth = borderwidth,
		)
	else
		set_legend!(
			sf.fig;
			position = position,
			inset = inset,
			bgcolor = bgcolor,
			bordercolor = bordercolor,
			borderwidth = borderwidth,
		)
	end
	return sf
end

"""
	subplot_legends!(fig; kwargs...)

Attach each subplot to its own legend box and place that legend inside the subplot domain.
This avoids Plotly's default behavior where all legends are clustered in one place.
"""
function subplot_legends!(
	fig::Union{Plot, SyncPlot};
	position::Union{Symbol, AbstractString} = get_default_legend_position(),
	legend_inset::Tuple{<:Real, <:Real} = _DEFAULT_LEGEND_INSET[],
	legend_bgcolor::String = _DEFAULT_LEGEND_BGCOLOR[],
	legend_bordercolor::String = _DEFAULT_LEGEND_BORDERCOLOR[],
	legend_borderwidth::Real = _DEFAULT_LEGEND_BORDERWIDTH[],
)
	p = _plot_obj(fig)
	_apply_subplot_legends!(
		p;
		legend_position = _normalize_legend_position(position),
		legend_inset = (Float64(legend_inset[1]), Float64(legend_inset[2])),
		legend_bgcolor = legend_bgcolor,
		legend_bordercolor = legend_bordercolor,
		legend_borderwidth = Float64(legend_borderwidth),
	)
	_refresh!(fig)
	return fig
end

function subplot_legends!(
	sf::SubplotFigure;
	position::Union{Symbol, AbstractString} = sf.legend_position,
	legend_inset::Tuple{<:Real, <:Real} = sf.legend_inset,
	legend_bgcolor::String = sf.legend_bgcolor,
	legend_bordercolor::String = sf.legend_bordercolor,
	legend_borderwidth::Real = sf.legend_borderwidth,
)
	sf.legend_position = _normalize_legend_position(position)
	sf.legend_inset = (Float64(legend_inset[1]), Float64(legend_inset[2]))
	sf.legend_bgcolor = legend_bgcolor
	sf.legend_bordercolor = legend_bordercolor
	sf.legend_borderwidth = Float64(legend_borderwidth)

	subplot_legends!(
		sf.fig;
		position = sf.legend_position,
		legend_inset = sf.legend_inset,
		legend_bgcolor = sf.legend_bgcolor,
		legend_bordercolor = sf.legend_bordercolor,
		legend_borderwidth = sf.legend_borderwidth,
	)
	return sf
end

function _check_subplot_dims(rows::Int, cols::Int)
	rows > 0 || throw(ArgumentError("`rows` must be positive."))
	cols > 0 || throw(ArgumentError("`cols` must be positive."))
	return nothing
end

function _check_subplot_cell(sf::SubplotFigure, row::Int, col::Int)
	(1 <= row <= sf.rows) || throw(ArgumentError("`row` must be in 1:$(sf.rows), got $(row)."))
	(1 <= col <= sf.cols) || throw(ArgumentError("`col` must be in 1:$(sf.cols), got $(col)."))
	return nothing
end

function _subplot_cell(sf::SubplotFigure, index::Int)
	maxidx = sf.rows * sf.cols
	(1 <= index <= maxidx) || throw(ArgumentError("`index` must be in 1:$(maxidx), got $(index)."))
	row = fld(index - 1, sf.cols) + 1
	col = mod(index - 1, sf.cols) + 1
	return row, col
end

function _resolve_subplot_cell(
	sf::SubplotFigure;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	if isnothing(row) && isnothing(col)
		return sf.current_row, sf.current_col
	end
	if isnothing(row) || isnothing(col)
		throw(ArgumentError("`row` and `col` must be provided together."))
	end
	r = Int(row)
	c = Int(col)
	_check_subplot_cell(sf, r, c)
	return r, c
end

"""
	subplots(rows, cols; kwargs...)

Create a MATLAB-like subplot canvas and return a `SubplotFigure`.
Use `subplot!(sf, row, col)` to change the active cell and `plot!(sf, x, y)` to append traces.
"""
function subplots(
	rows::Integer,
	cols::Integer;
	sync::Bool = true,
	width::Int = 960,
	height::Int = 720,
	title::String = "PlotlySupply",
	show::Bool = true,
	app = nothing,
	per_subplot_legends::Bool = true,
	legend_position::Union{Symbol, AbstractString} = get_default_legend_position(),
	legend_inset::Tuple{<:Real, <:Real} = _DEFAULT_LEGEND_INSET[],
	legend_bgcolor::String = _DEFAULT_LEGEND_BGCOLOR[],
	legend_bordercolor::String = _DEFAULT_LEGEND_BORDERCOLOR[],
	legend_borderwidth::Real = _DEFAULT_LEGEND_BORDERWIDTH[],
	subplot_kwargs...,
)
	rows_i = Int(rows)
	cols_i = Int(cols)
	_check_subplot_dims(rows_i, cols_i)

	layout = Layout(Subplots(rows = rows_i, cols = cols_i; subplot_kwargs...))
	fig = if sync
		plot(; layout = layout, sync = true, width = width, height = height, title = title, show = show, app = app)
	else
		p = Plot(Vector{GenericTrace}(undef, 0), layout)
		width > 0 && relayout!(p, width = width)
		height > 0 && relayout!(p, height = height)
		title != "" && relayout!(p, title = title)
		p
	end
	p = _plot_obj(fig)
	_apply_default_template!(p)
	_apply_default_cartesian_axes!(p)
	_refresh!(fig)

	return SubplotFigure(
		fig,
		rows_i,
		cols_i,
		1,
		1,
		per_subplot_legends,
		_normalize_legend_position(legend_position),
		(Float64(legend_inset[1]), Float64(legend_inset[2])),
		legend_bgcolor,
		legend_bordercolor,
		Float64(legend_borderwidth),
	)
end

"""
	subplot!(sf, row, col)
	subplot!(sf, index)

Set the active subplot cell in a `SubplotFigure`.
"""
function subplot!(sf::SubplotFigure, row::Integer, col::Integer)
	r = Int(row)
	c = Int(col)
	_check_subplot_cell(sf, r, c)
	sf.current_row = r
	sf.current_col = c
	return sf
end

function subplot!(sf::SubplotFigure, index::Integer)
	row, col = _subplot_cell(sf, Int(index))
	return subplot!(sf, row, col)
end

# Delegate raw PlotlyBase verbs to the underlying figure so a SubplotFigure can
# be driven like a Plot/SyncPlot. The fig-level methods already handle the
# Electron refresh; we return `sf` so calls remain chainable on the subplot.
for f in (:relayout!, :react!, :restyle!, :update_xaxes!, :update_yaxes!, :update_polars!)
	@eval function PlotlyBase.$f(sf::SubplotFigure, args...; kwargs...)
		PlotlyBase.$f(getfield(sf, :fig), args...; kwargs...)
		return sf
	end
end

savefig(sf::SubplotFigure, args...; kwargs...) = savefig(getfield(sf, :fig), args...; kwargs...)
savefig(io::IO, sf::SubplotFigure; kwargs...) = savefig(io, getfield(sf, :fig); kwargs...)
savefig(filename::AbstractString, sf::SubplotFigure; kwargs...) = savefig(filename, getfield(sf, :fig); kwargs...)

function PlotlyBase.add_trace!(
	sf::SubplotFigure,
	trace::GenericTrace;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	p = _plot_obj(sf.fig)
	PlotlyBase.add_trace!(p, trace; row = r, col = c, secondary_y = secondary_y)

	if sf.per_subplot_legends
		_apply_subplot_legends!(
			p;
			legend_position = sf.legend_position,
			legend_inset = sf.legend_inset,
			legend_bgcolor = sf.legend_bgcolor,
			legend_bordercolor = sf.legend_bordercolor,
			legend_borderwidth = sf.legend_borderwidth,
		)
	end

	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

function PlotlyBase.addtraces!(
	sf::SubplotFigure,
	traces::AbstractTrace...;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	for trace in traces
		PlotlyBase.add_trace!(sf, trace; row = row, col = col, secondary_y = secondary_y)
	end
	return sf
end

function _merge_layout_attr!(
	layout::Layout,
	key::Symbol,
	source;
	drop_keys::Tuple{Vararg{Symbol}} = (),
)
	source_dict = _symbol_dict(source)
	isempty(source_dict) && return
	for k in drop_keys
		pop!(source_dict, k, nothing)
	end
	target_dict = _symbol_dict(get(layout.fields, key, nothing))
	merge!(target_dict, source_dict)
	layout.fields[key] = attr(; target_dict...)
	return nothing
end

function _apply_source_layout_to_added_traces!(
	target::Plot,
	source::Plot,
	start_index::Int,
)
	start_index > length(target.data) && return nothing
	processed = Set{Symbol}()

	for idx in start_index:length(target.data)
		fields = target.data[idx].fields

		if haskey(fields, :xaxis) || haskey(fields, :yaxis)
			xref = String(get(fields, :xaxis, "x"))
			yref = String(get(fields, :yaxis, "y"))
			xkey = _axis_layout_key(xref, :x)
			ykey = _axis_layout_key(yref, :y)

			if !(xkey in processed)
				_merge_layout_attr!(
					target.layout,
					xkey,
					get(source.layout.fields, :xaxis, nothing);
					drop_keys = (:domain, :anchor),
				)
				push!(processed, xkey)
			end
			if !(ykey in processed)
				_merge_layout_attr!(
					target.layout,
					ykey,
					get(source.layout.fields, :yaxis, nothing);
					drop_keys = (:domain, :anchor),
				)
				push!(processed, ykey)
			end
		end

		if haskey(fields, :scene)
			scene_key = Symbol(String(get(fields, :scene, "scene")))
			if !(scene_key in processed)
				_merge_layout_attr!(
					target.layout,
					scene_key,
					get(source.layout.fields, :scene, nothing);
					drop_keys = (:domain,),
				)
				push!(processed, scene_key)
			end
		end

		if haskey(fields, :subplot)
			polar_key = Symbol(String(get(fields, :subplot, "polar")))
			if !(polar_key in processed)
				_merge_layout_attr!(
					target.layout,
					polar_key,
					get(source.layout.fields, :polar, nothing);
					drop_keys = (:domain,),
				)
				push!(processed, polar_key)
			end
		end
	end

	_merge_layout_attr!(target.layout, :font, get(source.layout.fields, :font, nothing))
	_merge_layout_attr!(target.layout, :coloraxis, get(source.layout.fields, :coloraxis, nothing))
	return nothing
end

function _subplot_delegate_mutator!(
	sf::SubplotFigure,
	mutator::Function,
	args...;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	# `title`/`width`/`height` are figure-level, not per-cell: the delegate only
	# transplants traces + per-axis layout, so these would be silently dropped.
	# Warn instead of leaving the caller wondering why nothing changed.
	let kw = values(kwargs)
		dropped = Symbol[]
		get(kw, :title, "") != "" && push!(dropped, :title)
		get(kw, :width, 0) != 0 && push!(dropped, :width)
		get(kw, :height, 0) != 0 && push!(dropped, :height)
		isempty(dropped) || @warn "Per-subplot plot_*! ignores figure-level keyword(s) $(dropped); set them on the `subplots(...)` call or via `relayout!(sf; ...)`."
	end
	tmp = Plot(Vector{GenericTrace}(undef, 0), Layout())
	mutator(tmp, args...; kwargs...)

	p = _plot_obj(sf.fig)
	start_index = length(p.data) + 1
	for trace in tmp.data
		PlotlyBase.add_trace!(p, deepcopy(trace); row = r, col = c, secondary_y = secondary_y)
	end
	_apply_source_layout_to_added_traces!(p, tmp, start_index)

	if sf.per_subplot_legends
		_apply_subplot_legends!(
			p;
			legend_position = sf.legend_position,
			legend_inset = sf.legend_inset,
			legend_bgcolor = sf.legend_bgcolor,
			legend_bordercolor = sf.legend_bordercolor,
			legend_borderwidth = sf.legend_borderwidth,
		)
	end

	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

function _subplot_xy_axis_keys(sf::SubplotFigure, row::Int, col::Int; secondary_y::Bool = false)
	p = _plot_obj(sf.fig)
	probe = scatter(
		x = [0.0],
		y = [0.0],
		mode = "markers",
		showlegend = false,
		hoverinfo = "skip",
		marker = attr(size = 0.1, opacity = 0.0),
	)
	try
		PlotlyBase.add_trace!(p, probe; row = row, col = col, secondary_y = secondary_y)
	catch err
		throw(ArgumentError("Selected subplot cell ($(row), $(col)) does not accept Cartesian x/y axes" *
			(secondary_y ? " with a secondary y-axis (was the cell created with `secondary_y=true`?)." : ".")))
	end
	fields = p.data[end].fields
	pop!(p.data)

	haskey(fields, :xaxis) || throw(ArgumentError("Selected subplot cell ($(row), $(col)) has no x-axis."))
	haskey(fields, :yaxis) || throw(ArgumentError("Selected subplot cell ($(row), $(col)) has no y-axis."))

	xkey = _axis_layout_key(String(fields[:xaxis]), :x)
	ykey = _axis_layout_key(String(fields[:yaxis]), :y)
	return xkey, ykey
end

"""
	xlabel!(sf, label; row=nothing, col=nothing)
	ylabel!(sf, label; row=nothing, col=nothing, secondary_y=false)
	xrange!(sf, range; row=nothing, col=nothing)
	yrange!(sf, range; row=nothing, col=nothing, secondary_y=false)

Set the axis title (`xlabel!`/`ylabel!`) or axis range (`xrange!`/`yrange!`,
a 2-element `[min, max]`) of one cell of a [`SubplotFigure`](@ref). When `row`
and `col` are omitted the currently active cell (see [`subplot!`](@ref)) is used;
otherwise both must be given. `ylabel!`/`yrange!` accept `secondary_y=true` to
target a cell's secondary y-axis (the cell must have been created with a
secondary-y spec). Returns the `SubplotFigure` for chaining.
"""
function xlabel!(
	sf::SubplotFigure,
	label::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	xkey, _ = _subplot_xy_axis_keys(sf, r, c)
	_merge_layout_attr!(_plot_layout(sf.fig), xkey, attr(title_text = String(label)))
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

function ylabel!(
	sf::SubplotFigure,
	label::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	_, ykey = _subplot_xy_axis_keys(sf, r, c; secondary_y = secondary_y)
	_merge_layout_attr!(_plot_layout(sf.fig), ykey, attr(title_text = String(label)))
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

function xrange!(
	sf::SubplotFigure,
	range::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	length(range) == 2 || throw(ArgumentError("`range` must have length 2."))
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	xkey, _ = _subplot_xy_axis_keys(sf, r, c)
	_merge_layout_attr!(_plot_layout(sf.fig), xkey, attr(range = collect(range)))
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

function yrange!(
	sf::SubplotFigure,
	range::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	length(range) == 2 || throw(ArgumentError("`range` must have length 2."))
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	_, ykey = _subplot_xy_axis_keys(sf, r, c; secondary_y = secondary_y)
	_merge_layout_attr!(_plot_layout(sf.fig), ykey, attr(range = collect(range)))
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

function plot_scatter!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_scatter!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_scatter!(
	sf::SubplotFigure,
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_scatter!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_stem!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_stem!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_stem!(
	sf::SubplotFigure,
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_stem!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_bar!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_bar!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_bar!(
	sf::SubplotFigure,
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_bar!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_histogram!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_histogram!,
		x;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_box!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_box!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_box!(
	sf::SubplotFigure,
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_box!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_violin!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_violin!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_violin!(
	sf::SubplotFigure,
	y::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_violin!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_scatterpolar!(
	sf::SubplotFigure,
	theta::Union{AbstractRange, Vector, SubArray},
	r::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_scatterpolar!,
		theta,
		r;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_heatmap!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_heatmap!,
		x,
		y,
		U;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_heatmap!(
	sf::SubplotFigure,
	U::Union{Array, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_heatmap!,
		U;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_contour!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_contour!,
		x,
		y,
		U;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_contour!(
	sf::SubplotFigure,
	U::Union{Array, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_contour!,
		U;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_quiver!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_quiver!,
		x,
		y,
		u,
		v;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_surface!(
	sf::SubplotFigure,
	X::Union{AbstractRange, Array, SubArray},
	Y::Union{AbstractRange, Array, SubArray},
	Z::Union{Array, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_surface!,
		X,
		Y,
		Z;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_surface!(
	sf::SubplotFigure,
	Z::Union{Array, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_surface!,
		Z;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_scatter3d!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_scatter3d!,
		x,
		y,
		z;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_quiver3d!(
	sf::SubplotFigure,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray},
	w::Union{AbstractRange, Vector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_quiver3d!,
		x,
		y,
		z,
		u,
		v,
		w;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

"""
	plot!(sf::SubplotFigure, x, y; kwargs...)

MATLAB-like alias for `plot_scatter!` when working with `SubplotFigure`.
"""
function plot!(
	sf::SubplotFigure,
	args...;
	kwargs...,
)
	return plot_scatter!(sf, args...; kwargs...)
end

#region 1D Plot

function _string_kwarg_vector(value::Union{String, Vector{String}}, n::Int)
	out = fill("", n)
	if value isa Vector
		for i in eachindex(value)
			i > n && break
			out[i] = value[i]
		end
	else
		fill!(out, value)
	end
	return out
end

function _first_or_empty(value::Union{String, Vector{String}})
	if value isa Vector
		return isempty(value) ? "" : value[1]
	end
	return value
end

# Reduce a possibly-vector styling kwarg to a scalar for a single-trace plot.
# Mirrors `_first_or_empty` but for numeric / Bool kwargs: an empty vector
# falls back to `default`, otherwise the first element is used.
_scalar_or_first(value, default) = value isa AbstractVector ? (isempty(value) ? default : value[1]) : value

# Compute a finite scalar `tick0` from possibly nested / non-finite data.
# Handles a vector-of-vectors (multi-series), ignores non-finite entries, and
# returns `nothing` when no finite value exists — so the axis simply omits
# `tick0` instead of receiving an invalid Vector or NaN. Iterates lazily (no
# flattening allocation) so it is cheap even for large series.
function _safe_tick0(v)
	if v isa AbstractVector && eltype(v) <: Union{AbstractVector, AbstractRange}
		best = nothing
		for sub in v
			t = _safe_tick0(sub)
			t === nothing || (best = best === nothing ? t : min(best, t))
		end
		return best
	end
	best = nothing
	for x in v
		if x isa Real && isfinite(x)
			best = best === nothing ? float(x) : min(best, float(x))
		end
	end
	return best
end

# Attach symmetric data error bars to one or more traces. `error_x`/`error_y`
# may be a flat vector (applied to every trace) or a vector-of-vectors (one per
# trace); `nothing` leaves that axis untouched.
function _set_error_bars!(trace, error_x, error_y)
	(error_x === nothing && error_y === nothing) && return nothing
	traces = trace isa AbstractVector ? trace : (trace,)
	nx = error_x isa AbstractVector && !isempty(error_x) && eltype(error_x) <: Union{AbstractVector, AbstractRange}
	ny = error_y isa AbstractVector && !isempty(error_y) && eltype(error_y) <: Union{AbstractVector, AbstractRange}
	for (n, t) in enumerate(traces)
		if error_x !== nothing && !(nx && n > length(error_x))
			t.error_x = attr(type = "data", array = collect(nx ? error_x[n] : error_x), visible = true)
		end
		if error_y !== nothing && !(ny && n > length(error_y))
			t.error_y = attr(type = "data", array = collect(ny ? error_y[n] : error_y), visible = true)
		end
	end
	return nothing
end

function _auto_xvalues(y)
	if isa(y, Vector) && eltype(y) <: Vector
		x = Vector{Vector{Int}}(undef, length(y))
		for n in eachindex(y)
			x[n] = 0:length(y[n])-1
		end
		return x
	end
	return 0:length(y)-1
end

function _apply_showlegend!(trace, showlegend)
	showlegend === nothing && return
	if isa(trace, Vector)
		if showlegend isa Bool
			for t in trace
				t.showlegend = showlegend
			end
		elseif showlegend isa Vector
			# Tolerate a vector longer than the trace count (ignore the surplus)
			# to match the lenient handling of color/legend in the constructors.
			for n in 1:min(length(trace), length(showlegend))
				trace[n].showlegend = showlegend[n]
			end
		end
	else
		if showlegend isa Bool
			trace.showlegend = showlegend
		elseif showlegend isa Vector && !isempty(showlegend)
			trace.showlegend = showlegend[1]
		end
	end
end

function _apply_cartesian_plot_options!(
	fig;
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	grid::Bool = true,
	fontsize::Int = 0,
	title::String = "",
	xscale::String = "",
	yscale::String = "",
	refresh::Bool = false,
	apply_template::Bool = true,
)
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title_text = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title_text = ylabel))
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	# On first construction apply the default template; when appending to an
	# existing figure only refresh the legend so a user-set template survives.
	if apply_template
		_apply_default_template!(fig)
	else
		_apply_default_legend!(fig)
	end
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end
	refresh && _refresh!(fig)
	return nothing
end

function _bar_trace(; x, y, color::String = "", name::String = "", orientation::String = "")
	kw = Dict{Symbol, Any}(:x => x, :y => y, :name => name)
	color == "" || (kw[:marker] = attr(color = color))
	orientation == "" || (kw[:orientation] = orientation)
	return bar(; kw...)
end

function _histogram_trace(
	;
	x,
	nbinsx::Int = 0,
	histnorm::String = "",
	color::String = "",
	name::String = "",
)
	kwargs = Dict{Symbol, Any}(
		:x => x,
		:name => name,
	)
	nbinsx > 0 && (kwargs[:nbinsx] = nbinsx)
	histnorm != "" && (kwargs[:histnorm] = histnorm)
	color != "" && (kwargs[:marker] = attr(color = color))
	return histogram(; kwargs...)
end

# Plotly's box/violin point options are a string enum
# ("all"|"outliers"|"suspectedoutliers") or `false`. A bare `true` is invalid
# and silently ignored by Plotly, so map it to the sensible "all".
_normalize_points(points) = points isa Bool ? (points ? "all" : false) : points

function _box_trace(
	;
	x = nothing,
	y,
	color::String = "",
	name::String = "",
	points::Union{Bool, String} = "outliers",
)
	kwargs = Dict{Symbol, Any}(
		:y => y,
		:name => name,
		:boxpoints => _normalize_points(points),
	)
	x === nothing || (kwargs[:x] = x)
	if color != ""
		kwargs[:marker] = attr(color = color)
		kwargs[:line] = attr(color = color)
	end
	return PlotlyBase.box(; kwargs...)
end

function _violin_trace(
	;
	x = nothing,
	y,
	color::String = "",
	name::String = "",
	points::Union{Bool, String} = "outliers",
	side::String = "both",
)
	kwargs = Dict{Symbol, Any}(
		:y => y,
		:name => name,
		:points => _normalize_points(points),
		:side => side,
	)
	x === nothing || (kwargs[:x] = x)
	if color != ""
		kwargs[:marker] = attr(color = color)
		kwargs[:line] = attr(color = color)
	end
	return violin(; kwargs...)
end

"""
	function plot_scatter(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		xscale::String = "",
		yscale::String = "",
		marker_size::Union{Int, Vector{Int}} = 0,
		marker_symbol::Union{String, Vector{String}} = "",
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Plots a rectangular (Cartesian) plot.

#### Arguments

- `x`: x-coordinate data (can be vector of vectors)
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `dash`: line style ("dash", "dashdot", or "dot", default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to show the grid or not (default: `true`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)
- `marker_size`: Marker size in pixels (default: `0`, can be vector)
- `marker_symbol`: Marker symbol name (default: `""`, can be vector)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_scatter(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	error_x::Union{Nothing, AbstractVector} = nothing,
	error_y::Union{Nothing, AbstractVector} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		trace = Vector{GenericTrace}(undef, length(y))
		modeV = fill("lines", length(y))
		dashV = fill("", length(y))
		colorV = fill("", length(y))
		legendV = fill("", length(y))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(dash isa Vector)
			fill!(dashV, dash)
		else
			for n in eachindex(dash)
				dashV[n] = dash[n]
			end
		end
		if !(color isa Vector)
			fill!(colorV, color)
		else
			for n in eachindex(color)
				colorV[n] = color[n]
			end
		end
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		marker_sizeV = fill(0, length(y))
		marker_symbolV = fill("", length(y))
		linewidthV = fill(0.0, length(y))
		showlegendV = Vector{Union{Nothing, Bool}}(nothing, length(y))
		if !(marker_size isa Vector)
			fill!(marker_sizeV, marker_size)
		else
			for n in eachindex(marker_size)
				marker_sizeV[n] = marker_size[n]
			end
		end
		if !(marker_symbol isa Vector)
			fill!(marker_symbolV, marker_symbol)
		else
			for n in eachindex(marker_symbol)
				marker_symbolV[n] = marker_symbol[n]
			end
		end
		if !(linewidth isa Vector)
			fill!(linewidthV, linewidth)
		else
			for n in eachindex(linewidth)
				linewidthV[n] = linewidth[n]
			end
		end
		if showlegend isa Bool
			fill!(showlegendV, showlegend)
		elseif showlegend isa Vector
			for n in eachindex(showlegend)
				showlegendV[n] = showlegend[n]
			end
		end

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(:y => y[n], :x => x[n], :mode => modeV[n], :line => attr(color = colorV[n], dash = dashV[n]), :name => legendV[n])
				mk = Dict{Symbol,Any}()
				marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
				marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
				!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
				linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				trace[n] = scatter(; trace_kw...)
			end
		else
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(:y => y[n], :x => x, :mode => modeV[n], :line => attr(color = colorV[n], dash = dashV[n]), :name => legendV[n])
				mk = Dict{Symbol,Any}()
				marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
				marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
				!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
				linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				trace[n] = scatter(; trace_kw...)
			end
		end
	else
		mode1 = _first_or_empty(mode)
		mode1 == "" && (mode1 = "lines")
		trace_kw = Dict{Symbol,Any}(:y => y, :x => x, :mode => mode1, :line => attr(color = _first_or_empty(color), dash = _first_or_empty(dash)), :name => _first_or_empty(legend))
		mk = Dict{Symbol,Any}()
		ms = _scalar_or_first(marker_size, 0)
		if ms isa Real && ms > 0
			mk[:size] = ms
		end
		msym = _first_or_empty(marker_symbol)
		if msym != ""
			mk[:symbol] = msym
		end
		!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
		lw = _scalar_or_first(linewidth, 0)
		if lw isa Real && lw > 0
			trace_kw[:line][:width] = lw
		end
		sl = _scalar_or_first(showlegend, nothing)
		if sl isa Bool
			trace_kw[:showlegend] = sl
		end
		trace = scatter(; trace_kw...)
	end
	layout = _default_cartesian_layout(
		title = title,
		xlabel = xlabel,
		ylabel = ylabel,
		x_tick0 = _safe_tick0(x),
		y_tick0 = _safe_tick0(y),
	)
	_set_error_bars!(trace, error_x, error_y)
	fig = Plot(trace, layout)
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	function plot_scatter(
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		xscale::String = "",
		yscale::String = "",
		marker_size::Union{Int, Vector{Int}} = 0,
		marker_symbol::Union{String, Vector{String}} = "",
		linewidth::Union{Real, Vector{<:Real}} = 0,
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Plots a rectangular (Cartesian) plot (x-axis not specified).

#### Arguments

- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `dash`: line style ("dash", "dashdot", or "dot", default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to show the grid or not (default: `true`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)
- `marker_size`: Marker size in pixels (default: `0`, can be vector)
- `marker_symbol`: Marker symbol name (default: `""`, can be vector)
- `linewidth`: Line width in pixels (default: `0`, can be vector)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_scatter(
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	error_x::Union{Nothing, AbstractVector} = nothing,
	error_y::Union{Nothing, AbstractVector} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		x = Vector{Vector{Int}}(undef, length(y))
		for n in eachindex(y)
			x[n] = 0:length(y[n])-1
		end
	else
		x = 0:length(y)-1
	end

	return plot_scatter(
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		mode = mode,
		dash = dash,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
		xscale = xscale,
		yscale = yscale,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		linewidth = linewidth,
		showlegend = showlegend,
		error_x = error_x,
		error_y = error_y,
		show = show,
	)
end

"""
	function plot_stem(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		xscale::String = "",
		yscale::String = "",
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Plots a rectangular stem plot.

#### Arguments

- `x`: x-coordinate data (can be vector of vectors)
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to show the grid or not (default: `true`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_stem(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		trace = Vector{GenericTrace}(undef, length(y))
		colorV = fill("", length(y))
		legendV = fill("", length(y))

		if !(color isa Vector)
			fill!(colorV, color)
		else
			for n in eachindex(color)
				colorV[n] = color[n]
			end
		end
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		showlegendV = Vector{Union{Nothing, Bool}}(nothing, length(y))
		if showlegend isa Bool
			fill!(showlegendV, showlegend)
		elseif showlegend isa Vector
			for n in eachindex(showlegend)
				showlegendV[n] = showlegend[n]
			end
		end

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				# Stem heads are drawn as markers; color belongs on `marker`
				# (a `line` color is ignored for a markers-only trace).
				trace_kw = Dict{Symbol,Any}(:y => y[n], :x => x[n], :name => legendV[n], :mode => "markers")
				colorV[n] != "" && (trace_kw[:marker] = attr(color = colorV[n]))
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				trace[n] = scatter(; trace_kw...)
			end
		else
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(:y => y[n], :x => x, :name => legendV[n], :mode => "markers")
				colorV[n] != "" && (trace_kw[:marker] = attr(color = colorV[n]))
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				trace[n] = scatter(; trace_kw...)
			end
		end
	else
		color1 = _first_or_empty(color)
		trace_kw = Dict{Symbol,Any}(:y => y, :x => x, :name => _first_or_empty(legend), :mode => "markers")
		color1 != "" && (trace_kw[:marker] = attr(color = color1))
		sl = _scalar_or_first(showlegend, nothing)
		if sl isa Bool
			trace_kw[:showlegend] = sl
		end
		trace = scatter(; trace_kw...)
	end
	layout = _default_cartesian_layout(
		title = title,
		xlabel = xlabel,
		ylabel = ylabel,
		x_tick0 = _safe_tick0(x),
		y_tick0 = _safe_tick0(y),
	)
	fig = Plot(trace, layout)

	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end

	# Draw a vertical line from the baseline (y=0) to each stem head. Use the
	# per-series color so the stems match their markers, defaulting to black.
	if isa(y, Vector) && eltype(y) <: Vector
		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				stem_color = colorV[n] == "" ? "black" : colorV[n]
				for m in eachindex(y[n])
					addtraces!(fig,
						scatter(
							x = [x[n][m], x[n][m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(color = stem_color, width = 0.5),
							showlegend = false,
						),
					)
				end
			end
		else
			for n in eachindex(y)
				stem_color = colorV[n] == "" ? "black" : colorV[n]
				for m in eachindex(y[n])
					addtraces!(fig,
						scatter(
							x = [x[m], x[m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(color = stem_color, width = 0.5),
							showlegend = false,
						),
					)
				end
			end
		end
	else
		stem_color = _first_or_empty(color) == "" ? "black" : _first_or_empty(color)
		for m in eachindex(y)
			addtraces!(fig,
				scatter(
					x = [x[m], x[m]],
					y = [0, y[m]],
					mode = "lines",
					line = attr(color = stem_color, width = 0.5),
					showlegend = false,
				),
			)
		end
	end
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	function plot_stem(
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		xscale::String = "",
		yscale::String = "",
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Plots a rectangular stem plot (x-axis not specified).

#### Arguments

- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to show the grid or not (default: `true`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_stem(
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		x = Vector{Vector{Int}}(undef, length(y))
		for n in eachindex(y)
			x[n] = 0:length(y[n])-1
		end
	else
		x = 0:length(y)-1
	end

	return plot_stem(
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
		xscale = xscale,
		yscale = yscale,
		showlegend = showlegend,
		show = show,
		)
end

"""
	plot_bar(x, y; kwargs...)
	plot_bar(y; kwargs...)

Bar plot of `y` over categories/positions `x` (defaults to `0:length(y)-1`).
Pass a `Vector` of `Vector`s for `y` (and optionally `x`) to draw multiple
grouped bar series.

# Keyword Arguments
- `xlabel`, `ylabel`: Axis labels (default `""`).
- `xrange`, `yrange`: Axis ranges as `[min, max]`; `[0, 0]` keeps auto-scaling.
- `width`, `height`: Figure size in pixels (`0` uses the default).
- `color`: Bar color(s) — a string, or a vector for multiple series.
- `legend`: Trace name(s) for the legend.
- `title`: Figure title.
- `grid`: Show grid lines (default `true`).
- `fontsize`: Base font size (`0` uses the Plotly default).
- `xscale`, `yscale`: `"log"` for a logarithmic axis.
- `showlegend`: Force legend entry visibility (`Bool` or vector).
- `show`: Open an Electron window immediately (returns a `SyncPlot`).

Returns a `PlotlyBase.Plot` (or a `SyncPlot` when `show=true`).
"""
function plot_bar(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	orientation::String = "",
	barmode::String = "",
	error_x::Union{Nothing, AbstractVector} = nothing,
	error_y::Union{Nothing, AbstractVector} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace[n] = _bar_trace(x = x[n], y = y[n], color = colorV[n], name = legendV[n], orientation = orientation)
			end
		else
			for n in eachindex(y)
				trace[n] = _bar_trace(x = x, y = y[n], color = colorV[n], name = legendV[n], orientation = orientation)
			end
		end
	else
		trace = _bar_trace(
			x = x,
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			orientation = orientation,
		)
	end

	_apply_showlegend!(trace, showlegend)
	_set_error_bars!(trace, error_x, error_y)

	fig = Plot(trace, _default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
	barmode == "" || relayout!(fig, barmode = barmode)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
	)
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

function plot_bar(
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	orientation::String = "",
	barmode::String = "",
	error_x::Union{Nothing, AbstractVector} = nothing,
	error_y::Union{Nothing, AbstractVector} = nothing,
	show::Bool = false,
)
	x = _auto_xvalues(y)
	return plot_bar(
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
		xscale = xscale,
		yscale = yscale,
		showlegend = showlegend,
		orientation = orientation,
		barmode = barmode,
		error_x = error_x,
		error_y = error_y,
		show = show,
	)
end

"""
	plot_histogram(x; kwargs...)

Histogram of the samples in `x`. Pass a `Vector` of `Vector`s for `x` to overlay
multiple histogram series.

# Keyword Arguments
- `nbinsx`: Target number of bins (`0` lets Plotly choose).
- `histnorm`: Normalization — `""`, `"percent"`, `"probability"`, `"density"`, or `"probability density"`.
- `xlabel`, `ylabel`: Axis labels.
- `xrange`, `yrange`: Axis ranges as `[min, max]`; `[0, 0]` keeps auto-scaling.
- `width`, `height`: Figure size in pixels.
- `color`: Bar color(s).
- `legend`: Trace name(s).
- `title`: Figure title.
- `grid`: Show grid lines (default `true`).
- `fontsize`: Base font size.
- `xscale`, `yscale`: `"log"` for a logarithmic axis.
- `showlegend`: Force legend entry visibility.
- `show`: Open an Electron window immediately (returns a `SyncPlot`).

Returns a `PlotlyBase.Plot` (or a `SyncPlot` when `show=true`).
"""
function plot_histogram(
	x::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	nbinsx::Int = 0,
	histnorm::String = "",
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(x, Vector) && eltype(x) <: Vector
		colorV = _string_kwarg_vector(color, length(x))
		legendV = _string_kwarg_vector(legend, length(x))
		trace = Vector{GenericTrace}(undef, length(x))
		for n in eachindex(x)
			trace[n] = _histogram_trace(
				x = x[n],
				nbinsx = nbinsx,
				histnorm = histnorm,
				color = colorV[n],
				name = legendV[n],
			)
		end
	else
		trace = _histogram_trace(
			x = x,
			nbinsx = nbinsx,
			histnorm = histnorm,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
		)
	end

	_apply_showlegend!(trace, showlegend)

	fig = Plot(trace, _default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
	)
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	plot_box(x, y; kwargs...)
	plot_box(y; kwargs...)

Box plot of the distribution(s) in `y`, optionally grouped by `x`. Pass a
`Vector` of `Vector`s for `y` to draw several boxes side-by-side (`boxmode="group"`).

# Keyword Arguments
- `points`: Outlier/point display — `"all"`, `"outliers"`, `"suspectedoutliers"`, or `false` (`true` is treated as `"all"`).
- `xlabel`, `ylabel`: Axis labels.
- `xrange`, `yrange`: Axis ranges as `[min, max]`; `[0, 0]` keeps auto-scaling.
- `width`, `height`: Figure size in pixels.
- `color`: Box color(s).
- `legend`: Trace name(s).
- `title`: Figure title.
- `grid`: Show grid lines (default `true`).
- `fontsize`: Base font size.
- `xscale`, `yscale`: `"log"` for a logarithmic axis.
- `showlegend`: Force legend entry visibility.
- `show`: Open an Electron window immediately (returns a `SyncPlot`).

Returns a `PlotlyBase.Plot` (or a `SyncPlot` when `show=true`).
"""
function plot_box(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	points::Union{Bool, String} = "outliers",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace[n] = _box_trace(
					x = x[n],
					y = y[n],
					color = colorV[n],
					name = legendV[n],
					points = points,
				)
			end
		else
			for n in eachindex(y)
				trace[n] = _box_trace(
					x = x,
					y = y[n],
					color = colorV[n],
					name = legendV[n],
					points = points,
				)
			end
		end
	else
		trace = _box_trace(
			x = x,
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			points = points,
		)
	end

	_apply_showlegend!(trace, showlegend)

	fig = Plot(trace, _default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
	# Render multiple boxes side-by-side (Plotly defaults to "overlay").
	if isa(y, Vector) && eltype(y) <: Vector && length(y) > 1
		relayout!(fig, boxmode = "group")
	end
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
	)
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

function plot_box(
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	points::Union{Bool, String} = "outliers",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))
		for n in eachindex(y)
			trace[n] = _box_trace(
				y = y[n],
				color = colorV[n],
				name = legendV[n],
				points = points,
			)
		end
	else
		trace = _box_trace(
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			points = points,
		)
	end

	_apply_showlegend!(trace, showlegend)

	fig = Plot(trace, _default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
	)
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	plot_violin(x, y; kwargs...)
	plot_violin(y; kwargs...)

Violin plot of the distribution(s) in `y`, optionally grouped by `x`. Pass a
`Vector` of `Vector`s for `y` to draw several violins side-by-side (`violinmode="group"`).

# Keyword Arguments
- `points`: Point display — `"all"`, `"outliers"`, `"suspectedoutliers"`, or `false` (`true` is treated as `"all"`).
- `side`: Violin side — `"both"`, `"positive"`, or `"negative"`.
- `xlabel`, `ylabel`: Axis labels.
- `xrange`, `yrange`: Axis ranges as `[min, max]`; `[0, 0]` keeps auto-scaling.
- `width`, `height`: Figure size in pixels.
- `color`: Violin color(s).
- `legend`: Trace name(s).
- `title`: Figure title.
- `grid`: Show grid lines (default `true`).
- `fontsize`: Base font size.
- `xscale`, `yscale`: `"log"` for a logarithmic axis.
- `showlegend`: Force legend entry visibility.
- `show`: Open an Electron window immediately (returns a `SyncPlot`).

Returns a `PlotlyBase.Plot` (or a `SyncPlot` when `show=true`).
"""
function plot_violin(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	points::Union{Bool, String} = "outliers",
	side::String = "both",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace[n] = _violin_trace(
					x = x[n],
					y = y[n],
					color = colorV[n],
					name = legendV[n],
					points = points,
					side = side,
				)
			end
		else
			for n in eachindex(y)
				trace[n] = _violin_trace(
					x = x,
					y = y[n],
					color = colorV[n],
					name = legendV[n],
					points = points,
					side = side,
				)
			end
		end
	else
		trace = _violin_trace(
			x = x,
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			points = points,
			side = side,
		)
	end

	_apply_showlegend!(trace, showlegend)

	fig = Plot(trace, _default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
	# Render multiple violins side-by-side (Plotly defaults to "overlay").
	if isa(y, Vector) && eltype(y) <: Vector && length(y) > 1
		relayout!(fig, violinmode = "group")
	end
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
	)
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

function plot_violin(
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	points::Union{Bool, String} = "outliers",
	side::String = "both",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))
		for n in eachindex(y)
			trace[n] = _violin_trace(
				y = y[n],
				color = colorV[n],
				name = legendV[n],
				points = points,
				side = side,
			)
		end
	else
		trace = _violin_trace(
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			points = points,
			side = side,
		)
	end

	_apply_showlegend!(trace, showlegend)

	fig = Plot(trace, _default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
	)
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	function plot_scatterpolar(
		theta::Union{AbstractRange, Vector, SubArray},
		r::Union{AbstractRange, Vector, SubArray};
		trange::Vector = [0, 0],
		rrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		marker_size::Union{Int, Vector{Int}} = 0,
		marker_symbol::Union{String, Vector{String}} = "",
		linewidth::Union{Real, Vector{<:Real}} = 0,
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Plots a polar plot.

#### Arguments

- `theta`: Angular coordinate data (can be vector of vectors)
- `r`: Radial coordinate data (can be vector of vectors)

#### Keywords

- `trange`: Range for the angular axis (default: `[0, 0]`)
- `rrange`: Range for the radial axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `dash`: line style ("dash", "dashdot", or "dot", default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to show the grid or not (default: `true`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `marker_size`: Marker size in pixels (default: `0`, can be vector)
- `marker_symbol`: Marker symbol name (default: `""`, can be vector)
- `linewidth`: Line width in pixels (default: `0`, can be vector)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_scatterpolar(
	theta::Union{AbstractRange, Vector, SubArray},
	r::Union{AbstractRange, Vector, SubArray};
	trange::Vector = [0, 0],
	rrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(r, Vector) && eltype(r) <: Vector
		trace = Vector{GenericTrace}(undef, length(r))
		modeV = fill("lines", length(r))
		dashV = fill("", length(r))
		colorV = fill("", length(r))
		legendV = fill("", length(r))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(dash isa Vector)
			fill!(dashV, dash)
		else
			for n in eachindex(dash)
				dashV[n] = dash[n]
			end
		end
		if !(color isa Vector)
			fill!(colorV, color)
		else
			for n in eachindex(color)
				colorV[n] = color[n]
			end
		end
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		marker_sizeV = fill(0, length(r))
		marker_symbolV = fill("", length(r))
		linewidthV = fill(0.0, length(r))
		showlegendV = Vector{Union{Nothing, Bool}}(nothing, length(r))
		if !(marker_size isa Vector)
			fill!(marker_sizeV, marker_size)
		else
			for n in eachindex(marker_size)
				marker_sizeV[n] = marker_size[n]
			end
		end
		if !(marker_symbol isa Vector)
			fill!(marker_symbolV, marker_symbol)
		else
			for n in eachindex(marker_symbol)
				marker_symbolV[n] = marker_symbol[n]
			end
		end
		if !(linewidth isa Vector)
			fill!(linewidthV, linewidth)
		else
			for n in eachindex(linewidth)
				linewidthV[n] = linewidth[n]
			end
		end
		if showlegend isa Bool
			fill!(showlegendV, showlegend)
		elseif showlegend isa Vector
			for n in eachindex(showlegend)
				showlegendV[n] = showlegend[n]
			end
		end

		if isa(theta, Vector) && eltype(theta) <: Vector
			for n in eachindex(r)
				trace_kw = Dict{Symbol,Any}(:r => r[n], :theta => theta[n], :mode => modeV[n], :line => attr(color = colorV[n], dash = dashV[n]), :name => legendV[n])
				mk = Dict{Symbol,Any}()
				marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
				marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
				!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
				linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				trace[n] = scatterpolar(; trace_kw...)
			end
		else
			for n in eachindex(r)
				trace_kw = Dict{Symbol,Any}(:r => r[n], :theta => theta, :mode => modeV[n], :line => attr(color = colorV[n], dash = dashV[n]), :name => legendV[n])
				mk = Dict{Symbol,Any}()
				marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
				marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
				!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
				linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				trace[n] = scatterpolar(; trace_kw...)
			end
		end
	else
		mode1 = _first_or_empty(mode)
		mode1 == "" && (mode1 = "lines")
		trace_kw = Dict{Symbol,Any}(:r => r, :theta => theta, :mode => mode1, :line => attr(color = _first_or_empty(color), dash = _first_or_empty(dash)), :name => _first_or_empty(legend))
		mk = Dict{Symbol,Any}()
		ms = _scalar_or_first(marker_size, 0)
		if ms isa Real && ms > 0
			mk[:size] = ms
		end
		msym = _first_or_empty(marker_symbol)
		if msym != ""
			mk[:symbol] = msym
		end
		!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
		lw = _scalar_or_first(linewidth, 0)
		if lw isa Real && lw > 0
			trace_kw[:line][:width] = lw
		end
		sl = _scalar_or_first(showlegend, nothing)
		if sl isa Bool
			trace_kw[:showlegend] = sl
		end
		trace = scatterpolar(; trace_kw...)
	end

	# Leave `polar.sector` unset by default so the plot shows the full circle;
	# only constrain the angular axis when the caller supplies `trange`.
	layout = Layout(title = title)
	fig = Plot(trace, layout)
	if !all(rrange .== [0, 0])
		update_polars!(fig, radialaxis = attr(range = rrange))
	end
	if !all(trange .== [0, 0])
		update_polars!(fig, attr(sector = trange))
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		update_polars!(fig, radialaxis = attr(showgrid = false), angularaxis = attr(showgrid = false))
	end
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

#endregion

#region 2D Plot

"""
	function plot_heatmap(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
		xscale::String = "",
		yscale::String = "",
	)

Plots heatmap (holographic) data.

#### Arguments

- `x`: x-axis coordinate data
- `y`: y-axis coordinate data
- `U`: 2D hologram data

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the heatmap (default: `""`)
- `title`: Title of the figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `equalar`: Whether to set equal aspect ratio (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)

"""
function plot_heatmap(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
	xscale::String = "",
	yscale::String = "",
	show::Bool = false,
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = heatmap(x = x, y = y, z = FV)
	colorscale != "" && (trace.colorscale = colorscale)
	if !all(zrange .== [0, 0])
		trace.zmin = zrange[1]
		trace.zmax = zrange[2]
	end
	layout = Layout(
		title = title,
		xaxis = attr(
			title = xlabel,
			constrain = "domain",
			automargin = true,
			zeroline = false,
			showline = true,
			mirror = true,
			ticks = "outside",
		),
		yaxis = attr(
			title = ylabel,
			constrain = "domain",
			zeroline = false,
			automargin = true,
			showline = true,
			mirror = true,
			ticks = "outside",
		),
		# margin = attr(r = 0, b = 0, t = 0, l = 0),
	)
	fig = Plot(trace, layout)
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if equalar
		update_xaxes!(fig,
		scaleanchor = "y",
		scaleratio = 1,
	)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	function plot_heatmap(
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
		xscale::String = "",
		yscale::String = "",
	)

Plots heatmap (holographic) data (axes not specified).

#### Arguments

- `U`: 2D hologram data

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the heatmap (default: `""`)
- `title`: Title of the figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `equalar`: Whether to set equal aspect ratio (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)

"""
function plot_heatmap(
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
	xscale::String = "",
	yscale::String = "",
	show::Bool = false,
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_heatmap(x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		width = width,
		height = height,
		equalar = equalar,
		xscale = xscale,
		yscale = yscale,
		show = show,
	)
end


"""
	function plot_contour(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
		xscale::String = "",
		yscale::String = "",
	)

Plots contour data.

#### Arguments

- `x`: x-axis coordinate data
- `y`: y-axis coordinate data
- `U`: 2D data for contours

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the contour plot (default: `""`)
- `title`: Title of the figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `equalar`: Whether to set equal aspect ratio (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)

"""
function plot_contour(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
	xscale::String = "",
	yscale::String = "",
	show::Bool = false,
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = contour(x = x, y = y, z = FV)
	colorscale != "" && (trace.colorscale = colorscale)
	if !all(zrange .== [0, 0])
		trace.zmin = zrange[1]
		trace.zmax = zrange[2]
	end
	layout = Layout(
		title = title,
		xaxis = attr(
			title = xlabel,
			constrain = "domain",
			automargin = true,
			zeroline = false,
			showline = true,
			mirror = true,
			ticks = "outside",
		),
		yaxis = attr(
			title = ylabel,
			constrain = "domain",
			zeroline = false,
			automargin = true,
			showline = true,
			mirror = true,
			ticks = "outside",
		),
		# margin = attr(r = 0, b = 0, t = 0, l = 0),
	)
	fig = Plot(trace, layout)
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if equalar
		update_xaxes!(fig,
		scaleanchor = "y",
		scaleratio = 1,
	)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	function plot_contour(
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
		xscale::String = "",
		yscale::String = "",
	)

Plots contour data (axes not specified).

#### Arguments

- `U`: 2D data for contours

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the contour plot (default: `""`)
- `title`: Title of the figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `equalar`: Whether to set equal aspect ratio (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)

"""
function plot_contour(
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
	xscale::String = "",
	yscale::String = "",
	show::Bool = false,
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_contour(x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		width = width,
		height = height,
		equalar = equalar,
		xscale = xscale,
		yscale = yscale,
		show = show,
	)
end


"""
	function plot_quiver(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		u::Union{AbstractRange, Vector, SubArray},
		v::Union{AbstractRange, Vector, SubArray};
		color::String = "RoyalBlue",
		sizeref::Real = 1,
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Plots a 2D quiver (vector field) diagram using arrow segments.

#### Arguments

- `x`: x-coordinates of vector origins
- `y`: y-coordinates of vector origins
- `u`: x-components of vector directions
- `v`: y-components of vector directions

#### Keywords

- `color`: Arrow color (default: `"RoyalBlue"`)
- `sizeref`: Reference scaling for arrow length (default: `1`)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to show the grid or not (default: `true`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
"""
function plot_quiver(
    x::Union{AbstractRange, Vector, SubArray},
    y::Union{AbstractRange, Vector, SubArray},
    u::Union{AbstractRange, Vector, SubArray},
    v::Union{AbstractRange, Vector, SubArray};
    color::String = "RoyalBlue",
    sizeref::Real = 1,
    xlabel::String = "",
    ylabel::String = "",
    xrange::Vector = [0, 0],
    yrange::Vector = [0, 0],
    width::Int = 0,
    height::Int = 0,
    title::String = "",
    fontsize::Int = 0,
    grid::Bool = true,
    show::Bool = false,
)
    x_vec = isa(x, AbstractRange) ? collect(x) : x
    y_vec = isa(y, AbstractRange) ? collect(y) : y
    u_vec = isa(u, AbstractRange) ? collect(u) : u
    v_vec = isa(v, AbstractRange) ? collect(v) : v

    length(x_vec) == length(y_vec) == length(u_vec) == length(v_vec) ||
        throw(ArgumentError("plot_quiver: x, y, u, v must all have the same length; got $(length(x_vec)), $(length(y_vec)), $(length(u_vec)), $(length(v_vec))"))

    p_max = maximum(sqrt.(u_vec .^ 2 .+ v_vec .^ 2))
    # All-zero (or non-finite) field would divide by zero and produce an all-NaN
    # invisible trace; fall back to unit scale so arrows degenerate to points.
    if !isfinite(p_max) || p_max == 0
        @warn "plot_quiver: all vectors have zero (or non-finite) magnitude; nothing to draw."
        p_max = one(p_max)
    end
    u_ref = u_vec ./ p_max .* sizeref
    v_ref = v_vec ./ p_max .* sizeref
    end_x = x_vec .+ u_ref .* 2 / 3
    end_y = y_vec .+ v_ref .* 2 / 3

    vect_nans = repeat([NaN], length(x_vec))

    arrow_length = sqrt.(u_ref .^ 2 .+ v_ref .^ 2)
    barb_angle = atan.(v_ref, u_ref)

    ang1 = barb_angle .+ atan(1 / 4)
    ang2 = barb_angle .- atan(1 / 4)

    seg1_x = arrow_length .* cos.(ang1) .* sqrt(1.0625)
    seg1_y = arrow_length .* sin.(ang1) .* sqrt(1.0625)

    seg2_x = arrow_length .* cos.(ang2) .* sqrt(1.0625)
    seg2_y = arrow_length .* sin.(ang2) .* sqrt(1.0625)

    arrowend1_x = end_x .- seg1_x
    arrowend1_y = end_y .- seg1_y
    arrowend2_x = end_x .- seg2_x
    arrowend2_y = end_y .- seg2_y
    arrow_x = _tuple_interleave((collect(arrowend1_x), collect(end_x), collect(arrowend2_x), collect(vect_nans)))
    arrow_y = _tuple_interleave((collect(arrowend1_y), collect(end_y), collect(arrowend2_y), collect(vect_nans)))

    arrow = scatter(x = arrow_x, y = arrow_y, mode = "lines", line_color = color,
        fill = "toself", fillcolor = color, hoverinfo = "skip")

    layout = Layout(
        title = title,
        xaxis = attr(
            title = xlabel,
            constrain = "domain",
            automargin = true,
            zeroline = false,
            showline = true,
            mirror = true,
            ticks = "outside",
        ),
        yaxis = attr(
            title = ylabel,
            constrain = "domain",
            zeroline = false,
            automargin = true,
            showline = true,
            mirror = true,
            ticks = "outside",
        ),
        # margin = attr(r = 0, b = 0, t = 0, l = 0),
    )

    fig = Plot(arrow, layout)
    if !all(xrange .== [0, 0])
        update_xaxes!(fig, range = xrange)
    end
    if !all(yrange .== [0, 0])
        update_yaxes!(fig, range = yrange)
    end
    if width > 0
        relayout!(fig, width = width)
    end
    if height > 0
        relayout!(fig, height = height)
    end

    update_xaxes!(fig,
        scaleanchor = "y",
        scaleratio = 1,
    )
    if !grid
        update_xaxes!(fig, showgrid = false)
        update_yaxes!(fig, showgrid = false)
    end
    _apply_default_template!(fig)
    if fontsize > 0
        relayout!(fig, font = attr(size = fontsize))
    end
    return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

#endregion

#region 3D Plot
"""
	function plot_surface(
		X::Array,
		Y::Array,
		Z::Array;
		surfacecolor::Array = [],
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Plots a 3D surface using x, y, z coordinate grids.

#### Arguments

- `X`: Grid of x-coordinates
- `Y`: Grid of y-coordinates
- `Z`: Grid of z-values defining the surface height

#### Keywords

- `surfacecolor`: Color values for each surface point (default: `[]`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `xlabel`: Label for the x-axis (default: `"x"`)
- `ylabel`: Label for the y-axis (default: `"y"`)
- `zlabel`: Label for the z-axis (default: `"z"`)
- `aspectmode`: Aspect mode setting (default: `"auto"`)
- `colorscale`: Color scale for the surface (default: `""`)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to display grid lines (default: `true`)
- `showaxis`: Whether to show axis lines and labels (default: `true`)
- `shared_coloraxis`: If `true`, uses a shared coloraxis (single colorbar) for multiple surfaces (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
"""
function plot_surface(
	X::Array,
	Y::Array,
	Z::Array;
	surfacecolor::Array = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	showaxis::Bool = true,
	shared_coloraxis::Bool = false,
	show::Bool = false,
)
	if isempty(surfacecolor)
		trace = surface(x = X, y = Y, z = Z)
	else
		trace = surface(x = X, y = Y, z = Z, surfacecolor = surfacecolor)
	end
	colorscale != "" && (trace.colorscale = colorscale)
	if shared_coloraxis
		trace.coloraxis = "coloraxis"
	end

	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	layout = Layout(
		title = title,
		scene = attr(
			aspectmode = aspectmode,
			xaxis = attr(title = xlabel, zeroline = false),
			yaxis = attr(title = ylabel, zeroline = false),
			zaxis = attr(title = zlabel, zeroline = false),
		),
		# coloraxis = attr(cmax = maximum(C), cmin = minimum(C)),
	)

	fig = Plot(trace, layout)
	if shared_coloraxis
		if colorscale == ""
			relayout!(fig, coloraxis = attr())
		else
			relayout!(fig, coloraxis = attr(colorscale = colorscale))
		end
	end
	_apply_scene_ranges!(fig; xrange = xrange, yrange = yrange, zrange = zrange)
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		relayout!(fig, scene = attr(
			xaxis = attr(showgrid = false),
			yaxis = attr(showgrid = false),
			zaxis = attr(showgrid = false),
		))
	end
	if !showaxis
		relayout!(fig, scene = attr(
			xaxis = attr(visible = false),
			yaxis = attr(visible = false),
			zaxis = attr(visible = false),
		))
	end
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	plot_surface(
		Z::Array;
		surfacecolor::Array = [],
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Plots a 3D surface given a matrix of height values `Z`, using the array indices as x and y coordinates.

# Arguments
- `Z::Array`: 2D array representing surface height. The dimensions of `Z` define the surface grid, with x and y coordinates automatically generated as `0:size(Z, 1)-1` and `0:size(Z, 2)-1`.

# Keyword Arguments
- `surfacecolor::Array`: Optional array for surface coloring. If empty, `Z` is used for coloring.
- `xrange::Vector`: `[xmin, xmax]` range for the x-axis. `[0, 0]` disables manual range.
- `yrange::Vector`: `[ymin, ymax]` range for the y-axis.
- `zrange::Vector`: `[zmin, zmax]` range for the z-axis.
- `width::Int`: Width of the figure in pixels. `0` uses default.
- `height::Int`: Height of the figure in pixels. `0` uses default.
- `xlabel::String`: Label for x-axis (defaults to `"x"` if empty).
- `ylabel::String`: Label for y-axis (defaults to `"y"` if empty).
- `zlabel::String`: Label for z-axis (defaults to `"z"` if empty).
- `aspectmode::String`: 3D scene aspect mode (`"auto"`, `"cube"`, `"data"`).
- `colorscale::String`: Colorscale name (e.g., `""`, `"Viridis"`).
- `title::String`: Plot title.
- `grid::Bool`: If `false`, disables grid lines.
- `showaxis::Bool`: If `false`, hides all axes.
- `shared_coloraxis::Bool`: If `true`, uses a shared coloraxis (single colorbar) for multiple surfaces.
- `fontsize::Int`: Font size for plot text (default: `0`, uses Plotly default).

# Returns
- A `Plot` object.

# Notes
- This function is a convenience wrapper for `plot_surface(X, Y, Z; ...)`, where `X` and `Y` are index grids derived from the shape of `Z`.
"""
function plot_surface(
	Z::Array; surfacecolor::Array = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	showaxis::Bool = true,
	shared_coloraxis::Bool = false,
	show::Bool = false,
)
	return plot_surface(
		collect(0:size(Z, 1)-1),
		collect(0:size(Z, 2)-1),
		Z;
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		width = width,
		height = height,
		surfacecolor = surfacecolor,
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		grid = grid,
		showaxis = showaxis,
		shared_coloraxis = shared_coloraxis,
		show = show,
	)
end

"""
	plot_scatter3d(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		z::Union{AbstractRange, Vector, SubArray};
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		title::String = "",
		fontsize::Int = 0,
		perspective::Bool = true,
		grid::Bool = true,
		showaxis::Bool = true,
		linewidth::Union{Real, Vector{<:Real}} = 0,
	)

Plots a 3D scatter or line plot using `PlotlyBase`, with options for customizing appearance and handling multiple curves.

# Arguments
- `x`, `y`, `z`: Coordinate vectors. If `z` is a `Vector{Vector}` (i.e., multiple datasets), `x` and `y` must also be `Vector{Vector}` of the same length.

# Keyword Arguments
- `xrange`, `yrange`, `zrange`: Axis limits in the form `[min, max]`. If `[0, 0]`, auto-scaling is used.
- `width`, `height`: Plot dimensions in pixels.
- `mode`: Drawing mode (`"lines"`, `"markers"`, `"lines+markers"`). Can be a vector for multiple traces.
- `color`: Line color(s). Can be a single string or a vector of strings for multiple traces.
- `legend`: Trace label(s) for the legend. Can be a string or a vector.
- `xlabel`, `ylabel`, `zlabel`: Axis labels. Defaults are `"x"`, `"y"`, and `"z"`.
- `aspectmode`: Aspect mode for 3D view. Options include `"auto"`, `"cube"`, and `"data"`.
- `title`: Title of the plot.
- `perspective`: If `false`, uses orthographic projection. Defaults to perspective projection.
- `grid`: Whether to show grid lines.
- `showaxis`: Whether to show axis lines and labels.
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default).
- `linewidth`: Line width in pixels (default: `0`, can be vector).

# Returns
- A `Plot` object containing the 3D scatter or line plot.

# Notes
- This function supports plotting multiple lines by passing `Vector{Vector}` types to `x`, `y`, and `z`. In this case, corresponding vectors of `mode`, `color`, and `legend` will be used.
"""
function plot_scatter3d(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray}; 
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	fontsize::Int = 0,
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	show::Bool = false,
)
	if isa(z, Vector) && eltype(z) <: Vector
		modeV = fill("lines", length(z))
		colorV = fill("", length(z))
		legendV = fill("", length(z))
		trace = Vector{GenericTrace}(undef, length(z))
		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(color isa Vector)
			fill!(colorV, color)
		else
			for n in eachindex(color)
				colorV[n] = color[n]
			end
		end
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end
		marker_sizeV = fill(0, length(z))
		marker_symbolV = fill("", length(z))
		linewidthV = fill(0.0, length(z))
		showlegendV = Vector{Union{Nothing, Bool}}(nothing, length(z))
		if !(marker_size isa Vector)
			fill!(marker_sizeV, marker_size)
		else
			for n in eachindex(marker_size)
				marker_sizeV[n] = marker_size[n]
			end
		end
		if !(marker_symbol isa Vector)
			fill!(marker_symbolV, marker_symbol)
		else
			for n in eachindex(marker_symbol)
				marker_symbolV[n] = marker_symbol[n]
			end
		end
		if !(linewidth isa Vector)
			fill!(linewidthV, linewidth)
		else
			for n in eachindex(linewidth)
				linewidthV[n] = linewidth[n]
			end
		end
		if showlegend isa Bool
			fill!(showlegendV, showlegend)
		elseif showlegend isa Vector
			for n in eachindex(showlegend)
				showlegendV[n] = showlegend[n]
			end
		end

		# x/y may be shared 1D coordinates broadcast across all z-series, or
		# per-series Vector-of-Vectors. Iterate over z (the multi-series arg).
		x_nested = x isa Vector && eltype(x) <: Vector
		y_nested = y isa Vector && eltype(y) <: Vector
		for n in eachindex(z)
			xn = x_nested ? x[n] : x
			yn = y_nested ? y[n] : y
			trace_kw = Dict{Symbol,Any}(:y => yn, :x => xn, :z => z[n], :mode => modeV[n], :line => attr(color = colorV[n]), :name => legendV[n])
			mk = Dict{Symbol,Any}()
			marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
			marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
			!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
			linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
			showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
			trace[n] = scatter3d(; trace_kw...)
		end
	else
		trace_kw = Dict{Symbol,Any}(:x => x, :y => y, :z => z, :mode => mode, :line => attr(color = color), :name => legend)
		mk = Dict{Symbol,Any}()
		if marker_size isa Int && marker_size > 0
			mk[:size] = marker_size
		end
		if marker_symbol isa String && marker_symbol != ""
			mk[:symbol] = marker_symbol
		end
		!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
		if linewidth isa Real && linewidth > 0
			trace_kw[:line][:width] = linewidth
		end
		if showlegend isa Bool
			trace_kw[:showlegend] = showlegend
		end
		trace = scatter3d(; trace_kw...)
	end

	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	layout = Layout(
		title = title,
		scene = attr(
			aspectmode = aspectmode,
			xaxis = attr(title = xlabel, zeroline = false),
			yaxis = attr(title = ylabel, zeroline = false),
			zaxis = attr(title = zlabel, zeroline = false),
		),
	)

	fig = Plot(trace, layout)
	if !perspective
		relayout!(fig, scene = attr(camera = attr(projection = attr(type = "orthographic"))))
	end

	_apply_scene_ranges!(fig; xrange = xrange, yrange = yrange, zrange = zrange)
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		relayout!(fig, scene = attr(
			xaxis = attr(showgrid = false),
			yaxis = attr(showgrid = false),
			zaxis = attr(showgrid = false),
		))
	end
	if !showaxis
		relayout!(fig, scene = attr(
			xaxis = attr(visible = false),
			yaxis = attr(visible = false),
			zaxis = attr(visible = false),
		))
	end
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

"""
	plot_quiver3d(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		z::Union{AbstractRange, Vector, SubArray},
		u::Union{AbstractRange, Vector, SubArray},
		v::Union{AbstractRange, Vector, SubArray},
		w::Union{AbstractRange, Vector, SubArray};
		sizeref::Real = 1,
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		colorscale::String = "",
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		title::String = "",
		fontsize::Int = 0,
		perspective::Bool = true,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Generates a 3D vector field (quiver plot) using cones via `PlotlyBase`.

# Arguments
- `x`, `y`, `z`: Coordinates of vector origins.
- `u`, `v`, `w`: Components of the vector field at the corresponding positions.

# Keyword Arguments
- `sizeref`: Scaling factor for cone size (default: 1).
- `xrange`, `yrange`, `zrange`: Axis limits in the form `[min, max]`. If `[0, 0]`, auto-scaling is used.
- `width`, `height`: Dimensions of the figure in pixels.
- `color`: If specified, sets a uniform color for all vectors.
- `colorscale`: Name of the Plotly colorscale to use when `color` is not specified (default: `""`).
- `xlabel`, `ylabel`, `zlabel`: Labels for x, y, z axes.
- `aspectmode`: Aspect mode for 3D rendering. Options include `"auto"`, `"cube"`, `"data"`.
- `title`: Title of the plot.
- `perspective`: If `false`, uses orthographic projection. Defaults to perspective view.
- `grid`: Controls visibility of grid lines.
- `showaxis`: Controls visibility of axis lines and labels.
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default).

# Returns
- A `Plot` object containing the 3D quiver plot.

# Notes
- By default, the vector field is visualized using cones with magnitude scaling via `sizeref`.
- If `color` is specified, all cones are displayed in a uniform color without a color bar.
"""
function plot_quiver3d(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray},
	w::Union{AbstractRange, Vector, SubArray}; 
	sizeref::Real = 1,
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	colorscale::String = "", xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	fontsize::Int = 0,
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	show::Bool = false,
)
	trace = cone(
		x = x,
		y = y,
		z = z,
		u = u,
		v = v,
		w = w,
		sizemode = "absolute",
		sizeref = sizeref,
		anchor = "cm",
	)
	colorscale != "" && (trace.colorscale = colorscale)
	# A cone shares one colorscale, so a uniform color is a flat two-stop scale.
	col = _first_or_empty(color)
	if col != "" # use single color
		trace.colorscale = [[0, col], [1, col]]
		trace.showscale = false
	end
	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	layout = Layout(
		title = title,
		scene = attr(
			aspectmode = aspectmode,
			xaxis = attr(title = xlabel, zeroline = false),
			yaxis = attr(title = ylabel, zeroline = false),
			zaxis = attr(title = zlabel, zeroline = false),
		),
	)

	fig = Plot(trace, layout)
	if !perspective
		relayout!(fig, scene = attr(camera = attr(projection = attr(type = "orthographic"))))
	end

	_apply_scene_ranges!(fig; xrange = xrange, yrange = yrange, zrange = zrange)
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		relayout!(fig, scene = attr(
			xaxis = attr(showgrid = false),
			yaxis = attr(showgrid = false),
			zaxis = attr(showgrid = false),
		))
	end
	if !showaxis
		relayout!(fig, scene = attr(
			xaxis = attr(visible = false),
			yaxis = attr(visible = false),
			zaxis = attr(visible = false),
		))
	end
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720, title = title == "" ? "PlotlySupply" : title) : fig
end

#endregion

#region Mutating Functions

"""
	function plot_scatter!(
		fig,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		xscale::String = "",
		yscale::String = "",
		marker_size::Union{Int, Vector{Int}} = 0,
		marker_symbol::Union{String, Vector{String}} = "",
		linewidth::Union{Real, Vector{<:Real}} = 0,
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Adds new scatter traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `x`: x-coordinate data (can be vector of vectors)
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `dash`: line style (default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)
- `marker_size`: Marker size in pixels (default: `0`, can be vector)
- `marker_symbol`: Marker symbol name (default: `""`, can be vector)
- `linewidth`: Line width in pixels (default: `0`, can be vector)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_scatter!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	error_x::Union{Nothing, AbstractVector} = nothing,
	error_y::Union{Nothing, AbstractVector} = nothing,
)
	_n0 = length(_plot_data(fig))
	if isa(y, Vector) && eltype(y) <: Vector
		modeV = fill("lines", length(y))
		dashV = fill("", length(y))
		colorV = fill("", length(y))
		legendV = fill("", length(y))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(dash isa Vector)
			fill!(dashV, dash)
		else
			for n in eachindex(dash)
				dashV[n] = dash[n]
			end
		end
		if !(color isa Vector)
			fill!(colorV, color)
		else
			for n in eachindex(color)
				colorV[n] = color[n]
			end
		end
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		marker_sizeV = fill(0, length(y))
		marker_symbolV = fill("", length(y))
		linewidthV = fill(0.0, length(y))
		showlegendV = Vector{Union{Nothing, Bool}}(nothing, length(y))
		if !(marker_size isa Vector)
			fill!(marker_sizeV, marker_size)
		else
			for n in eachindex(marker_size)
				marker_sizeV[n] = marker_size[n]
			end
		end
		if !(marker_symbol isa Vector)
			fill!(marker_symbolV, marker_symbol)
		else
			for n in eachindex(marker_symbol)
				marker_symbolV[n] = marker_symbol[n]
			end
		end
		if !(linewidth isa Vector)
			fill!(linewidthV, linewidth)
		else
			for n in eachindex(linewidth)
				linewidthV[n] = linewidth[n]
			end
		end
		if showlegend isa Bool
			fill!(showlegendV, showlegend)
		elseif showlegend isa Vector
			for n in eachindex(showlegend)
				showlegendV[n] = showlegend[n]
			end
		end

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(:y => y[n], :x => x[n], :mode => modeV[n], :line => attr(color = colorV[n], dash = dashV[n]), :name => legendV[n])
				mk = Dict{Symbol,Any}()
				marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
				marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
				!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
				linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				push!(_plot_data(fig), scatter(; trace_kw...))
			end
		else
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(:y => y[n], :x => x, :mode => modeV[n], :line => attr(color = colorV[n], dash = dashV[n]), :name => legendV[n])
				mk = Dict{Symbol,Any}()
				marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
				marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
				!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
				linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				push!(_plot_data(fig), scatter(; trace_kw...))
			end
		end
	else
		mode1 = _first_or_empty(mode)
		mode1 == "" && (mode1 = "lines")
		trace_kw = Dict{Symbol,Any}(:y => y, :x => x, :mode => mode1, :line => attr(color = _first_or_empty(color), dash = _first_or_empty(dash)), :name => _first_or_empty(legend))
		mk = Dict{Symbol,Any}()
		ms = _scalar_or_first(marker_size, 0)
		if ms isa Real && ms > 0
			mk[:size] = ms
		end
		msym = _first_or_empty(marker_symbol)
		if msym != ""
			mk[:symbol] = msym
		end
		!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
		lw = _scalar_or_first(linewidth, 0)
		if lw isa Real && lw > 0
			trace_kw[:line][:width] = lw
		end
		sl = _scalar_or_first(showlegend, nothing)
		if sl isa Bool
			trace_kw[:showlegend] = sl
		end
		push!(_plot_data(fig), scatter(; trace_kw...))
	end
	_set_error_bars!(view(_plot_data(fig), (_n0 + 1):length(_plot_data(fig))), error_x, error_y)
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title_text = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title_text = ylabel))
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end
	_refresh!(fig)
	return nothing
end

"""
	function plot_scatter!(
		fig,
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		xscale::String = "",
		yscale::String = "",
		marker_size::Union{Int, Vector{Int}} = 0,
		marker_symbol::Union{String, Vector{String}} = "",
		linewidth::Union{Real, Vector{<:Real}} = 0,
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Adds new scatter traces to an existing figure (x-axis not specified, uses indices).

#### Arguments

- `fig`: Existing `plot figure` to append to
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `dash`: line style (default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)
- `marker_size`: Marker size in pixels (default: `0`, can be vector)
- `marker_symbol`: Marker symbol name (default: `""`, can be vector)
- `linewidth`: Line width in pixels (default: `0`, can be vector)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_scatter!(
	fig,
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	error_x::Union{Nothing, AbstractVector} = nothing,
	error_y::Union{Nothing, AbstractVector} = nothing,
)
	if isa(y, Vector) && eltype(y) <: Vector
		x = Vector{Vector{Int}}(undef, length(y))
		for n in eachindex(y)
			x[n] = 0:length(y[n])-1
		end
	else
		x = 0:length(y)-1
	end

	return plot_scatter!(
		fig,
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		mode = mode,
		dash = dash,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
		xscale = xscale,
		yscale = yscale,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		linewidth = linewidth,
		showlegend = showlegend,
		error_x = error_x,
		error_y = error_y,
	)
end

"""
	function plot_stem!(
		fig,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		xscale::String = "",
		yscale::String = "",
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Adds new stem plot traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `x`: x-coordinate data (can be vector of vectors)
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_stem!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = fill("", length(y))
		legendV = fill("", length(y))

		if !(color isa Vector)
			fill!(colorV, color)
		else
			for n in eachindex(color)
				colorV[n] = color[n]
			end
		end
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		showlegendV = Vector{Union{Nothing, Bool}}(nothing, length(y))
		if showlegend isa Bool
			fill!(showlegendV, showlegend)
		elseif showlegend isa Vector
			for n in eachindex(showlegend)
				showlegendV[n] = showlegend[n]
			end
		end

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(:y => y[n], :x => x[n], :line => attr(color = colorV[n]), :name => legendV[n], :mode => "markers")
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				push!(_plot_data(fig), scatter(; trace_kw...))
			end
			for n in eachindex(y)
				for m in eachindex(y[n])
					push!(_plot_data(fig),
						scatter(
							x = [x[n][m], x[n][m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(color = "black", width = 0.5),
							showlegend = false,
						),
					)
				end
			end
		else
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(:y => y[n], :x => x, :line => attr(color = colorV[n]), :name => legendV[n], :mode => "markers")
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				push!(_plot_data(fig), scatter(; trace_kw...))
			end
			for n in eachindex(y)
				for m in eachindex(y[n])
					push!(_plot_data(fig),
						scatter(
							x = [x[m], x[m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(color = "black", width = 0.5),
							showlegend = false,
						),
					)
				end
			end
		end
	else
		trace_kw = Dict{Symbol,Any}(:y => y, :x => x, :line => attr(color = color), :name => legend, :mode => "markers")
		if showlegend isa Bool
			trace_kw[:showlegend] = showlegend
		end
		push!(_plot_data(fig), scatter(; trace_kw...))
		for m in eachindex(y)
			push!(_plot_data(fig),
				scatter(
					x = [x[m], x[m]],
					y = [0, y[m]],
					mode = "lines",
					line = attr(color = "black", width = 0.5),
					showlegend = false,
				),
			)
		end
	end
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title_text = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title_text = ylabel))
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end
	_refresh!(fig)
	return nothing
end

"""
	function plot_stem!(
		fig,
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		xscale::String = "",
		yscale::String = "",
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Adds new stem plot traces to an existing figure (x-axis not specified, uses indices).

#### Arguments

- `fig`: Existing `plot figure` to append to
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_stem!(
	fig,
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(y, Vector) && eltype(y) <: Vector
		x = Vector{Vector{Int}}(undef, length(y))
		for n in eachindex(y)
			x[n] = 0:length(y[n])-1
		end
	else
		x = 0:length(y)-1
	end

	return plot_stem!(
		fig,
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
		xscale = xscale,
		yscale = yscale,
		showlegend = showlegend,
		)
end

function plot_bar!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	orientation::String = "",
	barmode::String = "",
	error_x::Union{Nothing, AbstractVector} = nothing,
	error_y::Union{Nothing, AbstractVector} = nothing,
)
	_n0 = length(_plot_data(fig))
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))

		showlegendV = _string_kwarg_vector("", length(y))
		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				t = _bar_trace(x = x[n], y = y[n], color = colorV[n], name = legendV[n], orientation = orientation)
				showlegend isa Bool && (t.showlegend = showlegend)
				showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
				push!(_plot_data(fig), t)
			end
		else
			for n in eachindex(y)
				t = _bar_trace(x = x, y = y[n], color = colorV[n], name = legendV[n], orientation = orientation)
				showlegend isa Bool && (t.showlegend = showlegend)
				showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
				push!(_plot_data(fig), t)
			end
		end
	else
		t = _bar_trace(
			x = x,
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			orientation = orientation,
		)
		showlegend isa Bool && (t.showlegend = showlegend)
		push!(_plot_data(fig), t)
	end

	_set_error_bars!(view(_plot_data(fig), (_n0 + 1):length(_plot_data(fig))), error_x, error_y)
	barmode == "" || relayout!(fig, barmode = barmode)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		refresh = true,
		apply_template = false,
	)
	return nothing
end

function plot_bar!(
	fig,
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	orientation::String = "",
	barmode::String = "",
	error_x::Union{Nothing, AbstractVector} = nothing,
	error_y::Union{Nothing, AbstractVector} = nothing,
)
	x = _auto_xvalues(y)
	return plot_bar!(
		fig,
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
		xscale = xscale,
		yscale = yscale,
		showlegend = showlegend,
		orientation = orientation,
		barmode = barmode,
		error_x = error_x,
		error_y = error_y,
	)
end

function plot_histogram!(
	fig,
	x::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	nbinsx::Int = 0,
	histnorm::String = "",
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(x, Vector) && eltype(x) <: Vector
		colorV = _string_kwarg_vector(color, length(x))
		legendV = _string_kwarg_vector(legend, length(x))
		for n in eachindex(x)
			t = _histogram_trace(
				x = x[n],
				nbinsx = nbinsx,
				histnorm = histnorm,
				color = colorV[n],
				name = legendV[n],
			)
			showlegend isa Bool && (t.showlegend = showlegend)
			showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
			push!(_plot_data(fig), t)
		end
	else
		t = _histogram_trace(
			x = x,
			nbinsx = nbinsx,
			histnorm = histnorm,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
		)
		showlegend isa Bool && (t.showlegend = showlegend)
		push!(_plot_data(fig), t)
	end

	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		refresh = true,
		apply_template = false,
	)
	return nothing
end

function plot_box!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	points::Union{Bool, String} = "outliers",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				t = _box_trace(x = x[n], y = y[n], color = colorV[n], name = legendV[n], points = points)
				showlegend isa Bool && (t.showlegend = showlegend)
				showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
				push!(_plot_data(fig), t)
			end
		else
			for n in eachindex(y)
				t = _box_trace(x = x, y = y[n], color = colorV[n], name = legendV[n], points = points)
				showlegend isa Bool && (t.showlegend = showlegend)
				showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
				push!(_plot_data(fig), t)
			end
		end
	else
		t = _box_trace(x = x, y = y, color = _first_or_empty(color), name = _first_or_empty(legend), points = points)
		showlegend isa Bool && (t.showlegend = showlegend)
		push!(_plot_data(fig), t)
	end

	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		refresh = true,
		apply_template = false,
	)
	return nothing
end

function plot_box!(
	fig,
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	points::Union{Bool, String} = "outliers",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		for n in eachindex(y)
			t = _box_trace(y = y[n], color = colorV[n], name = legendV[n], points = points)
			showlegend isa Bool && (t.showlegend = showlegend)
			showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
			push!(_plot_data(fig), t)
		end
	else
		t = _box_trace(y = y, color = _first_or_empty(color), name = _first_or_empty(legend), points = points)
		showlegend isa Bool && (t.showlegend = showlegend)
		push!(_plot_data(fig), t)
	end

	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		refresh = true,
		apply_template = false,
	)
	return nothing
end

function plot_violin!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	points::Union{Bool, String} = "outliers",
	side::String = "both",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				t = _violin_trace(x = x[n], y = y[n], color = colorV[n], name = legendV[n], points = points, side = side)
				showlegend isa Bool && (t.showlegend = showlegend)
				showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
				push!(_plot_data(fig), t)
			end
		else
			for n in eachindex(y)
				t = _violin_trace(x = x, y = y[n], color = colorV[n], name = legendV[n], points = points, side = side)
				showlegend isa Bool && (t.showlegend = showlegend)
				showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
				push!(_plot_data(fig), t)
			end
		end
	else
		t = _violin_trace(x = x, y = y, color = _first_or_empty(color), name = _first_or_empty(legend), points = points, side = side)
		showlegend isa Bool && (t.showlegend = showlegend)
		push!(_plot_data(fig), t)
	end

	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		refresh = true,
		apply_template = false,
	)
	return nothing
end

function plot_violin!(
	fig,
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	points::Union{Bool, String} = "outliers",
	side::String = "both",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	xscale::String = "",
	yscale::String = "",
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		for n in eachindex(y)
			t = _violin_trace(y = y[n], color = colorV[n], name = legendV[n], points = points, side = side)
			showlegend isa Bool && (t.showlegend = showlegend)
			showlegend isa Vector && n <= length(showlegend) && (t.showlegend = showlegend[n])
			push!(_plot_data(fig), t)
		end
	else
		t = _violin_trace(y = y, color = _first_or_empty(color), name = _first_or_empty(legend), points = points, side = side)
		showlegend isa Bool && (t.showlegend = showlegend)
		push!(_plot_data(fig), t)
	end

	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		refresh = true,
		apply_template = false,
	)
	return nothing
end

"""
	function plot_scatterpolar!(
		fig,
		theta::Union{AbstractRange, Vector, SubArray},
		r::Union{AbstractRange, Vector, SubArray};
		trange::Vector = [0, 0],
		rrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		marker_size::Union{Int, Vector{Int}} = 0,
		marker_symbol::Union{String, Vector{String}} = "",
		linewidth::Union{Real, Vector{<:Real}} = 0,
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Adds new polar scatter traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `theta`: Angular coordinates
- `r`: Radial coordinates

#### Keywords

- `trange`: Range for the angular axis (default: `[0, 0]`)
- `rrange`: Range for the radial axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `dash`: line style (default: `""`, can be vector)
- `color`: Color of the plot (default: `""`, can be vector)
- `legend`: Legend name (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)
- `marker_size`: Marker size in pixels (default: `0`, can be vector)
- `marker_symbol`: Marker symbol name (default: `""`, can be vector)
- `linewidth`: Line width in pixels (default: `0`, can be vector)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_scatterpolar!(
	fig,
	theta::Union{AbstractRange, Vector, SubArray},
	r::Union{AbstractRange, Vector, SubArray};
	trange::Vector = [0, 0],
	rrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(r, Vector) && eltype(r) <: Vector
		modeV = fill("lines", length(r))
		dashV = fill("", length(r))
		colorV = fill("", length(r))
		legendV = fill("", length(r))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(dash isa Vector)
			fill!(dashV, dash)
		else
			for n in eachindex(dash)
				dashV[n] = dash[n]
			end
		end
		if !(color isa Vector)
			fill!(colorV, color)
		else
			for n in eachindex(color)
				colorV[n] = color[n]
			end
		end
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		marker_sizeV = fill(0, length(r))
		marker_symbolV = fill("", length(r))
		linewidthV = fill(0.0, length(r))
		showlegendV = Vector{Union{Nothing, Bool}}(nothing, length(r))
		if !(marker_size isa Vector)
			fill!(marker_sizeV, marker_size)
		else
			for n in eachindex(marker_size)
				marker_sizeV[n] = marker_size[n]
			end
		end
		if !(marker_symbol isa Vector)
			fill!(marker_symbolV, marker_symbol)
		else
			for n in eachindex(marker_symbol)
				marker_symbolV[n] = marker_symbol[n]
			end
		end
		if !(linewidth isa Vector)
			fill!(linewidthV, linewidth)
		else
			for n in eachindex(linewidth)
				linewidthV[n] = linewidth[n]
			end
		end
		if showlegend isa Bool
			fill!(showlegendV, showlegend)
		elseif showlegend isa Vector
			for n in eachindex(showlegend)
				showlegendV[n] = showlegend[n]
			end
		end

		if isa(theta, Vector) && eltype(theta) <: Vector
			for n in eachindex(r)
				trace_kw = Dict{Symbol,Any}(:r => r[n], :theta => theta[n], :mode => modeV[n], :line => attr(color = colorV[n], dash = dashV[n]), :name => legendV[n])
				mk = Dict{Symbol,Any}()
				marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
				marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
				!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
				linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				push!(_plot_data(fig), scatterpolar(; trace_kw...))
			end
		else
			for n in eachindex(r)
				trace_kw = Dict{Symbol,Any}(:r => r[n], :theta => theta, :mode => modeV[n], :line => attr(color = colorV[n], dash = dashV[n]), :name => legendV[n])
				mk = Dict{Symbol,Any}()
				marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
				marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
				!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
				linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				push!(_plot_data(fig), scatterpolar(; trace_kw...))
			end
		end
	else
		mode1 = _first_or_empty(mode)
		mode1 == "" && (mode1 = "lines")
		trace_kw = Dict{Symbol,Any}(:r => r, :theta => theta, :mode => mode1, :line => attr(color = _first_or_empty(color), dash = _first_or_empty(dash)), :name => _first_or_empty(legend))
		mk = Dict{Symbol,Any}()
		ms = _scalar_or_first(marker_size, 0)
		if ms isa Real && ms > 0
			mk[:size] = ms
		end
		msym = _first_or_empty(marker_symbol)
		if msym != ""
			mk[:symbol] = msym
		end
		!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
		lw = _scalar_or_first(linewidth, 0)
		if lw isa Real && lw > 0
			trace_kw[:line][:width] = lw
		end
		sl = _scalar_or_first(showlegend, nothing)
		if sl isa Bool
			trace_kw[:showlegend] = sl
		end
		push!(_plot_data(fig), scatterpolar(; trace_kw...))
	end
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	# Do not clip the angular axis to the data extent by default (full circle);
	# only constrain it when the caller supplies `trange`.
	if !all(rrange .== [0, 0])
		update_polars!(fig, radialaxis = attr(range = rrange))
	end
	if !all(trange .== [0, 0])
		update_polars!(fig, attr(sector = trange))
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		update_polars!(fig, radialaxis = attr(showgrid = false), angularaxis = attr(showgrid = false))
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	_refresh!(fig)
	return nothing
end

"""
	function plot_heatmap!(
		fig,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
		xscale::String = "",
		yscale::String = "",
	)

Adds new heatmap traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `x`: x-coordinate values
- `y`: y-coordinate values
- `U`: Matrix of values

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `colorscale`: Color scale for the heatmap (default: `""`)
- `title`: Title for the heatmap (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `equalar`: Whether to set equal aspect ratio (default: `false`)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)

"""
function plot_heatmap!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
	xscale::String = "",
	yscale::String = "",
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = heatmap(x = x, y = y, z = FV)
	colorscale != "" && (trace.colorscale = colorscale)
	if !all(zrange .== [0, 0])
		trace.zmin = zrange[1]
		trace.zmax = zrange[2]
	end
	push!(_plot_data(fig), trace)
	# apply optional layout updates if labels or title provided
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title = ylabel))
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if equalar
		update_xaxes!(fig,
			scaleanchor = "y",
			scaleratio = 1,
		)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end
	_refresh!(fig)
	return nothing
end

function plot_heatmap!(
	fig,
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
	xscale::String = "",
	yscale::String = "",
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_heatmap!(fig, x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		width = width,
		height = height,
		equalar = equalar,
		xscale = xscale,
		yscale = yscale,
	)
end

"""
	function plot_contour!(
		fig,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
		xscale::String = "",
		yscale::String = "",
	)

Adds new contour traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `x`: x-coordinate values
- `y`: y-coordinate values
- `U`: Matrix of values

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `colorscale`: Color scale for the contour plot (default: `""`)
- `title`: Title for the contour (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `equalar`: Whether to set equal aspect ratio (default: `false`)
- `xscale`: X-axis scale type ("log" for logarithmic, default: `""`)
- `yscale`: Y-axis scale type ("log" for logarithmic, default: `""`)

"""
function plot_contour!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
	xscale::String = "",
	yscale::String = "",
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = contour(x = x, y = y, z = FV)
	colorscale != "" && (trace.colorscale = colorscale)
	if !all(zrange .== [0, 0])
		trace.zmin = zrange[1]
		trace.zmax = zrange[2]
	end
	push!(_plot_data(fig), trace)
	# apply optional layout updates if labels or title provided
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title = ylabel))
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if equalar
		update_xaxes!(fig,
			scaleanchor = "y",
			scaleratio = 1,
		)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	if xscale != ""
		update_xaxes!(fig, type = xscale)
	end
	if yscale != ""
		update_yaxes!(fig, type = yscale)
	end
	_refresh!(fig)
	return nothing
end

function plot_contour!(
	fig,
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
	xscale::String = "",
	yscale::String = "",
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_contour!(fig, x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		width = width,
		height = height,
		equalar = equalar,
		xscale = xscale,
		yscale = yscale,
	)
end

"""
	function plot_quiver!(
		fig,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		u::Union{AbstractRange, Vector, SubArray},
		v::Union{AbstractRange, Vector, SubArray};
		color::String = "RoyalBlue",
		sizeref::Real = 1,
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Adds new quiver plot traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `x`: x-coordinate values
- `y`: y-coordinate values
- `u`: x-component of vector field
- `v`: y-component of vector field

#### Keywords

- `color`: Color of the arrows (default: `"RoyalBlue"`)
- `sizeref`: Reference scaling for arrow length (default: `1`)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)

"""
function plot_quiver!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray};
	color::String = "RoyalBlue",
	sizeref::Real = 1,
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
)
	x_vec = isa(x, AbstractRange) ? collect(x) : x
	y_vec = isa(y, AbstractRange) ? collect(y) : y
	u_vec = isa(u, AbstractRange) ? collect(u) : u
	v_vec = isa(v, AbstractRange) ? collect(v) : v

	length(x_vec) == length(y_vec) == length(u_vec) == length(v_vec) ||
		throw(ArgumentError("plot_quiver!: x, y, u, v must all have the same length; got $(length(x_vec)), $(length(y_vec)), $(length(u_vec)), $(length(v_vec))"))

	p_max = maximum(sqrt.(u_vec .^ 2 .+ v_vec .^ 2))
	if !isfinite(p_max) || p_max == 0
		@warn "plot_quiver!: all vectors have zero (or non-finite) magnitude; nothing to draw."
		p_max = one(p_max)
	end
	u_ref = u_vec ./ p_max .* sizeref
	v_ref = v_vec ./ p_max .* sizeref
	end_x = x_vec .+ u_ref .* 2 / 3
	end_y = y_vec .+ v_ref .* 2 / 3

	vect_nans = repeat([NaN], length(x_vec))

	arrow_length = sqrt.(u_ref .^ 2 .+ v_ref .^ 2)
	barb_angle = atan.(v_ref, u_ref)

	ang1 = barb_angle .+ atan(1 / 4)
	ang2 = barb_angle .- atan(1 / 4)

	seg1_x = arrow_length .* cos.(ang1) .* sqrt(1.0625)
	seg1_y = arrow_length .* sin.(ang1) .* sqrt(1.0625)

	seg2_x = arrow_length .* cos.(ang2) .* sqrt(1.0625)
	seg2_y = arrow_length .* sin.(ang2) .* sqrt(1.0625)

	arrowend1_x = end_x .- seg1_x
	arrowend1_y = end_y .- seg1_y
	arrowend2_x = end_x .- seg2_x
	arrowend2_y = end_y .- seg2_y
	arrow_x = _tuple_interleave((collect(arrowend1_x), collect(end_x), collect(arrowend2_x), collect(vect_nans)))
	arrow_y = _tuple_interleave((collect(arrowend1_y), collect(end_y), collect(arrowend2_y), collect(vect_nans)))

	arrow = scatter(x = arrow_x, y = arrow_y, mode = "lines", line_color = color,
		fill = "toself", fillcolor = color, hoverinfo = "skip")
	push!(_plot_data(fig), arrow)
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title = ylabel))
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	update_xaxes!(fig,
		scaleanchor = "y",
		scaleratio = 1,
	)
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	_refresh!(fig)
	return nothing
end

"""
	function plot_surface!(
		fig,
		X::Union{AbstractRange, Array, SubArray},
		Y::Union{AbstractRange, Array, SubArray},
		Z::Union{SubArray, Array};
		surfacecolor::Array = [],
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Adds new surface traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `X`: X-coordinates
- `Y`: Y-coordinates
- `Z`: Z-coordinates

#### Keywords

- `surfacecolor`: Color values for each surface point (default: `[]`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `zlabel`: Label for the z-axis (default: `""`)
- `aspectmode`: Aspect mode setting (default: `"auto"`)
- `colorscale`: Color scale for the surface (default: `""`)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to display grid lines (default: `true`)
- `showaxis`: Whether to show axis lines and labels (default: `true`)
- `shared_coloraxis`: If `true`, uses a shared coloraxis (single colorbar) for multiple surfaces (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_surface!(
	fig,
	X::Union{AbstractRange, Array, SubArray},
	Y::Union{AbstractRange, Array, SubArray},
	Z::Union{SubArray, Array};
	surfacecolor::Array = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	showaxis::Bool = true,
	shared_coloraxis::Bool = false,
	color::Array = [],  # Alias for surfacecolor for backward compatibility
)
	# Handle color parameter as alias for surfacecolor
	if !isempty(color)
		surfacecolor = color
	end
	
	if isempty(surfacecolor)
		trace = surface(x = X, y = Y, z = Z)
	else
		trace = surface(x = X, y = Y, z = Z, surfacecolor = surfacecolor)
	end
	colorscale != "" && (trace.colorscale = colorscale)
	if shared_coloraxis
		trace.coloraxis = "coloraxis"
	end
	push!(_plot_data(fig), trace)

	if shared_coloraxis
		for tr in _plot_data(fig)
			if get(tr, :type, "") == "surface"
				tr.coloraxis = "coloraxis"
			end
		end
		if colorscale == ""
			relayout!(fig, coloraxis = attr())
		else
			relayout!(fig, coloraxis = attr(colorscale = colorscale))
		end
	end

	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	xaxis_attr = attr(title = xlabel, zeroline = false)
	yaxis_attr = attr(title = ylabel, zeroline = false)
	zaxis_attr = attr(title = zlabel, zeroline = false)
	if !grid
		xaxis_attr = merge(xaxis_attr, attr(showgrid = false))
		yaxis_attr = merge(yaxis_attr, attr(showgrid = false))
		zaxis_attr = merge(zaxis_attr, attr(showgrid = false))
	end
	if !showaxis
		xaxis_attr = merge(xaxis_attr, attr(visible = false))
		yaxis_attr = merge(yaxis_attr, attr(visible = false))
		zaxis_attr = merge(zaxis_attr, attr(visible = false))
	end
	scene_attr = attr(
		aspectmode = aspectmode,
		xaxis = xaxis_attr,
		yaxis = yaxis_attr,
		zaxis = zaxis_attr,
	)
	relayout!(fig, scene = scene_attr)
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	_apply_scene_ranges!(fig; xrange = xrange, yrange = yrange, zrange = zrange)
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	_refresh!(fig)
	return nothing
end

function plot_surface!(
	fig,
	Z::Union{SubArray, Array}; surfacecolor::Array = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	showaxis::Bool = true,
	shared_coloraxis::Bool = false,
	color::Array = [],  # Alias for surfacecolor for backward compatibility
)
	return plot_surface!(
		fig,
		collect(0:size(Z, 1)-1),
		collect(0:size(Z, 2)-1),
		Z;
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		width = width,
		height = height,
		surfacecolor = surfacecolor,
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		grid = grid,
		showaxis = showaxis,
		shared_coloraxis = shared_coloraxis,
		color = color,
	)
end

"""
	function plot_scatter3d!(
		fig,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		z::Union{AbstractRange, Vector, SubArray};
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		title::String = "",
		fontsize::Int = 0,
		perspective::Bool = true,
		grid::Bool = true,
		showaxis::Bool = true,
		marker_size::Union{Int, Vector{Int}} = 0,
		marker_symbol::Union{String, Vector{String}} = "",
		linewidth::Union{Real, Vector{<:Real}} = 0,
		showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
	)

Adds new 3D scatter traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `x`: x-coordinate data (can be vector of vectors)
- `y`: y-coordinate data (can be vector of vectors)
- `z`: z-coordinate data (can be vector of vectors)

#### Keywords

- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `color`: Color of the plot (default: `""`, can be vector)
- `legend`: Legend name (default: `""`, can be vector)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `zlabel`: Label for the z-axis (default: `""`)
- `aspectmode`: Aspect mode for 3D view (default: `"auto"`)
- `title`: Title of the plot (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `perspective`: If `false`, uses orthographic projection (default: `true`)
- `grid`: Whether to show grid lines (default: `true`)
- `showaxis`: Whether to show axis lines and labels (default: `true`)
- `marker_size`: Marker size in pixels (default: `0`, can be vector)
- `marker_symbol`: Marker symbol name (default: `""`, can be vector)
- `linewidth`: Line width in pixels (default: `0`, can be vector)
- `showlegend`: Whether to show legend entry (default: `nothing`, can be vector)

"""
function plot_scatter3d!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray};
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	fontsize::Int = 0,
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	if isa(z, Vector) && eltype(z) <: Vector
		modeV = fill("lines", length(z))
		colorV = fill("", length(z))
		legendV = fill("", length(z))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(color isa Vector)
			fill!(colorV, color)
		else
			for n in eachindex(color)
				colorV[n] = color[n]
			end
		end
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		marker_sizeV = fill(0, length(z))
		marker_symbolV = fill("", length(z))
		linewidthV = fill(0.0, length(z))
		showlegendV = Vector{Union{Nothing, Bool}}(nothing, length(z))
		if !(marker_size isa Vector)
			fill!(marker_sizeV, marker_size)
		else
			for n in eachindex(marker_size)
				marker_sizeV[n] = marker_size[n]
			end
		end
		if !(marker_symbol isa Vector)
			fill!(marker_symbolV, marker_symbol)
		else
			for n in eachindex(marker_symbol)
				marker_symbolV[n] = marker_symbol[n]
			end
		end
		if !(linewidth isa Vector)
			fill!(linewidthV, linewidth)
		else
			for n in eachindex(linewidth)
				linewidthV[n] = linewidth[n]
			end
		end
		if showlegend isa Bool
			fill!(showlegendV, showlegend)
		elseif showlegend isa Vector
			for n in eachindex(showlegend)
				showlegendV[n] = showlegend[n]
			end
		end

		# x/y may be shared 1D coordinates broadcast across all z-series.
		x_nested = x isa Vector && eltype(x) <: Vector
		y_nested = y isa Vector && eltype(y) <: Vector
		for n in eachindex(z)
			xn = x_nested ? x[n] : x
			yn = y_nested ? y[n] : y
			trace_kw = Dict{Symbol,Any}(:y => yn, :x => xn, :z => z[n], :mode => modeV[n], :line => attr(color = colorV[n]), :name => legendV[n])
			mk = Dict{Symbol,Any}()
			marker_sizeV[n] > 0 && (mk[:size] = marker_sizeV[n])
			marker_symbolV[n] != "" && (mk[:symbol] = marker_symbolV[n])
			!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
			linewidthV[n] > 0 && (trace_kw[:line][:width] = linewidthV[n])
			showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
			push!(_plot_data(fig), scatter3d(; trace_kw...))
		end
	else
		trace_kw = Dict{Symbol,Any}(:x => x, :y => y, :z => z, :mode => mode, :line => attr(color = color), :name => legend)
		mk = Dict{Symbol,Any}()
		if marker_size isa Int && marker_size > 0
			mk[:size] = marker_size
		end
		if marker_symbol isa String && marker_symbol != ""
			mk[:symbol] = marker_symbol
		end
		!isempty(mk) && (trace_kw[:marker] = attr(; mk...))
		if linewidth isa Real && linewidth > 0
			trace_kw[:line][:width] = linewidth
		end
		if showlegend isa Bool
			trace_kw[:showlegend] = showlegend
		end
		push!(_plot_data(fig), scatter3d(; trace_kw...))
	end
	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	xaxis_attr = attr(title = xlabel, zeroline = false)
	yaxis_attr = attr(title = ylabel, zeroline = false)
	zaxis_attr = attr(title = zlabel, zeroline = false)
	if !grid
		xaxis_attr = merge(xaxis_attr, attr(showgrid = false))
		yaxis_attr = merge(yaxis_attr, attr(showgrid = false))
		zaxis_attr = merge(zaxis_attr, attr(showgrid = false))
	end
	if !showaxis
		xaxis_attr = merge(xaxis_attr, attr(visible = false))
		yaxis_attr = merge(yaxis_attr, attr(visible = false))
		zaxis_attr = merge(zaxis_attr, attr(visible = false))
	end
	relayout!(fig, scene = attr(
		aspectmode = aspectmode,
		xaxis = xaxis_attr,
		yaxis = yaxis_attr,
		zaxis = zaxis_attr,
	))
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if !perspective
		relayout!(fig, scene = attr(camera = attr(projection = attr(type = "orthographic"))))
	end
	_apply_scene_ranges!(fig; xrange = xrange, yrange = yrange, zrange = zrange)
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	_refresh!(fig)
	return nothing
end

"""
	function plot_quiver3d!(
		fig,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		z::Union{AbstractRange, Vector, SubArray},
		u::Union{AbstractRange, Vector, SubArray},
		v::Union{AbstractRange, Vector, SubArray},
		w::Union{AbstractRange, Vector, SubArray};
		sizeref::Real = 1,
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::String = "",
		colorscale::String = "",
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		title::String = "",
		fontsize::Int = 0,
		perspective::Bool = true,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Adds new 3D quiver plot traces to an existing figure.

#### Arguments

- `fig`: Existing `plot figure` to append to
- `x`: x-coordinate values
- `y`: y-coordinate values
- `z`: z-coordinate values
- `u`: x-component of vector field
- `v`: y-component of vector field
- `w`: z-component of vector field

#### Keywords

- `sizeref`: Reference scaling for arrow length (default: `1`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `color`: Color of the arrows (default: `""`)
- `colorscale`: Colorscale for magnitude visualization (default: `""`)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `zlabel`: Label for the z-axis (default: `""`)
- `aspectmode`: Aspect mode for 3D view (default: `"auto"`)
- `title`: Title of the plot (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `perspective`: If `false`, uses orthographic projection (default: `true`)
- `grid`: Whether to show grid lines (default: `true`)
- `showaxis`: Whether to show axis lines and labels (default: `true`)

"""
function plot_quiver3d!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray},
	w::Union{AbstractRange, Vector, SubArray};
	sizeref::Real = 1,
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	colorscale::String = "",
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	fontsize::Int = 0,
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
)
	trace = cone(
		x = x,
		y = y,
		z = z,
		u = u,
		v = v,
		w = w,
		sizemode = "absolute",
		sizeref = sizeref,
		anchor = "cm",
	)
	colorscale != "" && (trace.colorscale = colorscale)
	# if a single color is requested, force a uniform colorscale and hide colorbar
	col = _first_or_empty(color)
	if col != ""
		trace.colorscale = [[0, col], [1, col]]
		trace.showscale = false
	end
	push!(_plot_data(fig), trace)
	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	xaxis_attr = attr(title = xlabel, zeroline = false)
	yaxis_attr = attr(title = ylabel, zeroline = false)
	zaxis_attr = attr(title = zlabel, zeroline = false)
	if !grid
		xaxis_attr = merge(xaxis_attr, attr(showgrid = false))
		yaxis_attr = merge(yaxis_attr, attr(showgrid = false))
		zaxis_attr = merge(zaxis_attr, attr(showgrid = false))
	end
	if !showaxis
		xaxis_attr = merge(xaxis_attr, attr(visible = false))
		yaxis_attr = merge(yaxis_attr, attr(visible = false))
		zaxis_attr = merge(zaxis_attr, attr(visible = false))
	end
	relayout!(fig, scene = attr(
		aspectmode = aspectmode,
		xaxis = xaxis_attr,
		yaxis = yaxis_attr,
		zaxis = zaxis_attr,
	))
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if !perspective
		relayout!(fig, scene = attr(camera = attr(projection = attr(type = "orthographic"))))
	end
	_apply_scene_ranges!(fig; xrange = xrange, yrange = yrange, zrange = zrange)
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	_apply_default_legend!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	_refresh!(fig)
	return nothing
end

#endregion

"""
	set_template!(fig, template = "plotly_white")

Applies a visual template to a figure.

# Arguments
- `fig`: A `PlotlyBase.Plot` or a `PlotlySupply.SyncPlot`.
- `template`: Template name string or symbol.

# Notes
- This modifies the figure in-place using `relayout!`.
- Available templates include `plotly`, `ggplot2`, `seaborn`, `simple_white`, `plotly_dark`, etc.
"""
function set_template!(fig, template = string(get_default_template()))
	chosen = _normalize_template(template)
	relayout!(fig, template = chosen)
	_refresh!(fig)
	return nothing
end

## additional auxilliary functions

function _tuple_interleave(tu::Union{NTuple{3, Vector}, NTuple{4, Vector}})
	#auxilliary function to interleave elements of a NTuple of vectors, N = 3 or 4
	zipped_data = collect(zip(tu...))
	vv_zdata = [collect(elem) for elem in zipped_data]
	return reduce(vcat, vv_zdata)
end

#region Extended chart types

# Open a window for the freshly-built figure when `show=true`, otherwise return
# the `Plot`. Mirrors the inline pattern used by the core constructors.
_maybe_show(fig, show::Bool, width::Int, height::Int, title::String) =
	show ? to_syncplot(fig; width = width > 0 ? width : 960, height = height > 0 ? height : 720,
		title = title == "" ? "PlotlySupply" : title) : fig

# Lightweight layout options for non-Cartesian charts (pie, sankey, sunburst, …)
# that have no x/y axes to style. On first construction the default template is
# applied; on append (`apply_template=false`) only the legend is refreshed so a
# user-set template survives.
function _apply_basic_plot_options!(
	fig;
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	apply_template::Bool = true,
)
	title != "" && relayout!(fig, title = title)
	width > 0 && relayout!(fig, width = width)
	height > 0 && relayout!(fig, height = height)
	apply_template ? _apply_default_template!(fig) : _apply_default_legend!(fig)
	fontsize > 0 && relayout!(fig, font = attr(size = fontsize))
	return nothing
end

# Standard 3D scene layout shared by the 3D extended charts.
function _scene_layout(; title::String, xlabel::String, ylabel::String, zlabel::String, aspectmode::String)
	return Layout(
		title = title,
		scene = attr(
			aspectmode = aspectmode,
			xaxis = attr(title = xlabel == "" ? "x" : xlabel, zeroline = false),
			yaxis = attr(title = ylabel == "" ? "y" : ylabel, zeroline = false),
			zaxis = attr(title = zlabel == "" ? "z" : zlabel, zeroline = false),
		),
	)
end

# ── Pie ──────────────────────────────────────────────────────────────

function _pie_trace(values; labels, hole::Real, colors::Vector{String}, name::String)
	kw = Dict{Symbol, Any}(:values => collect(values))
	labels === nothing || (kw[:labels] = collect(labels))
	hole > 0 && (kw[:hole] = hole)
	isempty(colors) || (kw[:marker] = attr(colors = colors))
	name == "" || (kw[:name] = name)
	return pie(; kw...)
end

"""
	plot_pie(values; labels=nothing, hole=0, colors=String[], kwargs...)

Pie (or donut, when `hole>0`) chart of `values`, with optional slice `labels`
and per-slice `colors`.

# Keyword Arguments
- `labels`: Slice labels (defaults to indices).
- `hole`: Donut hole fraction in `[0, 1)`.
- `colors`: Per-slice colors.
- `title`, `width`, `height`, `fontsize`, `show`: Common figure options.
"""
function plot_pie(
	values::Union{AbstractVector, AbstractRange};
	labels::Union{Nothing, AbstractVector} = nothing,
	hole::Real = 0,
	colors::Vector{String} = String[],
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	fig = Plot(_pie_trace(values; labels = labels, hole = hole, colors = colors, name = ""), Layout())
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_pie!(fig, values; labels=nothing, hole=0, colors=String[], kwargs...)

Append a pie/donut trace to an existing figure.
"""
function plot_pie!(
	fig,
	values::Union{AbstractVector, AbstractRange};
	labels::Union{Nothing, AbstractVector} = nothing,
	hole::Real = 0,
	colors::Vector{String} = String[],
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(_plot_data(fig), _pie_trace(values; labels = labels, hole = hole, colors = colors, name = ""))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Sunburst / Treemap (hierarchical) ────────────────────────────────

function _hierarchy_trace(constructor, labels, parents; values, colorscale::String, name::String)
	length(labels) == length(parents) ||
		throw(ArgumentError("`labels` and `parents` must have the same length; got $(length(labels)) and $(length(parents))."))
	kw = Dict{Symbol, Any}(:labels => collect(labels), :parents => collect(parents))
	values === nothing || (kw[:values] = collect(values))
	colorscale == "" || (kw[:marker] = attr(colorscale = colorscale))
	name == "" || (kw[:name] = name)
	return constructor(; kw...)
end

"""
	plot_sunburst(labels, parents; values=nothing, colorscale="", kwargs...)

Hierarchical sunburst chart. `parents[i]` is the label of `labels[i]`'s parent
(use `""` for a root). Optional `values` size the slices.
"""
function plot_sunburst(
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	fig = Plot(_hierarchy_trace(sunburst, labels, parents; values = values, colorscale = colorscale, name = ""), Layout())
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_sunburst!(fig, labels, parents; values=nothing, colorscale="", kwargs...)

Append a sunburst trace to an existing figure.
"""
function plot_sunburst!(
	fig,
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(_plot_data(fig), _hierarchy_trace(sunburst, labels, parents; values = values, colorscale = colorscale, name = ""))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_treemap(labels, parents; values=nothing, colorscale="", kwargs...)

Hierarchical treemap chart. See [`plot_sunburst`](@ref) for the `labels`/`parents` convention.
"""
function plot_treemap(
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	fig = Plot(_hierarchy_trace(treemap, labels, parents; values = values, colorscale = colorscale, name = ""), Layout())
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_treemap!(fig, labels, parents; values=nothing, colorscale="", kwargs...)

Append a treemap trace to an existing figure.
"""
function plot_treemap!(
	fig,
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(_plot_data(fig), _hierarchy_trace(treemap, labels, parents; values = values, colorscale = colorscale, name = ""))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Funnel / Funnel-area ─────────────────────────────────────────────

"""
	plot_funnel(x, y; color="", legend="", kwargs...)

Funnel chart of stage values `x` against stage labels `y`.
"""
function plot_funnel(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	color::String = "",
	legend::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	kw = Dict{Symbol, Any}(:x => x, :y => y)
	color == "" || (kw[:marker] = attr(color = color))
	legend == "" || (kw[:name] = legend)
	fig = Plot(funnel(; kw...), Layout())
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_funnel!(fig, x, y; color="", legend="", kwargs...)

Append a funnel trace to an existing figure.
"""
function plot_funnel!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	color::String = "",
	legend::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	kw = Dict{Symbol, Any}(:x => x, :y => y)
	color == "" || (kw[:marker] = attr(color = color))
	legend == "" || (kw[:name] = legend)
	push!(_plot_data(fig), funnel(; kw...))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_funnelarea(values; labels=nothing, colors=String[], kwargs...)

Funnel-area chart of `values` with optional `labels`.
"""
function plot_funnelarea(
	values::Union{AbstractVector, AbstractRange};
	labels::Union{Nothing, AbstractVector} = nothing,
	colors::Vector{String} = String[],
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	kw = Dict{Symbol, Any}(:values => collect(values))
	labels === nothing || (kw[:labels] = collect(labels))
	isempty(colors) || (kw[:marker] = attr(colors = colors))
	fig = Plot(funnelarea(; kw...), Layout())
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_funnelarea!(fig, values; labels=nothing, colors=String[], kwargs...)

Append a funnel-area trace to an existing figure.
"""
function plot_funnelarea!(
	fig,
	values::Union{AbstractVector, AbstractRange};
	labels::Union{Nothing, AbstractVector} = nothing,
	colors::Vector{String} = String[],
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	kw = Dict{Symbol, Any}(:values => collect(values))
	labels === nothing || (kw[:labels] = collect(labels))
	isempty(colors) || (kw[:marker] = attr(colors = colors))
	push!(_plot_data(fig), funnelarea(; kw...))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Waterfall ────────────────────────────────────────────────────────

function _waterfall_trace(x, y; measure, legend::String)
	kw = Dict{Symbol, Any}(:x => x, :y => y)
	if measure !== nothing
		length(measure) == length(y) ||
			throw(ArgumentError("`measure` must match `y` in length; got $(length(measure)) and $(length(y))."))
		kw[:measure] = collect(measure)
	end
	legend == "" || (kw[:name] = legend)
	return waterfall(; kw...)
end

"""
	plot_waterfall(x, y; measure=nothing, legend="", kwargs...)

Waterfall chart. `measure[i]` is one of `"relative"`, `"total"`, or
`"absolute"` (defaults to all-relative when omitted).
"""
function plot_waterfall(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	measure::Union{Nothing, AbstractVector} = nothing,
	legend::String = "",
	xlabel::String = "",
	ylabel::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	grid::Bool = true,
	show::Bool = false,
)
	fig = Plot(_waterfall_trace(x, y; measure = measure, legend = legend),
		_default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
	_apply_cartesian_plot_options!(fig; xlabel = xlabel, ylabel = ylabel, width = width, height = height,
		grid = grid, fontsize = fontsize, title = title)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_waterfall!(fig, x, y; measure=nothing, legend="", kwargs...)

Append a waterfall trace to an existing figure.
"""
function plot_waterfall!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	measure::Union{Nothing, AbstractVector} = nothing,
	legend::String = "",
	xlabel::String = "",
	ylabel::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	grid::Bool = true,
)
	push!(_plot_data(fig), _waterfall_trace(x, y; measure = measure, legend = legend))
	_apply_cartesian_plot_options!(fig; xlabel = xlabel, ylabel = ylabel, width = width, height = height,
		grid = grid, fontsize = fontsize, title = title, refresh = true, apply_template = false)
	return nothing
end

# ── Indicator (number / gauge / delta) ───────────────────────────────

function _indicator_trace(value; mode::String, reference, gauge_range, gauge_shape::String, number_suffix::String)
	kw = Dict{Symbol, Any}(:mode => mode, :value => value)
	if reference !== nothing
		kw[:delta] = attr(reference = reference)
	end
	if gauge_range !== nothing
		kw[:gauge] = attr(shape = gauge_shape, axis = attr(range = collect(gauge_range)))
	end
	number_suffix == "" || (kw[:number] = attr(suffix = number_suffix))
	return indicator(; kw...)
end

"""
	plot_indicator(value; mode="number+delta", reference=nothing, gauge_range=nothing, gauge_shape="angular", number_suffix="", kwargs...)

KPI indicator showing a big `value`. Add a delta with `reference`, and a gauge
with `gauge_range=[lo,hi]` (`gauge_shape` is `"angular"` or `"bullet"`). `mode`
combines `"number"`, `"delta"`, and `"gauge"` with `+`.
"""
function plot_indicator(
	value::Real;
	mode::String = "number+delta",
	reference::Union{Nothing, Real} = nothing,
	gauge_range::Union{Nothing, AbstractVector} = nothing,
	gauge_shape::String = "angular",
	number_suffix::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	m = gauge_range !== nothing && !occursin("gauge", mode) ? mode * "+gauge" : mode
	fig = Plot(_indicator_trace(value; mode = m, reference = reference, gauge_range = gauge_range,
		gauge_shape = gauge_shape, number_suffix = number_suffix), Layout())
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_indicator!(fig, value; kwargs...)

Append an indicator trace to an existing figure (see [`plot_indicator`](@ref)).
"""
function plot_indicator!(
	fig,
	value::Real;
	mode::String = "number+delta",
	reference::Union{Nothing, Real} = nothing,
	gauge_range::Union{Nothing, AbstractVector} = nothing,
	gauge_shape::String = "angular",
	number_suffix::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	m = gauge_range !== nothing && !occursin("gauge", mode) ? mode * "+gauge" : mode
	push!(_plot_data(fig), _indicator_trace(value; mode = m, reference = reference, gauge_range = gauge_range,
		gauge_shape = gauge_shape, number_suffix = number_suffix))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Area (filled scatter) ────────────────────────────────────────────

function _area_traces(x, y; color, legend, mode::String, stack::Bool)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		x_nested = isa(x, Vector) && eltype(x) <: Vector
		traces = Vector{GenericTrace}(undef, length(y))
		for n in eachindex(y)
			xn = x_nested ? x[n] : x
			kw = Dict{Symbol, Any}(:x => xn, :y => y[n], :mode => mode, :name => legendV[n])
			colorV[n] == "" || (kw[:line] = attr(color = colorV[n]))
			stack ? (kw[:stackgroup] = "one") : (kw[:fill] = "tozeroy")
			traces[n] = scatter(; kw...)
		end
		return traces
	end
	kw = Dict{Symbol, Any}(:x => x, :y => y, :mode => mode, :fill => "tozeroy", :name => _first_or_empty(legend))
	c = _first_or_empty(color)
	c == "" || (kw[:line] = attr(color = c))
	return scatter(; kw...)
end

"""
	plot_area(x, y; color="", legend="", mode="lines", stack=false, kwargs...)
	plot_area(y; ...)

Filled-area line plot. With a `Vector` of `Vector`s for `y`, pass `stack=true`
to stack the series (Plotly `stackgroup`), otherwise each is filled to zero.
"""
function plot_area(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	mode::String = "lines",
	stack::Bool = false,
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	grid::Bool = true,
	show::Bool = false,
)
	trace = _area_traces(x, y; color = color, legend = legend, mode = mode, stack = stack)
	fig = Plot(trace, _default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel,
		x_tick0 = _safe_tick0(x), y_tick0 = _safe_tick0(y)))
	_apply_cartesian_plot_options!(fig; xlabel = xlabel, ylabel = ylabel, xrange = xrange, yrange = yrange,
		width = width, height = height, grid = grid, fontsize = fontsize, title = title)
	return _maybe_show(fig, show, width, height, title)
end

plot_area(y::Union{AbstractRange, Vector, SubArray}; kwargs...) = plot_area(_auto_xvalues(y), y; kwargs...)

"""
	plot_area!(fig, x, y; kwargs...)
	plot_area!(fig, y; ...)

Append filled-area trace(s) to an existing figure.
"""
function plot_area!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	mode::String = "lines",
	stack::Bool = false,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	trace = _area_traces(x, y; color = color, legend = legend, mode = mode, stack = stack)
	for t in (trace isa AbstractVector ? trace : [trace])
		push!(_plot_data(fig), t)
	end
	_apply_cartesian_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize,
		refresh = true, apply_template = false)
	return nothing
end

plot_area!(fig, y::Union{AbstractRange, Vector, SubArray}; kwargs...) = plot_area!(fig, _auto_xvalues(y), y; kwargs...)

# ── Candlestick / OHLC ───────────────────────────────────────────────

function _ohlc_trace(constructor, x, o, h, l, c; increasing_color::String, decreasing_color::String, legend::String)
	length(x) == length(o) == length(h) == length(l) == length(c) ||
		throw(ArgumentError("candlestick/ohlc: x, open, high, low, close must share length; got $(length(x)), $(length(o)), $(length(h)), $(length(l)), $(length(c))."))
	kw = Dict{Symbol, Any}(:x => x, :open => o, :high => h, :low => l, :close => c)
	increasing_color == "" || (kw[:increasing] = attr(line = attr(color = increasing_color)))
	decreasing_color == "" || (kw[:decreasing] = attr(line = attr(color = decreasing_color)))
	legend == "" || (kw[:name] = legend)
	return constructor(; kw...)
end

for (fn, fn!, ctor, label) in (
	(:plot_candlestick, :plot_candlestick!, :candlestick, "candlestick"),
	(:plot_ohlc, :plot_ohlc!, :ohlc, "OHLC"),
)
	@eval begin
		"""
			$($(string(fn)))(x, open, high, low, close; increasing_color="", decreasing_color="", legend="", kwargs...)

		$($label) financial chart over positions/dates `x`.
		"""
		function $fn(
			x::Union{AbstractRange, Vector, SubArray},
			open::Union{AbstractRange, Vector, SubArray},
			high::Union{AbstractRange, Vector, SubArray},
			low::Union{AbstractRange, Vector, SubArray},
			close::Union{AbstractRange, Vector, SubArray};
			increasing_color::String = "",
			decreasing_color::String = "",
			legend::String = "",
			xlabel::String = "",
			ylabel::String = "",
			title::String = "",
			width::Int = 0,
			height::Int = 0,
			fontsize::Int = 0,
			grid::Bool = true,
			show::Bool = false,
		)
			trace = _ohlc_trace($ctor, x, open, high, low, close;
				increasing_color = increasing_color, decreasing_color = decreasing_color, legend = legend)
			fig = Plot(trace, _default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
			_apply_cartesian_plot_options!(fig; xlabel = xlabel, ylabel = ylabel, width = width, height = height,
				grid = grid, fontsize = fontsize, title = title)
			return _maybe_show(fig, show, width, height, title)
		end

		"""
			$($(string(fn!)))(fig, x, open, high, low, close; kwargs...)

		Append a $($label) trace to an existing figure.
		"""
		function $fn!(
			fig,
			x::Union{AbstractRange, Vector, SubArray},
			open::Union{AbstractRange, Vector, SubArray},
			high::Union{AbstractRange, Vector, SubArray},
			low::Union{AbstractRange, Vector, SubArray},
			close::Union{AbstractRange, Vector, SubArray};
			increasing_color::String = "",
			decreasing_color::String = "",
			legend::String = "",
			title::String = "",
			width::Int = 0,
			height::Int = 0,
			fontsize::Int = 0,
		)
			push!(_plot_data(fig), _ohlc_trace($ctor, x, open, high, low, close;
				increasing_color = increasing_color, decreasing_color = decreasing_color, legend = legend))
			_apply_cartesian_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize,
				refresh = true, apply_template = false)
			return nothing
		end
	end
end

# ── 2D histogram (density) ───────────────────────────────────────────

function _histogram2d_trace(x, y; nbinsx::Int, nbinsy::Int, colorscale::String, histnorm::String)
	kw = Dict{Symbol, Any}(:x => x, :y => y)
	nbinsx > 0 && (kw[:nbinsx] = nbinsx)
	nbinsy > 0 && (kw[:nbinsy] = nbinsy)
	colorscale == "" || (kw[:colorscale] = colorscale)
	histnorm == "" || (kw[:histnorm] = histnorm)
	return histogram2d(; kw...)
end

"""
	plot_histogram2d(x, y; nbinsx=0, nbinsy=0, colorscale="", histnorm="", kwargs...)

2-D histogram (density heatmap) of paired samples `x`, `y`.
"""
function plot_histogram2d(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	nbinsx::Int = 0,
	nbinsy::Int = 0,
	colorscale::String = "",
	histnorm::String = "",
	xlabel::String = "",
	ylabel::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	grid::Bool = true,
	show::Bool = false,
)
	fig = Plot(_histogram2d_trace(x, y; nbinsx = nbinsx, nbinsy = nbinsy, colorscale = colorscale, histnorm = histnorm),
		_default_cartesian_layout(title = title, xlabel = xlabel, ylabel = ylabel))
	_apply_cartesian_plot_options!(fig; xlabel = xlabel, ylabel = ylabel, width = width, height = height,
		grid = grid, fontsize = fontsize, title = title)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_histogram2d!(fig, x, y; kwargs...)

Append a 2-D histogram trace to an existing figure.
"""
function plot_histogram2d!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	nbinsx::Int = 0,
	nbinsy::Int = 0,
	colorscale::String = "",
	histnorm::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(_plot_data(fig), _histogram2d_trace(x, y; nbinsx = nbinsx, nbinsy = nbinsy, colorscale = colorscale, histnorm = histnorm))
	_apply_cartesian_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize,
		refresh = true, apply_template = false)
	return nothing
end

# ── Annotations ──────────────────────────────────────────────────────

"""
	annotate!(fig, x, y, text; showarrow=true, xref="x", yref="y", font_size=0, kwargs...)

Append a text annotation at data coordinates `(x, y)`. Extra `kwargs` are passed
through to the Plotly annotation (e.g. `arrowhead`, `ax`, `ay`, `bgcolor`).
Returns the figure.
"""
function annotate!(
	fig,
	x,
	y,
	text::AbstractString;
	showarrow::Bool = true,
	xref::String = "x",
	yref::String = "y",
	font_size::Int = 0,
	kwargs...,
)
	p = _plot_obj(fig)
	d = Dict{Symbol, Any}(:x => x, :y => y, :text => String(text), :showarrow => showarrow, :xref => xref, :yref => yref)
	font_size > 0 && (d[:font] = attr(size = font_size))
	for (k, v) in kwargs
		d[k] = v
	end
	existing = get(p.layout.fields, :annotations, nothing)
	anns = existing === nothing ? Any[] : collect(existing)
	push!(anns, attr(; d...))
	relayout!(fig, annotations = anns)
	_refresh!(fig)
	return fig
end

# ── Sankey ───────────────────────────────────────────────────────────

function _sankey_trace(source, target, value; label, node_color::Vector{String}, link_color::String)
	length(source) == length(target) == length(value) ||
		throw(ArgumentError("sankey: source, target, value must share length; got $(length(source)), $(length(target)), $(length(value))."))
	node = Dict{Symbol, Any}()
	label === nothing || (node[:label] = collect(label))
	isempty(node_color) || (node[:color] = node_color)
	link = Dict{Symbol, Any}(:source => collect(source), :target => collect(target), :value => collect(value))
	link_color == "" || (link[:color] = link_color)
	return sankey(node = attr(; node...), link = attr(; link...))
end

"""
	plot_sankey(source, target, value; label=nothing, node_color=String[], link_color="", kwargs...)

Sankey flow diagram. `source`/`target` are 0-based node indices and `value` the
flow magnitude of each link; `label` names the nodes.
"""
function plot_sankey(
	source::AbstractVector,
	target::AbstractVector,
	value::AbstractVector;
	label::Union{Nothing, AbstractVector} = nothing,
	node_color::Vector{String} = String[],
	link_color::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	fig = Plot(_sankey_trace(source, target, value; label = label, node_color = node_color, link_color = link_color), Layout())
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_sankey!(fig, source, target, value; kwargs...)

Append a Sankey trace to an existing figure.
"""
function plot_sankey!(
	fig,
	source::AbstractVector,
	target::AbstractVector,
	value::AbstractVector;
	label::Union{Nothing, AbstractVector} = nothing,
	node_color::Vector{String} = String[],
	link_color::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(_plot_data(fig), _sankey_trace(source, target, value; label = label, node_color = node_color, link_color = link_color))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Parallel coordinates ─────────────────────────────────────────────

function _parcoords_dim(d)
	d isa Pair && return attr(label = String(first(d)), values = collect(last(d)))
	d isa PlotlyBase.PlotlyAttribute && return d
	throw(ArgumentError("each parcoords dimension must be a `\"label\" => values` Pair or an `attr(...)`."))
end

"""
	plot_parcoords(dimensions; line_color=nothing, colorscale="", kwargs...)

Parallel-coordinates plot. `dimensions` is a vector of `"label" => values`
pairs (or `attr(...)` dimensions). `line_color` (a per-row numeric vector) plus
`colorscale` color the lines.
"""
function plot_parcoords(
	dimensions::AbstractVector;
	line_color::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	kw = Dict{Symbol, Any}(:dimensions => [_parcoords_dim(d) for d in dimensions])
	if line_color !== nothing
		lc = Dict{Symbol, Any}(:color => collect(line_color))
		colorscale == "" || (lc[:colorscale] = colorscale)
		kw[:line] = attr(; lc...)
	end
	fig = Plot(parcoords(; kw...), Layout())
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_parcoords!(fig, dimensions; kwargs...)

Append a parallel-coordinates trace to an existing figure.
"""
function plot_parcoords!(
	fig,
	dimensions::AbstractVector;
	line_color::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	kw = Dict{Symbol, Any}(:dimensions => [_parcoords_dim(d) for d in dimensions])
	if line_color !== nothing
		lc = Dict{Symbol, Any}(:color => collect(line_color))
		colorscale == "" || (lc[:colorscale] = colorscale)
		kw[:line] = attr(; lc...)
	end
	push!(_plot_data(fig), parcoords(; kw...))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Ternary scatter ──────────────────────────────────────────────────

function _ternary_trace(a, b, c; mode::String, color::String, legend::String, marker_size::Int)
	kw = Dict{Symbol, Any}(:a => a, :b => b, :c => c, :mode => mode)
	mk = Dict{Symbol, Any}()
	color == "" || (mk[:color] = color)
	marker_size > 0 && (mk[:size] = marker_size)
	isempty(mk) || (kw[:marker] = attr(; mk...))
	legend == "" || (kw[:name] = legend)
	return scatterternary(; kw...)
end

function _ternary_layout(title, alabel, blabel, clabel)
	tern = Dict{Symbol, Any}()
	alabel == "" || (tern[:aaxis] = attr(title = alabel))
	blabel == "" || (tern[:baxis] = attr(title = blabel))
	clabel == "" || (tern[:caxis] = attr(title = clabel))
	return isempty(tern) ? Layout(title = title) : Layout(title = title, ternary = attr(; tern...))
end

"""
	plot_ternary(a, b, c; mode="markers", color="", legend="", marker_size=0, alabel="", blabel="", clabel="", kwargs...)

Ternary scatter plot of three-component compositions `(a, b, c)`.
"""
function plot_ternary(
	a::Union{AbstractRange, Vector, SubArray},
	b::Union{AbstractRange, Vector, SubArray},
	c::Union{AbstractRange, Vector, SubArray};
	mode::String = "markers",
	color::String = "",
	legend::String = "",
	marker_size::Int = 0,
	alabel::String = "",
	blabel::String = "",
	clabel::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	fig = Plot(_ternary_trace(a, b, c; mode = mode, color = color, legend = legend, marker_size = marker_size),
		_ternary_layout(title, alabel, blabel, clabel))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_ternary!(fig, a, b, c; kwargs...)

Append a ternary scatter trace to an existing figure.
"""
function plot_ternary!(
	fig,
	a::Union{AbstractRange, Vector, SubArray},
	b::Union{AbstractRange, Vector, SubArray},
	c::Union{AbstractRange, Vector, SubArray};
	mode::String = "markers",
	color::String = "",
	legend::String = "",
	marker_size::Int = 0,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(_plot_data(fig), _ternary_trace(a, b, c; mode = mode, color = color, legend = legend, marker_size = marker_size))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Image ────────────────────────────────────────────────────────────

# Convert an H×W×C numeric array to the nested [[[c…]…]…] form Plotly expects;
# pass an already-nested z through unchanged.
function _image_z(z)
	ndims(z) == 3 || return z
	return [[[z[i, j, ch] for ch in axes(z, 3)] for j in axes(z, 2)] for i in axes(z, 1)]
end

"""
	plot_image(z; colormodel="", kwargs...)

Display image data `z` — either an `H×W×C` numeric array (C = 3 RGB or 4 RGBA)
or an already-nested `[[[channels…]…]…]`. `colormodel` overrides the channel
interpretation (e.g. `"rgb"`, `"rgba"`, `"hsl"`).
"""
function plot_image(
	z::AbstractArray;
	colormodel::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	kw = Dict{Symbol, Any}(:z => _image_z(z))
	colormodel == "" || (kw[:colormodel] = colormodel)
	fig = Plot(image(; kw...),
		Layout(yaxis = attr(scaleanchor = "x", constrain = "domain"), xaxis = attr(constrain = "domain")))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_image!(fig, z; colormodel="", kwargs...)

Append an image trace to an existing figure.
"""
function plot_image!(
	fig,
	z::AbstractArray;
	colormodel::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	kw = Dict{Symbol, Any}(:z => _image_z(z))
	colormodel == "" || (kw[:colormodel] = colormodel)
	push!(_plot_data(fig), image(; kw...))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── 3D volumetric / mesh charts ──────────────────────────────────────

# Shared 3D scene post-processing (projection, ranges, grid/axis visibility,
# template/legend, font), mirroring the core 3D constructors.
function _apply_scene_options!(
	fig;
	xrange, yrange, zrange,
	width::Int, height::Int, perspective::Bool, grid::Bool, showaxis::Bool,
	fontsize::Int, apply_template::Bool,
)
	perspective || relayout!(fig, scene = attr(camera = attr(projection = attr(type = "orthographic"))))
	_apply_scene_ranges!(fig; xrange = xrange, yrange = yrange, zrange = zrange)
	width > 0 && relayout!(fig, width = width)
	height > 0 && relayout!(fig, height = height)
	grid || relayout!(fig, scene = attr(xaxis = attr(showgrid = false), yaxis = attr(showgrid = false), zaxis = attr(showgrid = false)))
	showaxis || relayout!(fig, scene = attr(xaxis = attr(visible = false), yaxis = attr(visible = false), zaxis = attr(visible = false)))
	apply_template ? _apply_default_template!(fig) : _apply_default_legend!(fig)
	fontsize > 0 && relayout!(fig, font = attr(size = fontsize))
	return nothing
end

function _mesh3d_trace(x, y, z; i, j, k, intensity, color::String, colorscale::String, opacity::Real)
	kw = Dict{Symbol, Any}(:x => x, :y => y, :z => z)
	if i !== nothing && j !== nothing && k !== nothing
		kw[:i] = i
		kw[:j] = j
		kw[:k] = k
	end
	intensity === nothing || (kw[:intensity] = collect(intensity))
	color == "" || (kw[:color] = color)
	colorscale == "" || (kw[:colorscale] = colorscale)
	opacity < 1 && (kw[:opacity] = opacity)
	return mesh3d(; kw...)
end

"""
	plot_mesh3d(x, y, z; i=nothing, j=nothing, k=nothing, intensity=nothing, color="", colorscale="", opacity=1, kwargs...)

3D triangular mesh through points `(x, y, z)`. Supply explicit triangle vertex
indices via `i`/`j`/`k` (0-based), or omit them for automatic triangulation.
Color with a uniform `color`, or per-vertex `intensity` + `colorscale`.
"""
function plot_mesh3d(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray};
	i = nothing, j = nothing, k = nothing,
	intensity::Union{Nothing, AbstractVector} = nothing,
	color::String = "",
	colorscale::String = "",
	opacity::Real = 1,
	xrange::Vector = [0, 0], yrange::Vector = [0, 0], zrange::Vector = [0, 0],
	xlabel::String = "", ylabel::String = "", zlabel::String = "",
	aspectmode::String = "auto", title::String = "", width::Int = 0, height::Int = 0,
	fontsize::Int = 0, perspective::Bool = true, grid::Bool = true, showaxis::Bool = true, show::Bool = false,
)
	fig = Plot(_mesh3d_trace(x, y, z; i = i, j = j, k = k, intensity = intensity, color = color, colorscale = colorscale, opacity = opacity),
		_scene_layout(title = title, xlabel = xlabel, ylabel = ylabel, zlabel = zlabel, aspectmode = aspectmode))
	_apply_scene_options!(fig; xrange = xrange, yrange = yrange, zrange = zrange, width = width, height = height,
		perspective = perspective, grid = grid, showaxis = showaxis, fontsize = fontsize, apply_template = true)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_mesh3d!(fig, x, y, z; kwargs...)

Append a 3D mesh trace to an existing figure.
"""
function plot_mesh3d!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray};
	i = nothing, j = nothing, k = nothing,
	intensity::Union{Nothing, AbstractVector} = nothing,
	color::String = "", colorscale::String = "", opacity::Real = 1,
	xrange::Vector = [0, 0], yrange::Vector = [0, 0], zrange::Vector = [0, 0],
	width::Int = 0, height::Int = 0, fontsize::Int = 0,
	perspective::Bool = true, grid::Bool = true, showaxis::Bool = true,
)
	push!(_plot_data(fig), _mesh3d_trace(x, y, z; i = i, j = j, k = k, intensity = intensity, color = color, colorscale = colorscale, opacity = opacity))
	_apply_scene_options!(fig; xrange = xrange, yrange = yrange, zrange = zrange, width = width, height = height,
		perspective = perspective, grid = grid, showaxis = showaxis, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

function _field3d_trace(constructor, x, y, z, value; isomin, isomax, surface_count::Int, colorscale::String, opacity::Real)
	kw = Dict{Symbol, Any}(:x => x, :y => y, :z => z, :value => collect(value))
	isomin === nothing || (kw[:isomin] = isomin)
	isomax === nothing || (kw[:isomax] = isomax)
	surface_count > 0 && (kw[:surface_count] = surface_count)
	colorscale == "" || (kw[:colorscale] = colorscale)
	opacity < 1 && (kw[:opacity] = opacity)
	return constructor(; kw...)
end

for (fn, fn!, ctor, label, defop) in (
	(:plot_isosurface, :plot_isosurface!, :isosurface, "isosurface", 1.0),
	(:plot_volume, :plot_volume!, :volume, "volume", 0.1),
)
	@eval begin
		"""
			$($(string(fn)))(x, y, z, value; isomin=nothing, isomax=nothing, surface_count=0, colorscale="", opacity=$($defop), kwargs...)

		3D $($label) of a scalar field `value` sampled at points `(x, y, z)`.
		`isomin`/`isomax` bound the rendered iso-levels and `surface_count` sets
		how many are drawn.
		"""
		function $fn(
			x::Union{AbstractRange, Vector, SubArray},
			y::Union{AbstractRange, Vector, SubArray},
			z::Union{AbstractRange, Vector, SubArray},
			value::Union{AbstractRange, Vector, SubArray};
			isomin::Union{Nothing, Real} = nothing, isomax::Union{Nothing, Real} = nothing,
			surface_count::Int = 0, colorscale::String = "", opacity::Real = $defop,
			xrange::Vector = [0, 0], yrange::Vector = [0, 0], zrange::Vector = [0, 0],
			xlabel::String = "", ylabel::String = "", zlabel::String = "",
			aspectmode::String = "auto", title::String = "", width::Int = 0, height::Int = 0,
			fontsize::Int = 0, perspective::Bool = true, grid::Bool = true, showaxis::Bool = true, show::Bool = false,
		)
			fig = Plot(_field3d_trace($ctor, x, y, z, value; isomin = isomin, isomax = isomax,
				surface_count = surface_count, colorscale = colorscale, opacity = opacity),
				_scene_layout(title = title, xlabel = xlabel, ylabel = ylabel, zlabel = zlabel, aspectmode = aspectmode))
			_apply_scene_options!(fig; xrange = xrange, yrange = yrange, zrange = zrange, width = width, height = height,
				perspective = perspective, grid = grid, showaxis = showaxis, fontsize = fontsize, apply_template = true)
			return _maybe_show(fig, show, width, height, title)
		end

		"""
			$($(string(fn!)))(fig, x, y, z, value; kwargs...)

		Append a 3D $($label) trace to an existing figure.
		"""
		function $fn!(
			fig,
			x::Union{AbstractRange, Vector, SubArray},
			y::Union{AbstractRange, Vector, SubArray},
			z::Union{AbstractRange, Vector, SubArray},
			value::Union{AbstractRange, Vector, SubArray};
			isomin::Union{Nothing, Real} = nothing, isomax::Union{Nothing, Real} = nothing,
			surface_count::Int = 0, colorscale::String = "", opacity::Real = $defop,
			xrange::Vector = [0, 0], yrange::Vector = [0, 0], zrange::Vector = [0, 0],
			width::Int = 0, height::Int = 0, fontsize::Int = 0,
			perspective::Bool = true, grid::Bool = true, showaxis::Bool = true,
		)
			push!(_plot_data(fig), _field3d_trace($ctor, x, y, z, value; isomin = isomin, isomax = isomax,
				surface_count = surface_count, colorscale = colorscale, opacity = opacity))
			_apply_scene_options!(fig; xrange = xrange, yrange = yrange, zrange = zrange, width = width, height = height,
				perspective = perspective, grid = grid, showaxis = showaxis, fontsize = fontsize, apply_template = false)
			_refresh!(fig)
			return nothing
		end
	end
end

function _streamtube_trace(x, y, z, u, v, w; sizeref::Real, colorscale::String)
	kw = Dict{Symbol, Any}(:x => x, :y => y, :z => z, :u => u, :v => v, :w => w)
	sizeref > 0 && (kw[:sizeref] = sizeref)
	colorscale == "" || (kw[:colorscale] = colorscale)
	return streamtube(; kw...)
end

"""
	plot_streamtube(x, y, z, u, v, w; sizeref=0, colorscale="", kwargs...)

3D streamtube visualization of a vector field `(u, v, w)` at points `(x, y, z)`.
"""
function plot_streamtube(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray},
	w::Union{AbstractRange, Vector, SubArray};
	sizeref::Real = 0, colorscale::String = "",
	xrange::Vector = [0, 0], yrange::Vector = [0, 0], zrange::Vector = [0, 0],
	xlabel::String = "", ylabel::String = "", zlabel::String = "",
	aspectmode::String = "auto", title::String = "", width::Int = 0, height::Int = 0,
	fontsize::Int = 0, perspective::Bool = true, grid::Bool = true, showaxis::Bool = true, show::Bool = false,
)
	fig = Plot(_streamtube_trace(x, y, z, u, v, w; sizeref = sizeref, colorscale = colorscale),
		_scene_layout(title = title, xlabel = xlabel, ylabel = ylabel, zlabel = zlabel, aspectmode = aspectmode))
	_apply_scene_options!(fig; xrange = xrange, yrange = yrange, zrange = zrange, width = width, height = height,
		perspective = perspective, grid = grid, showaxis = showaxis, fontsize = fontsize, apply_template = true)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_streamtube!(fig, x, y, z, u, v, w; kwargs...)

Append a streamtube trace to an existing figure.
"""
function plot_streamtube!(
	fig,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray},
	w::Union{AbstractRange, Vector, SubArray};
	sizeref::Real = 0, colorscale::String = "",
	xrange::Vector = [0, 0], yrange::Vector = [0, 0], zrange::Vector = [0, 0],
	width::Int = 0, height::Int = 0, fontsize::Int = 0,
	perspective::Bool = true, grid::Bool = true, showaxis::Bool = true,
)
	push!(_plot_data(fig), _streamtube_trace(x, y, z, u, v, w; sizeref = sizeref, colorscale = colorscale))
	_apply_scene_options!(fig; xrange = xrange, yrange = yrange, zrange = zrange, width = width, height = height,
		perspective = perspective, grid = grid, showaxis = showaxis, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Geographic maps ──────────────────────────────────────────────────

function _geo_layout(title::String, scope::String, projection::String)
	g = Dict{Symbol, Any}()
	scope == "" || (g[:scope] = scope)
	projection == "" || (g[:projection] = attr(type = projection))
	return isempty(g) ? Layout(title = title) : Layout(title = title, geo = attr(; g...))
end

function _mapbox_layout(title::String, style::String, zoom::Real, center_lon, center_lat)
	m = Dict{Symbol, Any}(:style => style)
	zoom > 0 && (m[:zoom] = zoom)
	if center_lon !== nothing && center_lat !== nothing
		m[:center] = attr(lon = center_lon, lat = center_lat)
	end
	return Layout(title = title, mapbox = attr(; m...))
end

"""
	plot_choropleth(locations, z; locationmode="country names", colorscale="", scope="", projection="", kwargs...)

Choropleth map shading regions `locations` by value `z`. `locationmode` selects
how `locations` are matched (e.g. `"country names"`, `"ISO-3"`, `"USA-states"`).
"""
function plot_choropleth(
	locations::AbstractVector,
	z::AbstractVector;
	locationmode::String = "country names",
	colorscale::String = "",
	scope::String = "",
	projection::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	length(locations) == length(z) ||
		throw(ArgumentError("choropleth: locations and z must share length; got $(length(locations)) and $(length(z))."))
	kw = Dict{Symbol, Any}(:locations => collect(locations), :z => collect(z), :locationmode => locationmode)
	colorscale == "" || (kw[:colorscale] = colorscale)
	fig = Plot(choropleth(; kw...), _geo_layout(title, scope, projection))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_choropleth!(fig, locations, z; kwargs...)

Append a choropleth trace to an existing figure.
"""
function plot_choropleth!(
	fig,
	locations::AbstractVector,
	z::AbstractVector;
	locationmode::String = "country names",
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	kw = Dict{Symbol, Any}(:locations => collect(locations), :z => collect(z), :locationmode => locationmode)
	colorscale == "" || (kw[:colorscale] = colorscale)
	push!(_plot_data(fig), choropleth(; kw...))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_scattergeo(lon, lat; mode="markers", color="", marker_size=0, legend="", scope="", projection="", kwargs...)

Scatter points on a geographic map at coordinates `(lon, lat)` (degrees).
"""
function plot_scattergeo(
	lon::AbstractVector,
	lat::AbstractVector;
	mode::String = "markers",
	color::String = "",
	marker_size::Int = 0,
	legend::String = "",
	scope::String = "",
	projection::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	length(lon) == length(lat) ||
		throw(ArgumentError("scattergeo: lon and lat must share length; got $(length(lon)) and $(length(lat))."))
	kw = Dict{Symbol, Any}(:lon => collect(lon), :lat => collect(lat), :mode => mode)
	mk = Dict{Symbol, Any}()
	color == "" || (mk[:color] = color)
	marker_size > 0 && (mk[:size] = marker_size)
	isempty(mk) || (kw[:marker] = attr(; mk...))
	legend == "" || (kw[:name] = legend)
	fig = Plot(scattergeo(; kw...), _geo_layout(title, scope, projection))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_scattergeo!(fig, lon, lat; kwargs...)

Append a scattergeo trace to an existing figure.
"""
function plot_scattergeo!(
	fig,
	lon::AbstractVector,
	lat::AbstractVector;
	mode::String = "markers",
	color::String = "",
	marker_size::Int = 0,
	legend::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	kw = Dict{Symbol, Any}(:lon => collect(lon), :lat => collect(lat), :mode => mode)
	mk = Dict{Symbol, Any}()
	color == "" || (mk[:color] = color)
	marker_size > 0 && (mk[:size] = marker_size)
	isempty(mk) || (kw[:marker] = attr(; mk...))
	legend == "" || (kw[:name] = legend)
	push!(_plot_data(fig), scattergeo(; kw...))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_scattermapbox(lon, lat; mode="markers", color="", marker_size=0, legend="", style="open-street-map", zoom=0, center_lon=nothing, center_lat=nothing, kwargs...)

Scatter points on a tile map at `(lon, lat)`. The default `"open-street-map"`
style needs no access token.
"""
function plot_scattermapbox(
	lon::AbstractVector,
	lat::AbstractVector;
	mode::String = "markers",
	color::String = "",
	marker_size::Int = 0,
	legend::String = "",
	style::String = "open-street-map",
	zoom::Real = 0,
	center_lon::Union{Nothing, Real} = nothing,
	center_lat::Union{Nothing, Real} = nothing,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	length(lon) == length(lat) ||
		throw(ArgumentError("scattermapbox: lon and lat must share length; got $(length(lon)) and $(length(lat))."))
	kw = Dict{Symbol, Any}(:lon => collect(lon), :lat => collect(lat), :mode => mode)
	mk = Dict{Symbol, Any}()
	color == "" || (mk[:color] = color)
	marker_size > 0 && (mk[:size] = marker_size)
	isempty(mk) || (kw[:marker] = attr(; mk...))
	legend == "" || (kw[:name] = legend)
	fig = Plot(scattermapbox(; kw...), _mapbox_layout(title, style, zoom, center_lon, center_lat))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_scattermapbox!(fig, lon, lat; kwargs...)

Append a scattermapbox trace to an existing figure.
"""
function plot_scattermapbox!(
	fig,
	lon::AbstractVector,
	lat::AbstractVector;
	mode::String = "markers",
	color::String = "",
	marker_size::Int = 0,
	legend::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	kw = Dict{Symbol, Any}(:lon => collect(lon), :lat => collect(lat), :mode => mode)
	mk = Dict{Symbol, Any}()
	color == "" || (mk[:color] = color)
	marker_size > 0 && (mk[:size] = marker_size)
	isempty(mk) || (kw[:marker] = attr(; mk...))
	legend == "" || (kw[:name] = legend)
	push!(_plot_data(fig), scattermapbox(; kw...))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_densitymapbox(lon, lat, z; radius=0, colorscale="", style="open-street-map", zoom=0, center_lon=nothing, center_lat=nothing, kwargs...)

Density heatmap on a tile map from weighted points `(lon, lat, z)`. `radius`
sets the influence (in pixels) of each point.
"""
function plot_densitymapbox(
	lon::AbstractVector,
	lat::AbstractVector,
	z::AbstractVector;
	radius::Real = 0,
	colorscale::String = "",
	style::String = "open-street-map",
	zoom::Real = 0,
	center_lon::Union{Nothing, Real} = nothing,
	center_lat::Union{Nothing, Real} = nothing,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	length(lon) == length(lat) == length(z) ||
		throw(ArgumentError("densitymapbox: lon, lat, z must share length; got $(length(lon)), $(length(lat)), $(length(z))."))
	kw = Dict{Symbol, Any}(:lon => collect(lon), :lat => collect(lat), :z => collect(z))
	radius > 0 && (kw[:radius] = radius)
	colorscale == "" || (kw[:colorscale] = colorscale)
	fig = Plot(densitymapbox(; kw...), _mapbox_layout(title, style, zoom, center_lon, center_lat))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_densitymapbox!(fig, lon, lat, z; kwargs...)

Append a densitymapbox trace to an existing figure.
"""
function plot_densitymapbox!(
	fig,
	lon::AbstractVector,
	lat::AbstractVector,
	z::AbstractVector;
	radius::Real = 0,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	kw = Dict{Symbol, Any}(:lon => collect(lon), :lat => collect(lat), :z => collect(z))
	radius > 0 && (kw[:radius] = radius)
	colorscale == "" || (kw[:colorscale] = colorscale)
	push!(_plot_data(fig), densitymapbox(; kw...))
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

#endregion
