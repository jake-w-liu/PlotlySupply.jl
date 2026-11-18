# Dots at grouped categorical positions: filled and hollow markers, group names under the ticks.
#
# Catalogue: optical "dot comparison with categorical-grouped x positions (filled vs hollow markers)".
# Replaces: integer x positions with gaps between groups, one tick label per point, group names
#   placed with annotate(xycoords=("data", "axes fraction"), xytext=(0, -12)), dotted nominal lines
#   with a right-aligned grey text and a legend above the axes at the left.
# 2.0: the group names are a SECOND tick-label row (`secondary_xaxis!(side = :bottom)`), laid out
#   below the tick labels with room reserved; no offsets are computed.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, dark = "#0072B2", "#202020"

groups = [("wall shift (nm)", ["−40", "−20", "+20", "+40"]), ("detuning (%)", ["−0.1", "+0.1", "+0.2"]),
	("film (nm)", ["−5", "+5"]), ("holes in y (nm)", ["+20"])]
xs, labels, centres = Float64[], String[], Float64[]
let x = 1.0
	for (_, ticks) in groups
		start = x
		for t in ticks
			push!(xs, x); push!(labels, t); x += 1
		end
		push!(centres, (start + x - 1) / 2)
		x += 1                                    # one empty slot between groups
	end
end
v3 = 4 .+ 11 .* abs.(sin.(3 .* xs))               # synthetic errors (percent)
v2 = v3 .- 0.2 .- 1.5 .* abs.(cos.(5 .* xs))

fig = with_style(:ieee) do
	fig = plot_scatter(xs, v3; mode = "markers", color = dark, legend = "3-D model",
		xrange = (0, xs[end] + 1.5), yrange = (0, 15.5), ylabel = "\$e_K\$ (%)")
	plot_scatter!(fig, xs, v2; mode = "markers", marker_symbol = "circle-open", color = blue,
		legend = "reduced model")
	hline!(fig, 2.10; color = dark, dash = "dot")
	hline!(fig, 2.17; color = blue, dash = "dot")
	annotate!(fig, 1.0, 2.17, "nominal"; xref = "x domain", showarrow = false, anchor = :bottomright, color = "gray")
	xticks!(fig, xs, labels)
	secondary_xaxis!(fig, identity, identity; side = :bottom, ticks = centres, ticklabels = first.(groups))
	set_legend!(fig; position = :outside_top, ncols = 2)
	panel_labels!(fig; labels = ["c"], bold = true)
	figsize!(fig, :ieee; columns = 2, aspect = 0.4)
	fig
end
savefig(fig, joinpath(outdir, "optical_dots.png"); scale = 2)
