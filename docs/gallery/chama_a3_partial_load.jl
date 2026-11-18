# Converged points with lines, unconverged points as crosses, on a log x axis.
#
# Catalogue: chama-python A3.
# Replaces: ax.plot(x, y, '-o') plus ax.plot(x, y, 'x'), set_xscale('log'), FuncFormatter decade
#   labels and ax.legend(bbox_to_anchor=...) pinned inside the axes.
# 2.0: `xticks = :decades` labels powers of ten; the default legend position avoids the data,
#   so nothing is pinned.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

Ξ = 10.0 .^ (0:6)
methods = [   # label, colour, u_1, converged?
	("Mixed enhanced strain", "#D55E00", [0.347, 0.298, 0.283, 0.278, 0.264, 0.221, 0.152], [true, true, true, true, true, false, false]),
	("Macroelement", "#0072B2", [0.366, 0.334, 0.323, 0.3215, 0.3214, 0.3214, 0.3214], trues(7)),
	("\$Q_1\$ displacement", "#000000", [0.338, 0.260, 0.119, 0.034, 0.0205, 0.019, 0.0188], trues(7)),
]

fig = with_style(:ieee) do
	fig = plot_scatter(Float64[], Float64[]; xscale = "log", xticks = :decades,
		xlabel = "\$\\Xi=\\lambda/\\mu\$", ylabel = "\$u_1(0.125,1)\$",
		title = "\$4\\times16\$ mesh, \$E\$ fixed")
	for (label, color, u, ok) in methods
		plot_scatter!(fig, Ξ[ok], u[ok]; mode = "lines+markers", marker_symbol = "circle",
			color = color, legend = label)
		any(.!ok) && plot_scatter!(fig, Ξ[.!ok], u[.!ok]; mode = "markers",
			marker_symbol = "x", marker_size = 9, color = color, legend = label * " (partial load)")
	end
	grid!(fig; alpha = 0.2)
	set_legend!(fig; position = :outside_bottom)
	figsize!(fig, :ieee; columns = 1, aspect = 1.0)
	fig
end
savefig(fig, joinpath(outdir, "chama_a3_partial_load.png"); scale = 2)
