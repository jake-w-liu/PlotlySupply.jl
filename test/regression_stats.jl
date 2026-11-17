using Test, PlotlySupply

# Regression and feature tests for the stats family: plot_bar, plot_histogram,
# plot_box, plot_violin, plot_histogram2d (constructors, Plot/SyncPlot
# mutators, SubplotFigure methods).

_st_fields(value) = value isa AbstractDict ? value : value.fields
_st_trace(fig, index = 1) = _st_fields(fig.data[index])
_st_layout(fig) = _st_fields(fig.layout)
_st_axis(fig, key) = _st_fields(_st_layout(fig)[key])
_st_get(value, keys...) = foldl((acc, key) -> _st_fields(acc)[key], keys; init = value)
_st_title(value) = value isa AbstractString ? value : _st_fields(value)[:text]

function _st_snapshot(fig)
	return (
		length(fig.data),
		repr(_st_layout(fig)),
		[repr(_st_fields(trace)) for trace in fig.data],
	)
end

@testset "stats: horizontal bars of the y-only form (#220 #39 #47 #57 #67 #99 #108)" begin
	values = [3.0, 5.0, 2.0]
	fig = plot_bar(values; orientation = "h")
	trace = _st_trace(fig)
	@test trace[:x] == values              # values on the value axis
	@test collect(trace[:y]) == [0, 1, 2]  # generated positions on the category axis
	@test trace[:orientation] == "h"

	vertical = _st_trace(plot_bar(values))
	@test collect(vertical[:x]) == [0, 1, 2]
	@test vertical[:y] == values
	@test !haskey(vertical, :orientation)

	nested = plot_bar([[1.0, 2.0], [3.0, 4.0, 5.0]]; orientation = "h")
	@test _st_trace(nested, 1)[:x] == [1.0, 2.0]
	@test collect(_st_trace(nested, 1)[:y]) == [0, 1]
	@test _st_trace(nested, 2)[:x] == [3.0, 4.0, 5.0]
	@test collect(_st_trace(nested, 2)[:y]) == [0, 1, 2]

	target = plot_scatter(1:3, 1:3)
	@test plot_bar!(target, values; orientation = "h") === nothing
	@test _st_trace(target, 2)[:x] == values
	@test collect(_st_trace(target, 2)[:y]) == [0, 1, 2]

	# The two-argument form stays plotly pass-through: x holds the values.
	passthrough = _st_trace(plot_bar([3, 2, 4], ["a", "b", "c"]; orientation = "h"))
	@test passthrough[:x] == [3, 2, 4]
	@test passthrough[:y] == ["a", "b", "c"]
	# ... also with several value series sharing the categories.
	nested_h = plot_bar([[1, 2], [3, 4]], ["a", "b"]; orientation = "h")
	@test length(nested_h.data) == 2
	@test _st_trace(nested_h, 2)[:x] == [3, 4]
	@test _st_trace(nested_h, 2)[:y] == ["a", "b"]

	sf = subplots(1, 2; sync = false)
	@test plot_bar!(sf, values; orientation = "h", row = 1, col = 2) === sf
	routed = _st_fields(sf.plot.data[end])
	@test routed[:x] == values
	@test collect(routed[:y]) == [0, 1, 2]
	@test routed[:xaxis] == "x2"

	@test_throws ArgumentError plot_bar(values; orientation = "horizontal")
end

@testset "stats: nested histograms overlay translucently on shared bins (#222 #61 #74)" begin
	a, b = randn(200), 0.1 .* randn(200)
	fig = plot_histogram([a, b]; nbinsx = 20)
	t1, t2 = _st_trace(fig, 1), _st_trace(fig, 2)
	@test _st_layout(fig)[:barmode] == "overlay"
	@test t1[:opacity] == 0.6 && t2[:opacity] == 0.6
	@test t1[:bingroup] == t2[:bingroup]
	# One mechanism (X3/K8): the root overlay alone overlays a fresh figure's
	# series; a shared offsetgroup is used only where the root mode is not
	# overlay (bars already present, a subplot cell).
	@test !haskey(t1, :offsetgroup) && !haskey(t2, :offsetgroup)
	@test t1[:nbinsx] == 20

	# Same call, same JSON; a different call gets its own group.
	again = plot_histogram([a, b]; nbinsx = 20)
	@test _st_trace(again, 1)[:bingroup] == t1[:bingroup]
	plot_histogram!(fig, [randn(50), randn(50)])
	@test _st_trace(fig, 3)[:bingroup] == _st_trace(fig, 4)[:bingroup]
	@test _st_trace(fig, 3)[:bingroup] != t1[:bingroup]

	single = _st_trace(plot_histogram(randn(50)))
	@test !haskey(single, :opacity)
	@test !haskey(single, :bingroup)
	@test !haskey(single, :offsetgroup)

	explicit = plot_histogram([randn(5), randn(5)]; opacity = 0.9)
	@test all(_st_fields(t)[:opacity] == 0.9 for t in explicit.data)

	# An existing bar mode other than overlay is kept: no translucency, no
	# shared slot, but still common bins.
	for existing in ("group", "stack")
		q = plot_scatter(1:3, 1:3)
		q.layout.fields[:barmode] = existing
		plot_histogram!(q, [randn(5), randn(5)])
		@test _st_layout(q)[:barmode] == existing
		@test all(!haskey(_st_fields(t), :opacity) for t in q.data[2:end])
		@test all(!haskey(_st_fields(t), :offsetgroup) for t in q.data[2:end])
		@test _st_trace(q, 2)[:bingroup] == _st_trace(q, 3)[:bingroup]
	end

	stacked = plot_histogram([randn(20), randn(20)]; barmode = "stack")
	@test _st_layout(stacked)[:barmode] == "stack"
	@test !haskey(_st_trace(stacked, 1), :opacity)
	@test !haskey(_st_trace(stacked, 1), :offsetgroup)

	overlay_mutator = plot_scatter(1:3, 1:3)
	plot_histogram!(overlay_mutator, [randn(20), randn(20)])
	@test _st_layout(overlay_mutator)[:barmode] == "overlay"
	@test all(_st_fields(t)[:opacity] == 0.6 for t in overlay_mutator.data[2:end])
end

@testset "stats: subplot histograms overlay inside their own cell (#221, trace part)" begin
	sf = subplots(1, 2; sync = false)
	plot_bar!(sf, ["Q1", "Q2"], [[1.0, 2.0], [3.0, 4.0]]; row = 1, col = 1)
	plot_histogram!(sf, [randn(50), randn(50)]; row = 1, col = 2)
	h1, h2 = _st_fields(sf.plot.data[3]), _st_fields(sf.plot.data[4])
	@test h1[:xaxis] == h2[:xaxis] == "x2"
	# A shared offsetgroup overlays the two series in their cell even when
	# the figure-wide barmode is plotly's default "group".
	@test h1[:offsetgroup] == h2[:offsetgroup]
	@test h1[:bingroup] == h2[:bingroup]
	@test h1[:opacity] == 0.6
	@test !haskey(_st_fields(sf.plot.data[1]), :offsetgroup)

	# The cell sees the figure-wide bar mode: under a root "stack" the series
	# stack on shared bins instead of being made translucent and slotted.
	stacked = subplots(1, 2; sync = false)
	stacked.plot.layout.fields[:barmode] = "stack"
	plot_histogram!(stacked, [randn(50), randn(50)]; row = 1, col = 2)
	s1, s2 = _st_fields(stacked.plot.data[1]), _st_fields(stacked.plot.data[2])
	@test _st_layout(stacked.plot)[:barmode] == "stack"
	@test !haskey(s1, :opacity) && !haskey(s1, :offsetgroup)
	@test s1[:bingroup] == s2[:bingroup]
	# The scoped root mode does not leak into later plain-Plot calls.
	@test _st_trace(plot_histogram([randn(5), randn(5)]), 1)[:opacity] == 0.6
