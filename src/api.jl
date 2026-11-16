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
	(position isa Symbol || position isa AbstractString) || throw(ArgumentError(
		"legend position must be a Symbol or a string such as :topright; got $(repr(position)).",
	))
	pos_raw = lowercase(strip(String(position)))
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
	get_default_legend_position() -> Symbol

Return the package-wide default legend position (a `Symbol` such as
`:topright`): where constructors and `plot_*!` mutators place a new legend box,
where [`set_legend!`](@ref) puts a legend that has none yet, and the default of
`subplots(...; legend_position)`. Change it with
[`set_default_legend_position!`](@ref).
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
	set_default_legend_position!(position::Union{Symbol,AbstractString} = :topright) -> Symbol

Set the package-wide default legend position (see
[`get_default_legend_position`](@ref)). Accepted symbols are `:topright`,
`:top`, `:topleft`, `:right`, `:center`, `:left`, `:bottomright`, `:bottom`,
`:bottomleft` (inside the axes) and the outside placements `:outside_right`,
`:outside_left`, `:outside_top` and `:outside_bottom` (placed as described in
[`set_legend!`](@ref)). Case, hyphen/space and alias forms (`"top-left"`,
`"upper right"`, `:outside`, `:left_outside`, …) are normalized; an
unrecognized name warns and falls back to `:topright`; a value that is neither
a `Symbol` nor a string throws an `ArgumentError`. Figures that already exist
are not changed. Returns the normalized position.

# Example
```julia
set_default_legend_position!(:outside_bottom)
fig = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; legend = ["a", "b"])  # legend below the axes
set_default_legend_position!()                                         # back to :topright
```
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

# Axis id a legend groups an x/y trace under: an overlaying axis (secondary y
# from `Spec(secondary_y=true)`, `_ensure_twin_y!`, a secondary x axis) has no
# domain of its own, so it resolves to the axis it overlays (and transitively
# through chains). A cycle or a missing target stops at the last axis.
function _legend_base_axis_ref(layout::Layout, ref::String, letter::Symbol)
	pattern = letter === :x ? r"^x([2-9]|[1-9][0-9]+)?$" : r"^y([2-9]|[1-9][0-9]+)?$"
	seen = Set{String}()
	current = ref
	while !(current in seen)
		push!(seen, current)
		key = _axis_layout_key(current, letter)
		_layout_axis_domain(layout, key) === nothing || return current
		overlaying = _cmn_mapping_get(get(layout.fields, key, nothing), :overlaying)
		(overlaying isa AbstractString && occursin(pattern, overlaying)) ||
			return current
		current = String(overlaying)
	end
	return current
end

function _trace_subplot_key_domain(p::Plot, trace::GenericTrace)
	fields = trace.fields

	if haskey(fields, :xaxis) || haskey(fields, :yaxis)
		xaxis = _legend_base_axis_ref(p.layout, String(get(fields, :xaxis, "x")), :x)
		yaxis = _legend_base_axis_ref(p.layout, String(get(fields, :yaxis, "y")), :y)
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

# Legend id reserved for the figure-level legend of a SubplotFigure that also
# has per-cell legends (`legend_entry!(…; legend_target=:figure)`). Cell legends
# are numbered 1, 2, … in order of first appearance, so the figure legend needs
# an id no cell can reach; plotly.js accepts any `legendN` and only lays out the
# ids traces reference, so a sparse high id costs nothing. A figure with this
# many cell legends is rejected rather than silently merged.
const _FIGURE_LEGEND_INDEX = 1000
const _FIGURE_LEGEND_ID = _legend_id(_FIGURE_LEGEND_INDEX)
# `meta` marker of proxy entries that belong to the figure-level legend.
const _FIGURE_LEGEND_META = "plotlysupply:figure_legend"
# Prefix of the legend groups `dedupe` creates (user groups are never renamed).
const _LEGEND_DEDUPE_GROUP_PREFIX = "plotlysupply:dedupe:"
const _LEGEND_OUTSIDE_POSITIONS = (:outside_right, :outside_left, :outside_top, :outside_bottom)
# Layout keys that make up a legend's placement; replacing a placement
# removes the ones the new placement does not set.
const _LEGEND_PLACEMENT_KEYS = (:x, :y, :xanchor, :yanchor, :xref, :yref, :orientation)
const _LEGEND_ID_PATTERN = r"^legend([2-9]|[1-9][0-9]+)$"

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

_trace_is_figure_legend_entry(trace) =
	trace isa GenericTrace && get(trace.fields, :meta, nothing) == _FIGURE_LEGEND_META

_legend_trace_legend_id(trace::GenericTrace) = string(get(trace.fields, :legend, "legend"))

# C12: a trace whose `name` is blank text and that sets no `showlegend` would
# give a blank legend entry. Traces without a `name` key keep Plotly's own
# "trace N" naming, and pie-like traces list their slices, not their name.
function _legend_hides_unnamed(trace)
	trace isa GenericTrace || return false
	haskey(trace.fields, :showlegend) && return false
	_trace_has_slice_legend(trace) && return false
	name = get(trace.fields, :name, nothing)
	return name isa AbstractString && isempty(strip(name))
end

function _legend_hide_unnamed!(p::Plot)
	for trace in p.data
		_legend_hides_unnamed(trace) && (trace.fields[:showlegend] = false)
	end
	return nothing
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

# Anchor that keeps a legend whose reference point is at fraction `f` of the
# axes on the axes side: points outside [0,1] put the legend beyond the point,
# points inside snap to the nearest third (plotly's own "auto" rule, applied in
# axes rather than paper fractions).
function _legend_tuple_anchor(f::Float64, low::String, mid::String, high::String)
	f > 1 && return low
	f < 0 && return high
	f < 1 / 3 && return low
	f > 2 / 3 && return high
	return mid
end

"""
	_legend_placement(position, xdom, ydom, inset; figure, xanchor = "", yanchor = "")

Placement fields (`x`, `y`, `xanchor`, `yanchor`, and `xref`/`yref`/`orientation`
when needed) of a legend box for `position` (a normalized Symbol or an
`(fx, fy)` tuple in fractions of the `xdom`×`ydom` paper box). `figure=true`
marks a figure-level legend: `:outside_left` and `:outside_bottom` are then
anchored to the container (plotly reserves a margin for them, so they never
cover tick labels or axis titles, spec C11); `:outside_top`/`:outside_right`
stay paper-anchored above/right of the plot, where plotly pushes the margin.
Outside top/bottom legends default to a horizontal orientation. Non-empty
`xanchor`/`yanchor` replace the computed anchors.
"""
function _legend_placement(
	position,
	xdom::Tuple{Float64, Float64},
	ydom::Tuple{Float64, Float64},
	inset::Tuple{Float64, Float64};
	figure::Bool,
	xanchor::AbstractString = "",
	yanchor::AbstractString = "",
)
	fields = Dict{Symbol, Any}()
	if position isa Tuple
		fx = Float64(position[1])
		fy = Float64(position[2])
		x = xdom[1] + fx * (xdom[2] - xdom[1])
		y = ydom[1] + fy * (ydom[2] - ydom[1])
		xa = _legend_tuple_anchor(fx, "left", "center", "right")
		ya = _legend_tuple_anchor(fy, "bottom", "middle", "top")
	else
		pos = position::Symbol
		x, y, xa, ya = _legend_anchor(xdom, ydom, inset, pos)
		if figure && pos === :outside_left
			fields[:xref] = "container"
			x = 0.0
			xa = "left"
		elseif figure && pos === :outside_bottom
			fields[:yref] = "container"
			y = 0.0
			ya = "bottom"
		end
		pos in (:outside_top, :outside_bottom) && (fields[:orientation] = "h")
	end
	fields[:x] = x
	fields[:y] = y
	fields[:xanchor] = isempty(xanchor) ? xa : String(xanchor)
	fields[:yanchor] = isempty(yanchor) ? ya : String(yanchor)
	return fields
end

