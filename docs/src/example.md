# Examples

## `plot_scatter`

```julia
# Simple line plot
x = 1:10
y = x.^2
fig = plot_scatter(x, y, xlabel="X", ylabel="Y²", title="Quadratic Function")


# Multiple lines with different styles
y1 = sin.(x)
y2 = cos.(x)
fig = plot_scatter(x, [y1, y2], 
                   mode=["lines", "lines"], 
                   dash=["", "dash"],
                   color=["blue", "red"],
                   legend=["sin(x)", "cos(x)"])
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_scatter.html" width="700" height="500"></iframe>
<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_scatter2.html" width="700" height="500"></iframe>

## `plot_stem`

```julia
# Discrete signal visualization
n = 0:10
signal = [1, 0, -1, 0, 1, 0, -1, 0, 1, 0, -1]
fig = plot_stem(n, signal, xlabel="Sample", ylabel="Amplitude")
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_stem.html" width="700" height="500"></iframe>

## `plot_scatterpolar`

```julia
# Polar rose pattern
theta = 0:1:360
r = 3 .* sind.(4 * theta)
fig = plot_scatterpolar(theta, r, title="Rose Pattern")
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_scatterpolar.html" width="700" height="500"></iframe>

## `plot_heatmap`

```julia
# Gaussian distribution heatmap
x = -8:0.1:8
y = -5:0.1:5
Y, X = meshgrid(y, x)  # uses Meshgrid.jl
Z = exp.(-(X.^2 + Y.^2))
fig = plot_heatmap(x, y, Z, title="2D Gaussian", colorscale="Viridis", equalar=true)
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_heatmap.html" width="700" height="500"></iframe>


## `plot_quiver`

```julia
# Vector field visualization
x = -2:0.5:2
y = -2:0.5:2
Y, X = meshgrid(y, x)  # uses Meshgrid.jl
U = -Y[:]
V = X[:]
fig = plot_quiver(X[:], Y[:], U, V, sizeref = 0.5, title="Circulation Field")
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_quiver.html" width="700" height="500"></iframe>


## `plot_surface`

```julia
# 3D mountain surface
x = -3:0.1:3
y = -3:0.1:3
Y, X = meshgrid(y, x)  # uses Meshgrid.jl
Z = 3 * (1 .- X).^2 .* exp.(-(X.^2) - (Y .+ 1).^2)
fig = plot_surface(X, Y, Z, title="3D Surface", colorscale="Plasma")
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_surface.html" width="700" height="500"></iframe>


## `plot_scatter3d`

```julia
# 3D parametric curve
t = 0:0.1:4π
x = cos.(t)
y = sin.(t)
z = t
fig = plot_scatter3d(x, y, z, mode="lines", title="3D Helix")
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_surface.html" width="700" height="500"></iframe>


## `plot_quiver3d`

```julia
# 3D magnetic field visualization
x = [-1, 0, 1]
y = [0, 0, 0]
z = [0, 0, 0]
u = [1, 0, -1]
v = [0, 1, 0]
w = [0, 0, 1]
fig = plot_quiver3d(x, y, z, u, v, w, sizeref=0.5, title="3D Vector Field")
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_quiver3d.html" width="700" height="500"></iframe>


## `set_template!`

```julia
fig = plot_scatter(1:10, (1:10).^2)
set_template!(fig, :plotly_dark)
```

<iframe src="https://jake-w-liu.github.io/assets/img/PlotlySupply/fig_template.html" width="700" height="500"></iframe>

