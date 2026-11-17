# Scaling benchmarks of PlotlySupply's hot paths: time and allocated bytes as
# a function of the problem size, with a fitted exponent (the slope of
# log(cost) over log(n) between the two largest sizes, where the fixed cost of
# a call no longer dominates). Included by `benchmarks.jl`; run alone with
#
#     julia --project=benchmark benchmark/scaling.jl [--quick] [--only NAME]
#
# Timing is the MINIMUM over repeated runs (the machine may be shared);
# allocations are deterministic and reported for the same run set.

using PlotlySupply
using Printf
using Statistics: median

const SCALING_QUICK = Ref(false)

"""
	bench_call(f; samples = 3) -> (time = s, bytes = b)

Minimum wall time (seconds, GC included) and minimum allocated bytes over
`samples` runs of `f()`, after one untimed warm-up run that compiles it.
"""
function bench_call(f; samples::Integer = 3)
	f()
	best_time = Inf
	best_bytes = typemax(Int)
	for _ in 1:samples
		GC.gc(false)
		stats = @timed f()
		best_time = min(best_time, stats.time)
		best_bytes = min(best_bytes, stats.bytes)
	end
	return (time = best_time, bytes = best_bytes)
end

# Fitted exponent of cost(n) between the two largest sizes (log-log slope).
function scaling_exponent(ns, costs)
	length(ns) >= 2 || return NaN
	n1, n2 = Float64(ns[end - 1]), Float64(ns[end])
	c1, c2 = Float64(costs[end - 1]), Float64(costs[end])
	(c1 > 0 && c2 > 0 && n2 > n1) || return NaN
	return log(c2 / c1) / log(n2 / n1)
end

struct ScalingRow
	group::String
	name::String
	n::Int
	unit::String     # what n counts ("points", "cells", ...)
	time::Float64
	bytes::Int
end

struct ScalingFit
	group::String
	name::String
	unit::String
	ns::Vector{Int}
	time_exponent::Float64
	bytes_exponent::Float64
	expected::String
end

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

scaling_sizes(full, quick) = SCALING_QUICK[] ? quick : full

wave(n) = (x = collect(range(0.0, 10.0; length = n)); (x, sin.(x) .+ 0.1 .* cos.(7 .* x)))

function field_matrix(n)
	x = collect(range(-2.0, 2.0; length = n))
	y = collect(range(-1.0, 3.0; length = n))
	return x, y, [sin(3a) * cos(2b) + 0.1a for a in x, b in y]
end

# A curvilinear (annulus) grid of m x m nodes: (m-1)^2 quadrilateral cells,
# drawn as polygons (a non-rectilinear grid cannot be a heatmap).
function annulus_grid(m)
	r = range(1.0, 2.0; length = m)
	t = range(0.0, pi; length = m)
	X = [ri * cos(ti) for ri in r, ti in t]
	Y = [ri * sin(ti) for ri in r, ti in t]
	C = [sin(3ti) / ri for ri in r[1:end-1], ti in t[1:end-1]]
	return X, Y, C
end

# Quads of an m x m node grid as plot_polygons node/connectivity input.
function quad_mesh(m)
	xs = Float64[]; ys = Float64[]
	for j in 1:m, i in 1:m
		push!(xs, i + 0.2 * sin(j)); push!(ys, j + 0.2 * cos(i))
	end
	node(i, j) = (j - 1) * m + i
	cells = Matrix{Int}(undef, (m - 1)^2, 4)
	k = 0
	for j in 1:m-1, i in 1:m-1
		k += 1
		cells[k, :] = [node(i, j), node(i + 1, j), node(i + 1, j + 1), node(i, j + 1)]
	end
	values = [sin(0.3 * c[1]) for c in eachrow(cells)]
	return xs, ys, cells, values
end

# 2 (m-1)^2 triangles on an m x m node grid.
function tri_mesh(m)
	xs = Float64[]; ys = Float64[]
	for j in 1:m, i in 1:m
		push!(xs, i + 0.3 * sin(j)); push!(ys, j)
	end
	node(i, j) = (j - 1) * m + i
	tris = Matrix{Int}(undef, 2 * (m - 1)^2, 3)
	k = 0
	for j in 1:m-1, i in 1:m-1
		tris[k += 1, :] = [node(i, j), node(i + 1, j), node(i + 1, j + 1)]
		tris[k += 1, :] = [node(i, j), node(i + 1, j + 1), node(i, j + 1)]
	end
	return xs, ys, tris, sin.(0.1 .* xs) .* cos.(0.1 .* ys)
