using Test, PlotlySupply
import Dates

# Regression tests for the legend audit findings (numbers are the audit ids)
# and the 2.0 legend behaviour changes C11 (outside legends re-anchored) and
# C12 (unnamed traces hidden).

@testset "regression: legends" begin
	PS = PlotlySupply
	PB = PlotlySupply.PlotlyBase
	sd(x) = PS._symbol_dict(x)
	pl(f) = PS._plot_obj(f isa SubplotFigure ? f.fig : f)
	lg(f, key = :legend) = sd(get(pl(f).layout.fields, key, nothing))
	shown(t) = get(t.fields, :showlegend, nothing) !== false
	function throws_arg(f, needle::AbstractString)
		err = try
			f()
			nothing
		catch caught
			caught
		end
		return err isa ArgumentError && occursin(needle, err.msg)
	end
	x = collect(1.0:5.0)

	@testset "#3/#213 (C11): outside legends never cover tick labels or axis titles" begin
		fig = plot_scatter(x, [x, 2x]; legend = ["a", "b"], xlabel = "x", ylabel = "y")
		set_legend!(fig; position = :outside_bottom)
		d = lg(fig)
		@test d[:yref] == "container" && d[:y] == 0 && d[:yanchor] == "bottom"
		@test d[:x] == 0.5 && d[:xanchor] == "center" && d[:orientation] == "h"
		set_legend!(fig; position = :outside_left)
		d = lg(fig)
		@test d[:xref] == "container" && d[:x] == 0 && d[:xanchor] == "left"
		@test !haskey(d, :yref) && !haskey(d, :orientation)
		set_legend!(fig; position = :outside_top)
		d = lg(fig)
		@test d[:y] > 1 && d[:yanchor] == "bottom" && d[:orientation] == "h" && !haskey(d, :xref)
		set_legend!(fig; position = :outside_right)
		d = lg(fig)
		@test d[:x] > 1 && d[:xanchor] == "left" && !haskey(d, :orientation)
		set_legend!(fig; position = :outside_bottom, orientation = :v)
		@test lg(fig)[:orientation] == "v"

		original = get_default_legend_position()
		try
			set_default_legend_position!(:outside_bottom)
			f2 = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
			@test lg(f2)[:yref] == "container" && lg(f2)[:yanchor] == "bottom"
		finally
			set_default_legend_position!(original)
		end
	end

	# The D12 room plan of `f` as `_finalize_figure!` left it, and the slot of
	# decoration `key` of the `:legend_titles` providers in it.
	plan_of(f) = PS._room_plan(f)
	slot_of(plan, key) = PS._room_slot(plan, PS._LT_OWNER, key)
	margin_t(f) = sd(pl(f).layout.fields[:margin])[:t]

	@testset "outside_top legend stays clear of the figure title (D12)" begin
		# constructor title, then a legend above the axes
		fig = plot_scatter(x, [x, 2x]; legend = ["a", "b"], title = "T")
		set_legend!(fig; position = :outside_top)
		p = pl(fig)
		plan = plan_of(fig)
		leg, band = slot_of(plan, "legend:legend"), slot_of(plan, "figure_title")
		d = lg(fig)
		# the legend at its slot above the axes, in paper coordinates
		@test d[:yanchor] == "bottom" && get(d, :yref, "paper") == "paper"
		@test d[:y] ≈ PS._lt_outside(plan, leg.edge, leg.offset, :top)
		# the title pinned to the top of the figure, its band beyond the legend
		t = sd(p.layout.fields[:title])
		@test t[:text] == "T" && t[:y] == 1 && t[:yanchor] == "top"
		@test sd(t[:pad])[:t] == PS._TEXT_TITLE_TOP_PAD
		@test band.offset ≈ leg.offset + leg.px + PS._ROOM_GAP
		# the top margin holds both
		@test margin_t(fig) >= band.offset + band.px + PS._ROOM_GAP
		# a larger margin of the user's is never reduced
		relayout!(fig; margin_t = 300)
		set_legend!(fig; position = :outside_top)
		@test margin_t(fig) == 300

		# title! after the legend, with math
		g = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
		set_legend!(g; position = :outside_top, ncols = 2)
		title!(g, "Fit \$\\alpha\$")
		plan = plan_of(g)
		leg, band = slot_of(plan, "legend:legend"), slot_of(plan, "figure_title")
		@test band.offset ≈ leg.offset + leg.px + PS._ROOM_GAP
		@test margin_t(g) >= band.offset + band.px + PS._ROOM_GAP
		@test sd(pl(g).layout.fields[:title])[:yanchor] == "top"

		# no legend above the axes: title! leaves pad.b alone
		h = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
		title!(h, "T")
		@test !haskey(sd(sd(pl(h).layout.fields[:title])[:pad]), :b)
		# a paper-referenced title is not moved
		k = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
		relayout!(k; title = attr(text = "paper", yref = "paper"))
		set_legend!(k; position = :outside_top)
		@test !haskey(sd(pl(k).layout.fields[:title]), :pad)
		# hidden legend: nothing to clear
		m = plot_scatter(x, [x, 2x]; legend = ["a", "b"], title = "T")
		set_legend!(m; position = :outside_top, showlegend = false)
		# The constructor placed the title like `title!` (Z28); a hidden legend
		# adds no clearance (`pad.b`) to it.
		@test sd(pl(m).layout.fields[:title])[:text] == "T"
		@test !haskey(sd(sd(pl(m).layout.fields[:title])[:pad]), :b)

		# SubplotFigure figure legend above the grid, the title above it
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, x, x; legend = "a", row = 1, col = 1)
		plot_scatter!(sf, x, 2x; legend = "b", row = 1, col = 2)
		title!(sf, "Grid")
		set_legend!(sf; position = :outside_top)
		plan = plan_of(sf)
		fl, band = slot_of(plan, "figure_legend:legend"), slot_of(plan, "figure_title")
		@test lg(sf)[:y] ≈ PS._lt_outside(plan, 1.0, fl.offset, :top)
		@test band.offset ≈ fl.offset + fl.px + PS._ROOM_GAP
		@test sd(pl(sf).layout.fields[:title])[:y] == 1
		@test margin_t(sf) >= band.offset + band.px + PS._ROOM_GAP
	end

	@testset "#4/#43/#63/#82/#212 (C12): blank-named traces get no legend entry" begin
		fig = plot_scatter(x, [x, 2x])
		@test all(t -> t.fields[:showlegend] === false, fig.data)
		@test get(fig.layout.fields, :showlegend, nothing) !== true
		named = plot_scatter(x, [x, 2x]; legend = ["a", ""])
		@test shown(named.data[1]) && named.data[2].fields[:showlegend] === false
		# hold-on: an unnamed series appended to a named figure
		plot_scatter!(named, x, 3x)
		@test named.data[end].fields[:showlegend] === false
		# nested series and other constructors
		@test all(t -> t.fields[:showlegend] === false, plot_bar([[1.0, 2.0], [2.0, 1.0]]).data)
		# raw traces without a `name`, explicit showlegend and pie slices are untouched
		raw = PB.Plot([PB.scatter(x = x, y = x), PB.scatter(x = x, y = x, name = "", showlegend = true), PB.pie(values = [1, 2], name = "")])
		PS._apply_default_legend!(raw)
		@test !haskey(raw.data[1].fields, :showlegend)
		@test raw.data[2].fields[:showlegend] === true
		@test !haskey(raw.data[3].fields, :showlegend)
		# set_legend! hides them too (full transaction path)
		raw2 = PB.Plot([PB.scatter(x = x, y = x, name = "a"), PB.scatter(x = x, y = x, name = " ")])
		set_legend!(raw2)
		@test raw2.data[2].fields[:showlegend] === false
	end

	@testset "#72/#103/#303: unnamed plot_stem has no stray legend entry" begin
		fig = plot_stem([3.0, 1.0, 2.0])
		@test !any(t -> PS._trace_will_showlegend(t), fig.data)
		fig2 = plot_scatter(x, x; legend = "named")
		plot_stem!(fig2, [3.0, 1.0, 2.0])
		@test count(t -> PS._trace_will_showlegend(t), fig2.data) == 1
	end

	@testset "#6/#17/#268/#300: set_legend!(sf; showlegend) and C6 keyword names" begin
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, x, x; legend = "a", row = 1, col = 1)
		plot_scatter!(sf, x, 2x; legend = "b", row = 1, col = 2)
		@test set_legend!(sf; showlegend = false) === sf
		@test pl(sf).layout.fields[:showlegend] === false
		set_legend!(sf; showlegend = true)
		@test pl(sf).layout.fields[:showlegend] === true
		# subplot_legends! takes showlegend and set_legend!'s keyword names
		@test subplot_legends!(sf; position = :bottomleft, inset = (0.05, 0.05), bgcolor = "white", showlegend = true) === sf
		@test lg(sf)[:bgcolor] == "white" && lg(sf, :legend2)[:bgcolor] == "white"
		@test lg(sf)[:xanchor] == "left" && lg(sf)[:yanchor] == "bottom"
		# 1.x names are deprecated aliases; giving both is an error
		subplot_legends!(sf; legend_bgcolor = "black")
		@test lg(sf)[:bgcolor] == "black"
		@test throws_arg(() -> subplot_legends!(sf; bgcolor = "red", legend_bgcolor = "blue"), "deprecated alias")
		@test throws_arg(() -> subplot_legends!(sf; show = true), "subplot_legends!: `show` is not supported")
		@test_throws MethodError subplot_legends!(sf; legend_position = :top)
		# the Plot method has the same keywords
		raw = pl(sf)
		p2 = deepcopy(raw)
		@test subplot_legends!(p2; position = :topleft, ncols = 1, showlegend = false) === p2
		@test p2.layout.fields[:showlegend] === false
	end

	@testset "#1/#12/#23/#31/#264: secondary-y and later traces use their cell's legend" begin
		sf = subplots(1, 2; sync = false, specs = [PB.Spec() PB.Spec(secondary_y = true)])
		plot_scatter!(sf, x, x; legend = "left", row = 1, col = 1)
		plot_scatter!(sf, x, x; legend = "right-sec", row = 1, col = 2, secondary_y = true)
		plot_scatter!(sf, x, 2x; legend = "right", row = 1, col = 2)
		ids = Dict(t.fields[:name] => t.fields[:legend] for t in pl(sf).data)
		@test ids["right-sec"] == ids["right"] != ids["left"]
		# legend boxes exist for exactly two cells, inside each cell
		boxes = [k for k in keys(pl(sf).layout.fields) if k === :legend || occursin(PS._LEGEND_ID_PATTERN, String(k))]
		@test length(boxes) == 2
		right_box = lg(sf, Symbol(ids["right"]))
		@test right_box[:x] > 0.5

		# a figure-mode canvas switched to per-subplot legends keeps routing later traces
		sg = subplots(1, 2; sync = false, per_subplot_legends = false)
		plot_scatter!(sg, x, x; legend = "a", row = 1, col = 1)
		plot_scatter!(sg, x, 2x; legend = "b", row = 1, col = 2)
		subplot_legends!(sg)
		@test sg.per_subplot_legends
		plot_scatter!(sg, x, 3x; legend = "late", row = 1, col = 2)
		add_trace!(sg, PB.scatter(x = x, y = 4x, name = "added"); row = 1, col = 2)
		ids = Dict(t.fields[:name] => t.fields[:legend] for t in pl(sg).data)
		@test ids["late"] == ids["b"] == ids["added"] != ids["a"]
	end

	@testset "#16: relayout! customisations survive later appends" begin
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, x, x; legend = "a", row = 1, col = 1)
		plot_scatter!(sf, x, 2x; legend = "b", row = 1, col = 2)
		relayout!(sf.fig; legend = attr(bgcolor = "red", x = 0.1, xanchor = "left"), legend2 = attr(bordercolor = "blue", y = 0.5))
		plot_scatter!(sf, x, 3x; legend = "c", row = 1, col = 2)
		add_trace!(sf, PB.scatter(x = x, y = 4x, name = "d"); row = 1, col = 1)
		@test lg(sf)[:bgcolor] == "red" && lg(sf)[:x] == 0.1 && lg(sf)[:xanchor] == "left"
		@test lg(sf, :legend2)[:bordercolor] == "blue" && lg(sf, :legend2)[:y] == 0.5
		# once the ids are renumbered (cell (1,1) emptied), the reused box is re-placed
		deletetraces!(sf.fig, 1, length(pl(sf).data))   # drop "a" and "d"
		plot_scatter!(sf, x, 5x; legend = "e", row = 1, col = 2)
		@test all(t -> t.fields[:legend] == "legend", pl(sf).data)
		@test lg(sf)[:x] > 0.5 && lg(sf)[:bgcolor] != "red"
	end

	@testset "#216/#266 (legend part): legend boxes follow dark templates" begin
		dark = PS._template_legend_colors(PB.templates[:plotly_dark])
		original = get_default_template()
		try
			set_default_template!(:plotly_dark)
			fig = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
			@test lg(fig)[:bgcolor] == dark.bgcolor && lg(fig)[:bordercolor] == dark.bordercolor
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, x, x; legend = "a", row = 1, col = 1)
			plot_scatter!(sf, x, 2x; legend = "b", row = 1, col = 2)
			@test lg(sf)[:bgcolor] == dark.bgcolor && lg(sf, :legend2)[:bgcolor] == dark.bgcolor
		finally
			set_default_template!(original)
		end
		@test dark.bgcolor != PS._DEFAULT_LEGEND_BGCOLOR[]
		# the figure's own template wins (Template object or "+"-compound name)
		fig = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
		relayout!(fig; template = PB.templates[:plotly_dark])
		set_legend!(fig; frame = true)
		@test lg(fig)[:bgcolor] == dark.bgcolor
		fig.layout.fields[:template] = "plotly_dark+xgridoff"
		set_legend!(fig; frame = false)
		set_legend!(fig; frame = true)
		@test lg(fig)[:bgcolor] == dark.bgcolor
	end

	@testset "#2/#13/#26/#32: figure-mode legend uses the stored settings" begin
		sf = subplots(1, 2; sync = false, per_subplot_legends = false, legend_position = :outside_bottom, legend_bgcolor = "rgb(255,0,0)")
		plot_scatter!(sf, x, x .^ 2; legend = "only", row = 1, col = 2)
		# the figure-mode pass the subplot delegate runs after appending traces
		PS._refresh_subplot_legends!(sf, pl(sf); first_new = 1)
		d = lg(sf)
		@test d[:yref] == "container" && d[:bgcolor] == "#FF0000"
		@test pl(sf).layout.fields[:showlegend] === true
		# an explicit set_legend!(sf) applies them as well
		sg = subplots(1, 2; sync = false, per_subplot_legends = false, legend_position = :outside_left)
		plot_scatter!(sg, x, x; legend = "only", row = 1, col = 1)
		set_legend!(sg)
		@test lg(sg)[:xref] == "container" && pl(sg).layout.fields[:showlegend] === true
	end

	@testset "_normalize_legend_position rejects non-names" begin
		@test throws_arg(() -> PS._normalize_legend_position(1.5), "must be a Symbol or a string")
		@test PS._normalize_legend_position(" Top-Left ") === :topleft
		@test (@test_logs (:warn,) match_mode = :any PS._normalize_legend_position("sideways")) === :topright
	end

	ann(f, name) = only(filter(a -> get(a, :name, "") == name, [sd(a) for a in pl(f).layout.fields[:annotations]]))

	@testset "D12/G60: panel titles and labels stack above a cell legend above the axes" begin
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, x, x; legend = "a", row = 1, col = 1)
		plot_scatter!(sf, x, [x, 2x]; legend = ["model", "measured"], row = 1, col = 2)
		title!(sf, "(b) Ellipse"; row = 1, col = 2, align = :left)
		panel_labels!(sf)
		decor(plan, key) = only(d for d in PS._lt_decorations(plan) if d.key == key)
		raise_of(plan, key, name) = only(e[3] for e in decor(plan, key).data if e[1] == name)
		# nothing below the title yet: at the top edge, with its own gap; the
		# label beside the left-aligned title sits over the y tick labels, so
		# the line rises clear of the top one
		plan = plan_of(sf)
		line = slot_of(plan, "line:xaxis2")
		raise = raise_of(plan, "line:xaxis2", "plotlysupply:title:1:2")
		@test line.offset + raise >= PS._LT_TICK_REACH * PS._lt_y_tick_font(plan, plan.areas[:xaxis2], :left) + 1 - 1e-9
		@test ann(sf, "plotlysupply:title:1:2")[:y] ≈ PS._lt_outside(plan, line.edge, line.offset - PS._ROOM_GAP + raise, :top)
		@test line.offset == PS._ROOM_GAP
		@test ann(sf, "plotlysupply:title:1:2")[:yshift] == PS._TEXT_PANEL_GAP
		set_legend!(sf; row = 1, col = 2, position = (0.5, 1.0), yanchor = "bottom", orientation = :h)
		lh = PS._legend_box_height(pl(sf), "legend2")
		@test lh > 16
		# order above the axes: the legend, then the title line
		plan = plan_of(sf)
		leg, line = slot_of(plan, "legend:legend2"), slot_of(plan, "line:xaxis2")
		@test leg.px ≈ lh && line.offset ≈ leg.offset + leg.px + PS._ROOM_GAP
		@test lg(sf, :legend2)[:y] ≈ PS._lt_outside(plan, leg.edge, leg.offset, :top)
		title_y = ann(sf, "plotlysupply:title:1:2")[:y]
		@test title_y ≈ PS._lt_outside(plan, line.edge, line.offset - PS._ROOM_GAP, :top)
		# the label rides on the title's line; the label of the other cell
		# (no legend above it) keeps its slot and rises onto the same line
		# (topo_response, optical_bars)
		@test ann(sf, "plotlysupply:panel_label:1:2")[:y] == title_y
		other = slot_of(plan, "line:xaxis")
		@test other.offset == PS._ROOM_GAP
		@test ann(sf, "plotlysupply:panel_label:1:1")[:y] ≈ title_y
		@test !PS._text_restack!(sf)                                             # idempotent
		# a higher user offset is kept
		title!(sf, "(b) Ellipse"; row = 1, col = 2, align = :left, offset = (0, 80))
		@test ann(sf, "plotlysupply:title:1:2")[:yshift] == PS._TEXT_PANEL_GAP + 80
		# entries added later grow the legend and the stack follows
		plot_scatter!(sf, x, 3x; legend = "a much longer third entry name", row = 1, col = 2)
		@test PS._legend_box_height(pl(sf), "legend2") >= lh
		plan = plan_of(sf)
		leg, line = slot_of(plan, "legend:legend2"), slot_of(plan, "line:xaxis2")
		# now wider than the cell, the legend rises clear of the top y tick label
		lift = decor(plan, "legend:legend2").data.lift
		@test lift > 0 && leg.offset + lift >= PS._LT_TICK_REACH * PS._lt_y_tick_font(plan, plan.areas[:xaxis2], :left) + 1 - 1e-9
		@test leg.px ≈ PS._legend_box_height(pl(sf), "legend2") + lift
		@test lg(sf, :legend2)[:y] ≈ PS._lt_outside(plan, leg.edge, leg.offset + lift, :top)
		@test line.offset ≈ leg.offset + leg.px + PS._ROOM_GAP
		@test ann(sf, "plotlysupply:panel_label:1:2")[:y] ≈ PS._lt_outside(plan, line.edge, line.offset - PS._ROOM_GAP, :top)

		# Z15: a top x axis (secondary_xaxis!) added after the title, then the
		# legend above it (order: axis, legend, title)
		ss = subplots(1, 2; sync = false)
		plot_scatter!(ss, x, [x, 2x]; legend = ["model", "data"], row = 1, col = 1)
		plot_scatter!(ss, x, x; legend = "z", row = 1, col = 2)
		title!(ss, "(a) top axis"; row = 1, col = 1, align = :left)
		before = ann(ss, "plotlysupply:title:1:1")[:y]
		secondary_xaxis!(ss, v -> 2v, v -> v / 2; title = "frequency (Hz)", row = 1, col = 1)
		plan = plan_of(ss)
		depth = plan.areas[:xaxis].own[:top]
		@test depth > 20
		line = slot_of(plan, "line:xaxis")
		@test line.offset ≈ PS._room_label_px(depth) + PS._ROOM_GAP
		@test ann(ss, "plotlysupply:title:1:1")[:y] > before
		@test ann(ss, "plotlysupply:title:1:1")[:y] ≈ PS._lt_outside(plan, line.edge, line.offset - PS._ROOM_GAP, :top)
		set_legend!(ss; row = 1, col = 1, position = (0.5, 1.0), xanchor = "center", yanchor = "bottom", orientation = :h)
		plan = plan_of(ss)
		leg, line = slot_of(plan, "legend:legend"), slot_of(plan, "line:xaxis")
		@test leg.offset ≈ PS._room_label_px(plan.areas[:xaxis].own[:top]) + PS._ROOM_GAP
		@test line.offset ≈ leg.offset + leg.px + PS._ROOM_GAP
		@test lg(ss)[:y] ≈ PS._lt_outside(plan, leg.edge, leg.offset, :top)
		@test ann(ss, "plotlysupply:title:1:1")[:y] ≈ PS._lt_outside(plan, line.edge, line.offset - PS._ROOM_GAP, :top)
		@test !PS._text_restack!(ss)
	end

	@testset "D12/G38: an :outside_top figure legend goes above the panel titles, under the figure title" begin
		sg = subplots(1, 2; sync = false, per_subplot_legends = false)
		figsize!(sg, 7.2, 4.0; units = :in)
		for c in 1:2
			plot_scatter!(sg, x, x .* c; legend = "run $(c)", row = 1, col = c)
		end
		set_legend!(sg; position = :outside_top)
		@test lg(sg)[:y] > 1 && !haskey(lg(sg), :yref)
		title!(sg, "(a) structured meshes"; row = 1, col = 1)
		plan = plan_of(sg)
		fl, line = slot_of(plan, "figure_legend:legend"), slot_of(plan, "line:xaxis")
		box = lg(sg)
		@test get(box, :yref, "paper") == "paper" && box[:yanchor] == "bottom" && box[:x] == 0.5
		# above the panel title line, which is above the axes
		@test fl.offset ≈ line.offset + line.px + PS._ROOM_GAP
		@test box[:y] ≈ PS._lt_outside(plan, 1.0, fl.offset, :top)
		@test margin_t(sg) >= fl.offset + fl.px + PS._ROOM_GAP
		# a figure title goes on top, beyond the legend
		title!(sg, "Convergence")
		plan = plan_of(sg)
		fl, band = slot_of(plan, "figure_legend:legend"), slot_of(plan, "figure_title")
		@test band.offset ≈ fl.offset + fl.px + PS._ROOM_GAP
		@test lg(sg)[:y] ≈ PS._lt_outside(plan, 1.0, fl.offset, :top)
		@test !haskey(sd(sd(pl(sg).layout.fields[:title])[:pad]), :b)
		@test margin_t(sg) >= band.offset + band.px + PS._ROOM_GAP
		@test !PS._text_restack!(sg)
		# tight_layout! keeps that room
		tight_layout!(sg)
		plan = plan_of(sg)
		band = slot_of(plan, "figure_title")
		@test margin_t(sg) >= band.offset + band.px + PS._ROOM_GAP
		@test !PS._text_restack!(sg)
		# a legend the user placed elsewhere is not moved
		set_legend!(sg; position = (0.2, 1.1))
		@test lg(sg)[:y] == 1.1 && get(lg(sg), :yref, "paper") == "paper"

		# single figure: an outside panel label goes on the line above the legend
		f = plot_scatter(x, [x, 2x]; legend = ["model", "data"])
		set_legend!(f; position = :outside_top)
		@test get(lg(f), :yref, "paper") == "paper"
		panel_labels!(f)
		plan = plan_of(f)
		leg, line = slot_of(plan, "legend:legend"), slot_of(plan, "line:xaxis")
		@test line.offset ≈ leg.offset + leg.px + PS._ROOM_GAP
		@test get(lg(f), :yref, "paper") == "paper" && lg(f)[:y] ≈ PS._lt_outside(plan, leg.edge, leg.offset, :top)
	end

	# Rendered geometry of the SVG `savefig` exports (K6: measured from that SVG,
	# laid out in the export window, not from whatever the window shows), in px
	# from the top-left corner of the figure. `legends`: the background box of
	# each legend; `ann`: the text box of each annotation; `xtitle`: every x
	# axis title; `ytitle`: every y axis title; `points`: every marker;
	# `plots`: every plot area; `ticks`: every tick label; `colorbars`: every
	# colorbar (bar, ticks and title); `gtitle`: the figure title (`nothing`
	# without one); `W`/`H`: the figure size.
	export_geometry_js = raw"""
	(function(svgText){
	var c=document.createElement('div');
	c.style.position='absolute';c.style.left='0px';c.style.top='0px';
	c.innerHTML=svgText;document.body.appendChild(c);
	try{
	var root=c.querySelector('svg');var R=root.getBoundingClientRect();
	var b=function(e){if(!e)return null;var r=e.getBoundingClientRect();
	 if(r.width===0&&r.height===0)return null;return [r.left-R.left,r.top-R.top,r.right-R.left,r.bottom-R.top];};
	var cls=function(e){return (e.getAttribute('class')||'').split(' ')[0];};
	var out={W:R.width,H:R.height,legends:[],ann:[],xtitle:[],ytitle:[],points:[],plots:[],ticks:[],colorbars:[],gtitle:null};
	c.querySelectorAll('g.infolayer > g').forEach(function(g){
	 var k=cls(g),bx;
	 if(/^legend[0-9]*$/.test(k)){bx=b(g.querySelector('rect.bg'))||b(g);if(bx)out.legends.push(bx);}
	 else if(/^g-x[0-9]*title$/.test(k)){bx=b(g);if(bx)out.xtitle.push(bx);}
	 else if(/^g-y[0-9]*title$/.test(k)){bx=b(g);if(bx)out.ytitle.push(bx);}
	 else if(k==='g-gtitle'){out.gtitle=b(g);}
	});
	c.querySelectorAll('g.annotation').forEach(function(a){var bx=b(a.querySelector('g.annotation-text-g'));if(bx)out.ann.push(bx);});
	c.querySelectorAll('path.point').forEach(function(e){var bx=b(e);if(bx)out.points.push(bx);});
	c.querySelectorAll('g.colorbar').forEach(function(g){var bx=b(g);if(bx)out.colorbars.push(bx);});
	['xaxislayer-above','yaxislayer-above'].forEach(function(layer){
	 c.querySelectorAll('g.'+layer+' text').forEach(function(t){var bx=b(t);if(bx)out.ticks.push(bx);});});
	c.querySelectorAll('g.overplot > g').forEach(function(pg){
	 var m=/translate\(([-0-9.e]+)[ ,]+([-0-9.e]+)\)/.exec(pg.getAttribute('transform')||'');
	 var id=/url\(['"]?#([^'")]+)['"]?\)/.exec(pg.getAttribute('clip-path')||'');
	 var r=id?c.querySelector('clipPath[id="'+id[1]+'"] rect'):null;
	 if(m&&r){var x=+m[1],y=+m[2];out.plots.push([x,y,x+(+r.getAttribute('width')),y+(+r.getAttribute('height'))]);}
	});
	return JSON.stringify(out);
	}finally{c.remove();}
	})
	"""
	function export_boxes(fig; kwargs...)
		svg = String(savefig(fig; format = "svg", kwargs...))
		raw = PS._with_export_window(PS._EXPORT_STATE) do ec, app, win, divid
			Base.invokelatest(() -> ec.run(win, export_geometry_js * "(" * PS._json_js(svg) * ")"))
		end
		return PB.JSON.parse(String(raw))
	end
	overlaps(a, b) = a !== nothing && b !== nothing &&
		min(a[3], b[3]) - max(a[1], b[1]) > 0.5 && min(a[4], b[4]) - max(a[2], b[2]) > 0.5

	@testset "G13/G38/G57/G60 export geometry: legends, titles and labels do not overlap" begin
		# G13: an :outside_bottom legend sits below the x title, with and without ncols
		for ncols in (0, 2)
			fig = plot_scatter(x, [x, 2x, 3x]; legend = ["model", "data", "fit"], xlabel = "time (s)")
			set_legend!(fig; position = :outside_bottom, ncols = ncols)
			b = export_boxes(fig)
			@test length(b["legends"]) == 1 && length(b["xtitle"]) == 1
			@test b["legends"][1][2] >= b["xtitle"][1][4]
		end

		# G38: figure legend above two panel titles, figure title on top
		sg = subplots(1, 2; sync = false, per_subplot_legends = false)
		for c in 1:2
			plot_scatter!(sg, x, x .* c; row = 1, col = c)
		end
		title!(sg, "(a) structured meshes"; row = 1, col = 1)
		title!(sg, "(b) perturbed meshes"; row = 1, col = 2)
		for lab in ("macroelement, unit square", "mixed enhanced strain, unit square",
			"macroelement, Cook's membrane", "mixed enhanced strain, Cook's membrane")
			legend_entry!(sg, lab; legend_target = :figure)
		end
		set_legend!(sg; position = :outside_top, ncols = 2, frame = false, legend_target = :figure)
		title!(sg, "Convergence of the mixed elements")
		b = export_boxes(sg)
		@test !isempty(b["legends"]) && length(b["ann"]) == 2 && b["gtitle"] !== nothing
		@test !any(overlaps(L, a) for L in b["legends"], a in b["ann"])
		@test !any(overlaps(L, b["gtitle"]) for L in b["legends"])
		@test all(a -> a[2] >= 0, b["ann"])

		# G57/G60: a two-column cell legend above (a), panel labels, a figure legend above
		sh = subplots(1, 3; sync = false)
		for c in 1:3
			plot_scatter!(sh, x, [x, 2x]; legend = ["model $(c)", "data $(c)"], row = 1, col = c)
		end
		# the cell is 173 px wide, but a legend above it may reach into the left
		# margin: the two columns (about 180 px) fit, without a warning
		@test_logs set_legend!(sh; row = 1, col = 1,
			position = (1.0, 1.0), xanchor = "right", yanchor = "bottom", ncols = 2)
		@test any(t -> get(t.fields, :legendgroup, "") == "plotlysupply:col:legend:c:2/2", pl(sh).data)
		# a cell legend inside its axes keeps the cell width: one column, with a warning
		sn = subplots(1, 3; sync = false)
		plot_scatter!(sn, x, [x, 2x]; legend = ["model 1", "data 1"], row = 1, col = 1)
		@test_logs (:warn, r"2 legend columns .* using 1\.") set_legend!(sn; row = 1, col = 1,
			position = :topleft, ncols = 2)
		legend_entry!(sh, "Newton"; legend_target = :figure, color = "red")
		set_legend!(sh; legend_target = :figure, position = :outside_top)
		panel_labels!(sh; bold = true)
		title!(sh, "(b) middle"; row = 1, col = 2, align = :left)
		b = export_boxes(sh)
		@test length(b["legends"]) == 4 && length(b["ann"]) == 4
		@test !any(overlaps(b["legends"][i], b["legends"][j]) for i in 1:4, j in 1:4 if i < j)
		@test !any(overlaps(L, a) for L in b["legends"], a in b["ann"])
		@test !any(overlaps(b["ann"][i], b["ann"][j]) for i in 1:4, j in 1:4 if i < j)
		@test all(a -> a[2] >= 0, b["ann"])
	end

	# The cell legend `key` of `f` sits where `_legend_placement` puts `position`
	# in its cell (the package default inset).
	function placed_at(f, key::Symbol, position::Symbol)
		p = pl(f)
		trace = first(t for t in p.data if get(t.fields, :legend, nothing) == String(key))
		_, (xd, yd) = PS._trace_subplot_key_domain(p, trace)
		want = PS._legend_placement(position, xd, yd, PS._DEFAULT_LEGEND_INSET[]; figure = false)
		have = lg(f, key)
		return all(k -> get(have, k, nothing) == get(want, k, nothing), PS._LEGEND_PLACEMENT_KEYS)
	end

	@testset "Y17: SubplotFigure cell legends go where they cover no data" begin
		# A rising curve takes the top right of its cell, a falling one the top left.
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, 1:10, (1:10) .^ 2; row = 1, col = 1, legend = "rising", mode = "lines+markers")
		plot_scatter!(sf, 1:10, 10 .- (1:10); row = 1, col = 2, legend = "falling", mode = "lines+markers")
		@test placed_at(sf, :legend, :topleft)
		@test placed_at(sf, :legend2, :topright)
		b = export_boxes(sf)
		@test length(b["legends"]) == 2 && length(b["points"]) == 20
		@test !any(overlaps(L, q) for L in b["legends"], q in b["points"])

		# An automatic cell legend follows its cell's data on later appends ...
		sg = subplots(1, 2; sync = false)
		plot_scatter!(sg, 1:10, 10 .- (1:10); row = 1, col = 1, legend = "falling")
		@test placed_at(sg, :legend, :topright)
		plot_scatter!(sg, 1:10, 1:10; row = 1, col = 1, legend = "rising")
		@test placed_at(sg, :legend, :right)
		plot_scatter!(sg, 1:10, fill(5.5, 10); row = 1, col = 1, legend = "flat")
		@test placed_at(sg, :legend, :bottom)
		# ... appends to another cell leave it alone ...
		plot_scatter!(sg, 1:10, 1:10; row = 1, col = 2, legend = "other")
		@test placed_at(sg, :legend, :bottom) && placed_at(sg, :legend2, :topleft)
		# ... and a position the user chose stays.
		set_legend!(sg; row = 1, col = 1, position = :topright)
		plot_scatter!(sg, 1:10, (1:10) .^ 0.5; row = 1, col = 1, legend = "root")
		@test placed_at(sg, :legend, :topright)
		relayout!(sg, legend2 = attr(x = 0.7, y = 0.5))
		plot_scatter!(sg, 1:10, 10 .- (1:10); row = 1, col = 2, legend = "falling 2")
		@test (lg(sg, :legend2)[:x], lg(sg, :legend2)[:y]) == (0.7, 0.5)

		# A secondary y axis counts: the crossing lines leave only the right edge free.
		ss = subplots(1, 1; sync = false, specs = fill(Spec(secondary_y = true), 1, 1))
		plot_scatter!(ss, 1:10, 1:10; row = 1, col = 1, legend = "primary rising")
		@test placed_at(ss, :legend, :topleft)
		plot_scatter!(ss, 1:10, 100 .* (10 .- (1:10)); row = 1, col = 1, secondary_y = true, legend = "secondary falling")
		@test placed_at(ss, :legend, :right)

		# A `fill = "toself"` area (a band) counts as covered, in a Plot and in a cell.
		band = plot_band(1:3, 0, [1, 2, 3]; legend = "b")
		@test (lg(band)[:x], lg(band)[:xanchor]) == (0.02, "left")
		sb = subplots(1, 2; sync = false)
		plot_band!(sb, 1:3, 0, [1, 2, 3]; row = 1, col = 2, legend = "b")
		@test placed_at(sb, :legend, :topleft)

		# Bars are scored (v7 vm-05): the tallest bar, at the right, leaves the
		# top left free.
		sk = subplots(1, 2; sync = false)
		plot_bar!(sk, ["a", "b", "c"], [1, 2, 3]; row = 1, col = 1, legend = "bars")
		@test placed_at(sk, :legend, :topleft)
		# Traces the estimate does not model (a histogram plotly.js bins) keep
		# the default corner.
		sk = subplots(1, 2; sync = false)
		plot_histogram!(sk, [0.1, 0.5, 0.5, 0.9, 0.9, 0.9]; row = 1, col = 1, legend = "samples")
		@test placed_at(sk, :legend, :topright)
		# The rule is off while the default position is not :topright.
		set_default_legend_position!(:topleft)
		try
			sd2 = subplots(1, 1; sync = false)
			plot_scatter!(sd2, 1:10, 10 .- (1:10); row = 1, col = 1, legend = "falling")
			@test placed_at(sd2, :legend, :topleft)
		finally
			set_default_legend_position!(:topright)
		end
	end

	@testset "Y17: polar cell legends avoid data and tick labels" begin
		# Points at 50-70 degrees on the rim of a square polar cell take its top
		# right corner, and a wide legend in another corner covers an angular tick
		# label (135, 225 or 315 degrees): it goes to the bottom edge, over grid only.
		sp = subplots(1, 1; sync = false, specs = fill(Spec(kind = "polar"), 1, 1))
		relayout!(sp, width = 500, height = 500)
		plot_scatterpolar!(sp, [50, 60, 70], [1, 1, 1]; row = 1, col = 1, legend = "measured pattern (dB)", mode = "markers")
		@test placed_at(sp, :legend, :bottom)
		b = export_boxes(sp)
		@test length(b["legends"]) == 1 && length(b["points"]) == 3
		@test !any(overlaps(b["legends"][1], q) for q in b["points"])
		# A roomy polar cell keeps the top right corner (it covers nothing there).
		sq = subplots(1, 2; sync = false, specs = [Spec() Spec(kind = "polar")])
		plot_scatterpolar!(sq, 0:30:330, fill(1.0, 12); row = 1, col = 2, legend = "pattern", mode = "markers")
		@test placed_at(sq, :legend, :topright)
		# No free position (the legend is wider than the room beside the disk):
		# v7 vm-06, beside the cell (it was the corner covering the fewest
		# points, then the fewest tick labels: on a tick label).
		sr = subplots(2, 2; sync = false, specs = [Spec() Spec(kind = "polar"); Spec(secondary_y = true) Spec()])
		plot_scatter!(sr, 1:5, [1, 4, 9, 16, 25]; row = 1, col = 1, legend = "(1,1)", mode = "lines+markers")
		plot_scatterpolar!(sr, 0:30:330, fill(1.0, 12); row = 1, col = 2, legend = "polar", mode = "markers")
		@test placed_at(sr, :legend, :topleft)
		polar_x = sd(sd(pl(sr).layout.fields[:polar])[:domain])[:x]
		@test lg(sr, :legend2)[:xanchor] == "left" && lg(sr, :legend2)[:x] >= polar_x[2]
		# Holes are not modelled: the default corner.
		sh = subplots(1, 1; sync = false, specs = fill(Spec(kind = "polar"), 1, 1))
		relayout!(sh, width = 500, height = 500, polar = attr(hole = 0.3))
		plot_scatterpolar!(sh, [50, 60, 70], [1, 1, 1]; row = 1, col = 1, legend = "measured pattern (dB)", mode = "markers")
		@test placed_at(sh, :legend, :topright)
	end

	@testset "G5/Y10: inset traces join the host cell legend, which avoids the inset" begin
		xs = collect(range(0, 2pi; length = 60))
		sl = subplots(1, 2; sync = false)
		plot_scatter!(sl, xs, sin.(xs); legend = "host", row = 1, col = 1)
		plot_scatter!(sl, xs, cos.(xs); legend = "right cell", row = 1, col = 2)
		subplot_legends!(sl)
		k = inset!(sl, (0.55, 0.55, 0.4, 0.4); row = 1, col = 1)
		plot_scatter!(sl, xs, xs .^ 2; inset = k, legend = "zoom")
		@test [t.fields[:legend] for t in pl(sl).data] == ["legend", "legend2", "legend"]
		@test !haskey(pl(sl).layout.fields, :legend3)
		# Y10: the host legend leaves the inset (top right) and the sine's peak
		# (top left) free.
		@test placed_at(sl, :legend, :bottomleft)
	end

	@testset "Y27: identical entries of scene cells merge into one figure legend" begin
		zs = [exp(-(a^2 + b^2)) for a in -1:0.5:1, b in -1:0.5:1]
		sf = subplots(1, 3; sync = false, specs = fill(Spec(kind = "scene"), 1, 3))
		for c in 1:3
			plot_surface!(sf, -1:0.5:1, -1:0.5:1, c .* zs; row = 1, col = c)
			plot_scatter3d!(sf, [0, 3], [0, 0], [0, 0]; color = "red", linewidth = 8, legend = "+x", row = 1, col = c)
		end
		# per-cell legends: one "+x" in each cell
		@test [get(t.fields, :legend, nothing) for t in pl(sf).data if t.fields[:type] == "scatter3d"] ==
			["legend", "legend2", "legend3"]
		set_legend!(sf; position = :outside_right)
		p = pl(sf)
		@test !sf.per_subplot_legends
		@test !any(haskey(p.layout.fields, k) for k in (:legend2, :legend3))
		lines = [t for t in p.data if t.fields[:type] == "scatter3d"]
		@test count(shown, lines) == 1
		@test length(unique(t.fields[:legendgroup] for t in lines)) == 1
		@test startswith(lines[1].fields[:legendgroup], PS._LEGEND_DEDUPE_GROUP_PREFIX)
	end

	@testset "W3: the best legend position avoids reference shapes and annotations" begin
		f = plot_scatter([0.0, 1.0, 2.0, 3.0], [0.0, 0.2, 0.1, 0.3]; legend = "data")
		yrange!(f, (0, 3))
		@test PS._scat_best_legend_position(pl(f)) === :topright          # the data is at the bottom
		# a dashed reference circle through the top right corner
		relayout!(f; shapes = [attr(type = "circle", xref = "x", yref = "y", x0 = 1.8, x1 = 3.3,
			y0 = 1.8, y1 = 3.3, line = attr(dash = "dash"))])
		@test PS._scat_best_legend_position(pl(f)) === :topleft
		# and a note at the top left: a free position is still chosen
		relayout!(f; annotations = [attr(text = "a long note text here", x = 0.3, y = 2.8, xref = "x",
			yref = "y", showarrow = false)])
		p = pl(f)
		scores = PS._scat_legend_scores(p, eachindex(p.data), :xaxis, "x", PS._scat_legend_figure_px(p.layout)...)
		index(position) = findfirst(==(position), PS._SCAT_LEGEND_POSITIONS)
		@test scores[index(:topright)] > 0 && scores[index(:topleft)] > 0
		best = PS._scat_best_legend_position(p)
		@test scores[index(best)] == 0 && minimum(scores) == 0
	end

	@testset "Z80: best legend position at 1e5 points (allocations, one scoring per append)" begin
		xs = collect(range(0, 10; length = 100_000))
		f = plot_scatter(xs, sin.(xs); legend = "sine")
		PS._scat_best_legend_position(pl(f))
		@test @allocated(PlotlySupply._scat_best_legend_position(pl(f))) < 16_000_000
		g = plot_scatter(xs, [sin.(xs), cos.(xs)]; legend = ["s", "c"], mode = "lines+markers")
		restyle!(g; line_shape = "hv")
		PS._scat_best_legend_position(pl(g))
		@test @allocated(PlotlySupply._scat_best_legend_position(pl(g))) < 16_000_000
		# The append placed the legend and remembered where: reading the state
		# again does not score the 2e5 points.
		h = plot_scatter(xs, sin.(xs); legend = "a")
		plot_scatter!(h, xs, cos.(xs); legend = "b")
		@test get(PS._SCAT_LEGEND_AUTO, PS._scat_legend_memo_key(pl(h)), nothing) === :topright
		PS._scat_legend_state(h)
		@test PS._scat_legend_state(h) === :auto
		@test @allocated(PS._scat_legend_state(h)) < 100_000
		# an explicit position is the user's: forgotten, and kept on appends
		set_legend!(h; position = :topleft)
		@test !haskey(PS._SCAT_LEGEND_AUTO, PS._scat_legend_memo_key(pl(h)))
		@test PS._scat_legend_state(h) === :fixed
		plot_scatter!(h, xs, 2 .* cos.(xs); legend = "c")
		@test lg(h)[:xanchor] == "left"
	end

	@testset "Z78: a legend over a heatmap stays clear of its colorbar" begin
		z = [sin(0.3 * i) * cos(0.25 * j) for i in 1:30, j in 1:20]
		f = plot_heatmap(collect(range(-pi, pi; length = 30)), collect(range(0, 2; length = 20)), z;
			title = "field", xlabel = "x", ylabel = "y", colorbar_title = "|E|^2 (a.u.)")
		plot_scatter!(f, [-2.0, 2.0], [0.5, 1.5]; legend = "reference", color = "white")
		b = export_boxes(f; width = 700, height = 500)
		@test length(b["legends"]) == 1 && length(b["plots"]) == 1
		legend, plot = b["legends"][1], b["plots"][1]
		# inside the plot area (plotly draws it there only when nothing is left
		# to push the margin: measured 40 px into the colorbar before)
		@test legend[1] >= plot[1] - 0.5 && legend[3] <= plot[3] + 0.5
		@test legend[2] >= plot[2] - 0.5 && legend[4] <= plot[4] + 0.5
	end

	@testset "Z48: an :outside_bottom figure legend stacks above bottom captions" begin
		function captioned(; tight = false, legend_first = false, grid = true)
			f = if grid
				sf = subplots(1, 2; sync = false)
				plot_scatter!(sf, 1:5, [1, 3, 2, 4, 3]; row = 1, col = 1, legend = "alpha", xlabel = "time t", ylabel = "y")
				plot_scatter!(sf, 1:5, [2, 1, 3, 2, 4]; row = 1, col = 2, legend = "beta", xlabel = "time t")
				sf
			else
				plot_scatter(1:5, [[1, 3, 2, 4, 3], [2, 1, 3, 2, 4]]; legend = ["alpha", "beta"], xlabel = "time t")
			end
			legend_first && set_legend!(f; position = :outside_bottom)
			annotate!(f, 0.5, 0.01, "Figure 1. A caption below the figure."; coords = :figure,
				showarrow = false, yanchor = "bottom")
			legend_first || set_legend!(f; position = :outside_bottom)
			tight && tight_layout!(f)
			return f
		end
		for kw in ((;), (legend_first = true,), (tight = true,), (grid = false,), (grid = false, tight = true))
			f = captioned(; kw...)
			d = lg(f)
			# still container-referenced at the bottom, now on the caption band
			@test d[:yref] == "container" && d[:yanchor] == "bottom" && d[:x] == 0.5
			band = 0.01 * 500 + 1.4 * 12 + PS._FIGURE_ANNOTATION_GAP
			@test d[:y] ≈ round(band / 500; digits = 6)
			b = export_boxes(f; width = 700, height = 500)
			@test length(b["legends"]) == 1 && length(b["ann"]) == 1 && !isempty(b["xtitle"])
			caption = b["ann"][1]
			@test !overlaps(b["legends"][1], caption)
			@test !any(overlaps(t, caption) || overlaps(t, b["legends"][1]) for t in b["xtitle"])
			@test !any(overlaps(q, caption) for q in b["plots"])
			# the caption stays at its figure fraction (rendered within 2 px)
			@test isapprox(500 - caption[4], 0.01 * 500; atol = 2)
			@test caption[2] >= 0 && caption[4] <= 500
		end
		# without a caption the legend keeps the bottom edge of the figure
		g = plot_scatter(1:5, [[1, 3, 2, 4, 3], [2, 1, 3, 2, 4]]; legend = ["alpha", "beta"])
		set_legend!(g; position = :outside_bottom)
		@test lg(g)[:y] == 0
	end

	# Every pair of rendered decorations (`export_boxes`) that overlap, every
	# decoration over a plot area or a tick label, and every one clipped by
	# the figure edge, as readable strings (empty: a clean figure).
	function layout_defects(b)
		items = Tuple{String, Vector{Float64}}[]
		for (kind, key) in (("legend", "legends"), ("annotation", "ann"), ("x title", "xtitle"),
			("y title", "ytitle"), ("colorbar", "colorbars"))
			for (i, box) in enumerate(b[key])
				push!(items, ("$(kind) $(i)", Float64.(box)))
			end
		end
		b["gtitle"] === nothing || push!(items, ("figure title", Float64.(b["gtitle"])))
		defects = String[]
		for i in eachindex(items), j in eachindex(items)
			i < j && overlaps(items[i][2], items[j][2]) && push!(defects, "$(items[i][1]) / $(items[j][1])")
		end
		for (name, box) in items, (kind, key) in (("plot", "plots"), ("tick", "ticks")), other in b[key]
			overlaps(box, other) && push!(defects, "$(name) / $(kind) $(round.(Float64.(other); digits = 1))")
		end
		for (name, box) in items
			(box[1] >= -0.5 && box[2] >= -0.5 && box[3] <= b["W"] + 0.5 && box[4] <= b["H"] + 0.5) ||
				push!(defects, "$(name) clipped $(round.(box; digits = 1))")
		end
		return unique(defects)
	end

	@testset "D12 acceptance: a 2x2 grid with every kind of decoration, at 700x500 and IEEE size" begin
		function acceptance_grid()
			xs = collect(range(0, 1; length = 30))
			sf = subplots(2, 2; sync = false)
			plot_scatter!(sf, xs, sin.(4xs); legend = "sin", row = 1, col = 2)
			plot_scatter!(sf, xs, cos.(4xs); legend = "cos", row = 1, col = 2)
			plot_scatter!(sf, xs, xs .^ 2; row = 1, col = 1)
			plot_heatmap!(sf, xs, xs, [sin(6a) * cos(6b) for a in xs, b in xs]; row = 2, col = 2)
			plot_scatter!(sf, xs, exp.(xs); row = 2, col = 1)
			for r in 1:2, c in 1:2
				xlabel!(sf, "x title"; row = r, col = c)
				ylabel!(sf, "y title"; row = r, col = c)
			end
			title!(sf, "first line<br>second line"; row = 1, col = 1)
			title!(sf, "\$\\alpha_1 + \\beta^2\$ math"; row = 1, col = 2)
			title!(sf, "plain title"; row = 2, col = 1)
			title!(sf, "another"; row = 2, col = 2)
			panel_labels!(sf)
			set_legend!(sf; row = 1, col = 2, position = :outside_top)
			colorbar!(sf; row = 2, col = 2, title = "z")
			legend_entry!(sf, "model"; legend_target = :figure, color = "red")
			legend_entry!(sf, "data"; legend_target = :figure, color = "blue")
			set_legend!(sf; legend_target = :figure, position = :outside_top)
			return sf
		end
		sf = acceptance_grid()
		b = export_boxes(sf; width = 700, height = 500)
		@test length(b["plots"]) == 4 && length(b["legends"]) == 2 && length(b["ann"]) == 8
		@test length(b["xtitle"]) == 4 && length(b["ytitle"]) == 4 && length(b["colorbars"]) == 1
		@test layout_defects(b) == String[]
		# the export copy is re-placed at another size too
		b = export_boxes(sf; width = 900, height = 650)
		@test layout_defects(b) == String[]
		# The IEEE single-column size: the rows give up most of their cells
		# (`_ROOM_MAX_SHARE`) and nothing overlaps.
		w, h = with_style(() -> PS._style_default_figure_size(), :ieee)
		@test (w, h) == (336, 252)
		b = with_style(:ieee) do
			export_boxes(acceptance_grid(); width = round(Int, w), height = round(Int, h))
		end
		@test length(b["plots"]) == 4 && length(b["legends"]) == 2 && length(b["ann"]) == 8
		@test layout_defects(b) == String[]
		@test all(p -> p[4] - p[2] > 5, b["plots"])
	end

	@testset "Z65/Z97: panel labels are not clipped under journal margins (no tight_layout! needed)" begin
		for style in (:publication, :ieee, :nature)
			for outside in (true, false)
				b = with_style(style) do
					w, h = PS._style_default_figure_size()
					fig = plot_scatter(1:5, [1, 4, 2, 5, 3]; xlabel = "x", ylabel = "y", title = "A title")
					panel_labels!(fig; labels = ["a"], position = :topleft, outside = outside)
					export_boxes(fig; width = round(Int, w), height = round(Int, h))
				end
				@test length(b["ann"]) == 1
				defects = layout_defects(b)
				# an inside label sits over its plot area by design; it must not
				# be clipped (an outside one touches nothing at all)
				outside ? (@test defects == String[]) : (@test !any(d -> occursin("clipped", d), defects))
				label = b["ann"][1]
				@test label[1] >= -0.5 && label[2] >= -0.5 && label[3] <= b["W"] + 0.5 && label[4] <= b["H"] + 0.5
			end
		end
	end

	@testset "D12: what reaches past a narrow cell clears its top y tick label; labels clear wide titles" begin
		xs = collect(range(0, 1; length = 20))
		size = (520, 260)
		# the tick label font of the figures below (the default style's)
		reach_of(plan, key) = PS._LT_TICK_REACH * PS._lt_y_tick_font(plan, plan.areas[key], :left) + 1
		# a label beside a left-aligned title, over the y tick labels of cell 1;
		# a centred title wider than cell 2, its label beside the title's end
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, xs, xs; row = 1, col = 1)
		plot_scatter!(sf, xs, 2 .* xs; row = 1, col = 2)
		relayout!(sf; yaxis_range = [0, 1], yaxis_dtick = 0.5, yaxis2_range = [0, 2], yaxis2_dtick = 1)
		title!(sf, "(left)"; row = 1, col = 1, align = :left)
		title!(sf, "a long centred panel title over a narrow cell"; row = 1, col = 2)
		panel_labels!(sf)
		plan = PS._room_plan(sf; size = size)
		lines = Dict(d.key => d for d in PS._lt_decorations(plan))
		for (key, area) in (("line:xaxis", :xaxis), ("line:xaxis2", :xaxis2))
			line = slot_of(plan, key)
			@test all(entry -> line.offset + entry[3] >= reach_of(plan, area) - 1e-9, lines[key].data)
		end
		b = export_boxes(sf; width = size[1], height = size[2])
		@test length(b["ann"]) == 4
		@test layout_defects(b) == String[]
		@test !PS._text_restack!(sf)
		# a legend wider than its cell, above the axes
		sl = subplots(1, 3; sync = false)
		for c in 1:3
			plot_scatter!(sl, xs, c .* xs; row = 1, col = c)
		end
		plot_scatter!(sl, xs, [xs, 2 .* xs]; legend = ["first series", "second series"], row = 1, col = 3)
		relayout!(sl; yaxis3_range = [0, 3], yaxis3_dtick = 1.5)
		set_legend!(sl; row = 1, col = 3, position = :outside_top, orientation = :h)
		plan = PS._room_plan(sl; size = size)
		legend = only(d for d in PS._lt_decorations(plan) if d.key == "legend:legend3")
		@test legend.role === :cell_legend
		@test legend.data.lift > 0
		@test slot_of(plan, legend.key).offset + legend.data.lift >= reach_of(plan, :xaxis3) - 1e-9
		b = export_boxes(sl; width = size[1], height = size[2])
		@test length(b["legends"]) == 1
		@test layout_defects(b) == String[]
	end

	@testset "D12: axis labels between cells get room; a user domain wider than that is kept" begin
		xs = collect(range(0, 1; length = 20))
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, xs, xs; row = 1, col = 1)
		plot_scatter!(sf, xs, 1000 .* xs; row = 1, col = 2)
		title!(sf, "(a)"; row = 1, col = 1)          # a request: the room is solved
		dom() = PS._layout_axis_domain(pl(sf).layout, :xaxis2)
		ref = dom()[1]
		ylabel!(sf, "y title"; row = 1, col = 2)
		first = dom()[1]
		@test first > ref
		# the room grows with the title (a side shrunk before only grows)
		relayout!(sf; yaxis2_title_font_size = 40)
		PS._finalize_figure!(sf)
		@test dom()[1] > first
		@test PS._finalize_figure!(sf) === false
		plan = plan_of(sf)
		a = plan.areas[:xaxis2]
		@test (dom()[1] - plan.areas[:xaxis].current[1][2]) * plan.Wp >= PS._room_label_px(a.own[:left]) - 1e-6
		# a domain the user narrowed farther is kept
		relayout!(sf; xaxis2_domain = [0.8, 1.0])
		PS._finalize_figure!(sf)
		@test collect(dom()) == [0.8, 1.0]
		# a row gap between the x axis above (axis title) and a title line below:
		# both rows give up height for it
		sr = subplots(2, 1; sync = false)
		plot_scatter!(sr, xs, xs; row = 1, col = 1)
		plot_scatter!(sr, xs, xs; row = 2, col = 1)
		xlabel!(sr, "x title"; row = 1, col = 1)
		title!(sr, "lower panel"; row = 2, col = 1)
		plan = PS._room_plan(sr; size = (300, 200))
		top, bottom = plan.areas[:xaxis].room[:bottom], plan.areas[:xaxis2].room[:top]
		@test top > 0 && bottom > 0
	end
	@testset "v6 K3: the best-position scoring reads the data in place (no copies)" begin
		n = 1_000_000
		xs = collect(range(0, 100; length = n))
		f = plot_scatter(xs, sin.(xs); legend = "data")
		p = pl(f)
		PS._scat_best_legend_position(p)
		@test (@allocated PS._scat_best_legend_position(p)) < 4 * 2^20
		# a list of coordinate vectors has the window of the chained vector: finite values only
		layout = PB.Layout()
		a, b = [1.0, NaN, 3.0], [-2.0, Inf, 0.5]
		@test PS._scat_legend_window(layout, :xaxis, Vector{Float64}[a, b]; padded = false) ==
			PS._scat_legend_window(layout, :xaxis, vcat(a, b); padded = false) == (-2.0, 3.0)
		@test PS._scat_legend_window(layout, :xaxis, Vector{Float64}[Float64[], Float64[]]; padded = false) === nothing
	end

	@testset "v6 S2/Q17/Q28/Z72: the default legend is never over data while a place is free, else outside" begin
		# S2: three rising lines leave the top-left and bottom-right corners free
		f = plot_scatter(1:5, [[1, 2, 3, 4, 5], [2, 3, 4, 5, 6], [0, 1, 2, 3, 4]]; legend = ["a", "b", "c"])
		@test PS._scat_best_legend_position(pl(f)) in (:topleft, :bottomright)
		@test lg(f)[:x] < 0.5 || lg(f)[:yanchor] == "bottom"
		# data on every corner and edge: the legend goes beside the axes ...
		xs = collect(range(0, 1; length = 40))
		function full_figure(; kwargs...)
			fig = plot_scatter(xs, [0 .* xs, 0.25 .+ 0 .* xs, 0.5 .+ 0 .* xs, 0.75 .+ 0 .* xs, 1 .+ 0 .* xs];
				legend = ["a", "b", "c", "d", "e"], kwargs...)
			for k in 1:4
				plot_scatter!(fig, fill(k / 5, 40), xs; mode = "lines", legend = "v$k")
			end
			return fig
		end
		f = full_figure()
		@test PS._scat_best_legend_position(pl(f)) === :outside_right
		@test lg(f)[:x] > 1 && lg(f)[:xanchor] == "left" && !haskey(lg(f), :orientation)
		# ... and below them at a journal column width
		f = full_figure(width = 300, height = 250)
		@test PS._scat_best_legend_position(pl(f)) === :outside_bottom
		@test lg(f)[:yref] == "container" && lg(f)[:orientation] == "h"
		# the room is reserved: the right margin holds the legend after the finalizer ran
		f = full_figure()
		PS._finalize_figure!(f)
		@test sd(pl(f).layout.fields[:margin])[:r] > 50       # beyond the plotly.js margin of the 1.x figures
		@test PS._finalize_figure!(f) === false
		# an appended trace keeps a legend the rule placed following the data; a legend
		# the user placed stays
		f = full_figure()
		plot_scatter!(f, xs, xs; legend = "g")
		@test lg(f)[:x] > 1
		f = full_figure()
		set_legend!(f; position = :topright)
		plot_scatter!(f, xs, xs .^ 2; legend = "g")
		@test lg(f)[:x] < 1 && lg(f)[:xanchor] == "right" && lg(f)[:yanchor] == "top"
		# the centre is never chosen
		f = plot_scatter(xs, [xs, 1 .- xs, 0.5 .+ 0 .* xs, 0.2 .+ 0 .* xs, 0.8 .+ 0 .* xs, 0.35 .+ 0 .* xs, 0.65 .+ 0 .* xs];
			legend = ["a", "b", "c", "d", "e", "f", "g"])
		@test PS._scat_best_legend_position(pl(f)) !== :center
		# Q17: quiver glyphs fill the corners of the field, the legend is not left at the top right
		g = range(-2, 2; length = 9)
		X = [a for a in g, b in g]; Y = [b for a in g, b in g]
		q = plot_quiver(X, Y, -Y, X; sizeref = 1.0, legend = "F", colorby = :magnitude, style = :triangle)
		@test lg(q)[:x] > 1
		@test PS._finalize_figure!(q) === false      # settled after the call: the legend room converged
	end

	@testset "v6 Z72: a cell legend with no free position goes below its cell when its row fits" begin
		xs = collect(range(0, 1; length = 30))
		# a grid of markers over the whole cell, one trace per name
		gx, gy = repeat(xs, 30), repeat(xs, inner = 30)
		function frame_cell!(sf, col; names = ("a", "b"))
			for name in names
				plot_scatter!(sf, gx, gy; mode = "markers", legend = name, row = 1, col = col)
			end
		end
		sf = subplots(1, 2; sync = false)
		frame_cell!(sf, 1)
		plot_scatter!(sf, xs, xs; row = 1, col = 2, legend = "free")
		one, two = lg(sf, :legend), lg(sf, :legend2)
		@test one[:yanchor] == "top" && one[:orientation] == "h" && one[:y] < 0.5   # under the cell
		@test two[:yanchor] == "top" && !haskey(two, :orientation) && two[:y] > 0.5  # a free corner
		# its room is reserved: the cell gave up height, the legend is below its plot area
		PS._finalize_figure!(sf)
		@test PS._finalize_figure!(sf) === false
		bottom = PS._layout_axis_domain(pl(sf).layout, :yaxis)[1]
		@test lg(sf, :legend)[:y] < bottom
		# v7 L10: a legend whose row is wider than its cell goes right of the cell
		# as a column, with its room taken from the cell, when the column takes
		# at most half the cell's width (vm-12: else below it as a column)
		function long_cells(width)
			g = subplots(1, 3; sync = false, width = width)
			for c in 1:3
				frame_cell!(g, c; names = ("a rather long label", "another long one", "a third long label"))
			end
			return g
		end
		ids, xkeys = (:legend, :legend2, :legend3), (:xaxis, :xaxis2, :xaxis3)
		wide = long_cells(1500)          # cells of about 370 px, a 160 px column
		for id in ids
			box = lg(wide, id)
			@test box[:xanchor] == "left" && box[:yanchor] == "top" && get(box, :orientation, "v") == "v"
		end
		PS._finalize_figure!(wide)
		@test PS._finalize_figure!(wide) === false
		for (id, xkey) in zip(ids, xkeys)
			@test lg(wide, id)[:x] >= PS._layout_axis_domain(pl(wide).layout, xkey)[2]   # beside its cell
		end
		narrow = long_cells(700)         # cells of about 175 px
		for (id, xkey) in zip(ids, xkeys)
			box = lg(narrow, id)
			xdom = PS._layout_axis_domain(pl(narrow).layout, xkey)
			@test box[:xanchor] == "center" && box[:yanchor] == "top" && box[:orientation] == "v"
			@test abs(box[:x] - (xdom[1] + xdom[2]) / 2) <= 1e-6                     # below its cell
		end
		PS._finalize_figure!(narrow)
		@test PS._finalize_figure!(narrow) === false
		bottom = PS._layout_axis_domain(pl(narrow).layout, :yaxis)[1]
		@test all(id -> lg(narrow, id)[:y] < bottom, ids)
	end

	@testset "v7: a cell legend placed by the rule keeps following the data after a finalize pass" begin
		# The room providers store an inside legend's position rounded to 6
		# decimals; the rule must still recognise it as its own (chama_a6 (b)).
		xs = 10.0 .^ (0:6)
		sf = subplots(1, 2; sync = false, width_ratios = [1, 1.3], width = 690, height = 270)
		plot_scatter!(sf, [0.0, 1.0], [0.0, 1.0]; row = 1, col = 1)
		plot_scatter!(sf, xs, [1.0, 0.8, 0.6, 0.4, 0.2, 0.1, 0.0]; row = 1, col = 2, legend = "a", xscale = "log")
		plot_scatter!(sf, xs, [0.9, 0.7, 0.5, 0.3, 0.15, 0.05, 0.0]; row = 1, col = 2, legend = "b")
		box = lg(sf, :legend2)
		@test (box[:xanchor], box[:yanchor]) == ("right", "top")              # the free top-right corner
		@test box[:x] == round(box[:x]; digits = 6)                          # as the providers stored it
		before = (box[:x], box[:y])
		# the third curve crosses the top-right corner: the legend moves (with
		# an exact comparison it stayed there, taken for a user placement)
		plot_scatter!(sf, xs, [0.0, 0.05, 0.2, 0.4, 0.6, 0.8, 1.0]; row = 1, col = 2, legend = "c")
		p = pl(sf)
		order, ids, domains, _ = PS._legend_subplot_assignment(p)
		xdom, ydom = domains[order[end]]
		best = PS._legend_best_cell_position(p, "legend2", xdom, ydom)
		@test best !== :topright
		want = PS._legend_placement(best, xdom, ydom, sf.legend_inset; figure = false)
		@test PS._legend_placement_matches(lg(sf, :legend2), want, (:xanchor, :yanchor))
		@test (lg(sf, :legend2)[:x], lg(sf, :legend2)[:y]) != before
		# the matcher: numbers within 1e-6, everything else equal
		@test PS._legend_placement_matches(Dict(:x => 0.989826), Dict(:x => 0.9898260869565217), (:x,))
		@test !PS._legend_placement_matches(Dict(:x => 0.9898), Dict(:x => 0.9898260869565217), (:x,))
		@test !PS._legend_placement_matches(Dict(:xanchor => "left"), Dict(:xanchor => "right"), (:xanchor,))
	end

	@testset "v7: a cell legend placed by the rule follows a range change; one the user placed stays" begin
		# gallery optical_reach (b): the legend was placed for the autorange
		# and stayed there, on the curves, after `xrange!` squeezed them left.
		anchors(sf, id) = (b = lg(sf, id); (b[:xanchor], b[:yanchor], get(b, :orientation, "v")))
		function build()
			sf = subplots(1, 2; sync = false, width = 700, height = 300)
			for (k, c) in enumerate((0.07, 0.10, 0.17))   # the last one reaches the top right
				r = collect(range(0.0, 0.2; length = 21))
				plot_scatter!(sf, r, clamp.(1 .- (r .- c) ./ 0.03, 0, 1); row = 1, col = 1, legend = "n$k")
			end
			plot_scatter!(sf, [0.0, 1.0], [0.0, 1.0]; row = 1, col = 2, legend = "other")
			return sf
		end
		# where the rule puts legend "legend" of the first cell now (its locals
		# are named apart from this testset's: a closure assigns those)
		function rule(fig)
			plot = pl(fig)
			cells, _, cell_domains, _ = PS._legend_subplot_assignment(plot)
			cx, cy = cell_domains[cells[1]]
			position = PS._legend_best_cell_position(plot, "legend", cx, cy)
			return position, PS._legend_placement(position, cx, cy, fig.legend_inset; figure = false)
		end
		sf = build()
		@test "legend" in PS._legend_cell_auto_ids(pl(sf))
		before = anchors(sf, :legend)
		@test before[1:2] != ("right", "top")                          # the autorange is full
		xrange!(sf, (0, 0.6); row = 1, col = 1)                  # the right of the cell is now free
		best, want = rule(sf)
		@test best in (:topright, :right, :bottomright)
		@test PS._legend_placement_matches(lg(sf, :legend), want, (:xanchor, :yanchor, :orientation))
		@test PS._finalize_figure!(sf) === false                       # settled
		# the curves fill the cell again: back where the rule puts it
		xrange!(sf, (0.05, 0.16); row = 1, col = 1)
		best2, want2 = rule(sf)
		@test best2 != best
		@test PS._legend_placement_matches(lg(sf, :legend), want2, (:xanchor, :yanchor, :orientation))
		@test PS._finalize_figure!(sf) === false
		# a position the user gave is kept whatever the range
		sf = build()
		set_legend!(sf; row = 1, col = 1, position = :bottomleft)
		@test !("legend" in something(PS._legend_cell_auto_ids(pl(sf)), Set{String}()))
		xrange!(sf, (0, 0.6); row = 1, col = 1)
		@test anchors(sf, :legend)[1:2] == ("left", "bottom")
		# options without a placement (a title) keep the rule
		sf = build()
		set_legend!(sf; row = 1, col = 1, title = "family")
		@test "legend" in PS._legend_cell_auto_ids(pl(sf))
	end

	@testset "v7: a marker's radius counts when scoring the legend corners" begin
		# A marker whose centre lies just outside the top-right box still covers it.
		fields = Dict{Symbol, Any}(:mode => "markers", :marker => Dict(:size => 10, :line => Dict(:width => 1)))
		@test PS._scat_legend_reach(fields, "markers") == 6.0
		@test PS._scat_legend_reach(Dict{Symbol, Any}(), "lines") == 1.0
		@test PS._scat_legend_reach(Dict{Symbol, Any}(:line => Dict(:width => 4)), "lines+markers") == 3.0
		@test PS._scat_legend_reach(Dict{Symbol, Any}(:marker => Dict(:size => [4, 12, missing])), "markers") == 6.0
	end

	@testset "v6: nothing to place returns at once; legend assignment and box sizes are computed once per plan" begin
		bare = plot_scatter(1:5, 1:5)
		@test isempty(PS._lt_decorations(PS._room_plan(bare; size = (300, 200))))
		sf = subplots(3, 3; sync = false)
		for r in 1:3, c in 1:3
			plot_scatter!(sf, 1:4, (1:4) .* r; row = r, col = c, legend = "s$r$c")
		end
		plan = PS._room_plan(sf; size = (600, 400))
		decorations = PS._lt_decorations(plan)
		@test count(d -> d.role in (:cell_legend, :inside_legend), decorations) == 9
		first_call = PS._lt_legend_assignment(plan)
		@test first_call !== nothing && length(first_call[1]) == 9
		@test PS._lt_legend_assignment(plan) === first_call        # the memo, not a recomputation
		@test PS._lt_box_size(plan, "legend") === PS._lt_box_size(plan, "legend")
		# the cell scan gives the assignment the per-trace lookup gave
		order, ids, domains, keys_ = PS._legend_subplot_assignment(pl(sf))
		@test order == ["xy:x|y", "xy:x2|y2", "xy:x3|y3", "xy:x4|y4", "xy:x5|y5", "xy:x6|y6", "xy:x7|y7", "xy:x8|y8", "xy:x9|y9"]
		@test [ids[k] for k in order] == collect(1:9)
		@test length(PS._legend_inset_cells(pl(sf))) == 9
	end

	@testset "v7 style-04: a legend title is drawn at the legend's size in a styled figure" begin
		xs = collect(1.0:5.0)
		size_of(f) = sd(sd(lg(f)[:font]))[:size]
		title_size(f) = sd(sd(sd(lg(f)[:title])[:font]))[:size]
		f = with_style(:nature) do
			g = plot_scatter(xs, [xs, 2 .* xs]; legend = ["alpha", "beta"])
			set_legend!(g; title = "Mode")
			g
		end
		@test title_size(f) == size_of(f)
		@test PS._legend_title_size(pl(f), lg(f)) == size_of(f)
		set_fonts!(f; legend = 6, units = :pt)
		@test size_of(f) ≈ 8 && title_size(f) ≈ 8
		# a size the user gives the title is kept
		relayout!(f; legend_title_font_size = 11)
		set_legend!(f; title = "Mode 2")
		@test title_size(f) == 11
		# :default keeps plotly.js's larger title
		d = plot_scatter(xs, [xs, 2 .* xs]; legend = ["alpha", "beta"])
		set_legend!(d; title = "Mode")
		@test !haskey(sd(sd(lg(d)[:title])), :font)
	end

	@testset "v7 perf-07: an append remembers where it put the legend of the user's figure" begin
		# Keyed by the Plot, the memo was written for the staged copy each
		# call works on: the user's Plot kept the constructor's :topright, and
		# every later call scored the whole figure again (146 KB here).
		x = collect(range(0.0, 10.0; length = 100))
		fig = plot_scatter(x, sin.(x); legend = "s0")
		for k in 1:50
			plot_scatter!(fig, x, sin.(x) .+ k; legend = "s$k")
		end
		placed = get(PS._SCAT_LEGEND_AUTO, PS._scat_legend_memo_key(pl(fig)), nothing)
		@test placed !== nothing && placed !== :topright
		@test PS._scat_legend_is(pl(fig), placed)
		@test PS._scat_legend_state(fig) === :auto
		@test @allocated(PS._scat_legend_state(fig)) < 20_000
		@test PS._scat_legend_memo_key(PS.Plot()) === nothing
	end

	@testset "v7 F1: the cell legend assignment allocates nothing per trace" begin
		# Measured before the fix: 84 KB per call at 200 traces (a boxed key
		# and an untyped tuple per trace), run several times per append; an
		# append with per-subplot legends cost 2.02x one with a figure legend.
		xs = collect(1.0:5.0)
		function grid(n, per)
			f = subplots(1, 2; sync = false, per_subplot_legends = per)
			for k in 1:n
				plot_scatter!(f, xs, xs .+ k; row = 1, col = 1)
			end
			plot_scatter!(f, xs, xs; row = 1, col = 1)
			return f
		end
		assign_bytes(f) = (PS._legend_subplot_assignment(pl(f)); @allocated PS._legend_subplot_assignment(pl(f)))
		small, large = assign_bytes(grid(50, true)), assign_bytes(grid(800, true))
		@test large < small + 16 * 750          # the per-trace key vector only (8 bytes a trace)
		append_bytes(f) = minimum(k -> @allocated(plot_scatter!(f, xs, xs .+ k; row = 1, col = 1)), 1:5)
		@test append_bytes(grid(200, true)) <= 1.5 * append_bytes(grid(200, false))
	end

	@testset "v7 vm-12: a cell legend that fits neither inside nor beside its cell goes below it as a column" begin
		# Twin-y cells of an :ieee 1 x 2 grid: before, the legends stayed
		# inside a plot area narrower than them (x = 0.21 right-anchored,
		# their samples over the left spine and tick labels); a column right
		# of the cell took the room the room engine caps.
		t = collect(0:0.1:10)
		sf = with_style(:ieee) do
			sf = subplots(1, 2; sync = false, specs = fill(Spec(secondary_y = true), 1, 2))
			for c in 1:2
				plot_scatter!(sf, t, sin.(c .* t); row = 1, col = c, legend = "voltage")
				plot_scatter!(sf, t, 1000 .* cos.(t); row = 1, col = c, secondary_y = true, legend = "current")
				ylabel!(sf, "voltage (V)"; row = 1, col = c)
				ylabel!(sf, "current (mA)"; row = 1, col = c, secondary_y = true)
			end
			sf
		end
		for (id, xkey) in ((:legend, :xaxis), (:legend2, :xaxis2))
			d = lg(sf, id)
			xdom = PS._layout_axis_domain(pl(sf).layout, xkey)
			anchor = String(sd(pl(sf).layout.fields[xkey])[:anchor])    # the primary y of the cell
			ydom = PS._layout_axis_domain(pl(sf).layout, Symbol("yaxis", anchor[2:end]))
			@test d[:yanchor] == "top" && d[:y] < ydom[1]                    # below the cell
			@test d[:xanchor] == "center" && xdom[1] < d[:x] < xdom[2]       # under its own plot area
			@test get(d, :orientation, "v") == "v"                           # a column: no row run under the neighbour
		end
		@test PS._finalize_figure!(sf) === false
	end

	@testset "v7: a path shape (ellipse!, polygon!) counts when scoring the legend corners" begin
		# gallery mdd_shell_field (b): the cell legend sat on a dotted ellipse!,
		# a path shape the rule did not read
		@test PS._scat_legend_path_pieces("M0,0 L1,0 L1,1 Z M2,2 H3 V4") ==
			[([0.0, 1.0, 1.0, 0.0], [0.0, 0.0, 1.0, 0.0], true), ([2.0, 3.0, 3.0], [2.0, 2.0, 4.0], false)]
		@test PS._scat_legend_path_pieces("M0,0 C1,1 2,2 3,-1.5e-1") == [([0.0, 3.0], [0.0, -0.15], false)]
		@test PS._scat_legend_path_pieces("m0,0 l1,1") === nothing          # relative: not read
		@test PS._scat_legend_path_pieces("M0,0 L1") === nothing
		@test PS._scat_legend_path_pieces(nothing) === nothing
		xs = collect(range(0, 1; length = 20))
		fig = plot_scatter(xs, 0.2 .* xs; legend = "low", yrange = [0, 1])   # the top right is free
		@test PS._scat_best_legend_position(pl(fig)) === :topright
		ellipse!(fig, 0.85, 0.85, 0.12, 0.12)
		@test PS._scat_best_legend_position(pl(fig)) !== :topright
	end

	@testset "v7 vm-06: a polar legend with no free corner goes beside the disk" begin
		th = collect(range(0, 2pi; length = 361))
		build() = plot_scatterpolar([th, th], [1 .+ cos.(th), 0.5 .+ 0.5 .* abs.(sin.(2 .* th))];
			thetaunit = "radians", legend = ["cardioid", "rose"])
		# theta in radians is scored (it was not: the legend kept the top right
		# corner, on the "1/4 π" tick label, under :ieee and :nature)
		p = pl(build())
		@test PS._legend_best_polar_position(p, eachindex(p.data), :polar, 300.0, 200.0, (110.0, 50.0)) !== nothing
		# the roomy default figure: its free top right corner
		box = lg(build())
		@test (box[:xanchor], box[:yanchor]) == ("right", "top") && box[:x] < 1
		for style in (:ieee, :nature)
			fig = with_style(build, style)
			box = lg(fig)
			@test box[:xanchor] == "left" && box[:x] > 1                  # beside the disk
			PS._finalize_figure!(fig)
			@test PS._finalize_figure!(fig) === false
		end
		# the same data in a polar cell of a journal grid
		sf = with_style(:ieee) do
			g = subplots(1, 2; sync = false, specs = [Spec() Spec(kind = "polar")])
			plot_scatter!(g, collect(0:0.1:1), collect(0:0.1:1); row = 1, col = 1, legend = "line")
			plot_scatterpolar!(g, [th, th], [1 .+ cos.(th), 0.5 .+ 0.5 .* abs.(sin.(2 .* th))];
				thetaunit = "radians", legend = ["cardioid", "pattern"], row = 1, col = 2)
			g
		end
		polar_x = sd(sd(pl(sf).layout.fields[:polar])[:domain])[:x]
		@test lg(sf, :legend2)[:xanchor] == "left" && lg(sf, :legend2)[:x] >= polar_x[2]
		@test PS._finalize_figure!(sf) === false
	end

	@testset "v7 vm-14: a reference line with a legend entry moves the rule's legend off it" begin
		t = collect(0.0:1:200)
		y = -10 .+ 2 .* sin.(t ./ 15)                      # the lower part of the y range
		build() = plot_scatter(t, y; legend = "signal", xlabel = "sample", ylabel = "level", yrange = (-14, 2))
		# the same line as a trace: the rule's answer
		ref = build()
		plot_scatter!(ref, [185.0, 185.0], [-14.0, 2.0]; legend = "event")
		@test !PS._scat_legend_is(pl(ref), :topright)
		for style in (:default, :ieee)
			fig = with_style(style) do
				f = build()
				vline!(f, 185; dash = "dot", legend = "event")
				f
			end
			# before: still top right, on the line (x = 0.98)
			@test !PS._scat_legend_is(pl(fig), :topright)
			@test PS._scat_legend_is(pl(fig), something(PS._scat_best_legend_position(pl(fig)), :topright))
		end
		# a legend the user placed stays where it is
		fig = build()
		set_legend!(fig; position = :topright)
		vline!(fig, 185; legend = "event")
		@test PS._scat_legend_is(pl(fig), :topright)
	end

	@testset "v7 vm-05/style-03: bars, boxes, violins, dates and categories are scored" begin
		# Unit pieces: plotly.js date and category coordinates.
		@test PS._scat_legend_date_ms("2024-01-01") == 1_704_067_200_000
		@test PS._scat_legend_date_ms(Dates.Date(2024, 1, 1)) == 1_704_067_200_000
		@test PS._scat_legend_date_ms("2024-01-01 12:30:15.5") == 1_704_067_200_000 + 1000 * (12 * 3600 + 30 * 60 + 15.5)
		@test PS._scat_legend_date_ms("2024-13-01") === nothing && PS._scat_legend_date_ms("dose 1") === nothing
		@test PS._scat_legend_autotype([1.0, 2.0]) === :linear
		@test PS._scat_legend_autotype(["1", "2.5"]) === :linear                # numeric strings are numbers
		@test PS._scat_legend_autotype(["control", "dose 1"]) === :category
		@test PS._scat_legend_autotype([Dates.Date(2024, 1, 1), Dates.Date(2024, 2, 1)]) === :date
		@test PS._scat_legend_autotype(Any["2024-01-01", "2024-01-02"]) === :date
		@test PS._scat_legend_category_name(2.0) == "2" && PS._scat_legend_category_name("a") == "a"
		lay(; fields...) = PB.Layout(; fields...)
		@test PS._scat_legend_categories(lay(), :xaxis, (["b", "a"], ["c", "a"])) == Dict("b" => 0, "a" => 1, "c" => 2)
		@test PS._scat_legend_categories(lay(xaxis = PB.attr(categoryorder = "category ascending")), :xaxis, (["b", "a"],)) ==
			Dict("a" => 0, "b" => 1)
		@test PS._scat_legend_categories(lay(xaxis = PB.attr(categoryorder = "array", categoryarray = ["z", "b"])), :xaxis,
			(["b", "a"],)) == Dict("z" => 0, "b" => 1, "a" => 2)
		@test PS._scat_legend_categories(lay(xaxis = PB.attr(categoryorder = "total ascending")), :xaxis, (["b"],)) === nothing

		# Figures of the findings: before, every one kept the top-right corner,
		# over the bars, the violin "c", the date curve's end and "dose 3".
		days = collect(Dates.Date(2024, 1, 1):Dates.Day(1):Dates.Date(2024, 6, 30))
		walk = collect(range(0, 18; length = length(days))) .+ sin.(1:length(days))
		build = Dict(
			"grouped bars" => () -> plot_bar(["Si", "Ge", "GaAs", "InP"],
				[[3.1, 4.0, 2.2, 5.1], [2.5, 3.6, 3.1, 4.4], [1.9, 2.8, 2.7, 3.9]]; legend = ["300 K", "200 K", "77 K"]),
			"style-03 bars" => () -> plot_bar(["A", "B", "C"], [[1.0, 2.0, 3.0], [1.5, 2.5, 3.5], [2.0, 3.0, 4.0]];
				legend = ["method 1", "method 2", "method 3"]),
			"stacked bars" => () -> plot_bar(["A", "B", "C", "D"], [[1.0, 2.0, 3.0, 4.0], [1.0, 1.0, 1.0, 1.0]];
				legend = ["base", "extra"], barmode = "stack"),
			"violins" => () -> plot_violin([[-3.0, -1.0, 0.0, 1.0, 3.3], [0.0, 0.5, 1.0, 1.5, 2.0], [-5.0, -1.0, 1.0, 2.5, 6.3]];
				legend = ["a", "b", "c"], points = false),
			"boxes" => () -> plot_box([[-2.0, 0.0, 0.5, 2.5], [-1.0, 1.0, 1.5, 3.5], [0.5, 2.5, 3.5, 5.5]]; legend = ["a", "b", "c"]),
			"date axis" => () -> plot_scatter(days, walk; legend = "station A"),
			"category axis" => () -> plot_scatter(["control", "dose 1", "dose 2", "dose 3"], [1.0, 1.6, 2.3, 3.0];
				mode = "markers", legend = "wild type"),
		)
		for (name, builder) in build, style in (:default, :ieee, :aip)
			fig = with_style(builder, style)
			p = pl(fig)
			# the first candidate, top right, covers data; an inside answer is
			# a free one (the rule goes outside when none is)
			pos = PS._scat_best_legend_position(p)
			@test pos !== nothing && pos !== :topright
			@test pos in PS._SCAT_LEGEND_POSITIONS || pos in PS._SCAT_LEGEND_OUTSIDE_POSITIONS
			@test PS._scat_legend_is(p, pos)
			@test PS._finalize_figure!(fig) === false
		end
		# The rectangles: a bar of the stack starts where the one below ends,
		# grouped bars share their slot, horizontal bars swap the axes.
		scored(fig) = begin
			p = pl(fig)
			series = PS._ScatLegendSeries[]
			ok, xpadded, xzero = PS._scat_legend_block_series!(series, Float64[], Dict{Symbol, Bool}(), Set{Symbol}(), p,
				[(t.fields, String(t.fields[:type]), :yaxis) for t in p.data], :xaxis,
				(key, letter) -> PS._scat_legend_axis(p, eachindex(p.data), key, letter))
			ok, series, xzero
		end
		ok, series, _ = scored(plot_bar(["A", "B"], [[1.0, 2.0], [3.0, 4.0]]; barmode = "stack"))
		@test ok && length(series) == 2
		@test series[2][3] == [1.0, 4.0, 2.0, 6.0]                    # from the first series' tops
		@test series[1][2] ≈ [-0.4, 0.4, 0.6, 1.4]                    # bargap 0.2 of a 1-wide slot
		ok, series, _ = scored(plot_bar(["A", "B"], [[1.0, 2.0], [3.0, 4.0]]))      # group
		@test ok && series[1][2] ≈ [-0.4, 0.0, 0.6, 1.0] && series[2][2] ≈ [0.0, 0.4, 1.0, 1.4]
		ok, series, xzero = scored(plot_bar([2.0, 5.0], ["a", "b"]; orientation = "h"))
		@test ok && xzero && series[1][2] == [0.0, 2.0, 0.0, 5.0] && series[1][3] ≈ [-0.4, 0.4, 0.6, 1.4]
		# not read: the legend keeps the corner the user or the default gave it
		@test PS._scat_legend_axis(pl(plot_scatter(1:3, 1:3)), 1:1, :xaxis, :x).kind === :linear
		h = plot_histogram(randn(200); legend = "samples")                      # binned by plotly.js
		@test PS._scat_best_legend_position(pl(h)) === nothing
		# a legend the user placed stays
		fig = plot_bar(["A", "B"], [1.0, 2.0]; legend = "v")
		set_legend!(fig; position = :topright)
		plot_bar!(fig, ["A", "B"], [3.0, 4.0]; legend = "w")
		@test PS._scat_legend_is(pl(fig), :topright)
	end

	@testset "v7 vm-01: a horizontal legend is given the rows plotly.js wraps it into" begin
		# The room above the axes was estimated for one row at the layout
		# margins' plot width (328 px) while plotly.js wraps at the plot width
		# after the axes' automargins (286 px): two rows (48 px), so plotly.js
		# pushed the top margin while drawing and, with MathJax entries, drew
		# the curves 19 px off their ticks in the export.
		xs = collect(range(0, 10; length = 100))
		fig = with_style(:ieee) do
			f = plot_scatter(xs, [sin.(xs), cos.(xs), sin.(xs) .* cos.(xs), 0.3 .* xs .- 1.5];
				legend = ["\$\\sin x\$", "\$\\cos x\$", "product", "linear trend"], xlabel = "x", ylabel = "y")
			set_legend!(f; position = :outside_top)
			f
		end
		p = pl(fig)
		plan = PS._room_plan(p)
		@test PS._lt_box_size(plan, "legend")[2] >= 48 - 1                 # two rows
		@test PS._legend_box_size(p, "legend"; wrap = 1000.0)[2] < 40         # one row when it fits
		# the room above the plot holds the legend: top margin >= its height
		# and its offset above the axes
		@test sd(p.layout.fields[:margin])[:t] >= 48
		# plotly.js' horizontal wrap (entries per row, rows): one row of own
		# widths when it fits, else the widest entry + gap per entry
		@test PS._legend_wrap([50.0, 60.0], 0.0, 200.0) == (2, 1)
		@test PS._legend_wrap([50.0, 60.0, 70.0, 80.0], 0.0, 200.0) == (2, 2)   # wrapped: widest + gap per entry
		@test PS._legend_wrap([50.0, 60.0, 70.0, 80.0], 0.0, 60.0) == (1, 4)
		@test PS._legend_wrap(Float64[], 0.0, 60.0) == (0, 0)
	end
end