end

@testset "stats: y-only box/violin group mode only when positions collide (#223 #60)" begin
	for (constructor, mutator, key) in (
		(plot_box, plot_box!, :boxmode),
		(plot_violin, plot_violin!, :violinmode),
	)
		named = constructor([randn(20), randn(20)]; legend = ["A", "B"])
		@test !haskey(_st_layout(named), key)
		@test [_st_fields(t)[:name] for t in named.data] == ["A", "B"]

		@test _st_layout(constructor([randn(20), randn(20)]))[key] == "group"
		@test _st_layout(constructor([randn(20), randn(20)]; legend = ["A", "A"]))[key] == "group"
		@test _st_layout(constructor([randn(20), randn(20)]; legend = "A"))[key] == "group"
		@test _st_layout(constructor([randn(20), randn(20)]; legend = ["A", " "]))[key] == "group"

		p = plot_scatter(1:3, 1:3)
		mutator(p, [randn(20), randn(20)]; legend = ["A", "B"])
		@test !haskey(_st_layout(p), key)
		# Repeating the name of a position-less trace already in the figure
		# would collide.
		existing = constructor(randn(10); legend = "A")
		mutator(existing, [randn(10), randn(10)]; legend = ["A", "B"])
		@test _st_layout(existing)[key] == "group"

		# Explicit positions keep the group default.
		grouped = constructor(["x", "x"], [[1.0, 2.0], [3.0, 4.0]]; legend = ["A", "B"])
		@test _st_layout(grouped)[key] == "group"

		# SubplotFigure: the delegate builds the traces on an empty staged
		# Plot, so the collision with a box already in the TARGET cell must be
		# seen through the cell context; boxes in other cells do not collide.
		sf = subplots(1, 2; sync = false)
		mutator(sf, randn(10); legend = "A", row = 1, col = 1)
		mutator(sf, [randn(10), randn(10)]; legend = ["A", "B"], row = 1, col = 1)
		@test _st_layout(sf.plot)[key] == "group"
		other = subplots(1, 2; sync = false)
		mutator(other, randn(10); legend = "A", row = 1, col = 1)
		mutator(other, [randn(10), randn(10)]; legend = ["A", "B"], row = 1, col = 2)
		@test !haskey(_st_layout(other.plot), key)
	end
end

@testset "stats: a per-cell barmode that changes other cells warns (C29)" begin
	sf = subplots(1, 2; sync = false)
	plot_bar!(sf, ["a", "b"], [[1, 2], [3, 4]]; row = 1, col = 1)
	@test_logs (:warn, r"figure-wide bar mode \"group\"") plot_bar!(
		sf, ["a", "b"], [[1, 2], [3, 4]]; barmode = "stack", row = 1, col = 2,
	)
	@test _st_layout(sf.plot)[:barmode] == "stack"
	# Same mode again: nothing changes, no warning.
	@test_logs plot_bar!(sf, ["c"], [[1], [2]]; barmode = "stack", row = 1, col = 2)
	@test_logs (:warn, r"figure-wide bar mode \"stack\"") plot_histogram!(
		sf, [randn(10), randn(10)]; barmode = "overlay", row = 1, col = 2,
	)

	# No bars elsewhere: an explicit mode is not a conflict.
	alone = subplots(1, 2; sync = false)
	plot_scatter!(alone, 1:3, 1:3; row = 1, col = 1)
	@test_logs plot_bar!(alone, ["a"], [[1], [2]]; barmode = "stack", row = 1, col = 2)
	# A rejected call does not warn and changes nothing.
	failing = subplots(1, 2; sync = false)
	plot_bar!(failing, ["a"], [1]; row = 1, col = 1)
	@test_logs (@test_throws ArgumentError plot_bar!(
		failing, ["a"], [1]; barmode = "stack", text = ["x", "y"], row = 1, col = 2,
	))
	@test !haskey(_st_layout(failing.plot), :barmode)
	@test length(failing.plot.data) == 1
end

@testset "stats: mutators honour a showlegend vector (#226 #102 #110)" begin
	cases = (
		(plot_bar, plot_bar!, ([1.0, 2, 3],)),
		(plot_bar, plot_bar!, (1:3, [1.0, 2, 3])),
		(plot_histogram, plot_histogram!, (randn(50),)),
		(plot_box, plot_box!, (randn(20),)),
		(plot_box, plot_box!, (fill("A", 20), randn(20))),
		(plot_violin, plot_violin!, (randn(20),)),
		(plot_violin, plot_violin!, (fill("A", 20), randn(20))),
	)
	for (constructor, mutator, args) in cases
		target = Plot(scatter(x = [0], y = [0]), Layout())
		mutator(target, args...; showlegend = [false])
		@test _st_fields(target.data[end])[:showlegend] === false
		@test _st_trace(constructor(args...; showlegend = [false]))[:showlegend] === false
	end
	nested = Plot(scatter(x = [0], y = [0]), Layout())
	plot_bar!(nested, [[1, 2], [3, 4]]; showlegend = BitVector([false, true]))
	@test [_st_fields(t)[:showlegend] for t in nested.data[2:end]] == [false, true]
end

@testset "stats: mutator grid keyword (#113)" begin
	for mutate! in (
		fig -> plot_bar!(fig, [1, 2, 3]; grid = true),
		fig -> plot_histogram!(fig, randn(10); grid = true),
		fig -> plot_box!(fig, randn(10); grid = true),
		fig -> plot_violin!(fig, randn(10); grid = true),
		fig -> plot_histogram2d!(fig, randn(10), randn(10); grid = true),
	)
		fig = plot_scatter([1, 2, 3]; grid = false)
		@test _st_axis(fig, :xaxis)[:showgrid] === false
		mutate!(fig)
		@test _st_axis(fig, :xaxis)[:showgrid] === true
		@test _st_axis(fig, :yaxis)[:showgrid] === true
	end
	fig = plot_scatter([1, 2, 3]; grid = false)
	plot_bar!(fig, [1, 2, 3])   # default `nothing` leaves the grid alone
	@test _st_axis(fig, :xaxis)[:showgrid] === false
	plot_bar!(fig, [1, 2, 3]; grid = :y)
	@test _st_axis(fig, :xaxis)[:showgrid] === false
	@test _st_axis(fig, :yaxis)[:showgrid] === true
	@test _st_axis(plot_bar([1, 2]; grid = :x), :yaxis)[:showgrid] === false
	@test_throws ArgumentError plot_box(randn(5); grid = :z)
end

