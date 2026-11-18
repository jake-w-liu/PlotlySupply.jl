# An analytic response surface with 3-D curves and samples, beside an equal-aspect ellipse.
#
# Catalogue: topo "3D facecolor-mapped parametric surface (torus)" (the same calls as chama_a9), topo "3D analytic response surface with markers, 3D curves and a 2D ellipse companion".
# Replaces: plot_surface (one colour, alpha, light edges) with ax.plot curves and ax.scatter samples
#   in 3-D, fraction tick labels, box aspect (1.3, 1, .85), view_init(24, -61), and a 2-D orbit
#   ellipse with text lines and a two-column legend above the axes.
# 2.0: `plot_surface!(color = ..., edges = true)`, `plot_scatter3d!`, `scene!(yticklabels = ...)`,
#   `view!`; in 3-D, axis titles are plain text (WebGL cannot typeset TeX); the 2-D panel stacks its
#   legend above the title by itself.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
surf, green, purple, dark = "#55A7CA", "#009E73", "#CC79A7", "#333333"

Rfun(a, t) = (1 - 0.55 * (a - 1)) * (1 + 1.6 * t^2 * a) + 0.12 * (a - 0.8)^2   # analytic model
α, τ = range(0.8, 1.4; length = 31), range(0, 0.125; length = 31)
ag, tg = range(0.88, 0.97; length = 6), range(0.02, 0.11; length = 6)
as, ts = [0.8, 0.85, 0.95, 1.0, 1.1, 1.21, 1.3, 1.4], [0.0, 0.03, 0.06, 0.09, 0.12]
sa = [a for a in as for t in ts][1:3:end]
st = [t for a in as for t in ts][1:3:end]
θ = range(0, 2π; length = 241)

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec()], width_ratios = [1.25, 1],
		width = journal_width(:ieee; columns = 2, units = :px), height = 300)
	plot_surface!(sf, collect(α), collect(τ), [Rfun(a, t) for a in α, t in τ]; row = 1, col = 1, color = surf,
		opacity = 0.66, edges = true, edgecolor = "#D6E6EC", xlabel = "material scale alpha",
		ylabel = "time step dt/T", zlabel = "frequency ratio R")
	for (x, y, c, dash, w) in ((collect(α), zeros(31), dark, "solid", 4), (fill(1.0, 31), collect(τ), dark, "dash", 3),
		(fill(1.21, 31), collect(τ), purple, "solid", 4))
		plot_scatter3d!(sf, x, y, Rfun.(x, y); row = 1, col = 1, color = c, linewidth = w, dash = dash, showlegend = false)
	end
	plot_scatter3d!(sf, collect(ag), collect(tg), Rfun.(ag, tg); row = 1, col = 1, mode = "lines+markers",
		marker_symbol = "diamond", marker_size = 4, color = green, linewidth = 4, showlegend = false)
	plot_scatter3d!(sf, sa, st, Rfun.(sa, st); row = 1, col = 1, mode = "markers", marker_symbol = "circle", marker_size = 3, color = dark,
		showlegend = false)
	scene!(sf; row = 1, col = 1, aspectratio = (1.3, 1.0, 0.85), showbackground = false, xticks = [0.8, 1.0, 1.2, 1.4],
		yticks = [0, 0.0625, 0.125], yticklabels = ["0", "1/16", "1/8"], zticks = [0.8, 1.0, 1.1])
	view!(sf; row = 1, col = 1, elev = 24, azim = -61)
	hline!(sf, 0; row = 1, col = 2, color = "#bbbbbb")
	vline!(sf, 0; row = 1, col = 2, color = "#bbbbbb")
	plot_scatter!(sf, cos.(θ), sin.(θ); row = 1, col = 2, color = dark, dash = "solid", legend = "\$\\alpha=1\$",
		xrange = (-1.2, 1.2), yrange = (-1.15, 1.15), equalar = true)
	plot_scatter!(sf, cos.(θ) ./ sqrt(1.21), sin.(θ); row = 1, col = 2, color = purple, dash = "solid",
		legend = "\$\\alpha=1.21\$")
	plot_scatter!(sf, [0, 1 / sqrt(1.21)], [1, 0]; row = 1, col = 2, mode = "markers", color = purple, showlegend = false)
	annotate!(sf, 0, 0.5, "\$\\alpha a^2+s^2=1\$"; row = 1, col = 2, showarrow = false)
	annotate!(sf, 0, 0.1, "own energy: constant"; row = 1, col = 2, showarrow = false)
	annotate!(sf, 0, -0.45, "original energy:<br>21% variation"; row = 1, col = 2, showarrow = false, color = purple)
	xticks!(sf, [-1, 0, 1]; row = 1, col = 2)
	yticks!(sf, [-1, 0, 1]; row = 1, col = 2)
	xlabel!(sf, "electric amplitude \$a\$"; row = 1, col = 2)
	ylabel!(sf, "magnetic amplitude \$s\$"; row = 1, col = 2)
	set_legend!(sf; row = 1, col = 2, position = :outside_top, ncols = 2)
	title!(sf, "analytic surface (dots: full system)"; row = 1, col = 1)
	title!(sf, "material shapes the orbit"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "topo_response.png"); scale = 2)
