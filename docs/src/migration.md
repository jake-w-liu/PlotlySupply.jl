# Migrating from 1.x

PlotlySupply 2.0 keeps every name that 1.9.3 exported; the changes are in
behaviour. Code blocks marked "1.x" show the old usage; the block after it is
the 2.0 form.

## Colour scale orientation (read this first)

Named colour scales follow matplotlib's orientation, and an unknown name is an
`ArgumentError` (1.x fell back to `"RdBu"`). In 1.x the names went to plotly.js,
which draws some scales the other way round. **A script or a package that
passes `colorscale = "Greys"`, `"Blues"`, `"Greens"`, `"YlGnBu"`, `"YlOrRd"` or
`"RdBu"` now gets the reversed picture**: high values that were dark are light.
The trace stores the resolved colour stops instead of the name.

| Name | 1.x (plotly.js), low to high | 2.0, low to high | 1.x direction in 2.0 |
|---|---|---|---|
| `"Greys"` | black to white | white to black | `"Greys_r"` |
| `"Blues"` | dark blue to light grey | white to dark blue | `"Blues_r"` |
| `"Greens"` | dark green to near white | near white to dark green | `"Greens_r"` |
| `"YlGnBu"` | dark blue to light yellow | light yellow to dark blue | `"YlGnBu_r"` |
| `"YlOrRd"` | dark red to light yellow | light yellow to dark red | `"YlOrRd_r"` |
| `"RdBu"` | blue to red | dark red to dark blue | `"RdBu_r"` |

