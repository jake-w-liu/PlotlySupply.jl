# Other charts and maps

These constructors take `title`, `width`, `height`, `fontsize` and `show`
like the others, and each has a `!` form. Labels with `$...$` math in slice,
node and dimension names are converted to Unicode, because plotly draws those
labels as plain text.

## Proportions and hierarchies

```julia
using PlotlySupply

fig = plot_pie([45, 30, 25]; labels = ["Solar", "Wind", "Hydro"], hole = 0.4,
    title = "Energy mix")
fig2 = plot_sunburst(["Physics", "Chemistry", "Optics", "Other", "Other"],
    ["", "", "P", "P", "C"]; ids = ["P", "C", "P/optics", "P/other", "C/other"],
    values = [0, 0, 4, 2, 3], colorscale = "viridis")
fig3 = plot_treemap(["2023", "2024", "Q1", "Q2", "Q1", "Q2"],
    ["", "", "2023", "2023", "2024", "2024"];
    ids = ["2023", "2024", "2023/Q1", "2023/Q2", "2024/Q1", "2024/Q2"],
    values = [0, 0, 1, 2, 3, 4])
```

Repeated labels need `ids` (plotly would merge them and drop a branch), so
[`plot_sunburst`](@ref) and [`plot_treemap`](@ref) raise an `ArgumentError`
without them.

## Flows and stages

```julia
fig = plot_sankey([0, 0, 1, 2], [1, 2, 3, 3], [8, 4, 6, 3];
    label = ["Source", "A", "B", "Sink"], link_color = "rgba(0,0,96,0.2)")
fig2 = plot_funnel([1200, 640, 210, 48], ["Visits", "Sign-ups", "Trials", "Sales"];
    xlabel = "Users")
fig3 = plot_funnelarea([120, 60, 25, 8]; labels = ["Visits", "Sign-ups", "Trials", "Sales"])
fig4 = plot_waterfall(["Revenue", "Costs", "Tax", "Profit"], [120, -70, -15, 0];
    measure = ["absolute", "relative", "relative", "total"], ylabel = "k€")
```

## Indicators, parallel coordinates and ternary plots

```julia
fig = plot_indicator(72; reference = 65, gauge_range = (0, 100), number_suffix = "%",
    title = "Availability")
fig2 = plot_parcoords(["mass (kg)" => [1.2, 3.4, 2.2], "speed" => [10, 4, 7]];
    line_color = [1.2, 3.4, 2.2], colorscale = "viridis")
fig3 = plot_ternary([0.6, 0.2, 0.1], [0.3, 0.5, 0.2], [0.1, 0.3, 0.7];
    alabel = "Sand", blabel = "Silt", clabel = "Clay", marker_size = 10)
```

`plot_indicator` shows the number only by default; a `reference` adds the
delta and `gauge_range` the gauge.

## Financial charts

```julia
o = [10, 11, 10.5, 12]
h = [11.5, 12, 11, 13]
l = [9.5, 10.2, 9.8, 11.4]
c = [11, 10.4, 10.9, 12.8]
fig = plot_candlestick(1:4, o, h, l, c; ylabel = "price")
fig2 = plot_ohlc(1:4, o, h, l, c; xrange = (0, 5))
```

## Maps

Geographic maps ([`plot_scattergeo`](@ref), [`plot_choropleth`](@ref)) draw
on plotly's built-in outlines. Tile maps ([`plot_scattermap`](@ref),
[`plot_choroplethmap`](@ref), [`plot_densitymap`](@ref)) use MapLibre with the
token-free `"open-street-map"` style by default; the `*mapbox` variants are
the older Mapbox-based versions. Tiles are downloaded when the map is drawn.

```julia
fig = plot_scattergeo([2.35, 13.40], [48.86, 52.52]; color = "red", marker_size = 10,
    legend = "cities", scope = "europe")
fig2 = plot_choropleth(["France", "Germany", "Spain"], [1.0, 2.0, 3.0];
    locationmode = "country names", scope = "europe", colorscale = "Blues")
fig3 = plot_scattermap([2.35, 13.40], [48.86, 52.52]; zoom = 3, center_lon = 8,
    center_lat = 50, legend = "cities")
update_maps!(fig3; style = "carto-positron", zoom = 4)
```

The map constructors accept further plotly.js trace attributes as keywords
(nested ones with underscores, such as `marker_opacity`); a name that is not
an attribute of the trace type raises an `ArgumentError`. Colour scales
follow the package's colormap names (matplotlib orientation).

In a subplot grid, map cells are created with `specs`, the map mutators take
`row`/`col`, and [`update_maps!`](@ref) changes one cell (call it on `sf.fig`
to change every map cell):

```julia
sf = subplots(1, 2; sync = false, specs = [Spec(kind = "map") Spec(kind = "map")])
plot_scattermap!(sf, [2.35], [48.86]; row = 1, col = 1, legend = "Paris")
plot_scattermap!(sf, [13.40], [52.52]; row = 1, col = 2, legend = "Berlin")
update_maps!(sf; row = 1, col = 1, zoom = 4, center_lon = 2.35, center_lat = 48.86)
update_maps!(sf.fig; style = "carto-positron")
```

The trace constructors [`scattermap`](@ref), [`choroplethmap`](@ref) and
[`densitymap`](@ref) build MapLibre traces for the PlotlyJS-style
`plot(traces, layout)` API.
