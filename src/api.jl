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

struct _StagedPlotMutation
	plot::Plot
end

struct _HighLevelStagedPlotMutation
	plot::Plot
end

function _refresh!(fig)
	p = _plot_obj(fig)
	# Route through the public target exactly once. A SyncPlot owns its renderer
	# transaction directly; a registered Plot discovers that SyncPlot through
	# react!. Rendering both paths allowed an older, unlocked full refresh to
	# race and overwrite a newer incremental mutation.
	react!(fig, p.data, p.layout)
	return nothing
end

_refresh!(::_StagedPlotMutation) = nothing
_refresh!(::_HighLevelStagedPlotMutation) = nothing

function PlotlyBase.relayout!(
	staged::_StagedPlotMutation,
	args...;
	kwargs...,
)
	_do_relayout!(staged.plot, args...; kwargs...)
	return staged
end

function PlotlyBase.relayout!(
	staged::_HighLevelStagedPlotMutation,
	args...;
	kwargs...,
)
	# The high-level fast path has already isolated every layout container that
	# PlotlyBase's setters can mutate. Applying the setter directly avoids
	# cloning that candidate again for every option helper. The setters are the
	# same ones the full staging path uses, so a scalar `title` is promoted
	# before nested `title_*` edits, dotted keys address nested paths, and a
	# `nothing` value removes the key.
	_apply_relayout_setters!(staged.plot.layout, args, kwargs, :relayout!)
	return staged
end

function PlotlyBase.react!(
	staged::_StagedPlotMutation,
	data::AbstractVector{<:AbstractTrace},
	layout::AbstractLayout,
)
	_do_react!(staged.plot, data, layout)
	return staged
end

function PlotlyBase.react!(
	staged::_HighLevelStagedPlotMutation,
	data::AbstractVector{<:AbstractTrace},
	layout::AbstractLayout,
)
	_do_react!(staged.plot, data, layout)
	return staged
end

function PlotlyBase.addtraces!(
	staged::_StagedPlotMutation,
	traces::AbstractTrace...,
)
	_do_addtraces!(staged.plot, traces...)
	return staged
end

function PlotlyBase.addtraces!(
	staged::_HighLevelStagedPlotMutation,
	traces::AbstractTrace...,
)
	_do_addtraces!(staged.plot, traces...)
	return staged
end

function PlotlyBase.addtraces!(
	staged::_StagedPlotMutation,
	index::Int,
	traces::AbstractTrace...,
)
	_do_addtraces!(staged.plot, index, traces...)
	return staged
end

function PlotlyBase.addtraces!(
	staged::_HighLevelStagedPlotMutation,
	index::Int,
	traces::AbstractTrace...,
)
	_do_addtraces!(staged.plot, index, traces...)
	return staged
end

for updater in (
	:update_xaxes!,
	:update_yaxes!,
	:update_geos!,
	:update_mapboxes!,
	:update_polars!,
	:update_scenes!,
	:update_ternaries!,
)
	@eval function PlotlyBase.$updater(
		staged::Union{
			_StagedPlotMutation,
			_HighLevelStagedPlotMutation,
		},
		with::PlotlyBase.PlotlyAttribute = attr();
		kwargs...,
	)
		PlotlyBase.$updater(
			staged.plot.layout,
			with;
			kwargs...,
		)
		return staged
	end
end

for updater in (
	:update_annotations!,
	:update_shapes!,
	:update_images!,
)
	@eval function PlotlyBase.$updater(
		staged::_StagedPlotMutation,
		with::PlotlyBase.PlotlyAttribute = attr();
		kwargs...,
	)
		PlotlyBase.$updater(
			staged.plot.layout,
			with;
			kwargs...,
		)
		return staged
	end
end

function _transactional_high_level_plot_mutation!(
	mutator::Function,
	fig::Union{Plot,SyncPlot},
	args...;
	kwargs...,
)
	result = Ref{Any}(nothing)
	staged_target = Ref{Any}(nothing)
	full_mutation = function (candidate)
		staged = _StagedPlotMutation(candidate)
		staged_target[] = staged
		result[] = mutator(staged, args...; kwargs...)
		return nothing
	end
	fast_mutation = function (candidate)
		staged = _HighLevelStagedPlotMutation(candidate)
		staged_target[] = staged
		result[] = mutator(staged, args...; kwargs...)
		return nothing
	end
	fast_path_allowed =
		(
			mutator === _set_legend_impl! ||
			_is_transactional_high_level_plot_mutator(mutator)
		) &&
		!(
			mutator === plot_surface! &&
			get(kwargs, :shared_coloraxis, false) === true
		)

	if !fast_path_allowed
		if fig isa SyncPlot
			_mutate_and_refresh_syncplot!(full_mutation, fig)
		else
			_transactional_full_plot_mutation!(
				full_mutation,
				fig,
			)
		end
	elseif fig isa SyncPlot
		prepare = (target, current) ->
			_prepare_high_level_plot_mutation_transaction(
				target,
				current,
				fast_mutation,
				full_mutation,
			)
		_syncplot_transaction!(fig, prepare)
	else
		_transactional_high_level_model_mutation!(
			fast_mutation,
			full_mutation,
			fig,
		)
	end
	return result[] === staged_target[] ? fig : result[]
end

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
# plotly_white paints axis.linecolor as #EBF0F8 (same as the grid). After
# f22f860 the Template object is applied in full, so that wash-out becomes the
# exported spine. Publication default is a closed black box.
const _DEFAULT_AXIS_LINECOLOR = "#000000"
const _DEFAULT_AXIS_LINEWIDTH = 1.0

function _normalize_template(template)
	(template isa Symbol || template isa AbstractString) ||
		throw(ArgumentError(
			"template names must be strings or symbols; got $(typeof(template))",
		))
	template_sym = Symbol(template)
	if template_sym in keys(PlotlyBase.templates)
		return template_sym
	end
	parts = strip.(split(String(template), '+'))
	if length(parts) > 1 &&
			all(!isempty(part) && Symbol(part) in keys(PlotlyBase.templates)
				for part in parts)
		return Symbol(join(parts, '+'))
	end
	valid_templates = sort!(collect(keys(PlotlyBase.templates)))
	@warn "Unrecognized template $(repr(template)); falling back to :plotly_white." valid = valid_templates
	return :plotly_white
end

_resolve_template(template::PlotlyBase.Template) = template
function _resolve_template(template)
	name = _normalize_template(template)
	name in keys(PlotlyBase.templates) &&
		return PlotlyBase.templates[name]
	return PlotlyBase.templates[String(name)]
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

Set the package-wide default Plotly template name used by high-level
constructors. The name may refer to a built-in template or a custom
`PlotlyBase.Template` registered in `PlotlyBase.templates`; registered names
may be combined with `+` using PlotlyBase's compound-template syntax. Invalid
names fall back to `:plotly_white`.
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
	relayout!(fig, template = _resolve_template(_DEFAULT_TEMPLATE[]))
	# Re-apply spines after the template so plotly_white cannot wash them out.
	_apply_default_cartesian_axes!(fig)
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
		:linecolor => _DEFAULT_AXIS_LINECOLOR,
		:linewidth => _DEFAULT_AXIS_LINEWIDTH,
		:tickcolor => _DEFAULT_AXIS_LINECOLOR,
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
			linecolor = _DEFAULT_AXIS_LINECOLOR,
			linewidth = _DEFAULT_AXIS_LINEWIDTH,
			tickcolor = _DEFAULT_AXIS_LINECOLOR,
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
			linecolor = _DEFAULT_AXIS_LINECOLOR,
			linewidth = _DEFAULT_AXIS_LINEWIDTH,
			tickcolor = _DEFAULT_AXIS_LINECOLOR,
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

# Mutating 3D constructors must not replace scene styling merely because a
# caller appended a trace. Only explicitly requested labels/aspect settings
# and the opt-out grid/visibility flags are merged into the existing scene.
function _apply_scene_style_options!(
	fig;
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::Union{Nothing, String} = nothing,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
)
	scene_options = Dict{Symbol, Any}()
	aspectmode === nothing || (scene_options[:aspectmode] = aspectmode)
	perspective === nothing ||
		(scene_options[:camera] = attr(
			projection = attr(
				type = perspective ? "perspective" : "orthographic",
			),
		))

	for (key, label) in (
		(:xaxis, xlabel),
		(:yaxis, ylabel),
		(:zaxis, zlabel),
	)
		axis_options = Dict{Symbol, Any}()
		isempty(label) ||
			(axis_options[:title] = attr(text = label))
		grid === nothing || (axis_options[:showgrid] = grid)
		showaxis === nothing || (axis_options[:visible] = showaxis)
		isempty(axis_options) ||
			(scene_options[key] = attr(; axis_options...))
	end

	isempty(scene_options) ||
		_merge_scene_layout_attr!(
			_plot_layout(fig),
			:scene,
			attr(; scene_options...),
		)
	return nothing
end

"""
	_SubplotInset

Immutable record of one inset axes pair registered on a [`SubplotFigure`](@ref)
(see `inset!`). `row`/`col` name the host grid cell; `xkey`/`ykey` are the
layout keys (`:xaxis5`, `:yaxis5`) and `xref`/`yref` the matching trace
references (`"x5"`, `"y5"`); `xdomain`/`ydomain` are the paper-fraction
domains the inset was created with. Inset ids are 1-based positions in
`sf.insets`.
"""
struct _SubplotInset
	row::Int
	col::Int
	xkey::Symbol
	ykey::Symbol
	xref::String
	yref::String
	xdomain::NTuple{2, Float64}
	ydomain::NTuple{2, Float64}
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
	# Inset axes registered by `inset!`, in creation order (id k == index k).
	# Staged copies get their own vector, so a failed transactional mutation
	# never leaks a half-registered inset into the live figure.
	insets::Vector{_SubplotInset}
	_lock::ReentrantLock
end

function SubplotFigure(
	fig::Union{Plot,SyncPlot},
	rows::Int,
	cols::Int,
	current_row::Int,
	current_col::Int,
	per_subplot_legends::Bool,
	legend_position::Symbol,
	legend_inset::Tuple{Float64,Float64},
	legend_bgcolor::String,
	legend_bordercolor::String,
	legend_borderwidth::Float64,
	insets::AbstractVector{_SubplotInset} = _SubplotInset[],
)
	return SubplotFigure(
		fig,
		rows,
		cols,
		current_row,
		current_col,
		per_subplot_legends,
		legend_position,
		legend_inset,
		legend_bgcolor,
		legend_bordercolor,
		legend_borderwidth,
		# Always own a fresh vector: a caller's vector (or a live figure's
		# metadata, when staging) must never be shared with this figure.
		collect(_SubplotInset, insets),
		ReentrantLock(),
	)
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
		name === :legend_borderwidth ||
		name === :insets ||
		name === :_lock
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
	own = private ?
		fieldnames(SubplotFigure) :
		filter(!=(:_lock), fieldnames(SubplotFigure))
	fig = getfield(sf, :fig)
	# `getproperty(sf, :plot)` serves the wrapped Plot for both backings, so
	# `:plot` must be listed for both: `hasproperty(sf, :plot)` is how the
	# untyped helpers (`_plot_obj`, `set_template!`, `annotate!`) find the
	# model. A SyncPlot already lists `:plot`; `unique` keeps each name once.
	forwarded = fig isa Plot ?
		(:plot, propertynames(fig, private)...) :
		propertynames(fig, private)
	return Tuple(unique((own..., forwarded...)))
end

function _staged_subplot_figure(
	sf::SubplotFigure,
	candidate::Plot,
)
	# The positional constructor copies `insets`, so the staged figure can
	# push/replace inset records without touching the live metadata until
	# `_commit_subplot_metadata!` publishes the fields the mutation owns.
	return SubplotFigure(
		candidate,
		sf.rows,
		sf.cols,
		sf.current_row,
		sf.current_col,
		sf.per_subplot_legends,
		sf.legend_position,
		sf.legend_inset,
		sf.legend_bgcolor,
		sf.legend_bordercolor,
		sf.legend_borderwidth,
		getfield(sf, :insets),
	)
end

const _SUBPLOT_SELECTION_METADATA_FIELDS = (
	:current_row,
	:current_col,
)
const _SUBPLOT_LEGEND_METADATA_FIELDS = (
	:legend_position,
	:legend_inset,
	:legend_bgcolor,
	:legend_bordercolor,
	:legend_borderwidth,
)
# Mutations that register inset axes (`inset!`) commit the new inset list
# together with the active-cell selection.
const _SUBPLOT_INSET_METADATA_FIELDS = (
	_SUBPLOT_SELECTION_METADATA_FIELDS...,
	:insets,
)

function _commit_subplot_metadata!(
	sf::SubplotFigure,
	staged::SubplotFigure,
	fields::Tuple{Vararg{Symbol}},
)
	for field in fields
		setfield!(sf, field, getfield(staged, field))
	end
	return sf
end

function _transactional_subplot_mutation!(
	mutator::Function,
	sf::SubplotFigure,
	metadata_fields::Tuple{Vararg{Symbol}},
	args...;
	kwargs...,
)
	metadata_lock = getfield(sf, :_lock)
	lock(metadata_lock)
	try
		staged_ref =
			Ref{Union{Nothing,SubplotFigure}}(nothing)
		result = Ref{Any}(nothing)
		mutation = function (candidate)
			staged = _staged_subplot_figure(sf, candidate)
			staged_ref[] = staged
			result[] =
				mutator(staged, args...; kwargs...)
			return nothing
		end
		commit_callback = _ -> _commit_subplot_metadata!(
			sf,
			something(staged_ref[]),
			metadata_fields,
		)

		fig = getfield(sf, :fig)
		if fig isa SyncPlot
			_mutate_and_refresh_syncplot!(
				mutation,
				fig;
				commit_callback = commit_callback,
			)
		else
			_transactional_full_plot_mutation!(
				mutation,
				fig;
				commit_callback = commit_callback,
			)
		end
		return result[] === staged_ref[] ? sf : result[]
	finally
		unlock(metadata_lock)
	end
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
	elseif x isa NamedTuple
		for (k, v) in pairs(x)
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

	if haskey(fields, :geo)
		geo_ref = String(get(fields, :geo, "geo"))
		domain = _layout_subplot_domain(p.layout, Symbol(geo_ref))
		domain === nothing && return nothing
		return ("geo:" * geo_ref, domain)
	end

	if haskey(fields, :subplot)
		subplot_ref = String(get(fields, :subplot, "polar"))
		domain = _layout_subplot_domain(p.layout, Symbol(subplot_ref))
		domain === nothing && return nothing
		return ("subplot:" * subplot_ref, domain)
	end

	if haskey(fields, :domain)
		domain_fields = _symbol_dict(fields[:domain])
		xdom = _domain_tuple(get(domain_fields, :x, nothing))
		ydom = _domain_tuple(get(domain_fields, :y, nothing))
		(xdom === nothing || ydom === nothing) && return nothing
		key = "domain:$(xdom[1]),$(xdom[2])|$(ydom[1]),$(ydom[2])"
		return (key, (xdom, ydom))
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
function _trace_has_slice_legend(trace::GenericTrace)
	trace_type = get(trace.fields, :type, nothing)
	return trace_type in ("pie", :pie, "funnelarea", :funnelarea)
end

function _trace_will_showlegend(trace::GenericTrace)
	haskey(trace.fields, :showlegend) &&
		return _trace_showlegend(trace)
	return _trace_has_legend_label(trace) ||
		_trace_has_slice_legend(trace)
end

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
			trace.fields[:showlegend] =
				_trace_will_showlegend(trace)
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

