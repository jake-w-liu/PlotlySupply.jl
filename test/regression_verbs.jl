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
		# 2.0 builders store `title.text`; a user-built `Layout(title = "T")`
		# still holds a bare String. Nested title setters must work on both.
		stored_title = fig.layout.fields[:title]
		original_text = stored_title isa AbstractString ?
			stored_title : stored_title[:text]
		@test original_text isa AbstractString
		@test relayout!(fig; title_x = 0.5, title_font_size = 20) === fig
		title = fig.layout.fields[:title]
		@test title[:text] == original_text
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

	# A displayed figure applies the same model change and renders it.
	fig = plot_scatter(1:3, [4, 5, 6]; title = "T")
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

	# redraw! on a displayed Plot runs inside the renderer transaction.
	p = Plot([scatter(y = [1, 2])])
	sp, renderer = _rv_syncplot(p; register = true)
	try
		@test redraw!(p) === p
		@test occursin("await Plotly.redraw(div);", only(renderer.scripts))
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

function _rv_open_window(p::Plot)
	try
		return to_syncplot(p; show = false)
	catch err
		# Accept environments where ElectronCall is not installed.
		occursin("ElectronCall", sprint(showerror, err)) || rethrow()
		return nothing
	end
end

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
	if sp === nothing
		@test_skip "Electron is not available"
	else
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
	end

	sp = _rv_open_window(Plot(scatter(x = [1, 2, 3, 4], y = [1, 2, 3, 4])))
	if sp === nothing
		@test_skip "Electron is not available"
	else
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
	end

	# Differential checks: mutate a plot rendered in one div through a
	# SyncPlot bound to it, then render the committed model into a second div
	# and compare what plotly.js shows.
	host = _rv_open_window(Plot(scatter(y = [1])))
	if host === nothing
		@test_skip "Electron is not available"
	else
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
end
