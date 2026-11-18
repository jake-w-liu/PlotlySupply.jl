# A block diagram on hidden axes above a device drawing with shaded design regions.
#
# Catalogue: optical "block-diagram schematic strip", math-d3-d4 "schematic from patches".
# Replaces: ax.axis('off'), FancyBboxPatch / FancyArrowPatch, a gridspec row with
#   height_ratios, axvspan, fill_between, dotted and solid edges and a legend above the axes.
# 2.0: `rectangle!(rounded = ...)`, `arrow!`, `annotate!(anchor = ...)`, `vspan!`, `plot_band!`,
#   `panel_labels!`; the legend is stacked above the panel by the layout engine.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
fill_c, edge_c, ink = "#f0f3f6", "#85939f", "#34495e"

L, side = 18.0, 5.0
x = collect(range(0, L; length = 1801))
inside(t) = side < t < L - side
bump(t, c, s) = exp(-((t - c) / s)^2)
hi0 = [inside(t) ? 1.5 : 0.9 for t in x]
lo0 = fill(-0.9, length(x))
hi = hi0 .+ [inside(t) ? 0.0 : 0.3bump(t, 3, 1.2) + 0.12bump(t, 15, 1.5) for t in x]
lo = lo0 .+ [inside(t) ? 0.0 : -0.2bump(t, 3.7, 0.4) + 0.35bump(t, 15.5, 0.8) for t in x]

fig = with_style(:ieee) do
	sf = subplots(2, 1; sync = false, height_ratios = [0.75, 1])
	figsize!(sf, :ieee; columns = 2, aspect = 0.5)
	A = (row = 1, col = 1)
	plot_scatter!(sf, Float64[], Float64[]; A..., xrange = (0, 10), yrange = (0, 1.5), equalar = true)
	for (x0, y0, w, h, body, caption) in ((1.35, 0.30, 1.0, 0.9, "\$\\mathbf{V}\$", "encoder"),
		(3.60, 0.25, 2.7, 1.0, "section \$\\mathbf{T}(\\omega)\$", "three guided modes"),
		(7.55, 0.30, 1.0, 0.9, "\$\\mathbf{W}^{\\mathsf{H}}\$", "decoder"))
		rectangle!(sf, x0, y0, x0 + w, y0 + h; A..., rounded = 0.08, fillcolor = fill_c, edgecolor = edge_c)
		annotate!(sf, x0 + w / 2, y0 + h / 2, body; A..., showarrow = false)
		annotate!(sf, x0 + w / 2, y0 - 0.05, caption; A..., showarrow = false, anchor = :top)
	end
	for (ys, x1, x2) in (((0.95, 0.55), 0.55, 1.35), ((0.95, 0.55), 8.55, 9.55),
		((0.45, 0.75, 1.05), 2.35, 3.6), ((0.45, 0.75, 1.05), 6.3, 7.55)), y in ys
		arrow!(sf, x1, y, x2, y; A..., color = ink)
	end
	annotate!(sf, 0.3, 0.95, "\$u_1\$"; A..., showarrow = false)
	annotate!(sf, 0.3, 0.55, "\$u_2\$"; A..., showarrow = false)
	annotate!(sf, 9.1, 1.36, "\$a\\,e^{-i\\omega\\tau}u_k\$"; A..., showarrow = false)
	axis_off!(sf; A...)
	# (b) the device: design regions below the data, body as a band, initial and designed edges
	B = (row = 2, col = 1)
	foreach(x0 -> vspan!(sf, x0, x0 + side; B..., color = "#DCEAF5", opacity = 1), (0, L - side))
	plot_band!(sf, x, lo, hi; B..., color = "#E6E6E6", opacity = 1)
	for e in (lo0, hi0)
		plot_scatter!(sf, x, e; B..., color = "gray", dash = "dot")
	end
	for e in (lo, hi)
		plot_scatter!(sf, x, e; B..., color = "black", dash = "solid")
	end
	legend_entry!(sf, "initial edges"; B..., color = "gray", dash = "dot")
	legend_entry!(sf, "designed edges"; B..., color = "black")
	legend_entry!(sf, "design regions"; B..., patch = true, color = "#DCEAF5")
	set_legend!(sf; B..., position = :outside_top, ncols = 3)
	xrange!(sf, (0, L); B...)
	xlabel!(sf, "\$x\$ (\$\\mu\$m)"; B...)
	ylabel!(sf, "\$y\$ (\$\\mu\$m)"; B...)
	spines!(sf; B..., style = :open)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "block_diagram.png"); scale = 2)
