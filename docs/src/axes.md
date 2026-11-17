# Axes and ticks

## Labels and ranges

[`xlabel!`](@ref) and [`ylabel!`](@ref) set axis titles; [`xrange!`](@ref)
and [`yrange!`](@ref) set limits. The `xlabel`, `ylabel`, `xrange` and
`yrange` keywords of the constructors do the same.

Ranges are data values on every axis type, including logarithmic axes (pass
`(1e-3, 1e2)`, never exponents). A reversed range (`hi < lo`) flips the axis.
`[0, 0]`, `(0, 0)` and `nothing` restore automatic ranging. Both bounds are
required: a partial range such as `(0, nothing)`, equal bounds and
non-positive bounds on a log axis raise an `ArgumentError`.

```julia
using PlotlySupply

fig = plot_scatter([1e-3, 1.0, 1e3], [1.0, 2.0, 3.0]; xscale = "log",
    xlabel = "frequency (Hz)", ylabel = "gain")
xrange!(fig, (1e-4, 1e4))     # data units on the log axis
yrange!(fig, (4, 0))          # reversed y axis
xrange!(fig, nothing)         # automatic again
```

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
`:decades`; keep the automatic ticks (or pass values) there. On an axis of
more than eight decades, every k-th decade is labelled.

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
