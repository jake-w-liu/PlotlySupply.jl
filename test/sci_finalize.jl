using Test, PlotlySupply
using PlotlySupply.PlotlyBase
import PlotlySupply.PlotlyBase.JSON

const _SFN = PlotlySupply

_sfn_fields(value) = value isa PlotlyBase.PlotlyAttribute ? value.fields : value
_sfn_plot(fig) = fig isa SubplotFigure ? fig.plot : fig
_sfn_axis(fig, key) = _sfn_fields(get(_sfn_plot(fig).layout.fields, key, nothing))
_sfn_get(fig, key, name) = _SFN._fin_field(_sfn_axis(fig, key), name)
_sfn_clip(fig, key) = _SFN._fin_sticky_clip(_sfn_axis(fig, key))
_sfn_bar(trace) = _sfn_fields(get(trace.fields, :colorbar, nothing))
_sfn_snapshot(p::Plot) = (JSON.json(p.layout), [JSON.json(t) for t in p.data])
_sfn_z(x, y) = [sin(a) * cos(b) for a in x, b in y]
# A 9 x 5 heatmap on centres 0:0.5:4 x 0:0.5:2: bricks span [-0.25, 4.25] x [-0.25, 2.25].
const _SFN_X = collect(0.0:0.5:4.0)
const _SFN_Y = collect(0.0:0.5:2.0)
const _SFN_XE = (-0.25, 4.25)
const _SFN_YE = (-0.25, 2.25)

# Rendered geometry of a figure in a hidden window at `width` x `height`: per
# Cartesian axis its range and px offset/length, and the px box of every
# colorbar's bar. `nothing` when the renderer cannot start (the checks are
# then skipped).
const _SFN_RENDER_JS = raw"""
(() => {
  const gd = document.getElementById(__DIV__);
  if (!gd || !gd._fullLayout || !gd._fullLayout._size) return null;
  if (gd.querySelectorAll('g.colorbar').length < __BARS__) return null;
  const fl = gd._fullLayout;
  const out = {axes: {}, colorbars: []};
  const root = gd.getBoundingClientRect();
  // Leftmost / rightmost drawn text of a set of text elements (px), or null.
  const extent = (texts, side) => {
    let v = null;
    for (const t of texts) {
      const r = t.getBoundingClientRect();
      if (r.width <= 0) continue;
      const e = side === 'left' ? r.left - root.left : r.right - root.left;
      v = v === null ? e : (side === 'left' ? Math.min(v, e) : Math.max(v, e));
    }
    return v;
  };
  for (const k of Object.keys(fl).filter(k => /^[xy]axis\d*$/.test(k))) {
    const a = fl[k];
    out.axes[k] = {range: a.range.map(Number), offset: a._offset, length: a._length,
      labels_left: extent(gd.querySelectorAll('g.' + k.replace('axis', '') + 'tick text'), 'left')};
  }
  for (const g of gd.querySelectorAll('g.colorbar')) {
    const el = g.querySelector('.cboutline') || g.querySelector('.cbfills') || g.querySelector('rect.cbbg');
    if (!el) continue;
    const r = el.getBoundingClientRect();
    out.colorbars.push({x0: r.left - root.left, x1: r.right - root.left,
      y0: r.top - root.top, y1: r.bottom - root.top,
      labels_right: extent(g.querySelectorAll('text'), 'right')});
  }
  return JSON.stringify(out);
})()
"""

function _sfn_render(fig; width::Int = 700, height::Int = 500, bars::Int = 0)
	p = _sfn_plot(fig)
	q = Plot(deepcopy(p.data), deepcopy(p.layout))
	relayout!(q; width = width, height = height)
	_SFN._finalize_figure!(q)
	sp = try
		to_syncplot(q; show = false)
	catch err
		@warn "sci_finalize: the renderer could not start; renderer checks are skipped" exception = (err, catch_backtrace())
		return nothing
	end
	try
		backend = _SFN._syncplot_backend(sp)
		script = replace(_SFN_RENDER_JS, "__DIV__" => _SFN._json_js(sp.divid), "__BARS__" => string(bars))
		for _ in 1:300
			raw = Base.invokelatest(() -> backend.run(sp.window, script))
			(raw === nothing || raw == "null") || return JSON.parse(String(raw))
			sleep(0.05)
		end
		error("sci_finalize: the figure did not render within 15 s")
	finally
		close(sp)
	end
end

_sfn_range(info, key) = Tuple(Float64.(info["axes"][String(key)]["range"]))

# Plot box (x0, x1, y0, y1) in px of the cell drawn on `xkey`/`ykey`.
function _sfn_box(info, xkey, ykey)
	ax = info["axes"][String(xkey)]
	ay = info["axes"][String(ykey)]
	return (ax["offset"], ax["offset"] + ax["length"], ay["offset"], ay["offset"] + ay["length"])
end

# Equal aspect within 1 px and a bar to the right of the box as tall as the
# box within 2 px.
function _sfn_check_aspect_cell(info, xkey, ykey)
	box = _sfn_box(info, xkey, ykey)
	rx = abs(-(_sfn_range(info, xkey)...))
	ry = abs(-(_sfn_range(info, ykey)...))
	w = box[2] - box[1]
	h = box[4] - box[3]
	@test abs(w - h * rx / ry) <= 1
	right = [bar for bar in info["colorbars"] if bar["x0"] >= box[2] - 1]
	@test !isempty(right)
	isempty(right) && return nothing
	bar = right[argmin([bar["x0"] for bar in right])]
	@test abs((bar["y1"] - bar["y0"]) - h) <= 2
	@test abs(bar["y0"] - box[3]) <= 2
	return nothing
