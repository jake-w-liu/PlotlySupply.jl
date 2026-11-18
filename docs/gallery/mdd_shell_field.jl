# A polar field drawn on a mirrored meridional disk with circles and a text core, beside branches.
#
# Catalogue: math-deepdebug 4, math-d3-d4 "polar-to-Cartesian field map" (meridional map).
# Replaces: pcolormesh on a (r, theta) mesh mirrored to a full disk (magma, fixed 0..1), a narrow
#   colorbar, Circle patches, a multi-line ax.text in the core, open/filled branch markers.
# 2.0: `plot_pcolormesh!` takes the curvilinear node arrays, `equalar = true` keeps the disk round,
#   `annotate!(fit = ...)` sizes the core text to the core, `colorbar!` keeps its bar inside the cell.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, orange = "#0072B2", "#D55E00"

redges = collect(range(1.0, 2.0; length = 41))
tedges = collect(range(0.0, π; length = 121))
R = [r for r in redges, t in tedges]
T = [t for r in redges, t in tedges]
rc = (redges[1:end-1] .+ redges[2:end]) ./ 2
tc = (tedges[1:end-1] .+ tedges[2:end]) ./ 2
F = [sin(π * (r - 1)) * abs(sin(t)) * (0.55 + 0.45 * cos(2t)^2) * (1 - 0.25 * cos(4t)) for r in rc, t in tc]
F ./= maximum(F)

# Two resonance branches: open marker at the start, filled marker at the end.
branches = [([1.65, 1.68, 1.72, 1.78, 1.85, 1.91], [0.455, 0.472, 0.482, 0.481, 0.47, 0.467], blue, "circle", "from \$\\ell=1\$"),
	([2.145, 2.11, 2.075, 2.025, 1.97, 1.93], [0.19, 0.182, 0.188, 0.213, 0.24, 0.259], orange, "square", "from \$\\ell=3\$")]

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, width_ratios = [1, 1.1])
	figsize!(sf, :ieee; columns = 2, aspect = 0.5)
	for sgn in (-1, 1)                          # the half disk and its mirror image
		plot_pcolormesh!(sf, sgn .* R .* sin.(T), R .* cos.(T), F; row = 1, col = 1, colorscale = "magma",
			crange = (0, 1), showscale = sgn == 1, equalar = true)
	end
	circle!(sf, 0, 0, 2.0; edgecolor = "gray", row = 1, col = 1)
	circle!(sf, 0, 0, 1.5; edgecolor = "#E6D3B3", dash = "dash", row = 1, col = 1)
	circle!(sf, 0, 0, 1.0; fillcolor = "#EFF1F3", edgecolor = "gray", row = 1, col = 1)
	annotate!(sf, 0, 0, "PEC core<br>\$\\ell=1\$: 47.4%<br>\$\\ell=3\$: 50.1%"; row = 1, col = 1,
		showarrow = false, fit = (1.7, 1.4))      # fit the text into the core
	colorbar!(sf; row = 1, col = 1, title = "\$|E_\\phi|/\\max|E_\\phi|\$", title_side = :right, ticks = [0, 0.5, 1])
	xticks!(sf, [-2, 0, 2]; row = 1, col = 1)
	yticks!(sf, [-2, 0, 2]; row = 1, col = 1)
	xlabel!(sf, "\$x/a\$"; row = 1, col = 1)
	ylabel!(sf, "\$z/a\$"; row = 1, col = 1)
	title!(sf, "coupled field at \$\\eta=3\$"; row = 1, col = 1)
	for (x, y, c, m, label) in branches
		plot_scatter!(sf, x, y; row = 1, col = 2, mode = "lines+markers", color = c, marker_symbol = m,
			marker_size = 4, legend = label)
		plot_scatter!(sf, x[1:1], y[1:1]; row = 1, col = 2, mode = "markers", color = c,
			marker_symbol = m * "-open", marker_size = 8)
		annotate!(sf, x[1], y[1], "\$\\eta=0\$"; row = 1, col = 2, showarrow = false, offset = (-22, 14), color = c)
		annotate!(sf, x[end], y[end], "\$\\eta=3\$"; row = 1, col = 2, showarrow = false, offset = (x[end] > x[1] ? 22 : -24, x[end] > x[1] ? -12 : 14), color = c)
	end
	ellipse!(sf, 1.91, 0.355, 0.235, 0.185; edgecolor = "gray", dash = "dot", row = 1, col = 2)
	xrange!(sf, (1.6, 2.2); row = 1, col = 2)
	yrange!(sf, (0.15, 0.55); row = 1, col = 2)
	spines!(sf; style = :open, row = 1, col = 2)
	xlabel!(sf, "\$\\mathrm{Re}(ka)\$"; row = 1, col = 2)
	ylabel!(sf, "\$\\mathrm{Im}(ka)\$"; row = 1, col = 2)
	title!(sf, "two resonance branches"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "mdd_shell_field.png"); scale = 2)
