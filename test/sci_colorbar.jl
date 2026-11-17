using Test, PlotlySupply

# Colorbar placement in SubplotFigure cells (F5), colorbar! (F6),
# shared_colorbar! (F7), colorbar title sides (A12) and grey-level colour
# strings (A1).

const _SCB = PlotlySupply
const _SCB_PB = PlotlySupply.PlotlyBase

_scb_fields(value) = value isa _SCB_PB.PlotlyAttribute ? value.fields : value
_scb_layout(p::Plot) = p.layout.fields
_scb_layout(sf::SubplotFigure) = sf.plot.layout.fields
_scb_axis(fig, key::Symbol) = _scb_fields(_scb_layout(fig)[key])
_scb_bar(trace) = _scb_fields(trace.fields[:colorbar])
_scb_marker_bar(trace) = _scb_fields(_scb_fields(trace.fields[:marker])[:colorbar])
_scb_axis_bar(fig, id::Symbol = :coloraxis) = _scb_fields(_scb_axis(fig, id)[:colorbar])
_scb_title(bar) = _scb_fields(bar[:title])
_scb_mid(domain) = (domain[1] + domain[2]) / 2
_scb_span(domain) = domain[2] - domain[1]

function _scb_annotations(fig, prefix::AbstractString)
	items = get(_scb_layout(fig), :annotations, Any[])
	return [
		_scb_fields(item) for item in items
		if startswith(string(get(_scb_fields(item), :name, "")), prefix)
	]
end

function _scb_error(f)
	try
		f()
	catch err
		return err
	end
	return nothing
end

function _scb_throws(f, needle::AbstractString)
	err = _scb_error(f)
	return err isa ArgumentError && occursin(needle, err.msg)
end

# Recording renderer for SyncPlot-backed figures; `fail` makes every script
# throw so rollback can be checked.
mutable struct _SCBRenderer
	scripts::Vector{String}
	fail::Bool
end

function _scb_live!(sf::SubplotFigure)
	renderer = _SCBRenderer(String[], false)
	backend = (
		isopen = window -> true,
		close = window -> nothing,
		run = (window, script) -> begin
			renderer.fail && throw(ErrorException("scb renderer failure"))
			push!(renderer.scripts, String(script))
			return "ok"
		end,
	)
	sf.fig = SyncPlot(
		sf.plot,
		nothing,
		:scb_window,
		"scb-div",
		_SCB._SyncPlotResources(nothing, backend),
	)
	return renderer
end

function _scb_heatmap_grid(rows::Int, cols::Int; scale = 1.0)
	sf = subplots(rows, cols; sync=false)
	values = Matrix{Float64}[]
	for r in 1:rows, c in 1:cols
		z = scale * ((r - 1) * cols + c) .+ rand(4, 4)
		push!(values, z)
		plot_heatmap!(sf, z; row=r, col=c)
	end
	return sf, values
end

