# A schematic of circles, arrows and math labels above two data panels.
#
# Catalogue: math-deepdebug 3, math-d3-d4 "schematic from patches, arrows and text".
# Replaces: GridSpec(2, 2) with a top cell spanning both columns, ax.axis('off') with
#   set_aspect('equal'), Circle / FancyArrowPatch patches, ax.text math labels and end-of-curve labels.
# 2.0: `Spec(colspan = 2)` for the wide cell, `equalar = true` + `axis_off!` for the drawing,
#   `circle!`/`arrow!`, and `annotate!` with `anchor` and `offset` instead of position arithmetic.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, green, purple, orange = "#0072B2", "#009E73", "#CC79A7", "#D55E00"

fig = with_style(:ieee) do
	sf = subplots(2, 2; sync = false, height_ratios = [0.9, 1], specs = [Spec(colspan = 2) missing; Spec() Spec()])
	figsize!(sf, :ieee; columns = 2, aspect = 0.72)
	# (a) the schematic: data units, equal aspect, no axes
	plot_scatter!(sf, Float64[], Float64[]; row = 1, col = 1, xrange = (0, 11.8), yrange = (-0.45, 3.35), equalar = true)
	cell = (row = 1, col = 1)
	circle!(sf, 2.1, 1.75, 0.45; fillcolor = "#CBD2D8", edgecolor = "gray", cell...)
	circle!(sf, 2.1, 1.75, 0.95; edgecolor = blue, cell...)
	for θ in deg2rad.((35, 5, -25))
		arrow!(sf, 2.1 + 1.05cos(θ), 1.75 + 1.05sin(θ), 2.1 + 1.55cos(θ), 1.75 + 1.55sin(θ); color = blue, cell...)
	end
	arrow!(sf, 4.6, 1.75, 6.5, 1.75; color = "black", linewidth = 1.5, cell...)
	circle!(sf, 8.6, 1.75, 0.95; fillcolor = lighten(green, 0.9), edgecolor = green, dash = "dash", layer = "below", cell...)
	plot_scatter!(sf, [8.6, 9.55], [1.75, 1.75]; mode = "lines+markers", color = blue, linewidth = 3, dash = "solid", cell...)
	for (x, y, text, kw) in ((2.1, 3.1, "outgoing field \$e^{-ikr}/r\$", ()), (2.1, 0.3, "\$1<\\rho<R/a\$", ()),
		(1.1, 0.7, "\$r=R\$", (color = blue,)), (5.55, 2.2, "\$x=R/r\$", ()),
		(5.55, 1.3, "\$F=re^{ikr}(\\mathbf{E},\\mathbf{V})\$", ()), (8.6, 3.1, "analytic disk \$|x|<\\rho\$", ()),
		(8.6, 1.45, "0", ()), (9.55, 1.45, "1", ()))
		annotate!(sf, x, y, text; showarrow = false, cell..., kw...)
	end
	annotate!(sf, 7.55, 2.45, "infinity"; showarrow = false, anchor = :right, color = green, cell...)
	annotate!(sf, 9.7, 2.45, "matching sphere"; showarrow = false, anchor = :left, color = blue, cell...)
	axis_off!(sf; cell...)
	# (b) bounded bulk norms on log-log axes with dotted limits
	l = [1, 2, 4, 8, 16, 32, 64]
	for (label, color, m, v, limit) in (("\$|\\kappa|=0\$", blue, "square", fill(1.0, 7), 1.0),
		("\$|\\kappa|=1\$", green, "circle", [1.38, 1.30, 1.28, 1.27, 1.27, 1.27, 1.27], 1.27),
		("\$|\\kappa|=4\$", purple, "triangle-up", [17.0, 11.0, 10.0, 10.3, 10.7, 11.0, 11.2], 11.4))
		plot_scatter!(sf, l, v; row = 2, col = 1, mode = "lines+markers", color = color, marker_symbol = m,
			legend = label, xscale = "log", yscale = "log")
		hline!(sf, limit; row = 2, col = 1, color = color, dash = "dot")
	end
	set_legend!(sf; row = 2, col = 1, position = (0.5, 0.45), xanchor = "center", yanchor = "middle")   # between the curves
	xticks!(sf, l, string.(l); row = 2, col = 1, minor = false)
	yticks!(sf, [1, 2, 5, 10, 20], ["1", "2", "5", "10", "20"]; row = 2, col = 1, minor = false)
	# (c) trace singular values with the curve label at the end of each curve
	for (k, color, slope) in (("4", purple, 1.15), ("1", green, 1.75), ("0.1", orange, 2.7))
		s = -slope .* (0:31) .* (1 .+ 0.004 .* (1:32)) .+ (k == "0.1" ? -3 : 0)
		plot_scatter!(sf, 1:32, s; row = 2, col = 2, color = color)
		annotate!(sf, 32, s[end], k; row = 2, col = 2, showarrow = false, anchor = :left, offset = (4, 0), color = color)
	end
	xlabel!(sf, "angular degree \$\\ell\$"; row = 2, col = 1)
	xlabel!(sf, "angular degree \$\\ell\$"; row = 2, col = 2)
	ylabel!(sf, "bulk norm \$n_\\ell^2\$"; row = 2, col = 1)
	ylabel!(sf, "\$\\log_{10}\$ singular value \$s_\\ell\$"; row = 2, col = 2)
	title!(sf, "physical exterior and analytic compactification"; align = :left, row = 1, col = 1)
	title!(sf, "bulk remains bounded"; align = :left, row = 2, col = 1)
	title!(sf, "trace loses amplitude"; align = :left, row = 2, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "mdd_schematic.png"); scale = 2)
