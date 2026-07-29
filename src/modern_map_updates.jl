# PlotlyBase's layout-updater registry predates `layout.map`.  Keep this
# updater package-owned so adding MapLibre support does not mutate or replace
# methods in the dependency.

function _combined_map_update(
	with::PlotlyBase.PlotlyAttribute,
	kwargs,
)
	update = attr()
	# PlotlyBase's generic associative setter recursively expands dictionaries.
	# `layout.map.style`, however, is itself an opaque MapLibre style object:
	# preserve it by identity. Center/bounds are shallow-wrapped so flattened
	# keyword setters cannot mutate a caller-owned nested object before
	# validation (including when validation subsequently fails).
	for (key, value) in with.fields
		symbol_key = Symbol(key)
		if symbol_key in (:center, :bounds) &&
			(value isa PlotlyBase.PlotlyAttribute ||
			 value isa AbstractDict ||
			 value isa NamedTuple)
			update.fields[symbol_key] = attr(_map_object_dict(value))
		else
			update.fields[symbol_key] = value
		end
	end
	for (key, value) in pairs(kwargs)
		symbol_key = Symbol(key)
		if symbol_key in (:center, :bounds) &&
			(value isa PlotlyBase.PlotlyAttribute ||
			 value isa AbstractDict ||
			 value isa NamedTuple)
			update.fields[symbol_key] = attr(_map_object_dict(value))
		elseif symbol_key === :style &&
			(value isa PlotlyBase.PlotlyAttribute ||
			 value isa AbstractDict ||
			 value isa NamedTuple)
			update.fields[symbol_key] = value
		else
			update[symbol_key] = value
		end
	end
	return update
end

function _prospective_map_options(current, update)
	current_options = _map_object_dict(current)
	update_options = _map_object_dict(update)
	for (key, value) in update_options
		if key in (:center, :bounds) &&
			value !== nothing &&
			haskey(current_options, key)
			current_nested = current_options[key]
			if (current_nested isa PlotlyBase.PlotlyAttribute ||
				current_nested isa AbstractDict ||
				current_nested isa NamedTuple) &&
				(value isa PlotlyBase.PlotlyAttribute ||
				 value isa AbstractDict ||
				 value isa NamedTuple)
				nested = _map_object_dict(current_nested)
				merge!(nested, _map_object_dict(value))
				current_options[key] = attr(nested)
				continue
			end
		end
		current_options[key] = value
	end
	return attr(current_options)
end

function _require_valid_map_update(
	layout::Layout,
	update::PlotlyBase.PlotlyAttribute,
)
	targets = Symbol[
		key for key in keys(layout.fields)
		if _is_modern_map_layout_key(key)
	]
	isempty(targets) && push!(targets, :map)

	# Validate small, shallow prospective containers. Large style/layer
	# payloads remain shared; only the map/center/bounds dictionaries are new.
	for key in targets
		current = get(layout.fields, key, attr())
		(current isa PlotlyBase.PlotlyAttribute ||
		 current isa AbstractDict ||
		 current isa NamedTuple) || throw(ArgumentError(
			"map: layout.$key must be a map attribute object.",
		))
		prospective = _prospective_map_options(
			current,
			update,
		)
		probe = Layout()
		probe.fields[:map] = prospective
		_require_valid_map_layouts(probe)
	end
	return nothing
end

function _require_valid_finalized_map_layouts(
	mutations,
	layout::Layout,
	targets,
)
	for key in targets
		projected = _finalized_layout_attr(
			mutations,
			_finalized_layout_value(
				mutations,
				layout,
				key,
			),
			(:center, :bounds),
		)
		probe = Layout()
		probe.fields[:map] = projected
		_require_valid_map_layouts(probe)
	end
	return nothing
end

function _update_all_maps!(
	layout::Layout,
	update::PlotlyBase.PlotlyAttribute,
)
	targets = Symbol[
		key for key in keys(layout.fields)
		if _is_modern_map_layout_key(key)
	]
	:map in targets || pushfirst!(targets, :map)
	context = _new_layout_merge_context()
	for key in targets
		_prepare_layout_attr_merge!(
			context,
			layout,
			key,
			update;
			deep_merge_keys = (:center, :bounds),
			mutate_builtin_target = true,
		)
	end
	mutations = _finalize_layout_merge_context(context)
	_require_valid_finalized_map_layouts(
		mutations,
		layout,
		targets,
	)
	_commit_layout_merge_context!(context, mutations)
	return layout
end

"""
	update_maps!(layout_or_figure, with=attr(); kwargs...)

Update every MapLibre-backed `layout.map`, `layout.map2`, ... object. Nested
`center` and `bounds` fields merge, so a partial update preserves unspecified
coordinates. Invalid map view/style values are rejected before mutation.
"""
function update_maps!(
	layout::Layout,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	update = _combined_map_update(with, kwargs)
	_require_valid_map_update(layout, update)
	return _update_all_maps!(layout, update)
end

function update_maps!(
	plot::Plot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	update_maps!(plot.layout, with; kwargs...)
	return plot
end

function update_maps!(
	staged::_StagedPlotMutation,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	update_maps!(staged.plot.layout, with; kwargs...)
	return staged
end
