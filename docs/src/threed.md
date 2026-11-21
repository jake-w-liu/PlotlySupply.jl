# 3-D plots

## Surfaces and wireframes

[`plot_surface`](@ref) takes `Z[i, j]` at `(X[i], Y[j])`: `X` and `Y` are
vectors of lengths `size(Z, 1)` and `size(Z, 2)`, or matrices of the size of
`Z` (so curvilinear grids work). `edges = true` draws the grid lines on a
uniform grid; [`plot_wireframe`](@ref) draws only the grid lines.

```julia
using PlotlySupply

xs = range(-2, 2; length = 41)
ys = range(-1, 1; length = 21)
Z = [exp(-x^2 - 4y^2) for x in xs, y in ys]
fig = plot_surface(xs, ys, Z; colorscale = "viridis", edges = true,
    xlabel = "\$x_1\$", ylabel = "\$x_2\$", zlabel = "\$f\$", view = (25, -50))
fig2 = plot_wireframe(xs, ys, Z; rstride = 2, cstride = 2, color = "steelblue")
```

`color = "gray"` draws one colour without a colorbar, `surfacecolor` colours
the surface by another array, and `lighting = :flat` turns off the shading.
`shared_coloraxis = true` (or [`shared_colorbar!`](@ref)) puts several
surfaces on one colour scale.

## Points, lines and segments

[`plot_scatter3d`](@ref) draws points and lines (one series per vector in a
vector of vectors). [`plot_segments3d`](@ref) draws unconnected segments, from
end-point lists or from an edge list.

```julia
t = range(0, 4π; length = 200)
fig = plot_scatter3d(cos.(t), sin.(t), t ./ 4π; legend = "helix", linewidth = 3)
x = [0.0, 1, 1, 0]; y = [0.0, 0, 1, 1]; z = zeros(4)
plot_segments3d!(fig, x, y, z, [1 2; 2 3; 3 4; 4 1]; color = "gray", dash = "dash")
```

Markers take the matplotlib codes `o . s D d + P x X` as well as plotly names,
`marker_line_color`/`marker_line_width` for the outline, `markevery = k` for
every `k`-th point, and `marker_color = "none"` for hollow markers (the outline
is then drawn in the series colour).

```julia
fig = plot_scatter3d(cos.(t), sin.(t), t ./ 4π; mode = "lines+markers", markevery = 10,
    marker_symbol = "s", marker_color = "none", marker_line_width = 1.5,
    legend = "helix")
```

With `markevery` on a series that also has lines or text, the markers are a
second trace of that series.

## Meshes and polygons

[`plot_mesh3d`](@ref) draws a triangle mesh (`i`, `j`, `k` 0-based plotly
indices, or an automatic triangulation), optionally coloured by `intensity`
per vertex or face, with `edges = true` for the triangle edges.
[`plot_polygons3d`](@ref) draws planar polygons with one value per face.

```julia
vx = [0.0, 1, 0, 0]; vy = [0.0, 0, 1, 0]; vz = [0.0, 0, 0, 1]
fig = plot_mesh3d(vx, vy, vz; i = [0, 0, 0, 1], j = [1, 2, 3, 2], k = [2, 3, 1, 3],
    intensity = [1.0, 2.0, 3.0, 4.0], intensitymode = "cell", edges = true,
    colorbar_title = "face")
faces = [[1, 2, 3], [1, 2, 4]]
fig2 = plot_polygons3d(vx, vy, vz, faces, [0.5, 1.5]; colorbar_title = "value")
```

## Vector fields and volumes

[`plot_quiver3d`](@ref) draws cones (`style = :cone`, the default; with
`sizemode = "scaled"` the largest cone is sized relative to the point spacing,
so rescaling the whole field, for example a change of units, does not change
the picture; each cone is still proportional to the length of its own vector)
or arrows
(`style = :arrow`). [`plot_isosurface`](@ref), [`plot_volume`](@ref) and
[`plot_streamtube`](@ref) take scattered grid points as flat vectors.

```julia
g = range(-1, 1; length = 5)
px = vec([x for x in g, y in g, z in g])
py = vec([y for x in g, y in g, z in g])
pz = vec([z for x in g, y in g, z in g])
fig = plot_quiver3d(px, py, pz, -py, px, 0.2 .* ones(length(px)); style = :arrow,
    color = "black")
fig2 = plot_isosurface(px, py, pz, px .^ 2 .+ py .^ 2 .+ pz .^ 2;
    isomin = 0.5, isomax = 1.5, surface_count = 2, colorscale = "plasma")
```

