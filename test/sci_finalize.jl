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
	@test !_SFN._fin_needs_full_staging(plot_heatmap(_SFN_X, _SFN_Y, _sfn_z(_SFN_X, _SFN_Y)))
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
	@test last_slot.offset + last_slot.px <=
		(neighbour.ref[1][1] - last_slot.edge) * plan.Wp - neighbour.own[:left] + 1e-6
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
	# The cell below stays aligned; the other columns keep their cells.
	@test collect(_SFN._layout_axis_domain(layout, :xaxis4)) ≈ collect(xd)
	@test collect(_SFN._layout_axis_domain(layout, :xaxis2)) ≈ collect(_SFN._layout_axis_domain(grid, :xaxis2))
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
	@test collect(_SFN._layout_axis_domain(layout, :yaxis3)) ≈ collect(_SFN._layout_axis_domain(grid, :yaxis3))
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
	@test slot.edge ≈ ref[1][2] - (_SFN._ROOM_GAP + 80 - (gap - facing - _SFN._ROOM_GAP)) / plan.Wp
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
		@test _SFN._fin_size_is_free(Layout(width = W, height = H))
		@test !_SFN._fin_size_is_free(Layout(width = W + 10, height = H))
		# Wide field: the width is kept, blank rows go; the lower bound
		# scales with the journal size (100 px at 500 px tall).
		f = plot_heatmap(x, y, z; equalar = true)
		@test f.layout.fields[:width] == round(Int, W)
		@test 100 <= f.layout.fields[:height] < H
		@test f.layout.fields[:height] >= round(_SFN._FIN_MIN_FIGURE_HEIGHT * H / _SFN._DEFAULT_EXPORT_HEIGHT_PX)
		# Tall field: the height is kept.
		t = plot_heatmap(y, x, permutedims(z); equalar = true)
		@test t.layout.fields[:height] == round(Int, H) && t.layout.fields[:width] < W
		# A size the user gave stays.
		u = plot_heatmap(x, y, z)
		figsize!(u, 400, 300)
		plot_heatmap!(u, x, y, z; equalar = true)
		@test u.layout.fields[:width] == 400 && u.layout.fields[:height] == 300
	end
	@test _SFN._fin_size_is_free(Layout())
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
		@test d1 == _SFN._layout_axis_domain(grid, :xaxis)
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
	# ... with no grown margin; the right-hand cells give up the room the
	# wrapped title needs in the 20 % gap (Z71), the left ones keep their domains.
	@test _sfn_fields(layout.fields[:margin])[:l] == 50
	for k in (:xaxis, :xaxis3)
		@test collect(_SFN._layout_axis_domain(layout, k)) ≈ collect(_SFN._layout_axis_domain(grid, k))
	end
	for k in (:xaxis2, :xaxis4)
		@test _SFN._layout_axis_domain(layout, k)[1] > _SFN._layout_axis_domain(grid, k)[1]
	end
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
	@test all(a -> a.room[:left] == 0, values(plan.areas))
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
