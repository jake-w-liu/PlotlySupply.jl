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
		@test t[:mode] == "lines" && sd(t[:line])[:color] == "red" && sd(t[:line])[:dash] == "dash" && sd(t[:line])[:width] == 3
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
		@test sd(fig.data[end].fields[:line])[:color] == "blue"
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
		@test d[:orientation] == "h" && d[:entrywidth] ≈ 1 / 3 && d[:entrywidthmode] == "fraction"
		@test (d[:x], d[:y]) == placed                      # position kept
		set_legend!(fig; entrywidth = 80, itemwidth = 40)
		d = lg(fig)
		@test d[:entrywidth] == 80 && d[:entrywidthmode] == "pixels" && d[:itemwidth] == 40
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
		@test d[:x] ≈ t12.xdomain[1] + 1.03 * (t12.xdomain[2] - t12.xdomain[1])
		@test d[:xanchor] == "left" && d[:y] ≈ t12.ydomain[2]
		# A3 per-cell ncols: entry width scaled to the cell width
		id21 = PS._legend_cell_legend_id(pl(sf), cell(sf, 2, 1))
		set_legend!(sf; row = 2, col = 1, position = :top, ncols = 2, frame = false)
		d = lg(sf, Symbol(id21))
		t21 = cell(sf, 2, 1)
		@test d[:entrywidth] ≈ (t21.xdomain[2] - t21.xdomain[1]) / 2 && d[:orientation] == "h"
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
		@test lg(sm)[:yref] == "container" && lg(sm)[:entrywidth] ≈ 0.5
		# figure-mode cell placement needs per-subplot legends
		@test throws_arg(() -> set_legend!(sm; row = 1, col = 1, position = :top), "per-subplot legends")
		# back to cell legends; the merge is undone
		set_legend!(sm; legend_target = :cell, position = :topleft)
		@test sm.per_subplot_legends
		@test count(t -> get(t.fields, :showlegend, true) !== false, pl(sm).data) == 6
		@test length(unique(t.fields[:legend] for t in pl(sm).data)) == 3
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
		@test label(1, 1)[:x] == t11.xdomain[1] && label(1, 1)[:y] == t11.ydomain[2]
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
end