function _set_legend_impl!(
	fig;
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

"""
	set_legend!(fig; position=:topright, showlegend=nothing, kwargs...)

Set legend placement and styling with simple position symbols such as
`:top`, `:topright`, `:left`, `:bottomleft`, or `:outside_right`. Accepted
positions also include `:bottom`, `:right`, `:center`, `:topleft`,
`:bottomright`, `:outside_left`, `:outside_top`, and `:outside_bottom`.

Pass `showlegend=true` to force the legend visible (useful for a single,
unnamed trace), or `showlegend=false` to hide it.

`fig` may be a `Plot`, [`SyncPlot`](@ref), or [`SubplotFigure`](@ref); on a
`SubplotFigure` the choice is stored and applied to the active subplot
arrangement (see [`subplot_legends!`](@ref)).

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
	return _transactional_high_level_plot_mutation!(
		_set_legend_impl!,
		fig;
		position = position,
		inset = inset,
		bgcolor = bgcolor,
		bordercolor = bordercolor,
		borderwidth = borderwidth,
		showlegend = showlegend,
	)
end

function _set_subplot_legend_impl!(
	sf::SubplotFigure;
	position::Union{Nothing, Symbol, AbstractString} = nothing,
	inset::Union{Nothing, Tuple{<:Real, <:Real}} = nothing,
	bgcolor::Union{Nothing, String} = nothing,
	bordercolor::Union{Nothing, String} = nothing,
	borderwidth::Union{Nothing, Real} = nothing,
)
	resolved_position =
		position === nothing ? sf.legend_position : position
	resolved_inset = inset === nothing ? sf.legend_inset : inset
	resolved_bgcolor =
		bgcolor === nothing ? sf.legend_bgcolor : bgcolor
	resolved_bordercolor =
		bordercolor === nothing ? sf.legend_bordercolor : bordercolor
	resolved_borderwidth =
		borderwidth === nothing ? sf.legend_borderwidth : borderwidth

	sf.legend_position = _normalize_legend_position(resolved_position)
	sf.legend_inset = (
		Float64(resolved_inset[1]),
		Float64(resolved_inset[2]),
	)
	sf.legend_bgcolor = resolved_bgcolor
	sf.legend_bordercolor = resolved_bordercolor
	sf.legend_borderwidth = Float64(resolved_borderwidth)

	if sf.per_subplot_legends
		subplot_legends!(
			sf;
			position = sf.legend_position,
			legend_inset = sf.legend_inset,
			legend_bgcolor = sf.legend_bgcolor,
			legend_bordercolor = sf.legend_bordercolor,
			legend_borderwidth = sf.legend_borderwidth,
		)
	else
		set_legend!(
			sf.fig;
			position = sf.legend_position,
			inset = sf.legend_inset,
			bgcolor = sf.legend_bgcolor,
			bordercolor = sf.legend_bordercolor,
			borderwidth = sf.legend_borderwidth,
		)
	end
	return sf
end

function set_legend!(
	sf::SubplotFigure;
	position::Union{Nothing, Symbol, AbstractString} = nothing,
	inset::Union{Nothing, Tuple{<:Real, <:Real}} = nothing,
	bgcolor::Union{Nothing, String} = nothing,
	bordercolor::Union{Nothing, String} = nothing,
	borderwidth::Union{Nothing, Real} = nothing,
)
	return _transactional_subplot_mutation!(
		_set_subplot_legend_impl!,
		sf,
		_SUBPLOT_LEGEND_METADATA_FIELDS;
		position = position,
		inset = inset,
		bgcolor = bgcolor,
		bordercolor = bordercolor,
		borderwidth = borderwidth,
	)
end

function _subplot_legends_impl!(
	fig;
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

"""
	subplot_legends!(fig; kwargs...)

Attach each subplot to its own legend box and place that legend inside the
subplot domain. This avoids Plotly's default behavior where all legends are
clustered in one place.

`fig` may be a `Plot`, [`SyncPlot`](@ref), or [`SubplotFigure`](@ref); returns
the figure.

# Keyword Arguments
- `position`: Symbolic legend placement, same set as [`set_legend!`](@ref)
  (default `get_default_legend_position()`).
- `legend_inset`: Relative `(x, y)` padding inside each subplot domain.
- `legend_bgcolor` / `legend_bordercolor` / `legend_borderwidth`: Legend box styling.
"""
function subplot_legends!(
	fig::Union{Plot, SyncPlot};
	position::Union{Symbol, AbstractString} = get_default_legend_position(),
	legend_inset::Tuple{<:Real, <:Real} = _DEFAULT_LEGEND_INSET[],
	legend_bgcolor::String = _DEFAULT_LEGEND_BGCOLOR[],
	legend_bordercolor::String = _DEFAULT_LEGEND_BORDERCOLOR[],
	legend_borderwidth::Real = _DEFAULT_LEGEND_BORDERWIDTH[],
)
	return _transactional_high_level_plot_mutation!(
		_subplot_legends_impl!,
		fig;
		position = position,
		legend_inset = legend_inset,
		legend_bgcolor = legend_bgcolor,
		legend_bordercolor = legend_bordercolor,
		legend_borderwidth = legend_borderwidth,
	)
end

function _subplot_figure_legends_impl!(
	sf::SubplotFigure;
	position::Union{Nothing, Symbol, AbstractString} = nothing,
	legend_inset::Union{Nothing, Tuple{<:Real, <:Real}} = nothing,
	legend_bgcolor::Union{Nothing, String} = nothing,
	legend_bordercolor::Union{Nothing, String} = nothing,
	legend_borderwidth::Union{Nothing, Real} = nothing,
)
	resolved_position =
		position === nothing ? sf.legend_position : position
	resolved_inset =
		legend_inset === nothing ? sf.legend_inset : legend_inset
	resolved_bgcolor =
		legend_bgcolor === nothing ? sf.legend_bgcolor : legend_bgcolor
	resolved_bordercolor = legend_bordercolor === nothing ?
		sf.legend_bordercolor :
		legend_bordercolor
	resolved_borderwidth = legend_borderwidth === nothing ?
		sf.legend_borderwidth :
		legend_borderwidth

	sf.legend_position = _normalize_legend_position(resolved_position)
	sf.legend_inset = (
		Float64(resolved_inset[1]),
		Float64(resolved_inset[2]),
	)
	sf.legend_bgcolor = resolved_bgcolor
	sf.legend_bordercolor = resolved_bordercolor
	sf.legend_borderwidth = Float64(resolved_borderwidth)

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

function subplot_legends!(
	sf::SubplotFigure;
	position::Union{Nothing, Symbol, AbstractString} = nothing,
	legend_inset::Union{Nothing, Tuple{<:Real, <:Real}} = nothing,
	legend_bgcolor::Union{Nothing, String} = nothing,
	legend_bordercolor::Union{Nothing, String} = nothing,
	legend_borderwidth::Union{Nothing, Real} = nothing,
)
	return _transactional_subplot_mutation!(
		_subplot_figure_legends_impl!,
		sf,
		_SUBPLOT_LEGEND_METADATA_FIELDS;
		position = position,
		legend_inset = legend_inset,
		legend_bgcolor = legend_bgcolor,
		legend_bordercolor = legend_bordercolor,
		legend_borderwidth = legend_borderwidth,
	)
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

	layout = _plotlysupply_subplot_layout(
		Subplots(rows = rows_i, cols = cols_i; subplot_kwargs...),
	)
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
	lock(getfield(sf, :_lock)) do
		_check_subplot_cell(sf, r, c)
		sf.current_row = r
		sf.current_col = c
	end
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
PlotlyBase.to_image(sf::SubplotFigure; kwargs...) =
	PlotlyBase.to_image(getfield(sf, :fig); kwargs...)
PlotlyBase.download_image(sf::SubplotFigure; kwargs...) =
	PlotlyBase.download_image(getfield(sf, :fig); kwargs...)

function _subplot_target_ref(
	p::Plot,
	row::Int,
	col::Int;
	secondary_y::Bool = false,
)
	grid_ref = p.layout.subplots.grid_ref
	if !isassigned(grid_ref, row, col) || isempty(grid_ref[row, col])
		throw(ArgumentError("subplot cell ($(row), $(col)) is empty"))
	end

	refs = grid_ref[row, col]
	if secondary_y && (refs[1].subplot_kind != "xy" || length(refs) < 2)
		throw(ArgumentError(
			"subplot cell ($(row), $(col)) has no secondary y-axis; " *
			"create it with `secondary_y=true`",
		))
	end
	return refs[secondary_y ? 2 : 1]
end

function _trace_subplot_kind(trace::GenericTrace)
	trace_type_value = get(trace.fields, :type, "scatter")
	trace_type = try
		trace_type_value isa Symbol ? trace_type_value : Symbol(trace_type_value)
	catch
		throw(ArgumentError("invalid Plotly trace type $(repr(trace_type_value))"))
	end
	kind = try
		_plotlysupply_subplot_kind_from_trace_type(trace_type)
	catch
		throw(ArgumentError("unknown Plotly trace type $(repr(trace_type_value))"))
	end
	kind isa AbstractString ||
		throw(ArgumentError("Plotly trace type $(repr(trace_type_value)) has no subplot kind"))
	return String(kind), trace_type
end

function _validate_subplot_traces!(
	p::Plot,
	traces,
	row::Int,
	col::Int;
	secondary_y::Bool = false,
)
	target_ref = _subplot_target_ref(p, row, col; secondary_y = secondary_y)
	target_kind = target_ref.subplot_kind
	for trace in traces
		trace isa GenericTrace ||
			throw(ArgumentError("only PlotlyBase.GenericTrace values can be added to a subplot"))
		required_kind, trace_type = _trace_subplot_kind(trace)
		required_kind == target_kind || throw(ArgumentError(
			"trace type '$trace_type' requires a '$required_kind' subplot, " *
			"but cell ($(row), $(col)) is '$target_kind'",
		))
	end
	return target_ref
end

function _subplot_add_trace_impl!(
	sf::SubplotFigure,
	trace::GenericTrace;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	p = _plot_obj(sf.fig)
	_validate_subplot_traces!(p, (trace,), r, c; secondary_y = secondary_y)
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

function PlotlyBase.add_trace!(
	sf::SubplotFigure,
	trace::GenericTrace;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	return _transactional_subplot_mutation!(
		_subplot_add_trace_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		trace;
		row = row,
		col = col,
		secondary_y = secondary_y,
	)
end

function _subplot_addtraces_impl!(
	sf::SubplotFigure,
	traces::AbstractTrace...;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	isempty(traces) && return sf

	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	p = _plot_obj(sf.fig)
	_validate_subplot_traces!(p, traces, r, c; secondary_y = secondary_y)

	# PlotlyBase.add_trace! deep-copies each trace and merges the selected
	# subplot references. Stage the whole batch so a bad later trace or subplot
	# reference cannot leave a partially appended figure.
	staged = Plot(p.layout)
	sizehint!(staged.data, length(traces))
	for trace in traces
		PlotlyBase.add_trace!(staged, trace; row = r, col = c, secondary_y = secondary_y)
	end
	append!(p.data, staged.data)

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
	isempty(traces) && return sf
	return _transactional_subplot_mutation!(
		_subplot_addtraces_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		traces...;
		row = row,
		col = col,
		secondary_y = secondary_y,
	)
end

_is_layout_mapping(value) =
	value isa PlotlyBase.PlotlyAttribute ||
	value isa AbstractDict ||
	value isa NamedTuple

const _AXIS_LAYOUT_MERGE_PATHS = ((:title,),)
const _GEO_LAYOUT_MERGE_PATHS = ((:projection,),)
const _POLAR_LAYOUT_MERGE_PATHS = (
	(:radialaxis, :title),
	(:angularaxis, :title),
)
const _SCENE_LAYOUT_MERGE_PATHS = (
	(:xaxis, :title),
	(:yaxis, :title),
	(:zaxis, :title),
	(:camera, :projection),
)
const _TERNARY_LAYOUT_MERGE_PATHS = (
	(:aaxis, :title),
	(:baxis, :title),
	(:caxis, :title),
)
const _MAPBOX_LAYOUT_MERGE_PATHS = ((:center,),)
const _MAP_LAYOUT_MERGE_PATHS = (
	(:center,),
	(:bounds,),
)

function _prepare_scene_layout_attr_merge!(
	context,
	layout::Layout,
	key::Symbol,
	source,
)
	return _prepare_layout_attr_merge!(
		context,
		layout,
		key,
		source;
		drop_keys = (:domain,),
		deep_merge_paths = _SCENE_LAYOUT_MERGE_PATHS,
		mutate_builtin_target = true,
	)
end

# Scene updates produced by PlotlySupply are deliberately partial. Merge only
# Plotly's known nested scene containers so an axis-label/range or camera
# projection update cannot replace sibling styling. This bounded schema merge
# avoids recursively traversing opaque or cyclic user-supplied layout values.
function _merge_scene_layout_attr!(
	layout::Layout,
	key::Symbol,
	source,
)
	context = _new_layout_merge_context()
	changed = _prepare_scene_layout_attr_merge!(
		context,
		layout,
		key,
		source,
	)
	changed || return nothing
	mutations = _finalize_layout_merge_context(context)
	_commit_layout_merge_context!(context, mutations)
	return nothing
end

function _prepare_ternary_layout_attr_merge!(
	context,
	layout::Layout,
	key::Symbol,
	source,
)
	return _prepare_layout_attr_merge!(
		context,
		layout,
		key,
		source;
		drop_keys = (:domain,),
		deep_merge_paths = _TERNARY_LAYOUT_MERGE_PATHS,
		mutate_builtin_target = true,
	)
end

# Ternary labels are partial axis updates, just like 3D scene labels. Preserve
# axis ranges/ticks and nested title styling while routing the source
# `ternary` layout into the selected target subplot (`ternary2`, etc.).
function _merge_ternary_layout_attr!(
	layout::Layout,
	key::Symbol,
	source,
)
	context = _new_layout_merge_context()
	changed = _prepare_ternary_layout_attr_merge!(
		context,
		layout,
		key,
		source,
	)
	changed || return nothing
	mutations = _finalize_layout_merge_context(context)
	_commit_layout_merge_context!(context, mutations)
	return nothing
end

function _builtin_layout_mapping_fields(existing)
	fields = if existing isa PlotlyBase.PlotlyAttribute
		existing.fields
	elseif existing isa Dict || existing isa IdDict
		existing
	else
		nothing
	end
	return fields isa Dict || fields isa IdDict ?
		fields :
		nothing
end

function _is_persistent_immutable_layout_mapping(existing)
	return existing isa Base.ImmutableDict ||
		(
			isdefined(Base, :PersistentDict) &&
			existing isa getfield(Base, :PersistentDict)
		)
end

function _requires_supported_layout_mapping_storage(existing)
	(
		existing isa PlotlyBase.PlotlyAttribute ||
		existing isa AbstractDict
	) || return false
	_builtin_layout_mapping_fields(existing) === nothing ||
		return false
	# Persistent mappings have no in-place write API, so replacing them is the
	# only possible update and does not abandon a mutable mapping identity.
	return !_is_persistent_immutable_layout_mapping(existing)
end

function _layout_mapping_storage(existing)
	if existing isa PlotlyBase.PlotlyAttribute
		return existing.fields
	elseif existing isa AbstractDict
		return existing
	end
	return nothing
end

function _require_unambiguous_layout_mapping(
	existing,
	path::String,
)
	fields = _layout_mapping_storage(existing)
	fields === nothing && return nothing

	seen = Set{Symbol}()
	for stored_key in keys(fields)
		(
			stored_key isa Symbol ||
			stored_key isa String
		) || throw(ArgumentError(
			"$path uses key $(repr(stored_key)) of type " *
			"$(typeof(stored_key)); atomic layout merges support only " *
			"concrete Symbol or String keys.",
		))
		canonical_key = Symbol(stored_key)
		canonical_key in seen && throw(ArgumentError(
			"$path contains both Symbol/String spellings of " *
			"$(repr(canonical_key)); merging them would silently discard " *
			"one value.",
		))
		push!(seen, canonical_key)
	end
	return nothing
end

function _require_safe_builtin_layout_mapping(
	fields,
	path::String,
)
	_require_unambiguous_layout_mapping(fields, path)
	key_type = keytype(fields)
	(
		Symbol <: key_type ||
		String <: key_type
	) || throw(ArgumentError(
		"$path uses key type $key_type, which cannot be committed " *
		"atomically with concrete Symbol or String keys.",
	))
	return nothing
end

function _new_layout_merge_context()
	return (
		contents = IdDict{Any, Dict{Symbol, Any}}(),
		paths = IdDict{Any, String}(),
		roots = IdDict{Any, Nothing}(),
	)
end

function _prepared_builtin_layout_contents!(
	context,
	existing,
	path::String,
)
	fields = _builtin_layout_mapping_fields(existing)
	fields === nothing && return nothing
	if !haskey(context.contents, fields)
		_require_safe_builtin_layout_mapping(fields, path)
		context.contents[fields] = _symbol_dict(existing)
		context.paths[fields] = path
	end
	return context.contents[fields]
end

function _try_prepare_builtin_layout_mapping(
	fields,
	contents::Dict{Symbol, Any},
)
	candidate = try
		existing_keys = Dict{Symbol, Any}()
		has_symbol_key = false
		has_string_key = false
		for stored_key in keys(fields)
			symbol_key = Symbol(stored_key)
			existing_keys[symbol_key] = stored_key
			has_symbol_key |= stored_key isa Symbol
			has_string_key |= stored_key isa AbstractString
		end
		prefer_string_key = has_string_key && !has_symbol_key

		prepared = empty(fields)
		for (candidate_key, candidate_value) in contents
			stored_key = if haskey(existing_keys, candidate_key)
				# Retain existing key objects, which matters for IdDict and
				# also avoids changing String-keyed mappings to Symbol keys.
				existing_keys[candidate_key]
			elseif prefer_string_key &&
				String <: keytype(fields)
				string(candidate_key)
			elseif Symbol <: keytype(fields)
				candidate_key
			elseif String <: keytype(fields)
				string(candidate_key)
			else
				candidate_key
			end
			prepared[stored_key] = candidate_value
		end
		prepared
	catch err
		if err isa MethodError ||
			err isa TypeError ||
			err isa InexactError ||
			err isa ArgumentError ||
			err isa OverflowError
			nothing
		else
			rethrow()
		end
	end
	return candidate
end

function _throw_unrepresentable_layout_mapping(
	path::String,
	fields,
)
	throw(ArgumentError(
		"$path uses $(typeof(fields)), which cannot represent the " *
		"merged layout values without replacing the container and " *
		"breaking object identity. Use an Any-valued mapping such as " *
		"`Dict{Symbol,Any}` for heterogeneous layout attributes.",
	))
end

function _finalize_layout_merge_context(context)
	mutations = IdDict{Any, Any}()
	for (fields, contents) in context.contents
		candidate =
			_try_prepare_builtin_layout_mapping(fields, contents)
		candidate === nothing &&
			_throw_unrepresentable_layout_mapping(
				context.paths[fields],
				fields,
			)
		_require_safe_builtin_layout_mapping(
			candidate,
			context.paths[fields],
		)
		mutations[fields] = candidate
	end
	return mutations
end

function _layout_merge_graph_terminal(value)
	return (
		isbits(value) ||
		value isa Symbol ||
		value isa String ||
		value isa Type ||
		value isa Module ||
		value isa Function ||
		value isa BigInt ||
		value isa BigFloat
	)
end

function _collect_layout_mapping_implementation_identities!(
	identities::IdDict{Any,Nothing},
	value,
	seen::IdDict{Any,Nothing},
)
	_layout_merge_graph_terminal(value) &&
		return identities
	haskey(seen, value) && return identities
	seen[value] = nothing
	ismutable(value) &&
		(identities[value] = nothing)
	(
		value isa Dict ||
		value isa IdDict ||
		value isa AbstractArray
	) && return identities
	for index in 1:fieldcount(typeof(value))
		isdefined(value, index) || continue
		_collect_layout_mapping_implementation_identities!(
			identities,
			getfield(value, index),
			seen,
		)
	end
	return identities
end

function _add_layout_mapping_implementation_identities!(
	identities::IdDict{Any,Nothing},
	value,
)
	storage = _layout_mapping_storage(value)
	(
		storage === nothing ||
		storage isa Dict ||
		storage isa IdDict
	) && return identities
	seen = IdDict{Any,Nothing}(storage => nothing)
	for index in 1:fieldcount(typeof(storage))
		isdefined(storage, index) || continue
		_collect_layout_mapping_implementation_identities!(
			identities,
			getfield(storage, index),
			seen,
		)
	end
	return identities
end

function _layout_mapping_has_model_alias(
	plot::Plot,
	key::Symbol,
)
	layout = plot.layout
	layout isa Layout || return false
	root = get(layout.fields, key, nothing)
	_is_layout_mapping(root) || return false

	identities = IdDict{Any,Nothing}(root => nothing)
	storage = _layout_mapping_storage(root)
	storage === nothing ||
		(identities[storage] = nothing)
	_add_layout_mapping_implementation_identities!(
		identities,
		root,
	)
	path = Any[]

	if storage !== nothing
		for (stored_key, child) in pairs(storage)
			_modern_map_graph_contains_identity(
				stored_key,
				identities,
				path,
			) && return true
			_modern_map_graph_contains_identity(
				child,
				identities,
				path,
			) && return true
		end
	end
	for (stored_key, child) in pairs(layout.fields)
		candidate_key =
			stored_key isa Symbol ||
			stored_key isa String ?
			Symbol(stored_key) :
			nothing
		candidate_key === key && child === root &&
			continue
		_modern_map_graph_contains_identity(
			stored_key,
			identities,
			path,
		) && return true
		_modern_map_graph_contains_identity(
			child,
			identities,
			path,
		) && return true
	end
	for graph_root in (
		plot.data,
		plot.frames,
		plot.config,
		getfield(layout, :subplots),
	)
		_modern_map_graph_contains_identity(
			graph_root,
			identities,
			path,
		) && return true
	end
	return false
end

function _nested_layout_mapping_model_alias(
	plot::Plot,
	key::Symbol,
	nested_key::Symbol,
)
	layout = plot.layout
	layout isa Layout || return (false, nothing)
	root = get(layout.fields, key, nothing)
	_is_layout_mapping(root) ||
		return (false, nothing)

	nested = nothing
	found = false
	for (stored_key, child) in pairs(root)
		(
			stored_key isa Symbol ||
			stored_key isa String
		) || continue
		Symbol(stored_key) === nested_key || continue
		nested = child
		found = true
		break
	end
	(
		found &&
		_is_layout_mapping(nested)
	) || return (false, nested)

	identities = IdDict{Any,Nothing}(nested => nothing)
	nested_storage =
		_layout_mapping_storage(nested)
	nested_storage === nothing ||
		(identities[nested_storage] = nothing)
	_add_layout_mapping_implementation_identities!(
		identities,
		nested,
	)
	path = Any[]

	for (stored_key, child) in pairs(nested)
		_modern_map_graph_contains_identity(
			stored_key,
			identities,
			path,
		) && return (true, nested)
		_modern_map_graph_contains_identity(
			child,
			identities,
			path,
		) && return (true, nested)
	end
	for (stored_key, child) in pairs(root)
		_modern_map_graph_contains_identity(
			stored_key,
			identities,
			path,
		) && return (true, nested)
		candidate_key =
			stored_key isa Symbol ||
			stored_key isa String ?
			Symbol(stored_key) :
			nothing
		candidate_key === nested_key &&
			child === nested &&
			continue
		_modern_map_graph_contains_identity(
			child,
			identities,
			path,
		) && return (true, nested)
	end
	for (stored_key, child) in pairs(layout.fields)
		_modern_map_graph_contains_identity(
			stored_key,
			identities,
			path,
		) && return (true, nested)
		candidate_key =
			stored_key isa Symbol ||
			stored_key isa String ?
			Symbol(stored_key) :
			nothing
		candidate_key === key && child === root &&
			continue
		_modern_map_graph_contains_identity(
			child,
			identities,
			path,
		) && return (true, nested)
	end
	for graph_root in (
		plot.data,
		plot.frames,
		plot.config,
		getfield(layout, :subplots),
	)
		_modern_map_graph_contains_identity(
			graph_root,
			identities,
			path,
		) && return (true, nested)
	end
	return (false, nested)
end

function _preserve_layout_mapping_root(
	plot::Plot,
	key::Symbol,
	nested_keys::Tuple{Vararg{Symbol}} =
		(:title,),
)
	existing = get(plot.layout.fields, key, nothing)
	preserve_builtin_root =
		existing isa PlotlyBase.PlotlyAttribute &&
		_builtin_layout_mapping_fields(existing) !== nothing
	root_has_alias =
		_layout_mapping_has_model_alias(plot, key)
	if root_has_alias &&
		_requires_supported_layout_mapping_storage(
			existing,
		)
		throw(ArgumentError(
			"layout.$key uses aliased $(typeof(existing)) storage, which " *
			"cannot be updated without splitting the alias. Use a " *
			"PlotlyAttribute, Dict, or IdDict.",
		))
	end
	nested_has_alias = false
	for nested_key in nested_keys
		has_alias, nested =
			_nested_layout_mapping_model_alias(
				plot,
				key,
				nested_key,
			)
		if has_alias &&
			_requires_supported_layout_mapping_storage(
				nested,
			)
			throw(ArgumentError(
				"layout.$key.$nested_key uses aliased " *
				"$(typeof(nested)) storage, which cannot be updated " *
				"without splitting the alias. Use a PlotlyAttribute, " *
				"Dict, or IdDict.",
			))
		end
		nested_has_alias |= has_alias
	end
	return preserve_builtin_root ||
		root_has_alias ||
		nested_has_alias
end

function _preserve_subplot_axis_root(
	sf::SubplotFigure,
	key::Symbol,
	nested_keys::Tuple{Vararg{Symbol}} =
		(:title,),
)
	return _preserve_layout_mapping_root(
		_plot_obj(sf.fig),
		key,
		nested_keys,
	)
end

function _layout_merge_key_reaches_mutation(
	value,
	mutated::IdDict{Any,Nothing},
	seen::IdDict{Any,Nothing},
)
	_layout_merge_graph_terminal(value) && return false
	haskey(mutated, value) && return true
	haskey(seen, value) && return false
	seen[value] = nothing

	if value isa AbstractDict
		for (key, child) in pairs(value)
			_layout_merge_key_reaches_mutation(
				key,
				mutated,
				seen,
			) && return true
			_layout_merge_key_reaches_mutation(
				child,
				mutated,
				seen,
			) && return true
		end
		(value isa Dict || value isa IdDict) &&
			return false
	elseif value isa AbstractArray
		_array_elements_may_be_mutation_containers(
			eltype(value),
		) || return false
		for index in eachindex(value)
			isassigned(value, index) || continue
			_layout_merge_key_reaches_mutation(
				value[index],
				mutated,
				seen,
			) && return true
		end
		value isa Array && return false
	end

	for index in 1:fieldcount(typeof(value))
		isdefined(value, index) || continue
		_layout_merge_key_reaches_mutation(
			getfield(value, index),
			mutated,
			seen,
		) && return true
	end
	return false
end

function _layout_merge_graph_has_hash_sensitive_key(
	value,
	mutated::IdDict{Any,Nothing},
	seen::IdDict{Any,Nothing},
)
	_layout_merge_graph_terminal(value) && return false
	haskey(seen, value) && return false
	seen[value] = nothing

	if value isa AbstractDict
		for (key, child) in pairs(value)
			if !(value isa IdDict) &&
				!_layout_merge_graph_terminal(key) &&
				_layout_merge_key_reaches_mutation(
					key,
					mutated,
					IdDict{Any,Nothing}(),
				)
				return true
			end
			_layout_merge_graph_has_hash_sensitive_key(
				key,
				mutated,
				seen,
			) && return true
			_layout_merge_graph_has_hash_sensitive_key(
				child,
				mutated,
				seen,
			) && return true
		end
		(value isa Dict || value isa IdDict) &&
			return false
	elseif value isa AbstractArray
		_array_elements_may_be_mutation_containers(
			eltype(value),
		) || return false
		for index in eachindex(value)
			isassigned(value, index) || continue
			_layout_merge_graph_has_hash_sensitive_key(
				value[index],
				mutated,
				seen,
			) && return true
		end
		value isa Array && return false
	end

	for index in 1:fieldcount(typeof(value))
		isdefined(value, index) || continue
		_layout_merge_graph_has_hash_sensitive_key(
			getfield(value, index),
			mutated,
			seen,
		) && return true
	end
	return false
end

function _require_hash_stable_layout_merge_keys!(
	context,
	mutations,
)
	isempty(mutations) && return nothing
	isempty(context.roots) && return nothing
	mutated = IdDict{Any,Nothing}(
		storage => nothing for storage in keys(mutations)
	)
	seen = IdDict{Any,Nothing}()
	for root in keys(context.roots)
		_layout_merge_graph_has_hash_sensitive_key(
			root,
			mutated,
			seen,
		) || continue
		paths = sort!(unique!(collect(values(context.paths))))
		throw(ArgumentError(
			"Updating $(join(paths, ", ")) would mutate a mapping used " *
			"as a reachable key in a hash-based dictionary. Store mutable " *
			"identity keys in IdDict instead.",
		))
	end
	return nothing
end

function _commit_layout_merge_context!(
	context,
	mutations = _finalize_layout_merge_context(context),
)
	_require_hash_stable_layout_merge_keys!(
		context,
		mutations,
	)
	# Every candidate has the same concrete dictionary type as its target and
	# contains only concrete Symbol/String keys. Candidate construction,
	# conversion, semantic validation, and ambiguity checks all happen before
	# this commit loop touches live state.
	for (fields, candidate) in mutations
		empty!(fields)
		merge!(fields, candidate)
	end
	return nothing
end

function _layout_merge_paths(
	deep_merge_keys::Tuple{Vararg{Symbol}},
	deep_merge_paths::Tuple,
)
	paths = (
		map(key -> (key,), deep_merge_keys)...,
		deep_merge_paths...,
	)
	for path in paths
		(
			path isa Tuple &&
			!isempty(path) &&
			all(key -> key isa Symbol, path)
		) || throw(ArgumentError(
			"layout deep-merge paths must be nonempty tuples of Symbols.",
		))
	end
	return paths
end

function _layout_merge_child_paths(paths::Tuple, key::Symbol)
	return Tuple(
		path[2:end] for path in paths
		if !isempty(path) && first(path) === key
	)
end

function _normalize_nested_layout_source(
	key::Symbol,
	value,
)
	if key === :title && value isa AbstractString
		return attr(text = String(value))
	end
	return value
end

function _normalize_nested_layout_existing(
	key::Symbol,
	value,
)
	if key === :title && value isa AbstractString
		return attr(text = String(value))
	end
	return value
end

function _require_identity_preserving_layout_mapping(
	existing,
	path::String,
)
	if _requires_supported_layout_mapping_storage(existing)
		throw(ArgumentError(
			"$path uses $(typeof(existing)), whose storage cannot " *
			"be committed atomically without replacing the container and " *
			"breaking object identity. Use a PlotlyAttribute, Dict, " *
			"IdDict, or immutable NamedTuple.",
		))
	end
	return nothing
end

function _prepare_layout_mapping_merge!(
	context,
	existing,
	source,
	path::String,
	merge_paths::Tuple;
	mutate_builtin_target::Bool,
	allow_unsupported_replacement::Bool = false,
)
	_require_unambiguous_layout_mapping(
		source,
		"$path update",
	)
	_require_unambiguous_layout_mapping(
		existing,
		path,
	)
	if mutate_builtin_target &&
		!allow_unsupported_replacement
		_require_identity_preserving_layout_mapping(
			existing,
			path,
		)
	end

	source_dict = _symbol_dict(source)
	existing_fields = _builtin_layout_mapping_fields(existing)
	target_dict = if mutate_builtin_target
		_prepared_builtin_layout_contents!(
			context,
			existing,
			path,
		)
	else
		nothing
	end
	target_dict === nothing &&
		(target_dict = _symbol_dict(existing))

	processed = Set{Symbol}()
	for merge_path in merge_paths
		isempty(merge_path) && continue
		nested_key = first(merge_path)
		nested_key in processed && continue
		push!(processed, nested_key)
		haskey(source_dict, nested_key) || continue

		source_nested = _normalize_nested_layout_source(
			nested_key,
			source_dict[nested_key],
		)
		source_dict[nested_key] = source_nested
		_is_layout_mapping(source_nested) || continue

		existing_nested = _normalize_nested_layout_existing(
			nested_key,
			get(target_dict, nested_key, nothing),
		)
		child_paths = _layout_merge_child_paths(
			merge_paths,
			nested_key,
		)
		merged_nested, _ = _prepare_layout_mapping_merge!(
			context,
			existing_nested,
			source_nested,
			"$path.$nested_key",
			child_paths;
			mutate_builtin_target = mutate_builtin_target,
			allow_unsupported_replacement =
				allow_unsupported_replacement,
		)
		source_dict[nested_key] = merged_nested
	end

	merge!(target_dict, source_dict)
	preserve_existing =
		mutate_builtin_target &&
		existing_fields !== nothing
	return (
		preserve_existing ?
			existing :
			attr(target_dict),
		preserve_existing,
	)
end

function _prepare_layout_attr_merge!(
	context,
	layout::Layout,
	key::Symbol,
	source;
	drop_keys::Tuple{Vararg{Symbol}} = (),
	deep_merge_keys::Tuple{Vararg{Symbol}} = (),
	deep_merge_paths::Tuple = (),
	mutate_builtin_target::Bool = false,
	allow_unsupported_replacement::Bool = false,
)
	context.roots[layout] = nothing
	_require_unambiguous_layout_mapping(
		source,
		"layout.$key update",
	)
	source_dict = _symbol_dict(source)
	isempty(source_dict) && return false
	for k in drop_keys
		pop!(source_dict, k, nothing)
	end
	isempty(source_dict) && return false
	existing = get(layout.fields, key, nothing)
	merge_paths = _layout_merge_paths(
		deep_merge_keys,
		deep_merge_paths,
	)
	merged, preserve_existing =
		_prepare_layout_mapping_merge!(
			context,
			existing,
			source_dict,
			"layout.$key",
			merge_paths;
			mutate_builtin_target = mutate_builtin_target,
			allow_unsupported_replacement =
				allow_unsupported_replacement,
		)
	if preserve_existing
		return true
	end
	layout_contents = _prepared_builtin_layout_contents!(
		context,
		layout.fields,
		"layout",
	)
	layout_contents === nothing && throw(ArgumentError(
		"layout.fields uses $(typeof(layout.fields)); replacing " *
		"layout.$key atomically requires Dict or IdDict storage.",
	))
	layout_contents[key] = merged
	return true
end

function _merge_layout_attr!(
	layout::Layout,
	key::Symbol,
	source;
	drop_keys::Tuple{Vararg{Symbol}} = (),
	deep_merge_keys::Tuple{Vararg{Symbol}} = (),
	deep_merge_paths::Tuple = (),
	mutate_builtin_target::Bool = false,
	allow_unsupported_replacement::Bool = false,
)
	context = _new_layout_merge_context()
	changed = _prepare_layout_attr_merge!(
		context,
		layout,
		key,
		source;
		drop_keys = drop_keys,
		deep_merge_keys = deep_merge_keys,
		deep_merge_paths = deep_merge_paths,
		mutate_builtin_target = mutate_builtin_target,
		allow_unsupported_replacement =
			allow_unsupported_replacement,
	)
	changed || return nothing
	mutations = _finalize_layout_merge_context(context)
	if mutate_builtin_target
		_require_valid_finalized_layout_merge(
			mutations,
			layout,
			key,
		)
	end
	_commit_layout_merge_context!(context, mutations)
	return nothing
end

function _require_valid_finalized_layout_merge(
	mutations,
	layout::Layout,
	key::Symbol,
)
	mapping_storage_mutated = function (value)
		fields = _builtin_layout_mapping_fields(value)
		return fields !== nothing &&
			haskey(mutations, fields)
	end
	map_root_mutated = function (
		value,
		nested_keys,
		path,
	)
		mapping_storage_mutated(value) && return true
		_is_layout_mapping(value) || return false
		for (stored_key, nested) in pairs(value)
			if mapping_storage_mutated(stored_key)
				_require_unambiguous_layout_mapping(
					value,
					path,
				)
			end
			mapping_storage_mutated(nested) ||
				continue
			if !(
				stored_key isa Symbol ||
				stored_key isa String
			)
				_require_unambiguous_layout_mapping(
					value,
					path,
				)
			end
			Symbol(stored_key) in nested_keys ||
				continue
			return true
		end
		return false
	end

	map_targets = Symbol[]
	mapbox_targets = Symbol[]
	for (stored_key, value) in layout.fields
		(
			stored_key isa Symbol ||
			stored_key isa String
		) || continue
		candidate_key = Symbol(stored_key)
		if _is_modern_map_layout_key(candidate_key)
			map_root_mutated(
				value,
				(:center, :bounds),
				"layout.$candidate_key",
			) || continue
			candidate_key in map_targets ||
				push!(map_targets, candidate_key)
		elseif startswith(String(candidate_key), "mapbox")
			map_root_mutated(
				value,
				(:center,),
				"layout.$candidate_key",
			) || continue
			candidate_key in mapbox_targets ||
				push!(mapbox_targets, candidate_key)
		end
	end
	if _is_modern_map_layout_key(key)
		key in map_targets || push!(map_targets, key)
	elseif startswith(String(key), "mapbox")
		key in mapbox_targets ||
			push!(mapbox_targets, key)
	end

	if !isempty(map_targets)
		_require_valid_finalized_map_layouts(
			mutations,
			layout,
			map_targets,
		)
	end
	if !isempty(mapbox_targets)
		_require_valid_finalized_mapbox_layouts(
			mutations,
			layout,
			mapbox_targets,
		)
	end
	return nothing
end

function _apply_source_layout_to_added_traces!(
	target::Plot,
	source::Plot,
	start_index::Int,
)
	start_index > length(target.data) && return nothing
	processed = Set{Symbol}()
	context = _new_layout_merge_context()
	context.roots[target] = nothing
	context.roots[source] = nothing
	changed_keys = Symbol[]

	function record_change!(key::Symbol, changed::Bool)
		changed || return nothing
		key in changed_keys || push!(changed_keys, key)
		return nothing
	end

	for idx in start_index:length(target.data)
		fields = target.data[idx].fields

		if haskey(fields, :xaxis) || haskey(fields, :yaxis)
			xref = String(get(fields, :xaxis, "x"))
			yref = String(get(fields, :yaxis, "y"))
			xkey = _axis_layout_key(xref, :x)
			ykey = _axis_layout_key(yref, :y)

			if !(xkey in processed)
				source_axis =
					get(
						source.layout.fields,
						:xaxis,
						nothing,
					)
				filtered_source =
					_symbol_dict(source_axis)
				pop!(filtered_source, :domain, nothing)
				pop!(filtered_source, :anchor, nothing)
				preserve_root =
					!isempty(filtered_source) &&
					_preserve_layout_mapping_root(
						target,
						xkey,
						haskey(
							filtered_source,
							:title,
						) ?
							(:title,) :
							(),
					)
				record_change!(
					xkey,
					_prepare_layout_attr_merge!(
						context,
						target.layout,
						xkey,
						source_axis;
						drop_keys = (:domain, :anchor),
						deep_merge_paths =
							_AXIS_LAYOUT_MERGE_PATHS,
						mutate_builtin_target =
							preserve_root,
						allow_unsupported_replacement =
							true,
					),
				)
				push!(processed, xkey)
			end
			if !(ykey in processed)
				source_axis =
					get(
						source.layout.fields,
						:yaxis,
						nothing,
					)
				filtered_source =
					_symbol_dict(source_axis)
				pop!(filtered_source, :domain, nothing)
				pop!(filtered_source, :anchor, nothing)
				preserve_root =
					!isempty(filtered_source) &&
					_preserve_layout_mapping_root(
						target,
						ykey,
						haskey(
							filtered_source,
							:title,
						) ?
							(:title,) :
							(),
					)
				record_change!(
					ykey,
					_prepare_layout_attr_merge!(
						context,
						target.layout,
						ykey,
						source_axis;
						drop_keys = (:domain, :anchor),
						deep_merge_paths =
							_AXIS_LAYOUT_MERGE_PATHS,
						mutate_builtin_target =
							preserve_root,
						allow_unsupported_replacement =
							true,
					),
				)
				push!(processed, ykey)
			end
		end

		if haskey(fields, :scene)
			scene_key = Symbol(String(get(fields, :scene, "scene")))
			if !(scene_key in processed)
				record_change!(
					scene_key,
					_prepare_scene_layout_attr_merge!(
						context,
						target.layout,
						scene_key,
						get(source.layout.fields, :scene, nothing),
					),
				)
				push!(processed, scene_key)
			end
		end

		if haskey(fields, :geo)
			geo_key = Symbol(String(get(fields, :geo, "geo")))
			if !(geo_key in processed)
				record_change!(
					geo_key,
					_prepare_layout_attr_merge!(
						context,
						target.layout,
						geo_key,
						get(source.layout.fields, :geo, nothing);
						drop_keys = (:domain,),
						deep_merge_paths =
							_GEO_LAYOUT_MERGE_PATHS,
						mutate_builtin_target = true,
					),
				)
				push!(processed, geo_key)
			end
		end

		if haskey(fields, :subplot)
			subplot_key = Symbol(String(fields[:subplot]))
			source_kind, _ = _trace_subplot_kind(target.data[idx])
			source_key = Symbol(source_kind)
			if !(subplot_key in processed)
				changed = if source_kind == "ternary"
					_prepare_ternary_layout_attr_merge!(
						context,
						target.layout,
						subplot_key,
						get(
							source.layout.fields,
							source_key,
							nothing,
						),
					)
				else
					merge_paths =
						source_kind == "polar" ?
						_POLAR_LAYOUT_MERGE_PATHS :
						source_kind == "mapbox" ?
							_MAPBOX_LAYOUT_MERGE_PATHS :
							source_kind == "map" ?
								_MAP_LAYOUT_MERGE_PATHS :
								()
					_prepare_layout_attr_merge!(
						context,
						target.layout,
						subplot_key,
						get(
							source.layout.fields,
							source_key,
							nothing,
						);
						drop_keys = (:domain,),
						deep_merge_paths = merge_paths,
						mutate_builtin_target = true,
					)
				end
				record_change!(subplot_key, changed)
				push!(processed, subplot_key)
			end
		end
	end

	for key in (:font, :coloraxis)
		record_change!(
			key,
			_prepare_layout_attr_merge!(
				context,
				target.layout,
				key,
				get(source.layout.fields, key, nothing);
				mutate_builtin_target = true,
			),
		)
	end

	isempty(changed_keys) && return nothing
	mutations = _finalize_layout_merge_context(context)
	for key in changed_keys
		_require_valid_finalized_layout_merge(
			mutations,
			target.layout,
			key,
		)
	end
	_commit_layout_merge_context!(context, mutations)
	return nothing
end

const _SUBPLOT_ROOT_LAYOUT_MODES = (:barmode, :boxmode, :violinmode)

function _apply_source_root_layout_modes!(
	target::Plot,
	source::Plot;
	overwrite_keys::Tuple{Vararg{Symbol}} = (),
)
	for key in _SUBPLOT_ROOT_LAYOUT_MODES
		haskey(source.layout.fields, key) || continue
		if key in overwrite_keys
			target.layout.fields[key] = source.layout.fields[key]
		else
			get!(target.layout.fields, key, source.layout.fields[key])
		end
	end
	return nothing
end

function _subplot_delegate_mutator_impl!(
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
	mutator(_StagedPlotMutation(tmp), args...; kwargs...)

	p = _plot_obj(sf.fig)
	target_ref = _validate_subplot_traces!(
		p,
		tmp.data,
		r,
		c;
		secondary_y = secondary_y,
	)
	routed = Vector{GenericTrace}()
	sizehint!(routed, length(tmp.data))
	for trace in tmp.data
		# The delegate owns `trace`, so only its fields dictionary needs a new
		# container before subplot references are merged. PlotlyBase.add_trace!
		# deep-copies every payload, which turns range/view-backed high-level
		# inputs into O(n) allocations without providing additional isolation.
		routed_trace = GenericTrace(copy(trace.fields))
		merge!(routed_trace, target_ref.trace_kwargs)
		push!(routed, routed_trace)
	end

	start_index = length(p.data) + 1
	append!(p.data, routed)
	_apply_source_layout_to_added_traces!(p, tmp, start_index)
	explicit_modes = get(values(kwargs), :barmode, "") == "" ?
		() :
		(:barmode,)
	_apply_source_root_layout_modes!(
		p,
		tmp;
		overwrite_keys = explicit_modes,
	)

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

function _subplot_delegate_mutator!(
	sf::SubplotFigure,
	mutator::Function,
	args...;
	kwargs...,
)
	metadata_lock = getfield(sf, :_lock)
	lock(metadata_lock)
	try
		staged_ref =
			Ref{Union{Nothing,SubplotFigure}}(nothing)
		result = Ref{Any}(nothing)
		mutation = function (candidate)
			staged = _staged_subplot_figure(sf, candidate)
			staged_ref[] = staged
			result[] = _subplot_delegate_mutator_impl!(
				staged,
				mutator,
				args...;
				kwargs...,
			)
			return nothing
		end
		commit_callback = _ -> _commit_subplot_metadata!(
			sf,
			something(staged_ref[]),
			_SUBPLOT_SELECTION_METADATA_FIELDS,
		)

		fig = getfield(sf, :fig)
		# Per-subplot legends rewrite existing traces. The append-only fast path
		# intentionally shares those trace roots, so retain full staging whenever
		# legend assignment is enabled.
		if sf.per_subplot_legends && fig isa SyncPlot
			_mutate_and_refresh_syncplot!(
				mutation,
				fig;
				commit_callback = commit_callback,
			)
		elseif sf.per_subplot_legends
			_transactional_full_plot_mutation!(
				mutation,
				fig;
				commit_callback = commit_callback,
			)
		elseif fig isa SyncPlot
			prepare = (target, current) ->
				_prepare_high_level_plot_mutation_transaction(
					target,
					current,
					mutation,
					mutation,
					commit_callback,
				)
			_syncplot_transaction!(fig, prepare)
		else
			_transactional_high_level_model_mutation!(
				mutation,
				mutation,
				fig,
				commit_callback,
			)
		end
		return result[] === staged_ref[] ? sf : result[]
	finally
		unlock(metadata_lock)
	end
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

# `kind` is the subplot kind of the cell (:geo or :mapbox). MapLibre `map`
# cells are updated by `_transactional_modern_map_subplot_update!`
# (electron_backend.jl), which owns the alias-preserving map transaction.
function _subplot_geographic_layout_key(
	sf::SubplotFigure,
	row::Int,
	col::Int,
	kind::Symbol,
)
	kind in (:geo, :mapbox) || throw(ArgumentError(
		"Unsupported geographic subplot kind `$kind`.",
	))
	expected_kind = String(kind)
	target_ref = _subplot_target_ref(_plot_obj(sf.fig), row, col)
	actual_kind = String(target_ref.subplot_kind)
	actual_kind == expected_kind || throw(ArgumentError(
		"Selected subplot cell ($(row), $(col)) is '$actual_kind', " *
		"not '$expected_kind'.",
	))
	return only(target_ref.layout_keys)
end

function _subplot_geographic_update_impl!(
	sf::SubplotFigure,
	updater::Function,
	kind::Symbol,
	with::PlotlyBase.PlotlyAttribute;
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	kwargs...,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	key = _subplot_geographic_layout_key(sf, r, c, kind)
	layout = _plot_layout(sf.fig)
	temporary = Layout()
	existing = get(layout.fields, key, nothing)
	# A `nothing` cell root (e.g. after `relayout!(sf; geo2 = nothing)`) is
	# Plotly's "all defaults"; update it like an empty object.
	temporary.fields[kind] =
		existing === nothing ? attr() : deepcopy(existing)
	updater(temporary, with; kwargs...)
	kind === :mapbox && _require_valid_mapbox_layouts(temporary)
	_merge_layout_attr!(
		layout,
		key,
		get(temporary.fields, kind, nothing);
		drop_keys = (:domain,),
		deep_merge_paths =
			kind === :geo ?
			_GEO_LAYOUT_MERGE_PATHS :
			_MAPBOX_LAYOUT_MERGE_PATHS,
		mutate_builtin_target = true,
	)
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

# The grid owns every cell's `domain`; a per-cell update drops it. Say so
# instead of silently ignoring the caller's value. Called before the
# transaction starts so staging cannot emit the warning twice.
function _warn_ignored_subplot_domain(
	fn::AbstractString,
	with::PlotlyBase.PlotlyAttribute,
	kwargs,
)
	requested = haskey(_symbol_dict(with), :domain) ||
		any(pairs(kwargs)) do (key, _)
			name = String(key)
			name == "domain" || startswith(name, "domain_")
		end
	requested && @warn "$fn on a SubplotFigure cell ignores `domain`: " *
		"subplot domains are managed by the `subplots(...)` grid. Use " *
		"`relayout!(sf; <key>_domain = ...)` to move a cell explicitly."
	return nothing
end

function _subplot_geographic_update!(
	sf::SubplotFigure,
	updater::Function,
	kind::Symbol,
	with::PlotlyBase.PlotlyAttribute;
	kwargs...,
)
	return _transactional_subplot_mutation!(
		_subplot_geographic_update_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		updater,
		kind,
		with;
		kwargs...,
	)
end

"""
	update_geos!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, kwargs...)

