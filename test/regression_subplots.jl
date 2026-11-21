using Test, PlotlySupply

# Regression tests for the SubplotFigure infrastructure (v2 "subplots"
# track): subplots() options, per-cell axis references, figure-wide modes,
# forwarded verbs and per-cell layout updaters.

const _RSP_PB = PlotlySupply.PlotlyBase

_rsp_fields(value) = value isa _RSP_PB.PlotlyAttribute ? value.fields : value
_rsp_layout(sf::SubplotFigure) = sf.plot.layout.fields
_rsp_axis(sf::SubplotFigure, key::Symbol) = _rsp_fields(_rsp_layout(sf)[key])
_rsp_span(domain) = domain[2] - domain[1]

# The text of an axis title (`nothing` when it has none, e.g. only a font).
function _rsp_title_text(axis)
	title = get(axis, :title, nothing)
	title isa AbstractString && return title
	title === nothing && return nothing
	return get(_rsp_fields(title), :text, nothing)
end

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

using Dates
import PlotlySupply.PlotlyBase.JSON

# ── Rendered axes (hidden window) ─────────────────────────────────────────
# Per Cartesian axis of the rendered figure: plotly's type, range (numbers,
# or strings on a date axis), the `matches` it kept and the texts of the tick
# labels that are drawn. `nothing` when the renderer cannot start (the
# renderer checks are then skipped; the first failure is reported once).
const _RSP_AXES_JS = raw"""
(() => {
  const gd = document.getElementById(__DIV__);
  if (!gd || !gd._fullLayout || !gd._fullLayout._size) return null;
  const fl = gd._fullLayout;
  const out = {};
  for (const k of Object.keys(fl).filter(k => /^[xy]axis\d*$/.test(k))) {
    const a = fl[k];
    const id = k.replace('axis', '');
    const labels = Array.from(gd.querySelectorAll('g.' + id + 'tick text'))
      .filter(t => t.getBoundingClientRect().width > 0).map(t => t.textContent);
    const title = (a.title && a.title.text && !/^Click to enter/.test(a.title.text)) ? a.title.text : null;
    out[k] = {type: a.type, range: a.range.map(v => (typeof v === 'string') ? v : Number(v)),
      matches: a.matches || null, labels: labels, title: title};
  }
  return JSON.stringify(out);
})()
"""

const _RSP_RENDERER_OK = Ref(true)

function _rsp_render_axes(fig)
	_RSP_RENDERER_OK[] || return nothing
	p = fig isa SubplotFigure ? fig.plot : fig
	q = Plot(deepcopy(p.data), deepcopy(p.layout))
	relayout!(q; width = 700, height = 500)
	sp = try
		to_syncplot(q; show = false)
	catch err
		_RSP_RENDERER_OK[] = false
		@warn "regression_subplots: the renderer could not start; renderer checks are skipped" exception = (err, catch_backtrace())
		return nothing
	end
	try
		backend = PlotlySupply._syncplot_backend(sp)
		script = replace(_RSP_AXES_JS, "__DIV__" => PlotlySupply._json_js(sp.divid))
		for _ in 1:300
			raw = Base.invokelatest(() -> backend.run(sp.window, script))
			(raw === nothing || raw == "null") || return JSON.parse(String(raw))
			sleep(0.05)
		end
		error("regression_subplots: the figure did not render within 15 s")
	finally
		close(sp)
	end
end

# ── Shared-axis table (G61) ───────────────────────────────────────────────
const _RSP_SHARE_CELLS = ((1, 1), (1, 2), (2, 1), (2, 2))

# The cells whose `letter` axes plotly.py's sharing `mode` groups together.
function _rsp_share_groups(letter::Symbol, mode)
	mode === false && return [[cell] for cell in _RSP_SHARE_CELLS]
	mode == "all" && return [collect(_RSP_SHARE_CELLS)]
	per_column = letter === :x ? (mode === true || mode == "columns") : mode == "columns"
	return per_column ? [[(1, c), (2, c)] for c in 1:2] : [[(r, 1), (r, 2)] for r in 1:2]
end

# Whether the tick labels of the `letter` axis of `cell` are hidden (only the
# bottom row keeps x labels, only the first column y labels).
_rsp_share_hidden(letter::Symbol, mode, cell) = letter === :x ?
	(cell[1] == 1 && (mode === true || mode == "columns" || mode == "all")) :
	(cell[2] == 2 && (mode === true || mode == "rows" || mode == "all"))

_rsp_share_index(cell) = (cell[1] - 1) * 2 + cell[2]

# Data of `cell` along the shared letter: positions 2k+1..2k+5 (k the cell's
# index), or dates 10k..10k+4 days after 2020-01-01.
_rsp_share_data(scale::Symbol, cell) = scale === :date ?
	[Date(2020, 1, 1) + Day(10 * _rsp_share_index(cell) + i) for i in 0:4] :
	Float64[2 * _rsp_share_index(cell) + i for i in 1:5]

const _RSP_SHARE_RANGE = Dict(:date => ["2020-01-15", "2020-02-10"])
_rsp_share_range(scale::Symbol) = get(_RSP_SHARE_RANGE, scale, [4.0, 9.0])

# A 2 x 2 grid sharing its `letter` axes with `mode`; the scale is applied on
# cell (1, 1) (`:log` through the plot call, `:reversed` through
# update_*axes!, `:date` by date data in every cell) and, with `ranged`, the
# range `_rsp_share_range(scale)` is set on cell (1, 2) with xrange!/yrange!.
function _rsp_share_figure(letter::Symbol, mode, scale::Symbol, ranged::Bool)
	kw = letter === :x ? (shared_xaxes = mode,) : (shared_yaxes = mode,)
	sf = subplots(2, 2; sync = false, kw...)
	for cell in _RSP_SHARE_CELLS
		base = _rsp_share_data(scale, cell)
		values = Float64[1, 3, 2, 5, 4]
		x, y = letter === :x ? (base, values) : (values, base)
		scale_kw = (cell == (1, 1) && scale === :log) ?
			(letter === :x ? (xscale = "log",) : (yscale = "log",)) : NamedTuple()
		plot_scatter!(sf, x, y; row = cell[1], col = cell[2], scale_kw...)
	end
	if scale === :reversed
		letter === :x ? update_xaxes!(sf; row = 1, col = 1, autorange = "reversed") :
			update_yaxes!(sf; row = 1, col = 1, autorange = "reversed")
	end
	if ranged
		range = _rsp_share_range(scale)
		letter === :x ? xrange!(sf, range; row = 1, col = 2) : yrange!(sf, range; row = 1, col = 2)
	end
	return sf
end

_rsp_share_key(sf, letter::Symbol, cell) = begin
	t = PlotlySupply._cell_target(sf; row = cell[1], col = cell[2])
	letter === :x ? t.xkey : t.ykey
end

# ── Completeness: every exported mutator on cell (2, 2) ──────────────────
# What a call changed on one cell: its layout objects, its traces (by axis /
# subplot reference, or by domain), the shapes/annotations/images on its axes
# or named after it (cell titles), its inset records and the legends its
# traces use.
function _rsp_cell_state(sf::SubplotFigure, r::Int, c::Int)
	p = sf.plot
	refs = p.layout.subplots.grid_ref[r, c]
	kind = String(first(refs).subplot_kind)
	ids = Set{String}(string(v) for ref in refs for (k, v) in _rsp_fields(ref.trace_kwargs) if k in (:xaxis, :yaxis, :scene, :subplot, :geo))
	cell_domain = _rsp_fields(get(_rsp_fields(first(refs).trace_kwargs), :domain, nothing))
	objects = [JSON.json(get(p.layout.fields, key, nothing)) for ref in refs for key in ref.layout_keys]
	traces = String[]
	legends = Set{String}()
	for trace in p.data
		trace_kind = first(PlotlySupply._trace_subplot_kind(trace))
		on_cell = if trace_kind == "xy"
			kind == "xy" && string(get(trace.fields, :xaxis, "x")) in ids &&
				string(get(trace.fields, :yaxis, "y")) in ids
		elseif trace_kind == "domain"
			domain = _rsp_fields(get(trace.fields, :domain, nothing))
			kind == "domain" && cell_domain !== nothing && domain !== nothing &&
				collect(_rsp_fields(domain)[:x]) == collect(cell_domain[:x]) &&
				collect(_rsp_fields(domain)[:y]) == collect(cell_domain[:y])
		else
			any(haskey(trace.fields, k) && string(trace.fields[k]) in ids for k in (:scene, :subplot, :geo))
		end
		on_cell || continue
		push!(traces, JSON.json(trace))
		push!(legends, string(get(trace.fields, :legend, "legend")))
	end
	strip_domain(ref) = replace(string(ref), " domain" => "")
	items = String[]
	for key in (:shapes, :annotations, :images)
		for item in get(p.layout.fields, key, Any[])
			fields = item isa _RSP_PB.Shape ? item.fields : _rsp_fields(item)
			on_axes = strip_domain(get(fields, :xref, "")) in ids || strip_domain(get(fields, :yref, "")) in ids
			named = endswith(string(get(fields, :name, "")), ":$(r):$(c)")
			(on_axes || named) && push!(items, JSON.json(item))
		end
	end
	legend_objects = [JSON.json(get(p.layout.fields, Symbol(name), nothing)) for name in sort!(collect(legends))]
	insets = [(record.xkey, record.ykey, JSON.json(get(p.layout.fields, record.xkey, nothing)))
		for record in sf.insets if (record.row, record.col) == (r, c)]
	return (objects = objects, traces = traces, items = items, legends = legend_objects, insets = insets)
end

