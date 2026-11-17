using Test, PlotlySupply

# Regression tests for the extended charts (pie, funnelarea, sunburst,
# treemap, funnel, waterfall, indicator, candlestick, ohlc, sankey,
# parcoords, ternary) and the 2-D `annotate!`. Finding numbers refer to the
# 2.0 audit.

_rx_fields(value) = value isa AbstractDict ? value : value.fields
_rx_get(value, keys::Symbol...) =
	foldl((current, key) -> _rx_fields(current)[key], keys; init = value)
_rx_has(value, key::Symbol) = haskey(_rx_fields(value), key)
_rx_trace(fig) = only(fig.data)
_rx_layout(fig) = _rx_fields(fig.layout)
_rx_scale(name) = PlotlySupply._resolve_colorscale(name; who = "test").scale

# `f()` throws an ArgumentError whose message contains `needle`.
function _rx_throws(f, needle::AbstractString)
	try
		f()
	catch err
		err isa ArgumentError || return false
		return occursin(needle, err.msg)
	end
	return false
end

# A mutator call that throws leaves the figure exactly as it was.
function _rx_atomic(fig, f, needle::AbstractString)
	before = json(fig)
	thrown = _rx_throws(f, needle)
	return thrown && json(fig) == before
end

@testset "regression: extended charts" begin
	@testset "plot_indicator mode, delta and gauge (findings 120, 125, 247)" begin
		# Default mode used to be "number+delta", which drew a zero delta.
		plain = _rx_trace(plot_indicator(42))
		@test plain.fields[:mode] == "number"
		@test !haskey(plain.fields, :delta)
		@test !haskey(plain.fields, :gauge)

		# A reference adds the delta.
		delta = _rx_trace(plot_indicator(72; reference = 65))
		@test delta.fields[:mode] == "number+delta"
		@test _rx_get(delta, :delta, :reference) == 65
		@test _rx_throws(() -> plot_indicator(1; mode = "number+delta"), "no `reference`")

		# gauge_range = 0:100 used to become a 101-element axis range.
		@test _rx_throws(() -> plot_indicator(50; gauge_range = 0:100), "exactly 2 elements")
		gauge = _rx_trace(plot_indicator(50; gauge_range = (0, 100)))
		@test gauge.fields[:mode] == "number+gauge"
		@test _rx_get(gauge, :gauge, :axis, :range) == [0, 100]
		@test _rx_get(gauge, :gauge, :shape) == "angular"
		@test _rx_throws(() -> plot_indicator(1; gauge_range = [100, 0]), "lo < hi")
		@test _rx_throws(() -> plot_indicator(1; gauge_range = [0, Inf]), "lo < hi")
		@test _rx_throws(() -> plot_indicator(1; gauge_range = 5), "2-element")

		# gauge_shape used to be dropped without a gauge_range.
		bullet = _rx_trace(plot_indicator(3; gauge_shape = "bullet"))
		@test bullet.fields[:mode] == "number+gauge"
		@test _rx_get(bullet, :gauge, :shape) == "bullet"
		@test !_rx_has(_rx_get(bullet, :gauge), :axis)
		explicit = _rx_trace(plot_indicator(3; mode = "gauge"))
		@test explicit.fields[:mode] == "gauge"
		@test _rx_get(explicit, :gauge, :shape) == "angular"

		@test _rx_throws(() -> plot_indicator(1; mode = "numbr"), "`mode` must combine")
		@test _rx_throws(() -> plot_indicator(1; mode = "number+number"), "twice")
		@test _rx_throws(() -> plot_indicator(1; gauge_shape = "round"), "`gauge_shape`")
		@test _rx_throws(() -> plot_indicator(NaN), "`value` must be a finite")
		@test _rx_throws(() -> plot_indicator(1; reference = Inf), "`reference` must be a finite")

		suffix = plot_indicator(0.5; number_suffix = "%", title = "Uptime \$\\eta\$", width = 400.5, fontsize = 18)
		@test _rx_get(_rx_trace(suffix), :number, :suffix) == "%"
		@test _rx_get(suffix.layout, :title, :text) == PlotlySupply._label("Uptime \$\\eta\$")
		@test _rx_layout(suffix)[:width] == 400.5
		@test _rx_get(suffix.layout, :font, :size) == 18

		fig = plot_indicator(1)
		@test _rx_atomic(fig, () -> plot_indicator!(fig, 2; gauge_range = 0:10), "exactly 2")
		@test _rx_atomic(fig, () -> plot_indicator!(fig, 2; show = true), "do not take `show`")
		@test plot_indicator!(fig, 2; reference = 1) === nothing
		@test fig.data[end].fields[:mode] == "number+delta"
	end

	@testset "sunburst/treemap repeated labels, ids and branchvalues (findings 129, 246)" begin
		labels = ["2023", "2024", "Q1", "Q1"]
		parents = ["", "", "2023", "2024"]
		for (constructor, mutator) in ((plot_sunburst, plot_sunburst!), (plot_treemap, plot_treemap!))
			# A repeated label used to merge two sectors and drop a branch.
			@test _rx_throws(() -> constructor(labels, parents), "\"Q1\" more than once")
			target = Plot()
			@test _rx_atomic(target, () -> mutator(target, labels, parents), "Pass unique `ids`")

			ids = ["2023", "2024", "2023/Q1", "2024/Q1"]
			fig = constructor(labels, ["", "", "2023", "2024"]; ids = ids, values = [0, 0, 1, 2], branchvalues = :total)
			trace = _rx_trace(fig)
			@test trace.fields[:ids] === ids
			@test trace.fields[:labels] === labels
			@test trace.fields[:branchvalues] == "total"
			@test !haskey(_rx_trace(constructor(["a", "b"], ["", "a"])).fields, :branchvalues)
			@test _rx_trace(constructor(["a", "b"], ["", "a"]; branchvalues = "remainder")).fields[:branchvalues] == "remainder"
			@test _rx_throws(() -> constructor(["a", "b"], ["", "a"]; branchvalues = "sum"), "`branchvalues`")
			@test _rx_throws(() -> constructor(labels, parents; ids = ["a", "b", "c", "a"]), "`ids` must be unique")
			@test _rx_throws(() -> constructor(labels, parents; ids = ["a", "b", "", "d"]), "`ids[3]`")
			@test _rx_throws(() -> constructor(labels, parents; ids = ["a", "b"]), "`ids` must have one entry")

			@test mutator(target, labels, parents; ids = ids) === nothing
			@test _rx_trace(target).fields[:ids] === ids

			# Value checks.
			@test _rx_throws(() -> constructor(["a", "b"], ["", "a"]; values = [1, -1]), "non-negative")
			@test _rx_throws(() -> constructor(["a", "b"], ["", "a"]; values = [1, NaN]), "finite")
			@test _rx_throws(() -> constructor(["a", "b"], ["", "a"]; values = ["1", "x"]), "must be a number")
			@test _rx_throws(() -> constructor(["a", "b"], ["", "a"]; colors = ["red"]), "`colors`")
			@test _rx_throws(() -> constructor(["a", "b"], ["", "a"]; colorscale = "no_such_map"), "unknown colorscale \"no_such_map\"")

			# C20 colour scales.
			scaled = _rx_trace(constructor(["a", "b"], ["", "a"]; values = [2, 1], colorscale = "viridis"))
			@test _rx_get(scaled, :marker, :colorscale) == _rx_scale("viridis")
			@test _rx_get(scaled, :marker, :colors) === scaled.fields[:values]

			# Slice text is drawn without MathJax: math labels are converted
			# and the original labels become the ids.
			math = _rx_trace(constructor(["\$\\alpha\$", "b"], ["", "\$\\alpha\$"]))
			@test math.fields[:labels] == ["α", "b"]
			@test math.fields[:ids] == ["\$\\alpha\$", "b"]
			@test math.fields[:parents] == ["", "\$\\alpha\$"]
			@test _rx_throws(() -> constructor(["Cost \$5", "b"], ["", "Cost \$5"]), "`labels[1]`")
		end
	end

	@testset "pie/funnelarea validation and labels" begin
		for (constructor, mutator) in ((plot_pie, plot_pie!), (plot_funnelarea, plot_funnelarea!))
			name = String(nameof(constructor))
			@test _rx_throws(() -> constructor([1, -1]), "$(name): `values[2]` must be non-negative")
			@test _rx_throws(() -> constructor([1, Inf]), "finite")
			@test _rx_throws(() -> constructor([1, 2]; labels = ["a"]), "`labels` must have one entry")
			@test _rx_throws(() -> constructor([1, 2]; colors = ["red"]), "`colors` must have one entry")
			@test _rx_throws(() -> constructor([1, 2]; colors = ["red", 3]), "`colors[2]`")
			coloured = _rx_trace(constructor([1, 2]; colors = [:red, "blue"]))
			@test _rx_get(coloured, :marker, :colors) == ["red", "blue"]
			@test !haskey(_rx_trace(constructor([1, 2]; colors = String[])).fields, :marker)
			labelled = _rx_trace(constructor([1, 2]; labels = ["\$\\beta_1\$", "x"]))
			@test labelled.fields[:labels] == [PlotlySupply._label_plain("\$\\beta_1\$"), "x"]
			@test !occursin('\$', labelled.fields[:labels][1])

			fig = constructor([1, 2]; title = "Share \$p\$", width = 500, height = 300.5, fontsize = 14)
			@test _rx_get(fig.layout, :title, :text) == PlotlySupply._label("Share \$p\$")
			@test _rx_layout(fig)[:height] == 300.5
			@test _rx_get(fig.layout, :font, :size) == 14
			@test _rx_throws(() -> constructor([1, 2]; width = -1), "`width`")

			target = Plot()
			@test _rx_atomic(target, () -> mutator(target, [1, -2]), "non-negative")
			@test _rx_atomic(target, () -> mutator(target, [1]; show = false), "do not take `show`")
			@test _rx_atomic(target, () -> mutator(target, [1]; row = 1, col = 1), "a single figure has one cell")
			@test mutator(target, [3, 4]; title = "t") === nothing
			@test _rx_get(target.layout, :title, :text) == "t"
		end
		@test _rx_throws(() -> plot_pie([1, 2]; hole = 1), "`hole`")
		@test _rx_throws(() -> plot_pie([1, 2]; hole = -0.1), "`hole`")
		@test _rx_trace(plot_pie([1, 2]; hole = 0.5)).fields[:hole] == 0.5
	end

	@testset "funnel and waterfall on Cartesian axes" begin
		funnel_fig = plot_funnel([100, 60, 30], ["A", "B", "C"]; xlabel = "Users", title = "Conversion",
			color = [:red, "green", "blue"], legend = "2024", grid = false)
		trace = _rx_trace(funnel_fig)
		@test _rx_get(trace, :marker, :color) == ["red", "green", "blue"]
		@test trace.fields[:name] == "2024"
		@test _rx_get(funnel_fig.layout, :xaxis, :title, :text) == "Users"
		# Plotly hides a funnel's value axis; an x-axis title shows it.
		@test _rx_get(funnel_fig.layout, :xaxis, :visible) === true
		@test !_rx_has(_rx_get(plot_funnel([1, 2], ["a", "b"]).layout, :xaxis), :visible)
		@test _rx_get(funnel_fig.layout, :title, :text) == "Conversion"
		@test _rx_get(funnel_fig.layout, :xaxis, :showgrid) === false
		@test _rx_throws(() -> plot_funnel([1, 2], ["a"]), "`y` must have one entry")
		@test _rx_throws(() -> plot_funnel(["x", "y"], ["a", "b"]), "`x[1]` must be a real number")
		@test _rx_throws(() -> plot_funnel([1, 2], ["a", "b"]; color = ["red"]), "`color`")
		@test _rx_throws(() -> plot_funnel([1, 2], ["a", "b"]; xrange = [1, 2, 3]), "`xrange`")
		log_fig = plot_scatter([1, 10], [1, 2]; xscale = "log")
		@test _rx_atomic(log_fig, () -> plot_funnel!(log_fig, [1, 2], ["a", "b"]), "logarithmic")
		target = plot_funnel([1, 2], ["a", "b"])
		@test _rx_atomic(target, () -> plot_funnel!(target, [1, 2], ["a", "b"]; secondary_y = true), "secondary y axis")

		waterfall_fig = plot_waterfall(["a", "b", "c"], [10, -3, missing]; measure = [:absolute, :relative, :total],
			ylabel = "k€", yrange = (-5, 20))
		trace = _rx_trace(waterfall_fig)
		@test trace.fields[:measure] == ["absolute", "relative", "total"]
		@test _rx_get(waterfall_fig.layout, :yaxis, :range) == [-5, 20]
		@test _rx_throws(() -> plot_waterfall(["a"], [1]; measure = ["sum"]), "`measure[1]`")
		@test _rx_throws(() -> plot_waterfall(["a", "b"], [1, NaN]; measure = ["relative", "relative"]), "`y[2]`")
		@test _rx_throws(() -> plot_waterfall(["a", "b"], [1, NaN]), "`y[2]` must be finite")
		@test _rx_throws(() -> plot_waterfall(["a", "b"], [1]), "`y` must have one entry")
		@test_throws MethodError plot_waterfall(["a"], [1]; yscale = "log")
		log_y = plot_scatter([1, 2], [1, 10]; yscale = "log")
		@test _rx_atomic(log_y, () -> plot_waterfall!(log_y, ["a"], [1]), "logarithmic")
		matrix = reshape(collect(1.0:4.0), 2, 2)
		@test _rx_throws(() -> plot_waterfall(view(matrix, :, :), view(matrix, :, :)), "must be a vector")
	end

	@testset "candlestick/ohlc validation and axis options" begin
		data = (1:3, [1.0, 2.0, 3.0], [2.0, 3.0, 4.0], [0.5, 1.0, 2.0], [1.5, 2.5, 3.5])
		for (constructor, mutator) in ((plot_candlestick, plot_candlestick!), (plot_ohlc, plot_ohlc!))
			fig = constructor(data...; yscale = "log", yrange = [0.1, 10], increasing_color = :teal,
				decreasing_color = "orange", legend = "ACME", xlabel = "day", title = "Prices")
			trace = _rx_trace(fig)
			@test _rx_get(trace, :increasing, :line, :color) == "teal"
			@test _rx_get(trace, :decreasing, :line, :color) == "orange"
			@test trace.fields[:name] == "ACME"
			@test _rx_get(fig.layout, :yaxis, :type) == "log"
			@test _rx_get(fig.layout, :yaxis, :range) ≈ [-1.0, 1.0]
			@test _rx_get(fig.layout, :xaxis, :title, :text) == "day"

			@test _rx_throws(() -> constructor(1:3, [1, 2], [2, 3, 4], [0, 1, 2], [1, 2, 3]), "`open` must have one entry")
			@test _rx_throws(() -> constructor(1:2, [1, 2], [2, 3], [0, 1], [1, Inf]), "`close[2]` must be finite")
			@test _rx_throws(() -> constructor(1:2, [1, 2], [2, 3], [0, 1], ["1", 2]), "`close[1]` must be a real number")
			@test _rx_throws(() -> constructor(1:2, [1, 2], [2, 3], [0, 1], [1, 2]; yscale = "log"), "`low[1]` is on a logarithmic axis")
			gaps = _rx_trace(constructor(1:3, [1.0, NaN, 3.0], [2.0, missing, 4.0], [0.5, nothing, 2.0], [1.5, NaN, 3.5]))
			@test isnan(gaps.fields[:open][2])

			target = plot_scatter(1:3, [1, 2, 3])
			@test _rx_atomic(target, () -> mutator(target, data...; secondary_y = true), "secondary y axis")
			@test _rx_atomic(target, () -> mutator(target, data...; show = true), "do not take `show`")
			@test _rx_atomic(target, () -> mutator(target, data...; xrange = [1, 2, 3]), "`xrange`")
			@test mutator(target, data...; ylabel = "price", xrange = (0, 4)) === nothing
			@test _rx_get(target.layout, :yaxis, :title, :text) == "price"
			@test _rx_get(target.layout, :xaxis, :range) == [0, 4]

			twin = subplots(1, 1; sync = false, specs = Union{Missing, Spec}[Spec(secondary_y = true);;])
			@test mutator(twin, data...; secondary_y = true) === twin
			@test only(twin.data).fields[:yaxis] == "y2"

			# The target cell's log axis is checked although the trace is
			# staged on an empty figure.
			log_cell = subplots(1, 2; sync = false)
			plot_scatter!(log_cell, 1:3, [1, 10, 100]; row = 1, col = 2, yscale = "log")
			bad = (1:2, [1, 2], [2, 3], [0, 1], [1, 2])
			@test _rx_atomic(log_cell.fig, () -> mutator(log_cell, bad...; row = 1, col = 2), "`low[1]` is on a logarithmic axis")
			@test mutator(log_cell, bad...; row = 1, col = 2, yscale = "linear") === log_cell
			@test mutator(log_cell, bad...; row = 1, col = 1) === log_cell
		end
	end

	@testset "SubplotFigure funnel/waterfall reject a log value axis in the cell" begin
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, [1, 10], [1, 10]; row = 1, col = 1, xscale = "log", yscale = "log")
		@test _rx_atomic(sf.fig, () -> plot_waterfall!(sf, ["a"], [1]; row = 1, col = 1), "logarithmic")
		@test _rx_atomic(sf.fig, () -> plot_funnel!(sf, [1, 2], ["a", "b"]; row = 1, col = 1), "logarithmic")
		@test plot_waterfall!(sf, ["a"], [1]; row = 1, col = 2) === sf
		@test plot_funnel!(sf, [1, 2], ["a", "b"]; row = 1, col = 2, xlabel = "n") === sf
		@test _rx_get(sf.fig.layout, :xaxis2, :visible) === true
	end

	@testset "sankey validation and colours" begin
		fig = plot_sankey([0, 0, 1], [1, 2, 2], [3, 1, 2]; label = ["\$x_0\$", "b", "c"],
			node_color = [:red, "green", "blue"], link_color = ["gray", "gray", "black"])
		trace = _rx_trace(fig)
		@test _rx_get(trace, :node, :label) == [PlotlySupply._label_plain("\$x_0\$"), "b", "c"]
		@test _rx_get(trace, :node, :color) == ["red", "green", "blue"]
		@test _rx_get(trace, :link, :color) == ["gray", "gray", "black"]
		@test _rx_get(_rx_trace(plot_sankey([0], [1], [1]; node_color = :teal)), :node, :color) == "teal"
		uncoloured = _rx_trace(plot_sankey([0], [1], [1]; node_color = String[]))
		@test !haskey(uncoloured.fields, :node) || !_rx_has(_rx_get(uncoloured, :node), :color)
		# Indices beyond the labels are plotly nodes, not an error.
		@test plot_sankey([0], [5], [1]; label = ["a", "b"]) isa Plot
		@test _rx_throws(() -> plot_sankey([0], [2], [1]; node_color = ["r", "g"]), "3 nodes")
		@test _rx_throws(() -> plot_sankey([0, 1], [1], [1, 2]), "`target` must have one entry")
		@test _rx_throws(() -> plot_sankey([0, 1], [1, 2], [1]), "`value` must have one entry")
		@test _rx_throws(() -> plot_sankey([-1], [1], [1]), "`source[1]` must be non-negative")
		@test _rx_throws(() -> plot_sankey([0.5], [1], [1]), "`source[1]` must be an integer")
		@test _rx_throws(() -> plot_sankey([0], [1], [-2]), "`value[1]` must be non-negative")
		@test _rx_throws(() -> plot_sankey([0], [1], [1]; link_color = ["a", "b"]), "`link_color`")
		target = Plot()
		@test _rx_atomic(target, () -> plot_sankey!(target, [0], [1], [NaN]), "finite")
		@test plot_sankey!(target, [0], [1], [1]; title = "Flows") === nothing
		@test _rx_get(target.layout, :title, :text) == "Flows"
	end

	@testset "parcoords title margin and validation (finding 250)" begin
		dims = ["mass \$m\$" => [1.2, 3.4, 2.2], "speed" => [10, 4, 7]]
		untitled = plot_parcoords(dims)
		titled = plot_parcoords(dims; title = "Trade-offs")
		# The title used to share the default top band with the labels.
		@test _rx_get(titled.layout, :margin, :t) == ceil(Int, 56 + 2 * 12 + 1.4 * 12 + 8)
		@test _rx_get(plot_parcoords(dims; title = "T", fontsize = 20).layout, :margin, :t) ==
			ceil(Int, 56 + 2 * 20 + 1.4 * 20 + 8)
		# Without a title the PlotlyBase default top margin (60 px) is kept.
		@test _rx_get(untitled.layout, :margin, :t) == 60
		roomy = plot_parcoords(dims)
		relayout!(roomy, margin = attr(t = 300, l = 80))
		@test plot_parcoords!(roomy, dims; title = "T") === nothing
		@test _rx_get(roomy.layout, :margin, :t) == 300
		@test _rx_get(roomy.layout, :margin, :l) == 80

		trace = _rx_trace(plot_parcoords(dims; line_color = [1, 2, 3], colorscale = "magma"))
		# Parcoords titles are drawn as plain Unicode (MathJax output is misplaced).
		@test _rx_get(trace, :dimensions)[1][:label] == PlotlySupply._label_plain("mass \$m\$")
		@test !occursin('\$', _rx_get(trace, :dimensions)[1][:label])
		@test _rx_get(trace, :line, :colorscale) == _rx_scale("magma")
		@test _rx_get(_rx_trace(plot_parcoords(dims; line_color = :teal)), :line, :color) == "teal"
		@test _rx_throws(() -> plot_parcoords(Pair{String, Vector{Int}}[]), "must not be empty")
		@test _rx_throws(() -> plot_parcoords(["a" => [1, 2], "b" => [1]]), "same number of values")
		@test _rx_throws(() -> plot_parcoords(dims; line_color = [1, 2]), "`line_color` must have one entry")
		@test _rx_throws(() -> plot_parcoords(dims; colorscale = "viridis"), "pass `line_color` too")
		@test _rx_throws(() -> plot_parcoords(dims; line_color = "red", colorscale = "viridis"), "numeric `line_color`")
		@test _rx_throws(() -> plot_parcoords([1, 2]), "`dimensions[1]`")
		@test _rx_throws(() -> plot_parcoords(["a" => [1, Inf]]), "finite")
	end

	@testset "ternary validation and corner titles" begin
		fig = plot_ternary([0.6, 0.2], [0.3, 0.5], [0.1, 0.3]; mode = "lines+markers", color = :teal,
			marker_size = [8, 12], alabel = "Sand \$\\phi\$", legend = "soil")
		trace = _rx_trace(fig)
		@test _rx_get(trace, :marker, :color) == "teal"
		@test _rx_get(trace, :line, :color) == "teal"
		@test _rx_get(trace, :marker, :size) == [8, 12]
		@test _rx_get(fig.layout, :ternary, :aaxis, :title, :text) == PlotlySupply._label("Sand \$\\phi\$")
		@test _rx_throws(() -> plot_ternary([1, 2], [1], [1, 2]), "`b` must have one entry")
		@test _rx_throws(() -> plot_ternary([1], [-1], [1]), "`b[1]` must be non-negative")
		@test _rx_throws(() -> plot_ternary([0], [0], [0]), "positive sum")
		@test _rx_throws(() -> plot_ternary([1], [1], [1]; mode = "dots"), "`mode`")
		@test _rx_throws(() -> plot_ternary([1], [1], [1]; marker_size = -1), "`marker_size`")
		@test plot_ternary([1, NaN], [1, 1], [1, 1]) isa Plot
		target = plot_ternary([1], [1], [1]; alabel = "A")
		@test _rx_atomic(target, () -> plot_ternary!(target, [1], [1], [1]; alabel = "\$x"), "`alabel`")
		@test plot_ternary!(target, [1], [1], [1]; blabel = "B") === nothing
		@test _rx_get(target.layout, :ternary, :aaxis, :title, :text) == "A"
		@test _rx_get(target.layout, :ternary, :baxis, :title, :text) == "B"
	end

	@testset "mutators reject show and cell selectors on a single figure" begin
		calls = (
			(plot_pie!, ([1, 2],)),
			(plot_funnelarea!, ([1, 2],)),
			(plot_sunburst!, (["a", "b"], ["", "a"])),
			(plot_treemap!, (["a", "b"], ["", "a"])),
			(plot_indicator!, (1,)),
			(plot_sankey!, ([0], [1], [1])),
			(plot_parcoords!, (["a" => [1, 2]],)),
			(plot_ternary!, ([1], [1], [1])),
			(plot_funnel!, ([1, 2], ["a", "b"])),
			(plot_waterfall!, (["a"], [1])),
			(plot_candlestick!, (1:1, [1], [2], [0.5], [1.5])),
			(plot_ohlc!, (1:1, [1], [2], [0.5], [1.5])),
		)
		for (mutator, args) in calls
			fig = Plot()
			@test _rx_atomic(fig, () -> mutator(fig, args...; show = true), "$(nameof(mutator)): mutators do not take `show`")
			@test _rx_atomic(fig, () -> mutator(fig, args...; row = 1, col = 1), "$(nameof(mutator)): `row`/`col`")
			@test_throws MethodError mutator(fig, args...; no_such_option = 1)
		end
	end

	@testset "dead helpers removed (findings 123, 133, 252)" begin
		@test !isdefined(PlotlySupply, :_tuple_interleave)
		for helper in (PlotlySupply._pie_trace, PlotlySupply._hierarchy_trace)
			@test all(method -> !(:name in Base.kwarg_decl(method)), methods(helper))
		end
	end