end

function vortex(n)
	x = collect(range(-2.0, 2.0; length = n))
	y = collect(range(-2.0, 2.0; length = n))
	U = [-b + 0.3a for a in x, b in y]
	V = [a + 0.1b for a in x, b in y]
	return x, y, U, V
end

# ---------------------------------------------------------------------------
# Size sweeps of constructors and whole-figure operations
# ---------------------------------------------------------------------------

function sweep!(rows, fits, group, name, unit, ns, make; expected = "1", samples = 3)
	times = Float64[]; bytes = Int[]
	for n in ns
		f = make(n)
		r = bench_call(f; samples = samples)
		push!(rows, ScalingRow(group, name, n, unit, r.time, r.bytes))
		push!(times, r.time); push!(bytes, r.bytes)
	end
	push!(fits, ScalingFit(group, name, unit, collect(ns),
		scaling_exponent(ns, times), scaling_exponent(ns, bytes), expected))
	return nothing
end

function scaling_constructors!(rows, fits)
	ns_points = scaling_sizes([1_000, 10_000, 100_000, 1_000_000], [1_000, 10_000, 100_000])
	sweep!(rows, fits, "constructor", "plot_scatter (no legend)", "points", ns_points, n -> begin
		x, y = wave(n); () -> plot_scatter(x, y)
	end)
	sweep!(rows, fits, "constructor", "plot_scatter (legend)", "points", ns_points, n -> begin
		x, y = wave(n); () -> plot_scatter(x, y; legend = "data")
	end)
	sweep!(rows, fits, "constructor", "plot_scatter (range x, lines)", "points", ns_points, n -> begin
		x = range(0.0, 10.0; length = n); y = sin.(x); () -> plot_scatter(x, y; mode = "lines")
	end)
	ns_series = scaling_sizes([1, 10, 50, 200], [1, 10, 50])
	sweep!(rows, fits, "constructor", "plot_scatter (k series x 100 pts)", "series", ns_series, k -> begin
		x, y = wave(100)
		ys = [y .+ i for i in 1:k]
		k == 1 ? (() -> plot_scatter(x, y; legend = "s1")) :
			(() -> plot_scatter([x for _ in 1:k], ys; legend = ["s$(i)" for i in 1:k]))
	end)
	ns_field = scaling_sizes([250, 500, 1000, 2000], [100, 250, 500])
	sweep!(rows, fits, "constructor", "plot_heatmap (n x n)", "n", ns_field, n -> begin
		x, y, U = field_matrix(n); () -> plot_heatmap(x, y, U; colorbar_title = "u")
	end; expected = "<= 1 (lazy)")
	sweep!(rows, fits, "constructor", "plot_contour (n x n)", "n", ns_field, n -> begin
		x, y, U = field_matrix(n); () -> plot_contour(x, y, U)
	end; expected = "<= 1 (lazy)")
	sweep!(rows, fits, "constructor", "plot_pcolormesh (rectilinear vectors, n x n cells)", "n", ns_field[1:end-1], n -> begin
		x, y, U = field_matrix(n + 1); C = U[1:n, 1:n]; () -> plot_pcolormesh(x, y, C)
	end; expected = "2 (n^2 values)", samples = 2)
	ns_cells = scaling_sizes([32, 101, 317], [32, 71])        # (m-1)^2 cells: 961, 1e4, 1e5
	sweep!(rows, fits, "constructor", "plot_pcolormesh (curvilinear)", "nodes/side", ns_cells, m -> begin
		X, Y, C = annulus_grid(m); () -> plot_pcolormesh(X, Y, C)
	end; expected = "2 (cells ~ m^2)", samples = 2)
	sweep!(rows, fits, "constructor", "plot_polygons (quads)", "nodes/side", ns_cells, m -> begin
		xs, ys, cells, vals = quad_mesh(m); () -> plot_polygons(xs, ys, cells, vals)
	end; expected = "2 (cells ~ m^2)", samples = 2)
	ns_tri = scaling_sizes([23, 72, 225], [23, 51])           # 2 (m-1)^2: ~1e3, 1e4, 1e5 triangles
	sweep!(rows, fits, "constructor", "plot_tripcolor (flat)", "nodes/side", ns_tri, m -> begin
		xs, ys, tris, vals = tri_mesh(m); () -> plot_tripcolor(xs, ys, tris, vals)
	end; expected = "2 (cells ~ m^2)", samples = 2)
	ns_grid = scaling_sizes([50, 100, 200], [25, 50])
	sweep!(rows, fits, "constructor", "plot_quiver (n x n grid)", "n", ns_grid, n -> begin
		x, y, U, V = vortex(n); () -> plot_quiver(x, y, U, V; sizeref = 4 / n)
	end; expected = "2 (arrows ~ n^2)", samples = 2)
	sweep!(rows, fits, "constructor", "plot_streamlines (n x n grid)", "n", ns_grid, n -> begin
		x, y, U, V = vortex(n); () -> plot_streamlines(x, y, U, V)
	end; expected = "<= 2", samples = 2)
	ns_samples = scaling_sizes([10_000, 100_000, 1_000_000], [10_000, 100_000])
	sweep!(rows, fits, "constructor", "plot_histogram (samples)", "samples", ns_samples, n -> begin
		v = sin.(1:n) .* sqrt.(1:n) ./ sqrt(n); () -> plot_histogram(v)
	end)
	sweep!(rows, fits, "constructor", "plot_bar (bars)", "bars", ns_samples, n -> begin
		v = abs.(sin.(1:n)); () -> plot_bar(v)
	end)
	return nothing
