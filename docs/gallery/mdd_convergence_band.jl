# h- and p-refinement: hollow experiment markers, formula lines, a min/max band, a guide.
#
# Catalogue: math-deepdebug 5; math-d3-d4 "log-log / semilogy convergence with an N^-p guide", "log-log dashed
#   bound plus markevery sparse markers", "limit overlays"; optical "ratio curves with a marker ladder".
# Replaces: loglog with mfc='none', fill_between, markevery=8, a dashed N^-2 guide with ax.text,
#   ax.annotate(arrowprops=...), a boxed ax.text in axes coordinates, open spines, a legend row above.
# 2.0: `plot_band!`, `markevery`, `slope_guide!`, `annotate!` with an offset and a background box,
#   `spines!(:open)` and one figure legend stacked above the panel titles.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, orange = "#0072B2", "#D55E00"

N = [4, 8, 16, 32, 64, 128]
Nd = exp.(range(log(4), log(128); length = 41))
errA = 0.8 .* N .^ -2 .* (1 .+ 1.5 ./ N)
p = 1:8
errB = 0.3 .* exp.(-1.25 .* p)

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, per_subplot_legends = false, shared_yaxes = true)
	figsize!(sf, :ieee; columns = 2, aspect = 0.45)
	# (a) h-refinement
	plot_band!(sf, Nd, 0.6 .* Nd .^ -2, 1.25 .* Nd .^ -2 .* (1 .+ 2 ./ Nd); row = 1, col = 1,
		color = blue, opacity = 0.18, xscale = "log", yscale = "log", legend = "min/max band")
	plot_scatter!(sf, Nd, 0.85 .* Nd .^ -2; row = 1, col = 1, color = blue, markevery = 8,
		mode = "lines+markers", marker_symbol = "square", legend = "formula")
	plot_scatter!(sf, N, errA; row = 1, col = 1, mode = "markers", marker_symbol = "circle-open",
		marker_size = 8, color = orange, legend = "experiment")
	slope_guide!(sf, -2; x = (10, 60), through = (10, 0.04), label = "\$N^{-2}\$", color = "gray",
		dash = "dash", row = 1, col = 1)
	annotate!(sf, N[2], errA[2], "pre-asymptotic"; row = 1, col = 1, offset = (45, 28))
	annotate!(sf, 0.04, 0.06, "\$\\kappa=4\$"; coords = :axes, row = 1, col = 1, showarrow = false,
		anchor = :bottomleft, background = "white", edgecolor = "gray")
	xticks!(sf, N, string.(N); row = 1, col = 1, minor = false)
	yticks!(sf, :decades; row = 1, col = 1)
	yrange!(sf, (1e-5, 0.3); row = 1, col = 1)
	# (b) p-refinement: exponential decay on the same y axis
	plot_scatter!(sf, p, 0.32 .* exp.(-1.22 .* p); row = 1, col = 2, color = blue, yscale = "log")
	plot_scatter!(sf, p, errB; row = 1, col = 2, mode = "markers", marker_symbol = "circle-open",
		marker_size = 8, color = orange)
	annotate!(sf, 0.96, 0.94, "spectral"; coords = :axes, row = 1, col = 2, showarrow = false,
		anchor = :topright, background = "white", edgecolor = "gray")
	xticks!(sf, collect(p); row = 1, col = 2)
	xlabel!(sf, "elements per side \$N\$"; row = 1, col = 1)
	xlabel!(sf, "polynomial degree \$p\$"; row = 1, col = 2)
	ylabel!(sf, "relative error"; row = 1, col = 1)
	title!(sf, "h-refinement"; align = :left, row = 1, col = 1)
	title!(sf, "p-refinement"; align = :left, row = 1, col = 2)
	for c in 1:2
		spines!(sf; style = :open, row = 1, col = c)
		grid!(sf; axis = :y, alpha = 0.25, row = 1, col = c)
	end
	panel_labels!(sf; labels = :abc, format = "({})")
	set_legend!(sf; position = :outside_top, ncols = 3, legend_target = :figure)
	sf
end
savefig(fig, joinpath(outdir, "mdd_convergence_band.png"); scale = 2)
