# PlotlyBase 0.8.23 predates Plotly.js' MapLibre-backed `map` subplot and the
# scattermap/choroplethmap/densitymap trace types.  Keep compatibility local to
# PlotlySupply: mutating PlotlyBase's private subplot registries would change
# process-wide behaviour and still would not update its older bundled schema.

const _MODERN_MAP_TRACE_TYPES = (
	:scattermap,
	:choroplethmap,
	:densitymap,
)

const _MODERN_MAP_SPEC_KINDS = (
	:map,
	_MODERN_MAP_TRACE_TYPES...,
)

"""
Classify a trace for PlotlySupply's subplot validation.

Modern MapLibre traces are handled locally.  Every other trace continues
through PlotlyBase's schema-driven classifier, preserving its existing
behaviour (including errors for unknown trace types).
"""
function _plotlysupply_subplot_kind_from_trace_type(trace_type::Symbol)
	trace_type in _MODERN_MAP_TRACE_TYPES && return "map"
	return PlotlyBase.get_subplotkind_from_trace_type(trace_type)
end

_is_modern_map_spec_kind(kind::AbstractString) =
	Symbol(kind) in _MODERN_MAP_SPEC_KINDS

function _subplot_effective_single_kind(kind::AbstractString)
	kind_symbol = Symbol(kind)
	kind_symbol in _MODERN_MAP_SPEC_KINDS && return "map"

	# A Spec may name a trace type instead of a subplot kind.  Ask PlotlyBase
	# only for trace names it advertises; calling its classifier for an
	# arbitrary symbol indexes the old schema and raises a KeyError.
	if kind_symbol in PlotlyBase._TRACE_TYPES
		classified = PlotlyBase.get_subplotkind_from_trace_type(kind_symbol)
		classified isa AbstractString || throw(ArgumentError(
			"Plotly trace type $(repr(kind)) has no subplot kind.",
		))
		return String(classified)
	end
	return String(kind)
end

function _modern_map_proxy_spec(spec::Spec)
	_is_modern_map_spec_kind(spec.kind) || return spec
	return Spec(
		kind = "mapbox",
		secondary_y = spec.secondary_y,
		colspan = spec.colspan,
		rowspan = spec.rowspan,
		l = spec.l,
		r = spec.r,
		b = spec.b,
		t = spec.t,
	)
end

function _modern_map_proxy_inset(inset::Inset)
	_is_modern_map_spec_kind(inset.kind) || return inset
	return Inset(
		cell = inset.cell,
		kind = "mapbox",
		colspan = inset.colspan,
		rowspan = inset.rowspan,
		l = inset.l,
		w = inset.w,
		b = inset.b,
		h = inset.h,
	)
end

function _contains_modern_map(sp::Subplots)
	for row in 1:sp.rows, col in 1:sp.cols
		spec = sp.specs[row, col]
		if !ismissing(spec) && _is_modern_map_spec_kind(spec.kind)
			return true
		end
	end
	if sp.insets isa AbstractVector
		for inset in sp.insets
			_is_modern_map_spec_kind(inset.kind) && return true
		end
	end
	return false
end

function _modern_map_proxy_specs(specs)
	proxy = Matrix{Union{Missing,Spec}}(undef, size(specs))
	for index in eachindex(specs)
		spec = specs[index]
		proxy[index] =
			ismissing(spec) ?
			missing :
			_modern_map_proxy_spec(spec)
	end
	return proxy
end

function _modern_map_proxy_insets(insets)
	insets isa AbstractVector || return insets
	proxy = Vector{Inset}(undef, length(insets))
	for index in eachindex(insets)
		proxy[index] = _modern_map_proxy_inset(insets[index])
	end
	return proxy
end

