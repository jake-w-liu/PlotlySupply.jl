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

	# ---- v3 (threed-int) ----

	_r3_layout(fig) = (fig isa SubplotFigure ? fig.plot.layout : fig.layout).fields
	_r3_annotations(fig) = [_r3_fields(a) for a in get(_r3_layout(fig), :annotations, Any[])]
	_r3_names(fig) = [a[:name] for a in _r3_annotations(fig)]
	_r3_message(f) = try
		f()
		""
	catch e
		e isa ArgumentError ? e.msg : "not an ArgumentError: $(typeof(e))"
	end
	_r3_sf(cols = 2) = subplots(1, cols; sync = false, specs = fill(Spec(kind = "scene"), 1, cols))

	@testset "X1 (3-D) colorbar_title_side and math colorbar titles" begin
		xs, ys = 0:3, 0:2
		Z = [x + y for x in xs, y in ys]
		for side in (:top, :right, :bottom)
			g = plot_surface(xs, ys, Z; colorbar_title = "plain", colorbar_title_side = side)
			title = _r3_fields(_r3_fields(g.data[1].fields[:colorbar])[:title])
			@test title[:text] == "plain"
			@test title[:side] == String(side)
			@test isempty(_r3_names(g))
			# Math titles become a MathJax annotation beside the bar (plotly.js
			# cannot typeset colorbar titles).
			f = plot_surface(xs, ys, Z; colorbar_title = raw"$\phi$ (V)", colorbar_title_side = side)
			@test _r3_names(f) == ["plotlysupply:colorbar_title:scene:$(side)"]
			@test _r3_annotations(f)[1][:text] == "\$\\phi\\text{ (V)}\$"
			@test !haskey(_r3_fields(f.data[1].fields[:colorbar]), :title)
		end
		@test _r3_annotations(plot_surface(Z; colorbar_title = L"\phi", colorbar_title_side = :right))[1][:textangle] == -90
		@test _r3_annotations(plot_surface(Z; colorbar_title = L"\phi", colorbar_title_side = :bottom))[1][:yanchor] == "top"
		@test _r3_fields(_r3_fields(plot_surface(Z; colorbar_title = "p", colorbar_title_side = "right").data[1].fields[:colorbar])[:title])[:side] == "right"
		# Every coloured 3-D trace type.
		x4, y4, z4 = [0.0, 1, 0, 0], [0.0, 0, 1, 0], [0.0, 0, 0, 1]
		g3 = range(0, 1, length = 3)
		VX = vec([a for a in g3, b in g3, c in g3])
		VY = vec([b for a in g3, b in g3, c in g3])
		VZ = vec([c for a in g3, b in g3, c in g3])
		faces = [[0.0 0 0; 1 0 0; 0 1 0], [0.0 0 0; 1 0 0; 0 0 1]]
		builders = (
			kw -> plot_mesh3d(x4, y4, z4; i = [0, 0], j = [1, 2], k = [2, 3], intensity = [1.0, 2, 3, 4], kw...),
			kw -> plot_isosurface(VX, VY, VZ, VX .+ VY .+ VZ; kw...),
			kw -> plot_volume(VX, VY, VZ, VX .+ VY .+ VZ; kw...),
			kw -> plot_quiver3d([0.0, 1], [0.0, 1], [0.0, 1], [1.0, 1], [0.0, 1], [0.0, 1]; kw...),
			kw -> plot_streamtube(VX, VY, VZ, ones(27), zeros(27), zeros(27); kw...),
			kw -> plot_polygons3d(faces, [1.0, 2.0]; kw...),
		)
		for build in builders
			f = build((colorbar_title = L"\rho", colorbar_title_side = :right))
			@test _r3_names(f) == ["plotlysupply:colorbar_title:scene:right"]
			g = build((colorbar_title = "rho", colorbar_title_side = :bottom))
			@test _r3_fields(_r3_fields(g.data[1].fields[:colorbar])[:title])[:side] == "bottom"
		end
		# Validation (also with a uniform colour, where no bar is drawn), before
		# any change.
		@test occursin("plot_surface: `colorbar_title_side` must be :top, :right or :bottom; got :left",
			_r3_message(() -> plot_surface(Z; colorbar_title_side = :left)))
		@test_throws ArgumentError plot_surface(Z; color = "red", colorbar_title_side = :left)
		@test_throws ArgumentError plot_mesh3d(x4, y4, z4; colorbar_title_side = 1)
		f = plot_surface(Z)
		before = PlotlyBase.JSON.json(f)
		@test occursin("plot_surface!: `colorbar_title_side`", _r3_message(() -> plot_surface!(f, Z; colorbar_title_side = :left)))
		@test PlotlyBase.JSON.json(f) == before
		# A shared colour axis: a later plain title removes the math annotation.
		f = plot_surface(xs, ys, Z; coloraxis = :shared, colorbar_title = raw"$T$")
		@test _r3_names(f) == ["plotlysupply:colorbar_title:coloraxis:top"]
		plot_surface!(f, xs, ys, Z .+ 1; coloraxis = :shared, colorbar_title = "T plain")
		@test isempty(_r3_names(f))
		@test _r3_fields(_r3_fields(_r3_fields(_r3_layout(f)[:coloraxis])[:colorbar])[:title])[:text] == "T plain"
		# SubplotFigure cells, also on a second colour axis.
		sf = _r3_sf()
		plot_surface!(sf, xs, ys, Z; row = 1, col = 2, colorbar_title = raw"$\phi$", colorbar_title_side = :right)
		@test "plotlysupply:colorbar_title:scene2:right" in _r3_names(sf)
		plot_surface!(sf, xs, ys, Z; row = 1, col = 1, coloraxis = "coloraxis2", colorbar_title = raw"$\psi$")
		@test "plotlysupply:colorbar_title:coloraxis2:top" in _r3_names(sf)
		plot_surface!(sf, xs, ys, Z; row = 1, col = 1, coloraxis = :shared, colorbar_title = raw"$\chi$")
		@test "plotlysupply:colorbar_title:coloraxis:top" in _r3_names(sf)
		plot_surface!(sf, xs, ys, Z; row = 1, col = 1, coloraxis = :shared, colorbar_title = "chi plain")
		@test !("plotlysupply:colorbar_title:coloraxis:top" in _r3_names(sf))
		@test "plotlysupply:colorbar_title:coloraxis2:top" in _r3_names(sf)
		n = length(sf.plot.data)
		@test_throws ArgumentError plot_surface!(sf, Z; row = 1, col = 1, colorbar_title_side = :left)
		@test length(sf.plot.data) == n
	end

	@testset "#87/#114 (3-D) no commented-out code or dead helpers" begin
		src = read(joinpath(pkgdir(PlotlySupply), "src", "sci", "scene3d.jl"), String)
		@test !occursin(r"^\s*#\s*(fig|trace|layout|p)\s*[.\[]?\S*\s*=[^=]"m, src)
		for file in ("api.jl", joinpath("sci", "scene3d.jl"))
			text = read(joinpath(pkgdir(PlotlySupply), "src", file), String)
			@test !occursin("showlegendV", text)
			@test !occursin("_tuple_interleave", text)
		end
	end

	@testset "X13 (3-D) a legend first made by an append follows the template" begin
		f = plot_surface(rand(3, 3))
		relayout!(f; template = PlotlyBase.templates[:plotly_dark])
		plot_scatter3d!(f, [0, 1], [0, 1], [0, 1]; legend = "line")
		legend = _r3_fields(_r3_layout(f)[:legend])
		@test legend[:bgcolor] == "rgba(17,17,17,0.72)"
		@test legend[:bordercolor] == "rgba(255,255,255,0.25)"
	end

	@testset "X10 (3-D) the plot style's widths, sizes and dash/marker cycle" begin
		st = with_style(:default; linewidth = 4, marker_size = 7, cycle = :dash_marker) do
			q = plot_scatter3d(1:3, 1:3, 1:3)
			plot_scatter3d!(q, 1:3, 1:3, 3:-1:1)
			plot_scatter3d!(q, 1:3, 1:3, 3:-1:1; mode = "lines")
			plot_wireframe!(q, [0.0, 1.0], [0.0, 1.0], zeros(2, 2); rstride = 1, cstride = 1)
			plot_segments3d!(q, [0.0], [0.0], [0.0], [1.0], [1.0], [1.0]; linewidth = 2)
			q
		end
		line(i) = _r3_fields(st.data[i].fields[:line])
		marker(i) = _r3_fields(get(st.data[i].fields, :marker, Dict{Symbol, Any}()))
		@test st.data[1].fields[:mode] == "lines+markers"
		@test (line(1)[:dash], line(1)[:width], marker(1)[:symbol], marker(1)[:size]) == ("solid", 4, "circle", 7)
		@test (line(2)[:dash], marker(2)[:symbol]) == ("dash", "square")
		@test st.data[3].fields[:mode] == "lines"   # an explicit mode is kept
		@test line(4)[:width] == 4                  # wireframe: the style's width, no dash cycle
		@test !haskey(line(4), :dash)
		@test line(5)[:width] == 2                  # an explicit width is kept
		w = with_style(() -> plot_wireframe([0.0, 1.0], [0.0, 1.0], zeros(2, 2)), :default; linewidth = 3)
		@test _r3_fields(w.data[1].fields[:line])[:width] == 3
		# Without a style: plotly's scatter3d width, 1 px wireframes and segments.
		d = plot_scatter3d(1:3, 1:3, 1:3)
		plot_wireframe!(d, [0.0, 1.0], [0.0, 1.0], zeros(2, 2))
		plot_segments3d!(d, [0.0], [0.0], [0.0], [1.0], [1.0], [1.0])
		@test d.data[1].fields[:mode] == "lines"
		@test !haskey(_r3_fields(d.data[1].fields[:line]), :width)
		@test _r3_fields(d.data[2].fields[:line])[:width] == 1
		@test _r3_fields(d.data[3].fields[:line])[:width] == 1
		# The cycle continues across SubplotFigure cells.
		sf = with_style(:default; cycle = :dash_marker) do
			s = _r3_sf()
			plot_scatter3d!(s, 1:3, 1:3, 1:3; row = 1, col = 1)
			plot_scatter3d!(s, 1:3, 1:3, 1:3; row = 1, col = 2)
			s
		end
		@test [_r3_fields(t.fields[:line])[:dash] for t in sf.plot.data] == ["solid", "dash"]
	end

	@testset "Bool coordinates are sent as numbers (3-D)" begin
		b = [true, false, true]
		nobool(values) = !(eltype(values) <: Bool) && !occursin(r"true|false", PlotlyBase.JSON.json(values))
		s = plot_scatter3d(b, [1, 2, 3], BitVector(b))
		@test s.data[1].fields[:x] == [1, 0, 1] && nobool(s.data[1].fields[:x]) && nobool(s.data[1].fields[:z])
		q = plot_quiver3d(b, b, b, [1.0, 1, 1], [1.0, 1, 1], b)
		@test all(nobool(q.data[1].fields[k]) for k in (:x, :y, :z, :w))
		m = plot_mesh3d([true, false, false], [false, true, false], [false, false, true])
		@test m.data[1].fields[:x] == [1, 0, 0] && nobool(m.data[1].fields[:x])
		p = plot_polygons3d([true, false, false], [false, true, false], [false, false, true], [[1, 2, 3]])
		@test nobool(p.data[1].fields[:x])
		g = plot_segments3d([true], [false], [false], [false], [true], [true])
		@test g.data[1].fields[:x] == [1.0, 0.0, nothing]
		w = plot_wireframe([false, true], [false, true], [true false; false true])
		@test all(nobool(w.data[1].fields[k]) for k in (:x, :y, :z))
		f = plot_scatter3d(1:3, 1:3, 1:3)
		plot_scatter3d!(f, b, b, b)
		@test nobool(f.data[end].fields[:x])
		sf = _r3_sf()
		plot_scatter3d!(sf, b, b, b; row = 1, col = 2)
		@test nobool(sf.plot.data[end].fields[:y])
	end

	@testset "#19 (3-D) LaTeXString labels, titles and text" begin
		f = plot_surface(rand(2, 2); xlabel = L"x_1", zlabel = L"\lambda^2", title = L"\alpha")
		@test _r3_fields(_r3_fields(_r3_scene(f)[:xaxis])[:title])[:text] == "x<sub>1</sub>"
		@test _r3_fields(_r3_fields(_r3_scene(f)[:zaxis])[:title])[:text] == "λ<sup>2</sup>"
		@test _r3_fields(_r3_layout(f)[:title])[:text] == "\$\\alpha\$"
		g = plot_scatter3d(1:2, 1:2, 1:2; legend = L"\beta", text = [L"\gamma", "plain"])
		@test g.data[1].fields[:name] == "\$\\beta\$"
		@test g.data[1].fields[:text] == ["γ", "plain"]   # WebGL text: Unicode
		scene!(f; ylabel = L"y_2")
		@test _r3_fields(_r3_fields(_r3_scene(f)[:yaxis])[:title])[:text] == "y<sub>2</sub>"
		annotate!(f, 0.5, 0.5, 0.5, L"\gamma")   # scene annotations are SVG: MathJax
		@test _r3_fields(_r3_scene(f)[:annotations][1])[:text] == "\$\\gamma\$"
		sf = _r3_sf()
		plot_surface!(sf, rand(2, 2); row = 1, col = 2, xlabel = L"x_1")
		@test _r3_fields(_r3_fields(_r3_scene(sf, :scene2)[:xaxis])[:title])[:text] == "x<sub>1</sub>"
	end

	@testset "consistency sweep: every 3-D constructor and mutator" begin
		gx, gy = collect(0.0:3.0), collect(0.0:2.0)
		Zm = [x + y for x in gx, y in gy]
		Znan = copy(Zm)
		Znan[2, 2] = NaN
		g3 = range(0, 1, length = 3)
		VX = vec([a for a in g3, b in g3, c in g3])
		VY = vec([b for a in g3, b in g3, c in g3])
		VZ = vec([c for a in g3, b in g3, c in g3])
		VV = VX .+ VY .+ VZ
		VVnan = copy(VV)
		VVnan[5] = NaN
		mx, my, mz = [0.0, 1, 0, 0], [0.0, 0, 1, 0], [0.0, 0, 0, 1]
		faces = [[0.0 0 0; 1 0 0; 0 1 0], [0.0 0 0; 1 0 0; 0 0 1]]
		# (name, constructor, mutator, args (ranges/views), keywords (Symbol
		# colours, LaTeXString titles), args with NaN)
		cases = (
			("surface", plot_surface, plot_surface!, (0:3, 0:2, view(Zm, :, :)),
				(colorscale = :viridis, colorbar_title = L"\phi", edgecolor = :white), (gx, gy, Znan)),
			("surface Z", plot_surface, plot_surface!, (Zm,), (color = :red,), (Znan,)),
			("scatter3d", plot_scatter3d, plot_scatter3d!, (view(collect(0.0:4.0), 1:4), 1:4, view([1.0, 2, 3, 4], :)),
				(color = :red, marker_color = :blue, mode = "lines+markers", text = L"\alpha"), ([1.0, NaN, 3.0], [1.0, 2, 3], [1.0, 2, 3])),
			("quiver3d", plot_quiver3d, plot_quiver3d!, (0:1, 0:1, 0:1, [1.0, 1], [0.0, 1], view([1.0, 1], :)),
				(colorscale = :plasma, colorbar_title = L"|v|"), ([0.0, NaN], [0.0, 1], [0.0, 1], [1.0, 1], [0.0, 1], [1.0, 1])),
			("quiver3d arrow", plot_quiver3d, plot_quiver3d!, (0:1, 0:1, 0:1, [1.0, 1], [0.0, 1], [1.0, 1]),
				(style = :arrow, color = :green), ([0.0, NaN], [0.0, 1], [0.0, 1], [1.0, 1], [0.0, 1], [1.0, 1])),
			("mesh3d", plot_mesh3d, plot_mesh3d!, (mx, my, view(mz, :)),
				(i = [0, 0], j = [1, 2], k = [2, 3], intensity = 1:4, colorbar_title = L"I", edgecolor = :black, edges = true),
				([0.0, 1, NaN, 0], my, mz)),
			("isosurface", plot_isosurface, plot_isosurface!, (VX, VY, VZ, VV), (colorscale = :viridis, colorbar_title = L"V"),
				(VX, VY, VZ, VVnan)),
			("volume", plot_volume, plot_volume!, (VX, VY, VZ, view(VV, :)), (colorbar_title = L"\rho",), (VX, VY, VZ, VVnan)),
			("streamtube", plot_streamtube, plot_streamtube!, (VX, VY, VZ, ones(27), zeros(27), zeros(27)), (colorbar_title = L"s",),
				(VX, VY, VZ, ones(27), zeros(27), fill(NaN, 27))),
			("polygons3d", plot_polygons3d, plot_polygons3d!, (faces, 1:2), (colorscale = :viridis, edgecolor = :black), (faces, [1.0, NaN])),
			("polygons3d indexed", plot_polygons3d, plot_polygons3d!, (mx, my, mz, [[1, 2, 3], [1, 2, 4]], 1:2), (),
				(mx, my, mz, [[1, 2, 3], [1, 2, 4]], [NaN, 1.0])),
			("wireframe", plot_wireframe, plot_wireframe!, (0:3, 0:2, view(Zm, :, :)), (color = :blue,), (gx, gy, Znan)),
			("segments3d", plot_segments3d, plot_segments3d!, (0:1, 0:1, 0:1, 1:2, 1:2, view([1.0, 2], :)), (color = :black,),
				([0.0, NaN], [0.0, 1], [0.0, 1], [1.0, 2], [1.0, 2], [1.0, 2])),
			("segments3d edges", plot_segments3d, plot_segments3d!, (mx, my, mz, [1 2; 2 3]), (), ([0.0, NaN, 0, 0], my, mz, [1 2; 2 3])),
		)
		scene_kw = (xrange = (0, 5), yrange = [0, 5], zrange = (-1, 6), xlabel = L"x_1", ylabel = L"\mathbf{b}", zlabel = L"\lambda^2")
		axis(fig, key, name) = _r3_fields(_r3_scene(fig, key)[name])
		for (name, ctor, mut, args, kw, nanargs) in cases
			@testset "$(name)" begin
				f = ctor(args...; kw..., scene_kw...)
				@test f isa Plot
				@test _r3_fields(axis(f, :scene, :xaxis)[:title])[:text] == "x<sub>1</sub>"
				@test axis(f, :scene, :yaxis)[:range] == [0, 5]
				@test axis(f, :scene, :zaxis)[:range] == [-1, 6]
				@test ctor(args...; kw..., xrange = [0, 5], yrange = (0, 5)) isa Plot
				@test ctor(nanargs...) isa Plot
				@test_throws ArgumentError ctor(args...; bogus_keyword = 1)
				# Mutator on a Plot: errors leave the figure unchanged.
				fig = plot_scatter3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0])
				@test mut(fig, args...; kw..., scene_kw...) === nothing
				@test mut(fig, nanargs...) === nothing
				@test _r3_fields(axis(fig, :scene, :zaxis)[:title])[:text] == "λ<sup>2</sup>"
				before = PlotlyBase.JSON.json(fig; allownan = true)
				@test occursin("`show`", _r3_message(() -> mut(fig, args...; show = true)))
				@test_throws ArgumentError mut(fig, args...; bogus_keyword = 1)
				@test PlotlyBase.JSON.json(fig; allownan = true) == before
				# SubplotFigure scene cell (1, 2).
				sf = _r3_sf()
				@test mut(sf, args...; row = 1, col = 2, kw..., scene_kw...) === sf
				@test mut(sf, nanargs...; row = 1, col = 2) === sf
				@test unique(String(get(t.fields, :scene, "scene")) for t in sf.plot.data) == ["scene2"]
				@test _r3_fields(axis(sf, :scene2, :xaxis)[:title])[:text] == "x<sub>1</sub>"
				@test axis(sf, :scene2, :xaxis)[:range] == [0, 5]
				before = PlotlyBase.JSON.json(sf.plot; allownan = true)
				@test occursin("`show`", _r3_message(() -> mut(sf, args...; row = 1, col = 2, show = true)))
				@test_throws ArgumentError mut(sf, args...; row = 1, col = 2, bogus_keyword = 1)
				@test PlotlyBase.JSON.json(sf.plot; allownan = true) == before
			end
		end
		# view!, scene! and annotate! with the same kinds of input.
		f = plot_surface(Zm)
		@test view!(f; elev = 20, azim = 30) === nothing
		@test scene!(f; xrange = (0, 4), zrange = [0, 6], xlabel = L"x_1", xticks = 0:2, xticklabels = [L"a", "b", "c"],
			backgroundcolor = :lightgray) === nothing
		@test annotate!(f, 1, 1, 1, L"\alpha"; color = :red) === f
		before = PlotlyBase.JSON.json(f)
		@test_throws ArgumentError view!(f; show = true)
		@test_throws ArgumentError scene!(f; show = true)
		@test_throws ArgumentError annotate!(f, 1, 1, 1, "x"; bogus = 1)
		@test PlotlyBase.JSON.json(f) == before
		sf = _r3_sf()
		plot_surface!(sf, Zm; row = 1, col = 2)
		@test view!(sf; row = 1, col = 2, elev = 20, azim = 30) === sf
		@test scene!(sf; row = 1, col = 2, zrange = (0, 6), zlabel = L"z") === sf
		@test annotate!(sf, 1, 1, 1, L"\beta"; row = 1, col = 2) === sf
		@test _r3_fields(axis(sf, :scene2, :zaxis)[:title])[:text] == "z"
	end
