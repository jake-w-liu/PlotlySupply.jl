# A single-colour 3-D geometry sketch with a label at a 3-D point.
#
# Catalogue: chama-python A8, chama-audit F.
# Replaces: Poly3DCollection in one colour with black edges, set_box_aspect, view_init,
#   set_yticks([-20, 0, 20]) and ax.text(48, 5, 60, ' C').
# 2.0: `plot_polygons3d` with a constant colour, `aspectmode = "data"` for true proportions,
#   `annotate!` with a 3-D position.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

# Cook's membrane: trapezoid (0,0)-(48,44)-(48,60)-(0,44) in x-z, extruded 10 mm in y.
t = 5.0
xz = [(0.0, 0.0), (48.0, 44.0), (48.0, 60.0), (0.0, 44.0)]
x = repeat([p[1] for p in xz], 2)
y = vcat(fill(-t, 4), fill(t, 4))
z = repeat([p[2] for p in xz], 2)
faces = [1 2 3 4; 5 8 7 6; 1 5 6 2; 2 6 7 3; 3 7 8 4; 4 8 5 1]

fig = with_style(:ieee) do
	fig = plot_polygons3d(x, y, z, faces; color = "#6baed6", edgecolor = "black", edgewidth = 2,
		xlabel = "x (mm)", ylabel = "y (mm)", zlabel = "z (mm)", aspectmode = "data",
		view = (20, -120))
	scene!(fig; yticks = [-20, 0, 20])          # keeps the ticks of the thin direction apart
	annotate!(fig, 48.0, 5.0, 60.0, " C"; showarrow = false)
	figsize!(fig, :ieee; columns = 1, aspect = 1.0)
	fig
end
savefig(fig, joinpath(outdir, "chama_a8_geometry_sketch.png"); scale = 2)
