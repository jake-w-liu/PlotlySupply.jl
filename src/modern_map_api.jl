# PlotlyBase 0.8.23 predates Plotly.js' MapLibre-backed trace constructors.
# GenericTrace is intentionally used here so support does not depend on the
# older PlotlyBase schema artifact.  The outer field dictionary is new, while
# coordinate arrays and other payloads remain shared with the caller.
"""
	scattermap(; kwargs...)
	scattermap(fields::AbstractDict; kwargs...)

Construct a `scattermap` trace: points, lines, or text rendered on a
MapLibre-backed tile map. Keyword arguments or `fields` become trace
attributes; see the [plotly.js figure
reference](https://plotly.com/julia/reference/).
"""
scattermap(; kwargs...) = GenericTrace("scattermap"; kwargs...)
scattermap(fields::AbstractDict; kwargs...) =
	GenericTrace("scattermap", _symbol_dict(fields); kwargs...)

"""
	choroplethmap(; kwargs...)
	choroplethmap(fields::AbstractDict; kwargs...)

Construct a `choroplethmap` trace: filled regions rendered on a MapLibre-backed
tile map. Keyword arguments or `fields` become trace attributes; see the
[plotly.js figure reference](https://plotly.com/julia/reference/).
"""
choroplethmap(; kwargs...) = GenericTrace("choroplethmap"; kwargs...)
choroplethmap(fields::AbstractDict; kwargs...) =
	GenericTrace("choroplethmap", _symbol_dict(fields); kwargs...)

"""
	densitymap(; kwargs...)
	densitymap(fields::AbstractDict; kwargs...)

Construct a `densitymap` trace: a density heatmap rendered on a MapLibre-backed
tile map. Keyword arguments or `fields` become trace attributes; see the
[plotly.js figure reference](https://plotly.com/julia/reference/).
"""
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

