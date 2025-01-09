# using Pkg, Revise
# Pkg.activate(".")

# # using PlotlySupply

using PlotlyJS

# using MeshGrid
# using Infiltrator

# # Y, X = meshgrid([1,2,3], [1,2])
# # Z = [1 2 3; 4 5 6]
# # # plt = splot(X, Y, Z; xlabel="qq")
# # # plt.plot.layout.scene[:xaxis][:title] = "a"
# # # plt.plot.data[1][:z][6] = 0
# # # react!(plt.plot, plt.plot.data, plt.plot.layout)
# # # redraw!(plt)
# # # display(plt)

# # # x = [2,4,8]
# # # y = [1,3,2]
# # # plt2 = rplot(x, y)
# # # plt2.plot.data[1][:y][2] = 0
# # # react!(plt2.plot, plt2.plot.data, plt2.plot.layout)
# # # display(plt2)

# # trace = surface(x = X, y = Y, z = Z, colorscale = "Jet")
# #     layout = Layout(
# #         scene = attr(
# #             aspectmode = "",
# #             xaxis = attr(title = "xlabel"),
# #             yaxis = attr(title = "ylabel"),
# #             zaxis = attr(title = "zlabel"),
# #         ),

# #         # coloraxis = attr(cmax = maximum(C), cmin = minimum(C)),
# #         # template = :plotly_white,
# #     )

# #   plt = plot(trace, layout)
# # #   plt.plot.layout.scene[:xaxis][:title] = "a"
# # # plt.plot.data[1][:z][6] = 0
# # relayout!(plt, scene = attr(xaxis = attr(title = "a")))


# # display(plt)

# # sleep(1)
# # Z[6] = 0
# # react!(plt.plot, plt.plot.data, plt.plot.layout)

# function test()
#     x = [1, 2, 3]
#     y = [1, 4, 7]
#     tr = scatter(x=x, y=y,)
#     fig = plot(tr)
#     # display(fig)
#     fig.plot.data[1][:y][3] = 0
#     react!(fig.plot, fig.plot.data, fig.plot.layout)
#     display(fig)
#     @infiltrate
#     # display(fig)
# end

# test()

x = [1, 2, 3]
y = [1, 4, 7]
tr = scatter(x=x, y=y,)
fig = plot(tr)

# change data
fig.plot.data[1][:y][3] = 0 # == y[3] = 0
react!(fig.plot, fig.plot.data, fig.plot.layout)
display(fig)