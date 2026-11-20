# PlotlySupply.jl

[![Build Status](https://github.com/jake-w-liu/PlotlySupply.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jake-w-liu/PlotlySupply.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/jake-w-liu/PlotlySupply.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jake-w-liu/PlotlySupply.jl)

PlotlySupply.jl is a plotting package for scientific figures, built on
[PlotlyBase.jl](https://github.com/sglyon/PlotlyBase.jl). One call draws a line
plot, a field, a mesh or a 3-D scene with labelled axes; `!` functions add to
a figure or to one cell of a subplot grid; `savefig` writes PDF, SVG, EPS, PNG,
JPEG or TIFF at an exact physical size. Journal presets (`:ieee`, `:aps`,
`:nature`, `:elsevier`, `:springer`, `:aip`) set the column width, fonts in
points, line weights and colour-blind-safe colours. Figures are plain
`PlotlyBase.Plot` objects, so the whole PlotlyBase API stays available.
Windows and image export use Electron through ElectronCall.jl; neither
PlotlyJS.jl nor Python is needed.

Documentation: [stable](https://jake-w-liu.github.io/PlotlySupply.jl/stable/),
[dev](https://jake-w-liu.github.io/PlotlySupply.jl/dev/).

## Installation

```julia
# fragment: installs the package
using Pkg
Pkg.add("PlotlySupply")
```

The package precompiles a workload of the common calls, so the first figure
of a session takes about a third of a second instead of 15 seconds. The price is
a longer one-time precompilation after each install or update (minutes) and a
larger package image (about 90 MB). To skip the workload, see
[Performance](https://jake-w-liu.github.io/PlotlySupply.jl/dev/performance/).

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

[Figures for papers](https://jake-w-liu.github.io/PlotlySupply.jl/dev/papers/)
has complete examples (convergence plot, field maps, 3-D surfaces, schematic), and
the [Gallery](https://jake-w-liu.github.io/PlotlySupply.jl/dev/gallery/) shows 44 figures,
each with its script in `docs/gallery/`.

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
  set yourself, is left alone. `figsize!` after the content is fine: the room
  is solved again for the new size, and once more at the export size.
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

## Function overview

Every function has a `!` form that adds to an existing figure, except where
the table lists only one name.

| Purpose | Functions |
|---|---|
| Lines and markers | `plot_scatter`, `plot_scatter!`, `plot_stem`, `plot_stem!`, `plot_area`, `plot_area!`, `plot_band`, `plot_band!`, `plot_segments`, `plot_segments!`, `plot_vlines`, `plot_vlines!`, `plot_hlines`, `plot_hlines!`, `plot_complex`, `plot_complex!`, `plot_scatterpolar`, `plot_scatterpolar!` |
| Statistics | `plot_bar`, `plot_bar!`, `plot_histogram`, `plot_histogram!`, `plot_histogram2d`, `plot_histogram2d!`, `plot_box`, `plot_box!`, `plot_violin`, `plot_violin!`, `plot_ecdf`, `plot_ecdf!`, `plot_kde`, `plot_kde!` |
| 2-D fields and meshes | `plot_heatmap`, `plot_heatmap!`, `plot_contour`, `plot_contour!`, `plot_matrix`, `plot_matrix!`, `plot_image`, `plot_image!`, `plot_pcolormesh`, `plot_pcolormesh!`, `plot_polygons`, `plot_polygons!`, `plot_tripcolor`, `plot_tripcolor!`, `plot_triplot`, `plot_triplot!`, `plot_tricontour`, `plot_tricontour!` |
| Vector fields | `plot_quiver` (arrows or triangles), `plot_quiver!`, `plot_streamlines`, `plot_streamlines!` |
| 3-D | `plot_surface`, `plot_surface!`, `plot_wireframe`, `plot_wireframe!`, `plot_scatter3d`, `plot_scatter3d!`, `plot_segments3d`, `plot_segments3d!`, `plot_mesh3d`, `plot_mesh3d!`, `plot_polygons3d`, `plot_polygons3d!`, `plot_quiver3d`, `plot_quiver3d!`, `plot_isosurface`, `plot_isosurface!`, `plot_volume`, `plot_volume!`, `plot_streamtube`, `plot_streamtube!` |
| 3-D scenes | `view!` (camera), `scene!` (aspect, panes, ticks), `zlabel!`, `zrange!` |
| Other charts | `plot_pie`, `plot_pie!`, `plot_sunburst`, `plot_sunburst!`, `plot_treemap`, `plot_treemap!`, `plot_funnel`, `plot_funnel!`, `plot_funnelarea`, `plot_funnelarea!`, `plot_waterfall`, `plot_waterfall!`, `plot_indicator`, `plot_indicator!`, `plot_sankey`, `plot_sankey!`, `plot_parcoords`, `plot_parcoords!`, `plot_ternary`, `plot_ternary!`, `plot_candlestick`, `plot_candlestick!`, `plot_ohlc`, `plot_ohlc!` |
| Maps | `plot_scattergeo`, `plot_scattergeo!`, `plot_choropleth`, `plot_choropleth!`, `plot_scattermap`, `plot_scattermap!`, `plot_choroplethmap`, `plot_choroplethmap!`, `plot_densitymap`, `plot_densitymap!`, `plot_scattermapbox`, `plot_scattermapbox!`, `plot_choroplethmapbox`, `plot_choroplethmapbox!`, `plot_densitymapbox`, `plot_densitymapbox!`, `update_maps!`; trace constructors `scattermap`, `choroplethmap`, `densitymap` |
| Subplot grids | `subplots`, `subplot!`, `SubplotFigure`, `inset!`, `remove_inset!`, `secondary_xaxis!`, `subplot_legends!`, `panel_labels!`, `make_subplots` (PlotlyJS-style), `mgrid` (PlotlyJS-style grid helper) |
| Axes and ticks | `xlabel!`, `ylabel!`, `xrange!`, `yrange!`, `xticks!`, `yticks!`, `log_ticks`, `axis_equal!`, `axis_off!`, `grid!`, `spines!` |
| Figure layout | `title!`, `figsize!` (pixels, physical units or a journal), `journal_width`, `tight_layout!` |
| Legends | `set_legend!`, `legend_entry!`, `set_default_legend_position!`, `get_default_legend_position` |
| Colour | `colormap`, `colormap_colors`, `discrete_colormap`, `lighten`, `COLORMAPS`, `COLOR_CYCLES`, `colorbar!`, `shared_colorbar!` |
| Text and math | `mathtext`, `annotate!`, `set_fonts!`, `set_default_mathtext!`, `get_default_mathtext` |
| Reference lines and shapes | `hline!`, `vline!`, `hspan!`, `vspan!`, `slope_guide!`, `slope_triangle!`, `circle!`, `ellipse!`, `arc!`, `arrow!`, `rectangle!`, `polygon!` |
| Styles and templates | `PlotStyle` (journal presets `:ieee`, `:aps`, `:nature`, `:elsevier`, `:springer`, `:aip`), `set_default_style!`, `get_default_style`, `with_style`, `register_style!`, `set_template!`, `set_default_template!`, `get_default_template` |
| Export | `savefig`, `json` |
| Windows and PlotlyJS compatibility | `SyncPlot`, `to_syncplot`, `plot`, `plot!` (same as the scatter mutator), `msgchannel`, `toggle_devtools` |

The two colour tables are public but not exported: write
`PlotlySupply.COLORMAPS` and `PlotlySupply.COLOR_CYCLES`.

PlotlySupply also re-exports PlotlyBase (`scatter`, `Layout`, `attr`,
`relayout!`, `restyle!`, `add_trace!`, `Spec`, ...), `meshgrid` from
MeshGrid.jl and the LaTeX string macro `@L_str` from LaTeXStrings.jl.

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

## Export

`savefig(fig, "name.ext"; ...)` writes `pdf`, `svg`, `eps` (through Ghostscript),
`png`, `jpeg`, `tiff` (`.tif`), `html` or `json`, chosen by the extension:

- `width`, `height` with `units = :px` (default), `:in`, `:cm`, `:mm` or `:pt`;
  without them the figure's own size, else the size of the style it carries
  (a journal preset sets one), else, for a figure without a recorded style,
  the active style's default size, else 700 x 500 px. PDF and EPS pages have
  exactly that size in points; PNG, JPEG and TIFF get `round(width * scale)`
  pixels.
- `dpi` for PNG, JPEG and TIFF (stored in the file); TIFF is lossless LZW with
  its resolution tags, 300 dpi unless told otherwise.
- `fonts = :auto` (PDF): text stays text in embedded TrueType fonts. Chromium can
  embed STIX or Latin Modern only as Type 3; `:auto` then outlines the page's
  text with Ghostscript. `:embed` and `:outline` force either. EPS text is
  outlines.
- `background = :transparent`, `tight = true` (trim the margins), and
  `deterministic = true` (the default: repeated exports are byte-identical).
- `savefig(fig, ["fig.pdf", "fig.png"])` writes several files from one render.
- HTML embeds plotly.js (about 4.5 MB per file); MathJax is loaded from its CDN
  when the figure has math.

See the [documentation](https://jake-w-liu.github.io/PlotlySupply.jl/dev/) for
guides to every area, the matplotlib-to-PlotlySupply table and the migration
notes from 1.x.

## License

MIT License. Developed by Jake W. Liu; contributions and issues are welcome.
