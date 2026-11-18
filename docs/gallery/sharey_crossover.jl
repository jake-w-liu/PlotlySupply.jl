# Two panels sharing y on a log x axis, hollow samples over limit curves, one legend above.
#
# Catalogue: math-d3-d4 "shared-y two-panel crossover with log x, hollow marker proxies and a
#   figure legend 'outside upper center'".
# Replaces: plt.subplots(sharey=True), set_xscale('log') with ticks 0.2/0.5/1/2/5, solid and
#   dashed limit curves, hollow circle/square samples, axhline(color='0.35', ls=':'),
#   fig.legend(ncol=3, loc='outside upper center') built from Line2D proxies.
# 2.0: the matplotlib grey level "0.35" is accepted as a colour, `legend_entry!` builds the proxy
#   entries and `:outside_top` places the legend above the panel titles.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
cn, cd = "#0072B2", "#D55E00"

ell = 10 .^ range(log10(0.16), log10(6); length = 360)
pts = [0.2, 0.35, 0.5, 0.75, 1, 1.5, 2, 4]
neumann(l) = 1 + 1.6 * exp(-2.2 * (l - 0.16)) * cos(2.5 * (l - 0.16)) + 0.04 * sin(9l) * exp(-l)
dirichlet(l) = 1 - exp(-2 * ((l - 0.16) / 0.3)^2) * (1 - 0.05 * sin(12l)) + 0.25 * exp(-((l - 0.5) / 0.2)^2)

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, shared_yaxes = true, per_subplot_legends = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.42)
	for (c, Λ) in enumerate((0, 2))
		s = 1 - 0.03Λ
		plot_scatter!(sf, ell, s .* neumann.(ell); row = 1, col = c, color = cn, dash = "solid", xscale = "log")
		plot_scatter!(sf, ell, s .* dirichlet.(ell); row = 1, col = c, color = cd, dash = "dash")
		for (k, mk) in enumerate(("circle-open", "square-open")), (f, col) in ((neumann, cn), (dirichlet, cd))
			plot_scatter!(sf, pts, s .* f.(pts) .* (1 + 0.05(k - 1)); row = 1, col = c, mode = "markers",
				marker_symbol = mk, color = col)
		end
		hline!(sf, 1; row = 1, col = c, color = "0.35", dash = "dot")
		xticks!(sf, [0.2, 0.5, 1, 2, 5], ["0.2", "0.5", "1", "2", "5"]; row = 1, col = c, minor = false)
		xlabel!(sf, "\$\\ell=L/\\sqrt{T}\$"; row = 1, col = c)
		title!(sf, "\$\\Lambda=\\gamma T=$Λ\$"; row = 1, col = c)
		grid!(sf; alpha = 0.16, row = 1, col = c)
	end
	ylabel!(sf, "\$\\mathcal{E}_L(T)/(T^{3/2}C_{\\infty})\$"; row = 1, col = 1)
	yrange!(sf, (0, 3.0); row = 1, col = 1)
	legend_entry!(sf, "Neumann limit"; color = cn)
	legend_entry!(sf, "Dirichlet limit"; color = cd, dash = "dash")
	legend_entry!(sf, "sharp corner"; color = "0.35", dash = "dot")
	legend_entry!(sf, "\$T=1600\$"; mode = "markers", marker_symbol = "circle-open", color = "black")
	legend_entry!(sf, "\$T=25600\$"; mode = "markers", marker_symbol = "square-open", color = "black")
	set_legend!(sf; position = :outside_top, ncols = 3)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "sharey_crossover.png"); scale = 2)
