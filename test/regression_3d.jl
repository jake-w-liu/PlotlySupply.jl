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