end

# ---------------------------------------------------------------------------
# Repeated mutators: the cost of call k must not grow with k
# ---------------------------------------------------------------------------

# Per-call time and bytes of `calls` successive mutations of one figure;
# returns the median over the first and the last `window` calls.
function repeated_calls(make_target, mutate!; calls::Integer, window::Integer = 10)
	# Warm-up: the whole sequence on a throw-away figure, so no call of the
	# measured run pays compile time (later calls can reach code paths the
	# first ones do not, e.g. grid cells with neighbours).
	warm = make_target()
	for k in 1:calls
		mutate!(warm, k)
	end
	warm = nothing
	GC.gc()
	target = make_target()
	times = Float64[]; bytes = Int[]
	for k in 1:calls
		stats = @timed mutate!(target, k)
		push!(times, stats.time); push!(bytes, stats.bytes)
	end
	first_w = 1:min(window, calls)
	last_w = max(1, calls - window + 1):calls
	return (
		first_time = median(times[first_w]), last_time = median(times[last_w]),
		first_bytes = median(bytes[first_w]), last_bytes = median(bytes[last_w]),
		total = sum(times), target = target,
	)
end

struct RepeatRow
	name::String
	calls::Int
	first_time::Float64
	last_time::Float64
	first_bytes::Float64
	last_bytes::Float64
	total::Float64
end

