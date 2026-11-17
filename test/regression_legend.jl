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
end
