# PlotlyBase 0.8.23 predates Plotly.js' MapLibre-backed trace constructors.
# GenericTrace is intentionally used here so support does not depend on the
# older PlotlyBase schema artifact.  The outer field dictionary is new, while
# coordinate arrays and other payloads remain shared with the caller.
scattermap(; kwargs...) = GenericTrace("scattermap"; kwargs...)
scattermap(fields::AbstractDict; kwargs...) =
	GenericTrace("scattermap", _symbol_dict(fields); kwargs...)

choroplethmap(; kwargs...) = GenericTrace("choroplethmap"; kwargs...)
choroplethmap(fields::AbstractDict; kwargs...) =
	GenericTrace("choroplethmap", _symbol_dict(fields); kwargs...)

densitymap(; kwargs...) = GenericTrace("densitymap"; kwargs...)
densitymap(fields::AbstractDict; kwargs...) =
	GenericTrace("densitymap", _symbol_dict(fields); kwargs...)

function _require_finite_map_number(
	name::AbstractString,
	value,
)
	value === nothing && return nothing
	valid = _is_finite_plotly_number(value)
	valid || throw(ArgumentError(
		"map: $name must be a finite JavaScript-representable real number, " *
		"not $(repr(value)).",
	))
	return nothing
end

function _require_valid_map_view(
	zoom,
	center_lon,
	center_lat,
)
	for (name, value) in (
		("zoom", zoom),
		("center_lon", center_lon),
		("center_lat", center_lat),
	)
		_require_finite_map_number(name, value)
	end
	return nothing
end

function _require_map_vector_length(
	kind::AbstractString,
	name::AbstractString,
	value,
	expected::Int,
)
	value isa AbstractVector || return nothing
	length(value) == expected || throw(ArgumentError(
		"$kind: $name must share the coordinate length $expected; got " *
		"$(length(value)).",
	))
	return nothing
end

function _require_valid_map_style(style)
	style === nothing && return nothing
	if style isa AbstractString
		isempty(strip(style)) && throw(ArgumentError(
			"map: style must be a nonempty named style or style URL.",
		))
		return nothing
	end
	if style isa PlotlyBase.PlotlyAttribute
		isempty(style.fields) && throw(ArgumentError(
			"map: a MapLibre style object must not be empty.",
		))
		return nothing
	end
	if style isa AbstractDict || style isa NamedTuple
		isempty(style) && throw(ArgumentError(
			"map: a MapLibre style object must not be empty.",
		))
		return nothing
	end
	throw(ArgumentError(
		"map: style must be nothing, a nonempty string, or a MapLibre style object; " *
		"got $(typeof(style)).",
	))
end

function _map_object_dict(value)
	if value isa NamedTuple
		return Dict{Symbol,Any}(Symbol(key) => item for (key, item) in pairs(value))
	end
	return _symbol_dict(value)
end

function _is_modern_map_layout_key(key)
	name = String(key)
	name == "map" && return true
	startswith(name, "map") || return false
	ncodeunits(name) > 3 || return false
	suffix = SubString(name, 4)
	all(isdigit, suffix) || return false
	first(suffix) == '0' && return false
	return suffix != "1"
end

"""
Validate every modern `layout.map`, `layout.map2`, ... object in `layout`.

Plotly.js accepts unbounded numeric map-view attributes and applies its own
camera semantics.  PlotlySupply therefore checks representation safety
(finite, non-Bool real values) without imposing narrower latitude, longitude,
or zoom ranges that are absent from the Plotly.js schema.
"""
function _require_valid_map_layouts(layout::Layout)
	for (key, value) in layout.fields
		_is_modern_map_layout_key(key) || continue
		(value isa PlotlyBase.PlotlyAttribute ||
		 value isa AbstractDict ||
		 value isa NamedTuple) || throw(ArgumentError(
			"map: layout.$key must be a map attribute object.",
		))
		_require_unambiguous_layout_mapping(
			value,
			"layout.$key",
		)
		map_options = _map_object_dict(value)

		if haskey(map_options, :style)
			_require_valid_map_style(map_options[:style])
		end
		for name in (:zoom, :bearing, :pitch)
			haskey(map_options, name) || continue
			_require_finite_map_number(String(name), map_options[name])
		end

		if haskey(map_options, :center) && map_options[:center] !== nothing
			center_value = map_options[:center]
			(center_value isa PlotlyBase.PlotlyAttribute ||
			 center_value isa AbstractDict ||
			 center_value isa NamedTuple) || throw(ArgumentError(
				"map: layout.$key.center must be an attribute object or nothing.",
			))
			_require_unambiguous_layout_mapping(
				center_value,
				"layout.$key.center",
			)
			center = _map_object_dict(center_value)
			for name in (:lon, :lat)
				haskey(center, name) || continue
				_require_finite_map_number(
					"center.$name",
					center[name],
				)
			end
		end

		if haskey(map_options, :bounds) && map_options[:bounds] !== nothing
			bounds_value = map_options[:bounds]
			(bounds_value isa PlotlyBase.PlotlyAttribute ||
			 bounds_value isa AbstractDict ||
			 bounds_value isa NamedTuple) || throw(ArgumentError(
				"map: layout.$key.bounds must be an attribute object or nothing.",
			))
			_require_unambiguous_layout_mapping(
				bounds_value,
				"layout.$key.bounds",
			)
			bounds = _map_object_dict(bounds_value)
			for name in (:west, :east, :south, :north)
				haskey(bounds, name) || continue
				_require_finite_map_number(
					"bounds.$name",
					bounds[name],
				)
			end
		end
	end
	return nothing
