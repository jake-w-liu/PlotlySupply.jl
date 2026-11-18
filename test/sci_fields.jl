using Test, PlotlySupply
using PlotlySupply: PlotlyBase

# 2-D fields: plot_heatmap, plot_contour, plot_quiver, plot_image (src/api.jl)
# and plot_matrix, plot_streamlines (src/sci/fields.jl). Audit-finding
# regressions live in test/regression_fields.jl.

const _SF_JSON = PlotlyBase.JSON

# Serialise as the export and window paths do: non-finite numbers become null.
_sf_roundtrip(x) = _SF_JSON.parse(_SF_JSON.json(x; PlotlySupply._JSON_NONFINITE_AS_NULL...))

function _sf_thrown(f)
	try
		f()
	catch err
		return err
	end
	return nothing
end

_sf_message(f) = (err = _sf_thrown(f); err === nothing ? "" : sprint(showerror, err))

_sf_axis(fig, key) = _sf_roundtrip(fig.layout)[String(key)]

# A SyncPlot whose renderer only records the scripts it is sent.
function _sf_headless_syncplot(p::Plot)
	scripts = String[]
	backend = (
		isopen = window -> true,
		close = window -> nothing,
		run = (window, script) -> (push!(scripts, script); "ok"),
	)
	resources = PlotlySupply._SyncPlotResources(nothing, backend)
	return SyncPlot(p, nothing, nothing, "fields-probe", resources), scripts
end