# Merge `ext` (from `_legend_layout_ext`) into a legend dict: plain values are
# set, Dict values are merged into the nested mapping (`title`, `font`).
function _legend_apply_ext!(d::Dict{Symbol, Any}, ext)
	ext === nothing && return d
	for (key, value) in ext
		if value isa AbstractDict
			nested = _symbol_dict(get(d, key, nothing))
			merge!(nested, value)
			d[key] = attr(; nested...)
		else
			d[key] = value
		end
	end
	return d
end

"""
	_legend_write_block!(p, key; placement, colors, ext, replace_placement, replace_colors, fresh)

Write the legend box `layout.<key>`. `placement` replaces the placement keys
when `replace_placement` (keys it does not set are removed), and is otherwise
written only when the box has no placement yet (`x`/`y` absent), so a box
placed by the user (`relayout!`, `set_legend!`) keeps its position. `colors`
(`bgcolor`/`bordercolor`/`borderwidth`) overwrite when `replace_colors`, else
fill missing keys. `ext` always overwrites. `fresh` drops the old box first.
"""
function _legend_write_block!(
	p::Plot,
	key::Symbol;
	placement = nothing,
	colors = nothing,
	ext = nothing,
	replace_placement::Bool = false,
	replace_colors::Bool = false,
	fresh::Bool = false,
)
	d = fresh ? Dict{Symbol, Any}() : _symbol_dict(get(p.layout.fields, key, nothing))
	if placement !== nothing
		if replace_placement
			for k in _LEGEND_PLACEMENT_KEYS
				haskey(placement, k) || delete!(d, k)
			end
			merge!(d, placement)
		elseif !haskey(d, :x) && !haskey(d, :y)
			merge!(d, placement)
		end
	end
	if colors !== nothing
		for (k, v) in pairs(colors)
			replace_colors ? (d[k] = v) : get!(d, k, v)
		end
	end
	_legend_apply_ext!(d, ext)
	p.layout.fields[key] = attr(; d...)
	return nothing
end

# The figure's own template (`layout.template`): a `Template`, a registered
# name, or a "+"-compound of registered names (as `relayout!(fig; template =
# "plotly_dark+xgridoff")` stores it); `nothing` when it has none or the name
# is unknown.
function _legend_layout_template(p::Plot)
	t = get(p.layout.fields, :template, nothing)
	t isa PlotlyBase.Template && return t
	if t isa AbstractString || t isa Symbol
		parts = strip.(split(String(t), '+'))
		if !isempty(parts) && all(part -> !isempty(part) && Symbol(part) in keys(PlotlyBase.templates), parts)
			return _resolve_template(join(parts, '+'))
		end
	end
	return nothing
end

# Template used for derived legend colours: the figure's own template when it
# has one (so `set_template!(fig, :plotly_dark)` + `set_legend!` gives a dark
# box), else the active style's template.
_legend_figure_template(p::Plot, style) =
	something(_legend_layout_template(p), _style_template(style))

# Default box colours (audit #216/#266): the active PlotStyle's legend frame in
# the figure's template — the 1.x translucent white box on light templates, a
# translucent box in the template background on dark ones, transparent when
# the style has `legend_frame=false`.
function _legend_default_colors(p::Plot)
	style = _active_style()
	d = _style_legend_defaults(style; template = _legend_figure_template(p, style))
	return (bgcolor = d.bgcolor, bordercolor = d.bordercolor, borderwidth = d.borderwidth)
end

# Colours stored on a SubplotFigure (`subplots(...; legend_bgcolor=...)`). The
# constructor stores the 1.x light defaults when the caller passes none, so
# exactly those values stand for "not chosen" and follow the template instead.
function _legend_resolve_colors(p::Plot, bgcolor, bordercolor, borderwidth)
	if bgcolor == _DEFAULT_LEGEND_BGCOLOR[] &&
		bordercolor == _DEFAULT_LEGEND_BORDERCOLOR[] &&
		borderwidth == _DEFAULT_LEGEND_BORDERWIDTH[]
		return _legend_default_colors(p)
	end
	return (bgcolor = String(bgcolor), bordercolor = String(bordercolor), borderwidth = Float64(borderwidth))
end

const _LEGEND_FRAMELESS_COLORS = (
	bgcolor = "rgba(0,0,0,0)",
	bordercolor = "rgba(0,0,0,0)",
	borderwidth = 0.0,
)

# Box colours one `set_legend!` call writes (always with replace semantics):
# `frame=false` gives a transparent borderless box; otherwise the explicit
# colours, completed with `defaults` when the box is new or `frame=true`
# (existing colours are kept for keys the call does not mention).
function _legend_call_colors(opts, defaults, block_exists::Bool)
	opts.frame === false && return _LEGEND_FRAMELESS_COLORS
	d = Dict{Symbol, Any}()
	if !block_exists || opts.frame === true
		d[:bgcolor] = defaults.bgcolor
		d[:bordercolor] = defaults.bordercolor
		d[:borderwidth] = defaults.borderwidth
	end
	opts.bgcolor === nothing || (d[:bgcolor] = opts.bgcolor)
	opts.bordercolor === nothing || (d[:bordercolor] = opts.bordercolor)
	opts.borderwidth === nothing || (d[:borderwidth] = opts.borderwidth)
	return d
end

_legend_anchors_given(opts) = !isempty(opts.xanchor) || !isempty(opts.yanchor)

function _legend_anchor_fields(opts)
	d = Dict{Symbol, Any}()
	isempty(opts.xanchor) || (d[:xanchor] = opts.xanchor)
	isempty(opts.yanchor) || (d[:yanchor] = opts.yanchor)
	return d
end

# Visible-legend flag after a legend pass: an explicit choice wins; otherwise
# `true` once any trace shows an entry (written only when unset unless
# `replace`, so a `relayout!(fig; showlegend=false)` survives later appends).
function _legend_set_showlegend!(p::Plot, showlegend, replace::Bool)
	if showlegend isa Bool
		p.layout.fields[:showlegend] = showlegend
	elseif any(trace -> trace isa GenericTrace && _trace_will_showlegend(trace), p.data)
		replace ? (p.layout.fields[:showlegend] = true) : get!(p.layout.fields, :showlegend, true)
	end
	return nothing
end

# ── Figure title above a top legend ──────────────────────────────────────────

# Smallest gap (px) between a figure title and a legend placed above the axes.
const _LEGEND_TITLE_GAP = 10
# plotly.js `layout.margin.t` default (px), used when neither the layout nor
# its template sets one.
const _PLOTLY_DEFAULT_MARGIN_T = 100
# plotly.js default size of the root font (px) and the title-font factor
# (`title.font.size` defaults to `round(1.4 × font.size)`).
const _PLOTLY_DEFAULT_FONT_SIZE = 12
const _PLOTLY_TITLE_FONT_FACTOR = 1.4

# A legend box drawn above the plot area: paper-referenced, `y ≥ 1` and
# anchored at its bottom edge (plotly pushes the top margin for it).
function _legend_box_above_plot(block)
	block === nothing && return false
	d = _symbol_dict(block)
	get(d, :visible, true) === false && return false
	get(d, :yref, "paper") == "paper" || return false
	y = get(d, :y, nothing)
	(y isa Real && y >= 1) || return false
	return get(d, :yanchor, nothing) == "bottom"
end

function _legend_has_box_above_plot(p::Plot)
	get(p.layout.fields, :showlegend, nothing) === false && return false
	ids = Set{String}()
	for trace in p.data
		trace isa GenericTrace && _trace_will_showlegend(trace) || continue
		push!(ids, _legend_trace_legend_id(trace))
	end
	return any(id -> _legend_box_above_plot(get(p.layout.fields, Symbol(id), nothing)), ids)
end

_legend_real(x) = (x isa Real && !(x isa Bool) && isfinite(x)) ? Float64(x) : nothing

function _legend_template_layout_value(p::Plot, path::Tuple)
	t = _legend_layout_template(p)
	t === nothing && return nothing
	value = _template_layout_fields(t)
	for key in path
		d = _symbol_dict(value)
		haskey(d, key) || return nothing
		value = d[key]
	end
	return value
end

