# A waveguide device schematic with hatched walls, design strips and dimension arrows, then to scale.
#
# Catalogue: optical "multi-panel schematic of device geometry" (Rectangles, hatch ticks,
#   annotate dimension arrows).
# Replaces: ax.axis('off') with set_aspect('equal'), Rectangle patches with dashed edges, a LineCollection
#   of hatch ticks, ax.annotate('<->') dimension arrows and a right-aligned multi-line ax.text.
# 2.0: `equalar = true`, `rectangle!(layer = "below")`, one `plot_segments!` call for the hatch,
#   `arrow!(head = :both)`, and `annotate!(anchor = ..., align = ...)`; no position arithmetic.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
navy, teal, orange, grey, strip = "#26456E", "#009E73", "#D55E00", "#7F8993", "#EEF2F6"
L, W = 4.0, 1.0
xs = [0.9, 1.8, 2.7]                                     # rectangle centres x_j
yup, ylo, hh = 0.75, 0.25, 0.1                           # strip centres and half height

fig = with_style(:ieee) do
	sf = subplots(2, 1; sync = false, height_ratios = [1.1, 0.9])
	figsize!(sf, :ieee; columns = 2, aspect = 0.62)
	A = (row = 1, col = 1)
	plot_scatter!(sf, Float64[], Float64[]; A..., xrange = (-0.6, L + 1.3), yrange = (-0.3, W + 0.12), equalar = true)
	for yc in (yup, ylo)                                 # shaded design strips with dashed rectangles
		rectangle!(sf, 0.35, yc - hh, L + 0.05, yc + hh; A..., fillcolor = strip, edgecolor = "gray", dash = "dot",
			layer = "below")
		foreach(xc -> rectangle!(sf, xc - 0.13, yc - hh, xc + 0.13, yc + hh; A..., edgecolor = grey, dash = "3px,2px"), xs)
	end
	for (xc, yc, half, label) in ((xs[2], yup, 0.06, "\$w_2^-\$"), (xs[1], ylo, 0.09, "\$w_1^+\$"), (xs[3], ylo, 0.04, "\$w_3^+\$"))
		rectangle!(sf, xc - half, yc - hh, xc + half, yc + hh; A..., fillcolor = teal, edgecolor = teal)
		annotate!(sf, xc + 0.16, yc, label; A..., showarrow = false, anchor = :left, color = teal)
	end
	plot_segments!(sf, -0.35, [0.0, W], L + 0.35, [0.0, W]; A..., color = "black", linewidth = 3, dash = "solid")   # walls
	xh = collect(-0.3:0.12:(L + 0.25))                                                                # hatch ticks
	plot_segments!(sf, [xh; xh], [fill(W, length(xh)); zeros(length(xh))], [xh; xh] .+ 0.07,
		[fill(W + 0.06, length(xh)); fill(-0.06, length(xh))]; A..., color = "black", linewidth = 0.6, dash = "solid")
	foreach(yw -> annotate!(sf, L + 0.45, yw, "wall, \$u=0\$"; A..., showarrow = false, anchor = :left), (0.0, W))
	arrow!(sf, -0.05, 0.585, 0.5, 0.585; A..., color = navy)
	arrow!(sf, 0.5, 0.415, -0.05, 0.415; A..., color = orange)
	annotate!(sf, 0.6, 0.585, "mode 1 incident"; A..., showarrow = false, anchor = :left, color = navy)
	annotate!(sf, 0.6, 0.415, "mode 2 reflected"; A..., showarrow = false, anchor = :left, color = orange)
	arrow!(sf, -0.22, 0, -0.22, W; A..., head = :both)
	annotate!(sf, -0.3, W / 2, "\$W\$"; A..., showarrow = false, anchor = :right)
	axis_off!(sf; A...)
	# (b) the design to scale: widths of the occupied rectangles against their limits
	B = (row = 2, col = 1)
	foreach(yw -> hline!(sf, yw; B..., color = "black", linewidth = 2), (0.0, W))
	widths = [0.0096, 0.004, 0.006, 0.003, 0.008, 0.005]
	for (k, xc) in enumerate((0.45, 1.45, 2.45)), (m, yc) in enumerate((yup, ylo))
		for dx in (-0.05, 0.05)
			rectangle!(sf, xc + dx - 0.04, yc - hh, xc + dx + 0.04, yc + hh; B..., edgecolor = grey, dash = "3px,2px")
		end
		w, xo = widths[2(k - 1) + m] * 2, xc + (iseven(k + m) ? 0.05 : -0.05)
		rectangle!(sf, xo - w / 2, yc - hh, xo + w / 2, yc + hh; B..., fillcolor = teal, edgecolor = teal)
	end
	annotate!(sf, 3.95, 0.5, "6 of 12 rectangles occupied<br>largest width 9.6 nm<br>dashed: width limit 80 nm";
		B..., showarrow = false, anchor = :right, align = "right")
	plot_scatter!(sf, Float64[], Float64[]; B..., xrange = (0, L), yrange = (-0.02, W + 0.02), equalar = true)
	xlabel!(sf, "\$x\$ (\$\\mu\$m)"; B...)
	ylabel!(sf, "\$y\$ (\$\\mu\$m)"; B...)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "device_geometry.png"); scale = 2)
