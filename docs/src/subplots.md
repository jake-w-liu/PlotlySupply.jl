# Subplots

## Grids and the active cell

[`subplots`](@ref)`(rows, cols)` returns a [`SubplotFigure`](@ref). The
`plot_*!` mutators draw into the active cell, or into `row`/`col` (which then
becomes active). [`subplot!`](@ref) selects a cell by `(row, col)` or by
MATLAB's row-major index. `sync = true` (the default) shows the grid in a live
window; `sync = false` builds it without one.

```julia
using PlotlySupply

sf = subplots(2, 2; sync = false, title = "Response", width = 700, height = 500)
plot_scatter!(sf, 0:0.1:10, sin.(0:0.1:10); row = 1, col = 1, legend = "sin")
subplot!(sf, 2)                          # row 1, column 2
plot_bar!(sf, ["a", "b", "c"], [3, 1, 2])
xlabel!(sf, "category")                  # labels the active cell (1, 2)
plot_histogram!(sf, randn(300); row = 2, col = 1)
plot_heatmap!(sf, rand(20, 10); row = 2, col = 2)
```

The axis helpers ([`xlabel!`](@ref), [`xrange!`](@ref), [`xticks!`](@ref),
[`grid!`](@ref), [`spines!`](@ref), ...) act on the active cell unless given
`row`/`col`.

`height_ratios` (top to bottom) and `width_ratios` (left to right) size the
rows and columns. `horizontal_spacing` and `vertical_spacing` are fractions
of the figure. `specs` chooses the cell kinds (`Spec(kind = "scene")`,
`"polar"`, `"map"`, ...) and secondary axes (`Spec(secondary_y = true)`);
`missing` leaves a cell empty.

```julia
sf = subplots(2, 1; sync = false, height_ratios = [3, 1], shared_xaxes = true)
plot_scatter!(sf, 1:100, cumsum(randn(100)); row = 1, col = 1)
plot_bar!(sf, 1:100, abs.(randn(100)); row = 2, col = 1)
xrange!(sf, (0, 101); row = 2, col = 1)   # shared: both rows change
```

With `shared_xaxes`/`shared_yaxes`, a range set on any cell is written to the
axis that owns the shared range, so every cell of the group shows it.

## Insets

[`inset!`](@ref) adds inset axes to a cell and returns their id `k`; the
mutators and axis helpers take `inset = k`. [`remove_inset!`](@ref) deletes
one.

```julia
sf = subplots(1, 1; sync = false)
x = range(0, 10; length = 500)
plot_scatter!(sf, x, sin.(3x) .* exp.(-x ./ 3); legend = "signal")
k = inset!(sf, (0.55, 0.55, 0.4, 0.4))       # (left, bottom, width, height) of the axes
plot_scatter!(sf, x, sin.(3x) .* exp.(-x ./ 3); inset = k, color = "crimson")
xrange!(sf, (0, 2); inset = k)
```

## Twin axes

A cell built with `Spec(secondary_y = true)` takes `secondary_y = true` in the
mutators, [`ylabel!`](@ref), [`yrange!`](@ref) and [`yticks!`](@ref).
[`secondary_xaxis!`](@ref) adds a top axis that shows a transform of the
bottom one (matplotlib `secondary_xaxis`).

```julia
sf = subplots(1, 1; sync = false, specs = fill(Spec(secondary_y = true), 1, 1))
plot_scatter!(sf, 1:10, rand(10); legend = "left")
plot_scatter!(sf, 1:10, 100 .* rand(10); secondary_y = true, legend = "right")
ylabel!(sf, "fraction")
ylabel!(sf, "count"; secondary_y = true)

λ = collect(400.0:5:700.0)
fig = plot_scatter(λ, exp.(-((λ .- 550) ./ 60) .^ 2); xlabel = "wavelength (nm)")
secondary_xaxis!(fig, l -> 299792.458 / l, ν -> 299792.458 / ν; title = "frequency (THz)")
```

## Colorbars

A colour-mapped trace drawn into a cell gets a colorbar next to that cell.
[`colorbar!`](@ref) restyles or moves one (`side = :bottom`, `title`, `ticks`,
...). [`shared_colorbar!`](@ref) binds the colour-mapped traces of several
cells to one colour scale and one bar.

```julia
sf = subplots(1, 3; sync = false, width = 900, height = 300)
for c in 1:3
    plot_heatmap!(sf, c .* rand(20, 20); row = 1, col = c)
end
shared_colorbar!(sf; title = "intensity", colorscale = "viridis")

sf2 = subplots(1, 2; sync = false, horizontal_spacing = 0.15)
plot_heatmap!(sf2, rand(10, 10); row = 1, col = 1)
plot_contour!(sf2, rand(10, 10); row = 1, col = 2)
colorbar!(sf2; row = 1, col = 2, title = "level", side = :bottom)
```

## Legends

Each cell has its own legend by default (`per_subplot_legends = true`).
[`set_legend!`](@ref) with an outside position merges all entries into one
figure legend, dropping duplicates. [`subplot_legends!`](@ref) places every
cell's legend; [`legend_entry!`](@ref) adds a legend-only entry (a proxy
handle).

```julia
sf = subplots(1, 3; sync = false)
for c in 1:3
    plot_scatter!(sf, 1:5, rand(5); legend = "measured", color = "black", row = 1, col = c)
    plot_scatter!(sf, 1:5, rand(5); legend = "model", color = "crimson", dash = "dash",
        row = 1, col = c)
end
set_legend!(sf; position = :outside_bottom, ncols = 2)    # one legend, two entries
```

## Titles and panel labels

[`title!`](@ref) sets the figure title or, with `row`/`col`, a panel title.
[`panel_labels!`](@ref) labels the panels "(a)", "(b)", ... in row-major
order.

```julia
sf = subplots(1, 2; sync = false)
plot_scatter!(sf, 1:3, [1, 4, 9]; row = 1, col = 1)
plot_scatter!(sf, 1:3, [9, 4, 1]; row = 1, col = 2)
title!(sf, "Convergence study"; align = :left, bold = true)
title!(sf, "Mesh, \$h = 0.1\$"; row = 1, col = 1)
title!(sf, "Error"; row = 1, col = 2)
panel_labels!(sf)
```

## Figure-wide settings

Settings that belong to the whole figure (title, size, `barmode`) are not
changed by the per-cell mutators: pass them to `subplots`, or use
[`title!`](@ref), [`figsize!`](@ref) or `relayout!(sf; ...)`. A mutator given
`title`, `width` or `height` in a cell ignores them with a warning.
