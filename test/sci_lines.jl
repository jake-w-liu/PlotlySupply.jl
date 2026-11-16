using Test, PlotlySupply

# Tests for src/sci/lines.jl: plot_band (F18), plot_segments / plot_vlines /
# plot_hlines (F19), plot_ecdf / plot_kde / plot_complex (F20).

_sl_fields(value) = value isa AbstractDict ? value : value.fields
_sl_get(value, key, default = nothing) = get(_sl_fields(value), key, default)
_sl_axis(fig, key) = _sl_fields(PlotlySupply._plot_obj(fig).layout.fields[key])
_sl_snapshot(fig) = (
	length(PlotlySupply._plot_obj(fig).data),
	deepcopy(PlotlySupply._plot_obj(fig).layout),
)
_sl_unchanged(fig, snapshot) =
	length(PlotlySupply._plot_obj(fig).data) == snapshot[1] &&
	PlotlySupply._plot_obj(fig).layout == snapshot[2]

function _sl_syncplot(p::Plot)
	backend = (
		isopen = window -> true,
		close = window -> nothing,
		run = (window, script) -> "ok",
	)
	return SyncPlot(
		p,
		nothing,
		:sl_window,
		"sl-div",
		PlotlySupply._SyncPlotResources(nothing, backend, nothing),
	)
end

# NaN/Inf never reach a trace; gaps are `nothing` (JSON null).
_sl_no_nan(values) = all(v -> v === nothing || !(v isa AbstractFloat) || isfinite(v), values)

@testset "sci lines: plot_band polygon (F18)" begin
	x = [0.0, 1.0, 2.0]
	f = plot_band(x, [0.0, 0.5, 1.0], [1.0, 2.0, 3.0]; legend = "band", color = "steelblue")
	@test length(f.data) == 1
	t = f.data[1]
	@test t.fields[:fill] == "toself"
	@test t.fields[:mode] == "lines"
	@test t.fields[:hoverinfo] == "skip"
	@test t.fields[:name] == "band"
	# Upper edge left to right, lower edge back.
	@test t.fields[:x] == [0.0, 1.0, 2.0, 2.0, 1.0, 0.0]
	@test t.fields[:y] == [1.0, 2.0, 3.0, 1.0, 0.5, 0.0]
	@test t.fields[:fillcolor] == PlotlySupply._rgba("steelblue", 0.25)
	@test _sl_get(t.fields[:line], :width) == 0

	# Scalar edges, an outline (closed ring) and the default colour.
	g = plot_band(x, 0, [1.0, 2.0, 3.0]; linewidth = 1.5, edgecolor = "black", opacity = 0.4)
	tg = g.data[1]
	@test tg.fields[:x] == [0.0, 1.0, 2.0, 2.0, 1.0, 0.0, 0.0]
	@test tg.fields[:y] == [1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 1.0]
	@test _sl_get(tg.fields[:line], :color) == "black"
	@test _sl_get(tg.fields[:line], :width) == 1.5
	@test tg.fields[:fillcolor] == PlotlySupply._rgba(PlotlySupply._default_trace_color(g, 1), 0.4)

	# `where` splits the band into one ring per run, separated by gaps.
	w = plot_band(0:5, 0, [1, 2, 3, 4, 5, 6]; where = [true, true, false, false, true, true])
	tw = w.data[1]
	@test tw.fields[:x] == [0.0, 1.0, 1.0, 0.0, nothing, 4.0, 5.0, 5.0, 4.0]
	@test tw.fields[:y] == [1.0, 2.0, 0.0, 0.0, nothing, 5.0, 6.0, 0.0, 0.0]
	# Values excluded by `where` may be anything, and never reach the trace.
	nan_band = plot_band(0:2, 0, [1.0, NaN, 3.0]; where = [true, false, true])
	@test _sl_no_nan(nan_band.data[1].fields[:y])
	@test isempty(plot_band(0:2, 0, [1, 2, 3]; where = falses(3)).data[1].fields[:x])

	# Several bands: nested x/lower/upper, one trace each.
	m = plot_band([0:2, 0:2], 0, [[1, 1, 1], [2, 2, 2]]; legend = ["a", "b"])
	@test length(m.data) == 2
	@test [t.fields[:name] for t in m.data] == ["a", "b"]
	@test m.data[2].fields[:y][1:3] == [2.0, 2.0, 2.0]

	h = plot_band(x, 0, [1, 2, 3]; hatch = "x")
	@test haskey(h.data[1].fields, :fillpattern)

	# Bands keep call order, so a line added later is drawn on top.
	l = plot_band(x, 0, [1, 2, 3]; legend = "band")
	plot_scatter!(l, x, [0.5, 1, 1.5]; legend = "line")
	@test [t.fields[:name] for t in l.data] == ["band", "line"]
end