@testset "sci: colorbars" begin
	@testset "cell colorbars sit next to their cell (F5, #262, #224, #42)" begin
		sf = subplots(1, 2; sync=false)
		plot_heatmap!(sf, rand(5, 5); row=1, col=1)
		plot_heatmap!(sf, 1000 .* rand(5, 5); row=1, col=2)
		xd1 = _scb_axis(sf, :xaxis)[:domain]
		xd2 = _scb_axis(sf, :xaxis2)[:domain]
		b1 = _scb_bar(sf.plot.data[1])
		b2 = _scb_bar(sf.plot.data[2])
		@test b1[:x] ≈ xd1[2] + _SCB._CBAR_CELL_PAD
		@test b2[:x] ≈ xd2[2] + _SCB._CBAR_CELL_PAD
		@test b1[:x] < xd2[1]
		@test b1[:len] ≈ 1.0
		@test b1[:y] ≈ 0.5
		@test (b1[:xanchor], b1[:yanchor], b1[:lenmode]) == ("left", "middle", "fraction")
		@test b1[:thickness] == _SCB._CBAR_CELL_THICKNESS

		# 2 × 1 grid: every bar spans its own row.
		col = subplots(2, 1; sync=false)
		plot_contour!(col, rand(5, 5); row=1, col=1)
		plot_heatmap!(col, rand(5, 5); row=2, col=1)
		for (index, key) in ((1, :yaxis), (2, :yaxis2))
			domain = _scb_axis(col, key)[:domain]
			bar = _scb_bar(col.plot.data[index])
			@test bar[:y] ≈ _scb_mid(domain)
			@test bar[:len] ≈ _scb_span(domain)
		end

		# histogram2d cells.
		hist = subplots(1, 2; sync=false)
		plot_histogram2d!(hist, randn(100), randn(100); row=1, col=1)
		plot_histogram2d!(hist, randn(100), randn(100); row=1, col=2)
		bars = [_scb_bar(t) for t in hist.plot.data]
		@test bars[1][:x] ≈ _scb_axis(hist, :xaxis)[:domain][2] + _SCB._CBAR_CELL_PAD
		@test bars[2][:x] ≈ _scb_axis(hist, :xaxis2)[:domain][2] + _SCB._CBAR_CELL_PAD

		# Scene cells use the scene domain.
		scenes = subplots(1, 2; sync=false, specs=[Spec(kind="scene") Spec(kind="scene")])
		plot_surface!(scenes, rand(3, 3); row=1, col=1)
		plot_surface!(scenes, rand(3, 3); row=1, col=2)
		scene_domain = _scb_fields(_scb_axis(scenes, :scene)[:domain])
		@test _scb_bar(scenes.plot.data[1])[:x] ≈ scene_domain[:x][2] + _SCB._CBAR_CELL_PAD
		@test _scb_bar(scenes.plot.data[2])[:x] ≈ 1.0 + _SCB._CBAR_CELL_PAD

		# Traces without a colour scale get no bar.
		plain = subplots(1, 1; sync=false)
		plot_scatter!(plain, [1.0, 2.0], [1.0, 2.0])
		@test !haskey(plain.plot.data[1].fields, :colorbar)
	end

	@testset "_place_cell_colorbars! keeps user settings" begin
		layout = Layout(
			xaxis=attr(domain=[0.0, 0.4]),
			yaxis=attr(domain=[0.2, 0.8]),
			xaxis2=attr(domain=[0.6, 1.0]),
			yaxis2=attr(domain=[0.2, 0.8]),
		)
		p = Plot(
			[
				heatmap(z=rand(3, 3), colorbar=attr(x=0.3)),
				heatmap(z=rand(3, 3), colorbar=attr(thickness=20, orientation="h")),
				heatmap(z=rand(3, 3), showscale=false),
				contour(z=rand(3, 3), contours=attr(coloring="none")),
				heatmap(z=rand(3, 3), xaxis="x2", yaxis="y2", colorbar=attr(len=0.5)),
			],
			layout,
		)
		_SCB._place_cell_colorbars!(p, 2)
		# Before start_index: untouched; an explicit x: untouched.
		@test _scb_bar(p.data[1]) == Dict{Symbol,Any}(:x => 0.3)
		bottom = _scb_bar(p.data[2])
		@test bottom[:orientation] == "h"
		@test bottom[:x] ≈ 0.2
		@test bottom[:y] ≈ 0.2 - _SCB._CBAR_BOTTOM_OFFSET
		@test bottom[:yanchor] == "top"
		@test bottom[:len] ≈ 0.4
		@test bottom[:thickness] == 20
		@test !haskey(p.data[3].fields, :colorbar)
		@test !haskey(p.data[4].fields, :colorbar)
		right = _scb_bar(p.data[5])
		@test right[:x] ≈ 1.0 + _SCB._CBAR_CELL_PAD
		@test right[:len] == 0.5
		@test _SCB._place_cell_colorbars!(p, length(p.data) + 1) === nothing

		# A bar with an explicit x is kept even when it is the first trace.
		q = Plot([heatmap(z=rand(3, 3), colorbar=attr(x=0.3))], layout)
		_SCB._place_cell_colorbars!(q, 1)
		@test _scb_bar(q.data[1]) == Dict{Symbol,Any}(:x => 0.3)
	end

	@testset "coloraxis bars follow the cells that use them" begin
		layout = Layout(
			xaxis=attr(domain=[0.0, 0.45]),
			yaxis=attr(domain=[0.0, 1.0]),
			xaxis2=attr(domain=[0.55, 1.0]),
			yaxis2=attr(domain=[0.0, 1.0]),
		)
		p = Plot([heatmap(z=rand(3, 3), coloraxis="coloraxis")], layout)
		_SCB._place_cell_colorbars!(p, 1)
		bar = _scb_axis_bar(p)
		@test bar[:x] ≈ 0.45 + _SCB._CBAR_CELL_PAD
		@test !haskey(p.data[1].fields, :colorbar)
		push!(p.data, heatmap(z=rand(3, 3), coloraxis="coloraxis", xaxis="x2", yaxis="y2"))
		_SCB._place_cell_colorbars!(p, 2)
		@test _scb_axis_bar(p)[:x] ≈ 1.0 + _SCB._CBAR_SHARED_PAD
		@test _scb_axis_bar(p)[:len] ≈ 1.0

		# A bar the user placed stays.
		user = Plot([heatmap(z=rand(3, 3), coloraxis="coloraxis")], deepcopy(layout))
		_scb_layout(user)[:coloraxis] = attr(colorbar=attr(x=0.7))
		_SCB._place_cell_colorbars!(user, 1)
		@test _scb_axis_bar(user)[:x] == 0.7
		push!(user.data, heatmap(z=rand(3, 3), coloraxis="coloraxis", xaxis="x2", yaxis="y2"))
		_SCB._place_cell_colorbars!(user, 2)
		@test _scb_axis_bar(user)[:x] == 0.7
		# showscale = false: nothing is written.
		hidden = Plot([heatmap(z=rand(3, 3), coloraxis="coloraxis")], deepcopy(layout))
		_scb_layout(hidden)[:coloraxis] = attr(showscale=false)
		_SCB._place_cell_colorbars!(hidden, 1)
		@test !haskey(_scb_axis(hidden, :coloraxis), :colorbar)

		# The coloraxis and colorbar objects are updated in place, so a layout
		# alias of them (here under `meta`) sees the placed bar.
		aliased = Plot([heatmap(z=rand(3, 3), coloraxis="coloraxis")], deepcopy(layout))
		cbar_obj = Dict{Symbol,Any}(:thickness => 20)
		axis_obj = Dict{Symbol,Any}(:cmin => 0.0, :colorbar => cbar_obj)
		_scb_layout(aliased)[:coloraxis] = axis_obj
		_scb_layout(aliased)[:meta] = Dict{Symbol,Any}(:coloraxis => axis_obj)
		_SCB._place_cell_colorbars!(aliased, 1)
		@test _scb_layout(aliased)[:coloraxis] === axis_obj
		@test axis_obj[:colorbar] === cbar_obj
		@test cbar_obj[:x] ≈ 0.45 + _SCB._CBAR_CELL_PAD
		@test cbar_obj[:thickness] == 20
		@test axis_obj[:cmin] == 0.0
		# A mapping that cannot hold Symbol keys/any values is replaced.
		typed = Plot([heatmap(z=rand(3, 3), coloraxis="coloraxis")], deepcopy(layout))
		typed_axis = Dict{String,Float64}("cmin" => 0.0)
		_scb_layout(typed)[:coloraxis] = typed_axis
		_SCB._place_cell_colorbars!(typed, 1)
		@test _scb_layout(typed)[:coloraxis] !== typed_axis
		@test _scb_axis(typed, :coloraxis)[:cmin] == 0.0
		@test _scb_axis_bar(typed)[:x] ≈ 0.45 + _SCB._CBAR_CELL_PAD
		@test typed_axis == Dict("cmin" => 0.0)
	end

	@testset "math colorbar titles become annotations" begin
		layout = Layout(xaxis=attr(domain=[0.0, 0.45]), yaxis=attr(domain=[0.0, 1.0]))
		p = Plot(
			[heatmap(z=rand(3, 3), colorbar=attr(title=attr(text="\$E\$", side="right")))],
			layout,
		)
		_SCB._place_cell_colorbars!(p, 1)
		@test !haskey(_scb_bar(p.data[1]), :title)
		anns = _scb_annotations(p, "plotlysupply:colorbar_title:x:")
		@test length(anns) == 1
		@test anns[1][:name] == "plotlysupply:colorbar_title:x:right"
		@test anns[1][:text] == "\$E\$"
		@test anns[1][:textangle] == -90
		@test anns[1][:x] ≈ 0.45 + _SCB._CBAR_CELL_PAD
		@test anns[1][:xref] == "paper"

		# Plain titles stay on the bar; the helpers are no-ops while deferred.
		q = Plot(
			[
				heatmap(z=rand(3, 3), colorbar=attr(x=1.02, title=attr(text="plain"))),
				heatmap(z=rand(3, 3), colorbar=attr(x=1.02, title=attr(text="\$m\$"))),
			],
			Layout(),
		)
		Base.ScopedValues.with(_SCB._CBAR_DEFER_MATH_TITLES => true) do
			_SCB._colorbar_math_titles!(q, 1:2)
		end
		@test isempty(_scb_annotations(q, "plotlysupply:colorbar_title:"))
		_SCB._colorbar_math_titles!(q, 1:2)
		@test _scb_title(_scb_bar(q.data[1]))[:text] == "plain"
		@test !haskey(_scb_bar(q.data[2]), :title)
		@test length(_scb_annotations(q, "plotlysupply:colorbar_title:")) == 1

		@test _SCB._colorbar_title_attr("") === nothing
		title = _scb_fields(_SCB._colorbar_title_attr("T", :right))
		@test (title[:text], title[:side]) == ("T", "right")
		@test _scb_throws(() -> _SCB._colorbar_title_attr("T", :left; who="plot_x"), "plot_x")
	end

	@testset "colorbar! edits one cell (F6, A12)" begin
		sf, _ = _scb_heatmap_grid(1, 2)
		xd1 = _scb_axis(sf, :xaxis)[:domain]
		xd2 = _scb_axis(sf, :xaxis2)[:domain]
		yd1 = _scb_axis(sf, :yaxis)[:domain]
		subplot!(sf, 1, 1)
		@test colorbar!(sf; row=1, col=2, title="Power", title_side=:right) === sf
		@test (sf.current_row, sf.current_col) == (1, 2)
		b2 = _scb_bar(sf.plot.data[2])
		@test _scb_title(b2)[:text] == "Power"
		@test _scb_title(b2)[:side] == "right"
		@test b2[:x] ≈ xd2[2] + _SCB._CBAR_CELL_PAD
		@test !haskey(_scb_bar(sf.plot.data[1]), :title)

		colorbar!(
			sf;
			row=1,
			col=1,
			side=:bottom,
			ticks=[0, 0.5, 1],
			ticklabels=["lo", "mid", "hi"],
			thickness=8,
			len=0.3,
			tickformat=".1f",
			exponentformat="power",
			outlinewidth=0,
		)
		b1 = _scb_bar(sf.plot.data[1])
		@test b1[:orientation] == "h"
		# Below the x tick labels (D12, G1): `len` keeps finalize's placement,
		# centred on the cell, which has its width back (its right bar went).
		plan = _SCB._room_plan(sf)
		slot = _SCB._room_slot(plan, :colorbar, "bar:1")
		@test slot.side === :bottom && slot.offset > plan.areas[:xaxis].own[:bottom] > 0
		@test b1[:y] ≈ yd1[1] - slot.offset / plan.Hp
		@test b1[:yanchor] == "top" && b1[:yref] == "paper"
		@test b1[:x] ≈ _scb_mid(_scb_axis(sf, :xaxis)[:domain])
		@test _scb_axis(sf, :xaxis)[:domain][2] ≈ 0.45
		@test b1[:len] ≈ 0.3
		@test b1[:tickmode] == "array"
		@test b1[:tickvals] == [0.0, 0.5, 1.0]
		@test b1[:ticktext] == ["lo", "mid", "hi"]
		@test b1[:thickness] == 8
		@test b1[:tickformat] == ".1f"
		@test b1[:exponentformat] == "power"
		@test b1[:outlinewidth] == 0.0

		# The geometry is rewritten on every call; x/y override it.
		colorbar!(sf; row=1, col=1, x=0.2, y=0.9)
		b1 = _scb_bar(sf.plot.data[1])
		@test (b1[:x], b1[:y], b1[:orientation]) == (0.2, 0.9, "v")
		@test b1[:tickvals] == [0.0, 0.5, 1.0]

		# Math titles are annotations that follow the bar.
		for side in (:top, :right, :bottom)
			colorbar!(sf; row=1, col=2, title="\$|E|^2\$", title_side=side)
			anns = _scb_annotations(sf, "plotlysupply:colorbar_title:x2:")
			@test length(anns) == 1
			@test anns[1][:name] == "plotlysupply:colorbar_title:x2:$(side)"
			@test anns[1][:text] == "\$|E|^2\$"
			@test !haskey(_scb_bar(sf.plot.data[2]), :title)
		end
		colorbar!(sf; row=1, col=2, x=0.9)
		@test only(_scb_annotations(sf, "plotlysupply:colorbar_title:x2:"))[:x] == 0.9
		colorbar!(sf; row=1, col=2, title="plain", title_side=:top)
		@test isempty(_scb_annotations(sf, "plotlysupply:colorbar_title:x2:"))
		@test _scb_title(_scb_bar(sf.plot.data[2]))[:text] == "plain"
		# No title: the current one is kept.
		colorbar!(sf; row=1, col=2, thickness=10)
		@test _scb_title(_scb_bar(sf.plot.data[2]))[:text] == "plain"

		# Errors leave the figure unchanged.
		data_before = deepcopy(sf.plot.data)
		layout_before = deepcopy(sf.plot.layout)
		for (kwargs, needle) in (
			((side=:left,), "`side`"),
			((title_side=:left,), "`title_side`"),
			((ticklabels=["a"],), "ticklabels"),
			((ticks=[1, 2], ticklabels=["a"]), "ticklabels"),
			((ticks=[1, NaN],), "ticks"),
			((exponentformat="bogus",), "exponentformat"),
			((outlinewidth=-1,), "outlinewidth"),
			((len=-1,), "len"),
			((x=NaN,), "x"),
			((col=nothing,), "together"),
			((col=3,), "`col`"),
			((coloraxis="bogus",), "coloraxis"),
			((coloraxis=:shared,), "no trace uses coloraxis"),
		)
			call = () -> colorbar!(sf; merge((row=1, col=1), kwargs)...)
			@test _scb_throws(call, "colorbar!")
			@test _scb_throws(call, needle)
		end
		@test sf.plot.data == data_before
		@test sf.plot.layout == layout_before

		empty = subplots(1, 2; sync=false)
		plot_heatmap!(empty, rand(3, 3); row=1, col=1)
		plot_scatter!(empty, [1.0], [1.0]; row=1, col=2)
		@test _scb_throws(() -> colorbar!(empty; row=1, col=2), "has no coloured trace")

		# Plot / single figure.
		p = plot_heatmap(rand(3, 3))
		@test colorbar!(p; title="T", side=:bottom) === nothing
		@test _scb_bar(p.data[1])[:orientation] == "h"
		@test _scb_title(_scb_bar(p.data[1]))[:text] == "T"
		@test _scb_throws(() -> colorbar!(p; row=1, col=1), "omit them")
		@test _scb_throws(() -> colorbar!(plot_scatter(1:3, 1:3)), "no coloured trace")
	end

	@testset "colorbar! on traces bound to a coloraxis and in insets" begin
		sf, _ = _scb_heatmap_grid(1, 2)
		shared_colorbar!(sf)
		colorbar!(sf; row=1, col=1, title="shared", title_side=:right)
		bar = _scb_axis_bar(sf)
		@test _scb_title(bar)[:text] == "shared"
		# Bar of a coloraxis: next to every cell that uses it.
		@test bar[:x] ≈ 1.0 + _SCB._CBAR_SHARED_PAD
		colorbar!(sf; row=1, col=1, coloraxis=:shared)
		@test _scb_axis_bar(sf)[:x] ≈ _scb_axis(sf, :xaxis)[:domain][2] + _SCB._CBAR_CELL_PAD

		inset = subplots(1, 2; sync=false)
		layout = _scb_layout(inset)
		layout[:xaxis3] = attr(domain=[0.6, 0.8], anchor="y3")
		layout[:yaxis3] = attr(domain=[0.6, 0.9], anchor="x3")
		push!(
			getfield(inset, :insets),
			_SCB._SubplotInset(1, 2, :xaxis3, :yaxis3, "x3", "y3", (0.6, 0.8), (0.6, 0.9)),
		)
		plot_heatmap!(inset, rand(3, 3); row=1, col=2, inset=1)
		colorbar!(inset; row=1, col=2, ticks=[0, 1])
		@test _scb_bar(inset.plot.data[1])[:tickvals] == [0.0, 1.0]
		# 2.0 (D10): the bar of an inset trace sits right of its host cell,
		# level with the inset, not over the host plot.
		inset_bar = _scb_bar(inset.plot.data[1])
		@test inset_bar[:x] ≈ 1.0 + _SCB._CBAR_CELL_PAD
		@test inset_bar[:y] ≈ 0.75
		@test inset_bar[:len] ≈ 0.3
	end

	@testset "shared_colorbar! (F7, #51, #231)" begin
		sf, values = _scb_heatmap_grid(1, 3; scale=5.0)
		@test shared_colorbar!(sf; title="I", colorscale="viridis") === sf
		@test all(t.fields[:coloraxis] == "coloraxis" for t in sf.plot.data)
		@test all(!haskey(t.fields, :colorbar) for t in sf.plot.data)
		axis = _scb_axis(sf, :coloraxis)
		@test axis[:cmin] == minimum(minimum.(values))
		@test axis[:cmax] == maximum(maximum.(values))
		@test axis[:colorscale] isa AbstractVector
		@test axis[:showscale] == true
		bar = _scb_axis_bar(sf)
		@test bar[:x] ≈ 1.0 + _SCB._CBAR_SHARED_PAD
		@test bar[:len] ≈ 0.75
		@test bar[:y] ≈ 0.5
		@test _scb_title(bar)[:text] == "I"

		# A subset of cells; the others keep their bars.
		grid, values = _scb_heatmap_grid(2, 2)
		shared_colorbar!(grid; cells=[(1, 1), (1, 2)], crange=[0, 3], side=:bottom, len=0.5)
		@test [get(t.fields, :coloraxis, nothing) for t in grid.plot.data] ==
			["coloraxis", "coloraxis", nothing, nothing]
		@test haskey(grid.plot.data[3].fields, :colorbar)
		axis = _scb_axis(grid, :coloraxis)
		@test (axis[:cmin], axis[:cmax]) == (0.0, 3.0)
		bar = _scb_axis_bar(grid)
		top = _scb_axis(grid, :yaxis)[:domain]
		@test bar[:orientation] == "h"
		# Below the x tick labels of row 1, which gives up the height the bar
		# needs so that it stays clear of row 2 (D12, G1).
		plan = _SCB._room_plan(grid)
		slot = _SCB._room_slot(plan, :colorbar, "coloraxis:coloraxis")
		@test bar[:y] ≈ top[1] - slot.offset / plan.Hp
		@test bar[:y] - slot.px / plan.Hp >= _scb_axis(grid, :yaxis3)[:domain][2] - 1e-9
		@test collect(_scb_axis(grid, :yaxis2)[:domain]) ≈ collect(top)
		@test bar[:len] ≈ 0.5
		@test bar[:x] ≈ 0.5

		# cmid: automatic limits centred on cmid.
		centred, _ = _scb_heatmap_grid(1, 2)
		shared_colorbar!(centred; cmid=0)
		axis = _scb_axis(centred, :coloraxis)
		@test axis[:cmid] == 0.0
		@test !haskey(axis, :cmin) && !haskey(axis, :cmax)

		# Plotly-computed colour data: automatic limits.
		hist = subplots(1, 2; sync=false)
		plot_histogram2d!(hist, randn(50), randn(50); row=1, col=1)
		plot_histogram2d!(hist, randn(50), randn(50); row=1, col=2)
		shared_colorbar!(hist; coloraxis="coloraxis2")
		@test all(t.fields[:coloraxis] == "coloraxis2" for t in hist.plot.data)
		@test !haskey(_scb_axis(hist, :coloraxis2), :cmin)

		# Errors leave the figure unchanged.
		check, _ = _scb_heatmap_grid(1, 2)
		data_before = deepcopy(check.plot.data)
		layout_before = deepcopy(check.plot.layout)
		for (kwargs, needle) in (
			((crange=[1, 0],), "increasing"),
			((crange=[0, 1], cmid=1.0), "cmid"),
			((crange=[0, 1], cmid=-0.5), "strictly inside"),
			((cmid=NaN,), "cmid"),
			((len=0,), "len"),
			((side=:left,), "`side`"),
			((title_side=:middle,), "title_side"),
			((colorscale="no-such-scale",), "colorscale"),
			((coloraxis="axis",), "coloraxis"),
			((cells=[(3, 1)],), "outside"),
			((cells=[(1,)],), "(row, col)"),
			((cells=Tuple{Int,Int}[],), "must not be empty"),
			((cells="all",), "`cells`"),
		)
			@test _scb_throws(() -> shared_colorbar!(check; kwargs...), "shared_colorbar!")
			@test _scb_throws(() -> shared_colorbar!(check; kwargs...), needle)
		end
		@test check.plot.data == data_before
		@test check.plot.layout == layout_before

		scatter_only = subplots(1, 1; sync=false)
		plot_scatter!(scatter_only, [1.0, 2.0], [1.0, 2.0])
		@test _scb_throws(() -> shared_colorbar!(scatter_only), "no coloured trace")
		@test _scb_throws(() -> shared_colorbar!(plot_heatmap(rand(2, 2)); cells=[(1, 1)]), "`cells`")

		# Plot form.
		p = plot_heatmap(rand(3, 3))
		push!(p.data, heatmap(z=2 .+ rand(3, 3)))
		@test shared_colorbar!(p; crange=[0, 3]) === nothing
		@test all(t.fields[:coloraxis] == "coloraxis" for t in p.data)
	end

	@testset "shared_colorbar! with filled contours (plotly.js coloraxis limitation)" begin
		# Filled contours keep their own scale settings, equal to the shared ones.
		sf = subplots(1, 3; sync=false)
		plot_heatmap!(sf, rand(4, 4); row=1, col=1)
		plot_contour!(sf, 2 .+ rand(4, 4); row=1, col=2)
		plot_contour!(sf, rand(4, 4); row=1, col=3)
		_scb_fields(sf.plot.data[3].fields)[:contours] = attr(coloring="heatmap")
		shared_colorbar!(sf; colorscale="viridis")
		heat, filled, smooth = sf.plot.data
		axis = _scb_axis(sf, :coloraxis)
		@test heat.fields[:coloraxis] == "coloraxis"
		@test smooth.fields[:coloraxis] == "coloraxis"  # coloring = "heatmap" binds fine
		@test !haskey(filled.fields, :coloraxis)
		@test filled.fields[:showscale] == false
		@test !haskey(filled.fields, :colorbar)
		@test filled.fields[:zauto] == false
		@test (filled.fields[:zmin], filled.fields[:zmax]) == (axis[:cmin], axis[:cmax])
		@test filled.fields[:colorscale] == axis[:colorscale]
		@test axis[:cmax] ≈ maximum(filled.fields[:z])

		# Only contours: the first draws the shared bar, no coloraxis is written.
		contours = subplots(1, 2; sync=false)
		plot_contour!(contours, rand(4, 4); row=1, col=1)
		plot_contour!(contours, 5 .+ rand(4, 4); row=1, col=2)
		shared_colorbar!(contours; title="C")
		first_contour, second_contour = contours.plot.data
		@test !haskey(_scb_layout(contours), :coloraxis)
		@test first_contour.fields[:showscale] == true
		@test second_contour.fields[:showscale] == false
		bar = _scb_bar(first_contour)
		@test bar[:x] ≈ 1.0 + _SCB._CBAR_SHARED_PAD
		@test bar[:len] ≈ 0.75
		@test _scb_title(bar)[:text] == "C"
		@test first_contour.fields[:zmin] == second_contour.fields[:zmin]
		@test first_contour.fields[:zmax] == second_contour.fields[:zmax]
		# No scale given: both name the template's contour scale explicitly.
		template = _scb_layout(contours)[:template]
		@test first_contour.fields[:colorscale] ==
			_scb_fields(first(template.data[:contour]))[:colorscale]
		@test second_contour.fields[:colorscale] == first_contour.fields[:colorscale]

		# cmid: the centred range is written out for the contours.
		centred = subplots(1, 2; sync=false)
		plot_heatmap!(centred, [-1.0 0.5; 0.0 0.2]; row=1, col=1)
		plot_contour!(centred, [-0.2 3.0; 0.0 0.1]; row=1, col=2)
		shared_colorbar!(centred; cmid=0)
		axis = _scb_axis(centred, :coloraxis)
		@test (axis[:cmin], axis[:cmax]) == (-3.0, 3.0)
		@test (centred.plot.data[2].fields[:zmin], centred.plot.data[2].fields[:zmax]) == (-3.0, 3.0)

		# Plotly-computed contour data needs an explicit crange.
		hist = Plot([histogram2dcontour(x=randn(30), y=randn(30)), heatmap(z=rand(3, 3))], Layout())
		before = deepcopy(hist.data)
		@test _scb_throws(() -> shared_colorbar!(hist), "crange")
		@test hist.data == before
		shared_colorbar!(hist; crange=[0, 10])
		@test (hist.data[1].fields[:zmin], hist.data[1].fields[:zmax]) == (0.0, 10.0)
		@test hist.data[2].fields[:coloraxis] == "coloraxis"
	end

	@testset "shared_colorbar! carries bar settings over" begin
		p = Plot(
			[
				heatmap(z=rand(3, 3), colorbar=attr(
					tickvals=[0, 1], ticktext=["1", "10"], tickformat=".2f",
					title=attr(text="dB"), x=0.4,
				)),
				heatmap(z=1 .+ rand(3, 3), colorbar=attr(tickvals=[1, 2], ticktext=["X", "100"])),
			],
			Layout(),
		)
		shared_colorbar!(p)
		bar = _scb_axis_bar(p)
		@test bar[:tickmode] == "array"
		@test bar[:tickvals] == [0.0, 1.0, 2.0]
		@test bar[:ticktext] == ["1", "10", "100"]  # the first label of a value wins
		@test bar[:tickformat] == ".2f"
		@test _scb_title(bar)[:text] == "dB"
		@test bar[:x] ≈ 1.0 + _SCB._CBAR_SHARED_PAD  # geometry is not carried

		titled = Plot([heatmap(z=rand(3, 3), colorbar=attr(title=attr(text="dB")))], Layout())
		shared_colorbar!(titled; title="Override")
		@test _scb_title(_scb_axis_bar(titled))[:text] == "Override"

		# A math title (an annotation) moves to the shared bar.
		math = subplots(1, 2; sync=false)
		plot_heatmap!(math, rand(3, 3); row=1, col=1)
		plot_heatmap!(math, rand(3, 3); row=1, col=2)
		colorbar!(math; row=1, col=1, title="\$\\alpha\$")
		@test length(_scb_annotations(math, "plotlysupply:colorbar_title:x:")) == 1
		shared_colorbar!(math)
		@test isempty(_scb_annotations(math, "plotlysupply:colorbar_title:x:"))
		shared_anns = _scb_annotations(math, "plotlysupply:colorbar_title:coloraxis:")
		@test length(shared_anns) == 1
		@test shared_anns[1][:text] == "\$\\alpha\$"
	end

	@testset "shared_colorbar! skips flat colours and respects carriers" begin
		cone_trace = cone(
			x=[0.0], y=[0.0], z=[0.0], u=[1.0], v=[1.0], w=[1.0],
			colorscale=[[0, "red"], [1, "red"]], showscale=false,
		)
		flat = Plot(
			[
				heatmap(z=rand(3, 3)),
				cone_trace,
				contour(z=rand(3, 3), contours=attr(coloring="none")),
			],
			Layout(),
		)
		shared_colorbar!(flat)
		@test flat.data[1].fields[:coloraxis] == "coloraxis"
		@test !haskey(flat.data[2].fields, :coloraxis)
		@test !haskey(flat.data[3].fields, :coloraxis)
		only_flat = Plot([cone_trace], Layout())
		@test _scb_throws(() -> shared_colorbar!(only_flat), "no coloured trace")

		carrier() = _SCB._colorbar_carrier_trace(stops="viridis", cmin=0, cmax=2)
		with_carrier = Plot([heatmap(z=rand(3, 3)), carrier()], Layout())
		shared_colorbar!(with_carrier)
		axis = _scb_axis(with_carrier, :coloraxis)
		@test (axis[:cmin], axis[:cmax]) == (0.0, 2.0)
		@test axis[:colorscale] == _scb_fields(with_carrier.data[2].fields[:marker])[:colorscale]
		@test _scb_fields(with_carrier.data[2].fields[:marker])[:coloraxis] == "coloraxis"
		@test !haskey(_scb_fields(with_carrier.data[2].fields[:marker]), :showscale)

		# The same limits/scale are accepted; anything else throws.
		agreeing = Plot([heatmap(z=rand(3, 3)), carrier()], Layout())
		shared_colorbar!(agreeing; crange=[0, 2], colorscale="viridis")
		@test _scb_axis(agreeing, :coloraxis)[:cmax] == 2.0
		for (make, kwargs, needle) in (
			(() -> Plot([heatmap(z=rand(3, 3)), carrier()], Layout()), (crange=[0, 1],), "carrier"),
			(() -> Plot([heatmap(z=rand(3, 3)), carrier()], Layout()), (colorscale="plasma",), "carrier"),
			(() -> Plot([heatmap(z=rand(3, 3)), carrier()], Layout()), (cmid=1,), "carrier"),
			(
				() -> Plot(
					[carrier(), _SCB._colorbar_carrier_trace(stops="viridis", cmin=0, cmax=5)],
					Layout(),
				),
				(;),
				"different colour limits",
			),
			(
				() -> Plot(
					[carrier(), _SCB._colorbar_carrier_trace(stops="plasma", cmin=0, cmax=2)],
					Layout(),
				),
				(;),
				"different colour scales",
			),
		)
			fig = make()
			before = deepcopy(fig.data)
			@test _scb_throws(() -> shared_colorbar!(fig; kwargs...), needle)
			@test fig.data == before
		end
	end

	@testset "colorbar!/shared_colorbar! run as one renderer transaction" begin
		sf, _ = _scb_heatmap_grid(1, 2)
		renderer = _scb_live!(sf)
		colorbar!(sf; row=1, col=1, title="t")
		@test length(renderer.scripts) == 1
		shared_colorbar!(sf)
		@test length(renderer.scripts) == 2
		@test occursin("Plotly.react", renderer.scripts[2])

		failing, _ = _scb_heatmap_grid(1, 2)
		failing_renderer = _scb_live!(failing)
		data_before = deepcopy(failing.plot.data)
		layout_before = deepcopy(failing.plot.layout)
		failing_renderer.fail = true
		@test_throws PlotlySupply._SyncPlotDesynchronizationError shared_colorbar!(failing)
		@test failing.plot.data == data_before
		@test failing.plot.layout == layout_before
	end

	@testset "grey-level colour strings (A1)" begin
		@test _SCB._color_hex("0") == "#000000"
		@test _SCB._color_hex("1") == "#FFFFFF"
		@test _SCB._color_hex("0.35") == "#595959"
		@test _SCB._color_hex(" 0.5 ") == "#808080"
		@test _SCB._color_hex(Symbol("0.5")) == "#808080"
		for bad in ("1.5", "-0.1", "NaN", "Inf")
			err = _scb_error(() -> _SCB._color_hex(bad; who="grey"))
			@test err isa ArgumentError
			@test occursin("grey level", err.msg)
		end
		# Grey levels work wherever colours are parsed.
		sf = subplots(1, 1; sync=false, legend_bgcolor="0.9")
		@test sf.legend_bgcolor == "#E6E6E6"
	end

	@testset "bar details (D10 M4)" begin
		# A placed bar is exactly as long as its cell: no padding at its ends.
		right = _SCB._cbar_placement(:right, (0.0, 0.4), (0.2, 0.8), 0.01)
		@test right[:ypad] == 0 && !haskey(right, :xpad)
		@test right[:len] ≈ 0.6
		bottom = _SCB._cbar_placement(:bottom, (0.0, 0.4), (0.2, 0.8), 0.01)
		@test bottom[:xpad] == 0 && !haskey(bottom, :ypad)

		# shared_colorbar! keeps limits the members set themselves.
		sf = subplots(1, 2; sync=false)
		x = collect(range(0, 1; length=5))
		z = [0.998 * sin(2pi * a) * cos(2pi * b) for a in x, b in x]
		plot_heatmap!(sf, x, x, z; row=1, col=1, crange=[-1, 1])
		plot_heatmap!(sf, x, x, 0.5 .* z; row=1, col=2, crange=[-1, 1])
		shared_colorbar!(sf)
		axis = _scb_axis(sf, :coloraxis)
		@test (axis[:cmin], axis[:cmax]) == (-1.0, 1.0)
		# Without explicit limits the data range is used.
		auto = subplots(1, 2; sync=false)
		plot_heatmap!(auto, x, x, z; row=1, col=1)
		plot_heatmap!(auto, x, x, 0.5 .* z; row=1, col=2)
		shared_colorbar!(auto)
		axis = _scb_axis(auto, :coloraxis)
		@test (axis[:cmin], axis[:cmax]) == extrema(z)

		# A math title on the right sits beside the tick labels; the right
		# margin grows to fit it.
		f = subplots(1, 1; sync=false)
		plot_heatmap!(f, x, x, z)
		colorbar!(f; title=raw"$E_z$", title_side=:right, ticks=[-1, 0, 1])
		bar = _scb_bar(f.plot.data[1])
		note = only(_scb_annotations(f, _SCB._CBAR_TITLE_ANNOTATION_PREFIX))
		font = _SCB._cbar_font_size(f.plot, bar)
		labels = 2 * _SCB._CBAR_CHAR_EM * font                               # "-1"
		@test note[:xshift] ≈ _SCB._CBAR_DEFAULT_XPAD + bar[:thickness] + 3 + labels + 4
		@test note[:textangle] == -90
		@test _scb_fields(_scb_layout(f)[:margin])[:r] > 50

		# A title on top clears the end tick label (half a text line above
		# the bar end when the bar has no end padding).
		top = subplots(1, 1; sync=false)
		plot_heatmap!(top, x, x, z)
		colorbar!(top; title=raw"$E_z$", title_side=:top)
		note = only(_scb_annotations(top, _SCB._CBAR_TITLE_ANNOTATION_PREFIX))
		font = _SCB._cbar_font_size(top.plot, _scb_bar(top.plot.data[1]))
		@test note[:yshift] ≈ 2 + 0.5 * _SCB._CBAR_LINE_EM * font
		@test note[:yanchor] == "bottom"

		# A bar `_finalize_figure!` placed on a scratch figure is placed again
		# for the cell it lands in.
		p = Plot(
			[heatmap(z=[1 2; 3 4], xaxis="x2", yaxis="y2",
				colorbar=attr(x=0.9, xanchor="left", xref="paper", len=1.0, lenmode="fraction", y=0.5, ypad=0))],
			Layout(xaxis2=attr(domain=[0.55, 1.0]), yaxis2=attr(domain=[0.0, 0.45])),
		)
		_SCB._place_cell_colorbars!(p, 1)
		bar = _scb_bar(p.data[1])
		@test bar[:x] ≈ 1.0 + _SCB._CBAR_CELL_PAD
		@test bar[:len] ≈ 0.45
		@test bar[:y] ≈ 0.225
		@test !haskey(bar, :xref)
	end
	@testset "a hidden bar keeps the math title of the shown one (G47)" begin
		r = collect(range(1.0, 2.0; length=6))
		θ = collect(range(0.0, π; length=9))
		X = [ri * sin(t) for ri in r, t in θ]
		Z = [ri * cos(t) for ri in r, t in θ]
		C = [ri + t for ri in r[1:end-1], t in θ[1:end-1]]
		T = raw"$|E_\phi|$"
		for side in (:top, :right)
			mirror = plot_pcolormesh(X, Z, C; colorscale="magma")
			plot_pcolormesh!(mirror, -X, Z, C; colorscale="magma", showscale=false)
			colorbar!(mirror; title=T, title_side=side)
			notes = _scb_annotations(mirror, _SCB._CBAR_TITLE_ANNOTATION_PREFIX)
			@test length(notes) == 1
			@test endswith(notes[1][:name], ":$(side)") && occursin("E_\\phi", notes[1][:text])
			# A later edit (no new title) keeps it too.
			colorbar!(mirror; ticks=[1, 2, 3])
			@test length(_scb_annotations(mirror, _SCB._CBAR_TITLE_ANNOTATION_PREFIX)) == 1

			h = plot_heatmap(rand(4, 4))
			plot_heatmap!(h, 4:7, 0:3, rand(4, 4); showscale=false)
			colorbar!(h; title=T, title_side=side)
			@test length(_scb_annotations(h, _SCB._CBAR_TITLE_ANNOTATION_PREFIX)) == 1
		end
		# The hidden bar gets the title on the bar (nothing drawn).
		h = plot_heatmap(rand(4, 4))
		plot_heatmap!(h, 4:7, 0:3, rand(4, 4); showscale=false)
		colorbar!(h; title="plain")
		@test _scb_title(_scb_bar(h.data[1]))[:text] == "plain"
		@test isempty(_scb_annotations(h, _SCB._CBAR_TITLE_ANNOTATION_PREFIX))
	end

	@testset "shared_colorbar! keeps the colours the traces were drawn with (G2)" begin
		sf = subplots(1, 2; sync=false)
		plot_heatmap!(sf, [-1.0 0.5; 0.2 1.0]; row=1, col=1)
		plot_heatmap!(sf, [-2.0 0.5; 0.2 3.0]; row=1, col=2)
		@test !haskey(sf.plot.data[1].fields, :colorscale)
		shared_colorbar!(sf)
		axis = _scb_axis(sf, :coloraxis)
		# The template's heatmap scale, so plotly's autocolorscale does not
		# switch signed data to a diverging scale.
		template = _scb_layout(sf)[:template]
		@test axis[:colorscale] == _scb_fields(first(template.data[:heatmap]))[:colorscale]
		# A scale a trace sets wins.
		named = subplots(1, 2; sync=false)
		plot_heatmap!(named, rand(2, 2); row=1, col=1, colorscale="viridis")
		plot_heatmap!(named, rand(2, 2); row=1, col=2)
		shared_colorbar!(named)
		@test _scb_axis(named, :coloraxis)[:colorscale] == named.plot.data[1].fields[:colorscale]
	end

	@testset "shared_colorbar! cmid inside an explicit crange (G8)" begin
		sf, _ = _scb_heatmap_grid(1, 2)
		shared_colorbar!(sf; crange=[-1, 3], cmid=0, colorscale="RdBu")
		axis = _scb_axis(sf, :coloraxis)
		@test (axis[:cmin], axis[:cmax]) == (-1.0, 3.0)
		@test !haskey(axis, :cmid)
		stops = _SCB._cbar_scale_stops(axis[:colorscale], false)
		base = _SCB._cbar_scale_stops("RdBu", false)
		# Two-slope remap (F4): the scale's middle (0.5) moves to cmid at 0.25.
		@test _SCB._cbar_same_stops(stops, _SCB._cbar_scale_stops(_SCB._two_slope_stops(base, 0.25), false))
		@test first(stops)[2] == first(base)[2] && last(stops)[2] == last(base)[2]
		@test issorted([Float64(t) for (t, _) in stops])
		@test stops != base
		# cmid in the middle of the range: the scale is unchanged.
		even, _ = _scb_heatmap_grid(1, 2)
		shared_colorbar!(even; crange=[-1, 1], cmid=0, colorscale="RdBu")
		@test _SCB._cbar_same_stops(_SCB._cbar_scale_stops(_scb_axis(even, :coloraxis)[:colorscale], false), base)
	end

	@testset "colorbar! keeps finalize's placement; x and y release it" begin
		sf = subplots(1, 2; sync=false)
		plot_heatmap!(sf, 1e4 .* rand(4, 4); row=1, col=1)
		plot_scatter!(sf, 1:3, 1:3; row=1, col=2)
		bar = _scb_bar(sf.plot.data[1])
		@test bar[:xref] == "paper"                      # the cell is narrowed for it
		x0 = bar[:x]
		colorbar!(sf; row=1, col=1, title="T")
		bar = _scb_bar(sf.plot.data[1])
		@test bar[:xref] == "paper" && bar[:x] ≈ x0 && bar[:len] ≈ 1.0
		# `len` keeps the placement and our mark, centred on the cell.
		colorbar!(sf; row=1, col=1, len=0.5)
		bar = _scb_bar(sf.plot.data[1])
		@test bar[:xref] == "paper" && bar[:len] ≈ 0.5 && bar[:y] ≈ 0.5
		# Without `len` again the bar follows the cell.
		colorbar!(sf; row=1, col=1)
		@test _scb_bar(sf.plot.data[1])[:len] ≈ 1.0
		# x/y place it: no mark, finalize leaves it alone.
		colorbar!(sf; row=1, col=1, x=0.3, y=0.4)
		bar = _scb_bar(sf.plot.data[1])
		@test (bar[:x], bar[:y]) == (0.3, 0.4) && !haskey(bar, :xref)
		@test _SCB._finalize_figure!(sf) === false
		@test (_scb_bar(sf.plot.data[1])[:x], _scb_bar(sf.plot.data[1])[:y]) == (0.3, 0.4)
		# A horizontal bar carries the mark on y.
		colorbar!(sf; row=1, col=1, side=:bottom)
		bar = _scb_bar(sf.plot.data[1])
		@test bar[:yref] == "paper" && bar[:yanchor] == "top" && !haskey(bar, :xref)
		@test _SCB._fin_bar_owned(bar)
		colorbar!(sf; row=1, col=1, side=:bottom, y=-0.3)
		bar = _scb_bar(sf.plot.data[1])
		@test bar[:y] == -0.3 && !haskey(bar, :yref) && !_SCB._fin_bar_owned(bar)
	end

	@testset "short titled bars still render (G63)" begin
		x = range(0, 6; length=121)
		y = range(0, 1.8; length=37)
		sf = subplots(1, 2; sync=false, horizontal_spacing=0.16)
		for c in 1:2
			plot_heatmap!(sf, x, y, [c * sin(a) * b for a in x, b in y]; row=1, col=c, equalar=true,
				colorscale="cividis")
		end
		shared_colorbar!(sf; title="u", len=0.4)
		@test _SCB._finalize_figure!(sf) === false
		# The export at 5.25 x 2 in: the bar keeps room for its title and a
		# tick label (shorter, plotly.js fails with "axis scaling").
		size = (5.25 * 96, 2.0 * 96)
		copy = _SCB._finalize_export_copy(sf.plot, (width=size[1], height=size[2]))
		bar = _scb_fields(_scb_fields(copy.layout.fields[:coloraxis])[:colorbar])
		plan = _SCB._room_plan(copy; size=size)
		font = plan.font
		need = _SCB._CBAR_LINE_EM * font + 2 + _SCB._CBAR_LINE_EM * font + 4
		@test bar[:len] * plan.Hp >= need - 1e-6
		yd = _scb_fields(copy.layout.fields[:yaxis])[:domain]
		@test bar[:len] > 0.4 * (yd[2] - yd[1])           # the 0.4 ratio was too short here
		path = tempname() * ".png"
		try
			savefig(sf, path; width=5.25, height=2.0, units=:in, dpi=100)
			@test isfile(path) && filesize(path) > 0
		catch err
			occursin("axis scaling", sprint(showerror, err)) && rethrow()
			@warn "sci_colorbar: export unavailable; G63 render check skipped" exception = err
		finally
			rm(path; force=true)
		end
	end
end
