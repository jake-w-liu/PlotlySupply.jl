# Computed curves with hollow reference markers on top and a partial-load cross.
#
# Catalogue: chama-audit B.
# Replaces: ax.plot('-o'), ax.plot('s', mfc='none'), ax.plot('x'), ax.grid(alpha=.2) and
#   ax.legend(loc='lower right') on constrained_layout.
# 2.0: `marker_color = "none"` gives the hollow squares; no legend position is pinned, the
#   default legend avoids the data.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

n = [8, 16, 32]
series = [("Mixed enhanced strain", "#D55E00", [0.17357, 0.17322, 0.17312], [0.17360, 0.17320, 0.17310]),
	("Macro mean log \$J\$", "#0072B2", [0.17418, 0.17330, 0.17313], [0.17420, 0.17335, 0.17312]),
	("\$Q_1\$ displacement", "#000000", [0.13030, 0.13712, 0.14982], [0.13030, 0.13715, 0.14980])]

fig = with_style(:ieee) do
	fig = plot_scatter(Float64[], Float64[]; xlabel = "elements per side \$n\$",
		ylabel = "\$-u_2(0,1)\$", title = "Compression: computed and digitized reference")
	for (name, color, computed, reference) in series
		plot_scatter!(fig, n, computed; mode = "lines+markers", color = color,
			legend = name * " (computed)")
		plot_scatter!(fig, n, reference; mode = "markers", marker_symbol = "square-open",
			marker_size = 9, color = color, legend = name * " (reference)")
	end
	plot_scatter!(fig, [12], [0.1342]; mode = "markers", marker_symbol = "x", marker_size = 9,
		color = "#000000", legend = "\$Q_1\$ displacement (partial load)")
	grid!(fig; alpha = 0.2)
	figsize!(fig, :ieee; columns = 2, aspect = 0.62)
	fig
end
savefig(fig, joinpath(outdir, "audit_b_reference_markers.png"); scale = 2)