@testset "sci lines: plot_band validation" begin
	@test_throws ArgumentError plot_band([0, 1, 2], [0, 0], [1, 1, 1])
	@test_throws ArgumentError plot_band([0, 1, 2], 0, [1, NaN, 1])
	@test_throws ArgumentError plot_band([0, 1, 2], 0, [1, 2, 3]; where = [true, false])
	@test_throws ArgumentError plot_band([0, 1, 2], 0, [1, 2, 3]; where = [1, 0, 1])
	@test_throws ArgumentError plot_band([0, 1, 2], 0, [1, 2, 3]; opacity = 2)
	@test_throws ArgumentError plot_band([0, 1, 2], 0, [1, 2, 3]; yscale = "log")
	@test_throws ArgumentError plot_band([0, 1, 2], [1im, 0, 0], [1, 2, 3])
	@test_throws ArgumentError plot_band([[0, 1], [0, 1], [0, 1]], 0, [[1, 1], [2, 2]])
	@test plot_band([0, 1, 2], 0, [1, 2, 3]; legend = ["a", "b"]).data[1].fields[:name] == "a"
	@test_throws ArgumentError plot_band([0, 1, 2], 0, [1, 2, 3]; hatch = "?")
	p = plot_scatter(1:3, 1:3)
	snapshot = _sl_snapshot(p)
	@test_throws ArgumentError plot_band!(p, [0, 1, 2], 0, [1, 2])
	@test_throws ArgumentError plot_band!(p, [0, 1, 2], 0, [1, 2, 3]; show = true)
	@test_throws ArgumentError plot_band!(p, [0, 1, 2], 0, [1, 2, 3]; colour = "red")
	@test _sl_unchanged(p, snapshot)
	@test plot_band(1:3, 1, [2, 3, 4]; yscale = "log").data[1].fields[:y][1] == 2.0
end

@testset "sci lines: segments, vlines and hlines (F19)" begin
	s = plot_segments([0, 2], [0, 1], [1, 3], [1, 0]; color = "red", linewidth = 2, legend = "seg")
	@test length(s.data) == 1
	t = s.data[1]
	@test t.fields[:x] == [0.0, 1.0, nothing, 2.0, 3.0, nothing]
	@test t.fields[:y] == [0.0, 1.0, nothing, 1.0, 0.0, nothing]
	@test t.fields[:mode] == "lines"
	@test _sl_get(t.fields[:line], :color) == "red"
	@test _sl_get(t.fields[:line], :width) == 2
	@test t.fields[:name] == "seg"

	v = plot_vlines([1, 2, 3], 0, [1, 2, 1.5]; dash = "dash")
	tv = v.data[1]
	@test tv.fields[:x] == [1.0, 1.0, nothing, 2.0, 2.0, nothing, 3.0, 3.0, nothing]
	@test tv.fields[:y] == [0.0, 1.0, nothing, 0.0, 2.0, nothing, 0.0, 1.5, nothing]
	@test _sl_get(tv.fields[:line], :dash) == "dash"

	h = plot_hlines([0.5, 1.5], 0, 4)
	th = h.data[1]
	@test th.fields[:x] == [0.0, 4.0, nothing, 0.0, 4.0, nothing]
	@test th.fields[:y] == [0.5, 0.5, nothing, 1.5, 1.5, nothing]

	# A single number gives one segment; a million segments are one trace.
	@test plot_vlines(2, 0, 1).data[1].fields[:x] == [2.0, 2.0, nothing]
	many = plot_segments(rand(10^5), rand(10^5), rand(10^5), rand(10^5))
	@test length(many.data) == 1
	@test length(many.data[1].fields[:x]) == 3 * 10^5

	@test_throws ArgumentError plot_segments([0, 1], [0, 1], [1, 2, 3], [1, 0])
	@test_throws ArgumentError plot_vlines([1, 2], 0, [1, NaN])
	@test_throws ArgumentError plot_hlines([1, 2], 0, 4; xscale = "log")
	@test_throws ArgumentError plot_vlines([1, 2], [0, 1], 2; yscale = "log")
	@test_throws ArgumentError plot_segments([0], [0], [1], ["a"])
	@test_throws ArgumentError plot_vlines([1, 2], 0, 1; opacity = -0.1)
	@test_throws ArgumentError plot_hlines([1, 2], 0, 1; dash = "wavy")

	p = plot_scatter(1:3, [1, 2, 3]; legend = "data")
	@test plot_vlines!(p, [1.5, 2.5], 0, 3; color = "gray") === nothing
	@test plot_hlines!(p, 2, 1, 3) === nothing
	@test plot_segments!(p, 1, 1, 3, 3; secondary_y = true) === nothing
	@test length(p.data) == 4
	@test p.data[4].fields[:yaxis] == "y2"
	@test_throws ArgumentError plot_hlines!(p, 2, 1, 3; show = true)
