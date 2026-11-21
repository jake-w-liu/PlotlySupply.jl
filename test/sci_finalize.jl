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
  // Outermost drawn edge (px) of a set of elements on `side`, or null.
  const extent = (elements, side) => {
    let v = null;
    for (const t of elements) {
      const r = t.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      const e = side === 'left' ? r.left - root.left : side === 'right' ? r.right - root.left :
        side === 'top' ? r.top - root.top : r.bottom - root.top;
      v = v === null ? e : ((side === 'left' || side === 'top') ? Math.min(v, e) : Math.max(v, e));
    }
    return v;
  };
  for (const k of Object.keys(fl).filter(k => /^[xy]axis\d*$/.test(k))) {
    const a = fl[k];
    const id = k.replace('axis', '');
    // Tick labels and the axis title.
    const labels = [...gd.querySelectorAll('g.' + id + 'tick text'), ...gd.querySelectorAll('.g-' + id + 'title text')];
    out.axes[k] = {range: a.range.map(Number), offset: a._offset, length: a._length,
      labels_left: extent(labels, 'left'), labels_bottom: extent(labels, 'bottom'),
      labels_right: extent(labels, 'right')};
  }
  out.annotations = [...gd.querySelectorAll('g.annotation')].map(g => {
    const parts = g.querySelectorAll('text, g.math-group');
    return {text: g.textContent, box: [extent(parts, 'left'), extent(parts, 'top'), extent(parts, 'right'), extent(parts, 'bottom')]};
  });
  for (const g of gd.querySelectorAll('g.colorbar')) {
    const el = g.querySelector('.cboutline') || g.querySelector('.cbfills') || g.querySelector('rect.cbbg');
    if (!el) continue;
    const r = el.getBoundingClientRect();
    const drawn = [el, ...g.querySelectorAll('text')];
    out.colorbars.push({x0: r.left - root.left, x1: r.right - root.left,
      y0: r.top - root.top, y1: r.bottom - root.top,
      labels_right: extent(g.querySelectorAll('text'), 'right'),
      top: extent(drawn, 'top'), bottom: extent(drawn, 'bottom')});
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
		xaxis4 = attr(showgrid = true),                         # free root
		yaxis = attr(showgrid = true),                          # free root
		yaxis2 = attr(matches = "y"),
		yaxis3 = attr(autorange = "reversed"),                  # explicit: untouched
		yaxis4 = attr(matches = "y3"),
		yaxis5 = attr(title = "free"),                         # not in a group
	)
	updates = PlotlySupply._fin_match_group_updates(layout)
	@test updates == Dict{Symbol, Any}(:xaxis4_autorange => true, :yaxis_autorange => true)
	# Y37: plotly.js 2.35 carries an "explicit range seen" flag from one match
	# group to the next, so a root with a range but no `autorange` gets an
	# explicit `autorange = false` (and keeps its range).
	ranged = Layout(xaxis = attr(range = [0, 3]), xaxis2 = attr(matches = "x"),
		yaxis = attr(showgrid = true), yaxis2 = attr(matches = "y"))
	@test PlotlySupply._fin_match_group_updates(ranged) ==
		Dict{Symbol, Any}(:xaxis_autorange => false, :yaxis_autorange => true)
	# A root that neither the layout nor a trace has is not created (plotly.js
	# ignores the reference); one a trace references exists.
	unknown = Layout(xaxis = attr(matches = "x7"))
	@test isempty(PlotlySupply._fin_match_group_updates(unknown, [scatter(x = [1.0], y = [1.0])]))
	@test PlotlySupply._fin_match_group_updates(unknown, [scatter(x = [1.0], y = [1.0], xaxis = "x7")]) ==
		Dict{Symbol, Any}(:xaxis7_autorange => true)
	m = plot_scatter([1.0, 2.0], [1.0, 2.0])
	relayout!(m; xaxis_matches = "x7")
	PlotlySupply._finalize_figure!(m)
	@test !haskey(m.layout.fields, :xaxis7)

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

@testset "the extent scan copies no coordinates (K8)" begin
	n = 1_000_000
	p = plot_heatmap(reshape(1:n, n, 1))
	_SFN._finalize_figure!(p)
	GC.gc()
	@test @allocated(_SFN._finalize_figure!(p)) < 200_000
	# Explicit coordinates: every entry is still checked, none is copied.
	x = collect(Float64, 0:(n - 1))
	t = heatmap(x = x, z = reshape(collect(1.0:n), 1, n))
	@test _SFN._fin_trace_extent(t, 'x', false) == (-0.5, n - 0.5)
	@test @allocated(_SFN._fin_trace_extent(t, 'x', false)) < 10_000
	x[n ÷ 2] = NaN
	@test _SFN._fin_trace_extent(t, 'x', false) === :unsupported
	@test _SFN._fin_trace_extent(heatmap(x = [1.0, 0.0, 10.0], z = [1 2 3]), 'x', true) === :unsupported
	@test all(_SFN._fin_trace_extent(heatmap(x = [1.0, 10.0, 100.0], z = [1 2 3]), 'x', true) .≈
		(10^-0.5, 10^2.5))
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
	# Data outside the field: the clip grows to it, padded by
	# `_FIN_OVERLAY_PAD` of the span on that side only (markers and arrow
	# tips are not cut at the frame, hm_06); the field edges stay exact.
	push!(p.data, scatter(x = [5.5], y = [-1.0], mode = "markers"))
	@test _SFN._finalize_figure!(p) === true
	pad = _SFN._FIN_OVERLAY_PAD
	@test all(_sfn_clip(p, :xaxis) .≈ (-0.25, 5.5 + pad * 5.75))
	@test all(_sfn_clip(p, :yaxis) .≈ (-1.0 - pad * 3.25, 2.25))
	@test _SFN._finalize_figure!(p) === false                # idempotent with the pad
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
	# The constructor finalized the figure already (D10): nothing is left.
	@test _SFN._finalize_figure!(g) === false
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
	# A trace with its own bar takes the full path too (fields-07: the bar
	# moves when the plot areas give up room); a plain figure does not.
	@test _SFN._fin_needs_full_staging(plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y)))
	@test !_SFN._fin_needs_full_staging(plot_scatter(1:3, [1.0, 2.0, 3.0]))
end

# An equal-aspect heatmap figure that was never finalized (constructors
# finalize, so it is built from PlotlyBase parts).
_sfn_raw_equal() = Plot([heatmap(x = _SFN_X, y = _SFN_Y, z = _sfn_z(_SFN_Y, _SFN_X))],
	Layout(yaxis = attr(scaleanchor = "x", constrain = "domain"), xaxis = attr(constrain = "domain")))

@testset "live traces are not written (append-only fast path)" begin
	g = _sfn_raw_equal()
	before = JSON.json(g.data[1])
	@test _SFN._finalize_figure!(g; live = g.data) === true  # the layout is written
	@test JSON.json(g.data[1]) == before
	@test _sfn_get(g, :xaxis, :domain) === nothing          # the cell is left for a full pass
	@test _sfn_clip(g, :xaxis) == _SFN_XE
	@test_throws ArgumentError _SFN._finalize_figure!(g; size = (0, 100))
	@test_throws ArgumentError _SFN._finalize_figure!(g; size = (100,))
end

@testset "export copy: fitted for the export size, the figure is not changed" begin
	g = _sfn_raw_equal()
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

@testset "D12: colorbars of one plot area sit side by side in their room (M4, X39)" begin
	z = _sfn_z(_SFN_X, _SFN_Y)
	# Single figure: a lone bar keeps plotly's default place (nothing written).
	lone = plot_heatmap(_SFN_X, _SFN_Y, z)
	@test _sfn_bar(lone.data[1]) === nothing || get(_sfn_bar(lone.data[1]), :x, nothing) === nothing
	# Two bars go side by side right of the plot area, each in its own slot.
	f = plot_heatmap(_SFN_X, _SFN_Y, z)
	plot_contour!(f, _SFN_X, _SFN_Y, 2 .* z)
	a = _sfn_bar(f.data[1])
	b = _sfn_bar(f.data[2])
	@test a[:x] ≈ 1 + _SFN._CBAR_CELL_PAD && a[:xanchor] == "left" && a[:xref] == "paper"
	plan = _SFN._room_plan(f)
	slot = _SFN._room_slot(plan, :colorbar, "bar:2")
	@test slot.side === :right && slot.edge == 1.0
	@test b[:x] ≈ slot.edge + (slot.offset - _SFN._ROOM_GAP) / plan.Wp + _SFN._CBAR_CELL_PAD
	@test (b[:x] - a[:x]) * plan.Wp >= _SFN._room_slot(plan, :colorbar, "bar:1").px
	@test _SFN._finalize_figure!(f) === false
	# A bar placed by the user stays.
	g = Plot([heatmap(x = _SFN_X, y = _SFN_Y, z = permutedims(z)),
		contour(x = _SFN_X, y = _SFN_Y, z = permutedims(2 .* z), colorbar = attr(x = 0.3))], Layout())
	_SFN._finalize_figure!(g)
	@test _sfn_bar(g.data[2])[:x] == 0.3
	# colorbar! with an explicit position releases a bar finalize placed; a
	# call without one keeps it where finalize put it.
	e = plot_heatmap(_SFN_X, _SFN_Y, z; equalar = true)
	@test _sfn_bar(e.data[1])[:xref] == "paper"
	colorbar!(e; title = "kept")
	@test _sfn_bar(e.data[1])[:xref] == "paper"
	@test _sfn_bar(e.data[1])[:x] ≈ _SFN._layout_axis_domain(e.layout, :xaxis)[2] + _SFN._FIN_CBAR_PAD
	colorbar!(e; x = 1.2)
	@test _sfn_bar(e.data[1])[:x] == 1.2
	@test !haskey(_sfn_bar(e.data[1]), :xref)
	@test _SFN._finalize_figure!(e) === false
	# A cell with a plot area to its right gives up the width its two bars
	# need, so they end before that area's tick labels.
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, z; row = 1, col = 1)
	plot_contour!(sf, _SFN_X, _SFN_Y, 2 .* z; row = 1, col = 1)
	plot_scatter!(sf, _SFN_X, sin.(_SFN_X); row = 1, col = 2)
	grid = _SFN._plotlysupply_subplot_layout(sf.plot.layout.subplots)
	xd = _SFN._layout_axis_domain(sf.plot.layout, :xaxis)
	yd = _SFN._cmn_y_axis_domain(sf.plot.layout, :yaxis)
	@test xd[1] == _SFN._layout_axis_domain(grid, :xaxis)[1]
	@test xd[2] < _SFN._layout_axis_domain(grid, :xaxis)[2]
	a = _sfn_bar(sf.plot.data[1])
	b = _sfn_bar(sf.plot.data[2])
	@test a[:x] ≈ xd[2] + _SFN._CBAR_CELL_PAD && b[:x] > a[:x]
	@test a[:len] ≈ yd[2] - yd[1] && b[:len] ≈ yd[2] - yd[1]
	@test a[:xref] == "paper" && b[:xref] == "paper"
	plan = _SFN._room_plan(sf)
	last_slot = _SFN._room_slot(plan, :colorbar, "bar:2")
	neighbour = plan.areas[:xaxis2]
	# D17: the neighbour moves too; the bars end before its labels.
	@test last_slot.offset + last_slot.px <=
		(neighbour.final[1][1] - last_slot.edge) * plan.Wp - neighbour.own[:left] + 1e-6
	@test _SFN._finalize_figure!(sf) === false
	# The last column keeps them side by side (the margin grows for them).
	last = subplots(1, 2; sync = false)
	plot_scatter!(last, _SFN_X, sin.(_SFN_X); row = 1, col = 1)
	plot_heatmap!(last, _SFN_X, _SFN_Y, z; row = 1, col = 2)
	plot_contour!(last, _SFN_X, _SFN_Y, 2 .* z; row = 1, col = 2)
	@test _sfn_bar(last.plot.data[3])[:x] > _sfn_bar(last.plot.data[2])[:x]
	@test _SFN._layout_axis_domain(last.plot.layout, :xaxis2)[2] == 1.0
	# The bar of a trace in an inset goes right of the host cell, level with
	# the inset, never over the host plot.
	si = subplots(1, 1; sync = false)
	plot_scatter!(si, _SFN_X, sin.(_SFN_X))
	k = inset!(si, (0.55, 0.55, 0.4, 0.4))
	plot_heatmap!(si, _SFN_X, _SFN_Y, z; inset = k)
	inset_bar = _sfn_bar(si.plot.data[2])
	host = _SFN._layout_axis_domain(si.plot.layout, :xaxis)
	@test inset_bar[:x] >= something(host, (0.0, 1.0))[2]
	inset_y = _SFN._layout_axis_domain(si.plot.layout, :yaxis2)
	@test inset_bar[:y] ≈ (inset_y[1] + inset_y[2]) / 2 && inset_bar[:len] ≈ inset_y[2] - inset_y[1]
	@test _SFN._finalize_figure!(si) === false
end

@testset "D12: an inner cell gives up the width its bar needs before the next cell (X33, X39)" begin
	z = _sfn_z(_SFN_X, _SFN_Y)
	# Wide tick labels (-8000 ...) do not fit in the default gap of a 2x3 grid.
	sf = subplots(2, 3; sync = false)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, 1e4 .* z; row = 1, col = 1)
	plot_scatter!(sf, _SFN_X, sin.(_SFN_X); row = 1, col = 2)
	plot_scatter!(sf, _SFN_X, cos.(_SFN_X); row = 2, col = 1)
	layout = sf.plot.layout
	grid = _SFN._plotlysupply_subplot_layout(layout.subplots)
	cell = _SFN._layout_axis_domain(grid, :xaxis)
	xd = _SFN._layout_axis_domain(layout, :xaxis)
	@test xd[1] == cell[1] && xd[2] < cell[2]
	# The cell below stays aligned; D17: every column gives up the same, so
	# the columns stay equal (the next one starts after the bar's room).
	@test collect(_SFN._layout_axis_domain(layout, :xaxis4)) ≈ collect(xd)
	x2 = _SFN._layout_axis_domain(layout, :xaxis2)
	@test x2[2] - x2[1] ≈ xd[2] - xd[1]
	@test collect(_SFN._layout_axis_domain(layout, :xaxis5)) ≈ collect(x2)
	bar = _sfn_bar(sf.plot.data[1])
	@test bar[:x] ≈ xd[2] + _SFN._CBAR_CELL_PAD
	@test bar[:xref] == "paper"
	# The bar ends before the tick labels of the next cell.
	W, H = 700.0, 500.0
	accs = _SFN._fin_collect_axes(sf.plot)
	m = _SFN._fin_margins(layout, accs, W, H, Dict{Symbol, NTuple{2, Float64}}(), Any[])
	Wp, Hp = W - m.l - m.r, H - m.t - m.b
	neighbour = _SFN._fin_right_neighbour(layout, accs, xd, _SFN._layout_axis_domain(layout, :yaxis), Hp)
	@test neighbour.x ≈ _SFN._layout_axis_domain(layout, :xaxis2)[1]
	@test neighbour.push > 20
	items, _, _ = _SFN._fin_collect_bars(sf.plot, Any[])
	width = _SFN._fin_bar_width(layout, items["x"][1], Hp)
	@test (bar[:x] - xd[2]) * Wp + width <= (neighbour.x - xd[2]) * Wp - neighbour.push + 0.01
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
	# A cell hosting an inset gives up the room of the inset's bar itself
	# (inset-02), and the inset follows its host's plot area.
	si = subplots(1, 2; sync = false)
	plot_scatter!(si, _SFN_X, sin.(_SFN_X); row = 1, col = 1)
	plot_scatter!(si, _SFN_X, cos.(_SFN_X); row = 1, col = 2)
	k = inset!(si, (0.55, 0.55, 0.4, 0.4); row = 1, col = 1)
	plot_heatmap!(si, _SFN_X, _SFN_Y, 1e4 .* z; inset = k)
	grid = _SFN._plotlysupply_subplot_layout(si.plot.layout.subplots)
	host = _SFN._layout_axis_domain(si.plot.layout, :xaxis)
	@test host[2] < _SFN._layout_axis_domain(grid, :xaxis)[2]
	t = _SFN._cell_target(si; inset = k, who = "test")
	ix = _SFN._layout_axis_domain(si.plot.layout, t.xkey)
	w = host[2] - host[1]
	@test ix[1] ≈ host[1] + 0.55w atol = 1e-6
	@test ix[2] ≈ host[1] + 0.95w atol = 1e-6
	@test _sfn_bar(si.plot.data[end])[:x] >= ix[2]
	@test _sfn_bar(si.plot.data[end])[:x] < _SFN._layout_axis_domain(si.plot.layout, :xaxis2)[1]
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
	# Removing the bar (showscale = false) widens the cell as well.
	sw = subplots(1, 2; sync = false)
	plot_heatmap!(sw, _SFN_X, _SFN_Y, 1e4 .* z; row = 1, col = 1)
	plot_scatter!(sw, _SFN_X, sin.(_SFN_X); row = 1, col = 2)
	cell = _SFN._layout_axis_domain(_SFN._plotlysupply_subplot_layout(sw.plot.layout.subplots), :xaxis)
	@test _SFN._layout_axis_domain(sw.plot.layout, :xaxis)[2] < cell[2]
	before = deepcopy(sw.plot.data)
	sw.plot.data[1].fields[:showscale] = false
	@test _SFN._finalize_figure!(sw; live = before) === true
	@test _SFN._finalize_figure!(sw) === false
	@test _SFN._layout_axis_domain(sw.plot.layout, :xaxis)[2] ≈ cell[2]
end

@testset "D12: horizontal colorbars go below the x tick labels and title (G1, G65)" begin
	z = _sfn_z(_SFN_X, _SFN_Y)
	# Single figure: below the x title, the bottom margin grows for it.
	h = plot_heatmap(_SFN_X, _SFN_Y, z)
	xlabel!(h, "x label")
	colorbar!(h; side = :bottom, title = "Amplitude")
	bar = _sfn_bar(h.data[1])
	plan = _SFN._room_plan(h)
	slot = _SFN._room_slot(plan, :colorbar, "bar:1")
	@test slot.side === :bottom && slot.offset >= plan.areas[:xaxis].own[:bottom] > 30
	@test bar[:orientation] == "h" && bar[:yanchor] == "top" && bar[:yref] == "paper"
	@test bar[:y] ≈ 0 - (slot.offset + _SFN._FIN_HBAR_TITLE_RISE * plan.font) / plan.Hp
	@test bar[:x] ≈ 0.5 && bar[:len] ≈ 1.0
	@test _SFN._finalize_figure!(h) === false
	# A later call on the same side without a position keeps the bar and our
	# mark; a new side moves it.
	colorbar!(h; side = :bottom, title = "Amplitude (V)")
	@test _sfn_bar(h.data[1])[:y] == bar[:y] && _sfn_bar(h.data[1])[:yref] == "paper"
	colorbar!(h; side = :right)
	bar = _sfn_bar(h.data[1])
	@test bar[:orientation] == "v" && !haskey(bar, :yref)
	# 2x2 grid: the upper row gives up the height the bar of cell (1,1)
	# needs, so the bar stays out of cell (2,1); the row stays aligned.
	sf = subplots(2, 2; sync = false, vertical_spacing = 0.2)
	for r in 1:2, c in 1:2
		plot_heatmap!(sf, _SFN_X, _SFN_Y, z; row = r, col = c)
		xlabel!(sf, "x label"; row = r, col = c)
	end
	colorbar!(sf; row = 1, col = 1, side = :bottom, title = "bottom")
	layout = sf.plot.layout
	grid = _SFN._plotlysupply_subplot_layout(layout.subplots)
	yd = _SFN._layout_axis_domain(layout, :yaxis)
	@test yd[1] > _SFN._layout_axis_domain(grid, :yaxis)[1]
	@test collect(_SFN._layout_axis_domain(layout, :yaxis2)) ≈ collect(yd)
	# D17: both rows give up the same; they stay equal and aligned.
	y3 = _SFN._layout_axis_domain(layout, :yaxis3)
	@test y3[2] - y3[1] ≈ yd[2] - yd[1]
	@test collect(_SFN._layout_axis_domain(layout, :yaxis4)) ≈ collect(y3)
	plan = _SFN._room_plan(sf)
	slot = _SFN._room_slot(plan, :colorbar, "bar:1")
	bar = _sfn_bar(sf.plot.data[1])
	@test bar[:y] ≈ yd[1] - (slot.offset + _SFN._FIN_HBAR_TITLE_RISE * plan.font) / plan.Hp
	below = _SFN._layout_axis_domain(layout, :yaxis3)[2]
	# The bar's group (its title rises above `y`) ends above row 2.
	rise = _SFN._FIN_HBAR_TITLE_RISE * plan.font
	@test bar[:y] + (rise - slot.px) / plan.Hp >= below - 1e-9
	@test _SFN._finalize_figure!(sf) === false
	# A bar of the bottom row grows the bottom margin (the plot height the
	# first bar was placed with changes): the bar of cell (1,1) stays ours,
	# re-placed, and clear of row 2.
	colorbar!(sf; row = 2, col = 2, side = :bottom, title = "bottom (2,2)")
	plan = _SFN._room_plan(sf)
	slot = _SFN._room_slot(plan, :colorbar, "bar:1")
	bar = _sfn_bar(sf.plot.data[1])
	yd = _SFN._layout_axis_domain(layout, :yaxis)
	@test bar[:yref] == "paper" && yd[1] > _SFN._layout_axis_domain(grid, :yaxis)[1]
	@test bar[:y] ≈ yd[1] - (slot.offset + _SFN._FIN_HBAR_TITLE_RISE * plan.font) / plan.Hp
	@test bar[:y] + (rise - slot.px) / plan.Hp >= _SFN._layout_axis_domain(layout, :yaxis3)[2] - 1e-9
	@test _SFN._finalize_figure!(sf) === false
	# A bottom bar shared by a row of cells (shared_colorbar!) goes below
	# their x titles.
	row = subplots(1, 3; sync = false)
	for c in 1:3
		plot_heatmap!(row, _SFN_X, _SFN_Y, c .* z; row = 1, col = c)
		xlabel!(row, "x title"; row = 1, col = c)
	end
	shared_colorbar!(row; side = :bottom, title = "shared")
	shared = _sfn_fields(_sfn_fields(row.plot.layout.fields[:coloraxis])[:colorbar])
	plan = _SFN._room_plan(row)
	slot = _SFN._room_slot(plan, :colorbar, "coloraxis:coloraxis")
	@test slot.offset > plan.areas[:xaxis].own[:bottom]
	@test shared[:y] ≈ 0 - (slot.offset + _SFN._FIN_HBAR_TITLE_RISE * plan.font) / plan.Hp && shared[:yref] == "paper"
	@test shared[:len] ≈ 0.75
	@test _SFN._finalize_figure!(row) === false
