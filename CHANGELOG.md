# Changelog

## 2.0.0 (unreleased)

2.0 turns PlotlySupply into a toolkit for scientific and publication figures.
Every name exported by 1.9.3 is still exported. The behaviour changes below
are listed with before/after code in the documentation page "Migrating from
1.x".

### Breaking changes

Colours

- Named colour scales follow matplotlib's orientation (`"RdBu"` runs from
  red to blue, `"Blues"` from light to dark), in every function that takes a
  `colorscale`, including 3-D, hierarchy and map plots. Traces store the
  resolved colour stops instead of the name. Unknown names raise an
  `ArgumentError`.

Axes and ranges

- Ranges on logarithmic axes are data values in `xrange!`, `yrange!` and the
  `xrange`/`yrange` keywords of constructors and mutators (1.x: exponents).
- `[0, 0]`, `(0, 0)` and `nothing` restore automatic ranging.
- Explicit ranges are written with `autorange = false`.
- Partial ranges, equal bounds, `Bool` bounds and strings on numeric axes
  raise an `ArgumentError`.
- On shared subplot axes, a range applies to the whole shared group.
- Mutators change only the primary axes.
- `grid = nothing` (the mutator default) keeps the grid.
- `tick0` is no longer written.
- Logarithmic axes label ticks as powers of ten.
- Changing an axis scale converts an explicit range.

Labels and titles

- Labels go through `mathtext`: text and `$...$` math mix in one label, and an
  odd number of unescaped `$` raises an `ArgumentError`
  (`set_default_mathtext!(false)` turns this off).
- Titles are stored as `title.text`, and empty titles are not written.
- `annotate!` takes data values on logarithmic axes, also in 3-D scenes.

Legends

- Traces without a name are hidden from the legend.
- Outside legend positions are anchored to the figure edge, and top and
  bottom legends are horizontal.
- `set_legend!(fig)` keeps the current placement.
- `set_legend!` merges duplicate entries (`dedupe = true`).
- `subplot_legends!` keywords lost their `legend_` prefix (old names are
  deprecated).
- The default legend of line plots moves to the corner with the least data
  (the matplotlib "best" placement).
- Legend boxes follow the template.

Subplots

- `subplots(...; sync = false)` writes no figure title. The window title is
  the `window_title` keyword.
- `update_xaxes!` and the other `update_*!` functions with `row`/`col` change
  only that cell.
- Colorbars sit next to their cell.
- Only an explicit `barmode` applies to the whole figure.
- Arguments are validated.
- `to_image` on a `sync = false` grid raises an `ArgumentError`.

Plot functions

- `plot_stem` draws two traces per series.
- `plot_area(...; stack = true)` stacks a single series.
- `plot_bar(y; orientation = "h")` puts positions on the y axis.
- The series of one `plot_histogram` call share bins and are overlaid.
  Histograms on log axes are counted in Julia and drawn as bars.
- Box and violin series are grouped only when their positions collide.
- Field functions require `U[ix, iy]`; a transposed matrix raises an
  `ArgumentError`.
- `Bool` matrices are drawn as 0/1, and complex data raises an
  `ArgumentError`.
- `plot_quiver` separates arrows with `null`, anchors equal aspect on the y
  axis and hides unnamed arrows from the legend. `plot_quiver!` and
  `plot_image!` apply equal aspect by default.
- `plot_quiver3d` cones use `sizemode = "scaled"`.
- `plot_surface(...; color = "gray")` draws one colour.
- 3-D scenes get an explicit camera at a fitted distance.
- Scenes with explicit ranges use `aspectmode = "manual"`.
- `plot_scatter3d` and nested `mode = ""` series draw lines.
- `plot_indicator` shows only the number unless `reference` or
  `gauge_range` is given.
- `plot_sunburst` and `plot_treemap` require `ids` when labels repeat.
- `plot_funnel` uses the package's axis style.
- New polar plots put radial labels at 22.5° with at most 6 ticks.

Validation and errors

- Mismatched lengths, matrices, complex data, empty data and invalid
  keyword values raise an `ArgumentError` whose message starts with the
  function name.
- Unknown keywords and `show` on mutators, 3-D, mesh and map functions raise
  an `ArgumentError` instead of a `MethodError`.
- Map functions reject keywords that are not plotly.js attributes of the
  trace.

Export, windows and templates

- `savefig` uses the figure's `layout.width`/`layout.height` when no size is
  given (1.x: always 700 x 500 px).
- Exports are deterministic by default.
- `redraw!` rebuilds the page from the Julia figure.
- At exit, Julia waits for the Electron processes it started.
- Dark templates use light axis lines and ticks.
- `set_template!` replaces colours derived from the previous template.
- `get_default_template` may return a `Template`.
- `PLOTLYSUPPLY_MATHJAX_SVG_FONT` accepts only the MathJax 2.7 SVG fonts.

### Added

Plot types

- `plot_band`, `plot_segments`, `plot_vlines`, `plot_hlines`,
  `plot_complex`.
- `plot_ecdf`, `plot_kde`.
- `plot_matrix`, `plot_pcolormesh`, `plot_polygons`, `plot_tripcolor`,
  `plot_triplot`, `plot_tricontour`, `plot_streamlines`.
- `plot_wireframe`, `plot_segments3d`, `plot_polygons3d`.
- The `!` form of each of these.

Plot keywords

- Line plots: `markevery`, `marker_line_width`, open markers with
  `marker_color = "none"`, `line_shape`.
