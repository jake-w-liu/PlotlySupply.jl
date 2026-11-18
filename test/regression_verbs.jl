using Test, PlotlySupply

# Regression tests for the SyncPlot renderer transactions behind relayout!,
# restyle!, update!, purge!, react! and extendtraces!/prependtraces!.

const _RV_PB = PlotlySupply.PlotlyBase

# Recording renderer. With `mimic_purge`, it behaves like plotly.js on a
# purged div: Plotly.relayout/update/redraw/restyle/extendTraces fail until a
# script runs Plotly.newPlot or Plotly.react on it.
mutable struct _RVRenderer
	scripts::Vector{String}
	mimic_purge::Bool
	purged::Bool
end

const _RV_PURGE_SENSITIVE_CALLS = (
	"Plotly.relayout(",
	"Plotly.update(",
	"Plotly.redraw(",
	"Plotly.restyle(",
	"Plotly.extendTraces(",
	"Plotly.prependTraces(",
)

function _rv_run!(renderer::_RVRenderer, script)
	text = String(script)
	push!(renderer.scripts, text)
	renderer.mimic_purge || return "ok"
	if occursin("Plotly.purge(div)", text)
		renderer.purged = !occursin("Plotly.newPlot(", text)
	elseif occursin("Plotly.newPlot(", text) || occursin("Plotly.react(", text)
		renderer.purged = false
	elseif renderer.purged &&
			any(call -> occursin(call, text), _RV_PURGE_SENSITIVE_CALLS)
		throw(ErrorException("plotly.js: the div is purged"))
	end
	return "ok"
end

function _rv_syncplot(
	p::Plot;
	spec::Union{Nothing,PlotlySupply._SyncPlotCreationSpec} = nothing,
	mimic_purge::Bool = false,
	register::Bool = false,
)
	renderer = _RVRenderer(String[], mimic_purge, false)
	backend = (
		isopen = window -> true,
		close = window -> nothing,
		run = (window, script) -> _rv_run!(renderer, script),
	)
	sp = SyncPlot(
		p,
		nothing,
		:rv_window,
		"rv-div",
		PlotlySupply._SyncPlotResources(nothing, backend, spec),
	)
	if register
		old, registered = PlotlySupply._register_displayed_syncplot!(p, sp)
		(old === nothing && registered) ||
			error("could not register the regression fixture")
	end
	return sp, renderer
end

_rv_calls(script::AbstractString) =
	[m.match for m in eachmatch(r"await Plotly\.[A-Za-z]+", script)]

@testset "verbs: scalar layout titles accept nested title setters" begin
	builders = (
		() -> plot_scatter(1:3, [4, 5, 6]; title = "T"),
		() -> plot_scatter(1:3, [4.0, 5, 6]),
		() -> plot_bar(["a", "b"], [1, 2]; title = "T"),
		() -> Plot(scatter(y = [1]), Layout(title = "T")),
	)
	for build in builders
		fig = build()
		# 2.0 builders store `title.text` and store nothing for an empty title
		# (D7 `_title_attr`); a user-built `Layout(title = "T")` still holds a
		# bare String. Nested title setters must work on all three.
		had_title = haskey(fig.layout.fields, :title)
		stored_title = get(fig.layout.fields, :title, "")
		original_text = stored_title isa AbstractString ?
			stored_title : stored_title[:text]
		@test original_text isa AbstractString
		@test relayout!(fig; title_x = 0.5, title_font_size = 20) === fig
		title = fig.layout.fields[:title]
		@test (had_title ? title[:text] : get(title, :text, "")) == original_text
		@test title[:x] == 0.5
		@test title[:font][:size] == 20
		@test relayout!(fig; title_text = "New") === fig
		@test fig.layout.fields[:title][:text] == "New"
		@test fig.layout.fields[:title][:x] == 0.5
	end

	fig = plot_scatter(1:3, [4, 5, 6])
	@test update!(fig; layout = Layout(title_text = "New")) === fig
	@test fig.layout.fields[:title][:text] == "New"

	p = Plot(scatter(y = [1, 2]), Layout(title = "T"))
	relayout!(p; title = attr(text = "A", x = 0.2))
	@test p.layout.fields[:title][:text] == "A"
	@test p.layout.fields[:title][:x] == 0.2
	# Assigning a plain string still stores the plain string.
	relayout!(p; title = "plain")
	@test p.layout.fields[:title] == "plain"

	p = Plot(scatter(y = [1]), Layout(xaxis = attr(title = "X")))
	relayout!(p; xaxis_title_font_size = 9)
	@test p.layout[:xaxis][:title][:text] == "X"
	@test p.layout[:xaxis][:title][:font][:size] == 9

	# A displayed figure applies the same model change and renders it. The
	# scalar (bare String) title is the one a user-built `Layout` holds; 2.0
	# builders store `title.text` (D7), for which the nested delta is sent.
	fig = Plot(scatter(x = 1:3, y = [4, 5, 6]), Layout(title = "T"))
	sp, renderer = _rv_syncplot(fig)
	try
		@test relayout!(sp; title_x = 0.5) === sp
		@test fig.layout.fields[:title][:text] == "T"
		@test fig.layout.fields[:title][:x] == 0.5
		script = only(renderer.scripts)
		@test _rv_calls(script) == ["await Plotly.relayout"]
		@test occursin("\"title\":{", script)
		@test occursin("\"x\":0.5", script)
		@test occursin("\"text\":\"T\"", script)
	finally
		close(sp)
	end
	built = plot_scatter(1:3, [4, 5, 6]; title = "T")
	sp, renderer = _rv_syncplot(built)
	try
		@test relayout!(sp; title_x = 0.5) === sp
		@test built.layout.fields[:title][:text] == "T"
		@test built.layout.fields[:title][:x] == 0.5
		script = only(renderer.scripts)
		@test _rv_calls(script) == ["await Plotly.relayout"]
		@test occursin("\"title.x\":0.5", script)
	finally
		close(sp)
	end
end

@testset "verbs: nothing removes the written attribute" begin
	p = Plot([scatter(x = [1, 2, 3], y = [4, 5, 6], line = attr(color = "red"))])
	sp, renderer = _rv_syncplot(p)
	try
		restyle!(sp, 1; line = nothing)
		@test !haskey(p.data[1].fields, :line)
		@test occursin("\"line\":[null]", last(renderer.scripts))
		extendtraces!(sp, Dict(:y => [[7]], :x => [[4]]), [1], -1)
		@test p.data[1][:x] == [1, 2, 3, 4]
		@test p.data[1][:y] == [4, 5, 6, 7]
		@test !occursin("null", _RV_PB.JSON.json(p.data))

		relayout!(sp; xaxis_range = [0, 1])
		relayout!(sp, Dict(:xaxis => nothing))
		@test !haskey(p.layout.fields, :xaxis)
		@test occursin("\"xaxis\":null", last(renderer.scripts))

		relayout!(sp; yaxis = attr(range = [1, 2]))
		relayout!(sp; yaxis_range = nothing)
		@test !haskey(p.layout[:yaxis], :range)
		@test occursin("\"yaxis.range\":null", last(renderer.scripts))
	finally
		close(sp)
	end

	# Unrendered figures drop the key the same way.
	p = Plot([scatter(y = [1, 2], marker = attr(color = "red", size = 4))])
	restyle!(p, 1; marker_color = nothing)
	@test p.data[1][:marker] == Dict{Any,Any}(:size => 4)
	update!(p, 1; name = "n", layout = Layout(title = nothing))
	@test !haskey(p.layout.fields, :title)
	@test p.data[1][:name] == "n"

	# Arbitrary-JSON attributes keep nested nothing values as data.
	p = Plot([scatter(y = [1, 2])], Layout(meta = Dict(:a => nothing)))
	relayout!(p; meta = Dict(:b => nothing, :c => 1))
	@test p.layout.fields[:meta] ==
		Dict{Any,Any}(:a => nothing, :b => nothing, :c => 1)