function scaling_repeated!(rep)
	calls = SCALING_QUICK[] ? 60 : 200
	x, y = wave(100)
	cases = [
		("plot_scatter! on a Plot (unnamed)", () -> plot_scatter(x, y),
			(f, k) -> plot_scatter!(f, x, y .+ k)),
		("plot_scatter! on a Plot (named)", () -> plot_scatter(x, y; legend = "s0"),
			(f, k) -> plot_scatter!(f, x, y .+ k; legend = "s$(k)")),
		("plot_scatter! on one SubplotFigure cell", () -> subplots(1, 2; sync = false),
			(sf, k) -> plot_scatter!(sf, x, y .+ k; row = 1, col = 1)),
		("plot_scatter! on one SubplotFigure cell (named)", () -> subplots(1, 2; sync = false),
			(sf, k) -> plot_scatter!(sf, x, y .+ k; row = 1, col = 1, legend = "s$(k)")),
		# Without per-subplot legends a SubplotFigure mutation takes the
		# append-only staging path instead of staging every trace.
		("plot_scatter! on one SubplotFigure cell (per_subplot_legends = false)",
			() -> subplots(1, 2; sync = false, per_subplot_legends = false),
			(sf, k) -> plot_scatter!(sf, x, y .+ k; row = 1, col = 1)),
		("hline! on a Plot", () -> plot_scatter(x, y),
			(f, k) -> hline!(f, 0.01k)),
	]
	for (name, make, mutate!) in cases
		r = repeated_calls(make, mutate!; calls = calls)
		push!(rep, RepeatRow(name, calls, r.first_time, r.last_time, r.first_bytes, r.last_bytes, r.total))
	end
	# A 6 x 6 grid filled cell by cell (36 calls; each call addresses a new cell).
	grid = SCALING_QUICK[] ? 4 : 6
	cells = [(i, j) for i in 1:grid for j in 1:grid]
	r = repeated_calls(() -> subplots(grid, grid; sync = false),
		(sf, k) -> plot_scatter!(sf, x, y; row = cells[k][1], col = cells[k][2], legend = "c$(k)");
		calls = length(cells), window = grid)
	push!(rep, RepeatRow("$(grid)x$(grid) grid, plot_scatter! per cell", length(cells),
		r.first_time, r.last_time, r.first_bytes, r.last_bytes, r.total))
	U = [sin(a / 5) * cos(b / 7) for a in 1:30, b in 1:30]
	r = repeated_calls(() -> subplots(grid, grid; sync = false),
		(sf, k) -> plot_heatmap!(sf, U; row = cells[k][1], col = cells[k][2]);
		calls = length(cells), window = grid)
	push!(rep, RepeatRow("$(grid)x$(grid) grid, plot_heatmap! per cell", length(cells),
		r.first_time, r.last_time, r.first_bytes, r.last_bytes, r.total))
	return nothing
end

# ---------------------------------------------------------------------------
# Whole-figure operations on large figures
# ---------------------------------------------------------------------------

function many_traces(k; points = 100, field = true)
	x, y = wave(points)
	fig = plot_scatter(x, y; legend = "s1")
	data = fig.data
	for i in 2:k
		t = deepcopy(data[1])
		t.fields[:y] = y .+ i
		t.fields[:name] = "s$(i)"
		push!(data, t)
	end
	field && push!(data, heatmap(z = rand(20, 20), x = collect(range(0, 10; length = 20)),
		y = collect(range(-1, 1; length = 20)), transpose = true))
	return fig
end

function scaling_figure_ops!(rows, fits)
	ks = scaling_sizes([1, 10, 100, 500], [1, 10, 100])
	sweep!(rows, fits, "figure op", "_finalize_figure! (k traces + heatmap)", "traces", ks, k -> begin
		fig = many_traces(k); () -> PlotlySupply._finalize_figure!(fig)
	end)
	sweep!(rows, fits, "figure op", "set_legend! (k named traces)", "traces", ks, k -> begin
		fig = many_traces(k; field = false)
		flip = Ref(false)
		# Alternate the position so every call really moves the legend.
		() -> (flip[] = !flip[]; set_legend!(fig; position = flip[] ? :topleft : :bottomright))
	end)
	sweep!(rows, fits, "figure op", "tight_layout! (k traces)", "traces", ks, k -> begin
		fig = many_traces(k); () -> tight_layout!(fig)
	end)
	ns_field = scaling_sizes([250, 500, 1000, 2000], [100, 250, 500])
	sweep!(rows, fits, "figure op", "colorbar! on a heatmap (n x n)", "n", ns_field, n -> begin
		x, y, U = field_matrix(n); fig = plot_heatmap(x, y, U)
		() -> colorbar!(fig; title = "u", ticks = [-1, 0, 1])
	end; expected = "0 (independent of n)")
	ns_points = scaling_sizes([10_000, 100_000, 1_000_000], [10_000, 100_000])
	sweep!(rows, fits, "export", "JSON.json (n-point scatter)", "points", ns_points, n -> begin
		x, y = wave(n); fig = plot_scatter(x, y)
		() -> PlotlyBase.JSON.json(fig)
	end; samples = 2)
	sweep!(rows, fits, "export", "savefig html to IOBuffer (n points)", "points", ns_points, n -> begin
		x, y = wave(n); fig = plot_scatter(x, y)
		() -> savefig(IOBuffer(), fig; format = "html")
	end; samples = 2)
	sweep!(rows, fits, "export", "png/pdf export model side (n points)", "points", ns_points, n -> begin
		x, y = wave(n); fig = plot_scatter(x, y)
		() -> PlotlySupply._prepare_export(fig, ("png", "pdf"), NamedTuple())
	end; samples = 2)
	ns_field = scaling_sizes([250, 500, 1000], [100, 250])
	sweep!(rows, fits, "export", "png export model side (heatmap n x n)", "n", ns_field, n -> begin
		x, y, U = field_matrix(n); fig = plot_heatmap(x, y, U)
		() -> PlotlySupply._prepare_export(fig, ("png",), NamedTuple())
	end; expected = "2 (n^2 values)", samples = 2)
	return nothing