# The top margin (px) and the title font size (px) plotly.js will use.
function _legend_top_margin(p::Plot)
	m = _legend_real(get(_symbol_dict(get(p.layout.fields, :margin, nothing)), :t, nothing))
	m === nothing && (m = _legend_real(_legend_template_layout_value(p, (:margin, :t))))
	return something(m, Float64(_PLOTLY_DEFAULT_MARGIN_T))
end

function _legend_title_font_size(p::Plot, title::AbstractDict)
	s = _legend_real(get(_symbol_dict(get(title, :font, nothing)), :size, nothing))
	s === nothing || return s
	s = _legend_real(_legend_template_layout_value(p, (:title, :font, :size)))
	s === nothing || return s
	root = _legend_real(get(_symbol_dict(get(p.layout.fields, :font, nothing)), :size, nothing))
	root === nothing && (root = _legend_real(_legend_template_layout_value(p, (:font, :size))))
	return round(_PLOTLY_TITLE_FONT_FACTOR * something(root, Float64(_PLOTLY_DEFAULT_FONT_SIZE)))
end

"""
	_legend_title_clearance(p, title) -> Union{Nothing, Dict{Symbol,Any}}

The fields of `title` (a `layout.title` value) that keep a figure title clear
of a legend drawn above the plot area, or `nothing` when nothing changes.

plotly.js 2.35.2 (`plots.doAutoMargin`) grows the top margin to the *largest*
of its pushers, so a title and a legend that both push it overlap. A
container-referenced title with `automargin=true` whose band (`pad.t` + text
height + `pad.b`) exceeds `margin.t` instead *reserves* that band, and the
pushers are laid out below it. The title is therefore given `automargin=true`,
`pad.t` = 10 px when it has none, and a `pad.b` (the gap between the title and
the legend) large enough for its band to exceed `margin.t` — measured with the
font size as a lower bound of the text height (half of it for MathJax titles).
Paper-referenced titles and titles with an explicit bottom/middle anchor or a
`y` in the lower half are left as they are. `pad.b` is never reduced.
"""
function _legend_title_clearance(p::Plot, title)
	d = title isa AbstractString ? Dict{Symbol, Any}(:text => String(title)) : _symbol_dict(title)
	text = get(d, :text, nothing)
	(text isa AbstractString && !isempty(strip(text))) || return nothing
	get(d, :yref, "container") == "container" || return nothing
	y = get(d, :y, "auto")
	(y == "auto" || (_legend_real(y) !== nothing && y > 0.5)) || return nothing
	get(d, :yanchor, "auto") in ("auto", "top") || return nothing

	pad = _symbol_dict(get(d, :pad, nothing))
	pad_t = _legend_real(get(pad, :t, nothing))
	if pad_t === nothing
		pad_t = Float64(_TEXT_TITLE_TOP_PAD)
		pad[:t] = _TEXT_TITLE_TOP_PAD
	end
	font_size = _legend_title_font_size(p, d)
	# Lower bound of the drawn text height: one line of text is at least as
	# tall as its font size; a MathJax expression can be shorter (e.g. `$x$`).
	text_floor = occursin('$', text) ? font_size / 2 : font_size
	needed = max(Float64(_LEGEND_TITLE_GAP), ceil(_legend_top_margin(p) - pad_t - text_floor + 1))
	pad_b = _legend_real(get(pad, :b, nothing))
	changed = get(d, :automargin, nothing) !== true || !haskey(d, :pad) ||
		pad_b === nothing || pad_b < needed || !(title isa AbstractDict || title isa PlotlyBase.PlotlyAttribute)
	(pad_b === nothing || pad_b < needed) && (pad[:b] = _text_number(needed))
	changed || return nothing
	d[:automargin] = true
	d[:pad] = attr(; pad...)
	return d
end

# Apply `_legend_title_clearance` to the figure title of `p` when a legend is
# drawn above the plot area (audit: an `:outside_top` legend overlapped the title).
function _legend_title_clearance!(p::Plot)
	_legend_has_box_above_plot(p) || return nothing
	title = get(p.layout.fields, :title, nothing)
	title === nothing && return nothing
	d = _legend_title_clearance(p, title)
	d === nothing || (p.layout.fields[:title] = attr(; d...))
	return nothing
end

# ── Deduplication (F15 `dedupe`) ──────────────────────────────────────────────

function _legend_canonical(x)
	if x isa PlotlyBase.PlotlyAttribute
		return _legend_canonical(x.fields)
	elseif x isa AbstractDict
		pairs_sorted = sort!([string(k) => _legend_canonical(v) for (k, v) in x]; by = first)
		return Tuple(pairs_sorted)
	elseif x isa AbstractArray
		return Any[_legend_canonical(v) for v in x]
	elseif x isa Symbol
		return String(x)
	end
	return x
end

function _legend_group_for_signature(trace::GenericTrace)
	group = get(trace.fields, :legendgroup, "")
	group isa AbstractString || return _legend_canonical(group)
	return startswith(group, _LEGEND_DEDUPE_GROUP_PREFIX) ? "" : String(group)
end

function _legend_has_explicit_color(trace::GenericTrace)
	fields = trace.fields
	haskey(fields, :fillcolor) && return true
	for key in (:line, :marker)
		value = get(fields, key, nothing)
		value === nothing && continue
		_cmn_mapping_get(value, :color) === nothing || return true
	end
	return false
end

# What a legend entry looks like: same type, name, mode, line/marker/fill
# styling, opacity and (user) legend group. Traces that set no colour get
# plotly's colorway colour by position, which is part of their look.
function _legend_style_signature(p::Plot, index::Int, trace::GenericTrace)
	fields = trace.fields
	sig = Any[
		string(get(fields, :type, "scatter")),
		_legend_canonical(get(fields, :name, nothing)),
		_legend_canonical(get(fields, :mode, nothing)),
		_legend_canonical(get(fields, :line, nothing)),
		_legend_canonical(get(fields, :marker, nothing)),
		_legend_canonical(get(fields, :fill, nothing)),
		_legend_canonical(get(fields, :fillcolor, nothing)),
		_legend_canonical(get(fields, :fillpattern, nothing)),
		_legend_canonical(get(fields, :opacity, nothing)),
		_legend_group_for_signature(trace),
	]
	_legend_has_explicit_color(trace) || push!(sig, _default_trace_color(p, index))
	return Tuple(sig)
end

# Trace indices (1-based) sharing one legend entry, per legend id; only groups
# with more than one trace are returned, members in trace order.
function _legend_dedupe_groups(p::Plot; legend_ids = nothing)
	groups = Dict{Any, Vector{Int}}()
	order = Any[]
	for (index, trace) in enumerate(p.data)
		trace isa GenericTrace || continue
		_trace_has_slice_legend(trace) && continue
		(_trace_has_legend_label(trace) && _trace_will_showlegend(trace)) || continue
		legend_id = _legend_trace_legend_id(trace)
		legend_ids === nothing || legend_id in legend_ids || continue
		key = (legend_id, _legend_style_signature(p, index, trace))
		members = get!(groups, key) do
			push!(order, key)
			Int[]
		end
		push!(members, index)
	end
	return [groups[key] for key in order if length(groups[key]) > 1]
end

"""
	_legend_dedupe!(p; legend_ids = nothing) -> Bool

Merge legend entries that look identical (same name and style, see
`_legend_style_signature`) within each legend: all members join one
`legendgroup` (the first member's own group, else a generated one) so a click
toggles them together, and only the first keeps `showlegend`. When a legend
had no user legend groups, its `traceorder` is pinned to "normal" so the new
groups do not switch plotly to grouped spacing. Returns whether anything changed.
"""
function _legend_dedupe!(p::Plot; legend_ids = nothing)
	groups = _legend_dedupe_groups(p; legend_ids = legend_ids)
	isempty(groups) && return false
	touched = Set{String}()
	for members in groups
		first_trace = p.data[members[1]]
		legend_id = _legend_trace_legend_id(first_trace)
		group = get(first_trace.fields, :legendgroup, "")
		if !(group isa AbstractString) || isempty(group)
			group = _LEGEND_DEDUPE_GROUP_PREFIX * legend_id * ":" * string(members[1])
		end
		for (k, index) in enumerate(members)
			trace = p.data[index]
			trace.fields[:legendgroup] = group
			k > 1 && (trace.fields[:showlegend] = false)
		end
		push!(touched, legend_id)
	end
	for legend_id in touched
		user_groups = any(p.data) do trace
			trace isa GenericTrace || return false
			_legend_trace_legend_id(trace) == legend_id || return false
			group = get(trace.fields, :legendgroup, "")
			return group isa AbstractString && !isempty(group) &&
				!startswith(group, _LEGEND_DEDUPE_GROUP_PREFIX)
		end
		user_groups && continue
		key = Symbol(legend_id)
		d = _symbol_dict(get(p.layout.fields, key, nothing))
		haskey(d, :traceorder) && continue
		d[:traceorder] = "normal"
		p.layout.fields[key] = attr(; d...)
	end
	return true
