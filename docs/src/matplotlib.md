# Coming from matplotlib

The table maps common matplotlib idioms to PlotlySupply calls. The examples
below the table run every row.

| matplotlib | PlotlySupply |
|---|---|
| `PolyCollection(verts, array=..., cmap=...)`, `set_clim`, shared colorbar | [`plot_polygons`](@ref) with `crange`, [`shared_colorbar!`](@ref) |
| `pcolormesh(X, Y, C, shading="flat")`, mirrored | [`plot_pcolormesh`](@ref), called again with `-X` |
| `tripcolor(tri, v, shading="gouraud", mask=...)` | [`plot_tripcolor`](@ref)`(...; shading = :gouraud, mask)` |
| `Poly3DCollection(..., array=...)`, `set_clim` | [`plot_polygons3d`](@ref), or [`plot_mesh3d`](@ref) with per-face `intensity` and `edges = true` |
| `view_init(elev, azim)`, `set_proj_type("ortho")`, `set_box_aspect` | [`view!`](@ref)`(...; elev, azim, projection)`, [`scene!`](@ref)`(...; aspectratio)` |
| `Line3DCollection(alpha=0.35)`, `plot_wireframe` | [`plot_segments3d`](@ref)`(...; opacity = 0.35)`, [`plot_wireframe`](@ref) |
| `ax.text(x, y, z, "C")`, 3-D `quiver` | [`annotate!`](@ref)`(fig, x, y, z, "C")`, [`plot_quiver3d`](@ref)`(...; style = :arrow)` |
| `cmap="magma"`, `"RdBu_r"`, `ListedColormap`, `cmap(np.linspace(...))` | `colorscale = "magma"`, [`discrete_colormap`](@ref), [`colormap_colors`](@ref) |
| `TwoSlopeNorm`, `LogNorm`, `BoundaryNorm`, symmetric `clim` | `cmid`, `colornorm = :log`, `levels`, `crange` |
| `fig.colorbar(ax=axes, shrink=..., label=..., ticks=...)`, `cax` | [`shared_colorbar!`](@ref), [`colorbar!`](@ref)`(...; title, len, ticks, x, y)` |
| `fig.legend(handles, loc="lower center", ncol=..., frameon=False)` | [`set_legend!`](@ref)`(...; position = :outside_bottom, ncols, frame = false)`, [`legend_entry!`](@ref) |
| `set_xticks(v, labels)`, `LogLocator(subs=...)`, `FuncFormatter("{:g}")`, `minorticks_off()` | [`xticks!`](@ref)`(fig, v, labels)`, `subs = (1, 2, 5)`, `"~g"` (the default), `minor = false` |
| `set_aspect("equal")`, `axis("off")`, top/right spines off, `grid(axis="y", alpha=...)` | [`axis_equal!`](@ref) or `equalar = true`, [`axis_off!`](@ref), [`spines!`](@ref)`(...; style = :open)`, [`grid!`](@ref)`(...; axis = :y, alpha)` |
| `set_title("(a) ...", loc="left", fontweight="bold")`, `suptitle`, `fig.text` | [`title!`](@ref)`(sf, ...; row, col, align = :left, bold = true)`, `title!(sf, ...)`, `annotate!(...; coords = :figure)` |
| mathtext labels mixing text and `$...$`, `"\n"` | automatic (see [Text and math](text.md)) |
| `mfc="white"`, `fillstyle="none"`, `mew`, `markevery`, `alpha` | `marker_color = "white"` or `"none"`, `marker_line_width`, `markevery`, `opacity` |
| `fill_between`, `axhline`, `axvline`, `axhspan`, `axvspan` | [`plot_band`](@ref), [`hline!`](@ref), [`vline!`](@ref), [`hspan!`](@ref), [`vspan!`](@ref) |
| `annotate(..., xytext=..., textcoords="offset points")`, slope guides | `annotate!(...; offset)` (also on log axes), [`slope_guide!`](@ref), [`slope_triangle!`](@ref) |
| `Circle`, `Rectangle`, `FancyBboxPatch`, `FancyArrowPatch("<->")`, `Arc` | [`circle!`](@ref), [`rectangle!`](@ref)`(...; rounded)`, [`arrow!`](@ref)`(...; head = :both)`, [`arc!`](@ref) |
| `contour(..., levels=[0], colors="white")`, `clabel` | [`plot_contour!`](@ref)`(...; levels = [0.0], coloring = "none", linecolor = "white", showlabels = true)` |
| annotated `imshow` | [`plot_heatmap`](@ref)`(...; text, texttemplate, origin = :upper)`, [`plot_matrix`](@ref) |
| `vlines(x, 0, w)`, `step(where="post")` | [`plot_vlines`](@ref), `line_shape = "hv"` |
| `secondary_xaxis("top", functions=...)`, `inset_axes` | [`secondary_xaxis!`](@ref), [`inset!`](@ref) and `inset = k` |
| `bar(..., hatch="///")`, `bar_label` | [`plot_bar`](@ref)`(...; hatch, text, textposition)` |
| `figsize` in inches, `dpi`, `metadata={"CreationDate": None}`, `.eps`, `bbox_inches="tight"` | [`savefig`](@ref)`(...; width, height, units = :in, dpi)`, `deterministic = true` (the default), `.eps`, `tight = true` |
| `rcParams`, `rc_context`, font sizes per role | [`set_default_style!`](@ref), [`with_style`](@ref), [`set_fonts!`](@ref) |