# A 2 x 2 grid whose cell (2, 2) is of `kind` (the others Cartesian), with a
# trace in cell (1, 1), which is the active cell.
function _rsp_complete_figure(kind::AbstractString)
	specs = kind == "xy" ? [Spec() Spec(); Spec() Spec()] : [Spec() Spec(); Spec() Spec(kind = kind)]
	sf = subplots(2, 2; sync = false, specs = specs)
	plot_scatter!(sf, [1.0, 2.0, 3.0], [1.0, 4.0, 9.0]; row = 1, col = 1)
	subplot!(sf, 1, 1)
	return sf
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

	@testset "real families: style cycles, colour axes and log ranges per cell (Y19, Y21, Y29, Y30, Y32, Y36)" begin
		# Y32: the dash/marker cycle runs across geo, ternary and xy cells.
		mixed = subplots(1, 3; sync=false, specs=[Spec(kind="geo") Spec(kind="ternary") Spec()])
		with_style(; cycle=:dash_marker) do
			plot_scattergeo!(mixed, [0.0, 1.0], [0.0, 1.0]; row=1, col=1, mode="lines")
			plot_ternary!(mixed, [0.2, 0.3], [0.3, 0.3], [0.5, 0.4]; row=1, col=2, mode="lines")
			plot_scatter!(mixed, [1.0, 2.0], [1.0, 2.0]; row=1, col=3)
		end
		@test [t[:type] for t in mixed.plot.data] == ["scattergeo", "scatterternary", "scatter"]
		@test [_rsp_fields(t[:line])[:dash] for t in mixed.plot.data] == ["solid", "dash", "dot"]
		@test [_rsp_fields(t[:marker])[:symbol] for t in mixed.plot.data] == ["circle", "square", "diamond"]
		# Y21/Y29: a field family in another cell does not restart the cycle,
		# exactly as on one figure.
		cells = subplots(1, 2; sync=false)
		single = plot_scatter([1.0, 2.0], [1.0, 2.0])
		with_style(; cycle=:dash) do
			plot_scatter!(cells, [1.0, 2.0], [1.0, 2.0]; row=1, col=1)
			plot_contour!(cells, [1.0 2.0; 3.0 4.0]; row=1, col=2)
			plot_scatter!(cells, [1.0, 2.0], [2.0, 2.0]; row=1, col=2)
			single = plot_scatter([1.0, 2.0], [1.0, 2.0])
			plot_contour!(single, [1.0 2.0; 3.0 4.0])
			plot_scatter!(single, [1.0, 2.0], [2.0, 2.0])
		end
		line_dash(t) = haskey(t.fields, :line) ? get(_rsp_fields(t[:line]), :dash, nothing) : nothing
		@test [line_dash(t) for t in cells.plot.data] == ["solid", nothing, "dash"]
		@test [line_dash(t) for t in cells.plot.data] == [line_dash(t) for t in single.data]
		# Y19/Y30: a numbered colour axis from a real family reaches the
		# figure, its bar placed next to the cell.
		colour = subplots(1, 2; sync=false)
		plot_pcolormesh!(colour, [0.0, 1.0, 2.0], [0.0, 1.0, 2.0], [1.0 2.0; 3.0 4.0];
			row=1, col=2, coloraxis="coloraxis3")
		axis3 = _rsp_fields(_rsp_layout(colour)[:coloraxis3])
		@test (axis3[:cmin], axis3[:cmax]) == (1.0, 4.0)
		@test only(colour.plot.data)[:coloraxis] == "coloraxis3"
		@test only(colour.plot.data)[:xaxis] == "x2"
		@test _rsp_fields(axis3[:colorbar])[:x] ≈ _rsp_axis(colour, :xaxis2)[:domain][2] + PlotlySupply._CBAR_CELL_PAD
		@test !haskey(_rsp_layout(colour), :coloraxis)
		# Y36: a range keyword on a log cell is in data units and validated.
		logcell = subplots(1, 2; sync=false)
		update_xaxes!(logcell; row=1, col=2, type="log")
		err = try
			plot_scatter!(logcell, [1.0, 10.0], [1.0, 2.0]; row=1, col=2, xrange=[-1, 1000])
			nothing
		catch caught
			caught
		end
		@test err isa ArgumentError && startswith(err.msg, "plot_scatter!:")
		@test isempty(logcell.plot.data)
		plot_scatter!(logcell, [1.0, 10.0], [1.0, 2.0]; row=1, col=2, xrange=[1, 1000])
		@test _rsp_axis(logcell, :xaxis2)[:range] ≈ [0.0, 3.0]
	end

	@testset "geographic cell updates and map families name themselves (Y20)" begin
		sf = subplots(1, 3; sync=false, specs=[Spec(kind="geo") Spec(kind="mapbox") Spec(kind="map")])
		snapshot = JSON.json(sf.plot)
		message(call) = try
			call()
			""
		catch caught
			caught isa ArgumentError ? caught.msg : sprint(showerror, caught)
		end
		for (call, want) in (
			(() -> update_geos!(sf; row=1, col=2, showland=true),
				"update_geos!: subplot cell (1, 2) is a 'mapbox' cell, not a 'geo' cell."),
			(() -> update_mapboxes!(sf; row=1, col=1, zoom=2),
				"update_mapboxes!: subplot cell (1, 1) is a 'geo' cell, not a 'mapbox' cell."),
			(() -> update_maps!(sf; row=1, col=1, zoom=2),
				"update_maps!: subplot cell (1, 1) is a 'geo' cell, not a 'map' cell."),
			(() -> update_geos!(sf; row=99, col=1, showland=true), "update_geos!: `row` must be in 1:1; got 99."),
			(() -> update_mapboxes!(sf; row=1, col=9, zoom=2), "update_mapboxes!: `col` must be in 1:3; got 9."),
			(() -> update_maps!(sf; row=99, col=3, zoom=2), "update_maps!: `row` must be in 1:1; got 99."),
			(() -> update_maps!(sf; row=1, col=nothing, zoom=2), "update_maps!: `row` and `col` must be provided together."),
			(() -> plot_scattermapbox!(sf, [0.0, 1.0], [0.0, 1.0]; row=99, col=2),
				"plot_scattermapbox!: `row` must be in 1:1; got 99."),
		)
			@test message(call) == want
		end
		# Shared validators name the family; the SubplotFigure call names itself.
		@test startswith(message(() -> update_mapboxes!(sf; row=1, col=2, zoom=Inf)), "update_mapboxes!: mapbox: zoom")
		@test startswith(message(() -> update_mapboxes!(sf; row=1, col=2, style="  ")), "update_mapboxes!: mapbox: style")
		@test startswith(message(() -> update_maps!(sf; row=1, col=3, zoom=Inf)), "update_maps!: map: zoom")
		for (name, call) in (
			("plot_densitymapbox!", () -> plot_densitymapbox!(sf, [0.0, 1], [0.0, 1], [1.0, 2]; row=99, col=2)),
			("plot_scattermap!", () -> plot_scattermap!(sf, [0.0, 1.0], [0.0, 1.0]; row=1, col=2)),
			("plot_scattergeo!", () -> plot_scattergeo!(sf, [0.0, 1.0], [0.0, 1.0]; row=1, col=3)),
		)
			@test startswith(message(call), name * ": ")
		end
		@test JSON.json(sf.plot) == snapshot
		@test (sf.current_row, sf.current_col) == (1, 1)
		# The valid calls still update the cell they name.
		update_maps!(sf; row=1, col=3, zoom=3)
		map_key = only(first(sf.plot.layout.subplots.grid_ref[1, 3]).layout_keys)
		@test _rsp_fields(_rsp_layout(sf)[map_key])[:zoom] == 3
		@test (sf.current_row, sf.current_col) == (1, 3)
		update_geos!(sf; row=1, col=1, showland=true)
		@test _rsp_fields(_rsp_layout(sf)[:geo])[:showland] === true
		@test (sf.current_row, sf.current_col) == (1, 1)
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
		# Y17: the rising host line and the inset fill the top right; the legend takes the free top left.
		@test legend2[:xanchor] == "left" && legend2[:x] >= _rsp_axis(sf, :xaxis2)[:domain][1]

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

	@testset "grid titles go through the mathtext layer (G25, Y38)" begin
		sf = subplots(
			2,
			2;
			sync=false,
			subplot_titles=["Panel \$a\$" "b"; "c\nd" missing],
			column_titles=["col \$x\$", "c2"],
			row_titles=["r1", "row \$\\alpha\$"],
			x_title="X \$t\$ (s)",
			y_title="Y \$v\$",
		)
		texts = [_rsp_fields(a)[:text] for a in _rsp_layout(sf)[:annotations]]
		# Mixed text and math keeps its text (as title!/xlabel! do); plain
		# titles stay plain and newlines become line breaks.
		@test texts == [
			"\$\\text{Panel }a\$", "b", "c<br>d",
			"\$\\text{col }x\$", "c2",
			"r1", "\$\\text{row }\\alpha\$",
			"\$\\text{X }t\\text{ (s)}\$", "\$\\text{Y }v\$",
		]
		@test all(t == PlotlySupply._label(t) for t in texts)  # idempotent
		# A flat list (plotly.py) is read row-major, like the matrix.
		flat = subplots(1, 2; sync=false, subplot_titles=["\$\\beta\$ map", "plain"])
		@test [_rsp_fields(a)[:text] for a in _rsp_layout(flat)[:annotations]] ==
			["\$\\beta\\text{ map}\$", "plain"]
		# Invalid entries are ArgumentErrors naming the keyword; nothing is built.
		err = try
			subplots(1, 2; sync=false, subplot_titles=["\$a", "b"])
		catch e
			e
		end
		@test err isa ArgumentError
		@test startswith(err.msg, "subplots: `subplot_titles` entry")
		@test_throws ArgumentError subplots(1, 2; sync=false, column_titles=["a"])
		@test_throws ArgumentError subplots(2, 1; sync=false, row_titles=["a", 1])
		@test_throws ArgumentError subplots(1, 2; sync=false, column_titles="ab")
		@test_throws ArgumentError subplots(1, 2; sync=false, x_title=3)
		@test_throws ArgumentError subplots(1, 2; sync=false, y_title="\$x")
		for name in (:x_title, :y_title, :column_titles)
			e = try
				subplots(1, 2; sync=false, name => (name === :column_titles ? ["\$q", "b"] : "\$q"))
			catch caught
				caught
			end
			@test e isa ArgumentError && occursin("`$(name)`", e.msg)
		end
	end

	@testset "shared axes act as one group (G61): sharing x scale x range table" begin
		modes = (false, true, "rows", "columns", "all")
		scales = (:linear, :log, :reversed, :date)
		for letter in (:x, :y), mode in modes, scale in scales, ranged in (false, true)
			label = "$(letter) shared=$(repr(mode)) $(scale)$(ranged ? " ranged" : "")"
			@testset "$label" begin
				sf = _rsp_share_figure(letter, mode, scale, ranged)
				groups = _rsp_share_groups(letter, mode)
				expected_range = _rsp_share_range(scale)
				# ---- model: one type per group, ranges on the root only ----
				roots = Dict{Any, Symbol}()
				for group in groups
					axis_keys = [_rsp_share_key(sf, letter, cell) for cell in group]
					fields = [_rsp_axis(sf, key) for key in axis_keys]
					followers = [k for (k, f) in zip(axis_keys, fields) if haskey(f, :matches)]
					@test length(followers) == length(axis_keys) - 1
					root = only(k for (k, f) in zip(axis_keys, fields) if !haskey(f, :matches))
					roots[group] = root
					@test all(PlotlySupply._fin_match_root(_rsp_layout(sf), k) == root for k in axis_keys)
					types = [get(f, :type, nothing) for f in fields]
					if scale === :log && (1, 1) in group
						@test all(==("log"), types)
					else
						@test !any(==("log"), types)
					end
					for (key, f) in zip(axis_keys, fields)
						key === root && continue
						@test !haskey(f, :range)
						@test !haskey(f, :autorange)
					end
					root_axis = _rsp_axis(sf, root)
					if ranged && (1, 2) in group
						want = scale === :log && (1, 1) in group ? log10.(expected_range) : expected_range
						@test root_axis[:autorange] === false
						@test scale === :date ? root_axis[:range] == want :
							isapprox(Float64.(root_axis[:range]), want; atol = 1e-12)
					elseif scale === :reversed && (1, 1) in group
						@test root_axis[:autorange] == "reversed"
					end
				end
				# ---- rendered: the group draws one range, labels where expected ----
				info = _rsp_render_axes(sf)
				for group in (info === nothing ? () : groups)
					root = roots[group]
					data = reduce(vcat, [_rsp_share_data(scale, cell) for cell in group])
					rendered = [info[String(_rsp_share_key(sf, letter, cell))] for cell in group]
					want_type = scale === :date ? "date" : (scale === :log && (1, 1) in group) ? "log" : "linear"
					@test all(a -> a["type"] == want_type, rendered)
					root_info = info[String(root)]
					for (cell, a) in zip(group, rendered)
						key = _rsp_share_key(sf, letter, cell)
						# plotly kept the `matches` (it drops it on a type mismatch).
						@test a["matches"] == (key === root ? nothing : PlotlySupply._fin_axis_ref(root))
						@test a["range"] == root_info["range"]
						@test isempty(a["labels"]) == _rsp_share_hidden(letter, mode, cell)
					end
					drawn = root_info["range"]
					if ranged && (1, 2) in group
						if scale === :date
							@test [first(String(v), 10) for v in drawn] == expected_range
						else
							want = scale === :log && (1, 1) in group ? log10.(expected_range) : expected_range
							@test isapprox(Float64.(drawn), want; atol = 1e-9)
						end
					elseif scale === :date
						lo, hi = Date(first(String(drawn[1]), 10)), Date(first(String(drawn[2]), 10))
						@test lo <= minimum(data) && hi >= maximum(data)
					else
						# Compared in axis units: plotly autoranges lines-only
						# x data tightly, so a log range is exactly
						# log10.(extrema(data)) and exp10 of it can round below
						# the data (2.999999999999999 for 3).
						bounds = Float64.(drawn)
						units = scale === :log && (1, 1) in group ? log10.(data) : data
						@test minimum(bounds) <= minimum(units) + 1e-9 && maximum(bounds) >= maximum(units) - 1e-9
						reversed = scale === :reversed && (1, 1) in group
						@test (bounds[1] > bounds[2]) == reversed
					end
				end
			end
		end
	end

	@testset "axis helpers on a shared axis act on the group (G61)" begin
		for letter in (:x, :y), mode in (true, "rows", "columns", "all")
			@testset "$(letter) shared=$(repr(mode))" begin
				sf = _rsp_share_figure(letter, mode, :linear, false)
				label!, range!, ticks! = letter === :x ? (xlabel!, xrange!, xticks!) : (ylabel!, yrange!, yticks!)
				ticks!(sf, [4.0, 6.0, 8.0], ["a", "b", "c"]; row=1, col=2)
				label!(sf, "quantity"; row=1, col=2)
				range!(sf, [3, 9]; row=1, col=2)
				group = only(g for g in _rsp_share_groups(letter, mode) if (1, 2) in g)
				axis_keys = [_rsp_share_key(sf, letter, cell) for cell in group]
				root = only(k for k in axis_keys if !haskey(_rsp_axis(sf, k), :matches))
				for key in axis_keys
					axis = _rsp_axis(sf, key)
					@test axis[:tickvals] == [4.0, 6.0, 8.0]
					@test axis[:ticktext] == ["a", "b", "c"]
					@test haskey(axis, :range) == (key === root)
				end
				@test _rsp_axis(sf, root)[:range] == [3, 9]
				@test _rsp_axis(sf, root)[:autorange] === false
				# The title sits on the axis that shows the group's tick labels
				# next to cell (1, 2): itself unless its labels are hidden.
				hidden = _rsp_share_hidden(letter, mode, (1, 2))
				label_cell = !hidden ? (1, 2) : letter === :x ? (2, 2) : (1, 1)
				label_key = _rsp_share_key(sf, letter, label_cell)
				# A journal style writes the title font on every axis: only a title
				# TEXT counts as the group's title.
				titled = [k for k in axis_keys if _rsp_title_text(_rsp_axis(sf, k)) !== nothing]
				@test titled == [label_key]
				@test _rsp_fields(_rsp_axis(sf, label_key)[:title])[:text] == "quantity"
				# Axes of other groups are untouched.
				for cell in _RSP_SHARE_CELLS
					cell in group && continue
					@test !haskey(_rsp_axis(sf, _rsp_share_key(sf, letter, cell)), :tickvals)
				end
				info = _rsp_render_axes(sf)
				for cell in (info === nothing ? () : group)
					a = info[String(_rsp_share_key(sf, letter, cell))]
					@test isapprox(Float64.(a["range"]), [3.0, 9.0]; atol = 1e-9)
					@test a["labels"] == (_rsp_share_hidden(letter, mode, cell) ? String[] : ["a", "b", "c"])
					@test a["title"] == (cell == label_cell ? "quantity" : nothing)
				end
			end
		end
	end

	@testset "shared axes: delegate keywords, update_*axes! and no-op calls (G61)" begin
		# A range passed to a plot_*! call on a follower reaches the root.
		sf = subplots(2, 1; sync=false, shared_xaxes=true)
		plot_scatter!(sf, 1:10, collect(1.0:10.0); row=1, col=1, xrange=[2, 5])
		@test !haskey(_rsp_axis(sf, :xaxis), :range)
		@test _rsp_axis(sf, :xaxis2)[:range] == [2, 5]
		@test _rsp_axis(sf, :xaxis2)[:autorange] === false
		# xscale on a follower types the whole group (plotly drops `matches`
		# from an axis whose type differs from the root's).
		plot_scatter!(sf, [1.0, 10.0, 100.0], [1.0, 2.0, 3.0]; row=2, col=1, xscale="log")
		@test _rsp_axis(sf, :xaxis)[:type] == "log"
		@test _rsp_axis(sf, :xaxis2)[:type] == "log"
		@test _rsp_axis(sf, :xaxis)[:matches] == "x2"
		# The delegate seeds a follower's scratch axis with the root's range
		# (log ticks and range conversions need the group's range), and a range
		# the mutator removes is removed from the root.
		seeded = subplots(2, 1; sync=false, shared_xaxes=true)
		plot_scatter!(seeded, 1:10, collect(1.0:10.0); row=2, col=1)
		xrange!(seeded, [3, 6]; row=2, col=1)
		seen = Ref{Any}(nothing)
		read_range = function (fig, x, y; kwargs...)
			seen[] = PlotlySupply._cmn_mapping_get(get(PlotlySupply._cmn_layout(fig).fields, :xaxis, nothing), :range)
			push!(PlotlySupply._plot_data(fig), scatter(x=x, y=y))
			return nothing
		end
		PlotlySupply._subplot_delegate_mutator!(seeded, read_range, [1, 2], [1, 2]; row=1, col=1)
		@test seen[] == [3, 6]
		@test _rsp_axis(seeded, :xaxis2)[:range] == [3, 6]
		@test !haskey(_rsp_axis(seeded, :xaxis), :range)
		drop_range = function (fig, x, y; kwargs...)
			push!(PlotlySupply._plot_data(fig), scatter(x=x, y=y))
			PlotlySupply._cmn_delete_layout_fields!(fig, :xaxis, (:range,))
			return nothing
		end
		PlotlySupply._subplot_delegate_mutator!(seeded, drop_range, [1, 2], [1, 2]; row=1, col=1)
		@test !haskey(_rsp_axis(seeded, :xaxis2), :range)
		@test _rsp_axis(seeded, :xaxis2)[:autorange] === true
		# update_xaxes! with a range on the root: the `autorange = true` the
		# finalizer gives group roots must not override it.
		root_ranged = subplots(2, 1; sync=false, shared_xaxes=true)
		plot_scatter!(root_ranged, 1:10, collect(1.0:10.0); row=2, col=1)
		@test _rsp_axis(root_ranged, :xaxis2)[:autorange] === true
		update_xaxes!(root_ranged; row=2, col=1, range=[3, 6])
		@test _rsp_axis(root_ranged, :xaxis2)[:autorange] === false
		@test _rsp_axis(root_ranged, :xaxis2)[:range] == [3, 6]
		# ... and on a follower it moves to the root.
		update_xaxes!(root_ranged; row=1, col=1, range=[1, 4])
		@test _rsp_axis(root_ranged, :xaxis2)[:range] == [1, 4]
		@test !haskey(_rsp_axis(root_ranged, :xaxis), :range)
		# Clearing the follower's range restores the group's autorange.
		xrange!(root_ranged, nothing; row=1, col=1)
		@test !haskey(_rsp_axis(root_ranged, :xaxis2), :range)
		@test _rsp_axis(root_ranged, :xaxis2)[:autorange] !== false
		# A secondary y axis (overlaying) is not a member of the y group.
		sec = subplots(1, 2; sync=false, shared_yaxes=true, specs=[Spec(secondary_y=true) Spec()])
		plot_scatter!(sec, 1:3, [1.0, 2.0, 3.0]; row=1, col=1)
		plot_scatter!(sec, 1:3, [10.0, 20.0, 30.0]; row=1, col=1, secondary_y=true, yscale="log")
		sec_key = PlotlySupply._cell_target(sec; row=1, col=1, secondary_y=true).ykey
		primary_keys = [PlotlySupply._cell_target(sec; row=1, col=c).ykey for c in 1:2]
		@test haskey(_rsp_axis(sec, sec_key), :overlaying)
		@test _rsp_axis(sec, sec_key)[:type] == "log"
		@test haskey(_rsp_axis(sec, primary_keys[2]), :matches)
		@test !any(get(_rsp_axis(sec, k), :type, nothing) == "log" for k in primary_keys)
		# A call that changes nothing in a group sends an append-only update.
		live = subplots(2, 1; sync=false, shared_xaxes=true, per_subplot_legends=false)
		plot_scatter!(live, 1:3, [1.0, 2.0, 3.0]; row=2, col=1)
		xticks!(live, [1.0, 2.0]; row=2, col=1)
		renderer = _rsp_live!(live)
		plot_scatter!(live, 1:3, [3.0, 2.0, 1.0]; row=1, col=1)
		@test occursin("Plotly.addTraces", only(renderer.scripts))
		@test !occursin("Plotly.relayout", only(renderer.scripts))
		# Unshared figures are not affected.
		plain = subplots(2, 1; sync=false)
		plot_scatter!(plain, 1:3, [1.0, 2.0, 3.0]; row=1, col=1, xrange=[0, 2])
		@test _rsp_axis(plain, :xaxis)[:range] == [0, 2]
		@test !haskey(_rsp_axis(plain, :xaxis2), :range)
	end

	@testset "every exported mutator addresses cell (2, 2) or names itself in an ArgumentError" begin
		# Process-wide setters take no figure.
		process_wide = Set(["register_style!", "set_default_legend_position!", "set_default_mathtext!",
			"set_default_style!", "set_default_template!"])
		image = attr(source="data:image/png;base64,iVBORw0KGgo=", x=0, y=1, sizex=0.2, sizey=0.2)
		geojson = Dict("type" => "FeatureCollection", "features" => [Dict("type" => "Feature", "id" => "A",
			"properties" => Dict(), "geometry" => Dict("type" => "Polygon",
			"coordinates" => [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]]))])
		grid3(f) = [f(i, j, k) for i in 0.0:1, j in 0.0:1, k in 0.0:1]
		none = sf -> nothing
		xy! = sf -> plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row=2, col=2)
		dates! = sf -> plot_scatter!(sf, [Date(2008, 1, 1) + Month(i) for i in 0:24], collect(1.0:25.0); row=2, col=2)
		heat! = sf -> plot_heatmap!(sf, [1.0 2.0; 3.0 4.0]; row=2, col=2)
		points3d! = sf -> plot_scatter3d!(sf, [0.0, 1], [0.0, 1], [0.0, 1]; row=2, col=2)
		# (name, kind of cell (2, 2), setup, call(sf, cell keywords))
		calls = Any[
			("add_hline!", "xy", none, (sf, rc) -> add_hline!(sf, 0.5; rc...)),
			("add_hrect!", "xy", none, (sf, rc) -> add_hrect!(sf, 0.2, 0.4; rc...)),
			("add_vline!", "xy", none, (sf, rc) -> add_vline!(sf, 1.5; rc...)),
			("add_vrect!", "xy", none, (sf, rc) -> add_vrect!(sf, 1, 2; rc...)),
			("add_shape!", "xy", none, (sf, rc) -> add_shape!(sf, rect(1, 2, 0.1, 0.2); rc...)),
			("add_layout_image!", "xy", none, (sf, rc) -> add_layout_image!(sf, image; rc...)),
			("add_recession_bands!", "xy", dates!, (sf, rc) -> add_recession_bands!(sf; rc...)),
			("add_trace!", "xy", none, (sf, rc) -> add_trace!(sf, scatter(x=[1, 2], y=[1, 2]); rc...)),
			("addtraces!", "xy", none, (sf, rc) -> addtraces!(sf, scatter(x=[1, 2], y=[1, 2]); rc...)),
			("annotate!", "xy", none, (sf, rc) -> annotate!(sf, 1, 1, "a"; rc...)),
			("annotate!", "scene", points3d!, (sf, rc) -> annotate!(sf, 0, 0, 0, "a"; rc...)),
			("arc!", "xy", none, (sf, rc) -> arc!(sf, 0, 0, 1, 0, 90; rc...)),
			("arrow!", "xy", none, (sf, rc) -> arrow!(sf, 0, 0, 1, 1; rc...)),
			("axis_equal!", "xy", xy!, (sf, rc) -> axis_equal!(sf; rc...)),
			("axis_off!", "xy", none, (sf, rc) -> axis_off!(sf; rc...)),
			("circle!", "xy", none, (sf, rc) -> circle!(sf, 0, 0, 1; rc...)),
			("colorbar!", "xy", heat!, (sf, rc) -> colorbar!(sf; rc..., title="c")),
			("deletetraces!", "xy", none, (sf, rc) -> deletetraces!(sf, 1; rc...)),
			("ellipse!", "xy", none, (sf, rc) -> ellipse!(sf, 0, 0, 1, 0.5; rc...)),
			("extendtraces!", "xy", none, (sf, rc) -> extendtraces!(sf, Dict(:y => [[1.0]]), [1]; rc...)),
			("figsize!", "xy", none, (sf, rc) -> figsize!(sf, 600, 400; rc...)),
			("grid!", "xy", none, (sf, rc) -> grid!(sf; rc...)),
			("hline!", "xy", none, (sf, rc) -> hline!(sf, 0.5; rc...)),
			("hspan!", "xy", none, (sf, rc) -> hspan!(sf, 0.2, 0.4; rc...)),
			("inset!", "xy", none, (sf, rc) -> inset!(sf, (0.6, 0.6, 0.3, 0.3); rc...)),
			("legend_entry!", "xy", none, (sf, rc) -> legend_entry!(sf, "lbl"; rc...)),
			("movetraces!", "xy", none, (sf, rc) -> movetraces!(sf, 1, 1; rc...)),
			("panel_labels!", "xy", none, (sf, rc) -> panel_labels!(sf; rc...)),
			("plot!", "xy", none, (sf, rc) -> plot!(sf, [1.0, 2, 3], [1.0, 2, 3]; rc...)),
			("plot_area!", "xy", none, (sf, rc) -> plot_area!(sf, [1.0, 2, 3], [1.0, 2, 3]; rc...)),
			("plot_band!", "xy", none, (sf, rc) -> plot_band!(sf, [1.0, 2, 3], [0.0, 0, 0], [1.0, 1, 1]; rc...)),
			("plot_bar!", "xy", none, (sf, rc) -> plot_bar!(sf, ["a", "b"], [1, 2]; rc...)),
			("plot_box!", "xy", none, (sf, rc) -> plot_box!(sf, [1.0, 2, 3]; rc...)),
			("plot_candlestick!", "xy", none, (sf, rc) -> plot_candlestick!(sf, 1:2, [2, 3], [3, 4], [1.5, 2.5], [2.8, 2.6]; rc...)),
			("plot_choropleth!", "geo", none, (sf, rc) -> plot_choropleth!(sf, ["Italy"], [2.0]; rc...)),
			("plot_choroplethmap!", "map", none, (sf, rc) -> plot_choroplethmap!(sf, geojson, ["A"], [1.0]; rc...)),
			("plot_choroplethmapbox!", "mapbox", none, (sf, rc) -> plot_choroplethmapbox!(sf, geojson, ["A"], [1.0]; rc...)),
			("plot_complex!", "xy", none, (sf, rc) -> plot_complex!(sf, [1 + 1im, 2 + 0.5im]; rc...)),
			("plot_contour!", "xy", none, (sf, rc) -> plot_contour!(sf, [1.0 2.0; 3.0 4.0]; rc...)),
			("plot_densitymap!", "map", none, (sf, rc) -> plot_densitymap!(sf, [0.0, 1], [0.0, 1]; rc...)),
			("plot_densitymapbox!", "mapbox", none, (sf, rc) -> plot_densitymapbox!(sf, [0.0, 1], [0.0, 1], [1.0, 2]; rc...)),
			("plot_ecdf!", "xy", none, (sf, rc) -> plot_ecdf!(sf, [1.0, 2, 3]; rc...)),
			("plot_funnel!", "xy", none, (sf, rc) -> plot_funnel!(sf, [90, 70, 40], ["A", "B", "C"]; rc...)),
			("plot_funnelarea!", "domain", none, (sf, rc) -> plot_funnelarea!(sf, [3, 2, 1]; rc...)),
			("plot_heatmap!", "xy", none, (sf, rc) -> plot_heatmap!(sf, [1.0 2.0; 3.0 4.0]; rc...)),
			("plot_histogram!", "xy", none, (sf, rc) -> plot_histogram!(sf, [1.0, 2, 2, 3]; rc...)),
			("plot_histogram2d!", "xy", none, (sf, rc) -> plot_histogram2d!(sf, [1.0, 2, 3], [1.0, 2, 3]; rc...)),
			("plot_hlines!", "xy", none, (sf, rc) -> plot_hlines!(sf, [1.0, 2], 0, 1; rc...)),
			("plot_image!", "xy", none, (sf, rc) -> plot_image!(sf, fill(UInt8(200), 2, 2, 3); rc...)),
			("plot_indicator!", "domain", none, (sf, rc) -> plot_indicator!(sf, 5; rc...)),
			("plot_isosurface!", "scene", none, (sf, rc) -> plot_isosurface!(sf, grid3((i, j, k) -> i), grid3((i, j, k) -> j),
				grid3((i, j, k) -> k), grid3((i, j, k) -> i + j + k); rc...)),
			("plot_kde!", "xy", none, (sf, rc) -> plot_kde!(sf, [1.0, 2, 2.5, 3, 4]; rc...)),
			("plot_matrix!", "xy", none, (sf, rc) -> plot_matrix!(sf, [1.0 2.0; 3.0 4.0]; rc...)),
			("plot_mesh3d!", "scene", none, (sf, rc) -> plot_mesh3d!(sf, [0.0, 1, 0, 0], [0.0, 0, 1, 0], [0.0, 0, 0, 1]; rc...)),
			("plot_ohlc!", "xy", none, (sf, rc) -> plot_ohlc!(sf, 1:2, [2, 3], [3, 4], [1.5, 2.5], [2.8, 2.6]; rc...)),
			("plot_parcoords!", "domain", none, (sf, rc) -> plot_parcoords!(sf, ["a" => [1, 2, 3], "b" => [3, 1, 2]]; rc...)),
			("plot_pcolormesh!", "xy", none, (sf, rc) -> plot_pcolormesh!(sf, 0.0:2, 0.0:2, [1.0 2.0; 3.0 4.0]; rc...)),
			("plot_pie!", "domain", none, (sf, rc) -> plot_pie!(sf, [1, 2]; rc...)),
			("plot_polygons!", "xy", none, (sf, rc) -> plot_polygons!(sf, [[0.0, 1.0, 1.0]], [[0.0, 0.0, 1.0]]; rc...)),
			("plot_polygons3d!", "scene", none, (sf, rc) -> plot_polygons3d!(sf, [[0.0 0 2; 1 0 2; 1 1 2; 0 1 2]]; rc...)),
			("plot_quiver!", "xy", none, (sf, rc) -> plot_quiver!(sf, [0.0, 1], [0.0, 1], [1.0, 1], [1.0, 1]; rc...)),
			("plot_quiver3d!", "scene", none, (sf, rc) -> plot_quiver3d!(sf, [0.0, 1], [0.0, 1], [0.0, 1], [1.0, 1], [1.0, 1], [1.0, 1]; rc...)),
			("plot_sankey!", "domain", none, (sf, rc) -> plot_sankey!(sf, [0, 1], [1, 2], [5, 3]; rc...)),
			("plot_scatter!", "xy", none, (sf, rc) -> plot_scatter!(sf, [1.0, 2], [1.0, 2]; rc...)),
			("plot_scatter3d!", "scene", none, (sf, rc) -> plot_scatter3d!(sf, [0.0, 1], [0.0, 1], [0.0, 1]; rc...)),
			("plot_scattergeo!", "geo", none, (sf, rc) -> plot_scattergeo!(sf, [0.0, 10], [0.0, 10]; rc...)),
			("plot_scattermap!", "map", none, (sf, rc) -> plot_scattermap!(sf, [0.0, 10], [0.0, 10]; rc...)),
			("plot_scattermapbox!", "mapbox", none, (sf, rc) -> plot_scattermapbox!(sf, [0.0, 10], [0.0, 10]; rc...)),
			("plot_scatterpolar!", "polar", none, (sf, rc) -> plot_scatterpolar!(sf, [1.0, 2], [0.0, 90]; rc...)),
			("plot_segments!", "xy", none, (sf, rc) -> plot_segments!(sf, [0.0], [0.0], [1.0], [1.0]; rc...)),
			("plot_segments3d!", "scene", none, (sf, rc) -> plot_segments3d!(sf, [0.0], [0.0], [0.0], [1.0], [1.0], [1.0]; rc...)),
			("plot_stem!", "xy", none, (sf, rc) -> plot_stem!(sf, [1.0, 2], [1.0, 2]; rc...)),
			("plot_streamlines!", "xy", none, (sf, rc) -> plot_streamlines!(sf, [0.0, 1, 2], [0.0, 1, 2], ones(3, 3), fill(0.5, 3, 3); rc...)),
			("plot_streamtube!", "scene", none, (sf, rc) -> plot_streamtube!(sf, grid3((i, j, k) -> i), grid3((i, j, k) -> j),
				grid3((i, j, k) -> k), grid3((i, j, k) -> 1.0), grid3((i, j, k) -> 0.0), grid3((i, j, k) -> 0.0); rc...)),
			("plot_sunburst!", "domain", none, (sf, rc) -> plot_sunburst!(sf, ["root", "a", "b"], ["", "root", "root"]; values=[0, 2, 1], rc...)),
			("plot_surface!", "scene", none, (sf, rc) -> plot_surface!(sf, [1.0 2.0; 3.0 4.0]; rc...)),
			("plot_ternary!", "ternary", none, (sf, rc) -> plot_ternary!(sf, [0.2, 0.3], [0.3, 0.3], [0.5, 0.4]; rc...)),
			("plot_treemap!", "domain", none, (sf, rc) -> plot_treemap!(sf, ["root", "a", "b"], ["", "root", "root"]; values=[0, 2, 1], rc...)),
			("plot_tricontour!", "xy", none, (sf, rc) -> plot_tricontour!(sf, [0.0, 1, 0, 1], [0.0, 0, 1, 1], [1 2 3; 2 4 3], [0.0, 1, 2, 3]; rc...)),
			("plot_tripcolor!", "xy", none, (sf, rc) -> plot_tripcolor!(sf, [0.0, 1, 0, 1], [0.0, 0, 1, 1], [1 2 3; 2 4 3], [0.0, 1, 2, 3]; rc...)),
			("plot_triplot!", "xy", none, (sf, rc) -> plot_triplot!(sf, [0.0, 1, 0, 1], [0.0, 0, 1, 1], [1 2 3; 2 4 3]; rc...)),
			("plot_violin!", "xy", none, (sf, rc) -> plot_violin!(sf, [1.0, 2, 3, 4]; rc...)),
			("plot_vlines!", "xy", none, (sf, rc) -> plot_vlines!(sf, [1.0, 2], 0, 1; rc...)),
			("plot_volume!", "scene", none, (sf, rc) -> plot_volume!(sf, grid3((i, j, k) -> i), grid3((i, j, k) -> j),
				grid3((i, j, k) -> k), grid3((i, j, k) -> i + j + k); rc...)),
			("plot_waterfall!", "xy", none, (sf, rc) -> plot_waterfall!(sf, ["a", "b"], [1, -1]; rc...)),
			("plot_wireframe!", "scene", none, (sf, rc) -> plot_wireframe!(sf, [0.0 1; 0 1], [0.0 0; 1 1], [1.0 2.0; 3.0 4.0]; rc...)),
			("polygon!", "xy", none, (sf, rc) -> polygon!(sf, [0.0, 1, 1], [0.0, 0, 1]; rc...)),
			("prependtraces!", "xy", none, (sf, rc) -> prependtraces!(sf, Dict(:y => [[1.0]]), [1]; rc...)),
			("purge!", "xy", none, (sf, rc) -> purge!(sf; rc...)),
			("react!", "xy", none, (sf, rc) -> react!(sf, sf.plot.data, sf.plot.layout; rc...)),
			("rectangle!", "xy", none, (sf, rc) -> rectangle!(sf, 0, 0, 1, 1; rc...)),
			("redraw!", "xy", none, (sf, rc) -> redraw!(sf; rc...)),
			("relayout!", "xy", none, (sf, rc) -> relayout!(sf; rc..., title_text="t")),
			("remove_inset!", "xy", sf -> inset!(sf, (0.6, 0.6, 0.3, 0.3); row=2, col=2), (sf, rc) -> remove_inset!(sf, 1; rc...)),
			("restyle!", "xy", none, (sf, rc) -> restyle!(sf, 1; rc..., opacity=0.5)),
			("scene!", "scene", points3d!, (sf, rc) -> scene!(sf; rc..., aspectmode="cube")),
			("secondary_xaxis!", "xy", xy!, (sf, rc) -> secondary_xaxis!(sf, x -> 2x, x -> x / 2; rc...)),
			("set_fonts!", "xy", none, (sf, rc) -> set_fonts!(sf; rc..., size=14)),
			("set_legend!", "xy", xy!, (sf, rc) -> set_legend!(sf; rc..., position=:topleft)),
			("set_template!", "xy", none, (sf, rc) -> set_template!(sf, "plotly_white"; rc...)),
			("shared_colorbar!", "xy", heat!, (sf, rc) -> shared_colorbar!(sf; rc...)),
			("slope_guide!", "xy", xy!, (sf, rc) -> slope_guide!(sf, 1; x=(1.0, 2.0), through=(1.0, 1.0), rc...)),
			("slope_triangle!", "xy", xy!, (sf, rc) -> slope_triangle!(sf, 1.0, 1.0, 1; rc...)),
			("spines!", "xy", none, (sf, rc) -> spines!(sf; rc..., style=:open)),
			("subplot!", "xy", none, (sf, rc) -> subplot!(sf, rc.row, rc.col)),
			("subplot_legends!", "xy", none, (sf, rc) -> subplot_legends!(sf; rc...)),
			("tight_layout!", "xy", none, (sf, rc) -> tight_layout!(sf; rc...)),
			("title!", "xy", none, (sf, rc) -> title!(sf, "T"; rc...)),
			("update!", "xy", none, (sf, rc) -> update!(sf; rc..., title_text="t")),
			("update_annotations!", "xy", sf -> annotate!(sf, 1, 1, "a"; row=2, col=2), (sf, rc) -> update_annotations!(sf; rc..., opacity=0.5)),
			("update_geos!", "geo", none, (sf, rc) -> update_geos!(sf; rc..., showland=true)),
			("update_images!", "xy", sf -> add_layout_image!(sf, image; row=2, col=2), (sf, rc) -> update_images!(sf; rc..., opacity=0.5)),
			("update_mapboxes!", "mapbox", none, (sf, rc) -> update_mapboxes!(sf; rc..., zoom=2)),
			("update_maps!", "map", none, (sf, rc) -> update_maps!(sf; rc..., zoom=2)),
			("update_polars!", "polar", none, (sf, rc) -> update_polars!(sf; rc..., hole=0.1)),
			("update_scenes!", "scene", none, (sf, rc) -> update_scenes!(sf; rc..., aspectmode="cube")),
			("update_shapes!", "xy", sf -> add_hline!(sf, 0.5; row=2, col=2), (sf, rc) -> update_shapes!(sf; rc..., opacity=0.5)),
			("update_ternaries!", "ternary", none, (sf, rc) -> update_ternaries!(sf; rc..., sum=1)),
			("update_xaxes!", "xy", none, (sf, rc) -> update_xaxes!(sf; rc..., title_text="t")),
			("update_yaxes!", "xy", none, (sf, rc) -> update_yaxes!(sf; rc..., title_text="t")),
			("view!", "scene", points3d!, (sf, rc) -> view!(sf; rc..., elev=20, azim=30)),
			("vline!", "xy", none, (sf, rc) -> vline!(sf, 0.5; rc...)),
			("vspan!", "xy", none, (sf, rc) -> vspan!(sf, 0.2, 0.4; rc...)),
			("xlabel!", "xy", none, (sf, rc) -> xlabel!(sf, "x"; rc...)),
			("xrange!", "xy", none, (sf, rc) -> xrange!(sf, [0, 1]; rc...)),
			("xticks!", "xy", none, (sf, rc) -> xticks!(sf, [0.0, 1.0]; rc...)),
			("ylabel!", "xy", none, (sf, rc) -> ylabel!(sf, "y"; rc...)),
			("yrange!", "xy", none, (sf, rc) -> yrange!(sf, [0, 1]; rc...)),
			("yticks!", "xy", none, (sf, rc) -> yticks!(sf, [0.0, 1.0]; rc...)),
			("zlabel!", "scene", points3d!, (sf, rc) -> zlabel!(sf, "z"; rc...)),
			("zrange!", "scene", points3d!, (sf, rc) -> zrange!(sf, [0, 1]; rc...)),
		]
		exported = Set(String(n) for n in names(PlotlySupply) if endswith(String(n), "!"))
		listed = Set(first(c) for c in calls)
		# A new exported mutator must be added to this table.
		@test isempty(setdiff(exported, process_wide, listed))
		@test isempty(setdiff(listed, exported))
		attempt(f) = try
			f()
			nothing
		catch err
			err
		end
		for (name, kind, setup, call) in calls
			@testset "$(name) on a $(kind) cell" begin
				sf = _rsp_complete_figure(kind)
				setup(sf)
				before11 = _rsp_cell_state(sf, 1, 1)
				before22 = _rsp_cell_state(sf, 2, 2)
				err = attempt(() -> call(sf, (row=2, col=2)))
				if err === nothing
					if name in ("ylabel!", "update_yaxes!", "plot_matrix!", "plot_tripcolor!")
						# D17: the room a y title takes in the gap before column 2,
						# and the room the colorbar of an equal-aspect cell (matrix,
						# mesh) needs beyond the right margin, is taken from every
						# column alike, so cell (1, 1) keeps the width of the plain
						# cell of column 2 (its legend follows its right edge);
						# nothing else of it changes.
						undomain(state) = merge(state, (
							objects = [replace(o, r"\"domain\":\[[^\]]*\],?" => "") for o in state.objects],
							legends = [replace(o, r"\"x\":[-+0-9.eE]+,?" => "") for o in state.legends]))
						@test undomain(_rsp_cell_state(sf, 1, 1)) == undomain(before11)
						xkey(r, c) = PlotlySupply._cell_target(sf; row = r, col = c, who = "test").xkey
						w11 = PlotlySupply._layout_axis_domain(sf.plot.layout, xkey(1, 1))
						plain = name in ("ylabel!", "update_yaxes!") ? (2, 2) : (1, 2)
						w2 = PlotlySupply._layout_axis_domain(sf.plot.layout, xkey(plain...))
						@test w11[2] - w11[1] ≈ w2[2] - w2[1] atol = 1e-9
					else
						@test _rsp_cell_state(sf, 1, 1) == before11
					end
					if name == "subplot!"
						# subplot! only selects the cell.
						@test (sf.current_row, sf.current_col) == (2, 2)
					else
						@test _rsp_cell_state(sf, 2, 2) != before22
					end
				else
					@test err isa ArgumentError
					@test err isa ArgumentError && startswith(err.msg, name * ":")
				end
				# Y20: a cell outside the grid is an ArgumentError naming the
				# function, raised before anything changes.
				fresh = _rsp_complete_figure(kind)
				setup(fresh)
				snapshot = JSON.json(fresh.plot)
				bad = attempt(() -> call(fresh, (row=99, col=2)))
				@test bad isa ArgumentError
				@test bad isa ArgumentError && startswith(bad.msg, name * ":")
				@test JSON.json(fresh.plot) == snapshot
			end
		end
	end
