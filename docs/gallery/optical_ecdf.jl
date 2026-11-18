# Quantile curves with outlined stars, a step ECDF with a tick strip, and residuals on a semilog axis.
#
# Catalogue: optical "ECDF/step curves, markers with white edges, vlines tick strips, LogLocator
#   subs + FuncFormatter".
# Replaces: loglog with '*'/'X' markers edged white, ax.step(where='post') with ax.vlines below
#   y = 0, LogLocator(subs=(1, 3)) with '{:g}' labels and a figure legend above all panels.
# 2.0: `plot_ecdf!`, `plot_vlines!`, `yticks!(subs = (1, 3), format = "~g")` and one figure legend.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
navy, teal, orange, purple = "#0072B2", "#009E73", "#D55E00", "#CC79A7"

q = exp10.(range(-2, 0; length = 40))
# lognormal-like samples on a fixed grid of normal scores (no random numbers: reproducible)
z = collect(range(-2, 2; length = 40))
samples = [2 .* exp.(0.6 .* z), 3.5 .* exp.(0.5 .* (z .+ 0.15 .* sin.(5 .* z)))]
n = 1:8

fig = with_style(:ieee) do
	sf = subplots(1, 3; sync = false, per_subplot_legends = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.4)
	for (k, (c, name)) in enumerate(((navy, "two frequencies"), (orange, "three frequencies")))
		plot_scatter!(sf, q, q .^ (0.8 + 0.25k); row = 1, col = 1, color = c, xscale = "log", yscale = "log",
			xticks = :decades, yticks = :decades, legend = name, dash = "solid")
	end
	plot_scatter!(sf, [0.05, 0.3], [0.03, 0.2]; row = 1, col = 1, mode = "markers", marker_symbol = "star",
		marker_size = 10, color = teal, legend = "selected")
	plot_scatter!(sf, [0.02, 0.6], [0.004, 0.4]; row = 1, col = 1, mode = "markers", marker_symbol = "x",
		marker_size = 8, color = purple, legend = "rejected")
	xlabel!(sf, "quantile level"; row = 1, col = 1)
	ylabel!(sf, "error"; row = 1, col = 1)
	plot_ecdf!(sf, samples; row = 1, col = 2, color = [navy, orange], xscale = "log")
	for (s, c) in zip(samples, (navy, orange))
		plot_vlines!(sf, s, -0.12, -0.03; row = 1, col = 2, color = c, dash = "solid")      # a strip of ticks below y = 0
	end
	yrange!(sf, (-0.13, 1.02); row = 1, col = 2)
	yticks!(sf, [0, 0.5, 1]; row = 1, col = 2)
	xticks!(sf, [1, 2, 4, 8]; row = 1, col = 2)
	xlabel!(sf, "width ratio"; row = 1, col = 2)
	ylabel!(sf, "ECDF"; row = 1, col = 2)
	plot_scatter!(sf, n, [0.5 .* 3.0 .^ (-0.6 .* n), 0.8 .* 2.5 .^ (-0.5 .* n), 2.0 .* 2.0 .^ (-0.45 .* n)];
		row = 1, col = 3, yscale = "log", mode = "lines+markers", color = [navy, teal, orange],
		marker_symbol = ["circle", "cross-thin-open", "square-open"])
	yticks!(sf; row = 1, col = 3, subs = (1, 3), format = "~g", minor = false)
	xlabel!(sf, "iteration"; row = 1, col = 3)
	ylabel!(sf, "residual"; row = 1, col = 3)
	legend_entry!(sf, "Newton"; legend_target = :figure, color = navy, mode = "lines+markers", marker_symbol = "circle")
	legend_entry!(sf, "Gauss-Newton"; legend_target = :figure, color = teal, mode = "lines+markers", marker_symbol = "cross-thin-open")
	legend_entry!(sf, "fixed point"; legend_target = :figure, color = orange, mode = "lines+markers", marker_symbol = "square-open")
	set_legend!(sf; legend_target = :figure, position = :outside_top, ncols = 3)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "optical_ecdf.png"); scale = 2)
