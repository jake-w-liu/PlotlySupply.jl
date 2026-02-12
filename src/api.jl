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

function _finalize_plot(fig::Plot; width::Int = 0, height::Int = 0, title::String = "")
	window_width = width > 0 ? width : 960
	window_height = height > 0 ? height : 720
	window_title = title == "" ? "PlotlySupply" : title
	return to_syncplot(fig; width = window_width, height = window_height, title = window_title)
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
	return template_sym in _VALID_TEMPLATES ? template_sym : :plotly_white
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
	return pos in _VALID_LEGEND_POSITIONS ? pos : :topright
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

Set the package-wide default legend position.
Accepted symbols include `:topright`, `:top`, `:topleft`, `:right`,
`:center`, `:left`, `:bottomright`, `:bottom`, and `:bottomleft`.
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
	xoutside_right = xdom[2] + (xdom[2] - xdom[1]) * xpad
	xoutside_left = xdom[1] - (xdom[2] - xdom[1]) * xpad
	youtside_top = ydom[2] + (ydom[2] - ydom[1]) * ypad
	youtside_bottom = ydom[1] - (ydom[2] - ydom[1]) * ypad

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
)
	p = _plot_obj(fig)
	legend_position = _normalize_legend_position(position)
	legend_inset = (Float64(inset[1]), Float64(inset[2]))
	x, y, xanchor, yanchor = _legend_anchor((0.0, 1.0), (0.0, 1.0), legend_inset, legend_position)

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
	if !haskey(p.layout.fields, :showlegend) && any(_trace_will_showlegend(trace) for trace in p.data)
		p.layout.fields[:showlegend] = true
	end
	return p
end

"""
	set_legend!(fig; position=:topright, kwargs...)

Set legend placement and styling with simple position symbols such as
`:top`, `:topright`, `:left`, `:bottomleft`, or `:outside_right`.
"""
function set_legend!(
	fig::Union{Plot, SyncPlot};
	position::Union{Symbol, AbstractString} = get_default_legend_position(),
	inset::Tuple{<:Real, <:Real} = _DEFAULT_LEGEND_INSET[],
	bgcolor::String = _DEFAULT_LEGEND_BGCOLOR[],
	bordercolor::String = _DEFAULT_LEGEND_BORDERCOLOR[],
	borderwidth::Real = _DEFAULT_LEGEND_BORDERWIDTH[],
)
	_apply_default_legend!(
		fig;
		position = position,
		inset = inset,
		bgcolor = bgcolor,
		bordercolor = bordercolor,
		borderwidth = borderwidth,
		overwrite = true,
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
		plot(; layout = layout, width = width, height = height, title = title, show = show, app = app)
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

function _subplot_xy_axis_keys(sf::SubplotFigure, row::Int, col::Int)
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
		PlotlyBase.add_trace!(p, probe; row = row, col = col)
	catch err
		throw(ArgumentError("Selected subplot cell ($(row), $(col)) does not accept Cartesian x/y axes."))
	end
	fields = p.data[end].fields
	pop!(p.data)

	haskey(fields, :xaxis) || throw(ArgumentError("Selected subplot cell ($(row), $(col)) has no x-axis."))
	haskey(fields, :yaxis) || throw(ArgumentError("Selected subplot cell ($(row), $(col)) has no y-axis."))

	xkey = _axis_layout_key(String(fields[:xaxis]), :x)
	ykey = _axis_layout_key(String(fields[:yaxis]), :y)
	return xkey, ykey
end

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
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	_, ykey = _subplot_xy_axis_keys(sf, r, c)
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
)
	length(range) == 2 || throw(ArgumentError("`range` must have length 2."))
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	_, ykey = _subplot_xy_axis_keys(sf, r, c)
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
	refresh::Bool = false,
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
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	refresh && _refresh!(fig)
	return nothing
end