end

@testset "verbs: keyword arguments apply in PlotlyBase order" begin
	original = Plot([scatter(y = [1, 2], marker = attr(size = 1))])
	p = deepcopy(original)
	reference = deepcopy(original.data[1])
	restyle!(p, 1; marker = attr(size = 10), marker_size = 5)
	_RV_PB.restyle!(reference, 1; marker = attr(size = 10), marker_size = 5)
	@test p.data[1][:marker][:size] == 5
	@test p.data[1].fields == reference.fields

	p = deepcopy(original)
	update!(p, 1; marker_color = "red", marker = attr(color = "blue"))
	@test p.data[1][:marker][:color] == "blue"

	original = Plot([scatter(y = [1, 2])], Layout(xaxis = attr(range = [0, 1])))
	p = deepcopy(original)
	reference = deepcopy(original.layout)
	relayout!(
		p;
		xaxis_title_text = "A",
		xaxis = attr(title = attr(text = "B")),
	)
	_RV_PB.relayout!(
		reference;
		xaxis_title_text = "A",
		xaxis = attr(title = attr(text = "B")),
	)
	@test p.layout[:xaxis][:title][:text] == "B"
	@test p.layout.fields == reference.fields

	# Vectorized restyle! keeps PlotlyBase's Dict{Symbol,Any}(kwargs) order.
	original = Plot([
		scatter(y = [1], marker = attr(size = 1)),
		scatter(y = [2], marker = attr(size = 2)),
	])
	p = deepcopy(original)
	references = deepcopy(original.data)
	kwargs = (marker = attr(size = 10), marker_size = 5)
	restyle!(p, [1, 2]; kwargs...)
	ordered = Dict{Symbol,Any}(pairs(kwargs))
	for (position, trace) in enumerate(references)
		_RV_PB.restyle!(trace, position; ordered...)
	end
	@test [trace.fields for trace in p.data] ==
		[trace.fields for trace in references]

	# The displayed path commits the same order.
	p = deepcopy(Plot([scatter(y = [1, 2], marker = attr(size = 1))]))
	sp, renderer = _rv_syncplot(p)
	try
		restyle!(sp, 1; marker = attr(size = 10), marker_size = 5)
		@test p.data[1][:marker][:size] == 5
		@test occursin("\"marker.size\":[5]", only(renderer.scripts))
	finally
		close(sp)
	end
end

@testset "verbs: incremental scripts send one Plotly call per trace group" begin
	p = Plot([
		scatter(
			y = [1, 2, 3],
			marker = attr(color = "blue", size = 1),
			line = attr(width = 1, color = "black"),
		),
	])
	sp, renderer = _rv_syncplot(p)
	try
		restyle!(
			sp,
			1;
			marker_color = "red",
			marker_size = 3,
			line_width = 2,
			opacity = 0.8,
			line_color = "green",
			name = "n",
		)
		script = only(renderer.scripts)
		@test _rv_calls(script) == ["await Plotly.restyle"]
		for path in (
			"\"marker.color\"",
			"\"marker.size\"",
			"\"line.width\"",
			"\"opacity\"",
			"\"line.color\"",
			"\"name\"",
		)
			@test occursin(path, script)
		end

		empty!(renderer.scripts)
		update!(
			sp,
			1,
			Dict(:name => "u");
			layout = Layout(title_text = "L"),
			marker_size = 4,
		)
		script = only(renderer.scripts)
		@test _rv_calls(script) == ["await Plotly.update"]
		@test occursin("\"marker.size\":[4]", script)
		@test occursin("\"name\":[\"u\"]", script)
		@test occursin("\"title\":{\"text\":\"L\"}", script)
	finally
		close(sp)
	end

	group = PlotlySupply._group_trace_operations
	operation(path, indices, value) =
		(path = path, indices = indices, values = Any[value])
	@test length(group([
		operation("marker", [0], Dict("size" => 1)),
		operation("marker.size", [0], 3),
	])) == 2
	@test length(group([
		operation("marker.size", [0], 3),
		operation("marker.color", [1], "red"),
	])) == 2
	@test length(group([
		operation("marker.size", [0], 3),
		operation("marker.color", [0], "red"),
		operation("name", [0], "n"),
	])) == 1
end

@testset "verbs: purge! leaves a plot that later verbs can update" begin
	followups = (
		sp -> relayout!(sp; title = "x"),
		sp -> update!(sp; layout = Layout(title = "y")),
		sp -> redraw!(sp),
		sp -> addtraces!(sp, scatter(y = [3, 4])),
	)
	for followup in followups
		p = Plot([scatter(y = [1, 2, 3])], Layout(title = "t"))
		sp, renderer = _rv_syncplot(p; mimic_purge = true)
		try
			purge!(sp)
			script = last(renderer.scripts)
			@test occursin("Plotly.purge(div);", script)
			@test occursin("await Plotly.newPlot(div, []", script)
			@test !occursin("if (true) await Plotly.animate", script)
			@test isempty(sp.plot.data)
			@test !renderer.purged
			before = length(renderer.scripts)
			@test followup(sp) === sp
			# The follow-up ran on its first attempt, without a recovery
			# rebuild after a renderer failure.
			@test length(renderer.scripts) == before + 1
			@test !sp._resources.renderer_desynchronized
		finally
			close(sp)
		end
	end
	p = Plot([scatter(y = [1, 2, 3])], Layout(title = "t"))
	sp, renderer = _rv_syncplot(p; mimic_purge = true)
	try
		purge!(sp)
		relayout!(sp; title = "x")
		@test p.layout.fields[:title] == "x"
	finally
		close(sp)
	end
end