end

# Wave-4 3-D items (v4 "threed"); each testset names its item id.
_v4_fields(value) = value isa PlotlyBase.PlotlyAttribute ? value.fields : value
_v4_message(f) = try
	f()
	""
catch err
	err isa ArgumentError || rethrow()
	err.msg
end
_v4_marker(trace) = _v4_fields(trace.fields[:marker])
_v4_line(trace) = _v4_fields(trace.fields[:line])
_v4_camera(p::Plot, key::Symbol = :scene) = _v4_fields(_v4_fields(p.layout.fields[key])[:camera])
_v4_xyz(value) = [Float64(_v4_fields(value)[k]) for k in (:x, :y, :z)]
_v4_copy(p::Plot) = Plot(copy(p.data), deepcopy(p.layout), p.frames; config = p.config)
function _v4_surface_data()
	xs = range(-2, 2; length = 25)
	ys = range(-1, 1; length = 21)
	return xs, ys, [exp(-x^2 - 2y^2) for x in xs, y in ys]
end
# Largest coordinate of the modelled drawing (box corners, tick labels and axis
# titles) of scene `key` in `p` exported at `size`, as a fraction of its half
# viewport, with the camera distance scaled by `scale`.
function _v4_label_extent(p::Plot, key::Symbol, size, scale::Float64 = 1.0)
	PS = PlotlySupply
	return Base.ScopedValues.with(PS._S3_EXPORT_SIZE => (Float64(size[1]), Float64(size[2]))) do
		camera = _v4_camera(p, key)
		eye = _v4_xyz(camera[:eye])
		center = haskey(camera, :center) ? _v4_xyz(camera[:center]) : zeros(3)
		offset = eye .- center
		distance = sqrt(sum(abs2, offset))
		frame = PS._s3_camera_frame(offset ./ distance, PS._s3_camera_up(camera))
		width, height = PS._s3_viewport(p, PS._s3_layout_target(p, key))
		corners, quads = PS._s3_label_layout(PS._s3_drawn_box(p, key), Tuple(center), frame, distance * scale,
			Float64(width), Float64(height), PS._s3_axis_labels(p, key), PS._s3_scene_spans(p, key))
		points = collect(Iterators.flatten((corners, Iterators.flatten(quads))))
		return maximum(point -> max(abs(point[1]) / (width / 2), abs(point[2]) / (height / 2)), points)
	end