end

@testset "D12: room requests of other owners (contract)" begin
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, _SFN_X, sin.(_SFN_X); row = 1, col = 1)
	plot_scatter!(sf, _SFN_X, cos.(_SFN_X); row = 1, col = 2)
	plan = _SFN._room_plan(sf)
	@test isempty(plan.requests)
	@test _SFN._room_domain(plan, :xaxis) == plan.areas[:xaxis].current
	@test _SFN._room_slot(plan, :colorbar, "bar:1") === nothing
	@test_throws ArgumentError _SFN._request_room!(plan, :xaxis, :middle, 10; owner = :test, key = "k")
	@test_throws ArgumentError _SFN._request_room!(plan, :xaxis, :right, -1; owner = :test, key = "k")
	@test_throws ArgumentError _SFN._request_room!(plan, :xaxis, :right, Inf; owner = :test, key = "k")
	_SFN._request_room!(plan, :nosuch, :right, 10; owner = :test, key = "k")
	@test isempty(plan.requests)
	# A request on the right of the left cell: the cell gives up what the
	# gap to its neighbour's tick labels cannot hold.
	_SFN._request_room!(plan, :xaxis, :right, 80; owner = :test, key = "k", margin_pushed = true)
	_SFN._room_set_refs!(plan)
	_SFN._room_solve!(plan)
	_SFN._room_assign_slots!(plan)
	slot = _SFN._room_slot(plan, :test, "k")
	ref = plan.areas[:xaxis].ref
	gap = (plan.areas[:xaxis2].ref[1][1] - ref[1][2]) * plan.Wp
	facing = _SFN._room_label_px(plan.areas[:xaxis2].own[:left])
	# D17: the room taken in the gap is shared by the columns (their spans
	# shrink alike), so the left cell's right edge moves by its share.
	take = (_SFN._ROOM_GAP + 80 - (gap - facing - _SFN._ROOM_GAP)) / plan.Wp
	spans = [ref[1][2] - ref[1][1], plan.areas[:xaxis2].ref[1][2] - plan.areas[:xaxis2].ref[1][1]]
	@test slot.edge ≈ ref[1][1] + spans[1] * (sum(spans) - take) / sum(spans)
	r2 = plan.areas[:xaxis2].final[1]
	@test r2[2] - r2[1] ≈ slot.edge - ref[1][1]
	@test slot.offset == _SFN._ROOM_GAP && slot.px == 80 && !slot.release
	@test _SFN._room_domain(plan, :xaxis)[1][2] == slot.edge
	# Text size helpers.
	@test _SFN._room_text_width("<b>abc</b>", 10) ≈ 18
	@test _SFN._room_text_width("ab<br>abcd", 10) ≈ 24
	@test _SFN._room_text_height("a<br>b", 10) ≈ 28
	@test _SFN._room_text_height(raw"$\frac{a}{b}$", 10) ≈ 22
	@test _SFN._room_text_height("", 10) == 0
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

@testset "subplot delegates finalize; equal aspect on an inset (Y18, Y2)" begin
	z = _sfn_z(_SFN_X, _SFN_Y)
	# Y18: the fast cell path (no equalar, no range) is finalized by the
	# delegate: the cell axes get the sticky clip, and nothing is left.
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, z; row = 1, col = 2)
	@test _sfn_clip(sf, :xaxis2) == _SFN_XE && _sfn_clip(sf, :yaxis2) == _SFN_YE
	@test _SFN._finalize_figure!(sf) === false
	# Y2: equalar on an inset constrains the inset's axes, not the host's,
	# and the inset is fitted inside its own rectangle.
	si = subplots(1, 1; sync = false)
	plot_scatter!(si, _SFN_X, sin.(_SFN_X))
	k = inset!(si, (0.5, 0.5, 0.45, 0.45))
	plot_heatmap!(si, _SFN_X, _SFN_Y, z; inset = k, equalar = true)
	@test _sfn_get(si, :yaxis2, :scaleanchor) == "x2"
	@test _sfn_get(si, :yaxis, :scaleanchor) === nothing
	@test _sfn_get(si, :xaxis2, :constrain) == "domain"
	inset = only(getfield(si, :insets))
	xd = _SFN._layout_axis_domain(si.plot.layout, :xaxis2)
	yd = _SFN._layout_axis_domain(si.plot.layout, :yaxis2)
	@test inset.xdomain[1] - 1e-9 <= xd[1] && xd[2] <= inset.xdomain[2] + 1e-9
	@test inset.ydomain[1] - 1e-9 <= yd[1] && yd[2] <= inset.ydomain[2] + 1e-9
	@test _SFN._finalize_figure!(si) === false
	# The helper itself takes an inset target.
	raw = subplots(1, 1; sync = false)
	plot_scatter!(raw, _SFN_X, sin.(_SFN_X))
	k = inset!(raw, (0.5, 0.5, 0.45, 0.45))
	plot_scatter!(raw, _SFN_X, cos.(_SFN_X); inset = k)
	target = _SFN._cell_target(raw; inset = k)
	_SFN._apply_equal_aspect!(raw, target; ratio = 2)
	@test _sfn_get(raw, :yaxis2, :scaleanchor) == "x2" && _sfn_get(raw, :yaxis2, :scaleratio) == 2.0
	@test _sfn_get(raw, :yaxis, :scaleanchor) === nothing
	@test_throws ArgumentError _SFN._apply_equal_aspect!(raw, target; ratio = 0)
end

@testset "append-only fast path: a cell whose bar would move is left for a full pass" begin
	z = _sfn_z(_SFN_X, _SFN_Y)
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, 1e4 .* z; row = 1, col = 1)
	plot_scatter!(sf, _SFN_X, sin.(_SFN_X); row = 1, col = 2)
	p = sf.plot
	live = copy(p.data)
	before = [JSON.json(t) for t in live]
	xd = _SFN._layout_axis_domain(p.layout, :xaxis)
	# A second bar in cell (1,1): the cell must narrow, so its first bar (a
	# live trace) would move; nothing of the cell changes on this path.
	push!(p.data, contour(x = _SFN_X, y = _SFN_Y, z = permutedims(2 .* z), xaxis = "x", yaxis = "y"))
	_SFN._finalize_figure!(sf; live = live)
	@test [JSON.json(t) for t in live] == before
	@test _SFN._layout_axis_domain(p.layout, :xaxis) == xd
	# The next full pass places both.
	@test _SFN._finalize_figure!(sf) === true
	narrowed = _SFN._layout_axis_domain(p.layout, :xaxis)
	@test narrowed[2] < xd[2]
	a = _sfn_bar(p.data[1])
	b = _sfn_bar(p.data[3])
	@test a[:x] ≈ narrowed[2] + _SFN._CBAR_CELL_PAD && b[:x] > a[:x]
	@test _SFN._finalize_figure!(sf) === false
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
		# Data outside the field: the range grows to it, padded on that side.
		out = plot_heatmap(_SFN_X, _SFN_Y, z)
		plot_scatter!(out, [5.5], [-1.0]; mode = "markers")
		info = _sfn_render(out)
		pad = _SFN._FIN_OVERLAY_PAD
		@test close_to(_sfn_range(info, :xaxis), (-0.25, 5.5 + pad * 5.75))
		@test close_to(_sfn_range(info, :yaxis), (-1.0 - pad * 3.25, 2.25))
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
		# G3, G19, G29, Y24: default 1x2 and 2x2 heatmap grids; a plain title
		# beside a bar stays clear of the next cell's y tick labels and title.
		pair = subplots(1, 2; sync = false)
		plot_heatmap!(pair, _SFN_X, _SFN_Y, 6 .* z; row = 1, col = 1)
		plot_heatmap!(pair, _SFN_X, _SFN_Y, z; row = 1, col = 2)
		info = _sfn_render(pair; bars = 2)
		bars = sort(info["colorbars"]; by = b -> b["x0"])
		@test bars[1]["labels_right"] < info["axes"]["yaxis2"]["labels_left"]
		quad = subplots(2, 2; sync = false)
		for r in 1:2, c in 1:2
			plot_heatmap!(quad, _SFN_X, _SFN_Y, (r + c) .* z; row = r, col = c)
			ylabel!(quad, "y title"; row = r, col = c)
		end
		colorbar!(quad; row = 2, col = 1, title = "plain right", title_side = :right)
		info = _sfn_render(quad; bars = 4)
		left = sort([b for b in info["colorbars"] if b["x0"] < 350]; by = b -> b["y0"])
		@test length(left) == 2
		@test left[1]["labels_right"] < info["axes"]["yaxis2"]["labels_left"]
		@test left[2]["labels_right"] < info["axes"]["yaxis4"]["labels_left"]
		# G1, G65: a bottom bar and its title go below the x tick labels and
		# title; in an upper row they stay out of the row below.
		single = plot_heatmap(_SFN_X, _SFN_Y, z)
		xlabel!(single, "x label")
		colorbar!(single; side = :bottom, title = "Amplitude")
		info = _sfn_render(single; bars = 1)
		@test only(info["colorbars"])["top"] > info["axes"]["xaxis"]["labels_bottom"]
		rows = subplots(2, 2; sync = false, vertical_spacing = 0.2)
		for r in 1:2, c in 1:2
			plot_heatmap!(rows, _SFN_X, _SFN_Y, z; row = r, col = c)
			xlabel!(rows, "x label"; row = r, col = c)
		end
		colorbar!(rows; row = 1, col = 1, side = :bottom, title = "bottom (1,1)")
		colorbar!(rows; row = 2, col = 2, side = :bottom, title = "bottom (2,2)")
		info = _sfn_render(rows; bars = 4)
		horizontal = sort([b for b in info["colorbars"] if b["x1"] - b["x0"] > b["y1"] - b["y0"]]; by = b -> b["y0"])
		@test length(horizontal) == 2
		@test horizontal[1]["top"] > info["axes"]["xaxis"]["labels_bottom"]
		@test horizontal[1]["bottom"] < info["axes"]["yaxis3"]["offset"]
		@test horizontal[2]["top"] > info["axes"]["xaxis4"]["labels_bottom"]
		# K4: plot_matrix pins its reversed y axis (descending range): row 1
		# is drawn at the top.
		info = _sfn_render(plot_matrix([10i + j for i in 1:3, j in 1:4]); bars = 1)
		@test close_to(_sfn_range(info, :yaxis), (3.5, 0.5))
		# hm_03: a tall equal-aspect field is centred with its y tick labels
		# and its bar in a wide figure.
		ty = collect(0.0:0.125:10.0)
		tall = plot_heatmap(_SFN_X, ty, _sfn_z(_SFN_X, ty); equalar = true)
		info = _sfn_render(tall; width = 700, height = 450, bars = 1)
		centre = (info["axes"]["yaxis"]["labels_left"] + only(info["colorbars"])["labels_right"]) / 2
		@test abs(centre - 350) <= 15
	end
end

# ---------------------------------------------------------------------------
# Wave 5 (layout-engine)
# ---------------------------------------------------------------------------

@testset "a journal style's own size is free for M3a; a user size is kept (Z67)" begin
	x = collect(range(0, 6; length = 61)); y = collect(range(0, 0.6; length = 7))
	z = [sin(a) + b for a in x, b in y]
	with_style(:ieee) do
		W, H = _SFN._style_default_figure_size()
		# The style's size is the FIGURE's (K1): a layout that carries the
		# style's record (a figure built under it) has it free; a bare layout
		# of the same size does not, whatever style is active.
		carried = plot_scatter(1:3, 1:3).layout
		carried.fields[:width] = W; carried.fields[:height] = H
		# L11: the journal width stays; only the height is free.
		@test _SFN._fin_size_choice(carried) == (Float64(W), Float64(H), false, true)
		@test _SFN._fin_size_choice(Layout(width = W, height = H)) === nothing
		carried.fields[:width] = W + 10
		@test _SFN._fin_size_choice(carried) === nothing
		# Wide field: the width is kept, blank rows go; the lower bound
		# scales with the journal size (100 px at 500 px tall).
		f = plot_heatmap(x, y, z; equalar = true)
		@test f.layout.fields[:width] == round(Int, W)
		@test 100 <= f.layout.fields[:height] < H
		@test f.layout.fields[:height] >= round(_SFN._FIN_MIN_FIGURE_HEIGHT * H / _SFN._DEFAULT_EXPORT_HEIGHT_PX)
		# Tall field: the journal width is never changed (L11), and the
		# height has no blank to drop.
		t = plot_heatmap(y, x, permutedims(z); equalar = true)
		@test t.layout.fields[:height] == round(Int, H) && t.layout.fields[:width] == round(Int, W)
		# A size the user gave stays.
		u = plot_heatmap(x, y, z)
		figsize!(u, 400, 300)
		plot_heatmap!(u, x, y, z; equalar = true)
		@test u.layout.fields[:width] == 400 && u.layout.fields[:height] == 300
	end
	@test _SFN._fin_size_choice(Layout()) == (700.0, 500.0, true, true)
	d = plot_heatmap(x, y, z; equalar = true)
	@test d.layout.fields[:width] == 700 && d.layout.fields[:height] < 500
end

@testset "images give their axes the pixel extent (Z40)" begin
	f = plot_image(rand(UInt8, 4, 6, 3))
	@test _sfn_clip(f, :xaxis) == (-0.5, 5.5)
	@test _sfn_clip(f, :yaxis) == (-0.5, 3.5)
	g = plot_image(rand(5, 7, 3); interpolation = :bilinear)
	@test haskey(g.data[end].fields, :source)
	@test _sfn_clip(g, :xaxis) == (-0.5, 6.5)
	@test _sfn_clip(g, :yaxis) == (-0.5, 4.5)
end

@testset "equal aspect resolves a one-sided linked limit (Z54)" begin
	f = plot_heatmap(collect(0:9), collect(0:4), rand(10, 5))
	xrange!(f, (2, nothing))
	plot_heatmap!(f, collect(0:9), collect(0:4), rand(10, 5); equalar = true)
	x = _sfn_axis(f, :xaxis)
	@test _sfn_get(f, :xaxis, :autorange) === false
	range = _sfn_get(f, :xaxis, :range)
	@test range[1] == 2 && 9 < range[2] <= 9.5 + 1e-9
end

@testset "D16: overlays whose anchors are inside the field keep the range tight" begin
	f = plot_heatmap(collect(0.0:4.0), collect(0.0:4.0), rand(5, 5))
	# An overlay drawn past the field (arrows from anchors inside it).
	plot_scatter!(f, [0.0, 5.5, 4.0, 4.0], [0.0, 2.0, 4.0, 5.0]; mode = "lines")
	q = f.data[end]
	loose = _sfn_clip(f, :xaxis)
	@test loose[1] == -0.5 && loose[2] ≈ 5.5 + _SFN._FIN_OVERLAY_PAD * 6.0
	q.fields[:meta] = Dict("plotlysupply_anchor_extent" => [0.0, 4.0, 0.0, 4.0])
	_SFN._finalize_figure!(f)
	@test _sfn_clip(f, :xaxis) == (-0.5, 4.5) && _sfn_clip(f, :yaxis) == (-0.5, 4.5)
	# A PlotlyAttribute meta with Symbol keys reads the same.
	with_meta(meta) = (t = GenericTrace("scatter"); t.fields[:meta] = meta; t)
	symbol_meta = PlotlyBase.PlotlyAttribute(Dict{Symbol, Any}(:plotlysupply_anchor_extent => [1, 2, 3, 4]))
	@test _SFN._fin_anchor_extent(with_meta(symbol_meta), 'y', false) == (3.0, 4.0)
	@test _SFN._fin_anchor_extent(with_meta(symbol_meta), 'x', true) == (1.0, 2.0)
	@test _SFN._fin_anchor_extent(with_meta(Dict("plotlysupply_anchor_extent" => [-1, 2, 3, 4])), 'x', true) === nothing
	# Anchors outside the field: their extent counts, padded on that side.
	q.fields[:meta] = Dict("plotlysupply_anchor_extent" => [0.0, 6.0, 0.0, 4.0])
	_SFN._finalize_figure!(f)
	clip = _sfn_clip(f, :xaxis)
	@test clip[1] == -0.5 && clip[2] ≈ 6.0 + _SFN._FIN_OVERLAY_PAD * 6.5
	@test _sfn_clip(f, :yaxis) == (-0.5, 4.5)
	# Malformed meta: ignored (the drawn extent counts).
	for bad in (Dict("plotlysupply_anchor_extent" => [0.0, 4.0]), Dict("plotlysupply_anchor_extent" => [4.0, 0.0, 0.0, 4.0]),
		Dict("plotlysupply_anchor_extent" => [NaN, 4.0, 0.0, 4.0]), "plotlysupply:field")
		@test _SFN._fin_anchor_extent(with_meta(bad), 'x', false) === nothing
	end
end

@testset "axis records are scanned once per run, lazily (Z81)" begin
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, _SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y); row = 1, col = 1)
	plot_scatter!(sf, 1:10, rand(10); row = 1, col = 2)
	axes = _SFN._fin_collect_axes(sf.plot)
	@test haskey(axes, :xaxis) && haskey(axes, :xaxis2)
	@test all(acc -> !acc.scanned, values(_SFN._fin_axis_records(axes)))
	acc = get(axes, :xaxis, nothing)
	@test acc.scanned && (acc.flo, acc.fhi) == (-0.25, 4.25)
	@test !_SFN._fin_axis_records(axes)[:xaxis2].scanned
	@test get(axes, :nope, :missing) === :missing
	# The run reads every record once: a second finalize changes nothing.
	@test _SFN._finalize_figure!(sf) === false
end

@testset "one colour scan per array per call (Z83)" begin
	z = rand(50, 50)
	@test _SFN._cbar_extrema(z) == extrema(z)
	calls = _SFN._cbar_with_extrema_memo() do
		_SFN._cbar_extrema(z); _SFN._cbar_extrema(z)
		memo = _SFN._CBAR_EXTREMA_MEMO[]
		(length(memo), memo[z])
	end
	@test calls == (1, extrema(z))
	@test _SFN._CBAR_EXTREMA_MEMO[] === nothing
	# The fast path agrees with the plain scan on every special value.
	cases = Any[Float64[], [NaN, NaN], [1.0, NaN, -Inf, 3.0, Inf], Float32[2, NaN, -1], [5.0], [-0.0, 0.0]]
	for values in cases
		@test _SFN._cbar_real_extrema(values) == _SFN._cbar_real_extrema(Any[v for v in values])
	end
	@test _SFN._cbar_real_extrema(PermutedDimsArray([1.0 NaN; 3.0 -2.0], (2, 1))) == (-2.0, 3.0)
	# A mutation scans a large colour array once (cost guard).
	h = plot_heatmap(rand(1500, 1500))
	colorbar!(h; title = "a")
	# (best of 3: a loaded machine can stall one timing, not all three)
	t = minimum(title -> @elapsed(colorbar!(h; title = title)), ("b", "c", "d"))
	@test t < 0.5
end

@testset "plot areas are found once per fit (Z82)" begin
	sf = subplots(2, 3; sync = false)
	for c in 1:3
		plot_heatmap!(sf, _SFN_X, _SFN_Y, 1e4 .* _sfn_z(_SFN_X, _SFN_Y); row = 1, col = c)
	end
	layout = sf.plot.layout
	accs = _SFN._fin_collect_axes(sf.plot)
	grid = Ref{Any}(_SFN._plotlysupply_subplot_layout(layout.subplots))
	ref = (_SFN._layout_axis_domain(grid[], :xaxis), _SFN._layout_axis_domain(grid[], :yaxis))
	cache = IdDict{Any, Any}()
	a = _SFN._fin_right_allowance(layout, accs, ref, grid, 600.0, 400.0; area_cache = cache)
	@test length(cache) == 1
	b = _SFN._fin_right_allowance(layout, accs, ref, grid, 600.0, 400.0; area_cache = cache)
	@test a == b == _SFN._fin_right_allowance(layout, accs, ref, grid, 600.0, 400.0)
	@test length(cache) == 1
	# Cost guard: finalizing a 2 x 3 grid of fields stays fast.
	_SFN._finalize_figure!(sf)
	@test minimum(_ -> @elapsed(_SFN._finalize_figure!(sf)), 1:3) < 0.5
end

