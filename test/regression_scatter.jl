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
	# oned-stem-no-frame: the stems come first (drawn below the heads) instead
	# of a negative zorder, which made plotly 2.35 draw no axis lines.
	stem, head = f.data
	@test head.fields[:mode] == "markers"
	@test head.fields[:y] === y
	@test stem.fields[:mode] == "lines"
	@test head.fields[:legendgroup] == stem.fields[:legendgroup]
	@test stem.fields[:showlegend] === false
	@test stem.fields[:hoverinfo] == "skip"
	@test !haskey(stem.fields, :zorder) && !haskey(head.fields, :zorder)
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
	@test [t.fields[:mode] for t in g.data] == ["lines", "lines", "markers", "markers"]
	@test g.data[1].fields[:legendgroup] == g.data[3].fields[:legendgroup]
	@test g.data[2].fields[:legendgroup] == g.data[4].fields[:legendgroup]
	@test g.data[1].fields[:legendgroup] != g.data[2].fields[:legendgroup]
	@test [t.fields[:name] for t in g.data[3:4]] == ["a", "b"]

	# Appended series get legend groups that never collide with existing ones.
	plot_stem!(g, 0:4, randn(5); legend = "c")
	groups = [g.data[k].fields[:legendgroup] for k in (1, 2, 5)]
	@test g.data[5].fields[:mode] == "lines" && g.data[6].fields[:mode] == "markers"
	@test allunique(groups)
	@test g.data[5].fields[:legendgroup] == g.data[6].fields[:legendgroup]

	p = Plot(Layout())
	@test plot_stem!(p, [1, 2, 3], [1.0, 2, 3]) === nothing
	@test length(p.data) == 2
end

@testset "scatter family: plot_stem baseline, colours and marker keywords (C30)" begin
	f = plot_stem(1:3, [1.0, -2.0, 3.0]; baseline = -0.5, color = "crimson",
		marker_symbol = "s", marker_size = 9.5, linewidth = 2, legend = "s")
	stem, head = f.data
	@test stem.fields[:y][1:3] == [-0.5, 1.0, nothing]
	@test stem.fields[:y][4:6] == [-0.5, -2.0, nothing]
	@test _rsc_get(stem.fields[:line], :color) == "crimson"
	@test _rsc_get(stem.fields[:line], :width) == 2
	@test _rsc_get(head.fields[:marker], :symbol) == "square"
	@test _rsc_get(head.fields[:marker], :size) == 9.5
	@test _rsc_get(head.fields[:marker], :color) == "crimson"

	# White heads keep the colorway colour as their edge; stems stay black.
	w = plot_stem(1:3, [1.0, 2.0, 3.0]; marker_color = "white", legend = "w")
	marker = _rsc_fields(w.data[2].fields[:marker])
	@test marker[:color] == "white"
	@test _rsc_get(marker[:line], :color) == PlotlySupply._default_trace_color(w, 1)
	@test _rsc_get(w.data[1].fields[:line], :color) == "black"

	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; baseline = Inf)
	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; baseline = true)
	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; marker_symbol = "nope")
	@test_throws ArgumentError plot_stem(1:3, [1.0, 2, 3]; linewidth = -1)
end

@testset "scatter family: unnamed stems have no legend entry (63, 72, 103, 303)" begin
	f = plot_stem([3.0, 1.0, 2.0])
	@test f.data[1].fields[:showlegend] === false
	@test !any(PlotlySupply._trace_will_showlegend, f.data)
	# The legend entry is the heads' (stems first, oned-stem-no-frame).
	q = plot_stem([3.0, 1.0, 2.0]; legend = "s")
	@test !haskey(q.data[2].fields, :showlegend)
	@test PlotlySupply._trace_will_showlegend(q.data[2])
	h = plot_stem([3.0, 1.0, 2.0]; showlegend = true)
	@test h.data[2].fields[:showlegend] === true
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
	@test_throws ArgumentError PlotlySupply._validate_tick_option(
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
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; colour = "red")   # invariant 4
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
	# D20: the cycle restarts in every cell, so the first trace of cell (1, 2)
	# takes the first colour.
	@test _rsc_get(_rsc_fields(sf2.plot.data[4].fields[:marker])[:line], :color) ==
		PlotlySupply._default_trace_color(sf2, 1)
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
		# One-sided limits (D11) are checked by `_rsc_partial_range_parity`.
		for (bad, message) in (
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
	# K7: the message is the shared primitive's (`_require_range_bound_types`):
	# it names the function, the keyword, the axis type and the bad value.
	err = _rsc_error(() -> plot_scatter(1:3, [1.0, 2, 3]; xscale = "linear", xrange = ("a", "b")))
	@test err isa ArgumentError
	@test startswith(err.msg, "plot_scatter:")
	@test occursin("`xrange` bounds on a linear axis must be numbers", err.msg)
	@test occursin(repr(("a", "b")), err.msg)
	err = _rsc_error(() -> plot_stem!(plot_stem(1:3, [1.0, 2, 3]), 1:3, [1.0, 2, 3];
		yscale = "linear", yrange = ["a", "b"]))
	@test err isa ArgumentError && startswith(err.msg, "plot_stem!:") &&
		occursin("`yrange` bounds on a linear axis must be numbers", err.msg)
	# Mutator ranges are data values on a log axis, as for `xrange!`.
	f = plot_scatter([1, 10, 100], [1.0, 2, 3])
	plot_scatter!(f, [1, 10, 100], [2.0, 3, 4]; xscale = "log", xrange = (1, 1000))
	@test _rsc_axis(f, :xaxis)[:type] == "log"
	@test _rsc_axis(f, :xaxis)[:range] ≈ [0.0, 3.0]
	@test_throws ArgumentError plot_scatter!(f, [1, 10], [1.0, 2]; xrange = (0, 10))

	# Polar sector and radial range: both bounds, distinct, numeric. They stay
	# two-sided whatever the Cartesian one-sided limits (D11) accept.
	@test occursin("must differ", _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; trange = (10, 10))).msg)
	@test occursin("must be numbers", _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; rrange = ("a", "b"))).msg)
	# (`rrange` takes one-sided limits since wave 5b: D11; only a `missing`
	# bound is an error there.)
	for partial in ((nothing, 2), [1, nothing], (0, missing))
		for keyword in (:rrange, :trange)
			keyword === :rrange && partial !== (0, missing) && continue
			err = _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; keyword => partial))
			@test err isa ArgumentError && startswith(err.msg, "plot_scatterpolar:") &&
				occursin("`$(keyword)` must give both bounds", err.msg)
		end
		target = plot_scatterpolar([0, 90], [1, 2])
		snapshot = _rsc_snapshot(target)
		err = _rsc_error(() -> plot_scatterpolar!(target, [0, 90], [2, 1]; trange = partial))
		@test err isa ArgumentError && startswith(err.msg, "plot_scatterpolar!:")
		@test _rsc_unchanged(target, snapshot)
	end
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
	# Y34: the messages are those of the shared `_validate_tick_option`.
	err = _rsc_error(() -> validate(; yticks = :decades))
	@test err isa ArgumentError && startswith(err.msg, "probe:") &&
		occursin("needs a logarithmic axis; :yaxis has type", err.msg)
	err = _rsc_error(() -> validate(; xticks = :auto, xticklabels = ["a"]))
	@test err isa ArgumentError && occursin("`xticklabels` need explicit `xticks` values", err.msg)
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
	stems, heads = d[7], d[8]          # stems first (oned-stem-no-frame)
	@test heads.fields[:mode] == "markers"
	@test _rsc_get(_rsc_marker(heads), :symbol) == symbols[mod1(7, length(symbols))]
	@test _rsc_get(_rsc_line(stems), :width) == 2
	@test !haskey(_rsc_line(stems), :dash) && stems.fields[:mode] == "lines"
	# Filled areas: the width only.
	@test _rsc_get(_rsc_line(d[9]), :width) == 2
	@test !haskey(_rsc_line(d[9]), :dash) && !haskey(_rsc_marker(d[9]), :symbol)
	# Without a style width the stems keep their thin default.
	@test _rsc_get(_rsc_line(plot_stem(1:3, [1.0, 2, 3]).data[1]), :width) == PlotlySupply._STEM_DEFAULT_LINEWIDTH

	# The cycle restarts in every cell of a SubplotFigure (D20).
	sf = with_style(; style_kw...) do
		s = subplots(1, 2; sync = false)
		plot_scatter!(s, 1:3, [[1, 2, 3], [3, 2, 1]]; row = 1, col = 1)
		plot_scatter!(s, 1:3, [[1, 2, 3], [3, 2, 1]]; row = 1, col = 2)
		s
	end
	@test [_rsc_get(_rsc_line(t), :dash) for t in sf.plot.data] == collect(dashes[[1, 2, 1, 2]])
	@test [_rsc_get(_rsc_marker(t), :symbol) for t in sf.plot.data] == collect(symbols[[1, 2, 1, 2]])
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
	# Categories and bars are scored too (v7 vm-05/style-03): rising data
	# takes the top right and leaves the top left free.
	@test placement(plot_scatter(["a", "b"], [1, 2]; legend = "cat")) == TL
	mixed = plot_bar(1:10, (1:10) .^ 2; legend = "bars")
	plot_scatter!(mixed, 1:10, (1:10) .^ 2; legend = "line")
	@test placement(mixed) == TL
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
			# One-sided limits follow `_checked_range` (D11, parity testset).
			for bad in ([1], (2, 2), (false, true))
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
			# plot_scatter rejects an unknown keyword itself (invariant 4); the other
			# constructors still leave it to Julia (cross-requested, errors-inputs-05).
			@test_throws (ctor === plot_scatter ? ArgumentError : MethodError) ctor(args...; extra..., bogus_kw = 1)
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

