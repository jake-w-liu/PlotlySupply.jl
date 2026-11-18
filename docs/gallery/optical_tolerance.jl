# Reference line on log-log axes, nested tolerance bands, and a secondary axis in nanometres.
#
# Catalogue: optical "log-log data + reference-line plot, axhspan tolerance bands, axvline
#   thresholds, secondary x axis".
# Replaces: GridSpec(2, 2) with a full-width bottom panel, axhspan, axvline, ax.secondary_xaxis
#   with a pair of conversion functions, ylim(bottom=0) and a figure legend 'outside upper center'.
# 2.0: `Spec(colspan = 2)`, `hspan!`/`vline!`, `secondary_xaxis!(f, finv)`, `yrange = (0, nothing)`
#   and `:outside_top`; the secondary axis' room is taken from the cell, no spacing is tuned.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, orange, grey = "#0072B2", "#D55E00", "#7F8993"

delta = exp10.(range(-4, 0; length = 30))
lam = 38.54
eta = lam .* delta .* (1 .- 0.4 .* delta .^ 2)
ratio = 1 .+ 0.03 .* delta .^ 0.3 .- 0.5 .* delta .^ 3
p = range(-0.3, 0.3; length = 121)

fig = with_style(:ieee) do
	sf = subplots(2, 2; sync = false, width_ratios = [1, 1.15], height_ratios = [1.3, 1],
		specs = [Spec() Spec(); Spec(colspan = 2) missing])
	figsize!(sf, :ieee; columns = 2, aspect = 0.62)
	plot_scatter!(sf, delta, lam .* delta; row = 1, col = 1, color = grey, dash = "dash", xscale = "log",
		yscale = "log", legend = "\$\\lambda_*\\delta,\\ \\lambda_*=38.54\$")
	plot_scatter!(sf, delta, eta; row = 1, col = 1, mode = "markers", color = blue, legend = "computed \$\\eta_*\$")
	xlabel!(sf, "hole contrast \$\\delta\$"; row = 1, col = 1)
	ylabel!(sf, "target scale \$\\eta_*\$"; row = 1, col = 1)
	hspan!(sf, 0.90, 1.10; row = 1, col = 2, color = "#eef1f4", opacity = 1)
	hspan!(sf, 0.98, 1.02; row = 1, col = 2, color = "#d9dee4", opacity = 1)
	hline!(sf, 1.0; row = 1, col = 2, color = grey)
	vline!(sf, 0.065; row = 1, col = 2, color = grey, dash = "dot")
	vline!(sf, 0.7; row = 1, col = 2, color = grey, dash = "dash")
	plot_scatter!(sf, delta, ratio; row = 1, col = 2, xscale = "log", mode = "lines+markers", color = blue,
		dash = "solid")
	annotate!(sf, 0.03, 0.05, "bands: ±2%, ±10%"; row = 1, col = 2, coords = :axes, showarrow = false,
		anchor = :bottomleft, color = grey)
	xlabel!(sf, "hole contrast \$\\delta\$"; row = 1, col = 2)
	ylabel!(sf, "\$\\eta_*/(\\lambda_*\\delta)\$"; row = 1, col = 2)
	plot_scatter!(sf, p, [2 .+ 230 .* p .^ 2, 3.4 .+ 120 .* p .^ 2 .* (1 .+ 0.5 .* sin.(12 .* p))];
		row = 2, col = 1, color = [blue, orange], dash = "solid")
	plot_scatter!(sf, p, fill(0.25, length(p)); row = 2, col = 1, color = grey, dash = "dash")
	hline!(sf, 10; row = 2, col = 1, color = grey, dash = "dot")
	xrange!(sf, (-0.3, 0.3); row = 2, col = 1)
	yrange!(sf, (0, nothing); row = 2, col = 1)                   # ylim(bottom=0)
	xlabel!(sf, "common relative detuning (%)"; row = 2, col = 1)
	ylabel!(sf, "\$e_K\$ (%)"; row = 2, col = 1)
	secondary_xaxis!(sf, pc -> pc / 100 * 1550.0, nm -> 100 * nm / 1550.0; row = 2, col = 1,
		title = "detuning at \$\\lambda_1\$ (nm)")
	legend_entry!(sf, "reduced-model design"; legend_target = :figure, color = blue)
	legend_entry!(sf, "scenario design"; legend_target = :figure, color = orange)
	legend_entry!(sf, "uniform grating"; legend_target = :figure, color = grey, dash = "dash")
	set_legend!(sf; legend_target = :figure, position = :outside_top)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "optical_tolerance.png"); scale = 2)