end

@testset "sci lines: plot_ecdf (F20)" begin
	f = plot_ecdf([3.0, 1.0, 2.0, NaN, missing]; legend = "ecdf")
	t = f.data[1]
	@test t.fields[:x] == [1.0, 1.0, 2.0, 3.0]
	@test t.fields[:y] ≈ [0.0, 1 / 3, 2 / 3, 1.0]
	@test _sl_get(t.fields[:line], :shape) == "hv"
	@test t.fields[:mode] == "lines"

	c = plot_ecdf([3.0, 1.0, 2.0]; complementary = true, stat = :count)
	@test c.data[1].fields[:y] == [3.0, 2.0, 1.0, 0.0]
	k = plot_ecdf([1, 1, 2]; stat = :count)
	@test k.data[1].fields[:x] == [1.0, 1.0, 1.0, 2.0]
	@test k.data[1].fields[:y] == [0.0, 1.0, 2.0, 3.0]

	m = plot_ecdf([randn(10), randn(20)]; legend = ["a", "b"], dash = ["solid", "dash"])
	@test length(m.data) == 2
	@test length(m.data[2].fields[:x]) == 21
	@test m.data[2].fields[:y][end] == 1.0

	@test_throws ArgumentError plot_ecdf([NaN, missing])
	@test_throws ArgumentError plot_ecdf(Float64[])
	@test_throws ArgumentError plot_ecdf([1.0, Inf])
	@test_throws ArgumentError plot_ecdf([1.0, 2.0]; stat = :density)
	@test_throws ArgumentError plot_ecdf([1.0 + 1im])
	@test_throws ArgumentError plot_ecdf([-1.0, 2.0]; xscale = "log")
	@test_throws ArgumentError plot_ecdf([1.0 2.0; 3.0 4.0])
	@test plot_ecdf([1.0, 10.0]; xscale = "log") isa Plot

	p = plot_ecdf([1.0, 2.0])
	@test plot_ecdf!(p, [1.5, 2.5]; legend = "b") === nothing
	@test length(p.data) == 2
end

@testset "sci lines: plot_kde (F20)" begin
	sample = [-1.0, 0.0, 0.0, 1.0, 2.0]
	f = plot_kde(sample; bandwidth = 0.5, npoints = 101, cut = 2, legend = "kde")
	t = f.data[1]
	grid = t.fields[:x]
	@test length(grid) == 101
	@test first(grid) ≈ -2.0
	@test last(grid) ≈ 3.0
	# Direct evaluation of the Gaussian KDE at one grid point.
	g = grid[51]
	expected = sum(exp(-0.5 * ((g - s) / 0.5)^2) for s in sample) / (5 * 0.5 * sqrt(2π))
	@test t.fields[:y][51] ≈ expected
	# It integrates to about 1 (trapezoid rule, grid covers ±2 bandwidths + data).
	wide = plot_kde(sample; bandwidth = 0.5, npoints = 2001, cut = 8).data[1]
	dx = wide.fields[:x][2] - wide.fields[:x][1]
	@test isapprox(sum(wide.fields[:y]) * dx, 1.0; atol = 1e-3)

	# Bandwidth rules.
	data = collect(1.0:10.0)
	n = length(data)
	sigma = sqrt(sum((data .- 5.5) .^ 2) / (n - 1))
	iqr = PlotlySupply._kde_quantile(data, 0.75) - PlotlySupply._kde_quantile(data, 0.25)
	@test iqr ≈ 4.5
	@test PlotlySupply._kde_bandwidth(data, :silverman, "t", "x") ≈ 0.9 * min(sigma, iqr / 1.34) * n^(-1 / 5)
	@test PlotlySupply._kde_bandwidth(data, :scott, "t", "x") ≈ (4 / 3)^(1 / 5) * sigma * n^(-1 / 5)

	filled = plot_kde([randn(50), randn(50) .+ 2]; fill = true, legend = ["a", "b"])
	@test length(filled.data) == 2
	@test all(t.fields[:fill] == "tozeroy" for t in filled.data)

	@test_throws ArgumentError plot_kde([1.0])
	@test plot_kde([1.0]; bandwidth = 0.1) isa Plot
	@test_throws ArgumentError plot_kde([2.0, 2.0])
	@test_throws ArgumentError plot_kde(sample; bandwidth = -1)
	@test_throws ArgumentError plot_kde(sample; bandwidth = :wide)
	@test_throws ArgumentError plot_kde(sample; npoints = 1)
	@test_throws ArgumentError plot_kde(sample; cut = -1)
	@test_throws ArgumentError plot_kde(sample; xscale = "log")
	@test plot_kde([10.0, 11.0, 12.0]; xscale = "log", cut = 1).data[1].fields[:x][1] > 0

	p = plot_scatter(1:3, 1:3)
	snapshot = _sl_snapshot(p)
	@test_throws ArgumentError plot_kde!(p, sample; npoints = 0)
	@test _sl_unchanged(p, snapshot)
	@test plot_kde!(p, sample; secondary_y = true, legend = "density") === nothing
	@test p.data[end].fields[:yaxis] == "y2"
