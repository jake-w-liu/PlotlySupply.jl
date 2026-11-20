# Changelog

## 2.0.0 (unreleased)

2.0 turns PlotlySupply into a toolkit for scientific and publication figures:
journal presets with exact column widths, fonts in points and embedded fonts,
TIFF/PDF/EPS export at exact sizes, tight field plots, layouts in which
colorbars, legends and titles never overlap their neighbours, and a much
faster first figure. Every name exported by 1.9.3 is still exported. The
behaviour changes below are listed with before/after code in the documentation
page "Migrating from 1.x".

It includes the fixes of 1.9.4 (listed at the end).

### Breaking changes

Colours

- Named colour scales follow matplotlib's orientation, in every function that
  takes a `colorscale`, including 3-D, hierarchy and map plots. **`"Greys"`,
  `"Blues"`, `"Greens"`, `"YlGnBu"`, `"YlOrRd"` and `"RdBu"` run the other way
  round than in 1.x** (plotly.js's `"Greys"` was black to white, now it is
  white to black; `"RdBu"` ran blue to red, now red to blue). Use the name with
  `_r` (`"Greys_r"`, `"RdBu_r"`) for the 1.x direction. Traces store the
  resolved colour stops instead of the name. Unknown names raise an
  `ArgumentError` (1.x fell back to `"RdBu"`).
- `:publication` and `colorway = :okabe_ito` use the Okabe-Ito cycle in a
  line-safe order starting with `#0072B2` (1.x started with `#E69F00`).

Axes and ranges

- Ranges on logarithmic axes are data values in `xrange!`, `yrange!` and the
  `xrange`/`yrange` keywords of constructors and mutators (1.x: exponents).
- `[0, 0]`, `(0, 0)` and `nothing` restore automatic ranging.
- Explicit ranges are written with `autorange = false`.
- Equal bounds, `Bool` bounds and strings on numeric axes raise an
  `ArgumentError`. One-sided limits `(lo, nothing)` and `(nothing, hi)` are
  accepted (see "Added").
- The automatic sentinels keep a reversed axis reversed.
- On shared subplot axes, a range applies to the whole shared group.
- Mutators change only the primary axes.
- `grid = nothing` (the mutator default) keeps the grid.
- `tick0` is no longer written.
- Logarithmic axes label ticks as powers of ten.
- Under `:publication` and the journal presets a logarithmic axis that spans
  two decades or more labels decades only without any tick call
  (`PlotStyle.log_ticks = :decades`; a figure remembers the rule of the style
  it was built under). `PlotStyle(...)` constructors given positional arguments
  take `log_ticks` as a trailing argument (default `:auto`).
- A full range with bounds that are neither numbers nor dates on an
  automatically typed axis (`yrange = ("a", "b")`) raises an `ArgumentError`.
- Axis titles that would run off the figure are wrapped between words by the
  layout engine only; each break it writes is a zero-width space (U+200B)
  before a bare `<br>` (plotly.js counts the extra lines of a title with a
  greedy `<br...>` pattern, which makes a run of `<br />` one tag; your own
  `<br>` stay as you wrote them) (`xlabel!(...; wrap = false)` keeps
  one line); `secondary_xaxis!` no longer writes `title.pad.b` onto a placed
  figure title, the top margin is raised when the figure is finalized.
- Changing an axis scale converts an explicit range.
- `grid!(which = :major | :minor)` changes only that grid (1.x: each call
  defined the whole grid).
- `xticks!`/`yticks!(direction = :both | :inout)` raise an `ArgumentError`.
- `zrange!`/`axis_equal!` on a 3-D scene pin `aspectmode = "manual"` with the
  drawn proportions.
- Inset tick labels default to one size step smaller, and inset frames follow
  the template colours.

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
- The default legend of line plots moves to the first free corner or edge
  (the matplotlib "best" placement; never the centre automatically) and goes
  outside the plot (right, or below a narrow plot) when none is free.
- Legend boxes follow the template.
- Cell legends of a `SubplotFigure` at the default `:topright` move to the
  first free position when traces are appended, below the cell when none is
  free and its entries fit in one row (`set_legend!(sf; position = :topright)`
  restores the 1.x corner); a legend placed by you stays.
- `set_legend!(ncols = k)` lays columns out as legend groups; a click toggles
  one entry.
- `legend_entry!` validates colours and writes hex CSS.

Subplots

- `subplots(...; sync = false)` writes no figure title. The window title is
  the `window_title` keyword.
- `subplots` writes no figure size by default (`width = 0`, `height = 0`:
  automatic); 1.x wrote 960 x 720 px into the layout. Pass `width`/`height`
  for that size.
- `update_xaxes!` and the other `update_*!` functions with `row`/`col` change
  only that cell.
