# Horizontal bars on a log axis with conditional value labels, and a stacked power budget.
#
# Catalogue: optical "horizontal bars on log x with inside/outside value labels; stacked vertical bars".
# Replaces: ax.barh with one highlighted colour, ax.text value labels inside or outside the bar,
#   hidden left spine, ax.bar(bottom=...) stacks and a legend above built from Rectangle handles.
# 2.0: one `plot_bar!` series per colour, `annotate!(anchor = ...)` for the labels, `barmode =
#   "stack"` for the budget and `:outside_top` for the legend; fonts and spines come from the preset.
using PlotlySupply

set_default_mathtext!(true; inherit_text_font = true)    # text parts of math labels stay in the sans font

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, orange, grey, dark = "#0072B2", "#E69F00", "#999999", "#202020"

names = ["Uniform poling", "Overlap sign", "Binary descent", "Gradient<br>continuation", "LP and rounding"]
vals = [100.0, 28.0, 4.13, 1.72, 2.10]
ypos = collect(length(vals):-1:1)                  # the first bar at the top
hl = [false, false, false, false, true]            # the highlighted bar is a series of its own

wl = ["1.55", "1.30", "0.707"]
slices = [[66.5, 68.0, 70.5], [17.5, 7.5, 11.0], [2.0, 3.5, 8.5], [14.0, 21.0, 10.0]]
slice_names = ["TM\$_0\$ transmitted", "TM\$_0\$ reflected", "other guided", "radiated"]
slice_colors = [blue, orange, grey, dark]

fig = with_style(:nature) do
	sf = subplots(1, 2; sync = false, width_ratios = [1.3, 1])
	figsize!(sf, :nature; columns = 2, aspect = 0.4)
	plot_bar!(sf, [vals[.!hl], vals[hl]], [ypos[.!hl], ypos[hl]]; row = 1, col = 1, orientation = "h",
		color = [grey, blue], barmode = "stack", xscale = "log", showlegend = false)
	for (v, y) in zip(vals, ypos)
		label = v >= 100 ? string(round(Int, v)) : string(round(v; sigdigits = 3))
		inside = v > 50                           # white inside a long bar, dark just outside a short one
		annotate!(sf, inside ? v / 1.1 : v * 1.1, y, label; row = 1, col = 1, showarrow = false,
			anchor = inside ? :right : :left, color = inside ? "white" : "black")
	end
	xrange!(sf, (1, 1.05 * maximum(vals)); row = 1, col = 1)
	xticks!(sf, [1, 10, 100], ["\$10^0\$", "\$10^1\$", "\$10^2\$"]; row = 1, col = 1)
	yticks!(sf, ypos, names; row = 1, col = 1)
	xlabel!(sf, "\$e_K\$ (%)"; row = 1, col = 1)
	title!(sf, "reduced model"; row = 1, col = 1)
	plot_bar!(sf, wl, slices; row = 1, col = 2, barmode = "stack", color = slice_colors, showlegend = false)
	yrange!(sf, (0, 100); row = 1, col = 2)
	xlabel!(sf, "wavelength (\$\\mu\$m)"; row = 1, col = 2)
	ylabel!(sf, "power of the input (%)"; row = 1, col = 2)
	for k in length(slice_names):-1:1                    # reverse stacking order
		legend_entry!(sf, slice_names[k]; row = 1, col = 2, patch = true, color = slice_colors[k])
	end
	set_legend!(sf; row = 1, col = 2, position = :outside_top, ncols = 2)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "optical_bars.png"); scale = 2)
set_default_mathtext!()