`"Reds"`, `"Hot"`, `"Jet"`, `"Rainbow"`, `"Viridis"` and `"Cividis"` keep their
direction (the colours of the ColorBrewer scales are matplotlib's, so the end
colours differ slightly from plotly.js's: `"Blues_r"` ends at `#F7FBFF`, not
at plotly.js's grey). `"Bluered"`, `"Picnic"`, `"Portland"`, `"Electric"`,
`"Blackbody"` and `"Earth"` are still plotly.js's own. The rule applies to
every function with a `colorscale`: 2-D, 3-D, statistical, hierarchy and map
functions, `shared_colorbar!` and `colorbar!`.

```julia
# fragment: 1.x code
plot_heatmap(U; colorscale = "RdBu")    # blue at the low end in 1.x
plot_heatmap(U; colorscale = "Greys")   # black at the low end in 1.x
```

```julia
using PlotlySupply

U = randn(20, 10)
fig = plot_heatmap(U; colorscale = "RdBu_r")   # blue at the low end in 2.0
fig.data[1][:colorscale][1]                    # [0.0, "#053061"], not "RdBu"
fig2 = plot_heatmap(U; colorscale = "Greys_r") # black at the low end, as in 1.x
# exactly plotly.js's stops, if the 1.x colours matter:
fig3 = plot_heatmap(U; colorscale = [(0, "rgb(0,0,0)"), (1, "rgb(255,255,255)")])
```

To find the places to change in a code base, search for `colorscale` and for
`"Greys"`, `"Blues"`, `"Greens"`, `"YlGnBu"`, `"YlOrRd"`, `"RdBu"`. Packages
that build colour scales for PlotlySupply must pass the 2.0 names (or explicit
stops) too.

## Ranges and annotations on log axes

Ranges on logarithmic axes are data values everywhere (`xrange!`, `yrange!`,
`zrange!`, and the `xrange`/`yrange` keywords of constructors and mutators).
1.x passed exponents through. `annotate!` on log axes also takes data values.

```julia
# fragment: 1.x code
fig = plot_scatter(f, g; xscale = "log", xrange = [0, 3])   # 10^0 .. 10^3
annotate!(fig, 1, 2, "peak")                                # at x = 10, y = 100
```

```julia
f = [1.0, 10, 100, 1000]
g = [1.0, 50, 100, 20]
fig = plot_scatter(f, g; xscale = "log", yscale = "log", xrange = [1, 1000])
annotate!(fig, 10, 50, "peak")
```

A non-positive bound on a log axis raises an `ArgumentError`. Changing an
axis to log with an explicit range in place converts that range.

## Ranges in general

- `[0, 0]`, `(0, 0)` and `nothing` restore automatic ranging; 1.x wrote a
  literal `[0, 0]` range.
- A range is written with `autorange = false`, so it applies even where an
  `autorange` was set.
- Equal bounds, `Bool` bounds and strings on numeric axes raise an
  `ArgumentError`. Date axes still take date strings.
- One-sided limits are new: `(lo, nothing)` and `(nothing, hi)` fix one end and
  autorange the other.
  `(nothing, nothing)` is automatic. A fixed end beyond all the data is an
  `ArgumentError`.
- The automatic sentinels (`nothing`, `[0, 0]`) keep a reversed axis
  reversed.
- On shared axes (`subplots(...; shared_xaxes = true)`) the range is written
  to the axis that owns the shared range, so every cell of the group changes.
  1.x silently ignored such calls.
- Mutators write `xrange`, `yrange`, `xscale`, `yscale` and `grid` to the
  primary axes only; 1.x wrote them to every axis of the figure.

```julia
fig = plot_scatter(1:10, rand(10))
xrange!(fig, (2, 8))
xrange!(fig, nothing)            # automatic again
yrange!(fig, (0, nothing))       # one-sided: bottom fixed at 0, top autoranges
```

## Axis helpers

- `grid!(fig; which = :minor)` and `which = :major` change only that grid. In
  1.x each call defined the whole grid: `which = :minor` switched the major
  grid off.
- `xticks!`/`yticks!(direction = :both)` and `:inout` raise an `ArgumentError`
  (plotly.js has no crossing ticks); `direction = :none` is new.
- `inset!` tick labels default to one size step smaller (the host's tick size
  divided by 1.2), and the inset's frame and tick colours follow the template
  (no longer black on dark templates).
- `secondary_xaxis!` on a heatmap or image cell computes its ticks over the
  tight cell-edge range and keeps the field's sticky autorange instead of
  freezing a range at the cell centres.
- `spines!` has new keywords (`bottom`, `top`, `left`, `right`, `ticks`);
  `xticks!` has `offset`; `inset!` has `coords = :data` and `fontsize`.

```julia
fig = plot_scatter(1:10, (1:10) .^ 2)
grid!(fig; which = :minor, alpha = 0.05)    # the major grid keeps its state
```

## Labels go through mathtext

Titles, axis labels, legend names, tick labels and annotations are converted
by [`mathtext`](@ref), so text and `$...$` math mix in one label (1.x showed
the dollars literally unless the whole label was math). An odd number of
unescaped `$` is an `ArgumentError`.

```julia
# fragment: 1.x code
plot_scatter(x, y; title = "cost \$5")
```

```julia
fig = plot_scatter(1:3, [1, 4, 9]; title = "cost \\\$5", xlabel = "time \$t\$ (s)")
set_default_mathtext!(false)     # or: pass labels through unchanged, as in 1.x
fig2 = plot_scatter(1:3, [1, 4, 9]; title = "cost \$5")
set_default_mathtext!()
```

## Titles are stored nested

Figure, axis and colorbar titles are stored as `title.text`, so later font
changes merge with them.

```julia
# fragment: 1.x code
fig.layout[:title]               # "Run 3"
```

```julia
fig = plot_scatter(1:3, [1, 2, 3]; title = "Run 3")
fig.layout[:title_text]          # "Run 3"
```

An empty `title`, `xlabel` or `ylabel` is no longer written at all.

## Legends

- A trace without a name (`legend` not given, or blank) is hidden from the
  legend. Pass `legend` to list it.
- Outside positions are anchored to the figure: `:outside_bottom` sits at the
  bottom edge of the figure (`yref = "container"`), `:outside_left` at the
  left edge, and top/bottom legends are horizontal.
- `set_legend!(fig)` without a `position` keeps the current placement and
  colours; 1.x moved the legend back to the default position.
- `set_legend!` merges entries with the same name and style
  (`dedupe = true`); pass `dedupe = false` for the 1.x behaviour.
- [`subplot_legends!`](@ref) keywords lost their `legend_` prefix (`inset`,
  `bgcolor`, `bordercolor`, `borderwidth`); the old names still work with a
  deprecation warning.
- The default legend of line plots goes to the corner that covers the least
  data while the package default position is `:topright`; a legend you
  place is never moved.
- The default legend box follows the template (a dark box on dark
  templates).
- Cell legends of a `SubplotFigure` at the default `:topright` also move to
  the least-covered position when traces are appended to the cell, and `plot_band`
  and `fill = "toself"` traces count as data. A legend placed with
  `set_legend!`/`relayout!` stays put, and any other default position turns the
  rule off.
- `set_legend!(...; ncols = k)` lays columns out as legend groups sized by
  their labels (not `entrywidth` fractions); a click toggles one entry, and
  columns that do not fit are reduced with a warning. A cell legend above or
  below its axes may reach over the gap to the next cell.
- `legend_entry!` validates colours (`ArgumentError`) and writes hex CSS
  (`"red"` becomes `"#FF0000"`).

```julia
# fragment: 1.x code
subplot_legends!(sf; legend_bgcolor = "white", legend_inset = (0.02, 0.98))
```

```julia
sf = subplots(1, 2; sync = false)
plot_scatter!(sf, 1:3, [1, 2, 3]; legend = "a", row = 1, col = 1)
plot_scatter!(sf, 1:3, [3, 2, 1]; row = 1, col = 2)     # no entry
subplot_legends!(sf; bgcolor = "white")
set_legend!(sf; position = :outside_bottom, dedupe = false)
```

## Subplots

- `subplots(...; sync = false)` writes no figure title; 1.x wrote
  "PlotlySupply". The window title is the separate `window_title` keyword.
- `update_xaxes!`, `update_yaxes!`, `update_scenes!`, `update_polars!`,
  `update_ternaries!`, `update_annotations!`, `update_shapes!` and
  `update_images!` with `row`/`col` change only that cell; 1.x changed every
  cell and stored `row`/`col` as attributes.
- Colorbars of traces drawn into cells sit next to their cell.
- Only an explicit `barmode` is copied to the whole figure.
- Arguments are validated (`ArgumentError` for spacing outside `[0, 1]`,
  malformed `subplot_titles`, ...).
- `to_image` on a `sync = false` grid raises an `ArgumentError` that points
  to `savefig`; 1.x returned `nothing`.
- Traces on inset axes share the host cell's legend.
- Cells with colorbars, outside legends, panel titles or labels give up room:
  the cell's plot area shrinks where the gap to its neighbour is too small
  (user-set domains are kept), so default grid domains differ from the plain
  grid when decorations are present. Bottom colorbars sit below the x tick
  labels and title (`yref = "paper"`, the margin grows) instead of at
  `domain - 0.12`; a vertical bar is never shorter than three tick-label
  lines plus its title.
- On shared axes (`shared_xaxes`/`shared_yaxes`) a call on any cell acts on the
  whole group: type, tick placement and format, tick font and angle are
  copied to every member, a range is written on the root, and an axis title
  set on a hidden-label cell goes to the label-showing cell. Styling-only calls
  (`set_fonts!`) never move a title. An inset sharing an axis keeps its own
  tick font. In 1.x each cell was changed alone.
- Grid titles (`subplot_titles`, `column_titles`, `row_titles`, `x_title`,
  `y_title`) are typeset by mathtext (`$...$` converts, an unbalanced `$` is an
  `ArgumentError`), are named annotations that `title!(sf, text; row, col)`
  replaces, and take the active style's title size (10.67 px under `:ieee`
  instead of 16). `column_titles`/`row_titles` need one string per column/row.