end

@testset "shared axes: styling a hidden-label axis title keeps the shown title's text" begin
	# Wave-4 integration regression: `set_fonts!` writes `title.font` on every
	# axis; on a shared-x column that font-only title of a hidden-label axis was
	# "moved" to the label-showing axis and replaced its text (the x title of
	# the bottom panel vanished from the figure).
	title_fields(sf, key) = (t = get(_rsp_axis(sf, key), :title, nothing);
		t === nothing ? nothing : _rsp_fields(t))
	make() = begin
		sf = subplots(3, 1; sync = false, shared_xaxes = true)
		for row in 1:3
			plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; row = row, col = 1)
		end
		xlabel!(sf, "position"; row = 3, col = 1)
		sf
	end

	sf = make()
	@test title_fields(sf, :xaxis3)[:text] == "position"
	set_fonts!(sf; label = 8, units = :pt)
	shown = title_fields(sf, :xaxis3)
	@test shown[:text] == "position"
	@test _rsp_fields(shown[:font])[:size] ≈ 8 * 4 / 3
	# A second pass and an explicit font update change nothing about the text.
	set_fonts!(sf; label = 9, units = :pt)
	@test title_fields(sf, :xaxis3)[:text] == "position"
	update_xaxes!(sf; title_font_size = 11)
	@test title_fields(sf, :xaxis3)[:text] == "position"
	@test _rsp_fields(title_fields(sf, :xaxis3)[:font])[:size] == 11

	# A text title set on a hidden-label cell still moves to the shown axis,
	# and keeps the font the shown axis already had.
	sf = make()
	set_fonts!(sf; label = 8, units = :pt)
	xlabel!(sf, "moved"; row = 1, col = 1)
	shown = title_fields(sf, :xaxis3)
	@test shown[:text] == "moved"
	@test _rsp_fields(shown[:font])[:size] ≈ 8 * 4 / 3
	hidden = title_fields(sf, :xaxis)
	@test hidden === nothing || !haskey(hidden, :text)

	# The same for a shared-y row.
	sf = subplots(1, 3; sync = false, shared_yaxes = true)
	for col in 1:3
		plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; row = 1, col = col)
	end
	ylabel!(sf, "amplitude"; row = 1, col = 1)
	set_fonts!(sf; label = 8, units = :pt)
	@test title_fields(sf, :yaxis)[:text] == "amplitude"
