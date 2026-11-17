using Test, PlotlySupply

# Regression tests for the scatter family (plot_scatter, plot_stem, plot_area,
# plot_scatterpolar, their mutators, plot!) and the shared 1-D helper layer.
# Finding ids from the 2.0 audit are given in the testset names.

# A SyncPlot whose renderer accepts every script, so mutators run their real
# SyncPlot transaction without an Electron window.
function _rsc_syncplot(p::Plot)
	backend = (
		isopen = window -> true,
		close = window -> nothing,
		run = (window, script) -> "ok",
	)
	return SyncPlot(
		p,
		nothing,
		:rsc_window,
		"rsc-div",
		PlotlySupply._SyncPlotResources(nothing, backend, nothing),
	)
end

_rsc_fields(value) = value isa AbstractDict ? value : value.fields
_rsc_axis(fig, key) = _rsc_fields(PlotlySupply._plot_obj(fig).layout.fields[key])
_rsc_get(value, key, default = nothing) = get(_rsc_fields(value), key, default)

# Layout and trace snapshot used to prove that a rejected call changed nothing.
_rsc_snapshot(fig) = (
	length(PlotlySupply._plot_obj(fig).data),
	deepcopy(PlotlySupply._plot_obj(fig).layout),
)

function _rsc_unchanged(fig, snapshot)
	p = PlotlySupply._plot_obj(fig)
	return length(p.data) == snapshot[1] && p.layout == snapshot[2]
end

@testset "scatter family: plot_stem builds 2 traces per series (62, 73, 111, 215)" begin
	y = randn(1000)
	f = plot_stem(y)
	@test length(f.data) == 2
	head, stem = f.data
	@test head.fields[:mode] == "markers"
	@test head.fields[:y] === y
	@test stem.fields[:mode] == "lines"
	@test head.fields[:legendgroup] == stem.fields[:legendgroup]
	@test stem.fields[:showlegend] === false
	@test stem.fields[:hoverinfo] == "skip"
	@test stem.fields[:zorder] == -1
	# Gap-separated segments baseline -> y (PlotlySupply's `_GAP` is `nothing`).
	@test length(stem.fields[:x]) == 3 * length(y)
	@test stem.fields[:x][1:3] == [0, 0, nothing]
	@test stem.fields[:y][1:3] == [0, y[1], nothing]
	@test all(isnothing, stem.fields[:y][3:3:end])
	# 1.x look: thin black stems unless a colour is given.
	@test _rsc_get(stem.fields[:line], :color) == "black"
	@test _rsc_get(stem.fields[:line], :width) == 0.5

	g = plot_stem([randn(5), randn(5)]; legend = ["a", "b"])
	@test length(g.data) == 4
	@test [t.fields[:mode] for t in g.data] == ["markers", "markers", "lines", "lines"]
	@test g.data[1].fields[:legendgroup] == g.data[3].fields[:legendgroup]
	@test g.data[2].fields[:legendgroup] == g.data[4].fields[:legendgroup]
	@test g.data[1].fields[:legendgroup] != g.data[2].fields[:legendgroup]
	@test [t.fields[:name] for t in g.data[1:2]] == ["a", "b"]

	# Appended series get legend groups that never collide with existing ones.
	plot_stem!(g, 0:4, randn(5); legend = "c")
	groups = [g.data[k].fields[:legendgroup] for k in (1, 2, 5)]
	@test allunique(groups)
	@test g.data[5].fields[:legendgroup] == g.data[6].fields[:legendgroup]

	p = Plot(Layout())
	@test plot_stem!(p, [1, 2, 3], [1.0, 2, 3]) === nothing
	@test length(p.data) == 2
end

@testset "scatter family: plot_stem baseline, colours and marker keywords (C30)" begin
	f = plot_stem(1:3, [1.0, -2.0, 3.0]; baseline = -0.5, color = "crimson",
		marker_symbol = "s", marker_size = 9.5, linewidth = 2, legend = "s")
	head, stem = f.data
	@test stem.fields[:y][1:3] == [-0.5, 1.0, nothing]
	@test stem.fields[:y][4:6] == [-0.5, -2.0, nothing]
	@test _rsc_get(stem.fields[:line], :color) == "crimson"
	@test _rsc_get(stem.fields[:line], :width) == 2
	@test _rsc_get(head.fields[:marker], :symbol) == "square"
	@test _rsc_get(head.fields[:marker], :size) == 9.5
	@test _rsc_get(head.fields[:marker], :color) == "crimson"

	# White heads keep the colorway colour as their edge; stems stay black.
	w = plot_stem(1:3, [1.0, 2.0, 3.0]; marker_color = "white", legend = "w")
	marker = _rsc_fields(w.data[1].fields[:marker])
	@test marker[:color] == "white"
	@test _rsc_get(marker[:line], :color) == PlotlySupply._default_trace_color(w, 1)
	@test _rsc_get(w.data[2].fields[:line], :color) == "black"

	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; baseline = Inf)
	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; baseline = true)
	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; marker_symbol = "nope")
	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; linewidth = -1)
end

@testset "scatter family: unnamed stems have no legend entry (63, 72, 103, 303)" begin
	f = plot_stem([3.0, 1.0, 2.0])
	@test f.data[1].fields[:showlegend] === false
	@test !any(PlotlySupply._trace_will_showlegend, f.data)
	q = plot_stem([3.0, 1.0, 2.0]; legend = "s")
	@test !haskey(q.data[1].fields, :showlegend)
	@test PlotlySupply._trace_will_showlegend(q.data[1])
	h = plot_stem([3.0, 1.0, 2.0]; showlegend = true)
	@test h.data[1].fields[:showlegend] === true
	r = plot_scatter(1:4, rand(4); legend = "named")
	plot_stem!(r, 1:4, rand(4))
	@test r.data[2].fields[:showlegend] === false
	@test r.data[3].fields[:showlegend] === false
end

@testset "scatter family: coordinate lengths are validated (50, 71, 112, 219)" begin
	@test_throws ArgumentError plot_stem([1, 2], [1.0, 2.0, 3.0])
	@test_throws ArgumentError plot_stem(1:3, rand(5))
	@test_throws ArgumentError plot_stem([[1, 2], [1, 2]], [[1.0, 2, 3], [1.0, 2, 3]])
	@test_throws ArgumentError plot_scatter([1, 2], [1.0, 2.0, 3.0])
	@test_throws ArgumentError plot_scatter(1:3, [[1.0, 2, 3], [1.0, 2]])
	@test_throws ArgumentError plot_area(1:3, [1.0, 2.0])
	@test_throws ArgumentError plot_scatterpolar([0, 90], [1.0, 2.0, 3.0])
	err = try
		plot_scatter([1, 2], [1.0, 2.0, 3.0])
	catch e
		e
	end
	@test occursin("plot_scatter:", err.msg)

	for mutate! in (
		fig -> plot_scatter!(fig, [1, 2], [1.0, 2.0, 3.0]),
		fig -> plot_stem!(fig, [1, 2], [1.0, 2.0, 3.0]),
		fig -> plot_stem!(fig, [1, 2], [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]),
		fig -> plot_area!(fig, [1, 2], [1.0, 2.0, 3.0]),
		fig -> plot_scatterpolar!(fig, [0, 90], [1.0, 2.0, 3.0]),
	)
		p = plot_scatter(1:3, 1:3)
		snapshot = _rsc_snapshot(p)
		@test_throws ArgumentError mutate!(p)
		@test _rsc_unchanged(p, snapshot)
	end

	# Error bars and text labels need one value per point.
	@test_throws ArgumentError plot_scatter(1:3, [1.0, 2, 3]; error_y = [0.1, 0.2])
	@test_throws ArgumentError plot_scatter(1:3, [1.0, 2, 3]; text = ["a", "b"])
	@test_throws ArgumentError plot_scatter(1:3, [1.0, 2, 3];
		error_y = ([0.1, 0.1, 0.1], [0.1, 0.1]))
end

