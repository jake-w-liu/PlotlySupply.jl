using Test, PlotlySupply

# These tests assert on the package's own defaults: an earlier file of the full run
# may leave a publication style active (`set_default_style!()` without an
# argument keeps the active style), which changes colorbar fonts and line widths.
set_default_style!(:default)

const _M2 = PlotlySupply
const _M2_PB = PlotlySupply.PlotlyBase

function _m2_throws(f, needle::AbstractString)
	err = try
		f()
		nothing
	catch caught
		caught
	end
	err isa ArgumentError || return false
	occursin(needle, err.msg) || (@info "message mismatch" needle err.msg; return false)
	return true
end

_m2_json(x) = _M2_PB.JSON.json(x)
_m2_get(m, key) = _M2._cmn_mapping_get(m, key)
_m2_type(t) = String(get(t.fields, :type, "scatter"))
_m2_fills(fig) = [t for t in _M2._plot_data(fig) if get(t.fields, :fill, "") == "toself"]
_m2_carriers(fig) = [
	t for t in _M2._plot_data(fig)
	if _m2_type(t) == "scatter" && get(t.fields, :x, nothing) == Any[nothing]
]
_m2_stops(name) = _M2._colorscale_stops(name; who = "test")

# Rings of a `_GAP`-separated fill trace, closing vertex dropped.
function _m2_rings(trace)
	xs = trace.fields[:x]
	ys = trace.fields[:y]
	rings = Tuple{Vector{Float64}, Vector{Float64}}[]
	start = 1
	for k in 1:(length(xs) + 1)
		if k > length(xs) || xs[k] === nothing
			rx = Float64[xs[i] for i in start:(k - 1)]
			ry = Float64[ys[i] for i in start:(k - 1)]
			@assert rx[1] == rx[end] && ry[1] == ry[end] "ring not closed"
			push!(rings, (rx[1:(end - 1)], ry[1:(end - 1)]))
			start = k + 1
		end
	end
	return rings
end

_m2_nrings(fig) = sum((length(_m2_rings(t)) for t in _m2_fills(fig)); init = 0)

# Fill colour of the ring whose vertex set equals (rx, ry).
function _m2_ring_color(fig, rx, ry)
	for t in _m2_fills(fig), (x, y) in _m2_rings(t)
		(sort(collect(zip(x, y))) == sort(collect(zip(rx, ry)))) && return t.fields[:fillcolor]
	end
	return nothing
end

# Expected colour of a value under uniform bins (matplotlib-style quantisation).
function _m2_expected(stops, v, lo, hi, n)
	t = clamp((v - lo) / (hi - lo), 0.0, 1.0)
	b = min(floor(Int, t * n), n - 1) + 1
	return _M2._sample_colorscale(stops, (b - 0.5) / n)
end

struct _M2RendererState
	scripts::Vector{String}
end

function _m2_syncplot(p)
	state = _M2RendererState(String[])
	open = Ref(true)
	backend = (
		isopen = window -> open[],
		close = window -> (open[] = false; nothing),
		run = (window, script) -> (push!(state.scripts, String(script)); "ok"),
	)
	sp = SyncPlot(p, nothing, :mesh2d_window, "mesh2d-div", _M2._SyncPlotResources(nothing, backend))
	return sp, state
end