# ── wave 4 (oned) ────────────────────────────────────────────────────────────

# The axis fields `_apply_axis_range!` (src/sci/base.jl) writes for `range` on
# `ref` (the figure a call builds without the range: an aspect-locked figure
# such as plot_complex's pins a one-sided limit to the data, D11), or the
# error it throws (`who = "REF"`).
function _rsc_primitive_range(range, letter::Symbol, ref = Plot(GenericTrace[], Layout()))
	err = _rsc_error(() -> PlotlySupply._apply_axis_range!(ref, letter, range, "REF"))
	return err, _rsc_axis_or_empty(ref, letter === :x ? :xaxis : :yaxis)
end

# Whether `axis` carries every field the primitive wrote (and the same
# `range`/`autorange` presence).
_rsc_axis_matches(axis, ref) =
	all(((key, value),) -> isequal(get(axis, key, nothing), value), pairs(ref)) &&
	all(key -> isequal(get(axis, key, nothing), get(ref, key, nothing)), (:range, :autorange))

const _RSC_ONE_SIDED = ((nothing, 2), [1, nothing], (0, nothing), (nothing, 2.5), [missing, 3])

@testset "scatter family: one-sided range keywords follow the shared primitive (D11, G41)" begin
	# The family no longer re-checks partial ranges itself: whatever
	# `_checked_range` decides (one-sided limits are being added there, D11)
	# reaches every constructor and mutator unchanged. Before that change
	# lands the primitive rejects them and the family must throw the same
	# message, naming itself; afterwards the axis must get exactly what the
	# primitive writes.
	cases = (
		("plot_scatter", :x, r -> plot_scatter(1:3, [1.0, 2, 3]; xrange = r),
			(f, r) -> plot_scatter!(f, 1:3, [1.0, 2, 3]; xrange = r)),
		("plot_stem", :y, r -> plot_stem(1:3, [1.0, 2, 3]; yrange = r),
			(f, r) -> plot_stem!(f, 1:3, [1.0, 2, 3]; yrange = r)),
		("plot_area", :y, r -> plot_area(1:3, [1.0, 2, 3]; yrange = r),
			(f, r) -> plot_area!(f, 1:3, [1.0, 2, 3]; yrange = r)),
		("plot_band", :y, r -> plot_band(1:3, [1.0, 2, 3], [2.0, 3, 4]; yrange = r),
			(f, r) -> plot_band!(f, 1:3, [1.0, 2, 3], [2.0, 3, 4]; yrange = r)),
		("plot_ecdf", :x, r -> plot_ecdf([1.0, 2, 3]; xrange = r),
			(f, r) -> plot_ecdf!(f, [1.0, 2, 3]; xrange = r)),
		("plot_complex", :y, r -> plot_complex([1 + 1im, 2 + 0.5im]; yrange = r),
			(f, r) -> plot_complex!(f, [1 + 1im, 2 + 0.5im]; yrange = r)),
	)
	for (who, letter, build, mutate!) in cases, partial in _RSC_ONE_SIDED
		key = letter === :x ? :xaxis : :yaxis
		# K7: the reference is the primitive applied to the family's own figure
		# (an empty figure has no aspect lock, so it never matched plot_complex).
		ref_err, ref_axis = _rsc_primitive_range(partial, letter, build(nothing))
		if ref_err === nothing
			fig = build(partial)
			@test _rsc_axis_matches(_rsc_axis_or_empty(fig, key), ref_axis)
			target = build(nothing)
			mutate!(target, partial)
			@test _rsc_axis_matches(_rsc_axis_or_empty(target, key), ref_axis)
		else
			@test ref_err isa ArgumentError
			err = _rsc_error(() -> build(partial))
			@test err isa ArgumentError
			@test err.msg == replace(ref_err.msg, "REF:" => "$(who):"; count = 1)
			target = build(nothing)
			snapshot = _rsc_snapshot(target)
			err = _rsc_error(() -> mutate!(target, partial))
			@test err isa ArgumentError
			@test err.msg == replace(ref_err.msg, "REF:" => "$(who)!:"; count = 1)
			@test _rsc_unchanged(target, snapshot)
		end
	end
	# The documented semantics: a one-sided limit is handled as by `yrange!`.
	@test occursin("one-sided limit", string(@doc plot_scatter))
	# The best-legend estimate reads a one-sided axis as plotly draws it: the
	# fixed bound, and the padded data extent on the autoscaled side.
	window(axis) = PlotlySupply._scat_legend_window(Layout(yaxis = axis), :yaxis, [5.0, 10.0]; padded = true)
	free_lo, free_hi = window(attr())
	@test free_lo < 5 && free_hi > 10
	@test window(attr(range = [0, nothing], autorange = "max")) == (0.0, free_hi)
	@test window(attr(range = [nothing, 20], autorange = "min")) == (free_lo, 20.0)
	# A fixed bound past the data leaves the data-only window.
	@test window(attr(range = [12, nothing], autorange = "max")) == (free_lo, free_hi)
	@test window(attr(range = [0, 20], autorange = false)) == (0.0, 20.0)
	# Wave 5: the encoding `_write_axis_range!` stores (`autorange` with
	# `autorangeoptions.minallowed`/`maxallowed`) is read the same way.
	@test window(attr(autorange = true, autorangeoptions = attr(minallowed = 0))) == (0.0, free_hi)
	@test window(attr(autorange = true, autorangeoptions = attr(maxallowed = 20))) == (free_lo, 20.0)
	@test window(attr(autorange = true, autorangeoptions = attr(minallowed = 12))) == (free_lo, free_hi)
	@test window(attr(autorange = "reversed", autorangeoptions = attr(minallowed = 0))) == (free_hi, 0.0)
	# What the keywords write is what the estimate reads.
	stored = plot_scatter([1.0, 2], [5.0, 10.0]; yrange = (0, nothing))
	@test PlotlySupply._scat_legend_window(stored.layout, :yaxis, [5.0, 10.0]; padded = true) == (0.0, free_hi)
