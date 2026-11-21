# Convergence with slope guides and a numerical-floor band, beside a work-accuracy plot.
#
# Catalogue: topo "log-log convergence/error curves with slope guides and numerical-floor band".
# Replaces: loglog with o-/s- series, dashed and dotted slope guides in the legend, an unresolved
#   value as a white marker at the floor, axhspan, fig.supylabel and one figure legend below.
# 2.0: `slope_guide!(legend = ...)`, `hspan!` for the floor, `y_title` for the shared y title, a
#   NaN gap for the unresolved point, and `:outside_bottom` for the figure legend.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, orange, purple, grey = "#0072B2", "#D55E00", "#CC79A7", "#777777"

d = [0.075, 0.1, 0.15, 0.2, 0.3, 0.4]
floor_ = 5e-12
graph = 1.1e-7 .* (d ./ 0.4) .^ 6
resolved = graph .> floor_
t = exp10.(range(-2.4, -0.5; length = 40))
cloud = 10 .^ (-3 .- 8 .* abs.(sin.(37 .* t)) .* (log10.(t) .+ 2.5) ./ 2)     # a deterministic point cloud
tf = exp10.(range(-2.4, -0.5; length = 10))

fig = with_style(:elsevier) do
	sf = subplots(1, 2; sync = false, shared_yaxes = true, per_subplot_legends = false,
		y_title = "largest relative error")
	figsize!(sf, :elsevier; columns = 2, aspect = 0.45)
	plot_scatter!(sf, d, [r ? g : NaN for (r, g) in zip(resolved, graph)]; row = 1, col = 1, xscale = "log",
		yscale = "log", mode = "lines+markers", marker_symbol = "circle", color = blue, legend = "graph eigenvalue error")
	plot_scatter!(sf, d[.!resolved], fill(floor_, count(.!resolved)); row = 1, col = 1, mode = "markers",
		marker_symbol = "circle-open", color = blue)               # unresolved: open marker pinned at the floor
	plot_scatter!(sf, d, 3e-5 .* (d ./ 0.4) .^ 4; row = 1, col = 1, mode = "lines+markers", marker_symbol = "square",
		color = purple, legend = "doublet projector error")
	slope_guide!(sf, 6; row = 1, col = 1, x = (0.1, 0.4), through = (0.4, 6e-8), color = grey, dash = "dash",
		legend = "\$\\delta^6\$ guide")
	slope_guide!(sf, 4; row = 1, col = 1, x = (0.1, 0.4), through = (0.4, 5e-5), color = grey, dash = "dot",
		legend = "\$\\delta^4\$ guide")
	hspan!(sf, 1e-13, floor_; row = 1, col = 1, color = "#ebebeb", opacity = 1)
	xticks!(sf, [0.075, 0.1, 0.2, 0.4], ["0.075", "0.1", "0.2", "0.4"]; row = 1, col = 1)
	xrange!(sf, (0.068, 0.45); row = 1, col = 1)
	yrange!(sf, (1e-12, 1e-2); row = 1, col = 1)
	yticks!(sf, :decades; row = 1, col = 1)
	plot_scatter!(sf, t, cloud; row = 1, col = 2, mode = "markers", marker_symbol = "circle", marker_size = 3,
		color = "#b8b8b8", opacity = 0.65, xscale = "log", yscale = "log", showlegend = false)
	plot_scatter!(sf, tf, 1e-3 .* (tf ./ tf[1]) .^ (-4.5); row = 1, col = 2, mode = "lines+markers",
		marker_symbol = "diamond", color = "black", legend = "full-model envelope")
	plot_scatter!(sf, [0.023, 0.05, 0.07, 0.1], fill(1.2e-6, 4); row = 1, col = 2, mode = "lines+markers",
		marker_symbol = "circle", color = blue, legend = "cell graph")
	plot_scatter!(sf, [0.004, 0.012, 0.016, 0.03], fill(1.2e-3, 4); row = 1, col = 2, mode = "lines+markers",
		marker_symbol = "square", color = orange, legend = "quadratic transverse basis")
	for c in 1:2
		grid!(sf; row = 1, col = c, axis = :y, alpha = 0.2)
	end
	xlabel!(sf, "thickness factor \$\\delta\$"; row = 1, col = 1)
	xlabel!(sf, "assembly + eigensolve time (s)"; row = 1, col = 2)
	title!(sf, "nearly degenerate pair"; row = 1, col = 1)
	title!(sf, "heterogeneous ellipse"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	set_legend!(sf; position = :outside_bottom)
	sf
end
savefig(fig, joinpath(outdir, "topo_convergence.png"); scale = 2)