- Whole-figure verbs on a `SubplotFigure` (`relayout!`, `restyle!`, `update!`,
  `react!`, `redraw!`, `deletetraces!`, `movetraces!`, `extendtraces!`,
  `prependtraces!`, `purge!`) reject the cell keywords `row`, `col`,
  `secondary_y`, `inset` and `show` with an `ArgumentError`; on a `Plot`,
  `add_hline!`/`add_vline!`/`add_hrect!`/`add_vrect!`/`add_shape!`/
  `add_layout_image!` reject `show`, `secondary_y`, `inset`, `xref`, `yref`,
  and an out-of-grid cell. On a `SubplotFigure` they take `row`/`col`.
- Appends to a `SubplotFigure` with per-subplot legends reach a live window as
  `addTraces` plus `relayout` when no existing trace is rewritten (1.x
  re-rendered the page); next to an existing colorbar or an equal-aspect cell
  the figure is rebuilt.
- `plot_bar!`/histogram calls with `bargap`/`bargroupgap` on a `SubplotFigure`
  are one transaction. `figsize!`, `tight_layout!`, `colorbar!` and
  `shared_colorbar!` with `show` or a cell keyword that does not apply raise an
  `ArgumentError`, not a `MethodError`.

```julia
# fragment: 1.x code
update_xaxes!(sf; row = 1, col = 2, title_text = "x")    # changed every cell
```

