using Test, PlotlySupply

# Regression tests for the template / default-look code (src/api.jl:
# `_normalize_template`, `set_default_template!`, `_apply_default_template!`,
# `_cartesian_axis_style`, `_default_cartesian_layout`,
# `_apply_default_cartesian_axes!`, `set_template!`, `_maybe_show`,
# `_apply_basic_plot_options!`) and its wiring to the PlotStyle API
# (src/sci/style.jl, spec C37/C38).

const _RS = PlotlySupply
const _RS_PB = PlotlySupply.PlotlyBase
const _RS_DARK_INK = "#f2f5fa"
const _RS_DARK_LEGEND = (bgcolor = "rgba(17,17,17,0.72)", bordercolor = "rgba(255,255,255,0.25)")
const _RS_LIGHT_LEGEND = (bgcolor = "rgba(255,255,255,0.72)", bordercolor = "rgba(0,0,0,0.15)")
# A trace type PlotlySupply cannot read (no `fields`): style helpers skip it.
struct _RSOpaqueTrace <: PlotlySupply.PlotlyBase.AbstractTrace end

# 2.0 (D14): the curated `COLOR_CYCLES[:okabe_ito]` order (high contrast first).
const _RS_OKABE_ITO = ["#0072B2", "#D55E00", "#009E73", "#CC79A7", "#000000", "#E69F00", "#56B4E9", "#F0E442"]

_rs_sd(x) = _RS._symbol_dict(x)
_rs_layout(fig) = _RS._plot_layout(fig).fields
_rs_get(fig, key) = _rs_sd(get(_rs_layout(fig), key, nothing))
_rs_json(fig) = _RS_PB.JSON.json(_RS._plot_obj(fig))

function _rs_syncplot(p)
	scripts = String[]
	backend = (
		isopen = window -> true,
		close = window -> nothing,
		run = (window, script) -> (push!(scripts, String(script)); "ok"),
	)
	sp = SyncPlot(p, nothing, :regression_style, "regression-style", _RS._SyncPlotResources(nothing, backend))
	return sp, scripts
end

# Run `f` with the given default template and style, restoring both after.
function _rs_with_defaults(f; template = nothing, style = nothing)
	old_template = get_default_template()
	old_style = get_default_style()
	try
		template === nothing || set_default_template!(template)
		style === nothing || set_default_style!(style)
		return f()
	finally
		_RS._DEFAULT_TEMPLATE[] = old_template
		set_default_style!(old_style)
	end
end