@testset "scatter family: matrices, 2-D views and complex data are rejected (46, 75)" begin
	M = [1.0 4.0; 2.0 5.0; 3.0 6.0]
	@test_throws ArgumentError plot_scatter(view(M, :, 1:2))
	@test_throws ArgumentError plot_scatter(1:3, view(M, :, 1:2))
	@test_throws ArgumentError plot_scatter(1:3, M)
	@test_throws ArgumentError plot_stem(view(M, :, 1:2))
	@test_throws ArgumentError plot_area(1:3, M)
	@test_throws ArgumentError plot_scatterpolar(1:3, M)
	err = try
		plot_scatter(1:3, M)
	catch e
		e
	end
	@test occursin("eachcol", err.msg)

	@test_throws ArgumentError plot_scatter([1 + 2im, 3 + 4im])
	@test_throws ArgumentError plot_scatter(1:2, [[1 + 2im, 3im], [1.0, 2.0]])
	@test_throws ArgumentError plot_scatter(1:2, Any[1.0, 2im])
	@test_throws ArgumentError plot_stem([1 + 2im, 3 + 4im])
	err = try
		plot_scatter([1 + 2im, 3 + 4im])
	catch e
		e
	end
	@test occursin("plot_complex", err.msg)

	# A column view is a vector and is stored by reference.
	column = view(M, :, 1)
	f = plot_scatter(column)
	@test f.data[1].fields[:y] === column
	@test_throws ArgumentError plot_scatter(1:3, [1.0, 2.0, 3.0]')
	@test_throws ArgumentError plot_scatter(1:3, [1.0 2.0 3.0])
end

@testset "scatter family: Vector{Any} multi-series input (40, 46, 59, 68, 132, 211)" begin
	ys = []
	push!(ys, [1.0, 2.0, 3.0])
	push!(ys, [3.0, 2.0, 1.0])
	for build in (
		() -> plot_scatter(ys),
		() -> plot_scatter(0:2, ys),
		() -> plot_area(ys),
		() -> plot_scatterpolar([0, 90, 180], ys),
	)
		f = build()
		@test length(f.data) == 2
		y_key = haskey(f.data[2].fields, :r) ? :r : :y
		@test f.data[2].fields[y_key] == [3.0, 2.0, 1.0]
	end
	@test length(plot_stem(ys).data) == 4

	p = plot_scatter(1:3, 1:3)
	plot_scatter!(p, ys)
	@test length(p.data) == 3
	plot_stem!(p, 0:2, ys)
	@test length(p.data) == 7

	sf = subplots(1, 1; sync = false)
	plot_scatter!(sf, [0, 1, 2], ys)
	@test length(sf.plot.data) == 2

	f = plot_scatter([[1.0, 2, 3], [3.0, 2, 1]];
		error_y = Any[[0.1, 0.1, 0.1], [0.5, 0.5, 0.5]])
	@test _rsc_get(f.data[2].fields[:error_y], :array) == [0.5, 0.5, 0.5]

	mixed = Any[[1.0, 2.0], 3.0]
	@test_throws ArgumentError plot_scatter(mixed)
	@test_throws ArgumentError plot_stem(mixed)
	@test_throws ArgumentError plot_area(mixed)
	err = try
		plot_scatter(1:2, mixed)
	catch e
		e
	end
	@test occursin("plot_scatter:", err.msg)
	@test !PlotlySupply._is_nested_series(Any[])
	@test !PlotlySupply._is_nested_series(Any[1, 2])
end

@testset "scatter family: no hidden tick0 (54, 64, 315)" begin
	for f in (
		plot_scatter(1:3, [0.37, 1.0, 2.0]),
		plot_stem(1:3, [0.37, 1.0, 2.0]),
		plot_area(1:3, [0.37, 1.0, 2.0]),
		plot_scatter([0.37, 1.0, 2.0]; yscale = "log", xscale = "log"),
	)
		@test !haskey(_rsc_axis(f, :xaxis), :tick0)
		@test !haskey(_rsc_axis(f, :yaxis), :tick0)
	end
	@test !isdefined(PlotlySupply, :_safe_tick0)

	# `_apply_showlegend!(trace, nothing)` leaves the trace unchanged.
	t = scatter(x = [1], y = [1])
	PlotlySupply._apply_showlegend!(t, nothing)
	@test !haskey(t.fields, :showlegend)
	t2 = scatter(x = [1], y = [1], showlegend = false)
	PlotlySupply._apply_showlegend!(t2, nothing)
	@test t2.fields[:showlegend] === false
	traces = [scatter(x = [1], y = [1]) for _ in 1:3]
	PlotlySupply._apply_showlegend!(traces, [true, nothing])
	@test traces[1].fields[:showlegend] === true
	@test !haskey(traces[2].fields, :showlegend)
	@test !haskey(traces[3].fields, :showlegend)
end

@testset "scatter family: mode \"\" means lines for every series (44, 65, 83, 104)" begin
	nested = [[1.0, 2, 3], [3.0, 2, 1]]
	modes(f) = [t.fields[:mode] for t in f.data]
	@test modes(plot_scatter(nested; mode = ["markers", ""])) == ["markers", "lines"]
	@test modes(plot_scatter(nested; mode = "")) == ["lines", "lines"]
	@test modes(plot_scatter([1.0, 2, 3]; mode = "")) == ["lines"]
	@test modes(plot_scatterpolar([0, 90, 180], nested; mode = ["markers", ""])) ==
		["markers", "lines"]
	p = Plot(Layout())
	plot_scatter!(p, nested; mode = ["markers", ""])
	@test modes(p) == ["markers", "lines"]
	q = Plot(Layout())
	plot_scatterpolar!(q, [0, 90, 180], nested; mode = "")
	@test modes(q) == ["lines", "lines"]
	@test modes(plot_scatter(nested; mode = "none")) == ["none", "none"]
	@test modes(plot_scatter(nested; mode = "markers+lines+text", text = "t")) ==
		["markers+lines+text", "markers+lines+text"]
	@test_throws ArgumentError plot_scatter(nested; mode = "lnes")
	@test_throws ArgumentError plot_scatter(nested; mode = "lines+lines")
	@test_throws ArgumentError plot_scatter(nested; mode = ["lines", 1])
end

@testset "scatter family: plot_area stack and axis scales (117, 214, 217)" begin
	f = plot_area(1:3, [1.0, 2.0, 3.0]; stack = true, legend = "a")
	@test f.data[1].fields[:stackgroup] == "one"
	@test !haskey(f.data[1].fields, :fill)
	plot_area!(f, 1:3, [1.0, 1.0, 1.0]; stack = true, legend = "b")
	@test f.data[2].fields[:stackgroup] == "one"
	g = plot_area(1:3, [1.0, 2.0, 3.0])
	@test g.data[1].fields[:fill] == "tozeroy"
	@test !haskey(g.data[1].fields, :stackgroup)

	a = plot_area(1:3, [1, 10, 100]; yscale = "log", xscale = "log")
	@test _rsc_axis(a, :yaxis)[:type] == "log"
	@test _rsc_axis(a, :xaxis)[:type] == "log"
	@test _rsc_axis(a, :yaxis)[:exponentformat] == "power"

	h = plot_area(1:3, [1.0, 2.0, 3.0]; hatch = "//", color = :teal)
	@test haskey(h.data[1].fields, :fillpattern)
	@test _rsc_get(h.data[1].fields[:line], :color) == "teal"
	@test_throws ArgumentError plot_area(1:3, [1.0, 2.0, 3.0]; hatch = "?")
	@test_throws ArgumentError plot_area(1:3, [1.0, 2.0, 3.0]; mode = "bogus")
	@test plot_area(1:3, [1.0, 2.0, 3.0]; mode = "").data[1].fields[:mode] == "lines"
end

@testset "scatter family: mutator grid and primary axes only (100, 113, 217)" begin
	for mutate! in (
		(fig; kw...) -> plot_scatter!(fig, [3, 2, 1]; kw...),
		(fig; kw...) -> plot_stem!(fig, [3, 2, 1]; kw...),
		(fig; kw...) -> plot_area!(fig, [3, 2, 1]; kw...),
		(fig; kw...) -> plot!(fig, [3, 2, 1]; kw...),
	)
		p = plot_scatter([1, 2, 3]; grid = false)
		mutate!(p)
		@test _rsc_axis(p, :xaxis)[:showgrid] === false
		mutate!(p; grid = true)
		@test _rsc_axis(p, :xaxis)[:showgrid] === true
		@test _rsc_axis(p, :yaxis)[:showgrid] === true
		mutate!(p; grid = :y)
		@test _rsc_axis(p, :xaxis)[:showgrid] === false
		@test _rsc_axis(p, :yaxis)[:showgrid] === true
	end
	f = plot_scatter(1:3, [1, 2, 3])
	plot_scatter!(f, 1:3, [2, 3, 4])
	@test get(_rsc_axis(f, :xaxis), :showgrid, nothing) !== false

	q = plot_scatterpolar(0:90:270, [1, 2, 3, 4]; grid = false)
	plot_scatterpolar!(q, 0:90:270, [2, 2, 2, 2]; grid = true)
	polar = _rsc_fields(q.layout.fields[:polar])
	@test _rsc_get(polar[:radialaxis], :showgrid) === true
	@test _rsc_get(polar[:angularaxis], :showgrid) === true

	p = plot_scatter(1:3, [1, 2, 3])
	push!(p.data, scatter(x = 1:3, y = [100, 200, 300], yaxis = "y2"))
	relayout!(p, yaxis2 = attr(overlaying = "y", side = "right", range = [0, 400]))
	plot_scatter!(p, 1:3, [1, 2, 3]; yrange = [1, 100], yscale = "log", xrange = (0, 4))
	@test _rsc_axis(p, :yaxis)[:range] ≈ [0.0, 2.0]
	@test _rsc_axis(p, :yaxis)[:type] == "log"
	@test _rsc_axis(p, :xaxis)[:range] == [0, 4]
	@test _rsc_axis(p, :yaxis2)[:range] == [0, 400]
	@test !haskey(_rsc_axis(p, :yaxis2), :type)
end

@testset "scatter family: range keywords are validated (18, 52, 93, 76)" begin
	@test_throws ArgumentError plot_scatter(1:3, [1.0, 2, 3]; xrange = [1, 2, 3])
	@test_throws ArgumentError plot_scatter(1:3, [1.0, 2, 3]; xrange = [5])
	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; yrange = Float64[])
	@test_throws ArgumentError plot_area(1:3, [1.0, 2, 3]; yrange = [0, Inf])
	@test_throws ArgumentError plot_scatter(1:3, [1.0, 2, 3]; yscale = "log", yrange = [0, 10])
	@test_throws ArgumentError plot_scatter(1:3, [1.0, 2, 3]; xscale = "logarithmic")
	@test_throws ArgumentError plot_scatterpolar([0, 90], [1, 2]; rrange = [1])
	p = plot_scatter(1:3, 1:3)
	snapshot = _rsc_snapshot(p)
	@test_throws ArgumentError plot_scatter!(p, 1:3, 1:3; yrange = Float64[])
	@test _rsc_unchanged(p, snapshot)

	@test !haskey(_rsc_axis(plot_scatter(1:3, [1.0, 2, 3]; xrange = [0, 0]), :xaxis), :range)
	@test !haskey(_rsc_axis(plot_scatter(1:3, [1.0, 2, 3]; xrange = nothing), :xaxis), :range)
	@test _rsc_axis(plot_scatter(1:3, [1.0, 2, 3]; xrange = [0, 5]), :xaxis)[:range] == [0, 5]
	@test _rsc_axis(plot_scatter(1:3, [1.0, 2, 3]; xrange = (1, 2)), :xaxis)[:range] == [1, 2]
	# Log-axis ranges are data values.
	log_fig = plot_scatter([1, 10, 100], [1.0, 2, 3]; xscale = "log", xrange = [1, 1000])
	@test _rsc_axis(log_fig, :xaxis)[:range] ≈ [0.0, 3.0]
	polar = plot_scatterpolar([0, 90], [1, 2]; rrange = (0, 3), trange = [0, 180])
	@test _rsc_get(_rsc_fields(polar.layout.fields[:polar])[:radialaxis], :range) == [0, 3]
	@test _rsc_fields(polar.layout.fields[:polar])[:sector] == [0, 180]