end

@testset "scatter family: equal range bounds are rejected everywhere (G33)" begin
	cases = (
		("plot_scatter", (; kw...) -> plot_scatter(1:3, [1.0, 2, 3]; kw...),
			(f; kw...) -> plot_scatter!(f, 1:3, [1.0, 2, 3]; kw...)),
		("plot_stem", (; kw...) -> plot_stem(1:3, [1.0, 2, 3]; kw...),
			(f; kw...) -> plot_stem!(f, 1:3, [1.0, 2, 3]; kw...)),
		("plot_area", (; kw...) -> plot_area(1:3, [1.0, 2, 3]; kw...),
			(f; kw...) -> plot_area!(f, 1:3, [1.0, 2, 3]; kw...)),
		("plot_band", (; kw...) -> plot_band(1:3, [1.0, 2, 3], [2.0, 3, 4]; kw...),
			(f; kw...) -> plot_band!(f, 1:3, [1.0, 2, 3], [2.0, 3, 4]; kw...)),
		("plot_segments", (; kw...) -> plot_segments([0.0], [0.0], [1.0], [1.0]; kw...),
			(f; kw...) -> plot_segments!(f, [0.0], [0.0], [1.0], [1.0]; kw...)),
		("plot_vlines", (; kw...) -> plot_vlines([1.0], 0.0, 1.0; kw...),
			(f; kw...) -> plot_vlines!(f, [1.0], 0.0, 1.0; kw...)),
		("plot_ecdf", (; kw...) -> plot_ecdf([1.0, 2, 3]; kw...),
			(f; kw...) -> plot_ecdf!(f, [1.0, 2, 3]; kw...)),
		("plot_kde", (; kw...) -> plot_kde([1.0, 2, 3]; kw...),
			(f; kw...) -> plot_kde!(f, [1.0, 2, 3]; kw...)),
		("plot_complex", (; kw...) -> plot_complex([1 + 1im, 2 + 0.5im]; kw...),
			(f; kw...) -> plot_complex!(f, [1 + 1im, 2 + 0.5im]; kw...)),
	)
	for (who, build, mutate!) in cases, (name, equal) in ((:xrange, [2, 2]), (:yrange, (5.0, 5.0)))
		err = _rsc_error(() -> build(; name => equal))
		@test err isa ArgumentError
		@test startswith(err.msg, "$(who):") && occursin("must differ", err.msg) &&
			occursin("`$(name)`", err.msg)
		target = build()
		snapshot = _rsc_snapshot(target)
		err = _rsc_error(() -> mutate!(target; name => equal))
		@test err isa ArgumentError && startswith(err.msg, "$(who)!:") && occursin("must differ", err.msg)
		@test _rsc_unchanged(target, snapshot)
	end
	# The twin y axis of `secondary_y = true` is checked the same way.
	target = plot_scatter(1:3, [1.0, 2, 3])
	snapshot = _rsc_snapshot(target)
	err = _rsc_error(() -> plot_scatter!(target, 1:3, [1.0, 2, 3]; secondary_y = true, yrange = (4, 4)))
	@test err isa ArgumentError && occursin("must differ", err.msg)
	@test _rsc_unchanged(target, snapshot)
	# Polar ranges too.
	err = _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; rrange = (5, 5)))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatterpolar:") && occursin("must differ", err.msg)
end

@testset "scatter family: the twin y axis uses the key-based primitives (Y35)" begin
	# Scale switch on an existing twin: the explicit range is converted as on
	# the primary axis (`_apply_axis_scale_to_key!`), log exponents in layout.
	p = plot_scatter(1:3, [1.0, 2, 3])
	plot_scatter!(p, 1:3, [10.0, 100, 1000]; secondary_y = true, yrange = (10, 1000))
	@test _rsc_axis(p, :yaxis2)[:range] == [10, 1000]
	plot_scatter!(p, 1:3, [20.0, 200, 900]; secondary_y = true, yscale = "log")
	y2 = _rsc_axis(p, :yaxis2)
	@test y2[:type] == "log"
	@test y2[:range] ≈ [1.0, 3.0]
	@test y2[:exponentformat] == "power"
	# A switch that cannot keep the range is rejected up front, as for `yscale`
	# on the primary axis, and names the keyword that fixes it.
	q = plot_scatter(1:3, [1.0, 2, 3])
	plot_scatter!(q, 1:3, [1.0, 2, 3]; secondary_y = true, yrange = (-1, 5))
	snapshot = _rsc_snapshot(q)
	err = _rsc_error(() -> plot_scatter!(q, 1:3, [1.0, 2, 3]; secondary_y = true, yscale = "log"))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatter!:") && occursin("yrange", err.msg)
	@test _rsc_unchanged(q, snapshot)
	# Bound types on a linear twin, positive bounds on a log twin.
	err = _rsc_error(() -> plot_stem!(q, 1:3, [1.0, 2, 3]; secondary_y = true, yscale = "linear", yrange = ("a", "b")))
	@test err isa ArgumentError && occursin("`yrange` bounds on a linear axis must be numbers", err.msg)
	err = _rsc_error(() -> plot_area!(q, 1:3, [1.0, 2, 3]; secondary_y = true, yscale = "log", yrange = (0, 5)))
	@test err isa ArgumentError && occursin("must be positive", err.msg)
	@test _rsc_unchanged(q, snapshot)
	# Tick presets on the twin: `:decades` needs its final type to be log.
	r = plot_scatter(1:3, [1.0, 2, 3])
	err = _rsc_error(() -> plot_scatter!(r, 1:3, [1.0, 2, 3]; secondary_y = true, yticks = :decades))
	@test err isa ArgumentError && occursin("needs a logarithmic axis", err.msg)
	@test !haskey(r.layout.fields, :yaxis2)
	plot_scatter!(r, 1:3, [1.0, 20, 300]; secondary_y = true, yscale = "log", yticks = :decades)
	y2 = _rsc_axis(r, :yaxis2)
	@test y2[:tickmode] == "linear" && y2[:dtick] == 1 && y2[:tick0] == 0
	# The removed family duplicates stay removed (one implementation).
	@test !isdefined(PlotlySupply, :_scat_require_axis_range)
	@test !isdefined(PlotlySupply, :_scat_apply_axis_options!)
	@test !isdefined(PlotlySupply, :_scat_validate_ticks)
end

