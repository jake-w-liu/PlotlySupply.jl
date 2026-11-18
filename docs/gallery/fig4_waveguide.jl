# A six-panel waveguide figure: signed field, current with streamlines and mode content, two columns.
#
# Catalogue: field maps with shared colorbars, streamlines on a field, shared axes (the "FIG. 4" of
#   the user's waveguide paper; chama-python A6 / optical stacked maps).
# Replaces: plt.subplots(3, 2, sharex=True, sharey=True, height_ratios=[1, 1, 2.6]) with imshow,
#   Rectangle outlines, streamplot, one colorbar per row, panel letters and a legend on the left.
# 2.0: no workaround is needed: the two field rows are tight to the field (no padding from the
#   outlines or streamlines), one `shared_colorbar!` per row, equal aspect where the field is drawn.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

a = 15.8                                              # guide width (mm)
x = collect(range(-12, 126; length = 277))
y = collect(range(0, a; length = 41))
mix(xi, x0, w) = 0.5 * (1 + tanh((xi - x0) / w))
# A TE10 / TE20 mixture whose weights change at x0: U[ix, iy] at (x[ix], y[iy]).
function fields(x0)
	f(xi, p, q, k) = (1 - mix(xi, x0, 12)) * p + mix(xi, x0, 12) * q
	Ez = [f(xi, sin(pi * yj / a) * cos(0.28 * xi), sin(2pi * yj / a) * cos(0.33 * xi), 0) for xi in x, yj in y]
	Jx = [f(xi, sin(pi * yj / a) * sin(0.28 * xi), sin(2pi * yj / a) * sin(0.33 * xi), 0) for xi in x, yj in y]
	Jy = [f(xi, 0.7 * cos(pi * yj / a) * cos(0.28 * xi), 0.9 * cos(2pi * yj / a) * cos(0.33 * xi), 0) for xi in x, yj in y]
	return Ez ./ maximum(abs, Ez), Jx, Jy
end
pins = [(0, 2), (2.5, 2), (5, 2), (18, 2.5), (21.5, 2.5), (27, 1), (40, 4.5), (51, 2.5), (60, 1), (62, 1), (64, 4), (68, 4)]
bins = [(10, 1), (12, 6), (22, 8), (42, 1), (47, 1.5), (56, 1), (66, 3.5), (80, 1), (92, 2), (95, 4), (100, 3.5), (105, 1)]

fig = with_style(:aps) do
	sf = subplots(3, 2; sync = false, height_ratios = [1, 1, 2.6], shared_xaxes = true, shared_yaxes = true,
		width = journal_width(:aps; columns = 2, units = :px), height = 420)
	for (col, (x0, name)) in enumerate(((68.0, "15.05 GHz, conversion band"), (78.0, "17.55 GHz, pass band")))
		Ez, Jx, Jy = fields(x0)
		plot_heatmap!(sf, x, y, Ez; row = 1, col = col, colorscale = "RdBu_r", zrange = (-1, 1), grid = false)
		foreach(((p, w),) -> rectangle!(sf, p, a - 3, p + w, a; row = 1, col = col), pins)       # pins on the walls
		foreach(((p, w),) -> rectangle!(sf, p, 0, p + w, 3.5; row = 1, col = col), bins)
		Jmag = hypot.(Jx, Jy)
		plot_heatmap!(sf, x, y, Jmag ./ maximum(Jmag); row = 2, col = col, colorscale = "Blues", zrange = (0, 1), grid = false)
		plot_streamlines!(sf, x, y, Jx, Jy; row = 2, col = col, color = "black", linewidth = 0.6, density = 0.8, arrowsize = 4)
		c20 = 0.6 .* mix.(x, x0, 5) .* (1 .- mix.(x, 96, 3)) .+ (col == 1 ? mix.(x, 96, 3) : 0.0)
		b10 = 0.03 .* exp.(-((x .- 60) ./ 25) .^ 2) .* abs.(sin.(0.3 .* x))
		b20 = 0.15 .* exp.(-((x .- 65) ./ 20) .^ 2) .* abs.(sin.(0.25 .* x))
		plot_scatter!(sf, x, [1 .- c20, c20, b10, b20]; row = 3, col = col, color = ["#0072B2", "#D55E00", "#0072B2", "#D55E00"],
			dash = ["solid", "solid", "dot", "dash"], xrange = (-12, 126), yrange = (-0.03, 1.08),
			legend = col == 1 ? ["TE<sub>10</sub> forward", "TE<sub>20</sub> forward", "TE<sub>10</sub> backward", "TE<sub>20</sub> backward"] : "")
		xlabel!(sf, "position along the guide (mm)"; row = 3, col = col)
		title!(sf, name; row = 1, col = col)
	end
	foreach(r -> yticks!(sf, [0, a], ["0", "\$a\$"]; row = r, col = 1), 1:2)
	ylabel!(sf, "mode content"; row = 3, col = 1)
	shared_colorbar!(sf; cells = [(1, 1), (1, 2)], title = "\$E_z\$", title_side = :right)
	shared_colorbar!(sf; cells = [(2, 1), (2, 2)], coloraxis = "coloraxis2", title = "\$|J_s|\$", title_side = :right)
	colorbar!(sf; coloraxis = :shared, ticks = [-1, 0, 1])
	colorbar!(sf; coloraxis = "coloraxis2", ticks = [0, 1])
	panel_labels!(sf; cells = [(1, 1), (2, 1), (3, 1), (1, 2), (2, 2), (3, 2)], labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "fig4_waveguide.png"); scale = 2)