end

@testset "scatter family: widened argument and keyword types (19, 56)" begin
	s = L"\sin(x)"
	f = plot_scatter(1:3, 1:3; title = s, xlabel = s, ylabel = s, legend = s)
	@test f.data[1].fields[:name] == "\$\\sin(x)\$"
	@test plot_scatter(1:3, 1:3; title = split("ab cd")[1]) isa Plot
	g = plot_scatter(1:3, [1, 2, 3]; color = :red, marker_size = 7.5,
		linewidth = 1.25, opacity = 0.5, legend = SubString("abc", 1, 2))
	@test _rsc_get(g.data[1].fields[:line], :color) == "red"
	@test _rsc_get(g.data[1].fields[:marker], :size) == 7.5
	@test _rsc_get(g.data[1].fields[:line], :width) == 1.25
	@test g.data[1].fields[:opacity] == 0.5
	@test g.data[1].fields[:name] == "ab"
	@test plot_stem(1:3, [1, 2, 3]; title = s, xlabel = s, legend = s) isa Plot
	@test plot_area(1:3, [1, 2, 3]; title = s, legend = s) isa Plot
	@test plot_scatterpolar([0, 90, 180], [1, 2, 3]; title = s, legend = s) isa Plot
	@test plot_scatter(1:3, Float32[1, 2, 3]; width = 600.0, height = 400, fontsize = 12.0) isa Plot
	@test_throws ArgumentError plot_scatter(1:3, 1:3; opacity = 1.5)
	@test_throws ArgumentError plot_scatter(1:3, 1:3; marker_size = -1)
	@test_throws ArgumentError plot_scatter(1:3, 1:3; color = [1])
	@test_throws ArgumentError plot_scatter(1:3, 1:3; dash = "wiggly")
	@test _rsc_get(plot_scatter(1:3, 1:3; dash = "5px,10px").data[1].fields[:line], :dash) == "5px,10px"
end

@testset "scatter family: per-series keyword vectors and showlegend vectors" begin
	nested = [[1.0, 2, 3], [3.0, 2, 1]]
	# The package-wide per-series convention: one value for every series, or
	# one entry per series; missing entries take the default and surplus
	# entries are ignored (and not validated).
	f = plot_scatter(nested; legend = ["a"], color = ["red"])
	@test [t.fields[:name] for t in f.data] == ["a", ""]
	@test _rsc_get(f.data[1].fields[:line], :color) == "red"
	@test !haskey(f.data[2].fields, :line)
	g = plot_scatter(nested; legend = ["a", "b", "surplus"], color = ["red", "blue", "ignored"])
	@test [t.fields[:name] for t in g.data] == ["a", "b"]
	@test [_rsc_get(t.fields[:line], :color) for t in g.data] == ["red", "blue"]
	@test [t.fields[:mode] for t in plot_scatter(nested; mode = ["markers", "lines", "bogus"]).data] ==
		["markers", "lines"]
	@test length(plot_stem(nested; legend = ["a", "b", "c"]).data) == 4
	# Entries that are used are validated.
	@test_throws ArgumentError plot_scatter(nested; color = ["red", 2])
	@test_throws ArgumentError plot_scatter(nested; marker_size = [5, -1])
	@test_throws ArgumentError plot_scatter(nested; showlegend = Any[true, "no"])

	# Per-point vectors must match their series (see also the length tests).
	@test_throws ArgumentError plot_scatter(nested; error_y = [[0.1, 0.1], [0.1, 0.1, 0.1]])
	@test_throws ArgumentError plot_scatter(nested; text = [["a", "b", "c"], ["a"]])
	@test_throws ArgumentError plot_scatter(nested; markevery = [nothing, [4]])

	# showlegend vectors apply per series, also for a single series in a mutator.
	h = plot_scatter(nested; legend = ["a", "b"], showlegend = [false, true])
	@test [t.fields[:showlegend] for t in h.data] == [false, true]
	p = plot_scatter(1:3, 1:3; legend = "x")
	plot_scatter!(p, 1:3, 3:-1:1; legend = "y", showlegend = [false])
	@test p.data[2].fields[:showlegend] === false
	plot_stem!(p, 1:3, 1:3; legend = "z", showlegend = [false])
	@test p.data[3].fields[:showlegend] === false
	plot_area!(p, 1:3, 1:3; legend = "w", showlegend = [false])
	@test p.data[5].fields[:showlegend] === false
	plot_scatterpolar!(p, [0, 90, 180], 1:3; legend = "v", showlegend = [false])
	@test p.data[6].fields[:showlegend] === false
	q = plot_scatter(1:3, 1:3; showlegend = [true])
	@test q.data[1].fields[:showlegend] === true
end

@testset "scatter family: marker styling, markevery, line_shape, fill, text (C23)" begin
	x = 1:10
	f = plot_scatter(x, [x .^ 2, x .^ 3]; marker_symbol = ["o", "x"],
		marker_color = ["white", ""], mode = "lines+markers",
		markevery = [2, [1, 5]], line_shape = ["hv", "spline"],
		marker_line_width = [2, 0])
	m1 = _rsc_fields(f.data[1].fields[:marker])
	@test m1[:symbol] == "circle"
	@test m1[:color] == "white"
	@test _rsc_get(m1[:line], :color) == PlotlySupply._default_trace_color(f, 1)
	@test _rsc_get(m1[:line], :width) == 2
	m2 = _rsc_fields(f.data[2].fields[:marker])
	@test m2[:symbol] == "x-thin"
	@test f.data[1].fields[:selectedpoints] == collect(0:2:9)
	@test f.data[2].fields[:selectedpoints] == [0, 4]
	@test _rsc_get(f.data[1].fields[:line], :shape) == "hv"
	@test _rsc_get(f.data[2].fields[:line], :shape) == "spline"

	h = plot_scatter(x, x; marker_color = "none", marker_symbol = "s", mode = "markers")
	@test _rsc_get(h.data[1].fields[:marker], :symbol) == "square-open"

	# markevery adds markers to a lines-only trace.
	k = plot_scatter(x, x; markevery = 3)
	@test k.data[1].fields[:mode] == "lines+markers"
	@test_throws ArgumentError plot_scatter(x, x; markevery = [0, 11])

	g = plot_scatter(1:3, [1, 2, 3]; fill = "tozeroy", fillcolor = "rgba(0,0,255,0.2)")
	@test g.data[1].fields[:fill] == "tozeroy"
	@test g.data[1].fields[:fillcolor] == "rgba(0,0,255,0.2)"
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; fill = "tozero")
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; line_shape = "steps")
	@test_throws ArgumentError plot_scatterpolar([0, 90, 180], [1, 2, 3]; line_shape = "hv")

	t = plot_scatter(1:3, [1, 2, 3]; text = ["a", L"\alpha", 3], textposition = "top center",
		textsize = 14, mode = "markers")
	@test t.data[1].fields[:mode] == "markers+text"
	@test t.data[1].fields[:text] == ["a", "α", "3"]
	@test t.data[1].fields[:textposition] == "top center"
	@test _rsc_get(t.data[1].fields[:textfont], :size) == 14
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; text = ["a", "b", "c"], textposition = "top")
	nested_text = plot_scatter([[1, 2], [3, 4]]; text = [["a", "b"], ["c", "d"]])
	@test nested_text.data[2].fields[:text] == ["c", "d"]

	clipped = plot_scatter(1:3, [1, 2, 3]; clip = false)
	@test clipped.data[1].fields[:cliponaxis] === false
	@test !haskey(plot_scatter(1:3, [1, 2, 3]).data[1].fields, :cliponaxis)
end