@testset "the extent scan allocates no copies of large data (Z79a)" begin
	n = 1_000_000
	s = plot_scatter(collect(1.0:n), rand(n))
	_SFN._finalize_figure!(s)
	axes = _SFN._fin_collect_axes(_sfn_plot(s))
	get(axes, :xaxis, nothing)
	axes = _SFN._fin_collect_axes(_sfn_plot(s))
	bytes = @allocated get(axes, :xaxis, nothing)
	@test bytes < 100_000
	bytes = @allocated _SFN._finalize_figure!(s)
	@test bytes < 2_000_000
	@test minimum(_ -> @elapsed(_SFN._finalize_figure!(s)), 1:3) < 0.25
end

@testset "export copies refit scenes; document exports orbit the origin (Z43)" begin
	x = collect(range(-1, 1; length = 12))
	f = plot_surface(x, x, [a^2 - b for a in x, b in x])
	opts = (width = 900.0, height = 300.0)
	live = _sfn_snapshot(f)
	pan = _SFN._finalize_export_copy(f, opts)
	still = _SFN._finalize_export_copy(f, opts; pan = false)
	@test _sfn_snapshot(f) == live
	camera(p) = _sfn_fields(_sfn_fields(p.layout.fields[:scene])[:camera])
	center(p) = (c = get(camera(p), :center, nothing); c === nothing ? (0.0, 0.0, 0.0) :
		(c = _sfn_fields(c); (Float64(c[:x]), Float64(c[:y]), Float64(c[:z]))))
	# `pan = false` (HTML/JSON: the viewer orbits the camera centre) returns a
	# centre PlotlySupply moved to the origin (`_s3_refit_scenes!`).
	@test center(still) == (0.0, 0.0, 0.0)
	# The export copy is framed for its size: the eye differs from the live one.
	eye(p) = (e = _sfn_fields(camera(p)[:eye]); (e[:x], e[:y], e[:z]))
	@test eye(still) != eye(f)
	@test eye(pan) == eye(still) || center(pan) != center(f)
	# The renderer path takes `pan`, the document path passes `pan = false`.
	options = _SFN._ExportOptions(900.0, 300.0, 1.0, nothing, true, nothing, false, 30.0, :px, false, :auto)
	@test center(_SFN._export_source(f, options; pan = false)) == (0.0, 0.0, 0.0)
	tight = _SFN._ExportOptions(900.0, 300.0, 1.0, nothing, true, nothing, true, 30.0, :px, false, :auto)
	@test center(_SFN._export_source(f, tight; pan = false)) == (0.0, 0.0, 0.0)
	# A centre the user set is kept either way.
	g = plot_surface(x, x, [a^2 - b for a in x, b in x])
	relayout!(g; scene_camera_center = Dict(:x => 0.2, :y => 0.1, :z => 0.0))
	@test center(_SFN._export_source(g, options; pan = false)) == center(g)
	@test _sfn_snapshot(f) == live
end

@testset "whole-figure annotations follow the margins every run leaves (Z47)" begin
	f = plot_scatter(1:10, rand(10))
	annotate!(f, 0.02, 0.98, "(a)"; coords = :figure, showarrow = false)
	item() = _sfn_fields(f.layout.fields[:annotations][1])
	before = item()[:xshift]
	# A y title widens the left margin estimate.
	ylabel!(f, "A y title")
	after = item()[:xshift]
	@test after != before
	# What the placement gives for the margins the run left: no change.
	copy_items = collect(Any, f.layout.fields[:annotations])
	@test _SFN._figure_annotations_place!(f, copy_items; size = (700.0, 500.0)) === nothing
	@test _sfn_fields(copy_items[1])[:xshift] == after
	@test _SFN._finalize_figure!(f) === false
end

@testset "grid titles get room past the outer axis labels (Z20)" begin
	sf = subplots(2, 2; sync = false, x_title = "Shared x title", y_title = "Shared y title (units)")
	for r in 1:2, c in 1:2
		plot_scatter!(sf, 1:10, 1000 .* (1:10); row = r, col = c)
	end
	layout = sf.plot.layout
	names = [_sfn_fields(a)[:name] for a in layout.fields[:annotations] if haskey(_sfn_fields(a), :name)]
	@test "plotlysupply:x_title" in names && "plotlysupply:y_title" in names
	find(name) = _sfn_fields(only(a for a in layout.fields[:annotations] if get(_sfn_fields(a), :name, "") == name))
	ytitle = find("plotlysupply:y_title")
	xtitle = find("plotlysupply:x_title")
	plan = _SFN._room_plan(sf)
	left = maximum(a.own[:left] for a in values(plan.areas))
	bottom = maximum(a.own[:bottom] for a in values(plan.areas))
	@test ytitle[:xanchor] == "right" && ytitle[:xshift] <= -left
	@test xtitle[:yanchor] == "top" && xtitle[:yshift] <= -bottom
	margin = _sfn_fields(layout.fields[:margin])
	@test margin[:l] >= -ytitle[:xshift] + _SFN._room_text_height("Shared y title (units)", 12.0)
	@test margin[:b] >= -xtitle[:yshift] + _SFN._room_text_height("Shared x title", 12.0)
	@test _SFN._finalize_figure!(sf) === false
	# The grid title owner is listed with the other room owners.
	@test :grid_titles in _SFN._ROOM_OWNERS
end

@testset "a y title in the gap takes room from its own cell (Z71)" begin
	with_style(:ieee) do
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, 1:10, rand(10); row = 1, col = 1)
		plot_scatter!(sf, 1:10, 1000 .* rand(10); row = 1, col = 2)
		ylabel!(sf, "left y"; row = 1, col = 1)
		ylabel!(sf, "Amplitude (a.u.)"; row = 1, col = 2)
		layout = sf.plot.layout
		grid = _SFN._plotlysupply_subplot_layout(layout.subplots)
		d1 = _SFN._layout_axis_domain(layout, :xaxis)
		d2 = _SFN._layout_axis_domain(layout, :xaxis2)
		@test d2[1] > _SFN._layout_axis_domain(grid, :xaxis2)[1]
		# D17: both cells give up the room; they stay equal.
		@test d1[1] == _SFN._layout_axis_domain(grid, :xaxis)[1]
		@test d1[2] - d1[1] ≈ d2[2] - d2[1]
		plan = _SFN._room_plan(sf)
		a = plan.areas[:xaxis2]
		@test (d2[1] - d1[2]) * plan.Wp >= _SFN._room_label_px(a.own[:left]) + _SFN._ROOM_GAP - 1e-6
		@test _SFN._finalize_figure!(sf) === false
	end
	# Labels that fit the gap leave the grid alone (2 x 3 default spacing).
	sf = subplots(2, 3; sync = false)
	plot_scatter!(sf, _SFN_X, sin.(_SFN_X); row = 1, col = 2)
	grid = _SFN._plotlysupply_subplot_layout(sf.plot.layout.subplots)
	for k in (:xaxis2, :xaxis3)
		@test collect(_SFN._layout_axis_domain(sf.plot.layout, k)) ≈ collect(_SFN._layout_axis_domain(grid, k))
	end
end

@testset "an axis title longer than the figure is wrapped (W5)" begin
	long = "a fairly long y-axis label that matplotlib would split"
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, 1:10, rand(10); row = 1, col = 1)
	plot_scatter!(sf, 1:10, rand(10); row = 1, col = 2)
	ylabel!(sf, long; row = 1, col = 1)
	figsize!(sf, 578, 227)
	title = _sfn_fields(_sfn_axis(sf, :yaxis)[:title])
	@test occursin(_SFN._FIN_WRAP_BREAK, title[:text])
	@test replace(title[:text], _SFN._FIN_WRAP_BREAK => " ") == long
	@test title[:standoff] == _SFN._FIN_WRAP_STANDOFF
	# Every line fits the figure height.
	for line in split(title[:text], _SFN._FIN_WRAP_BREAK)
		@test length(line) * _SFN._FIN_WRAP_CHAR_EM * 14 <= 227
	end
	# The figure's own margin is left alone (it would outlive the wrap); a
	# tight export copy gets a left margin that holds the lines (plotly's
	# automargin does not count them in full).
	layout = sf.plot.layout
	@test _sfn_fields(layout.fields[:margin])[:l] == 50
	@test _SFN._finalize_figure!(sf) === false
	tight = _SFN._ExportOptions(578.0, 227.0, 1.0, nothing, true, nothing, true, 30.0, :px, false, :auto)
	copy = _SFN._export_source(sf.plot, tight)
	copy_title = _sfn_fields(copy.layout.fields[:yaxis][:title])
	@test occursin(_SFN._FIN_WRAP_BREAK, copy_title[:text])
	accs = _SFN._fin_collect_axes(copy)
	need = _SFN._fin_y_labels_px(copy.layout, accs, :yaxis, (0.0, 1.0), 100.0)
	@test _sfn_fields(copy.layout.fields[:margin])[:l] >= need
	@test _sfn_fields(layout.fields[:margin])[:l] == 50
	# A larger figure: one line again, our standoff gone.
	figsize!(sf, 1400, 900)
	title = _sfn_fields(_sfn_axis(sf, :yaxis)[:title])
	@test title[:text] == long && get(title, :standoff, nothing) === nothing
	# The user's own breaks and math titles are kept as written.
	ylabel!(sf, "first<br>second line of a title that is much too long for this small figure"; row = 1, col = 1)
	figsize!(sf, 400, 150)
	text = _sfn_fields(_sfn_axis(sf, :yaxis)[:title])[:text]
	@test startswith(text, "first<br>second")
	ylabel!(sf, "\$\\alpha\$ a math title that is much too long for this small figure to show"; row = 1, col = 1)
	@test !occursin(_SFN._FIN_WRAP_BREAK, _sfn_fields(_sfn_axis(sf, :yaxis)[:title])[:text])
	# The wrapper itself.
	@test _SFN._fin_wrap_line("aa bb cc", 5) == "aa bb" * _SFN._FIN_WRAP_BREAK * "cc"
	@test _SFN._fin_wrap_line("averyveryverylongword x", 5) == "averyveryverylongword" * _SFN._FIN_WRAP_BREAK * "x"
	@test _SFN._fin_wrap_title("one two<br>three four", 7) == "one two<br>three" * _SFN._FIN_WRAP_BREAK * "four"
	# Extra lines widen the label estimate.
	axis = Dict{Symbol, Any}(:title => Dict{Symbol, Any}(:text => "a<br />b"))
	@test _SFN._fin_title_push(axis, 12.0) ≈ _SFN._fin_title_push(Dict(:title => "a"), 12.0) + _SFN._FIN_LINE_EM * 14
end

@testset "a title wrapped while the fonts were large leaves no room behind (composite_2x2)" begin
	sf = subplots(2, 2; sync = false, horizontal_spacing = 0.2, vertical_spacing = 0.2)
	plot_scatter!(sf, 1:3, 1:3; row = 1, col = 1)
	plot_scatter!(sf, 1:3, 1:3; row = 1, col = 2)
	set_fonts!(sf; size = 16, label = 20)
	for c in 1:2
		plot_scatter!(sf, 1:8, 10.0 .^ -(2 .* (1:8)); row = 2, col = c, yscale = "log")
		ylabel!(sf, "Relative frequency difference"; row = 2, col = c)
	end
	layout = sf.plot.layout
	grid = _SFN._plotlysupply_subplot_layout(layout.subplots)
	# Wrapped at the large font (the bottom row is 156 px tall; the finalizer's
	# wrap, `_FIN_WRAP_BREAK`, is the only one) ...
	@test occursin(_SFN._FIN_WRAP_BREAK, _sfn_fields(_sfn_axis(sf, :yaxis4)[:title])[:text])
	# ... with no grown margin; the room the wrapped title needs in the 20 %
	# gap (Z71) is given up by both columns alike (D17): the left ones keep
	# their left edge, the right ones start later, all four stay equal.
	@test _sfn_fields(layout.fields[:margin])[:l] == 50
	for k in (:xaxis, :xaxis3)
		@test _SFN._layout_axis_domain(layout, k)[1] ≈ _SFN._layout_axis_domain(grid, k)[1]
	end
	for k in (:xaxis2, :xaxis4)
		@test _SFN._layout_axis_domain(layout, k)[1] > _SFN._layout_axis_domain(grid, k)[1]
	end
	spans = [(d = _SFN._layout_axis_domain(layout, k); d[2] - d[1]) for k in (:xaxis, :xaxis2, :xaxis3, :xaxis4)]
	@test maximum(spans) - minimum(spans) <= 1e-9
	@test _SFN._finalize_figure!(sf) === false
	# Smaller fonts: one line again and the cells get the room back (the
	# record of what the room solve wrote, `layout.meta`, says the narrowing
	# was ours).
	set_fonts!(sf; size = 9, label = 9.2, tick = 7.5, units = :pt)
	@test _sfn_fields(_sfn_axis(sf, :yaxis4)[:title])[:text] == "Relative frequency difference"
	@test _sfn_fields(layout.fields[:margin])[:l] == 50
	for k in (:xaxis, :xaxis2, :xaxis3, :xaxis4)
		@test collect(_SFN._layout_axis_domain(layout, k)) ≈ collect(_SFN._layout_axis_domain(grid, k))
	end
	@test !haskey(layout.fields, :meta)
	@test _SFN._finalize_figure!(sf) === false
	# A domain the user narrowed after the solve is theirs and is kept.
	function build()
		g = subplots(2, 2; sync = false, horizontal_spacing = 0.2, vertical_spacing = 0.2)
		plot_scatter!(g, 1:3, 1:3; row = 1, col = 1)
		plot_scatter!(g, 1:3, 1:3; row = 1, col = 2)
		set_fonts!(g; size = 16, label = 20)
		for c in 1:2
			plot_scatter!(g, 1:8, 10.0 .^ -(2 .* (1:8)); row = 2, col = c, yscale = "log")
			ylabel!(g, "Relative frequency difference"; row = 2, col = c)
		end
		return g
	end
	g = build()
	@test _SFN._layout_axis_domain(g.plot.layout, :xaxis4)[1] > 0.6
	relayout!(g.plot; xaxis4_domain = [0.8, 1.0])
	set_fonts!(g; size = 9, label = 9.2, tick = 7.5, units = :pt)
	@test collect(_SFN._layout_axis_domain(g.plot.layout, :xaxis4)) ≈ [0.8, 1.0]
end

@testset "equal-aspect cells of a row keep one size when labels fill the gap (audit_d)" begin
	sf = subplots(1, 3; sync = false, horizontal_spacing = 0.04)
	figsize!(sf, 826, 288)
	for k in 1:3
		plot_heatmap!(sf, collect(range(0, 1.2; length = 13)), collect(range(0, 1.07; length = 11)), rand(13, 11);
			row = 1, col = k, equalar = true, showscale = false)
	end
	layout = sf.plot.layout
	plan = _SFN._room_plan(sf)
	# The middle cell's tick labels need more than the grid gap ...
	gap = 0.04 * plan.Wp
	@test plan.areas[:xaxis2].own[:left] > gap - _SFN._ROOM_GAP
	# ... yet no cell is narrowed for them: the fits stay alike.
	widths = [(d = _SFN._layout_axis_domain(layout, k); d[2] - d[1]) for k in (:xaxis, :xaxis2, :xaxis3)]
	heights = [(d = _SFN._layout_axis_domain(layout, k); d[2] - d[1]) for k in (:yaxis, :yaxis2, :yaxis3)]
	@test maximum(widths) - minimum(widths) <= 1e-6
	@test maximum(heights) - minimum(heights) <= 1e-6
	# D17: the gaps the labels widen are alike too.
	d = [_SFN._layout_axis_domain(layout, k) for k in (:xaxis, :xaxis2, :xaxis3)]
	@test d[2][1] - d[1][2] ≈ d[3][1] - d[2][2]
	@test _SFN._finalize_figure!(sf) === false
end

@testset "log-axis tick labels are estimated as plotly writes them" begin
	# plotly.js 2.35.2 formatLog: "10^-15" at 1.25 font sizes (power), "1e-15"
	# (e), "100µ" (SI/B past 10^±minexponent), the plain number otherwise.
	chars = _SFN._fin_log_label_chars
	@test chars(-15, "power", 3.0) == 6 && chars(0, "power", 3.0) == 2 && chars(1, "power", 3.0) == 3
	@test chars(2, "power", 3.0) == 4
	@test chars(-15, "e", 3.0) == 5 && chars(2, "E", 3.0) == 3
	@test chars(-4, "B", 3.0) == 4 && chars(-3, "B", 3.0) == 5 && chars(-16, "SI", 3.0) == 6
	@test chars(-4, "B", 5.0) == 6
	@test chars(-15, "none", 3.0) == 17
	axis = Dict{Symbol, Any}(:exponentformat => "power")
	@test _SFN._fin_tick_chars(axis, -15.7, -0.6, 300.0, true, true) == 6
	# A d3 format writes plain numbers; plotly's default format is "B".
	@test _SFN._fin_tick_chars(Dict{Symbol, Any}(:tickformat => ".1e"), -15.7, -0.6, 300.0, true, true) == 18
	@test _SFN._fin_tick_chars(Dict{Symbol, Any}(), -14.7, -4.2, 300.0, true, true) == 4
	@test _SFN._fin_tick_chars(Dict{Symbol, Any}(), -15.7, -4.2, 300.0, true, true) == 6
	# Renderer: the estimate covers the drawn labels without running far past them.
	f = plot_scatter(1:15, 10.0 .^ -(1:15); yscale = "log")
	info = _sfn_render(f)
	if info === nothing
		@test_skip "renderer unavailable"
	else
		layout = f.layout
		accs = _SFN._fin_collect_axes(f)
		axis = layout.fields[:yaxis]
		tickfont = _SFN._fin_mapping_font_size(axis, :tickfont, _SFN._fin_font_size(layout))
		lo, hi = _SFN._fin_shown_range(layout, :yaxis, accs)
		estimate = _SFN._fin_tick_chars(axis, lo, hi, 300.0, true, true) * 0.6 * tickfont
		drawn = info["axes"]["xaxis"]["offset"] - info["axes"]["yaxis"]["labels_left"]
		@test drawn <= estimate + _SFN._fin_tick_len(axis) + 2
		@test estimate <= drawn + 20
	end
end

@testset "a map's colorbar margin is reserved before plotly draws (Z49)" begin
	fig = plot_choropleth(["France", "Germany", "Spain"], [1.0, 2.0, 3.0]; scope = "europe", legend = "Regions")
	plot_scattergeo!(fig, [2.35, 13.40], [48.86, 52.52]; legend = "cities")
	plan = _SFN._room_plan(fig)
	@test haskey(plan.areas, :geo)
	requests = [r for r in plan.requests if r.owner === :colorbar]
	@test length(requests) == 1 && !requests[1].margin_pushed
	margin = _sfn_fields(fig.layout.fields[:margin])
	by_area, order, _ = _SFN._fin_collect_bars(fig, Any[])
	width = _SFN._fin_bar_width(fig.layout, by_area[order[1]][1], 390.0)
	@test margin[:r] >= width + _SFN._FIN_AUTOMARGIN_EXTRA
	@test _SFN._finalize_figure!(fig) === false
	# Cartesian bars still leave the margin to plotly's automargin.
	h = plot_heatmap(rand(4, 4))
	@test all(r -> r.margin_pushed, _SFN._room_plan(h).requests)
end

@testset "renderer: bars past a twin axis; grid titles (Z32, Z20)" begin
	f = plot_scatter(1:10, rand(10); legend = "line")
	plot_histogram2d!(f, randn(400) .* 2 .+ 5, randn(400) .* 2 .+ 5; secondary_y = true)
	ylabel!(f, "twin title"; secondary_y = true)
	info = _sfn_render(f; bars = 1)
	if info === nothing
		@test_skip "renderer unavailable"
	else
		bar = only(info["colorbars"])
		@test bar["x0"] >= info["axes"]["yaxis2"]["labels_right"] + 2
		@test bar["labels_right"] <= 700
		sf = subplots(2, 2; sync = false, x_title = "Shared x title", y_title = "Shared y title (units)")
		for r in 1:2, c in 1:2
			plot_scatter!(sf, 1:10, 1000 .* (1:10); row = r, col = c)
		end
		info = _sfn_render(sf)
		titles = info["annotations"]
		ybox = only(a["box"] for a in titles if occursin("Shared y", a["text"]))
		xbox = only(a["box"] for a in titles if occursin("Shared x", a["text"]))
		@test ybox[1] >= 0 && ybox[3] <= minimum(info["axes"][k]["labels_left"] for k in ("yaxis", "yaxis3"))
		@test xbox[4] <= 500 && xbox[2] >= maximum(info["axes"][k]["labels_bottom"] for k in ("xaxis3", "xaxis4"))
	end
end

end

@testset "D13/D16: glyphs without a field are padded on both sides; with one they stay tight" begin
	pad(lo, hi) = _SFN._FIN_OVERLAY_PAD * (hi - lo)
	alone = plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0])
	for (axis, coords) in ((:xaxis, :x), (:yaxis, :y))
		lo, hi = extrema(filter(!isnothing, alone.data[1].fields[coords]))
		# The drawn extent (arrowheads included), padded on both sides.
		clip = _sfn_clip(alone, axis)
		@test clip !== nothing && clip[1] < lo - 0.5 * pad(lo, hi) && clip[2] > hi + 0.5 * pad(lo, hi)
	end
	free = plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0]; equalar = false)
	lo, hi = extrema(filter(!isnothing, free.data[1].fields[:x]))
	@test _sfn_clip(free, :xaxis) == (lo - pad(lo, hi), hi + pad(lo, hi))
	@test _SFN._finalize_figure!(free) === false
	# A later trace widens the view; a heatmap under the glyphs makes them
	# anchors again: the axes are tight on the field.
	f = plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y))
	plot_quiver!(f, [0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0])
	@test _sfn_clip(f, :xaxis) == _SFN_XE && _sfn_clip(f, :yaxis) == _SFN_YE
