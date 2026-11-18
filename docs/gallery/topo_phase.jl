# A phase-plane schematic with arcs and leader labels, beside a phase-lag plot.
#
# Catalogue: topo "2D phase-plane schematic: unit circle fill, arc arrows, annotate leader lines,
#   markers with white edges".
# Replaces: ax.fill under everything, dotted reference radius, FancyArrowPatch arcs,
#   ax.annotate(xytext=..., arrowprops={'arrowstyle': '-'}) labels and white-edged markers.
# 2.0: `circle!(layer = "below")`, `arc!(arrow = :end)`, `annotate!(xytext = ..., head = ...)` leader
#   lines with a `background`, and `equalar = true`; labels do not overlap the circle or each other.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
coarse, fine, ref = "#D55E00", "#0072B2", "#333333"

lag8, lag32 = 2.368, 0.161                        # phase lags after 8 periods (rad)
p8 = (cos(deg2rad(225)), sin(deg2rad(225)))       # N = 8 state (schematic position)
p32 = (cos(-lag32), sin(-lag32))                  # N = 32 state
t, ts = range(0, 8; length = 100), 0:8

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.42)
	A = (row = 1, col = 1)
	plot_scatter!(sf, [0, 1], [0, 0]; A..., color = ref, dash = "dot", xrange = (-1.25, 1.5), yrange = (-1.2, 1.15),
		equalar = true)
	circle!(sf, 0, 0, 1; A..., fillcolor = "#F0F3F5", edgecolor = ref, layer = "below")
	hline!(sf, 0; A..., color = "#bababa")
	vline!(sf, 0; A..., color = "#bababa")
	plot_scatter!(sf, [[0, p8[1]], [0, p32[1]]], [[0, p8[2]], [0, p32[2]]]; A..., color = [coarse, fine], dash = "solid")
	arc!(sf, 0, 0, 0.58, 0, -135; A..., arrow = :end, color = coarse)
	arc!(sf, 0, 0, 0.86, 0, -rad2deg(lag32); A..., arrow = :end, color = fine)
	for (p, c, m) in (((1.0, 0.0), ref, "circle"), (p8, coarse, "circle"), (p32, fine, "square"))
		plot_scatter!(sf, [p[1]], [p[2]]; A..., mode = "markers", marker_symbol = m, marker_size = 8, color = c,
			marker_line_color = "white", marker_line_width = 0.6)
	end
	annotate!(sf, 1.0, 0.0, "exact"; A..., xytext = (1.2, 0.3), head = :none, anchor = :left, color = ref)
	annotate!(sf, p32[1], p32[2], "\$N=32\$"; A..., xytext = (1.1, -0.45), head = :none, color = fine)
	annotate!(sf, p8[1], p8[2], "\$N=8\$"; A..., xytext = (-0.95, -1.0), head = :none, color = coarse)
	annotate!(sf, -0.16, 0.5, "\$a^2+s^2=1\$<br>\$\\mathcal{E}_h=1/2\$"; A..., showarrow = false)
	xticks!(sf, [-1, 0, 1]; A...)
	yticks!(sf, [-1, 0, 1]; A...)
	xlabel!(sf, "electric amplitude \$a\$"; A...)
	ylabel!(sf, "magnetic amplitude \$s\$"; A...)
	for (lag, c, m, name) in ((lag8, coarse, "circle", "\$N=8\$"), (lag32, fine, "square", "\$N=32\$"))
		plot_scatter!(sf, t, lag / 8 .* t; row = 1, col = 2, color = c, dash = "solid")
		plot_scatter!(sf, ts, lag / 8 .* ts; row = 1, col = 2, mode = "markers", marker_symbol = m, color = c,
			legend = name)
		annotate!(sf, 8, lag, string(lag); row = 1, col = 2, showarrow = false, offset = (-4, 12), anchor = :right, color = c)
	end
	annotate!(sf, 0.03, 0.62, "curves: formula<br>symbols: full system"; row = 1, col = 2, coords = :axes,
		showarrow = false, anchor = :topleft, color = "gray")
	grid!(sf; row = 1, col = 2, alpha = 0.16)
	xlabel!(sf, "elapsed periods \$t/T_h\$"; row = 1, col = 2)
	ylabel!(sf, "phase lag \$\\delta\\psi\$ (rad)"; row = 1, col = 2)
	title!(sf, "equal energy, different phase"; row = 1, col = 1, align = :left)
	title!(sf, "phase lag accumulates"; row = 1, col = 2, align = :left)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "topo_phase.png"); scale = 2)