@testset "scatter family: error bars, symmetric and asymmetric (C31)" begin
	f = plot_scatter(1:3, [1.0, 2, 3]; error_y = [0.1, 0.2, 0.3],
		error_x = ([0.1, 0.1, 0.1], [0.4, 0.5, 0.6]))
	ey = _rsc_fields(f.data[1].fields[:error_y])
	@test ey[:type] == "data"
	@test ey[:array] == [0.1, 0.2, 0.3]
	@test !haskey(ey, :symmetric)
	ex = _rsc_fields(f.data[1].fields[:error_x])
	@test ex[:symmetric] === false
	@test ex[:array] == [0.4, 0.5, 0.6]
	@test ex[:arrayminus] == [0.1, 0.1, 0.1]

	nested = [[1.0, 2, 3], [3.0, 2, 1]]
	g = plot_scatter(nested; error_y = ([[0.1, 0.1, 0.1], [0.2, 0.2, 0.2]],
		[[0.3, 0.3, 0.3], [0.4, 0.4, 0.4]]))
	@test _rsc_get(g.data[2].fields[:error_y], :arrayminus) == [0.2, 0.2, 0.2]
	@test _rsc_get(g.data[2].fields[:error_y], :array) == [0.4, 0.4, 0.4]
	h = plot_scatter(nested; error_y = [([0.1, 0.1, 0.1], [0.2, 0.2, 0.2]),
		([0.3, 0.3, 0.3], [0.4, 0.4, 0.4])])
	@test _rsc_get(h.data[1].fields[:error_y], :array) == [0.2, 0.2, 0.2]
	shared = plot_scatter(nested; error_y = [0.5, 0.5, 0.5])
	@test all(_rsc_get(t.fields[:error_y], :array) == [0.5, 0.5, 0.5] for t in shared.data)

	@test_throws ArgumentError plot_scatter(nested; error_y = ([[0.1, 0.1, 0.1]], [[0.1, 0.1, 0.1], [0.2, 0.2, 0.2]]))
	@test_throws ArgumentError plot_scatter(nested; error_y = ([0.1, 0.1, 0.1], [[0.1, 0.1, 0.1]]))
	@test_throws ArgumentError plot_scatter(nested; error_y = (1, 2))
	@test_throws ArgumentError plot_scatter(nested; error_y = 0.1)
	@test_throws ArgumentError plot_scatter(nested; error_y = ([0.1, 0.1, 0.1],))
end

@testset "scatter family: ticks, equal aspect and figure keywords (C16)" begin
	f = plot_scatter(1:3, [1, 10, 100]; xticks = [1, 2, 3], xticklabels = ["a", "b", "c"],
		yscale = "log", yticks = [1, 10, 100], ytickformat = ".0f", equalar = false)
	xa = _rsc_axis(f, :xaxis)
	@test xa[:tickmode] == "array"
	@test xa[:tickvals] == [1.0, 2.0, 3.0]
	@test xa[:ticktext] == ["a", "b", "c"]
	ya = _rsc_axis(f, :yaxis)
	@test ya[:tickvals] == [1.0, 10.0, 100.0]
	@test ya[:tickformat] == ".0f"
	@test _rsc_axis(plot_stem(1:3, [1, 2, 3]; xtickformat = ".1f"), :xaxis)[:tickformat] == ".1f"

	e = plot_scatter(1:3, [1, 2, 3]; equalar = true)
	ye = _rsc_axis(e, :yaxis)
	@test ye[:scaleanchor] == "x"
	@test ye[:scaleratio] == 1.0

	# Tick keywords are checked before the figure changes.
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; xticklabels = ["a"])
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; xticks = [1, 2], xticklabels = ["a"])
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; yscale = "log", yticks = [0, 1])
	p = plot_scatter(1:3, [1, 2, 3])
	snapshot = _rsc_snapshot(p)
	@test_throws ArgumentError plot_scatter!(p, 1:3, [1, 2, 3]; yscale = "log", yticks = [-1, 1])
	@test _rsc_unchanged(p, snapshot)
	@test_throws ArgumentError PlotlySupply._scat_validate_ticks(
		p, :yaxis, [1, 2], ["a"], "", "plot_scatter!", "y")

	g = plot_scatter(1:3, [1, 2, 3]; title = "T", xlabel = "X", ylabel = "Y",
		width = 640, height = 480, fontsize = 13)
	@test _rsc_get(g.layout.fields[:title], :text) == "T"
	@test _rsc_get(_rsc_axis(g, :xaxis)[:title], :text) == "X"
	@test g.layout.fields[:width] == 640
	@test g.layout.fields[:height] == 480
	@test _rsc_get(g.layout.fields[:font], :size) == 13
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; width = -1)
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; grid = :diagonal)
end

@testset "scatter family: scatterpolar options and theta units (C33, 248)" begin
	f = plot_scatterpolar([0, 90, 180], [1, 2, 3]; fill = "toself", direction = "clockwise",
		rotation = 90, thetaunit = "radians", fillcolor = "rgba(255,0,0,0.3)")
	@test f.data[1].fields[:fill] == "toself"
	@test f.data[1].fields[:thetaunit] == "radians"
	angular = _rsc_fields(_rsc_fields(f.layout.fields[:polar])[:angularaxis])
	@test angular[:direction] == "clockwise"
	@test angular[:rotation] == 90
	@test angular[:thetaunit] == "radians"
	@test_throws ArgumentError plot_scatterpolar([0, 90], [1, 2]; thetaunit = "grad")
	@test_throws ArgumentError plot_scatterpolar([0, 90], [1, 2]; direction = "left")
	@test_throws ArgumentError plot_scatterpolar([0, 90], [1, 2]; rotation = NaN)
	@test_throws ArgumentError plot_scatterpolar([0, 90], [1, 2]; fill = "tozeroy")
	@test_throws ArgumentError plot_scatterpolar([0, 90], [1, 2]; grid = :x)
	@test_throws ArgumentError plot_scatterpolar!(f, [0, 90], [1, 2]; secondary_y = true)
	doc = string(@doc plot_scatterpolar)
	@test occursin("degrees", doc)
	@test occursin("thetaunit", doc)
end

@testset "scatter family: secondary_y on a plain figure (C35)" begin
	p = plot_scatter(1:3, [1, 2, 3]; ylabel = "left", legend = "a")
	plot_scatter!(p, 1:3, [10, 100, 1000]; secondary_y = true, ylabel = "right",
		yscale = "log", yrange = [1, 1000], legend = "b")
	@test p.data[2].fields[:yaxis] == "y2"
	y2 = _rsc_axis(p, :yaxis2)
	@test y2[:overlaying] == "y"
	@test y2[:side] == "right"
	@test y2[:type] == "log"
	@test y2[:range] ≈ [0.0, 3.0]
	@test _rsc_get(y2[:title], :text) == "right"
	@test _rsc_get(_rsc_axis(p, :yaxis)[:title], :text) == "left"
	@test !haskey(_rsc_axis(p, :yaxis), :type)
	# The twin axis is reused, not duplicated.
	plot_stem!(p, 1:3, [5, 50, 500]; secondary_y = true, legend = "c")
	plot_area!(p, 1:3, [5, 50, 500]; secondary_y = true, legend = "d")
	@test all(t.fields[:yaxis] == "y2" for t in p.data[3:end])
	@test !haskey(p.layout.fields, :yaxis3)
	@test_throws ArgumentError plot_scatter!(p, 1:3, [1, 2, 3]; secondary_y = "yes")
	# Bad twin-axis options are rejected before anything changes.
	q = plot_scatter(1:3, [1, 2, 3])
	snapshot = _rsc_snapshot(q)
	@test_throws ArgumentError plot_scatter!(q, 1:3, [1, 2, 3]; secondary_y = true,
		yscale = "log", yrange = [0, 10])
	@test _rsc_unchanged(q, snapshot)
end

@testset "scatter family: mutator keyword contract (show, unknown keywords)" begin
	for (mutate!, args) in (
		(plot_scatter!, (1:3, [1, 2, 3])),
		(plot_stem!, (1:3, [1, 2, 3])),
		(plot_area!, (1:3, [1, 2, 3])),
		(plot_scatterpolar!, ([0, 90, 180], [1, 2, 3])),
		(plot!, (1:3, [1, 2, 3])),
	)
		p = plot_scatter(1:3, [1, 2, 3])
		snapshot = _rsc_snapshot(p)
		err = try
			mutate!(p, args...; show = true)
		catch e
			e
		end
		@test err isa ArgumentError
		@test occursin("`show`", err.msg)
		@test_throws ArgumentError mutate!(p, args...; colour = "red")
		@test_throws ArgumentError mutate!(p, args...; row = 2)
		@test _rsc_unchanged(p, snapshot)
		@test mutate!(p, args...; row = nothing, col = nothing) === nothing
	end
	@test_throws MethodError plot_scatter(1:3, [1, 2, 3]; colour = "red")
end

