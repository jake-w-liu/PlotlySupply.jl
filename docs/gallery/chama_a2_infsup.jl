# Inf-sup study: filled versus open markers, shared y axis, O(h^2) guide, legend on top.
#
# Catalogue: chama-python A2.
# Replaces: plt.subplots(1, 2, sharey=True), loglog with mfc='white' markers, ax.text('$O(h^2)$')
#   on a two-point reference line, minorticks_off, fig.legend(loc='upper center', ncol=2).
# 2.0: `marker_color = "white"` makes the open markers, `slope_guide!` draws and labels the
#   reference slope, `:outside_top` stacks the legend above the panel titles.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

n = [4, 8, 16, 24, 32]
blue, red = "#0072B2", "#D55E00"
data = [   # label, colour, open?, marker, panel (a), panel (b)
	("macroelement, square", blue, false, "circle", [0.39, 0.315, 0.272, 0.257, 0.247], [0.305, 0.268, 0.255, 0.247]),
	("mixed enhanced, square", red, true, "circle", [0.135, 0.047, 0.0133, 0.0061, 0.0035], [0.019, 0.022, 0.0265, 0.0235]),
	("macroelement, Cook", blue, false, "triangle-up", [0.80, 0.63, 0.58, 0.55, 0.535], [0.63, 0.55, 0.535, 0.525]),
	("mixed enhanced, Cook", red, true, "triangle-up", [0.122, 0.037, 0.0101, 0.0046, 0.0026], [0.050, 0.042, 0.032, 0.026]),
]

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, shared_yaxes = true, per_subplot_legends = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.5)
	for (label, color, open, marker, ya, yb) in data, (col, ns, y) in ((1, n, ya), (2, n[2:end], yb))
		plot_scatter!(sf, ns, y; row = 1, col = col, color = color, mode = "lines+markers", marker_symbol = marker, marker_size = 7,
			marker_color = open ? "white" : color, xscale = "log", yscale = "log",
			(col == 1 ? (legend = label,) : NamedTuple())...)
	end
	for (col, ns) in ((1, n), (2, n[2:end]))
		xticks!(sf, ns, string.(ns); row = 1, col = col, minor = false)
		xlabel!(sf, "\$n\$  (mesh of \$n\\times n\$ elements)"; row = 1, col = col)
		grid!(sf; which = :major, alpha = 0.3, row = 1, col = col)
	end
	yrange!(sf, (1e-3, 1.2); row = 1, col = 1)
	yticks!(sf, :decades; row = 1, col = 1)
	ylabel!(sf, "\$\\beta_h^2\$"; row = 1, col = 1)
	# O(h^2) guide: y = 0.03 (4/n)^2 from n = 4 to 32, labelled in the plot.
	slope_guide!(sf, -2; x = (4, 32), through = (4, 0.03), color = "gray", dash = "solid",
		label = "\$O(h^2)\$", labelpos = :mid, row = 1, col = 1)
	title!(sf, "structured meshes"; row = 1, col = 1)
	title!(sf, "perturbed meshes"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	set_legend!(sf; position = :outside_top, ncols = 2, legend_target = :figure)
	sf
end
savefig(fig, joinpath(outdir, "chama_a2_infsup.png"); scale = 2)
