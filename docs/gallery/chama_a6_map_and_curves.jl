# A deformed-mesh field map beside a curve panel, the colorbar bound to the map only.
#
# Catalogue: chama-python A6.
# Replaces: fig.add_subplot(121/122), PolyCollection with clim at the 95th percentile,
#   fig.colorbar(c, ax=ax1, shrink=.85), unequal panel widths in constrained_layout.
# 2.0: `width_ratios`, a cell colorbar (`colorbar!(...; row, col)`) that stays inside its own
#   cell, and `xticks = :decades` for the curve panel.
using PlotlySupply, Statistics

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

# Deformed 8 x 32 cantilever: nodes and 1-based, counter-clockwise quads.
nx, ny = 8, 32
ij = [(i, j) for j in 0:ny for i in 0:nx]
θ = [0.55 * (j / ny)^2 for (_, j) in ij]
xs = [0.25 * i / nx * cos(t) + 0.30 * (j / ny)^2.2 for ((i, j), t) in zip(ij, θ)]
ys = [(j / ny) * (1 - 0.06 * j / ny) - 0.25 * i / nx * sin(t) for ((i, j), t) in zip(ij, θ)]
node(i, j) = j * (nx + 1) + i + 1
cells = reduce(vcat, [[node(i, j) node(i + 1, j) node(i + 1, j + 1) node(i, j + 1)]
	for j in 0:ny-1 for i in 0:nx-1])
cy = [mean(ys[cells[c, :]]) for c in axes(cells, 1)]
cx = [mean(xs[cells[c, :]]) for c in axes(cells, 1)]
s = 13 .* (1 .- cy) .^ 2 .* (0.6 .+ 0.8 .* abs.(cx .- 0.12 .- 0.3 .* cy .^ 2) ./ 0.25) .+ 0.4

Ξ = 10.0 .^ (0:6)
curves = [("Mixed enhanced strain", [0.347, 0.298, 0.283, 0.278, 0.264, 0.221, 0.152]),
	("Macroelement", [0.366, 0.334, 0.323, 0.3215, 0.3214, 0.3214, 0.3214]),
	("\$Q_1\$ displacement", [0.338, 0.260, 0.119, 0.034, 0.0205, 0.019, 0.0188])]

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, width_ratios = [1, 1.3],
		width = journal_width(:ieee; columns = 2, units = :px), height = 270)
	plot_polygons!(sf, xs, ys, cells, s; row = 1, col = 1, colorscale = "viridis",
		crange = (0, quantile(s, 0.95)), edgecolor = "black", edgewidth = 0.3, equalar = true,
		xlabel = "\$x_1\$", ylabel = "\$x_2\$", grid = false)
	colorbar!(sf; row = 1, col = 1, title = "\$s_{\\mathrm{plot}}\$", title_side = :right, len = 0.85)
	for (label, u) in curves
		plot_scatter!(sf, Ξ, u; row = 1, col = 2, mode = "lines+markers", legend = label,
			xscale = "log", xticks = :decades, xlabel = "\$\\Xi=\\lambda/\\mu\$", ylabel = "\$u_1(0.125,1)\$")
	end
	grid!(sf; alpha = 0.2, row = 1, col = 2)
	title!(sf, "\$s_{\\mathrm{plot}}\$ from \$\\mathbf{I}+\\nabla\\mathbf{u}_h\$<br>\$8\\times32\$ mesh"; row = 1, col = 1)
	title!(sf, "\$4\\times16\$ mesh, \$E\$ fixed"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "chama_a6_map_and_curves.png"); scale = 2)
