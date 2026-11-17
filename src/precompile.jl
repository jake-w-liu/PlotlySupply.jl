# Precompile workload (PrecompileTools, decision D14: time-to-first-figure is
# part of the product). Everything `_precompile_workload` runs while the
# package image is built is compiled into that image, so a user's first
# figure in a fresh session does not pay for inference and code generation.
# Measured before/after numbers are in benchmark/RESULTS.md.
#
# Rules this workload keeps (checked by test/regression_perf.jl, which runs
# the same function):
# - no Electron: no `show = true`, no `to_syncplot`, `subplots(...; sync =
#   false)` only, and only the in-process side of an export (the export copy,
#   the finalizer and the JSON the renderer would receive; html and json
#   written to an `IOBuffer`). Nothing touches the network or the file system.
# - no warnings, and no lasting change of package state: styles go through
#   `with_style`, which restores the active style; defaults are never set.
# - the inputs use the argument types a script most often passes:
#   `Vector{Float64}`, `range(...; length)` and `UnitRange{Int}` vectors, and
#   `Matrix{Float64}` fields.

using PrecompileTools: @setup_workload, @compile_workload

function _precompile_workload()
	x = collect(range(0.0, 2pi; length = 24))
	r = range(0.0, 2pi; length = 24)
	y = sin.(x)
	U = [sin(a) * cos(b) for a in x, b in x]

	# 1-D families, Plot path (constructor, mutator, figure options).
	fig = plot_scatter(x, y; xlabel = "\$x\$", ylabel = "amplitude", title = "Signal", legend = "sin")
	plot_scatter!(fig, x, cos.(x); legend = "cos", dash = "dash", marker_symbol = "o")
	plot_scatter!(fig, r, y .^ 2; mode = "lines", color = "black", linewidth = 2)
	xlabel!(fig, "time (s)")
	ylabel!(fig, "\$u(t)\$")
	xrange!(fig, (0, 2pi))
	yrange!(fig, (-1.5, 1.5))
	title!(fig, "Signals")
	set_legend!(fig; position = :bottomleft)
	hline!(fig, 0.5; dash = "dot")
	vline!(fig, pi)
	annotate!(fig, pi, 0.0, "zero")
	xticks!(fig, [0, pi, 2pi], ["0", "\$\\pi\$", "\$2\\pi\$"])
	figsize!(fig, 3.5, 2.5; units = :in)
	tight_layout!(fig)
	plot_scatter(1:10, collect(1.0:10.0) .^ 2; xscale = "log", yscale = "log", xticks = :decades, legend = "n^2")
	plot_scatter([x, x], [y, cos.(x)]; legend = ["a", "b"])
	plot_scatter(y; error_y = fill(0.1, length(y)))
	plot_bar(1:5, [3.0, 1.0, 4.0, 1.0, 5.0]; legend = "bars")
	plot_histogram(y; nbinsx = 10)

	# Fields, meshes and vector fields.
	hm = plot_heatmap(x, x, U; xlabel = "x", ylabel = "y", colorbar_title = "u")
	plot_contour!(hm, x, x, U; showscale = false)
	colorbar!(hm; title = "\$|u|\$", title_side = :right)
	plot_heatmap(U; equalar = true)
	plot_contour(x, x, U; colorbar_title = "u")
	plot_quiver(x[1:4:end], x[1:4:end], U[1:4:end, 1:4:end], U'[1:4:end, 1:4:end]; sizeref = 0.5)
	plot_streamlines(r, r, U, U'; density = 0.5)
	plot_pcolormesh([ri * cos(t) for ri in 1:4, t in x[1:6]], [ri * sin(t) for ri in 1:4, t in x[1:6]],
		[Float64(i + j) for i in 1:3, j in 1:5]; colorbar_title = "c")
	plot_tripcolor([0.0, 1.0, 0.0, 1.0], [0.0, 0.0, 1.0, 1.0], [1 2 3; 2 4 3], [0.0, 1.0, 2.0, 3.0])

	# 3-D.
	plot_surface(x, x, U; xlabel = "x", ylabel = "y", zlabel = "u")
	plot_scatter3d(x, y, cos.(x); legend = "helix")

	# SubplotFigure: cells, insets of the layout engine, cell decorations.
	sf = subplots(2, 2; sync = false)
	plot_scatter!(sf, x, y; row = 1, col = 1, legend = "sin")
	plot_scatter!(sf, x, cos.(x); row = 1, col = 1, legend = "cos")
	plot_heatmap!(sf, x, x, U; row = 1, col = 2, colorbar_title = "u")
	plot_bar!(sf, 1:3, [1.0, 2.0, 3.0]; row = 2, col = 1)
	plot_contour!(sf, x, x, U; row = 2, col = 2)
	xlabel!(sf, "x"; row = 1, col = 1)
	ylabel!(sf, "y"; row = 1, col = 1)
	yrange!(sf, (-2, 2); row = 1, col = 1)
	title!(sf, "(a) signals"; row = 1, col = 1)
	panel_labels!(sf)
	set_legend!(sf; row = 1, col = 1, position = :topleft)
	colorbar!(sf; row = 1, col = 2, title = "\$u\$")
	figsize!(sf, 7.0, 5.0; units = :in)
	tight_layout!(sf)

	# Publication style.
	with_style(:publication) do
		plot_scatter(x, y; legend = "a", xlabel = "x", ylabel = "y")
	end

	# The in-process side of every export (no Electron).
	_prepare_export(fig, ("png", "pdf", "svg"), NamedTuple())
	_prepare_export(getfield(sf, :fig), ("png", "pdf"), NamedTuple())
	savefig(IOBuffer(), fig; format = "html")
	savefig(IOBuffer(), hm; format = "json")
	return nothing
end

@setup_workload begin
	@compile_workload begin
		_precompile_workload()
	end
end