# A tile-map `style` (MapLibre `map` or legacy `mapbox` family) is `nothing`
# (keep / plotly.js default), a nonempty style name or URL, or a nonempty
# style object. An empty or blank name never finishes loading in plotly.js,
# so it is rejected up front.
function _require_valid_map_style(
	style;
	family::AbstractString = "map",
)
	style === nothing && return nothing
	object_name = family == "mapbox" ? "Mapbox" : "MapLibre"
	if style isa AbstractString
		isempty(strip(style)) && throw(ArgumentError(
			"$family: style must be a nonempty named style or style URL.",
		))
		return nothing
	end
	if style isa PlotlyBase.PlotlyAttribute
		isempty(style.fields) && throw(ArgumentError(
			"$family: a $object_name style object must not be empty.",
		))
		return nothing
	end
	if style isa AbstractDict || style isa NamedTuple
		isempty(style) && throw(ArgumentError(
			"$family: a $object_name style object must not be empty.",
		))
		return nothing
	end
	throw(ArgumentError(
		"$family: style must be nothing, a nonempty string, or a " *
		"$object_name style object; got $(typeof(style)).",
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
or zoom ranges that are absent from the Plotly.js schema.  A `nothing` root
is Plotly's "all defaults" and is valid.
"""
function _require_valid_map_layouts(layout::Layout)
	for (key, value) in layout.fields
		_is_modern_map_layout_key(key) || continue
		value === nothing && continue
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

	layout = Layout()
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

# Shared trace builder of choroplethmap (`kind = "choroplethmap"`) and the
# legacy choroplethmapbox. Per-location marker vectors must match
# `locations`: plotly.js silently reuses or drops entries otherwise.
function _choroplethmap_trace(
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	kind::AbstractString = "choroplethmap",
	constructor = choroplethmap,
	featureidkey::AbstractString,
	colorscale,
	marker_line_color,
	marker_line_width,
	marker_opacity,
	legend::AbstractString,
	trace_kwargs,
)
	_require_equal_geo_lengths(
		kind,
		:locations => locations,
		:z => z,
	)
	# plotly.js draws nothing (and reports no error) without usable GeoJSON.
	_is_plotly_geojson(geojson) || throw(ArgumentError(
		"$kind: `geojson` must be a GeoJSON object (Dict, attr or " *
		"NamedTuple) or a nonempty URL string; got $(typeof(geojson)).",
	))
	for (name, value) in (
		("marker_line_color", marker_line_color),
		("marker_line_width", marker_line_width),
		("marker_opacity", marker_opacity),
	)
		_require_map_vector_length(
			kind,
			name,
			value,
			length(locations),
		)
	end
	marker_line_width === nothing || _require_bounded_numeric_option(
		kind,
		"marker_line_width",
		marker_line_width;
		minimum = 0,
	)
	marker_opacity === nothing || _require_bounded_numeric_option(
		kind,
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
	if marker_line_color isa Union{AbstractString,Symbol}
		text = String(marker_line_color)
		if !isempty(text)
			line[:color] = text
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
	return constructor(; kw...)
end

# Shared trace builder of densitymap (`z` may be `nothing`: equal weights)
# and the legacy densitymapbox. `radius` `nothing` or scalar `0` keeps the
# plotly.js default; every emitted radius must satisfy the schema min of 1.
function _densitymap_trace(
	lon::AbstractVector,
	lat::AbstractVector,
	z::Union{Nothing,AbstractVector};
	kind::AbstractString = "densitymap",
	constructor = densitymap,
	radius,
	colorscale,
	trace_kwargs,
)
	if z === nothing
		_require_equal_geo_lengths(
			kind,
			:lon => lon,
			:lat => lat,
		)
	else
		_require_equal_geo_lengths(
			kind,
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
	_require_map_vector_length(kind, "radius", radius, length(lon))
	radius_is_default || _require_bounded_numeric_option(
		kind,
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
	return constructor(; kw...)
end

"""
	plot_scattermap(lon, lat; mode="markers", color="", marker_size=nothing,
		legend="", style="open-street-map", zoom=0, center_lon=nothing,
		center_lat=nothing, title="", width=0, height=0, fontsize=0,
		show=false, kwargs...)

Scatter points (or lines) on a MapLibre-backed tile map at `(lon, lat)`
(degrees). The default `"open-street-map"` style needs no access token.

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
- `style = "open-street-map"`: a nonempty MapLibre style name
  (`"carto-positron"`, `"carto-darkmatter"`, `"white-bg"`, ...), style URL, or
  nonempty style object.
- `zoom = 0`: initial zoom level (finite number).
- `center_lon = nothing`, `center_lat = nothing`: initial map centre in
  degrees (`nothing` keeps plotly.js' automatic centre).
- `title::AbstractString = ""`: figure title.
- `width::Real = 0`, `height::Real = 0`: figure size in pixels (0 = automatic,
  otherwise at least 10; rounded to whole pixels).
- `fontsize::Real = 0`: global font size (0 = template default, otherwise ≥ 1).
- `show::Bool = false`: open the figure in a window and return a `SyncPlot`.
- `kwargs...`: further Plotly `scattermap` trace attributes.

Throws `ArgumentError` for mismatched lengths (including per-point `color`
or `marker_size` vectors), negative sizes, an empty or invalid `style`,
non-finite view values, or invalid figure sizes.

Returns a `Plot`, or a `SyncPlot` when `show=true`.

# Example
```julia
fig = plot_scattermap([2.35, 13.40], [48.86, 52.52]; zoom=3,
	center_lon=8, center_lat=50, legend="cities")
```
"""
function plot_scattermap(
	lon::AbstractVector,
	lat::AbstractVector;
	mode::AbstractString = "markers",
	color::Union{Nothing,AbstractString,Symbol,AbstractVector} = "",
	marker_size::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = "open-street-map",
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
		"plot_scattermap";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _map_layout(style, zoom, center_lon, center_lat)
	trace = _geo_scatter_trace(
		"scattermap",
		scattermap,
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
	plot_scattermap!(fig, lon, lat; mode="markers", color="",
		marker_size=nothing, legend="", style=nothing, zoom=nothing,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, kwargs...)
	plot_scattermap!(sf::SubplotFigure, lon, lat; row=nothing, col=nothing, kwargs...)

Append a scattermap trace (see [`plot_scattermap`](@ref) for the arguments
and keywords; `show` is not accepted). `fig` is a `Plot`, a `SyncPlot` or a
`SubplotFigure`; on a `SubplotFigure` the trace goes to the `map` cell given
by `row`/`col` (pass both; default: the active cell) and `title`/`width`/
`height` are ignored with a warning (they are figure-wide).

The map-view keywords default to `nothing`, which keeps the existing
`layout.map` values; a partial centre keeps the other coordinate. A `title`
keeps the existing title's position and font, and a user template is
preserved.

Throws `ArgumentError` (leaving `fig` unchanged) for invalid input.
Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_scattermap([2.35], [48.86]; legend="Paris", zoom=4)
plot_scattermap!(fig, [13.40], [52.52]; legend="Berlin", color=:red)
```
"""
function plot_scattermap!(
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
		"plot_scattermap!";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_map_view(zoom, center_lon, center_lat)
	_require_valid_map_style(style)
	trace = _geo_scatter_trace(
		"scattermap",
		scattermap,
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
	_apply_geo_figure_options!(fig, options; apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_choroplethmap(geojson, locations, z; featureidkey="", colorscale="",
		marker_line_color=nothing, marker_line_width=nothing,
		marker_opacity=nothing, legend="", style="open-street-map", zoom=0,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, show=false, kwargs...)

Shade GeoJSON features on a MapLibre-backed tile map.

# Arguments
- `geojson`: a GeoJSON `FeatureCollection` (`Dict`, `attr`, `NamedTuple`) or
  a nonempty URL string.
- `locations::AbstractVector`: feature ids matched against `featureidkey`.
- `z::AbstractVector`: one value per location (same length as `locations`).

# Keywords
- `featureidkey::AbstractString = ""`: feature property matched by
  `locations` (`""` = plotly.js default `"id"`), e.g. `"properties.name"`.
- `colorscale::Union{AbstractString,AbstractVector} = ""`: Plotly colorscale
  name or `[[t, color], ...]` stops; `""` keeps the default.
- `marker_line_color::Union{Nothing,AbstractString,Symbol,AbstractVector} = nothing`:
  boundary colour, scalar or one per location.
- `marker_line_width::Union{Nothing,Real,AbstractVector} = nothing`: boundary
  width in pixels (≥ 0), scalar or one per location.
- `marker_opacity::Union{Nothing,Real,AbstractVector} = nothing`: fill opacity
  in [0, 1], scalar or one per location.
- `legend::AbstractString = ""`: legend name of the trace.
- `style`, `zoom`, `center_lon`, `center_lat`: map view, as for
  [`plot_scattermap`](@ref).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_scattermap`](@ref).
- `kwargs...`: further Plotly `choroplethmap` trace attributes.

Throws `ArgumentError` for an invalid `geojson`, mismatched lengths
(including per-location marker vectors), out-of-range marker values, and
invalid map-view or size values.

Returns a `Plot`, or a `SyncPlot` when `show=true`.

# Example
```julia
square = Dict("type" => "FeatureCollection", "features" => [Dict(
	"type" => "Feature", "id" => "A", "properties" => Dict(),
	"geometry" => Dict("type" => "Polygon",
		"coordinates" => [[[0, 0], [0, 5], [5, 5], [5, 0], [0, 0]]]))])
fig = plot_choroplethmap(square, ["A"], [1.0]; zoom=3, center_lon=2.5, center_lat=2.5)
```
"""
function plot_choroplethmap(
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	featureidkey::AbstractString = "",
	colorscale::Union{AbstractString,AbstractVector} = "",
	marker_line_color::Union{Nothing,AbstractString,Symbol,AbstractVector} = nothing,
	marker_line_width::Union{Nothing,Real,AbstractVector} = nothing,
	marker_opacity::Union{Nothing,Real,AbstractVector} = nothing,
	legend::AbstractString = "",
	style = "open-street-map",
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
		"plot_choroplethmap";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _map_layout(style, zoom, center_lon, center_lat)
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
	plot_choroplethmap!(fig, geojson, locations, z; featureidkey="",
		colorscale="", marker_line_color=nothing, marker_line_width=nothing,
		marker_opacity=nothing, legend="", style=nothing, zoom=nothing,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, kwargs...)
	plot_choroplethmap!(sf::SubplotFigure, geojson, locations, z; row=nothing, col=nothing, kwargs...)

Append a choroplethmap trace (see [`plot_choroplethmap`](@ref) for the
arguments and keywords; `show` is not accepted). `fig` is a `Plot`, a
`SyncPlot` or a `SubplotFigure`; on a `SubplotFigure` the trace goes to the
`map` cell given by `row`/`col` (pass both; default: the active cell) and
`title`/`width`/`height` are ignored with a warning.

The map-view keywords default to `nothing`, which keeps the existing
`layout.map` values. Throws `ArgumentError` (leaving `fig` unchanged) for
invalid input. Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_scattermap([2.5], [2.5]; zoom=3)
plot_choroplethmap!(fig, square, ["A"], [1.0]; marker_opacity=0.5)
```
"""
function plot_choroplethmap!(
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
		"plot_choroplethmap!";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
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
	_apply_geo_figure_options!(fig, options; apply_template = false)
	_refresh!(fig)
	return nothing
end

"""
	plot_densitymap(lon, lat, z=nothing; radius=nothing, colorscale="",
		style="open-street-map", zoom=0, center_lon=nothing, center_lat=nothing,
		title="", width=0, height=0, fontsize=0, show=false, kwargs...)

Density heatmap of the points `(lon, lat)` (degrees) on a MapLibre-backed
tile map.

# Arguments
- `lon::AbstractVector`, `lat::AbstractVector`: point coordinates.
- `z::Union{Nothing,AbstractVector} = nothing`: point weights (same length as
  `lon`/`lat`); `nothing` gives every point equal weight.

# Keywords
- `radius::Union{Nothing,Real,AbstractVector} = nothing`: influence radius of
  each point in pixels, scalar or one per point, each ≥ 1. `nothing` (or `0`)
  keeps plotly.js' default.
- `colorscale::Union{AbstractString,AbstractVector} = ""`: colorscale name or stops.
- `style`, `zoom`, `center_lon`, `center_lat`: map view, as for
  [`plot_scattermap`](@ref).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_scattermap`](@ref).
- `kwargs...`: further Plotly `densitymap` trace attributes.

Throws `ArgumentError` for mismatched lengths (including a per-point
`radius`), radii below 1 and invalid map-view or size values.

Returns a `Plot`, or a `SyncPlot` when `show=true`.

# Example
```julia
fig = plot_densitymap(randn(200), randn(200); radius=15, zoom=4)
```
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
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	show::Bool = false,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_densitymap";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _map_layout(style, zoom, center_lon, center_lat)
	trace = _densitymap_trace(
		lon,
		lat,
		z;
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
	plot_densitymap!(fig, lon, lat, z=nothing; radius=nothing, colorscale="",
		style=nothing, zoom=nothing, center_lon=nothing, center_lat=nothing,
		title="", width=0, height=0, fontsize=0, kwargs...)
	plot_densitymap!(sf::SubplotFigure, lon, lat, z=nothing; row=nothing, col=nothing, kwargs...)

Append a densitymap trace (see [`plot_densitymap`](@ref) for the arguments
and keywords; `show` is not accepted). `fig` is a `Plot`, a `SyncPlot` or a
`SubplotFigure`; on a `SubplotFigure` the trace goes to the `map` cell given
by `row`/`col` (pass both; default: the active cell) and `title`/`width`/
`height` are ignored with a warning.

The map-view keywords default to `nothing`, which keeps the existing
`layout.map` values. Throws `ArgumentError` (leaving `fig` unchanged) for
invalid input. Returns `nothing` (`sf` for a `SubplotFigure`).

# Example
```julia
fig = plot_scattermap([0.0], [0.0])
plot_densitymap!(fig, randn(50), randn(50); radius=20)
```
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
	title::AbstractString = "",
	width::Real = 0,
	height::Real = 0,
	fontsize::Real = 0,
	kwargs...,
)
	options = _geo_figure_options(
		"plot_densitymap!";
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
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
	_apply_geo_figure_options!(fig, options; apply_template = false)
	_refresh!(fig)
	return nothing
end