@testset "scatter family: tick presets on a Plot and in a SubplotFigure cell (Y34)" begin
	decades = (tickmode = "linear", tick0 = 0, dtick = 1, exponentformat = "power")
	check(axis) = all(((key, value),) -> isequal(get(axis, key, nothing), value), pairs(decades))
	@test check(_rsc_axis(plot_scatter([1, 10, 100], [1.0, 2, 3]; xscale = "log", xticks = :decades), :xaxis))
	@test check(_rsc_axis(plot_stem([1, 10, 100], [1.0, 2, 3]; xscale = "log", xticks = :decades), :xaxis))
	@test check(_rsc_axis(plot_area([1.0, 2, 3], [1, 10, 100]; yscale = "log", yticks = :decades), :yaxis))
	@test check(_rsc_axis(plot_ecdf(exp10.([0.0, 1, 2]); xscale = "log", xticks = :decades), :xaxis))
	auto = plot_scatter([1, 10, 100], [1.0, 2, 3]; xscale = "log", xticks = [1, 100])
	plot_scatter!(auto, [1, 10], [1.0, 2]; xticks = :auto)
	@test !haskey(_rsc_axis(auto, :xaxis), :tickvals)
	@test !haskey(_rsc_axis(auto, :xaxis), :tickmode)
	# In a cell: the delegate's scratch axes carry the cell's log type.
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, [1, 10, 100], [1.0, 2, 3]; row = 1, col = 2, xscale = "log", xticks = :decades)
	@test check(_rsc_axis(sf.plot, :xaxis2))
	@test !haskey(_rsc_axis_or_empty(sf.plot, :xaxis), :dtick)
	err = _rsc_error(() -> plot_stem!(sf, [1, 2], [1.0, 2]; row = 1, col = 1, xticks = :decades))
	@test err isa ArgumentError && startswith(err.msg, "plot_stem!:") && occursin("needs a logarithmic axis", err.msg)
end

@testset "scatter family: markevery keeps every text label visible (G28)" begin
	labels = ["a", "b", "c", "d", "e", "f"]
	f = plot_scatter(1:6, 1:6; mode = "lines+markers+text", markevery = 2, text = labels, textsize = 14)
	fields = f.data[1].fields
	@test fields[:selectedpoints] == [0, 2, 4]
	textfont = _rsc_fields(fields[:textfont])
	unselected = _rsc_fields(fields[:unselected])
	# plotly.js dims unselected text unless `unselected.textfont.color` is set;
	# both use the colour the text is drawn in (the template's font colour).
	template_font = _rsc_fields(PlotlySupply._template_layout_fields(PlotlySupply._figure_template(f))[:font])
	template_color = template_font[:color]
	@test template_color isa AbstractString && !isempty(template_color)
	@test textfont[:color] == template_color
	@test textfont[:size] == 14
	@test _rsc_get(unselected[:textfont], :color) == template_color
	@test _rsc_get(unselected[:marker], :opacity) == 0
	# An explicit figure font colour wins over the template's.
	g = plot_scatter(1:3, 1:3)
	relayout!(g; font_color = "#123456")
	plot_scatter!(g, 1:3, [3, 2, 1]; markevery = [1], text = ["x", "y", "z"])
	@test _rsc_get(g.data[2].fields[:textfont], :color) == "#123456"
	@test _rsc_get(_rsc_get(g.data[2].fields[:unselected], :textfont), :color) == "#123456"
	# Without markevery (no selection) or without text nothing is pinned.
	@test !haskey(plot_scatter(1:3, 1:3; text = ["a", "b", "c"]).data[1].fields, :textfont)
	h = plot_scatter(1:3, 1:3; markevery = 2)
	@test !haskey(_rsc_fields(h.data[1].fields[:unselected]), :textfont)
	@test !haskey(h.data[1].fields, :textfont)
	# In a SubplotFigure cell the colour comes from the real figure.
	sf = subplots(1, 2; sync = false)
	relayout!(sf; font_color = "#654321")
	plot_scatter!(sf, 1:4, 1:4; row = 1, col = 2, markevery = 2, text = ["p", "q", "r", "s"])
	trace = sf.plot.data[end].fields
	@test _rsc_get(trace[:textfont], :color) == "#654321"
	@test _rsc_get(_rsc_get(trace[:unselected], :textfont), :color) == "#654321"
	@test occursin("full strength", string(@doc plot_scatter))
end

@testset "scatterpolar: radial label angle and tick count are overridable defaults (K6)" begin
	f = plot_scatterpolar([0, 90, 180], [1, 2, 3])
	polar = _rsc_fields(f.layout.fields[:polar])
	@test !haskey(polar, :sector)
	radial = _rsc_fields(polar[:radialaxis])
	@test radial[:angle] == PlotlySupply._SCAT_POLAR_RLABEL_ANGLE == 22.5
	@test radial[:nticks] == PlotlySupply._SCAT_POLAR_RADIAL_NTICKS == 6
	# `trange` sets the sector and puts the labels at its start.
	g = plot_scatterpolar([0, 90], [1, 2]; trange = (0, 180))
	@test _rsc_fields(g.layout.fields[:polar])[:sector] == [0, 180]
	# User settings are kept: an explicit `rlabel_angle`, and an angle or tick
	# setting made on the figure before the next call.
	h = plot_scatterpolar([0, 90, 180], [1, 2, 3]; rlabel_angle = 45)
	@test _rsc_fields(_rsc_fields(h.layout.fields[:polar])[:radialaxis])[:angle] == 45
	relayout!(h; polar_radialaxis_angle = 70, polar_radialaxis_dtick = 0.5)
	plot_scatterpolar!(h, [0, 90], [2, 1])
	radial = _rsc_fields(_rsc_fields(h.layout.fields[:polar])[:radialaxis])
	@test radial[:angle] == 70
	@test radial[:dtick] == 0.5
end

@testset "oned families: the six tick keywords on every Cartesian constructor and mutator (G30)" begin
	sample = collect(range(-2, 2; length = 40))
	members = (
		(plot_scatter, plot_scatter!, (1:3, [1.0, 2, 3])),
		(plot_stem, plot_stem!, (1:3, [1.0, 2, 3])),
		(plot_area, plot_area!, (1:3, [1.0, 2, 3])),
		(plot_bar, plot_bar!, (1:3, [1.0, 2, 3])),
		(plot_histogram, plot_histogram!, (sample,)),
		(plot_box, plot_box!, (sample,)),
		(plot_violin, plot_violin!, (sample,)),
		(plot_histogram2d, plot_histogram2d!, (sample, reverse(sample))),
		(plot_band, plot_band!, (1:3, [0.0, 0, 0], [1.0, 2, 3])),
		(plot_segments, plot_segments!, ([0.0], [0.0], [1.0], [1.0])),
		(plot_vlines, plot_vlines!, ([1.0, 2], 0.0, 1.0)),
		(plot_hlines, plot_hlines!, ([1.0, 2], 0.0, 1.0)),
		(plot_ecdf, plot_ecdf!, (sample,)),
		(plot_kde, plot_kde!, (sample,)),
		(plot_complex, plot_complex!, ([1 + 1im, 2 - 1im],)),
	)
	ticks = (xticks = [1, 2, 3], xticklabels = ["a", "b", "c"], yticks = [0, 1, 2], yticklabels = ["p", "q", "r"])
	formats = (xtickformat = ".1f", ytickformat = ".2f")
	ticks_set(fig, xkey, ykey) =
		_rsc_axis(fig, xkey)[:tickvals] == [1, 2, 3] && _rsc_axis(fig, xkey)[:ticktext] == ["a", "b", "c"] &&
		_rsc_axis(fig, ykey)[:tickvals] == [0, 1, 2] && _rsc_axis(fig, ykey)[:ticktext] == ["p", "q", "r"]
	formats_set(fig, xkey, ykey) =
		_rsc_axis(fig, xkey)[:tickformat] == ".1f" && _rsc_axis(fig, ykey)[:tickformat] == ".2f"
	for (build, mutate!, args) in members
		name = string(nameof(build))
		@test ticks_set(build(args...; ticks...), :xaxis, :yaxis)
		@test formats_set(build(args...; formats...), :xaxis, :yaxis)
		fig = build(args...)
		@test mutate!(fig, args...; ticks...) === nothing
		@test ticks_set(fig, :xaxis, :yaxis)
		mutate!(fig, args...; formats...)
		@test formats_set(fig, :xaxis, :yaxis)
		sf = subplots(1, 2; sync = false)
		mutate!(sf, args...; row = 1, col = 2, ticks...)
		mutate!(sf, args...; row = 1, col = 2, formats...)
		@test ticks_set(sf.plot, :xaxis2, :yaxis2) && formats_set(sf.plot, :xaxis2, :yaxis2)
		@test !haskey(_rsc_axis_or_empty(sf.plot, :xaxis), :tickvals)
		# A label count that does not match the values is rejected up front.
		err = try
			build(args...; xticks = [1, 2], xticklabels = ["a"])
			nothing
		catch caught
			caught
		end
		@test err isa ArgumentError && startswith(err.msg, name * ":")
	end
