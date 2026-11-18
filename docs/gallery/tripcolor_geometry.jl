# A geometry sketch beside a Gouraud-shaded field on an unstructured triangle mesh.
#
# Catalogue: math-d3-d4 "FEM triangulation field map: tripcolor with Gouraud shading, mask, log10
#   values, white overlay outlines, colorbar" and "schematic from patches".
# Replaces: ax.tripcolor(shading='gouraud') with a Triangulation mask, Circle / Polygon patches,
#   ax.annotate with a plain leader, white overlay outlines and a shortened colorbar, both panels
#   with set_aspect('equal').
# 2.0: `plot_tripcolor!(mask = ...)`, `equalar = true`, `polygon!`/`circle!`, `annotate!(anchor = ...)`
#   and a cell colorbar that is as tall as the fitted plot.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

# metal wedge outline: corner at the origin, vertical edge, rounded cap, back along y = 0
t = range(0, 1; length = 120)
bx = vcat(0.0, 0.0, 1.3 .* sin.(π / 2 .* t) .^ (2 / 3), 0.0)
by = vcat(0.0, 1.27, 0.05 .+ 1.22 .* cos.(π / 2 .* t) .^ (2 / 3), 0.0)

# structured triangulation of the field window
xs, ys = range(-1.35, 1.4; length = 70), range(-1.05, 1.45; length = 64)
px, py = [x for x in xs, y in ys][:], [y for x in xs, y in ys][:]
id(i, j) = (j - 1) * length(xs) + i
tris = [tri for j in 1:length(ys)-1 for i in 1:length(xs)-1 for tri in
	([id(i, j), id(i + 1, j), id(i + 1, j + 1)], [id(i, j), id(i + 1, j + 1), id(i, j + 1)])]
H = @. 0.04 * exp(-((px + 0.75)^2 + (py - 0.35)^2) / 0.08) + 1e-3 * (1 + 0.3 * sin(2px) * cos(py)) -
	9e-4 * exp(-((px - 1.35)^2 + (py + 0.22)^2) / 0.02)
vals = log10.(max.(abs.(H), 1e-12))
mask = [hypot(sum(px[tr]) / 3, sum(py[tr]) / 3) < 0.05 for tr in tris]    # triangles at the corner

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.5)
	A = (row = 1, col = 1)
	plot_scatter!(sf, [0.0], [0.0]; A..., mode = "markers", color = "black", xrange = (-3.15, 3.15),
		yrange = (-3.15, 3.15), equalar = true, xlabel = "\$x\$", ylabel = "\$y\$", grid = false)
	circle!(sf, 0, 0, 3; A..., edgecolor = "gray")
	polygon!(sf, bx, by; A..., fillcolor = "#CED9E8", edgecolor = "black")
	circle!(sf, -0.75, 0.35, 0.4; A..., fillcolor = "#80B596", edgecolor = "#226644", opacity = 0.5)
	circle!(sf, 0, 0, 0.25; A..., edgecolor = "gray", dash = "dash")
	arrow!(sf, 0.45, -0.55, 0, 0; A..., head = :none)
	annotate!(sf, 0.45, -0.65, "one corner"; A..., showarrow = false, anchor = :topleft)
	annotate!(sf, -2.4, 0.85, "source support"; A..., showarrow = false, anchor = :bottomleft)
	annotate!(sf, -0.7, 2.4, "outgoing DtN"; A..., showarrow = false, anchor = :bottomleft)
	annotate!(sf, 0.42, 0.55, "metal"; A..., showarrow = false, anchor = :bottomleft)
	B = (row = 1, col = 2)
	plot_tripcolor!(sf, px, py, tris, vals; B..., shading = :gouraud, mask = mask, colorscale = "cividis",
		crange = (-4.5, -1.4), xrange = (-1.35, 1.4), yrange = (-1.05, 1.45), equalar = true,
		xlabel = "\$x\$", ylabel = "\$y\$", grid = false)
	plot_scatter!(sf, bx, by; B..., color = "white", dash = "solid")
	circle!(sf, -0.75, 0.35, 0.4; B..., edgecolor = "white", dash = "dash")
	colorbar!(sf; B..., len = 0.82, title = "\$\\log_{10}|H|\$", title_side = :right)
	title!(sf, "open one-corner geometry"; A...)
	title!(sf, "FEM field, \$z=0.8-0.04i\$"; B...)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "tripcolor_geometry.png"); scale = 2)