end

# ── Wave 5: shared-axis group sync audit (table-driven) ─────────────────────

# The tick-label, autorange-option and title state of every Cartesian axis.
const _RSP_SYNC_SHARED = (:type, :exponentformat, :showexponent, :tickmode, :tickvals, :ticktext, :tick0,
	:dtick, :nticks, :tickformat, :tickprefix, :ticksuffix, :separatethousands, :categoryorder,
	:categoryarray, :minor)
const _RSP_SYNC_GRID_ONLY = (:tickfont, :tickangle)
const _RSP_SYNC_LIMITS = (:minallowed, :maxallowed, :clipmin, :clipmax, :include)

_rsp_json(value) = value === nothing ? "null" : JSON.json(value)

# Shared-axis groups of `sf`, read from `matches` (root => members).
function _rsp_match_groups(sf::SubplotFigure)
	fields = _rsp_layout(sf)
	groups = Dict{Symbol, Vector{Symbol}}()
	for (key, axis) in fields
		occursin(r"^[xy]axis\d*$", String(key)) || continue
		a = _rsp_fields(axis)
		haskey(a, :overlaying) && continue
		ref = get(a, :matches, nothing)
		ref === nothing && continue
		letter = String(key)[1]
		root = Symbol(letter, "axis", String(ref)[2:end])
		haskey(fields, root) || continue
		push!(get!(() -> Symbol[root], groups, root), key)
	end
	return groups