end
# Ticks plotly.js labels on [lo, hi] with `count` automatic ticks.
function _v4_labelled(lo, hi, count)
	step = PlotlySupply._s3_plotly_tick_step(hi - lo, count)
	return floor(Int, hi / step + 1e-9) - ceil(Int, lo / step - 1e-9) + 1
end

# Whether a count above `count` (up to plotly.js's 9) labels two ticks of
# scene axis `d` of `p` on [lo, hi] with consecutive labels at least the
# widest of them plus one character apart along the axis as drawn at `size`
# (K4: the rule `_s3_cell_tick_count` follows; the counts are scanned while
# the labels stay apart, as their spacing only shrinks with the count).
function _v4_two_labels_fit(p::Plot, key::Symbol, d::Int, lo, hi, count, size)
	PS = PlotlySupply
	length_px = Base.ScopedValues.with(PS._S3_EXPORT_SIZE => (Float64(size[1]), Float64(size[2]))) do
		PS._s3_axis_pixel_lengths(p, PS._s3_layout_target(p, key), PS._s3_drawn_box(p, key))[d]
	end
	axis = _v4_fields(_v4_fields(p.layout.fields[key])[(:xaxis, :yaxis, :zaxis)[d]])
	layout_font = _v4_fields(get(p.layout.fields, :font, Dict{Symbol, Any}()))
	font = haskey(axis, :tickfont) ? _v4_fields(axis[:tickfont])[:size] : get(layout_font, :size, 12)
	char_px = PS._S3_CHAR_EM * PS._s3_tick_text_size(Float64(font))
	for n in (count + 1):9
		step = PS._s3_plotly_tick_step(hi - lo, n)
		first_tick, last_tick = ceil(lo / step - 1e-9) * step, floor(hi / step + 1e-9) * step
		chars = max(PS._s3_tick_text_chars(first_tick, step), PS._s3_tick_text_chars(last_tick, step))
		step / (hi - lo) * length_px >= (chars + 1) * char_px || return false
		_v4_labelled(lo, hi, n) >= 2 && return true
	end
	return false
end