end

@testset "regression: annotate!" begin
	@testset "font passthrough keeps fontsize (finding 121)" begin
		fig = plot_scatter(1:3, [1, 2, 3])
		@test annotate!(fig, 1, 1, "t"; fontsize = 20, font = attr(color = "red", family = "Courier")) === fig
		font = _rx_get(only(_rx_layout(fig)[:annotations]), :font)
		@test _rx_fields(font)[:size] == 20
		@test _rx_fields(font)[:color] == "red"
		@test _rx_fields(font)[:family] == "Courier"
		# Deprecated alias, the original finding's spelling.
		legacy = plot_scatter(1:3, [1, 2, 3])
		annotate!(legacy, 1, 1, "t"; font_size = 20, font = attr(color = "red"))
		@test _rx_get(only(_rx_layout(legacy)[:annotations]), :font, :size) == 20
		@test _rx_atomic(legacy, () -> annotate!(legacy, 1, 1, "u"; font_size = 10, fontsize = 12), "disagree")
		# Explicit fontsize/color win over a `font` passthrough.
		winner = plot_scatter(1:3, [1, 2, 3])
		annotate!(winner, 1, 1, "t"; fontsize = 9, color = "blue", font = attr(size = 30, color = "red"), font_family = "Arial")
		font = _rx_fields(_rx_get(only(_rx_layout(winner)[:annotations]), :font))
		@test (font[:size], font[:color], font[:family]) == (9, "blue", "Arial")
	end

	@testset "SubplotFigure method uses the active cell (findings 5, 41, 53, 116, 130, 217, 284)" begin
		sf = subplots(2, 1; sync = false)
		plot_scatter!(sf, 1:3, [1, 2, 3]; row = 2, col = 1)
		# The annotation used to land in cell (1, 1) (xref "x") whatever cell was active.
		@test annotate!(sf, 2, 2, "active") === sf
		active = only(_rx_layout(sf.fig)[:annotations])
		@test (active[:xref], active[:yref]) == ("x2", "y2")
		@test annotate!(sf, 0.5, 0.9, "top"; row = 1, col = 1, coords = :axes) === sf
		@test (sf.current_row, sf.current_col) == (1, 1)
		top = last(_rx_layout(sf.fig)[:annotations])
		@test (top[:xref], top[:yref]) == ("x domain", "y domain")
		@test _rx_atomic(sf.fig, () -> annotate!(sf, 1, 1, "bad"; row = 3, col = 1), "`row` must be in 1:2")

		twin = subplots(1, 1; sync = false, specs = Union{Missing, Spec}[Spec(secondary_y = true);;])
		annotate!(twin, 1, 1, "right axis"; secondary_y = true)
		@test only(_rx_layout(twin.fig)[:annotations])[:yref] == "y2"

		pies = subplots(1, 2; sync = false, specs = [Spec(kind = "domain") Spec(kind = "domain")])
		@test _rx_throws(() -> annotate!(pies, 0.5, 0.5, "x"; row = 1, col = 2), "`coords = :data` needs Cartesian")
		annotate!(pies, 0.5, 1.0, "right pie"; row = 1, col = 2, coords = :axes, showarrow = false)
		label = only(_rx_layout(pies.fig)[:annotations])
		@test label[:xref] == "paper"
		domain = PlotlySupply._cell_target(pies; row = 1, col = 2).xdomain
		@test label[:x] ≈ (domain[1] + domain[2]) / 2
	end

	@testset "coordinate systems, log axes and offsets" begin
		fig = plot_scatter(1:100, (1:100) .^ 2; yscale = "log", xscale = "log")
		annotate!(fig, 50, 1000, "knee"; offset = (30, 20), color = "firebrick")
		knee = last(_rx_layout(fig)[:annotations])
		@test knee[:x] ≈ log10(50)
		@test knee[:y] ≈ 3.0
		@test (knee[:ax], knee[:ay]) == (30, -20)
		@test knee[:arrowcolor] == "firebrick"
		@test _rx_get(knee, :font, :color) == "firebrick"
		annotate!(fig, 0.02, 0.95, "(a)"; coords = :axes, showarrow = false, offset = (4, -2))
		panel = last(_rx_layout(fig)[:annotations])
		@test (panel[:xref], panel[:yref], panel[:x], panel[:y]) == ("x domain", "y domain", 0.02, 0.95)
		@test (panel[:xshift], panel[:yshift]) == (4, -2)
		annotate!(fig, 0.5, 1.02, "caption"; coords = :figure, showarrow = false)
		@test (last(_rx_layout(fig)[:annotations])[:xref], last(_rx_layout(fig)[:annotations])[:yref]) == ("paper", "paper")
		annotate!(fig, 10, 100, "tail"; axref = "x", ayref = "y", ax = 100, ay = 10_000, arrowcolor = "black", color = "red")
		tail = last(_rx_layout(fig)[:annotations])
		@test (tail[:ax], tail[:ay]) == (2.0, 4.0)
		@test tail[:arrowcolor] == "black"
		annotate!(fig, 0.5, 10, "mixed"; xref = "x domain")
		mixed = last(_rx_layout(fig)[:annotations])
		@test (mixed[:xref], mixed[:x], mixed[:yref], mixed[:y]) == ("x domain", 0.5, "y", 1.0)

		count = length(_rx_layout(fig)[:annotations])
		for (call, needle) in (
			(() -> annotate!(fig, 0, 10, "zero"), "cannot be placed on logarithmic"),
			(() -> annotate!(fig, "a", 10, "cat"), "positive number"),
			(() -> annotate!(fig, 1, 1, "x"; coords = :pixels), "`coords`"),
			(() -> annotate!(fig, 1, 1, "x"; xref = "z"), "`xref`"),
			(() -> annotate!(fig, 1, 1, "x"; xref = "x7"), "does not have"),
			(() -> annotate!(fig, 1, 1, "x"; arowhead = 2), "unknown keyword `arowhead`"),
			(() -> annotate!(fig, 1, 1, "x"; x = 2), "positional"),
			(() -> annotate!(fig, 1, 1, "x"; offset = (1, 1), ax = 3), "`offset` and `ax`"),
			(() -> annotate!(fig, 1, 1, "x"; showarrow = false, offset = (1, 1), yshift = 3), "`offset` and `yshift`"),
			(() -> annotate!(fig, 1, 1, "x"; offset = (1, 2, 3)), "`offset`"),
			(() -> annotate!(fig, 1, 1, "x"; align = "justify"), "`align`"),
			(() -> annotate!(fig, 1, 1, "cost \$5"), "`text`"),
			(() -> annotate!(fig, 1, 1, "x"; row = 1, col = 1), "a single figure has one cell"),
			(() -> annotate!(fig, 1, 1, "x"; secondary_y = true), "no secondary y-axis"),
			(() -> annotate!(fig, 2, 2, "x"; coords = :axes, fontsize = -1), "`fontsize`"),
		)
			@test _rx_atomic(fig, call, needle)
		end
		@test length(_rx_layout(fig)[:annotations]) == count

		linear = plot_scatter(["a", "b"], [1, 2])
		annotate!(linear, "b", 2, "category")
		@test only(_rx_layout(linear)[:annotations])[:x] == "b"
		@test _rx_throws(() -> annotate!(linear, 1, Inf, "x"), "must be finite")

		pie_fig = plot_pie([1, 2])
		@test _rx_throws(() -> annotate!(pie_fig, 0.5, 0.5, "x"), "`coords = :data` needs Cartesian")
		annotate!(pie_fig, 0.5, 0.5, "centre"; coords = :axes, showarrow = false)
		@test only(_rx_layout(pie_fig)[:annotations])[:xref] == "paper"
	end

	@testset "text through mathtext, LaTeXString accepted (finding 56)" begin
		fig = plot_scatter(1:3, [1, 2, 3])
		annotate!(fig, 1, 1, "Time \$t\$ (s)"; align = "left")
		first_note = only(_rx_layout(fig)[:annotations])
		@test first_note[:text] == PlotlySupply._label("Time \$t\$ (s)"; align = :l)
		@test first_note[:align] == "left"
		annotate!(fig, 2, 2, L"\alpha^2")
		@test last(_rx_layout(fig)[:annotations])[:text] == PlotlySupply._label(L"\alpha^2")
		# Existing annotations are kept, in order.
		@test length(_rx_layout(fig)[:annotations]) == 2
		@test first(_rx_layout(fig)[:annotations])[:text] == first_note[:text]
	end
