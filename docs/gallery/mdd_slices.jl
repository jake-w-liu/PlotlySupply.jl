# Three horizontal slices of a field in a unit cube, with the cube wireframe and a vector arrow.
#
# Catalogue: math-deepdebug 2 (3-D slice panels with a shared colorbar).
# Replaces: add_subplot(projection='3d'), Poly3DCollection of slice triangles coloured by |u|,
#   Line3DCollection cube edges, ax.quiver, hidden ticks and one external colorbar.
# 2.0: `plot_polygons3d!` takes triangles as well as quads, `plot_segments3d!` the edges,
#   `plot_quiver3d!` the arrow; `shared_colorbar!` gives one bar for the three scenes.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

# Triangulated n x n grid on the slice z = z0; returns nodes, triangles and the field at their centroids.
function slice(z0, n, field)
	node(i, j) = j * (n + 1) + i + 1
	x = [i / n for j in 0:n for i in 0:n]
	y = [j / n for j in 0:n for i in 0:n]
	tris = reduce(vcat, [[node(i, j) node(i + 1, j) node(i + 1, j + 1); node(i, j) node(i + 1, j + 1) node(i, j + 1)]
		for j in 0:n-1 for i in 0:n-1])
	val = [field(sum(x[tris[t, :]]) / 3, sum(y[tris[t, :]]) / 3, z0) for t in axes(tris, 1)]
	return x, y, fill(z0, length(x)), tris, val
end
ring(x, y, z) = 3.0 * exp(-40 * (hypot(x - 0.5, y - 0.45) - 0.28)^2) * (0.55 + 0.45 * sin(π * z)) *
	(0.75 + 0.25 * cos(3 * atan(y - 0.45, x - 0.5)))
fields = [("exact field", ring), ("ordinary space", (x, y, z) -> 0.02 * ring(x, y, z)),
	("enriched space", (x, y, z) -> 0.959 * ring(x, y, z))]
cx, cy, cz = [0, 1, 1, 0, 0, 1, 1, 0], [0, 0, 1, 1, 0, 0, 1, 1], [0, 0, 0, 0, 1, 1, 1, 1]
cube = [1 2; 2 3; 3 4; 4 1; 5 6; 6 7; 7 8; 8 5; 1 5; 2 6; 3 7; 4 8]

fig = with_style(:ieee) do
	sf = subplots(1, 3; sync = false, specs = fill(Spec(kind = "scene"), 1, 3),
		width = journal_width(:ieee; columns = 2, units = :px), height = 240)
	for (c, (name, f)) in enumerate(fields)
		for z0 in (0.2, 0.5, 0.8)
			x, y, z, tris, val = slice(z0, 24, f)
			plot_polygons3d!(sf, x, y, z, tris, val; row = 1, col = c, colorscale = "viridis",
				crange = (0, 3), edgecolor = "")
		end
		plot_segments3d!(sf, cx, cy, cz, cube; row = 1, col = c, color = "#bfbfbf")
		plot_quiver3d!(sf, [0.05], [0.05], [1.0], [0.3], [0.0], [0.0]; row = 1, col = c, style = :arrow,
			color = "#D55E00", linewidth = 4)
		annotate!(sf, 0.4, 0.05, 1.0, "\$\\mathbf{b}\$"; row = 1, col = c, color = "#D55E00", showarrow = false)
		scene!(sf; row = 1, col = c, aspectmode = "cube", xrange = (0, 1), yrange = (0, 1), zrange = (0, 1),
			showticklabels = false, showbackground = false, xlabel = "\$x_1\$", ylabel = "\$x_2\$", zlabel = "\$x_3\$")
		view!(sf; row = 1, col = c, elev = 22, azim = -60)
		title!(sf, name; row = 1, col = c)
	end
	panel_labels!(sf; labels = :abc, format = "({})")
	shared_colorbar!(sf; title = "\$|\\mathbf{u}|\$", title_side = :right, len = 0.7)
	sf
end
savefig(fig, joinpath(outdir, "mdd_slices.png"); scale = 2)