@testset "regression: 3-D wave 4 (v4 threed)" begin
	PS = PlotlySupply

	@testset "G34 view!/scene! return nothing on a Plot" begin
		f = plot_surface(rand(3, 3))
		@test view!(f; elev = 10, azim = 20) === nothing
		@test scene!(f; aspectratio = (1, 1, 1)) === nothing
		@test _v4_fields(_v4_fields(f.layout.fields[:scene])[:aspectratio])[:x] == 1
	end

	@testset "Y7 the delegate's warnings and errors name the 3-D mutator" begin
		sf = subplots(1, 2; sync = false, specs = fill(Spec(kind = "scene"), 1, 2))
		@test_logs (:warn, r"^plot_surface!: per-subplot plot_\*! ignores figure-level keyword\(s\) \[:width\]") match_mode = :any plot_surface!(sf, rand(3, 3); row = 1, col = 1, width = 500)
		@test_logs (:warn, r"^plot_scatter3d!: per-subplot plot_\*! ignores figure-level keyword\(s\) \[:height\]") match_mode = :any plot_scatter3d!(sf, 1:3, 1:3, 1:3; row = 1, col = 2, height = 300)
		@test _v4_message(() -> plot_surface!(sf, rand(3, 3); row = 3, col = 1)) == "plot_surface!: `row` must be in 1:1; got 3."
		@test _v4_message(() -> plot_scatter3d!(sf, 1:3, 1:3, 1:3; row = 1, col = 5)) == "plot_scatter3d!: `col` must be in 1:2; got 5."
	end

	@testset "G18/G74 scatter3d marker symbols, hollow markers and edges" begin
		x = [1.0, 2, 3]
		m(; kw...) = _v4_marker(plot_scatter3d(x, x, x; mode = "markers", kw...).data[1])
		for (code, symbol) in ("o" => "circle", "." => "circle", "s" => "square", "D" => "diamond", "d" => "diamond",
			"+" => "cross", "P" => "cross", "x" => "x", "X" => "x", "diamond-open" => "diamond-open")
			@test m(marker_symbol = code)[:symbol] == symbol
		end
		@test m(marker_symbol = ".")[:size] == PS._CMN_POINT_MARKER_SIZE
		# Hollow: the open symbol in the series colour, no outline.
		hollow = m(marker_color = "none")
		@test (hollow[:symbol], hollow[:color], haskey(hollow, :line)) == ("circle-open", "#636EFA", false)
		@test m(marker_color = :none, marker_symbol = "s")[:symbol] == "square-open"
		@test m(marker_color = "none", marker_symbol = "x")[:symbol] == "x"
		ring = m(marker_color = "none", marker_line_width = 2, color = "#123456")
		@test ring[:color] == "#123456"
		@test _v4_fields(ring[:line]) == Dict(:color => "#123456", :width => 2.0)
		# A face colour gets an outline in the series colour (a white face stays visible).
		white = m(marker_color = "white", color = "blue")
		@test white[:color] == "white"
		@test _v4_fields(white[:line]) == Dict(:color => "blue", :width => PS._CMN_DEFAULT_MARKER_EDGE_WIDTH)
		edge = m(marker_line_color = "red", marker_line_width = 3)
		@test !haskey(edge, :color)
		@test _v4_fields(edge[:line]) == Dict(:color => "red", :width => 3.0)
		@test _v4_fields(m(marker_line_width = 2, color = "green")[:line])[:color] == "green"
		# Edge colours with an alpha channel are blended like line colours (G62).
		@test _v4_fields(m(marker_color = "white", marker_line_color = "rgba(0,0,0,0.5)")[:line])[:color] == "#808080"
		two = plot_scatter3d([x, x], [x, x], [x, 2x]; mode = "markers", marker_line_color = ["red", "blue"], marker_line_width = [1, 2])
		@test [_v4_fields(_v4_marker(t)[:line])[:color] for t in two.data] == ["red", "blue"]
		@test [_v4_fields(_v4_marker(t)[:line])[:width] for t in two.data] == [1.0, 2.0]
		g = plot_scatter3d(x, x, x)
		@test plot_scatter3d!(g, x, x, x; mode = "markers", marker_color = "none", marker_symbol = "D") === nothing
		@test _v4_marker(g.data[end])[:symbol] == "diamond-open"
		@test startswith(_v4_message(() -> plot_scatter3d(x, x, x; marker_symbol = "^")),
			"plot_scatter3d: `marker_symbol` must be one of \"circle\"")
		@test _v4_message(() -> plot_scatter3d(x, x, x; marker_line_width = -1)) ==
			"plot_scatter3d: `marker_line_width` must be >= 0; got -1."
		@test startswith(_v4_message(() -> plot_scatter3d(x, x, x; marker_line_color = "notacolor")),
			"plot_scatter3d: `marker_line_color`: invalid colour \"notacolor\"")
		@test startswith(_v4_message(() -> plot_scatter3d!(g, x, x, x; marker_color = "bogus")),
			"plot_scatter3d!: `marker_color`: invalid colour \"bogus\"")
		@test _v4_message(() -> plot_scatter3d(x, x, x; markevery = 0)) ==
			"plot_scatter3d: an integer `markevery` is a step and must be >= 1; got 0."
	end

	@testset "G18 scatter3d markevery" begin
		x = collect(1.0:5)
		f = plot_scatter3d(x, x, x; mode = "lines", markevery = 2, color = "red", legend = "s")
		@test length(f.data) == 2
		line, marked = f.data
		@test (line.fields[:mode], line.fields[:x], line.fields[:showlegend], haskey(line.fields, :marker)) ==
			("lines", x, false, false)
		@test (marked.fields[:mode], marked.fields[:hoverinfo], marked.fields[:name]) == ("lines+markers", "skip", "s")
		@test get(marked.fields, :showlegend, true) != false
		@test isequal(marked.fields[:x], [1.0, nothing, 3.0, nothing, 5.0, nothing])
		@test _v4_line(line)[:color] == _v4_line(marked)[:color] == "red"
		@test plot_scatter3d(x, x, x; mode = "markers", markevery = [1, 3]).data[1].fields[:x] == [1.0, 3.0]
		# A split series keeps its colour and the next series the next one.
		two = plot_scatter3d([x, x], [x, x], [x, 2x]; mode = "lines", markevery = [2, nothing])
		@test [t.fields[:mode] for t in two.data] == ["lines", "lines+markers", "lines"]
		@test [_v4_line(t)[:color] for t in two.data] == ["#636EFA", "#636EFA", "#EF553B"]
		g = plot_scatter3d(x, x, x)
		@test plot_scatter3d!(g, x, x, x; mode = "lines", markevery = 2) === nothing
		@test length(g.data) == 3
	end

	@testset "G62/G81 translucent 3-D line colours are blended over the background" begin
		tri = [[0.0 0 0; 1 0 0; 0 1 0]]
		edge(color) = only(_v4_line(t)[:color] for t in plot_polygons3d(tri; edgecolor = color).data if t.fields[:type] == "scatter3d")
		@test edge("rgba(255,255,255,0.48)") == "#FFFFFF"
		@test edge("rgba(0,0,0,0.48)") == "#858585"
		@test edge("#FF000080") == "#FF7F7F"
		@test edge(PS.Colors.RGBA(1, 0, 0, 0.5)) == "#FF8080"
		@test edge("0.5") == "#808080"
		@test edge("red") == "red"
		seg = ([0.0], [0.0], [0.0], [1.0], [1.0], [1.0])
		@test _v4_line(plot_segments3d(seg...; color = "rgba(255,0,0,0.5)").data[1])[:color] == "#FF8080"
		@test _v4_line(plot_scatter3d([1.0, 2], [1.0, 2], [1.0, 2]; color = "rgba(0,0,255,0.5)").data[1])[:color] == "#8080FF"
		@test _v4_line(plot_wireframe([0.0, 1.0], [0.0, 1.0], rand(2, 2); color = "rgba(0,0,0,0.25)").data[1])[:color] == "#BFBFBF"
		arrows = plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; style = :arrow, color = "rgba(0,128,0,0.5)")
		@test _v4_line(arrows.data[1])[:color] == "#80C080"
		s = plot_surface([0.0, 1, 2], [0.0, 1, 2], rand(3, 3); edges = true, edgecolor = "rgba(0,0,0,0.5)")
		@test _v4_fields(_v4_fields(s.data[1].fields[:contours])[:x])[:color] == "#808080"
		mesh = plot_mesh3d([0.0, 1, 0], [0.0, 0, 1], [0.0, 0, 0]; i = [0], j = [1], k = [2], edges = true,
			edgecolor = "rgba(0,0,0,0.5)")
		@test [_v4_line(t)[:color] for t in mesh.data if t.fields[:type] == "scatter3d"] == ["#808080"]
		# Cones are surfaces: the colour scale keeps the alpha channel.
		cone = plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; color = "rgba(0,128,0,0.5)")
		@test cone.data[1].fields[:colorscale] == [[0, "rgba(0,128,0,0.5)"], [1, "rgba(0,128,0,0.5)"]]
		# The background is the figure's, also in a subplot cell.
		sf = subplots(1, 2; sync = false, specs = fill(Spec(kind = "scene"), 1, 2))
		plot_segments3d!(sf, seg...; row = 1, col = 2, color = "rgba(255,0,0,0.5)")
		@test _v4_line(sf.plot.data[end])[:color] == "#FF8080"
		dark = plot_scatter3d([1.0, 2], [1.0, 2], [1.0, 2])
		relayout!(dark; paper_bgcolor = "black")
		@test plot_segments3d!(dark, seg...; color = "rgba(255,255,255,0.5)") === nothing
		@test _v4_line(dark.data[end])[:color] == "#808080"
		@test startswith(_v4_message(() -> plot_segments3d(seg...; color = "rgba(1,2)")),
			"plot_segments3d: `color`: invalid colour \"rgba(1,2)\"")
	end

	@testset "G45 documented: content outside the scene ranges" begin
		@test occursin("outside the scene's axis ranges is not drawn", string(@doc annotate!))
		for f in (plot_quiver3d, plot_segments3d, plot_scatter3d)
			@test occursin("A scene draws only what lies inside its axis ranges", string(Base.Docs.doc(f)))
		end
	end

	@testset "V3 plotly.js tick steps and cell tick counts" begin
		@test PS._s3_plotly_tick_step(4.25, 2) == 5.0
		@test PS._s3_plotly_tick_step(2.0, 1) == 5.0
		@test PS._s3_plotly_tick_step(1.0, 1) == 2.0
		@test PS._s3_plotly_tick_step(4.25, 3) == 2.0
		# log(1000)/LN10 is just below 3, as in JavaScript.
		@test PS._s3_plotly_tick_step(1000.0, 1) == 1000.0
		@test PS._s3_tick_text_chars(-0.5, 0.5) == 4
		@test PS._s3_tick_text_chars(12.0, 2.0) == 2
		@test PS._s3_tick_text_chars(10000.0, 5000.0) == 4
		@test PS._s3_tick_text_chars(0.0002, 0.0001) == 4
		xs, ys, Z = _v4_surface_data()
		f = plot_surface(xs, ys, Z)
		@test PS._s3_axis_range(f, :scene, 1, nothing) == (-2.125, 2.125)
		@test PS._s3_axis_range(plot_scatter3d([3.0], [1.0], [1.0]), :scene, 1, nothing) == (2.0, 4.0)
		@test PS._s3_axis_range(f, :scene, 1, Dict(:range => [0, 5])) == (0.0, 5.0)
		# Two ticks over 4.25 label only 0; three label -2, 0 and 2 once the
		# axis is long enough to keep "-2" and "0" apart.
		@test _v4_labelled(-2.125, 2.125, 2) == 1
		@test [PS._s3_cell_tick_count(f, :scene, 1, nothing, L, 2, 12.0) for L in (30.0, 60.0, 100.0)] == [2, 3, 3]
		@test PS._s3_cell_tick_count(f, :scene, 1, Dict(:type => "log"), 100.0, 2, 12.0) == 2
		@test PS._s3_cell_tick_count(f, :scene, 1, nothing, 400.0, 9, 12.0) == 9
	end

	@testset "V3 export viewport leaves room for colorbars" begin
		xs, ys, Z = _v4_surface_data()
		# 2 xpad + thickness + outline/2 + gap + "0.5" (3 × 0.56 × 12 px) wide,
		# at x = 1.02 of the plot area: r = (0.02·650 + bar + 12) / 1.02.
		bar = 2 * 10 + 30 + 0.5 + 4 + 3 * 0.56 * 12
		f = plot_surface(xs, ys, Z)
		r = PS._s3_colorbar_right_margin(f, 700.0, 50.0, 50.0)
		@test r ≈ (0.02 * 650 + bar + 12) / 1.02 atol = 0.01
		@test PS._s3_colorbar_right_margin(plot_surface(xs, ys, Z; colorbar_title = "amplitude", colorbar_title_side = :right),
			700.0, 50.0, 50.0) ≈ (0.02 * 650 + bar + 1.4 * 12 + 12) / 1.02 atol = 0.01
		@test PS._s3_colorbar_right_margin(plot_surface(xs, ys, Z; showscale = false), 700.0, 50.0, 50.0) == 50.0
		horizontal = plot_surface(xs, ys, Z)
		horizontal.data[1].fields[:colorbar] = attr(orientation = "h")
		@test PS._s3_colorbar_right_margin(horizontal, 700.0, 50.0, 50.0) == 50.0
		# The viewport is the plot area the finalizer's margins leave (W6), with
		# the colorbar's room on the right.
		width, height = Base.ScopedValues.with(PS._S3_EXPORT_SIZE => (700.0, 500.0)) do
			PS._s3_viewport(f, PS._s3_layout_target(f, :scene))
		end
		m = PS._fin_margins(f.layout, PS._fin_collect_axes(f), 700.0, 500.0, Dict{Symbol, Any}(), ())
		@test width ≈ 700 - m.l - PS._s3_colorbar_right_margin(f, 700.0, m.l, m.r)
		@test height ≈ 500 - m.t - m.b
		@test PS._s3_colorbar_right_margin(f, 700.0, m.l, m.r) > m.r
		# Outside an export the figure's own size is used: here none is set, so
		# the active style's default size (700 x 500 under :default, Z69).
		@test PS._style_default_figure_size() == (700, 500)
		@test PS._s3_viewport(f, PS._s3_layout_target(f, :scene)) == (width, height)
	end

	@testset "G72/G82/V3 export refit of scene cameras and cell ticks" begin
		xs, ys, Z = _v4_surface_data()
		f = plot_surface(xs, ys, Z; xlabel = "Material scale α", ylabel = "Time step Δt", zlabel = "Frequency ratio R")
		before = PlotlyBase.JSON.json(f)
		camera0 = _v4_camera(f)
		offset0 = _v4_xyz(camera0[:eye]) .- (haskey(camera0, :center) ? _v4_xyz(camera0[:center]) : zeros(3))
		# The figure is framed for its own size when it is built (W6): an export
		# at that size has nothing to refit.
		@test PS._s3_refit_scenes!(_v4_copy(f), f, (700, 500)) === false
		@test 0.97 < _v4_label_extent(f, :scene, (700, 500)) <= 1
		target = _v4_copy(f)
		@test PS._s3_refit_scenes!(target, f, (900, 350)) === true
		@test PlotlyBase.JSON.json(f) == before
		camera = _v4_camera(target)
		eye = _v4_xyz(camera[:eye])
		center = _v4_xyz(camera[:center])
		offset = eye .- center
		# The direction is kept; the drawing, labels included, uses the viewport.
		@test offset ./ sqrt(sum(abs2, offset)) ≈ offset0 ./ sqrt(sum(abs2, offset0)) atol = 1e-9
		@test 0.97 < _v4_label_extent(target, :scene, (900, 350)) <= 1
		@test _v4_label_extent(target, :scene, (900, 350), 0.97) > 1
		# Without `pan` the camera centre returns to the origin.
		fixed = _v4_copy(f)
		PS._s3_refit_scenes!(fixed, f, (700, 500); pan = false)
		@test !haskey(_v4_camera(fixed), :center)
		@test _v4_label_extent(fixed, :scene, (700, 500)) <= 1
		# A camera the user placed is left alone.
		user = plot_surface(xs, ys, Z)
		view!(user; elev = 30, azim = 40, distance = 3)
		user_copy = _v4_copy(user)
		PS._s3_refit_scenes!(user_copy, user, (900, 350))   # (its tick counts follow the size)
		@test _v4_camera(user_copy) == _v4_camera(user)
		# A 1x3 grid at 900x350: every scene fits its cell, labels included,
		# and its x and y axes label two ticks whenever two labels fit (K4).
		sf = subplots(1, 3; sync = false, specs = fill(Spec(kind = "scene"), 1, 3))
		for c in 1:3
			plot_surface!(sf, xs, ys, Z .* c; row = 1, col = c, xlabel = "x", ylabel = "y", zlabel = "height")
		end
		grid = _v4_copy(sf.plot)
		@test PS._s3_refit_scenes!(grid, sf.plot, (900, 350)) === true
		for key in (:scene, :scene2, :scene3)
			@test 0.9 < _v4_label_extent(grid, key, (900, 350)) <= 1
			scene = _v4_fields(grid.layout.fields[key])
			counts = [_v4_fields(scene[axis])[:nticks] for axis in (:xaxis, :yaxis, :zaxis)]
			@test all(n -> 2 <= n <= 9, counts)
			for (d, (lo, hi)) in ((1, (-2.125, 2.125)), (2, (-1.0625, 1.0625)))
				@test _v4_labelled(lo, hi, counts[d]) >= 2 || !_v4_two_labels_fit(grid, key, d, lo, hi, counts[d], (900, 350))
			end
		end
		@test _v4_message(() -> PS._s3_refit_scenes!(_v4_copy(f), f, (0, 500))) ==
			"_s3_refit_scenes!: `size` must be (width, height) in px; got (0, 500)."
		@test _v4_message(() -> PS._s3_refit_scenes!(f, f, (700, 500))) ==
			"_s3_refit_scenes!: `target` must have its own layout (it is written in place)."
	end
end

