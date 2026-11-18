# A mesh schematic beside a time trace with sampled hollow markers and an energy plot.
#
# Catalogue: math-d3-d4 "time-series / dual-panel with sci-notation offset text, equal-aspect mesh
#   schematic inline (3-panel strip)".
# Replaces: PolyCollection of triangles by material, Rectangle patches, ax.plot(t[::16], ..., 'o',
#   mfc='none'), ticklabel_format(style='sci') offset text and a legend placed in axes fractions.
# 2.0: `plot_polygons!` takes triangle lists, `markevery`, SI/power tick labels carry the exponent
#   (no offset text), and the default legend placement avoids the traces.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, red = "#0072B2", "#D55E00"

# (a) 8 x 8 grid of the square [-1, 1]^2 split into triangles; the upper right quadrant is metal.
n = 8
xs = range(-1, 1; length = n + 1)
X, Y = [x for x in xs, y in xs][:], [y for x in xs, y in xs][:]
id(i, j) = (j - 1) * (n + 1) + i
metal, vacuum = Vector{Int}[], Vector{Int}[]
for j in 1:n, i in 1:n, tri in ([id(i, j), id(i + 1, j), id(i + 1, j + 1)], [id(i, j), id(i + 1, j + 1), id(i, j + 1)])
	push!(sum(X[tri]) > 0 && sum(Y[tri]) > 0 ? metal : vacuum, tri)
end

t = collect(range(0, 8; length = 801))
probe = 0.8e-4 .* exp.(-0.3 .* t) .* (0.6 .* sin.(9 .* t) .+ 0.3 .* sin.(4.3 .* t) .+ 0.25 .* sin.(13 .* t))
E = 1e-5 .* (2.8 .+ 0.3 .* sin.(3 .* t) .+ 0.6 .* exp.(-((t .- 4) .^ 2) ./ 0.4)) .* (1 .- exp.(-6 .* t))
Ec = 1e-5 .* (0.3 .+ 0.1 .* sin.(2 .* t)) .* (1 .- exp.(-6 .* t))

fig = with_style(:ieee) do
	sf = subplots(1, 3; sync = false, width_ratios = [0.9, 1, 1])
	figsize!(sf, :ieee; columns = 2, aspect = 0.38)
	A = (row = 1, col = 1)
	plot_polygons!(sf, X, Y, vacuum; A..., color = "#FAFAFA", edgecolor = "#b8b8b8", edgewidth = 0.4, equalar = true)
	plot_polygons!(sf, X, Y, metal; A..., color = "#D4E0F0", edgecolor = "#b8b8b8", edgewidth = 0.4)
	rectangle!(sf, -1, -0.5, -0.5, 0; A..., fillcolor = "#d9edda", edgecolor = "#388443", opacity = 0.65)
	rectangle!(sf, -0.5, -0.5, 0.5, 0.5; A..., edgecolor = red, dash = "dash")
	plot_scatter!(sf, [0.0], [0.0]; A..., mode = "markers", color = red)
	annotate!(sf, 0.47, 0.73, "Drude metal"; A..., showarrow = false, anchor = :bottom)
	annotate!(sf, -0.73, -0.25, "Source"; A..., showarrow = false, anchor = :bottom)
	annotate!(sf, -0.44, 0.37, "Corner patch"; A..., showarrow = false, anchor = :left, color = red)
	xticks!(sf, [-1, 0, 1]; A...)
	yticks!(sf, [-1, 0, 1]; A...)
	xlabel!(sf, "\$x\$"; A...)
	ylabel!(sf, "\$y\$"; A...)
	plot_scatter!(sf, t, probe; row = 1, col = 2, color = blue, dash = "solid", legend = "full Maxwell FEM")
	plot_scatter!(sf, t[1:16:end], probe[1:16:end]; row = 1, col = 2, mode = "markers", marker_symbol = "circle-open",
		color = red, legend = "corner memory")
	ylabel!(sf, "\$\\mathrm{Re}\\,(F_E,E_h)\$"; row = 1, col = 2)
	plot_scatter!(sf, t, E; row = 1, col = 3, color = blue, dash = "solid", legend = "total physical energy")
	plot_scatter!(sf, t, Ec; row = 1, col = 3, color = red, dash = "solid", legend = "energy in corner patch")
	ylabel!(sf, "energy"; row = 1, col = 3)
	set_legend!(sf; row = 1, col = 3, position = (0.5, 0.5), xanchor = "center", yanchor = "middle")    # between the two curves
	for c in 2:3
		yticks!(sf; row = 1, col = c, exponentformat = "power")
		xlabel!(sf, "\$t\$"; row = 1, col = c)
		grid!(sf; alpha = 0.2, row = 1, col = c)
	end
	title!(sf, "Maxwell cavity"; A...)
	title!(sf, "bulk observation"; row = 1, col = 2)
	title!(sf, "physical energy"; row = 1, col = 3)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "mesh_timeseries_strip.png"); scale = 2)