Two conventions differ from matplotlib:

- Field matrices are indexed `U[ix, iy]` (`size(U) == (length(x), length(y))`),
  the transpose of matplotlib's `Z[iy, ix]`. Pass `permutedims(Z)` for data
  laid out for matplotlib. [`plot_matrix`](@ref) and [`plot_image`](@ref)
  keep the printed (row, column) layout.
- Sizes are in px at 96 px per inch, so matplotlib's 10 pt font is about
  13.3 px; [`set_fonts!`](@ref) and [`savefig`](@ref) take `units = :pt` or
  `:in`.

## Patches, meshes and colour scales

```julia
using PlotlySupply

px = [[0.0, 1, 1, 0], [1.0, 2, 1.5]]
py = [[0.0, 0, 1, 1], [0.0, 0, 1]]
sf = subplots(1, 2; sync = false, width = 800, height = 320)
plot_polygons!(sf, px, py, [1.0, 2.0]; crange = [0, 3], colorscale = "magma",
    row = 1, col = 1)
plot_polygons!(sf, px, py, [0.5, 2.5]; crange = [0, 3], colorscale = "magma",
    row = 1, col = 2)
shared_colorbar!(sf; title = "value")

r = range(1, 2; length = 5); θ = range(0, π / 2; length = 9)
X = [ri * cos(t) for ri in r, t in θ]
Y = [ri * sin(t) for ri in r, t in θ]
C = [ri * t for ri in r[1:end-1], t in θ[1:end-1]]
fig = plot_pcolormesh(X, Y, C; colorscale = "PuOr_r")
plot_pcolormesh!(fig, -X, Y, C; colorscale = "PuOr_r", showscale = false)

x = [0.0, 1, 0, 1, 0.5]; y = [0.0, 0, 1, 1, 0.5]
tri = [1 2 5; 2 4 5; 4 3 5; 3 1 5]
fig = plot_tripcolor(x, y, tri, x .- y; shading = :gouraud,
    mask = [false, false, true, false], colorscale = "coolwarm", cmid = 0)
```

## 3-D

```julia
vx = [0.0, 1, 0, 0]; vy = [0.0, 0, 1, 0]; vz = [0.0, 0, 0, 1]
fig = plot_polygons3d(vx, vy, vz, [[1, 2, 3], [1, 2, 4], [1, 3, 4]], [1.0, 2.0, 3.0])
fig2 = plot_mesh3d(vx, vy, vz; i = [0, 0, 0], j = [1, 1, 2], k = [2, 3, 3],
    intensity = [1.0, 2.0, 3.0], intensitymode = "cell", edges = true, crange = [0, 4])
view!(fig2; elev = 30, azim = -60, projection = "orthographic")
scene!(fig2; aspectratio = (1, 1, 0.5))

plot_segments3d!(fig, vx, vy, vz, [1 2; 2 3; 3 1]; opacity = 0.35, color = "gray")
fig3 = plot_wireframe(1:5, 1:4, rand(5, 4))
annotate!(fig, 0.0, 0.0, 1.0, "C")
fig4 = plot_quiver3d([0.0, 1], [0.0, 0], [0.0, 0], [1.0, 0], [0.0, 1], [0.0, 1];
    style = :arrow)
```

## Colormaps, norms and colorbars

```julia
U = [x * y for x in -1:0.1:1, y in -1:0.1:1]
fig = plot_heatmap(-1:0.1:1, -1:0.1:1, U; colorscale = "RdBu_r", cmid = 0)
fig2 = plot_heatmap(rand(10, 10) .* 1e3 .+ 1; colornorm = :log, colorscale = "magma")
fig3 = plot_heatmap(U; levels = [-1, -0.5, 0, 0.5, 1],
    colorscale = discrete_colormap(colormap_colors("coolwarm", 4)))
fig4 = plot_heatmap(U; crange = [-0.5, 0.5])
colorbar!(fig4; title = "\$u\$", len = 0.5, ticks = [-0.5, 0, 0.5], x = 1.05, y = 0.5)
```

## Legends, ticks, frames and titles

