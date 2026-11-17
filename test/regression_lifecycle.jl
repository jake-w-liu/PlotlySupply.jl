using Test, PlotlySupply
using Base64

# Dates is not a declared test dependency (Project.toml [extras]/[targets]), so
# `using Dates` fails under Pkg.test, whose load path is only the test
# environment. Load the stdlib by its UUID from the resolved manifest
# (PlotlyBase depends on it); switch back to `using Dates` once Dates is listed
# in [extras] and the test target.
const _RL_Dates = Base.require(Base.PkgId(Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), "Dates"))

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
	# Page loads (`ec.load(window, uri)`) and an optional error to raise from one.
	loads::Vector{String}
	load_error::Union{Nothing,Exception}
end

_RLFakeElectron() = _RLFakeElectron(_RLFakeWindow[], String[], String[], nothing)

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
	elseif name === :load
		return function (window, uri)
			failure = getfield(ec, :load_error)
			failure === nothing || throw(failure)
			push!(getfield(ec, :loads), String(uri))
			window.uri = String(uri)
			return nothing
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

# Run `f` with `set_default_mathtext!(enabled; kwargs...)` in effect, restoring
# the previous settings afterwards (also on failure).
function _rl_with_mathtext(f, enabled::Bool = true; kwargs...)
	previous = get_default_mathtext()
	set_default_mathtext!(enabled; kwargs...)
	try
		return f()
	finally
		set_default_mathtext!(
			previous.enabled;
			size = previous.size,
			font = previous.font,
			inherit_text_font = previous.inherit_text_font,
		)
	end
end

# Glyph-set prefixes of the MathJax <use> references in `svg` (e.g.
# "LATINMODERNMAIN" for `href="#LATINMODERNMAIN-3B1"`): they name the font.
function _rl_glyph_sets(svg::AbstractString)
	sets = Set{String}()
	for m in eachmatch(r"href=\"#([A-Z]+)-[0-9A-F]+\"", svg)
		push!(sets, m.captures[1])
	end
	return sort!(collect(sets))
end

# Live-window counterpart: glyph sets and inherited <text> font families of the
# typeset label `g.<name>-math-group`, plus that label's source text.
function _rl_live_math(sp::SyncPlot, name::AbstractString)
	result = _rl_js(sp, """
(() => {
  const g = document.querySelector('g.' + $(PlotlySupply._json_js(name)) + '-math-group');
  if (!g) return JSON.stringify(null);
  const source = g.parentNode.querySelector('text.' + $(PlotlySupply._json_js(name)));
  const sets = new Set();
  g.querySelectorAll('use').forEach(u => {
    const ref = u.getAttribute('href') || u.getAttribute('xlink:href') || '';
    const m = ref.match(/^#([A-Z]+)-/);
    if (m) sets.add(m[1]);
  });
  return JSON.stringify({
    source: source ? source.getAttribute('data-unformatted') : null,
    glyphs: Array.from(sets).sort(),
    families: Array.from(g.querySelectorAll('text')).map(t => t.getAttribute('font-family')),
  });
})()
""")
	return PlotlySupply.PlotlyBase.JSON.parse(result)
