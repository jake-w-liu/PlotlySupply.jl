# Three orthogonal cut planes through a unit cube in two scenes, one shared colorbar.
#
# Catalogue: topo "3D Poly3DCollection mesh / cut-plane renderings with per-polygon colours".
# Replaces: Poly3DCollection of triangles coloured per face, white cell outlines, a Line3DCollection
#   cube, ticks only at 0 and 1, hidden panes, orthographic view_init(24, -58), one side colorbar.
# 2.0: `plot_polygons3d!` takes a list of triangles with one value each, `coloraxis = :shared` makes
#   one colour scale for both scenes, `view!(projection = "orthographic")`, `colorbar!(coloraxis = :shared)`.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

# |E| of a cavity mode at a point of the unit cube
emag(p) = clamp(hypot(sin(π * p[2]) * sin(π * p[3]), 0.8 * sin(π * p[1]) * sin(π * p[3]),
	0.5 * sin(π * p[1]) * sin(π * p[2])), 0, 1)

# Triangles of the plane `axis` = c on an n x n grid; every triangle takes its centroid value.
function plane_triangles(axis, c, n)
	faces, vals = Matrix{Float64}[], Float64[]
	pt(u, v) = axis == 1 ? [c, u, v] : axis == 2 ? [u, c, v] : [u, v, c]
	h = 1 / n
	for i in 0:n-1, j in 0:n-1
		a, b, cc, d = pt(i * h, j * h), pt((i + 1) * h, j * h), pt((i + 1) * h, (j + 1) * h), pt(i * h, (j + 1) * h)
		for tri in ((a, b, cc), (a, cc, d))
			push!(faces, permutedims(hcat(tri...)))            # 3 x 3, one row per vertex
			push!(vals, emag(sum(tri) ./ 3))
		end
	end
	return faces, vals
end
corners = [(x, y, z) for x in 0:1, y in 0:1, z in 0:1]
edges = [(p, q) for p in corners for q in corners if p < q && sum(abs.(p .- q)) == 1]    # the 12 cube edges

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene")],
		width = journal_width(:ieee; columns = 2, units = :px), height = 250)
	for (k, (n, name)) in enumerate(((2, "coarse field, \$n=2\$"), (8, "refined field, \$n=8\$")))
		faces, vals = Matrix{Float64}[], Float64[]
		for (axis, c) in ((1, 0.47), (2, 0.53), (3, 0.49))
			f, v = plane_triangles(axis, c, 2n)
			append!(faces, f); append!(vals, v)
		end
		plot_polygons3d!(sf, faces, vals; row = 1, col = k, colorscale = "viridis", crange = (0, 1),
			edgecolor = "white", edgewidth = 0.5, coloraxis = :shared)
		plot_segments3d!(sf, [e[1][1] for e in edges], [e[1][2] for e in edges], [e[1][3] for e in edges],
			[e[2][1] for e in edges], [e[2][2] for e in edges], [e[2][3] for e in edges]; row = 1, col = k,
			color = "#89919A")
		scene!(sf; row = 1, col = k, aspectmode = "cube", showbackground = false, showgrid = false,
			xticks = [0, 1], yticks = [1], zticks = [1], xlabel = "\$x\$", ylabel = "\$y\$", zlabel = "\$z\$")
		view!(sf; row = 1, col = k, elev = 24, azim = -58, projection = "orthographic")
		title!(sf, name; row = 1, col = k)
	end
	panel_labels!(sf; labels = :abc, format = "({})")
	colorbar!(sf; coloraxis = :shared, ticks = [0, 0.5, 1], len = 0.5, title = "\$|\\mathbf{E}_h|\$", title_side = :right)
	sf
end
savefig(fig, joinpath(outdir, "topo_cutplanes.png"); scale = 2)