@testset "scatter family: SyncPlot and SubplotFigure mutators" begin
	sp = _rsc_syncplot(plot_scatter(1:3, [1, 2, 3]))
	@test plot_scatter!(sp, 1:3, [3, 2, 1]; legend = "b") === nothing
	@test plot_stem!(sp, 1:3, [1, 2, 3]; legend = "s") === nothing
	@test plot_area!(sp, 1:3, [1, 2, 3]; stack = true) === nothing
	@test plot!(sp, 1:3, [2, 2, 2]) === nothing
	@test length(sp.plot.data) == 6
	@test sp.plot.data[2].fields[:name] == "b"
	@test_throws ArgumentError plot_scatter!(sp, 1:3, [1, 2]; legend = "bad")
	@test length(sp.plot.data) == 6

	sp_polar = _rsc_syncplot(plot_scatterpolar([0, 90], [1, 2]))
	@test plot_scatterpolar!(sp_polar, [0, 90], [2, 3]) === nothing
	@test length(sp_polar.plot.data) == 2

	sf = subplots(2, 2; sync = false, specs = [
		PlotlySupply.Spec() PlotlySupply.Spec(kind = "polar");
		PlotlySupply.Spec(secondary_y = true) PlotlySupply.Spec()
	])
	@test plot_scatter!(sf, 1:3, [1, 2, 3]; row = 2, col = 1, legend = "left") === sf
	@test plot_scatter!(sf, 1:3, [30, 20, 10]; row = 2, col = 1, secondary_y = true, legend = "right") === sf
	@test plot_scatterpolar!(sf, [0, 90, 180], [1, 2, 3]; row = 1, col = 2) === sf
	@test plot_stem!(sf, 1:3, [1, -1, 2]; row = 2, col = 2, legend = "stem") === sf
	@test plot_area!(sf, 1:3, [1, 2, 3]; row = 2, col = 2) === sf
	@test plot!(sf, 1:3, [3, 2, 1]; row = 2, col = 2) === sf
	data = sf.plot.data
	@test length(data) == 7
	@test data[1].fields[:xaxis] == "x2" && data[1].fields[:yaxis] == "y2"
	@test data[2].fields[:xaxis] == "x2" && data[2].fields[:yaxis] == "y3"
	@test data[3].fields[:subplot] == "polar"
	@test all(t.fields[:xaxis] == "x3" && t.fields[:yaxis] == "y4" for t in data[4:7])
	@test data[4].fields[:legendgroup] == data[5].fields[:legendgroup]
	@test_throws ArgumentError plot_scatter!(sf, 1:3, [1, 2, 3]; row = 1, col = 1, show = true)
	@test_throws ArgumentError plot_scatter!(sf, 1:3, [1, 2]; row = 1, col = 1)
	@test length(sf.plot.data) == 7

	# Default colours and legend groups follow the real figure, not the
	# scratch figure the delegate builds the traces in.
	sf2 = subplots(1, 2; sync = false)
	plot_scatter!(sf2, 1:3, [1, 2, 3]; row = 1, col = 1)
	plot_stem!(sf2, 1:3, [1, 2, 3]; row = 1, col = 1)
	plot_scatter!(sf2, 1:3, [1, 2, 3]; row = 1, col = 2, marker_color = "white", mode = "markers")
	@test _rsc_get(_rsc_fields(sf2.plot.data[4].fields[:marker])[:line], :color) ==
		PlotlySupply._default_trace_color(sf2, 4)
	plot_stem!(sf2, 1:3, [1, 2, 3]; row = 1, col = 2)
	@test sf2.plot.data[5].fields[:legendgroup] != sf2.plot.data[2].fields[:legendgroup]
	@test sf2.plot.data[5].fields[:legendgroup] == sf2.plot.data[6].fields[:legendgroup]
end

@testset "scatter family: the active style's trace cycle" begin
	f = with_style(:default; cycle = :dash_marker) do
		plot_scatter([[1, 2, 3], [3, 2, 1]])
	end
	@test [_rsc_get(t.fields[:line], :dash) for t in f.data] == ["solid", "dash"]
	@test [t.fields[:mode] for t in f.data] == ["lines+markers", "lines+markers"]
	@test [_rsc_get(t.fields[:marker], :symbol) for t in f.data] == ["circle", "square"]
	# The cycle continues across appended traces, and explicit keywords win.
	with_style(:default; cycle = :dash_marker) do
		plot_scatter!(f, [1, 2, 3]; dash = "longdash")
		plot_scatter!(f, [1, 2, 3])
	end
	@test _rsc_get(f.data[3].fields[:line], :dash) == "longdash"
	@test _rsc_get(f.data[4].fields[:line], :dash) == "dashdot"
	plain = plot_scatter([[1, 2, 3], [3, 2, 1]])
	@test all(!haskey(t.fields, :line) for t in plain.data)
end

@testset "scatter family: plot! alias" begin
	p = plot_scatter(1:3, [1, 2, 3])
	@test plot!(p, 1:3, [3, 2, 1]; legend = "b", mode = "markers") === nothing
	@test length(p.data) == 2
	@test p.data[2].fields[:mode] == "markers"
	@test plot!(p, [5, 6]) === nothing
	@test p.data[3].fields[:x] == 0:1
	@test occursin("plot_scatter!", string(@doc plot!))
end

@testset "scatter family: docstrings list every keyword (45, 55, 66, 77, 105, 302)" begin
	scatter_doc = string(@doc plot_scatter)
	for key in ("linewidth", "error_x", "error_y", "show", "marker_color", "markevery",
		"line_shape", "fill", "text", "clip", "xticks", "equalar", "grid", "opacity")
		@test occursin(key, scatter_doc)
	end
	mutator_doc = string(@doc plot_scatter!)
	for key in ("secondary_y", "row", "show", "grid = nothing")
		@test occursin(key, mutator_doc)
	end
	stem_doc = string(@doc plot_stem)
	for key in ("baseline", "marker_symbol", "marker_color", "linewidth", "legendgroup", "show")
		@test occursin(key, stem_doc) || (key == "legendgroup" && occursin("legend group", stem_doc))
	end
	area_doc = string(@doc plot_area)
	for key in ("stack", "hatch", "xscale", "yscale", "show")
		@test occursin(key, area_doc)
	end
	@test occursin("secondary_y", string(@doc plot_area!))
	@test occursin("secondary_y", string(@doc plot_stem!))
end

# ── wave 3 (oned-int) ────────────────────────────────────────────────────────

_rsc_error(f) = try
	f()
	nothing
catch err
	err
end
_rsc_text(value) = value isa AbstractString ? value : _rsc_get(value, :text)
_rsc_axis_or_empty(fig, key) =
	_rsc_fields(get(PlotlySupply._plot_obj(fig).layout.fields, key, Dict{Symbol, Any}()))
_rsc_line(trace) = _rsc_fields(get(trace.fields, :line, Dict{Symbol, Any}()))
_rsc_marker(trace) = _rsc_fields(get(trace.fields, :marker, Dict{Symbol, Any}()))
# Trace contents with arrays collected, to compare figures built from views,
# ranges and plain vectors.
_rsc_traces(fig) = [
	repr(Dict(key => (value isa AbstractArray ? collect(value) : value) for (key, value) in _rsc_fields(trace)))
	for trace in PlotlySupply._plot_obj(fig).data
]

@testset "scatter family: ranges have the xrange!/yrange! semantics (X23, 18, 52, 76, 93)" begin
	for (build, mutate!) in (
		(r -> plot_scatter(1:3, [1.0, 2, 3]; xrange = r), (f, r) -> plot_scatter!(f, 1:3, [1.0, 2, 3]; xrange = r)),
		(r -> plot_stem(1:3, [1.0, 2, 3]; yrange = r), (f, r) -> plot_stem!(f, 1:3, [1.0, 2, 3]; yrange = r)),
		(r -> plot_area(1:3, [1.0, 2, 3]; xrange = r), (f, r) -> plot_area!(f, 1:3, [1.0, 2, 3]; xrange = r)),
	)
		for (bad, message) in (
			((nothing, 2), "partial ranges are not supported"),
			([1, nothing], "partial ranges are not supported"),
			((false, true), "must be numbers"),
			([2, 2], "must differ"),
			((1, 2, 3), "exactly 2 elements"),
		)
			err = _rsc_error(() -> build(bad))
			@test err isa ArgumentError
			@test occursin(message, err.msg)
			fig = build(nothing)
			snapshot = _rsc_snapshot(fig)
			err = _rsc_error(() -> mutate!(fig, bad))
			@test err isa ArgumentError && occursin(message, err.msg) && occursin("!:", err.msg)
			@test _rsc_unchanged(fig, snapshot)
		end
		# Automatic forms: no stored range.
		for automatic in (nothing, [0, 0], (0, 0), [nothing, nothing], (nothing, nothing))
			fig = build(automatic)
			@test !haskey(_rsc_axis_or_empty(fig, :xaxis), :range)
			@test !haskey(_rsc_axis_or_empty(fig, :yaxis), :range)
		end
	end
	err = _rsc_error(() -> plot_scatter(1:3, [1.0, 2, 3]; xscale = "linear", xrange = ("a", "b")))
	@test startswith(err.msg, "plot_scatter:") && occursin("numeric `xrange` bounds", err.msg)
	# Mutator ranges are data values on a log axis, as for `xrange!`.
	f = plot_scatter([1, 10, 100], [1.0, 2, 3])
	plot_scatter!(f, [1, 10, 100], [2.0, 3, 4]; xscale = "log", xrange = (1, 1000))
	@test _rsc_axis(f, :xaxis)[:type] == "log"
	@test _rsc_axis(f, :xaxis)[:range] ≈ [0.0, 3.0]
	@test_throws ArgumentError plot_scatter!(f, [1, 10], [1.0, 2]; xrange = (0, 10))

	# Polar sector and radial range: both bounds, distinct, numeric.
	@test occursin("must differ", _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; trange = (10, 10))).msg)
	@test occursin("must be numbers", _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; rrange = ("a", "b"))).msg)
	@test occursin("partial", _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; rrange = (nothing, 2))).msg)
	auto = plot_scatterpolar([0, 90], [1, 2]; rrange = [nothing, nothing], trange = (0, 0))
	polar = _rsc_fields(auto.layout.fields[:polar])
	@test !haskey(polar, :sector)
	@test !haskey(_rsc_fields(polar[:radialaxis]), :range)
	# On a log radial axis `rrange` is in data units.
	logpolar = plot_scatterpolar([0, 90], [1, 100])
	relayout!(logpolar; polar_radialaxis_type = "log")
	plot_scatterpolar!(logpolar, [0, 90], [2, 50]; rrange = (1, 100))
	@test _rsc_fields(_rsc_fields(logpolar.layout.fields[:polar])[:radialaxis])[:range] ≈ [0.0, 2.0]
	@test_throws ArgumentError plot_scatterpolar!(logpolar, [0, 90], [2, 50]; rrange = (0, 100))
end