end

@testset "sci_finalize" begin

@testset "match-group roots are found through chains; bad references are ignored" begin
	layout = Layout(
		xaxis = attr(matches = "x3"),
		xaxis3 = attr(matches = "x5"),
		xaxis5 = attr(),
		yaxis = attr(),
		yaxis2 = attr(matches = "y"),
		yaxis4 = attr(matches = "z9"),      # not a Cartesian axis reference
		xaxis7 = attr(matches = "x8"),      # root without a layout entry
		xaxis9 = attr(matches = "x10"),
		xaxis10 = attr(matches = "x9"),     # cycle: no root
	)
	@test PlotlySupply._fin_match_roots(layout) == Set([:xaxis5, :yaxis, :xaxis8])
	@test PlotlySupply._fin_axis_key("x") === :xaxis
	@test PlotlySupply._fin_axis_key(:y12) === :yaxis12
	@test PlotlySupply._fin_axis_key("x1") === nothing
	@test PlotlySupply._fin_axis_key("paper") === nothing
	@test PlotlySupply._fin_axis_key(3) === nothing
end

@testset "roots without range/autorange get autorange=true; explicit settings are kept" begin
	layout = Layout(
		xaxis = attr(matches = "x3"),
		xaxis3 = attr(range = [-12, 126], autorange = false),   # fixed root: untouched
		xaxis2 = attr(matches = "x4"),
		xaxis4 = attr(),                                        # free root
		yaxis = attr(),                                         # free root
		yaxis2 = attr(matches = "y"),
		yaxis3 = attr(autorange = "reversed"),                  # explicit: untouched
		yaxis4 = attr(matches = "y3"),
		yaxis5 = attr(title = "free"),                         # not in a group
	)
	updates = PlotlySupply._fin_match_group_updates(layout)
	@test updates == Dict{Symbol, Any}(:xaxis4_autorange => true, :yaxis_autorange => true)

	p = Plot(GenericTrace[], layout)
	@test PlotlySupply._finalize_figure!(p) === true             # returns whether it wrote
	@test PlotlySupply._finalize_figure!(p) === false
	f(key, name) = PlotlySupply._fin_field(p.layout.fields[key], name)
	@test f(:xaxis4, :autorange) === true
	@test f(:yaxis, :autorange) === true
	@test f(:xaxis3, :autorange) === false
	@test f(:xaxis3, :range) == [-12, 126]
	@test f(:yaxis3, :autorange) == "reversed"
	@test f(:yaxis5, :autorange) === nothing
	@test f(:xaxis, :autorange) === nothing                     # members are left alone
	# idempotent: nothing left to write
	@test isempty(PlotlySupply._fin_match_group_updates(p.layout))
end

@testset "a figure without shared axes is not touched" begin
	p = plot_scatter(1:3, [1, 2, 3])
	before = deepcopy(p.layout.fields)
	PlotlySupply._finalize_figure!(p)
	@test p.layout.fields == before
end

@testset "subplots: every shared-axis group root autoranges explicitly" begin
	sf = subplots(2, 2; sync = false, shared_xaxes = true, shared_yaxes = true)
	fields = sf.plot.layout.fields
	roots = PlotlySupply._fin_match_roots(sf.plot.layout)
	@test !isempty(roots)
	for root in roots
		@test PlotlySupply._fin_field(fields[root], :autorange) === true
	end
	# A range set on one group's root must not remove the others' autorange.
	plot_scatter!(sf, 1:3, [1, 2, 3]; row = 2, col = 1, xrange = (0, 5))
	fields = sf.plot.layout.fields          # the mutation commits a new layout
	fixed = [k for k in roots if PlotlySupply._fin_has_range(fields[k])]
	@test length(fixed) == 1
	for root in setdiff(roots, fixed)
		@test PlotlySupply._fin_field(fields[root], :autorange) === true
	end
	# Unshared grids get no autorange entries.
	plain = subplots(2, 2; sync = false)
	@test all(PlotlySupply._fin_field(axis, :autorange) === nothing
		for (key, axis) in plain.plot.layout.fields if PlotlySupply._fin_is_axis_key(key))
end

@testset "field kinds" begin
	@test _SFN._fin_field_kind(heatmap(z = [1 2; 3 4])) === :tight
	@test _SFN._fin_field_kind(contour(z = [1 2; 3 4])) === :tight
	@test _SFN._fin_field_kind(histogram2d(x = [1, 2], y = [1, 2])) === :tight
	@test _SFN._fin_field_kind(scatter(x = [1], y = [1])) === nothing
	@test _SFN._fin_field_kind(scatter(x = [1], y = [1], meta = _SFN._FIELD_META)) === :tight
	@test _SFN._fin_field_kind(heatmap(z = [1 2; 3 4], meta = _SFN._FIELD_META_LOOSE)) === :loose
	@test _SFN._fin_field_kind(nothing) === nothing
end

