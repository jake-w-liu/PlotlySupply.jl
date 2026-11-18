# Lines and markers

## Line and marker plots

[`plot_scatter`](@ref) draws lines, markers or both. `plot_scatter(y)` uses
`x = 0:length(y)-1`. A vector of vectors in `y` draws one series per vector;
`x` is then shared, or nested like `y`.

```julia
using PlotlySupply

x = range(0, 2π; length = 60)
fig = plot_scatter(x, [sin.(x), cos.(x)]; legend = ["sine", "cosine"],
    mode = ["lines", "lines+markers"], dash = ["", "dash"],
    xlabel = "phase (rad)", ylabel = "amplitude")
```

Every per-series keyword takes one value for all series or a vector with one
entry per series: `mode`, `dash`, `color`, `legend`, `linewidth`,
`marker_size`, `marker_symbol`, `marker_color`, `marker_line_color`,
`marker_line_width`, `opacity`, `line_shape`, `fill`, `fillcolor`,
`showlegend`.

- `dash` takes `"solid"`, `"dot"`, `"dash"`, `"longdash"`, `"dashdot"`,
  `"longdashdot"` or a dash-length list such as `"5px,3px"`.
- `marker_symbol` takes plotly names or matplotlib codes (`"o"`, `"s"`, `"D"`,
  `"^"`, ...).
- `marker_color = "white"` or `"none"` draws open markers; the outline takes
  the line colour, and `marker_line_width` sets its width.
- `markevery = k` puts markers on every `k`-th point only; with `text`, every
  label is kept at full strength and its colour is fixed when you call, so a
  later template change does not recolour it.
- `line_shape = "hv"` draws a step plot (matplotlib `step(where="post")`).

```julia
n = 0:40
y = exp.(-n ./ 15)
fig = plot_scatter(n, y; mode = "lines+markers", marker_symbol = "o",
    marker_color = "none", marker_line_width = 1.5, markevery = 5,
    line_shape = "hv", legend = "decay")
```

A series without a `legend` name has no legend entry. Pass
`showlegend = true` to force one.

Add series to an existing figure with [`plot_scatter!`](@ref) (or its short
name [`plot!`](@ref)):

```julia
fig = plot_scatter(1:10, rand(10); legend = "first")
plot_scatter!(fig, 1:10, rand(10); legend = "second", color = "crimson")
```

## Where the legend goes

While the package default position is `:topright`
([`get_default_legend_position`](@ref)), a new figure from `plot_scatter`,
`plot_stem`, `plot_area` and the line family (`plot_band`, `plot_segments`,
`plot_vlines`, `plot_hlines`, `plot_ecdf`, `plot_kde`, `plot_complex`) puts its
legend at the matplotlib "best" candidate that covers the least data. A legend
you place with [`set_legend!`](@ref) is never moved:

```julia
fig = plot_scatter(1:10, (1:10) .^ 2; legend = "squares")
set_legend!(fig; position = :bottomright)
```

## Error bars and bands

`error_y` (and `error_x`) take one magnitude per point, a vector of vectors
for several series, or a `(minus, plus)` tuple for asymmetric bars.
[`plot_band`](@ref) fills between two curves (matplotlib `fill_between`).

```julia
x = 0:0.5:5
y = exp.(-x)
e = 0.1 .* y
fig = plot_band(x, y .- 2e, y .+ 2e; legend = "±2σ", opacity = 0.2)
plot_scatter!(fig, x, y; mode = "markers", error_y = (e, 2e), legend = "data")
```

[`plot_area`](@ref) fills down to zero, or stacks series with `stack = true`.

```julia
fig = plot_area(1:5, [[1, 2, 3, 2, 1], [1, 1, 2, 2, 3]]; stack = true,
    legend = ["a", "b"])
```

## Stems, segments and line collections

[`plot_stem`](@ref) draws a marker at each point and a thin line down to
`baseline`. Each series is two traces: the markers (with the legend entry) and
one trace holding all stems.

```julia
n = 0:20
fig = plot_stem(n, exp.(-n ./ 6) .* cos.(n); legend = "h[n]", xlabel = "\$n\$")
```

[`plot_segments`](@ref) draws many separate segments as one trace (matplotlib
`LineCollection`); [`plot_vlines`](@ref) and [`plot_hlines`](@ref) draw
vertical or horizontal lines between given limits. For a line across the whole
axis use [`vline!`](@ref) and [`hline!`](@ref) (see
[Reference lines and shapes](shapes.md)).

```julia
θ = range(0, π; length = 12)
fig = plot_segments(zeros(12), zeros(12), cos.(θ), sin.(θ); color = "gray",
    equalar = true)
plot_vlines!(fig, [-0.5, 0.5], 0, 0.5; color = "black", dash = "dot")
```

## Complex data

Complex numbers are rejected by the other plot functions; [`plot_complex`](@ref)
draws them in the complex plane with equal axis scales, optionally with the
unit circle:

```julia
z = exp.(2π * im .* (0:7) ./ 8)
fig = plot_complex(z; unit_circle = true, mode = "markers", legend = "8th roots")
```

## Polar plots

[`plot_scatterpolar`](@ref) takes angles in degrees unless
`thetaunit = "radians"`. `trange` draws a sector, `rrange` sets the radial
range, and `direction`/`rotation` orient the angle. The radial tick labels sit
on the 22.5° spoke of a full circle (`rlabel_angle` moves them), and a radial
axis without tick settings gets at most 6 ticks. The Cartesian axis keywords
do not apply to a polar plot.

```julia
θ = range(0, 2π; length = 181)
fig = plot_scatterpolar(θ, 1 .+ cos.(θ); thetaunit = "radians", fill = "toself",
    legend = "cardioid", rotation = 90, direction = "clockwise")
fig2 = plot_scatterpolar(0:5:90, rand(19); trange = [0, 90], rrange = [0, 1])
```

## A second y axis

`secondary_y = true` on a mutator draws on a second y axis on the right,
created on first use; label it with `ylabel!(fig, ...; secondary_y = true)`.

```julia
t = 0:0.1:10
fig = plot_scatter(t, sin.(t); legend = "voltage", ylabel = "V")
plot_scatter!(fig, t, 100 .* cos.(t); legend = "current", secondary_y = true)
ylabel!(fig, "mA"; secondary_y = true)
```

## Line-style cycles

A [`PlotStyle`](@ref) with `cycle = :dash`, `:marker`, `:dash_marker`,
`:dash_symbol` or `:bw` gives each new line-type trace the next dash pattern or marker symbol,
for figures that must read in greyscale. Keywords you pass win over the cycle.
`plot_segments`, `plot_vlines`, `plot_hlines`, `plot_ecdf` and `plot_kde` take
only the width and dash from the style (no markers).

```julia
fig = with_style(PlotStyle(; cycle = :bw, linewidth = 2)) do
    plot_scatter(1:10, [rand(10), rand(10), rand(10)]; legend = ["a", "b", "c"])
end
```