end

# The subplot a SubplotFigure cell routes a trace to, per cell kind.
function _rx_cell_ref(trace, kind::AbstractString)
	fields = trace.fields
	kind == "xy" && return (fields[:xaxis], fields[:yaxis])
	kind == "domain" && return Tuple(_rx_get(fields[:domain], :x))
	return fields[:subplot]
end

@testset "regression: extended charts, v3 consistency" begin
	@testset "consistency sweep: every constructor and mutator, Plot and SubplotFigure" begin
		M = reshape(collect(1.0:12.0), 3, 4)
		title = L"Title $\alpha$"
		# (constructor, mutator, data (ranges and views), empty data, cell kind,
		#  stored-as-given field path => data argument, Symbol colour keyword,
		#  colour field path, expected colour value)
		cases = (
			(plot_pie, plot_pie!, (view(M, :, 1),), (Float64[],), "domain",
				(:values,) => 1, :colors => [:red, :green, :blue], (:marker, :colors), ["red", "green", "blue"]),
			(plot_funnelarea, plot_funnelarea!, (1:3,), (Int[],), "domain",
				(:values,) => 1, :colors => [:red, :green, :blue], (:marker, :colors), ["red", "green", "blue"]),
			(plot_sunburst, plot_sunburst!, (["a", "b", "c"], view(["", "a", "a"], 1:3)), (String[], String[]), "domain",
				nothing, :colors => [:red, :green, :blue], (:marker, :colors), ["red", "green", "blue"]),
			(plot_treemap, plot_treemap!, (["a", "b", "c"], ["", "a", "a"]), (String[], String[]), "domain",
				nothing, :colors => [:red, :green, :blue], (:marker, :colors), ["red", "green", "blue"]),
			(plot_funnel, plot_funnel!, (1:3, ["a", "b", "c"]), (Int[], String[]), "xy",
				(:x,) => 1, :color => :teal, (:marker, :color), "teal"),
			(plot_waterfall, plot_waterfall!, (["a", "b", "c"], view(M, :, 2)), (String[], Float64[]), "xy",
				(:y,) => 2, nothing, (), nothing),
			(plot_candlestick, plot_candlestick!, (1:3, view(M, :, 1), view(M, :, 1) .+ 2, view(M, :, 1) .- 1, view(M, :, 1) .+ 1),
				(Int[], Float64[], Float64[], Float64[], Float64[]), "xy",
				(:open,) => 2, :increasing_color => :teal, (:increasing, :line, :color), "teal"),
			(plot_ohlc, plot_ohlc!, (1:3, [1, 2, 3], [3, 4, 5], [0, 1, 2], [2, 3, 4]),
				(Int[], Float64[], Float64[], Float64[], Float64[]), "xy",
				(:x,) => 1, :decreasing_color => :orange, (:decreasing, :line, :color), "orange"),
			(plot_sankey, plot_sankey!, (0:1, 1:2, view([1.0, 2.0], :)), (Int[], Int[], Float64[]), "domain",
				(:link, :value) => 3, :node_color => :teal, (:node, :color), "teal"),
			(plot_parcoords, plot_parcoords!, (["a" => 1:3, "b" => view(M, :, 1)],), (Pair{String, Vector{Int}}[],), "domain",
				nothing, :line_color => :teal, (:line, :color), "teal"),
			(plot_ternary, plot_ternary!, (1:2, view(M, 1:2, 1), [1, 1]), (Float64[], Float64[], Float64[]), "ternary",
				(:b,) => 2, :color => :teal, (:marker, :color), "teal"),
			(plot_indicator, plot_indicator!, (3,), nothing, "domain",
				nothing, nothing, (), nothing),
		)
		for (ctor, mut, data, empty, kind, stored, colour, colour_path, colour_value) in cases
			who = String(nameof(ctor))
			# Range / SubArray data, a LaTeXString title and the figure options
			# through the D7 primitives.
			fig = ctor(data...; title = title, width = 640.0, height = 480, fontsize = 13.0)
			layout = _rx_layout(fig)
			@test _rx_get(layout, :title, :text) == PlotlySupply._label(title)
			@test (layout[:width], layout[:height]) == (640, 480)
			@test _rx_get(layout, :font, :size) == 13
			if stored !== nothing
				path, position = stored
				@test _rx_get(_rx_trace(fig), path...) === data[position]
			end
			if colour !== nothing
				coloured = _rx_trace(ctor(data...; (colour,)...))
				@test _rx_get(coloured, colour_path...) == colour_value
			end
			empty === nothing || @test _rx_throws(() -> ctor(empty...), "$(who): `")
			@test_throws MethodError ctor(data...; no_such_option = 1)

			target = ctor(data...)
			@test mut(target, data...; title = L"New $\beta$", fontsize = 11) === nothing
			@test length(target.data) == 2
			@test _rx_get(_rx_layout(target), :title, :text) == PlotlySupply._label(L"New $\beta$")
			@test _rx_get(_rx_layout(target), :font, :size) == 11
			@test _rx_atomic(target, () -> mut(target, data...; show = true), "$(who)!: mutators do not take `show`")
			@test _rx_atomic(target, () -> mut(target, data...; title = "\$x"), "$(who)!: `title`")
			empty === nothing || @test _rx_atomic(target, () -> mut(target, empty...), "$(who)!: `")
			@test_throws MethodError mut(target, data...; no_such_option = 1)

			# A SubplotFigure cell of the right kind; the trace is routed there.
			sf = subplots(1, 2; sync = false, specs = [Spec(kind = kind) Spec(kind = kind)])
			@test mut(sf, data...; row = 1, col = 2) === sf
			@test (sf.current_row, sf.current_col) == (1, 2)
			cell = PlotlySupply._cell_target(sf; row = 1, col = 2)
			expected = kind == "xy" ? (cell.xref, cell.yref) :
				kind == "domain" ? cell.xdomain : "ternary2"
			@test _rx_cell_ref(last(sf.fig.data), kind) == expected
			@test _rx_atomic(sf.fig, () -> mut(sf, data...; show = true), "$(who)!: mutators do not take `show`")
			empty === nothing || @test _rx_atomic(sf.fig, () -> mut(sf, empty...; row = 1, col = 1), "$(who)!: `")
			@test_throws MethodError mut(sf, data...; no_such_option = 1)
			wrong = subplots(1, 1; sync = false, specs = reshape([Spec(kind = kind == "xy" ? "domain" : "xy")], 1, 1))
			@test _rx_atomic(wrong.fig, () -> mut(wrong, data...), "$(who)!: trace type")
		end
	end

	@testset "empty data is an ArgumentError naming the argument" begin
		for (call, needle) in (
			(() -> plot_pie(Int[]), "plot_pie: `values` is empty"),
			(() -> plot_funnelarea(Float64[]), "plot_funnelarea: `values` is empty"),
			(() -> plot_sunburst(String[], String[]), "plot_sunburst: `labels` is empty"),
			(() -> plot_treemap(String[], String[]), "plot_treemap: `labels` is empty"),
			(() -> plot_funnel(Int[], String[]), "plot_funnel: `x` is empty"),
			(() -> plot_waterfall(String[], Float64[]), "plot_waterfall: `x` is empty"),
			(() -> plot_candlestick(Int[], Int[], Int[], Int[], Int[]), "plot_candlestick: `x` is empty"),
			(() -> plot_ohlc(Int[], Int[], Int[], Int[], Int[]), "plot_ohlc: `x` is empty"),
			(() -> plot_sankey(Int[], Int[], Int[]), "plot_sankey: `source` is empty"),
			(() -> plot_ternary(Int[], Int[], Int[]), "plot_ternary: `a` is empty"),
		)
			@test _rx_throws(call, needle)
		end
		# Lengths are still checked against the first argument.
		@test _rx_throws(() -> plot_funnel([1], String[]), "plot_funnel: `y` must have one entry")
	end

	@testset "plot_ternary applies the active style's trace defaults (X10)" begin
		style = PlotStyle(; linewidth = 3, marker_size = 9, cycle = :dash_marker)
		with_style(style) do
			reference = plot_scatter(1:2, [1, 2]; mode = "lines")
			plot_scatter!(reference, 1:2, [2, 1]; mode = "lines")
			fig = plot_ternary([0.5, 0.2], [0.3, 0.5], [0.2, 0.3]; mode = "lines")
			@test plot_ternary!(fig, [0.1, 0.4], [0.6, 0.3], [0.3, 0.3]; mode = "lines", marker_size = 4) === nothing
			for index in 1:2
				@test _rx_get(fig.data[index], :line, :width) == 3
				@test _rx_get(fig.data[index], :line, :dash) == _rx_get(reference.data[index], :line, :dash)
				# The caller chose the mode: the `:dash_marker` cycle adds no markers.
				@test fig.data[index].fields[:mode] == "lines"
			end
			@test _rx_get(fig.data[1], :line, :dash) != _rx_get(fig.data[2], :line, :dash)
			@test _rx_get(fig.data[1], :marker, :size) == 9
			# An explicit marker size wins over the style.
			@test _rx_get(fig.data[2], :marker, :size) == 4
		end
		plain = _rx_trace(plot_ternary([0.5], [0.3], [0.2]))
		@test !_rx_has(plain, :line)
		@test !_rx_has(plain, :marker)
	end

	@testset "Cartesian extended mutators and annotate! draw into an inset (X20)" begin
		sf = subplots(1, 1; sync = false)
		plot_scatter!(sf, 1:10, 1:10)
		k = inset!(sf, (0.55, 0.55, 0.4, 0.4))
		inset_target = PlotlySupply._cell_target(sf; inset = k)
		@test plot_funnel!(sf, [3, 2, 1], ["a", "b", "c"]; inset = k) === sf
		@test plot_waterfall!(sf, ["a", "b"], [1, 2]; inset = k) === sf
		@test plot_candlestick!(sf, 1:2, [1, 2], [2, 3], [0.5, 1.5], [1.5, 2.5]; inset = k) === sf
		@test plot_ohlc!(sf, 1:2, [1, 2], [2, 3], [0.5, 1.5], [1.5, 2.5]; inset = k) === sf
		@test annotate!(sf, 1, 1, "in"; inset = k) === sf
		@test length(sf.fig.data) == 5
		for trace in sf.fig.data[2:end]
			@test (trace.fields[:xaxis], trace.fields[:yaxis]) == (inset_target.xref, inset_target.yref)
		end
		@test (inset_target.xref, inset_target.yref) == ("x2", "y2")
		note = only(_rx_layout(sf.fig)[:annotations])
		@test (note[:xref], note[:yref]) == ("x2", "y2")
		@test _rx_atomic(sf.fig, () -> plot_funnel!(sf, [1], ["a"]; inset = 9), "plot_funnel!: unknown inset id 9")
		@test _rx_atomic(sf.fig, () -> plot_waterfall!(sf, ["a"], [1]; inset = k, secondary_y = true), "plot_waterfall!: an inset has no secondary y-axis")
		@test _rx_atomic(sf.fig, () -> plot_ohlc!(sf, 1:1, [1], [2], [0.5], [1.5]; inset = k, row = 2, col = 1), "plot_ohlc!: `row` must be in 1:1")
		@test _rx_atomic(sf.fig, () -> plot_candlestick!(sf, 1:1, [1], [2], [0.5], [1.5]; inset = true), "plot_candlestick!: `inset` must be an integer")

		# The logarithmic-axis checks read the inset's axes, not the host
		# cell's: a log host does not block a linear inset ...
		host_log = subplots(1, 1; sync = false)
		plot_scatter!(host_log, 1:3, [1, 10, 100]; yscale = "log", xscale = "log")
		linear_inset = inset!(host_log, (0.1, 0.5, 0.4, 0.4))
		@test plot_waterfall!(host_log, ["a", "b"], [1, -2]; inset = linear_inset) === host_log
		@test plot_funnel!(host_log, [2, 1], ["a", "b"]; inset = linear_inset) === host_log
		@test plot_candlestick!(host_log, 1:2, [-1, 2], [2, 3], [-1.5, 1.5], [1.5, 2.5]; inset = linear_inset) === host_log
		@test _rx_throws(() -> plot_waterfall!(host_log, ["a"], [1]), "plot_waterfall!: the y axis of this cell is logarithmic")
		# ... and a log inset is checked even on a linear host.
		host_linear = subplots(1, 1; sync = false)
		plot_scatter!(host_linear, 1:3, 1:3)
		log_inset = inset!(host_linear, (0.1, 0.5, 0.4, 0.4))
		plot_scatter!(host_linear, 1:3, [1, 10, 100]; inset = log_inset, yscale = "log", xscale = "log")
		for (call, needle) in (
			(() -> plot_waterfall!(host_linear, ["a"], [1]; inset = log_inset), "plot_waterfall!: the y axis of this inset is logarithmic"),
			(() -> plot_funnel!(host_linear, [1], ["a"]; inset = log_inset), "plot_funnel!: the x axis of this inset is logarithmic"),
			(() -> plot_candlestick!(host_linear, 1:2, [1, -2], [2, 3], [0.5, 1.5], [1.5, 2.5]; inset = log_inset), "plot_candlestick!: `open[2]` is on a logarithmic axis"),
			(() -> plot_ohlc!(host_linear, [0, 1], [1, 2], [2, 3], [0.5, 1.5], [1.5, 2.5]; inset = log_inset), "plot_ohlc!: `x[1]` is on a logarithmic axis"),
		)
			@test _rx_atomic(host_linear.fig, call, needle)
		end
		@test plot_waterfall!(host_linear, ["a"], [1]) === host_linear
	end
end
