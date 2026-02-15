using Pkg
Pkg.activate(".")
using PlotlySupply

x = 1:10
y = rand(10)
fig = plot_scatter(x, y)
savefig(fig, "scatter_plot.pdf")