Update the `geo` layout object of ONE `SubplotFigure` cell: the cell given by
`row`/`col` (pass both), or the active cell (see [`subplot!`](@ref)) when they
are omitted. The updated cell becomes the active cell. Keywords are Plotly
`layout.geo` attributes (`showland=true`, `projection_type="mercator"`, …);
nested `projection` settings merge with the existing ones.

The grid manages cell domains, so a `domain` value is ignored with a warning.
Throws `ArgumentError` (leaving the figure unchanged) when the cell is not a
`geo` cell. To update every geo object of the grid at once, call
`update_geos!(sf.fig; ...)` on the underlying `Plot`/`SyncPlot`.
Returns `sf`.

# Example
```julia
sf = subplots(1, 2; sync=false, specs=[Spec(kind="geo") Spec(kind="geo")])
update_geos!(sf; row=1, col=2, showland=true, landcolor="lightgray")
```
"""
function PlotlyBase.update_geos!(
	sf::SubplotFigure,
	with::PlotlyBase.PlotlyAttribute = attr();
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	kwargs...,
)
	_warn_ignored_subplot_domain("update_geos!", with, kwargs)
	return _subplot_geographic_update!(
		sf,
		PlotlyBase.update_geos!,
		:geo,
		with;
		row = row,
		col = col,
		kwargs...,
	)
end

"""
	update_mapboxes!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, kwargs...)

Update the legacy `mapbox` layout object of ONE `SubplotFigure` cell: the
cell given by `row`/`col` (pass both), or the active cell when they are
omitted. The updated cell becomes the active cell. Keywords are Plotly
`layout.mapbox` attributes (`style`, `zoom`, `center_lon`, `bearing`, …);
a partial `center` update keeps the unspecified coordinate.

`style` must be a nonempty style name/URL or a nonempty style object, and
the view values must be finite numbers; invalid values throw `ArgumentError`
before anything changes. The grid manages cell domains, so a `domain` value
is ignored with a warning. To update every mapbox object of the grid at
once, call `update_mapboxes!(sf.fig; ...)`. Returns `sf`.

# Example
```julia
sf = subplots(1, 2; sync=false, specs=[Spec(kind="mapbox") Spec(kind="mapbox")])
update_mapboxes!(sf; row=1, col=2, style="carto-positron", zoom=3)
```
"""
function PlotlyBase.update_mapboxes!(
	sf::SubplotFigure,
	with::PlotlyBase.PlotlyAttribute = attr();
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	kwargs...,
)
	_warn_ignored_subplot_domain("update_mapboxes!", with, kwargs)
	return _subplot_geographic_update!(
		sf,
		PlotlyBase.update_mapboxes!,
		:mapbox,
		with;
		row = row,
		col = col,
		kwargs...,
	)
end

"""
	update_maps!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, kwargs...)

Update the MapLibre `map` layout object of ONE `SubplotFigure` cell: the cell
given by `row`/`col` (pass both), or the active cell when they are omitted.
The updated cell becomes the active cell. Keywords are the same as for
`update_maps!(fig; ...)`: nested `center`/`bounds` merge, invalid view or
style values throw `ArgumentError` before anything changes, and an error is
also raised when the cell is not a `map` cell.

The grid manages cell domains, so a `domain` value is ignored with a warning.
To update every map cell of the grid at once, call `update_maps!(sf.fig; ...)`.
Returns `sf`.

# Example
```julia
sf = subplots(1, 2; sync=false, specs=[Spec(kind="map") Spec(kind="map")])
update_maps!(sf; row=1, col=1, zoom=2, center_lon=10)
update_maps!(sf.fig; style="carto-positron")   # every map cell
```
"""
function update_maps!(
	sf::SubplotFigure,
	with::PlotlyBase.PlotlyAttribute = attr();
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	kwargs...,
)
	_warn_ignored_subplot_domain("update_maps!", with, kwargs)
	return _transactional_modern_map_subplot_update!(
		sf,
		with;
		row = row,
		col = col,
		kwargs...,
	)
end

function _subplot_xlabel_impl!(
	sf::SubplotFigure,
	label::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	xkey, _ = _subplot_xy_axis_keys(sf, r, c)
	preserve_root =
		_preserve_subplot_axis_root(sf, xkey)
	_merge_layout_attr!(
		_plot_layout(sf.fig),
		xkey,
		attr(title_text = String(label));
		deep_merge_paths = _AXIS_LAYOUT_MERGE_PATHS,
		mutate_builtin_target = preserve_root,
		allow_unsupported_replacement = true,
	)
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

"""
	xlabel!(sf, label; row=nothing, col=nothing)

Set the x-axis title of one [`SubplotFigure`](@ref) cell. When `row` and `col`
are omitted, update the currently active cell selected by [`subplot!`](@ref);
otherwise both must be given. Returns `sf` for chaining.
"""
function xlabel!(
	sf::SubplotFigure,
	label::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	return _transactional_subplot_mutation!(
		_subplot_xlabel_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		label;
		row = row,
		col = col,
	)
end

function _subplot_ylabel_impl!(
	sf::SubplotFigure,
	label::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	_, ykey = _subplot_xy_axis_keys(sf, r, c; secondary_y = secondary_y)
	preserve_root =
		_preserve_subplot_axis_root(sf, ykey)
	_merge_layout_attr!(
		_plot_layout(sf.fig),
		ykey,
		attr(title_text = String(label));
		deep_merge_paths = _AXIS_LAYOUT_MERGE_PATHS,
		mutate_builtin_target = preserve_root,
		allow_unsupported_replacement = true,
	)
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

"""
	ylabel!(sf, label; row=nothing, col=nothing, secondary_y=false)

Set the y-axis title of one [`SubplotFigure`](@ref) cell. When `row` and `col`
are omitted, update the active cell. Pass `secondary_y=true` to target a
secondary-y cell created by an appropriate subplot spec. Returns `sf`.
"""
function ylabel!(
	sf::SubplotFigure,
	label::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	return _transactional_subplot_mutation!(
		_subplot_ylabel_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		label;
		row = row,
		col = col,
		secondary_y = secondary_y,
	)
end

function _subplot_xrange_impl!(
	sf::SubplotFigure,
	range::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	length(range) == 2 || throw(ArgumentError("`range` must have length 2."))
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	xkey, _ = _subplot_xy_axis_keys(sf, r, c)
	preserve_root =
		_preserve_subplot_axis_root(
			sf,
			xkey,
			(),
		)
	_merge_layout_attr!(
		_plot_layout(sf.fig),
		xkey,
		attr(range = collect(range));
		mutate_builtin_target = preserve_root,
	)
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

"""
	xrange!(sf, range; row=nothing, col=nothing)

Set the two-element x-axis `range` of one [`SubplotFigure`](@ref) cell. When
`row` and `col` are omitted, update the active cell. Returns `sf`.
"""
function xrange!(
	sf::SubplotFigure,
	range::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	length(range) == 2 ||
		throw(ArgumentError("`range` must have length 2."))
	return _transactional_subplot_mutation!(
		_subplot_xrange_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		range;
		row = row,
		col = col,
	)
end

function _subplot_yrange_impl!(
	sf::SubplotFigure,
	range::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	length(range) == 2 || throw(ArgumentError("`range` must have length 2."))
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	_, ykey = _subplot_xy_axis_keys(sf, r, c; secondary_y = secondary_y)
	preserve_root =
		_preserve_subplot_axis_root(
			sf,
			ykey,
			(),
		)
	_merge_layout_attr!(
		_plot_layout(sf.fig),
		ykey,
		attr(range = collect(range));
		mutate_builtin_target = preserve_root,
	)
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

"""
	yrange!(sf, range; row=nothing, col=nothing, secondary_y=false)

Set the two-element y-axis `range` of one [`SubplotFigure`](@ref) cell. When
`row` and `col` are omitted, update the active cell. Pass `secondary_y=true`
to target a secondary-y subplot axis. Returns `sf`.
"""
function yrange!(
	sf::SubplotFigure,
	range::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
)
	length(range) == 2 ||
		throw(ArgumentError("`range` must have length 2."))
	return _transactional_subplot_mutation!(
		_subplot_yrange_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		range;
		row = row,
		col = col,
		secondary_y = secondary_y,
	)
end

# Scatter-family SubplotFigure methods go through `_scat_subplot_delegate!`,
# which gives the scratch figure the real figure's default colours and legend
# groups.
function plot_scatter!(
	sf::SubplotFigure,
	x::AbstractArray,
	y::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _scat_subplot_delegate!(
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
	y::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _scat_subplot_delegate!(
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
	x::AbstractArray,
	y::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _scat_subplot_delegate!(
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
	y::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _scat_subplot_delegate!(
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
	theta::AbstractArray,
	r::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _scat_subplot_delegate!(
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray},
	U::AbstractArray;
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
	U::AbstractArray;
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray},
	U::AbstractArray;
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
	U::AbstractArray;
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
	X::AbstractArray,
	Y::AbstractArray,
	Z::AbstractArray;
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
	Z::AbstractArray;
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

# Extended chart mutators need the same explicit positional signatures as their
# Plot/SyncPlot counterparts. A catch-all SubplotFigure method would hide
# misspelled or otherwise unsupported call shapes.
for (fn, nargs) in (
	(:plot_pie!, 1),
	(:plot_funnelarea!, 1),
	(:plot_parcoords!, 1),
	(:plot_sunburst!, 2),
	(:plot_treemap!, 2),
	(:plot_sankey!, 3),
)
	@eval function $fn(
		sf::SubplotFigure,
		args::Vararg{AbstractVector, $nargs};
		kwargs...,
	)
		return _subplot_delegate_mutator!(sf, $fn, args...; kwargs...)
	end
end

# Geographic (geo, mapbox, MapLibre map) mutators on a SubplotFigure: append
# to the cell given by `row`/`col` (both or neither; default: the active
# cell), which must be of the trace's subplot kind. Every positional shape
# of the Plot-level method has an explicit method here.
for fn in (:plot_choropleth!, :plot_scattergeo!, :plot_scattermap!)
	@eval function $fn(
		sf::SubplotFigure,
		first_values::AbstractVector,
		second_values::AbstractVector;
		row::Union{Nothing,Integer} = nothing,
		col::Union{Nothing,Integer} = nothing,
		kwargs...,
	)
		return _subplot_delegate_mutator!(
			sf,
			$fn,
			first_values,
			second_values;
			row = row,
			col = col,
			kwargs...,
		)
	end
end

# `z = nothing` (equal weights) is part of the documented signature, so the
# explicit `nothing` must route to the cell like an omitted `z`.
function plot_densitymap!(
	sf::SubplotFigure,
	lon::AbstractVector,
	lat::AbstractVector,
	z::Union{Nothing,AbstractVector} = nothing;
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_densitymap!,
		lon,
		lat,
		z;
		row = row,
		col = col,
		kwargs...,
	)
end

function plot_choroplethmap!(
	sf::SubplotFigure,
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(
		sf,
		plot_choroplethmap!,
		geojson,
		locations,
		z;
		row = row,
		col = col,
		kwargs...,
	)
end

# Legacy mapbox cells additionally receive the token-free default style when
# neither the call nor the cell sets one (see `_subplot_mapbox_cell_style`).
function plot_scattermapbox!(
	sf::SubplotFigure,
	lon::AbstractVector,
	lat::AbstractVector;
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	style = nothing,
	kwargs...,
)
	return _subplot_mapbox_delegate!(
		sf,
		plot_scattermapbox!,
		(lon, lat);
		row = row,
		col = col,
		style = style,
		kwargs...,
	)
end

function plot_densitymapbox!(
	sf::SubplotFigure,
	lon::AbstractVector,
	lat::AbstractVector,
	z::AbstractVector;
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	style = nothing,
	kwargs...,
)
	return _subplot_mapbox_delegate!(
		sf,
		plot_densitymapbox!,
		(lon, lat, z);
		row = row,
		col = col,
		style = style,
		kwargs...,
	)
end

function plot_choroplethmapbox!(
	sf::SubplotFigure,
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	style = nothing,
	kwargs...,
)
	return _subplot_mapbox_delegate!(
		sf,
		plot_choroplethmapbox!,
		(geojson, locations, z);
		row = row,
		col = col,
		style = style,
		kwargs...,
	)
end

function plot_indicator!(
	sf::SubplotFigure,
	value::Real;
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_indicator!, value; kwargs...)
end

for (fn, nargs) in (
	(:plot_funnel!, 2),
	(:plot_candlestick!, 5),
	(:plot_ohlc!, 5),
	(:plot_histogram2d!, 2),
	(:plot_ternary!, 3),
	(:plot_streamtube!, 6),
)
	@eval function $fn(
		sf::SubplotFigure,
		args::Vararg{Union{AbstractRange, Vector, SubArray}, $nargs};
		kwargs...,
	)
		return _subplot_delegate_mutator!(sf, $fn, args...; kwargs...)
	end
end

for (fn, nargs) in (
	(:plot_waterfall!, 2),
	(:plot_mesh3d!, 3),
	(:plot_isosurface!, 4),
	(:plot_volume!, 4),
)
	@eval function $fn(
		sf::SubplotFigure,
		args::Vararg{Union{AbstractVector, SubArray}, $nargs};
		kwargs...,
	)
		return _subplot_delegate_mutator!(sf, $fn, args...; kwargs...)
	end
end

function plot_image!(
	sf::SubplotFigure,
	z::AbstractArray;
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_image!, z; kwargs...)
end

# SubplotFigure methods of plot_area! for every array type, through the
# scatter-family delegate (real-figure colours and style cycle). The
# Plot/SyncPlot methods are generated from the untyped ones (see
# `_install_transactional_high_level_plot_wrappers!`).
function plot_area!(
	sf::SubplotFigure,
	x::AbstractArray,
	y::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _scat_subplot_delegate!(
		sf,
		plot_area!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

function plot_area!(
	sf::SubplotFigure,
	y::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _scat_subplot_delegate!(
		sf,
		plot_area!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		kwargs...,
	)
end

"""
	plot!(fig, x, y; kwargs...)
	plot!(fig, y; kwargs...)