@testset "stats: histogram2d axis options, docs and colour keywords (#225)" begin
	x, y = 1 .+ 9 .* rand(100), rand(100)
	fig = plot_histogram2d(
		x,
		y;
		xscale = "log",
		xrange = (1, 100),
		yrange = [0, 1.5],
		xlabel = "x",
		yticks = [0, 0.5, 1],
		ytickformat = ".1f",
	)
	# plotly.js cannot bin a histogram2d on a log axis (it draws nothing), so
	# the counts are binned in Julia: equal-width bins in decades along x.
	trace = _st_trace(fig)
	@test trace[:type] == "heatmap"
	edges = log10.(trace[:x])
	@test all(isapprox.(diff(edges), edges[2] - edges[1]; atol = 1e-9))
	@test first(trace[:x]) <= minimum(x) && last(trace[:x]) >= maximum(x)
	@test sum(sum(row) for row in trace[:customdata]) == 100
	@test _st_axis(fig, :xaxis)[:type] == "log"
	@test _st_axis(fig, :xaxis)[:range] ≈ [0.0, 2.0]   # data units -> log10
	@test _st_axis(fig, :yaxis)[:range] == [0, 1.5]
	@test _st_axis(fig, :yaxis)[:tickvals] == [0.0, 0.5, 1.0]
	@test _st_axis(fig, :yaxis)[:tickformat] == ".1f"
	@test _st_title(_st_axis(fig, :xaxis)[:title]) == "x"
	@test_throws ArgumentError plot_histogram2d(x, y; xscale = "log", xrange = (0, 10))
	# Linear colour norm: empty bins are 0 (as in plotly's histogram2d), not gaps.
	@test all(value -> value isa Real, reduce(vcat, trace[:z]))
	# Non-positive samples cannot be shown on a log axis and are not counted.
	signed = _st_trace(plot_histogram2d([-1.0, 0.0, 1.0, 10.0], [1.0, 2.0, 3.0, 4.0]; xscale = "log"))
	@test sum(sum(row) for row in signed[:customdata]) == 2
	@test_throws ArgumentError plot_histogram2d([-1.0, 0.0], [1.0, 2.0]; xscale = "log")
	# Densities divide by each bin's own area in data units.
	density = _st_trace(plot_histogram2d(x, y; xscale = "log", histnorm = "probability density"))
	areas = diff(density[:y]) .* permutedims(diff(density[:x]))
	@test sum(reduce(vcat, permutedims.(density[:customdata])) .* areas) ≈ 1

	target = plot_scatter(1:3, 1:3)
	plot_histogram2d!(target, x, y; yscale = "log", yrange = (0.01, 1), nbinsx = 5)
	@test _st_axis(target, :yaxis)[:range] ≈ [-2.0, 0.0]
	@test _st_trace(target, 2)[:type] == "heatmap"
	# nbinsx is passed to the Julia binning as plotly's automatic bins would use it.
	x_start, x_stop, x_width = PlotlySupply._stats_autobins(Float64.(x), 5; total = length(x))
	@test _st_trace(target, 2)[:x] ≈
		[x_start + k * x_width for k in 0:round(Int, (x_stop - x_start) / x_width)]
	# A target whose axis is already logarithmic is binned in Julia too;
	# switching the axis back to linear uses plotly's histogram2d.
	log_target = plot_scatter([1, 10], [1, 2]; xscale = "log")
	plot_histogram2d!(log_target, x, y)
	@test _st_trace(log_target, 2)[:type] == "heatmap"
	plot_histogram2d!(log_target, x, y; xscale = "linear")
	@test _st_trace(log_target, 3)[:type] == "histogram2d"

	# Colour keywords (C20/C21).
	colored = plot_histogram2d(
		x,
		y;
		colorscale = "viridis",
		crange = (0, 10),
		showscale = false,
		colorbar_title = "count",
		colorbar_ticks = [0, 5, 10],
		colorbar_ticklabels = ["none", "some", "many"],
	)
	trace = _st_trace(colored)
	@test trace[:colorscale] == PlotlySupply._resolve_colorscale("viridis"; who = "t").scale
	@test trace[:zmin] == 0 && trace[:zmax] == 10
	@test trace[:showscale] === false
	@test _st_title(_st_get(trace, :colorbar)[:title]) == "count"
	@test _st_get(trace, :colorbar)[:tickvals] == [0.0, 5.0, 10.0]
	@test _st_get(trace, :colorbar)[:ticktext] == ["none", "some", "many"]
	@test _st_trace(plot_histogram2d(x, y; cmid = 4))[:zmid] == 4
	@test !haskey(_st_trace(plot_histogram2d(x, y)), :colorscale)

	shared = plot_histogram2d(x, y; coloraxis = :shared, crange = (1, 9), colorbar_title = "n")
	@test _st_trace(shared)[:coloraxis] == "coloraxis"
	@test !haskey(_st_trace(shared), :zmin)
	axis = _st_layout(shared)[:coloraxis]
	@test _st_fields(axis)[:cmin] == 1 && _st_fields(axis)[:cmax] == 9
	@test _st_title(_st_get(axis, :colorbar)[:title]) == "n"

	@test_throws ArgumentError plot_histogram2d(x, y; colorscale = "no-such-map")
	@test_throws ArgumentError plot_histogram2d(x, y; cmid = 1, colornorm = :log)
	@test_throws ArgumentError plot_histogram2d(x, y; colorbar_ticklabels = ["a"])
	@test_throws ArgumentError plot_histogram2d(x, y; coloraxis = "axis7")
	@test_throws ArgumentError plot_histogram2d(x, y; histnorm = "counts")
	@test_throws ArgumentError plot_histogram2d(x, y[1:10])
	@test_throws ArgumentError plot_histogram2d([x, x], [y, y])

	# The docstrings no longer call nbinsx a target (#227 #66): it is
	# approximate (plotly.js 2.35 draws 31 bins for nbinsx = 30 on randn(500)
	# and 20 on rand(500)), and they list the bar keywords.
	for text in (string(@doc plot_histogram2d), string(@doc plot_histogram))
		@test occursin("approximate number of bins", text)
		@test !occursin("Target number of bins", text)
	end
	for keyword in ("orientation", "barmode", "error_x", "error_y")
		@test occursin("`$(keyword)", string(@doc plot_bar))
	end
end

@testset "stats: histogram2d with a log colour norm bins in Julia" begin
	data = [1.0, 1, 1, 2, 3]
	@test PlotlySupply._stats_autobins(data, 0) == (-0.5, 3.5, 2.0)
	start, stop, width = PlotlySupply._stats_autobins([0.1, 0.2, 0.35, 0.5], 4)
	@test (start, stop, width) == (0.0, 0.6000000000000001, 0.2)

	fig = plot_histogram2d(data, data; colornorm = :log, colorbar_title = "count")
	trace = _st_trace(fig)
	@test trace[:type] == "heatmap"
	@test trace[:transpose] === false
	@test trace[:x] == [-0.5, 1.5, 3.5]
	@test trace[:y] == [-0.5, 1.5, 3.5]
	@test trace[:z] == [Any[log10(3), nothing], Any[nothing, log10(2)]]
	@test trace[:customdata] == [Any[3.0, 0.0], Any[0.0, 2.0]]
	@test occursin("%{customdata}", trace[:hovertemplate])
	colorbar = _st_fields(trace[:colorbar])
	# Decade/sub-decade ticks of the colour helper, kept verbatim (plotly HTML).
	expected_ticks = PlotlySupply._log_colorbar_ticks(log10(2), log10(3))
	@test colorbar[:tickvals] == expected_ticks[1]
	@test colorbar[:ticktext] == expected_ticks[2]
	@test _st_title(colorbar[:title]) == "count"

	normalized = _st_trace(plot_histogram2d(data, data; colornorm = :log, histnorm = "probability"))
	@test normalized[:customdata] == [Any[0.6, 0.0], Any[0.0, 0.4]]
	@test occursin("probability", normalized[:hovertemplate])
	density = _st_trace(plot_histogram2d(data, data; colornorm = :log, histnorm = "density"))
	@test density[:customdata][1][1] ≈ 3 / 4

	# Missing / non-finite samples are skipped; strings are rejected.
	gappy = _st_trace(plot_histogram2d([1.0, missing, NaN, 2, 3, 1, 1], [1.0, 2, 3, 2, 3, 1, 1]; colornorm = :log))
	@test sum(sum(row) for row in gappy[:customdata]) == 5
	@test_throws ArgumentError plot_histogram2d(["a", "b"], [1, 2]; colornorm = :log)
	@test_throws ArgumentError plot_histogram2d([NaN, NaN], [1, 2]; colornorm = :log)
	# Finite x and finite y never in the same pair: nothing to count.
	@test_throws ArgumentError plot_histogram2d([1.0, NaN], [NaN, 2.0]; colornorm = :log)
	@test_throws ArgumentError plot_histogram2d(data, data; colornorm = :sqrt)

	# Empty bins stay blank also under an explicit crange (matplotlib's LogNorm
	# masks them) instead of taking the bottom colour.
	ranged = _st_trace(plot_histogram2d(data, data; colornorm = :log, crange = (1, 10)))
	@test ranged[:z] == [Any[log10(3), nothing], Any[nothing, log10(2)]]
	@test ranged[:zmin] == 0.0 && ranged[:zmax] == 1.0
	@test ranged[:customdata] == [Any[3.0, 0.0], Any[0.0, 2.0]]

	# plotly counts missing/non-finite entries in the n of its 2σ/n^(1/4) bin
	# estimate (checked against the bins plotly.js computes: width 0.5 here,
	# 1.0 if only the finite samples were counted).
	finite = collect(range(-1.7, 1.7; length = 100))
	@test PlotlySupply._stats_autobins(finite, 0; total = 1000) == (-2.0, 2.0, 0.5)
	@test PlotlySupply._stats_autobins(finite, 0) == (-2.0, 2.0, 1.0)
	padded = _st_trace(plot_histogram2d(vcat(finite, fill(NaN, 900)), vcat(finite, finite, fill(0.5, 800)); colornorm = :log))
	@test padded[:x][2] - padded[:x][1] == 0.5
	@test first(padded[:x]) == -2.0 && last(padded[:x]) == 2.0
	@test_throws ArgumentError PlotlySupply._stats_autobins(Float64[], 0)

	sf = subplots(1, 2; sync = false)
	@test plot_histogram2d!(sf, data, data; colornorm = :log, row = 1, col = 2, xrange = (0, 4)) === sf
	@test _st_fields(sf.plot.data[end])[:xaxis] == "x2"
	@test _st_fields(_st_layout(sf.plot)[:xaxis2])[:range] == [0, 4]
