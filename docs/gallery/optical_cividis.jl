# Cividis maps with outlined holes and one colorbar, a smoothed error map, a log-scaled matrix.
#
# Catalogue: optical "imshow heatmaps (cividis) with dashed/solid white rectangle outlines, bilinear
#   map + contour + parametric polygon overlay, LogNorm matrix with outlined cells".
# Replaces: imshow(origin='lower', extent=...), Rectangle outlines, interpolation='bilinear',
#   ax.contour(levels=[10]), LogNorm(1e-4, 1), group labels placed with annotate(xycoords=axes).
# 2.0: `equalar = true`, `interpolation = :bilinear`, `colornorm = :log`, a SHARED colorbar for
#   the first row, and the group labels as a second tick-label row (`secondary_xaxis!(side = :bottom)`).
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
orange, dark = "#E69F00", "#202020"

x, y = range(0, 6; length = 121), range(0, 1.8; length = 37)
holes = ((0.2, 0.2, 0.6, 0.8), (0.2, 1.2, 0.6, 1.8), (0.8, 0.6, 1.4, 1.4), (2.2, 0.6, 2.8, 1.4))
fa = [0.05 * exp(-((xi - 3)^2 + (yi - 0.9)^2)) for xi in x, yi in y]
fb = [0.45 * (1 + sin(3xi + 2yi) * cos(5yi - xi)) for xi in x, yi in y]
g = range(-0.3, 0.3; length = 31)
E = [2 + 15 * (a^2 + 1.5b^2) / 0.09 for a in g, b in g]
K = [10.0^(-3.2 + 0.6 * sin(7i + 3j)) for i in 1:22, j in 1:4]    # synthetic |K| matrix, no random numbers
K[17, 2], K[15, 3] = 0.9, 1.0
t = range(0, 2π; length = 21)

fig = with_style(:aps) do
	sf = subplots(2, 2; sync = false)
	figsize!(sf, :aps; columns = 2, aspect = 0.75)
	for (c, F, dash) in ((1, fa, "dot"), (2, fb, "solid"))
		plot_heatmap!(sf, x, y, F; row = 1, col = c, colorscale = "cividis", crange = (0, maximum(fb)), equalar = true)
		foreach(h -> rectangle!(sf, h...; row = 1, col = c, edgecolor = "white", dash = dash), holes)
		xlabel!(sf, "x (\$\\mu\$m)"; row = 1, col = c)
	end
	ylabel!(sf, "y (\$\\mu\$m)"; row = 1, col = 1)
	shared_colorbar!(sf; cells = [(1, 1), (1, 2)], title = "\$|u_{1+}u_{2-}-u_{1-}u_{2+}|\$", title_side = :right)
	plot_heatmap!(sf, g, g, E; row = 2, col = 1, colorscale = "cividis", crange = (0, maximum(E)),
		interpolation = :bilinear, equalar = true, colorbar_title = "\$e_K\$ (%)")
	plot_contour!(sf, g, g, E; row = 2, col = 1, levels = [10.0], linecolor = "white")
	plot_scatter!(sf, 0.5 .* cos.(t) .* 0.5, 0.2 .* sin.(t) .+ 0.01; row = 2, col = 1, color = dark,
		mode = "lines+markers", dash = "solid", marker_size = 3, showlegend = false)
	xlabel!(sf, "detuning of input 2 (%)"; row = 2, col = 1)
	ylabel!(sf, "detuning of input 1 (%)"; row = 2, col = 1)
	plot_heatmap!(sf, 1:22, 1:4, K; row = 2, col = 2, colorscale = "cividis", colornorm = :log, crange = (1e-4, 1),
		colorbar_title = "\$|K|/\\eta_\\tau\$", equalar = false, origin = :upper)
	foreach(ij -> rectangle!(sf, ij[1] - 0.45, ij[2] - 0.5, ij[1] + 0.45, ij[2] + 0.5; row = 2, col = 2,
		edgecolor = orange), ((17, 2), (15, 3)))
	vline!(sf, 11.5; row = 2, col = 2, color = "white", linewidth = 2)
	xticks!(sf, [2, 4, 6, 8, 10, 13, 15, 17, 19, 21], string.([-4, -2, 0, 2, 4, -4, -2, 0, 2, 4]); row = 2, col = 2)
	yticks!(sf, 1:4, ["(+,+)", "(+,-)", "(-,+)", "(-,-)"]; row = 2, col = 2)
	secondary_xaxis!(sf, identity, identity; row = 2, col = 2, side = :bottom, ticks = [6, 17],
		ticklabels = ["backward (L)", "forward (R)"], title = "generated order")
	ylabel!(sf, "input pair"; row = 2, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "optical_cividis.png"); scale = 2)