# Wave-5 3-D items (v5 "threed"); each testset names its item id.
_v5_scene(p::Plot, key::Symbol = :scene) = _v4_fields(p.layout.fields[key])
_v5_axis(p::Plot, key::Symbol, axis::Symbol) = _v4_fields(_v5_scene(p, key)[axis])
_v5_center(camera) = haskey(camera, :center) ? _v4_xyz(camera[:center]) : zeros(3)
_v5_offset(p::Plot, key::Symbol = :scene) = (c = _v4_camera(p, key); _v4_xyz(c[:eye]) .- _v5_center(c))
_v5_distance(p::Plot, key::Symbol = :scene) = sqrt(sum(abs2, _v5_offset(p, key)))
_v5_width(p::Plot, key::Symbol) = (d = _v4_fields(_v5_scene(p, key)[:domain]); d[:x][2] - d[:x][1])
# The size a scene axis draws its tick labels at: its `tickfont.size`, else
# (plotly.js's inheritance) the figure font size, else plotly's 12.
function _v5_tickfont(p::Plot, key::Symbol, axis::Symbol)
	axis_fields = _v5_axis(p, key, axis)
	haskey(axis_fields, :tickfont) && return _v4_fields(axis_fields[:tickfont])[:size]
	font = get(p.layout.fields, :font, nothing)
	return font === nothing ? 12 : get(_v4_fields(font), :size, 12)
end
_v5_scene_sf(rows, cols) = subplots(rows, cols; sync = false, specs = fill(Spec(kind = "scene"), rows, cols))
# Run `f` under `style`; `with_style` restores the previous style afterwards
# (`set_default_style!()` without arguments would keep `style` active).
_v5_with_style(f, style) = with_style(f, style)