end

# Violations of the group invariants: group-wide attributes equal on every
# member (tick font/angle on the grid axes, insets keep theirs), every
# `autorangeoptions` entry equal on every member, range/autorange stated on
# the root only, no title text on a member whose tick labels are hidden.
function _rsp_sync_problems(sf::SubplotFigure)
	fields = _rsp_layout(sf)
	insets = Set{Symbol}()
	for inset in sf.insets
		push!(insets, inset.xkey, inset.ykey)
	end
	problems = String[]
	for (root, members) in _rsp_match_groups(sf)
		axes = Dict(m => _rsp_fields(fields[m]) for m in members)
		for name in (_RSP_SYNC_SHARED..., _RSP_SYNC_GRID_ONLY...)
			considered = name in _RSP_SYNC_GRID_ONLY ? filter(m -> !(m in insets), members) : members
			values = unique(_rsp_json(get(axes[m], name, nothing)) for m in considered)
			length(values) <= 1 || push!(problems, "$(root) group: $(name) differs: $(values)")
		end
		for entry in _RSP_SYNC_LIMITS
			values = unique(_rsp_json(get(_rsp_fields(get(axes[m], :autorangeoptions, attr())), entry, nothing))
				for m in members)
			length(values) <= 1 || push!(problems, "$(root) group: autorangeoptions.$(entry) differs: $(values)")
		end
		for m in members
			m === root && continue
			for name in (:range, :autorange)
				haskey(axes[m], name) && push!(problems, "$(m) (follower of $(root)) states $(name)")
			end
		end
		for m in members
			get(axes[m], :showticklabels, true) === false || continue
			text = _rsp_title_text(axes[m])
			(text isa AbstractString && !isempty(text)) && push!(problems, "$(m) (hidden labels) holds title $(repr(text))")
		end
	end
	return problems
