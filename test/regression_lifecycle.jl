using Test, PlotlySupply
using Base64

# Regression tests for the Electron window lifecycle and the PlotlyJS-style
# `plot`/`to_syncplot` entry points. The fake backend below mirrors the
# ElectronCall surface used by PlotlySupply (`Window`, `run`, `isopen`, `close`,
# `msgchannel`, `toggle_devtools`); its names carry an `_RL` prefix so this file
# can be included next to test/runtests.jl's own lifecycle fakes.

mutable struct _RLFakeWindow
	exists::Bool
	msg_channel::Channel{Any}
	uri::String
	width::Int
	height::Int
	title::String
	show::Bool
	close_calls::Int
	devtools_toggles::Int
	on_close::Any
end

mutable struct _RLFakeElectron
	windows::Vector{_RLFakeWindow}
	scripts::Vector{String}
end

_RLFakeElectron() = _RLFakeElectron(_RLFakeWindow[], String[])

function _rl_fake_close(window::_RLFakeWindow)
	window.close_calls += 1
	# Real ElectronCall closes over a pipe, i.e. it task-switches. `on_close`
	# lets a test reproduce that (a GC finalizer must not do it).
	window.on_close === nothing || window.on_close()
	window.exists = false
	isopen(window.msg_channel) && close(window.msg_channel)
	return nothing
end

function Base.getproperty(ec::_RLFakeElectron, name::Symbol)
	if name === :Window
		return function (app, uri; width, height, title, show)
			window = _RLFakeWindow(
				true,
				Channel{Any}(1),
				String(uri),
				width,
				height,
				String(title),
				show,
				0,
				0,
				nothing,
			)
			push!(getfield(ec, :windows), window)
			return window
		end
	elseif name === :isopen
		return window -> window.exists
	elseif name === :close
		return _rl_fake_close
	elseif name === :msgchannel
		return window -> window.msg_channel
	elseif name === :toggle_devtools
		return window -> (window.devtools_toggles += 1; nothing)
	elseif name === :run
		return function (window, script)
			push!(getfield(ec, :scripts), String(script))
			return "ok"
		end
	end
	return getfield(ec, name)
end

# Simulate the notification ElectronCall applies on a native (user) close.
function _rl_native_close!(window::_RLFakeWindow)
	window.exists = false
	isopen(window.msg_channel) && close(window.msg_channel)
	return nothing
end

function _rl_wait(predicate; timeout::Float64=10.0, collect::Bool=false)
	deadline = time() + timeout
	while time() < deadline
		predicate() && return true
		collect && GC.gc(true)
		sleep(0.02)
	end
	collect && GC.gc(true)
	return predicate()
end

# Build a SyncPlot in a separate frame and return only handles that do not
# reference it, so the caller can observe its collection.
@noinline function _rl_unreferenced_fake_syncplot(ec; show::Bool)
	sp = PlotlySupply._create_syncplot_window(
		ec,
		Plot(scatter(y=[1, 2, 3]));
		app=:fake,
		show=show,
	)
	return (
		ref=WeakRef(sp),
		window=sp.window,
		tempdir=getfield(sp, :_resources).tempdir,
	)
end

@noinline function _rl_unreferenced_real_syncplot()
	sp = to_syncplot(Plot(scatter(y=[1, 2, 3])); show=false)
	return (
		ref=WeakRef(sp),
		window=sp.window,
		tempdir=getfield(sp, :_resources).tempdir,
	)
end

@noinline _rl_alive(ref::WeakRef) = ref.value isa SyncPlot

# Close a SyncPlot reached only through a weak reference, without leaving a
# strong reference in the caller's frame.
@noinline function _rl_close_through_ref(ref::WeakRef)
	sp = ref.value
	sp isa SyncPlot || return false
	isopen(sp) || return false
	close(sp) === nothing || return false
	return !isopen(sp)
end

_rl_backend() = PlotlySupply._electroncall()
_rl_isopen(window) = Base.invokelatest(isopen, window)

