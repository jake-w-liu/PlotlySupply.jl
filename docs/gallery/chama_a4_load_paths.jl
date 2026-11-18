# Load-displacement paths: colour = method, line style = mesh, event markers, mixed legend.
#
# Catalogue: chama-python A4.
# Replaces: ax.plot(color=, linestyle=), 'x'/'+' marker overlays, ax.set_xlim(0, 1.025*ratio),
#   ax.set_ylim(bottom=0), ticklabel_format(style='plain') and a legend of grey Line2D proxies.
# 2.0: one-sided limits (`yrange = (0, nothing)`), `legend_entry!` for the grey line-style keys.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

ratio = 0.01
methods = [("Mixed enhanced strain", "#D55E00", 510.0), ("Macroelement", "#0072B2", 540.0),
	("\$Q_1\$ displacement", "#000000", 140.0)]
meshes = [("8×4×2", "dot", 0.94), ("16×4×2", "dash", 1.04), ("32×8×4", "solid", 1.0)]

fig = with_style(:ieee) do
	fig = plot_scatter(Float64[], Float64[]; xlabel = "line load \$q/E\$",
		ylabel = "\$-u_y(0,10,0)\$", xrange = (0, 1.025 * ratio), yrange = (0, nothing),
		xticks = 0:0.002:0.01)
	q = collect(range(0, ratio; length = 11))
	for (name, color, k) in methods, (_, dash, f) in meshes
		stiff = name == "Macroelement" ? f^1.6 : (startswith(name, "\$Q") ? f^4 : f)
		u = k * stiff .* q .* (1 .+ 18 .* q)
		if name == "Mixed enhanced strain" && dash == "dot"      # run stopped early: a big cross
			plot_scatter!(fig, q[9:9], u[9:9]; mode = "markers", marker_symbol = "x", marker_size = 10, color = color)
			u = u[1:9]
		end
		plot_scatter!(fig, q[1:length(u)], u; mode = "lines+markers", marker_symbol = "circle",
			marker_size = 3, dash = dash, color = color)
		name == "Macroelement" && dash == "dash" &&           # symmetry-plane crossings
			plot_scatter!(fig, q[[7, 9]], u[[7, 9]]; mode = "markers", marker_symbol = "cross-thin-open",
				marker_size = 9, color = color)
	end
	# Legend: method colours, then neutral grey keys for the meshes and the markers.
	foreach(m -> legend_entry!(fig, m[1]; color = m[2]), methods)
	foreach(m -> legend_entry!(fig, m[1]; color = "#555555", dash = m[2]), meshes)
	legend_entry!(fig, "partial state"; mode = "markers", marker_symbol = "x", color = "#555555")
	legend_entry!(fig, "symmetry plane"; mode = "markers", marker_symbol = "cross-thin-open", color = "#555555")
	set_legend!(fig; position = :topleft, ncols = 2)     # the free corner above the curves
	grid!(fig; alpha = 0.2)
	figsize!(fig, :ieee; columns = 2, aspect = 0.5)
	fig
end
savefig(fig, joinpath(outdir, "chama_a4_load_paths.png"); scale = 2)
