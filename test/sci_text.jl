using Test, PlotlySupply

# Tests for src/sci/text.jl: title! (F14/A11/B4), panel_labels! (F14),
# legend_entry! (F15) and the set_legend!/subplot_legends! options it
# validates (F15/A2/A3), on Plot, SyncPlot and SubplotFigure cells.

@testset "sci text" begin
	PS = PlotlySupply
	PB = PlotlySupply.PlotlyBase
	sd(x) = PS._symbol_dict(x)
	pl(f) = PS._plot_obj(f isa SubplotFigure ? f.fig : f)
	lg(f, key = :legend) = sd(get(pl(f).layout.fields, key, nothing))
	layout_json(f) = PB.JSON.json(pl(f).layout)
	data_json(f) = PB.JSON.json(pl(f).data)
	annotations(f) = Any[sd(a) for a in something(get(pl(f).layout.fields, :annotations, nothing), Any[])]
	named(f, name) = filter(a -> get(a, :name, nothing) == name, annotations(f))
	function throws_arg(f, needle::AbstractString)
		err = try
			f()
			nothing
		catch caught
			caught
		end
		return err isa ArgumentError && occursin(needle, err.msg)
	end
	function fake_syncplot(p)
		scripts = String[]
		backend = (
			isopen = window -> true,
			close = window -> nothing,
			run = (window, script) -> (push!(scripts, String(script)); "ok"),
		)
		resources = PS._SyncPlotResources(nothing, backend)
		return SyncPlot(p, nothing, :sci_text_probe, "sci-text-probe", resources), scripts
	end
	x = collect(1.0:5.0)
	grid(rows, cols; kw...) = begin
		sf = subplots(rows, cols; sync = false, kw...)
		for r in 1:rows, c in 1:cols
			plot_scatter!(sf, x, x .* (r + c); legend = "s$(r)$(c)", row = r, col = c)
		end
		sf
	end
	cell(sf, r, c) = PS._cell_target(sf; row = r, col = c, who = "test")

	@testset "title! figure title" begin
		fig = plot_scatter(x, x)
		@test title!(fig, "Hello") === nothing
		t = sd(pl(fig).layout.fields[:title])
		@test t[:text] == "Hello"
		@test t[:x] == 0.5 && t[:xanchor] == "center" && t[:xref] == "paper"
		@test t[:yref] == "container" && t[:y] == 1 && t[:yanchor] == "top"
		@test t[:automargin] === true
		@test sd(t[:pad])[:t] == PS._TEXT_TITLE_TOP_PAD

		# A11 offset + align + fontsize + bold (plain text gets <b>)
		title!(fig, "Left"; align = :left, offset = (5, 3), fontsize = 20, bold = true)
		t = sd(pl(fig).layout.fields[:title])
		@test t[:text] == "<b>Left</b>"
		@test t[:x] == 0 && t[:xanchor] == "left"
		pad = sd(t[:pad])
		@test pad[:t] == PS._TEXT_TITLE_TOP_PAD - 3 && pad[:l] == 5 && pad[:r] == 0
		@test sd(t[:font])[:size] == 20
		title!(fig, "Right"; align = "right", offset = [-4, -2])
		t = sd(pl(fig).layout.fields[:title])
		@test t[:x] == 1 && t[:xanchor] == "right"
		@test sd(t[:pad])[:r] == 4 && sd(t[:pad])[:t] == PS._TEXT_TITLE_TOP_PAD + 2

		# B4: bold + math uses \textbf on the text runs, never <b> around math
		title!(fig, "Mesh \$h\$"; bold = true)
		t = sd(pl(fig).layout.fields[:title])
		@test t[:text] == "\$\\textbf{Mesh }h\$"
		@test !occursin("<b>", t[:text])
		title!(fig, "\$x^2\$"; bold = true)
		@test sd(pl(fig).layout.fields[:title])[:text] == "\$x^2\$"

		# D5: AbstractString text (SubString, LaTeXString)
		title!(fig, SubString("abcdef", 1, 3))
		@test sd(pl(fig).layout.fields[:title])[:text] == "abc"
		title!(fig, L"\alpha")
		@test sd(pl(fig).layout.fields[:title])[:text] == "\$\\alpha\$"

		# "" removes the text
		title!(fig, "")
		@test sd(pl(fig).layout.fields[:title])[:text] == ""
	end

	@testset "title! validation happens before any change" begin
		fig = plot_scatter(x, x; title = "keep")
		before = layout_json(fig)
		@test throws_arg(() -> title!(fig, "t"; align = :middle), "title!: `align`")
		@test throws_arg(() -> title!(fig, "t"; offset = (3, 0)), "centred figure title")
		@test throws_arg(() -> title!(fig, "t"; offset = (0, 11)), "above the top edge")
		@test throws_arg(() -> title!(fig, "t"; offset = (1, 2, 3)), "title!: `offset`")
		@test throws_arg(() -> title!(fig, "t"; offset = (0, Inf)), "title!: `offset[2]`")
		@test throws_arg(() -> title!(fig, "t"; fontsize = -1), "title!: `fontsize`")
		@test throws_arg(() -> title!(fig, "t"; row = 1, col = 1), "title!")
		@test throws_arg(() -> title!(fig, "t"; show = true), "title!: `show` is not supported")
		@test throws_arg(() -> title!(fig, "<b>\$x\$</b>"), "title!: invalid label")
		@test throws_arg(() -> title!(fig, "\$x"), "title!: invalid label")
		@test layout_json(fig) == before
		# offset dy = 10 (the top edge) is allowed; a left title may move left
		title!(fig, "t"; align = :left, offset = (-3, 10))
		@test sd(sd(pl(fig).layout.fields[:title])[:pad])[:t] == 0
	end

	@testset "title! panel titles on SubplotFigure cells" begin
		sf = grid(2, 2)
		@test title!(sf, "(b) err \$e\$"; row = 1, col = 2, align = :left) === sf
		items = named(sf, "plotlysupply:title:1:2")
		@test length(items) == 1
		a = only(items)
		target = cell(sf, 1, 2)
		@test a[:text] == PS._label("(b) err \$e\$"; align = :l)
		@test a[:x] == target.xdomain[1] && a[:y] == target.ydomain[2]
		@test a[:xanchor] == "left" && a[:yanchor] == "bottom" && a[:align] == "left"
		@test a[:xref] == "paper" && a[:yref] == "paper" && a[:showarrow] === false
		@test a[:yshift] == PS._TEXT_PANEL_GAP && a[:xshift] == 0

		# replacing, offsets (dx allowed for panel titles), right/centre alignment
		title!(sf, "(b)"; row = 1, col = 2, align = :right, offset = (2, 3), fontsize = 11, bold = true)
		a = only(named(sf, "plotlysupply:title:1:2"))
		@test a[:text] == "<b>(b)</b>" && a[:x] == target.xdomain[2] && a[:xanchor] == "right"
		@test a[:xshift] == 2 && a[:yshift] == PS._TEXT_PANEL_GAP + 3
		@test sd(a[:font])[:size] == 11
		title!(sf, "(c)"; row = 2, col = 1, offset = (5, 0))
		b = only(named(sf, "plotlysupply:title:2:1"))
		t21 = cell(sf, 2, 1)
		@test b[:x] ≈ (t21.xdomain[1] + t21.xdomain[2]) / 2 && b[:xanchor] == "center"
		# "" removes only that panel title
		title!(sf, ""; row = 1, col = 2)
		@test isempty(named(sf, "plotlysupply:title:1:2"))
		@test length(named(sf, "plotlysupply:title:2:1")) == 1

		# figure title through the SubplotFigure
		title!(sf, "Figure"; align = :left)
		@test sd(pl(sf).layout.fields[:title])[:text] == "Figure"
		@test sd(pl(sf).layout.fields[:title])[:xanchor] == "left"

		# a centred subplot_titles annotation of that cell is replaced
		st = subplots(1, 2; sync = false, subplot_titles = ["A" "B"])
		plot_scatter!(st, x, x; row = 1, col = 2)
		title!(st, "New B"; row = 1, col = 2)
		texts = [get(a, :text, "") for a in annotations(st)]
		@test "A" in texts && !("B" in texts) && "New B" in texts

		# errors (nothing staged)
		before = layout_json(sf)
		@test throws_arg(() -> title!(sf, "t"; row = 1), "`row` and `col`")
		@test throws_arg(() -> title!(sf, "t"; row = 3, col = 1), "row")
		@test throws_arg(() -> title!(sf, "t"; align = :up), "title!: `align`")
		@test throws_arg(() -> title!(sf, "t"; offset = (2, 0)), "centred figure title")
		@test throws_arg(() -> title!(sf, "t"; show = false), "`show` is not supported")
		@test layout_json(sf) == before
	end

	@testset "title! on a SyncPlot" begin
		sp, scripts = fake_syncplot(plot_scatter(x, x))
		@test title!(sp, "Synced"; align = :right) === nothing
		@test sd(sp.plot.layout.fields[:title])[:text] == "Synced"
		@test !isempty(scripts)
	end

	@testset "panel_labels!" begin
		sf = grid(1, 3)
		@test panel_labels!(sf) === sf
		for (c, letter) in enumerate(("a", "b", "c"))
			a = only(named(sf, "plotlysupply:panel_label:1:$(c)"))
			target = cell(sf, 1, c)
			@test a[:text] == "($(letter))"
			@test a[:x] == target.xdomain[1] && a[:y] == target.ydomain[2]
			@test a[:xanchor] == "left" && a[:yanchor] == "bottom"
			@test a[:yshift] == PS._TEXT_PANEL_GAP && !haskey(a, :xshift)
		end
		# inside, other corner, other labels, bold, fontsize; replaces the old ones
		panel_labels!(sf; labels = :ABC, format = "{}.", position = :bottomright, outside = false, bold = true, fontsize = 9)
		@test length(filter(a -> startswith(string(get(a, :name, "")), "plotlysupply:panel_label:"), annotations(sf))) == 3
		a = only(named(sf, "plotlysupply:panel_label:1:2"))
		target = cell(sf, 1, 2)
		@test a[:text] == "<b>B.</b>"
		@test a[:x] == target.xdomain[2] && a[:y] == target.ydomain[1]
		@test a[:xanchor] == "right" && a[:yanchor] == "bottom"
		@test a[:xshift] == -PS._TEXT_PANEL_GAP && a[:yshift] == PS._TEXT_PANEL_GAP
		@test sd(a[:font])[:size] == 9
		panel_labels!(sf; labels = :roman)
		@test [only(named(sf, "plotlysupply:panel_label:1:$(c)"))[:text] for c in 1:3] == ["(i)", "(ii)", "(iii)"]
		panel_labels!(sf; labels = ["x", "\$y\$"], cells = [(1, 3), (1, 1)])
		@test only(named(sf, "plotlysupply:panel_label:1:3"))[:text] == "(x)"
		@test only(named(sf, "plotlysupply:panel_label:1:1"))[:text] == PS._label("(\$y\$)"; align = :l)
		@test PS._text_alpha_label(27) == "aa" && PS._text_roman_label(1994, "t") == "mcmxciv"

		# skipped empty cell (missing spec) in row-major order
		sm = subplots(1, 3; sync = false, specs = [PB.Spec() missing PB.Spec()])
		plot_scatter!(sm, x, x; row = 1, col = 1)
		plot_scatter!(sm, x, x; row = 1, col = 3)
		panel_labels!(sm)
		@test only(named(sm, "plotlysupply:panel_label:1:3"))[:text] == "(b)"
		@test isempty(named(sm, "plotlysupply:panel_label:1:2"))

		# single Plot and SyncPlot
		fig = plot_scatter(x, x)
		@test panel_labels!(fig; labels = ["A"], format = "{}") === nothing
		@test only(named(fig, "plotlysupply:panel_label:1:1"))[:text] == "A"
		sp, scripts = fake_syncplot(plot_scatter(x, x))
		panel_labels!(sp)
		@test only(named(sp, "plotlysupply:panel_label:1:1"))[:text] == "(a)"
		@test !isempty(scripts)

		# errors, before anything changes
		before = layout_json(sf)
		@test throws_arg(() -> panel_labels!(sf; format = "x"), "`format` must contain")
		@test throws_arg(() -> panel_labels!(sf; position = :middle), "`position` must be one of")
		@test throws_arg(() -> panel_labels!(sf; labels = :greek), "`labels` must be")
		@test throws_arg(() -> panel_labels!(sf; labels = ["a"]), "1 label(s) for 3 panel(s)")
		@test throws_arg(() -> panel_labels!(sf; cells = [(1, 1), (1, 1)]), "lists a cell twice")
		@test throws_arg(() -> panel_labels!(sf; cells = [(1, 4)]), "col")
		@test throws_arg(() -> panel_labels!(sf; fontsize = -2), "`fontsize`")
		@test throws_arg(() -> panel_labels!(sf; show = true), "`show` is not supported")
		@test throws_arg(() -> panel_labels!(sf; labels = ["<b>\$x\$</b>", "b", "c"]), "panel_labels!: invalid label")
		@test layout_json(sf) == before
		@test throws_arg(() -> panel_labels!(fig; cells = [(1, 1)]), "omit it")
	end

	@testset "legend_entry! proxies on a Plot" begin
		fig = plot_scatter(x, [x, 2x]; legend = ["", ""])   # unnamed data, hidden (C12)
		@test legend_entry!(fig, "line only"; color = :red, dash = :dash, linewidth = 3) === nothing
		t = fig.data[end].fields
		@test t[:x] == [nothing] && t[:y] == [nothing]
		@test t[:name] == "line only" && t[:showlegend] === true && t[:hoverinfo] == "skip"
		@test t[:mode] == "lines" && sd(t[:line])[:color] == "#FF0000" && sd(t[:line])[:dash] == "dash" && sd(t[:line])[:width] == 3
		legend_entry!(fig, "marker only"; mode = :markers, color = "#d62728", marker_symbol = "o", marker_size = 10)
		t = fig.data[end].fields
		@test t[:mode] == "markers" && sd(t[:marker])[:symbol] == "circle" && sd(t[:marker])[:size] == 10
		legend_entry!(fig, "hollow"; mode = "markers", marker_color = "none", color = "black")
		@test fig.data[end].fields[:mode] == "markers"
		legend_entry!(fig, "patch"; patch = true, color = "rgba(0,0,255,0.3)")
		m = sd(fig.data[end].fields[:marker])
		@test m[:symbol] == "square" && m[:color] == "rgba(0,0,255,0.3)"
		legend_entry!(fig, " ")
		@test sd(fig.data[end].fields[:line])[:color] == "rgba(0,0,0,0)"   # spacer: no symbol
		legend_entry!(fig, " "; color = "blue")
		@test sd(fig.data[end].fields[:line])[:color] == "#0000FF"
		# G10/G49: colours are validated and written as CSS plotly.js draws;
		# matplotlib grey levels become their hex grey.
		legend_entry!(fig, "grey"; mode = "lines+markers", color = "0.35", marker_color = "0.5", marker_line_color = :black)
		t = fig.data[end].fields
		@test sd(t[:line])[:color] == "#595959"
		@test sd(t[:marker])[:color] == "#808080" && sd(sd(t[:marker])[:line])[:color] == "#000000"
		legend_entry!(fig, "unfilled patch"; patch = true, color = "black", marker_color = "none", marker_line_width = 1)
		m = sd(fig.data[end].fields[:marker])
		@test m[:color] == "rgba(0,0,0,0)" && sd(m[:line])[:color] == "#000000"
		legend_entry!(fig, "hollow again"; mode = "markers", marker_symbol = "s", marker_color = "None", color = "0")
		m = sd(fig.data[end].fields[:marker])
		@test m[:symbol] == "square-open" && m[:color] == "#000000"
		legend_entry!(fig, "math \$\\sigma\$"; legendgroup = "g1", opacity = 0.5)
		@test fig.data[end].fields[:name] == PS._label("math \$\\sigma\$")
		@test fig.data[end].fields[:legendgroup] == "g1" && fig.data[end].fields[:opacity] == 0.5
		@test pl(fig).layout.fields[:showlegend] === true
		@test haskey(pl(fig).layout.fields, :legend)
		@test all(i -> fig.data[i].fields[:showlegend] === false, 1:2)

		n = length(fig.data)
		before = layout_json(fig)
		@test throws_arg(() -> legend_entry!(fig, ""), "`label` is empty")
		@test throws_arg(() -> legend_entry!(fig, "x"; mode = "bars"), "`mode` must be")
		@test throws_arg(() -> legend_entry!(fig, "x"; dash = "dashed"), "`dash` must be one of")
		@test throws_arg(() -> legend_entry!(fig, "x"; opacity = 2), "`opacity`")
		@test throws_arg(() -> legend_entry!(fig, "x"; legend_target = :axes), "`legend_target`")
		@test throws_arg(() -> legend_entry!(fig, "x"; row = 1, col = 1), "legend_entry!")
		@test throws_arg(() -> legend_entry!(fig, "x"; show = true), "`show` is not supported")
		@test throws_arg(() -> legend_entry!(fig, "<b>\$x\$</b>"), "legend_entry!: invalid label")
		@test throws_arg(() -> legend_entry!(fig, "x"; color = "nope"), "legend_entry!: `color`: invalid colour \"nope\"")
		@test throws_arg(() -> legend_entry!(fig, "x"; marker_color = "1.5"), "legend_entry!: `marker_color`: a numeric colour")
		@test throws_arg(() -> legend_entry!(fig, "x"; marker_line_color = "#12"), "`marker_line_color`")
		@test length(fig.data) == n && layout_json(fig) == before
		legend_entry!(fig, "custom dash"; dash = "5px,10px")
		@test sd(fig.data[end].fields[:line])[:dash] == "5px,10px"

		# SyncPlot
		sp, scripts = fake_syncplot(plot_scatter(x, x; legend = "data"))
		legend_entry!(sp, "proxy"; color = "green")
		@test sp.plot.data[end].fields[:name] == "proxy"
		@test !isempty(scripts)
	end

	@testset "legend_entry! on SubplotFigure cells" begin
		sf = grid(2, 2)
		@test legend_entry!(sf, "proxy21"; color = "black", row = 2, col = 1) === sf
		t = pl(sf).data[end]
		t21 = cell(sf, 2, 1)
		@test t.fields[:xaxis] == t21.xref && t.fields[:yaxis] == t21.yref
		owner = findfirst(tr -> tr.fields[:name] == "s21", pl(sf).data)
		@test t.fields[:legend] == pl(sf).data[owner].fields[:legend]
		# figure-level entry next to the cell legends
		legend_entry!(sf, "all panels"; color = "gray", dash = "dot", legend_target = :figure, row = 1, col = 1)
		t = pl(sf).data[end]
		@test t.fields[:meta] == PS._FIGURE_LEGEND_META && t.fields[:legend] == PS._FIGURE_LEGEND_ID
		box = lg(sf, Symbol(PS._FIGURE_LEGEND_ID))
		@test box[:yref] == "container" && box[:yanchor] == "bottom"
		# set_legend!(…; legend_target=:figure) moves only that box
		cell_box = lg(sf, :legend2)
		set_legend!(sf; legend_target = :figure, position = :outside_top, ncols = 1)
		box = lg(sf, Symbol(PS._FIGURE_LEGEND_ID))
		@test box[:y] > 1 && box[:yanchor] == "bottom" && !haskey(box, :yref)
		@test lg(sf, :legend2) == cell_box
		@test sf.per_subplot_legends

		# figure-mode canvas: the entry joins the one legend
		sg = subplots(1, 2; sync = false, per_subplot_legends = false)
		plot_scatter!(sg, x, x; legend = "a", row = 1, col = 1)
		legend_entry!(sg, "p"; row = 1, col = 2)
		@test !haskey(pl(sg).data[end].fields, :legend)

		before = data_json(sf)
		@test throws_arg(() -> legend_entry!(sf, "x"; row = 3, col = 1), "row")
		@test throws_arg(() -> legend_entry!(sf, "x"; mode = "nope"), "`mode` must be")
		@test throws_arg(() -> legend_entry!(sf, "x"; show = true), "`show` is not supported")
		@test data_json(sf) == before
	end

	@testset "set_legend! F15 options on a Plot" begin
		fig = plot_scatter(x, [x, 2x, 3x]; legend = ["a", "b", "c"])
		placed = (lg(fig)[:x], lg(fig)[:y])
		set_legend!(fig; ncols = 3)
		d = lg(fig)
		# G43/G58: columns are legend groups sized by their labels, no entrywidth
		@test d[:orientation] == "h" && d[:traceorder] == "grouped" && !haskey(d, :entrywidth)
		@test [t.fields[:legendgroup] for t in pl(fig).data] == ["plotlysupply:col:legend:c:$(k)/3" for k in 1:3]
		@test d[:groupclick] == "toggleitem"
		@test (d[:x], d[:y]) == placed                      # position kept
		set_legend!(fig; entrywidth = 80, itemwidth = 40)   # pixel entries keep the columns
		d = lg(fig)
		@test d[:entrywidth] == 80 && d[:entrywidthmode] == "pixels" && d[:itemwidth] == 40
		@test d[:traceorder] == "grouped" && pl(fig).data[3].fields[:legendgroup] == "plotlysupply:col:legend:c:3/3"
		set_legend!(fig; ncols = 1)                         # one column: plain vertical legend
		d = lg(fig)
		@test d[:orientation] == "v" && d[:traceorder] == "normal"
		@test !any(t -> haskey(t.fields, :legendgroup), pl(fig).data)
		set_legend!(fig; title = "Runs \$n\$", fontsize = 9)
		d = lg(fig)
		@test sd(d[:title])[:text] == PS._label("Runs \$n\$") && sd(d[:font])[:size] == 9
		set_legend!(fig; frame = false)
		d = lg(fig)
		@test d[:bgcolor] == "rgba(0,0,0,0)" && d[:borderwidth] == 0
		set_legend!(fig; frame = true)
		defaults = PS._legend_default_colors(pl(fig))
		@test lg(fig)[:bgcolor] == defaults.bgcolor && lg(fig)[:borderwidth] == defaults.borderwidth
		set_legend!(fig; bgcolor = :white, bordercolor = "black", borderwidth = 2)
		@test lg(fig)[:bgcolor] == "white" && lg(fig)[:borderwidth] == 2

		# positions: tuple / vector, anchors only, inset without position (re-placed at the default)
		set_legend!(fig; position = (1.02, 1.0))
		d = lg(fig)
		@test d[:x] == 1.02 && d[:xanchor] == "left" && d[:y] == 1.0 && d[:yanchor] == "top"
		set_legend!(fig; position = [0.5, 0.5])
		@test lg(fig)[:xanchor] == "center" && lg(fig)[:yanchor] == "middle"
		set_legend!(fig; xanchor = :right)
		@test lg(fig)[:xanchor] == "right" && lg(fig)[:x] == 0.5
		set_legend!(fig; inset = (0.1, 0.2))
		d = lg(fig)
		@test d[:x] ≈ 0.9 && d[:y] ≈ 0.8 && d[:xanchor] == "right" && d[:yanchor] == "top"
		# orientation is part of the placement
		set_legend!(fig; position = :outside_bottom)
		@test lg(fig)[:orientation] == "h"
		set_legend!(fig; position = :topleft)
		@test !haskey(lg(fig), :orientation)
		set_legend!(fig; position = :topleft, orientation = :horizontal)
		@test lg(fig)[:orientation] == "h"

		# showlegend
		set_legend!(fig; showlegend = false)
		@test pl(fig).layout.fields[:showlegend] === false
		set_legend!(fig; showlegend = true)
		@test pl(fig).layout.fields[:showlegend] === true

		# validation: ArgumentError("set_legend!: …") before anything changes
		before = layout_json(fig)
		@test throws_arg(() -> set_legend!(fig; ncols = 2, entrywidth = 50), "either `ncols`")
		@test throws_arg(() -> set_legend!(fig; ncols = 2, orientation = :v), "orientation=:v")
		@test throws_arg(() -> set_legend!(fig; ncols = 1.5), "whole number")
		@test throws_arg(() -> set_legend!(fig; ncols = -1), "`ncols`")
		@test throws_arg(() -> set_legend!(fig; orientation = :diagonal), "`orientation`")
		@test throws_arg(() -> set_legend!(fig; itemwidth = 10), "at least 30")
		@test throws_arg(() -> set_legend!(fig; xanchor = "middle"), "`xanchor`")
		@test throws_arg(() -> set_legend!(fig; yanchor = "left"), "`yanchor`")
		@test throws_arg(() -> set_legend!(fig; frame = false, bgcolor = "red"), "frame=false")
		@test throws_arg(() -> set_legend!(fig; bgcolor = ""), "`bgcolor` must not be empty")
		@test throws_arg(() -> set_legend!(fig; position = (0.5, Inf)), "`position[2]`")
		@test throws_arg(() -> set_legend!(fig; position = [1, 2, 3]), "`position`")
		@test throws_arg(() -> set_legend!(fig; inset = (-0.1, 0)), "`inset[1]`")
		@test throws_arg(() -> set_legend!(fig; borderwidth = -1), "`borderwidth`")
		@test throws_arg(() -> set_legend!(fig; legend_target = :axes), "`legend_target`")
		@test throws_arg(() -> set_legend!(fig; title = "\$x"), "set_legend!: invalid label")
		@test throws_arg(() -> set_legend!(fig; row = 1, col = 1), "omit them")
		@test throws_arg(() -> set_legend!(fig; show = true), "set_legend!: `show` is not supported")
		@test layout_json(fig) == before
		@test_throws MethodError set_legend!(fig; not_a_keyword = 1)   # D5: unknown keywords still raise

		# dedupe: same name and style → one entry, one legend group; dedupe=false keeps both
		dd = plot_scatter(x, [x, 2x]; legend = ["same", "same"], color = ["black", "black"])
		set_legend!(dd)
		@test dd.data[1].fields[:legendgroup] == dd.data[2].fields[:legendgroup]
		@test dd.data[2].fields[:showlegend] === false
		nd = plot_scatter(x, [x, 2x]; legend = ["same", "same"], color = ["black", "red"])
		set_legend!(nd)
		@test get(nd.data[2].fields, :showlegend, true) != false   # different style: both listed
		kd = plot_scatter(x, [x, 2x]; legend = ["same", "same"], color = ["black", "black"])
		set_legend!(kd; dedupe = false)
		@test !haskey(kd.data[2].fields, :legendgroup)

		# SyncPlot (layout-only fast path and trace-editing path)
		sp, scripts = fake_syncplot(plot_scatter(x, [x, 2x]; legend = ["a", "b"]))
		@test set_legend!(sp; position = :outside_bottom, ncols = 2) === sp
		@test sd(sp.plot.layout.fields[:legend])[:yref] == "container"
		@test !isempty(scripts)
		sp2, _ = fake_syncplot(plot_scatter(x, [x, 2x]; legend = ["s", "s"], color = ["black", "black"]))
		set_legend!(sp2)
		@test sp2.plot.data[2].fields[:showlegend] === false
	end

	@testset "set_legend! per-cell placement (A2) and modes" begin
		sf = grid(2, 2; horizontal_spacing = 0.2)
		id12 = PS._legend_cell_legend_id(pl(sf), cell(sf, 1, 2))
		@test set_legend!(sf; row = 1, col = 2, position = (1.03, 1.0)) === sf
		d = lg(sf, Symbol(id12))
		t12 = cell(sf, 1, 2)
		# D12: just outside the right edge, it is placed at the right-hand slot
		# of its cell by the room providers (in the requested direction, not
		# farther out than asked)
		plan = PS._room_plan(sf)
		slot = PS._room_slot(plan, PS._LT_OWNER, "legend:" * id12)
		@test d[:x] ≈ PS._lt_outside(plan, slot.edge, slot.offset, :right)
		@test t12.xdomain[2] < d[:x] <= t12.xdomain[1] + 1.03 * (t12.xdomain[2] - t12.xdomain[1])
		@test d[:xanchor] == "left" && d[:y] ≈ t12.ydomain[2]
		# A3/G57 per-cell ncols: content-sized columns (one entry → one column)
		id21 = PS._legend_cell_legend_id(pl(sf), cell(sf, 2, 1))
		set_legend!(sf; row = 2, col = 1, position = :top, ncols = 2, frame = false)
		d = lg(sf, Symbol(id21))
		owner21 = findfirst(t -> t.fields[:name] == "s21", pl(sf).data)
		@test d[:orientation] == "h" && d[:traceorder] == "grouped" && !haskey(d, :entrywidth)
		@test pl(sf).data[owner21].fields[:legendgroup] == "plotlysupply:col:$(id21):c:1/1"
		@test d[:bgcolor] == "rgba(0,0,0,0)"
		# other cells untouched by a per-cell call
		id11 = PS._legend_cell_legend_id(pl(sf), cell(sf, 1, 1))
		before11 = lg(sf, Symbol(id11))
		set_legend!(sf; row = 2, col = 2, position = :bottomleft, title = "cell")
		@test lg(sf, Symbol(id11)) == before11
		# showlegend for one cell box
		set_legend!(sf; row = 2, col = 2, showlegend = false)
		@test lg(sf, Symbol(PS._legend_cell_legend_id(pl(sf), cell(sf, 2, 2))))[:visible] === false

		# errors
		before = layout_json(sf)
		@test throws_arg(() -> set_legend!(sf; row = 1), "`row` and `col`")
		@test throws_arg(() -> set_legend!(sf; row = 1, col = 1, legend_target = :figure), "drop `row`/`col`")
		@test throws_arg(() -> set_legend!(sf; ncols = 2, entrywidth = 3), "either `ncols`")
		@test throws_arg(() -> set_legend!(sf; show = true), "`show` is not supported")
		@test layout_json(sf) == before
		empty_cell = subplots(1, 2; sync = false)
		plot_scatter!(empty_cell, x, x; legend = "a", row = 1, col = 1)
		@test throws_arg(() -> set_legend!(empty_cell; row = 1, col = 2, position = :top), "no legend entries yet")

		# an outside position merges all cells into one deduplicated figure legend
		sm = subplots(1, 3; sync = false)
		for c in 1:3
			plot_scatter!(sm, x, [x, 2x]; legend = ["model", "data"], color = ["black", "red"], row = 1, col = c)
		end
		set_legend!(sm; position = :outside_bottom, ncols = 2, frame = false)
		@test !sm.per_subplot_legends
		@test all(t -> !haskey(t.fields, :legend), pl(sm).data)
		@test count(t -> get(t.fields, :showlegend, true) !== false, pl(sm).data) == 2
		@test !any(k -> occursin(PS._LEGEND_ID_PATTERN, String(k)), keys(pl(sm).layout.fields))
		@test lg(sm)[:yref] == "container" && lg(sm)[:traceorder] == "grouped" && !haskey(lg(sm), :entrywidth)
		@test [pl(sm).data[k].fields[:legendgroup] for k in 1:2] == ["plotlysupply:col:legend:c:$(k)/2" for k in 1:2]
		# figure-mode cell placement needs per-subplot legends
		@test throws_arg(() -> set_legend!(sm; row = 1, col = 1, position = :top), "per-subplot legends")
		# back to cell legends; the merge is undone
		set_legend!(sm; legend_target = :cell, position = :topleft)
		@test sm.per_subplot_legends
		@test count(t -> get(t.fields, :showlegend, true) !== false, pl(sm).data) == 6
		@test length(unique(t.fields[:legend] for t in pl(sm).data)) == 3
	end

	@testset "legend columns: ncols, wrapped cell legends, title_side (G43, G57-G59, G76)" begin
		group(f, k) = get(pl(f).data[k].fields, :legendgroup, nothing)
		# column-major as matplotlib: the first `m mod n` columns take one more
		cm = plot_scatter(x, [x .+ k for k in 1:5]; legend = ["a", "b", "c", "d", "e"])
		set_legend!(cm; ncols = 2)
		@test [group(cm, k) for k in 1:5] == ["plotlysupply:col:legend:c:$(k)/2" for k in (1, 1, 1, 2, 2)]
		@test PS._legend_column_assignment(7, 3, 'c') == [1, 1, 1, 2, 2, 3, 3]
		@test PS._legend_column_assignment(5, 2, 'r') == [1, 2, 1, 2, 1]
		@test PS._legend_column_assignment(2, 4, 'c') == [1, 2]

		# columns that do not fit the plot area are reduced, with a warning
		long = ["Graph eigenvalue error, mesh level 1 (h)", "Doublet projector error at level 2",
			"Full-model envelope, three frequencies"]
		lf = plot_scatter(x, [x .+ k for k in 1:3]; legend = long)
		@test_logs (:warn, r"3 legend columns .* using 2\.") set_legend!(lf; ncols = 3)
		@test [group(lf, k) for k in 1:3] == ["plotlysupply:col:legend:c:$(k)/2" for k in (1, 1, 2)]
		wide = plot_scatter(x, [x .+ k for k in 1:3]; legend = long)
		relayout!(wide; width = 1600)
		@test_logs set_legend!(wide; ncols = 3)              # wide enough: no warning
		@test group(wide, 3) == "plotlysupply:col:legend:c:3/3"

		# merged duplicates: the listed entry takes a column, its duplicates rejoin it without columns
		dp = plot_scatter(x, [x, 2x, 3x]; legend = ["same", "same", "other"], color = ["black", "black", "red"])
		set_legend!(dp; ncols = 2)
		@test group(dp, 1) == "plotlysupply:col:legend:c:1/2" && group(dp, 3) == "plotlysupply:col:legend:c:2/2"
		@test group(dp, 2) == PS._LEGEND_DEDUPE_GROUP_PREFIX * "legend:1" && pl(dp).data[2].fields[:showlegend] === false
		set_legend!(dp; ncols = 1)
		@test group(dp, 1) == group(dp, 2) && group(dp, 3) === nothing
		@test lg(dp)[:traceorder] == "normal"

		# pie legends list slices: never split into columns
		pp = plot_pie([3, 2, 1]; labels = ["a", "b", "c"])
		set_legend!(pp; ncols = 2)
		@test group(pp, 1) === nothing && get(lg(pp), :traceorder, "") != "grouped"

		# entries added later join the last column of a cell legend
		sc = subplots(1, 2; sync = false)
		plot_scatter!(sc, x, [x, 2x, 3x]; legend = ["a", "b", "c"], row = 1, col = 1)
		plot_scatter!(sc, x, x; legend = "z", row = 1, col = 2)
		set_legend!(sc; row = 1, col = 1, ncols = 2)
		id = PS._legend_cell_legend_id(pl(sc), cell(sc, 1, 1))
		@test [group(sc, k) for k in 1:3] == ["plotlysupply:col:$(id):c:$(k)/2" for k in (1, 1, 2)]
		@test group(sc, 4) === nothing                       # the other cell keeps no columns
		plot_scatter!(sc, x, 4x; legend = "d", row = 1, col = 1)
		@test group(sc, 5) == "plotlysupply:col:$(id):c:2/2"

		# G59: a horizontal cell legend wraps row by row inside its cell
		sh = subplots(1, 3; sync = false)
		plot_scatter!(sh, x, [x, 2x]; legend = ["two frequencies", "three frequencies"], row = 1, col = 1)
		plot_scatter!(sh, x, x; legend = "z", row = 1, col = 2)
		# v7 L10: two long labels fit no corner of a third of the figure, so the
		# rule put this legend right of its cell (narrowing it); pinned inside,
		# the rows below are computed for the cell's full width.
		set_legend!(sh; row = 1, col = 1, position = :topright)
		@test_logs set_legend!(sh; row = 1, col = 1, orientation = :h)
		id = PS._legend_cell_legend_id(pl(sh), cell(sh, 1, 1))
		infos = [PS._legend_column_info(group(sh, k)) for k in 1:2]
		@test all(i -> i !== nothing && i[1] == id && i[2] == 'r', infos)
		@test lg(sh, Symbol(id))[:orientation] == "h"
		# ... and an explicit pixel entry width is kept and sizes the entries
		set_legend!(sh; row = 1, col = 1, orientation = :h, entrywidth = 10)
		@test lg(sh, Symbol(id))[:entrywidth] == 10 && group(sh, 2) == "plotlysupply:col:$(id):r:2/2"
		set_legend!(sh; row = 1, col = 1, orientation = :v)
		@test group(sh, 1) === nothing && group(sh, 2) === nothing

		# G76: legend title side
		ts = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
		set_legend!(ts; title = "Runs", title_side = :left)
		@test sd(lg(ts)[:title])[:side] == "left" && sd(lg(ts)[:title])[:text] == "Runs"
		set_legend!(ts; title_side = "top-center")
		@test sd(lg(ts)[:title])[:side] == "top center"
		before = layout_json(ts)
		@test throws_arg(() -> set_legend!(ts; title_side = :bottom), "set_legend!: `title_side` must be one of")
		@test layout_json(ts) == before
		tc = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
		set_legend!(tc; title = "Runs", ncols = 2)            # a column legend's title goes on top
		@test sd(lg(tc)[:title])[:side] == "top"
		sl = grid(1, 2)
		subplot_legends!(sl; title = "cell", title_side = :top_left)
		@test all(k -> sd(lg(sl, k)[:title])[:side] == "top left", (:legend, :legend2))
	end

	@testset "D5: no ambiguities, unknown keywords still raise" begin
		mine = (:title!, :panel_labels!, :legend_entry!, :set_legend!, :subplot_legends!)
		amb = Test.detect_ambiguities(PlotlySupply; recursive = false)
		@test isempty(filter(a -> a[1].name in mine || a[2].name in mine, amb))
		fig = plot_scatter(x, x; legend = "a")
		sf = grid(1, 2)
		for target in (fig, sf)
			@test_throws MethodError title!(target, "t"; not_a_keyword = 1)
			@test_throws MethodError panel_labels!(target; not_a_keyword = 1)
			@test_throws MethodError legend_entry!(target, "t"; not_a_keyword = 1)
			@test_throws MethodError set_legend!(target; not_a_keyword = 1)
			@test_throws MethodError subplot_legends!(target; not_a_keyword = 1)
		end
	end

	@testset "set_default_legend_position!" begin
		original = get_default_legend_position()
		try
			@test set_default_legend_position!("upper left") === :topleft
			@test get_default_legend_position() === :topleft
			@test set_default_legend_position!(:left_outside) === :outside_left
			@test throws_arg(() -> set_default_legend_position!(42), "must be a Symbol or a string")
			@test get_default_legend_position() === :outside_left
			@test (@test_logs (:warn,) match_mode = :any set_default_legend_position!(:nowhere)) === :topright
		finally
			set_default_legend_position!(original)
		end
	end

	@testset "panel labels and corner-aligned panel titles never overlap" begin
		sf = grid(1, 2)
		panel_labels!(sf; bold = true)
		label(r, c) = only(named(sf, "plotlysupply:panel_label:$(r):$(c)"))
		ptitle(r, c) = only(named(sf, "plotlysupply:title:$(r):$(c)"))
		# A left-aligned title at the label's corner: the label moves beside
		# the corner (outside the axes), the title keeps the corner.
		title!(sf, L"Mesh, $h = 0.1$"; row = 1, col = 1, align = :left)
		t11 = cell(sf, 1, 1)
		# D12: beside the corner it sits over the y tick labels, so the title
		# line rises clear of the top one
		plan = PS._room_plan(sf)
		line = PS._room_slot(plan, PS._LT_OWNER, "line:xaxis")
		entry = only(e for e in only(d for d in PS._lt_decorations(plan) if d.key == "line:xaxis").data
			if e[1] == "plotlysupply:panel_label:1:1")
		@test line.offset + entry[3] >= PS._LT_TICK_REACH * PS._lt_y_tick_font(plan, plan.areas[:xaxis], :left) + 1 - 1e-9
		@test label(1, 1)[:x] == t11.xdomain[1] &&
			  label(1, 1)[:y] ≈ PS._lt_outside(plan, line.edge, line.offset - PS._ROOM_GAP + entry[3], :top)
		@test label(1, 1)[:xanchor] == "right" && label(1, 1)[:xshift] == -PS._TEXT_PANEL_GAP
		@test label(1, 1)[:yanchor] == "bottom" && label(1, 1)[:yshift] == PS._TEXT_PANEL_GAP
		@test ptitle(1, 1)[:x] == t11.xdomain[1] && ptitle(1, 1)[:xanchor] == "left"
		@test ptitle(1, 1)[:text] == PS._label(L"Mesh, $h = 0.1$"; align = :l)
		# A centred title leaves the label at the corner.
		title!(sf, "Error"; row = 1, col = 2)
		@test label(1, 2)[:xanchor] == "left" && !haskey(label(1, 2), :xshift)
		# Removing the title puts the label back.
		title!(sf, ""; row = 1, col = 1)
		@test isempty(named(sf, "plotlysupply:title:1:1"))
		@test label(1, 1)[:xanchor] == "left" && !haskey(label(1, 1), :xshift)
		# Title first, then labels; the right corner mirrors the left one.
		title!(sf, "Error"; row = 1, col = 2, align = :right)
		panel_labels!(sf; position = :topright)
		@test label(1, 2)[:x] == cell(sf, 1, 2).xdomain[2]
		@test label(1, 2)[:xanchor] == "left" && label(1, 2)[:xshift] == PS._TEXT_PANEL_GAP
		@test label(1, 1)[:xanchor] == "right" && !haskey(label(1, 1), :xshift)
		# A title at the other corner, inside labels and bottom labels stay put.
		title!(sf, "Mesh"; row = 1, col = 1, align = :right)
		panel_labels!(sf)
		@test label(1, 1)[:xanchor] == "left" && !haskey(label(1, 1), :xshift)
		title!(sf, "Mesh"; row = 1, col = 1, align = :left)
		panel_labels!(sf; outside = false)
		@test label(1, 1)[:xanchor] == "left" && label(1, 1)[:xshift] == PS._TEXT_PANEL_GAP
		@test label(1, 1)[:yanchor] == "top"
		panel_labels!(sf; position = :bottomleft)
		@test label(1, 1)[:xanchor] == "left" && label(1, 1)[:yanchor] == "top"
		@test !haskey(label(1, 1), :xshift)
		# Only the panel label of the retitled cell is rewritten.
		panel_labels!(sf)
		before_12 = PB.JSON.json(label(1, 2))
		title!(sf, "Mesh 2"; row = 1, col = 1, align = :left)
		@test PB.JSON.json(label(1, 2)) == before_12
		@test label(1, 1)[:xanchor] == "right"
	end

	@testset "#19: LaTeXString and SubString labels in every text/axis helper" begin
		sub = SubString("xx time (s) yy", 4, 11)            # "time (s)"
		math = L"$\alpha_1$ (rad)"
		@test sub isa SubString && math isa AbstractString && !(math isa String)
		sf = grid(2, 2)
		title!(sf, math)
		@test PS._cmn_mapping_get(pl(sf).layout.fields[:title], :text) == PS._label(String(math))
		title!(sf, sub; row = 1, col = 1, align = :left)
		@test only(named(sf, "plotlysupply:title:1:1"))[:text] == PS._label(String(sub); align = :l)
		panel_labels!(sf; labels = [sub, math, SubString("abc", 2, 2), "d"], format = SubString("[({})]", 2, 5))
		@test only(named(sf, "plotlysupply:panel_label:1:2"))[:text] == PS._label("(" * String(math) * ")"; align = :l)
		@test only(named(sf, "plotlysupply:panel_label:2:1"))[:text] == PS._label("(b)"; align = :l)
		xlabel!(sf, math; row = 2, col = 2)
		ylabel!(sf, sub; row = 2, col = 2)
		@test PS._cmn_mapping_get(pl(sf).layout.fields[:xaxis4][:title], :text) == PS._label(String(math))
		@test PS._cmn_mapping_get(pl(sf).layout.fields[:yaxis4][:title], :text) == "time (s)"
		xticks!(sf, [1, 2], [math, sub]; row = 2, col = 2)
		@test pl(sf).layout.fields[:xaxis4][:ticktext] == [PS._label(String(math)), "time (s)"]
		secondary_xaxis!(sf, v -> 2v, v -> v / 2; row = 2, col = 2, title = math, ticks = [2, 4], ticklabels = [sub, math])
		sec = pl(sf).layout.fields[:xaxis5]
		@test PS._cmn_mapping_get(sec[:title], :text) == PS._label(String(math))
		@test sec[:ticktext] == ["time (s)", PS._label(String(math))]
		fig = plot_scatter(x, x)
		legend_entry!(fig, math; color = SubString("xred", 2, 4))
		legend_entry!(fig, sub)
		names = [get(t.fields, :name, nothing) for t in pl(fig).data]
		@test PS._label(String(math)) in names && "time (s)" in names
		PS._apply_cartesian_plot_options!(fig; xlabel = sub, ylabel = math, title = sub, who = "t")
		@test PS._cmn_mapping_get(pl(fig).layout.fields[:xaxis][:title], :text) == "time (s)"
		@test PS._cmn_mapping_get(pl(fig).layout.fields[:yaxis][:title], :text) == PS._label(String(math))
	end

	@testset "legend columns: a cell legend above or below its axes uses the band beside it (G83/G77)" begin
		sf = subplots(1, 3; sync = false)
		for c in 1:3
			plot_scatter!(sf, 1:3, 1:3; row = 1, col = c, legend = "s$(c)")
		end
		p = pl(sf)
		area = PS._legend_plot_area_width(p)
		xd = [PS._layout_axis_domain(p.layout, Symbol("xaxis", k == 1 ? "" : k)) for k in 1:3]
		yd = PS._layout_axis_domain(p.layout, :yaxis)
		# the band of the middle cell runs from its neighbours' edges ...
		lo, hi = PS._legend_band_interval(p, xd[2], yd)
		@test lo ≈ xd[1][2] && hi ≈ xd[3][1]
		# ... and beside the outer cells into the figure margins
		@test PS._legend_band_interval(p, xd[1], yd)[1] ≈ -PS._legend_margin_lr(p, :l) / area
		@test PS._legend_band_interval(p, xd[3], yd)[2] ≈ 1 + PS._legend_margin_lr(p, :r) / area
		span = xd[2][2] - xd[2][1]
		above(xanchor, x) = Dict{Symbol, Any}(:x => x, :xanchor => xanchor, :y => 1.0, :yanchor => "bottom")
		@test PS._legend_available_width(p, above("right", xd[2][2]), span; legend_id = "legend2") ≈
			(xd[2][2] - xd[1][2]) * area
		@test PS._legend_available_width(p, above("left", xd[2][1]), span; legend_id = "legend2") ≈
			(xd[3][1] - xd[2][1]) * area
		middle = (xd[2][1] + xd[2][2]) / 2
		@test PS._legend_available_width(p, above("center", middle), span; legend_id = "legend2") ≈
			2 * min(middle - xd[1][2], xd[3][1] - middle) * area
		below = Dict{Symbol, Any}(:x => xd[2][2], :xanchor => "right", :y => 0.0, :yanchor => "top")
		@test PS._legend_available_width(p, below, span; legend_id = "legend2") ≈ (xd[2][2] - xd[1][2]) * area
		# inside the axes, or without the legend id: the cell width
		inside = Dict{Symbol, Any}(:x => xd[2][2], :xanchor => "right", :y => 0.97, :yanchor => "top")
		@test PS._legend_available_width(p, inside, span; legend_id = "legend2") ≈ span * area
		@test PS._legend_available_width(p, above("right", xd[2][2]), span) ≈ span * area
	end

	@testset "D12: baseline depth of a title (_text_baseline_depth)" begin
		frame = PS._TEXT_ANNOTATION_FRAME
		s = PS._TEXT_SCRIPT_SCALE
		saved = PS._MATHTEXT_SETTINGS[]
		try
			set_default_mathtext!(true; inherit_text_font = false)
			# plain text: half the frame plus the font descent
			@test PS._text_baseline_depth("Plain title", 12) ≈ frame / 2 + 0.2 * 12
			@test PS._text_baseline_depth("Plain title", 16) ≈ frame / 2 + 0.2 * 16
			@test PS._text_baseline_depth("Plain title", 0) ≈ frame / 2 + 0.2 * 12      # unusable size: 12 px
			# MathJax: the depth of the expression
			@test PS._text_baseline_depth("\$x\$", 12) ≈ 0.25
			@test PS._text_baseline_depth("\$y\$", 12) ≈ 0.25 + 0.2 * 12
			@test PS._text_baseline_depth("\$\\mathrm{f}\$", 12) ≈ 0.25                # upright: no tail
			@test PS._text_baseline_depth("\$f\$", 12) ≈ 0.25 + 0.2 * 12
			@test PS._text_baseline_depth("\$(a)\$", 12) ≈ 0.25 + 0.25 * 12
			@test PS._text_baseline_depth("\$x_i\$", 12) ≈ 0.25 + 0.15 * 12
			@test PS._text_baseline_depth("\$x_i^2\$", 12) ≈ 0.25 + 0.25 * 12
			@test PS._text_baseline_depth("\$x_y\$", 12) ≈ 0.25 + (0.15 + s * 0.2) * 12
			@test PS._text_baseline_depth("\$\\frac{a}{b}\$", 12) ≈ 0.25 + 0.47 * 12
			@test PS._text_baseline_depth("\$\\sum_k x_k\$", 13) ≈ 0.25 + 0.36 * 13
			@test PS._text_baseline_depth("\$\\alpha\$ and \$\\beta\$", 12) ≈ 0.25   # the first segment
			# not estimated
			@test PS._text_baseline_depth("\$\\begin{array}{c}a\\\\b\\end{array}\$", 12) === nothing
			@test PS._text_baseline_depth("x<sub>2</sub>", 12) === nothing
			@test PS._text_baseline_depth("  ", 12) === nothing
			# inherit_text_font: text runs are drawn in the label's font
			set_default_mathtext!(true; inherit_text_font = true)
			@test PS._text_baseline_depth("\$\\text{(a) }x\$", 12) ≈ PS._TEXT_INHERITED_TEXT_DEPTH_PX
			@test PS._text_baseline_depth("\$\\frac{a}{b}\\text{ x}\$", 12) ≈ 0.25 + 0.47 * 12
			@test PS._text_baseline_depth("\$x\$", 12) ≈ 0.25                          # no text run
		finally
			PS._MATHTEXT_SETTINGS[] = saved
		end
	end

	@testset "D12: the titles of a row share one baseline (W2 chama_a6, audit_d)" begin
		saved = PS._MATHTEXT_SETTINGS[]
		try
			set_default_mathtext!(true; inherit_text_font = false)
			sf = subplots(1, 3; sync = false)
			for c in 1:3
				plot_scatter!(sf, 1:3, (1:3) .* c; row = 1, col = c)
			end
			title!(sf, "(a) plain"; row = 1, col = 1)
			title!(sf, "\$\\frac{a}{b}\$"; row = 1, col = 2)
			title!(sf, "\$x\$"; row = 1, col = 3)
			plan = PS._room_plan(sf)
			lines = Dict(d.area => d for d in PS._lt_decorations(plan) if d.role === :line)
			raise(key) = only(lines[key].data)[3]
			depth(text) = PS._text_baseline_depth(text, 12)
			deepest = depth("\$\\frac{a}{b}\$")
			@test raise(:xaxis2) == 0.0
			@test raise(:xaxis) ≈ deepest - depth("(a) plain")
			@test raise(:xaxis3) ≈ deepest - depth("\$x\$")
			# each line requests its own room plus its raise
			@test lines[:xaxis3].px ≈ maximum(PS._lt_annotation_px(plan, a, 1.0)
				for a in pl(sf).layout.fields[:annotations] if get(sd(a), :name, "") == "plotlysupply:title:1:3") + raise(:xaxis3)
			# placed: the raise goes into `y`, so the plain title sits higher
			y(name) = only(named(sf, name))[:y]
			@test y("plotlysupply:title:1:1") > y("plotlysupply:title:1:2")
			@test y("plotlysupply:title:1:3") > y("plotlysupply:title:1:1")
		finally
			PS._MATHTEXT_SETTINGS[] = saved
		end
	end

	@testset "Z60: subplot_titles are panel titles (named, styled, stacked)" begin
		sf = subplots(1, 2; sync = false, subplot_titles = ["(a) left", "(b) right"])
		for c in 1:2
			plot_scatter!(sf, 1:3, 1:3; row = 1, col = c)
		end
		for c in 1:2
			a = only(named(sf, "plotlysupply:title:1:$(c)"))
			@test a[:yanchor] == "bottom" && a[:yshift] == PS._TEXT_PANEL_GAP
		end
		set_fonts!(sf; title = 17)
		@test all(c -> sd(only(named(sf, "plotlysupply:title:1:$(c)"))[:font])[:size] == 17, 1:2)
		# title! on the cell replaces it instead of adding a second title
		title!(sf, "(a) replaced"; row = 1, col = 1)
		@test only(named(sf, "plotlysupply:title:1:1"))[:text] == "(a) replaced"
		@test length(annotations(sf)) == 2
	end

	@testset "Z17/Z18/Z21: cell keywords on whole-figure verbs are ArgumentErrors" begin
		sf = subplots(2, 2; sync = false)
		plot_scatter!(sf, 1:3, 1:3; legend = "a", row = 1, col = 1)
		before = layout_json(sf)
		@test throws_arg(() -> panel_labels!(sf; row = 2, col = 2), "panel_labels!: ")
		@test throws_arg(() -> panel_labels!(sf; row = 1), "panel_labels!: ")
		@test throws_arg(() -> subplot_legends!(sf; row = 2, col = 2), "subplot_legends!: ")
		@test throws_arg(() -> tight_layout!(sf; row = 2, col = 2), "tight_layout!: ")
		@test throws_arg(() -> tight_layout!(sf; show = true), "tight_layout!: ")
		@test throws_arg(() -> tight_layout!(sf; pad = "4"), "tight_layout!: ")
		fig = plot_scatter(1:3, 1:3)
		@test throws_arg(() -> tight_layout!(fig; show = true), "tight_layout!: ")
		@test throws_arg(() -> tight_layout!(fig; row = 1), "tight_layout!: ")
		@test throws_arg(() -> tight_layout!(fig; pad = -1), "tight_layout!: ")
		@test layout_json(sf) == before
	end

	@testset "v7: annotate! at an axes edge keeps a pad from the frame and its inward ticks" begin
		shift(f) = (a = last(annotations(f)); (get(a, :xshift, 0.0), get(a, :yshift, 0.0)))
		note!(f, x, y; kw...) = annotate!(f, x, y, "note"; coords = :axes, showarrow = false, kw...)
		# :ieee draws ticks inside on all four sides (mirrored): tick length
		# 3.5 pt, frame 1 px: 3.5 pt + 1.75 pt + 0.5 px.
		ieee = with_style(() -> plot_scatter([0.0, 1.0], [0.0, 1.0]), :ieee)
		len = Float64(sd(pl(ieee).layout.fields[:yaxis])[:ticklen])
		@test len ≈ 3.5 * PS._PT_PX
		pad = len + len / 2 + 0.5
		note!(ieee, 1, 0.5; anchor = :right)
		@test all(shift(ieee) .≈ (-pad, 0.0))
		note!(ieee, 0, 0; anchor = :bottomleft)
		@test all(shift(ieee) .≈ (pad, pad))
		note!(ieee, 1, 1)                                       # plotly's automatic anchor: top right
		@test all(shift(ieee) .≈ (-pad, -pad))
		# no pad: anchored away from the edge, centred on it, inside the
		# axes, with an arrow, an explicit offset, a raw shift, data coordinates
		for kw in ((anchor = :left,), (anchor = :center,))
			note!(ieee, 1, 0.5; kw...)
			@test shift(ieee) == (0.0, 0.0)
		end
		note!(ieee, 0.98, 0.5; anchor = :right)
		@test shift(ieee) == (0.0, 0.0)
		annotate!(ieee, 1, 0.5, "arrow"; coords = :axes)
		@test shift(ieee) == (0.0, 0.0)
		note!(ieee, 1, 0.5; anchor = :right, offset = (0, 0))
		@test shift(ieee) == (0.0, 0.0)
		note!(ieee, 1, 0.5; anchor = :right, offset = (-2, 1), units = :pt)
		@test all(shift(ieee) .≈ (-2 * PS._PT_PX, PS._PT_PX))
		note!(ieee, 1, 0.5; anchor = :right, yshift = 4)
		@test shift(ieee) == (0.0, 4)
		annotate!(ieee, 1.0, 0.5, "data"; showarrow = false, anchor = :right)
		@test shift(ieee) == (0.0, 0.0)
		# :default: outside ticks of plotly's 5 px, a 1 px frame
		plain = plot_scatter([0.0, 1.0], [0.0, 1.0])
		note!(plain, 1, 0.5; anchor = :right)
		@test all(shift(plain) .≈ (-3.0, 0.0))
		# a cell of a grid and its twin y axis with inside ticks on the right
		sf = subplots(1, 2; sync = false, specs = [Spec() Spec(secondary_y = true)])
		plot_scatter!(sf, [0.0, 1.0], [0.0, 1.0]; row = 1, col = 2)
		plot_scatter!(sf, [0.0, 1.0], [1.0, 0.0]; row = 1, col = 2, secondary_y = true)
		twin = only(k for (k, v) in pl(sf).layout.fields if occursin(r"^yaxis\d+$", String(k)) &&
			get(sd(v), :overlaying, nothing) == "y2")
		relayout!(sf; Symbol(twin, "_ticks") => "inside", Symbol(twin, "_ticklen") => 8)
		note!(sf, 1, 0.5; row = 1, col = 2, anchor = :right)
		@test all(shift(sf) .≈ (-(8 + 2.5 + 0.5), 0.0))
		note!(sf, 0, 0.5; row = 1, col = 2, anchor = :left)
		@test all(shift(sf) .≈ (3.0, 0.0))                       # the left edge has no inside ticks
	end

	@testset "v7 docs-06: column and row titles keep the panel titles' gap from the frame" begin
		sf = subplots(2, 2; sync = false, subplot_titles = ["a" "b"; "c" "d"],
			column_titles = ["\$\\alpha = 1\$", "C2"], row_titles = ["R1", "\$r_2\$"])
		byname = Dict(a[:name] => a for a in annotations(sf) if haskey(a, :name))
		gap = PS._TEXT_PANEL_GAP
		@test byname["plotlysupply:title:1:1"][:yshift] == gap
		for c in 1:2
			@test byname["plotlysupply:title!:1:$(c):column"][:yshift] == gap
		end
		for r in 1:2
			@test byname["plotlysupply:title!:$(r):2:row"][:xshift] == gap
		end
	end

	@testset "v7 perf-04: panel_labels! writes every label in one relayout" begin
		# (not `grid`: that name is the outer testset's local helper)
		function square_grid(n)
			g = subplots(n, n; sync = false)
			for r in 1:n, c in 1:n
				plot_scatter!(g, [1.0, 2.0], [1.0, 2.0]; row = r, col = c)
			end
			return g
		end
		small, large = square_grid(4), square_grid(8)
		panel_labels!(small)
		panel_labels!(large)
		# Measured before: 7.7 MB (4 x 4) and 86 MB (8 x 8), 11x for 4x the
		# cells (one relayout of the whole annotation list per label).
		@test @allocated(panel_labels!(large)) < 6 * @allocated(panel_labels!(small))
		# the same annotations as one upsert per label: the others first, in
		# their order, then the labels in cell order; a second call replaces
		sf = subplots(1, 3; sync = false)
		for c in 1:3
			plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row = 1, col = c)
		end
		annotate!(sf, 1.5, 1.5, "note"; row = 1, col = 2)
		panel_labels!(sf)
		panel_labels!(sf; format = "{})")
		names = [get(a, :name, "") for a in annotations(sf)]
		labels = filter(n -> startswith(n, "plotlysupply:panel_label:"), names)
		@test labels == ["plotlysupply:panel_label:1:$(c)" for c in 1:3]
		@test findfirst(==(labels[1]), names) > something(findfirst(n -> !startswith(n, "plotlysupply:panel_label:"), names), 0)
		@test [a[:text] for a in annotations(sf) if startswith(get(a, :name, ""), "plotlysupply:panel_label:")] ==
			[PS._text_label("$(l))", :left, false, "panel_labels!") for l in ("a", "b", "c")]
	end

	@testset "v7 tm-title-top-clip: a title of several lines starts where a one-line title does" begin
		for style in (:default, :ieee)
			fig = with_style(style) do
				f = plot_scatter(x, x; xlabel = "x", ylabel = "y")
				title!(f, "Two-line\nfigure title")
				f
			end
			PS._finalize_figure!(fig)
			@test PS._finalize_figure!(fig) === false
			t = sd(pl(fig).layout.fields[:title])
			size = PS._legend_title_font_size(pl(fig), t)
			# plotly.js puts the first line's baseline on the anchor (a one-line
			# title's 0.7 em lower): the pad holds that shift
			@test abs(sd(t[:pad])[:t] - (PS._TEXT_TITLE_TOP_PAD + 0.7 * size)) <= 1e-3
			# the margin holds the drawn band, so plotly.js does not push it
			# (a push moved every line up by a further 1.65 em)
			@test sd(pl(fig).layout.fields[:margin])[:t] >= sd(t[:pad])[:t] + PS._text_extent(t[:text], size)[2]
			# one line again: the pad title! gives
			title!(fig, "One line")
			PS._finalize_figure!(fig)
			@test sd(sd(pl(fig).layout.fields[:title])[:pad])[:t] == PS._TEXT_TITLE_TOP_PAD
			@test PS._finalize_figure!(fig) === false
		end
	end

	@testset "v7: titles and labels of a row share a baseline above a cell legend (topo_response, optical_bars)" begin
		# (a) and the cell title of (1, 1) were drawn a legend's height lower
		# than (b), which sits above the outside_top legend of (1, 2).
		xs = collect(range(0, 1; length = 30))
		label(c) = "plotlysupply:panel_label:1:$(c)"
		for style in (:default, :ieee), legend_cell in (2, 1)
			sf = with_style(style) do
				sf = subplots(1, 2; sync = false)
				plot_scatter!(sf, xs, xs .^ 2; row = 1, col = 1, legend = "square", xlabel = "x", ylabel = "y")
				plot_scatter!(sf, xs, [xs, 1 .- xs]; row = 1, col = 2, legend = ["radiated", "TM\$_0\$ reflected"],
					xlabel = "x", ylabel = "y")
				title!(sf, "reduced model"; row = 1, col = 1)
				set_legend!(sf; row = 1, col = legend_cell, position = :outside_top, ncols = 2)
				panel_labels!(sf; labels = :abc, format = "({})", bold = true)
				sf
			end
			PS._finalize_figure!(sf)
			@test PS._finalize_figure!(sf) === false
			a, b = only(named(sf, label(1))), only(named(sf, label(2)))
			@test a[:yref] == b[:yref] == "paper" && a[:yanchor] == b[:yanchor] == "bottom"
			@test abs(a[:y] - b[:y]) <= 1e-6
			@test get(a, :yshift, 0) == get(b, :yshift, 0)
			# above the legend of its own cell, and nothing changed beyond the
			# raise of the other cell's line
			plan = PS._room_plan(sf)
			lines = Dict(d.area => d for d in PS._lt_decorations(plan) if d.role === :line)
			other = legend_cell == 2 ? :xaxis : :xaxis2
			own = legend_cell == 2 ? :xaxis2 : :xaxis
			rise = PS._lt_expected_offset(plan, PS._lt_decorations(plan), own, :top, PS._LT_ORDER_LINE) -
				PS._lt_expected_offset(plan, PS._lt_decorations(plan), other, :top, PS._LT_ORDER_LINE)
			@test rise > 10                                  # the legend's band
			@test all(entry -> entry[3] >= rise - 1e-9, lines[other].data)
		end
	end

	@testset "v7 vm-03: panel label (a) beside a math cell title stays on the page" begin
		# :ieee 2 x 2 grid, math cell titles, a math legend in (1, 1), a
		# heatmap in (2, 1): label (a) was pushed 16.15 px left of the
		# plot area with a 4 px margin (only "a)" drawn).
		xs = range(0, 1; length = 40)
		hx = range(0, 4; length = 81); hy = range(0, 2; length = 41)
		U = [abs(sin(2a) * cos(3b)) for a in hx, b in hy]
		sf = with_style(:ieee) do
			sf = subplots(2, 2; sync = false, subplot_titles = ["Mesh \$h = 0.1\$", "Mesh \$h = 0.05\$", "Error map", "Convergence"])
			plot_scatter!(sf, xs, sin.(4xs); row = 1, col = 1, legend = "\$u_h\$")
			plot_scatter!(sf, xs, sin.(4xs); row = 1, col = 2)
			plot_heatmap!(sf, hx, hy, U; row = 2, col = 1)
			plot_scatter!(sf, xs, xs .^ 2; row = 2, col = 2)
			panel_labels!(sf)
			sf
		end
		byname = Dict(a[:name] => a for a in annotations(sf) if haskey(a, :name))
		a, c = byname["plotlysupply:panel_label:1:1"], byname["plotlysupply:panel_label:2:1"]
		@test get(a, :xshift, 0) == get(c, :xshift, 0)
		@test PS._finalize_figure!(sf) === false
	end
end