# Reconstruct rather than mutate a caller's Subplots.  Passing all fields
# except grid_ref preserves explicit computed-field overrides accepted by
# Parameters.jl's keyword constructor (spacing, widths, heights, and so on).
function _rebuild_subplots(
	sp::Subplots;
	specs = sp.specs,
	insets = sp.insets,
	grid_ref = nothing,
	shared_xaxes = sp.shared_xaxes,
	shared_yaxes = sp.shared_yaxes,
	subplot_titles = sp.subplot_titles,
	column_titles = sp.column_titles,
	row_titles = sp.row_titles,
	x_title = sp.x_title,
	y_title = sp.y_title,
)
	overrides = (;
		specs,
		insets,
		shared_xaxes,
		shared_yaxes,
		subplot_titles,
		column_titles,
		row_titles,
		x_title,
		y_title,
	)
	values = (;
		(
			name => (
				hasproperty(overrides, name) ?
					getproperty(overrides, name) :
					getfield(sp, name)
			)
			for name in fieldnames(Subplots)
			if name !== :grid_ref
		)...,
	)
	if grid_ref === nothing
		return Subplots(; values...)
	end
	return Subplots(; values..., grid_ref = grid_ref)
end

_numbered_subplot_key(prefix::AbstractString, index::Int) =
	Symbol(prefix * (index == 1 ? "" : string(index)))

function _append_map_translation!(
	translations::Vector{Tuple{Symbol,Symbol,String}},
	effective_kind::String,
	placeholder_index::Int,
	map_index::Int,
	mapbox_index::Int,
)
	if effective_kind == "map"
		map_index += 1
		new_key = _numbered_subplot_key("map", map_index)
	elseif effective_kind == "mapbox"
		mapbox_index += 1
		new_key = _numbered_subplot_key("mapbox", mapbox_index)
	else
		return placeholder_index, map_index, mapbox_index
	end

	placeholder_index += 1
	old_key = _numbered_subplot_key("mapbox", placeholder_index)
	push!(translations, (old_key, new_key, effective_kind))
	return placeholder_index, map_index, mapbox_index
end

function _modern_map_translations(sp::Subplots)
	translations = Tuple{Symbol,Symbol,String}[]
	placeholder_index = 0
	map_index = 0
	mapbox_index = 0

	# This order must match PlotlyBase.Layout(::Subplots): rows are the outer
	# loop, columns the inner loop.  Julia's ordinary matrix iteration is
	# column-major and would silently route mixed map/mapbox cells incorrectly.
	for row in 1:sp.rows, col in 1:sp.cols
		spec = sp.specs[row, col]
		ismissing(spec) && continue
		placeholder_index, map_index, mapbox_index =
			_append_map_translation!(
				translations,
				_subplot_effective_single_kind(spec.kind),
				placeholder_index,
				map_index,
				mapbox_index,
			)
	end

	# PlotlyBase initializes insets after every grid cell and uses the same
	# per-kind counter, so they must continue the placeholder sequence.
	if sp.insets isa AbstractVector
		for inset in sp.insets
			placeholder_index, map_index, mapbox_index =
				_append_map_translation!(
					translations,
					_subplot_effective_single_kind(inset.kind),
					placeholder_index,
					map_index,
					mapbox_index,
				)
		end
	end
	return translations
end

function _require_subplotref_compatibility()
	actual = fieldnames(PlotlyBase.SubplotRef)
	expected = (:subplot_kind, :layout_keys, :trace_kwargs)
	actual == expected || throw(ErrorException(
		"PlotlyBase.SubplotRef has incompatible fields $(actual); " *
		"expected $(expected) for modern map subplot support.",
	))
	return nothing
end

function _clear_missing_subplot_refs!(
	layout::Layout,
	sp::Subplots,
)
	grid_ref = layout.subplots.grid_ref
	for row in 1:sp.rows, col in 1:sp.cols
		ismissing(sp.specs[row, col]) || continue
		# PlotlyBase preassigns an XY ref for every 1×1 Subplots value, even
		# when its sole Spec is missing. An assigned empty vector preserves the
		# GridRef element type while making PlotlySupply's routing guard reject
		# the documented blank cell.
		grid_ref[row, col] = PlotlyBase.SubplotRef[]
	end
	return layout