@testset "verbs: react! with a model honours the window autoplay" begin
	cases = (
		# Playback is started without awaiting it (the render lock must not be
		# held for the length of an animation), so only the flag is asserted.
		(false, "if (false) Plotly.animate"),
		(true, "if (true) Plotly.animate"),
		(nothing, "if (true) Plotly.animate"),
	)
	for (autoplay, expected) in cases
		spec = autoplay === nothing ? nothing :
			PlotlySupply._SyncPlotCreationSpec(600, 400, "t", false, autoplay, 5.0)
		sp, renderer = _rv_syncplot(Plot([scatter(y = [0, 0])]); spec = spec)
		try
			animated = Plot(
				[scatter(y = [1, 1])],
				Layout(),
				[_RV_PB.frame(name = "f1", data = [attr(y = [2, 2])])],
			)
			@test react!(sp, animated) === sp
			script = only(renderer.scripts)
			@test occursin("Plotly.addFrames", script)
			@test occursin(expected, script)
			@test sp.plot === animated
		finally
			close(sp)
		end
	end
end

@testset "verbs: alias reachability skips numeric leaf arrays" begin
	values = [rand(3) for _ in 1:10]
	seen = IdDict{Any,Nothing}()
	@test !PlotlySupply._graph_reaches_staged_node(
		values,
		IdDict{Any,Any}(),
		seen,
	)
	@test length(seen) == 1
	memo = IdDict{Any,Any}(values[3] => copy(values[3]))
	@test PlotlySupply._graph_reaches_staged_node(
		values,
		memo,
		IdDict{Any,Nothing}(),
	)

	shared = Dict{Symbol,Any}(:text => "orig")
	p = Plot([scatter(y = [1, 2], customdata = Any[shared, 1])], Layout())
	p.layout.fields[:meta] = shared
	relayout!(p; meta_text = "changed")
	@test p.data[1].fields[:customdata][1] === p.layout.fields[:meta]
	@test p.data[1].fields[:customdata][1][:text] == "changed"

	p = Plot([scatter(y = rand(4), customdata = [rand(3) for _ in 1:4])])
	before = p.data[1].fields[:customdata]
	restyle!(p, 1; name = "n")
	@test p.data[1].fields[:customdata] === before
	@test p.data[1][:name] == "n"
end

@testset "verbs: extend/prepend send only the inserted points" begin
	n = 100_000
	p = Plot([scatter(x = collect(1.0:n), y = zeros(n))])
	sp, renderer = _rv_syncplot(p)
	try
		extendtraces!(sp, Dict(:x => [[n + 1.0]], :y => [[1.0]]), [1], 50_000)
		script = only(renderer.scripts)
		@test _rv_calls(script) == ["await Plotly.extendTraces"]
		@test sizeof(script) < 4096
		@test occursin("\"x\":[[100001.0]]", script)
		@test occursin("\"x\":[50000]", script)
		@test occursin(", [0], ", script)
		@test length(p.data[1][:x]) == 50_000
		@test last(p.data[1][:x]) == n + 1.0
		@test first(p.data[1][:x]) == n + 1.0 - 49_999

		empty!(renderer.scripts)
		prependtraces!(sp, Dict(:x => [[-1.0, -2.0]], :y => [[5.0, 6.0]]), [1], 4)
		script = only(renderer.scripts)
		@test _rv_calls(script) == ["await Plotly.prependTraces"]
		@test occursin("\"y\":[4]", script)
		@test p.data[1][:x] == [-1.0, -2.0, n + 1.0 - 49_999, n + 2.0 - 49_999]
		@test p.data[1][:y] == [5.0, 6.0, 0.0, 0.0]

		# Keyword form; no window means maxPoints -1.
		empty!(renderer.scripts)
		extendtraces!(sp, 1; x = [7.0], y = [0.5])
		script = only(renderer.scripts)
		@test _rv_calls(script) == ["await Plotly.extendTraces"]
		@test occursin("\"y\":[-1]", script)
		@test p.data[1][:y] == [5.0, 6.0, 0.0, 0.0, 0.5]

		# Only the kept inserted points are sent, with a window that
		# reproduces the model.
		empty!(renderer.scripts)
		extendtraces!(sp, Dict(:y => [[1.0, 2.0, 3.0]]), [1], 2)
		script = only(renderer.scripts)
		@test occursin("\"y\":[[2.0,3.0]]", script)
		@test occursin("\"y\":[2]", script)
		@test p.data[1][:y] == [2.0, 3.0]
	finally
		close(sp)
	end

	# Registered Plot targets use the same fast path.
	p = Plot([scatter(y = [1.0, 2.0])])
	sp, renderer = _rv_syncplot(p; register = true)
	try
		@test extendtraces!(p, Dict(:y => [[3.0]]), [1], 5) === p
		@test _rv_calls(only(renderer.scripts)) ==
			["await Plotly.extendTraces"]
		@test prependtraces!(p, [1]; y = [0.0]) === p
		@test p.data[1][:y] == [0.0, 1.0, 2.0, 3.0]
	finally
		close(sp)
	end

	# Unrendered figures (all keyword and index forms).
	p = Plot(scatter(y = [1]))
	@test extendtraces!(p, [1]; y = [2]) === p
	@test p.data[1][:y] == [1, 2]
	@test prependtraces!(p; y = [0]) === p
	@test p.data[1][:y] == [0, 1, 2]
	@test extendtraces!(p, 1; y = [3]) === p
	@test prependtraces!(p, Dict(:y => [[-1]]), 1) === p
	@test p.data[1][:y] == [-1, 0, 1, 2, 3]

	# Calls whose window result plotly.js cannot reproduce exactly keep the
	# full Plotly.react refresh, and still commit the PlotlyBase result.
	fallbacks = (
		# element type promotion (Int data extended with Float64)
		(
			Plot([scatter(x = [1, 2], y = [1, 2])]),
			sp -> extendtraces!(sp, Dict(:y => [[2.5]]), [1]),
			p -> p.data[1][:y] == [1.0, 2.0, 2.5],
		),
		# trace types with computed bins/positions
		(
			Plot([bar(x = [1, 2], y = [1, 2])]),
			sp -> extendtraces!(sp, Dict(:y => [[3]], :x => [[3]]), [1]),
			p -> p.data[1][:y] == [1, 2, 3],
		),
		# one trace object listed twice
		let trace = scatter(y = [1, 2])
			(
				Plot([trace, trace]),
				sp -> extendtraces!(sp, Dict(:y => [[3]]), [1]),
				p -> p.data[2][:y] == [1, 2, 3],
			)
		end,
		# an axis data array that becomes empty
		(
			Plot([scatter(x = [1, 2], y = [1, 2])]),
			sp -> extendtraces!(sp, Dict(:x => [[3]], :y => [[3]]), [1], 0),
			p -> isempty(p.data[1][:x]),
		),
		# underscore keys address nested attributes
		(
			Plot([scatter(y = [1, 2], marker = attr(color = ["a", "b"]))]),
			sp -> extendtraces!(sp, Dict(:marker_color => [["c"]]), [1]),
			p -> p.data[1][:marker][:color] == ["a", "b", "c"],
		),
	)
	for (p, call, check) in fallbacks
		sp, renderer = _rv_syncplot(p)
		try
			call(sp)
			@test _rv_calls(only(renderer.scripts)) == ["await Plotly.react"]
			@test check(p)
		finally
			close(sp)
		end
	end

	# Invalid calls fail before touching the renderer or the model.
	p = Plot([scatter(y = [1.0, 2.0])])
	sp, renderer = _rv_syncplot(p)
	try
		@test_throws ArgumentError extendtraces!(sp, Dict(:y => [[1.0]]), [1, 1])
		@test_throws ArgumentError extendtraces!(sp, Dict(:z => [[1.0]]), [1])
		@test_throws BoundsError extendtraces!(sp, Dict(:y => [[1.0]]), [2])
		@test isempty(renderer.scripts)
		@test p.data[1][:y] == [1.0, 2.0]
	finally
		close(sp)
	end