end

# ── wave 5 (oned) ────────────────────────────────────────────────────────────

import Dates

# The lowered data and layout `savefig` hands the renderer for `fig`
# (`_prepare_renderer_export`, the PNG/SVG/PDF path), parsed back from JSON.
function _rsc_export(fig)
	prepared = PlotlySupply._prepare_renderer_export(PlotlySupply._plot_obj(fig), (;))
	json = PlotlySupply.PlotlyBase.JSON
	return json.parse(prepared.data_js), json.parse(prepared.layout_js)
end

_rsc_limits(fig, key) = PlotlySupply._stored_axis_limits(PlotlySupply._plot_obj(fig).layout, key)

@testset "scatter family: one-sided limits on twin, log, date and shared axes (Z51, Z52, Z38)" begin
	y5 = [1.0, 2, 3, 4, 5]
	# The twin y axis of a Plot: the bound goes to that axis only.
	f = plot_scatter(1:5, y5)
	plot_scatter!(f, 1:5, 10 .* y5; secondary_y = true, yrange = (0, nothing))
	@test _rsc_limits(f, :yaxis2) == (0, nothing)
	@test _rsc_get(_rsc_axis(f, :yaxis2), :autorange) === true
	@test _rsc_limits(f, :yaxis) == (nothing, nothing)
	# A log axis stores the bound in log10 units.
	logy = [1.0, 10, 100, 1e3, 1e4]
	@test _rsc_limits(plot_scatter(1:5, logy; yscale = "log", yrange = (1e-2, nothing)), :yaxis) == (-2, nothing)
	@test _rsc_limits(plot_scatter(1:5, logy; yscale = "log", yrange = (nothing, 1e6)), :yaxis) == (nothing, 6)
	# A date axis stores epoch milliseconds.
	days = Dates.Date(2020, 1, 1) .+ Dates.Day.(0:9)
	f = plot_scatter(days, 1.0:10; xrange = (Dates.Date(2019, 12, 20), nothing))
	@test _rsc_limits(f, :xaxis) == (1000 * Dates.datetime2unix(Dates.DateTime(2019, 12, 20)), nothing)
	# Stem and area take the same path.
	@test _rsc_limits(plot_stem(1:5, y5; yrange = (-1, nothing)), :yaxis) == (-1, nothing)
	@test _rsc_limits(plot_area(1:5, y5; yrange = (nothing, 8)), :yaxis) == (nothing, 8)
	# Shared axes: the bound set through one cell reaches every member of the
	# `matches` group (before wave 5 only the follower kept it, and the PNG
	# ignored it: probe d11_shared_lo).
	sf = subplots(1, 2; sync = false, shared_yaxes = true)
	plot_scatter!(sf, 1:5, y5; row = 1, col = 1)
	plot_scatter!(sf, 1:5, y5 .+ 1; row = 1, col = 2, yrange = (0, nothing))
	@test _rsc_limits(sf.plot, :yaxis) == (0, nothing)
	@test _rsc_limits(sf.plot, :yaxis2) == (0, nothing)
	# Z38: the export copy savefig renders keeps the encoding.
	_, layout = _rsc_export(sf)
	@test layout["yaxis"]["autorangeoptions"]["minallowed"] == 0
	@test layout["yaxis"]["autorange"] === true
	_, layout = _rsc_export(plot_scatter(1:5, logy; yscale = "log", yrange = (1e-2, nothing)))
	@test layout["yaxis"]["autorangeoptions"]["minallowed"] == -2
	# Bad bounds name the function, and a mutator changes nothing first.
	err = _rsc_error(() -> plot_scatter(1:3, [1.0, 2, 3]; yrange = ("a", "b")))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatter:")
	target = plot_scatter(1:3, [1.0, 2, 3])
	snapshot = _rsc_snapshot(target)
	err = _rsc_error(() -> plot_scatter!(target, 1:3, [1.0, 2, 3]; yrange = ("a", nothing)))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatter!:")
	@test _rsc_unchanged(target, snapshot)
end

@testset "scatter family: colour keywords take grey levels and Colorants, reject unknown names (Z63, Z10)" begin
	Colors = PlotlySupply.Colors
	cases = (
		("0.35", "#595959"),
		(Colors.RGB(1, 0, 0), "#FF0000"),
		(Colors.RGBA(0, 0, 1, 0.5), "rgba(0,0,255,0.5)"),
		("rgba(0,0,0,0.5)", "rgba(0,0,0,0.5)"),
		(:navy, "navy"),
		("#1f77b4", "#1f77b4"),
	)
	for (value, expected) in cases
		@test _rsc_line(plot_scatter(1:3, [1.0, 2, 3]; color = value).data[1])[:color] == expected
		f = plot_scatter(1:3, [1.0, 2, 3])
		plot_scatter!(f, 1:3, [3.0, 2, 1]; color = value)
		@test _rsc_line(f.data[2])[:color] == expected
		m = plot_scatter(1:3, [1.0, 2, 3]; mode = "markers", marker_color = value, marker_line_color = value)
		@test _rsc_marker(m.data[1])[:color] == expected
		@test _rsc_get(_rsc_marker(m.data[1])[:line], :color) == expected
		a = plot_scatter(1:3, [1.0, 2, 3]; fill = "tozeroy", fillcolor = value)
		@test a.data[1].fields[:fillcolor] == expected
		stem_colors = [_rsc_line(t)[:color] for t in plot_stem(1:3, [1.0, 2, 3]; color = value).data
			if haskey(_rsc_line(t), :color)]
		@test !isempty(stem_colors) && all(==(expected), stem_colors)
		@test _rsc_line(plot_area(1:3, [1.0, 2, 3]; color = value).data[1])[:color] == expected
		@test _rsc_line(plot_scatterpolar([0.0, 90], [1.0, 2]; color = value).data[1])[:color] == expected
	end
	# Per-series vectors mix the forms.
	two = plot_scatter(1:3, [[1.0, 2, 3], [3.0, 2, 1]]; color = ["0.2", Colors.RGB(0, 0, 1)])
	@test [_rsc_line(t)[:color] for t in two.data] == ["#333333", "#0000FF"]
	# "none" stays a hollow marker face.
	hollow = plot_scatter(1:3, [1.0, 2, 3]; mode = "markers", marker_symbol = "o", marker_color = "none")
	@test !haskey(_rsc_marker(hollow.data[1]), :color)
	# SyncPlot and SubplotFigure mutators convert too.
	sp = _rsc_syncplot(plot_scatter(1:3, [1.0, 2, 3]))
	plot_scatter!(sp, 1:3, [3.0, 2, 1]; color = "0.35")
	@test _rsc_line(sp.plot.data[2])[:color] == "#595959"
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, 1:3, [1.0, 2, 3]; row = 1, col = 2, color = "0.35")
	@test _rsc_line(sf.plot.data[end])[:color] == "#595959"
	# Unknown colours throw an ArgumentError naming the function and keyword,
	# before anything is written.
	for (who, call) in (
		("plot_scatter", () -> plot_scatter(1:3, [1.0, 2, 3]; color = "notacolour")),
		("plot_scatter", () -> plot_scatter(1:3, [1.0, 2, 3]; marker_line_color = "zzz")),
		("plot_stem", () -> plot_stem(1:3, [1.0, 2, 3]; color = "nope")),
		("plot_area", () -> plot_area(1:3, [1.0, 2, 3]; color = "nope")),
		("plot_scatterpolar", () -> plot_scatterpolar([0.0, 90], [1.0, 2]; color = "nope")),
	)
		err = _rsc_error(call)
		@test err isa ArgumentError && startswith(err.msg, who * ": `")
		@test err isa ArgumentError && occursin("invalid colour", err.msg)
	end
	target = plot_scatter(1:3, [1.0, 2, 3])
	snapshot = _rsc_snapshot(target)
	err = _rsc_error(() -> plot_scatter!(target, 1:3, [1.0, 2, 3]; fillcolor = "nope"))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatter!: `fillcolor`:")
	@test _rsc_unchanged(target, snapshot)
	@test occursin("grey", string(@doc plot_scatter)) && occursin("Colorant", string(@doc plot_scatter))