# Meshes used throughout.
const _M2_QX = [0.0, 1.0, 2.0, 0.0, 1.0, 2.0]
const _M2_QY = [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
const _M2_QUADS = [1 2 5 4; 2 3 6 5]
const _M2_TX = [0.0, 1.0, 0.0, 1.0, 0.5]
const _M2_TY = [0.0, 0.0, 1.0, 1.0, 0.5]
const _M2_TRI = [1 2 5; 2 4 5; 4 3 5; 3 1 5]
const _M2_SQX = [0.0, 1.0, 0.0, 1.0]
const _M2_SQY = [0.0, 0.0, 1.0, 1.0]
const _M2_SQTRI = [1 2 4; 1 4 3]

@testset "sci mesh2d" begin
	@testset "exports and registry" begin
		for name in (
			:plot_polygons, :plot_polygons!, :plot_pcolormesh, :plot_pcolormesh!,
			:plot_tripcolor, :plot_tripcolor!, :plot_triplot, :plot_triplot!,
			:plot_tricontour, :plot_tricontour!,
		)
			@test name in names(PlotlySupply)
		end
		@test _M2._SCI_MESH2D_MUTATORS ==
			(:plot_polygons!, :plot_pcolormesh!, :plot_tripcolor!, :plot_triplot!, :plot_tricontour!)
		for name in _M2._SCI_MESH2D_MUTATORS
			@test name in _M2._TRANSACTIONAL_HIGH_LEVEL_PLOT_MUTATORS
		end
	end

	@testset "docstring examples run" begin
		# Fenced ```julia blocks of the raw docstrings (the parsed Markdown also
		# tags the indented signature lines as julia code).
		meta = Base.Docs.meta(PlotlySupply)
		for f in (
			plot_polygons, plot_polygons!, plot_pcolormesh, plot_pcolormesh!,
			plot_tripcolor, plot_tripcolor!, plot_triplot, plot_triplot!,
			plot_tricontour, plot_tricontour!,
		)
			multidoc = meta[Base.Docs.Binding(PlotlySupply, nameof(f))]
			raw = join((join(string.(d.text)) for d in values(multidoc.docs)), "\n")
			blocks = [m.captures[1] for m in eachmatch(r"```julia\n(.*?)```"s, raw)]
			@test !isempty(blocks)
			for code in blocks
				sandbox = Module()
				Core.eval(sandbox, :(using PlotlySupply))
				@test (include_string(sandbox, code); true)
			end
		end
	end

	@testset "plot_polygons: node form, colours, carrier" begin
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.2, 0.9]; colorbar_title = "T")
		@test fig isa Plot
		fills = _m2_fills(fig)
		carriers = _m2_carriers(fig)
		@test length(fills) == 2
		@test length(carriers) == 1
		@test length(fig.data) == length(fills) + 1          # non-empty bins + carrier
		stops = _m2_stops("Viridis")
		@test _m2_ring_color(fig, [0.0, 1.0, 1.0, 0.0], [0.0, 0.0, 1.0, 1.0]) == _M2._sample_colorscale(stops, 0.5 / 256)
		@test _m2_ring_color(fig, [1.0, 2.0, 2.0, 1.0], [0.0, 0.0, 1.0, 1.0]) == _M2._sample_colorscale(stops, 255.5 / 256)
		marker = carriers[1].fields[:marker]
		@test _m2_get(marker, :cmin) == 0.2
		@test _m2_get(marker, :cmax) == 0.9
		@test _m2_get(marker, :showscale) === true
		@test _m2_get(marker, :colorscale) == stops
		@test _m2_get(_m2_get(_m2_get(marker, :colorbar), :title), :text) == "T"
		t = fills[1]
		@test t.fields[:mode] == "lines"
		@test t.fields[:hoverinfo] == "skip"
		@test t.fields[:showlegend] === false
		# edgewidth = 0: a 0.5 px stroke in the fill colour closes AA seams.
		@test _m2_get(t.fields[:line], :width) == 0.5
		@test _m2_get(t.fields[:line], :color) == t.fields[:fillcolor]
		@test _m2_get(t.fields[:line], :simplify) === false
		@test !haskey(t.fields, :opacity)
		@test !haskey(t.fields, :fillpattern)
		# Equal aspect by default; template and figure defaults applied.
		@test _m2_get(fig.layout.fields[:yaxis], :scaleanchor) == "x"
		@test _m2_get(fig.layout.fields[:yaxis], :constrain) == "domain"
		@test haskey(fig.layout.fields, :template)
	end

	@testset "plot_polygons: numeric bin colours equal the sampled colorscale" begin
		n = 7
		xs = collect(0.0:n)
		x = vcat(xs, xs)
		y = vcat(zeros(n + 1), ones(n + 1))
		cells = [[i, i + 1, n + 2 + i, n + 1 + i] for i in 1:n]
		vals = [0.03, 0.5, 0.97, 0.12, 0.51, 0.77, 0.33]
		for (cs, nc) in (("Viridis", 256), ("RdBu_r", 16), ("magma", 3))
			fig = plot_polygons(x, y, cells, vals; colorscale = cs, ncolors = nc)
			stops = _m2_stops(cs)
			lo, hi = extrema(vals)
			for (i, v) in enumerate(vals)
				@test _m2_ring_color(fig, [i - 1.0, i, i, i - 1.0], [0.0, 0.0, 1.0, 1.0]) == _m2_expected(stops, v, lo, hi, nc)
			end
			bins = unique(min(floor(Int, (v - lo) / (hi - lo) * nc), nc - 1) for v in vals)
			@test length(_m2_fills(fig)) == length(bins)
			@test length(fig.data) == length(bins) + 1
		end
	end

	@testset "plot_polygons: connectivity forms and validation" begin
		# vector of index vectors, mixed polygon sizes
		x = [0.0, 1.0, 0.0, 2.0, 3.0, 3.0, 2.0, 4.0, 5.0, 5.5, 4.5, 4.0]
		y = [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.5, 1.0]
		fig = plot_polygons(x, y, [[1, 2, 3], (4, 5, 6, 7), [8, 9, 10, 11, 12]], [1.0, 2.0, 3.0])
		sizes = sort([length(r[1]) for t in _m2_fills(fig) for r in _m2_rings(t)])
		@test sizes == [3, 4, 5]
		# integral floats accepted as indices
		fig = plot_polygons(_M2_QX, _M2_QY, Float64.(_M2_QUADS), [1.0, 2.0])
		@test _m2_nrings(fig) == 2
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, [1 2 7 4], [1.0]), "refers to node 7, outside 1:6")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, [0 1 4 3], [1.0]), "Indices are 1-based")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, [1.5 2 5], [1.0]), "integer node indices")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, Any[true 2 5], [1.0]), "integer node indices")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, [1 2], [1.0]), "at least 3 nodes")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, [[1, 2]], [1.0]), "every cell needs at least 3")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, [1, 2, 3], [1.0]), "must be a vector of node indices")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, "cells", [1.0]), "integer matrix or a vector of index vectors")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY[1:5], _M2_QUADS), "`x` has 6 nodes but `y` has 5")
		@test _m2_throws(() -> plot_polygons([0.0, NaN, 1.0], [0.0, 1.0, 0.0], [1 2 3]), "entry 2 is NaN")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY), "need connectivity")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0]), "`values` has 1 entries for 2 cells")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, "a"]), "entry 2 is \"a\"")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, 1.0), "`values` must be a vector")
		# explicit polygons
		@test _m2_throws(() -> plot_polygons([[0.0, 1.0, 0.0]], [[0.0, 0.0]]), "polygon 1 has 3 x and 2 y")
		@test _m2_throws(() -> plot_polygons([[0.0, 1.0]], [[0.0, 0.0]]), "a polygon needs at least 3")
		@test _m2_throws(() -> plot_polygons([[0.0, 1.0, 0.0]], [[0.0, 0.0, 1.0], [0.0, 1.0, 0.0]]), "`px` has 1 polygons but `py` has 2")
		@test _m2_throws(() -> plot_polygons([[0.0, Inf, 0.0]], [[0.0, 0.0, 1.0]]), "non-finite or non-real vertex")
		@test _m2_throws(() -> plot_polygons([[0.0, 1.0, 0.0]], [[0.0, 0.0, 1.0]], [1.0], [2.0]), "fourth positional argument")
		@test _m2_throws(() -> plot_polygons(Any[1.0, [1.0]], [0.0, 1.0], [1 2 1]), "got a mixture")
		# empty inputs: nothing drawn, still a valid figure
		@test isempty(plot_polygons(Vector{Float64}[], Vector{Float64}[]).data)
		@test isempty(plot_polygons(Float64[], Float64[], Vector{Int}[], Float64[]).data)
	end

	@testset "plot_polygons: uniform colour, legend, keyword rules" begin
		fig = plot_polygons([[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]])
		@test length(fig.data) == 1
		@test fig.data[1].fields[:fillcolor] == _M2._default_trace_color(fig, 1)
		@test fig.data[1].fields[:showlegend] === false
		fig = plot_polygons([[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]]; color = :red, legend = "mesh \$\\alpha\$")
		@test fig.data[1].fields[:fillcolor] == _M2._color_hex("red"; who = "test")
		@test fig.data[1].fields[:showlegend] === true
		@test fig.data[1].fields[:name] == _M2._label("mesh \$\\alpha\$")
		# a legend entry is kept even with no polygons
		@test length(plot_polygons(Vector{Float64}[], Vector{Float64}[]; legend = "empty").data) == 1
		# second uniform mesh takes the next colour of the cycle
		plot_polygons!(fig, [[2.0, 3.0, 2.5]], [[0.0, 0.0, 1.0]])
		@test fig.data[2].fields[:fillcolor] == _M2._default_trace_color(fig, 2)
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, 2.0]; legend = "x"), "`legend` names a uniform-colour mesh")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, 2.0]; color = "red"), "`color` is the fill of a uniform-colour mesh")
		for (kw, value) in (
			(:crange, (0, 1)), (:cmid, 0), (:levels, [0, 1]), (:colornorm, :log), (:showscale, true),
			(:colorbar_title, "t"), (:colorbar_ticks, [1]), (:colorbar_ticklabels, ["a"]), (:coloraxis, :shared),
		)
			@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; (kw => value,)...), "`$(kw)` maps cell values to colours")
		end
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; color = "notacolour"), "color")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; color = 3), "`color` must be a colour string")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; legend = 1), "`legend` must be a string")
	end

	@testset "plot_polygons: NaN / missing cells and outlines" begin
		x = collect(0.0:4.0)
		xx = vcat(x, x)
		yy = vcat(zeros(5), ones(5))
		cells = [[i, i + 1, 6 + i, 5 + i] for i in 1:4]
		fig = plot_polygons(xx, yy, cells, [1.0, NaN, missing, 3.0])
		@test _m2_nrings(fig) == 2
		@test _m2_ring_color(fig, [1.0, 2.0, 2.0, 1.0], [0.0, 0.0, 1.0, 1.0]) === nothing
		marker = _m2_carriers(fig)[1].fields[:marker]
		@test (_m2_get(marker, :cmin), _m2_get(marker, :cmax)) == (1.0, 3.0)
		fig = plot_polygons(xx, yy, cells, [1.0, Inf, -Inf, 3.0]; edgecolor = "black", edgewidth = 1)
		outline = [t for t in fig.data if _m2_type(t) == "scatter" && !haskey(t.fields, :fill) && get(t.fields, :mode, "") == "lines"]
		@test length(outline) == 1
		@test count(isnothing,outline[1].fields[:x]) == 1        # two rings
		@test _m2_get(outline[1].fields[:line], :color) == _M2._color_hex("black"; who = "test")
		# all values missing: no fills, no carrier
		fig = plot_polygons(xx, yy, cells, [missing, NaN, NaN, missing])
		@test isempty(fig.data)
	end

	@testset "plot_polygons: colour norms" begin
		stops = _m2_stops("Viridis")
		# explicit crange: out-of-range values take the end colours
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [-5.0, 50.0]; crange = (0, 10))
		marker = _m2_carriers(fig)[1].fields[:marker]
		@test (_m2_get(marker, :cmin), _m2_get(marker, :cmax)) == (0.0, 10.0)
		@test _m2_ring_color(fig, [0.0, 1.0, 1.0, 0.0], [0.0, 0.0, 1.0, 1.0]) == _M2._sample_colorscale(stops, 0.5 / 256)
		@test _m2_ring_color(fig, [1.0, 2.0, 2.0, 1.0], [0.0, 0.0, 1.0, 1.0]) == _M2._sample_colorscale(stops, 255.5 / 256)
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, 2.0]; crange = (2, 1)), "lower bound must be less")
		# automatic range symmetric about cmid (plotly zmid)
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [-1.0, 3.0]; cmid = 0)
		marker = _m2_carriers(fig)[1].fields[:marker]
		@test (_m2_get(marker, :cmin), _m2_get(marker, :cmax)) == (-3.0, 3.0)
		# explicit crange + cmid: two-slope colormap, cmid colour = colormap centre
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [-1.0, 0.0]; crange = (-1, 3), cmid = 0, ncolors = 1024, colorscale = "RdBu")
		@test _m2_ring_color(fig, [1.0, 2.0, 2.0, 1.0], [0.0, 0.0, 1.0, 1.0]) ==
			_M2._sample_colorscale(_m2_stops("RdBu"), 0.5 + 0.5 / 1024)
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, 2.0]; cmid = 5, crange = (0, 1)), "must lie strictly inside")
		# a constant field gets ±0.5 like plotly
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [2.0, 2.0])
		marker = _m2_carriers(fig)[1].fields[:marker]
		@test (_m2_get(marker, :cmin), _m2_get(marker, :cmax)) == (1.5, 2.5)
		@test length(_m2_fills(fig)) == 1
		# log norm: colour units are log10, ticks on decades
		x = collect(0.0:3.0)
		cells = [[i, i + 1, 5 + i, 4 + i] for i in 1:3]
		fig = plot_polygons(vcat(x, x), vcat(zeros(4), ones(4)), cells, [1.0, 10.0, 100.0]; colornorm = :log, ncolors = 2)
		marker = _m2_carriers(fig)[1].fields[:marker]
		@test (_m2_get(marker, :cmin), _m2_get(marker, :cmax)) == (0.0, 2.0)
		bar = _m2_get(marker, :colorbar)
		@test _m2_get(bar, :tickvals) == [0.0, 1.0, 2.0]
		@test _m2_get(bar, :ticktext) == ["10<sup>0</sup>", "10<sup>1</sup>", "10<sup>2</sup>"]
		@test _m2_ring_color(fig, [1.0, 2.0, 2.0, 1.0], [0.0, 0.0, 1.0, 1.0]) == _M2._sample_colorscale(stops, 0.75)
		fig = plot_polygons(vcat(x, x), vcat(zeros(4), ones(4)), cells, [-1.0, 10.0, 100.0]; colornorm = :log)
		@test _m2_nrings(fig) == 2                                   # <= 0 is not drawn
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, 2.0]; colornorm = :sqrt), "`colornorm` must be :linear or :log")
		# discrete levels (BoundaryNorm): one trace per band, stepped colour bar
		x = collect(0.0:4.0)
		cells = [[i, i + 1, 6 + i, 5 + i] for i in 1:4]
		fig = plot_polygons(vcat(x, x), vcat(zeros(5), ones(5)), cells, [0.5, 1.5, 3.0, 5.0]; levels = [0, 1, 2, 4])
		@test length(_m2_fills(fig)) == 3
		marker = _m2_carriers(fig)[1].fields[:marker]
		@test (_m2_get(marker, :cmin), _m2_get(marker, :cmax)) == (0.0, 4.0)
		scale = _m2_get(marker, :colorscale)
		@test length(scale) == 6
		bands = [_M2._sample_colorscale(stops, (i - 0.5) / 3) for i in 1:3]
		@test [scale[1][2], scale[3][2], scale[5][2]] == bands
		@test _m2_ring_color(fig, [3.0, 4.0, 4.0, 3.0], [0.0, 0.0, 1.0, 1.0]) == bands[3]   # 5.0 > top: last band
		@test _m2_ring_color(fig, [2.0, 3.0, 3.0, 2.0], [0.0, 0.0, 1.0, 1.0]) == bands[3]
		@test _m2_get(_m2_get(marker, :colorbar), :tickvals) == [0.0, 1.0, 2.0, 4.0]
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, 2.0]; levels = [0, 2], crange = (0, 2)), "do not also pass `crange`")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, 2.0]; levels = [2, 1]), "strictly increasing")
		# ncolors
		x = collect(0.0:4.0)
		fig = plot_polygons(vcat(x, x), vcat(zeros(5), ones(5)), cells, [0.0, 0.4, 0.6, 1.0]; ncolors = 2)
		@test length(_m2_fills(fig)) == 2
		@test [length(_m2_rings(t)) for t in _m2_fills(fig)] == [2, 2]
		for bad in (0, 1025, 2.5, true)
			@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [1.0, 2.0]; ncolors = bad), "`ncolors` must be an integer in 1:1024")
		end
		# template colorscale and invalid names
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; colorscale = "")
		@test _m2_get(_m2_carriers(fig)[1].fields[:marker], :colorscale) == _M2._template_colorscale(fig)
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; colorscale = "nosuchmap"), "nosuchmap")
	end

	@testset "plot_polygons: colour bar keywords and coloraxis" begin
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; showscale = false,
			colorbar_ticks = [0, 0.5, 1], colorbar_ticklabels = ["lo", "\$\\mu\$", "hi"])
		marker = _m2_carriers(fig)[1].fields[:marker]
		@test _m2_get(marker, :showscale) === false
		bar = _m2_get(marker, :colorbar)
		@test _m2_get(bar, :tickvals) == [0.0, 0.5, 1.0]
		# v7 tm-cbar-math-ticklabels-hang: colorbar tick-label math as Unicode
		@test _m2_get(bar, :ticktext) == ["lo", "μ", "hi"]
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; colorbar_ticklabels = ["a"]), "need `ticks`")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; showscale = 1), "`showscale` must be true, false or nothing")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; colorbar_title = 1), "`colorbar_title` must be a string")
		# shared colour axis: limits written to layout, reused by later calls
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; coloraxis = :shared, colorbar_title = "c", colorscale = "magma")
		axis = fig.layout.fields[:coloraxis]
		@test (_m2_get(axis, :cmin), _m2_get(axis, :cmax)) == (0.0, 1.0)
		@test _m2_get(axis, :colorscale) == _m2_stops("magma")
		@test _m2_get(_m2_get(_m2_get(axis, :colorbar), :title), :text) == "c"
		@test !haskey(_M2._symbol_dict(axis), :showscale)
		marker = _m2_carriers(fig)[1].fields[:marker]
		@test _m2_get(marker, :coloraxis) == "coloraxis"
		@test _m2_get(marker, :colorscale) === nothing
		plot_polygons!(fig, _M2_QX .+ 3, _M2_QY, _M2_QUADS, [10.0, 0.5]; coloraxis = :shared, colorscale = "magma", equalar = false)
		axis = fig.layout.fields[:coloraxis]
		@test (_m2_get(axis, :cmin), _m2_get(axis, :cmax)) == (0.0, 1.0)
		top = _M2._sample_colorscale(_m2_stops("magma"), 255.5 / 256)
		@test _m2_ring_color(fig, [3.0, 4.0, 4.0, 3.0], [0.0, 0.0, 1.0, 1.0]) == top
		@test _m2_ring_color(fig, [4.0, 5.0, 5.0, 4.0], [0.0, 0.0, 1.0, 1.0]) == _m2_expected(_m2_stops("magma"), 0.5, 0.0, 1.0, 256)
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; coloraxis = "coloraxis3", showscale = false)
		@test _m2_get(fig.layout.fields[:coloraxis3], :showscale) === false
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; coloraxis = "axis2"), "`coloraxis` must be :shared")
	end

	@testset "plot_polygons: style keywords" begin
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; edgecolor = "black", edgewidth = 2, opacity = 0.4, hatch = "/")
		for t in _m2_fills(fig)
			@test _m2_get(t.fields[:line], :color) == _M2._color_hex("black"; who = "test")
			@test _m2_get(t.fields[:line], :width) == 2.0
			@test t.fields[:opacity] == 0.4
			@test _m2_get(t.fields[:fillpattern], :shape) == "/"
		end
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; edgecolor = "face", edgewidth = 1)
		@test all(_m2_get(t.fields[:line], :color) == t.fields[:fillcolor] for t in _m2_fills(fig))
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; edgecolor = "none")
		@test all(_m2_get(t.fields[:line], :color) == t.fields[:fillcolor] for t in _m2_fills(fig))
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; edgewidth = -1), "`edgewidth` must be a finite number >= 0")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; opacity = 1.5), "`opacity` must be a number in [0, 1]")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; hatch = 1), "`hatch` must be a string")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; hatch = "?"), "hatch")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; edgecolor = "nope"), "edgecolor")
		# hover: invisible centroid markers carrying the value
		fig = plot_polygons(_M2_QX, _M2_QY, _M2_QUADS, [0.25, missing]; hover = true)
		h = fig.data[end]
		@test h.fields[:mode] == "markers"
		@test h.fields[:x] == [0.5] && h.fields[:y] == [0.5]
		@test h.fields[:customdata] == [0.25]
		@test _m2_get(h.fields[:marker], :opacity) == 0
		@test occursin("%{customdata", h.fields[:hovertemplate])
		fig = plot_polygons([[0.0, 3.0, 0.0]], [[0.0, 0.0, 3.0]]; hover = true)
		@test fig.data[end].fields[:customdata] == [1]
		@test fig.data[end].fields[:x] ≈ [1.0] && fig.data[end].fields[:y] ≈ [1.0]   # area centroid
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; hover = 1), "`hover` must be true or false")
	end

	@testset "plot_polygons: figure keywords" begin
		fig = plot_polygons(_M2_QX .+ 1, _M2_QY .+ 1, _M2_QUADS, [0.0, 1.0];
			title = "Mesh", xlabel = "x", ylabel = "y", xrange = (1, 3), yrange = [1, 2],
			xscale = "log", width = 640, height = 480, fontsize = 14, grid = false, equalar = false)
		L = fig.layout.fields
		@test _m2_get(L[:title], :text) == _M2._label("Mesh")
		@test _m2_get(_m2_get(L[:xaxis], :title), :text) == _M2._label("x")
		@test _m2_get(L[:xaxis], :type) == "log"
		@test _m2_get(L[:xaxis], :range) ≈ [0.0, log10(3)]
		@test _m2_get(L[:yaxis], :range) == [1, 2]
		@test L[:width] == 640 && L[:height] == 480
		@test _m2_get(L[:font], :size) == 14
		@test _m2_get(L[:xaxis], :showgrid) === false
		@test _m2_get(L[:yaxis], :scaleanchor) === nothing
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; xscale = "log"), "x axis is logarithmic")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; yscale = :log), "`yscale` must be a string")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; xscale = "ln"), "`xscale` must be one of")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; grid = :z), "`grid` must be")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; xrange = (0, 1), xscale = "log"), "must be positive")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; equalar = 1), "`equalar` must be true or false")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; title = 1), "`title` must be a string")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; width = -1), "width")
		@test _m2_throws(() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; bogus = 1), "unsupported keyword argument(s) `bogus`")
		for ctor in (
			() -> plot_polygons(_M2_QX, _M2_QY, _M2_QUADS; show = 1),
			() -> plot_pcolormesh([0.0, 1.0], [0.0, 1.0], ones(1, 1); show = "yes"),
			() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; show = nothing),
			() -> plot_triplot(_M2_TX, _M2_TY, _M2_TRI; show = 0),
			() -> plot_tricontour(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; show = :no),
		)
			@test _m2_throws(ctor, "`show` must be true or false")
		end
	end

	@testset "mutators: Plot transactions, show, unknown keywords" begin
		fig = plot_polygons([[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]]; equalar = false)
		before = _m2_json(fig)
		@test _m2_throws(() -> plot_polygons!(fig, [[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]]; show = true), "mutators do not take `show`")
		@test _m2_throws(() -> plot_polygons!(fig, [[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]]; row = 1, col = 1), "`row` selects a SubplotFigure cell")
		# Z31: `secondary_y` is a Plot keyword now; it must be a Bool.
		@test _m2_throws(() -> plot_polygons!(fig, [[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]]; secondary_y = :yes), "plot_polygons!: `secondary_y` must be true or false")
		@test _m2_throws(() -> plot_polygons!(fig, [[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]], [1.0]; crange = (1, 0)), "lower bound")
		@test _m2_throws(() -> plot_pcolormesh!(fig, [0.0 1.0; 0.0 1.0], [0.0 0.0; 1.0 1.0], ones(1, 1); show = false), "mutators do not take `show`")
		@test _m2_throws(() -> plot_tripcolor!(fig, _M2_TX, _M2_TY, _M2_TRI, _M2_TX; show = true), "mutators do not take `show`")
		@test _m2_throws(() -> plot_triplot!(fig, _M2_TX, _M2_TY, _M2_TRI; show = true), "mutators do not take `show`")
		@test _m2_throws(() -> plot_tricontour!(fig, _M2_TX, _M2_TY, _M2_TRI, _M2_TX; show = true), "mutators do not take `show`")
		@test _m2_json(fig) == before
		@test plot_polygons!(fig, [[2.0, 3.0, 2.5]], [[0.0, 0.0, 1.0]]; title = "T2", grid = false) === nothing
		@test length(fig.data) == 2
		@test _m2_get(fig.layout.fields[:title], :text) == _M2._label("T2")
		@test _m2_get(fig.layout.fields[:xaxis], :showgrid) === false
		@test _m2_get(fig.layout.fields[:yaxis], :scaleanchor) == "x"     # mutator equalar defaults to true
		fig2 = plot_polygons([[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]]; equalar = false)
		plot_polygons!(fig2, [[2.0, 3.0, 2.5]], [[0.0, 0.0, 1.0]]; equalar = false)
		@test _m2_get(fig2.layout.fields[:yaxis], :scaleanchor) === nothing
		# a mesh cannot go onto a 3-D figure
		p3 = Plot(_M2_PB.scatter3d(x = [1], y = [1], z = [1]))
		@test _m2_throws(() -> plot_polygons!(p3, [[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]]), "mesh plots draw on Cartesian x/y axes")
	end

	@testset "mutators: SyncPlot renderer transactions" begin
		p = plot_polygons([[0.0, 1.0, 0.5]], [[0.0, 0.0, 1.0]])
		sp, state = _m2_syncplot(p)
		plot_tripcolor!(sp, _M2_TX, _M2_TY, _M2_TRI, _M2_TX .+ _M2_TY; shading = :gouraud)
		@test length(sp.plot.data) == 2                         # + one heatmap (it draws its own colour bar)
		@test _m2_type(sp.plot.data[2]) == "heatmap"
		@test !isempty(state.scripts)
		n = length(state.scripts)
		before = _m2_json(sp.plot)
		@test _m2_throws(() -> plot_triplot!(sp, _M2_TX, _M2_TY, _M2_TRI; dash = "zigzag"), "unknown `dash`")
		@test _m2_throws(() -> plot_triplot!(sp, _M2_TX, _M2_TY, _M2_TRI; show = true), "mutators do not take `show`")
		@test length(state.scripts) == n
		@test _m2_json(sp.plot) == before
		plot_tricontour!(sp, _M2_TX, _M2_TY, _M2_TRI, _M2_TX; levels = [0.5])
		@test length(state.scripts) > n
		@test length(sp.plot.data) == 3
	end

	@testset "SubplotFigure cells" begin
		sf = subplots(1, 2; sync = false)
		@test plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS, [0.0, 1.0]; row = 1, col = 2) === sf
		refs = [(get(t.fields, :xaxis, "x"), get(t.fields, :yaxis, "y")) for t in sf.plot.data]
		@test all(==(("x2", "y2")), refs)
		@test _m2_get(sf.plot.layout.fields[:yaxis2], :scaleanchor) == "x2"
		@test _m2_get(sf.plot.layout.fields[:yaxis2], :constrain) == "domain"
		@test _m2_get(sf.plot.layout.fields[:yaxis], :scaleanchor) === nothing
		@test (sf.current_row, sf.current_col) == (1, 2)
		# the uniform colour continues the cell's colour cycle
		plot_polygons!(sf, [[5.0, 6.0, 5.5]], [[0.0, 0.0, 1.0]]; row = 1, col = 1)
		plot_polygons!(sf, [[7.0, 8.0, 7.5]], [[0.0, 0.0, 1.0]]; row = 1, col = 1)
		cell1 = [t for t in sf.plot.data if get(t.fields, :xaxis, "x") == "x"]
		@test [t.fields[:fillcolor] for t in cell1] == [_M2._default_trace_color(sf, 1), _M2._default_trace_color(sf, 2)]
		# each function reaches a SubplotFigure cell
		@test plot_pcolormesh!(sf, [0.0, 1.0, 2.0], [0.0, 1.0], [1.0 2.0]'; row = 1, col = 1) === sf
		@test _m2_type(sf.plot.data[end]) == "heatmap" && sf.plot.data[end].fields[:xaxis] == "x"
		@test plot_tripcolor!(sf, _M2_TX, _M2_TY, _M2_TRI, _M2_TX; row = 1, col = 2) === sf
		@test plot_triplot!(sf, _M2_TX, _M2_TY, _M2_TRI; row = 1, col = 2, color = "red") === sf
		@test sf.plot.data[end].fields[:xaxis] == "x2"
		@test plot_tricontour!(sf, _M2_TX, _M2_TY, _M2_TRI, _M2_TX; row = 1, col = 2, levels = [0.5]) === sf
		@test sf.plot.data[end].fields[:yaxis] == "y2"
		# errors: show, bad cell, bad keyword; the figure is unchanged
		before = _m2_json(sf.plot)
		@test_throws ArgumentError plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS; show = true)
		@test _m2_throws(() -> plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS; row = 3, col = 1), "`row` must be in 1:1")
		@test _m2_throws(() -> plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS; row = 1), "must be given together")
		@test _m2_throws(() -> plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS; row = 1.0, col = 1), "`row` must be an integer")
		@test _m2_throws(() -> plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS; secondary_y = 1), "`secondary_y` must be true or false")
		@test _m2_throws(() -> plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS; nope = 1, row = 1, col = 1), "unsupported keyword argument(s) `nope`")
		@test _m2_throws(() -> plot_tripcolor!(sf, _M2_TX, _M2_TY, _M2_TRI, _M2_TX; secondary_y = true), "secondary")
		@test _m2_json(sf.plot) == before
		# a log axis of the target cell is honoured (and validated)
		relayout!(sf.plot; xaxis2 = attr(type = "log"))
		@test _m2_throws(() -> plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS; row = 1, col = 2), "x axis is logarithmic")
		plot_polygons!(sf, _M2_QX .+ 1, _M2_QY, _M2_QUADS; row = 1, col = 2, equalar = false)
		@test _m2_get(sf.plot.layout.fields[:xaxis2], :type) == "log"
	end

	@testset "SubplotFigure: secondary y, colour axes, SyncPlot-backed" begin
		sf = subplots(1, 2; sync = false, specs = [Spec(secondary_y = true) Spec()])
		plot_triplot!(sf, _M2_TX, _M2_TY, _M2_TRI; row = 1, col = 1, secondary_y = true)
		t = _M2._cell_target(sf; row = 1, col = 1, secondary_y = true)
		@test sf.plot.data[end].fields[:yaxis] == t.yref
		@test _m2_get(sf.plot.layout.fields[t.ykey], :scaleanchor) == "x"
		@test _m2_get(sf.plot.layout.fields[t.ykey], :constrain) == "range"     # overlaying twin
		# numbered colour axis: written in the same transaction
		plot_polygons!(sf, _M2_QX, _M2_QY, _M2_QUADS, [0.0, 4.0]; row = 1, col = 2, coloraxis = "coloraxis2", colorbar_title = "c2")
		axis = sf.plot.layout.fields[:coloraxis2]
		@test (_m2_get(axis, :cmin), _m2_get(axis, :cmax)) == (0.0, 4.0)
		@test _m2_get(_m2_get(_m2_get(axis, :colorbar), :title), :text) == "c2"
		@test _m2_get(_m2_carriers(sf.plot)[end].fields[:marker], :coloraxis) == "coloraxis2"
		# a later call on the other cell shares the stored limits
		plot_tripcolor!(sf, _M2_TX, _M2_TY, _M2_TRI, [0.0, 8.0, 8.0, 8.0]; row = 1, col = 1, coloraxis = "coloraxis2")
		axis = sf.plot.layout.fields[:coloraxis2]
		@test (_m2_get(axis, :cmin), _m2_get(axis, :cmax)) == (0.0, 4.0)
		# shared first colour axis through the delegate
		plot_pcolormesh!(sf, [0.0, 1.0], [0.0, 1.0], fill(3.0, 1, 1); row = 1, col = 1, coloraxis = :shared, crange = (0, 6))
		@test _m2_get(sf.plot.layout.fields[:coloraxis], :cmax) == 6.0
		@test sf.plot.data[end].fields[:coloraxis] == "coloraxis"
		# SyncPlot-backed SubplotFigure: renderer transaction, rollback on error
		base = subplots(1, 2; sync = false)
		sp, state = _m2_syncplot(base.plot)
		sfs = SubplotFigure(sp, 1, 2, 1, 1, false, :topright, (0.02, 0.03), "white", "black", 1.0)
		plot_tripcolor!(sfs, _M2_TX, _M2_TY, _M2_TRI, _M2_TX; row = 1, col = 2, coloraxis = "coloraxis4")
		@test !isempty(state.scripts)
		@test haskey(sp.plot.layout.fields, :coloraxis4)
		@test all(get(t.fields, :xaxis, "x") == "x2" for t in sp.plot.data)
		n = length(state.scripts)
		before = _m2_json(sp.plot)
		@test _m2_throws(() -> plot_tripcolor!(sfs, _M2_TX, _M2_TY, _M2_TRI, _M2_TX; row = 1, col = 1, coloraxis = "coloraxis5", resolution = 1, shading = :gouraud), "`resolution` must be an integer")
		@test length(state.scripts) == n
		@test _m2_json(sp.plot) == before
		@test !haskey(sp.plot.layout.fields, :coloraxis5)
	end

	@testset "plot_pcolormesh" begin
		# (3, 4) node grid with (2, 3) cell values: 6 polygons in C's order
		X = [i + 0.1j for i in 0:2, j in 0:3]
		Y = [j + 0.05i for i in 0:2, j in 0:3]
		C = reshape(collect(1.0:6.0), 2, 3)
		fig = plot_pcolormesh(X, Y, C; hover = true)
		@test _m2_nrings(fig) == 6
		@test fig.data[end].fields[:customdata] == collect(1.0:6.0)
		# cell (i, j) corners (i,j), (i+1,j), (i+1,j+1), (i,j+1)
		@test _m2_ring_color(fig, [X[2, 2], X[3, 2], X[3, 3], X[2, 3]], [Y[2, 2], Y[3, 2], Y[3, 3], Y[2, 3]]) ==
			_m2_expected(_m2_stops("Viridis"), C[2, 2], 1.0, 6.0, 256)
		# node values: each cell is the mean of its corners
		N = [10.0i + j for i in 1:3, j in 1:4]
		fig = plot_pcolormesh(X, Y, N; hover = true)
		@test fig.data[end].fields[:customdata] ≈ vec([(N[i, j] + N[i + 1, j] + N[i + 1, j + 1] + N[i, j + 1]) / 4 for i in 1:2, j in 1:3])
		N[1, 1] = NaN
		@test _m2_nrings(plot_pcolormesh(X, Y, N)) == 5
		@test _m2_throws(() -> plot_pcolormesh(X, Y, ones(3, 3)), "`C` must be 2x3 (one value per cell) or 3x4")
		@test _m2_throws(() -> plot_pcolormesh(X, Y[:, 1:3], C), "`X` is 3x4 but `Y` is 3x3")
		@test _m2_throws(() -> plot_pcolormesh(X, collect(0.0:3.0), C), "two vectors or `X, Y` as two matrices")
		@test _m2_throws(() -> plot_pcolormesh([0.0], [0.0, 1.0], ones(0, 1)), "at least 2x2")
		@test _m2_throws(() -> plot_pcolormesh(X, Y, C; color = "red"), "unsupported keyword argument(s) `color`")
		@test _m2_throws(() -> plot_pcolormesh(X, Y, C; legend = "a"), "unsupported keyword argument(s) `legend`")
		@test _m2_throws(() -> plot_pcolormesh(X .* NaN, Y, C), "`X` must contain finite")
		# vector form, rectilinear: one heatmap, rows indexed by y
		x = [0.0, 1.0, 3.0]
		y = [0.0, 2.0, 3.0, 5.0]
		fig = plot_pcolormesh(x, y, C)
		@test length(fig.data) == 1
		h = fig.data[1]
		@test _m2_type(h) == "heatmap"
		@test h.fields[:x] == x && h.fields[:y] == y
		@test h.fields[:transpose] === false
		@test h.fields[:zsmooth] === false
		@test h.fields[:z] == [[C[1, j], C[2, j]] for j in 1:3]
		@test (h.fields[:zmin], h.fields[:zmax]) == (1.0, 6.0)
		@test h.fields[:colorscale] == _m2_stops("Viridis")
		@test h.fields[:showscale] === true
		@test h.fields[:hoverinfo] == "skip"
		# decreasing coordinates are reversed together with C
		fig = plot_pcolormesh(reverse(x), y, C)
		@test fig.data[1].fields[:x] == x
		@test fig.data[1].fields[:z] == [[C[2, j], C[1, j]] for j in 1:3]
		# NaN cell is a gap; log norm stores log10 and hovers the raw value
		Cn = copy(C)
		Cn[2, 1] = NaN
		fig = plot_pcolormesh(x, y, Cn; colornorm = :log, hover = true, colorbar_title = "v")
		h = fig.data[1]
		@test h.fields[:z][1][2] === nothing
		@test h.fields[:z][2][1] ≈ log10(C[1, 2])
		@test h.fields[:customdata][2][1] == C[1, 2]
		@test h.fields[:zmin] == 0.0 && h.fields[:zmax] ≈ log10(6.0)
		@test _m2_get(_m2_get(h.fields[:colorbar], :title), :text) == "v"
		# coloraxis on the heatmap path
		fig = plot_pcolormesh(x, y, C; coloraxis = :shared, opacity = 0.5)
		@test fig.data[1].fields[:coloraxis] == "coloraxis"
		@test !haskey(fig.data[1].fields, :zmin)
		@test fig.data[1].fields[:opacity] == 0.5
		@test _m2_get(fig.layout.fields[:coloraxis], :cmax) == 6.0
		# edges, hatch, non-monotonic coordinates or log axes switch to polygons
		@test _m2_nrings(plot_pcolormesh(x, y, C; edgewidth = 1)) == 6
		@test _m2_nrings(plot_pcolormesh(x, y, C; hatch = "x")) == 6
		@test _m2_nrings(plot_pcolormesh([0.0, 2.0, 1.0], y, C)) == 6
		@test _m2_nrings(plot_pcolormesh(x .+ 1, y, C; xscale = "log")) == 6
		# mutator, mirrored copy
		fig = plot_pcolormesh(X, Y, C)
		n = length(fig.data)
		plot_pcolormesh!(fig, -X, Y, C; showscale = false)
		@test _m2_nrings(fig) == 12
		@test _m2_get(_m2_carriers(fig)[end].fields[:marker], :showscale) === false
	end

	@testset "plot_tripcolor: flat" begin
		fig = plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, [1.0, 2.0, 3.0, 4.0]; hover = true)
		@test _m2_nrings(fig) == 4
		@test fig.data[end].fields[:customdata] == [1.0, 2.0, 3.0, 4.0]
		@test _m2_get(_m2_carriers(fig)[1].fields[:marker], :cmin) == 1.0
		# node values: triangle value = mean of its vertices
		v = [0.0, 3.0, 6.0, 9.0, 12.0]
		fig = plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, v; hover = true)
		@test fig.data[end].fields[:customdata] ≈ [sum(v[_M2_TRI[i, :]]) / 3 for i in 1:4]
		# ambiguous length: nodes win in :auto, :cells forces per-triangle
		sq = [1 2 4; 1 4 3; 1 2 3; 2 4 3]
		fig = plot_tripcolor(_M2_SQX, _M2_SQY, sq, [1.0, 2.0, 3.0, 4.0]; hover = true)
		@test fig.data[end].fields[:customdata] ≈ [sum([1.0, 2.0, 3.0, 4.0][sq[i, :]]) / 3 for i in 1:4]
		fig = plot_tripcolor(_M2_SQX, _M2_SQY, sq, [1.0, 2.0, 3.0, 4.0]; values_at = :cells, hover = true)
		@test fig.data[end].fields[:customdata] == [1.0, 2.0, 3.0, 4.0]
		@test _m2_throws(() -> plot_tripcolor(_M2_SQX, _M2_SQY, sq, [1.0, 2.0, 3.0, 4.0]; values_at = :faces), "`values_at` must be")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, [1.0, 2.0]), "expected one per node (5) or one per triangle (4)")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, [1.0, 2.0]; values_at = :nodes), "`values` has 2 entries for 5 nodes")
		# mask: hidden triangles are not drawn and do not set the limits
		fig = plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, [1.0, 2.0, 3.0, 40.0]; mask = [false, false, false, true])
		@test _m2_nrings(fig) == 3
		@test _m2_get(_m2_carriers(fig)[1].fields[:marker], :cmax) == 3.0
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; mask = [true]), "`mask` has 1 entries for 4 triangles")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; mask = [1, 0, 0, 0]), "vector of Bool")
		# edges
		fig = plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, [1.0, 2.0, 3.0, 4.0]; edges = true)
		@test all(_m2_get(t.fields[:line], :color) == _M2._color_hex("rgba(0,0,0,0.35)"; who = "test") for t in _m2_fills(fig))
		@test all(_m2_get(t.fields[:line], :width) == 0.5 for t in _m2_fills(fig))
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; edges = 1), "`edges` must be true or false")
		# connectivity validation
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, [1 2 3 4], _M2_TX), "N x 3 matrix")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, permutedims(_M2_TRI), _M2_TX), "pass the transpose")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, [[1, 2, 3, 4]], _M2_TX), "needs exactly 3")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, [1 2 6], _M2_TX), "refers to node 6, outside 1:5")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; shading = :phong), "`shading` must be :flat or :gouraud")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; color = "red"), "unsupported keyword argument(s) `color`")
	end

	@testset "plot_tripcolor: gouraud raster" begin
		# A linear field is reproduced exactly by barycentric interpolation.
		f(x, y) = 2.0 + 3.0x - 1.5y
		x = [0.0, 4.0, 1.0]
		y = [0.0, 1.0, 3.0]
		fig = plot_tripcolor(x, y, [1 2 3], f.(x, y); shading = :gouraud, resolution = 64)
		@test length(fig.data) == 1
		h = fig.data[1]
		@test _m2_type(h) == "heatmap"
		@test h.fields[:transpose] === false
		xc, yc, z = h.fields[:x], h.fields[:y], h.fields[:z]
		@test length(xc) == 64 && length(yc) == 48
		@test xc[1] ≈ 4 / 64 / 2 && yc[1] ≈ 3 / 48 / 2
		filled = [(i, j) for j in eachindex(yc), i in eachindex(xc) if z[j][i] !== nothing]
		@test !isempty(filled)
		@test maximum(abs(z[j][i] - f(xc[i], yc[j])) for (i, j) in filled) < 1e-12
		# the pixel nearest the centroid carries the centroid value (mean of nodes)
		cx, cy = sum(x) / 3, sum(y) / 3
		i = argmin(abs.(xc .- cx)); j = argmin(abs.(yc .- cy))
		@test isapprox(z[j][i], sum(f.(x, y)) / 3; atol = 3.0 * (xc[2] - xc[1]) + 1.5 * (yc[2] - yc[1]))
		# pixels outside the triangle are gaps
		@test z[end][1] === nothing                                       # top-left corner of the bbox
		@test (h.fields[:zmin], h.fields[:zmax]) == extrema(f.(x, y))
		# masked triangle pixels are gaps; the hidden node does not set limits
		fig = plot_tripcolor(_M2_SQX, _M2_SQY, _M2_SQTRI, [0.0, 1.0, 1.0, 2.0]; shading = :gouraud, mask = [false, true], resolution = 20)
		h = fig.data[1]
		xc, yc, z = h.fields[:x], h.fields[:y], h.fields[:z]
		for j in eachindex(yc), i in eachindex(xc)
			# triangle 1 = (0,0), (1,0), (1,1): below the diagonal
			if yc[j] > xc[i] + 1e-9
				@test z[j][i] === nothing
			elseif yc[j] < xc[i] - 1e-9
				@test z[j][i] ≈ xc[i] + yc[j]
			end
		end
		@test (h.fields[:zmin], h.fields[:zmax]) == (0.0, 2.0)
		fig = plot_tripcolor(_M2_SQX, _M2_SQY, _M2_SQTRI, [0.0, 1.0, 50.0, 2.0]; shading = :gouraud, mask = [false, true])
		@test fig.data[1].fields[:zmax] == 2.0
		# options
		fig = plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; shading = :gouraud, edges = true, edgecolor = "red", edgewidth = 2, hover = true, opacity = 0.7)
		@test _m2_type(fig.data[2]) == "scatter"
		@test _m2_get(fig.data[2].fields[:line], :color) == _M2._color_hex("red"; who = "test")
		@test fig.data[1].fields[:opacity] == 0.7
		@test occursin("%{z", fig.data[1].fields[:hovertemplate])
		fig = plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX .+ 1; shading = :gouraud, colornorm = :log, hover = true)
		h = fig.data[1]
		k = findfirst(v -> v !== nothing, h.fields[:z][end ÷ 2])
		@test exp10(h.fields[:z][end ÷ 2][k]) ≈ h.fields[:customdata][end ÷ 2][k]
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, [1.0, 2.0, 3.0, 4.0]; shading = :gouraud), "must have one entry per node (5)")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX .+ 1, _M2_TY, _M2_TRI, _M2_TX; shading = :gouraud, xscale = "log"), "use shading = :flat on logarithmic axes")
		@test _m2_throws(() -> plot_tripcolor(_M2_TX, _M2_TY, _M2_TRI, _M2_TX; shading = :gouraud, resolution = 4096), "`resolution` must be an integer in 2:2048")
		@test _m2_throws(() -> plot_tripcolor([0.0, 1.0, 2.0], [0.0, 1.0, 2.0], [1 2 3], [1.0, 2.0, 3.0]; shading = :gouraud), "no area")
		# everything masked: nothing drawn
		fig = plot_tripcolor(_M2_SQX, _M2_SQY, _M2_SQTRI, [0.0, 1.0, 1.0, 2.0]; shading = :gouraud, mask = [true, true])
		@test isempty(fig.data)
	end

	@testset "plot_triplot" begin
		fig = plot_triplot(_M2_SQX, _M2_SQY, _M2_SQTRI)
		@test length(fig.data) == 1
		t = fig.data[1]
		@test length(t.fields[:x]) == 5 * 3 - 1                      # 5 unique edges
		@test count(isnothing,t.fields[:x]) == 4
		@test _m2_get(t.fields[:line], :color) == _M2._color_hex("black"; who = "test")
		@test _m2_get(t.fields[:line], :width) == 0.5
		@test t.fields[:showlegend] === false
		edges = Set{Tuple{Tuple{Float64, Float64}, Tuple{Float64, Float64}}}()
		for k in 1:3:length(t.fields[:x])
			push!(edges, minmax((t.fields[:x][k], t.fields[:y][k]), (t.fields[:x][k + 1], t.fields[:y][k + 1])))
		end
		@test length(edges) == 5
		@test ((0.0, 0.0), (1.0, 1.0)) in edges                      # the shared diagonal, once
		fig = plot_triplot(_M2_SQX, _M2_SQY, _M2_SQTRI; color = "", linewidth = 2, dash = "--", opacity = 0.5, legend = "mesh", mask = [false, true])
		t = fig.data[1]
		@test count(isnothing,t.fields[:x]) == 2                  # one triangle: 3 edges
		@test _m2_get(t.fields[:line], :color) == _M2._default_trace_color(fig, 1)
		@test _m2_get(t.fields[:line], :dash) == "dash"
		@test _m2_get(t.fields[:line], :width) == 2.0
		@test t.fields[:opacity] == 0.5
		@test t.fields[:showlegend] === true && t.fields[:name] == "mesh"
		@test _m2_get(plot_triplot(_M2_SQX, _M2_SQY, _M2_SQTRI; dash = "5px,3px").data[1].fields[:line], :dash) == "5px,3px"
		@test _m2_get(plot_triplot(_M2_SQX, _M2_SQY, _M2_SQTRI; dash = :dot).data[1].fields[:line], :dash) == "dot"
		@test _m2_throws(() -> plot_triplot(_M2_SQX, _M2_SQY, _M2_SQTRI; dash = "wavy"), "unknown `dash`")
		@test _m2_throws(() -> plot_triplot(_M2_SQX, _M2_SQY, _M2_SQTRI; linewidth = -1), "`linewidth` must be a finite number >= 0")
		@test _m2_throws(() -> plot_triplot(_M2_SQX, _M2_SQY, _M2_SQTRI; values = [1]), "unsupported keyword argument(s) `values`")
		@test _m2_throws(() -> plot_triplot(_M2_SQX, _M2_SQY, [1 2 3 4]), "N x 3 matrix")
		@test _m2_get(plot_triplot(_M2_SQX, _M2_SQY, _M2_SQTRI).layout.fields[:yaxis], :scaleanchor) == "x"
	end

	@testset "plot_tricontour" begin
		# v = x on the unit square: the 0.5 level is the vertical line x = 0.5
		fig = plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; levels = [0.5])
		@test length(fig.data) == 1
		t = fig.data[1]
		@test all(==(0.5), t.fields[:x])
		@test sort(t.fields[:y]) == [0.0, 0.5, 1.0]                   # one polyline through the diagonal crossing
		@test !any(isnothing, t.fields[:x])
		@test occursin("0.5", t.fields[:hovertemplate])
		# a peak in the middle gives a closed loop
		fig = plot_tricontour(_M2_TX, _M2_TY, _M2_TRI, [0.0, 0.0, 0.0, 0.0, 1.0]; levels = [0.5])
		t = fig.data[1]
		@test length(t.fields[:x]) == 5
		@test (t.fields[:x][1], t.fields[:y][1]) == (t.fields[:x][end], t.fields[:y][end])
		@test all(p -> isapprox(abs(p[1] - 0.5) + abs(p[2] - 0.5), 0.25; atol = 1e-12) ||
			isapprox(max(abs(p[1] - 0.5), abs(p[2] - 0.5)), 0.25; atol = 1e-12), zip(t.fields[:x], t.fields[:y]))
		# integer levels: round steps inside the data range
		@test _M2._mesh2d_nice_levels(0.0, 1.0, 4) == [0.2, 0.4, 0.6, 0.8]
		@test _M2._mesh2d_nice_levels(0.0, 1.0, 1) == [0.5]
		@test _M2._mesh2d_nice_levels(-1.6, 1.6, 8) == [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5]
		@test _M2._mesh2d_nice_levels(0.05, 0.95, 2) == [0.5]
		@test _M2._mesh2d_nice_levels(1e20, 1e20 + 1e6, 3) ≈ [1e20 + 2.5e5, 1e20 + 5e5, 1e20 + 7.5e5]
		# offset beyond 2^53 steps: evenly spaced fallback, still inside the range
		fallback = _M2._mesh2d_nice_levels(1e17, 1e17 + 100, 3)
		@test length(fallback) == 3 && all(1e17 < L < 1e17 + 100 for L in fallback)
		@test all(1 <= length(_M2._mesh2d_nice_levels(lo, lo + w, n)) <= n
			for lo in (-3.7, 0.0, 12.3), w in (1e-3, 0.7, 5.0, 1234.5), n in (1, 2, 3, 7, 10))
		fig = plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX .+ _M2_SQY; levels = 3)
		@test [t.fields[:hovertemplate] for t in fig.data] == ["0.5<extra></extra>", "1<extra></extra>", "1.5<extra></extra>"]
		@test isempty(plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, ones(4)).data)   # constant field: no levels
		# colours: levels sampled over their own range (or crange); fixed colour
		stops = _m2_stops("Viridis")
		@test [_m2_get(t.fields[:line], :color) for t in fig.data] == _M2._sample_colorscale(stops, [0.0, 0.5, 1.0])
		fig = plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX .+ _M2_SQY; levels = [1.0], crange = (0, 4), colorscale = "magma")
		@test _m2_get(fig.data[1].fields[:line], :color) == _M2._sample_colorscale(_m2_stops("magma"), 0.25)
		fig = plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; levels = [0.25, 0.75], color = :red, linewidth = 2, dash = ":", opacity = 0.5)
		for t in fig.data
			@test _m2_get(t.fields[:line], :color) == _M2._color_hex("red"; who = "test")
			@test _m2_get(t.fields[:line], :width) == 2.0
			@test _m2_get(t.fields[:line], :dash) == "dot"
			@test t.fields[:opacity] == 0.5
		end
		# labels: one per level at the midpoint of its longest polyline
		fig = plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; levels = [0.25, 0.75], showlabels = true, label_fontsize = 9)
		lab = fig.data[end]
		@test lab.fields[:mode] == "text"
		@test lab.fields[:text] == ["0.25", "0.75"]
		@test lab.fields[:x] ≈ [0.25, 0.75] && lab.fields[:y] ≈ [0.5, 0.5]
		@test _m2_get(lab.fields[:textfont], :shadow) == "auto"
		@test _m2_get(lab.fields[:textfont], :size) == 9.0
		@test _m2_get(lab.fields[:textfont], :color) == [_m2_get(t.fields[:line], :color) for t in fig.data[1:2]]
		# NaN node: its triangles are skipped; mask hides triangles
		fig = plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, [0.0, 1.0, NaN, 1.0]; levels = [0.5])
		@test sort(fig.data[1].fields[:y]) == [0.0, 0.5]
		fig = plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; levels = [0.5], mask = [true, false])
		@test sort(fig.data[1].fields[:y]) == [0.5, 1.0]
		# validation
		@test _m2_throws(() -> plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; levels = [0.5, 0.2]), "`levels` must be strictly increasing")
		@test _m2_throws(() -> plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; levels = 0), "must be >= 1")
		@test _m2_throws(() -> plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; levels = Float64[]), "must not be empty")
		@test _m2_throws(() -> plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; crange = (1, 1)), "crange")
		@test _m2_throws(() -> plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; showlabels = 1), "`showlabels` must be true or false")
		@test _m2_throws(() -> plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; label_fontsize = -2), "`label_fontsize`")
		@test _m2_throws(() -> plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, [1.0, 2.0]), "`values` has 2 entries for 4 nodes")
		@test _m2_throws(() -> plot_tricontour(_M2_SQX, _M2_SQY, _M2_SQTRI, _M2_SQX; colornorm = :log), "unsupported keyword argument(s) `colornorm`")
	end

	@testset "construction scales linearly in the cell count" begin
		# O(cells): 16x the cells may not cost more than ~16x the time (with
		# generous slack for timer noise); a quadratic step would cost ~256x.
		function grid(m)
			X = [i + 0.01j for i in 0:m, j in 0:m]
			Y = [j + 0.01i for i in 0:m, j in 0:m]
			C = [sin(0.1i) * cos(0.1j) for i in 1:m, j in 1:m]
			return X, Y, C
		end
		plot_pcolormesh(grid(4)...)
		small = grid(50)
		large = grid(200)
		t_small = minimum(@elapsed(plot_pcolormesh(small...)) for _ in 1:3)
		t_large = minimum(@elapsed(plot_pcolormesh(large...)) for _ in 1:3)
		@test t_large < 64 * t_small
	end
