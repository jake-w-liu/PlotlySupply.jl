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
const _RS_OKABE_ITO = ["#E69F00", "#56B4E9", "#009E73", "#F0E442", "#0072B2", "#D55E00", "#CC79A7", "#000000"]

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
			@test custom.legend_bgcolor == "pink"
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
				@test _rs_sd(fields[:font]) == Dict(:family => "STIXGeneral, Times New Roman, serif", :size => 14, :color => "#000000")
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
				@test font[:family] == "STIXGeneral, Times New Roman, serif"
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
				@test _rs_sd(sf.plot.layout.fields[:font])[:family] == "STIXGeneral, Times New Roman, serif"
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
			fig = plot_scatter(1:3, [[1, 2, 3], [2, 3, 4], [3, 4, 5]])
			old_line = fig.data[1].fields[:line]
			old_line_json = _RS_PB.JSON.json(old_line)
			@test _RS._apply_style_trace_defaults!(fig, 1:3; style = style) === nothing
			for (i, (dash, symbol)) in enumerate((("solid", "circle"), ("dash", "square"), ("dot", "diamond")))
				line = _rs_sd(fig.data[i].fields[:line])
				marker = _rs_sd(fig.data[i].fields[:marker])
				@test (line[:dash], line[:width]) == (dash, 2)
				@test (marker[:symbol], marker[:size]) == (symbol, 6)
				@test fig.data[i].fields[:mode] == "lines+markers"
			end
			# The container was replaced, not mutated.
			@test _RS_PB.JSON.json(old_line) == old_line_json
			# Applying again changes nothing.
			again = _rs_json(fig)
			_RS._apply_style_trace_defaults!(fig, 1:3; style = style)
			@test _rs_json(fig) == again

			# Values the caller set are kept; `explicit` protects sentinels.
			set = plot_scatter(1:3, [[1, 2, 3], [2, 3, 4]]; dash = ["dot", ""], marker_symbol = ["x", ""], marker_size = [9, 0], linewidth = [4, 0])
			_RS._apply_style_trace_defaults!(set, [1, 2]; style = style, explicit = (:mode,))
			first_line = _rs_sd(set.data[1].fields[:line])
			@test (first_line[:dash], first_line[:width]) == ("dot", 4)
			@test _rs_sd(set.data[1].fields[:marker])[:symbol] == "x"
			@test _rs_sd(set.data[1].fields[:marker])[:size] == 9
			@test _rs_sd(set.data[2].fields[:line])[:dash] == "dash"
			@test _rs_sd(set.data[2].fields[:marker])[:symbol] == "square"
			@test all(t -> t.fields[:mode] == "lines", set.data)
			kept = plot_scatter(1:3, 1:3)
			_RS._apply_style_trace_defaults!(kept, 1; style = style, explicit = [:dash, :linewidth])
			@test _rs_sd(kept.data[1].fields[:line])[:dash] == ""
			@test !haskey(_rs_sd(kept.data[1].fields[:line]), :width)
			@test _rs_sd(kept.data[1].fields[:marker])[:symbol] == "circle"

			# The cycle counts line-style traces only and continues on append.
			mixed = plot_heatmap([1 2; 3 4])
			plot_scatter!(mixed, 1:2, [1, 2])
			plot_scatter!(mixed, 1:2, [2, 1])
			plot_bar!(mixed, ["a", "b"], [1, 2])
			_RS._apply_style_trace_defaults!(mixed, 1:4; style = PlotStyle(; cycle = :dash))
			@test _rs_sd(mixed.data[2].fields[:line])[:dash] == "solid"
			@test _rs_sd(mixed.data[3].fields[:line])[:dash] == "dash"
			@test !haskey(mixed.data[1].fields, :line)
			@test !haskey(_rs_sd(get(mixed.data[4].fields, :marker, nothing)), :symbol)

			# scatter3d uses its own symbol set.
			cloud = Plot([scatter3d(x = [1, 2], y = [1, 2], z = [1, 2], mode = "lines") for _ in 1:5], Layout())
			_RS._apply_style_trace_defaults!(cloud, 1:5; style = PlotStyle(; cycle = :marker))
			@test [_rs_sd(t.fields[:marker])[:symbol] for t in cloud.data] == ["circle", "square", "diamond", "x", "cross"]
			@test all(t -> t.fields[:mode] == "lines+markers", cloud.data)

			# :default touches nothing; bad arguments throw before any write.
			plain = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]])
			before = _rs_json(plain)
			_RS._apply_style_trace_defaults!(plain, 1:2)
			@test _rs_json(plain) == before
			@test_throws ArgumentError _RS._apply_style_trace_defaults!(plain, [1, 3]; style = style)
			@test_throws ArgumentError _RS._apply_style_trace_defaults!(plain, 0; style = style)
			@test_throws ArgumentError _RS._apply_style_trace_defaults!(plain, true; style = style)
			@test_throws ArgumentError _RS._apply_style_trace_defaults!(plain, 1; style = style, explicit = (:color,))
			@test _rs_json(plain) == before
			# The active style is the default.
			with_style(; linewidth = 3) do
				_RS._apply_style_trace_defaults!(plain, 2)
			end
			@test _rs_sd(plain.data[2].fields[:line])[:width] == 3
			@test !haskey(_rs_sd(plain.data[1].fields[:line]), :width)
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
	finally
		_RS._DEFAULT_TEMPLATE[] = original_template
		set_default_style!(original_style)
	end
end
