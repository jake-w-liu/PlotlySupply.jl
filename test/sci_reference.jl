using Test, PlotlySupply

# These tests assert on the package's own defaults: an earlier file of the full run
# may leave a publication style active (`set_default_style!()` without an
# argument keeps the active style), which changes colorbar fonts and line widths.
set_default_style!(:default)

const _RFT = PlotlySupply
const _RFT_PB = PlotlySupply.PlotlyBase
# The Markdown stdlib is not a test dependency; take the module that defines
# the docstring object type (Markdown.MD) instead of `using Markdown`.
const _RFT_MD = parentmodule(typeof(Base.Docs.doc(hline!)))

_rft_json(x) = _RFT_PB.JSON.json(x)

# Walk nested PlotlyAttribute / Dict fields: `_rft(item, :line, :color)`.
function _rft(x, keys::Symbol...)
	for key in keys
		x isa _RFT_PB.PlotlyAttribute && (x = x.fields)
		x = x isa AbstractDict ? get(x, key, nothing) : nothing
		x === nothing && return nothing
	end
	return x
end

_rft_plot(fig) = fig isa SubplotFigure ? fig.plot : _RFT._plot_obj(fig)
_rft_layout_items(fig, field) = get(_rft_plot(fig).layout.fields, field, Any[])
_rft_shapes(fig) = _rft_layout_items(fig, :shapes)
_rft_annotations(fig) = _rft_layout_items(fig, :annotations)

function _rft_throws(f, needle::AbstractString)
	err = try
		f()
		nothing
	catch caught
		caught
	end
	err isa ArgumentError || return false
	return occursin(needle, err.msg)
end

# Fake renderer backend (as in test/renderer_transactions.jl) so a SyncPlot
# runs real renderer transactions without Electron.
mutable struct _RftRendererState
	open::Bool
	scripts::Vector{String}
end

function _rft_syncplot(p)
	state = _RftRendererState(true, String[])
	backend = (
		isopen = window -> state.open,
		close = window -> (state.open = false; nothing),
		run = (window, script) -> (push!(state.scripts, String(script)); "ok"),
	)
	sp = SyncPlot(
		p,
		nothing,
		:sci_reference_window,
		"sci-reference-div",
		_RFT._SyncPlotResources(nothing, backend),
	)
	return sp, state
end

# Registers an inset on cell (row, col), as `inset!` (axes.jl) will.
function _rft_add_inset_impl!(sf, row, col)
	host = _RFT._cell_target(sf; row = row, col = col)
	p = sf.plot
	xi = maximum(something(_RFT._cmn_axis_index(k, 'x'), 0) for k in keys(p.layout.fields)) + 1
	yi = maximum(something(_RFT._cmn_axis_index(k, 'y'), 0) for k in keys(p.layout.fields)) + 1
	xkey, ykey = Symbol("xaxis$(xi)"), Symbol("yaxis$(yi)")
	xd = (host.xdomain[1] + 0.6 * (host.xdomain[2] - host.xdomain[1]), host.xdomain[2])
	yd = (host.ydomain[1] + 0.6 * (host.ydomain[2] - host.ydomain[1]), host.ydomain[2])
	relayout!(sf.fig; (xkey => attr(domain = collect(xd), anchor = "y$(yi)"),)...)
	relayout!(sf.fig; (ykey => attr(domain = collect(yd), anchor = "x$(xi)", type = "log"),)...)
	push!(sf.insets, _RFT._SubplotInset(host.row, host.col, xkey, ykey, "x$(xi)", "y$(yi)", xd, yd))
	return length(sf.insets)
end

_rft_add_inset!(sf, row, col) = _RFT._transactional_subplot_mutation!(
	_rft_add_inset_impl!, sf, _RFT._SUBPLOT_INSET_METADATA_FIELDS, row, col,
)

# The code blocks after a docstring's "# Example" header (the signature block
# above it is a code block too, so it is skipped).
function _rft_example_blocks!(out, node, in_example::Ref{Bool})
	if node isa _RFT_MD.MD
		for child in node.content
			_rft_example_blocks!(out, child, in_example)
		end
	elseif node isa _RFT_MD.Header
		in_example[] = occursin("Example", _RFT_MD.plain(node))
	elseif node isa _RFT_MD.Code && in_example[]
		push!(out, node.code)
	end
	return out
end

# Run every example block of a docstring in a fresh module.
function _rft_run_doc_examples(f)
	blocks = _rft_example_blocks!(String[], Base.Docs.doc(f), Ref(false))
	for code in blocks
		m = Module()
		Core.eval(m, :(using PlotlySupply))
		Base.include_string(m, code)
	end
	return length(blocks)
end

