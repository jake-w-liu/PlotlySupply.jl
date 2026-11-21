# Statistical plots

## Bars

[`plot_bar`](@ref) takes positions and values, or values only (positions
`0:n-1`). A vector of vectors draws grouped series; `barmode = "stack"`
stacks them. `orientation = "h"` draws horizontal bars and swaps the roles
(plotly's convention, passed through): the values come first and the
categories second, `plot_bar(values, categories; orientation = "h")`.
Error bars, value labels and hatching are keywords.

```julia
using PlotlySupply

groups = ["A", "B", "C"]
fig = plot_bar(groups, [[3.0, 5.0, 2.0], [2.5, 4.0, 3.5]]; legend = ["2024", "2025"],
    error_y = [[0.3, 0.4, 0.2], [0.2, 0.5, 0.3]], ylabel = "yield (%)")
fig2 = plot_bar(groups, [3.0, 5.0, 2.0]; text = ["3.0", "5.0", "2.0"],
    textposition = "outside", hatch = "//", color = "steelblue")
fig3 = plot_bar([4.0, 2.0, 7.0]; orientation = "h")
```

Bar options:

- A `color`, `hatch` or `barwidth` vector with one entry per bar sets each bar
  of a single series (a vector of any other length is an `ArgumentError`);
  nested series take per-bar vectors per series.
- `barwidth` is in data units of the position axis and does not move the bar
  centres.
- `bargap` and `bargroupgap` (fractions in `[0, 1]`) are figure-wide and apply
  to every cell of a `SubplotFigure`.
- On a logarithmic value axis, bars keep plotly's base 0 and grow from the
  axis bottom (the lower range limit), as in matplotlib. Set `yrange`/`xrange`
  for comparisons, or pass `base`.
- `secondary_y = true` works on `plot_bar!`, `plot_histogram!`, `plot_box!`,
  `plot_violin!` and `plot_histogram2d!` for a `Plot` or `SyncPlot`; the
  y-axis keywords then address the twin. Bars on a twin are positioned
  separately from the primary bars, so they overlap at equal positions (like
  matplotlib's `twinx`): shift the positions and set `barwidth` to put them side
  by side.

```julia
fig = plot_bar(["a", "b", "c"], [3.0, 5.0, 2.0]; color = ["#0072B2", "#D55E00", "#009E73"],
    barwidth = [0.8, 0.5, 0.8], bargap = 0.2)
fig2 = plot_bar([1.0, 10.0, 100.0]; yscale = "log", yrange = (0.5, 200))
```

## Histograms

[`plot_histogram`](@ref) bins samples. `nbinsx` is an approximate bin count
(plotly rounds the bin width); `bins = (start, stop, width)` gives exact bins.
`histnorm` is `""` (counts), `"percent"`, `"probability"`, `"density"` or
`"probability density"`. Several series in one call share their bins and are
overlaid.

```julia
a = randn(500)
b = randn(500) .+ 1
fig = plot_histogram([a, b]; bins = (-4, 5, 0.25), histnorm = "probability density",
    legend = ["control", "treated"], xlabel = "value")
```

On a logarithmic binning axis plotly.js cannot bin, so the samples are counted
in Julia and drawn as bars with bins of equal width in decades:

```julia
sizes = exp.(2 .* randn(1000))
fig = plot_histogram(sizes; xscale = "log", xlabel = "particle size")
```

[`plot_histogram2d`](@ref) counts pairs on a grid and colours the counts
(`colornorm = :log` for counts that span decades). It takes the colour
keywords of the field plots but no `legend`.

```julia
x = randn(2000)
y = x .+ 0.5 .* randn(2000)
fig = plot_histogram2d(x, y; nbinsx = 40, nbinsy = 40, colorscale = "viridis",
    colorbar_title = "count")
```

## Distributions

[`plot_box`](@ref) and [`plot_violin`](@ref) take one vector of samples per
series; each named series sits on its name. The two-argument form follows
plotly: `x` gives the group of every sample. `points` shows the samples
(`"all"`, `"outliers"`, `false`).

The box statistic is plotly.js's `quartilemethod = "linear"` (a Hazen-type
interpolation of the quartiles), not the type-7 rule of numpy and
matplotlib: for `[1, 2, 3, 4, 10]` the box runs from 1.75 to 5.5, where
matplotlib draws 2 to 4. Whiskers end at the most extreme sample within
1.5 times the interquartile range of the box; samples beyond them are
outliers. The classification of the same data as outliers can therefore
differ from matplotlib's `boxplot`. `plot_box` has no `quartilemethod`
keyword; pass `quartilemethod = "exclusive"` or `"inclusive"` through
`update_traces!` to change it.

```julia
data = [randn(100), randn(100) .+ 1, 2 .* randn(100)]
fig = plot_box(data; legend = ["a", "b", "c"], points = "outliers", boxmean = true)
fig2 = plot_violin(data; legend = ["a", "b", "c"], points = false)
fig3 = plot_box(repeat(["low", "high"], 50), randn(100); points = "all")
```

[`plot_ecdf`](@ref) draws the empirical cumulative distribution as a step
line (`complementary = true` for `1 - F`, `stat = :count` for counts), and
[`plot_kde`](@ref) a Gaussian kernel density estimate (`bandwidth` is
`:silverman`, `:scott` or a number).

```julia
s = randn(300)
fig = plot_ecdf(s; legend = "ECDF")
fig2 = plot_kde([s, s .+ 2]; legend = ["a", "b"], bandwidth = :scott, fill = true)
```

## In subplots

The statistical mutators take `row`, `col` and `inset` on a `SubplotFigure`.
`barmode` is a figure-wide plotly setting: passing it in one cell re-arranges
the bars of every cell, with a warning only when another axis pair holds two
or more bar-like traces.

```julia
sf = subplots(1, 2; sync = false)
plot_histogram!(sf, randn(200); row = 1, col = 1, legend = "samples")
plot_box!(sf, [randn(50), randn(50) .+ 1]; row = 1, col = 2)
```