@testset "regression: 3-D wave 5 (v5 threed)" begin
	PS = PlotlySupply
	xs, ys, Z = _v4_surface_data()

	@testset "W6 identical cells give identical scenes (topo_torus layout)" begin
		# Three equal scene cells sharing one colour axis whose colorbar the
		# finalizer places (beside the last cell drawn so far, then beside the
		# row), above a full-width 2-D row; also under a style with colorbar
		# defaults (topo_torus's), whose styled shared bar must not lose its
		# placement and leave the middle cell narrowed.
		for style in (:default, PlotStyle(; tick_fontsize = 9))
			with_style(style) do
				sf = subplots(2, 3; sync = false, height_ratios = [2, 1],
					specs = [Spec(kind = "scene") Spec(kind = "scene") Spec(kind = "scene"); Spec(colspan = 3) missing missing])
				for c in 1:3
					plot_surface!(sf, xs, ys, Z; row = 1, col = c, shared_coloraxis = true, crange = (0, 1))
					view!(sf; row = 1, col = c, elev = 33, azim = -61)
				end
				colorbar!(sf; coloraxis = :shared, len = 0.3, y = 0.78)
				plot_heatmap!(sf, 1:4, 1:3, rand(4, 3); row = 2, col = 1, showscale = false)
				p = sf.plot
				keys3 = (:scene, :scene2, :scene3)
				widths = [_v5_width(p, k) for k in keys3]
				@test maximum(widths) - minimum(widths) < 1e-9
				distances = [_v5_distance(p, k) for k in keys3]
				@test maximum(distances) / minimum(distances) - 1 < 1e-6
				@test all(k -> _v5_offset(p, k) ./ _v5_distance(p, k) ≈ _v5_offset(p, :scene) ./ _v5_distance(p, :scene), keys3)
				for axis in (:xaxis, :yaxis, :zaxis)
					@test length(unique(get(_v5_axis(p, k, axis), :nticks, nothing) for k in keys3)) == 1
					@test length(unique(PlotlyBase.JSON.json(get(_v5_axis(p, k, axis), :tickfont, nothing)) for k in keys3)) == 1
				end
			end
		end
	end

	@testset "W6/Z45 framed live, at the layout size and at another size" begin
		f = plot_surface(xs, ys, Z; xlabel = "x", ylabel = "y", zlabel = "height")
		# A constructor returns the figure framed (labels included) for its size.
		@test PS._s3_finalize_scenes!(f) === false
		@test 0.97 < _v4_label_extent(f, :scene, (700, 500)) <= 1
		@test _v4_label_extent(f, :scene, (700, 500), 0.97) > 1
		# savefig at the layout size renders the figure itself; at another size
		# a copy framed for that size.
		@test PS._export_source(f, PS._normalize_export_options(f, (width = 700, height = 500))) === f
		other = PS._export_source(f, PS._normalize_export_options(f, (width = 900, height = 350)))
		@test other !== f
		@test 0.97 < _v4_label_extent(other, :scene, (900, 350)) <= 1
		@test _v4_label_extent(other, :scene, (900, 350), 0.97) > 1
		# Mutations keep it framed: data, axis titles (Z45), ranges, the size.
		plot_scatter3d!(f, [0.0, 4.0], [0.0, 1.0], [0.0, 2.0])
		@test PS._s3_finalize_scenes!(f) === false
		@test 0.97 < _v4_label_extent(f, :scene, (700, 500)) <= 1
		d0 = _v5_distance(f)
		# (Titles that fit the 232 px tall viewport at 900 x 350: a 40-character
		# z title, about 314 px long at 14 px, overflows at any distance.)
		zlabel!(f, "A long z title")
		xlabel!(f, "A long x axis title")
		# (Longer titles never bring the camera closer; the distance is found to
		# 2e-4, so a small change may not show in it.)
		@test _v5_distance(f) >= d0 * (1 - 2e-4)
		@test PS._s3_finalize_scenes!(f) === false
		@test 0.97 < _v4_label_extent(f, :scene, (700, 500)) <= 1
		zrange!(f, (0, 3))
		@test PS._s3_finalize_scenes!(f) === false
		@test 0.97 < _v4_label_extent(f, :scene, (700, 500)) <= 1
		figsize!(f, 900, 350)
		@test PS._s3_finalize_scenes!(f) === false
		@test 0.97 < _v4_label_extent(f, :scene, (900, 350)) <= 1
		@test PS._export_source(f, PS._normalize_export_options(f, NamedTuple())) === f
		# The same in a scene cell of a SubplotFigure.
		sf = _v5_scene_sf(1, 2)
		plot_surface!(sf, xs, ys, Z; row = 1, col = 2)
		d0 = _v5_distance(sf.plot, :scene2)
		xlabel!(sf, "A long x title"; row = 1, col = 2)
		@test _v5_distance(sf.plot, :scene2) > d0
		@test PS._s3_finalize_scenes!(sf.plot) === false
		@test 0.97 < _v4_label_extent(sf.plot, :scene2, (700, 500)) <= 1
		ylabel!(sf, ""; row = 1, col = 2)
		zrange!(sf, (0, nothing); row = 1, col = 2)
		@test PS._s3_finalize_scenes!(sf.plot) === false
		@test 0.97 < _v4_label_extent(sf.plot, :scene2, (700, 500)) <= 1
		@test _v4_message(() -> PS._s3_finalize_scenes!(_v4_copy(f), (0, 500))) ==
			"_s3_finalize_scenes!: `size` must be (width, height) in px; got (0, 500)."
		@test _v4_message(() -> PS._s3_finalize_scenes!(_v4_copy(f), (700, NaN))) ==
			"_s3_finalize_scenes!: `size` must be (width, height) in px; got (700, NaN)."
		# Scenes PlotlySupply did not frame (no mark) are left alone.
		raw = Plot(PlotlyBase.GenericTrace("surface"; z = Z))
		@test PS._s3_finalize_scenes!(raw, (700, 500)) === false
		@test !haskey(raw.layout.fields, :scene)
	end

	@testset "W6 an elongated scene seen nearly end-on is centred and fills its viewport" begin
		# The camera centre is moved to centre the drawing; close to a long
		# box the first pan step overshoots (labels near the eye), which used
		# to make the search stop at a distance that left a fifth of the
		# viewport empty.
		h = plot_scatter3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0]; aspectmode = "data", zrange = (0, 1))
		view!(h; elev = 20, azim = 10)
		plot_scatter3d!(h, [0.0, 9.0], [0.0, 1.0], [0.0, 1.0])
		@test 0.97 < _v4_label_extent(h, :scene, (700, 500)) <= 1
		@test _v4_label_extent(h, :scene, (700, 500), 0.97) > 1
		@test PS._s3_finalize_scenes!(h) === false
		# The same in a cell, at another size.
		sf = _v5_scene_sf(1, 2)
		plot_scatter3d!(sf, [0.0, 9.0], [0.0, 1.0], [0.0, 1.0]; row = 1, col = 2, aspectmode = "data")
		view!(sf; row = 1, col = 2, elev = 20, azim = 10)
		other = PS._export_source(sf.plot, PS._normalize_export_options(sf.plot, (width = 900, height = 350)))
		@test 0.97 < _v4_label_extent(other, :scene2, (900, 350)) <= 1
	end

	@testset "W6 a small cell gives its box room for the labels (no title cut off by the viewport)" begin
		# 7.16 in wide, three columns: the fixed pixel offsets of plotly.js's tick
		# labels and titles leave a box of under half the cell; the old floor of
		# half the cell left the y title outside the viewport.
		with_style(:ieee) do
			sf = subplots(1, 3; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene") Spec(kind = "scene")])
			for c in 1:3
				plot_surface!(sf, xs, ys, Z; row = 1, col = c, xlabel = "x", ylabel = "y", zlabel = "z", showscale = false)
			end
			figsize!(sf, :ieee; columns = 2, aspect = 0.32)
			size_px = (sf.plot.layout.fields[:width], sf.plot.layout.fields[:height])
			for key in (:scene, :scene2, :scene3)
				@test 0.97 < _v4_label_extent(sf.plot, key, size_px) <= 1
			end
			@test PS._s3_finalize_scenes!(sf.plot) === false
		end
	end

	@testset "W6 a user camera is kept; zoom scales the fitted distance" begin
		g = plot_surface(xs, ys, Z)
		relayout!(g; scene_camera_center = attr(x = 0.1, y = 0.0, z = 0.0))
		eye = _v4_xyz(_v4_camera(g)[:eye])
		plot_scatter3d!(g, [0.0, 1.0], [0.0, 1.0], [0.0, 1.0])
		@test _v5_center(_v4_camera(g)) == [0.1, 0.0, 0.0]
		@test _v4_xyz(_v4_camera(g)[:eye]) == eye
		h = plot_surface(xs, ys, Z)
		relayout!(h; scene_camera_eye = attr(x = 0.5, y = -2.0, z = 1.0))
		plot_scatter3d!(h, [0.0, 1.0], [0.0, 1.0], [0.0, 1.0])
		@test _v4_xyz(_v4_camera(h)[:eye]) == [0.5, -2.0, 1.0]
		PS._s3_finalize_scenes!(h, (900, 350))   # (its tick counts follow the size)
		@test _v4_xyz(_v4_camera(h)[:eye]) == [0.5, -2.0, 1.0]
		k = plot_surface(xs, ys, Z; width = 1100, height = 800)   # axes long enough for plotly's own tick counts
		view!(k; elev = 30, azim = -60)
		auto = _v5_distance(k)
		view!(k; elev = 30, azim = -60, zoom = 1.5)
		@test _v5_distance(k) ≈ auto / 1.5 rtol = 1e-6
		# The zoom survives an export at another size: the distance fitted there
		# divided by 1.5, so the drawing overflows the viewport.
		opts = PS._normalize_export_options(k, (width = 900, height = 350))
		unzoomed = plot_surface(xs, ys, Z; width = 1100, height = 800)
		view!(unzoomed; elev = 30, azim = -60)
		at = PS._export_source(k, opts)
		# (the tick counts of the short axes at 900 x 350 follow the zoomed axes' length, so the labels differ a little)
		@test _v5_distance(at) ≈ _v5_distance(PS._export_source(unzoomed, opts)) / 1.5 rtol = 0.1
		@test _v4_label_extent(at, :scene, (900, 350)) > 1.2
	end

	@testset "W6 scene tick and title fonts follow the style" begin
		_v5_with_style(PlotStyle(; tick_fontsize = 9, label_fontsize = 11)) do
			sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec()])
			plot_surface!(sf, xs, ys, Z; row = 1, col = 1, xlabel = "x")
			plot_scatter!(sf, 1:3, 1:3; row = 1, col = 2)
			p = sf.plot
			# gl3d draws scene tick text tickfont.size^2/12 px large: 9 px wants
			# sqrt(12 * 9); axis titles are drawn at their size.
			for axis in (:xaxis, :yaxis, :zaxis)
				@test _v5_tickfont(p, :scene, axis) ≈ sqrt(12 * 9)
			end
			@test _v4_fields(_v4_fields(_v5_axis(p, :scene, :xaxis)[:title])[:font])[:size] == 11
			two_d = [k for k in keys(p.layout.fields) if occursin(r"^xaxis\d*$", String(k))]
			@test !isempty(two_d)
			@test all(k -> _v4_fields(_v4_fields(p.layout.fields[k])[:tickfont])[:size] == 9, two_d)
			# Repeated finalizing does not compound; a size the user writes is
			# compensated in turn.
			@test PS._s3_finalize_scenes!(p) === false
			relayout!(p; scene_xaxis_tickfont_size = 20)
			plot_surface!(sf, xs, ys, Z; row = 1, col = 1)
			@test _v5_tickfont(p, :scene, :xaxis) ≈ sqrt(12 * 20)
			@test _v5_tickfont(p, :scene, :yaxis) ≈ sqrt(12 * 9)
		end
		# Without a style the scene ticks are drawn at the figure font size.
		f = plot_surface(xs, ys, Z)
		@test _v5_tickfont(f, :scene, :zaxis) ≈ 12
		relayout!(f; font = attr(size = 16))
		view!(f; elev = 20, azim = 30)
		@test _v5_tickfont(f, :scene, :zaxis) ≈ sqrt(12 * 16)
	end

	@testset "W6 perf guard: framing reads each trace's data once per axis" begin
		big = _v5_scene_sf(1, 3)
		Zb = [sin(i / 9) * cos(j / 7) for i in 1:250, j in 1:250]
		for c in 1:3
			plot_surface!(big, Zb; row = 1, col = c, xlabel = "x", zlabel = "z")
		end
		PS._s3_finalize_scenes!(_v4_copy(big.plot), (900, 350))   # compile
		framed = _v4_copy(big.plot)
		elapsed = @elapsed PS._s3_finalize_scenes!(framed, (800, 450))
		@test elapsed < 1.0
		@test PS._s3_finalize_scenes!(framed, (800, 450)) === false
	end

	@testset "Z69 the framing size falls back to the style's default size" begin
		_v5_with_style(PlotStyle(; width = 350, aspect = 0.8)) do
			@test PS._style_default_figure_size() == (350, 280)
			g = plot_surface(xs, ys, Z)
			delete!(g.layout.fields, :width)
			delete!(g.layout.fields, :height)
			m = PS._fin_margins(g.layout, PS._fin_collect_axes(g), 350.0, 280.0, Dict{Symbol, Any}(), ())
			w, h = PS._s3_viewport(g, PS._s3_layout_target(g, :scene))
			@test w ≈ 350 - m.l - PS._s3_colorbar_right_margin(g, 350.0, m.l, m.r)
			@test h ≈ 280 - m.t - m.b
		end
	end

	@testset "Z55 one-sided ranges on the 3-D constructor and mutator keywords" begin
		lo, hi = extrema(Z)
		top = hi + (hi - lo) / 32   # the open end: data end widened by 1/32 (zrange!)
		a = plot_surface(xs, ys, Z; zrange = (0, nothing))
		b = plot_surface(xs, ys, Z)
		zrange!(b, (0, nothing))
		@test _v5_axis(a, :scene, :zaxis)[:range] ≈ [0, top]
		@test _v5_axis(a, :scene, :zaxis)[:range] == _v5_axis(b, :scene, :zaxis)[:range]
		@test _v5_scene(a)[:aspectmode] == "manual"   # the range is pinned (Y26)
		s = plot_scatter3d([0.0, 2.0], [0.0, 1.0], [0.5, 3.0]; xrange = (nothing, 5))
		@test _v5_axis(s, :scene, :xaxis)[:range] ≈ [-2 / 32, 5]
		# A mutator resolves against all the scene's data.
		plot_scatter3d!(s, [0.0, 4.0], [0.0, 1.0], [0.0, 1.0]; zrange = (-1, nothing))
		@test _v5_axis(s, :scene, :zaxis)[:range] ≈ [-1, 3 + 3 / 32]
		scene!(s; yrange = (nothing, 2))
		@test _v5_axis(s, :scene, :yaxis)[:range] ≈ [-1 / 32, 2]
		# SubplotFigure cells: the open end comes from the cell's data.
		sf = _v5_scene_sf(1, 2)
		plot_scatter3d!(sf, [0.0, 1.0], [0.0, 1.0], [0.0, 8.0]; row = 1, col = 2)
		plot_surface!(sf, xs, ys, Z; row = 1, col = 2, zrange = (-1, nothing))
		@test _v5_axis(sf.plot, :scene2, :zaxis)[:range] ≈ [-1, 8 + 8 / 32]
		# A reversed axis keeps its direction; the bounds are in the order the
		# axis is drawn, as zrange! takes them.
		r = plot_scatter3d([0.0, 2.0], [0.0, 1.0], [0.0, 4.0])
		relayout!(r; scene_zaxis_autorange = "reversed")
		r2 = plot_scatter3d([0.0, 2.0], [0.0, 1.0], [0.0, 4.0])
		relayout!(r2; scene_zaxis_autorange = "reversed")
		scene!(r; zrange = (1, nothing))
		zrange!(r2, (1, nothing))
		@test _v5_axis(r, :scene, :zaxis)[:range] ≈ [1, -4 / 32]
		@test _v5_axis(r, :scene, :zaxis)[:range] == _v5_axis(r2, :scene, :zaxis)[:range]
		# On a log axis the fixed bound is a data value, as with xrange!.
		l = plot_scatter3d([1.0, 100.0], [0.0, 1.0], [0.0, 1.0])
		relayout!(l; scene_xaxis_type = "log")
		l2 = plot_scatter3d([1.0, 100.0], [0.0, 1.0], [0.0, 1.0])
		relayout!(l2; scene_xaxis_type = "log")
		scene!(l; xrange = (10, nothing))
		xrange!(l2, (10, nothing))
		@test _v5_axis(l, :scene, :xaxis)[:range] ≈ _v5_axis(l2, :scene, :xaxis)[:range]
		@test _v5_axis(l, :scene, :xaxis)[:range][1] ≈ 1
		@test startswith(_v4_message(() -> scene!(l; xrange = (-1, nothing))),
			"scene!: `xrange` bounds on a logarithmic scene axis")
		# Errors name the call and leave the figure unchanged.
		before = PlotlyBase.JSON.json(s)
		@test startswith(_v4_message(() -> plot_scatter3d!(s, [0.0, 1.0], [0.0, 1.0], [0.0, 1.0]; xrange = (100, nothing))),
			"plot_scatter3d!: `range` = (100, nothing) leaves no room for the data on the x axis")
		@test PlotlyBase.JSON.json(s) == before
		@test startswith(_v4_message(() -> plot_surface(xs, ys, Z; zrange = (missing, 1))),
			"plot_surface: `zrange`: an open bound of a one-sided limit is written `nothing`")
		@test occursin("has none yet", _v4_message(() -> scene!(_v5_scene_sf(1, 2); row = 1, col = 1, zrange = (0, nothing))))
		# (nothing, nothing) is the automatic range.
		@test !haskey(_v5_axis(plot_surface(xs, ys, Z; zrange = (nothing, nothing)), :scene, :zaxis), :range)
	end

	@testset "Z61 3-D traces and colour axes take the style's colorbar defaults" begin
		g = [0.0, 1.0]
		V = [x + y + z for x in g, y in g, z in g]
		_v5_with_style(PlotStyle(; tick_fontsize = 9, label_fontsize = 11, axis_linewidth = 1.5)) do
			styled(bar) = (b = _v4_fields(bar); _v4_fields(b[:tickfont])[:size] == 9 &&
				_v4_fields(_v4_fields(b[:title])[:font])[:size] == 11 && b[:outlinewidth] == 1.5)
			f = plot_surface(xs, ys, Z; colorbar_title = "c")
			plot_surface!(f, xs, ys, Z .+ 1; colorbar_title = "d")
			plot_isosurface!(f, g, g, g, V)
			plot_volume!(f, g, g, g, V)
			plot_mesh3d!(f, [0.0, 1, 0], [0.0, 0, 1], [0.0, 0, 0]; intensity = [0.0, 1, 2])
			plot_quiver3d!(f, g, g, g, g, g, g)
			plot_streamtube!(f, g, g, g, V, V, V)
			@test length(f.data) == 7
			@test all(t -> styled(t.fields[:colorbar]), f.data)
			@test _v4_fields(_v4_fields(f.data[2].fields[:colorbar])[:title])[:text] == "d"
			# SubplotFigure cells, and a colour axis a mutator creates.
			sf = _v5_scene_sf(1, 2)
			plot_surface!(sf, xs, ys, Z; row = 1, col = 1)
			@test styled(sf.plot.data[1].fields[:colorbar])
			plot_surface!(sf, xs, ys, Z; row = 1, col = 2, shared_coloraxis = true)
			plot_surface!(sf, xs, ys, Z; row = 1, col = 1, shared_coloraxis = true)
			@test styled(_v4_fields(sf.plot.layout.fields[:coloraxis])[:colorbar])
		end
	end

	@testset "Z63 3-D colour keywords are checked as colours" begin
		x = [0.0, 1.0]
		# A matplotlib grey level is drawn as its hex colour.
		@test _v4_line(plot_scatter3d(x, x, x; color = "0.35").data[1])[:color] == "#595959"
		@test _v4_line(plot_scatter3d(x, x, x; color = :red).data[1])[:color] == "red"
		@test _v4_line(plot_scatter3d(x, x, x; color = PS.Colors.RGB(1, 0, 0)).data[1])[:color] == "#FF0000"
		# Wrong types are ArgumentErrors naming the call and the keyword.
		@test _v4_message(() -> plot_scatter3d(x, x, x; color = 3.5)) ==
			"plot_scatter3d: `color` must be a colour string, Symbol or Colors.jl Colorant (or a vector of them, one per series); got Float64."
		@test _v4_message(() -> plot_scatter3d([x, x], [x, x], [x, x]; marker_color = ["red", 2])) ==
			"plot_scatter3d: `marker_color[2]` must be a colour string, Symbol or Colors.jl Colorant (or a vector of them, one per series); got Int64."
		@test _v4_message(() -> plot_quiver3d(x, x, x, x, x, x; color = 3.5)) ==
			"plot_quiver3d: `color` must be a colour string, Symbol or Colors.jl Colorant; got Float64."
		# Colours are checked also where they are not drawn.
		@test startswith(_v4_message(() -> plot_surface(xs, ys, Z; edgecolor = "notacolor")),
			"plot_surface: `edgecolor`: invalid colour \"notacolor\"")
		@test startswith(_v4_message(() -> plot_mesh3d([0.0, 1, 0], [0.0, 0, 1], [0.0, 0, 0]; edgecolor = "nope")),
			"plot_mesh3d: `edgecolor`: invalid colour \"nope\"")
		f = plot_scatter3d(x, x, x)
		before = PlotlyBase.JSON.json(f)
		for key in (:bgcolor, :bordercolor, :arrowcolor)
			@test startswith(_v4_message(() -> annotate!(f, 0.5, 0.5, 0.5, "t"; (key => "notacolor",)...)),
				"annotate!: `$(key)`: invalid colour \"notacolor\"")
		end
		@test PlotlyBase.JSON.json(f) == before
		annotate!(f, 0.5, 0.5, 0.5, "t"; bgcolor = "0.9")
		@test _v4_fields(only(_v5_scene(f)[:annotations]))[:bgcolor] == "#E6E6E6"
	end

	@testset "Z44 scene-grid legends: clear of the scenes; one figure legend dedupes" begin
		build() = begin
			sf = _v5_scene_sf(1, 3)
			for c in 1:3
				plot_surface!(sf, xs, ys, Z .* c; row = 1, col = c, xlabel = "x", ylabel = "y", zlabel = "height",
					showscale = false)
				plot_scatter3d!(sf, collect(xs), zeros(length(xs)), fill(2.0 * c, length(xs)); row = 1, col = c,
					legend = "ridge", color = "black")
			end
			sf
		end
		sf = build()
		p = sf.plot
		area = PS._s3_plot_area(p)
		plot_w, plot_h = area.width - area.l - area.r, area.height - area.t - area.b
		for key in (:scene, :scene2, :scene3)
			ridge = only(t for t in p.data if get(t.fields, :scene, "scene") == String(key) && get(t.fields, :name, "") == "ridge")
			id = string(get(ridge.fields, :legend, "legend"))
			box = _v4_fields(p.layout.fields[Symbol(id)])
			# Each cell legend lists its own cell's entry, at the cell's top right.
			@test (box[:xanchor], box[:yanchor], get(box, :xref, "paper"), get(box, :yref, "paper")) == ("right", "top", "paper", "paper")
			w, h = PS._legend_box_size(p, id)
			legend = (area.l + box[:x] * plot_w - w, area.t + (1 - box[:y]) * plot_h, area.l + box[:x] * plot_w, area.t + (1 - box[:y]) * plot_h + h)
			# The drawing (box corners, tick labels, titles) stays out of it.
			camera = _v4_camera(p, key)
			center = _v5_center(camera)
			offset = _v4_xyz(camera[:eye]) .- center
			distance = sqrt(sum(abs2, offset))
			target = PS._s3_layout_target(p, key)
			vw, vh = PS._s3_viewport(p, target)
			corners, quads = PS._s3_label_layout(PS._s3_drawn_box(p, key), Tuple(center),
				PS._s3_camera_frame(offset ./ distance, PS._s3_camera_up(camera)), distance, vw, vh,
				PS._s3_axis_labels(p, key), PS._s3_scene_spans(p, key))
			cx = area.l + plot_w * target.xdomain[1] + vw / 2
			cy = area.t + plot_h * (1 - target.ydomain[2]) + vh / 2
			points = [(cx + q[1], cy - q[2]) for q in Iterators.flatten((corners, Iterators.flatten(quads)))]
			drawing = (minimum(first, points), minimum(last, points), maximum(first, points), maximum(last, points))
			@test drawing[3] <= legend[1] || drawing[2] >= legend[4]
			# ... and still fills the rest of its cell.
			@test drawing[3] - drawing[1] > 0.6 * vw || drawing[4] - drawing[2] > 0.6 * vh
		end
		# One figure legend for the grid lists the identical entries once.
		set_legend!(sf; position = :outside_bottom)
		shown = [t for t in sf.plot.data if get(t.fields, :name, "") == "ridge" && get(t.fields, :showlegend, true) != false]
		@test length(shown) == 1
		@test PS._s3_finalize_scenes!(sf.plot) === false
	end
