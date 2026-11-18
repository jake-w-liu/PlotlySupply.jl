# Residual decay on a wide semilog axis with a leader label, and a min/max band of four curves.
#
# Catalogue: math-d3-d4 "shaded min/max band with bounding lines and annotated secondary curve".
# Replaces: semilogy over 1e-20 .. 1e3, ax.annotate(xytext=..., arrowprops={'arrowstyle': '-'}),
#   fill_between(alpha=.2) with bounding lines, a multi-line ax.text in axes coordinates,
#   a two-column frameless fig.legend above both panels.
# 2.0: `yticks = :decades` thins the labels of a 23-decade axis, `annotate!(offset = ...)` draws the
#   leader, `plot_band!` the band, `:outside_top` stacks the legend above the titles.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

colors = ["#0072B2", "#D55E00", "#009E73", "#CC79A7"]
markers = ["circle", "square", "triangle-up", "diamond"]
N = [12, 16, 20, 24, 32, 48, 64, 96, 128, 192, 256]
rates, offsets = [0.1168, 0.089, 0.1165, 0.1185], [1.0, 30.0, 1.2, 0.6]
labels = ["\$\\ell=1\$ TE, \$J=2\$", "\$\\ell=1\$ TE, \$J=6\$", "\$\\ell=1\$ TM, \$J=2\$", "\$\\ell=3\$ TE, \$J=2\$"]
residual(k) = offsets[k] .* 10.0 .^ (-rates[k] .* (N .- 12) ./ 1.5)
lognorm(k) = 0.72 .* N .+ 0.1k .* sqrt.(N) .- 4

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, per_subplot_legends = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.42)
	for k in 1:4
		plot_scatter!(sf, N, residual(k); row = 1, col = 1, color = colors[k], marker_symbol = markers[k],
			mode = "lines+markers", legend = labels[k], yscale = "log")
	end
	slow = 10.0 .^ (0.3 .- 0.016 .* (N .- 12))
	plot_scatter!(sf, N, slow; row = 1, col = 1, color = "gray", dash = "dot", marker_symbol = "x",
		mode = "lines+markers")
	annotate!(sf, 256, slow[end], "\$\\kappa=2+0.8i\$"; row = 1, col = 1, offset = (-60, -20), arrowhead = 0,
		color = "gray")
	yrange!(sf, (2e-20, 3e3); row = 1, col = 1)
	yticks!(sf, :decades; row = 1, col = 1)
	ylabel!(sf, "normalized residual \$\\eta_N\$"; row = 1, col = 1)
	# (b) the band between the pointwise minimum and maximum of the four norms
	norms = reduce(hcat, lognorm.(1:4))
	low, high = vec(minimum(norms; dims = 2)), vec(maximum(norms; dims = 2))
	plot_band!(sf, N, low, high; row = 1, col = 2, color = colors[1], opacity = 0.2)
	for y in (low, high)
		plot_scatter!(sf, N, y; row = 1, col = 2, color = colors[1], dash = "solid")
	end
	plot_scatter!(sf, N, low; row = 1, col = 2, mode = "markers", marker_size = 4, color = colors[1])
	annotate!(sf, 0.05, 0.9, "range across the four<br>main-frequency cases"; row = 1, col = 2, coords = :axes,
		showarrow = false, anchor = :topleft, color = colors[1])
	yrange!(sf, (0, 202); row = 1, col = 2)
	ylabel!(sf, "\$\\log_{10}\$ analytic norm \$A_N\$"; row = 1, col = 2)
	for c in 1:2
		xlabel!(sf, "polynomial degree \$N\$"; row = 1, col = c)
		xrange!(sf, (0, 265); row = 1, col = c)
		xticks!(sf, [0, 64, 128, 192, 256]; row = 1, col = c)
		spines!(sf; style = :open, row = 1, col = c)
		grid!(sf; axis = :y, alpha = 0.25, row = 1, col = c)
	end
	title!(sf, "residual decreases"; row = 1, col = 1, align = :left)
	title!(sf, "analytic norm grows"; row = 1, col = 2, align = :left)
	panel_labels!(sf; labels = :abc, format = "({})")
	set_legend!(sf; position = :outside_top, ncols = 2, legend_target = :figure)
	sf
end
savefig(fig, joinpath(outdir, "band_quasimodes.png"); scale = 2)
