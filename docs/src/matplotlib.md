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

## Figure archetypes from real projects

The rows below cover the figure types that appear in real matplotlib projects
(66 figure archetypes from convergence studies, FEM field maps, 3-D surfaces,
schematics and optical device figures; archetypes that differ only in data
share a row), each as the matplotlib construct, the PlotlySupply
statements that draw it and the gallery figure that shows it in a full
figure. Every statement in the right column is run by the test suite on
the data of the block below, so a row that stops working fails the build. The
`;` separates statements; a row creates its own figure.

```julia
using PlotlySupply

x = collect(range(0.0, 1.0; length = 20))
y = sin.(2π .* x)
ys = [y, cos.(2π .* x)]
lo, hi = y .- 0.2, y .+ 0.2
h = 0.5 ./ 2 .^ (0:5)
errs = [2 .* h, 3 .* h .^ 2, 5 .* h .^ 3]
U = [sin(3a) * cos(2b) for a in x, b in x]                    # U[ix, iy]
r = range(1, 2; length = 9);  θ = range(0, π; length = 33)
X = [ri * cos(t) for ri in r, t in θ];  Y = [ri * sin(t) for ri in r, t in θ]
C = [sin(3t) / ri for ri in r[1:end-1], t in θ[1:end-1]]       # one value per cell
tx = [0.0, 1.0, 0.0, 1.0, 0.5];  ty = [0.0, 0.0, 1.0, 1.0, 0.5]
tri = [1 2 5; 2 4 5; 4 3 5; 3 1 5];  tv = tx .+ ty
px = [[0.0, 1, 1, 0], [1.0, 2, 2, 1]];  py = [[0.0, 0, 1, 1], [0.0, 0, 1, 1]];  pv = [1.0, 2.0]
vx = [0.0, 1, 0, 0];  vy = [0.0, 0, 1, 0];  vz = [0.0, 0, 0, 1]
faces = [[1, 2, 3], [1, 2, 4], [1, 3, 4], [2, 3, 4]];  fv = [1.0, 2.0, 3.0, 4.0]
s = range(0, 2π; length = 41)
Zt = [(2 + cos(v)) * cos(u) for u in s, v in s]               # torus x, y, z grids
Yt = [(2 + cos(v)) * sin(u) for u in s, v in s]
Zs = [sin(v) for u in s, v in s]
```