end

@testset "verbs: scalar title deltas replace the title container" begin
	p = Plot(
		[scatter(y = [1, 2])],
		Layout(
			title = attr(text = "old", x = 0.3),
			xaxis = attr(title = attr(text = "xo", font = attr(size = 9))),
		),
	)
	sp, renderer = _rv_syncplot(p)
	try
		relayout!(sp; title = "New")
		@test p.layout.fields[:title] == "New"
		@test occursin("{\"title\":{\"text\":\"New\"}}", last(renderer.scripts))

		relayout!(sp; xaxis = attr(title = "X"))
		@test p.layout[:xaxis][:title] == "X"
		@test occursin(
			"\"xaxis.title\":{\"text\":\"X\"}",
			last(renderer.scripts),
		)

		restyle!(sp, 1; marker = attr(colorbar = attr(title = "cb")))
		@test occursin(
			"\"colorbar\":{\"title\":{\"text\":\"cb\"}}",
			last(renderer.scripts),
		)
		# The renderer copy is wrapped; the model keeps its value.
		@test p.data[1].fields[:marker][:colorbar][:title] == "cb"

		relayout!(sp; meta = Dict(:xaxis => Dict(:title => "data")))
		@test occursin(
			"\"meta\":{\"xaxis\":{\"title\":\"data\"}}",
			last(renderer.scripts),
		)
	finally
		close(sp)
	end
end

@testset "verbs: removed dead helpers stay removed" begin
	@test !isdefined(PlotlySupply, :_incremental_candidate_model)
	@test !isdefined(
		PlotlySupply,
		Symbol("_collect_changed_mutation_containers!"),
	)
	@test !isdefined(PlotlySupply, Symbol("_maybe_sync_refresh!"))
	@test !isdefined(PlotlySupply, Symbol("_maybe_sync_command!"))
	# The displayed-plot list duplicated _PLOT_SYNCPLOT_MAP (written in the same
	# critical sections, never read by the package).
	@test !isdefined(PlotlySupply, :_DISPLAYED_PLOTS)
	@test !isdefined(PlotlySupply, Symbol("_plotlyjs_refresh!"))

	# redraw! on a displayed Plot runs inside the renderer transaction.
	p = Plot([scatter(y = [1, 2])])
	sp, renderer = _rv_syncplot(p; register = true)
	try
		@test redraw!(p) === p
		# 2.0 (#165): redraw! rebuilds the window from the Julia model.
		@test occursin("await Plotly.newPlot(div,", only(renderer.scripts))
	finally
		close(sp)
	end
	@test redraw!(Plot(scatter(y = [1]))) isa Plot
end

@testset "verbs: dotted Symbol keys are property paths" begin
	p = Plot(
		[scatter(y = [1, 2], marker = attr(color = "green"))],
		Layout(xaxis = attr(title = attr(text = "x0")), title = "T"),
	)
	sp, renderer = _rv_syncplot(p)
	try
		restyle!(sp, 1, Dict(Symbol("marker.color") => "red"))
		@test p.data[1][:marker][:color] == "red"
		@test !haskey(p.data[1].fields, Symbol("marker.color"))
		@test occursin("\"marker.color\":[\"red\"]", last(renderer.scripts))

		restyle!(sp, 1, Dict(Symbol("error_y.color") => "blue"))
		@test p.data[1].fields[:error_y] == Dict{Any,Any}(:color => "blue")

		relayout!(sp, Dict(Symbol("xaxis.title.text") => "XT"))
		@test p.layout[:xaxis][:title][:text] == "XT"
		@test !haskey(p.layout.fields, Symbol("xaxis.title.text"))

		relayout!(sp, Dict(Symbol("title.x") => 0.5))
		@test p.layout.fields[:title] == Dict{Any,Any}(:text => "T", :x => 0.5)

		relayout!(sp; (Symbol("yaxis.range") => [0, 1],)...)
		@test p.layout[:yaxis][:range] == [0, 1]

		before = _RV_PB.JSON.json(p)
		count = length(renderer.scripts)
		@test_throws ArgumentError relayout!(
			sp,
			Dict(Symbol("annotations[0].text") => "x"),
		)
		@test_throws ArgumentError relayout!(
			sp,
			Dict(Symbol("xaxis..range") => [0, 1]),
		)
		@test_throws ArgumentError restyle!(
			sp,
			1,
			Dict(Symbol("marker.") => 1),
		)
		@test _RV_PB.JSON.json(p) == before
		@test length(renderer.scripts) == count
	finally
		close(sp)
	end

	p = Plot([scatter(y = [1, 2])])
	update!(p, 1, Dict(Symbol("line.width") => 3))
	@test p.data[1][:line][:width] == 3
end

@testset "verbs: empty vectorized values raise ArgumentError" begin
	p = Plot([scatter(y = [1]), scatter(y = [2])])
	before = [trace[:y] for trace in p.data]
	@test_throws ArgumentError restyle!(p; y = Float64[])
	@test_throws ArgumentError restyle!(p, [1, 2]; y = Float64[])
	@test_throws ArgumentError update!(p; y = Float64[])
	@test_throws ArgumentError restyle!(p; y = ())
	@test_throws ArgumentError restyle!(p, 1; y = Float64[])
	@test_throws ArgumentError restyle!(p, [1, 2], Dict(:y => Float64[]))
	@test [trace[:y] for trace in p.data] == before
	message = try
		restyle!(p; y = Float64[])
		""
	catch err
		sprint(showerror, err)
	end
	@test startswith(message, "ArgumentError: restyle!:")
	@test restyle!(p, Int[]; y = Float64[]) === p
	@test [trace[:y] for trace in p.data] == before
	restyle!(p; y = (Float64[],))
	@test all(isempty(trace[:y]) for trace in p.data)
end