end

_shared_subplot_axes_requested(value) =
	!ismissing(value) && value !== false

function _subplot_titles_requested(sp::Subplots)
	return !ismissing(sp.subplot_titles) ||
		!ismissing(sp.column_titles) ||
		!ismissing(sp.row_titles) ||
		!ismissing(sp.x_title) ||
		!ismissing(sp.y_title)
end

function _has_missing_subplot_specs(sp::Subplots)
	for row in 1:sp.rows, col in 1:sp.cols
		ismissing(sp.specs[row, col]) && return true
	end
	return false
end

function _subplot_attribute_fields(value)
	value isa PlotlyBase.PlotlyAttribute && return value.fields
	value isa AbstractDict && return value
	return nothing
end

function _subplot_domain_component(value, key::Symbol)
	fields = _subplot_attribute_fields(value)
	fields === nothing && return nothing
	component = get(fields, key, nothing)
	(component isa Tuple || component isa AbstractVector) ||
		return nothing
	length(component) == 2 || return nothing
	return (Float64(component[1]), Float64(component[2]))
end

function _subplot_domain(value)
	fields = _subplot_attribute_fields(value)
	fields === nothing && return nothing
	x_domain = _subplot_domain_component(value, :x)
	y_domain = _subplot_domain_component(value, :y)
	(x_domain === nothing || y_domain === nothing) && return nothing
	return (x = x_domain, y = y_domain)
end

function _subplot_grid_cell_domain(
	layout::Layout,
	row::Int,
	col::Int,
)
	grid_ref = layout.subplots.grid_ref
	isassigned(grid_ref, row, col) || return nothing
	refs = grid_ref[row, col]
	isempty(refs) && return nothing
	ref = refs[1]

	if ref.subplot_kind == "xy"
		length(ref.layout_keys) >= 2 || return nothing
		x_axis = get(layout.fields, ref.layout_keys[1], nothing)
		y_axis = get(layout.fields, ref.layout_keys[2], nothing)
		x_domain = _subplot_domain_component(x_axis, :domain)
		y_domain = _subplot_domain_component(y_axis, :domain)
		(x_domain === nothing || y_domain === nothing) && return nothing
		return (x = x_domain, y = y_domain)
	elseif ref.subplot_kind == "domain"
		return _subplot_domain(
			get(ref.trace_kwargs.fields, :domain, nothing),
		)
	end

	isempty(ref.layout_keys) && return nothing
	entry = get(layout.fields, ref.layout_keys[1], nothing)
	entry_fields = _subplot_attribute_fields(entry)
	entry_fields === nothing && return nothing
	return _subplot_domain(get(entry_fields, :domain, nothing))
end

function _subplot_axis_candidate(
	layout::Layout,
	sp::Subplots,
	row::Int,
	col::Int,
	axis::Symbol,
)
	spec = sp.specs[row, col]
	ismissing(spec) && return nothing
	span = axis === :x ? spec.colspan : spec.rowspan
	span == 1 || return nothing

	grid_ref = layout.subplots.grid_ref
	isassigned(grid_ref, row, col) || return nothing
	refs = grid_ref[row, col]
	isempty(refs) && return nothing
	ref = refs[1]
	ref.subplot_kind == "xy" || return nothing

	key_index = axis === :x ? 1 : 2
	length(ref.layout_keys) >= key_index || return nothing
	axis_key = ref.layout_keys[key_index]
	haskey(layout.fields, axis_key) || throw(ErrorException(
		"PlotlyBase did not generate expected shared-axis key $(axis_key).",
	))
	axis_id = replace(String(axis_key), "axis" => "")
	return (key = axis_key, id = axis_id)
end