end

# Everything a styling call must not move, drop or duplicate: the trace
# count, the axis title texts per axis and the annotation texts.
function _rsp_content(sf::SubplotFigure)
	fields = _rsp_layout(sf)
	titles = sort!([(String(k), _rsp_title_text(_rsp_fields(v))) for (k, v) in fields
		if occursin(r"^[xy]axis\d*$", String(k)) && _rsp_title_text(_rsp_fields(v)) !== nothing])
	notes = sort!([string(get(_rsp_fields(a), :text, "")) for a in get(fields, :annotations, Any[])])
	return (length(sf.plot.data), titles, notes)
end

# `:removed_cell`: shared columns and rows with cell (2, 2) removed
# (`missing` spec), the secondary y axis in cell (1, 2).
function _rsp_sync_figure(mode::Symbol)
	kw = mode === :x_columns ? (shared_xaxes = true,) :
		mode === :y_rows ? (shared_yaxes = true,) :
		mode === :x_rows ? (shared_xaxes = "rows",) :
		mode === :y_columns ? (shared_yaxes = "columns",) :
		mode === :removed_cell ? (shared_xaxes = true, shared_yaxes = true) :
		(shared_xaxes = "all", shared_yaxes = "all")
	removed = mode === :removed_cell
	specs = removed ? [Spec() Spec(secondary_y = true); Spec() missing] :
		[Spec() Spec(); Spec() Spec(secondary_y = true)]
	sf = subplots(2, 2; sync = false, specs = specs, subplot_titles = ["a" "b"; "c" "d"], kw...)
	for r in 1:2, c in 1:2
		removed && (r, c) == (2, 2) && continue
		plot_scatter!(sf, [1.0, 2.0, 4.0], [1.0, 3.0, 2.0] .* (r + c); row = r, col = c)
	end
	secondary = removed ? (1, 2) : (2, 2)
	plot_scatter!(sf, [1.0, 2.0, 4.0], [10.0, 20.0, 15.0]; row = secondary[1], col = secondary[2], secondary_y = true)
	inset!(sf, (0.55, 0.55, 0.4, 0.4); row = 1, col = 1, sharex = true, sharey = true)
	xlabel!(sf, "x of (1,1)"; row = 1, col = 1)
	ylabel!(sf, "y of (1,2)"; row = 1, col = 2)
	return sf
end

const _RSP_SYNC_TEMPLATE = let t = deepcopy(PlotlySupply.PlotlyBase.templates[:plotly_white])
	t.layout[:xaxis] = attr(tickformat = ".1f", title = attr(standoff = 5))
	t.layout[:yaxis] = attr(type = "linear", tickfont = attr(size = 13))
	t
end

# (name, styling-only?, idempotent?, call)
const _RSP_SYNC_CALLS = Any[
	("set_fonts! (figure)", true, true, sf -> set_fonts!(sf; tick = 9, label = 10, title = 12)),
	("set_fonts! (cell 1,1)", true, true, sf -> set_fonts!(sf; row = 1, col = 1, tick = 7, label = 8)),
	("set_fonts! (cell 2,2)", true, true, sf -> set_fonts!(sf; row = 2, col = 2, tick = 7)),
	("set_template! (name)", true, true, sf -> set_template!(sf, "plotly_dark")),
	("set_template! (axis defaults)", true, true, sf -> set_template!(sf, _RSP_SYNC_TEMPLATE)),
	("tight_layout!", true, true, sf -> tight_layout!(sf)),
	("update_xaxes! title font (all)", true, true, sf -> update_xaxes!(sf; title_font_size = 11)),
	("update_xaxes! title font (cell)", true, true, sf -> update_xaxes!(sf; row = 1, col = 2, title_font_size = 11)),
	("xticks! angle (cell)", true, true, sf -> xticks!(sf; angle = 30, row = 1, col = 1)),
	("xticks! angle (inset)", true, true, sf -> xticks!(sf; angle = 20, inset = 1)),
	("spines!", true, true, sf -> spines!(sf; style = :open)),
	("grid!", true, true, sf -> grid!(sf; row = 2, col = 1)),
	("xlabel! (hidden cell)", false, true, sf -> xlabel!(sf, "moved"; row = 1, col = 2)),
	("ylabel! (hidden cell)", false, true, sf -> ylabel!(sf, "moved"; row = 2, col = 2)),
	("xticks! values (cell)", false, true, sf -> xticks!(sf, [1.0, 2.0, 4.0]; row = 1, col = 2)),
	("yticks! values (inset)", false, true, sf -> yticks!(sf, [2.0, 4.0]; inset = 1)),
	("xrange! one-sided (follower)", false, true, sf -> xrange!(sf, (0, nothing); row = 1, col = 1)),
	("yrange! full (cell)", false, true, sf -> yrange!(sf, [0, 20]; row = 1, col = 2)),
	("keyword log + ticks", false, false, sf -> plot_scatter!(sf, [1.0, 2.0, 4.0], [1.0, 2.0, 3.0]; row = 1, col = 2,
		xscale = "log", yticks = [1.0, 2.0], ytickformat = ".2f")),
	("keyword one-sided limit", false, false, sf -> plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row = 1, col = 1,
		xrange = (nothing, 6))),
	("relayout! underscore", false, true, sf -> relayout!(sf; xaxis2_dtick = 1, yaxis2_tickformat = ".1f")),
	("relayout! dotted", false, true, sf -> relayout!(sf, Dict{Symbol, Any}(Symbol("xaxis.nticks") => 4, Symbol("yaxis3.type") => "log"))),
	("relayout! nested", false, true, sf -> relayout!(sf; xaxis4 = attr(tickprefix = "~"), yaxis = attr(title_text = "via relayout"))),
	("relayout! follower range", false, true, sf -> relayout!(sf; xaxis_range = [0, 5])),
	("update! layout", false, true, sf -> update!(sf; layout = Layout(yaxis4_tickangle = 45))),
	("update_yaxes! (cell)", false, true, sf -> update_yaxes!(sf; row = 2, col = 2, type = "log")),
	("remove_inset!", false, false, sf -> remove_inset!(sf, 1)),
	# One-sided limits (D11) through every entry point.
	("xrange! one-sided (root cell)", false, true, sf -> xrange!(sf, (nothing, 6); row = 2, col = 1)),
	("yrange! one-sided (cell)", false, true, sf -> yrange!(sf, (0, nothing); row = 2, col = 2)),
	("keyword one-sided y limit", false, true, sf -> plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row = 2, col = 1,
		yrange = (0, nothing))),
	("update_xaxes! autorangeoptions", false, true, sf -> update_xaxes!(sf; row = 1, col = 2,
		autorangeoptions = attr(minallowed = 0))),
	("relayout! autorangeoptions", false, true, sf -> relayout!(sf; xaxis2_autorangeoptions_maxallowed = 30)),
	("one-sided limit then full range", false, true, sf -> (xrange!(sf, (0, nothing); row = 1, col = 1);
		xrange!(sf, [1, 3]; row = 2, col = 1))),
	# `_axes_finalize_updates!`: decade ticks and wrapped titles.
	# Under a paper style the finalizer writes decade ticks on log axes.
	("log decade ticks (keyword)", false, true, sf -> with_style(:ieee) do
		plot_scatter!(sf, [1.0, 10.0, 1e3, 1e5], [1.0, 10.0, 1e3, 1e5]; row = 2, col = 1, xscale = "log", yscale = "log")
	end),
	("log decade ticks (relayout!)", false, true, sf -> with_style(:ieee) do
		relayout!(sf; xaxis_type = "log", yaxis3_type = "log")
	end),
	("log decade ticks (figsize!)", false, true, sf -> (relayout!(sf; xaxis_type = "log"); figsize!(sf, :ieee))),
	("wrapped long x title", false, true, sf -> xlabel!(sf, "A very long shared axis title that runs well past the width of its column " ^ 2;
		row = 1, col = 2)),
	("wrapped long y title", false, true, sf -> ylabel!(sf, "A very long shared axis title that runs well past the height of its row " ^ 2;
		row = 2, col = 1)),
	# Calls whose room reservations move the domains.
	# (not idempotent as a call: a second heatmap brings a second colorbar,
	# which needs room of its own; the finalize check below covers the rest)
	("heatmap colorbar (cell)", false, false, sf -> plot_heatmap!(sf, [1.0 2 3; 4 5 6]; row = 1, col = 2)),
	("panel title (cell)", false, true, sf -> title!(sf, "panel"; row = 1, col = 2)),
	("panel_labels!", false, true, sf -> panel_labels!(sf)),
	("figsize! :ieee", true, true, sf -> figsize!(sf, :ieee)),
	("set_style under with_style", false, true, sf -> with_style(:ieee) do
		xlabel!(sf, "styled"; row = 1, col = 2)
		set_fonts!(sf; tick = 7)
	end),
]

