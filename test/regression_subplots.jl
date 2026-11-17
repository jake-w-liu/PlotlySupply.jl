using Test, PlotlySupply

# Regression tests for the SubplotFigure infrastructure (v2 "subplots"
# track): subplots() options, per-cell axis references, figure-wide modes,
# forwarded verbs and per-cell layout updaters.

const _RSP_PB = PlotlySupply.PlotlyBase

_rsp_fields(value) = value isa _RSP_PB.PlotlyAttribute ? value.fields : value
_rsp_layout(sf::SubplotFigure) = sf.plot.layout.fields
_rsp_axis(sf::SubplotFigure, key::Symbol) = _rsp_fields(_rsp_layout(sf)[key])
_rsp_span(domain) = domain[2] - domain[1]

# Recording renderer for SyncPlot-backed figures; `fail` makes every script
# throw so rollback can be checked.
mutable struct _RSPRenderer
	scripts::Vector{String}
	fail::Bool
end

function _rsp_syncplot(p::Plot)
	renderer = _RSPRenderer(String[], false)
	backend = (
		isopen = window -> true,
		close = window -> nothing,
		run = (window, script) -> begin
			renderer.fail && throw(ErrorException("rsp renderer failure"))
			push!(renderer.scripts, String(script))
			return "ok"
		end,
	)
	sp = SyncPlot(
		p,
		nothing,
		:rsp_window,
		"rsp-div",
		PlotlySupply._SyncPlotResources(nothing, backend),
	)
	return sp, renderer
end

# Replace the Plot of a `sync=false` SubplotFigure by a recording SyncPlot.
function _rsp_live!(sf::SubplotFigure)
	sp, renderer = _rsp_syncplot(sf.plot)
	sf.fig = sp
	return renderer
end