end

# ---------------------------------------------------------------------------
# Memory: what a figure keeps of the caller's data
# ---------------------------------------------------------------------------

struct MemoryRow
	name::String
	n::Int
	user_bytes::Int
	retained_bytes::Int   # Base.summarysize of the figure minus shared input
	alloc_bytes::Int
	shares_input::Bool
end

function scaling_memory!(mem)
	n = SCALING_QUICK[] ? 100_000 : 1_000_000
	x, y = wave(n)
	user = Base.summarysize(x) + Base.summarysize(y)
	fig = plot_scatter(x, y)
	t = fig.data[1]
	shares = get(t.fields, :x, nothing) === x && get(t.fields, :y, nothing) === y
	retained = Base.summarysize(fig) - (shares ? user : 0)
	alloc = bench_call(() -> plot_scatter(x, y); samples = 2).bytes
	push!(mem, MemoryRow("plot_scatter(x, y)", n, user, retained, alloc, shares))

	m = SCALING_QUICK[] ? 300 : 1000
	xs, ys, U = field_matrix(m)
	user = Base.summarysize(U) + Base.summarysize(xs) + Base.summarysize(ys)
	fig = plot_heatmap(xs, ys, U)
	z = fig.data[1].fields[:z]
	shares = (z === U) || (applicable(parent, z) && parent(z) === U)
	retained = Base.summarysize(fig) - (shares ? Base.summarysize(U) : 0)
	alloc = bench_call(() -> plot_heatmap(xs, ys, U); samples = 2).bytes
	push!(mem, MemoryRow("plot_heatmap(x, y, U)", m * m, user, retained, alloc, shares))

	# A mutation of a figure that already holds n points: the staged
	# transaction must not copy the existing traces' data.
	fig = plot_scatter(x, y)
	small_x, small_y = wave(10)
	plot_scatter!(fig, small_x, small_y)
	alloc = bench_call(() -> plot_scatter!(fig, small_x, small_y); samples = 2).bytes
	push!(mem, MemoryRow("plot_scatter!(fig with n points, 10 points)", n, 0, 0, alloc, true))
	fig = plot_scatter(small_x, small_y)
	plot_scatter!(fig, small_x, small_y)
	alloc = bench_call(() -> plot_scatter!(fig, small_x, small_y); samples = 2).bytes
	push!(mem, MemoryRow("plot_scatter!(fig with 10 points, 10 points)", 10, 0, 0, alloc, true))
	fig = plot_scatter(x, y)
	alloc = bench_call(() -> relayout!(fig; title = "t"); samples = 2).bytes
	push!(mem, MemoryRow("relayout!(fig with n points)", n, 0, 0, alloc, true))
	fig = plot_scatter(x, y)
	alloc = bench_call(() -> xlabel!(fig, "x"); samples = 2).bytes
	push!(mem, MemoryRow("xlabel!(fig with n points)", n, 0, 0, alloc, true))
	# The same with legend entries: the legend's best-position search scores
	# the existing traces' points on every mutation.
	fig = plot_scatter(x, y; legend = "big")
	alloc = bench_call(() -> plot_scatter!(fig, small_x, small_y; legend = "small"); samples = 2).bytes
	push!(mem, MemoryRow("plot_scatter!(fig with a named n-point trace, 10 named points)", n, 0, 0, alloc,
		fig.data[1].fields[:x] === x))
	# SubplotFigure (full staged transaction): another cell holds n points.
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, x, y; row = 1, col = 1)
	alloc = bench_call(() -> plot_scatter!(sf, small_x, small_y; row = 1, col = 2); samples = 2).bytes
	push!(mem, MemoryRow("plot_scatter!(cell 2 of a SubplotFigure whose cell 1 holds n points)", n, 0, 0, alloc,
		getfield(sf, :fig).data[1].fields[:x] === x))

	# Rectilinear pcolormesh: drawn as one heatmap trace, which stores its own
	# (nullable) copy of the cell values.
	m = SCALING_QUICK[] ? 300 : 1000
	xs, ys, U = field_matrix(m + 1)
	C = U[1:m, 1:m]
	user = Base.summarysize(C) + Base.summarysize(xs) + Base.summarysize(ys)
	fig = plot_pcolormesh(xs, ys, C)
	retained = Base.summarysize(fig)
	alloc = bench_call(() -> plot_pcolormesh(xs, ys, C); samples = 2).bytes
	push!(mem, MemoryRow("plot_pcolormesh(x, y, C) rectilinear", m * m, user, retained, alloc, false))
	return nothing
