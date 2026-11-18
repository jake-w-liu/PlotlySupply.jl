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

	@testset "SubplotFigure log-axis checks run on the delegate's seeded axes (Y4)" begin
		# The SubplotFigure methods no longer pre-check the cell: the Plot
		# methods see the target axes (here the secondary y) through the
		# delegate's seeding, and the message names no target kind.
		function log_twin()
			twin = subplots(1, 1; sync = false, specs = Union{Missing, Spec}[Spec(secondary_y = true);;])
			plot_scatter!(twin, 1:3, [1, 2, 3])
			plot_scatter!(twin, 1:3, [1, 10, 100]; secondary_y = true, yscale = "log")
			return twin
		end
		twin = log_twin()
		@test _rx_atomic(twin.fig, () -> plot_waterfall!(twin, ["a"], [1]; secondary_y = true),
			"plot_waterfall!: the waterfall (y) axis is logarithmic, but waterfall (y) bars start at zero")
		@test _rx_atomic(twin.fig, () -> plot_candlestick!(twin, 1:2, [1, -2], [2, 3], [0.5, 1.5], [1.5, 2.5]; secondary_y = true),
			"plot_candlestick!: `open[2]` is on a logarithmic axis")
		@test _rx_atomic(twin.fig, () -> plot_ohlc!(twin, 1:2, [1, 2], [2, 3], [-0.5, 1.5], [1.5, 2.5]; secondary_y = true),
			"plot_ohlc!: `low[1]` is on a logarithmic axis")
		@test plot_waterfall!(twin, ["a"], [1]) === twin
		@test last(twin.fig.data).fields[:yaxis] == "y"
		@test plot_candlestick!(log_twin(), 1:2, [1, 2], [2, 3], [0.5, 1.5], [1.5, 2.5]; secondary_y = true) isa SubplotFigure
		# An explicit linear scale wins over the cell's log axis.
		log_cell = subplots(1, 1; sync = false)
		plot_scatter!(log_cell, 1:3, [1, 10, 100]; yscale = "log")
		@test plot_ohlc!(log_cell, 1:2, [1, 2], [2, 3], [0, 1], [1, 2]; yscale = "linear") === log_cell
		@test _rx_get(log_cell.fig.layout, :yaxis, :type) == "linear"
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
			# Z88: an unknown keyword is an ArgumentError naming the mutator.
			@test _rx_atomic(fig, () -> mutator(fig, args...; no_such_option = 1),
				"$(nameof(mutator)): unsupported keyword argument(s) `no_such_option`")
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

	@testset "coords = :figure is the whole figure, :paper the plot area (G39, G73)" begin
		# Rendered position of a paper-referenced annotation, in px from the
		# figure's left/bottom edge, for figure size W x H and margins m.
		px(a, W, H, m) = (
			m.l + a[:x] * (W - m.l - m.r) + get(a, :xshift, 0),
			m.b + a[:y] * (H - m.t - m.b) + get(a, :yshift, 0),
		)
		margins(target) = (l = _rx_get(_rx_layout(target)[:margin], :l), r = _rx_get(_rx_layout(target)[:margin], :r),
			t = _rx_get(_rx_layout(target)[:margin], :t), b = _rx_get(_rx_layout(target)[:margin], :b))
		fig = plot_scatter(1:3, 1:3; width = 600, height = 400)
		relayout!(fig; margin = attr(l = 60, r = 40, t = 50, b = 70))

		# :paper keeps plotly's meaning (any finite value, no shift).
		annotate!(fig, 0.5, -0.2, "below the axes"; coords = :paper, showarrow = false)
		paper = last(_rx_layout(fig)[:annotations])
		@test (paper[:xref], paper[:yref], paper[:x], paper[:y]) == ("paper", "paper", 0.5, -0.2)
		@test !_rx_has(paper, :xshift) && !_rx_has(paper, :yshift) && !_rx_has(paper, :name)

		# :figure: (0.25, 0.75) of the canvas, at every figure size.
		annotate!(fig, 0.25, 0.75, "inside"; coords = "figure", showarrow = false)
		inside = last(_rx_layout(fig)[:annotations])
		@test (inside[:xref], inside[:yref], inside[:x], inside[:y]) == ("paper", "paper", 0.25, 0.75)
		@test inside[:xshift] ≈ 0.25 * (60 + 40) - 60
		@test inside[:yshift] ≈ 0.75 * (50 + 70) - 70
		@test inside[:name] == "plotlysupply:figure:0.25:0.75:0.0:0.0"
		@test margins(fig) == (l = 60, r = 40, t = 50, b = 70)   # text over the plot: no reservation
		for (W, H) in ((600, 400), (1000, 700), (300, 900))
			@test all(px(inside, W, H, margins(fig)) .≈ (0.25 * W, 0.75 * H))
		end

		# A caption at the bottom edge raises the bottom margin above the tick
		# labels; the earlier figure annotation is re-placed for the new margin.
		annotate!(fig, 0.5, 0.0, "Caption line one<br>line two"; coords = :figure, showarrow = false)
		caption = last(_rx_layout(fig)[:annotations])
		m = margins(fig)
		@test m.b > 70 && (m.l, m.r, m.t) == (60, 40, 50)
		@test m.b >= 2 * 1.4 * 12 + 4 + 1.4 * 12   # two text lines, the gap, the x tick labels
		@test caption[:yshift] ≈ -m.b
		for (W, H) in ((600, 400), (1000, 700))
			@test all(px(caption, W, H, m) .≈ (0.5 * W, 0.0))
			@test all(px(_rx_layout(fig)[:annotations][2], W, H, m) .≈ (0.25 * W, 0.75 * H))
		end
		# A second caption above the first needs more room; both stay put.
		annotate!(fig, 0.5, 0.12, "Higher caption"; coords = :figure, showarrow = false, yanchor = "bottom")
		m2 = margins(fig)
		@test m2.b > m.b
		@test all(px(_rx_layout(fig)[:annotations][3], 600, 400, m2) .≈ (300, 0.0))
		@test all(px(last(_rx_layout(fig)[:annotations]), 600, 400, m2) .≈ (300, 0.12 * 400))

		# `offset` adds to the figure shift; an explicit `xref` keeps that
		# coordinate in plotly units.
		annotate!(fig, 0.5, 0.5, "offset"; coords = :figure, showarrow = false, offset = (10, -5))
		offset = last(_rx_layout(fig)[:annotations])
		@test all(px(offset, 600, 400, margins(fig)) .≈ (310, 195))
		annotate!(fig, 2, 0.9, "data x"; coords = :figure, xref = "x", showarrow = false)
		mixed = last(_rx_layout(fig)[:annotations])
		@test (mixed[:xref], mixed[:x], mixed[:yref], mixed[:y]) == ("x", 2, "paper", 0.9)
		@test !_rx_has(mixed, :xshift) && mixed[:name] == "plotlysupply:figure:-:0.9:0.0:0.0"
		# With an arrow the offset moves the text; the head is at the figure point.
		annotate!(fig, 0.9, 0.9, "arrow"; coords = :figure, offset = (-20, -20))
		arrow = last(_rx_layout(fig)[:annotations])
		@test (arrow[:ax], arrow[:ay]) == (-20, 20)
		@test all(px(arrow, 600, 400, margins(fig)) .≈ (540, 360))

		count = length(_rx_layout(fig)[:annotations])
		for (call, needle) in (
			(() -> annotate!(fig, 0.5, -0.1, "x"; coords = :figure), "annotate!: `y` = -0.1 is outside the figure"),
			(() -> annotate!(fig, 1.5, 0.1, "x"; coords = :figure), "use `coords = :paper`"),
			(() -> annotate!(fig, 0.5, 0.1, "x"; coords = :figure, name = "n"), "`name` cannot be set with `coords = :figure`"),
			(() -> annotate!(fig, 0.5, 0.1, "x"; coords = :figure, showarrow = false, yshift = 3), "`yshift` cannot be combined"),
			(() -> annotate!(fig, 0.5, 0.1, "x"; coords = :canvas), "`coords` must be :data, :axes, :paper or :figure"),
		)
			@test _rx_atomic(fig, call, needle)
		end
		@test length(_rx_layout(fig)[:annotations]) == count

		# SubplotFigure: figure fractions ignore the cell.
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, 1:3, 1:3; row = 1, col = 1, xlabel = "time")
		plot_scatter!(sf, 1:3, 1:3; row = 1, col = 2, xlabel = "time")
		@test annotate!(sf, 0.5, 0.01, "Two-line caption<br>below both panels"; coords = :figure,
			showarrow = false, yanchor = "bottom") === sf
		note = only(_rx_layout(sf.fig)[:annotations])
		sm = margins(sf.fig)
		@test (note[:xref], note[:yref]) == ("paper", "paper")
		for (W, H) in ((700, 500), (900, 650))
			@test all(px(note, W, H, sm) .≈ (W / 2, 0.01 * H))
		end
		@test sm.b >= 0.01 * 500 + 2 * 1.4 * 12 + 4
	end

	@testset "coords = :axes anchors by the position in the cell on every cell kind (G70)" begin
		sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec()])
		plot_surface!(sf, rand(3, 3); row = 1, col = 1)
		plot_scatter!(sf, 1:3, 1:3; row = 1, col = 2)
		for (x, y, xanchor, yanchor) in ((0.05, 0.95, "left", "top"), (0.5, 0.5, "center", "middle"), (0.9, 0.1, "right", "bottom"))
			annotate!(sf, x, y, "3-D"; row = 1, col = 1, coords = :axes, showarrow = false)
			scene = last(_rx_layout(sf.fig)[:annotations])
			@test (scene[:xref], scene[:xanchor], scene[:yanchor]) == ("paper", xanchor, yanchor)
			domain = PlotlySupply._cell_target(sf; row = 1, col = 1).xdomain
			@test scene[:x] ≈ domain[1] + x * (domain[2] - domain[1])
			# plotly's own rule on a 2-D cell's domain reference gives the same
			# anchors, so nothing is written there.
			annotate!(sf, x, y, "2-D"; row = 1, col = 2, coords = :axes, showarrow = false)
			flat = last(_rx_layout(sf.fig)[:annotations])
			@test flat[:xref] == "x domain" && !_rx_has(flat, :xanchor) && !_rx_has(flat, :yanchor)
			@test PlotlySupply._annotation_auto_xanchor(x) == xanchor
			@test PlotlySupply._annotation_auto_yanchor(y) == yanchor
		end
		# An explicit anchor wins; with an arrow plotly centres the text itself.
		annotate!(sf, 0.05, 0.95, "kept"; row = 1, col = 1, coords = :axes, showarrow = false, xanchor = "center")
		kept = last(_rx_layout(sf.fig)[:annotations])
		@test (kept[:xanchor], kept[:yanchor]) == ("center", "top")
		annotate!(sf, 0.05, 0.95, "arrow"; row = 1, col = 1, coords = :axes)
		@test !_rx_has(last(_rx_layout(sf.fig)[:annotations]), :xanchor)
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
		annotate!(fig, 0.5, 1.02, "caption"; coords = :paper, showarrow = false)
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
			@test _rx_atomic(target, () -> mut(target, data...; no_such_option = 1),
				"$(who)!: unsupported keyword argument(s) `no_such_option`")

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
			@test _rx_atomic(sf.fig, () -> mut(sf, data...; no_such_option = 1),
				"$(who)!: unsupported keyword argument(s) `no_such_option`")
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
		@test _rx_throws(() -> plot_waterfall!(host_log, ["a"], [1]), "plot_waterfall!: the waterfall (y) axis is logarithmic")
		# ... and a log inset is checked even on a linear host.
		host_linear = subplots(1, 1; sync = false)
		plot_scatter!(host_linear, 1:3, 1:3)
		log_inset = inset!(host_linear, (0.1, 0.5, 0.4, 0.4))
		plot_scatter!(host_linear, 1:3, [1, 10, 100]; inset = log_inset, yscale = "log", xscale = "log")
		for (call, needle) in (
			(() -> plot_waterfall!(host_linear, ["a"], [1]; inset = log_inset), "plot_waterfall!: the waterfall (y) axis is logarithmic"),
			(() -> plot_funnel!(host_linear, [1], ["a"]; inset = log_inset), "plot_funnel!: the funnel (x) axis is logarithmic"),
			(() -> plot_candlestick!(host_linear, 1:2, [1, -2], [2, 3], [0.5, 1.5], [1.5, 2.5]; inset = log_inset), "plot_candlestick!: `open[2]` is on a logarithmic axis"),
			(() -> plot_ohlc!(host_linear, [0, 1], [1, 2], [2, 3], [0.5, 1.5], [1.5, 2.5]; inset = log_inset), "plot_ohlc!: `x[1]` is on a logarithmic axis"),
		)
			@test _rx_atomic(host_linear.fig, call, needle)
		end
		@test plot_waterfall!(host_linear, ["a"], [1]) === host_linear
	end