- Colorbars sit next to their cell.
- Only an explicit `barmode` applies to the whole figure.
- Cells give up room for colorbars, outside legends, panel titles and labels
  (their plot area shrinks, never a neighbour's); bottom colorbars sit below
  the tick labels; a vertical colorbar is at least three tick-label lines
  tall. Domains you set are kept.
- On shared axes a call on any cell acts on the whole group (type, ticks,
  tick font, range); a title set on a hidden-label cell goes to the labelled
  one; styling-only calls never move a title.
- Grid titles (`subplot_titles`, `column_titles`, `row_titles`, `x_title`,
  `y_title`) go through mathtext, are named annotations and follow the style's
  title size.
- Whole-figure verbs (`relayout!`, `restyle!`, `update!`, ...) reject cell
  keywords; `add_hline!` and the other `add_*` helpers reject `show`,
  `secondary_y`, `inset`, `xref`, `yref` on a `Plot` and take `row`/`col` on a
  `SubplotFigure`.
- Arguments are validated.
- `to_image` on a `sync = false` grid raises an `ArgumentError`.
- `panel_labels!(sf; row, col)` and `subplot_legends!(sf; row, col)` raise an
  `ArgumentError` (they were a `MethodError`); the `update_*!` functions on a
  `Plot` or `SyncPlot` raise an `ArgumentError` for `row`, `col`, `secondary_y`,
  `inset` and `show` (they wrote them into the layout).
- A plot area may give up two thirds of its cell for decorations (was one
  half), so crowded grids shrink more instead of overlapping; titles and
  legends are placed after the room is solved, so an outside-right legend of a
  single plot sits at `x` about 1.007, not 1.02. A figure title that already
  carries `pad.t` keeps it.

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
- `plot_bar` with one series: `color`, `hatch` and `barwidth` vectors with one
  entry per bar set each bar (1.x used the first entry only).
- `plot_image(interpolation = :bilinear)` writes a PNG source; contours with
  non-uniform levels are one trace per level.
- `plot_quiver`/`plot_streamlines` overlays do not widen a field's tight axes;
  `plot_quiver` `color` defaults to `nothing`.
- `view!(fig)` and `scene!(fig)` return `nothing` on a `Plot` or `SyncPlot`.
- 3-D colours with an alpha channel are drawn opaque, blended over the
  background; `plot_scatter3d(marker_color = ...)` adds a 1.5 px outline.
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
  trace, reject empty data, and pass titles and legend names through
  `mathtext`. Raw plotly.js attributes go in `trace = attr(...)`; bare
  keywords such as `hovertemplate` raise an `ArgumentError`.
- `legend` of `plot_choropleth` and the density maps is the trace's legend
  name (with `showlegend = true`).
- `annotate!(coords = :figure)` now means fractions of the whole figure in
  `[0, 1]`; plotly's paper coordinates are `coords = :paper`.

Export, windows and templates

- `savefig` uses the figure's `layout.width`/`layout.height` when no size is
  given (1.x: always 700 x 500 px).
- Exports are deterministic by default.
- A figure without a size exports at the size of the style it carries (a figure
  without a recorded style: the active style's size), else 700 x 500 px.
- PDF with `fonts = :auto`: text of a page with Type 3 fonts is outlined by
  Ghostscript (TrueType figures are unchanged). EPS text is outlined and its
  bounding box is the page; translucent EPS colours are blended.
- Raster sizes are rounded, not truncated; PNG/JPEG with physical units record
  `96 * scale` dpi; SVG with physical units carries them (`88mm`).
- `.tif`/`.tiff` are a format; an unwritable destination raises an
  `ArgumentError` before rendering.
- HTML export embeds plotly.js (about 4.5 MB per file).
- `figsize!` stores exact, unrounded sizes; its errors are `ArgumentError`.
- The `:publication` font family is "Times New Roman, Times, Liberation Serif,
  serif" (PDF embeds TrueType).
- `redraw!` rebuilds the page from the Julia figure.
- At exit, Julia waits for the Electron processes it started.
- Dark templates use light axis lines and ticks.
- `savefig` with an unsupported format, or with an invalid
  `PLOTLYSUPPLY_MATHJAX_SVG_FONT`, raises an `ArgumentError` (1.x:
  `ErrorException`). HTML export keeps the figure's `div` id, so the bytes are
  deterministic.
- Static exports (PDF, SVG, EPS, PNG, JPEG, TIFF) draw every vertex of a line
  (`line.simplify = false`); windows and HTML keep plotly.js' simplification,
  and `simplify = true`/`false` on a scatter constructor sets it for a trace.
- Under a style with a line width, box and violin traces get that line width
  where unset (plotly's default was 2 px); polar and ternary figures keep a
  margin of at least one tick-label height; the constructor colour of
  `plot_band` follows the style's colour cycle (was `#636EFA`); equal-aspect
  single figures keep a width you set exactly (journal columns are no longer
  rounded to whole pixels).
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
  `plot_pcolormesh` keeps matplotlib's automatic aspect (`equalar = false`);
  pass `equalar = true` for a mesh that draws physical space.
- 3-D: `view`, `edges`, `lighting`, `style = :arrow` for `plot_quiver3d`;
  `plot_scatter3d` `marker_line_color`, `marker_line_width`, `markevery`,
  hollow markers and the matplotlib marker codes.
- `plot_quiver`: `style = :triangle`, `pivot`, `scale = :uniform`, `headwidth`,
  `colorby` (with the colour and colorbar keywords), `edgecolor`, `edgewidth`,
  `opacity`.
- Bars: `barwidth`, per-bar `color`/`hatch` vectors, `bargap`/`bargroupgap`
  on subplots; `secondary_y` on `plot_bar!`, `plot_histogram!`, `plot_box!`,
  `plot_violin!`, `plot_histogram2d!`.
- Maps: `trace = attr(...)`; `colorscale` on scatter maps; `legend` on
  choropleth and density maps.
- Polar plots: `rlabel_angle`.
- `plot_scatterpolar(rrange = (nothing, b))` and `(a, nothing)` are one-sided
  radial limits; `trange` stays two-sided.

Axes and ticks

- One-sided limits: `xrange`, `yrange` and `zrange` (keywords and `xrange!`,
  `yrange!`, `zrange!`) take `(lo, nothing)` and `(nothing, hi)`.
- `spines!` keywords `bottom`, `top`, `left`, `right` (also over a data
  interval) and `ticks = :mirror | :primary | :none`; `xticks!(offset = ...)`
  and `direction = :none`; `inset!(coords = :data, fontsize = ...)`.
- Tick keywords (`xticks`, `yticks`, `xticklabels`, ...) on `plot_matrix`,
  `plot_pcolormesh`, `plot_polygons`, `plot_tripcolor`, `plot_triplot`,
  `plot_tricontour`, `plot_funnel`, `plot_waterfall`, `plot_candlestick`,
  `plot_ohlc`.
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
- `inset = k` in the mutators, including `plot_funnel!`, `plot_waterfall!`,
  `plot_candlestick!` and `plot_ohlc!` on a `SubplotFigure`.

Annotations and shapes

- `hline!`, `vline!`, `hspan!`, `vspan!`.
- `slope_guide!`, `slope_triangle!`.
- `circle!`, `ellipse!`, `rectangle!`, `polygon!`, `arc!`, `arrow!`.
- `legend_entry!`.
- `annotate!` with `coords` (`:data`, `:axes`, `:paper`, `:figure`), `offset`,
  `anchor`, `background`, `fit`/`wrap` and `xytext`.

Text and colours

- `mathtext`, `set_default_mathtext!`, `get_default_mathtext`, `set_fonts!`.
- `COLORMAPS`, `colormap`, `colormap_colors`, `discrete_colormap`,
  `lighten`.

Styles and export

- `PlotStyle`, `set_default_style!`, `get_default_style`, `with_style`,
  `register_style!`, with the built-in styles `:default` and `:publication`.
- Journal presets `:ieee`, `:aps`, `:nature`, `:elsevier`, `:springer`, `:aip`
  (fonts in points, 1 pt lines, journal ticks, Okabe-Ito colours, greyscale-safe
  `:dash_symbol` cycle, single-column width), `journal_width`, and
  `figsize!(fig, :ieee; columns = 2, aspect = 0.4)` (a taller figure than the
  journal's maximum is an error). Optica is not included: its widths could not
  be confirmed.
- `PlotStyle` fields `width`, `aspect`, `axis_linewidth`, `tick_length`,
  `mirror_ticks`, `errorbar_width`, `reference_linewidth`; `COLOR_CYCLES`
  (`:okabe_ito`, `:tol_bright`, `:tol_vibrant`, `:tol_muted`,
  `:tol_high_contrast`); greyscale-safe and uniform colormaps are tabulated in
  the `COLORMAPS` docstring; grey levels such as `"0.35"` are accepted as
  colours.
- `figsize!`, `tight_layout!`.
- `savefig` options:
  - EPS output (through Ghostscript);
  - TIFF output (`.tif`/`.tiff`, LZW, resolution tags);
  - the `fonts` keyword (`:auto`, `:embed`, `:outline`) for PDF and EPS;
  - exact PDF/EPS page sizes in points;
  - physical `units`, `dpi`, `background`, `tight`, `deterministic` and
    `timeout`;
  - several files from one render.
- A precompile workload: the first figure of a session takes about a third
  of a second instead of 15 seconds (low machine load, `benchmark/RESULTS.md`);
  the one-time precompilation takes minutes longer and the package image grows
  by about 80 MB (5.9 MB to 87.6 MB). Opt out with the
  `precompile_workload` preference. A benchmark suite lives in `benchmark/`.

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

Layout

- Colorbars, outside legends, panel titles and panel labels no longer overlap
  neighbouring panels, and fields fit their axes without a white border.
- The axis title of a shared-axis grid keeps its text when fonts are
  restyled.

### Removed

- No exported names were removed.
- The internal helper `_safe_tick0` was removed, and `tick0` is no longer
  written to axes.
- 1.x behaviour that 2.0 replaces is listed under "Breaking changes".

## 1.9.4 (2026-11-18)

Patch release on the 1.x line, included in 2.0.0.

- Math legend entries are sized to their text and no longer clipped
  (plotly.js is patched at load time to give math text groups an explicit font
  family and size); SVG output keeps its quotes.
- Asset hashing is linear on Julia 1.12 (it was quadratic).