function _bar_trace(; x, y, color::String = "", name::String = "")
	if color == ""
		return bar(x = x, y = y, name = name)
	end
	return bar(x = x, y = y, name = name, marker = attr(color = color))
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
		:boxpoints => points,
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
		:points => points,
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
- `dash`: line style ("dash, "dashdot", or "dot", default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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
)
	if isa(y, Vector) && eltype(y) <: Vector
		trace = Vector{GenericTrace}(undef, length(y))
		modeV = fill("line", length(y))
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

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace[n] = scatter(
					y = y[n],
					x = x[n],
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
			end
		else
			for n in eachindex(y)
				trace[n] = scatter(
					y = y[n],
					x = x,
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
			end
		end
	else
		trace = scatter(y = y, x = x, mode = mode, line = attr(color = color, dash = dash), name = legend)
	end
	layout = _default_cartesian_layout(
		title = title,
		xlabel = xlabel,
		ylabel = ylabel,
		x_tick0 = minimum(x),
		y_tick0 = minimum(y),
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
	return _finalize_plot(fig; width = width, height = height, title = title)
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
- `dash`: line style ("dash, "dashdot", or "dot", default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: legend of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)
- `grid`: Whether to show the grid or not (default: true)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				# trace[n] = stem(
				# 	y = y[n],
				# 	x = x[n],
				# 	line = attr(color = colorV[n]),
				# 	name = legendV[n],
				# )
				trace[n] = scatter(
					y = y[n],
					x = x[n],
					line = attr(color = colorV[n]),
					name = legendV[n],
					mode = "markers",
				)
			end
		else
			for n in eachindex(y)
				# trace[n] = stem(
				# 	y = y[n],
				# 	x = x,
				# 	line = attr(color = colorV[n]),
				# 	name = legendV[n],
				# )
				trace[n] = scatter(
					y = y[n],
					x = x,
					line = attr(color = colorV[n]),
					name = legendV[n],
					mode = "markers",
				)
			end
		end
	else
		# trace = stem(y = y, x = x, line = attr(color = color), name = legend)
		trace = scatter(y = y, x = x, line = attr(color = color), name = legend, mode = "markers")
	end
	layout = _default_cartesian_layout(
		title = title,
		xlabel = xlabel,
		ylabel = ylabel,
		x_tick0 = minimum(x),
		y_tick0 = minimum(y),
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

	#exp
	if isa(y, Vector) && eltype(y) <: Vector
		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				for m in eachindex(y[n])
					# add_shape!(fig, line(
					# 	x0 = x[n][m], y0 = 0,
					# 	x1 = x[n][m], y1 = y[n][m],
					# 	line = attr(color = "black", width = 0.5),
					# )
					# )
					addtraces!(fig,
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
				for m in eachindex(y[n])
					# add_shape!(fig, line(
					# 	x0 = x[m], y0 = 0,
					# 	x1 = x[m], y1 = y[n][m],
					# 	line = attr(color = "black", width = 0.5),
					# )
					# )
					addtraces!(fig,
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
		for m in eachindex(y)
			# add_shape!(fig, line(
			# 	x0 = x[m], y0 = 0,
			# 	x1 = x[m], y1 = y[m],
			# 	line = attr(color = "black", width = 0.5),
			# )
			# )
			addtraces!(fig,
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
	return _finalize_plot(fig; width = width, height = height, title = title)
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
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: legend of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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
		)
end

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
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace[n] = _bar_trace(x = x[n], y = y[n], color = colorV[n], name = legendV[n])
			end
		else
			for n in eachindex(y)
				trace[n] = _bar_trace(x = x, y = y[n], color = colorV[n], name = legendV[n])
			end
		end
	else
		trace = _bar_trace(
			x = x,
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
		)
	end

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
	)
	return _finalize_plot(fig; width = width, height = height, title = title)
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
	)
end

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
	)
	return _finalize_plot(fig; width = width, height = height, title = title)
end

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
	)
	return _finalize_plot(fig; width = width, height = height, title = title)
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
	)
	return _finalize_plot(fig; width = width, height = height, title = title)
end

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
	)
	return _finalize_plot(fig; width = width, height = height, title = title)
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
	)
	return _finalize_plot(fig; width = width, height = height, title = title)
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
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
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
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: legend of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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
)
	if isa(r, Vector) && eltype(r) <: Vector
		trace = Vector{GenericTrace}(undef, length(r))
		modeV = fill("line", length(r))
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

		if isa(theta, Vector) && eltype(theta) <: Vector
			for n in eachindex(r)
				trace[n] = scatterpolar(
					r = r[n],
					theta = theta[n],
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
			end
		else
			for n in eachindex(r)
				trace[n] = scatterpolar(
					r = r[n],
					theta = theta,
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
			end
		end
	else
		trace = scatterpolar(
			r = r,
			theta = theta,
			mode = mode,
			line = attr(color = color, dash = dash),
			name = legend,
		)
	end

	layout = Layout(
		title = title,
		polar = attr(sector = [minimum(theta), maximum(theta)]),
	)
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
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return _finalize_plot(fig; width = width, height = height, title = title)
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
	)

Plots heatmap (holographic) data.

#### Arguments

- 'x::AbstractRange': x-axis range
- 'y::AbstractRange': x-axis range
- `U`: 2D hologram data

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the heatmap (default: `""`)
- `title`: Title of thje figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- 'equalar': Whether to set equal aspect ratio (default: false)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = heatmap(x = x, y = y, z = FV, colorscale = colorscale)
	if !all(zrange .== [0, 0])
		trace.zmin = zrange[1]
		trace.zmax = zrange[2]
	end
	if length(x) > 1
		dx = x[2] - x[1]
	else
		dx = 0
	end
	if length(y) > 1
		dy = y[2] - y[1]
	else
		dy = 0
	end
	if dx == 0 && dy != 0
		dx = dy
	elseif dy == 0 && dx != 0
		dy = dx
	end
	layout = Layout(
		title = title,
		scene = attr(aspectmode = "data"),
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
	return _finalize_plot(fig; width = width, height = height, title = title)
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
- `title`: Title of thje figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- 'equalar': Whether to set equal aspect ratio (default: false)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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
	)

Plots contour data.

#### Arguments

- 'x::AbstractRange': x-axis range
- 'y::AbstractRange': x-axis range
- `U`: 2D data for contours

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the contour plot (default: `""`)
- `title`: Title of thje figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- 'equalar': Whether to set equal aspect ratio (default: false)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = contour(x = x, y = y, z = FV, colorscale = colorscale)
	if !all(zrange .== [0, 0])
		trace.zmin = zrange[1]
		trace.zmax = zrange[2]
	end
	if length(x) > 1
		dx = x[2] - x[1]
	else
		dx = 0
	end
	if length(y) > 1
		dy = y[2] - y[1]
	else
		dy = 0
	end
	if dx == 0 && dy != 0
		dx = dy
	elseif dy == 0 && dx != 0
		dy = dx
	end
	layout = Layout(
		title = title,
		scene = attr(aspectmode = "data"),
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
	return _finalize_plot(fig; width = width, height = height, title = title)
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
- `title`: Title of thje figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- 'equalar': Whether to set equal aspect ratio (default: false)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

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
)
    x_vec = isa(x, AbstractRange) ? collect(x) : x
    y_vec = isa(y, AbstractRange) ? collect(y) : y
    u_vec = isa(u, AbstractRange) ? collect(u) : u
    v_vec = isa(v, AbstractRange) ? collect(v) : v

    p_max = maximum(sqrt.(u_vec .^ 2 .+ v_vec .^ 2))
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
        scene = attr(aspectmode = "data"),
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
    return _finalize_plot(fig; width = width, height = height, title = title)
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
)
	if isempty(surfacecolor)
		trace = surface(x = X, y = Y, z = Z, colorscale = colorscale)
	else
		trace = surface(x = X, y = Y, z = Z, surfacecolor = surfacecolor, colorscale = colorscale)
	end
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
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
	end
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
	return _finalize_plot(fig; width = width, height = height, title = title)
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
		for n in eachindex(y)
			trace[n] = scatter3d(
				y = y[n],
				x = x[n],
				z = z[n],
				mode = modeV[n],
				line = attr(color = colorV[n]),
				name = legendV[n],
			)
		end
	else
		trace = scatter3d(x = x, y = y, z = z, mode = mode, line = attr(color = color), name = legend)
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

	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
	end
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
	return _finalize_plot(fig; width = width, height = height, title = title)
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
		colorscale = colorscale,
	)
	if color != "" # use single color
		trace.colorscale = [[0, color], [1, color]]
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

	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
	end
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
	return _finalize_plot(fig; width = width, height = height, title = title)
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
)
	if isa(y, Vector) && eltype(y) <: Vector
		modeV = fill("line", length(y))
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

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace = scatter(
					y = y[n],
					x = x[n],
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
				push!(_plot_data(fig), trace)
			end
		else
			for n in eachindex(y)
				trace = scatter(
					y = y[n],
					x = x,
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
				push!(_plot_data(fig), trace)
			end
		end
	else
		trace = scatter(y = y, x = x, mode = mode, line = attr(color = color, dash = dash), name = legend)
		push!(_plot_data(fig), trace)
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
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
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

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace_stem = scatter(
					y = y[n],
					x = x[n],
					line = attr(color = colorV[n]),
					name = legendV[n],
					mode = "markers",
				)
				push!(_plot_data(fig), trace_stem)
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
				trace_stem = scatter(
					y = y[n],
					x = x,
					line = attr(color = colorV[n]),
					name = legendV[n],
					mode = "markers",
				)
				push!(_plot_data(fig), trace_stem)
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
		trace_stem = scatter(y = y, x = x, line = attr(color = color), name = legend, mode = "markers")
		push!(_plot_data(fig), trace_stem)
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
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
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
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				push!(_plot_data(fig), _bar_trace(x = x[n], y = y[n], color = colorV[n], name = legendV[n]))
			end
		else
			for n in eachindex(y)
				push!(_plot_data(fig), _bar_trace(x = x, y = y[n], color = colorV[n], name = legendV[n]))
			end
		end
	else
		push!(_plot_data(fig), _bar_trace(
			x = x,
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
		))
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
		refresh = true,
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
)
	if isa(x, Vector) && eltype(x) <: Vector
		colorV = _string_kwarg_vector(color, length(x))
		legendV = _string_kwarg_vector(legend, length(x))
		for n in eachindex(x)
			push!(_plot_data(fig), _histogram_trace(
				x = x[n],
				nbinsx = nbinsx,
				histnorm = histnorm,
				color = colorV[n],
				name = legendV[n],
			))
		end
	else
		push!(_plot_data(fig), _histogram_trace(
			x = x,
			nbinsx = nbinsx,
			histnorm = histnorm,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
		))
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
		refresh = true,
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
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				push!(_plot_data(fig), _box_trace(
					x = x[n],
					y = y[n],
					color = colorV[n],
					name = legendV[n],
					points = points,
				))
			end
		else
			for n in eachindex(y)
				push!(_plot_data(fig), _box_trace(
					x = x,
					y = y[n],
					color = colorV[n],
					name = legendV[n],
					points = points,
				))
			end
		end
	else
		push!(_plot_data(fig), _box_trace(
			x = x,
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			points = points,
		))
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
		refresh = true,
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
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		for n in eachindex(y)
			push!(_plot_data(fig), _box_trace(
				y = y[n],
				color = colorV[n],
				name = legendV[n],
				points = points,
			))
		end
	else
		push!(_plot_data(fig), _box_trace(
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			points = points,
		))
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
		refresh = true,
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
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				push!(_plot_data(fig), _violin_trace(
					x = x[n],
					y = y[n],
					color = colorV[n],
					name = legendV[n],
					points = points,
					side = side,
				))
			end
		else
			for n in eachindex(y)
				push!(_plot_data(fig), _violin_trace(
					x = x,
					y = y[n],
					color = colorV[n],
					name = legendV[n],
					points = points,
					side = side,
				))
			end
		end
	else
		push!(_plot_data(fig), _violin_trace(
			x = x,
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			points = points,
			side = side,
		))
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
		refresh = true,
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
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		for n in eachindex(y)
			push!(_plot_data(fig), _violin_trace(
				y = y[n],
				color = colorV[n],
				name = legendV[n],
				points = points,
				side = side,
			))
		end
	else
		push!(_plot_data(fig), _violin_trace(
			y = y,
			color = _first_or_empty(color),
			name = _first_or_empty(legend),
			points = points,
			side = side,
		))
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
		refresh = true,
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
)
	if isa(r, Vector) && eltype(r) <: Vector
		modeV = fill("line", length(r))
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

		if isa(theta, Vector) && eltype(theta) <: Vector
			for n in eachindex(r)
				trace = scatterpolar(
					r = r[n],
					theta = theta[n],
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
				push!(_plot_data(fig), trace)
			end
		else
			for n in eachindex(r)
				trace = scatterpolar(
					r = r[n],
					theta = theta,
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
				push!(_plot_data(fig), trace)
			end
		end
	else
		trace = scatterpolar(
			r = r,
			theta = theta,
			mode = mode,
			line = attr(color = color, dash = dash),
			name = legend,
		)
		push!(_plot_data(fig), trace)
	end
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if isa(theta, Vector) && eltype(theta) <: Vector
		min_theta = minimum(map(minimum, theta))
		max_theta = maximum(map(maximum, theta))
		relayout!(fig, polar = attr(sector = [min_theta, max_theta]))
	else
		relayout!(fig, polar = attr(sector = [minimum(theta), maximum(theta)]))
	end
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
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	_apply_default_template!(fig)
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
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = heatmap(x = x, y = y, z = FV, colorscale = colorscale)
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
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
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
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = contour(x = x, y = y, z = FV, colorscale = colorscale)
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
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
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

	p_max = maximum(sqrt.(u_vec .^ 2 .+ v_vec .^ 2))
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
	_apply_default_template!(fig)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	_refresh!(fig)
	return nothing
end

"""
	function plot_surface!(
		fig,
		X::Matrix,
		Y::Matrix,
		Z::Matrix;
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
	X::Matrix,
	Y::Matrix,
	Z::Matrix;
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
		trace = surface(x = X, y = Y, z = Z, colorscale = colorscale)
	else
		trace = surface(x = X, y = Y, z = Z, surfacecolor = surfacecolor, colorscale = colorscale)
	end
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
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
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
	_refresh!(fig)
	return nothing
end

function plot_surface!(
	fig,
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

		for n in eachindex(z)
			trace = scatter3d(
				y = y[n],
				x = x[n],
				z = z[n],
				mode = modeV[n],
				line = attr(color = colorV[n]),
				name = legendV[n],
			)
			push!(_plot_data(fig), trace)
		end
	else
		trace = scatter3d(
			x = x,
			y = y,
			z = z,
			mode = mode,
			line = attr(color = color),
			name = legend,
		)
		push!(_plot_data(fig), trace)
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
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
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
		colorscale = colorscale,
	)
	# if a single color is requested, force a uniform colorscale and hide colorbar
	if color != ""
		trace.colorscale = [[0, color], [1, color]]
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
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
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
