# Migrating from 1.x

PlotlySupply 2.0 keeps every name that 1.9.3 exported; the changes are in
behaviour. Code blocks marked "1.x" show the old usage; the block after it is
the 2.0 form.

## Colormap names

Named colour scales follow matplotlib's orientation, and an unknown name is an
`ArgumentError`. In 1.x the names went to plotly.js, whose `"RdBu"` runs from
blue (low) to red (high) and whose `"Blues"` runs from dark to light. The
trace now stores the resolved stops instead of the name.

```julia
# fragment: 1.x code
plot_heatmap(U; colorscale = "RdBu")    # blue at the low end in 1.x
```

```julia
using PlotlySupply

U = randn(20, 10)
fig = plot_heatmap(U; colorscale = "RdBu_r")   # blue at the low end in 2.0
fig.data[1][:colorscale][1]                    # [0.0, "#053061"], not "RdBu"
```

This applies to every function with a `colorscale`, including the 3-D,
statistical, hierarchy and map functions.

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
- Partial ranges (`(nothing, 5)`), equal bounds, `Bool` bounds and strings on
  numeric axes raise an `ArgumentError`. Date axes still take date strings.
- On shared axes (`subplots(...; shared_xaxes = true)`) the range is written
  to the axis that owns the shared range, so every cell of the group changes.
  1.x silently ignored such calls.
- Mutators write `xrange`, `yrange`, `xscale`, `yscale` and `grid` to the
  primary axes only; 1.x wrote them to every axis of the figure.

```julia
fig = plot_scatter(1:10, rand(10))
xrange!(fig, (2, 8))
xrange!(fig, nothing)            # automatic again
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
- Map functions raise an `ArgumentError` for a keyword that is not an
  attribute of the trace, for empty data, and for `show`, `row` or `col` on
  a `Plot`. Map titles and legend names go through mathtext.

```julia
# fragment: 1.x code
plot_indicator(72)                 # number and a zero delta
```

```julia
fig = plot_indicator(72; reference = 65)
fig.data[1][:mode]                 # "number+delta"
```

## Export and windows

- `savefig` without `width`/`height` uses the figure's `layout.width` and
  `layout.height`; 1.x always used 700 x 500 px.
- Exports are deterministic by default (`deterministic = true`).
- `redraw!` rebuilds the page from the Julia figure.
- At Julia exit, the Electron processes PlotlySupply started are closed and
  waited for (scripts take 1 to 4 s longer to exit).

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