end

@testset "scatter family: `simplify` keyword; exports draw every vertex (Z35)" begin
	# The figure itself only carries an explicit choice.
	@test !haskey(plot_scatter(1:3, [1.0, 2, 3]).data[1].fields, :line)
	@test _rsc_line(plot_scatter(1:3, [1.0, 2, 3]; simplify = true).data[1])[:simplify] === true
	@test _rsc_line(plot_scatter(1:3, [1.0, 2, 3]; simplify = false).data[1])[:simplify] === false
	two = plot_scatter(1:3, [[1.0, 2, 3], [3.0, 2, 1]]; simplify = [true, nothing])
	@test _rsc_line(two.data[1])[:simplify] === true
	@test !haskey(_rsc_line(two.data[2]), :simplify)
	g = plot_scatter(1:3, [1.0, 2, 3])
	plot_scatter!(g, 1:3, [3.0, 2, 1]; simplify = true)
	@test _rsc_line(g.data[2])[:simplify] === true
	@test _rsc_line(plot_complex([1 + 1im, 2 + 0im]; mode = "lines", simplify = true).data[1])[:simplify] === true
	err = _rsc_error(() -> plot_scatter(1:3, [1.0, 2, 3]; simplify = [1]))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatter: `simplify`")
	# savefig: every line-drawing scatter trace without a choice gets
	# `simplify = false` (plotly.js' default `true` facets dense curves at
	# 600 dpi: probe p03, 153 of 4000 vertices drawn); markers-only traces,
	# explicit choices, other trace types and the caller's figure are left alone.
	e = plot_scatter(1:3, [[1.0, 2, 3], [3.0, 2, 1], [2.0, 2, 2]];
		mode = ["lines", "markers", "lines+markers"], simplify = [nothing, nothing, true])
	plot_ecdf!(e, [1.0, 2, 3])
	push!(e.data, bar(x = ["a"], y = [1]))
	data, _ = _rsc_export(e)
	@test data[1]["line"]["simplify"] === false
	@test !haskey(get(data[2], "line", Dict{String, Any}()), "simplify")
	@test data[3]["line"]["simplify"] === true
	@test data[4]["line"]["simplify"] === false
	@test !haskey(get(data[5], "line", Dict{String, Any}()), "simplify")
	@test !haskey(e.data[1].fields, :line)
	@test occursin("simplify", string(@doc plot_scatter))
end

@testset "scatter family: the plot! alias names itself in its errors (Z23)" begin
	p = plot_scatter(1:3, [1.0, 2, 3])
	snapshot = _rsc_snapshot(p)
	for call in (
		() -> plot!(p, 1:3, [1.0]),
		() -> plot!(p, [1.0, 2]; show = true),
		() -> plot!(p, 1:3, [1.0, 2, 3]; color = "nope"),
	)
		err = _rsc_error(call)
		@test err isa ArgumentError && startswith(err.msg, "plot!:")
	end
	@test _rsc_unchanged(p, snapshot)
	sp = _rsc_syncplot(plot_scatter(1:3, [1.0, 2, 3]))
	err = _rsc_error(() -> plot!(sp, 1:3, [1.0]))
	@test err isa ArgumentError && startswith(err.msg, "plot!:")
	sf = subplots(1, 2; sync = false)
	for call in (() -> plot!(sf, 1:3, [1.0, 2, 3]; row = 9, col = 1), () -> plot!(sf, 1:3, [1.0]))
		err = _rsc_error(call)
		@test err isa ArgumentError && startswith(err.msg, "plot!:")
	end
	# plot_scatter! keeps its own name.
	@test startswith(_rsc_error(() -> plot_scatter!(p, 1:3, [1.0])).msg, "plot_scatter!:")
	@test startswith(_rsc_error(() -> plot_scatter!(sf, 1:3, [1.0])).msg, "plot_scatter!:")
	@test plot!(sf, 1:3, [1.0, 2, 3]; row = 1, col = 2) === sf
	@test length(sf.plot.data) == 1
	@test occursin("Its errors name", string(@doc plot!))
end

@testset "oned constructors: `title` gets the title! placement (Z28)" begin
	_title(fig) = _rsc_fields(PlotlySupply._plot_obj(fig).layout.fields[:title])
	reference = plot_scatter(1:3, [1.0, 2, 3])
	title!(reference, "T")
	expected = _title(reference)
	@test expected[:yref] == "container" && expected[:y] == 1 && expected[:yanchor] == "top"
	for fig in (
		plot_scatter(1:3, [1.0, 2, 3]; title = "T"),
		plot_stem(1:3, [1.0, 2, 3]; title = "T"),
		plot_area(1:3, [1.0, 2, 3]; title = "T"),
		plot_scatterpolar([0.0, 90], [1.0, 2]; title = "T"),
		plot_bar(["a", "b"], [1.0, 2]; title = "T"),
		plot_histogram([1.0, 2, 2, 3]; title = "T"),
		plot_box([1.0, 2, 3, 4]; title = "T"),
		plot_band(1:3, [0.0, 0, 0], [1.0, 2, 3]; title = "T"),
		plot_ecdf([1.0, 2, 3]; title = "T"),
		plot_complex([1 + 1im, 2 - 1im]; title = "T"),
	)
		@test _title(fig) == expected
	end
	# A placed title keeps its placement; a mutator's `title` only changes the text.
	left = plot_scatter(1:3, [1.0, 2, 3])
	title!(left, "L"; align = :left)
	plot_scatter!(left, 1:3, [3.0, 2, 1]; title = "L2")
	@test _title(left)[:text] == "L2" && _title(left)[:xanchor] == "left" && _title(left)[:x] == 0
	moved = plot_scatter(1:3, [1.0, 2, 3]; title = "M")
	relayout!(moved; title_y = 0.9)
	plot_bar!(moved, [1, 2], [1.0, 2]; title = "M2")
	@test _title(moved)[:y] == 0.9 && _title(moved)[:text] == "M2"
	# A top secondary axis keeps the placement. The two do not overlap: the
	# room engine holds the top margin for the title band above the axis
	# (`_axes_title_clearance` leaves a container-placed title to it), so the
	# margin grows by the depth of the top axis (lead render check
	# k4_title_top_axis.png: title clear of the top tick labels).
	plain = plot_scatter(1:3, [1.0, 2, 3]; title = "T")
	top = plot_scatter(1:3, [1.0, 2, 3]; title = "T")
	secondary_xaxis!(top, v -> 2v, v -> v / 2)
	@test _title(top)[:yref] == "container" && _title(top)[:yanchor] == "top" && _title(top)[:y] == 1
	@test _rsc_get(_title(top)[:pad], :t) == 10
	top_margin(fig) = _rsc_get(PlotlySupply._plot_obj(fig).layout.fields[:margin], :t)
	@test top_margin(top) >= top_margin(plain) + 10
