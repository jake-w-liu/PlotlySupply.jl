# Three panels of error and norm curves against a subdivision count, one legend row below.
#
# Catalogue: math-deepdebug 1 (also math-deepdebug "multi-panel semilog/log-log convergence").
# Replaces: ax.plot with a shade, marker and line style per series, set_xscale('log', base=2),
#   per-panel legends, big open circles, a dashed 1/n reference and fig.legend(loc='lower center').
# 2.0: `lighten` makes the shades, per-panel legends come from named traces, the shared legend
#   is built with `legend_entry!` and sits below the panels without tight_layout!.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

n = [4, 6, 8, 12]
regimes = [("\$\\lambda=n\$", 0.62, "circle", "solid"),   # label, white fraction, marker, dash
	("\$\\lambda=100n^{3/2}\$", 0.42, "diamond", "dot"),
	("\$\\lambda=100n^2\$", 0.22, "square", "dash"),
	("\$\\lambda=100n^4\$", 0.0, "triangle-up", "dashdot")]
err_a = [[0.47, 0.32, 0.25, 0.165], [0.60, 0.49, 0.435, 0.38], [0.67, 0.61, 0.585, 0.57], [0.94, 0.97, 0.98, 0.99]]
norm_b = [[0.88, 0.95, 0.97, 0.98], [0.74, 0.82, 0.86, 0.88], [0.64, 0.67, 0.69, 0.71], [0.16, 0.08, 0.046, 0.021]]
err_c = [[0.47, 0.32, 0.25, 0.165], [0.48, 0.33, 0.255, 0.17], [0.50, 0.345, 0.265, 0.178], [0.52, 0.36, 0.275, 0.185]]
grey, blue = "#2b2b2b", "#0072B2"

fig = with_style(:ieee) do
	sf = subplots(1, 3; sync = false, per_subplot_legends = true)
	figsize!(sf, :ieee; columns = 2, aspect = 0.36)
	for (k, (label, w, m, dash)) in enumerate(regimes)
		look = (mode = "lines+markers", marker_symbol = m, dash = dash, xscale = "log")
		plot_scatter!(sf, n, err_a[k]; row = 1, col = 1, color = lighten(grey, w), look...)
		plot_scatter!(sf, n, norm_b[k]; row = 1, col = 2, color = lighten(grey, w), yscale = "log", look...)
		plot_scatter!(sf, n, err_c[k]; row = 1, col = 3, color = lighten(blue, w), yscale = "log", look...)
		legend_entry!(sf, label; mode = "lines+markers", color = lighten(grey, w), marker_symbol = m,
			dash = dash, legend_target = :figure)
	end
	plot_scatter!(sf, [3.6, 13.4], [0.265, 0.265]; row = 1, col = 1, color = "#009E73", dash = "dot",
		legend = "local lower bound")
	plot_scatter!(sf, n, [0.53, 0.37, 0.285, 0.19]; row = 1, col = 3, mode = "markers",
		marker_symbol = "circle-open", marker_size = 12, color = "#E69F00", legend = "discrete limit",
		yscale = "log")
	plot_scatter!(sf, n, 1.65 ./ n; row = 1, col = 3, color = "gray", dash = "dash",
		legend = "\$\\propto n^{-1}\$", yscale = "log")
	yrange!(sf, (0, 1.05); row = 1, col = 1)
	yticks!(sf, :decades; row = 1, col = 2)
	yticks!(sf, [0.1, 0.2, 0.5, 1], ["0.1", "0.2", "0.5", "1"]; row = 1, col = 3, minor = false)
	yrange!(sf, (0.1, 1.6); row = 1, col = 3)
	for c in 1:3
		xticks!(sf, n, string.(n); row = 1, col = c, minor = false)
		xrange!(sf, (3.6, 13.4); row = 1, col = c)
		grid!(sf; which = :major, alpha = 0.3, row = 1, col = c)
		xlabel!(sf, "subdivisions \$n\$"; row = 1, col = c)
	end
	ylabel!(sf, "relative energy error"; row = 1, col = 1)
	ylabel!(sf, "field norm \$\\|u_h\\|/\\|u_\\star\\|\$"; row = 1, col = 2)
	title!(sf, "ordinary space: error"; row = 1, col = 1)
	title!(sf, "ordinary space: field"; row = 1, col = 2)
	title!(sf, "enriched space: error"; row = 1, col = 3)
	panel_labels!(sf; labels = :abc, format = "({})")
	set_legend!(sf; legend_target = :figure, position = :outside_bottom, ncols = 4)
	sf
end
savefig(fig, joinpath(outdir, "mdd_regimes.png"); scale = 2)
