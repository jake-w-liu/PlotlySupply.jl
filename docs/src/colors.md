# Colours

## Colormap names

Every `colorscale` keyword resolves names through [`COLORMAPS`](@ref) in
matplotlib orientation: `"RdBu"` runs from dark red (low) to dark blue (high),
`"Blues"` from white to dark blue. Lookup is case-insensitive and a `"_r"`
suffix reverses a map. The built-in names are

- perceptual: `viridis`, `plasma`, `inferno`, `magma`, `cividis`, `turbo`,
  `twilight`;
- diverging: `coolwarm`, `seismic`, `bwr`, `RdBu`, `PuOr`, `RdYlBu`,
  `Spectral`, `PiYG`, `PRGn`, `RdGy`, `BrBG`;
- sequential: `Blues`, `Greys`, `Reds`, `Greens`, `Oranges`, `Purples`,
  `YlGnBu`, `YlOrRd`;
- classic: `hot`, `jet`, `rainbow`, `gray`, `grey`.

The plotly.js built-ins `Bluered`, `Picnic`, `Portland`, `Electric`,
`Blackbody`, `Earth` and ColorSchemes.jl scheme names also work. An unknown
name raises an `ArgumentError` with suggestions. A `colorscale` may also be a
vector of colours, a vector of `(t, colour)` stops, or a `ColorScheme`.

```julia
using PlotlySupply

colormap("RdBu")[1]          # (0.0, "#67001F"): dark red at the low end
colormap("RdBu_r")[1]        # (0.0, "#053061"): reversed
fig = plot_heatmap(randn(30, 20); colorscale = "RdBu_r", cmid = 0)
```

Register a map of your own by adding it to the table:

```julia
PlotlySupply.COLORMAPS["ice"] = ["#000033", "#3366cc", "#ffffff"]
fig = plot_heatmap(rand(10, 10); colorscale = "ice_r")
```

## Sampling colours

[`colormap`](@ref) returns the `(t, colour)` stops of a map (resampled with
`n`), [`colormap_colors`](@ref) samples `n` colours, e.g. for a family of
lines, [`discrete_colormap`](@ref) builds a stepped map from a list of colours
(matplotlib `ListedColormap`), and [`lighten`](@ref) mixes a colour towards
white.

```julia
cols = colormap_colors("viridis", 4; range = (0.1, 0.9))
fig = plot_scatter(1:10, [rand(10) for _ in 1:4]; color = cols,
    legend = ["a", "b", "c", "d"])
bands = discrete_colormap(colormap_colors("viridis", 5))
fig2 = plot_heatmap(rand(20, 20); colorscale = bands)
lighten("#0072B2", 0.7)      # pale version for a band behind a line
```

## Colour limits and norms

- `crange = [lo, hi]` fixes the colour limits (`[0, 0]` is automatic).
- `cmid = 0` centres a diverging map on a value (matplotlib `TwoSlopeNorm`
  with a symmetric range).
- `colornorm = :log` maps log10 of the data, with decade ticks on the colorbar
  (matplotlib `LogNorm`).
- `levels = [b0, b1, ..., bk]` draws `k` discrete colour bands between the
  boundaries (matplotlib `BoundaryNorm`).

```julia
x = range(1, 5; length = 50)
y = range(1, 3; length = 30)
P = [10.0^(x - y) for x in x, y in y]
fig = plot_heatmap(x, y, P; colornorm = :log, colorbar_title = "power")
fig2 = plot_heatmap(x, y, log10.(P); levels = [-2, -1, 0, 1, 2, 3, 4],
    colorscale = "viridis")
```

## Colorbars

The colorbar keywords of the field functions are `showscale`,
`colorbar_title`, `colorbar_title_side` (`:top`, `:right`, `:bottom`),
`colorbar_ticks` and `colorbar_ticklabels`. Math in a colorbar title is
drawn as an annotation next to the bar. [`colorbar!`](@ref) changes the bar
of an existing figure or cell (length, thickness, position, ticks, number
format), and [`shared_colorbar!`](@ref) gives several panels one scale and
one bar (see [Subplots](subplots.md)). Traces with the same `coloraxis`
share a colour scale.

```julia
fig = plot_heatmap(rand(20, 20); colorbar_title = "\$|E|\$ (V/m)",
    colorbar_title_side = :right)
colorbar!(fig; len = 0.6, thickness = 15, ticks = [0, 0.5, 1],
    ticklabels = ["low", "mid", "high"])
```

## Colour cycles

The trace colours come from the template's `colorway`. The `:publication`
style uses the Okabe–Ito palette, which stays distinguishable for the common
forms of colour blindness. A [`PlotStyle`](@ref) takes any palette from
`PlotlyBase.colors` (`:okabe_ito`, `:tab10`, `:tol_bright`, ...) or a list of
colours as `colorway`, and `cycle = :bw` draws all lines in black with a dash
cycle.

```julia
fig = with_style(PlotStyle(; colorway = :tol_bright)) do
    plot_scatter(1:10, [rand(10) for _ in 1:3]; legend = ["a", "b", "c"])
end
```
