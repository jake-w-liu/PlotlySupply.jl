# Two stacked panels sharing x beside one tall panel, with titled legends and offset labels.
#
# Catalogue: optical "converged-fraction curves with sequential colormap ramp + scatter-with-annotation
#   panel + fill_between band spanning 2 rows".
# Replaces: GridSpec(2, 2, width_ratios=[1.3, 1]) with a spanning panel, a LinearSegmentedColormap ramp
#   sampled per line, ax.annotate(xytext=(-5, 4), textcoords='offset points'), fill_between and a
#   diagonal reference line, one titled legend per panel.
# 2.0: `Spec(rowspan = 2)`, `colormap_colors` for the ramp, `annotate!(offset = ...)`, `plot_band!`;
#   the left panels get a one-row titled legend above them (`position = :outside_top`), the default
#   legend of the right panel avoids its data.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
navy, orange, grey, light = "#0072B2", "#D55E00", "#7F8993", "#D5DBE1"

families = (("two frequencies", [4, 6, 8, 12, 33]), ("three frequencies", [6, 8, 12, 18, 33]))
x2, y2 = [0.065, 0.08, 0.115, 0.18, 0.465], [0.057, 0.079, 0.113, 0.158, 0.317]
x3, y3 = [0.08, 0.095, 0.125, 0.22, 0.445], [0.069, 0.083, 0.124, 0.194, 0.263]
xx = [0.0, 0.5]

fig = with_style(:ieee) do
	sf = subplots(2, 2; sync = false, width_ratios = [1.3, 1], shared_xaxes = "columns",
		specs = [Spec() Spec(rowspan = 2); Spec() missing])
	figsize!(sf, :ieee; columns = 2, aspect = 0.7)        # room for the legends above (a) and (b)
	for (row, (family, ns)) in enumerate(families)
		ramp = colormap_colors(["#93AECB", navy], length(ns))           # light-to-dark ramp per layout
		for (j, n) in enumerate(ns)
			r0 = collect(range(0.015, 0.30; length = 30))
			frac = clamp.(1 .- (r0 .- (0.045 + 0.006 * n * (row == 1 ? 1.0 : 0.6))) ./ 0.03, 0, 1)
			keep = [true; frac[1:end-1] .> 0]                           # stop one point after the fraction hits 0
			plot_scatter!(sf, r0[keep], frac[keep]; row = row, col = 1, color = ramp[j], dash = "solid",
				mode = "lines+markers", marker_symbol = ["circle", "square", "diamond", "triangle-up", "triangle-down"][j],
				legend = j < length(ns) ? string(n) : "$n centers")
		end
		ylabel!(sf, "converged fraction"; row = row, col = 1)
		yrange!(sf, (-0.05, 1.05); row = row, col = 1)
		yticks!(sf, [0, 0.5, 1]; row = row, col = 1)
		set_legend!(sf; row = row, col = 1, position = :outside_top, orientation = :h, title = family)
	end
	xlabel!(sf, "prescribed amplitude \$r_0=|r_{21}(k_m)|\$"; row = 2, col = 1)
	plot_band!(sf, xx, 0.59 .* xx, xx; row = 1, col = 2, color = light, opacity = 0.6,
		legend = "\$0.59\\,t_{\\mathrm{geom}}/K\$ to \$t_{\\mathrm{geom}}/K\$")
	plot_scatter!(sf, xx, xx; row = 1, col = 2, color = grey, dash = "solid", legend = "\$r_0\\sqrt{M}=t_{\\mathrm{geom}}/K\$")
	plot_scatter!(sf, x2, y2; row = 1, col = 2, mode = "markers", marker_symbol = "circle", color = navy, legend = "two frequencies")
	plot_scatter!(sf, x3, y3; row = 1, col = 2, mode = "markers", marker_symbol = "square", color = orange, legend = "three frequencies")
	for (x, y) in ((x2[end], y2[end]), (x3[end], y3[end]))
		annotate!(sf, x, y, "budget"; row = 1, col = 2, showarrow = false, offset = (-5, 4), anchor = :bottomright)
	end
	annotate!(sf, x3[4], y3[4], "budget and<br>width limit"; row = 1, col = 2, showarrow = false,
		offset = (5, -4), anchor = :topleft)
	xrange!(sf, (0, 0.5); row = 1, col = 2)
	yrange!(sf, (0, 1.4 * maximum(y2)); row = 1, col = 2)      # headroom for the legend
	xlabel!(sf, "\$t_{\\mathrm{geom}}/K\$"; row = 1, col = 2)
	ylabel!(sf, "full reach \$r_0\\sqrt{M}\$"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true, cells = [(1, 1), (2, 1), (1, 2)])
	sf
end
savefig(fig, joinpath(outdir, "optical_reach.png"); scale = 2)