@testset "verbs: plotly.js side effects select a full refresh" begin
	function last_calls(make, mutate!)
		p = make()
		sp, renderer = _rv_syncplot(p)
		try
			mutate!(sp)
			return _rv_calls(last(renderer.scripts))
		finally
			close(sp)
		end
	end
	ranged() = Plot(
		scatter(x = collect(1:100), y = collect(1:100) .^ 2),
		Layout(xaxis = attr(range = [1, 100])),
	)
	react = ["await Plotly.react"]
	@test last_calls(ranged, sp -> relayout!(sp; xaxis_type = "log")) == react
	@test last_calls(ranged, sp -> restyle!(sp, 1; type = "bar")) == react
	@test last_calls(ranged, sp -> restyle!(sp, 1; orientation = "h")) == react
	@test last_calls(
		ranged,
		sp -> update!(sp, 1; layout = Layout(xaxis_type = "log")),
	) == react
	@test last_calls(ranged, sp -> relayout!(sp; width = 500)) == react
	@test last_calls(
		() -> Plot(scatter3d(x = [1, 2], y = [1, 2], z = [1, 2]), Layout(scene = attr(aspectmode = "auto"))),
		sp -> relayout!(sp; scene_aspectratio = attr(x = 1, y = 1, z = 0.3)),
	) == react
	@test last_calls(
		() -> Plot(scatter(y = [1, 2]), Layout(xaxis = attr(autorange = true))),
		sp -> relayout!(sp; xaxis_range = [0, 1]),
	) == react
	@test last_calls(
		() -> Plot(heatmap(z = [1 2; 3 4])),
		sp -> restyle!(sp, 1; zmin = 0),
	) == react
	@test last_calls(
		() -> Plot(heatmap(z = [1 2; 3 4], autocolorscale = true)),
		sp -> restyle!(sp, 1; colorscale = "Viridis"),
	) == react
	@test last_calls(
		() -> Plot(scatter(y = [1, 2], marker = attr(color = [1, 2]))),
		sp -> restyle!(sp, 1; marker_cmin = 0),
	) == react
	@test last_calls(
		() -> Plot(scatter(y = [1, 2]), Layout(xaxis = attr(tickmode = "auto"))),
		sp -> relayout!(sp; xaxis_dtick = 1),
	) == react
	@test last_calls(
		() -> Plot(scatter(y = [1, 2, 3]), Layout(xaxis = attr(type = "linear"))),
		sp -> restyle!(sp, 1; y = ([4, 5, 6],)),
	) == react
	# A template default replaces plotly.js's attribute default. (The layout
	# already has an xaxis, so the renderer receives leaf paths such as
	# `xaxis.range`, which carry plotly.js implied edits; a whole new container
	# carries none.)
	templated = function ()
		layout = Layout(xaxis = attr(showgrid = true))
		layout.fields[:template] =
			_RV_PB.Template(layout = Layout(xaxis_autorange = true))
		return Plot(scatter(y = [1, 2]), layout)
	end
	@test last_calls(
		templated,
		sp -> relayout!(sp; xaxis_range = [0, 1]),
	) == react
	@test last_calls(
		templated,
		sp -> relayout!(sp; xaxis_dtick = 1),
	) == ["await Plotly.relayout"]

	# Calls whose implied edits match the model stay incremental.
	gridded() = Plot(scatter(y = [1, 2]), Layout(xaxis = attr(showgrid = true)))
	@test last_calls(
		gridded,
		sp -> relayout!(sp; xaxis_range = [0, 1]),
	) == ["await Plotly.relayout"]
	@test last_calls(
		gridded,
		sp -> relayout!(sp; xaxis_dtick = 1),
	) == ["await Plotly.relayout"]
	@test last_calls(
		() -> Plot(scatter(y = [1, 2])),
		sp -> relayout!(sp; xaxis_range = [0, 1]),
	) == ["await Plotly.relayout"]
	@test last_calls(
		() -> Plot(scatter3d(x = [1, 2], y = [1, 2], z = [1, 2])),
		sp -> relayout!(sp; scene_aspectratio = attr(x = 1, y = 1, z = 0.3)),
	) == ["await Plotly.relayout"]
	@test last_calls(
		() -> Plot(scatter(y = [1, 2, 3])),
		sp -> restyle!(sp, 1; y = ([4, 5, 6],)),
	) == ["await Plotly.restyle"]
	@test last_calls(
		ranged,
		sp -> restyle!(sp, 1; marker_size = 3),
	) == ["await Plotly.restyle"]

	# The full refresh commits exactly the PlotlyBase model.
	p = ranged()
	sp, renderer = _rv_syncplot(p)
	try
		relayout!(sp; xaxis_type = "log")
		@test p.layout[:xaxis][:type] == "log"
		@test p.layout[:xaxis][:range] == [1, 100]
		@test occursin(
			_RV_PB.JSON.json(p.layout; allownan = true),
			last(renderer.scripts),
		)
	finally
		close(sp)
	end
end

# ── Real renderer checks (hidden Electron windows) ─────────────────────

# ElectronCall is a hard dependency, so a window that fails to open is a test
# failure, not a skip.
_rv_open_window(p::Plot) = to_syncplot(p; show = false)

function _rv_js(sp::SyncPlot, script::AbstractString)
	backend = PlotlySupply._syncplot_backend(sp)
	return Base.invokelatest(() -> backend.run(sp.window, script))
end

function _rv_div_json(sp::SyncPlot, divid::AbstractString, expression)
	return _rv_js(
		sp,
		"(function(){ const d = document.getElementById(" *
		PlotlySupply._json_js(divid) * "); " *
		"try { return JSON.stringify($expression); } " *
		"catch (e) { return 'ERR ' + e.message; } })()",
	)
end