@testset "extents follow plotly's bounds" begin
	ext(trace, letter; islog = false) = _SFN._fin_trace_extent(trace, letter, islog)
	z = zeros(2, 3)                                  # 3 x samples, 2 y samples
	@test ext(heatmap(x = [0, 1, 2], y = [0, 10], z = z), 'x') == (-0.5, 2.5)        # centres
	@test ext(heatmap(x = [0, 1, 2], y = [0, 10], z = z), 'y') == (-5.0, 15.0)
	@test ext(heatmap(x = [0, 1, 2, 3], z = z), 'x') == (0.0, 3.0)                     # n + 1 edges
	@test ext(heatmap(x = [0, 1], z = z), 'x') == (-0.5, 2.5)                          # extrapolated
	@test ext(heatmap(x0 = 10, dx = 2, z = z), 'x') == (9.0, 15.0)                     # x0/dx
	@test ext(heatmap(z = z), 'y') == (-0.5, 1.5)
	lo, hi = ext(heatmap(x = [1, 10, 100], z = z), 'x'; islog = true)                  # log space
	@test lo ≈ 10^-0.5 && hi ≈ 10^2.5
	@test ext(heatmap(x0 = 1, dx = 1, z = z), 'x'; islog = true) === :unsupported
	@test ext(heatmap(x = ["a", "b", "c"], z = z), 'x') === :unsupported
	@test ext(contour(x = [0, 1, 2], z = z), 'x') == (0.0, 2.0)                       # nodes
	@test ext(contour(x0 = 1, dx = 0.5, z = z), 'x') == (1.0, 2.0)
	@test ext(scatter(x = [3.0, NaN, -1.0], y = [1, 2, 3]), 'x') == (-1.0, 3.0)
	@test ext(scatter(y = [2.0, 5.0], fill = "tozeroy"), 'y') == (0.0, 5.0)
	@test ext(scatter(y = [2.0, 5.0]), 'x') == (0.0, 1.0)                              # implicit x
	@test ext(scatter(x = [-1.0, 10.0], y = [1, 1]), 'x'; islog = true) == (10.0, 10.0)
	@test ext(scatter(x = [1.0], y = [1.0], error_y = attr(array = [0.5])), 'y') === :unsupported
	@test ext(histogram2d(x = [1, 2], y = [1, 2]), 'x') === :unsupported
	# Data-referenced shapes and annotations count; others do not.
	layout = Layout(
		shapes = [attr(type = "rect", x0 = -2, x1 = 1, y0 = 0, y1 = 1)],
		annotations = [attr(x = 7, y = 1, text = "a"), attr(x = 0.5, y = 0.5, xref = "paper", yref = "paper", text = "b")],
	)
	@test _SFN._fin_layout_item_extent(layout, "x", 'x', false) == (-2.0, 7.0)
	@test _SFN._fin_layout_item_extent(layout, "x", 'x', true) === :unsupported
	@test _SFN._fin_layout_item_extent(Layout(shapes = [attr(type = "path", path = "M0,0")]), "x", 'x', false) === :unsupported
end

@testset "sticky clip: written once, follows the data, removed when no longer sticky" begin
	p = Plot([heatmap(x = _SFN_X, y = _SFN_Y, z = _sfn_z(_SFN_Y, _SFN_X))], Layout())
	@test _SFN._finalize_figure!(p) === true
	@test _sfn_clip(p, :xaxis) == _SFN_XE
	@test _sfn_clip(p, :yaxis) == _SFN_YE
	@test _sfn_get(p, :xaxis, :range) === nothing           # autorange stays plotly's
	@test _sfn_get(p, :xaxis, :autorange) === nothing
	@test _SFN._finalize_figure!(p) === false                # idempotent: no writes
	# Markers inside the field change nothing.
	push!(p.data, scatter(x = [1.0, 2.0], y = [1.0, 1.5], mode = "markers"))
	@test _SFN._finalize_figure!(p) === false
	# Data outside the field: the clip grows to it exactly, without padding.
	push!(p.data, scatter(x = [5.5], y = [-1.0], mode = "markers"))
	@test _SFN._finalize_figure!(p) === true
	@test _sfn_clip(p, :xaxis) == (-0.25, 5.5)
	@test _sfn_clip(p, :yaxis) == (-1.0, 2.25)
	pop!(p.data)
	_SFN._finalize_figure!(p)
	@test _sfn_clip(p, :xaxis) == _SFN_XE
	# Hidden traces take no part.
	push!(p.data, scatter(x = [9.0], y = [9.0], visible = "legendonly"))
	@test _SFN._finalize_figure!(p) === false
	# Something whose extent is not computed here (error bars) turns it off.
	push!(p.data, scatter(x = [1.0], y = [1.0], error_y = attr(array = [0.5])))
	@test _SFN._finalize_figure!(p) === true
	@test _sfn_get(p, :yaxis, :autorangeoptions) === nothing
	@test _sfn_clip(p, :xaxis) == _SFN_XE                    # x is still exact
	# Scatter alone: no field, no clip.
	q = Plot([scatter(x = [1.0, 2.0], y = [1.0, 2.0])], Layout())
	@test _SFN._finalize_figure!(q) === false
	# A loose field (`tight = false`) keeps the padded autorange of both axes.
	loose = Plot([
		heatmap(x = _SFN_X, y = _SFN_Y, z = _sfn_z(_SFN_Y, _SFN_X)),
		heatmap(x = _SFN_X, y = _SFN_Y, z = _sfn_z(_SFN_Y, _SFN_X), meta = _SFN._FIELD_META_LOOSE),
	], Layout())
	_SFN._finalize_figure!(loose)
	@test _sfn_clip(loose, :xaxis) === nothing && _sfn_clip(loose, :yaxis) === nothing