```julia
sf = subplots(1, 2; sync = false, title = "Results", window_title = "run 3")
plot_scatter!(sf, 1:3, [1, 2, 3]; row = 1, col = 1)
plot_scatter!(sf, 1:3, [3, 2, 1]; row = 1, col = 2)
update_xaxes!(sf; row = 1, col = 2, title_text = "x (right cell only)")
```

## Lines and statistics

- [`plot_stem`](@ref) draws two traces per series (markers, then stems),
  not one trace per point.
- `tick0` is no longer written on axes.
- Mismatched `x`/`y` lengths, matrices and complex data raise an
  `ArgumentError` (complex data points to [`plot_complex`](@ref)); stats
  functions given a matrix suggest `eachcol`.
- `mode = ""` means `"lines"` for every series.
- `plot_area(...; stack = true)` stacks a single series too.
- `plot_bar(y; orientation = "h")` puts the positions `0:n-1` on the y axis.
- The series of one `plot_histogram` call share their bins and are overlaid
  at opacity 0.6. On a log binning axis histograms are counted in Julia and
  drawn as `bar` traces (plotly.js drew nothing there).
- Box and violin series of one call are grouped only when their positions
  collide.
- Error-bar magnitudes must be non-negative.
- The style's line width now also applies to segments, vertical and
  horizontal lines, ECDF and KDE curves.
- `plot_bar` with a single series: a `color`, `hatch` or `barwidth` vector with
  one entry per bar now sets each bar. In 1.x a colour vector was read per
  series and only its first entry was used; a vector of any other length is
  an `ArgumentError`. `hatch` also accepts nested per-bar vectors.
- On a `SubplotFigure` the `barmode` warning appears only when another axis pair
  holds two or more bar-like traces.
- With `markevery` and `text`, the new traces carry their own `textfont.color`,
  pinned to the text colour at the call, so a later template change does not
  recolour the labels.
- `plot_bar!`, `plot_histogram!`, `plot_box!`, `plot_violin!` and
  `plot_histogram2d!` accept `secondary_y = true` on a `Plot`/`SyncPlot`
  (they raised an `ArgumentError`).
- Messages for tick presets and range keywords use the shared wording
  (`` `xrange` bounds on a linear axis must be numbers``). The internal helpers
  `_scat_validate_ticks`, `_scat_require_axis_range`, `_scat_apply_axis_options!`
  and `_stats_reject_keywords` are gone.

```julia
# fragment: 1.x code
length(plot_stem(1:5, rand(5)).data)     # 5
```

```julia
fig = plot_stem(1:5, rand(5))
length(fig.data)                          # 2
fig2 = plot_bar([4.0, 2.0, 7.0]; orientation = "h")
fig3 = plot_scatter(1:3, real.([1im, 2, 3]))
```

## Fields

- Matrices are checked against `U[ix, iy]`: `size(U) == (length(x), length(y))`
  (or cell edges). A transposed matrix raises an `ArgumentError` that
  suggests `permutedims(U)`; 1.x drew it silently.
- `Bool` matrices are drawn as 0/1; complex matrices raise an
  `ArgumentError`.
- `plot_quiver` separates arrows with `nothing` (JSON `null`) instead of
  `NaN`, sets equal aspect through `yaxis.scaleanchor`, hides an unnamed
  quiver from the legend, and `plot_quiver!` applies equal aspect by default.
- `plot_image` rejects arrays that are not `H x W x 3`/`H x W x 4` or colour
  matrices; `plot_image!` applies equal aspect by default.