end

# ── 2.0 integration wave 3 (fields-int): X1 colour-bar titles, `tight`, X23
# ranges, X20 insets, D10 finalize and X10 line widths on the mesh family. ──

const _M2V3_QX = [0.0, 1.0, 2.0, 0.0, 1.0, 2.0]
const _M2V3_QY = [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
const _M2V3_QUADS = [1 2 5 4; 2 3 6 5]
const _M2V3_TX = [0.0, 1.0, 0.0]
const _M2V3_TY = [0.0, 0.0, 1.0]
const _M2V3_TRI = [1 2 3]

_m2v3_d(x) = _M2._symbol_dict(x)
_m2v3_layout(fig) = _M2._plot_obj(fig).layout.fields
_m2v3_axis(fig, key) = _m2v3_d(get(_m2v3_layout(fig), key, Dict{Symbol, Any}()))
_m2v3_anns(fig) = [_m2v3_d(a) for a in get(_m2v3_layout(fig), :annotations, Any[])]
_m2v3_names(fig) = String[String(get(a, :name, "")) for a in _m2v3_anns(fig)]
_m2v3_meta(fig) = Any[get(t.fields, :meta, nothing) for t in _M2._plot_data(fig)]
# The colour bar of a figure: on a trace, on a trace's marker, or on a layout
# colour axis (exactly one is expected).
function _m2v3_colorbar(fig)
	bars = Dict{Symbol, Any}[]
	for t in _M2._plot_data(fig)
		haskey(t.fields, :colorbar) && push!(bars, _m2v3_d(t.fields[:colorbar]))
		m = _m2v3_d(get(t.fields, :marker, Dict{Symbol, Any}()))
		haskey(m, :colorbar) && push!(bars, _m2v3_d(m[:colorbar]))
	end
	for (k, v) in _m2v3_layout(fig)
		startswith(String(k), "coloraxis") || continue
		c = _m2v3_d(v)
		haskey(c, :colorbar) && push!(bars, _m2v3_d(c[:colorbar]))
	end
	return only(bars)
end
function _m2v3_inset_sf()
	sf = subplots(2, 2; sync = false)
	inset!(sf, (0.6, 0.6, 0.35, 0.35); row = 2, col = 2)
	sf.current_row = 1
	sf.current_col = 1
	return sf, getfield(sf, :insets)[1]
end

@testset "sci mesh2d: 2.0 integration (fields-int)" begin
	coloured = (
		("plot_polygons", kw -> plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS, [0.2, 0.9]; kw...)),
		("plot_pcolormesh", kw -> plot_pcolormesh(0:3, 0:2, [1.0 2; 3 4; 5 6]; kw...)),
		("plot_tripcolor", kw -> plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2.0, 3.0]; kw...)),
		("plot_tripcolor", kw -> plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2.0, 3.0]; shading = :gouraud, kw...)),
		("plot_pcolormesh!", kw -> (f = plot_pcolormesh(0:1, 0:1, ones(1, 1); showscale = false);
			plot_pcolormesh!(f, 0:3, 0:2, [1.0 2; 3 4; 5 6]; kw...); f)),
	)

	@testset "X1 colorbar_title_side: plain titles" begin
		for (who, build) in coloured, side in (:top, :right, :bottom)
			bar = _m2v3_colorbar(build((colorbar_title = "T", colorbar_title_side = side)))
			@test _m2v3_d(bar[:title]) == Dict{Symbol, Any}(:text => "T", :side => String(side))
		end
		# Default :top; a String is accepted.
		@test _m2v3_d(_m2v3_colorbar(coloured[1][2]((colorbar_title = "T",)))[:title])[:side] == "top"
		@test _m2v3_d(_m2v3_colorbar(coloured[2][2]((colorbar_title = "T", colorbar_title_side = "Right")))[:title])[:side] == "right"
		for (who, build) in coloured
			@test _m2_throws(() -> build((colorbar_title_side = :left,)),
				"$(who): `colorbar_title_side` must be :top, :right or :bottom; got :left.")
		end
		# A uniform-colour mesh has no bar: the keyword is an error, not a no-op.
		@test _m2_throws(() -> plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS; colorbar_title_side = :right),
			"plot_polygons: `colorbar_title_side` maps cell values to colours")
	end

	@testset "X1 math colour-bar titles: annotations in figures, cells and insets" begin
		for (who, build) in coloured, side in (:top, :right)
			f = build((colorbar_title = "\$T_1\$", colorbar_title_side = side))
			name = "plotlysupply:colorbar_title:x:$(side)"
			@test count(==(name), _m2v3_names(f)) == 1
			ann = only(a for a in _m2v3_anns(f) if a[:name] == name)
			@test ann[:text] == "\$T_1\$"
			side === :right && @test ann[:textangle] == -90
			@test !haskey(_m2v3_colorbar(f), :title)
		end
		g = plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2.0, 3.0]; shading = :gouraud,
			coloraxis = :shared, colorbar_title = "\$g\$")
		@test "plotlysupply:colorbar_title:coloraxis:top" in _m2v3_names(g)
		sf = subplots(1, 2; sync = false)
		plot_pcolormesh!(sf, 0:3, 0:2, [1.0 2; 3 4; 5 6]; row = 1, col = 2,
			colorbar_title = "\$c\$", colorbar_title_side = :right)
		@test "plotlysupply:colorbar_title:x2:right" in _m2v3_names(sf)
		# X51: a numbered colour axis in a cell keeps its math title.
		sf, rec = _m2v3_inset_sf()
		plot_polygons!(sf, [[0, 1, 1.0]], [[0, 0, 1.0]], [1.0]; inset = 1,
			coloraxis = "coloraxis2", colorbar_title = "\$\\beta\$")
		@test "plotlysupply:colorbar_title:coloraxis2:top" in _m2v3_names(sf)
		ann = only(a for a in _m2v3_anns(sf) if a[:name] == "plotlysupply:colorbar_title:coloraxis2:top")
		@test ann[:text] == "\$\\beta\$"
	end

	@testset "tight: fill traces carry the finalize meta" begin
		tight, loose = "plotlysupply:field", "plotlysupply:field:loose"
		@test _m2v3_meta(plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS)) == Any[tight]
		@test _m2v3_meta(plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS; tight = false)) == Any[loose]
		@test _m2v3_meta(plot_pcolormesh(0:3, 0:2, rand(3, 2))) == Any[tight]
		@test _m2v3_meta(plot_pcolormesh(0:3, 0:2, rand(3, 2); tight = false)) == Any[loose]
		@test _m2v3_meta(plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; shading = :gouraud, edges = true)) ==
			Any[tight, nothing]
		# Edges, carriers and hover markers are overlays: no meta.
		f = plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS, [0.2, 0.9]; edgecolor = "black", edgewidth = 1, hover = true)
		@test count(==(tight), _m2v3_meta(f)) == length(_m2_fills(f))
		@test all(t -> !haskey(t.fields, :meta), _m2_carriers(f))
		@test _m2v3_meta(plot_triplot(_M2V3_TX, _M2V3_TY, _M2V3_TRI)) == Any[nothing]
		@test _m2v3_meta(plot_tricontour(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; levels = [1.5])) == Any[nothing]
		for (who, call) in (
			("plot_polygons", () -> plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS; tight = 1)),
			("plot_pcolormesh", () -> plot_pcolormesh(0:3, 0:2, rand(3, 2); tight = nothing)),
			("plot_tripcolor", () -> plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; tight = "no")),
		)
			@test _m2_throws(call, "$(who): `tight` must be true or false")
		end
		@test _m2_throws(() -> plot_triplot(_M2V3_TX, _M2V3_TY, _M2V3_TRI; tight = true), "unsupported keyword argument")
	end

	@testset "X23 K1 K2 D11 ranges: sentinels, one-sided limits, validation, log axes, cells" begin
		clip(fig, key) = _M2._fin_sticky_clip(get(_m2v3_layout(fig), key, nothing))
		# The one-sided limit (D11) on an axis: `(:pinned, range)` on an
		# equal-aspect axis, else `(autorange, minallowed, maxallowed)`.
		function lim(fig, key)
			ax = _m2v3_axis(fig, key)
			get(ax, :autorange, true) === false && return (:pinned, collect(ax[:range]))
			opts = _m2v3_d(get(ax, :autorangeoptions, Dict{Symbol, Any}()))
			return (get(ax, :autorange, true), get(opts, :minallowed, nothing), get(opts, :maxallowed, nothing))
		end
		# Sentinels are automatic (K1): no user range, finalize's clip of the
		# mesh extent; an equal-aspect mesh is pinned to exactly that clip.
		for sentinel in ([0, 0], (0, 0), nothing, [nothing, nothing])
			f = plot_pcolormesh(0:3, 0:2, rand(3, 2); xrange = sentinel)
			@test clip(f, :xaxis) == (0.0, 3.0) && !haskey(_m2v3_axis(f, :xaxis), :range)
			g = plot_pcolormesh(0:3, 0:2, rand(3, 2); xrange = sentinel, equalar = true)
			@test clip(g, :xaxis) == (0.0, 3.0)
			@test _m2v3_axis(g, :xaxis)[:autorange] === false && _m2v3_axis(g, :xaxis)[:range] == [0.0, 3.0]
			h = plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS; yrange = sentinel)
			@test clip(h, :yaxis) == (0.0, 1.0) && _m2v3_axis(h, :yaxis)[:range] == [0.0, 1.0]
		end
		# No user range was recorded: a later trace widens the axis. A marker
		# past the mesh (K5 / D16) reaches the marker plus the overlay pad
		# (2.5 % of the span) on that side; the mesh side stays tight.
		f = plot_pcolormesh(0:3, 0:2, rand(3, 2); xrange = nothing)
		plot_scatter!(f, [9.0], [1.0]; mode = "markers")
		@test clip(f, :xaxis) == (0.0, 9.0 + _M2._FIN_OVERLAY_PAD * 9.0)
		ax = _m2v3_axis(plot_pcolormesh(0:3, 0:2, rand(3, 2); yrange = (0.5, 1.5)), :yaxis)
		@test collect(ax[:range]) == [0.5, 1.5] && ax[:autorange] === false
		# D11: one-sided limits on every mesh function and mutator.
		for (who, build) in (
			("plot_polygons", kw -> plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS; kw...)),
			("plot_pcolormesh", kw -> plot_pcolormesh(0:3, 0:2, rand(3, 2); kw...)),
			("plot_tripcolor", kw -> plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; kw...)),
			("plot_triplot", kw -> plot_triplot(_M2V3_TX, _M2V3_TY, _M2V3_TRI; kw...)),
			("plot_tricontour", kw -> plot_tricontour(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; levels = [1.5], kw...)),
			("plot_pcolormesh!", kw -> (f = plot_pcolormesh(0:3, 0:2, rand(3, 2)); plot_pcolormesh!(f, 0:3, 0:2, rand(3, 2); kw...); f)),
		)
			# Fixed bound plus autorange (`savefig` keeps autorange options), or,
			# on an equal-aspect axis, pinned to the bound and the data's edge.
			f = build((; xrange = (0.25, nothing)))
			aspect = haskey(_m2v3_axis(f, :yaxis), :scaleanchor)
			l = lim(f, :xaxis)
			@test (l[1] === :pinned) == aspect
			@test aspect ? (minimum(l[2]) == 0.25 && l[2][1] < l[2][2]) : l == (true, 0.25, nothing)
			f = build((; yrange = [nothing, 0.75]))
			l = lim(f, :yaxis)
			@test aspect ? (l[1] === :pinned && maximum(l[2]) == 0.75 && l[2][1] < l[2][2]) : l == (true, nothing, 0.75)
			@test clip(f, :yaxis) === nothing
			# The D11 messages of the shared range check (Z53).
			@test _m2_throws(() -> build((; xrange = (missing, 2))), "$(who): `xrange`: an open bound of a one-sided limit is written `nothing`")
			@test _m2_throws(() -> build((; yrange = (Inf, nothing))), "$(who): `yrange` bounds must be finite")
			@test _m2_throws(() -> build((; yrange = [1, 1])), "$(who): `yrange`: the range bounds must differ")
			@test _m2_throws(() -> build((; xrange = (true, 2))), "$(who): `xrange` range bounds must be numbers (or date/category values), not Bool")
		end
		f = plot_tripcolor([1.0, 10.0, 1.0], _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; xscale = "log", xrange = (1, 100))
		@test _m2v3_axis(f, :xaxis)[:range] == [0.0, 2.0] && _m2v3_axis(f, :xaxis)[:autorange] === false
		# One-sided on a log axis: data units, stored as log10; positive only.
		f = plot_pcolormesh([1.0, 10, 100], 0:2, rand(2, 2); xscale = "log", xrange = (nothing, 50))
		@test lim(f, :xaxis)[1:2] == (true, nothing) && lim(f, :xaxis)[3] ≈ log10(50)
		# Equal-aspect meshes: pinned to the bound and the mesh edge.
		@test lim(plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS; xrange = (0.5, nothing)), :xaxis) == (:pinned, [0.5, 2.0])
		@test lim(plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; yrange = (nothing, 0.5)), :yaxis) == (:pinned, [0.0, 0.5])
		@test lim(plot_pcolormesh(0:3, 0:2, rand(3, 2); equalar = true, xrange = (nothing, 2)), :xaxis) == (:pinned, [0.0, 2.0])
		@test _m2_throws(() -> plot_pcolormesh([1.0, 10, 100], 0:2, rand(2, 2); xscale = "log", xrange = (0, nothing)),
			"plot_pcolormesh: `xrange` bounds on a logarithmic axis are data values and must be positive")
		# Cells: data units on a log cell, autorange off.
		sf = subplots(1, 2; sync = false)
		plot_pcolormesh!(sf, [1.0, 10, 100], 0:1, rand(2, 1); row = 1, col = 2, xscale = "log")
		plot_pcolormesh!(sf, [1.0, 10, 100], 0:1, rand(2, 1); row = 1, col = 2, xrange = (1, 1000))
		@test _m2v3_axis(sf, :xaxis2)[:range] == [0.0, 3.0] && _m2v3_axis(sf, :xaxis2)[:autorange] === false
		plot_pcolormesh!(sf, [1.0, 10, 100], 0:1, rand(2, 1); row = 1, col = 2, xrange = (10, nothing))
		@test lim(sf, :xaxis2) == (true, 1.0, nothing)
		plot_triplot!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI; row = 1, col = 1, yrange = [nothing, 1])
		l = lim(sf, :yaxis)
		@test l == (true, nothing, 1) || (l[1] === :pinned && l[2][2] == 1)
		n = length(_M2._plot_data(sf))
		@test _m2_throws(() -> plot_triplot!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI; row = 1, col = 1, yrange = [missing, 1]),
			"plot_triplot!: `yrange`: an open bound of a one-sided limit is written `nothing`")
		@test _m2_throws(() -> plot_pcolormesh!(sf, [1.0, 10, 100], 0:1, rand(2, 1); row = 1, col = 2, xrange = (0, nothing)),
			"plot_pcolormesh!: `xrange` bounds on a logarithmic axis are data values and must be positive")
		@test length(_M2._plot_data(sf)) == n
		# Shared x: the range goes to the `matches` root, which plotly.js reads.
		shared = subplots(2, 1; sync = false, shared_xaxes = true)
		root = _M2._fin_match_root(shared.plot.layout.fields, :xaxis)
		@test root === :xaxis2
		plot_pcolormesh!(shared, 0:3, 0:1, rand(3, 1); row = 1, col = 1, xrange = (0, 5))
		@test collect(_m2v3_axis(shared, root)[:range]) == [0, 5]
		@test !haskey(_m2v3_axis(shared, :xaxis), :range)
		shared = subplots(2, 1; sync = false, shared_xaxes = true)
		plot_pcolormesh!(shared, 0:3, 0:1, rand(3, 1); row = 1, col = 1, xrange = (nothing, 5))
		@test lim(shared, :xaxis2) == (true, nothing, 5)
		@test _m2v3_d(_m2v3_axis(shared, :xaxis)[:autorangeoptions])[:maxallowed] == 5
		@test !haskey(_m2v3_axis(shared, :xaxis), :range)
	end

	@testset "X20 inset = k on every mesh mutator" begin
		for call in (
			sf -> plot_polygons!(sf, [[0, 1, 1.0]], [[0, 0, 1.0]], [1.0]; inset = 1),
			# G51: plot_pcolormesh has no equal aspect by default; ask for it here.
			sf -> plot_pcolormesh!(sf, 0:3, 0:2, rand(3, 2); inset = 1, equalar = true),
			sf -> plot_tripcolor!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; inset = 1),
			sf -> plot_tripcolor!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; inset = 1, shading = :gouraud),
			sf -> plot_triplot!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI; inset = 1),
			sf -> plot_tricontour!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; inset = 1, levels = [1.5]),
		)
			sf, rec = _m2v3_inset_sf()
			@test call(sf) === sf
			data = _M2._plot_data(sf)
			@test !isempty(data)
			@test all(t -> t.fields[:xaxis] == rec.xref && t.fields[:yaxis] == rec.yref, data)
			@test _m2v3_axis(sf, rec.ykey)[:scaleanchor] == rec.xref
			@test !haskey(_m2v3_axis(sf, :yaxis4), :scaleanchor)
			@test (sf.current_row, sf.current_col) == (2, 2)
		end
		sf, rec = _m2v3_inset_sf()
		@test _m2_throws(() -> plot_pcolormesh!(sf, 0:3, 0:2, rand(3, 2); inset = 2), "unknown inset id 2")
		@test _m2_throws(() -> plot_triplot!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI; inset = 1, show = true),
			"plot_triplot!: mutators do not take `show`")
		@test isempty(_M2._plot_data(sf))
	end

	@testset "D10 K3 mesh mutators finalize the figure (sticky contract)" begin
		# The `matches` root holding a mesh field gets finalize's clip of the
		# mesh extent (pinned to it under the default equal aspect of polygons
		# and tripcolor), which a later trace widens; triplot/tricontour draw no
		# field, so their root keeps plotly's autorange.
		clip(fig) = _M2._fin_sticky_clip(get(_m2v3_layout(fig), :xaxis, nothing))
		for (mutate!, extent, pinned) in (
			(p -> plot_polygons!(p, _M2V3_QX, _M2V3_QY, _M2V3_QUADS), (0.0, 2.0), true),
			(p -> plot_pcolormesh!(p, 0:3, 0:2, rand(3, 2)), (0.0, 3.0), false),
			(p -> plot_tripcolor!(p, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]), (0.0, 1.0), true),
			(p -> plot_triplot!(p, _M2V3_TX, _M2V3_TY, _M2V3_TRI), nothing, false),
			(p -> plot_tricontour!(p, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; levels = [1.5]), nothing, false),
		)
			p = Plot(GenericTrace[], Layout(xaxis2 = attr(matches = "x", anchor = "y2"), yaxis2 = attr(anchor = "x2")))
			mutate!(p)
			ax = _m2v3_axis(p, :xaxis)
			if extent === nothing
				@test clip(p) === nothing && ax[:autorange] === true && !haskey(ax, :range)
				continue
			end
			@test clip(p) == extent
			if pinned
				@test ax[:autorange] === false && Tuple(Float64.(ax[:range])) == extent
			else
				@test ax[:autorange] === true && !haskey(ax, :range)
			end
			# A marker past the mesh: the axis reaches it plus the overlay pad
			# (K5 / D16), on that side only.
			marker = extent[2] + 10.0
			plot_scatter!(p, [marker], [0.5]; mode = "markers")
			widened = (extent[1], marker + _M2._FIN_OVERLAY_PAD * (marker - extent[1]))
			@test clip(p) == widened
			pinned && @test Tuple(Float64.(_m2v3_axis(p, :xaxis)[:range])) == widened
		end
	end

	@testset "X10 mesh lines take the style's line width, not its cycle" begin
		line(f) = _m2v3_d(f.data[1].fields[:line])
		with_style(; linewidth = 3, cycle = :dash_marker) do
			t = plot_triplot(_M2V3_TX, _M2V3_TY, _M2V3_TRI)
			@test line(t)[:width] == 3 && !haskey(line(t), :dash) && t.data[1].fields[:mode] == "lines"
			@test line(plot_tricontour(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; levels = [1.5]))[:width] == 3
			# Explicit widths win; polygon fills keep their hairline outline.
			@test line(plot_triplot(_M2V3_TX, _M2V3_TY, _M2V3_TRI; linewidth = 2))[:width] == 2
			@test line(plot_tricontour(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; levels = [1.5], linewidth = 0.25))[:width] == 0.25
			@test line(plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS, [0.2, 0.9]))[:width] == 0.5
			sf = subplots(1, 2; sync = false)
			plot_triplot!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI; row = 1, col = 2)
			@test _m2v3_d(_M2._plot_data(sf)[end].fields[:line])[:width] == 3
		end
		@test line(plot_triplot(_M2V3_TX, _M2V3_TY, _M2V3_TRI))[:width] == 0.5
		@test line(plot_tricontour(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; levels = [1.5]))[:width] == 1
		@test _m2_throws(() -> plot_triplot(_M2V3_TX, _M2V3_TY, _M2V3_TRI; linewidth = -1), "plot_triplot")
	end
