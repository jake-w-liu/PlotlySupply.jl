# A heatmap with two labels in every cell, beside a log-log companion.
#
# Catalogue: topo "annotated heatmap (imshow) with per-cell mathtext labels and colorbar".
# Replaces: imshow with categorical ticks, ax.text in every cell (white on dark cells, black on light),
#   a colorbar with fixed ticks and a rotated label, width_ratios with a companion panel.
# 2.0: `plot_heatmap!(text = ...)` writes the cell labels (the colour of each follows the cell's
#   luminance), `colorbar!(ticks = ...)`, and the categories are the x ticks themselves.
using PlotlySupply

set_default_mathtext!(true; inherit_text_font = true)    # text parts of math labels stay in the sans font

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, purple = "#0072B2", "#CC79A7"

cases = ["circular", "elliptic", "heterogeneous"]
deltas = [0.05, 0.08, 0.12, 0.18, 0.24, 0.32]
err = [5.6e-11 1.4e-10 1.9e-10; 1.1e-9 3.3e-9 4.6e-9; 1.9e-8 6.3e-8 9.7e-8;
	3.9e-7 1.4e-6 2.4e-6; 3.4e-6 1.3e-5 2.8e-5; 2.9e-5 1.3e-4 4.4e-4]       # [delta, case]
factor = [3.1e6 1.8e6 1.0e6; 4.3e5 2.0e5 1.2e5; 5.8e4 2.5e4 1.4e4;
	7.3e3 3.0e3 1.7e3; 1.8e3 705 348; 472 165 58]

# Heatmap cell text is plain text (plotly does not typeset TeX there): the exponent is <sup>.
function sci(v)
	e = floor(Int, log10(v))
	return "$(round(v / 10.0^e; digits = 1))×10<sup>$(replace(string(e), "-" => "−"))</sup>"
end
paren(v) = v >= 1e3 ? "($(sci(v)))" : "($(round(Int, v)))"
labels = permutedims([sci(err[i, j]) * "<br>" * paren(factor[i, j]) for i in eachindex(deltas), j in eachindex(cases)])

d = [0.075, 0.1, 0.15, 0.2, 0.3, 0.4]
fig = with_style(:elsevier) do
	sf = subplots(1, 2; sync = false, width_ratios = [1, 1.12])
	figsize!(sf, :elsevier; columns = 2, aspect = 0.42)
	plot_heatmap!(sf, cases, string.(deltas), permutedims(log10.(err)); row = 1, col = 1, colorscale = "viridis",
		crange = (-11, -2), text = labels, textsize = 6)               # U[ix, iy]: x = case, y = delta
	colorbar!(sf; row = 1, col = 1, ticks = [-11, -8, -5, -2], title = "\$\\log_{10}\$ error", title_side = :right)
	ylabel!(sf, "thickness factor \$\\delta\$"; row = 1, col = 1)
	title!(sf, "graph error and reduction factor"; row = 1, col = 1)
	plot_scatter!(sf, d, 1.1e-7 .* (d ./ 0.4) .^ 6; row = 1, col = 2, xscale = "log", yscale = "log",
		xticks = :decades, mode = "lines+markers", marker_symbol = "circle", color = blue, legend = "graph eigenvalue error")
	plot_scatter!(sf, d, 3e-5 .* (d ./ 0.4) .^ 4; row = 1, col = 2, mode = "lines+markers", marker_symbol = "square",
		color = purple, legend = "doublet projector error")
	xticks!(sf, [0.075, 0.1, 0.2, 0.4], ["0.075", "0.1", "0.2", "0.4"]; row = 1, col = 2)
	grid!(sf; row = 1, col = 2, axis = :y, alpha = 0.2)
	xlabel!(sf, "thickness factor \$\\delta\$"; row = 1, col = 2)
	ylabel!(sf, "error"; row = 1, col = 2)
	title!(sf, "nearly degenerate pair"; row = 1, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "topo_annotated_heatmap.png"); scale = 2)
set_default_mathtext!()