MATLAB-like alias for [`plot_scatter!`](@ref): appends line/marker traces to
a `Plot`, a [`SyncPlot`](@ref) or a `SubplotFigure` (active cell, or
`row`/`col`) and accepts the same keywords. Returns `nothing` for a
`Plot`/`SyncPlot` and the figure for a `SubplotFigure`.
"""
function plot!(
	sf::SubplotFigure,
	args...;
	kwargs...,
)
	return plot_scatter!(sf, args...; kwargs...)
end

function plot!(
	fig::Union{Plot, SyncPlot},
	args...;
	kwargs...,
)
	return plot_scatter!(fig, args...; kwargs...)
end

#region 1D Plot

# Normalize a scalar-or-vector per-series keyword to exactly `n` values.
# Scalars broadcast, short vectors retain `default` for missing series, and
# overlong vectors are intentionally truncated instead of indexing past the
# destination. The explicit element type keeps optional values such as
# `Union{Nothing,Bool}` type-stable.
function _series_kwarg_vector(
	value,
	n::Int,
	default,
	::Type{T},
) where {T}
	n >= 0 || throw(ArgumentError("series count must be nonnegative, got $n"))
	out = Vector{T}(undef, n)
	fill!(out, default)
	if value isa AbstractVector
		for (destination, source) in
			zip(eachindex(out), eachindex(value))
			out[destination] = value[source]
		end
	else
		fill!(out, value)
	end
	return out
end

function _string_kwarg_vector(
	value::Union{AbstractString, AbstractVector{<:AbstractString}},
	n::Int,
)
	return _series_kwarg_vector(value, n, "", String)
end

function _first_or_empty(
	value::Union{AbstractString, AbstractVector{<:AbstractString}},
)
	if value isa AbstractVector
		return isempty(value) ? "" : String(first(value))
	end
	return String(value)
end

# Reduce a possibly-vector styling kwarg to a scalar for a single-trace plot.
# Mirrors `_first_or_empty` but for numeric / Bool kwargs: an empty vector
# falls back to `default`, otherwise the first element is used.
_scalar_or_first(value, default) = value isa AbstractVector ? (isempty(value) ? default : value[1]) : value

# A multi-series input is any abstract vector whose elements are themselves
# abstract vectors.  Keeping this type-driven avoids scanning the data and
# correctly handles ranges, views, and abstractly typed collections.
@inline _is_nested_series(::AbstractVector{<:AbstractVector}; who::AbstractString = "") = true
@inline _is_nested_series(::Any; who::AbstractString = "") = false

# Abstractly typed containers (`ys = []; push!(ys, v)`, JSON-parsed data) carry
# no element type to dispatch on, so their elements are inspected. A container
# mixing series vectors with scalar values is ambiguous and is rejected rather
# than plotted as one garbage series. `who` (the public function name), when
# given, prefixes the error message.
function _is_nested_series(values::AbstractVector; who::AbstractString = "")
	isconcretetype(eltype(values)) && return false
	isempty(values) && return false
	nested_count = count(value -> value isa AbstractVector, values)
	nested_count == 0 && return false
	nested_count == length(values) ||
		throw(ArgumentError(
			(isempty(who) ? "" : "$(who): ") *
			"multi-series input mixes $(nested_count) series vector(s) with " *
			"$(length(values) - nested_count) scalar value(s); pass either one " *
			"flat series or a vector whose elements are all series vectors.",
		))
	return true
end

function _apply_nested_layout_mode!(
	fig,
	values,
	key::Symbol,
	mode::String,
)
	if _is_nested_series(values) && length(values) > 1
		get!(_plot_layout(fig).fields, key, mode)
	end
	return nothing
end

function _apply_explicit_layout_mode!(
	fig,
	key::Symbol,
	mode::String,
)
	isempty(mode) || (_plot_layout(fig).fields[key] = mode)
	return nothing
end

# Classify a (primary, secondary) coordinate pair as flat or multi-series and
# check that their series counts agree. `who` (the public function name), when
# given, prefixes the error message as "<function>: <message>".
function _nested_coordinate_mode(
	primary,
	secondary,
	primary_name::Symbol,
	secondary_name::Symbol;
	who::AbstractString = "",
)
	prefix = isempty(who) ? "" : "$(who): "
	primary_nested = _is_nested_series(primary; who = who)
	secondary_nested = _is_nested_series(secondary; who = who)
	if secondary_nested
		primary_nested || throw(ArgumentError(
			"$(prefix)`$secondary_name` contains multiple series but `$primary_name` contains one series.",
		))
		length(secondary) == length(primary) || throw(ArgumentError(
			"$(prefix)`$secondary_name` and `$primary_name` must contain the same number of series; " *
			"got $(length(secondary)) and $(length(primary)).",
		))
	end
	return primary_nested, secondary_nested
end

function _scatter3d_trace(
	x,
	y,
	z;
	mode::String,
	color::String,
	legend::String,
	marker_size::Int,
	marker_symbol::String,
	linewidth::Real,
	showlegend::Union{Nothing, Bool},
)
	trace_kw = Dict{Symbol, Any}(
		:x => x,
		:y => y,
		:z => z,
		:mode => mode,
		:line => attr(color = color),
		:name => legend,
	)
	marker_options = Dict{Symbol, Any}()
	marker_size > 0 && (marker_options[:size] = marker_size)
	isempty(marker_symbol) ||
		(marker_options[:symbol] = marker_symbol)
	isempty(marker_options) ||
		(trace_kw[:marker] = attr(; marker_options...))
	linewidth > 0 &&
		(trace_kw[:line][:width] = linewidth)
	showlegend === nothing ||
		(trace_kw[:showlegend] = showlegend)
	return scatter3d(; trace_kw...)
end

function _scatter3d_traces(
	x,
	y,
	z;
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	z_nested, x_nested =
		_nested_coordinate_mode(z, x, :z, :x)
	_, y_nested =
		_nested_coordinate_mode(z, y, :z, :y)

	if !z_nested
		mode_value = _first_or_empty(mode)
		isempty(mode_value) && (mode_value = "lines")
		return _scatter3d_trace(
			x,
			y,
			z;
			mode = mode_value,
			color = _first_or_empty(color),
			legend = _first_or_empty(legend),
			marker_size = _scalar_or_first(marker_size, 0),
			marker_symbol = _first_or_empty(marker_symbol),
			linewidth = _scalar_or_first(linewidth, 0),
			showlegend = _scalar_or_first(showlegend, nothing),
		)
	end

	series_count = length(z)
	mode_values =
		_series_kwarg_vector(mode, series_count, "lines", String)
	color_values =
		_series_kwarg_vector(color, series_count, "", String)
	legend_values =
		_series_kwarg_vector(legend, series_count, "", String)
	marker_size_values =
		_series_kwarg_vector(marker_size, series_count, 0, Int)
	marker_symbol_values =
		_series_kwarg_vector(marker_symbol, series_count, "", String)
	linewidth_values =
		_series_kwarg_vector(linewidth, series_count, 0.0, Float64)
	showlegend_values = _series_kwarg_vector(
		showlegend,
		series_count,
		nothing,
		Union{Nothing, Bool},
	)

	traces = Vector{GenericTrace}(undef, series_count)
	for index in eachindex(z)
		traces[index] = _scatter3d_trace(
			x_nested ? x[index] : x,
			y_nested ? y[index] : y,
			z[index];
			mode = mode_values[index],
			color = color_values[index],
			legend = legend_values[index],
			marker_size = marker_size_values[index],
			marker_symbol = marker_symbol_values[index],
			linewidth = linewidth_values[index],
			showlegend = showlegend_values[index],
		)
	end
	return traces
end

# Plotly `error_x` / `error_y` attribute of one trace. A vector gives symmetric
# data errors; a `(minus, plus)` tuple gives asymmetric ones (`symmetric =
# false`, `array` = plus, `arrayminus` = minus). Arrays are stored by reference.
function _error_bar_attr(entry)
	if entry isa Tuple
		minus, plus = entry
		return attr(
			type = "data",
			symmetric = false,
			array = plus,
			arrayminus = minus,
			visible = true,
		)
	end
	return attr(type = "data", array = entry, visible = true)
end

# Split an `error_x` / `error_y` keyword into one entry per trace (`nothing`
# means no error bars on that trace):
# - `nothing`: no error bars;
# - a flat vector: the same symmetric errors on every trace;
# - a vector of vectors: one symmetric error vector per trace;
# - a `(minus, plus)` tuple of flat vectors: the same asymmetric errors on
#   every trace;
# - a `(minus, plus)` tuple of vectors of vectors, or a vector of
#   `(minus, plus)` tuples: one asymmetric pair per trace.
# A per-trace list shorter than the trace count leaves the remaining traces
# without error bars and surplus entries are ignored (the 1.x leniency of the
# per-series keywords). The `minus` and `plus` lists of a per-trace asymmetric
# pair must hold the same number of series.
function _error_bar_entries(
	err,
	n::Int,
	name::AbstractString = "error",
	who::AbstractString = "",
)
	prefix = isempty(who) ? "" : "$(who): "
	entries = Vector{Any}(nothing, n)
	err === nothing && return entries
	asymmetric_pair = function (pair)
		(pair isa Tuple && length(pair) == 2) || throw(ArgumentError(
			"$(prefix)an asymmetric `$(name)` is a `(minus, plus)` tuple; got $(repr(pair)).",
		))
		return (pair[1], pair[2])
	end
	if err isa Tuple
		minus, plus = asymmetric_pair(err)
		(minus isa AbstractVector && plus isa AbstractVector) || throw(ArgumentError(
			"$(prefix)`$(name) = (minus, plus)` needs two vectors; got " *
			"($(typeof(minus)), $(typeof(plus))).",
		))
		minus_nested = _is_nested_series(minus; who = who)
		minus_nested == _is_nested_series(plus; who = who) || throw(ArgumentError(
			"$(prefix)`$(name) = (minus, plus)`: both must be flat vectors or " *
			"both vectors of vectors (one per series).",
		))
		if minus_nested
			length(minus) == length(plus) || throw(ArgumentError(
				"$(prefix)`$(name) = (minus, plus)`: `minus` has $(length(minus)) " *
				"series but `plus` has $(length(plus)).",
			))
			for (index, minus_i, plus_i) in zip(1:n, minus, plus)
				entries[index] = (minus_i, plus_i)
			end
		else
			fill!(entries, (minus, plus))
		end
	elseif err isa AbstractVector
		if !isempty(err) && first(err) isa Tuple
			for (index, pair) in zip(1:n, err)
				entries[index] = asymmetric_pair(pair)
			end
		elseif _is_nested_series(err; who = who)
			for (index, series_errors) in zip(1:n, err)
				entries[index] = series_errors
			end
		else
			fill!(entries, err)
		end
	else
		throw(ArgumentError(
			"$(prefix)`$(name)` must be nothing, a vector, a vector of vectors " *
			"(one per series) or a `(minus, plus)` tuple; got $(typeof(err)).",
		))
	end
	return entries
end

# Attach data error bars to one or more traces. `error_x`/`error_y` take the
# forms listed at `_error_bar_entries`; `nothing` leaves that axis untouched.
function _set_error_bars!(trace, error_x, error_y)
	(error_x === nothing && error_y === nothing) && return nothing
	traces = trace isa AbstractVector ? trace : (trace,)
	n = length(traces)
	x_entries = _error_bar_entries(error_x, n, "error_x")
	y_entries = _error_bar_entries(error_y, n, "error_y")
	for (index, t) in enumerate(traces)
		x_entries[index] === nothing ||
			(t.error_x = _error_bar_attr(x_entries[index]))
		y_entries[index] === nothing ||
			(t.error_y = _error_bar_attr(y_entries[index]))
	end
	return nothing
end

# Default x coordinates `0:length(y)-1` of a y-only call (one range per
# series for multi-series `y`). `who` prefixes the error for ambiguous input.
function _auto_xvalues(y; who::AbstractString = "")
	if _is_nested_series(y; who = who)
		x = Vector{UnitRange{Int}}(undef, length(y))
		if y isa LinRange{<:Vector}
			# A built-in LinRange of ordinary vectors preserves the endpoint
			# length. Inspecting only its stored first endpoint avoids
			# materializing every interpolated vector just to obtain lengths.
			isempty(y) || fill!(x, 0:(length(first(y)) - 1))
		elseif y isa StepRangeLen{<:Vector}
			# A built-in vector StepRangeLen likewise preserves the vector
			# step's length, and `step` returns that stored vector directly.
			isempty(y) || fill!(x, 0:(length(step(y)) - 1))
		else
			# Keep the general path for views, heterogeneous collections, and
			# custom ranges whose inner series may have different lengths.
			for (n, series) in enumerate(y)
				x[n] = 0:(length(series) - 1)
			end
		end
		return x
	end
	return 0:(length(y) - 1)
end

# Apply a `showlegend` keyword (`nothing`, a Bool, or one entry per trace) to
# one trace or a vector of traces. `nothing` entries leave a trace unchanged;
# surplus vector entries are ignored, as for the other per-series keywords.
function _apply_showlegend!(trace, showlegend)
	showlegend === nothing && return
	if trace isa AbstractVector
		if showlegend isa Bool
			for t in trace
				t.showlegend = showlegend
			end
		elseif showlegend isa AbstractVector
			for (t, value) in zip(trace, showlegend)
				value === nothing || (t.showlegend = value)
			end
		end
	else
		if showlegend isa Bool
			trace.showlegend = showlegend
		elseif showlegend isa AbstractVector && !isempty(showlegend)
			value = first(showlegend)
			value === nothing || (trace.showlegend = value)
		end
	end
	return nothing
end

function _apply_cartesian_plot_options!(
	fig;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	width::Real = 0,
	height::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	fontsize::Real = 0,
	title::AbstractString = "",
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	ykey::Symbol = :yaxis,
	refresh::Bool = false,
	apply_template::Bool = true,
	who::AbstractString = "plot",
)
	# Validate every option before the first write so a rejected keyword
	# leaves the figure untouched. A twin y axis (`ykey` other than :yaxis,
	# see `_ensure_twin_y!`) takes `ylabel`/`yscale`/`yrange`/`yticks`; the
	# D7 primitives address the primary axes only, so it is handled here.
	primary_y = ykey === :yaxis
	_validate_cartesian_options(
		fig,
		who;
		xrange = xrange,
		yrange = primary_y ? yrange : nothing,
		xscale = xscale,
		yscale = primary_y ? yscale : "",
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
	)
	if !primary_y
		_require_axis_scale(yscale, who, "yscale")
		_scat_require_axis_range(fig, ykey, yrange, yscale, who, "yrange")
	end

	_apply_figure_title!(fig, title)
	_apply_axis_title!(fig, :x, xlabel)
	# Scale before range: a logarithmic axis stores its range as exponents.
	_apply_axis_scale!(fig, :x, xscale, who)
	_apply_axis_range!(fig, :x, xrange, who)
	if primary_y
		_apply_axis_title!(fig, :y, ylabel)
		_apply_axis_scale!(fig, :y, yscale, who)
		_apply_axis_range!(fig, :y, yrange, who)
	else
		_scat_apply_axis_options!(
			fig,
			ykey;
			label = ylabel,
			scale = yscale,
			range = yrange,
			range_name = "yrange",
			who = who,
		)
	end
	_apply_figure_size!(fig, who; width = width, height = height)
	# `grid = true` keeps the template's grid (the constructor default);
	# `false` or an axis selector overrides it.
	grid === true || _apply_axis_grid!(fig, grid, who)
	# Ticks after scale and range: log axes and explicit ranges are known.
	_scat_apply_ticks!(fig, :xaxis, xticks, xticklabels, xtickformat, who)
	_scat_apply_ticks!(fig, ykey, yticks, yticklabels, ytickformat, who)
	equalar && _apply_equal_aspect!(fig, _cell_target(fig; who = who); who = who)
	# On first construction apply the default template; when appending to an
	# existing figure only refresh the legend so a user-set template survives.
	if apply_template
		_apply_default_template!(fig)
	else
		_apply_default_legend!(fig)
	end
	_apply_figure_fontsize!(fig, who, fontsize)
	refresh && _refresh!(fig)
	return nothing
end

# Mutator-side grid override: `nothing` (the mutator default) keeps the
# existing grid, anything else is applied explicitly, so `grid = true` can
# re-enable a grid that was switched off earlier.
function _apply_cartesian_grid_override!(
	fig,
	grid::Union{Nothing, Bool, Symbol},
	who::AbstractString = "plot",
)
	_apply_axis_grid!(fig, grid, who)
	return nothing
end

# ── Scatter family: shared validation and trace building ─────────────
# Used by plot_scatter, plot_stem, plot_area and plot_scatterpolar (with their
# mutators) and by the plots in src/sci/lines.jl. Validators never write;
# messages start with `who`, the public function name.

const _SCAT_MODE_FLAGS = ("lines", "markers", "text")
const _SCAT_DASH_NAMES = ("solid", "dot", "dash", "longdash", "dashdot", "longdashdot")
# plotly.js also accepts an explicit dash-length list ("5px,10px,2px", "5%,2%").
const _SCAT_DASH_LENGTHS = r"^\s*\d+(\.\d+)?(px|%)?\s*(,\s*\d+(\.\d+)?(px|%)?\s*)*$"
# `line.shape` values of plotly.js `scatter` and of `scatterpolar`.
const _SCAT_LINE_SHAPES = ("linear", "spline", "hv", "vh", "hvh", "vhv")
const _SCAT_POLAR_LINE_SHAPES = ("linear", "spline")
# `fill` values of plotly.js `scatter` and of `scatterpolar`.
const _SCAT_FILLS = ("none", "tozeroy", "tozerox", "tonexty", "tonextx", "toself", "tonext")
const _SCAT_POLAR_FILLS = ("none", "toself", "tonext")
const _SCAT_TEXT_POSITIONS = (
	"top left",
	"top center",
	"top right",
	"middle left",
	"middle center",
	"middle right",
	"bottom left",
	"bottom center",
	"bottom right",
)
# Stem lines keep the 1.x look (thin black) unless a colour, a line width or
# an active PlotStyle says otherwise.
const _STEM_DEFAULT_COLOR = "black"
const _STEM_DEFAULT_LINEWIDTH = 0.5
# plotly.js `zorder` of stems traces: below the default layer 0 of every other
# trace on the same axes.
const _STEM_ZORDER = -1

# Range check of any Cartesian axis `key` (`nothing`: an axis that does not
# exist yet and starts linear) against the axis type the call ends up with.
function _scat_require_axis_range(
	fig,
	key::Union{Nothing, Symbol},
	range,
	scale::AbstractString,
	who::AbstractString,
	name::AbstractString,
)
	checked = _checked_range(range, who, name)
	checked === nothing && return nothing
	final_type = !isempty(scale) ? String(scale) :
		key === nothing ? "-" : _axis_type(_plot_layout(fig), key)
	if final_type == "log"
		for bound in checked
			(bound isa Real && bound > 0) || throw(ArgumentError(
				"$(who): `$(name)` bounds on a logarithmic axis are data values " *
				"and must be positive; got $(repr(range)).",
			))
		end
	end
	return checked
end

# Validate the common Cartesian keywords of a scatter-family call before its
# first write. `ykey` is the y axis the call draws on: `:yaxis`, an existing
# twin axis, or `nothing` for a twin that `_ensure_twin_y!` will create.
function _scat_validate_cartesian_options(
	fig,
	who::AbstractString;
	ykey::Union{Nothing, Symbol} = :yaxis,
	xrange = nothing,
	yrange = nothing,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid = nothing,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
)
	primary_y = ykey === :yaxis
	_validate_cartesian_options(
		fig,
		who;
		xrange = xrange,
		yrange = primary_y ? yrange : nothing,
		xscale = xscale,
		yscale = primary_y ? yscale : "",
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
	)
	if !primary_y
		_require_axis_scale(yscale, who, "yscale")
		_scat_require_axis_range(fig, ykey, yrange, yscale, who, "yrange")
	end
	_scat_validate_ticks(fig, :xaxis, xticks, xticklabels, xscale, who, "x")
	_scat_validate_ticks(fig, ykey, yticks, yticklabels, yscale, who, "y")
	return nothing
end

# Tick values and labels of axis `key` (`nothing`: a twin y axis not created
# yet), checked as `_apply_ticks!` will check them once the call's `scale` is
# applied, so a bad tick keyword throws before the figure changes.
function _scat_validate_ticks(
	fig,
	key::Union{Nothing, Symbol},
	values,
	labels,
	scale::AbstractString,
	who::AbstractString,
	letter::AbstractString,
)
	(values === nothing && labels === nothing) && return nothing
	log_axis = !isempty(scale) ? scale == "log" :
		key !== nothing && _cmn_is_log_axis(_plot_layout(fig), key)
	tickvals = values === nothing ? nothing : _cmn_tick_values(values, log_axis, who)
	if labels !== nothing
		tickvals === nothing && throw(ArgumentError(
			"$(who): `$(letter)ticklabels` needs `$(letter)ticks` (one tick value per label).",
		))
		_cmn_tick_labels(labels, length(tickvals), who)
	end
	return nothing
end

# Title, scale and range of a non-primary Cartesian axis (the twin y axis of
# `secondary_y = true`) with the semantics of the D7 primitives: the label
# goes through `_label`, a log axis gets power exponents unless an exponent
# format is already set, and the range is given in data units.
function _scat_apply_axis_options!(
	fig,
	key::Symbol;
	label::AbstractString = "",
	scale::AbstractString = "",
	range = nothing,
	range_name::AbstractString = "range",
	who::AbstractString,
)
	isempty(label) || relayout!(fig; Symbol(key, :_title_text) => _label(label))
	if !isempty(scale)
		relayout!(fig; Symbol(key, :_type) => String(scale))
		if scale == "log"
			axis = get(_plot_layout(fig).fields, key, nothing)
			_cmn_mapping_get(axis, :exponentformat) === nothing &&
				relayout!(fig; Symbol(key, :_exponentformat) => "power")
		end
	end
	checked = _checked_range(range, who, range_name)
	if checked !== nothing
		layout = _plot_layout(fig)
		value = _axis_type(layout, key) == "log" ?
			_to_axis_range(layout, key, checked; who = "$(who) (`$(range_name)`)") :
			checked
		relayout!(
			fig;
			Symbol(key, :_range) => value,
			Symbol(key, :_autorange) => false,
		)
	end
	return nothing
end

# `xticks`/`xticklabels`/`xtickformat` (and the y counterparts) of a
# constructor or mutator: forwarded to `_apply_ticks!` when any is given.
function _scat_apply_ticks!(
	fig,
	key::Symbol,
	values,
	labels,
	format::AbstractString,
	who::AbstractString,
)
	(values === nothing && labels === nothing && isempty(format)) && return nothing
	_apply_ticks!(fig, key; values = values, labels = labels, format = format, who = who)
	return nothing
end

# Keywords a Plot/SyncPlot mutator of this family accepts beyond its documented
# list; they arrive through its `kwargs...`. `secondary_y::Bool` draws on a twin
# y axis (created on first use by `_ensure_twin_y!`); `row`/`col` may only be
# `nothing` (they select SubplotFigure cells). `show` and every other keyword
# are an ArgumentError. `kwargs` iterates `key => value` pairs (a mutator's
# `kwargs...`). Returns `secondary_y`.
function _scat_mutator_options(who::AbstractString, kwargs)
	secondary_y = false
	for (key, value) in kwargs
		if key === :secondary_y
			value isa Bool || throw(ArgumentError(
				"$(who): `secondary_y` must be true or false; got $(repr(value)).",
			))
			secondary_y = value
		elseif key === :show
			throw(ArgumentError(
				"$(who): `show` is a constructor keyword; a mutator draws into the " *
				"figure it is given. Display that figure with `display(fig)` or open " *
				"a window with `to_syncplot(fig)`.",
			))
		elseif key === :row || key === :col
			value === nothing || throw(ArgumentError(
				"$(who): `row`/`col` select a SubplotFigure cell; a single figure " *
				"has one cell, so omit them.",
			))
		else
			throw(ArgumentError("$(who): unsupported keyword argument `$(key)`."))
		end
	end
	return secondary_y
end

# Window size/title for a constructor's `show = true`.
_scat_maybe_show(fig, show::Bool, width::Real, height::Real, title::AbstractString) =
	_maybe_show(fig, show, round(Int, width), round(Int, height), String(title))

function _scat_require_vector(v, who::AbstractString, name::Symbol)
	v isa AbstractVector && return nothing
	shape = v isa AbstractArray ? "a $(ndims(v))-dimensional " : "a "
	throw(ArgumentError(
		"$(who): `$(name)` must be a vector (one series) or a vector of vectors " *
		"(several series); got $(shape)$(typeof(v)). Pass the columns of a " *
		"matrix `A` as `collect(eachcol(A))`.",
	))
end

function _scat_complex_error(who::AbstractString, name::Symbol)
	throw(ArgumentError(
		"$(who): `$(name)` holds complex values; plot_complex(z) draws them in " *
		"the complex plane (real part on x, imaginary part on y). To plot one " *
		"component pass real.(v), imag.(v) or abs.(v).",
	))
end

# Element check of one coordinate vector: complex numbers and arrays cannot be
# drawn as coordinates. A concrete element type is checked in O(1); abstractly
# typed vectors are scanned without allocating.
function _scat_check_values(v::AbstractVector, who::AbstractString, name::Symbol)
	T = eltype(v)
	if isconcretetype(T)
		T <: Complex && _scat_complex_error(who, name)
		T <: AbstractArray && throw(ArgumentError(
			"$(who): `$(name)` holds $(T) elements; pass a vector of values, or " *
			"a vector of vectors for several series.",
		))
		return nothing
	end
	for value in v
		value isa Complex && _scat_complex_error(who, name)
		value isa AbstractArray && throw(ArgumentError(
			"$(who): `$(name)` holds a $(typeof(value)) element; pass a vector of " *
			"values, or a vector of vectors for several series.",
		))
	end
	return nothing
end

# Validate the coordinates of a scatter-family call and split them into
# per-series vectors (stored by reference, never copied). `y` (the primary
# coordinate) decides between one series and several; `x` is shared by every
# series or nested like `y`. Every series needs as many `x` as `y` values.
# Returns `(xs, ys, nested)`.
function _scat_series(
	x,
	y,
	who::AbstractString;
	xname::Symbol = :x,
	yname::Symbol = :y,
)
	_scat_require_vector(x, who, xname)
	_scat_require_vector(y, who, yname)
	y_nested, x_nested =
		_nested_coordinate_mode(y, x, yname, xname; who = who)
	if !y_nested
		_scat_check_values(x, who, xname)
		_scat_check_values(y, who, yname)
		length(x) == length(y) || throw(ArgumentError(
			"$(who): `$(xname)` has $(length(x)) values but `$(yname)` has " *
			"$(length(y)); they must have the same length.",
		))
		return Any[x], Any[y], false
	end
	n = length(y)
	xs = Vector{Any}(undef, n)
	ys = Vector{Any}(undef, n)
	x_nested || _scat_check_values(x, who, xname)
	x_series = x_nested ? x : Iterators.repeated(x, n)
	for (index, (xi, yi)) in enumerate(zip(x_series, y))
		x_nested && _scat_check_values(xi, who, xname)
		_scat_check_values(yi, who, yname)
		length(xi) == length(yi) || throw(ArgumentError(
			"$(who): series $(index) has $(length(xi)) `$(xname)` values but " *
			"$(length(yi)) `$(yname)` values; they must have the same length.",
		))
		xs[index] = xi
		ys[index] = yi
	end
	return xs, ys, true
end

# One validated value per series: a scalar applies to every series; a vector
# gives one entry per series. Missing entries take `default` and surplus
# entries are ignored, the per-series convention of every plot family
# (`_series_kwarg_vector`). `check` validates and normalises each entry that
# is used (its messages name the keyword).
_scat_per_series(value, n::Int, default, check) =
	Any[check(entry) for entry in _series_kwarg_vector(value, n, default, Any)]

function _scat_mode(mode, who::AbstractString)
	(mode isa AbstractString) || throw(ArgumentError(
		"$(who): `mode` entries must be strings; got $(repr(mode)).",
	))
	isempty(mode) && return "lines"
	value = String(mode)
	value == "none" && return value
	parts = split(value, '+')
	(all(part -> part in _SCAT_MODE_FLAGS, parts) && allunique(parts)) ||
		throw(ArgumentError(
			"$(who): `mode` must combine \"lines\", \"markers\" and \"text\" with " *
			"'+' (e.g. \"lines+markers\"), or be \"none\" or \"\" (lines); got " *
			"$(repr(value)).",
		))
	return value
end

function _scat_add_mode_flag(mode::AbstractString, flag::AbstractString)
	mode == "none" && return String(flag)
	flag in split(mode, '+') && return String(mode)
	return string(mode, "+", flag)
end

function _scat_string(value, who::AbstractString, name::AbstractString)
	(value isa AbstractString || value isa Symbol) || throw(ArgumentError(
		"$(who): `$(name)` must be a string; got $(repr(value)).",
	))
	return String(value)
end

function _scat_choice(value, choices, who::AbstractString, name::AbstractString)
	text = _scat_string(value, who, name)
	(isempty(text) || text in choices) || throw(ArgumentError(
		"$(who): `$(name)` must be one of $(join(repr.(choices), ", ")) or \"\" " *
		"(unset); got $(repr(text)).",
	))
	return text
end

function _scat_dash(value, who::AbstractString)
	text = _scat_string(value, who, "dash")
	(isempty(text) || text in _SCAT_DASH_NAMES || occursin(_SCAT_DASH_LENGTHS, text)) ||
		throw(ArgumentError(
			"$(who): `dash` must be one of $(join(repr.(_SCAT_DASH_NAMES), ", ")), " *
			"a dash-length list such as \"5px,10px\", or \"\" (solid); got " *
			"$(repr(text)).",
		))
	return text
end

function _scat_nonnegative(value, who::AbstractString, name::AbstractString)
	(value isa Real && !(value isa Bool) && isfinite(value) && value >= 0) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a finite number >= 0 (0 = default); got " *
			"$(repr(value)).",
		))
	return value
end

function _scat_unit_interval(value, who::AbstractString, name::AbstractString)
	(value isa Real && !(value isa Bool) && isfinite(value) && 0 <= value <= 1) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a number in [0, 1]; got $(repr(value)).",
		))
	return value
end

function _scat_optional_bool(value, who::AbstractString, name::AbstractString)
	(value === nothing || value isa Bool) || throw(ArgumentError(
		"$(who): `$(name)` entries must be true, false or nothing; got $(repr(value)).",
	))
	return value
end

# Marker symbols are validated here (Plotly names or matplotlib codes) but kept
# as given: `_marker_attr` maps them and gives "." its small default size.
function _scat_marker_symbol(value, who::AbstractString)
	text = _scat_string(value, who, "marker_symbol")
	_plotly_marker_symbol(text; who = who)
	return text
end

# Resolved per-series style of a scatter-family call: one NamedTuple per
# series. The active PlotStyle's trace defaults (`_style_trace_defaults`, for
# trace `n_existing + i`) fill keywords that are still at their sentinels;
# under the :default style they are empty and nothing changes.
function _scat_series_styles(
	n::Int,
	n_existing::Int,
	who::AbstractString;
	mode = "lines",
	dash = "",
	color = "",
	legend = "",
	marker_size = 0,
	marker_symbol = "",
	marker_color = "",
	marker_line_color = "",
	marker_line_width = 0,
	linewidth = 0,
	opacity = 1,
	showlegend = nothing,
	line_shape = "",
	line_shapes = _SCAT_LINE_SHAPES,
	fill = "",
	fills = _SCAT_FILLS,
	fillcolor = "",
)
	modes = _scat_per_series(mode, n, "lines", value -> _scat_mode(value, who))
	dashes = _scat_per_series(dash, n, "", value -> _scat_dash(value, who))
	colors = _scat_per_series(
		color,
		n,
		"",
		value -> _cmn_check_color(value, "color", who),
	)
	names = _scat_per_series(
		legend,
		n,
		"",
		value -> _scat_string(value, who, "legend"),
	)
	sizes = _scat_per_series(
		marker_size,
		n,
		0,
		value -> _scat_nonnegative(value, who, "marker_size"),
	)
	symbols = _scat_per_series(
		marker_symbol,
		n,
		"",
		value -> _scat_marker_symbol(value, who),
	)
	faces = _scat_per_series(
		marker_color,
		n,
		"",
		value -> _cmn_check_color(value, "marker_color", who),
	)
	edges = _scat_per_series(
		marker_line_color,
		n,
		"",
		value -> _cmn_check_color(value, "marker_line_color", who),
	)
	edge_widths = _scat_per_series(
		marker_line_width,
		n,
		0,
		value -> _scat_nonnegative(value, who, "marker_line_width"),
	)
	widths = _scat_per_series(
		linewidth,
		n,
		0,
		value -> _scat_nonnegative(value, who, "linewidth"),
	)
	opacities = _scat_per_series(
		opacity,
		n,
		1,
		value -> _scat_unit_interval(value, who, "opacity"),
	)
	legends_shown = _scat_per_series(
		showlegend,
		n,
		nothing,
		value -> _scat_optional_bool(value, who, "showlegend"),
	)
	shapes = _scat_per_series(
		line_shape,
		n,
		"",
		value -> _scat_choice(value, line_shapes, who, "line_shape"),
	)
	fill_modes = _scat_per_series(
		fill,
		n,
		"",
		value -> _scat_choice(value, fills, who, "fill"),
	)
	fill_colors = _scat_per_series(
		fillcolor,
		n,
		"",
		value -> _cmn_check_color(value, "fillcolor", who),
	)

	styles = Vector{Any}(undef, n)
	n == 0 && return styles
	style = _active_style()
	template = _style_template(style)
	for index in 1:n
		defaults = _style_trace_defaults(style, n_existing + index; template = template)
		trace_mode = modes[index]
		get(defaults, :markers, false) === true && trace_mode == "lines" &&
			(trace_mode = "lines+markers")
		styles[index] = (
			mode = trace_mode,
			name = names[index],
			color = isempty(colors[index]) ? String(get(defaults, :color, "")) : colors[index],
			dash = isempty(dashes[index]) ? String(get(defaults, :dash, "")) : dashes[index],
			linewidth = widths[index] == 0 ? get(defaults, :linewidth, 0) : widths[index],
			marker_size = sizes[index] == 0 ? get(defaults, :marker_size, 0) : sizes[index],
			marker_symbol = isempty(symbols[index]) ?
				String(get(defaults, :marker_symbol, "")) : symbols[index],
			marker_color = faces[index],
			marker_line_color = edges[index],
			marker_line_width = edge_widths[index],
			opacity = opacities[index],
			showlegend = legends_shown[index],
			line_shape = shapes[index],
			fill = fill_modes[index],
			fillcolor = fill_colors[index],
		)
	end
	return styles
end

# A marker face colour or a stroke-only symbol ("x-thin", ...) needs an
# explicit series colour for its edge; otherwise Plotly's colorway applies.
function _scat_needs_series_color(style)
	face = style.marker_color
	(!isempty(face) && face != "none") && return true
	isempty(style.marker_symbol) && return false
	return _cmn_is_line_symbol(_plotly_marker_symbol(style.marker_symbol))
end

# Per-point text labels of each series (`nothing`: no labels). `text` is a
# string (one label for every point), a vector (the labels of a one-series
# call, or the same labels for every series) or a vector of vectors (one label
# vector per series). Labels are plain text (`_label_plain`; Plotly does not
# typeset trace text); numbers are printed, `nothing`/`missing` are blank.
function _scat_series_text(text, nested::Bool, lengths::Vector{Int}, who::AbstractString)
	n = length(lengths)
	out = Vector{Any}(nothing, n)
	text === nothing && return out
	if text isa AbstractString
		fill!(out, _label_plain(text))
		return out
	end
	text isa AbstractVector || throw(ArgumentError(
		"$(who): `text` must be nothing, a string, a vector of labels or a vector " *
		"of label vectors (one per series); got $(typeof(text)).",
	))
	if nested && _is_nested_series(text; who = who)
		for (index, labels) in zip(1:n, text)
			out[index] = _scat_text_labels(labels, lengths[index], who, index)
		end
	else
		for index in 1:n
			out[index] = _scat_text_labels(text, lengths[index], who, index)
		end
	end
	return out
end

function _scat_text_labels(labels::AbstractVector, n::Int, who::AbstractString, series::Int)
	length(labels) == n || throw(ArgumentError(
		"$(who): `text` for series $(series) has $(length(labels)) labels but the " *
		"series has $(n) points.",
	))
	out = Vector{String}(undef, n)
	for (index, label) in zip(1:n, labels)
		out[index] = if label isa AbstractString
			_label_plain(label)
		elseif label === nothing || label === missing
			""
		elseif label isa Real
			string(label)
		else
			throw(ArgumentError(
				"$(who): `text` labels must be strings or numbers; got $(repr(label)).",
			))
		end
	end
	return out
end

# `markevery` of each series as `_markevery_fields` dictionaries. For several
# series, a vector gives one entry per series (each `nothing`, a step or an
# index vector) and a scalar applies to every series.
function _scat_series_markevery(markevery, nested::Bool, lengths::Vector{Int}, who::AbstractString)
	n = length(lengths)
	out = Vector{Dict{Symbol, Any}}(undef, n)
	entries = nested && markevery isa AbstractVector ?
		_series_kwarg_vector(markevery, n, nothing, Any) :
		fill(markevery, n)
	for index in 1:n
		out[index] = _markevery_fields(entries[index], lengths[index]; who = who)
	end
	return out
end

# Error bars of each series (see `_error_bar_entries`); every given array must
# have one value per point of its series.
function _scat_series_errors(err, lengths::Vector{Int}, who::AbstractString, name::AbstractString)
	entries = _error_bar_entries(err, length(lengths), name, who)
	for (index, entry) in enumerate(entries)
		entry === nothing && continue
		for values in (entry isa Tuple ? entry : (entry,))
			values isa AbstractVector || throw(ArgumentError(
				"$(who): `$(name)` for series $(index) must be a vector; got " *
				"$(typeof(values)).",
			))
			length(values) == lengths[index] || throw(ArgumentError(
				"$(who): `$(name)` for series $(index) has $(length(values)) values " *
				"but the series has $(lengths[index]) points.",
			))
		end
	end
	return entries
end

# Build one scatter-family trace. `fields` already holds the coordinates
# (stored by reference); `style` is one entry of `_scat_series_styles` and
# `series_color` its resolved colour. Only non-sentinel attributes are written.
function _scat_trace(
	fields::Dict{Symbol, Any},
	trace_type::AbstractString,
	style,
	who::AbstractString;
	series_color::AbstractString = style.color,
	markevery::AbstractDict = Dict{Symbol, Any}(),
	text = nothing,
	textposition::AbstractString = "",
	textsize::Real = 0,
	error_x = nothing,
	error_y = nothing,
	cliponaxis::Union{Nothing, Bool} = nothing,
	yref::AbstractString = "",
)
	mode = style.mode
	isempty(markevery) || (mode = _scat_add_mode_flag(mode, "markers"))
	text === nothing || (mode = _scat_add_mode_flag(mode, "text"))
	fields[:mode] = mode
	fields[:name] = isempty(style.name) ? "" : _label(style.name)
	line = Dict{Symbol, Any}()
	isempty(series_color) || (line[:color] = String(series_color))
	isempty(style.dash) || (line[:dash] = style.dash)
	style.linewidth > 0 && (line[:width] = style.linewidth)
	isempty(style.line_shape) || (line[:shape] = style.line_shape)
	isempty(line) || (fields[:line] = attr(line))
	marker = _marker_attr(;
		color_series = series_color,
		marker_color = style.marker_color,
		marker_line_color = style.marker_line_color,
		marker_line_width = style.marker_line_width,
		marker_size = style.marker_size,
		marker_symbol = style.marker_symbol,
		who = who,
	)
	isempty(marker.fields) || (fields[:marker] = marker)
	style.opacity == 1 || (fields[:opacity] = style.opacity)
	style.showlegend === nothing || (fields[:showlegend] = style.showlegend)
	merge!(fields, markevery)
	isempty(style.fill) || (fields[:fill] = style.fill)
	isempty(style.fillcolor) || (fields[:fillcolor] = style.fillcolor)
	if text !== nothing
		fields[:text] = text
		isempty(textposition) || (fields[:textposition] = String(textposition))
		textsize > 0 && (fields[:textfont] = attr(size = textsize))
	end
	error_x === nothing || (fields[:error_x] = _error_bar_attr(error_x))
	error_y === nothing || (fields[:error_y] = _error_bar_attr(error_y))
	cliponaxis === nothing || (fields[:cliponaxis] = cliponaxis)
	isempty(yref) || (fields[:yaxis] = String(yref))
	return GenericTrace(String(trace_type), fields)
end

# The twin y axis of a Plot/SyncPlot mutator call with `secondary_y = true`:
# the existing one, or `nothing` when `_ensure_twin_y!` will create it.
_scat_twin_key(fig, secondary_y::Bool) =
	secondary_y ? _cmn_twin_y_key(_plot_layout(fig)) : :yaxis

# SubplotFigure calls build their traces in an empty scratch figure (see
# `_subplot_delegate_mutator!`). While they do, this holds what the scratch
# figure cannot know about the real one: `figure` and `offset` (its trace
# count) give the default colours plotly.js will assign, `legend_groups` the
# legend groups already in use.
const _SCAT_SUBPLOT_CONTEXT = Base.ScopedValues.ScopedValue{Any}(nothing)

# `_subplot_delegate_mutator!` for this family: the context is read from `sf`
# inside the delegate (which holds the figure's lock) and set while `mutator`
# runs on the scratch figure.
function _scat_subplot_delegate!(sf::SubplotFigure, mutator, args...; kwargs...)
	in_context = function (target, values...; options...)
		plot = _plot_obj(getfield(sf, :fig))
		groups = Set{String}()
		for trace in plot.data
			group = get(trace.fields, :legendgroup, nothing)
			group isa AbstractString && push!(groups, String(group))
		end
		context = (figure = sf, offset = length(plot.data), legend_groups = groups)
		return Base.ScopedValues.with(_SCAT_SUBPLOT_CONTEXT => context) do
			mutator(target, values...; options...)
		end
	end
	return _subplot_delegate_mutator!(sf, in_context, args...; kwargs...)
end

# Number of traces that precede the next trace appended to `fig`: its own
# traces plus, while a SubplotFigure call builds its traces in a scratch
# figure, the real figure's. Trace positions derived from it (default colours,
# style cycles) match the ones plotly.js assigns in the final figure.
function _scat_existing_count(fig)
	context = _SCAT_SUBPLOT_CONTEXT[]
	count = length(_plot_data(fig))
	return context === nothing ? count : context.offset + count
end

# Default colour plotly.js gives the trace at 1-based position `index` of the
# final figure (`index` counts from `_scat_existing_count`): read from `fig`,
# or from the real figure while a SubplotFigure call is building its traces.
function _scat_default_color(fig, index::Integer)
	context = _SCAT_SUBPLOT_CONTEXT[]
	return _default_trace_color(context === nothing ? fig : context.figure, index)
end

# Shared body of plot_scatter / plot_scatter! (and plot_complex(!)): validate
# everything, then append one trace per series and apply the figure options.
function _scatter_impl!(
	fig,
	x,
	y;
	who::AbstractString,
	constructor::Bool,
	secondary_y::Bool = false,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	width::Real = 0,
	height::Real = 0,
	mode = "lines",
	dash = "",
	color = "",
	legend = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid = true,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	marker_size = 0,
	marker_symbol = "",
	marker_color = "",
	marker_line_color = "",
	marker_line_width = 0,
	linewidth = 0,
	opacity = 1,
	markevery = nothing,
	line_shape = "",
	fill = "",
	fillcolor = "",
	text = nothing,
	textposition::AbstractString = "",
	textsize::Real = 0,
	showlegend = nothing,
	error_x = nothing,
	error_y = nothing,
	clip::Bool = true,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	extra_traces = nothing,
)
	xs, ys, nested = _scat_series(x, y, who)
	n = length(ys)
	lengths = Int[length(series) for series in ys]
	n_existing = _scat_existing_count(fig)
	styles = _scat_series_styles(
		n,
		n_existing,
		who;
		mode = mode,
		dash = dash,
		color = color,
		legend = legend,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		marker_color = marker_color,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		linewidth = linewidth,
		opacity = opacity,
		showlegend = showlegend,
		line_shape = line_shape,
		fill = fill,
		fillcolor = fillcolor,
	)
	texts = _scat_series_text(text, nested, lengths, who)
	position = _scat_choice(textposition, _SCAT_TEXT_POSITIONS, who, "textposition")
	text_size = _scat_nonnegative(textsize, who, "textsize")
	marks = _scat_series_markevery(markevery, nested, lengths, who)
	x_errors = _scat_series_errors(error_x, lengths, who, "error_x")
	y_errors = _scat_series_errors(error_y, lengths, who, "error_y")
	_scat_validate_cartesian_options(
		fig,
		who;
		ykey = _scat_twin_key(fig, secondary_y),
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
	)

	ykey = secondary_y ? _ensure_twin_y!(fig; who = who) : :yaxis
	yref = secondary_y ? _cmn_axis_ref(ykey; who = who) : ""
	cliponaxis = clip ? nothing : false
	data = _plot_data(fig)
	for index in 1:n
		style = styles[index]
		series_color = style.color
		if isempty(series_color) && _scat_needs_series_color(style)
			series_color = _scat_default_color(fig, n_existing + index)
		end
		push!(
			data,
			_scat_trace(
				Dict{Symbol, Any}(:x => xs[index], :y => ys[index]),
				"scatter",
				style,
				who;
				series_color = series_color,
				markevery = marks[index],
				text = texts[index],
				textposition = position,
				textsize = text_size,
				error_x = x_errors[index],
				error_y = y_errors[index],
				cliponaxis = cliponaxis,
				yref = yref,
			),
		)
	end
	extra_traces === nothing || extra_traces(fig, yref)
	# A constructor's `grid = true` keeps the template grid; a mutator applies
	# any non-nothing `grid`, so `true` re-enables a grid switched off earlier.
	constructor || _apply_cartesian_grid_override!(fig, grid, who)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = constructor ? grid : nothing,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
		ykey = ykey,
		apply_template = constructor,
		who = who,
	)
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
	plot_scatter(x, y; kwargs...) -> Plot (or SyncPlot with `show = true`)
	plot_scatter(y; kwargs...)

Line and marker plot of `y` against `x` on Cartesian axes (Plotly `scatter`
traces). The one-argument form uses `x = 0:length(y)-1` (per series).

#### Data

- `x`, `y`: vectors of equal length (numbers, dates or category strings;
  `NaN`/`missing` values leave a gap). A vector of vectors in `y` draws one
  trace per series; `x` is then either one vector shared by every series or a
  vector of vectors with one entry per series. Each series needs as many `x`
  as `y` values. Ranges, views and abstractly typed containers
  (`ys = []; push!(ys, v)`) are accepted; data is stored by reference.
- Matrices and complex values are rejected with an `ArgumentError`: pass
  `collect(eachcol(A))` for one series per column, and use
  [`plot_complex`](@ref) for complex data.

#### Per-series keywords

Each accepts one value for every series or a vector with one entry per series
(missing entries take the default, surplus entries are ignored).

- `mode = "lines"`: `"lines"`, `"markers"`, `"text"` or a `+` combination
  (`"lines+markers"`), or `"none"`; `""` means `"lines"`.
- `dash = ""`: `"solid"`, `"dot"`, `"dash"`, `"longdash"`, `"dashdot"`,
  `"longdashdot"` or a dash-length list such as `"5px,10px"`.
- `color = ""`: line (and default marker) colour, a CSS colour string or
  `Symbol`; `""` uses the template colorway.
- `legend = ""`: legend name (`AbstractString`, math such as `L"\\alpha"` is
  typeset).
- `linewidth = 0`: line width in px (`0`: default).
- `line_shape = ""`: `"linear"`, `"spline"`, or the step shapes `"hv"`
  (step after the point), `"vh"`, `"hvh"`, `"vhv"`.
- `marker_size = 0`: marker diameter in px (`Real`; `0`: default).
- `marker_symbol = ""`: a Plotly symbol (`"circle"`, `"square-open"`, ...) or a
  matplotlib code: `"o"`, `"s"`, `"^"`, `"v"`, `"<"`, `">"`, `"D"`, `"d"`,
  `"x"` (thin x), `"+"` (thin cross), `"*"`, `"p"`, `"h"`, `"."` (small dot).
- `marker_color = ""`: marker face colour; `"none"` draws hollow markers.
  With a face colour the edge is `marker_line_color`, otherwise the series
  colour, 1.5 px wide.
- `marker_line_color = ""`, `marker_line_width = 0`: marker edge colour and
  width in px.
- `opacity = 1`: trace opacity in [0, 1].
- `fill = ""`: area fill, `"tozeroy"`, `"tozerox"`, `"tonexty"`, `"tonextx"`,
  `"toself"`, `"tonext"` or `"none"`; `fillcolor = ""` sets its colour.
- `showlegend = nothing`: `true`/`false` force the legend entry on or off.

#### Other trace keywords

- `markevery = nothing`: draw markers only at some points (`mode` gains
  `"markers"`): an integer step `k` (points `1:k:n`), a range or vector of
  1-based indices, or a `Bool` mask. For several series a vector gives one
  entry per series and a scalar applies to all.
- `text = nothing`: per-point labels drawn at the points (`mode` gains
  `"text"`): a string for every point, a vector of labels (strings or numbers;
  shared by all series), or a vector of label vectors (one per series).
  `textposition = ""` (`"top center"`, `"middle right"`, ... any of the nine
  `"<top|middle|bottom> <left|center|right>"`) and `textsize = 0` (px) style
  them.
- `error_x = nothing`, `error_y = nothing`: data error bars, given as a vector
  (symmetric, shared by all series), a vector of vectors (one per series), or
  a `(minus, plus)` tuple of such for asymmetric bars. Each array has one
  value per point.
- `clip = true`: `false` lets markers and text extend past the plot area edge
  (Plotly `cliponaxis = false`, matplotlib `clip_on=False`).

#### Figure keywords

- `title = ""`, `xlabel = ""`, `ylabel = ""`: text (`AbstractString`, math is
  typeset).
- `xscale = ""`, `yscale = ""`: axis type, `"linear"`, `"log"`, `"date"`,
  `"category"`; log axes label ticks as powers of ten.
- `xrange = [0, 0]`, `yrange = [0, 0]`: axis range as a 2-element vector or
  tuple in data units (also on log axes); `[0, 0]` or `nothing` autoscale.
- `xticks = nothing`, `yticks = nothing`: tick positions; `xticklabels`,
  `yticklabels`: one label per tick; `xtickformat = ""`, `ytickformat = ""`:
  d3 tick format (e.g. `".2f"`).
- `equalar = false`: equal data aspect ratio (one x unit spans as many pixels
  as one y unit).
- `grid = true`: `true` keeps the template grid, `false` hides it, `:x`,
  `:y`, `:both` or `:none` choose the axes with grid lines.
- `width = 0`, `height = 0`: figure size in px (`0`: automatic);
  `fontsize = 0`: global font size in px.
- `show = false`: `true` opens the figure in a window and returns the
  `SyncPlot`.

Invalid values (unknown modes, symbols or dash names, mismatched lengths,
non-positive bounds on a log axis, ...) throw an `ArgumentError` that names
the function.

#### Example

```julia
x = range(0, 2π; length = 50)
fig = plot_scatter(x, [sin.(x), cos.(x)]; legend = ["sin", "cos"],
	mode = ["lines", "lines+markers"], marker_symbol = "o", marker_color = "white",
	markevery = [nothing, 5], xlabel = "\$t\$", ylabel = "signal")
```
"""
function plot_scatter(
	x::AbstractArray,
	y::AbstractArray;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	width::Real = 0,
	height::Real = 0,
	mode::Union{AbstractString, AbstractVector} = "lines",
	dash::Union{AbstractString, AbstractVector} = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	marker_size::Union{Real, AbstractVector} = 0,
	marker_symbol::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_color::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_line_color::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_line_width::Union{Real, AbstractVector} = 0,
	linewidth::Union{Real, AbstractVector} = 0,
	opacity::Union{Real, AbstractVector} = 1,
	markevery = nothing,
	line_shape::Union{AbstractString, AbstractVector} = "",
	fill::Union{AbstractString, AbstractVector} = "",
	fillcolor::Union{AbstractString, Symbol, AbstractVector} = "",
	text = nothing,
	textposition::AbstractString = "",
	textsize::Real = 0,
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	error_x = nothing,
	error_y = nothing,
	clip::Bool = true,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_scatter_impl!(
		fig,
		x,
		y;
		who = "plot_scatter",
		constructor = true,
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
		marker_color = marker_color,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		linewidth = linewidth,
		opacity = opacity,
		markevery = markevery,
		line_shape = line_shape,
		fill = fill,
		fillcolor = fillcolor,
		text = text,
		textposition = textposition,
		textsize = textsize,
		showlegend = showlegend,
		error_x = error_x,
		error_y = error_y,
		clip = clip,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
	)
	return _scat_maybe_show(fig, show, width, height, title)
end

plot_scatter(y::AbstractArray; kwargs...) =
	plot_scatter(_auto_xvalues(y; who = "plot_scatter"), y; kwargs...)

# Legend groups that tie each stem series' head and stem traces together. They
# are unique within the target figure: groups already used by its traces (or,
# for a SubplotFigure call, by the real figure) are skipped, so a click on one
# series never toggles another series.
function _stem_legend_groups(fig, n::Int)
	used = Set{String}()
	for trace in _plot_data(fig)
		group = get(trace.fields, :legendgroup, nothing)
		group isa AbstractString && push!(used, String(group))
	end
	context = _SCAT_SUBPLOT_CONTEXT[]
	context === nothing || union!(used, context.legend_groups)
	groups = Vector{String}(undef, n)
	candidate = 0
	for index in 1:n
		group = ""
		while true
			candidate += 1
			group = "plotlysupply:stem:$(candidate)"
			group in used || break
		end
		groups[index] = group
	end
	return groups
end

# One stems trace for a series: `baseline -> y` segments separated by `_GAP`,
# so a series is drawn by a single trace whatever its length.
function _stem_segments(x::AbstractVector, y::AbstractVector, baseline::Real)
	m = length(y)
	sx = Vector{Any}(undef, 3m)
	sy = Vector{Any}(undef, 3m)
	for (k, (xv, yv)) in enumerate(zip(x, y))
		sx[3k - 2] = xv
		sx[3k - 1] = xv
		sx[3k] = _GAP
		sy[3k - 2] = baseline
		sy[3k - 1] = yv
		sy[3k] = _GAP
	end
	return sx, sy
end

# Shared body of plot_stem / plot_stem!: one marker ("head") trace per series,
# followed by one stems trace per series. Each series' two traces share a
# unique legend group; the stems never get a legend entry or hover label.
function _stem_impl!(
	fig,
	x,
	y;
	who::AbstractString,
	constructor::Bool,
	secondary_y::Bool = false,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	width::Real = 0,
	height::Real = 0,
	color = "",
	legend = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid = true,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	showlegend = nothing,
	baseline::Real = 0,
	marker_size = 0,
	marker_symbol = "",
	marker_color = "",
	linewidth = 0,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
)
	xs, ys, _ = _scat_series(x, y, who)
	(baseline isa Bool || !isfinite(baseline)) && throw(ArgumentError(
		"$(who): `baseline` must be a finite number; got $(repr(baseline)).",
	))
	n = length(ys)
	n_existing = _scat_existing_count(fig)
	styles = _scat_series_styles(
		n,
		n_existing,
		who;
		mode = "markers",
		color = color,
		legend = legend,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		marker_color = marker_color,
		linewidth = linewidth,
		showlegend = showlegend,
	)
	_scat_validate_cartesian_options(
		fig,
		who;
		ykey = _scat_twin_key(fig, secondary_y),
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
	)

	ykey = secondary_y ? _ensure_twin_y!(fig; who = who) : :yaxis
	yref = secondary_y ? _cmn_axis_ref(ykey; who = who) : ""
	groups = _stem_legend_groups(fig, n)
	heads = Vector{GenericTrace}(undef, n)
	stems = Vector{GenericTrace}(undef, n)
	for index in 1:n
		style = styles[index]
		series_color = style.color
		if isempty(series_color) && _scat_needs_series_color(style)
			series_color = _scat_default_color(fig, n_existing + index)
		end
		marker = _marker_attr(;
			color_series = series_color,
			marker_color = style.marker_color,
			marker_size = style.marker_size,
			marker_symbol = style.marker_symbol,
			who = who,
		)
		# A markers-only trace has no line colour for the markers to inherit,
		# so the series colour becomes the face colour.
		(haskey(marker.fields, :color) || isempty(series_color)) ||
			(marker.fields[:color] = String(series_color))
		name = isempty(style.name) ? "" : _label(style.name)
		head = Dict{Symbol, Any}(
			:x => xs[index],
			:y => ys[index],
			:mode => "markers",
			:name => name,
			:legendgroup => groups[index],
		)
		isempty(marker.fields) || (head[:marker] = marker)
		# An unnamed series has no legend entry (its stems trace would otherwise
		# make plotly.js draw a legend with one blank entry); `showlegend`
		# overrides this.
		head_legend = style.showlegend === nothing ?
			(isempty(name) ? false : nothing) : style.showlegend
		head_legend === nothing || (head[:showlegend] = head_legend)
		isempty(yref) || (head[:yaxis] = yref)
		heads[index] = GenericTrace("scatter", head)

		stem_x, stem_y = _stem_segments(xs[index], ys[index], baseline)
		# Stems take the series colour only when one is given (`color`, or the
		# active style's cycle); the colorway colour resolved above for
		# white-faced or line-symbol heads stays on the heads.
		stem_color = isempty(style.color) ? _STEM_DEFAULT_COLOR : String(style.color)
		stem_width = style.linewidth > 0 ? style.linewidth : _STEM_DEFAULT_LINEWIDTH
		stem = Dict{Symbol, Any}(
			:x => stem_x,
			:y => stem_y,
			:mode => "lines",
			:name => name,
			:line => attr(color = stem_color, width = stem_width),
			:legendgroup => groups[index],
			:showlegend => false,
			:hoverinfo => "skip",
			# Drawn below the heads (and the other traces of the axes), as in
			# matplotlib, so a stem never crosses a hollow or white-faced head.
			:zorder => _STEM_ZORDER,
		)
		isempty(yref) || (stem[:yaxis] = yref)
		stems[index] = GenericTrace("scatter", stem)
	end
	append!(_plot_data(fig), heads)
	append!(_plot_data(fig), stems)
	# A constructor's `grid = true` keeps the template grid; a mutator applies
	# any non-nothing `grid`, so `true` re-enables a grid switched off earlier.
	constructor || _apply_cartesian_grid_override!(fig, grid, who)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = constructor ? grid : nothing,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
		ykey = ykey,
		apply_template = constructor,
		who = who,
	)
	return nothing