| matplotlib archetype | PlotlySupply | Gallery |
|---|---|---|
| 1x2 log-log convergence with custom log ticks and a hand-built legend | `sf = subplots(1, 2; sync = false); plot_scatter!(sf, h, errs; row = 1, col = 1, xscale = "log", yscale = "log", xticks = :decades, mode = "lines+markers", legend = ["p=1", "p=2", "p=3"]); plot_scatter!(sf, h, errs; row = 1, col = 2, xscale = "log", yscale = "log", legend = ["a", "b", "c"]); set_legend!(sf; position = :outside_bottom, ncols = 3)` | [`chama_a1_eigenvalue_study`](gallery.md#chama_a1_eigenvalue_study) |
| log-x curves, open and filled markers, shared-y panels, legend on top, slope reference with text | `sf = subplots(1, 2; sync = false, shared_yaxes = true); plot_scatter!(sf, h, errs; row = 1, col = 1, xscale = "log", marker_color = ["none", "white", "black"], mode = "lines+markers", legend = ["a", "b", "c"]); slope_guide!(sf, 2; row = 1, col = 1, x = (h[end], h[1]), through = (h[3], errs[2][3]), label = "2"); set_legend!(sf; position = :outside_top)` | [`chama_a2_infsup`](gallery.md#chama_a2_infsup) |
| solid markers plus `x` markers for partial-load points, log x | `plot_scatter(h, errs[1]; xscale = "log", mode = "lines+markers", marker_symbol = "circle", legend = "converged"); fig = plot_scatter(h, errs[1]; xscale = "log", mode = "markers", marker_symbol = "x", legend = "partial")` | [`chama_a3_partial_load`](gallery.md#chama_a3_partial_load) |
| many lines: linestyle encodes mesh, colour encodes method, mixed legend from proxy handles | `fig = plot_scatter(x, [y, 2 .* y, y .+ 1, 2 .* y .+ 1]; color = ["#b33c38", "#b33c38", "#245e9c", "#245e9c"], dash = ["solid", "dash", "solid", "dash"], legend = ["A/coarse", "A/fine", "B/coarse", "B/fine"]); legend_entry!(fig, "method"; color = "gray")` | [`chama_a4_load_paths`](gallery.md#chama_a4_load_paths) |
| `PolyCollection` of an FEM mesh coloured by cell value, 1x3 panels, ONE shared colorbar | `sf = subplots(1, 3; sync = false); for c in 1:3; plot_polygons!(sf, px, py, c .* pv; row = 1, col = c, edgecolor = "black", crange = (0, 4)); end; shared_colorbar!(sf; title = "\|u\|")` | [`chama_a5_deformed_meshes`](gallery.md#chama_a5_deformed_meshes) |
| mesh field map plus an adjacent line plot, colorbar bound to one axes | `sf = subplots(1, 2; sync = false, width_ratios = [2, 1]); plot_polygons!(sf, px, py, pv; row = 1, col = 1, colorbar_title = "u"); plot_scatter!(sf, x, y; row = 1, col = 2)` | [`chama_a6_map_and_curves`](gallery.md#chama_a6_map_and_curves) |
| `Poly3DCollection` of a hex-mesh exterior, 1x3 with a common colorbar and `view_init` | `sf = subplots(1, 3; sync = false, specs = fill(Spec(kind = "scene"), 1, 3)); for c in 1:3; plot_polygons3d!(sf, vx, vy, vz, faces, c .* fv; row = 1, col = c); view!(sf; row = 1, col = c, elev = 25, azim = -60); end; shared_colorbar!(sf; title = "u")` | [`chama_a7_hex_surfaces`](gallery.md#chama_a7_hex_surfaces) |
| single-colour 3-D block with a text label at a 3-D point | `fig = plot_polygons3d(vx, vy, vz, faces, fv; colorscale = "Blues", showscale = false, crange = (0, 2)); annotate!(fig, 0.5, 0.5, 0.5, "C")` | [`chama_a8_geometry_sketch`](gallery.md#chama_a8_geometry_sketch) |
| torus with a diverging map, faint wireframe of the reference mesh, top-down camera, colorbar axes | `fig = plot_surface(Zt, Yt, Zs; colorscale = "RdBu_r", cmid = 0); plot_wireframe!(fig, Zt, Yt, Zs; opacity = 0.2, color = "gray"); view!(fig; elev = 90, azim = -90, projection = "orthographic"); colorbar!(fig; title = "u", len = 0.6)` | [`chama_a9_torus_ghost_mesh`](gallery.md#chama_a9_torus_ghost_mesh) |
| 3-D parametric surface coloured by a facecolor array, axes off, `text2D`, standalone colorbar | `fig = plot_surface(Zt, Yt, Zs; surfacecolor = Zs, colorscale = "viridis"); scene!(fig; showaxis = false); annotate!(fig, 0.05, 0.95, "(a)"; coords = :axes, showarrow = false)` | [`topo_response`](gallery.md#topo_response) |
| 3-D mesh with per-polygon colours (cut planes) | `fig = plot_mesh3d(vx, vy, vz; i = [0, 0, 0, 1], j = [1, 2, 3, 2], k = [2, 3, 1, 3], intensity = fv, intensitymode = "cell", edges = true); fig2 = plot_polygons3d(vx, vy, vz, faces, fv)` | [`topo_cutplanes`](gallery.md#topo_cutplanes) |
| tetrahedron with `quiver` basis arrows and a custom `Arrow3D` | `fig = plot_polygons3d(vx, vy, vz, faces, fv; opacity = 0.4); plot_quiver3d!(fig, vx, vy, vz, vy, vz, vx; style = :arrow, color = "black")` | [`topo_whitney`](gallery.md#topo_whitney) |
| analytic response surface with markers and 3-D curves, plus a 2-D ellipse companion | `sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "xy")]); plot_surface!(sf, Zt, Yt, Zs; row = 1, col = 1, colorscale = "viridis"); plot_scatter3d!(sf, [0.0, 1], [0.0, 1], [0.0, 1]; row = 1, col = 1, marker_symbol = "o", marker_color = "none", marker_line_color = "black"); plot_scatter!(sf, cos.(s), 0.5 .* sin.(s); row = 1, col = 2)` | [`topo_response`](gallery.md#topo_response) |
| dashboard: scatter strips with multi-line `annotate`, curve overlay, `suptitle`, footnote | `fig = plot_scatter(x, y; mode = "markers", title = "Comparison"); annotate!(fig, 0.5, 0.4, "peak\nvalue"; offset = (20, 20)); annotate!(fig, 0.5, 0.01, "Source: simulation"; coords = :figure, showarrow = false, anchor = :bottom)` | [`optical_dots`](gallery.md#optical_dots) |
| print fitting and vector export: `figsize`, `dpi`, EPS, `metadata={"CreationDate": None}` | `fig = with_style(:ieee) do; plot_scatter(x, y; xlabel = "\$x\$"); end; savefig(fig, "arch.pdf"; width = 3.5, height = 2.5, units = :in)` | [`journal_export`](gallery.md#journal_export) |
| shaded min/max band with bounding lines and a dashed secondary curve | `fig = plot_band(x, lo, hi; color = "#0072B2", opacity = 0.2, legend = "range"); plot_scatter!(fig, x, y; legend = "mean"); plot_scatter!(fig, x, hi; dash = "dash", legend = "bound")` | [`band_quasimodes`](gallery.md#band_quasimodes) |
| theory line against hollow-marker data points, limit line | `fig = plot_scatter(x, y; legend = "theory"); plot_scatter!(fig, x[1:3:end], y[1:3:end]; mode = "markers", marker_color = "none", marker_line_width = 1.5, legend = "data"); hline!(fig, 0.0; dash = "dot")` | [`mdd_theory_vs_data`](gallery.md#mdd_theory_vs_data) |
| schematic from patches, `FancyArrowPatch` and text on an axis-off equal-aspect axes | `fig = plot_scatter(Float64[], Float64[]; xrange = (0, 10), yrange = (0, 4), equalar = true); rectangle!(fig, 1, 1, 4, 3; rounded = 0.2, label = "A"); arrow!(fig, 4, 2, 6, 2; text = "beam", offset = (0, 10)); circle!(fig, 8, 2, 1); annotate!(fig, 8, 3.4, "ring"; showarrow = false); axis_off!(fig)` | [`mdd_schematic`](gallery.md#mdd_schematic), [`block_diagram`](gallery.md#block_diagram) |
| `pcolormesh` on a polar-to-Cartesian mesh, mirrored to a full disk, circle overlays | `fig = plot_pcolormesh(X, Y, C; colorscale = "magma", equalar = true); plot_pcolormesh!(fig, -X, Y, C; colorscale = "magma", showscale = false, equalar = true); circle!(fig, 0, 0, 1.5; edgecolor = "white")` | [`mdd_shell_field`](gallery.md#mdd_shell_field) |
| `tripcolor` with Gouraud shading and a mask, white outlines, colorbar | `fig = plot_tripcolor(tx, ty, tri, tv; shading = :gouraud, colorscale = "viridis"); plot_triplot!(fig, tx, ty, tri; color = "white", linewidth = 1)` | [`tripcolor_geometry`](gallery.md#tripcolor_geometry) |
| complex-plane scatter of poles with per-point offset labels, filled and hollow markers | `z = [0.5 + 0.5im, -0.5 + 0.2im, 0.1 - 0.8im]; fig = plot_complex(z; mode = "markers", marker_color = ["black", "none", "black"], unit_circle = true); annotate!(fig, 0.5, 0.5, "p1"; offset = (10, 10))` | [`poles_scatter`](gallery.md#poles_scatter) |
| `markevery` sparse markers plus `axhline` limit lines on log-log | `fig = plot_scatter(h, errs[2]; xscale = "log", yscale = "log", mode = "lines+markers", markevery = 2); hline!(fig, 1e-3; dash = "dash")` | [`mdd_convergence_band`](gallery.md#mdd_convergence_band) |
| 2x2 composite (field map, trajectories, two convergence panels) with panel-letter titles | `sf = subplots(2, 2; sync = false); plot_heatmap!(sf, x, x, U; row = 1, col = 1); plot_scatter!(sf, y, x; row = 1, col = 2); plot_scatter!(sf, h, errs; row = 2, col = 1, xscale = "log", yscale = "log"); plot_scatter!(sf, x, y; row = 2, col = 2); panel_labels!(sf)` | [`mdd_shell_field`](gallery.md#mdd_shell_field) |
| scientific-notation offset text on the axis | `fig = plot_scatter(x, 1e7 .* x); yticks!(fig; offset = :auto)` | [`mesh_timeseries_strip`](gallery.md#mesh_timeseries_strip) |
| single curve with a star extrapolation marker | `fig = plot_scatter(x, y; legend = "fit"); plot_scatter!(fig, [1.2], [0.3]; mode = "markers", marker_symbol = "star", marker_size = 12, legend = "limit")` | [`endpoint_star`](gallery.md#endpoint_star) |
| stacked `pcolormesh` maps with a white contour outline and one shared vertical colorbar | `sf = subplots(2, 1; sync = false); for r in 1:2; plot_heatmap!(sf, x, x, r .* U; row = r, col = 1, colorscale = "inferno"); plot_contour!(sf, x, x, U; row = r, col = 1, levels = [0.0], coloring = "none", linecolor = "white"); end; shared_colorbar!(sf; title = "\|E\|^2")` | [`field_maps`](gallery.md#field_maps), [`fig4_waveguide`](gallery.md#fig4_waveguide) |
| side-by-side parameter-space heatmaps, `sharey`, one colorbar | `sf = subplots(1, 3; sync = false, shared_yaxes = true); for c in 1:3; plot_heatmap!(sf, x, x, c .* U; row = 1, col = c, colorscale = "magma"); end; shared_colorbar!(sf)` | [`param_heatmaps`](gallery.md#param_heatmaps) |
| line plots with distinct linestyles, hand-placed panel letters, frameless legends | `sf = subplots(1, 2; sync = false); plot_scatter!(sf, x, ys; row = 1, col = 1, dash = ["solid", "dash"], legend = ["a", "b"]); plot_scatter!(sf, x, ys; row = 1, col = 2); panel_labels!(sf); set_legend!(sf; frame = false)` | [`mdd_regimes`](gallery.md#mdd_regimes) |
| optimization history on a log y axis with fading alpha, scatter with categorical x ticks | `fig = plot_scatter(1:20, [10.0 .^ (-0.1 .* (1:20)) .* k for k in (1, 2, 3)]; yscale = "log", opacity = [0.3, 0.6, 1.0]); fig2 = plot_scatter(["a", "b", "c"], [1.0, 2.0, 1.5]; mode = "markers")` | [`optimization_history`](gallery.md#optimization_history) |
| grouped bars on a log y axis with custom ticks, plus a power-versus-channel line | `fig = plot_bar(["a", "b", "c"], [[1.0, 10, 100], [2.0, 20, 50]]; yscale = "log", yrange = (0.5, 200), yticks = [1, 10, 100], legend = ["x", "y"])` | [`log_bars`](gallery.md#log_bars) |
| ratio curves with a marker ladder, hand-built `Line2D` legend, `fillstyle` full versus none | `fig = plot_scatter(x, ys; mode = "lines+markers", marker_color = ["none", "black"], legend = ["open", "filled"]); legend_entry!(fig, "proxy"; color = "gray", dash = "dash")` | [`mdd_convergence_band`](gallery.md#mdd_convergence_band) |
| ECDF/step curves, white-edged markers, `vlines` tick strips, `LogLocator(subs)` | `fig = plot_ecdf(randn(100); legend = "ECDF"); plot_vlines!(fig, [-1.0, 0.0, 1.0], 0, 0.05; color = "black"); fig2 = plot_scatter(h, errs[1]; xscale = "log", marker_line_color = "white", mode = "markers"); xticks!(fig2; subs = (1, 2, 5))` | [`optical_ecdf`](gallery.md#optical_ecdf) |
| converged-fraction curves with a sequential colour ramp and a band spanning two rows | `cols = colormap_colors("viridis", 3); sf = subplots(2, 2; sync = false, specs = [Spec() Spec(rowspan = 2); Spec() missing]); plot_scatter!(sf, x, [y, 2 .* y, 3 .* y]; row = 1, col = 1, color = cols); plot_band!(sf, x, lo, hi; row = 1, col = 2)` | [`optical_reach`](gallery.md#optical_reach) |
| pixel-pattern `imshow` with a `ListedColormap`, `Rectangle` cells and wavevector arrows | `fig = plot_heatmap(x, x, round.(U); colorscale = discrete_colormap(["#ffffff", "#444444", "#0072B2"]), showscale = false); rectangle!(fig, 0.2, 0.2, 0.6, 0.6; edgecolor = "white"); arrow!(fig, 0.5, 0.5, 0.8, 0.8)` | [`optical_pixelmap`](gallery.md#optical_pixelmap) |
| `imshow` with dashed and solid white outlines, bilinear map plus contour, `LogNorm` matrix with outlined cells | `fig = plot_heatmap(x, x, U; colorscale = "cividis", interpolation = :bilinear); rectangle!(fig, 0.2, 0.2, 0.6, 0.6; edgecolor = "white", dash = "dash", fillcolor = "rgba(0,0,0,0)"); fig2 = plot_heatmap(1:4, 1:4, abs.(U[1:4, 1:4]) .+ 1e-3; colornorm = :log)` | [`optical_cividis`](gallery.md#optical_cividis) |
| horizontal bars on a log x axis with value labels (for `orientation = "h"` the values come first), stacked vertical bars | `fig = plot_bar([1.0, 10, 100], ["a", "b", "c"]; orientation = "h", xscale = "log", xrange = (0.5, 200), text = ["1", "10", "100"], textposition = "outside"); fig2 = plot_bar(["p", "q"], [[1.0, 2], [3.0, 1]]; barmode = "stack")` | [`optical_bars`](gallery.md#optical_bars) |
| log-log data plus a reference line, `axhspan` tolerance bands, `axvline` thresholds, secondary x axis | `fig = plot_scatter(h, errs[2]; xscale = "log", yscale = "log", mode = "markers"); hspan!(fig, 1e-3, 1e-2; opacity = 0.2); vline!(fig, 0.1; dash = "dot"); secondary_xaxis!(fig, v -> 1 / v, v -> 1 / v; title = "1/h")` | [`optical_tolerance`](gallery.md#optical_tolerance) |
| dot comparison on categorical-grouped x positions, filled versus hollow markers | `fig = plot_scatter(["a", "b", "c"], [[1.0, 2, 3], [1.5, 2.5, 2.0]]; mode = "markers", marker_color = ["black", "none"], legend = ["x", "y"])` | [`optical_dots`](gallery.md#optical_dots) |
| annotated `imshow` with per-cell mathtext labels and a colorbar | `fig = plot_matrix([1.0 0.5; 0.5 1.0]; xlabels = ["\$a\$", "\$b\$"], ylabels = ["\$a\$", "\$b\$"], colorbar_title = "\$r\$")` | [`topo_annotated_heatmap`](gallery.md#topo_annotated_heatmap) |
| `pcolormesh` strips with non-uniform edges, log y, categorical ticks | `fig = plot_pcolormesh([0.0, 0.1, 0.4, 1.0], [1.0, 10, 100, 1000], rand(3, 3); yscale = "log", xticks = [0.05, 0.25, 0.7], xticklabels = ["a", "b", "c"])` | [`topo_pcolormesh`](gallery.md#topo_pcolormesh) |
| phase-plane schematic: unit circle fill, arc arrows, leader lines, markers with white edges | `fig = plot_scatter(Float64[], Float64[]; xrange = (-2, 2), yrange = (-2, 2), equalar = true); circle!(fig, 0, 0, 1; fillcolor = "rgba(0,114,178,0.2)"); arc!(fig, 0, 0, 1.4, 20, 100; arrow = :end); annotate!(fig, 1, 0, "fixed point"; xytext = (1.5, 0.8), head = :none); plot_scatter!(fig, [0.0], [0.0]; mode = "markers", marker_line_color = "white", marker_size = 10)` | [`topo_phase`](gallery.md#topo_phase) |
| axes the layout checker measured by hand: tight bounding boxes, `constrained_layout`, `subplots_adjust` | not needed: colorbars, legends, titles and panel labels reserve their own room; `savefig(...; tight = true)` and `tight_layout!(fig)` trim the margins | [`journal_export`](gallery.md#journal_export) |