end

# ---------------------------------------------------------------------------
# Wave 6
# ---------------------------------------------------------------------------

# Drawn boxes (px, [left, top, right, bottom]) of the y title and the tick
# labels of every Cartesian axis of `p` in a hidden window at its own size;
# `nothing` when the renderer cannot start.
const _SFN_TITLE_JS = raw"""
(() => {
  const gd = document.getElementById(__DIV__);
  if (!gd || !gd._fullLayout || !gd._fullLayout._size) return null;
  const root = gd.getBoundingClientRect();
  const box = els => { let b = null; for (const t of els) { const r = t.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) continue;
    const q = [r.left - root.left, r.top - root.top, r.right - root.left, r.bottom - root.top];
    b = b === null ? q : [Math.min(b[0], q[0]), Math.min(b[1], q[1]), Math.max(b[2], q[2]), Math.max(b[3], q[3])]; } return b; };
  const out = {axes: {}};
  for (const k of Object.keys(gd._fullLayout).filter(k => /^[xy]axis\d*$/.test(k))) {
    const id = k.replace('axis', '');
    out.axes[k] = {ticks: box(gd.querySelectorAll('g.' + id + 'tick text')), title: box(gd.querySelectorAll('.g-' + id + 'title text'))};
  }
  return JSON.stringify(out);
})()
"""

function _sfn_measure_titles(p::Plot)
	sp = try
		to_syncplot(p; show = false)
	catch err
		@warn "sci_finalize: the renderer could not start; renderer checks are skipped" exception = (err, catch_backtrace())
		return nothing
	end
	try
		backend = _SFN._syncplot_backend(sp)
		script = replace(_SFN_TITLE_JS, "__DIV__" => _SFN._json_js(sp.divid))
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

@testset "V1: a wrapped y title keeps its standoff from the tick labels (tight export, 3-4 lines)" begin
	# The break is a bare <br> (plotly.js counts the extra lines of a title
	# with a greedy regex that sees `<br />` ... `<br />` as one tag).
	@test endswith(_SFN._FIN_WRAP_BREAK, "<br>") && !occursin("/", _SFN._FIN_WRAP_BREAK)
	@test _SFN._fin_wrap_line("aa bb cc", 5) == "aa bb" * _SFN._FIN_WRAP_BREAK * "cc"
	@test count("<br", _SFN._fin_wrap_line("aaa bbb ccc ddd eee", 3)) == 4
	text = "a fairly long y-axis label that matplotlib would split"
	for (tight, cols) in ((true, 1), (false, 1))
		with_style(PlotStyle(; font_family = "DejaVu Sans, Arial, sans-serif", fontsize = 8 * 96 / 72,
				spines = :open, grid = false)) do
			sf = subplots(1, 2; sync = false, horizontal_spacing = 0.14)
			x = range(0, 1; length = 20)
			plot_scatter!(sf, x, x .^ 2; row = 1, col = 1)
			plot_scatter!(sf, x, sqrt.(x); row = 1, col = 2)
			ylabel!(sf, text; row = 1, col = 1)
			xlabel!(sf, "x"; row = 1, col = 1)
			figsize!(sf, 153, 60; units = :mm)
			W, H = sf.plot.layout.fields[:width], sf.plot.layout.fields[:height]
			c = if tight
				q = _SFN._clone_plot_model(sf.plot)
				tight_layout!(q)
				_SFN._finalize_figure!(q; size = (W, H))
				q
			else
				_SFN._finalize_export_copy(sf.plot, (width = W, height = H))
			end
			title = _sfn_fields(_sfn_fields(c.layout.fields[:yaxis])[:title])
			@test count(_SFN._FIN_LINE_BREAK, title[:text]) >= (tight ? 2 : 1)
			info = _sfn_measure_titles(c)
			info === nothing && return
			a = info["axes"]["yaxis"]
			# Standoff 10 px (plotly's own base gap for one line), the figure's
			# left edge is not crossed.
			@test a["ticks"][1] - a["title"][3] >= 8
			@test a["title"][1] >= -0.5
		end
	end
end

@testset "Q18: cells of one colour axis give up the same room for a bar between grid cells" begin
	xs = collect(range(-2, 2; length = 20)); ys = collect(range(-2, 2; length = 20))
	Z = [exp(-(x^2 + y^2)) * cos(2x) for y in ys, x in xs]
	sf = subplots(1, 3; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene") Spec()])
	for c in 1:2
		plot_surface!(sf, xs, ys, Z .* c; row = 1, col = c, xlabel = "x", ylabel = "y", zlabel = "z",
			shared_coloraxis = true, crange = (-2, 2))
	end
	plot_scatter!(sf, xs, Z[10, :]; row = 1, col = 3)
	figsize!(sf, 900, 350)
	layout = sf.plot.layout
	d1 = _SFN._layout_subplot_domain(layout, :scene)
	d2 = _SFN._layout_subplot_domain(layout, :scene2)
	w1, w2 = d1[1][2] - d1[1][1], d2[1][2] - d2[1][1]
	@test w1 ≈ w2 atol = 1e-9
	grid = _SFN._plotlysupply_subplot_layout(layout.subplots)
	# Narrower than the grid cell (the bar sits in the gap before cell 3), the
	# first at the cell's left edge; D17: the columns give up the room alike,
	# so the second starts later than its grid cell.
	gw = _SFN._layout_subplot_domain(grid, :scene)
	@test w1 < gw[1][2] - gw[1][1] - 1e-3
	@test d1[1][1] ≈ gw[1][1] atol = 1e-9
	@test d2[1][1] >= _SFN._layout_subplot_domain(grid, :scene2)[1][1] - 1e-9
	# the bar is right of the second scene, left of the third cell
	bar = _sfn_fields(_sfn_fields(layout.fields[:coloraxis])[:colorbar])
	@test d2[1][2] < bar[:x] < _SFN._layout_axis_domain(layout, :xaxis)[1]
	@test _SFN._finalize_figure!(sf) === false
	# The bar leaves: both give the room back.
	relayout!(sf.plot; coloraxis_showscale = false)
	_SFN._finalize_figure!(sf)
	# (the bar is gone from the plan only with the coloraxis; either both are back or both stay equal)
	e1 = _SFN._layout_subplot_domain(layout, :scene); e2 = _SFN._layout_subplot_domain(layout, :scene2)
	@test (e1[1][2] - e1[1][1]) ≈ (e2[1][2] - e2[1][1]) atol = 1e-9
	# At the paper edge the bar goes to the margin: no cell is narrowed for it.
	sg = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene")])
	for c in 1:2
		plot_surface!(sg, xs, ys, Z .* c; row = 1, col = c, shared_coloraxis = true, crange = (-2, 2))
	end
	figsize!(sg, 800, 400)
	f1 = _SFN._layout_subplot_domain(sg.plot.layout, :scene)
	f2 = _SFN._layout_subplot_domain(sg.plot.layout, :scene2)
	@test (f1[1][2] - f1[1][1]) ≈ (f2[1][2] - f2[1][1]) atol = 1e-9
end

@testset "Q26: a title added later to a polar figure under a small style margin gets its margin" begin
	th = collect(0:10:350)
	r = 1 .+ 0.3 .* cos.(deg2rad.(3 .* th))
	with_style(:ieee) do
		f = plot_scatterpolar(th, r)
		m0 = _sfn_fields(f.layout.fields[:margin])
		@test m0[:t] == m0[:l]                                  # no title yet: one label of room
		title!(f, "A polar pattern with a long title")
		m1 = _sfn_fields(f.layout.fields[:margin])
		root = _SFN._tight_root_font_size(k -> get(f.layout.fields, k, nothing))
		want = ceil(1.2 * root + 8) + ceil(_SFN._tight_title_height(f.layout.fields[:title], k -> get(f.layout.fields, k, nothing), root)) + 4
		@test m1[:t] >= want - 1e-9
		@test m1[:l] == m0[:l] && m1[:b] == m0[:b] && m1[:r] == m0[:r]
		@test _SFN._finalize_figure!(f) === false
		# A smaller title does not shrink it again (margins only grow).
		title!(f, "T")
		@test _sfn_fields(f.layout.fields[:margin])[:t] >= m1[:t]
	end
	# Larger tick fonts after construction grow every side (the angular
	# labels' own font: the style sets it, so a larger figure font alone
	# leaves them as they are).
	with_style(:ieee) do
		g = plot_scatterpolar(th, r)
		m0 = _sfn_fields(g.layout.fields[:margin])
		relayout!(g; polar_angularaxis_tickfont_size = 30)
		_SFN._finalize_figure!(g)
		m1 = _sfn_fields(g.layout.fields[:margin])
		@test all(m1[s] > m0[s] for s in (:l, :r, :b, :t))
	end
	# No margin of its own (plotly's generous default): nothing is written.
	h = plot_scatterpolar(th, r; title = "Long title here")
	@test !haskey(h.layout.fields, :margin) || !haskey(_sfn_fields(h.layout.fields[:margin]), :t) ||
		_sfn_fields(h.layout.fields[:margin])[:t] >= 60
end

@testset "Q38: figsize! on a figure with content re-solves the room for the new size" begin
	build() = with_style(:ieee) do
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, 1:3, 1:3; row = 1, col = 1, xlabel = "x", ylabel = "y")
		plot_scatter!(sf, 1:3, 1:3; row = 1, col = 2, xlabel = "x", ylabel = "y")
		sf
	end
	sf = build()
	narrow = _SFN._layout_axis_domain(sf.plot.layout, :xaxis2)
	@test narrow[1] > 0.6                    # the y title and labels took room in a 3.5 in figure
	figsize!(sf, :ieee; columns = 2, aspect = 0.38)
	sized_first = with_style(:ieee) do
		g = subplots(1, 2; sync = false)
		figsize!(g, :ieee; columns = 2, aspect = 0.38)
		plot_scatter!(g, 1:3, 1:3; row = 1, col = 1, xlabel = "x", ylabel = "y")
		plot_scatter!(g, 1:3, 1:3; row = 1, col = 2, xlabel = "x", ylabel = "y")
		g
	end
	# The gap widened at the old size is given back: same as sizing first.
	for k in (:xaxis, :xaxis2)
		@test collect(_SFN._layout_axis_domain(sf.plot.layout, k)) ≈ collect(_SFN._layout_axis_domain(sized_first.plot.layout, k))
	end
	@test _SFN._layout_axis_domain(sf.plot.layout, :xaxis2)[1] ≈ 0.55 atol = 1e-9
	@test !haskey(sf.plot.layout.fields, :meta) || !haskey(_sfn_fields(sf.plot.layout.fields[:meta]), Symbol("plotlysupply:room"))
	@test _SFN._finalize_figure!(sf) === false
	# And back to a column: the room is taken again.
	figsize!(sf, :ieee; columns = 1, aspect = 0.75)
	@test collect(_SFN._layout_axis_domain(sf.plot.layout, :xaxis2)) ≈ collect(narrow) atol = 1e-6
	@test _SFN._finalize_figure!(sf) === false
	# A domain the user narrowed is theirs and survives a resize.
	h = build()
	relayout!(h.plot; xaxis2_domain = [0.8, 1.0])
	figsize!(h, :ieee; columns = 2, aspect = 0.38)
	@test collect(_SFN._layout_axis_domain(h.plot.layout, :xaxis2)) ≈ [0.8, 1.0]
end

# Boxes (px) of the annotations of `p` once their math has rendered.
const _SFN_ANN_JS = raw"""
(() => {
  const gd = document.getElementById(__DIV__);
  if (!gd || !gd._fullLayout || !gd._fullLayout._size) return null;
  const root = gd.getBoundingClientRect();
  const out = {W: root.width, ann: []};
  for (const g of gd.querySelectorAll('g.annotation')) {
    const r = g.getBoundingClientRect();
    out.ann.push({text: g.textContent, math: g.querySelectorAll('.annotation-text-math-group, g[class*=math]').length,
      left: r.left - root.left, right: r.right - root.left, top: r.top - root.top, bottom: r.bottom - root.top, w: r.width});
  }
  return JSON.stringify(out);
})()
"""

function _sfn_annotation_boxes(p::Plot)
	sp = try
		to_syncplot(p; show = false)
	catch err
		@warn "sci_finalize: the renderer could not start; renderer checks are skipped" exception = (err, catch_backtrace())
		return nothing
	end
	try
		backend = _SFN._syncplot_backend(sp)
		script = replace(_SFN_ANN_JS, "__DIV__" => _SFN._json_js(sp.divid))
		for _ in 1:400
			raw = Base.invokelatest(() -> backend.run(sp.window, script))
			if !(raw === nothing || raw == "null")
				d = JSON.parse(String(raw))
				!isempty(d["ann"]) && all(a -> a["w"] > 1 && a["math"] > 0, d["ann"]) && return d
			end
			sleep(0.05)
		end
		return nothing
	finally
		close(sp)
	end
end

@testset "Q28: a math colorbar title is not clipped by the right figure edge (3.5 in, 7.16 in)" begin
	x = collect(range(0, 1; length = 24)); y = collect(range(0, 1; length = 24))
	Z = [sin(3a) * cos(3b) for a in x, b in y]
	for cols in (1, 2), title in (raw"$|E_z|^2$ (V$^2$/m$^2$)", raw"$\mathrm{Re}\,\epsilon_{\mathrm{eff}}(\omega)$")
		with_style(:ieee) do
			f = plot_heatmap(x, y, Z; colorbar_title = title, colorbar_title_side = :right, xlabel = "x", ylabel = "y")
			figsize!(f, :ieee; columns = cols, aspect = 0.75)
			W = f.layout.fields[:width]; H = f.layout.fields[:height]
			@test W ≈ (cols == 1 ? 3.5 : 7.16) * 96 atol = 1e-6
			@test _SFN._finalize_figure!(f) === false
			# The margin holds the title: its estimate is inside the figure.
			@test _sfn_fields(f.layout.fields[:margin])[:r] > 50
			c = _SFN._finalize_export_copy(f, (width = W, height = H))
			info = _sfn_annotation_boxes(c)
			info === nothing && return
			for a in info["ann"]
				@test a["right"] <= info["W"] - 0.5
				@test a["left"] >= 0
			end
		end
	end
end

# ---------------------------------------------------------------------------
# Wave 7 (layout-engine): D17 band solve, L11 compression, L7 wrap record
# ---------------------------------------------------------------------------

# Px plot box (x0, x1, y0, y1) of each SubplotFigure cell in `cells`.
function _sfn_grid_boxes(sf, info, cells)
	out = Dict{Tuple{Int, Int}, NTuple{4, Float64}}()
	for (r, c) in cells
		t = _SFN._cell_target(sf; row = r, col = c, who = "test")
		out[(r, c)] = Float64.(_sfn_box(info, t.xkey, t.ykey))
	end
	return out
end

# D17: the cells of each column share their left and right px edges, those
# of each row their top and bottom ones, and the column widths (row heights)
# divided by their ratios agree, all within `tol` px. `spans` lists a
# spanning cell with the columns it covers.
function _sfn_check_grid(sf, info, rows, cols; wr = ones(length(cols)), spans = (), tol = 0.5)
	cells = unique(vcat(rows..., cols..., [s[1] for s in spans]))
	b = _sfn_grid_boxes(sf, info, cells)
	for col in cols, cell in col[2:end]
		@test abs(b[cell][1] - b[col[1]][1]) <= tol
		@test abs(b[cell][2] - b[col[1]][2]) <= tol
	end
	for row in rows, cell in row[2:end]
		@test abs(b[cell][3] - b[row[1]][3]) <= tol
		@test abs(b[cell][4] - b[row[1]][4]) <= tol
	end
	w = [(b[col[1]][2] - b[col[1]][1]) / wr[i] for (i, col) in enumerate(cols)]
	h = [b[row[1]][4] - b[row[1]][3] for row in rows]
	@test maximum(w) - minimum(w) <= tol
	@test maximum(h) - minimum(h) <= tol
	@test all(>(5), w) && all(>(5), h)
	for (cell, (c1, c2)) in spans
		@test abs(b[cell][1] - b[cols[c1][1]][1]) <= tol
		@test abs(b[cell][2] - b[cols[c2][1]][2]) <= tol
	end
	return b
end

@testset "D17: the plot areas of a regular grid stay equal and aligned (renderer)" begin
	x = collect(range(0, 1; length = 30))
	Z = [sin(0.4i) * cos(0.3j) for i in 1:10, j in 1:10]
	g(r, c) = [(i, j) for i in 1:r, j in 1:c]
	rows_of(r, c) = [[(i, j) for j in 1:c] for i in 1:r]
	cols_of(r, c) = [[(i, j) for i in 1:r] for j in 1:c]
	configs = [
		("1x2 long y titles", () -> begin
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, x, x .^ 2; row = 1, col = 1, xlabel = "Hole contrast",
				ylabel = "Normalised transmitted power through the split infrared channel")
			plot_scatter!(sf, x, sqrt.(x); row = 1, col = 2, xlabel = "Hole contrast", ylabel = "power")
			sf
		end, rows_of(1, 2), cols_of(1, 2), ones(2), ()),
		("2x2 legend on top of (1,1)", () -> begin
			sf = subplots(2, 2; sync = false)
			for r in 1:2, c in 1:2
				plot_scatter!(sf, x, x .^ (r + c); row = r, col = c, xlabel = "x", ylabel = "y$r$c", legend = "s$r$c")
			end
			set_legend!(sf; row = 1, col = 1, position = :outside_top)
			sf
		end, rows_of(2, 2), cols_of(2, 2), ones(2), ()),
		("2x3 with colorbar cells", () -> begin
			sf = subplots(2, 3; sync = false)
			for r in 1:2, c in 1:3
				if (r + c) % 2 == 0
					plot_heatmap!(sf, Z; row = r, col = c, xlabel = "x", ylabel = "y")
				else
					plot_scatter!(sf, x, x; row = r, col = c, xlabel = "x", ylabel = "y")
				end
			end
			sf
		end, rows_of(2, 3), cols_of(2, 3), ones(3), ()),
		("3x1 with a panel title", () -> begin
			sf = subplots(3, 1; sync = false)
			for r in 1:3
				plot_scatter!(sf, x, x; row = r, col = 1, xlabel = "time (s)", ylabel = "y$r")
			end
			title!(sf, "(a)"; row = 2, col = 1)
			sf
		end, rows_of(3, 1), cols_of(3, 1), ones(1), ()),
		("spanning top row", () -> begin
			sf = subplots(2, 2; sync = false, specs = [Spec(colspan = 2) missing; Spec() Spec()])
			plot_scatter!(sf, x, x; row = 1, col = 1, ylabel = "span")
			plot_heatmap!(sf, Z; row = 2, col = 1, ylabel = "left")
			plot_scatter!(sf, x, x; row = 2, col = 2, ylabel = "right")
			sf
		end, [[(1, 1)], [(2, 1), (2, 2)]], [[(2, 1)], [(2, 2)]], ones(2), (((1, 1), (1, 2)),)),
		("width_ratios 2:1", () -> begin
			sf = subplots(1, 2; sync = false, width_ratios = [2, 1])
			plot_heatmap!(sf, Z; row = 1, col = 1, ylabel = "a")
			plot_scatter!(sf, x, x; row = 1, col = 2, ylabel = "b")
			sf
		end, rows_of(1, 2), cols_of(1, 2), [2.0, 1.0], ()),
		("legend below (1,2)", () -> begin
			sf = subplots(2, 2; sync = false)
			for r in 1:2, c in 1:2
				plot_scatter!(sf, x, x .* c; row = r, col = c, legend = "a$r$c")
				plot_scatter!(sf, x, x .* r; row = r, col = c, legend = "b$r$c")
			end
			set_legend!(sf; row = 1, col = 2, position = :outside_bottom)
			sf
		end, rows_of(2, 2), cols_of(2, 2), ones(2), ()),
		("shared axes and a bar", () -> begin
			sf = subplots(2, 2; sync = false, shared_xaxes = true, shared_yaxes = true)
			for r in 1:2, c in 1:2
				plot_scatter!(sf, x, x .* c; row = r, col = c, xlabel = r == 2 ? "x" : "", ylabel = c == 1 ? "y" : "")
			end
			plot_heatmap!(sf, Z; row = 1, col = 2)
			sf
		end, rows_of(2, 2), cols_of(2, 2), ones(2), ()),
	]
	for (name, build, rows, cols, wr, spans) in configs
		for size in (:default, :ieee1, :ieee2)
			sf = size === :default ? build() : with_style(build, :ieee)
			size === :ieee2 && figsize!(sf, :ieee; columns = 2)
			@test _SFN._finalize_figure!(sf) === false
			W = round(Int, get(sf.plot.layout.fields, :width, 700))
			H = round(Int, get(sf.plot.layout.fields, :height, 500))
			info = _sfn_render(sf; width = W, height = H)
			info === nothing && break
			@testset "$name at $size ($W x $H)" begin
				_sfn_check_grid(sf, info, rows, cols; wr = wr, spans = spans)
			end
		end
	end
end