- Field mutators change only the primary axes.
- Field traces carry `meta = "plotlysupply:field"`.
- `linewidth = 0` in `plot_streamlines`, `plot_triplot` and
  `plot_tricontour` means the style's width.
- `plot_pcolormesh` and `plot_pcolormesh!` default to `equalar = false`
  (matplotlib's auto aspect). Pass `equalar = true` for a physical-space mesh.
- `plot_image(...; interpolation = :bilinear)` writes a PNG `source` with
  smoothing instead of `z`/`colormodel`; hover shows the RGBA pixel and
  non-finite pixels are transparent.
- Contours with non-uniform line `levels` are one trace per level
  (`coloring = "none"`, explicit line colour, no legend entry) plus a colorbar
  carrier trace.
- The keywords `style`, `pivot`, `scale`, `headwidth` of `plot_quiver` and
  `interpolation` of heatmaps and images raise an `ArgumentError`, not a
  `MethodError`, for a wrong value; the `plot_quiver` `color` default is
  `nothing`.
- `plot_quiver` and `plot_streamlines` overlays no longer widen the tight axes
  of a field under them: their anchor points count, not the arrows' length;
  parts of arrows beyond the frame are clipped. Fields fit their axes exactly
  also with overlays; where overlays reach past the field the range is padded
  by 2.5 % of the span.
- Field axes: `plot_matrix` and the mesh functions take the tick keywords
  (`xticks`, `yticks`, `xticklabels`, ...).
- `plot_quiver(...; style = :triangle)`, `pivot`, `scale` and `colorby` are new:
  see [2-D fields](fields.md).

```julia
# fragment: 1.x code
Z = f.(xs', ys)        # size (length(ys), length(xs)): matplotlib layout
plot_heatmap(xs, ys, Z)  # 1.x drew it without an error
```

```julia
xs = range(0, 1; length = 30)
ys = range(0, 2; length = 20)
U = [x * y for x in xs, y in ys]         # U[ix, iy]
fig = plot_heatmap(xs, ys, U)
Z = permutedims(U)                       # data in matplotlib layout
fig2 = plot_heatmap(xs, ys, permutedims(Z))
```

## 3-D

- `plot_quiver3d` cones use `sizemode = "scaled"`: their size follows the
  point spacing, not the field's magnitude. Vectors with non-finite values
  are skipped with a warning.
- Inputs are validated before the figure changes (`ArgumentError` for bad
  ranges, opacity, sizes, colours, colormap names, shapes, complex data).
- `plot_surface(...; color = "gray")` draws one colour without a colorbar.
- Perspective scenes get an explicit camera at a distance that fits the box
  (`view!(...; distance = :auto)` computes it); 1.x left the camera unset.
- A scene with an explicit range uses `aspectmode = "manual"` with the span
  ratios.
- `annotate!(fig, x, y, z, text)` takes data values on log scene axes.
- `plot_scatter3d` series with `mode = ""` draw lines.
- `view!(fig)` and `scene!(fig)` on a `Plot` or `SyncPlot` return `nothing`
  (1.x returned `fig`); the `SubplotFigure` methods still return `sf`.
- 3-D line, edge, arrow and marker colours with an alpha channel (`rgba(...)`,
  `#RRGGBBAA`) are drawn opaque, blended over the scene background, as
  `opacity < 1` already was. Before they passed through unchanged.
- `plot_scatter3d`: a `marker_color` face colour also gets a 1.5 px outline in
  the series colour (matplotlib's `markerfacecolor`); `markevery` on a series
  with lines or text adds a second trace for it; new keywords
  `marker_line_color`, `marker_line_width`, `marker_color = "none"` and the
  matplotlib marker codes `o . s D d + P x X`.
- 3-D colour keyword errors read `` `<fn>: `<kw>`: invalid colour ...` `` and grey
  levels such as `"0.35"` are accepted.
- `zrange!`/`axis_equal!` on a scene with `aspectmode` `"data"` or `"auto"` pin
  `"manual"` with ratios from the drawn spans, so later `zrange!` calls keep
  the box proportions.
- Scene cells can get a higher automatic `nticks` than before (the smallest
  count that labels two ticks).

```julia
# fragment: 1.x code
plot_quiver3d(x, y, z, u, v, w; sizeref = 0.5)   # size depended on |(u, v, w)|
```

```julia
fig = plot_quiver3d([0.0, 1], [0.0, 0], [0.0, 0], [1e6, 0], [0.0, 1e6], [0.0, 0])
fig.data[1][:sizemode]                            # "scaled"
fig2 = plot_quiver3d([0.0, 1], [0.0, 0], [0.0, 0], [1.0, 0], [0.0, 1], [0.0, 0];
    sizemode = "absolute")
```

## Other charts and maps

- `plot_indicator` shows only the number by default; `reference` adds the
  delta and `gauge_range` the gauge.
- `plot_sunburst` and `plot_treemap` require `ids` when labels repeat.
- Pie, funnel, waterfall, candlestick, OHLC, Sankey and ternary inputs are
  validated (`ArgumentError` for empty data, mismatched lengths, negative
  values where plotly requires non-negative ones).
- `plot_funnel` uses the package's axis styling.
- Map functions (`plot_scattergeo`, `plot_choropleth`, `plot_scattermap(box)`,
  `plot_choroplethmap(box)`, `plot_densitymap(box)` and their `!` forms) raise an
  `ArgumentError` for any bare plotly keyword; raw plotly.js attributes now go
  in `trace = attr(...)`, which may not set `name`, `colorscale`, the
  positional data or anything a package keyword controls. They also raise for
  empty data and for `show`, `row` or `col` on a `Plot`. Map titles and legend
  names go through mathtext.
- `legend` on `plot_choropleth` and the density maps is the trace's legend
  name with `showlegend = true` (1.x set plotly's trace `legend` id);
  `plot_choroplethmap(box)` with `legend` also sets `showlegend = true`.
  Scatter maps take `colorscale` with a numeric `color`.
- `annotate!(...; coords = :figure)` now means fractions of the whole figure in
  `[0, 1]` and may raise the bottom margin for captions. The old meaning,
  plotly's paper coordinates, is `coords = :paper`. With `:figure`, `name`,
  `xshift` and `yshift` are rejected and values outside `[0, 1]` raise.
  `coords = :axes` with `showarrow = false` on 3-D, polar, map and domain cells
  writes `xanchor`/`yanchor` from the cell position.
- Errors of log-axis bar charts (`plot_funnel!`, `plot_waterfall!`,
  `plot_candlestick!`, `plot_ohlc!` on a `SubplotFigure`) read "the <axis> axis
  is logarithmic, but ... bars start at zero".

```julia
# fragment: 1.x code
plot_indicator(72)                 # number and a zero delta
annotate!(fig, 0.5, 0.5, "x"; coords = :figure)   # plotly paper coordinates
plot_scattergeo(lon, lat; hovertemplate = "%{lat}")
```

```julia
fig = plot_indicator(72; reference = 65)
fig.data[1][:mode]                 # "number+delta"
fig2 = plot_scatter(1:3, [1, 2, 3])
annotate!(fig2, 0.5, 0.5, "x"; coords = :paper, showarrow = false)    # the old :figure
annotate!(fig2, 0.5, 0.02, "Source"; coords = :figure, showarrow = false)  # whole figure
fig3 = plot_scattergeo([2.35], [48.86]; trace = attr(hovertemplate = "%{lat}"))
```

## Export and windows

- `savefig` without `width`/`height` uses the figure's `layout.width` and
  `layout.height`; 1.x always used 700 x 500 px.
- Exports are deterministic by default (`deterministic = true`).
- `redraw!` rebuilds the page from the Julia figure.
- At Julia exit, the Electron processes PlotlySupply started are closed and
  waited for (scripts take 1 to 4 s longer to exit).
- A figure without a size exports at the active style's default size (a
  journal preset sets one) instead of always 700 x 500 px.
- PDF with `fonts = :auto` (the default): when Chromium embedded Type 3 fonts
  (STIX, Latin Modern) and Ghostscript is on `PATH`, all text of the page is
  converted to outlines and can no longer be selected. TrueType figures
  (Times New Roman, Arial) are unchanged.
- EPS text is outlined unless `fonts = :embed`; the `%%BoundingBox` is the whole
  page; translucent colours are blended over their background instead of being
  flattened to opaque.
- Raster pixel counts are rounded, not truncated (6.35 cm at 300 dpi is 750 px,
  was 749). PNG and JPEG exported with physical units and no `dpi` record
  96 x `scale` dpi; pixel-unit exports record none, as in 1.x.
- SVG exported with physical units has `width`/`height` with a unit suffix
  (`88mm`); the `viewBox` is unchanged.
- `.tif` and `.tiff` are a format now (they raised an `ErrorException`).
- An unwritable destination directory raises an `ArgumentError` before
  rendering.
- HTML export embeds plotly.js (about 4.5 MB per file) instead of loading it
  from a CDN; MathJax still comes from its CDN.

```julia
fig = plot_scatter(1:3, [1, 2, 3]; width = 400, height = 300)
savefig(fig, "small.png")                       # 400 x 300 px
savefig(fig, "default.png"; width = 700, height = 500)
```

## Templates, styles and math settings

- On dark templates the axis lines, ticks and the default legend box use the
  template's colours instead of black and white.
- `set_template!` also replaces the colours that were derived from the
  previous template; colours you set yourself are kept.
- `get_default_template()` may return a `PlotlyBase.Template`.
- `set_template!(fig, name; kwargs...)` with keywords raises an
  `ArgumentError`.
- `PLOTLYSUPPLY_MATHJAX_SVG_FONT` accepts only the MathJax 2.7 SVG fonts
  (`TeX`, `STIX-Web`, `Asana-Math`, `Neo-Euler`, `Gyre-Pagella`,
  `Gyre-Termes`, `Latin-Modern`).
- New polar plots put the radial tick labels at 22.5° with at most 6 ticks
  (`rlabel_angle` changes the angle).
- `:publication` and `colorway = :okabe_ito` use `COLOR_CYCLES[:okabe_ito]` in a
  line-safe order whose first colour is `#0072B2`; 1.x followed PlotlyBase's
  order, starting with `#E69F00`. A symbol `colorway` looks in `COLOR_CYCLES`
  before `PlotlyBase.colors`.
- The `:publication` font family changed from "STIXGeneral, Times New Roman,
  serif" to "Times New Roman, Times, Liberation Serif, serif" so that PDF
  export embeds TrueType fonts instead of Type 3. Sans presets use "Arial,
  Helvetica, Liberation Sans, sans-serif".
- `figsize!` stores exact (unrounded) sizes: 10 cm is 377.95 px, not 378.
  `figsize!` with `show`, an unknown keyword or `String` units raises an
  `ArgumentError` (a `MethodError` before).
- Under a style that sets `linewidth`, `errorbar_width`, `axis_linewidth` or
  `tick_length`, contour line widths, error-bar thickness and trace colorbar
  fonts, outline and ticks follow it. `:default` is unchanged.
- Journal presets (`:ieee`, `:aps`, `:nature`, `:elsevier`, `:springer`,
  `:aip`), `figsize!(fig, :ieee; columns = 2)`, `journal_width`, the
  `PlotStyle` fields `width`, `aspect`, `axis_linewidth`, `tick_length`,
  `mirror_ticks`, `errorbar_width`, `reference_linewidth` and the
  `:dash_symbol` cycle are new, as is `COLOR_CYCLES`.
- Grey levels as strings (`"0.35"`) are accepted wherever PlotStyle,
  `set_fonts!` and the 3-D colour keywords take a colour.
- Colorbar settings of `shared_colorbar!`: `cmid` inside `crange` builds a
  two-slope scale and no longer throws; a matches-group root that has a range
  gets an explicit `autorange = false`.

## Errors

Invalid input raises an `ArgumentError` whose message starts with the public
function name (`"plot_scatter!: ..."`). Unknown keywords and `show` on
mutators raise an `ArgumentError` instead of a `MethodError` in the mutators,
3-D, mesh and map functions; the 2-D constructors still raise a
`MethodError` for an unknown keyword.

```julia
fig = plot_scatter(1:3, [1, 2, 3])
try
    plot_scatter!(fig, 1:3, [1, 2]; legend = "short")
catch err
    err isa ArgumentError || rethrow()
end
```
