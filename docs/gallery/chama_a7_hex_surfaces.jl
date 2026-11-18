# Exterior faces of three deformed hexahedral meshes, coloured by a displacement, one colorbar.
#
# Catalogue: chama-python A7, chama-audit E.
# Replaces: fig.add_subplot(1, 3, i, projection='3d'), Poly3DCollection(cmap=, edgecolors=)
#   with set_array/clim, view_init(elev=20, azim=-65), set_box_aspect, MaxNLocator(nbins=3),
#   fig.colorbar(coll, ax=axes, shrink=.65).
# 2.0: scene cells (`Spec(kind = "scene")`), `plot_polygons3d!` with a quad face matrix,
#   `view!` for the camera and `shared_colorbar!`; the scenes are framed to fill their cells.
using PlotlySupply, Statistics

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

# Exterior quads of an nx*ny*nz hex block [0,a]x[0,a]x[0,1], bent in x by `bend z^2`.
function bent_block(nx, ny, nz, a, bend)
	id(i, j, k) = (k * (ny + 1) + j) * (nx + 1) + i + 1
	nodes = [(i, j, k) for k in 0:nz for j in 0:ny for i in 0:nx]
	ux = [bend * (k / nz)^2 * (1 - 0.15 * a * j / ny) for (_, j, k) in nodes]
	X = [a * i / nx for (i, _, _) in nodes] .+ ux
	Y = [a * j / ny for (_, j, _) in nodes]
	Z = [k / nz - 0.175 * bend * (k / nz)^3 for (_, _, k) in nodes]
	faces = Vector{Int}[]
	for k in 0:nz-1, j in 0:ny-1                       # x = 0 and x = a
		push!(faces, [id(0, j, k), id(0, j, k + 1), id(0, j + 1, k + 1), id(0, j + 1, k)])
		push!(faces, [id(nx, j, k), id(nx, j + 1, k), id(nx, j + 1, k + 1), id(nx, j, k + 1)])
	end
	for k in 0:nz-1, i in 0:nx-1                       # y = 0 and y = a
		push!(faces, [id(i, 0, k), id(i + 1, 0, k), id(i + 1, 0, k + 1), id(i, 0, k + 1)])
		push!(faces, [id(i, ny, k), id(i, ny, k + 1), id(i + 1, ny, k + 1), id(i + 1, ny, k)])
	end
	for j in 0:ny-1, i in 0:nx-1                       # z = 0 and z = 1
		push!(faces, [id(i, j, 0), id(i, j + 1, 0), id(i + 1, j + 1, 0), id(i + 1, j, 0)])
		push!(faces, [id(i, j, nz), id(i + 1, j, nz), id(i + 1, j + 1, nz), id(i, j + 1, nz)])
	end
	F = permutedims(reduce(hcat, faces))
	return X, Y, Z, F, [mean(ux[F[f, :]]) for f in axes(F, 1)]
end

panels = [("Mixed enhanced strain", bent_block(4, 4, 8, 0.25, 0.40)),
	("Macroelement", bent_block(4, 4, 8, 0.25, 0.47)),
	("\$Q_1\$ displacement", bent_block(4, 4, 8, 0.25, 0.065))]
crange = (0.0, maximum(maximum(p[2][5]) for p in panels))    # common colour range

fig = with_style(:ieee) do
	sf = subplots(1, 3; sync = false, specs = fill(Spec(kind = "scene"), 1, 3),
		width = journal_width(:ieee; columns = 2, units = :px), height = 250)
	for (c, (name, (X, Y, Z, F, val))) in enumerate(panels)
		plot_polygons3d!(sf, X, Y, Z, F, val; row = 1, col = c, colorscale = "viridis",
			crange = crange, edgecolor = "black", edgewidth = 0.5,
			xlabel = "x", ylabel = "y", zlabel = "z")
		scene!(sf; row = 1, col = c, aspectmode = "cube", xrange = (-0.15, 0.85),
			yrange = (-0.375, 0.625), zrange = (0, 1), nticks = 3)     # the same box in every panel
		view!(sf; row = 1, col = c, elev = 20, azim = -65)
		title!(sf, name; row = 1, col = c)
	end
	panel_labels!(sf; labels = :abc, format = "({})")
	shared_colorbar!(sf; title = "\$u_x\$", title_side = :right, len = 0.65)
	sf
end
savefig(fig, joinpath(outdir, "chama_a7_hex_surfaces.png"); scale = 2)