end

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

function scaling_report(rows, fits, rep, mem)
	io = IOBuffer()
	println(io, "### Size sweeps\n")
	println(io, "| group | benchmark | n | unit | min time (ms) | allocated (MB) |")
	println(io, "|---|---|---:|---|---:|---:|")
	for r in rows
		@printf(io, "| %s | %s | %d | %s | %.2f | %.2f |\n", r.group, r.name, r.n, r.unit, 1e3 * r.time, r.bytes / 2^20)
	end
	println(io, "\n### Fitted exponents (log-log slope between the two largest sizes)\n")
	println(io, "| benchmark | sizes | time exponent | bytes exponent | expected |")
	println(io, "|---|---|---:|---:|---|")
	for f in fits
		@printf(io, "| %s | %s %s | %.2f | %.2f | %s |\n", f.name, join(f.ns, ", "), f.unit,
			f.time_exponent, f.bytes_exponent, f.expected)
	end
	println(io, "\n### Repeated mutators (median per call over the first and the last calls)\n")
	println(io, "| case | calls | first (ms) | last (ms) | last/first time | first (KB) | last (KB) | last/first bytes | total (s) |")
	println(io, "|---|---:|---:|---:|---:|---:|---:|---:|---:|")
	for r in rep
		@printf(io, "| %s | %d | %.2f | %.2f | %.2f | %.1f | %.1f | %.2f | %.2f |\n", r.name, r.calls,
			1e3 * r.first_time, 1e3 * r.last_time, r.last_time / r.first_time,
			r.first_bytes / 1024, r.last_bytes / 1024, r.last_bytes / r.first_bytes, r.total)
	end
	println(io, "\n### Memory (what the figure keeps of the caller's data)\n")
	println(io, "| case | n | input (MB) | figure beyond shared input (MB) | allocated per call (MB) | input shared by reference |")
	println(io, "|---|---:|---:|---:|---:|---|")
	for m in mem
		@printf(io, "| %s | %d | %.2f | %.2f | %.3f | %s |\n", m.name, m.n, m.user_bytes / 2^20,
			m.retained_bytes / 2^20, m.alloc_bytes / 2^20, m.shares_input ? "yes" : "no")
	end
	return String(take!(io))
end

function scaling_run(; quick::Bool = false, only = nothing)
	SCALING_QUICK[] = quick
	rows = ScalingRow[]; fits = ScalingFit[]; rep = RepeatRow[]; mem = MemoryRow[]
	sections = (
		"constructors" => () -> scaling_constructors!(rows, fits),
		"repeated" => () -> scaling_repeated!(rep),
		"figure" => () -> scaling_figure_ops!(rows, fits),
		"memory" => () -> scaling_memory!(mem),
	)
	for (name, run!) in sections
		(only === nothing || only == name) || continue
		t = @elapsed run!()
		@printf(stderr, "scaling: %s done in %.1f s\n", name, t)
	end
	return scaling_report(rows, fits, rep, mem)
end

function scaling_main(args)
	quick = "--quick" in args
	only = nothing
	i = findfirst(==("--only"), args)
	i === nothing || (only = args[i + 1])
	print(scaling_run(; quick = quick, only = only))
	return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
	scaling_main(ARGS)
end
