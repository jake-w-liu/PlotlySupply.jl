using Test, PlotlySupply

# 2.0 3-D features (spec F30–F34, C24/C28, C20/C21 on 3-D traces, ADDENDUM
# A7, A8, A10, B2): view!, scene!, 3-D annotate!, _label3d, polygons3d,
# wireframes, 3-D segments, arrows, per-face meshes and the colour keywords.

_t3_fields(value) = value isa PlotlyBase.PlotlyAttribute ? value.fields :
	value isa AbstractDict ? value : error("not a mapping: $(typeof(value))")
_t3_layout(fig) = (fig isa SubplotFigure ? fig.plot.layout : fig.layout).fields
_t3_scene(fig, key::Symbol = :scene) = _t3_fields(_t3_layout(fig)[key])
_t3_axis(fig, axis::Symbol, key::Symbol = :scene) = _t3_fields(_t3_scene(fig, key)[axis])
_t3_camera(fig, key::Symbol = :scene) = _t3_fields(_t3_scene(fig, key)[:camera])
_t3_xyz(value) = (f = _t3_fields(value); (f[:x], f[:y], f[:z]))
_t3_cube(; kwargs...) = plot_scatter3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0]; aspectmode = "cube", kwargs...)
_t3_scene_sf(cols = 2; kwargs...) =
	subplots(1, cols; sync = false, specs = fill(Spec(kind = "scene"), 1, cols), kwargs...)
_t3_backend(scripts) = (
	isopen = window -> true,
	close = window -> nothing,
	run = (window, script) -> (push!(scripts, String(script)); "ok"),
)
_t3_syncplot(p, scripts) =
	SyncPlot(p, nothing, :t3_window, "t3-div", PlotlySupply._SyncPlotResources(nothing, _t3_backend(scripts)))

