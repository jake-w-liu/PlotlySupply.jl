using Test
using PlotlySupply

# Tests for src/sci/style.jl: PlotStyle presets, the internal style API used by
# the constructors, set_fonts!, tight_layout! and figsize!.

@testset "sci style" begin
	PS = PlotlySupply
	PB = PlotlySupply.PlotlyBase
	sd(x) = PS._symbol_dict(x)
	json(x) = PB.JSON.json(x)
	# 2.0 (D14): `:okabe_ito` names the curated COLOR_CYCLES order (thin-line
	# readable colours first); a ColorScheme keeps its own (ColorSchemes) order.
	OKABE_ITO = ["#0072B2", "#D55E00", "#009E73", "#CC79A7", "#000000", "#E69F00", "#56B4E9", "#F0E442"]
	OKABE_ITO_CS = ["#E69F00", "#56B4E9", "#009E73", "#F0E442", "#0072B2", "#D55E00", "#CC79A7", "#000000"]
	thrown(f) = try
		f()
		nothing
	catch err
		err
	end

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
			@test PlotStyle(; colorway = PB.colors.all[:okabe_ito]).colorway == OKABE_ITO_CS
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
			@test s.colorway[1] == "#0072B2"

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
			@test pub.font_family == "Times New Roman, Times, Liberation Serif, serif"
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
			@test PS._style_template(default) === PS._resolve_template(:plotly_dark)
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

			# Subplot titles above the plot area raise the top margin (D12: the
			# room providers do, when the figure is finalized after the change).
			sf = subplots(1, 2; sync = false, title = "", subplot_titles = ["a" "b"])
			PS._apply_style_layout!(sf.fig, pub)
			PS._finalize_figure!(sf)
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
			# The constructor placed the title like `title!` (Z28): its explicit
			# `pad.t` (_TEXT_TITLE_TOP_PAD) is kept, not replaced by the margin.
			@test sd(title[:pad])[:t] == 10

			tight_layout!(fig; pad = 2.5)
			@test sd(fig.layout.fields[:margin])[:l] == 2.5
			# An explicit title pad set by the user (here by the previous call) is kept.
			@test sd(sd(fig.layout.fields[:title])[:pad])[:t] == 10
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
			# Estimated text width at 12 px + 2*(borderpad+borderwidth), 0.05 of 700 px left of the plot.
			label_width = PS._text_extent("left label", 12)[1]
			@test m[:l] == 4 + ceil(0.05 * 700 + label_width + 4)
			# plotly.js 2.35.2 draws "left label" 51 px wide at 12 px
			# (Verdana); the estimate must not fall short of that.
			@test 51 <= label_width <= 65
			@test (m[:r], m[:t], m[:b]) == (4, 4, 4)

			huge = plot_scatter(1:3, [1, 2, 3])
			relayout!(huge, annotations = [PB.attr(text = repeat("x", 300), x = 0, y = 0.5, xref = "paper", yref = "paper", xanchor = "right", showarrow = false)])
			tight_layout!(huge)
			@test sd(huge.layout.fields[:margin])[:l] == 0.45 * 700

			# Subplot titles above the plot area: their height, and the title's.
			# D12: the room providers stack them (a gap, the title line, a gap)
			# and raise the top margin from the tight minimum to hold them.
			sf = subplots(1, 2; sync = false, title = "", subplot_titles = ["a" "b"])
			subplot_title_size = sd(sd(sf.layout.fields[:annotations][1])[:font])[:size]
			@test tight_layout!(sf) === sf
			plan = PS._room_plan(sf)
			line = PS._room_slot(plan, PS._LT_OWNER, "line:xaxis")
			@test line.offset == PS._ROOM_GAP && line.px >= subplot_title_size * 1.3
			@test sd(sf.layout.fields[:margin]) ==
				  Dict(:l => 4, :r => 4, :t => ceil(line.offset + line.px + PS._ROOM_GAP), :b => 4)
			titled = subplots(1, 2; sync = false, title = "Figure", subplot_titles = ["a" "b"])
			tight_layout!(titled)
			plan = PS._room_plan(titled)
			line = PS._room_slot(plan, PS._LT_OWNER, "line:xaxis")
			band = PS._room_slot(plan, PS._LT_OWNER, "figure_title")
			@test band.offset ≈ line.offset + line.px + PS._ROOM_GAP
			@test band.px >= round(1.4 * 12) * 1.3
			@test sd(titled.layout.fields[:margin])[:t] == ceil(band.offset + band.px + PS._ROOM_GAP)
			@test_throws ArgumentError tight_layout!(titled; pad = -1)

			# G37: two-line TeX panel titles are measured as typeset. mathtext
			# writes "(a) …\n$u_x$ = …" as one `\begin{array}` expression;
			# plotly.js 2.35.2 typesets it 147 x 33 px (frame included) at
			# 12 px, so it needs neither side margins nor less than 33 px
			# (+ the 4 px title gap) above the cells.
			for math in (false, true)
				g37 = subplots(1, 2; sync = false)
				for c in 1:2
					plot_scatter!(g37, 1:3, [1, 4, 9]; row = 1, col = c)
					title!(g37, "(a) Mixed enhanced strain\n" * (math ? "\$u_x\$ = 0.3973" : "u_x = 0.3973"); row = 1, col = c)
				end
				figsize!(g37, 8, 3.5; units = :in)
				tight_layout!(g37)
				gm = sd(g37.layout.fields[:margin])
				@test gm[:l] == 4 && gm[:r] == 4
				@test 4 + 4 + 33 <= gm[:t] <= 4 + 4 + 33 * 1.3
			end
			# Figure titles are measured the same way (array rows, not raw TeX).
			tex_title = plot_scatter(1:3, [1, 2, 3])
			tex_title.layout.fields[:title] = PB.attr(text = PS._label("Line one\n\$\\sigma_{xx}\$ two"))
			relayout!(tex_title, annotations = [PB.attr(text = "above", x = 0.5, y = 1, xref = "paper", yref = "paper", yanchor = "bottom", showarrow = false)])
			tight_layout!(tex_title)
			title_size = round(1.4 * 12)
			@test sd(tex_title.layout.fields[:margin])[:t] ==
				  4 + ceil(12 * 1.3 + 4) + ceil(2 * 1.3 * title_size + 4)

			sp, scripts = fake_syncplot(plot_scatter(1:3, [1, 2, 3]; title = "T"))
			@test tight_layout!(sp) === nothing
			@test length(scripts) == 1
			@test sd(sp.plot.layout.fields[:margin])[:t] == 4
			@test :tight_layout! in PS._SCI_STYLE_MUTATORS
			@test :figsize! in PS._SCI_STYLE_MUTATORS
			# Z68: without a layout size, the active style's figure size is measured
			# (a figure made outside the sized style has none).
			ieee = plot_scatter(1:3, [1, 2, 3])
			relayout!(ieee, annotations = [PB.attr(text = "left label", x = -0.05, y = 0.5, xref = "paper",
				yref = "paper", xanchor = "right", showarrow = false)])
			with_style(() -> tight_layout!(ieee), :ieee)
			@test !haskey(ieee.layout.fields, :width)
			ieee_width = with_style(() -> PS._style_default_figure_size()[1], :ieee)
			@test ieee_width < 700
			ieee_font = PS._tight_root_font_size(k -> get(ieee.layout.fields, k, nothing))
			@test sd(ieee.layout.fields[:margin])[:l] ==
				  4 + ceil(0.05 * ieee_width + PS._text_extent("left label", ieee_font)[1] + 4)

			# Z48: a caption placed in figure fractions keeps the room under the
			# x axis that `annotate!` reserved: the room providers hold it.
			captioned = plot_scatter(1:3, [1, 2, 3]; xlabel = "time")
			annotate!(captioned, 0.5, 0.01, "Figure 1. A caption."; coords = :figure, showarrow = false, yanchor = "bottom")
			reserved = sd(captioned.layout.fields[:margin])[:b]
			tight_layout!(captioned)
			@test sd(captioned.layout.fields[:margin])[:b] >= reserved
			caption = sd(only(captioned.layout.fields[:annotations]))
			margins = PS._room_plan(captioned).margins
			# re-placed for the new margins: still at 1 % of the figure height
			@test caption[:yshift] ≈ round(0.01 * (margins.t + margins.b) - margins.b; digits = 2)
		end

		@testset "figsize!" begin
			fig = plot_scatter(1:3, [1, 2, 3])
			@test figsize!(fig, 3.5, 2.5; units = :in) === nothing
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (336, 240)
			# 2.0 (D14): sizes are stored exactly, not rounded to whole pixels,
			# so a vector export has the requested physical size.
			@test fig.layout.fields[:width] isa Int
			figsize!(fig, 10, 5; units = :cm)
			@test fig.layout.fields[:width] ≈ 10 * 96 / 2.54
			@test fig.layout.fields[:height] ≈ 5 * 96 / 2.54
			figsize!(fig, 100, 50; units = :mm)
			@test fig.layout.fields[:width] ≈ 100 * 96 / 25.4
			figsize!(fig, 252, 180; units = :pt)
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (336, 240)
			figsize!(fig, 800.4, 600.6)
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (800.4, 600.6)

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
			# G32 (figsize! part): unknown keywords, `show` included, name the verb.
			msg = sprint(showerror, thrown(() -> figsize!(sp, 3, 2; show = true)))
			@test occursin("figsize!: unsupported keyword argument(s) `show`", msg)
			@test occursin("figsize!: unsupported keyword argument(s) `bogus`", sprint(showerror, thrown(() -> figsize!(sf, 3, 2; bogus = 1))))
			@test_throws ArgumentError figsize!(fig, 3, 2; units = "in")
			@test length(scripts) == 1
		end

		@testset "PlotStyle size and line-weight fields (D14)" begin
			s = PlotStyle(; width = 336, aspect = 0.6, axis_linewidth = 1, tick_length = 4.5, mirror_ticks = true,
				errorbar_width = 1.5, reference_linewidth = 0.75)
			@test (s.width, s.aspect, s.axis_linewidth, s.tick_length) === (336.0, 0.6, 1.0, 4.5)
			@test s.mirror_ticks === true && s.errorbar_width === 1.5 && s.reference_linewidth === 0.75
			# The defaults are "unset" and change nothing.
			d = PlotStyle()
			@test (d.width, d.aspect, d.axis_linewidth, d.tick_length, d.mirror_ticks, d.errorbar_width, d.reference_linewidth) ==
				  (0.0, 0.0, 0.0, 0.0, false, 0.0, 0.0)
			for (name, bad) in ((:width, 5), (:width, -1), (:width, NaN), (:width, 3e9), (:aspect, 0.001), (:aspect, 101),
				(:aspect, -1), (:axis_linewidth, -1), (:tick_length, Inf))
				err = thrown(() -> PlotStyle(; (name => bad,)...))
				@test err isa ArgumentError
				@test occursin("PlotStyle: `$(name)`", sprint(showerror, err))
			end
			# Wrong types are rejected by the keyword signature.
			@test_throws TypeError PlotStyle(; mirror_ticks = 1)
			@test_throws TypeError PlotStyle(; reference_linewidth = "1")
			s_bad = PlotStyle()
			@test_throws ArgumentError (s_bad.mirror_ticks = 1)
			@test_throws ArgumentError (s_bad.errorbar_width = true)
			# width and aspect together must give a height plotly accepts.
			@test occursin("height of 5.0 px", sprint(showerror, thrown(() -> PlotStyle(; width = 10, aspect = 0.5))))
			@test PlotStyle(; width = 20, aspect = 0.5).width == 20
			s2 = PlotStyle(; width = 20)
			@test_throws ArgumentError (s2.aspect = 0.4)
			@test s2.aspect == 0
			@test_throws ArgumentError (s2.width = 12)
			@test s2.width == 20
			@test_throws ArgumentError with_style(() -> nothing; width = 12)
			@test_throws ArgumentError set_default_style!(:ieee; aspect = 0.02)
			@test get_default_style() == PlotStyle()
			# copy / == / hash / show include the new fields.
			c = copy(s)
			@test c == s && hash(c) == hash(s)
			c.mirror_ticks = false
			@test c != s
			shown = sprint(show, MIME"text/plain"(), s)
			@test occursin("aspect = 0.6", shown) && occursin("reference_linewidth = 0.75", shown)
			# Grey levels are colours (G16): converted, never passed through raw.
			@test PlotStyle(; font_color = "0.35").font_color == "#595959"
			@test PlotStyle(; colorway = ["0", "0.5", "red"]).colorway == ["#000000", "#808080", "red"]
			msg = sprint(showerror, thrown(() -> PlotStyle(; font_color = "1.5")))
			@test occursin("PlotStyle: `font_color` = \"1.5\" is a matplotlib grey level and must lie in [0, 1]", msg)
			@test_throws ArgumentError PlotStyle(; colorway = ["#000000", "-0.2"])
			grey_fig = plot_scatter(1:3, [1, 2, 3])
			set_fonts!(grey_fig; color = "0.2")
			@test sd(grey_fig.layout.fields[:font])[:color] == "#333333"
			# The new cycles.
			@test PlotStyle(; cycle = :dash_symbol).cycle === :dash_symbol
			@test PlotStyle(; cycle = "bw_dash_marker").cycle === :bw_dash_marker
			ds = PS._style_trace_defaults(PlotStyle(; cycle = :dash_symbol), 3)
			@test ds == Dict(:dash => "dot", :marker_symbol => "diamond")
			bdm = PlotStyle(; cycle = :bw_dash_marker, colorway = :tol_bright)
			@test PS._style_trace_defaults(bdm, 2) == Dict(:dash => "dash", :marker_symbol => "square", :markers => true)
			@test PS._style_layout_defaults(bdm)[:colorway] == ["#000000"]
			@test PS._style_layout_defaults(bdm; template = PB.templates[:plotly_dark])[:colorway] == ["#f2f5fa"]
			@test PS._style_trace_defaults(PlotStyle(; errorbar_width = 2), 1) == Dict(:errorbar_width => 2)
		end

		@testset "journal presets and journal_width (D14)" begin
			@test Base.isexported(PlotlySupply, :journal_width)
			mm = 96 / 25.4
			expected = Dict(
				:ieee => ([1 => 3.5 * 96, 2 => 7.16 * 96], "Times New Roman, Times, Liberation Serif, serif", 8, "inside", true, :box),
				:aps => ([1 => 86 * mm, 2 => 172 * mm], "Times New Roman, Times, Liberation Serif, serif", 9, "inside", true, :box),
				:nature => ([1 => 89 * mm, 2 => 183 * mm], "Arial, Helvetica, Liberation Sans, sans-serif", 7, "outside", false, :open),
				:elsevier => ([1 => 90 * mm, 1.5 => 140 * mm, 2 => 190 * mm], "Arial, Helvetica, Liberation Sans, sans-serif", 9, "outside", false, :box),
				:springer => ([1 => 84 * mm, 1.5 => 129 * mm, 2 => 174 * mm], "Helvetica, Arial, Liberation Sans, sans-serif", 8, "outside", false, :box),
				:aip => ([1 => 3.37 * 96, 2 => 6.69 * 96], "Times New Roman, Times, Liberation Serif, serif", 8, "inside", true, :box),
			)
			@test Set(PS._JOURNAL_NAMES) == Set(keys(expected))
			@test PS._BUILTIN_STYLE_NAMES == (:default, :publication, PS._JOURNAL_NAMES...)
			for (name, (widths, family, pt, ticks, mirror, spines)) in expected
				st = PS._STYLE_REGISTRY[name]
				@test st.width ≈ widths[1][2]
				@test st.aspect == 0.75
				@test PS._style_default_figure_size(st) == (st.width, st.width * 0.75)
				@test st.font_family == family
				px = pt * 4 / 3
				@test all(f -> getfield(st, f) ≈ px, (:fontsize, :title_fontsize, :label_fontsize, :tick_fontsize, :legend_fontsize))
				@test (st.ticks, st.mirror_ticks, st.spines) == (ticks, mirror, spines)
				# Print weights: 1 pt data lines, 0.75 pt axes/error bars/references, 3.5 pt ticks.
				@test st.linewidth ≈ 4 / 3 && st.axis_linewidth ≈ 1 && st.errorbar_width ≈ 1 && st.reference_linewidth ≈ 1
				@test st.tick_length ≈ 3.5 * 4 / 3 && st.marker_size ≈ 6
				@test st.colorway == PS.COLOR_CYCLES[:okabe_ito] && st.cycle === :dash_symbol
				@test st.template === :plotly_white && st.font_color == "#000000" && !st.grid && !st.legend_frame
				@test st.mathsize == "\\large"
				for (columns, px_width) in widths
					@test journal_width(name; columns = columns, units = :px) ≈ px_width
					@test journal_width(String(name); columns = columns, units = :mm) ≈ px_width / mm
				end
				@test_throws ArgumentError register_style!(name, PlotStyle())
			end
			@test journal_width(:ieee) == 3.5
			@test journal_width(:ieee; columns = 2) ≈ 7.16
			@test journal_width(:nature; units = :mm) ≈ 89
			@test journal_width(:aps; units = :cm) ≈ 8.6
			@test journal_width(:aip; columns = 2, units = :pt) ≈ 6.69 * 72
			@test journal_width(:springer; columns = 1.5, units = :mm) ≈ 129
			msg = sprint(showerror, thrown(() -> journal_width(:optica)))
			@test occursin("journal_width: unknown journal :optica; journals are :ieee, :aps, :nature, :elsevier, :springer, :aip", msg)
			@test occursin(":ieee defines figure widths for 1, 2 column(s)", sprint(showerror, thrown(() -> journal_width(:ieee; columns = 1.5))))
			@test_throws ArgumentError journal_width(:ieee; columns = true)
			@test_throws ArgumentError journal_width(:ieee; columns = "1")
			@test_throws ArgumentError journal_width(:ieee; units = :furlong)
			@test_throws ArgumentError journal_width(:ieee; units = "in")
			# The built-in presets are selectable like any style.
			with_style(:nature) do
				@test get_default_style() == PS._STYLE_REGISTRY[:nature]
			end
		end

		@testset "figsize! with a journal (D14)" begin
			mm = 96 / 25.4
			fig = plot_scatter(1:3, [1, 2, 3])
			@test figsize!(fig, :nature) === nothing
			@test fig.layout.fields[:width] ≈ 89 * mm
			@test fig.layout.fields[:height] ≈ 89 * mm * 0.75
			figsize!(fig, :ieee; columns = 2, height = 3)
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (7.16 * 96, 288)
			figsize!(fig, "elsevier"; columns = 1.5, aspect = 0.5)
			@test fig.layout.fields[:width] ≈ 140 * mm && fig.layout.fields[:height] ≈ 70 * mm
			figsize!(fig, :springer; height = 60, units = :mm)
			@test fig.layout.fields[:height] ≈ 60 * mm
			figsize!(fig, :nature; height = 17, units = :cm)        # exactly the 170 mm limit
			@test fig.layout.fields[:height] ≈ 170 * mm
			figsize!(fig, :ieee)
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (336, 252)
			# The active style's aspect is the default.
			with_style(; width = 300, aspect = 0.5) do
				figsize!(fig, :aip)
			end
			@test fig.layout.fields[:height] ≈ 3.37 * 96 * 0.5
			before = json(fig)
			for (args, kwargs, needle) in (
				((:optica,), (;), "unknown journal :optica"),
				((:aps,), (; columns = 1.5), ":aps defines figure widths for 1, 2 column(s)"),
				((:ieee,), (; aspect = 0.5, height = 2), "pass `aspect` or `height`, not both"),
				((:ieee,), (; aspect = 0), "`aspect` (height / width) must be between 0.01 and 100"),
				((:ieee,), (; aspect = NaN), "`aspect` must be finite"),
				((:nature,), (; height = 171, units = :mm), "Nature figures may be at most 170 mm high"),
				((:springer,), (; height = 24, units = :cm), "Springer figures may be at most 234 mm high"),
				((:aip,), (; height = 9), "AIP Publishing figures may be at most 8.25 in high"),
				((:ieee,), (; height = 0.05), "plotly requires at least 10 px"),
				((:ieee,), (; height = -1), "`height` must be > 0"),
				((:ieee,), (; units = :furlong), "`units` must be one of"),
				((:ieee,), (; show = true), "unsupported keyword argument(s) `show`"),
				((:ieee,), (; colums = 2), "unsupported keyword argument(s) `colums`"),
			)
				msg = sprint(showerror, thrown(() -> figsize!(fig, args...; kwargs...)))
				@test startswith(msg, "ArgumentError: figsize!: ")
				@test occursin(needle, msg)
			end
			@test json(fig) == before

			sf = subplots(2, 2; sync = false)
			@test figsize!(sf, :nature; columns = 2, aspect = 0.8) === sf
			@test sf.layout.fields[:width] ≈ 183 * mm && sf.layout.fields[:height] ≈ 183 * mm * 0.8
			sf_before = json(sf.plot)
			@test_throws ArgumentError figsize!(sf, :nature; height = 200, units = :mm)
			@test_throws ArgumentError figsize!(sf, :nature; show = true)
			@test json(sf.plot) == sf_before

			sp, scripts = fake_syncplot(plot_scatter(1:3, [1, 2, 3]))
			@test figsize!(sp, :aps) === nothing
			@test sp.plot.layout.fields[:width] ≈ 86 * mm
			@test length(scripts) == 1
			@test_throws ArgumentError figsize!(sp, :aps; columns = 3)
			@test length(scripts) == 1
		end

		@testset "sized styles size new figures; _style_default_figure_size (D14)" begin
			@test PS._style_default_figure_size(PlotStyle()) == (700.0, 500.0)
			@test PS._style_default_figure_size(PS._STYLE_REGISTRY[:publication]) == (700.0, 500.0)
			@test PS._style_default_figure_size(PlotStyle(; width = 400)) == (400.0, 300.0)
			@test PS._style_default_figure_size(PlotStyle(; width = 400, aspect = 1.25)) == (400.0, 500.0)
			with_style(:ieee) do
				@test PS._style_default_figure_size() == (336.0, 252.0)
				fig = plot_scatter(1:3, [1, 2, 3])
				@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (336, 252)
				@test fig.layout.fields[:width] isa Int
				# A size the caller gives wins; a lone width keeps the aspect, a
				# lone height keeps the column width.
				w = plot_scatter(1:3, [1, 2, 3]; width = 600)
				@test (w.layout.fields[:width], w.layout.fields[:height]) == (600, 450)
				h = plot_scatter(1:3, [1, 2, 3]; height = 400)
				@test (h.layout.fields[:width], h.layout.fields[:height]) == (336, 400)
				both = plot_scatter(1:3, [1, 2, 3]; width = 500, height = 100)
				@test (both.layout.fields[:width], both.layout.fields[:height]) == (500, 100)
				pie = plot_pie([1, 2]; labels = ["a", "b"])
				@test (pie.layout.fields[:width], pie.layout.fields[:height]) == (336, 252)
				sf = subplots(2, 2; sync = false)
				@test (sf.layout.fields[:width], sf.layout.fields[:height]) == (336, 252)
			end
			with_style(:nature) do
				fig = plot_heatmap(1:3, 1:3, [1 2 3; 4 5 6; 7 8 9])
				@test fig.layout.fields[:width] ≈ 89 * 96 / 25.4
			end
			# Unsized styles write no size (plotly autosize, 700 x 500 export).
			for name in (:default, :publication)
				fig = with_style(() -> plot_scatter(1:3, [1, 2, 3]), name)
				@test !haskey(fig.layout.fields, :width) && !haskey(fig.layout.fields, :height)
			end
			# An extreme aspect is clamped to plotly's range for a lone width.
			with_style(; width = 100, aspect = 0.1) do
				fig = plot_scatter(1:3, [1, 2, 3]; width = 50)
				@test fig.layout.fields[:height] == 10
			end
		end

		@testset "_style_ink, _style_line_width, axis line weights (D14)" begin
			light = plot_scatter(1:3, [1, 2, 3])
			@test PS._style_ink(light) == "#000000"
			dark = plot_scatter(1:3, [1, 2, 3])
			set_template!(dark, :plotly_dark)
			@test PS._style_ink(dark) == "#f2f5fa"
			bare = PB.Plot(PB.scatter(x = 1:2, y = 1:2), PB.Layout())
			delete!(bare.layout.fields, :template)   # PlotlyBase adds its default template
			with_style(; template = :plotly_dark) do
				@test PS._style_ink(bare) == "#f2f5fa"      # no template: the style's
			end
			ieee = PS._STYLE_REGISTRY[:ieee]
			@test PS._style_line_width(:data; default = 2, style = ieee) ≈ 4 / 3
			@test PS._style_line_width(:contour; default = 2, style = ieee) ≈ 4 / 3
			@test PS._style_line_width(:mesh; default = 0.5, style = ieee) ≈ 4 / 3
			@test PS._style_line_width(:reference; default = 2, style = ieee) ≈ 1
			@test PS._style_line_width(:axis; default = 2, style = ieee) ≈ 1
			@test PS._style_line_width(:errorbar; default = 2, style = ieee) ≈ 1
			@test PS._style_line_width(:reference; default = 1.5) === 1.5      # :default style
			with_style(; reference_linewidth = 3) do
				@test PS._style_line_width(:reference; default = 1) === 3.0
			end
			@test occursin("unknown line role :spine", sprint(showerror, thrown(() -> PS._style_line_width(:spine; default = 1))))
			@test_throws ArgumentError PS._style_line_width(:data; default = -1)
			@test_throws ArgumentError PS._style_line_width(:data; default = NaN)

			ax = PS._style_axis_defaults(ieee)
			@test ax[:mirror] == "ticks" && ax[:ticks] == "inside"
			@test ax[:linewidth] == 1 && ax[:tickwidth] == 1 && ax[:ticklen] ≈ 3.5 * 4 / 3
			@test ax[:showgrid] === false && !haskey(ax, :gridwidth)
			nat = PS._style_axis_defaults(PS._STYLE_REGISTRY[:nature])
			@test nat[:mirror] === false && nat[:showline] === true && nat[:ticks] == "outside"
			@test PS._style_axis_defaults(PlotStyle(; mirror_ticks = true, ticks = :none))[:mirror] === true
			@test PS._style_axis_defaults(PlotStyle(; mirror_ticks = true, spines = :open))[:mirror] === false
			@test PS._style_axis_defaults(PlotStyle(; axis_linewidth = 2))[:gridwidth] == 2
			# :default keeps the 1.x frame keys exactly.
			@test !any(haskey(PS._style_axis_defaults(), k) for k in (:tickwidth, :ticklen, :gridwidth))
		end
	finally
		set_default_style!(:default)
		set_default_template!(original_template)
	end
end