```julia
sf = subplots(1, 2; sync = false)
for c in 1:2
    plot_scatter!(sf, 1:5, rand(5); legend = "data", color = "black", row = 1, col = c)
end
legend_entry!(sf, "model"; color = "crimson", dash = "dash")
set_legend!(sf; position = :outside_bottom, ncols = 2, frame = false)
title!(sf, "(a) Mesh"; row = 1, col = 1, align = :left, bold = true)
title!(sf, "Study")
annotate!(sf, 0.99, 0.01, "draft"; coords = :figure, showarrow = false)

fig = plot_scatter([1e-2, 1e2], [1.0, 2.0]; xscale = "log")
xticks!(fig; subs = (1, 2, 5), minor = false)
fig2 = plot_scatter(0:3, [0, 1, 4, 9])
xticks!(fig2, [0, 1, 2, 3], ["zero", "one", "two", "three"])
axis_equal!(fig2)
spines!(fig2; style = :open)
grid!(fig2; axis = :y, alpha = 0.3)
fig3 = plot_heatmap(rand(5, 5))
axis_off!(fig3)
```

## Markers, bands, reference lines and annotations

```julia
x = collect(0:0.5:10)
fig = plot_scatter(x, sin.(x); mode = "lines+markers", marker_color = "white",
    marker_line_width = 1.5, markevery = 4, legend = "sin")
plot_scatter!(fig, x, cos.(x); mode = "markers", marker_color = "none", opacity = 0.6,
    legend = "cos")
plot_band!(fig, x, sin.(x) .- 0.2, sin.(x) .+ 0.2; color = "#0072B2", opacity = 0.2)
hline!(fig, 0; color = "gray")
vline!(fig, 5; dash = "dot")
hspan!(fig, -0.25, 0.25; opacity = 0.2)
vspan!(fig, 2, 3; color = "orange", opacity = 0.2)

h = [0.1, 0.05, 0.025]
fig2 = plot_scatter(h, 3 .* h .^ 2; xscale = "log", yscale = "log", mode = "markers")
annotate!(fig2, 0.05, 7.5e-3, "mid"; offset = (20, -20))
slope_guide!(fig2, 2; x = (0.025, 0.1), through = (0.1, 0.01), label = "2")
slope_triangle!(fig2, 0.05, 3e-3, 2)
```

## Shapes, contours, annotated images and steps

```julia
fig = plot_scatter(Float64[], Float64[]; xrange = [0, 6], yrange = [0, 3], equalar = true)
circle!(fig, 1, 1.5, 0.5)
rectangle!(fig, 2, 1, 3.5, 2; rounded = 0.2)
arrow!(fig, 3.5, 1.5, 5, 1.5; head = :both)
arc!(fig, 1, 1.5, 0.8, 0, 90; arrow = :end)

xs = range(-1, 1; length = 41)
U = [x^2 - y^2 for x in xs, y in xs]
fig2 = plot_heatmap(xs, xs, U; colorscale = "RdBu_r", cmid = 0)
plot_contour!(fig2, xs, xs, U; levels = [0.0], coloring = "none", linecolor = "white",
    showlabels = true)

M = [1 2 3; 4 5 6]
fig3 = plot_heatmap(1:2, 1:3, M; text = string.(M), origin = :upper)
fig4 = plot_matrix(M)
fig5 = plot_vlines([1, 2, 3], 0, [0.5, 1.0, 0.25]; xrange = (0.5, 3.5))
fig6 = plot_scatter(1:5, [1, 3, 2, 4, 3]; line_shape = "hv")
```

## Axes, bars, export and styles

```julia
λ = collect(400.0:10:700.0)
fig = plot_scatter(λ, rand(length(λ)); xlabel = "wavelength (nm)")
secondary_xaxis!(fig, l -> 299792.458 / l, ν -> 299792.458 / ν; title = "frequency (THz)")
sf = subplots(1, 1; sync = false)
plot_scatter!(sf, 1:10, rand(10))
k = inset!(sf, (0.6, 0.6, 0.35, 0.35))
plot_scatter!(sf, 1:3, rand(3); inset = k)

fig2 = plot_bar(["a", "b"], [3.0, 2.0]; hatch = "///", text = ["3", "2"],
    textposition = "outside")
savefig(fig2, "bars.pdf"; width = 3.5, height = 2.5, units = :in, tight = true)
savefig(fig2, "bars.png"; width = 3.5, height = 2.5, units = :in, dpi = 300)

set_default_style!(:publication)
fig3 = with_style(:default) do
    plot_scatter(1:3, [1, 2, 3])
end
set_default_style!(:default)
set_fonts!(fig3; title = 12, label = 10, tick = 8, units = :pt)
```

```julia
# fragment: needs Ghostscript (gs) on PATH
savefig(fig2, "bars.eps"; width = 3.5, height = 2.5, units = :in)
```