end

# ── wave 4 (fields): G30 tick keywords, G51 pcolormesh aspect, Y5 SubplotFigure
# delegate on the mesh family. ──

@testset "sci mesh2d: wave 4 (fields)" begin
	mesh_builds = (
		("plot_polygons", kw -> plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS; kw...)),
		("plot_pcolormesh", kw -> plot_pcolormesh(0:3, 0:2, rand(3, 2); kw...)),
		("plot_tripcolor", kw -> plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; kw...)),
		("plot_triplot", kw -> plot_triplot(_M2V3_TX, _M2V3_TY, _M2V3_TRI; kw...)),
		("plot_tricontour", kw -> plot_tricontour(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; levels = [1.5], kw...)),
		("plot_tripcolor!", kw -> (f = plot_pcolormesh(0:3, 0:2, rand(3, 2)); plot_tripcolor!(f, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; kw...); f)),
	)

	@testset "G30 tick keywords on every mesh function" begin
		for (who, build) in mesh_builds
			f = build((; xticks = [0, 0.5, 1], xticklabels = ["a", "b", "c"], ytickformat = ".2f", yticks = [0, 1]))
			ax = _m2v3_axis(f, :xaxis)
			ay = _m2v3_axis(f, :yaxis)
			@test ax[:tickmode] == "array" && ax[:tickvals] == [0, 0.5, 1] && ax[:ticktext] == ["a", "b", "c"]
			@test ay[:tickvals] == [0, 1] && ay[:tickformat] == ".2f"
			@test _m2_throws(() -> build((; xticklabels = ["a"])), "$(who): `xticklabels` needs `xticks`")
			@test _m2_throws(() -> build((; yticks = [true])), "$(who): tick values must all be real numbers")
			@test _m2_throws(() -> build((; xtickformat = 3)), who)
		end
		# The ticks follow a log axis set in the same call (data units).
		f = plot_pcolormesh([1.0, 10, 100], 0:2, rand(2, 2); xscale = "log", xticks = [1, 10, 100])
		@test _m2v3_axis(f, :xaxis)[:tickvals] == [1, 10, 100] && _m2v3_axis(f, :xaxis)[:type] == "log"
		# SubplotFigure cell.
		sf = subplots(1, 2; sync = false)
		plot_tripcolor!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; row = 1, col = 2, yticks = [0, 0.5, 1])
		@test _m2v3_axis(sf, :yaxis2)[:tickvals] == [0, 0.5, 1]
		@test occursin("`xticks = nothing`", string(Base.Docs.doc(plot_polygons)))
	end

	@testset "G51 plot_pcolormesh keeps matplotlib's auto aspect" begin
		f = plot_pcolormesh(0:3, 0:2, rand(3, 2))
		@test !haskey(_m2v3_axis(f, :yaxis), :scaleanchor)
		g = plot_pcolormesh(0:3, 0:2, rand(3, 2); equalar = true)
		@test _m2v3_axis(g, :yaxis)[:scaleanchor] == "x"
		p = plot_scatter([0.0, 1.0], [0.0, 1.0])
		plot_pcolormesh!(p, 0:3, 0:2, rand(3, 2))
		@test !haskey(_m2v3_axis(p, :yaxis), :scaleanchor)
		# The other mesh functions keep the equal aspect of a geometric mesh.
		@test _m2v3_axis(plot_tripcolor(_M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]), :yaxis)[:scaleanchor] == "x"
		@test _m2v3_axis(plot_polygons(_M2V3_QX, _M2V3_QY, _M2V3_QUADS), :yaxis)[:scaleanchor] == "x"
		@test occursin("`equalar = false` by default", string(Base.Docs.doc(plot_pcolormesh)))
	end

	@testset "Y5 mesh SubplotFigure delegate: errors name the function, colour axes transplant" begin
		sf = subplots(1, 2; sync = false)
		@test _m2_throws(() -> plot_pcolormesh!(sf, 0:3, 0:2, rand(3, 2); row = 1, col = 1, show = true),
			"plot_pcolormesh!: mutators do not take `show`")
		@test _m2_throws(() -> plot_tricontour!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [1.0, 2, 3]; row = 1, col = 1, bogus = 1),
			"plot_tricontour!: unsupported keyword argument(s) `bogus`")
		@test isempty(_M2._plot_data(sf))
		@test_logs (:warn, r"plot_polygons!: per-subplot plot_\*! ignores figure-level keyword") plot_polygons!(
			sf, _M2V3_QX, _M2V3_QY, _M2V3_QUADS, [0.2, 0.9]; row = 1, col = 1, title = "t")
		# A numbered colour axis is transplanted by the delegate (no separate
		# transaction) and shared by a second call on another cell.
		plot_pcolormesh!(sf, 0:3, 0:2, [1.0 2; 3 4; 5 6]; row = 1, col = 2, coloraxis = "coloraxis2")
		ca = _m2v3_d(_m2v3_layout(sf)[:coloraxis2])
		@test ca[:cmin] == 1 && ca[:cmax] == 6
		@test _M2._plot_data(sf)[end].fields[:xaxis] == "x2"
		plot_tripcolor!(sf, _M2V3_TX, _M2V3_TY, _M2V3_TRI, [2.0, 3, 4]; row = 1, col = 1, coloraxis = "coloraxis2")
		@test _m2v3_d(_m2v3_layout(sf)[:coloraxis2])[:cmax] == 6
		# A log cell: coordinates are checked against the cell's axis type.
		relayout!(sf.plot; xaxis2 = attr(type = "log"))
		@test _m2_throws(() -> plot_pcolormesh!(sf, 0:3, 0:2, rand(3, 2); row = 1, col = 2), "plot_pcolormesh!")
	end