end

@testset "sticky clip: log, reversed and shared axes" begin
	p = Plot([heatmap(x = [1, 10, 100], y = [0, 1], z = zeros(2, 3))], Layout(xaxis = attr(type = "log")))
	_SFN._finalize_figure!(p)
	lo, hi = _sfn_clip(p, :xaxis)
	@test lo ≈ 10^-0.5 && hi ≈ 10^2.5                       # data units on a log axis
	upper = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); origin = :upper)
	_SFN._finalize_figure!(upper)
	@test _sfn_get(upper, :yaxis, :autorange) == "reversed"
	@test _sfn_clip(upper, :yaxis) == _SFN_YE
	sf = subplots(1, 2; sync = false, shared_yaxes = true)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); row = 1, col = 1)
	plot_heatmap!(sf, _SFN_X, 2 .* _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); row = 1, col = 2)
	@test _sfn_clip(sf, :yaxis) == (-0.5, 4.5)              # union over the group
	@test _sfn_clip(sf, :yaxis2) == (-0.5, 4.5)
	@test _sfn_clip(sf, :xaxis) == _SFN_XE
	@test _SFN._finalize_figure!(sf) === false
end

@testset "user settings are never changed" begin
	f = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y))
	_SFN._finalize_figure!(f)
	xrange!(f, (1, 2))
	@test _sfn_get(f, :xaxis, :range) == [1, 2]
	@test _sfn_get(f, :xaxis, :autorange) === false
	@test _SFN._finalize_figure!(f) === false
	xrange!(f, nothing)                                     # the sticky range is back
	@test _sfn_get(f, :xaxis, :range) === nothing
	@test _sfn_get(f, :xaxis, :autorange) in (true, nothing)
	@test _sfn_clip(f, :xaxis) == _SFN_XE
	# User autorangeoptions are kept, the other axis still gets its clip.
	own = Plot([heatmap(x = _SFN_X, y = _SFN_Y, z = _sfn_z(_SFN_Y, _SFN_X))],
		Layout(xaxis = attr(autorangeoptions = attr(clipmin = 1))))
	_SFN._finalize_figure!(own)
	@test _sfn_fields(_sfn_get(own, :xaxis, :autorangeoptions)) == Dict(:clipmin => 1)
	@test _sfn_clip(own, :yaxis) == _SFN_YE
	# A range set with autorange = false is never touched, even when it
	# equals nothing finalize would write.
	fixed = Plot([heatmap(x = _SFN_X, y = _SFN_Y, z = _sfn_z(_SFN_Y, _SFN_X))],
		Layout(xaxis = attr(range = [0, 1], autorange = false)))
	_SFN._finalize_figure!(fixed)
	@test _sfn_get(fixed, :xaxis, :range) == [0, 1]
	@test _sfn_clip(fixed, :xaxis) === nothing
end

@testset "equal aspect: pinned ranges, fitted cell, hugging bar" begin
	g = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); equalar = true)
	@test _SFN._finalize_figure!(g) === true
	# The clip does not survive plotly's aspect constraint (probe p7), so the
	# range is pinned to it.
	@test _sfn_get(g, :xaxis, :autorange) === false
	@test _sfn_get(g, :xaxis, :range) == collect(_SFN_XE)
	@test _sfn_get(g, :yaxis, :range) == collect(_SFN_YE)
	@test _sfn_clip(g, :xaxis) == _SFN_XE
	# M3a: no size given, a wide field keeps the default width and gets a
	# derived height within the documented bounds.
	W = g.layout.fields[:width]
	H = g.layout.fields[:height]
	@test W == 700
	@test _SFN._FIN_MIN_FIGURE_HEIGHT <= H < 500
	xd = _sfn_get(g, :xaxis, :domain)
	yd = _sfn_get(g, :yaxis, :domain)
	@test 0 <= xd[1] < xd[2] <= 1 && 0 <= yd[1] < yd[2] <= 1
	@test _sfn_get(g, :xaxis, :constraintoward) == "right"
	bar = _sfn_bar(g.data[1])
	@test bar[:x] ≈ xd[2] + _SFN._FIN_CBAR_PAD
	@test bar[:len] ≈ yd[2] - yd[1]
	@test bar[:y] ≈ (yd[1] + yd[2]) / 2
	@test bar[:ypad] == 0 && bar[:xanchor] == "left" && bar[:xref] == "paper"
	@test _SFN._finalize_figure!(g) === false
	# Dropping the constraint unpins the range; the clip stays.
	relayout!(g; yaxis_scaleanchor = nothing)
	_SFN._finalize_figure!(g)
	@test _sfn_get(g, :xaxis, :range) === nothing
	@test _sfn_get(g, :xaxis, :autorange) === true
	@test _sfn_clip(g, :xaxis) == _SFN_XE
	# A tall field keeps the default height and derives the width.
	ty = collect(0.0:0.5:10.0)
	tall = plot_heatmap(_SFN_X, ty, _sfn_z(_SFN_X, ty); equalar = true)
	_SFN._finalize_figure!(tall)
	@test tall.layout.fields[:height] == 500
	@test _SFN._FIN_MIN_FIGURE_WIDTH <= tall.layout.fields[:width] < 700
	# An explicit size is never changed: the cell is fitted inside it.
	sized = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); equalar = true)
	relayout!(sized; width = 900, height = 600)
	_SFN._finalize_figure!(sized)
	@test (sized.layout.fields[:width], sized.layout.fields[:height]) == (900, 600)
	@test _sfn_get(sized, :yaxis, :domain)[2] - _sfn_get(sized, :yaxis, :domain)[1] < 1
	# Subplot cells stay inside their grid cell.
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); row = 1, col = 1, equalar = true)
	plot_heatmap!(sf, _SFN_X, ty, _sfn_z(_SFN_X, ty); row = 1, col = 2, equalar = true)
	grid = _SFN._plotlysupply_subplot_layout(sf.plot.layout.subplots)
	for (xkey, ykey, index) in ((:xaxis, :yaxis, 1), (:xaxis2, :yaxis2, 2))
		ref_x = _SFN._layout_axis_domain(grid, xkey)
		ref_y = _SFN._layout_axis_domain(grid, ykey)
		xd = _sfn_get(sf, xkey, :domain)
		yd = _sfn_get(sf, ykey, :domain)
		@test ref_x[1] - 1e-9 <= xd[1] && xd[2] <= ref_x[2] + 1e-9
		@test ref_y[1] - 1e-9 <= yd[1] && yd[2] <= ref_y[2] + 1e-9
		@test _sfn_bar(sf.plot.data[index])[:x] ≈ xd[2] + _SFN._FIN_CBAR_PAD
	end
	@test _SFN._finalize_figure!(sf) === false
	@test _SFN._fin_needs_full_staging(sf)
	@test !_SFN._fin_needs_full_staging(plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y)))