- Bars: `hatch`, `text`, `textposition`. Histograms: `bins`.
- Fields: `levels`, `cmid`, `colornorm = :log`, `text`, `origin`, `tight`.
  Fields fit their axes exactly and keep the colorbar as tall as the field
  under `equalar = true`.
- 3-D: `view`, `edges`, `lighting`, `style = :arrow` for `plot_quiver3d`.
- Polar plots: `rlabel_angle`.

Axes and ticks

- `xticks!`, `yticks!` (values, labels, d3 formats, `subs`, minor ticks,
  `:decades`).
- `log_ticks`, `axis_equal!`, `axis_off!`, `grid!`, `spines!`.
- `zlabel!`, `zrange!`, `view!`, `scene!`.
- `secondary_xaxis!`.
- Date ranges in `xrange!`.

Subplots

- `inset!`, `remove_inset!`, `shared_colorbar!`, `colorbar!`,
  `panel_labels!`, `title!`.
- `height_ratios` and `width_ratios`.
- Per-cell `row`/`col`/`inset` in the axis helpers.

Annotations and shapes

- `hline!`, `vline!`, `hspan!`, `vspan!`.
- `slope_guide!`, `slope_triangle!`.
- `circle!`, `ellipse!`, `rectangle!`, `polygon!`, `arc!`, `arrow!`.
- `legend_entry!`.
- `annotate!` with `coords` and `offset`.

Text and colours

- `mathtext`, `set_default_mathtext!`, `get_default_mathtext`, `set_fonts!`.
- `COLORMAPS`, `colormap`, `colormap_colors`, `discrete_colormap`,
  `lighten`.

Styles and export

- `PlotStyle`, `set_default_style!`, `get_default_style`, `with_style`,
  `register_style!`, with the built-in styles `:default` and `:publication`.
- `figsize!`, `tight_layout!`.
- `savefig` options:
  - EPS output (through Ghostscript);
  - physical `units`, `dpi`, `background`, `tight`, `deterministic` and
    `timeout`;
  - several files from one render.

### Fixed

Export

- HTML and JSON export no longer fails on `NaN` or `Inf` data (including every
  `plot_quiver` figure); the values are written as `null`.
- Text in titles and labels can no longer break out of the script of an
  exported HTML page.
- Exports no longer depend on the figure exported before them (stale
  colorbars and layout in PDF and subplot exports).
- `savefig` keeps the permissions of an overwritten file.
- `savefig` accepts a `timeout` for large figures.

Subplots

- Equal-aspect plots in cells other than (1, 1) are no longer tied to the
  first cell's y axis.
- Colorbars of different cells no longer stack at the figure edge.
- `xrange!`/`yrange!` work on shared axes.
- `shared_xaxes = "all"` hides the tick labels of the right cells.
- `update_xaxes!(sf; row, col)` no longer changes every cell.
- `subplots(...; per_subplot_legends = false)` honours the legend position
  and shows a single named trace.
- `annotate!`, `set_template!` and `set_legend!(sf; showlegend)` work on
  `sync = false` grids.
- `plot_surface!(sf; shared_coloraxis = true)` also binds surfaces that are
  already there.

Legends

- Unnamed traces, including the stems of `plot_stem`, no longer leave blank
  legend entries.
- Outside bottom and left legends no longer cover tick labels and axis
  titles.

Plot functions

- Transposed or wrongly sized field matrices are reported instead of being
  drawn wrongly, and the documentation examples build `U[ix, iy]`.
- Series collected in an untyped vector (`ys = []; push!(ys, v)`) are drawn
  as separate series.
- Mismatched `x`/`y` lengths are reported instead of points being dropped.
- `plot_bar(y; orientation = "h")` draws bars of length `y`.
- Overlaid histograms are translucent and share bins.
- Histograms on log axes are no longer empty.
- Boxes and violins stay centred on their labels.
- `plot_stem` builds two traces instead of one per point.
- `plot_image` keeps the alpha channel of RGBA data and rejects arrays it
  cannot show.
- `Bool` matrices draw as 0/1 instead of an empty plot.
- `plot_quiver3d` cone size no longer depends on the field's units.
- Invalid 3-D input is reported instead of dropping cones.
- `plot_isosurface` and `plot_volume` accept 3-D arrays.
- `plot_surface` accepts `perspective`.
- `plot_indicator` honours `reference` and `gauge_shape`, and rejects
  `gauge_range = 0:100`.
- `plot_sunburst`/`plot_treemap` no longer merge repeated labels silently.
- `plot_choropleth` with `geojson` draws its regions.
- Mapbox plots and mapbox subplot cells get a token-free style.
- `plot_scattergeo` and the mapbox functions check that per-point colours and
  sizes match the data length.

Labels, templates and windows

- `LaTeXString` and `SubString` labels are accepted.
- Titles can be changed with `relayout!(fig; title_x = ...)` and the other
  `title_*` attributes.
- Axis lines and ticks are visible on dark templates.
- Unknown colour scale names are reported instead of falling back to RdBu.
- `plot(trace; layout = ...)` keeps the layout.
- `subplots(...; sync = false)` no longer writes "PlotlySupply" as the figure
  title.

### Removed

- No exported names were removed.
- The internal helper `_safe_tick0` was removed, and `tick0` is no longer
  written to axes.
- 1.x behaviour that 2.0 replaces is listed under "Breaking changes".