end

# Split the entries `_legend_dedupe!` merged (its generated groups only; user
# legend groups are untouched). Used when a SubplotFigure switches between one
# figure legend and per-cell legends: entries merged across cells must be listed
# again in their own cell legend (and vice versa); the new mode re-deduplicates.
function _legend_undo_dedupe!(p::Plot)
	for trace in p.data
		trace isa GenericTrace || continue
		group = get(trace.fields, :legendgroup, nothing)
		(group isa AbstractString && startswith(group, _LEGEND_DEDUPE_GROUP_PREFIX)) || continue
		delete!(trace.fields, :legendgroup)
		get(trace.fields, :showlegend, nothing) === false && delete!(trace.fields, :showlegend)
	end
	return nothing
end

# ── Per-subplot legends ──────────────────────────────────────────────────────

# Pure: cell legend assignment of `p` — keys in first-appearance order, the
# legend index of each key and its paper domain. Figure-legend entries
# (`_FIGURE_LEGEND_META`) are not cell entries.
function _legend_subplot_assignment(p::Plot)
	order = String[]
	ids = Dict{String, Int}()
	domains = Dict{String, Tuple{Tuple{Float64, Float64}, Tuple{Float64, Float64}}}()
	trace_keys = Vector{Union{Nothing, String}}(nothing, length(p.data))
	for (index, trace) in enumerate(p.data)
		trace isa GenericTrace || continue
		_trace_is_figure_legend_entry(trace) && continue
		key_domain = _trace_subplot_key_domain(p, trace)
		key_domain === nothing && continue
		key, domain = key_domain
		trace_keys[index] = key
		haskey(ids, key) && continue
		push!(order, key)
		ids[key] = length(order)
		domains[key] = domain
		length(order) < _FIGURE_LEGEND_INDEX || throw(ArgumentError(
			"subplot legends: at most $(_FIGURE_LEGEND_INDEX - 1) cell legends " *
			"are supported; this figure needs more (use one figure legend: " *
			"`set_legend!(sf; legend_target=:figure)`).",
		))
	end
	return order, ids, domains, trace_keys
end

"""
	_apply_subplot_legends!(p; legend_position, legend_inset, legend_bgcolor, legend_bordercolor, legend_borderwidth, overwrite=false, replace_placement=overwrite, replace_colors=overwrite, fresh=false, xanchor="", yanchor="", ext_opts=nothing)

Give every subplot of `p` its own legend box (`legend`, `legend2`, … in order
of first appearance) inside its domain. Secondary/overlaying axes share their
base cell's legend; figure-legend proxies go to the reserved figure legend.
Traces without `showlegend` get it from `_trace_will_showlegend`. Existing
boxes keep their placement and colours unless `replace_placement` /
`replace_colors` (so `relayout!` customisations survive later appends); a box
is also rebuilt when its id now belongs to traces that had another id (the
ids were renumbered, e.g. after `deletetraces!`) or to traces that had none
(a new cell). `fresh` rebuilds every box from scratch. `ext_opts` are
validated `_legend_options` whose F15 fields (`_legend_layout_ext`) are
written into every box, with `ncols` scaled to the width of each cell.
"""
function _apply_subplot_legends!(
	p::Plot;
	legend_position::Union{Symbol, Tuple{Float64, Float64}},
	legend_inset::Tuple{Float64, Float64},
	legend_bgcolor::AbstractString,
	legend_bordercolor::AbstractString,
	legend_borderwidth::Real,
	overwrite::Bool = false,
	replace_placement::Bool = overwrite,
	replace_colors::Bool = overwrite,
	fresh::Bool = false,
	xanchor::AbstractString = "",
	yanchor::AbstractString = "",
	ext_opts = nothing,
)
	order, ids, domains, trace_keys = _legend_subplot_assignment(p)

	# Legend ids whose traces already carried exactly that id (`kept`) or a
	# different one (`moved`), to tell a box that still belongs to its cell
	# from one whose id was handed to another cell.
	kept = Set{String}()
	moved = Set{String}()
	has_figure_entries = false
	for (index, trace) in enumerate(p.data)
		trace isa GenericTrace || continue
		if _trace_is_figure_legend_entry(trace)
			has_figure_entries = true
			trace.fields[:legend] = _FIGURE_LEGEND_ID
		else
			key = trace_keys[index]
			key === nothing && continue
			new_id = _legend_id(ids[key])
			old_id = get(trace.fields, :legend, nothing)
			if old_id !== nothing
				string(old_id) == new_id ? push!(kept, new_id) : push!(moved, new_id)
			end
			trace.fields[:legend] = new_id
		end
		if !haskey(trace.fields, :showlegend)
			trace.fields[:showlegend] =
				_trace_will_showlegend(trace)
		end
	end

	colors = _legend_resolve_colors(p, legend_bgcolor, legend_bordercolor, legend_borderwidth)
	for key in order
		xdom, ydom = domains[key]
		legend_id = _legend_id(ids[key])
		reassigned = legend_id in moved || !(legend_id in kept)
		placement = _legend_placement(
			legend_position,
			xdom,
			ydom,
			legend_inset;
			figure = false,
			xanchor = xanchor,
			yanchor = yanchor,
		)
		_legend_write_block!(
			p,
			_legend_symbol(ids[key]);
			placement = placement,
			colors = colors,
			ext = ext_opts === nothing ? nothing :
				_legend_layout_ext(ext_opts; span = xdom[2] - xdom[1]),
			replace_placement = replace_placement || reassigned,
			replace_colors = replace_colors || reassigned,
			fresh = fresh,
		)
	end
	figure_key = Symbol(_FIGURE_LEGEND_ID)
	if has_figure_entries && !haskey(p.layout.fields, figure_key)
		# A figure legend nobody placed yet goes below the plot area.
		_legend_write_block!(
			p,
			figure_key;
			placement = _legend_placement(:outside_bottom, (0.0, 1.0), (0.0, 1.0), legend_inset; figure = true),
			colors = colors,
		)
	end
	_legend_set_showlegend!(p, nothing, overwrite)
	_legend_title_clearance!(p)

	return p
end

"""
	_apply_figure_legend!(p; position, inset, bgcolor, bordercolor, borderwidth, first_new=1, move_all=false, ...)

One figure-level legend (`layout.legend`) for every trace of `p`, placed
relative to the whole figure (outside positions use container anchoring).
Only traces from index `first_new` on get a `showlegend` default, so the
append-only fast path can call it; `move_all=true` (explicit `set_legend!`)
also moves every trace into "legend". Box semantics as `_legend_write_block!`.
"""
function _apply_figure_legend!(
	p::Plot;
	position::Union{Symbol, Tuple{Float64, Float64}},
	inset::Tuple{Float64, Float64},
	bgcolor::AbstractString,
	bordercolor::AbstractString,
	borderwidth::Real,
	first_new::Integer = 1,
	move_all::Bool = false,
	replace_placement::Bool = false,
	replace_colors::Bool = false,
	fresh::Bool = false,
	xanchor::AbstractString = "",
	yanchor::AbstractString = "",
	ext = nothing,
	explicit::Bool = false,
)
	start = move_all ? 1 : max(Int(first_new), 1)
	for index in start:length(p.data)
		trace = p.data[index]
		trace isa GenericTrace || continue
		move_all && delete!(trace.fields, :legend)
		if !haskey(trace.fields, :showlegend)
			trace.fields[:showlegend] = _trace_will_showlegend(trace)
		end
	end
	will_show = any(trace -> trace isa GenericTrace && _trace_will_showlegend(trace), p.data)
	if explicit || haskey(p.layout.fields, :legend) || will_show
		placement = _legend_placement(
			position,
			(0.0, 1.0),
			(0.0, 1.0),
			inset;
			figure = true,
			xanchor = xanchor,
			yanchor = yanchor,
		)
		_legend_write_block!(
			p,
			:legend;
			placement = placement,
			colors = _legend_resolve_colors(p, bgcolor, bordercolor, borderwidth),
			ext = ext,
			replace_placement = replace_placement,
			replace_colors = replace_colors,
			fresh = fresh,
		)
	end
	_legend_set_showlegend!(p, nothing, explicit)
	_legend_title_clearance!(p)
	return p