@testset "L11: a grid of equal-aspect cells drops its blank band; compress = false keeps it" begin
	Z = [sin(0.4i) * cos(0.3j) for i in 1:12, j in 1:12]
	function pair(; kw...)
		sf = subplots(1, 2; sync = false, kw...)
		for c in 1:2
			plot_heatmap!(sf, Z; row = 1, col = c, equalar = true, xlabel = "x", ylabel = "y")
		end
		sf
	end
	sf = pair()
	l = sf.plot.layout
	# No size given: the free height loses the blank rows the square cells
	# leave in a 700 x 500 page; the width stays.
	@test l.fields[:width] == 700
	@test l.fields[:height] < 480
	@test _SFN._finalize_figure!(sf) === false
	# compress = false: the page and the centred cells stay.
	kept = pair(; compress = false)
	@test get(kept.plot.layout.fields, :height, 500) == 500
	@test _SFN._fin_compress_grid(kept.plot.layout) === false
	@test _SFN._finalize_figure!(kept) === false
	# A user size is never changed.
	u = pair()
	figsize!(u, 640, 480)
	@test u.plot.layout.fields[:width] == 640 && u.plot.layout.fields[:height] == 480
	@test _SFN._finalize_figure!(u) === false
	# A journal width is kept; the height adapts.
	with_style(:ieee) do
		j = pair()
		W, H = _SFN._style_default_figure_size()
		@test j.plot.layout.fields[:width] == round(Int, W)
		@test j.plot.layout.fields[:height] < H
		@test _SFN._finalize_figure!(j) === false
	end
	# Rendered: the square boxes fill the compressed row and the shared bar
	# serves exactly their block: `len = 1` spans it, the default 0.75 of it,
	# centred on it (its title drawn inside that length).
	for len in (1.0, 0.75)
		s = pair()
		shared_colorbar!(s; title = "u", len = len)
		@test _SFN._finalize_figure!(s) === false
		W = round(Int, s.plot.layout.fields[:width]); H = round(Int, s.plot.layout.fields[:height])
		info = _sfn_render(s; width = W, height = H, bars = 1)
		info === nothing && break
		b = _sfn_grid_boxes(s, info, [(1, 1), (1, 2)])
		for cell in values(b)
			@test abs((cell[2] - cell[1]) - (cell[4] - cell[3])) <= 1
		end
		bar = only(info["colorbars"])
		box = b[(1, 1)]
		@test abs((bar["top"] + bar["bottom"]) / 2 - (box[3] + box[4]) / 2) <= 2
		@test abs((bar["bottom"] - bar["top"]) - len * (box[4] - box[3])) <= 3
	end
end

@testset "L7: the wrap is recorded in layout.meta; the title carries no marker" begin
	long = "Normalised transmitted power through the split infrared channel"
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, 1:10, collect(1.0:10.0); row = 1, col = 1, xlabel = "Hole contrast")
	plot_scatter!(sf, 1:10, collect(1.0:10.0); row = 1, col = 2)
	ylabel!(sf, long; row = 1, col = 1)
	figsize!(sf, 336, 200)
	text = _sfn_fields(_sfn_axis(sf, :yaxis)[:title])[:text]
	@test count("<br>", text) >= 2                       # three lines or more
	@test !occursin('​', text) && !occursin("<br />", text)
	@test replace(text, "<br>" => " ") == long
	@test _SFN._fin_wrap_record(sf.plot.layout)["yaxis"] == (long, text)
	@test _SFN._finalize_figure!(sf) === false
	# Re-joined on a larger figure; the record goes with the wrap.
	figsize!(sf, 1400, 900)
	@test _sfn_fields(_sfn_axis(sf, :yaxis)[:title])[:text] == long
	@test !haskey(_SFN._fin_wrap_record(sf.plot.layout), "yaxis")
	@test _SFN._finalize_figure!(sf) === false
	# Wrapped again, then changed by the user: theirs, the record dropped.
	figsize!(sf, 336, 200)
	@test haskey(_SFN._fin_wrap_record(sf.plot.layout), "yaxis")
	ylabel!(sf, "first<br>second"; row = 1, col = 1)
	@test _sfn_fields(_sfn_axis(sf, :yaxis)[:title])[:text] == "first<br>second"
	@test !haskey(_SFN._fin_wrap_record(sf.plot.layout), "yaxis")
	@test _SFN._finalize_figure!(sf) === false
	# A user break inside a long title survives the wrap and the re-join.
	ylabel!(sf, "first<br>" * long; row = 1, col = 1)
	@test startswith(_sfn_fields(_sfn_axis(sf, :yaxis)[:title])[:text], "first<br>")
	figsize!(sf, 1400, 900)
	@test _sfn_fields(_sfn_axis(sf, :yaxis)[:title])[:text] == "first<br>" * long
	# A record read back from JSON (String keys) is understood.
	figsize!(sf, 336, 200)
	q = Layout()
	q.fields[:meta] = JSON.parse(JSON.json(sf.plot.layout.fields[:meta]))
	@test _SFN._fin_wrap_record(q)["yaxis"][1] == "first<br>" * long
end

@testset "L7: a wrapped title keeps its gap and leaves no U+200B in the exports" begin
	long = "Normalised transmitted power through the split infrared channel"
	f = with_style(:ieee) do
		g = plot_scatter(collect(0:0.1:1), collect(0:0.1:1); xlabel = "Hole contrast", ylabel = long)
		figsize!(g, 168, 168)
		g
	end
	@test count("<br>", _sfn_fields(f.layout.fields[:yaxis][:title])[:text]) >= 2
	dir = mktempdir()
	svg = joinpath(dir, "w.svg"); pdf = joinpath(dir, "w.pdf")
	savefig(f, svg); savefig(f, pdf)
	@test !occursin('​', read(svg, String))
	tool = Sys.which("pdftotext")
	if tool !== nothing
		@test !occursin('​', read(`$tool $pdf -`, String))
	end
	@test _SFN._finalize_figure!(f) === false
end

@testset "settled after mutators of equal-aspect and overlay figures (fields-06, fields-07, docs-08)" begin
	_SFN._finalize_figure!(plot_scatter(1:2, 1:2))
	@test _SFN._FIN_FIT_ROUNDS == 4
	Z = [sin(0.4i) * cos(0.3j) for i in 1:9, j in 1:13]
	cases = [
		"xlabel!" => f -> xlabel!(f, "x (mm)"),
		"xrange!" => f -> xrange!(f, (2, 8)),
		"scatter with a legend" => f -> plot_scatter!(f, [2.0, 4.0], [3.0, 5.0]; legend = "probes"),
		"figsize!" => f -> figsize!(f, :ieee),
	]
	for (name, mutate!) in cases
		f = plot_heatmap(Z; equalar = true)
		mutate!(f)
		@test _SFN._finalize_figure!(f) === false
	end
	# axis_equal! fits its cell for the new aspect at once.
	f = plot_heatmap(Z)
	axis_equal!(f)
	@test _SFN._finalize_figure!(f) === false
	# An overlay with a legend beside a heatmap's bar under a journal style.
	g = range(-2, 2; length = 9)
	X = [a for a in g, b in g]; Y = [b for a in g, b in g]
	for style in (:ieee, :nature)
		with_style(style) do
			h = plot_heatmap(collect(g), collect(g), X .^ 2 .+ Y .^ 2)
			plot_quiver!(h, X, Y, -Y, X; legend = "F")
			@test _SFN._finalize_figure!(h) === false
		end
	end
	# figsize! leaves the colorbar ticks it implies written (style-06).
	h = plot_heatmap(1:20, 1:15, [sin(0.3i) + cos(0.2j) for i in 1:20, j in 1:15]; colorbar_title = "u")
	figsize!(h, 336, 227)
	@test _SFN._finalize_figure!(h) === false
	# The worst case of the fit loop needs no more than the cap.
	q = plot_quiver(X, Y, -Y, X; sizeref = 1.0, legend = "F", colorby = :magnitude, style = :triangle)
	@test _SFN._FIN_LAST_ROUNDS[] <= _SFN._FIN_FIT_ROUNDS
	@test _SFN._finalize_figure!(q) === false
	@test _SFN._FIN_LAST_ROUNDS[] == 1
end

@testset "a figure caption and a figure annotation settle (tm-caption, docs-07)" begin
	x = collect(range(0, 1; length = 20))
	for style in (:default, :ieee)
		with_style(style) do
			f = plot_scatter(x, [x, x .^ 2]; legend = ["a", "b"], xlabel = "x")
			set_legend!(f; position = :outside_bottom)
			annotate!(f, 0.5, 0.01, "Source: simulation"; coords = :figure, showarrow = false, anchor = :bottom)
			@test _SFN._finalize_figure!(f) === false
		end
	end
	sf = subplots(1, 2; sync = false)
	for c in 1:2
		plot_scatter!(sf, 1:5, [0.3, 0.1, 0.8, 0.5, 0.9]; legend = "data", color = "black", row = 1, col = c)
	end
	legend_entry!(sf, "model"; color = "crimson", dash = "dash")
	set_legend!(sf; position = :outside_bottom, ncols = 2, frame = false)
	title!(sf, "(a) Mesh"; row = 1, col = 1, align = :left, bold = true)
	title!(sf, "Study")
	annotate!(sf, 0.99, 0.01, "draft"; coords = :figure, showarrow = false)
	@test _SFN._finalize_figure!(sf) === false
	# Annotation lists that differ by a zero shift or by rounding draw the same.
	a = [attr(text = "c", x = 0.5, y = 0.01, yshift = -92.38)]
	@test _SFN._fin_same_annotations(a, [attr(text = "c", x = 0.5, y = 0.01, yshift = -92.3, xshift = 0)])
	@test !_SFN._fin_same_annotations(a, [attr(text = "c", x = 0.5, y = 0.01, yshift = -90.0)])
	@test !_SFN._fin_same_annotations(a, [attr(text = "d", x = 0.5, y = 0.01, yshift = -92.38)])
end

@testset "a bar over equal-aspect cells keeps its length (sharedcb-02)" begin
	Z = [sin(0.4i) * cos(0.3j) for i in 1:12, j in 1:10]
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, Z; row = 1, col = 1, equalar = true)
	plot_heatmap!(sf, Z; row = 1, col = 2, equalar = true)
	shared_colorbar!(sf; side = :bottom, title = "u")
	len = sf.plot.layout[:coloraxis][:colorbar][:len]
	for _ in 1:4
		@test _SFN._finalize_figure!(sf) === false
	end
	@test sf.plot.layout[:coloraxis][:colorbar][:len] == len
end

@testset "insets follow a host fitted for equal aspect (inset-01, axes-ticks-06)" begin
	θ = range(0, 2π; length = 200)
	Z = [sin(0.4i) * cos(0.3j) for i in 1:9, j in 1:13]
	# Hosts the fit sizes: a circle with fixed ranges, an equal-aspect field.
	build(order, host) = begin
		sf = subplots(1, 1; sync = false)
		figsize!(sf, 700, 400)
		if host === :circle
			plot_scatter!(sf, cos.(θ), sin.(θ); xrange = (-1.2, 1.2), yrange = (-1.2, 1.2))
			order === :before && axis_equal!(sf)
		else
			plot_heatmap!(sf, Z; equalar = order === :before)
		end
		inset!(sf, (0.6, 0.6, 0.35, 0.35))
		plot_scatter!(sf, 1:3, 1:3; inset = 1)
		order === :after && axis_equal!(sf)
		sf
	end
	for order in (:before, :after), kind in (:circle, :field)
		sf = build(order, kind)
		@test _SFN._finalize_figure!(sf) === false
		info = _sfn_render(sf; width = 700, height = 400)
		info === nothing && break
		hb = _sfn_box(info, :xaxis, :yaxis)
		t = _SFN._cell_target(sf; inset = 1, who = "test")
		box = _sfn_box(info, t.xkey, t.ykey)
		w = hb[2] - hb[1]; h = hb[4] - hb[3]
		# The host is drawn square-unit (fitted), not stretched over the cell.
		@test w < 700 - 100
		# (0.6, 0.6, 0.35, 0.35) of the drawn plot box (y from the bottom).
		@test abs(box[1] - (hb[1] + 0.6w)) <= 2
		@test abs(box[2] - (hb[1] + 0.95w)) <= 2
		@test abs(box[4] - (hb[4] - 0.6h)) <= 2
		@test abs(box[3] - (hb[4] - 0.95h)) <= 2
	end
end

@testset "a top math colorbar title gets room under the journal styles (threed-f02, vm-02)" begin
	xs = collect(range(-2, 2; length = 41)); ys = collect(range(-1, 1; length = 21))
	Z = [exp(-x^2 - 4y^2) for x in xs, y in ys]
	for style in (:ieee, :nature)
		with_style(style) do
			f = plot_heatmap(xs, ys, Z; colorbar_title = raw"$|E|$ (V/m)")
			@test _SFN._finalize_figure!(f) === false
			font = _SFN._fin_font_size(f.layout)
			# The margin holds the title above the bar's top end.
			@test _sfn_fields(f.layout.fields[:margin])[:t] >= _SFN._FIN_MATH_TITLE_H * font
			sf = subplots(1, 2; sync = false)
			plot_heatmap!(sf, xs, ys, Z; row = 1, col = 1, colorbar_title = raw"$|E_x|$")
			plot_heatmap!(sf, xs, ys, Z; row = 1, col = 2, colorbar_title = raw"$|E_y|$")
			title!(sf, "Field components")
			@test _SFN._finalize_figure!(sf) === false
			plan = _SFN._room_plan(sf)
			@test count(r -> r.side === :top && endswith(r.key, ":title"), plan.requests) == 2
		end
	end
end

@testset "relayout! takes the finalizer's updates as one Dict of paths (perf-01)" begin
	paths = _SFN._fin_property_paths(Dict{Symbol, Any}(:legend2_x => 1.0, :xaxis3_domain => [0.1, 0.2],
		:margin => Dict{Symbol, Any}(:l => 4), :margin_b => 30))
	@test paths[Symbol("legend2.x")] == 1.0
	@test paths[Symbol("xaxis3.domain")] == [0.1, 0.2]
	# A child of a container written whole goes into the container.
	@test paths[:margin] == Dict{Symbol, Any}(:l => 4, :b => 30)
	@test !haskey(paths, Symbol("margin.b"))
	p = plot_scatter(1:3, 1:3)
	relayout!(p, paths)
	@test p.layout[:legend2][:x] == 1.0 && p.layout[:margin][:b] == 30
	# A new grid shape compiles no relayout! method for its key set.
	sf = subplots(1, 3; sync = false)
	for c in 1:3
		plot_scatter!(sf, 1:3, 1:3; row = 1, col = c, legend = "s$c")
	end
	sf = subplots(2, 3; sync = false)
	t = @elapsed for r in 1:2, c in 1:3
		plot_scatter!(sf, 1:3, 1:3; row = r, col = c, legend = "s$r$c")
	end
	@test t < 1.5
end

_sfn_margin(fig, side) = _SFN._cmn_mapping_get(get(_sfn_plot(fig).layout.fields, :margin, nothing), side)

@testset "margins the room engine raised are given back (cbar-01, margin-01)" begin
	Z = [1.0 2 3; 4 5 6]
	for st in (:default, :ieee)
		with_style(st) do
			# The right margin of a grid without a bar.
			plain = subplots(1, 1; sync = false)
			plot_scatter!(plain, 1:3, 1:3; legend = "data")
			r0 = _sfn_margin(plain, :r)
			# A cell bar at the paper edge raises it (held for the inside
			# legend, `_lt_hold_pushed_margins!`; a bar alone is left to
			# plotly's automargin since its empty legend no longer counts,
			# layout-fuzz-01); moved below, it is given back.
			sf = subplots(1, 1; sync = false)
			plot_heatmap!(sf, Z)
			plot_scatter!(sf, [0.0, 1.0, 2.0], [0.0, 1.0, 1.0]; legend = "data")
			raised = _sfn_margin(sf, :r)
			@test raised > r0
			colorbar!(sf; side = :bottom)
			# Given back down to what the last x tick label at the right
			# paper edge needs (the heatmap's x range is known: its cell
			# edges), at once: a later finalize does not raise it again.
			plan = _SFN._room_plan(sf)
			tick = _SFN._fin_tick_overhang_px(sf.plot, _SFN._fin_collect_axes(sf.plot), plan.Wp, plan.W)
			@test _sfn_margin(sf, :r) == max(r0, ceil(tick)) < raised
			@test _sfn_margin(sf, :b) > _sfn_margin(plain, :b)
			@test _SFN._finalize_figure!(sf) === false
			# An outside legend raises it; moved inside, it is given back.
			lg = subplots(1, 2; sync = false)
			plot_scatter!(lg, 1:5, [1.0, 3, 2, 5, 4]; row = 1, col = 1, legend = "data")
			plot_scatter!(lg, 1:5, [2.0, 1, 4, 3, 5]; row = 1, col = 2, legend = "model")
			m0 = _sfn_margin(lg, :r)
			set_legend!(lg; position = :outside_right)
			@test _sfn_margin(lg, :r) > m0
			set_legend!(lg; position = :topleft)
			@test _sfn_margin(lg, :r) == m0
			@test _SFN._finalize_figure!(lg) === false
			@test _SFN._fin_meta_get(lg.plot.layout, _SFN._ROOM_MARGIN_KEY) === nothing
		end
	end
	# A margin the user set is theirs: kept when the bar leaves, never lowered.
	sf = subplots(1, 1; sync = false)
	plot_heatmap!(sf, Z)
	relayout!(sf.plot; margin_r = 120)
	colorbar!(sf; side = :bottom)
	@test _sfn_margin(sf, :r) == 120
	@test _SFN._finalize_figure!(sf) === false
	# The record survives a JSON round trip (String keys).
	sf = subplots(1, 1; sync = false)
	plot_heatmap!(sf, Z)
	plot_scatter!(sf, [0.0, 1.0, 2.0], [0.0, 1.0, 1.0]; legend = "data")
	rec = _SFN._room_margin_record(sf.plot.layout)
	@test haskey(rec, :r) && rec[:r][2] == _sfn_margin(sf, :r)
	meta = _SFN._symbol_dict(sf.plot.layout.fields[:meta])
	json = Dict{Any, Any}(String(_SFN._ROOM_MARGIN_KEY) => Dict{Any, Any}("r" => Any[rec[:r][1], rec[:r][2]]))
	q = Layout(); q.fields[:meta] = json
	@test _SFN._room_margin_record(q) == rec
end

@testset "decorations plotly does not push margins for get theirs (style-07, vm-19, vm-17, vm-18)" begin
	for st in (:publication, :ieee, :nature)
		with_style(st) do
			# Ternary: the default corner titles "Component A/B/C" are drawn.
			fig = plot_ternary([0.2, 0.3], [0.3, 0.3], [0.5, 0.4])
			m = fig.layout.fields[:margin]
			font = _SFN._fin_font_size(fig.layout)
			# The corner labels are drawn at each axis's own tick font (the
			# style's), else at the figure's.
			root = _SFN._tight_root_font_size(k -> get(fig.layout.fields, k, nothing))
			tick = 0.0
			for axis in (:aaxis, :baxis, :caxis)
				tick = max(tick, _SFN._fin_mapping_font_size(_SFN._cmn_mapping_get(fig.layout.fields[:ternary], axis), :tickfont, root))
			end
			title = _SFN._fin_mapping_font_size(_SFN._cmn_mapping_get(_SFN._cmn_mapping_get(fig.layout.fields[:ternary], :baxis), :title), :font, font)
			corner = ceil(_SFN._FIN_LINE_EM * title + 4)
			@test m[:b] >= ceil(1.2 * tick + 8) + corner
			@test m[:t] >= ceil(1.2 * tick + 8) + corner
			@test m[:r] >= ceil(_SFN._text_extent("Component C", title)[1] / 2 + 4)
			@test _SFN._finalize_figure!(fig) === false
			# An empty title draws nothing and takes no room (margins here
			# only grow: start from 1 px).
			bare = plot_ternary([0.2, 0.3], [0.3, 0.3], [0.5, 0.4])
			relayout!(bare; ternary_aaxis_title_text = "", ternary_baxis_title_text = "", ternary_caxis_title_text = "",
				margin_b = 1, margin_t = 1)
			_SFN._finalize_figure!(bare)
			@test bare.layout.fields[:margin][:b] == ceil(1.2 * tick + 8)
			@test _SFN._finalize_figure!(bare) === false
			# Parcoords: dimension titles above, range labels below, the first
			# axis' tick labels left of it.
			pc = plot_parcoords(["mass (kg)" => [1.2, 3.4, 2.2], "speed" => [10.0, 30.0, 20.0]])
			mp = pc.layout.fields[:margin]
			@test mp[:t] >= _SFN._FIN_PARCOORDS_TITLE_OFFSET + 4
			@test mp[:b] >= _SFN._FIN_PARCOORDS_EXTENT_OFFSET + 4
			@test mp[:l] >= ceil(_SFN._text_extent("mass (kg)", _SFN._fin_font_size(pc.layout))[1] / 2)
			@test _SFN._finalize_figure!(pc) === false
			# Angular gauge: room for the end labels, alike on both sides.
			g = plot_indicator(72; reference = 65, gauge_range = (0, 100), number_suffix = "%", title = "Availability")
			mg = g.layout.fields[:margin]
			@test mg[:l] == mg[:r] >= 12 + _SFN._text_extent("100", _SFN._fin_font_size(g.layout))[1]
			@test _SFN._finalize_figure!(g) === false
		end
	end
end

