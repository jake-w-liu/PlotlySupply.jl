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

# Example
```julia
t = scattermap(lon = [2.35, 13.40], lat = [48.86, 52.52], mode = "markers")
fig = plot(t, Layout(map = attr(style = "open-street-map", zoom = 3)))
```
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

# Example
```julia
square = Dict("type" => "FeatureCollection", "features" => [Dict(
	"type" => "Feature", "id" => "A", "properties" => Dict(),
	"geometry" => Dict("type" => "Polygon",
		"coordinates" => [[[0, 0], [0, 5], [5, 5], [5, 0], [0, 0]]]))])
t = choroplethmap(geojson = square, locations = ["A"], z = [1.0])
fig = plot(t, Layout(map = attr(style = "open-street-map", zoom = 3)))
```
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

# Example
```julia
t = densitymap(lon = [2.35, 2.36, 2.40], lat = [48.86, 48.85, 48.87], z = [1.0, 2.0, 3.0])
fig = plot(t, Layout(map = attr(style = "open-street-map", zoom = 9)))
```
"""
densitymap(; kwargs...) = GenericTrace("densitymap"; kwargs...)
densitymap(fields::AbstractDict; kwargs...) =
	GenericTrace("densitymap", _symbol_dict(fields); kwargs...)

function _require_finite_map_number(
	name::AbstractString,
	value;
	who::AbstractString = "map",
)
	value === nothing && return nothing
	valid = _is_finite_plotly_number(value)
	valid || throw(ArgumentError(
		"$who: $name must be a finite JavaScript-representable real number, " *
		"not $(repr(value)).",
	))
	return nothing
end

function _require_valid_map_view(
	zoom,
	center_lon,
	center_lat;
	who::AbstractString = "map",
)
	for (name, value) in (
		("zoom", zoom),
		("center_lon", center_lon),
		("center_lat", center_lat),
	)
		_require_finite_map_number(name, value; who = who)
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
# so it is rejected up front. `who` prefixes the errors (the public function
# when called from a plotting function).
function _require_valid_map_style(
	style;
	family::AbstractString = "map",
	who::AbstractString = family,
)
	style === nothing && return nothing
	object_name = family == "mapbox" ? "Mapbox" : "MapLibre"
	if style isa AbstractString
		isempty(strip(style)) && throw(ArgumentError(
			"$who: style must be a nonempty named style or style URL.",
		))
		return nothing
	end
	if style isa PlotlyBase.PlotlyAttribute
		isempty(style.fields) && throw(ArgumentError(
			"$who: a $object_name style object must not be empty.",
		))
		return nothing
	end
	if style isa AbstractDict || style isa NamedTuple
		isempty(style) && throw(ArgumentError(
			"$who: a $object_name style object must not be empty.",
		))
		return nothing
	end
	throw(ArgumentError(
		"$who: style must be nothing, a nonempty string, or a " *
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
	center_lat;
	who::AbstractString = "map",
)
	_require_valid_map_view(zoom, center_lon, center_lat; who = who)
	_require_valid_map_style(style; who = who)

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
# `locations`: plotly.js silently reuses or drops entries otherwise. Errors
# name `who`, the public function.
function _choroplethmap_trace(
	geojson,
	locations::AbstractVector,
	z::AbstractVector;
	who::AbstractString,
	kind::AbstractString = "choroplethmap",
	constructor = choroplethmap,
	featureidkey::AbstractString,
	colorscale,
	marker_line_color,
	marker_line_width,
	marker_opacity,
	legend::AbstractString,
	trace,
)
	_require_equal_geo_lengths(
		who,
		:locations => locations,
		:z => z,
	)
	_require_nonempty_map_data(who, "locations", locations)
	# plotly.js draws nothing (and reports no error) without usable GeoJSON.
	_is_plotly_geojson(geojson) || throw(ArgumentError(
		"$who: `geojson` must be a GeoJSON object (Dict, attr or " *
		"NamedTuple) or a nonempty URL string; got $(typeof(geojson)).",
	))
	for (name, value) in (
		("marker_line_color", marker_line_color),
		("marker_line_width", marker_line_width),
		("marker_opacity", marker_opacity),
	)
		_require_map_vector_length(
			who,
			name,
			value,
			length(locations),
		)
	end
	marker_line_width === nothing || _require_bounded_numeric_option(
		who,
		"marker_line_width",
		marker_line_width;
		minimum = 0,
	)
	marker_opacity === nothing || _require_bounded_numeric_option(
		who,
		"marker_opacity",
		marker_opacity;
		minimum = 0,
		maximum = 1,
	)
	name = _extended_label(legend, who, "legend")
	scale = _map_colorscale(who, colorscale)
	built = _map_base_trace(
		who,
		kind,
		constructor,
		trace;
		reserved = (
			"geojson" => "the positional arguments",
			"locations" => "the positional arguments",
			"z" => "the positional arguments",
			"featureidkey" => "the `featureidkey` keyword",
		),
		controlled = (
			(:marker, :line, :color) => "marker_line_color",
			(:marker, :line, :width) => "marker_line_width",
			(:marker, :opacity) => "marker_opacity",
		),
	)
	_map_set!(built, geojson, :geojson)
	_map_set!(built, locations, :locations)
	_map_set!(built, z, :z)
	isempty(featureidkey) || _map_set!(built, String(featureidkey), :featureidkey)
	scale === nothing || _map_set!(built, scale, :colorscale)
	if marker_line_color isa Union{AbstractString, Symbol}
		text = String(marker_line_color)
		isempty(text) || _map_set!(built, text, :marker, :line, :color)
	elseif marker_line_color !== nothing
		_map_set!(built, marker_line_color, :marker, :line, :color)
	end
	marker_line_width === nothing ||
		_map_set!(built, marker_line_width, :marker, :line, :width)
	marker_opacity === nothing || _map_set!(built, marker_opacity, :marker, :opacity)
	_map_set_legend!(built, name)
	return built
end

# Shared trace builder of densitymap (`z` may be `nothing`: equal weights)
# and the legacy densitymapbox. `radius` `nothing` or scalar `0` keeps the
# plotly.js default; every emitted radius must satisfy the schema min of 1.
# Errors name `who`, the public function.
function _densitymap_trace(
	lon::AbstractVector,
	lat::AbstractVector,
	z::Union{Nothing,AbstractVector};
	who::AbstractString,
	kind::AbstractString = "densitymap",
	constructor = densitymap,
	radius,
	colorscale,
	legend::AbstractString,
	trace,
)
	if z === nothing
		_require_equal_geo_lengths(
			who,
			:lon => lon,
			:lat => lat,
		)
	else
		_require_equal_geo_lengths(
			who,
			:lon => lon,
			:lat => lat,
			:z => z,
		)
	end
	_require_nonempty_map_data(who, "lon", lon)

	radius_is_default =
		radius === nothing ||
		(
			radius isa Real &&
			!(radius isa Bool) &&
			radius == 0
		)
	_require_map_vector_length(who, "radius", radius, length(lon))
	radius_is_default || _require_bounded_numeric_option(
		who,
		"radius",
		radius;
		minimum = 1,
	)

	scale = _map_colorscale(who, colorscale)
	name = _extended_label(legend, who, "legend")
	built = _map_base_trace(
		who,
		kind,
		constructor,
		trace;
		reserved = (
			"lon" => "the positional arguments",
			"lat" => "the positional arguments",
			"z" => "the positional arguments",
			"radius" => "the `radius` keyword",
		),
	)
	_map_set!(built, lon, :lon)
	_map_set!(built, lat, :lat)
	z === nothing || _map_set!(built, z, :z)
	radius_is_default || _map_set!(built, radius, :radius)
	scale === nothing || _map_set!(built, scale, :colorscale)
	_map_set_legend!(built, name)
	return built
end

"""
	plot_scattermap(lon, lat; mode="markers", color="", marker_size=nothing,
		colorscale="", legend="", style="open-street-map", zoom=0,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, trace=nothing, show=false)