end

@testset "sci mesh2d: wave 5 (fields)" begin
	@testset "Z84 rectilinear plot_pcolormesh validates the cell values in place" begin
		C = rand(1000, 1000)
		Cn = rand(1001, 1001)
		Cm = Matrix{Union{Missing, Float64}}(C)
		Cm[3, 7] = missing
		# Warm up (compilation is not counted).
		for _ in 1:2
			_M2._mesh2d_cell_values(C, 1001, 1001, "t")
			_M2._mesh2d_cell_values(Cn, 1001, 1001, "t")
			_M2._mesh2d_cell_values(Cm, 1001, 1001, "t")
			plot_pcolormesh(0:1000, 0:1000, C)
		end
		# One Float64 matrix per cell value (8 MB here), read straight from `C`:
		# no Matrix{Any} copy and no boxing per entry (either costs 8 MB or
		# more). 1 MiB covers the array headers and what the allocator adds in
		# a long test process (the count is 16.04 MB alone and was 16.40 MB in
		# the full suite; 64 KiB failed there).
		slack = 2^20
		@test @allocated(_M2._mesh2d_cell_values(C, 1001, 1001, "t")) <= sizeof(C) + slack
		@test @allocated(_M2._mesh2d_cell_values(Cm, 1001, 1001, "t")) <= sizeof(C) + slack
		# Node values: the node matrix and the cell means.
		@test @allocated(_M2._mesh2d_cell_values(Cn, 1001, 1001, "t")) <= sizeof(Cn) + sizeof(C) + slack
		v = _M2._mesh2d_cell_values(Cm, 1001, 1001, "t")
		@test v isa Matrix{Float64} && isnan(v[3, 7]) && v[1, 1] == C[1, 1]
		# The whole call: the validated values (8 MB, also the colour values
		# under a linear norm), the trace's z rows (about 9 MB, kept) and small
		# bookkeeping. The 1.x path held a Matrix{Any} copy and a second pass
		# (about 168 MB); 4x the input is a guard well below that.
		@test @allocated(plot_pcolormesh(0:1000, 0:1000, C)) < 4 * sizeof(C)
		# The values themselves are unchanged by the in-place path.
		z = plot_pcolormesh(0:2, 0:2, [1.0 NaN; 3.0 4.0]).data[1].fields[:z]
		@test z == [[1.0, 3.0], [nothing, 4.0]]
		@test _m2_throws(() -> plot_pcolormesh(0:2, 0:2, Any[1.0 "a"; 3.0 4.0]), "plot_pcolormesh: colour values must be real numbers or missing; entry 3 is \"a\"")
	end
end