end

"""
	plot_stem(x, y; kwargs...) -> Plot (or SyncPlot with `show = true`)
	plot_stem(y; kwargs...)

Stem plot: a marker at every `(x, y)` point joined to `baseline` by a thin
vertical line (matplotlib `stem`). The one-argument form uses
`x = 0:length(y)-1` (per series).

Each series is drawn by two traces: a marker ("head") trace carrying the legend
entry, and one stems trace whose segments are separated by gaps. The two share
a legend group, so clicking the legend entry toggles the whole series. All head
traces of a call come first, then all stems traces; the stems are drawn below
every other trace of the axes (plotly.js `zorder = -1`), so they never cross a
head. Stems never show hover labels or legend entries.

#### Data

- `x`, `y`: vectors of equal length, or a vector of vectors in `y` (one series
  each) with `x` shared or nested like `y`. Matrices and complex values throw
  an `ArgumentError`.

#### Keywords

Per series (a value for every series, or a vector with one entry per series):

- `color = ""`: head and stem colour (`""`: heads use the colorway, stems are
  black).
- `legend = ""`: legend name (an unnamed series has no legend entry);
  `showlegend = nothing`: force the legend entry on (`true`) or off (`false`).
- `marker_size = 0` (px), `marker_symbol = ""` (Plotly name or matplotlib code
  such as `"o"`, `"s"`, `"D"`), `marker_color = ""` (head face colour;
  `"none"` gives hollow heads).
- `linewidth = 0`: stem line width in px (`0`: 0.5 px).

Shared:

- `baseline = 0`: the y value the stems start from.
- `title`, `xlabel`, `ylabel`, `xscale`, `yscale`, `xrange`, `yrange`,
  `xticks`, `xticklabels`, `yticks`, `yticklabels`, `xtickformat`,
  `ytickformat`, `equalar`, `grid`, `width`, `height`, `fontsize`, `show`: as
  for [`plot_scatter`](@ref) (ranges in data units, `grid = true` keeps the
  template grid).

#### Example

```julia
n = 0:20
fig = plot_stem(n, exp.(-n ./ 6) .* cos.(n); legend = "h[n]", baseline = 0,
	marker_color = "white", xlabel = "\$n\$")
```
"""
function plot_stem(
	x::AbstractArray,
	y::AbstractArray;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	width::Real = 0,
	height::Real = 0,
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	baseline::Real = 0,
	marker_size::Union{Real, AbstractVector} = 0,
	marker_symbol::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_color::Union{AbstractString, Symbol, AbstractVector} = "",
	linewidth::Union{Real, AbstractVector} = 0,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stem_impl!(
		fig,
		x,
		y;
		who = "plot_stem",
		constructor = true,
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
		baseline = baseline,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		marker_color = marker_color,
		linewidth = linewidth,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
	)
	return _scat_maybe_show(fig, show, width, height, title)
end

plot_stem(y::AbstractArray; kwargs...) =
	plot_stem(_auto_xvalues(y; who = "plot_stem"), y; kwargs...)

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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))

		if x_nested
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
	_apply_explicit_layout_mode!(fig, :barmode, barmode)
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
	if _is_nested_series(x)
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
	_apply_nested_layout_mode!(fig, x, :barmode, "overlay")
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))

		if x_nested
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
	_apply_nested_layout_mode!(fig, y, :boxmode, "group")
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
	if _is_nested_series(y)
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
	_apply_nested_layout_mode!(fig, y, :boxmode, "group")
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		trace = Vector{GenericTrace}(undef, length(y))

		if x_nested
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
	_apply_nested_layout_mode!(fig, y, :violinmode, "group")
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
	if _is_nested_series(y)
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
	_apply_nested_layout_mode!(fig, y, :violinmode, "group")
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

const _POLAR_DIRECTIONS = ("counterclockwise", "clockwise")
const _POLAR_THETAUNITS = ("degrees", "radians")

# Shared body of plot_scatterpolar / plot_scatterpolar!: validate everything,
# append one `scatterpolar` trace per series and set the options of the
# primary polar subplot (`layout.polar`).
function _scatterpolar_impl!(
	fig,
	theta,
	r;
	who::AbstractString,
	constructor::Bool,
	trange = [0, 0],
	rrange = [0, 0],
	width::Real = 0,
	height::Real = 0,
	mode = "lines",
	dash = "",
	color = "",
	legend = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid = true,
	marker_size = 0,
	marker_symbol = "",
	marker_color = "",
	marker_line_color = "",
	marker_line_width = 0,
	linewidth = 0,
	opacity = 1,
	markevery = nothing,
	line_shape = "",
	fill = "",
	fillcolor = "",
	showlegend = nothing,
	direction::AbstractString = "",
	rotation::Union{Nothing, Real} = nothing,
	thetaunit::AbstractString = "",
)
	thetas, rs, nested = _scat_series(theta, r, who; xname = :theta, yname = :r)
	n = length(rs)
	lengths = Int[length(series) for series in rs]
	n_existing = _scat_existing_count(fig)
	styles = _scat_series_styles(
		n,
		n_existing,
		who;
		mode = mode,
		dash = dash,
		color = color,
		legend = legend,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		marker_color = marker_color,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		linewidth = linewidth,
		opacity = opacity,
		showlegend = showlegend,
		line_shape = line_shape,
		line_shapes = _SCAT_POLAR_LINE_SHAPES,
		fill = fill,
		fills = _SCAT_POLAR_FILLS,
		fillcolor = fillcolor,
	)
	marks = _scat_series_markevery(markevery, nested, lengths, who)
	sector = _checked_range(trange, who, "trange")
	radial = _checked_range(rrange, who, "rrange")
	_require_size_option(width, who, "width")
	_require_size_option(height, who, "height")
	_require_size_option(fontsize, who, "fontsize")
	(grid === nothing || grid isa Bool) || throw(ArgumentError(
		"$(who): `grid` must be true, false or nothing (a polar plot has no x/y " *
		"axes to select); got $(repr(grid)).",
	))
	angular_direction = _scat_choice(direction, _POLAR_DIRECTIONS, who, "direction")
	(rotation === nothing || (!(rotation isa Bool) && isfinite(rotation))) ||
		throw(ArgumentError(
			"$(who): `rotation` must be a finite angle in degrees or nothing; got " *
			"$(repr(rotation)).",
		))
	unit = _scat_choice(thetaunit, _POLAR_THETAUNITS, who, "thetaunit")

	data = _plot_data(fig)
	for index in 1:n
		style = styles[index]
		series_color = style.color
		if isempty(series_color) && _scat_needs_series_color(style)
			series_color = _scat_default_color(fig, n_existing + index)
		end
		fields = Dict{Symbol, Any}(:r => rs[index], :theta => thetas[index])
		isempty(unit) || (fields[:thetaunit] = unit)
		push!(
			data,
			_scat_trace(
				fields,
				"scatterpolar",
				style,
				who;
				series_color = series_color,
				markevery = marks[index],
			),
		)
	end
	_apply_figure_title!(fig, title)
	radial === nothing || relayout!(fig; polar_radialaxis_range = radial)
	sector === nothing || relayout!(fig; polar_sector = sector)
	# A constructor keeps the template grid unless `grid = false`; a mutator
	# leaves it alone unless `grid` is given.
	if constructor ? grid === false : grid !== nothing
		relayout!(
			fig;
			polar_radialaxis_showgrid = grid,
			polar_angularaxis_showgrid = grid,
		)
	end
	isempty(angular_direction) ||
		relayout!(fig; polar_angularaxis_direction = angular_direction)
	rotation === nothing || relayout!(fig; polar_angularaxis_rotation = rotation)
	isempty(unit) || relayout!(fig; polar_angularaxis_thetaunit = unit)
	_apply_figure_size!(fig, who; width = width, height = height)
	constructor ? _apply_default_template!(fig) : _apply_default_legend!(fig)
	_apply_figure_fontsize!(fig, who, fontsize)
	return nothing
end

"""
	plot_scatterpolar(theta, r; kwargs...) -> Plot (or SyncPlot with `show = true`)

Line and marker plot in polar coordinates (Plotly `scatterpolar`): angle
`theta`, radius `r`.

#### Data

- `theta`: angles, in **degrees** by default; pass `thetaunit = "radians"`
  for radian data (radian data drawn as degrees collapses into a sliver).
  Angles grow counterclockwise from the positive x direction unless
  `direction`/`rotation` say otherwise.
- `r`: radii, same length as `theta`. A vector of vectors in `r` draws one
  trace per series; `theta` is shared or nested like `r`. Matrices and
  complex values throw an `ArgumentError`.

#### Keywords

Per series (a value for every series, or a vector with one entry per series):
`mode = "lines"`, `dash = ""`, `color = ""`, `legend = ""`, `linewidth = 0`,
`marker_size = 0`, `marker_symbol = ""`, `marker_color = ""`,
`marker_line_color = ""`, `marker_line_width = 0`, `opacity = 1`,
`showlegend = nothing`, as for [`plot_scatter`](@ref), and

- `line_shape = ""`: `"linear"` or `"spline"`.
- `fill = ""`: `"toself"` (fill the closed curve), `"tonext"` or `"none"`;
  `fillcolor = ""` sets its colour.

Shared:

- `markevery = nothing`: markers only at some points, as for `plot_scatter`.
- `thetaunit = ""`: `"degrees"` or `"radians"`; also sets the angular tick
  label unit.
- `direction = ""`: `"counterclockwise"` or `"clockwise"` angle direction;
  `rotation = nothing`: angle (degrees) at which `theta = 0` is drawn
  (`90` puts 0 at the top).
- `trange = [0, 0]`: angular sector `[start, end]` in degrees (`[0, 0]`: full
  circle); `rrange = [0, 0]`: radial axis range.
- `grid = true`: `false` hides the radial and angular grid lines.
- `title = ""`, `width = 0`, `height = 0`, `fontsize = 0`, `show = false`: as
  for `plot_scatter`.

#### Example

```julia
θ = range(0, 2π; length = 181)
fig = plot_scatterpolar(θ, 1 .+ cos.(θ); thetaunit = "radians", fill = "toself",
	legend = "cardioid", direction = "clockwise", rotation = 90)
```
"""
function plot_scatterpolar(
	theta::AbstractArray,
	r::AbstractArray;
	trange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	rrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	width::Real = 0,
	height::Real = 0,
	mode::Union{AbstractString, AbstractVector} = "lines",
	dash::Union{AbstractString, AbstractVector} = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	marker_size::Union{Real, AbstractVector} = 0,
	marker_symbol::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_color::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_line_color::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_line_width::Union{Real, AbstractVector} = 0,
	linewidth::Union{Real, AbstractVector} = 0,
	opacity::Union{Real, AbstractVector} = 1,
	markevery = nothing,
	line_shape::Union{AbstractString, AbstractVector} = "",
	fill::Union{AbstractString, AbstractVector} = "",
	fillcolor::Union{AbstractString, Symbol, AbstractVector} = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	direction::AbstractString = "",
	rotation::Union{Nothing, Real} = nothing,
	thetaunit::AbstractString = "",
	show::Bool = false,
)
	fig = Plot(GenericTrace[], Layout())
	_scatterpolar_impl!(
		fig,
		theta,
		r;
		who = "plot_scatterpolar",
		constructor = true,
		trange = trange,
		rrange = rrange,
		width = width,
		height = height,
		mode = mode,
		dash = dash,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		marker_color = marker_color,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		linewidth = linewidth,
		opacity = opacity,
		markevery = markevery,
		line_shape = line_shape,
		fill = fill,
		fillcolor = fillcolor,
		showlegend = showlegend,
		direction = direction,
		rotation = rotation,
		thetaunit = thetaunit,
	)
	return _scat_maybe_show(fig, show, width, height, title)
end

#endregion

#region 2D Plot