@testset "shared axes: every call keeps the group invariants (table)" begin
	for mode in (:x_columns, :y_rows, :x_rows, :y_columns, :all, :removed_cell)
		@testset "$(mode)" begin
			base = _rsp_sync_figure(mode)
			@test !isempty(_rsp_match_groups(base))
			@test isempty(_rsp_sync_problems(base))
			for (name, styling, idempotent, call) in _RSP_SYNC_CALLS
				@testset "$(name)" begin
					sf = _rsp_sync_figure(mode)
					before = _rsp_content(sf)
					state = JSON.json(sf.plot)
					# On `:removed_cell` a call that addresses the removed
					# cell is an ArgumentError that leaves the figure as it
					# was; elsewhere every call applies.
					err = try
						call(sf)
						nothing
					catch caught
						mode === :removed_cell || rethrow()
						caught
					end
					if err !== nothing
						@test err isa ArgumentError
						@test JSON.json(sf.plot) == state
					else
						@test isempty(_rsp_sync_problems(sf))
						styling && @test _rsp_content(sf) == before
						first_state = JSON.json(sf.plot.layout)
						# Whatever the call did, the figure is settled: finalizing
						# it again writes nothing (D10/D12).
						@test PlotlySupply._finalize_figure!(sf) === false
						@test JSON.json(sf.plot.layout) == first_state
						if idempotent
							call(sf)
							@test JSON.json(sf.plot.layout) == first_state
						end
					end
				end
			end
		end
	end
	# with_style: a figure built under a journal style keeps the invariants.
	sf = with_style(:ieee) do
		_rsp_sync_figure(:x_columns)
	end
	@test isempty(_rsp_sync_problems(sf))
end

@testset "shared axes: the finalizer's axis fits reach a fixed point in one call" begin
	# Decade ticks of a log axis read the domain the room solve moves: a
	# second `_finalize_figure!` must write nothing, and neither may the
	# next call of the same kind.
	for mode in (:x_columns, :y_rows, :x_rows, :all)
		sf = _rsp_sync_figure(mode)
		with_style(:ieee) do
			plot_scatter!(sf, [1.0, 10.0, 1e3, 1e5], [1.0, 10.0, 1e3, 1e5]; row = 2, col = 1,
				xscale = "log", yscale = "log")
			@test PlotlySupply._finalize_figure!(sf) === false
			ticks = [get(_rsp_axis(sf, k), :dtick, nothing) for k in (:xaxis3, :yaxis3)]
			@test any(!isnothing, ticks)
			before = JSON.json(sf.plot.layout)
			plot_scatter!(sf, [1.0, 10.0, 1e3, 1e5], [1.0, 10.0, 1e3, 1e5]; row = 2, col = 1,
				xscale = "log", yscale = "log")
			@test JSON.json(sf.plot.layout) == before
		end
		@test isempty(_rsp_sync_problems(sf))
	end
end

@testset "shared axes: a title text lives on the members that show tick labels, once each" begin
	# x groups of `sf`: root => (members carrying a title starting with `text`,
	# members whose tick labels are shown).
	function carriers(sf, text)
		out = Dict{Symbol, Tuple{Vector{Symbol}, Vector{Symbol}}}()
		inset_keys = Set(k for inset in sf.insets for k in (inset.xkey, inset.ykey))
		for (root, members) in _rsp_match_groups(sf)
			startswith(String(root), "xaxis") || continue
			# Insets take no title; the finalizer wraps a long title with
			# `<br>` (after a zero-width space) where the figure is narrow.
			members = filter(m -> !(m in inset_keys), members)
			axes = Dict(m => _rsp_fields(_rsp_layout(sf)[m]) for m in members)
			plain(t) = replace(t, "\u200b<br>" => " ", "<br>" => " ", "\u200b" => "")
			titled = sort([m for m in members if (t = _rsp_title_text(axes[m]); t isa AbstractString && startswith(plain(t), text))])
			shown = sort([m for m in members if get(axes[m], :showticklabels, true) !== false])
			out[root] = (titled, shown)
		end
		return out
	end
	long = "A very long shared axis title that runs well past the width of its column "
	for mode in (:x_columns, :x_rows, :all), (label, text) in (("short", "T"), ("long (wrapped)", long ^ 2))
		@testset "$(mode) $(label)" begin
			prefix = text[1:min(end, 20)]
			sf = _rsp_sync_figure(mode)
			for cell in ((1, 1), (1, 2), (2, 1), (2, 2))
				xlabel!(sf, text; row = cell[1], col = cell[2])
			end
			# Labelled through every cell: the title is on every member that
			# shows tick labels and on no hidden one (a hidden member's call
			# moved its title to the shown one, never duplicating it).
			info = carriers(sf, prefix)
			@test !isempty(info)
			for (root, (titled, shown)) in info
				@test titled == shown
			end
			@test isempty(_rsp_sync_problems(sf))
			# Styling, journal size and style, and a repeated call neither
			# move nor duplicate it.
			set_fonts!(sf; label = 9)
			figsize!(sf, :ieee)
			with_style(:ieee) do
				xlabel!(sf, text; row = 1, col = 1)
			end
			for (root, (titled, shown)) in carriers(sf, prefix)
				@test titled == shown
			end
			@test isempty(_rsp_sync_problems(sf))
			again = JSON.json(sf.plot.layout)
			xlabel!(sf, text; row = 1, col = 1)
			@test JSON.json(sf.plot.layout) == again
		end
	end
	# A single call names one cell of a shared column: one titled member.
	sf = _rsp_sync_figure(:x_columns)
	xlabel!(sf, "only"; row = 1, col = 2)
	# Cell (1, 2) hides its tick labels: the title is on the shown axis of
	# its column, (2, 2), and nowhere else.
	@test Dict(k => first(v) for (k, v) in carriers(sf, "only")) == Dict(:xaxis3 => Symbol[], :xaxis4 => [:xaxis4])
end

# Plotly.js operations a recording renderer received.
_rsp_ops(renderer) = [m.captures[1] for s in renderer.scripts
	for m in eachmatch(r"Plotly\.(react|addTraces|relayout|restyle|newPlot)\(", s)]
_rsp_axis_get(sf, key, name) = get(_rsp_axis(sf, key), name, nothing)

@testset "shared axes: relayout!/update! act on the group (Z12, Z29)" begin
	types(sf) = (_rsp_axis_get(sf, :yaxis, :type), _rsp_axis_get(sf, :yaxis2, :type))
	for call in (
		sf -> relayout!(sf; yaxis2_type = "log"),
		sf -> relayout!(sf, Dict{Symbol, Any}(Symbol("yaxis2.type") => "log")),
		sf -> relayout!(sf; yaxis2 = attr(type = "log")),
		sf -> update!(sf; layout = Layout(yaxis2_type = "log")),
	)
		sf = subplots(1, 2; sync = false, shared_yaxes = true)
		@test call(sf) === sf
		@test types(sf) == ("log", "log")
	end
	sf = subplots(1, 2; sync = false, shared_yaxes = true)
	relayout!(sf; yaxis2_tickvals = [2.0], yaxis2_tickformat = ".1f")
	@test _rsp_axis_get(sf, :yaxis, :tickvals) == [2.0]
	@test _rsp_axis_get(sf, :yaxis, :tickformat) == ".1f"
	# A follower range is the group's: it moves to the root.
	sf = subplots(2, 1; sync = false, shared_xaxes = true)
	relayout!(sf; xaxis_range = [0, 5])
	@test _rsp_axis_get(sf, :xaxis2, :range) == [0, 5]
	@test _rsp_axis_get(sf, :xaxis2, :autorange) === false
	@test _rsp_axis_get(sf, :xaxis, :range) === nothing
	# Without shared axes, or naming no group axis, the verb is the plain one.
	sf = subplots(1, 2; sync = false)
	relayout!(sf; yaxis2_type = "log")
	@test types(sf) == (nothing, "log")
	sf = subplots(1, 2; sync = false, shared_yaxes = true)
	plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; row = 1, col = 1)
	renderer = _rsp_live!(sf)
	relayout!(sf; title_text = "t")
	@test _rsp_ops(renderer) == ["relayout"]
	empty!(renderer.scripts)
	relayout!(sf; yaxis2_type = "log")
	@test _rsp_ops(renderer) == ["react"]
	@test types(sf) == ("log", "log")
	# Cell keywords are still rejected before anything changes.
	snapshot = JSON.json(sf.plot)
	@test_throws ArgumentError relayout!(sf; row = 1, yaxis2_type = "linear")
	@test_throws ArgumentError update!(sf; col = 1, layout = Layout(yaxis2_type = "linear"))
	@test JSON.json(sf.plot) == snapshot
	# A failing renderer leaves the model as it was.
	renderer.fail = true
	@test_throws PlotlySupply._SyncPlotDesynchronizationError relayout!(sf; yaxis_type = "linear")
	@test types(sf) == ("log", "log")
end

@testset "shared axes: only a title text set by the call moves" begin
	title_text(sf, key) = (t = _rsp_axis_get(sf, key, :title); t === nothing ? nothing :
		t isa AbstractString ? t : get(_rsp_fields(t), :text, nothing))
	sf = subplots(2, 1; sync = false, shared_xaxes = true)
	plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; row = 1, col = 1)
	xlabel!(sf, "bottom"; row = 2, col = 1)
	# A raw write leaves a text on the hidden-label axis; styling it later
	# must not move that text over the shown title.
	PlotlySupply.PlotlyBase.relayout!(sf.plot; xaxis_title_text = "raw top")
	set_fonts!(sf; label = 9)
	@test title_text(sf, :xaxis2) == "bottom"
	update_xaxes!(sf; row = 1, col = 1, title_font_size = 12)
	@test title_text(sf, :xaxis2) == "bottom"
	# Setting the text moves it.
	xlabel!(sf, "moved"; row = 1, col = 1)
	@test title_text(sf, :xaxis2) == "moved"
	@test title_text(sf, :xaxis) === nothing
end

@testset "shared axes: an inset keeps its own tick font and angle" begin
	sf = subplots(2, 1; sync = false, shared_xaxes = true)
	plot_scatter!(sf, 1:10, collect(1.0:10); row = 1, col = 1)
	plot_scatter!(sf, 1:10, collect(1.0:10); row = 2, col = 1)
	k = inset!(sf, (0.6, 0.6, 0.3, 0.3); row = 1, col = 1, sharex = true)
	ik = sf.insets[k].xkey
	inset_font = _rsp_fields(_rsp_axis_get(sf, ik, :tickfont))[:size]
	set_fonts!(sf; row = 2, col = 1, tick = 7)
	@test _rsp_fields(_rsp_axis_get(sf, :xaxis, :tickfont))[:size] == 7
	@test _rsp_fields(_rsp_axis_get(sf, ik, :tickfont))[:size] == inset_font
	xticks!(sf; angle = 30, inset = k)
	@test _rsp_axis_get(sf, ik, :tickangle) == 30
	@test _rsp_axis_get(sf, :xaxis, :tickangle) === nothing
	@test _rsp_axis_get(sf, :xaxis2, :tickangle) === nothing
	# Tick placement is the group's (matplotlib `sharex`).
	xticks!(sf, [2.0, 4.0]; inset = k)
	@test _rsp_axis_get(sf, :xaxis, :tickvals) == [2.0, 4.0]
	@test _rsp_axis_get(sf, :xaxis2, :tickvals) == [2.0, 4.0]
	@test _rsp_axis_get(sf, ik, :tickvals) == [2.0, 4.0]
end