end

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

	@testset "set_default_mathtext!: font, inherit_text_font, style size" begin
		_rl_with_mathtext() do
			@test get_default_mathtext() ==
				(enabled = true, size = "", font = "", inherit_text_font = false)
			# Font names are matched case-insensitively and stored canonically.
			@test set_default_mathtext!(; font = " stix-web ", inherit_text_font = true) ==
				(enabled = true, size = "", font = "STIX-Web", inherit_text_font = true)
			@test PlotlySupply._mathjax_page_config() ==
				(font = "STIX-Web", inherit_text_font = true)
			for bad in ("bogus", "Latin Modern", "TeX\"); alert(1); (\"")
				err = _rl_error(() -> set_default_mathtext!(; font = bad))
				@test err isa ArgumentError
				@test occursin("set_default_mathtext!", sprint(showerror, err))
				@test occursin("Latin-Modern", sprint(showerror, err))
			end
			# Validation happens before anything changes.
			@test_throws ArgumentError set_default_mathtext!(; size = "\\footnotesize", font = "TeX")
			@test get_default_mathtext().font == "STIX-Web"
			# Every keyword is replaced on each call.
			@test set_default_mathtext!(false) ==
				(enabled = false, size = "", font = "", inherit_text_font = false)
			set_default_mathtext!()

			# font = "" falls back to the environment variable, then Latin-Modern.
			withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => nothing) do
				@test PlotlySupply._mathjax_svg_font() == "Latin-Modern"
			end
			withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => "gyre-pagella") do
				@test PlotlySupply._mathjax_svg_font() == "Gyre-Pagella"
				@test occursin("SVG: {font: \"Gyre-Pagella\"}", PlotlySupply._mathjax_head_html())
				# An explicit setting wins over the environment.
				set_default_mathtext!(; font = "neo-euler")
				@test PlotlySupply._mathjax_svg_font() == "Neo-Euler"
				set_default_mathtext!()
			end
			withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => "bogus") do
				err = _rl_error(PlotlySupply._mathjax_svg_font)
				@test err isa ErrorException
				@test occursin("PLOTLYSUPPLY_MATHJAX_SVG_FONT", err.msg)
				@test occursin("Gyre-Termes", err.msg)
				set_default_mathtext!(; font = "TeX")
				@test PlotlySupply._mathjax_svg_font() == "TeX"
				set_default_mathtext!()
			end

			# The page script carries the font and the inherit switch.
			plain = PlotlySupply._mathjax_config_script("TeX"; inherit_text_font = false)
			@test occursin("SVG: {font: \"TeX\"}", plain)
			@test occursin("var INHERIT = false;", plain)
			@test occursin("\"SVG Jax Ready\"", plain)
			@test !occursin("__INHERIT__", plain)
			inherit = PlotlySupply._mathjax_config_script("Asana-Math"; inherit_text_font = true)
			@test occursin("SVG: {font: \"Asana-Math\"}", inherit)
			@test occursin("var INHERIT = true;", inherit)
			@test occursin("mtextFontInherit: true", inherit)
			# The defaults follow the settings, for every page kind.
			set_default_mathtext!(; font = "gyre-termes", inherit_text_font = true)
			for page in (
				PlotlySupply._mathjax_head_html(),
				PlotlySupply._export_window_html("rl-export"),
				PlotlySupply._syncplot_html("rl-div"; autoplay = false, timeout_s = 1.0),
				String(savefig(Plot(scatter(y = [1, 2])); format = "html")),
			)
				@test occursin("SVG: {font: \"Gyre-Termes\"}", page)
				@test occursin("var INHERIT = true;", page)
			end
			set_default_mathtext!()
			@test occursin(
				"var INHERIT = false;",
				PlotlySupply._syncplot_html("rl-div"; autoplay = false, timeout_s = 1.0),
			)
		end

		# The size default consults the active PlotStyle when its own is "".
		_rl_with_mathtext() do
			@test PlotlySupply._label("Time \$t\$") == "\$\\text{Time }t\$"
			with_style(:publication) do
				@test PlotlySupply._label("Time \$t\$") == "\$\\large{\\text{Time }t}\$"
				@test mathtext("\$x\$") == "\$\\large{x}\$"
				@test mathtext("\$x\$"; size = "") == "\$x\$"
				@test mathtext("\$x\$"; size = "small") == "\$\\small{x}\$"
				@test PlotlySupply._label("plain") == "plain"
				# The package setting overrides the style.
				set_default_mathtext!(; size = "\\normalsize")
				@test PlotlySupply._label("\$x\$") == "\$\\normalsize{x}\$"
				set_default_mathtext!()
			end
			# A style size MathJax 2 does not have fails only for math labels,
			# and an explicit size still works.
			with_style(:default; mathsize = "\\footnotesize") do
				err = _rl_error(() -> PlotlySupply._label("\$x\$"))
				@test err isa ArgumentError
				@test occursin("footnotesize", sprint(showerror, err))
				@test_throws ArgumentError mathtext("\$x\$")
				@test PlotlySupply._label("plain") == "plain"
				@test mathtext("\$x\$"; size = "Large") == "\$\\Large{x}\$"
				set_default_mathtext!(; size = "small")
				@test PlotlySupply._label("\$x\$") == "\$\\small{x}\$"
				set_default_mathtext!()
			end
		end
	end

	@testset "live pages reload when the MathJax configuration changes" begin
		_rl_with_mathtext() do
			ec = _RLFakeElectron()
			sp = PlotlySupply._create_syncplot_window(
				ec,
				Plot(scatter(y = [1, 2]));
				app = :fake,
				show = false,
				title = "Reload",
				autoplay = true,
			)
			try
				resources = getfield(sp, :_resources)
				index = joinpath(resources.tempdir, "index.html")
				model_file = joinpath(resources.tempdir, PlotlySupply._SYNCPLOT_MODEL_FILENAME)
				live_title() = sp.plot.layout[:title]
				@test PlotlySupply._syncplot_page_mathjax(sp) ==
					(font = "Latin-Modern", inherit_text_font = false)
				@test occursin("SVG: {font: \"Latin-Modern\"}", read(index, String))

				# An unchanged configuration never reloads.
				relayout!(sp; title = "a")
				@test isempty(ec.loads)

				set_default_mathtext!(; font = "TeX", inherit_text_font = true)
				before = length(ec.scripts)
				relayout!(sp; title = "b")
				@test ec.loads == [PlotlySupply._file_uri(index)]
				page = read(index, String)
				@test occursin("SVG: {font: \"TeX\"}", page)
				@test occursin("var INHERIT = true;", page)
				@test occursin("<title>Reload</title>", page)
				# A reload never restarts an animation.
				@test occursin("if (false) Plotly.animate", page)
				# The page is rebuilt from the committed model ("a"); the update then
				# runs as usual: readiness handshake, then the relayout script.
				@test occursin("\"title\":\"a\"", read(model_file, String))
				@test ec.scripts[before + 1] == PlotlySupply._syncplot_readiness_script()
				@test length(ec.scripts) == before + 2
				@test live_title() == "b"
				@test PlotlySupply._syncplot_page_mathjax(sp) ==
					(font = "TeX", inherit_text_font = true)
				@test !resources.renderer_desynchronized
				relayout!(sp; title = "b2")
				@test length(ec.loads) == 1

				# A failed reload leaves the model unchanged and marks the renderer
				# desynchronized; the next update reloads again.
				set_default_mathtext!(; font = "STIX-Web")
				ec.load_error = ErrorException("rl load failure")
				err = _rl_error(() -> relayout!(sp; title = "c"))
				@test err isa PlotlySupply._SyncPlotDesynchronizationError
				@test err.recovery_error == ErrorException("rl load failure")
				@test occursin("rl load failure", sprint(showerror, err))
				@test live_title() == "b2"
				@test resources.renderer_desynchronized
				@test PlotlySupply._syncplot_page_mathjax(sp).font == "TeX"
				ec.load_error = nothing
				relayout!(sp; title = "d")
				@test length(ec.loads) == 2
				@test live_title() == "d"
				@test !resources.renderer_desynchronized
				@test PlotlySupply._syncplot_page_mathjax(sp) ==
					(font = "STIX-Web", inherit_text_font = false)

				# An interrupt propagates as itself.
				set_default_mathtext!(; font = "Neo-Euler")
				ec.load_error = InterruptException()
				@test_throws InterruptException relayout!(sp; title = "e")
				@test live_title() == "d"
				@test resources.renderer_desynchronized
				ec.load_error = nothing

				# `_syncplot_refresh_page!` applies the configuration without
				# changing the model.
				model = sp.plot
				@test PlotlySupply._syncplot_refresh_page!(sp) === nothing
				@test length(ec.loads) == 3
				@test sp.plot === model
				@test live_title() == "d"
				@test PlotlySupply._syncplot_page_mathjax(sp).font == "Neo-Euler"
				@test !resources.renderer_desynchronized

				# An invalid environment font fails the update before any renderer
				# effect.
				set_default_mathtext!()
				withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => "bogus") do
					scripts = length(ec.scripts)
					@test_throws ErrorException relayout!(sp; title = "f")
					@test length(ec.scripts) == scripts
					@test live_title() == "d"
				end
			finally
				close(sp)
			end
			@test !isopen(sp)
		end
		# A window cannot be built with an invalid environment font.
		withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => "bogus") do
			ec = _RLFakeElectron()
			@test_throws ErrorException PlotlySupply._create_syncplot_window(
				ec,
				Plot(scatter(y = [1]));
				app = :fake,
				show = false,
			)
			@test isempty(ec.windows)
		end
	end

	@testset "react!(sp, ::Plot) follows the window's autoplay setting" begin
		frames = [frame(name = "rl-ap$(i)", data = [attr(y = [i, i])]) for i in 1:2]
		for autoplay in (true, false)
			ec = _RLFakeElectron()
			sp = PlotlySupply._create_syncplot_window(
				ec,
				Plot(scatter(y = [0, 0]));
				app = :fake,
				show = false,
				autoplay = autoplay,
			)
			try
				react!(sp, Plot([scatter(y = [0, 0])], Layout(), frames))
				@test occursin("if ($(autoplay)) Plotly.animate(div, null)", ec.scripts[end])
				@test !occursin("await Plotly.animate", ec.scripts[end])
			finally
				close(sp)
			end
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

		@testset "react! starts autoplay without blocking other windows" begin
			# 40 frames at plotly's default 500 ms per frame play for ~20 s, far
			# longer than every step below, so "still playing" is deterministic.
			frames = [frame(name = "rl-np$(i)", data = [attr(y = [i, i])]) for i in 1:40]
			playback(sp) = PlotlySupply.PlotlyBase.JSON.parse(_rl_js(sp, """
(() => {
  const d = document.getElementById($(PlotlySupply._json_js(sp.divid)));
  const t = d._transitionData || {};
  return JSON.stringify({y: Array.from(d.data[0].y), queued: (t._frameQueue || []).length,
    running: !!t._animationRaf});
})()
"""))
			opened = SyncPlot[]
			try
				player = push!(opened, to_syncplot(Plot(scatter(y = [0, 0])); show = false))[end]
				other = push!(opened, to_syncplot(Plot(scatter(y = [5, 5])); show = false))[end]
				still = push!(opened, to_syncplot(Plot(scatter(y = [0, 0])); show = false, autoplay = false))[end]
				@test react!(player, Plot([scatter(y = [0, 0])], Layout(), frames)) === player
				# react! returned while the animation is still playing ...
				state = playback(player)
				@test state["running"]
				@test state["queued"] > 0
				# ... and another window's update does not wait for it.
				relayout!(other; title = "not blocked")
				@test playback(player)["running"]
				@test _rl_js(other, "document.getElementById($(PlotlySupply._json_js(other.divid)))._fullLayout.title.text") ==
					"not blocked"
				# A window created with autoplay = false installs frames without playing.
				react!(still, Plot([scatter(y = [0, 0])], Layout(), frames))
				sleep(1.0)
				quiet = playback(still)
				@test quiet["y"] == [0, 0]
				@test !quiet["running"]
				@test quiet["queued"] == 0
				@test _rl_js(still, "document.getElementById($(PlotlySupply._json_js(still.divid)))._transitionData._frames.length") == 40
			finally
				foreach(close, opened)
			end
			@test all(sp -> !isopen(sp), opened)
		end

		@testset "MathJax labels are typeset after react! and relayout!" begin
			fig = Plot(
				scatter(x = [1, 2, 3], y = [1.0, 4.0, 9.0]),
				Layout(
					title = attr(text = mathtext(raw"Start $\alpha^2$")),
					xaxis = attr(title = attr(text = mathtext(raw"$x_i$ (m)"))),
				),
			)
			sp = to_syncplot(fig; show = false)
			try
				typeset(name, label) = _rl_wait(; timeout = 30.0) do
					state = _rl_live_math(sp, name)
					state !== nothing && state["source"] == label && !isempty(state["glyphs"])
				end
				@test typeset("gtitle", mathtext(raw"Start $\alpha^2$"))
				@test typeset("xtitle", mathtext(raw"$x_i$ (m)"))

				after_relayout = mathtext(raw"After relayout $\beta_0$")
				relayout!(sp; title = attr(text = after_relayout))
				@test typeset("gtitle", after_relayout)
				@test typeset("xtitle", mathtext(raw"$x_i$ (m)"))

				ylabel = mathtext(raw"Energy $E^2$ (J)")
				react!(sp, Plot(
					scatter(x = [1, 2, 3], y = [9.0, 4.0, 1.0]),
					Layout(yaxis = attr(title = attr(text = ylabel))),
				))
				@test typeset("ytitle", ylabel)
				# The previous labels are gone with the old layout.
				@test _rl_live_math(sp, "gtitle") === nothing
				@test _rl_live_math(sp, "xtitle") === nothing
				@test !getfield(sp, :_resources).renderer_desynchronized
				if !isempty(_RL_FIGURES)
					relayout!(sp; title = attr(text = after_relayout))
					@test typeset("gtitle", after_relayout)
					url = to_image(sp; format = "png", width = 700, height = 500)
					write(
						joinpath(_RL_FIGURES, "live_mathjax_after_updates.png"),
						base64decode(split(url, ","; limit = 2)[2]),
					)
				end
			finally
				close(sp)
			end
			@test !isopen(sp)
		end

		@testset "set_default_mathtext! reaches open windows and every export" begin
			label = mathtext(raw"Contrast $\lambda$ and $\textbf{bold}\ x$")
			fig() = Plot(
				scatter(x = [1, 2, 3], y = [1.0, 4.0, 9.0]),
				Layout(
					font = attr(family = "Courier New, monospace", size = 16),
					title = attr(text = label),
				),
			)
			_rl_with_mathtext() do
				# Live window: built with Latin-Modern, then the settings change.
				sp = to_syncplot(fig(); show = false)
				try
					@test _rl_wait(; timeout = 30.0) do
						state = _rl_live_math(sp, "gtitle")
						state !== nothing && !isempty(state["glyphs"])
					end
					state = _rl_live_math(sp, "gtitle")
					@test all(startswith("LATINMODERN"), state["glyphs"])
					@test all(isnothing, state["families"])

					set_default_mathtext!(; font = "TeX", inherit_text_font = true)
					relabel = mathtext(raw"Reloaded $\lambda$ and $\textbf{bold}\ x$")
					relayout!(sp; title = attr(text = relabel))
					@test PlotlySupply._syncplot_page_mathjax(sp) ==
						(font = "TeX", inherit_text_font = true)
					@test _rl_wait(; timeout = 30.0) do
						state = _rl_live_math(sp, "gtitle")
						state !== nothing && state["source"] == relabel && !isempty(state["glyphs"])
					end
					state = _rl_live_math(sp, "gtitle")
					@test all(startswith("MJ"), state["glyphs"])
					# Every text run of the label is drawn in the figure font.
					@test !isempty(state["families"])
					@test all(f -> f !== nothing && occursin("Courier New", f), state["families"])
					@test sp.plot.layout[:title][:text] == relabel
					@test !getfield(sp, :_resources).renderer_desynchronized
					if !isempty(_RL_FIGURES)
						url = to_image(sp; format = "png", width = 700, height = 500)
						write(
							joinpath(_RL_FIGURES, "live_reloaded_tex_inherit.png"),
							base64decode(split(url, ","; limit = 2)[2]),
						)
					end
				finally
					close(sp)
				end
				@test !isopen(sp)

				# Export window: reused while the configuration is unchanged,
				# rebuilt as soon as it changes.
				set_default_mathtext!()
				svg() = String(savefig(fig(); format = "svg", width = 600, height = 400))
				inherited(svg) = occursin(r"<text[^>]*font-family=\"[^\"]*Courier New", svg)
				first_svg = svg()
				@test "LATINMODERNMAIN" in _rl_glyph_sets(first_svg)
				@test all(startswith("LATINMODERN"), _rl_glyph_sets(first_svg))
				@test !inherited(first_svg)
				window = PlotlySupply._EXPORT_STATE.window
				svg()
				@test PlotlySupply._EXPORT_STATE.window === window

				set_default_mathtext!(; font = "gyre-termes")
				termes = svg()
				@test !isempty(_rl_glyph_sets(termes))
				@test all(startswith("GYRETERMES"), _rl_glyph_sets(termes))
				@test !inherited(termes)
				@test PlotlySupply._EXPORT_STATE.window !== window
				@test PlotlySupply._EXPORT_STATE.mathjax_font == "Gyre-Termes"
				@test !PlotlySupply._EXPORT_STATE.mathjax_inherit_text_font
				window = PlotlySupply._EXPORT_STATE.window

				set_default_mathtext!(; font = "Gyre-Termes", inherit_text_font = true)
				inherit_svg = svg()
				@test all(startswith("GYRETERMES"), _rl_glyph_sets(inherit_svg))
				@test inherited(inherit_svg)
				@test PlotlySupply._EXPORT_STATE.window !== window
				@test PlotlySupply._EXPORT_STATE.mathjax_inherit_text_font
				# PDF export of an inherited label works (a `"` in a font list
				# used to break plotly's SVG serialization).
				pdf = savefig(fig(); format = "pdf", width = 600, height = 400)
				@test String(pdf[1:5]) == "%PDF-"
				if !isempty(_RL_FIGURES)
					savefig(fig(), joinpath(_RL_FIGURES, "export_termes_inherit.png"); width = 700, height = 500)
					set_default_mathtext!()
					savefig(fig(), joinpath(_RL_FIGURES, "export_default.png"); width = 700, height = 500)
				end
			end
			# Back to the defaults: the next export rebuilds the window again.
			restored = _rl_glyph_sets(String(savefig(fig(); format = "svg")))
			@test "LATINMODERNMAIN" in restored
			@test all(startswith("LATINMODERN"), restored)
			@test PlotlySupply._EXPORT_STATE.mathjax_font == "Latin-Modern"
			@test !PlotlySupply._EXPORT_STATE.mathjax_inherit_text_font
		end

		@testset "shape, image, JSON and devtools entry points" begin
			months = collect(_RL_Dates.Date(2007, 1, 1):_RL_Dates.Month(1):_RL_Dates.Date(2010, 12, 1))
			sp = to_syncplot(
				Plot(scatter(x = months, y = collect(1.0:length(months)))),
				show = false,
			)
			try
				live(expr) = _rl_js(sp, """
(() => {
  const d = document.getElementById($(PlotlySupply._json_js(sp.divid)));
  return JSON.stringify($expr);
})()
""")
				live_shapes() = PlotlySupply.PlotlyBase.JSON.parse(live(
					"d._fullLayout.shapes.map(s => [s.type, s.xref, s.yref, s.x0, s.x1, s.y0, s.y1])",
				))
				model_shapes() = sp.plot.layout[:shapes]

				@test add_vline!(sp, "2008-06-01"; line_color = "red") === sp
				@test length(model_shapes()) == 1
				@test live_shapes() == [["line", "x", "y domain", "2008-06-01", "2008-06-01", 0, 1]]

				@test add_hrect!(sp, 2.0, 5.0; fillcolor = "blue", opacity = 0.2) === sp
				@test live_shapes()[2] == ["rect", "x domain", "y", 0, 1, 2, 5]

				@test add_vrect!(sp, "2009-01-01", "2009-06-01") === sp
				@test live_shapes()[3] == ["rect", "x", "y domain", "2009-01-01", "2009-06-01", 0, 1]

				@test add_shape!(sp, attr(type = "circle", x0 = "2010-01-01", x1 = "2010-03-01", y0 = 30, y1 = 40)) === sp
				@test live_shapes()[4] == ["circle", "x", "y", "2010-01-01", "2010-03-01", 30, 40]
				@test length(model_shapes()) == 4

				# A 1x1 transparent PNG.
				pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
				@test add_layout_image!(sp, attr(source = pixel, x = 0.1, y = 0.9, sizex = 0.2, sizey = 0.2)) === sp
				@test length(sp.plot.layout[:images]) == 1
				@test PlotlySupply.PlotlyBase.JSON.parse(live(
					"d._fullLayout.images.map(i => [i.source.length, i.xref, i.yref, i.x, i.y])",
				)) == [[length(pixel), "x domain", "y domain", 0.1, 0.9]]

				# The 2007-2009 recession overlaps the data: one band, appended
				# after the existing shapes and returned.
				existing = live_shapes()
				bands = add_recession_bands!(sp)
				@test length(bands) == 5
				@test length(model_shapes()) == 5
				shapes = live_shapes()
				@test length(shapes) == 5
				@test shapes[1:4] == existing
				# PlotlyBase's recession_dates.tsv row "2008-01-01  2009-07-01".
				@test shapes[5] == ["rect", "x", "paper", "2008-01-01", "2009-07-01", 0, 1]
				@test !getfield(sp, :_resources).renderer_desynchronized

				mktempdir() do dir
					path = joinpath(dir, "fig.json")
					@test savejson(sp, path) === sp.plot
					saved = PlotlySupply.PlotlyBase.JSON.parsefile(path)
					@test length(saved["layout"]["shapes"]) == 5
					@test length(saved["layout"]["images"]) == 1
					@test length(saved["data"][1]["x"]) == length(months)
					@test_throws ArgumentError savejson(sp, joinpath(dir, "fig.png"))
					@test !isfile(joinpath(dir, "fig.png"))
				end

				ec = PlotlySupply._syncplot_backend(sp)
				devtools_open() = Base.invokelatest(() -> ec.run(
					sp.window.app,
					"require('electron').BrowserWindow.fromId($(sp.window.id)).webContents.isDevToolsOpened()",
				))
				@test !devtools_open()
				@test toggle_devtools(sp) === nothing
				@test _rl_wait(devtools_open; timeout = 10.0)
				@test toggle_devtools(sp) === nothing
				@test _rl_wait(() -> !devtools_open(); timeout = 10.0)
				@test isopen(sp)
			finally
				close(sp)
			end
			@test !isopen(sp)
			@test_throws InvalidStateException toggle_devtools(sp)
		end
	end
end
