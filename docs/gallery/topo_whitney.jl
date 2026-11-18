# Whitney basis functions on a reference tetrahedron: edges, a face, vector fields and a normal.
#
# Catalogue: topo "3D schematic: tetrahedron with Whitney basis quiver, custom Arrow3D and
#   Poly3DCollection triangle".
# Replaces: orthographic 3-D axes with axis off, grey edges, a translucent face, ax.quiver of small
#   arrows, custom Arrow3D (FancyArrowPatch) for oriented edges, a bold n label, text2D captions.
# 2.0: `plot_quiver3d!(style = :arrow)` for every arrow, `view!(projection = "orthographic")`,
#   `scene!(showaxis = false)`, `annotate!` in 3-D and axes-fraction captions.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, green, dark, edge = "#0072B2", "#009E73", "#2F3236", "#9AA0A6"

V = [0.0 0 0; 1 0 0; 0 1 0; 0 0 1]                    # vertices 0..3 (rows)
λ(p) = [1 - sum(p), p[1], p[2], p[3]]                  # barycentric coordinates
∇λ = [[-1.0, -1, -1], [1.0, 0, 0], [0.0, 1, 0], [0.0, 0, 1]]
cross3(a, b) = [a[2]b[3] - a[3]b[2], a[3]b[1] - a[1]b[3], a[1]b[2] - a[2]b[1]]
w01(p) = (l = λ(p); l[1] .* ∇λ[2] .- l[2] .* ∇λ[1])   # edge (Whitney 1-form) basis
w012(p) = (l = λ(p); 2 .* (l[1] .* cross3(∇λ[2], ∇λ[3]) .+ l[2] .* cross3(∇λ[3], ∇λ[1]) .+
	l[3] .* cross3(∇λ[1], ∇λ[2])))                    # face (Whitney 2-form) basis
pts = [[a, b, c] ./ 6 for a in 1:4 for b in 1:4 for c in 1:4 if a + b + c <= 5]
tet_edges = [1 2; 1 3; 1 4; 2 3; 2 4; 3 4]
xyz(v) = (getindex.(v, 1), getindex.(v, 2), getindex.(v, 3))

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene")],
		width = journal_width(:ieee; columns = 2, units = :px), height = 250)
	for (k, (name, field, color, scale, path, caption)) in enumerate((
		("edge basis \$w_{01}\$", w01, blue, 0.22, [1, 2], "\$\\int_{[0,1]} w_{01} = 1\$"),
		("face basis \$w_{012}\$", w012, green, 0.12, [1, 2, 3, 1], "\$\\int_{[0,1,2]} w_{012} = 1\$")))
		plot_segments3d!(sf, V[:, 1], V[:, 2], V[:, 3], tet_edges; row = 1, col = k, color = edge)
		plot_polygons3d!(sf, [V[[1, 2, 3], :]]; row = 1, col = k, color = color, opacity = 0.12, edgecolor = "")
		u = [scale .* field(p) for p in pts]
		plot_quiver3d!(sf, xyz(pts)..., xyz(u)...; row = 1, col = k, style = :arrow, color = color, headsize = 0.28)
		for m in 1:length(path)-1                      # the oriented edge or the face circulation
			p, q = V[path[m], :], V[path[m+1], :]
			plot_quiver3d!(sf, [p[1]], [p[2]], [p[3]], [q[1] - p[1]], [q[2] - p[2]], [q[3] - p[3]]; row = 1, col = k,
				style = :arrow, color = color, linewidth = 5, headsize = 0.1)
		end
		if k == 2                                      # the normal of face 012
			plot_quiver3d!(sf, [0.36], [0.33], [0.0], [0.0], [0.0], [0.25]; row = 1, col = k, style = :arrow,
				color = dark, linewidth = 3, headsize = 0.25)
			annotate!(sf, 0.40, 0.36, 0.30, "\$\\mathbf{n}\$"; row = 1, col = k, showarrow = false, xshift = 8)
		end
		plot_scatter3d!(sf, V[:, 1], V[:, 2], V[:, 3]; row = 1, col = k, mode = "markers", marker_symbol = "circle", marker_size = 4, color = dark,
			showlegend = false)
		foreach(v -> annotate!(sf, V[v, 1], V[v, 2], V[v, 3], string(v - 1); row = 1, col = k, showarrow = false, xshift = -9, yshift = 7), 1:4)
		scene!(sf; row = 1, col = k, aspectmode = "cube", showaxis = false, showgrid = false, showbackground = false,
			showticklabels = false)
		view!(sf; row = 1, col = k, elev = 19, azim = -60, projection = "orthographic")
		title!(sf, name; row = 1, col = k)
		annotate!(sf, 0.0, 0.02, caption; row = 1, col = k, coords = :axes, showarrow = false, anchor = :bottomleft,
			color = color)
	end
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "topo_whitney.png"); scale = 2)