@testset "scatter family: tick presets reach the shared tick helper (D9)" begin
	# The tick keywords accept the presets `:decades` and `:auto` and forward
	# them to `_apply_ticks!` (src/sci/base.jl) unchanged; this checks the
	# family's own validation of them.
	fig = plot_scatter([1, 10, 100], [1.0, 2, 3]; xscale = "log")
	validate(; kw...) = PlotlySupply._scat_validate_cartesian_options(fig, "probe"; kw...)
	@test validate(; xticks = :decades) === nothing                 # x axis already log
	@test validate(; yscale = "log", yticks = :decades) === nothing
	@test validate(; xticks = :auto, yticks = :auto) === nothing
	err = _rsc_error(() -> validate(; yticks = :decades))
	@test err isa ArgumentError && occursin("logarithmic y axis", err.msg)
	err = _rsc_error(() -> validate(; xticks = :auto, xticklabels = ["a"]))
	@test err isa ArgumentError && occursin("cannot be combined with the tick preset", err.msg)
	@test_throws ArgumentError validate(; xticks = :weekly)
	# Constructors and mutators of all three families run this validator.
	for call in (
		() -> plot_scatter(1:3, [1.0, 2, 3]; xticks = :decades),
		() -> plot_stem(1:3, [1.0, 2, 3]; yticks = :decades),
		() -> plot_bar([1, 2]; yticks = :decades),
		() -> plot_ecdf([1.0, 2.0]; xticks = :decades),
		() -> plot_scatter!(plot_scatter(1:3, [1.0, 2, 3]), 1:3, [1.0, 2, 3]; xticks = :decades),
	)
		err = _rsc_error(call)
		@test err isa ArgumentError && occursin("needs a logarithmic", err.msg)
	end
end

@testset "scatter family: PlotStyle trace defaults on every series (X10)" begin
	style_kw = (; cycle = :dash_marker, linewidth = 2, marker_size = 7)
	symbols = PlotlySupply._STYLE_MARKER_CYCLE
	dashes = PlotlySupply._STYLE_DASH_CYCLE
	f = with_style(; style_kw...) do
		g = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; legend = ["a", "b"])
		plot_scatter!(g, 1:3, [2, 2, 2]; legend = "c", mode = "lines")
		plot_scatter!(g, 1:3, [1, 1, 1]; legend = "d", dash = "longdash", linewidth = 5)
		plot_vlines!(g, [1.5, 2.5], 0, 1; legend = "v")
		plot_ecdf!(g, [1.0, 2.0, 3.0]; legend = "e")
		plot_stem!(g, 1:3, [0.5, -0.5, 0.2]; legend = "s")
		plot_area!(g, 1:3, [0.1, 0.2, 0.1]; legend = "area")
		g
	end
	d = f.data
	@test length(d) == 9
	# Unset keywords take the cycle at the trace's position; explicit ones win.
	@test [_rsc_get(_rsc_line(t), :dash) for t in d[1:4]] == [dashes[1], dashes[2], dashes[3], "longdash"]
	@test [_rsc_get(_rsc_line(t), :width) for t in d[1:4]] == [2, 2, 2, 5]
	@test [t.fields[:mode] for t in d[1:4]] == ["lines+markers", "lines+markers", "lines", "lines+markers"]
	@test [_rsc_get(_rsc_marker(t), :symbol) for t in d[[1, 2, 4]]] == [symbols[1], symbols[2], symbols[4]]
	@test all(_rsc_get(_rsc_marker(t), :size) == 7 for t in d[[1, 2, 4]])
	# Segment collections and ECDF steps: width and dash cycle, no markers.
	for (index, t) in zip(5:6, d[5:6])
		@test t.fields[:mode] == "lines"
		@test _rsc_get(_rsc_line(t), :width) == 2
		@test _rsc_get(_rsc_line(t), :dash) == dashes[mod1(index, length(dashes))]
		@test !haskey(_rsc_marker(t), :symbol)
	end
	# Stems: the heads take the marker cycle, the stem lines the width only.
	heads, stems = d[7], d[8]
	@test heads.fields[:mode] == "markers"
	@test _rsc_get(_rsc_marker(heads), :symbol) == symbols[mod1(7, length(symbols))]
	@test _rsc_get(_rsc_line(stems), :width) == 2
	@test !haskey(_rsc_line(stems), :dash) && stems.fields[:mode] == "lines"
	# Filled areas: the width only.
	@test _rsc_get(_rsc_line(d[9]), :width) == 2
	@test !haskey(_rsc_line(d[9]), :dash) && !haskey(_rsc_marker(d[9]), :symbol)
	# Without a style width the stems keep their thin default.
	@test _rsc_get(_rsc_line(plot_stem(1:3, [1.0, 2, 3]).data[2]), :width) == PlotlySupply._STEM_DEFAULT_LINEWIDTH

	# The cycle runs over the whole SubplotFigure, cell after cell.
	sf = with_style(; style_kw...) do
		s = subplots(1, 2; sync = false)
		plot_scatter!(s, 1:3, [[1, 2, 3], [3, 2, 1]]; row = 1, col = 1)
		plot_scatter!(s, 1:3, [[1, 2, 3], [3, 2, 1]]; row = 1, col = 2)
		s
	end
	@test [_rsc_get(_rsc_line(t), :dash) for t in sf.plot.data] == dashes[1:4]
	@test [_rsc_get(_rsc_marker(t), :symbol) for t in sf.plot.data] == symbols[1:4]
	# SyncPlot mutators style the appended traces only.
	sp = _rsc_syncplot(plot_scatter(1:3, [1, 2, 3]))
	with_style(; style_kw...) do
		plot_scatter!(sp, 1:3, [3, 2, 1])
	end
	@test !haskey(sp.plot.data[1].fields, :line)
	@test _rsc_get(_rsc_line(sp.plot.data[2]), :dash) == dashes[2]
	@test _rsc_get(_rsc_line(sp.plot.data[2]), :width) == 2
	# plot_complex draws markers by default, styled with the cycle; the unit
	# circle keeps its own look.
	c = with_style(; style_kw...) do
		plot_complex(cis.(range(0, 2pi; length = 8)); unit_circle = true)
	end
	@test c.data[1].fields[:mode] == "markers"
	@test _rsc_get(_rsc_marker(c.data[1]), :symbol) == symbols[1]
	@test c.data[2].fields[:mode] == "lines" && !haskey(_rsc_marker(c.data[2]), :symbol)
	# :publication sets fonts and colours, no per-trace defaults.
	pub = with_style(:publication) do
		plot_scatter(1:3, [[1, 2, 3], [3, 2, 1], [2, 2, 2], [1, 3, 1]])
	end
	@test all(!haskey(t.fields, :line) && t.fields[:mode] == "lines" for t in pub.data)
end

@testset "scatter family: inset = k on every SubplotFigure mutator (X20)" begin
	log_kw = (; yscale = "log", yrange = (1, 1000))
	axis_kw = (; xrange = (0.5, 3.5), xlabel = "ix", ylabel = "iy")
	cases = (
		(sf -> plot_scatter!(sf, 1:3, [1.0, 10, 100]; inset = 1, log_kw..., axis_kw...), true),
		(sf -> plot_stem!(sf, 1:3, [1.0, 10, 100]; inset = 1, baseline = 1, log_kw..., axis_kw...), true),
		(sf -> plot_area!(sf, 1:3, [1.0, 10, 100]; inset = 1, log_kw..., axis_kw...), true),
		(sf -> plot!(sf, 1:3, [1.0, 10, 100]; inset = 1, log_kw..., axis_kw...), true),
		(sf -> plot_band!(sf, 1:3, 1, [2.0, 20, 200]; inset = 1, log_kw..., axis_kw...), true),
		(sf -> plot_segments!(sf, 1, 1, 3, 100; inset = 1, log_kw..., axis_kw...), true),
		(sf -> plot_vlines!(sf, [1.5, 2.5], 1, 100; inset = 1, log_kw..., axis_kw...), true),
		(sf -> plot_hlines!(sf, [2.0, 20.0], 1, 3; inset = 1, log_kw..., axis_kw...), true),
		(sf -> plot_ecdf!(sf, [1.0, 2.0, 3.0]; inset = 1, axis_kw...), false),
		(sf -> plot_kde!(sf, [1.0, 2.0, 3.0]; inset = 1, cut = 0, axis_kw...), false),
		(sf -> plot_complex!(sf, [1 + 1im, 2 + 2im]; inset = 1, axis_kw...), false),
	)
	for (mutate!, log_y) in cases
		sf = subplots(1, 1; sync = false)
		inset!(sf, (0.55, 0.55, 0.4, 0.4))
		@test mutate!(sf) === sf
		@test !isempty(sf.plot.data)
		@test all(t.fields[:xaxis] == "x2" && t.fields[:yaxis] == "y2" for t in sf.plot.data)
		inset_x, inset_y = _rsc_axis(sf, :xaxis2), _rsc_axis(sf, :yaxis2)
		@test inset_x[:range] == [0.5, 3.5]
		@test _rsc_text(inset_x[:title]) == "ix" && _rsc_text(inset_y[:title]) == "iy"
		if log_y
			@test inset_y[:type] == "log" && inset_y[:range] ≈ [0.0, 3.0]
		end
		main_x, main_y = _rsc_axis_or_empty(sf, :xaxis), _rsc_axis_or_empty(sf, :yaxis)
		@test !haskey(main_x, :range) && !haskey(main_y, :type) && !haskey(main_y, :range)
		@test !haskey(main_x, :title) || isempty(_rsc_text(main_x[:title]))
	end

	# An inset of a cell other than (1, 1); a wrong cell or id is rejected
	# before anything changes.
	grid = subplots(2, 2; sync = false)
	inset!(grid, (0.6, 0.6, 0.35, 0.35); row = 2, col = 2)
	plot_scatter!(grid, 1:3, [1, 2, 3]; row = 2, col = 2, inset = 1, xrange = (0, 4))
	inset_ref = grid.plot.data[1].fields[:xaxis]
	@test inset_ref ∉ ("x", "x4")
	@test _rsc_axis(grid, Symbol("xaxis", inset_ref[2:end]))[:range] == [0, 4]
	@test !haskey(_rsc_axis_or_empty(grid, :xaxis4), :range)
	err = _rsc_error(() -> plot_stem!(grid, 1:3, [1, 2, 3]; row = 1, col = 1, inset = 1))
	@test err isa ArgumentError && occursin("belongs to cell (2, 2)", err.msg)
	err = _rsc_error(() -> plot_ecdf!(grid, [1.0, 2.0]; row = 2, col = 2, inset = 2))
	@test err isa ArgumentError
	@test length(grid.plot.data) == 1
	# A Plot has no insets; a polar cell has no inset axes.
	@test_throws ArgumentError plot_scatter!(plot_scatter(1:3, 1:3), 1:3, 1:3; inset = 1)
	polar = subplots(1, 2; sync = false, specs = [PlotlySupply.Spec(kind = "polar") PlotlySupply.Spec()])
	inset!(polar, (0.55, 0.55, 0.4, 0.4); row = 1, col = 2)
	@test_throws ArgumentError plot_scatterpolar!(polar, [0, 90], [1, 2]; row = 1, col = 2, inset = 1)
	@test_throws ArgumentError plot_scatterpolar!(polar, [0, 90], [1, 2]; row = 1, col = 1, secondary_y = true)
	@test isempty(polar.plot.data)