"""
	function plot_heatmap(
		x::Union{AbstractVector, SubArray},
		y::Union{AbstractVector, SubArray},
		U::AbstractArray;
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray},
	U::AbstractArray;
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
	FV = transpose(U) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
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
		U::AbstractArray;
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
	U::AbstractArray;
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
	x = 0:(size(U, 1) - 1)
	y = 0:(size(U, 2) - 1)
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
		x::Union{AbstractVector, SubArray},
		y::Union{AbstractVector, SubArray},
		U::AbstractArray;
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray},
	U::AbstractArray;
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
	FV = transpose(U) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
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
		U::AbstractArray;
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
	U::AbstractArray;
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
	x = 0:(size(U, 1) - 1)
	y = 0:(size(U, 2) - 1)
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


# Preserve the existing maximum shaft length while matching Plotly's reference
# quiver proportions for the arrowhead.
const _QUIVER_SHAFT_SCALE = 2 / 3
const _QUIVER_HEAD_SCALE = 0.3
const _QUIVER_HEAD_ANGLE = pi / 9

function _quiver_coordinates(
	x,
	y,
	u,
	v,
	sizeref::Real;
	caller::AbstractString,
)
	n = length(x)
	n == length(y) == length(u) == length(v) || throw(ArgumentError(
		"$caller: x, y, u, v must all have the same length; got " *
		"$(length(x)), $(length(y)), $(length(u)), $(length(v))",
	))
	isfinite(sizeref) && sizeref >= 0 || throw(ArgumentError(
		"$caller: sizeref must be finite and non-negative; got $sizeref",
	))

	TX = promote_type(Float64, eltype(x), eltype(u), eltype(v), typeof(sizeref))
	TY = promote_type(Float64, eltype(y), eltype(u), eltype(v), typeof(sizeref))
	empty_x, empty_y = Vector{TX}(), Vector{TY}()
	n == 0 && return empty_x, empty_y

	# Represent each magnitude as component * shape, where component is the
	# largest absolute component and shape lies in [1, sqrt(2)]. Comparing
	# bounded ratios avoids squaring overflow and underflow.
	max_component = 0.0
	max_shape = 0.0
	drawable = 0
	skipped = 0

	@inbounds for i in eachindex(x, y, u, v)
		xi, yi, ui, vi = x[i], y[i], u[i], v[i]
		xi isa Real && yi isa Real && ui isa Real && vi isa Real ||
			throw(ArgumentError(
				"$caller: x, y, u, v values must be real numbers " *
				"(invalid value at index $i)",
			))

		xf, yf, uf, vf = float(xi), float(yi), float(ui), float(vi)
		if !(isfinite(xf) && isfinite(yf) && isfinite(uf) && isfinite(vf))
			skipped += 1
			continue
		end

		component = max(abs(uf), abs(vf))
		iszero(component) && continue
		shape = hypot(uf / component, vf / component)
		drawable += 1

		if iszero(max_component) ||
		   (component > max_component ?
			shape > (max_component / component) * max_shape :
			(component / max_component) * shape > max_shape)
			max_component, max_shape = component, shape
		end
	end

	skipped > 0 && @warn(
		"$caller: skipped $skipped vector(s) with non-finite origins or components.",
	)
	if drawable == 0
		n > skipped && @warn(
			"$caller: all finite vectors have zero magnitude; nothing to draw.",
		)
		return empty_x, empty_y
	end

	# An explicit zero scale is a valid request for no visible arrows.
	iszero(sizeref) && return empty_x, empty_y

	# Each arrow needs a shaft and a separate three-point arrowhead:
	# origin, tip, NaN, head1, tip, head2, NaN.
	output_length = Base.Checked.checked_mul(7, drawable)
	arrow_x = Vector{TX}(undef, output_length)
	arrow_y = Vector{TY}(undef, output_length)
	cos_head, sin_head = cos(_QUIVER_HEAD_ANGLE), sin(_QUIVER_HEAD_ANGLE)
	max_shaft = sizeref * _QUIVER_SHAFT_SCALE
	j = 1

	@inbounds for i in eachindex(x, y, u, v)
		xf, yf = float(x[i]), float(y[i])
		uf, vf = float(u[i]), float(v[i])
		isfinite(xf) && isfinite(yf) && isfinite(uf) && isfinite(vf) ||
			continue

		component = max(abs(uf), abs(vf))
		iszero(component) && continue
		su, sv = uf / component, vf / component
		shape = hypot(su, sv)
		ux, uy = su / shape, sv / shape

		shaft = (component / max_component) *
			(shape / max_shape) *
			max_shaft
		tip_x, tip_y = xf + ux * shaft, yf + uy * shaft

		arm = _QUIVER_HEAD_SCALE * shaft
		head1_x = tip_x - arm * (ux * cos_head - uy * sin_head)
		head1_y = tip_y - arm * (uy * cos_head + ux * sin_head)
		head2_x = tip_x - arm * (ux * cos_head + uy * sin_head)
		head2_y = tip_y - arm * (uy * cos_head - ux * sin_head)

		isfinite(tip_x) && isfinite(tip_y) &&
			isfinite(head1_x) && isfinite(head1_y) &&
			isfinite(head2_x) && isfinite(head2_y) ||
			throw(ArgumentError(
				"$caller: scaled arrow coordinates are non-finite at index $i",
			))

		arrow_x[j] = xf
		arrow_y[j] = yf
		arrow_x[j + 1] = tip_x
		arrow_y[j + 1] = tip_y
		arrow_x[j + 2] = NaN
		arrow_y[j + 2] = NaN
		arrow_x[j + 3] = head1_x
		arrow_y[j + 3] = head1_y
		arrow_x[j + 4] = tip_x
		arrow_y[j + 4] = tip_y
		arrow_x[j + 5] = head2_x
		arrow_y[j + 5] = head2_y
		arrow_x[j + 6] = NaN
		arrow_y[j + 6] = NaN
		j += 7
	end

	return arrow_x, arrow_y
end

function _quiver_trace(
	x,
	y,
	u,
	v;
	color::String = "RoyalBlue",
	sizeref::Real = 1,
	caller::AbstractString = "plot_quiver",
)
	arrow_x, arrow_y =
		_quiver_coordinates(x, y, u, v, sizeref; caller = caller)
	return scatter(
		x = arrow_x,
		y = arrow_y,
		mode = "lines",
		line_color = color,
		hoverinfo = "skip",
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
    arrow = _quiver_trace(
        x,
        y,
        u,
        v;
        color = color,
        sizeref = sizeref,
        caller = "plot_quiver",
    )

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
		X::AbstractArray,
		Y::AbstractArray,
		Z::AbstractArray;
		surfacecolor::AbstractArray = [],
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
	X::AbstractArray,
	Y::AbstractArray,
	Z::AbstractArray;
	surfacecolor::AbstractArray = [],
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
		Z::AbstractArray;
		surfacecolor::AbstractArray = [],
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
- `Z::AbstractArray`: 2D array representing surface height. The dimensions of `Z` define the surface grid, with x and y coordinates automatically generated as `0:size(Z, 1)-1` and `0:size(Z, 2)-1`.

# Keyword Arguments
- `surfacecolor::AbstractArray`: Optional array for surface coloring. If empty, `Z` is used for coloring.
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
	Z::AbstractArray; surfacecolor::AbstractArray = [],
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
		0:(size(Z, 1) - 1),
		0:(size(Z, 2) - 1),
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
	trace = _scatter3d_traces(
		x,
		y,
		z;
		mode = mode,
		color = color,
		legend = legend,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		linewidth = linewidth,
		showlegend = showlegend,
	)

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
	plot_scatter!(fig, x, y; kwargs...) -> nothing (SubplotFigure: the figure)
	plot_scatter!(fig, y; kwargs...)

Append line/marker trace(s) to an existing figure: a `Plot`, a
[`SyncPlot`](@ref) (its window updates in one transaction) or a
`SubplotFigure` (the active cell, or `row`/`col`). Takes the data and every
keyword of [`plot_scatter`](@ref) except `show` (which throws an
`ArgumentError`), plus:

- `secondary_y = false`: draw on a secondary y axis on the right. On a `Plot`
  or `SyncPlot` the axis is created on first use (`ylabel`, `yscale`,
  `yrange`, `yticks`, ... then apply to it); on a `SubplotFigure` the cell
  needs `specs = [Spec(secondary_y = true) ...]`.
- `row`, `col` (`SubplotFigure` only): the target cell.

Figure keywords only change what they name: labels, ranges, scales and ticks
apply to the primary axes (or the secondary y axis), `grid = nothing` (the
mutator default) keeps the current grid and `true`/`false`/`:x`/`:y`/`:both`/
`:none` set it, and a template set with `set_template!` is kept. On a
`SubplotFigure`, `title`, `width` and `height` are figure-level and are
ignored with a warning. Invalid input throws before the figure changes.

#### Example

```julia
fig = plot_scatter(1:10, (1:10) .^ 2; legend = "data")
plot_scatter!(fig, 1:10, 10 .* (1:10); legend = "rate", secondary_y = true,
	ylabel = "rate", dash = "dash")
```
"""
function plot_scatter!(
	fig,
	x::AbstractArray,
	y::AbstractArray;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	width::Real = 0,
	height::Real = 0,
	mode::Union{AbstractString, AbstractVector} = "lines",
	dash::Union{AbstractString, AbstractVector} = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	marker_size::Union{Real, AbstractVector} = 0,
	marker_symbol::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_color::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_line_color::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_line_width::Union{Real, AbstractVector} = 0,
	linewidth::Union{Real, AbstractVector} = 0,
	opacity::Union{Real, AbstractVector} = 1,
	markevery = nothing,
	line_shape::Union{AbstractString, AbstractVector} = "",
	fill::Union{AbstractString, AbstractVector} = "",
	fillcolor::Union{AbstractString, Symbol, AbstractVector} = "",
	text = nothing,
	textposition::AbstractString = "",
	textsize::Real = 0,
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	error_x = nothing,
	error_y = nothing,
	clip::Bool = true,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	kwargs...,
)
	who = "plot_scatter!"
	secondary_y = _scat_mutator_options(who, kwargs)
	_scatter_impl!(
		fig,
		x,
		y;
		who = who,
		constructor = false,
		secondary_y = secondary_y,
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
		marker_color = marker_color,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		linewidth = linewidth,
		opacity = opacity,
		markevery = markevery,
		line_shape = line_shape,
		fill = fill,
		fillcolor = fillcolor,
		text = text,
		textposition = textposition,
		textsize = textsize,
		showlegend = showlegend,
		error_x = error_x,
		error_y = error_y,
		clip = clip,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
	)
	_refresh!(fig)
	return nothing
end

plot_scatter!(fig, y::AbstractArray; kwargs...) =
	plot_scatter!(fig, _auto_xvalues(y; who = "plot_scatter!"), y; kwargs...)

"""
	plot_stem!(fig, x, y; kwargs...) -> nothing (SubplotFigure: the figure)
	plot_stem!(fig, y; kwargs...)

Append stem series to an existing `Plot`, [`SyncPlot`](@ref) or
`SubplotFigure` cell (see [`plot_stem`](@ref) for the traces and keywords).
Takes every keyword of `plot_stem` except `show` (an `ArgumentError`), plus
`secondary_y = false` (draw on a secondary y axis, created on first use on a
`Plot`/`SyncPlot`) and `row`/`col` (`SubplotFigure` only). `grid = nothing`
keeps the current grid; the legend groups of the new series never collide with
those already in the figure.

#### Example

```julia
fig = plot_stem(0:10, rand(11); legend = "a")
plot_stem!(fig, 0:10, -rand(11); legend = "b", color = "crimson", marker_symbol = "s")
```
"""
function plot_stem!(
	fig,
	x::AbstractArray,
	y::AbstractArray;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	width::Real = 0,
	height::Real = 0,
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	baseline::Real = 0,
	marker_size::Union{Real, AbstractVector} = 0,
	marker_symbol::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_color::Union{AbstractString, Symbol, AbstractVector} = "",
	linewidth::Union{Real, AbstractVector} = 0,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	kwargs...,
)
	who = "plot_stem!"
	secondary_y = _scat_mutator_options(who, kwargs)
	_stem_impl!(
		fig,
		x,
		y;
		who = who,
		constructor = false,
		secondary_y = secondary_y,
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
		baseline = baseline,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		marker_color = marker_color,
		linewidth = linewidth,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
	)
	_refresh!(fig)
	return nothing
end

plot_stem!(fig, y::AbstractArray; kwargs...) =
	plot_stem!(fig, _auto_xvalues(y; who = "plot_stem!"), y; kwargs...)

"""
	plot_bar!(fig, x, y; kwargs...)
	plot_bar!(fig, y; kwargs...)

Append bar trace(s) to an existing figure (`Plot`, [`SyncPlot`](@ref), or
[`SubplotFigure`](@ref)). When `x` is omitted it defaults to `0:length(y)-1`.
Pass a `Vector` of `Vector`s for `y` (and optionally `x`) to append multiple
bar series at once.

# Keyword Arguments
- `color`: Bar color(s) — a string, or a vector for multiple series.
- `legend`: Trace name(s) for the legend.
- `orientation`: `"v"` (default) or `"h"` for horizontal bars.
- `barmode`: Layout bar mode such as `"group"` or `"stack"`.
- `error_x`, `error_y`: Error-bar magnitudes applied to the appended trace(s).
- `xlabel`, `ylabel`, `xrange`, `yrange`, `width`, `height`, `title`,
  `fontsize`, `grid`, `xscale`, `yscale`, `showlegend`: same as [`plot_bar`](@ref).
"""
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	_n0 = length(_plot_data(fig))
	if y_nested
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))

		showlegendV = _string_kwarg_vector("", length(y))
		if x_nested
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
	_apply_explicit_layout_mode!(fig, :barmode, barmode)
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

"""
	plot_histogram!(fig, x; kwargs...)

Append histogram trace(s) of the samples in `x` to an existing figure (`Plot`,
[`SyncPlot`](@ref), or [`SubplotFigure`](@ref)). Pass a `Vector` of `Vector`s
for `x` to overlay multiple series (`barmode` is set to `"overlay"` for nested
input).

# Keyword Arguments
- `nbinsx`: Target number of bins (`0` lets Plotly choose).
- `histnorm`: Normalization — `""`, `"percent"`, `"probability"`, `"density"`, or `"probability density"`.
- `color`, `legend`, `title`, `xlabel`, `ylabel`, `xrange`, `yrange`, `width`,
  `height`, `grid`, `fontsize`, `xscale`, `yscale`, `showlegend`: same as
  [`plot_histogram`](@ref).
"""
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
	if _is_nested_series(x)
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

	_apply_nested_layout_mode!(fig, x, :barmode, "overlay")
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
	plot_box!(fig, x, y; kwargs...)
	plot_box!(fig, y; kwargs...)

Append box trace(s) of the distribution(s) in `y`, optionally grouped by `x`,
to an existing figure (`Plot`, [`SyncPlot`](@ref), or [`SubplotFigure`](@ref)).
Pass a `Vector` of `Vector`s for `y` to append several boxes at once
(`boxmode="group"`).

# Keyword Arguments
- `points`: Outlier/point display — `"all"`, `"outliers"`, `"suspectedoutliers"`, or `false`.
- `color`, `legend`, `title`, `xlabel`, `ylabel`, `xrange`, `yrange`, `width`,
  `height`, `grid`, `fontsize`, `xscale`, `yscale`, `showlegend`: same as
  [`plot_box`](@ref).
"""
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		if x_nested
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

	_apply_nested_layout_mode!(fig, y, :boxmode, "group")
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
	if _is_nested_series(y)
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

	_apply_nested_layout_mode!(fig, y, :boxmode, "group")
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
	plot_violin!(fig, x, y; kwargs...)
	plot_violin!(fig, y; kwargs...)

Append violin trace(s) of the distribution(s) in `y`, optionally grouped by
`x`, to an existing figure (`Plot`, [`SyncPlot`](@ref), or
[`SubplotFigure`](@ref)). Pass a `Vector` of `Vector`s for `y` to append
several violins at once (`violinmode="group"`).

# Keyword Arguments
- `points`: Point display — `"all"`, `"outliers"`, `"suspectedoutliers"`, or `false`.
- `side`: Violin side — `"both"`, `"positive"`, or `"negative"`.
- `color`, `legend`, `title`, `xlabel`, `ylabel`, `xrange`, `yrange`, `width`,
  `height`, `grid`, `fontsize`, `xscale`, `yscale`, `showlegend`: same as
  [`plot_violin`](@ref).
"""
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
		if x_nested
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

	_apply_nested_layout_mode!(fig, y, :violinmode, "group")
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
	if _is_nested_series(y)
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

	_apply_nested_layout_mode!(fig, y, :violinmode, "group")
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
	plot_scatterpolar!(fig, theta, r; kwargs...) -> nothing (SubplotFigure: the figure)

Append polar trace(s) to an existing `Plot`, [`SyncPlot`](@ref) or polar
`SubplotFigure` cell (`row`/`col`). Takes the data and every keyword of
[`plot_scatterpolar`](@ref) except `show` (an `ArgumentError`); `theta` is in
degrees unless `thetaunit = "radians"`. Options apply to the primary polar
subplot (`layout.polar`; a SubplotFigure maps it to the cell's subplot);
`grid = nothing` (the mutator default) keeps the current grid and `true`/
`false` set it.

#### Example

```julia
fig = plot_scatterpolar(0:10:350, ones(36); legend = "unit")
plot_scatterpolar!(fig, 0:10:350, 0.5 .+ rand(36); legend = "noise", mode = "markers")
```
"""
function plot_scatterpolar!(
	fig,
	theta::AbstractArray,
	r::AbstractArray;
	trange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	rrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	width::Real = 0,
	height::Real = 0,
	mode::Union{AbstractString, AbstractVector} = "lines",
	dash::Union{AbstractString, AbstractVector} = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	title::AbstractString = "",
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	marker_size::Union{Real, AbstractVector} = 0,
	marker_symbol::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_color::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_line_color::Union{AbstractString, Symbol, AbstractVector} = "",
	marker_line_width::Union{Real, AbstractVector} = 0,
	linewidth::Union{Real, AbstractVector} = 0,
	opacity::Union{Real, AbstractVector} = 1,
	markevery = nothing,
	line_shape::Union{AbstractString, AbstractVector} = "",
	fill::Union{AbstractString, AbstractVector} = "",
	fillcolor::Union{AbstractString, Symbol, AbstractVector} = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	direction::AbstractString = "",
	rotation::Union{Nothing, Real} = nothing,
	thetaunit::AbstractString = "",
	kwargs...,
)
	who = "plot_scatterpolar!"
	_scat_mutator_options(who, kwargs) && throw(ArgumentError(
		"$(who): `secondary_y` addresses a Cartesian y axis; polar traces have none.",
	))
	_scatterpolar_impl!(
		fig,
		theta,
		r;
		who = who,
		constructor = false,
		trange = trange,
		rrange = rrange,
		width = width,
		height = height,
		mode = mode,
		dash = dash,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		marker_color = marker_color,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		linewidth = linewidth,
		opacity = opacity,
		markevery = markevery,
		line_shape = line_shape,
		fill = fill,
		fillcolor = fillcolor,
		showlegend = showlegend,
		direction = direction,
		rotation = rotation,
		thetaunit = thetaunit,
	)
	_refresh!(fig)
	return nothing
end

"""
	function plot_heatmap!(
		fig,
		x::Union{AbstractVector, SubArray},
		y::Union{AbstractVector, SubArray},
		U::AbstractArray;
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray},
	U::AbstractArray;
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
	FV = transpose(U) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
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
	U::AbstractArray;
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
	x = 0:(size(U, 1) - 1)
	y = 0:(size(U, 2) - 1)
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
		x::Union{AbstractVector, SubArray},
		y::Union{AbstractVector, SubArray},
		U::AbstractArray;
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray},
	U::AbstractArray;
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
	FV = transpose(U) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
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
	U::AbstractArray;
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
	x = 0:(size(U, 1) - 1)
	y = 0:(size(U, 2) - 1)
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
	arrow = _quiver_trace(
		x,
		y,
		u,
		v;
		color = color,
		sizeref = sizeref,
		caller = "plot_quiver!",
	)
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
		X::AbstractArray,
		Y::AbstractArray,
		Z::AbstractArray;
		surfacecolor::AbstractArray = [],
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::Union{Nothing, String} = nothing,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Union{Nothing, Bool} = nothing,
		showaxis::Union{Nothing, Bool} = nothing,
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
- `aspectmode`: Aspect mode setting; `nothing` preserves the existing scene (default: `nothing`)
- `colorscale`: Color scale for the surface (default: `""`)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to display grid lines; `nothing` preserves the existing scene (default: `nothing`)
- `showaxis`: Whether to show axes; `nothing` preserves the existing scene (default: `nothing`)
- `shared_coloraxis`: If `true`, uses a shared coloraxis (single colorbar) for multiple surfaces (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_surface!(
	fig,
	X::AbstractArray,
	Y::AbstractArray,
	Z::AbstractArray;
	surfacecolor::AbstractArray = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::Union{Nothing, String} = nothing,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	shared_coloraxis::Bool = false,
	color::AbstractArray = [],  # Alias for surfacecolor for backward compatibility
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

	_apply_scene_style_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		grid = grid,
		showaxis = showaxis,
	)
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
	Z::AbstractArray; surfacecolor::AbstractArray = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::Union{Nothing, String} = nothing,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	shared_coloraxis::Bool = false,
	color::AbstractArray = [],  # Alias for surfacecolor for backward compatibility
)
	return plot_surface!(
		fig,
		0:(size(Z, 1) - 1),
		0:(size(Z, 2) - 1),
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
		aspectmode::Union{Nothing, String} = nothing,
		title::String = "",
		fontsize::Int = 0,
		perspective::Union{Nothing, Bool} = nothing,
		grid::Union{Nothing, Bool} = nothing,
		showaxis::Union{Nothing, Bool} = nothing,
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
- `aspectmode`: Aspect mode for 3D view; `nothing` preserves the existing scene (default: `nothing`)
- `title`: Title of the plot (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `perspective`: Projection mode; `nothing` preserves the existing scene (default: `nothing`)
- `grid`: Whether to show grid lines; `nothing` preserves the existing scene (default: `nothing`)
- `showaxis`: Whether to show axes; `nothing` preserves the existing scene (default: `nothing`)
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
	aspectmode::Union{Nothing, String} = nothing,
	title::String = "",
	fontsize::Int = 0,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
	marker_size::Union{Int, Vector{Int}} = 0,
	marker_symbol::Union{String, Vector{String}} = "",
	linewidth::Union{Real, Vector{<:Real}} = 0,
	showlegend::Union{Nothing, Bool, Vector{Bool}} = nothing,
)
	traces = _scatter3d_traces(
		x,
		y,
		z;
		mode = mode,
		color = color,
		legend = legend,
		marker_size = marker_size,
		marker_symbol = marker_symbol,
		linewidth = linewidth,
		showlegend = showlegend,
	)
	if traces isa GenericTrace
		push!(_plot_data(fig), traces)
	else
		append!(_plot_data(fig), traces)
	end
	_apply_scene_style_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		perspective = perspective,
		grid = grid,
		showaxis = showaxis,
	)
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
		aspectmode::Union{Nothing, String} = nothing,
		title::String = "",
		fontsize::Int = 0,
		perspective::Union{Nothing, Bool} = nothing,
		grid::Union{Nothing, Bool} = nothing,
		showaxis::Union{Nothing, Bool} = nothing,
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
- `aspectmode`: Aspect mode for 3D view; `nothing` preserves the existing scene (default: `nothing`)
- `title`: Title of the plot (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `perspective`: Projection mode; `nothing` preserves the existing scene (default: `nothing`)
- `grid`: Whether to show grid lines; `nothing` preserves the existing scene (default: `nothing`)
- `showaxis`: Whether to show axes; `nothing` preserves the existing scene (default: `nothing`)

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
	aspectmode::Union{Nothing, String} = nothing,
	title::String = "",
	fontsize::Int = 0,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
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
	_apply_scene_style_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		perspective = perspective,
		grid = grid,
		showaxis = showaxis,
	)
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

#endregion

"""
	set_template!(fig, template = "plotly_white")

Applies a visual template to a figure.

# Arguments
- `fig`: A `PlotlyBase.Plot` or a `PlotlySupply.SyncPlot`.
- `template`: Registered template name (string or symbol), or a
  `PlotlyBase.Template`.

# Notes
- This modifies the figure in-place using `relayout!`.
- Available templates include `plotly`, `ggplot2`, `seaborn`, `simple_white`, `plotly_dark`, etc.
- Registered template names may be combined with `+`.
"""
function set_template!(fig, template = string(get_default_template()))
	chosen = _resolve_template(template)
	relayout!(fig, template = chosen)
	_refresh!(fig)
	return nothing
end

## additional auxiliary functions

function _tuple_interleave(tu::Tuple{Vararg{AbstractVector, N}}) where {N}
	N > 0 || return Any[]
	n = length(first(tu))
	all(v -> length(v) == n, tu) || throw(ArgumentError(
		"all vectors passed to `_tuple_interleave` must have the same length.",
	))
	T = mapreduce(eltype, promote_type, tu)
	out = Vector{T}(undef, Base.Checked.checked_mul(N, n))
	j = 1
	for values in zip(tu...)
		for value in values
			@inbounds out[j] = value
			j += 1
		end
	end
	return out
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
	kw = Dict{Symbol, Any}(:values => values)
	labels === nothing || (kw[:labels] = labels)
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

function _hierarchy_trace(
	constructor,
	labels,
	parents;
	values,
	colors,
	colorscale::String,
	name::String,
)
	length(labels) == length(parents) ||
		throw(ArgumentError("`labels` and `parents` must have the same length; got $(length(labels)) and $(length(parents))."))
	kw = Dict{Symbol, Any}(
		:labels => labels,
		:parents => parents,
	)
	if values !== nothing
		length(values) == length(labels) ||
			throw(ArgumentError(
				"`values` must match `labels` in length; got " *
				"$(length(values)) and $(length(labels)).",
			))
		kw[:values] = values
	end

	marker = Dict{Symbol,Any}()
	if colors !== nothing
		length(colors) == length(labels) ||
			throw(ArgumentError(
				"`colors` must match `labels` in length; got " *
				"$(length(colors)) and $(length(labels)).",
			))
		marker[:colors] = colors
	end
	if !isempty(colorscale)
		if colors === nothing && values !== nothing
			marker[:colors] = kw[:values]
		end
		marker[:colorscale] = colorscale
	end
	isempty(marker) || (kw[:marker] = attr(; marker...))
	name == "" || (kw[:name] = name)
	return constructor(; kw...)
end

