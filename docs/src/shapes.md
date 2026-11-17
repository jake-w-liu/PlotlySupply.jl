# Reference lines and shapes

All functions on this page add to an existing figure, take `row`, `col` and
`inset` on a `SubplotFigure`, and are additive (calling again adds more).
Coordinates are data values, also on log axes. They return `nothing`, or the
`SubplotFigure`.

## Reference lines and spans

[`hline!`](@ref) and [`vline!`](@ref) draw lines across the whole plot area
(matplotlib `axhline`/`axvline`); [`hspan!`](@ref) and [`vspan!`](@ref) shade
bands (`axhspan`/`axvspan`). `label` writes text at the line, `legend` gives
it a legend entry.

```julia
using PlotlySupply

fig = plot_scatter(1:100, cumsum(randn(100)); legend = "signal")
hline!(fig, 0; dash = "dash", color = "gray")
vline!(fig, [25, 75]; dash = "dot", legend = "events")
vspan!(fig, 40, 60; color = :orange, label = "window", labelpos = :top_center)
hspan!(fig, -2, 2; color = "#cccccc", opacity = 0.3)
```

## Slope markers

[`slope_guide!`](@ref) draws the power law through a point over an interval
(a straight line on log-log axes); [`slope_triangle!`](@ref) draws the
classic slope triangle with run and rise labels. Slopes are in decades on log
axes.

```julia
h = [0.1, 0.05, 0.025, 0.0125]
err = 3 .* h .^ 2 .* (1 .+ 0.1 .* h)
fig = plot_scatter(h, err; mode = "markers", xscale = "log", yscale = "log",
    legend = "error")
slope_guide!(fig, 2; x = (0.0125, 0.1), through = (0.1, 0.02), label = "\$O(h^2)\$")

N = [16, 32, 64, 128]
fig2 = plot_scatter(N, 10.0 .* N .^ -2.0; xscale = "log", yscale = "log")
slope_triangle!(fig2, 32, 5e-3, -2; width = 0.3)
```

## Shapes for schematics

[`circle!`](@ref), [`ellipse!`](@ref), [`rectangle!`](@ref) (with
`rounded` corners), [`polygon!`](@ref), [`arc!`](@ref) and [`arrow!`](@ref)
draw in data units, with `fillcolor`, `edgecolor`, `linewidth`, `dash` and a
`label` inside the shape. `arrow!` takes `head = :end`, `:start` or `:both`.
A circle looks round only with equal axis scales, and circles, ellipses,
arcs and rounded rectangles are not available on log axes (`ArgumentError`).

```julia
fig = plot_scatter(Float64[], Float64[]; xrange = [0, 10], yrange = [0, 4],
    equalar = true)
rectangle!(fig, 1, 1, 4, 3; rounded = 0.3, fillcolor = "#eeeeee", label = "Laser")
rectangle!(fig, 6, 1, 9, 3; label = "Detector")
arrow!(fig, 4, 2, 6, 2; text = "beam")
circle!(fig, 5, 3.5, 0.3; fillcolor = :gold)
arc!(fig, 5, 2, 0.8, 30, 150; arrow = :end)
axis_off!(fig)
```

For free text, use [`annotate!`](@ref) (see [Text and math](text.md)).