end

@testset "secondary_xaxis!: side = :bottom on a bottom axis is a second label row (W5)" begin
	f = plot_scatter([1.0, 2, 3, 5, 6], [1.0, 2, 3, 2, 1]; mode = "markers")
	xticks!(f, [1, 2, 3, 5, 6], ["a", "b", "c", "d", "e"])
	xrange!(f, (0, 7))
	secondary_xaxis!(f, identity, identity; side = :bottom, ticks = [2, 5.5],
		ticklabels = ["g1", "g2"], title = "groups")
	row = _rsc_axis(f, :xaxis2)
	@test row[:side] == "bottom" && row[:overlaying] == "x" && row[:matches] == "x"
	@test row[:tickvals] == [2.0, 5.5]
	@test row[:ticktext] == ["<br>g1", "<br>g2"]
	@test row[:showline] == false && row[:tickcolor] == "rgba(0,0,0,0)" && row[:tickangle] == 0
	@test get(row, :ticks, nothing) == get(_rsc_axis(f, :xaxis), :ticks, nothing)
	@test _rsc_text(row[:title]) == "groups"
	@test _rsc_axis(f, :xaxis)[:range] == [0, 7]
	@test "plotlysupply:secondary_xaxis:x:row" in [get(t.fields, :name, "") for t in f.data]
	# Two-line primary labels push the row down two lines.
	g = plot_scatter([1.0, 2], [1.0, 2])
	xticks!(g, [1, 2], ["a<br>b", "c"])
	secondary_xaxis!(g, identity, identity; side = :bottom, ticks = [1.5], ticklabels = ["G"])
	@test _rsc_axis(g, :xaxis2)[:ticktext] == ["<br><br>G"]
	# Without a title the text stays unset: plotly.js reserves a title line
	# below an axis titled "" (render probe p14: a 24 px blank band).
	title_text(fig) = _rsc_get(_rsc_get(_rsc_axis(fig, :xaxis2), :title, Dict{Symbol, Any}()), :text)
	@test title_text(g) === nothing
	# A top secondary axis and the row coexist; a second row call replaces the
	# row, including its title.
	secondary_xaxis!(f, v -> 10v, v -> v / 10)
	secondary_xaxis!(f, identity, identity; side = :bottom, ticks = [2], ticklabels = ["only"])
	@test count(k -> occursin(r"^xaxis\d+$", String(k)), keys(f.layout.fields)) == 2
	@test _rsc_axis(f, :xaxis2)[:ticktext] == ["<br>only"]
	@test title_text(f) === nothing
	@test _rsc_axis(f, :xaxis3)[:side] == "top"
	# The same side on a top primary is still an error, raised before any change.
	t = plot_scatter([1.0, 2], [1.0, 2])
	relayout!(t; xaxis_side = "top")
	snapshot = _rsc_snapshot(t)
	err = _rsc_error(() -> secondary_xaxis!(t, identity, identity; side = :top))
	@test err isa ArgumentError && occursin("already on the top", err.msg)
	@test _rsc_unchanged(t, snapshot)
	@test occursin("second label row", string(@doc secondary_xaxis!))
end

# A vector that counts element reads (getindex), to bound the passes a call
# makes over the caller's data.
struct _RscCountingVector <: AbstractVector{Float64}
	data::Vector{Float64}
	reads::Base.RefValue{Int}
end
Base.size(v::_RscCountingVector) = size(v.data)
Base.IndexStyle(::Type{_RscCountingVector}) = IndexLinear()
Base.getindex(v::_RscCountingVector, i::Int) = (v.reads[] += 1; v.data[i])

@testset "scatter family: a million points are neither copied nor rescanned (performance)" begin
	n = 1_000_000
	x = collect(range(0, 100; length = n))
	y = sin.(x)
	# The traces hold the caller's vectors, in constructors and appends.
	f = plot_scatter(x, y; legend = "data")
	@test f.data[1].fields[:x] === x && f.data[1].fields[:y] === y
	g = plot_scatter(1:10, collect(1.0:10); legend = "a")
	plot_scatter!(g, x, y; legend = "b")
	@test g.data[2].fields[:y] === y
	# The best-legend estimate reads a Float64 trace in place, and its scoring
	# loop is type-stable: before wave 5 it boxed every point (about 905 MiB
	# and 1 s per call for this trace, twice per named append).
	@test PlotlySupply._scat_legend_coords(y, false) === y
	p = PlotlySupply._plot_obj(f)
	PlotlySupply._scat_best_legend_position(p)
	@test (@allocated PlotlySupply._scat_best_legend_position(p)) < 16 * 2^20
	# A non-Float64 vector is read once to settle the figure (sm-07: the
	# constructor finalizes, which takes the data extent: measured 1e6 Float64
	# points 0.33 ms -> 1.15 ms per call) and once more for the legend
	# placement (the conversion); never more.
	counted = _RscCountingVector(copy(y), Ref(0))
	plot_scatter(x, counted)
	@test counted.reads[] <= n
	counted.reads[] = 0
	plot_scatter(x, counted; legend = "data")
	@test counted.reads[] <= 2n
end

@testset "scatter family: polar radial one-sided limits and bound types (Z51, D11)" begin
	rget(fig, key) = _rsc_get(_rsc_fields(_rsc_fields(fig.layout.fields[:polar])[:radialaxis]), key)
	opts(fig) = (o = rget(fig, :autorangeoptions); o === nothing ? Dict{Symbol, Any}() : _rsc_fields(o))
	f = plot_scatterpolar([0, 90, 180], [1.0, 2, 3]; rrange = (0, nothing))
	@test rget(f, :autorange) === true
	@test opts(f)[:minallowed] == 0
	@test !haskey(opts(f), :maxallowed)
	f = plot_scatterpolar([0, 90, 180], [1.0, 2, 3]; rrange = (nothing, 5))
	@test opts(f)[:maxallowed] == 5
	# The export copy keeps the encoding (Z38).
	_, layout = _rsc_export(f)
	@test layout["polar"]["radialaxis"]["autorangeoptions"]["maxallowed"] == 5
	@test layout["polar"]["radialaxis"]["autorange"] === true
	# A mutator replaces it, and a full range replaces a limit.
	plot_scatterpolar!(f, [0, 90], [1.0, 2]; rrange = (1, 4))
	@test rget(f, :range) == [1, 4]
	@test isempty(opts(f))
	plot_scatterpolar!(f, [0, 90], [1.0, 2]; rrange = (nothing, 3))
	@test opts(f)[:maxallowed] == 3
	# A fixed lower end with the upper one open.
	g = plot_scatterpolar([0, 90], [1.0, 100]; rrange = (1, nothing))
	@test rget(g, :autorange) === true
	@test opts(g)[:minallowed] == 1
	# Errors: both ends open, a non-number, trange stays two-sided.
	err = _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; rrange = (nothing, nothing), trange = (0, nothing)))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatterpolar:")
	err = _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; rrange = ("a", nothing)))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatterpolar:")
	err = _rsc_error(() -> plot_scatterpolar([0, 90], [1, 2]; rrange = (true, nothing)))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatterpolar:")
	# Linear and autotyped axes reject non-numeric, non-date bounds.
	for bounds in (("a", "b"), ("a", nothing), (nothing, "b"))
		err = _rsc_error(() -> plot_scatter(1:3, [1.0, 2, 3]; yrange = bounds))
		@test err isa ArgumentError && startswith(err.msg, "plot_scatter:")
		err = _rsc_error(() -> plot_bar(["a"], [1.0]; yrange = bounds))
		@test err isa ArgumentError && startswith(err.msg, "plot_bar:")
	end