@testset "a free height fits an equal-aspect field to its journal column (vm-08)" begin
	r = range(1, 2; length = 13); th = range(0, pi; length = 41)
	X = [ri * cos(t) for ri in r, t in th]; Y = [ri * sin(t) for ri in r, t in th]
	C = [sin(3t) / ri for ri in r[1:end-1], t in th[1:end-1]]
	for st in (:ieee, :nature)
		fig = with_style(st) do
			plot_pcolormesh(X, Y, C; colorscale = "RdBu_r", cmid = 0, colorbar_title = "f", equalar = true, xlabel = "x", ylabel = "y")
		end
		W = fig.layout.fields[:width]; H = fig.layout.fields[:height]
		# The journal width is kept exactly; the height follows the field.
		@test W == journal_width(st; columns = 1, units = :px)
		@test _SFN._finalize_figure!(fig) === false
		info = _sfn_render(fig; width = round(Int, W), height = round(Int, H), bars = 1)
		info === nothing && break
		box = _sfn_box(info, :xaxis, :yaxis)
		w = box[2] - box[1]; h = box[4] - box[3]
		@test abs(w - 2h) <= 1.5
		# The box takes the width labels and bar leave (the old fit left a
		# 96 px box on a 336 px page), and the page holds it with its labels.
		@test w >= 0.55 * W
		bar = only(info["colorbars"])
		@test bar["labels_right"] <= W
		@test bar["y1"] - bar["y0"] <= h + 2
	end
end

@testset "a bar's room holds its title and every stacked bar (cbar-03, cbar-04)" begin
	# cbar-03: a top title wider than the bar and its labels.
	Z = [sin(0.5i) * cos(0.4j) for i in 1:20, j in 1:15]
	sf = subplots(1, 2; sync = false, width = 700, height = 300)
	plot_heatmap!(sf, Z; row = 1, col = 1, colorbar_title = "intensity (a.u.)")
	plot_scatter!(sf, 1:5, [1000.0, 2500, 3000, 2800, 3100]; row = 1, col = 2, ylabel = "counts", yrange = (0, 4000))
	plan = _SFN._room_plan(sf)
	bar = _sfn_bar(sf.plot.data[1])
	font = _SFN._fin_font_size(sf.plot.layout)
	title_right = bar[:x] * plan.Wp + _SFN._text_extent("intensity (a.u.)", font)[1]
	x2 = _SFN._layout_axis_domain(sf.plot.layout, :xaxis2)
	@test title_right <= x2[1] * plan.Wp - _SFN._room_label_px(plan.areas[:xaxis2].own[:left])
	@test _SFN._finalize_figure!(sf) === false
	# cbar-04: three bars of one cell stay out of the next one.
	Zc = [sin(0.5i) * cos(0.4j) for i in 1:12, j in 1:10]
	for st in (:aps, :ieee)
		with_style(st) do
			sf = subplots(1, 2; sync = false)
			plot_heatmap!(sf, Zc; row = 1, col = 1, colorbar_title = "u")
			plot_contour!(sf, Zc .^ 2; row = 1, col = 1, colorbar_title = "v")
			plot_contour!(sf, Zc .* 3; row = 1, col = 1, colorbar_title = "w")
			plot_scatter!(sf, 1:5, [1.0, 3, 2, 5, 4]; row = 1, col = 2)
			@test _SFN._finalize_figure!(sf) === false
			W = round(Int, sf.plot.layout.fields[:width]); H = round(Int, sf.plot.layout.fields[:height])
			info = _sfn_render(sf; width = W, height = H, bars = 3)
			info === nothing && return
			box2 = _sfn_box(info, :xaxis2, :yaxis2)
			@test length(info["colorbars"]) == 3
			# The last bar's tick labels end before cell 2's y tick labels.
			plan = _SFN._room_plan(sf)
			@test maximum(b["labels_right"] for b in info["colorbars"]) <=
				box2[1] - _SFN._room_label_px(plan.areas[:xaxis2].own[:left]) + 1
		end
	end
end

@testset "the last x tick label of a tight export is never cut; the tight margin stays otherwise" begin
	cases = (
		((0, 10), :default, true), ((0, 1000), :default, true), ((0, 9.3), :default, false),
		((0, 10), :ieee, true),
	)
	for (xr, st, at_end) in cases
		fig = with_style(st) do
			plot_scatter(collect(range(xr[1], xr[2]; length = 11)), collect(1.0:11.0); xrange = xr, xlabel = "x", ylabel = "y")
		end
		tight_layout!(fig)
		@test _SFN._finalize_figure!(fig) === false
		r = _sfn_margin(fig, :r)
		at_end ? (@test r > 4) : (@test r == 4)
		W = round(Int, something(get(fig.layout.fields, :width, nothing), 700))
		H = round(Int, something(get(fig.layout.fields, :height, nothing), 500))
		info = _sfn_render(fig; width = W, height = H)
		info === nothing && break
		@test info["axes"]["xaxis"]["labels_right"] <= W
	end
	# Explicit tick text at the right end: its own width counts.
	fig = plot_scatter(collect(0.0:10.0), collect(1.0:11.0); xrange = (0, 10))
	xticks!(fig, [0, 5, 10], ["0", "5", "10 units"])
	tight_layout!(fig)
	@test _SFN._finalize_figure!(fig) === false
	@test _sfn_margin(fig, :r) > 9
	info = _sfn_render(fig; width = 700, height = 500)
	info === nothing || @test info["axes"]["xaxis"]["labels_right"] <= 700
	# A tick label that ends inside the plot area leaves the margin alone.
	fig = plot_heatmap(collect(0.0:0.5:10.0), collect(0.0:0.5:4.0), [sin(a) * cos(b) for a in 0:0.5:10, b in 0:0.5:4])
	tight_layout!(fig)
	@test _sfn_margin(fig, :r) == 4
	# An equal-aspect box that ends near the paper edge, not at it: the label
	# overhangs less by the gap, measured on the domain the pass writes, and
	# the margin settles within the call (an :ieee pair alternated between 4
	# and 8 px; a :nature pair given a panel title stepped 6 -> 5 -> 4 px a
	# round, past the round cap).
	x = range(-1.0, 1.0; length = 21)
	y = range(-1.0, 1.0; length = 15)
	U = [exp(-(a^2 + b^2)) for a in x, b in y]
	for (st, titled) in ((:ieee, false), (:nature, false), (:nature, true))
		sf = with_style(st) do
			s = subplots(1, 2; sync = false)
			for j in 1:2
				plot_heatmap!(s, x, y, U; row = 1, col = j, equalar = true, showscale = false)
			end
			titled && title!(s, "(a)"; row = 1, col = 1)
			s
		end
		@test _SFN._finalize_figure!(sf) === false
		layout = sf.plot.layout
		W = round(Int, something(get(layout.fields, :width, nothing), 700))
		H = round(Int, something(get(layout.fields, :height, nothing), 500))
		info = _sfn_render(sf; width = W, height = H)
		info === nothing && continue
		@test info["axes"]["xaxis2"]["labels_right"] <= W
	end
end

@testset "a 3-D scene cell takes the whole slot of its row and column (L2)" begin
	xs = collect(range(-2, 2; length = 21)); ys = collect(range(-1, 1; length = 11))
	Z = [exp(-x^2 - 4y^2) for x in xs, y in ys]
	sf = subplots(2, 2; sync = false, specs = [Spec() Spec(kind = "scene"); Spec() Spec()])
	plot_scatter!(sf, xs, sin.(xs); row = 1, col = 1, xlabel = "x", ylabel = "amplitude (a.u.)")
	plot_surface!(sf, xs, ys, Z; row = 1, col = 2, showscale = false)
	plot_scatter!(sf, xs, cos.(xs); row = 2, col = 1, xlabel = "x", ylabel = "y")
	plot_scatter!(sf, xs, 1000 .* cos.(xs); row = 2, col = 2, xlabel = "x", ylabel = "counts")
	layout = sf.plot.layout
	plan = _SFN._room_plan(sf)
	scene = _SFN._layout_subplot_domain(layout, :scene)
	x1 = _SFN._layout_axis_domain(layout, :xaxis)
	x4 = _SFN._layout_axis_domain(layout, :xaxis3)
	# The plot area below gives up room on its left for its tick labels and
	# title; the scene, which draws its labels inside its domain, does not:
	# it starts where that room starts, the grid gap after column 1.
	@test x4[1] > scene[1][1] + 1 / plan.Wp
	@test scene[1][1] - x1[2] ≈ 0.1 atol = 1e-6
	@test scene[1][2] ≈ x4[2]
	# Its top is its row's top; it is as tall as its row's slot.
	@test scene[2][2] ≈ _SFN._layout_axis_domain(layout, :yaxis)[2]
	@test scene[2][1] <= _SFN._layout_axis_domain(layout, :yaxis)[1] + 1e-9
	@test _SFN._finalize_figure!(sf) === false
	# Scenes that gave up room for their own bars get their whole slots back
	# when one shared bar replaces them (mdd_slices), after every call settled.
	sf = subplots(1, 3; sync = false, specs = fill(Spec(kind = "scene"), 1, 3), horizontal_spacing = 0.02)
	figsize!(sf, 11.2, 3.4; units = :in)
	g = collect(range(0, 1; length = 6))
	for c in 1:3
		plot_surface!(sf, g, g, [sin(3a) * cos(2b) * c for a in g, b in g]; row = 1, col = c)
		title!(sf, "panel $c\nsecond line"; row = 1, col = c)
		@test _SFN._finalize_figure!(sf) === false
	end
	narrowed = _SFN._layout_subplot_domain(sf.plot.layout, :scene)[1]
	@test narrowed[2] < 0.32 - 1e-3
	shared_colorbar!(sf; title = "u", len = 0.7)
	for (key, slot) in ((:scene, (0.0, 0.32)), (:scene2, (0.34, 0.66)), (:scene3, (0.68, 1.0)))
		@test collect(_SFN._layout_subplot_domain(sf.plot.layout, key)[1]) ≈ collect(slot) atol = 1e-9
	end
	@test _SFN._finalize_figure!(sf) === false
end

@testset "panel labels above equal-aspect rows settle within the round cap (B1, B2)" begin
	# device_geometry: a label above the top cell needs a margin plotly does
	# not push; the margin shrinks the plot region, which moves the fitted
	# box, which changes what the label needs. Solved together in one round:
	# the call takes at most two rounds and leaves nothing for a next one.
	for st in (:default, :ieee)
		with_style(st) do
			sf = subplots(2, 1; sync = false, height_ratios = [1.1, 0.9])
			figsize!(sf, :ieee; columns = 2, aspect = 0.62)
			plot_scatter!(sf, Float64[], Float64[]; row = 1, col = 1, xrange = (-0.6, 5.3), yrange = (-0.3, 1.12),
				equalar = true)
			plot_scatter!(sf, [0.5, 1.5, 2.5], [0.25, 0.75, 0.5]; row = 2, col = 1, xrange = (0, 4), yrange = (0, 1),
				equalar = true, legend = "rects")
			xlabel!(sf, "x (um)"; row = 2, col = 1)
			ylabel!(sf, "y (um)"; row = 2, col = 1)
			panel_labels!(sf)
			@test _SFN._FIN_LAST_ROUNDS[] <= 2
			@test _SFN._finalize_figure!(sf) === false
			@test _SFN._FIN_LAST_ROUNDS[] == 1
			# The label sits on the top cell, its line inside the top margin.
			layout = sf.plot.layout
			top = _SFN._layout_axis_domain(layout, :yaxis)[2]
			labels = [_SFN._symbol_dict(a) for a in get(layout.fields, :annotations, Any[])
				if get(_SFN._symbol_dict(a), :name, "") == "plotlysupply:panel_label:1:1"]
			@test length(labels) == 1
			label = labels[1]
			@test label[:yref] == "paper" && label[:yanchor] == "bottom"
			@test label[:y] ≈ top atol = 1e-6
			t = _sfn_margin(sf, :t)
			Hp = layout.fields[:height] - t - _sfn_margin(sf, :b)
			@test (label[:y] - 1) * Hp + get(label, :yshift, 0) + 1.3 * _SFN._fin_font_size(layout) <= t
		end
	end
end

# ---------------------------------------------------------------------------
# Per-mutation cost (Q27, subplots owner (c))
# ---------------------------------------------------------------------------

@testset "cost: layout and key lookups answer like the copies they replaced" begin
	# `_layout_axis_domain` / `_layout_subplot_domain` read without copying the entry.
	l = Layout(xaxis = attr(domain = [0.1, 0.4]),
		scene = attr(domain = attr(x = [0.0, 0.5], y = [0.25, 1.0])), xaxis4 = attr(domain = [0.3]))
	l.fields[:yaxis2] = Dict{Any, Any}("domain" => (0.2, 0.9))      # a String-keyed mapping
	l.fields[:xaxis3] = nothing
	@test _SFN._layout_axis_domain(l, :xaxis) == (0.1, 0.4)
	@test _SFN._layout_axis_domain(l, :yaxis2) == (0.2, 0.9)
	@test _SFN._layout_axis_domain(l, :xaxis3) === nothing
	@test _SFN._layout_axis_domain(l, :xaxis4) === nothing        # not a pair
	@test _SFN._layout_axis_domain(l, :xaxis9) === nothing        # absent
	@test _SFN._layout_subplot_domain(l, :scene) == ((0.0, 0.5), (0.25, 1.0))
	@test _SFN._layout_subplot_domain(l, :scene2) === nothing
	# Reference classification, cached.
	for ref in ("x", "y", "x2", "y13", "x10")
		@test _SFN._fin_axis_key(ref) === Symbol(ref[1], "axis", ref[2:end])
		@test _SFN._fin_axis_key(ref) === _SFN._fin_axis_key(Symbol(ref)) === _SFN._fin_axis_key(ref)
	end
	for ref in ("", "x1", "x0", "xx", "z", "x02", "X", "xaxis", " x", 3, nothing, 'x')
		@test _SFN._fin_axis_key(ref) === nothing
	end
	for key in (:xaxis, :yaxis2, :xaxis12)
		@test _SFN._fin_is_axis_key(key) && _SFN._fin_is_axis_key(key)
	end
	for key in (:xaxis1, :xaxis0, :scene, :x, "xaxis", 3, :yaxis02)
		@test !_SFN._fin_is_axis_key(key)
	end
	@test _SFN._axis_layout_key("x", :x) === :xaxis
	@test _SFN._axis_layout_key("y12", :y) === :yaxis12
	@test _SFN._axis_layout_key("q", :x) === :xaxisq               # as `replace(r"^[xy]" => "")` did
	@test _SFN._axis_layout_key("", :y) === :yaxis
	# The caches are bounded: unknown keys cannot grow them without limit.
	for i in 1:(_SFN._FIN_KEY_CACHE_LIMIT + 50)
		_SFN._fin_axis_key("z$i"); _SFN._fin_is_axis_key(Symbol("k$i"))
	end
	@test length(_SFN._FIN_AXIS_KEY_CACHE) <= _SFN._FIN_KEY_CACHE_LIMIT
	@test length(_SFN._FIN_IS_AXIS_KEY_CACHE) <= _SFN._FIN_KEY_CACHE_LIMIT
	@test _SFN._fin_axis_key("x2") === :xaxis2                     # still answers when full
	# The legend host search keeps its answers: a grid cell's own pair has no host,
	# an inset inside a cell is hosted by it.
	sf = subplots(2, 2; sync = false)
	for r in 1:2, c in 1:2
		plot_scatter!(sf, 1:3, 1:3; row = r, col = c)
	end
	p = sf.plot
	@test _SFN._legend_inset_host(p, "x2", "y2", (0.6, 1.0), (0.6, 1.0)) === nothing
end

@testset "cost: the room plan keeps its overlay scan and legend assignment per plan" begin
	f = plot_scatter(1:10, rand(10); legend = "line")
	plot_histogram2d!(f, randn(40) .* 2 .+ 5, randn(40) .* 2 .+ 5; secondary_y = true)
	plan = _SFN._room_plan(f)
	list = _SFN._room_overlays(plan)
	@test any(item -> item[2] == 'y' && item[4] == "right", list)
	@test _SFN._room_overlays(plan) === list                      # not scanned again
	sf = subplots(2, 2; sync = false)
	for r in 1:2, c in 1:2
		plot_scatter!(sf, 1:3, 1:3; row = r, col = c, legend = "s$(r)$(c)")
	end
	plan = _SFN._room_plan(sf)
	a1 = _SFN._room_legend_assignment(plan)
	@test _SFN._room_legend_assignment(plan) === a1
	@test a1[1] == _SFN._legend_subplot_assignment(sf.plot)[1]
end

@testset "cost: an append to a many-cell grid does not pay for every cell twice (Q27)" begin
	grid(n) = begin
		sf = subplots(n, n; sync = false)
		for r in 1:n, c in 1:n
			plot_scatter!(sf, 1:5, [1.0, 3.0, 2.0, 5.0, 4.0]; row = r, col = c, xlabel = "x", ylabel = "y")
		end
		sf
	end
	cost(sf) = begin
		for _ in 1:3
			plot_scatter!(sf, 1:3, 1:3; row = 1, col = 1)
		end
		minimum(@allocated(plot_scatter!(sf, 1:3, 1:3; row = 1, col = 1)) for _ in 1:5)
	end
	small, large = cost(grid(2)), cost(grid(6))
	# Linear in the number of cells at most (9x the cells): the plan no longer
	# scans every layout entry or every cell's pairs once per cell.
	@test large <= 8.0 * small
	@test large < 2.6e6
	# One 6 x 6 grid of heatmaps with a bar each: the bars are decorations, so
	# the finalizer pays for them, but per cell no more than a 2 x 2 grid does.
	hgrid(n) = begin
		sf = subplots(n, n; sync = false)
		for r in 1:n, c in 1:n
			plot_heatmap!(sf, [1.0 2.0; 3.0 4.0]; row = r, col = c)
		end
		sf
	end
	h2, h6 = hgrid(2), hgrid(6)
	_SFN._finalize_figure!(h2); _SFN._finalize_figure!(h6)
	f2 = minimum(@allocated(_SFN._finalize_figure!(h2)) for _ in 1:5)
	f6 = minimum(@allocated(_SFN._finalize_figure!(h6)) for _ in 1:5)
	@test f6 / 36 <= 1.3 * f2 / 4
	@test f6 < 2.4e6
	# xlabel! on a 200-trace figure: no per-trace copies.
	big = plot_scatter(1:10, 1:10)
	for i in 1:199
		plot_scatter!(big, 1:10, (1:10) .* i)
	end
	for _ in 1:3
		xlabel!(big, "a")
	end
	@test minimum(@allocated(xlabel!(big, "b")) for _ in 1:5) < 3.6e5
end

@testset "audit probes settle and keep their size (settle-04, figsize-01, vm-07)" begin
	# settle-04: one equal-aspect heatmap in the left cell of a 1x2 grid
	# alternated between two layouts on every finalize.
	U = [-1.529 -0.73 -0.465; -0.089 -0.818 -1.248; -0.051 -0.721 1.022; -1.343 -1.166 -1.08]
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, U; row = 1, col = 1, equalar = true)
	@test _SFN._finalize_figure!(sf) === false
	plot_scatter!(sf, 1:5, [1.0, 4, 2, 5, 3]; row = 1, col = 2, legend = "data")
	@test _SFN._finalize_figure!(sf) === false
	# figsize-01: an explicit journal size is the figure's, under that
	# journal's style too (it was narrowed to 264 px for a quiver).
	x = 0:0.5:3; y = 0:0.5:3
	Uq = [cos(b) for a in x, b in y]; Vq = [sin(a) for a in x, b in y]
	for style in (:default, :ieee)
		with_style(style) do
			for make in (() -> plot_quiver(x, y, Uq, Vq), () -> plot_heatmap(x, y, Uq; equalar = true))
				p = make()
				figsize!(p, :ieee; columns = 1)
				@test (p.layout.fields[:width], p.layout.fields[:height]) == (336, 252)
				@test _SFN._finalize_figure!(p) === false
				figsize!(p, 3.5, 2.5; units = :in)
				@test (p.layout.fields[:width], p.layout.fields[:height]) == (336, 240)
			end
		end
	end
	# vm-07: overlays drawn on fields leave them settled.
	gx = range(-2, 2; length = 41)
	P = [exp(-(a^2 + b^2)) for a in gx, b in gx]
	q = range(-1.8, 1.8; length = 10)
	qx = vec([a for a in q, b in q]); qy = vec([b for a in q, b in q])
	fig = plot_heatmap(gx, gx, P; equalar = true)
	plot_quiver!(fig, qx, qy, -qy, qx; sizeref = 0.35, legend = "v")
	@test _SFN._finalize_figure!(fig) === false
	px = [0.0, 1, 0, 1, 0.5]; py = [0.0, 0, 1, 1, 0.5]; tri = [1 2 5; 2 4 5; 4 3 5; 3 1 5]
	fig3 = with_style(:ieee) do
		f = plot_tripcolor(px, py, tri, px .+ py; equalar = true, colorbar_title = "u")
		plot_triplot!(f, px, py, tri; color = "white")
		f
	end
	@test _SFN._finalize_figure!(fig3) === false
end

