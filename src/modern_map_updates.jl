# PlotlyBase's layout-updater registry predates `layout.map`.  Keep this
# updater package-owned so adding MapLibre support does not mutate or replace
# methods in the dependency.

const _MAP_NESTED_UPDATE_KEYS = (:center, :bounds)

# The nested root (`:center` / `:bounds`) a flattened keyword such as
# `center_lon` or `bounds_west` writes into, or `nothing`.
function _flattened_map_nested_root(key::Symbol)
	name = String(key)
	for root in _MAP_NESTED_UPDATE_KEYS
		startswith(name, string(root, "_")) && return root
	end
	return nothing
end

# Stage a structured `center`/`bounds` value. Mappings merge per leaf into a
# mapping staged earlier in the same call (later wins), so
# `center_lon = 1, center = attr(lat = 2)` keeps both coordinates. The merged
# container is new, so caller-owned objects are never mutated.
function _stage_map_nested_update!(
	update::PlotlyBase.PlotlyAttribute,
	flattened_roots::Set{Symbol},
	key::Symbol,
	value,
)
	if value === nothing
		key in flattened_roots && throw(ArgumentError(
			"map: `$key = nothing` cannot be combined with `$(key)_*` " *
			"keywords in the same update.",
		))
		update.fields[key] = nothing
	elseif _is_layout_mapping(value)
		staged = get(update.fields, key, nothing)
		merged =
			_is_layout_mapping(staged) ?
			_map_object_dict(staged) :
			Dict{Symbol,Any}()
		merge!(merged, _map_object_dict(value))
		update.fields[key] = attr(merged)
	else
		# Not a mapping: `_require_valid_map_layouts` rejects it with the
		# attribute path.
		update.fields[key] = value
	end
	return nothing
end

function _combined_map_update(
	with::PlotlyBase.PlotlyAttribute,
	kwargs,
)
	update = attr()
	flattened_roots = Set{Symbol}()
	# PlotlyBase's generic associative setter recursively expands dictionaries.
	# `layout.map.style`, however, is itself an opaque MapLibre style object:
	# preserve it by identity. Center/bounds are shallow-copied so flattened
	# keyword setters cannot mutate a caller-owned nested object before
	# validation (including when validation subsequently fails).
	for (key, value) in with.fields
		symbol_key = Symbol(key)
		if symbol_key in _MAP_NESTED_UPDATE_KEYS
			_stage_map_nested_update!(
				update,
				flattened_roots,
				symbol_key,
				value,
			)
		else
			update.fields[symbol_key] = value
		end
	end
	for (key, value) in pairs(kwargs)
		symbol_key = Symbol(key)
		root = _flattened_map_nested_root(symbol_key)
		if symbol_key in _MAP_NESTED_UPDATE_KEYS
			_stage_map_nested_update!(
				update,
				flattened_roots,
				symbol_key,
				value,
			)
		elseif symbol_key === :style && _is_layout_mapping(value)
			update.fields[symbol_key] = value
		elseif root !== nothing
			if haskey(update.fields, root)
				staged = update.fields[root]
				staged === nothing && throw(ArgumentError(
					"map: `$symbol_key` cannot be combined with " *
					"`$root = nothing` in the same update.",
				))
				_is_layout_mapping(staged) || throw(ArgumentError(
					"map: `$root` must be an attribute object or nothing " *
					"to combine it with `$symbol_key`; got " *
					"$(typeof(staged)).",
				))
			end
			push!(flattened_roots, root)
			update[symbol_key] = value
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
		current = get(layout.fields, key, nothing)
		# A missing or `nothing` root is Plotly's "all defaults".
		current === nothing && (current = attr())
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
		value = _finalized_layout_value(
			mutations,
			layout,
			key,
		)
		_require_unambiguous_layout_mapping(
			value,
			"layout.$key",
		)
		contents = _finalized_layout_mapping_dict(
			mutations,
			value,
		)
		for nested_key in (:center, :bounds)
			haskey(contents, nested_key) || continue
			nested = contents[nested_key]
			_is_layout_mapping(nested) || continue
			_require_unambiguous_layout_mapping(
				nested,
				"layout.$key.$nested_key",
			)
		end
		projected = _finalized_layout_attr(
			mutations,
			value,
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

"""
	update_maps!(fig, with=attr(); kwargs...)

Update every MapLibre `layout.map`, `layout.map2`, ... object of `fig`, a
`Layout`, `Plot` or `SyncPlot` (a figure without a map object gets
`layout.map`). For one cell of a `SubplotFigure` see
`update_maps!(sf::SubplotFigure; row, col, ...)`.

`with` and the keywords are Plotly `layout.map` attributes: `style` (a
nonempty style name/URL or a nonempty MapLibre style object), `zoom`,
`bearing`, `pitch`, `center` (`center_lon`, `center_lat`), `bounds`
(`bounds_west`, ...), `layers`, … Nested `center` and `bounds` values merge,
so a partial update keeps the unspecified coordinates; structured and
flattened forms combine (`center_lon=1, center=attr(lat=2)` sets both), and
`center=nothing` resets the centre (it cannot be combined with
`center_*` keywords in the same call).

Invalid view values (non-finite numbers), an empty style, or a non-object
`center`/`bounds` throw `ArgumentError` before anything changes. A `nothing`
map object is treated as empty. Returns `fig`.

# Example
```julia
fig = plot_scattermap([2.35], [48.86])
update_maps!(fig; style="carto-positron", zoom=5, center_lon=2.35, center_lat=48.86)
```
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