@testset "sci reference.jl" begin
	@testset "exports and registry" begin
		names = (:hline!, :vline!, :hspan!, :vspan!, :circle!, :ellipse!, :rectangle!,
			:polygon!, :arrow!, :arc!, :slope_guide!, :slope_triangle!)
		@test _RFT._SCI_REFERENCE_MUTATORS == names
		for name in names
			@test name in Base.names(PlotlySupply)
			f = getfield(PlotlySupply, name)
			@test _RFT._is_transactional_high_level_plot_mutator(f)
			# A generated Plot/SyncPlot wrapper and an explicit SubplotFigure method.
			@test any(m -> m.sig isa DataType && length(m.sig.parameters) >= 2 &&
				m.sig.parameters[2] == Union{Plot, SyncPlot}, methods(f))
			@test any(m -> m.sig isa DataType && length(m.sig.parameters) >= 2 &&
				m.sig.parameters[2] == SubplotFigure, methods(f))
			@test isempty(Test.detect_ambiguities(PlotlySupply; recursive = false) |>
				amb -> filter(a -> a[1].name == name || a[2].name == name, amb))
		end
	end

	@testset "hline!/vline!: shapes, styles, legend proxy" begin
		fig = plot_scatter([0.0, 10.0], [0.0, 5.0])
		n0 = length(fig.data)
		@test hline!(fig, 3) === nothing
		s = _rft_shapes(fig)[end]
		@test _rft(s, :type) == "line"
		@test (_rft(s, :xref), _rft(s, :x0), _rft(s, :x1)) == ("x domain", 0, 1)
		@test (_rft(s, :yref), _rft(s, :y0), _rft(s, :y1)) == ("y", 3.0, 3.0)
		@test _rft(s, :line, :color) == "#000000"
		@test _rft(s, :line, :width) == 1.0
		@test _rft(s, :line, :dash) === nothing
		@test _rft(s, :layer) == "above"
		@test _rft(s, :opacity) === nothing
		@test _rft(s, :name) == "plotlysupply:hline!:0:0"
		@test length(fig.data) == n0   # no legend -> no proxy

		# Vector input (Int, range, Vector{Any}, SubArray), styles, legend.
		hline!(fig, Any[1, 2.5]; color = :red, dash = "--", linewidth = 2.5, opacity = 0.4,
			layer = "between", legend = "refs")
		new = _rft_shapes(fig)[(end - 1):end]
		@test [_rft(x, :y0) for x in new] == [1.0, 2.5]
		@test all(_rft(x, :line, :color) == "#FF0000" for x in new)
		@test all(_rft(x, :line, :dash) == "dash" for x in new)
		@test all(_rft(x, :line, :width) == 2.5 for x in new)
		@test all(_rft(x, :opacity) == 0.4 for x in new)
		@test all(_rft(x, :layer) == "between" for x in new)
		proxy = fig.data[end]
		@test length(fig.data) == n0 + 1
		@test proxy.fields[:name] == "refs"
		@test proxy.fields[:showlegend] === true
		@test proxy.fields[:x] == [nothing] && proxy.fields[:y] == [nothing]
		@test _rft(proxy.fields[:line], :color) == "#FF0000"
		@test _rft(proxy.fields[:line], :dash) == "dash"
		@test _rft(proxy.fields[:line], :width) == 2.5
		@test proxy.fields[:opacity] == 0.4
		@test fig.layout.fields[:showlegend] === true

		hline!(fig, 1:2)
		@test [_rft(x, :y0) for x in _rft_shapes(fig)[(end - 1):end]] == [1.0, 2.0]
		v = [5.0, 6.0, 7.0]
		vline!(fig, view(v, 2:3); dash = "5px, 2px")
		new = _rft_shapes(fig)[(end - 1):end]
		@test [_rft(x, :x0) for x in new] == [6.0, 7.0]
		@test all(_rft(x, :yref) == "y domain" && _rft(x, :y0) == 0 && _rft(x, :y1) == 1 for x in new)
		@test all(_rft(x, :xref) == "x" for x in new)
		@test _rft(new[1], :line, :dash) == "5px,2px"
		@test _rft(new[1], :name) == "plotlysupply:vline!:0:0"

		# Additive: the same call twice draws two lines.
		k = length(_rft_shapes(fig))
		hline!(fig, 4)
		hline!(fig, 4)
		@test length(_rft_shapes(fig)) == k + 2

		# Empty vector draws nothing and adds no legend entry.
		k, nd = length(_rft_shapes(fig)), length(fig.data)
		@test hline!(fig, Float64[]; legend = "none") === nothing
		@test length(_rft_shapes(fig)) == k && length(fig.data) == nd

		# Shape labels: plain text (no MathJax in shape labels), position, size.
		hline!(fig, 2; label = "\$T_c\$ limit", labelpos = :end, fontsize = 14)
		s = _rft_shapes(fig)[end]
		@test _rft(s, :label, :text) == _RFT._label_plain("\$T_c\$ limit")
		@test !occursin('$', _rft(s, :label, :text))
		@test _rft(s, :label, :textposition) == "end"
		@test _rft(s, :label, :font, :size) == 14.0
		hline!(fig, 2; label = "mid", labelpos = :mid)
		@test _rft(_rft_shapes(fig)[end], :label, :textposition) == "middle"
		hline!(fig, 2; color = "")
		@test _rft(_rft_shapes(fig)[end], :line, :color) === nothing

		# Pre-existing shapes (also PlotlyBase Shape objects) are kept in order.
		fig2 = plot_scatter([1, 2], [1, 2])
		add_hline!(fig2, 1.5)
		first_shape = _rft_shapes(fig2)[1]
		hline!(fig2, 1.2)
		@test length(_rft_shapes(fig2)) == 2
		@test _rft_shapes(fig2)[1] === first_shape
	end

	@testset "hline!/vline! on log axes (data units, positive)" begin
		fig = plot_scatter([1.0, 1000.0], [1.0, 1e6]; xscale = "log", yscale = "log")
		hline!(fig, 100)
		vline!(fig, [10, 30])
		shapes = _rft_shapes(fig)
		# Shapes stay in data units on log axes (plotly.js converts them).
		@test _rft(shapes[1], :y0) == 100.0
		@test [_rft(s, :x0) for s in shapes[2:3]] == [10.0, 30.0]
		snapshot = _rft_json(fig)
		@test _rft_throws(() -> hline!(fig, 0), "hline!: `y` = 0.0 cannot be placed on a logarithmic axis")
		@test _rft_throws(() -> vline!(fig, [10, -1]), "vline!: `x[2]` = -1.0 cannot be placed on a logarithmic axis")
		@test _rft_json(fig) == snapshot
	end

	@testset "keyword and value validation (figure unchanged)" begin
		fig = plot_scatter([0, 1], [0, 1])
		snapshot = _rft_json(fig)
		@test _rft_throws(() -> hline!(fig, 1; show = true), "hline!: `show` is not accepted")
		@test _rft_throws(() -> vline!(fig, 1; show = false), "vline!: `show` is not accepted")
		@test _rft_throws(() -> hline!(fig, 1; colour = "red"), "hline!: unsupported keyword argument `colour`")
		@test _rft_throws(() -> hline!(fig, NaN), "hline!: `y` must be a finite real number")
		@test _rft_throws(() -> hline!(fig, Any[1, missing]), "hline!: `y[2]` must be a finite real number")
		@test _rft_throws(() -> hline!(fig, Any[[1, 2]]), "hline!: `y[1]` must be a finite real number")
		@test _rft_throws(() -> hline!(fig, [true]), "hline!: `y[1]` must be a finite real number")
		@test _rft_throws(() -> hline!(fig, 1; color = "notacolour"), "hline!: invalid colour")
		@test _rft_throws(() -> hline!(fig, 1; color = 3), "hline!: `color` must be a colour string or Symbol")
		@test _rft_throws(() -> hline!(fig, 1; dash = "wavy"), "hline!: `dash` must be")
		@test _rft_throws(() -> hline!(fig, 1; linewidth = -1), "hline!: `linewidth` must be >= 0")
		@test _rft_throws(() -> hline!(fig, 1; linewidth = Inf), "hline!: `linewidth` must be a finite real number")
		@test _rft_throws(() -> hline!(fig, 1; opacity = 1.5), "hline!: `opacity` must lie in [0, 1]")
		@test _rft_throws(() -> hline!(fig, 1; layer = "top"), "hline!: `layer` must be one of")
		@test _rft_throws(() -> hline!(fig, 1; labelpos = "top left"), "hline!: `labelpos` must be")
		@test _rft_throws(() -> hline!(fig, 1; label = 5), "hline!: `label` must be a string")
		@test _rft_throws(() -> hline!(fig, 1; legend = :x), "hline!: `legend` must be a string")
		@test _rft_throws(() -> hline!(fig, 1; fontsize = -2), "hline!: `fontsize` must be >= 0")
		@test _rft_throws(() -> hline!(fig, 1; row = 1, col = 1), "hline!: `row`/`col` select a SubplotFigure cell")
		@test _rft_throws(() -> hline!(fig, 1; inset = 1), "hline!: `inset` needs a SubplotFigure")
		@test _rft_throws(() -> hline!(fig, 1; secondary_y = 1), "hline!: `secondary_y` must be true or false")
		@test _rft_throws(() -> vline!(fig, 1; secondary_y = true), "vline!: unsupported keyword argument `secondary_y`")
		@test _rft_throws(() -> vspan!(fig, 0, 1; secondary_y = true), "vspan!: unsupported keyword argument `secondary_y`")
		# An odd `$` in a label fails in the text pipeline before any write.
		@test_throws ArgumentError hline!(fig, 1; label = "cost \$5")
		@test_throws ArgumentError hline!(fig, 1; legend = "cost \$5")
		@test_throws MethodError hline!(fig, "1")
		@test _rft_json(fig) == snapshot

		# A non-vector layout.shapes is rejected before anything is written.
		bad = plot_scatter([0, 1], [0, 1])
		bad.layout.fields[:shapes] = attr(type = "line")
		snap_bad = _rft_json(bad)
		@test _rft_throws(() -> hline!(bad, 1; legend = "x"), "hline!: layout.shapes must be a vector")
		@test _rft_json(bad) == snap_bad

		# Non-Cartesian targets.
		polar = plot_scatterpolar([0.0, 90.0], [1.0, 2.0])
		@test _rft_throws(() -> hline!(polar, 1), "hline!: needs Cartesian x/y axes; this figure is a :polar subplot")
		sfp = subplots(1, 2; sync = false, specs = [Spec(kind = "xy") Spec(kind = "polar")])
		@test _rft_throws(() -> circle!(sfp, 0, 0, 1; row = 1, col = 2), "circle!: needs Cartesian x/y axes; subplot cell (1, 2) is a :polar subplot")
	end

	@testset "secondary_y on a plain figure creates the twin y axis" begin
		fig = plot_scatter([0.0, 1.0], [0.0, 1.0])
		snapshot = _rft_json(fig)
		# Validation failures leave the figure without a twin axis.
		@test _rft_throws(() -> hline!(fig, NaN; secondary_y = true), "hline!: `y` must be a finite real number")
		@test _rft_json(fig) == snapshot
		hline!(fig, 50; secondary_y = true, legend = "twin")
		@test fig.layout.fields[:yaxis2][:overlaying] == "y"
		s = _rft_shapes(fig)[end]
		@test _rft(s, :yref) == "y2"
		@test _rft(s, :xref) == "x domain"
		@test fig.data[end].fields[:yaxis] == "y2"
		# A second call reuses the twin.
		hspan!(fig, 10, 20; secondary_y = true)
		@test _rft(_rft_shapes(fig)[end], :yref) == "y2"
		@test !haskey(fig.layout.fields, :yaxis3)
		# Log twin: annotation coordinates convert with the twin's type.
		relayout!(fig, yaxis2_type = "log")
		arrow!(fig, 0.2, 10, 0.8, 1000; secondary_y = true)
		a = _rft_annotations(fig)[end]
		@test (_rft(a, :yref), _rft(a, :ayref)) == ("y2", "y2")
		@test (_rft(a, :ay), _rft(a, :y)) == (1.0, 3.0)
		@test (_rft(a, :ax), _rft(a, :x)) == (0.2, 0.8)
	end

	@testset "SubplotFigure: cell (1,2), active cell, per-cell legends, insets" begin
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, [1, 2], [3, 4]; row = 1, col = 1, legend = "a")
		plot_scatter!(sf, [1, 2], [30, 40]; row = 1, col = 2, legend = "b")
		subplot!(sf, 1, 1)
		@test hline!(sf, 35; row = 1, col = 2, legend = "ref") === sf
		@test (sf.current_row, sf.current_col) == (1, 2)
		s = _rft_shapes(sf)[end]
		@test (_rft(s, :xref), _rft(s, :yref), _rft(s, :y0)) == ("x2 domain", "y2", 35.0)
		@test _rft(s, :name) == "plotlysupply:hline!:1:2"
		proxy = sf.plot.data[end]
		@test (proxy.fields[:xaxis], proxy.fields[:yaxis]) == ("x2", "y2")
		# The proxy joins cell (1,2)'s legend, like the trace "b".
		@test proxy.fields[:legend] == sf.plot.data[2].fields[:legend]
		@test proxy.fields[:legend] != sf.plot.data[1].fields[:legend]

		hspan!(sf, 31, 33; row = 1, col = 2)
		s = _rft_shapes(sf)[end]
		@test (_rft(s, :xref), _rft(s, :yref), _rft(s, :y0), _rft(s, :y1)) == ("x2 domain", "y2", 31.0, 33.0)
		@test _rft(s, :layer) == "below"
		vspan!(sf, 1.2, 1.4; row = 1, col = 2, legend = "band")
		s = _rft_shapes(sf)[end]
		@test (_rft(s, :xref), _rft(s, :yref), _rft(s, :x0), _rft(s, :x1)) == ("x2", "y2 domain", 1.2, 1.4)

		# Default target: the active cell.
		subplot!(sf, 1, 1)
		circle!(sf, 1.5, 3.5, 0.2)
		s = _rft_shapes(sf)[end]
		@test (_rft(s, :xref), _rft(s, :yref)) == ("x", "y")
		@test (_rft(s, :x0), _rft(s, :x1), _rft(s, :y0), _rft(s, :y1)) == (1.3, 1.7, 3.3, 3.7)

		# Errors: row/col pairing and range, failing calls leave sf unchanged.
		snapshot = _rft_json(sf.plot)
		@test _rft_throws(() -> hline!(sf, 1; row = 1), "hline!: `row` and `col` must be given together")
		@test _rft_throws(() -> hline!(sf, 1; row = 1, col = 3), "hline!: `col` must be in 1:2")
		@test _rft_throws(() -> hline!(sf, 1; row = 1, col = 2, secondary_y = true), "hline!: subplot cell (1, 2) has no secondary y-axis")
		@test _rft_throws(() -> hline!(sf, 1; row = 1, col = 2, show = true), "hline!: `show` is not accepted")
		@test _rft_throws(() -> arrow!(sf, 1, 1, 1, 1; row = 1, col = 2), "arrow!: the start (1.0, 1.0) and end point coincide")
		@test _rft_json(sf.plot) == snapshot
		@test (sf.current_row, sf.current_col) == (1, 1)

		# Secondary y axis of a SubplotFigure cell.
		sf2 = subplots(1, 2; sync = false, specs = [Spec() Spec(secondary_y = true)])
		plot_scatter!(sf2, [1, 2], [1, 2]; row = 1, col = 2)
		plot_scatter!(sf2, [1, 2], [10, 20]; row = 1, col = 2, secondary_y = true)
		hline!(sf2, 15; row = 1, col = 2, secondary_y = true)
		target = _RFT._cell_target(sf2; row = 1, col = 2, secondary_y = true)
		@test _rft(_rft_shapes(sf2)[end], :yref) == target.yref
		@test target.yref != "y2"

		# Inset (log y): shapes in data units, annotations in log10.
		sf3 = subplots(1, 2; sync = false)
		plot_scatter!(sf3, [1, 2], [1, 2]; row = 1, col = 2)
		k = _rft_add_inset!(sf3, 1, 2)
		@test k == 1
		inset = sf3.insets[1]
		hline!(sf3, 100; inset = 1)
		s = _rft_shapes(sf3)[end]
		@test (_rft(s, :xref), _rft(s, :yref), _rft(s, :y0)) == (inset.xref * " domain", inset.yref, 100.0)
		@test _rft(s, :name) == "plotlysupply:hline!:1:2"
		arrow!(sf3, 0.5, 10, 1.5, 1000; inset = 1)
		a = _rft_annotations(sf3)[end]
		@test (_rft(a, :xref), _rft(a, :axref), _rft(a, :yref)) == (inset.xref, inset.xref, inset.yref)
		@test (_rft(a, :ay), _rft(a, :y)) == (1.0, 3.0)
		@test (sf3.current_row, sf3.current_col) == (1, 2)
		@test _rft_throws(() -> hline!(sf3, 0; inset = 1), "hline!: `y` = 0.0 cannot be placed on a logarithmic axis")
		@test _rft_throws(() -> hline!(sf3, 1; inset = 2), "hline!: unknown inset id 2")
		@test _rft_throws(() -> circle!(sf3, 1, 10, 1; inset = 1), "circle!: a circle is defined by lengths in data units")
		slope_guide!(sf3, 1; x = (0.5, 1.5), through = (1.0, 10.0), inset = 1, legend = "g")
		tr = sf3.plot.data[end]
		@test (tr.fields[:xaxis], tr.fields[:yaxis]) == (inset.xref, inset.yref)
	end

	@testset "SyncPlot: one renderer transaction, committed model" begin
		sp, state = _rft_syncplot(plot_scatter([0.0, 1.0], [0.0, 1.0]))
		n = length(state.scripts)
		@test hline!(sp, 0.5; legend = "half") === nothing
		@test length(state.scripts) == n + 1
		@test _rft(_rft_shapes(sp)[end], :y0) == 0.5
		@test sp.plot.data[end].fields[:name] == "half"
		n = length(state.scripts)
		arrow!(sp, 0.1, 0.1, 0.9, 0.9; text = "diag")
		@test length(state.scripts) == n + 1
		@test length(_rft_annotations(sp)) == 2
		snapshot = _rft_json(sp.plot)
		n = length(state.scripts)
		@test _rft_throws(() -> polygon!(sp, [0, 1], [0, 1, 2]), "polygon!: `x` and `y` must have the same length")
		@test _rft_json(sp.plot) == snapshot
		@test length(state.scripts) == n
		close(sp)

		# SyncPlot-backed SubplotFigure.
		sp2, state2 = _rft_syncplot(Plot(GenericTrace[], Layout(Subplots(rows = 1, cols = 2))))
		sfs = SubplotFigure(sp2, 1, 2, 1, 1, true, :topright, (0.02, 0.03), "white", "black", 1.0)
		n = length(state2.scripts)
		@test vline!(sfs, 0.5; row = 1, col = 2, legend = "v") === sfs
		@test length(state2.scripts) == n + 1
		@test _rft(_rft_shapes(sfs)[end], :xref) == "x2"
		@test sfs.current_col == 2
		close(sp2)
	end

	@testset "hspan!/vspan!" begin
		fig = plot_scatter([0, 10], [0, 1])
		@test hspan!(fig, 0.6, 0.2) === nothing
		s = _rft_shapes(fig)[end]
		@test _rft(s, :type) == "rect"
		@test (_rft(s, :xref), _rft(s, :x0), _rft(s, :x1)) == ("x domain", 0, 1)
		@test (_rft(s, :yref), _rft(s, :y0), _rft(s, :y1)) == ("y", 0.6, 0.2)
		@test _rft(s, :fillcolor) == "#CCCCCC"
		@test _rft(s, :opacity) == 0.3
		@test _rft(s, :line, :width) == 0
		@test _rft(s, :layer) == "below"
		@test _rft(s, :name) == "plotlysupply:hspan!:0:0"

		n = length(fig.data)
		vspan!(fig, 2, 4; color = :orange, opacity = 0.5, edgecolor = "black", legend = "event",
			label = "E", labelpos = :top_left, layer = :above)
		s = _rft_shapes(fig)[end]
		@test (_rft(s, :yref), _rft(s, :y0), _rft(s, :y1)) == ("y domain", 0, 1)
		@test (_rft(s, :xref), _rft(s, :x0), _rft(s, :x1)) == ("x", 2.0, 4.0)
		@test _rft(s, :fillcolor) == "#FFA500"
		@test _rft(s, :line, :color) == "#000000"
		@test _rft(s, :line, :width) == 1.0   # edgecolor implies a 1 px outline
		@test _rft(s, :layer) == "above"
		@test _rft(s, :label, :text) == "E"
		@test _rft(s, :label, :textposition) == "top left"
		proxy = fig.data[end]
		@test length(fig.data) == n + 1
		@test proxy.fields[:mode] == "markers"
		@test _rft(proxy.fields[:marker], :symbol) == "square"
		@test _rft(proxy.fields[:marker], :color) == "#FFA500"
		@test _rft(proxy.fields[:marker], :line, :color) == "#000000"
		@test _rft(proxy.fields[:marker], :line, :width) == 1.0
		@test proxy.fields[:opacity] == 0.5

		# linewidth > 0 without edgecolor outlines in the fill colour; an
		# explicit 0 with an edgecolor draws no outline.
		hspan!(fig, 0, 1; color = "blue", linewidth = 2)
		@test (_rft(_rft_shapes(fig)[end], :line, :color), _rft(_rft_shapes(fig)[end], :line, :width)) == ("#0000FF", 2.0)
		hspan!(fig, 0, 1; edgecolor = "red", linewidth = 0)
		@test _rft(_rft_shapes(fig)[end], :line, :width) == 0
		hspan!(fig, 0, 1; color = "none", edgecolor = "red")
		@test _rft(_rft_shapes(fig)[end], :fillcolor) === nothing
		hspan!(fig, 0, 1; labelpos = :center)
		@test _rft(_rft_shapes(fig)[end], :label) === nothing   # no text, no label

		snapshot = _rft_json(fig)
		@test _rft_throws(() -> hspan!(fig, 0, Inf), "hspan!: `y1` must be a finite real number")
		@test _rft_throws(() -> vspan!(fig, 0, 1; labelpos = :end), "vspan!: `labelpos` must be")
		@test _rft_throws(() -> vspan!(fig, 0, 1; linewidth = -1), "vspan!: `linewidth` must be >= 0")
		@test _rft_json(fig) == snapshot

		logfig = plot_scatter([1, 100], [1, 100]; xscale = "log", yscale = "log")
		snapshot = _rft_json(logfig)
		@test _rft_throws(() -> hspan!(logfig, 0, 10), "hspan!: `y0` = 0.0 cannot be placed on a logarithmic axis")
		@test _rft_throws(() -> vspan!(logfig, 1, -10), "vspan!: `x1` = -10.0 cannot be placed on a logarithmic axis")
		@test _rft_json(logfig) == snapshot
		vspan!(logfig, 3, 30)
		@test (_rft(_rft_shapes(logfig)[end], :x0), _rft(_rft_shapes(logfig)[end], :x1)) == (3.0, 30.0)
	end

	@testset "circle!/ellipse!/rectangle!/polygon!" begin
		fig = plot_scatter([0, 10], [0, 10])
		@test circle!(fig, 2, 3, 1.5; fillcolor = "lightblue", label = "\$\\Omega\$", legend = "disk") === nothing
		s = _rft_shapes(fig)[end]
		@test _rft(s, :type) == "circle"
		@test (_rft(s, :x0), _rft(s, :x1), _rft(s, :y0), _rft(s, :y1)) == (0.5, 3.5, 1.5, 4.5)
		@test (_rft(s, :xref), _rft(s, :yref)) == ("x", "y")
		@test _rft(s, :fillcolor) == _RFT._color_hex("lightblue")
		@test _rft(s, :line, :color) == "#000000"
		@test _rft(s, :line, :width) == 1.0
		@test _rft(s, :label, :text) == "Ω"
		@test fig.data[end].fields[:name] == "disk"
		@test _rft(fig.data[end].fields[:marker], :symbol) == "square"

		# Unfilled, dashed outline -> line-sample legend proxy.
		circle!(fig, 5, 5, 1; dash = "dot", edgecolor = "red", legend = "ring")
		s = _rft_shapes(fig)[end]
		@test _rft(s, :fillcolor) === nothing
		@test _rft(s, :line, :dash) == "dot"
		@test fig.data[end].fields[:mode] == "lines"
		@test _rft(fig.data[end].fields[:line], :dash) == "dot"
		circle!(fig, 5, 5, 1; edgecolor = "none", fillcolor = "red")
		@test _rft(_rft_shapes(fig)[end], :line, :width) == 0

		ellipse!(fig, 1, 2, 2, 1; angle = 90)
		s = _rft_shapes(fig)[end]
		@test _rft(s, :type) == "path"
		path = _rft(s, :path)
		@test startswith(path, "M") && endswith(path, " Z")
		pts = [parse.(Float64, split(m.captures[1], ",")) for m in eachmatch(r"[ML]([^ ]+)", path)]
		@test length(pts) == 128
		# angle 90: the a-axis (length 2) points along +y.
		@test pts[1] ≈ [1.0, 4.0] atol = 1e-12
		@test pts[33] ≈ [0.0, 2.0] atol = 1e-12   # t = π/2: b-axis along -x
		@test all(p -> isapprox(((p[2] - 2) / 2)^2 + ((p[1] - 1) / 1)^2, 1; atol = 1e-12), pts)
		ellipse!(fig, 0, 0, 1, 1; angle = π / 2, degrees = false)
		pts2 = [parse.(Float64, split(m.captures[1], ",")) for m in eachmatch(r"[ML]([^ ]+)", _rft(_rft_shapes(fig)[end], :path))]
		@test pts2[1] ≈ [0.0, 1.0] atol = 1e-12

		rectangle!(fig, 4, 1, 1, 3)
		s = _rft_shapes(fig)[end]
		@test _rft(s, :type) == "rect"
		@test (_rft(s, :x0), _rft(s, :y0), _rft(s, :x1), _rft(s, :y1)) == (4.0, 1.0, 1.0, 3.0)
		rectangle!(fig, 1, 1, 4, 3; rounded = 0.5, fillcolor = "#eeeeee", label = "Laser", labelpos = :center)
		s = _rft_shapes(fig)[end]
		@test _rft(s, :type) == "path"
		@test count('Q', _rft(s, :path)) == 4
		@test _rft(s, :path) == "M1.5,1.0 L3.5,1.0 Q4.0,1.0 4.0,1.5 L4.0,2.5 Q4.0,3.0 3.5,3.0 " *
			"L1.5,3.0 Q1.0,3.0 1.0,2.5 L1.0,1.5 Q1.0,1.0 1.5,1.0 Z"
		@test _rft(s, :label, :textposition) == "middle center"
		rectangle!(fig, 0, 0, 2, 1; rounded = 0.5)   # rounded == min(w, h)/2 is allowed
		@test occursin("Q", _rft(_rft_shapes(fig)[end], :path))

		polygon!(fig, [0, 1, 0.5], Any[0, 0, 1]; fillcolor = :gold)
		s = _rft_shapes(fig)[end]
		@test _rft(s, :path) == "M0.0,0.0 L1.0,0.0 L0.5,1.0 Z"
		@test _rft(s, :fillcolor) == "#FFD700"
		polygon!(fig, 1:3, [1, 2, 1]; closed = false)
		@test _rft(_rft_shapes(fig)[end], :path) == "M1.0,1.0 L2.0,2.0 L3.0,1.0"
		polygon!(fig, [1e-5, 2e-5], [3.0, 4.0]; closed = false)
		@test _rft(_rft_shapes(fig)[end], :path) == "M1.0e-5,3.0 L2.0e-5,4.0"

		snapshot = _rft_json(fig)
		@test _rft_throws(() -> circle!(fig, 0, 0, 0), "circle!: `r` must be positive")
		@test _rft_throws(() -> circle!(fig, 0, NaN, 1), "circle!: `cy` must be a finite real number")
		@test _rft_throws(() -> ellipse!(fig, 0, 0, 1, -1), "ellipse!: `b` must be positive")
		@test _rft_throws(() -> ellipse!(fig, 0, 0, 1, 1; degrees = 1), "ellipse!: `degrees` must be true or false")
		@test _rft_throws(() -> rectangle!(fig, 0, 0, 2, 1; rounded = 0.6), "rectangle!: `rounded` = 0.6 exceeds half the shorter side (0.5)")
		@test _rft_throws(() -> rectangle!(fig, 0, 0, 2, 1; rounded = -0.1), "rectangle!: `rounded` must be >= 0")
		@test _rft_throws(() -> polygon!(fig, [0, 1], [0, 1]), "polygon!: a closed polygon needs at least 3 vertices")
		@test _rft_throws(() -> polygon!(fig, [0], [0]; closed = false), "polygon!: an open polyline needs at least 2 vertices")
		@test _rft_throws(() -> polygon!(fig, [0, 1, NaN], [0, 1, 2]), "polygon!: `x[3]` must be a finite real number")
		@test _rft_throws(() -> polygon!(fig, [0, 1, 2], [0, 1, 2]; closed = :yes), "polygon!: `closed` must be true or false")
		@test _rft_throws(() -> polygon!(fig, [0, 1, 2], [0, 1, 2]; fillcolor = "nope"), "polygon!: invalid colour")
		@test _rft_throws(() -> circle!(fig, 0, 0, 1; legend = "x", show = true), "circle!: `show` is not accepted")
		@test _rft_json(fig) == snapshot

		# Log axes: polygon! and plain rectangle! are placed in data units;
		# length-defined shapes are rejected.
		logfig = plot_scatter([1, 100], [1, 100]; xscale = "log", yscale = "log")
		polygon!(logfig, [2, 50, 50], [2, 2, 50])
		@test _rft(_rft_shapes(logfig)[end], :path) == "M2.0,2.0 L50.0,2.0 L50.0,50.0 Z"
		rectangle!(logfig, 20, 1, 40, 10)
		@test (_rft(_rft_shapes(logfig)[end], :x0), _rft(_rft_shapes(logfig)[end], :y1)) == (20.0, 10.0)
		snapshot = _rft_json(logfig)
		@test _rft_throws(() -> polygon!(logfig, [1, 2, 0], [1, 2, 3]), "polygon!: `x[3]` = 0.0 cannot be placed on a logarithmic axis")
		@test _rft_throws(() -> circle!(logfig, 10, 10, 1), "circle!: a circle is defined by lengths in data units")
		@test _rft_throws(() -> ellipse!(logfig, 10, 10, 1, 1), "ellipse!: an ellipse is defined by lengths in data units")
		@test _rft_throws(() -> rectangle!(logfig, 2, 2, 5, 5; rounded = 1), "rectangle!: a rounded rectangle is defined by lengths in data units")
		@test _rft_throws(() -> rectangle!(logfig, -2, 2, 5, 5), "rectangle!: `x0` = -2.0 cannot be placed on a logarithmic axis")
		@test _rft_throws(() -> arc!(logfig, 10, 10, 1, 0, 90), "arc!: an arc is defined by lengths in data units")
		@test _rft_json(logfig) == snapshot
		semilog = plot_scatter([1, 100], [1, 2]; xscale = "log")
		@test _rft_throws(() -> circle!(semilog, 10, 1, 1), "circle!: a circle is defined by lengths in data units")
	end

	@testset "arrow!" begin
		fig = plot_scatter([0, 10], [0, 5])
		@test arrow!(fig, 1, 1, 9, 2) === nothing
		a = _rft_annotations(fig)[end]
		@test (_rft(a, :x), _rft(a, :y), _rft(a, :ax), _rft(a, :ay)) == (9.0, 2.0, 1.0, 1.0)
		@test (_rft(a, :xref), _rft(a, :yref), _rft(a, :axref), _rft(a, :ayref)) == ("x", "y", "x", "y")
		@test _rft(a, :showarrow) === true
		@test _rft(a, :text) == ""
		@test (_rft(a, :arrowhead), _rft(a, :arrowsize), _rft(a, :arrowwidth)) == (2, 1.0, 1.0)
		@test _rft(a, :arrowside) == "end"
		@test _rft(a, :arrowcolor) == "#000000"
		@test _rft(a, :startarrowhead) === nothing
		@test (_rft(a, :standoff), _rft(a, :startstandoff)) == (0, 0)
		@test _rft(a, :name) == "plotlysupply:arrow!:0:0"

		arrow!(fig, 1, 1, 9, 2; head = :start, headsize = 2, linewidth = 3, color = :red)
		a = _rft_annotations(fig)[end]
		@test _rft(a, :arrowside) == "start"
		@test (_rft(a, :startarrowhead), _rft(a, :startarrowsize)) == (2, 2.0)
		@test (_rft(a, :arrowwidth), _rft(a, :arrowcolor)) == (3.0, "#FF0000")
		arrow!(fig, 1, 1, 9, 2; head = "both")
		@test _rft(_rft_annotations(fig)[end], :arrowside) == "end+start"

		# Label annotation: default at the midpoint, offset in px, colour.
		k = length(_rft_annotations(fig))
		arrow!(fig, 0, 0, 4, 2; head = :both, text = "\$L\$", offset = (0, 10), fontsize = 13, color = "blue")
		@test length(_rft_annotations(fig)) == k + 2
		t = _rft_annotations(fig)[end]
		@test _rft(t, :showarrow) === false
		@test (_rft(t, :x), _rft(t, :y)) == (2.0, 1.0)
		@test _rft(t, :text) == PlotlySupply._label("\$L\$")
		@test (_rft(t, :xshift), _rft(t, :yshift)) == (nothing, 10.0)
		@test (_rft(t, :font, :color), _rft(t, :font, :size)) == ("#0000FF", 13.0)
		arrow!(fig, 0, 0, 4, 2; text = "s", textpos = :start)
		@test (_rft(_rft_annotations(fig)[end], :x), _rft(_rft_annotations(fig)[end], :y)) == (0.0, 0.0)
		arrow!(fig, 0, 0, 4, 2; text = "e", textpos = "end")
		@test (_rft(_rft_annotations(fig)[end], :x), _rft(_rft_annotations(fig)[end], :y)) == (4.0, 2.0)

		# head = :none draws a line shape (plus the optional label).
		ks, ka = length(_rft_shapes(fig)), length(_rft_annotations(fig))
		arrow!(fig, 0, 0, 3, 3; head = :none, linewidth = 0, color = "green")
		@test length(_rft_shapes(fig)) == ks + 1 && length(_rft_annotations(fig)) == ka
		s = _rft_shapes(fig)[end]
		@test (_rft(s, :type), _rft(s, :x0), _rft(s, :y0), _rft(s, :x1), _rft(s, :y1)) == ("line", 0.0, 0.0, 3.0, 3.0)
		@test (_rft(s, :xref), _rft(s, :yref)) == ("x", "y")
		@test (_rft(s, :line, :color), _rft(s, :line, :width)) == ("#008000", 0.0)

		# Log axes: annotation coordinates are log10, line shapes data units.
		logfig = plot_scatter([1, 1000], [1, 1e6]; xscale = "log", yscale = "log")
		arrow!(logfig, 1, 1e4, 10, 100; text = "m")
		a, t = _rft_annotations(logfig)[(end - 1):end]
		@test (_rft(a, :x), _rft(a, :y), _rft(a, :ax), _rft(a, :ay)) == (1.0, 2.0, 0.0, 4.0)
		@test (_rft(t, :x), _rft(t, :y)) == (0.5, 3.0)   # visual midpoint (geometric mean)
		arrow!(logfig, 2, 1e5, 1000, 1e5; head = :none)
		s = _rft_shapes(logfig)[end]
		@test (_rft(s, :x0), _rft(s, :x1), _rft(s, :y0)) == (2.0, 1000.0, 1e5)
		snapshot = _rft_json(logfig)
		@test _rft_throws(() -> arrow!(logfig, 0, 1, 10, 10), "arrow!: `x0` = 0.0 cannot be placed on a logarithmic axis")
		@test _rft_json(logfig) == snapshot

		snapshot = _rft_json(fig)
		@test _rft_throws(() -> arrow!(fig, 1, 1, 1, 1), "arrow!: the start (1.0, 1.0) and end point coincide")
		@test _rft_throws(() -> arrow!(fig, 0, 0, 1, 1; head = :tail), "arrow!: `head` must be one of :end, :start, :both, :none")
		@test _rft_throws(() -> arrow!(fig, 0, 0, 1, 1; headsize = 0.2), "arrow!: `headsize` must be >= 0.3")
		@test _rft_throws(() -> arrow!(fig, 0, 0, 1, 1; linewidth = 0.05), "arrow!: an arrow `linewidth` must be >= 0.1")
		@test _rft_throws(() -> arrow!(fig, 0, 0, 1, 1; textpos = :top), "arrow!: `textpos` must be one of :start, :mid, :end")
		@test _rft_throws(() -> arrow!(fig, 0, 0, 1, 1; offset = (1, 2, 3)), "arrow!: `offset` must have exactly 2 elements")
		@test _rft_throws(() -> arrow!(fig, 0, 0, 1, 1; offset = 5), "arrow!: `offset` must be a 2-tuple")
		@test _rft_throws(() -> arrow!(fig, 0, 0, 1, 1; text = :t), "arrow!: `text` must be a string")
		@test_throws ArgumentError arrow!(fig, 0, 0, 1, 1; text = "odd \$ sign")
		@test _rft_json(fig) == snapshot
	end

	@testset "arc!" begin
		fig = plot_scatter([-2, 2], [-2, 2])
		@test arc!(fig, 0, 0, 1, 0, 90) === nothing
		s = _rft_shapes(fig)[end]
		@test (_rft(s, :type), _rft(s, :xref), _rft(s, :yref)) == ("path", "x", "y")
		path = _rft(s, :path)
		@test !endswith(path, "Z")
		pts = [parse.(Float64, split(m.captures[1], ",")) for m in eachmatch(r"[ML]([^ ]+)", path)]
		@test length(pts) == 32   # max(32, 128 * 0.25)
		@test pts[1] ≈ [1.0, 0.0] atol = 1e-12
		@test pts[end] ≈ [0.0, 1.0] atol = 1e-12
		@test all(p -> isapprox(hypot(p...), 1; atol = 1e-12), pts)
		@test all(p -> p[1] >= -1e-12 && p[2] >= -1e-12, pts)   # first quadrant (CCW)
		@test isempty(_rft_annotations(fig))
		arc!(fig, 0, 0, 1, 0, 360)
		pts = [parse.(Float64, split(m.captures[1], ",")) for m in eachmatch(r"[ML]([^ ]+)", _rft(_rft_shapes(fig)[end], :path))]
		@test length(pts) == 128

		# Clockwise arc with an end head: the head points along the travel.
		arc!(fig, 1, 1, 2, π / 2, 0; degrees = false, arrow = :end, color = "green", dash = "dot", linewidth = 2, headsize = 1.5)
		s = _rft_shapes(fig)[end]
		@test _rft(s, :line, :dash) == "dot"
		@test _rft(s, :line, :color) == "#008000"
		a = _rft_annotations(fig)[end]
		@test (_rft(a, :x), _rft(a, :y)) == (3.0, 1.0)   # tip at theta1 = 0
		# Clockwise at theta = 0 the travel direction is -y, so the tail is above the tip.
		@test _rft(a, :ax) ≈ 3.0 atol = 1e-12
		@test _rft(a, :ay) ≈ 1.0 + 0.1 * 2 atol = 1e-12
		@test (_rft(a, :arrowwidth), _rft(a, :arrowsize), _rft(a, :arrowcolor)) == (2.0, 1.5, "#008000")
		@test _rft(a, :arrowside) == "end"

		k = length(_rft_annotations(fig))
		arc!(fig, 0, 0, 1, 0, 90; arrow = :both)
		@test length(_rft_annotations(fig)) == k + 2
		head_end, head_start = _rft_annotations(fig)[(end - 1):end]
		@test _rft(head_end, :x) ≈ 0.0 atol = 1e-12
		@test _rft(head_end, :y) ≈ 1.0 atol = 1e-12
		@test _rft(head_end, :ax) ≈ 0.1 atol = 1e-12   # CCW at 90 deg travels -x
		@test (_rft(head_start, :x), _rft(head_start, :y)) == (1.0, 0.0)
		@test _rft(head_start, :ay) ≈ 0.1 atol = 1e-12  # tail ahead along +y; head points back
		# Short arcs keep the head tail on the arc's span.
		arc!(fig, 0, 0, 1, 0, 1; arrow = :end)
		a = _rft_annotations(fig)[end]
		@test hypot(_rft(a, :x) - _rft(a, :ax), _rft(a, :y) - _rft(a, :ay)) ≈ deg2rad(1) / 2 atol = 1e-12

		snapshot = _rft_json(fig)
		@test _rft_throws(() -> arc!(fig, 0, 0, 1, 10, 10), "arc!: `theta0` and `theta1` coincide")
		@test _rft_throws(() -> arc!(fig, 0, 0, 1, 0, 400), "arc!: the arc spans more than one full turn")
		@test _rft_throws(() -> arc!(fig, 0, 0, -1, 0, 90), "arc!: `r` must be positive")
		@test _rft_throws(() -> arc!(fig, 0, 0, 1, 0, 90; arrow = :tip), "arc!: `arrow` must be one of")
		@test _rft_throws(() -> arc!(fig, 0, 0, 1, 0, 90; arrow = :end, linewidth = 0), "arc!: an arrow `linewidth` must be >= 0.1")
		@test _rft_throws(() -> arc!(fig, 0, 0, 1, 0, 90; text = "x"), "arc!: unsupported keyword argument `text`")
		@test _rft_json(fig) == snapshot
	end

	@testset "slope_guide!" begin
		# Log-log: two end points on y = through[2] * (x / through[1])^order.
		h = [0.1, 0.05, 0.025]
		fig = plot_scatter(h, 3 .* h .^ 2; xscale = "log", yscale = "log")
		n = length(fig.data)
		@test slope_guide!(fig, 2; x = (0.01, 0.1), through = (0.1, 0.02), label = "\$O(h^2)\$") === nothing
		tr = fig.data[end]
		@test length(fig.data) == n + 1
		@test tr.fields[:x] == [0.01, 0.1]
		@test tr.fields[:y] ≈ [0.02 * (0.01 / 0.1)^2, 0.02]
		@test tr.fields[:showlegend] === false
		@test !haskey(tr.fields, :name)
		@test tr.fields[:hoverinfo] == "skip"
		@test _rft(tr.fields[:line], :dash) == "dash"
		@test _rft(tr.fields[:line], :color) == "#777777"
		a = _rft_annotations(fig)[end]
		@test _rft(a, :x) ≈ log10(sqrt(0.01 * 0.1))   # geometric mean on log x
		@test _rft(a, :y) ≈ log10(0.02 * (sqrt(0.01 * 0.1) / 0.1)^2)
		@test _rft(a, :text) == PlotlySupply._label("\$O(h^2)\$")
		@test _rft(a, :showarrow) === false
		# Rising guide: label up-left of the line, 4 px away.
		@test (_rft(a, :xanchor), _rft(a, :yanchor), _rft(a, :xshift), _rft(a, :yshift)) == ("right", "bottom", -4.0, 4.0)
		@test _rft(a, :font, :color) == "#777777"

		# Falling guide, label at the end with an extra offset, legend entry.
		slope_guide!(fig, -1; x = [0.01, 0.1], through = (0.01, 1.0), labelpos = :end, label = "slope -1",
			offset = (2, 3), legend = "guide", color = :black, dash = "-", linewidth = 2)
		tr = fig.data[end]
		@test tr.fields[:y] ≈ [1.0, 0.1]
		@test tr.fields[:showlegend] === true && tr.fields[:name] == "guide"
		@test _rft(tr.fields[:line], :dash) == "solid"
		a = _rft_annotations(fig)[end]
		@test (_rft(a, :x), _rft(a, :y)) == (log10(0.1), log10(0.1))
		@test (_rft(a, :xanchor), _rft(a, :yanchor), _rft(a, :xshift), _rft(a, :yshift)) == ("left", "middle", 6.0, 3.0)
		slope_guide!(fig, -1; x = (0.01, 0.1), through = (0.01, 1.0), labelpos = :mid, label = "m")
		a = _rft_annotations(fig)[end]
		@test (_rft(a, :xanchor), _rft(a, :xshift)) == ("left", 4.0)   # falling: up-right
		slope_guide!(fig, 2; x = (0.01, 0.1), through = (0.1, 1.0), labelpos = :start, label = "s")
		a = _rft_annotations(fig)[end]
		@test (_rft(a, :x), _rft(a, :xanchor), _rft(a, :xshift)) == (log10(0.01), "right", -4.0)
		# A reversed x axis flips the screen-side choices.
		relayout!(fig, xaxis_autorange = "reversed")
		slope_guide!(fig, 2; x = (0.01, 0.1), through = (0.1, 1.0), label = "r")
		@test _rft(_rft_annotations(fig)[end], :xanchor) == "left"
		slope_guide!(fig, 2; x = (0.01, 0.1), through = (0.1, 1.0), labelpos = :end, label = "r")
		@test _rft(_rft_annotations(fig)[end], :xanchor) == "right"

		# Linear axes: 64 linear samples of the curve (2 for a straight line).
		lin = plot_scatter([0, 2], [0, 4])
		slope_guide!(lin, 2; x = (0, 2), through = (1, 1))
		tr = lin.data[end]
		@test length(tr.fields[:x]) == 64
		@test tr.fields[:x] ≈ collect(range(0, 2; length = 64))
		@test tr.fields[:y] ≈ tr.fields[:x] .^ 2
		slope_guide!(lin, 1; x = (0, 2), through = (1, 3))
		@test lin.data[end].fields[:y] == [0.0, 6.0]
		slope_guide!(lin, 3; x = (-1, 1), through = (1, 1))   # odd integer order, negative x
		@test lin.data[end].fields[:y][1] ≈ -1.0
		slope_guide!(lin, 0.5; x = (0, 4), through = (1, 1))   # x = 0 with a positive non-integer order
		@test lin.data[end].fields[:y][1] == 0.0
		@test isempty(_rft_annotations(lin))
		# Semilog-x: log-spaced samples.
		semi = plot_scatter([1, 100], [0, 1]; xscale = "log")
		slope_guide!(semi, 1; x = (1, 100), through = (1, 0.01))
		xs = semi.data[end].fields[:x]
		@test length(xs) == 64 && xs[1] == 1.0 && xs[end] == 100.0
		@test log10.(xs) ≈ collect(range(0, 2; length = 64))

		snapshot = _rft_json(fig)
		@test _rft_throws(() -> slope_guide!(fig, 2; through = (1, 1)), "slope_guide!: the `x` keyword")
		@test _rft_throws(() -> slope_guide!(fig, 2; x = (0.1, 1)), "slope_guide!: the `through` keyword")
		@test _rft_throws(() -> slope_guide!(fig, 2; x = (0.1, 0.1), through = (1, 1)), "slope_guide!: `x` must span a non-empty interval")
		@test _rft_throws(() -> slope_guide!(fig, 2; x = (0.1, 1), through = (1, 0)), "slope_guide!: `through[2]` = 0.0 cannot be placed on a logarithmic axis")
		@test _rft_throws(() -> slope_guide!(fig, 2; x = (0, 1), through = (1, 1)), "slope_guide!: `x[1]` = 0.0 cannot be placed on a logarithmic axis")
		@test _rft_throws(() -> slope_guide!(fig, NaN; x = (0.1, 1), through = (1, 1)), "slope_guide!: `order` must be a finite real number")
		@test _rft_throws(() -> slope_guide!(fig, 2; x = (0.1, 1), through = (1, 1), labelpos = :top), "slope_guide!: `labelpos` must be one of :start, :mid, :end")
		@test _rft_throws(() -> slope_guide!(fig, 2; x = (0.1, 1, 2), through = (1, 1)), "slope_guide!: `x` must have exactly 2 elements")
		@test _rft_throws(() -> slope_guide!(fig, 2; x = (0.1, 1), through = (1, 1), show = true), "slope_guide!: `show` is not accepted")
		@test _rft_json(fig) == snapshot
		snapshot = _rft_json(lin)
		@test _rft_throws(() -> slope_guide!(lin, 2; x = (0, 1), through = (0, 1)), "slope_guide!: `through[1]` must be non-zero")
		@test _rft_throws(() -> slope_guide!(lin, 0.5; x = (-1, 1), through = (1, 1)), "slope_guide!: a non-integer `order` needs")
		@test _rft_throws(() -> slope_guide!(lin, -1; x = (-1, 1), through = (1, 1)), "slope_guide!: a negative `order` has a pole at x = 0")
		@test _rft_throws(() -> slope_guide!(lin, 400; x = (1, 1e3), through = (1, 1)), "slope_guide!: the guide is not finite")
		@test _rft_json(lin) == snapshot
		semilogy = plot_scatter([1, 2], [1, 10]; yscale = "log")
		@test _rft_throws(() -> slope_guide!(semilogy, 1; x = (-1, 1), through = (1, 1)), "slope_guide!: the guide takes non-positive values")
	end

	@testset "slope_triangle!" begin
		# Log-log, order 2, width 0.5 decades, below a rising line.
		fig = plot_scatter([1, 100], [1, 1e4]; xscale = "log", yscale = "log")
		n = length(fig.data)
		@test slope_triangle!(fig, 10, 1, 2; width = 0.5) === nothing
		tr = fig.data[end]
		@test length(fig.data) == n + 1
		x1, y1 = 10 * 10^0.5, 1 * 10^1.0
		@test tr.fields[:x] ≈ [10, x1, x1, 10]
		@test tr.fields[:y] ≈ [1, 1, y1, 1]       # right angle at (x1, y0): below
		@test tr.fields[:showlegend] === false && tr.fields[:hoverinfo] == "skip"
		@test !haskey(tr.fields, :fill)
		run, rise = _rft_annotations(fig)[(end - 1):end]
		@test _rft(run, :text) == "1" && _rft(rise, :text) == "2"
		@test (_rft(run, :x), _rft(run, :y)) == ((1 + 1.5) / 2, 0.0)
		@test (_rft(run, :yanchor), _rft(run, :yshift)) == ("top", -4.0)      # under the bottom leg
		@test (_rft(rise, :x), _rft(rise, :y)) == (1.5, 0.5)
		@test (_rft(rise, :xanchor), _rft(rise, :xshift)) == ("left", 4.0)    # right of the right leg
		@test _rft(run, :font, :color) == _RFT._color_hex("gray")

		# Above: right angle at (x0, y1); labels above the top leg and left.
		slope_triangle!(fig, 10, 1, 2; width = 0.5, below = false, fillcolor = "lightblue", labels = ("", "\$p\$"))
		tr = fig.data[end]
		@test tr.fields[:x] ≈ [10, 10, x1, 10]
		@test tr.fields[:y] ≈ [1, y1, y1, 1]
		@test (tr.fields[:fill], tr.fields[:fillcolor]) == ("toself", _RFT._color_hex("lightblue"))
		rise = _rft_annotations(fig)[end]
		@test _rft(rise, :text) == PlotlySupply._label("\$p\$")
		@test (_rft(rise, :x), _rft(rise, :xanchor), _rft(rise, :xshift)) == (1.0, "right", -4.0)
		@test length(_rft_annotations(fig)) == 3   # the empty run label is omitted

		# Linear axes: width is a fraction of the x range; falling line, order -1.5.
		lin = plot_scatter(0:10, 20 .- 1.5 .* (0:10))
		slope_triangle!(lin, 2, 16, -1.5)
		tr = lin.data[end]
		@test tr.fields[:x] ≈ [2, 2, 5, 2]
		@test tr.fields[:y] ≈ [16, 11.5, 11.5, 16]   # below a falling line: corner (x0, y1)
		run, rise = _rft_annotations(lin)[(end - 1):end]
		@test _rft(rise, :text) == "-1.5"
		@test (_rft(run, :y), _rft(run, :yanchor)) == (11.5, "top")
		@test (_rft(rise, :x), _rft(rise, :xanchor)) == (2.0, "right")
		relayout!(lin, xaxis_range = [0, 20], xaxis_autorange = false)
		slope_triangle!(lin, 2, 16, 1; width = 0.25, labels = ["a", "b"])
		@test lin.data[end].fields[:x] ≈ [2, 7, 7, 2]   # 0.25 of the explicit range
		slope_triangle!(lin, 2.0, 16, 2.0; width = -0.1)
		@test lin.data[end].fields[:x] ≈ [2, 2, 0, 2]   # negative width extends left
		@test _rft(_rft_annotations(lin)[end], :text) == "2"

		snapshot = _rft_json(lin)
		@test _rft_throws(() -> slope_triangle!(lin, 2, 16, 0), "slope_triangle!: a slope triangle needs a non-zero `order`")
		@test _rft_throws(() -> slope_triangle!(lin, 2, 16, 1; width = 0), "slope_triangle!: `width` must be non-zero")
		@test _rft_throws(() -> slope_triangle!(lin, 2, 16, 1; labels = ("1",)), "slope_triangle!: `labels` must be a 2-tuple")
		@test _rft_throws(() -> slope_triangle!(lin, 2, 16, 1; below = nothing), "slope_triangle!: `below` must be true or false")
		@test _rft_json(lin) == snapshot
		empty_fig = Plot()
		@test _rft_throws(() -> slope_triangle!(empty_fig, 1, 1, 1), "slope_triangle!: on a linear x axis `width` is a fraction of the x range")
		snapshot = _rft_json(fig)
		@test _rft_throws(() -> slope_triangle!(fig, 0, 1, 1), "slope_triangle!: `x0` = 0.0 cannot be placed on a logarithmic axis")
		@test _rft_throws(() -> slope_triangle!(fig, 1, 1, 1e300; width = 1), "slope_triangle!: the triangle does not fit in Float64")
		@test _rft_json(fig) == snapshot

		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, [1, 10], [1, 100]; row = 1, col = 2, xscale = "log", yscale = "log")
		@test slope_triangle!(sf, 2, 2, 2; row = 1, col = 2) === sf
		tr = sf.plot.data[end]
		@test (tr.fields[:xaxis], tr.fields[:yaxis]) == ("x2", "y2")
		@test all(_rft(a, :xref) == "x2" for a in _rft_annotations(sf)[(end - 1):end])
	end

	@testset "docstring examples run" begin
		for f in (hline!, vline!, hspan!, vspan!, circle!, ellipse!, rectangle!, polygon!,
			arrow!, arc!, slope_guide!, slope_triangle!)
			@test _rft_run_doc_examples(f) >= 1
		end
	end