@testset "sci: 3-D scenes" begin
	@testset "_label3d converts TeX for WebGL text (A8)" begin
		L = PlotlySupply._label3d
		@test L("\$x_1\$") == "x<sub>1</sub>"
		@test L("\$\\mathbf{b}\$") == "<b>b</b>"
		@test L("\$\\lambda^2\$") == "λ<sup>2</sup>"
		@test L("Energy \$E_{k}\$ (J)") == "Energy E<sub>k</sub> (J)"
		@test L("\$\\textit{v}\$ and \$\\mathrm{d}t\$") == "<i>v</i> and dt"
		@test L("\$\\frac{a}{b}\$") == "a/b"
		@test L("\$\\sqrt{x}\$") == "√x"
		@test L("plain") == "plain"
		@test L("price \\\$5") == "price \$5"
		@test L("two\nlines") == "two<br>lines"
		@test L("") == ""
		@test_logs (:warn, r"threedtestmacro") L("\$\\threedtestmacro{x}\$")
		@test (@test_logs L("\$\\threedtestmacro{y}\$")) == "\\threedtestmacro{y}"   # warns once
		@test_throws ArgumentError L("\$x")
		previous = get_default_mathtext()
		try
			set_default_mathtext!(false)
			@test L("\$x_1\$") == "\$x_1\$"
		finally
			set_default_mathtext!(previous.enabled; size = previous.size)
		end
		# Scene axis titles use it; scene annotations keep MathJax.
		f = plot_surface(rand(3, 3); xlabel = "\$x_1\$", ylabel = "\$\\mathbf{b}\$", zlabel = "\$\\lambda^2\$")
		@test _t3_fields(_t3_axis(f, :xaxis)[:title])[:text] == "x<sub>1</sub>"
		@test _t3_fields(_t3_axis(f, :yaxis)[:title])[:text] == "<b>b</b>"
		@test _t3_fields(_t3_axis(f, :zaxis)[:title])[:text] == "λ<sup>2</sup>"
		g = plot_scatter3d(1:2, 1:2, 1:2; text = ["\$\\alpha\$", "b"])
		@test g.data[1].fields[:text] == ["α", "b"]
	end

	@testset "view!: matplotlib view_init camera (F31, A10)" begin
		f = _t3_cube()
		@test view!(f; elev = 30, azim = -60, distance = 2) === f
		eye = _t3_xyz(_t3_camera(f)[:eye])
		@test collect(eye) ≈ 2 .* [cosd(30) * cosd(-60), cosd(30) * sind(-60), sind(30)]
		@test collect(_t3_xyz(_t3_camera(f)[:up])) == [0.0, 0.0, 1.0]
		# Elevation 0, azimuth 0 looks along -x from +x.
		view!(f; elev = 0, azim = 0, distance = 3)
		@test collect(_t3_xyz(_t3_camera(f)[:eye])) ≈ [3.0, 0.0, 0.0]
		# Near-vertical views use a horizontal up vector (+y up for azim = -90).
		view!(f; elev = 90, azim = -90, distance = 2)
		@test collect(_t3_xyz(_t3_camera(f)[:up])) ≈ [0.0, 1.0, 0.0] atol = 1e-12
		@test collect(_t3_xyz(_t3_camera(f)[:eye])) ≈ [0.0, 0.0, 2.0] atol = 1e-12
		# up = :y rolls the axes like matplotlib's vertical_axis = "y".
		view!(f; elev = 30, azim = -60, distance = 2, up = :y)
		e = 2 .* [cosd(30) * cosd(-60), cosd(30) * sind(-60), sind(30)]
		@test collect(_t3_xyz(_t3_camera(f)[:eye])) ≈ [e[2], e[3], e[1]]
		@test collect(_t3_xyz(_t3_camera(f)[:up])) == [0.0, 1.0, 0.0]
		# Automatic distance frames the unit cube in the default 700×500 figure.
		view!(f; elev = 30, azim = -60)
		radius = 0.5 * sqrt(3)
		half = atan(min(1.0, 600 / 390) * tan(π / 8))
		@test sqrt(sum(abs2, collect(_t3_xyz(_t3_camera(f)[:eye])))) ≈ 1.05 * radius / sin(half)
		view!(f; elev = 30, azim = -60, zoom = 2)
		@test sqrt(sum(abs2, collect(_t3_xyz(_t3_camera(f)[:eye])))) ≈ 1.05 * radius / sin(half) / 2
		# Spec F31 reference: box (1, 0.25, 0.25) in a 0.32-wide cell of a 900×350
		# figure with zero margins is framed at distance 1.726.
		cell = plot_scatter3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0]; width = 900, height = 350)
		relayout!(cell; margin = attr(l = 0, r = 0, t = 0, b = 0))
		PlotlySupply._merge_scene_layout_attr!(cell.layout, :scene, attr(domain = attr(x = [0, 0.32], y = [0, 1])))
		scene!(cell; aspectratio = (1, 0.25, 0.25))
		view!(cell; elev = 20, azim = -65)
		eye = collect(_t3_xyz(_t3_camera(cell)[:eye]))
		@test sqrt(sum(abs2, eye)) ≈ 1.726 atol = 1e-3
		@test eye ./ sqrt(sum(abs2, eye)) ≈ [cosd(20) * cosd(-65), cosd(20) * sind(-65), sind(20)]
		# Projection switch; orthographic zoom scales the scene box.
		view!(f; projection = "orthographic", zoom = 1.5)
		@test _t3_fields(_t3_camera(f)[:projection])[:type] == "orthographic"
		@test _t3_scene(f)[:aspectmode] == "manual"
		@test collect(_t3_xyz(_t3_scene(f)[:aspectratio])) ≈ [1.5, 1.5, 1.5]
		view!(f; projection = "orthographic", zoom = 1.5)   # does not compound
		@test collect(_t3_xyz(_t3_scene(f)[:aspectratio])) ≈ [1.5, 1.5, 1.5]
		# "auto" aspect derived from the data is pinned for the framing.
		g = plot_scatter3d([0.0, 2.0], [0.0, 1.0], [0.0, 1.0])
		view!(g)
		@test _t3_scene(g)[:aspectmode] == "manual"
		@test collect(_t3_xyz(_t3_scene(g)[:aspectratio])) ≈ [1.0, 0.5, 0.5]
		# Errors leave the figure unchanged.
		before = PlotlyBase.JSON.json(f)
		@test_throws ArgumentError view!(f; zoom = 0)
		@test_throws ArgumentError view!(f; zoom = -1)
		@test_throws ArgumentError view!(f; up = :w)
		@test_throws ArgumentError view!(f; elev = NaN)
		@test_throws ArgumentError view!(f; distance = -1)
		@test_throws ArgumentError view!(f; projection = "fisheye")
		@test_throws ArgumentError view!(f; bogus = 1)
		@test_throws ArgumentError view!(f; row = 1, col = 1)
		@test PlotlyBase.JSON.json(f) == before
		@test_throws ArgumentError view!(plot_scatter(1:2, 1:2))
		# `view = (elev, azim)` on constructors and mutators.
		h = plot_surface(rand(3, 3); view = (10, 20), aspectmode = "cube")
		ev = collect(_t3_xyz(_t3_camera(h)[:eye]))
		@test ev ./ sqrt(sum(abs2, ev)) ≈ [cosd(10) * cosd(20), cosd(10) * sind(20), sind(10)]
		plot_scatter3d!(h, 1:2, 1:2, 1:2; view = (45, 0))
		ev = collect(_t3_xyz(_t3_camera(h)[:eye]))
		@test ev ./ sqrt(sum(abs2, ev)) ≈ [cosd(45), 0.0, sind(45)] atol = 1e-12
		@test_throws ArgumentError plot_surface(rand(3, 3); view = (10,))
	end

	@testset "view!: SubplotFigure cells change only their scene" begin
		sf = _t3_scene_sf(3)
		for c in 1:3
			plot_surface!(sf, rand(4, 4); row = 1, col = c)
		end
		subplot!(sf, 1, 1)
		before1 = PlotlyBase.JSON.json(_t3_layout(sf)[:scene])
		before3 = PlotlyBase.JSON.json(_t3_layout(sf)[:scene3])
		@test view!(sf; row = 1, col = 2, elev = 0, azim = 90, distance = 2) === sf
		@test collect(_t3_xyz(_t3_camera(sf, :scene2)[:eye])) ≈ [0.0, 2.0, 0.0] atol = 1e-12
		@test PlotlyBase.JSON.json(_t3_layout(sf)[:scene]) == before1
		@test PlotlyBase.JSON.json(_t3_layout(sf)[:scene3]) == before3
		@test (sf.current_row, sf.current_col) == (1, 1)
		# The auto framing uses the cell's width (a third of the plot area).
		view!(sf; row = 1, col = 3, elev = 20, azim = 30)
		@test _t3_scene(sf, :scene3)[:aspectmode] == "manual"
		@test_throws ArgumentError view!(sf; row = 1, col = 4)
		# view = (elev, azim) through a cell mutator touches only that scene.
		plot_scatter3d!(sf, 1:3, 1:3, 1:3; row = 1, col = 1, view = (0, 180))
		eye = collect(_t3_xyz(_t3_camera(sf, :scene)[:eye]))
		@test eye ./ sqrt(sum(abs2, eye)) ≈ [-1.0, 0.0, 0.0] atol = 1e-12
		@test PlotlyBase.JSON.json(_t3_layout(sf)[:scene3]) != before3   # changed above only by view!
		mixed = subplots(1, 2; sync = false, specs = [Spec(kind = "xy") Spec(kind = "scene")])
		@test_throws ArgumentError view!(mixed; row = 1, col = 1)
	end

	@testset "scene!: aspect, axes, panes and ticks (A7)" begin
		f = plot_surface(rand(5, 4))
		@test scene!(f; aspectratio = (2, 1, 0.5)) === f
		@test _t3_scene(f)[:aspectmode] == "manual"
		@test collect(_t3_xyz(_t3_scene(f)[:aspectratio])) == [2.0, 1.0, 0.5]
		scene!(f; aspectratio = (x = 1, y = 2, z = 3))
		@test collect(_t3_xyz(_t3_scene(f)[:aspectratio])) == [1.0, 2.0, 3.0]
		scene!(f; showbackground = false, showgrid = false, showticklabels = false, nticks = 4)
		for axis in (:xaxis, :yaxis, :zaxis)
			a = _t3_axis(f, axis)
			@test a[:showbackground] === false
			@test a[:showgrid] === false
			@test a[:showticklabels] === false
			@test a[:nticks] == 4
		end
		scene!(f; backgroundcolor = "lightyellow")
		@test _t3_axis(f, :zaxis)[:backgroundcolor] == "lightyellow"
		@test _t3_axis(f, :zaxis)[:showbackground] === true
		scene!(f; showaxis = false)
		@test _t3_axis(f, :xaxis)[:visible] === false
		scene!(f; xticks = [0, 2, 4], xticklabels = ["\$0\$", "\$\\pi\$", "\$2\\pi\$"], zticks = (0.0, 0.5))
		x = _t3_axis(f, :xaxis)
		@test x[:tickmode] == "array"
		@test x[:tickvals] == [0, 2, 4]
		@test x[:ticktext] == ["0", "π", "2π"]
		@test _t3_axis(f, :zaxis)[:tickvals] == [0.0, 0.5]
		scene!(f; xlabel = "\$x_1\$", zrange = (0, 2))
		@test _t3_fields(_t3_axis(f, :xaxis)[:title])[:text] == "x<sub>1</sub>"
		@test _t3_axis(f, :zaxis)[:range] == [0, 2]
		@test _t3_axis(f, :xaxis)[:tickvals] == [0, 2, 4]   # earlier settings are kept
		before = PlotlyBase.JSON.json(f)
		@test_throws ArgumentError scene!(f; aspectratio = (1, 0, 1))
		@test_throws ArgumentError scene!(f; aspectratio = (1, 1))
		@test_throws ArgumentError scene!(f; aspectratio = (1, 1, 1), aspectmode = "cube")
		@test_throws ArgumentError scene!(f; xticklabels = ["a"])
		@test_throws ArgumentError scene!(f; xticks = [1, 2], xticklabels = ["a"])
		@test_throws ArgumentError scene!(f; xticks = [1, NaN])
		@test_throws ArgumentError scene!(f; nticks = -1)
		@test_throws ArgumentError scene!(f; backgroundcolor = "notacolour")
		@test_throws ArgumentError scene!(f; zrange = [1])
		@test_throws ArgumentError scene!(f; bogus = true)
		@test PlotlyBase.JSON.json(f) == before
		# Log scene axis: ranges are data values.
		g = plot_scatter3d([1.0, 100.0], [1.0, 2.0], [1.0, 2.0])
		PlotlySupply._merge_scene_layout_attr!(g.layout, :scene, attr(xaxis = attr(type = "log")))
		scene!(g; xrange = [1, 1000])
		@test _t3_axis(g, :xaxis)[:range] ≈ [0.0, 3.0]
		@test_throws ArgumentError scene!(g; xrange = [0, 10])
		# Per cell.
		sf = _t3_scene_sf()
		plot_surface!(sf, rand(3, 3); row = 1, col = 1)
		plot_surface!(sf, rand(3, 3); row = 1, col = 2)
		before1 = PlotlyBase.JSON.json(_t3_layout(sf)[:scene])
		@test scene!(sf; row = 1, col = 2, aspectratio = (1, 1, 2), showaxis = false) === sf
		@test _t3_scene(sf, :scene2)[:aspectmode] == "manual"
		@test PlotlyBase.JSON.json(_t3_layout(sf)[:scene]) == before1
	end

	@testset "annotate! in a 3-D scene (F32)" begin
		f = _t3_cube()
		@test annotate!(f, 1, 1, 1, "\$\\alpha\$"; fontsize = 14, color = "red", bgcolor = "white") === f
		anns = _t3_scene(f)[:annotations]
		@test length(anns) == 1
		a = _t3_fields(anns[1])
		@test (a[:x], a[:y], a[:z]) == (1.0, 1.0, 1.0)
		@test a[:text] == PlotlySupply._label("\$\\alpha\$")   # MathJax, not _label3d
		@test a[:showarrow] === false
		@test _t3_fields(a[:font]) == Dict{Symbol, Any}(:size => 14, :color => "red")
		@test a[:bgcolor] == "white"
		@test !haskey(_t3_layout(f), :annotations)               # not a 2-D annotation
		annotate!(f, 1, 1, 1, "\$\\alpha\$"; fontsize = 20)       # same point and text: replaced
		@test length(_t3_scene(f)[:annotations]) == 1
		@test _t3_fields(_t3_fields(_t3_scene(f)[:annotations][1])[:font])[:size] == 20
		annotate!(f, 0, 0, 0, "origin"; showarrow = true, ax = 20, ay = -20)
		@test length(_t3_scene(f)[:annotations]) == 2
		before = PlotlyBase.JSON.json(f)
		@test_throws ArgumentError annotate!(f, NaN, 0, 0, "x")
		@test_throws ArgumentError annotate!(f, 0, 0, 0, "x"; xref = "paper")
		@test_throws ArgumentError annotate!(f, 0, 0, 0, "x"; xanchor = "middle")
		@test_throws ArgumentError annotate!(f, 0, 0, 0, "x"; fontsize = -1)
		@test_throws ArgumentError annotate!(f, 0, 0, 0, "x"; color = "nope")
		@test_throws ArgumentError annotate!(f, 0, 0, 0, "\$x")
		@test PlotlyBase.JSON.json(f) == before
		@test_throws ArgumentError annotate!(plot_scatter(1:2, 1:2), 1, 1, 1, "x")
		# 2-D arity still works.
		g = plot_scatter(1:3, 1:3)
		annotate!(g, 2, 2, "two")
		@test length(_t3_layout(g)[:annotations]) == 1
		# Log scene axis: the point is in data units, stored as the exponent.
		h = plot_scatter3d([1.0, 100.0], [1.0, 2.0], [1.0, 2.0])
		PlotlySupply._merge_scene_layout_attr!(h.layout, :scene, attr(xaxis = attr(type = "log")))
		annotate!(h, 10, 1, 1, "ten")
		@test _t3_fields(_t3_scene(h)[:annotations][1])[:x] ≈ 1.0
		@test_throws ArgumentError annotate!(h, -1, 1, 1, "bad")
		# Per cell, registered as a SubplotFigure mutator.
		sf = _t3_scene_sf()
		plot_scatter3d!(sf, 1:2, 1:2, 1:2; row = 1, col = 1)
		plot_scatter3d!(sf, 1:2, 1:2, 1:2; row = 1, col = 2)
		@test annotate!(sf, 1, 1, 1, "cell 2"; row = 1, col = 2) === sf
		@test length(_t3_scene(sf, :scene2)[:annotations]) == 1
		@test !haskey(_t3_scene(sf, :scene), :annotations)
		@test :annotate! in PlotlySupply._TRANSACTIONAL_HIGH_LEVEL_PLOT_MUTATORS
	end

	@testset "plot_polygons3d (F30)" begin
		x = [0.0, 1, 1, 0, 0, 1, 1, 0]
		y = [0.0, 0, 1, 1, 0, 0, 1, 1]
		z = [0.0, 0, 0, 0, 1, 1, 1, 1]
		faces = [1 2 3 4; 5 6 7 8; 1 2 6 5; 2 3 7 6; 3 4 8 7; 4 1 5 8]
		f = plot_polygons3d(x, y, z, faces, collect(1.0:6.0); colorscale = "viridis")
		mesh, edges = f.data
		@test mesh.fields[:type] == "mesh3d"
		@test length(mesh.fields[:i]) == 12                  # two triangles per quad
		@test mesh.fields[:i][1:2] == [0, 0] && mesh.fields[:j][1:2] == [1, 2] && mesh.fields[:k][1:2] == [2, 3]
		@test mesh.fields[:intensitymode] == "cell"
		@test mesh.fields[:intensity] == repeat(1.0:6.0; inner = 2)
		@test mesh.fields[:flatshading] === true             # lighting = :flat by default
		@test _t3_fields(mesh.fields[:lighting])[:ambient] == 1.0
		@test _t3_scene(f)[:aspectmode] == "data"
		# Boundary edges only (no diagonals), each once: a cube has 12.
		@test edges.fields[:type] == "scatter3d"
		@test length(edges.fields[:x]) == 3 * 12
		@test count(isnothing, edges.fields[:x]) == 12
		# Explicit coordinate faces share vertices.
		square(z0) = [0.0 0 z0; 1 0 z0; 1 1 z0; 0 1 z0]
		g = plot_polygons3d([square(0.0), [0.0 0 0; 1 0 0; 0.5 0.5 -1.0]], [1.0, NaN])
		@test length(g.data[1].fields[:x]) == 5                 # 4 + 1 new vertex
		@test length(g.data[1].fields[:i]) == 2                 # the NaN triangle is not filled
		@test length(g.data[2].fields[:x]) == 3 * 6             # its edges are drawn (4 + 2 new)
		h = plot_polygons3d([square(0.0)]; color = :orange, edgecolor = "")
		@test length(h.data) == 1
		@test h.data[1].fields[:color] == "orange"
		k = plot_polygons3d([square(0.0)])
		@test k.data[1].fields[:color] == PlotlySupply._default_trace_color(k, 1)
		plot_polygons3d!(k, [square(1.0)], [3.0]; colorscale = "plasma", crange = [0, 5])
		@test length(k.data) == 4
		@test k.data[3].fields[:cmin] == 0.0 && k.data[3].fields[:cmax] == 5.0
		@test_throws ArgumentError plot_polygons3d([square(0.0)]; colorscale = "viridis")
		@test_throws ArgumentError plot_polygons3d([square(0.0)], [1.0, 2.0])
		@test_throws ArgumentError plot_polygons3d([square(0.0)], [1.0]; color = "red")
		@test_throws ArgumentError plot_polygons3d(x, y, z, [1 2 9])
		@test_throws ArgumentError plot_polygons3d(x, y, z, [1 2])
		@test_throws ArgumentError plot_polygons3d([[0.0 0 0; 1 1 1]])
		@test_throws ArgumentError plot_polygons3d([[0.0 0 NaN; 1 1 1; 0 1 0]])
		before = length(k.data)
		@test_throws ArgumentError plot_polygons3d!(k, [square(2.0)]; opacity = 2)
		@test length(k.data) == before
		sf = _t3_scene_sf()
		@test plot_polygons3d!(sf, x, y, z, faces; row = 1, col = 2) === sf
		@test all(t -> get(t.fields, :scene, "") == "scene2", sf.plot.data)
	end

	@testset "plot_mesh3d per-face colours and edges (F30, C27)" begin
		x = [0.0, 1, 0, 0]
		y = [0.0, 0, 1, 0]
		z = [0.0, 0, 0, 1]
		tri = (i = [0, 0, 0, 1], j = [1, 1, 2, 2], k = [2, 3, 3, 3])
		f = plot_mesh3d(x, y, z; tri..., intensity = [1.0, 2.0, 3.0, 4.0], intensitymode = "cell")
		@test f.data[1].fields[:intensitymode] == "cell"
		g = plot_mesh3d([x; 2.0], [y; 2.0], [z; 2.0]; tri..., intensity = [1.0, 2, 3, 4])
		@test g.data[1].fields[:intensitymode] == "cell"        # 4 faces, 5 vertices
		h = plot_mesh3d(x, y, z; tri..., facecolor = ["red", "green", "blue", "gold"], edges = true,
			edgecolor = "white", edgewidth = 2, lighting = :flat)
		@test h.data[1].fields[:facecolor] == ["red", "green", "blue", "gold"]
		@test h.data[1].fields[:flatshading] === true
		@test length(h.data) == 2
		@test _t3_fields(h.data[2].fields[:line]) == Dict{Symbol, Any}(:color => "white", :width => 2.0)
		@test count(isnothing, h.data[2].fields[:x]) == 6        # a tetrahedron has 6 edges
		m = plot_mesh3d(x, y, z; tri..., intensity = [1.0, 10, 100, 1000], colornorm = :log)
		@test m.data[1].fields[:intensity] ≈ [0.0, 1.0, 2.0, 3.0]
		@test_throws ArgumentError plot_mesh3d(x, y, z; tri..., facecolor = ["red"])
		@test_throws ArgumentError plot_mesh3d(x, y, z; tri..., intensity = [1.0, 2.0])
		@test_throws ArgumentError plot_mesh3d(x, y, z; tri..., intensity = [1.0, 2, 3, 4], color = "red")
		@test_throws ArgumentError plot_mesh3d(x, y, z; colorscale = "viridis")
		@test_throws ArgumentError plot_mesh3d(x, y, z; edges = true)
		@test_throws ArgumentError plot_mesh3d(x, y, z; i = [0], j = [1])
		err = try
			plot_mesh3d(x, y, z; i = [0], j = [1], k = [7])
		catch e
			e
		end
		@test err isa ArgumentError && startswith(err.msg, "plot_mesh3d: ")
	end

	@testset "plot_wireframe (F33) and the B2 opacity pre-blend" begin
		xs = [0.0, 1.0, 2.0]
		ys = [0.0, 1.0]
		Z = [0.0 1.0; 2.0 3.0; 4.0 5.0]
		f = plot_wireframe(xs, ys, Z)
		t = f.data[1].fields
		@test t[:type] == "scatter3d" && t[:mode] == "lines"
		# 3 lines of constant i (2 points + gap) and 2 of constant j (3 points + gap).
		@test length(t[:x]) == 3 * 3 + 2 * 4
		@test t[:x][1:3] == [0.0, 0.0, nothing]
		@test t[:z][1:2] == [0.0, 1.0]
		@test t[:z][10:12] == [0.0, 2.0, 4.0]
		@test _t3_fields(t[:line])[:color] == "black"
		g = plot_wireframe(xs, ys, Z; rstride = 0, cstride = 1)
		@test length(g.data[1].fields[:x]) == 2 * 4
		h = plot_wireframe(0:9, 0:9, rand(10, 10); rstride = 4, cstride = 4)
		@test count(isnothing, h.data[1].fields[:x]) == 2 * 4  # lines 1, 5, 9, 10
		# Ghost line: black at 0.35 over a white scene background.
		ghost = plot_surface(Z)
		plot_wireframe!(ghost, xs, ys, Z; opacity = 0.35)
		@test _t3_fields(ghost.data[end].fields[:line])[:color] == "#A6A6A6"
		# Over a dark scene background the blend uses that background.
		dark = plot_surface(Z)
		PlotlySupply._merge_scene_layout_attr!(dark.layout, :scene, attr(bgcolor = "#000000"))
		plot_wireframe!(dark, xs, ys, Z; opacity = 0.5, color = "white")
		@test _t3_fields(dark.data[end].fields[:line])[:color] ==
			  PlotlySupply._blend_over("white", 0.5, "#000000"; who = "test")
		# 5 line separators + the NaN point on its row line and on its column line.
		@test count(isnothing, plot_wireframe(xs, ys, [NaN 1.0; 2.0 3.0; 4.0 5.0]).data[1].fields[:z]) == 7
		@test length(plot_wireframe(xs, ys, BitMatrix([1 0; 0 1; 1 1])).data[1].fields[:z]) == 17
		@test_throws ArgumentError plot_wireframe(xs, ys, Z; rstride = 0, cstride = 0)
		@test_throws ArgumentError plot_wireframe(xs, ys, Z; rstride = -1)
		@test_throws ArgumentError plot_wireframe(xs, ys, Any[0 1; 2 "x"; 4 5])
		@test_throws ArgumentError plot_wireframe(xs, ys, Z; opacity = 1.5)
		@test_throws ArgumentError plot_wireframe(xs, ys, Z; dash = "dotted")
		@test_throws ArgumentError plot_wireframe([0.0, 1.0], ys, Z)
	end

	@testset "plot_segments3d (F33)" begin
		f = plot_segments3d([0.0, 1.0], [0.0, 0.0], [0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [0.0, 0.0];
			dash = "dash", linewidth = 2)
		t = f.data[1].fields
		@test t[:x] == [0.0, 0.0, nothing, 1.0, 1.0, nothing]
		@test t[:y] == [0.0, 1.0, nothing, 0.0, 1.0, nothing]
		@test _t3_fields(t[:line]) == Dict{Symbol, Any}(:color => "#999999", :width => 2.0, :dash => "dash")
		g = plot_segments3d([0.0, 1.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 0.0], [1 2; 2 3])
		@test g.data[1].fields[:x] == [0.0, 1.0, nothing, 1.0, 1.0, nothing]
		@test plot_segments3d([0.0], [0.0], [0.0], [NaN], [1.0], [1.0]).data[1].fields[:x] == [0.0, nothing, nothing]
		plot_segments3d!(g, [0.0], [0.0], [0.0], [0.0], [0.0], [1.0]; color = :red, legend = "z")
		@test _t3_fields(g.data[end].fields[:line])[:color] == "red"
		@test g.data[end].fields[:name] == "z" && g.data[end].fields[:showlegend] === true
		@test_throws ArgumentError plot_segments3d([0.0], [0.0], [0.0], [1.0, 2.0], [0.0], [0.0])
		@test_throws ArgumentError plot_segments3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0], [1 3])
		@test_throws ArgumentError plot_segments3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0], [1 2 1])
		@test_throws ArgumentError plot_segments3d(Any[0.0, "a"], [0.0, 1.0], [0.0, 1.0], [1 2])
	end

	@testset "plot_quiver3d style = :arrow (F34)" begin
		f = plot_quiver3d([0.0, 1.0, 5.0], [0.0, 0.0, 5.0], [0.0, 0.0, 5.0], [2.0, 0.0, 0.0], [0.0, 0.0, 0.0],
			[0.0, 4.0, 0.0]; style = :arrow, color = "red", headsize = 0.25, linewidth = 3, legend = "F")
		shaft, heads = f.data
		@test shaft.fields[:type] == "scatter3d"
		@test shaft.fields[:x] == [0.0, 1.5, nothing, 1.0, 1.0, nothing]   # the zero vector is skipped
		@test shaft.fields[:z] == [0.0, 0.0, nothing, 0.0, 3.0, nothing]
		@test _t3_fields(shaft.fields[:line]) == Dict{Symbol, Any}(:color => "red", :width => 3.0)
		@test shaft.fields[:name] == "F" && shaft.fields[:showlegend] === true
		@test heads.fields[:type] == "cone"
		@test heads.fields[:x] == [2.0, 1.0] && heads.fields[:z] == [0.0, 4.0]   # tips
		@test heads.fields[:anchor] == "tip"
		@test heads.fields[:sizemode] == "raw"
		@test heads.fields[:sizeref] == 0.25
		@test heads.fields[:colorscale] == [[0, "red"], [1, "red"]]
		@test heads.fields[:showscale] === false && heads.fields[:showlegend] === false
		d = plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; style = :arrow)
		@test _t3_fields(d.data[1].fields[:line])[:color] == PlotlySupply._default_trace_color(d, 1)
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; style = :arrow, headsize = 1)
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; style = :arrow, sizeref = 2)
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; style = :arrow, colorscale = "viridis")
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; headsize = 0.3)
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; style = :quiver)
		g = plot_scatter3d([0.0], [0.0], [0.0])
		plot_quiver3d!(g, [0.0], [0.0], [0.0], [0.0], [1.0], [0.0]; style = "arrow")
		@test length(g.data) == 3
	end

	@testset "plot_surface colour, opacity, lighting and edges (C24, C28)" begin
		xs = 0.0:1.0:3.0
		ys = 0.0:0.5:1.0
		Z = [x + y for x in xs, y in ys]
		f = plot_surface(xs, ys, Z; color = "steelblue", opacity = 0.6, lighting = :flat, edges = true,
			edgecolor = "white", edgewidth = 2)
		t = f.data[1].fields
		@test t[:colorscale] == [[0, "steelblue"], [1, "steelblue"]]
		@test t[:showscale] === false
		@test t[:opacity] == 0.6
		@test _t3_fields(t[:lighting])[:diffuse] == 0.0
		cx = _t3_fields(_t3_fields(t[:contours])[:x])
		cy = _t3_fields(_t3_fields(t[:contours])[:y])
		@test cx[:show] === true && cx[:start] == 0.0 && cx[:size] == 1.0 && cx[:end] > 3.0
		@test cy[:size] == 0.5 && cx[:color] == "white" && cx[:width] == 2.0
		g = plot_surface(xs, ys, Z; crange = [0, 10], cmid = 2, colorscale = "RdBu", colorbar_title = "T")
		@test g.data[1].fields[:cmin] == 0.0 && g.data[1].fields[:cmax] == 10.0
		@test haskey(g.data[1].fields, :colorbar)
		h = plot_surface(xs, ys, Z .+ 1; colornorm = :log)
		@test h.data[1].fields[:surfacecolor] ≈ log10.(Z .+ 1)
		k = plot_surface(xs, ys, Z; levels = [0, 1, 2, 4])
		@test k.data[1].fields[:cmin] == 0 && k.data[1].fields[:cmax] == 4
		a = plot_surface(xs, ys, Z; coloraxis = "coloraxis2", colorscale = "viridis")
		@test a.data[1].fields[:coloraxis] == "coloraxis2"
		@test haskey(_t3_fields(_t3_layout(a)[:coloraxis2]), :colorscale)
		@test !haskey(a.data[1].fields, :colorscale)
		@test_throws ArgumentError plot_surface(xs, ys, Z; color = "steelblue", colorscale = "viridis")
		@test_throws ArgumentError plot_surface(xs, ys, Z; edges = true, edgewidth = 20)
		@test_throws ArgumentError plot_surface([0.0, 1, 3, 4], ys, Z; edges = true)   # non-uniform
		@test_throws ArgumentError plot_surface(xs, ys, Z; lighting = (shininess = 1,))
		@test_throws ArgumentError plot_surface(xs, ys, Z; shared_coloraxis = true, coloraxis = "coloraxis2")
		@test_throws ArgumentError plot_surface(xs, [0.0, 1.0], Z)
		@test_throws ArgumentError plot_surface(rand(2, 2, 2))
		# Curvilinear grids are accepted (without edges).
		X = [r * cos(θ) for r in 1:3, θ in range(0, π; length = 4)]
		Y = [r * sin(θ) for r in 1:3, θ in range(0, π; length = 4)]
		@test plot_surface(X, Y, X .+ Y).data[1].fields[:x] === X
		@test_throws ArgumentError plot_surface(X, Y, X .+ Y; edges = true)
	end

	@testset "colour keywords on every coloured 3-D trace (C20, C21)" begin
		viridis = PlotlySupply._resolve_colorscale("viridis"; who = "test").scale
		g = [0.0, 1.0]
		V = [x + y + z for x in g, y in g, z in g]
		traces = (
			plot_quiver3d([0.0, 1], [0.0, 1], [0.0, 1], [1.0, 1], [0.0, 1], [0.0, 1]; colorscale = "viridis",
				crange = [0, 2], colorbar_title = "|v|").data[1],
			plot_isosurface(g, g, g, V; colorscale = "viridis", crange = [0, 2], colorbar_title = "|v|").data[1],
			plot_volume(g, g, g, V; colorscale = "viridis", crange = [0, 2], colorbar_title = "|v|").data[1],
			plot_streamtube(g, g, g, V, V, V; colorscale = "viridis", crange = [0, 2], colorbar_title = "|v|").data[1],
			plot_mesh3d([0.0, 1, 0], [0.0, 0, 1], [0.0, 0, 0]; intensity = [0.0, 1, 2], colorscale = "viridis",
				crange = [0, 2], colorbar_title = "|v|").data[1],
		)
		for t in traces
			@test t.fields[:colorscale] == viridis
			@test t.fields[:cmin] == 0.0 && t.fields[:cmax] == 2.0
			@test haskey(_t3_fields(t.fields[:colorbar]), :title)
		end
		# A shared colour axis across a 1×3 scene grid.
		sf = _t3_scene_sf(3)
		for c in 1:3
			plot_surface!(sf, c .* rand(3, 3); row = 1, col = c, coloraxis = :shared, colorscale = "viridis")
		end
		@test all(t -> t.fields[:coloraxis] == "coloraxis", sf.plot.data)
		@test _t3_fields(_t3_layout(sf)[:coloraxis])[:colorscale] == viridis
		plot_isosurface!(sf, g, g, g, V; row = 1, col = 3, coloraxis = "coloraxis2", crange = [0, 3])
		@test sf.plot.data[end].fields[:coloraxis] == "coloraxis2"
		@test _t3_fields(_t3_layout(sf)[:coloraxis2])[:cmax] == 3.0
		@test_throws ArgumentError plot_isosurface(g, g, g, V; colornorm = :log)
		@test_throws ArgumentError plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; colornorm = :log)
		@test_throws ArgumentError plot_volume(g, g, g, V; coloraxis = "axis2")
		@test_throws ArgumentError plot_volume(g, g, g, V; isomin = 2, isomax = 1)
		@test_throws ArgumentError plot_volume(g, g, g, V; surface_count = -1)
		@test_throws ArgumentError plot_isosurface(g, g, g, V; caps = 1)
	end

	@testset "plot_scatter3d text, opacity and colours (F32, B2)" begin
		f = plot_scatter3d(1:3, 1:3, 1:3; mode = "markers", text = ["a", "b", "c"], textposition = "top center",
			textsize = 14, marker_color = :red, color = :blue)
		t = f.data[1].fields
		@test t[:mode] == "markers+text"
		@test t[:text] == ["a", "b", "c"] && t[:textposition] == "top center"
		@test _t3_fields(t[:textfont])[:size] == 14
		@test _t3_fields(t[:marker])[:color] == "red"
		@test _t3_fields(t[:line])[:color] == "blue"
		g = plot_scatter3d(1:3, 1:3, 1:3; color = "black", opacity = 0.35)
		@test _t3_fields(g.data[1].fields[:line])[:color] == "#A6A6A6"
		@test !haskey(g.data[1].fields, :opacity)
		h = plot_scatter3d(1:3, 1:3, 1:3; opacity = 0.5)
		@test _t3_fields(h.data[1].fields[:line])[:color] ==
			  PlotlySupply._blend_over(PlotlySupply._default_trace_color(h, 1), 0.5, "#ffffff"; who = "test")
		m = plot_scatter3d([1:3, 1:3], [1:3, 1:3], [1:3, 3:-1:1]; text = [["a", "b", "c"], ["d", "e", "f"]],
			textsize = [10, 12])
		@test m.data[2].fields[:text] == ["d", "e", "f"]
		@test _t3_fields(m.data[2].fields[:textfont])[:size] == 12
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; text = ["a"])
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; textposition = "top")
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; opacity = 2)
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; marker_symbol = "triangle-up")
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; color = "notacolour")
		@test_throws ArgumentError plot_scatter3d(1:3, 1:2, 1:3)
		@test_throws ArgumentError plot_scatter3d(1:3, 1:3, 1:3; linewidth = -1)
	end

	@testset "SubplotFigure cells: background, colours, keyword routing" begin
		sf = _t3_scene_sf()
		plot_scatter3d!(sf, 1:2, 1:2, 1:2; row = 1, col = 1)
		plot_scatter3d!(sf, 1:2, 1:2, 1:2; row = 1, col = 1)
		PlotlySupply._merge_scene_layout_attr!(sf.plot.layout, :scene2, attr(bgcolor = "#ff0000"))
		plot_scatter3d!(sf, 1:2, 1:2, 1:2; row = 1, col = 2, color = "#0000ff", opacity = 0.5)
		@test _t3_fields(sf.plot.data[end].fields[:line])[:color] ==
			  PlotlySupply._blend_over("#0000ff", 0.5, "#ff0000"; who = "test")
		plot_scatter3d!(sf, 1:2, 1:2, 1:2; row = 1, col = 2, opacity = 0.5)
		@test _t3_fields(sf.plot.data[end].fields[:line])[:color] ==
			  PlotlySupply._blend_over(PlotlySupply._default_trace_color(sf.plot, 4), 0.5, "#ff0000"; who = "test")
		# Scene keywords go to the target cell's scene only.
		before1 = PlotlyBase.JSON.json(_t3_layout(sf)[:scene])
		plot_surface!(sf, rand(3, 3); row = 1, col = 2, xlabel = "\$x_1\$", zrange = [0, 2], perspective = false)
		@test _t3_fields(_t3_axis(sf, :xaxis, :scene2)[:title])[:text] == "x<sub>1</sub>"
		@test _t3_axis(sf, :zaxis, :scene2)[:range] == [0, 2]
		@test PlotlyBase.JSON.json(_t3_layout(sf)[:scene]) == before1
		@test_throws ArgumentError plot_surface!(sf, rand(3, 3); row = 1, col = 2, secondary_y = true)
		@test_throws ArgumentError plot_surface!(sf, rand(3, 3); row = 1, col = 2, show = true)
		mixed = subplots(1, 2; sync = false, specs = [Spec(kind = "xy") Spec(kind = "scene")])
		n = length(mixed.plot.data)
		@test_throws ArgumentError plot_scatter3d!(mixed, 1:2, 1:2, 1:2; row = 1, col = 1)
		@test length(mixed.plot.data) == n
		# Each 3-D mutator works on a cell other than (1, 1).
		g = [0.0, 1.0]
		V = [x + y + z for x in g, y in g, z in g]
		cell = _t3_scene_sf()
		for add! in (
			s -> plot_surface!(s, rand(2, 2); row = 1, col = 2),
			s -> plot_scatter3d!(s, 1:2, 1:2, 1:2; row = 1, col = 2),
			s -> plot_quiver3d!(s, g, g, g, g, g, g; row = 1, col = 2),
			s -> plot_mesh3d!(s, [0.0, 1, 0], [0.0, 0, 1], [0.0, 0, 0]; row = 1, col = 2),
			s -> plot_isosurface!(s, g, g, g, V; row = 1, col = 2),
			s -> plot_volume!(s, g, g, g, V; row = 1, col = 2),
			s -> plot_streamtube!(s, g, g, g, V, V, V; row = 1, col = 2),
			s -> plot_polygons3d!(s, [[0.0 0 0; 1 0 0; 0 1 0]]; row = 1, col = 2),
			s -> plot_wireframe!(s, g, g, rand(2, 2); row = 1, col = 2),
			s -> plot_segments3d!(s, g, g, g, g, g, g; row = 1, col = 2),
		)
			before = length(cell.plot.data)
			@test add!(cell) === cell
			@test length(cell.plot.data) > before
			@test all(t -> get(t.fields, :scene, "") == "scene2", cell.plot.data[(before + 1):end])
		end
	end

	@testset "SyncPlot mutators and return values" begin
		scripts = String[]
		p = plot_scatter3d(1:3, 1:3, 1:3)
		sp = _t3_syncplot(p, scripts)
		@test plot_surface!(sp, rand(3, 3)) === nothing
		@test length(p.data) == 2
		@test view!(sp; elev = 10, azim = 10) === sp
		@test scene!(sp; aspectratio = (1, 1, 1)) === sp
		@test annotate!(sp, 1, 1, 1, "x") === sp
		@test plot_polygons3d!(sp, [[0.0 0 0; 1 0 0; 0 1 0]]) === nothing
		@test plot_wireframe!(sp, [0.0, 1.0], [0.0, 1.0], rand(2, 2)) === nothing
		@test plot_segments3d!(sp, [0.0], [0.0], [0.0], [1.0], [1.0], [1.0]) === nothing
		@test length(scripts) == 7
		@test_throws ArgumentError plot_surface!(sp, rand(3, 3); show = true)
		@test length(scripts) == 7
		for name in (:view!, :scene!, :plot_polygons3d!, :plot_wireframe!, :plot_segments3d!)
			@test name in PlotlySupply._SCI_SCENE3D_MUTATORS
		end
	end

	@testset "constructor/mutator keyword parity" begin
		pairs = (
			(plot_surface, plot_surface!), (plot_scatter3d, plot_scatter3d!), (plot_quiver3d, plot_quiver3d!),
			(plot_mesh3d, plot_mesh3d!), (plot_isosurface, plot_isosurface!), (plot_volume, plot_volume!),
			(plot_streamtube, plot_streamtube!), (plot_polygons3d, plot_polygons3d!),
			(plot_wireframe, plot_wireframe!), (plot_segments3d, plot_segments3d!),
		)
		keywords(f) = Set(Iterators.flatten(
			(Symbol(k) for k in Base.kwarg_decl(m) if !endswith(string(k), "...")) for m in methods(f)
			if parentmodule(m) === PlotlySupply && !(m.sig isa UnionAll ? false : any(T -> T === SubplotFigure, m.sig.parameters))
		))
		for (ctor, mut) in pairs
			ck = setdiff(keywords(ctor), (:show,))
			mk = setdiff(keywords(mut), (:row, :col, :secondary_y))
			@test (ctor, setdiff(ck, mk)) == (ctor, Set{Symbol}())
			@test (mut, setdiff(mk, ck)) == (mut, Set{Symbol}())
		end
	end

	@testset "docstring examples run" begin
		functions = (
			plot_surface, plot_surface!, plot_scatter3d, plot_scatter3d!, plot_quiver3d, plot_quiver3d!,
			plot_mesh3d, plot_mesh3d!, plot_isosurface, plot_isosurface!, plot_volume, plot_volume!,
			plot_streamtube, plot_streamtube!, plot_polygons3d, plot_polygons3d!, plot_wireframe,
			plot_wireframe!, plot_segments3d, plot_segments3d!, view!, scene!,
		)
		blocks(f) = begin
			doc = string(Base.Docs.doc(f))
			at = findfirst("# Examples", doc)
			at === nothing ? String[] :
			[m.captures[1] for m in eachmatch(r"```julia\n(.*?)```"s, doc[last(at):end])]
		end
		for f in functions
			examples = blocks(f)
			@test (f, length(examples)) == (f, 1)
			for code in examples
				@test (f, Base.include_string(Module(), code) !== missing) == (f, true)
			end
		end
		# annotate! has 2-D and 3-D docs; the 3-D example is the one using a scene.
		annotate_examples = filter(code -> occursin("plot_scatter3d", code), blocks(annotate!))
		@test length(annotate_examples) == 1
		@test Base.include_string(Module(), only(annotate_examples)) isa Plot
	end
end