end

@testset "scatter family: radial tick labels off the 0° spoke (V4)" begin
	radial(f) = _rsc_fields(_rsc_fields(PlotlySupply._plot_obj(f).layout.fields[:polar])[:radialaxis])
	plain = plot_scatterpolar([0, 90, 180], [1, 2, 3])
	@test radial(plain)[:angle] == PlotlySupply._SCAT_POLAR_RLABEL_ANGLE == 22.5
	@test radial(plain)[:nticks] == PlotlySupply._SCAT_POLAR_RADIAL_NTICKS
	sector = plot_scatterpolar([0, 90], [1, 2]; trange = (90, 180))
	@test radial(sector)[:angle] == 90
	@test radial(plot_scatterpolar([0, 90], [1, 2]; trange = (0, 360)))[:angle] == 22.5
	@test radial(plot_scatterpolar([0, 90], [1, 2]; rlabel_angle = -45))[:angle] == -45
	# An angle set earlier is kept, unless a new sector excludes it.
	kept = plot_scatterpolar([0, 90], [1, 2]; rlabel_angle = 135)
	plot_scatterpolar!(kept, [0, 90], [2, 3])
	@test radial(kept)[:angle] == 135
	plot_scatterpolar!(kept, [0, 90], [2, 3]; trange = (0, 90))
	@test radial(kept)[:angle] == 0
	plot_scatterpolar!(kept, [0, 90], [2, 3]; rlabel_angle = 30)
	@test radial(kept)[:angle] == 30
	for bad in (NaN, Inf, true)
		err = _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; rlabel_angle = bad))
		@test err isa ArgumentError && occursin("rlabel_angle", err.msg)
	end
	snapshot = _rsc_snapshot(kept)
	@test_throws ArgumentError plot_scatterpolar!(kept, [0, 90], [2, 3]; rlabel_angle = NaN)
	@test _rsc_unchanged(kept, snapshot)
	# Tick settings made by the user are kept.
	ticked = plot_scatterpolar([0, 90], [1, 2])
	relayout!(ticked; polar_radialaxis_dtick = 0.25, polar_radialaxis_nticks = nothing)
	plot_scatterpolar!(ticked, [0, 90], [2, 3])
	@test radial(ticked)[:dtick] == 0.25
	@test get(radial(ticked), :nticks, nothing) === nothing

	# SubplotFigure: each polar cell gets its own angle; a user angle stays.
	sf = subplots(1, 2; sync = false, specs = [PlotlySupply.Spec(kind = "polar") PlotlySupply.Spec(kind = "polar")])
	plot_scatterpolar!(sf, [0, 90], [1, 2]; row = 1, col = 2)
	polar2() = _rsc_fields(_rsc_fields(sf.plot.layout.fields[:polar2])[:radialaxis])
	@test polar2()[:angle] == 22.5
	@test polar2()[:nticks] == PlotlySupply._SCAT_POLAR_RADIAL_NTICKS
	update_polars!(sf; row = 1, col = 2, radialaxis = attr(angle = 200))
	plot_scatterpolar!(sf, [0, 90], [3, 4]; row = 1, col = 2)
	@test polar2()[:angle] == 200
	plot_scatterpolar!(sf, [0, 90], [3, 4]; row = 1, col = 1, rlabel_angle = 60)
	@test _rsc_fields(_rsc_fields(sf.plot.layout.fields[:polar])[:radialaxis])[:angle] == 60
	@test polar2()[:angle] == 200
	@test occursin("rlabel_angle", string(@doc plot_scatterpolar))
	@test occursin("rlabel_angle", string(@doc plot_scatterpolar!))
end

@testset "scatter family: the default legend avoids the data (V5)" begin
	function placement(f)
		legend = _rsc_fields(PlotlySupply._plot_obj(f).layout.fields[:legend])
		return (legend[:x], legend[:y], legend[:xanchor], legend[:yanchor])
	end
	TR = (0.98, 0.97, "right", "top")
	TL = (0.02, 0.97, "left", "top")
	BL = (0.02, 0.03, "left", "bottom")
	BR = (0.98, 0.03, "right", "bottom")
	RIGHT = (0.98, 0.5, "right", "middle")
	@test placement(plot_scatter(1:10, (10:-1:1) .^ 2; legend = "falling")) == TR
	@test placement(plot_scatter(1:10, (1:10) .^ 2; legend = "rising")) == TL
	# Error-bar ends count, with plotly's 5 % autorange padding.
	y = [2.0, 3.1, 2.8, 4.0, 4.4, 5.1]
	@test placement(plot_scatter(1:6, y; mode = "markers", error_y = fill(0.3, 6), legend = "e")) == TL
	# Twin y: the right-axis data is scored on its own scale, inside the plot
	# area (the right-axis tick labels stay clear).
	twin = plot_scatter(1:10, (1:10) .^ 2; legend = "left")
	plot_scatter!(twin, 1:10, 10.0 .^ (1:10); secondary_y = true, yscale = "log", legend = "right")
	@test placement(twin) == TL
	# An automatic legend follows the data as series are appended: with all
	# four corners taken it moves to the middle of the right edge.
	crossing = plot_scatter(1:10, (10:-1:1) .^ 2; legend = "left: falling")
	@test placement(crossing) == TR
	plot_scatter!(crossing, 1:10, 10.0 .^ (1:10) ./ 1e3; secondary_y = true, yscale = "log",
		legend = "right: rising (log)")
	@test placement(crossing) == RIGHT
	moved = plot_scatter([0, 10, 5], [0, 0, 10]; mode = "markers", legend = "a")
	@test placement(moved) == TR
	plot_scatter!(moved, [10], [10]; mode = "markers", legend = "b")
	@test placement(moved) == TL
	sp = _rsc_syncplot(plot_scatter([0, 10, 5], [0, 0, 10]; mode = "markers", legend = "a"))
	plot_scatter!(sp, [10], [10]; mode = "markers", legend = "b")
	@test placement(sp) == TL
	# The line family takes part.
	lines = plot_scatter([0, 10, 5], [0, 0, 10]; mode = "markers", legend = "a")
	plot_segments!(lines, 9, 9, 10, 10; legend = "segment")
	@test placement(lines) == TL
	# A position chosen by the user stays.
	user = plot_scatter(1:10, (1:10) .^ 2; legend = "rising")
	set_legend!(user; position = :bottomright)
	plot_scatter!(user, 1:10, 100 .- (1:10) .^ 2; legend = "falling")
	@test placement(user) == BR
	relayout!(user; legend_x = 0.5)
	plot_scatter!(user, 1:10, collect(1:10); legend = "third")
	@test placement(user)[1] == 0.5
	# Unknown extents (categories, bars) keep the default corner.
	@test placement(plot_scatter(["a", "b"], [1, 2]; legend = "cat")) == TR
	mixed = plot_bar(1:10, (1:10) .^ 2; legend = "bars")
	plot_scatter!(mixed, 1:10, (1:10) .^ 2; legend = "line")
	@test placement(mixed) == TR
	# Off while another default position is set.
	try
		set_default_legend_position!(:bottomleft)
		@test placement(plot_scatter(1:10, (1:10) .^ 2; legend = "rising")) == BL
	finally
		set_default_legend_position!(:topright)
	end
	# Step lines are scored along their steps.
	step(shape) = placement(plot_scatter([0.0, 10.0], [0.0, 10.0]; mode = "lines", line_shape = shape, legend = shape))
	@test step("linear") == TL
	@test step("vh") == BL
	@test step("hv") == TR
	@test occursin("set_legend!", string(@doc plot_scatter))
end