end

function _map_layout(
	title::String,
	style,
	zoom,
	center_lon,
	center_lat,
)
	_require_valid_map_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style)

	map_options = Dict{Symbol,Any}()
	style === nothing ||
		(map_options[:style] =
			style isa AbstractString ? String(style) : style)
	zoom === nothing || (map_options[:zoom] = zoom)

	center = Dict{Symbol,Any}()
	center_lon === nothing || (center[:lon] = center_lon)
	center_lat === nothing || (center[:lat] = center_lat)
	isempty(center) || (map_options[:center] = attr(center))

	layout = Layout(title = title)
	isempty(map_options) ||
		(layout.fields[:map] = attr(map_options))
	return layout
end

function _apply_map_layout_options!(
	fig;
	style,
	zoom,
	center_lon,
	center_lat,
)
	source = _map_layout(
		"",
		style,
		zoom,
		center_lon,
		center_lat,
	)
	haskey(source.fields, :map) || return nothing
	_merge_layout_attr!(
		_plot_layout(fig),
		:map,
		source.fields[:map];
		deep_merge_keys = (:center,),
		mutate_builtin_target = true,
	)
	return nothing
end

function _scattermap_trace(
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString,
	color,
	marker_size,
	legend::AbstractString,
	trace_kwargs,
)
	_require_equal_geo_lengths(
		"scattermap",
		:lon => lon,
		:lat => lat,
	)
	_require_map_vector_length(
		"scattermap",
		"color",
		color,
		length(lon),
	)
	_require_map_vector_length(
		"scattermap",
		"marker_size",
		marker_size,
		length(lon),
	)
	kw = _trace_keyword_dict(trace_kwargs)
	kw[:lon] = lon
	kw[:lat] = lat
	kw[:mode] = String(mode)
	_set_geo_marker!(kw, color, marker_size)
	isempty(legend) || (kw[:name] = String(legend))
	return scattermap(; kw...)
end

function _choroplethmap_trace(
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	featureidkey::AbstractString,
	colorscale,
	marker_line_color,
	marker_line_width,
	marker_opacity,
	legend::AbstractString,
	trace_kwargs,
)
	_require_equal_geo_lengths(
		"choroplethmap",
		:locations => locations,
		:z => z,
	)
	for (name, value) in (
		("marker_line_color", marker_line_color),
		("marker_line_width", marker_line_width),
		("marker_opacity", marker_opacity),
	)
		_require_map_vector_length(
			"choroplethmap",
			name,
			value,
			length(locations),
		)
	end
	marker_line_width === nothing || _require_bounded_numeric_option(
		"choroplethmap",
		"marker_line_width",
		marker_line_width;
		minimum = 0,
	)
	marker_opacity === nothing || _require_bounded_numeric_option(
		"choroplethmap",
		"marker_opacity",
		marker_opacity;
		minimum = 0,
		maximum = 1,
	)

	kw = _trace_keyword_dict(trace_kwargs)
	kw[:geojson] = geojson
	kw[:locations] = locations
	kw[:z] = z
	isempty(featureidkey) ||
		(kw[:featureidkey] = String(featureidkey))
	_set_optional_colorscale!(kw, colorscale)
	isempty(legend) || (kw[:name] = String(legend))

	marker = _symbol_dict(get(kw, :marker, nothing))
	marker_changed = false
	line = _symbol_dict(get(marker, :line, nothing))
	if marker_line_color isa AbstractString
		if !isempty(marker_line_color)
			line[:color] = String(marker_line_color)
			marker_changed = true
		end
	elseif marker_line_color !== nothing
		line[:color] = marker_line_color
		marker_changed = true
	end
	if marker_line_width !== nothing
		line[:width] = marker_line_width
		marker_changed = true
	end
	isempty(line) || (marker[:line] = attr(; line...))
	if marker_opacity !== nothing
		marker[:opacity] = marker_opacity
		marker_changed = true
	end
	marker_changed && (kw[:marker] = attr(; marker...))
	return choroplethmap(; kw...)
