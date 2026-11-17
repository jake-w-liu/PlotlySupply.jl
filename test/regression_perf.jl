using Test, PlotlySupply

# Performance guards (decision D14). Every bound here is on allocated BYTES,
# which are deterministic, or on ratios of them: wall-clock thresholds would
# fail on a busy machine. Each guard pins behaviour the code already has
# (measured numbers in benchmark/RESULTS.md), so a later change cannot
# silently regress it: payloads stay shared by reference, a constructor's
# cost does not grow with the data it only references, mutating a figure that
# holds a lot of data does not copy that data, and whole-figure operations stay
# linear in the number of traces and points.

# Minimum allocation of `f()` over three runs after a warm-up run (compiles).
function _perf_alloc(f)
	f()
	return minimum(_ -> @allocated(f()), 1:3)
end

_perf_wave(n) = (x = collect(range(0.0, 10.0; length = n)); (x, sin.(x) .+ 0.1 .* cos.(7 .* x)))

function _perf_field(n)
	x = collect(range(-2.0, 2.0; length = n))
	y = collect(range(-1.0, 3.0; length = n))
	return x, y, [sin(3a) * cos(2b) + 0.1a for a in x, b in y]
end

# A Plot with `k` named 100-point scatter traces and, with `field`, one heatmap.
function _perf_many_traces(k::Integer; field::Bool = true)
	x, y = _perf_wave(100)
	fig = plot_scatter(x, y; legend = "s1")
	for i in 2:k
		trace = deepcopy(fig.data[1])
		trace.fields[:y] = y .+ i
		trace.fields[:name] = "s$(i)"
		push!(fig.data, trace)
	end
	field && push!(fig.data, heatmap(z = rand(20, 20), x = collect(range(0, 10; length = 20)),
		y = collect(range(-1, 1; length = 20)), transpose = true))
	return fig
end

# Package state the precompile workload must leave as it found it.
_perf_state() = (
	get_default_style(),
	get_default_template(),
	get_default_legend_position(),
	get_default_mathtext(),
	PlotlySupply._DEFAULT_LEGEND_INSET[],
	copy(PlotlySupply._OWNED_ELECTRON_APPS),
	PlotlySupply._EXPORT_STATE.app,
	PlotlySupply._EXPORT_STATE.window,
	PlotlySupply._EXPORT_STATE.tempdir,
	length(PlotlySupply._PLOT_SYNCPLOT_MAP),
)

@testset "perf: precompile workload" begin
	@test isdefined(PlotlySupply, :_precompile_workload)
	before = _perf_state()
	# No warning or error is logged (a warning would also print during
	# precompilation), and nothing is returned.
	result = @test_logs min_level = Base.CoreLogging.Warn PlotlySupply._precompile_workload()
	@test result === nothing
	# No lasting change of package state: no style or default changed, no
	# Electron application, export window or export directory created (other
	# test files may have started their own before this one runs), no SyncPlot.
	@test _perf_state() == before

	# The workload source itself: only in-process exports, no windows.
	path = joinpath(pkgdir(PlotlySupply), "src", "precompile.jl")
	source = read(path, String)
	code = join((line for line in eachline(IOBuffer(source)) if !startswith(lstrip(line), "#")), "\n")
	@test occursin("@compile_workload", code)
	@test !occursin(r"show\s*=\s*true", code)
	@test !occursin(r"sync\s*=\s*true", code)
	@test !occursin("to_syncplot", code)
	@test !occursin(r"\bdisplay\(", code)
	@test !occursin(r"\b(set_default_style!|set_default_template!|set_default_legend_position!|set_default_mathtext!|register_style!)\(", code)
	# Every subplots call is a plain model (no window) ...
	subplot_calls = collect(eachmatch(r"subplots\([^)]*\)", code))
	@test !isempty(subplot_calls)
	@test all(m -> occursin(r"sync\s*=\s*false", m.match), subplot_calls)
	# ... and every savefig writes html/json into an IOBuffer.
	savefig_calls = collect(eachmatch(r"savefig\([^\n]*", code))
	@test !isempty(savefig_calls)
	@test all(m -> occursin("savefig(IOBuffer()", m.match) && occursin(r"format\s*=\s*\"(html|json)\"", m.match),
		savefig_calls)
end

@testset "perf: constructors keep the caller's data by reference" begin
	x, y = _perf_wave(10_000)
	fig = plot_scatter(x, y)
	@test fig.data[1].fields[:x] === x
	@test fig.data[1].fields[:y] === y
	r = range(0.0, 1.0; length = 1_000)
	s = sin.(r)
	fig = plot_scatter(r, s; mode = "lines")
	@test fig.data[1].fields[:x] === r
	@test fig.data[1].fields[:y] === s

	xs, ys, U = _perf_field(40)
	for constructor in (plot_heatmap, plot_contour)
		fig = constructor(xs, ys, U)
		z = fig.data[1].fields[:z]
		# A lazy transpose of U itself (plotly's row-major z), not a copy.
		@test parent(z) === U
		@test fig.data[1].fields[:x] === xs
		@test fig.data[1].fields[:y] === ys
	end
	fig = plot_surface(xs, ys, U)
	@test fig.data[1].fields[:z] === U
end