@testset "regression: templates and the default look" begin
	original_template = get_default_template()
	original_style = get_default_style()
	try
		set_default_template!(:plotly_white)
		set_default_style!(:default)

		@testset "#119 #131 #216 #266 #283 spines and legend follow the template" begin
			fig = plot_scatter(1:4, [[1, 2, 3, 4], [4, 3, 2, 1]]; legend = ["a", "b"])
			@test set_template!(fig, "plotly_dark") === nothing
			@test fig.layout.fields[:template] == _RS_PB.templates[:plotly_dark]
			for key in (:xaxis, :yaxis)
				axis = _rs_get(fig, key)
				@test axis[:linecolor] == _RS_DARK_INK
				@test axis[:tickcolor] == _RS_DARK_INK
				# Nothing else about the frame changes.
				@test axis[:showline] === true && axis[:mirror] === true && axis[:ticks] == "outside"
			end
			legend = _rs_get(fig, :legend)
			@test (legend[:bgcolor], legend[:bordercolor]) == Tuple(_RS_DARK_LEGEND)
			@test legend[:borderwidth] == 1.0

			set_template!(fig, "plotly_white")
			@test _rs_get(fig, :xaxis)[:linecolor] == "#000000"
			@test _rs_get(fig, :yaxis)[:tickcolor] == "#000000"
			legend = _rs_get(fig, :legend)
			@test (legend[:bgcolor], legend[:bordercolor]) == Tuple(_RS_LIGHT_LEGEND)

			# Light → light changes nothing but the template.
			x_before = _rs_get(fig, :xaxis)
			set_template!(fig, :ggplot2)
			@test _rs_get(fig, :xaxis) == x_before

			# Colours the user chose survive any number of template changes.
			user = plot_scatter(1:3, 1:3; legend = "u")
			relayout!(user, xaxis = attr(linecolor = "red"), legend_bgcolor = "yellow")
			update_yaxes!(user; tickcolor = "blue")
			set_template!(user, "plotly_dark")
			@test _rs_get(user, :xaxis)[:linecolor] == "red"
			@test _rs_get(user, :xaxis)[:tickcolor] == _RS_DARK_INK
			@test _rs_get(user, :yaxis)[:tickcolor] == "blue"
			@test _rs_get(user, :yaxis)[:linecolor] == _RS_DARK_INK
			@test _rs_get(user, :legend)[:bgcolor] == "yellow"
			@test _rs_get(user, :legend)[:bordercolor] == _RS_DARK_LEGEND.bordercolor
			set_template!(user, "plotly_white")
			@test _rs_get(user, :xaxis)[:linecolor] == "red"
			@test _rs_get(user, :yaxis)[:linecolor] == "#000000"

			# A compound and a Template object are handled like a name.
			compound = plot_scatter(1:3, 1:3)
			set_template!(compound, " plotly_dark + xgridoff ")
			@test _rs_get(compound, :xaxis)[:linecolor] == _RS_DARK_INK
			set_template!(compound, _RS_PB.templates[:plotly_white])
			@test _rs_get(compound, :xaxis)[:linecolor] == "#000000"

			# Every axis and per-cell legend of a multi-axis figure.
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, 1:3, 1:3; row = 1, col = 1, legend = "l")
			plot_scatter!(sf, 1:3, 3:-1:1; row = 1, col = 2, legend = "r")
			set_template!(sf.fig, "plotly_dark")
			for key in (:xaxis, :yaxis, :xaxis2, :yaxis2)
				@test _rs_get(sf.fig, key)[:linecolor] == _RS_DARK_INK
				@test _rs_get(sf.fig, key)[:tickcolor] == _RS_DARK_INK
			end
			for key in filter(k -> occursin(r"^legend\d*$", String(k)), collect(keys(_rs_layout(sf.fig))))
				@test _rs_get(sf.fig, key)[:bgcolor] == _RS_DARK_LEGEND.bgcolor
			end

			# New figures under a dark default template.
			_rs_with_defaults(; template = :plotly_dark) do
				for g in (
					plot_scatter(1:4, [[1, 2, 3, 4], [4, 3, 2, 1]]; legend = ["a", "b"]),
					plot_area(1:5, [1, 3, 2, 5, 4]),
					plot_waterfall(["a", "b"], [1, 2]),
				)
					@test _rs_get(g, :xaxis)[:linecolor] == _RS_DARK_INK
					@test _rs_get(g, :yaxis)[:tickcolor] == _RS_DARK_INK
				end
				g = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; legend = ["a", "b"])
				@test _rs_get(g, :legend)[:bgcolor] == _RS_DARK_LEGEND.bgcolor
				# Non-Cartesian constructors get the dark legend box too.
				pie = plot_pie([1, 2]; labels = ["p", "q"])
				@test _rs_get(pie, :legend)[:bgcolor] == _RS_DARK_LEGEND.bgcolor
			end
			h = plot_scatter(1:4, 1:4)
			@test _rs_get(h, :xaxis)[:linecolor] == "#000000"
		end

		@testset "set_template! on a SyncPlot" begin
			sp, scripts = _rs_syncplot(plot_scatter(1:3, 1:3; legend = "s"))
			@test set_template!(sp, :plotly_dark) === nothing
			@test sp.plot.layout.fields[:template] == _RS_PB.templates[:plotly_dark]
			@test _rs_get(sp, :xaxis)[:linecolor] == _RS_DARK_INK
			@test _rs_get(sp, :legend)[:bgcolor] == _RS_DARK_LEGEND.bgcolor
			@test !isempty(scripts)
			@test any(s -> occursin(_RS_DARK_INK, s), scripts)
			before = _rs_json(sp)
			@test_throws ArgumentError set_template!(sp, 3)
			@test_throws ArgumentError set_template!(sp, :plotly_white; show = false)
			@test _rs_json(sp) == before
			close(sp)
		end

		@testset "#5 #53 #116 #284 (+ set_template! part of #41 #130 #268) set_template! on a SubplotFigure" begin
			# The findings' own regression tests (sync = false, Plot-backed).
			# Before: set_template! changed the template and then threw.
			s5 = subplots(1, 1; sync = false)
			plot!(s5, 1:3, [1, 2, 3])
			@test set_template!(s5, "ggplot2") === s5
			@test s5.plot.layout.fields[:template] == _RS_PB.templates[:ggplot2]
			@test annotate!(s5, 2, 2, "hi") === s5
			@test length(s5.plot.layout.fields[:annotations]) == 1
			s53 = subplots(1, 2; sync = false)
			@test annotate!(s53, 1, 1, "hi"; xref = "x2", yref = "y2") === s53
			s53b = subplots(1, 2; sync = false)
			set_template!(s53b, "plotly_dark")
			@test s53b.plot.layout.fields[:template].layout.fields[:paper_bgcolor] == "rgb(17,17,17)"
			s53c = subplots(1, 1; sync = false, specs = fill(Spec(kind = "map"), 1, 1))
			plot_densitymap!(s53c, [0.0, 1.0], [0.0, 1.0], nothing)
			@test length(s53c.plot.data) == 1 && s53c.plot.data[1].fields[:subplot] == "map"
			s116 = subplots(2, 1; sync = false, show = false)
			plot_scatter!(s116, [1.0, 2.0], [3.0, 4.0])
			@test set_template!(s116, "plotly_dark") === s116
			@test s116.layout.fields[:template] == _RS_PB.templates[:plotly_dark]
			s284 = subplots(1, 2; sync = false)
			plot!(s284, 1:3, [1, 2, 3])
			@test hasproperty(s284, :plot)
			set_template!(s284, "plotly_dark")
			@test s284.plot.layout.fields[:template] == _RS._resolve_template("plotly_dark")

			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, 1:5, [1.0, 2, 3, 2, 1]; row = 1, col = 2, legend = "a")
			@test set_template!(sf, "plotly_dark") === sf
			@test sf.plot.layout.fields[:template] == _RS_PB.templates[:plotly_dark]
			@test sf.plot.layout.fields[:template].layout.fields[:paper_bgcolor] == "rgb(17,17,17)"
			for key in (:xaxis, :yaxis, :xaxis2, :yaxis2)
				@test _rs_get(sf, key)[:linecolor] == _RS_DARK_INK
			end
			# Stored legend colours for legends added later are re-derived too.
			@test (sf.legend_bgcolor, sf.legend_bordercolor) == Tuple(_RS_DARK_LEGEND)
			@test (sf.rows, sf.cols) == (1, 2)

			# Validation happens before anything changes.
			before = _rs_json(sf)
			stored = (sf.legend_bgcolor, sf.legend_bordercolor)
			@test_throws ArgumentError set_template!(sf, 3)
			err = try
				set_template!(sf, :plotly_white; show = false)
				nothing
			catch e
				e
			end
			@test err isa ArgumentError
			@test occursin("show", sprint(showerror, err))
			@test_throws ArgumentError set_template!(sf; row = 1, col = 1)
			@test _rs_json(sf) == before
			@test (sf.legend_bgcolor, sf.legend_bordercolor) == stored

			# Default argument and back to light.
			@test set_template!(sf) === sf
			@test sf.plot.layout.fields[:template] == _RS_PB.templates[:plotly_white]
			@test _rs_get(sf, :xaxis2)[:linecolor] == "#000000"
			@test (sf.legend_bgcolor, sf.legend_bordercolor) == Tuple(_RS_LIGHT_LEGEND)

			# Custom stored legend colours are kept.
			custom = subplots(1, 1; sync = false, legend_bgcolor = "pink")
			set_template!(custom, :plotly_dark)
			# `subplots` stores colours normalised to hex (2.0, `_color_hex`).
			@test custom.legend_bgcolor == "#FFC0CB"
			@test custom.legend_bordercolor == _RS_DARK_LEGEND.bordercolor

			# SyncPlot-backed SubplotFigure.
			sp, scripts = _rs_syncplot(subplots(1, 2; sync = false).fig)
			sf_sync = SubplotFigure(sp, 1, 2, 1, 1, true, :topright, (0.02, 0.03),
				_RS_LIGHT_LEGEND.bgcolor, _RS_LIGHT_LEGEND.bordercolor, 1.0)
			@test set_template!(sf_sync, :plotly_dark) === sf_sync
			@test sp.plot.layout.fields[:template] == _RS_PB.templates[:plotly_dark]
			@test _rs_get(sp, :xaxis2)[:linecolor] == _RS_DARK_INK
			@test sf_sync.legend_bgcolor == _RS_DARK_LEGEND.bgcolor
			@test !isempty(scripts)
			close(sp)
		end

		@testset "#9 template names with surrounding whitespace" begin
			@test (@test_logs _RS._normalize_template("ggplot2 ")) === :ggplot2
			@test (@test_logs _RS._normalize_template(" ggplot2")) === :ggplot2
			@test (@test_logs _RS._normalize_template(Symbol(" seaborn "))) === :seaborn
			@test (@test_logs _RS._normalize_template(" plotly_dark + xgridoff ")) === Symbol("plotly_dark+xgridoff")
			@test (@test_logs _RS._normalize_template(SubString("xggplot2", 2))) === :ggplot2
			for bad in ("", "  ", "nope", "ggplot2+", "+ggplot2", "ggplot2 + nope")
				@test (@test_logs (:warn,) _RS._normalize_template(bad)) === :plotly_white
			end
			@test_throws ArgumentError _RS._normalize_template(1)
			fig = plot_scatter(1:3, 1:3)
			@test_logs set_template!(fig, " ggplot2 ")
			@test fig.layout.fields[:template] == _RS_PB.templates[:ggplot2]
			_rs_with_defaults() do
				@test (@test_logs set_default_template!(" seaborn ")) === :seaborn
				@test get_default_template() === :seaborn
			end
		end

		@testset "#122 set_template! default follows the package default" begin
			_rs_with_defaults(; template = :plotly_dark) do
				f = plot_scatter(1:3, [1, 2, 3])
				set_template!(f, "seaborn")
				set_template!(f)
				@test f.layout.fields[:template] == _RS_PB.templates[:plotly_dark]
				@test _rs_get(f, :xaxis)[:linecolor] == _RS_DARK_INK
			end
			doc = string(@doc set_template!)
			@test occursin("template = get_default_template()", doc)
			@test !occursin("template = \"plotly_white\"", doc)
			@test occursin("SubplotFigure", doc)
		end

		@testset "C38 set_default_template! accepts a Template" begin
			custom = _RS_PB.Template(layout = _RS_PB.Layout(paper_bgcolor = "rgb(5,5,40)", font = attr(color = "#eeeeee")))
			_rs_with_defaults() do
				@test set_default_template!(custom) === custom
				@test get_default_template() === custom
				fig = plot_scatter(1:3, 1:3; legend = "c")
				@test fig.layout.fields[:template] == custom
				# A dark custom template gets a light frame and a dark legend box.
				@test _rs_get(fig, :xaxis)[:linecolor] == "#eeeeee"
				@test _rs_get(fig, :legend)[:bgcolor] == "rgba(5,5,40,0.72)"
				@test _RS._style_template(PlotStyle()) === custom
				# set_template! with no template applies the Template default.
				other = plot_scatter(1:3, 1:3)
				set_template!(other, :ggplot2)
				set_template!(other)
				@test other.layout.fields[:template] == custom
				heat = plot_heatmap([1 2; 3 4])
				@test heat.layout.fields[:template] == custom
				# Invalid values leave the default unchanged.
				@test_throws ArgumentError set_default_template!(3)
				@test get_default_template() === custom
			end
			@test get_default_template() === :plotly_white
		end

		@testset ":default style keeps the 1.x layout (D7 titles)" begin
			legacy_axis = Dict{Symbol, Any}(
				:zeroline => false,
				:showline => true,
				:mirror => true,
				:ticks => "outside",
				:automargin => true,
				:linecolor => "#000000",
				:linewidth => 1.0,
				:tickcolor => "#000000",
			)
			@test _rs_sd(_RS._cartesian_axis_style()) == legacy_axis
			@test _rs_sd(_RS._cartesian_axis_style(; axis = :y)) == legacy_axis
			x_axis = _rs_sd(_RS._cartesian_axis_style(; title_text = SubString("a b", 1), tick0 = 1.5))
			@test _rs_sd(x_axis[:title]) == Dict(:text => "a b")
			@test x_axis[:tick0] == 1.5
			math = _rs_sd(_RS._cartesian_axis_style(; title_text = "\$\\alpha\$"))
			@test _rs_sd(math[:title])[:text] == _RS._label("\$\\alpha\$")
			@test_throws ArgumentError _RS._cartesian_axis_style(; axis = :z)

			layout = _RS._default_cartesian_layout()
			@test !haskey(layout.fields, :title)
			@test _rs_sd(layout.fields[:xaxis]) == legacy_axis
			@test _rs_sd(layout.fields[:yaxis]) == legacy_axis
			titled = _RS._default_cartesian_layout(; title = SubString("Title"), xlabel = "x", ylabel = "y", x_tick0 = 0, y_tick0 = 2)
			@test _rs_sd(titled.fields[:title]) == Dict(:text => "Title")
			@test _rs_sd(_rs_sd(titled.fields[:xaxis])[:title]) == Dict(:text => "x")
			@test _rs_sd(_rs_sd(titled.fields[:yaxis])[:title]) == Dict(:text => "y")
			@test _rs_sd(titled.fields[:yaxis])[:tick0] == 2

			fig = plot_scatter(1:3, [1, 4, 9])
			for key in (:font, :colorway)
				@test !haskey(fig.layout.fields, key)
			end
			@test fig.layout.fields[:template] == _RS_PB.templates[:plotly_white]
			for key in (:xaxis, :yaxis), (k, v) in legacy_axis
				@test _rs_get(fig, key)[k] == v
			end
			@test _rs_get(fig, :margin) == Dict(:l => 50, :r => 50, :t => 60, :b => 50)
			named = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; legend = ["a", "b"])
			legend = _rs_get(named, :legend)
			@test (legend[:bgcolor], legend[:bordercolor], legend[:borderwidth]) ==
				  (_RS_LIGHT_LEGEND.bgcolor, _RS_LIGHT_LEGEND.bordercolor, 1.0)

			# `_apply_default_template!` is idempotent under :default.
			before = _rs_json(named)
			_RS._apply_default_template!(named)
			@test _rs_json(named) == before
		end

		@testset "_apply_default_cartesian_axes!" begin
			bare = Plot(GenericTrace[], Layout())
			_RS._apply_default_cartesian_axes!(bare)
			@test !haskey(bare.layout.fields, :xaxis) && !haskey(bare.layout.fields, :yaxis)
			two = Plot(GenericTrace[], Layout(xaxis = attr(title = attr(text = "keep")), yaxis2 = attr(side = "right")))
			_RS._apply_default_cartesian_axes!(two; template = _RS_PB.templates[:plotly_dark])
			@test _rs_get(two, :xaxis)[:linecolor] == _RS_DARK_INK
			@test _rs_sd(_rs_get(two, :xaxis)[:title])[:text] == "keep"
			@test _rs_get(two, :yaxis2)[:tickcolor] == _RS_DARK_INK
			@test _rs_get(two, :yaxis2)[:side] == "right"
			open_style = PlotStyle(; spines = :open, ticks = :inside, grid = false)
			_RS._apply_default_cartesian_axes!(two; style = open_style)
			@test _rs_get(two, :xaxis)[:mirror] === false
			@test _rs_get(two, :yaxis2)[:ticks] == "inside"
			@test _rs_get(two, :xaxis)[:showgrid] === false
			@test _rs_get(two, :xaxis)[:linecolor] == "#000000"
		end

		@testset "C37 active style wired into new figures" begin
			_rs_with_defaults(; style = :publication) do
				fig = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; legend = ["a", "b"], title = "T", xlabel = "x", ylabel = "y")
				fields = fig.layout.fields
				@test _rs_sd(fields[:font]) == Dict(:family => "Times New Roman, Times, Liberation Serif, serif", :size => 14, :color => "#000000")
				@test fields[:colorway] == _RS_OKABE_ITO
				margin = _rs_sd(fields[:margin])
				@test (margin[:l], margin[:r], margin[:b]) == (10, 10, 10)
				title = _rs_sd(fields[:title])
				@test title[:text] == "T"
				@test title[:automargin] === true
				@test _rs_sd(title[:font])[:size] == 16
				xaxis = _rs_get(fig, :xaxis)
				@test _rs_sd(xaxis[:title])[:text] == "x"
				@test _rs_sd(_rs_sd(xaxis[:title])[:font])[:size] == 14
				@test _rs_sd(xaxis[:tickfont])[:size] == 12
				@test xaxis[:linecolor] == "#000000" && xaxis[:mirror] === true
				legend = _rs_get(fig, :legend)
				@test (legend[:bgcolor], legend[:bordercolor], legend[:borderwidth]) == ("rgba(0,0,0,0)", "rgba(0,0,0,0)", 0.0)
				@test _rs_sd(legend[:font])[:size] == 12

				# No top margin is reserved for an empty title.
				untitled = plot_scatter(1:3, 1:3)
				@test _rs_get(untitled, :margin)[:t] == 10
				@test !haskey(_rs_get(untitled, :title), :text)

				# Non-Cartesian charts get the style too; an explicit fontsize wins
				# over the style's base size and keeps its family.
				pie = plot_pie([1, 2, 3]; labels = ["a", "b", "c"], title = "P", fontsize = 11)
				font = _rs_get(pie, :font)
				@test font[:size] == 11
				@test font[:family] == "Times New Roman, Times, Liberation Serif, serif"
				@test _rs_get(pie, :title)[:text] == "P"
				@test pie.layout.fields[:colorway] == _RS_OKABE_ITO

				# Re-templating a :publication figure: the style's black text and
				# the frame follow the dark template; the frameless legend stays.
				set_template!(fig, :plotly_dark)
				@test _rs_sd(fig.layout.fields[:font])[:color] == _RS_DARK_INK
				@test _rs_get(fig, :xaxis)[:linecolor] == _RS_DARK_INK
				@test _rs_get(fig, :legend)[:bgcolor] == "rgba(0,0,0,0)"
				@test fig.layout.fields[:colorway] == _RS_OKABE_ITO
			end

			# A style template, spines, ticks and grid.
			with_style(; template = :plotly_dark, spines = :open, ticks = :inside, grid = false) do
				fig = plot_scatter(1:3, 1:3; legend = "d")
				@test fig.layout.fields[:template] == _RS_PB.templates[:plotly_dark]
				xaxis = _rs_get(fig, :xaxis)
				@test xaxis[:linecolor] == _RS_DARK_INK
				@test xaxis[:mirror] === false
				@test xaxis[:ticks] == "inside"
				@test xaxis[:showgrid] === false
				@test _rs_get(fig, :legend)[:bgcolor] == _RS_DARK_LEGEND.bgcolor
			end
			@test plot_scatter(1:3, 1:3).layout.fields[:template] == _RS_PB.templates[:plotly_white]

			# A custom style template that sets ticks/mirror wins over the style.
			ticks_template = _RS_PB.Template(layout = _RS_PB.Layout(xaxis = attr(ticks = "inside", mirror = "allticks")))
			with_style(PlotStyle(; template = ticks_template)) do
				xaxis = _rs_get(plot_scatter(1:3, 1:3), :xaxis)
				@test !haskey(xaxis, :ticks) && !haskey(xaxis, :mirror)
				@test xaxis[:showline] === true
				yaxis = _rs_get(plot_scatter(1:3, 1:3), :yaxis)
				@test yaxis[:ticks] == "outside" && yaxis[:mirror] === true
			end

			# Subplots get the style on every axis.
			with_style(:publication) do
				sf = subplots(1, 2; sync = false, subplot_titles = ["a" "b"])
				@test _rs_sd(sf.plot.layout.fields[:font])[:family] == "Times New Roman, Times, Liberation Serif, serif"
				@test _rs_get(sf, :xaxis2)[:linecolor] == "#000000"
				@test _rs_get(sf, :margin)[:t] > 10
			end
		end

		@testset ":bw cycle colour follows the template" begin
			with_style(; cycle = :bw) do
				fig = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]])
				@test fig.layout.fields[:colorway] == ["#000000"]
				@test uppercase(_RS._default_trace_color(fig, 2)) == "#000000"
				set_template!(fig, :plotly_dark)
				@test fig.layout.fields[:colorway] == [_RS_DARK_INK]
				@test uppercase(_RS._default_trace_color(fig, 2)) == uppercase(_RS_DARK_INK)
				set_template!(fig, :plotly_white)
				@test fig.layout.fields[:colorway] == ["#000000"]
			end
			with_style(; cycle = :bw, template = :plotly_dark) do
				@test plot_scatter(1:3, 1:3).layout.fields[:colorway] == [_RS_DARK_INK]
			end
			# A user colorway is never touched.
			fig = plot_scatter(1:3, 1:3)
			relayout!(fig, colorway = ["red", "blue"])
			set_template!(fig, :plotly_dark)
			@test fig.layout.fields[:colorway] == ["red", "blue"]
		end

		@testset "_apply_style_trace_defaults!" begin
			style = PlotStyle(; cycle = :dash_marker, linewidth = 2, marker_size = 6)
			# K6: traces built without any `line`/`marker` container (the 2.0
			# scatter family writes none when the caller sets nothing) and with
			# an existing container that must be replaced, not mutated.
			shared_line = _RS_PB.attr(color = "red")
			fig = Plot([
				scatter(x = 1:3, y = [1, 2, 3], mode = "lines"),
				scatter(x = 1:3, y = [2, 3, 4], mode = "lines", line = shared_line),
				scatter(x = 1:3, y = [3, 4, 5], mode = "lines", line = shared_line),
			], Layout())
			shared_json = _RS_PB.JSON.json(shared_line)
			@test _RS._apply_style_trace_defaults!(fig, 1:3; style = style) === nothing
			for (i, (dash, symbol)) in enumerate((("solid", "circle"), ("dash", "square"), ("dot", "diamond")))
				line = _rs_sd(fig.data[i].fields[:line])
				marker = _rs_sd(fig.data[i].fields[:marker])
				@test (line[:dash], line[:width]) == (dash, 2)
				@test (marker[:symbol], marker[:size]) == (symbol, 6)
				@test fig.data[i].fields[:mode] == "lines+markers"
			end
			# Existing entries are kept; the shared container was replaced, not mutated.
			@test _rs_sd(fig.data[2].fields[:line])[:color] == "red"
			@test _RS_PB.JSON.json(shared_line) == shared_json
			@test fig.data[2].fields[:line] !== fig.data[3].fields[:line]
			# Applying again changes nothing (idempotent), also with repeated positions.
			again = _rs_json(fig)
			_RS._apply_style_trace_defaults!(fig, 1:3; style = style)
			@test _rs_json(fig) == again
			_RS._apply_style_trace_defaults!(fig, [3, 3, 1]; style = style)
			@test _rs_json(fig) == again

			# Values the caller set are kept; `explicit` protects sentinels.
			set = Plot([
				scatter(x = 1:3, y = 1:3, mode = "lines", line = _RS_PB.attr(dash = "dot", width = 4),
					marker = _RS_PB.attr(symbol = "x", size = [9, 8, 7])),
				scatter(x = 1:3, y = 1:3, mode = "lines", line = _RS_PB.attr(dash = "", width = 0),
					marker = _RS_PB.attr(size = 0)),
			], Layout())
			_RS._apply_style_trace_defaults!(set, [1, 2]; style = style, explicit = (:mode,))
			@test _rs_sd(set.data[1].fields[:line]) == Dict{Symbol, Any}(:dash => "dot", :width => 4)
			@test _rs_sd(set.data[1].fields[:marker]) == Dict{Symbol, Any}(:symbol => "x", :size => [9, 8, 7])
			# "" is the unset sentinel; 0 is an explicit value.
			@test _rs_sd(set.data[2].fields[:line]) == Dict{Symbol, Any}(:dash => "dash", :width => 0)
			@test _rs_sd(set.data[2].fields[:marker]) == Dict{Symbol, Any}(:symbol => "square", :size => 0)
			@test all(t -> t.fields[:mode] == "lines", set.data)
			kept = Plot([scatter(x = 1:3, y = 1:3, mode = "lines", line = _RS_PB.attr(dash = ""))], Layout())
			_RS._apply_style_trace_defaults!(kept, 1; style = style, explicit = [:dash, :linewidth])
			@test _rs_sd(kept.data[1].fields[:line]) == Dict{Symbol, Any}(:dash => "")
			@test _rs_sd(kept.data[1].fields[:marker])[:symbol] == "circle"
			@test kept.data[1].fields[:mode] == "lines+markers"
			# A single Symbol is accepted for `explicit`.
			single = Plot([scatter(x = 1:2, y = 1:2, mode = "lines")], Layout())
			_RS._apply_style_trace_defaults!(single, 1; style = style, explicit = :mode)
			@test single.data[1].fields[:mode] == "lines"
			# A symbol the caller chose is not forced visible: `mode` is the caller's too.
			chosen = Plot([scatter(x = 1:2, y = 1:2, mode = "lines", marker = _RS_PB.attr(symbol = "star"))], Layout())
			_RS._apply_style_trace_defaults!(chosen, 1; style = PlotStyle(; cycle = :marker))
			@test chosen.data[1].fields[:mode] == "lines"
			@test _rs_sd(chosen.data[1].fields[:marker]) == Dict{Symbol, Any}(:symbol => "star")
			# A Symbol mode gets the markers flag like a string mode.
			symmode = Plot([scatter(x = 1:2, y = 1:2, mode = :lines)], Layout())
			_RS._apply_style_trace_defaults!(symmode, 1; style = PlotStyle(; cycle = :marker))
			@test symmode.data[1].fields[:mode] == "lines+markers"

			# The cycle counts line-style traces only and continues on append.
			mixed = Plot([heatmap(z = [1 2; 3 4]), scatter(x = 1:2, y = [1, 2]), scatter(x = 1:2, y = [2, 1]), bar(x = ["a", "b"], y = [1, 2])], Layout())
			bar_json = _RS_PB.JSON.json(mixed.data[4])
			_RS._apply_style_trace_defaults!(mixed, 1:4; style = PlotStyle(; cycle = :dash))
			@test _rs_sd(mixed.data[2].fields[:line])[:dash] == "solid"
			@test _rs_sd(mixed.data[3].fields[:line])[:dash] == "dash"
			@test !haskey(mixed.data[1].fields, :line)
			@test _RS_PB.JSON.json(mixed.data[4]) == bar_json
			push!(mixed.data, scatter(x = 1:2, y = [0, 0]))
			_RS._apply_style_trace_defaults!(mixed, 5; style = PlotStyle(; cycle = :dash))
			@test _rs_sd(mixed.data[5].fields[:line])[:dash] == "dot"

			# scatter3d uses its own symbol set.
			cloud = Plot([scatter3d(x = [1, 2], y = [1, 2], z = [1, 2], mode = "lines") for _ in 1:9], Layout())
			_RS._apply_style_trace_defaults!(cloud, 1:9; style = PlotStyle(; cycle = :marker))
			@test [_rs_sd(t.fields[:marker])[:symbol] for t in cloud.data] ==
				  ["circle", "square", "diamond", "x", "cross", "circle-open", "square-open", "diamond-open", "circle"]
			@test all(t -> t.fields[:mode] == "lines+markers", cloud.data)

			# Traces that are not GenericTraces are neither styled nor counted.
			opaque = Plot(_RS_PB.AbstractTrace[_RSOpaqueTrace(), scatter(x = 1:2, y = 1:2)], Layout())
			_RS._apply_style_trace_defaults!(opaque, 1:2; style = style)
			@test _rs_sd(opaque.data[2].fields[:line])[:dash] == "solid"
			@test _RS._with_style_trace_offset(() -> _RS._STYLE_TRACE_OFFSET[], opaque) == 1

			# :default touches nothing; bad arguments throw before any write.
			plain = Plot([scatter(x = 1:3, y = [1, 2, 3], mode = "lines"), scatter(x = 1:3, y = [3, 2, 1], mode = "lines")], Layout())
			before = _rs_json(plain)
			_RS._apply_style_trace_defaults!(plain, 1:2)
			@test _rs_json(plain) == before
			_RS._apply_style_trace_defaults!(plain, Int[]; style = style)
			@test _rs_json(plain) == before
			for bad in ([1, 3], 0, true, [1.0], Any[1, true])
				err = try
					_RS._apply_style_trace_defaults!(plain, bad; style = style)
					nothing
				catch caught
					caught
				end
				@test err isa ArgumentError
				@test occursin("_apply_style_trace_defaults!: trace index", sprint(showerror, err))
			end
			@test_throws ArgumentError _RS._apply_style_trace_defaults!(plain, 1; style = style, explicit = (:color,))
			@test_throws ArgumentError _RS._apply_style_trace_defaults!(plain, 1; style = style, explicit = :color)
			@test _rs_json(plain) == before
			# A malformed container aborts the whole call before any write.
			broken = Plot([scatter(x = 1:2, y = 1:2), scatter(x = 1:2, y = 1:2, line = "solid")], Layout())
			broken_json = _rs_json(broken)
			err = try
				_RS._apply_style_trace_defaults!(broken, 1:2; style = style)
				nothing
			catch caught
				caught
			end
			@test err isa ArgumentError
			@test occursin("data[2]: `line` is a String", sprint(showerror, err))
			@test _rs_json(broken) == broken_json
			# The active style is the default.
			with_style(; linewidth = 3) do
				_RS._apply_style_trace_defaults!(plain, 2)
			end
			@test _rs_sd(plain.data[2].fields[:line]) == Dict{Symbol, Any}(:width => 3)
			@test !haskey(plain.data[1].fields, :line)
		end

		@testset "X10: _apply_style_trace_defaults! is safe on every trace type" begin
			style = PlotStyle(; cycle = :dash_marker, linewidth = 2.5, marker_size = 7)
			# plotly.js 2.35 trace types without the scatter-style line.dash and
			# marker.symbol: never written.
			others = [
				bar(x = [1, 2], y = [1, 2]), histogram(x = [1, 2, 2]), box(y = [1, 2, 3]),
				violin(y = [1, 2, 3]), heatmap(z = [1 2; 3 4]), contour(z = [1 2; 3 4]),
				histogram2d(x = [1, 2], y = [1, 2]), histogram2dcontour(x = [1, 2], y = [1, 2]),
				surface(z = [1 2; 3 4]), mesh3d(x = [0, 1, 0], y = [0, 0, 1], z = [0, 0, 0]),
				cone(x = [0], y = [0], z = [0], u = [1], v = [0], w = [0]),
				streamtube(x = [0, 1], y = [0, 1], z = [0, 1], u = [1, 1], v = [0, 0], w = [0, 0]),
				isosurface(x = [0, 1], y = [0, 1], z = [0, 1], value = [0, 1]),
				volume(x = [0, 1], y = [0, 1], z = [0, 1], value = [0, 1]),
				pie(values = [1, 2]), funnel(x = [1, 2]), funnelarea(values = [1, 2]),
				waterfall(y = [1, -1]), candlestick(open = [1], high = [2], low = [0], close = [1.5]),
				ohlc(open = [1], high = [2], low = [0], close = [1.5]), sunburst(labels = ["a"], parents = [""]),
				treemap(labels = ["a"], parents = [""]), sankey(node = _RS_PB.attr(label = ["a", "b"])),
				parcoords(dimensions = [_RS_PB.attr(values = [1, 2])]), splom(dimensions = [_RS_PB.attr(values = [1, 2])]),
				scattermapbox(lat = [0], lon = [0], mode = "lines"), choropleth(locations = ["FRA"], z = [1]),
				densitymapbox(lat = [0], lon = [0], z = [1]), indicator(value = 1), table(cells = _RS_PB.attr(values = [[1]])),
				carpet(a = [1, 2], b = [1, 2], y = [1, 2]),
				_RS_PB.GenericTrace("scattermap"; lat = [0], lon = [0], mode = "lines"),
			]
			ofig = Plot(others, Layout())
			ojson = [_RS_PB.JSON.json(t) for t in ofig.data]
			_RS._apply_style_trace_defaults!(ofig, 1:length(others); style = style)
			@test [_RS_PB.JSON.json(t) for t in ofig.data] == ojson

			# Line-style types: every attribute written exists for the type and
			# takes a value from the type's allowed set (plotly.js 2.35 schema;
			# scatter3d, scattergl and scatterpolargl accept these four dashes too).
			lines = [
				scatter(x = [1, 2], y = [1, 2], mode = "lines"),
				scattergl(x = [1, 2], y = [1, 2], mode = "lines"),
				scatterpolar(r = [1, 2], theta = [0, 90], mode = "lines"),
				scatterpolargl(r = [1, 2], theta = [0, 90], mode = "lines"),
				scatter3d(x = [1, 2], y = [1, 2], z = [1, 2], mode = "lines"),
				scatterternary(a = [1, 2], b = [1, 2], c = [1, 2], mode = "lines"),
				_RS_PB.GenericTrace("scattersmith"; real = [1, 2], imag = [1, 2], mode = "lines"),
				scattercarpet(a = [1, 2], b = [1, 2], mode = "lines"),
				scattergeo(lat = [0, 1], lon = [0, 1], mode = "lines"),
			]
			lfig = Plot(lines, Layout())
			_RS._apply_style_trace_defaults!(lfig, 1:length(lines); style = style)
			dashes = ("solid", "dash", "dot", "dashdot")
			symbols2d = ("circle", "square", "diamond", "triangle-up", "x", "triangle-down", "cross", "star")
			symbols3d = ("circle", "square", "diamond", "x", "cross", "circle-open", "square-open", "diamond-open")
			for (rank, t) in enumerate(lfig.data)
				line = _rs_sd(t.fields[:line])
				marker = _rs_sd(t.fields[:marker])
				@test Set(keys(line)) == Set([:width, :dash])
				@test Set(keys(marker)) == Set([:size, :symbol])
				@test line[:width] == 2.5 && marker[:size] == 7
				@test line[:dash] == dashes[mod1(rank, 4)]
				is3d = t.fields[:type] == "scatter3d"
				@test marker[:symbol] == (is3d ? symbols3d : symbols2d)[mod1(rank, 8)]
				@test t.fields[:mode] == "lines+markers"
			end
			ljson = _rs_json(lfig)
			_RS._apply_style_trace_defaults!(lfig, 1:length(lines); style = style)
			@test _rs_json(lfig) == ljson

			# Explicit values on every line-style type are never overridden.
			mine = [
				_RS_PB.GenericTrace(type; mode = "lines", line = _RS_PB.attr(width = 0.5, dash = "longdash"),
					marker = _RS_PB.attr(size = [3, 4], symbol = "circle"))
				for type in ("scatter", "scattergl", "scatterpolar", "scatterpolargl", "scatter3d",
					"scatterternary", "scattersmith", "scattercarpet", "scattergeo")
			]
			mfig = Plot(mine, Layout())
			mjson = _rs_json(mfig)
			_RS._apply_style_trace_defaults!(mfig, 1:length(mine); style = style)
			@test _rs_json(mfig) == mjson

			# Works through SubplotFigure and SyncPlot targets (model only).
			sf = subplots(1, 2; sync = false)
			push!(sf.plot.data, scatter(x = 1:2, y = 1:2, xaxis = "x2", yaxis = "y2"))
			_RS._apply_style_trace_defaults!(sf, length(sf.plot.data); style = style)
			@test _rs_sd(sf.plot.data[end].fields[:line])[:dash] == "solid"
			sp, scripts = _rs_syncplot(Plot([scatter(x = 1:2, y = 1:2)], Layout()))
			try
				_RS._apply_style_trace_defaults!(sp, 1; style = style)
				@test _rs_sd(sp.plot.data[1].fields[:line])[:width] == 2.5
				@test isempty(scripts)
			finally
				close(sp)
			end
		end

		@testset "_apply_basic_plot_options! and _maybe_show" begin
			fig = Plot(GenericTrace[pie(values = [1, 2], labels = ["a", "b"])], Layout())
			_RS._apply_basic_plot_options!(fig; title = SubString("Pie"), width = 400.0, height = 300, fontsize = 12.5)
			@test _rs_get(fig, :title) == Dict(:text => "Pie")
			@test (fig.layout.fields[:width], fig.layout.fields[:height]) == (400.0, 300)
			@test _rs_get(fig, :font)[:size] == 12.5
			@test fig.layout.fields[:template] == _RS_PB.templates[:plotly_white]
			@test _rs_get(fig, :legend)[:bgcolor] == _RS_LIGHT_LEGEND.bgcolor

			fresh = Plot(GenericTrace[pie(values = [1, 2])], Layout())
			before = _rs_json(fresh)
			for bad in ((; width = -1), (; height = NaN), (; fontsize = Inf), (; width = true))
				err = try
					_RS._apply_basic_plot_options!(fresh; title = "t", who = "plot_pie", bad...)
					nothing
				catch e
					e
				end
				@test err isa ArgumentError
				@test startswith(sprint(showerror, err), "ArgumentError: plot_pie:")
				@test _rs_json(fresh) == before
			end

			# The append path keeps the figure's template and gives a legend it
			# creates the box matching that template.
			dark = Plot([scatter(x = [1, 2], y = [1, 2], name = "n")], Layout(template = _RS_PB.templates[:plotly_dark]))
			_RS._apply_basic_plot_options!(dark; apply_template = false, fontsize = 10)
			@test dark.layout.fields[:template] == _RS_PB.templates[:plotly_dark]
			@test _rs_get(dark, :legend)[:bgcolor] == _RS_DARK_LEGEND.bgcolor
			@test _rs_get(dark, :font)[:size] == 10
			@test !haskey(dark.layout.fields, :xaxis)

			shown = plot_scatter(1:3, 1:3)
			@test _RS._maybe_show(shown, false, 0, 0, "") === shown
			@test _RS._maybe_show(shown, false, 640.0, 480, SubString("window")) === shown
		end

		@testset "template errors and warnings name the function" begin
			fig = plot_scatter(1:3, 1:3)
			before = _rs_json(fig)
			for (call, who) in (
				(() -> set_template!(fig, 3), "set_template!:"),
				(() -> set_template!(fig, nothing), "set_template!:"),
				(() -> set_default_template!(3.5), "set_default_template!:"),
			)
				err = try
					call()
					nothing
				catch e
					e
				end
				@test err isa ArgumentError
				@test startswith(sprint(showerror, err), "ArgumentError: $(who)")
			end
			@test _rs_json(fig) == before
			@test get_default_template() === :plotly_white
			@test_logs (:warn, r"^set_template!: unrecognized template \"nope\"") set_template!(fig, "nope")
			@test fig.layout.fields[:template] == _RS_PB.templates[:plotly_white]
			_rs_with_defaults() do
				@test (@test_logs (:warn, r"^set_default_template!: unrecognized") set_default_template!(:nope)) === :plotly_white
			end
		end

		@testset "an explicit grid keyword wins over the style grid" begin
			# The constructor pipeline: layout, then the options (grid first), then
			# the template.
			function built(grid)
				fig = Plot(GenericTrace[scatter(x = [1, 2], y = [1, 2])], _RS._default_cartesian_layout())
				_RS._apply_cartesian_plot_options!(fig; grid = grid, who = "probe")
				return fig
			end
			with_style(; grid = false) do
				hidden = plot_scatter(1:3, 1:3)
				@test _rs_get(hidden, :xaxis)[:showgrid] === false
				@test _rs_get(hidden, :yaxis)[:showgrid] === false
				@test _rs_get(built(true), :xaxis)[:showgrid] === false
				x_only = built(:x)
				@test _rs_get(x_only, :xaxis)[:showgrid] === true
				@test _rs_get(x_only, :yaxis)[:showgrid] === false
				both = built(:both)
				@test _rs_get(both, :xaxis)[:showgrid] === true
				@test _rs_get(both, :yaxis)[:showgrid] === true
				# Axes without a grid setting of their own get the style's.
				sf = subplots(1, 2; sync = false)
				for key in (:xaxis, :xaxis2, :yaxis, :yaxis2)
					@test _rs_get(sf, key)[:showgrid] === false
				end
			end
			# (An empty `attr()` is dropped by `Layout`, so each axis gets a key.)
			bare = Plot(GenericTrace[], Layout(xaxis = attr(showgrid = true), xaxis2 = attr(side = "top"), yaxis = attr(title_text = "y")))
			_RS._apply_default_cartesian_axes!(bare; style = PlotStyle(; grid = false))
			@test _rs_get(bare, :xaxis)[:showgrid] === true
			@test _rs_get(bare, :xaxis2)[:showgrid] === false
			@test _rs_get(bare, :yaxis)[:showgrid] === false
			# Under the default style no grid key is written at all.
			plain = plot_scatter(1:3, 1:3)
			@test !haskey(_rs_get(plain, :xaxis), :showgrid)
		end

		@testset "figure-derived legend and axis defaults" begin
			dark = plot_scatter(1:3, 1:3)
			set_template!(dark, :plotly_dark)
			@test _RS._figure_legend_defaults(dark) ==
				  (bgcolor = _RS_DARK_LEGEND.bgcolor, bordercolor = _RS_DARK_LEGEND.bordercolor, borderwidth = 1.0)
			@test _RS._figure_legend_defaults(dark; style = PlotStyle(; legend_frame = false)).borderwidth == 0.0
			@test _RS._figure_axis_defaults(dark; axis = :y)[:linecolor] == _RS_DARK_INK
			light = plot_scatter(1:3, 1:3)
			@test _RS._figure_legend_defaults(light) ==
				  (bgcolor = _RS_LIGHT_LEGEND.bgcolor, bordercolor = _RS_LIGHT_LEGEND.bordercolor, borderwidth = 1.0)
			@test _RS._figure_axis_defaults(light)[:tickcolor] == "#000000"
			# A template stored by name is resolved; a layout without one falls
			# back to the style's template.
			named = Plot(GenericTrace[], Layout())
			named.layout.fields[:template] = " plotly_dark "
			@test _RS._figure_style_template(named) === _RS_PB.templates[:plotly_dark]
			delete!(named.layout.fields, :template)
			@test _RS._figure_template(named) === nothing
			@test _RS._figure_style_template(named) === _RS_PB.templates[:plotly_white]
			with_style(; template = :ggplot2) do
				@test _RS._figure_style_template(named) === _RS_PB.templates[:ggplot2]
			end
			# Legend font for legends created after construction.
			@test _RS._style_legend_font() == Dict{Symbol, Any}()
			@test _RS._style_legend_font(PlotStyle(; legend_fontsize = 9)) == Dict{Symbol, Any}(:size => 9.0)
			with_style(:publication) do
				@test _RS._style_legend_font() == Dict{Symbol, Any}(:size => 12.0)
			end
		end

		@testset "X11 a twin y axis takes the figure template's ink" begin
			# Fails before X11: the twin got the black 1.x spine on any template.
			dark = Plot(GenericTrace[scatter(x = 1:3, y = 1:3)], Layout(template = _RS_PB.templates[:plotly_dark]))
			key = _RS._ensure_twin_y!(dark)
			twin = _rs_sd(dark.layout.fields[key])
			@test key == :yaxis2
			@test (twin[:linecolor], twin[:tickcolor]) == (_RS_DARK_INK, _RS_DARK_INK)
			@test (twin[:overlaying], twin[:side], twin[:anchor], twin[:showgrid]) == ("y", "right", "x", false)
			@test !haskey(twin, :mirror)
			@test _RS._ensure_twin_y!(dark) == :yaxis2   # idempotent
			# Light figures keep the exact 1.x twin.
			light = plot_scatter(1:3, 1:3)
			_RS._ensure_twin_y!(light)
			@test _rs_sd(light.layout.fields[:yaxis2]) == Dict{Symbol, Any}(
				:overlaying => "y", :side => "right", :anchor => "x", :showgrid => false,
				:zeroline => false, :showline => true, :ticks => "outside", :automargin => true,
				:linecolor => "#000000", :linewidth => 1.0, :tickcolor => "#000000",
			)
			# A colour set on the primary axis still wins (copied after the defaults).
			custom = plot_scatter(1:3, 1:3)
			custom.layout.fields[:yaxis] = merge(_rs_sd(custom.layout.fields[:yaxis]), Dict{Symbol, Any}(:linecolor => "#123456"))
			_RS._ensure_twin_y!(custom)
			@test _rs_sd(custom.layout.fields[:yaxis2])[:linecolor] == "#123456"
		end

		@testset "X12 the template colorscale follows the active style" begin
			ggplot = _RS._template_colorscale(_RS_PB.templates[:ggplot2])
			white = _RS._template_colorscale(_RS_PB.templates[:plotly_white])
			@test ggplot != white
			@test _RS._template_colorscale() == white
			# Fails before X12: `nothing` meant get_default_template() only.
			with_style(; template = :ggplot2) do
				@test _RS._template_colorscale() == ggplot
				@test _RS._template_colorscale(nothing; trace_type = "contour") ==
					  _RS._template_colorscale(_RS_PB.templates[:ggplot2]; trace_type = "contour")
			end
			_rs_with_defaults(; template = :ggplot2) do
				@test _RS._template_colorscale() == ggplot
			end
		end

		@testset "X6 #266 #268 set_template! re-derives per-cell legend boxes" begin
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, 1:3, 1:3; legend = "a", row = 1, col = 1)
			plot_scatter!(sf, 1:3, 3:-1:1; legend = "b", row = 1, col = 2)
			subplot_legends!(sf)
			legends(f) = sort!([k for k in keys(f.plot.layout.fields) if startswith(String(k), "legend")])
			@test legends(sf) == [:legend, :legend2]
			# A per-cell box with a user colour keeps it.
			sf.plot.layout.fields[:legend2] = merge(_rs_sd(sf.plot.layout.fields[:legend2]), Dict{Symbol, Any}(:bordercolor => "#00FF00"))
			@test set_template!(sf, :plotly_dark) === sf
			for key in (:legend, :legend2)
				@test _rs_sd(sf.plot.layout.fields[key])[:bgcolor] == _RS_DARK_LEGEND.bgcolor
			end
			@test _rs_sd(sf.plot.layout.fields[:legend])[:bordercolor] == _RS_DARK_LEGEND.bordercolor
			@test _rs_sd(sf.plot.layout.fields[:legend2])[:bordercolor] == "#00FF00"
			@test (sf.legend_bgcolor, sf.legend_bordercolor) == (_RS_DARK_LEGEND.bgcolor, _RS_DARK_LEGEND.bordercolor)
			# Every cell's axes are re-inked too.
			for key in (:xaxis, :yaxis, :xaxis2, :yaxis2)
				@test _rs_sd(sf.plot.layout.fields[key])[:linecolor] == _RS_DARK_INK
			end
			# And back.
			set_template!(sf, :plotly_white)
			@test _rs_sd(sf.plot.layout.fields[:legend2])[:bgcolor] == _RS_LIGHT_LEGEND.bgcolor
			@test _rs_sd(sf.plot.layout.fields[:yaxis2])[:linecolor] == "#000000"
			# set_legend!(sf; showlegend) (X17) returns the figure and validates first.
			@test set_legend!(sf; showlegend = false) === sf
			@test sf.plot.layout.fields[:showlegend] === false
			before = _rs_json(sf)
			@test_throws ArgumentError set_legend!(sf; showlegend = true, ncols = -1)
			@test_throws ArgumentError set_template!(sf, 3)
			@test _rs_json(sf) == before
		end

		@testset "style cycle: offset scope and mode flags" begin
			style = PlotStyle(; cycle = :dash_marker)
			outer = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]])
			tmp = plot_scatter(1:3, [[1, 1, 1], [2, 2, 2]])
			_RS._with_style_trace_offset(outer) do
				_RS._apply_style_trace_defaults!(tmp, 1:2; style = style)
			end
			@test [_rs_sd(t.fields[:line])[:dash] for t in tmp.data] == ["dot", "dashdot"]
			@test [_rs_sd(t.fields[:marker])[:symbol] for t in tmp.data] == ["diamond", "triangle-up"]
			# The offset is scoped: outside the block positions restart at 1.
			@test _RS._STYLE_TRACE_OFFSET[] == 0
			again = plot_scatter(1:3, [1, 1, 1])
			_RS._apply_style_trace_defaults!(again, 1; style = style)
			@test _rs_sd(again.data[1].fields[:line])[:dash] == "solid"
			# The value of `f` is returned, and the offset is reset on an exception.
			@test _RS._with_style_trace_offset(() -> 42, outer) == 42
			@test_throws ErrorException _RS._with_style_trace_offset(() -> error("boom"), outer)
			@test _RS._STYLE_TRACE_OFFSET[] == 0

			modes = Plot([scatter(x = [1, 2], y = [1, 2], mode = m) for m in ("lines+text", "markers", "lines+markers", "text")], Layout())
			unset = Plot([scatter(x = [1, 2], y = [1, 2])], Layout())
			_RS._apply_style_trace_defaults!(modes, 1:4; style = PlotStyle(; cycle = :marker))
			_RS._apply_style_trace_defaults!(unset, 1; style = PlotStyle(; cycle = :marker))
			@test [t.fields[:mode] for t in modes.data] == ["lines+markers+text", "markers", "lines+markers", "text"]
			@test !haskey(unset.data[1].fields, :mode)
			@test _rs_sd(unset.data[1].fields[:marker])[:symbol] == "circle"
		end

		@testset "Y22 / D14: contours, error bars and colorbars take the style" begin
			style = PlotStyle(; linewidth = 2.5, errorbar_width = 1.5, tick_fontsize = 9, label_fontsize = 11,
				axis_linewidth = 0.75, tick_length = 4, ticks = :inside)
			fig = Plot([
				contour(z = [1 2; 3 4], contours = _RS_PB.attr(coloring = "lines")),
				contour(z = [1 2; 3 4]),                                         # filled: plotly's thin boundaries
				histogram2dcontour(x = [1, 2], y = [1, 2], contours = _RS_PB.attr(coloring = :none)),
				contour(z = [1 2; 3 4], contours = _RS_PB.attr(coloring = "lines"), line = _RS_PB.attr(width = 0.3)),
				scatter(x = 1:3, y = 1:3, error_y = _RS_PB.attr(array = [0.1, 0.2, 0.1])),
				bar(x = ["a", "b"], y = [1, 2], error_y = _RS_PB.attr(array = [0.1, 0.2]), error_x = _RS_PB.attr(visible = false)),
				scatter3d(x = [1, 2], y = [1, 2], z = [1, 2], error_z = _RS_PB.attr(array = [0.1, 0.1], thickness = 4)),
				heatmap(z = [1 2; 3 4], colorbar = _RS_PB.attr(title = "c", ticks = "outside")),
				heatmap(z = [1 2; 3 4], coloraxis = "coloraxis"),
				scatter(x = 1:2, y = 1:2, mode = "markers", marker = _RS_PB.attr(color = [1, 2], showscale = true)),
			], Layout())
			ids = 1:length(fig.data)
			_RS._apply_style_trace_defaults!(fig, ids; style = style)
			line(i) = _rs_sd(get(fig.data[i].fields, :line, nothing))
			@test line(1)[:width] == 2.5
			@test !haskey(fig.data[2].fields, :line)
			@test line(3)[:width] == 2.5
			@test line(4)[:width] == 0.3
			@test _rs_sd(fig.data[5].fields[:error_y]) == Dict(:array => [0.1, 0.2, 0.1], :thickness => 1.5)
			@test _rs_sd(fig.data[6].fields[:error_y])[:thickness] == 1.5
			@test _rs_sd(fig.data[6].fields[:error_x]) == Dict(:visible => false)
			@test !haskey(fig.data[5].fields, :error_x)          # never created
			@test _rs_sd(fig.data[7].fields[:error_z])[:thickness] == 4
			cb = _rs_sd(fig.data[8].fields[:colorbar])
			@test _rs_sd(cb[:title]) == Dict(:text => "c", :font => Dict{Symbol, Any}(:size => 11))
			@test _rs_sd(cb[:tickfont]) == Dict(:size => 9)
			@test cb[:ticks] == "outside"                         # the caller's
			@test (cb[:outlinewidth], cb[:tickwidth], cb[:ticklen]) == (0.75, 0.75, 4)
			# No colour: colorbars live on traces, which set_template! cannot re-derive.
			@test !haskey(cb, :outlinecolor) && !haskey(cb, :tickcolor)
			@test !haskey(fig.data[9].fields, :colorbar)          # coloraxis-bound
			mcb = _rs_sd(_rs_sd(fig.data[10].fields[:marker])[:colorbar])
			@test _rs_sd(mcb[:tickfont]) == Dict(:size => 9) && mcb[:ticks] == "inside"
			@test _rs_sd(fig.data[10].fields[:marker])[:color] == [1, 2]
			# Idempotent.
			again = _rs_json(fig)
			_RS._apply_style_trace_defaults!(fig, ids; style = style)
			@test _rs_json(fig) == again
			# `explicit = :linewidth` protects a contour's automatic width.
			c = Plot([contour(z = [1 2; 3 4], contours = _RS_PB.attr(coloring = "lines"))], Layout())
			_RS._apply_style_trace_defaults!(c, 1; style = style, explicit = :linewidth)
			@test !haskey(c.data[1].fields, :line)
			# A style with only font sizes writes no colorbar line attributes.
			fonts_only = Plot([heatmap(z = [1 2; 3 4])], Layout())
			_RS._apply_style_trace_defaults!(fonts_only, 1; style = PlotStyle(; tick_fontsize = 9))
			@test _rs_sd(fonts_only.data[1].fields[:colorbar]) == Dict(:tickfont => Dict{Symbol, Any}(:size => 9))
			# A malformed error-bar or colorbar container aborts before any write.
			for bad in (scatter(x = 1:2, y = 1:2, error_y = "0.1"), heatmap(z = [1 2; 3 4], colorbar = 3))
				broken = Plot([scatter(x = 1:2, y = 1:2), bad], Layout())
				before = _rs_json(broken)
				@test_throws ArgumentError _RS._apply_style_trace_defaults!(broken, 1:2; style = style)
				@test _rs_json(broken) == before
			end
		end

		@testset "colorbar and 3-D/polar/ternary line weights at construction (D14)" begin
			_rs_with_defaults(; style = :ieee) do
				hm = plot_heatmap(1:3, 1:3, [1 2 3; 4 5 6; 7 8 9]; colorbar_title = "c")
				cb = _rs_sd(hm.data[1].fields[:colorbar])
				@test (cb[:outlinewidth], cb[:tickwidth], cb[:ticks]) == (1, 1, "inside")
				@test cb[:ticklen] ≈ 3.5 * 4 / 3
				surf = plot_surface([1.0 2; 3 4]; xlabel = "x")
				for axis in (:xaxis, :yaxis, :zaxis)
					a = _rs_sd(_rs_get(surf, :scene)[axis])
					@test (a[:linewidth], a[:tickwidth], a[:gridwidth]) == (1, 1, 1)
				end
				pol = plot_scatterpolar([0, 90, 180], [1, 2, 3])
				@test _rs_sd(_rs_get(pol, :polar)[:radialaxis])[:linewidth] == 1
				@test _rs_sd(_rs_get(pol, :polar)[:angularaxis])[:tickwidth] == 1
			end
			# Unsized/unweighted styles leave plotly's colorbar and scene look.
			_rs_with_defaults(; style = :publication) do
				hm = plot_heatmap(1:3, 1:3, [1 2 3; 4 5 6; 7 8 9])
				cb = _rs_sd(hm.data[1].fields[:colorbar])
				@test !any(haskey(cb, k) for k in (:outlinewidth, :ticks, :ticklen, :tickwidth))
				surf = plot_surface([1.0 2; 3 4])
				@test !haskey(_rs_sd(_rs_get(surf, :scene)[:xaxis]), :linewidth)
			end
		end

		@testset ":dash_symbol and :bw_dash_marker cycles on figures (D14)" begin
			_rs_with_defaults(; style = :ieee) do
				lines = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1], [2, 2, 2]])
				@test [_rs_sd(t.fields[:line])[:dash] for t in lines.data] == ["solid", "dash", "dot"]
				@test all(t -> t.fields[:mode] == "lines", lines.data)   # no markers added
				marked = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; mode = "lines+markers")
				@test [_rs_sd(t.fields[:marker])[:symbol] for t in marked.data] == ["circle", "square"]
			end
			with_style(; cycle = :bw_dash_marker, colorway = :tol_bright) do
				fig = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]])
				@test fig.layout.fields[:colorway] == ["#000000"]
				@test all(t -> t.fields[:mode] == "lines+markers", fig.data)
				@test [_rs_sd(t.fields[:marker])[:symbol] for t in fig.data] == ["circle", "square"]
				set_template!(fig, :plotly_dark)
				@test fig.layout.fields[:colorway] == [_RS_DARK_INK]
			end
		end

		@testset "the style reaches every text and line role (table-driven, D14)" begin
			# Each row: (label, figure key, path, expected value from the style).
			# The figures cover a Plot and a 2x2 SubplotFigure. Elements another
			# owner's code leaves unstyled are listed (with the call that would
			# fix them) in the v4/publication-style cross requests and are not
			# rows here: subplot titles from `subplots(...; subplot_titles)` (font
			# size 16), colorbars of traces added by `plot_heatmap!`-type
			# mutators, error bars of `plot_bar`, and the line width/colour of
			# `hline!`/`vline!`/`rectangle!`/`arrow!` (fixed 1 px black).
			px(pt) = pt * 4 / 3
			getpath(d, path) = begin
				for k in path
					d = d isa _RS_PB.PlotlyAttribute || d isa AbstractDict ? _rs_sd(d) : d
					if k isa Integer
						d = d isa AbstractVector && k <= length(d) ? d[k] : nothing
					else
						d = d isa AbstractDict ? get(d, k, nothing) : nothing
					end
					d === nothing && return nothing
				end
				d isa _RS_PB.PlotlyAttribute ? _rs_sd(d) : d
			end
			for name in (:publication, :ieee)
				st = _RS._STYLE_REGISTRY[name]
				num(x) = x == 0 ? nothing : _RS._style_number(x)
				axis_w = st.axis_linewidth > 0 ? num(st.axis_linewidth) : 1.0
				figs = _rs_with_defaults(; style = name) do
					plot = plot_scatter(1:5, [1.0, 2, 3, 4, 5]; error_y = fill(0.2, 5),
						legend = "a", xlabel = "x", ylabel = "y", title = "T", mode = "lines+markers")
					plot_scatter!(plot, 1:5, [5.0, 4, 3, 2, 1]; legend = "b")
					hm = plot_heatmap(1:3, 1:3, [1 2 3; 4 5 6; 7 8 9]; colorbar_title = "c", xlabel = "x")
					ct = plot_contour(1:5, 1:5, [i * j for i in 1:5, j in 1:5]; coloring = "lines")
					tri = plot_triplot([0.0, 1, 0, 1], [0.0, 0, 1, 1], [1 2 3; 2 4 3])
					surf = plot_surface([1.0 2; 3 4]; xlabel = "x", zlabel = "z")
					sf = subplots(2, 2; sync = false)
					plot_scatter!(sf, 1:5, [1.0, 2, 3, 4, 5]; error_y = fill(0.2, 5), legend = "s", row = 1, col = 1)
					plot_contour!(sf, 1:5, 1:5, [i * j for i in 1:5, j in 1:5]; coloring = "lines", row = 2, col = 1)
					plot_scatter!(sf, 1:5, [5.0, 4, 3, 2, 1]; row = 2, col = 2)
					xlabel!(sf, "xl"; row = 2, col = 2)
					(; plot, hm, ct, tri, surf, sf)
				end
				size_ok = st.width > 0 ? (num(st.width), num(st.width * 0.75)) : (nothing, nothing)
				rows = [
					# text roles
					("title", :plot, (:layout, :title, :font, :size), num(st.title_fontsize)),
					("axis title", :plot, (:layout, :xaxis, :title, :font, :size), num(st.label_fontsize)),
					("tick labels", :plot, (:layout, :yaxis, :tickfont, :size), num(st.tick_fontsize)),
					("legend", :plot, (:layout, :legend, :font, :size), num(st.legend_fontsize)),
					("font family", :plot, (:layout, :font, :family), st.font_family),
					("text ink", :plot, (:layout, :font, :color), "#000000"),
					("colorbar title", :hm, (:data, 1, :colorbar, :title, :font, :size), num(st.label_fontsize)),
					("colorbar ticks", :hm, (:data, 1, :colorbar, :tickfont, :size), num(st.tick_fontsize)),
					("3-D axis title", :surf, (:layout, :scene, :zaxis, :title, :font, :size), num(st.label_fontsize)),
					("3-D tick labels", :surf, (:layout, :scene, :xaxis, :tickfont, :size), num(st.tick_fontsize)),
					("2x2 cell tick labels", :sf, (:layout, :xaxis4, :tickfont, :size), num(st.tick_fontsize)),
					("2x2 cell axis title", :sf, (:layout, :xaxis4, :title, :font, :size), num(st.label_fontsize)),
					("2x2 legend", :sf, (:layout, :legend, :font, :size), num(st.legend_fontsize)),
					# line roles
					("spines", :plot, (:layout, :xaxis, :linewidth), axis_w),
					("spine ink", :plot, (:layout, :xaxis, :linecolor), "#000000"),
					("tick width", :plot, (:layout, :xaxis, :tickwidth), num(st.axis_linewidth)),
					("tick length", :plot, (:layout, :xaxis, :ticklen), num(st.tick_length)),
					("tick direction", :plot, (:layout, :xaxis, :ticks), st.ticks),
					("data line", :plot, (:data, 2, :line, :width), num(st.linewidth)),
					("error bars", :plot, (:data, 1, :error_y, :thickness), num(st.errorbar_width)),
					("colorbar outline", :hm, (:data, 1, :colorbar, :outlinewidth), num(st.axis_linewidth)),
					("contour lines", :ct, (:data, 1, :line, :width), num(st.linewidth)),
					("mesh edges", :tri, (:data, 1, :line, :width), st.linewidth > 0 ? num(st.linewidth) : 0.5),
					("3-D spines", :surf, (:layout, :scene, :xaxis, :linewidth), num(st.axis_linewidth)),
					("2x2 cell spines", :sf, (:layout, :xaxis3, :linewidth), axis_w),
					("2x2 cell tick length", :sf, (:layout, :yaxis2, :ticklen), num(st.tick_length)),
					("2x2 appended data line", :sf, (:data, 3, :line, :width), num(st.linewidth)),
					("2x2 error bars", :sf, (:data, 1, :error_y, :thickness), num(st.errorbar_width)),
					("2x2 contour lines", :sf, (:data, 2, :line, :width), num(st.linewidth)),
					# figure size
					("figure width", :plot, (:layout, :width), size_ok[1]),
					("figure height", :hm, (:layout, :height), size_ok[2]),
					("2x2 figure width", :sf, (:layout, :width), size_ok[1]),
				]
				for (label, key, path, expected) in rows
					p = _RS._plot_obj(getfield(figs, key))
					root = path[1] === :layout ? p.layout.fields : Any[t.fields for t in p.data]
					actual = getpath(root, path[2:end])
					ok = actual isa Real && expected isa Real ? actual ≈ expected : isequal(actual, expected)
					ok || @info "style reach" name label actual expected
					@test ok
				end
			end
		end
	finally
		_RS._DEFAULT_TEMPLATE[] = original_template
		set_default_style!(original_style)
	end
end