end

"""
	_refresh_subplot_legends!(sf, p = sf's Plot; first_new = 1)

Legend pass after traces were appended to a SubplotFigure: per-subplot
legends when `sf.per_subplot_legends`, otherwise the figure legend with the
stored `sf.legend_*` settings. Existing boxes keep their placement/colours;
in figure mode only traces from `first_new` on are touched, so it is safe on
the append-only fast transaction path.
"""
function _refresh_subplot_legends!(
	sf::SubplotFigure,
	p::Plot = _plot_obj(getfield(sf, :fig));
	first_new::Integer = 1,
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
	else
		_apply_figure_legend!(
			p;
			position = sf.legend_position,
			inset = sf.legend_inset,
			bgcolor = sf.legend_bgcolor,
			bordercolor = sf.legend_bordercolor,
			borderwidth = sf.legend_borderwidth,
			first_new = first_new,
		)
	end
	return p
end

"""
	_apply_default_legend!(fig; position=nothing, inset=nothing, bgcolor=nothing, bordercolor=nothing, borderwidth=nothing, overwrite=false, showlegend=nothing)

Legend pass of the constructors and `plot_*!` mutators. Hides traces with a
blank name (C12), then writes the styled legend box when a legend will show
(or one exists / `overwrite`): position from `set_default_legend_position!`,
colours from the active style and the figure's template unless given. With
`overwrite=false` an existing box keeps its placement and colours.
"""
function _apply_default_legend!(
	fig;
	position::Union{Nothing, Symbol, AbstractString, Tuple{<:Real, <:Real}} = nothing,
	inset::Union{Nothing, Tuple{<:Real, <:Real}} = nothing,
	bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	borderwidth::Union{Nothing, Real} = nothing,
	overwrite::Bool = false,
	showlegend::Union{Nothing, Bool} = nothing,
)
	p = _plot_obj(fig)
	legend_position = position === nothing ? _DEFAULT_LEGEND_POSITION[] :
		position isa Tuple ? (Float64(position[1]), Float64(position[2])) :
		_normalize_legend_position(position)
	legend_inset = inset === nothing ? _DEFAULT_LEGEND_INSET[] :
		(Float64(inset[1]), Float64(inset[2]))
	_legend_hide_unnamed!(p)

	# Only write a styled legend block when a legend will actually show (a trace
	# with a name/showlegend), one already exists, or the caller forces it
	# (`overwrite=true`). This keeps empty canvases and unnamed single-trace
	# figures free of stray legend layout.
	if overwrite || haskey(p.layout.fields, :legend) ||
		any(trace -> trace isa GenericTrace && _trace_will_showlegend(trace), p.data)
		defaults = _legend_default_colors(p)
		colors = (
			bgcolor = bgcolor === nothing ? defaults.bgcolor : String(bgcolor),
			bordercolor = bordercolor === nothing ? defaults.bordercolor : String(bordercolor),
			borderwidth = borderwidth === nothing ? defaults.borderwidth : Float64(borderwidth),
		)
		_legend_write_block!(
			p,
			:legend;
			placement = _legend_placement(legend_position, (0.0, 1.0), (0.0, 1.0), legend_inset; figure = true),
			colors = colors,
			replace_placement = overwrite,
			replace_colors = overwrite,
		)
	end
	if showlegend isa Bool
		# Explicit caller override (e.g. force a legend for a single unnamed trace).
		p.layout.fields[:showlegend] = showlegend
	elseif !haskey(p.layout.fields, :showlegend) &&
		any(trace -> trace isa GenericTrace && _trace_will_showlegend(trace), p.data)
		p.layout.fields[:showlegend] = true
	end
	_legend_title_clearance!(p)
	return p
end

# ── set_legend! on Plot / SyncPlot ───────────────────────────────────────────

# The single legend of a Plot/SyncPlot. `traces=false` is the registered
# layout-only fast path (`_set_legend_impl!`); `traces=true` also hides blank
# names and deduplicates, which rewrites existing traces and therefore runs on
# the full (trace-cloning) transaction path.
function _legend_apply_plot!(fig, opts; traces::Bool)
	p = _plot_obj(fig)
	traces && _legend_hide_unnamed!(p)
	exists = haskey(p.layout.fields, :legend)
	existing = _symbol_dict(get(p.layout.fields, :legend, nothing))
	placed = haskey(existing, :x) || haskey(existing, :y)
	# No `position`: keep the current placement, unless there is none yet or an
	# `inset` asks for a re-placement (then the package default position, as in 1.x).
	position = opts.position !== nothing ? opts.position :
		(!placed || opts.inset_given) ? _DEFAULT_LEGEND_POSITION[] : nothing
	placement, replace = if position !== nothing
		(_legend_placement(
			position,
			(0.0, 1.0),
			(0.0, 1.0),
			opts.inset;
			figure = true,
			xanchor = opts.xanchor,
			yanchor = opts.yanchor,
		), true)
	elseif _legend_anchors_given(opts)
		(_legend_anchor_fields(opts), false)
	else
		(nothing, false)
	end
	if placement !== nothing && !replace
		# Anchors only: keep x/y and the rest of the placement.
		merge!(existing, placement)
		p.layout.fields[:legend] = attr(; existing...)
		placement = nothing
	end
	_legend_write_block!(
		p,
		:legend;
		placement = placement,
		colors = _legend_call_colors(opts, _legend_default_colors(p), exists),
		ext = _legend_layout_ext(opts),
		replace_placement = true,
		replace_colors = true,
	)
	traces && opts.dedupe && _legend_dedupe!(p)
	_legend_set_showlegend!(p, opts.showlegend, false)
	_legend_title_clearance!(p)
	_refresh!(fig)
	return fig
end

# Registered with the transactional fast path (`_transactional_high_level_plot_mutation!`):
# it only touches the layout.
_set_legend_impl!(fig; options) = _legend_apply_plot!(fig, options; traces = false)
# Not registered: always the full transaction path.
_set_legend_traces_impl!(fig; options) = _legend_apply_plot!(fig, options; traces = true)

"""
	set_legend!(fig; position=nothing, inset=nothing, bgcolor=nothing, bordercolor=nothing, borderwidth=nothing, showlegend=nothing, xanchor="", yanchor="", orientation=nothing, ncols=0, title="", fontsize=0, frame=nothing, dedupe=true, itemwidth=0, entrywidth=0, legend_target=nothing, row=nothing, col=nothing)

Place and style the legend of a `Plot`, [`SyncPlot`](@ref) or
[`SubplotFigure`](@ref). Keywords left at their defaults leave the
corresponding setting unchanged, so `set_legend!(fig; ncols=3)` keeps the
current position.

# Placement
- `position`: a `Symbol`/string — `:topright`, `:top`, `:topleft`, `:right`,
  `:center`, `:left`, `:bottomright`, `:bottom`, `:bottomleft` (inside the
  axes), or `:outside_right`, `:outside_left`, `:outside_top`,
  `:outside_bottom` (outside; hyphen/space/alias forms such as `"top-left"`,
  `"upper right"`, `:outside` are accepted, an unknown value warns and falls
  back to `:topright`) — or an `(fx, fy)` tuple (or 2-vector) of axes
  fractions, which may lie outside `[0, 1]` (`(1.02, 1)` is just right of the
  top-right corner). `nothing` keeps the current placement (a figure without a
  legend box gets `get_default_legend_position()`).
  - `:outside_bottom` is anchored to the bottom of the figure container and
    `:outside_left` to its left edge (Plotly reserves a margin, so the legend
    never covers tick labels or axis titles); `:outside_top` sits above the
    plot area and `:outside_right` right of it. Outside top/bottom legends are
    horizontal unless `orientation` says otherwise.
  - Tuple positions anchor the legend box on the axes side of the point:
    `fx > 1` → `xanchor="left"`, `fx < 0` → `"right"`, inside the nearest third.
- `inset::Tuple{Real,Real}` (or 2-vector): `(x, y)` padding from the axes
  edges as fractions of the axes (default `(0.02, 0.03)`; values above 0.49
  are clamped). Outside positions use it as a fixed paper offset.
- `xanchor`, `yanchor` (`""` = computed): `"left"|"center"|"right"|"auto"` and
  `"top"|"middle"|"bottom"|"auto"`; given without `position` they replace only
  the anchors.

# Appearance
- `orientation`: `:v`/`:h` (or `"v"`/`"h"`, `:vertical`/`:horizontal`);
  `nothing` = horizontal for outside top/bottom and when `ncols > 0`, else vertical.
- `ncols::Integer = 0`: number of columns of a horizontal legend (sets
  `entrywidth = 1/ncols` with `entrywidthmode = "fraction"`).
- `entrywidth::Real = 0`: width of each entry in px (`entrywidthmode = "pixels"`);
  cannot be combined with `ncols`.
- `itemwidth::Real = 0`: width of the symbol part of each entry in px
  (Plotly requires at least 30).
- `title::AbstractString = ""`: legend title (mathtext allowed, through `_label`).
- `fontsize::Real = 0`: entry font size in px (0 = unchanged).
- `frame`: `false` = transparent, borderless box; `true` = restore the default
  box (template/style colours); `nothing` = unchanged.
- `bgcolor`, `bordercolor` (string or Symbol), `borderwidth::Real`: explicit
  box styling (incompatible with `frame=false`). Defaults follow the active
  [`PlotStyle`](@ref) and the figure's template (a dark template gets a dark box).
- `showlegend::Union{Nothing,Bool}`: force the legend on (`true`, e.g. for a
  single named trace that Plotly would not list) or off (`false`). Traces with
  a blank name never get an entry (they are hidden automatically).
- `dedupe::Bool = true`: entries with the same name and identical style
  (same line/marker/fill, same colour) in one legend are merged: they join one
  `legendgroup` (clicking toggles all of them) and only the first is listed.
  Applies to the traces present when `set_legend!` runs; `false` leaves entries
  as they are.

# SubplotFigure
- `row`, `col`: place only that cell's legend (per-subplot legends must be on,
  and the cell needs at least one entry). Symbol and tuple positions are
  relative to the cell's axes.
- `legend_target`: `:cell` places every cell's own legend (and turns
  per-subplot legends on); `:figure` places the figure-level legend. Without
  it, an outside position merges all entries into **one figure legend** (cell
  legends are switched off and identical entries from different cells are
  deduplicated), other positions apply to the current mode. With per-subplot
  legends on, `legend_target=:figure` places only the figure legend that holds
  `legend_entry!(…; legend_target=:figure)` proxies, next to the cell legends.
- Stored settings (`sf.legend_position`, `sf.legend_inset`, colours) are updated
  and used for cells that get traces later.

Returns `fig` (the `SubplotFigure` for one). Invalid values throw an
`ArgumentError` before anything is changed.

# Example
```julia
fig = plot_scatter(1:10, [rand(10), rand(10)]; legend = ["model", "data"])
set_legend!(fig; position = :outside_bottom, ncols = 2, frame = false)

sf = subplots(1, 3; sync = false)
for c in 1:3
	plot_scatter!(sf, 1:5, rand(5); legend = "measured", color = "black", row = 1, col = c)
end
set_legend!(sf; position = :outside_bottom, ncols = 3)   # one legend, one "measured" entry
```
"""
function set_legend!(
	fig::Union{Plot, SyncPlot};
	position::Union{Nothing, Symbol, AbstractString, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	inset::Union{Nothing, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	borderwidth::Union{Nothing, Real} = nothing,
	showlegend::Union{Nothing, Bool} = nothing,
	xanchor::Union{AbstractString, Symbol} = "",
	yanchor::Union{AbstractString, Symbol} = "",
	orientation::Union{Nothing, Symbol, AbstractString} = nothing,
	ncols::Real = 0,
	title::AbstractString = "",
	fontsize::Real = 0,
	frame::Union{Nothing, Bool} = nothing,
	dedupe::Bool = true,
	itemwidth::Real = 0,
	entrywidth::Real = 0,
	legend_target::Union{Nothing, Symbol} = nothing,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	(row === nothing && col === nothing) || throw(ArgumentError(
		"set_legend!: `row`/`col` select a SubplotFigure cell; a Plot/SyncPlot " *
		"has a single legend, so omit them.",
	))
	options = _legend_options(
		"set_legend!";
		position, inset, bgcolor, bordercolor, borderwidth, showlegend,
		xanchor, yanchor, orientation, ncols, title, fontsize, frame, dedupe,
		itemwidth, entrywidth, legend_target,
	)
	p = _plot_obj(fig)
	needs_trace_edits =
		any(_legend_hides_unnamed, p.data) ||
		(options.dedupe && !isempty(_legend_dedupe_groups(p)))
	return _transactional_high_level_plot_mutation!(
		needs_trace_edits ? _set_legend_traces_impl! : _set_legend_impl!,
		fig;
		options = options,
	)
end

# ── set_legend! / subplot_legends! on SubplotFigure ──────────────────────────

const _SUBPLOT_LEGEND_MODE_METADATA_FIELDS = (
	_SUBPLOT_LEGEND_METADATA_FIELDS...,
	:per_subplot_legends,
)

# Store the explicit choices of one call on the SubplotFigure, so cells that
# get traces later follow them.
function _legend_store_settings!(sf::SubplotFigure, opts)
	opts.position isa Symbol && (sf.legend_position = opts.position)
	opts.inset_given && (sf.legend_inset = opts.inset)
	if opts.frame === false
		sf.legend_bgcolor = _LEGEND_FRAMELESS_COLORS.bgcolor
		sf.legend_bordercolor = _LEGEND_FRAMELESS_COLORS.bordercolor
		sf.legend_borderwidth = _LEGEND_FRAMELESS_COLORS.borderwidth
	elseif opts.frame === true
		# Back to "not chosen": the template/style default box.
		sf.legend_bgcolor = _DEFAULT_LEGEND_BGCOLOR[]
		sf.legend_bordercolor = _DEFAULT_LEGEND_BORDERCOLOR[]
		sf.legend_borderwidth = _DEFAULT_LEGEND_BORDERWIDTH[]
	end
	opts.bgcolor === nothing || (sf.legend_bgcolor = opts.bgcolor)
	opts.bordercolor === nothing || (sf.legend_bordercolor = opts.bordercolor)
	opts.borderwidth === nothing || (sf.legend_borderwidth = opts.borderwidth)
	return nothing
end

_legend_colors_given(opts) =
	opts.frame !== nothing || opts.bgcolor !== nothing ||
	opts.bordercolor !== nothing || opts.borderwidth !== nothing

_legend_placement_given(opts) =
	opts.position !== nothing || opts.inset_given || _legend_anchors_given(opts)

function _legend_set_cell_mode!(sf::SubplotFigure, p::Plot, opts)
	was_per = sf.per_subplot_legends
	sf.per_subplot_legends = true
	_legend_store_settings!(sf, opts)
	position = opts.position === nothing ? sf.legend_position : opts.position
	was_per || _legend_undo_dedupe!(p)
	_apply_subplot_legends!(
		p;
		legend_position = position,
		legend_inset = sf.legend_inset,
		legend_bgcolor = sf.legend_bgcolor,
		legend_bordercolor = sf.legend_bordercolor,
		legend_borderwidth = sf.legend_borderwidth,
		overwrite = true,
		replace_placement = !was_per || _legend_placement_given(opts),
		replace_colors = !was_per || _legend_colors_given(opts),
		fresh = !was_per,
		xanchor = opts.xanchor,
		yanchor = opts.yanchor,
		ext_opts = opts,
	)
	opts.dedupe && _legend_dedupe!(p)
	opts.showlegend === nothing || (p.layout.fields[:showlegend] = opts.showlegend)
	return nothing
end

function _legend_set_figure_mode!(sf::SubplotFigure, p::Plot, opts)
	was_per = sf.per_subplot_legends
	sf.per_subplot_legends = false
	_legend_store_settings!(sf, opts)
	position = opts.position === nothing ? sf.legend_position : opts.position
	if was_per
		# Cell boxes (and a figure-entry box) are no longer referenced.
		for key in collect(keys(p.layout.fields))
			occursin(_LEGEND_ID_PATTERN, String(key)) && delete!(p.layout.fields, key)
		end
		_legend_undo_dedupe!(p)
	end
	_apply_figure_legend!(
		p;
		position = position,
		inset = sf.legend_inset,
		bgcolor = sf.legend_bgcolor,
		bordercolor = sf.legend_bordercolor,
		borderwidth = sf.legend_borderwidth,
		move_all = true,
		replace_placement = was_per || _legend_placement_given(opts),
		replace_colors = was_per || _legend_colors_given(opts),
		fresh = was_per,
		xanchor = opts.xanchor,
		yanchor = opts.yanchor,
		ext = _legend_layout_ext(opts),
		explicit = true,
	)
	opts.dedupe && _legend_dedupe!(p; legend_ids = ("legend",))
	opts.showlegend === nothing || (p.layout.fields[:showlegend] = opts.showlegend)
	return nothing
end

# Per-subplot mode, `legend_target=:figure`: the box of the figure legend that
# holds `legend_entry!(…; legend_target=:figure)` proxies; cell legends and the
# stored cell settings are untouched.
function _legend_set_figure_entry_legend!(sf::SubplotFigure, p::Plot, opts)
	key = Symbol(_FIGURE_LEGEND_ID)
	exists = haskey(p.layout.fields, key)
	# A new box, or an `inset` without a `position`, uses this legend's
	# default place below the plot area.
	position = opts.position !== nothing ? opts.position :
		(!exists || opts.inset_given) ? :outside_bottom : nothing
	if position === nothing && _legend_anchors_given(opts)
		d = _symbol_dict(get(p.layout.fields, key, nothing))
		merge!(d, _legend_anchor_fields(opts))
		p.layout.fields[key] = attr(; d...)
	end
	defaults = _legend_resolve_colors(p, sf.legend_bgcolor, sf.legend_bordercolor, sf.legend_borderwidth)
	_legend_write_block!(
		p,
		key;
		placement = position === nothing ? nothing : _legend_placement(
			position,
			(0.0, 1.0),
			(0.0, 1.0),
			opts.inset;
			figure = true,
			xanchor = opts.xanchor,
			yanchor = opts.yanchor,
		),
		colors = _legend_call_colors(opts, defaults, exists),
		ext = _legend_layout_ext(opts),
		replace_placement = true,
		replace_colors = true,
	)
	opts.dedupe && _legend_dedupe!(p; legend_ids = (_FIGURE_LEGEND_ID,))
	opts.showlegend === nothing || _legend_set_visible!(p, key, opts.showlegend)
	return nothing
end

function _legend_set_visible!(p::Plot, key::Symbol, visible::Bool)
	d = _symbol_dict(get(p.layout.fields, key, nothing))
	d[:visible] = visible
	p.layout.fields[key] = attr(; d...)
	return nothing
end

# Legend id of cell `target`'s own legend (matched on the cell's paper domain),
# or `nothing` when the cell has no legend entries yet.
function _legend_cell_legend_id(p::Plot, target)
	order, ids, domains, _ = _legend_subplot_assignment(p)
	for key in order
		xdom, ydom = domains[key]
		if isapprox(collect(xdom), collect(target.xdomain); atol = 1e-9) &&
			isapprox(collect(ydom), collect(target.ydomain); atol = 1e-9)
			return _legend_id(ids[key])
		end
	end
	return nothing
end

function _legend_set_cell!(sf::SubplotFigure, p::Plot, opts, row, col)
	opts.legend_target === :figure && throw(ArgumentError(
		"set_legend!: `legend_target=:figure` addresses the figure legend; " *
		"drop `row`/`col`.",
	))
	target = _cell_target(sf; row = row, col = col, who = "set_legend!")
	sf.per_subplot_legends || throw(ArgumentError(
		"set_legend!: per-cell legend placement (`row`/`col`) needs " *
		"per-subplot legends; this figure has one figure-level legend " *
		"(call `subplot_legends!(sf)` first).",
	))
	legend_id = _legend_cell_legend_id(p, target)
	legend_id === nothing && throw(ArgumentError(
		"set_legend!: cell ($(target.row), $(target.col)) has no legend " *
		"entries yet; add its traces (or `legend_entry!`) before placing its legend.",
	))
	# Assign ids / defaults first, so the cell box exists with the stored style.
	_refresh_subplot_legends!(sf, p)
	key = Symbol(legend_id)
	# An `inset` without a `position` re-places the box at the stored position.
	position = opts.position !== nothing ? opts.position :
		opts.inset_given ? sf.legend_position : nothing
	if position === nothing && _legend_anchors_given(opts)
		d = _symbol_dict(get(p.layout.fields, key, nothing))
		merge!(d, _legend_anchor_fields(opts))
		p.layout.fields[key] = attr(; d...)
	end
	defaults = _legend_resolve_colors(p, sf.legend_bgcolor, sf.legend_bordercolor, sf.legend_borderwidth)
	_legend_write_block!(
		p,
		key;
		placement = position === nothing ? nothing : _legend_placement(
			position,
			target.xdomain,
			target.ydomain,
			opts.inset;
			figure = false,
			xanchor = opts.xanchor,
			yanchor = opts.yanchor,
		),
		colors = _legend_call_colors(opts, defaults, true),
		ext = _legend_layout_ext(opts; span = target.xdomain[2] - target.xdomain[1]),
		replace_placement = true,
		replace_colors = true,
	)
	opts.dedupe && _legend_dedupe!(p; legend_ids = (legend_id,))
	opts.showlegend === nothing || _legend_set_visible!(p, key, opts.showlegend)
	return nothing
end

function _set_subplot_legend_impl!(
	sf::SubplotFigure;
	options,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	opts = options
	p = _plot_obj(sf.fig)
	if row !== nothing || col !== nothing
		_legend_set_cell!(sf, p, opts, row, col)
	else
		target = if opts.legend_target !== nothing
			opts.legend_target
		elseif opts.position isa Symbol && opts.position in _LEGEND_OUTSIDE_POSITIONS
			:figure
		else
			sf.per_subplot_legends ? :cell : :figure
		end
		if target === :cell
			_legend_set_cell_mode!(sf, p, opts)
		elseif sf.per_subplot_legends && opts.legend_target === :figure
			_legend_set_figure_entry_legend!(sf, p, opts)
		else
			_legend_set_figure_mode!(sf, p, opts)
		end
	end
	_legend_title_clearance!(p)
	_refresh!(sf.fig)
	return sf
end

function set_legend!(
	sf::SubplotFigure;
	position::Union{Nothing, Symbol, AbstractString, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	inset::Union{Nothing, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	borderwidth::Union{Nothing, Real} = nothing,
	showlegend::Union{Nothing, Bool} = nothing,
	xanchor::Union{AbstractString, Symbol} = "",
	yanchor::Union{AbstractString, Symbol} = "",
	orientation::Union{Nothing, Symbol, AbstractString} = nothing,
	ncols::Real = 0,
	title::AbstractString = "",
	fontsize::Real = 0,
	frame::Union{Nothing, Bool} = nothing,
	dedupe::Bool = true,
	itemwidth::Real = 0,
	entrywidth::Real = 0,
	legend_target::Union{Nothing, Symbol} = nothing,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	options = _legend_options(
		"set_legend!";
		position, inset, bgcolor, bordercolor, borderwidth, showlegend,
		xanchor, yanchor, orientation, ncols, title, fontsize, frame, dedupe,
		itemwidth, entrywidth, legend_target,
	)
	(row === nothing) == (col === nothing) || throw(ArgumentError(
		"set_legend!: `row` and `col` must be given together.",
	))
	return _transactional_subplot_mutation!(
		_set_subplot_legend_impl!,
		sf,
		_SUBPLOT_LEGEND_MODE_METADATA_FIELDS;
		options = options,
		row = row,
		col = col,
	)
end

# `subplot_legends!` keyword names of 1.x, kept as deprecated aliases (C6).
function _legend_subplot_aliases(
	who::AbstractString;
	inset,
	bgcolor,
	bordercolor,
	borderwidth,
	legend_inset,
	legend_bgcolor,
	legend_bordercolor,
	legend_borderwidth,
)
	resolved = Any[]
	for (name, value, alias, alias_value) in (
		("inset", inset, "legend_inset", legend_inset),
		("bgcolor", bgcolor, "legend_bgcolor", legend_bgcolor),
		("bordercolor", bordercolor, "legend_bordercolor", legend_bordercolor),
		("borderwidth", borderwidth, "legend_borderwidth", legend_borderwidth),
	)
		if alias_value !== nothing
			value === nothing || throw(ArgumentError(
				"$(who): `$(alias)` is a deprecated alias of `$(name)`; pass only `$(name)`.",
			))
			Base.depwarn("$(who): `$(alias)` is deprecated, use `$(name)`.", Symbol(who))
			push!(resolved, alias_value)
		else
			push!(resolved, value)
		end
	end
	return (inset = resolved[1], bgcolor = resolved[2], bordercolor = resolved[3], borderwidth = resolved[4])
end

function _subplot_legends_impl!(fig; options)
	opts = options
	p = _plot_obj(fig)
	position = opts.position === nothing ? _DEFAULT_LEGEND_POSITION[] : opts.position
	defaults = _legend_default_colors(p)
	_apply_subplot_legends!(
		p;
		legend_position = position,
		legend_inset = opts.inset,
		legend_bgcolor = opts.frame === false ? _LEGEND_FRAMELESS_COLORS.bgcolor :
			something(opts.bgcolor, defaults.bgcolor),
		legend_bordercolor = opts.frame === false ? _LEGEND_FRAMELESS_COLORS.bordercolor :
			something(opts.bordercolor, defaults.bordercolor),
		legend_borderwidth = opts.frame === false ? _LEGEND_FRAMELESS_COLORS.borderwidth :
			something(opts.borderwidth, defaults.borderwidth),
		overwrite = true,
		xanchor = opts.xanchor,
		yanchor = opts.yanchor,
		ext_opts = opts,
	)
	opts.dedupe && _legend_dedupe!(p)
	opts.showlegend === nothing || (p.layout.fields[:showlegend] = opts.showlegend)
	_refresh!(fig)
	return fig
end

"""
	subplot_legends!(fig; position=nothing, inset=nothing, bgcolor=nothing, bordercolor=nothing, borderwidth=nothing, showlegend=nothing, xanchor="", yanchor="", orientation=nothing, ncols=0, title="", fontsize=0, frame=nothing, dedupe=true, itemwidth=0, entrywidth=0)

Give each subplot its own legend box, placed inside (or, for outside
positions, next to) that subplot's axes, instead of Plotly's single legend.
Secondary-y traces share their cell's legend. The keywords mean the same as
in [`set_legend!`](@ref); the 1.x names `legend_inset`, `legend_bgcolor`,
`legend_bordercolor` and `legend_borderwidth` are deprecated aliases of
`inset`, `bgcolor`, `bordercolor` and `borderwidth`.

- On a [`SubplotFigure`](@ref) it turns per-subplot legends on
  (`sf.per_subplot_legends = true`), so traces added later get their cell's
  legend too; `position = nothing` keeps the current boxes (cells without one
  use `sf.legend_position`). Same as `set_legend!(sf; legend_target = :cell, ...)`.
- On a `Plot`/[`SyncPlot`](@ref) built with subplots it assigns the legends
  once (`position = nothing` means `get_default_legend_position()`).

Returns `fig`.

# Example
```julia
sf = subplots(1, 2; sync = false, per_subplot_legends = false)
plot_scatter!(sf, 1:3, [1, 2, 3]; legend = "left", row = 1, col = 1)
plot_scatter!(sf, 1:3, [3, 2, 1]; legend = "right", row = 1, col = 2)
subplot_legends!(sf; position = :bottomright)
```
"""
function subplot_legends!(
	fig::Union{Plot, SyncPlot};
	position::Union{Nothing, Symbol, AbstractString, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	inset::Union{Nothing, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	borderwidth::Union{Nothing, Real} = nothing,
	showlegend::Union{Nothing, Bool} = nothing,
	xanchor::Union{AbstractString, Symbol} = "",
	yanchor::Union{AbstractString, Symbol} = "",
	orientation::Union{Nothing, Symbol, AbstractString} = nothing,
	ncols::Real = 0,
	title::AbstractString = "",
	fontsize::Real = 0,
	frame::Union{Nothing, Bool} = nothing,
	dedupe::Bool = true,
	itemwidth::Real = 0,
	entrywidth::Real = 0,
	legend_inset::Union{Nothing, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	legend_bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_borderwidth::Union{Nothing, Real} = nothing,
)
	aliases = _legend_subplot_aliases(
		"subplot_legends!";
		inset, bgcolor, bordercolor, borderwidth,
		legend_inset, legend_bgcolor, legend_bordercolor, legend_borderwidth,
	)
	options = _legend_options(
		"subplot_legends!";
		position,
		inset = aliases.inset,
		bgcolor = aliases.bgcolor,
		bordercolor = aliases.bordercolor,
		borderwidth = aliases.borderwidth,
		showlegend, xanchor, yanchor, orientation, ncols, title, fontsize,
		frame, dedupe, itemwidth, entrywidth,
		legend_target = nothing,
	)
	return _transactional_high_level_plot_mutation!(
		_subplot_legends_impl!,
		fig;
		options = options,
	)
end

function _subplot_figure_legends_impl!(sf::SubplotFigure; options)
	p = _plot_obj(sf.fig)
	_legend_set_cell_mode!(sf, p, options)
	_refresh!(sf.fig)
	return sf
end

function subplot_legends!(
	sf::SubplotFigure;
	position::Union{Nothing, Symbol, AbstractString, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	inset::Union{Nothing, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	borderwidth::Union{Nothing, Real} = nothing,
	showlegend::Union{Nothing, Bool} = nothing,
	xanchor::Union{AbstractString, Symbol} = "",
	yanchor::Union{AbstractString, Symbol} = "",
	orientation::Union{Nothing, Symbol, AbstractString} = nothing,
	ncols::Real = 0,
	title::AbstractString = "",
	fontsize::Real = 0,
	frame::Union{Nothing, Bool} = nothing,
	dedupe::Bool = true,
	itemwidth::Real = 0,
	entrywidth::Real = 0,
	legend_inset::Union{Nothing, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	legend_bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_borderwidth::Union{Nothing, Real} = nothing,
)
	aliases = _legend_subplot_aliases(
		"subplot_legends!";
		inset, bgcolor, bordercolor, borderwidth,
		legend_inset, legend_bgcolor, legend_bordercolor, legend_borderwidth,
	)
	options = _legend_options(
		"subplot_legends!";
		position,
		inset = aliases.inset,
		bgcolor = aliases.bgcolor,
		bordercolor = aliases.bordercolor,
		borderwidth = aliases.borderwidth,
		showlegend, xanchor, yanchor, orientation, ncols, title, fontsize,
		frame, dedupe, itemwidth, entrywidth,
		legend_target = :cell,
	)
	return _transactional_subplot_mutation!(
		_subplot_figure_legends_impl!,
		sf,
		_SUBPLOT_LEGEND_MODE_METADATA_FIELDS;
		options = options,
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