end

# ── 2.0 integration wave 3 (fields-int): X10 line width of the slope traces
# and the reference-shape probe on log axes, cell (2, 2), its secondary y
# axis and an inset. ──────────────────────────────────────────────────────────

_rftv3_refs(s) = (_rft(s, :xref), _rft(s, :yref))
# Slope in decades of the first and last point of a trace.
_rftv3_decades(t) = (log10(t.fields[:y][end]) - log10(t.fields[:y][1])) / (log10(t.fields[:x][end]) - log10(t.fields[:x][1]))

@testset "sci reference.jl: 2.0 integration (fields-int)" begin
	@testset "X10 slope guide / triangle take the style's line width" begin
		loglog() = plot_scatter([1.0, 10.0], [1.0, 100.0]; xscale = "log", yscale = "log")
		with_style(; linewidth = 3, cycle = :dash_marker) do
			f = loglog()
			slope_guide!(f, 2; x = (1, 10), through = (1, 1))
			@test _rft(f.data[end].fields[:line], :width) == 3
			@test _rft(f.data[end].fields[:line], :dash) == "dash"     # the guide's own dash, not the cycle's
			@test f.data[end].fields[:mode] == "lines"
			slope_triangle!(f, 2, 2, 2)
			@test _rft(f.data[end].fields[:line], :width) == 3
			slope_guide!(f, 1; x = (1, 10), through = (1, 1), linewidth = 0.5)
			@test _rft(f.data[end].fields[:line], :width) == 0.5
			slope_triangle!(f, 2, 2, 1; linewidth = 2)
			@test _rft(f.data[end].fields[:line], :width) == 2
		end
		f = loglog()
		slope_guide!(f, 2; x = (1, 10), through = (1, 1))
		slope_triangle!(f, 2, 2, 2)
		@test _rft(f.data[end - 1].fields[:line], :width) == 1
		@test _rft(f.data[end].fields[:line], :width) == 1
		@test _rft_throws(() -> slope_guide!(f, 2; x = (1, 10), through = (1, 1), linewidth = -1), "slope_guide!: `linewidth` must be >= 0")
		@test _rft_throws(() -> slope_triangle!(f, 2, 2, 2; linewidth = NaN), "slope_triangle!: `linewidth` must be a finite real number")
	end

	@testset "probe: log-log axes (data units, slopes in decades)" begin
		f = plot_scatter([1.0, 10.0], [1.0, 100.0]; xscale = "log", yscale = "log")
		hline!(f, 10.0); vline!(f, 3.0); hspan!(f, 2.0, 5.0); vspan!(f, 5.0, 7.0)
		rectangle!(f, 2.0, 20.0, 4.0, 50.0)
		shapes = _rft_shapes(f)
		@test [(_rft(s, :type), _rftv3_refs(s)...) for s in shapes] == [
			("line", "x domain", "y"), ("line", "x", "y domain"), ("rect", "x domain", "y"),
			("rect", "x", "y domain"), ("rect", "x", "y")]
		# Shapes take data values on a log axis.
		@test (_rft(shapes[1], :y0), _rft(shapes[2], :x0)) == (10.0, 3.0)
		@test [_rft(shapes[5], k) for k in (:x0, :x1, :y0, :y1)] == [2.0, 4.0, 20.0, 50.0]
		# Annotations (the arrow) take log10 values, as plotly.js requires.
		arrow!(f, 1.0, 2.0, 6.0, 60.0)
		a = _rft_annotations(f)[end]
		@test [_rft(a, k) for k in (:x, :y, :ax, :ay)] ≈ log10.([6.0, 60.0, 1.0, 2.0])
		@test _rft(a, :axref) == "x"
		@test _rft_throws(() -> circle!(f, 8.0, 30.0, 0.5), "circle!: a circle is defined by lengths in data units")
		@test _rft_throws(() -> hline!(f, 0.0), "hline!: `y` = 0.0 cannot be placed on a logarithmic axis")
		for order in (2, 1, 0.5, -1, -1.5)
			slope_guide!(f, order; x = (1, 10), through = (3, 30))
			@test _rftv3_decades(f.data[end]) ≈ order
			slope_triangle!(f, 3, 30, order; width = 0.5)
			t = f.data[end]
			# Corners 1 -> 3 are the hypotenuse: rise / run in decades = order.
			@test (log10(t.fields[:y][3]) - log10(t.fields[:y][1])) / (log10(t.fields[:x][3]) - log10(t.fields[:x][1])) ≈ order
		end
	end

	@testset "probe: cell (2, 2), its secondary y axis and an inset" begin
		sf = subplots(2, 2; sync = false, specs = [Spec() Spec(); Spec() Spec(secondary_y = true)])
		plot_scatter!(sf, [0.0, 10.0], [0.0, 100.0]; row = 2, col = 2)
		plot_scatter!(sf, [0.0, 10.0], [5.0, 1.0]; row = 2, col = 2, secondary_y = true)
		cell = _RFT._cell_target(sf; row = 2, col = 2)
		twin = _RFT._cell_target(sf; row = 2, col = 2, secondary_y = true)
		@test twin.yref != cell.yref
		inset!(sf, (0.05, 0.6, 0.4, 0.35); row = 2, col = 2)
		rec = sf.insets[1]
		plot_scatter!(sf, [1.0, 100.0], [1.0, 1e4]; inset = 1, xscale = "log", yscale = "log")

		x, y = cell.xref, cell.yref
		hline!(sf, 10.0; row = 2, col = 2); vline!(sf, 3.0; row = 2, col = 2)
		hspan!(sf, 2.0, 5.0; row = 2, col = 2); vspan!(sf, 5.0, 7.0; row = 2, col = 2)
		rectangle!(sf, 2.0, 20.0, 4.0, 50.0; row = 2, col = 2); circle!(sf, 8.0, 30.0, 0.5; row = 2, col = 2)
		@test [_rftv3_refs(s) for s in _rft_shapes(sf)] == [
			("$x domain", y), (x, "$y domain"), ("$x domain", y), (x, "$y domain"), (x, y), (x, y)]
		arrow!(sf, 1.0, 2.0, 6.0, 60.0; row = 2, col = 2)
		@test (_rft(_rft_annotations(sf)[end], :xref), _rft(_rft_annotations(sf)[end], :yref)) == (x, y)

		ty = twin.yref
		hline!(sf, 3.0; row = 2, col = 2, secondary_y = true); hspan!(sf, 1.5, 2.0; row = 2, col = 2, secondary_y = true)
		rectangle!(sf, 1.0, 1.0, 2.0, 2.0; row = 2, col = 2, secondary_y = true)
		circle!(sf, 8.0, 4.0, 0.5; row = 2, col = 2, secondary_y = true)
		@test [_rftv3_refs(s) for s in _rft_shapes(sf)[(end - 3):end]] == [("$x domain", ty), ("$x domain", ty), (x, ty), (x, ty)]
		@test _rft_throws(() -> vline!(sf, 1.0; row = 2, col = 2, secondary_y = true), "vline!: unsupported keyword argument `secondary_y`")
		slope_guide!(sf, 1; x = (2, 8), through = (2, 2), row = 2, col = 2, secondary_y = true)
		slope_triangle!(sf, 6, 3, -0.2; row = 2, col = 2, secondary_y = true)
		@test all((t.fields[:xaxis], t.fields[:yaxis]) == (x, ty) for t in sf.plot.data[(end - 1):end])

		# Inset with log-log axes: refs follow the inset; slopes are in decades.
		n = length(_rft_shapes(sf))
		hline!(sf, 10.0; inset = 1); vline!(sf, 3.0; inset = 1); rectangle!(sf, 2.0, 20.0, 4.0, 50.0; inset = 1)
		@test [_rftv3_refs(s) for s in _rft_shapes(sf)[(n + 1):end]] ==
			[("$(rec.xref) domain", rec.yref), (rec.xref, "$(rec.yref) domain"), (rec.xref, rec.yref)]
		slope_guide!(sf, 2; x = (1, 10), through = (1, 10), inset = 1)
		t = sf.plot.data[end]
		@test (t.fields[:xaxis], t.fields[:yaxis]) == (rec.xref, rec.yref)
		@test _rftv3_decades(t) ≈ 2
		@test _rft_throws(() -> circle!(sf, 8.0, 30.0, 0.5; inset = 1), "circle!: a circle is defined by lengths in data units")
		@test (sf.current_row, sf.current_col) == (2, 2)
	end
