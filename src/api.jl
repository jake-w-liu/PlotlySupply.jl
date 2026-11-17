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
		_finalize_figure!(staged; live = _plot_data(fig))
		return nothing
	end
	fast_mutation = function (candidate)
		staged = _HighLevelStagedPlotMutation(candidate)
		staged_target[] = staged
		result[] = mutator(staged, args...; kwargs...)
		_finalize_figure!(staged; live = _plot_data(fig))
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

# Package-wide default template: a registered template name (`+` compounds
# allowed) or a `PlotlyBase.Template` object (spec C38).
const _DEFAULT_TEMPLATE = Ref{Union{Symbol, PlotlyBase.Template}}(:plotly_white)
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
# exported spine. Publication default is a closed black box. This is the spine
# and tick colour on LIGHT templates; dark templates get a light colour from
# `_template_ink` (src/sci/style.jl), so the frame stays visible.
const _DEFAULT_AXIS_LINECOLOR = "#000000"
const _DEFAULT_AXIS_LINEWIDTH = 1.0

# Registered template name for `template` (a String or Symbol), or `nothing`
# when it names no registered template. Surrounding whitespace is ignored, and
# `+` compounds are accepted when every part is registered (PlotlyBase strips
# every part the same way). Never warns.
function _template_name_or_nothing(template::Union{AbstractString, Symbol})
	known = keys(PlotlyBase.templates)
	exact = Symbol(template)
	exact in known && return exact
	name = strip(String(template))
	isempty(name) && return nothing
	stripped = Symbol(name)
	stripped in known && return stripped
	parts = strip.(split(name, '+'))
	if length(parts) > 1 &&
			all(!isempty(part) && Symbol(part) in known for part in parts)
		return Symbol(join(parts, '+'))
	end
	return nothing
end

# Normalized registered template name for a `String`/`Symbol` template
# specification. An unrecognised name warns and falls back to `:plotly_white`
# (the 1.x behaviour); any other type throws an `ArgumentError` naming `who`,
# the public function the template was passed to.
function _normalize_template(template; who::AbstractString = "template")
	(template isa Symbol || template isa AbstractString) ||
		throw(ArgumentError(
			"$(who): a template must be a registered template name (String or " *
			"Symbol) or a PlotlyBase.Template; got a $(typeof(template)).",
		))
	name = _template_name_or_nothing(template)
	name === nothing || return name
	valid_templates = sort!(collect(keys(PlotlyBase.templates)))
	@warn "$(who): unrecognized template $(repr(template)); falling back to :plotly_white." valid = valid_templates
	return :plotly_white
end

# The `PlotlyBase.Template` object for a template specification: a Template is
# returned as is, a name goes through `_normalize_template` (same `who`).
_resolve_template(template::PlotlyBase.Template; who::AbstractString = "template") = template
function _resolve_template(template; who::AbstractString = "template")
	name = _normalize_template(template; who = who)
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

Return the package-wide default Plotly template used by high-level
constructors: a template name `Symbol` (initially `:plotly_white`; compound
names such as `Symbol("plotly_white+xgridoff")` are possible) or the
`PlotlyBase.Template` object passed to [`set_default_template!`](@ref).

The active [`PlotStyle`](@ref) follows this default unless the style names a
template of its own (the built-in `:default` style does not).
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

Set the package-wide default Plotly template used by high-level constructors
(figures created afterwards; existing figures are unchanged, use
[`set_template!`](@ref) for those).

# Arguments
- `template`: one of
  - a registered template name, as a `String` or `Symbol` (`"plotly_white"`,
    `:plotly_dark`, `"ggplot2"`, `"simple_white"`, … or a custom
    `PlotlyBase.Template` registered in `PlotlyBase.templates`). Surrounding
    whitespace is ignored, and registered names may be combined with `+`
    using PlotlyBase's compound-template syntax (`"plotly_white+xgridoff"`).
    An unrecognised name warns and falls back to `:plotly_white`.
  - a `PlotlyBase.Template` object, used as is.
  Any other type throws an `ArgumentError`.

Axis spines and tick marks follow the template: black on light templates and
the template's light text colour on dark ones such as `plotly_dark`; the
default legend box is likewise derived from the template.

Returns the new default: the normalized name `Symbol`, or the `Template`
object.

# Example
```julia
set_default_template!(:plotly_dark)
fig = plot_scatter(1:10, (1:10) .^ 2)      # dark figure with a light frame
set_default_template!(PlotlyBase.Template(layout = attr(font = attr(family = "Arial"))))
set_default_template!()                    # back to "plotly_white"
```
"""
function set_default_template!(template = "plotly_white")
	_DEFAULT_TEMPLATE[] = template isa PlotlyBase.Template ?
		template :
		_normalize_template(template; who = "set_default_template!")
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

While the default is `:topright`, the legends of the scatter and line
families and the cell legends of a [`SubplotFigure`](@ref) go where they cover
the least data (matplotlib's `loc = "best"`, see [`plot_scatter`](@ref)); any
other default turns this off.

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

# The default look of a figure under construction (spec C37): the active
# `PlotStyle`'s template, then its Cartesian axis defaults (re-applied after
# the template so plotly_white cannot wash the spines out), the default legend
# box derived from the template and style, and finally the style's fonts,
# colorway and margins. Under the built-in `:default` style this produces
# exactly the 1.x layout. Call it on a figure under construction only (the
# constructors' `apply_template = true` path, `subplots`, `make_subplots`):
# `_apply_style_layout!` writes colorbar fonts onto existing traces, which a
# registered fast-path mutation cannot stage.
function _apply_default_template!(fig)
	style = _active_style()
	template = _style_template(style)
	relayout!(fig, template = template)
	_apply_default_cartesian_axes!(fig; style = style, template = template)
	_apply_default_legend!(fig; _style_legend_defaults(style; template = template)...)
	_apply_style_layout!(fig, style; template = template)
	return nothing
end

# Attributes of one Cartesian axis of a new figure: the active style's axis
# defaults (spines, ticks, ink colour, grid; see `_style_axis_defaults`), the
# axis title (written as `title.text` through `_label`; an empty title writes
# nothing) and an optional `tick0`. `axis` (`:x` or `:y`) selects which
# template axis may override `ticks`/`mirror` for custom templates.
function _cartesian_axis_style(
	;
	title_text::AbstractString = "",
	tick0 = nothing,
	axis::Symbol = :x,
)
	d = _style_axis_defaults(_active_style(); axis = axis)
	title = isempty(title_text) ? nothing : _title_attr(_label(title_text))
	title === nothing || (d[:title] = title)
	tick0 === nothing || (d[:tick0] = tick0)
	return attr(; d...)
end

# Layout of a new Cartesian figure: the figure title (as `title.text` through
# `_label`, omitted when empty) and the styled primary x and y axes.
function _default_cartesian_layout(
	;
	title::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	x_tick0 = nothing,
	y_tick0 = nothing,
)
	yaxis = _cartesian_axis_style(title_text = ylabel, tick0 = y_tick0, axis = :y)
	xaxis = _cartesian_axis_style(title_text = xlabel, tick0 = x_tick0, axis = :x)
	figure_title = isempty(title) ? nothing : _title_attr(_label(title))
	figure_title === nothing && return Layout(yaxis = yaxis, xaxis = xaxis)
	return Layout(title = figure_title, yaxis = yaxis, xaxis = xaxis)
end

# Re-apply the style's Cartesian axis defaults to every x/y axis of the figure
# (only when the layout has x/y axes at all). `style` is a `PlotStyle`
# (defined in src/sci/style.jl, included further down, hence no annotation);
# `template` must be the template the figure uses (normally the style's own,
# just applied by `_apply_default_template!`): it chooses the spine/tick ink.
#
# The 1.x frame keys (zeroline, showline, mirror, ticks, automargin, linecolor,
# linewidth, tickcolor) are written to every axis, as in 1.x. `showgrid`
# (written only by a style with `grid = false`) is filled in only where an axis
# has none yet, so an explicit `grid = :x`/`:y`/`false` applied by a
# constructor before the template is kept.
function _apply_default_cartesian_axes!(
	fig;
	style = _active_style(),
	template::PlotlyBase.Template = _style_template(style),
)
	fields = _plot_layout(fig).fields
	layout_keys = collect(keys(fields))
	has_x = any(startswith(String(k), "xaxis") for k in layout_keys)
	has_y = any(startswith(String(k), "yaxis") for k in layout_keys)
	# Compute everything before the first write.
	x_defaults = has_x ? _style_axis_defaults(style; template = template, axis = :x) : nothing
	y_defaults = has_y ? _style_axis_defaults(style; template = template, axis = :y) : nothing
	grid_updates = Pair{Symbol, Any}[]
	for (defaults, letter) in ((x_defaults, "x"), (y_defaults, "y"))
		defaults === nothing && continue
		showgrid = pop!(defaults, :showgrid, nothing)
		showgrid === nothing && continue
		for key in sort!(filter(k -> occursin(Regex("^$(letter)axis\\d*\$"), String(k)), layout_keys); by = String)
			haskey(_symbol_dict(fields[key]), :showgrid) && continue
			push!(grid_updates, Symbol(key, "_showgrid") => showgrid)
		end
	end
	x_defaults === nothing || update_xaxes!(fig; x_defaults...)
	y_defaults === nothing || update_yaxes!(fig; y_defaults...)
	isempty(grid_updates) || relayout!(fig; grid_updates...)
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
			match_snapshot = _subplot_match_snapshot(_plot_obj(candidate))
			result[] =
				mutator(staged, args...; kwargs...)
			_subplot_match_sync!(_plot_obj(candidate), match_snapshot)
			_finalize_figure!(staged; live = _plot_data(getfield(sf, :fig)))
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

# ── Shared-axis (`matches`) groups ─────────────────────────────────────────
#
# plotly.js (2.35.2, render probes for G61) draws every axis of a `matches`
# group over the ROOT's range, ignores a range or autorange written on a
# follower, and drops `matches` from an axis whose type differs from the
# root's (a log cell next to a linear cell stops being shared and is drawn
# with its own range). A SubplotFigure call that changes one axis of a group
# therefore acts on the group (`_subplot_match_sync!`, run on the staged
# figure after every SubplotFigure mutation and before `_finalize_figure!`):
#
# - the group-wide attributes (`_SUBPLOT_MATCH_SHARED_KEYS`: axis type, tick
#   placement and tick-label format) changed on one member are copied to every
#   member (the root's change wins over a follower's);
# - a `range`/`autorange` changed on a follower moves to the root; a range set
#   without an `autorange` makes the root state `autorange = false` (the
#   `autorange = true` `_finalize_figure!` gives group roots would override
#   it), a range removed without one makes it autorange again;
# - an axis title set on a member whose tick labels are hidden moves to the
#   member that shows the group's tick labels in the same column (x) or row
#   (y): that is where the shared axis is labelled.
#
# Axes that overlay another axis (secondary axes, twins) are never members.
# Nothing is written when the call changed nothing in a group.

const _SUBPLOT_MATCH_SHARED_KEYS = (
	:type,
	:exponentformat,
	:showexponent,
	:tickmode,
	:tickvals,
	:ticktext,
	:tick0,
	:dtick,
	:nticks,
	:tickformat,
	:tickprefix,
	:ticksuffix,
	:separatethousands,
	:tickangle,
	:tickfont,
	:categoryorder,
	:categoryarray,
	:minor,
)
const _SUBPLOT_MATCH_RANGE_KEYS = (:range, :autorange)
const _SUBPLOT_MATCH_TRACKED_KEYS = (
	_SUBPLOT_MATCH_SHARED_KEYS...,
	_SUBPLOT_MATCH_RANGE_KEYS...,
	:title,
)

# Marks an attribute an axis does not state (distinct from every stored value).
struct _SubplotMatchAbsent end

struct _SubplotMatchSnapshot
	# root => members, root first, then the followers in axis-index order
	groups::Vector{Pair{Symbol, Vector{Symbol}}}
	# member => tracked attribute => canonical value
	values::Dict{Symbol, Dict{Symbol, Any}}
end

function _subplot_match_value(axis, name::Symbol)
	value = _cmn_mapping_get(axis, name)
	return value === nothing ? _SubplotMatchAbsent() : _legend_canonical(value)
end

_subplot_match_axis_order(key::Symbol) =
	(String(key)[1], something(tryparse(Int, String(key)[6:end]), 1))

_subplot_match_overlays(axis) = _cmn_mapping_get(axis, :overlaying) !== nothing

# The `matches` groups of `fields` (a layout's fields): root => members. A
# chain to an axis the layout does not hold, a cyclic chain and axes that
# overlay another axis are skipped (plotly.js ignores such references).
function _subplot_match_groups(fields::AbstractDict)
	groups = Dict{Symbol, Vector{Symbol}}()
	for (key, axis) in fields
		(key isa Symbol && _fin_is_axis_key(key)) || continue
		_fin_axis_key(_fin_field(axis, :matches)) === nothing && continue
		_subplot_match_overlays(axis) && continue
		root = _fin_match_root(fields, key)
		(root === nothing || root === key || !haskey(fields, root)) && continue
		_subplot_match_overlays(fields[root]) && continue
		push!(get!(() -> Symbol[], groups, root), key)
	end
	ordered = Pair{Symbol, Vector{Symbol}}[]
	for root in sort!(collect(keys(groups)); by = _subplot_match_axis_order)
		followers = sort!(groups[root]; by = _subplot_match_axis_order)
		push!(ordered, root => Symbol[root; followers])
	end
	return ordered
end

# The tracked attributes of every shared-axis group of `p` before a mutation;
# `nothing` when the figure has no group (the sync is then skipped).
function _subplot_match_snapshot(p::Plot)
	fields = p.layout.fields
	groups = _subplot_match_groups(fields)
	isempty(groups) && return nothing
	values = Dict{Symbol, Dict{Symbol, Any}}()
	for (_, members) in groups, member in members
		axis = get(fields, member, nothing)
		values[member] = Dict{Symbol, Any}(
			name => _subplot_match_value(axis, name) for name in _SUBPLOT_MATCH_TRACKED_KEYS
		)
	end
	return _SubplotMatchSnapshot(groups, values)
end

# Write `value` (`_SubplotMatchAbsent()`: delete) as attribute `name` of axis
# `key`, replacing a nested value wholesale.
function _subplot_match_write!(p::Plot, key::Symbol, name::Symbol, value)
	if value isa _SubplotMatchAbsent
		_cmn_delete_layout_fields!(p, key, (name,))
	else
		_cmn_merge_layout_key!(p, key, Dict{Symbol, Any}(name => deepcopy(value)))
	end
	return nothing
end

_subplot_match_raw(axis, name::Symbol) =
	something(_cmn_mapping_get(axis, name), _SubplotMatchAbsent())

# Position of axis `key` across its own direction: the start of the domain of
# the axis it is anchored to (an x axis sits at the bottom of its y axis'
# domain, a y axis at the left of its x axis' domain).
function _subplot_match_cross_position(layout::Layout, key::Symbol)
	anchor = _fin_axis_key(_fin_string(_cmn_mapping_get(get(layout.fields, key, nothing), :anchor)))
	anchor === nothing && return nothing
	domain = _layout_axis_domain(layout, anchor)
	return domain === nothing ? nothing : domain[1]
end

# The member of `members` that shows the group's tick labels next to `member`:
# its domain overlaps `member`'s and it is the lowest (x) or left-most (y) such
# member with visible tick labels; `nothing` if there is none.
function _subplot_match_label_axis(layout::Layout, members, member::Symbol)
	own = _layout_axis_domain(layout, member)
	own === nothing && return nothing
	best = nothing
	best_position = Inf
	for other in members
		other === member && continue
		_cmn_mapping_get(get(layout.fields, other, nothing), :showticklabels) === false && continue
		domain = _layout_axis_domain(layout, other)
		domain === nothing && continue
		# 1e-9: domains are paper fractions; touching cells do not overlap.
		min(own[2], domain[2]) - max(own[1], domain[1]) > 1e-9 || continue
		position = _subplot_match_cross_position(layout, other)
		position === nothing && continue
		if position < best_position
			best = other
			best_position = position
		end
	end
	return best
end

"""
	_subplot_match_sync!(p::Plot, snapshot)

Make the changes a SubplotFigure call made to the axes of a shared-axis
(`matches`) group act on the group (see the comment above
`_SUBPLOT_MATCH_SHARED_KEYS`). `snapshot` is `_subplot_match_snapshot(p)`
taken before the call; `nothing` is a no-op.
"""
function _subplot_match_sync!(p::Plot, snapshot::Union{Nothing, _SubplotMatchSnapshot})
	snapshot === nothing && return nothing
	layout = p.layout
	fields = layout.fields
	for (root, members) in snapshot.groups
		all(member -> haskey(fields, member), members) || continue
		changed = Dict{Symbol, Vector{Symbol}}()
		for member in members, name in _SUBPLOT_MATCH_TRACKED_KEYS
			before = snapshot.values[member][name]
			isequal(before, _subplot_match_value(fields[member], name)) && continue
			push!(get!(() -> Symbol[], changed, name), member)
		end
		isempty(changed) && continue

		# Group-wide attributes: the first member that changed one (the root
		# when it did) is the source for every member.
		for name in _SUBPLOT_MATCH_SHARED_KEYS
			sources = get(changed, name, nothing)
			sources === nothing && continue
			source = first(sources)
			value = _subplot_match_raw(fields[source], name)
			canonical = _subplot_match_value(fields[source], name)
			for member in members
				member === source && continue
				isequal(_subplot_match_value(fields[member], name), canonical) && continue
				_subplot_match_write!(p, member, name, value)
			end
		end

		# Range and autorange live on the root.
		range_sources = get(changed, :range, nothing)
		autorange_sources = get(changed, :autorange, nothing)
		for (name, sources) in ((:range, range_sources), (:autorange, autorange_sources))
			sources === nothing && continue
			source = first(sources)
			source === root ||
				_subplot_match_write!(p, root, name, _subplot_match_raw(fields[source], name))
			for member in sources
				member === root && continue
				_subplot_match_write!(p, member, name, _SubplotMatchAbsent())
			end
		end
		if range_sources !== nothing && autorange_sources === nothing
			root_axis = fields[root]
			autorange = _cmn_mapping_get(root_axis, :autorange)
			if _cmn_mapping_get(root_axis, :range) === nothing
				autorange === false && _subplot_match_write!(p, root, :autorange, true)
			else
				autorange === false || _subplot_match_write!(p, root, :autorange, false)
			end
		end

		# A title on an axis with hidden tick labels labels the group's axis.
		title_sources = get(changed, :title, nothing)
		title_sources === nothing && continue
		for member in title_sources
			_cmn_mapping_get(fields[member], :showticklabels) === false || continue
			title = _cmn_mapping_get(fields[member], :title)
			title === nothing && continue
			target = _subplot_match_label_axis(layout, members, member)
			target === nothing && continue
			_subplot_match_write!(p, target, :title, title)
			_subplot_match_write!(p, member, :title, _SubplotMatchAbsent())
		end
	end
	return nothing
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

# Tolerance of the domain containment test below (paper fractions; inset
# domains are computed from the host domain in floating point).
const _LEGEND_DOMAIN_TOL = 1e-9

_legend_domain_within(inner, outer) =
	inner[1] >= outer[1] - _LEGEND_DOMAIN_TOL && inner[2] <= outer[2] + _LEGEND_DOMAIN_TOL

# Grid cell whose legend lists the traces of the x/y axis pair (xref, yref):
# `nothing` when the pair is a grid cell's own (the common case, decided by
# comparing ids only), otherwise — an inset (`inset!`, `subplots(...; insets)`)
# or other extra axes — the Cartesian cell whose plot area contains the pair's
# domain, as (x ref, y ref, x domain, y domain). A pair inside no cell, or
# inside several overlapping cells, keeps its own legend.
function _legend_inset_host(p::Plot, xref::String, yref::String, xdom, ydom)
	grid_ref = p.layout.subplots.grid_ref
	cells = Tuple{String, String}[]
	for index in eachindex(grid_ref)
		isassigned(grid_ref, index) || continue
		refs = grid_ref[index]
		isempty(refs) && continue
		ref = first(refs)
		String(ref.subplot_kind) == "xy" || continue
		routing = ref.trace_kwargs.fields
		cell = (String(get(routing, :xaxis, "x")), String(get(routing, :yaxis, "y")))
		cell == (xref, yref) && return nothing
		push!(cells, cell)
	end
	host = nothing
	for (cell_x, cell_y) in cells
		cell_xdom = _layout_axis_domain(p.layout, _axis_layout_key(cell_x, :x))
		cell_ydom = _layout_axis_domain(p.layout, _axis_layout_key(cell_y, :y))
		(cell_xdom === nothing || cell_ydom === nothing) && continue
		(_legend_domain_within(xdom, cell_xdom) && _legend_domain_within(ydom, cell_ydom)) ||
			continue
		host === nothing || return nothing
		host = (cell_x, cell_y, cell_xdom, cell_ydom)
	end
	return host
end

function _trace_subplot_key_domain(p::Plot, trace::GenericTrace)
	fields = trace.fields

	if haskey(fields, :xaxis) || haskey(fields, :yaxis)
		xaxis = _legend_base_axis_ref(p.layout, String(get(fields, :xaxis, "x")), :x)
		yaxis = _legend_base_axis_ref(p.layout, String(get(fields, :yaxis, "y")), :y)
		xdom = _layout_axis_domain(p.layout, _axis_layout_key(xaxis, :x))
		ydom = _layout_axis_domain(p.layout, _axis_layout_key(yaxis, :y))
		(xdom === nothing || ydom === nothing) && return nothing
		# Traces on an inset are listed in the legend of the cell that hosts it.
		host = _legend_inset_host(p, xaxis, yaxis, xdom, ydom)
		if host !== nothing
			xaxis, yaxis, xdom, ydom = host
		end
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
	if _legend_real(get(pad, :t, nothing)) === nothing
		pad[:t] = _TEXT_TITLE_TOP_PAD
	end
	needed = _legend_title_clearance_pad(p, d)
	pad_b = _legend_real(get(pad, :b, nothing))
	changed = get(d, :automargin, nothing) !== true || !haskey(d, :pad) ||
		pad_b === nothing || pad_b < needed || !(title isa AbstractDict || title isa PlotlyBase.PlotlyAttribute)
	(pad_b === nothing || pad_b < needed) && (pad[:b] = _text_number(needed))
	changed || return nothing
	d[:automargin] = true
	d[:pad] = attr(; pad...)
	return d
end

# The `title.pad.b` `_legend_title_clearance` gives title `d` (a Dict with
# text): the band pad.t (10 px when unset) + text + pad.b must exceed
# `margin.t`, with the font size as a lower bound of the text height (half of
# it for MathJax titles).
function _legend_title_clearance_pad(p::Plot, d::AbstractDict)
	text = get(d, :text, "")
	pad_t = _legend_real(get(_symbol_dict(get(d, :pad, nothing)), :t, nothing))
	pad_t === nothing && (pad_t = Float64(_TEXT_TITLE_TOP_PAD))
	font_size = _legend_title_font_size(p, d)
	# Lower bound of the drawn text height: one line of text is at least as
	# tall as its font size; a MathJax expression can be shorter (e.g. `$x$`).
	text_floor = (text isa AbstractString && occursin('$', text)) ? font_size / 2 : font_size
	return max(Float64(_LEGEND_TITLE_GAP), ceil(_legend_top_margin(p) - pad_t - text_floor + 1))
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

# Layout pass after every legend placement: the decorations above the axes
# are stacked (D12: panel titles/labels above cell legends, figure legends
# above both), or, with nothing stacked, the figure title clears a legend
# above the plot area (`_text_restack!(p; clearance = true)`).
function _legend_stack!(p::Plot)
	_text_restack!(p; clearance = true)
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
	(startswith(group, _LEGEND_DEDUPE_GROUP_PREFIX) || _legend_is_column_group(group)) && return ""
	return String(group)
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
toggles them together, and only the first keeps `showlegend`. A first member
that sits in a legend column (`_legend_apply_columns!`) keeps its column group
and the hidden members get a generated group. When a legend had no user
legend groups, its `traceorder` is pinned to "normal" so the new groups do
not switch plotly to grouped spacing. Returns whether anything changed.
"""
function _legend_dedupe!(p::Plot; legend_ids = nothing)
	groups = _legend_dedupe_groups(p; legend_ids = legend_ids)
	isempty(groups) && return false
	touched = Set{String}()
	for members in groups
		first_trace = p.data[members[1]]
		legend_id = _legend_trace_legend_id(first_trace)
		group = get(first_trace.fields, :legendgroup, "")
		in_column = _legend_is_column_group(group)
		if !(group isa AbstractString) || isempty(group) || in_column
			group = _LEGEND_DEDUPE_GROUP_PREFIX * legend_id * ":" * string(members[1])
		end
		for (k, index) in enumerate(members)
			(k == 1 && in_column) && continue
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
				!startswith(group, _LEGEND_DEDUPE_GROUP_PREFIX) &&
				!_legend_is_column_group(group)
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

# Fill the style's legend font (`_style_legend_font()`) into `layout.<key>.font`
# where the box sets no value yet.
function _legend_fill_style_font!(p::Plot, key::Symbol, style_font::AbstractDict)
	isempty(style_font) && return nothing
	d = _symbol_dict(get(p.layout.fields, key, nothing))
	font = _symbol_dict(get(d, :font, nothing))
	all(name -> haskey(font, name), keys(style_font)) && return nothing
	for (name, value) in style_font
		get!(font, name, value)
	end
	d[:font] = attr(; font...)
	p.layout.fields[key] = attr(; d...)
	return nothing
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
written into every box (the callers lay `ncols` columns out afterwards with
`_legend_relayout_columns!`); entries new to a column legend join a column.
`auto_from > 0` (an append whose first new trace has that index) moves a box
at the package default position (`:topright`, no explicit anchors) to the
position covering the least of its cell's data (`_legend_best_cell_position`,
Y17) when the box is new or still sits where that rule put it for the traces
before the append; a box the user placed elsewhere stays.
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
	auto_from::Integer = 0,
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
	# Cells that received traces in this append (only they can change their
	# best legend position).
	appended = Set{String}()
	if auto_from > 0
		for index in auto_from:length(p.data)
			key = trace_keys[index]
			key === nothing || push!(appended, key)
		end
	end
	# Legend boxes created after construction get the active style's legend
	# font size, which the style wrote only onto the legends that existed when
	# the figure was built (an explicit font size already in the box wins).
	style_font = _style_legend_font()
	for key in order
		xdom, ydom = domains[key]
		legend_id = _legend_id(ids[key])
		legend_key = _legend_symbol(ids[key])
		created = fresh || !haskey(p.layout.fields, legend_key)
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
		auto = key in appended && legend_position === :topright && isempty(xanchor) &&
			isempty(yanchor) && !replace_placement && _DEFAULT_LEGEND_POSITION[] === :topright
		if auto && !(created || reassigned)
			current = _symbol_dict(p.layout.fields[legend_key])
			earlier = something(_legend_best_cell_position(p, legend_id, xdom, ydom; before = auto_from), :topright)
			expected = _legend_placement(earlier, xdom, ydom, legend_inset; figure = false)
			auto = all(k -> get(current, k, nothing) == get(expected, k, nothing), _LEGEND_PLACEMENT_KEYS)
		end
		_legend_write_block!(
			p,
			legend_key;
			placement = placement,
			colors = colors,
			ext = ext_opts === nothing ? nothing :
				_legend_layout_ext(ext_opts; span = xdom[2] - xdom[1]),
			replace_placement = replace_placement || reassigned,
			replace_colors = replace_colors || reassigned,
			fresh = fresh,
		)
		created && _legend_fill_style_font!(p, legend_key, style_font)
		if auto
			# Scored once the box carries its frame and font (its size).
			best = something(_legend_best_cell_position(p, legend_id, xdom, ydom), :topright)
			_legend_write_block!(
				p,
				legend_key;
				placement = _legend_placement(best, xdom, ydom, legend_inset; figure = false),
				replace_placement = true,
			)
		end
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
		_legend_fill_style_font!(p, figure_key, style_font)
	end
	# Entries that joined a column legend (`ncols`) take a column.
	_legend_extend_columns!(p)
	_legend_set_showlegend!(p, nothing, overwrite)
	_legend_stack!(p)

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
	# New entries of a column legend (`ncols`) take a column; earlier traces
	# are not touched (append-only path).
	_legend_extend_columns!(p; first = start)
	_legend_set_showlegend!(p, nothing, explicit)
	_legend_stack!(p)
	return p
end

"""
	_refresh_subplot_legends!(sf, p = sf's Plot; first_new = 1, auto = false)

Legend pass after traces were appended to a SubplotFigure: per-subplot
legends when `sf.per_subplot_legends`, otherwise the figure legend with the
stored `sf.legend_*` settings. Existing boxes keep their placement/colours;
in figure mode only traces from `first_new` on are touched, so it is safe on
the append-only fast transaction path. `auto = true` (the append paths) lets
cell legends at the default position follow their cell's data
(`_apply_subplot_legends!(…; auto_from = first_new)`, Y17).
"""
function _refresh_subplot_legends!(
	sf::SubplotFigure,
	p::Plot = _plot_obj(getfield(sf, :fig));
	first_new::Integer = 1,
	auto::Bool = false,
)
	if sf.per_subplot_legends
		_apply_subplot_legends!(
			p;
			legend_position = sf.legend_position,
			legend_inset = sf.legend_inset,
			legend_bgcolor = sf.legend_bgcolor,
			legend_bordercolor = sf.legend_bordercolor,
			legend_borderwidth = sf.legend_borderwidth,
			auto_from = auto ? first_new : 0,
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
	# Entries without a column in a column legend (`ncols`) - the new
	# traces - take one; entries already laid out are not touched.
	_legend_extend_columns!(p)
	if showlegend isa Bool
		# Explicit caller override (e.g. force a legend for a single unnamed trace).
		p.layout.fields[:showlegend] = showlegend
	elseif !haskey(p.layout.fields, :showlegend) &&
		any(trace -> trace isa GenericTrace && _trace_will_showlegend(trace), p.data)
		p.layout.fields[:showlegend] = true
	end
	_legend_stack!(p)
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
	traces && _legend_relayout_columns!(p, "legend", opts)
	_legend_set_showlegend!(p, opts.showlegend, false)
	_legend_stack!(p)
	_refresh!(fig)
	return fig
end

# Registered with the transactional fast path (`_transactional_high_level_plot_mutation!`):
# it only touches the layout.
_set_legend_impl!(fig; options) = _legend_apply_plot!(fig, options; traces = false)
# Not registered: always the full transaction path.
_set_legend_traces_impl!(fig; options) = _legend_apply_plot!(fig, options; traces = true)

"""
	set_legend!(fig; position=nothing, inset=nothing, bgcolor=nothing, bordercolor=nothing, borderwidth=nothing, showlegend=nothing, xanchor="", yanchor="", orientation=nothing, ncols=0, title="", title_side=nothing, fontsize=0, frame=nothing, dedupe=true, itemwidth=0, entrywidth=0, legend_target=nothing, row=nothing, col=nothing)

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
    never covers tick labels or axis titles); `:outside_top` sits just above
    the plot area and `:outside_right` right of it, where Plotly grows the
    margin to fit them. Outside top/bottom legends are horizontal unless
    `orientation` says otherwise.
  - With a legend above the plot area, a figure title (from the constructor's
    `title` or [`title!`](@ref)) is pinned to the top edge with
    `title.automargin=true` and given a `title.pad.b`, so that the legend is
    laid out *below* the title instead of over it. This holds while
    `layout.margin.t` keeps the value it had then; titles referenced to the
    paper (`title.yref="paper"`) or anchored at their bottom are left alone.
  - A new `position` replaces the whole placement, including the
    orientation: an outside top/bottom legend moved to an inside position is
    vertical again unless `orientation` or `ncols` is given.
  - Tuple positions anchor the legend box on the axes side of the point:
    `fx > 1` → `xanchor="left"`, `fx < 0` → `"right"`, inside the nearest third.
- `inset::Tuple{Real,Real}` (or 2-vector): `(x, y)` padding from the axes
  edges as fractions of the axes (default `(0.02, 0.03)`; values above 0.49
  are clamped). Outside positions use it as a fixed paper offset. An `inset`
  without a `position` re-places the legend at the default position (the
  stored `sf.legend_position` for a SubplotFigure).
- `xanchor`, `yanchor` (`""` = computed): `"left"|"center"|"right"|"auto"` and
  `"top"|"middle"|"bottom"|"auto"`; given without `position` they replace only
  the anchors.

# Appearance
- `orientation`: `:v`/`:h` (or `"v"`/`"h"`, `:vertical`/`:horizontal`);
  `nothing` = horizontal for outside top/bottom and when `ncols > 1`, else
  vertical. A horizontal *cell* legend wraps its entries into as many
  columns as fit the cell (it never runs into the neighbouring cell).
- `ncols::Integer = 0`: lay the entries out in this many columns, filled
  column by column as matplotlib's `ncols` does (`ncols = 1` is a vertical
  legend). Each column is as wide as its widest label. When the columns do
  not fit the width available to the legend (its cell for a cell legend, the
  plot area for a figure legend inside it), fewer columns are used and a
  warning says so. A cell legend above or below its axes (e.g.
  `position = (1, 1), xanchor = "right", yanchor = "bottom"`) may reach from
  its anchor over the gap to the next cell of its row, or into the figure
  margin beside the grid. Columns are Plotly legend groups (`traceorder="grouped"`,
  `layout.legend.groupclick="toggleitem"`): a click toggles one entry, and the
  entries' own legend groups (stem heads, merged duplicates, `legendgroup`
  of `legend_entry!`) no longer link them to other traces. Entries added
  later join the last column; call `set_legend!` again to rebalance.
  Legends that list pie slices are not split into columns.
- `entrywidth::Real = 0`: width of each entry in px (`entrywidthmode = "pixels"`);
  cannot be combined with `ncols` in one call. A column legend keeps its
  columns, each entry `entrywidth` wide.
- `itemwidth::Real = 0`: width of the symbol part of each entry in px
  (Plotly requires at least 30). Plotly's row height (font size × 1.3, at
  least 16 px, plus 3 px) and the gaps between entries are fixed; `fontsize`
  is the way to a more compact legend.
- `title::AbstractString = ""`: legend title (mathtext allowed, through `_label`).
- `title_side`: where the title sits: `:top`, `:left`, `:top_left`,
  `:top_center`, `:top_right` (`nothing` = unchanged; Plotly puts it on top
  of a vertical legend and left of a horizontal one, a column legend gets it
  on top). `:top` puts the title above entries that start at the left edge;
  Plotly also indents the entries by the title's width for `:top_left`, so a
  matplotlib-style title above the entries is `:top`.
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
`ArgumentError` before anything is changed; `show` is not accepted (this
modifies an existing figure).

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
	title_side::Union{Nothing, Symbol, AbstractString} = nothing,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	show = nothing,
)
	_text_reject_show(show, "set_legend!")
	(row === nothing && col === nothing) || throw(ArgumentError(
		"set_legend!: `row`/`col` select a SubplotFigure cell; a Plot/SyncPlot " *
		"has a single legend, so omit them.",
	))
	options = _legend_options(
		"set_legend!";
		position, inset, bgcolor, bordercolor, borderwidth, showlegend,
		xanchor, yanchor, orientation, ncols, title, fontsize, frame, dedupe,
		itemwidth, entrywidth, legend_target, title_side,
	)
	p = _plot_obj(fig)
	# Legend columns (`ncols`, an orientation change of a column legend) are
	# legend groups on the traces.
	needs_trace_edits =
		any(_legend_hides_unnamed, p.data) ||
		(options.dedupe && !isempty(_legend_dedupe_groups(p))) ||
		options.ncols > 0 || _legend_column_layout(p, "legend") !== nothing
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
	if !was_per
		# Legend ids change with the mode: columns are laid out again below.
		_legend_clear_column_groups!(p)
		_legend_undo_dedupe!(p)
	end
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
	_legend_relayout_cell_columns!(p, opts)
	opts.showlegend === nothing || (p.layout.fields[:showlegend] = opts.showlegend)
	return nothing
end

# `_legend_relayout_columns!` for every cell legend of `p`, each fitted to its
# cell's width.
function _legend_relayout_cell_columns!(p::Plot, opts)
	order, ids, domains, _ = _legend_subplot_assignment(p)
	for key in order
		xdom = domains[key][1]
		_legend_relayout_columns!(p, _legend_id(ids[key]), opts; span = xdom[2] - xdom[1], cell = true)
	end
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
		_legend_clear_column_groups!(p)
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
	_legend_relayout_columns!(p, "legend", opts)
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
	_legend_relayout_columns!(p, _FIGURE_LEGEND_ID, opts)
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
	_legend_relayout_columns!(p, legend_id, opts; span = target.xdomain[2] - target.xdomain[1], cell = true)
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
	_legend_stack!(p)
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
	title_side::Union{Nothing, Symbol, AbstractString} = nothing,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	show = nothing,
)
	_text_reject_show(show, "set_legend!")
	options = _legend_options(
		"set_legend!";
		position, inset, bgcolor, bordercolor, borderwidth, showlegend,
		xanchor, yanchor, orientation, ncols, title, fontsize, frame, dedupe,
		itemwidth, entrywidth, legend_target, title_side,
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
	_legend_relayout_cell_columns!(p, opts)
	opts.showlegend === nothing || (p.layout.fields[:showlegend] = opts.showlegend)
	_refresh!(fig)
	return fig
end

"""
	subplot_legends!(fig; position=nothing, inset=nothing, bgcolor=nothing, bordercolor=nothing, borderwidth=nothing, showlegend=nothing, xanchor="", yanchor="", orientation=nothing, ncols=0, title="", title_side=nothing, fontsize=0, frame=nothing, dedupe=true, itemwidth=0, entrywidth=0)

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

`ncols` gives each cell's legend that many columns (fewer, with a warning,
where they do not fit the cell). Returns `fig`. Invalid values throw an
`ArgumentError` before anything is changed; `show` is not accepted.

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
	title_side::Union{Nothing, Symbol, AbstractString} = nothing,
	legend_inset::Union{Nothing, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	legend_bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_borderwidth::Union{Nothing, Real} = nothing,
	show = nothing,
)
	_text_reject_show(show, "subplot_legends!")
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
		title_side,
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
	title_side::Union{Nothing, Symbol, AbstractString} = nothing,
	legend_inset::Union{Nothing, Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = nothing,
	legend_bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_borderwidth::Union{Nothing, Real} = nothing,
	show = nothing,
)
	_text_reject_show(show, "subplot_legends!")
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
		title_side,
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

# The (row, col) a SubplotFigure call targets: the active cell when both are
# `nothing`, otherwise the validated pair. Errors are prefixed with `who`.
function _resolve_subplot_cell(
	sf::SubplotFigure;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	who::AbstractString = "SubplotFigure",
)
	if isnothing(row) && isnothing(col)
		return sf.current_row, sf.current_col
	end
	if isnothing(row) || isnothing(col)
		throw(ArgumentError("$(who): `row` and `col` must be provided together."))
	end
	(row isa Bool || col isa Bool) && throw(ArgumentError(
		"$(who): `row` and `col` must be integers, not Bool.",
	))
	(1 <= row <= sf.rows) || throw(ArgumentError(
		"$(who): `row` must be in 1:$(sf.rows); got $(row).",
	))
	(1 <= col <= sf.cols) || throw(ArgumentError(
		"$(who): `col` must be in 1:$(sf.cols); got $(col).",
	))
	return Int(row), Int(col)
end

const _SUBPLOTS_START_CELLS = ("top-left", "bottom-left")

# A grid title (`subplot_titles`, `column_titles`, `row_titles`, `x_title`,
# `y_title`) as the text plotly renders: the mathtext layer (`_label`) keeps
# the text around `$…$` math and turns newlines into line breaks. A label the
# layer rejects (an odd number of `$`, an HTML tag next to math, ...) is an
# ArgumentError naming the keyword.
function _subplots_title_label(text::AbstractString, name::AbstractString)
	return try
		_label(text)
	catch err
		err isa ArgumentError || rethrow()
		throw(ArgumentError("subplots: `$(name)` entry $(repr(text)): $(err.msg)"))
	end
end

# Validated relative sizes for `height_ratios` / `width_ratios`: `count`
# positive finite reals, returned as Float64 in the caller's order.
function _subplots_checked_ratios(ratios, count::Int, name::AbstractString)
	(ratios isa AbstractVector || ratios isa Tuple) || throw(ArgumentError(
		"subplots: `$(name)` must be a vector of positive numbers; got " *
		"$(typeof(ratios)).",
	))
	length(ratios) == count || throw(ArgumentError(
		"subplots: `$(name)` needs one entry per " *
		(name == "height_ratios" ? "row" : "column") *
		" ($(count)); got $(length(ratios)).",
	))
	out = Vector{Float64}(undef, count)
	for (k, value) in enumerate(ratios)
		(value isa Real && !(value isa Bool) && isfinite(value) && value > 0) ||
			throw(ArgumentError(
				"subplots: `$(name)` entries must be positive finite numbers; " *
				"entry $(k) is $(repr(value)).",
			))
		out[k] = Float64(value)
	end
	return out
end

# Translate `height_ratios` (top-to-bottom as drawn) and `width_ratios`
# (left-to-right) into PlotlyBase's `row_heights` / `column_widths`.
# PlotlyBase spreads `row_heights` bottom-up for start_cell = "top-left"
# (row_heights[1] sizes the BOTTOM row), so the list is reversed. For
# start_cell = "bottom-left" PlotlyBase 0.8 sizes row r with the
# (rows - r + 1)-th entry but stacks rows with the cumulative bottom-up sum,
# which overlaps or overflows the cells for any non-symmetric list; only
# uniform ratios give a valid grid there.
function _subplots_grid_kwargs(
	rows::Int,
	cols::Int,
	height_ratios,
	width_ratios,
	subplot_kwargs,
)
	grid = Dict{Symbol,Any}(pairs(subplot_kwargs))
	start_cell = get(grid, :start_cell, "top-left")
	(start_cell isa AbstractString && start_cell in _SUBPLOTS_START_CELLS) ||
		throw(ArgumentError(
			"subplots: `start_cell` must be \"top-left\" or \"bottom-left\"; " *
			"got $(repr(start_cell)).",
		))
	grid[:start_cell] = String(start_cell)
	# PlotlyBase checks the spacing with `spacing < 0 || spacing > 1 && error(...)`,
	# which accepts negative values and raises a plain ErrorException otherwise.
	for (name, count) in ((:horizontal_spacing, cols), (:vertical_spacing, rows))
		haskey(grid, name) || continue
		spacing = grid[name]
		(spacing isa Real && !(spacing isa Bool) && isfinite(spacing) &&
			0 <= spacing <= 1 && spacing * (count - 1) < 1) || throw(ArgumentError(
			"subplots: `$(name)` must be a finite number in [0, 1] whose " *
			"$(count - 1) gap(s) leave room for the cells (spacing × $(count - 1) < 1); " *
			"got $(repr(spacing)).",
		))
		grid[name] = Float64(spacing)
	end
	# PlotlyBase types `subplot_titles` as a Matrix of String/missing; accept
	# plotly.py's flat list (a Vector, read in row-major order) and
	# loosely-typed containers, and reject anything else with an ArgumentError
	# rather than a conversion MethodError. Every grid title is a text label
	# plotly typesets with MathJax, so it goes through the mathtext layer
	# (`_label`) like `title!` and the axis titles: mixed text and `$…$` math
	# keeps its text (G25).
	haskey(grid, :subplot_titles) && grid[:subplot_titles] === missing &&
		delete!(grid, :subplot_titles)
	if haskey(grid, :subplot_titles)
		titles = grid[:subplot_titles]
		(titles isa AbstractVecOrMat &&
			all(t -> t isa AbstractString || t === missing, titles)) ||
			throw(ArgumentError(
				"subplots: `subplot_titles` must be a vector or matrix of strings " *
				"(`missing` skips a cell); got $(repr(titles)).",
			))
		as_matrix = titles isa AbstractVector ? reshape(collect(titles), 1, :) : collect(titles)
		labelled = map(t -> t === missing ? missing : _subplots_title_label(t, "subplot_titles"), as_matrix)
		grid[:subplot_titles] = any(ismissing, as_matrix) ?
			Matrix{Union{Missing, String}}(labelled) :
			Matrix{String}(labelled)
	end
	for (name, count, unit) in ((:column_titles, cols, "column"), (:row_titles, rows, "row"))
		haskey(grid, name) && grid[name] === missing && delete!(grid, name)
		haskey(grid, name) || continue
		titles = grid[name]
		(titles isa AbstractVector && all(t -> t isa AbstractString, titles)) ||
			throw(ArgumentError(
				"subplots: `$(name)` must be a vector of strings, one per $(unit) " *
				"(\"\" for none); got $(repr(titles)).",
			))
		length(titles) == count || throw(ArgumentError(
			"subplots: `$(name)` needs one entry per $(unit) ($(count)); got " *
			"$(length(titles)).",
		))
		grid[name] = String[_subplots_title_label(t, String(name)) for t in titles]
	end
	for name in (:x_title, :y_title)
		haskey(grid, name) && grid[name] === missing && delete!(grid, name)
		haskey(grid, name) || continue
		title = grid[name]
		title isa AbstractString || throw(ArgumentError(
			"subplots: `$(name)` must be a string; got $(repr(title)).",
		))
		grid[name] = _subplots_title_label(title, String(name))
	end
	if height_ratios !== nothing
		haskey(grid, :row_heights) && throw(ArgumentError(
			"subplots: pass either `height_ratios` (top-to-bottom) or " *
			"`row_heights` (PlotlyBase order), not both.",
		))
		ratios = _subplots_checked_ratios(height_ratios, rows, "height_ratios")
		if start_cell == "top-left"
			grid[:row_heights] = reverse(ratios)
		else
			all(==(first(ratios)), ratios) || throw(ArgumentError(
				"subplots: unequal `height_ratios` are not supported with " *
				"start_cell = \"bottom-left\": PlotlyBase computes " *
				"overlapping row domains for that combination. Use the " *
				"default start_cell = \"top-left\" (row 1 at the top).",
			))
			grid[:row_heights] = ratios
		end
	end
	if width_ratios !== nothing
		haskey(grid, :column_widths) && throw(ArgumentError(
			"subplots: pass either `width_ratios` or `column_widths`, not both.",
		))
		grid[:column_widths] =
			_subplots_checked_ratios(width_ratios, cols, "width_ratios")
	end
	return grid
end

# ── `subplots(...; insets = [Inset(...), ...])` ──────────────────────────────
#
# PlotlyBase creates the axes of its `Inset` specifications but keeps no
# routing record of them, so the Cartesian ("xy") ones are registered in
# `sf.insets` here: `inset=k` then targets them like the insets `inset!` adds.
# A Cartesian inset must lie inside one Cartesian cell (PlotlyBase ignores
# `colspan`/`rowspan` of an inset, and the record is an x/y axis pair).
# Insets of other kinds (map, scene, ...) are passed to PlotlyBase unchanged;
# their subplots are routed by the map/scene layers, not by `inset=k`.

const _SubplotsCheckedInset = NamedTuple{
	(:index, :row, :col, :xfrac, :yfrac),
	Tuple{Int, Int, Int, NTuple{2, Float64}, NTuple{2, Float64}},
}

# A size fraction of an `Inset` (`l`, `b`, or `w`/`h`, which may be "to_end").
function _subplots_inset_fraction(value, k::Int, name::AbstractString; size::Bool)
	if size && value isa AbstractString
		value == "to_end" || throw(ArgumentError(
			"subplots: `insets[$(k)].$(name)` must be a number or \"to_end\"; got $(repr(value)).",
		))
		return nothing
	end
	(value isa Real && !(value isa Bool) && isfinite(value) &&
		(size ? 0 < value <= 1 : 0 <= value < 1)) || throw(ArgumentError(
		"subplots: `insets[$(k)].$(name)` must be a finite number in " *
		(size ? "(0, 1]" : "[0, 1)") * " (a fraction of the host cell); got $(repr(value)).",
	))
	return Float64(value)
end

# Validated `insets` keyword (before the grid is built): a vector of
# `PlotlyBase.Inset` whose cells lie inside the grid. Cartesian insets must not
# span cells and their fractions must keep them inside the host cell; they are
# returned (with their position `index` in `insets`) as fractions of the host
# cell, in order. Insets of other kinds are not returned.
function _subplots_checked_insets(insets, rows::Int, cols::Int)
	checked = _SubplotsCheckedInset[]
	insets === missing && return checked
	(insets isa AbstractVector && all(inset -> inset isa PlotlyBase.Inset, insets)) ||
		throw(ArgumentError(
			"subplots: `insets` must be a vector of `Inset(...)` specifications; got " *
			"$(repr(insets)). (`inset!(sf, bounds)` adds an inset to an existing figure.)",
		))
	for (k, inset) in enumerate(insets)
		r, c = inset.cell
		(1 <= r <= rows && 1 <= c <= cols) || throw(ArgumentError(
			"subplots: `insets[$(k)].cell` = $(inset.cell) is outside the " *
			"$(rows) × $(cols) grid.",
		))
		inset.kind == "xy" || continue
		(inset.colspan == 1 && inset.rowspan == 1) || throw(ArgumentError(
			"subplots: `insets[$(k)]` sets colspan/rowspan, which PlotlyBase ignores; " *
			"an inset lies inside one cell (size it with `w`/`h`).",
		))
		l = _subplots_inset_fraction(inset.l, k, "l"; size = false)
		b = _subplots_inset_fraction(inset.b, k, "b"; size = false)
		w = _subplots_inset_fraction(inset.w, k, "w"; size = true)
		h = _subplots_inset_fraction(inset.h, k, "h"; size = true)
		x1 = w === nothing ? 1.0 : l + w
		y1 = h === nothing ? 1.0 : b + h
		# Tolerance for fractions such as 0.7 + 0.3, which exceed 1 by one ulp.
		(x1 <= 1 + 1e-12 && y1 <= 1 + 1e-12) || throw(ArgumentError(
			"subplots: `insets[$(k)]` reaches outside its cell (l + w = $(x1), " *
			"b + h = $(y1)); both must be at most 1.",
		))
		push!(checked, (
			index = k,
			row = r,
			col = c,
			xfrac = (l, min(x1, 1.0)),
			yfrac = (b, min(y1, 1.0)),
		))
	end
	return checked
end

# Register the Cartesian insets PlotlyBase created for `checked` (from
# `_subplots_checked_insets`, in order): the j-th one holds the x/y axes
# numbered j after every grid x/y axis (other inset kinds use their own
# counters). Their domains are recomputed from the host cell's plot area
# (PlotlyBase sizes them by one grid column/row, which is wrong for spanning
# and bottom-left cells), and their tick labels do not push the figure margins
# (as for `inset!`). Returns the inset records.
function _subplots_register_insets!(p::Plot, checked::Vector{_SubplotsCheckedInset})
	records = _SubplotInset[]
	isempty(checked) && return records
	layout = p.layout
	grid_ref = layout.subplots.grid_ref
	max_x = 0
	max_y = 0
	for index in eachindex(grid_ref)
		isassigned(grid_ref, index) || continue
		for ref in grid_ref[index]
			String(ref.subplot_kind) == "xy" || continue
			x_index = _cmn_axis_index(ref.layout_keys[1], 'x')
			y_index = _cmn_axis_index(ref.layout_keys[2], 'y')
			x_index === nothing || (max_x = max(max_x, x_index))
			y_index === nothing || (max_y = max(max_y, y_index))
		end
	end
	for (j, inset) in enumerate(checked)
		k, r, c = inset.index, inset.row, inset.col
		host = isassigned(grid_ref, r, c) ? grid_ref[r, c] : PlotlyBase.SubplotRef[]
		(!isempty(host) && String(first(host).subplot_kind) == "xy") || throw(ArgumentError(
			"subplots: the host cell $((r, c)) of the Cartesian `insets[$(k)]` is not " *
			"a Cartesian (\"xy\") cell.",
		))
		hx = something(_layout_axis_domain(layout, first(host).layout_keys[1]), (0.0, 1.0))
		hy = _cmn_y_axis_domain(layout, first(host).layout_keys[2])
		xkey = Symbol("xaxis", max_x + j)
		ykey = Symbol("yaxis", max_y + j)
		xref = "x$(max_x + j)"
		yref = "y$(max_y + j)"
		# PlotlyBase numbers inset axes after the grid's; anything else means
		# its layout builder changed, and the records would point elsewhere.
		(_cmn_mapping_get(get(layout.fields, xkey, nothing), :anchor) == yref &&
			_cmn_mapping_get(get(layout.fields, ykey, nothing), :anchor) == xref) ||
			error("subplots: PlotlyBase did not create `insets[$(k)]` as $(xkey)/$(ykey).")
		xfrac, yfrac = inset.xfrac, inset.yfrac
		xdomain = (hx[1] + xfrac[1] * (hx[2] - hx[1]), hx[1] + xfrac[2] * (hx[2] - hx[1]))
		ydomain = (hy[1] + yfrac[1] * (hy[2] - hy[1]), hy[1] + yfrac[2] * (hy[2] - hy[1]))
		_cmn_merge_layout_key!(p, xkey, Dict{Symbol, Any}(:domain => collect(xdomain), :automargin => false))
		_cmn_merge_layout_key!(p, ykey, Dict{Symbol, Any}(:domain => collect(ydomain), :automargin => false))
		push!(records, _SubplotInset(r, c, xkey, ykey, xref, yref, xdomain, ydomain))
	end
	return records
end

# A legend colour keyword of `subplots`: `nothing` takes the style default; a
# String/Symbol must parse as a colour (CSS name, hex, rgb/rgba/hsl, or a
# matplotlib grey level such as "0.35") and is stored in the normalised
# "#RRGGBB" / "rgba(...)" form plotly understands.
function _subplots_legend_colour(value, default::AbstractString, name::AbstractString)
	value === nothing && return String(default)
	return _color_hex(value; who = "subplots: `$(name)`")
end

"""
	subplots(rows::Integer, cols::Integer; sync=true, title="", window_title="",
		width=0, height=0, show=true, app=nothing, height_ratios=nothing,
		width_ratios=nothing, per_subplot_legends=true,
		legend_position=get_default_legend_position(), legend_inset=(0.02, 0.03),
		legend_bgcolor=nothing, legend_bordercolor=nothing,
		legend_borderwidth=nothing, subplot_kwargs...) -> SubplotFigure

Create a MATLAB-like grid of `rows` × `cols` subplot cells and return a
[`SubplotFigure`](@ref). Cell `(1, 1)` (top left) is active; select another
with [`subplot!`](@ref) and append to the active cell (or to `row`/`col`) with
the `plot_*!` mutators, `add_trace!` and `addtraces!`. Coloured traces added
with `plot_*!` get a colorbar next to their own cell (see
[`colorbar!`](@ref) and [`shared_colorbar!`](@ref)).

# Keywords
- `sync::Bool=true`: `true` shows the figure in a live Electron window (the
  figure is a `SyncPlot`); `false` builds a plain `Plot` without a window.
- `title::AbstractString=""`: figure title, stored as `layout.title.text`
  in both modes (LaTeX/mathtext is rendered, see [`mathtext`](@ref)); `""`
  writes no title. (1.x wrote `"PlotlySupply"` here for `sync=false`.)
- `window_title::AbstractString=""`: title of the Electron window
  (`sync=true` only). `""` uses `title` when it is non-empty, otherwise
  `"PlotlySupply"`.
- `width::Real=0`, `height::Real=0`: figure size in CSS pixels, written to
  `layout.width`/`layout.height` in both modes and, with `sync=true`, used as
  the window size. `0` leaves the layout size automatic (the figure fills the
  window, which defaults to 960 × 720; `savefig` then uses its own default
  size). Negative or non-finite values throw an `ArgumentError`.
- `show::Bool=true`, `app=nothing`: window visibility and ElectronCall
  application (`sync=true` only; validated in both modes).
- `height_ratios=nothing`: relative row heights listed TOP-TO-BOTTOM as drawn
  (`[3, 1]` makes row 1 three times as tall as row 2); a vector or tuple with
  one positive finite number per row. Cannot be combined with `row_heights`;
  with `start_cell="bottom-left"` only equal ratios are accepted (PlotlyBase
  overlaps unequal rows there).
- `width_ratios=nothing`: relative column widths, LEFT-TO-RIGHT; one positive
  finite number per column. Cannot be combined with `column_widths`.
- `per_subplot_legends::Bool=true`: every cell gets its own legend inside the
  cell. `false` keeps one figure legend, placed and styled with the
  `legend_*` keywords below as soon as a named trace is added.
- `legend_position::Union{Symbol,AbstractString}`: legend placement inside
  each cell (or the figure), one of the [`set_legend!`](@ref) positions.
- `legend_inset=(0.02, 0.03)`: legend offset from the cell edges as fractions
  of the cell (2-tuple or 2-vector of finite numbers).
- `legend_bgcolor`, `legend_bordercolor` (String or Symbol colour, also a
  matplotlib grey level such as `"0.9"`), `legend_borderwidth::Real` (px):
  legend box style. `nothing` takes the active style's defaults, which for
  the default style are the 1.x `"rgba(255,255,255,0.72)"`,
  `"rgba(0,0,0,0.15)"` and `1` (darker on dark templates, transparent and 0
  for frameless styles).
- `subplot_kwargs...`: forwarded to `PlotlyBase.Subplots`: `specs`,
  `shared_xaxes`, `shared_yaxes`, `start_cell` (`"top-left"` or
  `"bottom-left"`), `subplot_titles` (a matrix, or a vector read in
  row-major order as in plotly.py), `column_titles`, `row_titles`,
  `x_title`, `y_title`, `insets`, `horizontal_spacing`, `vertical_spacing`
  (numbers in `[0, 1]` that must leave room for the cells),
  `column_widths` and `row_heights`. `row_heights` keeps PlotlyBase's order:
  for the default `start_cell="top-left"` its FIRST entry sizes the BOTTOM
  row; prefer `height_ratios`. Cell colorbars sit in the gap right of their
  cell, so widen `horizontal_spacing` when neighbouring cells crowd them.
- Grid titles (`subplot_titles`, `column_titles` — one string per column —,
  `row_titles` — one per row —, `x_title`, `y_title`) are text labels like
  [`title!`](@ref): `\$…\$` math mixed with text keeps the text and `\\n`
  breaks the line. `""` or `missing` leaves a cell untitled.
- Shared axes (`shared_xaxes`, `shared_yaxes`: `true`, `"rows"`,
  `"columns"`, `"all"`, as in plotly.py) form one `matches` group per
  column/row/figure; plotly draws every axis of a group with the root's
  range and type. Calls on any cell of a group act on the group: the axis
  type (`xscale = "log"`), tick placement and tick-label format are copied
  to every axis of the group, a range set on any cell (`xrange!`, the
  `xrange` keyword, `update_xaxes!(sf; row, col, range)`) becomes the
  group's range, and an axis title set on a cell whose tick labels are
  hidden goes to the cell that shows the group's tick labels in that column
  (x) or row (y). Secondary y axes are never part of a group.
- `insets`: a vector of `PlotlyBase.Inset(cell=(row, col), kind, l, w, b, h)`
  whose cells lie in the grid. Cartesian insets (`kind="xy"`, the default)
  are registered like the ones [`inset!`](@ref) adds: ids `1, 2, …` in the
  order they appear (before any `inset!` ids), targeted with `inset = k` by
  the `plot_*!` mutators and axis helpers; their tick labels do not push the
  figure margins and their traces are listed in the host cell's legend. For
  them `l`/`b` (in `[0, 1)`) and `w`/`h` (in `(0, 1]`, or `"to_end"`) are
  fractions of the host cell's plot area, `l + w` and `b + h` must not
  exceed 1, `colspan`/`rowspan` must be 1 and the host must be a Cartesian
  cell. Insets of other kinds (maps, scenes, ...) are passed to PlotlyBase
  unchanged and get no `inset` id.

Every option is validated before the figure (or window) is created; invalid
values throw an `ArgumentError`. Figure-level settings are not changed by the
per-cell `plot_*!` mutators: set them here or with `relayout!(sf; ...)`.

# Example
```julia
sf = subplots(2, 1; sync=false, title="Response", height_ratios=[3, 1],
	width=700, height=500)
plot_scatter!(sf, 0:0.1:10, sin.(0:0.1:10); row=1, col=1)
plot_scatter!(sf, 0:0.1:10, cos.(0:0.1:10); row=2, col=1)
```
"""
function subplots(
	rows::Integer,
	cols::Integer;
	sync::Bool = true,
	width::Real = 0,
	height::Real = 0,
	title::AbstractString = "",
	window_title::AbstractString = "",
	show::Bool = true,
	app = nothing,
	height_ratios = nothing,
	width_ratios = nothing,
	per_subplot_legends::Bool = true,
	legend_position::Union{Symbol, AbstractString} = get_default_legend_position(),
	legend_inset::Union{Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = _DEFAULT_LEGEND_INSET[],
	legend_bgcolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_bordercolor::Union{Nothing, AbstractString, Symbol} = nothing,
	legend_borderwidth::Union{Nothing, Real} = nothing,
	subplot_kwargs...,
)
	# Validate every option before a figure or window exists.
	(rows isa Bool || cols isa Bool) && throw(ArgumentError(
		"subplots: `rows` and `cols` must be integers, not Bool.",
	))
	for key in (:rows, :cols, :grid_ref)
		haskey(subplot_kwargs, key) && throw(ArgumentError(
			"subplots: `$(key)` is not a keyword; pass the grid shape " *
			"positionally as `subplots(rows, cols)`.",
		))
	end
	rows_i = Int(rows)
	cols_i = Int(cols)
	_check_subplot_dims(rows_i, cols_i)
	_require_size_option(width, "subplots", "width")
	_require_size_option(height, "subplots", "height")
	resolved_window_title = isempty(window_title) ? title : window_title
	# Pure validation of the window options (size limits, app/show types),
	# applied below only with sync = true.
	_syncplot_window_options(
		"subplots";
		app = app,
		width = width,
		height = height,
		title = resolved_window_title,
		show = show,
	)
	normalized_legend_position = _normalize_legend_position(legend_position)
	(length(legend_inset) == 2 && all(v -> !(v isa Bool) && isfinite(v), legend_inset)) ||
		throw(ArgumentError(
			"subplots: `legend_inset` must be two finite numbers (x, y); got " *
			"$(repr(legend_inset)).",
		))
	inset = (Float64(legend_inset[1]), Float64(legend_inset[2]))
	# Unset legend colours follow the active style and template (the 1.x
	# translucent white box under the default style; a dark box on dark
	# templates; transparent for frameless styles).
	legend_style = _style_legend_defaults()
	bgcolor = _subplots_legend_colour(legend_bgcolor, legend_style.bgcolor, "legend_bgcolor")
	bordercolor = _subplots_legend_colour(
		legend_bordercolor,
		legend_style.bordercolor,
		"legend_bordercolor",
	)
	borderwidth = legend_borderwidth === nothing ?
		Float64(legend_style.borderwidth) :
		legend_borderwidth
	(!(borderwidth isa Bool) && isfinite(borderwidth) && borderwidth >= 0) ||
		throw(ArgumentError(
			"subplots: `legend_borderwidth` must be a finite number ≥ 0; got " *
			"$(repr(legend_borderwidth)).",
		))
	grid_kwargs = _subplots_grid_kwargs(
		rows_i,
		cols_i,
		height_ratios,
		width_ratios,
		subplot_kwargs,
	)
	inset_fractions = _subplots_checked_insets(get(grid_kwargs, :insets, missing), rows_i, cols_i)
	grid = try
		Subplots(; rows = rows_i, cols = cols_i, grid_kwargs...)
	catch err
		# PlotlyBase checks start_cell, shared-axis modes and title counts
		# with @assert; report them as argument errors.
		err isa AssertionError || rethrow()
		throw(ArgumentError("subplots: invalid grid option: $(err.msg)"))
	end
	# The cell sizes PlotlyBase derived from the spacing (the horizontal room
	# also shrinks for secondary y axes and row titles) must stay positive.
	for (name, sizes) in (
		("horizontal_spacing", getfield(grid, :_widths)),
		("vertical_spacing", getfield(grid, :_heights)),
	)
		all(size -> size > 0, sizes) || throw(ArgumentError(
			"subplots: `$(name)` leaves no room for the cells; use a smaller value.",
		))
	end
	layout = _plotlysupply_subplot_layout(grid)

	# Build the complete model first, so a live window renders it once.
	p = Plot(Vector{GenericTrace}(undef, 0), layout)
	_apply_default_template!(p)
	inset_records = _subplots_register_insets!(p, inset_fractions)
	_apply_figure_title!(p, title)
	_apply_figure_size!(p, "subplots"; width = width, height = height)
	# Shared axes: keep every `matches` group autoranging (see finalize.jl).
	_finalize_figure!(p)
	fig = sync ?
		plot(
			p;
			sync = true,
			app = app,
			width = width,
			height = height,
			title = resolved_window_title,
			show = show,
		) :
		p

	return SubplotFigure(
		fig,
		rows_i,
		cols_i,
		1,
		1,
		per_subplot_legends,
		normalized_legend_position,
		inset,
		bgcolor,
		bordercolor,
		Float64(borderwidth),
		inset_records,
	)
end

"""
	subplot!(sf, row, col)
	subplot!(sf, index)

Set the active subplot cell in a `SubplotFigure` and return `sf`.

`subplot!(sf, row, col)` selects cell `(row, col)` (row 1 is the top row for
the default `start_cell="top-left"`). `subplot!(sf, index)` uses MATLAB's
row-major numbering: `index = (row - 1) * cols + col`, so in a 2 × 3 grid
index 4 is cell `(2, 1)`. Later `plot_*!`, `add_trace!`, `xlabel!`, ... calls
without `row`/`col` target the active cell. Selecting a cell changes no
figure data and never refreshes the window.

Out-of-range or `Bool` indices throw an `ArgumentError` and leave the active
cell unchanged. Empty cells (`specs` entries of `missing`) may be selected,
but plotting into them throws.
"""
function subplot!(sf::SubplotFigure, row::Integer, col::Integer)
	r, c = _resolve_subplot_cell(sf; row = row, col = col, who = "subplot!")
	lock(getfield(sf, :_lock)) do
		sf.current_row = r
		sf.current_col = c
	end
	return sf
end

function subplot!(sf::SubplotFigure, index::Integer)
	index isa Bool && throw(ArgumentError(
		"subplot!: `index` must be an integer, not Bool.",
	))
	count = sf.rows * sf.cols
	(1 <= index <= count) || throw(ArgumentError(
		"subplot!: `index` must be in 1:$(count); got $(index).",
	))
	row, col = _subplot_cell(sf, Int(index))
	return subplot!(sf, row, col)
end

# Delegate raw PlotlyBase verbs to the underlying figure so a SubplotFigure can
# be driven like a Plot/SyncPlot. The fig-level methods already handle the
# Electron refresh and their own transactions; `sf` is returned so calls remain
# chainable on the subplot. These verbs address traces by index or the whole
# layout, so they take no `row`/`col`: a cell keyword (`row`, `col`,
# `secondary_y`, `inset`) or `show` is an ArgumentError naming the verb, where
# PlotlyBase would have written it into the layout or traces as an attribute
# (or failed with a MethodError).
for f in (
	:relayout!,
	:react!,
	:restyle!,
	:update!,
	:redraw!,
	:deletetraces!,
	:movetraces!,
	:extendtraces!,
	:prependtraces!,
)
	@eval function PlotlyBase.$f(sf::SubplotFigure, args...; kwargs...)
		_verb_reject_cell_keywords($(String(f)), kwargs; whole_figure = true)
		PlotlyBase.$f(getfield(sf, :fig), args...; kwargs...)
		return sf
	end
end

# Layout key of the `family` object (`:xaxis`, `:yaxis`, `:polar`, `:scene`,
# `:ternary`) of one grid cell; `secondary_y` selects the cell's secondary y
# axis. Throws when the cell has no such object.
function _subplot_layout_object_key(
	p::Plot,
	row::Int,
	col::Int,
	family::Symbol,
	who::AbstractString;
	secondary_y::Bool = false,
)
	ref = _subplot_target_ref(p, row, col; secondary_y = secondary_y, who = who)
	kind = String(ref.subplot_kind)
	expected = family in (:xaxis, :yaxis) ? "xy" : String(family)
	kind == expected || throw(ArgumentError(
		"$(who): subplot cell ($(row), $(col)) is a '$(kind)' cell and has no " *
		"$(family) object.",
	))
	if family === :xaxis
		return ref.layout_keys[1]
	elseif family === :yaxis
		return ref.layout_keys[2]
	end
	return only(ref.layout_keys)
end

# Nested paths merged (not replaced) per layout object family. A function, not
# a constant: the path constants are defined further down in this file.
function _subplot_layout_object_merge_paths(family::Symbol)
	family in (:xaxis, :yaxis) && return _AXIS_LAYOUT_MERGE_PATHS
	family === :polar && return _POLAR_LAYOUT_MERGE_PATHS
	family === :scene && return _SCENE_LAYOUT_MERGE_PATHS
	family === :ternary && return _TERNARY_LAYOUT_MERGE_PATHS
	throw(ArgumentError("unsupported subplot layout object family `$(family)`."))
end

function _subplot_layout_object_update_impl!(
	sf::SubplotFigure,
	updater::Function,
	family::Symbol,
	who::AbstractString,
	with::PlotlyBase.PlotlyAttribute;
	row::Union{Nothing, Integer},
	col::Union{Nothing, Integer},
	secondary_y::Bool = false,
	inset = nothing,
	kwargs...,
)
	p = _plot_obj(sf.fig)
	if inset === nothing
		r, c = _resolve_subplot_cell(sf; row = row, col = col, who = who)
		key = _subplot_layout_object_key(
			p,
			r,
			c,
			family,
			who;
			secondary_y = secondary_y,
		)
	else
		# An inset's own x/y axis (its cell, when given, must host it).
		target = _cell_target(
			sf;
			row = row,
			col = col,
			secondary_y = secondary_y,
			inset = inset,
			who = who,
		)
		r, c = target.row, target.col
		key = family === :xaxis ? target.xkey : target.ykey
	end
	layout = p.layout
	# Run PlotlyBase's own updater on a scratch layout holding only this cell's
	# object, so `with`, `kwargs` and underscore paths (`title_text=...`) mean
	# exactly what they mean for the figure-wide update.
	temporary = Layout()
	existing = get(layout.fields, key, nothing)
	temporary.fields[family] = existing === nothing ? attr() : deepcopy(existing)
	updater(temporary, with; kwargs...)
	_merge_layout_attr!(
		layout,
		key,
		get(temporary.fields, family, nothing);
		drop_keys = (:domain,),
		deep_merge_paths = _subplot_layout_object_merge_paths(family),
		mutate_builtin_target = true,
	)
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

function _subplot_layout_object_update!(
	sf::SubplotFigure,
	updater::Function,
	family::Symbol,
	who::AbstractString,
	with::PlotlyBase.PlotlyAttribute,
	row,
	col,
	kwargs;
	secondary_y::Bool = false,
	inset = nothing,
)
	if row === nothing && col === nothing && inset === nothing
		secondary_y && throw(ArgumentError(
			"$(who): `secondary_y=true` selects one cell's secondary y axis; " *
			"pass `row` and `col`.",
		))
		updater(getfield(sf, :fig), with; kwargs...)
		return sf
	end
	(row === nothing) == (col === nothing) || throw(ArgumentError(
		"$(who): `row` and `col` must be provided together.",
	))
	_warn_ignored_subplot_domain(who, with, kwargs)
	return _transactional_subplot_mutation!(
		_subplot_layout_object_update_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		updater,
		family,
		who,
		with;
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		kwargs...,
	)
end

"""
	update_xaxes!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, inset=nothing, kwargs...)
	update_yaxes!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, secondary_y=false, inset=nothing, kwargs...)
	update_polars!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, kwargs...)
	update_scenes!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, kwargs...)
	update_ternaries!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, kwargs...)

Update layout objects of a [`SubplotFigure`](@ref). Keywords are Plotly
attributes of that object family (`showgrid=false`, `title_text="t"`, …).

- Without `row`/`col`: every object of the family in the whole figure is
  updated (as for a `Plot`); the active cell is unchanged.
- With `row` and `col` (pass both): only that cell's object is updated —
  its x axis, y axis (`secondary_y=true`: its secondary y axis), polar,
  scene or ternary — and the cell becomes the active cell. The cell must be
  of the matching kind, otherwise an `ArgumentError` is thrown and nothing
  changes. The grid owns cell domains, so a `domain` value is ignored with a
  warning. `row`/`col` are never written as attributes.
- `update_xaxes!`/`update_yaxes!` with `inset=k`: only the x (y) axis of
  inset `k` of `sf.insets` ([`inset!`](@ref), `subplots(...; insets)`) is
  updated, and its host cell becomes the active cell; `row`/`col` may be
  omitted (when given they must name the host cell). An unknown id, or
  `secondary_y=true` with an inset, is an `ArgumentError`.

Returns `sf`.

# Example
```julia
sf = subplots(1, 2; sync=false)
update_xaxes!(sf; showgrid=false)                 # every x axis
update_yaxes!(sf; row=1, col=2, type="log")       # only cell (1, 2)
k = inset!(sf, (0.6, 0.6, 0.35, 0.35); row=1, col=2)
update_xaxes!(sf; inset=k, type="log")            # only the inset's x axis
```
"""
function PlotlyBase.update_xaxes!(
	sf::SubplotFigure,
	with::PlotlyBase.PlotlyAttribute = attr();
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	inset = nothing,
	kwargs...,
)
	return _subplot_layout_object_update!(
		sf,
		PlotlyBase.update_xaxes!,
		:xaxis,
		"update_xaxes!",
		with,
		row,
		col,
		kwargs;
		inset = inset,
	)
end

function PlotlyBase.update_yaxes!(
	sf::SubplotFigure,
	with::PlotlyBase.PlotlyAttribute = attr();
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset = nothing,
	kwargs...,
)
	return _subplot_layout_object_update!(
		sf,
		PlotlyBase.update_yaxes!,
		:yaxis,
		"update_yaxes!",
		with,
		row,
		col,
		kwargs;
		secondary_y = secondary_y,
		inset = inset,
	)
end

for (updater, family) in (
	(:update_polars!, :polar),
	(:update_scenes!, :scene),
	(:update_ternaries!, :ternary),
)
	who = String(updater)
	doc = """
		$(who)(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, kwargs...)

	Without `row`/`col`, update every `$(family)` object of the figure; with
	both, update only that cell's `$(family)` object (an `ArgumentError` if the
	cell is of another kind) and make it the active cell. `domain` is ignored
	with a warning on a cell update. Returns `sf`. See
	[`update_xaxes!`](@ref) for the full SubplotFigure semantics.
	"""
	@eval begin
		@doc $doc function PlotlyBase.$updater(
			sf::SubplotFigure,
			with::PlotlyBase.PlotlyAttribute = attr();
			row::Union{Nothing, Integer} = nothing,
			col::Union{Nothing, Integer} = nothing,
			kwargs...,
		)
			return _subplot_layout_object_update!(
				sf,
				PlotlyBase.$updater,
				$(QuoteNode(family)),
				$who,
				with,
				row,
				col,
				kwargs,
			)
		end
	end
end

# `xref`/`yref` values of an annotation/shape/image that place it on one of
# `axis_refs` ("x3" or "x3 domain").
function _subplot_item_ref_matches(value, axis_refs)
	value isa AbstractString || return false
	base = endswith(value, " domain") ? value[1:(end - length(" domain"))] : value
	return base in axis_refs
end

function _subplot_layout_vector_update_impl!(
	sf::SubplotFigure,
	updater::Function,
	vector_key::Symbol,
	who::AbstractString,
	with::PlotlyBase.PlotlyAttribute;
	row::Integer,
	col::Integer,
	kwargs...,
)
	r, c = _resolve_subplot_cell(sf; row = row, col = col, who = who)
	p = _plot_obj(sf.fig)
	refs = p.layout.subplots.grid_ref
	(isassigned(refs, r, c) && !isempty(refs[r, c])) || throw(ArgumentError(
		"$(who): subplot cell ($(r), $(c)) is empty.",
	))
	cell_refs = refs[r, c]
	kind = String(first(cell_refs).subplot_kind)
	kind == "xy" || throw(ArgumentError(
		"$(who): subplot cell ($(r), $(c)) is a '$(kind)' cell; only " *
		"Cartesian cells own layout.$(vector_key) entries.",
	))
	xrefs = Set{String}()
	yrefs = Set{String}()
	for ref in cell_refs
		trace_refs = ref.trace_kwargs.fields
		push!(xrefs, String(trace_refs[:xaxis]))
		push!(yrefs, String(trace_refs[:yaxis]))
	end
	items = get(p.layout.fields, vector_key, nothing)
	if items isa AbstractVector
		# `Shape` entries (PlotlyBase's `rect`/`line`/`hline`, the shape verbs)
		# keep their attributes in `fields`, like `attr(...)` entries.
		item_field(item, name) =
			_cmn_mapping_get(item isa PlotlyBase.Shape ? item.fields : item, name)
		selected = [
			index for index in eachindex(items)
			if _subplot_item_ref_matches(item_field(items[index], :xref), xrefs) &&
				_subplot_item_ref_matches(item_field(items[index], :yref), yrefs)
		]
		if !isempty(selected)
			# Apply PlotlyBase's own merge to copies of the selected entries,
			# then publish them in their original positions.
			temporary = Layout()
			temporary.fields[vector_key] =
				Any[deepcopy(items[index]) for index in selected]
			updater(temporary, with; kwargs...)
			updated = temporary.fields[vector_key]
			for (position, index) in enumerate(selected)
				items[index] = updated[position]
			end
		end
	end
	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

for (updater, vector_key) in (
	(:update_annotations!, :annotations),
	(:update_shapes!, :shapes),
	(:update_images!, :images),
)
	who = String(updater)
	doc = """
		$(who)(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, kwargs...)

	Merge `with` and the attribute keywords into entries of
	`layout.$(vector_key)` of a [`SubplotFigure`](@ref).

	- Without `row`/`col`: every entry is updated (as for a `Plot`).
	- With `row` and `col` (pass both): only entries placed on that Cartesian
	  cell — `xref` and `yref` both name one of the cell's axes, with or
	  without the `" domain"` suffix (secondary y included) — are updated, and
	  the cell becomes the active cell. Paper-referenced entries and entries
	  without explicit `xref`/`yref` belong to no cell. A non-Cartesian cell
	  throws an `ArgumentError`.

	Returns `sf`.
	"""
	@eval begin
		@doc $doc function PlotlyBase.$updater(
			sf::SubplotFigure,
			with::PlotlyBase.PlotlyAttribute = attr();
			row::Union{Nothing, Integer} = nothing,
			col::Union{Nothing, Integer} = nothing,
			kwargs...,
		)
			if row === nothing && col === nothing
				PlotlyBase.$updater(getfield(sf, :fig), with; kwargs...)
				return sf
			end
			(row === nothing || col === nothing) && throw(ArgumentError(
				$(who * ": `row` and `col` must be provided together."),
			))
			return _transactional_subplot_mutation!(
				_subplot_layout_vector_update_impl!,
				sf,
				_SUBPLOT_SELECTION_METADATA_FIELDS,
				PlotlyBase.$updater,
				$(QuoteNode(vector_key)),
				$who,
				with;
				row = row,
				col = col,
				kwargs...,
			)
		end
	end
end

# ── PlotlyBase shape/image verbs: add_hline!, add_vline!, add_hrect!,
# add_vrect!, add_shape!, add_layout_image!, add_recession_bands! ──────────
#
# PlotlyBase writes every keyword of these verbs into the new shape, so a
# `show`, `secondary_y` or `inset` keyword silently became a junk attribute,
# and it has no SubplotFigure methods (G26). The helpers below are shared by
# the SubplotFigure methods (here) and the Plot/SyncPlot methods
# (plotlyjs_compat.jl): they validate the call before anything changes and
# place the items on the axes of the selected cells.

# Keywords that select a SubplotFigure cell (or ask for a window). PlotlyBase's
# layout updaters and shape verbs on a Plot/SyncPlot would write them as
# attributes (`xaxis.row = 1`), so they are rejected there (Y31).
const _VERB_CELL_KEYWORDS = (:row, :col, :secondary_y, :inset)

function _verb_reject_show(who::AbstractString, kwargs)
	haskey(kwargs, :show) && throw(ArgumentError(
		"$(who): figure verbs do not take `show`; display the figure with " *
		"`display(fig)` (or create it with `show = true`).",
	))
	return nothing
end

"""
	_verb_reject_cell_keywords(who, kwargs; allow = (), whole_figure = false)

Throw an `ArgumentError` prefixed with `who` when `kwargs` holds `show` or a
SubplotFigure cell keyword (`row`, `col`, `secondary_y`, `inset`) that is not
listed in `allow`. The Plot/SyncPlot methods of the PlotlyBase layout updaters
(`update_xaxes!`, ..., `update_images!`) call it first: PlotlyBase would write
these keywords into the layout as attributes. `whole_figure = true` words the
error for a SubplotFigure verb that acts on the whole figure (`relayout!`,
`restyle!`, ...).
"""
function _verb_reject_cell_keywords(who::AbstractString, kwargs; allow = (), whole_figure::Bool = false)
	_verb_reject_show(who, kwargs)
	for key in _VERB_CELL_KEYWORDS
		key in allow && continue
		haskey(kwargs, key) || continue
		throw(ArgumentError(
			whole_figure ?
				"$(who): `$(key)` selects a cell, but `$(who)` acts on the whole " *
				"SubplotFigure (traces by index, layout by attribute path); use " *
				"the cell-aware verbs (`update_xaxes!(sf; row, col, ...)`, " *
				"`plot_*!(sf, ...; row, col)`, ...) to address one cell." :
				"$(who): `$(key)` selects a cell of a SubplotFigure (see " *
				"`subplots`); a Plot or SyncPlot has no cells to select, and " *
				"PlotlyBase would write `$(key)` into the layout as an attribute.",
		))
	end
	return nothing
end

# Layout vector and placement of each verb (PlotlyBase's directions): 'h' spans
# the cell horizontally (x as a fraction of the axis domain, y in data), 'v'
# vertically, 'X' places the item in data coordinates on both axes (a "paper"
# or "<axis> domain" reference of the item becomes a fraction of the cell),
# 'I' places it in domain fractions of both axes.
const _VERB_LAYOUT_ITEM_VERBS = (
	(:add_hline!, :shapes, 'h', ("y",)),
	(:add_vline!, :shapes, 'v', ("x",)),
	(:add_hrect!, :shapes, 'h', ("y0", "y1")),
	(:add_vrect!, :shapes, 'v', ("x0", "x1")),
	(:add_shape!, :shapes, 'X', ("shape",)),
	(:add_layout_image!, :images, 'I', ("image",)),
)

function _verb_item_spec(verb::Symbol)
	for spec in _VERB_LAYOUT_ITEM_VERBS
		spec[1] === verb && return spec
	end
	throw(ArgumentError("unknown layout item verb `$(verb)`."))
end

# A coordinate of add_hline!/add_vline!/add_hrect!/add_vrect!: a finite number,
# a date/category value (String, Date, ...) or a non-empty vector of them (one
# item per entry, as PlotlyBase's `hline`/`rect` build). `nothing`, `missing`,
# Bool and non-finite numbers would draw nothing or garbage.
function _verb_check_coordinate(value, name::AbstractString, who::AbstractString)
	values = value isa AbstractVector ? value : (value,)
	value isa AbstractVector && isempty(value) && throw(ArgumentError(
		"$(who): `$(name)` is an empty vector; pass at least one coordinate.",
	))
	for v in values
		bad = v === nothing || v === missing || v isa Bool ||
			(v isa Real && !isfinite(v)) || v isa AbstractVector
		bad && throw(ArgumentError(
			"$(who): `$(name)` must be a finite number, a date/category value " *
			"or a vector of them; got $(repr(value)).",
		))
	end
	return nothing
end

function _verb_check_item(item, who::AbstractString)
	if item isa AbstractDict
		return PlotlyBase.PlotlyAttribute(Dict{Symbol, Any}(Symbol(k) => v for (k, v) in item))
	end
	(item isa PlotlyBase.Shape || item isa PlotlyBase.PlotlyAttribute) || throw(ArgumentError(
		"$(who): expected a `Shape` (`rect(...)`, `line(...)`, `circle(...)`, " *
		"`path(...)`), an `attr(...)` or a vector of them; got $(typeof(item)).",
	))
	return item
end

# The items a verb adds, built and validated before anything changes:
# returns (layout key, direction, items). `args` are the verb's positional
# arguments after the figure; `kwargs` its attribute keywords.
function _verb_layout_items(verb::Symbol, who::AbstractString, args, kwargs)
	_, key, direction, names = _verb_item_spec(verb)
	length(args) == length(names) || throw(ArgumentError(
		"$(who): expected $(length(names)) positional argument(s) after the " *
		"figure ($(join(names, ", "))); got $(length(args)).",
	))
	_verb_reject_show(who, kwargs)
	for ref in (:xref, :yref)
		haskey(kwargs, ref) && throw(ArgumentError(
			"$(who): `$(ref)` is set from the target cell's axes; select the " *
			"cell with `row`/`col` (SubplotFigure: also `secondary_y`, `inset`).",
		))
	end
	base = if verb === :add_shape! || verb === :add_layout_image!
		isempty(kwargs) || throw(ArgumentError(
			"$(who): unsupported keyword argument(s) " *
			"$(join(("`$(k)`" for k in keys(kwargs)), ", ")); set the attributes " *
			"on the $(verb === :add_shape! ? "shape" : "image") itself.",
		))
		args[1]
	else
		for (value, name) in zip(args, names)
			_verb_check_coordinate(value, name, who)
		end
		if verb === :add_hline!
			PlotlyBase.hline(args[1]; kwargs...)
		elseif verb === :add_vline!
			PlotlyBase.vline(args[1]; kwargs...)
		elseif verb === :add_hrect!
			PlotlyBase.rect(0, 1, args[1], args[2]; kwargs...)
		else
			PlotlyBase.rect(args[1], args[2], 0, 1; kwargs...)
		end
	end
	raw = base isa AbstractVector ? base : (base,)
	isempty(raw) && throw(ArgumentError("$(who): nothing to add (an empty vector)."))
	items = Any[_verb_check_item(item, who) for item in raw]
	return key, direction, items
end

_verb_domain_ref(current, axis::AbstractString) =
	(current isa AbstractString && (current == "paper" || endswith(current, " domain"))) ?
		axis * " domain" : String(axis)

# Copies of `items` placed on the axes `xref`/`yref` ("x2", "y3", ...).
function _verb_place_items(items, direction::Char, xref::AbstractString, yref::AbstractString)
	placed = Vector{Any}(undef, length(items))
	for (index, item) in enumerate(items)
		copy_item = deepcopy(item)
		fields = copy_item.fields
		if direction == 'h'
			fields[:xref] = xref * " domain"
			fields[:yref] = String(yref)
		elseif direction == 'v'
			fields[:xref] = String(xref)
			fields[:yref] = yref * " domain"
		elseif direction == 'I'
			fields[:xref] = xref * " domain"
			fields[:yref] = yref * " domain"
		else
			fields[:xref] = _verb_domain_ref(get(fields, :xref, nothing), xref)
			fields[:yref] = _verb_domain_ref(get(fields, :yref, nothing), yref)
		end
		placed[index] = copy_item
	end
	return placed
end

# Append the items, placed on every (xref, yref) target, to `layout.<key>`.
# The layout vector is replaced, never mutated in place (a staged figure may
# share it with the live one).
function _verb_append_layout_items!(layout::Layout, key::Symbol, direction::Char, items, targets)
	existing = get(layout.fields, key, nothing)
	combined = Any[]
	if existing isa AbstractVector
		append!(combined, existing)
	elseif existing !== nothing
		push!(combined, existing)
	end
	for (xref, yref) in targets
		append!(combined, _verb_place_items(items, direction, xref, yref))
	end
	layout.fields[key] = combined
	return layout
end

# PlotlyBase `row`/`col` of a Plot: "all" (or `:`), an index or a vector of
# indices into its subplot grid.
function _verb_plot_indices(value, count::Int, name::AbstractString, who::AbstractString)
	(value isa Colon || (value isa AbstractString && value == "all")) && return collect(1:count)
	ok(i) = i isa Integer && !(i isa Bool) && 1 <= i <= count
	value isa Integer && ok(value) && return [Int(value)]
	value isa AbstractVector && !isempty(value) && all(ok, value) && return Int[v for v in value]
	throw(ArgumentError(
		"$(who): `$(name)` must be \"all\", an integer in 1:$(count) or a " *
		"vector of them (the figure's subplot grid has $(count) " *
		"$(name == "row" ? "row" : "column")(s)); got $(repr(value)).",
	))
end

# (xref, yref) of the Cartesian cells of a Plot's subplot grid that PlotlyBase's
# `row`/`col` select (column-major, as PlotlyBase iterates them). Blank and
# non-Cartesian cells are skipped when several cells are selected and are an
# ArgumentError when the call names exactly that cell.
function _verb_plot_cell_refs(p::Plot, row, col, who::AbstractString)
	grid_ref = p.layout.subplots.grid_ref
	rows = _verb_plot_indices(row, size(grid_ref, 1), "row", who)
	cols = _verb_plot_indices(col, size(grid_ref, 2), "col", who)
	single = length(rows) == 1 && length(cols) == 1 && row isa Integer && col isa Integer
	targets = Tuple{String, String}[]
	for c in cols, r in rows
		if !isassigned(grid_ref, r, c) || isempty(grid_ref[r, c])
			single && throw(ArgumentError("$(who): subplot cell ($(r), $(c)) is empty."))
			continue
		end
		ref = first(grid_ref[r, c])
		kind = String(ref.subplot_kind)
		if kind != "xy" || length(ref.layout_keys) < 2
			single && throw(ArgumentError(
				"$(who): subplot cell ($(r), $(c)) is a '$(kind)' cell; shapes " *
				"and images need Cartesian x/y axes.",
			))
			continue
		end
		refs = ref.trace_kwargs.fields
		push!(targets, (
			String(get(refs, :xaxis, _fin_axis_ref(ref.layout_keys[1]))),
			String(get(refs, :yaxis, _fin_axis_ref(ref.layout_keys[2]))),
		))
	end
	isempty(targets) && throw(ArgumentError(
		"$(who): no Cartesian (x/y) cell matches row = $(repr(row)), col = $(repr(col)).",
	))
	return targets
end

# Validated SubplotFigure `row`/`col` value: `nothing`, an integer or "all".
function _verb_subplot_selector(value, name::AbstractString, who::AbstractString)
	(value === nothing || (value isa Integer && !(value isa Bool))) && return value
	value isa AbstractString && value == "all" && return value
	throw(ArgumentError(
		"$(who): `$(name)` must be an integer, \"all\" or `nothing` (the " *
		"active cell); got $(repr(value)).",
	))
end

# Targets (`_CellTarget`s, all Cartesian) of a SubplotFigure verb and the cell
# that becomes active (`nothing` for "all"): the active cell, the cell
# `row`/`col` (its secondary y axis with `secondary_y`), inset `inset`, or with
# "all" every Cartesian cell of the selected rows/columns (blank cells, cells
# of other kinds and, with `secondary_y`, cells without a secondary y axis are
# skipped).
function _verb_subplot_targets(sf::SubplotFigure, row, col, secondary_y::Bool, inset, who::AbstractString)
	row = _verb_subplot_selector(row, "row", who)
	col = _verb_subplot_selector(col, "col", who)
	if row isa AbstractString || col isa AbstractString
		(row === nothing || col === nothing) && throw(ArgumentError(
			"$(who): `row` and `col` must be provided together.",
		))
		inset === nothing || throw(ArgumentError(
			"$(who): `inset` selects one inset; it cannot be combined with " *
			"`row`/`col` = \"all\".",
		))
		rows = row isa AbstractString ? (1:sf.rows) : (row,)
		cols = col isa AbstractString ? (1:sf.cols) : (col,)
		row isa Integer && !(1 <= row <= sf.rows) && throw(ArgumentError(
			"$(who): `row` must be in 1:$(sf.rows); got $(row).",
		))
		col isa Integer && !(1 <= col <= sf.cols) && throw(ArgumentError(
			"$(who): `col` must be in 1:$(sf.cols); got $(col).",
		))
		grid_ref = _plot_obj(sf.fig).layout.subplots.grid_ref
		targets = _CellTarget[]
		for r in rows, c in cols
			(isassigned(grid_ref, r, c) && !isempty(grid_ref[r, c])) || continue
			refs = grid_ref[r, c]
			String(first(refs).subplot_kind) == "xy" || continue
			secondary_y && length(refs) < 2 && continue
			push!(targets, _cell_target(sf; row = r, col = c, secondary_y = secondary_y, who = who))
		end
		isempty(targets) && throw(ArgumentError(
			"$(who): no Cartesian (x/y) cell$(secondary_y ? " with a secondary y axis" : "") " *
			"matches row = $(repr(row)), col = $(repr(col)).",
		))
		return targets, nothing
	end
	t = _cell_target(sf; row = row, col = col, secondary_y = secondary_y, inset = inset, who = who)
	t.kind === :xy || throw(ArgumentError(
		"$(who): subplot cell ($(t.row), $(t.col)) is a :$(t.kind) cell; shapes " *
		"and images need Cartesian x/y axes.",
	))
	return [t], (t.row, t.col)
end

function _verb_subplot_add_items_impl!(
	sf::SubplotFigure,
	key::Symbol,
	direction::Char,
	items;
	row,
	col,
	secondary_y::Bool,
	inset,
	who::AbstractString,
)
	targets, active = _verb_subplot_targets(sf, row, col, secondary_y, inset, who)
	p = _plot_obj(sf.fig)
	_verb_append_layout_items!(p.layout, key, direction, items, ((t.xref, t.yref) for t in targets))
	if active !== nothing
		sf.current_row, sf.current_col = active
	end
	_refresh!(sf.fig)
	return sf
end

# Placement sentence of each verb's SubplotFigure docstring.
const _VERB_PLACEMENT_DOCS = Dict(
	:add_hline! => "a line across the cell's full width at data value `y` of its y axis",
	:add_vline! => "a line across the cell's full height at data value `x` of its x axis",
	:add_hrect! => "a band across the cell's full width between data values `y0` and `y1`",
	:add_vrect! => "a band across the cell's full height between data values `x0` and `x1`",
	:add_shape! => "`shape` in data coordinates of the cell's axes (an `xref`/`yref` of " *
		"`\"paper\"` or `\"… domain\"` on the shape becomes a fraction of the cell)",
	:add_layout_image! => "`image` with `x`, `y`, `sizex`, `sizey` as fractions of the " *
		"cell's plot area",
)

const _VERB_ATTRIBUTE_DOCS =
	"`attributes...` are shape attributes (`line_color = \"red\"`, " *
	"`line_dash = \"dash\"`, `fillcolor`, `opacity`, `layer`, ...); a vector of " *
	"coordinates adds one shape per entry."

for (verb, _, _, names) in _VERB_LAYOUT_ITEM_VERBS
	who = String(verb)
	signature = join(names, ", ")
	whole_item = verb in (:add_shape!, :add_layout_image!)
	attrs = whole_item ? "" : ", attributes..."
	attribute_doc = whole_item ?
		"The item is given whole; attribute keywords are an `ArgumentError`." :
		_VERB_ATTRIBUTE_DOCS
	placement = _VERB_PLACEMENT_DOCS[verb]
	doc = """
		$(who)(sf::SubplotFigure, $(signature); row=nothing, col=nothing, secondary_y=false, inset=nothing$(attrs))

	PlotlyBase's `$(who)` on cells of a [`SubplotFigure`](@ref): adds
	$(placement). On a logarithmic axis shape coordinates are data values
	(plotly converts them).

	- Without `row`/`col`: the active cell. With both: that cell, which becomes
	  the active cell. `row = "all"` and/or `col = "all"`: every Cartesian cell
	  of those rows/columns (blank and non-Cartesian cells are skipped; the
	  active cell is unchanged).
	- `secondary_y = true`: the cell's secondary y axis; `inset = k`: the axes
	  of inset `k` (`row`/`col` may then be omitted).
	- $(attribute_doc)

	`xref`/`yref`, `show`, an unknown cell, a non-Cartesian cell, `nothing`/`NaN`
	coordinates and the wrong number of arguments are `ArgumentError`s; the
	figure is then unchanged. Returns `sf`.

	# Example
	```julia
	sf = subplots(2, 2; sync = false)
	plot_scatter!(sf, 1:10, rand(10); row = 2, col = 2)
	add_hline!(sf, 0.5; row = 2, col = 2, line_dash = "dash")
	add_vrect!(sf, 2, 4; row = "all", col = 1, fillcolor = "LightGray", opacity = 0.3, line_width = 0)
	```
	"""
	@eval begin
		@doc $doc function PlotlyBase.$verb(
			sf::SubplotFigure,
			args...;
			row = nothing,
			col = nothing,
			secondary_y::Bool = false,
			inset = nothing,
			kwargs...,
		)
			key, direction, items = _verb_layout_items($(QuoteNode(verb)), $who, args, kwargs)
			return _transactional_subplot_mutation!(
				_verb_subplot_add_items_impl!,
				sf,
				_SUBPLOT_SELECTION_METADATA_FIELDS,
				key,
				direction,
				items;
				row = row,
				col = col,
				secondary_y = secondary_y,
				inset = inset,
				who = $who,
			)
		end
	end
end

# Recession-band shapes (PlotlyBase's NBER table) for the traces with date x
# values on `xref`, placed on the cell (x in data, y over the cell's height);
# `nothing` when no such trace has dates in a recession period's span.
function _verb_recession_shapes(p::Plot, xref::AbstractString, yref::AbstractString, kwargs)
	probe = Plot(GenericTrace[])
	for trace in p.data
		trace isa GenericTrace || continue
		String(string(get(trace.fields, :xaxis, "x"))) == xref || continue
		x = get(trace.fields, :x, nothing)
		x isa AbstractVector || continue
		isempty(x) && continue
		push!(probe.data, GenericTrace(Dict{Symbol, Any}(:type => "scatter", :x => x)))
	end
	isempty(probe.data) && return nothing
	bands = PlotlyBase._recession_band_shapes(probe; kwargs...)
	bands === nothing && return nothing
	items = bands isa AbstractVector ? collect(Any, bands) : Any[bands]
	isempty(items) && return nothing
	for item in items
		item.fields[:xref] = String(xref)
		item.fields[:yref] = yref * " domain"
		item.fields[:y0] = 0
		item.fields[:y1] = 1
	end
	return items
end

function _verb_subplot_recession_impl!(
	sf::SubplotFigure;
	row,
	col,
	secondary_y::Bool,
	inset,
	band_kwargs,
)
	who = "add_recession_bands!"
	targets, active = _verb_subplot_targets(sf, row, col, secondary_y, inset, who)
	p = _plot_obj(sf.fig)
	shapes = Any[]
	for t in targets
		items = _verb_recession_shapes(p, t.xref, t.yref, band_kwargs)
		items === nothing || append!(shapes, items)
	end
	isempty(shapes) && throw(ArgumentError(
		"$(who): no trace on the selected cell(s) has date x values inside the " *
		"span of the US recession table; nothing to mark.",
	))
	existing = get(p.layout.fields, :shapes, nothing)
	combined = Any[]
	existing isa AbstractVector ? append!(combined, existing) :
		existing === nothing || push!(combined, existing)
	append!(combined, shapes)
	p.layout.fields[:shapes] = combined
	if active !== nothing
		sf.current_row, sf.current_col = active
	end
	_refresh!(sf.fig)
	return sf
end

"""
	add_recession_bands!(sf::SubplotFigure; row=nothing, col=nothing, secondary_y=false, inset=nothing, attributes...)

PlotlyBase's `add_recession_bands!` on cells of a [`SubplotFigure`](@ref):
shades the US (NBER) recessions that fall inside the date span of the traces
on the cell's x axis, over the cell's full height. Cell selection as for
[`add_hline!`](@ref) (`row = "all"`/`col = "all"` marks every Cartesian cell
of those rows/columns that has date data). `attributes...` override the band
style (default `fillcolor = "#E6E6E6"`, `opacity = 0.4`, `line_width = 0`,
`layer = "below"`). No date data in the selected cells, `xref`/`yref` or `show`
is an `ArgumentError`. Returns `sf`.
"""
function PlotlyBase.add_recession_bands!(
	sf::SubplotFigure;
	row = nothing,
	col = nothing,
	secondary_y::Bool = false,
	inset = nothing,
	kwargs...,
)
	who = "add_recession_bands!"
	_verb_reject_show(who, kwargs)
	for ref in (:xref, :yref)
		haskey(kwargs, ref) && throw(ArgumentError(
			"$(who): `$(ref)` is set from the target cell's axes; select the cell " *
			"with `row`/`col`.",
		))
	end
	return _transactional_subplot_mutation!(
		_verb_subplot_recession_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS;
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		band_kwargs = kwargs,
	)
end

function _subplot_purge_impl!(sf::SubplotFigure)
	p = _plot_obj(sf.fig)
	# Rebuild the same grid (specs, spacing, ratios, titles) from the stored
	# PlotlyBase.Subplots with a fresh routing table, then restyle it like a
	# new `subplots(...)` figure.
	fresh = _plotlysupply_subplot_layout(
		_rebuild_subplots(p.layout.subplots),
	)
	empty!(p.data)
	empty!(p.layout.fields)
	merge!(p.layout.fields, fresh.fields)
	p.layout.subplots = fresh.subplots
	_apply_default_template!(p)
	# Insets added with `inset!` go; those of `subplots(...; insets)` are part
	# of the grid and are registered again.
	empty!(sf.insets)
	append!(
		sf.insets,
		_subplots_register_insets!(
			p,
			_subplots_checked_insets(p.layout.subplots.insets, sf.rows, sf.cols),
		),
	)
	sf.current_row = 1
	sf.current_col = 1
	_refresh!(sf.fig)
	return sf
end

"""
	purge!(sf::SubplotFigure)

Remove every trace and every layout setting of `sf` but keep its grid: the
figure is reset to the empty grid `subplots(...)` created (same specs,
spacing, ratios and subplot titles, default template), insets added with
[`inset!`](@ref) are dropped (the `subplots(...; insets)` ones belong to the
grid and stay registered) and cell `(1, 1)` becomes active. A figure title or size set by
`subplots(...; title, width, height)` is removed too. A live window is
redrawn in one transaction. Returns `sf`. `purge!` acts on the whole figure:
any keyword (`row`, `col`, `show`, ...) is an `ArgumentError`.
"""
function PlotlyBase.purge!(sf::SubplotFigure; kwargs...)
	_verb_reject_cell_keywords("purge!", kwargs; whole_figure = true)
	isempty(kwargs) || throw(ArgumentError(
		"purge!: unsupported keyword argument(s) " *
		"$(join(("`$(k)`" for k in keys(kwargs)), ", ")); purge! takes only the figure.",
	))
	return _transactional_subplot_mutation!(
		_subplot_purge_impl!,
		sf,
		_SUBPLOT_INSET_METADATA_FIELDS,
	)
end

"""
	isopen(sf::SubplotFigure) -> Bool

`true` while the Electron window of a `subplots(...; sync=true)` figure is
open; always `false` for a figure built with `sync=false` (it has no window).
"""
function Base.isopen(sf::SubplotFigure)
	fig = getfield(sf, :fig)
	return fig isa SyncPlot ? isopen(fig) : false
end

"""
	close(sf::SubplotFigure) -> nothing

Close the Electron window of a `subplots(...; sync=true)` figure. A figure
built with `sync=false` has no window, so this is a no-op for it. The figure
model (`sf.plot`) stays usable after the window is closed.
"""
function Base.close(sf::SubplotFigure)
	fig = getfield(sf, :fig)
	fig isa SyncPlot && close(fig)
	return nothing
end

savefig(sf::SubplotFigure, args...; kwargs...) = savefig(getfield(sf, :fig), args...; kwargs...)
savefig(io::IO, sf::SubplotFigure; kwargs...) = savefig(io, getfield(sf, :fig); kwargs...)
savefig(filename::AbstractString, sf::SubplotFigure; kwargs...) = savefig(filename, getfield(sf, :fig); kwargs...)

function _subplot_window_figure(sf::SubplotFigure, who::AbstractString)
	fig = getfield(sf, :fig)
	fig isa SyncPlot || throw(ArgumentError(
		"$(who): this SubplotFigure was created with `sync=false` and has no " *
		"window to render in. Use `savefig(sf, \"figure.png\")` (or " *
		"`savefig(io, sf; format=\"png\")`) to render it.",
	))
	return fig
end

"""
	to_image(sf::SubplotFigure; kwargs...) -> String
	download_image(sf::SubplotFigure; kwargs...) -> nothing

Render a `subplots(...; sync=true)` figure in its window (see
`to_image(::SyncPlot)` / `download_image(::SyncPlot)`). A figure created with
`sync=false` has no window: both throw an `ArgumentError` pointing to
`savefig` instead of returning `nothing`.
"""
function PlotlyBase.to_image(sf::SubplotFigure; kwargs...)
	return PlotlyBase.to_image(_subplot_window_figure(sf, "to_image"); kwargs...)
end

function PlotlyBase.download_image(sf::SubplotFigure; kwargs...)
	PlotlyBase.download_image(
		_subplot_window_figure(sf, "download_image");
		kwargs...,
	)
	return nothing
end

# The routing reference (axis/scene ids and subplot kind) of grid cell
# (row, col); `secondary_y` selects the cell's secondary y axis. Errors are
# prefixed with `who`.
function _subplot_target_ref(
	p::Plot,
	row::Int,
	col::Int;
	secondary_y::Bool = false,
	who::AbstractString = "SubplotFigure",
)
	grid_ref = p.layout.subplots.grid_ref
	if !checkbounds(Bool, grid_ref, row, col) || !isassigned(grid_ref, row, col) ||
			isempty(grid_ref[row, col])
		throw(ArgumentError(
			"$(who): subplot cell ($(row), $(col)) is empty (its `specs` entry " *
			"is `missing`, or a spanning cell covers it).",
		))
	end

	refs = grid_ref[row, col]
	if secondary_y && (refs[1].subplot_kind != "xy" || length(refs) < 2)
		throw(ArgumentError(
			"$(who): subplot cell ($(row), $(col)) has no secondary y-axis; " *
			"create the grid with `specs` containing `Spec(secondary_y=true)` " *
			"for that cell.",
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

# Check that every trace can be drawn in cell (row, col) (its subplot kind
# matches the cell's) and return the cell's routing reference. Nothing is
# modified; errors are prefixed with `who`.
function _validate_subplot_traces!(
	p::Plot,
	traces,
	row::Int,
	col::Int;
	secondary_y::Bool = false,
	who::AbstractString = "SubplotFigure",
)
	target_ref = _subplot_target_ref(p, row, col; secondary_y = secondary_y, who = who)
	target_kind = target_ref.subplot_kind
	for trace in traces
		trace isa GenericTrace || throw(ArgumentError(
			"$(who): only PlotlyBase.GenericTrace values can be added to a " *
			"subplot; got $(typeof(trace)).",
		))
		required_kind, trace_type = _trace_subplot_kind(trace)
		required_kind == target_kind || throw(ArgumentError(
			"$(who): trace type '$trace_type' requires a '$required_kind' subplot, " *
			"but cell ($(row), $(col)) is '$target_kind'.",
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
	r, c = _resolve_subplot_cell(sf; row = row, col = col, who = "add_trace!")
	p = _plot_obj(sf.fig)
	_validate_subplot_traces!(p, (trace,), r, c; secondary_y = secondary_y, who = "add_trace!")
	PlotlyBase.add_trace!(p, trace; row = r, col = c, secondary_y = secondary_y)
	_refresh_subplot_legends!(sf, p; first_new = length(p.data), auto = true)

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
	index::Union{Nothing, Int} = nothing,
)
	isempty(traces) && return sf

	r, c = _resolve_subplot_cell(sf; row = row, col = col, who = "addtraces!")
	p = _plot_obj(sf.fig)
	if index !== nothing
		1 <= index <= length(p.data) + 1 || throw(ArgumentError(
			"addtraces!: insertion index must be in 1:$(length(p.data) + 1); " *
			"got $(index).",
		))
	end
	_validate_subplot_traces!(p, traces, r, c; secondary_y = secondary_y, who = "addtraces!")

	# PlotlyBase.add_trace! deep-copies each trace and merges the selected
	# subplot references. Stage the whole batch so a bad later trace or subplot
	# reference cannot leave a partially appended figure.
	staged = Plot(p.layout)
	sizehint!(staged.data, length(traces))
	for trace in traces
		PlotlyBase.add_trace!(staged, trace; row = r, col = c, secondary_y = secondary_y)
	end
	first_new = if index === nothing
		append!(p.data, staged.data)
		length(p.data) - length(staged.data) + 1
	else
		# Same order as PlotlyBase's addtraces!(p, i, traces...): the first
		# new trace lands at position `index`.
		splice!(p.data, index:(index - 1), staged.data)
		index
	end
	_refresh_subplot_legends!(sf, p; first_new = first_new, auto = true)

	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

"""
	addtraces!(sf::SubplotFigure, traces...; row=nothing, col=nothing, secondary_y=false)
	addtraces!(sf::SubplotFigure, i::Int, traces...; row=nothing, col=nothing, secondary_y=false)

Add `traces` to one cell of `sf` — the cell given by `row`/`col` (pass both)
or the active cell — routed to that cell's axes (`secondary_y=true`: its
secondary y axis). The second form inserts them at trace position `i`
(`1 ≤ i ≤ length(sf.data) + 1`) instead of appending. Every trace is checked
against the cell kind before anything changes; the cell becomes the active
cell. Returns `sf`.
"""
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

function PlotlyBase.addtraces!(
	sf::SubplotFigure,
	i::Int,
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
		index = i,
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

# A nested layout value in the form the deep merge expects, for both the
# incoming and the existing side: a bare-string `title` is promoted to
# `attr(text = ...)` (plotly's shorthand); every other value is unchanged.
function _normalize_nested_layout_value(
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

		source_nested = _normalize_nested_layout_value(
			nested_key,
			source_dict[nested_key],
		)
		source_dict[nested_key] = source_nested
		_is_layout_mapping(source_nested) || continue

		existing_nested = _normalize_nested_layout_value(
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

# Axis-reference attributes a transplanted primary axis can carry
# (`_apply_equal_aspect!` writes `scaleanchor`, shared axes write `matches`,
# twins write `overlaying`). They name the scratch figure's axes; every routed
# trace uses the target cell's axes, so an "x…" reference becomes the cell's
# x axis and a "y…" reference its y axis. A reference to the axis itself is
# dropped (plotly rejects a self-anchored axis); `anchor` never reaches this
# point because the grid owns it.
const _SUBPLOT_AXIS_REF_KEYS = (:scaleanchor, :matches, :overlaying)
const _SUBPLOT_X_REF_PATTERN = r"^x([2-9]|[1-9][0-9]+)?$"
const _SUBPLOT_Y_REF_PATTERN = r"^y([2-9]|[1-9][0-9]+)?$"

function _subplot_remap_axis_refs(
	source_axis,
	xref::AbstractString,
	yref::AbstractString,
	self_ref::AbstractString,
)
	source_axis === nothing && return nothing
	_is_layout_mapping(source_axis) || return source_axis
	fields = _symbol_dict(source_axis)
	any(key -> haskey(fields, key), _SUBPLOT_AXIS_REF_KEYS) ||
		return source_axis
	for key in _SUBPLOT_AXIS_REF_KEYS
		haskey(fields, key) || continue
		value = fields[key]
		value isa AbstractString || continue
		mapped = occursin(_SUBPLOT_X_REF_PATTERN, value) ? String(xref) :
			occursin(_SUBPLOT_Y_REF_PATTERN, value) ? String(yref) :
			String(value)
		if mapped == self_ref
			delete!(fields, key)
		else
			fields[key] = mapped
		end
	end
	# A new container: the scratch figure's axis object is never mutated.
	return PlotlyBase.PlotlyAttribute(fields)
end

# Root layout keys of a scratch figure that `_apply_source_layout_to_added_traces!`
# merges into the target figure: `font`, `coloraxis` and the numbered colour
# axes (`coloraxis2`, ...) in index order.
const _SUBPLOT_NUMBERED_COLORAXIS_KEY = r"^coloraxis([2-9]|[1-9][0-9]+)$"

function _subplot_transplanted_root_keys(source::Plot)
	numbered = Tuple{Int, Symbol}[]
	for key in keys(source.layout.fields)
		m = match(_SUBPLOT_NUMBERED_COLORAXIS_KEY, String(key))
		m === nothing && continue
		push!(numbered, (parse(Int, m.captures[1]), Symbol(key)))
	end
	sort!(numbered)
	return (:font, :coloraxis, (key for (_, key) in numbered)...)
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
				source_axis = _subplot_remap_axis_refs(
					get(
						source.layout.fields,
						:xaxis,
						nothing,
					),
					xref,
					yref,
					xref,
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
				source_axis = _subplot_remap_axis_refs(
					get(
						source.layout.fields,
						:yaxis,
						nothing,
					),
					xref,
					yref,
					yref,
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

	# The root font and every colour axis the mutator wrote ("coloraxis",
	# "coloraxis2", ...): traces keep the colour-axis id the mutator gave them.
	for key in _subplot_transplanted_root_keys(source)
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

# Trace types each figure-wide mode arranges.
function _subplot_mode_trace_types(key::Symbol)
	key === :barmode && return ("bar", "histogram")
	key === :boxmode && return ("box",)
	return ("violin",)
end

# Root modes the caller passed explicitly (a non-empty string keyword).
function _subplot_explicit_root_modes(kwargs)
	return Tuple(
		key for key in _SUBPLOT_ROOT_LAYOUT_MODES
		if (value = get(kwargs, key, "")) isa AbstractString && !isempty(value)
	)
end

# barmode/boxmode/violinmode are single figure-wide plotly attributes, so a
# per-cell mutator must not let its automatic choice leak into other cells.
# - An explicit mode (`barmode="stack"`) is written to the root.
# - An explicit boxmode/violinmode that replaces a different mode already
#   arranging traces in other cells warns. The bar mode is reported by the
#   stats family's own SubplotFigure delegate (`_stats_subplot_delegate!`), the
#   only family whose mutators take `barmode`, so it is not warned twice.
# - An automatic box/violin mode only fills an unset root value (it offsets
#   boxes but hides no data).
# - An automatic barmode is never copied: a nested histogram's "overlay" would
#   hide grouped bars in every other cell. The histogram family overlays the
#   series of one call inside their own cell with a shared `offsetgroup`.
function _apply_source_root_layout_modes!(
	target::Plot,
	source::Plot;
	explicit_keys::Tuple{Vararg{Symbol}} = (),
	start_index::Int = length(target.data) + 1,
	who::AbstractString = "plot",
)
	for key in _SUBPLOT_ROOT_LAYOUT_MODES
		haskey(source.layout.fields, key) || continue
		value = source.layout.fields[key]
		if key in explicit_keys
			existing = get(target.layout.fields, key, nothing)
			if key !== :barmode && existing !== nothing && existing != value &&
					_subplot_mode_used_elsewhere(target, key, start_index)
				@warn "$(who): `$(key)=$(repr(value))` replaces " *
					"`$(key)=$(repr(existing))` for the WHOLE figure: plotly " *
					"has one $(key), so traces already in other cells are " *
					"re-arranged too."
			end
			target.layout.fields[key] = value
		elseif key !== :barmode
			get!(target.layout.fields, key, value)
		end
	end
	return nothing
end

# Whether traces that existed before `start_index` and sit on other axes than
# the new traces are arranged by the root mode `key`.
function _subplot_mode_used_elsewhere(target::Plot, key::Symbol, start_index::Int)
	types = _subplot_mode_trace_types(key)
	new_refs = Set{Tuple{String,String}}()
	for index in start_index:length(target.data)
		fields = target.data[index].fields
		push!(new_refs, (
			string(get(fields, :xaxis, "x")),
			string(get(fields, :yaxis, "y")),
		))
	end
	for index in 1:min(start_index - 1, length(target.data))
		fields = target.data[index].fields
		string(get(fields, :type, "scatter")) in types || continue
		refs = (
			string(get(fields, :xaxis, "x")),
			string(get(fields, :yaxis, "y")),
		)
		refs in new_refs || return true
	end
	return false
end

# plot_surface!(...; shared_coloraxis=true) also binds the surfaces already in
# the figure to the shared coloraxis, which rewrites existing trace roots.
_subplot_shared_surface_coloraxis(mutator, kwargs) =
	mutator === plot_surface! && get(kwargs, :shared_coloraxis, false) === true

# Name that prefixes the delegate's own errors and warnings (cell resolution,
# trace-kind checks, ignored figure-level keywords): `delegate_who` when the
# caller passes it, else a `who` keyword the caller forwards to its mutator
# (the 2-D field family does), else the mutator's name. A closure (families
# that wrap the public mutator to set a context) has a generated name, so the
# exported PlotlySupply function it captures names it; a closure that captures
# no exported function, or several, falls back to "SubplotFigure".
function _subplot_delegate_who(mutator, delegate_who, kwargs)
	delegate_who === nothing || return String(delegate_who)
	forwarded = get(kwargs, :who, nothing)
	(forwarded isa AbstractString && !isempty(forwarded)) && return String(forwarded)
	return _subplot_mutator_name(mutator)
end

_subplot_is_closure(f::Function) = startswith(String(nameof(f)), "#")

function _subplot_mutator_name(mutator::Function)
	_subplot_is_closure(mutator) || return String(nameof(mutator))
	found = Set{Symbol}()
	_subplot_collect_captured_mutators!(found, mutator)
	return length(found) == 1 ? String(only(found)) : "SubplotFigure"
end

# Names of the exported PlotlySupply functions a closure captures, directly or
# through the closures it captures (a closure with keyword arguments keeps its
# captures in an inner body closure). Closures are immutable values, so the
# walk cannot cycle; captured `Core.Box`es (reassigned variables) are skipped.
function _subplot_collect_captured_mutators!(found::Set{Symbol}, closure::Function)
	for index in 1:nfields(closure)
		captured = getfield(closure, index)
		captured isa Function || continue
		if _subplot_is_closure(captured)
			_subplot_collect_captured_mutators!(found, captured)
		elseif Base.isexported(PlotlySupply, nameof(captured))
			push!(found, nameof(captured))
		end
	end
	return found
end

# Attributes of a cell's x/y axes that a mutator reads to behave as it would
# on a single figure with those axes: the axis type (log axes convert ranges
# and coordinates, validate positivity and build log-aware traces), the
# exponent format a log axis already has, the explicit range / autorange
# (tick helpers derive log ticks from it) and the tick settings (tick presets
# replace or remove them). The delegate copies them onto the scratch figure's
# primary axes before the mutator runs and maps the result back.
const _SUBPLOT_SEEDED_AXIS_KEYS = (
	:type,
	:exponentformat,
	:range,
	:autorange,
	:tickmode,
	:tickvals,
	:ticktext,
	:tick0,
	:dtick,
	:tickformat,
	:minor,
)

# Layout keys (x, y) of the axes the delegate routes traces to: the inset's
# axes, the cell's x axis with its primary or secondary y axis, or `nothing`
# for a non-Cartesian cell. Empty cells and a missing secondary axis throw
# (prefixed with `who`) before the mutator runs.
function _subplot_delegate_axis_keys(
	p::Plot,
	row::Int,
	col::Int,
	inset_target,
	secondary_y::Bool,
	who::AbstractString,
)
	inset_target === nothing || return (inset_target.xkey, inset_target.ykey)
	ref = _subplot_target_ref(p, row, col; secondary_y = secondary_y, who = who)
	String(ref.subplot_kind) == "xy" || return nothing
	refs = ref.trace_kwargs.fields
	return (
		_axis_layout_key(String(refs[:xaxis]), :x),
		_axis_layout_key(String(refs[:yaxis]), :y),
	)
end

# The root of the shared-axis (`matches`) group axis `key` follows, or `key`
# itself when it follows none (or the chain is cyclic / leads to an axis the
# layout does not hold, which plotly.js ignores).
function _subplot_match_range_root(fields::AbstractDict, key::Symbol)
	_subplot_match_overlays(get(fields, key, nothing)) && return key
	root = _fin_match_root(fields, key)
	(root === nothing || !haskey(fields, root)) && return key
	_subplot_match_overlays(fields[root]) && return key
	return root
end

# Copy the `_SUBPLOT_SEEDED_AXIS_KEYS` of the target axes onto the scratch
# figure's `xaxis`/`yaxis` (independent copies: the mutator never reaches the
# figure's own containers). The range and autorange of an axis that follows a
# shared-axis group come from the group root, which holds them for the whole
# group. Returns, per scratch axis, the values seeded, and the group root of
# each scratch axis whose range was seeded from a root.
function _subplot_seed_scratch_axes!(scratch::Plot, p::Plot, axis_keys)
	seeded = Dict{Symbol, Dict{Symbol, Any}}()
	roots = Dict{Symbol, Symbol}()
	axis_keys === nothing && return seeded, roots
	fields = p.layout.fields
	for (scratch_key, cell_key) in zip((:xaxis, :yaxis), axis_keys)
		axis = get(fields, cell_key, nothing)
		root = _subplot_match_range_root(fields, cell_key)
		root_axis = root === cell_key ? axis : fields[root]
		root === cell_key || (roots[scratch_key] = root)
		values = Dict{Symbol, Any}()
		for name in _SUBPLOT_SEEDED_AXIS_KEYS
			source = name in _SUBPLOT_MATCH_RANGE_KEYS ? root_axis : axis
			value = _cmn_mapping_get(source, name)
			value === nothing || (values[name] = deepcopy(value))
		end
		isempty(values) && continue
		scratch.layout.fields[scratch_key] = attr(; deepcopy(values)...)
		seeded[scratch_key] = values
	end
	return seeded, roots
end

# After the mutator ran: drop the seeded values it left unchanged from the
# scratch axes (they already hold in the cell, and re-writing them would turn
# an append into a layout change), and return the seeded keys it removed,
# which the delegate then removes from the cell's axes as well.
function _subplot_unseed_scratch_axes!(scratch::Plot, seeded)
	removed = Dict{Symbol, Vector{Symbol}}()
	for (scratch_key, values) in seeded
		current = get(scratch.layout.fields, scratch_key, nothing)
		fields = _symbol_dict(current)
		gone = Symbol[]
		for (name, value) in values
			if !haskey(fields, name)
				push!(gone, name)
			elseif isequal(_legend_canonical(fields[name]), _legend_canonical(value))
				delete!(fields, name)
			end
		end
		isempty(gone) || (removed[scratch_key] = gone)
		if isempty(fields)
			delete!(scratch.layout.fields, scratch_key)
		else
			scratch.layout.fields[scratch_key] = attr(; fields...)
		end
	end
	return removed
end

function _subplot_delegate_mutator_impl!(
	sf::SubplotFigure,
	mutator::Function,
	args...;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	delegate_who::Union{Nothing, AbstractString} = nothing,
	kwargs...,
)
	who = _subplot_delegate_who(mutator, delegate_who, kwargs)
	inset_target = inset === nothing ? nothing : _cell_target(
		sf;
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		who = who,
	)
	r, c = inset_target === nothing ?
		_resolve_subplot_cell(sf; row = row, col = col, who = who) :
		(inset_target.row, inset_target.col)
	p = _plot_obj(sf.fig)
	# Resolve the target axes first: an empty cell or a missing secondary axis
	# fails before any trace is built.
	axis_keys = _subplot_delegate_axis_keys(p, r, c, inset_target, secondary_y, who)
	# `title`/`width`/`height` are figure-level, not per-cell: the delegate only
	# transplants traces + per-axis layout, so these would be silently dropped.
	# Warn instead of leaving the caller wondering why nothing changed.
	let kw = values(kwargs)
		dropped = Symbol[]
		get(kw, :title, "") != "" && push!(dropped, :title)
		get(kw, :width, 0) != 0 && push!(dropped, :width)
		get(kw, :height, 0) != 0 && push!(dropped, :height)
		isempty(dropped) || @warn "$(who): per-subplot plot_*! ignores figure-level keyword(s) $(dropped); set them on the `subplots(...)` call or via `relayout!(sf; ...)`."
	end
	tmp = Plot(Vector{GenericTrace}(undef, 0), Layout())
	# The scratch axes start as the target axes (type, range, ticks), so the
	# mutator converts ranges, validates ticks and builds log-aware traces
	# exactly as on a single figure with those axes.
	seeded, seeded_roots = _subplot_seed_scratch_axes!(tmp, p, axis_keys)
	# Colorbar titles that plotly cannot typeset are converted after the
	# traces reach their cell and the colorbars are placed (see
	# `_place_cell_colorbars!`), not on the scratch figure. The style's
	# dash/marker cycle continues from the traces already in the figure.
	Base.ScopedValues.with(_CBAR_DEFER_MATH_TITLES => true) do
		_with_style_trace_offset(p) do
			mutator(_StagedPlotMutation(tmp), args...; kwargs...)
		end
	end
	removed = _subplot_unseed_scratch_axes!(tmp, seeded)

	trace_refs = if inset_target === nothing
		_validate_subplot_traces!(
			p,
			tmp.data,
			r,
			c;
			secondary_y = secondary_y,
			who = who,
		).trace_kwargs
	else
		for trace in tmp.data
			kind, trace_type = _trace_subplot_kind(trace)
			kind == "xy" || throw(ArgumentError(
				"$(who): trace type '$(trace_type)' needs a '$(kind)' subplot; " *
				"inset $(inset) has Cartesian x/y axes.",
			))
		end
		attr(xaxis = inset_target.xref, yaxis = inset_target.yref)
	end
	routed = Vector{GenericTrace}()
	sizehint!(routed, length(tmp.data))
	for trace in tmp.data
		# The delegate owns `trace`, so only its fields dictionary needs a new
		# container before subplot references are merged. PlotlyBase.add_trace!
		# deep-copies every payload, which turns range/view-backed high-level
		# inputs into O(n) allocations without providing additional isolation.
		routed_trace = GenericTrace(copy(trace.fields))
		merge!(routed_trace, trace_refs)
		push!(routed, routed_trace)
	end

	start_index = length(p.data) + 1
	append!(p.data, routed)
	_apply_source_layout_to_added_traces!(p, tmp, start_index)
	if !isempty(routed) && axis_keys !== nothing
		for (scratch_key, cell_key) in zip((:xaxis, :yaxis), axis_keys)
			names = get(removed, scratch_key, nothing)
			names === nothing && continue
			root = get(seeded_roots, scratch_key, nothing)
			if root === nothing
				_cmn_delete_layout_fields!(p, cell_key, Tuple(names))
			else
				# A range/autorange seeded from the group root is removed there.
				_cmn_delete_layout_fields!(
					p,
					cell_key,
					Tuple(n for n in names if !(n in _SUBPLOT_MATCH_RANGE_KEYS)),
				)
				_cmn_delete_layout_fields!(
					p,
					root,
					Tuple(n for n in names if n in _SUBPLOT_MATCH_RANGE_KEYS),
				)
			end
		end
	end
	_apply_source_root_layout_modes!(
		p,
		tmp;
		explicit_keys = _subplot_explicit_root_modes(kwargs),
		start_index = start_index,
		who = who,
	)
	if _subplot_shared_surface_coloraxis(mutator, kwargs)
		# Mirror the Plot-level mutator: every surface of the figure shares
		# the coloraxis. `_subplot_delegate_mutator!` stages this case fully.
		for index in 1:(start_index - 1)
			trace = p.data[index]
			trace isa GenericTrace || continue
			string(get(trace.fields, :type, "")) == "surface" || continue
			trace.fields[:coloraxis] = "coloraxis"
		end
	end
	_place_cell_colorbars!(p, start_index)
	_refresh_subplot_legends!(sf, p; first_new = start_index, auto = true)

	sf.current_row = r
	sf.current_col = c
	_refresh!(sf.fig)
	return sf
end

"""
	_subplot_delegate_mutator!(sf, mutator, args...; row=nothing, col=nothing, secondary_y=false, inset=nothing, delegate_who=nothing, kwargs...)

Run the `Plot`-level `mutator(fig, args...; kwargs...)` for one cell of `sf`
(internal; the SubplotFigure methods of the `plot_*!` families call it). The
mutator builds its traces on an empty scratch figure whose primary axes carry
the target axes' type, exponent format, range and tick settings
(`_SUBPLOT_SEEDED_AXIS_KEYS`; the range of a shared axis is the group
root's), so log cells convert ranges and validate data like a single log
figure. Changes to a shared axis act on its group (`_subplot_match_sync!`). The traces are then routed to the cell
(`row`/`col`, default the active cell; `secondary_y`; or inset `inset` of
`sf.insets`), the scratch axes' changes are merged into the cell's axes
(axis references such as `scaleanchor` retargeted to the cell), every
`coloraxis*` layout object and `font` are merged into the figure, colorbars
are placed next to the cell and the legends refreshed. Figure-wide
`barmode`/`boxmode`/`violinmode` reach the root only when passed explicitly
(an automatic box/violin mode fills an unset root). `delegate_who` names the
public function in the delegate's own errors (default: see
`_subplot_delegate_who`). Validation errors leave `sf` unchanged; the live
window gets one append-only update unless the call must rewrite existing
traces (per-subplot legends, `shared_coloraxis`). Returns `sf`.
"""
function _subplot_delegate_mutator!(
	sf::SubplotFigure,
	mutator::Function,
	args...;
	kwargs...,
)
	haskey(kwargs, :show) && throw(ArgumentError(
		"$(_subplot_delegate_who(mutator, get(kwargs, :delegate_who, nothing), kwargs)): " *
		"mutators do not take `show`; the SubplotFigure " *
		"is shown by `subplots(...; sync=true)` (or `display(sf)`).",
	))
	metadata_lock = getfield(sf, :_lock)
	lock(metadata_lock)
	try
		staged_ref =
			Ref{Union{Nothing,SubplotFigure}}(nothing)
		result = Ref{Any}(nothing)
		mutation = function (candidate)
			staged = _staged_subplot_figure(sf, candidate)
			staged_ref[] = staged
			match_snapshot = _subplot_match_snapshot(_plot_obj(candidate))
			result[] = _subplot_delegate_mutator_impl!(
				staged,
				mutator,
				args...;
				kwargs...,
			)
			_subplot_match_sync!(_plot_obj(candidate), match_snapshot)
			_finalize_figure!(staged; live = _plot_data(getfield(sf, :fig)))
			return nothing
		end
		commit_callback = _ -> _commit_subplot_metadata!(
			sf,
			something(staged_ref[]),
			_SUBPLOT_SELECTION_METADATA_FIELDS,
		)

		fig = getfield(sf, :fig)
		# Per-subplot legends and plot_surface!(...; shared_coloraxis=true)
		# rewrite existing traces. The append-only fast path intentionally
		# shares those trace roots, so retain full staging for both.
		full_staging =
			sf.per_subplot_legends ||
			_subplot_shared_surface_coloraxis(mutator, kwargs)
		if full_staging && fig isa SyncPlot
			_mutate_and_refresh_syncplot!(
				mutation,
				fig;
				commit_callback = commit_callback,
			)
		elseif full_staging
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

# Layout keys of a cell's x and y axes, read from the grid routing table (no
# probe trace is added to the figure).
function _subplot_xy_axis_keys(sf::SubplotFigure, row::Int, col::Int; secondary_y::Bool = false)
	p = _plot_obj(sf.fig)
	grid_ref = p.layout.subplots.grid_ref
	(checkbounds(Bool, grid_ref, row, col) &&
		isassigned(grid_ref, row, col) &&
		!isempty(grid_ref[row, col])) || throw(ArgumentError(
		"Selected subplot cell ($(row), $(col)) is empty (its `specs` entry is " *
		"`missing`, or a spanning cell covers it) and has no axes.",
	))
	refs = grid_ref[row, col]
	kind = String(first(refs).subplot_kind)
	kind == "xy" || throw(ArgumentError(
		"Selected subplot cell ($(row), $(col)) is a '$(kind)' cell and does " *
		"not accept Cartesian x/y axes.",
	))
	if secondary_y && length(refs) < 2
		throw(ArgumentError(
			"Selected subplot cell ($(row), $(col)) has no secondary y-axis; " *
			"create the grid with `specs` containing `Spec(secondary_y=true)` " *
			"for that cell.",
		))
	end
	trace_refs = refs[secondary_y ? 2 : 1].trace_kwargs.fields
	(haskey(trace_refs, :xaxis) && haskey(trace_refs, :yaxis)) || throw(ArgumentError(
		"Selected subplot cell ($(row), $(col)) has no x/y axis pair.",
	))
	xkey = _axis_layout_key(String(trace_refs[:xaxis]), :x)
	ykey = _axis_layout_key(String(trace_refs[:yaxis]), :y)
	return xkey, ykey
end

# The layout key of the single `kind` object (:geo, :mapbox, :map, ...) of
# cell (row, col); an empty cell or a cell of another kind is an ArgumentError
# naming `who`.
function _subplot_cell_layout_key(
	sf::SubplotFigure,
	row::Int,
	col::Int,
	kind::Symbol;
	who::AbstractString = "SubplotFigure",
)
	expected_kind = String(kind)
	target_ref = _subplot_target_ref(_plot_obj(sf.fig), row, col; who = who)
	actual_kind = String(target_ref.subplot_kind)
	actual_kind == expected_kind || throw(ArgumentError(
		"$(who): subplot cell ($(row), $(col)) is a '$actual_kind' cell, " *
		"not a '$expected_kind' cell.",
	))
	return only(target_ref.layout_keys)
end

# `kind` is the subplot kind of the cell (:geo or :mapbox). MapLibre `map`
# cells are updated by `_transactional_modern_map_subplot_update!`
# (electron_backend.jl), which owns the alias-preserving map transaction;
# `update_maps!` only checks the cell with `_subplot_cell_layout_key`.
function _subplot_geographic_layout_key(
	sf::SubplotFigure,
	row::Int,
	col::Int,
	kind::Symbol;
	who::AbstractString = "SubplotFigure",
)
	kind in (:geo, :mapbox) || throw(ArgumentError(
		"$(who): unsupported geographic subplot kind `$kind`.",
	))
	return _subplot_cell_layout_key(sf, row, col, kind; who = who)
end

# Run `f()` so that an ArgumentError raised by a shared validator (whose
# message names a Plotly family, such as "mapbox: zoom must be …") names the
# public SubplotFigure function `who` instead. Errors that already start with
# "`who`:" and other exception types pass through unchanged.
function _subplot_name_errors(f, who::AbstractString)
	try
		return f()
	catch err
		(err isa ArgumentError && !startswith(err.msg, who * ":")) || rethrow()
		throw(ArgumentError("$(who): $(err.msg)"))
	end
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
	who = String(nameof(updater))
	r, c = _resolve_subplot_cell(sf; row = row, col = col, who = who)
	key = _subplot_geographic_layout_key(sf, r, c, kind; who = who)
	layout = _plot_layout(sf.fig)
	temporary = Layout()
	existing = get(layout.fields, key, nothing)
	# A `nothing` cell root (e.g. after `relayout!(sf; geo2 = nothing)`) is
	# Plotly's "all defaults"; update it like an empty object.
	temporary.fields[kind] =
		existing === nothing ? attr() : deepcopy(existing)
	_subplot_name_errors(who) do
		updater(temporary, with; kwargs...)
		kind === :mapbox && _require_valid_mapbox_layouts(temporary)
	end
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
	# Resolve and check the cell under the (reentrant) metadata lock, so the
	# errors name `update_maps!` and the cell cannot change before the
	# transaction runs.
	return lock(getfield(sf, :_lock)) do
		r, c = _resolve_subplot_cell(sf; row = row, col = col, who = "update_maps!")
		_subplot_cell_layout_key(sf, r, c, :map; who = "update_maps!")
		_subplot_name_errors("update_maps!") do
			_transactional_modern_map_subplot_update!(
				sf,
				with;
				row = r,
				col = c,
				kwargs...,
			)
		end
	end
end

function _subplot_xlabel_impl!(
	sf::SubplotFigure,
	label::AbstractString;
	row = nothing,
	col = nothing,
	inset = nothing,
)
	_axes_label!(
		sf,
		'x',
		label;
		row = row,
		col = col,
		inset = inset,
		who = "xlabel!",
	)
	return sf
end

"""
	xlabel!(fig, label; row=nothing, col=nothing, inset=nothing)
	xlabel!(sf::SubplotFigure, label; row=nothing, col=nothing, inset=nothing)

Set the x-axis title of a `Plot`/`SyncPlot`, of one
[`SubplotFigure`](@ref) cell, or of an inset.

# Arguments
- `fig`: a `Plot`, `SyncPlot` or `SubplotFigure`.
- `label::AbstractString`: the title; mixed text and `\$...\$` math goes
  through the mathtext layer. `""` clears the title. On a 3-D scene cell the
  title is written to `scene.xaxis.title.text` (scene titles cannot typeset
  MathJax, so TeX is converted to HTML/Unicode).

# Keywords
- `row`, `col`: SubplotFigure cell (both or neither). Omitted, the active
  cell selected by [`subplot!`](@ref) is used; the targeted cell becomes the
  active cell. An `ArgumentError` on a plain figure.
- `inset = nothing`: inset id `k` from [`inset!`](@ref) (SubplotFigure only).

Throws `ArgumentError` (figure unchanged) for cells without x/y or scene
axes. Returns `nothing` (`sf` for a SubplotFigure, for chaining).

# Example
```julia
fig = plot_scatter(1:10, rand(10))
xlabel!(fig, "time (s)")
sf = subplots(1, 2; sync = false)
xlabel!(sf, "x (m)"; row = 1, col = 2)
```
"""
function xlabel!(
	fig,
	label::AbstractString;
	row = nothing,
	col = nothing,
	inset = nothing,
	show = nothing,
)
	_axes_reject_show(show, "xlabel!")
	_axes_label!(
		fig,
		'x',
		label;
		row = row,
		col = col,
		inset = inset,
		who = "xlabel!",
	)
	return nothing
end

function xlabel!(
	sf::SubplotFigure,
	label::AbstractString;
	row = nothing,
	col = nothing,
	inset = nothing,
	show = nothing,
)
	_axes_reject_show(show, "xlabel!")
	return _transactional_subplot_mutation!(
		_subplot_xlabel_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		label;
		row = row,
		col = col,
		inset = inset,
	)
end

function _subplot_ylabel_impl!(
	sf::SubplotFigure,
	label::AbstractString;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
)
	_axes_label!(
		sf,
		'y',
		label;
		row = row,
		col = col,
		inset = inset,
		secondary_y = secondary_y,
		who = "ylabel!",
	)
	return sf
end

"""
	ylabel!(fig, label; row=nothing, col=nothing, inset=nothing, secondary_y=false)
	ylabel!(sf::SubplotFigure, label; row=nothing, col=nothing, inset=nothing, secondary_y=false)

Set the y-axis title of a `Plot`/`SyncPlot`, of one
[`SubplotFigure`](@ref) cell, or of an inset; identical to
[`xlabel!`](@ref) for the y axis.

# Keywords
- `row`, `col`, `inset`: as for [`xlabel!`](@ref).
- `secondary_y::Bool = false`: target the secondary y axis: the twin of a
  plain figure (created by a `secondary_y=true` plot call) or the secondary
  axis of a `Spec(secondary_y=true)` subplot cell. Without one it is an
  `ArgumentError`.

Returns `nothing` (`sf` for a SubplotFigure).

# Example
```julia
sf = subplots(1, 1; sync = false, specs = fill(Spec(secondary_y = true), 1, 1))
plot_scatter!(sf, 1:3, [1.0, 2, 3])
plot_scatter!(sf, 1:3, [10.0, 20, 30]; secondary_y = true)
ylabel!(sf, "left")
ylabel!(sf, "right"; secondary_y = true)
```
"""
function ylabel!(
	fig,
	label::AbstractString;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
	show = nothing,
)
	_axes_reject_show(show, "ylabel!")
	_axes_label!(
		fig,
		'y',
		label;
		row = row,
		col = col,
		inset = inset,
		secondary_y = secondary_y,
		who = "ylabel!",
	)
	return nothing
end

function ylabel!(
	sf::SubplotFigure,
	label::AbstractString;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
	show = nothing,
)
	_axes_reject_show(show, "ylabel!")
	return _transactional_subplot_mutation!(
		_subplot_ylabel_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		label;
		row = row,
		col = col,
		inset = inset,
		secondary_y = secondary_y,
	)
end

function _subplot_xrange_impl!(
	sf::SubplotFigure,
	range;
	row = nothing,
	col = nothing,
	inset = nothing,
)
	_axes_range!(
		sf,
		'x',
		range;
		row = row,
		col = col,
		inset = inset,
		who = "xrange!",
	)
	return sf
end

"""
	xrange!(fig, range; row=nothing, col=nothing, inset=nothing)
	xrange!(sf::SubplotFigure, range; row=nothing, col=nothing, inset=nothing)

Set the x-axis range of a `Plot`/`SyncPlot`, of one [`SubplotFigure`](@ref)
cell, or of an inset.

# Arguments
- `range`: `(lo, hi)` or `[lo, hi]` in DATA units on every axis type: on a
  logarithmic axis pass data values (`(1e-3, 1e2)`), never exponents; they
  are converted to the log10 values Plotly stores, and non-positive bounds
  are an `ArgumentError` (breaking in 2.0: 1.x passed log10 exponents
  through). A reversed range (`hi < lo`) flips the axis. Bounds are numbers
  on linear, log and category axes (category positions are 0-based
  indices); a date axis also takes date strings or `Date`/`DateTime`.
  `[0, 0]`, `(0, 0)` and `nothing` restore automatic ranging (1.x wrote a
  literal `[0, 0]` range). Partial ranges and equal bounds are an
  `ArgumentError`.

# Keywords
- `row`, `col`: SubplotFigure cell (both or neither). Omitted, the active
  cell is used; the targeted cell becomes the active cell. An
  `ArgumentError` on a plain figure.
- `inset = nothing`: inset id `k` from [`inset!`](@ref) (SubplotFigure only).

The range is written with `autorange = false`, so it applies even where an
explicit `autorange` was set. When the axis is shared with other cells
(`shared_xaxes`, i.e. it `matches` another axis), the range is written on
the axis that owns the shared range, so every cell of the group shows it.
A 3-D scene cell sets `scene.xaxis.range` (log scene axes alike). Returns
`nothing` (`sf` for a SubplotFigure).

# Example
```julia
fig = plot_scatter([1e-3, 1.0, 1e3], [1.0, 2.0, 3.0]; xscale = "log")
xrange!(fig, (1e-4, 1e4))       # data units on the log axis
xrange!(fig, nothing)            # automatic again
```
"""
function xrange!(
	fig,
	range;
	row = nothing,
	col = nothing,
	inset = nothing,
	show = nothing,
)
	_axes_reject_show(show, "xrange!")
	_axes_range!(
		fig,
		'x',
		range;
		row = row,
		col = col,
		inset = inset,
		who = "xrange!",
	)
	return nothing
end

function xrange!(
	sf::SubplotFigure,
	range;
	row = nothing,
	col = nothing,
	inset = nothing,
	show = nothing,
)
	_axes_reject_show(show, "xrange!")
	return _transactional_subplot_mutation!(
		_subplot_xrange_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		range;
		row = row,
		col = col,
		inset = inset,
	)
end

function _subplot_yrange_impl!(
	sf::SubplotFigure,
	range;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
)
	_axes_range!(
		sf,
		'y',
		range;
		row = row,
		col = col,
		inset = inset,
		secondary_y = secondary_y,
		who = "yrange!",
	)
	return sf
end

"""
	yrange!(fig, range; row=nothing, col=nothing, inset=nothing, secondary_y=false)
	yrange!(sf::SubplotFigure, range; row=nothing, col=nothing, inset=nothing, secondary_y=false)

Set the y-axis range of a `Plot`/`SyncPlot`, of one [`SubplotFigure`](@ref)
cell, or of an inset; identical to [`xrange!`](@ref) for the y axis: DATA
units on logarithmic axes (`yrange!(fig, (1, 1e5))`, not exponents),
`autorange = false`, shared axes, scene cells.

# Keywords
- `row`, `col`, `inset`: as for [`xrange!`](@ref).
- `secondary_y::Bool = false`: target the secondary y axis (the twin of a
  plain figure or of a `Spec(secondary_y=true)` subplot cell).

Returns `nothing` (`sf` for a SubplotFigure).

# Example
```julia
fig = plot_scatter(1:10, exp.(1:10); yscale = "log")
yrange!(fig, (1, 1e5))
```
"""
function yrange!(
	fig,
	range;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
	show = nothing,
)
	_axes_reject_show(show, "yrange!")
	_axes_range!(
		fig,
		'y',
		range;
		row = row,
		col = col,
		inset = inset,
		secondary_y = secondary_y,
		who = "yrange!",
	)
	return nothing
end

function yrange!(
	sf::SubplotFigure,
	range;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
	show = nothing,
)
	_axes_reject_show(show, "yrange!")
	return _transactional_subplot_mutation!(
		_subplot_yrange_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		range;
		row = row,
		col = col,
		inset = inset,
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
	x::AbstractArray,
	y::AbstractArray;
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
	y::AbstractArray;
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
	x::AbstractArray;
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
	x::AbstractArray,
	y::AbstractArray;
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
	y::AbstractArray;
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
	x::AbstractArray,
	y::AbstractArray;
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
	y::AbstractArray;
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

# SubplotFigure path of the 2-D field mutators (heatmap, contour, quiver,
# image, and plot_matrix/plot_streamlines in src/sci/fields.jl), as one
# transaction (an error leaves the figure unchanged). The delegate builds the
# traces on an empty scratch figure and transplants them into the target cell
# (`row`/`col`, the active cell, or `inset = k`). `_finalize_figure!` is never
# run on the scratch figure (its extents would be the new traces' only).
# What depends on the cell's own axes is applied afterwards on the real
# figure, in a fully staged transaction: the axis ranges (the scratch figure
# does not know that a cell axis is logarithmic or matched to another), the
# equal aspect (scaleanchor naming the cell's x axis) and `_finalize_figure!`
# over the whole figure. Without those a call takes the delegate's
# append-only fast path, which finalizes the figure itself (field-layout
# contract, CONTRACT.md §4). The style gives field overlays only its line
# width, which does not depend on the cycle position, so the scratch
# figure's trace numbering needs no offset.
function _field2d_subplot!(
	sf::SubplotFigure,
	mutator::Function,
	args::Tuple;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	equalar::Bool = false,
	kwargs...,
)
	who = String(get(kwargs, :who, string(nameof(mutator))))
	haskey(kwargs, :show) && _field2d_reject_keywords(who, kwargs)
	# `xrange`/`yrange` of a mutator that has them are applied to the cell
	# below; plot_matrix! has none, so there they stay in `forwarded` and the
	# mutator rejects them as unknown keywords exactly as on a Plot.
	forwarded = values(kwargs)
	xr = yr = nothing
	if mutator !== plot_matrix!
		xr = _field2d_checked_range(get(forwarded, :xrange, nothing), who, "xrange")
		yr = _field2d_checked_range(get(forwarded, :yrange, nothing), who, "yrange")
		forwarded = Base.structdiff(forwarded, NamedTuple{(:xrange, :yrange)})
	end
	if !equalar && xr === nothing && yr === nothing
		return Base.ScopedValues.with(_FIELD2D_DEFER_FINALIZE => true) do
			_subplot_delegate_mutator!(
				sf,
				mutator,
				args...;
				row = row,
				col = col,
				secondary_y = secondary_y,
				inset = inset,
				equalar = false,
				forwarded...,
			)
		end
	end
	return _transactional_subplot_mutation!(
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
	) do staged
		Base.ScopedValues.with(_FIELD2D_DEFER_FINALIZE => true) do
			_subplot_delegate_mutator_impl!(
				staged,
				mutator,
				args...;
				row = row,
				col = col,
				secondary_y = secondary_y,
				inset = inset,
				equalar = false,
				forwarded...,
			)
		end
		# The delegate made the target cell active, so this is the cell (or
		# the inset) the traces went to.
		target = _cell_target(
			staged;
			secondary_y = secondary_y,
			inset = inset,
			who = who,
		)
		# The equal aspect before the ranges: a one-sided limit is written
		# differently on an aspect-constrained axis.
		equalar && _apply_equal_aspect!(staged, target; who = who)
		# An image's y axis without a direction is drawn reversed by plotly.
		_field2d_cell_ranges!(staged, target, xr, yr, who; implicit_reversed_y = mutator === plot_image!)
		_finalize_figure!(_StagedPlotMutation(_cmn_plot(staged)))
		return staged
	end
end

# Explicit `xrange`/`yrange` (validated by `_field2d_checked_range`; `nothing`
# leaves the axis alone) of a SubplotFigure cell, in DATA units: converted to
# the log10 values Plotly stores on a log axis, written with
# `autorange = false` on the root of the axis's `matches` group (the only axis
# plotly.js reads a shared range from). A one-sided limit (D11) is written by
# `_field2d_apply_partial_range!` on the group; `implicit_reversed_y` (an
# image's y axis) keeps plotly's reversed default when the axis states no
# direction, as on a Plot.
# (`t` is a `_CellTarget`, defined after this file in src/sci/common.jl.)
function _field2d_cell_ranges!(fig, t, xr, yr, who::AbstractString; implicit_reversed_y::Bool = false)
	for (checked, key, name) in ((xr, t.xkey, "xrange"), (yr, t.ykey, "yrange"))
		checked === nothing && continue
		root = _axes_match_root(fig, key, who)
		if _field2d_is_partial(checked)
			_field2d_require_partial_range(fig, root, checked, "", who, name)
			_field2d_apply_partial_range!(
				fig,
				root,
				checked;
				implicit_reversed = implicit_reversed_y && name == "yrange",
				who = who,
			)
			continue
		end
		layout = _cmn_layout(fig)
		value = _axis_type(layout, root) == "log" ?
			_to_axis_range(layout, root, checked; who = "$(who) (`$(name)`)") :
			checked
		_cmn_merge_layout_key!(
			fig,
			root,
			Dict{Symbol, Any}(:range => value, :autorange => false),
		)
	end
	return nothing
end

# SubplotFigure methods of the field mutators (Y3): the Plot-level mutator
# runs on the delegate's scratch figure, whose axes are seeded with the cell's
# type, range and ticks (`_SUBPLOT_SEEDED_AXIS_KEYS`), so implicit
# coordinates (1-based on a log cell), positivity checks on a log cell and
# log-aware glyphs (quiver) are computed exactly as on a single figure.
function plot_heatmap!(
	sf::SubplotFigure,
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	equalar::Bool = false,
	kwargs...,
)
	return _field2d_subplot!(
		sf,
		plot_heatmap!,
		(x, y, U);
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		equalar = equalar,
		kwargs...,
	)
end

function plot_heatmap!(
	sf::SubplotFigure,
	U::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	equalar::Bool = false,
	kwargs...,
)
	return _field2d_subplot!(
		sf,
		plot_heatmap!,
		(U,);
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		equalar = equalar,
		kwargs...,
	)
end

function plot_contour!(
	sf::SubplotFigure,
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	equalar::Bool = false,
	kwargs...,
)
	return _field2d_subplot!(
		sf,
		plot_contour!,
		(x, y, U);
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		equalar = equalar,
		kwargs...,
	)
end

function plot_contour!(
	sf::SubplotFigure,
	U::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	equalar::Bool = false,
	kwargs...,
)
	return _field2d_subplot!(
		sf,
		plot_contour!,
		(U,);
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		equalar = equalar,
		kwargs...,
	)
end

function plot_quiver!(
	sf::SubplotFigure,
	x::AbstractArray,
	y::AbstractArray,
	u::AbstractArray,
	v::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	equalar::Bool = true,
	kwargs...,
)
	return _field2d_subplot!(
		sf,
		plot_quiver!,
		(x, y, u, v);
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		equalar = equalar,
		kwargs...,
	)
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

"""
	plot_indicator!(fig, value; mode="number", reference=nothing,
		gauge_range=nothing, gauge_shape="", number_suffix="", title="",
		width=0, height=0, fontsize=0)
	plot_indicator!(sf::SubplotFigure, value; row=nothing, col=nothing, kwargs...)

Append an indicator trace to `fig` (`Plot`/`SyncPlot`), or to the `domain`
cell `row`, `col` of a `SubplotFigure` (default: the active cell). Keywords as
for [`plot_indicator`](@ref) without `show` (an `ArgumentError`); see
[`plot_pie!`](@ref) for the figure-level options.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
sf = subplots(1, 2; sync = false, specs = [Spec(kind = "domain") Spec(kind = "domain")])
plot_indicator!(sf, 42; row = 1, col = 1)
plot_indicator!(sf, 0.8; gauge_range = (0, 1), row = 1, col = 2)
```
"""
function plot_indicator!(
	fig,
	value::Real;
	mode::AbstractString = "number",
	reference::Union{Nothing, Real} = nothing,
	gauge_range = nothing,
	gauge_shape::AbstractString = "",
	number_suffix::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_indicator!"
	_extended_mutator_guard(who, show, row, col)
	trace = _indicator_trace(
		who,
		value;
		mode = mode,
		reference = reference,
		gauge_range = gauge_range,
		gauge_shape = gauge_shape,
		number_suffix = number_suffix,
	)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	push!(_plot_data(fig), trace)
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	_refresh!(fig)
	return nothing
end

function plot_image!(
	sf::SubplotFigure,
	z::AbstractArray;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	equalar::Bool = true,
	kwargs...,
)
	return _field2d_subplot!(
		sf,
		plot_image!,
		(z,);
		row = row,
		col = col,
		secondary_y = secondary_y,
		equalar = equalar,
		kwargs...,
	)
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

# Common Cartesian keywords of a constructor (`apply_template = true`) or
# mutator (`apply_template = false`, usually `refresh = true`), applied through
# the D7 primitives (src/sci/base.jl) to the PRIMARY axes (`xaxis`/`yaxis`, or
# the twin `ykey`): every option is validated first, then title, labels,
# scale, range (DATA units on log axes; a scale switch keeps the data interval
# of an explicit range), size, grid (`true` keeps the template grid), ticks
# (`xticks`/`yticks` take values or the D9 presets `:decades`/`:auto`, see
# `_apply_ticks!`), equal aspect, template/legend and font size. Works on a
# figure that already holds traces and on an empty one.
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
		_require_axis_range_for_key(fig, ykey, yrange, yscale, who; name = "yrange")
	end
	# Tick values/labels and the D9 presets (`:decades`, `:auto`) are checked
	# against the axis type this call ends up with, before anything is written.
	_validate_tick_option(fig, :xaxis, xticks, xticklabels, xscale, who, "x")
	_validate_tick_option(fig, ykey, yticks, yticklabels, yscale, who, "y")

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
		# The twin y axis gets the same primitives, addressed by key.
		_apply_axis_title_to_key!(fig, ykey, ylabel)
		_apply_axis_scale_to_key!(fig, ykey, yscale, who; name = "yscale")
		_apply_axis_range_to_key!(fig, ykey, yrange, who; name = "yrange")
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

_stats_is_barlike(trace) =
	trace isa GenericTrace && string(get(trace.fields, :type, "")) in _STATS_BARMODE_TRACE_TYPES

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
	_scat_require_vector(series, who, Symbol(name))
	element_type = eltype(series)
	complex_values = element_type !== Union{} && (
		element_type <: Complex ||
		(!isconcretetype(element_type) && any(value -> value isa Complex, series))
	)
	complex_values && throw(ArgumentError(
		"$(who): `$(name)` has complex values, which Plotly cannot draw; pass " *
		"real.(v), imag.(v), abs.(v) or angle.(v).",
	))
	# A series holds one scalar per sample or bar; arrays inside a series that is
	# not a vector of vectors (e.g. a vector of matrices) cannot be drawn.
	array_values = element_type !== Union{} && (
		element_type <: AbstractArray ||
		(!isconcretetype(element_type) && any(value -> value isa AbstractArray, series))
	)
	array_values && throw(ArgumentError(
		"$(who): `$(name)` entries must be scalars (one per sample or bar), or " *
		"`$(name)` a vector of vectors (one per series); got $(typeof(series)).",
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
	# The public methods take any AbstractArray so a matrix gets this
	# ArgumentError (pointing at `collect(eachcol(A))`), not a MethodError.
	_scat_require_vector(values, who, Symbol(value_name))
	positions === nothing || _scat_require_vector(positions, who, Symbol(position_name))
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

# Per-series values of a bar keyword that may also be given bar by bar (G68),
# for series of `bar_counts` bars (`nested`: the data held several series):
# - a scalar (`isscalar(value)`): every bar of every series;
# - one series: a vector with one entry per bar sets each bar (matplotlib's
#   `bar(color = [...])`), a one-entry vector is the series value, an empty
#   vector leaves the default, and any other length is an `ArgumentError`;
# - several series: one entry per series (missing entries keep `default`,
#   surplus entries are ignored, as for every per-series keyword); an entry
#   that is itself a vector sets the bars of its series, one entry per bar.
# Every scalar goes through `convert` (which validates it). Returns one value
# per series: `default`, a converted scalar, or a `Vector{Any}` of them.
function _stats_bar_values(
	value,
	bar_counts::Vector{Int},
	nested::Bool,
	default,
	who::AbstractString,
	name::AbstractString,
	describe::AbstractString;
	isscalar,
	convert,
)
	count = length(bar_counts)
	isscalar(value) && return Any[convert(value) for _ in 1:count]
	value isa AbstractVector || throw(ArgumentError(
		"$(who): `$(name)` must be $(describe), a vector with one per series, or " *
		"(for a single series) a vector with one per bar; got $(repr(value)).",
	))
	function per_bar(entry, index)
		length(entry) == bar_counts[index] || throw(ArgumentError(
			"$(who): `$(name)` gives $(length(entry)) per-bar entries for series " *
			"$(index), which has $(bar_counts[index]) bars; give one per bar.",
		))
		return Any[
			isscalar(item) ? convert(item) : throw(ArgumentError(
				"$(who): per-bar `$(name)` entries must be $(describe); got $(repr(item)).",
			))
			for item in entry
		]
	end
	function series_entry(entry, index)
		isscalar(entry) && return convert(entry)
		entry isa AbstractVector && return per_bar(entry, index)
		throw(ArgumentError(
			"$(who): `$(name)` entries must be $(describe) or a vector with one per " *
			"bar; got $(repr(entry)).",
		))
	end
	out = Any[default for _ in 1:count]
	if !nested
		bars = only(bar_counts)
		if isempty(value)
			return out
		elseif length(value) == 1
			out[1] = series_entry(value[1], 1)
		elseif length(value) == bars
			out[1] = per_bar(value, 1)
		else
			throw(ArgumentError(
				"$(who): `$(name)` has $(length(value)) entries for a single series of " *
				"$(bars) bars; give one value for the series or one per bar.",
			))
		end
		return out
	end
	for index in 1:min(count, length(value))
		out[index] = series_entry(value[index], index)
	end
	return out
end

# Bar colours: per series a colour string ("" = the colour cycle) or a vector
# of non-empty colours, one per bar (plotly `marker.color` array).
function _stats_bar_colors(color, bar_counts::Vector{Int}, nested::Bool, who::AbstractString)
	values = _stats_bar_values(
		color, bar_counts, nested, "", who, "color", "a colour string or symbol";
		isscalar = entry -> entry isa AbstractString || entry isa Symbol,
		convert = entry -> String(entry),
	)
	return Any[
		entry isa AbstractVector ? String[
			isempty(item) ? throw(ArgumentError(
				"$(who): per-bar `color` entries must be non-empty colours; got \"\".",
			)) : item for item in entry
		] : entry
		for entry in values
	]
end

# Bar widths in data units of the position axis (plotly `width`; `nothing`:
# plotly's automatic width), per series a number, `nothing` or one per bar.
function _stats_bar_widths(barwidth, bar_counts::Vector{Int}, nested::Bool, who::AbstractString)
	check(entry) = (entry isa Real && !(entry isa Bool) && isfinite(entry) && entry > 0) ?
		entry : throw(ArgumentError(
			"$(who): `barwidth` values must be positive finite numbers (data units of " *
			"the position axis) or `nothing`; got $(repr(entry)).",
		))
	values = _stats_bar_values(
		barwidth, bar_counts, nested, nothing, who, "barwidth", "a positive number";
		isscalar = entry -> entry === nothing || (entry isa Real && !(entry isa Bool)),
		convert = entry -> entry === nothing ? nothing : check(entry),
	)
	return Any[
		entry isa AbstractVector ? (any(isnothing, entry) ? throw(ArgumentError(
			"$(who): per-bar `barwidth` entries must be numbers; got `nothing`.",
		)) : Any[entry...]) : entry
		for entry in values
	]
end

# Bar hatches (`_hatch_pattern`): per series a pattern, `nothing`, or, for
# per-bar hatches, one pattern whose `shape`, `size` and `solidity` are arrays
# ("" shape: no hatch on that bar).
function _stats_bar_patterns(hatch, bar_counts::Vector{Int}, nested::Bool, who::AbstractString)
	values = _stats_bar_values(
		hatch, bar_counts, nested, "", who, "hatch", "a hatch string";
		isscalar = entry -> entry isa AbstractString,
		convert = entry -> String(entry),
	)
	return Any[
		entry isa AbstractVector ? _stats_per_bar_pattern(entry, who) :
		_hatch_pattern(entry; who = who)
		for entry in values
	]
end

# Plotly's `marker.pattern` defaults (plotly.js 2.35.2 schema: `size` 8,
# `solidity` 0.3), written for the bars whose hatch leaves them unset, so the
# per-bar arrays stay aligned with the bars.
const _STATS_PATTERN_DEFAULT_SIZE = 8.0
const _STATS_PATTERN_DEFAULT_SOLIDITY = 0.3

function _stats_per_bar_pattern(hatches::AbstractVector, who::AbstractString)
	patterns = Any[_hatch_pattern(String(entry); who = who) for entry in hatches]
	all(isnothing, patterns) && return nothing
	field(pattern, key, default) =
		pattern === nothing ? default : get(pattern.fields, key, default)
	return attr(
		shape = String[field(pattern, :shape, "") for pattern in patterns],
		fillmode = "overlay",
		size = Float64[field(pattern, :size, _STATS_PATTERN_DEFAULT_SIZE) for pattern in patterns],
		solidity = Float64[
			field(pattern, :solidity, _STATS_PATTERN_DEFAULT_SOLIDITY) for pattern in patterns
		],
	)
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
# untouched. `ykey` is the y axis the call draws on (see
# `_scat_validate_cartesian_options`; `nothing`: a twin y axis not created yet).
function _stats_validate_options(
	fig,
	who::AbstractString,
	options;
	ykey::Union{Nothing, Symbol} = :yaxis,
)
	# The family validator of the scatter family checks ranges with the
	# `xrange!` semantics and tick values/presets against the final axis type.
	_scat_validate_cartesian_options(
		fig,
		who;
		ykey = ykey,
		xrange = options.xrange,
		yrange = options.yrange,
		xscale = options.xscale,
		yscale = options.yscale,
		width = options.width,
		height = options.height,
		fontsize = options.fontsize,
		grid = options.grid,
		xticks = options.xticks,
		xticklabels = options.xticklabels,
		yticks = options.yticks,
		yticklabels = options.yticklabels,
	)
	_stats_label(options.title)
	_stats_label(options.xlabel)
	_stats_label(options.ylabel)
	return nothing
end

# Apply the validated common keywords through the D7 primitives. Constructors
# keep the template grid for their default `grid = true`; mutators default to
# `nothing` (unchanged) and apply every explicit value, so `grid = true`
# re-enables a grid that was switched off earlier. The y keywords address
# `ykey`: the primary y axis, or the twin y axis of `secondary_y = true` (the
# key-based primitives give it the same semantics as the primary axis).
function _stats_apply_options!(
	fig,
	who::AbstractString,
	options;
	mutator::Bool,
	ykey::Symbol = :yaxis,
)
	_apply_figure_title!(fig, options.title)
	_apply_axis_title!(fig, :x, options.xlabel)
	_apply_axis_title_to_key!(fig, ykey, options.ylabel)
	# Scale before range and ticks: a logarithmic axis stores its range as
	# exponents and takes tick values in data units.
	_apply_axis_scale!(fig, :x, options.xscale, who)
	_apply_axis_scale_to_key!(fig, ykey, options.yscale, who; name = "yscale")
	_apply_axis_range!(fig, :x, _scat_range_arg(options.xrange), who)
	_apply_axis_range_to_key!(fig, ykey, _scat_range_arg(options.yrange), who; name = "yrange")
	# Tick values, labels and the D9 presets (`:decades`, `:auto`) go to
	# `_apply_ticks!` unchanged.
	_scat_apply_ticks!(fig, :xaxis, options.xticks, options.xticklabels, options.xtickformat, who)
	_scat_apply_ticks!(fig, ykey, options.yticks, options.yticklabels, options.ytickformat, who)
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

# Mutators take the constructor keywords minus `show`; their `kwargs...` carry
# `secondary_y` (a twin y axis on a Plot/SyncPlot, C35) and turn `show` and any
# other unknown keyword into a clear error. As in the scatter family,
# `row = nothing`/`col = nothing` (no cell) are accepted on a Plot/SyncPlot.
# Returns `secondary_y`.
_stats_mutator_options(who::AbstractString, kwargs) = _scat_mutator_options(who, kwargs)

# The y axis a statistics call draws on (C35): `:yaxis`, or with
# `secondary_y = true` the twin y axis of a Plot/SyncPlot, created on first use
# by `_ensure_twin_y!` (which refuses a non-Cartesian figure before writing).
# Call after every keyword is validated; validate with
# `ykey = _scat_twin_key(fig, secondary_y)`. Returns the layout key and the
# trace reference ("y2", ...; "" for the primary axis).
function _stats_target_y!(fig, secondary_y::Bool, who::AbstractString)
	secondary_y || return (:yaxis, "")
	key = _ensure_twin_y!(fig; who = who)
	return (key, _cmn_axis_ref(key; who = who))
end

# Bind the traces of one call to the twin y axis (`yref` "" keeps the primary).
function _stats_bind_y!(traces, yref::AbstractString)
	isempty(yref) && return traces
	for trace in traces
		trace.fields[:yaxis] = yref
	end
	return traces
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

# Run a stats mutator on a SubplotFigure cell (or inset, `inset = k`) with
# `_STATS_SUBPLOT_CELL` set to the context of the axes it draws on. The
# (reentrant) metadata lock is held from the lookup to the commit so another
# task cannot change the cell in between. An explicit `barmode` that changes
# the layout of bars on other axes (plotly's bar mode is one figure-wide
# setting; unset means plotly's "group") is reported with one warning after the
# call succeeds, when some other axes hold two or more bar-like traces (the
# only bars a mode change moves).
function _stats_subplot_delegate!(
	sf::SubplotFigure,
	mutator,
	args...;
	row,
	col,
	secondary_y::Bool,
	who::AbstractString,
	inset = nothing,
	kwargs...,
)
	return lock(getfield(sf, :_lock)) do
		root = _plot_obj(getfield(sf, :fig))
		target = _cell_target(
			sf;
			row = row,
			col = col,
			secondary_y = secondary_y,
			inset = inset,
			who = who,
		)
		cell_traces = Any[]
		# Bar-like traces on the OTHER axes, counted per axis pair: plotly.js
		# positions bars per subplot (one x/y pair; a twin y is its own pair), so
		# the bar mode only re-arranges a pair that holds two or more of them. A
		# single series per pair is drawn the same in every mode. Hidden traces
		# are counted too, which errs towards warning.
		others_bars = Dict{Tuple{String, String}, Int}()
		for trace in root.data
			fields = trace.fields
			if target.kind === :xy && _stats_trace_on(fields, target.xref, target.yref)
				push!(cell_traces, fields)
			elseif _stats_is_barlike(trace)
				pair = (string(get(fields, :xaxis, "x")), string(get(fields, :yaxis, "y")))
				others_bars[pair] = get(others_bars, pair, 0) + 1
			end
		end
		others_grouped = any(count -> count >= 2, Base.values(others_bars))
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
				inset = inset,
				kwargs...,
			)
		end
		# `bargap`/`bargroupgap` are figure-wide plotly settings that the cell
		# delegate does not carry to the root layout; the mutator above has
		# validated them (it threw before any change otherwise), so they are
		# written to the figure here.
		gaps = Pair{Symbol, Any}[
			key => values(kwargs)[key] for key in (:bargap, :bargroupgap)
			if get(values(kwargs), key, nothing) !== nothing
		]
		isempty(gaps) || relayout!(sf; gaps...)
		requested = get(values(kwargs), :barmode, "")
		current = root_barmode === nothing ? "group" : root_barmode
		if others_grouped && requested isa AbstractString && !isempty(requested) &&
			requested != current
			@warn "$(who): `barmode = $(repr(requested))` replaces the figure-wide " *
				"bar mode $(repr(current)) for the WHOLE figure: plotly has one " *
				"`layout.barmode` for every subplot, so the bars and histograms " *
				"already in other cells are re-arranged too."
		end
		return result
	end
end

# ── Trace builders ──────────────────────────────────────────────────────────

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

# Docstring fragments shared by the scatter, statistics and lines.jl families
# (interpolated into their docstrings; the list items continue with a 2-space
# indent).
const _SCAT_RANGE_DOC = """
`xrange = [0, 0]`, `yrange = [0, 0]`: axis range `[lo, hi]` or `(lo, hi)` in
  data units, also on a logarithmic axis (bounds must then be positive), with
  exactly the semantics of [`xrange!`](@ref)/[`yrange!`](@ref) (both are
  checked and applied by the same helpers): `[0, 0]`, `nothing` or
  `[nothing, nothing]` autoscale; a one-sided limit `(lo, nothing)` or
  `(nothing, hi)` is handled as `yrange!` handles it; bounds must differ and
  must not be `Bool`, and a linear or category axis needs numeric bounds."""
const _SCAT_TICKS_DOC = """
`xticks = nothing`, `yticks = nothing`: tick positions in data units, or a
  preset: `:decades` (one labelled tick per power of ten; logarithmic axis
  only) or `:auto` (plotly's automatic ticks). `xticklabels`, `yticklabels`:
  one label per tick value (not with a preset); `xtickformat = ""`,
  `ytickformat = ""`: d3 tick format (e.g. `".2f"`)."""
const _SCAT_LEGEND_DOC = """
While the default legend position is `:topright` (see
[`set_default_legend_position!`](@ref)), the legend of a `Plot`/`SyncPlot`,
and each cell legend of a `SubplotFigure` (Cartesian cells with any y axes,
polar cells), goes where its box covers the fewest data points, line segments
and filled areas (and, in a polar cell, the tick labels): the corners
first (top right, top left, bottom left, bottom right), then the middle of
the right, left, bottom and top edges, then the centre. Later calls of the
scatter and line families move it again as data is added, as long as it sits
where this rule put it; a legend placed anywhere else (`set_legend!`,
`relayout!`) keeps its place. When every position covers something the
legend takes the one covering the least; move it with `set_legend!` (e.g. to
an `:outside_*` position) then. A trace the estimate does not model (bars,
heatmaps, other x axes, stacked fills or fills to another trace) or
non-numeric coordinates make the data extent unknown; the rule then uses the
top-right default."""
const _SCAT_INSET_DOC = """
`row`/`col` select the cell (default: the active
  cell) and `inset = k` draws on inset `k` (see [`inset!`](@ref)); the axis
  keywords then address the inset's axes."""

# `[nothing, nothing]` (or `(nothing, nothing)`) is an automatic range, as for
# `xrange!`; the other automatic sentinels (`[0, 0]`, `(0, 0)`, `nothing`) are
# recognised by `_is_auto_range`.
_scat_is_unset_range(range) =
	(range isa AbstractVector || range isa Tuple) && length(range) == 2 &&
	all(bound -> bound === nothing, range)

# A range keyword as the D7 primitives expect it: `[nothing, nothing]` becomes
# `nothing` (automatic); everything else is passed on unchanged.
_scat_range_arg(range) = _scat_is_unset_range(range) ? nothing : range

# Validate a polar range keyword (`rrange`, `trange` of plot_scatterpolar):
# `[0, 0]`, `(0, 0)`, `nothing` and `[nothing, nothing]` are automatic
# (returns `nothing`); otherwise exactly two finite bounds, neither
# `nothing`/`missing` nor `Bool`, and not equal. A polar sector or radial range
# is always two-sided (the one-sided Cartesian limits of D11 do not apply), so
# this check rejects a missing bound itself, whatever `_checked_range` accepts.
# Returns the bounds as a 2-element vector. Writes nothing. The Cartesian
# `xrange`/`yrange` keywords are checked by `_scat_validate_cartesian_options`
# through the shared primitives instead.
function _scat_checked_range(range, who::AbstractString, name::AbstractString)
	_scat_is_unset_range(range) && return nothing
	# A missing bound is rejected before the shared check, which may accept
	# one-sided Cartesian limits.
	if (range isa AbstractVector || range isa Tuple) && length(range) == 2
		any(bound -> bound === nothing || bound === missing, range) && throw(ArgumentError(
			"$(who): `$(name)` must give both bounds; partial ranges are not " *
			"supported here (use [0, 0] or `nothing` for an automatic range). Got " *
			"$(repr(range)).",
		))
	end
	checked = _checked_range(range, who, name)
	checked === nothing && return nothing
	for bound in checked
		bound isa Bool && throw(ArgumentError(
			"$(who): `$(name)` bounds must be numbers (or date/category values); got " *
			"$(repr(range)).",
		))
	end
	isequal(checked[1], checked[2]) && throw(ArgumentError(
		"$(who): the `$(name)` bounds must differ; got $(repr(range)) (use [0, 0] or " *
		"`nothing` for an automatic range).",
	))
	return checked
end

# Validate the common Cartesian keywords of a scatter-family (and statistics
# and lines.jl) call before its first write, through the shared key-based
# primitives of src/sci/base.jl and src/sci/common.jl, so every family checks
# ranges, scales and ticks exactly as `_apply_cartesian_plot_options!` and
# `xrange!`/`xticks!` do. `ykey` is the y axis the call draws on: `:yaxis`, an
# existing twin axis, or `nothing` for a twin that `_ensure_twin_y!` will
# create (validated as a fresh axis: no type, no range).
#
# Ranges are data units on every axis type (positive on a log axis); which
# shapes are accepted (automatic sentinels, one-sided limits, equal or Bool
# bounds, ...) is decided by `_checked_range`, so this family accepts exactly
# what `xrange!`/`yrange!` accept. Tick values and the D9 presets are checked
# by `_validate_tick_option` against the axis type the call ends up with.
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
	xrange = _scat_range_arg(xrange)
	yrange = _scat_range_arg(yrange)
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
		# A twin that does not exist yet starts with no type and no range, as
		# the y axis of an empty figure does.
		target, key = ykey === nothing ?
			(Plot(GenericTrace[], Layout()), :yaxis) : (fig, ykey)
		_require_axis_range_for_key(target, key, yrange, yscale, who; name = "yrange")
	end
	_validate_tick_option(fig, :xaxis, xticks, xticklabels, xscale, who, "x")
	_validate_tick_option(fig, ykey, yticks, yticklabels, yscale, who, "y")
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
	# Shared with the statistical family (`_stats_mutator_options`).
	any(pair -> first(pair) === :show, kwargs) && throw(ArgumentError(
		"$(who): mutators do not take `show`; display the figure with `display(fig)` " *
		"or pass `show = true` to the constructor.",
	))
	secondary_y = false
	unknown = Symbol[]
	for (key, value) in kwargs
		if key === :secondary_y
			value isa Bool || throw(ArgumentError(
				"$(who): `secondary_y` must be true or false; got $(repr(value)).",
			))
			secondary_y = value
		elseif key === :row || key === :col
			value === nothing || throw(ArgumentError(
				"$(who): `row`/`col` select a SubplotFigure cell; a single figure " *
				"has one cell, so omit them.",
			))
		else
			push!(unknown, key)
		end
	end
	isempty(unknown) || throw(ArgumentError(
		"$(who): unsupported keyword argument(s) $(join(("`$(key)`" for key in unknown), ", ")); " *
		"see the docstring for the accepted keywords.",
	))
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
# series, holding the validated keyword values exactly as the caller gave them
# (sentinels included). The active PlotStyle's per-trace defaults (line width,
# marker size, dash/marker cycle) are filled into the finished traces by
# `_scat_apply_style!` (`_apply_style_trace_defaults!`), not here.
function _scat_series_styles(
	n::Int,
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
	for index in 1:n
		styles[index] = (
			mode = modes[index],
			name = names[index],
			color = colors[index],
			dash = dashes[index],
			linewidth = widths[index],
			marker_size = sizes[index],
			marker_symbol = symbols[index],
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

# plotly.js layout `font.color` default (`Color.defaultLine`, plotly.js 2.35.2
# schema): the colour of text when neither the layout nor its template sets one.
const _SCAT_PLOTLY_FONT_COLOR = "#444"

# Colour plotly draws trace text in when the trace sets none: the figure's
# `layout.font.color`, else its template's, else plotly's default. Inside a
# SubplotFigure call the real figure is read (the scratch figure has neither).
function _scat_text_color(fig)
	context = _SCAT_SUBPLOT_CONTEXT[]
	layout = _plot_layout(context === nothing ? fig : context.figure)
	value = _cmn_mapping_get(get(layout.fields, :font, nothing), :color)
	(value isa AbstractString && !isempty(value)) && return String(value)
	template = _figure_template(layout)
	if template !== nothing
		font = get(_template_layout_fields(template), :font, nothing)
		value = _cmn_mapping_get(font, :color)
		(value isa AbstractString && !isempty(value)) && return String(value)
	end
	return _SCAT_PLOTLY_FONT_COLOR
end

# `markevery` hides the skipped markers through `selectedpoints` (see
# `_markevery_fields`), and plotly.js 2.35.2 then also dims the TEXT of every
# unselected point unless `unselected.textfont.color` or
# `selected.textfont.color` is set (`makeSelectedTextStyleFns`: unselected
# text is `addOpacity(color, DESELECTDIM)` otherwise), so labels of the
# skipped points faded (G28). For the traces at `indices` that have both, pin
# the text colour: `textfont.color` and `unselected.textfont.color` get the
# trace's own text colour, else the colour plotly would draw the text in
# (`_scat_text_color`, read after the template is applied), so every label is
# drawn alike. Pinned labels keep that colour if the template changes later.
function _scat_pin_markevery_text!(fig, indices)
	data = _plot_data(fig)
	color = nothing
	for index in indices
		fields = data[index].fields
		(haskey(fields, :selectedpoints) && get(fields, :text, nothing) !== nothing) || continue
		textfont_fields = _scat_attr_fields(get(fields, :textfont, nothing))
		text_color = get(textfont_fields, :color, nothing)
		if !(text_color isa AbstractString && !isempty(text_color))
			color === nothing && (color = _scat_text_color(fig))
			text_color = color
		end
		textfont_fields[:color] = text_color
		fields[:textfont] = attr(textfont_fields)
		unselected_fields = _scat_attr_fields(get(fields, :unselected, nothing))
		unselected_textfont = _scat_attr_fields(get(unselected_fields, :textfont, nothing))
		unselected_textfont[:color] = text_color
		unselected_fields[:textfont] = attr(unselected_textfont)
		fields[:unselected] = attr(unselected_fields)
	end
	return nothing
end

# A fresh `Dict{Symbol, Any}` copy of a plotly attribute value (a
# `PlotlyAttribute` or a dictionary; anything else gives an empty one).
function _scat_attr_fields(value)
	out = Dict{Symbol, Any}()
	if value isa PlotlyBase.PlotlyAttribute
		merge!(out, value.fields)
	elseif value isa AbstractDict
		for (key, entry) in value
			out[Symbol(key)] = entry
		end
	end
	return out
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
	row = get(kwargs, :row, nothing)
	col = get(kwargs, :col, nothing)
	in_context = function (target, values...; options...)
		plot = _plot_obj(getfield(sf, :fig))
		groups = Set{String}()
		for trace in plot.data
			group = get(trace.fields, :legendgroup, nothing)
			group isa AbstractString && push!(groups, String(group))
		end
		context = (
			figure = sf,
			offset = length(plot.data),
			legend_groups = groups,
			polar = _scat_cell_polar_layout(sf, plot, row, col),
		)
		# The style's dash/marker cycle continues the real figure's line-style
		# traces instead of restarting at the scratch figure's first trace.
		return Base.ScopedValues.with(_SCAT_SUBPLOT_CONTEXT => context) do
			_with_style_trace_offset(plot) do
				mutator(target, values...; options...)
			end
		end
	end
	return _subplot_delegate_mutator!(sf, in_context, args...; kwargs...)
end

# Polar subplot layout (`layout.polar2`, ...) of the SubplotFigure cell a call
# targets (`row`/`col`, else the active cell), or `nothing` when that cell is
# not a polar subplot or has no layout yet. Read while the delegate holds the
# figure (it has validated `row`/`col` by then).
function _scat_cell_polar_layout(sf::SubplotFigure, plot, row, col)
	r, c = row === nothing || col === nothing ?
		(getfield(sf, :current_row), getfield(sf, :current_col)) : (Int(row), Int(col))
	grid_ref = plot.layout.subplots.grid_ref
	(checkbounds(Bool, grid_ref, r, c) && isassigned(grid_ref, r, c) &&
		!isempty(grid_ref[r, c])) || return nothing
	ref = grid_ref[r, c][1]
	(String(ref.subplot_kind) == "polar" && !isempty(ref.layout_keys)) || return nothing
	return get(plot.layout.fields, ref.layout_keys[1], nothing)
end

# Layout of the polar subplot a scatterpolar call draws on: `layout.polar` of
# `fig`, or, while a SubplotFigure call builds its traces in a scratch figure,
# the target cell's polar subplot of the real figure.
function _scat_polar_layout(fig)
	context = _SCAT_SUBPLOT_CONTEXT[]
	context === nothing || return context.polar
	return get(_plot_layout(fig).fields, :polar, nothing)
end

# ── Default legend position (lead review V5) ────────────────────────────────
# matplotlib's `loc = "best"` for the package-default legend position: while
# the default position is :topright, the legend of a Plot/SyncPlot goes to the
# first position of `_SCAT_LEGEND_POSITIONS` (matplotlib's candidate order:
# the four corners, then the middle of the right, left, bottom and top edges,
# then the centre) whose estimated box covers the fewest data points (markers,
# error-bar ends), line segments and filled areas of the traces on the main x
# axis (primary or secondary y). Each call of this family re-evaluates a
# legend it created, or one that still sits where the rule puts it for the
# figure as it stood before the call (so the rule placed it); a legend
# anywhere else was placed by the user (`set_legend!`, `relayout!`) and is
# never moved. A trace the estimate does not model (another type or x axis, a
# stacked fill or a fill to another trace) or non-numeric coordinates
# (categories, dates) make the data extent unknown: the legend then goes to,
# or stays at, the default top-right corner. SubplotFigure cell legends follow
# the same rule per cell (`_legend_best_cell_position`). Known limit: a legend
# the user puts exactly where the rule would put it is indistinguishable from
# an automatic one and follows the data too.
const _SCAT_LEGEND_POSITIONS =
	(:topright, :topleft, :bottomleft, :bottomright, :right, :left, :bottom, :top, :center)
# Legend size estimate in px for a 12 px legend font: one entry per 20 px row
# plus 10 px padding; 50 px for the sample line and padding plus 7 px per label
# character. Used only to compare corners, so a rough estimate suffices.
const _SCAT_LEGEND_ROW_PX = 20.0
const _SCAT_LEGEND_PAD_PX = 10.0
const _SCAT_LEGEND_SAMPLE_PX = 50.0
const _SCAT_LEGEND_CHAR_PX = 7.0
# Figure size and margins (px) assumed when the layout does not set them:
# plotly.js' default margins (l = r = 80, t = 100, b = 80) on a 700 x 500 figure
# (the package's `savefig` default page).
const _SCAT_LEGEND_FIGURE_PX = (700.0, 500.0)
const _SCAT_LEGEND_MARGIN_PX = (l = 80.0, r = 80.0, t = 100.0, b = 80.0)
# Traces longer than this are sampled with a stride when scoring corners
# (bounds the cost on million-point traces; the score is an estimate anyway).
const _SCAT_LEGEND_MAX_POINTS = 100_000

_scat_legend_placed(fig) = begin
	legend = get(_plot_layout(fig).fields, :legend, nothing)
	_cmn_mapping_get(legend, :x) !== nothing || _cmn_mapping_get(legend, :y) !== nothing
end

function _scat_layout_px(layout, key::Symbol, default::Float64)
	value = get(layout.fields, key, nothing)
	return value isa Real && !(value isa Bool) && value > 0 ? Float64(value) : default
end

# Coordinates of `values` on an axis of type `axis_type` (log10 on a log axis);
# `nothing` when a value is neither numeric nor a gap (the extent is unknown).
function _scat_legend_coords(values, log_axis::Bool)
	values isa AbstractVector || return nothing
	out = Vector{Float64}(undef, length(values))
	for (index, value) in enumerate(values)
		if value === nothing || value === missing
			out[index] = NaN
		elseif value isa Real && !(value isa Bool)
			v = Float64(value)
			out[index] = log_axis ? (v > 0 ? log10(v) : NaN) : v
		else
			return nothing
		end
	end
	return out
end

# Error-bar extents `(minus, plus)` of a trace's `error_x`/`error_y` attribute
# (absolute magnitudes per point), or `nothing`.
function _scat_legend_errors(error, n::Int)
	error === nothing && return nothing
	_cmn_mapping_get(error, :visible) === false && return nothing
	plus = _cmn_mapping_get(error, :array)
	plus isa AbstractVector || return nothing
	minus = _cmn_mapping_get(error, :symmetric) === false ?
		_cmn_mapping_get(error, :arrayminus) : plus
	minus isa AbstractVector || (minus = plus)
	value(v, i) = i <= length(v) && v[i] isa Real && isfinite(v[i]) ? Float64(v[i]) : 0.0
	return [value(minus, i) for i in 1:n], [value(plus, i) for i in 1:n]
end

# Whether the segment (x1, y1)-(x2, y2) meets the box [u0, u1] x [v0, v1]
# (Liang-Barsky clipping).
function _scat_segment_hits_box(x1, y1, x2, y2, u0, u1, v0, v1)
	t0, t1 = 0.0, 1.0
	dx, dy = x2 - x1, y2 - y1
	for (p, q) in ((-dx, x1 - u0), (dx, u1 - x1), (-dy, y1 - v0), (dy, v1 - y1))
		if p == 0
			q < 0 && return false
		else
			r = q / p
			if p < 0
				r > t1 && return false
				r > t0 && (t0 = r)
			else
				r < t0 && return false
				r < t1 && (t1 = r)
			end
		end
	end
	return true
end

# Share of the axis length plotly.js' autorange leaves empty beyond a padded
# extreme: plotly.js 2.35.2 `makePadFn` pads it by `0.05 * ax._length` px,
# while a `tozero` extreme at 0 (a `fill = "tozeroy"` baseline) gets no pad.
# The few px of marker radius plotly adds as well are ignored.
const _SCAT_LEGEND_AUTORANGE_PAD = 0.05

# The data window `(lo, hi)` of axis `key` in its stored units: the explicit
# range, else the extent of `values` (the coordinates drawn on it) widened as
# plotly's autorange does when `padded` (plotly pads every scatter y axis, and
# the x axis of traces with markers, text or y error bars). With `tight_zero`,
# an extreme at exactly 0 is not padded.
function _scat_legend_window(layout, key::Symbol, values; padded::Bool, tight_zero::Bool = false)
	axis = get(layout.fields, key, nothing)
	range = _cmn_mapping_get(axis, :range)
	autorange = _cmn_mapping_get(axis, :autorange)
	is_bound(bound) = bound isa Real && !(bound isa Bool) && isfinite(bound)
	explicit = autorange !== true && range isa AbstractVector && length(range) == 2
	if explicit && all(is_bound, range) && range[1] != range[2]
		return Float64(range[1]), Float64(range[2])
	end
	finite = Iterators.filter(isfinite, values)
	isempty(finite) && return nothing
	lo, hi = extrema(finite)
	lo == hi && ((lo, hi) = (lo - 0.5, hi + 0.5))
	pad_lo = padded && !(tight_zero && lo == 0) ? _SCAT_LEGEND_AUTORANGE_PAD : 0.0
	pad_hi = padded && !(tight_zero && hi == 0) ? _SCAT_LEGEND_AUTORANGE_PAD : 0.0
	# The data spans the axis length minus both pads.
	scale = (hi - lo) / (1 - pad_lo - pad_hi)
	lo, hi = lo - pad_lo * scale, hi + pad_hi * scale
	# A one-sided limit (lead decision D11: `range = [lo, nothing]` or
	# `[nothing, hi]` next to a partial `autorange`): the fixed bound, and the
	# padded data extent on the autoscaled side. A data extent that does not
	# reach past the fixed bound leaves the data-only window.
	if explicit && count(is_bound, range) == 1 && any(isnothing, range)
		if is_bound(range[1]) && hi > range[1]
			return Float64(range[1]), hi
		elseif is_bound(range[2]) && lo < range[2]
			return lo, Float64(range[2])
		end
	end
	return autorange == "reversed" ? (hi, lo) : (lo, hi)
end

# Vertices of the line plotly.js draws from (u1, v1) to (u2, v2) for the
# scatter `line.shape` `shape` (plotly.js 2.35 `line_points`: "hv" goes
# across then up, "vh" up then across, "hvh"/"vhv" turn at the midpoint;
# "linear" and "spline" are scored as the straight segment).
function _scat_legend_step_path(shape::AbstractString, u1, v1, u2, v2)
	if shape == "hv"
		return ((u1, v1), (u2, v1), (u2, v2))
	elseif shape == "vh"
		return ((u1, v1), (u1, v2), (u2, v2))
	elseif shape == "hvh"
		um = (u1 + u2) / 2
		return ((u1, v1), (um, v1), (um, v2), (u2, v2))
	elseif shape == "vhv"
		vm = (v1 + v2) / 2
		return ((u1, v1), (u1, vm), (u2, vm), (u2, v2))
	end
	return ((u1, v1), (u2, v2))
end

function _scat_legend_path_hits_box(path, u0, u1, v0, v1)
	for index in 1:(length(path) - 1)
		a, b = path[index], path[index + 1]
		_scat_segment_hits_box(a[1], a[2], b[1], b[2], u0, u1, v0, v1) && return true
	end
	return false
end

# The position of `_SCAT_LEGEND_POSITIONS` for the default legend of `p`, or
# `nothing` when the data extent is unknown: a visible trace this estimate does
# not model (another trace type, another x axis, a stacked fill or a fill to
# another trace) or non-numeric coordinates.
function _scat_best_legend_position(p::Plot)
	width_px, height_px = _scat_legend_figure_px(p.layout)
	return _scat_best_legend_position(p, eachindex(p.data), :xaxis, "x", width_px, height_px)
end

# The scoring of `_scat_best_legend_position` for the traces `indices` of `p`
# drawn on x axis `xref` (layout key `xkey`, any y axes) in a plot area of
# `width_px` x `height_px`; `box = (w, h)` is the legend size in px (else the
# rough per-entry estimate above). `obstacles` are rectangles
# `(u0, u1, v0, v1)` (fractions of the plot area, e.g. insets) a legend box
# must not cover: each scores like a filled area, by the share of the box it
# covers. Used for a Plot (all traces, main axes) and for a SubplotFigure cell
# legend (the cell's traces, `_legend_best_cell_position`).
function _scat_best_legend_position(
	p::Plot,
	indices,
	xkey::Symbol,
	xref::AbstractString,
	width_px::Float64,
	height_px::Float64,
	box = nothing;
	obstacles = (),
)
	layout = p.layout
	entries = 0
	widest = 0
	# (y axis key, x coordinates, y coordinates, kind, line shape): `:points`
	# are scored where they lie, `:segments` join consecutive points with the
	# trace's line shape, `:drops` join each point to y = 0 (the area of a
	# `fill = "tozeroy"` trace), `:polygon` is the closed area of a
	# `fill = "toself"` trace (`_scat_legend_fill_scores!`).
	series = Tuple{Symbol, Vector{Float64}, Vector{Float64}, Symbol, String}[]
	xpadded = false
	for trace_index in indices
		trace = p.data[trace_index]
		trace isa GenericTrace || return nothing
		fields = trace.fields
		if _trace_will_showlegend(trace)
			entries += 1
			name = get(fields, :name, "")
			widest = max(widest, length(string(name)))
		end
		visible = get(fields, :visible, true)
		(visible === false || visible == "legendonly") && continue
		string(get(fields, :type, "scatter")) in ("scatter", "scattergl") || return nothing
		string(get(fields, :xaxis, "x")) == xref || return nothing
		# Stacked fills and fills to another trace or to x = 0 cover areas
		# these scores do not model.
		haskey(fields, :stackgroup) && return nothing
		fill = string(get(fields, :fill, ""))
		fill in ("", "none", "tozeroy", "toself") || return nothing
		ykey = _axis_layout_key(string(get(fields, :yaxis, "y")), :y)
		ylog = _axis_type(layout, ykey) == "log"
		xs = _scat_legend_coords(get(fields, :x, nothing), _axis_type(layout, xkey) == "log")
		ys = _scat_legend_coords(get(fields, :y, nothing), ylog)
		(xs === nothing || ys === nothing) && return nothing
		n = min(length(xs), length(ys))
		n == 0 && continue
		xs, ys = xs[1:n], ys[1:n]
		mode = string(get(fields, :mode, "lines+markers"))
		shape = _cmn_mapping_get(get(fields, :line, nothing), :shape)
		shape = shape isa AbstractString ? String(shape) : "linear"
		# plotly.js 2.35.2 scatter `calcAxisExpansion`: the x extremes are padded
		# with y error bars, or with markers or text unless the trace fills to y = 0.
		xpadded |= _scat_legend_errors(get(fields, :error_y, nothing), n) !== nothing ||
			(fill != "tozeroy" && (occursin("markers", mode) || occursin("text", mode)))
		# Error-bar ends count as points (on linear axes; log axes keep the
		# points only).
		extra_x, extra_y = Float64[], Float64[]
		for (letter, error) in ((:y, get(fields, :error_y, nothing)), (:x, get(fields, :error_x, nothing)))
			bounds = _scat_legend_errors(error, n)
			bounds === nothing && continue
			axis_key = letter === :y ? ykey : xkey
			_axis_type(layout, axis_key) == "log" && continue
			minus, plus = bounds
			if letter === :y
				append!(extra_x, xs, xs)
				append!(extra_y, ys .- minus, ys .+ plus)
			else
				append!(extra_x, xs .- minus, xs .+ plus)
				append!(extra_y, ys, ys)
			end
		end
		push!(series, (ykey, vcat(xs, extra_x), vcat(ys, extra_y), :points, shape))
		occursin("lines", mode) && push!(series, (ykey, xs, ys, :segments, shape))
		fill == "tozeroy" && !ylog && push!(series, (ykey, xs, ys, :drops, shape))
		fill == "toself" && push!(series, (ykey, xs, ys, :polygon, shape))
	end
	(box === nothing ? entries == 0 || isempty(series) : isempty(series) && isempty(obstacles)) &&
		return nothing

	xwindow = isempty(series) ? (0.0, 1.0) : _scat_legend_window(
		layout, xkey, Iterators.flatten(s[2] for s in series); padded = xpadded,
	)
	xwindow === nothing && return nothing
	ywindows = Dict{Symbol, Any}()
	for key in unique(s[1] for s in series)
		# A filled area reaches down to 0, which the autorange includes unpadded.
		filled = any(s -> s[1] === key && s[4] === :drops, series)
		ywindows[key] = _scat_legend_window(
			layout,
			key,
			Iterators.flatten((Iterators.flatten(s[3] for s in series if s[1] === key), filled ? (0.0,) : ()));
			padded = true,
			tight_zero = filled,
		)
	end

	box_w, box_h = if box === nothing
		(
			min(0.6, (_SCAT_LEGEND_SAMPLE_PX + _SCAT_LEGEND_CHAR_PX * widest) / width_px),
			min(0.6, (_SCAT_LEGEND_PAD_PX + _SCAT_LEGEND_ROW_PX * entries) / height_px),
		)
	else
		(min(0.95, box[1] / width_px), min(0.95, box[2] / height_px))
	end
	# The box of each candidate, from the anchor point and anchors the legend
	# would get there.
	boxes = map(_SCAT_LEGEND_POSITIONS) do position
		x, y, xanchor, yanchor =
			_legend_anchor((0.0, 1.0), (0.0, 1.0), _DEFAULT_LEGEND_INSET[], position)
		u0 = xanchor == "left" ? x : xanchor == "right" ? x - box_w : x - box_w / 2
		v0 = yanchor == "bottom" ? y : yanchor == "top" ? y - box_h : y - box_h / 2
		return (u0, u0 + box_w, v0, v0 + box_h)
	end
	scores = zeros(Int, length(boxes))
	xlo, xhi = xwindow
	for (ykey, xs, ys, kind, shape) in series
		ywindow = ywindows[ykey]
		ywindow === nothing && continue
		ylo, yhi = ywindow
		v_zero = (0.0 - ylo) / (yhi - ylo)
		count = length(xs)
		stride = max(1, cld(count, _SCAT_LEGEND_MAX_POINTS))
		if kind === :polygon
			us = [(xs[index] - xlo) / (xhi - xlo) for index in 1:stride:count]
			vs = [(ys[index] - ylo) / (yhi - ylo) for index in 1:stride:count]
			_scat_legend_fill_scores!(scores, us, vs, boxes)
			continue
		end
		previous = nothing
		for index in 1:stride:count
			u = (xs[index] - xlo) / (xhi - xlo)
			v = (ys[index] - ylo) / (yhi - ylo)
			if !(isfinite(u) && isfinite(v))
				previous = nothing
				continue
			end
			path = kind === :segments && previous !== nothing ?
				_scat_legend_step_path(shape, previous[1], previous[2], u, v) : nothing
			for (corner, (u0, u1, v0, v1)) in enumerate(boxes)
				hit = if kind === :segments
					path !== nothing && _scat_legend_path_hits_box(path, u0, u1, v0, v1)
				elseif kind === :drops
					_scat_segment_hits_box(u, v, u, v_zero, u0, u1, v0, v1)
				else
					u0 <= u <= u1 && v0 <= v <= v1
				end
				hit && (scores[corner] += 1)
			end
			previous = (u, v)
		end
	end
	samples = _SCAT_LEGEND_FILL_SAMPLES^2
	for (a0, a1, b0, b1) in obstacles
		for (corner, (u0, u1, v0, v1)) in enumerate(boxes)
			overlap = max(0.0, min(u1, a1) - max(u0, a0)) * max(0.0, min(v1, b1) - max(v0, b0))
			overlap > 0 && (scores[corner] += ceil(Int, samples * overlap / ((u1 - u0) * (v1 - v0))))
		end
	end
	# `argmin` returns the first minimum: ties keep the candidate order.
	return _SCAT_LEGEND_POSITIONS[argmin(scores)]
end

# Samples per box side for `_scat_legend_fill_scores!` (5 x 5 = 25 points: a
# box covering a filled area outweighs one crossing a few line segments).
const _SCAT_LEGEND_FILL_SAMPLES = 5

# Add to `scores[k]` the share of candidate box `boxes[k]` a `fill = "toself"`
# area covers: the number of a regular grid of sample points of the box inside
# the polygon(s) `us`, `vs` (unit axes coordinates; rings separated by
# non-finite values, each closed back to its first vertex as plotly.js fills
# them; even-odd rule).
function _scat_legend_fill_scores!(scores::Vector{Int}, us::Vector{Float64}, vs::Vector{Float64}, boxes)
	edges = NTuple{4, Float64}[]
	start = 0
	n = length(us)
	for index in 1:(n + 1)
		if index <= n && isfinite(us[index]) && isfinite(vs[index])
			if start == 0
				start = index
			else
				push!(edges, (us[index - 1], vs[index - 1], us[index], vs[index]))
			end
		else
			start != 0 && index - 1 > start &&
				push!(edges, (us[index - 1], vs[index - 1], us[start], vs[start]))
			start = 0
		end
	end
	isempty(edges) && return scores
	k = _SCAT_LEGEND_FILL_SAMPLES
	for (corner, (u0, u1, v0, v1)) in enumerate(boxes)
		for a in 1:k, b in 1:k
			u = u0 + (a - 0.5) / k * (u1 - u0)
			v = v0 + (b - 0.5) / k * (v1 - v0)
			inside = false
			for (x1, y1, x2, y2) in edges
				if (y1 > v) != (y2 > v) && u < x1 + (v - y1) * (x2 - x1) / (y2 - y1)
					inside = !inside
				end
			end
			inside && (scores[corner] += 1)
		end
	end
	return scores
end

function _scat_legend_figure_px(layout)
	width = _scat_layout_px(layout, :width, _SCAT_LEGEND_FIGURE_PX[1])
	height = _scat_layout_px(layout, :height, _SCAT_LEGEND_FIGURE_PX[2])
	margin = get(layout.fields, :margin, nothing)
	side(name) = begin
		value = _cmn_mapping_get(margin, name)
		value isa Real && !(value isa Bool) && value >= 0 ? Float64(value) :
			Float64(getfield(_SCAT_LEGEND_MARGIN_PX, name))
	end
	return max(width - side(:l) - side(:r), 50.0), max(height - side(:t) - side(:b), 50.0)
end

# Whether the best-position rule applies: on a Plot/SyncPlot (SubplotFigure
# cell legends are placed by the delegate) while the package default position
# is :topright.
_scat_legend_rule_active() =
	_SCAT_SUBPLOT_CONTEXT[] === nothing && _DEFAULT_LEGEND_POSITION[] === :topright

# Placement keys of the legend at `position` with the package default inset
# (as `_apply_default_legend!` writes them).
_scat_position_placement(position::Symbol) = _legend_placement(
	position, (0.0, 1.0), (0.0, 1.0), _DEFAULT_LEGEND_INSET[]; figure = true,
)

# Whether the legend of `p` has exactly the placement keys of `placement`.
function _scat_legend_at(p::Plot, placement)
	legend = get(p.layout.fields, :legend, nothing)
	return all(
		key -> _cmn_mapping_get(legend, key) == get(placement, key, nothing),
		_LEGEND_PLACEMENT_KEYS,
	)
end

# State of the legend of `fig` before a call of this family writes anything:
# `:none` (not placed yet), `:auto` (where this rule puts it for the figure as
# it stands, so the rule placed it and it follows the data) or `:fixed`
# (anywhere else: set by the user, `set_legend!`, `relayout!`, or while the
# rule is off; never moved).
function _scat_legend_state(fig)
	_scat_legend_placed(fig) || return :none
	_scat_legend_rule_active() || return :fixed
	p = _plot_obj(fig)
	any(
		position -> _scat_legend_at(p, _scat_position_placement(position)),
		_SCAT_LEGEND_POSITIONS,
	) || return :fixed
	position = something(_scat_best_legend_position(p), :topright)
	return _scat_legend_at(p, _scat_position_placement(position)) ? :auto : :fixed
end

# After a Plot/SyncPlot call of this family whose legend was `before`
# (`_scat_legend_state` at the start of the call): a legend the call created
# (at the default top-right) or one still at its automatic position moves to
# the position with the least data; a `:fixed` legend stays.
function _scat_place_legend!(fig, before::Symbol)
	before === :fixed && return nothing
	_scat_legend_rule_active() || return nothing
	_scat_legend_placed(fig) || return nothing
	p = _plot_obj(fig)
	# A legend created by this call sits at the package default corner.
	before === :none && !_scat_legend_at(p, _scat_position_placement(:topright)) && return nothing
	placement = _scat_position_placement(something(_scat_best_legend_position(p), :topright))
	_scat_legend_at(p, placement) && return nothing
	_legend_write_block!(p, :legend; placement = placement, replace_placement = true)
	_legend_stack!(p)
	return nothing
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

# Keyword sets passed as `explicit` to `_apply_style_trace_defaults!` for
# traces that must take only some of the active PlotStyle's per-trace
# defaults: filled areas and segment collections take the line width only (no
# dash cycle, no markers on their vertices); dense curves (ECDF steps, KDE) take
# the line width and the dash cycle but no cycle markers, which would hide them.
const _SCAT_STYLE_WIDTH_ONLY = (:dash, :marker_symbol, :marker_size, :mode)
const _SCAT_STYLE_NO_MARKERS = (:marker_symbol, :marker_size, :mode)

# Fill the active PlotStyle's per-trace defaults into the traces at `indices`
# (the traces the calling constructor or mutator just appended to `fig`):
# line width, marker size and the dash/marker cycle wherever the trace leaves
# them unset, positioned by the trace's rank among the figure's line-style
# traces. `explicit` lists the keywords the caller set (never filled, e.g.
# `:mode` when `mode` was passed) plus those the trace kind must not take.
# Inside a SubplotFigure call the cycle continues the real figure's traces
# (`_scat_subplot_delegate!` runs the call under `_with_style_trace_offset`).
# A no-op under the `:default` style.
function _scat_apply_style!(fig, indices; explicit = ())
	isempty(indices) && return nothing
	_apply_style_trace_defaults!(fig, indices; explicit = explicit)
	return nothing
end

# `explicit` entry for a `mode` keyword whose default is `nothing` (unset).
_scat_mode_explicit(mode) = mode === nothing ? () : (:mode,)

# Shared body of plot_scatter / plot_scatter! (and plot_complex(!)): validate
# everything, then append one trace per series and apply the figure options.
# `mode = nothing` means `"lines"` (`default_mode`) left to the active style,
# whose marker cycle may then add markers; an explicit `mode` is kept as given.
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
	mode = nothing,
	default_mode::AbstractString = "lines",
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
	xrange = _scat_range_arg(xrange)
	yrange = _scat_range_arg(yrange)
	n = length(ys)
	lengths = Int[length(series) for series in ys]
	n_existing = _scat_existing_count(fig)
	styles = _scat_series_styles(
		n,
		who;
		mode = something(mode, default_mode),
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

	legend_state = _scat_legend_state(fig)
	ykey = secondary_y ? _ensure_twin_y!(fig; who = who) : :yaxis
	yref = secondary_y ? _cmn_axis_ref(ykey; who = who) : ""
	cliponaxis = clip ? nothing : false
	data = _plot_data(fig)
	first_new = length(data) + 1
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
	_scat_apply_style!(fig, (length(data) - n + 1):length(data); explicit = _scat_mode_explicit(mode))
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
	# After the template: the pinned colour is the one plotly would use.
	_scat_pin_markevery_text!(fig, first_new:(first_new + n - 1))
	_scat_place_legend!(fig, legend_state)
	return nothing
end

# One bar trace. `color` is one colour ("" = the colour cycle) or one per bar;
# `width` (plotly `width`, data units of the position axis) is `nothing`
# (automatic), one number or one per bar.
function _bar_trace(;
	x,
	y,
	color::Union{AbstractString, AbstractVector{<:AbstractString}} = "",
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
	width = nothing,
)
	kw = Dict{Symbol, Any}(:x => x, :y => y, :name => String(name))
	marker = Dict{Symbol, Any}()
	if color isa AbstractVector
		marker[:color] = String[String(entry) for entry in color]
	else
		isempty(color) || (marker[:color] = String(color))
	end
	width === nothing || (kw[:width] = width)
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

function _stats_bar!(
	fig,
	x,
	y,
	who::AbstractString,
	options,
	bar_options;
	mutator::Bool,
	secondary_y::Bool = false,
)
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
		_scat_require_vector(y, who, :y)
		values, positions = y, _auto_xvalues(y)
	else
		# Two-argument form: plotly's convention, `x` and `y` are passed
		# through as given; for horizontal bars `x` holds the values.
		value_name, position_name = horizontal ? ("x", "y") : ("y", "x")
		values, positions = horizontal ? (x, y) : (y, x)
	end
	value_list, position_list, nested =
		_stats_series_lists(values, positions, who, value_name, position_name)
	count = length(value_list)
	bar_counts = Int[length(series) for series in value_list]
	colors = _stats_bar_colors(o.color, bar_counts, nested, who)
	names = _stats_names(o.legend, count)
	showlegends = _stats_showlegends(o.showlegend, count)
	patterns = _stats_bar_patterns(o.hatch, bar_counts, nested, who)
	widths = _stats_bar_widths(o.barwidth, bar_counts, nested, who)
	bargap = _stats_number(o.bargap, who, "bargap", 0, 1)
	bargroupgap = _stats_number(o.bargroupgap, who, "bargroupgap", 0, 1)
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
			width = widths[index],
		)
	end
	_stats_validate_options(fig, who, options; ykey = _scat_twin_key(fig, secondary_y))

	ykey, yref = _stats_target_y!(fig, secondary_y, who)
	append!(_plot_data(fig), _stats_bind_y!(traces, yref))
	_apply_explicit_layout_mode!(fig, :barmode, barmode)
	# Figure-wide plotly settings: written only when given.
	bargap === nothing || relayout!(fig; bargap = bargap)
	bargroupgap === nothing || relayout!(fig; bargroupgap = bargroupgap)
	_stats_apply_options!(fig, who, options; mutator = mutator, ykey = ykey)
	return nothing
end

function _stats_histogram!(
	fig,
	x,
	who::AbstractString,
	options,
	histogram_options;
	mutator::Bool,
	secondary_y::Bool = false,
)
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
	# One mechanism per case for the automatic overlay (no bar mode passed or
	# set): a plain figure without other bar-like traces gets the root
	# `barmode = "overlay"`; a SubplotFigure cell, or a figure whose existing
	# bars are arranged by plotly's default "group" mode, keeps the figure-wide
	# mode and overlays only this call's series through one shared
	# `offsetgroup` (traces of one offset group share their positions under
	# "group"). Under an explicit or existing "overlay" neither is needed.
	slot_overlay = overlay && mode === nothing &&
		(cell !== nothing || any(trace -> _stats_is_barlike(trace), _plot_data(fig)))
	root_overlay = overlay && mode === nothing && !slot_overlay
	group_id = shared ?
		_stats_histogram_group_id(
			sample_list,
			(orientation, nbins, bins, histnorm, o.cumulative),
		) : ""
	trace_opacity = opacity !== nothing ? opacity :
		overlay ? _STATS_OVERLAY_OPACITY : nothing
	horizontal = orientation == "h"
	# The y axis this call draws on (`nothing`: a twin it creates).
	check_ykey = _scat_twin_key(fig, secondary_y)
	log_axis = _stats_log_axis(
		fig,
		horizontal ? options.yscale : options.xscale,
		horizontal ? check_ykey : :xaxis,
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
				# Log-axis bars set `offset`, which plotly always draws
				# overlaid, so only these traces need the shared slot.
				offsetgroup = slot_overlay ? group_id : "",
			)
		end
	end
	_stats_validate_options(fig, who, options; ykey = check_ykey)

	ykey, yref = _stats_target_y!(fig, secondary_y, who)
	append!(_plot_data(fig), _stats_bind_y!(traces, yref))
	if !isempty(barmode)
		_apply_explicit_layout_mode!(fig, :barmode, barmode)
	elseif root_overlay
		_apply_nested_layout_mode!(fig, x, :barmode, "overlay")
	end
	_stats_apply_options!(fig, who, options; mutator = mutator, ykey = ykey)
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
	secondary_y::Bool = false,
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
	_stats_validate_options(fig, who, options; ykey = _scat_twin_key(fig, secondary_y))

	ykey, yref = _stats_target_y!(fig, secondary_y, who)
	append!(_plot_data(fig), _stats_bind_y!(traces, yref))
	group && _apply_nested_layout_mode!(fig, values, mode_key, "group")
	_stats_apply_options!(fig, who, options; mutator = mutator, ykey = ykey)
	return nothing
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
(missing entries take the default, surplus entries are ignored). Keywords left
at their default take the active [`PlotStyle`](@ref)'s per-trace defaults
(line width, marker size, dash and marker cycle; none under `:default`).

- `mode = nothing`: `"lines"`, `"markers"`, `"text"` or a `+` combination
  (`"lines+markers"`), or `"none"`; `""` means `"lines"`. `nothing` draws
  lines, plus markers when the active style has a marker cycle; an explicit
  `mode` is kept as given.
- `dash = ""`: `"solid"`, `"dot"`, `"dash"`, `"longdash"`, `"dashdot"`,
  `"longdashdot"` or a dash-length list such as `"5px,10px"` (`""`: the
  style's dash cycle, else solid).
- `color = ""`: line (and default marker) colour, a CSS colour string or
  `Symbol`; `""` uses the template colorway.
- `legend = ""`: legend name (`AbstractString`, math such as `L"\\alpha"` is
  typeset).
- `linewidth = 0`: line width in px (`0`: the style's width, else plotly's).
- `line_shape = ""`: `"linear"`, `"spline"`, or the step shapes `"hv"`
  (step after the point), `"vh"`, `"hvh"`, `"vhv"`.
- `marker_size = 0`: marker diameter in px (`Real`; `0`: the style's size,
  else plotly's).
- `marker_symbol = ""`: a Plotly symbol (`"circle"`, `"square-open"`, ...) or a
  matplotlib code: `"o"`, `"s"`, `"^"`, `"v"`, `"<"`, `">"`, `"D"`, `"d"`,
  `"x"` (thin x), `"+"` (thin cross), `"*"`, `"p"`, `"h"`, `"."` (small dot);
  `""`: the style's marker cycle, else a circle.
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
  them. With `markevery`, every label is still drawn at full strength: the
  text colour is fixed to the figure's font colour at the time of the call
  (plotly would otherwise fade the labels of the points without a marker), so
  a later template change does not recolour these labels.
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
- $(_SCAT_RANGE_DOC)
- $(_SCAT_TICKS_DOC)
- `equalar = false`: equal data aspect ratio (one x unit spans as many pixels
  as one y unit).
- `grid = true`: `true` keeps the template grid, `false` hides it, `:x`,
  `:y`, `:both` or `:none` choose the axes with grid lines.
- `width = 0`, `height = 0`: figure size in px (`0`: automatic);
  `fontsize = 0`: global font size in px.
- `show = false`: `true` opens the figure in a window and returns the
  `SyncPlot`.

$(_SCAT_LEGEND_DOC)

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
	mode::Union{Nothing, AbstractString, AbstractVector} = nothing,
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
	xrange = _scat_range_arg(xrange)
	yrange = _scat_range_arg(yrange)
	styles = _scat_series_styles(
		n,
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
	# Without an explicit `linewidth`, stems take the active style's line width
	# (filled by `_scat_apply_style!`) or, when the style has none, the thin
	# matplotlib stem width.
	style_width = haskey(_style_trace_defaults(_active_style(), 1), :linewidth)
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

	legend_state = _scat_legend_state(fig)
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
		stem_line = attr(color = stem_color)
		if style.linewidth > 0
			stem_line.fields[:width] = style.linewidth
		elseif !style_width
			stem_line.fields[:width] = _STEM_DEFAULT_LINEWIDTH
		end
		stem = Dict{Symbol, Any}(
			:x => stem_x,
			:y => stem_y,
			:mode => "lines",
			:name => name,
			:line => stem_line,
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
	data = _plot_data(fig)
	append!(data, heads)
	append!(data, stems)
	# Heads (markers only) take the style's marker size and marker cycle; stems
	# take its line width only (solid, no markers, as matplotlib's stem lines).
	first_head = length(data) - 2n + 1
	_scat_apply_style!(fig, first_head:(first_head + n - 1); explicit = (:linewidth, :dash, :mode))
	_scat_apply_style!(fig, (first_head + n):length(data); explicit = _SCAT_STYLE_WIDTH_ONLY)
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
	_scat_place_legend!(fig, legend_state)
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
  `"none"` gives hollow heads). Unset, the heads take the active
  [`PlotStyle`](@ref)'s marker size and marker cycle.
- `linewidth = 0`: stem line width in px (`0`: the active style's line width,
  else 0.5 px). Stems are always solid.

Shared:

- `baseline = 0`: the y value the stems start from.
- `title`, `xlabel`, `ylabel`, `xscale`, `yscale`, `xrange`, `yrange`,
  `xticks`, `xticklabels`, `yticks`, `yticklabels`, `xtickformat`,
  `ytickformat`, `equalar`, `grid`, `width`, `height`, `fontsize`, `show`: as
  for [`plot_scatter`](@ref) (ranges in data units with the semantics of
  `xrange!`, tick presets `:decades`/`:auto`, `grid = true` keeps the
  template grid; a new legend avoids the data).

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
- `AbstractVector` data: vectors, ranges, views. Complex values, matrices and
  other arrays that are not vectors are an `ArgumentError` (pass
  `collect(eachcol(A))` for one series per column).

- Logarithmic value axis (`yscale = "log"`, or `xscale = "log"` for
  horizontal bars): bars keep plotly's base 0, which lies below every log
  axis, so each bar grows from the bottom (left) edge of the axis, its lower
  range limit, as in matplotlib. The bar heights therefore read against the
  axis limit: fix it with `yrange`/`xrange` (data units) for figures that
  compare bars, or pass `base` to start the bars at a given value. Tick
  keywords (`yticks`, `yticklabels`, `:decades`) apply as on any log axis.

#### Keyword Arguments
- `color::Union{AbstractString,Symbol,AbstractVector} = ""`: bar colour (`""`
  uses the colour cycle). Several series: a vector with one colour per series,
  where an entry may itself be a vector with one colour per bar of that
  series. A single series: a vector with one colour per bar colours each bar
  (as matplotlib's `bar(color = [...])`), a one-element vector is the series
  colour, and any other length is an `ArgumentError`. The legend shows the
  first bar's colour for a per-bar series.
- `barwidth = nothing`: bar width in data units of the position axis (1 =
  the spacing of categories), as matplotlib's `width`: a number for every
  bar, or vectors following the `color` rule (one per series, or one per bar).
  A width does not move the bar centre; under the default grouped `barmode`
  the series still take their own slots. `nothing`: plotly's automatic width.
- `bargap = nothing`, `bargroupgap = nothing`: figure-wide plotly gaps in
  [0, 1], the fraction of the position spacing between neighbouring bar
  groups and between the bars of one group (`nothing` leaves them unchanged:
  plotly's defaults 0.2 and 0). On a `SubplotFigure` they apply to every
  cell (plotly has one value per figure).
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
- `hatch::Union{AbstractString,AbstractVector} = ""`: matplotlib hatch
  (`"/"`, `"\\\\"`, `"x"`, `"-"`, `"|"`, `"+"`, `"."`, repeated for density,
  e.g. `"//"`); vectors follow the `color` rule (one per series, or one per
  bar, where `""` leaves a bar plain).
- `xlabel`, `ylabel`, `title::AbstractString = ""`: axis titles and figure
  title (mathtext labels allowed).
- $(_SCAT_RANGE_DOC)
- `xscale`, `yscale::AbstractString = ""`: axis type, e.g. `"log"` (log axes
  get power-of-ten tick labels).
- $(_SCAT_TICKS_DOC)
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
# One highlighted bar, narrower bars:
plot_bar(["a", "b", "c"], [3, 5, 2]; color = ["grey", "steelblue", "grey"], barwidth = 0.5)
```
"""
function plot_bar(
	x::AbstractArray,
	y::AbstractArray;
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
	hatch::Union{AbstractString, AbstractVector} = "",
	barwidth = nothing,
	bargap = nothing,
	bargroupgap = nothing,
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
			textposition, texttemplate, base, opacity, hatch, barwidth, bargap,
			bargroupgap);
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

function plot_bar(
	y::AbstractArray;
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
	hatch::Union{AbstractString, AbstractVector} = "",
	barwidth = nothing,
	bargap = nothing,
	bargroupgap = nothing,
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
			textposition, texttemplate, base, opacity, hatch, barwidth, bargap,
			bargroupgap);
		mutator = false,
	)
	return _stats_maybe_show(fig, show, width, height, title)
end

"""
	plot_histogram(x; kwargs...)

Histogram of the samples `x`. Returns a `PlotlyBase.Plot`, or a
[`SyncPlot`](@ref) window when `show = true`.

#### Data
- `x::AbstractVector`: the samples (vector, range or view; complex values and
  matrices are an `ArgumentError`). With `orientation = "h"` the samples are binned along
  the y axis and the bars grow along x.
- Multiple series: a vector of vectors (also `Vector{Any}`). The series of one
  call share their bins (`bingroup`). They are overlaid, each trace with
  opacity 0.6 (unless `opacity` is given): on a figure without other bars or
  histograms the layout `barmode` becomes `"overlay"`; on a figure whose
  existing bars use plotly's default (unset) bar mode, and in a
  `SubplotFigure` cell, the figure-wide mode is left alone and only the
  series of this call share one `offsetgroup` (drawn at the same positions).
  Under a bar mode `"overlay"` that is passed or already set, neither is
  needed. With `barmode = "stack"`/`"group"`/`"relative"` (passed or already
  set on the figure) the series are stacked or grouped on the shared bins
  instead.
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
	x::AbstractArray;
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
- Vectors, ranges and views are accepted; matrices and complex values are an
  `ArgumentError` (pass `collect(eachcol(A))` for one series per column), and
  each series needs one group per sample.
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
	x::AbstractArray,
	y::AbstractArray;
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
	y::AbstractArray;
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
	x::AbstractArray,
	y::AbstractArray;
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
	y::AbstractArray;
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

const _POLAR_DIRECTIONS = ("counterclockwise", "clockwise")
const _POLAR_THETAUNITS = ("degrees", "radians")
# Default angle (degrees, plotly's `polar.radialaxis.angle`: 0 points right,
# counterclockwise) of the radial axis that carries the radial tick labels.
# plotly.js draws it along 0°, where its labels collide with the angular "0°"
# label and with data on that spoke (lead review V4); 22.5° is matplotlib's
# default `rlabel_position`, half way between the 0° and 45° spokes of the
# default angular grid.
const _SCAT_POLAR_RLABEL_ANGLE = 22.5
# Most radial ticks plotly.js may draw on a radial axis without tick settings.
# Left to itself plotly.js 2.35 puts ten ticks 0.1 apart on r in [0, 0.9] of a
# 700 x 500 figure, and their labels, drawn along the angled radial axis, run
# into each other; at most 6 ticks (matplotlib draws about 5 radial rings)
# keeps them apart (renders compared in the V4 review).
const _SCAT_POLAR_RADIAL_NTICKS = 6

# Whether angle `a` (degrees) lies in the polar sector `[s1, s2]` (degrees,
# counterclockwise from s1 to s2, as plotly draws a sector).
function _scat_angle_in_sector(a::Real, sector)
	start, stop = Float64(sector[1]), Float64(sector[2])
	span = stop - start
	abs(span) >= 360 && return true
	lo, hi = min(start, stop), max(start, stop)
	return mod(Float64(a) - lo, 360) <= hi - lo
end

# The radial range `checked` (data units) as plotly stores it on the radial
# axis of the polar subplot `polar` (a layout mapping or `nothing`): log10
# exponents when that axis is logarithmic.
function _scat_polar_range_value(polar, checked, who::AbstractString)
	radial = _cmn_mapping_get(polar, :radialaxis)
	_cmn_mapping_get(radial, :type) == "log" || return checked
	all(bound -> bound isa Real && bound > 0, checked) || throw(ArgumentError(
		"$(who): `rrange` bounds on a logarithmic radial axis are data values and " *
		"must be positive; got $(repr(Tuple(checked))).",
	))
	return Float64[log10(bound) for bound in checked]
end

# Shared body of plot_scatterpolar / plot_scatterpolar!: validate everything,
# append one `scatterpolar` trace per series and set the options of the
# primary polar subplot (`layout.polar`). `mode = nothing` is "lines", left to
# the active style's marker cycle.
function _scatterpolar_impl!(
	fig,
	theta,
	r;
	who::AbstractString,
	constructor::Bool,
	trange = [0, 0],
	rrange = [0, 0],
	rlabel_angle::Union{Nothing, Real} = nothing,
	width::Real = 0,
	height::Real = 0,
	mode = nothing,
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
		who;
		mode = something(mode, "lines"),
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
	sector = _scat_checked_range(trange, who, "trange")
	radial = _scat_checked_range(rrange, who, "rrange")
	for (bounds, name) in ((sector, "trange"), (radial, "rrange"))
		bounds === nothing || all(bound -> bound isa Real, bounds) || throw(ArgumentError(
			"$(who): `$(name)` bounds must be numbers; got $(repr(Tuple(bounds))).",
		))
	end
	polar_layout = _scat_polar_layout(fig)
	radial === nothing || (radial = _scat_polar_range_value(polar_layout, radial, who))
	(rlabel_angle === nothing || (!(rlabel_angle isa Bool) && isfinite(rlabel_angle))) ||
		throw(ArgumentError(
			"$(who): `rlabel_angle` must be a finite angle in degrees or nothing; got " *
			"$(repr(rlabel_angle)).",
		))
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
	_stats_label(title)
	# Angle of the radial axis (where the radial tick labels are drawn): the
	# caller's `rlabel_angle`; else, on a polar subplot that has no angle yet,
	# `_SCAT_POLAR_RLABEL_ANGLE` (full circle) or the start of a sector set by
	# this call; an existing angle outside a new sector moves to its start.
	existing_angle = _cmn_mapping_get(_cmn_mapping_get(polar_layout, :radialaxis), :angle)
	existing_sector = _cmn_mapping_get(polar_layout, :sector)
	axis_angle = if rlabel_angle !== nothing
		rlabel_angle
	elseif sector !== nothing && abs(sector[2] - sector[1]) >= 360
		# A full-circle sector: off the start spoke, as without a sector.
		existing_angle isa Real ? nothing : sector[1] + _SCAT_POLAR_RLABEL_ANGLE
	elseif sector !== nothing
		existing_angle isa Real && _scat_angle_in_sector(existing_angle, sector) ?
			nothing : sector[1]
	elseif existing_angle === nothing && existing_sector === nothing
		_SCAT_POLAR_RLABEL_ANGLE
	else
		nothing
	end
	# A radial axis without tick settings gets at most
	# `_SCAT_POLAR_RADIAL_NTICKS` ticks; ticks set earlier are kept.
	radial_axis = _cmn_mapping_get(polar_layout, :radialaxis)
	default_nticks = all(
		key -> _cmn_mapping_get(radial_axis, key) === nothing,
		(:nticks, :dtick, :tickvals, :tickmode),
	)

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
	_scat_apply_style!(fig, (length(data) - n + 1):length(data); explicit = _scat_mode_explicit(mode))
	_apply_figure_title!(fig, title)
	radial === nothing || relayout!(fig; polar_radialaxis_range = radial)
	sector === nothing || relayout!(fig; polar_sector = sector)
	axis_angle === nothing || relayout!(fig; polar_radialaxis_angle = axis_angle)
	default_nticks && relayout!(fig; polar_radialaxis_nticks = _SCAT_POLAR_RADIAL_NTICKS)
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
`mode = nothing`, `dash = ""`, `color = ""`, `legend = ""`, `linewidth = 0`,
`marker_size = 0`, `marker_symbol = ""`, `marker_color = ""`,
`marker_line_color = ""`, `marker_line_width = 0`, `opacity = 1`,
`showlegend = nothing`, as for [`plot_scatter`](@ref) (`mode = nothing` draws
lines, plus markers under a style with a marker cycle; unset keywords take the
active [`PlotStyle`](@ref)'s per-trace defaults), and

- `line_shape = ""`: `"linear"` or `"spline"`.
- `fill = ""`: `"toself"` (fill the closed curve), `"tonext"` or `"none"`;
  `fillcolor = ""` sets its colour.

Shared:

- `markevery = nothing`: markers only at some points, as for `plot_scatter`.
- `thetaunit = ""`: `"degrees"` or `"radians"`, the unit of `theta`; also
  sets the angular tick label unit. `""` keeps the subplot's unit (plotly:
  degrees).
- `direction = ""`: `"counterclockwise"` or `"clockwise"` angle direction;
  `rotation = nothing`: angle (degrees) at which `theta = 0` is drawn
  (`90` puts 0 at the top).
- `trange = [0, 0]`: the drawn angular sector `(start, stop)`, always in
  degrees of the drawing (plotly `polar.sector`: 0 points right, angles grow
  counterclockwise, whatever `thetaunit`, `direction` and `rotation` say);
  `[0, 0]`, `nothing` or `[nothing, nothing]`: the full circle.
- `rrange = [0, 0]`: radial axis range `(lo, hi)` in data units (positive on
  a logarithmic radial axis); `[0, 0]`, `nothing` or `[nothing, nothing]`:
  automatic. Both ranges take two different, non-`Bool` numbers; a polar
  sector or radial range always gives both bounds (a one-sided limit such as
  `(nothing, 2)` is an `ArgumentError`).
- `rlabel_angle = nothing`: angle (degrees of the drawing, as `trange`) of
  the radial axis that carries the radial tick labels (plotly
  `polar.radialaxis.angle`). `nothing`: 22.5° on a new full-circle subplot
  (off the 0° spoke, whose angular label and data the labels would hit,
  matplotlib's default), the start of the sector when `trange` sets one, and
  otherwise the subplot's current angle. A radial axis without tick settings
  also gets at most 6 ticks (`polar.radialaxis.nticks`), so that its labels
  along the angled axis do not run into each other; ticks set with
  [`update_polars!`](@ref) (`nticks`, `dtick`, `tickvals`, `tickmode`) are
  kept.
- `grid = true`: `false` hides the radial and angular grid lines.
- `title = ""`, `width = 0`, `height = 0`, `fontsize = 0`, `show = false`: as
  for `plot_scatter`.

The Cartesian keywords of `plot_scatter` (`xlabel`, `ylabel`, `xrange`,
`yrange`, `xscale`, `yscale`, ticks, `equalar`) do not apply to a polar plot:
use `trange`/`rrange`, or [`update_polars!`](@ref) for the polar axes.

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
	mode::Union{Nothing, AbstractString, AbstractVector} = nothing,
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
	rlabel_angle::Union{Nothing, Real} = nothing,
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
		rlabel_angle = rlabel_angle,
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

# ── 2-D field helpers (plot_heatmap / plot_contour / plot_quiver / plot_image,
# and plot_matrix / plot_streamlines in src/sci/fields.jl) ───────────────────
#
# Matrix convention of every 2-D field function: `U[ix, iy]` is the value at
# (x[ix], y[iy]), so `size(U) == (length(x), length(y))`. The matrix is handed
# to plotly lazily as `transpose(U)`; PlotlyBase then sets `transpose = true`,
# so no copy is made. Per-cell `text` and the raw values in `customdata` are
# NOT transposed by plotly.js, so they are passed in the `U[ix, iy]` layout
# itself (PlotlyBase serialises a Julia matrix column by column, which is the
# `[iy][ix]` order plotly reads them in).

# Whether the primary `letter` axis is logarithmic once a call that passes
# `scale` ("" keeps the current type) has been applied. `fig === nothing`
# stands for a figure that does not exist yet.
function _field2d_log_axis(fig, letter::Symbol, scale::AbstractString)
	isempty(scale) || return scale == "log"
	fig === nothing && return false
	return _axis_type(_plot_layout(fig), _axis_layout_key(letter)) == "log"
end

# Implicit coordinates of a matrix dimension of length `n`: the 0-based
# indices, or 1-based on a logarithmic axis, where 0 cannot be drawn.
_field2d_implicit_axis(n::Integer, log_axis::Bool) =
	log_axis ? (1:n) : (0:(n - 1))

_field2d_bad_coordinate(value) =
	value isa Bool || value === missing || value === nothing ||
	(value isa Number && !(value isa Real)) || value isa AbstractArray

# Validate a coordinate vector: finite reals (positive on a log axis), or
# strings/dates for category/date axes. The vector itself is not copied.
function _field2d_check_coordinates(
	v,
	who::AbstractString,
	name::AbstractString;
	log_axis::Bool = false,
)
	if ndims(v) != 1
		hint = ndims(v) == 2 ?
			" For grid matrices `Y, X = meshgrid(y, x)` pass the coordinate " *
			"vectors `x = X[:, 1]` and `y = Y[1, :]`." :
			""
		throw(ArgumentError(
			"$(who): `$(name)` must be a vector of coordinates; got a " *
			"$(ndims(v))-D array of size $(size(v)).$(hint)",
		))
	end
	numeric = eltype(v) <: Real && !(eltype(v) <: Bool)
	for (i, value) in enumerate(v)
		if numeric || (value isa Real && !(value isa Bool))
			isfinite(value) || throw(ArgumentError(
				"$(who): `$(name)` coordinates must be finite; entry $(i) is $(value).",
			))
			log_axis && value <= 0 && throw(ArgumentError(
				"$(who): `$(name)` is on a logarithmic axis, so its coordinates " *
				"must be positive; entry $(i) is $(value).",
			))
		elseif _field2d_bad_coordinate(value)
			throw(ArgumentError(
				"$(who): `$(name)` coordinates must be finite real numbers, " *
				"strings (categories) or dates; entry $(i) is $(repr(value)).",
			))
		elseif log_axis
			throw(ArgumentError(
				"$(who): `$(name)` is on a logarithmic axis, so its coordinates " *
				"must be positive numbers; entry $(i) is $(repr(value)).",
			))
		end
	end
	return nothing
end

_field2d_complex_error(who::AbstractString, name::AbstractString) =
	ArgumentError(
		"$(who): `$(name)` is complex-valued; plot a real quantity such as " *
		"abs.($(name)) (magnitude), real.($(name)), imag.($(name)) or " *
		"angle.($(name)) (phase).",
	)

# The matrix that is plotted for `U`: real matrices are returned unchanged (no
# copy); Bool entries become 0/1 (plotly cannot colour JSON true/false);
# complex or non-numeric entries are an error. NaN and `missing` mark gaps.
function _field2d_matrix(U, who::AbstractString, name::AbstractString = "U")
	ndims(U) == 2 || throw(ArgumentError(
		"$(who): `$(name)` must be a matrix indexed $(name)[ix, iy]; got a " *
		"$(ndims(U))-D array of size $(size(U)).",
	))
	T = eltype(U)
	T <: Bool && return UInt8.(U)
	T <: Complex && throw(_field2d_complex_error(who, name))
	T <: Real && isconcretetype(T) && return U
	has_bool = false
	for value in U
		if value isa Bool
			has_bool = true
		elseif !(value === missing || value isa Real)
			value isa Complex && throw(_field2d_complex_error(who, name))
			throw(ArgumentError(
				"$(who): `$(name)` entries must be real numbers (NaN or missing " *
				"mark gaps); got $(repr(value)).",
			))
		end
	end
	has_bool || return U
	return map(value -> value isa Bool ? UInt8(value) : value, U)
end

# `U[ix, iy]` must match the coordinate lengths; heatmaps also accept cell
# edges (one more coordinate than cells).
function _field2d_check_shape(
	x,
	y,
	U,
	who::AbstractString;
	allow_edges::Bool,
)
	nx, ny = size(U)
	lx, ly = length(x), length(y)
	fits(l, n) = l == n || (allow_edges && n > 0 && l == n + 1)
	fits(lx, nx) && fits(ly, ny) && return nothing
	edges = allow_edges ?
		" (or one less in each dimension when x and y list the cell edges)" :
		""
	hint = fits(lx, ny) && fits(ly, nx) ?
		" The matrix looks transposed: if it is indexed U[iy, ix] (rows " *
		"follow y, e.g. built from `meshgrid(x, y)`), pass permutedims(U)." :
		""
	throw(ArgumentError(
		"$(who): the matrix is indexed U[ix, iy], so size(U) must be " *
		"(length(x), length(y)) = ($(lx), $(ly))$(edges); got size(U) = " *
		"$(size(U)).$(hint)",
	))
end

function _field2d_labels(labels, who::AbstractString, name::AbstractString)
	(labels isa AbstractVector || labels isa Tuple) || throw(ArgumentError(
		"$(who): `$(name)` must be a vector of labels; got $(typeof(labels)).",
	))
	return String[
		_label(label isa AbstractString ? label : string(label))
		for label in labels
	]
end

# A colour keyword (`linecolor`, `color`): "" / nothing is unset; strings and
# Symbols are validated and passed through, Colorants become hex strings.
function _field2d_color_string(color, who::AbstractString, name::AbstractString)
	color === nothing && return ""
	if color isa AbstractString || color isa Symbol
		text = strip(String(color))
		isempty(text) && return ""
		_parse_color(text, who)
		return String(text)
	elseif color isa Colors.Colorant
		return _color_hex(color; who = who)
	end
	throw(ArgumentError(
		"$(who): `$(name)` must be a colour name, hex string, Symbol or " *
		"Colors.jl Colorant; got $(repr(color)).",
	))
end

function _field2d_nonnegative(value, who::AbstractString, name::AbstractString)
	(value isa Real && !(value isa Bool) && isfinite(value) && value >= 0) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a finite number ≥ 0 (0 = unset); got " *
			"$(repr(value)).",
		))
	return value
end

# Colour keywords of plot_heatmap(!) / plot_contour(!) (spec C21) resolved
# through `_apply_color_norm`. Returns the matrix to plot (log10 values for
# colornorm = :log), the raw values for the hover text (`nothing` when the
# norm is linear), the colour fields and the normalised coloraxis id. Without
# a coloraxis the fields are trace fields (`colorscale`, `zmin`, `zmax`,
# `zmid`, `showscale`, `colorbar`); with one they are the `layout.<coloraxis>`
# fields (`cmin`/`cmax`/`cmid`) and the trace only references the axis.
function _field2d_color(
	Z,
	who::AbstractString;
	zrange,
	crange,
	cmid,
	colornorm,
	levels,
	colorscale,
	showscale::Union{Nothing, Bool},
	colorbar_title::AbstractString,
	colorbar_title_side::Symbol = :top,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
)
	zlimits = _checked_range(zrange, who, "zrange")
	if zlimits !== nothing
		_checked_range(crange, who, "crange") === nothing || throw(ArgumentError(
			"$(who): `zrange` is an alias of `crange`; pass only one of them.",
		))
		(all(b -> b isa Real && !(b isa Bool), zlimits) && zlimits[1] < zlimits[2]) ||
			throw(ArgumentError(
				"$(who): `zrange` must be numeric colour limits (lower, upper) " *
				"with lower < upper; got $(repr(zrange)).",
			))
	end
	ticklabels = colorbar_ticklabels === nothing ? nothing :
		_field2d_labels(colorbar_ticklabels, who, "colorbar_ticklabels")
	norm = _apply_color_norm(
		Z;
		crange = zlimits === nothing ? crange : zrange,
		cmid = cmid,
		colornorm = colornorm,
		levels = levels,
		stops = colorscale,
		ticks = colorbar_ticks,
		ticklabels = ticklabels,
		who = who,
	)
	colorbar = _field2d_colorbar(
		colorbar_title,
		colorbar_title_side,
		who;
		ticks = norm.tickvals,
		ticklabels = norm.ticktext,
	)
	axis_id = coloraxis === nothing ? nothing :
		_normalize_coloraxis(coloraxis, who)
	prefix = axis_id === nothing ? "z" : "c"
	fields = Dict{Symbol, Any}()
	stops = norm.stops
	(stops isa AbstractString && isempty(stops)) || (fields[:colorscale] = stops)
	norm.cmin === nothing || (fields[Symbol(prefix, "min")] = norm.cmin)
	norm.cmax === nothing || (fields[Symbol(prefix, "max")] = norm.cmax)
	norm.cmid === nothing || (fields[Symbol(prefix, "mid")] = norm.cmid)
	showscale === nothing || (fields[:showscale] = showscale)
	colorbar === nothing || (fields[:colorbar] = colorbar)
	return (
		values = norm.values,
		customdata = norm.customdata,
		fields = fields,
		coloraxis = axis_id,
	)
end

# Hover text of a log-normalised field: plotly holds log10 values, so the raw
# values travel in `customdata`.
const _FIELD2D_LOG_HOVERTEMPLATE =
	"x: %{x}<br>y: %{y}<br>z: %{customdata:.3g}<extra></extra>"

function _field2d_color_trace_fields!(fields::AbstractDict, color)
	if color.coloraxis === nothing
		merge!(fields, color.fields)
	else
		fields[:coloraxis] = color.coloraxis
	end
	if color.customdata !== nothing
		fields[:customdata] = color.customdata
		fields[:hovertemplate] = _FIELD2D_LOG_HOVERTEMPLATE
	end
	return fields
end

# Write the colour fields of a shared coloraxis into `layout.<coloraxis>`.
function _field2d_apply_coloraxis!(fig, color)
	color.coloraxis === nothing && return nothing
	_cmn_merge_layout_key!(
		fig,
		Symbol(color.coloraxis),
		color.fields;
		nested = (:colorbar,),
	)
	return nothing
end

function _field2d_origin(origin, who::AbstractString; allow_unset::Bool)
	(origin isa Symbol || origin isa AbstractString) || throw(ArgumentError(
		"$(who): `origin` must be :lower or :upper; got $(repr(origin)).",
	))
	value = lowercase(strip(String(origin)))
	allow_unset && isempty(value) && return ""
	value in ("lower", "upper") || throw(ArgumentError(
		"$(who): `origin` must be :lower or :upper" *
		(allow_unset ? " (or \"\" to keep the y-axis direction)" : "") *
		"; got $(repr(origin)).",
	))
	return value
end

# Make the primary `letter` axis decrease (`reversed = true`) or increase
# along the screen direction. An explicit range is reordered; otherwise the
# autorange direction is written. An increasing direction is only written
# when the axis is currently reversed, unless `force` (plotly reverses the y
# axis of image traces by default).
function _field2d_axis_direction!(fig, letter::Symbol, reversed::Bool; force::Bool = false)
	key = _axis_layout_key(letter)
	axis = get(_plot_layout(fig).fields, key, nothing)
	current = _cmn_mapping_get(axis, :range)
	autorange = _cmn_mapping_get(axis, :autorange)
	if autorange isa AbstractString && autorange in ("min", "max", "min reversed", "max reversed")
		# A plotly partial autorange (set by the user or another family; the
		# field families write one-sided limits as autorange options, see
		# `_field2d_apply_partial_range!`): keep the fixed bound, move it to
		# the slot of the new direction.
		endswith(autorange, "reversed") == reversed && return nothing
		(current isa AbstractVector && length(current) == 2) || return nothing
		fixed = current[1] === nothing ? current[2] : current[1]
		base = startswith(autorange, "min") ? "min" : "max"
		first_slot = (base == "max") != reversed
		_cmn_merge_layout_key!(
			fig,
			key,
			Dict{Symbol, Any}(
				:range => first_slot ? Any[fixed, nothing] : Any[nothing, fixed],
				:autorange => reversed ? base * " reversed" : base,
			),
		)
		return nothing
	end
	if (autorange === nothing || autorange === false) &&
			current isa AbstractVector && length(current) == 2
		first_bound, last_bound = current[1], current[2]
		comparable =
			(first_bound isa Real && last_bound isa Real) ||
			(first_bound isa AbstractString && last_bound isa AbstractString)
		if comparable && (reversed ? first_bound < last_bound : first_bound > last_bound)
			relayout!(fig; Symbol(key, :_range) => Any[last_bound, first_bound])
		end
		return nothing
	end
	if reversed
		relayout!(fig; Symbol(key, :_autorange) => "reversed")
	elseif force || autorange == "reversed"
		relayout!(fig; Symbol(key, :_autorange) => true)
	end
	return nothing
end

# `origin = "upper"` points the y axis down (first row / y value at the top),
# "lower" up; "" leaves the axis alone.
_field2d_apply_origin!(fig, origin::AbstractString) =
	isempty(origin) ? nothing :
	_field2d_axis_direction!(fig, :y, origin == "upper")

# A `Date`/`DateTime` coordinate as the ISO string plotly.js reads on a date
# axis (Y25): "2020-01-02", "2020-01-02T03:04:05.678". Anything else is
# returned unchanged. (`Dates` is imported in src/sci/reference.jl; this body
# resolves it at call time.)
_field2d_date_value(v) =
	(v isa Dates.Date || v isa Dates.DateTime) ? string(v) : v

# Tick values with dates converted by `_field2d_date_value` (the shared tick
# helpers take numbers, or strings on date/category axes); tick presets and
# `nothing` pass unchanged.
function _field2d_tick_values(values)
	(values isa AbstractVector || values isa Tuple) || return values
	any(v -> v isa Dates.Date || v isa Dates.DateTime, values) || return values
	return Any[_field2d_date_value(v) for v in values]
end

# Check the tick keywords before the first write, against the axis types the
# call ends up with (`_validate_tick_option`; D9 presets pass).
function _field2d_validate_ticks(
	fig,
	who::AbstractString;
	xticks = nothing,
	xticklabels = nothing,
	xtickformat = "",
	yticks = nothing,
	yticklabels = nothing,
	ytickformat = "",
	xscale::AbstractString = "",
	yscale::AbstractString = "",
)
	for (name, value) in (("xtickformat", xtickformat), ("ytickformat", ytickformat))
		value isa AbstractString || throw(ArgumentError(
			"$(who): `$(name)` must be a d3 format string such as \".2f\"; got $(repr(value)).",
		))
	end
	_validate_tick_option(fig, :xaxis, _field2d_tick_values(xticks), xticklabels, xscale, who, "x")
	_validate_tick_option(fig, :yaxis, _field2d_tick_values(yticks), yticklabels, yscale, who, "y")
	return nothing
end

function _field2d_apply_ticks!(
	fig,
	who::AbstractString;
	xticks,
	xticklabels,
	xtickformat::AbstractString,
	yticks,
	yticklabels,
	ytickformat::AbstractString,
)
	if xticks !== nothing || xticklabels !== nothing || !isempty(xtickformat)
		_apply_ticks!(
			fig,
			:xaxis;
			values = _field2d_tick_values(xticks),
			labels = xticklabels,
			format = xtickformat,
			who = who,
		)
	end
	if yticks !== nothing || yticklabels !== nothing || !isempty(ytickformat)
		_apply_ticks!(
			fig,
			:yaxis;
			values = _field2d_tick_values(yticks),
			labels = yticklabels,
			format = ytickformat,
			who = who,
		)
	end
	return nothing
end

# Common Cartesian options of the 2-D field functions, applied through the
# figure-option primitives (primary axes only). Constructors (`constructor =
# true`) keep the template grid for `grid = true` and apply the default
# template; mutators apply any explicit `grid` and only refresh the legend so
# a user template survives. Call `_field2d_validate_cartesian` first.
# `xrange`/`yrange` come from `_field2d_checked_range`; a one-sided limit
# (D11) is written after the axis direction (`origin`) is known, unless
# `partial_ranges = false` (the caller sets the direction afterwards and
# applies it itself with `_field2d_apply_partial_range!`).
function _field2d_apply_options!(
	fig,
	who::AbstractString;
	constructor::Bool,
	title::AbstractString,
	xlabel::AbstractString,
	ylabel::AbstractString,
	xscale::AbstractString,
	yscale::AbstractString,
	xrange,
	yrange,
	xticks,
	xticklabels,
	xtickformat::AbstractString,
	yticks,
	yticklabels,
	ytickformat::AbstractString,
	origin::AbstractString,
	equalar::Bool,
	width,
	height,
	fontsize,
	grid,
	partial_ranges::Bool = true,
)
	_apply_figure_title!(fig, title)
	_apply_axis_title!(fig, :x, xlabel)
	_apply_axis_title!(fig, :y, ylabel)
	# Scale before range and ticks: a log axis stores exponents.
	_apply_axis_scale!(fig, :x, xscale, who)
	_apply_axis_scale!(fig, :y, yscale, who)
	_apply_axis_range!(fig, :x, _field2d_two_sided(xrange), who)
	_apply_axis_range!(fig, :y, _field2d_two_sided(yrange), who)
	_field2d_apply_ticks!(
		fig,
		who;
		xticks = xticks,
		xticklabels = xticklabels,
		xtickformat = xtickformat,
		yticks = yticks,
		yticklabels = yticklabels,
		ytickformat = ytickformat,
	)
	_field2d_apply_origin!(fig, origin)
	# The equal aspect first: a one-sided limit is written differently on an
	# aspect-constrained axis (`_field2d_apply_partial_range!`).
	equalar && _apply_equal_aspect!(fig, _cell_target(fig; who = who); who = who)
	if partial_ranges
		_field2d_apply_partial_range!(fig, :xaxis, xrange; who = who)
		_field2d_apply_partial_range!(fig, :yaxis, yrange; who = who)
	end
	_apply_figure_size!(fig, who; width = width, height = height)
	(constructor && grid === true) || _apply_axis_grid!(fig, grid, who)
	constructor ? _apply_default_template!(fig) : _apply_default_legend!(fig)
	_apply_figure_fontsize!(fig, who, fontsize)
	return nothing
end

# A fresh Cartesian figure for a 2-D field constructor.
_field2d_new_figure() = Plot(GenericTrace[], _default_cartesian_layout())

_field2d_show(fig, show::Bool, width, height, title::AbstractString) =
	show ? to_syncplot(
		fig;
		width = width > 0 ? width : 960,
		height = height > 0 ? height : 720,
		title = isempty(title) ? "PlotlySupply" : title,
	) : fig

# Mutators do not open windows: a `show` keyword (or any other unknown
# keyword) is an ArgumentError naming the function.
function _field2d_reject_keywords(who::AbstractString, extra)
	isempty(extra) && return nothing
	names = collect(keys(extra))
	:show in names && throw(ArgumentError(
		"$(who): mutators do not take `show`; the traces are added to the " *
		"figure you pass (display it, or call `to_syncplot(fig)` for a window).",
	))
	throw(ArgumentError(
		"$(who): unsupported keyword argument(s) " *
		"$(join(("`$(name)`" for name in names), ", ")).",
	))
end

# An axis-range keyword (`xrange`, `yrange`) of the 2-D field and mesh
# families, with the semantics of the range mutators (`xrange!`, X23, D11):
# - `[0, 0]`, `(0, 0)`, `nothing` and `[nothing, nothing]` are the automatic
#   sentinel: `nothing` is returned and the axis is left as it is;
# - a one-sided limit `(lo, nothing)` / `(nothing, hi)` (matplotlib
#   `set_xlim(left = lo)`) is returned as `Any[lo, nothing]` /
#   `Any[nothing, hi]`: that bound is fixed and the other side autoranges
#   (`_field2d_apply_partial_range!`);
# - otherwise exactly two finite, different bounds, returned as `Any[lo, hi]`.
# `missing` and Bool bounds throw. Bounds are DATA values (converted on a log
# axis when applied); strings and dates pass for category/date axes, except
# that a one-sided bound is a number or a Date/DateTime.
function _field2d_checked_range(range, who::AbstractString, name::AbstractString)
	if (range isa AbstractVector || range isa Tuple) && length(range) == 2
		any(bound -> bound isa Bool, range) && throw(ArgumentError(
			"$(who): `$(name)` bounds must be numbers (or date/category values); " *
			"got $(repr(range)).",
		))
		any(bound -> bound === missing, range) && throw(ArgumentError(
			"$(who): `$(name)` bounds must be numbers (or date/category values); " *
			"`missing` is not a bound (use `nothing` for an open side, e.g. " *
			"(0, nothing) fixes only the lower limit). Got $(repr(range)).",
		))
		lower, upper = range[1], range[2]
		lower === nothing && upper === nothing && return nothing
		if lower === nothing || upper === nothing
			bound = something(lower, upper)
			(bound isa Real && !isfinite(bound)) && throw(ArgumentError(
				"$(who): `$(name)` bounds must be finite; got $(repr(range)).",
			))
			# plotly.js's autorange options (`_field2d_apply_partial_range!`)
			# take numbers (a category's 0-based position on a category axis)
			# and dates; it ignores category names and date strings there.
			bound isa Union{Real, Dates.Date, Dates.DateTime} || throw(ArgumentError(
				"$(who): the bound of a one-sided `$(name)` must be a number (the " *
				"0-based position on a category axis) or a Date/DateTime; got " *
				"$(repr(range)).",
			))
			return Any[lower, upper]
		end
	end
	# Two-sided ranges: `_checked_range` rejects equal, non-finite and
	# malformed bounds.
	return _checked_range(range, who, name)
end

# Whether a range returned by `_field2d_checked_range` is a one-sided limit.
_field2d_is_partial(range) =
	range !== nothing && (range[1] === nothing || range[2] === nothing)

# The two-sided part of a checked range: `nothing` for the automatic sentinel
# and for a one-sided limit (applied separately).
_field2d_two_sided(range) = _field2d_is_partial(range) ? nothing : range

# Whether axis layout entry `axis` points down/left: autorange "reversed" (or
# a reversed one-sided autorange), or an explicit descending numeric range.
# `implicit` is the direction plotly.js takes when the axis states none (the y
# axis of an image is reversed by default).
function _field2d_axis_reversed(axis; implicit::Bool = false)
	autorange = _cmn_mapping_get(axis, :autorange)
	if autorange isa AbstractString
		return endswith(autorange, "reversed")
	end
	current = _cmn_mapping_get(axis, :range)
	if (autorange === nothing || autorange === false) &&
			current isa AbstractVector && length(current) == 2 &&
			current[1] isa Real && current[2] isa Real
		return current[1] > current[2]
	end
	return autorange === nothing && current === nothing && implicit
end

# Check the bound of a one-sided limit (D11) against the type axis `key` ends
# up with (`scale` when the call sets one): a number on linear, log and
# category axes, positive on a log axis. Writes nothing.
function _field2d_require_partial_range(
	fig,
	key::Symbol,
	range,
	scale::AbstractString,
	who::AbstractString,
	name::AbstractString,
)
	_field2d_is_partial(range) || return nothing
	axis_type = isempty(scale) ? _axis_type(_cmn_layout(fig), key) : String(scale)
	bound = something(range[1], range[2])
	if axis_type in _NUMERIC_RANGE_AXIS_TYPES
		bound isa Real || throw(ArgumentError(
			"$(who): `$(name)` bounds on a $(axis_type) axis must be numbers; got " *
			"$(repr(Tuple(range))).",
		))
	end
	axis_type == "log" && !(bound > 0) && throw(ArgumentError(
		"$(who): `$(name)` bounds on a logarithmic axis are data values and must " *
		"be positive; got $(repr(Tuple(range))).",
	))
	return nothing
end

# `_validate_cartesian_options` for the field and mesh families, which also
# take one-sided limits (D11): the shared validator sees only the two-sided
# part of a range; a one-sided limit is checked by
# `_field2d_require_partial_range`. With a one-sided limit the axis's old
# range is replaced, so a scale switch in the same call cannot strand it (the
# shared check of a stranded old range is skipped for that axis).
function _field2d_validate_cartesian(
	fig,
	who::AbstractString;
	xrange = nothing,
	yrange = nothing,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width = 0,
	height = 0,
	fontsize = 0,
	grid = nothing,
)
	_require_axis_scale(xscale, who, "xscale")
	_require_axis_scale(yscale, who, "yscale")
	_validate_cartesian_options(
		fig,
		who;
		xrange = _field2d_two_sided(xrange),
		yrange = _field2d_two_sided(yrange),
		xscale = _field2d_is_partial(xrange) ? "" : xscale,
		yscale = _field2d_is_partial(yrange) ? "" : yscale,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
	)
	_field2d_require_partial_range(fig, :xaxis, xrange, xscale, who, "xrange")
	_field2d_require_partial_range(fig, :yaxis, yrange, yscale, who, "yrange")
	return nothing
end

# (width, height) in pixels of an image trace's `z` (the lazy C×W×H array of
# `_image_z`, or nested rows of pixels) or of its PNG `source` (the IHDR
# header of a "data:image/png;base64," URI); `nothing` when unknown.
function _field2d_image_size(fields)
	z = get(fields, :z, nothing)
	if z isa AbstractArray && ndims(z) == 3
		return (size(z, 2), size(z, 3))
	elseif z isa AbstractVector && !isempty(z) && first(z) isa AbstractVector
		return (length(first(z)), length(z))
	end
	source = get(fields, :source, nothing)
	prefix = "data:image/png;base64,"
	(source isa AbstractString && startswith(source, prefix)) || return nothing
	# 24 base64 characters past the prefix cover the 8-byte signature, the
	# IHDR length and tag and the two 4-byte sizes (32 bytes = 44 characters).
	ncodeunits(source) >= ncodeunits(prefix) + 44 || return nothing
	header = try
		Base64.base64decode(source[(ncodeunits(prefix) + 1):(ncodeunits(prefix) + 44)])
	catch
		return nothing
	end
	(length(header) >= 24 && header[1:8] == _PNG_SIGNATURE && header[13:16] == codeunits("IHDR")) ||
		return nothing
	be32(i) = Int(header[i]) << 24 | Int(header[i + 1]) << 16 | Int(header[i + 2]) << 8 | Int(header[i + 3])
	return (be32(17), be32(21))
end

# Extent (lo, hi) in data units along `letter` of the visible traces and
# data-referenced layout items on axes `members`, as `_finalize_figure!`
# computes it (field edges, data; unpadded), with image traces measured here
# (finalize does not size an image's 3-D `z` or a `source`). `nothing` when a
# trace's extent is not computed, the axis type is not linear/log, or there is
# no finite extent.
function _field2d_partial_extent(fig, members::Vector{Symbol}, letter::Char, islog::Bool)
	p = _cmn_plot(fig)
	layout = p.layout
	all(m -> _fin_axis_type(layout, m) in ("-", "linear", "log"), members) || return nothing
	lo, hi = Inf, -Inf
	cache = Dict{Any, Union{Nothing, String}}()
	for trace in p.data
		trace isa GenericTrace || continue
		_cmn_trace_kind(trace, cache) == "xy" || continue
		_fin_visible(trace) || continue
		_fin_axis_key(get(trace.fields, Symbol(letter, :axis), string(letter))) in members || continue
		extent = if _fin_trace_type(trace) == "image"
			size = _field2d_image_size(trace.fields)
			start = get(trace.fields, Symbol(letter, "0"), 0)
			step = get(trace.fields, Symbol("d", letter), 1)
			(islog || size === nothing || !(start isa Real) || !(step isa Real)) ? :unsupported :
				minmax(start - step / 2, start + step * ((letter == 'x' ? size[1] : size[2]) - 0.5))
		else
			_fin_trace_extent(trace, letter, islog)
		end
		extent === :unsupported && return nothing
		extent === nothing && continue
		lo = min(lo, Float64(extent[1]))
		hi = max(hi, Float64(extent[2]))
	end
	for member in members
		extent = _fin_layout_item_extent(layout, _fin_axis_ref(member), letter, islog)
		extent === :unsupported && return nothing
		extent === nothing && continue
		lo = min(lo, Float64(extent[1]))
		hi = max(hi, Float64(extent[2]))
	end
	return isfinite(lo) && isfinite(hi) ? (lo, hi) : nothing
end

# D11: write the one-sided limit `range` (from `_field2d_checked_range`) on
# axis `key` and its `matches` group. The fixed bound is in plotly's range
# units (log10 on a log axis).
#
# plotly.js 2.35.2's partial autorange ("max" with `range = [lo, null]`) is
# drawn on screen but lost by `savefig`: after a draw plotly writes the
# computed range back into the layout (both bounds numeric), and the copy that
# `Plotly.toImage` draws then fails plotly's range/autorange consistency check
# and autoranges both sides (probe: first draw x = [2, 7.47], copy
# [-0.47, 7.47]). So the limit is written as `autorangeoptions.minallowed`
# (lower bound) or `maxallowed` (upper bound) with `autorange = true` (or
# "reversed", keeping the direction): plotly then autoranges the open side
# with the fixed bound as the range end, in the window and in the copy. Every
# member of a `matches` group needs the option (plotly autoranges each member
# and unites the ranges); the root gets the autorange.
#
# An aspect-constrained axis (equal aspect, or an image's y axis) is
# re-ranged by plotly for the constraint, which ignores these options (probe:
# `maxallowed = 2.5` gave x = [-5.7, 7.73]). There the limit is applied as
# matplotlib's `set_xlim(left = lo)` does, which keeps the other limit where
# it is: the root is fixed to the fixed bound and the current extent of the
# group's data on the open side (`_finalize_figure!`'s extent: field edges and
# data, unpadded). Without a finite extent (no data yet, or traces whose
# extent is not computed) the options are written as above.
#
# A sticky clip `_finalize_figure!` wrote earlier (its exact
# `autorangeoptions` signature) is dropped from the group: it would clip the
# open side to the old extent. Other user `autorangeoptions` entries are kept,
# except the opposite `minallowed`/`maxallowed` (an earlier one-sided limit:
# the open side autoranges).
# A two-sided or automatic range is left to the caller.
function _field2d_apply_partial_range!(
	fig,
	key::Symbol,
	range;
	implicit_reversed::Bool = false,
	who::AbstractString,
)
	_field2d_is_partial(range) || return nothing
	layout = _cmn_layout(fig)
	fields = layout.fields
	islog = _axis_type(layout, key) == "log"
	lower, upper = range[1], range[2]
	fixed = something(lower, upper)
	if islog
		(fixed isa Real && fixed > 0) || throw(ArgumentError(
			"$(who): one-sided limits on a logarithmic axis are data values and " *
			"must be positive; got $(repr(Tuple(range))).",
		))
	end
	# plotly's range units: log10 on a log axis; on a date axis the autorange
	# options take epoch milliseconds (a date string there makes plotly.js
	# 2.35.2 fall back to its empty-axis range, probe p14).
	to_range(v) = islog ? log10(Float64(v)) :
		v isa Union{Dates.Date, Dates.DateTime} ?
			Dates.value(Dates.DateTime(v) - Dates.DateTime(1970)) : v
	reversed = _field2d_axis_reversed(get(fields, key, nothing); implicit = implicit_reversed)
	root = something(_fin_match_root(fields, key), key)
	members = Symbol[key]
	root === key || push!(members, root)
	for member in keys(fields)
		_fin_is_axis_key(member) || continue
		member in members && continue
		_fin_match_root(fields, member) === root && push!(members, member)
	end
	pinned = nothing
	if fixed isa Real && any(in(_fin_aspect_axes(layout, _fin_collect_axes(_cmn_plot(fig)))), members)
		extent = _field2d_partial_extent(fig, members, String(key)[1], islog)
		if extent !== nothing
			lo, hi = extent
			a, b = lower === nothing ? (lo, Float64(fixed)) : (Float64(fixed), hi)
			# A fixed bound beyond the data inverts the axis, as in matplotlib;
			# one equal to the far data edge leaves no range to fix.
			a != b && (pinned = reversed ? Any[to_range(b), to_range(a)] : Any[to_range(a), to_range(b)])
		end
	end
	option, other = lower === nothing ? (:maxallowed, :minallowed) : (:minallowed, :maxallowed)
	for member in members
		current = get(fields, member, nothing)
		old = _cmn_mapping_get(current, :autorangeoptions)
		user = _fin_sticky_clip(current) === nothing && _is_layout_mapping(old)
		options = Dict{Symbol, Any}()
		if user
			for (name, value) in (old isa PlotlyBase.PlotlyAttribute ? old.fields : old)
				options[Symbol(name)] = value
			end
		end
		old === nothing || _cmn_delete_layout_fields!(fig, member, (:autorangeoptions,))
		if pinned === nothing
			options[option] = to_range(fixed)
			delete!(options, other)
		end
		isempty(options) ||
			_cmn_merge_layout_key!(fig, member, Dict{Symbol, Any}(:autorangeoptions => attr(; options...)))
	end
	if pinned === nothing
		_cmn_delete_layout_fields!(fig, root, (:range,))
		_cmn_merge_layout_key!(fig, root, Dict{Symbol, Any}(:autorange => reversed ? "reversed" : true))
	else
		_cmn_merge_layout_key!(fig, root, Dict{Symbol, Any}(:range => pinned, :autorange => false))
	end
	return nothing
end

# A Bool keyword given untyped so a wrong value is an ArgumentError naming it.
function _field2d_bool(value, who::AbstractString, name::AbstractString)
	value isa Bool || throw(ArgumentError(
		"$(who): `$(name)` must be true or false; got $(repr(value)).",
	))
	return value
end

# `interpolation` of plot_heatmap / plot_image (G67, matplotlib's imshow
# `interpolation`) as plotly's `zsmooth`: `:nearest` (default) draws every
# cell as a flat brick (`nothing`: zsmooth stays unset, plotly's `false`);
# `:bilinear` interpolates between cell centres. A heatmap uses "best"
# (bilinear per pixel, valid on non-uniform grids); an image trace only has
# "fast" (the browser's bilinear image scaling, which plotly.js applies only to
# a `source` image: see `_image_png_uri`).
function _field2d_zsmooth(interpolation, who::AbstractString; image::Bool)
	value = interpolation isa AbstractString ? Symbol(lowercase(strip(interpolation))) :
		interpolation
	value === :nearest && return nothing
	value === :bilinear && return image ? "fast" : "best"
	throw(ArgumentError(
		"$(who): `interpolation` must be :nearest or :bilinear; got " *
		"$(repr(interpolation)).",
	))
end

# `colorbar_title_side` (X1): :top (default), :right or :bottom, as a Symbol
# or string; `_colorbar_title_attr` rejects any other side.
function _field2d_title_side(side, who::AbstractString)
	(side isa Symbol || side isa AbstractString) || throw(ArgumentError(
		"$(who): `colorbar_title_side` must be :top, :right or :bottom; got " *
		"$(repr(side)).",
	))
	value = Symbol(lowercase(strip(String(side))))
	# Validates the side (and builds nothing for an empty title).
	_colorbar_title_attr("", value; who = who)
	return value
end

# Line width of a field overlay (contour lines, streamlines, mesh edges)
# whose `linewidth` keyword is 0, i.e. automatic (X10): the active style's
# line width (`with_style(linewidth = ...)`), else `default` (`nothing`:
# leave the width to plotly). Overlays take no dash/marker cycle, which would
# turn one field into a dashed or marked series.
function _field2d_style_linewidth(default)
	width = get(_style_trace_defaults(_active_style(), 1), :linewidth, nothing)
	return width === nothing ? default : width
end

# Colorbar of a field trace with the title on `side` (X1): the ticks of
# `_colorbar_attr` plus `title = attr(text, side)`; `nothing` when neither a
# title nor ticks are set.
function _field2d_colorbar(
	title::AbstractString,
	side::Symbol,
	who::AbstractString;
	ticks = nothing,
	ticklabels = nothing,
)
	bar = _colorbar_attr(; ticks = ticks, ticklabels = ticklabels, who = who)
	title_value = _colorbar_title_attr(title, side; who = who)
	title_value === nothing && return bar
	fields = bar === nothing ? Dict{Symbol, Any}() : _symbol_dict(bar)
	fields[:title] = title_value
	return attr(; fields...)
end

# D10 (3): the `tight` flag of a field trace, read by `_finalize_figure!`'s
# sticky-edge logic (src/sci/finalize.jl, owned by field-layout). Per the
# field-layout contract (CONTRACT.md §1-2) a trace that draws the field
# itself carries `meta = "plotlysupply:field"` (tight, the default) or
# `"plotlysupply:field:loose"` (`tight = false`), compared exactly, so nothing
# else may go into `meta`. Overlays (quiver arrows, streamlines, edge and
# carrier traces) carry no field `meta`. Native heatmap/contour/image traces
# count as tight fields without `meta`; only the loose value opts them out.
const _FIELD2D_META_TIGHT = "plotlysupply:field"
const _FIELD2D_META_LOOSE = "plotlysupply:field:loose"

_field2d_field_meta(tight::Bool) = tight ? _FIELD2D_META_TIGHT : _FIELD2D_META_LOOSE

function _field2d_mark_field!(fields::AbstractDict, tight::Bool)
	fields[:meta] = _field2d_field_meta(tight)
	return fields
end

# Inside the SubplotFigure path of a field mutator the traces are first built
# on the delegate's scratch figure; the SubplotFigure method finalizes the
# whole figure after the transplant instead (see `_field2d_subplot!`).
const _FIELD2D_DEFER_FINALIZE = Base.ScopedValues.ScopedValue(false)

# The finishing steps every 2-D field constructor/mutator runs after its
# traces (indices `first_new:end`) and options are in `fig`:
# - X1: math colorbar titles of the new traces (and of `coloraxis`) become
#   annotations (deferred to the delegate inside a SubplotFigure call);
# - X10: the active style's trace defaults for the new line traces. `style`
#   lists which of `_STYLE_TRACE_DEFAULT_KEYWORDS` the style may fill: a field
#   overlay takes the style's line width but not the dash/marker cycle, which
#   would turn every quiver or streamline into a dashed or marked series;
# - D10: `_finalize_figure!`.
function _field2d_finish!(
	fig,
	first_new::Int;
	coloraxis = nothing,
	style::Tuple{Vararg{Symbol}} = (),
)
	last_index = length(_plot_data(fig))
	if first_new <= last_index
		indices = first_new:last_index
		_colorbar_math_titles!(
			fig,
			indices;
			coloraxes = coloraxis === nothing ? () : (coloraxis,),
		)
		if !isempty(style)
			_apply_style_trace_defaults!(
				fig,
				indices;
				explicit = Tuple(
					name for name in _STYLE_TRACE_DEFAULT_KEYWORDS if !(name in style)
				),
			)
		end
	end
	_FIELD2D_DEFER_FINALIZE[] || _finalize_figure!(fig)
	return nothing
end

# ── Heatmap ──────────────────────────────────────────────────────────

# Per-cell text of a heatmap (spec F27). `text` uses the `U[ix, iy]` layout of
# the data; plain text (`_label_plain`: plotly never typesets cell text).
function _heatmap_text_fields(
	text,
	texttemplate::AbstractString,
	textsize,
	data_size::Tuple{Int, Int},
	who::AbstractString,
)
	fields = Dict{Symbol, Any}()
	_field2d_nonnegative(textsize, who, "textsize")
	if text !== nothing
		(text isa AbstractArray && ndims(text) == 2) || throw(ArgumentError(
			"$(who): `text` must be a matrix of cell labels indexed " *
			"text[ix, iy] like U; got $(typeof(text)).",
		))
		size(text) == data_size || throw(ArgumentError(
			"$(who): `text` must have the size of U, $(data_size) (indexed " *
			"text[ix, iy]); got $(size(text)).",
		))
		fields[:text] = map(
			label -> _label_plain(label isa AbstractString ? label : string(label)),
			text,
		)
		isempty(texttemplate) && (fields[:texttemplate] = "%{text}")
	end
	isempty(texttemplate) || (fields[:texttemplate] = String(texttemplate))
	textsize > 0 && (fields[:textfont] = attr(size = textsize))
	return fields
end

function _heatmap_add!(
	fig,
	who::AbstractString,
	x,
	y,
	U;
	constructor::Bool,
	xlabel::AbstractString,
	ylabel::AbstractString,
	title::AbstractString,
	xrange,
	yrange,
	zrange,
	crange,
	cmid,
	colornorm,
	levels,
	colorscale,
	showscale::Union{Nothing, Bool},
	colorbar_title::AbstractString,
	colorbar_title_side = :top,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
	text,
	texttemplate::AbstractString,
	textsize,
	origin,
	xgap,
	ygap,
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
	tight = true,
	interpolation = :nearest,
	xscale::AbstractString,
	yscale::AbstractString,
)
	xrange = _field2d_checked_range(xrange, who, "xrange")
	yrange = _field2d_checked_range(yrange, who, "yrange")
	_field2d_validate_cartesian(
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
	)
	tight_value = _field2d_bool(tight, who, "tight")
	zsmooth = _field2d_zsmooth(interpolation, who; image = false)
	title_side = _field2d_title_side(colorbar_title_side, who)
	origin_value = _field2d_origin(origin, who; allow_unset = !constructor)
	_field2d_nonnegative(xgap, who, "xgap")
	_field2d_nonnegative(ygap, who, "ygap")
	Z = _field2d_matrix(U, who)
	_field2d_check_coordinates(
		x,
		who,
		"x";
		log_axis = _field2d_log_axis(fig, :x, xscale),
	)
	_field2d_check_coordinates(
		y,
		who,
		"y";
		log_axis = _field2d_log_axis(fig, :y, yscale),
	)
	_field2d_check_shape(x, y, Z, who; allow_edges = true)
	color = _field2d_color(
		Z,
		who;
		zrange = zrange,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		levels = levels,
		colorscale = colorscale,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
	)
	fields = Dict{Symbol, Any}(
		:x => x,
		:y => y,
		:z => transpose(color.values),
	)
	_field2d_color_trace_fields!(fields, color)
	merge!(
		fields,
		_heatmap_text_fields(text, texttemplate, textsize, size(Z), who),
	)
	xgap > 0 && (fields[:xgap] = xgap)
	ygap > 0 && (fields[:ygap] = ygap)
	zsmooth === nothing || (fields[:zsmooth] = zsmooth)
	_field2d_mark_field!(fields, tight_value)

	first_new = length(_plot_data(fig)) + 1
	push!(_plot_data(fig), heatmap(; fields...))
	_field2d_apply_coloraxis!(fig, color)
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
		origin = origin_value,
		equalar = equalar,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
	)
	_field2d_finish!(fig, first_new; coloraxis = color.coloraxis)
	return nothing
end

"""
	plot_heatmap(x, y, U; kwargs...)
	plot_heatmap(U; kwargs...)

Draw the matrix `U` as a heatmap. `U[ix, iy]` is the value at
`(x[ix], y[iy])`, so `size(U) == (length(x), length(y))`; `x`/`y` may instead
list the `n + 1` cell edges. This is the layout of `f.(X, Y)` for
`Y, X = meshgrid(y, x)`. A wrongly shaped `U` throws an `ArgumentError` (a
matrix indexed `U[iy, ix]` is reported as transposed: pass `permutedims(U)`).
Without `x`/`y` the cells sit at the 0-based indices `0:size(U, 1)-1` and
`0:size(U, 2)-1` (1-based on an axis made logarithmic with `xscale`/`yscale`).

`x`/`y` are vectors of finite reals (positive on a log axis), strings
(categories) or dates. `U` holds real numbers; NaN and `missing` leave gaps,
Bool matrices are drawn as 0/1, complex matrices throw (plot `abs.(U)`,
`real.(U)`, `angle.(U)`, ...). `U` is not copied.

#### Keywords

Colour (spec C21):
- `colorscale = ""`: a colormap name (`"viridis"`, `"RdBu_r"`, any `COLORMAPS`,
  plotly.js or ColorSchemes.jl name, `_r` reverses), a vector of colours or of
  `(t, colour)` stops, or a `ColorScheme`; `""` uses the template's. Unknown
  names throw with suggestions.
- `crange = [0, 0]`: colour limits `(lower, upper)`; `[0, 0]`/`nothing` is
  automatic. `zrange` is an alias (passing both throws).
- `cmid::Union{Nothing,Real} = nothing`: colour midpoint. With an automatic
  `crange` it is plotly's `zmid`; inside an explicit `crange` the colorscale
  is remapped so its centre sits at `cmid` (two-slope norm).
- `colornorm = :linear`: `:log` colours `log10(U)` (non-positive values are
  gaps, or `crange[1]` with an explicit positive `crange`); the colorbar shows
  decades `10ᵏ` and the hover shows the raw values.
- `levels = nothing`: `k + 1` increasing boundaries give `k` discrete colour
  bands (BoundaryNorm); excludes `crange`/`cmid`.
- `showscale::Union{Nothing,Bool} = nothing`: show/hide the colorbar
  (`nothing` = plotly default, shown).
- `colorbar_title = ""`: colorbar title (mathtext; a title in `\$...\$` is
  drawn as a typeset annotation beside the bar, in single figures and in
  subplot cells), `colorbar_title_side = :top`: where the title sits, `:top`,
  `:right` (along the bar) or `:bottom` (Symbol or String).
- `colorbar_ticks = nothing` (tick values in data units),
  `colorbar_ticklabels = nothing` (same length as `colorbar_ticks`).
- `coloraxis = nothing`: `:shared` (or `"coloraxis2"`, ...) binds the trace to
  a shared `layout.coloraxis`, which then receives the colour settings.

Cells and text (spec F27):
- `text = nothing`: matrix of per-cell labels, same size and `[ix, iy]`
  indexing as `U` (plain text; `<br>` breaks lines). Implies
  `texttemplate = "%{text}"` unless one is given.
- `texttemplate = ""`: e.g. `"%{z:.2f}"` (with `colornorm = :log`, `z` is
  `log10` of the value).
- `textsize::Real = 0`: cell-text font size (0 = automatic).
- `origin = :lower`: `:upper` reverses the y axis so `y[1]` is at the top.
- `xgap::Real = 0`, `ygap::Real = 0`: gaps between cells in pixels.
- `interpolation = :nearest`: `:nearest` draws every cell as a flat brick;
  `:bilinear` interpolates the colour between cell centres (plotly
  `zsmooth = "best"`), as matplotlib's `imshow(interpolation = "bilinear")`.

Axes and figure:
- `xlabel = ""`, `ylabel = ""`, `title = ""`: text (LaTeX in `\$...\$` allowed).
- `xrange = [0, 0]`, `yrange = [0, 0]`: axis limits `(lower, upper)` (a
  2-element vector or tuple) in data units, also on a log axis (converted to
  the log10 values plotly stores); a range turns the axis's autorange off.
  `[0, 0]`, `nothing` or `[nothing, nothing]` leaves the axis automatic. A
  one-sided limit `(lo, nothing)` or `(nothing, hi)` fixes that bound and
  lets the other side autorange (matplotlib `set_xlim(left = lo)`); on an
  equal-aspect axis, which plotly.js re-ranges for the aspect, the other
  limit is fixed at the current data extent instead (as matplotlib does).
  Two bounds must differ; Bool and `missing` bounds throw. Dates and
  category strings are accepted.
- `xscale = ""`, `yscale = ""`: axis type, e.g. `"log"`.
- `xticks = nothing`, `xticklabels = nothing`, `xtickformat = ""`, `yticks`,
  `yticklabels`, `ytickformat`: explicit tick values (data units; `Date`s on
  a date axis), their labels (same length), and a d3 tick format. Tick
  presets (`:decades`, `:auto`) work as in `xticks!`.
- `grid::Union{Nothing,Bool,Symbol} = true`: `true` keeps the template grid,
  `false`/`:none` hides it, `:x`/`:y`/`:both` choose the axes.
- `equalar::Bool = false`: equal data aspect (one x unit = one y unit).
- `tight::Bool = true`: while an axis autoranges, its range is fitted to the
  field (the outer cell edges, also on log axes) and the other traces on that
  axis, without plotly's padding. `false` restores plotly's padded autorange
  on both axes of the trace. An explicit `xrange`/`yrange` always wins.
- `width = 0`, `height = 0` (pixels, 0 = automatic), `fontsize = 0`.
- `show::Bool = false`: open the figure in a window and return a `SyncPlot`.

Returns a `Plot` (a `SyncPlot` when `show = true`). Invalid input throws an
`ArgumentError`.

# Example
```julia
x = range(0, 2; length = 40)
y = range(-1, 1; length = 30)
U = [sin(pi * xi) * yi for xi in x, yi in y]     # U[ix, iy]
fig = plot_heatmap(x, y, U; colorscale = "RdBu_r", cmid = 0,
	xlabel = "x", ylabel = "y", colorbar_title = "u")
```
"""
function plot_heatmap(
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	levels = nothing,
	colorscale = "",
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	text = nothing,
	texttemplate::AbstractString = "",
	textsize::Real = 0,
	origin::Union{Symbol, AbstractString} = :lower,
	xgap::Real = 0,
	ygap::Real = 0,
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
	tight = true,
	interpolation = :nearest,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	show::Bool = false,
)
	fig = _field2d_new_figure()
	_heatmap_add!(
		fig,
		"plot_heatmap",
		x,
		y,
		U;
		constructor = true,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		levels = levels,
		colorscale = colorscale,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
		text = text,
		texttemplate = texttemplate,
		textsize = textsize,
		origin = origin,
		xgap = xgap,
		ygap = ygap,
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
		tight = tight,
		interpolation = interpolation,
		xscale = xscale,
		yscale = yscale,
	)
	return _field2d_show(fig, show, width, height, title)
end

function plot_heatmap(
	U::AbstractArray;
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	kwargs...,
)
	x = _field2d_implicit_axis(size(U, 1), xscale == "log")
	y = _field2d_implicit_axis(size(U, 2), yscale == "log")
	return plot_heatmap(x, y, U; xscale = xscale, yscale = yscale, kwargs...)
end

# ── Contour ──────────────────────────────────────────────────────────

const _CONTOUR_COLORINGS = ("fill", "lines", "heatmap", "none")

# plotly.js's default line and label colour of an ordinary (level) contour
# trace (contour style defaults: `line.color` "#000"); used for the
# constraint traces of filled bands, whose own default is the fill colour.
const _CONTOUR_DEFAULT_LINE_COLOR = "#000"

function _contour_uniform_levels(values::Vector{Float64})
	step = values[2] - values[1]
	return all(
		i -> isapprox(values[i + 1] - values[i], step; rtol = 1e-6),
		1:(length(values) - 1),
	)
end

# Contour-level specification of plot_contour(!) (spec F26). `kind` is
# `:auto` (plotly chooses), `:count` (`ncontours`), `:uniform`
# (start/end/size), `:per_level` (one trace per level: a single level, or
# non-uniform line contours) or `:bands` (non-uniform filled contours: one
# constraint trace per band). `values` are in plotted units (log10 under
# colornorm = :log), `boundaries` in data units.
function _contour_specs(
	levels,
	who::AbstractString;
	ncontours = 0,
	coloring = "",
	linecolor_set::Bool = false,
	log_levels::Bool = false,
)
	(ncontours isa Integer && !(ncontours isa Bool) && ncontours >= 0) ||
		throw(ArgumentError(
			"$(who): `ncontours` must be an integer ≥ 0 (0 = automatic); got " *
			"$(repr(ncontours)).",
		))
	(coloring isa Symbol || coloring isa AbstractString) || throw(ArgumentError(
		"$(who): `coloring` must be a string or symbol; got $(repr(coloring)).",
	))
	mode = lowercase(strip(String(coloring)))
	(isempty(mode) || mode in _CONTOUR_COLORINGS) || throw(ArgumentError(
		"$(who): `coloring` must be \"fill\", \"lines\", \"heatmap\", \"none\" " *
		"or \"\" (plotly default, filled); got $(repr(coloring)).",
	))
	if linecolor_set
		mode == "lines" && throw(ArgumentError(
			"$(who): `linecolor` conflicts with coloring = \"lines\" (lines " *
			"coloured by the colorscale); use coloring = \"none\" or \"fill\".",
		))
		isempty(mode) && (mode = "none")
	end
	kind = :auto
	count = 0
	values = Float64[]
	boundaries = Float64[]
	if levels === nothing
		ncontours > 0 && (kind = :count; count = Int(ncontours))
	elseif levels isa Integer && !(levels isa Bool)
		ncontours > 0 && throw(ArgumentError(
			"$(who): pass either `levels` or `ncontours`, not both.",
		))
		levels >= 1 || throw(ArgumentError(
			"$(who): an integer `levels` is the number of contour levels and " *
			"must be ≥ 1; got $(levels).",
		))
		kind = :count
		count = Int(levels)
	else
		ncontours > 0 && throw(ArgumentError(
			"$(who): pass either `levels` or `ncontours`, not both.",
		))
		(levels isa AbstractVector || levels isa Tuple) || throw(ArgumentError(
			"$(who): `levels` must be an integer (number of levels) or a " *
			"vector of level values; got $(repr(levels)).",
		))
		boundaries = _checked_real_vector(levels, who, "levels")
		isempty(boundaries) && throw(ArgumentError(
			"$(who): `levels` must contain at least one level.",
		))
		all(i -> boundaries[i] < boundaries[i + 1], 1:(length(boundaries) - 1)) ||
			throw(ArgumentError(
				"$(who): `levels` must be strictly increasing; got $(repr(levels)).",
			))
		if log_levels
			all(>(0), boundaries) || throw(ArgumentError(
				"$(who): `levels` must be positive for colornorm = :log; got " *
				"$(repr(levels)).",
			))
			values = log10.(boundaries)
		else
			values = copy(boundaries)
		end
		if length(values) >= 2 && _contour_uniform_levels(values)
			kind = :uniform
		elseif length(values) >= 2
			isempty(mode) && (mode = "fill")
			mode == "heatmap" && throw(ArgumentError(
				"$(who): coloring = \"heatmap\" needs uniformly spaced `levels`; " *
				"got $(repr(levels)).",
			))
			kind = mode == "fill" ? :bands : :per_level
		else
			isempty(mode) && (mode = "lines")
			mode in ("fill", "heatmap") && throw(ArgumentError(
				"$(who): coloring = \"$(mode)\" needs at least two `levels` (a " *
				"filled band lies between two levels); got $(repr(levels)).",
			))
			kind = :per_level
		end
	end
	return (
		kind = kind,
		count = count,
		values = values,
		boundaries = boundaries,
		coloring = mode,
	)
end

const _CONTOUR_DASHES =
	("solid", "dot", "dash", "longdash", "dashdot", "longdashdot")
const _CONTOUR_DASH_LIST =
	r"^\s*\d+(\.\d+)?(px|%)?(\s*,\s*\d+(\.\d+)?(px|%)?)*\s*$"

function _field2d_dash(dash, who::AbstractString)
	(dash isa Symbol || dash isa AbstractString) || throw(ArgumentError(
		"$(who): `dash` must be a string or symbol; got $(repr(dash)).",
	))
	value = strip(String(dash))
	(isempty(value) || value in _CONTOUR_DASHES ||
		occursin(_CONTOUR_DASH_LIST, value)) || throw(ArgumentError(
		"$(who): `dash` must be one of $(join(repr.(_CONTOUR_DASHES), ", ")), a " *
		"dash-length list such as \"5px,3px\", or \"\"; got $(repr(dash)).",
	))
	return String(value)
end

function _contour_add!(
	fig,
	who::AbstractString,
	x,
	y,
	U;
	constructor::Bool,
	levels,
	ncontours,
	coloring,
	linecolor,
	linewidth,
	dash,
	showlabels::Bool,
	labelformat::AbstractString,
	xlabel::AbstractString,
	ylabel::AbstractString,
	title::AbstractString,
	xrange,
	yrange,
	zrange,
	crange,
	cmid,
	colornorm,
	colorscale,
	showscale::Union{Nothing, Bool},
	colorbar_title::AbstractString,
	colorbar_title_side,
	colorbar_ticks,
	colorbar_ticklabels,
	coloraxis,
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
	tight,
	xscale::AbstractString,
	yscale::AbstractString,
)
	xrange = _field2d_checked_range(xrange, who, "xrange")
	yrange = _field2d_checked_range(yrange, who, "yrange")
	_field2d_validate_cartesian(
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
	)
	tight_value = _field2d_bool(tight, who, "tight")
	title_side = _field2d_title_side(colorbar_title_side, who)
	line_color = _field2d_color_string(linecolor, who, "linecolor")
	_field2d_nonnegative(linewidth, who, "linewidth")
	dash_value = _field2d_dash(dash, who)
	log_norm = _normalize_colornorm(colornorm, who) === :log
	spec = _contour_specs(
		levels,
		who;
		ncontours = ncontours,
		coloring = coloring,
		linecolor_set = !isempty(line_color),
		log_levels = log_norm,
	)
	single_colour = spec.coloring == "none"
	single_colour && showscale === true && throw(ArgumentError(
		"$(who): `showscale = true` needs colour-mapped contours; coloring = " *
		"\"none\" (or a `linecolor`) draws single-colour lines.",
	))
	Z = _field2d_matrix(U, who)
	_field2d_check_coordinates(
		x,
		who,
		"x";
		log_axis = _field2d_log_axis(fig, :x, xscale),
	)
	_field2d_check_coordinates(
		y,
		who,
		"y";
		log_axis = _field2d_log_axis(fig, :y, yscale),
	)
	_field2d_check_shape(x, y, Z, who; allow_edges = false)
	bands = spec.kind === :bands
	# G15: colour-mapped lines at a single or non-uniform levels are one trace
	# per level (start == end), for which plotly.js builds a degenerate colour
	# map (every level in the same colour). Their colours are sampled here, and
	# a carrier trace draws the colorbar, as for bands.
	line_levels = spec.kind === :per_level && spec.coloring == "lines"
	carried = bands || line_levels
	color = _field2d_color(
		Z,
		who;
		zrange = zrange,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		levels = nothing,
		colorscale = colorscale,
		showscale = single_colour ? false : showscale,
		colorbar_title = carried ? "" : colorbar_title,
		colorbar_title_side = title_side,
		colorbar_ticks = carried ? nothing : colorbar_ticks,
		colorbar_ticklabels = carried ? nothing : colorbar_ticklabels,
		coloraxis = carried ? nothing : coloraxis,
	)
	user_crange = _checked_range(zrange, who, "zrange") === nothing ? crange : zrange
	user_ticklabels = colorbar_ticklabels === nothing ? nothing :
		_field2d_labels(colorbar_ticklabels, who, "colorbar_ticklabels")
	band_norm = nothing
	if bands
		# Filled bands between non-uniform levels: the band colours and the
		# stepped colorbar come from the BoundaryNorm of the levels.
		band_norm = _apply_color_norm(
			nothing;
			crange = user_crange,
			cmid = cmid,
			colornorm = colornorm,
			levels = spec.boundaries,
			stops = colorscale,
			ticks = colorbar_ticks,
			ticklabels = user_ticklabels,
			who = who,
		)
	end
	carrier_norm = band_norm
	level_colours = String[]
	if line_levels
		line_norm = _contour_line_norm(
			spec,
			color.values,
			who;
			crange = user_crange,
			cmid = cmid,
			colornorm = colornorm,
			colorscale = colorscale,
			colorbar_ticks = colorbar_ticks,
			colorbar_ticklabels = user_ticklabels,
		)
		level_colours = line_norm.colours
		carrier_norm = line_norm
	elseif bands && colorbar_ticks === nothing
		# matplotlib labels a contour colorbar with FixedLocator(levels,
		# nbins = 10): at most about ten of the boundaries.
		keep = _contour_tick_subset(band_norm.tickvals)
		carrier_norm = (
			stops = band_norm.stops,
			cmin = band_norm.cmin,
			cmax = band_norm.cmax,
			tickvals = band_norm.tickvals[keep],
			ticktext = band_norm.ticktext === nothing ? nothing : band_norm.ticktext[keep],
		)
	end

	base = Dict{Symbol, Any}(:x => x, :y => y, :z => transpose(color.values))
	_field2d_color_trace_fields!(base, color)
	# Filled contours draw the field: tight/loose `meta`. Line contours are
	# overlays and carry no field `meta` (a native contour trace already
	# counts as tight); `tight = false` still opts them out (CONTRACT.md §1).
	(spec.coloring in ("lines", "none") && tight_value) ||
		_field2d_mark_field!(base, tight_value)
	line = Dict{Symbol, Any}()
	isempty(line_color) || (line[:color] = line_color)
	# Line contours take the style's line width when `linewidth = 0` (X10);
	# filled contours keep plotly's thin level boundaries.
	line_width = linewidth > 0 ? linewidth :
		spec.coloring in ("lines", "none") ? _field2d_style_linewidth(nothing) : nothing
	line_width === nothing || (line[:width] = line_width)
	isempty(dash_value) || (line[:dash] = dash_value)
	contours = Dict{Symbol, Any}()
	(isempty(spec.coloring) || bands) || (contours[:coloring] = spec.coloring)
	showlabels && (contours[:showlabels] = true)
	isempty(labelformat) || (contours[:labelformat] = String(labelformat))
	single_colour && (base[:showlegend] = false)

	traces = GenericTrace[]
	if spec.kind === :count
		base[:ncontours] = spec.count
	elseif spec.kind === :uniform
		base[:autocontour] = false
		contours[:start] = spec.values[1]
		contours[:end] = spec.values[end]
		contours[:size] = spec.values[2] - spec.values[1]
	end
	if spec.kind in (:auto, :count, :uniform)
		isempty(line) || (base[:line] = attr(; line...))
		isempty(contours) || (base[:contours] = attr(; contours...))
		push!(traces, contour(; base...))
	elseif spec.kind === :per_level
		for (index, level) in enumerate(spec.values)
			fields = copy(base)
			fields[:autocontour] = false
			level_contours = copy(contours)
			level_contours[:start] = level
			level_contours[:end] = level
			# plotly needs a positive size; start == end gives one level.
			level_contours[:size] = 1
			level_line = copy(line)
			if line_levels
				# The level's colour from the colour map (G15); the carrier
				# below draws the colorbar.
				level_contours[:coloring] = "none"
				level_line[:color] = level_colours[index]
				showlabels && (level_contours[:labelfont] = attr(color = level_colours[index]))
				fields[:showscale] = false
				# plotly.js lists a contour trace with coloring "none" in the
				# legend (contour/style_defaults: only other colourings default
				# `showlegend` to false); the levels are one field, not series.
				fields[:showlegend] = false
			end
			fields[:contours] = attr(; level_contours...)
			isempty(level_line) || (fields[:line] = attr(; level_line...))
			if index > 1
				# One colorbar and one hover label for the whole level set.
				color.coloraxis === nothing && (fields[:showscale] = false)
				fields[:hoverinfo] = "skip"
			end
			push!(traces, contour(; fields...))
		end
	else
		k = length(spec.values) - 1
		for band in 1:k
			fill_colour = band_norm.stops[2 * band - 1][2]
			# plotly shades the region a constraint EXCLUDES, so "][" (keep
			# values outside the band) fills the band itself.
			band_contours = Dict{Symbol, Any}(
				:type => "constraint",
				:operation => "][",
				:value => Any[spec.values[band], spec.values[band + 1]],
			)
			# Constraint contours draw their lines and labels in the fill colour
			# by default (labels invisible on their own band); use the colour of
			# an ordinary contour trace instead.
			band_line_colour = isempty(line_color) ? _CONTOUR_DEFAULT_LINE_COLOR : line_color
			if showlabels
				band_contours[:showlabels] = true
				band_contours[:labelfont] = attr(color = band_line_colour)
			end
			isempty(labelformat) ||
				(band_contours[:labelformat] = String(labelformat))
			band_line = Dict{Symbol, Any}(
				:color => band_line_colour,
				# No outline between bands unless a line width is requested.
				:width => linewidth > 0 ? linewidth : 0,
			)
			isempty(dash_value) || (band_line[:dash] = dash_value)
			fields = Dict{Symbol, Any}(
				:x => x,
				:y => y,
				:z => base[:z],
				:autocontour => false,
				:contours => attr(; band_contours...),
				:fillcolor => fill_colour,
				:line => attr(; band_line...),
				:showscale => false,
				:showlegend => false,
			)
			_field2d_mark_field!(fields, tight_value)
			if band == 1
				color.customdata === nothing ||
					(fields[:customdata] = color.customdata)
				color.customdata === nothing ||
					(fields[:hovertemplate] = _FIELD2D_LOG_HOVERTEMPLATE)
			else
				fields[:hoverinfo] = "skip"
			end
			push!(traces, contour(; fields...))
		end
	end
	if carried
		# One colorbar for the sampled colours (bands or level lines).
		colorbar = _field2d_colorbar(
			colorbar_title,
			title_side,
			who;
			ticks = carrier_norm.tickvals,
			ticklabels = carrier_norm.ticktext,
		)
		if coloraxis === nothing
			push!(
				traces,
				_colorbar_carrier_trace(;
					stops = carrier_norm.stops,
					cmin = carrier_norm.cmin,
					cmax = carrier_norm.cmax,
					showscale = showscale !== false,
					colorbar = colorbar,
					who = who,
				),
			)
		else
			axis_id = _normalize_coloraxis(coloraxis, who)
			push!(
				traces,
				_colorbar_carrier_trace(;
					cmin = carrier_norm.cmin,
					cmax = carrier_norm.cmax,
					coloraxis = axis_id,
					who = who,
				),
			)
			axis_fields = Dict{Symbol, Any}(
				:colorscale => carrier_norm.stops,
				:cmin => carrier_norm.cmin,
				:cmax => carrier_norm.cmax,
			)
			showscale === nothing || (axis_fields[:showscale] = showscale)
			colorbar === nothing || (axis_fields[:colorbar] = colorbar)
			_cmn_merge_layout_key!(
				fig,
				Symbol(axis_id),
				axis_fields;
				nested = (:colorbar,),
			)
		end
	end

	first_new = length(_plot_data(fig)) + 1
	append!(_plot_data(fig), traces)
	_field2d_apply_coloraxis!(fig, color)
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
	)
	_field2d_finish!(
		fig,
		first_new;
		coloraxis = carried ?
			(coloraxis === nothing ? nothing : _normalize_coloraxis(coloraxis, who)) :
			color.coloraxis,
	)
	return nothing
end

# matplotlib's `FixedLocator(levels, nbins = 10)`, the tick locator of a
# contour colorbar: every `step`-th level, step = max(ceil(n / 10), 1), from
# the offset whose subset holds the level closest to zero. Returns the kept
# indices of `levels`.
const _CONTOUR_COLORBAR_NBINS = 10

function _contour_tick_subset(levels::AbstractVector{<:Real})
	n = length(levels)
	step = max(cld(n, _CONTOUR_COLORBAR_NBINS), 1)
	best = collect(1:step:n)
	for offset in 2:min(step, n)
		candidate = collect(offset:step:n)
		minimum(abs, levels[candidate]) < minimum(abs, levels[best]) && (best = candidate)
	end
	return best
end

# Colours of colour-mapped contour lines drawn one trace per level (G15) and
# the colorbar that explains them. matplotlib's line contours normalise
# between the lowest and the highest level; an explicit `crange` (with a
# `cmid` two-slope remap) wins, `cmid` alone centres the levels' span on it,
# and a single level spans the data. Level values and limits are in plotted
# units (log10 under colornorm = :log). Colorbar ticks sit at the levels
# (`_contour_tick_subset`) unless `colorbar_ticks` are given.
function _contour_line_norm(
	spec,
	values,
	who::AbstractString;
	crange,
	cmid,
	colornorm,
	colorscale,
	colorbar_ticks,
	colorbar_ticklabels,
)
	log_norm = _normalize_colornorm(colornorm, who) === :log
	norm = _apply_color_norm(
		spec.boundaries;
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		stops = colorscale,
		ticks = colorbar_ticks,
		ticklabels = colorbar_ticklabels,
		who = who,
	)
	levels = spec.values
	if norm.cmin !== nothing && norm.cmax !== nothing
		lower, upper = Float64(norm.cmin), Float64(norm.cmax)
	else
		if length(levels) >= 2
			lower, upper = extrema(levels)
		else
			extent = _finite_extrema(values)
			lower, upper = extent === nothing ? (levels[1], levels[1]) : extent
		end
		if norm.cmid !== nothing
			half = max(upper - norm.cmid, norm.cmid - lower)
			lower, upper = norm.cmid - half, norm.cmid + half
		end
		if !(lower < upper)
			# A constant field (or no finite value): centre the level.
			lower, upper = lower - 0.5, upper + 0.5
		end
	end
	stops = _concrete_norm_stops(norm.stops, nothing, who)
	colours = _sample_colorscale(
		stops,
		[clamp((level - lower) / (upper - lower), 0.0, 1.0) for level in levels],
	)
	if colorbar_ticks === nothing
		keep = _contour_tick_subset(levels)
		tickvals = levels[keep]
		ticktext = log_norm ? [_log_tick_label(b) for b in spec.boundaries[keep]] : nothing
	else
		tickvals = norm.tickvals
		ticktext = norm.ticktext
	end
	return (
		colours = colours,
		stops = stops,
		cmin = lower,
		cmax = upper,
		tickvals = tickvals,
		ticktext = ticktext,
	)
end

"""
	plot_contour(x, y, U; kwargs...)
	plot_contour(U; kwargs...)

Draw contours of the matrix `U`. `U[ix, iy]` is the value at `(x[ix], y[iy])`,
so `size(U) == (length(x), length(y))` (exactly; the layout of `f.(X, Y)` for
`Y, X = meshgrid(y, x)`). A wrongly shaped `U` throws an `ArgumentError` that
suggests `permutedims(U)` when the matrix is transposed. Without `x`/`y` the
grid is `0:size(U, 1)-1` by `0:size(U, 2)-1` (1-based on a log axis). `x`/`y`
and `U` follow the rules of [`plot_heatmap`](@ref) (finite coordinates; real
values with NaN/`missing` gaps; Bool drawn as 0/1; complex throws).

#### Keywords

Levels and lines (spec F26):
- `levels = nothing`: an `Integer` is the number of levels (plotly picks
  them); a uniformly spaced vector gives exactly those levels
  (`contours.start/end/size`); a single level or non-uniform levels draw one
  line trace per level; non-uniform levels with filled colouring draw one
  filled band per interval (values outside `[levels[1], levels[end]]` stay
  empty) and a stepped colorbar. Levels are data values, also with
  `colornorm = :log`.
- `ncontours::Integer = 0`: number of automatic levels (not with `levels`).
- `coloring = ""`: `"fill"` (plotly default), `"lines"` (lines coloured by the
  colorscale), `"heatmap"`, or `"none"` (single-colour lines without colorbar
  or legend entry). A single level defaults to `"lines"`. Line contours drawn
  one trace per level (a single level, non-uniform levels) take the colour of
  their level on the norm (`crange`, else `levels[1]..levels[end]`, else the
  data extent; matplotlib `contour(..., cmap = ...)`), and their colorbar,
  carried by an invisible trace, has its ticks at the levels (at most 10,
  thinned like matplotlib's level ticks) unless `colorbar_ticks` is given.
- `linecolor = ""`: one colour for every contour line (string, Symbol or
  Colorant); implies `coloring = "none"` unless `"fill"`/`"heatmap"` is given
  and conflicts with `"lines"`.
- `linewidth::Real = 0`: line width in px. `0` is automatic: line contours
  (`coloring = "lines"`/`"none"`) take the active style's line width
  ([`with_style`](@ref)), else plotly's default; filled contours keep plotly's
  thin level boundaries (bands: none).
- `dash = ""` (`"dash"`, `"dot"`, `"dashdot"`, ... or `"5px,3px"`).
- `showlabels::Bool = false`, `labelformat = ""` (d3 format, e.g. `".2f"`).

Colour: `colorscale`, `crange` (alias `zrange`), `cmid`, `colornorm`,
`showscale`, `colorbar_title`, `colorbar_title_side = :top`,
`colorbar_ticks`, `colorbar_ticklabels`, `coloraxis` as for
[`plot_heatmap`](@ref) (`showscale = true` with single-colour lines throws).

Axes and figure: `xlabel`, `ylabel`, `title`, `xrange`, `yrange`, `xscale`,
`yscale`, `xticks`, `xticklabels`, `xtickformat`, `yticks`, `yticklabels`,
`ytickformat`, `grid = true`, `equalar = false`, `tight::Bool = true`,
`width`, `height`, `fontsize`, `show = false`, as for [`plot_heatmap`](@ref).
`tight` fits the autoranged axes to the contour grid (filled contours and
line contours alike); `tight = false` opts the trace out.

Returns a `Plot` (a `SyncPlot` when `show = true`). Invalid input throws an
`ArgumentError`.

# Example
```julia
x = range(-2, 2; length = 60)
y = range(-1, 1; length = 40)
U = [exp(-xi^2 - 4yi^2) for xi in x, yi in y]    # U[ix, iy]
fig = plot_heatmap(x, y, U)
plot_contour!(fig, x, y, U; levels = [0.5], linecolor = "white",
	showlabels = true)                         # overlay one labelled level
```
"""
function plot_contour(
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray;
	levels = nothing,
	ncontours::Integer = 0,
	coloring::Union{Symbol, AbstractString} = "",
	linecolor = "",
	linewidth::Real = 0,
	dash::Union{Symbol, AbstractString} = "",
	showlabels::Bool = false,
	labelformat::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	colorscale = "",
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
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
	tight = true,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	show::Bool = false,
)
	fig = _field2d_new_figure()
	_contour_add!(
		fig,
		"plot_contour",
		x,
		y,
		U;
		constructor = true,
		levels = levels,
		ncontours = ncontours,
		coloring = coloring,
		linecolor = linecolor,
		linewidth = linewidth,
		dash = dash,
		showlabels = showlabels,
		labelformat = labelformat,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		colorscale = colorscale,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
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
		tight = tight,
		xscale = xscale,
		yscale = yscale,
	)
	return _field2d_show(fig, show, width, height, title)
end

function plot_contour(
	U::AbstractArray;
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	kwargs...,
)
	x = _field2d_implicit_axis(size(U, 1), xscale == "log")
	y = _field2d_implicit_axis(size(U, 2), yscale == "log")
	return plot_contour(x, y, U; xscale = xscale, yscale = yscale, kwargs...)
end

# ── Quiver ───────────────────────────────────────────────────────────

# Arrow geometry: the longest arrow is `sizeref * _QUIVER_SHAFT_SCALE` axis
# units long and every arrowhead arm is `_QUIVER_HEAD_SCALE` of its shaft at
# `_QUIVER_HEAD_ANGLE` from it (plotly.py's create_quiver proportions).
const _QUIVER_SHAFT_SCALE = 2 / 3
const _QUIVER_HEAD_SCALE = 0.3
const _QUIVER_HEAD_ANGLE = pi / 9

# Quiver kinds (lead decision D13).
const _QUIVER_STYLES = (:arrow, :triangle)
const _QUIVER_PIVOTS = (:tail, :middle, :tip)
const _QUIVER_SCALES = (:magnitude, :uniform)
# `headwidth` default of `style = :triangle`: the base is half as wide as the
# triangle is long (D13).
const _QUIVER_TRIANGLE_HEADWIDTH = 0.5
# Colour bins of `colorby` (one trace per non-empty bin, as plot_polygons):
# 256 bins resolve every step of an 8-bit colormap (the mesh family's
# `ncolors` default), while the trace count stays bounded by the glyph count.
const _QUIVER_COLOR_BINS = 256
# Points per glyph in the trace arrays, the closing gap included: an arrow is
# tail, tip, gap, head arm, tip, head arm, gap; a triangle is base corner,
# apex, base corner, first corner again, gap.
const _QUIVER_ARROW_POINTS = 7
const _QUIVER_TRIANGLE_POINTS = 5

# Glyph outlines of every finite, non-zero vector, in data units, separated by
# `_GAP` (JSON null). Returns `(xs, ys, drawn)`: glyph `g` occupies entries
# `(g - 1) * P + 1 : g * P` (`P` = `_QUIVER_ARROW_POINTS` or
# `_QUIVER_TRIANGLE_POINTS`) and `drawn[g]` is the index of its vector.
# - Length: `scale = :magnitude` makes the longest glyph `sizeref *
#   _QUIVER_SHAFT_SCALE` axis units long and the others proportional to their
#   magnitude; `:uniform` gives every glyph that length (a direction field).
# - `style = :arrow`: shaft and two head arms; `:triangle`: a filled isosceles
#   triangle whose base is `headwidth` times its length.
# - `pivot`: the part of the glyph at `(x, y)` (`:tail`, `:middle`, `:tip`).
# On a logarithmic axis the glyph is laid out in axis units (decades) and
# mapped back, so it points at atan(v, u) on screen with equal aspect
# (matplotlib's default `angles = "uv"`); origins there must be positive.
function _quiver_coordinates(
	x,
	y,
	u,
	v,
	sizeref::Real;
	caller::AbstractString,
	xlog::Bool = false,
	ylog::Bool = false,
	style::Symbol = :arrow,
	pivot::Symbol = :tail,
	scale::Symbol = :magnitude,
	headwidth::Real = _QUIVER_TRIANGLE_HEADWIDTH,
)
	n = length(x)
	n == length(y) == length(u) == length(v) || throw(ArgumentError(
		"$caller: x, y, u, v must all have the same length; got " *
		"$(length(x)), $(length(y)), $(length(u)), $(length(v))",
	))
	(sizeref isa Real && !(sizeref isa Bool) && isfinite(sizeref) && sizeref >= 0) ||
		throw(ArgumentError(
			"$caller: sizeref must be finite and non-negative; got $sizeref",
		))

	empty_x = Union{Nothing, Float64}[]
	empty_y = Union{Nothing, Float64}[]
	n == 0 && return empty_x, empty_y, Int[]

	# Represent each magnitude as component * shape, where component is the
	# largest absolute component and shape lies in [1, sqrt(2)]. Comparing
	# bounded ratios avoids squaring overflow and underflow.
	max_component = 0.0
	max_shape = 0.0
	drawable = 0
	skipped = 0

	@inbounds for (xi, yi, ui, vi, i) in zip(x, y, u, v, 1:n)
		for (value, name) in ((xi, "x"), (yi, "y"), (ui, "u"), (vi, "v"))
			value isa Complex && throw(_field2d_complex_error(caller, name))
			(value isa Real && !(value isa Bool)) || throw(ArgumentError(
				"$caller: x, y, u, v values must be real numbers " *
				"(invalid value at index $i)",
			))
		end

		xf, yf, uf, vf = Float64(xi), Float64(yi), Float64(ui), Float64(vi)
		if !(isfinite(xf) && isfinite(yf) && isfinite(uf) && isfinite(vf))
			skipped += 1
			continue
		end
		xlog && xf <= 0 && throw(ArgumentError(
			"$caller: x is on a logarithmic axis, so arrow origins must be " *
			"positive; x[$i] = $xf",
		))
		ylog && yf <= 0 && throw(ArgumentError(
			"$caller: y is on a logarithmic axis, so arrow origins must be " *
			"positive; y[$i] = $yf",
		))

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
		return empty_x, empty_y, Int[]
	end

	# An explicit zero scale is a valid request for no visible arrows.
	iszero(sizeref) && return empty_x, empty_y, Int[]

	triangle = style === :triangle
	points = triangle ? _QUIVER_TRIANGLE_POINTS : _QUIVER_ARROW_POINTS
	output_length = Base.Checked.checked_mul(points, drawable)
	out_x = Vector{Union{Nothing, Float64}}(undef, output_length)
	out_y = Vector{Union{Nothing, Float64}}(undef, output_length)
	drawn = Vector{Int}(undef, drawable)
	cos_head, sin_head = cos(_QUIVER_HEAD_ANGLE), sin(_QUIVER_HEAD_ANGLE)
	max_length = Float64(sizeref) * _QUIVER_SHAFT_SCALE
	# Fraction of the glyph length that lies behind `(x, y)`.
	behind = pivot === :tail ? 0.0 : pivot === :middle ? 0.5 : 1.0
	half_base = Float64(headwidth) / 2
	to_axis_x(value) = xlog ? log10(value) : value
	to_axis_y(value) = ylog ? log10(value) : value
	from_axis_x(value) = xlog ? exp10(value) : value
	from_axis_y(value) = ylog ? exp10(value) : value
	j = 1
	g = 0

	@inbounds for (xi, yi, ui, vi, i) in zip(x, y, u, v, 1:n)
		xf, yf = Float64(xi), Float64(yi)
		uf, vf = Float64(ui), Float64(vi)
		isfinite(xf) && isfinite(yf) && isfinite(uf) && isfinite(vf) ||
			continue

		component = max(abs(uf), abs(vf))
		iszero(component) && continue
		su, sv = uf / component, vf / component
		shape = hypot(su, sv)
		ux, uy = su / shape, sv / shape

		glyph_length = scale === :uniform ? max_length :
			(component / max_component) * (shape / max_shape) * max_length
		anchor_x, anchor_y = to_axis_x(xf), to_axis_y(yf)
		tail_x = anchor_x - behind * glyph_length * ux
		tail_y = anchor_y - behind * glyph_length * uy
		tip_x, tip_y = tail_x + ux * glyph_length, tail_y + uy * glyph_length

		if triangle
			half = half_base * glyph_length
			corners_x = (
				from_axis_x(tail_x - half * uy),
				from_axis_x(tip_x),
				from_axis_x(tail_x + half * uy),
			)
			corners_y = (
				from_axis_y(tail_y + half * ux),
				from_axis_y(tip_y),
				from_axis_y(tail_y - half * ux),
			)
			all(isfinite, corners_x) && all(isfinite, corners_y) ||
				throw(ArgumentError(
					"$caller: scaled glyph coordinates are non-finite at index $i",
				))
			out_x[j], out_y[j] = corners_x[1], corners_y[1]
			out_x[j + 1], out_y[j + 1] = corners_x[2], corners_y[2]
			out_x[j + 2], out_y[j + 2] = corners_x[3], corners_y[3]
			out_x[j + 3], out_y[j + 3] = corners_x[1], corners_y[1]
			out_x[j + 4], out_y[j + 4] = _GAP, _GAP
		else
			arm = _QUIVER_HEAD_SCALE * glyph_length
			head1_x = tip_x - arm * (ux * cos_head - uy * sin_head)
			head1_y = tip_y - arm * (uy * cos_head + ux * sin_head)
			head2_x = tip_x - arm * (ux * cos_head + uy * sin_head)
			head2_y = tip_y - arm * (uy * cos_head - ux * sin_head)

			points_x = (
				from_axis_x(tail_x),
				from_axis_x(tip_x),
				from_axis_x(head1_x),
				from_axis_x(head2_x),
			)
			points_y = (
				from_axis_y(tail_y),
				from_axis_y(tip_y),
				from_axis_y(head1_y),
				from_axis_y(head2_y),
			)
			all(isfinite, points_x) && all(isfinite, points_y) ||
				throw(ArgumentError(
					"$caller: scaled arrow coordinates are non-finite at index $i",
				))
			# The tail is the data point itself for `pivot = :tail` (no
			# round trip through log10/exp10).
			out_x[j] = behind == 0 ? xf : points_x[1]
			out_y[j] = behind == 0 ? yf : points_y[1]
			out_x[j + 1] = points_x[2]
			out_y[j + 1] = points_y[2]
			out_x[j + 2] = _GAP
			out_y[j + 2] = _GAP
			out_x[j + 3] = points_x[3]
			out_y[j + 3] = points_y[3]
			out_x[j + 4] = points_x[2]
			out_y[j + 4] = points_y[2]
			out_x[j + 5] = points_x[4]
			out_y[j + 5] = points_y[4]
			out_x[j + 6] = _GAP
			out_y[j + 6] = _GAP
		end
		g += 1
		drawn[g] = i
		j += points
	end

	return out_x, out_y, drawn
end

# Flatten the accepted quiver input forms into four equal-length vectors:
# four vectors (one arrow per entry), four same-size matrices (meshgrid
# style), coordinate vectors with `u[ix, iy]`/`v[ix, iy]` matrices of size
# (length(x), length(y)), or (as before 2.0) any mix of vectors and matrices
# with one element count, paired element by element in column-major order.
function _quiver_points(x, y, u, v, who::AbstractString)
	for (value, name) in ((x, "x"), (y, "y"), (u, "u"), (v, "v"))
		ndims(value) <= 2 || throw(ArgumentError(
			"$(who): `$(name)` must be a vector or a matrix; got a " *
			"$(ndims(value))-D array of size $(size(value)).",
		))
	end
	dims = (ndims(x), ndims(y), ndims(u), ndims(v))
	if all(==(2), dims)
		size(x) == size(y) == size(u) == size(v) || throw(ArgumentError(
			"$(who): matrices x, y, u, v must have the same size; got " *
			"$(size(x)), $(size(y)), $(size(u)), $(size(v)).",
		))
		return vec(x), vec(y), vec(u), vec(v)
	end
	grid = (length(x), length(y))
	if dims == (1, 1, 2, 2) && size(u) == grid && size(v) == grid
		nx, ny = grid
		return (
			[x[ix] for ix in eachindex(x), _ in 1:ny][:],
			[y[iy] for _ in 1:nx, iy in eachindex(y)][:],
			vec(u),
			vec(v),
		)
	end
	length(x) == length(y) == length(u) == length(v) &&
		return vec(x), vec(y), vec(u), vec(v)
	hint = dims == (1, 1, 2, 2) ?
		" With coordinate vectors x, y the components are indexed u[ix, iy], " *
		"so u and v must have size (length(x), length(y)) = $(grid); got " *
		"$(size(u)) and $(size(v))." *
		(size(u) == reverse(grid) ? " They look transposed: pass permutedims(u), permutedims(v)." : "") :
		""
	throw(ArgumentError(
		"$(who): x, y, u, v must be four vectors of one length, four matrices " *
		"of one size, or coordinate vectors x, y with u, v matrices of size " *
		"(length(x), length(y)); got sizes $(size(x)), $(size(y)), $(size(u)), " *
		"$(size(v)).$(hint)",
	))
end

function _quiver_choice(value, choices::Tuple, who::AbstractString, name::AbstractString)
	(value isa Symbol || value isa AbstractString) || throw(ArgumentError(
		"$(who): `$(name)` must be $(join(repr.(choices), ", ", " or ")); got $(repr(value)).",
	))
	symbol = Symbol(lowercase(strip(String(value))))
	symbol in choices || throw(ArgumentError(
		"$(who): `$(name)` must be $(join(repr.(choices), ", ", " or ")); got $(repr(value)).",
	))
	return symbol
end

# The glyph keywords of plot_quiver(!) (D13), validated. `pivot = nothing`
# is the style's default (`:tail` for arrows, `:middle` for triangles);
# `headwidth = nothing` is `_QUIVER_TRIANGLE_HEADWIDTH`. Triangle-only
# keywords (`headwidth`, `edgecolor`, `edgewidth`) throw with arrows, and the
# arrow-only `linewidth` throws with triangles.
function _quiver_glyph_options(
	who::AbstractString;
	style,
	pivot,
	scale,
	headwidth,
	edgecolor,
	edgewidth,
	linewidth,
	opacity,
)
	style_value = _quiver_choice(style, _QUIVER_STYLES, who, "style")
	triangle = style_value === :triangle
	pivot_value = pivot === nothing ? (triangle ? :middle : :tail) :
		_quiver_choice(pivot, _QUIVER_PIVOTS, who, "pivot")
	scale_value = _quiver_choice(scale, _QUIVER_SCALES, who, "scale")
	width_value = _QUIVER_TRIANGLE_HEADWIDTH
	if headwidth !== nothing
		triangle || throw(ArgumentError(
			"$(who): `headwidth` sets the base of style = :triangle glyphs; " *
			"arrows (style = :arrow) have fixed heads.",
		))
		(headwidth isa Real && !(headwidth isa Bool) && isfinite(headwidth) && headwidth > 0) ||
			throw(ArgumentError(
				"$(who): `headwidth` must be a finite number > 0 (base width as a " *
				"fraction of the triangle's length); got $(repr(headwidth)).",
			))
		width_value = Float64(headwidth)
	end
	edge = _field2d_color_string(edgecolor, who, "edgecolor")
	_field2d_nonnegative(edgewidth, who, "edgewidth")
	_field2d_nonnegative(linewidth, who, "linewidth")
	if triangle
		linewidth > 0 && throw(ArgumentError(
			"$(who): `linewidth` is the line width of arrows; outline style = " *
			":triangle glyphs with `edgewidth` (and `edgecolor`).",
		))
	elseif !isempty(edge) || edgewidth > 0
		throw(ArgumentError(
			"$(who): `edgecolor`/`edgewidth` outline style = :triangle glyphs; " *
			"arrows are lines (set their width with `linewidth`).",
		))
	end
	(opacity isa Real && !(opacity isa Bool) && isfinite(opacity) && 0 <= opacity <= 1) ||
		throw(ArgumentError(
			"$(who): `opacity` must be a number in [0, 1]; got $(repr(opacity)).",
		))
	return (
		style = style_value,
		pivot = pivot_value,
		scale = scale_value,
		headwidth = width_value,
		edgecolor = edge,
		edgewidth = Float64(edgewidth),
		linewidth = linewidth,
		opacity = Float64(opacity),
	)
end

# `colorby` of plot_quiver(!) (D13): `:none`, `:magnitude`, or an array with
# the shape of `u` (one value per vector, matched to the vectors as `u` is).
# Returns `:none`, `:magnitude` or the array.
function _quiver_colorby(colorby, u, who::AbstractString)
	if colorby isa Symbol || colorby isa AbstractString
		return _quiver_choice(colorby, (:none, :magnitude), who, "colorby")
	end
	colorby isa AbstractArray || throw(ArgumentError(
		"$(who): `colorby` must be :none, :magnitude or an array of values with " *
		"the shape of `u`; got $(typeof(colorby)).",
	))
	size(colorby) == size(u) || throw(ArgumentError(
		"$(who): a `colorby` array needs one value per vector, with the shape " *
		"of `u` $(size(u)); got size $(size(colorby)).",
	))
	return colorby
end

# A colour keyword passed to plot_quiver(!) without `colorby` is an error
# naming it (it would be silently ignored).
function _quiver_require_colorby(who::AbstractString; kwargs...)
	given = String[]
	for (name, value) in kwargs
		unset = name === :colorscale ? _is_unset_colorscale(value) :
			name === :crange ? _is_auto_range(value) :
			name === :colornorm ? (value === :linear || value == "linear") :
			name === :colorbar_title ? value == "" :
			name === :colorbar_title_side ? true :
			value === nothing
		unset || push!(given, "`$(name)`")
	end
	isempty(given) || throw(ArgumentError(
		"$(who): $(join(given, ", ")) $(length(given) == 1 ? "colours the glyphs by value and needs" :
			"colour the glyphs by value and need") `colorby` (:magnitude or an " *
		"array); got colorby = :none.",
	))
	return nothing
end

# One glyph trace: arrows are lines, triangles filled polygons. `colour = ""`
# leaves the colour to plotly.
function _quiver_glyph_trace(
	xs,
	ys,
	colour::AbstractString,
	glyph;
	name::AbstractString,
	showlegend::Bool,
	group::Union{Nothing, String},
)
	fields = Dict{Symbol, Any}(
		:x => xs,
		:y => ys,
		:mode => "lines",
		:hoverinfo => "skip",
		:name => name,
		:showlegend => showlegend,
	)
	if glyph.style === :triangle
		fields[:fill] = "toself"
		isempty(colour) || (fields[:fillcolor] = colour)
		# No outline by default; `simplify = false` keeps every vertex of
		# small triangles.
		line = Dict{Symbol, Any}(:width => glyph.edgewidth, :simplify => false)
		if !isempty(glyph.edgecolor)
			line[:color] = glyph.edgecolor
		elseif !isempty(colour)
			line[:color] = colour
		end
	else
		line = isempty(colour) ? Dict{Symbol, Any}() : Dict{Symbol, Any}(:color => colour)
		glyph.linewidth > 0 && (line[:width] = glyph.linewidth)
	end
	isempty(line) || (fields[:line] = attr(; line...))
	glyph.opacity < 1 && (fields[:opacity] = glyph.opacity)
	group === nothing || (fields[:legendgroup] = group)
	return scatter(; fields...)
end

# The traces of one quiver call: the glyphs in one trace (`colorby = :none`)
# or one trace per colour bin plus a colorbar carrier, all under one legend
# entry. Returns `(traces, colour_map)` (`nothing` without `colorby`).
function _quiver_traces(
	fig,
	x,
	y,
	u,
	v,
	who::AbstractString;
	colour::AbstractString,
	sizeref,
	legend::AbstractString,
	glyph,
	colorby,
	xlog::Bool,
	ylog::Bool,
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
)
	xp, yp, up, vp = _quiver_points(x, y, u, v, who)
	glyph_x, glyph_y, drawn = _quiver_coordinates(
		xp,
		yp,
		up,
		vp,
		sizeref;
		caller = who,
		xlog = xlog,
		ylog = ylog,
		style = glyph.style,
		pivot = glyph.pivot,
		scale = glyph.scale,
		headwidth = glyph.headwidth,
	)
	name = isempty(legend) ? "" : _label(legend)
	group = isempty(legend) ? nothing : "plotlysupply:quiver:" * name
	if colorby === :none
		trace = _quiver_glyph_trace(
			glyph_x,
			glyph_y,
			colour,
			glyph;
			name = name,
			# An unnamed quiver gets no "trace N" legend entry.
			showlegend = !isempty(legend),
			group = nothing,
		)
		return GenericTrace[trace], nothing
	end
	values = if colorby === :magnitude
		Float64[hypot(Float64(up[i]), Float64(vp[i])) for i in drawn]
	else
		flat = vec(colorby)
		Any[flat[i] for i in drawn]
	end
	cm = _mesh2d_colour(
		fig,
		_Mesh2dTarget(),
		values;
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
	bins, colours = _mesh2d_bins(cm, _QUIVER_COLOR_BINS)
	points = glyph.style === :triangle ? _QUIVER_TRIANGLE_POINTS : _QUIVER_ARROW_POINTS
	counts = zeros(Int, length(colours))
	for b in bins
		b > 0 && (counts[b] += 1)
	end
	bin_x = [Vector{Union{Nothing, Float64}}(undef, counts[b] * points) for b in eachindex(colours)]
	bin_y = [Vector{Union{Nothing, Float64}}(undef, counts[b] * points) for b in eachindex(colours)]
	filled = zeros(Int, length(colours))
	for (g, b) in enumerate(bins)
		b == 0 && continue
		source = ((g - 1) * points + 1):(g * points)
		target = (filled[b] + 1):(filled[b] + points)
		copyto!(bin_x[b], first(target), glyph_x, first(source), points)
		copyto!(bin_y[b], first(target), glyph_y, first(source), points)
		filled[b] += points
	end
	traces = GenericTrace[]
	for b in eachindex(colours)
		counts[b] == 0 && continue
		first_trace = isempty(traces)
		push!(
			traces,
			_quiver_glyph_trace(
				bin_x[b],
				bin_y[b],
				colours[b],
				glyph;
				name = first_trace ? name : "",
				showlegend = first_trace && !isempty(legend),
				group = group,
			),
		)
	end
	if isempty(traces)
		# Nothing to colour (no drawable vector, or no finite colour value):
		# keep one empty glyph trace, as without `colorby`.
		push!(
			traces,
			_quiver_glyph_trace(
				Union{Nothing, Float64}[],
				Union{Nothing, Float64}[],
				"",
				glyph;
				name = name,
				showlegend = !isempty(legend),
				group = group,
			),
		)
	end
	carrier = _mesh2d_carrier(cm, who)
	carrier === nothing || push!(traces, carrier)
	return traces, cm
end

function _quiver_add!(
	fig,
	who::AbstractString,
	x,
	y,
	u,
	v;
	constructor::Bool,
	color,
	sizeref,
	legend::AbstractString,
	linewidth,
	style = :arrow,
	pivot = nothing,
	scale = :magnitude,
	headwidth = nothing,
	edgecolor = "",
	edgewidth = 0,
	opacity = 1,
	colorby = :none,
	colorscale = "",
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	showscale = nothing,
	colorbar_title = "",
	colorbar_title_side = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
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
)
	xrange = _field2d_checked_range(xrange, who, "xrange")
	yrange = _field2d_checked_range(yrange, who, "yrange")
	_field2d_validate_cartesian(
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
	)
	glyph = _quiver_glyph_options(
		who;
		style = style,
		pivot = pivot,
		scale = scale,
		headwidth = headwidth,
		edgecolor = edgecolor,
		edgewidth = edgewidth,
		linewidth = linewidth,
		opacity = opacity,
	)
	colorby_value = _quiver_colorby(colorby, u, who)
	title_side = _field2d_title_side(colorbar_title_side, who)
	if colorby_value === :none
		_quiver_require_colorby(
			who;
			colorscale = colorscale,
			crange = crange,
			cmid = cmid,
			colornorm = colornorm,
			levels = levels,
			showscale = showscale,
			colorbar_title = colorbar_title,
			colorbar_ticks = colorbar_ticks,
			colorbar_ticklabels = colorbar_ticklabels,
			coloraxis = coloraxis,
		)
		colour = _field2d_color_string(color === nothing ? "RoyalBlue" : color, who, "color")
	else
		color === nothing || throw(ArgumentError(
			"$(who): `color` sets one colour for every glyph and conflicts with " *
			"`colorby` (the glyphs are coloured through `colorscale`).",
		))
		colour = ""
	end
	traces, cm = _quiver_traces(
		fig,
		x,
		y,
		u,
		v,
		who;
		colour = colour,
		sizeref = sizeref,
		legend = legend,
		glyph = glyph,
		colorby = colorby_value,
		xlog = _field2d_log_axis(fig, :x, xscale),
		ylog = _field2d_log_axis(fig, :y, yscale),
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
	)
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
	)
	# Arrows take the style's line width, never its dash/marker cycle;
	# triangles keep their own outline (none by default).
	_field2d_finish!(
		fig,
		first_new;
		coloraxis = cm === nothing ? nothing : cm.coloraxis,
		style = glyph.style === :arrow ? (:linewidth,) : (),
	)
	return nothing
end

"""
	plot_quiver(x, y, u, v; kwargs...)

Draw a 2-D vector field: one glyph per vector `(u, v)` at `(x, y)`, either an
arrow (`style = :arrow`, the default) or a filled triangle
(`style = :triangle`). Accepted forms:
- four vectors of equal length (one arrow per entry);
- four matrices of the same size (e.g. from `Y, X = meshgrid(y, x)`);
- coordinate vectors `x`, `y` with component matrices `u[ix, iy]`,
  `v[ix, iy]` of size `(length(x), length(y))`;
- otherwise vectors and matrices with one element count, paired element by
  element in column-major order (e.g. `X`, `Y` from `meshgrid` with `u = -Y[:]`).
Other sizes throw an `ArgumentError` (a transposed `u`, `v` is reported).

Glyph size is proportional to the magnitude `hypot(u, v)`: the longest glyph
is `2/3 * sizeref` long in x/y data units (on a log axis, in decades) and the
others are scaled by their magnitude relative to it, so `sizeref` is the
length budget of the strongest vector and does not depend on the units of
`u`, `v`. Set `sizeref` to about the grid spacing so neighbouring glyphs do
not overlap. An arrowhead is 0.3 of its shaft at ±20°; a triangle's base is
`headwidth` times its length, so its whole size follows the magnitude.
Glyphs are polygons in data units: they scale with the axes, and with
`equalar = true` they are not distorted. Vectors with a non-finite origin or
component are skipped with a warning; zero vectors draw nothing (a warning
when every vector is zero). On a logarithmic axis (`xscale`/`yscale =
"log"`) the glyphs are laid out in axis units (decades), pointing at angle
`atan(v, u)` with equal aspect (matplotlib's default `angles = "uv"`), and
origins must be positive.

[`plot_quiver3d`](@ref) is the 3-D counterpart: its `style = :cone` draws
solid cones (like `style = :triangle` here) and `style = :arrow` line arrows.

#### Keywords
Glyphs (lead decision D13):
- `style = :arrow`: `:arrow` (shaft and head, lines) or `:triangle` (one
  filled isosceles triangle per vector, pointing along `(u, v)`).
- `pivot = nothing`: the part of the glyph at `(x, y)`: `:tail`, `:middle` or
  `:tip` (matplotlib's `pivot`); `nothing` is `:tail` for arrows and
  `:middle` for triangles.
- `scale = :magnitude`: `:uniform` draws every non-zero vector at the full
  `2/3 * sizeref` length (a direction field; combine with
  `colorby = :magnitude` to show the strength by colour).
- `sizeref::Real = 1`: length budget of the longest glyph (see above); 0
  draws nothing; must be finite and ≥ 0.
- `headwidth = nothing`: triangle base width as a fraction of its length
  (> 0; default 0.5). Triangles only.
- `color = nothing`: one colour for every glyph (string, Symbol or Colorant;
  `nothing` is "RoyalBlue", `""` leaves it to plotly). Not with `colorby`.
- `linewidth::Real = 0`: arrow line width in pixels; `0` takes the active
  style's line width ([`with_style`](@ref)), else plotly's default. The
  style's dash/marker cycle is not applied to arrows. Arrows only.
- `edgecolor = ""`, `edgewidth::Real = 0`: triangle outline colour and width
  in pixels (default: no outline; `edgecolor = ""` with a width outlines in
  the fill colour). Triangles only.
- `opacity::Real = 1`: glyph opacity in [0, 1].
- `legend = ""`: legend name; one legend entry per call (an unnamed quiver
  has none).

Colour by value (`colorby`):
- `colorby = :none`: `:magnitude` colours each glyph by `hypot(u, v)`; an
  array with the shape of `u` gives one value per vector (NaN/`missing`
  values are not drawn). The glyphs are binned into $(_QUIVER_COLOR_BINS)
  colours (one trace per used colour) and a colorbar is added.
- `colorscale = ""` (template default), `crange = [0, 0]` (automatic: the
  values' extent), `cmid = nothing`, `colornorm = :linear` (`:log`),
  `levels = nothing` (discrete bands), `showscale = nothing`,
  `colorbar_title = ""` (mathtext), `colorbar_title_side = :top`,
  `colorbar_ticks = nothing`, `colorbar_ticklabels = nothing`,
  `coloraxis = nothing` (`:shared` or "coloraxisN"): as for
  [`plot_polygons`](@ref). They need `colorby`; passing one without it throws.

Axes and figure:
- `equalar::Bool = true`: equal data aspect, so glyph angles are true.
- `xlabel = ""`, `ylabel = ""`, `title = ""`, `xrange = [0, 0]`,
  `yrange = [0, 0]` (data units; `[0, 0]`/`nothing` automatic; a one-sided
  `(lo, nothing)`/`(nothing, hi)` fixes one bound; with the equal aspect the
  other is fixed at the current data extent, as plotly.js re-ranges an
  equal-aspect axis), `xscale = ""`,
  `yscale = ""`,
  `xticks`, `xticklabels`, `xtickformat`, `yticks`, `yticklabels`,
  `ytickformat`, `grid::Union{Nothing,Bool,Symbol} = true`, `width = 0`,
  `height = 0`, `fontsize = 0`: as for [`plot_heatmap`](@ref).
- `show::Bool = false`: open a window and return a `SyncPlot`.

Returns a `Plot` (a `SyncPlot` when `show = true`). Invalid input throws an
`ArgumentError`.

# Example
```julia
x = range(-1, 1; length = 9)
y = range(-1, 1; length = 7)
u = [-yi for xi in x, yi in y]                  # u[ix, iy]
v = [xi for xi in x, yi in y]
fig = plot_quiver(x, y, u, v; sizeref = 0.3, legend = "rotation")
# Direction by glyph, strength by colour:
fig2 = plot_quiver(x, y, u, v; style = :triangle, scale = :uniform,
	sizeref = 0.3, colorby = :magnitude, colorbar_title = "|v|")
```
"""
function plot_quiver(
	x::AbstractArray,
	y::AbstractArray,
	u::AbstractArray,
	v::AbstractArray;
	style = :arrow,
	pivot = nothing,
	scale = :magnitude,
	sizeref::Real = 1,
	headwidth = nothing,
	color = nothing,
	linewidth::Real = 0,
	edgecolor = "",
	edgewidth::Real = 0,
	opacity::Real = 1,
	legend::AbstractString = "",
	colorby = :none,
	colorscale = "",
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
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
	equalar::Bool = true,
	show::Bool = false,
)
	fig = _field2d_new_figure()
	_quiver_add!(
		fig,
		"plot_quiver",
		x,
		y,
		u,
		v;
		constructor = true,
		style = style,
		pivot = pivot,
		scale = scale,
		sizeref = sizeref,
		headwidth = headwidth,
		color = color,
		linewidth = linewidth,
		edgecolor = edgecolor,
		edgewidth = edgewidth,
		opacity = opacity,
		legend = legend,
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
	return _field2d_show(fig, show, width, height, title)
end

#endregion

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
- `row`, `col`, `inset = nothing` (`SubplotFigure` only): $(_SCAT_INSET_DOC)

Figure keywords only change what they name: labels, ranges, scales and ticks
apply to the primary axes (or the secondary y axis), `grid = nothing` (the
mutator default) keeps the current grid and `true`/`false`/`:x`/`:y`/`:both`/
`:none` set it, and a template set with `set_template!` is kept. On a
`SubplotFigure`, `title`, `width` and `height` are figure-level and are
ignored with a warning. Invalid input throws before the figure changes. The
appended traces continue the active style's dash/marker cycle.

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
	mode::Union{Nothing, AbstractString, AbstractVector} = nothing,
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
`Plot`/`SyncPlot`) and `row`/`col`/`inset` (`SubplotFigure` only: the target
cell, or inset `k` of [`inset!`](@ref)). `grid = nothing` keeps the current
grid; the legend groups of the new series never collide with those already in
the figure.

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

Append bar trace(s) to `fig`: a `Plot`, a [`SyncPlot`](@ref) or a
[`SubplotFigure`](@ref) cell. Data conventions and keywords are those of
[`plot_bar`](@ref) (including `orientation`, `barmode`, `error_x`/`error_y`,
`text`, `textposition`, `texttemplate`, `base`, `opacity`, `hatch`, per-bar
`color`, `barwidth`, `bargap`/`bargroupgap` and the tick keywords), with these
differences:
- `grid::Union{Nothing,Bool,Symbol} = nothing` leaves the grid unchanged; any
  other value (also `true`) is applied.
- `show` is not accepted (`ArgumentError`); display the figure instead.
- On a `SubplotFigure`, `row`/`col` select the cell (default: the current
  cell), `inset = k` draws on inset `k` (see [`inset!`](@ref)) and
  `secondary_y = true` targets the cell's secondary y axis; the axis keywords
  apply to those axes. `title`, `width` and `height` are figure-wide and are
  ignored there with a warning, and `barmode` (a single figure-wide plotly
  setting) applies to every cell, with one warning when it re-arranges bars
  already in other cells; `bargap`/`bargroupgap` are figure-wide as well.
- On a `Plot`/`SyncPlot`, `secondary_y = true` draws on a secondary y axis on
  the right, created on first use (`ylabel`, `yscale`, `yrange`, `yticks`,
  ... then apply to it). Plotly positions the bars of each y axis
  separately, so bars on the two axes at the same positions overlap (as with
  matplotlib's `twinx`); shift the positions and set `barwidth` to place them
  side by side. `row`, `col` and `inset` are not accepted there
  (`row = nothing`/`col = nothing`, no cell, are ignored).

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
	x::AbstractArray,
	y::AbstractArray;
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
	hatch::Union{AbstractString, AbstractVector} = "",
	barwidth = nothing,
	bargap = nothing,
	bargroupgap = nothing,
	kwargs...,
)
	secondary_y = _stats_mutator_options("plot_bar!", kwargs)
	_stats_bar!(
		fig,
		x,
		y,
		"plot_bar!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, orientation, barmode, error_x, error_y, text,
			textposition, texttemplate, base, opacity, hatch, barwidth, bargap,
			bargroupgap);
		mutator = true,
		secondary_y = secondary_y,
	)
	return nothing
end

function plot_bar!(
	fig,
	y::AbstractArray;
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
	hatch::Union{AbstractString, AbstractVector} = "",
	barwidth = nothing,
	bargap = nothing,
	bargroupgap = nothing,
	kwargs...,
)
	secondary_y = _stats_mutator_options("plot_bar!", kwargs)
	_stats_bar!(
		fig,
		nothing,
		y,
		"plot_bar!",
		(; xlabel, ylabel, title, xrange, yrange, xscale, yscale, width, height,
			fontsize, grid, xticks, xticklabels, xtickformat, yticks, yticklabels,
			ytickformat),
		(; color, legend, showlegend, orientation, barmode, error_x, error_y, text,
			textposition, texttemplate, base, opacity, hatch, barwidth, bargap,
			bargroupgap);
		mutator = true,
		secondary_y = secondary_y,
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
(grouped by default). An explicit `barmode` is figure-wide; on a
`SubplotFigure` it warns once when it re-arranges bars in other cells.
Differences from the constructor:
- `grid::Union{Nothing,Bool,Symbol} = nothing` leaves the grid unchanged; any
  other value (also `true`) is applied.
- `show` is not accepted (`ArgumentError`).
- On a `SubplotFigure`, `row`/`col` select the cell (default: the current
  cell), `inset = k` draws on inset `k` (see [`inset!`](@ref)) and
  `secondary_y = true` targets its secondary y axis; `title`, `width` and
  `height` are figure-wide and ignored there with a warning.
- On a `Plot`/`SyncPlot`, `secondary_y = true` draws on a secondary y axis on
  the right, created on first use (`ylabel`, `yscale`, `yrange`, `yticks`,
  ... then apply to it); `row`, `col` and `inset` are not accepted there
  (`row = nothing`/`col = nothing`, no cell, are ignored).

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
	x::AbstractArray;
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
	secondary_y = _stats_mutator_options("plot_histogram!", kwargs)
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
		secondary_y = secondary_y,
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
  cell), `inset = k` draws on inset `k` (see [`inset!`](@ref)) and
  `secondary_y = true` targets its secondary y axis; `title`, `width` and
  `height` are figure-wide and ignored there with a warning.
- On a `Plot`/`SyncPlot`, `secondary_y = true` draws on a secondary y axis on
  the right, created on first use (`ylabel`, `yscale`, `yrange`, `yticks`,
  ... then apply to it); `row`, `col` and `inset` are not accepted there
  (`row = nothing`/`col = nothing`, no cell, are ignored).

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
	x::AbstractArray,
	y::AbstractArray;
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
	secondary_y = _stats_mutator_options("plot_box!", kwargs)
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
		secondary_y = secondary_y,
	)
	return nothing
end

function plot_box!(
	fig,
	y::AbstractArray;
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
	secondary_y = _stats_mutator_options("plot_box!", kwargs)
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
		secondary_y = secondary_y,
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
  cell), `inset = k` draws on inset `k` (see [`inset!`](@ref)) and
  `secondary_y = true` targets its secondary y axis; `title`, `width` and
  `height` are figure-wide and ignored there with a warning.
- On a `Plot`/`SyncPlot`, `secondary_y = true` draws on a secondary y axis on
  the right, created on first use (`ylabel`, `yscale`, `yrange`, `yticks`,
  ... then apply to it); `row`, `col` and `inset` are not accepted there
  (`row = nothing`/`col = nothing`, no cell, are ignored).

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
	x::AbstractArray,
	y::AbstractArray;
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
	secondary_y = _stats_mutator_options("plot_violin!", kwargs)
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
		secondary_y = secondary_y,
	)
	return nothing
end

function plot_violin!(
	fig,
	y::AbstractArray;
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
	secondary_y = _stats_mutator_options("plot_violin!", kwargs)
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
		secondary_y = secondary_y,
	)
	return nothing
end

"""
	plot_scatterpolar!(fig, theta, r; kwargs...) -> nothing (SubplotFigure: the figure)

Append polar trace(s) to an existing `Plot`, [`SyncPlot`](@ref) or polar
`SubplotFigure` cell (`row`/`col`). Takes the data and every keyword of
[`plot_scatterpolar`](@ref) except `show` (an `ArgumentError`); `theta` is in
degrees unless `thetaunit = "radians"`. Options apply to the primary polar
subplot (`layout.polar`; a SubplotFigure maps it to the polar subplot of the
`row`/`col` cell); `grid = nothing` (the mutator default) keeps the current
grid and `true`/`false` set it. The radial label angle is set only where the
subplot has none yet (or with `rlabel_angle`, or when a new `trange` sector
excludes it), so an angle set earlier is kept. `secondary_y` and `inset`
(Cartesian axes) are rejected.

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
	mode::Union{Nothing, AbstractString, AbstractVector} = nothing,
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
	rlabel_angle::Union{Nothing, Real} = nothing,
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
		rlabel_angle = rlabel_angle,
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
	plot_heatmap!(fig, x, y, U; kwargs...)
	plot_heatmap!(fig, U; kwargs...)
	plot_heatmap!(sf::SubplotFigure, x, y, U; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)
	plot_heatmap!(sf::SubplotFigure, U; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)

Append a heatmap of `U` (indexed `U[ix, iy]`, `size(U) == (length(x),
length(y))` or cell edges) to `fig`, a `Plot` or `SyncPlot`, or to a cell of
a `SubplotFigure` (`row`/`col` together, default: the active cell;
`secondary_y` targets the cell's secondary y axis; `inset = k` targets the
`k`-th inset added with [`inset!`](@ref), and its parent cell becomes the
active cell). Implicit coordinates are 0-based, or 1-based when the target
x/y axis is (or is made) logarithmic.

Takes the keywords of [`plot_heatmap`](@ref) except `show` (passing `show`
throws an `ArgumentError`), with mutator defaults that leave the figure as it
is: `origin = ""` keeps the y-axis direction (`:upper`/`:lower` set it),
`grid = nothing` keeps the grid (`true` re-enables it), empty labels/titles,
automatic ranges and empty scales change nothing. The layout keywords act on
the primary axes of a `Plot`/`SyncPlot` and on the target cell's axes of a
`SubplotFigure`, where `title`, `width` and `height` are ignored with a
warning. `xrange`/`yrange` (data units, also on a log axis) set the target
axes' limits with autorange off, on a shared (`matches`) axis the limits of
its group; a one-sided limit `(lo, nothing)`/`(nothing, hi)` fixes one bound
and autoranges the other (on an equal-aspect axis the other is fixed at the
current data extent); `[0, 0]`/`nothing` leaves them as they are. A user
template is kept. `interpolation = :bilinear` smooths the heatmap (plotly
`zsmooth = "best"`).

Invalid input throws an `ArgumentError` and leaves the figure unchanged.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_heatmap(rand(4, 3))
plot_heatmap!(fig, 5:8, 0:2, rand(4, 3); colorscale = "viridis")
```
"""
function plot_heatmap!(
	fig,
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray;
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	levels = nothing,
	colorscale = "",
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
	text = nothing,
	texttemplate::AbstractString = "",
	textsize::Real = 0,
	origin::Union{Symbol, AbstractString} = "",
	xgap::Real = 0,
	ygap::Real = 0,
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
	tight = true,
	interpolation = :nearest,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	kwargs...,
)
	_field2d_reject_keywords("plot_heatmap!", kwargs)
	_heatmap_add!(
		fig,
		"plot_heatmap!",
		x,
		y,
		U;
		constructor = false,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		levels = levels,
		colorscale = colorscale,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
		text = text,
		texttemplate = texttemplate,
		textsize = textsize,
		origin = origin,
		xgap = xgap,
		ygap = ygap,
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
		tight = tight,
		interpolation = interpolation,
		xscale = xscale,
		yscale = yscale,
	)
	_refresh!(fig)
	return nothing
end

function plot_heatmap!(
	fig,
	U::AbstractArray;
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	kwargs...,
)
	x = _field2d_implicit_axis(size(U, 1), _field2d_log_axis(fig, :x, xscale))
	y = _field2d_implicit_axis(size(U, 2), _field2d_log_axis(fig, :y, yscale))
	return plot_heatmap!(fig, x, y, U; xscale = xscale, yscale = yscale, kwargs...)
end

"""
	plot_contour!(fig, x, y, U; kwargs...)
	plot_contour!(fig, U; kwargs...)
	plot_contour!(sf::SubplotFigure, x, y, U; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)
	plot_contour!(sf::SubplotFigure, U; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)

Append contours of `U` (indexed `U[ix, iy]`, `size(U) == (length(x),
length(y))`) to `fig`, a `Plot` or `SyncPlot`, or to a cell of a
`SubplotFigure` (`row`/`col` together, default: the active cell;
`secondary_y` targets the cell's secondary y axis; `inset = k` targets the
`k`-th inset from [`inset!`](@ref)). Implicit coordinates are 0-based, or
1-based when the target axis is logarithmic.

Takes the keywords of [`plot_contour`](@ref) except `show` (passing `show`
throws an `ArgumentError`); `grid = nothing` keeps the grid, and the other
layout keywords change nothing at their defaults. The overlay idiom draws
one labelled white level without a colorbar or legend entry:
`plot_contour!(fig, x, y, U; levels = [0.0], linecolor = "white",
showlabels = true)`. On a `SubplotFigure` the layout keywords act on the
target cell (`xrange`/`yrange` as for [`plot_heatmap!`](@ref)); `title`,
`width` and `height` are ignored with a warning.

Invalid input throws an `ArgumentError` and leaves the figure unchanged.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
x = range(-1, 1; length = 30)
U = [xi^2 + yi^2 for xi in x, yi in x]
fig = plot_heatmap(x, x, U)
plot_contour!(fig, x, x, U; levels = [0.25, 0.5], coloring = "none",
	linecolor = "black", showlabels = true)
```
"""
function plot_contour!(
	fig,
	x::AbstractArray,
	y::AbstractArray,
	U::AbstractArray;
	levels = nothing,
	ncontours::Integer = 0,
	coloring::Union{Symbol, AbstractString} = "",
	linecolor = "",
	linewidth::Real = 0,
	dash::Union{Symbol, AbstractString} = "",
	showlabels::Bool = false,
	labelformat::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	zrange = [0, 0],
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	colorscale = "",
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
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
	tight = true,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	kwargs...,
)
	_field2d_reject_keywords("plot_contour!", kwargs)
	_contour_add!(
		fig,
		"plot_contour!",
		x,
		y,
		U;
		constructor = false,
		levels = levels,
		ncontours = ncontours,
		coloring = coloring,
		linecolor = linecolor,
		linewidth = linewidth,
		dash = dash,
		showlabels = showlabels,
		labelformat = labelformat,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		crange = crange,
		cmid = cmid,
		colornorm = colornorm,
		colorscale = colorscale,
		showscale = showscale,
		colorbar_title = colorbar_title,
		colorbar_title_side = colorbar_title_side,
		colorbar_ticks = colorbar_ticks,
		colorbar_ticklabels = colorbar_ticklabels,
		coloraxis = coloraxis,
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
		tight = tight,
		xscale = xscale,
		yscale = yscale,
	)
	_refresh!(fig)
	return nothing
end

function plot_contour!(
	fig,
	U::AbstractArray;
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	kwargs...,
)
	x = _field2d_implicit_axis(size(U, 1), _field2d_log_axis(fig, :x, xscale))
	y = _field2d_implicit_axis(size(U, 2), _field2d_log_axis(fig, :y, yscale))
	return plot_contour!(fig, x, y, U; xscale = xscale, yscale = yscale, kwargs...)
end

"""
	plot_quiver!(fig, x, y, u, v; kwargs...)
	plot_quiver!(sf::SubplotFigure, x, y, u, v; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)

Append a vector field (same input forms, glyph kinds, scaling and keywords as
[`plot_quiver`](@ref): `style`, `pivot`, `scale`, `headwidth`, `colorby`
and the colour keywords, `edgecolor`, `edgewidth`, `opacity`; except
`show`, which throws an `ArgumentError`) to `fig`, a `Plot` or `SyncPlot`, or
to a cell of a `SubplotFigure` (`row`/`col` together, default: the active
cell; `secondary_y` targets the cell's secondary y axis; `inset = k` targets
the `k`-th inset from [`inset!`](@ref)). `xrange`/`yrange` act as for
[`plot_heatmap!`](@ref). `equalar = true` (default) locks the data aspect of
the target axes; `grid = nothing` keeps the grid (`true` re-enables it,
`false` hides it). Each call scales its own glyphs: the longest glyph of this
call is `2/3 * sizeref` long in x/y data units. Glyphs on an axis that is
already logarithmic are laid out in decades. On a `SubplotFigure`, `title`,
`width` and `height` are ignored with a warning.

Invalid input throws an `ArgumentError` and leaves the figure unchanged.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
x = range(0, 1; length = 6)
fig = plot_heatmap(x, x, [xi * yi for xi in x, yi in x])
plot_quiver!(fig, x, x, [yi for xi in x, yi in x], [-xi for xi in x, yi in x];
	color = "white", sizeref = 0.2, legend = "flow")
```
"""
function plot_quiver!(
	fig,
	x::AbstractArray,
	y::AbstractArray,
	u::AbstractArray,
	v::AbstractArray;
	style = :arrow,
	pivot = nothing,
	scale = :magnitude,
	sizeref::Real = 1,
	headwidth = nothing,
	color = nothing,
	linewidth::Real = 0,
	edgecolor = "",
	edgewidth::Real = 0,
	opacity::Real = 1,
	legend::AbstractString = "",
	colorby = :none,
	colorscale = "",
	crange = [0, 0],
	cmid::Union{Nothing, Real} = nothing,
	colornorm::Union{Symbol, AbstractString} = :linear,
	levels = nothing,
	showscale::Union{Nothing, Bool} = nothing,
	colorbar_title::AbstractString = "",
	colorbar_title_side::Union{Symbol, AbstractString} = :top,
	colorbar_ticks = nothing,
	colorbar_ticklabels = nothing,
	coloraxis = nothing,
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
	equalar::Bool = true,
	kwargs...,
)
	_field2d_reject_keywords("plot_quiver!", kwargs)
	_quiver_add!(
		fig,
		"plot_quiver!",
		x,
		y,
		u,
		v;
		constructor = false,
		style = style,
		pivot = pivot,
		scale = scale,
		sizeref = sizeref,
		headwidth = headwidth,
		color = color,
		linewidth = linewidth,
		edgecolor = edgecolor,
		edgewidth = edgewidth,
		opacity = opacity,
		legend = legend,
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
	_refresh!(fig)
	return nothing
end

#endregion

"""
	set_template!(fig, template = get_default_template())
	set_template!(sf::SubplotFigure, template = get_default_template())

Apply a Plotly template to an existing figure, in place.

# Arguments
- `fig`: a `PlotlyBase.Plot`, a [`SyncPlot`](@ref) or a
  [`SubplotFigure`](@ref) (the template is figure-wide, so a SubplotFigure
  takes no `row`/`col`).
- `template`: a registered template name (`String` or `Symbol`, e.g.
  `"plotly_white"`, `:plotly_dark`, `"ggplot2"`, `"seaborn"`,
  `"simple_white"`, `"presentation"`; surrounding whitespace is ignored and
  names may be combined with `+`, e.g. `"plotly_dark+xgridoff"`), or a
  `PlotlyBase.Template` object. Defaults to the package-wide default template
  ([`get_default_template`](@ref), initially `:plotly_white`; see
  [`set_default_template!`](@ref)). An unrecognised name warns and falls back
  to `:plotly_white`; any other type throws an `ArgumentError`.

# Template-derived colours
PlotlySupply draws axis spines, tick marks and the default legend box in
colours derived from the template: black spines and a translucent white
legend on light templates, the template's light text colour and a
translucent dark legend on dark templates such as `plotly_dark`. When the
template changes, every value that still equals the colour derived from the
previous template is re-derived for the new one: `linecolor`/`tickcolor` of
every `xaxis*`/`yaxis*`, `bgcolor`/`bordercolor` of every `legend*` (and, on a
`SubplotFigure`, the stored legend colours used for legends added later),
`layout.font.color` and a single-colour `layout.colorway` (the `:bw` style
cycle). Colours you set yourself (e.g. `linecolor = "red"`) are kept, and
nothing else (spines, ticks, fonts, sizes) is changed.

The call takes no keyword arguments (an `ArgumentError` names any that are
passed, `show` included). It validates the template before changing anything
and is atomic. Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a
`SubplotFigure`.

# Example
```julia
fig = plot_scatter(1:10, (1:10) .^ 2; legend = "n²")
set_template!(fig, "plotly_dark")   # dark background, light frame and legend
set_template!(fig)                  # back to the default template

sf = subplots(1, 2; sync = false)
plot_scatter!(sf, 1:3, [1, 2, 3])
set_template!(sf, :ggplot2)         # returns sf
```
"""
function set_template!(fig, template = get_default_template(); kwargs...)
	_require_no_set_template_keywords(kwargs)
	chosen = _resolve_template(template; who = "set_template!")
	_apply_template_change!(fig, chosen)
	_refresh!(fig)
	return nothing
end

function _require_no_set_template_keywords(kwargs)
	isempty(kwargs) && return nothing
	names = join(("`$(k)`" for k in keys(kwargs)), ", ")
	hint = haskey(kwargs, :show) ? " (mutators do not take `show`)" : ""
	throw(ArgumentError(
		"set_template!: unsupported keyword argument(s) $(names)$(hint); " *
		"set_template! takes only the figure and the template.",
	))
end

# Spine/tick ink and legend box colours derived from a figure's current
# template; a figure without a (usable) template counts as the 1.x light look.
_set_template_old_ink(old) = old === nothing ? _DEFAULT_AXIS_LINECOLOR : _template_ink(old)
_set_template_old_legend(old) = old === nothing ?
	(bgcolor = _DEFAULT_LEGEND_BGCOLOR[], bordercolor = _DEFAULT_LEGEND_BORDERCOLOR[]) :
	_template_legend_colors(old)

# Every layout value derived from the figure's current template that must be
# re-derived for `chosen`, as `relayout!` keyword pairs. Only values that still
# equal the derived colour of the current template are listed, so colours set
# by the caller survive.
function _template_change_updates(layout::PlotlyBase.Layout, chosen::PlotlyBase.Template)
	old = _figure_template(layout)
	old_ink = _set_template_old_ink(old)
	old_legend = _set_template_old_legend(old)
	new_ink = _template_ink(chosen)
	new_legend = _template_legend_colors(chosen)
	updates = Pair{Symbol, Any}[]
	function rederive!(key, field, old_value, new_value, container)
		isequal(old_value, new_value) && return nothing
		isequal(get(container, field, nothing), old_value) || return nothing
		push!(updates, Symbol(key, "_", field) => new_value)
		return nothing
	end
	for key in sort!(collect(keys(layout.fields)); by = String)
		name = String(key)
		if occursin(r"^[xy]axis\d*$", name)
			axis = _symbol_dict(layout.fields[key])
			rederive!(name, :linecolor, old_ink, new_ink, axis)
			rederive!(name, :tickcolor, old_ink, new_ink, axis)
		elseif occursin(r"^legend\d*$", name)
			legend = _symbol_dict(layout.fields[key])
			rederive!(name, :bgcolor, old_legend.bgcolor, new_legend.bgcolor, legend)
			rederive!(name, :bordercolor, old_legend.bordercolor, new_legend.bordercolor, legend)
		end
	end
	rederive!("font", :color, old_ink, new_ink, _symbol_dict(get(layout.fields, :font, nothing)))
	colorway = get(layout.fields, :colorway, nothing)
	if colorway isa AbstractVector && length(colorway) == 1 &&
	   isequal(colorway[1], old_ink) && !isequal(old_ink, new_ink)
		push!(updates, :colorway => [new_ink])
	end
	return updates
end

function _apply_template_change!(fig, chosen::PlotlyBase.Template)
	updates = _template_change_updates(_plot_layout(fig), chosen)
	relayout!(fig; template = chosen, updates...)
	return nothing
end

function _set_template_subplot_impl!(sf::SubplotFigure, chosen::PlotlyBase.Template)
	old_legend = _set_template_old_legend(_figure_template(_plot_layout(sf.fig)))
	new_legend = _template_legend_colors(chosen)
	# The stored legend colours style every per-cell legend added later.
	isequal(sf.legend_bgcolor, old_legend.bgcolor) &&
		(sf.legend_bgcolor = new_legend.bgcolor)
	isequal(sf.legend_bordercolor, old_legend.bordercolor) &&
		(sf.legend_bordercolor = new_legend.bordercolor)
	_apply_template_change!(sf.fig, chosen)
	_refresh!(sf.fig)
	return sf
end

function set_template!(sf::SubplotFigure, template = get_default_template(); kwargs...)
	_require_no_set_template_keywords(kwargs)
	# Resolve (and so validate) before the transaction starts.
	chosen = _resolve_template(template; who = "set_template!")
	return _transactional_subplot_mutation!(
		_set_template_subplot_impl!,
		sf,
		_SUBPLOT_LEGEND_METADATA_FIELDS,
		chosen,
	)
end

#region Extended chart types

# Open a window for the freshly-built figure when `show=true`, otherwise return
# the `Plot`. `to_syncplot` validates the window options and maps the
# constructor sentinels `0` (width/height) and `""` (title) to its defaults
# (960 × 720 px, "PlotlySupply"). The window title is the plain `title` text.
_maybe_show(fig, show::Bool, width::Real, height::Real, title::AbstractString) =
	show ? to_syncplot(fig; width = width, height = height, title = title) : fig

# Lightweight layout options for non-Cartesian charts (pie, sankey, sunburst, …)
# that have no x/y axes to style, written through the D7 figure-option
# primitives: every option is validated before the first write (errors name
# `who`), the title is stored as `title.text` through `_label`, and an
# explicit `fontsize` is applied after the template so it wins over the
# style's base size. On first construction the default template (and active
# style) is applied; on append (`apply_template=false`) only the legend is
# refreshed so a user-set template survives.
function _apply_basic_plot_options!(
	fig;
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	apply_template::Bool = true,
	who::AbstractString = "plot",
)
	_require_size_option(width, who, "width")
	_require_size_option(height, who, "height")
	_require_size_option(fontsize, who, "fontsize")
	# The title is the first write, so a label `_label` rejects throws before
	# anything has changed.
	_apply_figure_title!(fig, title)
	_apply_figure_size!(fig, who; width = width, height = height)
	if apply_template
		_apply_default_template!(fig)
	else
		# A legend first created by an append gets the box that matches the
		# figure's own template (dark on plotly_dark), not the light default.
		_apply_default_legend!(fig; _figure_legend_defaults(fig)...)
	end
	_apply_figure_fontsize!(fig, who, fontsize)
	return nothing
end

# ── Extended chart helpers ───────────────────────────────────────────
#
# Shared by the extended charts below (pie, funnelarea, sunburst, treemap,
# funnel, waterfall, indicator, candlestick, ohlc, sankey, parcoords,
# ternary) and by `annotate!`. The checks only read their inputs, so a
# builder can validate everything before the first write. Errors are
# `ArgumentError("<who>: …")`, where `who` is the public function name.

# Mutators never open a window, and `row`/`col` address a SubplotFigure cell:
# the SubplotFigure methods take them out before calling the mutator, so on a
# single figure they are an error.
function _extended_mutator_guard(who::AbstractString, show, row, col)
	show === nothing || throw(ArgumentError(
		"$(who): mutators do not take `show` (they never open a window); " *
		"display the figure with `to_syncplot(fig)`, or pass `show = true` " *
		"to the constructor.",
	))
	(row === nothing && col === nothing) || throw(ArgumentError(
		"$(who): `row`/`col` select a SubplotFigure cell; a single figure " *
		"has one cell, so omit them.",
	))
	return nothing
end

# The Cartesian mutators take `secondary_y` for SubplotFigure cells (the
# SubplotFigure method routes it to the cell's secondary y axis).
function _extended_secondary_y_guard(who::AbstractString, secondary_y::Bool)
	secondary_y && throw(ArgumentError(
		"$(who): `secondary_y = true` addresses the secondary y axis of a " *
		"SubplotFigure cell created with `specs = Spec(secondary_y = true)`; " *
		"it is not available on a single figure.",
	))
	return nothing
end

# A user label through the mathtext pipeline (text plotly typesets: titles,
# axis titles, legend names, ternary axis titles, annotations).
function _extended_label(
	text::AbstractString,
	who::AbstractString,
	name::AbstractString;
	align::Symbol = :c,
)
	try
		return _label(text; align = align)
	catch err
		err isa ArgumentError || rethrow()
		throw(ArgumentError("$(who): `$(name)`: $(err.msg)"))
	end
end

# The same for text plotly draws without MathJax (`data-notex`: slice labels
# of pie/funnelarea/sunburst/treemap, sankey node labels) and for parcoords
# dimension labels (see `_parcoords_dim`).
function _extended_plain_label(
	text::AbstractString,
	who::AbstractString,
	name::AbstractString,
)
	try
		return _label_plain(text)
	catch err
		err isa ArgumentError || rethrow()
		throw(ArgumentError("$(who): `$(name)`: $(err.msg)"))
	end
end

# `_label_plain` changes only strings that contain a `$` or a line break;
# every other character passes through verbatim.
_extended_needs_plain(value) =
	value isa AbstractString &&
	(occursin('$', value) || occursin('\n', value) || occursin('\r', value))

# Data labels drawn without MathJax. Labels with math or line breaks are
# converted with `_label_plain`; otherwise the caller's array is returned
# unchanged (not copied), so large payloads stay shared.
function _extended_plain_labels(
	labels::AbstractVector,
	who::AbstractString,
	name::AbstractString,
)
	any(_extended_needs_plain, labels) || return labels
	converted = Vector{Any}(undef, length(labels))
	for (position, value) in enumerate(labels)
		converted[position] = _extended_needs_plain(value) ?
			_extended_plain_label(value, who, "$(name)[$(position)]") :
			value
	end
	return converted
end

_extended_is_real(value) = value isa Real && !(value isa Bool)

_extended_is_gap(value) =
	value === missing ||
	value === nothing ||
	(value isa AbstractFloat && isnan(value))

# Element checks for numeric data arrays. Every element must be a finite real
# number (Bool is rejected). `gaps = true` also admits `missing`, `nothing`
# and NaN (drawn as gaps); `numeric_strings = true` admits strings that parse
# as numbers (plotly coerces them); `nonnegative`, `positive` (log axes) and
# `integer` (node indices) add the obvious constraints.
function _extended_check_numbers(
	who::AbstractString,
	name::AbstractString,
	values;
	nonnegative::Bool = false,
	positive::Bool = false,
	integer::Bool = false,
	gaps::Bool = false,
	numeric_strings::Bool = false,
)
	for (position, raw) in enumerate(values)
		gaps && _extended_is_gap(raw) && continue
		value = raw
		if numeric_strings && raw isa AbstractString
			parsed = tryparse(Float64, raw)
			parsed === nothing && throw(ArgumentError(
				"$(who): `$(name)[$(position)]` must be a number; got $(repr(raw)).",
			))
			value = parsed
		end
		_extended_is_real(value) || throw(ArgumentError(
			"$(who): `$(name)[$(position)]` must be a real number; got " *
			"$(repr(raw))" *
			(gaps ? " (mark missing values with `missing`, `nothing` or NaN)." : "."),
		))
		isfinite(value) || throw(ArgumentError(
			"$(who): `$(name)[$(position)]` must be finite; got $(repr(raw)).",
		))
		nonnegative && value < 0 && throw(ArgumentError(
			"$(who): `$(name)[$(position)]` must be non-negative; got $(repr(raw)).",
		))
		positive && value <= 0 && throw(ArgumentError(
			"$(who): `$(name)[$(position)]` is on a logarithmic axis and must be " *
			"positive; got $(repr(raw)).",
		))
		integer && !isinteger(value) && throw(ArgumentError(
			"$(who): `$(name)[$(position)]` must be an integer index; got $(repr(raw)).",
		))
	end
	return nothing
end

function _extended_check_number(who::AbstractString, name::AbstractString, value)
	(_extended_is_real(value) && isfinite(value)) || throw(ArgumentError(
		"$(who): `$(name)` must be a finite real number; got $(repr(value)).",
	))
	return value
end

# Data arguments also admit array views for dispatch compatibility with the
# 1.x signatures; anything but a vector is an error.
function _extended_require_vector(who::AbstractString, name::AbstractString, values)
	ndims(values) == 1 || throw(ArgumentError(
		"$(who): `$(name)` must be a vector; got a $(ndims(values))-dimensional " *
		"$(typeof(values)) (use `vec(...)` to flatten it).",
	))
	return nothing
end

# A chart needs at least one data element: plotly.js draws an empty trace
# without any message, which hides a caller's bug.
function _extended_require_nonempty(who::AbstractString, name::AbstractString, values)
	isempty(values) && throw(ArgumentError(
		"$(who): `$(name)` is empty; pass at least one value.",
	))
	return nothing
end

function _extended_check_length(
	who::AbstractString,
	name::AbstractString,
	values,
	reference_name::AbstractString,
	n::Integer,
)
	length(values) == n || throw(ArgumentError(
		"$(who): `$(name)` must have one entry per element of " *
		"`$(reference_name)` ($(n)); got $(length(values)).",
	))
	return nothing
end

_extended_is_colour(value) = value isa AbstractString || value isa Symbol

# One colour keyword: a String or Symbol (`""` = unset), passed through to
# plotly as a String.
function _extended_colour(who::AbstractString, name::AbstractString, value)
	_extended_is_colour(value) || throw(ArgumentError(
		"$(who): `$(name)` must be a colour string or Symbol; got $(repr(value)).",
	))
	return String(value)
end

# A per-element colour array of length `n`: colour strings/Symbols, and real
# numbers when `numbers = true` (plotly maps those through a colorscale).
# Returned unchanged unless Symbols have to become Strings.
function _extended_colour_vector(
	who::AbstractString,
	name::AbstractString,
	colors::AbstractVector,
	n::Integer,
	reference_name::AbstractString;
	numbers::Bool = false,
)
	_extended_check_length(who, name, colors, reference_name, n)
	for (position, value) in enumerate(colors)
		(_extended_is_colour(value) ||
		 (numbers && _extended_is_real(value) && isfinite(value))) ||
			throw(ArgumentError(
				"$(who): `$(name)[$(position)]` must be a colour string or Symbol" *
				(numbers ? " or a finite number" : "") * "; got $(repr(value)).",
			))
	end
	any(value -> value isa Symbol, colors) || return colors
	return Any[value isa Symbol ? String(value) : value for value in colors]
end

# `width`, `height` and `fontsize` of the charts without Cartesian axes.
function _extended_validate_sizes(who::AbstractString; width, height, fontsize)
	_require_size_option(width, who, "width")
	_require_size_option(height, who, "height")
	_require_size_option(fontsize, who, "fontsize")
	return nothing
end

# Common options of the charts without Cartesian axes. `title` is already a
# `_label` result. A constructor applies the default template; a mutator only
# refreshes the legend, so a user template survives.
function _extended_apply_figure_options!(
	fig,
	who::AbstractString;
	title::AbstractString,
	width,
	height,
	fontsize,
	apply_template::Bool,
)
	_apply_figure_title!(fig, title)
	_apply_figure_size!(fig, who; width = width, height = height)
	apply_template ? _apply_default_template!(fig) : _apply_default_legend!(fig)
	_apply_figure_fontsize!(fig, who, fontsize)
	return nothing
end

# Open a window for a freshly built figure when `show = true` (960×720 and
# the title "PlotlySupply" when width/height/title are unset).
_extended_maybe_show(fig, show::Bool, width::Real, height::Real, title::AbstractString) =
	show ?
	to_syncplot(
		fig;
		width = width > 0 ? width : 960,
		height = height > 0 ? height : 720,
		title = isempty(title) ? "PlotlySupply" : title,
	) :
	fig

# Spine-styled Cartesian layout without a stored title (titles are written by
# `_apply_figure_title!` as `title.text`).
function _extended_cartesian_layout()
	layout = _default_cartesian_layout()
	get(layout.fields, :title, nothing) == "" && delete!(layout.fields, :title)
	return layout
end

# Validated (`_label`led) title and axis labels of a Cartesian chart.
_extended_cartesian_labels(who::AbstractString; title, xlabel, ylabel) = (
	title = _extended_label(title, who, "title"),
	xlabel = _extended_label(xlabel, who, "xlabel"),
	ylabel = _extended_label(ylabel, who, "ylabel"),
)

# Constructor of a Cartesian chart: one trace, spine-styled axes, then the
# common options through the D7 primitives (validated before any write).
# `reveal_x_axis` shows an x axis plotly hides by default (the value axis of
# a horizontal funnel) when the caller gave it a title.
function _extended_cartesian_plot(
	who::AbstractString,
	trace;
	labels,
	raw_title::AbstractString,
	xrange,
	yrange,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width,
	height,
	fontsize,
	grid,
	show::Bool,
	reveal_x_axis::Bool = false,
)
	fig = Plot(trace, _extended_cartesian_layout())
	_apply_cartesian_plot_options!(
		fig;
		xlabel = labels.xlabel,
		ylabel = labels.ylabel,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		grid = grid,
		fontsize = fontsize,
		title = labels.title,
		who = who,
	)
	reveal_x_axis && relayout!(fig, xaxis_visible = true)
	return _extended_maybe_show(fig, show, width, height, raw_title)
end

# Mutator of a Cartesian chart: every option is validated before the trace
# is appended; `grid = nothing` leaves the grid as it is, any other value is
# applied (so `grid = true` re-enables a hidden grid).
function _extended_cartesian_append!(
	fig,
	who::AbstractString,
	trace;
	labels,
	xrange,
	yrange,
	xscale::AbstractString = "",
	yscale::AbstractString = "",
	width,
	height,
	fontsize,
	grid,
	reveal_x_axis::Bool = false,
)
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
	push!(_plot_data(fig), trace)
	_apply_axis_grid!(fig, grid, who)
	reveal_x_axis && relayout!(fig, xaxis_visible = true)
	_apply_cartesian_plot_options!(
		fig;
		xlabel = labels.xlabel,
		ylabel = labels.ylabel,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		grid = nothing,
		fontsize = fontsize,
		title = labels.title,
		refresh = true,
		apply_template = false,
		who = who,
	)
	return nothing
end

# Axis type a Cartesian mutator will draw on: the requested scale, otherwise
# the figure's current primary-axis type.
_extended_final_axis_type(fig, key::Symbol, scale::AbstractString) =
	isempty(scale) ? _axis_type(fig, key) : String(scale)

# ── Pie / funnel-area ────────────────────────────────────────────────

# Trace of the slice charts (`pie`, `funnelarea`). Validates everything, then
# stores the caller's arrays without copying them.
function _pie_trace(
	constructor,
	who::AbstractString,
	values::AbstractVector;
	labels,
	colors,
	hole = 0,
)
	_extended_require_nonempty(who, "values", values)
	_extended_check_numbers(who, "values", values; nonnegative = true, numeric_strings = true)
	(_extended_is_real(hole) && isfinite(hole) && 0 <= hole < 1) || throw(ArgumentError(
		"$(who): `hole` must be a number in [0, 1) (the hole radius as a " *
		"fraction of the pie radius); got $(repr(hole)).",
	))
	n = length(values)
	kw = Dict{Symbol, Any}(:values => values)
	if labels !== nothing
		_extended_check_length(who, "labels", labels, "values", n)
		kw[:labels] = _extended_plain_labels(labels, who, "labels")
	end
	if colors !== nothing && !isempty(colors)
		kw[:marker] = attr(colors = _extended_colour_vector(who, "colors", colors, n, "values"))
	end
	hole > 0 && (kw[:hole] = hole)
	return constructor(; kw...)
end

function _extended_slice_plot(
	constructor,
	who::AbstractString,
	values::AbstractVector;
	labels,
	colors,
	hole = 0,
	title::AbstractString,
	width,
	height,
	fontsize,
	show::Bool,
)
	trace = _pie_trace(constructor, who, values; labels = labels, colors = colors, hole = hole)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	fig = Plot(trace, Layout())
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = true,
	)
	return _extended_maybe_show(fig, show, width, height, title)
end

function _extended_slice_append!(
	fig,
	constructor,
	who::AbstractString,
	values::AbstractVector;
	labels,
	colors,
	hole = 0,
	title::AbstractString,
	width,
	height,
	fontsize,
)
	trace = _pie_trace(constructor, who, values; labels = labels, colors = colors, hole = hole)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	push!(_plot_data(fig), trace)
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	_refresh!(fig)
	return nothing
end

"""
	plot_pie(values; labels=nothing, hole=0, colors=nothing, title="", width=0,
		height=0, fontsize=0, show=false)

Pie chart of `values`, or a donut chart when `hole > 0`. Each value is one
slice whose angle is proportional to it.

# Arguments
- `values::AbstractVector`: non-negative finite numbers (numeric strings are
  accepted, as plotly coerces them). The array is stored without copying.

# Keywords
- `labels::Union{Nothing,AbstractVector} = nothing`: one label per slice
  (default: the indices `0, 1, …`). Plotly sums slices that share a label.
  Slice text is drawn without MathJax, so a label containing `\$…\$` math is
  converted to Unicode with sub/superscripts (`"\$\\alpha\$"` → `"α"`); an odd
  number of unescaped `\$` is an `ArgumentError` (write `\\\$` for a dollar sign).
- `hole::Real = 0`: radius of the donut hole as a fraction of the pie radius,
  in `[0, 1)`.
- `colors::Union{Nothing,AbstractVector} = nothing`: one colour (String or
  Symbol) per slice; `nothing` or an empty vector uses the template colorway.
- `title::AbstractString = ""`: figure title (mathtext, see `mathtext`).
- `width::Real = 0`, `height::Real = 0`: figure size in px (`0` = automatic).
- `fontsize::Real = 0`: global font size in px (`0` = template default).
- `show::Bool = false`: open an Electron window and return a `SyncPlot`.

Lengths that differ from `length(values)`, negative or non-finite values and
a `hole` outside `[0, 1)` throw an `ArgumentError`.

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_pie([45, 30, 25]; labels = ["Solar", "Wind", "Hydro"], hole = 0.4,
	title = "Energy mix")
```
"""
function plot_pie(
	values::AbstractVector;
	labels::Union{Nothing, AbstractVector} = nothing,
	hole::Real = 0,
	colors::Union{Nothing, AbstractVector} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	return _extended_slice_plot(
		pie,
		"plot_pie",
		values;
		labels = labels,
		colors = colors,
		hole = hole,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		show = show,
	)
end

"""
	plot_pie!(fig, values; labels=nothing, hole=0, colors=nothing, title="",
		width=0, height=0, fontsize=0)
	plot_pie!(sf::SubplotFigure, values; row=nothing, col=nothing, kwargs...)

Append a pie/donut trace to `fig` (a `Plot` or `SyncPlot`). The keywords are
those of [`plot_pie`](@ref) without `show` (passing `show` throws an
`ArgumentError`); a non-empty `title` and non-zero `width`/`height`/`fontsize`
update the figure, and the template is left as it is. Several pies in one
figure overlap unless their `domain` is set; use a SubplotFigure instead.

On a `SubplotFigure` the trace goes to the `domain` cell `row`, `col` (both or
neither; default: the active cell), which becomes the active cell; `title`,
`width` and `height` are figure-level there and are ignored with a warning.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
sf = subplots(1, 2; sync = false, specs = [Spec(kind = "domain") Spec(kind = "domain")])
plot_pie!(sf, [3, 2, 1]; labels = ["a", "b", "c"], row = 1, col = 1)
plot_pie!(sf, [1, 1]; labels = ["x", "y"], hole = 0.5, row = 1, col = 2)
```
"""
function plot_pie!(
	fig,
	values::AbstractVector;
	labels::Union{Nothing, AbstractVector} = nothing,
	hole::Real = 0,
	colors::Union{Nothing, AbstractVector} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_pie!"
	_extended_mutator_guard(who, show, row, col)
	return _extended_slice_append!(
		fig,
		pie,
		who,
		values;
		labels = labels,
		colors = colors,
		hole = hole,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
end

function plot_pie!(
	sf::SubplotFigure,
	values::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_pie!, values; row = row, col = col, kwargs...)
end

# ── Sunburst / Treemap (hierarchical) ────────────────────────────────

const _EXTENDED_BRANCHVALUES = ("remainder", "total")

function _extended_first_duplicate(values)
	seen = Set{Any}()
	for value in values
		value in seen && return value
		push!(seen, value)
	end
	return nothing
end

# Trace of the hierarchical charts. Without `ids`, plotly identifies a sector
# by its label, so labels must be unique (a repeated label would silently
# merge two branches). When labels contain math they are converted for
# display and the original labels become the `ids`, so `parents` still
# refers to them.
function _hierarchy_trace(
	constructor,
	who::AbstractString,
	labels::AbstractVector,
	parents::AbstractVector;
	values,
	colors,
	colorscale,
	ids,
	branchvalues,
)
	_extended_require_nonempty(who, "labels", labels)
	n = length(labels)
	_extended_check_length(who, "parents", parents, "labels", n)
	if ids === nothing
		if !allunique(labels)
			duplicate = _extended_first_duplicate(labels)
			throw(ArgumentError(
				"$(who): `labels` contains $(repr(duplicate)) more than once; plotly " *
				"identifies sectors by label, so the repeated sectors would be merged " *
				"and one branch dropped. Pass unique `ids` (with `parents` referring " *
				"to ids) to repeat a label.",
			))
		end
	else
		ids isa AbstractVector || throw(ArgumentError(
			"$(who): `ids` must be a vector with one unique id per label; got $(typeof(ids)).",
		))
		_extended_check_length(who, "ids", ids, "labels", n)
		for (position, id) in enumerate(ids)
			valid = (id isa AbstractString && !isempty(id)) ||
				id isa Symbol ||
				(_extended_is_real(id) && isfinite(id))
			valid || throw(ArgumentError(
				"$(who): `ids[$(position)]` must be a non-empty string, a Symbol or a " *
				"finite number (\"\" marks a root in `parents`); got $(repr(id)).",
			))
		end
		if !allunique(ids)
			duplicate = _extended_first_duplicate(ids)
			throw(ArgumentError("$(who): `ids` must be unique; $(repr(duplicate)) appears more than once."))
		end
	end
	if values !== nothing
		_extended_check_length(who, "values", values, "labels", n)
		_extended_check_numbers(who, "values", values; nonnegative = true, numeric_strings = true)
	end
	checked_colors = colors === nothing ? nothing :
		_extended_colour_vector(who, "colors", colors, n, "labels"; numbers = true)
	branch = String(branchvalues)
	(isempty(branch) || branch in _EXTENDED_BRANCHVALUES) || throw(ArgumentError(
		"$(who): `branchvalues` must be \"remainder\", \"total\" or \"\" (plotly " *
		"default, \"remainder\"); got $(repr(branchvalues)).",
	))
	scale = _resolve_colorscale(colorscale; who = who).scale
	display_labels = _extended_plain_labels(labels, who, "labels")

	kw = Dict{Symbol, Any}(:labels => display_labels, :parents => parents)
	if ids !== nothing
		kw[:ids] = ids
	elseif display_labels !== labels
		kw[:ids] = labels
	end
	values === nothing || (kw[:values] = values)
	isempty(branch) || (kw[:branchvalues] = branch)
	marker = Dict{Symbol, Any}()
	checked_colors === nothing || (marker[:colors] = checked_colors)
	if !(scale isa AbstractString && isempty(scale))
		# A colorscale colours the sectors by `values` unless explicit
		# `colors` are given (without either array plotly ignores it).
		checked_colors === nothing && values !== nothing && (marker[:colors] = values)
		marker[:colorscale] = scale
	end
	isempty(marker) || (kw[:marker] = attr(; marker...))
	return constructor(; kw...)
end

function _extended_hierarchy_plot(
	constructor,
	who::AbstractString,
	labels::AbstractVector,
	parents::AbstractVector;
	values,
	colors,
	colorscale,
	ids,
	branchvalues,
	title::AbstractString,
	width,
	height,
	fontsize,
	show::Bool,
)
	trace = _hierarchy_trace(
		constructor,
		who,
		labels,
		parents;
		values = values,
		colors = colors,
		colorscale = colorscale,
		ids = ids,
		branchvalues = branchvalues,
	)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	fig = Plot(trace, Layout())
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = true,
	)
	return _extended_maybe_show(fig, show, width, height, title)
end

function _extended_hierarchy_append!(
	fig,
	constructor,
	who::AbstractString,
	labels::AbstractVector,
	parents::AbstractVector;
	values,
	colors,
	colorscale,
	ids,
	branchvalues,
	title::AbstractString,
	width,
	height,
	fontsize,
)
	trace = _hierarchy_trace(
		constructor,
		who,
		labels,
		parents;
		values = values,
		colors = colors,
		colorscale = colorscale,
		ids = ids,
		branchvalues = branchvalues,
	)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	push!(_plot_data(fig), trace)
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	_refresh!(fig)
	return nothing
end

"""
	plot_sunburst(labels, parents; values=nothing, colors=nothing, colorscale="",
		ids=nothing, branchvalues="", title="", width=0, height=0, fontsize=0,
		show=false)

Hierarchical sunburst chart: rings of sectors, the root in the centre.

# Arguments
- `labels::AbstractVector`: the text of each sector. Without `ids` the labels
  identify the sectors, so they must be unique (a repeated label throws an
  `ArgumentError`; plotly would merge the two sectors and drop a branch).
  Drawn without MathJax: `\$…\$` math is converted to Unicode (the original
  labels then serve as ids).
- `parents::AbstractVector`: for each sector, the label (or id, when `ids` is
  given) of its parent; `""` marks a root.

# Keywords
- `values::Union{Nothing,AbstractVector} = nothing`: non-negative sector
  sizes (numeric strings accepted). With the plotly default
  `branchvalues = "remainder"` a parent's value is added to the sum of its
  children; with `"total"` it is the total of its subtree (and must be at
  least the sum of its children). Without values every leaf counts once.
- `colors::Union{Nothing,AbstractVector} = nothing`: one colour (String or
  Symbol) or number (mapped through `colorscale`) per sector.
- `colorscale = ""`: a colormap name (matplotlib/plotly.py orientation,
  case-insensitive, `_r` reverses; unknown names throw), a vector of colours or
  `(t, colour)` stops, or a `ColorScheme`. With `values` and no `colors` the
  sectors are coloured by `values`; `""` keeps the colorway.
- `ids::Union{Nothing,AbstractVector} = nothing`: unique sector ids (non-empty
  strings, Symbols or numbers). Use them to repeat a label in different
  branches, e.g. `labels = ["2023", "2024", "Q1", "Q1"]`,
  `ids = ["2023", "2024", "2023/Q1", "2024/Q1"]`,
  `parents = ["", "", "2023", "2024"]`.
- `branchvalues::Union{AbstractString,Symbol} = ""`: `"remainder"`, `"total"`
  or `""` (plotly default, `"remainder"`).
- `title::AbstractString = ""`, `width::Real = 0`, `height::Real = 0`,
  `fontsize::Real = 0`, `show::Bool = false`: as for [`plot_pie`](@ref).

All arrays must have `length(labels)` entries. The caller's arrays are stored
without copying (unless labels with math have to be converted).

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
The label "Other" appears in two branches, so the sectors get `ids` and
`parents` refers to those ids:
```julia
fig = plot_sunburst(
	["Physics", "Chemistry", "Optics", "Other", "Other"],
	["", "", "P", "P", "C"];
	ids = ["P", "C", "P/optics", "P/other", "C/other"],
	values = [0, 0, 4, 2, 3],
	colorscale = "viridis",
)
```
"""
function plot_sunburst(
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	colorscale = "",
	ids::Union{Nothing, AbstractVector} = nothing,
	branchvalues::Union{AbstractString, Symbol} = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	return _extended_hierarchy_plot(
		sunburst,
		"plot_sunburst",
		labels,
		parents;
		values = values,
		colors = colors,
		colorscale = colorscale,
		ids = ids,
		branchvalues = branchvalues,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		show = show,
	)
end

"""
	plot_sunburst!(fig, labels, parents; values=nothing, colors=nothing,
		colorscale="", ids=nothing, branchvalues="", title="", width=0,
		height=0, fontsize=0)
	plot_sunburst!(sf::SubplotFigure, labels, parents; row=nothing, col=nothing, kwargs...)

Append a sunburst trace to `fig` (`Plot`/`SyncPlot`), or to the `domain` cell
`row`, `col` of a `SubplotFigure` (default: the active cell). Arguments and
keywords as for [`plot_sunburst`](@ref) without `show` (an `ArgumentError`);
see [`plot_pie!`](@ref) for the figure-level options.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = Plot()
plot_sunburst!(fig, ["root", "a", "b"], ["", "root", "root"]; values = [0, 2, 1])
```
"""
function plot_sunburst!(
	fig,
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	colorscale = "",
	ids::Union{Nothing, AbstractVector} = nothing,
	branchvalues::Union{AbstractString, Symbol} = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_sunburst!"
	_extended_mutator_guard(who, show, row, col)
	return _extended_hierarchy_append!(
		fig,
		sunburst,
		who,
		labels,
		parents;
		values = values,
		colors = colors,
		colorscale = colorscale,
		ids = ids,
		branchvalues = branchvalues,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
end

function plot_sunburst!(
	sf::SubplotFigure,
	labels::AbstractVector,
	parents::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_sunburst!, labels, parents; row = row, col = col, kwargs...)
end

"""
	plot_treemap(labels, parents; values=nothing, colors=nothing, colorscale="",
		ids=nothing, branchvalues="", title="", width=0, height=0, fontsize=0,
		show=false)

Hierarchical treemap: nested rectangles whose areas follow `values`. The
arguments, the `labels`/`parents`/`ids` convention and every keyword are those
of [`plot_sunburst`](@ref).

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
Each year has quarters "Q1" and "Q2", so the sectors get `ids`; `parents`
refers to ids:
```julia
fig = plot_treemap(
	["2023", "2024", "Q1", "Q2", "Q1", "Q2"],
	["", "", "2023", "2023", "2024", "2024"];
	ids = ["2023", "2024", "2023/Q1", "2023/Q2", "2024/Q1", "2024/Q2"],
	values = [0, 0, 1, 2, 3, 4],
)
```
"""
function plot_treemap(
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	colorscale = "",
	ids::Union{Nothing, AbstractVector} = nothing,
	branchvalues::Union{AbstractString, Symbol} = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	return _extended_hierarchy_plot(
		treemap,
		"plot_treemap",
		labels,
		parents;
		values = values,
		colors = colors,
		colorscale = colorscale,
		ids = ids,
		branchvalues = branchvalues,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		show = show,
	)
end

"""
	plot_treemap!(fig, labels, parents; values=nothing, colors=nothing,
		colorscale="", ids=nothing, branchvalues="", title="", width=0,
		height=0, fontsize=0)
	plot_treemap!(sf::SubplotFigure, labels, parents; row=nothing, col=nothing, kwargs...)

Append a treemap trace to `fig` (`Plot`/`SyncPlot`), or to the `domain` cell
`row`, `col` of a `SubplotFigure` (default: the active cell). Arguments and
keywords as for [`plot_sunburst`](@ref) without `show` (an `ArgumentError`);
see [`plot_pie!`](@ref) for the figure-level options.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = Plot()
plot_treemap!(fig, ["root", "a", "b"], ["", "root", "root"]; values = [0, 2, 1])
```
"""
function plot_treemap!(
	fig,
	labels::AbstractVector,
	parents::AbstractVector;
	values::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	colorscale = "",
	ids::Union{Nothing, AbstractVector} = nothing,
	branchvalues::Union{AbstractString, Symbol} = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_treemap!"
	_extended_mutator_guard(who, show, row, col)
	return _extended_hierarchy_append!(
		fig,
		treemap,
		who,
		labels,
		parents;
		values = values,
		colors = colors,
		colorscale = colorscale,
		ids = ids,
		branchvalues = branchvalues,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
end

function plot_treemap!(
	sf::SubplotFigure,
	labels::AbstractVector,
	parents::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_treemap!, labels, parents; row = row, col = col, kwargs...)
end

# ── Funnel ───────────────────────────────────────────────────────────

# Funnel bars are centred on zero, so the value axis (x) cannot be
# logarithmic; stage labels go on the y axis.
function _extended_funnel_trace(who::AbstractString, x, y; color, legend::AbstractString)
	_extended_require_vector(who, "x", x)
	_extended_require_vector(who, "y", y)
	_extended_require_nonempty(who, "x", x)
	n = length(x)
	_extended_check_length(who, "y", y, "x", n)
	_extended_check_numbers(who, "x", x)
	kw = Dict{Symbol, Any}(:x => x, :y => y)
	if color isa AbstractVector
		isempty(color) ||
			(kw[:marker] = attr(color = _extended_colour_vector(who, "color", color, n, "x")))
	else
		colour = _extended_colour(who, "color", color)
		isempty(colour) || (kw[:marker] = attr(color = colour))
	end
	name = _extended_label(legend, who, "legend")
	isempty(name) || (kw[:name] = name)
	return funnel(; kw...)
end

# Funnel and waterfall bars start at zero, which a log value axis cannot show.
# `fig` is the target figure, or the delegate's staging figure seeded with the
# target cell's, secondary-y or inset axes, so the message names no target.
function _extended_require_linear_value_axis(fig, who::AbstractString, key::Symbol, what::AbstractString)
	_axis_type(fig, key) == "log" && throw(ArgumentError(
		"$(who): the $(what) axis is logarithmic, but $(what) bars start at " *
		"zero; use a linear axis.",
	))
	return nothing
end

"""
	plot_funnel(x, y; color="", legend="", xlabel="", ylabel="", xrange=[0, 0],
		yrange=[0, 0], title="", width=0, height=0, fontsize=0, grid=true,
		show=false)

Funnel chart: one horizontal bar per stage, centred on zero, with width
`x[i]`, labelled by `y[i]` on the y axis (top to bottom in the given order).

# Arguments
- `x::AbstractVector`: stage values (finite real numbers).
- `y::AbstractVector`: stage labels (categories), same length as `x`.

# Keywords
- `color::Union{AbstractString,Symbol,AbstractVector} = ""`: bar colour, or
  one colour per stage (`""` = colorway).
- `legend::AbstractString = ""`: legend name of the trace (mathtext).
- `xlabel`, `ylabel::AbstractString = ""`: axis titles (mathtext). Plotly
  hides the value (x) axis of a funnel; a non-empty `xlabel` shows it.
- `xrange`, `yrange = [0, 0]`: axis ranges as a 2-element vector or tuple in
  data units; `[0, 0]` (or `nothing`) means automatic.
- `title::AbstractString = ""`: figure title (mathtext).
- `width::Real = 0`, `height::Real = 0`: figure size in px (`0` = automatic).
- `fontsize::Real = 0`: global font size in px (`0` = template default).
- `grid::Union{Bool,Symbol} = true`: `true` keeps the template grid; `false`
  or `:none` hides it, `:x`/`:y`/`:both` choose the axes with grid lines.
- `show::Bool = false`: open an Electron window and return a `SyncPlot`.

The value axis cannot be logarithmic (the bars are centred on zero).
Mismatched lengths and non-numeric or non-finite values throw an `ArgumentError`.

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_funnel([1200, 640, 210, 48], ["Visits", "Sign-ups", "Trials", "Sales"];
	xlabel = "Users", title = "Conversion")
```
"""
function plot_funnel(
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray};
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Bool, Symbol} = true,
	show::Bool = false,
)
	who = "plot_funnel"
	trace = _extended_funnel_trace(who, x, y; color = color, legend = legend)
	labels = _extended_cartesian_labels(who; title = title, xlabel = xlabel, ylabel = ylabel)
	return _extended_cartesian_plot(
		who,
		trace;
		labels = labels,
		raw_title = title,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		show = show,
		reveal_x_axis = !isempty(labels.xlabel),
	)
end

"""
	plot_funnel!(fig, x, y; color="", legend="", xlabel="", ylabel="",
		xrange=[0, 0], yrange=[0, 0], title="", width=0, height=0, fontsize=0,
		grid=nothing)
	plot_funnel!(sf::SubplotFigure, x, y; row=nothing, col=nothing, secondary_y=false,
		inset=nothing, kwargs...)

Append a funnel trace to `fig` (`Plot`/`SyncPlot`). Arguments and keywords as
for [`plot_funnel`](@ref) without `show` (an `ArgumentError`); only non-default
options change the figure, `grid = nothing` keeps the current grid and any other
value is applied, and the template is left as it is. The figure's x axis must
not be logarithmic.

On a `SubplotFigure` the trace goes to the `xy` cell `row`, `col` (both or
neither; default: the active cell; `secondary_y = true` draws against the
cell's secondary y axis), or to inset `inset` (an id returned by
[`inset!`](@ref); with `row`/`col` they must name the inset's cell); that cell
becomes the active cell. Axis options apply to the cell's (or inset's) axes,
`title`/`width`/`height` are ignored with a warning, and the target x axis
must not be logarithmic. `secondary_y` on a single figure, and `inset`
together with `secondary_y`, are an `ArgumentError`.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_funnel([100, 60, 30], ["A", "B", "C"]; legend = "2023")
plot_funnel!(fig, [90, 70, 40], ["A", "B", "C"]; legend = "2024")
```
"""
function plot_funnel!(
	fig,
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray};
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	secondary_y::Bool = false,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_funnel!"
	_extended_mutator_guard(who, show, row, col)
	_extended_secondary_y_guard(who, secondary_y)
	trace = _extended_funnel_trace(who, x, y; color = color, legend = legend)
	labels = _extended_cartesian_labels(who; title = title, xlabel = xlabel, ylabel = ylabel)
	_extended_require_linear_value_axis(fig, who, :xaxis, "funnel (x)")
	return _extended_cartesian_append!(
		fig,
		who,
		trace;
		labels = labels,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		reveal_x_axis = !isempty(labels.xlabel),
	)
end

function plot_funnel!(
	sf::SubplotFigure,
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	# The delegate seeds the staging figure with the target axes' types (cell,
	# secondary y or inset), so the Plot method's log-axis check sees them.
	return _subplot_delegate_mutator!(
		sf,
		plot_funnel!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		kwargs...,
	)
end

"""
	plot_funnelarea(values; labels=nothing, colors=nothing, title="", width=0,
		height=0, fontsize=0, show=false)

Funnel-area chart: stacked trapezoids whose areas are proportional to
`values`, top to bottom in the given order.

# Arguments
- `values::AbstractVector`: non-negative finite numbers (numeric strings are
  accepted). Stored without copying.

# Keywords
- `labels::Union{Nothing,AbstractVector} = nothing`: one label per stage
  (default: indices). Drawn without MathJax: `\$…\$` math becomes Unicode, as
  for [`plot_pie`](@ref).
- `colors::Union{Nothing,AbstractVector} = nothing`: one colour (String or
  Symbol) per stage; `nothing`/empty uses the colorway.
- `title::AbstractString = ""`, `width::Real = 0`, `height::Real = 0`,
  `fontsize::Real = 0`, `show::Bool = false`: as for [`plot_pie`](@ref).

Mismatched lengths and negative or non-finite values throw an `ArgumentError`.

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_funnelarea([120, 60, 25, 8]; labels = ["Visits", "Sign-ups", "Trials", "Sales"])
```
"""
function plot_funnelarea(
	values::AbstractVector;
	labels::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	return _extended_slice_plot(
		funnelarea,
		"plot_funnelarea",
		values;
		labels = labels,
		colors = colors,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		show = show,
	)
end

"""
	plot_funnelarea!(fig, values; labels=nothing, colors=nothing, title="",
		width=0, height=0, fontsize=0)
	plot_funnelarea!(sf::SubplotFigure, values; row=nothing, col=nothing, kwargs...)

Append a funnel-area trace to `fig` (`Plot`/`SyncPlot`), or to the `domain`
cell `row`, `col` of a `SubplotFigure` (default: the active cell). Keywords as
for [`plot_funnelarea`](@ref) without `show` (an `ArgumentError`); see
[`plot_pie!`](@ref) for the figure-level options.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = Plot()
plot_funnelarea!(fig, [5, 3, 1]; labels = ["x", "y", "z"])
```
"""
function plot_funnelarea!(
	fig,
	values::AbstractVector;
	labels::Union{Nothing, AbstractVector} = nothing,
	colors::Union{Nothing, AbstractVector} = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_funnelarea!"
	_extended_mutator_guard(who, show, row, col)
	return _extended_slice_append!(
		fig,
		funnelarea,
		who,
		values;
		labels = labels,
		colors = colors,
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
end

function plot_funnelarea!(
	sf::SubplotFigure,
	values::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_funnelarea!, values; row = row, col = col, kwargs...)
end

# ── Waterfall ────────────────────────────────────────────────────────

const _EXTENDED_WATERFALL_MEASURES = ("relative", "total", "absolute")

_extended_measure_name(measure) =
	measure isa Symbol ? String(measure) :
	measure isa AbstractString ? measure :
	nothing

function _waterfall_trace(
	who::AbstractString,
	x,
	y;
	measure,
	legend::AbstractString,
)
	_extended_require_vector(who, "x", x)
	_extended_require_vector(who, "y", y)
	_extended_require_nonempty(who, "x", x)
	n = length(x)
	_extended_check_length(who, "y", y, "x", n)
	if measure === nothing
		_extended_check_numbers(who, "y", y)
	else
		_extended_check_length(who, "measure", measure, "y", n)
		for (position, (value, step)) in enumerate(zip(y, measure))
			name = _extended_measure_name(step)
			(name !== nothing && name in _EXTENDED_WATERFALL_MEASURES) || throw(ArgumentError(
				"$(who): `measure[$(position)]` must be \"relative\", \"total\" or " *
				"\"absolute\"; got $(repr(step)).",
			))
			# plotly computes a "total" bar from the running sum and ignores
			# its y value, so a placeholder (`missing`, NaN, 0) is fine there.
			if name == "total"
				(_extended_is_gap(value) || _extended_is_real(value)) || throw(ArgumentError(
					"$(who): `y[$(position)]` (a \"total\") must be a number or a " *
					"placeholder (`missing`, `nothing`, NaN); got $(repr(value)).",
				))
			else
				(_extended_is_real(value) && isfinite(value)) || throw(ArgumentError(
					"$(who): `y[$(position)]` must be a finite real number; got $(repr(value)).",
				))
			end
		end
	end
	kw = Dict{Symbol, Any}(:x => x, :y => y)
	if measure !== nothing
		kw[:measure] = any(step -> step isa Symbol, measure) ?
			String[_extended_measure_name(step) for step in measure] :
			measure
	end
	name = _extended_label(legend, who, "legend")
	isempty(name) || (kw[:name] = name)
	return waterfall(; kw...)
end

"""
	plot_waterfall(x, y; measure=nothing, legend="", xlabel="", ylabel="",
		xrange=[0, 0], yrange=[0, 0], title="", width=0, height=0, fontsize=0,
		grid=true, show=false)

Waterfall chart: a running total built from the increments `y`, one bar per
category `x`.

# Arguments
- `x::AbstractVector`: bar positions or categories.
- `y::AbstractVector`: increments (finite real numbers), same length as `x`.

# Keywords
- `measure::Union{Nothing,AbstractVector} = nothing`: one of `"relative"`
  (add `y[i]`), `"absolute"` (reset the total to `y[i]`) or `"total"` (draw the
  running total; its `y` value is ignored and may be `missing`/NaN) per bar,
  as Strings or Symbols; `nothing` means all relative.
- `legend::AbstractString = ""`: legend name of the trace (mathtext).
- `xlabel`, `ylabel`, `xrange`, `yrange`, `title`, `width`, `height`,
  `fontsize`, `grid`, `show`: as for [`plot_funnel`](@ref).

The y axis cannot be logarithmic (the bars start at zero). Mismatched lengths,
unknown measures and non-finite increments throw an `ArgumentError`.

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_waterfall(["Revenue", "Costs", "Tax", "Profit"], [120, -70, -15, 0];
	measure = ["absolute", "relative", "relative", "total"], ylabel = "k€")
```
"""
function plot_waterfall(
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray};
	measure::Union{Nothing, AbstractVector} = nothing,
	legend::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Bool, Symbol} = true,
	show::Bool = false,
)
	who = "plot_waterfall"
	trace = _waterfall_trace(who, x, y; measure = measure, legend = legend)
	labels = _extended_cartesian_labels(who; title = title, xlabel = xlabel, ylabel = ylabel)
	return _extended_cartesian_plot(
		who,
		trace;
		labels = labels,
		raw_title = title,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		show = show,
	)
end

"""
	plot_waterfall!(fig, x, y; measure=nothing, legend="", xlabel="", ylabel="",
		xrange=[0, 0], yrange=[0, 0], title="", width=0, height=0, fontsize=0,
		grid=nothing)
	plot_waterfall!(sf::SubplotFigure, x, y; row=nothing, col=nothing, secondary_y=false,
		inset=nothing, kwargs...)

Append a waterfall trace to `fig` (`Plot`/`SyncPlot`), or to the `xy` cell
`row`, `col` of a `SubplotFigure`. Arguments and keywords as for
[`plot_waterfall`](@ref) without `show` (an `ArgumentError`); `grid = nothing`
keeps the current grid and `grid = true` re-enables a hidden one. See
[`plot_funnel!`](@ref) for the SubplotFigure, `inset` and `secondary_y`
rules. The figure's (cell's, inset's) y axis must not be logarithmic.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_waterfall(["a", "b"], [1, 2]; grid = false)
plot_waterfall!(fig, ["a", "b"], [2, -1]; grid = true)
```
"""
function plot_waterfall!(
	fig,
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray};
	measure::Union{Nothing, AbstractVector} = nothing,
	legend::AbstractString = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	grid::Union{Nothing, Bool, Symbol} = nothing,
	secondary_y::Bool = false,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_waterfall!"
	_extended_mutator_guard(who, show, row, col)
	_extended_secondary_y_guard(who, secondary_y)
	trace = _waterfall_trace(who, x, y; measure = measure, legend = legend)
	labels = _extended_cartesian_labels(who; title = title, xlabel = xlabel, ylabel = ylabel)
	_extended_require_linear_value_axis(fig, who, :yaxis, "waterfall (y)")
	return _extended_cartesian_append!(
		fig,
		who,
		trace;
		labels = labels,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
	)
end

function plot_waterfall!(
	sf::SubplotFigure,
	x::Union{AbstractVector, SubArray},
	y::Union{AbstractVector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	# The delegate seeds the staging figure with the target axes' types (cell,
	# secondary y or inset), so the Plot method's log-axis check sees them.
	return _subplot_delegate_mutator!(
		sf,
		plot_waterfall!,
		x,
		y;
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		kwargs...,
	)
end

# ── Indicator (number / gauge / delta) ───────────────────────────────

const _EXTENDED_INDICATOR_FLAGS = ("number", "delta", "gauge")
const _EXTENDED_GAUGE_SHAPES = ("angular", "bullet")

# The plotly `mode` flag list. A `reference` adds "delta" and a gauge request
# (`gauge_range` or `gauge_shape`) adds "gauge", so neither is silently
# ignored; "delta" without a reference (plotly would draw a meaningless zero
# change) is an error.
function _extended_indicator_mode(
	who::AbstractString,
	mode::AbstractString,
	reference,
	gauge_requested::Bool,
)
	flags = String[]
	for part in split(mode, '+')
		flag = String(strip(part))
		flag in _EXTENDED_INDICATOR_FLAGS || throw(ArgumentError(
			"$(who): `mode` must combine \"number\", \"delta\" and \"gauge\" with " *
			"\"+\" (e.g. \"number+gauge\"); got $(repr(mode)).",
		))
		flag in flags && throw(ArgumentError(
			"$(who): `mode` lists $(repr(flag)) twice; got $(repr(mode)).",
		))
		push!(flags, flag)
	end
	reference === nothing || "delta" in flags || push!(flags, "delta")
	gauge_requested && !("gauge" in flags) && push!(flags, "gauge")
	reference === nothing && "delta" in flags && throw(ArgumentError(
		"$(who): `mode` includes \"delta\" but no `reference` was given; the " *
		"delta is `value - reference`.",
	))
	return join(flags, "+")
end

function _indicator_trace(
	who::AbstractString,
	value;
	mode::AbstractString,
	reference,
	gauge_range,
	gauge_shape::AbstractString,
	number_suffix::AbstractString,
)
	_extended_check_number(who, "value", value)
	reference === nothing || _extended_check_number(who, "reference", reference)
	axis_range = nothing
	if gauge_range !== nothing
		(gauge_range isa AbstractVector || gauge_range isa Tuple) || throw(ArgumentError(
			"$(who): `gauge_range` must be a 2-element vector or tuple (lo, hi); " *
			"got $(typeof(gauge_range)).",
		))
		length(gauge_range) == 2 || throw(ArgumentError(
			"$(who): `gauge_range` must have exactly 2 elements (lo, hi), e.g. " *
			"[0, 100] — not a range such as 0:100; got $(length(gauge_range)) elements.",
		))
		lower, upper = first(gauge_range), last(gauge_range)
		(_extended_is_real(lower) && _extended_is_real(upper) &&
		 isfinite(lower) && isfinite(upper) && lower < upper) || throw(ArgumentError(
			"$(who): `gauge_range` must be two finite numbers lo < hi; got $(repr(gauge_range)).",
		))
		axis_range = Any[lower, upper]
	end
	shape = String(gauge_shape)
	(isempty(shape) || shape in _EXTENDED_GAUGE_SHAPES) || throw(ArgumentError(
		"$(who): `gauge_shape` must be \"angular\", \"bullet\" or \"\"; got $(repr(gauge_shape)).",
	))
	resolved_mode = _extended_indicator_mode(
		who,
		mode,
		reference,
		gauge_range !== nothing || !isempty(shape),
	)
	kw = Dict{Symbol, Any}(:mode => resolved_mode, :value => value)
	reference === nothing || (kw[:delta] = attr(reference = reference))
	if occursin("gauge", resolved_mode)
		gauge = Dict{Symbol, Any}(:shape => isempty(shape) ? "angular" : shape)
		axis_range === nothing || (gauge[:axis] = attr(range = axis_range))
		kw[:gauge] = attr(; gauge...)
	end
	isempty(number_suffix) || (kw[:number] = attr(suffix = String(number_suffix)))
	return indicator(; kw...)
end

"""
	plot_indicator(value; mode="number", reference=nothing, gauge_range=nothing,
		gauge_shape="", number_suffix="", title="", width=0, height=0,
		fontsize=0, show=false)

KPI indicator showing `value` as a big number, optionally with the change
relative to a `reference` (delta) and a gauge.

# Arguments
- `value::Real`: the finite number to display.

# Keywords
- `mode::AbstractString = "number"`: `"number"`, `"delta"` and `"gauge"`
  combined with `+`. A `reference` adds `"delta"` and `gauge_range`/
  `gauge_shape` add `"gauge"` automatically; `"delta"` without a `reference`
  is an `ArgumentError`.
- `reference::Union{Nothing,Real} = nothing`: reference value; the delta shows
  `value - reference`.
- `gauge_range = nothing`: gauge axis range as a 2-element vector or tuple
  `(lo, hi)` with `lo < hi` (a range such as `0:100` is rejected); `nothing`
  lets plotly choose.
- `gauge_shape::AbstractString = ""`: `"angular"` (default when a gauge is
  drawn) or `"bullet"` (a horizontal bar).
- `number_suffix::AbstractString = ""`: text appended to the number (e.g.
  `"%"`), drawn verbatim.
- `title::AbstractString = ""`: figure title (mathtext).
- `width::Real = 0`, `height::Real = 0`, `fontsize::Real = 0`,
  `show::Bool = false`: as for [`plot_pie`](@ref).

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_indicator(72; reference = 65, gauge_range = (0, 100), number_suffix = "%",
	title = "Availability")
```
"""
function plot_indicator(
	value::Real;
	mode::AbstractString = "number",
	reference::Union{Nothing, Real} = nothing,
	gauge_range = nothing,
	gauge_shape::AbstractString = "",
	number_suffix::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	who = "plot_indicator"
	trace = _indicator_trace(
		who,
		value;
		mode = mode,
		reference = reference,
		gauge_range = gauge_range,
		gauge_shape = gauge_shape,
		number_suffix = number_suffix,
	)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	fig = Plot(trace, Layout())
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = true,
	)
	return _extended_maybe_show(fig, show, width, height, title)
end

function plot_indicator!(
	sf::SubplotFigure,
	value::Real;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_indicator!, value; row = row, col = col, kwargs...)
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
	mode::Union{Nothing, AbstractString} = nothing,
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
	trace_mode = _scat_mode(something(mode, "lines"), who)
	xrange = _scat_range_arg(xrange)
	yrange = _scat_range_arg(yrange)
	styles = _scat_series_styles(
		n,
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

	legend_state = _scat_legend_state(fig)
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
	# The outline takes the active style's line width; a filled area takes no
	# dash or marker cycle (as matplotlib's fill_between/stackplot).
	_scat_apply_style!(fig, (length(data) - n + 1):length(data); explicit = _SCAT_STYLE_WIDTH_ONLY)
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
	_scat_place_legend!(fig, legend_state)
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
- `mode = nothing`: trace mode (`"lines+markers"`, ...); `nothing` or `""`
  means `"lines"`.
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
  for [`plot_scatter`](@ref) (ranges in data units with the semantics of
  `xrange!`, tick presets `:decades`/`:auto`, `grid = true` keeps the
  template grid).

The outline takes the active [`PlotStyle`](@ref)'s line width; areas take no
dash or marker cycle. A legend created on a figure with stacked areas stays
at the default corner.

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
	mode::Union{Nothing, AbstractString} = nothing,
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
`row`/`col`/`inset` (`SubplotFigure` only: the target cell, or inset `k` of
[`inset!`](@ref)). `grid = nothing` keeps the current grid. With
`stack = true` the new series stack on the earlier `stack = true` areas of the
same axes.
"""
function plot_area!(
	fig,
	x::AbstractArray,
	y::AbstractArray;
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::Union{AbstractString, AbstractVector} = "",
	mode::Union{Nothing, AbstractString} = nothing,
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

# Price columns of a candlestick/OHLC trace. Gaps (`missing`, `nothing`,
# NaN) are allowed, so non-trading days can be skipped; on a logarithmic
# price axis the prices must be positive.
function _ohlc_trace(
	constructor,
	who::AbstractString,
	x,
	open,
	high,
	low,
	close;
	increasing_color,
	decreasing_color,
	legend::AbstractString,
	log_x::Bool,
	log_y::Bool,
)
	_extended_require_vector(who, "x", x)
	_extended_require_nonempty(who, "x", x)
	n = length(x)
	for (name, values) in (("open", open), ("high", high), ("low", low), ("close", close))
		_extended_require_vector(who, name, values)
		_extended_check_length(who, name, values, "x", n)
		_extended_check_numbers(who, name, values; gaps = true, positive = log_y)
	end
	log_x && _extended_check_numbers(who, "x", x; positive = true)
	increasing = _extended_colour(who, "increasing_color", increasing_color)
	decreasing = _extended_colour(who, "decreasing_color", decreasing_color)
	name = _extended_label(legend, who, "legend")
	kw = Dict{Symbol, Any}(:x => x, :open => open, :high => high, :low => low, :close => close)
	isempty(increasing) || (kw[:increasing] = attr(line = attr(color = increasing)))
	isempty(decreasing) || (kw[:decreasing] = attr(line = attr(color = decreasing)))
	isempty(name) || (kw[:name] = name)
	return constructor(; kw...)
end

function _extended_ohlc_plot(
	constructor,
	who::AbstractString,
	x,
	open,
	high,
	low,
	close;
	increasing_color,
	decreasing_color,
	legend::AbstractString,
	xlabel::AbstractString,
	ylabel::AbstractString,
	xrange,
	yrange,
	xscale::AbstractString,
	yscale::AbstractString,
	title::AbstractString,
	width,
	height,
	fontsize,
	grid,
	show::Bool,
)
	trace = _ohlc_trace(
		constructor,
		who,
		x,
		open,
		high,
		low,
		close;
		increasing_color = increasing_color,
		decreasing_color = decreasing_color,
		legend = legend,
		log_x = xscale == "log",
		log_y = yscale == "log",
	)
	labels = _extended_cartesian_labels(who; title = title, xlabel = xlabel, ylabel = ylabel)
	return _extended_cartesian_plot(
		who,
		trace;
		labels = labels,
		raw_title = title,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
		show = show,
	)
end

function _extended_ohlc_append!(
	fig,
	constructor,
	who::AbstractString,
	x,
	open,
	high,
	low,
	close;
	increasing_color,
	decreasing_color,
	legend::AbstractString,
	xlabel::AbstractString,
	ylabel::AbstractString,
	xrange,
	yrange,
	xscale::AbstractString,
	yscale::AbstractString,
	title::AbstractString,
	width,
	height,
	fontsize,
	grid,
	secondary_y::Bool,
	row,
	col,
	show,
)
	_extended_mutator_guard(who, show, row, col)
	_extended_secondary_y_guard(who, secondary_y)
	trace = _ohlc_trace(
		constructor,
		who,
		x,
		open,
		high,
		low,
		close;
		increasing_color = increasing_color,
		decreasing_color = decreasing_color,
		legend = legend,
		log_x = _extended_final_axis_type(fig, :xaxis, xscale) == "log",
		log_y = _extended_final_axis_type(fig, :yaxis, yscale) == "log",
	)
	labels = _extended_cartesian_labels(who; title = title, xlabel = xlabel, ylabel = ylabel)
	_extended_cartesian_append!(
		fig,
		who,
		trace;
		labels = labels,
		xrange = xrange,
		yrange = yrange,
		xscale = xscale,
		yscale = yscale,
		width = width,
		height = height,
		fontsize = fontsize,
		grid = grid,
	)
	return nothing
end

"""
	plot_candlestick(x, open, high, low, close; increasing_color="",
		decreasing_color="", legend="", xlabel="", ylabel="", xrange=[0, 0],
		yrange=[0, 0], xscale="", yscale="", title="", width=0, height=0,
		fontsize=0, grid=true, show=false)

Candlestick chart: for each period `x[i]` a box from `open[i]` to `close[i]`
with whiskers to `high[i]` and `low[i]`, coloured by direction. Plotly adds a
range slider under the x axis.

# Arguments
- `x::AbstractVector`: period positions (numbers, dates or date strings).
- `open`, `high`, `low`, `close::AbstractVector`: prices, one per period
  (finite real numbers; `missing`, `nothing` or NaN leave a gap). Stored
  without copying. The OHLC ordering (`low ≤ open, close ≤ high`) is not
  checked.

# Keywords
- `increasing_color::Union{AbstractString,Symbol} = ""`: colour of rising
  periods (`""` = plotly green).
- `decreasing_color::Union{AbstractString,Symbol} = ""`: colour of falling
  periods (`""` = plotly red).
- `legend::AbstractString = ""`: legend name of the trace (mathtext).
- `xlabel`, `ylabel::AbstractString = ""`: axis titles (mathtext).
- `xrange`, `yrange = [0, 0]`: axis ranges as a 2-element vector or tuple in
  data units; `[0, 0]` (or `nothing`) means automatic.
- `xscale`, `yscale::AbstractString = ""`: `"linear"`, `"log"` or `""`
  (automatic). On a `"log"` axis the values must be positive.
- `title::AbstractString = ""`: figure title (mathtext).
- `width::Real = 0`, `height::Real = 0`: figure size in px (`0` = automatic).
- `fontsize::Real = 0`: global font size in px (`0` = template default).
- `grid::Union{Bool,Symbol} = true`: `true` keeps the template grid; `false`
  or `:none` hides it, `:x`/`:y`/`:both` choose the axes with grid lines.
- `show::Bool = false`: open an Electron window and return a `SyncPlot`.

Arrays whose length differs from `length(x)` and non-finite or non-numeric
prices throw an `ArgumentError`.

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_candlestick(1:4, [10, 11, 10.5, 12], [11.5, 12, 11, 13],
	[9.5, 10.2, 9.8, 11.4], [11, 10.4, 10.9, 12.8]; ylabel = "Price", title = "ACME")
```
"""
function plot_candlestick(
	x::Union{AbstractVector, SubArray},
	open::Union{AbstractVector, SubArray},
	high::Union{AbstractVector, SubArray},
	low::Union{AbstractVector, SubArray},
	close::Union{AbstractVector, SubArray};
	increasing_color::Union{AbstractString, Symbol} = "",
	decreasing_color::Union{AbstractString, Symbol} = "",
	legend::AbstractString = "",
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
	grid::Union{Bool, Symbol} = true,
	show::Bool = false,
)
	return _extended_ohlc_plot(
		candlestick,
		"plot_candlestick",
		x,
		open,
		high,
		low,
		close;
		increasing_color = increasing_color,
		decreasing_color = decreasing_color,
		legend = legend,
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
		show = show,
	)
end

"""
	plot_candlestick!(fig, x, open, high, low, close; increasing_color="",
		decreasing_color="", legend="", xlabel="", ylabel="", xrange=[0, 0],
		yrange=[0, 0], xscale="", yscale="", title="", width=0, height=0,
		fontsize=0, grid=nothing)
	plot_candlestick!(sf::SubplotFigure, x, open, high, low, close;
		row=nothing, col=nothing, secondary_y=false, inset=nothing, kwargs...)

Append a candlestick trace to `fig` (`Plot`/`SyncPlot`). Arguments and
keywords as for [`plot_candlestick`](@ref) without `show` (an
`ArgumentError`); only non-default options change the figure, `grid = nothing`
keeps the current grid and any other value is applied, and the template is
left as it is.

On a `SubplotFigure` the trace goes to the `xy` cell `row`, `col` (both or
neither; default: the active cell; `secondary_y = true` draws against the
cell's secondary y axis), or to inset `inset` (an id returned by
[`inset!`](@ref)); that cell becomes the active cell. Axis options apply to the
cell's (or inset's) axes, and prices must be positive on a logarithmic target
y axis. `title`/`width`/`height` are ignored with a warning. `secondary_y` on a
single figure, and `inset` together with `secondary_y`, are an
`ArgumentError`.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_candlestick(1:2, [1, 2], [2, 3], [0.5, 1.5], [1.8, 2.2]; legend = "A")
plot_candlestick!(fig, 1:2, [2, 3], [3, 4], [1.5, 2.5], [2.8, 2.6]; legend = "B")
```
"""
function plot_candlestick!(
	fig,
	x::Union{AbstractVector, SubArray},
	open::Union{AbstractVector, SubArray},
	high::Union{AbstractVector, SubArray},
	low::Union{AbstractVector, SubArray},
	close::Union{AbstractVector, SubArray};
	increasing_color::Union{AbstractString, Symbol} = "",
	decreasing_color::Union{AbstractString, Symbol} = "",
	legend::AbstractString = "",
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
	grid::Union{Nothing, Bool, Symbol} = nothing,
	secondary_y::Bool = false,
	row = nothing,
	col = nothing,
	show = nothing,
)
	return _extended_ohlc_append!(
		fig,
		candlestick,
		"plot_candlestick!",
		x,
		open,
		high,
		low,
		close;
		increasing_color = increasing_color,
		decreasing_color = decreasing_color,
		legend = legend,
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
		secondary_y = secondary_y,
		row = row,
		col = col,
		show = show,
	)
end

function plot_candlestick!(
	sf::SubplotFigure,
	x::Union{AbstractVector, SubArray},
	open::Union{AbstractVector, SubArray},
	high::Union{AbstractVector, SubArray},
	low::Union{AbstractVector, SubArray},
	close::Union{AbstractVector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	# The delegate seeds the staging figure with the target axes' types (cell,
	# secondary y or inset), so the Plot method's positivity checks on log
	# axes see them.
	return _subplot_delegate_mutator!(
		sf,
		plot_candlestick!,
		x,
		open,
		high,
		low,
		close;
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		kwargs...,
	)
end

"""
	plot_ohlc(x, open, high, low, close; increasing_color="",
		decreasing_color="", legend="", xlabel="", ylabel="", xrange=[0, 0],
		yrange=[0, 0], xscale="", yscale="", title="", width=0, height=0,
		fontsize=0, grid=true, show=false)

OHLC bar chart: for each period `x[i]` a vertical bar from `low[i]` to
`high[i]` with ticks at `open[i]` (left) and `close[i]` (right), coloured by
direction. Arguments and keywords are those of [`plot_candlestick`](@ref).

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_ohlc(1:4, [10, 11, 10.5, 12], [11.5, 12, 11, 13],
	[9.5, 10.2, 9.8, 11.4], [11, 10.4, 10.9, 12.8]; increasing_color = "teal")
```
"""
function plot_ohlc(
	x::Union{AbstractVector, SubArray},
	open::Union{AbstractVector, SubArray},
	high::Union{AbstractVector, SubArray},
	low::Union{AbstractVector, SubArray},
	close::Union{AbstractVector, SubArray};
	increasing_color::Union{AbstractString, Symbol} = "",
	decreasing_color::Union{AbstractString, Symbol} = "",
	legend::AbstractString = "",
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
	grid::Union{Bool, Symbol} = true,
	show::Bool = false,
)
	return _extended_ohlc_plot(
		ohlc,
		"plot_ohlc",
		x,
		open,
		high,
		low,
		close;
		increasing_color = increasing_color,
		decreasing_color = decreasing_color,
		legend = legend,
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
		show = show,
	)
end

"""
	plot_ohlc!(fig, x, open, high, low, close; increasing_color="",
		decreasing_color="", legend="", xlabel="", ylabel="", xrange=[0, 0],
		yrange=[0, 0], xscale="", yscale="", title="", width=0, height=0,
		fontsize=0, grid=nothing)
	plot_ohlc!(sf::SubplotFigure, x, open, high, low, close;
		row=nothing, col=nothing, secondary_y=false, inset=nothing, kwargs...)

Append an OHLC trace to `fig` (`Plot`/`SyncPlot`), or to the `xy` cell
`row`, `col` of a `SubplotFigure`. Arguments and keywords as for
[`plot_ohlc`](@ref) without `show` (an `ArgumentError`); see
[`plot_candlestick!`](@ref) for the option, SubplotFigure, `inset` and
`secondary_y` rules.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = Plot()
plot_ohlc!(fig, 1:2, [1, 2], [2, 3], [0.5, 1.5], [1.8, 2.2]; yscale = "log")
```
"""
function plot_ohlc!(
	fig,
	x::Union{AbstractVector, SubArray},
	open::Union{AbstractVector, SubArray},
	high::Union{AbstractVector, SubArray},
	low::Union{AbstractVector, SubArray},
	close::Union{AbstractVector, SubArray};
	increasing_color::Union{AbstractString, Symbol} = "",
	decreasing_color::Union{AbstractString, Symbol} = "",
	legend::AbstractString = "",
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
	grid::Union{Nothing, Bool, Symbol} = nothing,
	secondary_y::Bool = false,
	row = nothing,
	col = nothing,
	show = nothing,
)
	return _extended_ohlc_append!(
		fig,
		ohlc,
		"plot_ohlc!",
		x,
		open,
		high,
		low,
		close;
		increasing_color = increasing_color,
		decreasing_color = decreasing_color,
		legend = legend,
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
		secondary_y = secondary_y,
		row = row,
		col = col,
		show = show,
	)
end

function plot_ohlc!(
	sf::SubplotFigure,
	x::Union{AbstractVector, SubArray},
	open::Union{AbstractVector, SubArray},
	high::Union{AbstractVector, SubArray},
	low::Union{AbstractVector, SubArray},
	close::Union{AbstractVector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	# The delegate seeds the staging figure with the target axes' types (cell,
	# secondary y or inset), so the Plot method's positivity checks on log
	# axes see them.
	return _subplot_delegate_mutator!(
		sf,
		plot_ohlc!,
		x,
		open,
		high,
		low,
		close;
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		kwargs...,
	)
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
function _stats_log_axis(fig, scale::AbstractString, key::Union{Nothing, Symbol})
	isempty(scale) || return scale == "log"
	# `nothing`: a twin y axis this call creates, which starts linear.
	key === nothing && return false
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

function _stats_histogram2d!(
	fig,
	x,
	y,
	who::AbstractString,
	options,
	color_options;
	mutator::Bool,
	secondary_y::Bool = false,
)
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

	# The y axis this call draws on (`nothing`: a twin it creates).
	check_ykey = _scat_twin_key(fig, secondary_y)
	xlog = _stats_log_axis(fig, options.xscale, :xaxis)
	ylog = _stats_log_axis(fig, options.yscale, check_ykey)
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
	_stats_validate_options(fig, who, options; ykey = check_ykey)

	ykey, yref = _stats_target_y!(fig, secondary_y, who)
	push!(_plot_data(fig), only(_stats_bind_y!(GenericTrace[trace], yref)))
	isempty(layout_fields) || relayout!(fig; layout_fields...)
	_stats_apply_options!(fig, who, options; mutator = mutator, ykey = ykey)
	return nothing
end

"""
	plot_histogram2d(x, y; kwargs...)

2-D histogram (density heatmap) of the paired samples `x[i]`, `y[i]`. Returns
a `PlotlyBase.Plot`, or a [`SyncPlot`](@ref) window when `show = true`.

#### Data
`x`, `y::AbstractVector` of equal length (vectors, ranges or views; complex
values, matrices and vectors of series are an `ArgumentError`). By default plotly bins and counts the samples
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

There is no `legend` keyword: a 2-D histogram is one colour-mapped trace whose
key is its colorbar (`colorbar_title`), not a legend entry.

#### Example
```julia
x, y = randn(5000), randn(5000)
fig = plot_histogram2d(x, y; nbinsx = 40, nbinsy = 40, colorscale = "viridis")
plot_histogram2d(x, y; colornorm = :log, colorbar_title = "count")
```
"""
function plot_histogram2d(
	x::AbstractArray,
	y::AbstractArray;
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
  cell), `inset = k` draws on inset `k` (see [`inset!`](@ref)) and
  `secondary_y = true` targets its secondary y axis; `title`, `width` and
  `height` are figure-wide and ignored there with a warning.
- On a `Plot`/`SyncPlot`, `secondary_y = true` draws on a secondary y axis on
  the right, created on first use (`ylabel`, `yscale`, `yrange`, `yticks`,
  ... then apply to it); `row`, `col` and `inset` are not accepted there
  (`row = nothing`/`col = nothing`, no cell, are ignored).

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
	x::AbstractArray,
	y::AbstractArray;
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
	secondary_y = _stats_mutator_options("plot_histogram2d!", kwargs)
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
		secondary_y = secondary_y,
	)
	return nothing
end

function plot_histogram2d!(
	sf::SubplotFigure,
	x::AbstractArray,
	y::AbstractArray;
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

# ── Annotations ──────────────────────────────────────────────────────

# Attribute names of a plotly.js 2.35.2 `layout.annotations` item (the version
# PlotlyBase's schema describes). Keyword arguments of `annotate!` are
# accepted when their first `_`-separated segment is one of these, so
# `arrowhead = 2` and `hoverlabel_bgcolor = "white"` pass through while a
# typo such as `arowhead` is an error instead of being silently ignored.
const _ANNOTATION_ATTRIBUTE_NAMES = (
	:align, :arrowcolor, :arrowhead, :arrowside, :arrowsize, :arrowwidth,
	:ax, :axref, :ay, :ayref, :bgcolor, :bordercolor, :borderpad,
	:borderwidth, :captureevents, :clicktoshow, :font, :height, :hoverlabel,
	:hovertext, :name, :opacity, :showarrow, :standoff, :startarrowhead,
	:startarrowsize, :startstandoff, :templateitemname, :text, :textangle,
	:valign, :visible, :width, :x, :xanchor, :xclick, :xref, :xshift, :y,
	:yanchor, :yclick, :yref, :yshift,
)

const _ANNOTATION_COORDS = (:data, :axes, :paper, :figure)

# `name` of an annotation placed in whole-figure fractions (`coords =
# :figure`): the prefix, then "<fx>:<fy>:<dx>:<dy>" (the figure fractions,
# "-" for a coordinate given through an explicit `xref`/`yref`, and the px
# shift of `offset`), so `_figure_annotations_place!` can re-place it.
const _FIGURE_ANNOTATION_PREFIX = "plotlysupply:figure:"

# plotly.js 2.35.2 "auto" anchor of a paper- or domain-referenced annotation
# without an arrow (annotations/draw.js: `t < 1/3 ? "left" : t > 2/3 ?
# "right" : "center"` with t = x, and t = 1 - y for the vertical anchor).
_annotation_auto_xanchor(fraction::Real) = fraction < 1 / 3 ? "left" : fraction > 2 / 3 ? "right" : "center"
_annotation_auto_yanchor(fraction::Real) = fraction > 2 / 3 ? "top" : fraction < 1 / 3 ? "bottom" : "middle"

# Plotly reference strings: "paper", or an axis ("x", "x2", …) optionally
# followed by " domain" (fractions of that axis' domain). Arrow tails also
# take "pixel".
const _ANNOTATION_X_REF = r"^(paper|x([2-9]|[1-9][0-9]+)?( domain)?)$"
const _ANNOTATION_Y_REF = r"^(paper|y([2-9]|[1-9][0-9]+)?( domain)?)$"
const _ANNOTATION_AX_REF = r"^(pixel|x([2-9]|[1-9][0-9]+)?( domain)?)$"
const _ANNOTATION_AY_REF = r"^(pixel|y([2-9]|[1-9][0-9]+)?( domain)?)$"

function _annotation_fraction(value, who::AbstractString, name::AbstractString, what::AbstractString)
	(_extended_is_real(value) && isfinite(value)) || throw(ArgumentError(
		"$(who): `$(name)` must be a finite number ($(what)); got $(repr(value)).",
	))
	return value
end

# A data coordinate on Cartesian axis `key`: on a logarithmic axis plotly
# positions annotations by log10(value), so the data value is converted
# (and must be positive); elsewhere numbers must be finite and categories or
# dates pass through unchanged.
function _annotation_data_position(layout::Layout, key::Symbol, value, who::AbstractString, name::AbstractString)
	(value === nothing || value === missing) && throw(ArgumentError(
		"$(who): `$(name)` must be a coordinate; got $(repr(value)).",
	))
	if _axis_type(layout, key) == "log"
		_extended_is_real(value) || throw(ArgumentError(
			"$(who): `$(name)` is on logarithmic axis $(repr(key)) and must be a " *
			"positive number; got $(repr(value)).",
		))
		return _to_axis_coord(layout, key, value; who = who)
	end
	value isa Bool && throw(ArgumentError("$(who): `$(name)` must be a coordinate; got $(repr(value))."))
	value isa Real && !isfinite(value) && throw(ArgumentError(
		"$(who): `$(name)` must be finite; got $(repr(value)).",
	))
	return value
end

function _annotation_axis_exists(layout::Layout, key::Symbol)
	key in (:xaxis, :yaxis) && return true
	return haskey(layout.fields, key)
end

# Reference and position of one annotation coordinate. An explicit `xref` /
# `yref` wins over `coords`.
function _annotation_coordinate(
	layout::Layout,
	target,
	letter::Symbol,
	value,
	coords::Symbol,
	ref_override,
	who::AbstractString,
)
	name = String(letter)
	ref_name = name * "ref"
	if ref_override !== nothing
		ref_override isa AbstractString || throw(ArgumentError(
			"$(who): `$(ref_name)` must be a string; got $(repr(ref_override)).",
		))
		ref = String(ref_override)
		pattern = letter === :x ? _ANNOTATION_X_REF : _ANNOTATION_Y_REF
		occursin(pattern, ref) || throw(ArgumentError(
			"$(who): `$(ref_name)` must be \"paper\", \"$(name)\", \"$(name)2\", … or " *
			"\"$(name) domain\", \"$(name)2 domain\", …; got $(repr(ref)).",
		))
		ref == "paper" && return ref, _annotation_fraction(value, who, name, "a figure fraction")
		axis_ref = replace(ref, " domain" => "")
		key = _axis_layout_key(axis_ref, letter)
		_annotation_axis_exists(layout, key) || throw(ArgumentError(
			"$(who): `$(ref_name)` refers to axis $(repr(axis_ref)), which this " *
			"figure does not have.",
		))
		endswith(ref, " domain") &&
			return ref, _annotation_fraction(value, who, name, "a fraction of the axis domain")
		return ref, _annotation_data_position(layout, key, value, who, name)
	end
	if coords === :paper
		return "paper", _annotation_fraction(value, who, name, "a fraction of the plot area")
	elseif coords === :figure
		# Whole-figure fractions; `_extended_annotate!` adds the px shift that
		# turns this paper position into the figure position.
		fraction = _annotation_fraction(value, who, name, "a figure fraction")
		0 <= fraction <= 1 || throw(ArgumentError(
			"$(who): `$(name)` = $(repr(value)) is outside the figure: `coords = :figure` " *
			"takes fractions of the whole figure in [0, 1]. For plotly's paper " *
			"coordinates (fractions of the plot area, negative below it) use `coords = :paper`.",
		))
		return "paper", fraction
	elseif coords === :axes
		fraction = _annotation_fraction(value, who, name, "a fraction of the axes")
		if target.kind === :xy
			return (letter === :x ? target.xref : target.yref) * " domain", fraction
		end
		# Subplots without Cartesian axes (pie, polar, ternary, 3-D, maps):
		# map the fraction into the cell's domain in figure coordinates.
		lower, upper = letter === :x ? target.xdomain : target.ydomain
		return "paper", lower + fraction * (upper - lower)
	end
	target.kind === :xy || throw(ArgumentError(
		"$(who): `coords = :data` needs Cartesian x/y axes, but the target is a " *
		":$(target.kind) $(target.row == 0 ? "figure" : "cell"); use `coords = :axes` " *
		"or `coords = :figure`.",
	))
	key = letter === :x ? target.xkey : target.ykey
	return letter === :x ? target.xref : target.yref,
		_annotation_data_position(layout, key, value, who, name)
end

# Arrow tail (`ax`/`ay`) given in data units through an axis `axref`/`ayref`:
# convert it on a logarithmic axis like the head.
function _annotation_tail!(entry::Dict{Symbol, Any}, layout::Layout, letter::Symbol, who::AbstractString)
	value_key = letter === :x ? :ax : :ay
	ref_key = letter === :x ? :axref : :ayref
	haskey(entry, ref_key) || return nothing
	ref_value = entry[ref_key]
	ref_value isa AbstractString || throw(ArgumentError(
		"$(who): `$(ref_key)` must be a string; got $(repr(ref_value)).",
	))
	ref = String(ref_value)
	pattern = letter === :x ? _ANNOTATION_AX_REF : _ANNOTATION_AY_REF
	occursin(pattern, ref) || throw(ArgumentError(
		"$(who): `$(ref_key)` must be \"pixel\", an axis such as \"$(letter)2\", or " *
		"\"<axis> domain\"; got $(repr(ref)).",
	))
	(ref == "pixel" || endswith(ref, " domain")) && return nothing
	key = _axis_layout_key(ref, letter)
	_annotation_axis_exists(layout, key) || throw(ArgumentError(
		"$(who): `$(ref_key)` refers to axis $(repr(ref)), which this figure does not have.",
	))
	haskey(entry, value_key) &&
		(entry[value_key] = _annotation_data_position(layout, key, entry[value_key], who, String(value_key)))
	return nothing
end

const _ANNOTATION_ALIGN = Dict("left" => :l, "center" => :c, "right" => :r)

# ── Whole-figure annotations (`coords = :figure`) ──
#
# plotly.js annotations reference only the paper (the plot area inside the
# margins) or axes, so a figure fraction f is drawn at paper fraction f
# shifted by f * (l + r) - l px horizontally and f * (t + b) - b px
# vertically (l, r, t, b: the rendered margins in px). The shift does not
# depend on the figure size, so the position stays right in a `savefig` of
# another size as long as the margins do not change. A caption that reaches
# into the bottom margin also gets room there below the x-axis tick labels
# and title: `margin.b` is raised so they and the caption do not overlap.

# Gap (px) kept between the bottom-axis decorations and a caption below them.
const _FIGURE_ANNOTATION_GAP = 4.0

# (fx, fy, dx, dy) of an annotation placed by `coords = :figure` (`nothing`
# for a coordinate given through `xref`/`yref`), or `nothing` for any other
# annotation.
function _figure_annotation_spec(item)
	name = _cmn_mapping_get(item, :name)
	(name isa AbstractString && startswith(name, _FIGURE_ANNOTATION_PREFIX)) || return nothing
	parts = split(name[(ncodeunits(_FIGURE_ANNOTATION_PREFIX) + 1):end], ':')
	length(parts) == 4 || return nothing
	fraction(part) = part == "-" ? nothing : tryparse(Float64, part)
	fx, fy = fraction(parts[1]), fraction(parts[2])
	dx, dy = tryparse(Float64, parts[3]), tryparse(Float64, parts[4])
	(dx === nothing || dy === nothing) && return nothing
	(parts[1] != "-" && fx === nothing) && return nothing
	(parts[2] != "-" && fy === nothing) && return nothing
	return (fx = fx, fy = fy, dx = dx, dy = dy)
end

# Estimated height (px) of annotation text: 1.4 em per line, 2.2 em for a
# line with typeset math that has sub/superscripts or fractions (the D12
# text-height rule). Lines are split at `<br>` and, in the `\begin{array}`
# form `_label` gives multi-line math text, at `\\`.
function _figure_annotation_text_height(text, fontsize::Float64)
	text isa AbstractString || return 1.4 * fontsize
	height = 0.0
	for segment in split(text, r"<br\s*/?>")
		lines = occursin("\\begin{array}", segment) ? split(segment, "\\\\") : (segment,)
		math = occursin('$', segment)
		for line in lines
			tall = math && (occursin('^', line) || occursin('_', line) || occursin("\\frac", line))
			height += (tall ? 2.2 : 1.4) * fontsize
		end
	end
	return height
end

function _figure_annotation_fontsize(item, layout::Layout)
	size = _cmn_mapping_get(_cmn_mapping_get(item, :font), :size)
	(size isa Real && !(size isa Bool) && isfinite(size) && size > 0) && return Float64(size)
	base = _cmn_mapping_get(get(layout.fields, :font, nothing), :size)
	(base isa Real && !(base isa Bool) && isfinite(base) && base > 0) && return Float64(base)
	return 12.0
end

# Figure size (px) used for the bottom-margin reservation: the layout size,
# else plotly's default 700 x 500 (`savefig`'s default size as well).
function _figure_annotation_size(layout::Layout)
	side(key, default) = (v = get(layout.fields, key, nothing);
		v isa Real && !(v isa Bool) && isfinite(v) && v > 0 ? Float64(v) : default)
	return side(:width, _DEFAULT_EXPORT_WIDTH_PX), side(:height, _DEFAULT_EXPORT_HEIGHT_PX)
end

# Re-place every whole-figure annotation of `annotations` (the figure's
# annotation list, items replaced, never mutated) for the current margins of
# `p`, raising the bottom margin when a caption reaches below the plot area.
# Returns the new `margin.b` (px) to write, or `nothing`.
function _figure_annotations_place!(p::Plot, annotations::Vector{Any})
	specs = [(index, spec) for (index, item) in pairs(annotations)
		for spec in (_figure_annotation_spec(item),) if spec !== nothing]
	isempty(specs) && return nothing
	layout = p.layout
	W, H = _figure_annotation_size(layout)
	accs = _fin_collect_axes(p)
	margins = _fin_margins(layout, accs, W, H, Dict{Symbol, NTuple{2, Float64}}(), Any[])
	# Room the bottom x-axis tick labels and title take (their automargin push
	# plus plotly's extra), measured with a zero base margin.
	probe = Layout(copy(layout.fields))
	probe_margin = _symbol_dict(get(layout.fields, :margin, nothing))
	probe_margin[:b] = 0
	probe.fields[:margin] = probe_margin
	push = _fin_margins(probe, accs, W, H, Dict{Symbol, NTuple{2, Float64}}(), Any[]).b
	axis_room = push > 0 ? push + _FIN_AUTOMARGIN_EXTRA : 0.0

	needed = margins.b
	for (index, spec) in specs
		spec.fy === nothing && continue
		item = annotations[index]
		_cmn_mapping_get(item, :showarrow) === false || continue
		height = _figure_annotation_text_height(_cmn_mapping_get(item, :text), _figure_annotation_fontsize(item, layout))
		anchor = something(_cmn_mapping_get(item, :yanchor), "auto")
		anchor == "auto" && (anchor = _annotation_auto_yanchor(spec.fy))
		y0 = spec.fy * H + spec.dy
		below = anchor == "top" ? height : anchor == "middle" ? height / 2 : 0.0
		bottom, top = y0 - below, y0 - below + height
		# Only text that reaches into the bottom margin is a caption below the
		# axes; text over the plot area is left where it is.
		bottom < margins.b || continue
		needed = max(needed, min(top + _FIGURE_ANNOTATION_GAP + axis_room, H / 2))
	end
	new_b = needed > margins.b + 0.5 ? Float64(ceil(needed)) : nothing
	b = new_b === nothing ? margins.b : new_b

	for (index, spec) in specs
		item = annotations[index]
		fields = _symbol_dict(item)
		spec.fx === nothing || (fields[:xshift] = round(spec.fx * (margins.l + margins.r) - margins.l + spec.dx; digits = 2))
		spec.fy === nothing || (fields[:yshift] = round(spec.fy * (margins.t + b) - b + spec.dy; digits = 2))
		annotations[index] = attr(; fields...)
	end
	return new_b
end

# Build the annotation for `target` (a `_CellTarget`) and append it to the
# figure's annotations. Everything is validated before the layout is written.
function _extended_annotate!(
	fig,
	target,
	x,
	y,
	text::AbstractString;
	coords::Union{Symbol, AbstractString} = :data,
	offset = (0, 0),
	fontsize::Real = 0,
	font_size = nothing,
	color::Union{AbstractString, Symbol} = "",
	showarrow::Bool = true,
	xref = nothing,
	yref = nothing,
	kwargs...,
)
	who = "annotate!"
	layout = _plot_layout(fig)
	coordinate_system = Symbol(coords)
	coordinate_system in _ANNOTATION_COORDS || throw(ArgumentError(
		"$(who): `coords` must be :data, :axes, :paper or :figure; got $(repr(coords)).",
	))
	_require_size_option(fontsize, who, "fontsize")
	font_px = fontsize
	if font_size !== nothing
		Base.depwarn(
			"`annotate!(...; font_size = n)` is deprecated; use `fontsize = n`.",
			:annotate!,
		)
		_require_size_option(font_size, who, "font_size")
		(fontsize > 0 && font_size != fontsize) && throw(ArgumentError(
			"$(who): `font_size` (deprecated) and `fontsize` disagree " *
			"($(repr(font_size)) vs $(repr(fontsize))); pass only `fontsize`.",
		))
		font_px = font_size
	end
	text_color = _extended_colour(who, "color", color)
	(offset isa Tuple || offset isa AbstractVector) && length(offset) == 2 || throw(ArgumentError(
		"$(who): `offset` must be a 2-element tuple or vector (dx, dy) in px; got $(repr(offset)).",
	))
	dx = _annotation_fraction(offset[begin], who, "offset", "px")
	dy = _annotation_fraction(offset[end], who, "offset", "px")

	entry = Dict{Symbol, Any}()
	font = Dict{Symbol, Any}()
	for (key, value) in kwargs
		head = Symbol(first(split(String(key), '_')))
		head in _ANNOTATION_ATTRIBUTE_NAMES || throw(ArgumentError(
			"$(who): unknown keyword `$(key)`; plotly annotations have no " *
			"attribute $(repr(String(head))).",
		))
		key in (:x, :y, :text) && throw(ArgumentError(
			"$(who): `$(key)` is a positional argument; do not pass it as a keyword.",
		))
		if key === :font
			value isa Union{PlotlyBase.PlotlyAttribute, AbstractDict, NamedTuple} || throw(ArgumentError(
				"$(who): `font` must be an `attr(...)`, a Dict or a NamedTuple; got $(typeof(value)).",
			))
			merge!(font, _symbol_dict(value))
		elseif head === :font
			attribute = String(key)[(ncodeunits("font_") + 1):end]
			isempty(attribute) && throw(ArgumentError("$(who): unknown keyword `$(key)`."))
			font[Symbol(attribute)] = value
		else
			entry[key] = value
		end
	end
	align = get(entry, :align, "center")
	(align isa AbstractString && haskey(_ANNOTATION_ALIGN, align)) || throw(ArgumentError(
		"$(who): `align` must be \"left\", \"center\" or \"right\"; got $(repr(align)).",
	))
	label = _extended_label(text, who, "text"; align = _ANNOTATION_ALIGN[align])

	x_ref, x_position = _annotation_coordinate(layout, target, :x, x, coordinate_system, xref, who)
	y_ref, y_position = _annotation_coordinate(layout, target, :y, y, coordinate_system, yref, who)
	_annotation_tail!(entry, layout, :x, who)
	_annotation_tail!(entry, layout, :y, who)
	# Coordinates in whole-figure fractions (an explicit `xref`/`yref` wins).
	figure_x = coordinate_system === :figure && xref === nothing
	figure_y = coordinate_system === :figure && yref === nothing
	if figure_x || figure_y
		haskey(entry, :name) && throw(ArgumentError(
			"$(who): `name` cannot be set with `coords = :figure` (it marks the " *
			"annotation as placed in figure fractions).",
		))
		for (taken, key) in ((figure_x, :xshift), (figure_y, :yshift))
			taken && haskey(entry, key) && throw(ArgumentError(
				"$(who): `$(key)` cannot be combined with `coords = :figure` (the " *
				"shift places the annotation in the figure); use `offset`.",
			))
		end
	end
	# G70: cell fractions of a pie, polar, ternary, 3-D or map cell become
	# figure ("paper") fractions, where plotly's automatic anchor would follow
	# the position in the figure. Anchor by the position in the cell instead,
	# as plotly does for the "x domain" references of a Cartesian cell.
	if coordinate_system === :axes && target.kind !== :xy && !showarrow
		xref === nothing && !haskey(entry, :xanchor) && (entry[:xanchor] = _annotation_auto_xanchor(x))
		yref === nothing && !haskey(entry, :yanchor) && (entry[:yanchor] = _annotation_auto_yanchor(y))
	end
	if dx != 0 || dy != 0
		shift_keys = showarrow ? (:ax, :ay, :axref, :ayref) : (:xshift, :yshift)
		for key in shift_keys
			haskey(entry, key) && throw(ArgumentError(
				"$(who): `offset` and `$(key)` both move the " *
				(showarrow ? "text away from the arrow head" : "annotation") *
				"; pass only one of them.",
			))
		end
		if showarrow
			# The arrow head stays at (x, y); the text moves by the offset
			# (plotly's `ay` grows downwards, `offset` upwards).
			entry[:ax] = dx
			entry[:ay] = -dy
		else
			entry[:xshift] = dx
			entry[:yshift] = dy
		end
	end
	font_px > 0 && (font[:size] = font_px)
	if !isempty(text_color)
		font[:color] = text_color
		showarrow && !haskey(entry, :arrowcolor) && (entry[:arrowcolor] = text_color)
	end
	isempty(font) || (entry[:font] = attr(; font...))
	entry[:x] = x_position
	entry[:y] = y_position
	entry[:xref] = x_ref
	entry[:yref] = y_ref
	entry[:text] = label
	entry[:showarrow] = showarrow
	if figure_x || figure_y
		# Without an arrow the offset is a shift, which the placement adds to
		# the figure shift; with an arrow it moved the text (`ax`/`ay`).
		shift_x, shift_y = showarrow ? (0.0, 0.0) : (Float64(dx), Float64(dy))
		entry[:name] = _FIGURE_ANNOTATION_PREFIX *
			"$(figure_x ? Float64(x_position) : "-"):$(figure_y ? Float64(y_position) : "-"):$(shift_x):$(shift_y)"
	end

	existing = get(layout.fields, :annotations, nothing)
	annotations = existing === nothing ? Any[] : collect(Any, existing)
	push!(annotations, attr(; entry...))
	margin_b = _figure_annotations_place!(_plot_obj(fig), annotations)
	if margin_b === nothing
		relayout!(fig, annotations = annotations)
	else
		relayout!(fig; annotations = annotations, margin_b = margin_b)
	end
	return nothing
end

"""
	annotate!(fig, x, y, text; coords=:data, offset=(0, 0), fontsize=0,
		color="", showarrow=true, xref=nothing, yref=nothing, kwargs...)
	annotate!(sf::SubplotFigure, x, y, text; row=nothing, col=nothing,
		secondary_y=false, inset=nothing, kwargs...)

Add the text annotation `text` at `(x, y)`, by default with an arrow pointing
at that position.

# Arguments
- `fig`: a `Plot` or `SyncPlot` (or a `SubplotFigure`, see below).
- `x`, `y`: the position, in the coordinate system chosen by `coords`.
- `text::AbstractString`: the annotation text (mathtext: `\$…\$` math is
  typeset, `\\n` breaks lines; `LaTeXString`s are accepted).

# Keywords
- `coords::Symbol = :data`:
  - `:data`: data coordinates of the figure's (or cell's) x/y axes. On a
    logarithmic axis give the data value (`x = 1000`), not its exponent.
  - `:axes`: fractions of the axes area, `(0, 0)` bottom left, `(1, 1)` top
    right (of the cell's domain for pie, polar, ternary, 3-D and map cells).
    Without an arrow the text is anchored by its position in the cell (left
    of 1/3 of the width left-aligned, right of 2/3 right-aligned, else
    centred; likewise bottom/middle/top), on every kind of cell.
  - `:paper`: plotly "paper" coordinates, fractions of the plot area inside
    the figure margins (of the whole subplot grid on a `SubplotFigure`);
    values below 0 or above 1 reach into the margins.
  - `:figure`: fractions of the whole figure, `(0, 0)` its bottom-left
    corner and `(1, 1)` its top-right corner (matplotlib's `fig.text`), each
    in `[0, 1]`; use it for footnotes and captions. The text is drawn at the
    plot-area position shifted by the figure margins, so it keeps its place
    in any `savefig` size as long as the margins do not change. Text without
    an arrow that reaches below the plot area is a caption: the bottom margin
    is raised so the caption sits below the x-axis tick labels and title
    (at most half the figure height). Each `annotate!` re-places the figure
    annotations already present for the margins at that time; margins
    changed later (a legend moved below the plot, `tight_layout!`) are not
    followed until the next `annotate!`. `name` and `xshift`/`yshift`
    cannot be combined with it (use `offset`).
- `offset = (0, 0)`: `(dx, dy)` in px, `dy` upwards. With an arrow the text
  moves by the offset and the arrow head stays at `(x, y)`; without an arrow the
  whole annotation is shifted.
- `fontsize::Real = 0`: text size in px (`0` = figure font).
- `font_size`: deprecated alias of `fontsize`.
- `color::Union{AbstractString,Symbol} = ""`: text colour, also used for the
  arrow unless `arrowcolor` is given (`""` = plotly default).
- `showarrow::Bool = true`: draw an arrow from the text to `(x, y)`.
- `xref`, `yref::Union{Nothing,AbstractString} = nothing`: explicit plotly
  references (`"paper"`, `"x2"`, `"y3 domain"`, …) that override `coords` for
  that coordinate; an axis reference takes data units (log-converted like
  `:data`).
- `kwargs...`: further plotly annotation attributes, e.g. `arrowhead = 2`,
  `bgcolor = "white"`, `font = attr(family = "Courier")`, `align = "left"`,
  `ax`/`ay` (with `axref`/`ayref` set to an axis, in data units). Unknown names
  throw an `ArgumentError`.

On a `SubplotFigure` the annotation is placed in cell `row`, `col` (both or
neither; default: the active cell), against the cell's secondary y axis with
`secondary_y = true`, or in inset `inset` (an id returned by `inset!`); that
cell becomes the active cell. On a single figure, `row`/`col`/`inset` throw an
`ArgumentError` and `secondary_y = true` needs a secondary y axis.

# Returns
`fig` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_scatter(1:100, (1:100) .^ 2; yscale = "log")
annotate!(fig, 50, 2500, "knee"; offset = (30, 30), color = "firebrick")
annotate!(fig, 0.02, 0.95, "(a)"; coords = :axes, showarrow = false, fontsize = 16)
annotate!(fig, 0.5, 0.01, "Source: simulation"; coords = :figure, showarrow = false,
	yanchor = "bottom")
```
"""
function annotate!(
	fig,
	x,
	y,
	text::AbstractString;
	coords::Union{Symbol, AbstractString} = :data,
	offset = (0, 0),
	fontsize::Real = 0,
	font_size = nothing,
	color::Union{AbstractString, Symbol} = "",
	showarrow::Bool = true,
	xref = nothing,
	yref = nothing,
	row = nothing,
	col = nothing,
	secondary_y::Bool = false,
	inset = nothing,
	kwargs...,
)
	target = _cell_target(fig; row = row, col = col, secondary_y = secondary_y, inset = inset, who = "annotate!")
	_extended_annotate!(
		fig,
		target,
		x,
		y,
		text;
		coords = coords,
		offset = offset,
		fontsize = fontsize,
		font_size = font_size,
		color = color,
		showarrow = showarrow,
		xref = xref,
		yref = yref,
		kwargs...,
	)
	_refresh!(fig)
	return fig
end

function _annotate_subplot_impl!(
	sf::SubplotFigure,
	x,
	y,
	text::AbstractString;
	row = nothing,
	col = nothing,
	secondary_y::Bool = false,
	inset = nothing,
	kwargs...,
)
	target = _cell_target(sf; row = row, col = col, secondary_y = secondary_y, inset = inset, who = "annotate!")
	_extended_annotate!(sf.fig, target, x, y, text; kwargs...)
	sf.current_row = target.row
	sf.current_col = target.col
	_refresh!(sf.fig)
	return sf
end

function annotate!(
	sf::SubplotFigure,
	x,
	y,
	text::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	secondary_y::Bool = false,
	inset = nothing,
	kwargs...,
)
	_transactional_subplot_mutation!(
		_annotate_subplot_impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		x,
		y,
		text;
		row = row,
		col = col,
		secondary_y = secondary_y,
		inset = inset,
		kwargs...,
	)
	return sf
end

# ── Sankey ───────────────────────────────────────────────────────────

# Number of nodes plotly draws: one per label, plus any node an index refers
# to beyond the labels. Indices are validated integer-valued reals; they are
# compared without conversion so a huge Float64 index cannot overflow `Int`.
function _sankey_node_count(label, source, target)
	largest = -1
	for index in Iterators.flatten((source, target))
		index > largest && (largest = index)
	end
	labelled = label === nothing ? 0 : length(label)
	return largest + 1 > labelled ? largest + 1 : labelled
end

function _sankey_trace(
	who::AbstractString,
	source::AbstractVector,
	target::AbstractVector,
	value::AbstractVector;
	label,
	node_color,
	link_color,
)
	_extended_require_nonempty(who, "source", source)
	n = length(source)
	_extended_check_length(who, "target", target, "source", n)
	_extended_check_length(who, "value", value, "source", n)
	_extended_check_numbers(who, "source", source; nonnegative = true, integer = true)
	_extended_check_numbers(who, "target", target; nonnegative = true, integer = true)
	_extended_check_numbers(who, "value", value; nonnegative = true)
	node = Dict{Symbol, Any}()
	label === nothing || (node[:label] = _extended_plain_labels(label, who, "label"))
	if node_color isa AbstractVector
		if !isempty(node_color)
			nodes = _sankey_node_count(label, source, target)
			length(node_color) == nodes || throw(ArgumentError(
				"$(who): `node_color` must have one colour per node ($(nodes) nodes: " *
				"the labels and every index in `source`/`target`); got $(length(node_color)).",
			))
			node[:color] = _extended_colour_vector(who, "node_color", node_color, length(node_color), "nodes")
		end
	else
		colour = _extended_colour(who, "node_color", node_color)
		isempty(colour) || (node[:color] = colour)
	end
	link = Dict{Symbol, Any}(:source => source, :target => target, :value => value)
	if link_color isa AbstractVector
		isempty(link_color) ||
			(link[:color] = _extended_colour_vector(who, "link_color", link_color, n, "source"))
	else
		colour = _extended_colour(who, "link_color", link_color)
		isempty(colour) || (link[:color] = colour)
	end
	return sankey(node = attr(; node...), link = attr(; link...))
end

"""
	plot_sankey(source, target, value; label=nothing, node_color="",
		link_color="", title="", width=0, height=0, fontsize=0, show=false)

Sankey flow diagram: link `i` carries `value[i]` from node `source[i]` to node
`target[i]`.

# Arguments
- `source`, `target::AbstractVector`: 0-based node indices (non-negative
  integers), one per link.
- `value::AbstractVector`: flow of each link (non-negative finite numbers).
  The three arrays are stored without copying.

# Keywords
- `label::Union{Nothing,AbstractVector} = nothing`: node names, by index.
  Drawn without MathJax: `\$…\$` math becomes Unicode with sub/superscripts.
- `node_color::Union{AbstractString,Symbol,AbstractVector} = ""`: one colour
  for every node, or one per node (the node count is the larger of
  `length(label)` and the largest index + 1). `""` or an empty vector uses the
  colorway.
- `link_color::Union{AbstractString,Symbol,AbstractVector} = ""`: one colour
  for every link, or one per link (`""` = translucent grey).
- `title::AbstractString = ""`, `width::Real = 0`, `height::Real = 0`,
  `fontsize::Real = 0`, `show::Bool = false`: as for [`plot_pie`](@ref).

Mismatched lengths, negative or fractional indices and negative or
non-finite values throw an `ArgumentError`.

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_sankey([0, 0, 1, 2], [1, 2, 3, 3], [8, 4, 6, 3];
	label = ["Source", "A", "B", "Sink"], link_color = "rgba(0,0,96,0.2)")
```
"""
function plot_sankey(
	source::AbstractVector,
	target::AbstractVector,
	value::AbstractVector;
	label::Union{Nothing, AbstractVector} = nothing,
	node_color::Union{AbstractString, Symbol, AbstractVector} = "",
	link_color::Union{AbstractString, Symbol, AbstractVector} = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	who = "plot_sankey"
	trace = _sankey_trace(who, source, target, value; label = label, node_color = node_color, link_color = link_color)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	fig = Plot(trace, Layout())
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = true,
	)
	return _extended_maybe_show(fig, show, width, height, title)
end

"""
	plot_sankey!(fig, source, target, value; label=nothing, node_color="",
		link_color="", title="", width=0, height=0, fontsize=0)
	plot_sankey!(sf::SubplotFigure, source, target, value; row=nothing, col=nothing, kwargs...)

Append a Sankey trace to `fig` (`Plot`/`SyncPlot`), or to the `domain` cell
`row`, `col` of a `SubplotFigure` (default: the active cell). Arguments and
keywords as for [`plot_sankey`](@ref) without `show` (an `ArgumentError`); see
[`plot_pie!`](@ref) for the figure-level options.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = Plot()
plot_sankey!(fig, [0, 1], [1, 2], [5, 3]; label = ["a", "b", "c"])
```
"""
function plot_sankey!(
	fig,
	source::AbstractVector,
	target::AbstractVector,
	value::AbstractVector;
	label::Union{Nothing, AbstractVector} = nothing,
	node_color::Union{AbstractString, Symbol, AbstractVector} = "",
	link_color::Union{AbstractString, Symbol, AbstractVector} = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_sankey!"
	_extended_mutator_guard(who, show, row, col)
	trace = _sankey_trace(who, source, target, value; label = label, node_color = node_color, link_color = link_color)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	push!(_plot_data(fig), trace)
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	_refresh!(fig)
	return nothing
end

function plot_sankey!(
	sf::SubplotFigure,
	source::AbstractVector,
	target::AbstractVector,
	value::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_sankey!, source, target, value; row = row, col = col, kwargs...)
end

# ── Parallel coordinates ─────────────────────────────────────────────

# One dimension: a `label => values` Pair (a non-vector iterable is
# collected), or a raw plotly `attr(...)` passed through unchanged. Plotly
# hands parcoords axis titles to MathJax, but places the typeset result at the
# top tick label instead of above the axis (seen on 700x500 renders with
# plotly.js 2.35.2), so labels take the Unicode `_label_plain` path.
function _parcoords_dim(who::AbstractString, dimension, position::Integer)
	if dimension isa Pair
		label = first(dimension)
		(label isa AbstractString || label isa Symbol) || throw(ArgumentError(
			"$(who): the label of `dimensions[$(position)]` must be a string or " *
			"Symbol; got $(repr(label)).",
		))
		values = last(dimension)
		values isa AbstractVector || (values = collect(values))
		values isa AbstractVector || throw(ArgumentError(
			"$(who): the values of `dimensions[$(position)]` must be a vector; " *
			"got $(typeof(last(dimension))).",
		))
		_extended_check_numbers(who, "dimensions[$(position)] values", values; gaps = true)
		return attr(
			label = _extended_plain_label(String(label), who, "dimensions[$(position)] label"),
			values = values,
		)
	end
	dimension isa PlotlyBase.PlotlyAttribute && return dimension
	throw(ArgumentError(
		"$(who): each dimension must be a `\"label\" => values` Pair or an " *
		"`attr(...)`; `dimensions[$(position)]` is a $(typeof(dimension)).",
	))
end

_parcoords_dim_values(dimension) =
	get(dimension.fields, :values, nothing)

function _parcoords_trace(who::AbstractString, dimensions::AbstractVector; line_color, colorscale)
	isempty(dimensions) && throw(ArgumentError("$(who): `dimensions` must not be empty."))
	dims = Any[_parcoords_dim(who, dimension, position) for (position, dimension) in enumerate(dimensions)]
	rows = nothing
	for (position, dimension) in enumerate(dims)
		values = _parcoords_dim_values(dimension)
		values === nothing && continue
		count = length(values)
		if rows === nothing
			rows = count
		elseif count != rows
			throw(ArgumentError(
				"$(who): every dimension must have the same number of values; " *
				"`dimensions[$(position)]` has $(count), the first has $(rows).",
			))
		end
	end
	scale = _resolve_colorscale(colorscale; who = who).scale
	has_scale = !(scale isa AbstractString && isempty(scale))
	line = Dict{Symbol, Any}()
	if line_color === nothing || (line_color isa AbstractString && isempty(line_color))
		has_scale && throw(ArgumentError(
			"$(who): `colorscale` colours the lines by a numeric `line_color` " *
			"vector (one value per row); pass `line_color` too.",
		))
	elseif line_color isa AbstractVector
		rows === nothing || _extended_check_length(who, "line_color", line_color, "rows", rows)
		_extended_check_numbers(who, "line_color", line_color)
		line[:color] = line_color
	else
		has_scale && throw(ArgumentError(
			"$(who): `colorscale` needs a numeric `line_color` vector (one value " *
			"per row), not the single colour $(repr(line_color)).",
		))
		line[:color] = _extended_colour(who, "line_color", line_color)
	end
	has_scale && (line[:colorscale] = scale)
	kw = Dict{Symbol, Any}(:dimensions => dims)
	isempty(line) || (kw[:line] = attr(; line...))
	return parcoords(; kw...)
end

# Parcoords draws its dimension labels above the plot area, in the band the
# figure title uses. With a title, the top margin is raised to hold both: the
# label line and the title line (font size `f`, default 12 px; the title is
# drawn 1.4× larger by plotly's default template) plus padding. The values
# were tuned on renders at 700×500 px with fontsize 12 and 20.
function _parcoords_title_margin!(fig, fontsize::Real)
	font = fontsize > 0 ? Float64(fontsize) : 12.0
	needed = ceil(Int, 56 + 2 * font + 1.4 * font + 8)
	layout = _plot_layout(fig)
	margin = _symbol_dict(get(layout.fields, :margin, nothing))
	current = get(margin, :t, nothing)
	current isa Real && current >= needed && return nothing
	margin[:t] = needed
	relayout!(fig, margin = attr(; margin...))
	return nothing
end

"""
	plot_parcoords(dimensions; line_color=nothing, colorscale="", title="",
		width=0, height=0, fontsize=0, show=false)

Parallel-coordinates plot: one vertical axis per dimension and one line per
row through the row's values.

# Arguments
- `dimensions::AbstractVector`: `"label" => values` Pairs (`\$…\$` math in
  the label is drawn as Unicode with sub/superscripts; `values` is a vector,
  stored without copying, or any iterable, which is collected), or raw plotly
  `attr(label = …, values = …, range = …)`
  dimensions (passed through unchanged). All dimensions need the same number
  of values (rows).

# Keywords
- `line_color = nothing`: a numeric vector with one value per row (mapped
  through `colorscale`), or a single colour (String or Symbol) for every line.
- `colorscale = ""`: a colormap name (matplotlib/plotly.py orientation,
  case-insensitive, `_r` reverses; unknown names throw), a vector of colours or
  `(t, colour)` stops, or a `ColorScheme`; needs a numeric `line_color`.
- `title::AbstractString = ""`: figure title (mathtext). The top margin is
  raised so the title clears the dimension labels.
- `width::Real = 0`, `height::Real = 0`, `fontsize::Real = 0`,
  `show::Bool = false`: as for [`plot_pie`](@ref).

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_parcoords(["mass (kg)" => [1.2, 3.4, 2.2], "speed" => [10, 4, 7]];
	line_color = [1.2, 3.4, 2.2], colorscale = "viridis", title = "Trade-offs")
```
"""
function plot_parcoords(
	dimensions::AbstractVector;
	line_color = nothing,
	colorscale = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	who = "plot_parcoords"
	trace = _parcoords_trace(who, dimensions; line_color = line_color, colorscale = colorscale)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	fig = Plot(trace, Layout())
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = true,
	)
	isempty(title_text) || _parcoords_title_margin!(fig, fontsize)
	return _extended_maybe_show(fig, show, width, height, title)
end

"""
	plot_parcoords!(fig, dimensions; line_color=nothing, colorscale="",
		title="", width=0, height=0, fontsize=0)
	plot_parcoords!(sf::SubplotFigure, dimensions; row=nothing, col=nothing, kwargs...)

Append a parallel-coordinates trace to `fig` (`Plot`/`SyncPlot`), or to the
`domain` cell `row`, `col` of a `SubplotFigure` (default: the active cell).
Arguments and keywords as for [`plot_parcoords`](@ref) without `show` (an
`ArgumentError`); see [`plot_pie!`](@ref) for the figure-level options.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = Plot()
plot_parcoords!(fig, ["a" => [1, 2, 3], "b" => [3, 1, 2]]; line_color = "teal")
```
"""
function plot_parcoords!(
	fig,
	dimensions::AbstractVector;
	line_color = nothing,
	colorscale = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_parcoords!"
	_extended_mutator_guard(who, show, row, col)
	trace = _parcoords_trace(who, dimensions; line_color = line_color, colorscale = colorscale)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	push!(_plot_data(fig), trace)
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	isempty(title_text) || _parcoords_title_margin!(fig, fontsize)
	_refresh!(fig)
	return nothing
end

function plot_parcoords!(
	sf::SubplotFigure,
	dimensions::AbstractVector;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_parcoords!, dimensions; row = row, col = col, kwargs...)
end

# ── Ternary scatter ──────────────────────────────────────────────────

const _EXTENDED_TERNARY_MODE_FLAGS = ("lines", "markers", "text")

function _extended_scatter_mode(who::AbstractString, mode::AbstractString)
	mode == "none" && return String(mode)
	flags = split(mode, '+')
	for flag in flags
		flag in _EXTENDED_TERNARY_MODE_FLAGS || throw(ArgumentError(
			"$(who): `mode` must combine \"lines\", \"markers\" and \"text\" with " *
			"\"+\", or be \"none\"; got $(repr(mode)).",
		))
	end
	allunique(flags) || throw(ArgumentError("$(who): `mode` repeats a flag; got $(repr(mode))."))
	return String(mode)
end

function _ternary_trace(
	who::AbstractString,
	a,
	b,
	c;
	mode::AbstractString,
	color,
	legend::AbstractString,
	marker_size,
)
	_extended_require_vector(who, "a", a)
	_extended_require_vector(who, "b", b)
	_extended_require_vector(who, "c", c)
	_extended_require_nonempty(who, "a", a)
	n = length(a)
	_extended_check_length(who, "b", b, "a", n)
	_extended_check_length(who, "c", c, "a", n)
	for (name, values) in (("a", a), ("b", b), ("c", c))
		_extended_check_numbers(who, name, values; nonnegative = true, gaps = true)
	end
	for (position, (va, vb, vc)) in enumerate(zip(a, b, c))
		(_extended_is_gap(va) || _extended_is_gap(vb) || _extended_is_gap(vc)) && continue
		va + vb + vc > 0 || throw(ArgumentError(
			"$(who): point $(position) is (0, 0, 0); a composition needs a positive sum.",
		))
	end
	checked_mode = _extended_scatter_mode(who, mode)
	kw = Dict{Symbol, Any}(:a => a, :b => b, :c => c, :mode => checked_mode)
	marker = Dict{Symbol, Any}()
	if color isa AbstractVector
		isempty(color) ||
			(marker[:color] = _extended_colour_vector(who, "color", color, n, "a"; numbers = true))
	else
		colour = _extended_colour(who, "color", color)
		if !isempty(colour)
			marker[:color] = colour
			occursin("lines", checked_mode) && (kw[:line] = attr(color = colour))
		end
	end
	if marker_size isa AbstractVector
		_extended_check_length(who, "marker_size", marker_size, "a", n)
		_extended_check_numbers(who, "marker_size", marker_size; nonnegative = true)
		marker[:size] = marker_size
	else
		(_extended_is_real(marker_size) && isfinite(marker_size) && marker_size >= 0) || throw(ArgumentError(
			"$(who): `marker_size` must be a non-negative number (0 = plotly default) " *
			"or a vector of them; got $(repr(marker_size)).",
		))
		marker_size > 0 && (marker[:size] = marker_size)
	end
	isempty(marker) || (kw[:marker] = attr(; marker...))
	name = _extended_label(legend, who, "legend")
	isempty(name) || (kw[:name] = name)
	return scatterternary(; kw...)
end

# Corner titles of the ternary subplot, merged into `layout.ternary` so
# existing axis styling (title font, ticks) is kept. `labels` are `_label`
# results; empty ones are skipped.
function _apply_ternary_labels!(
	fig;
	alabel::AbstractString = "",
	blabel::AbstractString = "",
	clabel::AbstractString = "",
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

_ternary_axis_labels(who::AbstractString; alabel, blabel, clabel) = (
	alabel = _extended_label(alabel, who, "alabel"),
	blabel = _extended_label(blabel, who, "blabel"),
	clabel = _extended_label(clabel, who, "clabel"),
)

"""
	plot_ternary(a, b, c; mode="markers", color="", legend="", marker_size=0,
		alabel="", blabel="", clabel="", title="", width=0, height=0,
		fontsize=0, show=false)

Ternary scatter plot of three-part compositions `(a[i], b[i], c[i])`. Plotly
normalises each point to `a + b + c = 1`.

# Arguments
- `a`, `b`, `c::AbstractVector`: the components (non-negative finite numbers,
  same length, each point with a positive sum; `missing`, `nothing` or NaN
  leave a gap). Stored without copying.

# Keywords
- `mode::AbstractString = "markers"`: `"markers"`, `"lines"`, `"text"`
  combined with `+`, or `"none"`.
- `color::Union{AbstractString,Symbol,AbstractVector} = ""`: colour of the
  markers (and lines), or one colour or number per point (`""` = colorway).
- `legend::AbstractString = ""`: legend name of the trace (mathtext).
- `marker_size::Union{Real,AbstractVector} = 0`: marker size in px, or one per
  point (`0` = plotly default).
- `alabel`, `blabel`, `clabel::AbstractString = ""`: titles of the a, b and c
  corners (mathtext).
- `title::AbstractString = ""`, `width::Real = 0`, `height::Real = 0`,
  `fontsize::Real = 0`, `show::Bool = false`: as for [`plot_pie`](@ref).

The active [`PlotStyle`](@ref) fills unset line widths, dashes, marker sizes
and symbols, as for [`plot_scatter`](@ref). Empty or mismatched components
throw an `ArgumentError`.

# Returns
A `Plot`, or a `SyncPlot` when `show = true`.

# Example
```julia
fig = plot_ternary([0.6, 0.2, 0.1], [0.3, 0.5, 0.2], [0.1, 0.3, 0.7];
	alabel = "Sand", blabel = "Silt", clabel = "Clay", marker_size = 10)
```
"""
function plot_ternary(
	a::Union{AbstractVector, SubArray},
	b::Union{AbstractVector, SubArray},
	c::Union{AbstractVector, SubArray};
	mode::AbstractString = "markers",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::AbstractString = "",
	marker_size::Union{Real, AbstractVector} = 0,
	alabel::AbstractString = "",
	blabel::AbstractString = "",
	clabel::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
)
	who = "plot_ternary"
	trace = _ternary_trace(who, a, b, c; mode = mode, color = color, legend = legend, marker_size = marker_size)
	corner = _ternary_axis_labels(who; alabel = alabel, blabel = blabel, clabel = clabel)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	fig = Plot(trace, Layout())
	# The default `mode` has no lines, so a mode with lines was chosen by
	# the caller and the style's `:dash_marker` cycle must not add markers.
	_apply_style_trace_defaults!(fig, 1; explicit = (:mode,))
	_apply_ternary_labels!(fig; corner...)
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = true,
	)
	return _extended_maybe_show(fig, show, width, height, title)
end

"""
	plot_ternary!(fig, a, b, c; mode="markers", color="", legend="",
		marker_size=0, alabel="", blabel="", clabel="", title="", width=0,
		height=0, fontsize=0)
	plot_ternary!(sf::SubplotFigure, a, b, c; row=nothing, col=nothing, kwargs...)

Append a ternary scatter trace to `fig` (`Plot`/`SyncPlot`), or to the
`ternary` cell `row`, `col` of a `SubplotFigure` (default: the active cell).
Arguments and keywords as for [`plot_ternary`](@ref) without `show` (an
`ArgumentError`); non-empty corner titles replace the current ones and keep
their styling. See [`plot_pie!`](@ref) for the figure-level options.

# Returns
`nothing` for a `Plot`/`SyncPlot`, `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_ternary([0.2, 0.3], [0.3, 0.4], [0.5, 0.3]; legend = "batch 1")
plot_ternary!(fig, [0.4, 0.1], [0.2, 0.6], [0.4, 0.3]; legend = "batch 2")
```
"""
function plot_ternary!(
	fig,
	a::Union{AbstractVector, SubArray},
	b::Union{AbstractVector, SubArray},
	c::Union{AbstractVector, SubArray};
	mode::AbstractString = "markers",
	color::Union{AbstractString, Symbol, AbstractVector} = "",
	legend::AbstractString = "",
	marker_size::Union{Real, AbstractVector} = 0,
	alabel::AbstractString = "",
	blabel::AbstractString = "",
	clabel::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "plot_ternary!"
	_extended_mutator_guard(who, show, row, col)
	trace = _ternary_trace(who, a, b, c; mode = mode, color = color, legend = legend, marker_size = marker_size)
	corner = _ternary_axis_labels(who; alabel = alabel, blabel = blabel, clabel = clabel)
	title_text = _extended_label(title, who, "title")
	_extended_validate_sizes(who; width = width, height = height, fontsize = fontsize)
	push!(_plot_data(fig), trace)
	_apply_style_trace_defaults!(fig, length(_plot_data(fig)); explicit = (:mode,))
	_apply_ternary_labels!(fig; corner...)
	_extended_apply_figure_options!(
		fig,
		who;
		title = title_text,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	_refresh!(fig)
	return nothing
end

function plot_ternary!(
	sf::SubplotFigure,
	a::Union{AbstractVector, SubArray},
	b::Union{AbstractVector, SubArray},
	c::Union{AbstractVector, SubArray};
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	kwargs...,
)
	return _subplot_delegate_mutator!(sf, plot_ternary!, a, b, c; row = row, col = col, kwargs...)
end

# ── Image ────────────────────────────────────────────────────────────

const _IMAGE_COLORMODELS = ("rgb", "rgba", "rgba256", "hsl", "hsla")

_image_colormodel_channels(model::AbstractString) =
	model in ("rgb", "hsl") ? 3 : 4

_image_sequence(value) = value isa AbstractVector || value isa Tuple

# Present an H×W×C numeric array in Plotly's row/pixel/channel JSON order
# without materializing one heap object per pixel/channel. PlotlyBase's JSON
# lowering reverses Julia array dimensions, so this lazy C×W×H permutation
# serializes identically to a nested H×W×C vector. Already-nested rows of
# pixels are validated and passed through unchanged.
function _image_z(z; who::AbstractString = "plot_image")
	if ndims(z) == 3
		channels = size(z, 3)
		channels in (3, 4) || throw(ArgumentError(
			"$(who): an H×W×C image must have 3 (RGB) or 4 (RGBA) channels; " *
			"got C=$channels.",
		))
		return PermutedDimsArray(z, (3, 2, 1))
	end
	return _image_nested(z, who).data
end

const _IMAGE_FORMS =
	"an H×W×3 (RGB) or H×W×4 (RGBA) array of channel values, a matrix of " *
	"Colors.jl colours, a matrix of pixel vectors, or nested rows of pixel vectors"

# Validate nested rows of pixels (`z[row][column][channel]`).
function _image_nested(rows, who::AbstractString)
	(rows isa AbstractVector && !isempty(rows)) || throw(ArgumentError(
		"$(who): image data must be $(_IMAGE_FORMS); got $(summary(rows)).",
	))
	first(rows) isa Real && throw(ArgumentError(
		"$(who): a vector of numbers is not an image; expected $(_IMAGE_FORMS).",
	))
	width = -1
	channels = -1
	bytes = true
	for (i, row) in enumerate(rows)
		_image_sequence(row) || throw(ArgumentError(
			"$(who): nested image rows must be vectors of pixels; row $(i) is " *
			"$(repr(row)).",
		))
		if width < 0
			width = length(row)
			width > 0 || throw(ArgumentError("$(who): image row 1 has no pixels."))
		elseif length(row) != width
			throw(ArgumentError(
				"$(who): every image row must have the same number of pixels; " *
				"row 1 has $(width), row $(i) has $(length(row)).",
			))
		end
		for (j, pixel) in enumerate(row)
			_image_sequence(pixel) || throw(ArgumentError(
				"$(who): pixel ($(i), $(j)) must be a vector of 3 or 4 channel " *
				"values; got $(repr(pixel)).",
			))
			n = length(pixel)
			n in (3, 4) || throw(ArgumentError(
				"$(who): pixel ($(i), $(j)) has $(n) channels; expected 3 (RGB) " *
				"or 4 (RGBA).",
			))
			if channels < 0
				channels = n
			elseif n != channels
				throw(ArgumentError(
					"$(who): every pixel needs the same number of channels; " *
					"pixel (1, 1) has $(channels), pixel ($(i), $(j)) has $(n).",
				))
			end
			for value in pixel
				(value isa Real && !(value isa Bool)) || throw(ArgumentError(
					"$(who): pixel channels must be real numbers; pixel " *
					"($(i), $(j)) has $(repr(value)).",
				))
				value isa UInt8 || (bytes = false)
			end
		end
	end
	return (
		kind = :nested,
		data = rows,
		channels = channels,
		bytes = bytes,
		height = length(rows),
		width = width,
	)
end

# H×W×C bytes of a matrix of Colors.jl colours (`img[row, column]`, row 1 at
# the top). Colours with alpha keep it (C = 4).
function _image_from_colorants(z, who::AbstractString)
	isempty(z) && throw(ArgumentError("$(who): the image is empty."))
	alpha = eltype(z) <: Colors.TransparentColor
	for pixel in z
		pixel isa Colors.Colorant || throw(ArgumentError(
			"$(who): a colour image must contain only Colors.jl colours; got " *
			"$(repr(pixel)).",
		))
		alpha |= pixel isa Colors.TransparentColor
	end
	channels = alpha ? 4 : 3
	data = Array{UInt8}(undef, size(z, 1), size(z, 2), channels)
	for (j, column) in enumerate(axes(z, 2)), (i, row) in enumerate(axes(z, 1))
		c = convert(Colors.RGBA{Float64}, z[row, column])
		data[i, j, 1] = _channel_byte(Float64(Colors.red(c)))
		data[i, j, 2] = _channel_byte(Float64(Colors.green(c)))
		data[i, j, 3] = _channel_byte(Float64(Colors.blue(c)))
		alpha && (data[i, j, 4] = _channel_byte(Float64(Colors.alpha(c))))
	end
	return (
		kind = :array3,
		data = data,
		channels = channels,
		bytes = true,
		height = size(z, 1),
		width = size(z, 2),
	)
end

# Validate plot_image input and describe it (see `_IMAGE_FORMS`).
function _image_source(z, who::AbstractString)
	if ndims(z) == 3
		size(z, 3) in (3, 4) || throw(ArgumentError(
			"$(who): an H×W×C image must have 3 (RGB) or 4 (RGBA) channels; " *
			"got C=$(size(z, 3)).",
		))
		(size(z, 1) > 0 && size(z, 2) > 0) ||
			throw(ArgumentError("$(who): the image is empty; got size $(size(z))."))
		T = eltype(z)
		T <: Complex && throw(_field2d_complex_error(who, "z"))
		if !(T <: Real && !(T <: Bool) && isconcretetype(T))
			for value in z
				value isa Complex && throw(_field2d_complex_error(who, "z"))
				(value isa Real && !(value isa Bool)) || throw(ArgumentError(
					"$(who): channel values must be real numbers; got $(repr(value)).",
				))
			end
		end
		return (
			kind = :array3,
			data = z,
			channels = size(z, 3),
			bytes = T === UInt8,
			height = size(z, 1),
			width = size(z, 2),
		)
	elseif ndims(z) == 2
		(!isempty(z) && all(pixel -> pixel isa Colors.Colorant, z)) &&
			return _image_from_colorants(z, who)
		if !isempty(z) && all(_image_sequence, z)
			rows = [
				[collect(z[row, column]) for column in axes(z, 2)]
				for row in axes(z, 1)
			]
			return _image_nested(rows, who)
		end
		throw(ArgumentError(
			"$(who): a 2-D matrix of numbers is not an image; plot scalar data " *
			"with plot_heatmap(z), or pass $(_IMAGE_FORMS).",
		))
	elseif ndims(z) == 1
		return _image_nested(z, who)
	end
	throw(ArgumentError(
		"$(who): image data must be $(_IMAGE_FORMS); got a $(ndims(z))-D " *
		"array of size $(size(z)).",
	))
end

# `colormodel = ""` picks rgb for three channels and, for four channels,
# "rgba256" (alpha 0-255) for 8-bit data or "rgba" (alpha 0-1) otherwise, so
# the alpha channel is never dropped.
function _image_colormodel(colormodel, source, who::AbstractString)
	(colormodel isa Symbol || colormodel isa AbstractString) || throw(ArgumentError(
		"$(who): `colormodel` must be a string; got $(repr(colormodel)).",
	))
	model = lowercase(strip(String(colormodel)))
	if isempty(model)
		source.channels == 4 || return ""
		return source.bytes ? "rgba256" : "rgba"
	end
	model in _IMAGE_COLORMODELS || throw(ArgumentError(
		"$(who): `colormodel` must be one of $(join(repr.(_IMAGE_COLORMODELS), ", ")) " *
		"or \"\" (automatic); got $(repr(colormodel)).",
	))
	expected = _image_colormodel_channels(model)
	expected == source.channels || throw(ArgumentError(
		"$(who): colormodel $(repr(model)) needs $(expected) channels per pixel; " *
		"the image has $(source.channels).",
	))
	return model
end

# Pixel placement for `extent = (left, right, bottom, top)` (matplotlib's
# imshow convention): pixel edges span the extent, column 1 starts at `left`,
# row 1 lies at `top` (origin "upper") or `bottom` (origin "lower"). plotly
# places pixel (r, c) at (x0 + c dx, y0 + r dy) with positive steps, so a
# decreasing direction is expressed by reversing the rows/columns.
function _image_placement(extent, origin::AbstractString, height::Int, width::Int, who::AbstractString)
	((extent isa Tuple || extent isa AbstractVector) && length(extent) == 4) ||
		throw(ArgumentError(
			"$(who): `extent` must be (left, right, bottom, top); got $(repr(extent)).",
		))
	left, right, bottom, top = _checked_real_vector(extent, who, "extent")
	left == right && throw(ArgumentError(
		"$(who): `extent` needs left != right; got $(repr(extent)).",
	))
	bottom == top && throw(ArgumentError(
		"$(who): `extent` needs bottom != top; got $(repr(extent)).",
	))
	sx = (right - left) / width
	start_y = origin == "upper" ? top : bottom
	sy = (origin == "upper" ? bottom - top : top - bottom) / height
	return (
		x0 = sx > 0 ? left + sx / 2 : right + abs(sx) / 2,
		dx = abs(sx),
		flip_columns = sx < 0,
		y0 = sy > 0 ? start_y + sy / 2 : start_y + height * sy + abs(sy) / 2,
		dy = abs(sy),
		flip_rows = sy < 0,
		x_reversed = right < left,
		y_reversed = top < bottom,
	)
end

function _image_flip(source, flip_rows::Bool, flip_columns::Bool)
	if source.kind === :array3
		rows = flip_rows ? reverse(axes(source.data, 1)) : axes(source.data, 1)
		columns = flip_columns ? reverse(axes(source.data, 2)) : axes(source.data, 2)
		return (flip_rows || flip_columns) ?
			view(source.data, rows, columns, :) :
			source.data
	end
	rows = flip_rows ? reverse(source.data) : source.data
	return flip_columns ? [reverse(row) for row in rows] : rows
end

# ── `interpolation = :bilinear` images (G67) ──
# plotly.js 2.35.2 (traces/image/plot.js) smooths an image only when it is a
# `source` URL: its `_realImage` path needs zsmooth "fast", `!_hasZ`,
# `_hasSource` and linear axes, and then lets the renderer scale one <image>.
# A `z` image is always painted as one flat rectangle per pixel, whatever
# `zsmooth` says. A bilinear image is therefore sent as an 8-bit RGBA PNG data
# URI, its pixels converted exactly as plotly converts `z` (default
# zmin/zmax: channel values clamped to the colour model's range).

# Channel `k` of pixel (`r`, `c`) (1-based positions) of flipped image data.
function _image_channel(data, kind::Symbol, r::Int, c::Int, k::Int)
	if kind === :array3
		return data[axes(data, 1)[r], axes(data, 2)[c], axes(data, 3)[k]]
	end
	row = data[firstindex(data) + r - 1]
	pixel = row[firstindex(row) + c - 1]
	return pixel[firstindex(pixel) + k - 1]
end

_image_byte(v::Float64) = round(UInt8, clamp(v, 0.0, 255.0))

# H×W image data in plotly colour model `model` ("" is plotly's default for a
# `z` image, "rgb") as a 4×W×H array of RGBA bytes, the PNG scanline order. A
# pixel with a non-finite channel has no colour plotly could draw, so it is
# left fully transparent.
function _image_rgba_bytes(source, data, model::AbstractString)
	model = isempty(model) ? "rgb" : model
	height, width = source.height, source.width
	out = zeros(UInt8, 4, width, height)
	hsl = startswith(model, "hsl")
	# rgba256 carries alpha in 0..255; rgba and hsla in 0..1.
	alpha_scale = model == "rgba256" ? 1.0 : 255.0
	has_alpha = _image_colormodel_channels(model) == 4
	for r in 1:height, c in 1:width
		v1 = Float64(_image_channel(data, source.kind, r, c, 1))
		v2 = Float64(_image_channel(data, source.kind, r, c, 2))
		v3 = Float64(_image_channel(data, source.kind, r, c, 3))
		a = has_alpha ? Float64(_image_channel(data, source.kind, r, c, 4)) * alpha_scale : 255.0
		(isfinite(v1) && isfinite(v2) && isfinite(v3) && isfinite(a)) || continue
		if hsl
			# plotly's hsl model: hue 0..360, saturation and lightness 0..100 (%).
			rgb = convert(Colors.RGB{Float64}, Colors.HSL{Float64}(
				clamp(v1, 0.0, 360.0),
				clamp(v2, 0.0, 100.0) / 100,
				clamp(v3, 0.0, 100.0) / 100,
			))
			out[1, c, r] = _image_byte(255 * Float64(Colors.red(rgb)))
			out[2, c, r] = _image_byte(255 * Float64(Colors.green(rgb)))
			out[3, c, r] = _image_byte(255 * Float64(Colors.blue(rgb)))
		else
			out[1, c, r] = _image_byte(v1)
			out[2, c, r] = _image_byte(v2)
			out[3, c, r] = _image_byte(v3)
		end
		out[4, c, r] = _image_byte(a)
	end
	return out
end

# Adler-32 of `bytes` (RFC 1950 §8.2), reducing every 5552 bytes: the largest
# run whose sums cannot overflow 32 bits (zlib's NMAX).
function _image_adler32(bytes::AbstractVector{UInt8})
	a = UInt32(1)
	b = UInt32(0)
	n = length(bytes)
	i = 1
	@inbounds while i <= n
		stop = min(n, i + 5551)
		for j in i:stop
			a += bytes[j]
			b += a
		end
		a %= UInt32(65521)
		b %= UInt32(65521)
		i = stop + 1
	end
	return (b << 16) | a
end

function _image_png_chunk!(io::IO, type::String, payload::AbstractVector{UInt8})
	tag = Vector{UInt8}(codeunits(type))
	write(io, _be_u32(length(payload)), tag, payload)
	write(io, _be_u32(_crc32(payload, _crc32(tag))))
	return io
end

# An 8-bit RGBA PNG of `rgba` (4×W×H). The zlib stream uses stored (level 0)
# deflate blocks: exact, dependency-free, and still smaller than the JSON
# `z` arrays it replaces.
function _image_png(rgba::Array{UInt8, 3})
	width, height = size(rgba, 2), size(rgba, 3)
	stride = 4 * width
	raw = Vector{UInt8}(undef, height * (stride + 1))
	for r in 1:height
		start = (r - 1) * (stride + 1)
		raw[start + 1] = 0x00 # filter type None
		copyto!(raw, start + 2, rgba, (r - 1) * stride + 1, stride)
	end
	zlib = IOBuffer()
	write(zlib, 0x78, 0x01) # deflate, 32 KiB window, no preset dictionary
	n = length(raw)
	position = 1
	while position <= n
		len = min(0xffff, n - position + 1)
		write(zlib, position + len > n ? 0x01 : 0x00) # BFINAL, BTYPE = stored
		write(zlib, UInt8(len & 0xff), UInt8(len >> 8))
		write(zlib, UInt8(~len & 0xff), UInt8((~len >> 8) & 0xff))
		write(zlib, view(raw, position:(position + len - 1)))
		position += len
	end
	write(zlib, _be_u32(_image_adler32(raw)))
	png = IOBuffer()
	write(png, _PNG_SIGNATURE)
	# Bit depth 8, colour type 6 (RGBA), deflate, adaptive filtering, no interlace.
	_image_png_chunk!(png, "IHDR", vcat(_be_u32(width), _be_u32(height), UInt8[8, 6, 0, 0, 0]))
	_image_png_chunk!(png, "IDAT", take!(zlib))
	_image_png_chunk!(png, "IEND", UInt8[])
	return take!(png)
end

_image_png_uri(source, data, model::AbstractString) =
	"data:image/png;base64," * Base64.base64encode(_image_png(_image_rgba_bytes(source, data, model)))

function _image_add!(
	fig,
	who::AbstractString,
	z;
	constructor::Bool,
	colormodel,
	extent,
	origin,
	xlabel::AbstractString,
	ylabel::AbstractString,
	title::AbstractString,
	xrange,
	yrange,
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
	tight,
	interpolation = :nearest,
)
	xrange = _field2d_checked_range(xrange, who, "xrange")
	yrange = _field2d_checked_range(yrange, who, "yrange")
	_field2d_validate_cartesian(
		fig,
		who;
		xrange = xrange,
		yrange = yrange,
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
	)
	tight_value = _field2d_bool(tight, who, "tight")
	zsmooth = _field2d_zsmooth(interpolation, who; image = true)
	origin_value = _field2d_origin(origin, who; allow_unset = !constructor)
	source = _image_source(z, who)
	model = _image_colormodel(colormodel, source, who)
	placement = extent === nothing ? nothing : _image_placement(
		extent,
		isempty(origin_value) ? "upper" : origin_value,
		source.height,
		source.width,
		who,
	)
	data = placement === nothing ? source.data :
		_image_flip(source, placement.flip_rows, placement.flip_columns)
	fields = Dict{Symbol, Any}()
	if zsmooth === nothing
		fields[:z] = source.kind === :array3 ? _image_z(data; who = who) : data
		isempty(model) || (fields[:colormodel] = model)
	else
		# A smoothed image must be a `source` (see `_image_png_uri`); plotly
		# reads it as "rgba256" and ignores `colormodel`.
		fields[:source] = _image_png_uri(source, data, model)
	end
	if placement !== nothing
		fields[:x0] = placement.x0
		fields[:dx] = placement.dx
		fields[:y0] = placement.y0
		fields[:dy] = placement.dy
	end
	zsmooth === nothing || (fields[:zsmooth] = zsmooth)
	_field2d_mark_field!(fields, tight_value)

	first_new = length(_plot_data(fig)) + 1
	push!(_plot_data(fig), image(; fields...))
	_field2d_apply_options!(
		fig,
		who;
		constructor = constructor,
		title = title,
		xlabel = xlabel,
		ylabel = ylabel,
		xscale = "",
		yscale = "",
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
		partial_ranges = false,
	)
	# plotly reverses the y axis of an image by default; write the direction
	# explicitly so the extent / origin hold.
	if placement !== nothing
		_field2d_axis_direction!(fig, :x, placement.x_reversed; force = true)
		_field2d_axis_direction!(fig, :y, placement.y_reversed; force = true)
	elseif !isempty(origin_value)
		_field2d_axis_direction!(fig, :y, origin_value == "upper"; force = true)
	end
	# One-sided limits (D11) after the direction, so the fixed bound lands in
	# the slot of the image's direction; a y axis that states no direction is
	# drawn reversed by plotly for an image.
	_field2d_apply_partial_range!(fig, :xaxis, xrange; who = who)
	_field2d_apply_partial_range!(fig, :yaxis, yrange; implicit_reversed = true, who = who)
	_field2d_finish!(fig, first_new)
	return nothing
end

"""
	plot_image(z; kwargs...)

Display an image. `z` is one of
- an `H×W×3` (RGB) or `H×W×4` (RGBA) array of channel values, `z[row,
  column, channel]` (row 1 is the top row with the default `origin`);
- a matrix of Colors.jl colours (`img[row, column]`, e.g. from Images.jl),
  converted to 8-bit RGB, or RGBA when the colours carry alpha;
- a matrix of pixel vectors, or nested rows of pixels `z[row][column]` with 3
  or 4 channels each.
Channel values follow plotly's convention: 0-255 for RGB (scale `[0, 1]` float
data by 255). A 4-channel image uses `colormodel = "rgba256"` (alpha also
0-255) when the data are `UInt8` and `"rgba"` (alpha in 0-1) otherwise, so the
alpha channel is kept. A 2-D matrix of numbers is not an image (use
[`plot_heatmap`](@ref)); 1-D, 4-D, 2-channel, complex or empty data throw an
`ArgumentError`.

#### Keywords
- `colormodel = ""`: `"rgb"`, `"rgba"`, `"rgba256"`, `"hsl"` or `"hsla"`;
  must match the channel count; `""` chooses as above.
- `extent = nothing`: `(left, right, bottom, top)` in data units: the image
  spans these pixel edges (matplotlib's `imshow(extent=...)`); a reversed pair
  (`right < left`, `top < bottom`) reverses that axis. Without `extent` pixel
  `(row, column)` is centred at x = column - 1, y = row - 1.
- `origin = :upper`: row 1 at the top (`:lower`: at the bottom, y axis
  pointing up).
- `equalar::Bool = true`: square pixels (equal data aspect).
- `tight::Bool = true`: autoranged axes fit the image's pixel edges without
  padding; `false` restores plotly's padded autorange (as for
  [`plot_heatmap`](@ref)).
- `interpolation = :nearest`: `:nearest` draws crisp square pixels;
  `:bilinear` lets the renderer smooth the image when it is scaled, as
  matplotlib's `imshow(interpolation = "bilinear")`. plotly.js smooths only
  an image given as a picture, so a bilinear image is sent as an 8-bit RGBA
  PNG (trace `source`, `zsmooth = "fast"`; channel values are converted from
  `colormodel` and clamped to its range, a pixel with a non-finite channel is
  transparent, and the hover shows the RGBA bytes). The smoothing needs
  linear axes; on a log axis plotly draws the pixels flat.
- `xlabel = ""`, `ylabel = ""`, `title = ""`, `xrange = [0, 0]`,
  `yrange = [0, 0]` (data units; `[0, 0]`/`nothing` automatic; a one-sided
  `(lo, nothing)`/`(nothing, hi)` fixes one bound and, as plotly.js
  re-ranges an image's aspect-constrained axes, fixes the other at the
  image's current extent, as matplotlib's `set_xlim` does). The image
  keeps its orientation: with `origin = :upper` (or a reversed `extent`) the
  bounds of an explicit range are reordered so that axis still points down
  (left), e.g. `yrange = (0, 2)` is written as `[2, 0]`. `xticks`,
  `xticklabels`, `xtickformat`, `yticks`, `yticklabels`, `ytickformat`,
  `grid::Union{Nothing,Bool,Symbol} = true`, `width = 0`, `height = 0`,
  `fontsize = 0`: as for [`plot_heatmap`](@ref).
- `show::Bool = false`: open a window and return a `SyncPlot`.

Returns a `Plot` (a `SyncPlot` when `show = true`).

# Example
```julia
img = zeros(UInt8, 20, 30, 4)              # H×W×RGBA
img[:, :, 1] .= 255                        # red
img[:, :, 4] .= repeat(UInt8.(round.(range(0, 255; length = 30)))', 20)
fig = plot_image(img; extent = (0, 3, 0, 2), xlabel = "x (mm)", ylabel = "y (mm)")
```
"""
function plot_image(
	z::AbstractArray;
	colormodel::Union{Symbol, AbstractString} = "",
	extent = nothing,
	origin::Union{Symbol, AbstractString} = :upper,
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
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
	equalar::Bool = true,
	tight = true,
	interpolation = :nearest,
	show::Bool = false,
)
	fig = _field2d_new_figure()
	_image_add!(
		fig,
		"plot_image",
		z;
		constructor = true,
		colormodel = colormodel,
		extent = extent,
		origin = origin,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = xrange,
		yrange = yrange,
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
		tight = tight,
		interpolation = interpolation,
	)
	return _field2d_show(fig, show, width, height, title)
end

"""
	plot_image!(fig, z; kwargs...)
	plot_image!(sf::SubplotFigure, z; row = nothing, col = nothing, secondary_y = false, inset = nothing, kwargs...)

Append an image (same data forms and keywords as [`plot_image`](@ref), except
`show`, which throws an `ArgumentError`) to `fig`, a `Plot` or `SyncPlot`, or
to a cell of a `SubplotFigure` (`row`/`col` together, default: the active
cell; `secondary_y` targets the cell's secondary y axis; `inset = k` targets
the `k`-th inset from [`inset!`](@ref); `xrange`/`yrange` act as for
[`plot_heatmap!`](@ref); `interpolation = :bilinear` smooths the image as
for [`plot_image`](@ref)). `origin = ""`
(default) keeps the y-axis direction (plotly shows an
image's first row at the top unless the axis direction was set); `:upper` /
`:lower` set it, and an `extent` sets both axis directions. `grid = nothing`
keeps the grid. On a `SubplotFigure`, `title`, `width` and `height` are
ignored with a warning.

Invalid input throws an `ArgumentError` and leaves the figure unchanged.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_heatmap(0:9, 0:9, rand(10, 10))
plot_image!(fig, fill(UInt8(200), 2, 2, 3); extent = (2, 4, 2, 4))
```
"""
function plot_image!(
	fig,
	z::AbstractArray;
	colormodel::Union{Symbol, AbstractString} = "",
	extent = nothing,
	origin::Union{Symbol, AbstractString} = "",
	xlabel::AbstractString = "",
	ylabel::AbstractString = "",
	title::AbstractString = "",
	xrange = [0, 0],
	yrange = [0, 0],
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
	equalar::Bool = true,
	tight = true,
	interpolation = :nearest,
	kwargs...,
)
	_field2d_reject_keywords("plot_image!", kwargs)
	_image_add!(
		fig,
		"plot_image!",
		z;
		constructor = false,
		colormodel = colormodel,
		extent = extent,
		origin = origin,
		xlabel = xlabel,
		ylabel = ylabel,
		title = title,
		xrange = xrange,
		yrange = yrange,
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
		tight = tight,
		interpolation = interpolation,
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

# Top-level trace attributes of the map trace types, as the bundled plotly.js
# 2.35.2 (the `plotlyjs` artifact in Artifacts.toml) lists them in
# `Plotly.PlotSchema.get().traces[kind].attributes` (`_deprecated` dropped).
# The `trace` keyword of the map constructors and mutators holds raw trace
# attributes; a name outside this list was silently ignored by plotly.js, so
# a typo, a layout key or a keyword of another plotting function went
# unnoticed. Keep the list in step with the bundled plotly.js when it is
# upgraded.
const _MAP_TRACE_ATTRIBUTE_NAMES = Dict{String,Set{String}}(
	"choropleth" => Set{String}([
		"autocolorscale", "coloraxis", "colorbar", "colorscale", "customdata",
		"customdatasrc", "featureidkey", "geo", "geojson", "hoverinfo", "hoverinfosrc",
		"hoverlabel", "hovertemplate", "hovertemplatesrc", "hovertext", "hovertextsrc",
		"ids", "idssrc", "legend", "legendgroup", "legendgrouptitle", "legendrank",
		"legendwidth", "locationmode", "locations", "locationssrc", "marker", "meta",
		"metasrc", "name", "reversescale", "selected", "selectedpoints", "showlegend",
		"showscale", "stream", "text", "textsrc", "transforms", "uid", "uirevision",
		"unselected", "visible", "z", "zauto", "zmax", "zmid", "zmin", "zsrc",
	]),
	"scattergeo" => Set{String}([
		"connectgaps", "customdata", "customdatasrc", "featureidkey", "fill",
		"fillcolor", "geo", "geojson", "hoverinfo", "hoverinfosrc", "hoverlabel",
		"hovertemplate", "hovertemplatesrc", "hovertext", "hovertextsrc", "ids",
		"idssrc", "lat", "latsrc", "legend", "legendgroup", "legendgrouptitle",
		"legendrank", "legendwidth", "line", "locationmode", "locations", "locationssrc",
		"lon", "lonsrc", "marker", "meta", "metasrc", "mode", "name", "opacity",
		"selected", "selectedpoints", "showlegend", "stream", "text", "textfont",
		"textposition", "textpositionsrc", "textsrc", "texttemplate", "texttemplatesrc",
		"transforms", "uid", "uirevision", "unselected", "visible",
	]),
	"scattermapbox" => Set{String}([
		"below", "cluster", "connectgaps", "customdata", "customdatasrc", "fill",
		"fillcolor", "hoverinfo", "hoverinfosrc", "hoverlabel", "hovertemplate",
		"hovertemplatesrc", "hovertext", "hovertextsrc", "ids", "idssrc", "lat",
		"latsrc", "legend", "legendgroup", "legendgrouptitle", "legendrank",
		"legendwidth", "line", "lon", "lonsrc", "marker", "meta", "metasrc", "mode",
		"name", "opacity", "selected", "selectedpoints", "showlegend", "stream",
		"subplot", "text", "textfont", "textposition", "textsrc", "texttemplate",
		"texttemplatesrc", "transforms", "uid", "uirevision", "unselected", "visible",
	]),
	"choroplethmapbox" => Set{String}([
		"autocolorscale", "below", "coloraxis", "colorbar", "colorscale", "customdata",
		"customdatasrc", "featureidkey", "geojson", "hoverinfo", "hoverinfosrc",
		"hoverlabel", "hovertemplate", "hovertemplatesrc", "hovertext", "hovertextsrc",
		"ids", "idssrc", "legend", "legendgroup", "legendgrouptitle", "legendrank",
		"legendwidth", "locations", "locationssrc", "marker", "meta", "metasrc", "name",
		"reversescale", "selected", "selectedpoints", "showlegend", "showscale",
		"stream", "subplot", "text", "textsrc", "transforms", "uid", "uirevision",
		"unselected", "visible", "z", "zauto", "zmax", "zmid", "zmin", "zsrc",
	]),
	"densitymapbox" => Set{String}([
		"autocolorscale", "below", "coloraxis", "colorbar", "colorscale", "customdata",
		"customdatasrc", "hoverinfo", "hoverinfosrc", "hoverlabel", "hovertemplate",
		"hovertemplatesrc", "hovertext", "hovertextsrc", "ids", "idssrc", "lat",
		"latsrc", "legend", "legendgroup", "legendgrouptitle", "legendrank",
		"legendwidth", "lon", "lonsrc", "meta", "metasrc", "name", "opacity", "radius",
		"radiussrc", "reversescale", "showlegend", "showscale", "stream", "subplot",
		"text", "textsrc", "transforms", "uid", "uirevision", "visible", "z", "zauto",
		"zmax", "zmid", "zmin", "zsrc",
	]),
	"scattermap" => Set{String}([
		"below", "cluster", "connectgaps", "customdata", "customdatasrc", "fill",
		"fillcolor", "hoverinfo", "hoverinfosrc", "hoverlabel", "hovertemplate",
		"hovertemplatesrc", "hovertext", "hovertextsrc", "ids", "idssrc", "lat",
		"latsrc", "legend", "legendgroup", "legendgrouptitle", "legendrank",
		"legendwidth", "line", "lon", "lonsrc", "marker", "meta", "metasrc", "mode",
		"name", "opacity", "selected", "selectedpoints", "showlegend", "stream",
		"subplot", "text", "textfont", "textposition", "textsrc", "texttemplate",
		"texttemplatesrc", "transforms", "uid", "uirevision", "unselected", "visible",
	]),
	"choroplethmap" => Set{String}([
		"autocolorscale", "below", "coloraxis", "colorbar", "colorscale", "customdata",
		"customdatasrc", "featureidkey", "geojson", "hoverinfo", "hoverinfosrc",
		"hoverlabel", "hovertemplate", "hovertemplatesrc", "hovertext", "hovertextsrc",
		"ids", "idssrc", "legend", "legendgroup", "legendgrouptitle", "legendrank",
		"legendwidth", "locations", "locationssrc", "marker", "meta", "metasrc", "name",
		"reversescale", "selected", "selectedpoints", "showlegend", "showscale",
		"stream", "subplot", "text", "textsrc", "transforms", "uid", "uirevision",
		"unselected", "visible", "z", "zauto", "zmax", "zmid", "zmin", "zsrc",
	]),
	"densitymap" => Set{String}([
		"autocolorscale", "below", "coloraxis", "colorbar", "colorscale", "customdata",
		"customdatasrc", "hoverinfo", "hoverinfosrc", "hoverlabel", "hovertemplate",
		"hovertemplatesrc", "hovertext", "hovertextsrc", "ids", "idssrc", "lat",
		"latsrc", "legend", "legendgroup", "legendgrouptitle", "legendrank",
		"legendwidth", "lon", "lonsrc", "meta", "metasrc", "name", "opacity", "radius",
		"radiussrc", "reversescale", "showlegend", "showscale", "stream", "subplot",
		"text", "textsrc", "transforms", "uid", "uirevision", "visible", "z", "zauto",
		"zmax", "zmid", "zmin", "zsrc",
	]),
)

# ── Map keyword plumbing (G23) ──
#
# The map constructors and mutators take named PlotlySupply keywords only
# (validated; colour scales through `_resolve_colorscale`, text through
# `_label`). Raw plotly.js trace attributes reach the trace through ONE
# explicit keyword, `trace` (an `attr(...)`, Dict or NamedTuple), whose
# attribute names are checked against the trace type. Every other keyword
# argument is an error (`_map_reject_keywords`).

# Keyword arguments no map function takes: `show` on a mutator (mutators
# never open a window), `row`/`col` on a single figure (the SubplotFigure
# methods take them out before calling the Plot-level mutator) and any other
# name, with a pointer to `trace` for raw plotly.js attributes.
function _map_reject_keywords(who::AbstractString, kwargs; mutator::Bool)
	isempty(kwargs) && return nothing
	if mutator
		haskey(kwargs, :show) && throw(ArgumentError(
			"$(who): mutators do not take `show` (they never open a window); " *
			"display the figure with `to_syncplot(fig)`, or pass `show = true` " *
			"to the constructor.",
		))
		(haskey(kwargs, :row) || haskey(kwargs, :col)) && throw(ArgumentError(
			"$(who): `row`/`col` select a SubplotFigure cell; a single figure " *
			"has one cell, so omit them.",
		))
	end
	names = join(("`$(key)`" for key in keys(kwargs)), ", ")
	throw(ArgumentError(
		"$(who): unknown keyword argument(s) $(names). Raw plotly.js trace " *
		"attributes go in the `trace` keyword, e.g. `trace = attr(hovertemplate = \"...\")`.",
	))
end

# A map trace needs at least one location: plotly.js draws an empty trace
# without any message, which hides a caller's bug.
function _require_nonempty_map_data(who::AbstractString, name::AbstractString, values)
	isempty(values) && throw(ArgumentError(
		"$(who): `$(name)` is empty; a map trace needs at least one location.",
	))
	return nothing
end

# Whether a (possibly nested) attribute container holds a `colorscale` key.
function _map_has_colorscale(container)
	_is_layout_mapping(container) || return false
	for (key, value) in _symbol_dict(container)
		key === :colorscale && return true
		_map_has_colorscale(value) && return true
	end
	return false
end

# Whether `trace` holds the attribute at `path` (a nested key path).
function _map_has(trace::GenericTrace, path::Symbol...)
	container = trace.fields
	for key in path
		_is_layout_mapping(container) || return false
		fields = _symbol_dict(container)
		haskey(fields, key) || return false
		container = fields[key]
	end
	return true
end

# `trace.<path...> = value`. Every container on the path is replaced by a
# fresh `Dict`, so a container that came from the caller's `trace` keyword is
# never mutated.
function _map_set!(trace::GenericTrace, value, path::Symbol...)
	_map_set_path!(trace.fields, value, path)
	return trace
end

function _map_set_path!(container::AbstractDict, value, path::Tuple{Vararg{Symbol}})
	key = first(path)
	if length(path) == 1
		container[key] = value
		return nothing
	end
	child = _symbol_dict(get(container, key, nothing))
	container[key] = child
	_map_set_path!(child, value, Base.tail(path))
	return nothing
end

# The trace a map function `who` starts from: an empty `kind` trace, or one
# holding the raw plotly.js attributes of its `trace` keyword. A key is a
# top-level attribute or a nested path below one in PlotlyBase's underscore
# form (`marker_opacity`, `hoverlabel_font_size`); no top-level name of these
# trace types contains an underscore, so the attribute is the part before the
# first `_`. `trace` may not set what the function sets itself: `type`, the
# attributes in `reserved` (`head => "where it comes from"`: positional
# arguments, `mode`, `locationmode`, ...), the nested paths in `controlled`
# (`(:marker, :size) => "marker_size"`), the trace `name` (the `legend`
# keyword: text goes through `_label`) and any `colorscale` (the
# `colorscale` keyword: names are resolved with matplotlib orientation).
# Validates before it builds anything; never mutates `trace`.
function _map_base_trace(
	who::AbstractString,
	kind::AbstractString,
	constructor,
	trace;
	reserved::Tuple{Vararg{Pair{String, String}}},
	controlled::Tuple{Vararg{Pair{<:Tuple{Vararg{Symbol}}, String}}} = (),
)
	trace === nothing && return constructor()
	_is_layout_mapping(trace) || throw(ArgumentError(
		"$(who): `trace` must be an `attr(...)`, a Dict or a NamedTuple of " *
		"plotly.js `$(kind)` trace attributes; got $(typeof(trace)).",
	))
	attributes = _symbol_dict(trace)
	allowed = _MAP_TRACE_ATTRIBUTE_NAMES[kind]
	sources = Dict{String, String}(
		"type" => "is fixed to $(repr(kind))",
		"name" => "comes from the `legend` keyword",
		"colorscale" => "comes from the `colorscale` keyword",
	)
	for (head, source) in reserved
		sources[head] = "comes from $(source)"
	end
	for key in keys(attributes)
		name = String(key)
		head = String(first(split(name, '_'; limit = 2)))
		haskey(sources, head) && throw(ArgumentError(
			"$(who): `trace` attribute `$(name)` sets the trace's `$(head)`, " *
			"which $(sources[head]).",
		))
		head in allowed || throw(ArgumentError(
			"$(who): `trace` attribute `$(name)` is not a plotly.js `$(kind)` " *
			"trace attribute (nested attributes are written with underscores, " *
			"e.g. `hoverlabel_bgcolor`, or as nested `attr(...)`).",
		))
	end
	built = constructor(; attributes...)
	_map_has_colorscale(built.fields) && throw(ArgumentError(
		"$(who): `trace` may not set a `colorscale`; use the `colorscale` " *
		"keyword (names are resolved like every colour scale of the package).",
	))
	for (path, keyword) in controlled
		_map_has(built, path...) && throw(ArgumentError(
			"$(who): `trace` attribute `$(join(path, '_'))` is set by the " *
			"`$(keyword)` keyword; use the keyword.",
		))
	end
	return built
end

# A map `colorscale` keyword resolved like every other `colorscale` keyword
# of the package (`_resolve_colorscale`: COLORMAPS / plotly.js / ColorSchemes
# names with matplotlib orientation, a `"_r"` suffix, colour vectors,
# `[t, colour]` stops, a `ColorScheme`; unknown names throw), so a name means
# the same colours on a map as on a heatmap. `nothing` when unset (plotly's
# default).
function _map_colorscale(who::AbstractString, colorscale)
	scale = _resolve_colorscale(colorscale; who = who).scale
	scale isa AbstractString && isempty(scale) && return nothing
	return scale
end

# The legend entry of a map trace: `legend` (mathtext, through `_label`) is
# the trace name and, unless `trace` decides `showlegend`, turns the entry
# on (choropleth and density traces are off by default in plotly.js). ""
# leaves the trace unnamed. `name` is the validated `_label` result.
function _map_set_legend!(trace::GenericTrace, name::AbstractString)
	isempty(name) && return trace
	_map_set!(trace, name, :name)
	_map_has(trace, :showlegend) || _map_set!(trace, true, :showlegend)
	return trace
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

# Whether a scatter-map `color` is a vector of numbers (coloured through the
# colour scale) rather than colour names.
_map_numeric_color(color) =
	color isa AbstractVector && !isempty(color) &&
	all(value -> value isa Real && !(value isa Bool), color)

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
# Electron window and raster exports are integer-sized. `title` is the plain
# text (the window title of `show = true`) and `label` its mathtext form, the
# figure title. Validates only, so callers can run it before mutating
# anything.
function _geo_figure_options(
	who::AbstractString;
	title::AbstractString,
	width::Real,
	height::Real,
	fontsize::Real,
)
	label = _extended_label(title, who, "title")
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
		who = String(who),
		title = String(title),
		label = label,
		width = round(Int, Float64(width)),
		height = round(Int, Float64(height)),
		fontsize = fontsize,
	)
end

# Apply validated `_geo_figure_options` to a constructed (`apply_template =
# true`) or appended-to (`false`: only the legend is refreshed so a user
# template survives) figure through the D7 figure-option primitives (see
# `_apply_basic_plot_options!`): the title is stored as `title.text` and
# keeps the existing title's other attributes (position, font), and an
# explicit `fontsize` is applied after the template so it wins over the
# style's base size.
function _apply_geo_figure_options!(
	fig,
	options;
	apply_template::Bool,
)
	_apply_basic_plot_options!(
		fig;
		title = options.label,
		width = options.width,
		height = options.height,
		fontsize = options.fontsize,
		apply_template = apply_template,
		who = options.who,
	)
	return nothing
end

# Shared trace builder of scattergeo / scattermapbox / scattermap (`kind`).
# `color`: "" / nothing = Plotly default; a String or Symbol is one colour; a
# vector is per point (colour names, or numbers coloured through
# `colorscale`, which needs such numbers). `marker_size`: nothing = default;
# a Real or a per-point vector, >= 0. Per-point vectors must match the
# coordinates: plotly.js silently drops the points past a shorter marker
# array. `trace` holds raw plotly.js attributes (`_map_base_trace`). Errors
# name `who`, the public function; nothing is built before all checks pass.
function _geo_scatter_trace(
	kind::AbstractString,
	constructor,
	lon::AbstractVector,
	lat::AbstractVector;
	who::AbstractString,
	mode::AbstractString,
	color,
	marker_size,
	colorscale,
	legend::AbstractString,
	trace,
)
	_require_equal_geo_lengths(
		who,
		:lon => lon,
		:lat => lat,
	)
	_require_nonempty_map_data(who, "lon", lon)
	_require_map_vector_length(who, "color", color, length(lon))
	_require_map_vector_length(
		who,
		"marker_size",
		marker_size,
		length(lon),
	)
	marker_size === nothing || _require_bounded_numeric_option(
		who,
		"marker_size",
		marker_size;
		minimum = 0,
	)
	scale = _map_colorscale(who, colorscale)
	scale === nothing || _map_numeric_color(color) || throw(ArgumentError(
		"$(who): `colorscale` colours numeric `color` values; pass `color` as " *
		"one number per point to use it.",
	))
	name = _extended_label(legend, who, "legend")
	built = _map_base_trace(
		who,
		kind,
		constructor,
		trace;
		reserved = (
			"lon" => "the positional arguments",
			"lat" => "the positional arguments",
			"mode" => "the `mode` keyword",
		),
		controlled = ((:marker, :color) => "color", (:marker, :size) => "marker_size"),
	)
	_map_set!(built, lon, :lon)
	_map_set!(built, lat, :lat)
	_map_set!(built, String(mode), :mode)
	if color isa Union{AbstractString, Symbol}
		text = String(color)
		isempty(text) || _map_set!(built, text, :marker, :color)
	elseif color !== nothing
		_map_set!(built, color, :marker, :color)
	end
	marker_size === nothing || _map_set!(built, marker_size, :marker, :size)
	scale === nothing || _map_set!(built, scale, :marker, :colorscale)
	isempty(name) || _map_set!(built, name, :name)
	return built
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
	who::AbstractString,
	locationmode::Union{Nothing,AbstractString},
	geojson,
	featureidkey::AbstractString,
	colorscale,
	legend::AbstractString,
	trace,
)
	_require_equal_geo_lengths(
		who,
		:locations => locations,
		:z => z,
	)
	_require_nonempty_map_data(who, "locations", locations)
	has_geojson = _is_plotly_geojson(geojson)
	geojson === nothing || has_geojson || throw(ArgumentError(
		"$(who): `geojson` must be a GeoJSON object (Dict, attr or " *
		"NamedTuple) or a nonempty URL string; got $(typeof(geojson)).",
	))
	# An explicit mode always wins. Otherwise match GeoJSON features when a
	# GeoJSON is given (plotly.js' own default) and country names if not.
	mode =
		locationmode !== nothing ? String(locationmode) :
		has_geojson ? "geojson-id" : "country names"
	mode in _CHOROPLETH_LOCATIONMODES || throw(ArgumentError(
		"$(who): `locationmode` must be one of " *
		"$(join(repr.(_CHOROPLETH_LOCATIONMODES), ", ")); got $(repr(mode)).",
	))
	mode == "geojson-id" && !has_geojson && throw(ArgumentError(
		"$(who): locationmode=\"geojson-id\" requires `geojson`.",
	))
	isempty(featureidkey) || mode == "geojson-id" || throw(ArgumentError(
		"$(who): `featureidkey` only applies to GeoJSON locations " *
		"(locationmode=\"geojson-id\"); got locationmode=$(repr(mode)).",
	))
	scale = _map_colorscale(who, colorscale)
	name = _extended_label(legend, who, "legend")
	built = _map_base_trace(
		who,
		"choropleth",
		choropleth,
		trace;
		reserved = (
			"locations" => "the positional arguments",
			"z" => "the positional arguments",
			"locationmode" => "the `locationmode` keyword",
			"geojson" => "the `geojson` keyword",
			"featureidkey" => "the `featureidkey` keyword",
		),
	)
	_map_set!(built, locations, :locations)
	_map_set!(built, z, :z)
	_map_set!(built, mode, :locationmode)
	has_geojson && _map_set!(built, geojson, :geojson)
	isempty(featureidkey) || _map_set!(built, String(featureidkey), :featureidkey)
	scale === nothing || _map_set!(built, scale, :colorscale)
	_map_set_legend!(built, name)
	return built
end

function _require_valid_mapbox_view(
	zoom,
	center_lon,
	center_lat,
	bearing = nothing,
	pitch = nothing;
	who::AbstractString = "mapbox",
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
			"$who: $name must be a finite JavaScript-representable " *
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
	center_lat;
	who::AbstractString = "mapbox",
)
	_require_valid_mapbox_view(zoom, center_lon, center_lat; who = who)
	_require_valid_map_style(style; family = "mapbox", who = who)
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
	style;
	who::AbstractString = "SubplotFigure",
)
	style === nothing || return style
	r, c = _resolve_subplot_cell(sf; row = row, col = col, who = who)
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
			style = _subplot_mapbox_cell_style(
				sf,
				row,
				col,
				style;
				who = _subplot_delegate_who(
					mutator,
					get(kwargs, :delegate_who, nothing),
					kwargs,
				),
			),
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
include("sci/finalize.jl")

"""
	plot_choropleth(locations, z; locationmode=nothing, geojson=nothing,
		featureidkey="", colorscale="", legend="", scope="", projection="",
		title="", width=0, height=0, fontsize=0, trace=nothing, show=false)

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
- `colorscale = ""`: a colormap name (`"viridis"`, `"Blues"`, `"RdBu_r"`: any
  `COLORMAPS`, plotly.js or ColorSchemes.jl name, matplotlib orientation,
  case-insensitive, `_r` reverses; unknown names throw), a vector of colours
  or `(t, colour)` stops, or a `ColorScheme`; `""` keeps the default.
- `legend::AbstractString = ""`: legend name of the trace (mathtext); a
  name also shows the trace in the legend (plotly.js hides choropleth
  traces from the legend by default).
- `scope::AbstractString = ""`: geo scope (`"world"`, `"europe"`, `"usa"`, ...).
- `projection::AbstractString = ""`: geo projection type (`"mercator"`, ...).
- `title::AbstractString = ""`: figure title (mathtext, see `mathtext`).
- `width::Real = 0`, `height::Real = 0`: figure size in pixels (0 = automatic,
  otherwise at least 10; rounded to whole pixels).
- `fontsize::Real = 0`: global font size (0 = template default, otherwise ≥ 1).
- `trace = nothing`: raw plotly.js `choropleth` trace attributes as
  `attr(...)` (or a Dict/NamedTuple), nested ones written with underscores:
  `trace = attr(zmin = 0, zmax = 5, hovertext = names, marker_line_color =
  "white")`. This is the only raw pass-through; its values are passed on
  unchanged. A name that is not a `choropleth` attribute of the bundled
  plotly.js throws, as do the attributes set from the arguments above
  (`locations`, `z`, `locationmode`, `geojson`, `featureidkey`, `name`: use
  `legend`, any `colorscale`).
- `show::Bool = false`: open the figure in a window and return a `SyncPlot`.

Any other keyword argument throws `ArgumentError`. So do empty or mismatched
`locations`/`z`, an unknown `locationmode`, `"geojson-id"` matching without
`geojson`, `featureidkey` without GeoJSON matching, an unknown colorscale, or
an invalid size.

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
	colorscale = "",
	legend::AbstractString = "",
	scope::AbstractString = "",
	projection::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	trace = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_choropleth"
	_map_reject_keywords(who, kwargs; mutator = false)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	built = _choropleth_trace(
		locations,
		z;
		who = who,
		locationmode = locationmode,
		geojson = geojson,
		featureidkey = featureidkey,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	fig = Plot(built, _geo_layout(scope, projection))
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
		featureidkey="", colorscale="", legend="", scope="", projection="",
		title="", width=0, height=0, fontsize=0, trace=nothing)
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
	colorscale = "",
	legend::AbstractString = "",
	scope::AbstractString = "",
	projection::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	trace = nothing,
	kwargs...,
)
	who = "plot_choropleth!"
	_map_reject_keywords(who, kwargs; mutator = true)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	built = _choropleth_trace(
		locations,
		z;
		who = who,
		locationmode = locationmode,
		geojson = geojson,
		featureidkey = featureidkey,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	push!(_plot_data(fig), built)
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
		colorscale="", legend="", scope="", projection="", title="", width=0,
		height=0, fontsize=0, trace=nothing, show=false)

Scatter points (or lines) on a `geo` (outline) map at longitudes `lon` and
latitudes `lat` in degrees.

# Arguments
- `lon::AbstractVector`, `lat::AbstractVector`: coordinates (equal lengths).

# Keywords
- `mode::AbstractString = "markers"`: Plotly scatter mode (`"markers"`,
  `"lines"`, `"lines+markers"`, `"text"`, ...).
- `color::Union{Nothing,AbstractString,Symbol,AbstractVector} = ""`: marker
  colour; one colour, or one value per point (colour names, or numbers
  coloured through `colorscale`). `""`/`nothing` keeps the default.
- `marker_size::Union{Nothing,Real,AbstractVector} = nothing`: marker size in
  pixels (≥ 0), scalar or one per point.
- `colorscale = ""`: colour scale of numeric `color` values, resolved as for
  [`plot_choropleth`](@ref) (matplotlib orientation, unknown names throw).
  Needs `color` as one number per point.
- `legend::AbstractString = ""`: legend name of the trace (mathtext).
- `scope::AbstractString = ""`, `projection::AbstractString = ""`: geo scope
  and projection type (see [`plot_choropleth`](@ref)).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_choropleth`](@ref).
- `trace = nothing`: raw plotly.js `scattergeo` trace attributes, the only raw
  pass-through, as for [`plot_choropleth`](@ref) (e.g. `trace =
  attr(marker_symbol = "square", line_width = 2)`); it may not set `lon`,
  `lat`, `mode`, `marker_color`, `marker_size`, `name` or any `colorscale`
  (use the arguments).

The active [`PlotStyle`](@ref) fills unset line widths, dashes, marker sizes
and symbols, as for [`plot_scatter`](@ref).

Per-point vectors must have the coordinate length; empty coordinates,
mismatches, negative or non-finite sizes, a `colorscale` without numeric
`color`, an unknown colour-scale name, any other keyword argument and invalid
figure sizes throw `ArgumentError`.

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
	colorscale = "",
	legend::AbstractString = "",
	scope::AbstractString = "",
	projection::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	trace = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_scattergeo"
	_map_reject_keywords(who, kwargs; mutator = false)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	built = _geo_scatter_trace(
		"scattergeo",
		scattergeo,
		lon,
		lat;
		who = who,
		mode = mode,
		color = color,
		marker_size = marker_size,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	fig = Plot(built, _geo_layout(scope, projection))
	# The default `mode` has no lines, so a mode with lines was chosen by
	# the caller and the style's `:dash_marker` cycle must not add markers.
	_apply_style_trace_defaults!(fig, 1; explicit = (:mode,))
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
		marker_size=nothing, colorscale="", legend="", scope="", projection="",
		title="", width=0, height=0, fontsize=0, trace=nothing)
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
	colorscale = "",
	legend::AbstractString = "",
	scope::AbstractString = "",
	projection::AbstractString = "",
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	trace = nothing,
	kwargs...,
)
	who = "plot_scattergeo!"
	_map_reject_keywords(who, kwargs; mutator = true)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	built = _geo_scatter_trace(
		"scattergeo",
		scattergeo,
		lon,
		lat;
		who = who,
		mode = mode,
		color = color,
		marker_size = marker_size,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	push!(_plot_data(fig), built)
	_apply_style_trace_defaults!(fig, length(_plot_data(fig)); explicit = (:mode,))
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
		colorscale="", legend="", style="open-street-map", zoom=0,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, trace=nothing, show=false)

Scatter points (or lines) on a legacy Mapbox tile map at `(lon, lat)`
(degrees). The MapLibre-based [`plot_scattermap`](@ref) is the modern
equivalent.

# Arguments
- `lon::AbstractVector`, `lat::AbstractVector`: coordinates (equal lengths).

# Keywords
- `mode`, `color`, `marker_size`, `colorscale`, `legend`: as for
  [`plot_scattergeo`](@ref).
- `style = "open-street-map"`: tile style: a nonempty style name/URL or a
  nonempty Mapbox style object. The default needs no access token; Mapbox
  styles (`"basic"`, `"streets"`, `mapbox://...`) need `layout.mapbox.accesstoken`.
- `zoom = 0`: initial zoom level (finite number).
- `center_lon = nothing`, `center_lat = nothing`: initial map centre in
  degrees (`nothing` keeps plotly.js' automatic centre).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_choropleth`](@ref).
- `trace = nothing`: raw plotly.js `scattermapbox` trace attributes, the only
  raw pass-through, with the restrictions of [`plot_scattergeo`](@ref).

Throws `ArgumentError` for empty or mismatched coordinates, a `colorscale`
without numeric `color`, an unknown colour-scale name, an empty or
non-string, non-object `style`, non-finite view values, any other keyword
argument or invalid sizes.

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
	colorscale = "",
	legend::AbstractString = "",
	style = _DEFAULT_MAPBOX_STYLE,
	zoom = 0,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	trace = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_scattermapbox"
	_map_reject_keywords(who, kwargs; mutator = false)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _mapbox_layout(style, zoom, center_lon, center_lat; who = who)
	built = _geo_scatter_trace(
		"scattermapbox",
		scattermapbox,
		lon,
		lat;
		who = who,
		mode = mode,
		color = color,
		marker_size = marker_size,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	fig = Plot(built, layout)
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
		marker_size=nothing, colorscale="", legend="", style=nothing,
		zoom=nothing, center_lon=nothing, center_lat=nothing, title="",
		width=0, height=0, fontsize=0, trace=nothing)
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
	colorscale = "",
	legend::AbstractString = "",
	style = nothing,
	zoom = nothing,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	trace = nothing,
	kwargs...,
)
	who = "plot_scattermapbox!"
	_map_reject_keywords(who, kwargs; mutator = true)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_mapbox_view(zoom, center_lon, center_lat; who = who)
	_require_valid_map_style(style; family = "mapbox", who = who)
	built = _geo_scatter_trace(
		"scattermapbox",
		scattermapbox,
		lon,
		lat;
		who = who,
		mode = mode,
		color = color,
		marker_size = marker_size,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	push!(_plot_data(fig), built)
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
		fontsize=0, trace=nothing, show=false)

Shade GeoJSON features on a legacy Mapbox tile map. The MapLibre-based
[`plot_choroplethmap`](@ref) is the modern equivalent.

# Arguments
- `geojson`: a GeoJSON `FeatureCollection` (`Dict`, `attr`, `NamedTuple`) or URL.
- `locations::AbstractVector`: feature ids matched against `featureidkey`.
- `z::AbstractVector`: one value per location (same length as `locations`).

# Keywords
- `featureidkey::AbstractString = ""`: feature property matched by
  `locations` (`""` = plotly.js default `"id"`).
- `colorscale = ""`: colormap name, colour vector, stops or `ColorScheme`, as
  for [`plot_choropleth`](@ref).
- `marker_line_color::Union{Nothing,AbstractString,Symbol,AbstractVector} = nothing`:
  boundary colour, scalar or one per location.
- `marker_line_width::Union{Nothing,Real,AbstractVector} = nothing`: boundary
  width in pixels (≥ 0), scalar or one per location.
- `marker_opacity::Union{Nothing,Real,AbstractVector} = nothing`: fill opacity
  in [0, 1], scalar or one per location.
- `legend::AbstractString = ""`: legend name of the trace (mathtext); a
  name also shows the trace in the legend (off by default in plotly.js).
- `style`, `zoom`, `center_lon`, `center_lat`: map view, as for
  [`plot_scattermapbox`](@ref).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_choropleth`](@ref).
- `trace = nothing`: raw plotly.js `choroplethmapbox` trace attributes, the
  only raw pass-through, with the restrictions of
  [`plot_choroplethmap`](@ref).

Per-location vectors must have the `locations` length; empty `locations`,
mismatches, out-of-range values, an unknown colour-scale name and any other
keyword argument throw `ArgumentError`.

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
	colorscale = "",
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
	trace = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_choroplethmapbox"
	_map_reject_keywords(who, kwargs; mutator = false)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _mapbox_layout(style, zoom, center_lon, center_lat; who = who)
	built = _choroplethmap_trace(
		geojson,
		locations,
		z;
		who = who,
		kind = "choroplethmapbox",
		constructor = choroplethmapbox,
		featureidkey = featureidkey,
		colorscale = colorscale,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		marker_opacity = marker_opacity,
		legend = legend,
		trace = trace,
	)
	fig = Plot(built, layout)
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
		fontsize=0, trace=nothing)
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
	colorscale = "",
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
	trace = nothing,
	kwargs...,
)
	who = "plot_choroplethmapbox!"
	_map_reject_keywords(who, kwargs; mutator = true)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_mapbox_view(zoom, center_lon, center_lat; who = who)
	_require_valid_map_style(style; family = "mapbox", who = who)
	built = _choroplethmap_trace(
		geojson,
		locations,
		z;
		who = who,
		kind = "choroplethmapbox",
		constructor = choroplethmapbox,
		featureidkey = featureidkey,
		colorscale = colorscale,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		marker_opacity = marker_opacity,
		legend = legend,
		trace = trace,
	)
	push!(_plot_data(fig), built)
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
	plot_densitymapbox(lon, lat, z; radius=0, colorscale="", legend="",
		style="open-street-map", zoom=0, center_lon=nothing, center_lat=nothing,
		title="", width=0, height=0, fontsize=0, trace=nothing, show=false)

Density heatmap of weighted points `(lon, lat, z)` on a legacy Mapbox tile
map. The MapLibre-based [`plot_densitymap`](@ref) is the modern equivalent.

# Arguments
- `lon::AbstractVector`, `lat::AbstractVector`: point coordinates in degrees.
- `z::AbstractVector`: point weights (same length as `lon`/`lat`).

# Keywords
- `radius::Union{Real,AbstractVector} = 0`: influence radius of each point in
  pixels, scalar or one per point, each ≥ 1. `0` keeps plotly.js' default.
- `colorscale = ""`: colormap name, colour vector, stops or `ColorScheme`, as
  for [`plot_choropleth`](@ref).
- `legend::AbstractString = ""`: legend name of the trace (mathtext); a
  name also shows the trace in the legend (off by default in plotly.js).
- `style`, `zoom`, `center_lon`, `center_lat`: map view, as for
  [`plot_scattermapbox`](@ref).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_choropleth`](@ref).
- `trace = nothing`: raw plotly.js `densitymapbox` trace attributes, the only
  raw pass-through, with the restrictions of [`plot_densitymap`](@ref).

Throws `ArgumentError` for empty or mismatched coordinates (including a
per-point `radius`), radii below 1, an unknown colour-scale name, any other
keyword argument and invalid map-view or size values.

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
	colorscale = "",
	legend::AbstractString = "",
	style = _DEFAULT_MAPBOX_STYLE,
	zoom = 0,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	trace = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_densitymapbox"
	_map_reject_keywords(who, kwargs; mutator = false)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _mapbox_layout(style, zoom, center_lon, center_lat; who = who)
	built = _densitymap_trace(
		lon,
		lat,
		z;
		who = who,
		kind = "densitymapbox",
		constructor = densitymapbox,
		radius = radius,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	fig = Plot(built, layout)
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
	plot_densitymapbox!(fig, lon, lat, z; radius=0, colorscale="", legend="",
		style=nothing, zoom=nothing, center_lon=nothing, center_lat=nothing,
		title="", width=0, height=0, fontsize=0, trace=nothing)
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
	colorscale = "",
	legend::AbstractString = "",
	style = nothing,
	zoom = nothing,
	center_lon = nothing,
	center_lat = nothing,
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	trace = nothing,
	kwargs...,
)
	who = "plot_densitymapbox!"
	_map_reject_keywords(who, kwargs; mutator = true)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_mapbox_view(zoom, center_lon, center_lat; who = who)
	_require_valid_map_style(style; family = "mapbox", who = who)
	built = _densitymap_trace(
		lon,
		lat,
		z;
		who = who,
		kind = "densitymapbox",
		constructor = densitymapbox,
		radius = radius,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	push!(_plot_data(fig), built)
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
