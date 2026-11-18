# Axes and ticks

## Labels and ranges

[`xlabel!`](@ref) and [`ylabel!`](@ref) set axis titles; [`xrange!`](@ref)
and [`yrange!`](@ref) set limits. The `xlabel`, `ylabel`, `xrange` and
`yrange` keywords of the constructors do the same.

Ranges are data values on every axis type, including logarithmic axes (pass
`(1e-3, 1e2)`, never exponents). A reversed range (`hi < lo`) flips the axis.
`[0, 0]`, `(0, 0)`, `nothing` and `(nothing, nothing)` restore automatic
ranging (a reversed axis stays reversed). Equal bounds and non-positive bounds
on a log axis raise an `ArgumentError`.

```julia
using PlotlySupply

fig = plot_scatter([1e-3, 1.0, 1e3], [1.0, 2.0, 3.0]; xscale = "log",
    xlabel = "frequency (Hz)", ylabel = "gain")
xrange!(fig, (1e-4, 1e4))     # data units on the log axis
yrange!(fig, (4, 0))          # reversed y axis
xrange!(fig, nothing)         # automatic again
```

### One-sided limits

`(lo, nothing)` fixes the left or bottom end and lets the other end follow the
data, also data added later; `(nothing, hi)` fixes the right or top end. This
is matplotlib's `set_ylim(bottom = 0)`. The first bound is always the left or
bottom end, so on a reversed axis `(lo, nothing)` fixes the largest value.
The `xrange` and `yrange` keywords of the 2-D constructors and mutators, and
`zrange` of the 3-D ones, take the same forms.

```julia
fig = plot_scatter(1:10, (1:10) .^ 2; legend = "squares")
yrange!(fig, (0, nothing))                   # starts at 0, the top autoranges
plot_scatter!(fig, 1:10, 3 .* (1:10) .^ 2)   # the top follows the new data
xrange!(fig, (nothing, 12))                  # right end fixed at 12

fig2 = plot_scatter([1e-2, 1, 1e3], [1.0, 2.0, 3.0]; xscale = "log", xrange = (1e-3, nothing))
```

- The bound is in data units: positive values on log axes, `Date`/`DateTime`
  (or a `"yyyy-mm-dd[ HH:MM[:SS]]"` string) on date axes, the 0-based position
  on category axes. Anything else raises an `ArgumentError`.
- On an axis tied by an aspect constraint (`equalar = true`, images) and on a
  3-D scene axis plotly.js cannot autorange one end. The open end is then taken
  from the data when the call runs, and does not follow data added later.
- A fixed end beyond all the data on the axis (`yrange!(fig, (nothing, 0))` for
  positive data) raises an `ArgumentError`: nothing would be visible.
- A full range or `nothing` afterwards replaces the one-sided limit.

An explicit range is written with `autorange = false`, so it holds even where
an `autorange` was set before.

## Logarithmic axes

`xscale = "log"` / `yscale = "log"` make an axis logarithmic. Tick labels use
powers of ten (`exponentformat = "power"`). Plotly's automatic log ticks also
label intermediate digits (2, 5) on axes that span fewer than about 4 to 7
decades. The `:decades` preset labels powers of ten only, with unlabelled
minor ticks at 2..9; `:auto` returns to plotly's automatic ticks.

```julia
f = plot_scatter([1e-3, 1e5], [1.0, 2.0]; xscale = "log")
xticks!(f, :decades)
xticks!(f, :auto)
g = plot_scatter(10 .^ (0:0.1:3), 10 .^ (0:0.1:3); xscale = "log", yscale = "log",
    xticks = :decades, yticks = :decades)
```

An axis spanning less than two decades gets only one or two labels with
`:decades`; keep the automatic ticks (or pass values) there. A log axis with no
tick setting of yours follows the style the figure was built under
(`PlotStyle.log_ticks`): under `:default` it keeps plotly's labels, except where
they would collide at the size the figure is drawn (a panel at journal column
width), where every render, `savefig` included, labels decades only until the
labels fit; under `:publication` and the journal presets an axis that spans two
decades or more labels decades only without any call. The figure remembers the
rule of the style it was built under (`layout.meta.plotlysupply.log_ticks`), so
it keeps its tick labels when it is changed or exported outside the
`with_style` block. On an axis of more than eight decades, every k-th decade is
labelled.

For explicit log ticks, [`log_ticks`](@ref) lists `subs` mantissas per decade,
and `xticks!(fig; subs = (1, 2, 5))` uses them over the axis range:

```julia
log_ticks(1e-3, 1; subs = (1, 2, 5))     # [0.001, 0.002, 0.005, 0.01, ..., 1.0]
f = plot_scatter([1e-3, 1e3], [1e-2, 1e4]; xscale = "log", yscale = "log")
yticks!(f; subs = (1, 2, 5), minor = true)
```

## Tick values, labels and format

[`xticks!`](@ref) and [`yticks!`](@ref) take tick values in data units and an
optional label per value. Labels go through mathtext, so TeX works. Without
labels, ticks on a linear axis are printed with the d3 format `"~g"` (0.0025,
16). `format` sets another d3 format, `angle` rotates the labels, `minor`
turns minor ticks on or off, and `direction`, `tickwidth` and `ticklen` style
the marks.

```julia
x = collect(range(0, 2π; length = 100))
fig = plot_scatter(x, sin.(x))
xticks!(fig, [0, π/2, π, 3π/2, 2π], ["\$0\$", "\$\\pi/2\$", "\$\\pi\$", "\$3\\pi/2\$", "\$2\\pi\$"])
yticks!(fig; format = ".1f", minor = true, direction = "inside")
```

The same tick settings are constructor keywords: `xticks`, `xticklabels`,
`xtickformat` (and the `y` forms).

## Date axes

Dates and times (`Date`, `DateTime`) on x make a date axis. Ranges on a date
axis take dates or date strings.

```julia
using Dates
days = Date(2024, 1, 1):Day(1):Date(2024, 3, 31)
fig = plot_scatter(collect(days), cumsum(randn(length(days))); ylabel = "index")
xrange!(fig, (Date(2024, 2, 1), Date(2024, 2, 29)))
xrange!(fig, ("2024-01-15", "2024-02-15"))
```

## Aspect ratio, frame and grid

```julia
fig = plot_scatter(cos.(0:0.1:2π), sin.(0:0.1:2π))
axis_equal!(fig)                         # one x unit as long as one y unit
spines!(fig; style = :open)              # only the left and bottom axis lines
grid!(fig; axis = :y, alpha = 0.3)       # horizontal grid lines only
fig2 = plot_heatmap(rand(10, 10))
axis_off!(fig2)                          # no axes, ticks or grid
```

[`axis_equal!`](@ref), [`axis_off!`](@ref), [`grid!`](@ref) and
[`spines!`](@ref) take `row`, `col` and `inset` on a `SubplotFigure`;
`grid!` and `spines!` also take `cells = :all`.

[`spines!`](@ref) switches single sides (`bottom`, `top`, `left`, `right`),
draws a side only over a data interval (matplotlib's `set_bounds`, a "range
frame") and chooses where the ticks go with `ticks = :mirror`, `:primary` or
`:none`. Lines plotly.js cannot draw as axis lines become shapes named
`plotlysupply:spine:<xy>:<k>`. [`grid!`](@ref) with `which = :major` or
`:minor` changes only that grid; the other kind keeps its state:

```julia
fig = plot_scatter(1:10, (1:10) .^ 2)
spines!(fig; top = false, right = false)       # left and bottom only
spines!(fig; left = (1, 100), bottom = (1, 10)) # range frame: lines only over the data
grid!(fig; axis = :y, which = :minor, alpha = 0.05)
fig2 = plot_scatter(1:10, 1e5 .* (1:10))
xticks!(fig2; direction = :none)               # no tick marks on x
yticks!(fig2; offset = :auto)                  # scientific offset text "×10⁵" above the axis
```

Tick marks cannot cross the axis line: `direction = :both` and `:inout` raise an
`ArgumentError` (plotly.js has no crossing ticks). `offset = :auto` (or a
power `k`, or `:none`) moves a common scientific exponent into an annotation
named `plotlysupply:offset:<ref>`; it works on linear axes.

## Insets

[`inset!`](@ref) places a small axes inside a cell. With `coords = :data` the
box is given in the host's data units, which needs a fixed host range
(`xrange!`/`yrange!`) or a field's tight range; `fontsize` sets the inset's
tick labels (default: the host's tick size divided by 1.2). The frame and tick
colours of an inset follow the template.

```julia
sf = subplots(1, 1; sync = false)
x = range(0, 10; length = 400)
plot_scatter!(sf, x, sin.(2x) .* exp.(-x ./ 5); legend = "signal")
xrange!(sf, (0, 10)); yrange!(sf, (-1, 1))
k = inset!(sf, (5, 0.3, 4, 0.6); coords = :data, fontsize = 8)   # x 5..9, y 0.3..0.9
plot_scatter!(sf, x, sin.(2x) .* exp.(-x ./ 5); inset = k, color = "crimson")
xrange!(sf, (2, 3); inset = k)
```

[`secondary_xaxis!`](@ref) takes the template's ink colour when the primary
axis sets none.