function _set_subplot_axis_match!(
	layout::Layout,
	axis_key::Symbol,
	target_id::String,
	hide_tick_labels::Bool,
)
	entry = get(layout.fields, axis_key, nothing)
	fields = _subplot_attribute_fields(entry)
	fields === nothing && throw(ErrorException(
		"layout.$axis_key is not an axis attribute object",
	))
	fields[:matches] = target_id
	hide_tick_labels && (fields[:showticklabels] = false)
	return nothing
end

function _share_subplot_axis_group!(
	layout::Layout,
	sp::Subplots,
	cells,
	axis::Symbol,
	hide_tick_labels,
)
	first_axis_id = nothing
	for cell in cells
		row, col, position = cell
		candidate = _subplot_axis_candidate(
			layout,
			sp,
			row,
			col,
			axis,
		)
		candidate === nothing && continue
		if first_axis_id === nothing
			first_axis_id = candidate.id
			continue
		end
		hide = hide_tick_labels isa Function ?
			hide_tick_labels(row, col, position) :
			hide_tick_labels
		_set_subplot_axis_match!(
			layout,
			candidate.key,
			first_axis_id,
			hide,
		)
	end
	return nothing
end

function _apply_subplot_shared_axis!(
	layout::Layout,
	sp::Subplots,
	axis::Symbol,
	shared,
)
	_shared_subplot_axes_requested(shared) || return nothing
	rows_iter = collect(1:sp.rows)
	sp.start_cell == "top-left" && reverse!(rows_iter)

	if shared == "columns" || (axis === :x && shared === true)
		for col in 1:sp.cols
			cells = (
				(row, col, position)
				for (position, row) in enumerate(rows_iter)
			)
			_share_subplot_axis_group!(
				layout,
				sp,
				cells,
				axis,
				axis === :x,
			)
		end
	elseif shared == "rows" || (axis === :y && shared === true)
		for row in rows_iter
			cells = (
				(row, col, col)
				for col in 1:sp.cols
			)
			_share_subplot_axis_group!(
				layout,
				sp,
				cells,
				axis,
				axis === :y,
			)
		end
	elseif shared == "all"
		cells = (
			(row, col, position)
			for col in 1:sp.cols
			for (position, row) in enumerate(rows_iter)
		)
		hide_tick_labels = if axis === :y
			(_, col, _) -> col > 0
		elseif sp.start_cell == "bottom-left"
			(_, _, position) -> position > 0
		else
			(row, _, _) -> row < sp.rows
		end
		_share_subplot_axis_group!(
			layout,
			sp,
			cells,
			axis,
			hide_tick_labels,
		)
	end
	return nothing
end

function _apply_subplot_shared_axes!(
	layout::Layout,
	sp::Subplots,
)
	_apply_subplot_shared_axis!(
		layout,
		sp,
		:x,
		sp.shared_xaxes,
	)
	_apply_subplot_shared_axis!(
		layout,
		sp,
		:y,
		sp.shared_yaxes,
	)
	return layout
end

function _subplot_title_text(value)
	(value === nothing || ismissing(value) || value === false) &&
		return nothing
	value isa AbstractString || return String(value)
	isempty(value) && return nothing
	return String(value)
end

