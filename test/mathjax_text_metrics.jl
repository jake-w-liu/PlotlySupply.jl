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
end