"""
	plot_sunburst(labels, parents; values=nothing, colors=nothing,
		colorscale="", kwargs...)

Hierarchical sunburst chart. `parents[i]` is the label of `labels[i]`'s parent
(use `""` for a root). Optional `values` size the slices. When `colorscale`
is set, `values` color the slices unless `colors` are supplied explicitly.
Without either array, Plotly derives colors from the hierarchy.
"""
function plot_sunburst(
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	fig = Plot(
		_hierarchy_trace(
			sunburst,
			labels,
			parents;
			values = values,
			colors = colors,
			colorscale = colorscale,
			name = "",
		),
		Layout(),
	)
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_sunburst!(fig, labels, parents; values=nothing, colors=nothing,
		colorscale="", kwargs...)

Append a sunburst trace to an existing figure.
"""
function plot_sunburst!(
	fig,
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(
		_plot_data(fig),
		_hierarchy_trace(
			sunburst,
			labels,
			parents;
			values = values,
			colors = colors,
			colorscale = colorscale,
			name = "",
		),
	)
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_treemap(labels, parents; values=nothing, colors=nothing,
		colorscale="", kwargs...)

Hierarchical treemap chart. See [`plot_sunburst`](@ref) for the `labels`/`parents` convention.
"""
function plot_treemap(
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
)
	fig = Plot(
		_hierarchy_trace(
			treemap,
			labels,
			parents;
			values = values,
			colors = colors,
			colorscale = colorscale,
			name = "",
		),
		Layout(),
	)
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_treemap!(fig, labels, parents; values=nothing, colors=nothing,
		colorscale="", kwargs...)

Append a treemap trace to an existing figure.
"""
function plot_treemap!(
	fig,
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	colorscale::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(
		_plot_data(fig),
		_hierarchy_trace(
			treemap,
			labels,
			parents;
			values = values,
			colors = colors,
			colorscale = colorscale,
			name = "",
		),
	)
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
	kw = Dict{Symbol, Any}(:values => values)
	labels === nothing || (kw[:labels] = labels)
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
	kw = Dict{Symbol, Any}(:values => values)
	labels === nothing || (kw[:labels] = labels)
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
		kw[:measure] = measure
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray};
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray};
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

# Shared body of plot_area / plot_area!: one filled scatter trace per series.
# `stack = true` puts every series of the call in the stack group "one", which
# also stacks them on earlier `stack = true` areas of the same axes; otherwise
# each series is filled to zero.
function _area_impl!(
	fig,
	x,
	y;
	who::AbstractString,
	constructor::Bool,
	secondary_y::Bool = false,
	color = "",
	legend = "",
	mode::AbstractString = "lines",
	stack::Bool = false,
	hatch::AbstractString = "",
	showlegend = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid = true,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
)
	xs, ys, _ = _scat_series(x, y, who)
	n = length(ys)
	n_existing = _scat_existing_count(fig)
	trace_mode = _scat_mode(mode, who)
	styles = _scat_series_styles(
		n,
		n_existing,
		who;
		mode = trace_mode,
		color = color,
		legend = legend,
		showlegend = showlegend,
	)
	_hatch_pattern(hatch; who = who)
	_scat_validate_cartesian_options(
		fig,
		who;
		ykey = _scat_twin_key(fig, secondary_y),
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
	)

	ykey = secondary_y ? _ensure_twin_y!(fig; who = who) : :yaxis
	yref = secondary_y ? _cmn_axis_ref(ykey; who = who) : ""
	data = _plot_data(fig)
	for index in 1:n
		style = styles[index]
		fields = Dict{Symbol, Any}(
			:x => xs[index],
			:y => ys[index],
			:mode => trace_mode,
			:name => isempty(style.name) ? "" : _label(style.name),
		)
		isempty(style.color) || (fields[:line] = attr(color = style.color))
		if stack
			fields[:stackgroup] = "one"
		else
			fields[:fill] = "tozeroy"
		end
		pattern = _hatch_pattern(hatch; who = who)
		pattern === nothing || (fields[:fillpattern] = pattern)
		style.showlegend === nothing || (fields[:showlegend] = style.showlegend)
		isempty(yref) || (fields[:yaxis] = yref)
		push!(data, GenericTrace("scatter", fields))
	end
	# A constructor's `grid = true` keeps the template grid; a mutator applies
	# any non-nothing `grid`, so `true` re-enables a grid switched off earlier.
	constructor || _apply_cartesian_grid_override!(fig, grid, who)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		grid = constructor ? grid : nothing,
		fontsize = fontsize,
		title = title,
		xscale = xscale,
		yscale = yscale,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
		ykey = ykey,
		apply_template = constructor,
		who = who,
	)
	return nothing
end

"""
	plot_area(x, y; kwargs...) -> Plot (or SyncPlot with `show = true`)
	plot_area(y; kwargs...)

Filled-area plot: each series is a line filled down to zero, or, with
`stack = true`, stacked on the series before it (Plotly `stackgroup`). The
one-argument form uses `x = 0:length(y)-1` (per series).

#### Data

- `x`, `y`: vectors of equal length, or a vector of vectors in `y` (one area
  per series) with `x` shared or nested like `y`. Matrices and complex values
  throw an `ArgumentError`.

#### Keywords

- `color = ""`: line and fill colour per series (scalar or vector; the fill is
  the colour at half opacity). `legend = ""`: names per series;
  `showlegend = nothing`: force legend entries on or off (scalar or vector).
- `mode = "lines"`: trace mode (`"lines+markers"`, ...).
- `stack = false`: stack the series of this call, and any later
  `plot_area!(...; stack = true)` series on the same axes, on top of each
  other. A single series also joins the stack, so stacks can be built one
  `plot_area!` call at a time. (Plotly lists stacked areas in reverse order
  in the legend so the entries follow the stack.)
- `hatch = ""`: matplotlib hatch pattern drawn over the fill: `"/"`, `"\\\\"`,
  `"x"`, `"-"`, `"|"`, `"+"`, `"."` (repeat a character for density, e.g.
  `"///"`).
- `title`, `xlabel`, `ylabel`, `xscale`, `yscale`, `xrange`, `yrange`,
  `xticks`, `xticklabels`, `yticks`, `yticklabels`, `xtickformat`,
  `ytickformat`, `equalar`, `grid`, `width`, `height`, `fontsize`, `show`: as
  for [`plot_scatter`](@ref) (ranges in data units, `grid = true` keeps the
  template grid).

#### Example

```julia
t = 0:10
fig = plot_area(t, [rand(11), rand(11)]; stack = true, legend = ["a", "b"])
plot_area!(fig, t, rand(11); stack = true, legend = "c", hatch = "//")
```
"""
function plot_area(
	x::AbstractArray,
	y::AbstractArray;
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	mode::AbstractString = "lines",
	stack::Bool = false,
	hatch::AbstractString = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_area_impl!(
		fig,
		x,
		y;
		who = "plot_area",
		constructor = true,
		color = color,
		legend = legend,
		mode = mode,
		stack = stack,
		hatch = hatch,
		showlegend = showlegend,
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
	)
	return _scat_maybe_show(fig, show, width, height, title)
end

plot_area(y::AbstractArray; kwargs...) =
	plot_area(_auto_xvalues(y; who = "plot_area"), y; kwargs...)

"""
	plot_area!(fig, x, y; kwargs...) -> nothing (SubplotFigure: the figure)
	plot_area!(fig, y; kwargs...)

Append filled-area trace(s) to an existing `Plot`, [`SyncPlot`](@ref) or
`SubplotFigure` cell (see [`plot_area`](@ref)). Takes every keyword of
`plot_area` except `show` (an `ArgumentError`), plus `secondary_y = false`
(draw on a secondary y axis, created on first use on a `Plot`/`SyncPlot`) and
`row`/`col` (`SubplotFigure` only). `grid = nothing` keeps the current grid.
With `stack = true` the new series stack on the earlier `stack = true` areas
of the same axes.
"""
function plot_area!(
	fig,
	x::AbstractArray,
	y::AbstractArray;
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	mode::AbstractString = "lines",
	stack::Bool = false,
	hatch::AbstractString = "",
	showlegend::Union{Nothing, Bool, AbstractVector} = nothing,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	yrange::Union{Nothing, AbstractVector, Tuple} = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	yticks = nothing,
	yticklabels = nothing,
	xtickformat::AbstractString = "",
	ytickformat::AbstractString = "",
	equalar::Bool = false,
	kwargs...,
)
	who = "plot_area!"
	secondary_y = _scat_mutator_options(who, kwargs)
	_area_impl!(
		fig,
		x,
		y;
		who = who,
		constructor = false,
		secondary_y = secondary_y,
		color = color,
		legend = legend,
		mode = mode,
		stack = stack,
		hatch = hatch,
		showlegend = showlegend,
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		xticks = xticks,
		xticklabels = xticklabels,
		yticks = yticks,
		yticklabels = yticklabels,
		xtickformat = xtickformat,
		ytickformat = ytickformat,
		equalar = equalar,
	)
	_refresh!(fig)
	return nothing
end

plot_area!(fig, y::AbstractArray; kwargs...) =
	plot_area!(fig, _auto_xvalues(y; who = "plot_area!"), y; kwargs...)

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
			xlabel::String = "",
			ylabel::String = "",
			title::String = "",
			width::Int = 0,
			height::Int = 0,
			fontsize::Int = 0,
			grid::Union{Nothing, Bool} = nothing,
		)
			push!(_plot_data(fig), _ohlc_trace($ctor, x, open, high, low, close;
				increasing_color = increasing_color, decreasing_color = decreasing_color, legend = legend))
			_apply_cartesian_grid_override!(fig, grid)
			_apply_cartesian_plot_options!(
				fig;
				xlabel = xlabel,
				ylabel = ylabel,
				title = title,
				width = width,
				height = height,
				fontsize = fontsize,
				refresh = true,
				apply_template = false,
			)
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
	xlabel::String = "",
	ylabel::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	grid::Union{Nothing, Bool} = nothing,
)
	push!(_plot_data(fig), _histogram2d_trace(x, y; nbinsx = nbinsx, nbinsy = nbinsy, colorscale = colorscale, histnorm = histnorm))
	_apply_cartesian_grid_override!(fig, grid)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		refresh = true,
		apply_template = false,
	)
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
	label === nothing || (node[:label] = label)
	isempty(node_color) || (node[:color] = node_color)
	link = Dict{Symbol, Any}(
		:source => source,
		:target => target,
		:value => value,
	)
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
	if d isa Pair
		values = last(d)
		return attr(
			label = String(first(d)),
			values = values isa AbstractVector ?
				values :
				collect(values),
		)
	end
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
		lc = Dict{Symbol, Any}(:color => line_color)
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
		lc = Dict{Symbol, Any}(:color => line_color)
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

function _apply_ternary_labels!(
	fig;
	alabel::String = "",
	blabel::String = "",
	clabel::String = "",
)
	ternary = Dict{Symbol, Any}()
	alabel == "" ||
		(ternary[:aaxis] = attr(title_text = alabel))
	blabel == "" ||
		(ternary[:baxis] = attr(title_text = blabel))
	clabel == "" ||
		(ternary[:caxis] = attr(title_text = clabel))
	isempty(ternary) && return nothing
	_merge_ternary_layout_attr!(
		_plot_layout(fig),
		:ternary,
		attr(; ternary...),
	)
	return nothing
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
	alabel::String = "",
	blabel::String = "",
	clabel::String = "",
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
)
	push!(_plot_data(fig), _ternary_trace(a, b, c; mode = mode, color = color, legend = legend, marker_size = marker_size))
	_apply_ternary_labels!(
		fig;
		alabel = alabel,
		blabel = blabel,
		clabel = clabel,
	)
	_apply_basic_plot_options!(fig; title = title, width = width, height = height, fontsize = fontsize, apply_template = false)
	_refresh!(fig)
	return nothing
end

# ── Image ────────────────────────────────────────────────────────────

# Present an H×W×C numeric array in Plotly's row/pixel/channel JSON order
# without materializing one heap object per pixel/channel. PlotlyBase's JSON
# lowering reverses Julia array dimensions, so this lazy C×W×H permutation
# serializes identically to a nested H×W×C vector. Pass already-nested data
# through unchanged.
function _image_z(z)
	ndims(z) == 3 || return z
	channels = size(z, 3)
	channels in (3, 4) || throw(ArgumentError(
		"an H×W×C image must have 3 (RGB) or 4 (RGBA) channels; got C=$channels.",
	))
	return PermutedDimsArray(z, (3, 2, 1))
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

function _apply_scene_mutator_options!(
	fig;
	xrange,
	yrange,
	zrange,
	xlabel::String,
	ylabel::String,
	zlabel::String,
	aspectmode::Union{Nothing, String},
	title::String,
	width::Int,
	height::Int,
	perspective::Union{Nothing, Bool},
	grid::Union{Nothing, Bool},
	showaxis::Union{Nothing, Bool},
	fontsize::Int,
)
	_apply_scene_style_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		perspective = perspective,
		grid = grid,
		showaxis = showaxis,
	)
	isempty(title) || relayout!(fig, title = title)
	_apply_scene_ranges!(
		fig;
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
	)
	width > 0 && relayout!(fig, width = width)
	height > 0 && relayout!(fig, height = height)
	_apply_default_legend!(fig)
	fontsize > 0 && relayout!(fig, font = attr(size = fontsize))
	return nothing
end

function _require_mesh_indices(indices, name::Symbol, vertex_count::Int)
	(
		indices isa AbstractVector ||
		indices isa Tuple
	) || throw(ArgumentError(
		"mesh3d: `$name` must be a one-dimensional index collection.",
	))
	index_count = try
		length(indices)
	catch err
		(
			err isa MethodError ||
			err isa ArgumentError ||
			err isa TypeError
		) || rethrow()
		throw(ArgumentError(
			"mesh3d: `$name` must be a finite index collection.",
		))
	end
	for (position, index) in enumerate(indices)
		(
			index isa Integer &&
			!(index isa Bool) &&
			0 <= index < vertex_count
		) || throw(ArgumentError(
			"mesh3d: `$name[$position]` must be a zero-based integer " *
			"between 0 and $(vertex_count - 1); got $(repr(index)).",
		))
	end
	return index_count
end

function _mesh3d_trace(x, y, z; i, j, k, intensity, color::String, colorscale::String, opacity::Real)
	vertex_count = length(x)
	(length(y) == vertex_count && length(z) == vertex_count) ||
		throw(ArgumentError(
			"mesh3d: x, y, z must share length; got " *
			"$(length(x)), $(length(y)), $(length(z)).",
		))
	(
		opacity isa Bool ||
		!isfinite(opacity) ||
		opacity < 0 ||
		opacity > 1
	) && throw(ArgumentError(
		"mesh3d: `opacity` must be a finite number between 0 and 1.",
	))

	kw = Dict{Symbol, Any}(:x => x, :y => y, :z => z)
	index_values = (i, j, k)
	index_presence = map(value -> value !== nothing, index_values)
	if any(index_presence) && !all(index_presence)
		throw(ArgumentError(
			"mesh3d: triangle indices `i`, `j`, and `k` must be " *
			"supplied together or all omitted.",
		))
	elseif all(index_presence)
		index_lengths = (
			_require_mesh_indices(i, :i, vertex_count),
			_require_mesh_indices(j, :j, vertex_count),
			_require_mesh_indices(k, :k, vertex_count),
		)
		(index_lengths[1] == index_lengths[2] == index_lengths[3]) ||
			throw(ArgumentError(
				"mesh3d: i, j, k must share length; got " *
				"$(join(index_lengths, ", ")).",
			))
		kw[:i] = i
		kw[:j] = j
		kw[:k] = k
	end
	if intensity !== nothing
		length(intensity) == vertex_count ||
			throw(ArgumentError(
				"mesh3d: `intensity` must match x/y/z in length; got " *
				"$(length(intensity)) and $vertex_count.",
			))
		kw[:intensity] = intensity
	end
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray},
	z::Union{AbstractVector, SubArray};
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
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray},
	z::Union{AbstractVector, SubArray};
	i = nothing, j = nothing, k = nothing,
	intensity::Union{Nothing, AbstractVector} = nothing,
	color::String = "", colorscale::String = "", opacity::Real = 1,
	xrange::Vector = [0, 0], yrange::Vector = [0, 0], zrange::Vector = [0, 0],
	xlabel::String = "", ylabel::String = "", zlabel::String = "",
	aspectmode::Union{Nothing, String} = nothing, title::String = "",
	width::Int = 0, height::Int = 0, fontsize::Int = 0,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
)
	push!(_plot_data(fig), _mesh3d_trace(x, y, z; i = i, j = j, k = k, intensity = intensity, color = color, colorscale = colorscale, opacity = opacity))
	_apply_scene_mutator_options!(
		fig;
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		title = title,
		width = width,
		height = height,
		perspective = perspective,
		grid = grid,
		showaxis = showaxis,
		fontsize = fontsize,
	)
	_refresh!(fig)
	return nothing
end

function _field3d_trace(constructor, x, y, z, value; isomin, isomax, surface_count::Int, colorscale::String, opacity::Real)
	kw = Dict{Symbol, Any}(
		:x => x,
		:y => y,
		:z => z,
		:value => value,
	)
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
			x::Union{AbstractVector, SubArray},
			y::Union{AbstractVector, SubArray},
			z::Union{AbstractVector, SubArray},
			value::Union{AbstractVector, SubArray};
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
			x::Union{AbstractVector, SubArray},
			y::Union{AbstractVector, SubArray},
			z::Union{AbstractVector, SubArray},
			value::Union{AbstractVector, SubArray};
			isomin::Union{Nothing, Real} = nothing, isomax::Union{Nothing, Real} = nothing,
			surface_count::Int = 0, colorscale::String = "", opacity::Real = $defop,
			xrange::Vector = [0, 0], yrange::Vector = [0, 0], zrange::Vector = [0, 0],
			xlabel::String = "", ylabel::String = "", zlabel::String = "",
			aspectmode::Union{Nothing, String} = nothing, title::String = "",
			width::Int = 0, height::Int = 0, fontsize::Int = 0,
			perspective::Union{Nothing, Bool} = nothing,
			grid::Union{Nothing, Bool} = nothing,
			showaxis::Union{Nothing, Bool} = nothing,
		)
			push!(_plot_data(fig), _field3d_trace($ctor, x, y, z, value; isomin = isomin, isomax = isomax,
				surface_count = surface_count, colorscale = colorscale, opacity = opacity))
			_apply_scene_mutator_options!(
				fig;
				xrange = xrange,
				yrange = yrange,
				zrange = zrange,
				xlabel = xlabel,
				ylabel = ylabel,
				zlabel = zlabel,
				aspectmode = aspectmode,
				title = title,
				width = width,
				height = height,
				perspective = perspective,
				grid = grid,
				showaxis = showaxis,
				fontsize = fontsize,
			)
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
	xlabel::String = "", ylabel::String = "", zlabel::String = "",
	aspectmode::Union{Nothing, String} = nothing, title::String = "",
	width::Int = 0, height::Int = 0, fontsize::Int = 0,
	perspective::Union{Nothing, Bool} = nothing,
	grid::Union{Nothing, Bool} = nothing,
	showaxis::Union{Nothing, Bool} = nothing,
)
	push!(_plot_data(fig), _streamtube_trace(x, y, z, u, v, w; sizeref = sizeref, colorscale = colorscale))
	_apply_scene_mutator_options!(
		fig;
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		title = title,
		width = width,
		height = height,
		perspective = perspective,
		grid = grid,
		showaxis = showaxis,
		fontsize = fontsize,
	)
	_refresh!(fig)
	return nothing
end

# ── Geographic maps ──────────────────────────────────────────────────

function _require_equal_geo_lengths(
	kind::AbstractString,
	values::Pair{Symbol}...,
)
	lengths = map(value -> length(last(value)), values)
	all(==(first(lengths)), lengths) && return nothing
	names = join((String(first(value)) for value in values), ", ")
	throw(ArgumentError(
		"$kind: $names must share length; got $(join(lengths, ", ")).",
	))
end

function _trace_keyword_dict(kwargs)
	result = Dict{Symbol,Any}()
	for (key, value) in pairs(kwargs)
		result[Symbol(key)] = value
	end
	return result
end

function _set_optional_colorscale!(
	kwargs::Dict{Symbol,Any},
	colorscale,
)
	if colorscale isa AbstractString
		isempty(colorscale) || (kwargs[:colorscale] = String(colorscale))
	elseif colorscale !== nothing
		kwargs[:colorscale] = colorscale
	end
	return kwargs
end

function _is_finite_plotly_number(value)
	(value isa Real && !(value isa Bool)) || return false
	# JSON can encode arbitrary-precision Julia numbers that JavaScript then
	# parses as ±Infinity. Plotly.js number fields require a finite IEEE-754
	# Number, so validate representability without coercing the caller's value.
	converted = try
		Float64(value)
	catch err
		(
			err isa MethodError ||
			err isa InexactError ||
			err isa OverflowError ||
			err isa DomainError ||
			err isa ArgumentError ||
			err isa TypeError
		) || rethrow()
		return false
	end
	return isfinite(converted)
end

function _require_bounded_numeric_option(
	kind::AbstractString,
	name::AbstractString,
	value;
	minimum::Real,
	maximum::Union{Nothing,Real} = nothing,
)
	values = value isa AbstractVector ? value : (value,)
	valid = all(values) do entry
		_is_finite_plotly_number(entry) || return false
		entry >= minimum || return false
		maximum === nothing || entry <= maximum
	end
	valid && return nothing

	bounds = maximum === nothing ?
		"at least $minimum" :
		"between $minimum and $maximum"
	throw(ArgumentError(
		"$kind: $name must contain only finite numeric values $bounds.",
	))
end

# `color`: "" / nothing = Plotly default; a String or Symbol is one colour; a
# vector is per point (colour names or numbers mapped through the colorscale).
# `marker_size`: nothing = default; a Real or a per-point vector, >= 0.
function _set_geo_marker!(
	kwargs::Dict{Symbol,Any},
	kind::AbstractString,
	color,
	marker_size,
)
	marker = _symbol_dict(get(kwargs, :marker, nothing))
	changed = false
	if color isa Union{AbstractString,Symbol}
		text = String(color)
		if !isempty(text)
			marker[:color] = text
			changed = true
		end
	elseif color !== nothing
		marker[:color] = color
		changed = true
	end
	if marker_size !== nothing
		_require_bounded_numeric_option(
			kind,
			"marker_size",
			marker_size;
			minimum = 0,
		)
		marker[:size] = marker_size
		changed = true
	end
	changed && (kwargs[:marker] = attr(; marker...))
	return kwargs
end

function _geo_layout(
	scope::AbstractString,
	projection::AbstractString,
)
	g = Dict{Symbol, Any}()
	isempty(scope) || (g[:scope] = String(scope))
	isempty(projection) ||
		(g[:projection] = attr(type = String(projection)))
	return isempty(g) ? Layout() : Layout(geo = attr(; g...))
end

# Figure-level keywords shared by every geographic constructor and mutator
# (geo, mapbox and MapLibre families). `0` means automatic. The minimums are
# the plotly.js schema minimums (`layout.width`/`height` >= 10 px,
# `font.size` >= 1); pixel sizes are rounded to whole pixels because the
# Electron window and raster exports are integer-sized. Validates only, so
# callers can run it before mutating anything.
function _geo_figure_options(
	who::AbstractString;
	title::AbstractString,
	width::Real,
	height::Real,
	fontsize::Real,
)
	for (name, value, minimum) in (
		("width", width, 10),
		("height", height, 10),
		("fontsize", fontsize, 1),
	)
		valid =
			_is_finite_plotly_number(value) &&
			abs(Float64(value)) <= maxintfloat(Float64) &&
			(iszero(value) || value >= minimum)
		valid || throw(ArgumentError(
			"$who: `$name` must be 0 (automatic) or a finite number of at " *
			"least $minimum; got $(repr(value)).",
		))
	end
	return (
		title = String(title),
		width = round(Int, Float64(width)),
		height = round(Int, Float64(height)),
		fontsize = fontsize,
	)
end

# Apply validated `_geo_figure_options` to a constructed (`apply_template =
# true`) or appended-to (`false`: only the legend is refreshed so a user
# template survives) figure. A new title is stored as `attr(text = ...)` and
# keeps the existing title's other attributes (position, font).
function _apply_geo_figure_options!(
	fig,
	options;
	apply_template::Bool,
)
	_apply_basic_plot_options!(fig; apply_template = apply_template)
	title = _title_attr(options.title)
	if title !== nothing
		existing = get(_plot_layout(fig).fields, :title, nothing)
		if _is_layout_mapping(existing)
			merged = _symbol_dict(existing)
			merged[:text] = options.title
			title = attr(; merged...)
		end
		relayout!(fig, title = title)
	end
	options.width > 0 && relayout!(fig, width = options.width)
	options.height > 0 && relayout!(fig, height = options.height)
	options.fontsize > 0 &&
		relayout!(fig, font = attr(size = options.fontsize))
	return nothing
end

# Shared trace builder of scattergeo / scattermapbox / scattermap. Per-point
# `color` and `marker_size` vectors must match the coordinates: plotly.js
# silently drops the points past a shorter marker array.
function _geo_scatter_trace(
	kind::AbstractString,
	constructor,
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString,
	color,
	marker_size,
	legend::AbstractString,
	trace_kwargs,
)
	_require_equal_geo_lengths(
		kind,
		:lon => lon,
		:lat => lat,
	)
	_require_map_vector_length(kind, "color", color, length(lon))
	_require_map_vector_length(
		kind,
		"marker_size",
		marker_size,
		length(lon),
	)
	kw = _trace_keyword_dict(trace_kwargs)
	kw[:lon] = lon
	kw[:lat] = lat
	kw[:mode] = String(mode)
	_set_geo_marker!(kw, kind, color, marker_size)
	isempty(legend) || (kw[:name] = String(legend))
	return constructor(; kw...)
end

const _CHOROPLETH_LOCATIONMODES =
	("ISO-3", "USA-states", "country names", "geojson-id")

# plotly.js uses a choropleth's `geojson` only when it is a nonempty URL
# string or an object (choropleth supplyDefaults); anything else is ignored.
_is_plotly_geojson(value) =
	value isa AbstractString ? !isempty(value) : _is_layout_mapping(value)

function _choropleth_trace(
	locations::AbstractVector,
	z::AbstractVector;
	locationmode::Union{Nothing,AbstractString},
	geojson,
	featureidkey::AbstractString,
	colorscale,
	trace_kwargs,
)
	_require_equal_geo_lengths(
		"choropleth",
		:locations => locations,
		:z => z,
	)
	has_geojson = _is_plotly_geojson(geojson)
	geojson === nothing || has_geojson || throw(ArgumentError(
		"choropleth: `geojson` must be a GeoJSON object (Dict, attr or " *
		"NamedTuple) or a nonempty URL string; got $(typeof(geojson)).",
	))
	# An explicit mode always wins. Otherwise match GeoJSON features when a
	# GeoJSON is given (plotly.js' own default) and country names if not.
	mode =
		locationmode !== nothing ? String(locationmode) :
		has_geojson ? "geojson-id" : "country names"
	mode in _CHOROPLETH_LOCATIONMODES || throw(ArgumentError(
		"choropleth: `locationmode` must be one of " *
		"$(join(repr.(_CHOROPLETH_LOCATIONMODES), ", ")); got $(repr(mode)).",
	))
	mode == "geojson-id" && !has_geojson && throw(ArgumentError(
		"choropleth: locationmode=\"geojson-id\" requires `geojson`.",
	))
	isempty(featureidkey) || mode == "geojson-id" || throw(ArgumentError(
		"choropleth: `featureidkey` only applies to GeoJSON locations " *
		"(locationmode=\"geojson-id\"); got locationmode=$(repr(mode)).",
	))
	kw = _trace_keyword_dict(trace_kwargs)
	kw[:locations] = locations
	kw[:z] = z
	kw[:locationmode] = mode
	has_geojson && (kw[:geojson] = geojson)
	isempty(featureidkey) ||
		(kw[:featureidkey] = String(featureidkey))
	_set_optional_colorscale!(kw, colorscale)
	return choropleth(; kw...)
end

function _require_valid_mapbox_view(
	zoom,
	center_lon,
	center_lat,
	bearing = nothing,
	pitch = nothing,
)
	for (name, value) in (
		(:zoom, zoom),
		(:center_lon, center_lon),
		(:center_lat, center_lat),
		(:bearing, bearing),
		(:pitch, pitch),
	)
		value === nothing && continue
		valid = _is_finite_plotly_number(value)
		valid || throw(ArgumentError(
			"mapbox: $name must be a finite JavaScript-representable " *
			"real number, not $(repr(value)).",
		))
	end
	return nothing
end

function _require_mapbox_mapping(
	value,
	path::AbstractString,
)
	(
		value isa PlotlyBase.PlotlyAttribute ||
		value isa AbstractDict ||
		value isa NamedTuple
	) || throw(ArgumentError(
		"mapbox: $path must be an attribute object.",
	))
	return nothing
end

function _require_valid_mapbox_options(
	mapbox,
	key,
	finalized_mapping,
)
	# An empty style string never finishes loading in plotly.js (an export
	# then blocks), so stored styles are validated like the keyword.
	haskey(mapbox, :style) &&
		_require_valid_map_style(mapbox[:style]; family = "mapbox")
	center = Dict{Symbol,Any}()
	if haskey(mapbox, :center) &&
		mapbox[:center] !== nothing
		center_value = mapbox[:center]
		_require_mapbox_mapping(
			center_value,
			"layout.$key.center",
		)
		_require_unambiguous_layout_mapping(
			center_value,
			"layout.$key.center",
		)
		center = finalized_mapping(center_value)
	end
	_require_valid_mapbox_view(
		get(mapbox, :zoom, nothing),
		get(center, :lon, nothing),
		get(center, :lat, nothing),
		get(mapbox, :bearing, nothing),
		get(mapbox, :pitch, nothing),
	)
	return nothing
end

function _require_valid_mapbox_layouts(layout::Layout)
	for (key, value) in layout.fields
		startswith(String(key), "mapbox") || continue
		_require_mapbox_mapping(
			value,
			"layout.$key",
		)
		_require_unambiguous_layout_mapping(
			value,
			"layout.$key",
		)
		mapbox = _symbol_dict(value)
		_require_valid_mapbox_options(
			mapbox,
			key,
			_symbol_dict,
		)
	end
	return nothing
end

function _finalized_layout_value(
	mutations,
	layout::Layout,
	key::Symbol,
)
	fields = _builtin_layout_mapping_fields(layout.fields)
	if fields !== nothing && haskey(mutations, fields)
		return get(
			_symbol_dict(mutations[fields]),
			key,
			nothing,
		)
	end
	return get(layout.fields, key, nothing)
end

function _finalized_layout_mapping_dict(mutations, value)
	fields = _builtin_layout_mapping_fields(value)
	if fields !== nothing && haskey(mutations, fields)
		return _symbol_dict(mutations[fields])
	end
	return _symbol_dict(value)
end

function _finalized_layout_attr(
	mutations,
	value,
	deep_keys::Tuple{Vararg{Symbol}},
)
	contents =
		_finalized_layout_mapping_dict(mutations, value)
	for key in deep_keys
		haskey(contents, key) || continue
		nested = contents[key]
		_is_layout_mapping(nested) || continue
		contents[key] = attr(
			_finalized_layout_mapping_dict(
				mutations,
				nested,
			),
		)
	end
	return attr(contents)
end

function _require_valid_finalized_mapbox_layouts(
	mutations,
	layout::Layout,
	targets,
)
	for key in targets
		value = _finalized_layout_value(
			mutations,
			layout,
			key,
		)
		_require_mapbox_mapping(
			value,
			"layout.$key",
		)
		_require_unambiguous_layout_mapping(
			value,
			"layout.$key",
		)
		mapbox = _finalized_layout_mapping_dict(
			mutations,
			value,
		)
		_require_valid_mapbox_options(
			mapbox,
			key,
			value -> _finalized_layout_mapping_dict(
				mutations,
				value,
			),
		)
	end
	return nothing
end

function _update_mapboxes_preserving_aliases!(
	layout::Layout,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	temporary = Layout()
	PlotlyBase.update_mapboxes!(temporary, with; kwargs...)
	update = get(temporary.fields, :mapbox, nothing)
	update === nothing && return layout

	targets = Symbol[
		key for key in keys(layout.fields)
		if startswith(String(key), "mapbox")
	]
	:mapbox in targets || pushfirst!(targets, :mapbox)
	context = _new_layout_merge_context()
	for key in targets
		_prepare_layout_attr_merge!(
			context,
			layout,
			key,
			update;
			deep_merge_paths =
				_MAPBOX_LAYOUT_MERGE_PATHS,
			mutate_builtin_target = true,
		)
	end
	mutations = _finalize_layout_merge_context(context)
	for key in targets
		_require_valid_finalized_layout_merge(
			mutations,
			layout,
			key,
		)
	end
	_commit_layout_merge_context!(context, mutations)
	return layout
end

function _mapbox_layout(
	style,
	zoom,
	center_lon,
	center_lat,
)
	_require_valid_mapbox_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style; family = "mapbox")
	m = Dict{Symbol, Any}()
	style === nothing ||
		(m[:style] = style isa AbstractString ? String(style) : style)
	zoom === nothing || (m[:zoom] = zoom)
	center = Dict{Symbol,Any}()
	center_lon === nothing || (center[:lon] = center_lon)
	center_lat === nothing || (center[:lat] = center_lat)
	if !isempty(center)
		m[:center] = attr(center)
	end
	layout = Layout()
	isempty(m) || (layout.fields[:mapbox] = attr(m))
	return layout
end

# plotly.js renders a mapbox subplot without `style` only with a Mapbox
# access token (its default "basic" style is token-gated) and otherwise
# refuses to draw or export. The mapbox constructors therefore default to
# this token-free style, and the mutators apply it to a target that has none.
const _DEFAULT_MAPBOX_STYLE = "open-street-map"

# The style stored in a mapbox layout root, or `nothing` when the root, or
# its style, is absent or `nothing`.
function _mapbox_root_style(root)
	_is_layout_mapping(root) || return nothing
	return get(_symbol_dict(root), :style, nothing)
end

# The `style` to forward when a mapbox mutator runs for a SubplotFigure cell.
# The delegate runs the Plot-level mutator against an empty staging Plot, so
# the mutator cannot see the target cell: forward the caller's style, else
# the cell's current one (an unchanged merge), else the token-free default.
# `nothing` (non-mapbox or empty cell) leaves the error to the delegate.
function _subplot_mapbox_cell_style(
	sf::SubplotFigure,
	row,
	col,
	style,
)
	style === nothing || return style
	r, c = _resolve_subplot_cell(sf; row = row, col = col)
	p = _plot_obj(getfield(sf, :fig))
	grid_ref = p.layout.subplots.grid_ref
	(isassigned(grid_ref, r, c) && !isempty(grid_ref[r, c])) ||
		return nothing
	ref = first(grid_ref[r, c])
	(ref.subplot_kind == "mapbox" && length(ref.layout_keys) == 1) ||
		return nothing
	existing = _mapbox_root_style(
		get(p.layout.fields, only(ref.layout_keys), nothing),
	)
	return existing === nothing ? _DEFAULT_MAPBOX_STYLE : existing
end

function _subplot_mapbox_delegate!(
	sf::SubplotFigure,
	mutator::Function,
	args::Tuple;
	row::Union{Nothing,Integer},
	col::Union{Nothing,Integer},
	style,
	kwargs...,
)
	# Hold the (reentrant) metadata lock across the cell lookup and the
	# delegated transaction so another task cannot restyle the cell between.
	return lock(getfield(sf, :_lock)) do
		_subplot_delegate_mutator!(
			sf,
			mutator,
			args...;
			row = row,
			col = col,
			style = _subplot_mapbox_cell_style(sf, row, col, style),
			kwargs...,
		)
	end
end

function _apply_geo_layout_options!(
	fig;
	scope::AbstractString,
	projection::AbstractString,
)
	source = _geo_layout(scope, projection)
	haskey(source.fields, :geo) || return nothing
	_merge_layout_attr!(
		_plot_layout(fig),
		:geo,
		source.fields[:geo];
		deep_merge_paths = _GEO_LAYOUT_MERGE_PATHS,
		mutate_builtin_target = true,
	)
	return nothing
end

function _apply_mapbox_layout_options!(
	fig;
	style,
	zoom,
	center_lon,
	center_lat,
)
	if style === nothing && _mapbox_root_style(
		get(_plot_layout(fig).fields, :mapbox, nothing),
	) === nothing
		style = _DEFAULT_MAPBOX_STYLE
	end
	source = _mapbox_layout(
		style,
		zoom,
		center_lon,
		center_lat,
	)
	haskey(source.fields, :mapbox) || return nothing
	_merge_layout_attr!(
		_plot_layout(fig),
		:mapbox,
		source.fields[:mapbox];
		deep_merge_paths =
			_MAPBOX_LAYOUT_MERGE_PATHS,
		mutate_builtin_target = true,
	)
	return nothing
end

include("modern_map_api.jl")
include("modern_map_updates.jl")

# 2.0 scientific-plotting extensions. Order matters: later files may use helpers
# from earlier ones.
include("sci/base.jl")
include("sci/common.jl")
include("sci/color.jl")
include("sci/mathtext.jl")
include("sci/style.jl")
include("sci/export.jl")
include("sci/colorbar.jl")
include("sci/axes.jl")
include("sci/text.jl")
include("sci/reference.jl")
include("sci/lines.jl")
include("sci/mesh2d.jl")
include("sci/fields.jl")
include("sci/scene3d.jl")

"""
	plot_choropleth(locations, z; locationmode=nothing, geojson=nothing,
		featureidkey="", colorscale="", scope="", projection="", title="",
		width=0, height=0, fontsize=0, show=false, kwargs...)

Choropleth on a `geo` (outline) map: shade the regions named by `locations`
by the values `z`.

# Arguments
- `locations::AbstractVector`: region identifiers, matched as `locationmode` says.
- `z::AbstractVector`: one value per location (same length as `locations`),
  coloured through `colorscale`.

# Keywords
- `locationmode::Union{Nothing,AbstractString} = nothing`: how `locations` are
  matched: `"country names"`, `"ISO-3"`, `"USA-states"` or `"geojson-id"`.
  `nothing` selects `"geojson-id"` when `geojson` is given and
  `"country names"` otherwise.
- `geojson = nothing`: a GeoJSON `FeatureCollection` (`Dict`, `attr` or
  `NamedTuple`) or a URL string; its features are matched by `locations`.
- `featureidkey::AbstractString = ""`: the GeoJSON feature property matched by
  `locations` (plotly.js default `"id"`), e.g. `"properties.name"`. Only valid
  with `"geojson-id"` matching.
- `colorscale::Union{AbstractString,AbstractVector} = ""`: Plotly colorscale
  name or `[[t, color], ...]` stops; `""` keeps the default.
- `scope::AbstractString = ""`: geo scope (`"world"`, `"europe"`, `"usa"`, ...).
- `projection::AbstractString = ""`: geo projection type (`"mercator"`, ...).
- `title::AbstractString = ""`: figure title.
- `width::Real = 0`, `height::Real = 0`: figure size in pixels (0 = automatic,
  otherwise at least 10; rounded to whole pixels).
- `fontsize::Real = 0`: global font size (0 = template default, otherwise ≥ 1).
- `show::Bool = false`: open the figure in a window and return a `SyncPlot`.
- `kwargs...`: further Plotly `choropleth` trace attributes (`zmin`, `zmax`,
  `hovertext`, `marker_line_color`, ...).

Throws `ArgumentError` for mismatched lengths, an unknown `locationmode`,
`"geojson-id"` matching without `geojson`, `featureidkey` without GeoJSON
matching, or an invalid size.

Returns a `Plot`, or a `SyncPlot` when `show=true`.

# Example
```julia
fig = plot_choropleth(["France", "Germany", "Spain"], [1.0, 2.0, 3.0];
	scope="europe", title="Values")
```
"""
function plot_choropleth(
	locations::AbstractVector,
	z::AbstractVector;
	locationmode::Union{Nothing,AbstractString} = nothing,
	geojson = nothing,
	featureidkey::AbstractString = "",
	colorscale::Union{AbstractString,AbstractVector} = "",
	scope::AbstractString = "",
	projection::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_choropleth";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	trace = _choropleth_trace(
		locations,
		z;
		locationmode = locationmode,
		geojson = geojson,
		featureidkey = featureidkey,
		colorscale = colorscale,
		trace_kwargs = kwargs,
	)
	fig = Plot(trace, _geo_layout(scope, projection))
	_apply_geo_figure_options!(fig, options; apply_template = true)
	return _maybe_show(
		fig,
		show,
		options.width,
		options.height,
		options.title,
	)
end

"""
	plot_choropleth!(fig, locations, z; locationmode=nothing, geojson=nothing,
		featureidkey="", colorscale="", scope="", projection="", title="",
		width=0, height=0, fontsize=0, kwargs...)
	plot_choropleth!(sf::SubplotFigure, locations, z; row=nothing, col=nothing, kwargs...)

Append a choropleth trace (see [`plot_choropleth`](@ref) for the arguments and
keywords; `show` is not accepted). `fig` is a `Plot`, a `SyncPlot` or a
`SubplotFigure`; on a `SubplotFigure` the trace goes to the `geo` cell given
by `row`/`col` (pass both; default: the active cell) and `title`/`width`/
`height` are ignored with a warning (they are figure-wide).

Layout keywords change the figure only when set: `scope`/`projection` merge
into the existing `geo` object, and a `title` keeps the existing title's
position and font. A user template is preserved.

Throws `ArgumentError` (leaving `fig` unchanged) for invalid input.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_choropleth(["France"], [1.0]; scope="europe")
plot_choropleth!(fig, ["Italy"], [2.0])
```
"""
function plot_choropleth!(
	fig,
	locations::AbstractVector,
	z::AbstractVector;
	locationmode::Union{Nothing,AbstractString} = nothing,
	geojson = nothing,
	featureidkey::AbstractString = "",
	colorscale::Union{AbstractString,AbstractVector} = "",
	scope::AbstractString = "",
	projection::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_choropleth!";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	trace = _choropleth_trace(
		locations,
		z;
		locationmode = locationmode,
		geojson = geojson,
		featureidkey = featureidkey,
		colorscale = colorscale,
		trace_kwargs = kwargs,
	)
	push!(_plot_data(fig), trace)
	_apply_geo_layout_options!(
		fig;
		scope = scope,
		projection = projection,
	)
	_apply_geo_figure_options!(fig, options; apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_scattergeo(lon, lat; mode="markers", color="", marker_size=nothing,
		legend="", scope="", projection="", title="", width=0, height=0,
		fontsize=0, show=false, kwargs...)

Scatter points (or lines) on a `geo` (outline) map at longitudes `lon` and
latitudes `lat` in degrees.

# Arguments
- `lon::AbstractVector`, `lat::AbstractVector`: coordinates (equal lengths).

# Keywords
- `mode::AbstractString = "markers"`: Plotly scatter mode (`"markers"`,
  `"lines"`, `"lines+markers"`, `"text"`, ...).
- `color::Union{Nothing,AbstractString,Symbol,AbstractVector} = ""`: marker
  colour; one colour, or one value per point (colour names, or numbers
  coloured through `marker_colorscale`). `""`/`nothing` keeps the default.
- `marker_size::Union{Nothing,Real,AbstractVector} = nothing`: marker size in
  pixels (≥ 0), scalar or one per point.
- `legend::AbstractString = ""`: legend name of the trace.
- `scope::AbstractString = ""`, `projection::AbstractString = ""`: geo scope
  and projection type (see [`plot_choropleth`](@ref)).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_choropleth`](@ref).