end

@testset "live traces are not written (append-only fast path)" begin
	g = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); equalar = true)
	before = JSON.json(g.data[1])
	@test _SFN._finalize_figure!(g; live = g.data) isa Bool
	@test JSON.json(g.data[1]) == before
	@test _sfn_get(g, :xaxis, :domain) === nothing          # the cell is left for a full pass
	@test_throws ArgumentError _SFN._finalize_figure!(g; size = (0, 100))
	@test_throws ArgumentError _SFN._finalize_figure!(g; size = (100,))
end

@testset "export copy: fitted for the export size, the figure is not changed" begin
	g = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); equalar = true)
	before = _sfn_snapshot(g)
	c = _SFN._finalize_export_copy(g, (width = 800, height = 400))
	@test c !== g
	@test _sfn_snapshot(g) == before
	@test c.data[1] !== g.data[1]                           # written trace is a clone
	@test !haskey(c.layout.fields, :width)                  # export size is not stored
	@test _sfn_get(c, :xaxis, :domain) !== nothing
	@test _sfn_bar(c.data[1])[:xref] == "paper"
	plain = plot_scatter([1.0, 2.0], [1.0, 2.0])
	@test _SFN._finalize_export_copy(plain, (width = 700, height = 500)) === plain
end

@testset "colorbars on one plot area do not overlap (M4, X39)" begin
	z = _sfn_z(_SFN_X, _SFN_Y)
	# Single figure: the second bar goes to the right of the first.
	f = plot_heatmap(_SFN_X, _SFN_Y, z)
	plot_contour!(f, _SFN_X, _SFN_Y, 2 .* z)
	_SFN._finalize_figure!(f)
	first_bar = _sfn_bar(f.data[1])
	second = _sfn_bar(f.data[2])
	@test first_bar === nothing || get(first_bar, :x, nothing) === nothing
	@test second[:x] > 1.02 && second[:xanchor] == "left"
	@test _SFN._finalize_figure!(f) === false
	# A bar placed by the user stays.
	g = Plot([heatmap(x = _SFN_X, y = _SFN_Y, z = permutedims(z)),
		contour(x = _SFN_X, y = _SFN_Y, z = permutedims(2 .* z), colorbar = attr(x = 0.3))], Layout())
	_SFN._finalize_figure!(g)
	@test _sfn_bar(g.data[2])[:x] == 0.3
	# colorbar! with an explicit position releases a bar finalize placed.
	e = plot_heatmap(_SFN_X, _SFN_Y, z; equalar = true)
	_SFN._finalize_figure!(e)
	@test _sfn_bar(e.data[1])[:xref] == "paper"
	colorbar!(e; x = 1.2)
	@test _sfn_bar(e.data[1])[:x] == 1.2
	@test !haskey(_sfn_bar(e.data[1]), :xref)
	@test _SFN._finalize_figure!(e) === false
	# A cell with a plot area to its right: the bars share the cell's
	# height in one column instead of running into the next cell.
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, z; row = 1, col = 1)
	plot_contour!(sf, _SFN_X, _SFN_Y, 2 .* z; row = 1, col = 1)
	plot_scatter!(sf, _SFN_X, sin.(_SFN_X); row = 1, col = 2)
	a = _sfn_bar(sf.plot.data[1])
	b = _sfn_bar(sf.plot.data[2])
	yd = _SFN._cmn_y_axis_domain(sf.plot.layout, :yaxis)
	@test a[:x] ≈ b[:x]
	@test a[:y] > b[:y]
	@test a[:len] + b[:len] < yd[2] - yd[1]
	@test a[:y] + a[:len] / 2 ≈ yd[2]
	@test isapprox(b[:y] - b[:len] / 2, yd[1]; atol = 1e-9)
	@test _SFN._finalize_figure!(sf) === false
	# The last column keeps them side by side (the margin grows for them).
	last = subplots(1, 2; sync = false)
	plot_scatter!(last, _SFN_X, sin.(_SFN_X); row = 1, col = 1)
	plot_heatmap!(last, _SFN_X, _SFN_Y, z; row = 1, col = 2)
	plot_contour!(last, _SFN_X, _SFN_Y, 2 .* z; row = 1, col = 2)
	@test _sfn_bar(last.plot.data[3])[:x] > _sfn_bar(last.plot.data[2])[:x]
	# The bar of a trace in an inset goes right of the host cell, level with
	# the inset, never over the host plot.
	si = subplots(1, 1; sync = false)
	plot_scatter!(si, _SFN_X, sin.(_SFN_X))
	k = inset!(si, (0.55, 0.55, 0.4, 0.4))
	plot_heatmap!(si, _SFN_X, _SFN_Y, z; inset = k)
	inset_bar = _sfn_bar(si.plot.data[2])
	host = _SFN._layout_axis_domain(si.plot.layout, :xaxis)
	@test inset_bar[:x] >= something(host, (0.0, 1.0))[2]
	@test _SFN._finalize_figure!(si) === false
