# Two series with their extrapolated end points drawn as stars.
#
# Catalogue: math-d3-d4 "single-curve endpoint coefficient with star extrapolation marker".
# Replaces: ax.plot('o-') / ax.plot('s-'), ax.plot(0, B0, '*', ms=9) in the matching colour,
#   \operatorname legend labels, explicit ticks, faint grid and a frameless legend.
# 2.0: multi-series `plot_scatter` with per-series colours and markers, `\operatorname` in math
#   legend entries, the journal preset for fonts and size.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
colors = ["#4477AA", "#EE6677"]

x = sqrt.([0.00125, 0.0025, 0.005, 0.01, 0.02, 0.04])
re_b = -8.3 .+ 26.5 .* x                 # synthetic 10^4 Re B and 10^4 Im B
im_b = 0.45 .- 16.5 .* x

fig = with_style(:ieee) do
	fig = plot_scatter(x, [re_b, im_b]; mode = "lines+markers", marker_symbol = ["circle", "square"],
		color = colors, legend = ["\$10^4\\operatorname{Re}B\$", "\$10^4\\operatorname{Im}B\$"],
		xlabel = "\$\\sqrt{\\sigma}\$", ylabel = "endpoint chart coefficient", title = "Geometric endpoint coupling",
		xticks = 0:0.05:0.2)
	for (y0, c) in zip((-8.3, 0.42), colors)       # unnamed: no legend entry
		plot_scatter!(fig, [0.0], [y0]; mode = "markers", marker_symbol = "star", marker_size = 12, color = c)
	end
	grid!(fig; alpha = 0.2)
	figsize!(fig, :ieee; columns = 1, aspect = 0.85)
	fig
end
savefig(fig, joinpath(outdir, "endpoint_star.png"); scale = 2)