end

@testset "scatter family: one-sided limit on an equal-aspect axis pins the open end (Z51, D11)" begin
	f = plot_scatter(1:5, [1.0, 2, 3, 4, 5]; equalar = true, yrange = (0, nothing))
	range = _rsc_axis(f, :yaxis)[:range]
	@test range[1] == 0 && range[2] >= 5
	z = plot_complex([1 + 1im, 2 + 0.5im]; yrange = (0, nothing))
	@test _rsc_axis(z, :yaxis)[:range][1] == 0
end

@testset "v7 axes-style: 1-D audit fixes (histogram bins, violin log, stems, bar labels, date widths, area gaps)" begin
	PS = PlotlySupply
	g(x, ks...) = (for k in ks; x = PS._cmn_mapping_get(x, k); end; x)
	L(f) = PS._cmn_layout(f).fields
	argmsg(f) = try
		f(); "no error"
	catch err
		err isa ArgumentError ? err.msg : string(typeof(err))
	end
	data = [1.0, 2, 2, 3, 3, 3, 4, 4, 4, 4]

	@testset "oned-hist-stop-dropped / oned-hist-logbins" begin
		# The last explicit bin is closed: the four samples at `stop` count.
		h = plot_histogram(data; bins = (1, 4, 1))
		@test h.data[1].fields[:x] == [1.0, 2.0, 3.0] && h.data[1].fields[:y] == [1.0, 2.0, 7.0]
		hp = plot_histogram(data; bins = (1, 4, 1), histnorm = "probability")
		@test hp.data[1].fields[:y] ≈ [0.1, 0.2, 0.7]
		# Log auto bins: plotly's 1-D rule over log10 (one decade wide here),
		# no empty end bins.
		hl = plot_histogram([1.0, 10, 10, 100, 100, 100, 1000]; xscale = "log")
		@test hl.data[1].fields[:y] == [1.0, 2.0, 3.0, 1.0]
		edges = [c[1] for c in hl.data[1].fields[:customdata]]
		@test log10.(edges) ≈ [-0.5, 0.5, 1.5, 2.5]
	end

	@testset "oned-violin-log: the kernel stays inside the data" begin
		v = plot_violin([1.0, 10, 100, 1000, 50]; yscale = "log")
		@test v.data[1].fields[:spanmode] == "hard"
		@test !haskey(plot_violin([1.0, 10, 100]).data[1].fields, :spanmode)
	end

	@testset "oned-stem-no-frame: stems keep the axis frame (rendered)" begin
		s = plot_stem(1:3, [1.0, 2, 3])
		@test all(t -> !haskey(t.fields, :zorder), s.data)
		svg = try
			String(savefig(s; format = "svg", width = 500, height = 400))
		catch err
			m = sprint(showerror, err)
			@test occursin("Electron", m) || occursin("Plotly.js", m)
			nothing
		end
		if svg !== nothing
			lines = [m.captures[1] for m in eachmatch(r"class=\"[xy]lines-above crisp\" d=\"([^\"]*)\"", svg)]
			@test length(lines) == 2 && all(d -> d != "M0,0" && length(d) > 10, lines)
		end
	end

	@testset "oned-bar-text-clipped / vm-10: room for outside bar labels" begin
		for st in (:default, :ieee)
			b = with_style(st) do
				plot_bar(["a", "b", "c"], [3, 2, 5]; text = ["3", "2", "5"], textposition = "outside")
			end
			inc = g(L(b)[:yaxis], :autorangeoptions, :include)
			@test length(inc) == 1 && 5.2 < inc[1] < 5.8
			@test !PS._finalize_figure!(b)
		end
		bl = plot_bar(["a", "b"], [10, 1000]; text = ["10", "1000"], textposition = "outside", yscale = "log")
		@test 1000 < g(L(bl)[:yaxis], :autorangeoptions, :include)[1] < 3000
		# An explicit range is the user's: no include.
		br = plot_bar(["a", "b"], [1, 2]; text = ["1", "2"], textposition = "outside", yrange = [0, 10])
		@test g(L(br)[:yaxis], :autorangeoptions) === nothing
		# Rendered: the tallest label lies inside the plot area.
		b = with_style(() -> plot_bar(["a", "b", "c"], [3, 2, 5]; text = ["3", "2", "5"], textposition = "outside"), :ieee)
		svg = try
			String(savefig(b; format = "svg"))
		catch err
			m = sprint(showerror, err)
			@test occursin("Electron", m) || occursin("Plotly.js", m)
			nothing
		end
		if svg !== nothing
			# plotly drops (`cliponaxis`) or clips a label outside the plot area;
			# all three value labels are drawn.
			@test count(m -> m.captures[1] in ("3", "2", "5"), eachmatch(r"<text class=\"bartext[^\"]*\"[^>]*>([^<]*)</text>", svg)) == 3
		end
	end

	@testset "oned-bar-date-width: barwidth in days on a date axis" begin
		days = PS.Dates.Date(2024, 1, 1) .+ PS.Dates.Day.(0:9)
		@test plot_bar(days, 1:10; barwidth = 0.8).data[1].fields[:width] == 0.8 * 86_400_000
		@test plot_bar(PS.Dates.DateTime.(days), 1:10; barwidth = 0.5).data[1].fields[:width] == 0.5 * 86_400_000
		@test plot_bar(1:10, days; barwidth = 0.8, orientation = "h").data[1].fields[:width] == 0.8 * 86_400_000
		@test plot_bar(1:10, 1:10; barwidth = 0.8).data[1].fields[:width] == 0.8
	end

	@testset "oned-area-gap-filled: a gap is an error, not a filled plateau" begin
		@test argmsg(() -> plot_area(1:5, [1.0, 2, NaN, 2, 1])) == "plot_area: `y` has a gap (`NaN` at position 3); " *
			"a filled area cannot show a gap (plotly.js would fill across it, or take it as 0 when stacked): " *
			"draw each gap-free part with its own call."
		@test occursin("of series 2", argmsg(() -> plot_area(1:3, [[1.0, 2, 3], [1.0, missing, 3]]; stack = true)))
		f = plot_area(1:3, [1.0, 2, 3])
		before = length(f.data)
		@test occursin("has a gap", argmsg(() -> plot_area!(f, 1:3, [1.0, NaN, 3])))
		@test length(f.data) == before
	end
end

@testset "v8 axes-style: numerics-01 error bar values are checked" begin
	for kw in ((error_y = [0.1, -0.2, 0.1],), (error_y = ([0.1, 0.1, 0.1], [0.3, -0.3, 0.3]),), (error_y = ["a", "b", "c"],))
		err = try
			plot_scatter(1:3, [1.0, 2, 3]; kw...); nothing
		catch e
			e
		end
		@test err isa ArgumentError && startswith(err.msg, "plot_scatter: `error_y` entries must be non-negative numbers")
	end
	@test plot_scatter(1:3, [1.0, 2, 3]; error_y = [0.1, missing, 0.2]) isa PlotlySupply.Plot
end