@testset "long y tick labels of a lower grid row stay on the page (optical_pixelmap (b))" begin
	# The gallery script had shortened them to "0-24" / "24-48".
	z = [sign(sin(0.9i + 1.3j) + 1e-9) for i in 1:40, j in 1:9]
	xs = collect(range(0, 24; length = 41))
	for style in (:default, :ieee)
		sf = with_style(style) do
			s = subplots(2, 1; sync = false)
			plot_scatter!(s, [0.0, 1.0], [0.0, 1.0]; row = 1, col = 1)
			plot_heatmap!(s, xs, collect(range(1.15, 2.05; length = 10)), z; row = 2, col = 1, showscale = false)
			plot_heatmap!(s, xs, collect(range(0.0, 0.9; length = 10)), z; row = 2, col = 1, showscale = false)
			yticks!(s, [1.6, 0.45], ["0–24 µm", "24–48 µm"]; row = 2, col = 1)
			panel_labels!(s)
			s
		end
		@test _SFN._finalize_figure!(sf) === false
		fields = sf.plot.layout.fields
		info = _sfn_render(sf; width = round(Int, get(fields, :width, 700)), height = round(Int, get(fields, :height, 500)))
		info === nothing && break
		t = _SFN._cell_target(sf; row = 2, col = 1, who = "test")
		left = info["axes"][String(t.ykey)]["labels_left"]
		@test left >= 0
	end
end

@testset "an append that must move an existing bar is staged in full (fields-07)" begin
	# A second choropleth sets the first bar aside: a write to a trace the
	# append-only path shares with the live figure.
	g = plot_choropleth(["USA"], [1.0]); set_template!(g, "plotly_dark")
	first_bar = get(g.data[1].fields, :colorbar, nothing)
	plot_choropleth!(g, ["CAN"], [2.0])
	# D21: the figure holds the power-format copy of the named template
	# (made once per registered template and shared, so `===` holds).
	@test g.layout.fields[:template] === _SFN._power_template(PlotlyBase.templates[:plotly_dark])
	@test g.layout.fields[:template] !== PlotlyBase.templates[:plotly_dark]
	@test _SFN._finalize_figure!(g) === false
	@test get(g.data[1].fields, :colorbar, nothing) != first_bar
	# The strict run of the fast path raises where it cannot write; the
	# lenient one leaves the shared trace as it is.
	h = plot_choropleth(["USA"], [1.0])
	second = plot_choropleth(["CAN"], [2.0]).data[1]
	staged() = Plot(GenericTrace[h.data[1], second], deepcopy(h.layout))
	@test_throws _SFN._FinNeedsFullStaging _SFN._finalize_figure!(staged(); live = h.data, strict = true)
	before = deepcopy(h.data[1].fields)
	_SFN._finalize_figure!(staged(); live = h.data)
	@test isequal(h.data[1].fields, before)
	# An append that moves no bar keeps the fast path: the existing trace
	# objects are the live ones.
	m = plot_heatmap(rand(4, 3))
	t1 = m.data[1]
	plot_scatter!(m, [1.0, 2.0], [1.0, 2.0])
	@test m.data[1] === t1
	@test _SFN._finalize_figure!(m) === false
end

@testset "_fin_least_size finds the least fitting size whatever it starts from" begin
	# Sizes 237 and up fit; each probe answers with an estimate of the boundary.
	calls = Ref(0)
	probe(boundary, estimate) = s -> (calls[] += 1; (s >= boundary, estimate(s)))
	for guesses in ((400.0, 300.0), (237.0,), (236.0,), (201.0,), (499.0,), (NaN,), ())
		for estimate in (s -> 237.0, s -> s, s -> 1000.0, s -> -5.0)
			calls[] = 0
			@test _SFN._fin_least_size(probe(237, estimate), 200.0, 500.0, guesses) == 237.0
			@test calls[] <= 20
		end
	end
	# None fits below the base: the base, unrounded (a journal height).
	@test _SFN._fin_least_size(s -> (false, s + 1), 200.0, 252.3, (220.0,)) == 252.3
	# Everything fits: the lower bound, rounded up.
	@test _SFN._fin_least_size(s -> (true, s - 1), 200.4, 500.0, (300.0,)) == 201.0
	# An empty range and a probe that cannot fit: the base.
	@test _SFN._fin_least_size(s -> (true, s), 500.0, 500.0, (300.0,)) == 500.0
	@test _SFN._fin_least_size(s -> nothing, 200.0, 500.0, (300.0,)) == 500.0
end

@testset "single and grid equal-aspect fields settle (free size, fit cycles, slow margins, edge bars)" begin
	settled(fig) = _SFN._finalize_figure!(fig) === false && _SFN._finalize_figure!(fig) === false
	field(ex, ey, nx, ny) = (x = range(-ex, ex; length = nx); y = range(-ey, ey; length = ny);
		(x, y, [exp(-(a^2 + b^2)) for a in x, b in y]))
	# A free height corrected by the blank the fit leaves alternated between
	# 386 and 393 px: the size is now the least that fits.
	x, y, U = field(2.0, 1.0, 41, 21)
	p = plot_heatmap(x, y, U; equalar = true, colorbar_title = "|E| (V/m)", xlabel = "x (mm)", ylabel = "y (mm)")
	@test settled(p)
	H = p.layout.fields[:height]
	@test H < 500
	ctx = _SFN._fin_context(p, nothing, nothing, false)
	accs = _SFN._fin_collect_axes(p)
	bars = _SFN._fin_collect_bars(p, ctx.insets)
	fit_at(h) = _SFN._fin_plan_and_fit(ctx, accs, bars, 700.0, Float64(h))[2][(:xaxis, :yaxis)]
	_SFN._with_figure_style(p) do
		_SFN._cbar_with_extrema_memo() do
			@test fit_at(H).free_px <= 1
			@test fit_at(H - 1).free_px > 1
		end
	end
	# The fit's passes cycled with period 5 (y tick labels widening past a
	# box height): the pass with the smallest boxes is the fit.
	with_style(:aps) do
		x, y, U = field(1.5, 1.5, 30, 30)
		q = plot_heatmap(x, y, U; equalar = true, colorbar_title = "\$|E|\$ (V/m)", xlabel = "x (mm)",
			ylabel = "y (mm)", title = "field")
		@test settled(q)
	end
	# The y labels' margin estimate crept 2.4 px per pass toward the 10 px
	# margin: the constructor's run ended a round short.
	with_style(:publication) do
		x, y, U = field(0.55, 2.0, 11, 40)
		r = plot_heatmap(x, y, U; equalar = true, xlabel = "x (mm)", ylabel = "y (mm)")
		@test settled(r)
	end
	# The bars of the right column of an :ieee grid were taken from its slot
	# alone: a 17 px box, given up, laid out by the fit and the solve on
	# alternate rounds. The band edge now gives that room up for every column.
	# The 2 x 2 grids: L11 cut the :ieee one to 114 px, where no cell fitted,
	# and moved the :nature one 252 -> 246 -> 135 -> 110 px and back. The
	# :aps pair with bar titles: the bar of the right cell, drawn beyond the
	# paper while the cell was given up, kept the fit's margin too wide for it.
	cases = Any[(style, rows, cols, (; xlabel = "x (mm)", ylabel = "y (mm)"))
		for style in (:ieee, :nature) for (rows, cols) in ((1, 2), (2, 2))]
	push!(cases, (:aps, 1, 2, (; colorbar_title = "|E| (V/m)")))
	for (style, rows, cols, deco) in cases
		with_style(style) do
			x, y, U = field(2.0, 1.0, 21, 15)
			sf = subplots(rows, cols; sync = false)
			for i in 1:rows, j in 1:cols
				plot_heatmap!(sf, x, y, U; row = i, col = j, equalar = true, deco...)
			end
			@test settled(sf)
			widths = [(d = _SFN._layout_axis_domain(sf.plot.layout, Symbol(k)); d[2] - d[1])
				for k in (cols == 2 && rows == 1 ? ("xaxis", "xaxis2") : ("xaxis", "xaxis2", "xaxis3", "xaxis4"))]
			@test maximum(widths) - minimum(widths) <= 1e-6
			# Every cell is fitted (its domain is the fit's, in the room record
			# or inside its grid cell, and its bar hugs it).
			fits = _SFN._with_figure_style(sf) do
				_SFN._cbar_with_extrema_memo() do
					ctx = _SFN._fin_context(sf, nothing, nothing, false)
					accs = _SFN._fin_collect_axes(sf.plot)
					bars = _SFN._fin_collect_bars(sf.plot, ctx.insets)
					W, H = _SFN._fin_figure_size(ctx, sf.plot.layout)
					_SFN._fin_plan_and_fit(ctx, accs, bars, W, H)[2]
				end
			end
			@test length(fits) == rows * cols
		end
	end
end

@testset "a compressed grid size that stops holding is searched again, then given up (L11)" begin
	# A record of a compressed size whose cells do not fit there (the state
	# the :ieee 2 x 2 grid was left in): the size is searched again from the
	# base. The fits read the state they start from (titles wrapped for the
	# 114 px rows), so where that leads is not the size the figure was built
	# with; it settles at a size whose cells are all fitted with the plot
	# boxes of the base size.
	fits_at(fig, W, H) = _SFN._with_figure_style(fig) do
		_SFN._cbar_with_extrema_memo() do
			ctx = _SFN._fin_context(fig, nothing, nothing, false)
			accs = _SFN._fin_collect_axes(ctx.p)
			bars = _SFN._fin_collect_bars(ctx.p, ctx.insets)
			_SFN._fin_plan_and_fit(ctx, accs, bars, Float64(W), Float64(H))[2]
		end
	end
	with_style(:ieee) do
		x = range(-2.0, 2.0; length = 21); y = range(-1.0, 1.0; length = 15)
		U = [exp(-(a^2 + b^2)) for a in x, b in y]
		sf = subplots(2, 2; sync = false)
		for i in 1:2, j in 1:2
			plot_heatmap!(sf, x, y, U; row = i, col = j, equalar = true, xlabel = "x (mm)", ylabel = "y (mm)")
		end
		layout = sf.plot.layout
		W0, H0 = Float64(layout.fields[:width]), Float64(layout.fields[:height])
		rec = _SFN._fin_meta_get(layout, _SFN._FIN_SIZE_KEY)
		base = rec isa AbstractVector ? Float64(rec[2]) : H0
		layout.fields[:height] = 114
		_SFN._fin_meta_set!(layout, _SFN._FIN_SIZE_KEY, Any[W0, base, W0, 114.0, 0, 1])
		@test _SFN._finalize_figure!(sf) === true
		@test _SFN._finalize_figure!(sf) === false
		H = layout.fields[:height]
		@test 114 < H <= base
		at_base = fits_at(sf, W0, base)
		now = fits_at(sf, W0, H)
		@test length(at_base) == length(now) == 4
		# Within the 2 px a size the figure has is kept by (`_fin_free_size`).
		@test all(((cell, f),) -> now[cell].width_px >= f.width_px - 2 && now[cell].height_px >= f.height_px - 2, at_base)
		# A size that was searched again as often as allowed and stops holding
		# as well: the compression is given up for the base size, recorded,
		# and settled.
		layout.fields[:height] = 114
		_SFN._fin_meta_set!(layout, _SFN._FIN_SIZE_KEY, Any[W0, base, W0, 114.0, 0, 1, 1 + _SFN._FIN_SIZE_SEARCHES])
		@test _SFN._finalize_figure!(sf) === true
		@test layout.fields[:height] == base
		@test _SFN._fin_size_abandoned(layout)
		@test _SFN._finalize_figure!(sf) === false
	end
end

@testset "L11 drops only blank: a compressed grid keeps the plot boxes of its base size" begin
	# A 1 x 2 pair compressed with its two right bars, then given one bottom
	# bar: it kept the size the right bars had led to (700 x 303), its boxes
	# 181 px wide where the base size gives 270. Built with the bottom bar
	# from the start it took another size (326 px), with 209 px boxes.
	Z = [sin(0.4i) * cos(0.3j) for i in 1:12, j in 1:10]
	fits_at(fig, W, H) = _SFN._with_figure_style(fig) do
		_SFN._cbar_with_extrema_memo() do
			ctx = _SFN._fin_context(fig, nothing, nothing, false)
			accs = _SFN._fin_collect_axes(ctx.p)
			bars = _SFN._fin_collect_bars(ctx.p, ctx.insets)
			_SFN._fin_plan_and_fit(ctx, accs, bars, Float64(W), Float64(H))[2]
		end
	end
	sizes = Tuple{Int, Int}[]
	for showscale in (true, false)
		sf = subplots(1, 2; sync = false)
		plot_heatmap!(sf, Z; row = 1, col = 1, equalar = true, showscale = showscale)
		plot_heatmap!(sf, Z; row = 1, col = 2, equalar = true, showscale = showscale)
		shared_colorbar!(sf; side = :bottom, title = "u")
		@test _SFN._finalize_figure!(sf) === false
		layout = sf.plot.layout
		W, H = layout.fields[:width], layout.fields[:height]
		push!(sizes, (W, H))
		@test H < 500
		base = fits_at(sf, 700, 500)
		now = fits_at(sf, W, H)
		@test length(base) == length(now) == 2
		for (cell, f) in base
			@test now[cell].width_px >= f.width_px - 2
			@test now[cell].height_px >= f.height_px - 2
		end
		# One px less does not keep them.
		less = fits_at(sf, W, H - 1)
		@test any(((cell, f),) -> !haskey(less, cell) || less[cell].width_px < f.width_px - 1 ||
			less[cell].height_px < f.height_px - 1, base)
	end
	# The same figure gets the same size whichever way it was built.
	@test abs(sizes[1][2] - sizes[2][2]) <= 1
end

# ---------------------------------------------------------------------------
# v8 r1 (layout-engine): settling, colorbar spans, title room
# ---------------------------------------------------------------------------

_sfn_settled(fig) = _SFN._finalize_figure!(fig) === false
_sfn_size(fig) = (l = _sfn_plot(fig).layout.fields; (Int(round(l[:width])), Int(round(l[:height]))))

# The drawn box (px, page coordinates) of the x title of a rendered figure:
# its MathJax svg when it has one.
const _SFN_XTITLE_JS = raw"""
(() => {
  const gd = document.getElementById(__DIV__);
  if (!gd || !gd._fullLayout || !gd._fullLayout._size) return null;
  const t = gd.querySelector('.g-xtitle');
  if (!t) return null;
  const math = t.querySelector('.math-group, svg');
  if (!math) return null;
  const root = gd.getBoundingClientRect();
  const r = math.getBoundingClientRect();
  if (r.height <= 0) return null;
  return JSON.stringify({height: gd._fullLayout.height, top: r.top - root.top, bottom: r.bottom - root.top});
})()
"""

# Runs `js` (with `__DIV__` for the graph div) on the figure drawn in a
# hidden window until it returns a JSON string; `nothing` when the renderer
# cannot start (the checks are then skipped). With `width` and `height`, a
# copy of the figure is drawn at that size, finalized for it.
function _sfn_render_js(fig, js::AbstractString; width = nothing, height = nothing)
	p = _sfn_plot(fig)
	if width !== nothing
		p = Plot(deepcopy(p.data), deepcopy(p.layout))
		relayout!(p; width = width, height = height)
		_SFN._finalize_figure!(p)
	end
	sp = try
		to_syncplot(p; show = false)
	catch err
		@warn "sci_finalize: the renderer could not start; renderer checks are skipped" exception = (err, catch_backtrace())
		return nothing
	end
	try
		backend = _SFN._syncplot_backend(sp)
		script = replace(js, "__DIV__" => _SFN._json_js(sp.divid))
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

_sfn_render_xtitle(fig) = _sfn_render_js(fig, _SFN_XTITLE_JS)

# The px boxes of the angular tick labels of every polar subplot drawn.
const _SFN_POLAR_TICKS_JS = raw"""
(() => {
  const gd = document.getElementById(__DIV__);
  if (!gd || !gd._fullLayout || !gd._fullLayout._size) return null;
  const root = gd.getBoundingClientRect();
  const out = {};
  for (const g of gd.querySelectorAll('g.polarlayer > g')) {
    const id = [...g.classList].find(c => /^polar\d*$/.test(c));
    if (!id) continue;
    out[id] = [...g.querySelectorAll('g.angularaxistick text')].map(t => {
      const r = t.getBoundingClientRect();
      return [r.left - root.left, r.top - root.top, r.right - root.left, r.bottom - root.top];
    }).filter(b => b[2] > b[0]);
  }
  if (Object.keys(out).length === 0) return null;
  return JSON.stringify(out);
})()
"""

@testset "constructors return settled figures (errors-inputs-01, apib-10, seams-02, vm-settle, apia-03, apia-10)" begin
	x = collect(range(0.1, 3.0; length = 40))
	h = [sin(3a) * b for a in 1:30 for b in (0.5, 1.0)]
	hy = [cos(2a) * b for a in 1:30 for b in (0.5, 1.0)]
	θ = collect(range(0, 2π; length = 91))
	xs = range(-2, 2; length = 21); ys = range(-1, 1; length = 11)
	Z = [exp(-a^2 - 4b^2) for a in xs, b in ys]
	cases = [
		"math title" => () -> plot_scatter(x, sin.(x); title = "\$t\$ (s)"),
		"two-line title" => () -> plot_scatter(x, sin.(x); title = "a<br>b"),
		"long x title" => () -> plot_scatter(x, sin.(x); xlabel = repeat("a long axis title ", 6)),
		"histogram2d log" => () -> plot_histogram2d(h, hy; colornorm = :log, colorbar_title = "count"),
		"histogram2d log axes" => () -> plot_histogram2d(abs.(h) .+ 0.1, abs.(hy) .+ 0.1; colornorm = :log, xscale = "log"),
		"polar legend" => () -> plot_scatterpolar(θ, [abs.(cos.(2 .* θ)), 0.5 .+ 0.3 .* cos.(θ)];
			thetaunit = "radians", legend = ["a", "b"], title = "\$r(\\theta)\$<br>two lines"),
		"surface" => () -> plot_surface(xs, ys, Z; colorbar_title = "\$\\Phi\$ (V)", zlabel = "\$\\Phi\$ (V)"),
		"box legend" => () -> plot_box(h; legend = "A"),
		"choropleth" => () -> plot_choropleth(["USA", "CAN"], [1.0, 2.0]),
	]
	for st in (:default, :ieee, :aps), (name, build) in cases
		fig = with_style(build, st)
		@test _sfn_settled(fig)
	end
end

@testset "the math colorbar title of a removed field goes with it (sm-01, sm-13)" begin
	Z = [sin(i / 3) * cos(j / 4) for i in 1:15, j in 1:12]
	titles(fig) = [String(a[:name]) for a in get(_sfn_plot(fig).layout.fields, :annotations, Any[])
		if occursin("colorbar_title", string(get(a, :name, "")))]
	fig = plot_heatmap(1:15, 1:12, Z; colorbar_title = "\$\\phi\$ (V)")
	@test length(titles(fig)) == 1
	deletetraces!(fig, 1)
	plot_scatter!(fig, 1:15, sin.(1:15); legend = "line")
	@test isempty(titles(fig))
	@test _sfn_settled(fig)
	fig = plot_heatmap(1:15, 1:12, Z; colorbar_title = "\$\\phi\$ (V)")
	react!(fig, [scatter(x = 1:3, y = [1, 2, 3])], fig.layout)
	ylabel!(fig, "y")
	@test isempty(titles(fig))
	sf = subplots(1, 1; sync = false)
	plot_scatter!(sf, 1:3, [1.0, 2, 3]; legend = "main")
	k = inset!(sf, (0.55, 0.55, 0.4, 0.4))
	plot_heatmap!(sf, 1:15, 1:12, Z; inset = k, colorbar_title = "\$u\$ (V)")
	@test length(titles(sf)) == 1
	remove_inset!(sf, k)
	@test isempty(titles(sf))
	@test _sfn_settled(sf)
end

@testset "figure annotations and narrowed cells settle (sm-04, sm-10, layout-fuzz-01, layout-fuzz-10)" begin
	Z = [sin(i / 3) * cos(j / 4) for i in 1:6, j in 1:5]
	f = plot_heatmap(collect(1.0:6), collect(1.0:5), Z; xlabel = "x")
	annotate!(f, 0.5, 0.01, "Source: simulation"; coords = :figure, showarrow = false, anchor = :bottom)
	@test _sfn_settled(f)
	f = plot_scatter(1:6, [1.0, 3, 2, 5, 4, 6]; xlabel = "x", title = "\$\\alpha\$ test")
	annotate!(f, 0.5, 0.01, "note"; coords = :figure, showarrow = false, anchor = :bottom)
	@test _sfn_settled(f)
	Z2 = [sin(i / 3) * cos(j / 4) for i in 1:15, j in 1:12]
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, 1:15, 1:12, Z2; row = 1, col = 1)
	plot_heatmap!(sf, 1:15, 1:12, Z2; row = 1, col = 2)
	relayout!(sf; xaxis_domain = [0.0, 0.3])
	xlabel!(sf, "x"; row = 1, col = 2)
	@test _sfn_settled(sf)
	xs = collect(range(0.0, 3.0; length = 30)); ys = collect(range(0.0, 2.0; length = 20))
	Zf = [sin(2a) * cos(3b) for a in xs, b in ys]
	xl = collect(range(0.0, 1.0; length = 40))
	for st in (:ieee, :aps, :nature)
		sf = with_style(st) do
			sf = subplots(1, 2; sync = false)
			plot_heatmap!(sf, xs, ys, Zf; row = 1, col = 2)
			sf
		end
		@test _sfn_settled(sf)
		sf = with_style(st) do
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, xl, xl .^ 2; row = 1, col = 1, legend = "model", xlabel = "x", ylabel = "y")
			plot_heatmap!(sf, xs, ys, Zf; row = 1, col = 2, xlabel = "x", ylabel = "y", colorbar_title = "E")
			sf
		end
		@test _sfn_settled(sf)
	end
	# figsize! after an equal-aspect field: settled by the call.
	f = with_style(:ieee) do
		f = plot_heatmap(xs, ys, Zf; equalar = true)
		figsize!(f, :ieee; columns = 2)
		f
	end
	@test _sfn_settled(f)
