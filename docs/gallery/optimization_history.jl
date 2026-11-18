# Optimization histories with fading seeds beside categorical end points with rotated labels.
#
# Catalogue: optical "optimization history semilogy with fading alpha per seed + scatter with
#   categorical x ticks".
# Replaces: ax.plot(alpha = 1 - .23 * seed) with one legend entry per method, set_xticks +
#   set_xticklabels + tick_params(rotation=20), minor log-tick labels on a short axis.
# 2.0: per-trace `opacity`, an unnamed trace stays out of the legend, `xticks!(...; angle = -20)`,
#   and `yticks!(...; subs = ...)` labels the mantissas of an axis shorter than a decade.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

methods = [("power-constrained fit", "#0072B2", "solid", "circle", -0.08),
	("eigenchannel pair", "#CC79A7", "dash", "square", 0.08)]

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.4)
	for (m, (name, color, dash, marker, dx)) in enumerate(methods)
		finals = Float64[]
		for seed in 0:2
			evals = collect(1:(260 + 90seed))
			J = @. 6e-3 * (0.06 + 0.94 * exp(-evals / (25 + 15seed + 20m))) * (1 + 0.6 * abs(sin(0.37evals + seed)))
			best = accumulate(min, J)                                   # running minimum
			push!(finals, best[end])
			plot_scatter!(sf, evals, best; row = 1, col = 1, color = color, dash = dash, opacity = 1 - 0.23seed,
				yscale = "log", (seed == 0 ? (legend = name,) : NamedTuple())...)
		end
		for case in 0:2                                                 # three starting-point families
			plot_scatter!(sf, [case + dx], [finals[case + 1] * (1 + 0.4case)]; row = 1, col = 2, mode = "markers",
				marker_symbol = marker, color = color, yscale = "log")
		end
	end
	xticks!(sf, [0, 1, 2], ["uniform 0.2", "uniform 0.5", "random"]; row = 1, col = 2, angle = -20)
	xrange!(sf, (-0.5, 2.5); row = 1, col = 2)
	yticks!(sf; row = 1, col = 2, subs = 1:9)               # less than a decade: label every mantissa
	xlabel!(sf, "Maxwell evaluations"; row = 1, col = 1)
	ylabel!(sf, "best feasible \$J\$"; row = 1, col = 1)
	ylabel!(sf, "final objective \$J\$"; row = 1, col = 2)
	foreach(c -> spines!(sf; style = :open, row = 1, col = c), 1:2)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "optimization_history.png"); scale = 2)