end

# ── Wave 6 (v6 threed): scenes in grid cells fill them; labels apart ─────────

# The modelled drawing of every scene of `fig` as exported with the options
# `kw` (the layout size when empty): per scene key the viewport (cell) size,
# the span of the union of the box and all label rectangles, the share of the
# cell that union spans in the dimension that limits it (`fill`: the larger of
# its two shares), whether it lies inside
# the cell, the intersecting label rectangles with their (axis, kind) tags and
# the title placements. Positions in px from the cell centre, y up
# (`_s3_label_layout_tagged` at the camera written).
function _v6_drawing(fig; kw...)
	PS = PlotlySupply
	p = fig isa SubplotFigure ? fig.plot : fig
	options = PS._normalize_export_options(p, NamedTuple(kw))
	src = PS._export_source(p, options)
	size = (Float64(options.width), Float64(options.height))
	out = Dict{Symbol, Any}()
	Base.ScopedValues.with(PS._S3_EXPORT_SIZE => size) do
		for key in keys(src.layout.fields)
			(key isa Symbol && occursin(PS._S3_SCENE_KEY, String(key))) || continue
			target = PS._s3_layout_target(src, key)
			scene = src.layout.fields[key]
			camera = PS._cmn_mapping_get(scene, :camera)
			eye = PS._s3_vector3(PS._cmn_mapping_get(camera, :eye))
			center = PS._s3_vector3(PS._cmn_mapping_get(camera, :center))
			distance = PS._s3_norm(eye .- center)
			frame = PS._s3_camera_frame((eye .- center) ./ distance, PS._s3_camera_up(camera))
			w, h = PS._s3_viewport(src, target)
			mark = PS._s3_mark(scene)
			own = mark !== nothing && any(!isempty, mark.titles)
			corners, quads, tags, placed = PS._s3_label_layout_tagged(PS._s3_drawn_box(src, key), Tuple(center), frame,
				distance, w, h, PS._s3_axis_labels(src, key), PS._s3_scene_spans(src, key); own = own)
			xs = vcat(first.(corners), [pt[1] for q in quads for pt in q])
			ys = vcat(last.(corners), [pt[2] for q in quads for pt in q])
			hits = [(tags[i], tags[j]) for i in eachindex(quads) for j in (i + 1):length(quads)
				if PS._s3_quads_intersect(quads[i], quads[j]; tolerance = PS._S3_LABEL_TOUCH_PX)]
			span = (maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
			fill = max(span[1] / w, span[2] / h)
			inside = minimum(xs) >= -w / 2 - 0.5 && maximum(xs) <= w / 2 + 0.5 &&
				minimum(ys) >= -h / 2 - 0.5 && maximum(ys) <= h / 2 + 0.5
			out[key] = (; viewport = (w, h), span, fill, inside, hits, placed, own, mark)
		end
	end
	return out
end

function _v6_topo_cell()
	sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec()], width_ratios = [1.25, 1],
		horizontal_spacing = 0.1)
	α = range(0.8, 1.4; length = 15)
	τ = range(0, 0.125; length = 15)
	R = [(1 - 0.55 * (a - 1)) * (1 + 1.6 * t^2 * a) for a in α, t in τ]
	plot_surface!(sf, collect(α), collect(τ), R; row = 1, col = 1)
	scene!(sf; row = 1, col = 1, aspectratio = (1.30, 1.0, 0.85), showbackground = false,
		xlabel = "Material scale \$\\alpha\$", ylabel = "Time step \$\\Delta t/T_h\$", zlabel = "Frequency ratio \$R\$")
	view!(sf; row = 1, col = 1, elev = 24, azim = -61)
	θ = range(0, 2π; length = 61)
	plot_scatter!(sf, cos.(θ), sin.(θ); row = 1, col = 2)
	return sf
end

const _V6_TOPO_EXPORT = (width = 6.6, height = 2.0, units = :in, dpi = 200, tight = true)

