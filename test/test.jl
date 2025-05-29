using Pkg, Revise
Pkg.activate(".")

using PlotlySupply

### 1D Line Plot

plot_scatter(0:0.1:2π, sin.(0:0.1:2π); xlabel="x", ylabel="sin(x)", title="Sine Wave")


### 2D Heatmap

x = -5:0.1:5
y = -5:0.1:5
U = [sin(sqrt(xi^2 + yj^2)) for yj in y, xi in x]
plot_heatmap(x, y, U; xlabel="x", ylabel="y", title="Radial Sine")