end

@testset "an inner cell gives up the width its bar needs before the next cell (X33, X39)" begin
	z = _sfn_z(_SFN_X, _SFN_Y)
	# Wide tick labels (-8000 ...) do not fit in the default gap of a 1x3 grid.
	sf = subplots(2, 3; sync = false)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, 1e4 .* z; row = 1, col = 1)
	plot_scatter!(sf, _SFN_X, sin.(_SFN_X); row = 1, col = 2)
	plot_scatter!(sf, _SFN_X, cos.(_SFN_X); row = 2, col = 1)
	layout = sf.plot.layout
	grid = _SFN._plotlysupply_subplot_layout(layout.subplots)
	cell = _SFN._layout_axis_domain(grid, :xaxis)
	xd = _SFN._layout_axis_domain(layout, :xaxis)
	@test xd[1] == cell[1] && xd[2] < cell[2]
	# The cell below stays aligned; the other columns keep their cells.
	@test collect(_SFN._layout_axis_domain(layout, :xaxis4)) ≈ collect(xd)
	@test collect(_SFN._layout_axis_domain(layout, :xaxis2)) ≈ collect(_SFN._layout_axis_domain(grid, :xaxis2))
	bar = _sfn_bar(sf.plot.data[1])
	@test bar[:x] ≈ xd[2] + _SFN._CBAR_CELL_PAD
	@test bar[:xref] == "paper"
	# The bar group ends before the tick labels of the next cell.
	W, H = 700.0, 500.0
	accs = _SFN._fin_collect_axes(sf.plot)
	m = _SFN._fin_margins(layout, accs, W, H, Dict{Symbol, NTuple{2, Float64}}(), Any[])
	Wp, Hp = W - m.l - m.r, H - m.t - m.b
	neighbour = _SFN._fin_right_neighbour(layout, accs, xd, _SFN._layout_axis_domain(layout, :yaxis), Hp)
	@test neighbour.x ≈ _SFN._layout_axis_domain(layout, :xaxis2)[1]
	@test neighbour.push > 20
	items, _, _ = _SFN._fin_collect_bars(sf.plot, Any[])
	width = _SFN._fin_bar_width(layout, items["x"][1], Hp)
	@test (bar[:x] - xd[2]) * Wp + width <= (neighbour.x - xd[2]) * Wp - neighbour.push + 1e-6
	@test _SFN._finalize_figure!(sf) === false
	# The export copy is fitted again for the export size.
	for (w, wider) in ((500, false), (1400, true))
		copy = deepcopy(sf.plot)
		_SFN._finalize_figure!(copy; size = (w, 400))
		edge = _SFN._layout_axis_domain(copy.layout, :xaxis)[2]
		@test (edge > xd[2]) == wider
		@test _sfn_bar(copy.data[1])[:x] ≈ edge + _SFN._CBAR_CELL_PAD
	end
	@test _SFN._layout_axis_domain(sf.plot.layout, :xaxis)[2] == xd[2]
	# A domain the user set is kept; the bar follows it without our mark, and
	# later runs leave both alone.
	relayout!(sf; xaxis_domain = [0.0, 0.2], xaxis4_domain = [0.0, 0.2])
	_SFN._finalize_figure!(sf)
	@test collect(_SFN._layout_axis_domain(sf.plot.layout, :xaxis)) == [0.0, 0.2]
	@test collect(_SFN._layout_axis_domain(sf.plot.layout, :xaxis4)) == [0.0, 0.2]
	bar = _sfn_bar(sf.plot.data[1])
	@test bar[:x] ≈ 0.2 + _SFN._CBAR_CELL_PAD
	@test !haskey(bar, :xref)
	@test _SFN._finalize_figure!(sf) === false
	copy = deepcopy(sf.plot)
	_SFN._finalize_figure!(copy; size = (500, 400))
	@test collect(_SFN._layout_axis_domain(copy.layout, :xaxis)) == [0.0, 0.2]
	# A cell hosting an inset is not narrowed (the inset would stick out).
	si = subplots(1, 2; sync = false)
	plot_scatter!(si, _SFN_X, sin.(_SFN_X); row = 1, col = 1)
	plot_scatter!(si, _SFN_X, cos.(_SFN_X); row = 1, col = 2)
	k = inset!(si, (0.55, 0.55, 0.4, 0.4); row = 1, col = 1)
	plot_heatmap!(si, _SFN_X, _SFN_Y, 1e4 .* z; inset = k)
	grid = _SFN._plotlysupply_subplot_layout(si.plot.layout.subplots)
	@test _SFN._layout_axis_domain(si.plot.layout, :xaxis)[2] ≈ _SFN._layout_axis_domain(grid, :xaxis)[2]
	@test _SFN._finalize_figure!(si) === false
	# The panel title follows the cell; when the cell's bar goes (here to a
	# shared colour axis) the cell widens again.
	st = subplots(1, 2; sync = false)
	title!(st, "left"; row = 1, col = 1)
	plot_heatmap!(st, _SFN_X, _SFN_Y, 1e4 .* z; row = 1, col = 1)
	plot_heatmap!(st, _SFN_X, _SFN_Y, z; row = 1, col = 2)
	cell = _SFN._layout_axis_domain(_SFN._plotlysupply_subplot_layout(st.plot.layout.subplots), :xaxis)
	title_x() = only(a for a in st.plot.layout.fields[:annotations] if a[:name] == "plotlysupply:title:1:1")[:x]
	xd = _SFN._layout_axis_domain(st.plot.layout, :xaxis)
	@test xd[2] < cell[2]
	@test title_x() ≈ (xd[1] + xd[2]) / 2
	shared_colorbar!(st; cells = [(1, 1), (1, 2)])
	xd = _SFN._layout_axis_domain(st.plot.layout, :xaxis)
	@test xd[2] ≈ cell[2]
	@test title_x() ≈ (cell[1] + cell[2]) / 2
	@test _SFN._finalize_figure!(st) === false
