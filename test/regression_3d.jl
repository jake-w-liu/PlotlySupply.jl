using Test, PlotlySupply

# Regression tests for the audit findings fixed in the 3-D track (v2
# "threed"). Each testset names its finding id and fails on the 1.x code.

_r3_fields(value) = value isa PlotlyBase.PlotlyAttribute ? value.fields : value
_r3_scene(fig, key::Symbol = :scene) = _r3_fields(
	(fig isa SubplotFigure ? fig.plot.layout : fig.layout).fields[key],
)
_r3_projection(fig, key::Symbol = :scene) =
	_r3_fields(_r3_fields(_r3_fields(_r3_scene(fig, key))[:camera])[:projection])[:type]
_r3_json(value) = PlotlyBase.JSON.parse(PlotlyBase.JSON.json(value; allownan = true))
_r3_viridis() = PlotlySupply._resolve_colorscale("Viridis"; who = "test").scale
_r3_resolved(name) = PlotlySupply._resolve_colorscale(name; who = "test").scale

@testset "regression: 3-D plotting" begin
	@testset "#238/#80 quiver3d cones default to sizemode=\"scaled\", sizeref=1" begin
		X = repeat([-1.0, 0, 1], 9)
		Y = repeat(repeat([-1.0, 0, 1]; inner = 3), 3)
		Z = repeat([-1.0, 0, 1]; inner = 9)
		U = -Y
		V = X
		W = fill(0.3, 27)
		for k in (1e-4, 1.0, 1e3)
			t = plot_quiver3d(X, Y, Z, k .* U, k .* V, k .* W).data[1].fields
			@test t[:sizemode] == "scaled"
			@test t[:sizeref] == 1
			g = plot_scatter3d([0.0], [0.0], [0.0])
			@test plot_quiver3d!(g, X, Y, Z, k .* U, k .* V, k .* W) === nothing
			@test g.data[end].fields[:sizemode] == "scaled"
			@test g.data[end].fields[:sizeref] == 1
		end
		absolute = plot_quiver3d(X, Y, Z, U, V, W; sizemode = "absolute", sizeref = 2).data[1].fields
		@test absolute[:sizemode] == "absolute"
		@test absolute[:sizeref] == 2
		@test plot_quiver3d(X, Y, Z, U, V, W; sizemode = :raw).data[1].fields[:sizemode] == "raw"
		@test_throws ArgumentError plot_quiver3d(X, Y, Z, U, V, W; sizeref = -1)
		@test_throws ArgumentError plot_quiver3d(X, Y, Z, U, V, W; sizeref = 0)
		@test_throws ArgumentError plot_quiver3d(X, Y, Z, U, V, W; sizemode = "bogus")
		f = plot_scatter3d(1:2, 1:2, 1:2)
		@test_throws ArgumentError plot_quiver3d!(f, X, Y, Z, U, V, W; sizeref = NaN)
		@test length(f.data) == 1
	end

	@testset "#91 quiver3d validates lengths and skips non-finite vectors" begin
		@test_throws ArgumentError plot_quiver3d(1:5, 1:5, 1:5, [1.0, 2.0], [1.0, 2.0, 3.0], [1.0])
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; sizeref = -1)
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; sizeref = NaN)
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], Any["bad"], [0.0], [0.0])
		f = plot_scatter(1:2, 1:2)
		n = length(f.data)
		@test_throws ArgumentError plot_quiver3d!(f, [0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; sizeref = -1)
		@test length(f.data) == n
		q = @test_logs (:warn, r"skipped 1") plot_quiver3d(
			[0.0, 2.0], [0.0, 0.0], [0.0, 0.0], [1.0, NaN], [0.0, 0.0], [0.0, 0.0],
		)
		@test collect(q.data[1].fields[:x]) == [0.0]
		@test all(isfinite, q.data[1].fields[:u])
		# A non-finite origin is skipped too, also for arrows.
		a = @test_logs (:warn, r"skipped 1") plot_quiver3d(
			[0.0, Inf], [0.0, 0.0], [0.0, 0.0], [1.0, 1.0], [0.0, 0.0], [0.0, 0.0]; style = :arrow,
		)
		@test a.data[2].fields[:x] == [1.0]
		# Without bad samples the inputs are passed through unchanged.
		x = [0.0, 1.0]
		@test plot_quiver3d(x, x, x, x, x, x).data[1].fields[:x] === x
	end

	@testset "#242 quiver3d anchor keyword; docs no longer say \"vector origins\"" begin
		@test plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]).data[1].fields[:anchor] == "cm"
		@test plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; anchor = "tail").data[1].fields[:anchor] == "tail"
		fig = plot_scatter3d([0.0], [0.0], [0.0])
		plot_quiver3d!(fig, [0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; anchor = :tip)
		@test fig.data[end].fields[:anchor] == "tip"
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; anchor = "base")
		doc = string(@doc plot_quiver3d)
		@test !occursin("vector origins", doc)
		@test occursin("centre", doc)
	end

	@testset "#240/#94 plot_surface(!) accept `perspective`" begin
		f = plot_surface(rand(3, 3); perspective = false)
		@test _r3_projection(f) == "orthographic"
		@test _r3_projection(plot_surface(collect(1.0:3), collect(1.0:3), rand(3, 3); perspective = false)) ==
			  "orthographic"
		g = plot_surface(rand(3, 3))
		plot_surface!(g, rand(3, 3); perspective = false)
		@test _r3_projection(g) == "orthographic"
		sf = subplots(1, 1; sync = false, specs = Union{Missing, Spec}[Spec(kind = "scene");;])
		@test plot_surface!(sf, rand(3, 3); perspective = false) === sf
		@test _r3_projection(sf) == "orthographic"
	end

	@testset "#84/#294 plot_surface accepts the `color` alias of surfacecolor" begin
		Z = rand(3, 4)
		C = rand(3, 4)
		@test plot_surface(Z; color = C).data[1].fields[:surfacecolor] == C
		@test plot_surface(0:2, 0:3, Z; color = C).data[1].fields[:surfacecolor] == C
		g = plot_surface(Z)
		plot_surface!(g, Z; color = C)
		@test g.data[end].fields[:surfacecolor] == C
		@test_throws ArgumentError plot_surface(Z; color = C, surfacecolor = C)
		doc = string(@doc plot_surface!)
		@test occursin("shared_coloraxis", doc) && occursin("surfacecolor", doc)
	end

	@testset "#243 shared_coloraxis keeps an earlier surface's colorscale" begin
		fig = plot_surface(rand(3, 3); colorscale = "Hot")
		plot_surface!(fig, rand(3, 3); shared_coloraxis = true)
		d = _r3_json(fig)
		@test d["layout"]["coloraxis"]["colorscale"] == _r3_json(_r3_resolved("Hot"))
		@test all(t -> t["coloraxis"] == "coloraxis", d["data"])
		fig2 = plot_surface(rand(3, 3); colorscale = "Hot")
		plot_surface!(fig2, rand(3, 3); shared_coloraxis = true, colorscale = "Viridis")
		@test _r3_json(fig2)["layout"]["coloraxis"]["colorscale"] == _r3_json(_r3_viridis())
		fig3 = plot_surface(rand(3, 3))
		plot_surface!(fig3, rand(3, 3); shared_coloraxis = true, colorscale = "Hot")
		plot_surface!(fig3, rand(3, 3); shared_coloraxis = true)
		@test _r3_json(fig3)["layout"]["coloraxis"]["colorscale"] == _r3_json(_r3_resolved("Hot"))
	end

	@testset "#38/#101 SubplotFigure shared_coloraxis links existing surfaces" begin
		for psl in (true, false)
			sf = subplots(1, 2; sync = false, specs = fill(Spec(kind = "scene"), 1, 2), per_subplot_legends = psl)
			plot_surface!(sf, [1.0 2; 3 4]; row = 1, col = 1)
			plot_surface!(sf, [10.0 20; 30 40]; row = 1, col = 2, shared_coloraxis = true)
			@test [get(t.fields, :coloraxis, nothing) for t in sf.plot.data] == ["coloraxis", "coloraxis"]
			@test (sf.current_row, sf.current_col) == (1, 2)
		end
		# A failing call rolls back: the first surface does not join the axis.
		sf = subplots(1, 2; sync = false, specs = fill(Spec(kind = "scene"), 1, 2))
		plot_surface!(sf, rand(3, 3); row = 1, col = 1)
		@test_throws ArgumentError plot_surface!(
			sf, rand(3, 3); row = 1, col = 2, shared_coloraxis = true, aspectmode = "bogus",
		)
		@test length(sf.plot.data) == 1
		@test !haskey(sf.plot.data[1].fields, :coloraxis)

		# SyncPlot-backed SubplotFigure: one Plotly.react, old trace object kept.
		for psl in (true, false)
			base = subplots(1, 2; sync = false, specs = fill(Spec(kind = "scene"), 1, 2))
			p = base.plot
			plot_surface!(base, [1.0 2; 3 4]; row = 1, col = 1)
			scripts = String[]
			backend = (
				isopen = window -> true,
				close = window -> nothing,
				run = (window, script) -> (push!(scripts, String(script)); "ok"),
			)
			sp = SyncPlot(p, nothing, :r3_window, "r3-div", PlotlySupply._SyncPlotResources(nothing, backend))
			sf = SubplotFigure(sp, 1, 2, 1, 1, psl, :topright, (0.02, 0.03), "white", "black", 1.0)
			old = p.data[1]
			plot_surface!(sf, [10.0 20; 30 40]; row = 1, col = 2, shared_coloraxis = true)
			@test p.data[1] === old
			@test p.data[1].fields[:coloraxis] == "coloraxis"
			@test p.data[2].fields[:coloraxis] == "coloraxis"
			@test occursin("Plotly.react", only(scripts))
			@test !occursin("Plotly.addTraces", only(scripts))
		end
	end

	@testset "#241 isosurface/volume take 3-D arrays and flatten them" begin
		g = range(-1, 1; length = 4)
		X = [a for a in g, b in g, c in g]
		Y = [b for a in g, b in g, c in g]
		Z = [c for a in g, b in g, c in g]
		V = X .^ 2 .+ Y .^ 2 .+ Z .^ 2
		for f in (plot_isosurface, plot_volume), args in ((X, Y, Z, V), map(A -> view(A, :, :, :), (X, Y, Z, V)))
			t = only(f(args...).data)
			for k in (:x, :y, :z, :value)
				@test ndims(t.fields[k]) == 1
			end
			@test collect(t.fields[:x]) == vec(X)
			@test collect(t.fields[:value]) == vec(V)
		end
		# Axis vectors with a length(x)×length(y)×length(z) value array.
		t = only(plot_isosurface(collect(g), collect(g), collect(g), V).data)
		@test collect(t.fields[:x]) == vec(X)
		@test collect(t.fields[:y]) == vec(Y)
		@test collect(t.fields[:z]) == vec(Z)
		@test_throws ArgumentError plot_isosurface(X, Y, Z, V[:, :, 1:2])
		@test_throws ArgumentError plot_volume(X, Y, Z, V[:, :, 1:2])
		sf = subplots(1, 1; sync = false, specs = fill(Spec(kind = "scene"), 1, 1))
		plot_isosurface!(sf, X, Y, Z, V)
		@test ndims(only(sf.plot.data).fields[:x]) == 1
		h = plot_scatter3d([0.0], [0.0], [0.0])
		plot_volume!(h, X, Y, Z, V)
		@test ndims(h.data[end].fields[:value]) == 1
	end

	@testset "#245 scatter3d `dash`" begin
		f = plot_scatter3d(1:3, 1:3, 1:3; dash = "dash")
		@test f.data[1].fields[:line][:dash] == "dash"
		g = plot_scatter3d([[1, 2], [1, 2]], [[1, 2], [1, 2]], [[1, 2], [2, 1]]; dash = ["dot", ""])
		@test g.data[1].fields[:line][:dash] == "dot"
		@test !haskey(_r3_fields(g.data[2].fields[:line]), :dash)
		plot_scatter3d!(f, 1:3, 1:3, [3, 2, 1]; dash = "dot")
		@test f.data[end].fields[:line][:dash] == "dot"
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; dash = "dashed")
	end

	@testset "#83/#95/#44/#104 (scatter3d) nested mode \"\" means \"lines\"" begin
		f = plot_scatter3d([[1, 2], [1, 2]], [[1, 2], [1, 2]], [[1, 2], [2, 1]]; mode = ["", "markers"])
		@test f.data[1].fields[:mode] == "lines"
		@test f.data[2].fields[:mode] == "markers"
		g = plot_scatter3d(1:2, 1:2, 1:2)
		plot_scatter3d!(g, [[1, 2], [1, 2]], [[1, 2], [1, 2]], [[1, 2], [2, 1]]; mode = [""])
		@test g.data[2].fields[:mode] == "lines"
		@test g.data[3].fields[:mode] == "lines"
		@test_throws ArgumentError plot_scatter3d(1:2, 1:2, 1:2; mode = "line")
	end

	@testset "#92 (surface) Bool matrices are sent as 0/1" begin
		for Z in (BitMatrix([true false; false true]), Matrix{Bool}([true false; false true]))
			p = plot_surface(Z)
			@test !(eltype(p.data[1].fields[:z]) <: Bool)
			s = PlotlyBase.JSON.json(p.data[1])
			@test !occursin("true", s) && !occursin("false", s)
			q = plot_surface(rand(2, 2))
			plot_surface!(q, Z)
			@test !(eltype(q.data[end].fields[:z]) <: Bool)
		end
		c = plot_surface(rand(2, 2); surfacecolor = trues(2, 2)).data[1].fields[:surfacecolor]
		@test !(eltype(c) <: Bool)
		# Non-Bool payloads keep their identity (lazy payloads).
		Z = rand(2, 2)
		@test plot_surface(Z).data[1].fields[:z] === Z
	end

	@testset "#93/#18 (3-D) range keywords are validated" begin
		@test_throws ArgumentError plot_surface(rand(3, 3); zrange = [5])
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; zrange = [1])
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; xrange = [1, 2, 3])
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; yrange = [NaN, 1])
		@test_throws ArgumentError plot_mesh3d([0, 1, 0], [0, 0, 1], [0, 0, 0]; zrange = [1, 1])
		f = plot_scatter3d(1:3, 1:3, 1:3)
		@test_throws ArgumentError plot_scatter3d!(f, 1:3, 1:3, 1:3; zrange = [1])
		@test length(f.data) == 1
		@test !haskey(_r3_fields(_r3_scene(plot_surface(rand(3, 3); zrange = (0, 0)))[:zaxis]), :range)
		@test _r3_fields(_r3_scene(plot_surface(rand(3, 3); zrange = (0, 2)))[:zaxis])[:range] == [0, 2]
	end

	@testset "#239 (3-D) colorscale names resolve; unknown names throw" begin
		t = plot_surface(rand(3, 3); colorscale = "Plasma").data[1].fields
		@test t[:colorscale] == _r3_resolved("plasma")
		@test plot_surface(rand(3, 3); colorscale = "viridis").data[1].fields[:colorscale] == _r3_viridis()
		@test_throws ArgumentError plot_surface(rand(3, 3); colorscale = "NoSuchMap")
		@test_throws ArgumentError plot_mesh3d([0, 1, 0], [0, 0, 1], [0, 0, 0]; intensity = [1.0, 2, 3], colorscale = "NoSuchMap")
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; colorscale = "NoSuchMap")
	end

	@testset "#40/#211 (scatter3d) Vector{Any} of series is multi-series" begin
		zs = []
		push!(zs, [1.0, 2.0, 3.0])
		push!(zs, [3.0, 2.0, 1.0])
		f = plot_scatter3d(1:3, 1:3, zs)
		@test length(f.data) == 2
		@test collect(f.data[2].fields[:z]) == [3.0, 2.0, 1.0]
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, Any[[1.0, 2.0, 3.0], 4.0])
	end

	@testset "#19 (3-D) LaTeXString / SubString labels" begin
		label = SubString("xx-axis", 2)
		f = plot_surface(rand(2, 2); xlabel = label, title = SubString("ttitle", 2))
		@test _r3_fields(_r3_fields(_r3_scene(f)[:xaxis])[:title])[:text] == "x-axis"
		g = plot_scatter3d(1:2, 1:2, 1:2; legend = SubString("aname", 2), color = :red)
		@test g.data[1].fields[:name] == "name"
		@test g.data[1].fields[:line][:color] == "red"
	end

	@testset "#75 (3-D) complex data is rejected" begin
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, [1.0im, 2, 3])
		@test_throws ArgumentError plot_surface(fill(1.0 + 1im, 2, 2))
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0im], [0.0], [0.0])
		@test_throws ArgumentError plot_isosurface([0.0, 1], [0.0, 1], [0.0, 1], [1.0im, 2])
	end

	@testset "#86/#96/#105/#114/#302 (3-D) docstrings list every keyword" begin
		functions = (
			plot_surface, plot_surface!, plot_scatter3d, plot_scatter3d!, plot_quiver3d, plot_quiver3d!,
			plot_mesh3d, plot_mesh3d!, plot_isosurface, plot_isosurface!, plot_volume, plot_volume!,
			plot_streamtube, plot_streamtube!, plot_polygons3d, plot_polygons3d!, plot_wireframe,
			plot_wireframe!, plot_segments3d, plot_segments3d!, view!, scene!,
		)
		for f in functions
			doc = string(Base.Docs.doc(f))
			for m in methods(f)
				parentmodule(m) === PlotlySupply || continue
				for k in Base.kwarg_decl(m)
					name = string(k)
					endswith(name, "...") && continue
					@test (f, name, occursin(Regex("`" * name * "(`|::| =)"), doc)) == (f, name, true)
				end
			end
			@test occursin("# Examples", doc)
		end
		d = string(@doc plot_scatter3d)
		@test !occursin("must also be `Vector{Vector}`", d)
		@test !occursin("color::String = \"\"", string(@doc plot_quiver3d!))
		@test occursin("first", string(@doc plot_quiver3d))   # a colour vector uses its first entry
	end

	@testset "mutators reject `show` with a clear message" begin
		f = plot_scatter3d(1:2, 1:2, 1:2)
		err = try
			plot_scatter3d!(f, 1:2, 1:2, 1:2; show = true)
			nothing
		catch e
			e
		end
		@test err isa ArgumentError
		@test occursin("plot_scatter3d!: `show` is a constructor keyword", err.msg)
		@test length(f.data) == 1
		@test_throws ArgumentError plot_surface!(f, rand(2, 2); show = true)
		@test_throws ArgumentError plot_quiver3d!(f, [0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; show = true)
		@test_throws ArgumentError plot_mesh3d!(f, [0, 1, 0], [0, 0, 1], [0, 0, 0]; show = true)
		@test_throws ArgumentError plot_surface(rand(2, 2); bogus = 1)
		@test length(f.data) == 1
	end
end
