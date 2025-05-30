using Pkg, Revise
Pkg.activate(".")

using PlotlySupply

### 1D Line Plot

# fig = plot_scatter(0:0.1:2π, sin.(0:0.1:2π); xlabel="x", ylabel="sin(x)", title="Sine Wave")

# 3D mountain surface
x = -3:0.1:3
y = -3:0.1:3
X = repeat(x', length(y), 1)
Y = repeat(y, 1, length(x))
Z = 3 * (1 .- X).^2 .* exp.(-(X.^2) - (Y .+ 1).^2)
fig = plot_surface(X, Y, Z, title="3D Surface", colorscale="Plasma")

set_template!(fig, "plotly_white")

# fig.plot.layout.template = PlotlyJS.templates.plotly_dark

display(fig)