end

function _densitymap_trace(
	lon::AbstractVector,
	lat::AbstractVector,
	z::Union{Nothing,AbstractVector};
	radius,
	colorscale,
	trace_kwargs,
)
	if z === nothing
		_require_equal_geo_lengths(
			"densitymap",
			:lon => lon,
			:lat => lat,
		)
	else
		_require_equal_geo_lengths(
			"densitymap",
			:lon => lon,
			:lat => lat,
			:z => z,
		)
	end

	radius_is_default =
		radius === nothing ||
		(
			radius isa Real &&
			!(radius isa Bool) &&
			radius == 0
		)
	if radius isa AbstractVector
		length(radius) == length(lon) || throw(ArgumentError(
			"densitymap: radius must share lon/lat length; got " *
			"$(length(radius)) and $(length(lon)).",
		))
	end
	radius_is_default || _require_bounded_numeric_option(
		"densitymap",
		"radius",
		radius;
		minimum = 1,
	)

	kw = _trace_keyword_dict(trace_kwargs)
	kw[:lon] = lon
	kw[:lat] = lat
	z === nothing || (kw[:z] = z)
	radius_is_default || (kw[:radius] = radius)
	_set_optional_colorscale!(kw, colorscale)
	return densitymap(; kw...)
end

"""
	plot_scattermap(lon, lat; mode="markers", color="",
		marker_size=nothing, legend="", style="open-street-map", zoom=0,
		center_lon=nothing, center_lat=nothing, kwargs...)

Plot points or lines on a MapLibre-backed tile map.  The default
`"open-street-map"` style requires no Mapbox access token.
"""
function plot_scattermap(
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString = "markers",
	color::Union{Nothing,AbstractString,AbstractVector} = "",
	marker_size::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = "open-street-map",
	zoom = 0,
	center_lon = nothing,
	center_lat = nothing,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
	kwargs...,
)
	_require_valid_map_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style)
	trace = _scattermap_trace(
		lon,
		lat;
		mode = mode,
		color = color,
		marker_size = marker_size,
		legend = legend,
		trace_kwargs = kwargs,
	)
	fig = Plot(
		trace,
		_map_layout(
			title,
			style,
			zoom,
			center_lon,
			center_lat,
		),
	)
	_apply_basic_plot_options!(
		fig;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_scattermap!(fig, lon, lat; kwargs...)

Append a scattermap trace.  Omitted map-view options preserve the existing
`layout.map` object.
"""
function plot_scattermap!(
	fig,
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString = "markers",
	color::Union{Nothing,AbstractString,AbstractVector} = "",
	marker_size::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = nothing,
	zoom = nothing,
	center_lon = nothing,
	center_lat = nothing,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	kwargs...,
)
	_require_valid_map_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style)
	trace = _scattermap_trace(
		lon,
		lat;
		mode = mode,
		color = color,
		marker_size = marker_size,
		legend = legend,
		trace_kwargs = kwargs,
	)
	push!(_plot_data(fig), trace)
	_apply_map_layout_options!(
		fig;
		style = style,
		zoom = zoom,
		center_lon = center_lon,
		center_lat = center_lat,
	)
	_apply_basic_plot_options!(
		fig;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	_refresh!(fig)
	return nothing
end

"""
	plot_choroplethmap(geojson, locations, z; featureidkey="",
		colorscale="", style="open-street-map", zoom=0, kwargs...)

Shade GeoJSON features on a MapLibre-backed tile map. `locations` and `z`
must have equal lengths.
"""
function plot_choroplethmap(
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	featureidkey::AbstractString = "",
	colorscale::Union{AbstractString,AbstractVector} = "",
	marker_line_color::Union{Nothing,AbstractString,AbstractVector} = nothing,
	marker_line_width::Union{Nothing,Real,AbstractVector} = nothing,
	marker_opacity::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = "open-street-map",
	zoom = 0,
	center_lon = nothing,
	center_lat = nothing,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
	kwargs...,
)
	_require_valid_map_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style)
	trace = _choroplethmap_trace(
		geojson,
		locations,
		z;
		featureidkey = featureidkey,
		colorscale = colorscale,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		marker_opacity = marker_opacity,
		legend = legend,
		trace_kwargs = kwargs,
	)
	fig = Plot(
		trace,
		_map_layout(
			title,
			style,
			zoom,
			center_lon,
			center_lat,
		),
	)
	_apply_basic_plot_options!(
		fig;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_choroplethmap!(fig, geojson, locations, z; kwargs...)

Append a choroplethmap trace.  Omitted map-view options preserve the existing
`layout.map` object.
"""
function plot_choroplethmap!(
	fig,
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	featureidkey::AbstractString = "",
	colorscale::Union{AbstractString,AbstractVector} = "",
	marker_line_color::Union{Nothing,AbstractString,AbstractVector} = nothing,
	marker_line_width::Union{Nothing,Real,AbstractVector} = nothing,
	marker_opacity::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = nothing,
	zoom = nothing,
	center_lon = nothing,
	center_lat = nothing,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	kwargs...,
)
	_require_valid_map_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style)
	trace = _choroplethmap_trace(
		geojson,
		locations,
		z;
		featureidkey = featureidkey,
		colorscale = colorscale,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		marker_opacity = marker_opacity,
		legend = legend,
		trace_kwargs = kwargs,
	)
	push!(_plot_data(fig), trace)
	_apply_map_layout_options!(
		fig;
		style = style,
		zoom = zoom,
		center_lon = center_lon,
		center_lat = center_lat,
	)
	_apply_basic_plot_options!(
		fig;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	_refresh!(fig)
	return nothing
end

"""
	plot_densitymap(lon, lat, z=nothing; radius=nothing, colorscale="",
		style="open-street-map", zoom=0, kwargs...)

Render a MapLibre density heatmap.  Omitting `z` gives every point equal
weight.  A vector radius must have one finite value of at least 1 per point.
"""
function plot_densitymap(
	lon::AbstractVector,
	lat::AbstractVector,
	z::Union{Nothing,AbstractVector} = nothing;
	radius::Union{Nothing,Real,AbstractVector} = nothing,
	colorscale::Union{AbstractString,AbstractVector} = "",
	style = "open-street-map",
	zoom = 0,
	center_lon = nothing,
	center_lat = nothing,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	show::Bool = false,
	kwargs...,
)
	_require_valid_map_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style)
	trace = _densitymap_trace(
		lon,
		lat,
		z;
		radius = radius,
		colorscale = colorscale,
		trace_kwargs = kwargs,
	)
	fig = Plot(
		trace,
		_map_layout(
			title,
			style,
			zoom,
			center_lon,
			center_lat,
		),
	)
	_apply_basic_plot_options!(
		fig;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	return _maybe_show(fig, show, width, height, title)
end

"""
	plot_densitymap!(fig, lon, lat, z=nothing; kwargs...)

Append a densitymap trace.  Omitted map-view options preserve the existing
`layout.map` object.
"""
function plot_densitymap!(
	fig,
	lon::AbstractVector,
	lat::AbstractVector,
	z::Union{Nothing,AbstractVector} = nothing;
	radius::Union{Nothing,Real,AbstractVector} = nothing,
	colorscale::Union{AbstractString,AbstractVector} = "",
	style = nothing,
	zoom = nothing,
	center_lon = nothing,
	center_lat = nothing,
	title::String = "",
	width::Int = 0,
	height::Int = 0,
	fontsize::Int = 0,
	kwargs...,
)
	_require_valid_map_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style)
	trace = _densitymap_trace(
		lon,
		lat,
		z;
		radius = radius,
		colorscale = colorscale,
		trace_kwargs = kwargs,
	)
	push!(_plot_data(fig), trace)
	_apply_map_layout_options!(
		fig;
		style = style,
		zoom = zoom,
		center_lon = center_lon,
		center_lat = center_lat,
	)
	_apply_basic_plot_options!(
		fig;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
		apply_template = false,
	)
	_refresh!(fig)
	return nothing
end