@testset "verbs: live renderer matches the committed model" begin
	sp = _rv_open_window(Plot([scatter(y = [1, 2, 3])], Layout(title = "t")))
	try
		divid = sp.divid
		@test purge!(sp) === sp
		@test relayout!(sp; title = "x") === sp
		@test _rv_div_json(sp, divid, "d._fullLayout.title.text") ==
			"\"x\""
		@test redraw!(sp) === sp
		@test update!(sp; layout = Layout(title = "y")) === sp
		@test addtraces!(sp, scatter(y = [2, 1])) === sp
		@test _rv_div_json(sp, divid, "d.data.length") == "1"
		@test _rv_div_json(sp, divid, "d._fullLayout.title.text") ==
			"\"y\""
		@test !sp._resources.renderer_desynchronized
	finally
		close(sp)
	end

	sp = _rv_open_window(Plot(scatter(x = [1, 2, 3, 4], y = [1, 2, 3, 4])))
	try
		divid = sp.divid
		model_x() = _RV_PB.JSON.json(sp.plot.data[1][:x])
		live_x() = _rv_div_json(sp, divid, "d.data[0].x")
		extendtraces!(sp, Dict(:x => [[5, 6, 7]], :y => [[5, 6, 7]]), [1], 3)
		@test sp.plot.data[1][:x] == [5, 6, 7]
		@test live_x() == model_x()
		prependtraces!(sp, Dict(:x => [[0, -1]], :y => [[0, -1]]), [1], 4)
		@test sp.plot.data[1][:x] == [0, -1, 5, 6]
		@test live_x() == model_x()
		extendtraces!(sp, Dict(:y => [[9]]), [1], 0)
		@test isempty(sp.plot.data[1][:y])
		@test _rv_div_json(sp, divid, "d.data[0].y") == "[]"

		# A user zoom survives a streamed append.
		restyle!(sp, 1; y = ([1, 2, 3, 4],))
		_rv_js(
			sp,
			"(async function(){ await Plotly.relayout(document." *
			"getElementById(" * PlotlySupply._json_js(divid) *
			"), {'xaxis.range': [0.5, 1.5]}); return 'ok'; })()",
		)
		extendtraces!(sp, 1; x = [8], y = [5])
		@test _rv_div_json(sp, divid, "d._fullLayout.xaxis.range") ==
			"[0.5,1.5]"
		@test live_x() == model_x()
	finally
		close(sp)
	end

	# Differential checks: mutate a plot rendered in one div through a
	# SyncPlot bound to it, then render the committed model into a second div
	# and compare what plotly.js shows.
	host = _rv_open_window(Plot(scatter(y = [1])))
	try
		_rv_js(
			host,
			"""
(function(){
  for (const id of ["rv-live", "rv-model"]) {
    const d = document.createElement("div");
    d.id = id;
    d.style.width = "600px";
    d.style.height = "400px";
    document.body.appendChild(d);
  }
  return "ok";
})()""",
		)
		function render!(divid, p)
			result = _rv_js(
				host,
				"(async function(){ const d = document.getElementById(" *
				PlotlySupply._json_js(divid) * "); Plotly.purge(d); " *
				"await Plotly.newPlot(d, $(PlotlySupply._json_js(p.data)), " *
				"$(PlotlySupply._json_js(p.layout)), " *
				"$(PlotlySupply._json_js(p.config))); return 'ok'; })()",
			)
			result == "ok" || error("newPlot failed: $result")
		end
		function differential(make, mutate!, expressions)
			p = make()
			render!("rv-live", p)
			backend = (
				isopen = window -> true,
				close = window -> nothing,
				run = (window, script) -> _rv_js(host, script),
			)
			probe = SyncPlot(
				p,
				nothing,
				:rv_probe,
				"rv-live",
				PlotlySupply._SyncPlotResources(nothing, backend),
			)
			try
				mutate!(probe)
			finally
				close(probe)
			end
			render!("rv-model", p)
			return [
				_rv_div_json(host, "rv-live", expression) ==
				_rv_div_json(host, "rv-model", expression)
				for expression in expressions
			]
		end
		ranged() = Plot(
			scatter(x = collect(1:100), y = collect(1:100) .^ 2),
			Layout(xaxis = attr(range = [1, 100])),
		)
		axis = ["d._fullLayout.xaxis.range", "d._fullLayout.xaxis.type"]
		@test all(differential(
			ranged,
			sp -> relayout!(sp; xaxis_type = "log"),
			axis,
		))
		@test all(differential(
			ranged,
			sp -> restyle!(sp, 1; type = "bar"),
			[axis; "d._fullData[0].type"],
		))
		@test all(differential(
			() -> Plot(
				scatter(y = [1, 2]),
				Layout(xaxis = attr(autorange = true)),
			),
			sp -> relayout!(sp; xaxis_range = [0, 1]),
			[axis; "d._fullLayout.xaxis.autorange"],
		))
		@test all(differential(
			() -> Plot(
				scatter3d(x = [1, 2], y = [1, 2], z = [1, 2]),
				Layout(scene = attr(aspectmode = "auto")),
			),
			sp -> relayout!(sp; scene_aspectratio = attr(x = 1, y = 1, z = 0.3)),
			["d._fullLayout.scene.aspectmode", "d._fullLayout.scene.aspectratio"],
		))
		@test all(differential(
			() -> Plot(heatmap(z = [1 2; 3 4])),
			sp -> restyle!(sp, 1; zmin = 0),
			["d._fullData[0].zauto", "d._fullData[0].zmin", "d._fullData[0].zmax"],
		))
		@test all(differential(
			() -> Plot(
				[scatter(y = [1, 2])],
				Layout(title = attr(text = "old", font = attr(size = 30))),
			),
			sp -> relayout!(sp; title = "New"),
			["d._fullLayout.title.text", "d._fullLayout.title.font.size"],
		))
		@test all(differential(
			() -> Plot([scatter(y = [1, 2, 3], mode = "markers")]),
			sp -> restyle!(
				sp,
				1;
				marker = attr(
					color = [1, 2, 3],
					showscale = true,
					colorbar = attr(title = "cb"),
				),
			),
			["d._fullData[0].marker.colorbar.title.text"],
		))
		@test all(differential(
			() -> Plot([scatter(y = [1, 2], line = attr(color = "red"))]),
			sp -> restyle!(sp, 1; line = nothing),
			["d._fullData[0].line.color"],
		))
		@test all(differential(
			() -> Plot([scatter(y = [1, 2], marker = attr(size = 4))]),
			sp -> restyle!(sp, 1, Dict(Symbol("marker.size") => 9)),
			["d._fullData[0].marker.size"],
		))
	finally
		close(host)
	end
end

# ── Shape and image verbs (G26), cell keywords on whole-figure verbs (Y31) ──

using Dates

_rv_fields(item) = (item isa _RV_PB.Shape || item isa _RV_PB.PlotlyAttribute) ? item.fields : item
_rv_refs(item) = (_rv_fields(item)[:xref], _rv_fields(item)[:yref])
_rv_items(p::Plot, key::Symbol) = collect(get(p.layout.fields, key, Any[]))

# The ArgumentError `f()` throws, or `nothing` when it returns.
function _rv_argument_error(f)
	try
		f()
	catch err
		err isa ArgumentError && return err
		rethrow()
	end
	return nothing
end

