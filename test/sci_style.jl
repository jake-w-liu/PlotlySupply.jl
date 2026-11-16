using Test
using PlotlySupply

# Tests for src/sci/style.jl: PlotStyle presets, the internal style API used by
# the constructors, set_fonts!, tight_layout! and figsize!.

@testset "sci style" begin
	PS = PlotlySupply
	PB = PlotlySupply.PlotlyBase
	sd(x) = PS._symbol_dict(x)
	json(x) = PB.JSON.json(x)
	OKABE_ITO = ["#E69F00", "#56B4E9", "#009E73", "#F0E442", "#0072B2", "#D55E00", "#CC79A7", "#000000"]

	function fake_syncplot(p)
		scripts = String[]
		backend = (
			isopen = window -> true,
			close = window -> nothing,
			run = (window, script) -> (push!(scripts, String(script)); "ok"),
		)
		resources = PS._SyncPlotResources(nothing, backend)
		return SyncPlot(p, nothing, :sci_style_probe, "sci-style-probe", resources), scripts
	end

	original_template = get_default_template()
	try
		@testset "PlotStyle construction and validation" begin
			s = PlotStyle()
			@test s.template === nothing
			@test s.font_family == ""
			@test s.fontsize === 0.0
			@test s.font_color == ""
			@test s.colorway === nothing
			@test s.ticks == "outside"
			@test s.spines === :box
			@test s.grid && s.legend_frame
			@test s.margin === nothing
			@test s.mathsize == ""
			@test s.cycle === :none

			@test PlotStyle(; template = " plotly_dark + xgridoff ").template === Symbol("plotly_dark+xgridoff")
			@test PlotStyle(; template = "simple_white").template === :simple_white
			@test PlotStyle(; ticks = :none).ticks == ""
			@test PlotStyle(; ticks = "inside").ticks == "inside"
			@test PlotStyle(; spines = "open").spines === :open
			@test PlotStyle(; cycle = "dash_marker").cycle === :dash_marker
			@test PlotStyle(; colorway = :okabe_ito).colorway == OKABE_ITO
			@test PlotStyle(; colorway = [PB.Colors.RGB(1, 0, 0), "blue", :green]).colorway == ["#FF0000", "blue", "green"]
			@test PlotStyle(; colorway = PB.colors.all[:okabe_ito]).colorway == OKABE_ITO
			@test PlotStyle(; font_color = PB.Colors.RGBA(0, 0, 0, 0.5)).font_color == "rgba(0,0,0,0.5)"
			@test PlotStyle(; margin = 12).margin == Dict(:l => 12.0, :r => 12.0, :t => 12.0, :b => 12.0)
			@test PlotStyle(; margin = (l = 5, t = 7)).margin == Dict(:l => 5.0, :t => 7.0)
			@test PlotStyle(; margin = Dict("pad" => 2)).margin == Dict(:pad => 2.0)
			@test PlotStyle(; fontsize = 12, linewidth = 1.5).fontsize === 12.0

			@test_throws ArgumentError PlotStyle(; fontsize = -1)
			@test_throws ArgumentError PlotStyle(; fontsize = 0.5)
			@test_throws ArgumentError PlotStyle(; tick_fontsize = NaN)
			@test_throws ArgumentError PlotStyle(; label_fontsize = Inf)
			@test_throws ArgumentError PlotStyle(; fontsize = true)
			@test_throws ArgumentError PlotStyle(; linewidth = -0.1)
			@test_throws ArgumentError PlotStyle(; ticks = :sideways)
			@test_throws ArgumentError PlotStyle(; spines = :left)
			@test_throws ArgumentError PlotStyle(; cycle = :rainbow)
			@test_throws ArgumentError PlotStyle(; mathsize = "\\big")
			# Exactly the MathJax 2 switches the mathtext pipeline accepts.
			@test_throws ArgumentError PlotStyle(; mathsize = "\\footnotesize")
			@test PlotStyle(; mathsize = "\\Tiny").mathsize == "\\Tiny"
			for size in ("\\tiny", "\\scriptsize", "\\small", "\\normalsize", "\\large", "\\Large", "\\LARGE", "\\huge", "\\Huge")
				@test PlotStyle(; mathsize = size).mathsize == size
				@test mathtext("\$x\$"; size = size) isa String
			end
			@test_throws ArgumentError PlotStyle(; template = :no_such_template)
			@test_throws ArgumentError PlotStyle(; template = "plotly_white+no_such_template")
			@test_throws ArgumentError PlotStyle(; template = "plotly_white+")
			@test_throws ArgumentError PlotStyle(; template = 3)
			@test_throws ArgumentError PlotStyle(; font_color = "notacolor")
			@test_throws ArgumentError PlotStyle(; colorway = :no_such_palette)
			@test_throws ArgumentError PlotStyle(; colorway = String[])
			@test_throws ArgumentError PlotStyle(; colorway = ["#ffffff", "bad"])
			@test_throws ArgumentError PlotStyle(; colorway = ["#ffffff", ""])
			@test_throws ArgumentError PlotStyle(; margin = -1)
			@test_throws ArgumentError PlotStyle(; margin = (l = 1, q = 2))
			@test_throws ArgumentError PlotStyle(; margin = NamedTuple())
			@test_throws ArgumentError PlotStyle(; margin = "10")

			s = PlotStyle()
			s.fontsize = 12
			@test s.fontsize === 12.0
			@test_throws ArgumentError (s.fontsize = -1)
			@test s.fontsize === 12.0
			s.colorway = :okabe_ito
			@test s.colorway == OKABE_ITO
			@test_throws ArgumentError (s.bogus = 1)
			@test_throws ArgumentError (s.ticks = "both")
			@test s.ticks == "outside"

			c = copy(s)
			@test c == s
			@test c !== s
			@test c.colorway !== s.colorway
			c.colorway[1] = "#123456"
			@test s.colorway[1] == "#E69F00"

			@test PlotStyle(; fontsize = 12) == PlotStyle(; fontsize = 12)
			@test hash(PlotStyle(; fontsize = 12)) == hash(PlotStyle(; fontsize = 12))
			@test PlotStyle(; fontsize = 12) != PlotStyle(; fontsize = 13)
			t = PB.Template(layout = PB.Layout(paper_bgcolor = "white"))
			t_equal = PB.Template(layout = PB.Layout(paper_bgcolor = "white"))
			@test PlotStyle(; template = t) == PlotStyle(; template = t)
			@test hash(PlotStyle(; template = t)) == hash(PlotStyle(; template = t))
			@test PlotStyle(; template = t) != PlotStyle(; template = t_equal)

			shown = sprint(show, MIME"text/plain"(), PlotStyle(; fontsize = 12, template = t))
			@test occursin("PlotStyle:", shown)
			@test occursin("fontsize = 12.0", shown)
			@test occursin("PlotlyBase.Template(…)", shown)
		end

		@testset "registry, set/get/with_style" begin
			@test get_default_style() == PlotStyle()
			pub = PS._STYLE_REGISTRY[:publication]
			@test pub.template === :plotly_white
			@test pub.font_family == "STIXGeneral, Times New Roman, serif"
			@test pub.font_color == "#000000"
			@test pub.tick_fontsize < pub.label_fontsize
			@test pub.colorway == OKABE_ITO
			@test pub.spines === :box
			@test !pub.legend_frame
			@test pub.mathsize == "\\large"
			@test pub.margin == Dict(:l => 10.0, :r => 10.0, :t => 10.0, :b => 10.0)

			returned = set_default_style!(:publication)
			@test returned == pub
			returned.fontsize = 30
			@test get_default_style().fontsize == pub.fontsize
			@test PS._active_style() == pub
			@test PS._style_mathsize() == "\\large"

			got = get_default_style()
			got.fontsize = 31
			@test get_default_style().fontsize == pub.fontsize

			updated = set_default_style!(; tick_fontsize = 11)
			@test updated.tick_fontsize == 11.0
			@test updated.font_family == pub.font_family
			@test get_default_style().tick_fontsize == 11.0
			@test PS._STYLE_REGISTRY[:publication].tick_fontsize == 12.0

			before = get_default_style()
			@test_throws ArgumentError set_default_style!(:publication; fontsize = -1)
			@test_throws ArgumentError set_default_style!(; bogus = 1)
			@test_throws ArgumentError set_default_style!(:no_such_style)
			@test get_default_style() == before

			@test set_default_style!(:default) == PlotStyle()
			@test get_default_style() == PlotStyle()

			value = with_style(:publication) do
				get_default_style().font_family
			end
			@test value == pub.font_family
			@test get_default_style() == PlotStyle()

			@test_throws ErrorException with_style(() -> error("boom"), :publication)
			@test get_default_style() == PlotStyle()

			nested = with_style(:publication) do
				inner = with_style(; fontsize = 20) do
					s = get_default_style()
					(s.font_family, s.fontsize)
				end
				(inner, get_default_style().fontsize)
			end
			@test nested == ((pub.font_family, 20.0), pub.fontsize)
			@test get_default_style() == PlotStyle()

			called = Ref(false)
			@test_throws ArgumentError with_style(() -> (called[] = true), :publication; fontsize = -1)
			@test !called[]
			@test_throws ArgumentError with_style(() -> (called[] = true), :no_such_style)
			@test !called[]

			mine = PlotStyle(; fontsize = 18, cycle = :bw)
			@test register_style!(:sci_style_test, mine) === :sci_style_test
			mine.fontsize = 40
			@test PS._STYLE_REGISTRY[:sci_style_test].fontsize == 18.0
			@test with_style(() -> get_default_style().cycle, :sci_style_test) === :bw
			@test_throws ArgumentError register_style!(:default, PlotStyle())
			@test_throws ArgumentError register_style!(:publication, PlotStyle())
			@test PS._STYLE_REGISTRY[:default] == PlotStyle()
		end

		@testset ":default style reproduces 1.x" begin
			default = PlotStyle()
			axis = PS._style_axis_defaults(default)
			# The 1.x `_cartesian_axis_style` constants.
			legacy = Dict{Symbol, Any}(
				:zeroline => false,
				:showline => true,
				:mirror => true,
				:ticks => "outside",
				:automargin => true,
				:linecolor => "#000000",
				:linewidth => 1.0,
				:tickcolor => "#000000",
			)
			@test axis == legacy
			@test sd(PS._cartesian_axis_style()) == legacy
			@test PS._style_axis_defaults(default; axis = :y) == legacy
			@test PS._style_legend_defaults(default) == (
				bgcolor = PS._DEFAULT_LEGEND_BGCOLOR[],
				bordercolor = PS._DEFAULT_LEGEND_BORDERCOLOR[],
				borderwidth = Float64(PS._DEFAULT_LEGEND_BORDERWIDTH[]),
			)
			@test isempty(PS._style_layout_defaults(default))
			@test isempty(PS._style_trace_defaults(default, 3))
			@test PS._style_mathsize(default) == ""
			@test_throws ArgumentError PS._style_axis_defaults(default; axis = :z)

			@test PS._style_template(default) === PS._resolve_template(PS._DEFAULT_TEMPLATE[])
			set_default_template!(:plotly_dark)
			@test PS._style_template(default) === PB.templates[:plotly_dark]
			@test PS._style_axis_defaults(default)[:linecolor] == "#f2f5fa"
			set_default_template!(original_template)

			# `_apply_default_template!` is wired through the style API (C37);
			# under :default re-applying it changes nothing.
			figures = [
				plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; legend = ["a", "b"], title = "T", xlabel = "x", ylabel = "y"),
				plot_heatmap(collect(1:3), collect(1:2), [1 2; 3 4; 5 6]; title = "H"),
				subplots(1, 2; sync = false, subplot_titles = ["a" "b"]).fig,
			]
			for fig in figures
				before = json(fig)
				PS._apply_style_layout!(fig, default)
				@test json(fig) == before
				PS._apply_default_template!(fig)
				@test json(fig) == before
			end
		end

		@testset "template-derived colours (dark templates)" begin
			dark = PB.templates[:plotly_dark]
			@test PS._template_is_dark(dark)
			@test !PS._template_is_dark(PB.templates[:plotly_white])
			@test !PS._template_is_dark(PB.templates[:xgridoff])
			@test PS._template_is_dark(PS._resolve_template("plotly_dark+xgridoff"))
			@test PS._template_ink(dark) == "#f2f5fa"
			@test PS._template_ink(PB.templates[:plotly_white]) == "#000000"
			@test PS._template_ink(PB.templates[:ggplot2]) == "#000000"
			# Black background with a font colour that would be unreadable on it.
			low_contrast = PB.Template(layout = PB.Layout(paper_bgcolor = "black", font = PB.attr(color = "#111111")))
			@test PS._template_is_dark(low_contrast)
			@test PS._template_ink(low_contrast) == "#ffffff"
			# A fully transparent background is the white page underneath.
			transparent = PB.Template(layout = PB.Layout(paper_bgcolor = "rgba(0,0,0,0)"))
			@test !PS._template_is_dark(transparent)

			@test PS._template_legend_colors(dark) == (bgcolor = "rgba(17,17,17,0.72)", bordercolor = "rgba(255,255,255,0.25)")
			@test PS._template_legend_colors(PB.templates[:plotly_white]) ==
				  (bgcolor = PS._DEFAULT_LEGEND_BGCOLOR[], bordercolor = PS._DEFAULT_LEGEND_BORDERCOLOR[])

			dark_style = PlotStyle(; template = :plotly_dark)
			axis = PS._style_axis_defaults(dark_style)
			@test axis[:linecolor] == "#f2f5fa"
			@test axis[:tickcolor] == "#f2f5fa"
			@test PS._style_legend_defaults(dark_style) ==
				  (bgcolor = "rgba(17,17,17,0.72)", bordercolor = "rgba(255,255,255,0.25)", borderwidth = 1.0)
			@test PS._style_legend_defaults(PlotStyle(; legend_frame = false)) ==
				  (bgcolor = "rgba(0,0,0,0)", bordercolor = "rgba(0,0,0,0)", borderwidth = 0.0)
		end

		@testset "axis defaults: spines, ticks, grid, custom templates" begin
			open_axis = PS._style_axis_defaults(PlotStyle(; spines = :open))
			@test open_axis[:showline] && !open_axis[:mirror]
			none_axis = PS._style_axis_defaults(PlotStyle(; spines = :none))
			@test !none_axis[:showline] && !none_axis[:mirror]
			@test PS._style_axis_defaults(PlotStyle(; ticks = :inside))[:ticks] == "inside"
			@test PS._style_axis_defaults(PlotStyle(; grid = false))[:showgrid] == false
			@test !haskey(PS._style_axis_defaults(PlotStyle()), :showgrid)

			# Publication evidence E18: a custom template's ticks/mirror win.
			custom = PB.Template(layout = PB.Layout(xaxis = PB.attr(ticks = "inside", mirror = "allticks")))
			x_axis = PS._style_axis_defaults(PlotStyle(; template = custom); axis = :x)
			@test !haskey(x_axis, :ticks) && !haskey(x_axis, :mirror)
			@test x_axis[:showline]
			y_axis = PS._style_axis_defaults(PlotStyle(; template = custom); axis = :y)
			@test y_axis[:ticks] == "outside" && y_axis[:mirror]
			# Built-in templates keep the PlotlySupply look, also when passed as
			# the Template object (regression: this lookup used to throw a
			# MethodError on PlotlyBase's lazy template table).
			for spec in (:ggplot2, PB.templates[:ggplot2], "simple_white+xgridoff")
				axis = PS._style_axis_defaults(PlotStyle(; template = spec))
				@test axis[:ticks] == "outside"
				@test axis[:mirror]
			end
		end

		@testset "trace cycles" begin
			bw = PlotStyle(; cycle = :bw, linewidth = 2, marker_size = 6.5)
			@test PS._style_trace_defaults(bw, 1) ==
				  Dict(:dash => "solid", :linewidth => 2, :marker_size => 6.5)
			@test PS._style_trace_defaults(bw, 2)[:dash] == "dash"
			@test PS._style_trace_defaults(bw, 4)[:dash] == "dashdot"
			@test PS._style_trace_defaults(bw, 5)[:dash] == "solid"
			# The :bw ink is the figure colorway, derived from the template.
			@test PS._style_layout_defaults(bw)[:colorway] == ["#000000"]
			@test PS._style_layout_defaults(bw; template = PB.templates[:plotly_dark])[:colorway] == ["#f2f5fa"]
			@test PS._style_layout_defaults(PlotStyle(; cycle = :bw, colorway = :okabe_ito))[:colorway] == ["#000000"]
			dash = PS._style_trace_defaults(PlotStyle(; cycle = :dash), 3)
			@test dash == Dict(:dash => "dot")
			marker = PS._style_trace_defaults(PlotStyle(; cycle = :marker), 9)
			@test marker == Dict(:marker_symbol => "circle", :markers => true)
			both = PS._style_trace_defaults(PlotStyle(; cycle = :dash_marker), 2)
			@test both == Dict(:dash => "dash", :marker_symbol => "square", :markers => true)
			@test_throws ArgumentError PS._style_trace_defaults(bw, 0)
		end

		@testset "_apply_style_layout! (:publication)" begin
			pub = PS._STYLE_REGISTRY[:publication]
			fig = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; legend = ["a", "b"], title = "T", xlabel = "x", ylabel = "y")
			old_xaxis = fig.layout.fields[:xaxis]
			old_xaxis_json = json(old_xaxis)
			PS._apply_style_layout!(fig, pub)
			fields = fig.layout.fields
			@test sd(fields[:font]) == Dict(:family => pub.font_family, :size => 14, :color => "#000000")
			@test fields[:colorway] == OKABE_ITO
			@test sd(fields[:margin]) == Dict(:l => 10, :r => 10, :t => 10, :b => 10)
			title = sd(fields[:title])
			@test title[:text] == "T"
			@test title[:automargin] === true
			@test sd(title[:pad])[:t] == 10
			@test sd(title[:font])[:size] == 16
			xaxis = sd(fields[:xaxis])
			@test sd(xaxis[:title])[:text] == "x"
			@test sd(sd(xaxis[:title])[:font])[:size] == 14
			@test sd(xaxis[:tickfont])[:size] == 12
			@test sd(sd(fields[:legend])[:font])[:size] == 12
			# The axis container that existed before was replaced, not mutated.
			@test json(old_xaxis) == old_xaxis_json

			# Subplot titles above the plot area raise the top margin.
			sf = subplots(1, 2; sync = false, title = "", subplot_titles = ["a" "b"])
			PS._apply_style_layout!(sf.fig, pub)
			@test sd(sf.layout.fields[:margin])[:t] > 10
			@test sd(sf.layout.fields[:margin])[:l] == 10
		end

		@testset "set_fonts! on a Plot" begin
			fig = PB.Plot(
				[
					PB.scatter(x = [1, 2], y = [1, 2]),
					PB.scatter(x = [1, 2], y = [2, 1], yaxis = "y2", legend = "legend2"),
				],
				PB.Layout(
					title = "T",
					xaxis = PB.attr(title = "x"),
					yaxis2 = PB.attr(overlaying = "y", side = "right", title = PB.attr(text = "right", font = PB.attr(color = "red"))),
					legend2 = PB.attr(x = 0.1),
					annotations = [
						PB.attr(text = "note", x = 1, y = 1, xref = "x", yref = "y"),
						PB.attr(text = "panel", x = 0.5, y = 1, xref = "paper", yref = "paper", name = "plotlysupply:title:1:1"),
					],
				),
			)
			old_xaxis = fig.layout.fields[:xaxis]
			old_xaxis_json = json(old_xaxis)
			@test set_fonts!(fig; family = "Arial", size = 13, color = :black, title = 20, label = 15, tick = 9,
				legend = 11, annotation = 10) === nothing
			fields = fig.layout.fields
			@test sd(fields[:font]) == Dict(:family => "Arial", :size => 13, :color => "black")
			title = sd(fields[:title])
			@test title[:text] == "T"
			@test sd(title[:font]) == Dict(:size => 20)
			for key in (:xaxis, :yaxis, :yaxis2)
				axis = sd(fields[key])
				@test sd(sd(axis[:title])[:font])[:size] == 15
				@test sd(axis[:tickfont]) == Dict(:size => 9)
			end
			@test sd(sd(fields[:xaxis])[:title])[:text] == "x"
			@test sd(fields[:yaxis2])[:overlaying] == "y"
			@test sd(sd(fields[:yaxis2])[:title])[:text] == "right"
			@test sd(sd(sd(fields[:yaxis2])[:title])[:font]) == Dict(:color => "red", :size => 15)
			@test sd(sd(fields[:legend])[:font]) == Dict(:size => 11)
			@test sd(sd(fields[:legend2])[:font]) == Dict(:size => 11)
			@test sd(fields[:legend2])[:x] == 0.1
			annotations = fields[:annotations]
			@test sd(sd(annotations[1])[:font]) == Dict(:size => 10)
			@test sd(sd(annotations[2])[:font]) == Dict(:size => 20)
			@test json(old_xaxis) == old_xaxis_json

			# Only the roles passed are written.
			set_fonts!(fig; tick = 7.5, units = :pt)
			@test sd(sd(fig.layout.fields[:xaxis])[:tickfont]) == Dict(:size => 10)
			@test sd(sd(sd(fig.layout.fields[:xaxis])[:title])[:font])[:size] == 15
			@test sd(fig.layout.fields[:font])[:size] == 13

			# Missing title: no error, the title font is still set for a later title.
			untitled = PB.Plot(PB.scatter(y = [1, 2]))
			@test set_fonts!(untitled; title = 18) === nothing
			@test sd(sd(untitled.layout.fields[:title])[:font]) == Dict(:size => 18)

			# Colorbars: trace-level, coloraxis, marker colorbars only when shown.
			cb = PB.Plot(
				[
					PB.heatmap(z = [[1, 2], [3, 4]]),
					PB.heatmap(z = [[1, 2], [3, 4]], coloraxis = "coloraxis2"),
					PB.scatter(y = [1, 2], marker = PB.attr(color = [1, 2], showscale = true)),
					PB.scatter(y = [1, 2], marker = PB.attr(color = "red")),
				],
				PB.Layout(coloraxis2 = PB.attr(colorscale = "Viridis")),
			)
			set_fonts!(cb; tick = 9, label = 13)
			heat_cb = sd(cb.data[1].fields[:colorbar])
			@test sd(heat_cb[:tickfont]) == Dict(:size => 9)
			@test sd(sd(heat_cb[:title])[:font]) == Dict(:size => 13)
			coloraxis_cb = sd(sd(cb.layout.fields[:coloraxis2])[:colorbar])
			@test sd(coloraxis_cb[:tickfont]) == Dict(:size => 9)
			@test sd(cb.layout.fields[:coloraxis2])[:colorscale] == "Viridis"
			marker_cb = sd(sd(cb.data[3].fields[:marker])[:colorbar])
			@test sd(marker_cb[:tickfont]) == Dict(:size => 9)
			@test sd(cb.data[3].fields[:marker])[:showscale] === true
			@test !haskey(sd(cb.data[4].fields[:marker]), :colorbar)
			set_fonts!(cb; colorbar = 20)
			heat_cb = sd(cb.data[1].fields[:colorbar])
			@test sd(heat_cb[:tickfont]) == Dict(:size => 20)
			@test sd(sd(heat_cb[:title])[:font]) == Dict(:size => 20)
		end

		@testset "set_fonts! validation and atomicity" begin
			fig = plot_scatter(1:3, [1, 2, 3]; title = "T", xlabel = "x")
			before = json(fig)
			@test_throws ArgumentError set_fonts!(fig; size = -1)
			@test_throws ArgumentError set_fonts!(fig; tick = Inf)
			@test_throws ArgumentError set_fonts!(fig; tick = 0.5)
			@test_throws ArgumentError set_fonts!(fig; tick = 0.6, units = :pt)
			@test_throws ArgumentError set_fonts!(fig; label = 12, units = :cm)
			@test_throws ArgumentError set_fonts!(fig; color = "notacolor")
			@test_throws ArgumentError set_fonts!(fig; tick = 10, row = 1, col = 1)
			@test json(fig) == before

			# A malformed container anywhere aborts the whole call.
			broken = plot_scatter(1:3, [1, 2, 3]; legend = "a")
			broken.layout.fields[:xaxis] = 5
			broken_before = json(broken)
			@test_throws ArgumentError set_fonts!(broken; legend = 12, label = 10)
			@test json(broken) == broken_before

			# SyncPlot: one renderer update on success, none on failure.
			sp, scripts = fake_syncplot(plot_scatter(1:3, [1, 2, 3]; title = "T", xlabel = "x"))
			@test set_fonts!(sp; tick = 11) === nothing
			@test length(scripts) == 1
			@test occursin("tickfont", scripts[end])
			@test sd(sd(sp.plot.layout.fields[:xaxis])[:tickfont]) == Dict(:size => 11)
			sp_before = json(sp.plot)
			@test_throws ArgumentError set_fonts!(sp; tick = -1)
			@test length(scripts) == 1
			@test json(sp.plot) == sp_before
		end

		@testset "set_fonts! on a SubplotFigure" begin
			sf = subplots(1, 2; sync = false, specs = [PB.Spec(kind = "scene") PB.Spec(kind = "polar")])
			@test set_fonts!(sf; label = 15, tick = 9) === sf
			scene = sd(sf.layout.fields[:scene])
			for axis in (:xaxis, :yaxis, :zaxis)
				@test sd(sd(sd(scene[axis])[:title])[:font]) == Dict(:size => 15)
				@test sd(sd(scene[axis])[:tickfont]) == Dict(:size => 9)
			end
			polar = sd(sf.layout.fields[:polar])
			@test sd(sd(sd(polar[:radialaxis])[:title])[:font]) == Dict(:size => 15)
			@test sd(sd(polar[:radialaxis])[:tickfont]) == Dict(:size => 9)
			@test sd(sd(polar[:angularaxis])[:tickfont]) == Dict(:size => 9)

			cells = subplots(1, 2; sync = false, title = "")
			plot_scatter!(cells, collect(1:5), collect(1:5) .^ 2; row = 1, col = 1, legend = "left")
			plot_scatter!(cells, collect(1:5), collect(1:5); row = 1, col = 2, legend = "right")
			plot_heatmap!(cells, collect(1:4), collect(1:3), [1 2 3; 4 5 6; 7 8 9; 10 11 12]; row = 1, col = 2)
			annotate!(cells.fig, 2.0, 2.0, "in cell 2"; xref = "x2", yref = "y2")
			annotate!(cells.fig, 2.0, 2.0, "in cell 1"; xref = "x", yref = "y")
			left_xaxis = json(cells.layout.fields[:xaxis])
			left_legend = json(cells.layout.fields[:legend])
			@test set_fonts!(cells; row = 1, col = 2, size = 20, tick = 8, family = "Courier New", colorbar = 18) === cells
			fields = cells.layout.fields
			@test json(fields[:xaxis]) == left_xaxis
			@test json(fields[:legend]) == left_legend
			for key in (:xaxis2, :yaxis2)
				@test sd(sd(fields[key])[:tickfont]) == Dict(:family => "Courier New", :size => 8)
				@test sd(sd(sd(fields[key])[:title])[:font]) == Dict(:family => "Courier New", :size => 20)
			end
			@test sd(sd(fields[:legend2])[:font]) == Dict(:family => "Courier New", :size => 20)
			heat_cb = sd(cells.fig.data[end].fields[:colorbar])
			@test sd(heat_cb[:tickfont]) == Dict(:family => "Courier New", :size => 18)
			@test sd(sd(fields[:annotations][1])[:font]) == Dict(:family => "Courier New", :size => 20)
			@test !haskey(sd(fields[:annotations][2]), :font)
			@test !haskey(fields, :font)

			snapshot = json(cells.fig)
			@test_throws ArgumentError set_fonts!(cells; row = 1, col = 3, tick = 8)
			@test_throws ArgumentError set_fonts!(cells; row = 1, tick = 8)
			@test_throws ArgumentError set_fonts!(cells; row = 1, col = 1, tick = -8)
			@test json(cells.fig) == snapshot
		end

		@testset "set_fonts! cell scoping by subplot kind" begin
			sf = subplots(1, 2; sync = false, title = "", specs = [PB.Spec() PB.Spec(kind = "scene")])
			# Traces without placing keywords: plotly puts them on the default
			# subplot of their own kind ("x"/"y", "scene").
			push!(sf.fig.data, PB.scatter(y = [1, 2], marker = PB.attr(color = [1, 2], showscale = true)))
			push!(sf.fig.data, PB.surface(z = [[1, 2], [3, 4]]))
			sf.layout.fields[:annotations] = Any[PB.attr(text = "default refs", x = 1, y = 1)]
			set_fonts!(sf; row = 1, col = 1, tick = 8, legend = 11)
			@test sd(sd(sd(sf.fig.data[1].fields[:marker])[:colorbar])[:tickfont]) == Dict(:size => 8)
			@test !haskey(sf.fig.data[2].fields, :colorbar)
			@test !haskey(sd(sf.layout.fields[:annotations][1]), :font)
			@test sd(sd(sf.layout.fields[:legend])[:font]) == Dict(:size => 11)
			set_fonts!(sf; row = 1, col = 1, annotation = 9)
			@test sd(sd(sf.layout.fields[:annotations][1])[:font]) == Dict(:size => 9)
			set_fonts!(sf; row = 1, col = 2, tick = 7)
			@test sd(sd(sf.fig.data[2].fields[:colorbar])[:tickfont]) == Dict(:size => 7)
			@test sd(sd(sd(sf.fig.data[1].fields[:marker])[:colorbar])[:tickfont]) == Dict(:size => 8)
			@test sd(sd(sd(sf.layout.fields[:scene])[:xaxis])[:tickfont]) == Dict(:size => 7)
			@test sd(sd(sf.layout.fields[:annotations][1])[:font]) == Dict(:size => 9)

			# Non-string legend/coloraxis references are ignored, not errors.
			odd = PB.Plot([PB.scatter(y = [1, 2], legend = 5, coloraxis = :nope)])
			@test set_fonts!(odd; legend = 10, colorbar = 10) === nothing
			@test sd(sd(odd.layout.fields[:legend])[:font]) == Dict(:size => 10)
			@test !haskey(odd.layout.fields, :nope)
		end

		@testset "tight_layout!" begin
			fig = plot_scatter(1:3, [1, 2, 3]; title = "T", xlabel = "x")
			relayout!(fig, margin = PB.attr(l = 50, pad = 3))
			@test tight_layout!(fig) === nothing
			margin = sd(fig.layout.fields[:margin])
			@test margin == Dict(:l => 4, :r => 4, :t => 4, :b => 4, :pad => 3)
			title = sd(fig.layout.fields[:title])
			@test title[:text] == "T"
			@test title[:automargin] === true
			@test sd(title[:pad]) == Dict(:t => 4)

			tight_layout!(fig; pad = 2.5)
			@test sd(fig.layout.fields[:margin])[:l] == 2.5
			# An explicit title pad set by the user (here by the previous call) is kept.
			@test sd(sd(fig.layout.fields[:title])[:pad]) == Dict(:t => 4)
			tight_layout!(fig; pad = 0)
			@test sd(fig.layout.fields[:margin])[:b] == 0

			before = json(fig)
			for bad in (-1, NaN, Inf, true)
				@test_throws ArgumentError tight_layout!(fig; pad = bad)
			end
			@test json(fig) == before

			untitled = plot_scatter(1:3, [1, 2, 3])
			tight_layout!(untitled)
			@test !haskey(sd(get(untitled.layout.fields, :title, nothing)), :automargin)

			paper_title = plot_scatter(1:3, [1, 2, 3])
			paper_title.layout.fields[:title] = PB.attr(text = "P", yref = "paper")
			tight_layout!(paper_title)
			@test sd(paper_title.layout.fields[:title])[:automargin] === true
			@test !haskey(sd(paper_title.layout.fields[:title]), :pad)

			# Annotations: paper-referenced ones are measured, data ones are not.
			labelled = plot_scatter(1:3, [1, 2, 3])
			relayout!(labelled, annotations = [
				PB.attr(text = "left label", x = -0.05, y = 0.5, xref = "paper", yref = "paper", xanchor = "right", showarrow = false),
				PB.attr(text = "data note", x = 2, y = 2, xref = "x", yref = "y"),
			])
			tight_layout!(labelled)
			m = sd(labelled.layout.fields[:margin])
			# 10 characters at 12 px * 0.6 em + 2*(borderpad+borderwidth), 0.05 of 700 px left of the plot.
			@test m[:l] == 4 + ceil(0.05 * 700 + 10 * 12 * 0.6 + 4)
			@test (m[:r], m[:t], m[:b]) == (4, 4, 4)

			huge = plot_scatter(1:3, [1, 2, 3])
			relayout!(huge, annotations = [PB.attr(text = repeat("x", 300), x = 0, y = 0.5, xref = "paper", yref = "paper", xanchor = "right", showarrow = false)])
			tight_layout!(huge)
			@test sd(huge.layout.fields[:margin])[:l] == 0.45 * 700

			# Subplot titles above the plot area: their height, and the title's.
			sf = subplots(1, 2; sync = false, title = "", subplot_titles = ["a" "b"])
			subplot_title_size = sd(sd(sf.layout.fields[:annotations][1])[:font])[:size]
			annotation_room = ceil(subplot_title_size * 1.3 + 4)
			@test tight_layout!(sf) === sf
			@test sd(sf.layout.fields[:margin]) == Dict(:l => 4, :r => 4, :t => 4 + annotation_room, :b => 4)
			titled = subplots(1, 2; sync = false, title = "Figure", subplot_titles = ["a" "b"])
			tight_layout!(titled)
			title_room = ceil(round(1.4 * 12) * 1.3 + 4)
			@test sd(titled.layout.fields[:margin])[:t] == 4 + annotation_room + title_room
			@test_throws ArgumentError tight_layout!(titled; pad = -1)

			sp, scripts = fake_syncplot(plot_scatter(1:3, [1, 2, 3]; title = "T"))
			@test tight_layout!(sp) === nothing
			@test length(scripts) == 1
			@test sd(sp.plot.layout.fields[:margin])[:t] == 4
			@test :tight_layout! in PS._SCI_STYLE_MUTATORS
			@test :figsize! in PS._SCI_STYLE_MUTATORS
		end

		@testset "figsize!" begin
			fig = plot_scatter(1:3, [1, 2, 3])
			@test figsize!(fig, 3.5, 2.5; units = :in) === nothing
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (336, 240)
			figsize!(fig, 10, 5; units = :cm)
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (378, 189)
			figsize!(fig, 100, 50; units = :mm)
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (378, 189)
			figsize!(fig, 252, 180; units = :pt)
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (336, 240)
			figsize!(fig, 800.4, 600.6)
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (800, 601)
			@test fig.layout.fields[:width] isa Int

			before = json(fig)
			@test_throws ArgumentError figsize!(fig, 0, 100)
			@test_throws ArgumentError figsize!(fig, 100, -1)
			@test_throws ArgumentError figsize!(fig, NaN, 100)
			@test_throws ArgumentError figsize!(fig, 100, Inf)
			@test_throws ArgumentError figsize!(fig, true, 100)
			@test_throws ArgumentError figsize!(fig, 100, 100; units = :furlong)
			@test_throws ArgumentError figsize!(fig, 5, 100)
			@test_throws ArgumentError figsize!(fig, 0.05, 1; units = :in)
			@test_throws ArgumentError figsize!(fig, 1e12, 100)
			@test json(fig) == before

			sf = subplots(1, 2; sync = false)
			@test figsize!(sf, 6, 3; units = :in) === sf
			@test (sf.layout.fields[:width], sf.layout.fields[:height]) == (576, 288)
			@test_throws ArgumentError figsize!(sf, -6, 3)

			sp, scripts = fake_syncplot(plot_scatter(1:3, [1, 2, 3]))
			@test figsize!(sp, 3, 2; units = :in) === nothing
			@test (sp.plot.layout.fields[:width], sp.plot.layout.fields[:height]) == (288, 192)
			@test length(scripts) == 1
		end
	finally
		set_default_style!(:default)
		set_default_template!(original_template)
	end
end