- `kwargs...`: further Plotly `scattergeo` trace attributes.

Per-point vectors must have the coordinate length; mismatches, negative or
non-finite sizes, and invalid figure sizes throw `ArgumentError`.

Returns a `Plot`, or a `SyncPlot` when `show=true`.

# Example
```julia
fig = plot_scattergeo([2.35, 13.40], [48.86, 52.52]; color="red",
	marker_size=10, legend="cities", scope="europe")
```
"""
function plot_scattergeo(
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString = "markers",
	color::Union{Nothing,AbstractString,Symbol,AbstractVector} = "",
	marker_size::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	scope::AbstractString = "",
	projection::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_scattergeo";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	trace = _geo_scatter_trace(
		"scattergeo",
		scattergeo,
		lon,
		lat;
		mode = mode,
		color = color,
		marker_size = marker_size,
		legend = legend,
		trace_kwargs = kwargs,
	)
	fig = Plot(trace, _geo_layout(scope, projection))
	_apply_geo_figure_options!(fig, options; apply_template = true)
	return _maybe_show(
		fig,
		show,
		options.width,
		options.height,
		options.title,
	)
end

"""
	plot_scattergeo!(fig, lon, lat; mode="markers", color="",
		marker_size=nothing, legend="", scope="", projection="", title="",
		width=0, height=0, fontsize=0, kwargs...)
	plot_scattergeo!(sf::SubplotFigure, lon, lat; row=nothing, col=nothing, kwargs...)

Append a scattergeo trace (see [`plot_scattergeo`](@ref) for the arguments and
keywords; `show` is not accepted). `fig` is a `Plot`, a `SyncPlot` or a
`SubplotFigure`; on a `SubplotFigure` the trace goes to the `geo` cell given
by `row`/`col` (pass both; default: the active cell) and `title`/`width`/
`height` are ignored with a warning.

Layout keywords change the figure only when set; `scope`/`projection` merge
into the existing `geo` object and a user template is preserved.

Throws `ArgumentError` (leaving `fig` unchanged) for invalid input.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_scattergeo([2.35], [48.86]; legend="Paris")
plot_scattergeo!(fig, [13.40], [52.52]; legend="Berlin", color=:blue)
```
"""
function plot_scattergeo!(
	fig,
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString = "markers",
	color::Union{Nothing,AbstractString,Symbol,AbstractVector} = "",
	marker_size::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	scope::AbstractString = "",
	projection::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_scattergeo!";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	trace = _geo_scatter_trace(
		"scattergeo",
		scattergeo,
		lon,
		lat;
		mode = mode,
		color = color,
		marker_size = marker_size,
		legend = legend,
		trace_kwargs = kwargs,
	)
	push!(_plot_data(fig), trace)
	_apply_geo_layout_options!(
		fig;
		scope = scope,
		projection = projection,
	)
	_apply_geo_figure_options!(fig, options; apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_scattermapbox(lon, lat; mode="markers", color="", marker_size=nothing,
		legend="", style="open-street-map", zoom=0, center_lon=nothing,
		center_lat=nothing, title="", width=0, height=0, fontsize=0,
		show=false, kwargs...)

Scatter points (or lines) on a legacy Mapbox tile map at `(lon, lat)`
(degrees). The MapLibre-based [`plot_scattermap`](@ref) is the modern
equivalent.

# Arguments
- `lon::AbstractVector`, `lat::AbstractVector`: coordinates (equal lengths).

# Keywords
- `mode`, `color`, `marker_size`, `legend`: as for [`plot_scattergeo`](@ref).
- `style = "open-street-map"`: tile style: a nonempty style name/URL or a
  nonempty Mapbox style object. The default needs no access token; Mapbox
  styles (`"basic"`, `"streets"`, `mapbox://...`) need `layout.mapbox.accesstoken`.
- `zoom = 0`: initial zoom level (finite number).
- `center_lon = nothing`, `center_lat = nothing`: initial map centre in
  degrees (`nothing` keeps plotly.js' automatic centre).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_choropleth`](@ref).
- `kwargs...`: further Plotly `scattermapbox` trace attributes.

Throws `ArgumentError` for mismatched lengths, an empty or non-string,
non-object `style`, non-finite view values or invalid sizes.

Returns a `Plot`, or a `SyncPlot` when `show=true`.

# Example
```julia
fig = plot_scattermapbox([2.35, 13.40], [48.86, 52.52]; zoom=3,
	center_lon=8, center_lat=50)
```
"""
function plot_scattermapbox(
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString = "markers",
	color::Union{Nothing,AbstractString,Symbol,AbstractVector} = "",
	marker_size::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = _DEFAULT_MAPBOX_STYLE,
	zoom = 0,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_scattermapbox";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _mapbox_layout(style, zoom, center_lon, center_lat)
	trace = _geo_scatter_trace(
		"scattermapbox",
		scattermapbox,
		lon,
		lat;
		mode = mode,
		color = color,
		marker_size = marker_size,
		legend = legend,
		trace_kwargs = kwargs,
	)
	fig = Plot(trace, layout)
	_apply_geo_figure_options!(fig, options; apply_template = true)
	return _maybe_show(
		fig,
		show,
		options.width,
		options.height,
		options.title,
	)
end

"""
	plot_scattermapbox!(fig, lon, lat; mode="markers", color="",
		marker_size=nothing, legend="", style=nothing, zoom=nothing,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, kwargs...)
	plot_scattermapbox!(sf::SubplotFigure, lon, lat; row=nothing, col=nothing, kwargs...)

Append a scattermapbox trace (see [`plot_scattermapbox`](@ref) for the
arguments and keywords; `show` is not accepted). `fig` is a `Plot`, a
`SyncPlot` or a `SubplotFigure`; on a `SubplotFigure` the trace goes to the
`mapbox` cell given by `row`/`col` (pass both; default: the active cell) and
`title`/`width`/`height` are ignored with a warning.

The map-view keywords default to `nothing`, which keeps the target's current
value. A target without a style (a bare `Plot()`, a new `subplots` mapbox
cell) gets the token-free `"open-street-map"` style, because plotly.js cannot
draw or export a mapbox subplot without a style or an access token.

Throws `ArgumentError` (leaving `fig` unchanged) for invalid input.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = Plot()
plot_scattermapbox!(fig, [2.35], [48.86]; zoom=4, center_lon=2, center_lat=48)
```
"""
function plot_scattermapbox!(
	fig,
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString = "markers",
	color::Union{Nothing,AbstractString,Symbol,AbstractVector} = "",
	marker_size::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = nothing,
	zoom = nothing,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_scattermapbox!";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_mapbox_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style; family = "mapbox")
	trace = _geo_scatter_trace(
		"scattermapbox",
		scattermapbox,
		lon,
		lat;
		mode = mode,
		color = color,
		marker_size = marker_size,
		legend = legend,
		trace_kwargs = kwargs,
	)
	push!(_plot_data(fig), trace)
	_apply_mapbox_layout_options!(
		fig;
		style = style,
		zoom = zoom,
		center_lon = center_lon,
		center_lat = center_lat,
	)
	_apply_geo_figure_options!(fig, options; apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_choroplethmapbox(geojson, locations, z; featureidkey="",
		colorscale="", marker_line_color=nothing, marker_line_width=nothing,
		marker_opacity=nothing, legend="", style="open-street-map", zoom=0,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, show=false, kwargs...)

Shade GeoJSON features on a legacy Mapbox tile map. The MapLibre-based
[`plot_choroplethmap`](@ref) is the modern equivalent.

# Arguments
- `geojson`: a GeoJSON `FeatureCollection` (`Dict`, `attr`, `NamedTuple`) or URL.
- `locations::AbstractVector`: feature ids matched against `featureidkey`.
- `z::AbstractVector`: one value per location (same length as `locations`).

# Keywords
- `featureidkey::AbstractString = ""`: feature property matched by
  `locations` (`""` = plotly.js default `"id"`).
- `colorscale::Union{AbstractString,AbstractVector} = ""`: colorscale name or stops.
- `marker_line_color::Union{Nothing,AbstractString,Symbol,AbstractVector} = nothing`:
  boundary colour, scalar or one per location.
- `marker_line_width::Union{Nothing,Real,AbstractVector} = nothing`: boundary
  width in pixels (≥ 0), scalar or one per location.
- `marker_opacity::Union{Nothing,Real,AbstractVector} = nothing`: fill opacity
  in [0, 1], scalar or one per location.
- `legend::AbstractString = ""`: legend name of the trace.
- `style`, `zoom`, `center_lon`, `center_lat`: map view, as for
  [`plot_scattermapbox`](@ref).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_choropleth`](@ref).
- `kwargs...`: further Plotly `choroplethmapbox` trace attributes.

Per-location vectors must have the `locations` length; mismatches and
out-of-range values throw `ArgumentError`.

Returns a `Plot`, or a `SyncPlot` when `show=true`.

# Example
```julia
square = Dict("type" => "FeatureCollection", "features" => [Dict(
	"type" => "Feature", "id" => "A", "properties" => Dict(),
	"geometry" => Dict("type" => "Polygon",
		"coordinates" => [[[0, 0], [0, 5], [5, 5], [5, 0], [0, 0]]]))])
fig = plot_choroplethmapbox(square, ["A"], [1.0]; zoom=3, center_lon=2.5, center_lat=2.5)
```
"""
function plot_choroplethmapbox(
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	featureidkey::AbstractString = "",
	colorscale::Union{AbstractString,AbstractVector} = "",
	marker_line_color::Union{Nothing,AbstractString,Symbol,AbstractVector} = nothing,
	marker_line_width::Union{Nothing,Real,AbstractVector} = nothing,
	marker_opacity::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = _DEFAULT_MAPBOX_STYLE,
	zoom = 0,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_choroplethmapbox";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _mapbox_layout(style, zoom, center_lon, center_lat)
	trace = _choroplethmap_trace(
		geojson,
		locations,
		z;
		kind = "choroplethmapbox",
		constructor = choroplethmapbox,
		featureidkey = featureidkey,
		colorscale = colorscale,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		marker_opacity = marker_opacity,
		legend = legend,
		trace_kwargs = kwargs,
	)
	fig = Plot(trace, layout)
	_apply_geo_figure_options!(fig, options; apply_template = true)
	return _maybe_show(
		fig,
		show,
		options.width,
		options.height,
		options.title,
	)
end

"""
	plot_choroplethmapbox!(fig, geojson, locations, z; featureidkey="",
		colorscale="", marker_line_color=nothing, marker_line_width=nothing,
		marker_opacity=nothing, legend="", style=nothing, zoom=nothing,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, kwargs...)
	plot_choroplethmapbox!(sf::SubplotFigure, geojson, locations, z; row=nothing, col=nothing, kwargs...)

Append a GeoJSON choroplethmapbox trace (see
[`plot_choroplethmapbox`](@ref) for the arguments and keywords; `show` is not
accepted). `fig` is a `Plot`, a `SyncPlot` or a `SubplotFigure`; on a
`SubplotFigure` the trace goes to the `mapbox` cell given by `row`/`col`
(pass both; default: the active cell) and `title`/`width`/`height` are
ignored with a warning.

The map-view keywords default to `nothing`, which keeps the target's current
value; a target without a style gets the token-free `"open-street-map"`
style (see [`plot_scattermapbox!`](@ref)).

Throws `ArgumentError` (leaving `fig` unchanged) for invalid input.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_scattermapbox([2.5], [2.5]; zoom=3)
plot_choroplethmapbox!(fig, square, ["A"], [1.0]; marker_opacity=0.5)
```
"""
function plot_choroplethmapbox!(
	fig,
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	featureidkey::AbstractString = "",
	colorscale::Union{AbstractString,AbstractVector} = "",
	marker_line_color::Union{Nothing,AbstractString,Symbol,AbstractVector} = nothing,
	marker_line_width::Union{Nothing,Real,AbstractVector} = nothing,
	marker_opacity::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = nothing,
	zoom = nothing,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_choroplethmapbox!";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_mapbox_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style; family = "mapbox")
	trace = _choroplethmap_trace(
		geojson,
		locations,
		z;
		kind = "choroplethmapbox",
		constructor = choroplethmapbox,
		featureidkey = featureidkey,
		colorscale = colorscale,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		marker_opacity = marker_opacity,
		legend = legend,
		trace_kwargs = kwargs,
	)
	push!(_plot_data(fig), trace)
	_apply_mapbox_layout_options!(
		fig;
		style = style,
		zoom = zoom,
		center_lon = center_lon,
		center_lat = center_lat,
	)
	_apply_geo_figure_options!(fig, options; apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_densitymapbox(lon, lat, z; radius=0, colorscale="",
		style="open-street-map", zoom=0, center_lon=nothing, center_lat=nothing,
		title="", width=0, height=0, fontsize=0, show=false, kwargs...)

Density heatmap of weighted points `(lon, lat, z)` on a legacy Mapbox tile
map. The MapLibre-based [`plot_densitymap`](@ref) is the modern equivalent.

# Arguments
- `lon::AbstractVector`, `lat::AbstractVector`: point coordinates in degrees.
- `z::AbstractVector`: point weights (same length as `lon`/`lat`).

# Keywords
- `radius::Union{Real,AbstractVector} = 0`: influence radius of each point in
  pixels, scalar or one per point, each ≥ 1. `0` keeps plotly.js' default.
- `colorscale::Union{AbstractString,AbstractVector} = ""`: colorscale name or stops.
- `style`, `zoom`, `center_lon`, `center_lat`: map view, as for
  [`plot_scattermapbox`](@ref).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_choropleth`](@ref).
- `kwargs...`: further Plotly `densitymapbox` trace attributes.

Throws `ArgumentError` for mismatched lengths (including a per-point
`radius`), radii below 1 and invalid map-view or size values.

Returns a `Plot`, or a `SyncPlot` when `show=true`.

# Example
```julia
fig = plot_densitymapbox(randn(200), randn(200), rand(200); radius=15, zoom=4)
```
"""
function plot_densitymapbox(
	lon::AbstractVector,
	lat::AbstractVector,
	z::AbstractVector;
	radius::Union{Real,AbstractVector} = 0,
	colorscale::Union{AbstractString,AbstractVector} = "",
	style = _DEFAULT_MAPBOX_STYLE,
	zoom = 0,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_densitymapbox";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _mapbox_layout(style, zoom, center_lon, center_lat)
	trace = _densitymap_trace(
		lon,
		lat,
		z;
		kind = "densitymapbox",
		constructor = densitymapbox,
		radius = radius,
		colorscale = colorscale,
		trace_kwargs = kwargs,
	)
	fig = Plot(trace, layout)
	_apply_geo_figure_options!(fig, options; apply_template = true)
	return _maybe_show(
		fig,
		show,
		options.width,
		options.height,
		options.title,
	)
end

"""
	plot_densitymapbox!(fig, lon, lat, z; radius=0, colorscale="",
		style=nothing, zoom=nothing, center_lon=nothing, center_lat=nothing,
		title="", width=0, height=0, fontsize=0, kwargs...)
	plot_densitymapbox!(sf::SubplotFigure, lon, lat, z; row=nothing, col=nothing, kwargs...)

Append a densitymapbox trace (see [`plot_densitymapbox`](@ref) for the
arguments and keywords; `show` is not accepted). `fig` is a `Plot`, a
`SyncPlot` or a `SubplotFigure`; on a `SubplotFigure` the trace goes to the
`mapbox` cell given by `row`/`col` (pass both; default: the active cell) and
`title`/`width`/`height` are ignored with a warning.

The map-view keywords default to `nothing`, which keeps the target's current
value; a target without a style gets the token-free `"open-street-map"`
style (see [`plot_scattermapbox!`](@ref)).

Throws `ArgumentError` (leaving `fig` unchanged) for invalid input.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_scattermapbox([0.0], [0.0])
plot_densitymapbox!(fig, randn(50), randn(50), rand(50); radius=20)
```
"""
function plot_densitymapbox!(
	fig,
	lon::AbstractVector,
	lat::AbstractVector,
	z::AbstractVector;
	radius::Union{Real,AbstractVector} = 0,
	colorscale::Union{AbstractString,AbstractVector} = "",
	style = nothing,
	zoom = nothing,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_densitymapbox!";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_mapbox_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style; family = "mapbox")
	trace = _densitymap_trace(
		lon,
		lat,
		z;
		kind = "densitymapbox",
		constructor = densitymapbox,
		radius = radius,
		colorscale = colorscale,
		trace_kwargs = kwargs,
	)
	push!(_plot_data(fig), trace)
	_apply_mapbox_layout_options!(
		fig;
		style = style,
		zoom = zoom,
		center_lon = center_lon,
		center_lat = center_lat,
	)
	_apply_geo_figure_options!(fig, options; apply_template = false)
	_refresh!(fig)
	return nothing
end

#endregion

# The public high-level mutators above intentionally accept several figure-like
# targets through an untyped first argument. Install strictly-more-specific
# Plot/SyncPlot methods with the same remaining positional signatures. Each
# wrapper runs the original implementation against `_StagedPlotMutation`, so
# direct vector pushes and all nested layout helpers are published by one
# renderer transaction.
const _TRANSACTIONAL_HIGH_LEVEL_PLOT_MUTATORS = (
	:plot_scatter!,
	:plot_stem!,
	:plot_bar!,
	:plot_histogram!,
	:plot_box!,
	:plot_violin!,
	:plot_scatterpolar!,
	:plot_heatmap!,
	:plot_contour!,
	:plot_quiver!,
	:plot_surface!,
	:plot_scatter3d!,
	:plot_quiver3d!,
	:plot_pie!,
	:plot_sunburst!,
	:plot_treemap!,
	:plot_funnel!,
	:plot_funnelarea!,
	:plot_waterfall!,
	:plot_indicator!,
	:plot_area!,
	:plot_candlestick!,
	:plot_ohlc!,
	:plot_histogram2d!,
	:annotate!,
	:plot_sankey!,
	:plot_parcoords!,
	:plot_ternary!,
	:plot_image!,
	:plot_mesh3d!,
	:plot_isosurface!,
	:plot_volume!,
	:plot_streamtube!,
	:plot_choropleth!,
	:plot_scattergeo!,
	:plot_scattermap!,
	:plot_choroplethmap!,
	:plot_densitymap!,
	:plot_scattermapbox!,
	:plot_choroplethmapbox!,
	:plot_densitymapbox!,
	:set_template!,
	_SCI_COMMON_MUTATORS...,
	_SCI_COLOR_MUTATORS...,
	_SCI_MATHTEXT_MUTATORS...,
	_SCI_STYLE_MUTATORS...,
	_SCI_EXPORT_MUTATORS...,
	_SCI_COLORBAR_MUTATORS...,
	_SCI_AXES_MUTATORS...,
	_SCI_TEXT_MUTATORS...,
	_SCI_REFERENCE_MUTATORS...,
	_SCI_LINES_MUTATORS...,
	_SCI_MESH2D_MUTATORS...,
	_SCI_FIELDS_MUTATORS...,
	_SCI_SCENE3D_MUTATORS...,
)

function _is_transactional_high_level_plot_mutator(mutator::Function)
	for function_name in _TRANSACTIONAL_HIGH_LEVEL_PLOT_MUTATORS
		mutator === getfield(@__MODULE__, function_name) &&
			return true
	end
	return false
end

function _install_transactional_high_level_plot_wrappers!()
	for function_name in _TRANSACTIONAL_HIGH_LEVEL_PLOT_MUTATORS
		mutator = getfield(@__MODULE__, function_name)
		for method in collect(methods(mutator))
			method.module === (@__MODULE__) || continue
			signature = Base.unwrap_unionall(method.sig)
			positional_types = signature.parameters[2:end]
			isempty(positional_types) && continue
			first(positional_types) === Any || continue

			argument_types = positional_types[2:end]
			argument_names = [
				gensym(:argument)
				for _ in argument_types
			]
			typed_arguments = [
				:($(argument_names[ind])::$(argument_types[ind]))
				for ind in eachindex(argument_types)
			]
			definition = quote
				function $(function_name)(
					fig::Union{Plot,SyncPlot},
					$(typed_arguments...);
					kwargs...,
				)
					return _transactional_high_level_plot_mutation!(
						$(function_name),
						fig,
						$(argument_names...);
						kwargs...,
					)
				end
			end
			Core.eval(@__MODULE__, definition)
		end
	end
	return nothing
end

_install_transactional_high_level_plot_wrappers!()
