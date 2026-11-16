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
		@test b1[:y] ≈ yd1[1] - _SCB._CBAR_BOTTOM_OFFSET
		@test b1[:yanchor] == "top"
		@test b1[:x] ≈ _scb_mid(xd1)
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
		@test _scb_bar(inset.plot.data[1])[:x] ≈ 0.8 + _SCB._CBAR_CELL_PAD
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
		@test bar[:y] ≈ top[1] - _SCB._CBAR_BOTTOM_OFFSET
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
			((crange=[0, 1], cmid=0.5), "cmid"),
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
		@test_throws Exception shared_colorbar!(failing)
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
end