function _rl_close_raw_window(window)
	_rl_isopen(window) || return nothing
	ec = _rl_backend()
	Base.invokelatest(() -> ec.close(window))
	return nothing
end

function _rl_js(sp::SyncPlot, js::AbstractString)
	ec = PlotlySupply._syncplot_backend(sp)
	return Base.invokelatest(() -> ec.run(sp.window, js))
end

function _rl_window_title(sp::SyncPlot)
	window = sp.window
	ec = _rl_backend()
	return Base.invokelatest(() -> ec.run(
		window.app,
		"require('electron').BrowserWindow.fromId($(window.id)).getTitle()",
	))
end

# A SubplotFigure driving `sp` without opening a real window: build the grid
# headlessly, then swap in the (fake-backed) SyncPlot.
function _rl_syncplot_backed_subplots(sp::SyncPlot, rows::Int, cols::Int)
	sf = subplots(rows, cols; sync=false)
	setfield!(sf, :fig, sp)
	return sf
end

function _rl_error(f)
	try
		f()
	catch err
		return err
	end
	return nothing
end

const _RL_FIGURES = get(
	ENV,
	"PLOTLYSUPPLY_LIFECYCLE_FIGURES",
	"",
)

@testset "regression: Electron lifecycle and plot entry points" begin
	@testset "GC finalizer defers the native close to a task" begin
		ec = _RLFakeElectron()
		handle = _rl_unreferenced_fake_syncplot(ec; show=false)
		# Real ElectronCall closes over a pipe; doing that inside a GC finalizer
		# throws "task switch not allowed from inside gc finalizer".
		handle.window.on_close = () -> yield()
		@test _rl_wait(; collect=true) do
			handle.ref.value === nothing &&
				handle.window.close_calls == 1 &&
				!handle.window.exists &&
				!ispath(handle.tempdir)
		end
		@test !isopen(handle.window.msg_channel)
	end

	@testset "visible windows stay open until closed" begin
		ec = _RLFakeElectron()
		handle = _rl_unreferenced_fake_syncplot(ec; show=true)
		for _ in 1:5
			GC.gc(true)
			sleep(0.06)
		end
		# A window the user can see must not vanish at an arbitrary GC.
		@test _rl_alive(handle.ref)
		@test handle.window.exists
		@test handle.window.close_calls == 0
		@test isdir(handle.tempdir)

		_rl_native_close!(handle.window)
		@test _rl_wait(; collect=true) do
			!ispath(handle.tempdir) && handle.ref.value === nothing
		end
		@test handle.window.close_calls == 0
	end

	@testset "explicit close releases a visible SyncPlot" begin
		ec = _RLFakeElectron()
		handle = _rl_unreferenced_fake_syncplot(ec; show=true)
		@test _rl_close_through_ref(handle.ref)
		@test !handle.window.exists
		@test !ispath(handle.tempdir)
		@test _rl_wait(; collect=true) do
			handle.ref.value === nothing
		end
		@test handle.window.close_calls == 1
	end

	@testset "window options are validated before any window exists" begin
		plot_model = Plot(scatter(y=[1, 2, 3]))
		for (width, height) in ((-5, 720), (960, -1), (NaN, 720), (960, Inf), (0.3, 720), (1.0e12, 720))
			mktempdir() do temp_root
				ec = _RLFakeElectron()
				err = withenv("TMPDIR" => temp_root) do
					_rl_error(() -> PlotlySupply._create_syncplot_window(
						ec,
						plot_model;
						app=:fake,
						show=false,
						width=width,
						height=height,
					))
				end
				@test err isa ArgumentError
				@test occursin(width == 960 ? "height" : "width", err.msg)
				@test isempty(ec.windows)
				@test isempty(ec.scripts)
				@test isempty(readdir(temp_root))
			end
		end
		@test_throws TypeError PlotlySupply._create_syncplot_window(
			_RLFakeElectron(),
			plot_model;
			app=:fake,
			width="wide",
		)
		@test_throws ArgumentError PlotlySupply._create_syncplot_window(
			_RLFakeElectron(),
			plot_model;
			app=:fake,
			width=true,
		)

		# 0 and "" are the package-wide "default" sentinels; Real sizes round.
		ec = _RLFakeElectron()
		sp = PlotlySupply._create_syncplot_window(
			ec,
			plot_model;
			app=:fake,
			show=false,
			width=0,
			height=500.4,
			title=SubString("xx Requested <&> Title", 4),
		)
		try
			window = only(ec.windows)
			spec = getfield(sp, :_resources).creation_spec
			@test (window.width, window.height) == (960, 500)
			@test (spec.width, spec.height) == (960, 500)
			@test window.title == "Requested <&> Title"
			@test spec.title == "Requested <&> Title"
			index_html = read(
				joinpath(getfield(sp, :_resources).tempdir, "index.html"),
				String,
			)
			@test occursin("<title>Requested &lt;&amp;&gt; Title</title>", index_html)
			@test !occursin("<title>PlotlySupply</title>", index_html)
		finally
			close(sp)
		end

		ec = _RLFakeElectron()
		sp = PlotlySupply._create_syncplot_window(
			ec,
			plot_model;
			app=:fake,
			show=false,
			width=0,
			height=0,
			title="",
		)
		try
			window = only(ec.windows)
			@test (window.width, window.height, window.title) ==
				(960, 720, "PlotlySupply")
		finally
			close(sp)
		end
	end

	@testset "startup page: MathJax, window title, non-blocking autoplay" begin
		html = PlotlySupply._syncplot_html("rl-div"; autoplay=true, timeout_s=2.5)
		head, body = split(html, "<body>"; limit=2)
		@test occursin("text/x-mathjax-config", head)
		@test occursin("<script src=\"$(PlotlySupply._MATHJAX_CDN_URL)\"></script>", head)
		@test findfirst("text/x-mathjax-config", head)[1] <
			findfirst(PlotlySupply._MATHJAX_CDN_URL, head)[1]
		@test occursin("<title>PlotlySupply</title>", head)
		# Autoplay starts after the readiness handshake instead of being awaited
		# inside the startup deadline.
		@test !occursin("await Plotly.animate", html)
		@test occursin("if (true) Plotly.animate(div, null).catch(", body)
		@test occursin("await Plotly.addFrames", body)

		quiet = PlotlySupply._syncplot_html("rl-div"; autoplay=false, timeout_s=2.5, title="T&<>\"'")
		@test occursin("if (false) Plotly.animate(div, null).catch(", quiet)
		@test occursin("<title>T&amp;&lt;&gt;&quot;&#39;</title>", quiet)
	end

	@testset "rebuild scripts start autoplay without awaiting it" begin
		frames = [frame(name="rl-f$(i)", data=[attr(y=[i, i + 1])]) for i in 1:3]
		animated = Plot([scatter(y=[0, 1])], Layout(), frames)
		rebuild = PlotlySupply._plotlyjs_newplot_script(animated, "rl-div"; autoplay=true, purge=true)
		@test !occursin("await Plotly.animate", rebuild)
		@test occursin("if (true) Plotly.animate(div, null).catch(", rebuild)
		@test occursin("await Plotly.addFrames", rebuild)
		still = PlotlySupply._plotlyjs_newplot_script(animated, "rl-div"; autoplay=false)
		@test occursin("if (false) Plotly.animate(div, null).catch(", still)

		payload = (data="[]", layout="{}", config="{}", frames="[]")
		sp = SyncPlot(Plot(scatter(y=[1])), nothing, nothing, "rl-payload")
		payload_rebuild = PlotlySupply._plotlyjs_refresh_payload_script(
			sp,
			payload;
			rebuild=true,
			autoplay=true,
		)
		@test !occursin("await Plotly.animate", payload_rebuild)
		@test occursin("if (true) Plotly.animate(div, null).catch(", payload_rebuild)

		# react!(sp, ::Plot) uses the rebuild script; it must not hold the
		# backend for the length of the animation.
		ec = _RLFakeElectron()
		sp = PlotlySupply._create_syncplot_window(
			ec,
			Plot(scatter(y=[0]));
			app=:fake,
			show=false,
		)
		try
			react!(sp, animated)
			@test occursin("Plotly.newPlot", ec.scripts[end])
			@test !occursin("await Plotly.animate", ec.scripts[end])
		finally
			close(sp)
		end
	end

	@testset "plot keyword handling" begin
		t1 = scatter(y=[1, 2])
		t2 = scatter(y=[2, 1])
		lay = Layout(title=attr(text="WANTED"))
		fr = frame(name="rl-frame", data=[attr(y=[3, 4])])

		@test plot(t1; layout=lay).layout === lay
		@test plot([t1, t2]; layout=lay).layout === lay
		@test plot(t1, t2; layout=lay).layout === lay
		@test plot(t1, lay).layout === lay
		@test plot([t1, t2], lay).data == [t1, t2]
		@test plot(t1; frames=[fr]).frames == [fr]
		@test plot(t1, lay, [fr]).frames == [fr]
		@test plot([t1], lay, [fr]).frames == [fr]
		@test plot(lay, [fr]).frames == [fr]
		@test plot(lay).layout === lay
		@test plot(; layout=lay).layout === lay
		@test plot(t1; config=PlotConfig(displaylogo=false)).config.displaylogo == false
		fig = Plot(t1)
		@test plot(fig) === fig

		# An untyped vector of traces (e.g. built with push!) is accepted.
		any_traces = Any[t1, t2]
		p_any = plot(any_traces; layout=lay)
		@test p_any.data == [t1, t2]
		@test p_any.data isa Vector{<:AbstractTrace}
		@test p_any.layout === lay
		@test plot(Any[]) isa Plot
		@test isempty(plot(Any[]).data)
		@test plot(Any[t1], lay, Any[fr]).frames == [fr]
		err = _rl_error(() -> plot(Any[t1, 1]))
		@test err isa ArgumentError
		@test occursin("element 2", err.msg)
		err = _rl_error(() -> plot(t1, lay, Any[fr, 3]))
		@test err isa ArgumentError
		@test occursin("frame", err.msg)

		# Arguments given twice, or model keywords on a prebuilt Plot.
		for call in (
			() -> plot(t1, Layout(); layout=lay),
			() -> plot([t1], Layout(); layout=lay),
			() -> plot(t1, lay, [fr]; frames=[fr]),
			() -> plot(lay; layout=lay),
			() -> plot(Plot(t1); layout=lay),
			() -> plot(Plot(t1); config=PlotConfig()),
			() -> plot(Plot(t1); frames=[fr]),
		)
			err = _rl_error(call)
			@test err isa ArgumentError
			@test startswith(err.msg, "plot: ")
		end

		# Unknown keywords raise on both paths instead of being dropped.
		for call in (
			() -> plot(t1; synch=true),
			() -> plot(t1; sync=false, bogus=1),
			() -> plot(t1; layuot=lay),
			() -> plot([t1]; bogus=1),
			() -> plot(t1, t2; bogus=1),
			() -> plot(Plot(t1); bogus=1),
			() -> plot(; layout=lay, bogus=1),
			() -> plot(lay; bogus=1),
			() -> plot(t1; sync=true, show=false, bogus=1),
		)
			err = _rl_error(call)
			@test err isa ArgumentError
			@test occursin("bogus", err.msg) || occursin("synch", err.msg) ||
				occursin("layuot", err.msg)
			@test occursin("width", err.msg)
		end

		# Window options are accepted (and validated) without sync.
		@test plot(
			t1;
			sync=false,
			title="raw",
			width=500,
			height=400.0,
			show=false,
			app=nothing,
			autoplay=false,
			timeout_s=1,
		) isa Plot
		@test_throws ArgumentError plot(t1; width=-1)
		@test_throws ArgumentError plot(t1; timeout_s=-1)
		@test_throws TypeError plot(t1; width="wide")
		@test_throws TypeError plot(t1; show="yes")
	end

	@testset "unsupported calls name the accepted forms" begin
		for call in (
			() -> plot(1:3, [4, 5, 6]),
			() -> plot(sin, 0, 1),
			() -> plot((scatter(y=[1]), scatter(y=[2]))),
			() -> plot("nonsense"),
		)
			err = _rl_error(call)
			@test err isa ArgumentError
			@test startswith(err.msg, "plot: ")
			@test occursin("plot(traces", err.msg)
			@test occursin("plot_scatter", err.msg)
			@test !occursin("Pkg.add", err.msg)
			@test !occursin("ElectronCall", err.msg)
		end
		err = _rl_error(() -> plot([1, 2, 3]))
		@test err isa ArgumentError
		@test occursin("element 1", err.msg)

		sf = subplots(1, 2; sync=false)
		err = _rl_error(() -> plot(sf))
		@test err isa ArgumentError
		@test occursin("SubplotFigure", err.msg)
		@test occursin("display(sf)", err.msg)

		for (value, needle) in ((42, "Int64"), (sf, "SubplotFigure"), (nothing, "Nothing"))
			err = _rl_error(() -> to_syncplot(value))
			@test err isa ArgumentError
			@test startswith(err.msg, "to_syncplot: ")
			@test occursin(needle, err.msg)
			@test occursin("to_syncplot(fig::Plot", err.msg)
			@test !occursin("Pkg.add", err.msg)
		end

		bogus = SyncPlot(Plot(scatter(y=[1])), nothing, nothing, "rl-bogus")
		@test to_syncplot(bogus) === bogus
		@test to_syncplot(bogus; width=10, title="ignored") === bogus
		@test_throws MethodError to_syncplot(bogus; widht=10)

		for doc in (string(@doc plot), string(@doc to_syncplot))
			@test !occursin("Pkg.add", doc)
			@test !occursin("requires `ElectronCall", doc)
		end
		@test occursin("plot(traces::AbstractVector", string(@doc plot))
		@test nameof(PlotlySupply._electroncall()) === :ElectronCall
	end

	@testset "propertynames(::SyncPlot) lists each name once" begin
		sp = SyncPlot(Plot(scatter(y=[1])), nothing, nothing, "rl-props")
		names = propertynames(sp)
		private_names = propertynames(sp, true)
		@test allunique(names)
		@test allunique(private_names)
		@test count(==(:divid), names) == 1
		@test :data in names && :layout in names && :plot in names
		@test :_resources ∉ names
		@test :_resources ∈ private_names
		@test sp.divid == "rl-props"

		sf = _rl_syncplot_backed_subplots(sp, 1, 1)
		@test allunique(propertynames(sf))
	end

	@testset "SyncPlot helpers use the SyncPlot's own backend" begin
		ec = _RLFakeElectron()
		sp = PlotlySupply._create_syncplot_window(
			ec,
			Plot(scatter(y=[1]));
			app=:fake,
			show=false,
		)
		try
			window = only(ec.windows)
			@test msgchannel(sp) === window.msg_channel
			@test toggle_devtools(sp) === nothing
			@test window.devtools_toggles == 1
		finally
			close(sp)
		end
	end

	@testset "SubplotFigure display and compact show" begin
		sf = subplots(1, 2; sync=false)
		plot_scatter!(sf, 1:3, [1.0, 2.0, 3.0])
		@test applicable(display, PlotlySupply.ElectronDisplay(), sf)
		text = sprint(show, MIME"text/plain"(), sf)
		@test !occursin("ReentrantLock", text)
		@test startswith(text, "SubplotFigure(1x2 grid, active cell (1, 1), Plot with 1 trace)")
		@test sprint(show, sf) == text

		ec = _RLFakeElectron()
		sp = PlotlySupply._create_syncplot_window(
			ec,
			Plot(scatter(y=[1]));
			app=:fake,
			show=false,
		)
		try
			sync_sf = _rl_syncplot_backed_subplots(sp, 2, 3)
			subplot!(sync_sf, 2, 1)
			text = sprint(show, sync_sf)
			@test startswith(text, "SubplotFigure(2x3 grid, active cell (2, 1), SyncPlot(open, div=")
			# A SyncPlot-backed figure already has its window; Base.display falls
			# back to the text display exactly as for a bare SyncPlot.
			err = _rl_error(() -> display(PlotlySupply.ElectronDisplay(), sync_sf))
			@test err isa MethodError
			@test err.f === display
			@test isempty(ec.windows[2:end])
		finally
			close(sp)
		end
	end

	@testset "real Electron windows" begin
		@testset "GC of an unreferenced window leaves the backend usable" begin
			handle = _rl_unreferenced_real_syncplot()
			try
				@test _rl_wait(; collect=true, timeout=30.0) do
					handle.ref.value === nothing &&
						!_rl_isopen(handle.window) &&
						!ispath(handle.tempdir)
				end
				sp = to_syncplot(Plot(scatter(y=[3, 2, 1])); show=false)
				try
					relayout!(sp; title="after-gc")
					@test _rl_js(sp, """
(() => {
  const div = document.getElementById($(PlotlySupply._json_js(sp.divid)));
  return div._fullLayout.title.text;
})()
""") == "after-gc"
				finally
					close(sp)
				end
			finally
				_rl_close_raw_window(handle.window)
			end
		end

		@testset "window title, size and MathJax typesetting" begin
			fig = plot_scatter(
				1:3,
				[1.0, 4.0, 9.0];
				title=raw"$\alpha^2 + \beta_0$",
				xlabel=raw"$x_i$",
				ylabel="plain label",
			)
			sp = to_syncplot(fig; show=false, title="Requested <Title>", width=640.0, height=0)
			try
				@test _rl_window_title(sp) == "Requested <Title>"
				@test _rl_js(sp, "[window.innerWidth, typeof MathJax]") == [640, "object"]
				# plotly.js wraps each MathJax-typeset label in `g.<name>-math-group`.
				math_groups() = sort!(String.(_rl_js(sp, """
Array.from(document.querySelectorAll('g[class\$="-math-group"]'))
  .map(function(g) { return g.getAttribute('class'); })
""")))
				@test _rl_wait(; timeout=20.0) do
					length(math_groups()) == 2
				end
				@test math_groups() == ["gtitle-math-group", "xtitle-math-group"]
				if !isempty(_RL_FIGURES)
					url = to_image(sp; format="png", width=700, height=500)
					png = base64decode(split(url, ","; limit=2)[2])
					write(joinpath(_RL_FIGURES, "live_window_mathjax.png"), png)
				end
			finally
				close(sp)
			end
		end

		@testset "animations longer than the startup timeout open" begin
			frames = [
				frame(name="rl-anim-$(i)", data=[attr(y=[i, i + 1, i + 2])])
				for i in 1:12
			]
			started = time()
			sp = plot(
				scatter(y=[0, 1, 2]);
				frames=frames,
				sync=true,
				show=false,
				timeout_s=3,
			)
			try
				@test sp isa SyncPlot
				@test time() - started < 3 + 10
				@test isopen(sp)
				@test _rl_js(sp, """
(() => {
  const div = document.getElementById($(PlotlySupply._json_js(sp.divid)));
  return div._transitionData._frames.length;
})()
""") == 12
			finally
				close(sp)
			end
		end

		@testset "display(sf) opens the SubplotFigure's Plot" begin
			sf = subplots(1, 1; sync=false)
			plot_scatter!(sf, 1:3, [3.0, 1.0, 2.0])
			display(PlotlySupply.ElectronDisplay(), sf)
			sp = lock(PlotlySupply._SYNCPLOT_REGISTRY_LOCK) do
				get(PlotlySupply._PLOT_SYNCPLOT_MAP, sf.plot, nothing)
			end
			try
				@test sp isa SyncPlot
				@test isopen(sp)
				@test sp.plot === sf.plot
			finally
				sp === nothing || close(sp)
			end
		end
	end
end