end

@testset "stats: paired lengths and complex data (#50 #75)" begin
	@test_throws ArgumentError plot_bar(["a", "b"], [1, 2, 3])
	@test_throws ArgumentError plot_bar(1:3, [[1, 2, 3], [1, 2]])
	@test_throws ArgumentError plot_box(["a", "b"], [1.0, 2.0, 3.0])
	@test_throws ArgumentError plot_violin(["a", "b"], [1.0, 2.0, 3.0])
	@test_throws ArgumentError plot_box([[1, 1], [2, 2]], [[1.0, 2], [3.0]])
	@test_throws ArgumentError plot_bar([1 + 2im, 3im])
	@test_throws ArgumentError plot_histogram([1 + 2im, 3im])
	@test_throws ArgumentError plot_box(Any[1.0, 2im])
	@test_throws ArgumentError plot_violin([[1.0, 2.0], [1im]])
	matrix = [1.0 4.0; 2.0 5.0; 3.0 6.0]
	@test_throws MethodError plot_bar(view(matrix, :, 1:2))
	@test_throws MethodError plot_histogram(view(matrix, :, 1:2))
	@test _st_trace(plot_bar(view(matrix, :, 1)))[:y] == [1.0, 2.0, 3.0]
	# Ragged series with generated positions remain valid.
	@test length(plot_bar([1:3, 1:5]).data) == 2

	target = plot_scatter(1:3, 1:3)
	@test_throws ArgumentError plot_bar!(target, ["a", "b"], [1, 2, 3])
	@test length(target.data) == 1
	sf = subplots(1, 1; sync = false)
	@test_throws ArgumentError plot_box!(sf, ["a", "b"], [1.0, 2.0, 3.0])
	@test isempty(sf.plot.data)
end