@testset "sci fields" begin
	# Asymmetric analytic field on a non-square, non-uniform grid: the value
	# at (x[ix], y[iy]) is x + 10 y, so any transposition is detectable.
	x = [0.0, 1.0, 3.0, 6.0]
	y = [10.0, 20.0, 40.0]
	U = [xi + 10 * yi for xi in x, yi in y]          # U[ix, iy], size (4, 3)
	expected(ix, iy) = x[ix] + 10 * y[iy]

	@testset "heatmap: U[ix, iy] orientation" begin
		fig = plot_heatmap(x, y, U)
		t = _sf_roundtrip(fig.data[1])
		@test t["type"] == "heatmap"
		@test t["transpose"] == true             # plotly reads z[ix][iy]
		@test t["x"] == x && t["y"] == y
		@test length(t["z"]) == 4 && all(length(row) == 3 for row in t["z"])
		@test all(t["z"][ix][iy] == expected(ix, iy) for ix in 1:4, iy in 1:3)
		# Cell edges (one more coordinate than cells) are accepted.
		edges = plot_heatmap([0.0, 1, 2, 4, 8], [0.0, 1, 3, 9], U)
		@test edges.data[1].fields[:x] == [0.0, 1, 2, 4, 8]
		# Implicit axes are the 0-based indices.
		implicit = plot_heatmap(U)
		@test collect(implicit.data[1].fields[:x]) == 0:3
		@test collect(implicit.data[1].fields[:y]) == 0:2
		# Ranges, SubArrays and adjoints are accepted as they are.
		sub = view(U, 1:3, :)
		fig_sub = plot_heatmap(x[1:3], 1:3, sub)
		@test _sf_roundtrip(fig_sub.data[1])["z"][3] == [U[3, 1], U[3, 2], U[3, 3]]
		fig_adj = plot_heatmap(y, x, U')
		@test _sf_roundtrip(fig_adj.data[1])["z"][2] == [U[1, 2], U[2, 2], U[3, 2], U[4, 2]]
	end

	@testset "heatmap: shape and data validation" begin
		msg = _sf_message(() -> plot_heatmap(x, y, permutedims(U)))
		@test occursin("plot_heatmap", msg)
		@test occursin("(length(x), length(y)) = (4, 3)", msg)
		@test occursin("got size(U) = (3, 4)", msg)
		@test occursin("permutedims(U)", msg)
		msg = _sf_message(() -> plot_heatmap(x, y[1:2], U))
		@test occursin("(4, 2)", msg) && !occursin("permutedims", msg)
		X = [xi for xi in x, yi in y]
		Y = [yi for xi in x, yi in y]
		msg = _sf_message(() -> plot_heatmap(X, Y, U))
		@test occursin("must be a vector of coordinates", msg)
		@test occursin("meshgrid", msg)
		msg = _sf_message(() -> plot_heatmap(x, y, complex.(U)))
		@test occursin("complex-valued", msg) && occursin("abs.(U)", msg)
		@test _sf_thrown(() -> plot_heatmap(x, y, Any[1 2 3; "a" 2 3; 1 2 3; 1 2 3])) isa ArgumentError
		@test _sf_thrown(() -> plot_heatmap([0.0, NaN, 1.0, 2.0], y, U)) isa ArgumentError
		@test _sf_thrown(() -> plot_heatmap([true, false, true, false], y, U)) isa ArgumentError
		@test _sf_thrown(() -> plot_heatmap(x, y, rand(4, 3, 2))) isa ArgumentError
		# Gaps: NaN and missing serialize as null.
		G = Union{Missing, Float64}[1.0 missing; NaN 4.0]
		t = _sf_roundtrip(plot_heatmap(G).data[1])
		@test t["z"] == [[1.0, nothing], [nothing, 4.0]]
		# Bool masks are drawn as 0/1.
		mask = [true false; false true; true true]
		zb = _sf_roundtrip(plot_heatmap(mask).data[1])["z"]
		@test zb == [[1, 0], [0, 1], [1, 1]]
		# Categorical and date coordinates pass through.
		cat = plot_heatmap(["a", "b", "c", "d"], ["p", "q", "r"], U)
		@test cat.data[1].fields[:x] == ["a", "b", "c", "d"]
	end

	@testset "heatmap: log axes and positive coordinates" begin
		fig = plot_heatmap(U; xscale = "log")
		@test collect(fig.data[1].fields[:x]) == 1:4           # no index 0 on a log axis
		@test collect(fig.data[1].fields[:y]) == 0:2
		@test _sf_axis(fig, :xaxis)["type"] == "log"
		msg = _sf_message(() -> plot_heatmap(x, y, U; xscale = "log"))
		@test occursin("logarithmic axis", msg) && occursin("positive", msg)
		base = plot_heatmap([1.0, 2.0, 4.0, 8.0], y, U; xscale = "log")
		plot_heatmap!(base, U)                                  # inherits the log x axis
		@test collect(base.data[2].fields[:x]) == 1:4
	end

	@testset "heatmap: colour mapping (C21)" begin
		fig = plot_heatmap(x, y, U; colorscale = "Viridis")
		cs = fig.data[1].fields[:colorscale]
		@test cs isa AbstractVector && length(cs) > 2
		@test cs[1][1] == 0 && uppercase(cs[1][2]) == "#440154"
		@test cs[end][1] == 1 && uppercase(cs[end][2]) == "#FDE725"
		msg = _sf_message(() -> plot_heatmap(x, y, U; colorscale = "NoSuchMap"))
		@test occursin("NoSuchMap", msg)
		t = _sf_roundtrip(plot_heatmap(x, y, U; crange = (0, 500)).data[1])
		@test t["zmin"] == 0 && t["zmax"] == 500
		t = _sf_roundtrip(plot_heatmap(x, y, U; zrange = [0, 500]).data[1])
		@test t["zmin"] == 0 && t["zmax"] == 500
		msg = _sf_message(() -> plot_heatmap(x, y, U; zrange = [0, 1], crange = [0, 2]))
		@test occursin("alias", msg)
		@test _sf_thrown(() -> plot_heatmap(x, y, U; crange = [1])) isa ArgumentError
		@test _sf_thrown(() -> plot_heatmap(x, y, U; crange = [2, 1])) isa ArgumentError
		t = _sf_roundtrip(plot_heatmap(x, y, U; cmid = 0).data[1])
		@test t["zmid"] == 0
		# Explicit crange + cmid: TwoSlopeNorm, colour 0.5 sits at cmid.
		fig = plot_heatmap(x, y, U; crange = (0, 400), cmid = 100, colorscale = "RdBu_r")
		stops = fig.data[1].fields[:colorscale]
		centre = PlotlySupply._sample_colorscale("RdBu_r", 0.5)
		@test any(s -> isapprox(s[1], 0.25; atol = 1e-12), stops)
		@test PlotlySupply._sample_colorscale(stops, 0.25) == centre
		# Log norm: log10 values, raw values in the hover text, decade ticks.
		L = [10.0^(ix + iy) for ix in 1:4, iy in 1:3]
		t = _sf_roundtrip(plot_heatmap(x, y, L; colornorm = :log).data[1])
		@test t["z"][2][3] ≈ 5.0
		@test t["customdata"][3][2] ≈ 1e5                      # customdata[iy][ix]
		@test occursin("customdata", t["hovertemplate"])
		@test t["colorbar"]["tickmode"] == "array"
		@test any(==("10<sup>3</sup>"), t["colorbar"]["ticktext"])
		@test _sf_thrown(() -> plot_heatmap(x, y, U; colornorm = :sqrt)) isa ArgumentError
		# Discrete levels (BoundaryNorm).
		t = _sf_roundtrip(plot_heatmap(x, y, U; levels = [0, 100, 200, 500]).data[1])
		@test t["zmin"] == 0 && t["zmax"] == 500
		@test t["colorbar"]["tickvals"] == [0, 100, 200, 500]
		@test length(t["colorscale"]) == 6
		# Colorbar options.
		t = _sf_roundtrip(plot_heatmap(x, y, U; showscale = false, colorbar_title = "\$E_z\$",
			colorbar_ticks = [0, 250], colorbar_ticklabels = ["lo", "hi"]).data[1])
		@test t["showscale"] == false
		@test t["colorbar"]["title"]["text"] == "\$E_z\$"
		@test t["colorbar"]["tickvals"] == [0, 250] && t["colorbar"]["ticktext"] == ["lo", "hi"]
		@test _sf_thrown(() -> plot_heatmap(x, y, U; colorbar_ticklabels = ["a"])) isa ArgumentError
		# Shared coloraxis.
		fig = plot_heatmap(x, y, U; coloraxis = :shared, crange = (0, 500), colorscale = "Viridis",
			colorbar_title = "c")
		t = _sf_roundtrip(fig.data[1])
		@test t["coloraxis"] == "coloraxis"
		@test !haskey(t, "colorscale") && !haskey(t, "zmin")
		ca = _sf_axis(fig, :coloraxis)
		@test ca["cmin"] == 0 && ca["cmax"] == 500
		@test ca["colorbar"]["title"]["text"] == "c"
		plot_heatmap!(fig, x, y, 2 .* U; coloraxis = :shared)
		@test fig.data[2].fields[:coloraxis] == "coloraxis"
		@test _sf_thrown(() -> plot_heatmap(x, y, U; coloraxis = "axis9")) isa ArgumentError
	end

	@testset "heatmap: text, origin, gaps, grid (C26/F27)" begin
		T = [string("ix", ix, "iy", iy) for ix in 1:4, iy in 1:3]
		t = _sf_roundtrip(plot_heatmap(x, y, U; text = T, textsize = 9).data[1])
		# plotly reads text[iy][ix] (it does not transpose text).
		@test all(t["text"][iy][ix] == "ix$(ix)iy$(iy)" for ix in 1:4, iy in 1:3)
		@test t["texttemplate"] == "%{text}"
		@test t["textfont"]["size"] == 9
		t = _sf_roundtrip(plot_heatmap(x, y, U; texttemplate = "%{z:.1f}").data[1])
		@test t["texttemplate"] == "%{z:.1f}" && !haskey(t, "text")
		multiline = _sf_roundtrip(plot_heatmap([1, 2], [1], reshape([1.0, 2.0], 2, 1);
			text = reshape(["a\nb", "c"], 2, 1)).data[1])
		@test multiline["text"][1] == ["a<br>b", "c"]
		msg = _sf_message(() -> plot_heatmap(x, y, U; text = fill("a", 3, 4)))
		@test occursin("text", msg) && occursin("(4, 3)", msg)
		@test !haskey(_sf_axis(plot_heatmap(x, y, U), :yaxis), "autorange")
		@test _sf_axis(plot_heatmap(x, y, U; origin = :upper), :yaxis)["autorange"] == "reversed"
		up = plot_heatmap(x, y, U; origin = :upper, yrange = (10, 40))
		@test _sf_axis(up, :yaxis)["range"] == [40, 10]
		@test _sf_thrown(() -> plot_heatmap(x, y, U; origin = :middle)) isa ArgumentError
		fig = plot_heatmap(x, y, U; origin = :upper)
		plot_heatmap!(fig, x, y, U; origin = :lower)
		@test _sf_axis(fig, :yaxis)["autorange"] == true
		t = _sf_roundtrip(plot_heatmap(x, y, U; xgap = 1, ygap = 2).data[1])
		@test t["xgap"] == 1 && t["ygap"] == 2
		@test _sf_thrown(() -> plot_heatmap(x, y, U; xgap = -1)) isa ArgumentError
		fig = plot_heatmap(x, y, U; grid = false)
		@test _sf_axis(fig, :xaxis)["showgrid"] == false
		@test _sf_axis(fig, :yaxis)["showgrid"] == false
		plot_heatmap!(fig, x, y, U; grid = true)
		@test _sf_axis(fig, :xaxis)["showgrid"] == true
	end

	@testset "heatmap: figure options" begin
		fig = plot_heatmap(x, y, U; title = "T", xlabel = "\$x\$ (m)", ylabel = "y", xrange = [0, 6],
			yrange = (10, 40), xticks = [0, 3, 6], xticklabels = ["a", "b", "c"], ytickformat = ".1f",
			width = 600, height = 400, fontsize = 14, equalar = true)
		l = _sf_roundtrip(fig.layout)
		@test l["title"]["text"] == "T"
		@test l["xaxis"]["title"]["text"] == PlotlySupply._label("\$x\$ (m)")
		@test l["xaxis"]["range"] == [0, 6] && l["yaxis"]["range"] == [10, 40]
		@test l["xaxis"]["tickvals"] == [0, 3, 6] && l["xaxis"]["ticktext"] == ["a", "b", "c"]
		@test l["yaxis"]["tickformat"] == ".1f"
		@test l["width"] == 600 && l["height"] == 400 && l["font"]["size"] == 14
		@test l["yaxis"]["scaleanchor"] == "x" && l["yaxis"]["scaleratio"] == 1
		@test _sf_thrown(() -> plot_heatmap(x, y, U; xrange = [1])) isa ArgumentError
		@test _sf_thrown(() -> plot_heatmap(x, y, U; width = -1)) isa ArgumentError
		@test _sf_thrown(() -> plot_heatmap(x, y, U; xscale = "logarithmic")) isa ArgumentError
		@test _sf_thrown(() -> plot_heatmap(x, y, U; bogus = 1)) isa MethodError
	end

	@testset "heatmap!: mutator behaviour" begin
		fig = plot_heatmap(x, y, U; xlabel = "x")
		@test plot_heatmap!(fig, x, y, U; ylabel = "y2", xrange = (0, 3)) === nothing
		@test length(fig.data) == 2
		l = _sf_roundtrip(fig.layout)
		@test l["xaxis"]["title"]["text"] == "x"
		@test l["yaxis"]["title"]["text"] == "y2"
		@test l["xaxis"]["range"] == [0, 3]
		msg = _sf_message(() -> plot_heatmap!(fig, U; show = true))
		@test occursin("plot_heatmap!", msg) && occursin("show", msg)
		msg = _sf_message(() -> plot_heatmap!(fig, U; bogus = 1))
		@test occursin("unsupported keyword", msg) && occursin("bogus", msg)
		@test length(fig.data) == 2
		# A failed mutation leaves the figure unchanged.
		before = _SF_JSON.json(fig)
		@test _sf_thrown(() -> plot_heatmap!(fig, x, y, permutedims(U))) isa ArgumentError
		@test _SF_JSON.json(fig) == before
		# SyncPlot: one transaction.
		sp, scripts = _sf_headless_syncplot(plot_heatmap(x, y, U))
		@test plot_heatmap!(sp, x, y, U; colorscale = "Viridis") === nothing
		@test length(sp.plot.data) == 2
		@test _sf_thrown(() -> plot_heatmap!(sp, U; show = true)) isa ArgumentError
		@test length(sp.plot.data) == 2
	end

	@testset "contour: levels, coloring, labels (C25/F26)" begin
		fig = plot_contour(x, y, U)
		t = _sf_roundtrip(fig.data[1])
		@test t["type"] == "contour" && t["transpose"] == true
		@test all(t["z"][ix][iy] == expected(ix, iy) for ix in 1:4, iy in 1:3)
		# Uniform levels: one trace with start/end/size.
		t = _sf_roundtrip(plot_contour(x, y, U; levels = 100:100:400).data[1])
		@test t["autocontour"] == false
		@test t["contours"]["start"] == 100 && t["contours"]["end"] == 400
		@test t["contours"]["size"] ≈ 100
		# Integer levels / ncontours: a level count.
		@test _sf_roundtrip(plot_contour(x, y, U; levels = 7).data[1])["ncontours"] == 7
		@test _sf_roundtrip(plot_contour(x, y, U; ncontours = 5).data[1])["ncontours"] == 5
		@test _sf_thrown(() -> plot_contour(x, y, U; levels = 5, ncontours = 5)) isa ArgumentError
		@test _sf_thrown(() -> plot_contour(x, y, U; levels = [3, 2])) isa ArgumentError
		# Non-uniform filled levels: one constraint band per interval + a colorbar carrier.
		fig = plot_contour(x, y, U; levels = [100, 150, 300, 500], colorbar_title = "b")
		@test length(fig.data) == 4
		bands = [_sf_roundtrip(fig.data[k]) for k in 1:3]
		@test [b["contours"]["value"] for b in bands] == [[100, 150], [150, 300], [300, 500]]
		@test all(b["contours"]["type"] == "constraint" for b in bands)
		# plotly fills the region a constraint excludes: "][" fills the band.
		@test all(b["contours"]["operation"] == "][" for b in bands)
		@test length(unique(b["fillcolor"] for b in bands)) == 3
		@test all(b["showscale"] == false && b["showlegend"] == false for b in bands)
		# Band lines/labels use plotly's level-contour colour, not the fill colour.
		@test all(b["line"]["color"] == "#000" && b["line"]["width"] == 0 for b in bands)
		labelled = plot_contour(x, y, U; levels = [100, 150, 300, 500], showlabels = true)
		@test all(_sf_roundtrip(t)["contours"]["labelfont"]["color"] == "#000" for t in labelled.data[1:3])
		white = plot_contour(x, y, U; levels = [100, 150, 300, 500], showlabels = true,
			linecolor = "white", coloring = :fill, linewidth = 1)
		wt = _sf_roundtrip(white.data[1])
		@test wt["line"]["color"] == "white" && wt["contours"]["labelfont"]["color"] == "white"
		carrier = _sf_roundtrip(fig.data[4])
		@test carrier["marker"]["cmin"] == 100 && carrier["marker"]["cmax"] == 500
		@test carrier["marker"]["colorbar"]["title"]["text"] == "b"
		@test carrier["marker"]["colorbar"]["tickvals"] == [100, 150, 300, 500]
		# Non-uniform line levels: one trace per level, each in its level's
		# colour (G15: plotly would draw a single-level trace in one end colour),
		# plus one colorbar carrier with ticks at the levels.
		fig = plot_contour(x, y, U; levels = [100, 150, 300], coloring = :lines)
		@test length(fig.data) == 4
		level_traces = [_sf_roundtrip(t) for t in fig.data[1:3]]
		vals = [t["contours"] for t in level_traces]
		@test [(c["start"], c["end"]) for c in vals] == [(100, 100), (150, 150), (300, 300)]
		@test all(c["coloring"] == "none" for c in vals)
		@test length(unique(t["line"]["color"] for t in level_traces)) == 3
		line_carrier = _sf_roundtrip(fig.data[4])
		@test line_carrier["type"] == "scatter" && line_carrier["marker"]["colorbar"]["tickvals"] == [100, 150, 300]
		# A single labelled level in one colour (overlay style).
		t = _sf_roundtrip(plot_contour(x, y, U; levels = [200], linecolor = "white", showlabels = true,
			labelformat = ".0f", linewidth = 2, dash = :dash).data[1])
		@test t["contours"]["coloring"] == "none"
		@test t["contours"]["start"] == 200 && t["contours"]["end"] == 200
		@test t["contours"]["showlabels"] == true && t["contours"]["labelformat"] == ".0f"
		@test t["line"] == Dict("color" => "white", "width" => 2, "dash" => "dash")
		@test t["showscale"] == false && t["showlegend"] == false
		@test _sf_thrown(() -> plot_contour(x, y, U; linecolor = "white", coloring = :lines)) isa ArgumentError
		@test _sf_thrown(() -> plot_contour(x, y, U; coloring = :stripes)) isa ArgumentError
		@test _sf_thrown(() -> plot_contour(x, y, U; dash = "wiggly")) isa ArgumentError
		@test _sf_thrown(() -> plot_contour(x, y, U; linecolor = "notacolour")) isa ArgumentError
		@test _sf_thrown(() -> plot_contour(x, y, U; levels = [1.0], coloring = :fill)) isa ArgumentError
		# Contours need one value per grid point (no cell edges).
		@test _sf_thrown(() -> plot_contour([0.0, 1, 2, 4, 8], [0.0, 1, 3, 9], U)) isa ArgumentError
		@test _sf_thrown(() -> plot_contour(x, y, complex.(U))) isa ArgumentError
		implicit = plot_contour(U; yscale = "log")
		@test collect(implicit.data[1].fields[:y]) == 1:3
	end

	@testset "contour!: overlay on a heatmap" begin
		fig = plot_heatmap(x, y, U; colorscale = "RdBu_r")
		@test plot_contour!(fig, x, y, U; levels = [150.0], linecolor = "white", showlabels = true) === nothing
		t = _sf_roundtrip(fig.data[2])
		@test t["showscale"] == false && t["showlegend"] == false
		@test t["line"]["color"] == "white"
		@test _sf_thrown(() -> plot_contour!(fig, U; show = true)) isa ArgumentError
		@test length(fig.data) == 2
	end

	@testset "quiver: geometry, gaps and naming" begin
		fig = plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 0.0], [0.0, 2.0])
		t = fig.data[1].fields
		# Shafts: the longest arrow is 2/3 * sizeref; others scale linearly.
		@test t[:x][1:2] ≈ [0.0, 1 / 3] && t[:y][1:2] ≈ [0.0, 0.0]
		@test t[:x][8:9] ≈ [1.0, 1.0] && t[:y][8:9] ≈ [1.0, 5 / 3]
		@test count(isnothing, t[:x]) == 4 && t[:x][3] === nothing
		json = _SF_JSON.json(fig)
		@test !occursin("NaN", json)
		@test t[:showlegend] == false
		half = plot_quiver([0.0], [0.0], [3.0], [4.0]; sizeref = 0.3)
		hx, hy = half.data[1].fields[:x], half.data[1].fields[:y]
		@test hypot(hx[2] - hx[1], hy[2] - hy[1]) ≈ 0.2
		# Named quiver traces appear in the legend under that name.
		named = plot_quiver([0.0], [0.0], [1.0], [1.0]; legend = "velocity", color = :red, linewidth = 2)
		nt = _sf_roundtrip(named.data[1])
		@test nt["name"] == "velocity" && nt["showlegend"] == true
		@test nt["line"] == Dict("color" => "red", "width" => 2)
		@test _sf_thrown(() -> plot_quiver([0.0], [0.0], [1.0], [1.0]; color = "nope")) isa ArgumentError
		@test _sf_thrown(() -> plot_quiver([0.0], [0.0], [1.0], [1.0]; sizeref = -1)) isa ArgumentError
		@test isempty(plot_quiver([0.0], [0.0], [1.0], [1.0]; sizeref = 0).data[1].fields[:x])
		@test _sf_thrown(() -> plot_quiver([0.0, 1.0], [0.0], [1.0], [1.0])) isa ArgumentError
		@test _sf_thrown(() -> plot_quiver([0.0], [0.0], [1.0im], [1.0])) isa ArgumentError
		skipped = @test_logs (:warn, r"skipped 1 vector") plot_quiver([0.0, 1.0], [0.0, 0.0], [NaN, 1.0], [1.0, 0.0])
		@test length(skipped.data[1].fields[:x]) == 7
	end

	@testset "quiver: grid forms, orientation and aspect" begin
		qx = [0.0, 1.0, 3.0]
		qy = [0.0, 2.0]
		qu = [1.0 * ix for ix in 1:3, iy in 1:2]                 # u[ix, iy] = ix
		qv = [1.0 * iy for ix in 1:3, iy in 1:2]                 # v[ix, iy] = iy
		fig = plot_quiver(qx, qy, qu, qv)
		px = fig.data[1].fields[:x]
		py = fig.data[1].fields[:y]
		starts = [(px[k], py[k]) for k in 1:7:length(px)]
		@test length(starts) == 6
		# Each arrow starts at its grid point and points along (u, v) there.
		for (k, (ix, iy)) in enumerate(((ix, iy) for iy in 1:2 for ix in 1:3))
			base = 7 * (k - 1) + 1
			@test (px[base], py[base]) == (qx[ix], qy[iy])
			dx, dy = px[base + 1] - px[base], py[base + 1] - py[base]
			@test atan(dy, dx) ≈ atan(qv[ix, iy], qu[ix, iy])
		end
		@test _sf_axis(fig, :yaxis)["scaleanchor"] == "x"
		@test !haskey(_sf_axis(plot_quiver(qx, qy, qu, qv; equalar = false), :yaxis), "scaleanchor")
		msg = _sf_message(() -> plot_quiver(qx, qy, permutedims(qu), permutedims(qv)))
		@test occursin("(length(x), length(y)) = (3, 2)", msg) && occursin("permutedims(u)", msg)
		# Equal element counts pair element by element (column-major), as before 2.0:
		# meshgrid matrices with flattened components, or flattened coordinates.
		QX = [xi for xi in qx, yi in qy]
		QY = [yi for xi in qx, yi in qy]
		mixed = plot_quiver(QX, QY, vec(qu), vec(qv)).data[1].fields
		@test mixed[:x] == fig.data[1].fields[:x] && mixed[:y] == fig.data[1].fields[:y]
		flat = plot_quiver(vec(QX), vec(QY), qu, qv).data[1].fields
		@test flat[:x] == fig.data[1].fields[:x] && flat[:y] == fig.data[1].fields[:y]
		@test _sf_thrown(() -> plot_quiver(QX, QY, permutedims(qu), permutedims(qv))) isa ArgumentError
		# Logarithmic axes: arrows keep their screen proportions, origins must be positive.
		lg = plot_quiver([1.0, 10.0], [1.0, 1.0], [1.0, 1.0], [0.0, 0.0]; xscale = "log")
		lx = lg.data[1].fields[:x]
		@test lx[2] / lx[1] ≈ lx[9] / lx[8]                      # equal decades
		@test _sf_axis(lg, :xaxis)["type"] == "log"
		@test _sf_thrown(() -> plot_quiver([0.0], [1.0], [1.0], [1.0]; xscale = "log")) isa ArgumentError
	end

	@testset "quiver!: overlay and validation" begin
		fig = plot_heatmap(x, y, U; xlabel = "x")
		@test plot_quiver!(fig, [1.0], [20.0], [1.0], [0.0]; legend = "E") === nothing
		@test fig.data[2].fields[:name] == "E"
		@test _sf_axis(fig, :yaxis)["scaleanchor"] == "x"
		fig2 = plot_heatmap(x, y, U)
		plot_quiver!(fig2, [1.0], [20.0], [1.0], [0.0]; equalar = false)
		@test !haskey(_sf_axis(fig2, :yaxis), "scaleanchor")
		@test _sf_thrown(() -> plot_quiver!(fig2, [1.0], [1.0], [1.0], [1.0]; show = true)) isa ArgumentError
		@test length(fig2.data) == 2
	end

	@testset "image: data forms and colour models" begin
		rgb = zeros(UInt8, 2, 3, 3)
		rgb[1, 1, 1] = 255                                      # top-left red
		rgb[2, 3, 3] = 255                                      # bottom-right blue
		fig = plot_image(rgb)
		t = _sf_roundtrip(fig.data[1])
		@test t["z"][1][1] == [255, 0, 0] && t["z"][2][3] == [0, 0, 255]
		@test !haskey(t, "colormodel")
		# row 1 at the top: finalize pins the image's pixel edges, descending
		yr = _sf_axis(fig, :yaxis)["range"]
		@test _sf_axis(fig, :yaxis)["autorange"] == false && yr[1] > yr[2]
		@test _sf_axis(fig, :yaxis)["scaleanchor"] == "x"        # square pixels
		rgba = zeros(UInt8, 2, 2, 4)
		@test plot_image(rgba).data[1].fields[:colormodel] == "rgba256"
		@test plot_image(zeros(2, 2, 4)).data[1].fields[:colormodel] == "rgba"
		@test plot_image(rgba; colormodel = :rgba).data[1].fields[:colormodel] == "rgba"
		@test plot_image(rgb; colormodel = "hsl").data[1].fields[:colormodel] == "hsl"
		@test occursin("needs 4 channels", _sf_message(() -> plot_image(rgb; colormodel = "rgba")))
		@test _sf_thrown(() -> plot_image(rgb; colormodel = "cmyk")) isa ArgumentError
		msg = _sf_message(() -> plot_image(rand(3, 3)))
		@test occursin("plot_heatmap", msg)
		@test _sf_thrown(() -> plot_image(rand(3))) isa ArgumentError
		@test _sf_thrown(() -> plot_image(rand(2, 2, 3, 1))) isa ArgumentError
		@test _sf_thrown(() -> plot_image(zeros(UInt8, 2, 2, 2))) isa ArgumentError
		@test _sf_thrown(() -> plot_image(zeros(ComplexF64, 2, 2, 3))) isa ArgumentError
		@test _sf_thrown(() -> plot_image(zeros(UInt8, 0, 2, 3))) isa ArgumentError
		# Nested rows of pixels and matrices of pixel vectors.
		nested = [[[255, 0, 0], [0, 255, 0]], [[0, 0, 255], [9, 9, 9]]]
		@test _sf_roundtrip(plot_image(nested).data[1])["z"] == nested
		pixels = reshape([[255, 0, 0, 255], [0, 0, 255, 0], [0, 255, 0, 128], [9, 9, 9, 9]], 2, 2)
		tm = _sf_roundtrip(plot_image(pixels).data[1])
		@test tm["z"][1][2] == [0, 255, 0, 128] && tm["z"][2][1] == [0, 0, 255, 0]
		@test tm["colormodel"] == "rgba"
		@test _sf_thrown(() -> plot_image([[[1, 2, 3]], [[1, 2, 3], [4, 5, 6]]])) isa ArgumentError
		@test _sf_thrown(() -> plot_image([[[1, 2, 3], [1, 2]]])) isa ArgumentError
		# Colors.jl colour matrices (Images.jl): bytes, alpha kept.
		C = PlotlySupply.Colors
		img = [C.RGB(1, 0, 0) C.RGB(0, 1, 0); C.RGB(0, 0, 1) C.RGB(1, 1, 1)]
		tc = _sf_roundtrip(plot_image(img).data[1])
		@test tc["z"][1][2] == [0, 255, 0] && tc["z"][2][1] == [0, 0, 255]
		imga = [C.RGBA(1, 0, 0, 0.5) C.RGBA(0, 1, 0, 1)]
		ta = _sf_roundtrip(plot_image(imga).data[1])
		@test ta["z"][1][1] == [255, 0, 0, 128] && ta["colormodel"] == "rgba256"
		gray = [C.Gray(0.0) C.Gray(1.0)]
		@test _sf_roundtrip(plot_image(gray).data[1])["z"][1][2] == [255, 255, 255]
	end

	@testset "image: extent and origin (C32)" begin
		img = zeros(UInt8, 2, 4, 3)
		img[1, 1, 1] = 255                                      # row 1, column 1
		fig = plot_image(img; extent = (0, 4, 0, 2))
		t = fig.data[1].fields
		@test t[:x0] == 0.5 && t[:dx] == 1.0
		@test t[:y0] == 0.5 && t[:dy] == 1.0
		yax = _sf_axis(fig, :yaxis)
		@test yax["autorange"] == false && yax["range"] == [0.0, 2.0]   # bottom < top: y points up
		# Rows are flipped so row 1 lands at y0 + 1 * dy = 1.5, the top row.
		tz = _sf_roundtrip(fig.data[1])["z"]
		@test tz[2][1] == [255, 0, 0] && tz[1][1] == [0, 0, 0]
		low = plot_image(img; extent = (0, 4, 0, 2), origin = :lower)
		lt = low.data[1].fields
		@test lt[:y0] == 0.5 && lt[:dy] == 1.0                   # row 1 at the bottom
		@test _sf_roundtrip(low.data[1])["z"][1][1] == [255, 0, 0]
		rev = plot_image(img; extent = (4, 0, 0, 2))
		rt = _sf_roundtrip(rev.data[1])
		@test rt["x0"] == 0.5 && rt["dx"] == 1.0
		@test rt["z"][2][4] == [255, 0, 0]                       # column 1 at x = 3.5 (left = 4)
		@test _sf_axis(rev, :xaxis)["autorange"] == false && _sf_axis(rev, :xaxis)["range"] == [4.0, 0.0]
		@test _sf_thrown(() -> plot_image(img; extent = (0, 0, 0, 2))) isa ArgumentError
		@test _sf_thrown(() -> plot_image(img; extent = (0, 1, 2))) isa ArgumentError
		@test _sf_thrown(() -> plot_image(img; extent = (0, 1, 0, Inf))) isa ArgumentError
		low_y = _sf_axis(plot_image(img; origin = :lower), :yaxis)
		@test low_y["autorange"] == false && low_y["range"] == [-0.5, 1.5]
		@test _sf_thrown(() -> plot_image(img; origin = :left)) isa ArgumentError
		# The mutator keeps the axis direction unless asked.
		fig = plot_heatmap(x, y, U)
		@test plot_image!(fig, img) === nothing
		# (no direction was given: plotly shows the image's row 1 at the top, and
		# finalize pins the axis the way plotly would draw it, descending)
		keep = _sf_axis(fig, :yaxis)["range"]
		@test _sf_axis(fig, :yaxis)["autorange"] == false && keep[1] > keep[2]
		plot_image!(fig, img; origin = :upper)
		up = _sf_axis(fig, :yaxis)["range"]
		@test _sf_axis(fig, :yaxis)["autorange"] == false && up[1] > up[2]
		@test _sf_thrown(() -> plot_image!(fig, img; show = true)) isa ArgumentError
		@test length(fig.data) == 3
	end

	@testset "plot_matrix (F28)" begin
		A = [1.0 2.0 3.0 4.0 5.0; 6.0 7.0 8.0 9.0 10.0; 11.0 12.0 13.0 14.0 15.0]
		fig = plot_matrix(A; xlabels = ["a", "b", "c", "d", "e"], ylabels = [:r1, :r2, :r3])
		tr = fig.data[1]
		t = _sf_roundtrip(tr)
		@test collect(tr.fields[:x]) == 1:5 && collect(tr.fields[:y]) == 1:3
		# z[ix][iy] (transpose = true): column j is x = j, row i is y = i.
		@test all(t["z"][j][i] == A[i, j] for i in 1:3, j in 1:5)
		@test t["texttemplate"] == "%{z:.2f}"
		l = _sf_roundtrip(fig.layout)
		@test l["yaxis"]["autorange"] === false && l["yaxis"]["range"][1] > l["yaxis"]["range"][2]  # K4: pinned descending, row 1 at the top
		@test l["xaxis"]["tickvals"] == 1:5 && l["xaxis"]["ticktext"] == ["a", "b", "c", "d", "e"]
		@test l["yaxis"]["ticktext"] == ["r1", "r2", "r3"]
		@test l["yaxis"]["scaleanchor"] == "x"
		@test t["colorscale"] == _sf_roundtrip(plot_heatmap(A; colorscale = "RdBu_r").data[1])["colorscale"]
		@test !haskey(_sf_roundtrip(plot_matrix(A; annotate = false).data[1]), "texttemplate")
		@test _sf_roundtrip(plot_matrix(A; fmt = ".0f").data[1])["texttemplate"] == "%{z:.0f}"
		labels = [string(i, ",", j) for i in 1:3, j in 1:5]
		tl = _sf_roundtrip(plot_matrix(A; text = labels).data[1])
		@test all(tl["text"][i][j] == "$i,$j" for i in 1:3, j in 1:5)
		@test tl["texttemplate"] == "%{text}"
		tc = _sf_roundtrip(plot_matrix(A; crange = (-15, 15), cmid = 0, colorbar_title = "v").data[1])
		@test tc["zmin"] == -15 && tc["zmax"] == 15
		@test tc["colorbar"]["title"]["text"] == "v"
		@test occursin("one label per column (5)", _sf_message(() -> plot_matrix(A; xlabels = ["a"])))
		@test _sf_thrown(() -> plot_matrix(A; text = fill("x", 5, 3))) isa ArgumentError
		@test _sf_thrown(() -> plot_matrix(A; fmt = "")) isa ArgumentError
		@test _sf_thrown(() -> plot_matrix(complex.(A))) isa ArgumentError
		big = plot_matrix(rand(40, 3))
		@test !haskey(_sf_axis(big, :yaxis), "tickvals")         # automatic ticks beyond 30 rows
		@test _sf_axis(big, :xaxis)["tickvals"] == 1:3
		fig = plot_heatmap(x, y, U)
		@test plot_matrix!(fig, A; xlabels = 1:5) === nothing
		@test length(fig.data) == 2
		@test _sf_thrown(() -> plot_matrix!(fig, A; show = true)) isa ArgumentError
	end

	@testset "plot_streamlines (F29)" begin
		sx = collect(range(-2.0, 2.0; length = 41))
		sy = collect(range(-1.0, 1.0; length = 21))
		# Uniform flow to +x: every streamline is horizontal and runs left to right.
		Uu = ones(41, 21)
		Vu = zeros(41, 21)
		fig = plot_streamlines(sx, sy, Uu, Vu)
		t = fig.data[1].fields
		@test t[:mode] == "lines+markers"
		lines = Vector{Vector{Tuple{Float64, Float64}}}([[]])
		for (px, py) in zip(t[:x], t[:y])
			px === nothing ? push!(lines, []) : push!(lines[end], (px, py))
		end
		filter!(!isempty, lines)
		@test length(lines) >= 5
		@test all(all(p[2] ≈ line[1][2] for p in line) for line in lines)
		@test all(issorted(first.(line)) for line in lines)
		@test all(-2 <= p[1] <= 2 && -1 <= p[2] <= 1 for line in lines for p in line)
		# One arrowhead per streamline, pointing along the flow.
		marker = _sf_roundtrip(fig.data[1])["marker"]
		@test count(>(0), marker["size"]) == length(lines)
		@test marker["symbol"] == "arrow" && marker["angleref"] == "previous"
		@test _sf_roundtrip(fig.data[1])["x"][end] === nothing
		# Counter-clockwise vortex (U, V) = (-y, x): positive angular motion.
		Uv = [-yi for xi in sx, yi in sy]
		Vv = [xi for xi in sx, yi in sy]
		vt = plot_streamlines(sx, sy, Uv, Vv; arrows = false).data[1].fields
		@test vt[:mode] == "lines"
		cross = 0.0
		steps = 0
		for k in 1:(length(vt[:x]) - 1)
			(vt[:x][k] === nothing || vt[:x][k + 1] === nothing) && continue
			cross += vt[:x][k] * vt[:y][k + 1] - vt[:x][k + 1] * vt[:y][k]
			steps += 1
		end
		@test steps > 100 && cross > 0
		# Explicit seeds, forward only: each line starts at its seed.
		seeded = plot_streamlines(sx, sy, Uu, Vu; seeds = [(-1.5, 0.25), (0.0, -0.5)], direction = :forward)
		st = seeded.data[1].fields
		@test st[:x][1] ≈ -1.5 && st[:y][1] ≈ 0.25
		gap = findfirst(isnothing, st[:x])
		@test st[:x][gap + 1] ≈ 0.0 atol = 1e-12
		@test st[:y][gap + 1] ≈ -0.5
		@test st[:x][gap - 1] ≈ 2.0                                # runs to the right edge
		short = plot_streamlines(sx, sy, Uu, Vu; seeds = [-1.5 0.25], direction = :forward, maxlength = 0.25)
		@test short.data[1].fields[:x][end - 1] ≈ -0.5 atol = 0.06  # 0.25 domain widths of 4
		@test _sf_thrown(() -> plot_streamlines(sx, sy, Uu, Vu; seeds = [(5.0, 0.0)])) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines(sx, sy, Uu, Vu; seeds = [1.0, 2.0])) isa ArgumentError
		# Colour by speed: binned traces + a colorbar carrier spanning the speeds.
		sp = plot_streamlines(sx, sy, Uv, Vv; colorby = :speed, colorscale = "Viridis", colorbar_title = "|v|")
		@test length(sp.data) >= 3
		carrier = _sf_roundtrip(sp.data[end])
		@test carrier["marker"]["colorbar"]["title"]["text"] == "|v|"
		@test 0 < carrier["marker"]["cmin"] < carrier["marker"]["cmax"] <= hypot(2, 1) + 1e-9
		@test all(_sf_roundtrip(tr)["line"]["color"] isa String for tr in sp.data[1:(end - 1)])
		@test count(tr -> tr.fields[:showlegend], sp.data) == 0
		@test _sf_thrown(() -> plot_streamlines(sx, sy, Uv, Vv; colorby = :speed, color = "red")) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines(sx, sy, Uv, Vv; colorscale = "Viridis")) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines(sx, sy, Uv, Vv; colorby = :angle)) isa ArgumentError
		# NaN marks regions without flow: no streamline enters them.
		Un = copy(Uu)
		Un[21:41, :] .= NaN
		nt = plot_streamlines(sx, sy, Un, Vu).data[1].fields
		@test all(px === nothing || px <= 0.0 + 1e-9 for px in nt[:x])
		# Validation.
		@test _sf_thrown(() -> plot_streamlines(sx, sy, permutedims(Uu), permutedims(Vu))) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines(sx, sy, Uu, zeros(41, 20))) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines(reverse(sx), sy, Uu, Vu)) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines(sx, sy, complex.(Uu), Vu)) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines(sx, sy, Uu, Vu; density = 0)) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines(sx, sy, Uu, Vu; direction = :up)) isa ArgumentError
		zero_field = @test_logs (:warn, r"no streamline") plot_streamlines(sx, sy, Vu, Vu)
		@test isempty(zero_field.data[1].fields[:x])
		# Named, coloured, appended.
		fig = plot_heatmap(sx, sy, hypot.(Uv, Vv))
		@test plot_streamlines!(fig, sx, sy, Uv, Vv; color = "white", legend = "flow", linewidth = 2) === nothing
		ft = _sf_roundtrip(fig.data[2])
		@test ft["line"] == Dict("color" => "white", "width" => 2)
		@test ft["name"] == "flow" && ft["showlegend"] == true
		@test _sf_thrown(() -> plot_streamlines!(fig, sx, sy, Uv, Vv; show = true)) isa ArgumentError
		@test length(fig.data) == 2
		dens = plot_streamlines(sx, sy, Uv, Vv; density = 2, arrows = false).data[1].fields
		@test count(isnothing, dens[:x]) > count(isnothing, vt[:x])
	end

	@testset "SubplotFigure cells other than (1, 1)" begin
		sf = subplots(2, 2; sync = false)
		@test plot_heatmap!(sf, x, y, U; row = 2, col = 2, equalar = true, origin = :upper,
			xlabel = "x") === sf
		l = _sf_roundtrip(sf.plot.layout)
		@test sf.plot.data[end].fields[:xaxis] == "x4" && sf.plot.data[end].fields[:yaxis] == "y4"
		@test l["yaxis4"]["scaleanchor"] == "x4"
		# D10 M3: an equal-aspect cell's axes are pinned; reversed = range high to low.
		@test l["yaxis4"]["autorange"] == false && l["yaxis4"]["range"][1] > l["yaxis4"]["range"][2]
		@test l["xaxis4"]["title"]["text"] == "x"
		@test !haskey(l["xaxis"], "scaleanchor") && !haskey(l["yaxis"], "scaleanchor")
		plot_quiver!(sf, [1.0, 2.0], [1.0, 2.0], [1.0, 1.0], [1.0, 0.0]; row = 1, col = 2, legend = "q")
		l = _sf_roundtrip(sf.plot.layout)
		@test l["yaxis2"]["scaleanchor"] == "x2"
		@test sf.plot.data[end].fields[:xaxis] == "x2"
		@test sf.plot.data[end].fields[:name] == "q"
		plot_contour!(sf, U; row = 2, col = 1, yscale = "log")
		@test collect(sf.plot.data[end].fields[:y]) == 1:3
		@test _sf_roundtrip(sf.plot.layout)["yaxis3"]["type"] == "log"
		plot_image!(sf, zeros(UInt8, 2, 2, 3); row = 2, col = 1)
		@test _sf_roundtrip(sf.plot.layout)["yaxis3"]["scaleanchor"] == "x3"
		plot_matrix!(sf, [1 2; 3 4]; row = 1, col = 1)
		l = _sf_roundtrip(sf.plot.layout)
		@test l["yaxis"]["autorange"] == false && l["yaxis"]["range"][1] > l["yaxis"]["range"][2] &&
			l["yaxis"]["scaleanchor"] == "x"
		ns = length(sf.plot.data)
		plot_streamlines!(sf, collect(0.0:0.5:2.0), collect(0.0:0.5:1.0), ones(5, 3), zeros(5, 3);
			row = 1, col = 2)
		@test sf.plot.data[end].fields[:xaxis] == "x2"
		@test length(sf.plot.data) == ns + 1
		# secondary_y: the trace and the equal aspect use the cell's secondary y axis.
		sy = subplots(1, 2; sync = false, specs = [Spec() Spec(secondary_y = true)])
		plot_quiver!(sy, [0.0, 1.0], [0.0, 1.0], [1.0, 0.0], [0.0, 1.0]; row = 1, col = 2, secondary_y = true)
		@test sy.plot.data[end].fields[:xaxis] == "x2" && sy.plot.data[end].fields[:yaxis] == "y3"
		ly = _sf_roundtrip(sy.plot.layout)
		@test ly["yaxis3"]["scaleanchor"] == "x2"
		@test !haskey(ly["yaxis"], "scaleanchor") && !haskey(ly["yaxis2"], "scaleanchor")
		# The overlaying twin keeps the aspect by its range (it shares the
		# cell's domain), not by a domain it cannot shrink.
		@test ly["yaxis3"]["constrain"] == "range"
		# Log cell axes are honoured for coordinate checks of the delegated methods.
		sl = subplots(1, 2; sync = false)
		plot_heatmap!(sl, [1.0, 2.0, 4.0, 8.0], y, U; row = 1, col = 2, xscale = "log")
		@test _sf_thrown(() -> plot_heatmap!(sl, x, y, U; row = 1, col = 2)) isa ArgumentError
		@test _sf_thrown(() -> plot_quiver!(sl, [0.0], [1.0], [1.0], [1.0]; row = 1, col = 2)) isa ArgumentError
		@test _sf_thrown(() -> plot_heatmap!(sl, x, y, U; row = 1, col = 1, show = true)) isa ArgumentError
		@test _sf_thrown(() -> plot_quiver!(sl, [1.0], [1.0], [1.0], [1.0]; show = true)) isa ArgumentError
		@test _sf_thrown(() -> plot_streamlines!(sl, [1.0, 2.0], [1.0, 2.0], ones(2, 2), ones(2, 2);
			row = 1, col = 1, show = true)) isa ArgumentError
		@test length(sl.plot.data) == 1
	end

	@testset "constructor/mutator keyword parity and docstrings" begin
		kw(m) = Set(filter(k -> !endswith(string(k), "..."), Base.kwarg_decl(m)))
		for (ctor, mut) in ((plot_heatmap, plot_heatmap!), (plot_contour, plot_contour!),
				(plot_quiver, plot_quiver!), (plot_image, plot_image!), (plot_matrix, plot_matrix!),
				(plot_streamlines, plot_streamlines!))
			ctor_kw = union((kw(m) for m in methods(ctor))...)
			mut_kw = union((kw(m) for m in methods(mut) if m.sig.parameters[2] === Any)...)
			@test setdiff(ctor_kw, mut_kw) == Set([:show])
			@test setdiff(mut_kw, ctor_kw) == Set()
			doc = string(Base.Docs.doc(ctor)) * string(Base.Docs.doc(mut))
			for k in union(ctor_kw, mut_kw)
				@test occursin(Regex("`" * string(k) * "\\b"), doc)
			end
			@test occursin("row = nothing, col = nothing, secondary_y = false", doc)
			@test occursin("U[ix, iy]", string(Base.Docs.doc(ctor))) ||
				ctor in (plot_image, plot_matrix, plot_quiver)
		end
	end
end