end

@testset "secondary y over an equal-aspect host settles (errors-inputs-02)" begin
	Z = [1.0 2 3; 4 5 6; 7 8 9]
	f = plot_matrix(Z)
	plot_matrix!(f, Z; secondary_y = true)
	@test _sfn_settled(f)
	px, py = [[0.0, 1, 1], [1.0, 2, 2]], [[0.0, 0, 1], [0.0, 0, 1]]
	f = plot_polygons(px, py, [1.0, 2.0])
	plot_polygons!(f, px, py, [1.0, 2.0]; secondary_y = true)
	@test _sfn_settled(f)
	f = plot_tripcolor([0.0, 1, 0, 1], [0.0, 0, 1, 1], [1 2 3; 2 4 3], [1.0, 2, 3, 4])
	plot_tripcolor!(f, [0.0, 1, 0, 1], [0.0, 0, 1, 1], [1 2 3; 2 4 3], [1.0, 2, 3, 4]; secondary_y = true)
	@test _sfn_settled(f)
end

@testset "rule-placed cell legends do not move each other (docs-truth-16, vm-gridleg, layout-fuzz-11)" begin
	x = collect(range(0.0, 1.0; length = 30))
	sf = with_style(:nature) do
		sf = subplots(1, 3; sync = false)
		for c in 1:3
			plot_scatter!(sf, x, x .^ c; row = 1, col = c, legend = ["model $c"], xlabel = "x", ylabel = "y")
		end
		figsize!(sf, :nature; columns = 2)
		sf
	end
	@test _sfn_settled(sf)
	L = sf.plot.layout.fields
	for (c, id) in enumerate((:legend, :legend2, :legend3))
		lg = _SFN._symbol_dict(get(L, id, nothing))
		xd = _SFN._symbol_dict(L[c == 1 ? :xaxis : Symbol(:xaxis, c)])[:domain]
		haskey(lg, :x) || continue
		# Beside its own cell (inside or right of it), never over the next one.
		c < 3 && @test lg[:x] < _SFN._symbol_dict(L[Symbol(:xaxis, c + 1)])[:domain][1]
		@test lg[:x] >= xd[1] - 1e-9
	end
	# layout-fuzz-11: a cell legend left under its cell follows figsize!.
	xs = collect(range(0.0, 3.0; length = 30)); ys = collect(range(0.0, 2.0; length = 20))
	Z = [sin(2a) * cos(3b) for a in xs, b in ys]
	xx = 10 .^ range(-3, 3; length = 30)
	sf = with_style(:springer) do
		sf = subplots(3, 2; sync = false, column_titles = ["Column 1", "Column 2"])
		plot_bar!(sf, ["alpha", "beta", "gamma", "delta"], [3, 1, 2, 4]; row = 1, col = 1, xlabel = "Error",
			legend = raw"$\alpha = 0.5$")
		plot_heatmap!(sf, xs, ys, Z; row = 2, col = 1, xlabel = "time (s)", ylabel = "Error", colorbar_title = "intensity (a.u.)")
		plot_scatter!(sf, xx, xx .^ -2; row = 3, col = 1, xscale = "log", yscale = "log",
			xlabel = raw"elements per side $n$", legend = raw"$\alpha = 0.5$")
		figsize!(sf, :springer; columns = 2, aspect = 1.0)
		sf
	end
	@test _sfn_settled(sf)
	L = sf.plot.layout.fields
	lg = _SFN._symbol_dict(L[:legend])
	# The legend of cell (1, 1) stays in row 1: above the top of row 2.
	row2_top = _SFN._symbol_dict(L[:yaxis3])[:domain][2]
	@test lg[:y] > row2_top
end

@testset "margins hold what plotly cannot push (layout-fuzz-08, layout-fuzz-14)" begin
	# Decorations taller than a :nature figure: savefig neither fails nor
	# leaves less than plotly's least plot height.
	f = with_style(:nature) do
		f = plot_scatter(1:5, [1.0, 2, 3, 2, 1]; legend = "a", ylabel = repeat("long left title ", 3),
			xlabel = repeat("a wrapped long x title ", 8))
		plot_scatter!(f, 1:5, [2.0, 1, 2, 3, 2]; legend = "b")
		plot_scatter!(f, 1:5, [3.0, 2, 1, 1, 2]; legend = "c")
		set_legend!(f; position = :outside_bottom)
		f
	end
	@test _sfn_settled(f)
	m = _SFN._symbol_dict(f.layout.fields[:margin])
	W, H = _sfn_size(f)
	@test H - m[:t] - m[:b] >= min(64, H / 2) - 1
	@test !isempty(savefig(f; format = "svg"))
	# A narrow cell with a bottom bar titled on its right: the bar keeps room
	# for its title and labels, and the export works.
	sf = subplots(1, 4; sync = false)
	plot_heatmap!(sf, 1:10, 1:10, [sin(i) * j for i in 1:10, j in 1:10]; row = 1, col = 1)
	colorbar!(sf; row = 1, col = 1, side = :bottom, title = "intensity (a.u.)", title_side = :right)
	figsize!(sf, 336, 200)
	@test _sfn_settled(sf)
	bar = _sfn_bar(sf.plot.data[1])
	W = 336 - sum(_SFN._symbol_dict(sf.plot.layout.fields[:margin])[k] for k in (:l, :r))
	@test bar[:len] * W >= _SFN._text_extent("intensity (a.u.)", _SFN._fin_font_size(sf.plot.layout))[1]
	@test !isempty(savefig(sf; format = "svg"))
end

@testset "the finalizer's restyle! takes one Dict of paths (perf-restyle)" begin
	p = plot_heatmap([1.0 2; 3 4])
	ctx = _SFN._fin_context(p, nothing, nothing, false)
	_SFN._fin_restyle!(ctx, 1, Dict{Symbol, Any}(:colorbar_x => 0.5, :colorbar_len => 0.4))
	@test _sfn_bar(p.data[1])[:x] == 0.5 && _sfn_bar(p.data[1])[:len] == 0.4
	@test !haskey(p.data[1].fields, :colorbar_x)
	# A key set never seen before compiles no restyle! method.
	updates = Dict{Symbol, Any}(:colorbar_ypad => 0, :colorbar_xanchor => "left", :colorbar_thickness => 11,
		:colorbar_outlinewidth => 1)
	Base.cumulative_compile_timing(true)
	t0 = Base.cumulative_compile_time_ns()[1]
	_SFN._fin_restyle!(ctx, 1, updates)
	t1 = Base.cumulative_compile_time_ns()[1]
	Base.cumulative_compile_timing(false)
	@test (t1 - t0) / 1e9 < 0.2
	@test _sfn_bar(p.data[1])[:thickness] == 11
end

@testset "plot_area rejects Inf as it rejects NaN, before any mutation (apia-01)" begin
	err = try
		plot_area([1.0, 2, 3, 4, 5], [1.0, 2, Inf, 2, 1]); nothing
	catch e
		e
	end
	@test err isa ArgumentError && startswith(err.msg, "plot_area:") && occursin("Inf", err.msg)
	@test_throws ArgumentError plot_area([1.0, 2, 3], [1.0, -Inf, 1])
	f = plot_scatter(1:3, [1.0, 2, 3])
	before = _sfn_snapshot(f)
	@test_throws ArgumentError plot_area!(f, [1.0, 2, 3], [1.0, Inf, 1])
	@test _sfn_snapshot(f) == before
end

@testset "rendered colorbars span their plot areas (layout-fuzz-04, layout-fuzz-05, layout-fuzz-09)" begin
	xs40 = collect(range(0.0, 4.0; length = 40)); ys10 = collect(range(0.0, 1.0; length = 10))
	Zw = [sin(2a) * cos(3b) for a in xs40, b in ys10]
	# A bottom bar under a wide fitted field: as wide as its box.
	f = plot_heatmap(xs40, ys10, Zw; equalar = true)
	colorbar!(f; side = :bottom)
	@test _sfn_settled(f)
	W, H = _sfn_size(f)
	info = _sfn_render(f; width = W, height = H, bars = 1)
	if info !== nothing
		box = _sfn_box(info, :xaxis, :yaxis)
		bar = only(info["colorbars"])
		@test abs(bar["x0"] - box[1]) <= 1.5 && abs(bar["x1"] - box[2]) <= 1.5
	end
	# Under a tall fitted field in a grid resized after its content.
	xs10 = collect(range(0.0, 1.0; length = 10)); ys30 = collect(range(0.0, 3.0; length = 30))
	Zt = [sin(2a) * cos(3b) for a in xs10, b in ys30]
	sf = subplots(2, 1; sync = false)
	plot_heatmap!(sf, xs10, ys30, Zt; row = 1, col = 1, equalar = true)
	colorbar!(sf; row = 1, col = 1, side = :bottom)
	plot_scatter!(sf, xs10, xs10; row = 2, col = 1)
	figsize!(sf, 7.16, 8.0; units = :in)
	@test _sfn_settled(sf)
	W, H = _sfn_size(sf)
	info = _sfn_render(sf; width = W, height = H, bars = 1)
	if info !== nothing
		box = _sfn_box(info, :xaxis, :yaxis)
		bar = only(info["colorbars"])
		@test abs(bar["x0"] - box[1]) <= 1.5 && abs(bar["x1"] - box[2]) <= 1.5
	end
	# A single field at plotly's default bar position: as tall as the plot.
	f = plot_heatmap([sin(i) * j for i in 1:10, j in 1:8])
	@test _sfn_settled(f)
	info = _sfn_render(f; bars = 1)
	if info !== nothing
		box = _sfn_box(info, :xaxis, :yaxis)
		bar = only(info["colorbars"])
		@test abs(bar["y0"] - box[3]) <= 1.5 && abs(bar["y1"] - box[4]) <= 1.5
	end
	# A cell bar written before a figure title, panel labels and figsize!
	# follows its cell.
	xs = collect(range(0.0, 3.0; length = 30)); ys = collect(range(0.0, 2.0; length = 20))
	Z = [sin(2a) * cos(3b) for a in xs, b in ys]
	xl = collect(range(0.0, 1.0; length = 30))
	sf = with_style(:aps) do
		sf = subplots(2, 1; sync = false)
		plot_heatmap!(sf, xs, ys, Z; row = 1, col = 1, ylabel = "y", colorbar_title = "intensity (a.u.)")
		plot_scatter!(sf, xl, xl .^ 2; row = 2, col = 1, xlabel = "x", ylabel = "y")
		title!(sf, "Convergence study"; align = :left)
		panel_labels!(sf)
		figsize!(sf, :aps; columns = 2, aspect = 1.0)
		sf
	end
	@test _sfn_settled(sf)
	W, H = _sfn_size(sf)
	info = _sfn_render(sf; width = W, height = H, bars = 1)
	if info !== nothing
		box = _sfn_box(info, :xaxis, :yaxis)
		bar = only(info["colorbars"])
		@test abs(bar["y1"] - box[4]) <= 1.5
		@test bar["top"] >= box[3] - 1.5
	end
end

@testset "math titles stay on the page (vm-xtitleclip, vm-cbtitle)" begin
	for st in (:ieee, :aps, :nature)
		fig = with_style(st) do
			plot_scatter(collect(1:10), collect(1:10) .^ 2; xlabel = "frequency \$f\$ (Hz)", ylabel = "y")
		end
		@test _sfn_settled(fig)
		info = _sfn_render_xtitle(fig)
		info === nothing || @test info["bottom"] <= info["height"] - 1
	end
	# A plain title keeps the style's tight margin.
	fig = with_style(:ieee) do
		plot_scatter(collect(1:10), collect(1:10) .^ 2; xlabel = "frequency f (Hz)")
	end
	@test _sfn_margin(fig, :b) == 4
	x = range(-2, 2; length = 81); y = range(-1, 1; length = 41)
	U = [sin(3a) * cos(4b) for a in x, b in y]
	for st in (:ieee, :aps)
		fig = with_style(st) do
			plot_heatmap(x, y, U; colorbar_title = "\$E_z\$ (V/m)", equalar = true)
		end
		@test _sfn_settled(fig)
		W, H = _sfn_size(fig)
		info = _sfn_render(fig; width = W, height = H, bars = 1)
		if info !== nothing
			ann = only([a for a in info["annotations"] if a["box"][2] !== nothing])
			@test ann["box"][2] >= 0
			@test _SFN._finalize_figure!(fig) === false
		end
	end
end

@testset "a 1 x 1 grid drops a wide field's blank as a Plot does (seams-15)" begin
	xw = range(0, 4; length = 80); yw = range(0, 1; length = 20)
	W = [sin(2a) * cos(3b) for a in xw, b in yw]
	for st in (:default, :ieee)
		fp = with_style(() -> plot_heatmap(xw, yw, W; equalar = true, xlabel = "x", ylabel = "y"), st)
		sf = with_style(st) do
			sf = subplots(1, 1; sync = false)
			plot_heatmap!(sf, xw, yw, W; equalar = true, xlabel = "x", ylabel = "y")
			sf
		end
		@test _sfn_settled(sf)
		H0 = st === :default ? 500 : 252
		@test _sfn_size(sf)[2] < 0.6 * H0
		@test abs(_sfn_size(sf)[2] - _sfn_size(fp)[2]) <= 0.1 * _sfn_size(fp)[2]
		yd = _SFN._symbol_dict(sf.plot.layout.fields[:yaxis])[:domain]
		@test yd[2] - yd[1] > 0.95
	end
end

@testset "a field alone in the right column of a journal grid settles (sm-05, sm-15)" begin
	xs = range(-2, 2; length = 21); ys = range(-1, 1; length = 11)
	Z = [exp(-a^2 - 4b^2) for a in xs, b in ys]
	for st in (:ieee, :aps)
		sf = with_style(st) do
			subplots(2, 2; sync = false, specs = [Spec() Spec(kind = "scene"); Spec(kind = "polar") Spec()])
		end
		plot_surface!(sf, collect(xs), collect(ys), Z; row = 1, col = 2)
		@test _sfn_settled(sf)
		for (r, c) in ((2, 2), (2, 3))
			sf = with_style(st) do
				sf = subplots(r, c; sync = false)
				plot_heatmap!(sf, xs, ys, Z; row = 1, col = c)
				sf
			end
			@test _sfn_settled(sf)
			r0 = _sfn_margin(sf, :r)
			@test _sfn_settled(sf) && _sfn_margin(sf, :r) == r0
		end
	end
end

@testset "titles of a row wrap within their cells (vm-xtitleoverlap)" begin
	xx = collect(range(0, 1; length = 50))
	for st in (:aps, :ieee)
		sf = with_style(st) do
			sf = subplots(1, 3; sync = false, shared_yaxes = true)
			for c in 1:3
				plot_scatter!(sf, xx, sin.(c .* xx); row = 1, col = c)
				xlabel!(sf, "normalised position xi (a.u.)"; row = 1, col = c)
			end
			sf
		end
		@test _sfn_settled(sf)
		L = sf.plot.layout.fields
		for key in (:xaxis, :xaxis2, :xaxis3)
			text = _SFN._fin_title_text(L[key])
			@test occursin("<br>", text)
			@test replace(text, "<br>" => " ") == "normalised position xi (a.u.)"
		end
	end
	# A title with room in its cell stays on one line.
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, xx, xx; row = 1, col = 1, xlabel = "x (m)")
	plot_scatter!(sf, xx, xx; row = 1, col = 2, xlabel = "y (m)")
	@test _SFN._fin_title_text(sf.plot.layout.fields[:xaxis]) == "x (m)"
end

@testset "adjacent polar cells keep their angular labels apart (layout-fuzz-06)" begin
	x = collect(range(0.0, 1.0; length = 40))
	th = collect(range(0, 360; length = 60))
	sf = subplots(1, 3; sync = false, specs = [Spec() Spec(kind = "polar") Spec(kind = "polar")])
	plot_scatter!(sf, x, x .^ 2; row = 1, col = 1, xlabel = "x", ylabel = "y")
	plot_scatterpolar!(sf, th, 1 .+ 0.5 .* sind.(3 .* th); row = 1, col = 2)
	plot_scatterpolar!(sf, th, 1 .+ 0.5 .* sind.(3 .* th); row = 1, col = 3)
	@test _sfn_settled(sf)
	info = _sfn_render_js(sf, _SFN_POLAR_TICKS_JS; width = 700, height = 500)
	if info !== nothing
		@test haskey(info, "polar") && haskey(info, "polar2")
		a, b = info["polar"], info["polar2"]
		@test !isempty(a) && !isempty(b)
		@test maximum(t[3] for t in a) < minimum(t[1] for t in b)
	end
end

# The px boxes (left, top, right, bottom) of the annotations drawn, once
# every one of them is typeset.
const _SFN_ANNOTATIONS_JS = raw"""
(() => {
  const gd = document.getElementById(__DIV__);
  if (!gd || !gd._fullLayout || !gd._fullLayout._size) return null;
  const root = gd.getBoundingClientRect();
  const boxes = [];
  for (const g of gd.querySelectorAll('g.annotation')) {
    const r = g.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return null;
    boxes.push([r.left - root.left, r.top - root.top, r.right - root.left, r.bottom - root.top]);
  }
  if (boxes.length === 0) return null;
  return JSON.stringify({boxes: boxes});
})()
"""

@testset "a y axis offset label gets room above its axis (O2)" begin
	for st in (:ieee, :aps)
		fig = with_style(st) do
			f = plot_scatter(collect(1.0:10), collect(1.0:10) .* 3e7; xlabel = "x", ylabel = "y")
			yticks!(f; offset = :auto)
			f
		end
		@test _sfn_settled(fig)
		@test _sfn_margin(fig, :t) > 4
		W, H = _sfn_size(fig)
		info = _sfn_render_js(fig, _SFN_ANNOTATIONS_JS)
		if info !== nothing
			@test length(info["boxes"]) == 1
			@test info["boxes"][1][2] >= 0
		end
	end
	# Without an offset the style's top margin stays.
	fig = with_style(:ieee) do
		plot_scatter(collect(1.0:10), collect(1.0:10); xlabel = "x", ylabel = "y")
	end
	@test _sfn_margin(fig, :t) == 4
end

@testset "savefig draws a settled grid as it is (export copy, Q27 hold)" begin
	# A grid holds the margins its bars push whatever its legends list: the
	# export copy (a Plot) finds the grid settled as the SubplotFigure did,
	# so `savefig` draws the figure itself, not a re-fitted copy.
	opts(p) = _SFN._normalize_export_options(p, pairs((; scale = 2)))
	hg = subplots(2, 2; sync = false)
	for r in 1:2, c in 1:2
		plot_heatmap!(hg, [1.0 2.0; 3.0 4.0]; row = r, col = c)
	end
	fm = with_style(:aps) do
		sf = subplots(3, 1; sync = false, shared_xaxes = true, width = 325, height = 330)
		for r in 1:3
			plot_pcolormesh!(sf, collect(range(0, 6; length = 31)), collect(range(0, 1.8; length = 11)), rand(31, 11);
				row = r, col = 1, crange = (0, 1), equalar = true)
			ylabel!(sf, "\$y\$ (\$\\mu\$m)"; row = r, col = 1)
		end
		xlabel!(sf, "\$x\$ (\$\\mu\$m)"; row = 3, col = 1)
		shared_colorbar!(sf; title = "normalized \$|E_z|^2\$", title_side = :right)
		sf
	end
	for fig in (hg, fm)
		@test _sfn_settled(fig)
		p = _sfn_plot(fig)
		@test _SFN._finalize_export_copy(p, opts(p)) === p
	end
end

@testset "a margin capped back to its value is not rewritten (small figure, bottom bar)" begin
	# :ieee 336 x 158 px: the bottom bar of a fitted field asks for more
	# bottom margin than the plot can give; capped back to the margin the
	# figure has, nothing is written and the figure settles.
	Z = [sin(a) * cos(b) for a in range(0, 3; length = 40), b in range(0, 2; length = 30)]
	f = with_style(:ieee) do
		f = plot_heatmap(collect(range(0, 6; length = 40)), collect(range(0, 1; length = 30)), Z; equalar = true)
		colorbar!(f; side = :bottom, title = "intensity")
		f
	end
	@test _sfn_settled(f)
	W, H = _sfn_size(f)
	@test _sfn_margin(f, :t) + _sfn_margin(f, :b) <= H - 64
end

@testset "a polar figure under a paper style is settled with its style margin (angular tick font)" begin
	# :publication draws the angular labels at its 12 px tick font under a
	# 14 px figure font: the margin holds one 12 px line plus plotly's offset,
	# as the style gave it, and a finalize does not grow it to the 14 px room.
	for name in (:publication, :ieee)
		stp = _SFN._STYLE_REGISTRY[name]
		room = ceil(1.2 * stp.tick_fontsize + 8)
		fig = with_style(() -> plot_scatterpolar(0:30:330, 1:12), name)
		@test with_style(() -> _sfn_settled(fig), name)
		@test all(side -> _sfn_margin(fig, side) == room, (:l, :r, :t, :b))
	end
end

@testset "a math x title under a generous margin writes nothing (plotly's push holds it)" begin
	# :default: 50 px of bottom margin hold the plain title (48.1 px); plotly
	# pushes it to 60 px, past the deepest MathJax title measured (54.4 px).
	p = plot_scatter([1.0, 2.0, 3.0], [1.0, 4.0, 9.0])
	xlabel!(p, raw"$t$ (s)")
	@test _sfn_margin(p, :b) == 50
	@test _SFN._fin_meta_get(p.layout, _SFN._ROOM_MARGIN_KEY) === nothing
end