function _append_subplot_title_annotation!(
	annotations::Vector,
	title,
	domain;
	edge::Symbol = :top,
	offset::Real = 0,
)
	text = _subplot_title_text(title)
	(text === nothing || domain === nothing) && return nothing
	x_domain = domain.x
	y_domain = domain.y

	if edge === :top
		x = (x_domain[1] + x_domain[2]) / 2
		y = y_domain[2]
		xanchor = "center"
		yanchor = "bottom"
		textangle = 0
		xshift = 0
		yshift = offset
	elseif edge === :bottom
		x = (x_domain[1] + x_domain[2]) / 2
		y = y_domain[1]
		xanchor = "center"
		yanchor = "top"
		textangle = 0
		xshift = 0
		yshift = -offset
	elseif edge === :right
		x = x_domain[2]
		y = (y_domain[1] + y_domain[2]) / 2
		xanchor = "left"
		yanchor = "middle"
		textangle = 90
		xshift = offset
		yshift = 0
	elseif edge === :left
		x = x_domain[1]
		y = (y_domain[1] + y_domain[2]) / 2
		xanchor = "right"
		yanchor = "middle"
		textangle = -90
		xshift = -offset
		yshift = 0
	else
		throw(ArgumentError("unsupported subplot title edge $(repr(edge))"))
	end

	annotation = attr(
		font_size = 16,
		showarrow = false,
		text = text,
		x = x,
		xanchor = xanchor,
		xref = "paper",
		y = y,
		yanchor = yanchor,
		yref = "paper",
	)
	textangle == 0 || (annotation[:textangle] = textangle)
	xshift == 0 || (annotation[:xshift] = xshift)
	yshift == 0 || (annotation[:yshift] = yshift)
	push!(annotations, annotation)
	return nothing
end

function _first_occupied_column_domain(
	layout::Layout,
	sp::Subplots,
	col::Int,
)
	rows = sp.start_cell == "top-left" ?
		(1:sp.rows) :
		(sp.rows:-1:1)
	for row in rows
		domain = _subplot_grid_cell_domain(layout, row, col)
		domain === nothing || return domain
	end
	return nothing
end

function _rightmost_occupied_row_domain(
	layout::Layout,
	sp::Subplots,
	row::Int,
)
	for col in sp.cols:-1:1
		domain = _subplot_grid_cell_domain(layout, row, col)
		domain === nothing || return domain
	end
	return nothing
end

function _apply_subplot_title_annotations!(
	layout::Layout,
	sp::Subplots,
)
	annotations = Any[]

	if !ismissing(sp.subplot_titles)
		size(sp.subplot_titles) == (sp.rows, sp.cols) ||
			throw(ArgumentError(
				"`subplot_titles` must have size " *
				"($(sp.rows), $(sp.cols)); got " *
				"$(size(sp.subplot_titles)).",
			))
		for row in 1:sp.rows, col in 1:sp.cols
			_append_subplot_title_annotation!(
				annotations,
				sp.subplot_titles[row, col],
				_subplot_grid_cell_domain(
					layout,
					row,
					col,
				),
			)
		end
	end

	if !ismissing(sp.column_titles)
		for col in 1:sp.cols
			_append_subplot_title_annotation!(
				annotations,
				sp.column_titles[col],
				_first_occupied_column_domain(
					layout,
					sp,
					col,
				),
			)
		end
	end

	if !ismissing(sp.row_titles)
		for row in 1:sp.rows
			_append_subplot_title_annotation!(
				annotations,
				sp.row_titles[row],
				_rightmost_occupied_row_domain(
					layout,
					sp,
					row,
				);
				edge = :right,
			)
		end
	end

	if !ismissing(sp.x_title)
		_append_subplot_title_annotation!(
			annotations,
			sp.x_title,
			(x = (0.0, sp.max_width), y = (0.0, 1.0));
			edge = :bottom,
			offset = 30,
		)
	end
	if !ismissing(sp.y_title)
		_append_subplot_title_annotation!(
			annotations,
			sp.y_title,
			(x = (0.0, 1.0), y = (0.0, 1.0));
			edge = :left,
			offset = 40,
		)
	end

	layout.fields[:annotations] = annotations
	return layout
end