end

@testset "a shared scene coloraxis spreading to existing surfaces moves its bar (K11)" begin
	sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene")])
	plot_surface!(sf, rand(3, 3); row = 1, col = 1)
	plot_surface!(sf, 5 .+ rand(3, 3); row = 1, col = 2, shared_coloraxis = true)
	bar = _sfn_fields(_sfn_fields(sf.plot.layout.fields[:coloraxis])[:colorbar])
	@test bar[:x] ≈ 1.0 + _SFN._CBAR_SHARED_PAD
	@test _SFN._finalize_figure!(sf) === false
	# Without traces rebound by the mutation the bar is left where it is.
	colorbar!(sf; row = 1, col = 1, coloraxis = :shared)
	bar = _sfn_fields(_sfn_fields(sf.plot.layout.fields[:coloraxis])[:colorbar])
	@test bar[:x] ≈ _sfn_get(sf, :scene, :domain)[:x][2] + _SFN._CBAR_CELL_PAD
end

@testset "a math title beside the bar gets room in the right margin" begin
	f = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y))
	colorbar!(f; title = raw"$|E|^2$", title_side = :right)
	margin_r = _sfn_fields(f.layout.fields[:margin])[:r]
	@test margin_r > 50
	notes = [_sfn_fields(a) for a in f.layout.fields[:annotations]]
	@test any(a -> endswith(string(get(a, :name, "")), ":right"), notes)
	@test _SFN._finalize_figure!(f) === false
	# On an equal-aspect figure the title is fitted inside the margin.
	g = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); equalar = true)
	colorbar!(g; title = raw"$|E|^2$", title_side = :right)
	@test _SFN._finalize_figure!(g) === false
end

@testset "a failing finalizer rolls the mutation back" begin
	# A non-numeric axis domain makes the margin estimate throw.
	p = Plot([scatter(x = [1.0, 2.0], y = [1.0, 2.0])],
		Layout(xaxis = attr(domain = ["a", "b"]), yaxis = attr(automargin = true)))
	before = _sfn_snapshot(p)
	trace = try
		plot_scatter!(p, [1.0, 2.0], [3.0, 4.0])
		nothing
	catch
		stacktrace(catch_backtrace())
	end
	@test trace !== nothing
	@test trace !== nothing && any(frame -> frame.func in (:_fin_run!, :_finalize_figure!, :_fin_fit!), trace)
	@test _sfn_snapshot(p) == before
end