Scatter points (or lines) on a MapLibre-backed tile map at `(lon, lat)`
(degrees). The default `"open-street-map"` style needs no access token.

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
- `colorscale = ""`: colour scale of numeric `color` values, resolved like
  every `colorscale` of the package (`colormap` names with matplotlib
  orientation, `"_r"` reverses, colour vectors, `[t, colour]` stops, a
  `ColorScheme`; unknown names throw). Needs `color` as one number per point.
- `legend::AbstractString = ""`: legend name of the trace (mathtext).
- `style = "open-street-map"`: a nonempty MapLibre style name
  (`"carto-positron"`, `"carto-darkmatter"`, `"white-bg"`, ...), style URL, or
  nonempty style object.
- `zoom = 0`: initial zoom level (finite number).
- `center_lon = nothing`, `center_lat = nothing`: initial map centre in
  degrees (`nothing` keeps plotly.js' automatic centre).
- `title::AbstractString = ""`: figure title (mathtext, see `mathtext`).
- `width::Real = 0`, `height::Real = 0`: figure size in pixels (0 = automatic,
  otherwise at least 10; rounded to whole pixels).
- `fontsize::Real = 0`: global font size (0 = template default, otherwise ≥ 1).
- `trace = nothing`: raw plotly.js `scattermap` trace attributes as
  `attr(...)` (or a Dict/NamedTuple), nested ones written with underscores:
  `trace = attr(hovertemplate = "%{lon}", marker_opacity = 0.7)`. This is
  the only raw pass-through; its values are passed on unchanged. A name that
  is not a `scattermap` attribute of the bundled plotly.js throws, as do the
  attributes set from the arguments above (`lon`, `lat`, `mode`,
  `marker_color`, `marker_size`, `name`: use `legend`, any `colorscale`).
- `show::Bool = false`: open the figure in a window and return a `SyncPlot`.

Any other keyword argument throws `ArgumentError`. So do empty or mismatched
coordinates (including per-point `color` or `marker_size` vectors), negative
sizes, a `colorscale` without numeric `color`, an unknown colour-scale name,
an empty or invalid `style`, non-finite view values, or invalid figure sizes.

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
	colorscale = "",
	legend::AbstractString = "",
	style = "open-street-map",
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
	who = "plot_scattermap"
	_map_reject_keywords(who, kwargs; mutator = false)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _map_layout(style, zoom, center_lon, center_lat; who = who)
	built = _geo_scatter_trace(
		"scattermap",
		scattermap,
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
	plot_scattermap!(fig, lon, lat; mode="markers", color="",
		marker_size=nothing, colorscale="", legend="", style=nothing,
		zoom=nothing, center_lon=nothing, center_lat=nothing, title="",
		width=0, height=0, fontsize=0, trace=nothing)
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
	who = "plot_scattermap!"
	_map_reject_keywords(who, kwargs; mutator = true)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_map_view(zoom, center_lon, center_lat; who = who)
	_require_valid_map_style(style; who = who)
	built = _geo_scatter_trace(
		"scattermap",
		scattermap,
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
		fontsize=0, trace=nothing, show=false)

Shade GeoJSON features on a MapLibre-backed tile map.

# Arguments
- `geojson`: a GeoJSON `FeatureCollection` (`Dict`, `attr`, `NamedTuple`) or
  a nonempty URL string.
- `locations::AbstractVector`: feature ids matched against `featureidkey`.
- `z::AbstractVector`: one value per location (same length as `locations`).

# Keywords
- `featureidkey::AbstractString = ""`: feature property matched by
  `locations` (`""` = plotly.js default `"id"`), e.g. `"properties.name"`.
- `colorscale = ""`: colormap name, colour vector, stops or `ColorScheme`, as
  for [`plot_choropleth`](@ref); `""` keeps the default.
- `marker_line_color::Union{Nothing,AbstractString,Symbol,AbstractVector} = nothing`:
  boundary colour, scalar or one per location.
- `marker_line_width::Union{Nothing,Real,AbstractVector} = nothing`: boundary
  width in pixels (≥ 0), scalar or one per location.
- `marker_opacity::Union{Nothing,Real,AbstractVector} = nothing`: fill opacity
  in [0, 1], scalar or one per location.
- `legend::AbstractString = ""`: legend name of the trace (mathtext); a
  name also shows the trace in the legend (plotly.js hides choropleth
  traces from the legend by default).
- `style`, `zoom`, `center_lon`, `center_lat`: map view, as for
  [`plot_scattermap`](@ref).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_scattermap`](@ref).
- `trace = nothing`: raw plotly.js `choroplethmap` trace attributes, the only
  raw pass-through, as for [`plot_scattermap`](@ref); it may not set
  `geojson`, `locations`, `z`, `featureidkey`, `marker_line_color`,
  `marker_line_width`, `marker_opacity`, `name` or any `colorscale` (use the
  keywords).

Any other keyword argument throws `ArgumentError`. So do an invalid
`geojson`, empty or mismatched `locations`/`z` (including per-location marker
vectors), out-of-range marker values, an unknown colour-scale name, and
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
	colorscale = "",
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
	trace = nothing,
	show::Bool = false,
	kwargs...,
)
	who = "plot_choroplethmap"
	_map_reject_keywords(who, kwargs; mutator = false)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _map_layout(style, zoom, center_lon, center_lat; who = who)
	built = _choroplethmap_trace(
		geojson,
		locations,
		z;
		who = who,
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
	plot_choroplethmap!(fig, geojson, locations, z; featureidkey="",
		colorscale="", marker_line_color=nothing, marker_line_width=nothing,
		marker_opacity=nothing, legend="", style=nothing, zoom=nothing,
		center_lon=nothing, center_lat=nothing, title="", width=0, height=0,
		fontsize=0, trace=nothing)
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
square = Dict("type" => "FeatureCollection", "features" => [Dict(
	"type" => "Feature", "id" => "A", "properties" => Dict(),
	"geometry" => Dict("type" => "Polygon",
		"coordinates" => [[[0, 0], [0, 5], [5, 5], [5, 0], [0, 0]]]))])
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
	who = "plot_choroplethmap!"
	_map_reject_keywords(who, kwargs; mutator = true)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_map_view(zoom, center_lon, center_lat; who = who)
	_require_valid_map_style(style; who = who)
	built = _choroplethmap_trace(
		geojson,
		locations,
		z;
		who = who,
		featureidkey = featureidkey,
		colorscale = colorscale,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		marker_opacity = marker_opacity,
		legend = legend,
		trace = trace,
	)
	push!(_plot_data(fig), built)
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
		legend="", style="open-street-map", zoom=0, center_lon=nothing,
		center_lat=nothing, title="", width=0, height=0, fontsize=0,
		trace=nothing, show=false)

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
- `colorscale = ""`: colormap name, colour vector, stops or `ColorScheme`, as
  for [`plot_choropleth`](@ref).
- `legend::AbstractString = ""`: legend name of the trace (mathtext); a
  name also shows the trace in the legend (off by default in plotly.js).
- `style`, `zoom`, `center_lon`, `center_lat`: map view, as for
  [`plot_scattermap`](@ref).
- `title`, `width`, `height`, `fontsize`, `show`: as for [`plot_scattermap`](@ref).
- `trace = nothing`: raw plotly.js `densitymap` trace attributes, the only raw
  pass-through, as for [`plot_scattermap`](@ref); it may not set `lon`,
  `lat`, `z`, `radius`, `name` or any `colorscale` (use the arguments).

Any other keyword argument throws `ArgumentError`. So do empty or mismatched
coordinates (including a per-point `radius`), radii below 1, an unknown
colour-scale name and invalid map-view or size values.

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
	colorscale = "",
	legend::AbstractString = "",
	style = "open-street-map",
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
	who = "plot_densitymap"
	_map_reject_keywords(who, kwargs; mutator = false)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	layout = _map_layout(style, zoom, center_lon, center_lat; who = who)
	built = _densitymap_trace(
		lon,
		lat,
		z;
		who = who,
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
	plot_densitymap!(fig, lon, lat, z=nothing; radius=nothing, colorscale="",
		legend="", style=nothing, zoom=nothing, center_lon=nothing,
		center_lat=nothing, title="", width=0, height=0, fontsize=0,
		trace=nothing)
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
	who = "plot_densitymap!"
	_map_reject_keywords(who, kwargs; mutator = true)
	options = _geo_figure_options(
		who;
		title = title,
		width = width,
		height = height,
		fontsize = fontsize,
	)
	_require_valid_map_view(zoom, center_lon, center_lat; who = who)
	_require_valid_map_style(style; who = who)
	built = _densitymap_trace(
		lon,
		lat,
		z;
		who = who,
		radius = radius,
		colorscale = colorscale,
		legend = legend,
		trace = trace,
	)
	push!(_plot_data(fig), built)
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
