using Test, PlotlySupply

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

	@testset "outside_top legend stays clear of the figure title" begin
		# constructor title, then a legend above the axes
		fig = plot_scatter(x, [x, 2x]; legend = ["a", "b"], title = "T")
		set_legend!(fig; position = :outside_top)
		p = pl(fig)
		t = sd(p.layout.fields[:title])
		@test t[:text] == "T" && t[:automargin] === true
		pad = sd(t[:pad])
		@test pad[:t] == PS._TEXT_TITLE_TOP_PAD
		# the title band exceeds margin.t, so plotly reserves it above the legend
		@test pad[:t] + PS._legend_title_font_size(p, t) + pad[:b] > PS._legend_top_margin(p)
		@test pad[:b] >= PS._LEGEND_TITLE_GAP
		# exact value for a known margin and font size
		relayout!(fig; margin_t = 80, title_font_size = 20)
		set_legend!(fig; position = :outside_top)
		@test sd(sd(p.layout.fields[:title])[:pad])[:b] == 80 - PS._TEXT_TITLE_TOP_PAD - 20 + 1
		# never reduced
		relayout!(fig; title_pad_b = 120)
		set_legend!(fig; position = :outside_top)
		@test sd(sd(p.layout.fields[:title])[:pad])[:b] == 120

		# title! after the legend, with math (half the font size as height bound)
		g = plot_scatter(x, [x, 2x]; legend = ["a", "b"])
		set_legend!(g; position = :outside_top, ncols = 2)
		title!(g, "Fit \$\\alpha\$")
		q = pl(g)
		t = sd(q.layout.fields[:title])
		@test sd(t[:pad])[:b] == ceil(PS._legend_top_margin(q) - PS._TEXT_TITLE_TOP_PAD - PS._legend_title_font_size(q, t) / 2 + 1)

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
		# D7: the constructor stores the title as `title.text`; nothing is added.
		@test sd(pl(m).layout.fields[:title]) == Dict{Symbol, Any}(:text => "T")

		# SubplotFigure figure legend above the grid
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, x, x; legend = "a", row = 1, col = 1)
		plot_scatter!(sf, x, 2x; legend = "b", row = 1, col = 2)
		title!(sf, "Grid")
		set_legend!(sf; position = :outside_top)
		@test haskey(sd(sd(pl(sf).layout.fields[:title])[:pad]), :b)
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
		@test ann(sf, "plotlysupply:title:1:2")[:yshift] == PS._TEXT_PANEL_GAP   # nothing below it yet
		set_legend!(sf; row = 1, col = 2, position = (0.5, 1.0), yanchor = "bottom", orientation = :h)
		lh = PS._legend_box_height(pl(sf), "legend2")
		@test lh > 16
		@test ann(sf, "plotlysupply:title:1:2")[:yshift] ≈ lh + PS._TEXT_PANEL_GAP
		# the label rides on the title's line; the other cell is unchanged
		@test ann(sf, "plotlysupply:panel_label:1:2")[:yshift] == ann(sf, "plotlysupply:title:1:2")[:yshift]
		@test ann(sf, "plotlysupply:panel_label:1:1")[:yshift] == PS._TEXT_PANEL_GAP
		@test !PS._text_restack!(sf)                                             # idempotent
		# a higher user offset is kept
		title!(sf, "(b) Ellipse"; row = 1, col = 2, align = :left, offset = (0, 80))
		@test ann(sf, "plotlysupply:title:1:2")[:yshift] == PS._TEXT_PANEL_GAP + 80
		# entries added later grow the legend and the stack follows
		plot_scatter!(sf, x, 3x; legend = "a much longer third entry name", row = 1, col = 2)
		@test PS._legend_box_height(pl(sf), "legend2") >= lh
		@test ann(sf, "plotlysupply:panel_label:1:2")[:yshift] ≈ PS._legend_box_height(pl(sf), "legend2") + PS._TEXT_PANEL_GAP

		# below a top x axis (secondary_xaxis!) and the legend above it (order: axis, legend, title)
		ss = subplots(1, 2; sync = false)
		plot_scatter!(ss, x, [x, 2x]; legend = ["model", "data"], row = 1, col = 1)
		plot_scatter!(ss, x, x; legend = "z", row = 1, col = 2)
		secondary_xaxis!(ss, v -> 2v, v -> v / 2; title = "frequency (Hz)", row = 1, col = 1)
		title!(ss, "(a) top axis"; row = 1, col = 1, align = :left)
		depth = maximum(t[3] for t in PS._text_top_axes(pl(ss)))
		@test depth > 20
		@test ann(ss, "plotlysupply:title:1:1")[:yshift] ≈ depth + PS._TEXT_PANEL_GAP
		set_legend!(ss; row = 1, col = 1, position = (0.5, 1.0), xanchor = "center", yanchor = "bottom", orientation = :h)
		box = lg(ss)
		offset = (box[:y] - 1) * PS._text_plot_height(pl(ss))
		@test isapprox(offset, depth + PS._TEXT_PANEL_GAP; atol = PS._TEXT_STACK_TOL)
		@test isapprox(ann(ss, "plotlysupply:title:1:1")[:yshift],
			offset + PS._legend_box_height(pl(ss), "legend") + PS._TEXT_PANEL_GAP; atol = 2 * PS._TEXT_STACK_TOL)
		@test !PS._text_restack!(ss)
	end

	@testset "D12/G38: an :outside_top figure legend goes above the panel titles, under the figure title" begin
		sg = subplots(1, 2; sync = false, per_subplot_legends = false)
		figsize!(sg, 7.2, 4.0; units = :in)
		H = 4.0 * 96
		for c in 1:2
			plot_scatter!(sg, x, x .* c; legend = "run $(c)", row = 1, col = c)
		end
		set_legend!(sg; position = :outside_top)
		@test lg(sg)[:y] > 1 && !haskey(lg(sg), :yref)          # nothing stacked yet: unchanged
		title!(sg, "(a) structured meshes"; row = 1, col = 1)
		box = lg(sg)
		@test box[:yref] == "container" && box[:yanchor] == "top" && box[:x] == 0.5
		@test box[:y] ≈ round(1 - PS._TEXT_PANEL_GAP / H; digits = 4)
		lh = PS._legend_box_height(pl(sg), "legend")
		title_h = PS._text_extent("(a) structured meshes", 12)[2]
		margin_t() = sd(pl(sg).layout.fields[:margin])[:t]
		# room for the legend, the gap and the panel title (yshift + text + annotation frame)
		@test margin_t() >= PS._TEXT_PANEL_GAP + lh + PS._LEGEND_TITLE_GAP + PS._TEXT_PANEL_GAP + title_h
		# a figure title goes on top, the legend right under it, with no clearance pad.b
		title!(sg, "Convergence")
		band = PS._text_title_band(pl(sg))
		@test band > 20
		@test lg(sg)[:y] ≈ round(1 - band / H; digits = 4)
		@test !haskey(sd(sd(pl(sg).layout.fields[:title])[:pad]), :b)
		@test margin_t() >= band + lh + PS._LEGEND_TITLE_GAP + title_h
		@test !PS._text_restack!(sg)
		# tight_layout! keeps that room
		tight_layout!(sg)
		@test margin_t() >= band + lh + PS._LEGEND_TITLE_GAP + title_h
		@test !PS._text_restack!(sg)
		# a legend the user placed elsewhere is not moved
		set_legend!(sg; position = (0.2, 1.1))
		@test lg(sg)[:y] == 1.1 && get(lg(sg), :yref, "paper") == "paper"

		# single figure: an outside panel label is a stack too
		f = plot_scatter(x, [x, 2x]; legend = ["model", "data"])
		set_legend!(f; position = :outside_top)
		@test get(lg(f), :yref, "paper") == "paper"
		panel_labels!(f)
		@test lg(f)[:yref] == "container" && lg(f)[:yanchor] == "top"
	end

	# Rendered geometry, read back from the export window after `savefig`.
	function export_boxes(fig)
		savefig(fig; format = "svg")
		raw = PS._with_export_window(PS._EXPORT_STATE) do ec, app, win, divid
			script = "(function(){var gd=document.getElementById($(PS._json_js(divid)));" *
				"var b=function(e){if(!e)return null;var r=e.getBoundingClientRect();return [r.left,r.top,r.right,r.bottom];};" *
				"return JSON.stringify({" *
				"legends:Array.from(gd.querySelectorAll('g.infolayer > g')).filter(function(g){" *
				"return /^legend[0-9]*\$/.test((g.getAttribute('class')||'').split(' ')[0]);}).map(function(g){return b(g.querySelector('rect.bg'));})," *
				"ann:Array.from(gd.querySelectorAll('g.annotation')).map(function(a){return b(a.querySelector('g.annotation-text-g'));})," *
				"xtitle:Array.from(gd.querySelectorAll('g.g-xtitle')).map(b)," *
				"points:Array.from(gd.querySelectorAll('path.point')).map(b)," *
				"gtitle:b(gd.querySelector('g.g-gtitle'))});})()"
			Base.invokelatest(() -> ec.run(win, script))
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

		# Traces the estimate does not model keep the default corner.
		sk = subplots(1, 2; sync = false)
		plot_bar!(sk, ["a", "b", "c"], [1, 2, 3]; row = 1, col = 1, legend = "bars")
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
		# the position covering the fewest points, then the fewest tick labels.
		sr = subplots(2, 2; sync = false, specs = [Spec() Spec(kind = "polar"); Spec(secondary_y = true) Spec()])
		plot_scatter!(sr, 1:5, [1, 4, 9, 16, 25]; row = 1, col = 1, legend = "(1,1)", mode = "lines+markers")
		plot_scatterpolar!(sr, 0:30:330, fill(1.0, 12); row = 1, col = 2, legend = "polar", mode = "markers")
		@test placed_at(sr, :legend, :topleft)
		@test placed_at(sr, :legend2, :topright)
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
end
