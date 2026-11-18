# A torus coloured by a signed displacement over a faint wireframe of the reference mesh.
#
# Catalogue: chama-python A9, chama-audit G.
# Replaces: Line3DCollection (ghost edges) under a Poly3DCollection with cmap='coolwarm' and a
#   symmetric clim, view_init(elev=65, azim=-70), a hand-placed colorbar axes.
# 2.0: `scene!` fixes equal axes, `plot_segments3d!` draws the ghost mesh, `plot_polygons3d!` takes a
#   diverging scale with a symmetric `crange`, and `shared_colorbar!` draws the bar.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

R, r = 10.0, 1.0
nφ, nθ = 96, 12
φs = range(0, 2π; length = nφ + 1)[1:end-1]
θs = range(0, 2π; length = nθ + 1)[1:end-1]
id(i, j) = mod(i, nφ) * nθ + mod(j, nθ) + 1
X0 = [(R + r * cos(θ)) * cos(φ) for φ in φs for θ in θs]
Y0 = [(R + r * cos(θ)) * sin(φ) for φ in φs for θ in θs]
Z0 = [r * sin(θ) for φ in φs for θ in θs]
quads = permutedims(reduce(hcat, [[id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1)]
	for i in 0:nφ-1 for j in 0:nθ-1]))
edges = permutedims(reduce(hcat, vcat([[id(i, j), id(i + 1, j)] for i in 0:nφ-1 for j in 0:nθ-1],
	[[id(i, j), id(i, j + 1)] for i in 0:nφ-1 for j in 0:nθ-1])))

pinch(A) = [-A * sin(φ) * exp(-1.6 * cos(φ)^2) for φ in φs for θ in θs]   # u_y of a pinching load
panels = [("Mixed enhanced strain", 5.035), ("Macroelement", 5.145), ("\$Q_1\$ displacement", 1.596)]
facevalue(u) = [sum(u[quads[f, :]]) / 4 for f in axes(quads, 1)]
m = maximum(last, panels)                                     # symmetric limits (-m, m)

fig = with_style(:ieee) do
	sf = subplots(1, 3; sync = false, specs = fill(Spec(kind = "scene"), 1, 3),
		width = journal_width(:ieee; columns = 2, units = :px), height = 260)
	for (c, (name, tip)) in enumerate(panels)
		uy = pinch(tip)
		plot_segments3d!(sf, X0, Y0, Z0, edges; row = 1, col = c, color = "#999999",
			linewidth = 0.5, opacity = 0.35)
		plot_polygons3d!(sf, X0, Y0 .+ uy, Z0, quads, facevalue(uy); row = 1, col = c,
			colorscale = "coolwarm", crange = (-m, m), edgecolor = "", edgewidth = 0)
		scene!(sf; row = 1, col = c, aspectmode = "cube", xrange = (-12, 12), yrange = (-12, 12),
			zrange = (-12, 12))                                 # equal axes, as ax.set_box_aspect
		view!(sf; row = 1, col = c, elev = 65, azim = -70)
		title!(sf, "$name<br>\$-u_y(0,10,0)=$(tip)\$"; row = 1, col = c)
	end
	panel_labels!(sf; labels = :abc, format = "({})")
	shared_colorbar!(sf; title = "signed \$u_y\$", title_side = :right, len = 0.6)
	sf
end
savefig(fig, joinpath(outdir, "chama_a9_torus_ghost_mesh.png"); scale = 2)