end

# Dates is not a declared test dependency (see test/regression_lifecycle.jl):
# load the stdlib by its UUID.
const _RFT_Dates = Base.require(Base.PkgId(Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), "Dates"))

@testset "sci reference.jl: wave 4 (fields)" begin
	@testset "Y25 Date/DateTime positions on a date axis" begin
		D = _RFT_Dates
		days = collect(D.Date(2024, 1, 1):D.Day(1):D.Date(2024, 1, 10))
		ts = plot_scatter(days, collect(1.0:10.0))
		vline!(ts, D.Date(2024, 1, 4))
		@test (_rft(_rft_shapes(ts)[end], :x0), _rft(_rft_shapes(ts)[end], :x1)) == ("2024-01-04", "2024-01-04")
		# Julia promotes [Date, DateTime] to DateTime values.
		vline!(ts, [D.Date(2024, 1, 5), D.DateTime(2024, 1, 5, 12, 30)])
		@test [_rft(s, :x0) for s in _rft_shapes(ts)[(end - 1):end]] == ["2024-01-05T00:00:00", "2024-01-05T12:30:00"]
		vline!(ts, Any[D.Date(2024, 1, 6), D.DateTime(2024, 1, 6, 6)])
		@test [_rft(s, :x0) for s in _rft_shapes(ts)[(end - 1):end]] == ["2024-01-06", "2024-01-06T06:00:00"]
		vspan!(ts, D.Date(2024, 1, 2), D.Date(2024, 1, 3); label = "outage")
		s = _rft_shapes(ts)[end]
		@test (_rft(s, :x0), _rft(s, :x1), _rft(s, :yref)) == ("2024-01-02", "2024-01-03", "y domain")
		rectangle!(ts, D.Date(2024, 1, 6), 2.0, D.Date(2024, 1, 8), 4.0)
		s = _rft_shapes(ts)[end]
		@test (_rft(s, :type), _rft(s, :x0), _rft(s, :x1), _rft(s, :y0), _rft(s, :y1)) == ("rect", "2024-01-06", "2024-01-08", 2.0, 4.0)
		# Arrows: annotation x/ax are dates; the label sits at the midpoint in time.
		arrow!(ts, D.Date(2024, 1, 2), 2.0, D.Date(2024, 1, 5), 8.0; text = "rise")
		head, label = _rft_annotations(ts)[(end - 1):end]
		@test (_rft(head, :x), _rft(head, :ax), _rft(head, :axref)) == ("2024-01-05", "2024-01-02", "x")
		@test (_rft(head, :y), _rft(head, :ay)) == (8.0, 2.0)
		@test (_rft(label, :x), _rft(label, :y)) == ("2024-01-03T12:00:00", 5.0)
		arrow!(ts, D.Date(2024, 1, 2), 2.0, D.Date(2024, 1, 5), 8.0; head = :none)
		@test (_rft(_rft_shapes(ts)[end], :x0), _rft(_rft_shapes(ts)[end], :x1)) == ("2024-01-02", "2024-01-05")
		# The figure serialises them as strings.
		@test occursin("\"x0\":\"2024-01-04\"", _rft_json(_rft_plot(ts).layout))
		# hline! on an explicit date y axis.
		dy = plot_scatter([1.0, 2.0], [1.0, 2.0])
		relayout!(dy; yaxis_type = "date")
		hline!(dy, D.Date(2024, 3, 1))
		@test _rft(_rft_shapes(dy)[end], :y0) == "2024-03-01"
		# Errors: a date on a numeric axis (declared, or autotyped by numeric
		# data), mixed date/number ends, rounded date rectangles.
		@test _rft_throws(() -> hline!(ts, D.Date(2024, 1, 2)),
			"hline!: `y` = 2024-01-02 is a date, which can only be placed on a date axis; this axis has type \"linear\"")
		lin = plot_scatter([1.0, 2.0], [1.0, 2.0]; xscale = "log")
		@test _rft_throws(() -> vline!(lin, D.Date(2024, 1, 2)), "this axis has type \"log\"")
		@test _rft_throws(() -> vspan!(ts, D.Date(2024, 1, 2), 3), "vspan!: `x0` and `x1` must both be dates or both be numbers")
		@test _rft_throws(() -> arrow!(ts, D.Date(2024, 1, 2), 1.0, 5.0, 2.0), "arrow!: `x0` and `x1` must both be dates or both be numbers")
		@test _rft_throws(() -> rectangle!(ts, D.Date(2024, 1, 2), 1.0, D.Date(2024, 1, 3), 2.0; rounded = 0.1),
			"rectangle!: a rounded rectangle is defined by lengths in data units, which date corners do not have")
		n = length(_rft_shapes(ts))
		@test _rft_throws(() -> vline!(ts, [D.Date(2024, 1, 2), D.Date(2024, 1, 3)]; color = "notacolour"), "vline!")
		@test length(_rft_shapes(ts)) == n
		# Numbers are unchanged on numeric axes, and the autotyped axis of an
		# empty figure takes dates.
		num = plot_scatter([1.0, 2.0], [1.0, 2.0])
		vline!(num, 1.5)
		@test _rft(_rft_shapes(num)[end], :x0) == 1.5
		blank = Plot()
		vline!(blank, D.Date(2024, 1, 2))
		@test _rft(_rft_shapes(blank)[end], :x0) == "2024-01-02"
		# SubplotFigure cell with date data.
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, days, collect(1.0:10.0); row = 1, col = 2)
		vspan!(sf, D.Date(2024, 1, 2), D.Date(2024, 1, 3); row = 1, col = 2)
		s = _rft_shapes(sf)[end]
		@test (_rft(s, :xref), _rft(s, :x0)) == ("x2", "2024-01-02")
		plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row = 1, col = 1)
		@test _rft_throws(() -> vline!(sf, D.Date(2024, 1, 2); row = 1, col = 1), "vline!: `x` = 2024-01-02 is a date")
		for f in (hline!, vline!, hspan!, vspan!, rectangle!, arrow!)
			@test occursin("Date", string(Base.Docs.doc(f)))
		end
	end
