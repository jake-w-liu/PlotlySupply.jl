# A binary pixel pattern drawn cell by cell with wave-vector arrows, and the same pattern as image rows.
#
# Catalogue: optical "pixel-pattern / domain map via imshow with ListedColormap + Rectangle cell
#   drawing + wavevector arrows (device top view)".
# Replaces: Rectangle patches per pixel, FancyArrowPatch fans, a rotated '<->' dimension annotation,
#   imshow(cmap=ListedColormap, vmin=-1.5, vmax=1.5), row labels as y ticks, a three-patch legend.
# 2.0: `rectangle!`/`arrow!` in data units on an `equalar` axis, `discrete_colormap` for the
#   ListedColormap, `plot_heatmap!` on pixel EDGES, `annotate!(textangle = ...)`, patch legend entries.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
dark, grey = "#202020", "#999999"
minus_c, hole_c, plus_c, plus_dark = "#f7f7f7", "#a9adb3", "#c6d6ea", "#2f5f9e"

h, W = 0.2, 1.8                                      # pixel pitch and film width (um)
nx, ny = 21, Int(W / h)
pattern = [sign(sin(1.7i + 2.3j + 0.4i * j) + 1e-9) for i in 1:nx, j in 1:ny]   # deterministic +-1 pattern
x0 = 4.0

fig = with_style(:ieee) do
	sf = subplots(2, 1; sync = false, height_ratios = [1.4, 1])
	figsize!(sf, :ieee; columns = 2, aspect = 0.62)
	A = (row = 1, col = 1)
	plot_scatter!(sf, Float64[], Float64[]; A..., xrange = (0, 11.4), yrange = (-0.6, 2.2), equalar = true)
	for i in 1:nx, j in 1:ny                         # one rectangle per cell; the last five columns sit past a break
		x = x0 + (i - 1) * h + (i > 16 ? 0.6 : 0.0)
		rectangle!(sf, x, (j - 1) * h, x + h, j * h; A..., fillcolor = pattern[i, j] > 0 ? plus_c : minus_c,
			edgecolor = "none")
	end
	foreach(((hx, hy, hw),) -> rectangle!(sf, hx, hy, hx + hw, hy + hw; A..., fillcolor = hole_c, edgecolor = dark),
		((4.1, 0.2, 0.4), (4.9, 0.6, 0.6), (6.3, 0.8, 0.5)))
	rectangle!(sf, x0, 0, x0 + 16h, W; A..., edgecolor = grey)
	rectangle!(sf, x0 + 16h + 0.6, 0, x0 + 21h + 0.6, W; A..., edgecolor = grey)
	foreach(y -> annotate!(sf, x0 + 16h + 0.3, y, "//"; A..., showarrow = false, color = grey), (-0.05, W + 0.05))
	annotate!(sf, x0, -0.12, "x = 0"; A..., showarrow = false, anchor = :top)
	annotate!(sf, x0 + 21h + 0.6, -0.12, "x = L = 48 \$\\mu\$m"; A..., showarrow = false, anchor = :top)
	arrow!(sf, x0 - 0.15, 0, x0 - 0.15, W; A..., head = :both, color = grey)
	annotate!(sf, x0 - 0.3, W / 2, "W = 1.8 \$\\mu\$m"; A..., showarrow = false, textangle = -90, anchor = :right)
	for (c, ang) in (("#0072B2", 27.0), ("#D55E00", 21.6)), s in (1, -1)    # the two input wavelengths
		arrow!(sf, 0.3, W / 2, 0.3 + 1.2cosd(ang), W / 2 + s * 1.2sind(ang); A..., color = c)
	end
	for ang in range(110, 250; length = 11)           # backward orders, grey
		arrow!(sf, 3.3, W / 2, 3.3 + 0.7cosd(ang), W / 2 + 0.7sind(ang); A..., color = "#b9bec4")
	end
	xr = x0 + 21h + 1.0
	for ang in range(-70, 70; length = 11)           # generated orders; the selected ones are dark
		selected = abs(abs(ang) - 14) < 1
		arrow!(sf, xr, W / 2, xr + 0.8cosd(ang), W / 2 + 0.8sind(ang); A..., color = selected ? dark : "#b9bec4")
	end
	annotate!(sf, xr + 0.95, W / 2 + 0.25, "R+1"; A..., showarrow = false, anchor = :left)
	annotate!(sf, xr + 0.95, W / 2 - 0.25, "R−1"; A..., showarrow = false, anchor = :left)
	axis_off!(sf; A...)
	# (b) the pattern as two image rows with the ListedColormap look
	per = 120
	rows = [[sign(sin(0.9i + 1.3j + 5k) + 1e-9) for i in 1:per, j in 1:9] for k in 1:2]
	rows[1][1:3, 1:4] .= 0; rows[1][8:12, 5:9] .= 0                     # holes are 0
	cmap = discrete_colormap([minus_c, hole_c, plus_dark])
	xs = range(0, 24; length = per + 1)                                  # pixel EDGES
	plot_heatmap!(sf, xs, range(1.15, 2.05; length = 10), rows[1]; row = 2, col = 1, colorscale = cmap,
		crange = (-1.5, 1.5), showscale = false)
	plot_heatmap!(sf, xs, range(0.0, 0.9; length = 10), rows[2]; row = 2, col = 1, colorscale = cmap,
		crange = (-1.5, 1.5), showscale = false)
	yticks!(sf, [1.6, 0.45], ["0–24", "24–48"]; row = 2, col = 1)
	xlabel!(sf, "x from the start of each row (\$\\mu\$m)"; row = 2, col = 1)
	legend_entry!(sf, "+1"; row = 2, col = 1, patch = true, color = plus_dark)
	legend_entry!(sf, "−1"; row = 2, col = 1, patch = true, color = minus_c, marker_line_color = grey, marker_line_width = 0.5)
	legend_entry!(sf, "hole"; row = 2, col = 1, patch = true, color = hole_c, marker_line_color = grey, marker_line_width = 0.5)
	set_legend!(sf; row = 2, col = 1, position = :outside_top, ncols = 3)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "optical_pixelmap.png"); scale = 2)