@testset "renderer: sticky ranges and equal aspect (hidden window)" begin
	z = _sfn_z(_SFN_X, _SFN_Y)
	close_to(a, b) = isapprox(a[1], b[1]; atol = 1e-6) && isapprox(a[2], b[2]; atol = 1e-6)
	f = plot_heatmap(_SFN_X, _SFN_Y, z)
	info = _sfn_render(f; bars = 1)
	if info === nothing
		@test_skip "renderer unavailable"
	else
		@test close_to(_sfn_range(info, :xaxis), _SFN_XE)
		@test close_to(_sfn_range(info, :yaxis), _SFN_YE)
		# Overlays inside the field keep the field edges.
		over = plot_heatmap(_SFN_X, _SFN_Y, z)
		plot_scatter!(over, [1.0, 2.0, 3.0], [0.5, 1.0, 1.5]; mode = "markers")
		plot_quiver!(over, [1.0, 2.0], [1.0, 1.0], [0.2, 0.2], [0.1, 0.1])
		plot_streamlines!(over, _SFN_X, _SFN_Y, [1.0 + 0 * a for a in _SFN_X, b in _SFN_Y],
			[0.1 * sin(a) for a in _SFN_X, b in _SFN_Y])
		plot_contour!(over, _SFN_X, _SFN_Y, z; coloring = "lines")
		info = _sfn_render(over)
		@test close_to(_sfn_range(info, :xaxis), _SFN_XE)
		@test close_to(_sfn_range(info, :yaxis), _SFN_YE)
		# Data outside the field: the range grows to it without padding.
		out = plot_heatmap(_SFN_X, _SFN_Y, z)
		plot_scatter!(out, [5.5], [-1.0]; mode = "markers")
		info = _sfn_render(out)
		@test close_to(_sfn_range(info, :xaxis), (-0.25, 5.5))
		@test close_to(_sfn_range(info, :yaxis), (-1.0, 2.25))
		# origin = :upper: reversed, still exact.
		info = _sfn_render(plot_heatmap(_SFN_X, _SFN_Y, z; origin = :upper))
		@test close_to(_sfn_range(info, :yaxis), (2.25, -0.25))
		# An explicit range wins; xrange!(fig, nothing) brings the edges back.
		user = plot_heatmap(_SFN_X, _SFN_Y, z)
		xrange!(user, (1, 2))
		@test close_to(_sfn_range(_sfn_render(user), :xaxis), (1.0, 2.0))
		xrange!(user, nothing)
		@test close_to(_sfn_range(_sfn_render(user), :xaxis), _SFN_XE)
		# M1: a fixed range on one shared group leaves the others autoranging.
		grid = subplots(2, 2; sync = false, shared_xaxes = true, shared_yaxes = true)
		plot_scatter!(grid, [10.0, 20.0], [1.0, 2.0]; row = 1, col = 2)
		plot_scatter!(grid, [1.0, 2.0, 3.0], [1.0, 2.0, 3.0]; row = 2, col = 1, xrange = (0, 5))
		info = _sfn_render(grid)
		x2 = _sfn_range(info, :xaxis2)
		@test x2[1] <= 10 && x2[2] >= 20
		@test close_to(_sfn_range(info, :xaxis3), (0.0, 5.0))
		# Equal aspect: single figure, 1x2 and 2x2 grids.
		ty = collect(0.0:0.5:10.0)
		single = plot_heatmap(_SFN_X, _SFN_Y, z; equalar = true)
		info = _sfn_render(single; bars = 1)
		_sfn_check_aspect_cell(info, :xaxis, :yaxis)
		@test close_to(_sfn_range(info, :xaxis), _SFN_XE)
		pair = subplots(1, 2; sync = false)
		plot_heatmap!(pair, _SFN_X, _SFN_Y, z; row = 1, col = 1, equalar = true)
		plot_heatmap!(pair, _SFN_X, ty, _sfn_z(_SFN_X, ty); row = 1, col = 2, equalar = true)
		info = _sfn_render(pair; width = 900, height = 450, bars = 2)
		_sfn_check_aspect_cell(info, :xaxis, :yaxis)
		_sfn_check_aspect_cell(info, :xaxis2, :yaxis2)
		quad = subplots(2, 2; sync = false)
		for (r, c, yy) in ((1, 1, _SFN_Y), (1, 2, ty), (2, 1, _SFN_X), (2, 2, collect(0.0:0.5:3.0)))
			plot_heatmap!(quad, _SFN_X, yy, _sfn_z(_SFN_X, yy); row = r, col = c, equalar = true)
		end
		info = _sfn_render(quad; width = 900, height = 700, bars = 4)
		for (xkey, ykey) in ((:xaxis, :yaxis), (:xaxis2, :yaxis2), (:xaxis3, :yaxis3), (:xaxis4, :yaxis4))
			_sfn_check_aspect_cell(info, xkey, ykey)
		end
		# X33/X39: the bars of inner cells (wide tick labels, two bars in one
		# cell) end before the tick labels of the next cell.
		row = subplots(1, 3; sync = false)
		plot_heatmap!(row, _SFN_X, _SFN_Y, 1e4 .* z; row = 1, col = 1)
		plot_heatmap!(row, _SFN_X, _SFN_Y, z; row = 1, col = 2)
		plot_contour!(row, _SFN_X, _SFN_Y, 2 .* z; row = 1, col = 2)
		plot_scatter!(row, _SFN_X, sin.(_SFN_X); row = 1, col = 3)
		info = _sfn_render(row; width = 900, height = 400, bars = 3)
		bars = sort(info["colorbars"]; by = b -> (b["x0"], b["y0"]))
		@test length(bars) == 3
		for (i, next) in ((1, "yaxis2"), (2, "yaxis3"), (3, "yaxis3"))
			@test bars[i]["labels_right"] < info["axes"][next]["labels_left"]
		end
		# The two bars of the middle cell do not overlap.
		@test bars[2]["labels_right"] < bars[3]["x0"] || bars[2]["y1"] < bars[3]["y0"] || bars[3]["y1"] < bars[2]["y0"]
	end
end

end
