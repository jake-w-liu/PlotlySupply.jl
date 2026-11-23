using Test, PlotlySupply

# L9 and D19 measured in the export renderer: one text size and one face per
# text site (the text parts of a mixed "text $math$" label are drawn in the
# site's font at the site's size), and the text-extent estimates against what
# plotly.js draws. Every figure is drawn in the export window as savefig
# draws it (the prepared export copy, `Plotly.newPlot`) and measured there.

@testset "renderer text metrics (L9, D19)" begin
	PS = PlotlySupply
	JSON = PlotlySupply.PlotlyBase.JSON
	plotobj(f) = f isa SubplotFigure ? f.fig : f

	# Draw `fig` in the export window and return the parsed value of `js`
	# (the body of an async function that sees the drawn `div`).
	function drawn_json(fig, js::AbstractString)
		prepared = PS._prepare_export(plotobj(fig), ("pdf",), NamedTuple()).renderer
		w = prepared.options.width
		h = prepared.options.height
		body = """
$(PS._EXPORT_RESET_DIV_JS)
    const layout = Object.assign({}, $(prepared.layout_js), {width: $(PS._json_js(w)), height: $(PS._json_js(h))});
    await Plotly.newPlot(div, $(prepared.data_js), layout, Object.assign({}, $(prepared.config_js)));
    const result = await (async function() { $js })();
    return JSON.stringify(result);
"""
		raw = PS._with_export_window(PS._EXPORT_STATE) do ec, app, win, divid
			Base.invokelatest(() -> ec.run(win, PS._guarded_export_script(divid, 60.0, body)))
		end
		raw isa AbstractString || error("the export window did not draw the figure: $(repr(raw))")
		return JSON.parse(raw)
	end

	# Every math group: the label's own font (the hidden source <text>), the
	# text runs MathJax drew (effective px size with the drawing transform,
	# family, weight, cap height of "M" in that font), the cap height of the
	# math font's "M" glyphs, and the group's width. Every plain <text>: its
	# font, cap height and width.
	metrics_js = raw"""
  const cv = document.createElement('canvas').getContext('2d');
  function cap(weight, size, family) { cv.font = (weight || 'normal') + ' ' + size + 'px ' + family; return cv.measureText('M').actualBoundingBoxAscent; }
  function scaleOf(el) { const m = el.getScreenCTM(); return Math.sqrt(Math.abs(m.a * m.d - m.b * m.c)); }
  const out = {groups: [], plains: []};
  div.querySelectorAll('g[class$="-math-group"]').forEach(function (g) {
    const key = g.getAttribute('data-unformatted');
    let src = null;
    for (let c = g.parentNode.firstChild; c; c = c.nextSibling) {
      if (c.tagName === 'text' && c.getAttribute('data-unformatted') === key) { src = c; break; }
    }
    const site = src ? {family: src.style.fontFamily, size: parseFloat(src.style.fontSize), weight: src.style.fontWeight || '400'} : null;
    const runs = [];
    g.querySelectorAll('text').forEach(function (t) {
      const size = parseFloat(t.getAttribute('font-size') || getComputedStyle(t).fontSize) * scaleOf(t);
      const family = t.getAttribute('font-family') || getComputedStyle(t).fontFamily;
      const weight = t.getAttribute('font-weight') || getComputedStyle(t).fontWeight;
      runs.push({text: t.textContent, size: size, family: family, weight: weight, cap: cap(weight, size, family)});
    });
    const glyphs = [];
    g.querySelectorAll('use').forEach(function (u) {
      const href = u.getAttribute('href') || u.getAttribute('xlink:href') || '';
      if (/-4D$/.test(href)) glyphs.push(u.getBoundingClientRect().height);
    });
    const svg = g.querySelector('svg');
    out.groups.push({cls: g.getAttribute('class'), label: key, site: site,
      site_cap: site ? cap(site.weight, site.size, site.family) : null, runs: runs, glyphs: glyphs,
      width: svg ? svg.getBoundingClientRect().width : g.getBoundingClientRect().width});
  });
  div.querySelectorAll('text').forEach(function (t) {
    if (t.getAttribute('data-math') === 'N' && t.style.display === 'none') return;
    if (t.closest('g[class$="-math-group"]')) return;
    const txt = t.textContent; if (!txt) return;
    const cs = getComputedStyle(t);
    // getBBox: the text's own (unrotated) box, as plotly.js measures it.
    out.plains.push({cls: t.getAttribute('class'), text: txt, family: cs.fontFamily, size: parseFloat(cs.fontSize),
      weight: cs.fontWeight, cap: cap(cs.fontWeight, parseFloat(cs.fontSize), cs.fontFamily),
      width: t.getBBox().width});
  });
  return out;
"""

	presets = (:ieee, :aps, :nature, :elsevier, :springer, :aip, :publication)
	# CSS font weights as numbers ("normal" is 400, "bold" 700).
	weight(w) = (w = string(w); w == "normal" || isempty(w) ? 400 : w == "bold" ? 700 : parse(Int, w))
	x = collect(0.0:0.25:2.0)
	function sites_figure(style)
		with_style(style) do
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, x, [x, x .^ 2]; row = 1, col = 1, legend = ["MMMM plain", "MMMM \$x\$ mixed"],
				xlabel = "MMMM \$n\$", ylabel = "MMMM (plain)")
			plot_heatmap!(sf, [1.0 2.0; 3.0 4.0]; row = 1, col = 2, colorbar_title = "MMMM \$\\phi\$")
			title!(sf, "MMMM \$\\alpha\$ cell"; row = 1, col = 1)
			title!(sf, "MMMM \$\\beta\$ figure")
			annotate!(sf, 1.0, 2.0, "MMMM \$\\gamma\$ note"; row = 1, col = 1)
			sf
		end
	end

	@testset "L9: text parts of a mixed label share the site's face and size ($(style))" for style in presets
		r = drawn_json(sites_figure(style), metrics_js)
		groups = filter(g -> g["site"] !== nothing && occursin("MMMM", g["label"]), r["groups"])
		# legend entry, x axis title, colorbar title, cell title, figure title, annotation
		@test length(groups) == 6
		for g in groups
			site = g["site"]
			runs = filter(run -> occursin("MMMM", run["text"]), g["runs"])
			@test length(runs) == 1
			isempty(runs) && continue
			run = only(runs)
			@test isapprox(run["size"], site["size"]; rtol = 0.01)                 # same size
			@test run["family"] == replace(site["family"], "\"" => "'")            # same face
			@test weight(run["weight"]) == weight(site["weight"])                   # same weight
			@test abs(run["cap"] / g["site_cap"] - 1) <= 0.03                       # cap height of "M"
			@test isempty(g["glyphs"])                                              # no math-font "M"
		end
	end

	@testset "L9: under :default the text parts keep the math font at the site's cap height" begin
		r = drawn_json(sites_figure(:default), metrics_js)
		groups = filter(g -> g["site"] !== nothing && occursin("MMMM", g["label"]), r["groups"])
		@test length(groups) == 6
		for g in groups
			@test isempty(filter(run -> occursin("MMMM", run["text"]), g["runs"]))  # math font glyphs
			@test length(g["glyphs"]) == 4
			@test all(h -> abs(h / g["site_cap"] - 1) <= 0.03, g["glyphs"])
		end
	end

	@testset "L9/D19: estimates of mixed and plain labels equal the drawn widths ($(style))" for style in (presets..., :default)
		fig = sites_figure(style)
		r = drawn_json(fig, metrics_js)
		for g in r["groups"]
			(g["site"] === nothing || !occursin("MMMM", g["label"])) && continue
			est = with_style(() -> PS._text_extent(g["label"], g["site"]["size"]; family = g["site"]["family"])[1], style)
			@test g["width"] <= est <= 1.08 * g["width"]
		end
		for t in r["plains"]
			startswith(t["text"], "MMMM") || continue
			est = with_style(() -> PS._text_extent(t["text"], t["size"]; family = t["family"])[1], style)
			@test t["width"] <= est <= 1.08 * t["width"]
		end
	end

	# D19 acceptance: 200 random plain strings per preset (printable ASCII
	# without the markup characters < & $), drawn as annotations in the
	# preset's font, are estimated within +8 % / -0 % of their drawn width.
	# A fixed linear congruential generator keeps the strings the same on
	# every Julia version.
	function random_strings(seed::UInt64, n::Int)
		state = seed
		next() = (state = state * 0x5851f42d4c957f2d + 0x14057b7ef767814f; Int(state >> 33))
		alphabet = [Char(c) for c in 32:126 if !(Char(c) in "<&\$")]
		strings = String[]
		while length(strings) < n
			len = 3 + next() % 28
			s = strip(String([alphabet[1 + next() % length(alphabet)] for _ in 1:len]))
			isempty(s) || push!(strings, s)
		end
		return strings
	end
	plain_js = raw"""
  return Array.from(div.querySelectorAll('g.annotation-text-g text.annotation-text')).map(function (t) {
    const cs = getComputedStyle(t);
    return {text: t.textContent, size: parseFloat(cs.fontSize), family: cs.fontFamily, width: t.getBoundingClientRect().width};
  });
"""
	@testset "D19: 200 random plain strings within +8 %/-0 % ($(style))" for style in (presets..., :default)
		strings = random_strings(UInt64(0x9e3779b97f4a7c15) + UInt64(hash(style) % 1000), 200)
		fig = with_style(style) do
			f = plot_scatter([0.0, 1.0], [0.0, 1.0]; width = 1600, height = 2000)
			for (k, s) in enumerate(strings)
				annotate!(f, 0.01 + 0.5 * ((k - 1) % 2), 1 - 0.005 * (k - 0.5) / 1.0, s; coords = :paper, anchor = :left)
			end
			f
		end
		drawn = drawn_json(fig, plain_js)
		@test length(drawn) == length(strings)
		ratios = Float64[]
		for d in drawn
			est = with_style(() -> PS._text_extent(d["text"], d["size"])[1], style)
			push!(ratios, est / d["width"])
		end
		@test minimum(ratios) >= 1.0
		@test maximum(ratios) <= 1.08
	end

	# tm-extent-under: CJK text, the Verdana fallback's minus and long arrows
	# (fixed with D19), and display math, display big operators and braces
	# were estimated smaller than drawn ($$\int_0^1 f\,dx$$ 0.74 x the drawn
	# height, \prod with limits 0.66 x, \underbrace{x}_{n} 0.58 x the width).
	math_box_js = raw"""
  const out = [];
  div.querySelectorAll('g.annotation').forEach(function (a) {
    let u = null;
    a.querySelectorAll('g.annotation-text-g text, g.annotation-text-g [class*="math-group"]').forEach(function (e) {
      const r = e.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return;
      u = u ? [Math.min(u[0], r.left), Math.min(u[1], r.top), Math.max(u[2], r.right), Math.max(u[3], r.bottom)] :
        [r.left, r.top, r.right, r.bottom];
    });
    out.push({index: +a.getAttribute('data-index'), size: u ? [u[2] - u[0], u[3] - u[1]] : null});
  });
  return out;
"""
	extent_strings = ["电场强度分布 (V/m)", "−1.5×10³", "\$a \\Longrightarrow b\$", "\$\$\\int_0^1 f\\,dx\$\$","\$\$\\int f\\,dx\$\$", "\$\$\\sum_{i=1}^{n} a_i\$\$",
		"\$\$\\prod_{k=1}^{N} x_k\$\$", "\$\$\\oint_C E\\cdot dl\$\$", "\$\$\\frac{a}{b}\$\$",
		"\$\\displaystyle\\sum\\limits_{i=1}^{n} a_i\$", "\$\\underbrace{abc}_{n}\$", "\$\\underbrace{x}_{n}\$",
		"\$\\underbrace{abcdefgh}_{n}\$", "\$\\overbrace{abc}^{n}\$", "\$\\underbrace{a}_{\\text{long label}}\$"]
	@testset "tm-extent-under: CJK, arrows, display operators and braces are not under-estimated ($(style))" for style in (:default, :ieee)
		fig = with_style(style) do
			f = plot_scatter([0.0, 1.0], [0.0, 1.0]; width = 700, height = 60 * length(extent_strings) + 80)
			for (k, s) in enumerate(extent_strings)
				annotate!(f, 0.02, 1 - (k - 0.5) / length(extent_strings), s; coords = :paper, showarrow = false,
					anchor = :left, fontsize = 12)
			end
			f
		end
		stored = [PS._symbol_dict(a)[:text] for a in PS._plot_obj(fig).layout.fields[:annotations]]
		drawn = drawn_json(fig, math_box_js)
		@test length(drawn) == length(extent_strings)
		for d in drawn
			text = stored[d["index"] + 1]
			w, h = d["size"]
			ew, eh = with_style(() -> PS._text_extent(text, 12), style)
			@test (text, ew / w >= 1.0) == (text, true)
			@test (text, eh / h >= 1.0) == (text, true)
		end
	end

	# v7: text anchored at an edge of the axes keeps clear of the frame and of
	# the tick marks pointing inwards along it (gallery device_geometry (b)).
	# Before: 2.5 px from the frame under :ieee, inside its 4.7 px ticks.
	edge_js = raw"""
  const fr = div.querySelector('.draglayer .xy rect.nsewdrag').getBoundingClientRect();
  const notes = {};
  div.querySelectorAll('g.annotation').forEach(function (a) {
    const t = a.querySelector('text'); const r = t.getBoundingClientRect();
    notes[t.textContent] = {right: fr.right - r.right, left: r.left - fr.left, bottom: fr.bottom - r.bottom, top: r.top - fr.top};
  });
  return notes;
"""
	@testset "annotate! at an axes edge clears the frame and its inward ticks ($(style))" for style in (:ieee, :nature, :default)
		fig = with_style(style) do
			f = plot_scatter([0.0, 1.0], [0.0, 1.0])
			annotate!(f, 1, 0.5, "right note"; coords = :axes, anchor = :right, showarrow = false)
			annotate!(f, 0, 0, "corner"; coords = :axes, anchor = :bottomleft, showarrow = false)
			annotate!(f, 1, 1, "exact"; coords = :axes, anchor = :topright, showarrow = false, offset = (0, 0))
			f
		end
		y = PS._symbol_dict(PS._plot_obj(fig).layout.fields[:yaxis])
		x = PS._symbol_dict(PS._plot_obj(fig).layout.fields[:xaxis])
		inward(a) = get(a, :ticks, "") == "inside" ? Float64(get(a, :ticklen, 5)) : 0.0
		gaps = drawn_json(fig, edge_js)
		@test gaps["right note"]["right"] >= inward(y) + 1.5
		@test gaps["corner"]["left"] >= inward(y) + 1.5
		@test gaps["corner"]["bottom"] >= inward(x) + 1.5
		# an explicit offset = (0, 0) puts the text at the edge
		@test gaps["exact"]["right"] < gaps["right note"]["right"]
		@test gaps["exact"]["top"] < 3
	end

	# tm-cbar-math-title-clip: a math colorbar title (an annotation beside,
	# above or below the bar) of two lines or with a fraction ran past the
	# figure edge, and under :ieee (4 px margins) a title above the bar was
	# drawn outside the figure.
	cbar_title_js = raw"""
  const fig = div.querySelector('svg.main-svg').getBoundingClientRect();
  const out = [];
  div.querySelectorAll('g.annotation').forEach(function (a) {
    let u = null;
    a.querySelectorAll('g.annotation-text-g text, g.annotation-text-g [class*="math-group"]').forEach(function (e) {
      const r = e.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return;
      u = u ? [Math.min(u[0], r.left), Math.min(u[1], r.top), Math.max(u[2], r.right), Math.max(u[3], r.bottom)] :
        [r.left, r.top, r.right, r.bottom];
    });
    if (u) out.push([u[0] - fig.left, u[1] - fig.top, fig.right - u[2], fig.bottom - u[3]]);
  });
  return out;
"""
	cbar_titles = ("frac" => "\$\\frac{|E|}{E_0}\$", "2-line" => "normalised\nfield \$|E|\$",
		"math" => "\$|E|^2\$ (V\$^2\$/m\$^2\$)")
	@testset "tm-cbar-math-title-clip: math colorbar title inside the figure ($(style), $(tag), $(side))" for
			style in (:default, :ieee), (tag, title) in cbar_titles, side in (:right, :top, :bottom)
		xs = collect(range(0, 1; length = 12))
		ys = collect(range(0, 1; length = 10))
		Z = [sin(3a) * cos(2b) for a in xs, b in ys]
		fig = with_style(style) do
			plot_heatmap(xs, ys, Z; xlabel = "x", ylabel = "y", colorbar_title = title, colorbar_title_side = side)
		end
		@test PS._finalize_figure!(fig) === false
		gaps = drawn_json(fig, cbar_title_js)
		@test length(gaps) == 1
		# left, top, right and bottom distance of the glyphs from the figure edge
		@test all(gap -> minimum(gap) >= 0, gaps)
	end

	# tm-twoline-math-axis-title: a math axis title of several rows got the
	# room of one line and grew half its extra rows into the tick labels
	# (gap -1.7 px under :ieee, 3.5 px under :default for two rows; plain
	# titles keep 10-16 px).
	axis_gap_js = raw"""
  const box = el => el.getBoundingClientRect();
  const fig = box(div.querySelector('svg.main-svg'));
  const title = L => { const g = div.querySelector('g.g-' + L + 'title'); const m = g.querySelector('g[class*="math-group"]'); return box(m || g.querySelector('text')); };
  const labels = L => Array.from(div.querySelectorAll('g.' + L + 'axislayer-above g.' + L + 'tick text')).map(box);
  const xt = title('x'), yt = title('y');
  return {x: xt.top - Math.max.apply(null, labels('x').map(b => b.bottom)),
    y: Math.min.apply(null, labels('y').map(b => b.left)) - yt.right,
    inside: xt.bottom <= fig.bottom + 0.5 && yt.left >= fig.left - 0.5};
"""
	@testset "tm-twoline-math-axis-title: math axis titles of several rows keep their gap ($(style), $(rows) rows)" for
			style in (:default, :ieee), rows in (1, 2, 3)
		xl = join(["time \$t\$", "(s)", "last"][1:rows], "\n")
		yl = join(["field \$E_z\$", "(V/m)", "last"][1:rows], "\n")
		fig = with_style(style) do
			plot_scatter(collect(range(0, 1; length = 20)), collect(range(-100, 100; length = 20)); xlabel = xl, ylabel = yl)
		end
		@test PS._finalize_figure!(fig) === false
		gaps = drawn_json(fig, axis_gap_js)
		# D24: under a sized style the gap is its `title_gap` (0.5 em of the title font).
		em_gap = with_style(() -> PS._style_title_gap(PS._active_style()), style)
		want = em_gap === nothing ? nothing : em_gap * with_style(() -> PS._active_style().label_fontsize, style)
		@test want === nothing ? gaps["x"] >= 8 : abs(gaps["x"] - want) <= 1
		@test want === nothing ? gaps["y"] >= 8 : abs(gaps["y"] - want) <= 1
		@test gaps["inside"]
	end

	# docs-06: a math column title sat on the top frame line of its column
	# (no gap; a MathJax box ends at the formula's baseline).
	@testset "math column titles clear the frame" begin
		sf = subplots(2, 2; sync = false, shared_xaxes = true, shared_yaxes = true,
			column_titles = ["\$\\alpha = 1\$", "\$\\alpha = 2\$"], row_titles = ["\$r_1\$", "\$r_2\$"])
		for r in 1:2, c in 1:2
			plot_scatter!(sf, 1:5, collect(1.0:5.0) .* r; row = r, col = c)
		end
		js = raw"""
  const frames = Array.from(div.querySelectorAll('.draglayer .nsewdrag')).map(r => r.getBoundingClientRect());
  const top = Math.min.apply(null, frames.map(r => r.top));
  const right = Math.max.apply(null, frames.map(r => r.right));
  const out = [];
  div.querySelectorAll('g.annotation').forEach(function (a) {
    const g = a.querySelector('g[class$="-math-group"]'); if (!g) return;
    const r = g.getBoundingClientRect();
    out.push({label: g.getAttribute('data-unformatted'), above: top - r.bottom, beside: r.left - right});
  });
  return out;
"""
		drawn = drawn_json(sf, js)
		cols = filter(d -> occursin("alpha", d["label"]), drawn)
		rows = filter(d -> occursin("r_", d["label"]), drawn)
		@test length(cols) == 2 && length(rows) == 2
		@test all(d -> d["above"] >= 2, cols)
		@test all(d -> d["beside"] >= 2, rows)
	end

	# vm-01: an :outside_top legend with MathJax entries that plotly.js wraps
	# into two rows. The room above the axes was one row, plotly.js pushed the
	# top margin while drawing, and the SVG export drew the curves and frame
	# 19 px off the tick labels (sin(0) at y = 115.5, tick "0" at 134.5).
	@testset "vm-01: data drawn at its ticks under a wrapped outside_top math legend ($(style))" for style in (:ieee, :nature)
		xs = collect(range(0, 10; length = 100))
		fig = with_style(style) do
			f = plot_scatter(xs, [sin.(xs), cos.(xs), sin.(xs) .* cos.(xs), 0.3 .* xs .- 1.5];
				legend = ["\$\\sin x\$", "\$\\cos x\$", "product", "linear trend"], xlabel = "x", ylabel = "y")
			set_legend!(f; position = :outside_top)
			f
		end
		path = joinpath(mktempdir(), "vm01.svg")
		savefig(fig, path)
		svg = read(path, String)
		tick = match(r"class=\"ytick\"><text[^>]*transform=\"translate\(0,([0-9.]+)\)\"[^>]*>0</text>", svg)
		group = match(r"<g class=\"xy\" transform=\"translate\(([0-9.]+),([0-9.]+)\)\"", svg)
		line = match(r"<path class=\"js-line\" d=\"M([0-9.]+),([0-9.]+)", svg)
		@test tick !== nothing && group !== nothing && line !== nothing
		if tick !== nothing && group !== nothing && line !== nothing
			# the first point of sin x (data y = 0) on the tick "0"
			@test abs(parse(Float64, group[2]) + parse(Float64, line[2]) - parse(Float64, tick[1])) <= 0.5
		end
		# the legend lies inside the figure
		legend = match(r"<g class=\"legend\"[^>]*transform=\"translate\(([-0-9.]+),([-0-9.]+)\)\"", svg)
		@test legend !== nothing && parse(Float64, legend[2]) >= 0
	end

	# tm-cbar-math-ticklabels-hang: math colorbar tick labels made every export
	# wait for its timeout and fail (plotly.js never finished drawing them);
	# they are drawn as Unicode with <sup>/<sub>.
	@testset "math colorbar tick labels export" begin
		fig = plot_heatmap([1.0 2.0; 3.0 4.0]; colorbar_ticks = [1, 2.5, 4],
			colorbar_ticklabels = ["\$10^{-3}\$", "b", "\$\\alpha\$"])
		colorbar!(fig; ticks = [1, 2.5, 4], ticklabels = ["\$a\$", "b", "c"])
		path = joinpath(mktempdir(), "cbar.svg")
		@test savefig(fig, path; timeout = 60) == path
		svg = read(path, String)
		@test occursin(">a</text>", svg) && occursin(">c</text>", svg)
	end

	# tm-title-top-clip: the first line of a title of several lines, and a
	# MathJax title, started above the top of the figure (-7 px for
	# "Two-line\nfigure title", -17 px under :ieee, -5 px for a fraction).
	@testset "tm-title-top-clip: titles start inside the figure ($(style))" for style in (:default, :ieee)
		for text in ("Two-line\nfigure title", "Three\nline\ntitle", "Response \$\\frac{\\partial u}{\\partial t}\$",
				"Two-line\nfigure title \$\\alpha\$")
			fig = with_style(style) do
				f = plot_scatter(collect(0.0:0.5:2.0), collect(0.0:0.5:2.0); xlabel = "x", ylabel = "y")
				title!(f, text)
				f
			end
			r = drawn_json(fig, raw"""
  const g = div.querySelector('.g-gtitle').getBoundingClientRect(), top = div.getBoundingClientRect().top;
  return {top: g.top - top, bottom: g.bottom - top, t: div._fullLayout._size.t, margin: div._fullLayout.margin.t};
""")
			@test r["top"] >= 0
			@test r["bottom"] <= r["t"]                 # above the plot area
			@test abs(r["t"] - r["margin"]) <= 0.5      # plotly.js did not push the margin
		end
	end

	# tm-math-script-minsize: below about 11 px MathJax stopped shrinking
	# sub/superscripts (its scriptminsize, 8 px): `$x^{2}$` drawn at 4 px was
	# 1.63 times as wide per px of font as at 12 px. The width per px of font
	# is the same at every size.
	@testset "tm-math-script-minsize: math scales with its font size" begin
		fig = plot_scatter([0.0, 1.0], [0.0, 1.0])
		for (k, size) in enumerate((4, 7, 12))
			annotate!(fig, 0.5, 0.3k, "\$x^{2}\$"; fontsize = size, showarrow = false)
		end
		widths = drawn_json(fig, raw"""
  return Array.from(div.querySelectorAll('g.annotation g[class$="-math-group"] svg')).map(s => s.getBoundingClientRect().width);
""")
		@test length(widths) == 3
		if length(widths) == 3
			per_px = widths ./ [4, 7, 12]
			@test maximum(per_px) / minimum(per_px) < 1.05
		end
	end

	# vm-06: the default legend of a polar figure with no free corner goes
	# beside the disk; it sat on the "1/4 π" angular tick label.
	@testset "vm-06: polar legend clear of the angular tick labels ($(style))" for style in (:ieee, :nature)
		th = collect(range(0, 2pi; length = 361))
		fig = with_style(style) do
			plot_scatterpolar([th, th], [1 .+ cos.(th), 0.5 .+ 0.5 .* abs.(sin.(2 .* th))];
				thetaunit = "radians", legend = ["cardioid", "rose"])
		end
		boxes = drawn_json(fig, raw"""
  const top = div.getBoundingClientRect();
  const box = el => { const r = el.getBoundingClientRect(); return [r.left - top.left, r.top - top.top, r.right - top.left, r.bottom - top.top]; };
  return {legend: box(div.querySelector('g.legend > rect.bg')),
    labels: Array.from(div.querySelectorAll('g.angularaxistick text')).map(box)};
""")
		overlap(a, b) = a[1] < b[3] && b[1] < a[3] && a[2] < b[4] && b[2] < a[4]
		@test length(boxes["labels"]) == 8
		@test !any(label -> overlap(boxes["legend"], label), boxes["labels"])
	end

	# tm-legend-math-title-clip: with a math entry, plotly.js measured and
	# placed the entry's MathJax group for the math legend title (the title
	# kept no transform: 8.3 px above the legend box, cut by it).
	@testset "tm-legend-math-title-clip: a math legend title inside its box ($(style), $(tag))" for style in (:default, :ieee),
			(tag, title) in (("math", "\$\\epsilon_r\$ values"), ("frac", "\$\\frac{a}{b}\$ ratio"))
		xs = collect(range(0, 1; length = 30))
		fig = with_style(style) do
			f = plot_scatter(xs, [xs, xs .^ 2, xs .^ 3]; legend = ["linear", "quadratic \$x^2\$", "cubic"], xlabel = "x", ylabel = "y")
			set_legend!(f; position = :topright, title = title)
			f
		end
		r = drawn_json(fig, raw"""
  const lg = div.querySelector('g.legend'), top = div.getBoundingClientRect().top;
  const box = el => { const b = el.getBoundingClientRect(); return [b.top - top, b.bottom - top]; };
  const title = lg.querySelector('g[class*=titletext-math-group]');
  const entries = Array.from(lg.querySelectorAll('g.traces')).map(box);
  return {bg: box(lg.querySelector('rect.bg')), title: title ? box(title) : null,
    first: Math.min(...entries.map(e => e[0]))};
""")
		@test r["title"] !== nothing
		@test r["title"][1] >= r["bg"][1] - 0.5                 # inside the box
		@test r["title"][2] <= r["first"] + 0.5                 # above the first entry
	end

	# vm-05/style-03: the default legend of bars, boxes and violins kept the
	# top-right corner, over the tallest bars and the violin "c".
	@testset "vm-05: default legend clear of bars, boxes and violins ($(style))" for style in (:default, :ieee)
		figures = (
			() -> plot_bar(["Si", "Ge", "GaAs", "InP"], [[3.1, 4.0, 2.2, 5.1], [2.5, 3.6, 3.1, 4.4], [1.9, 2.8, 2.7, 3.9]];
				legend = ["300 K", "200 K", "77 K"]),
			() -> plot_bar(["A", "B", "C", "D"], [[1.0, 2.0, 3.0, 4.0], [1.0, 1.0, 1.0, 1.0]]; legend = ["base", "extra"], barmode = "stack"),
			() -> plot_bar([3.0, 5.0, 8.0, 9.5], ["a", "b", "c", "d"]; orientation = "h", legend = "value"),
			() -> plot_violin([[-3.0, -1.0, 0.0, 1.0, 3.3], [0.0, 0.5, 1.0, 1.5, 2.0], [-5.0, -1.0, 1.0, 2.5, 6.3]];
				legend = ["a", "b", "c"], points = false),
			() -> plot_box([[-2.0, 0.0, 0.5, 2.5], [-1.0, 1.0, 1.5, 3.5], [0.5, 2.5, 3.5, 5.5]]; legend = ["a", "b", "c"]),
		)
		for build in figures
			fig = with_style(build, style)
			PS._finalize_figure!(fig)
			r = drawn_json(fig, raw"""
  const top = div.getBoundingClientRect();
  const box = el => { const b = el.getBoundingClientRect(); return [b.left - top.left, b.top - top.top, b.right - top.left, b.bottom - top.top]; };
  return {legend: box(div.querySelector('g.legend > rect.bg')),
    marks: Array.from(div.querySelectorAll('g.barlayer g.point path, g.boxlayer path.box, g.violinlayer path.violin, g.boxlayer path.point')).map(box)};
""")
			overlap(a, b) = min(a[3], b[3]) - max(a[1], b[1]) > 0.5 && min(a[4], b[4]) - max(a[2], b[2]) > 0.5
			@test !isempty(r["marks"])
			@test !any(mark -> overlap(r["legend"], mark), r["marks"])
		end
	end

	# topo_response, optical_bars: the cell title and label (a) of a cell
	# without a legend above it were drawn a legend's height lower than (b),
	# above the outside_top legend of its neighbour.
	@testset "panel labels and cell titles of a row on one baseline ($(style))" for style in (:default, :ieee)
		xs = collect(range(0, 1; length = 30))
		sf = with_style(style) do
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, xs, xs .^ 2; row = 1, col = 1, xlabel = "x", ylabel = "y")
			plot_scatter!(sf, xs, [xs, 1 .- xs]; row = 1, col = 2, legend = ["radiated", "TM\$_0\$ reflected"],
				xlabel = "x", ylabel = "y")
			title!(sf, "reduced model"; row = 1, col = 1)
			set_legend!(sf; row = 1, col = 2, position = :outside_top, ncols = 1)
			panel_labels!(sf; labels = :abc, format = "({})", bold = true)
			sf
		end
		r = drawn_json(sf, raw"""
  const top = div.getBoundingClientRect().top, anns = div._fullLayout.annotations, out = {};
  div.querySelectorAll('g.annotation').forEach((g, i) => { const b = g.querySelector('.annotation-text-g').getBoundingClientRect(); out[anns[i].name] = [b.top - top, b.bottom - top]; });
  const lg = div.querySelector('g.legend2 > rect.bg') || div.querySelector('g.legend > rect.bg');
  return {anns: out, legend: lg.getBoundingClientRect().top - top};
""")
		a = r["anns"]["plotlysupply:panel_label:1:1"]
		b = r["anns"]["plotlysupply:panel_label:1:2"]
		t = r["anns"]["plotlysupply:title:1:1"]
		@test abs(a[2] - b[2]) <= 0.5 && abs(t[2] - b[2]) <= 0.5
		@test b[2] <= r["legend"]                                   # the line stays above the legend
		@test min(a[1], b[1], t[1]) >= -1                           # and on the page
	end
end
