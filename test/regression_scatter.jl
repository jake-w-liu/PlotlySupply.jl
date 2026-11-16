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