## Camera and scene

[`view!`](@ref) points the camera like matplotlib's `view_init(elev, azim)`;
every 3-D function also takes `view = (elev, azim)`. `projection =
"orthographic"` removes the perspective. [`scene!`](@ref) sets the box aspect
(matplotlib `set_box_aspect`), panes, grid and ticks of one scene.

```julia
fig = plot_surface(rand(20, 10))
view!(fig; elev = 20, azim = 30)
scene!(fig; aspectratio = (2, 1, 0.5), showbackground = false, nticks = 4)
view!(fig; elev = 90, azim = -90, projection = "orthographic")   # top view, +y up
```

`view!` and `scene!` return `nothing` for a `Plot` or `SyncPlot` (the figure
changes in place) and the `SubplotFigure` for a grid.

Without `view!` a perspective scene keeps plotly's default viewing direction
at a distance that fits the box, its tick labels and its axis titles into the
cell, and the 3-D functions keep that distance up to date as data is added or
the figure is resized; `savefig` frames the scene again for the export size.
The framing reduces the offsets of tick labels and axis titles from the box
(compact pads, through the patched plotly.js that windows, exports and HTML
files use; a plain PlotlyBase display ignores the pads in
`layout.meta["plotlysupply:gl3d"]` and draws plotly's own, so labels there can
be clipped), so a scene fills its cell, and scenes in cells of the same size
with the same box proportions get the same distance. When the three axis
titles of a scene cannot be kept apart they are drawn as annotations named
`plotlysupply:scene3d:<scene>:title:<x|y|z>`, rotated along the projected
axis, wrapped or set smaller; at a corner shared by two axes one end tick of
the axis with more ticks is dropped (tick values you set are never touched).
A positive `distance` you pass to `view!` (plotly's normalised units, about
2.2 for the default view) is a deliberate camera: it is kept as given and
moves only the camera; the label offsets the automatic framing wrote stay as
they were (they are not fitted again for the new distance, so check that the
labels still fit). A camera set before the scene was ever framed (for
example a `Layout(scene = attr(camera = ...))` passed to `plot`) and an
orthographic scene keep plotly's own offsets. `zoom` divides the distance of
the automatic framing.

In a scene cell smaller than the plot area, axes with automatic ticks get
about one tick per 40 px (2 to 9), raised until two ticks are labelled when
they fit; axes under four ticks long (a single-column figure) get explicit
counts, because WebGL tick counts follow the export scale; `scene!(; nticks)`
or tick values you set are kept.

Titles and tick labels of a 3-D scene are placed by WebGL at fixed pixel
offsets from the box, so a small cell gets a small box (never less than 40 % of
the cell) and the framing keeps every label inside the cell. Known limitations:
in a cell of about 300 x 250 px, three long axis titles can still overlap each
other and the tick labels (shorten them or leave the title out), and two tick
labels at a corner of the box can touch.

## Axis titles and ranges

[`zlabel!`](@ref) and [`zrange!`](@ref) complete [`xlabel!`](@ref) and
[`xrange!`](@ref) for scenes. Scene axis titles and tick labels are drawn by
WebGL, which cannot typeset TeX: `$...$` in them is converted to Unicode and
HTML (`$x_1$` becomes x with a subscript 1, `$\alpha$` becomes α). Figure
titles, legends and annotations are typeset normally.

```julia
fig = plot_surface(rand(10, 10))
zlabel!(fig, "height \$h\$ (m)")
zrange!(fig, (0, 2))
```

A scene with an explicit range is drawn with `aspectmode = "manual"` and the
proportions of the axis spans, because plotly.js ignores ranges in its
automatic aspect modes.

Content outside the scene ranges is hidden, not clipped at the box; widen the
range or filter the data if a surface seems to lose its edge. Line, edge,
arrow and marker colours with an alpha channel (`rgba(...)`, `#RRGGBBAA`) are
drawn opaque, blended over the scene background, as `opacity < 1` already was;
cones keep the alpha in their colour scale.

## In subplots

Scene cells are created with `specs`; the 3-D mutators, `view!` and `scene!`
take `row`/`col`.

```julia
sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene")])
plot_surface!(sf, rand(5, 5); row = 1, col = 1)
plot_surface!(sf, rand(5, 5); row = 1, col = 2)
view!(sf; row = 1, col = 2, elev = 10, azim = 0)
```
