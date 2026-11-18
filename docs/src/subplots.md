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

### Shared axes act as a group

With `shared_xaxes`/`shared_yaxes` the axes of a column or row form a group.
What you set on any cell applies to the whole group: the axis type (linear or
log), tick placement and format, tick font and angle, and a range or
one-sided limit (written on the axis that owns the shared range). This holds
for the keywords, the axis helpers, `update_xaxes!`/`update_yaxes!` and a
`relayout!` or `update!` that names a group axis. Secondary y axes are
excluded.

- An axis title set on a cell whose tick labels are hidden goes to the cell
  that shows the labels (x: the bottom cell of the column, y: the left cell of
  the row). Calls that only style a title (`set_fonts!`, `title_font`) never
  move it; it moves only when the call sets its text.
- An inset that shares a cell's axis keeps its own tick font and angle.
- Grid titles (`subplot_titles`, `column_titles`, `row_titles`, `x_title`,
  `y_title`) are named annotations (`plotlysupply:title:<row>:<col>`, column and row
  titles `plotlysupply:title!:<row>:<col>:column` / `:row`,
  `plotlysupply:x_title`, `plotlysupply:y_title`), so `title!(sf, text; row,
  col)` replaces one instead of adding a second. They go through mathtext
  (`$...$` works, an unbalanced `$` is an error), follow the active style's
  title size, and `set_fonts!(sf; title = ...)` restyles them.
  `column_titles` and `row_titles` need one string per column or row. plotly.py
  puts `column_titles` and the top row's `subplot_titles` at the same place, so
  give one or the other.

```julia
sf = subplots(2, 2; sync = false, shared_xaxes = true, shared_yaxes = true,
    column_titles = ["\$\\alpha = 1\$", "\$\\alpha = 2\$"])
for r in 1:2, c in 1:2
    plot_scatter!(sf, 1:5, rand(5); row = r, col = c)
end
xrange!(sf, (1, 10); row = 1, col = 1)        # the whole shared column changes
xlabel!(sf, "\$x\$"; row = 1, col = 1)         # the label goes to the bottom cell
```

Whole-figure verbs (`relayout!`, `restyle!`, `update!`, `purge!`, `figsize!`,
...) reject the cell keywords `row`, `col`, `secondary_y` and `inset`; `add_hline!`,
`add_vline!`, `add_hrect!`, `add_vrect!`, `add_shape!`, `add_layout_image!` and
`add_recession_bands!` take them, and `hline!`, `vline!` and the shape helpers
do the same on a `SubplotFigure`.

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

`colorbar!` details:

- `len` is a paper fraction centred on the cell; `len = 0` (the default) is
  the cell's extent and follows it. A call with `len` keeps the layout
  engine's placement; only `x` or `y` take the bar out of its hands.
- `side` defaults to `:right`: calling `colorbar!` without `side` on a bottom
  bar moves it back to the right, so pass `side = :bottom` again.
- A vertical bar is never drawn shorter than three lines of tick labels plus a
  title above or below it (at most the plot height); a shorter `len` is
  raised to that.
- A math (`$...$`) title is an annotation next to the bar; it follows later
  `colorbar!` moves, but not `relayout!` edits of the bar.
- In `shared_colorbar!`, an explicit `crange` is the colour limit of every
  bound trace, and `cmid` inside it builds a two-slope colour scale.

## Room for decorations

A colorbar, an outside legend, a panel title, a panel label and a secondary
x axis each get their own room, taken from the cell they belong to or from the
figure margin, never from a neighbouring cell. The rules:

- A cell gives up room on the side where its decorations need more than the
  gap to the next cell holds: its plot area shrinks, and the cells that share
  that grid edge shrink alike, by at most two thirds of a cell. At the edge of
  the figure the margin grows instead. A bottom colorbar sits below the x tick
  labels and the x title.
- Above a cell the stack is, from the axes upwards: the secondary x axis, a
  legend placed above the axes, the panel title; a panel label sits at the
  left on the title's line (beside the corner of an aligned title, above the
  axes without one).
- A figure that already fits is not changed. Domains, legend positions and
  colorbar `x`/`y` that you set yourself always win, and the result is
  idempotent: repeating a call, or exporting, gives the same layout. The
  domains the engine narrows are recorded in `layout.meta["plotlysupply:room"]`
  (area => `[x0, x1, y0, y1]`): a domain equal to its record is given back when
  the room is no longer needed, any other narrowed domain is yours and is kept
  (a `meta` that is not a dictionary switches the record off).
- Equal-aspect cells place their titles, panel labels and corner legends on the
  fitted plot box, not on the cell.
- Sizes are estimated from the figure size in pixels (`layout.width`, else
  700), the font sizes and the text lengths, generously, and the layout is
  fitted again on the copy that `savefig` exports at its real size. Set the
  size first (`figsize!`, or `width`/`height`): a layout fitted at a
  smaller size keeps the room it asked for.
- Known limits: a bottom bar released because its cell's domain is yours is not
  re-placed later; after you relayout a y domain a bar keeps its old `len`
  until the next `colorbar!` call; equal-aspect cells in one row can end up
  slightly different in height when only one of them narrows for a bar.
- Overlays on a field (quiver, streamlines, scatter) widen the field's tight
  axes only where their anchor points lie outside the field, by 2.5 % of the
  span; arrow parts beyond the frame are clipped.

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

Where the default legend goes: while the default position is `:topright`, a
cell legend moves to the position that covers the least data (matplotlib's
`loc = "best"`) each time traces are appended to the cell. This applies to
the line and marker families, band and fill traces, secondary y axes, polar
cells and insets. A legend placed with `set_legend!` or `relayout!` stays
put; setting another default position turns the rule off. When no position is
free, the one that covers least is taken (a legend wider than its cell can
cross data). Cells with other trace types, category or date coordinates keep
the top right.

`set_legend!(...; ncols = k)` lays the entries out in `k` columns (as
legend groups named `plotlysupply:col:...`, so clicking an entry toggles that
entry only); columns that do not fit the cell are reduced with a warning.
`title_side = :top` puts the legend title above the entries like matplotlib;
plotly.js also indents the entries by the title width for `:top_left`. A
cell legend above or below its axes may reach over the gap to the next cell
or into the figure margin.
Widths are estimated at `layout.width` (else 700 px); if the export is
narrower, plotly grows the margin. A cell legend wider than its cell (long
labels) overflows it even in one column, and a position that equals the rule's
choice still follows the data. A legend you place inside a cell is kept even
when it is taller or wider than the plot area: it overflows, and the engine asks
for no room for it (room taken from the cell would shrink the plot and make the
overflow worse), so use `ncols`, a smaller `fontsize` or an outside position. A figure legend taller than the plot area
(a long legend above a small panel in a short figure) is clipped by plotly
with a scrollbar in a window; a `tight = true` export shows it whole.

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