@testset "regression: subplots infrastructure" begin
	@testset "subplots: figure title, size and window options" begin
		sf = subplots(1, 2; sync=false)
		@test !haskey(_rsp_layout(sf), :title)
		@test !haskey(_rsp_layout(sf), :width)
		@test !haskey(_rsp_layout(sf), :height)

		titled = subplots(
			2,
			1;
			sync=false,
			title="Overview",
			width=700,
			height=500,
			window_title="Window",
		)
		@test _rsp_fields(_rsp_layout(titled)[:title])[:text] == "Overview"
		@test _rsp_layout(titled)[:width] == 700
		@test _rsp_layout(titled)[:height] == 500

		@test_throws ArgumentError subplots(1, 1; sync=false, width=-1)
		@test_throws ArgumentError subplots(1, 1; sync=false, height=Inf)
		@test_throws ArgumentError subplots(true, 1; sync=false)
		@test_throws ArgumentError subplots(1, 1; sync=false, legend_inset=(NaN, 0.1))
		@test_throws ArgumentError subplots(1, 1; sync=false, legend_borderwidth=-1)
		@test_throws ArgumentError subplots(1, 1; sync=false, legend_inset=[0.1])
		@test_throws ArgumentError subplots(1, 1; sync=false, legend_bgcolor="notacolour")
		@test_throws ArgumentError subplots(1, 1; sync=false, rows=2)
		# PlotlyBase accepts negative spacing and raises a plain error above 1;
		# both, and spacings that leave no room for the cells, are rejected.
		for (key, value) in (
			(:horizontal_spacing, 1.5),
			(:horizontal_spacing, -0.1),
			(:horizontal_spacing, NaN),
			(:horizontal_spacing, true),
			(:horizontal_spacing, 0.5),  # 1 × 3 grid: 2 gaps of 0.5 fill the row
			(:vertical_spacing, 0.6),
		)
			err = try
				subplots(key === :vertical_spacing ? 3 : 1, 3; sync=false, Dict(key => value)...)
				nothing
			catch caught
				caught
			end
			@test err isa ArgumentError
			@test occursin(String(key), err.msg)
		end
		spaced = subplots(1, 3; sync=false, horizontal_spacing=0.1)
		@test _rsp_axis(spaced, :xaxis2)[:domain][1] - _rsp_axis(spaced, :xaxis)[:domain][2] ≈ 0.1
		# PlotlyBase grid assertions surface as ArgumentError.
		@test_throws ArgumentError subplots(1, 2; sync=false, column_titles=["a", "b", "c"])
		@test_throws ArgumentError subplots(1, 2; sync=false, shared_xaxes="bogus")
		# plotly.py's flat subplot_titles list is accepted (row-major).
		flat = subplots(2, 2; sync=false, subplot_titles=["A", "B", "C", "D"])
		texts = [_rsp_fields(a)[:text] for a in _rsp_layout(flat)[:annotations]]
		@test texts == ["A", "B", "C", "D"]
		@test_throws ArgumentError subplots(1, 2; sync=false, subplot_titles=[1, 2])
		@test_throws ArgumentError subplots(1, 2; sync=false, subplot_titles="AB")

		# Legend style defaults follow the active style; explicit colours are
		# normalised.
		styled = subplots(1, 1; sync=false, legend_bgcolor="white", legend_bordercolor="0.5")
		@test styled.legend_bgcolor == "#FFFFFF"
		@test styled.legend_bordercolor == "#808080"
		@test styled.legend_borderwidth == 1.0
		default_style = subplots(1, 1; sync=false)
		@test default_style.legend_bgcolor == "rgba(255,255,255,0.72)"
		@test default_style.legend_bordercolor == "rgba(0,0,0,0.15)"
		@test default_style.legend_borderwidth == 1.0
	end

	@testset "subplots: sync=true writes the figure title, not the window title (C10)" begin
		sf = subplots(1, 1; show=false)
		try
			@test sf.fig isa SyncPlot
			@test !haskey(_rsp_layout(sf), :title)
		finally
			close(sf)
		end
		titled = subplots(1, 1; show=false, title="Figure T", window_title="Window W")
		try
			@test _rsp_fields(_rsp_layout(titled)[:title])[:text] == "Figure T"
		finally
			close(titled)
		end
	end

	@testset "subplots: height_ratios / width_ratios" begin
		sf = subplots(2, 1; sync=false, height_ratios=[3, 1])
		top = _rsp_axis(sf, :yaxis)[:domain]
		bottom = _rsp_axis(sf, :yaxis2)[:domain]
		@test top[1] > bottom[2]
		@test isapprox(_rsp_span(top), 3 * _rsp_span(bottom); rtol=1e-9)

		three = subplots(3, 1; sync=false, height_ratios=[1, 2, 3])
		spans = [_rsp_span(_rsp_axis(three, key)[:domain]) for key in (:yaxis, :yaxis2, :yaxis3)]
		@test isapprox(spans[2], 2 * spans[1]; rtol=1e-9)
		@test isapprox(spans[3], 3 * spans[1]; rtol=1e-9)

		wide = subplots(1, 2; sync=false, width_ratios=[1, 2])
		left = _rsp_axis(wide, :xaxis)[:domain]
		right = _rsp_axis(wide, :xaxis2)[:domain]
		@test left[2] < right[1]
		@test isapprox(_rsp_span(right), 2 * _rsp_span(left); rtol=1e-9)

		# Equal ratios are accepted with start_cell="bottom-left".
		equal = subplots(2, 1; sync=false, start_cell="bottom-left", height_ratios=[1, 1])
		@test isapprox(
			_rsp_span(_rsp_axis(equal, :yaxis)[:domain]),
			_rsp_span(_rsp_axis(equal, :yaxis2)[:domain]);
			rtol=1e-9,
		)
		# PlotlyBase overlaps unequal bottom-left rows, so they are rejected.
		@test_throws ArgumentError subplots(2, 1; sync=false, start_cell="bottom-left", height_ratios=[3, 1])
		@test_throws ArgumentError subplots(2, 1; sync=false, start_cell="middle")
		@test_throws ArgumentError subplots(2, 1; sync=false, height_ratios=[1, 2, 3])
		@test_throws ArgumentError subplots(2, 1; sync=false, height_ratios=[1, 0])
		@test_throws ArgumentError subplots(2, 1; sync=false, height_ratios=[1, NaN])
		@test_throws ArgumentError subplots(2, 1; sync=false, height_ratios=[1, 2], row_heights=[0.5, 0.5])
		@test_throws ArgumentError subplots(1, 2; sync=false, width_ratios=[1, 2], column_widths=[0.5, 0.5])
	end

	@testset "subplots: default styling applied once" begin
		sf = subplots(2, 2; sync=false)
		for key in (:xaxis, :xaxis2, :yaxis, :yaxis4)
			axis = _rsp_axis(sf, key)
			@test axis[:linecolor] == "#000000"
			@test axis[:mirror] == true
			@test axis[:showline] == true
		end
	end

	@testset "axis references are retargeted to the cell (#22, #29)" begin
		sf = subplots(2, 2; sync=false)
		plot_scatter!(sf, [0.0, 1], [0.0, 1000]; row=1, col=1)
		plot_heatmap!(sf, collect(1.0:3), collect(1.0:3), rand(3, 3); row=2, col=1, equalar=true)
		plot_quiver!(sf, [0.0, 1], [0.0, 1], [0.5, 0.5], [0.2, 0.2]; row=2, col=2)
		@test _rsp_axis(sf, :xaxis3)[:scaleanchor] == "y3"
		@test _rsp_axis(sf, :xaxis4)[:scaleanchor] == "y4"
		@test !haskey(_rsp_axis(sf, :xaxis), :scaleanchor)
		@test !haskey(_rsp_axis(sf, :xaxis2), :scaleanchor)

		# A cell (1, 1) target keeps its own references.
		single = subplots(1, 1; sync=false)
		plot_quiver!(single, [0.0, 1], [0.0, 1], [0.5, 0.5], [0.2, 0.2])
		@test _rsp_axis(single, :xaxis)[:scaleanchor] == "y"

		remapped = PlotlySupply._subplot_remap_axis_refs(
			attr(scaleanchor="y", matches="x", overlaying="free", range=[0, 1]),
			"x3",
			"y3",
			"x3",
		)
		fields = _rsp_fields(remapped)
		@test fields[:scaleanchor] == "y3"
		@test !haskey(fields, :matches)  # self-reference dropped
		@test fields[:overlaying] == "free"
		@test fields[:range] == [0, 1]
	end

	@testset "barmode does not leak between cells (#221)" begin
		sf = subplots(1, 2; sync=false)
		plot_bar!(sf, ["Q1", "Q2"], [[1.0, 2.0], [3.0, 4.0]]; row=1, col=1)
		plot_histogram!(sf, [randn(50), randn(50)]; row=1, col=2)
		@test get(_rsp_layout(sf), :barmode, "group") != "overlay"
		# The histograms overlay inside their own cell (one offset group); the
		# bars keep plotly's per-trace groups.
		@test sf.plot.data[3][:offsetgroup] == sf.plot.data[4][:offsetgroup]
		@test !haskey(sf.plot.data[1].fields, :offsetgroup)
		@test !haskey(sf.plot.data[2].fields, :offsetgroup)
		# A single histogram is not grouped.
		single = subplots(1, 1; sync=false)
		plot_histogram!(single, randn(20))
		@test !haskey(single.plot.data[1].fields, :offsetgroup)
		# Under an explicit root overlay no offset group is needed.
		overlaid = subplots(1, 1; sync=false)
		relayout!(overlaid; barmode="overlay")
		plot_histogram!(overlaid, [randn(20), randn(20)])
		@test all(!haskey(t.fields, :offsetgroup) for t in overlaid.plot.data)

		reverse_order = subplots(1, 2; sync=false)
		plot_histogram!(reverse_order, [randn(50), randn(50)]; row=1, col=1)
		plot_bar!(reverse_order, ["Q1", "Q2"], [[1.0, 2.0], [3.0, 4.0]]; row=1, col=2)
		@test get(_rsp_layout(reverse_order), :barmode, "group") != "overlay"

		# An explicit mode is figure-wide and still applied …
		plot_bar!(reverse_order, ["Q1"], [[1.0], [2.0]]; barmode="stack", row=1, col=2)
		@test _rsp_layout(reverse_order)[:barmode] == "stack"
		# … with a warning when it re-arranges bars already in another cell.
		explicit = subplots(1, 2; sync=false)
		plot_bar!(explicit, ["Q1"], [[1.0], [2.0]]; barmode="group", row=1, col=1)
		@test_logs (:warn, r"WHOLE figure") plot_bar!(
			explicit,
			["Q1"],
			[[1.0], [2.0]];
			barmode="stack",
			row=1,
			col=2,
		)
		@test _rsp_layout(explicit)[:barmode] == "stack"
		# Same mode or same cell: no warning.
		@test_logs plot_bar!(explicit, ["Q1"], [[1.0], [2.0]]; barmode="stack", row=1, col=1)

		# Automatic box/violin modes only fill an unset root value.
		boxes = subplots(1, 2; sync=false)
		plot_box!(boxes, [randn(10), randn(10)]; row=1, col=2)
		@test _rsp_layout(boxes)[:boxmode] == "group"
		_rsp_layout(boxes)[:boxmode] = "overlay"
		plot_box!(boxes, [randn(10), randn(10)]; row=1, col=1)
		@test _rsp_layout(boxes)[:boxmode] == "overlay"
	end

	@testset "update_xaxes!/update_yaxes! with row/col (#8, #15)" begin
		sf = subplots(1, 2; sync=false)
		domain = _rsp_axis(sf, :xaxis2)[:domain]
		@test update_xaxes!(sf; row=1, col=2, showgrid=false, title_text="t2") === sf
		@test _rsp_axis(sf, :xaxis2)[:showgrid] == false
		@test _rsp_axis(sf, :xaxis2)[:domain] == domain
		@test _rsp_fields(_rsp_axis(sf, :xaxis2)[:title])[:text] == "t2"
		@test get(_rsp_axis(sf, :xaxis), :showgrid, true) != false
		@test !haskey(_rsp_axis(sf, :xaxis2), :row)
		@test !haskey(_rsp_axis(sf, :xaxis2), :col)
		@test (sf.current_row, sf.current_col) == (1, 2)

		update_yaxes!(sf; row=1, col=1, type="log")
		@test _rsp_axis(sf, :yaxis)[:type] == "log"
		@test !haskey(_rsp_axis(sf, :yaxis2), :type)

		# Without row/col every axis is updated (PlotlyBase semantics).
		update_xaxes!(sf; zeroline=true)
		@test _rsp_axis(sf, :xaxis)[:zeroline] == true
		@test _rsp_axis(sf, :xaxis2)[:zeroline] == true

		@test_throws ArgumentError update_xaxes!(sf; row=1, showgrid=true)
		@test_throws ArgumentError update_yaxes!(sf; secondary_y=true, type="log")
		@test_throws ArgumentError update_yaxes!(sf; row=1, col=1, secondary_y=true, type="log")
		@test_throws ArgumentError update_xaxes!(sf; row=3, col=1, showgrid=true)

		secondary = subplots(1, 1; sync=false, specs=fill(Spec(secondary_y=true), 1, 1))
		plot_scatter!(secondary, [1.0, 2.0], [3.0, 4.0]; secondary_y=true)
		update_yaxes!(secondary; row=1, col=1, secondary_y=true, type="log")
		@test _rsp_axis(secondary, :yaxis2)[:type] == "log"
		@test !haskey(_rsp_axis(secondary, :yaxis), :type)

		polar = subplots(1, 2; sync=false, specs=[Spec(kind="polar") Spec(kind="xy")])
		update_polars!(polar; row=1, col=1, bgcolor="#eeeeee")
		@test _rsp_fields(_rsp_layout(polar)[:polar])[:bgcolor] == "#eeeeee"
		@test_throws ArgumentError update_polars!(polar; row=1, col=2, bgcolor="#eeeeee")
		@test_throws ArgumentError update_xaxes!(polar; row=1, col=1, showgrid=false)
	end

	@testset "update_annotations!/update_shapes! with row/col" begin
		sf = subplots(1, 2; sync=false)
		relayout!(
			sf;
			annotations=[
				attr(text="a", x=0, y=0, xref="x", yref="y"),
				attr(text="b", x=0, y=0, xref="x2", yref="y2"),
				attr(text="c", x=0.5, y=0.5, xref="x2 domain", yref="y2 domain"),
				attr(text="p", x=0.5, y=1, xref="paper", yref="paper"),
			],
			shapes=[
				attr(type="line", x0=0, x1=1, y0=0, y1=1, xref="x", yref="y"),
				attr(type="line", x0=0, x1=1, y0=0, y1=1, xref="x2", yref="y2"),
			],
		)
		@test update_annotations!(sf; row=1, col=2, font_color="red") === sf
		colours = [
			get(_rsp_fields(get(_rsp_fields(a), :font, attr())), :color, nothing)
			for a in _rsp_layout(sf)[:annotations]
		]
		@test colours == [nothing, "red", "red", nothing]
		update_shapes!(sf; row=1, col=1, line_width=3)
		widths = [
			get(_rsp_fields(get(_rsp_fields(s), :line, attr())), :width, nothing)
			for s in _rsp_layout(sf)[:shapes]
		]
		@test widths == [3, nothing]
		# Without row/col: every entry.
		update_annotations!(sf; opacity=0.5)
		@test all(_rsp_fields(a)[:opacity] == 0.5 for a in _rsp_layout(sf)[:annotations])
		@test_throws ArgumentError update_annotations!(sf; row=1, opacity=1)

		polar = subplots(1, 1; sync=false, specs=fill(Spec(kind="polar"), 1, 1))
		@test_throws ArgumentError update_annotations!(polar; row=1, col=1, opacity=1)
	end

	@testset "forwarded PlotlyBase verbs return sf (#24, #30)" begin
		sf = subplots(1, 2; sync=false)
		plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row=1, col=1)
		plot_scatter!(sf, [1.0, 2.0], [3.0, 4.0]; row=1, col=2)
		plot_scatter!(sf, [1.0, 2.0], [5.0, 6.0]; row=1, col=2)
		first_trace, second_trace, third_trace = sf.plot.data
		@test movetraces!(sf, 1) === sf
		@test sf.plot.data[3] === first_trace
		@test deletetraces!(sf, 3) === sf
		@test length(sf.plot.data) == 2
		@test extendtraces!(sf, Dict(:y => Vector[[9.0]]), [1], -1) === sf
		@test sf.plot.data[1][:y][end] == 9.0
		@test prependtraces!(sf, Dict(:y => Vector[[0.0]]), [2], -1) === sf
		@test sf.plot.data[2][:y][1] == 0.0
		@test update!(sf, [1], Dict(:opacity => 0.3)) === sf
		@test sf.plot.data[1][:opacity] == 0.3
		@test update!(sf, 2; opacity=0.4) === sf
		@test sf.plot.data[2][:opacity] == 0.4
		@test redraw!(sf) === sf
		@test restyle!(sf, 2; opacity=0.6) === sf
		@test sf.plot.data[2][:opacity] == 0.6
		@test relayout!(sf; hovermode="x") === sf
		@test _rsp_layout(sf)[:hovermode] == "x"
		@test second_trace in sf.plot.data && third_trace in sf.plot.data
	end

	@testset "addtraces!(sf, i, traces...) inserts at an index" begin
		sf = subplots(1, 2; sync=false)
		plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row=1, col=1)
		plot_scatter!(sf, [1.0, 2.0], [3.0, 4.0]; row=1, col=1)
		inserted = scatter(x=[1, 2], y=[0, 0], name="inserted")
		@test addtraces!(sf, 2, inserted; row=1, col=2) === sf
		@test length(sf.plot.data) == 3
		@test sf.plot.data[2][:name] == "inserted"
		@test sf.plot.data[2][:xaxis] == "x2"
		@test (sf.current_row, sf.current_col) == (1, 2)
		@test addtraces!(sf, 4, scatter(y=[1]); row=1, col=1) === sf
		@test length(sf.plot.data) == 4
		@test_throws ArgumentError("addtraces!: insertion index must be in 1:5; got 6.") addtraces!(sf, 6, scatter(y=[1]); row=1, col=1)
		@test_throws ArgumentError("addtraces!: insertion index must be in 1:5; got 0.") addtraces!(sf, 0, scatter(y=[1]); row=1, col=1)
		@test length(sf.plot.data) == 4
	end

	@testset "purge!(sf) keeps the grid (#150)" begin
		sf = subplots(2, 1; sync=false, height_ratios=[3, 1], title="T")
		domain = _rsp_axis(sf, :yaxis)[:domain]
		plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row=2, col=1)
		relayout!(sf; hovermode="x")
		@test purge!(sf) === sf
		@test isempty(sf.plot.data)
		@test !haskey(_rsp_layout(sf), :hovermode)
		@test !haskey(_rsp_layout(sf), :title)
		@test _rsp_axis(sf, :yaxis)[:domain] == domain
		@test (sf.current_row, sf.current_col) == (1, 1)
		plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row=2, col=1)
		@test sf.plot.data[1][:yaxis] == "y2"
		@test _rsp_axis(sf, :yaxis)[:linecolor] == "#000000"
	end

	@testset "isopen/close/to_image on SubplotFigure (#318)" begin
		sf = subplots(1, 1; sync=false)
		@test isopen(sf) == false
		@test close(sf) === nothing
		@test_throws ArgumentError to_image(sf)
		@test_throws ArgumentError download_image(sf)
		@test sf.plot isa Plot

		live = subplots(1, 1; sync=false)
		renderer = _rsp_live!(live)
		@test isopen(live) == true
		# A window figure forwards to the SyncPlot and returns its result.
		@test to_image(live; format="png") == "ok"
		@test occursin("Plotly.toImage", last(renderer.scripts))
		@test download_image(live) === nothing
		@test occursin("Plotly.downloadImage", last(renderer.scripts))
	end

	@testset "update_scenes!/update_ternaries!/update_images! with row/col" begin
		scenes = subplots(1, 2; sync=false, specs=[Spec(kind="scene") Spec(kind="scene")])
		domain = _rsp_fields(_rsp_axis(scenes, :scene2)[:domain])
		@test update_scenes!(scenes; row=1, col=2, aspectmode="cube") === scenes
		@test _rsp_axis(scenes, :scene2)[:aspectmode] == "cube"
		@test _rsp_fields(_rsp_axis(scenes, :scene2)[:domain]) == domain
		@test !haskey(_rsp_axis(scenes, :scene), :aspectmode)
		@test (scenes.current_row, scenes.current_col) == (1, 2)
		update_scenes!(scenes; dragmode="orbit")
		@test _rsp_axis(scenes, :scene)[:dragmode] == "orbit"
		@test _rsp_axis(scenes, :scene2)[:dragmode] == "orbit"
		@test_throws ArgumentError update_xaxes!(scenes; row=1, col=1, showgrid=false)

		ternary = subplots(1, 2; sync=false, specs=[Spec(kind="ternary") Spec(kind="xy")])
		@test update_ternaries!(ternary; row=1, col=1, sum=100) === ternary
		@test _rsp_axis(ternary, :ternary)[:sum] == 100
		@test_throws ArgumentError update_ternaries!(ternary; row=1, col=2, sum=1)
		@test_throws ArgumentError update_scenes!(ternary; row=1, col=1, aspectmode="cube")

		images = subplots(1, 2; sync=false)
		relayout!(
			images;
			images=[
				attr(source="a.png", xref="x", yref="y", x=0, y=0, sizex=1, sizey=1),
				attr(source="b.png", xref="x2 domain", yref="y2 domain", x=0, y=0, sizex=1, sizey=1),
			],
		)
		@test update_images!(images; row=1, col=2, opacity=0.4) === images
		opacities = [get(_rsp_fields(i), :opacity, nothing) for i in _rsp_layout(images)[:images]]
		@test opacities == [nothing, 0.4]
	end

	@testset "cell errors name the calling function" begin
		sf = subplots(1, 2; sync=false, specs=[Spec(kind="polar") Spec(kind="xy")])
		for (call, who) in (
			(() -> add_trace!(sf, scatter(x=[1], y=[1]); row=1, col=1), "add_trace!"),
			(() -> addtraces!(sf, scatter(x=[1], y=[1]); row=1, col=1), "addtraces!"),
			(() -> plot_scatter!(sf, [1.0], [1.0]; row=1, col=1), "plot_scatter!"),
			(() -> plot_scatter!(sf, [1.0], [1.0]; row=3, col=1), "plot_scatter!"),
			(() -> plot_scatter!(sf, [1.0], [1.0]; row=true, col=1), "plot_scatter!"),
			(() -> subplot!(sf, 5), "subplot!"),
			(() -> subplot!(sf, 1, 3), "subplot!"),
			(() -> update_yaxes!(sf; row=1, col=2, secondary_y=true, type="log"), "update_yaxes!"),
		)
			err = try
				call()
				nothing
			catch caught
				caught
			end
			@test err isa ArgumentError
			@test startswith(err.msg, who * ":")
		end
		@test isempty(sf.plot.data)
		@test (sf.current_row, sf.current_col) == (1, 1)
	end

	@testset "mutators reject `show`" begin
		sf = subplots(1, 1; sync=false)
		@test_throws ArgumentError plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; show=true)
		@test isempty(sf.plot.data)
	end

	@testset "cell selection messages (#27)" begin
		sf = subplots(1, 2; sync=false, specs=[Spec(kind="polar") Spec(kind="xy")])
		err = try
			xlabel!(sf, "x"; row=1, col=1)
			nothing
		catch caught
			caught
		end
		@test err isa ArgumentError
		@test occursin("does not accept Cartesian x/y axes", err.msg)
		secondary_err = try
			PlotlySupply._subplot_xy_axis_keys(sf, 1, 2; secondary_y=true)
			nothing
		catch caught
			caught
		end
		@test secondary_err isa ArgumentError
		@test occursin("secondary y-axis", secondary_err.msg)
	end

	@testset "plot_surface!(sf; shared_coloraxis=true) links existing surfaces (#38, #101)" begin
		for psl in (true, false)
			sf = subplots(
				1,
				2;
				sync=false,
				per_subplot_legends=psl,
				specs=[Spec(kind="scene") Spec(kind="scene")],
			)
			plot_surface!(sf, rand(3, 3); row=1, col=1)
			plot_surface!(sf, 5 .+ rand(3, 3); row=1, col=2, shared_coloraxis=true)
			@test all(get(t.fields, :coloraxis, nothing) == "coloraxis" for t in sf.plot.data)
			bar = _rsp_fields(_rsp_fields(_rsp_layout(sf)[:coloraxis])[:colorbar])
			# One bar next to both scenes.
			@test bar[:x] ≈ 1.0 + PlotlySupply._CBAR_SHARED_PAD

			# Without the flag nothing else is rebound.
			plain = subplots(1, 2; sync=false, per_subplot_legends=psl, specs=[Spec(kind="scene") Spec(kind="scene")])
			plot_surface!(plain, rand(3, 3); row=1, col=1)
			plot_surface!(plain, rand(3, 3); row=1, col=2)
			@test all(!haskey(t.fields, :coloraxis) for t in plain.plot.data)

			# Live figure: the rebinding of an existing surface is sent as one
			# full Plotly.react (the append-only fast path would leave the
			# renderer's first surface unbound).
			live = subplots(1, 2; sync=false, per_subplot_legends=psl, specs=[Spec(kind="scene") Spec(kind="scene")])
			plot_surface!(live, rand(3, 3); row=1, col=1)
			renderer = _rsp_live!(live)
			plot_surface!(live, rand(3, 3); row=1, col=2, shared_coloraxis=true)
			@test all(get(t.fields, :coloraxis, nothing) == "coloraxis" for t in live.plot.data)
			@test length(renderer.scripts) == 1
			@test occursin("Plotly.react", only(renderer.scripts))
			@test !occursin("Plotly.addTraces", only(renderer.scripts))

			# Renderer failure: the live model is unchanged (rollback).
			failing = subplots(1, 2; sync=false, per_subplot_legends=psl, specs=[Spec(kind="scene") Spec(kind="scene")])
			plot_surface!(failing, rand(3, 3); row=1, col=1)
			failing_renderer = _rsp_live!(failing)
			first_surface = failing.plot.data[1]
			layout_before = deepcopy(failing.plot.layout)
			failing_renderer.fail = true
			@test_throws ErrorException("rsp renderer failure") plot_surface!(failing, rand(3, 3); row=1, col=2, shared_coloraxis=true)
			@test length(failing.plot.data) == 1
			@test failing.plot.data[1] === first_surface
			@test !haskey(failing.plot.data[1].fields, :coloraxis)
			@test failing.plot.layout == layout_before

			# A later shared surface without `colorscale` keeps the axis
			# colorscale an earlier one set (#243).
			scaled = subplots(1, 2; sync=false, per_subplot_legends=psl, specs=[Spec(kind="scene") Spec(kind="scene")])
			plot_surface!(scaled, rand(3, 3); row=1, col=1, colorscale="Viridis", shared_coloraxis=true)
			plot_surface!(scaled, rand(3, 3); row=1, col=2, shared_coloraxis=true)
			@test _rsp_fields(_rsp_layout(scaled)[:coloraxis])[:colorscale] == "Viridis"
			@test all(get(t.fields, :coloraxis, nothing) == "coloraxis" for t in scaled.plot.data)
		end
	end

	@testset "inset routing through the delegate" begin
		sf = subplots(1, 2; sync=false)
		layout = _rsp_layout(sf)
		layout[:xaxis3] = attr(domain=[0.6, 0.8], anchor="y3")
		layout[:yaxis3] = attr(domain=[0.6, 0.9], anchor="x3")
		push!(
			getfield(sf, :insets),
			PlotlySupply._SubplotInset(1, 2, :xaxis3, :yaxis3, "x3", "y3", (0.6, 0.8), (0.6, 0.9)),
		)
		plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row=1, col=2, inset=1)
		@test sf.plot.data[end][:xaxis] == "x3"
		@test sf.plot.data[end][:yaxis] == "y3"
		@test (sf.current_row, sf.current_col) == (1, 2)
		# A heatmap colorbar is placed next to the inset.
		plot_heatmap!(sf, rand(3, 3); row=1, col=2, inset=1)
		@test _rsp_fields(sf.plot.data[end][:colorbar])[:x] ≈ 0.8 + PlotlySupply._CBAR_CELL_PAD
		@test_throws ArgumentError plot_scatter!(sf, [1.0], [1.0]; row=1, col=2, inset=2)
	end

	@testset "figure legend styled with the SubplotFigure options (#2, #13)" begin
		sf = subplots(
			1,
			2;
			sync=false,
			per_subplot_legends=false,
			legend_position=:bottomleft,
			legend_bgcolor="#123456",
			legend_bordercolor="#654321",
			legend_borderwidth=2,
		)
		plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row=1, col=2, legend="a")
		legend = _rsp_fields(_rsp_layout(sf)[:legend])
		@test legend[:bgcolor] == "#123456"
		@test legend[:bordercolor] == "#654321"
		@test legend[:borderwidth] == 2
		@test legend[:yanchor] == "bottom"
		@test legend[:xanchor] == "left"
		# A legend set by the user afterwards is kept by later mutators.
		relayout!(sf; legend=attr(x=0.5, y=0.5, xanchor="center", yanchor="middle"))
		plot_scatter!(sf, [1.0, 2.0], [2.0, 3.0]; row=1, col=1, legend="b")
		@test _rsp_fields(_rsp_layout(sf)[:legend])[:x] == 0.5
	end
end
