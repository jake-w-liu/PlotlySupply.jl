# API reference

Every function and type that PlotlySupply defines and exports, grouped by
purpose. The PlotlyBase names that PlotlySupply re-exports (`scatter`,
`Layout`, `attr`, `relayout!`, ...) are listed in
[Re-exported API](compat.md).

```@meta
CurrentModule = PlotlySupply
```

```@docs
PlotlySupply
```

## Figures, windows and export

```@docs
SyncPlot
SubplotFigure
plot
plot!
to_syncplot
toggle_devtools
msgchannel
savefig
json
```

## Lines and markers

```@docs
plot_scatter
plot_scatter!
plot_band
plot_band!
plot_area
plot_area!
plot_stem
plot_stem!
plot_segments
plot_segments!
plot_vlines
plot_vlines!
plot_hlines
plot_hlines!
plot_complex
plot_complex!
plot_scatterpolar
plot_scatterpolar!
```

## Statistical plots

```@docs
plot_bar
plot_bar!
plot_histogram
plot_histogram!
plot_histogram2d
plot_histogram2d!
plot_box
plot_box!
plot_violin
plot_violin!
plot_ecdf
plot_ecdf!
plot_kde
plot_kde!
```

## 2-D fields

```@docs
plot_heatmap
plot_heatmap!
plot_contour
plot_contour!
plot_image
plot_image!
plot_matrix
plot_matrix!
plot_pcolormesh
plot_pcolormesh!
plot_polygons
plot_polygons!
plot_tripcolor
plot_tripcolor!
plot_triplot
plot_triplot!
plot_tricontour
plot_tricontour!
plot_quiver
plot_quiver!
plot_streamlines
plot_streamlines!
mgrid
```

## 3-D plots

```@docs
plot_surface
plot_surface!
plot_wireframe
plot_wireframe!
plot_scatter3d
plot_scatter3d!
plot_segments3d
plot_segments3d!
plot_mesh3d
plot_mesh3d!
plot_polygons3d
plot_polygons3d!
plot_quiver3d
plot_quiver3d!
plot_isosurface
plot_isosurface!
plot_volume
plot_volume!
plot_streamtube
plot_streamtube!
view!
scene!
zlabel!
zrange!
```

## Other charts

```@docs
plot_pie
plot_pie!
plot_sunburst
plot_sunburst!
plot_treemap
plot_treemap!
plot_funnel
plot_funnel!
plot_funnelarea
plot_funnelarea!
plot_waterfall
plot_waterfall!
plot_indicator
plot_indicator!
plot_sankey
plot_sankey!
plot_parcoords
plot_parcoords!
plot_ternary
plot_ternary!
plot_candlestick
plot_candlestick!
plot_ohlc
plot_ohlc!
```

## Maps

```@docs
plot_scattergeo
plot_scattergeo!
plot_choropleth
plot_choropleth!
plot_scattermap
plot_scattermap!
plot_choroplethmap
plot_choroplethmap!
plot_densitymap
plot_densitymap!
plot_scattermapbox
plot_scattermapbox!
plot_choroplethmapbox
plot_choroplethmapbox!
plot_densitymapbox
plot_densitymapbox!
update_maps!
scattermap
choroplethmap
densitymap
```

## Subplots

```@docs
subplots
make_subplots
subplot!
inset!
remove_inset!
secondary_xaxis!
subplot_legends!
shared_colorbar!
panel_labels!
title!
```

## Axes and ticks

```@docs
xlabel!
ylabel!
xrange!
yrange!
xticks!
yticks!
log_ticks
axis_equal!
axis_off!
grid!
spines!
```

## Legends

```@docs
set_legend!
legend_entry!
set_default_legend_position!
get_default_legend_position
```

## Text and math

```@docs
mathtext
set_default_mathtext!
get_default_mathtext
annotate!
set_fonts!
```

## Colours

```@docs
COLORMAPS
COLOR_CYCLES
colormap
colormap_colors
discrete_colormap
lighten
colorbar!
```

## Reference lines and shapes

```@docs
hline!
vline!
hspan!
vspan!
slope_guide!
slope_triangle!
circle!
ellipse!
rectangle!
polygon!
arc!
arrow!
```

## Styles, templates and figure size

```@docs
PlotStyle
set_default_style!
get_default_style
with_style
register_style!
set_template!
set_default_template!
get_default_template
figsize!
journal_width
tight_layout!
```
