# Two-panel log-log eigenvalue study with one figure legend below the panels.
#
# Catalogue: chama-python A1, chama-audit A.
# Replaces: plt.subplots(1, 2) with set_xscale/set_yscale('log'), LogLocator(subs=(1, 2, 5)),
#   FuncFormatter('{:g}'), Line2D proxy handles and fig.legend(loc='lower center', ncol=4).
# 2.0: named series feed one figure legend, `subs`/`format` give the 1-2-5 ticks and a
#   journal preset sets fonts, line weights and the size.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

n_a = [4, 8, 16, 24, 32]
n_b = [8, 16, 24, 32]
# Colour, dash and marker identify a series in both panels (the style's cycle counts traces
# of the whole figure, so a series that appears twice is given its look explicitly).
series = [   # label, colour, dash, marker, panel (a), panel (b)
	("Mixed enhanced, square", "#0072B2", "solid", "square", [0.135, 0.046, 0.0132, 0.0060, 0.0035], [0.0195, 0.0222, 0.0268, 0.0240]),
	("Macroelement, square", "#D55E00", "dash", "square", [0.39, 0.315, 0.272, 0.257, 0.247], [0.310, 0.272, 0.259, 0.251]),
	("Mixed enhanced, Cook", "#009E73", "dot", "triangle-up", [0.122, 0.037, 0.0101, 0.0046, 0.0026], [0.050, 0.042, 0.031, 0.026]),
	("Macroelement, Cook", "#CC79A7", "dashdot", "triangle-up", [0.80, 0.63, 0.58, 0.55, 0.535], [0.605, 0.535, 0.528, 0.522]),
]

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, per_subplot_legends = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.42)
	for (label, color, dash, marker, ya, yb) in series
		plot_scatter!(sf, n_a, ya; row = 1, col = 1, legend = label, mode = "lines+markers",
			color = color, dash = dash, marker_symbol = marker, xscale = "log", yscale = "log")
		plot_scatter!(sf, n_b, yb; row = 1, col = 2, mode = "lines+markers",
			color = color, dash = dash, marker_symbol = marker, xscale = "log", yscale = "log")
	end
	xticks!(sf, n_a, string.(n_a); row = 1, col = 1)
	xticks!(sf, n_b, string.(n_b); row = 1, col = 2)
	yticks!(sf, :decades; row = 1, col = 1)
	yticks!(sf; subs = (1, 2, 5), format = "~g", row = 1, col = 2)
	xlabel!(sf, "elements per direction \$n\$"; row = 1, col = 1)
	xlabel!(sf, "elements per direction \$n\$"; row = 1, col = 2)
	ylabel!(sf, "smallest eigenvalue \$\\beta_h^2\$"; row = 1, col = 1)
	foreach(c -> grid!(sf; alpha = 0.25, row = 1, col = c), 1:2)
	title!(sf, "Structured meshes"; row = 1, col = 1)
	title!(sf, "Perturbed meshes"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	set_legend!(sf; position = :outside_bottom, legend_target = :figure)
	sf
end
savefig(fig, joinpath(outdir, "chama_a1_eigenvalue_study.png"); scale = 2)
