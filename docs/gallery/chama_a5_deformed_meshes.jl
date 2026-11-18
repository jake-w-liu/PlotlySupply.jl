# Three deformed FEM quad meshes coloured by a cell value, one shared colorbar.
#
# Catalogue: chama-python A5, chama-audit D.
# Replaces: PolyCollection(cmap=, edgecolors='black', linewidths=.25) with set_array/clim,
#   set_aspect('equal'), fig.colorbar(c, ax=list(axes), shrink=.75), two-line mathtext titles.
# 2.0: `plot_polygons!` takes nodes plus a quad connectivity matrix; `shared_colorbar!` draws one
#   bar of the common colour range, 75 % of the panel height; panels keep their aspect.
using PlotlySupply, Statistics

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

# n x n quads of the unit square, deformed by an indentation of strength `a`.
function deformed_square(n, a, bulge)
	node(i, j) = j * (n + 1) + i + 1
	ij = [(i, j) for j in 0:n for i in 0:n]
	uy = [-a * (j / n) * (1 - 0.8 * (i / n)^2) - 0.02 * j / n for (i, j) in ij]
	ux = [bulge * (j / n) * (i / n) * (1 - 0.3 * j / n) for (i, j) in ij]
	x = [i / n for (i, _) in ij] .+ ux
	y = [j / n for (_, j) in ij] .+ uy
	quads = reduce(vcat, [[node(i, j) node(i + 1, j) node(i + 1, j + 1) node(i, j + 1)]
		for j in 0:n-1 for i in 0:n-1])
	cell = [mean(uy[quads[c, :]]) for c in axes(quads, 1)]      # cell value: mean nodal u_2
	return x, y, quads, cell
end

panels = [("Mixed enhanced strain", 0.1732, deformed_square(16, 0.155, 0.17)),
	("Macroelement", 0.1733, deformed_square(16, 0.155, 0.17)),
	("\$Q_1\$ displacement", 0.1372, deformed_square(16, 0.11, 0.14))]
umin = minimum(minimum(p[3][4]) for p in panels)            # one colour range for all panels

fig = with_style(:ieee) do
	sf = subplots(1, 3; sync = false, width = journal_width(:ieee; columns = 2, units = :px), height = 220)
	for (c, (name, tip, (x, y, quads, cell))) in enumerate(panels)
		plot_polygons!(sf, x, y, quads, cell; row = 1, col = c, colorscale = "viridis",
			crange = (umin, 0.0), edgecolor = "black", edgewidth = 0.3, equalar = true,
			xlabel = "\$x_1\$", ylabel = c == 1 ? "\$x_2\$" : "")
		title!(sf, "$name<br>\$-u_2(0,1)=$(tip)\$"; row = 1, col = c)
	end
	panel_labels!(sf; labels = :abc, format = "({})")
	shared_colorbar!(sf; title = "\$u_2\$", title_side = :right, len = 0.75)
	sf
end
savefig(fig, joinpath(outdir, "chama_a5_deformed_meshes.png"); scale = 2)