@testset "stats: Vector{Any} multi-series (#40 #46 #59 #68 #132)" begin
	series = Any[[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
	@test length(plot_bar(series).data) == 2
	@test length(plot_bar(["a", "b", "c"], series).data) == 2
	@test length(plot_histogram(series).data) == 2
	@test length(plot_box(series).data) == 2
	@test length(plot_violin(series).data) == 2
	target = plot_scatter(1:3, 1:3)
	plot_box!(target, series)
	plot_violin!(target, series)
	plot_histogram!(target, series)
	plot_bar!(target, series)
	@test length(target.data) == 9
	@test _st_trace(target, 2)[:y] == [1.0, 2.0, 3.0]
	@test_throws ArgumentError plot_bar(Any[[1.0, 2.0], 3.0])
end

@testset "stats: bar text, base, opacity, hatch and error bars (C29, C31)" begin
	fig = plot_bar(
		["a", "b"],
		[[1.0, 2.0], [3.0, 4.0]];
		text = [["low", "\$\\alpha\$"], [3, missing]],
		textposition = "outside",
		texttemplate = "%{y:.1f} \$",
		base = [0.5, 1],
		opacity = 0.8,
		hatch = ["//", "x"],
		error_y = ([0.1, 0.2], [0.3, 0.4]),
		color = [:red, "blue"],
	)
	t1, t2 = _st_trace(fig, 1), _st_trace(fig, 2)
	@test t1[:text] == ["low", "α"]          # plain text, no MathJax
	@test t2[:text] == Any[3, ""]
	@test t1[:textposition] == "outside"
	@test t1[:texttemplate] == "%{y:.1f} \$"  # verbatim plotly template
	@test t1[:base] == [0.5, 1.0] && t2[:base] == [0.5, 1.0]
	@test t1[:opacity] == 0.8
	@test _st_get(t1, :marker, :pattern)[:shape] == "/"
	@test _st_get(t2, :marker, :pattern)[:shape] == "x"
	@test _st_get(t1, :marker)[:color] == "red"
	errors = _st_fields(t1[:error_y])
	@test errors[:symmetric] === false
	@test errors[:array] == [0.3, 0.4] && errors[:arrayminus] == [0.1, 0.2]
	@test _st_fields(_st_trace(plot_bar([1, 2]; error_y = [0.1, 0.2]))[:error_y])[:array] == [0.1, 0.2]
	nested_errors = plot_bar([[1, 2], [3, 4]]; error_x = [[0.1, 0.1], [0.2, 0.2]], text = "same")
	@test _st_fields(_st_trace(nested_errors, 2)[:error_x])[:array] == [0.2, 0.2]
	@test _st_trace(nested_errors, 2)[:text] == "same"
	@test _st_trace(plot_bar([1, 2]; base = -1))[:base] == -1

	@test_throws ArgumentError plot_bar([1, 2]; text = ["one"])
	@test_throws ArgumentError plot_bar([1, 2]; text = [true, false])
	@test_throws ArgumentError plot_bar([1, 2]; textposition = "top")
	@test_throws ArgumentError plot_bar([1, 2]; base = [0, Inf])
	@test_throws ArgumentError plot_bar([1, 2]; base = [0])
	@test_throws ArgumentError plot_bar([1, 2]; opacity = 1.5)
	@test_throws ArgumentError plot_bar([1, 2]; hatch = "o")
	@test_throws ArgumentError plot_bar([1, 2]; error_y = [0.1])
	@test_throws ArgumentError plot_bar([[1, 2], [3, 4]]; error_y = [[0.1, 0.1], [0.2]])
	@test_throws ArgumentError plot_bar([1, 2]; error_y = [0.1, -0.2])
	@test_throws ArgumentError plot_bar([1, 2]; error_y = ["a", "b"])
	@test_throws ArgumentError plot_bar([[1, 2], [3, 4]]; error_y = ([[0.1, 0.1], [0.1, 0.1]], [[0.1, 0.1]]))
	@test_throws ArgumentError plot_bar([1, 2]; error_y = ([0.1, 0.1],))
	@test_throws ArgumentError plot_bar([1, 2]; error_y = 0.1)
	@test_throws ArgumentError plot_bar([1, 2]; barmode = "stacked")
	@test_throws ArgumentError plot_bar([1, 2]; color = [1, 2])
	@test_throws ArgumentError plot_bar([1, 2]; text = "\$x")   # unbalanced mathtext

	stack = plot_bar(["a", "b"], [[1, 2], [3, 4]]; barmode = "stack")
	@test _st_layout(stack)[:barmode] == "stack"

	# Per-point keywords given per series follow the per-series rule: series
	# without an entry get none (as error bars did in 1.x), surplus is ignored.
	partial = plot_bar(
		[[1, 2], [3, 4], [5, 6]];
		error_y = [[0.1, 0.1]],
		text = [["a", "b"], ["c", "d"]],
		base = [[1, 1]],
	)
	@test _st_fields(_st_trace(partial, 1)[:error_y])[:array] == [0.1, 0.1]
	@test !haskey(_st_trace(partial, 2), :error_y)
	@test _st_trace(partial, 2)[:text] == ["c", "d"]
	@test !haskey(_st_trace(partial, 3), :text)
	@test !haskey(_st_trace(partial, 2), :base)
	@test !haskey(_st_trace(plot_bar([[1, 2], [3, 4]]; error_y = Vector{Float64}[]), 1), :error_y)
	# NaN / missing magnitudes leave single bars without an error bar.
	@test isequal(_st_fields(_st_trace(plot_bar([1, 2]; error_y = [NaN, 0.2]))[:error_y])[:array], [NaN, 0.2])
	# Horizontal bars carry the value errors on x.
	horizontal = _st_trace(plot_bar([3.0, 5.0], ["a", "b"]; orientation = "h", error_x = [0.5, 0.25]))
	@test _st_fields(horizontal[:error_x])[:array] == [0.5, 0.25]
end

@testset "stats: histogram hatch, cumulative, orientation and bins (C29)" begin
	samples = randn(100)
	fig = plot_histogram(
		[samples, samples .+ 1];
		bins = (-4, 5, 0.5),
		cumulative = true,
		hatch = ["", "//"],
		histnorm = "probability",
		color = ["red", "blue"],
	)
	t1, t2 = _st_trace(fig, 1), _st_trace(fig, 2)
	@test _st_fields(t1[:xbins]) == Dict(:start => -4.0, Symbol("end") => 5.0, :size => 0.5)
	@test _st_fields(t1[:cumulative])[:enabled] === true
	@test t1[:histnorm] == "probability"
	@test !haskey(_st_get(t1, :marker), :pattern)
	@test _st_get(t2, :marker, :pattern)[:shape] == "/"

	horizontal = _st_trace(plot_histogram(samples; orientation = "h", nbinsx = 10, bins = nothing))
	@test horizontal[:y] == samples && !haskey(horizontal, :x)
	@test horizontal[:orientation] == "h"
	@test horizontal[:nbinsy] == 10 && !haskey(horizontal, :nbinsx)
	horizontal_bins = _st_trace(plot_histogram(samples; orientation = "h", bins = (0, 1, 0.1)))
	@test _st_fields(horizontal_bins[:ybins])[:size] == 0.1

	@test_throws ArgumentError plot_histogram(samples; bins = (0, 1, 0.1), nbinsx = 5)
	@test_throws ArgumentError plot_histogram(samples; bins = (1, 0, 0.1))
	@test_throws ArgumentError plot_histogram(samples; bins = (0, 1, 0))
	@test_throws ArgumentError plot_histogram(samples; bins = (0, 1))
	@test_throws ArgumentError plot_histogram(samples; bins = (0, NaN, 0.1))
	@test_throws ArgumentError plot_histogram(samples; nbinsx = -1)
	@test_throws ArgumentError plot_histogram(samples; histnorm = "count")
	@test_throws ArgumentError plot_histogram(samples; orientation = "x")
	@test_throws ArgumentError plot_histogram(samples; opacity = -0.1)
end

@testset "stats: box/violin orientation, mean, notches, jitter (C34)" begin
	samples = randn(30)
	horizontal = _st_trace(plot_box(samples; orientation = "h"))
	@test horizontal[:x] == samples && !haskey(horizontal, :y)
	@test horizontal[:orientation] == "h"
	passthrough = _st_trace(plot_box(samples, fill("g", 30); orientation = "h"))
	@test passthrough[:x] == samples && passthrough[:y] == fill("g", 30)
	nested_h = plot_violin([samples, samples], fill("g", 30); orientation = "h")
	@test length(nested_h.data) == 2
	@test _st_layout(nested_h)[:violinmode] == "group"

	box = _st_trace(plot_box(samples; boxmean = "sd", notched = true, jitter = 0.3, pointpos = -1.8, points = "all"))
	@test box[:boxmean] == "sd" && box[:notched] === true
	@test box[:jitter] == 0.3 && box[:pointpos] == -1.8
	@test box[:boxpoints] == "all"
	@test _st_trace(plot_box(samples; boxmean = true))[:boxmean] === true
	@test !haskey(_st_trace(plot_box(samples)), :boxmean)
	@test _st_trace(plot_box(samples; points = false))[:boxpoints] === false

	violin = _st_trace(plot_violin(samples; box = true, meanline = true, side = "negative", points = true))
	@test _st_fields(violin[:box])[:visible] === true
	@test _st_fields(violin[:meanline])[:visible] === true
	@test violin[:side] == "negative"
	@test violin[:points] == "all"

	@test_throws ArgumentError plot_box(samples; boxmean = "mean")
	@test_throws ArgumentError plot_box(samples; jitter = 2)
	@test_throws ArgumentError plot_box(samples; pointpos = 3)
	@test_throws ArgumentError plot_box(samples; points = "none")
	@test_throws ArgumentError plot_violin(samples; side = "left")
	@test_throws ArgumentError plot_violin(samples; orientation = "horizontal")

	target = plot_scatter(1:3, 1:3)
	plot_violin!(target, samples; orientation = "h", meanline = true)
	@test _st_trace(target, 2)[:x] == samples
	@test _st_fields(_st_trace(target, 2)[:meanline])[:visible] === true
end

@testset "stats: tick keywords and D7 options (C16)" begin
	fig = plot_bar(
		[1, 10, 100];
		yscale = "log",
		yticks = [1, 10, 100],
		yticklabels = ["one", "ten", "\$10^2\$"],
		xtickformat = "d",
		title = SubString("A title", 1, 7),
		xlabel = "\$x\$",
		width = 640.0,
		height = 480,
		fontsize = 13.5,
	)
	yaxis = _st_axis(fig, :yaxis)
	@test yaxis[:tickvals] == [1.0, 10.0, 100.0]
	@test yaxis[:ticktext][1] == "one"
	@test yaxis[:ticktext][3] == PlotlySupply._label("\$10^2\$")
	@test yaxis[:exponentformat] == "power"
	@test _st_axis(fig, :xaxis)[:tickformat] == "d"
	@test _st_title(_st_layout(fig)[:title]) == "A title"
	@test _st_title(_st_axis(fig, :xaxis)[:title]) == PlotlySupply._label("\$x\$")
	@test _st_layout(fig)[:width] == 640.0
	@test _st_fields(_st_layout(fig)[:font])[:size] == 13.5

	@test_throws ArgumentError plot_bar([1, 2]; xticklabels = ["a", "b"])
	@test_throws ArgumentError plot_bar([1, 2]; xticks = [0, 1], xticklabels = ["a"])
	@test_throws ArgumentError plot_bar([1, 2]; yscale = "log", yticks = [0, 1])
	@test_throws ArgumentError plot_bar([1, 2]; width = -1)
	@test_throws ArgumentError plot_bar([1, 2]; xscale = "logarithmic")
	@test_throws ArgumentError plot_bar([1, 2]; xrange = (1, 2, 3))
	@test_throws ArgumentError plot_bar([1, 2]; title = "\$x")

	sf = subplots(1, 2; sync = false)
	plot_box!(sf, randn(10); row = 1, col = 2, yticks = [-1, 0, 1], ylabel = "cell 2")
	@test _st_fields(_st_layout(sf.plot)[:yaxis2])[:tickvals] == [-1.0, 0.0, 1.0]
	@test !haskey(_st_fields(_st_layout(sf.plot)[:yaxis]), :tickvals)
end

@testset "stats: mutators validate before writing and reject show (C42)" begin
	for mutate! in (
		fig -> plot_bar!(fig, [1, 2]; yrange = (1, 2, 3)),
		fig -> plot_bar!(fig, [1, 2]; xticks = [1], xticklabels = ["a", "b"]),
		fig -> plot_histogram!(fig, [randn(5), randn(5)]; bins = (1, 0, 1)),
		fig -> plot_histogram!(fig, randn(5); xlabel = "\$x"),
		fig -> plot_box!(fig, [randn(5), randn(5)]; legend = ["a", "b"], width = -5),
		fig -> plot_violin!(fig, randn(5); yscale = "log", yrange = (-1, 1)),
		fig -> plot_histogram2d!(fig, randn(5), randn(5); colorscale = "nope"),
	)
		fig = plot_scatter(1:3, 1:3; title = "keep")
		before = _st_snapshot(fig)
		@test_throws ArgumentError mutate!(fig)
		@test _st_snapshot(fig) == before
	end

	fig = plot_scatter(1:3, 1:3)
	for mutate! in (
		() -> plot_bar!(fig, [1, 2]; show = true),
		() -> plot_histogram!(fig, randn(5); show = false),
		() -> plot_box!(fig, randn(5); show = true),
		() -> plot_violin!(fig, randn(5); show = true),
		() -> plot_histogram2d!(fig, randn(5), randn(5); show = true),
	)
		err = try
			mutate!()
			nothing
		catch caught
			caught
		end
		@test err isa ArgumentError
		@test occursin("do not take `show`", sprint(showerror, err))
	end
	@test_throws ArgumentError plot_bar!(fig, [1, 2]; colour = "red")
	@test_throws MethodError plot_bar([1, 2]; colour = "red")
	@test length(fig.data) == 1

	sf = subplots(1, 1; sync = false)
	@test_throws ArgumentError plot_histogram!(sf, randn(5); show = true)
	@test isempty(sf.plot.data)
end

@testset "stats: constructors and mutators take the same keywords" begin
	function declared(f; mutator::Bool)
		names = Set{Symbol}()
		for method in methods(f)
			signature = Base.unwrap_unionall(method.sig).parameters
			if mutator
				(length(signature) >= 2 && signature[2] === Any) || continue
			end
			union!(names, filter(!=(Symbol("kwargs...")), Base.kwarg_decl(method)))
		end
		return names
	end
	for (constructor, mutator) in (
		(plot_bar, plot_bar!),
		(plot_histogram, plot_histogram!),
		(plot_box, plot_box!),
		(plot_violin, plot_violin!),
		(plot_histogram2d, plot_histogram2d!),
	)
		ctor_keywords = declared(constructor; mutator = false)
		@test :show in ctor_keywords
		@test setdiff(ctor_keywords, (:show,)) == declared(mutator; mutator = true)
	end
end

@testset "stats: secondary y axis of a subplot cell" begin
	sf = subplots(1, 2; sync = false, specs = [PlotlySupply.Spec(secondary_y = true) PlotlySupply.Spec()])
	plot_bar!(sf, [1, 2, 3]; row = 1, col = 1)
	plot_box!(sf, randn(10); row = 1, col = 1, secondary_y = true)
	plot_histogram!(sf, randn(20); row = 1, col = 2)
	routed = [_st_fields(trace) for trace in sf.plot.data]
	@test routed[1][:yaxis] == "y"
	@test routed[2][:yaxis] != "y" && routed[2][:xaxis] == "x"
	@test routed[3][:xaxis] != "x"
end

# A SyncPlot whose renderer is a recording stub: mutators must update the model
# and send the change in one transaction, or leave both untouched.
function _st_probe_syncplot(plot)
	scripts = String[]
	backend = (
		isopen = window -> true,
		close = window -> nothing,
		run = (window, script) -> (push!(scripts, String(script)); "ok"),
	)
	resources = PlotlySupply._SyncPlotResources(nothing, backend)
	return SyncPlot(plot, nothing, :stats_probe_window, "stats-probe", resources), scripts
end

@testset "stats: SyncPlot mutators commit atomically" begin
	for mutate! in (
		sp -> plot_bar!(sp, [1, 2]; legend = "bars", yrange = (0, 3)),
		sp -> plot_bar!(sp, [1.0, 2.0], ["a", "b"]; orientation = "h"),
		sp -> plot_histogram!(sp, [randn(20), randn(20)]; bins = (-3, 3, 0.5)),
		sp -> plot_box!(sp, randn(10); boxmean = true, grid = :y),
		sp -> plot_box!(sp, fill("g", 10), randn(10)),
		sp -> plot_violin!(sp, randn(10); box = true),
		sp -> plot_violin!(sp, fill("g", 10), randn(10)),
		sp -> plot_histogram2d!(sp, randn(30), randn(30); colornorm = :log),
	)
		sp, scripts = _st_probe_syncplot(plot_scatter(1:3, 1:3))
		@test mutate!(sp) === nothing
		@test length(sp.plot.data) >= 2
		@test !isempty(scripts)
	end

	sp, scripts = _st_probe_syncplot(plot_scatter(1:3, 1:3; title = "keep"))
	before = _st_snapshot(sp.plot)
	@test_throws ArgumentError plot_bar!(sp, [1, 2]; error_y = [0.1])
	@test_throws ArgumentError plot_histogram!(sp, randn(5); bins = (0, 1, -1))
	@test_throws ArgumentError plot_box!(sp, randn(5); show = true)
	@test_throws ArgumentError plot_histogram2d!(sp, randn(5), randn(4))
	@test _st_snapshot(sp.plot) == before
	@test isempty(scripts)
end

@testset "stats: histograms on a log binning axis are binned in Julia" begin
	# plotly.js 2.35 draws nothing for a histogram binned along a log axis, so
	# the counts are made in Julia and drawn as bars spanning the bins.
	data = exp.(randn(2000))
	fig = plot_histogram(data; xscale = "log")
	trace = _st_trace(fig)
	@test trace[:type] == "bar"
	@test trace[:offset] == 0
	left, right = trace[:x], trace[:x] .+ trace[:width]
	@test right[1:(end - 1)] ≈ left[2:end]                     # contiguous bins
	steps = log10.(right) .- log10.(left)
	@test all(isapprox.(steps, steps[1]; atol = 1e-9))          # equal width in decades
	@test sum(trace[:y]) == 2000
	@test first(left) <= minimum(data) && last(right) >= maximum(data)
	@test trace[:customdata][1] ≈ [left[1], right[1]]
	@test _st_axis(fig, :xaxis)[:type] == "log"
	# nbinsx works as for plotly's automatic bins, over log10 of the data.
	l_start, l_stop, l_width = PlotlySupply._stats_autobins(log10.(data), 5; total = length(data))
	@test log10.(_st_trace(plot_histogram(data; xscale = "log", nbinsx = 5))[:x]) ≈
		[l_start + k * l_width for k in 0:(round(Int, (l_stop - l_start) / l_width) - 1)]

	# Non-positive samples cannot be shown on a log axis and are not counted.
	@test sum(_st_trace(plot_histogram([-1.0, 0.0, 1.0, 2.0, 30.0]; xscale = "log"))[:y]) == 3
	@test_throws ArgumentError plot_histogram([-1.0, 0.0]; xscale = "log")
	@test_throws ArgumentError plot_histogram(["a", "b"]; xscale = "log")

	# Normalizations follow plotly's histnorm / cumulative semantics.
	density = _st_trace(plot_histogram(data; xscale = "log", histnorm = "probability density"))
	@test sum(density[:y] .* density[:width]) ≈ 1
	@test sum(_st_trace(plot_histogram(data; xscale = "log", histnorm = "percent"))[:y]) ≈ 100
	cumulative = _st_trace(plot_histogram(data; xscale = "log", histnorm = "probability", cumulative = true))
	@test issorted(cumulative[:y]) && last(cumulative[:y]) ≈ 1
	@test last(_st_trace(plot_histogram(data; xscale = "log", histnorm = "density", cumulative = true))[:y]) == 2000

	# Explicit bins are linear in data units and must start above 0.
	explicit = _st_trace(plot_histogram(data; xscale = "log", bins = (0.5, 10, 0.5)))
	@test explicit[:x] ≈ collect(0.5:0.5:9.5)
	@test all(explicit[:width] .≈ 0.5)
	@test sum(explicit[:y]) == count(value -> 0.5 <= value < 10, data)
	@test_throws ArgumentError plot_histogram(data; xscale = "log", bins = (0, 10, 1))

	# The series of one call share their bins; overlay is translucent and
	# group mode splits each bin into equal shares in decades.
	a, b = data, 3 .* exp.(randn(500))
	overlay = plot_histogram([a, b]; xscale = "log", legend = ["a", "b"])
	@test _st_trace(overlay, 1)[:x] == _st_trace(overlay, 2)[:x]
	@test _st_trace(overlay, 1)[:opacity] == 0.6
	@test _st_layout(overlay)[:barmode] == "overlay"
	grouped = plot_histogram([a, b]; xscale = "log", barmode = "group")
	first_series, second_series = _st_trace(grouped, 1), _st_trace(grouped, 2)
	@test first_series[:x] .+ first_series[:width] ≈ second_series[:x]
	@test log10.(first_series[:x] .+ first_series[:width]) .- log10.(first_series[:x]) ≈
		log10.(second_series[:x] .+ second_series[:width]) .- log10.(second_series[:x])
	@test first_series[:customdata] == second_series[:customdata]   # hover shows the whole bin

	# Horizontal histograms bin along a log y axis; a log COUNT axis keeps
	# plotly's own histogram.
	horizontal = _st_trace(plot_histogram(data; yscale = "log", orientation = "h"))
	@test horizontal[:type] == "bar" && horizontal[:orientation] == "h"
	@test sum(horizontal[:x]) == 2000
	@test _st_trace(plot_histogram(data; yscale = "log"))[:type] == "histogram"

	# A mutator target whose binning axis is already logarithmic.
	target = plot_scatter([1, 10], [1, 2]; xscale = "log")
	plot_histogram!(target, data)
	@test _st_trace(target, 2)[:type] == "bar"

	# Styling keywords carry over to the bars.
	styled = _st_trace(plot_histogram(data; xscale = "log", color = "red", hatch = "/", legend = "s", showlegend = true))
	@test _st_fields(styled[:marker])[:color] == "red"
	@test haskey(_st_fields(styled[:marker]), :pattern)
	@test styled[:name] == "s" && styled[:showlegend] === true
end

# ── wave 3 (oned-int) ────────────────────────────────────────────────────────

_st_error(f) = try
	f()
	nothing
catch err
	err
end
_st_axis_or_empty(fig, key) = _st_fields(get(_st_layout(fig), key, Dict{Symbol, Any}()))

@testset "stats: one overlay mechanism per case (X3, K8)" begin
	# A figure without other bars: the root overlay alone, no offset slot.
	fresh = plot_histogram([randn(20), randn(20)])
	@test _st_layout(fresh)[:barmode] == "overlay"
	@test all(!haskey(_st_fields(t), :offsetgroup) for t in fresh.data)
	lines = plot_scatter(1:3, 1:3)
	plot_histogram!(lines, [randn(20), randn(20)])
	@test _st_layout(lines)[:barmode] == "overlay"
	@test all(!haskey(_st_fields(t), :offsetgroup) for t in lines.data)
	# Grouped bars already present: plotly's "group" mode stays for them and
	# only the new series share one offset slot (and so overlay).
	mixed = plot_bar(["a", "b"], [[1, 2], [3, 4]])
	plot_histogram!(mixed, [randn(20), randn(20)])
	@test !haskey(_st_layout(mixed), :barmode)
	@test !haskey(_st_trace(mixed, 1), :offsetgroup) && !haskey(_st_trace(mixed, 2), :offsetgroup)
	@test _st_trace(mixed, 3)[:offsetgroup] == _st_trace(mixed, 4)[:offsetgroup] == _st_trace(mixed, 3)[:bingroup]
	@test _st_trace(mixed, 3)[:opacity] == 0.6
	# An existing root overlay needs neither.
	again = plot_histogram([randn(20), randn(20)])
	plot_histogram!(again, [randn(20), randn(20)])
	@test all(!haskey(_st_fields(t), :offsetgroup) for t in again.data)
	# SubplotFigure: a cell overlays through the slot; a root overlay set by
	# the user makes it unnecessary.
	sf = subplots(1, 1; sync = false)
	plot_histogram!(sf, [randn(20), randn(20)])
	cell = [_st_fields(t) for t in sf.plot.data]
	@test cell[1][:offsetgroup] == cell[2][:offsetgroup]
	@test !haskey(_st_layout(sf.plot), :barmode)
	overlaid = subplots(1, 1; sync = false)
	relayout!(overlaid; barmode = "overlay")
	plot_histogram!(overlaid, [randn(20), randn(20)])
	@test all(!haskey(_st_fields(t), :offsetgroup) for t in overlaid.plot.data)
	# An explicit mode goes to the root.
	explicit = plot_bar(["a"], [1])
	plot_histogram!(explicit, [randn(20), randn(20)]; barmode = "stack")
	@test _st_layout(explicit)[:barmode] == "stack"
	@test all(!haskey(_st_fields(t), :offsetgroup) for t in explicit.data)
	# Log-axis bars carry `offset`, which plotly draws overlaid without a slot.
	logged = plot_bar([1.0, 2.0], [1, 2])
	plot_histogram!(logged,[exp.(randn(50)), exp.(randn(50))]; xscale = "log")
	@test all(!haskey(_st_fields(t), :offsetgroup) for t in logged.data)
end

@testset "stats: ranges have the xrange!/yrange! semantics (X23, 18, 52, 76, 93)" begin
	builds = (
		r -> plot_bar([1, 2]; yrange = r),
		r -> plot_histogram(randn(10); xrange = r),
		r -> plot_box(randn(10); yrange = r),
		r -> plot_violin(randn(10); yrange = r),
		r -> plot_histogram2d(randn(10), randn(10); xrange = r),
	)
	mutators = (
		(f, r) -> plot_bar!(f, [1, 2]; yrange = r),
		(f, r) -> plot_histogram!(f, randn(10); xrange = r),
		(f, r) -> plot_box!(f, randn(10); yrange = r),
		(f, r) -> plot_violin!(f, randn(10); yrange = r),
		(f, r) -> plot_histogram2d!(f, randn(10), randn(10); xrange = r),
	)
	for (build, mutate!) in zip(builds, mutators)
		for (bad, message) in (
			((nothing, 2), "partial ranges are not supported"),
			((false, true), "must be numbers"),
			([2, 2], "must differ"),
			((1, 2, 3), "exactly 2 elements"),
		)
			err = _st_error(() -> build(bad))
			@test err isa ArgumentError && occursin(message, err.msg)
			target = plot_scatter(1:3, 1:3)
			before = _st_snapshot(target)
			err = _st_error(() -> mutate!(target, bad))
			@test err isa ArgumentError && occursin(message, err.msg)
			@test _st_snapshot(target) == before
		end
		for automatic in (nothing, [0, 0], [nothing, nothing], (nothing, nothing))
			fig = build(automatic)
			@test !haskey(_st_axis_or_empty(fig, :xaxis), :range)
			@test !haskey(_st_axis_or_empty(fig, :yaxis), :range)
		end
	end
	# Data units on a log axis, constructor and mutator.
	@test _st_axis(plot_bar([1, 10, 100]; yscale = "log", yrange = (1, 1000)), :yaxis)[:range] ≈ [0.0, 3.0]
	target = plot_bar([1, 10, 100])
	plot_bar!(target, [2, 20, 200]; yscale = "log", yrange = (1, 1000))
	@test _st_axis(target, :yaxis)[:range] ≈ [0.0, 3.0]
	@test_throws ArgumentError plot_box(exp.(randn(10)); yscale = "log", yrange = (0, 10))
end

@testset "stats: tick presets reach the shared tick helper (D9)" begin
	err = _st_error(() -> plot_bar([1, 2]; yticks = :decades))
	@test err isa ArgumentError && startswith(err.msg, "plot_bar:") && occursin("logarithmic y axis", err.msg)
	err = _st_error(() -> plot_histogram(randn(10); xticks = :auto, xticklabels = ["a"]))
	@test err isa ArgumentError && occursin("cannot be combined with the tick preset", err.msg)
	err = _st_error(() -> plot_box!(plot_scatter(1:3, 1:3), randn(5); yticks = :decades))
	@test err isa ArgumentError && startswith(err.msg, "plot_box!:")
	# On a log axis the preset passes the family's validation (the shared
	# helper then draws it).
	fig = plot_bar([1, 10, 100]; yscale = "log")
	@test PlotlySupply._scat_validate_cartesian_options(fig, "plot_bar"; yticks = :decades) === nothing
end

@testset "stats: plain log axes label powers of ten (X22)" begin
	@test _st_axis(plot_bar([1, 10, 100]; yscale = "log"), :yaxis)[:exponentformat] == "power"
	@test _st_axis(plot_histogram(exp.(randn(50)); xscale = "log"), :xaxis)[:exponentformat] == "power"
	@test _st_axis(plot_box(exp.(randn(20)); yscale = "log"), :yaxis)[:exponentformat] == "power"
	@test _st_axis(plot_violin(exp.(randn(20)); yscale = "log"), :yaxis)[:exponentformat] == "power"
	target = plot_bar([1, 2])
	plot_bar!(target, [10, 100]; yscale = "log")
	@test _st_axis(target, :yaxis)[:exponentformat] == "power"
end

@testset "stats: matrices and 2-D views are rejected with a hint (X29)" begin
	M = [1.0 4.0; 2.0 5.0; 3.0 6.0]
	for call in (
		() -> plot_bar(M),
		() -> plot_bar(view(M, :, 1:2)),
		() -> plot_bar(1:3, M),
		() -> plot_histogram(M),
		() -> plot_box(M),
		() -> plot_box(["a", "b", "c"], M),
		() -> plot_violin(M),
		() -> plot_violin(1:3, M),
		() -> plot_histogram2d(M, M),
		() -> plot_histogram2d(1:3, M),
	)
		err = _st_error(call)
		@test err isa ArgumentError
		@test occursin("must be a vector", err.msg) && occursin("eachcol", err.msg)
	end
	err = _st_error(() -> plot_bar([M, M]))
	@test err isa ArgumentError && occursin("entries must be scalars", err.msg)
	# Mutators on a Plot and on a SubplotFigure change nothing.
	target = plot_scatter(1:3, 1:3)
	before = _st_snapshot(target)
	for mutate! in (
		f -> plot_bar!(f, M),
		f -> plot_histogram!(f, M),
		f -> plot_box!(f, M),
		f -> plot_violin!(f, 1:3, M),
		f -> plot_histogram2d!(f, M, M),
	)
		@test_throws ArgumentError mutate!(target)
		sf = subplots(1, 1; sync = false)
		@test_throws ArgumentError mutate!(sf)
		@test isempty(sf.plot.data)
	end
	@test _st_snapshot(target) == before
	# A column view is a vector.
	@test collect(_st_trace(plot_bar(view(M, :, 1)))[:y]) == [1.0, 2.0, 3.0]
end

@testset "stats: inset = k on every SubplotFigure mutator (X20)" begin
	axis_kw = (; xrange = (0, 3), xlabel = "ix", ylabel = "iy")
	for (mutate!, log_y) in (
		(sf -> plot_bar!(sf, [1, 2], [3, 30]; inset = 1, yscale = "log", axis_kw...), true),
		(sf -> plot_histogram!(sf, [randn(20), randn(20)]; inset = 1, yscale = "log", axis_kw...), true),
		(sf -> plot_box!(sf, exp.(randn(20)); inset = 1, yscale = "log", axis_kw...), true),
		(sf -> plot_violin!(sf, exp.(randn(20)); inset = 1, yscale = "log", axis_kw...), true),
		(sf -> plot_histogram2d!(sf, randn(20), randn(20); inset = 1, axis_kw...), false),
	)
		sf = subplots(1, 1; sync = false)
		inset!(sf, (0.55, 0.55, 0.4, 0.4))
		@test mutate!(sf) === sf
		@test all(_st_fields(t)[:xaxis] == "x2" && _st_fields(t)[:yaxis] == "y2" for t in sf.plot.data)
		inset_x, inset_y = _st_axis(sf.plot, :xaxis2), _st_axis(sf.plot, :yaxis2)
		@test inset_x[:range] == [0, 3]
		@test _st_title(inset_x[:title]) == "ix" && _st_title(inset_y[:title]) == "iy"
		log_y && @test inset_y[:type] == "log"
		main_x, main_y = _st_axis_or_empty(sf.plot, :xaxis), _st_axis_or_empty(sf.plot, :yaxis)
		@test !haskey(main_x, :range) && !haskey(main_y, :type)
		@test !haskey(main_x, :title) || isempty(_st_title(main_x[:title]))
	end
	# An unknown inset changes nothing; a Plot takes no `inset`.
	sf = subplots(1, 1; sync = false)
	inset!(sf, (0.55, 0.55, 0.4, 0.4))
	err = _st_error(() -> plot_bar!(sf, [1, 2]; inset = 2))
	@test err isa ArgumentError && occursin("plot_bar!", err.msg)
	@test isempty(sf.plot.data)
	@test_throws ArgumentError plot_box!(plot_scatter(1:3, 1:3), randn(5); inset = 1)
	# `row = nothing`/`col = nothing` (no cell) are accepted on a Plot, as in
	# the scatter family.
	fig = plot_scatter(1:3, 1:3)
	@test plot_bar!(fig, [1, 2]; row = nothing, col = nothing) === nothing
	@test_throws ArgumentError plot_bar!(fig, [1, 2]; row = 1)
end
