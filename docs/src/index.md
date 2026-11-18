# PlotlySupply.jl

PlotlySupply.jl is a plotting package for scientific figures, built on
[PlotlyBase.jl](https://github.com/sglyon/PlotlyBase.jl). One call draws a line
plot, a field, a mesh or a 3-D scene with labelled axes; `!` functions add to
a figure or to one cell of a subplot grid; [`savefig`](@ref) writes PDF, SVG,
EPS, PNG, JPEG or TIFF at an exact physical size. Journal presets (`:ieee`,
`:aps`, `:nature`, `:elsevier`, `:springer`, `:aip`) set the column width,
fonts in points, line weights and colour-blind-safe colours. Figures are plain
`PlotlyBase.Plot` objects, so the whole PlotlyBase API stays available.
Windows and image export use Electron through ElectronCall.jl; neither
PlotlyJS.jl nor Python is needed.

## Installation

```julia
# fragment: installs the package
using Pkg
Pkg.add("PlotlySupply")
```

The package precompiles a workload of the common calls, so the first figure
of a session takes about half a second instead of half a minute. The price is
a longer one-time precompilation after each install or update (minutes) and a
larger package image (about 70 MB). To skip the workload, see
[Performance](performance.md).

## Quick tour

Lines on logarithmic axes, with ranges in data units and ticks at powers of ten:

```julia
using PlotlySupply

h = 0.2 ./ 2 .^ (0:6)
err = 3 .* h .^ 2 .+ 1e-5 .* h
fig = plot_scatter(h, err; mode = "lines+markers", legend = "measured",
    xscale = "log", yscale = "log", xrange = [1e-3, 1], yticks = :decades,
    xlabel = "mesh size \$h\$", ylabel = "error")
slope_guide!(fig, 2; x = (3e-3, 0.2), through = (0.2, 0.3), label = "\$O(h^2)\$")
```

A field: matrices are indexed `U[ix, iy]`, so build them with `x` in the outer
loop. `equalar = true` keeps the aspect ratio, and the axes fit the field
without padding:

```julia
xs = range(-2, 2; length = 81)
ys = range(-1, 1; length = 41)
U = [exp(-x^2 - 3y^2) for x in xs, y in ys]      # size (81, 41)
fig = plot_heatmap(xs, ys, U; colorscale = "viridis", equalar = true,
    xlabel = "\$x\$", ylabel = "\$y\$", colorbar_title = "\$|E|^2\$")
plot_contour!(fig, xs, ys, U; levels = [0.25, 0.5, 0.75], coloring = "none",
    linecolor = "white")
```

Subplots with one colorbar for both panels:

```julia
sf = subplots(1, 2; sync = false, width = 700, height = 320,
    subplot_titles = ["(a) t = 0", "(b) t = 1"])
plot_heatmap!(sf, xs, ys, U; row = 1, col = 1)
plot_heatmap!(sf, xs, ys, 0.5 .* U; row = 1, col = 2)
shared_colorbar!(sf; title = "intensity", colorscale = "magma")
```

A figure for a paper. A journal preset sets the fonts (in points), line
weights, colour-blind-safe colours and the single-column width; `savefig`
without a size uses that width, so the PDF page is exactly 3.5 in wide with
Times New Roman embedded. `figsize!(fig, :ieee; columns = 2)` and
`journal_width(:nature; columns = 2, units = :mm)` give the other widths:

```julia
t = 0:0.05:10
fig = with_style(:ieee) do
    plot_scatter(t, [sin.(t), cos.(t)]; legend = ["\$\\sin t\$", "\$\\cos t\$"],
        xlabel = "time \$t\$ (s)", ylabel = "signal")
end
savefig(fig, "signal.pdf")                 # 3.5 in x 2.625 in, fonts embedded
savefig(fig, "signal.tif"; dpi = 600)      # TIFF, LZW, 2100 x 1575 px
```

A two-panel figure at the double-column width, drawn after the size is set:

```julia
w = journal_width(:aps; columns = 2, units = :px)
sf = with_style(:aps) do
    sf = subplots(1, 2; sync = false, width = w, height = 0.4w)
    plot_scatter!(sf, t, sin.(t); row = 1, col = 1, ylabel = "\$u\$", xlabel = "\$t\$")
    plot_heatmap!(sf, xs, ys, U; row = 1, col = 2, colorscale = "RdBu_r", zrange = (-1, 1),
        xlabel = "\$x\$", colorbar_title = "\$|E|\$")
    panel_labels!(sf; labels = :abc, format = "({})")
    sf
end
savefig(sf, "fields.pdf")                  # 17.2 cm wide page
```

[Figures for papers](papers.md)
has complete examples (convergence plot, field maps, 3-D surfaces, schematic), and
the [Gallery](gallery.md) shows 44 figures, each with its script, that recreate the
figure types of three research projects.

MATLAB-style subplots: `subplot!` selects the active cell, and the axis helpers
(`xlabel!`, `ylabel!`, `xrange!`, ...) act on the active cell, so call them
right after drawing into it:

```julia
sf = subplots(2, 2; sync = false, legend_position = :topright)
plot!(sf, 1:100, cumsum(randn(100)); legend = "run A")
xlabel!(sf, "time"); ylabel!(sf, "value"); xrange!(sf, [0, 100])
subplot!(sf, 1, 2)
plot_stem!(sf, 1:100, abs.(randn(100)); legend = "run B")
subplot!(sf, 3)                      # index 3 = row 2, column 1
plot_contour!(sf, rand(30, 30))
subplot!(sf, 2, 2)
plot_heatmap!(sf, rand(30, 30))      # each colorbar sits next to its own cell
```

`subplots(...; sync = true)` (the default) shows the grid in a live window;
`sync = false` builds it without one. A constructor returns a `Plot`; pass
`show = true` to open it in a window, or call `display(fig)`.

## Conventions

- **Matrices are `U[ix, iy]`.** For `plot_heatmap`, `plot_contour`,
  `plot_quiver`, `plot_streamlines` and `plot_surface`, `U[i, j]` is the value
  at `(x[i], y[j])` and `size(U) == (length(x), length(y))`. Build it as
  `[f(x, y) for x in xs, y in ys]`. A transposed matrix raises an
  `ArgumentError` that says so. `plot_matrix(A)` is the exception: it draws `A`
  as printed (row 1 at the top). `plot_image` takes an `H x W x 3` (or 4)
  array with channel values 0 to 255, row 1 at the top.
- **Ranges are data values, also on log axes.** `xrange = [1e-3, 1]` on a log
  axis, never exponents. `[0, 0]`, `(0, 0)` or `nothing` means automatic. A
  one-sided limit fixes one end and autoranges the other:
  `yrange = (0, nothing)` or `xrange!(fig, (nothing, 10))` (matplotlib's
  `set_ylim(bottom = 0)`); the first bound is always the left or bottom end.
  Equal bounds and non-positive bounds on a log axis raise an `ArgumentError`.
- **Decorations get their own room.** A colorbar, an outside legend, a panel
  title or label takes room from its own cell or from the figure margin, never
  from a neighbouring panel; a figure that already fits, and any position you
  set yourself, is left alone. Choose the figure size first (journal
  `figsize!`, or `width`/`height`): the layout is fitted for the size the figure
  has when you call, and again at the export size.
- **Mutators end in `!`** and take a `Plot`, a `SyncPlot` (the window updates)
  or a `SubplotFigure`. On a `SubplotFigure` they draw into the active cell, or
  into `row`/`col`; Cartesian mutators also take `secondary_y = true` and
  `inset = k`. They return `nothing`, or the `SubplotFigure`.
- **Labels are mathtext.** Titles, axis labels, legend names and annotations
  may mix text and `$...$` math (`"time \$t\$ (s)"`); an unbalanced `$` is an
  error and `\$` is a literal dollar sign.
- **Invalid input is an error, not a broken figure.** Mismatched lengths,
  wrongly shaped matrices, unknown colormap names and invalid ranges raise an
  `ArgumentError` naming the function, before the figure is changed.

## Guides

- [Lines and markers](lines.md): line and marker plots, error bars, bands,
  stems, segments, polar and complex data, twin y axes.
- [Statistical plots](statistics.md): bars, histograms, box and violin plots,
  ECDF and KDE.
- [2-D fields](fields.md): heatmaps, contours, meshes, quivers and
  streamlines; tight axes and equal aspect.
- [3-D plots](threed.md): surfaces, meshes, vector fields, cameras and scenes.
- [Subplots](subplots.md): grids, shared axes, insets, twin axes, colorbars,
  legends, panel labels.
- [Axes and ticks](axes.md): ranges, log axes, tick presets, date axes.
- [Text and math](text.md): mathtext rules, fonts and sizes, annotations.
- [Colours](colors.md): colormaps, norms, discrete maps, colorbars.
- [Reference lines and shapes](shapes.md): guide lines, spans, slope markers,
  schematics.
- [Styles and templates](styles.md): `PlotStyle`, templates, figure size.
- [Export](export.md): file formats, physical sizes, resolution.
- [Live windows](windows.md): `SyncPlot` and Electron.
- [Other charts and maps](charts.md): pie, sunburst, Sankey, financial charts,
  geographic and tile maps.
- [Figures for papers](papers.md): from data to a camera-ready figure.
- [Gallery](gallery.md): 44 complete figures with their scripts (`docs/gallery/`).
- [Performance](performance.md): load time, time to first figure, the precompile workload and the benchmarks.
- [Coming from matplotlib](matplotlib.md) and [Migrating from 1.x](migration.md).

Every exported name is documented in the [API reference](api.md); the
PlotlyBase names PlotlySupply re-exports are listed on the
[compatibility page](compat.md).

## Common keywords

Keyword support is grouped by family:

- **2-D Cartesian constructors:** `plot_scatter`, `plot_stem`, `plot_area`, `plot_band`, `plot_segments`, `plot_vlines`, `plot_hlines`, `plot_ecdf`, `plot_kde`, `plot_complex`, `plot_bar`, `plot_histogram`, `plot_box`, `plot_violin`, `plot_histogram2d`, `plot_funnel`, `plot_waterfall`, `plot_candlestick`, `plot_ohlc`, `plot_heatmap`, `plot_contour`, `plot_quiver`, `plot_streamlines`, `plot_image`, `plot_matrix`, `plot_pcolormesh`, `plot_polygons`, `plot_tripcolor`, `plot_triplot`, `plot_tricontour`
- **3-D constructors:** `plot_scatter3d`, `plot_surface`, `plot_wireframe`, `plot_segments3d`, `plot_mesh3d`, `plot_polygons3d`, `plot_quiver3d`, `plot_isosurface`, `plot_volume`, `plot_streamtube`
- **Colour-mapped constructors:** `plot_heatmap`, `plot_contour`, `plot_histogram2d`, `plot_matrix`, `plot_pcolormesh`, `plot_polygons`, `plot_tripcolor`, `plot_tricontour`, `plot_streamlines`, `plot_surface`, `plot_mesh3d`, `plot_polygons3d`, `plot_quiver3d`, `plot_isosurface`, `plot_volume`, `plot_streamtube`

| Keywords | Meaning | Accepted by | Except |
|---|---|---|---|
| `title`, `width`, `height`, `fontsize`, `show` | figure title; size in px (0 = automatic); base font size (0 = template); `show = true` opens a window and returns a `SyncPlot` | every constructor | none |
| `xlabel`, `ylabel`, `grid` | axis titles; `grid = false` hides the grid | 2-D Cartesian | none |
| `xrange`, `yrange` | axis limits `[lo, hi]` in data units, also on log axes; `(lo, nothing)` or `(nothing, hi)` fixes one end; `[0, 0]` or `nothing` is automatic | 2-D Cartesian | `plot_matrix` |
| `xscale`, `yscale` | `"linear"` or `"log"` | 2-D Cartesian | `plot_complex`, `plot_funnel`, `plot_waterfall`, `plot_image`, `plot_matrix` |
| `xticks`, `yticks`, `xticklabels`, `yticklabels`, `xtickformat`, `ytickformat` | tick values (data units) or the presets `:decades` and `:auto`, their labels, a d3 format | 2-D Cartesian | none |
| `equalar` | equal axis scales (aspect ratio 1) | 2-D Cartesian | `plot_bar`, `plot_histogram`, `plot_box`, `plot_violin`, `plot_histogram2d`, `plot_funnel`, `plot_waterfall`, `plot_candlestick`, `plot_ohlc` |
| `legend` | legend name; unnamed traces get no legend entry | 2-D Cartesian | `plot_histogram2d`, `plot_heatmap`, `plot_contour`, `plot_image`, `plot_matrix`, `plot_pcolormesh`, `plot_tripcolor`, `plot_tricontour` |
| `color` | one colour, or one per series | 2-D Cartesian | `plot_histogram2d`, `plot_waterfall`, `plot_candlestick`, `plot_ohlc`, `plot_heatmap`, `plot_contour`, `plot_image`, `plot_matrix`, `plot_pcolormesh`, `plot_tripcolor` |
| `xlabel`, `ylabel`, `zlabel`, `xrange`, `yrange`, `zrange`, `aspectmode`, `perspective`, `showaxis`, `grid`, `view` | scene axes, ranges, aspect, projection and camera `(elev, azim)` | 3-D | none |
| `colorscale` | colormap name, colours or `(t, colour)` stops | Colour-mapped | none |
| `crange` | colour limits `[lo, hi]`; `[0, 0]` is automatic | Colour-mapped | `plot_streamlines` |
| `cmid` | value at the centre of the colormap (diverging data) | Colour-mapped | `plot_streamlines`, `plot_tricontour` |
| `colornorm`, `showscale` | `:linear` or `:log` colour mapping; colorbar on or off | Colour-mapped | `plot_matrix`, `plot_streamlines`, `plot_tricontour` |
| `colorbar_title` | colorbar title (mathtext) | Colour-mapped | `plot_tricontour` |
| `mode`, `marker_size`, `marker_symbol` | `"lines"`, `"markers"`, `"lines+markers"`; marker size in px; marker symbol | `plot_scatter`, `plot_scatterpolar`, `plot_scatter3d`, `plot_complex` | none |
| `dash`, `linewidth` | dash pattern (`"dash"`, `"dot"`, `"--"`, ...); line width in px | `plot_scatter`, `plot_scatterpolar`, `plot_scatter3d`, `plot_complex`, `plot_segments`, `plot_segments3d`, `plot_vlines`, `plot_hlines`, `plot_ecdf`, `plot_kde`, `plot_contour`, `plot_triplot`, `plot_tricontour`, `plot_wireframe` | none |
| `trange`, `rrange`, `rlabel_angle`, `thetaunit`, `direction`, `rotation` | polar sector and radial range, radial label angle, angle unit and orientation | `plot_scatterpolar` | none |
| `tight` | `false` restores plotly's padded autorange around a field | `plot_heatmap`, `plot_contour`, `plot_image`, `plot_matrix`, `plot_pcolormesh`, `plot_polygons`, `plot_tripcolor` | none |

`plot_scatterpolar` takes none of the Cartesian axis keywords; use `trange`,
`rrange` or `update_polars!`. Mutators (`plot_*!`) take the keywords of their
constructor except `show`. A keyword a function does not take raises an error.
