# Examples

Short, complete examples for the most used functions. Each runs as written
after `using PlotlySupply`; add `show = true` to a constructor, or call
`display(fig)`, to see the figure in a window, or export it with
[`savefig`](@ref).

## Lines

```julia
using PlotlySupply

x = 1:10
fig = plot_scatter(x, x .^ 2; xlabel = "\$x\$", ylabel = "\$x^2\$",
    title = "Quadratic function")

fig2 = plot_scatter(x, [sin.(x), cos.(x)]; mode = ["lines+markers", "lines"],
    dash = ["solid", "dash"], color = ["blue", "red"],
    legend = ["\$\\sin x\$", "\$\\cos x\$"])
plot_scatter!(fig2, x, 0.5 .* sin.(x); color = "gray", legend = "half")
```

## Discrete signal

```julia
n = 0:10
signal = [1, 0, -1, 0, 1, 0, -1, 0, 1, 0, -1]
fig = plot_stem(n, signal; xlabel = "sample", ylabel = "amplitude")
```

## Polar rose

```julia
θ = 0:1:360
r = 3 .* abs.(sind.(4 .* θ))
fig = plot_scatterpolar(θ, r; title = "Rose")
```

## Gaussian field with overlays

`meshgrid(y, x)` returns `Y, X` of size `(length(x), length(y))`, the
`U[ix, iy]` layout the field functions expect.

```julia
x = -5:0.1:5
y = -3:0.1:3
Y, X = meshgrid(y, x)
U = exp.(-(X .^ 2 .+ Y .^ 2) ./ 4)
fig = plot_heatmap(x, y, U; colorscale = "viridis", equalar = true,
    colorbar_title = "\$u\$", title = "Gaussian")
θ = range(0, 2π; length = 100)
plot_scatter!(fig, 2 .* cos.(θ), 2 .* sin.(θ); color = "red", legend = "\$r = 2\$")
plot_scatter!(fig, [-4, 4], [-2, 2]; dash = "dash", color = "white", legend = "cut")
set_legend!(fig; position = :topleft)
```

## Radial sine contour

```julia
x = -5:0.1:5
y = -5:0.1:5
U = [sin(hypot(xi, yj)) for xi in x, yj in y]
fig = plot_contour(x, y, U; colorscale = "RdBu_r", cmid = 0, equalar = true,
    title = "Radial sine")
```

## Circulation field

```julia
x = -2:0.5:2
y = -2:0.5:2
Y, X = meshgrid(y, x)
fig = plot_quiver(vec(X), vec(Y), -vec(Y), vec(X); sizeref = 0.5,
    legend = "circulation")
```

## Surfaces

```julia
x = -3:0.1:3
y = -3:0.1:3
Y, X = meshgrid(y, x)
Z = 3 .* (1 .- X) .^ 2 .* exp.(-(X .^ 2) .- (Y .+ 1) .^ 2)
fig = plot_surface(X, Y, Z; colorscale = "plasma", title = "Surface")

Z1 = sin.(hypot.(X, Y))
Z2 = 0.5 .* cos.(hypot.(X, Y)) .+ 2
fig2 = plot_surface(X, Y, Z1; xlabel = "x", ylabel = "y", zlabel = "z")
plot_surface!(fig2, X, Y, Z2; shared_coloraxis = true)
```

## Helix and 3-D vectors

```julia
t = 0:0.1:4π
fig = plot_scatter3d(cos.(t), sin.(t), t; title = "Helix")

fig2 = plot_quiver3d([-1, 0, 1], [0, 0, 0], [0, 0, 0], [1, 0, -1], [0, 1, 0],
    [0, 0, 1]; sizeref = 0.5, title = "3-D vectors")
```

## Dark template

```julia
fig = plot_scatter(1:10, (1:10) .^ 2; legend = "squares")
set_template!(fig, "plotly_dark")
```
