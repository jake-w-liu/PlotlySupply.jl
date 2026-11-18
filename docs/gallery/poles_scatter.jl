# Poles in the complex plane: filled and hollow markers, a label next to every point.
#
# Catalogue: math-d3-d4 "complex-plane scatter of poles with per-point offset-text labels".
# Replaces: ax.scatter with mfc='white', ax.annotate(str(l), xytext=(4, 3), textcoords='offset points'),
#   a note in axes coordinates, y-only grid, open spines, legend top right.
# 2.0: `marker_symbol = "square-open"`, `annotate!(offset = ...)` in px from the data point,
#   `grid = :y` and `spines!(style = :open)`; the default legend position avoids the points.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, orange = "#0072B2", "#D55E00"

# synthetic pole lattice: (Re, Im, degree)
te = [(0.0, 1.0, 1), (0.87, 1.5, 2), (0.0, 2.32, 3), (1.75, 1.84, 3), (0.87, 2.9, 4), (2.65, 2.1, 4),
	(0.0, 3.65, 5), (1.74, 3.35, 5), (3.57, 2.32, 5), (0.87, 4.25, 6), (2.62, 3.74, 6), (4.49, 2.52, 6)]
tm = [(0.87, 0.5, 1), (0.0, 1.6, 2), (1.8, 0.7, 2), (0.87, 2.16, 3), (2.75, 0.85, 3), (0.0, 2.95, 4),
	(1.75, 2.57, 4), (3.71, 0.95, 4), (0.87, 3.55, 5), (2.64, 2.91, 5), (4.67, 1.05, 5), (0.0, 4.28, 6),
	(1.74, 4.04, 6), (3.54, 3.2, 6), (5.64, 1.13, 6)]

fig = with_style(:ieee) do
	fig = plot_scatter(first.(te), getindex.(te, 2); mode = "markers", marker_symbol = "circle", color = blue,
		legend = "TE poles", xlabel = "\$\\mathrm{Re}\\,\\kappa\$", ylabel = "\$\\mathrm{Im}\\,\\kappa\$",
		xrange = (-0.2, 6), yrange = (0, 5.8), grid = :y)
	plot_scatter!(fig, first.(tm), getindex.(tm, 2); mode = "markers", marker_symbol = "square-open",
		color = orange, legend = "TM poles")
	plot_scatter!(fig, [1.0], [1.5]; mode = "markers", marker_symbol = "x", color = "black", legend = "quasimode \$\\kappa\$")
	for (pts, color) in ((te, blue), (tm, orange)), (x, y, l) in pts
		annotate!(fig, x, y, string(l); showarrow = false, offset = (6, 6), anchor = :left, color = color)
	end
	annotate!(fig, 0.97, 0.59, "point labels: \$\\ell\$"; coords = :axes, showarrow = false, anchor = :bottomright,
		color = "gray")
	spines!(fig; style = :open)
	figsize!(fig, :ieee; columns = 1, aspect = 0.8)
	fig
end
savefig(fig, joinpath(outdir, "poles_scatter.png"); scale = 2)