@testset "consistency sweep: constructors and mutators of the 1-D families" begin
	x = collect(1.0:5.0)
	y = [1.0, 3.0, 2.0, 5.0, 4.0]
	samples = [0.5, 1.2, 2.3, 2.9, 3.1, 4.0, 4.4, 1.7]
	# (constructor, mutator, data, position of the series argument (0: none),
	# takes `color`, takes `legend`, takes `xscale`)
	cases = (
		(plot_scatter, plot_scatter!, (x, y), 2, true, true, true),
		(plot_stem, plot_stem!, (x, y), 2, true, true, true),
		(plot_area, plot_area!, (x, y), 2, true, true, true),
		(plot_bar, plot_bar!, (x, y), 2, true, true, true),
		(plot_histogram, plot_histogram!, (samples,), 1, true, true, true),
		(plot_box, plot_box!, (samples,), 1, true, true, true),
		(plot_violin, plot_violin!, (samples,), 1, true, true, true),
		(plot_histogram2d, plot_histogram2d!, (samples, reverse(samples)), 0, false, false, true),
		(plot_band, plot_band!, (x, y .- 0.5, y .+ 0.5), 0, true, true, true),
		(plot_segments, plot_segments!, (x, y, x .+ 0.5, y .+ 0.5), 0, true, true, true),
		(plot_vlines, plot_vlines!, (x, 1.0, 2.0), 0, true, true, true),
		(plot_hlines, plot_hlines!, (y, 1.0, 2.0), 0, true, true, true),
		(plot_ecdf, plot_ecdf!, (samples,), 1, true, true, true),
		(plot_kde, plot_kde!, (samples,), 1, true, true, true),
		(plot_complex, plot_complex!, (cis.(range(0, 2pi; length = 5)),), 0, true, true, false),
	)
	for (ctor, mut, args, series_at, has_color, has_legend, has_scale) in cases
		# A KDE curve reaches `cut` bandwidths past the data; `cut = 0` keeps
		# it on the positive log axis of (g).
		extra = ctor === plot_kde ? (; cut = 0) : NamedTuple()
		@testset "$(nameof(ctor))" begin
			# (a) ranges as tuple and as vector.
			tuple_fig = ctor(args...; extra..., xrange = (0.5, 6), yrange = (0.1, 9))
			vector_fig = ctor(args...; extra..., xrange = [0.5, 6], yrange = [0.1, 9])
			@test _rsc_axis(tuple_fig, :xaxis)[:range] == [0.5, 6] == _rsc_axis(vector_fig, :xaxis)[:range]
			@test _rsc_axis(tuple_fig, :yaxis)[:range] == [0.1, 9] == _rsc_axis(vector_fig, :yaxis)[:range]
			for bad in ([1], (2, 2), (false, true), (nothing, 2))
				@test_throws ArgumentError ctor(args...; extra..., xrange = bad)
			end
			# (b) Symbol and String colours.
			if has_color
				@test _rsc_traces(ctor(args...; extra..., color = :red)) ==
					_rsc_traces(ctor(args...; extra..., color = "red"))
			end
			# (c) LaTeXString and SubString labels.
			latex = ctor(args...; extra..., title = L"$\alpha$", xlabel = L"$x_1$", ylabel = SubString("abcd", 1, 2))
			plain = ctor(args...; extra..., title = "\$\\alpha\$", xlabel = "\$x_1\$", ylabel = "ab")
			@test _rsc_text(latex.layout.fields[:title]) == _rsc_text(plain.layout.fields[:title])
			@test _rsc_text(_rsc_axis(latex, :xaxis)[:title]) == _rsc_text(_rsc_axis(plain, :xaxis)[:title])
			@test _rsc_text(_rsc_axis(latex, :yaxis)[:title]) == "ab"
			if has_legend
				@test _rsc_traces(ctor(args...; extra..., legend = L"$\beta$")) ==
					_rsc_traces(ctor(args...; extra..., legend = "\$\\beta\$"))
			end
			# (d) SubArray, UnitRange and Vector{Any} inputs; matrices rejected.
			views = map(a -> a isa AbstractVector ? view(a, :) : a, args)
			@test _rsc_traces(ctor(views...; extra...)) == _rsc_traces(ctor(args...; extra...))
			if args[1] === x
				@test length(ctor(1:5, args[2:end]...; extra...).data) == length(ctor(args...; extra...).data)
			end
			if series_at > 0
				head = args[1:(series_at - 1)]
				multi = ctor(head..., Any[args[series_at], args[series_at]]; extra...)
				@test length(multi.data) == 2 * length(ctor(args...; extra...).data)
				M = hcat(args[series_at], args[series_at])
				@test_throws ArgumentError ctor(head..., M; extra...)
				@test_throws ArgumentError ctor(head..., view(M, :, 1:2); extra...)
			end
			# (e) `show` on a mutator and (f) unknown keywords.
			fig = ctor(args...; extra...)
			snapshot = _rsc_snapshot(fig)
			err = _rsc_error(() -> mut(fig, args...; extra..., show = true))
			@test err isa ArgumentError && occursin("mutators do not take `show`", err.msg)
			err = _rsc_error(() -> mut(fig, args...; extra..., bogus_kw = 1))
			@test err isa ArgumentError && occursin("unsupported keyword argument(s) `bogus_kw`", err.msg)
			@test _rsc_unchanged(fig, snapshot)
			@test_throws MethodError ctor(args...; extra..., bogus_kw = 1)
			@test mut(fig, args...; extra..., row = nothing, col = nothing) === nothing
			# (g) a log x axis with a data-unit range: on a Plot, on cell (2, 2)
			# of a SubplotFigure and on an inset.
			scale = has_scale ? (; xscale = "log") : NamedTuple()
			stored = has_scale ? log10.([0.5, 10]) : [0.5, 10]
			if has_scale
				logged = ctor(args...; extra..., scale..., xrange = (0.5, 10))
				@test _rsc_axis(logged, :xaxis)[:type] == "log"
				@test _rsc_axis(logged, :xaxis)[:range] ≈ stored
				@test _rsc_axis(logged, :xaxis)[:exponentformat] == "power"   # X22
				target = ctor(args...; extra...)
				mut(target, args...; extra..., scale..., xrange = (0.5, 10))
				@test _rsc_axis(target, :xaxis)[:range] ≈ stored
			end
			sf = subplots(2, 2; sync = false)
			@test mut(sf, args...; extra..., scale..., row = 2, col = 2, xrange = (0.5, 10)) === sf
			@test _rsc_axis(sf, :xaxis4)[:range] ≈ stored
			has_scale && @test _rsc_axis(sf, :xaxis4)[:type] == "log"
			@test !haskey(_rsc_axis_or_empty(sf, :xaxis), :range)
			ins = subplots(1, 1; sync = false)
			inset!(ins, (0.55, 0.55, 0.4, 0.4))
			@test mut(ins, args...; extra..., scale..., inset = 1, xrange = (0.5, 10)) === ins
			@test all(t.fields[:xaxis] == "x2" for t in ins.plot.data)
			@test _rsc_axis(ins, :xaxis2)[:range] ≈ stored
			@test !haskey(_rsc_axis_or_empty(ins, :xaxis), :type)
		end
	end
end

@testset "docstrings list every keyword; Cartesian members take the common set (77, 105, 302, 251, 306)" begin
	declared(f) = Set{Symbol}(
		key for method in methods(f) for key in Base.kwarg_decl(method) if key !== Symbol("kwargs...")
	)
	documented(f, key) = occursin(Regex("`" * string(key) * "[`\\s=:]"), string(Base.Docs.doc(f)))
	families = (
		(plot_scatter, plot_scatter!), (plot_stem, plot_stem!), (plot_area, plot_area!),
		(plot_scatterpolar, plot_scatterpolar!), (plot_bar, plot_bar!),
		(plot_histogram, plot_histogram!), (plot_box, plot_box!), (plot_violin, plot_violin!),
		(plot_histogram2d, plot_histogram2d!), (plot_band, plot_band!),
		(plot_segments, plot_segments!), (plot_vlines, plot_vlines!), (plot_hlines, plot_hlines!),
		(plot_ecdf, plot_ecdf!), (plot_kde, plot_kde!), (plot_complex, plot_complex!),
	)
	common = (:xlabel, :ylabel, :title, :xrange, :yrange, :xscale, :yscale, :width, :height,
		:fontsize, :grid, :legend)
	# Keywords of the common set that make no sense for a member; its docstring
	# says so.
	exceptions = Dict{Any, Vector{Symbol}}(
		plot_histogram2d => [:legend],
		plot_complex => [:xscale, :yscale],
		plot_scatterpolar => [:xlabel, :ylabel, :xrange, :yrange, :xscale, :yscale],
	)
	for (ctor, mut) in families
		ctor_keys = declared(ctor)
		mut_keys = declared(mut)
		# Every constructor keyword is documented ...
		@test sort([key for key in ctor_keys if !documented(ctor, key)]) == Symbol[]
		# ... a mutator takes all of them but `show` ...
		@test sort(collect(setdiff(ctor_keys, mut_keys))) == [:show]
		@test documented(mut, :show)
		# ... and documents its own extras (row/col/secondary_y/inset).
		@test sort([key for key in setdiff(mut_keys, ctor_keys) if !documented(mut, key)]) == Symbol[]
		lacking = sort([key for key in common if !(key in ctor_keys)])
		@test lacking == sort(get(exceptions, ctor, Symbol[]))
		@test sort([key for key in common if !(key in mut_keys)]) == lacking
		doc = string(Base.Docs.doc(ctor))
		@test all(key -> occursin(string(key), doc), lacking)
	end
	@test occursin("degrees", string(@doc plot_scatterpolar))
end