@testset "shared axes: one-sided limits reach every member" begin
	limits(sf, key) = (o = _rsp_axis_get(sf, key, :autorangeoptions); o === nothing ? nothing :
		Dict(k => v for (k, v) in _rsp_fields(o)))
	sf = subplots(2, 1; sync = false, shared_xaxes = true)
	plot_scatter!(sf, 1:10, collect(1.0:10); row = 1, col = 1)
	plot_scatter!(sf, 1:10, collect(1.0:10); row = 2, col = 1, xrange = (nothing, 20))
	@test limits(sf, :xaxis2) == Dict(:maxallowed => 20)
	@test limits(sf, :xaxis) == Dict(:maxallowed => 20)
	# A one-sided limit replaces the earlier one (D11: the open side
	# autoranges), on the follower as on the root; before the fix the root
	# kept `maxallowed` and plotly.js united both members' limits.
	plot_scatter!(sf, 1:10, collect(1.0:10); row = 1, col = 1, xrange = (-5, nothing))
	@test limits(sf, :xaxis2) == Dict(:minallowed => -5)
	@test limits(sf, :xaxis) == Dict(:minallowed => -5)
	# A second identical call writes nothing.
	layout = JSON.json(sf.plot.layout)
	plot_scatter!(sf, 1:10, collect(1.0:10); row = 1, col = 1, xrange = (-5, nothing))
	@test JSON.json(sf.plot.layout) == layout
	# A limit written on one member reaches the group, its removal too.
	relayout!(sf; xaxis_autorangeoptions_maxallowed = 30)
	@test limits(sf, :xaxis2) == Dict(:minallowed => -5, :maxallowed => 30)
	relayout!(sf; xaxis_autorangeoptions_minallowed = nothing)
	@test limits(sf, :xaxis2) == Dict(:maxallowed => 30)
	@test limits(sf, :xaxis) == Dict(:maxallowed => 30)
end

@testset "shared axes: sticky field ranges are not bounced" begin
	U = [sin(a / 3) * cos(b / 4) for a in 1:8, b in 1:6]
	for equalar in (false, true)
		sf = subplots(2, 1; sync = false, shared_xaxes = true)
		plot_heatmap!(sf, U; row = 1, col = 1, equalar = equalar)
		plot_heatmap!(sf, 2 .* U; row = 2, col = 1, equalar = equalar)
		@test isempty(_rsp_sync_problems(sf))
		_rsp_live!(sf)
		plot_scatter!(sf, [2.0, 3.0], [2.0, 3.0]; row = 1, col = 1)
		for call in (
			sf -> plot_scatter!(sf, [2.0, 3.0], [2.0, 3.0]; row = 1, col = 1),
			sf -> xlabel!(sf, "x"; row = 2, col = 1),
		)
			call(sf)
			second = JSON.json(sf.plot.layout)
			call(sf)
			@test JSON.json(sf.plot.layout) == second
		end
		@test isempty(_rsp_sync_problems(sf))
	end
end

@testset "figure-wide gaps through the delegate (Z33)" begin
	gaps(sf) = (get(_rsp_layout(sf), :bargap, nothing), get(_rsp_layout(sf), :bargroupgap, nothing))
	sf = subplots(1, 2; sync = false)
	PlotlySupply._subplot_delegate_mutator!(sf, plot_bar!, ["a", "b"], [1, 2]; row = 1, col = 2,
		bargap = 0.3, bargroupgap = 0.1)
	@test gaps(sf) == (0.3, 0.1)
	# An automatic gap of a mutator never reaches the root.
	sf = subplots(1, 2; sync = false)
	plot_histogram!(sf, [1.0, 2, 2, 3]; row = 1, col = 1)
	plot_bar!(sf, ["a", "b"], [1, 2]; row = 1, col = 2)
	@test gaps(sf) == (nothing, nothing)
	# The stats family writes them in the same transaction as the bars.
	sf = subplots(1, 2; sync = false)
	renderer = _rsp_live!(sf)
	plot_bar!(sf, ["a", "b"], [1, 2]; row = 1, col = 2, bargap = 0.25, bargroupgap = 0.05)
	@test gaps(sf) == (0.25, 0.05)
	@test length(renderer.scripts) == 1
	snapshot = JSON.json(sf.plot)
	@test_throws ArgumentError plot_bar!(sf, ["a"], [1]; row = 1, col = 1, bargap = 2.0)
	@test JSON.json(sf.plot) == snapshot
end

@testset "grid titles are named (Z60)" begin
	names_texts(sf) = [(get(_rsp_fields(a), :name, nothing), _rsp_fields(a)[:text]) for a in _rsp_layout(sf)[:annotations]]
	sf = subplots(2, 2; sync = false, subplot_titles = ["a" "b"; "c" "d"], column_titles = ["C1", "C2"],
		row_titles = ["R1", "R2"], x_title = "X", y_title = "Y")
	@test names_texts(sf) == [
		("plotlysupply:title:1:1", "a"), ("plotlysupply:title:1:2", "b"),
		("plotlysupply:title:2:1", "c"), ("plotlysupply:title:2:2", "d"),
		("plotlysupply:title!:1:1:column", "C1"), ("plotlysupply:title!:1:2:column", "C2"),
		("plotlysupply:title!:1:2:row", "R1"), ("plotlysupply:title!:2:2:row", "R2"),
		("plotlysupply:x_title", "X"), ("plotlysupply:y_title", "Y"),
	]
	# List form: titles go to the occupied cells in row-major order.
	sl = subplots(2, 2; sync = false, specs = [Spec() Spec(); Spec(colspan = 2) missing], subplot_titles = ["p" "q" "r"])
	@test names_texts(sl) == [("plotlysupply:title:1:1", "p"), ("plotlysupply:title:1:2", "q"), ("plotlysupply:title:2:1", "r")]
	# A journal style and set_fonts! size them as titles.
	sizes(sf) = [_rsp_fields(_rsp_fields(a)[:font])[:size] for a in _rsp_layout(sf)[:annotations]]
	journal_size = with_style(:ieee) do
		PlotlySupply._active_style().title_fontsize
	end
	@test journal_size > 0 && journal_size != 16
	ieee = with_style(:ieee) do
		subplots(2, 2; sync = false, subplot_titles = ["a" "b"; "c" "d"], x_title = "X", y_title = "Y")
	end
	@test all(s -> s ≈ journal_size, sizes(ieee))
	set_fonts!(ieee; title = 20)
	@test all(==(20), sizes(ieee))
	# A cell-scoped call styles that cell's title only.
	set_fonts!(ieee; row = 1, col = 2, title = 9)
	@test sizes(ieee) == [20, 9, 20, 20, 20, 20]
	# title! replaces the cell's grid title instead of adding a second one.
	title!(ieee, "new b"; row = 1, col = 2)
	texts = [_rsp_fields(a)[:text] for a in _rsp_layout(ieee)[:annotations]]
	@test count(==("new b"), texts) == 1
	@test !("b" in texts)
	# The default style keeps plotly's make_subplots title size.
	@test all(==(16), sizes(sf))
end

@testset "plot! names itself in cell errors (Z23)" begin
	sf = subplots(1, 2; sync = false)
	snapshot = JSON.json(sf.plot)
	catch_error(f) = try
		f()
		nothing
	catch e
		e
	end
	err = catch_error(() -> plot!(sf, [1.0, 2.0], [1.0, 2.0]; row = 99, col = 2))
	@test err isa ArgumentError && startswith(err.msg, "plot!:")
	err = catch_error(() -> plot!(sf, [1.0, 2.0], [1.0, 2.0]; row = 1, col = 1, secondary_y = true))
	@test err isa ArgumentError && startswith(err.msg, "plot!:")
	err = catch_error(() -> plot!(sf, [1.0, 2.0]; row = 99, col = 1))
	@test err isa ArgumentError && startswith(err.msg, "plot!:")
	@test JSON.json(sf.plot) == snapshot
	@test plot!(sf, [1.0, 2.0], [1.0, 2.0]; row = 1, col = 2) === sf
	@test length(sf.plot.data) == 1
end

@testset "SubplotFigure appends are staged append-only (Z82)" begin
	x = collect(range(0.0, 10.0; length = 100))
	y = sin.(x)
	legend_ids(sf) = [get(t.fields, :legend, nothing) for t in sf.plot.data]
	# Per-subplot legends (the default): an append that changes no existing
	# trace goes to the live window as addTraces + relayout.
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, x, y; row = 1, col = 1, legend = "a")
	renderer = _rsp_live!(sf)
	plot_scatter!(sf, x, y .+ 1; row = 1, col = 1, legend = "b")
	@test _rsp_ops(renderer) == ["addTraces", "relayout"]
	empty!(renderer.scripts)
	plot_scatter!(sf, x, y .+ 2; row = 1, col = 2, legend = "c")
	@test _rsp_ops(renderer) == ["addTraces", "relayout"]
	@test legend_ids(sf) == ["legend", "legend", "legend2"]
	@test all(t -> haskey(t.fields, :showlegend), sf.plot.data)
	# A trace added through the underlying figure has no legend id yet: the
	# next append gives it one, which rewrites an existing trace, so that call
	# is staged fully.
	addtraces!(sf.fig, scatter(x = [1.0, 2.0], y = [1.0, 2.0], xaxis = "x", yaxis = "y", name = "raw"))
	@test !haskey(sf.plot.data[end].fields, :legend)
	empty!(renderer.scripts)
	plot_scatter!(sf, x, y; row = 1, col = 2, legend = "d")
	@test _rsp_ops(renderer) == ["react"]
	@test legend_ids(sf) == ["legend", "legend", "legend2", "legend", "legend2"]
	# Existing colorbars and equal-aspect cells may move: full staging.
	empty!(renderer.scripts)
	plot_heatmap!(sf, [1.0 2.0; 3.0 4.0]; row = 1, col = 2)
	@test _rsp_ops(renderer) == ["addTraces", "relayout"]
	empty!(renderer.scripts)
	plot_scatter!(sf, x, y; row = 1, col = 1)
	@test _rsp_ops(renderer) == ["react"]
	sq = subplots(1, 2; sync = false)
	plot_scatter!(sq, x, y; row = 1, col = 1)
	axis_equal!(sq; row = 1, col = 1)
	renderer = _rsp_live!(sq)
	plot_scatter!(sq, x, y; row = 1, col = 2)
	@test _rsp_ops(renderer) == ["react"]
	# Cost guard: an append into a cell that already holds 200 traces costs
	# about as many bytes with per-subplot legends as with one figure legend
	# (measured 942 KB against 697 KB; before Z82 the full staging of every
	# trace made it 3036 KB).
	function append_bytes(per_subplot_legends)
		f = subplots(1, 2; sync = false, per_subplot_legends = per_subplot_legends)
		for k in 1:200
			plot_scatter!(f, x, y .+ k; row = 1, col = 1)
		end
		plot_scatter!(f, x, y; row = 1, col = 1)
		return minimum(k -> @allocated(plot_scatter!(f, x, y .+ k; row = 1, col = 1)), 1:5)
	end
	@test append_bytes(true) < 2 * append_bytes(false)
end

@testset "6x6 heatmap grid: one append stays O(decorations), not O(data) (W5B perf guard)" begin
	# Measured on the merged tree: about 15 MB for the 36th append, of which
	# about 90 % is `_finalize_figure!` (36 cells' rooms and colorbars). The
	# cost must not depend on the size of the matrices.
	cells = [(i, j) for i in 1:6 for j in 1:6]
	append_bytes(n) = begin
		field = [sin(a / 5) * cos(b / 7) for a in 1:n, b in 1:n]
		sf = subplots(6, 6; sync = false)
		for k in 1:35
			plot_heatmap!(sf, field; row = cells[k][1], col = cells[k][2])
		end
		plot_heatmap!(sf, field; row = 6, col = 6)   # compile and warm up
		sf = subplots(6, 6; sync = false)
		for k in 1:35
			plot_heatmap!(sf, field; row = cells[k][1], col = cells[k][2])
		end
		@allocated plot_heatmap!(sf, field; row = 6, col = 6)
	end
	small = append_bytes(20)
	large = append_bytes(200)
	@test small < 40 * 2^20
	@test large < 1.5 * small
end