end

# Wave 5: tick keywords of the Cartesian extended charts, unknown keywords,
# annotate!'s per-coordinate systems, colours and text boxes, and the
# figure-annotation placement hook.
_rx_ann(fig) = [PlotlySupply._symbol_dict(a) for a in _rx_layout(fig)[:annotations]]
_rx_last(fig) = last(_rx_ann(fig))
_rx_font(a) = PlotlySupply._symbol_dict(a[:font])

@testset "regression: extended charts and annotate!, wave 5" begin
	@testset "tick keywords on funnel, waterfall, candlestick and ohlc (Z31 item 2)" begin
		f = plot_funnel([3.0, 2.0, 1.0], ["a", "b", "c"]; xticks = [0, 1, 2], xticklabels = ["0", "one", "two"],
			xtickformat = ".1f")
		x = _rx_get(_rx_layout(f), :xaxis)
		@test (x[:tickmode], x[:tickvals], x[:ticktext], x[:tickformat]) == ("array", [0, 1, 2], ["0", "one", "two"], ".1f")
		# The mutator writes them, on the category stage axis too, and checks
		# them before the trace is added.
		@test plot_funnel!(f, [1.0], ["d"]; yticks = ["a", "d"], ytickformat = "") === nothing
		@test _rx_get(_rx_layout(f), :yaxis, :tickvals) == ["a", "d"]
		@test length(f.data) == 2
		@test _rx_atomic(f, () -> plot_funnel!(f, [1.0], ["e"]; xticklabels = ["x"]),
			"plot_funnel!: `xticklabels` needs `xticks`")

		w = plot_waterfall(["a", "b"], [1.0, 2.0]; yticks = [0, 1.5, 3], ytickformat = ".1f")
		@test _rx_get(_rx_layout(w), :yaxis, :tickvals) == [0, 1.5, 3]
		@test _rx_get(_rx_layout(w), :yaxis, :tickformat) == ".1f"
		plot_waterfall!(w, ["a", "b"], [1.0, 2.0]; yticks = [0, 2, 4], yticklabels = ["0", "\$2\$", "4"])
		@test _rx_get(_rx_layout(w), :yaxis, :ticktext) == ["0", "\$2\$", "4"]

		day(d) = PlotlySupply.Dates.Date(2024, 1, d)
		c = plot_candlestick([day(1), day(2)], [1, 2], [2, 3], [0.5, 1.5], [1.8, 2.2]; xticks = [day(1), day(2)],
			xtickformat = "%b %d")
		@test _rx_get(_rx_layout(c), :xaxis, :tickvals) == ["2024-01-01", "2024-01-02"]
		@test _rx_get(_rx_layout(c), :xaxis, :tickformat) == "%b %d"
		@test _rx_atomic(c, () -> plot_candlestick!(c, [day(3)], [1], [2], [0.5], [1.8]; yticks = [1, 2], yticklabels = ["a"]),
			"plot_candlestick!: got 1 tick labels for 2 tick values")

		o = plot_ohlc(1:3, [1, 2, 3], [2, 3, 4], [0.5, 1.5, 2.5], [1.8, 2.2, 3.3]; yscale = "log", yticks = :decades)
		@test (_rx_get(_rx_layout(o), :yaxis, :tickmode), _rx_get(_rx_layout(o), :yaxis, :dtick)) == ("linear", 1)
		@test _rx_throws(() -> plot_ohlc(1:3, [1, 2, 3], [2, 3, 4], [0.5, 1.5, 2.5], [1.8, 2.2, 3.3]; yticks = :decades),
			"plot_ohlc: the `:decades` tick preset")
		plot_ohlc!(o, 4:4, [3], [4], [2.5], [3.5]; xticks = [1, 4], xticklabels = ["start", "end"])
		@test _rx_get(_rx_layout(o), :xaxis, :ticktext) == ["start", "end"]

		# SubplotFigure: the ticks go to the cell's axes.
		sf = subplots(1, 2; sync = false)
		plot_waterfall!(sf, ["a"], [1]; row = 1, col = 2, yticks = [0, 1], yticklabels = ["zero", "one"])
		cell = PlotlySupply._cell_target(sf; row = 1, col = 2)
		@test _rx_get(_rx_layout(sf.fig), cell.ykey, :ticktext) == ["zero", "one"]
		@test !_rx_has(_rx_get(_rx_layout(sf.fig), :yaxis), :ticktext)
		@test _rx_atomic(sf.fig, () -> plot_candlestick!(sf, 1:2, [1, 2], [2, 3], [0.5, 1.5], [1.8, 2.2]; row = 1, col = 1,
			yticklabels = ["x"]), "plot_candlestick!: `yticklabels` needs `yticks`")
	end

	@testset "unknown keywords name the mutator, Plot and SubplotFigure (Z88)" begin
		fig = plot_candlestick(1:2, [1, 2], [2, 3], [0.5, 1.5], [1.8, 2.2])
		@test _rx_atomic(fig, () -> plot_ohlc!(fig, 1:1, [1], [2], [0.5], [1.5]; colour = "red", widht = 2),
			"plot_ohlc!: unsupported keyword argument(s) `colour`, `widht`")
		sf = subplots(1, 1; sync = false, specs = reshape([Spec(kind = "domain")], 1, 1))
		@test _rx_atomic(sf.fig, () -> plot_pie!(sf, [1.0, 2.0]; labelz = ["a", "b"]),
			"plot_pie!: unsupported keyword argument(s) `labelz`")
	end

	@testset "per-coordinate systems: xcoords, ycoords (Z57)" begin
		fig = plot_scatter(1:10, 1:10)
		annotate!(fig, 3.5, 1.02, "peak"; ycoords = :axes, showarrow = false)
		a = _rx_last(fig)
		@test (a[:xref], a[:x], a[:yref], a[:y]) == ("x", 3.5, "y domain", 1.02)
		annotate!(fig, 0.02, 5, "edge"; xcoords = :paper, showarrow = false)
		a = _rx_last(fig)
		@test (a[:xref], a[:x], a[:yref], a[:y]) == ("paper", 0.02, "y", 5)
		# A figure fraction for x only: x is re-placed for the margins, y stays data.
		annotate!(fig, 0.5, 5, "middle of the figure"; xcoords = :figure, showarrow = false)
		a = _rx_last(fig)
		@test (a[:xref], a[:yref], a[:y]) == ("paper", "y", 5)
		@test a[:name] == "plotlysupply:figure:0.5:-:0.0:0.0"
		@test _rx_has(a, :xshift) && !_rx_has(a, :yshift)
		# coords sets the default of both.
		annotate!(fig, 0.5, 7, "axes x"; coords = :axes, ycoords = :data, showarrow = false)
		a = _rx_last(fig)
		@test (a[:xref], a[:yref], a[:y]) == ("x domain", "y", 7)
		# A data coordinate on a logarithmic axis is converted per coordinate.
		logfig = plot_scatter(1:3, [1, 10, 100]; yscale = "log")
		annotate!(logfig, 0.5, 100, "log y"; xcoords = :axes)
		a = _rx_last(logfig)
		@test (a[:xref], a[:x], a[:yref], a[:y]) == ("x domain", 0.5, "y", 2.0)
		n = length(_rx_ann(fig))
		@test _rx_atomic(fig, () -> annotate!(fig, 1, 1, "x"; xcoords = :pixels), "annotate!: `xcoords` must be :data, :axes, :paper or :figure")
		@test _rx_atomic(fig, () -> annotate!(fig, 1, 1.5, "x"; ycoords = :figure), "annotate!: `y` = 1.5 is outside the figure")
		@test length(_rx_ann(fig)) == n
		# A pie cell: an x in cell fractions is anchored by its place in the cell.
		pies = subplots(1, 2; sync = false, specs = [Spec(kind = "domain") Spec(kind = "domain")])
		plot_pie!(pies, [1, 2]; row = 1, col = 2)
		annotate!(pies, 1.0, 0.5, "right"; row = 1, col = 2, xcoords = :axes, ycoords = :paper, showarrow = false)
		a = _rx_last(pies.fig)
		@test a[:xanchor] == "right" && !_rx_has(a, :yanchor)
	end

	@testset "colours go through _color_option (Z63)" begin
		fig = plot_scatter(1:3, 1:3)
		annotate!(fig, 1, 1, "c"; color = "0.35", arrowcolor = :red, bgcolor = PlotlySupply.Colors.RGB(0, 0, 1))
		a = _rx_last(fig)
		@test (_rx_font(a)[:color], a[:arrowcolor], a[:bgcolor]) == ("#595959", "red", "#0000FF")
		annotate!(fig, 1, 1, "f"; showarrow = false, font = attr(color = "0.5"), bordercolor = "0",
			hoverlabel = attr(bgcolor = "1"))
		a = _rx_last(fig)
		@test _rx_font(a)[:color] == "#808080"
		@test a[:bordercolor] == "#000000"
		@test PlotlySupply._symbol_dict(a[:hoverlabel])[:bgcolor] == "#FFFFFF"
		annotate!(fig, 1, 1, "g"; color = :teal, edgecolor = "0.2", background = PlotlySupply.Colors.RGBA(1, 0, 0, 0.5))
		a = _rx_last(fig)
		@test (_rx_font(a)[:color], a[:bordercolor], a[:bgcolor]) == ("teal", "#333333", "rgba(255,0,0,0.5)")
		n = length(_rx_ann(fig))
		for (call, needle) in (
			(() -> annotate!(fig, 1, 1, "x"; color = 0.5), "annotate!: `color` must be a colour"),
			(() -> annotate!(fig, 1, 1, "x"; arrowcolor = "not-a-colour"), "annotate!: `arrowcolor`: invalid colour"),
			(() -> annotate!(fig, 1, 1, "x"; font_color = "1.5"), "annotate!: `font_color`"),
			(() -> annotate!(fig, 1, 1, "x"; background = "nope"), "annotate!: `background`"),
		)
			@test _rx_atomic(fig, call, needle)
		end
		@test length(_rx_ann(fig)) == n
	end

	@testset "anchor, units, background box, rotation, leader arrows (W8)" begin
		fig = plot_scatter([0.0, 10.0], [0.0, 5.0]; mode = "markers")
		annotate!(fig, 2, 2, "a<br>b"; showarrow = false, anchor = :topleft, offset = (3, -3), units = :pt)
		a = _rx_last(fig)
		@test (a[:xanchor], a[:yanchor], a[:align]) == ("left", "top", "left")
		@test (a[:xshift], a[:yshift]) == (4.0, -4.0)
		annotate!(fig, 2, 2, "b"; showarrow = false, anchor = "upper right", align = :center, fontsize = 9, units = :pt)
		a = _rx_last(fig)
		@test (a[:xanchor], a[:yanchor], a[:align], _rx_font(a)[:size]) == ("right", "top", "center", 12.0)
		for (name, expected) in ((:bottom, ("center", "bottom")), ("center left", ("left", "middle")),
				(:lower_right, ("right", "bottom")), ("centre", ("center", "middle")))
			annotate!(fig, 1, 1, "c"; showarrow = false, anchor = name)
			@test (_rx_last(fig)[:xanchor], _rx_last(fig)[:yanchor]) == expected
		end
		# A box: background (translucent), edge, matplotlib's 0.3 em padding.
		annotate!(fig, 5, 2.5, "box"; showarrow = false, background = "white", background_opacity = 0.5, edgecolor = "black",
			edgewidth = 1.5)
		a = _rx_last(fig)
		@test (a[:bgcolor], a[:bordercolor], a[:borderwidth], a[:borderpad]) == ("rgba(255,255,255,0.5)", "black", 1.5, 3.6)
		annotate!(fig, 5, 2.5, "pad"; showarrow = false, background = "white", pad = 3, units = :pt, fontsize = 10)
		a = _rx_last(fig)
		@test (a[:bgcolor], a[:borderpad]) == ("white", 4.0)
		# A raw bgcolor keeps plotly's padding (1.x output unchanged).
		annotate!(fig, 5, 2.5, "raw"; showarrow = false, bgcolor = "white")
		@test !_rx_has(_rx_last(fig), :borderpad)
		# rotation is counter-clockwise; plotly's textangle clockwise.
		annotate!(fig, 1, 4, "r"; showarrow = false, rotation = 30)
		@test _rx_last(fig)[:textangle] == -30.0
		annotate!(fig, 1, 4, "r0"; showarrow = false, rotation = 0)
		@test !_rx_has(_rx_last(fig), :textangle)
		# Leader line / arrow from the text at xytext to (x, y).
		annotate!(fig, 7, 1, "leader"; xytext = (6, 2), head = :none)
		a = _rx_last(fig)
		@test (a[:axref], a[:ax], a[:ayref], a[:ay], a[:arrowhead], a[:showarrow]) == ("x", 6, "y", 2, 0, true)
		annotate!(fig, 0.5, 0.5, "axes"; coords = :axes, xytext = (0.2, 0.8))
		a = _rx_last(fig)
		@test (a[:axref], a[:ax], a[:ayref], a[:ay]) == ("x domain", 0.2, "y domain", 0.8)
		@test !_rx_has(a, :arrowhead)
		logfig = plot_scatter(1:3, [1, 10, 100]; yscale = "log")
		annotate!(logfig, 2, 10, "log tail"; xytext = (1, 1000))
		@test (_rx_last(logfig)[:ay], _rx_last(logfig)[:y]) == (3.0, 1.0)

		n = length(_rx_ann(fig))
		for (call, needle) in (
			(() -> annotate!(fig, 1, 1, "x"; anchor = :middleish), "annotate!: `anchor` must be :center"),
			(() -> annotate!(fig, 1, 1, "x"; anchor = 3), "annotate!: `anchor` must be a Symbol or string"),
			(() -> annotate!(fig, 1, 1, "x"; anchor = :left, xanchor = "left"), "`anchor` and `xanchor` set the same thing"),
			(() -> annotate!(fig, 1, 1, "x"; rotation = 10, textangle = 3), "`rotation` and `textangle`"),
			(() -> annotate!(fig, 1, 1, "x"; background = "white", bgcolor = "red"), "`background` and `bgcolor`"),
			(() -> annotate!(fig, 1, 1, "x"; edgecolor = "red", bordercolor = "red"), "`edgecolor` and `bordercolor`"),
			(() -> annotate!(fig, 1, 1, "x"; edgewidth = 1, borderwidth = 1), "`edgewidth` and `borderwidth`"),
			(() -> annotate!(fig, 1, 1, "x"; pad = 1, borderpad = 1), "`pad` and `borderpad`"),
			(() -> annotate!(fig, 1, 1, "x"; head = :none, arrowhead = 2), "`head` and `arrowhead`"),
			(() -> annotate!(fig, 1, 1, "x"; head = :both), "annotate!: `head` must be :end"),
			(() -> annotate!(fig, 1, 1, "x"; head = :none, showarrow = false), "`head = :none` needs an arrow"),
			(() -> annotate!(fig, 1, 1, "x"; units = :cm), "annotate!: `units` must be :px or :pt"),
			(() -> annotate!(fig, 1, 1, "x"; background_opacity = 0.3), "`background_opacity` needs `background`"),
			(() -> annotate!(fig, 1, 1, "x"; background = "white", background_opacity = 2), "`background_opacity` must be a number in [0, 1]"),
			(() -> annotate!(fig, 1, 1, "x"; pad = -1), "annotate!: `pad` must be a non-negative"),
			(() -> annotate!(fig, 1, 1, "x"; rotation = NaN), "annotate!: `rotation` must be a finite number"),
			(() -> annotate!(fig, 1, 1, "x"; xytext = (1, 2), showarrow = false), "`xytext` places the text away"),
			(() -> annotate!(fig, 1, 1, "x"; xytext = (1, 2), offset = (3, 3)), "`xytext` and `offset`"),
			(() -> annotate!(fig, 1, 1, "x"; xytext = (1, 2), ax = 3), "`xytext` and `ax`"),
			(() -> annotate!(fig, 1, 1, "x"; xytext = (1, 2, 3)), "`xytext` must be a 2-element"),
			(() -> annotate!(fig, 0.1, 0.1, "x"; coords = :paper, xytext = (0.2, 0.2)), "`xytext` needs (x, y) on axes"),
			(() -> annotate!(fig, 1, 1, "x"; xytext = (Inf, 2)), "annotate!: `xytext` must be finite"),
		)
			@test _rx_atomic(fig, call, needle)
		end
		@test length(_rx_ann(fig)) == n
	end

	@testset "text fitted to a box: fit, wrap, refit by the finalizer (W8)" begin
		fig = plot_scatter([0.0, 10.0], [0.0, 5.0]; mode = "markers")
		xrange!(fig, (0, 10)); yrange!(fig, (0, 5))
		annotate!(fig, 5, 4, "box"; fit = (2, 0.5), fontsize = 30)
		a = _rx_last(fig)
		@test a[:showarrow] == false
		@test a[:name] == "plotlysupply:fit:2.0:0.5:30.0"
		# The font size is the largest that fits the box (and at most 30 px).
		Wp, Hp = PlotlySupply._annotation_plot_px(fig, PlotlySupply._fin_collect_axes(fig))
		box_w, box_h = 2 / 10 * Wp, 0.5 / 5 * Hp
		size = _rx_font(a)[:size]
		tw, th = PlotlySupply._text_extent(a[:text], size)
		@test size < 30
		@test tw + 4 <= box_w && th + 4 <= box_h      # padding 1 px + border 1 px on each side
		tw2, th2 = PlotlySupply._text_extent(a[:text], size + 0.2)
		@test tw2 + 4 > box_w || th2 + 4 > box_h       # 0.2 px more does not fit
		# Text that fits keeps its size: never grown past fontsize / the figure font.
		annotate!(fig, 5, 1, "x"; fit = (4, 2))
		@test _rx_font(_rx_last(fig))[:size] == 12.0
		# wrap: the line breaks giving the largest size, fewest lines on a tie.
		annotate!(fig, 5, 2.5, "the quick brown fox jumps over the lazy dog"; fit = (4, 1), wrap = true)
		a = _rx_last(fig)
		@test a[:text] == "the quick brown fox<br>jumps over the lazy dog"
		@test _rx_font(a)[:size] == 12.0
		annotate!(fig, 5, 2.5, "a b"; fit = (4, 1), wrap = true)
		@test _rx_last(fig)[:text] == "a b"
		# A rotated label in a tall box.
		annotate!(fig, 9, 2.5, "rotated label in a tall box"; fit = (1, 4), rotation = 90)
		a = _rx_last(fig)
		tw, th = PlotlySupply._text_extent(a[:text], _rx_font(a)[:size])
		@test th + 4 <= 1 / 10 * Wp && tw + 4 <= 4 / 5 * Hp
		@test _rx_font(a)[:size] > 6
		# The finalizer refits for the export size (smaller in a smaller
		# figure), and a second pass changes nothing.
		fitted(f) = [_rx_font(x)[:size] for x in _rx_ann(f) if startswith(string(get(x, :name, "")), "plotlysupply:fit:")]
		small = PlotlySupply._finalize_export_copy(fig, (width = 350, height = 250))
		@test all(fitted(small) .<= fitted(fig))
		@test fitted(small)[1] < fitted(fig)[1]
		@test PlotlySupply._finalize_figure!(fig) == false
		# A figure-size change refits the live figure as well.
		before = fitted(fig)
		relayout!(fig; width = 1400, height = 1000)
		PlotlySupply._finalize_figure!(fig)
		@test fitted(fig)[1] > before[1]
		@test PlotlySupply._finalize_figure!(fig) == false
		# wrap: the breaks are chosen again for the export size (a narrow,
		# tall export takes more lines at a larger size than the live breaks
		# would get), and kept when the text was replaced after annotate!.
		pangram = "the quick brown fox: jumps over the lazy dog"
		function wrapped_figure()
			f = plot_scatter([0.0, 10.0], [0.0, 5.0]; mode = "markers", width = 700, height = 500)
			xrange!(f, (0, 10)); yrange!(f, (0, 5))
			annotate!(f, 5, 2.5, pangram; fit = (4, 1), wrap = true)
			return f
		end
		function set_last!(f, key, value)
			items = collect(Any, f.layout.fields[:annotations])
			fields = PlotlySupply._symbol_dict(items[end])
			fields[key] = value
			items[end] = attr(; fields...)
			relayout!(f; annotations = items)
		end
		narrow_export(f) = _rx_last(PlotlySupply._finalize_export_copy(f, (width = 300, height = 900)))
		tall = wrapped_figure()
		live = _rx_last(tall)
		@test live[:name] == "plotlysupply:fit:4.0:1.0:0.0:wrap:c:$(pangram)"
		@test PlotlySupply._annotation_fit_spec(live).wrap == (align = :c, source = pangram)
		narrow = narrow_export(tall)
		lines(a) = count("<br>", a[:text]) + 1
		@test lines(narrow) > lines(live)
		@test narrow[:text] in [PlotlySupply._label(c) for c in PlotlySupply._annotation_wrap_candidates(pangram)]
		@test PlotlySupply._finalize_figure!(tall) == false
		# The same annotation without the wrap spec keeps the live breaks at a
		# smaller size in that export.
		kept = wrapped_figure()
		set_last!(kept, :name, "plotlysupply:fit:4.0:1.0:0.0")
		kept_export = narrow_export(kept)
		@test kept_export[:text] == live[:text]
		@test _rx_font(narrow)[:size] > _rx_font(kept_export)[:size]
		# A text replaced after annotate! is kept (and only resized).
		set_last!(tall, :text, "edited text")
		@test narrow_export(tall)[:text] == "edited text"
		# Malformed fit names are not fitted annotations.
		for name in ("plotlysupply:fit:1:1", "plotlysupply:fit:1:1:0:wrap", "plotlysupply:fit:1:1:0:wrap:x:text",
				"plotlysupply:fit:1:1:0:nowrap:c:text")
			@test PlotlySupply._annotation_fit_spec(attr(name = name)) === nothing
		end
		# Fractions of the axes; a pie cell scales the box to the cell.
		annotate!(fig, 0.5, 0.5, "axes box"; coords = :axes, fit = (0.2, 0.1))
		@test _rx_last(fig)[:name] == "plotlysupply:fit:0.2:0.1:0.0"
		pies = subplots(1, 2; sync = false, specs = [Spec(kind = "domain") Spec(kind = "domain")])
		plot_pie!(pies, [1, 2]; row = 1, col = 2)
		annotate!(pies, 0.5, 0.5, "pie"; row = 1, col = 2, coords = :axes, fit = (0.5, 0.2))
		cell = PlotlySupply._cell_target(pies; row = 1, col = 2)
		@test _rx_last(pies.fig)[:name] ==
			"plotlysupply:fit:$(0.5 * (cell.xdomain[2] - cell.xdomain[1])):$(0.2 * (cell.ydomain[2] - cell.ydomain[1])):0.0"
		# A figure without fitted annotations is not touched by the provider.
		plain = plot_scatter(1:3, 1:3)
		annotate!(plain, 1, 1, "plain")
		@test PlotlySupply._finalize_figure!(plain) == false

		cats = plot_scatter(["a", "b"], [1, 2])
		logfig = plot_scatter(1:3, [1, 10, 100]; yscale = "log")
		n = length(_rx_ann(fig))
		for (target, call, needle) in (
			(fig, () -> annotate!(fig, 1, 1, "x"; fit = (1, 1), showarrow = true), "`fit` sizes text in a box and cannot draw an arrow"),
			(fig, () -> annotate!(fig, 1, 1, "x"; fit = (0, 1)), "the box width and height must be positive"),
			(fig, () -> annotate!(fig, 1, 1, "x"; fit = (1, 2, 3)), "`fit` must be a 2-element"),
			(fig, () -> annotate!(fig, 1, 1, "x"; fit = (1, 1), name = "mine"), "`name` cannot be set with `fit`"),
			(fig, () -> annotate!(fig, 0.5, 0.5, "x"; coords = :figure, fit = (0.1, 0.1)), "cannot be combined with `coords = :figure`"),
			(fig, () -> annotate!(fig, 1, 1, "x"; wrap = true), "`wrap = true` breaks the text into lines"),
			(cats, () -> annotate!(cats, "a", 1, "x"; fit = (1, 1)), "`fit` needs a linear x axis"),
			(logfig, () -> annotate!(logfig, 2, 10, "x"; fit = (1, 1)), "`fit` needs a linear y axis"),
		)
			@test _rx_atomic(target, call, needle)
		end
		@test length(_rx_ann(fig)) == n
	end

	@testset "_figure_annotations_place! is pure and idempotent, with a size (Z47)" begin
		json = PlotlySupply.PlotlyBase.JSON.json
		fig = plot_scatter(1:3, 1:3; width = 600, height = 400)
		relayout!(fig; margin = attr(l = 60, r = 40, t = 50, b = 70))
		annotate!(fig, 0.25, 0.75, "inside"; coords = :figure, showarrow = false)
		annotate!(fig, 1, 1, "data")
		# The margins change after the annotation was placed.
		relayout!(fig; margin = attr(l = 100, r = 40, t = 50, b = 70))
		before = json(fig)
		items = collect(Any, _rx_layout(fig)[:annotations])
		originals = copy(items)
		@test PlotlySupply._figure_annotations_place!(fig, items) === nothing
		@test json(fig) == before                                  # the figure is not written
		@test items[2] === originals[2]                            # other annotations untouched
		@test items[1] !== originals[1]                            # replaced, not mutated
		@test PlotlySupply._symbol_dict(originals[1])[:xshift] ≈ 0.25 * (60 + 40) - 60
		@test PlotlySupply._symbol_dict(items[1])[:xshift] ≈ 0.25 * (100 + 40) - 100
		relayout!(fig; annotations = items)
		again = collect(Any, _rx_layout(fig)[:annotations])
		@test PlotlySupply._figure_annotations_place!(fig, again) === nothing
		@test all(i -> isequal(PlotlySupply._symbol_dict(again[i]), PlotlySupply._symbol_dict(items[i])), eachindex(items))

		# A tall caption: the bottom margin it needs is capped at half the
		# figure height of `size` (the export size on a savefig copy).
		caption = plot_scatter(1:3, 1:3; width = 600, height = 400)
		annotate!(caption, 0.5, 0.0, join(fill("caption line", 6), "<br>"); coords = :figure, showarrow = false)
		items = collect(Any, _rx_layout(caption)[:annotations])
		b_now = _rx_get(_rx_layout(caption), :margin, :b)
		@test PlotlySupply._figure_annotations_place!(caption, copy(items)) === nothing   # placed already
		relayout!(caption; margin_b = 20)
		@test PlotlySupply._figure_annotations_place!(caption, copy(items); size = (600, 160)) == 80.0   # H / 2 of `size`
		@test PlotlySupply._figure_annotations_place!(caption, copy(items); size = (600, 400)) == b_now
		@test PlotlySupply._figure_annotations_place!(caption, copy(items)) == b_now     # the layout size
		@test _rx_throws(() -> PlotlySupply._figure_annotations_place!(caption, items; size = (0, 10)),
			"_figure_annotations_place!: `size` must be (width, height) in px")
		@test _rx_throws(() -> PlotlySupply._figure_annotations_place!(caption, items; size = (600,)),
			"_figure_annotations_place!: `size`")
	end
end
