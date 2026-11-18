# Theory lines against hollow-marker data, with a shorter residual row of stems below.
#
# Catalogue: math-deepdebug 6, math-deepdebug "linear-axis line plots with hollow markers",
#   math-d3-d4 "linear overlays".
# Replaces: plt.subplots(2, 2, sharex='col', height_ratios=[1.5, 1]), ax.plot(x[::3], y[::3], 'o',
#   mfc='none'), ax.vlines stems, tick_params(direction='in'), a boxed ax.text in axes coordinates.
# 2.0: `height_ratios`, `shared_xaxes = "columns"`, `plot_vlines!` stems and an `annotate!`
#   box; inward ticks and the box frame come from the journal preset.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

x = collect(range(0, 10.5; length = 43))
xs = x[1:6:end]                                  # the "computed" points
series = [("\$g=0.001\$", "#0072B2", "circle-open", -0.0078), ("\$g=0.008\$", "#D55E00", "square-open", -0.0615)]
resid(xv, k) = 1e-4 .* (0.6 .+ 0.4k) .* sin.(1.3 .* xv .+ k) .* exp.(-0.08 .* xv)

fig = with_style(:aps) do
	sf = subplots(2, 2; sync = false, height_ratios = [1.5, 1], shared_xaxes = "columns")
	figsize!(sf, :aps; columns = 2, aspect = 0.5)
	for (k, (label, c, m, slope)) in enumerate(series)
		dx = 0.12 * (k - 1.5)                    # keep the two stems of one x apart
		r = resid(xs, k)
		for (col, y, scale) in ((1, slope .* x, 1), (2, -1.79 .* x .* (1 + 0.2k), 3))
			plot_scatter!(sf, x, y; row = 1, col = col, color = c)
			plot_scatter!(sf, xs, y[1:6:end]; row = 1, col = col, mode = "markers", marker_symbol = m,
				marker_size = 8, color = c, (col == 1 ? (legend = label,) : NamedTuple())...)
			plot_vlines!(sf, xs .+ dx, 0, scale .* r; row = 2, col = col, color = c)
			plot_scatter!(sf, xs .+ dx, scale .* r; row = 2, col = col, mode = "markers",
				marker_symbol = "circle", marker_size = 4, color = c)
		end
	end
	annotate!(sf, 0.97, 0.95, "symbols: HDM computation<br>lines: Mellin exponent"; coords = :axes,
		row = 1, col = 2, showarrow = false, anchor = :topright)
	for c in 1:2
		hline!(sf, 0; row = 2, col = c, color = "gray")
		annotate!(sf, 0.98, 0.06, "residual"; coords = :axes, row = 2, col = c, showarrow = false,
			anchor = :bottomright)
		xlabel!(sf, "\$\\log(\\ell_{\\mathrm{ref}}/\\ell)\$"; row = 2, col = c)
		foreach(r -> grid!(sf; alpha = 0.25, row = r, col = c), 1:2)
	end
	ylabel!(sf, "\$\\log|q/q_{\\mathrm{ref}}|\$"; row = 1, col = 1)
	ylabel!(sf, "\$\\arg[q/q_{\\mathrm{ref}}]\$"; row = 1, col = 2)
	title!(sf, "attenuation"; row = 1, col = 1)
	title!(sf, "phase"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "mdd_theory_vs_data.png"); scale = 2)