@testset "perf: constructor allocations do not grow with referenced data" begin
	# A copy of the data would add 8 bytes per value (0.8 MB for 1e5 points);
	# the bounds leave room for a few small bookkeeping allocations only.
	small, large = 100, 100_000
	for (name, make) in (
		"plot_scatter" => n -> (d = _perf_wave(n); () -> plot_scatter(d...)),
		"plot_scatter lines (range x)" => n -> (r = range(0.0, 1.0; length = n); s = sin.(r);
			() -> plot_scatter(r, s; mode = "lines")),
		"plot_bar" => n -> (v = abs.(sin.(1:n)); () -> plot_bar(v)),
		"plot_histogram" => n -> (v = sin.(1:n); () -> plot_histogram(v)),
	)
		a_small = _perf_alloc(make(small))
		a_large = _perf_alloc(make(large))
		@testset "$(name)" begin
			@test a_large - a_small < 16 * 1024
		end
	end
	# Fields: an n x n matrix is referenced, so a 1000 x 1000 field (8 MB)
	# costs about as much as a 10 x 10 one. (The remaining difference is
	# proportional to n, from the coordinate vectors.)
	for (name, make) in (
		"plot_heatmap" => n -> (d = _perf_field(n); () -> plot_heatmap(d...)),
		"plot_contour" => n -> (d = _perf_field(n); () -> plot_contour(d...)),
		"plot_surface" => n -> (d = _perf_field(n); () -> plot_surface(d...)),
	)
		a_small = _perf_alloc(make(10))
		a_large = _perf_alloc(make(1_000))
		@testset "$(name)" begin
			@test a_large - a_small < 256 * 1024
		end
	end
	# colorbar! restyles the bar; it never touches the field values.
	allocs = map((10, 1_000)) do n
		fig = plot_heatmap(_perf_field(n)...)
		_perf_alloc(() -> colorbar!(fig; title = "u", title_side = :right))
	end
	@test allocs[2] - allocs[1] < 256 * 1024
end

@testset "perf: mutating a large figure does not copy its data" begin
	xb, yb = _perf_wave(1_000_000)
	xs, ys = _perf_wave(10)
	# The staged transaction of a mutator shares the existing traces' arrays:
	# its cost is the same whether the figure holds 10 or 1e6 points.
	for (name, mutate) in (
		"plot_scatter!" => fig -> plot_scatter!(fig, xs, ys),
		"relayout!" => fig -> relayout!(fig; title = "t"),
		"xlabel!" => fig -> xlabel!(fig, "x"),
		"hline!" => fig -> hline!(fig, 0.5),
		"set_legend!" => fig -> set_legend!(fig; position = :bottomleft),
	)
		big = plot_scatter(xb, yb)
		tiny = plot_scatter(xs, ys)
		a_big = _perf_alloc(() -> mutate(big))
		a_tiny = _perf_alloc(() -> mutate(tiny))
		@testset "$(name)" begin
			@test a_big - a_tiny < 16 * 1024
			@test big.data[1].fields[:x] === xb
			@test big.data[1].fields[:y] === yb
		end
	end
	# SubplotFigure: a call into one cell does not copy the data of another.
	allocs = map((10, 1_000_000)) do n
		x, y = _perf_wave(n)
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, x, y; row = 1, col = 1)
		a_scatter = _perf_alloc(() -> plot_scatter!(sf, xs, ys; row = 1, col = 2))
		a_label = _perf_alloc(() -> xlabel!(sf, "x"; row = 1, col = 2))
		@test sf.fig.data[1].fields[:x] === x
		(a_scatter, a_label)
	end
	@test allocs[2][1] < allocs[1][1] + 64 * 1024
	@test allocs[2][2] < allocs[1][2] + 64 * 1024
end

@testset "perf: whole-figure operations scale linearly" begin
	# 10x the traces may cost at most 15x the bytes (linear with fixed costs
	# gives about 7-10x; a quadratic pass would give about 100x).
	for (name, make) in (
		"_finalize_figure!" => fig -> (() -> PlotlySupply._finalize_figure!(fig)),
		"tight_layout!" => fig -> (() -> tight_layout!(fig)),
		"set_legend!" => fig -> (flip = Ref(false);
			() -> (flip[] = !flip[]; set_legend!(fig; position = flip[] ? :topleft : :bottomright))),
		"JSON" => fig -> (() -> PlotlyBase.JSON.json(fig)),
	)
		a50 = _perf_alloc(make(_perf_many_traces(50)))
		a500 = _perf_alloc(make(_perf_many_traces(500)))
		@testset "$(name) over traces" begin
			@test a500 < 15 * a50
		end
	end
	# 10x the points: serialization and the in-process export stay linear.
	for (name, make) in (
		"JSON" => fig -> (() -> PlotlyBase.JSON.json(fig)),
		"savefig html" => fig -> (() -> savefig(IOBuffer(), fig; format = "html")),
		"export model (png)" => fig -> (() -> PlotlySupply._prepare_export(fig, ("png",), NamedTuple())),
	)
		a4 = _perf_alloc(make(plot_scatter(_perf_wave(10_000)...)))
		a5 = _perf_alloc(make(plot_scatter(_perf_wave(100_000)...)))
		@testset "$(name) over points" begin
			@test a5 < 13 * a4
		end
	end
	# Multi-series constructor: linear in the number of series. The fixed cost
	# of a constructor dominates at 20 series, so the guard compares the cost
	# per added series over 20 -> 100 with that over 100 -> 500 (equal for a
	# linear cost, 5x for a quadratic one).
	x, y = _perf_wave(100)
	a = Dict(k => _perf_alloc(() -> plot_scatter([x for _ in 1:k], [y .+ i for i in 1:k])) for k in (20, 100, 500))
	per_series_low = (a[100] - a[20]) / 80
	per_series_high = (a[500] - a[100]) / 400
	@test per_series_low > 0
	@test per_series_high < 2 * per_series_low
end