end

@testset "sci reference.jl: wave 5 (fields)" begin
	@testset "Z64 reference lines and shapes: the style's reference width, the template's ink" begin
		line(item) = (_rft(item, :line, :color), _rft(item, :line, :width))
		draw!(f) = (hline!(f, 1); vline!(f, 1); circle!(f, 0, 0, 1); ellipse!(f, 0, 0, 2, 1);
			rectangle!(f, 0, 0, 1, 1); polygon!(f, [0, 1, 1], [0, 0, 1]); vspan!(f, 0, 1; edgecolor = "red"))
		# Default style, light template: black ink, 1 px.
		f = plot_scatter(1:3, 1:3)
		draw!(f)
		shapes = _rft_shapes(f)
		@test length(shapes) == 7
		@test all(s -> line(s) == ("#000000", 1), shapes[1:6])
		@test line(shapes[7])[2] == 1
		# A journal style: its `reference_linewidth` (0.75 pt in px).
		with_style(:ieee) do
			g = plot_scatter(1:3, 1:3)
			draw!(g)
			@test all(s -> line(s)[2] ≈ 0.75 * _RFT._PT_PX, _rft_shapes(g))
			# An explicit width wins.
			hline!(g, 2; linewidth = 3)
			@test line(_rft_shapes(g)[end])[2] == 3
		end
		# A dark template: the template's light ink, so the line stays visible.
		d = plot_scatter(1:3, 1:3)
		relayout!(d; template = _RFT_PB.templates[:plotly_dark])
		draw!(d)
		ink = _RFT._style_ink(d)
		# (hex colours are written upper-case: "#f2f5fa" -> "#F2F5FA")
		@test lowercase(ink) != "#000000" && all(s -> lowercase(line(s)[1]) == lowercase(ink), _rft_shapes(d)[1:6])
		# An explicit colour wins.
		hline!(d, 2; color = "red")
		@test line(_rft_shapes(d)[end])[1] != ink
	end
end
