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
	x::AbstractVector,
	y::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _stats_subplot_delegate!(
		sf,
		plot_bar!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		who = "plot_bar!",
		kwargs...,
	)
end

function plot_bar!(
	sf::SubplotFigure,
	y::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _stats_subplot_delegate!(
		sf,
		plot_bar!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		who = "plot_bar!",
		kwargs...,
	)
end

function plot_histogram!(
	sf::SubplotFigure,
	x::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _stats_subplot_delegate!(
		sf,
		plot_histogram!,
		x;
		row = row,
		col = col,
		secondary_y = secondary_y,
		who = "plot_histogram!",
		kwargs...,
	)
end

function plot_box!(
	sf::SubplotFigure,
	x::AbstractVector,
	y::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _stats_subplot_delegate!(
		sf,
		plot_box!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		who = "plot_box!",
		kwargs...,
	)
end

function plot_box!(
	sf::SubplotFigure,
	y::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _stats_subplot_delegate!(
		sf,
		plot_box!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		who = "plot_box!",
		kwargs...,
	)
end

function plot_violin!(
	sf::SubplotFigure,
	x::AbstractVector,
	y::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _stats_subplot_delegate!(
		sf,
		plot_violin!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		who = "plot_violin!",
		kwargs...,
	)
end

function plot_violin!(
	sf::SubplotFigure,
	y::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _stats_subplot_delegate!(
		sf,
		plot_violin!,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		who = "plot_violin!",
		kwargs...,
	)
end

function plot_histogram2d!(
	sf::SubplotFigure,
	x::AbstractVector,
	y::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	kwargs...,
)
	return _stats_subplot_delegate!(
		sf,
		plot_histogram2d!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		who = "plot_histogram2d!",
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
	(:plot_area!, 1),
	(:plot_area!, 2),
	(:plot_candlestick!, 5),
	(:plot_ohlc!, 5),
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
@inline _is_nested_series(::AbstractVector{<:AbstractVector}) = true
@inline _is_nested_series(::Any) = false

# Abstractly typed containers (`ys = []; push!(ys, v)`, JSON-parsed data) carry
# no element type to dispatch on, so their elements are inspected. A container
# mixing series vectors with scalar values is ambiguous and is rejected rather
# than plotted as one garbage series.
function _is_nested_series(values::AbstractVector)
	isconcretetype(eltype(values)) && return false
	isempty(values) && return false
	nested_count = count(value -> value isa AbstractVector, values)
	nested_count == 0 && return false
	nested_count == length(values) ||
		throw(ArgumentError(
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

function _nested_coordinate_mode(primary, secondary, primary_name::Symbol, secondary_name::Symbol)
	primary_nested = _is_nested_series(primary)
	secondary_nested = _is_nested_series(secondary)
	if secondary_nested
		primary_nested || throw(ArgumentError(
			"`$secondary_name` contains multiple series but `$primary_name` contains one series.",
		))
		length(secondary) == length(primary) || throw(ArgumentError(
			"`$secondary_name` and `$primary_name` must contain the same number of series; " *
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

# Compute a finite scalar `tick0` from possibly nested / non-finite data.
# Handles a vector-of-vectors (multi-series), ignores non-finite entries, and
# returns `nothing` when no finite value exists — so the axis simply omits
# `tick0` instead of receiving an invalid Vector or NaN. Iterates lazily (no
# flattening allocation) so it is cheap even for large series.
function _safe_tick0(v)
	if _is_nested_series(v)
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
	nx = _is_nested_series(error_x)
	ny = _is_nested_series(error_y)
	for (n, t) in enumerate(traces)
		if error_x !== nothing && !(nx && n > length(error_x))
			payload = nx ? error_x[n] : error_x
			t.error_x = attr(
				type = "data",
				array = payload,
				visible = true,
			)
		end
		if error_y !== nothing && !(ny && n > length(error_y))
			payload = ny ? error_y[n] : error_y
			t.error_y = attr(
				type = "data",
				array = payload,
				visible = true,
			)
		end
	end
	return nothing
end

function _auto_xvalues(y)
	if _is_nested_series(y)
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
	refresh::Bool = false,
	apply_template::Bool = true,
	who::AbstractString = "plot",
)
	# Validate every option before the first write so a rejected keyword
	# leaves the figure untouched.
	_validate_cartesian_options(
		fig,
		who;
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
	)

	_apply_figure_title!(fig, title)
	_apply_axis_title!(fig, :x, xlabel)
	_apply_axis_title!(fig, :y, ylabel)
	# Scale before range: a logarithmic axis stores its range as exponents.
	_apply_axis_scale!(fig, :x, xscale, who)
	_apply_axis_scale!(fig, :y, yscale, who)
	_apply_axis_range!(fig, :x, xrange, who)
	_apply_axis_range!(fig, :y, yrange, who)
	_apply_figure_size!(fig, who; width = width, height = height)
	# `grid = true` keeps the template's grid (the constructor default);
	# `false` or an axis selector overrides it.
	grid === true || _apply_axis_grid!(fig, grid, who)
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

# ── Statistical traces: bar, histogram, box, violin, histogram2d ─────────────
# The constructors and `!` mutators of this family share the builders below, so
# both validate and build identically. Every `_stats_*` builder is pure: it
# validates its inputs and returns new traces without touching a figure; the
# callers then validate the figure options and only afterwards write.

const _STATS_HISTNORMS = ("", "percent", "probability", "density", "probability density")
const _STATS_BARMODES = ("", "group", "overlay", "stack", "relative")
const _STATS_TEXTPOSITIONS = ("", "inside", "outside", "auto", "none")
const _STATS_POINT_MODES = ("all", "outliers", "suspectedoutliers")
const _STATS_VIOLIN_SIDES = ("both", "positive", "negative")
# Trace opacity of automatically overlaid histograms: every series stays
# visible where they overlap while the colours remain identifiable (checked on
# rendered overlays of two overlapping normal samples).
const _STATS_OVERLAY_OPACITY = 0.6
# Trace types whose layout is governed by the figure-wide `layout.barmode`.
const _STATS_BARMODE_TRACE_TYPES = ("bar", "histogram")

# What the stats rules need to know about the SubplotFigure cell being filled.
# The subplot delegate runs the mutator on an empty staged Plot, so the
# histogram overlay rule (figure-wide bar mode) and the box/violin collision
# rule (boxes already in the cell) read the real figure from here.
struct _StatsCellContext
	# Root `layout.barmode` of the SubplotFigure (`nothing` when unset).
	barmode::Any
	# Field dictionaries of the traces already drawn on the target cell's axes.
	traces::Vector{Any}
end

# `nothing` outside a SubplotFigure call; set by `_stats_subplot_delegate!`.
const _STATS_SUBPLOT_CELL = Base.ScopedValues.ScopedValue{Union{Nothing, _StatsCellContext}}(nothing)

function _stats_choice(
	value::AbstractString,
	choices,
	who::AbstractString,
	name::AbstractString,
)
	value in choices || throw(ArgumentError(
		"$(who): `$(name)` must be one of $(join(repr.(choices), ", ")); got $(repr(value)).",
	))
	return String(value)
end

function _stats_orientation(orientation::AbstractString, who::AbstractString)
	orientation in ("", "v", "h") || throw(ArgumentError(
		"$(who): `orientation` must be \"v\" (vertical), \"h\" (horizontal) or \"\" " *
		"(vertical); got $(repr(orientation)).",
	))
	return String(orientation)
end

# Optional number restricted to [lo, hi]; `nothing` means unset.
function _stats_number(value, who::AbstractString, name::AbstractString, lo::Real, hi::Real)
	value === nothing && return nothing
	(value isa Real && !(value isa Bool) && isfinite(value) && lo <= value <= hi) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a number in [$(lo), $(hi)] or nothing; got $(repr(value)).",
		))
	return value
end

function _stats_count(value::Integer, who::AbstractString, name::AbstractString)
	(!(value isa Bool) && value >= 0) || throw(ArgumentError(
		"$(who): `$(name)` must be a non-negative integer (0 = automatic); got $(repr(value)).",
	))
	return Int(value)
end

_stats_label(text::AbstractString) = isempty(text) ? "" : _label(text)

# A plotted series must be data Plotly can draw: complex numbers serialize as
# {re, im} objects that plotly.js silently does not plot. Abstractly typed
# containers are scanned because their element type says nothing.
function _stats_check_series(series, who::AbstractString, name::AbstractString)
	element_type = eltype(series)
	complex_values = element_type !== Union{} && (
		element_type <: Complex ||
		(!isconcretetype(element_type) && any(value -> value isa Complex, series))
	)
	complex_values && throw(ArgumentError(
		"$(who): `$(name)` has complex values, which Plotly cannot draw; pass " *
		"real.(v), imag.(v), abs.(v) or angle.(v).",
	))
	return series
end

# Split `values` (the series to draw) and their optional `positions`
# (categories or coordinates, either shared or one per series) into per-series
# lists, checking series counts.
function _stats_series_lists(
	values,
	positions,
	who::AbstractString,
	value_name::AbstractString,
	position_name::AbstractString,
)
	values_nested = _is_nested_series(values)
	positions_nested = positions !== nothing && _is_nested_series(positions)
	if positions_nested
		values_nested || throw(ArgumentError(
			"$(who): `$(position_name)` holds $(length(positions)) series but " *
			"`$(value_name)` holds a single series.",
		))
		length(positions) == length(values) || throw(ArgumentError(
			"$(who): `$(value_name)` and `$(position_name)` must hold the same number " *
			"of series; got $(length(values)) and $(length(positions)).",
		))
	end
	value_list = values_nested ? Any[series for series in values] : Any[values]
	position_list = positions_nested ? Any[series for series in positions] :
		Any[positions for _ in value_list]
	for (index, series) in enumerate(value_list)
		_stats_check_series(series, who, value_name)
		position_series = position_list[index]
		position_series === nothing && continue
		_stats_check_series(position_series, who, position_name)
		length(position_series) == length(series) || throw(ArgumentError(
			values_nested ?
			"$(who): series $(index) of `$(value_name)` has $(length(series)) values " *
			"but `$(position_name)` has $(length(position_series)) for it." :
			"$(who): `$(value_name)` has $(length(series)) values but " *
			"`$(position_name)` has $(length(position_series)).",
		))
	end
	return value_list, position_list, values_nested
end

# Per-series colours: one string or symbol for every series, or a vector with
# one entry per series (short vectors leave the remaining series on the colour
# cycle, long vectors are truncated, like the other per-series keywords).
function _stats_colors(color, count::Int, who::AbstractString)
	if color isa AbstractVector
		entries = String[]
		for entry in color
			(entry isa AbstractString || entry isa Symbol) || throw(ArgumentError(
				"$(who): `color` entries must be strings or symbols; got $(repr(entry)).",
			))
			push!(entries, String(entry))
		end
		return _series_kwarg_vector(entries, count, "", String)
	end
	(color isa AbstractString || color isa Symbol) || throw(ArgumentError(
		"$(who): `color` must be a string, a symbol or a vector of them; got $(repr(color)).",
	))
	return fill(String(color), count)
end

_stats_names(legend, count::Int) =
	String[_stats_label(name) for name in _series_kwarg_vector(legend, count, "", String)]

_stats_showlegends(showlegend, count::Int) =
	_series_kwarg_vector(showlegend, count, nothing, Union{Nothing, Bool})

function _stats_patterns(hatch, count::Int, who::AbstractString)
	hatches = _series_kwarg_vector(hatch, count, "", String)
	return Any[_hatch_pattern(entry; who = who) for entry in hatches]
end

# The part of a per-point keyword that belongs to series `index`: a flat vector
# (shared by every series) or a vector of vectors (one per series). Like the
# other per-series keywords, a vector of vectors with fewer entries than there
# are series leaves the remaining series without it (`nothing` is returned)
# and surplus entries are ignored. The part's length must match the series'
# point count.
function _stats_point_part(
	value,
	index::Int,
	point_count::Int,
	who::AbstractString,
	name::AbstractString,
)
	part = value
	if _is_nested_series(value)
		index <= length(value) || return nothing
		part = value[index]
	end
	length(part) == point_count || throw(ArgumentError(
		"$(who): `$(name)` has $(length(part)) entries for a series of $(point_count) values.",
	))
	return part
end

# Error-bar attribute for one series: a vector of magnitudes (symmetric), a
# vector of such vectors (one per series), or a `(minus, plus)` tuple of either
# form (asymmetric). Series without an entry (including an empty vector of
# vectors) get no error bars.
function _stats_error_bars(
	errors,
	index::Int,
	point_count::Int,
	who::AbstractString,
	name::AbstractString,
)
	errors === nothing && return nothing
	form_message = "$(who): `$(name)` must be a vector of error magnitudes, a vector " *
		"of such vectors (one per series) or a (minus, plus) tuple of them"
	if errors isa Tuple
		length(errors) == 2 || throw(ArgumentError("$(form_message); got a $(length(errors))-tuple."))
		parts = map(enumerate(("minus", "plus"))) do (position, side)
			part = errors[position]
			part isa AbstractVector || throw(ArgumentError("$(form_message); the $(side) part is $(typeof(part))."))
			_stats_check_error_values(part, who, "$(name) ($(side))")
			_stats_point_part(part, index, point_count, who, "$(name) ($(side))")
		end
		all(isnothing, parts) && return nothing
		any(isnothing, parts) && throw(ArgumentError(
			"$(who): the minus and plus parts of `$(name)` must cover the same series; " *
			"series $(index) has only one of them.",
		))
		return attr(
			type = "data",
			symmetric = false,
			array = parts[2],
			arrayminus = parts[1],
			visible = true,
		)
	end
	errors isa AbstractVector || throw(ArgumentError("$(form_message); got $(typeof(errors))."))
	_stats_check_error_values(errors, who, name)
	part = _stats_point_part(errors, index, point_count, who, name)
	part === nothing && return nothing
	return attr(type = "data", array = part, visible = true)
end

# Error magnitudes must be non-negative numbers, as in matplotlib (`NaN`,
# `missing` or `nothing` leave a point without an error bar); plotly silently
# draws nothing for other values and flips negative ones.
function _stats_check_error_values(errors, who::AbstractString, name::AbstractString)
	series_list = _is_nested_series(errors) ? errors : (errors,)
	for series in series_list, value in series
		(value === nothing || value === missing ||
			(value isa Real && !(value isa Bool) && !(value < 0))) || throw(ArgumentError(
			"$(who): `$(name)` entries must be non-negative numbers; got $(repr(value)).",
		))
	end
	return nothing
end

# Bar labels are plain SVG text (plotly never typesets them), so strings go
# through `_label_plain`; numbers are kept and formatted by plotly; `nothing`
# and `missing` leave a bar unlabelled.
function _stats_bar_text_entry(entry, who::AbstractString)
	entry isa AbstractString && return _label_plain(entry)
	(entry === nothing || entry === missing) && return ""
	(entry isa Real && !(entry isa Bool)) && return entry
	throw(ArgumentError("$(who): `text` entries must be strings or numbers; got $(repr(entry))."))
end

function _stats_bar_text(
	text,
	index::Int,
	point_count::Int,
	who::AbstractString,
)
	text === nothing && return nothing
	text isa AbstractString && return _label_plain(text)
	text isa AbstractVector || throw(ArgumentError(
		"$(who): `text` must be a string, a vector with one label per bar, or a vector " *
		"of such vectors (one per series); got $(typeof(text)).",
	))
	part = _stats_point_part(text, index, point_count, who, "text")
	part === nothing && return nothing
	return Any[_stats_bar_text_entry(entry, who) for entry in part]
end

function _stats_bar_base_entry(entry, who::AbstractString)
	entry isa AbstractString && return String(entry)
	(entry isa Real && !(entry isa Bool) && isfinite(entry)) && return entry
	throw(ArgumentError(
		"$(who): `base` entries must be finite numbers (or date strings); got $(repr(entry)).",
	))
end

function _stats_bar_base(
	base,
	index::Int,
	point_count::Int,
	who::AbstractString,
)
	base === nothing && return nothing
	base isa AbstractVector || return _stats_bar_base_entry(base, who)
	part = _stats_point_part(base, index, point_count, who, "base")
	part === nothing && return nothing
	return Any[_stats_bar_base_entry(entry, who) for entry in part]
end

# Explicit histogram bins `(start, stop, width)` in data units.
function _stats_bins(bins, who::AbstractString)
	bins === nothing && return nothing
	((bins isa Tuple || bins isa AbstractVector) && length(bins) == 3) ||
		throw(ArgumentError(
			"$(who): `bins` must be a (start, stop, width) tuple; got $(repr(bins)).",
		))
	values = Float64[]
	for (entry, name) in zip(bins, ("start", "stop", "width"))
		(entry isa Real && !(entry isa Bool) && isfinite(entry)) || throw(ArgumentError(
			"$(who): `bins` $(name) must be a finite number; got $(repr(entry)).",
		))
		push!(values, Float64(entry))
	end
	values[1] < values[2] || throw(ArgumentError(
		"$(who): `bins` start must be less than stop; got $(repr(bins)).",
	))
	values[3] > 0 || throw(ArgumentError(
		"$(who): `bins` width must be positive; got $(repr(bins)).",
	))
	return (values[1], values[2], values[3])
end

function _stats_bins_attr(bins)
	return attr(Dict{Symbol, Any}(
		:start => bins[1],
		Symbol("end") => bins[2],
		:size => bins[3],
	))
end

# Deterministic id shared by the traces of one multi-series histogram call: it
# becomes their `bingroup` (common bins) and, for overlays, their `offsetgroup`
# (same bar slot, so they overlay inside their own subplot even under the
# figure-wide default barmode "group"). It hashes every sample and the bin
# options, so separate calls (and other subplot cells) get separate groups
# while the same call always produces the same JSON.
function _stats_histogram_group_id(series_list, options)
	digest = hash(options, hash("PlotlySupply.plot_histogram"))
	for series in series_list
		digest = hash(length(series), digest)
		for value in series
			digest = hash(value, digest)
		end
	end
	return "plotlysupply-histogram-" * string(digest; base = 16)
end

# Validate the points / jitter / pointpos keywords shared by box and violin.
function _stats_points(points, who::AbstractString)
	points isa Bool && return points
	(points isa AbstractString && points in _STATS_POINT_MODES) || throw(ArgumentError(
		"$(who): `points` must be true, false, $(join(repr.(_STATS_POINT_MODES), ", ")); " *
		"got $(repr(points)).",
	))
	return String(points)
end

# Box / violin positions collide when traces without explicit positions share
# a name: plotly then draws them on one category, and only group mode places
# them side by side. Distinctly named series each own a category, where group
# mode would narrow and offset them. Existing position-less traces of the same
# type and orientation in the target figure (for a SubplotFigure: on the
# target cell's axes) count as well.
function _stats_positions_collide(
	fig,
	names::Vector{String},
	trace_type::String,
	horizontal::Bool,
)
	any(name -> isempty(strip(name)), names) && return true
	allunique(names) || return true
	position_key = horizontal ? :y : :x
	value_key = horizontal ? :x : :y
	cell = _STATS_SUBPLOT_CELL[]
	existing_traces = cell === nothing ?
		Any[trace.fields for trace in _plot_data(fig)] : cell.traces
	for fields in existing_traces
		get(fields, :type, nothing) == trace_type || continue
		haskey(fields, position_key) && continue
		haskey(fields, value_key) || continue
		existing = get(fields, :name, "")
		existing isa AbstractString && existing in names && return true
	end
	return false
end

# ── Figure options shared by the family ──────────────────────────────────────

# Validate every common Cartesian keyword before the first write, including
# tick values against the axis type the call ends with and titles/labels
# (mathtext rejects malformed `$…$`), so a rejected keyword leaves the figure
# untouched.
function _stats_validate_options(fig, who::AbstractString, options)
	_validate_cartesian_options(
		fig,
		who;
		xrange = options.xrange,
		yrange = options.yrange,
		xscale = options.xscale,
		yscale = options.yscale,
		width = options.width,
		height = options.height,
		fontsize = options.fontsize,
		grid = options.grid,
	)
	_stats_validate_ticks(fig, :x, options.xticks, options.xticklabels, options.xscale, who)
	_stats_validate_ticks(fig, :y, options.yticks, options.yticklabels, options.yscale, who)
	_stats_label(options.title)
	_stats_label(options.xlabel)
	_stats_label(options.ylabel)
	return nothing
end

function _stats_validate_ticks(
	fig,
	letter::Symbol,
	values,
	labels,
	scale::AbstractString,
	who::AbstractString,
)
	name = String(letter)
	if values === nothing
		labels === nothing || throw(ArgumentError(
			"$(who): `$(name)ticklabels` need `$(name)ticks` (one label per tick value).",
		))
		return nothing
	end
	key = letter === :x ? :xaxis : :yaxis
	final_type = isempty(scale) ? _axis_type(_plot_layout(fig), key) : String(scale)
	tick_values = _cmn_tick_values(values, final_type == "log", who)
	labels === nothing || _cmn_tick_labels(labels, length(tick_values), who)
	return nothing
end

function _stats_apply_ticks!(
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

# Apply the validated common keywords through the D7 primitives. Constructors
# keep the template grid for their default `grid = true`; mutators default to
# `nothing` (unchanged) and apply every explicit value, so `grid = true`
# re-enables a grid that was switched off earlier.
function _stats_apply_options!(fig, who::AbstractString, options; mutator::Bool)
	_apply_figure_title!(fig, options.title)
	_apply_axis_title!(fig, :x, options.xlabel)
	_apply_axis_title!(fig, :y, options.ylabel)
	# Scale before range and ticks: a logarithmic axis stores its range as
	# exponents and takes tick values in data units.
	_apply_axis_scale!(fig, :x, options.xscale, who)
	_apply_axis_scale!(fig, :y, options.yscale, who)
	_apply_axis_range!(fig, :x, options.xrange, who)
	_apply_axis_range!(fig, :y, options.yrange, who)
	_stats_apply_ticks!(fig, :xaxis, options.xticks, options.xticklabels, options.xtickformat, who)
	_stats_apply_ticks!(fig, :yaxis, options.yticks, options.yticklabels, options.ytickformat, who)
	_apply_figure_size!(fig, who; width = options.width, height = options.height)
	(mutator || options.grid !== true) && _apply_axis_grid!(fig, options.grid, who)
	# A new figure gets the default template; an append only refreshes the
	# legend so a user-set template survives.
	if mutator
		_apply_default_legend!(fig)
	else
		_apply_default_template!(fig)
	end
	_apply_figure_fontsize!(fig, who, options.fontsize)
	mutator && _refresh!(fig)
	return nothing
end

# Mutators take the constructor keywords minus `show`; `kwargs...` only exists
# to turn `show` (and any other unknown keyword) into a clear error.
function _stats_reject_keywords(who::AbstractString, kwargs)
	isempty(kwargs) && return nothing
	names = collect(keys(kwargs))
	:show in names && throw(ArgumentError(
		"$(who): mutators do not take `show`; display the figure with `display(fig)` " *
		"or pass `show = true` to the constructor.",
	))
	throw(ArgumentError(
		"$(who): unsupported keyword argument(s) $(join(repr.(names), ", ")); see " *
		"the docstring for the accepted keywords.",
	))
end

function _stats_maybe_show(fig, show::Bool, width::Real, height::Real, title::AbstractString)
	show || return fig
	return _maybe_show(
		fig,
		true,
		width isa Integer ? Int(width) : round(Int, width),
		height isa Integer ? Int(height) : round(Int, height),
		String(title),
	)
end

# ── SubplotFigure delegation ────────────────────────────────────────────────

_stats_trace_on(fields, xref::AbstractString, yref::AbstractString) =
	get(fields, :xaxis, "x") == xref && get(fields, :yaxis, "y") == yref

# Run a stats mutator on a SubplotFigure cell with `_STATS_SUBPLOT_CELL` set to
# the cell's context. The (reentrant) metadata lock is held from the lookup to
# the commit so another task cannot change the cell in between. An explicit
# `barmode` that changes the layout of bars on other axes (plotly's bar mode is
# one figure-wide setting) is reported with a warning after the call succeeds.
function _stats_subplot_delegate!(
	sf::SubplotFigure,
	mutator,
	args...;
	row,
	col,
	secondary_y::Bool,
	who::AbstractString,
	kwargs...,
)
	return lock(getfield(sf, :_lock)) do
		root = _plot_obj(getfield(sf, :fig))
		target = _cell_target(sf; row = row, col = col, secondary_y = secondary_y, who = who)
		cell_traces = Any[]
		others_barlike = false
		for trace in root.data
			fields = trace.fields
			if target.kind === :xy && _stats_trace_on(fields, target.xref, target.yref)
				push!(cell_traces, fields)
			else
				others_barlike |= get(fields, :type, nothing) in _STATS_BARMODE_TRACE_TYPES
			end
		end
		root_barmode = get(root.layout.fields, :barmode, nothing)
		context = _StatsCellContext(root_barmode, cell_traces)
		result = Base.ScopedValues.with(_STATS_SUBPLOT_CELL => context) do
			_subplot_delegate_mutator!(
				sf,
				mutator,
				args...;
				row = row,
				col = col,
				secondary_y = secondary_y,
				kwargs...,
			)
		end
		requested = get(values(kwargs), :barmode, "")
		current = root_barmode === nothing ? "group" : root_barmode
		if others_barlike && requested isa AbstractString && !isempty(requested) &&
			requested != current
			@warn "$(who): `barmode = $(repr(requested))` replaces the figure-wide " *
				"bar mode $(repr(current)); plotly has one `layout.barmode` for every " *
				"subplot, so the existing bars and histograms on the other axes change too."
		end
		return result
	end
end

# ── Trace builders ──────────────────────────────────────────────────────────

function _bar_trace(;
	x,
	y,
	color::AbstractString = "",
	name::AbstractString = "",
	orientation::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	text = nothing,
	textposition::AbstractString = "",
	texttemplate::AbstractString = "",
	base = nothing,
	opacity::Union{Nothing, Real} = nothing,
	pattern = nothing,
	error_x = nothing,
	error_y = nothing,
)
	kw = Dict{Symbol, Any}(:x => x, :y => y, :name => String(name))
	marker = Dict{Symbol, Any}()
	isempty(color) || (marker[:color] = String(color))
	pattern === nothing || (marker[:pattern] = pattern)
	isempty(marker) || (kw[:marker] = attr(; marker...))
	isempty(orientation) || (kw[:orientation] = String(orientation))
	showlegend === nothing || (kw[:showlegend] = showlegend)
	text === nothing || (kw[:text] = text)
	isempty(textposition) || (kw[:textposition] = String(textposition))
	isempty(texttemplate) || (kw[:texttemplate] = String(texttemplate))
	base === nothing || (kw[:base] = base)
	opacity === nothing || (kw[:opacity] = opacity)
	error_x === nothing || (kw[:error_x] = error_x)
	error_y === nothing || (kw[:error_y] = error_y)
	return bar(; kw...)
end

# One histogram trace. `orientation = "h"` bins `samples` along y (the bars
# grow along x); otherwise along x.
function _histogram_trace(;
	samples,
	orientation::AbstractString = "",
	nbins::Int = 0,
	bins = nothing,
	histnorm::AbstractString = "",
	cumulative::Bool = false,
	color::AbstractString = "",
	name::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	opacity::Union{Nothing, Real} = nothing,
	pattern = nothing,
	bingroup::AbstractString = "",
	offsetgroup::AbstractString = "",
)
	horizontal = orientation == "h"
	kw = Dict{Symbol, Any}(:name => String(name))
	kw[horizontal ? :y : :x] = samples
	isempty(orientation) || (kw[:orientation] = String(orientation))
	nbins > 0 && (kw[horizontal ? :nbinsy : :nbinsx] = nbins)
	bins === nothing || (kw[horizontal ? :ybins : :xbins] = _stats_bins_attr(bins))
	isempty(histnorm) || (kw[:histnorm] = String(histnorm))
	cumulative && (kw[:cumulative] = attr(enabled = true))
	marker = Dict{Symbol, Any}()
	isempty(color) || (marker[:color] = String(color))
	pattern === nothing || (marker[:pattern] = pattern)
	isempty(marker) || (kw[:marker] = attr(; marker...))
	showlegend === nothing || (kw[:showlegend] = showlegend)
	opacity === nothing || (kw[:opacity] = opacity)
	isempty(bingroup) || (kw[:bingroup] = String(bingroup))
	isempty(offsetgroup) || (kw[:offsetgroup] = String(offsetgroup))
	return histogram(; kw...)
end

# Histogram on a logarithmic binning axis, which plotly.js cannot bin (see
# `_stats_log_axis`): the series of one call are counted in Julia on shared
# bins and drawn as `bar` traces whose bars span their bins exactly (`offset`
# 0 and `width` = bin width, in data units). Automatic bins have equal width
# in decades (plotly's automatic bins over log10 of the pooled samples,
# `nbins` approximate); explicit `bins` are linear in data units and must start
# above 0. Non-positive samples cannot be shown on a log axis and are not
# counted. `histnorm` and `cumulative` follow plotly's histogram: densities
# divide by each bin's width in data units, the cumulative sum is taken after
# normalization, and under `cumulative` the density norms act as their
# non-density equivalents. With `grouped`, the series sit side by side inside
# each bin, each taking an equal share of the bin's width in decades.
function _stats_log_histogram_traces(
	sample_list,
	who::AbstractString;
	orientation::AbstractString,
	nbins::Int,
	bins,
	histnorm::AbstractString,
	cumulative::Bool,
	grouped::Bool,
	colors,
	names,
	showlegends,
	opacity,
	patterns,
)
	series_count = length(sample_list)
	positions = Vector{Vector{Float64}}(undef, series_count)
	total_length = 0
	for (index, samples) in enumerate(sample_list)
		numeric = _stats_numeric_samples(samples, who, "x")
		total_length += length(samples)
		positions[index] = bins === nothing ? Float64[log10(value) for value in numeric if value > 0] : numeric
	end
	if bins === nothing
		pooled = reduce(vcat, positions; init = Float64[])
		isempty(pooled) && throw(ArgumentError(
			"$(who): a histogram on a log axis needs at least one positive finite sample.",
		))
		start, stop, width = _stats_autobins(pooled, nbins; total = total_length)
		bin_count = round(Int, (stop - start) / width)
		edges = exp10.([start + k * width for k in 0:bin_count])
	else
		start, stop, width = bins
		start > 0 || throw(ArgumentError(
			"$(who): on a log axis `bins` (data units) must start above 0; got start = $(start).",
		))
		# plotly keeps every bin whose left edge lies below `stop`.
		bin_count = max(1, ceil(Int, (stop - start) / width - 1e-9))
		edges = [start + k * width for k in 0:bin_count]
	end
	bin_widths = diff(edges)
	norm = histnorm
	if cumulative
		norm == "density" && (norm = "")
		norm == "probability density" && (norm = "probability")
	end
	horizontal = orientation == "h"
	value_letter = horizontal ? "x" : "y"
	hovertemplate = "[%{customdata[0]:.4g}, %{customdata[1]:.4g}): " *
		"$(cumulative ? "cumulative " : "")$(_STATS_HISTNORM_LABELS[histnorm]) %{$(value_letter)}"
	customdata = [Any[edges[k], edges[k + 1]] for k in 1:bin_count]
	traces = Vector{GenericTrace}(undef, series_count)
	for index in 1:series_count
		counts = zeros(Float64, bin_count)
		binned = 0
		for position in positions[index]
			bin = _stats_bin_index(position, start, width, bin_count)
			bin == 0 && continue
			counts[bin] += 1
			binned += 1
		end
		if norm == "percent"
			binned > 0 && (counts .*= 100 / binned)
		elseif norm == "probability"
			binned > 0 && (counts ./= binned)
		elseif norm == "density"
			counts ./= bin_widths
		elseif norm == "probability density"
			counts ./= bin_widths
			binned > 0 && (counts ./= binned)
		end
		cumulative && cumsum!(counts, counts)
		if grouped
			low = log10.(edges[1:(end - 1)])
			share = (log10.(edges[2:end]) .- low) ./ series_count
			left = exp10.(low .+ (index - 1) .* share)
			right = exp10.(low .+ index .* share)
		else
			left = edges[1:(end - 1)]
			right = edges[2:end]
		end
		kw = Dict{Symbol, Any}(
			:name => String(names[index]),
			:offset => 0,
			:width => right .- left,
			:customdata => customdata,
			:hovertemplate => hovertemplate,
		)
		kw[horizontal ? :y : :x] = left
		kw[horizontal ? :x : :y] = counts
		horizontal && (kw[:orientation] = "h")
		marker = Dict{Symbol, Any}()
		isempty(colors[index]) || (marker[:color] = String(colors[index]))
		patterns[index] === nothing || (marker[:pattern] = patterns[index])
		isempty(marker) || (kw[:marker] = attr(; marker...))
		showlegends[index] === nothing || (kw[:showlegend] = showlegends[index])
		opacity === nothing || (kw[:opacity] = opacity)
		traces[index] = bar(; kw...)
	end
	return traces
end

# Plotly's box/violin point options are a string enum
# ("all"|"outliers"|"suspectedoutliers") or `false`. A bare `true` is invalid
# and silently ignored by Plotly, so map it to the sensible "all".
_normalize_points(points) = points isa Bool ? (points ? "all" : false) : points

# Shared box/violin fields: data, name, colour, orientation and point options.
function _stats_distribution_fields(;
	x,
	y,
	color::AbstractString,
	name::AbstractString,
	orientation::AbstractString,
	showlegend::Union{Nothing, Bool},
	jitter::Union{Nothing, Real},
	pointpos::Union{Nothing, Real},
)
	kw = Dict{Symbol, Any}(:name => String(name))
	x === nothing || (kw[:x] = x)
	y === nothing || (kw[:y] = y)
	if !isempty(color)
		kw[:marker] = attr(color = String(color))
		kw[:line] = attr(color = String(color))
	end
	isempty(orientation) || (kw[:orientation] = String(orientation))
	showlegend === nothing || (kw[:showlegend] = showlegend)
	jitter === nothing || (kw[:jitter] = jitter)
	pointpos === nothing || (kw[:pointpos] = pointpos)
	return kw
end

function _box_trace(;
	x = nothing,
	y = nothing,
	color::AbstractString = "",
	name::AbstractString = "",
	points::Union{Bool, AbstractString} = "outliers",
	orientation::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	boxmean::Union{Bool, AbstractString} = false,
	notched::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
)
	kw = _stats_distribution_fields(;
		x = x,
		y = y,
		color = color,
		name = name,
		orientation = orientation,
		showlegend = showlegend,
		jitter = jitter,
		pointpos = pointpos,
	)
	kw[:boxpoints] = _normalize_points(points)
	boxmean === false || (kw[:boxmean] = boxmean isa Bool ? true : String(boxmean))
	notched && (kw[:notched] = true)
	return PlotlyBase.box(; kw...)
end

function _violin_trace(;
	x = nothing,
	y = nothing,
	color::AbstractString = "",
	name::AbstractString = "",
	points::Union{Bool, AbstractString} = "outliers",
	side::AbstractString = "both",
	orientation::AbstractString = "",
	showlegend::Union{Nothing, Bool} = nothing,
	box::Bool = false,
	meanline::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
)
	kw = _stats_distribution_fields(;
		x = x,
		y = y,
		color = color,
		name = name,
		orientation = orientation,
		showlegend = showlegend,
		jitter = jitter,
		pointpos = pointpos,
	)
	kw[:points] = _normalize_points(points)
	kw[:side] = String(side)
	box && (kw[:box] = attr(visible = true))
	meanline && (kw[:meanline] = attr(visible = true))
	return violin(; kw...)
end

# ── Family implementations (shared by constructor and mutator) ───────────────

function _stats_bar!(fig, x, y, who::AbstractString, options, bar_options; mutator::Bool)
	o = bar_options
	orientation = _stats_orientation(o.orientation, who)
	horizontal = orientation == "h"
	barmode = _stats_choice(o.barmode, _STATS_BARMODES, who, "barmode")
	textposition = _stats_choice(o.textposition, _STATS_TEXTPOSITIONS, who, "textposition")
	opacity = _stats_number(o.opacity, who, "opacity", 0, 1)
	if x === nothing
		# y-only form: generated positions 0:n-1 go on the category axis, the
		# values on the value axis (x for horizontal bars).
		value_name, position_name = "y", "x"
		values, positions = y, _auto_xvalues(y)
	else
		# Two-argument form: plotly's convention, `x` and `y` are passed
		# through as given; for horizontal bars `x` holds the values.
		value_name, position_name = horizontal ? ("x", "y") : ("y", "x")
		values, positions = horizontal ? (x, y) : (y, x)
	end
	value_list, position_list, _ =
		_stats_series_lists(values, positions, who, value_name, position_name)
	count = length(value_list)
	colors = _stats_colors(o.color, count, who)
	names = _stats_names(o.legend, count)
	showlegends = _stats_showlegends(o.showlegend, count)
	patterns = _stats_patterns(o.hatch, count, who)
	traces = Vector{GenericTrace}(undef, count)
	for index in 1:count
		series = value_list[index]
		series_positions = position_list[index]
		points = length(series)
		trace_x, trace_y = horizontal ? (series, series_positions) : (series_positions, series)
		traces[index] = _bar_trace(;
			x = trace_x,
			y = trace_y,
			color = colors[index],
			name = names[index],
			orientation = orientation,
			showlegend = showlegends[index],
			text = _stats_bar_text(o.text, index, points, who),
			textposition = textposition,
			texttemplate = o.texttemplate,
			base = _stats_bar_base(o.base, index, points, who),
			opacity = opacity,
			pattern = patterns[index],
			error_x = _stats_error_bars(o.error_x, index, points, who, "error_x"),
			error_y = _stats_error_bars(o.error_y, index, points, who, "error_y"),
		)
	end
	_stats_validate_options(fig, who, options)

	append!(_plot_data(fig), traces)
	_apply_explicit_layout_mode!(fig, :barmode, barmode)
	_stats_apply_options!(fig, who, options; mutator = mutator)
	return nothing
end

function _stats_histogram!(fig, x, who::AbstractString, options, histogram_options; mutator::Bool)
	o = histogram_options
	orientation = _stats_orientation(o.orientation, who)
	histnorm = _stats_choice(o.histnorm, _STATS_HISTNORMS, who, "histnorm")
	barmode = _stats_choice(o.barmode, _STATS_BARMODES, who, "barmode")
	nbins = _stats_count(o.nbinsx, who, "nbinsx")
	bins = _stats_bins(o.bins, who)
	(bins !== nothing && nbins > 0) && throw(ArgumentError(
		"$(who): pass either `nbinsx` (an approximate bin count) or `bins` (explicit " *
		"(start, stop, width) bins), not both.",
	))
	opacity = _stats_number(o.opacity, who, "opacity", 0, 1)
	sample_list, _, nested = _stats_series_lists(x, nothing, who, "x", "")
	count = length(sample_list)
	colors = _stats_colors(o.color, count, who)
	names = _stats_names(o.legend, count)
	showlegends = _stats_showlegends(o.showlegend, count)
	patterns = _stats_patterns(o.hatch, count, who)

	# Several series from one call share their bins. They overlay unless a bar
	# mode other than "overlay" is requested or already set on the target, in
	# which case plotly groups or stacks them on the shared bins.
	shared = nested && count > 1
	existing_mode = get(_plot_layout(fig).fields, :barmode, nothing)
	cell = _STATS_SUBPLOT_CELL[]
	(existing_mode === nothing && cell !== nothing) && (existing_mode = cell.barmode)
	mode = isempty(barmode) ? existing_mode : barmode
	overlay = shared && (mode === nothing || mode == "overlay")
	group_id = shared ?
		_stats_histogram_group_id(
			sample_list,
			(orientation, nbins, bins, histnorm, o.cumulative),
		) : ""
	trace_opacity = opacity !== nothing ? opacity :
		overlay ? _STATS_OVERLAY_OPACITY : nothing
	horizontal = orientation == "h"
	log_axis = _stats_log_axis(
		fig,
		horizontal ? options.yscale : options.xscale,
		horizontal ? :yaxis : :xaxis,
	)
	if log_axis
		traces = _stats_log_histogram_traces(
			sample_list,
			who;
			orientation = orientation,
			nbins = nbins,
			bins = bins,
			histnorm = histnorm,
			cumulative = o.cumulative,
			grouped = shared && mode == "group",
			colors = colors,
			names = names,
			showlegends = showlegends,
			opacity = trace_opacity,
			patterns = patterns,
		)
	else
		traces = Vector{GenericTrace}(undef, count)
		for index in 1:count
			traces[index] = _histogram_trace(;
				samples = sample_list[index],
				orientation = orientation,
				nbins = nbins,
				bins = bins,
				histnorm = histnorm,
				cumulative = o.cumulative,
				color = colors[index],
				name = names[index],
				showlegend = showlegends[index],
				opacity = trace_opacity,
				pattern = patterns[index],
				bingroup = group_id,
				offsetgroup = overlay ? group_id : "",
			)
		end
	end
	_stats_validate_options(fig, who, options)

	append!(_plot_data(fig), traces)
	if !isempty(barmode)
		_apply_explicit_layout_mode!(fig, :barmode, barmode)
	elseif overlay
		_apply_nested_layout_mode!(fig, x, :barmode, "overlay")
	end
	_stats_apply_options!(fig, who, options; mutator = mutator)
	return nothing
end

function _stats_distribution!(
	fig,
	x,
	y,
	who::AbstractString,
	options,
	distribution_options;
	kind::Symbol,
	mutator::Bool,
)
	o = distribution_options
	orientation = _stats_orientation(o.orientation, who)
	horizontal = orientation == "h"
	points = _stats_points(o.points, who)
	jitter = _stats_number(o.jitter, who, "jitter", 0, 1)
	pointpos = _stats_number(o.pointpos, who, "pointpos", -2, 2)
	if kind === :box
		boxmean = o.boxmean
		(boxmean isa Bool || boxmean == "sd") || throw(ArgumentError(
			"$(who): `boxmean` must be true, false or \"sd\"; got $(repr(boxmean)).",
		))
	else
		_stats_choice(o.side, _STATS_VIOLIN_SIDES, who, "side")
	end
	if x === nothing
		# y-only form: one distribution per series, positioned by its name;
		# horizontal distributions put the samples on x.
		value_name, position_name = "y", ""
		values, positions = y, nothing
	else
		value_name, position_name = horizontal ? ("x", "y") : ("y", "x")
		values, positions = horizontal ? (x, y) : (y, x)
	end
	value_list, position_list, nested =
		_stats_series_lists(values, positions, who, value_name, position_name)
	count = length(value_list)
	colors = _stats_colors(o.color, count, who)
	names = _stats_names(o.legend, count)
	showlegends = _stats_showlegends(o.showlegend, count)
	traces = Vector{GenericTrace}(undef, count)
	for index in 1:count
		series = value_list[index]
		series_positions = position_list[index]
		trace_x, trace_y = horizontal ? (series, series_positions) : (series_positions, series)
		traces[index] = if kind === :box
			_box_trace(;
				x = trace_x,
				y = trace_y,
				color = colors[index],
				name = names[index],
				points = points,
				orientation = orientation,
				showlegend = showlegends[index],
				boxmean = o.boxmean,
				notched = o.notched,
				jitter = jitter,
				pointpos = pointpos,
			)
		else
			_violin_trace(;
				x = trace_x,
				y = trace_y,
				color = colors[index],
				name = names[index],
				points = points,
				side = o.side,
				orientation = orientation,
				showlegend = showlegends[index],
				box = o.box,
				meanline = o.meanline,
				jitter = jitter,
				pointpos = pointpos,
			)
		end
	end
	# Several series side by side need group mode when they share positions:
	# always with explicit positions, and in the y-only form when names collide.
	mode_key = kind === :box ? :boxmode : :violinmode
	group = nested && count > 1 && (
		positions !== nothing ||
		_stats_positions_collide(fig, names, String(kind), horizontal)
	)
	_stats_validate_options(fig, who, options)

	append!(_plot_data(fig), traces)
	group && _apply_nested_layout_mode!(fig, values, mode_key, "group")
	_stats_apply_options!(fig, who, options; mutator = mutator)
	return nothing
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		trace = Vector{GenericTrace}(undef, length(y))
		series_count = length(y)
		modeV = _series_kwarg_vector(
			mode,
			series_count,
			"lines",
			String,
		)
		dashV = _series_kwarg_vector(
			dash,
			series_count,
			"",
			String,
		)
		colorV = _series_kwarg_vector(
			color,
			series_count,
			"",
			String,
		)
		legendV = _series_kwarg_vector(
			legend,
			series_count,
			"",
			String,
		)
		marker_sizeV = _series_kwarg_vector(
			marker_size,
			series_count,
			0,
			Int,
		)
		marker_symbolV = _series_kwarg_vector(
			marker_symbol,
			series_count,
			"",
			String,
		)
		linewidthV = _series_kwarg_vector(
			linewidth,
			series_count,
			0.0,
			Float64,
		)
		showlegendV = _series_kwarg_vector(
			showlegend,
			series_count,
			nothing,
			Union{Nothing,Bool},
		)

		if x_nested
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
	x = _auto_xvalues(y)
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		trace = Vector{GenericTrace}(undef, length(y))
		series_count = length(y)
		colorV = _series_kwarg_vector(
			color,
			series_count,
			"",
			String,
		)
		legendV = _series_kwarg_vector(
			legend,
			series_count,
			"",
			String,
		)
		showlegendV = _series_kwarg_vector(
			showlegend,
			series_count,
			nothing,
			Union{Nothing,Bool},
		)

		if x_nested
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
	if y_nested
		if x_nested
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
	x = _auto_xvalues(y)
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

Bar chart. Returns a `PlotlyBase.Plot`, or a [`SyncPlot`](@ref) window when
`show = true`.

#### Data
- `plot_bar(x, y)`: plotly's convention, passed through as given. For vertical
  bars (default) `x` holds the categories or positions and `y` the bar values.
  For `orientation = "h"` the roles swap: `x` holds the values (bar lengths)
  and `y` the categories, e.g. `plot_bar([3, 5, 2], ["a", "b", "c"];
  orientation = "h")`.
- `plot_bar(y)`: the values `y` at generated positions `0:length(y)-1`, which
  go on the category axis (the y axis for `orientation = "h"`).
- Multiple series: pass a vector of vectors for the values (and optionally one
  position vector per series); a vector whose elements are all vectors (also
  `Vector{Any}`) is multi-series. Every series must have as many values as
  its positions. Bars of several series are grouped (plotly's default
  `barmode`).
- `AbstractVector` data: vectors, ranges, views. Complex values are an
  `ArgumentError`.

#### Keyword Arguments
- `color::Union{AbstractString,Symbol,AbstractVector} = ""`: bar colour, or one
  colour per series (`""` uses the colour cycle).
- `legend::Union{AbstractString,AbstractVector{<:AbstractString}} = ""`: trace
  name(s) shown in the legend (mathtext labels allowed).
- `showlegend::Union{Nothing,Bool,AbstractVector{Bool}} = nothing`: force the
  legend entry on/off, per series when a vector.
- `orientation::AbstractString = ""`: `"v"`/`""` vertical, `"h"` horizontal.
- `barmode::AbstractString = ""`: layout bar mode `"group"`, `"stack"`,
  `"overlay"` or `"relative"`; `""` leaves it unchanged (plotly: `"group"`).
- `error_x`, `error_y = nothing`: error bars, a vector of non-negative
  magnitudes (one per bar, shared by every series), a vector of such vectors
  (one per series) or a `(minus, plus)` tuple of either form for asymmetric
  bars. For horizontal bars the value errors are `error_x`. `NaN`/`missing`
  leaves a bar without an error bar.
- `text = nothing`: bar labels, a string for every bar, a vector with one
  label (string or number) per bar, or a vector of such vectors (one per
  series). Strings are drawn as plain text (plotly never typesets bar text:
  `\$…\$` math becomes Unicode/HTML, no MathJax); `nothing`/`missing` entries
  leave a bar unlabelled.
- `textposition::AbstractString = ""`: `"inside"`, `"outside"`, `"auto"` or
  `"none"` (`""` is plotly's `"auto"`).
- `texttemplate::AbstractString = ""`: plotly text template, e.g.
  `"%{y:.1f}"`, passed through verbatim.
- `base = nothing`: where bars start on the value axis, a number or one number
  per bar (per series as a vector of vectors).
- Per-point keywords given as a vector of vectors (`error_x`, `error_y`,
  `text`, `base`) follow the per-series rule of the other keywords: series
  without an entry get none, surplus entries are ignored; each entry must have
  one value per bar of its series.
- `opacity::Union{Nothing,Real} = nothing`: trace opacity in [0, 1].
- `hatch::Union{AbstractString,AbstractVector{<:AbstractString}} = ""`:
  matplotlib hatch (`"/"`, `"\\\\"`, `"x"`, `"-"`, `"|"`, `"+"`, `"."`,
  repeated for density, e.g. `"//"`), per series when a vector.
- `xlabel`, `ylabel`, `title::AbstractString = ""`: axis titles and figure
  title (mathtext labels allowed).
- `xrange`, `yrange = [0, 0]`: axis range `[min, max]` or `(min, max)` in data
  units (also on log axes); `[0, 0]` or `nothing` autoscales.
- `xscale`, `yscale::AbstractString = ""`: axis type, e.g. `"log"` (log axes
  get power-of-ten tick labels).
- `xticks`, `yticks = nothing`: tick positions (data units); `xticklabels`,
  `yticklabels = nothing`: one label per tick; `xtickformat`,
  `ytickformat::AbstractString = ""`: d3 tick format, e.g. `".2f"`.
- `width`, `height::Real = 0`: figure size in pixels (`0` = automatic).
- `fontsize::Real = 0`: base font size in pixels (`0` = template default).
- `grid::Union{Nothing,Bool,Symbol} = true`: `true` keeps the template grid;
  `false`, `:none`, `:x`, `:y`, `:both` select the grid lines.
- `show::Bool = false`: open the figure in an Electron window.

#### Example
```julia
fig = plot_bar(["Q1", "Q2", "Q3"], [[10, 12, 9], [11, 14, 11]];
	legend = ["2023", "2024"], error_y = [[1, 1, 2], [2, 1, 1]], text = [[10, 12, 9], [11, 14, 11]])
plot_bar([3, 5, 2], ["a", "b", "c"]; orientation = "h", hatch = "//")
```
"""
function plot_bar(
	x::AbstractVector,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	orientation::AbstractString = "",
	barmode::AbstractString = "",
	error_x = nothing,
	error_y = nothing,
	text = nothing,
	textposition::AbstractString = "",
	texttemplate::AbstractString = "",
	base = nothing,
	opacity::Union{Nothing, Real} = nothing,
	hatch::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stats_bar!(
		fig,
		x,
		y,
		"plot_bar",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, orientation, barmode, error_x, error_y, text,
			textposition, texttemplate, base, opacity, hatch);
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

function plot_bar(
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	orientation::AbstractString = "",
	barmode::AbstractString = "",
	error_x = nothing,
	error_y = nothing,
	text = nothing,
	textposition::AbstractString = "",
	texttemplate::AbstractString = "",
	base = nothing,
	opacity::Union{Nothing, Real} = nothing,
	hatch::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stats_bar!(
		fig,
		nothing,
		y,
		"plot_bar",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, orientation, barmode, error_x, error_y, text,
			textposition, texttemplate, base, opacity, hatch);
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

"""
	plot_histogram(x; kwargs...)

Histogram of the samples `x`. Returns a `PlotlyBase.Plot`, or a
[`SyncPlot`](@ref) window when `show = true`.

#### Data
- `x::AbstractVector`: the samples (vector, range or view; complex values are
  an `ArgumentError`). With `orientation = "h"` the samples are binned along
  the y axis and the bars grow along x.
- Multiple series: a vector of vectors (also `Vector{Any}`). The series of one
  call share their bins (`bingroup`). They are overlaid: each trace gets
  opacity 0.6 (unless `opacity` is given) and one shared `offsetgroup`, and the
  layout `barmode` becomes `"overlay"` unless the figure already has a bar
  mode. With `barmode = "stack"`/`"group"`/`"relative"` (passed or already set
  on the figure) they are stacked or grouped on the shared bins instead.
- Log binning axis (`xscale = "log"`, `yscale = "log"` with
  `orientation = "h"`, or a mutator target whose binning axis is already
  logarithmic): plotly.js cannot bin there (it draws nothing), so the samples
  are counted in Julia (numeric data only) and drawn as `bar` traces spanning
  the bins. Automatic bins have equal width in decades (chosen like plotly's
  automatic bins, over log10 of the data, shared by the series of one call);
  explicit `bins` are in data units and must start above 0. Non-positive
  samples, which a log axis cannot show, are dropped. `histnorm` and
  `cumulative` behave as in plotly (densities divide by each bin's width in
  data units); in group mode the series of one call share each bin side by
  side.

#### Keyword Arguments
- `nbinsx::Integer = 0`: approximate number of bins (`0` = automatic). It is
  neither exact nor a strict maximum: plotly rounds the bin width (data range
  / `nbinsx`) to a "nice" value and aligns the edges to round numbers, so the
  drawn count differs (measured with plotly.js 2.35: 31 bins for
  `nbinsx = 30` on `randn(500)`, 20 on `rand(500)`). Use `bins` for exact
  bins. With `orientation = "h"` it applies to the bins along y.
- `bins = nothing`: explicit bins `(start, stop, width)` in data units, e.g.
  `(0, 10, 0.5)`; mutually exclusive with `nbinsx`.
- `histnorm::AbstractString = ""`: `""` (counts), `"percent"`,
  `"probability"`, `"density"` or `"probability density"`.
- `cumulative::Bool = false`: cumulative histogram.
- `orientation::AbstractString = ""`: `"v"`/`""` vertical, `"h"` horizontal.
- `barmode::AbstractString = ""`: layout bar mode (see above); `""` keeps the
  automatic choice.
- `opacity::Union{Nothing,Real} = nothing`: trace opacity in [0, 1].
- `hatch::Union{AbstractString,AbstractVector{<:AbstractString}} = ""`:
  matplotlib hatch per series (see [`plot_bar`](@ref)).
- `color::Union{AbstractString,Symbol,AbstractVector} = ""`, `legend = ""`,
  `showlegend = nothing`: per-series colour, name and legend visibility as in
  [`plot_bar`](@ref).
- `xlabel`, `ylabel`, `title`, `xrange`, `yrange`, `xscale`, `yscale`,
  `xticks`, `xticklabels`, `xtickformat`, `yticks`, `yticklabels`,
  `ytickformat`, `width`, `height`, `fontsize`, `grid = true`, `show = false`:
  as in [`plot_bar`](@ref).

#### Example
```julia
a, b = randn(500), randn(500) .+ 1
fig = plot_histogram([a, b]; bins = (-4, 5, 0.25), legend = ["a", "b"])
plot_histogram([a, b]; barmode = "stack", nbinsx = 30, hatch = ["", "//"])
plot_histogram(a; cumulative = true, histnorm = "probability")
```
"""
function plot_histogram(
	x::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	nbinsx::Integer = 0,
	bins = nothing,
	histnorm::AbstractString = "",
	cumulative::Bool = false,
	orientation::AbstractString = "",
	barmode::AbstractString = "",
	opacity::Union{Nothing, Real} = nothing,
	hatch::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stats_histogram!(
		fig,
		x,
		"plot_histogram",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, nbinsx, bins, histnorm, cumulative,
			orientation, barmode, opacity, hatch);
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

"""
	plot_box(x, y; kwargs...)
	plot_box(y; kwargs...)

Box plot. Returns a `PlotlyBase.Plot`, or a [`SyncPlot`](@ref) window when
`show = true`.

#### Data
- `plot_box(y)`: one box of the samples `y`, placed at its `legend` name. A
  vector of vectors (also `Vector{Any}`) draws one box per series; distinctly
  named series each sit centred on their own name, while unnamed or
  duplicate-named series are placed side by side (`boxmode = "group"`).
- `plot_box(x, y)`: plotly's convention, passed through. For vertical boxes
  `x` gives the group (category) of every sample in `y` (same length), so
  `plot_box(["a", "a", "b", "b"], [1.0, 2.0, 3.0, 4.0])` draws boxes "a" and
  "b". Several `y` series (vector of vectors, sharing `x` or with one `x` per
  series) are grouped side by side (`boxmode = "group"`). For
  `orientation = "h"` the roles swap: `x` holds the samples and `y` the groups.
- An existing `boxmode` on the figure is never overwritten.

#### Keyword Arguments
- `points::Union{Bool,AbstractString} = "outliers"`: sample points drawn next
  to the box: `"all"` (or `true`), `"outliers"`, `"suspectedoutliers"`, or
  `false`.
- `orientation::AbstractString = ""`: `"v"`/`""` vertical, `"h"` horizontal
  (the y-only form then puts the samples on x).
- `boxmean::Union{Bool,AbstractString} = false`: `true` draws the mean as a
  dashed line, `"sd"` also the standard deviation.
- `notched::Bool = false`: notched boxes (median confidence interval).
- `jitter::Union{Nothing,Real} = nothing`: horizontal spread of the drawn
  points in [0, 1].
- `pointpos::Union{Nothing,Real} = nothing`: offset of the points relative to
  the box in [-2, 2] (0 = centred on the box).
- `color::Union{AbstractString,Symbol,AbstractVector} = ""`, `legend = ""`,
  `showlegend = nothing`: per-series colour, name and legend visibility as in
  [`plot_bar`](@ref).
- `xlabel`, `ylabel`, `title`, `xrange`, `yrange`, `xscale`, `yscale`,
  `xticks`, `xticklabels`, `xtickformat`, `yticks`, `yticklabels`,
  `ytickformat`, `width`, `height`, `fontsize`, `grid = true`, `show = false`:
  as in [`plot_bar`](@ref).

#### Example
```julia
fig = plot_box([randn(100), randn(100) .+ 1]; legend = ["control", "drug"], boxmean = true)
plot_box(repeat(["a", "b"], 50), randn(100); points = "all", jitter = 0.3, pointpos = -1.8)
```
"""
function plot_box(
	x::AbstractVector,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	points::Union{Bool, AbstractString} = "outliers",
	orientation::AbstractString = "",
	boxmean::Union{Bool, AbstractString} = false,
	notched::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stats_distribution!(
		fig,
		x,
		y,
		"plot_box",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, points, orientation, boxmean, notched, jitter,
			pointpos);
		kind = :box,
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

function plot_box(
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	points::Union{Bool, AbstractString} = "outliers",
	orientation::AbstractString = "",
	boxmean::Union{Bool, AbstractString} = false,
	notched::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stats_distribution!(
		fig,
		nothing,
		y,
		"plot_box",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, points, orientation, boxmean, notched, jitter,
			pointpos);
		kind = :box,
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

"""
	plot_violin(x, y; kwargs...)
	plot_violin(y; kwargs...)

Violin plot (kernel density of the samples). Returns a `PlotlyBase.Plot`, or a
[`SyncPlot`](@ref) window when `show = true`.

#### Data
Same conventions as [`plot_box`](@ref): `plot_violin(y)` places each series at
its `legend` name (unnamed or duplicate-named series side by side with
`violinmode = "group"`); `plot_violin(x, y)` passes `x` (the group of every
sample) and `y` (the samples) through, swapped for `orientation = "h"`, and
groups several series side by side. An existing `violinmode` is never
overwritten.

#### Keyword Arguments
- `points::Union{Bool,AbstractString} = "outliers"`: `"all"` (or `true`),
  `"outliers"`, `"suspectedoutliers"` or `false`.
- `side::AbstractString = "both"`: `"both"`, `"positive"` or `"negative"`
  (half violins).
- `orientation::AbstractString = ""`: `"v"`/`""` vertical, `"h"` horizontal.
- `box::Bool = false`: draw a mini box plot inside the violin.
- `meanline::Bool = false`: draw the sample mean as a line.
- `jitter::Union{Nothing,Real} = nothing` in [0, 1] and
  `pointpos::Union{Nothing,Real} = nothing` in [-2, 2]: spread and offset of
  the drawn points.
- `color::Union{AbstractString,Symbol,AbstractVector} = ""`, `legend = ""`,
  `showlegend = nothing`: per-series colour, name and legend visibility as in
  [`plot_bar`](@ref).
- `xlabel`, `ylabel`, `title`, `xrange`, `yrange`, `xscale`, `yscale`,
  `xticks`, `xticklabels`, `xtickformat`, `yticks`, `yticklabels`,
  `ytickformat`, `width`, `height`, `fontsize`, `grid = true`, `show = false`:
  as in [`plot_bar`](@ref).

#### Example
```julia
fig = plot_violin([randn(200), randn(200) .+ 1]; legend = ["a", "b"], box = true, meanline = true)
plot_violin(randn(200); orientation = "h", side = "positive", points = false)
```
"""
function plot_violin(
	x::AbstractVector,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	points::Union{Bool, AbstractString} = "outliers",
	side::AbstractString = "both",
	orientation::AbstractString = "",
	box::Bool = false,
	meanline::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stats_distribution!(
		fig,
		x,
		y,
		"plot_violin",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, points, side, orientation, box, meanline,
			jitter, pointpos);
		kind = :violin,
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

function plot_violin(
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	points::Union{Bool, AbstractString} = "outliers",
	side::AbstractString = "both",
	orientation::AbstractString = "",
	box::Bool = false,
	meanline::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stats_distribution!(
		fig,
		nothing,
		y,
		"plot_violin",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, points, side, orientation, box, meanline,
			jitter, pointpos);
		kind = :violin,
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
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
	r_nested, theta_nested = _nested_coordinate_mode(r, theta, :r, :theta)
	if r_nested
		trace = Vector{GenericTrace}(undef, length(r))
		series_count = length(r)
		modeV = _series_kwarg_vector(
			mode,
			series_count,
			"lines",
			String,
		)
		dashV = _series_kwarg_vector(
			dash,
			series_count,
			"",
			String,
		)
		colorV = _series_kwarg_vector(
			color,
			series_count,
			"",
			String,
		)
		legendV = _series_kwarg_vector(
			legend,
			series_count,
			"",
			String,
		)
		marker_sizeV = _series_kwarg_vector(
			marker_size,
			series_count,
			0,
			Int,
		)
		marker_symbolV = _series_kwarg_vector(
			marker_symbol,
			series_count,
			"",
			String,
		)
		linewidthV = _series_kwarg_vector(
			linewidth,
			series_count,
			0.0,
			Float64,
		)
		showlegendV = _series_kwarg_vector(
			showlegend,
			series_count,
			nothing,
			Union{Nothing,Bool},
		)

		if theta_nested
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	_n0 = length(_plot_data(fig))
	if y_nested
		series_count = length(y)
		modeV = _series_kwarg_vector(
			mode,
			series_count,
			"lines",
			String,
		)
		dashV = _series_kwarg_vector(
			dash,
			series_count,
			"",
			String,
		)
		colorV = _series_kwarg_vector(
			color,
			series_count,
			"",
			String,
		)
		legendV = _series_kwarg_vector(
			legend,
			series_count,
			"",
			String,
		)
		marker_sizeV = _series_kwarg_vector(
			marker_size,
			series_count,
			0,
			Int,
		)
		marker_symbolV = _series_kwarg_vector(
			marker_symbol,
			series_count,
			"",
			String,
		)
		linewidthV = _series_kwarg_vector(
			linewidth,
			series_count,
			0.0,
			Float64,
		)
		showlegendV = _series_kwarg_vector(
			showlegend,
			series_count,
			nothing,
			Union{Nothing,Bool},
		)

		if x_nested
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
	x = _auto_xvalues(y)
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
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		series_count = length(y)
		colorV = _series_kwarg_vector(
			color,
			series_count,
			"",
			String,
		)
		legendV = _series_kwarg_vector(
			legend,
			series_count,
			"",
			String,
		)
		showlegendV = _series_kwarg_vector(
			showlegend,
			series_count,
			nothing,
			Union{Nothing,Bool},
		)

		if x_nested
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(
					:y => y[n],
					:x => x[n],
					:name => legendV[n],
					:mode => "markers",
				)
				colorV[n] != "" &&
					(trace_kw[:marker] =
						attr(color = colorV[n]))
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				push!(_plot_data(fig), scatter(; trace_kw...))
			end
			for n in eachindex(y)
				stem_color =
					colorV[n] == "" ? "black" : colorV[n]
				for m in eachindex(y[n])
					push!(_plot_data(fig),
						scatter(
							x = [x[n][m], x[n][m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(
								color = stem_color,
								width = 0.5,
							),
							showlegend = false,
						),
					)
				end
			end
		else
			for n in eachindex(y)
				trace_kw = Dict{Symbol,Any}(
					:y => y[n],
					:x => x,
					:name => legendV[n],
					:mode => "markers",
				)
				colorV[n] != "" &&
					(trace_kw[:marker] =
						attr(color = colorV[n]))
				showlegendV[n] !== nothing && (trace_kw[:showlegend] = showlegendV[n])
				push!(_plot_data(fig), scatter(; trace_kw...))
			end
			for n in eachindex(y)
				stem_color =
					colorV[n] == "" ? "black" : colorV[n]
				for m in eachindex(y[n])
					push!(_plot_data(fig),
						scatter(
							x = [x[m], x[m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(
								color = stem_color,
								width = 0.5,
							),
							showlegend = false,
						),
					)
				end
			end
		end
	else
		color1 = _first_or_empty(color)
		trace_kw = Dict{Symbol,Any}(
			:y => y,
			:x => x,
			:name => _first_or_empty(legend),
			:mode => "markers",
		)
		color1 != "" &&
			(trace_kw[:marker] = attr(color = color1))
		sl = _scalar_or_first(showlegend, nothing)
		if sl isa Bool
			trace_kw[:showlegend] = sl
		end
		push!(_plot_data(fig), scatter(; trace_kw...))
		stem_color = color1 == "" ? "black" : color1
		for m in eachindex(y)
			push!(_plot_data(fig),
				scatter(
					x = [x[m], x[m]],
					y = [0, y[m]],
					mode = "lines",
					line = attr(
						color = stem_color,
						width = 0.5,
					),
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
	x = _auto_xvalues(y)
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

"""
	plot_bar!(fig, x, y; kwargs...)
	plot_bar!(fig, y; kwargs...)

Append bar trace(s) to `fig`: a `Plot`, a [`SyncPlot`](@ref) or a
[`SubplotFigure`](@ref) cell. Data conventions and keywords are those of
[`plot_bar`](@ref) (including `orientation`, `barmode`, `error_x`/`error_y`,
`text`, `textposition`, `texttemplate`, `base`, `opacity`, `hatch` and the
tick keywords), with these differences:
- `grid::Union{Nothing,Bool,Symbol} = nothing` leaves the grid unchanged; any
  other value (also `true`) is applied.
- `show` is not accepted (`ArgumentError`); display the figure instead.
- On a `SubplotFigure`, `row`/`col` select the cell (default: the current
  cell) and `secondary_y = true` targets the cell's secondary y axis; the
  axis keywords apply to that cell's axes. `title`, `width` and `height` are
  figure-wide and are ignored there with a warning, and `barmode` (a single
  figure-wide plotly setting) applies to every cell.

Every keyword is validated before the figure changes. Returns `nothing` for a
`Plot`/`SyncPlot` and the `SubplotFigure` for a subplot target.

#### Example
```julia
fig = plot_bar(["a", "b"], [1, 2]; legend = "2023")
plot_bar!(fig, ["a", "b"], [2, 3]; legend = "2024", text = [2, 3])
```
"""
function plot_bar!(
	fig,
	x::AbstractVector,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	orientation::AbstractString = "",
	barmode::AbstractString = "",
	error_x = nothing,
	error_y = nothing,
	text = nothing,
	textposition::AbstractString = "",
	texttemplate::AbstractString = "",
	base = nothing,
	opacity::Union{Nothing, Real} = nothing,
	hatch::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	kwargs...,
)
	_stats_reject_keywords("plot_bar!", kwargs)
	_stats_bar!(
		fig,
		x,
		y,
		"plot_bar!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, orientation, barmode, error_x, error_y, text,
			textposition, texttemplate, base, opacity, hatch);
		mutator = true,
	)
	return nothing
end

function plot_bar!(
	fig,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	orientation::AbstractString = "",
	barmode::AbstractString = "",
	error_x = nothing,
	error_y = nothing,
	text = nothing,
	textposition::AbstractString = "",
	texttemplate::AbstractString = "",
	base = nothing,
	opacity::Union{Nothing, Real} = nothing,
	hatch::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	kwargs...,
)
	_stats_reject_keywords("plot_bar!", kwargs)
	_stats_bar!(
		fig,
		nothing,
		y,
		"plot_bar!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, orientation, barmode, error_x, error_y, text,
			textposition, texttemplate, base, opacity, hatch);
		mutator = true,
	)
	return nothing
end

"""
	plot_histogram!(fig, x; kwargs...)

Append histogram trace(s) of the samples `x` to `fig`: a `Plot`, a
[`SyncPlot`](@ref) or a [`SubplotFigure`](@ref) cell. Data conventions and
keywords are those of [`plot_histogram`](@ref) (`nbinsx` is an approximate
bin count; `bins`, `histnorm`, `cumulative`, `orientation`, `barmode`, `opacity`,
`hatch`, tick keywords). The series of ONE call share bins and overlay as
described there; separate calls are binned separately, and appending single
series one call at a time gives plotly's layout for the figure's `barmode`
(grouped by default). Differences from the constructor:
- `grid::Union{Nothing,Bool,Symbol} = nothing` leaves the grid unchanged; any
  other value (also `true`) is applied.
- `show` is not accepted (`ArgumentError`).
- On a `SubplotFigure`, `row`/`col` select the cell (default: the current
  cell) and `secondary_y = true` targets its secondary y axis; `title`,
  `width` and `height` are figure-wide and ignored there with a warning.

Every keyword is validated before the figure changes. Returns `nothing` for a
`Plot`/`SyncPlot` and the `SubplotFigure` for a subplot target.

#### Example
```julia
fig = plot_histogram(randn(500); legend = "reference")
plot_histogram!(fig, [randn(500) .+ 1, randn(500) .- 1]; bins = (-5, 5, 0.25))
```
"""
function plot_histogram!(
	fig,
	x::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	nbinsx::Integer = 0,
	bins = nothing,
	histnorm::AbstractString = "",
	cumulative::Bool = false,
	orientation::AbstractString = "",
	barmode::AbstractString = "",
	opacity::Union{Nothing, Real} = nothing,
	hatch::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	kwargs...,
)
	_stats_reject_keywords("plot_histogram!", kwargs)
	_stats_histogram!(
		fig,
		x,
		"plot_histogram!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, nbinsx, bins, histnorm, cumulative,
			orientation, barmode, opacity, hatch);
		mutator = true,
	)
	return nothing
end

"""
	plot_box!(fig, x, y; kwargs...)
	plot_box!(fig, y; kwargs...)

Append box trace(s) to `fig`: a `Plot`, a [`SyncPlot`](@ref) or a
[`SubplotFigure`](@ref) cell. Data conventions and keywords are those of
[`plot_box`](@ref) (`points`, `orientation`, `boxmean`, `notched`, `jitter`,
`pointpos`, tick keywords). In the y-only form, group mode is chosen when the
new series' names are blank or repeated, or repeat the name of a box already
in the figure that has no explicit positions. Differences from the
constructor:
- `grid::Union{Nothing,Bool,Symbol} = nothing` leaves the grid unchanged; any
  other value (also `true`) is applied.
- `show` is not accepted (`ArgumentError`).
- On a `SubplotFigure`, `row`/`col` select the cell (default: the current
  cell) and `secondary_y = true` targets its secondary y axis; `title`,
  `width` and `height` are figure-wide and ignored there with a warning.

Every keyword is validated before the figure changes. Returns `nothing` for a
`Plot`/`SyncPlot` and the `SubplotFigure` for a subplot target.

#### Example
```julia
fig = plot_box(randn(100); legend = "control")
plot_box!(fig, randn(100) .+ 1; legend = "drug", boxmean = "sd")
```
"""
function plot_box!(
	fig,
	x::AbstractVector,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	points::Union{Bool, AbstractString} = "outliers",
	orientation::AbstractString = "",
	boxmean::Union{Bool, AbstractString} = false,
	notched::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
	kwargs...,
)
	_stats_reject_keywords("plot_box!", kwargs)
	_stats_distribution!(
		fig,
		x,
		y,
		"plot_box!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, points, orientation, boxmean, notched, jitter,
			pointpos);
		kind = :box,
		mutator = true,
	)
	return nothing
end

function plot_box!(
	fig,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	points::Union{Bool, AbstractString} = "outliers",
	orientation::AbstractString = "",
	boxmean::Union{Bool, AbstractString} = false,
	notched::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
	kwargs...,
)
	_stats_reject_keywords("plot_box!", kwargs)
	_stats_distribution!(
		fig,
		nothing,
		y,
		"plot_box!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, points, orientation, boxmean, notched, jitter,
			pointpos);
		kind = :box,
		mutator = true,
	)
	return nothing
end

"""
	plot_violin!(fig, x, y; kwargs...)
	plot_violin!(fig, y; kwargs...)

Append violin trace(s) to `fig`: a `Plot`, a [`SyncPlot`](@ref) or a
[`SubplotFigure`](@ref) cell. Data conventions and keywords are those of
[`plot_violin`](@ref) (`points`, `side`, `orientation`, `box`, `meanline`,
`jitter`, `pointpos`, tick keywords); group mode is chosen as for
[`plot_box!`](@ref). Differences from the constructor:
- `grid::Union{Nothing,Bool,Symbol} = nothing` leaves the grid unchanged; any
  other value (also `true`) is applied.
- `show` is not accepted (`ArgumentError`).
- On a `SubplotFigure`, `row`/`col` select the cell (default: the current
  cell) and `secondary_y = true` targets its secondary y axis; `title`,
  `width` and `height` are figure-wide and ignored there with a warning.

Every keyword is validated before the figure changes. Returns `nothing` for a
`Plot`/`SyncPlot` and the `SubplotFigure` for a subplot target.

#### Example
```julia
fig = plot_violin(randn(200); legend = "a")
plot_violin!(fig, randn(200) .+ 1; legend = "b", box = true, meanline = true)
```
"""
function plot_violin!(
	fig,
	x::AbstractVector,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	points::Union{Bool, AbstractString} = "outliers",
	side::AbstractString = "both",
	orientation::AbstractString = "",
	box::Bool = false,
	meanline::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
	kwargs...,
)
	_stats_reject_keywords("plot_violin!", kwargs)
	_stats_distribution!(
		fig,
		x,
		y,
		"plot_violin!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, points, side, orientation, box, meanline,
			jitter, pointpos);
		kind = :violin,
		mutator = true,
	)
	return nothing
end

function plot_violin!(
	fig,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
	showlegend::Union{Nothing, Bool, AbstractVector{Bool}} = nothing,
	points::Union{Bool, AbstractString} = "outliers",
	side::AbstractString = "both",
	orientation::AbstractString = "",
	box::Bool = false,
	meanline::Bool = false,
	jitter::Union{Nothing, Real} = nothing,
	pointpos::Union{Nothing, Real} = nothing,
	kwargs...,
)
	_stats_reject_keywords("plot_violin!", kwargs)
	_stats_distribution!(
		fig,
		nothing,
		y,
		"plot_violin!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, points, side, orientation, box, meanline,
			jitter, pointpos);
		kind = :violin,
		mutator = true,
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
	r_nested, theta_nested = _nested_coordinate_mode(r, theta, :r, :theta)
	if r_nested
		series_count = length(r)
		modeV = _series_kwarg_vector(
			mode,
			series_count,
			"lines",
			String,
		)
		dashV = _series_kwarg_vector(
			dash,
			series_count,
			"",
			String,
		)
		colorV = _series_kwarg_vector(
			color,
			series_count,
			"",
			String,
		)
		legendV = _series_kwarg_vector(
			legend,
			series_count,
			"",
			String,
		)
		marker_sizeV = _series_kwarg_vector(
			marker_size,
			series_count,
			0,
			Int,
		)
		marker_symbolV = _series_kwarg_vector(
			marker_symbol,
			series_count,
			"",
			String,
		)
		linewidthV = _series_kwarg_vector(
			linewidth,
			series_count,
			0.0,
			Float64,
		)
		showlegendV = _series_kwarg_vector(
			showlegend,
			series_count,
			nothing,
			Union{Nothing,Bool},
		)

		if theta_nested
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

function _area_traces(x, y; color, legend, mode::String, stack::Bool)
	y_nested, x_nested = _nested_coordinate_mode(y, x, :y, :x)
	if y_nested
		colorV = _string_kwarg_vector(color, length(y))
		legendV = _string_kwarg_vector(legend, length(y))
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
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	grid::Union{Nothing, Bool} = nothing,
)
	trace = _area_traces(x, y; color = color, legend = legend, mode = mode, stack = stack)
	for t in (trace isa AbstractVector ? trace : [trace])
		push!(_plot_data(fig), t)
	end
	_apply_cartesian_grid_override!(fig, grid)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		refresh = true,
		apply_template = false,
	)
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

# Finite numeric samples of one histogram axis (the Julia-binned path needs
# numbers; missing and non-finite samples are skipped).
function _stats_numeric_samples(values, who::AbstractString, name::AbstractString)
	samples = Float64[]
	sizehint!(samples, length(values))
	for value in values
		value === missing && continue
		(value isa Real && !(value isa Bool)) || throw(ArgumentError(
			"$(who): a log binning axis (and colornorm=:log) bins the samples in Julia, " *
			"which needs numeric `$(name)`; got $(repr(value)).",
		))
		isfinite(value) && push!(samples, Float64(value))
	end
	return samples
end

# Where a sample falls on its axis for binning: the value on a linear axis,
# log10 of it on a log axis (where non-positive values cannot be shown).
# `nothing` for samples that are not binned (missing, non-finite, ≤ 0 on log).
function _stats_bin_position(value, log_axis::Bool)
	(value isa Real && !(value isa Bool) && isfinite(value)) || return nothing
	log_axis || return Float64(value)
	value > 0 || return nothing
	return log10(Float64(value))
end

# Whether a histogram's binning axis is logarithmic after this call: the
# requested scale, else the figure's current axis type. plotly.js 2.35 cannot
# bin a histogram or histogram2d on a log axis: automatic bins mix a log-unit
# bin end with a data-unit size and come out empty (gd.calcdata holds no
# counts for x = exp.(randn(5000)) on a log x axis), and explicit bins are
# misread (1-D: 115 bins spanning 2..31 for start=-2, end=2, size=0.25; 2-D:
# a renderer "Invalid array length" error for start=0, end=30, size=1). Such
# histograms are binned in Julia instead.
function _stats_log_axis(fig, scale::AbstractString, key::Symbol)
	isempty(scale) || return scale == "log"
	return _axis_type(_plot_layout(fig), key) == "log"
end

# plotly.js computes `Math.log(v) / Math.LN10`, which differs from `log10` at
# exact powers of ten (log(1000)/ln(10) = 2.9999999999999996); the automatic
# bins below must round the same way to reproduce plotly's bin width.
_stats_js_floor_log10(value::Float64) = floor(log(value) / log(10.0))

# Automatic bins `(start, stop, width)` of one axis, reproducing plotly.js 2.35
# `Axes.autoBin` for numeric data on a linear (or log, which plotly bins
# linearly) axis in the 2-D histogram variant, so a histogram2d binned in
# Julia (colornorm = :log) gets the bins plotly would pick for the same data.
# `samples` are the finite values; `total` is the length of the original data
# including missing/non-finite entries, which plotly keeps in the sample count
# of its 2σ/n^(1/4) estimate. `nbins > 0` is the requested (approximate) bin
# count, as plotly's `nbinsx`. Verified
# against the bins plotly.js computes (gd._fullData xbins/ybins) for normal,
# uniform, integer, constant, single-sample, scaled and clustered data.
function _stats_autobins(samples::Vector{Float64}, nbins::Int; total::Int = length(samples))
	count = length(samples)
	count > 0 || throw(ArgumentError("_stats_autobins: needs at least one finite sample."))
	total >= count || throw(ArgumentError("_stats_autobins: `total` must be at least the sample count."))
	lower, upper = extrema(samples)
	size_estimate = if nbins > 0
		(upper - lower) / nbins
	else
		# Smallest gap between distinct values, rounded down to 0.9, 1.9, 4.9
		# or 9.9 times its decade, against 2σ/n^(1/4) (2-D variant).
		sorted = sort(samples)
		min_gap = upper - lower
		min_gap == 0 && (min_gap = 1.0)
		threshold = min_gap / max(count - 1, 1) / 1e4
		previous = sorted[1]
		for value in @view sorted[2:end]
			gap = value - previous
			if gap > threshold
				min_gap = min(min_gap, gap)
				previous = value
			end
		end
		decade = 10.0^_stats_js_floor_log10(min_gap)
		ratio = min_gap / decade
		rounded = decade * (ratio >= 9.9 ? 9.9 : ratio >= 4.9 ? 4.9 : ratio >= 1.9 ? 1.9 : 0.9)
		mean_value = sum(samples) / count
		deviation = sqrt(sum(value -> (value - mean_value)^2, samples) / count)
		max(rounded, 2 * deviation / total^0.25)
	end
	(isfinite(size_estimate) && size_estimate > 0) || (size_estimate = 1.0)
	# Axes.autoTicks on a linear axis: the next "nice" width 2, 5 or 10 times
	# the estimate's decade that is strictly larger than the estimate.
	decade = 10.0^_stats_js_floor_log10(size_estimate)
	ratio = size_estimate / decade
	width = decade * (ratio < 2 ? 2.0 : ratio < 5 ? 5.0 : 10.0)
	start = ceil(lower / width) * width - width
	# Move the edges off the data: integer data gets half-integer edges, and
	# data clustered on the edges is shifted by half a bin.
	near_edge(value) = rem(1 + 100 * (value - start) / width, 100) < 2
	integers = 0
	on_edges = 0
	on_centres = 0
	for value in samples
		isinteger(value) && (integers += 1)
		near_edge(value) && (on_edges += 1)
		near_edge(value + width / 2) && (on_centres += 1)
	end
	shifted = start
	if integers == count
		if width < 1
			shifted = lower - 0.5 * width
		else
			shifted -= 0.5
			shifted + width < lower && (shifted += width)
		end
	elseif on_centres < 0.1 * count &&
		(on_edges > 0.3 * count || near_edge(lower) || near_edge(upper))
		half = width / 2
		shifted += shifted + half < lower ? half : -half
	end
	stop = shifted + (1 + floor((upper - shifted) / width)) * width
	return shifted, stop, width
end

# Bin index (1-based) of `value` for bins starting at `start` of `width`, or 0
# outside; plotly's `Lib.findBin` uses the same 1e-9 tolerance.
function _stats_bin_index(value::Float64, start::Float64, width::Float64, nbins::Int)
	index = floor(Int, (value - start) / width + 1e-9) + 1
	return 1 <= index <= nbins ? index : 0
end

const _STATS_HISTNORM_LABELS = Dict(
	"" => "count",
	"percent" => "percent",
	"probability" => "probability",
	"density" => "density",
	"probability density" => "probability density",
)

# Julia-side 2-D histogram, used where plotly's own histogram2d cannot serve:
# colornorm = :log (plotly counts in the browser, where the counts cannot be
# log-normed) and log axes (where plotly bins nothing). The bins are plotly's
# automatic bins over the bin positions (`_stats_bin_position`): linear in the
# data on a linear axis, of equal width in decades on a log axis. Returns the
# bin edges in data units and the normalized counts as `z[iy, ix]`.
function _stats_histogram2d_counts(
	x,
	y,
	nbinsx::Int,
	nbinsy::Int,
	histnorm::String,
	who::AbstractString;
	xlog::Bool,
	ylog::Bool,
)
	x_numeric = _stats_numeric_samples(x, who, "x")
	y_numeric = _stats_numeric_samples(y, who, "y")
	x_samples = xlog ? Float64[log10(value) for value in x_numeric if value > 0] : x_numeric
	y_samples = ylog ? Float64[log10(value) for value in y_numeric if value > 0] : y_numeric
	requirement = (xlog || ylog) ? "finite (and on a log axis positive)" : "finite"
	(isempty(x_samples) || isempty(y_samples)) && throw(ArgumentError(
		"$(who): binning in Julia needs at least one $(requirement) x and y sample.",
	))
	x_start, x_stop, x_width = _stats_autobins(x_samples, nbinsx; total = length(x))
	y_start, y_stop, y_width = _stats_autobins(y_samples, nbinsy; total = length(y))
	nx = round(Int, (x_stop - x_start) / x_width)
	ny = round(Int, (y_stop - y_start) / y_width)
	counts = zeros(Float64, ny, nx)
	total = 0
	for (x_value, y_value) in zip(x, y)
		x_position = _stats_bin_position(x_value, xlog)
		y_position = _stats_bin_position(y_value, ylog)
		(x_position === nothing || y_position === nothing) && continue
		ix = _stats_bin_index(x_position, x_start, x_width, nx)
		iy = _stats_bin_index(y_position, y_start, y_width, ny)
		(ix == 0 || iy == 0) && continue
		counts[iy, ix] += 1
		total += 1
	end
	total > 0 || throw(ArgumentError(
		"$(who): binning in Julia needs at least one (x, y) pair whose x and y are both " *
		"$(requirement).",
	))
	x_edges = [x_start + k * x_width for k in 0:nx]
	y_edges = [y_start + k * y_width for k in 0:ny]
	xlog && (x_edges = exp10.(x_edges))
	ylog && (y_edges = exp10.(y_edges))
	if histnorm == "percent"
		counts .*= 100 / total
	elseif histnorm == "probability"
		counts ./= total
	elseif histnorm in ("density", "probability density")
		# Bin areas in data units: equal on linear axes, growing with the
		# decade on a log axis.
		counts ./= diff(y_edges) .* permutedims(diff(x_edges))
		histnorm == "probability density" && (counts ./= total)
	end
	return x_edges, y_edges, counts
end

_stats_matrix_rows(matrix::AbstractMatrix) =
	[Any[_stats_json_value(matrix[row, column]) for column in axes(matrix, 2)] for row in axes(matrix, 1)]

# Non-finite colour values are gaps; JSON `null` is plotly's gap marker.
_stats_json_value(value) = value isa Real && !isfinite(value) ? _GAP : value

function _stats_histogram2d!(fig, x, y, who::AbstractString, options, color_options; mutator::Bool)
	o = color_options
	(_is_nested_series(x) || _is_nested_series(y)) && throw(ArgumentError(
		"$(who): takes one set of paired samples `x`, `y`; got a vector of series.",
	))
	_stats_check_series(x, who, "x")
	_stats_check_series(y, who, "y")
	length(x) == length(y) || throw(ArgumentError(
		"$(who): `x` and `y` must have the same length (one (x, y) sample per entry); " *
		"got $(length(x)) and $(length(y)).",
	))
	nbinsx = _stats_count(o.nbinsx, who, "nbinsx")
	nbinsy = _stats_count(o.nbinsy, who, "nbinsy")
	histnorm = _stats_choice(o.histnorm, _STATS_HISTNORMS, who, "histnorm")
	norm = _normalize_colornorm(o.colornorm, who)
	coloraxis = o.coloraxis === nothing ? nothing : _normalize_coloraxis(o.coloraxis, who)
	colorbar_title = _stats_label(o.colorbar_title)

	xlog = _stats_log_axis(fig, options.xscale, :xaxis)
	ylog = _stats_log_axis(fig, options.yscale, :yaxis)
	if norm === :log || xlog || ylog
		x_edges, y_edges, counts = _stats_histogram2d_counts(
			x, y, nbinsx, nbinsy, histnorm, who; xlog = xlog, ylog = ylog,
		)
		# Under the log norm empty bins hold no data: they stay blank
		# (matplotlib's LogNorm masks them too) instead of being floored to the
		# bottom of an explicit crange. The linear norm colours them as 0, as
		# plotly's own histogram2d does.
		mapped = _apply_color_norm(
			norm === :log ? map(count -> count > 0 ? count : NaN, counts) : counts;
			crange = o.crange,
			cmid = o.cmid,
			colornorm = norm,
			levels = o.levels,
			stops = o.colorscale,
			ticks = o.colorbar_ticks,
			ticklabels = o.colorbar_ticklabels,
			who = who,
		)
		value_format = histnorm == "" ? "%{customdata}" : "%{customdata:.3g}"
		trace = heatmap(
			x = x_edges,
			y = y_edges,
			z = _stats_matrix_rows(mapped.values),
			customdata = _stats_matrix_rows(counts),
			transpose = false,
			hovertemplate = "x: %{x}<br>y: %{y}<br>$(_STATS_HISTNORM_LABELS[histnorm]): " *
				"$(value_format)<extra></extra>",
		)
	else
		mapped = _apply_color_norm(
			nothing;
			crange = o.crange,
			cmid = o.cmid,
			colornorm = :linear,
			levels = o.levels,
			stops = o.colorscale,
			ticks = o.colorbar_ticks,
			ticklabels = o.colorbar_ticklabels,
			who = who,
		)
		fields = Dict{Symbol, Any}(:x => x, :y => y)
		nbinsx > 0 && (fields[:nbinsx] = nbinsx)
		nbinsy > 0 && (fields[:nbinsy] = nbinsy)
		isempty(histnorm) || (fields[:histnorm] = histnorm)
		trace = histogram2d(; fields...)
	end
	# User colorbar tick labels are text for MathJax; the automatic decade
	# labels of the log norm are plotly HTML and stay verbatim.
	ticktext = mapped.ticktext
	if o.colorbar_ticklabels !== nothing && ticktext !== nothing
		ticktext = String[_stats_label(label) for label in ticktext]
	end
	colorbar = _colorbar_attr(;
		title = colorbar_title,
		ticks = mapped.tickvals,
		ticklabels = ticktext,
		who = who,
	)
	scale = mapped.stops
	has_scale = !(scale isa AbstractString && isempty(scale))
	layout_fields = Pair{Symbol, Any}[]
	if coloraxis === nothing
		has_scale && (trace.colorscale = scale)
		mapped.cmin === nothing || (trace.zmin = mapped.cmin)
		mapped.cmax === nothing || (trace.zmax = mapped.cmax)
		mapped.cmid === nothing || (trace.zmid = mapped.cmid)
		colorbar === nothing || (trace.colorbar = colorbar)
		o.showscale === nothing || (trace.showscale = o.showscale)
	else
		# A shared colour axis carries the scale, limits and colorbar of every
		# trace bound to it; existing colorbar styling is merged, not replaced.
		trace.coloraxis = coloraxis
		has_scale && push!(layout_fields, Symbol(coloraxis, "_colorscale") => scale)
		mapped.cmin === nothing || push!(layout_fields, Symbol(coloraxis, "_cmin") => mapped.cmin)
		mapped.cmax === nothing || push!(layout_fields, Symbol(coloraxis, "_cmax") => mapped.cmax)
		mapped.cmid === nothing || push!(layout_fields, Symbol(coloraxis, "_cmid") => mapped.cmid)
		o.showscale === nothing || push!(layout_fields, Symbol(coloraxis, "_showscale") => o.showscale)
		if colorbar !== nothing
			for (key, value) in colorbar.fields
				if key === :title
					push!(layout_fields, Symbol(coloraxis, "_colorbar_title_text") => colorbar_title)
				else
					push!(layout_fields, Symbol(coloraxis, "_colorbar_", key) => value)
				end
			end
		end
	end
	_stats_validate_options(fig, who, options)

	push!(_plot_data(fig), trace)
	isempty(layout_fields) || relayout!(fig; layout_fields...)
	_stats_apply_options!(fig, who, options; mutator = mutator)
	return nothing
end

"""
	plot_histogram2d(x, y; kwargs...)

2-D histogram (density heatmap) of the paired samples `x[i]`, `y[i]`. Returns
a `PlotlyBase.Plot`, or a [`SyncPlot`](@ref) window when `show = true`.

#### Data
`x`, `y::AbstractVector` of equal length (vectors, ranges or views; complex
values are an `ArgumentError`). By default plotly bins and counts the samples
(a `histogram2d` trace). Two cases are binned in Julia instead and drawn as a
`heatmap` over the bin edges, whose hover shows the (normalized) count;
numeric data only, missing and non-finite samples are skipped:
- `colornorm = :log`: the bins are those plotly would choose; `z` is log10 of
  the count and empty bins are left blank.
- a log x or y axis (`xscale`/`yscale = "log"`, or a mutator target whose axis
  is already logarithmic), where plotly.js cannot bin a `histogram2d` and
  would draw nothing: along a log axis the bins have equal width in decades
  (chosen like plotly's automatic bins, over log10 of the data), and
  non-positive samples, which a log axis cannot show, are dropped. Densities
  divide by each bin's area in data units.

#### Keyword Arguments
- `nbinsx`, `nbinsy::Integer = 0`: approximate number of bins along x / y
  (`0` = automatic); plotly rounds the bin width to a "nice" value and aligns
  the edges to round numbers, so the drawn count can be somewhat higher or
  lower (see [`plot_histogram`](@ref)). On a log axis the width is in decades.
- `histnorm::AbstractString = ""`: `""` (counts), `"percent"`,
  `"probability"`, `"density"` or `"probability density"`.
- `colorscale = ""`: colormap name (`"viridis"`, `"RdBu_r"`, `:magma`, a
  plotly name), a vector of colours or `(t, colour)` stops, or a
  `ColorScheme`; `""` uses the template's colorscale.
- `crange = [0, 0]`: colour limits `[min, max]` (data units, counts);
  `[0, 0]`/`nothing` is automatic.
- `cmid::Union{Nothing,Real} = nothing`: colour midpoint (linear norm).
- `colornorm::Union{Symbol,AbstractString} = :linear`: `:linear` or `:log`
  (decade colorbar ticks labelled 10ᵏ).
- `levels = nothing`: k+1 increasing boundaries giving k discrete colours.
- `showscale::Union{Nothing,Bool} = nothing`: show/hide the colorbar.
- `colorbar_title::AbstractString = ""`, `colorbar_ticks = nothing`,
  `colorbar_ticklabels = nothing`: colorbar title and ticks (tick positions
  in data units, labels need ticks of the same length).
- `coloraxis = nothing`: `:shared` (or `"coloraxis"`, `"coloraxis2"`, …)
  binds the trace to a shared colour axis; the colour keywords are then
  written to that layout colour axis.
- `xlabel`, `ylabel`, `title`, `xrange`, `yrange`, `xscale`, `yscale`,
  `xticks`, `xticklabels`, `xtickformat`, `yticks`, `yticklabels`,
  `ytickformat`, `width`, `height`, `fontsize`, `grid = true`, `show = false`:
  as in [`plot_bar`](@ref).

#### Example
```julia
x, y = randn(5000), randn(5000)
fig = plot_histogram2d(x, y; nbinsx = 40, nbinsy = 40, colorscale = "viridis")
plot_histogram2d(x, y; colornorm = :log, colorbar_title = "count")
```
"""
function plot_histogram2d(
	x::AbstractVector,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = true,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	nbinsx::Integer = 0,
	nbinsy::Integer = 0,
	histnorm::AbstractString = "",
	colorscale = "",
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	show::Bool = false,
)
	fig = Plot(GenericTrace[], _default_cartesian_layout())
	_stats_histogram2d!(
		fig,
		x,
		y,
		"plot_histogram2d",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; nbinsx, nbinsy, histnorm, colorscale, crange, cmid, colornorm, levels,
			showscale, colorbar_title, colorbar_ticks, colorbar_ticklabels, coloraxis);
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

"""
	plot_histogram2d!(fig, x, y; kwargs...)

Append a 2-D histogram of the paired samples `x`, `y` to `fig`: a `Plot`, a
[`SyncPlot`](@ref) or a [`SubplotFigure`](@ref) cell. Data conventions and
keywords are those of [`plot_histogram2d`](@ref), with these differences:
- `grid::Union{Nothing,Bool,Symbol} = nothing` leaves the grid unchanged; any
  other value (also `true`) is applied.
- `show` is not accepted (`ArgumentError`).
- On a `SubplotFigure`, `row`/`col` select the cell (default: the current
  cell) and `secondary_y = true` targets its secondary y axis; `title`,
  `width` and `height` are figure-wide and ignored there with a warning.

Every keyword is validated before the figure changes. Returns `nothing` for a
`Plot`/`SyncPlot` and the `SubplotFigure` for a subplot target.

#### Example
```julia
fig = plot_scatter(randn(100), randn(100); mode = "markers")
plot_histogram2d!(fig, randn(5000), randn(5000); colornorm = :log)
```
"""
function plot_histogram2d!(
	fig,
	x::AbstractVector,
	y::AbstractVector;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	xticks = nothing,
	xticklabels = nothing,
	xtickformat::AbstractString = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat::AbstractString = "",
	nbinsx::Integer = 0,
	nbinsy::Integer = 0,
	histnorm::AbstractString = "",
	colorscale = "",
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	kwargs...,
)
	_stats_reject_keywords("plot_histogram2d!", kwargs)
	_stats_histogram2d!(
		fig,
		x,
		y,
		"plot_histogram2d!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; nbinsx, nbinsy, histnorm, colorscale, crange, cmid, colornorm, levels,
			showscale, colorbar_title, colorbar_ticks, colorbar_ticklabels, coloraxis);
		mutator = true,
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
