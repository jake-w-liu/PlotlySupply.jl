using Pkg, Revise
Pkg.activate(".")

using PlotlySupply

# plot_scatter(1:3, 4:6, title = "dd", height =400, width = 400)

# plot_surface([1 3 5; 2 4 6])

# plot_scatter3d([[1,2,3], [1,2,3]], [[4,5,6], [8,10, 12]], [[7,8,9], [14,16,18]], legend = ["a", "b"], perspective = false)

# plot_heatmap([1 3 5; 2 4 6], width = 800, height = 800);

# plot_quiver([0, 1], [0, 1], [0, 1], [1, -1]; xrange = [-1, 2])
# plot_quiver([0, 1], [0, 1], [0, 1], [1, -1]; xrange = [0, 2], yrange = [0, 1], width = 800, height = 500)
plot_quiver([0, 1], [0, 1], [0, 1], [1, -1]; xrange = [0, 2], yrange = [0, 4], width = 300, height = 500, grid = false)

# plot_heatmap([0,1e-6], [0,1e-6,2e-6], [1 3 5; 2 4 6]);