function _translate_modern_map_layout!(
	layout::Layout,
	sp::Subplots,
	proxy_sp::Subplots,
)
	_require_subplotref_compatibility()
	translations = _modern_map_translations(sp)
	isempty(translations) && throw(ErrorException(
		"modern map subplot translation was requested without a map placeholder",
	))

	translation_by_old =
		Dict(old_key => (new_key, effective_kind)
			for (old_key, new_key, effective_kind) in translations)
	length(translation_by_old) == length(translations) ||
		throw(ErrorException("duplicate map subplot placeholders were generated"))
	length(unique(new_key for (_, new_key, _) in translations)) ==
		length(translations) ||
		throw(ErrorException("duplicate translated map subplot keys were generated"))

	# Remove every old key before assigning any new one.  In an interleaved
	# grid, a new legacy key (for example :mapbox) may equal an old proxy key;
	# staging prevents one translation from overwriting another's domain.
	staged_layouts = Vector{Any}(undef, length(translations))
	for (index, (old_key, _, _)) in enumerate(translations)
		haskey(layout.fields, old_key) || throw(ErrorException(
			"PlotlyBase did not generate expected map placeholder $(old_key).",
		))
		staged_layouts[index] = layout.fields[old_key]
	end
	for (old_key, _, _) in translations
		delete!(layout.fields, old_key)
	end
	for (index, (_, new_key, _)) in enumerate(translations)
		haskey(layout.fields, new_key) && throw(ErrorException(
			"cannot translate modern map subplot: layout key $(new_key) " *
			"already exists",
		))
		layout.fields[new_key] = staged_layouts[index]
	end

	final_grid_ref =
		Matrix{Vector{PlotlyBase.SubplotRef}}(undef, sp.rows, sp.cols)
	for row in 1:sp.rows, col in 1:sp.cols
		isassigned(proxy_sp.grid_ref, row, col) || continue
		refs = proxy_sp.grid_ref[row, col]
		if length(refs) == 1 && length(refs[1].layout_keys) == 1
			old_key = only(refs[1].layout_keys)
			translation = get(translation_by_old, old_key, nothing)
			if translation !== nothing
				new_key, effective_kind = translation
				final_grid_ref[row, col] = [
					PlotlyBase.SubplotRef(
						subplot_kind = effective_kind,
						layout_keys = [new_key],
						trace_kwargs = attr(subplot = String(new_key)),
					),
				]
				continue
			end
		end
		final_grid_ref[row, col] = refs
	end

	# Publish the original user-facing specs together with the translated,
	# fully staged routing table only after every layout/ref check succeeded.
	final_sp = _rebuild_subplots(
		sp;
		grid_ref = final_grid_ref,
	)
	layout.subplots = final_sp
	return layout
end

"""
Build a PlotlyBase layout with package-local modern `map` compatibility.

The common path delegates directly to PlotlyBase.  When local post-processing
is required, PlotlyBase first builds the grid and domains with shared axes and
title annotations disabled.  Modern mapbox placeholders are then translated
into independently numbered `map` and `mapbox` families, and blank-aware axis
links and annotations are derived from the final routing table without
changing PlotlyBase global state.
"""
function _plotlysupply_subplot_layout(sp::Subplots)
	has_modern_map = _contains_modern_map(sp)
	needs_local_postprocessing =
		has_modern_map ||
		_has_missing_subplot_specs(sp) ||
		sp.shared_xaxes !== false ||
		sp.shared_yaxes !== false ||
		_subplot_titles_requested(sp)
	needs_local_postprocessing || return Layout(sp)

	builder_sp = _rebuild_subplots(
		sp;
		specs =
			has_modern_map ?
			_modern_map_proxy_specs(sp.specs) :
			sp.specs,
		insets =
			has_modern_map ?
			_modern_map_proxy_insets(sp.insets) :
			sp.insets,
		shared_xaxes = false,
		shared_yaxes = false,
		subplot_titles = missing,
		column_titles = missing,
		row_titles = missing,
		x_title = missing,
		y_title = missing,
	)
	layout = Layout(builder_sp)
	if has_modern_map
		_translate_modern_map_layout!(
			layout,
			sp,
			builder_sp,
		)
	else
		layout.subplots = _rebuild_subplots(
			sp;
			grid_ref = layout.subplots.grid_ref,
		)
	end
	_clear_missing_subplot_refs!(layout, sp)
	_apply_subplot_shared_axes!(layout, sp)
	_apply_subplot_title_annotations!(layout, sp)
	return layout
end