@testset "regression: 3-D wave 6 (v6 threed)" begin
	PS = PlotlySupply

	@testset "V4 scenes in cells fill them, labels never overlap (the projection model)" begin
		cases = Pair{String, Any}[]
		# (a) three long rotated axis titles in a small cell (topo_response (a))
		push!(cases, "topo_response" => (_v6_topo_cell(), _V6_TOPO_EXPORT))
		# (b) three scenes of one row at Nature double-column width, one colour bar
		xs = range(-2, 2; length = 21)
		Z(a) = [exp(-(x^2 + y^2) / a) * cos(2x) * cos(2y) for x in xs, y in xs]
		nature = with_style(:nature) do
			w = journal_width(:nature; columns = 2, units = :px)
			sf = subplots(1, 3; sync = false, width = w, height = 0.36w, specs = fill(Spec(kind = "scene"), 1, 3))
			for (c, a) in enumerate((1.0, 2.0, 4.0))
				plot_surface!(sf, xs, xs, Z(a); row = 1, col = c, shared_coloraxis = true, xlabel = "\$x\$", ylabel = "\$y\$",
					zlabel = "\$u\$", aspectmode = "cube")
				view!(sf; row = 1, col = c, elev = 25, azim = -55)
			end
			colorbar!(sf; coloraxis = :shared, title = "\$u\$", title_side = :right)
			sf
		end
		push!(cases, "nature_1x3" => (nature, NamedTuple()))
		# (c) a single column export: one scene at the IEEE column width
		ieee = with_style(:ieee) do
			w = journal_width(:ieee; columns = 1, units = :px)
			plot_surface(xs, xs, Z(2.0); width = w, height = 0.8w, xlabel = "x", ylabel = "y", zlabel = "z")
		end
		push!(cases, "ieee_single" => (ieee, NamedTuple()))
		# (d) scenes beside a 2-D panel
		mixed = subplots(1, 3; sync = false, width = 900, height = 300,
			specs = [Spec(kind = "scene") Spec() Spec(kind = "scene")])
		plot_surface!(mixed, xs, xs, Z(2.0); row = 1, col = 1, xlabel = "x", ylabel = "y", zlabel = "z")
		plot_scatter!(mixed, collect(xs), Z(2.0)[:, 10]; row = 1, col = 2)
		plot_surface!(mixed, xs, xs, Z(2.0); row = 1, col = 3, xlabel = "x", ylabel = "y", zlabel = "z")
		push!(cases, "mixed_scene_xy" => (mixed, NamedTuple()))
		for (name, (fig, kw)) in cases
			drawing = _v6_drawing(fig; kw...)
			@test !isempty(drawing)
			for (key, d) in drawing
				@test (name, key, d.fill >= 0.8) == (name, key, true)
				@test (name, key, d.inside) == (name, key, true)
				@test (name, key, d.hits) == (name, key, [])
			end
		end
		# the identical cells of the row are drawn identically (Q39)
		d = _v6_drawing(nature)
		scenes = sort(collect(keys(d)); by = string)
		@test length(scenes) == 3
		@test all(k -> isapprox(collect(d[k].viewport), collect(d[scenes[1]].viewport); atol = 1e-6) &&
		isapprox(collect(d[k].span), collect(d[scenes[1]].span); atol = 1e-6), scenes)
	end

	@testset "titles PlotlySupply draws itself: annotations at the projected axis, settled, restored" begin
		sf = _v6_topo_cell()
		d = _v6_drawing(sf; _V6_TOPO_EXPORT...)[:scene]
		@test d.own
		@test d.mark.titles == ("Material scale α", "Time step Δ t/T<sub>h</sub>", "Frequency ratio R")
		@test length(d.placed) == 3
		# the live figure (framed for the layout size) carries the same
		figsize!(sf, 6.6, 2.0; units = :in)
		layout = sf.plot.layout.fields
		names = [PS._cmn_mapping_get(a, :name) for a in layout[:annotations]]
		for letter in ("x", "y", "z")
			@test "plotlysupply:scene3d:scene:title:$letter" in names
		end
		for axis in (:xaxis, :yaxis, :zaxis)
			@test _r3_fields(_r3_fields(_r3_fields(layout[:scene])[axis])[:title])[:text] == PS._S3_TITLE_HIDDEN
		end
		one = [a for a in layout[:annotations] if PS._cmn_mapping_get(a, :name) == "plotlysupply:scene3d:scene:title:x"][1]
		@test PS._cmn_mapping_get(one, :xref) == "paper" && PS._cmn_mapping_get(one, :showarrow) === false
		@test 0 <= PS._cmn_mapping_get(one, :x) <= 1 && 0 <= PS._cmn_mapping_get(one, :y) <= 1
		# settled: nothing is written by another pass, a savefig changes nothing
		@test PS._finalize_figure!(sf) === false
		@test PS._s3_finalize_scenes!(sf.plot) === false
		before = PlotlyBase.JSON.json(sf.plot.layout.fields)
		mktempdir() do dir
			savefig(sf, joinpath(dir, "own.png"))
		end
		@test PlotlyBase.JSON.json(sf.plot.layout.fields) == before
		# a camera of the user's gets the scene's own titles back
		view!(sf; row = 1, col = 1, elev = 24, azim = -61, distance = 6.0)
		names = [PS._cmn_mapping_get(a, :name) for a in get(sf.plot.layout.fields, :annotations, [])]
		@test !any(n -> n isa AbstractString && startswith(n, "plotlysupply:scene3d:"), names)
		@test _r3_fields(_r3_fields(_r3_fields(sf.plot.layout.fields[:scene])[:zaxis])[:title])[:text] == "Frequency ratio R"
		@test all(isempty, PS._s3_mark(sf.plot.layout.fields[:scene]).titles)
		@test PS._s3_finalize_scenes!(sf.plot) === false
	end

	@testset "_s3_wrap_title and _s3_quads_intersect" begin
		@test PS._s3_wrap_title("Material scale α") == ("Material<br>scale α", 8)
		@test PS._s3_wrap_title("Frequency ratio R") == ("Frequency<br>ratio R", 9)
		@test PS._s3_wrap_title("Time step Δ t/T<sub>h</sub>") !== nothing
		@test PS._s3_wrap_title("Energy") === nothing
		@test PS._s3_wrap_title("a<br>b c") === nothing
		@test PS._s3_wrap_title("\$a b\$") === nothing
		@test PS._s3_wrap_title(" lone") === nothing
		sq(x, y, s = 1.0) = ((x, y), (x + s, y), (x + s, y + s), (x, y + s))
		@test PS._s3_quads_intersect(sq(0, 0), sq(0.5, 0.5))
		@test !PS._s3_quads_intersect(sq(0, 0), sq(2, 0))
		@test !PS._s3_quads_intersect(sq(0, 0), sq(1, 0))
		@test !PS._s3_quads_intersect(sq(0, 0), sq(0.9, 0.9); tolerance = 0.2)
		@test PS._s3_quads_intersect(sq(0, 0), sq(0.5, 0.5); tolerance = 0.2)
	end

	@testset "label pads: the asset reads them, the model writes and reads them" begin
		layout = Layout()
		@test !PS._s3_write_pads!(layout, :scene, PS._S3_GL_DEFAULT_PADS)
		@test PS._s3_write_pads!(layout, :scene, (8.0, 12.5))
		@test layout.fields[:meta][Symbol("plotlysupply:gl3d")][:scene] == [8.0, 12.5]
		@test !PS._s3_write_pads!(layout, :scene, (8.0, 12.5))
		p = Plot(layout)
		@test PS._s3_scene_pads(p, :scene) == (8.0, 12.5)
		@test PS._s3_scene_pads(p, :scene2) == PS._S3_GL_DEFAULT_PADS
		@test PS._s3_write_pads!(layout, :scene, PS._S3_GL_DEFAULT_PADS)
		@test !haskey(layout.fields, :meta)
		# the user's own meta is kept; a meta that is not a mapping is left alone
		layout = Layout()
		layout.fields[:meta] = Dict{Any, Any}("mine" => 1)
		@test PS._s3_write_pads!(layout, :scene, (8.0, 12.5))
		@test layout.fields[:meta]["mine"] == 1
		@test PS._s3_write_pads!(layout, :scene, PS._S3_GL_DEFAULT_PADS)
		@test layout.fields[:meta] == Dict{Any, Any}("mine" => 1)
		layout = Layout()
		layout.fields[:meta] = "text"
		@test !PS._s3_write_pads!(layout, :scene, (8.0, 12.5))
		@test layout.fields[:meta] == "text"
		# the patched Plotly.js: the seam occurs once and the patch reads the record
		source = read(PS._plotlyjs_asset_path(), String)
		@test count(PS._PLOTLYJS_GL3D_PAD_SEAM, source) == 1
		@test occursin("plotlysupply:gl3d", PS._patch_plotlyjs_math_fonts(source))
		# the scenes of a figure framed by PlotlySupply carry compact pads
		f = _v6_topo_cell()
		figsize!(f, 6.6, 2.0; units = :in)
		@test PS._s3_scene_pads(f.plot, :scene)[1] < PS._S3_GL_TICK_PAD
		@test PS._s3_finalize_scenes!(f.plot) === false
	end

	@testset "Z92 corner tick labels: one end tick of one axis is dropped, tracked, never stale" begin
		xs = range(-1, 1; length = 31)
		Zs = [sqrt(max(1 - x^2 - y^2, 0.0)) for x in xs, y in xs]
		make() = plot_surface(xs .* 0.5, xs .* 0.5, 2 .* Zs .- 1; aspectmode = "data", xlabel = "x", ylabel = "y", zlabel = "z")
		f = make()
		axes = (:xaxis, :yaxis, :zaxis)
		mark = PS._s3_mark(f.layout.fields[:scene])
		trimmed = [d for d in 1:3 if !isempty(mark.tickvals[d])]
		@test length(trimmed) == 1
		d = only(trimmed)
		values = _r3_fields(_r3_fields(f.layout.fields[:scene])[axes[d]])[:tickvals]
		@test collect(Float64, values) == collect(mark.tickvals[d])
		@test issorted(values) && length(values) >= 2
		@test isempty(_v6_drawing(f)[:scene].hits)
		@test PS._finalize_figure!(f) === false
		# data that moves the range re-derives the tick values: never a stale list
		plot_scatter3d!(f, [0.0, 3.0], [0.0, 3.0], [0.0, 5.0])
		mark2 = PS._s3_mark(f.layout.fields[:scene])
		scene2 = _r3_fields(f.layout.fields[:scene])
		for e in 1:3
			axis = _r3_fields(scene2[axes[e]])
			tv = get(axis, :tickvals, nothing)
			if isempty(mark2.tickvals[e])
				@test tv === nothing
			else
				@test collect(Float64, tv) == collect(mark2.tickvals[e])
				range = PS._s3_axis_range(f, :scene, e, axis)
				@test all(v -> range[1] - 1e-9 <= v <= range[2] + 1e-9, mark2.tickvals[e])
			end
		end
		@test PS._s3_finalize_scenes!(f) === false
		# a tick placement of the user's is never touched
		g = make()
		scene!(g; zticks = [-1.0, 0.0, 1.0], xticks = [-0.5, 0.0, 0.5])
		mg = PS._s3_mark(g.layout.fields[:scene])
		@test isempty(mg.tickvals[1]) && isempty(mg.tickvals[3])
		@test collect(Float64, _r3_fields(_r3_fields(g.layout.fields[:scene])[:zaxis])[:tickvals]) == [-1.0, 0.0, 1.0]
		@test PS._s3_finalize_scenes!(g) === false
		# plotly.js's step inside the range
		@test PS._s3_nice_ticks((-1.0625, 1.0625), 5) == ([-1.0, -0.5, 0.0, 0.5, 1.0], 0.5)
		@test PS._s3_nice_ticks((0.0, 0.0), 5)[1] == Float64[]
	end

	@testset "Q18 identical scene cells stay identical when one colour bar is shared" begin
		xs = range(-2, 2; length = 21)
		sf = subplots(1, 3; sync = false, width = 900, height = 330, specs = fill(Spec(kind = "scene"), 1, 3))
		for c in 1:3
			plot_surface!(sf, xs, xs, [exp(-(x^2 + y^2)) for x in xs, y in xs]; row = 1, col = c, shared_coloraxis = true,
				aspectmode = "cube")
			view!(sf; row = 1, col = c, elev = 25, azim = -55)
		end
		colorbar!(sf; coloraxis = :shared, title = "u", title_side = :right)
		d = _v6_drawing(sf)
		scenes = sort(collect(keys(d)); by = string)
		@test length(scenes) == 3
		@test all(k -> isapprox(collect(d[k].viewport), collect(d[scenes[1]].viewport); atol = 1e-6) &&
		isapprox(collect(d[k].span), collect(d[scenes[1]].span); atol = 1e-6), scenes)
		widths = [(dm = _r3_fields(_r3_fields(sf.plot.layout.fields[k])[:domain]); dm[:x][2] - dm[:x][1]) for k in scenes]
		@test maximum(widths) - minimum(widths) < 1e-9
	end

	@testset "a second framing pass is cheap (own titles + corner ticks)" begin
		sf = _v6_topo_cell()
		figsize!(sf, 6.6, 2.0; units = :in)
		PS._s3_finalize_scenes!(sf.plot)
		t = @elapsed PS._s3_finalize_scenes!(sf.plot)
		@test t < 2.0
	end
end
