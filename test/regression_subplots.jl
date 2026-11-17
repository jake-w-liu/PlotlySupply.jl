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
		# 2.0 (D10 M3, `_apply_equal_aspect!`): the y axis anchors to the x axis.
		@test _rsp_axis(sf, :yaxis3)[:scaleanchor] == "x3"
		@test _rsp_axis(sf, :yaxis4)[:scaleanchor] == "x4"
		@test !haskey(_rsp_axis(sf, :xaxis), :scaleanchor)
		@test !haskey(_rsp_axis(sf, :xaxis2), :scaleanchor)

		# A cell (1, 1) target keeps its own references.
		single = subplots(1, 1; sync=false)
		plot_quiver!(single, [0.0, 1], [0.0, 1], [0.5, 0.5], [0.2, 0.2])
		@test _rsp_axis(single, :yaxis)[:scaleanchor] == "x"

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
		@test startswith(err.msg, "xlabel!:")
		@test occursin("this cell is :polar", err.msg)
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
			@test_throws PlotlySupply._SyncPlotDesynchronizationError plot_surface!(failing, rand(3, 3); row=1, col=2, shared_coloraxis=true)
			@test length(failing.plot.data) == 1
			@test failing.plot.data[1] === first_surface
			@test !haskey(failing.plot.data[1].fields, :coloraxis)
			@test failing.plot.layout == layout_before

			# A later shared surface without `colorscale` keeps the axis
			# colorscale an earlier one set (#243).
			scaled = subplots(1, 2; sync=false, per_subplot_legends=psl, specs=[Spec(kind="scene") Spec(kind="scene")])
			plot_surface!(scaled, rand(3, 3); row=1, col=1, colorscale="Viridis", shared_coloraxis=true)
			plot_surface!(scaled, rand(3, 3); row=1, col=2, shared_coloraxis=true)
			# 2.0 (C20): colormap names are resolved to colour stops.
			@test _rsp_fields(_rsp_layout(scaled)[:coloraxis])[:colorscale] ==
				[Any[t, c] for (t, c) in colormap("Viridis")]
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
		# A heatmap colorbar is placed level with the inset, right of the
		# host cell (2.0, D10: never over the host plot).
		plot_heatmap!(sf, rand(3, 3); row=1, col=2, inset=1)
		@test _rsp_fields(sf.plot.data[end][:colorbar])[:x] ≈ 1.0 + PlotlySupply._CBAR_CELL_PAD
		@test _rsp_fields(sf.plot.data[end][:colorbar])[:y] ≈ 0.75
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

	@testset "the delegate runs mutators on the target axes (X32, X50)" begin
		# A log cell: ranges are converted and validated as on a log figure.
		sf = subplots(1, 2; sync=false)
		update_xaxes!(sf; row=1, col=2, type="log")
		plot_scatter!(sf, [1.0, 10.0, 100.0], [1.0, 2.0, 3.0]; row=1, col=2, xrange=[1, 100])
		@test _rsp_axis(sf, :xaxis2)[:type] == "log"
		@test _rsp_axis(sf, :xaxis2)[:range] ≈ [0.0, 2.0]
		n = length(sf.plot.data)
		err = try
			plot_scatter!(sf, [1.0, 10.0], [1.0, 2.0]; row=1, col=2, xrange=[-1, 100])
			nothing
		catch caught
			caught
		end
		@test err isa ArgumentError
		@test startswith(err.msg, "plot_scatter!:")
		@test occursin("logarithmic", err.msg)
		@test length(sf.plot.data) == n
		@test _rsp_axis(sf, :xaxis2)[:range] ≈ [0.0, 2.0]
		# Cell (1, 1) is untouched.
		@test !haskey(_rsp_axis(sf, :xaxis), :type)
		@test !haskey(_rsp_axis(sf, :xaxis), :range)

		# A histogram on a log cell is binned in log space (a bar trace of
		# explicit bins) instead of plotly's linear histogram.
		hist = subplots(1, 2; sync=false)
		update_xaxes!(hist; row=1, col=2, type="log")
		plot_histogram!(hist, exp10.(range(0, 3; length=200)); row=1, col=2)
		@test hist.plot.data[end][:type] == "bar"
		@test hist.plot.data[end][:xaxis] == "x2"
		@test _rsp_axis(hist, :xaxis2)[:type] == "log"
		linear = subplots(1, 2; sync=false)
		plot_histogram!(linear, exp10.(range(0, 3; length=200)); row=1, col=2)
		@test linear.plot.data[end][:type] == "histogram"

		# Inset axes and a secondary y axis are seeded the same way.
		ins = subplots(1, 2; sync=false)
		k = inset!(ins, (0.5, 0.5, 0.4, 0.4); row=1, col=2)
		record = ins.insets[k]
		update_xaxes!(ins; type="log")
		plot_scatter!(ins, [1.0, 100.0], [1.0, 2.0]; row=1, col=2, inset=k, xrange=[1, 100])
		@test _rsp_axis(ins, record.xkey)[:range] ≈ [0.0, 2.0]
		@test !haskey(_rsp_axis(ins, :xaxis2), :range)

		sec = subplots(1, 1; sync=false, specs=fill(Spec(secondary_y=true), 1, 1))
		plot_scatter!(sec, [1.0, 2.0], [1.0, 2.0])
		update_yaxes!(sec; row=1, col=1, secondary_y=true, type="log")
		plot_scatter!(sec, [1.0, 2.0], [1.0, 1000.0]; secondary_y=true, yrange=[1, 1000])
		@test _rsp_axis(sec, :yaxis2)[:range] ≈ [0.0, 3.0]
		@test _rsp_axis(sec, :yaxis2)[:overlaying] == "y"
		@test !haskey(_rsp_axis(sec, :yaxis), :range)

		# Seeded settings the mutator leaves alone are not re-sent; settings it
		# removes are removed from the cell (and from the live figure).
		live = subplots(1, 2; sync=false, per_subplot_legends=false)
		plot_scatter!(live, [1.0, 2.0], [1.0, 2.0]; row=1, col=1)
		update_xaxes!(live; row=1, col=2, type="log", tickmode="array", tickvals=[1, 10], ticktext=["a", "b"])
		renderer = _rsp_live!(live)
		plot_scatter!(live, [1.0, 10.0], [1.0, 2.0]; row=1, col=2)
		@test length(renderer.scripts) == 1
		@test occursin("Plotly.addTraces", only(renderer.scripts))
		@test !occursin("Plotly.relayout", only(renderer.scripts))
		@test _rsp_axis(live, :xaxis2)[:tickvals] == [1, 10]
		drop_ticks = function (fig, x, y; kwargs...)
			push!(PlotlySupply._plot_data(fig), scatter(x=x, y=y))
			PlotlySupply._cmn_delete_layout_fields!(fig, :xaxis, (:tickmode, :tickvals, :ticktext))
			return nothing
		end
		empty!(renderer.scripts)
		PlotlySupply._subplot_delegate_mutator!(live, drop_ticks, [1.0, 10.0], [1.0, 2.0]; row=1, col=2)
		axis = _rsp_axis(live, :xaxis2)
		@test !haskey(axis, :tickvals) && !haskey(axis, :ticktext) && !haskey(axis, :tickmode)
		@test axis[:type] == "log"
		@test haskey(axis, :domain)
		@test occursin("\"xaxis2.tickvals\":null", only(renderer.scripts))
		@test !occursin("xaxis2.type", only(renderer.scripts))
		# A call that adds no trace changes no axis.
		update_xaxes!(live; row=1, col=2, tickvals=[1, 10])
		no_traces = (fig; kwargs...) -> PlotlySupply._cmn_delete_layout_fields!(fig, :xaxis, (:tickvals,))
		PlotlySupply._subplot_delegate_mutator!(live, no_traces; row=1, col=2)
		@test _rsp_axis(live, :xaxis2)[:tickvals] == [1, 10]
		# A renderer failure rolls the removal back with the traces.
		update_xaxes!(live; row=1, col=2, tickmode="array", ticktext=["a", "b"])
		axis_before = deepcopy(_rsp_layout(live)[:xaxis2])
		count_before = length(live.plot.data)
		renderer.fail = true
		@test_throws PlotlySupply._SyncPlotDesynchronizationError PlotlySupply._subplot_delegate_mutator!(live, drop_ticks, [1.0, 10.0], [1.0, 2.0]; row=1, col=2)
		renderer.fail = false
		@test _rsp_layout(live)[:xaxis2] == axis_before
		@test length(live.plot.data) == count_before
	end

	@testset "style cycles continue across cells (X9)" begin
		sf = subplots(1, 2; sync=false)
		mutator = function (fig, x, y; kwargs...)
			push!(PlotlySupply._plot_data(fig), scatter(x=x, y=y, mode="lines"))
			PlotlySupply._apply_style_trace_defaults!(fig, length(PlotlySupply._plot_data(fig)))
			return nothing
		end
		with_style(; cycle=:dash) do
			PlotlySupply._subplot_delegate_mutator!(sf, mutator, [1, 2], [1, 2]; row=1, col=1)
			PlotlySupply._subplot_delegate_mutator!(sf, mutator, [1, 2], [2, 3]; row=1, col=2)
			PlotlySupply._subplot_delegate_mutator!(sf, mutator, [1, 2], [3, 4]; row=1, col=1)
		end
		dashes = [_rsp_fields(t[:line])[:dash] for t in sf.plot.data]
		@test dashes[1] != dashes[2]
		@test dashes[2] != dashes[3]
		@test length(unique(dashes)) == 3
	end

	@testset "numbered colour axes reach the figure (X51)" begin
		sf = subplots(1, 2; sync=false)
		mutator = function (fig, z; kwargs...)
			push!(PlotlySupply._plot_data(fig), heatmap(z=z, coloraxis="coloraxis2"))
			push!(PlotlySupply._plot_data(fig), heatmap(z=z, coloraxis="coloraxis10"))
			relayout!(
				fig;
				coloraxis2=attr(colorscale="Viridis", cmin=0, cmax=1),
				coloraxis10=attr(colorscale="Greys"),
			)
			return nothing
		end
		PlotlySupply._subplot_delegate_mutator!(sf, mutator, rand(3, 3); row=1, col=2)
		layout = _rsp_layout(sf)
		@test _rsp_fields(layout[:coloraxis2])[:colorscale] == "Viridis"
		@test _rsp_fields(layout[:coloraxis2])[:cmax] == 1
		@test _rsp_fields(layout[:coloraxis10])[:colorscale] == "Greys"
		@test [t[:coloraxis] for t in sf.plot.data] == ["coloraxis2", "coloraxis10"]
		# The colour axis bar is placed next to the cell.
		@test _rsp_fields(_rsp_fields(layout[:coloraxis2])[:colorbar])[:x] ≈
			_rsp_axis(sf, :xaxis2)[:domain][2] + PlotlySupply._CBAR_CELL_PAD
		@test PlotlySupply._subplot_transplanted_root_keys(
			Plot(GenericTrace[], Layout(coloraxis10=attr(cmin=0), coloraxis2=attr(cmin=1), coloraxisfoo=attr(cmin=2))),
		) == (:font, :coloraxis, :coloraxis2, :coloraxis10)
	end

	@testset "delegate errors name the public function (X52)" begin
		sf = subplots(1, 2; sync=false, specs=[Spec(kind="polar") Spec(kind="xy")])
		message(call) = try
			call()
			""
		catch caught
			caught isa ArgumentError ? caught.msg : "not an ArgumentError: $(caught)"
		end
		@test startswith(message(() -> plot_scatter!(sf, [1.0], [1.0]; row=1, col=1)), "plot_scatter!:")
		@test startswith(message(() -> plot_scatter!(sf, [1.0], [1.0]; show=true)), "plot_scatter!:")
		@test startswith(message(() -> plot_heatmap!(sf, rand(2, 2); row=3, col=1)), "plot_heatmap!:")
		@test startswith(message(() -> plot_bar!(sf, ["a"], [1.0]; row=1, col=1)), "plot_bar!:")
		anonymous = (fig, x; kwargs...) -> nothing
		@test startswith(
			message(() -> PlotlySupply._subplot_delegate_mutator!(sf, anonymous, 1; row=4, col=1)),
			"SubplotFigure:",
		)
		@test startswith(
			message(() -> PlotlySupply._subplot_delegate_mutator!(sf, anonymous, 1; row=4, col=1, delegate_who="plot_custom!")),
			"plot_custom!:",
		)
		@test startswith(
			message(() -> PlotlySupply._subplot_delegate_mutator!(sf, anonymous, 1; row=1, col=2, show=true, delegate_who="plot_custom!")),
			"plot_custom!:",
		)
		# A wrapper closure is named after the exported mutator it captures.
		wrap(m) = (fig, values...; options...) -> m(fig, values...; options...)
		@test PlotlySupply._subplot_mutator_name(wrap(plot_scatter!)) == "plot_scatter!"
		@test PlotlySupply._subplot_mutator_name(wrap(wrap(plot_bar!))) == "plot_bar!"
		@test PlotlySupply._subplot_mutator_name(plot_stem!) == "plot_stem!"
		pair(a, b) = (fig; kw...) -> (a(fig); b(fig))
		@test PlotlySupply._subplot_mutator_name(pair(plot_scatter!, plot_bar!)) == "SubplotFigure"
		@test PlotlySupply._subplot_mutator_name(pair(plot_bar!, plot_bar!)) == "plot_bar!"
		@test PlotlySupply._subplot_mutator_name(anonymous) == "SubplotFigure"
		@test isempty(sf.plot.data)
	end

	@testset "subplots(...; insets) registers the insets (X21)" begin
		sf = subplots(1, 2; sync=false, insets=[_RSP_PB.Inset(cell=(1, 2), l=0.5, w=0.4, b=0.5, h=0.4)])
		@test length(sf.insets) == 1
		record = sf.insets[1]
		host_x = _rsp_axis(sf, :xaxis2)[:domain]
		host_y = _rsp_axis(sf, :yaxis2)[:domain]
		@test (record.row, record.col) == (1, 2)
		@test (record.xkey, record.ykey, record.xref, record.yref) == (:xaxis3, :yaxis3, "x3", "y3")
		@test collect(record.xdomain) ≈ [host_x[1] + 0.5 * _rsp_span(host_x), host_x[1] + 0.9 * _rsp_span(host_x)]
		@test collect(record.ydomain) ≈ [host_y[1] + 0.5 * _rsp_span(host_y), host_y[1] + 0.9 * _rsp_span(host_y)]
		@test collect(_rsp_axis(sf, :xaxis3)[:domain]) ≈ collect(record.xdomain)
		@test _rsp_axis(sf, :xaxis3)[:automargin] == false
		@test _rsp_axis(sf, :yaxis3)[:automargin] == false

		plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; legend="host", row=1, col=2)
		plot_scatter!(sf, 1:3, [3.0, 2.0, 1.0]; legend="inset", row=1, col=2, inset=1)
		@test (sf.plot.data[2][:xaxis], sf.plot.data[2][:yaxis]) == ("x3", "y3")
		@test sf.plot.data[1][:legend] == sf.plot.data[2][:legend]
		# `inset!` numbers its insets after the grid's.
		@test inset!(sf, (0.1, 0.1, 0.3, 0.3); row=1, col=1) == 2
		# update_xaxes!/update_yaxes! address an inset's own axes.
		subplot!(sf, 1, 1)
		@test update_xaxes!(sf; inset=1, type="log") === sf
		@test _rsp_axis(sf, :xaxis3)[:type] == "log"
		@test !haskey(_rsp_axis(sf, :xaxis2), :type)
		@test !haskey(_rsp_axis(sf, :xaxis2), :inset) && !haskey(_rsp_axis(sf, :xaxis3), :inset)
		@test (sf.current_row, sf.current_col) == (1, 2)
		@test update_yaxes!(sf; row=1, col=1, inset=2, title_text="inset y") === sf
		inset2_y = sf.insets[2].ykey
		@test _rsp_fields(_rsp_axis(sf, inset2_y)[:title])[:text] == "inset y"
		@test !haskey(_rsp_axis(sf, :yaxis), :title) ||
			get(_rsp_fields(_rsp_axis(sf, :yaxis)[:title]), :text, "") != "inset y"
		layout_before = deepcopy(sf.plot.layout)
		for (call, fragment) in (
			(() -> update_xaxes!(sf; inset=3, type="log"), "unknown inset id 3"),
			(() -> update_xaxes!(sf; row=1, col=1, inset=1, type="log"), "belongs to cell (1, 2)"),
			(() -> update_yaxes!(sf; inset=1, secondary_y=true, type="log"), "no secondary y-axis"),
			(() -> update_xaxes!(sf; row=1, inset=1, type="log"), "together"),
		)
			err = try
				call()
				nothing
			catch caught
				caught
			end
			@test err isa ArgumentError
			@test occursin(fragment, err.msg)
		end
		@test sf.plot.layout == layout_before
		update_xaxes!(sf; inset=1, type="linear")
		# "to_end" sizes reach the host's edge.
		to_end = subplots(2, 1; sync=false, insets=[_RSP_PB.Inset(cell=(2, 1), l=0.6, b=0.7)])
		host = _rsp_axis(to_end, :xaxis2)[:domain]
		@test to_end.insets[1].xdomain[2] ≈ host[2]
		@test to_end.insets[1].ydomain[2] ≈ _rsp_axis(to_end, :yaxis2)[:domain][2]
		# Secondary y axes: the inset axes follow every grid axis.
		secondary = subplots(1, 1; sync=false, specs=fill(Spec(secondary_y=true), 1, 1),
			insets=[_RSP_PB.Inset(cell=(1, 1), l=0.6, w=0.3, b=0.6, h=0.3)])
		@test (secondary.insets[1].xkey, secondary.insets[1].ykey) == (:xaxis2, :yaxis3)

		# purge! keeps the grid's insets and drops `inset!` ones.
		purge!(sf)
		@test length(sf.insets) == 1
		@test sf.insets[1].xkey == :xaxis3
		@test collect(_rsp_axis(sf, :xaxis3)[:domain]) ≈ collect(record.xdomain)
		plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; row=1, col=2, inset=1)
		@test sf.plot.data[end][:xaxis] == "x3"

		# Other kinds pass through to PlotlyBase without an `inset` id; the
		# Cartesian ids count Cartesian insets only.
		mixed = subplots(1, 2; sync=false, insets=[
			_RSP_PB.Inset(cell=(1, 1), kind="scene", l=0.5, w=0.4, b=0.5, h=0.4),
			_RSP_PB.Inset(cell=(1, 2), l=0.5, w=0.4, b=0.5, h=0.4),
		])
		@test haskey(_rsp_layout(mixed), :scene)
		@test length(mixed.insets) == 1
		@test (mixed.insets[1].row, mixed.insets[1].col, mixed.insets[1].xkey) == (1, 2, :xaxis3)
		plot_scatter!(mixed, 1:3, [1.0, 2.0, 3.0]; row=1, col=2, inset=1)
		@test mixed.plot.data[end][:xaxis] == "x3"

		for (insets, fragment) in (
			([_RSP_PB.Inset(cell=(2, 2))], "outside the 1 × 2 grid"),
			([_RSP_PB.Inset(cell=(3, 1), kind="map")], "outside the 1 × 2 grid"),
			([_RSP_PB.Inset(cell=(0, 1))], "outside the 1 × 2 grid"),
			([_RSP_PB.Inset(cell=(1, 2), colspan=2)], "colspan/rowspan"),
			([_RSP_PB.Inset(cell=(1, 2), l=0.7, w=0.5)], "reaches outside its cell"),
			([_RSP_PB.Inset(cell=(1, 2), b=0.5, h=0.6)], "reaches outside its cell"),
			([_RSP_PB.Inset(cell=(1, 2), l=-0.1)], "`insets[1].l`"),
			([_RSP_PB.Inset(cell=(1, 2), l=1.0)], "`insets[1].l`"),
			([_RSP_PB.Inset(cell=(1, 2), b=NaN)], "`insets[1].b`"),
			([_RSP_PB.Inset(cell=(1, 2), w=0.0)], "`insets[1].w`"),
			([_RSP_PB.Inset(cell=(1, 2), h="half")], "`insets[1].h`"),
			(true, "vector of `Inset"),
			(nothing, "vector of `Inset"),
		)
			err = try
				subplots(1, 2; sync=false, insets=insets)
				nothing
			catch caught
				caught
			end
			@test err isa ArgumentError
			@test startswith(err.msg, "subplots:")
			@test occursin(fragment, err.msg)
		end
		polar_host = try
			subplots(1, 2; sync=false, specs=[Spec(kind="polar") Spec()], insets=[_RSP_PB.Inset(cell=(1, 1))])
			nothing
		catch caught
			caught
		end
		@test polar_host isa ArgumentError
		@test occursin("not a Cartesian", polar_host.msg)
		@test isempty(subplots(1, 2; sync=false, insets=_RSP_PB.Inset[]).insets)
	end

	@testset "inset and secondary-axis traces use the host cell's legend (X19, X26)" begin
		sf = subplots(1, 2; sync=false)
		plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; legend="left", row=1, col=1)
		plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; legend="host", row=1, col=2)
		k = inset!(sf, (0.5, 0.5, 0.4, 0.4); row=1, col=2)
		plot_scatter!(sf, 1:3, [3.0, 2.0, 1.0]; legend="inset", row=1, col=2, inset=k)
		@test [t[:legend] for t in sf.plot.data] == ["legend", "legend2", "legend2"]
		@test !haskey(_rsp_layout(sf), :legend3)
		# The legend box stays inside the host cell.
		legend2 = _rsp_fields(_rsp_layout(sf)[:legend2])
		@test legend2[:x] <= _rsp_axis(sf, :xaxis2)[:domain][2]
		@test legend2[:xanchor] == "right"

		# Inset in a non-(1, 1) cell of a 2 × 2 grid, before any host trace.
		grid = subplots(2, 2; sync=false)
		plot_scatter!(grid, 1:3, [1.0, 2.0, 3.0]; legend="a", row=1, col=1)
		k2 = inset!(grid, (0.6, 0.6, 0.35, 0.35); row=2, col=2)
		plot_scatter!(grid, 1:3, [1.0, 2.0, 3.0]; legend="in", row=2, col=2, inset=k2)
		plot_scatter!(grid, 1:3, [1.0, 2.0, 3.0]; legend="host", row=2, col=2)
		@test grid.plot.data[2][:legend] == grid.plot.data[3][:legend] != "legend"
		box = _rsp_fields(_rsp_layout(grid)[Symbol(grid.plot.data[2][:legend])])
		host_x = _rsp_axis(grid, :xaxis4)[:domain]
		@test host_x[1] <= box[:x] <= host_x[2]

		sec = subplots(2, 1; sync=false, specs=fill(Spec(secondary_y=true), 2, 1))
		plot_scatter!(sec, 1:3, [1.0, 2.0, 3.0]; legend="a", row=1, col=1)
		plot_scatter!(sec, 1:3, [1.0, 2.0, 3.0]; legend="b", row=2, col=1)
		plot_scatter!(sec, 1:3, [3.0, 2.0, 1.0]; legend="c", row=2, col=1, secondary_y=true)
		@test [t[:legend] for t in sec.plot.data] == ["legend", "legend2", "legend2"]

		# A pair in no cell, or inside overlapping cells, keeps its own legend.
		p = sf.plot
		@test PlotlySupply._legend_inset_host(p, "x2", "y2", (0.6, 0.9), (0.5, 0.9)) === nothing
		@test PlotlySupply._legend_inset_host(p, "x9", "y9", (0.40, 0.60), (0.1, 0.2)) === nothing
		host = PlotlySupply._legend_inset_host(p, "x9", "y9", (0.6, 0.9), (0.5, 0.9))
		@test host[1:2] == ("x2", "y2")
	end

	@testset "families route into an inset of a non-(1, 1) cell (X20)" begin
		sf = subplots(1, 2; sync=false)
		k = inset!(sf, (0.55, 0.55, 0.4, 0.4); row=1, col=2)
		record = sf.insets[k]
		plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; legend="s", row=1, col=2, inset=k)
		plot_heatmap!(sf, rand(3, 4); row=1, col=2, inset=k)
		plot_bar!(sf, ["a", "b"], [1.0, 2.0]; row=1, col=2, inset=k)
		plot_contour!(sf, rand(4, 4); row=1, col=2, inset=k)
		@test [t[:type] for t in sf.plot.data] == ["scatter", "heatmap", "bar", "contour"]
		@test all(t[:xaxis] == record.xref && t[:yaxis] == record.yref for t in sf.plot.data)
		@test all(get(t.fields, :legend, "legend") == "legend" for t in sf.plot.data)
		@test !haskey(_rsp_layout(sf), :legend2)
		# Host axes are untouched.
		@test !haskey(_rsp_axis(sf, :xaxis2), :range)
		@test (sf.current_row, sf.current_col) == (1, 2)
	end

	@testset "new cell legends take the style's legend font (X8b)" begin
		with_style(:publication) do
			sf = subplots(1, 3; sync=false)
			plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; legend="a", row=1, col=1)
			plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; legend="b", row=1, col=2)
			size1 = _rsp_fields(_rsp_fields(_rsp_layout(sf)[:legend])[:font])[:size]
			size2 = _rsp_fields(_rsp_fields(_rsp_layout(sf)[:legend2])[:font])[:size]
			@test size2 == size1 == PlotlySupply._active_style().legend_fontsize
			# A font the user set is kept by later calls.
			relayout!(sf; legend2=attr(font=attr(size=20, color="red")))
			plot_scatter!(sf, 1:3, [3.0, 2.0, 1.0]; legend="c", row=1, col=2)
			font2 = _rsp_fields(_rsp_fields(_rsp_layout(sf)[:legend2])[:font])
			@test font2[:size] == 20
			@test font2[:color] == "red"
		end
		# Legend colours follow the active template (X8a) and accept Symbols and
		# other AbstractStrings (X5).
		dark = with_style(; template=:plotly_dark) do
			subplots(1, 1; sync=false)
		end
		light = subplots(1, 1; sync=false)
		@test (dark.legend_bgcolor, dark.legend_bordercolor) == ("rgba(17,17,17,0.72)", "rgba(255,255,255,0.25)")
		@test (light.legend_bgcolor, light.legend_bordercolor) == ("rgba(255,255,255,0.72)", "rgba(0,0,0,0.15)")
		named = subplots(1, 1; sync=false, legend_bgcolor=:red, legend_bordercolor=SubString("blue", 1))
		@test (named.legend_bgcolor, named.legend_bordercolor) == ("#FF0000", "#0000FF")
		@test_throws ArgumentError subplots(1, 1; sync=false, legend_bgcolor=:notacolour)
		# The default style sets no legend font.
		plain = subplots(1, 2; sync=false)
		plot_scatter!(plain, 1:3, [1.0, 2.0, 3.0]; legend="a", row=1, col=1)
		plot_scatter!(plain, 1:3, [1.0, 2.0, 3.0]; legend="b", row=1, col=2)
		@test !haskey(_rsp_fields(_rsp_layout(plain)[:legend2]), :font)
	end

	@testset "add_trace!/addtraces! and the delegate refresh legends (X4)" begin
		fig_legend = subplots(1, 2; sync=false, per_subplot_legends=false,
			legend_position=:outside_bottom, legend_bgcolor=:red)
		plot_scatter!(fig_legend, 1:3, [1.0, 2.0, 3.0]; legend="only", row=1, col=2)
		legend = _rsp_fields(_rsp_layout(fig_legend)[:legend])
		@test legend[:bgcolor] == "#FF0000"
		@test legend[:yref] == "container"
		@test _rsp_layout(fig_legend)[:showlegend] == true

		added = subplots(1, 1; sync=false, per_subplot_legends=false, legend_position=:bottomleft)
		add_trace!(added, scatter(x=[1, 2], y=[1, 2], name="n"))
		@test _rsp_fields(_rsp_layout(added)[:legend])[:xanchor] == "left"
		@test _rsp_fields(_rsp_layout(added)[:legend])[:yanchor] == "bottom"

		cells = subplots(1, 2; sync=false)
		add_trace!(cells, scatter(x=[1, 2], y=[1, 2], name="a"); row=1, col=1)
		add_trace!(cells, scatter(x=[1, 2], y=[1, 2], name="b"); row=1, col=2)
		@test [t[:legend] for t in cells.plot.data] == ["legend", "legend2"]
		@test _rsp_fields(_rsp_layout(cells)[:legend2])[:x] <= _rsp_axis(cells, :xaxis2)[:domain][2]
		# Inserted traces join their cell's legend (ids follow trace order, so
		# the cells' ids swap; every box is re-placed in its own cell).
		addtraces!(cells, 1, scatter(x=[1, 2], y=[2, 3], name="c"); row=1, col=2)
		@test cells.plot.data[1][:name] == "c"
		@test cells.plot.data[1][:legend] == cells.plot.data[3][:legend] != cells.plot.data[2][:legend]
		addtraces!(cells, scatter(x=[1, 2], y=[2, 3], name="d"), scatter(x=[1, 2], y=[3, 4], name="e"); row=1, col=1)
		@test cells.plot.data[4][:legend] == cells.plot.data[5][:legend] == cells.plot.data[2][:legend]
		for (trace_index, xkey) in ((1, :xaxis2), (2, :xaxis))
			box = _rsp_fields(_rsp_layout(cells)[Symbol(cells.plot.data[trace_index][:legend])])
			domain = _rsp_axis(cells, xkey)[:domain]
			@test domain[1] <= box[:x] <= domain[2]
		end
	end

	@testset "cell legends sit inside the cell, clear of its colorbar (V2)" begin
		sf = subplots(1, 2; sync=false, specs=[Spec() Spec(kind="scene")])
		plot_heatmap!(sf, collect(0.0:4), collect(0.0:4), rand(5, 5); row=1, col=1)
		plot_scatter!(sf, collect(0.0:4), collect(0.0:4); legend="diagonal", row=1, col=1)
		xs = collect(range(-1, 1; length=5))
		plot_surface!(sf, xs, xs, [x * y for x in xs, y in xs]; row=1, col=2)
		plot_scatter3d!(sf, [0.0, 1.0], [0.0, 1.0], [0.0, 1.0]; legend="segment", row=1, col=2)
		xdomain = _rsp_axis(sf, :xaxis)[:domain]
		scene_x = _rsp_fields(_rsp_fields(_rsp_layout(sf)[:scene])[:domain])[:x]
		for (legend_key, domain, trace) in ((:legend, xdomain, sf.plot.data[1]), (:legend2, scene_x, sf.plot.data[3]))
			box = _rsp_fields(_rsp_layout(sf)[legend_key])
			bar = _rsp_fields(trace[:colorbar])
			@test box[:xanchor] == "right"
			@test domain[1] < box[:x] <= domain[2]
			@test bar[:x] ≈ domain[2] + PlotlySupply._CBAR_CELL_PAD
			@test bar[:xanchor] == "left"
		end
		@test [get(t.fields, :legend, nothing) for t in sf.plot.data] == ["legend", "legend", "legend2", "legend2"]
		for position in (:topright, :right, :bottomright, :top, :bottomleft)
			placed = subplots(1, 1; sync=false, legend_position=position)
			plot_heatmap!(placed, rand(3, 3))
			plot_scatter!(placed, 1:3, [1.0, 2.0, 3.0]; legend="s")
			box = _rsp_fields(_rsp_layout(placed)[:legend])
			bar = _rsp_fields(placed.plot.data[1][:colorbar])
			domain = _rsp_axis(placed, :xaxis)[:domain]
			@test domain[1] <= box[:x] <= domain[2]
			@test box[:x] < bar[:x]
		end
	end

	@testset "root modes: no duplicate delegate barmode handling (K4, K8)" begin
		# The delegate copies an explicit bar mode without warning (the stats
		# family reports it) and adds no offset groups of its own.
		sf = subplots(1, 2; sync=false)
		bars = function (fig, x, y; barmode="", kwargs...)
			push!(PlotlySupply._plot_data(fig), _RSP_PB.bar(x=x, y=y), _RSP_PB.bar(x=x, y=y))
			isempty(barmode) || relayout!(fig; barmode=barmode)
			return nothing
		end
		auto_overlay = function (fig, x, y; kwargs...)
			push!(PlotlySupply._plot_data(fig), _RSP_PB.bar(x=x, y=y), _RSP_PB.bar(x=x, y=y))
			relayout!(fig; barmode="overlay")
			return nothing
		end
		PlotlySupply._subplot_delegate_mutator!(sf, bars, ["a"], [1.0]; barmode="group", row=1, col=1)
		@test_logs PlotlySupply._subplot_delegate_mutator!(sf, bars, ["a"], [1.0]; barmode="stack", row=1, col=2)
		@test _rsp_layout(sf)[:barmode] == "stack"
		PlotlySupply._subplot_delegate_mutator!(sf, auto_overlay, ["a"], [1.0]; row=1, col=2)
		@test _rsp_layout(sf)[:barmode] == "stack"
		@test all(!haskey(t.fields, :offsetgroup) for t in sf.plot.data)
		@test !isdefined(PlotlySupply, :_subplot_overlay_new_bars!)

		# An explicit box mode that re-arranges boxes in another cell warns.
		boxes = function (fig, y; boxmode="", kwargs...)
			push!(PlotlySupply._plot_data(fig), _RSP_PB.box(y=y))
			isempty(boxmode) || relayout!(fig; boxmode=boxmode)
			return nothing
		end
		bx = subplots(1, 2; sync=false)
		PlotlySupply._subplot_delegate_mutator!(bx, boxes, [1.0, 2.0]; boxmode="group", row=1, col=1)
		@test_logs (:warn, r"boxmode.*WHOLE figure") PlotlySupply._subplot_delegate_mutator!(
			bx, boxes, [1.0, 2.0]; boxmode="overlay", row=1, col=2, delegate_who="plot_custom!")
		@test _rsp_layout(bx)[:boxmode] == "overlay"
		@test_logs PlotlySupply._subplot_delegate_mutator!(bx, boxes, [1.0, 2.0]; boxmode="overlay", row=1, col=1)
	end

	@testset "axis references are retargeted for insets, secondary and shared axes (X38)" begin
		anchored = function (fig, x, y; kwargs...)
			push!(PlotlySupply._plot_data(fig), scatter(x=x, y=y))
			relayout!(fig; yaxis=attr(scaleanchor="x", scaleratio=2), xaxis=attr(constrain="domain"))
			return nothing
		end
		sf = subplots(2, 2; sync=false, specs=[Spec() Spec(); Spec() Spec(secondary_y=true)])
		k = inset!(sf, (0.5, 0.5, 0.4, 0.4); row=2, col=1)
		record = sf.insets[k]
		PlotlySupply._subplot_delegate_mutator!(sf, anchored, [1, 2], [1, 2]; row=2, col=1, inset=k)
		@test _rsp_axis(sf, record.ykey)[:scaleanchor] == record.xref
		@test _rsp_axis(sf, record.ykey)[:scaleratio] == 2
		@test _rsp_axis(sf, record.ykey)[:anchor] == record.xref
		@test _rsp_axis(sf, record.xkey)[:constrain] == "domain"
		@test !haskey(_rsp_axis(sf, :yaxis3), :scaleanchor)

		PlotlySupply._subplot_delegate_mutator!(sf, anchored, [1, 2], [1, 2]; row=2, col=2, secondary_y=true)
		trace = sf.plot.data[end]
		ykey = Symbol("yaxis", trace[:yaxis][2:end])
		xref = trace[:xaxis]
		@test _rsp_axis(sf, ykey)[:scaleanchor] == xref
		@test _rsp_axis(sf, ykey)[:anchor] == xref
		@test haskey(_rsp_axis(sf, ykey), :overlaying)
		@test !any(get(_rsp_axis(sf, key), :scaleanchor, nothing) == "x" for key in (:yaxis, :yaxis2, :yaxis3))

		shared = subplots(2, 1; sync=false, shared_xaxes=true)
		matches_before = get(_rsp_axis(shared, :xaxis), :matches, nothing)
		@test matches_before !== nothing
		PlotlySupply._subplot_delegate_mutator!(shared, anchored, [1, 2], [1, 2]; row=2, col=1)
		@test get(_rsp_axis(shared, :xaxis), :matches, nothing) == matches_before
		@test _rsp_axis(shared, :yaxis2)[:scaleanchor] == "x2"
		@test !haskey(_rsp_axis(shared, :yaxis), :scaleanchor)
	end

	@testset "axis helpers on Plot and SyncPlot (#318)" begin
		p = plot_scatter(1:3, [1.0, 2.0, 3.0])
		@test xlabel!(p, "X") === nothing
		@test _rsp_fields(_rsp_fields(p.layout.fields[:xaxis])[:title])[:text] == "X"
		@test xrange!(p, [0, 4]) === nothing
		@test _rsp_fields(p.layout.fields[:xaxis])[:range] == [0, 4]
		@test_throws ArgumentError xrange!(p, [0, 1, 2])

		sp, renderer = _rsp_syncplot(plot_scatter(1:3, [1.0, 2.0, 3.0]))
		@test xlabel!(sp, "time") === nothing
		@test _rsp_fields(_rsp_fields(sp.plot.layout.fields[:xaxis])[:title])[:text] == "time"
		@test xrange!(sp, [1, 2]) === nothing
		@test _rsp_fields(sp.plot.layout.fields[:xaxis])[:range] == [1, 2]
		@test length(renderer.scripts) == 2
		@test all(occursin("Plotly.relayout", script) for script in renderer.scripts)
		@test occursin("time", renderer.scripts[1])
	end

	@testset "README subplots pattern: axis helpers address the intended cell (#307)" begin
		sf = subplots(2, 2; sync=false, legend_position=:topright)
		plot!(sf, 1:100, cumsum(ones(100)); legend="run A")
		xlabel!(sf, "time"); ylabel!(sf, "value"); xrange!(sf, [0, 100])
		subplot!(sf, 1, 2)
		plot_stem!(sf, 1:100, ones(100); legend="run B")
		subplot!(sf, 3)
		plot_contour!(sf, rand(30, 30))
		subplot!(sf, 2, 2)
		plot_heatmap!(sf, rand(30, 30))
		@test _rsp_axis(sf, :xaxis)[:range] == [0, 100]
		@test _rsp_fields(_rsp_axis(sf, :xaxis)[:title])[:text] == "time"
		@test _rsp_fields(_rsp_axis(sf, :yaxis)[:title])[:text] == "value"
		@test !haskey(_rsp_axis(sf, :xaxis4), :range)
		# The contour and heatmap colorbars sit next to their own cells.
		bars = [_rsp_fields(t[:colorbar])[:x] for t in sf.plot.data if t[:type] in ("contour", "heatmap")]
		@test bars[1] ≈ _rsp_axis(sf, :xaxis3)[:domain][2] + PlotlySupply._CBAR_CELL_PAD
		@test bars[2] ≈ _rsp_axis(sf, :xaxis4)[:domain][2] + PlotlySupply._CBAR_CELL_PAD
		# Helpers act on the active cell: after `subplot!(sf, 2, 2)` they need
		# `row`/`col` to reach cell (1, 1).
		xlabel!(sf, "seconds"; row=1, col=1)
		@test _rsp_fields(_rsp_axis(sf, :xaxis)[:title])[:text] == "seconds"
		@test !haskey(_rsp_axis(sf, :xaxis4), :title) ||
			get(_rsp_fields(_rsp_axis(sf, :xaxis4)[:title]), :text, "") == ""
	end

	@testset "one nested-layout normalizer (#27, X2)" begin
		@test PlotlySupply._normalize_nested_layout_value(:title, "T") == attr(text="T")
		value = attr(text="kept")
		@test PlotlySupply._normalize_nested_layout_value(:title, value) === value
		@test PlotlySupply._normalize_nested_layout_value(:xaxis, "x") == "x"
		@test !isdefined(PlotlySupply, :_normalize_nested_layout_source)
		@test !isdefined(PlotlySupply, :_normalize_nested_layout_existing)
		# The delegate's axis merge promotes a bare-string title on either side.
		retitle = function (fig, x, y; axis_title, kwargs...)
			push!(PlotlySupply._plot_data(fig), scatter(x=x, y=y))
			relayout!(fig; xaxis=attr(title=axis_title))
			return nothing
		end
		sf = subplots(1, 2; sync=false)
		update_xaxes!(sf; row=1, col=2, title=attr(text="old", font=attr(size=9)))
		PlotlySupply._subplot_delegate_mutator!(sf, retitle, [1, 2], [1, 2]; axis_title="new", row=1, col=2)
		title = _rsp_fields(_rsp_axis(sf, :xaxis2)[:title])
		@test title[:text] == "new"
		@test _rsp_fields(title[:font])[:size] == 9
		_rsp_layout(sf)[:xaxis] = attr(domain=_rsp_axis(sf, :xaxis)[:domain], anchor="y", title="kept")
		PlotlySupply._subplot_delegate_mutator!(sf, retitle, [1, 2], [1, 2]; axis_title=attr(font=attr(size=11)), row=1, col=1)
		title1 = _rsp_fields(_rsp_axis(sf, :xaxis)[:title])
		@test title1[:text] == "kept"
		@test _rsp_fields(title1[:font])[:size] == 11
	end
end