end

@testset "sci lines: plot_complex (F20)" begin
	z = [1 + 1im, -1 + 0.5im, 0.0 - 2im]
	f = plot_complex(z; legend = "z")
	t = f.data[1]
	@test t.fields[:x] == [1.0, -1.0, 0.0]
	@test t.fields[:y] == [1.0, 0.5, -2.0]
	@test t.fields[:mode] == "markers"
	@test _sl_get(_sl_axis(f, :xaxis)[:title], :text) == "Re"
	@test _sl_get(_sl_axis(f, :yaxis)[:title], :text) == "Im"
	@test _sl_axis(f, :yaxis)[:scaleanchor] == "x"

	u = plot_complex(z; unit_circle = true)
	@test length(u.data) == 2
	circle = u.data[2]
	@test circle.fields[:showlegend] === false
	@test length(circle.fields[:x]) == 361
	@test all(isapprox.(hypot.(circle.fields[:x], circle.fields[:y]), 1.0; atol = 1e-12))

	m = plot_complex([z, 2 .* z]; legend = ["z", "2z"], mode = "lines+markers")
	@test length(m.data) == 2
	@test m.data[2].fields[:x] == [2.0, -2.0, 0.0]

	@test plot_complex([1.0, 2.0]).data[1].fields[:y] == [0.0, 0.0]
	@test_throws ArgumentError plot_complex(["a", "b"])
	@test_throws ArgumentError plot_complex([1im 2im; 3im 4im])
	@test_throws ArgumentError plot_complex(z; mode = "bars")

	p = plot_complex(z)
	@test plot_complex!(p, conj.(z); legend = "conj", unit_circle = true) === nothing
	@test length(p.data) == 3
	@test p.data[2].fields[:y] == [-1.0, -0.5, 2.0]
	@test_throws ArgumentError plot_complex!(p, z; show = true)
end

@testset "sci lines: SyncPlot and SubplotFigure mutators" begin
	sp = _sl_syncplot(plot_scatter(1:3, [1, 2, 3]))
	@test plot_band!(sp, 1:3, 0, [1, 2, 3]) === nothing
	@test plot_vlines!(sp, 2, 0, 3) === nothing
	@test plot_ecdf!(sp, [1.0, 2.0, 3.0]) === nothing
	@test length(sp.plot.data) == 4
	@test_throws ArgumentError plot_band!(sp, 1:3, 0, [1, 2])
	@test length(sp.plot.data) == 4

	sf = subplots(1, 2; sync = false)
	@test plot_band!(sf, 1:3, 0, [1, 2, 3]; row = 1, col = 2, legend = "b") === sf
	@test plot_segments!(sf, 0, 0, 1, 1; row = 1, col = 2) === sf
	@test plot_hlines!(sf, 1, 0, 2; row = 1, col = 2) === sf
	@test plot_vlines!(sf, 1, 0, 2; row = 1, col = 2) === sf
	@test plot_ecdf!(sf, [1.0, 2.0]; row = 1, col = 2) === sf
	@test plot_kde!(sf, [1.0, 2.0, 4.0]; row = 1, col = 2) === sf
	@test plot_complex!(sf, [1im, 1.0]; row = 1, col = 2, unit_circle = true) === sf
	@test length(sf.plot.data) == 8
	@test all(t.fields[:xaxis] == "x2" && t.fields[:yaxis] == "y2" for t in sf.plot.data)
	# The band's default colour is the one plotly.js gives trace 1 of the figure.
	@test sf.plot.data[1].fields[:fillcolor] ==
		PlotlySupply._rgba(PlotlySupply._default_trace_color(sf, 1), 0.25)
	@test_throws ArgumentError plot_ecdf!(sf, [1.0, 2.0]; row = 1, col = 2, show = true)
	@test length(sf.plot.data) == 8
end

@testset "sci lines: docstrings" begin
	for f in (plot_band, plot_band!, plot_segments, plot_segments!, plot_vlines,
		plot_vlines!, plot_hlines, plot_hlines!, plot_ecdf, plot_ecdf!, plot_kde,
		plot_kde!, plot_complex, plot_complex!)
		doc = string(Base.Docs.doc(f))
		@test occursin(string(nameof(f)), doc)
	end
	@test occursin("where", string(@doc plot_band))
	@test occursin("silverman", string(@doc plot_kde))
	@test occursin("unit_circle", string(@doc plot_complex))
end