@testset "verbs: shape and image verbs on a SubplotFigure (G26)" begin
	specs = [Spec() Spec(); Spec(kind = "polar") Spec(secondary_y = true)]
	sf = subplots(2, 2; sync = false, specs = specs)
	plot_scatter!(sf, 1:10, collect(1.0:10.0); row = 1, col = 1)
	plot_scatter!(sf, 1:10, collect(1.0:10.0); row = 2, col = 2)
	cell(r, c; kw...) = PlotlySupply._cell_target(sf; row = r, col = c, kw...)
	t11, t12, t22 = cell(1, 1), cell(1, 2), cell(2, 2)
	t22s = cell(2, 2; secondary_y = true)
	subplot!(sf, 1, 1)

	# One cell: the shape lands on that cell's axes and the cell becomes active.
	@test add_hline!(sf, 0.5; row = 2, col = 2, line_dash = "dash") === sf
	shape = last(_rv_items(sf.plot, :shapes))
	@test _rv_refs(shape) == ("$(t22.xref) domain", t22.yref)
	@test _rv_fields(shape)[:y0] == 0.5 && _rv_fields(shape)[:y1] == 0.5
	@test _rv_fields(shape)[:x0] == 0 && _rv_fields(shape)[:x1] == 1
	@test _rv_fields(_rv_fields(shape)[:line])[:dash] == "dash"
	@test !haskey(_rv_fields(shape), :row) && !haskey(_rv_fields(shape), :show)
	@test (sf.current_row, sf.current_col) == (2, 2)

	# Without row/col: the active cell.
	subplot!(sf, 1, 2)
	add_vline!(sf, 3)
	@test _rv_refs(last(_rv_items(sf.plot, :shapes))) == (t12.xref, "$(t12.yref) domain")
	# secondary_y: the cell's secondary y axis.
	add_hrect!(sf, 0.2, 0.4; row = 2, col = 2, secondary_y = true, fillcolor = "red")
	band = last(_rv_items(sf.plot, :shapes))
	@test _rv_refs(band) == ("$(t22s.xref) domain", t22s.yref)
	@test t22s.yref != t22.yref
	@test (_rv_fields(band)[:y0], _rv_fields(band)[:y1]) == (0.2, 0.4)

	# "all": every Cartesian cell (the polar cell is skipped); the active cell stays.
	subplot!(sf, 1, 1)
	n_before = length(_rv_items(sf.plot, :shapes))
	add_vrect!(sf, 2, 4; row = "all", col = "all", opacity = 0.2)
	added = _rv_items(sf.plot, :shapes)[(n_before + 1):end]
	@test Set(_rv_refs.(added)) == Set([(t.xref, "$(t.yref) domain") for t in (t11, t12, t22)])
	@test all(_rv_fields(s)[:opacity] == 0.2 for s in added)
	@test (sf.current_row, sf.current_col) == (1, 1)
	n_before = length(_rv_items(sf.plot, :shapes))
	add_hline!(sf, 1.0; row = 1, col = "all")
	@test Set(_rv_refs.(_rv_items(sf.plot, :shapes)[(n_before + 1):end])) ==
		Set([("$(t.xref) domain", t.yref) for t in (t11, t12)])

	# add_shape!: data coordinates; a paper reference becomes the cell's domain.
	add_shape!(sf, rect(1, 2, 0.1, 0.2); row = 1, col = 2)
	@test _rv_refs(last(_rv_items(sf.plot, :shapes))) == (t12.xref, t12.yref)
	add_shape!(sf, _RV_PB.hline(0.5); row = 1, col = 2)
	@test _rv_refs(last(_rv_items(sf.plot, :shapes))) == ("$(t12.xref) domain", t12.yref)
	# A vector of coordinates adds one shape each.
	n_before = length(_rv_items(sf.plot, :shapes))
	add_hline!(sf, [0.1, 0.9]; row = 1, col = 1)
	@test [_rv_fields(s)[:y0] for s in _rv_items(sf.plot, :shapes)[(n_before + 1):end]] == [0.1, 0.9]
	# add_layout_image!: both references are the cell's domain.
	image = attr(source = "data:image/png;base64,iVBORw0KGgo=", x = 0, y = 1, sizex = 0.2, sizey = 0.2)
	add_layout_image!(sf, image; row = 2, col = 2)
	@test _rv_refs(only(_rv_items(sf.plot, :images))) == ("$(t22.xref) domain", "$(t22.yref) domain")
	@test !haskey(image.fields, :xref)  # the caller's attribute is not mutated
	# An inset's axes.
	k = inset!(sf, (0.6, 0.6, 0.3, 0.3); row = 1, col = 1)
	ti = PlotlySupply._cell_target(sf; inset = k)
	add_hline!(sf, 0.5; inset = k)
	@test _rv_refs(last(_rv_items(sf.plot, :shapes))) == ("$(ti.xref) domain", ti.yref)

	# update_shapes! on one cell reaches the Shape entries the verbs add (it
	# skipped them: their attributes live in `Shape.fields`).
	update_shapes!(sf; row = 1, col = 2, opacity = 0.3)
	on12(s) = replace(_rv_fields(s)[:xref], " domain" => "") == t12.xref &&
		replace(_rv_fields(s)[:yref], " domain" => "") == t12.yref
	shapes = _rv_items(sf.plot, :shapes)
	# vline, vrect ("all"), hline (row 1), rect and paper hline on (1, 2).
	@test count(on12, shapes) == 5
	@test all(get(_rv_fields(s), :opacity, nothing) == 0.3 for s in shapes if on12(s))
	@test !any(get(_rv_fields(s), :opacity, nothing) == 0.3 for s in shapes if !on12(s))

	# Errors: ArgumentErrors naming the verb; the figure is unchanged.
	before = deepcopy(sf.plot.layout)
	active = (sf.current_row, sf.current_col)
	for (verb, call) in (
		("add_hline!", () -> add_hline!(sf, 0.5; row = 2, col = 1)),          # polar cell
		("add_hline!", () -> add_hline!(sf, 0.5; row = 99, col = 1)),
		("add_hline!", () -> add_hline!(sf, 0.5; show = true)),
		("add_hline!", () -> add_hline!(sf, 0.5; xref = "paper")),
		("add_hline!", () -> add_hline!(sf, NaN)),
		("add_hline!", () -> add_hline!(sf, nothing)),
		("add_hline!", () -> add_hline!(sf, Float64[])),
		("add_hline!", () -> add_hline!(sf)),
		("add_hline!", () -> add_hline!(sf, 1; row = "all")),
		("add_hline!", () -> add_hline!(sf, 1; row = "any", col = 1)),
		("add_hline!", () -> add_hline!(sf, 1; row = "all", col = "all", inset = k)),
		("add_hrect!", () -> add_hrect!(sf, 0.1; row = 1, col = 1)),
		("add_vrect!", () -> add_vrect!(sf, 1, Inf; row = 1, col = 1)),
		("add_vline!", () -> add_vline!(sf, 1; row = 1, col = 1, secondary_y = true)),
		("add_shape!", () -> add_shape!(sf, rect(1, 2, 3, 4); fillcolor = "red")),
		("add_shape!", () -> add_shape!(sf, 3)),
		("add_layout_image!", () -> add_layout_image!(sf, image; row = 2, col = 1)),
	)
		err = _rv_argument_error(call)
		@test err isa ArgumentError
		@test err !== nothing && startswith(err.msg, verb * ":")
	end
	@test sf.plot.layout == before
	@test (sf.current_row, sf.current_col) == active

	# add_recession_bands!: the bands inside the date span of the cell's
	# traces, over the cell's height.
	dated = subplots(1, 2; sync = false)
	dates = [Date(2007, 1, 1) + Month(i) for i in 0:36]
	plot_scatter!(dated, collect(1.0:3.0), [1.0, 2.0, 3.0]; row = 1, col = 1)
	plot_scatter!(dated, dates, collect(1.0:37.0); row = 1, col = 2)
	@test add_recession_bands!(dated; row = 1, col = 2) === dated
	bands = _rv_items(dated.plot, :shapes)
	@test all(_rv_refs(s) == ("x2", "y2 domain") for s in bands)
	@test all((_rv_fields(s)[:y0], _rv_fields(s)[:y1]) == (0, 1) for s in bands)
	# The same bands as PlotlyBase computes for a single figure with these dates
	# (its table has the 2008-01-01 .. 2009-07-01 recession).
	reference = _RV_PB._recession_band_shapes(Plot(scatter(x = dates, y = collect(1.0:37.0))))
	span(s) = (_rv_fields(s)[:x0], _rv_fields(s)[:x1])
	@test span.(bands) == [span(s) for s in (reference isa AbstractVector ? reference : [reference])]
	@test span.(bands) == [(Date(2008, 1, 1), Date(2009, 7, 1))]
	err = _rv_argument_error(() -> add_recession_bands!(dated; row = 1, col = 1))
	@test err !== nothing && startswith(err.msg, "add_recession_bands!:")
	err = _rv_argument_error(() -> add_recession_bands!(dated; row = 1, col = 2, show = true))
	@test err !== nothing && startswith(err.msg, "add_recession_bands!:")
	@test length(_rv_items(dated.plot, :shapes)) == length(bands)

	# A live figure gets one renderer transaction.
	live = subplots(1, 2; sync = false)
	plot_scatter!(live, 1:3, [1.0, 2.0, 3.0]; row = 1, col = 2)
	sp, renderer = _rv_syncplot(live.plot)
	live.fig = sp
	add_hline!(live, 2.0; row = 1, col = 2)
	@test length(renderer.scripts) == 1
	@test occursin("x2 domain", only(renderer.scripts))
	@test length(_rv_items(live.plot, :shapes)) == 1
end

@testset "verbs: shape verbs on a Plot or SyncPlot validate the grid selection (G26)" begin
	p = plot_scatter(1:3, [1.0, 2.0, 3.0])
	@test add_hline!(p, 2) === p
	@test _rv_refs(only(_rv_items(p, :shapes))) == ("x domain", "y")
	grid = make_subplots(rows = 1, cols = 2)
	add_vline!(grid, 1; col = 2)
	@test _rv_refs(only(_rv_items(grid, :shapes))) == ("x2", "y2 domain")
	add_hline!(grid, 1)
	@test length(_rv_items(grid, :shapes)) == 3
	add_vrect!(grid, 1, 2; row = 1, col = [1, 2])
	@test length(_rv_items(grid, :shapes)) == 5
	# A non-Cartesian cell is skipped for "all" and rejected by index.
	mixed = make_subplots(rows = 1, cols = 2, specs = [Spec() Spec(kind = "polar")])
	add_hline!(mixed, 1)
	@test _rv_refs(only(_rv_items(mixed, :shapes))) == ("x domain", "y")
	before = deepcopy(mixed.layout)
	for (verb, call) in (
		("add_hline!", () -> add_hline!(mixed, 1; col = 2)),
		("add_hline!", () -> add_hline!(mixed, 1; row = 5)),
		("add_hline!", () -> add_hline!(mixed, 1; row = "any")),
		("add_hline!", () -> add_hline!(mixed, 1; col = [1, 3])),
		("add_hline!", () -> add_hline!(mixed, 1; show = true)),
		("add_hline!", () -> add_hline!(mixed, 1; secondary_y = true)),
		("add_hline!", () -> add_hline!(mixed, 1; inset = 1)),
		("add_hline!", () -> add_hline!(mixed, 1; yref = "y2")),
		("add_vline!", () -> add_vline!(mixed, missing)),
		("add_shape!", () -> add_shape!(mixed, "circle")),
		("add_layout_image!", () -> add_layout_image!(mixed, attr(source = "s"); opacity = 0.5)),
		("add_recession_bands!", () -> add_recession_bands!(mixed; show = true)),
		("add_recession_bands!", () -> add_recession_bands!(mixed; row = 1)),
	)
		err = _rv_argument_error(call)
		@test err !== nothing && startswith(err.msg, verb * ":")
	end
	@test mixed.layout == before

	sp, renderer = _rv_syncplot(plot_scatter(1:3, [1.0, 2.0, 3.0]))
	add_hline!(sp, 2)
	@test _rv_refs(only(_rv_items(sp.plot, :shapes))) == ("x domain", "y")
	@test length(renderer.scripts) == 1
	err = _rv_argument_error(() -> add_hline!(sp, 2; show = true))
	@test err !== nothing && startswith(err.msg, "add_hline!:")
	@test length(renderer.scripts) == 1
	@test length(_rv_items(sp.plot, :shapes)) == 1
end

@testset "verbs: cell keywords on whole-figure verbs are ArgumentErrors (Y31)" begin
	# SyncPlot layout updaters defined in plotlyjs_compat.jl.
	sp, renderer = _rv_syncplot(plot_scatter(1:3, [1.0, 2.0, 3.0]))
	before = deepcopy(sp.plot.layout)
	for f in (update_annotations!, update_shapes!, update_images!, update_geos!, update_scenes!, update_ternaries!),
			key in (:row, :col, :secondary_y, :inset, :show)
		err = _rv_argument_error(() -> f(sp; key => 1, opacity = 0.5))
		@test err !== nothing && startswith(err.msg, "$(nameof(f)):") && occursin("`$(key)`", err.msg)
	end
	@test isempty(renderer.scripts)
	@test sp.plot.layout == before
	# The Plot methods of every layout updater and the SyncPlot update_xaxes!/
	# update_yaxes!/update_polars!/update_mapboxes! reject cell keywords (Z24).
	rejects_row(f, fig) = _rv_argument_error(() -> f(fig; row = 1, col = 1, title_text = "t")) !== nothing
	@test rejects_row(update_xaxes!, first(_rv_syncplot(plot_scatter(1:3, [1.0, 2.0, 3.0]))))
	@test rejects_row(update_xaxes!, plot_scatter(1:3, [1.0, 2.0, 3.0]))
	@test rejects_row(update_shapes!, plot_scatter(1:3, [1.0, 2.0, 3.0]))

	# SubplotFigure verbs that act on the whole figure.
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0]; row = 1, col = 1)
	before = deepcopy(sf.plot.layout)
	for (name, call) in (
		("relayout!", () -> relayout!(sf; row = 1, col = 2, title_text = "t")),
		("restyle!", () -> restyle!(sf, 1; col = 2, opacity = 0.5)),
		("update!", () -> update!(sf; inset = 1, title_text = "t")),
		("react!", () -> react!(sf, sf.plot.data, sf.plot.layout; row = 1)),
		("redraw!", () -> redraw!(sf; show = true)),
		("deletetraces!", () -> deletetraces!(sf, 1; row = 1)),
		("movetraces!", () -> movetraces!(sf, 1, 1; secondary_y = true)),
		("extendtraces!", () -> extendtraces!(sf, Dict(:y => [[4.0]]), [1]; row = 1)),
		("prependtraces!", () -> prependtraces!(sf, Dict(:y => [[0.0]]), [1]; col = 1)),
		("purge!", () -> purge!(sf; row = 1, col = 1)),
		("purge!", () -> purge!(sf; keep = true)),
	)
		err = _rv_argument_error(call)
		@test err !== nothing && startswith(err.msg, name * ":")
	end
	@test sf.plot.layout == before
	@test length(sf.plot.data) == 1
	@test !haskey(sf.plot.layout.fields, :row)
	# Without cell keywords they still act on the figure.
	@test relayout!(sf; title_text = "t") === sf
	@test sf.plot.layout.fields[:title][:text] == "t"
end
