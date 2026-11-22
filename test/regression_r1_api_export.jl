using Test, PlotlySupply
using PlotlySupply: PlotlyBase
using Base64
isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")

# v8 fix round r1 (api-export): the Electron connection after interrupts and
# failed starts, export documents and pages, user-error contracts of the grid
# constructors and the compat helpers, and test-infrastructure checks.

const _R1 = PlotlySupply

_r1_err(f) = try
	f()
	nothing
catch err
	err
end

function _r1_argerr(f, prefix::AbstractString)
	err = _r1_err(f)
	ok = err isa ArgumentError && startswith(err.msg, prefix)
	ok || @info "unexpected error" prefix err
	return ok
end

# Run `code` in a fresh Julia process of this project. Returns (finished,
# output, seconds); a process still running after `limit_s` is killed (it is
# the one started here, by its Process handle).
function _r1_subprocess(code::AbstractString; limit_s::Real = 240, threads::Int = 1)
	dir = mktempdir()
	script = joinpath(dir, "script.jl")
	write(script, code)
	out = joinpath(dir, "out.txt")
	cmd = `$(Base.julia_cmd()) --startup-file=no --threads=$(threads) --project=$(Base.active_project()) $(script)`
	t0 = time()
	proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out); wait = false)
	finished = timedwait(() -> process_exited(proc), Float64(limit_s); pollint = 0.5) === :ok
	if !finished
		kill(proc, Base.SIGKILL)
		wait(proc)
	end
	seconds = time() - t0
	text = isfile(out) ? read(out, String) : ""
	rm(dir; recursive = true, force = true)
	return (finished = finished, output = text, seconds = seconds, exitcode = proc.exitcode)
end

@testset "r1 tests-ci-06: the suite is many small top-level statements" begin
	# runtests.jl was one 5550-line @testset compiled as one thunk (52+
	# minutes of codegen before its first statement). Its testsets are now
	# core_suite.jl, ~150 statements (the largest, about 970 lines, lowers in
	# about 3 s), and runtests.jl `include`s every file inside the root set.
	path = joinpath(@__DIR__, "core_suite.jl")
	ex = Meta.parseall(read(path, String); filename = path)
	lines = [a.line for a in ex.args if a isa LineNumberNode]
	nlines = countlines(path)
	spans = diff(vcat(lines, nlines + 1))
	@test length(lines) > 50
	@test maximum(spans) < 1500
	runner = read(joinpath(@__DIR__, "runtests.jl"), String)
	@test countlines(joinpath(@__DIR__, "runtests.jl")) < 100
	# Test's internal testset stack (`push_testset`) is gone in Julia 1.13:
	# the runner uses only `@testset` and `include`, whose statements are
	# recorded in the enclosing set on every supported version.
	@test !occursin("push_testset", runner) && !occursin("pop_testset", runner)
	mktempdir() do dir
		inner = joinpath(dir, "inner.jl")
		write(inner, "using Test\n@testset \"inner a\" begin @test true end\n@testset \"inner b\" begin @test 1 + 1 == 2 end\n")
		outer = @testset "outer" begin
			include(inner)
		end
		@test [r.description for r in outer.results] == ["inner a", "inner b"]
	end
end

@testset "r1 mr-01: an interrupted renderer request cannot answer a later one" begin
	warm = savefig(plot_scatter([1.0, 2.0], [1.0, 2.0]); format = "png")
	@test length(warm) > 1000
	state = _R1._EXPORT_STATE
	app = state.app
	slow_js = "new Promise(function (r) { setTimeout(function () { r('slow'); }, 1500); })"
	run_js = isdefined(_R1, :_ec_run) ? _R1._ec_run :
		(ec, target, code) -> Base.invokelatest(() -> ec.run(target, code))
	slow = @async _R1._with_export_window(state) do ec, app, win, divid
		run_js(ec, win, slow_js)
	end
	@test timedwait(() -> islocked(app.comm_lock), 30.0) === :ok
	sleep(0.3)
	schedule(slow, InterruptException(); error = true)
	err = _r1_err(() -> fetch(slow))
	@test err isa TaskFailedException && err.task.exception isa InterruptException
	# Let the abandoned reply arrive first, so it is the next line on the
	# connection: the next request must still get its own reply.
	sleep(1.6)
	fast = _R1._with_export_window(state) do ec, app, win, divid
		run_js(ec, win, "'fast'")
	end
	@test fast == "fast"
	# And the next exports write the figures they are given.
	for k in 1:3
		marker = "R1MARKER$(k)"
		svg = String(savefig(plot_scatter(1:3, [3.0, 1.0, 2.0] .* k; title = marker); format = "svg"))
		@test occursin(marker, svg)
	end
	png = savefig(plot_scatter(1:3, [1.0, 2.0, 3.0]); format = "png")
	@test png[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
end

@testset "r1 mr-01: an export interrupted while it draws leaves no stale state" begin
	big = plot_scatter(collect(1.0:60_000.0), rand(60_000); mode = "markers")
	savefig(plot_scatter([1.0, 2.0], [2.0, 1.0]); format = "png")
	app = _R1._EXPORT_STATE.app
	task = @async savefig(big; format = "png")
	@test timedwait(() -> islocked(app.comm_lock), 60.0) === :ok
	sleep(0.4)
	istaskdone(task) || schedule(task, InterruptException(); error = true)
	_r1_err(() -> fetch(task))
	marker = "R1AFTERINTERRUPT"
	svg = String(savefig(plot_scatter(1:4, [1.0, 4.0, 2.0, 3.0]; title = marker); format = "svg"))
	@test occursin(marker, svg)
	@test !occursin("60000", svg)
	pdf = savefig(plot_scatter(1:3, [1.0, 2.0, 3.0]); format = "pdf")
	@test String(pdf[1:5]) == "%PDF-"
end

if isdefined(_R1, :_ec_native)
	@testset "r1 mr-01: a connection whose owed replies never arrive is given up" begin
		savefig(plot_scatter([1.0, 2.0], [1.0, 2.0]); format = "png")
		state = _R1._EXPORT_STATE
		app = state.app
		hung = @async _R1._with_export_window(state) do ec, app, win, divid
			_R1._ec_run(ec, win, "new Promise(function () {})")  # never settles
		end
		@test timedwait(() -> islocked(app.comm_lock), 30.0) === :ok
		sleep(0.3)
		schedule(hung, InterruptException(); error = true)
		_r1_err(() -> fetch(hung))
		@test _R1._ec_owed(app) == 1
		old = _R1._EC_SETTLE_TIMEOUT_S[]
		_R1._EC_SETTLE_TIMEOUT_S[] = 1.0
		try
			# A native command cannot run before the owed reply: the
			# connection is given up and the application shut down.
			err = _r1_err(() -> _R1._ec_native(() -> :ran, _R1._electroncall(), app; who = "savefig"))
			@test err isa ErrorException && startswith(err.msg, "savefig: the Electron connection was given up")
			@test _R1._ec_poisoned(app)
		finally
			_R1._EC_SETTLE_TIMEOUT_S[] = old
		end
		# The export state recovers with a fresh application.
		marker = "R1AFTERPOISON"
		svg = String(savefig(plot_scatter(1:3, [1.0, 3.0, 2.0]; title = marker); format = "svg"))
		@test occursin(marker, svg)
		@test _R1._EXPORT_STATE.app !== app
		@test !_R1._ec_poisoned(_R1._EXPORT_STATE.app)
		@test timedwait(() -> process_exited(app.proc), 30.0) === :ok
	end
end

@testset "r1 platform-deps-01: savefig fails within its timeout when Electron cannot start" begin
	code = """
	using PlotlySupply
	ec = PlotlySupply._electroncall()
	Core.eval(ec.Electron_jll, :(electron_path = "/usr/bin/false"))
	t = time()
	msg = try
		savefig(plot_scatter(1:3, [1, 4, 9]); format = "svg", timeout = 5)
		"no error"
	catch err
		sprint(showerror, err)
	end
	println("ELAPSED ", round(time() - t; digits = 1))
	println("MESSAGE ", msg)
	flush(stdout)
	exit(0)
	"""
	r = _r1_subprocess(code; limit_s = 240)
	@test r.finished
	m = match(r"ELAPSED ([0-9.]+)", r.output)
	@test m !== nothing && parse(Float64, m.captures[1]) < 30
	@test occursin("MESSAGE savefig: the Electron renderer did not start within 5.0 s", r.output)
	r.finished && @test r.exitcode == 0
end

@testset "r1 platform-deps-05: concurrent first use starts one Electron application" begin
	code = """
	using PlotlySupply
	const PS = PlotlySupply
	ec = PS._electroncall()
	apps = Vector{Any}(undef, 4)
	@sync for i in 1:4
		Threads.@spawn apps[i] = PS._default_electron_app(ec)
	end
	println("DISTINCT ", length(unique(objectid, apps)))
	println("STARTED ", length(ec._global_applications))
	flush(stdout)
	exit(0)
	"""
	r = _r1_subprocess(code; limit_s = 240, threads = 4)
	@test r.finished
	@test occursin("DISTINCT 1", r.output)
	@test occursin("STARTED 1", r.output)
end

@testset "r1 export-06: a renderer timeout is an ErrorException" begin
	err = _r1_err(() -> savefig(plot_scatter(1:3, [1.0, 2.0, 3.0]); format = "png", timeout = 0.001))
	@test err isa ErrorException
	@test occursin("timeout", lowercase(sprint(showerror, err)))
	@test !isempty(savefig(plot_scatter([1.0, 2.0], [1.0, 2.0]); format = "png"))
end

@testset "r1 apib-03/tests-ci-08: subplots rows/cols messages name the function" begin
	@test _r1_argerr(() -> subplots(0, 2; sync = false), "subplots: `rows` must be positive")
	@test _r1_argerr(() -> subplots(1, -2; sync = false), "subplots: `cols` must be positive")
end

@testset "r1 apib-02/sm-14: subplots and subplot! keyword errors are ArgumentErrors" begin
	@test _r1_argerr(() -> subplots(1, 2; sync = false, bogus = 1), "subplots: unsupported keyword")
	err = _r1_err(() -> subplots(1, 2; sync = false, sharex = true))
	@test err isa ArgumentError && occursin("shared_xaxes", err.msg)
	@test _r1_argerr(() -> subplots(1, 2; sync = false, legend_position = 3), "subplots:")
	@test _r1_argerr(() -> subplots(1, 2; sync = false, legend_inset = (0.1,)), "subplots:")
	@test _r1_argerr(() -> subplots(1, 2; sync = false, compress = 1), "subplots:")
	@test _r1_argerr(() -> subplots(1, 2; sync = false, window_title = 3), "subplots:")
	@test _r1_argerr(() -> subplots(1, 2; sync = false, show = 1), "subplots:")
	@test _r1_argerr(() -> subplots(1, 2; sync = 1), "subplots:")
	sf = subplots(2, 1; sync = false)
	@test _r1_argerr(() -> subplot!(sf, 2, 1; bogus = 1), "subplot!: unsupported keyword")
	@test _r1_argerr(() -> subplot!(sf, 2; bogus = 1), "subplot!: unsupported keyword")
	@test _r1_argerr(() -> subplot!(sf, 3), "subplot!: `index` must be in 1:2")
	# Valid calls still work.
	sf2 = subplots(1, 2; sync = false, legend_position = :bottom, legend_inset = (0.1, 0.9))
	@test sf2 isa SubplotFigure
end

@testset "r1 seams-07: specs spans that cover the same cell are rejected" begin
	specs = [missing Spec(rowspan = 2); Spec(colspan = 2) missing]
	err = _r1_err(() -> subplots(2, 2; sync = false, specs = specs))
	@test err isa ArgumentError
	@test startswith(err.msg, "subplots: the spans of")
	@test occursin("cover cell (2, 1)", err.msg) || occursin("cover cell (1, 1)", err.msg) ||
		occursin("cover cell", err.msg)
	# Disjoint spans are still accepted and give disjoint domains.
	ok = subplots(2, 2; sync = false, specs = [Spec(rowspan = 2) Spec(); missing Spec()])
	@test ok isa SubplotFigure
end

@testset "r1 apia-04: make_subplots is settled and its user errors are ArgumentErrors" begin
	p = make_subplots(rows = 2, cols = 2, shared_xaxes = true)
	before = json(p)
	@test !_R1._finalize_figure!(p)
	@test json(p) == before
	add_trace!(p, scatter(x = 1:3, y = [1, 3, 2]); row = 1, col = 1)
	@test !_R1._finalize_figure!(p)
	@test _r1_argerr(() -> make_subplots(rows = 0), "make_subplots: `rows` must be a positive integer")
	@test _r1_argerr(() -> make_subplots(cols = 0), "make_subplots: `cols` must be a positive integer")
	@test _r1_argerr(() -> make_subplots(rows = -2), "make_subplots:")
	@test _r1_argerr(() -> make_subplots(rows = 2, vertical_spacing = 2), "make_subplots:")
	@test _r1_argerr(() -> make_subplots(foo = 1), "make_subplots: unsupported keyword")
	@test _r1_argerr(() -> make_subplots(cols = 2, column_widths = [1.0]), "make_subplots:")
	q = make_subplots(rows = 1, cols = 2, column_widths = [0.3, 0.7])
	@test q.layout[:xaxis][:domain][2] < q.layout[:xaxis2][:domain][1]
end

@testset "r1 apia-05: mgrid takes one or more vectors" begin
	@test _r1_argerr(() -> mgrid(), "mgrid:")
	@test _r1_argerr(() -> mgrid([1 2; 3 4]), "mgrid:")
	@test _r1_argerr(() -> mgrid([1 2; 3 4], 1:2), "mgrid:")
	@test _r1_argerr(() -> mgrid(5), "mgrid:")
	a, b = mgrid(1:3, 1:2)
	@test size(a) == (3, 2) && a[:, 1] == 1:3 && b[1, :] == 1:2
end

@testset "r1 apia-12: json(fig, indent) is the null-safe figure JSON" begin
	p = plot_scatter(1:3, [1.0, NaN, 3.0])
	s = json(p, 2)
	@test occursin("null", s)
	@test s == json(p; pretty = 2)
	@test PlotlyBase.JSON.parse(s)["data"][1]["y"][2] === nothing
	sf = subplots(1, 2; sync = false)
	t = json(sf, 2)
	d = PlotlyBase.JSON.parse(t)
	@test haskey(d, "data") && haskey(d, "layout")
	@test !occursin("_lock", t)
	@test _r1_argerr(() -> json(p, -1), "json:")
end

@testset "r1 sm-12: inset! on a Plot names the function" begin
	@test _r1_argerr(() -> inset!(plot_scatter(1:3, 1:3), [0.5, 0.5, 0.3, 0.3]), "inset!: only a SubplotFigure has insets")
end

@testset "r1 export-02: a narrow PDF/EPS page does not depend on earlier math exports" begin
	small = plot_scatter(1:10, (1:10) .^ 2; xlabel = "x label", ylabel = "y label", legend = "data")
	kw = (width = 2.5, height = 2, units = :in)
	before = savefig(small; format = "pdf", kw...)
	mathfig = plot_scatter(1:10, sqrt.(1:10); xlabel = raw"$\omega t$ (rad)", ylabel = raw"$|E|^2$",
		title = raw"$E(\omega) = \int_0^\infty e^{-i\omega t}\, f(t)\, \mathrm{d}t + \sum_{n=1}^{N} a_n \cos(n \omega t)$")
	savefig(mathfig; format = "png")
	after = savefig(small; format = "pdf", kw...)
	# The drawing transform (the page content scale) is the same, so the whole
	# deterministic file is.
	@test after == before
end

# The raw text of a PDF (its dictionaries are plain text).
_r1_pdf_text(bytes::Vector{UInt8}) = String(copy(bytes))

@testset "r1 vm-pdfframe: PDF axis lines, ticks and grid keep their width and opacity" begin
	fig = with_style(() -> plot_scatter(collect(range(-2, 2; length = 81)), sin.(range(-2, 2; length = 81))), :ieee)
	pdf = _r1_pdf_text(savefig(fig; format = "pdf"))
	# Every stroke of this figure is opaque and at least 1 px (0.75 pt) wide:
	# no hairline (`/LW 0`) graphics state and no translucent stroke (`/CA` < 1).
	widths = [parse(Float64, m.captures[1]) for m in eachmatch(r"/LW ([0-9.]+)", pdf)]
	alphas = [parse(Float64, m.captures[1]) for m in eachmatch(r"/CA ([0-9.]+)", pdf)]
	@test !isempty(widths) && minimum(widths) >= 1 - 1e-6
	@test !isempty(alphas) && all(==(1.0), alphas)
end

@testset "r1 vm-pdfinterp: unsmoothed heatmap cells stay flat in PDF viewers" begin
	x = range(-2, 2; length = 21)
	Z = [exp(-(a^2 + b^2)) for a in x, b in x]
	fig = with_style(() -> plot_heatmap(x, x, Z; equalar = true, colorbar_title = "intensity"), :ieee)
	pdf = _r1_pdf_text(savefig(fig; format = "pdf"))
	dims = [(parse(Int, m.captures[1]), parse(Int, m.captures[2])) for m in
		eachmatch(r"/Subtype\s*/Image\s*/Width\s+(\d+)\s*/Height\s+(\d+)", pdf)]
	@test length(dims) == 1
	w, h = only(dims)
	# Whole-factor nearest-neighbour enlargement of the 21 x 21 cells to at
	# least 384 ppi, so no viewer can blur them.
	@test w % 21 == 0 && h % 21 == 0 && w >= 4 * 21 && h >= 4 * 21
	# A smoothed heatmap (drawn by plotly.js at the plot-area size, not
	# pixelated) is not enlarged.
	smooth = with_style(() -> plot_heatmap(x, x, Z; interpolation = :bilinear), :ieee)
	sdims = [(parse(Int, m.captures[1]), parse(Int, m.captures[2])) for m in
		eachmatch(r"/Subtype\s*/Image\s*/Width\s+(\d+)\s*/Height\s+(\d+)", _r1_pdf_text(savefig(smooth; format = "pdf")))]
	@test length(sdims) == 1 && only(sdims)[1] <= smooth.layout[:width]
end

@testset "r1 platform-deps-02/layout-fuzz-02: SVG export is deterministic and valid" begin
	other = plot_scatter(1:3, 1:3; title = raw"$|E| \cdot \Gamma$")
	fig = plot_scatter(1:10, sqrt.(1:10); xlabel = raw"$\omega t$ (rad)", ylabel = raw"$x^2$", legend = raw"$\alpha_1$")
	first = String(savefig(fig; format = "svg"))
	savefig(other; format = "svg")
	second = String(savefig(fig; format = "svg"))
	@test first == second
	# One glyph block, no duplicate ids, only glyphs this figure uses.
	@test length(collect(eachmatch(r"id=\"MathJax_SVG_glyphs\"", second))) == 1
	ids = [m.captures[1] for m in eachmatch(r"\sid=\"([^\"]+)\"", second)]
	@test allunique(ids)
	defined = Set(m.captures[1] for m in eachmatch(r"<path[^>]*\bid=\"([A-Z][-A-Z0-9]*)\"", second))
	used = Set(m.captures[1] for m in eachmatch(r"href=\"#([^\"]+)\"", second))
	@test !isempty(defined) && defined == intersect(used, defined) && issubset(filter(u -> occursin('-', u) && uppercase(u) == u, used), defined)
	# Every element below the root writes its attributes in name order.
	root_end = findfirst('>', second)
	for m in eachmatch(r"<[A-Za-z][-A-Za-z0-9_:.]*((?:\s+[A-Za-z_:][-A-Za-z0-9_:.]*=\"[^\"]*\")+)\s*/?>", second[(root_end + 1):end])
		names = [a.captures[1] for a in eachmatch(r"\s+([A-Za-z_:][-A-Za-z0-9_:.]*)=", m.captures[1])]
		issorted(names) || (@test issorted(names); break)
	end
	# The SVG draws the figure: decoded by the renderer, it matches the PNG.
	url = "data:image/svg+xml;base64," * base64encode(second)
	js = """
	(async function() {
	  const img = new Image();
	  await new Promise(function(res, rej) { img.onload = res; img.onerror = function() { rej(new Error('svg did not decode')); }; img.src = $(_R1._json_js(url)); });
	  const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
	  const ctx = c.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height);
	  ctx.drawImage(img, 0, 0, c.width, c.height);
	  return c.toDataURL('image/png');
	})()
	"""
	png_url = _R1._with_export_window(_R1._EXPORT_STATE) do ec, app, win, divid
		_R1._ec_run(ec, win, js)
	end
	drawn = base64decode(split(png_url, ",")[2])
	reference = savefig(fig; format = "png", scale = 1)
	w1, h1, c1, p1 = _R1._png_decode(drawn)
	w2, h2, c2, p2 = _R1._png_decode(reference)
	@test (w1, h1) == (w2, h2)
	if (w1, h1, c1) == (w2, h2, c2)
		d = abs.(Int.(p1) .- Int.(p2))
		@test count(>(32), d) <= 0.002 * length(d)
	end
end

@testset "r1 export-01: html and json ignore the size keywords" begin
	x = range(-2, 2; length = 41); y = range(-1, 1; length = 21)
	field = plot_heatmap(x, y, [sin(a) * cos(b) for a in x, b in y]; equalar = true, colorbar_title = "f")
	surf = plot_surface(x, y, [a * b for a in x, b in y])
	for fig in (field, surf), fmt in ("json", "html")
		plain = savefig(fig; format = fmt)
		@test savefig(fig; format = fmt, width = 300, height = 600) == plain
		@test savefig(fig; format = fmt, width = 3.5, height = 2.5, units = :in, dpi = 600, tight = false) == plain
	end
	# Several files in one call: the document is the figure at its own size,
	# the PDF has the requested page.
	dir = mktempdir()
	try
		savefig(field, [joinpath(dir, "f.pdf"), joinpath(dir, "f.json")]; width = 3.5, height = 2.5, units = :in)
		@test read(joinpath(dir, "f.json")) == savefig(field; format = "json")
		box = match(r"/MediaBox\s*\[\s*([-0-9.]+)\s+([-0-9.]+)\s+([-0-9.]+)\s+([-0-9.]+)", String(read(joinpath(dir, "f.pdf"))))
		@test box !== nothing && isapprox(parse(Float64, box[3]) - parse(Float64, box[1]), 252; atol = 0.01)
	finally
		rm(dir; recursive = true, force = true)
	end
	# The figure itself is not changed by any of it.
	@test !_R1._finalize_figure!(field)
end

if Sys.isunix()
	@testset "r1 mr-02: an interrupted EPS export stops its Ghostscript child" begin
		savefig(plot_scatter([1.0, 2.0], [1.0, 2.0]); format = "png")
		dir = mktempdir()
		record = joinpath(dir, "record.txt")
		fake = joinpath(dir, "gs")
		write(fake, """
		#!/bin/sh
		echo "\$\$" > "$(record)"
		exec sleep 30
		""")
		chmod(fake, 0o755)
		old_path = ENV["PATH"]
		ENV["PATH"] = dir * ":" * old_path
		try
			task = @async savefig(plot_scatter(1:10, 1:10); format = "eps")
			@test timedwait(() -> isfile(record) && !isempty(read(record, String)), 120.0) === :ok
			pid = parse(Int, strip(read(record, String)))
			alive() = success(pipeline(`kill -0 $pid`; stdout = devnull, stderr = devnull))
			@test alive()
			schedule(task, InterruptException(); error = true)
			err = _r1_err(() -> fetch(task))
			@test err isa TaskFailedException && err.task.exception isa InterruptException
			# The child was stopped and reaped before savefig returned.
			@test !alive()
		finally
			ENV["PATH"] = old_path
			rm(dir; recursive = true, force = true)
		end
	end
end

@testset "r1 platform-deps-04: a render asset removed by a temp cleaner is rebuilt" begin
	parent = mktempdir()
	try
		state = _R1._PlotlyJSCompatAssetState()
		path = _R1._plotlyjs_render_asset_path(; state, cache_parent = parent)
		@test isfile(path)
		rm(dirname(path); recursive = true)          # what a temp cleaner does
		rebuilt = _R1._plotlyjs_render_asset_path(; state, cache_parent = parent)
		@test isfile(rebuilt) && rebuilt != path
		@test _R1._plotlyjs_file_digest(rebuilt) == state.asset.digest
		@test isfile(joinpath(dirname(rebuilt), "LICENSE"))
		# A changed (not missing) asset still fails closed.
		write(rebuilt, "changed")
		@test_throws ErrorException _R1._plotlyjs_render_asset_path(; state, cache_parent = parent)
		_R1._cleanup_plotlyjs_compat_asset!(state)
	finally
		rm(parent; recursive = true, force = true)
	end
	# The session's own asset: removed, then a new export window and an HTML
	# page still work.
	global_path = _R1._plotlyjs_render_asset_path()
	rm(dirname(global_path); recursive = true)
	html = String(savefig(plot_scatter(1:3, 1:3); format = "html"))
	@test occursin("Plotly", html)
	lock(() -> _R1._retire_export_window_locked!(_R1._EXPORT_STATE; throw_errors = true), _R1._EXPORT_STATE.lock)
	svg = String(savefig(plot_scatter(1:3, [3, 1, 2]; title = "AFTERCLEAN"); format = "svg"))
	@test occursin("AFTERCLEAN", svg)
	@test isfile(_R1._plotlyjs_render_asset_path())
end

@testset "r1 errors-inputs-09: a bad trace index is an ArgumentError naming the verb" begin
	fig = plot_scatter(1:3, [1.0, 2.0, 3.0])
	before = json(fig)
	@test _r1_argerr(() -> restyle!(fig, 0; opacity = 0.5), "restyle!: trace index 0 is out of range 1:1")
	@test _r1_argerr(() -> restyle!(fig, 5; opacity = 0.5), "restyle!: trace index 5 is out of range 1:1")
	@test _r1_argerr(() -> update!(fig, 0; opacity = 0.5), "update!: trace index 0")
	@test _r1_argerr(() -> deletetraces!(fig, 5), "deletetraces!: trace index 5")
	@test _r1_argerr(() -> movetraces!(fig, 0, 1), "movetraces!: trace index 0")
	@test _r1_argerr(() -> addtraces!(fig, 0, scatter(y = [1])), "addtraces!: trace index 0 is out of range 1:2")
	@test _r1_argerr(() -> extendtraces!(fig, Dict(:y => [[1.0]]), [5]), "extendtraces!: trace index 5")
	@test _r1_argerr(() -> prependtraces!(fig, Dict(:y => [[1.0]]), [5]), "prependtraces!: trace index 5")
	@test json(fig) == before
end

@testset "r1 tests-ci-08/errors-inputs-08: splice and default-setter messages name the function" begin
	fig = plot_scatter(1:3, [1.0, 2.0, 3.0])
	@test _r1_argerr(() -> extendtraces!(fig, Dict(:y => [[5.0], [6.0]]), [1, 1]), "extendtraces!: `indices` must not contain duplicates")
	@test _r1_argerr(() -> extendtraces!(fig, Dict(:y => [[5.0], [6.0]]), [1]), "extendtraces!: update attribute :y must contain one vector per trace index")
	@test _r1_argerr(() -> prependtraces!(fig, Dict(:a => 1), [1]), "prependtraces!: update attribute :a must be a vector")
	@test _r1_argerr(() -> extendtraces!(fig, Dict(:y => [[5.0]]), [1], Dict(:x => [1])), "extendtraces!: `maxpoints` must contain an entry")
	old = get_default_legend_position()
	try
		@test _r1_argerr(() -> set_default_legend_position!(3), "set_default_legend_position!: the position must be a Symbol")
		@test _r1_argerr(() -> set_default_legend_position!(nothing), "set_default_legend_position!:")
		@test get_default_legend_position() == old
	finally
		set_default_legend_position!(old)
	end
end

@testset "r1 sm-14: add_recession_bands! style keywords style the bands; others are ArgumentErrors" begin
	dates = [PlotlySupply.Dates.Date(2006, 1, 1), PlotlySupply.Dates.Date(2010, 6, 1)]
	fig = plot_scatter(dates, [1.0, 2.0])
	before = json(fig)
	@test _r1_argerr(() -> add_recession_bands!(fig; colr = "red"), "add_recession_bands!: `colr` is not a shape attribute")
	@test _r1_argerr(() -> add_recession_bands!(fig; x0 = 1), "add_recession_bands!: `x0` is set by the recession table")
	@test json(fig) == before
	# Before: every override (documented: "attributes override the band
	# style") was a MethodError from PlotlyBase's attr splice.
	shapes = add_recession_bands!(fig; fillcolor = "red", opacity = 0.2, line_color = "blue")
	@test length(shapes) == 1     # the 2007-2009 recession
	band = shapes[1]
	@test band[:fillcolor] == "red" && band[:opacity] == 0.2 && band[:layer] == "below"
	@test band[:line][:color] == "blue" && band[:line][:width] == 0
	# PlotlyBase's recession table: 2008-01 to 2009-07 for this span.
	@test band[:xref] == "x" && band[:x0] == PlotlySupply.Dates.Date(2008, 1, 1) && band[:x1] == PlotlySupply.Dates.Date(2009, 7, 1)
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, dates, [1.0, 2.0]; row = 1, col = 2)
	before = json(sf.plot)
	@test _r1_argerr(() -> add_recession_bands!(sf; row = 1, col = 2, bogus = 1), "add_recession_bands!: `bogus` is not a shape attribute")
	@test json(sf.plot) == before
	@test add_recession_bands!(sf; row = 1, col = 2, fillcolor = "green") === sf
	@test sf.plot.layout[:shapes][end][:fillcolor] == "green"
	@test sf.plot.layout[:shapes][end][:xref] == "x2"
end

@testset "r1 errors-inputs-08: a value that is no figure, scatter3d series, kde range" begin
	x = [1.0, 2.0, 3.0]
	notfig = "the first argument must be the figure (a Plot, SyncPlot or SubplotFigure); got a value of type"
	for (who, call) in (
		("xlabel!", v -> xlabel!(v, "x")),
		("title!", v -> title!(v, "T")),
		("plot_scatter!", v -> plot_scatter!(v, x, x)),
		("plot_heatmap!", v -> plot_heatmap!(v, [1.0 2.0; 3.0 4.0])),
		("annotate!", v -> annotate!(v, 1, 1, "a")),
		("hline!", v -> hline!(v, 0.5)),
		("figsize!", v -> figsize!(v, :ieee)),
		("plot_surface!", v -> plot_surface!(v, x, x, x * x')),
		("colorbar!", v -> colorbar!(v)),
		("set_fonts!", v -> set_fonts!(v; size = 10)),
		("set_legend!", v -> set_legend!(v; position = :top)),
		("shared_colorbar!", v -> shared_colorbar!(v)),
	), value in (nothing, 1, "fig", PlotlyBase.Layout(), PlotlyBase.scatter(y = [1]), Dict(:a => 1), [1, 2])
		@test _r1_argerr(() -> call(value), "$(who): $(notfig) $(typeof(value)).")
	end
	@test _r1_argerr(() -> subplot!(nothing, 1, 1), "subplot!: the first argument must be a SubplotFigure")
	@test _r1_argerr(() -> subplot_legends!(1), "subplot_legends!: the first argument must be a SubplotFigure")
	# The figure forms still work.
	fig = plot_scatter(x, x)
	@test xlabel!(fig, "x") === nothing
	@test fig.layout[:xaxis][:title][:text] == "x"
	@test _r1_argerr(() -> plot_scatter3d([x, x], [x, x], x), "plot_scatter3d: `x` contains multiple series but `z` contains one series.")
	@test _r1_argerr(() -> plot_scatter3d(x, [x, x], x), "plot_scatter3d: `y` contains multiple series but `z` contains one series.")
	@test _r1_argerr(() -> plot_kde([1e308, -1e308, 0.0]), "plot_kde: the curve of `x` would span")
	@test plot_kde([1.0, 2.0, 2.5]) isa PlotlyBase.Plot
end

@testset "r1 apib-02/sm-14: unknown keywords of the text and legend verbs and the setters" begin
	fig = plot_scatter(1:3, [1.0, 2.0, 3.0]; legend = "a")
	sf = subplots(1, 2; sync = false)
	before = json(fig)
	@test _r1_argerr(() -> title!(fig, "T"; fontsiz = 9), "title!: unsupported keyword argument(s) `fontsiz`")
	@test _r1_argerr(() -> title!(sf, "T"; row = 1, col = 1, inset = 1), "title!: unsupported keyword argument(s) `inset`")
	@test _r1_argerr(() -> set_legend!(fig; positon = :top), "set_legend!: unsupported keyword argument(s) `positon`")
	@test _r1_argerr(() -> set_legend!(sf; positon = :top), "set_legend!: unsupported keyword")
	@test _r1_argerr(() -> subplot_legends!(sf; positon = :top), "subplot_legends!: unsupported keyword")
	@test _r1_argerr(() -> panel_labels!(sf; styel = :paren), "panel_labels!: unsupported keyword")
	@test _r1_argerr(() -> legend_entry!(fig, "x"; colr = "red"), "legend_entry!: unsupported keyword argument(s) `colr`")
	@test _r1_argerr(() -> set_default_mathtext!(; bogus = 1), "set_default_mathtext!: unsupported keyword")
	@test _r1_argerr(() -> set_default_template!(:plotly_white; bogus = 1), "set_default_template!: unsupported keyword")
	@test _r1_argerr(() -> register_style!(:r1_never_registered, PlotStyle(); bogus = 1), "register_style!: unsupported keyword")
	@test json(fig) == before
	# The messages never name an internal type.
	err = _r1_err(() -> title!(fig, "T"; fontsiz = 9))
	@test !occursin("Staged", sprint(showerror, err))
	# Valid keywords still work.
	title!(fig, "T"; fontsize = 12)
	@test fig.layout[:title][:text] == "T"
end

@testset "r1 apib-02: legend_entry! on a SubplotFigure rejects an unknown keyword" begin
	sf = subplots(1, 2; sync = false)
	before = json(sf.plot)
	@test _r1_argerr(() -> legend_entry!(sf, "x"; colr = "red"), "legend_entry!: unsupported keyword argument(s) `colr`")
	@test json(sf.plot) == before
	legend_entry!(sf, "x"; color = "red", row = 1, col = 2)
	@test sf.plot.data[end][:name] == "x"
end

@testset "r1 errors-inputs-05: unknown keywords of the compat verbs, savejson and to_syncplot" begin
	p = plot_scatter(1:3, [1.0, 2.0, 3.0])
	addtraces!(p, PlotlyBase.scatter(x = [1, 2], y = [2.0, 1.0]))
	before = json(p)
	tr = PlotlyBase.scatter(x = [1], y = [1.0])
	upd = Dict(:y => [[4.0]])
	path = joinpath(mktempdir(), "r1.json")
	# A SyncPlot without a window: the keyword check comes before any use of it.
	sp = SyncPlot(deepcopy(p), nothing, nothing, "r1-no-window")
	for target in (p, sp)
		@test _r1_argerr(() -> purge!(target; bogus = 1), "purge!: unsupported keyword argument(s) `bogus`; it takes no keyword arguments.")
		@test _r1_argerr(() -> redraw!(target; bogus = 1), "redraw!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> react!(target, copy(p.data), p.layout; bogus = 1), "react!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> addtraces!(target, tr; bogus = 1), "addtraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> addtraces!(target, 1, tr; bogus = 1), "addtraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> deletetraces!(target, 1; bogus = 1), "deletetraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> movetraces!(target, 1; bogus = 1), "movetraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> movetraces!(target, [1], [2]; bogus = 1), "movetraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> extendtraces!(target, upd, [1]; bogus = 1), "extendtraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> extendtraces!(target, upd, 1; bogus = 1), "extendtraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> prependtraces!(target, upd, [1]; bogus = 1), "prependtraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> prependtraces!(target, upd, 1; bogus = 1), "prependtraces!: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> savejson(target, path; bogus = 1), "savejson: unsupported keyword argument(s) `bogus`")
		@test _r1_argerr(() -> add_trace!(target, tr; colum = 1), "add_trace!: unsupported keyword argument(s) `colum`; it takes `row`, `col`, `secondary_y`.")
		@test _r1_argerr(() -> to_syncplot(target; widht = 10), "to_syncplot: unsupported keyword argument(s) `widht`; it takes `app`, `width`")
	end
	@test json(p) == before
	@test json(sp.plot) == before
	@test !isfile(path)
	# Valid calls still work.
	@test add_trace!(p, tr; row = 1, col = 1) === p
	@test length(p.data) == 3
	@test extendtraces!(p, upd, [3]) === p
	@test p.data[3][:y] == [1.0, 4.0]
	@test movetraces!(p, 1) === p
	@test deletetraces!(p, 3) === p
	@test length(p.data) == 2
	@test savejson(p, path) === p
	@test isfile(path)
	# The text and colour utilities.
	@test _r1_argerr(() -> mathtext("a"; bogus = 1), "mathtext: unsupported keyword argument(s) `bogus`; it takes `align`, `size`.")
	@test _r1_argerr(() -> colormap_colors("viridis", 3; bogus = 1), "colormap_colors: unsupported keyword argument(s) `bogus`; it takes `reverse`, `range`.")
	@test _r1_argerr(() -> discrete_colormap(["#000000", "#ffffff"]; bogus = 1), "discrete_colormap: unsupported keyword argument(s) `bogus`; it takes no keyword arguments.")
	@test _r1_argerr(() -> lighten("#000000", 0.5; bogus = 1), "lighten: unsupported keyword argument(s) `bogus`; it takes no keyword arguments.")
	@test _r1_argerr(() -> log_ticks(1, 100; bogus = 1), "log_ticks: unsupported keyword argument(s) `bogus`; it takes `subs`, `base`.")
	@test lighten("#000000", 0.5) == "#808080"
	@test log_ticks(4, 32; base = 2) == [4.0, 8.0, 16.0, 32.0]
	@test length(colormap_colors("viridis", 3; reverse = true)) == 3
	@test mathtext("a"; align = :l) isa String
end

@testset "r1 O16: text/html display of a figure with NaN, add_trace! into a cell of another kind" begin
	JSON = PlotlyBase.JSON
	p = plot_scatter(1:3, [1.0, NaN, Inf]; title = "gap")
	before = json(p)
	html = sprint(show, MIME"text/html"(), p)
	m = match(r"Plotly\.newPlot\(\s*'[^']+',\s*(\[.*?\]),\n", html)
	@test m !== nothing
	data = JSON.parse(m.captures[1])
	# The page holds the figure JSON `json(fig)` describes: non-finite as null.
	@test data[1]["y"] == [1.0, nothing, nothing]
	@test data == JSON.parse(before)["data"]
	@test occursin(string(p.divid), html)
	@test json(p) == before
	h = sprint(show, MIME"text/html"(), plot_heatmap([1.0 NaN; 2.0 3.0]))
	z = JSON.parse(match(r"Plotly\.newPlot\(\s*'[^']+',\s*(\[.*?\]),\n", h).captures[1])[1]["z"]
	@test any(row -> any(isnothing, row), z)

	fig = make_subplots(rows = 1, cols = 2, specs = [Spec(kind = "polar") Spec(kind = "xy")])
	snapshot = json(fig)
	err = _r1_err(() -> add_trace!(fig, scatter(x = 1:3, y = [1, 3, 2]); row = 1, col = 1))
	@test err isa ArgumentError
	@test startswith(err.msg, "add_trace!: a scatter trace is drawn in a \"xy\" subplot, but cell (1, 1) is \"polar\"")
	@test json(fig) == snapshot
	add_trace!(fig, scatterpolar(r = [1, 2, 3], theta = [0, 90, 180]); row = 1, col = 1)
	add_trace!(fig, scatter(x = 1:3, y = [1, 3, 2]); row = 1, col = 2)
	@test [t[:type] for t in fig.data] == ["scatterpolar", "scatter"]
	@test get(fig.data[1].fields, :subplot, "polar") == "polar"
	# A plain figure takes any trace, as plotly places it itself.
	q = Plot(scatter(y = [1, 2]))
	add_trace!(q, scatterpolar(r = [1, 2], theta = [0, 90]))
	@test length(q.data) == 2
end

@testset "r1 threed-live-06: a failed live figsize! of a 3-D figure leaves the model unchanged" begin
	JSON = PlotlyBase.JSON
	run_js(sp, code) = Base.invokelatest(() -> _R1._syncplot_backend(sp).run(sp.window, code))
	sabotage = """(() => { window.__r1_saved = {relayout: Plotly.relayout, restyle: Plotly.restyle, react: Plotly.react, addTraces: Plotly.addTraces, update: Plotly.update};
	  for (const k of Object.keys(window.__r1_saved)) Plotly[k] = function() { return Promise.reject(new Error('injected ' + k)); }; return 'ok'; })()"""
	restore = """(() => { for (const k of Object.keys(window.__r1_saved)) Plotly[k] = window.__r1_saved[k]; return 'ok'; })()"""
	xs = range(-2, 2; length = 21); ys = range(-1, 1; length = 11)
	G = [exp(-x^2 - 4y^2) for x in xs, y in ys]
	sp = to_syncplot(plot_surface(xs, ys, G; xlabel = "x", ylabel = "y", zlabel = "z"); show = false)
	try
		before = JSON.parse(json(sp.plot))
		meta_before = deepcopy(sp.plot.layout.fields[:meta])
		run_js(sp, sabotage)
		failed = _r1_err(() -> figsize!(sp, 400, 300))
		run_js(sp, restore)
		@test failed !== nothing
		@test JSON.parse(json(sp.plot)) == before
		@test isequal(sp.plot.layout.fields[:meta], meta_before)
		@test !haskey(sp.plot.layout.fields[:meta], Symbol("plotlysupply:size"))
		# The same call with a working renderer commits the size, its mark
		# and the 3-D label pads, and the window gets the same record.
		figsize!(sp, 400, 300)
		meta = sp.plot.layout.fields[:meta]
		@test sp.plot.layout[:width] == 400
		@test meta[Symbol("plotlysupply:size")] == "user"
		window = JSON.parse(String(run_js(sp, "JSON.stringify(document.getElementById($(repr(string(sp.divid)))).layout.meta)")))
		@test window["plotlysupply:size"] == "user"
		@test window["plotlysupply:gl3d"]["scene"] == meta[Symbol("plotlysupply:gl3d")][:scene]
	finally
		close(sp)
	end
end

@testset "r1 S-api-export-2: 3-D label pads keep the user's aliases into layout.meta" begin
	sf = subplots(1, 1; sync = false, show = false, per_subplot_legends = false,
		specs = fill(Spec(kind = "scene"), 1, 1))
	fields(x) = x isa AbstractDict ? x : x.fields
	scene = sf.layout.fields[:scene]
	font = attr(color = "red")
	title = attr(); fields(title)[:text] = "old"; fields(title)[:font] = font
	xaxis = attr(); fields(xaxis)[:title] = title; fields(scene)[:xaxis] = xaxis
	sf.layout.fields[:meta] = Dict{Symbol, Any}(:font => font, :xaxis => xaxis)
	plot_surface!(sf, [1.0 2.0; 3.0 4.0]; xlabel = "surface-x", shared_coloraxis = true)
	holder = sf.layout.fields[:meta]
	committed = fields(fields(fields(sf.layout.fields[:scene])[:xaxis])[:title])
	@test haskey(holder, Symbol("plotlysupply:gl3d"))
	@test committed[:text] == "surface-x"
	@test committed[:font] === holder[:font]
	@test committed[:font] === font
	@test fields(sf.layout.fields[:scene])[:xaxis] === holder[:xaxis]
end

@testset "r1 tests-ci-07: registries a test file extends are restored after it" begin
	snapshot = _global_registries_snapshot()
	cmap = PlotlySupply.COLORMAPS["viridis"]
	try
		PlotlySupply.COLORMAPS["r1_ice"] = ["#000000", "#ffffff"]
		push!(PlotlySupply.COLORMAPS["viridis"], "#000000")   # changed in place
		register_style!(:r1_registry_style, PlotStyle())
		@test Set(_global_registries_diff(snapshot, _global_registries_snapshot())) == Set([:colormaps, :styles])
	finally
		_global_registries_restore!(snapshot)
	end
	@test _global_registries_diff(snapshot, _global_registries_snapshot()) == Symbol[]
	@test !haskey(PlotlySupply.COLORMAPS, "r1_ice")
	@test PlotlySupply.COLORMAPS["viridis"] == snapshot.colormaps["viridis"]
	@test !haskey(PlotlySupply._STYLE_REGISTRY, :r1_registry_style)
end

@testset "r1 apib-05: sunburst/treemap hierarchies plotly cannot draw are ArgumentErrors" begin
	for (ctor, mut, who) in ((plot_sunburst, plot_sunburst!, "plot_sunburst"), (plot_treemap, plot_treemap!, "plot_treemap"))
		@test _r1_argerr(() -> ctor(["r", "a", "b"], ["", "q", "r"]),
			"$(who): `parents[2]` is \"q\", which is not one of the labels")
		@test _r1_argerr(() -> ctor(["r", "a"], ["", "r"]; values = [1, 5], branchvalues = "total"),
			"$(who): with `branchvalues = \"total\"` the value of \"r\" (1) must be at least the sum of its children (5.0)")
		# With ids, a parent names an id, not a label.
		@test _r1_argerr(() -> ctor(["r", "a"], ["", "r"]; ids = ["x", "y"]),
			"$(who): `parents[2]` is \"r\", which is not one of the ids")
		@test ctor(["r", "a"], ["", "x"]; ids = ["x", "y"]) isa Plot
		# Valid trees: equal totals, remainder values above their parents, ids.
		@test ctor(["r", "a", "b"], ["", "r", "r"]; values = [2, 1, 1], branchvalues = "total") isa Plot
		@test ctor(["r", "a"], ["", "r"]; values = [1, 5]) isa Plot
		@test ctor(["r", "a", "a"], ["", "r1", "r1"]; ids = ["r1", "a1", "a2"]) isa Plot
		@test ctor(["r", "a"], ["", 1]; ids = [1.0, 2.0]) isa Plot   # plotly reads both as "1"
		# plotly's own rule (render probe apib05b): without a "" root, the one
		# parent that names no sector becomes the root; two such parents, a
		# cycle, or no root at all draw nothing.
		@test ctor(["a", "b"], ["q", "q"]) isa Plot
		@test ctor(1:5, 0:4) isa Plot
		@test ctor(["a", "b", "c"], ["", "", "a"]) isa Plot
		@test _r1_argerr(() -> ctor(["a", "b"], ["q", "r"]),
			"$(who): `parents` names \"q\" and \"r\", which are not among the labels")
		@test _r1_argerr(() -> ctor(["r", "a", "b"], ["", "b", "a"]),
			"$(who): the sector \"a\" is its own ancestor")
		@test _r1_argerr(() -> ctor(["a", "b"], ["", "b"]), "$(who): the sector \"b\" is its own ancestor")
		@test _r1_argerr(() -> ctor(1:3, 1:3), "$(who): no sector is a root")
		@test _r1_argerr(() -> ctor(Any[2, "2"], ["", ""]),
			"$(who): `labels` contains 2 and \"2\", which plotly reads as the same name")
		fig = ctor(["r", "a"], ["", "r"])
		before = json(fig)
		@test _r1_argerr(() -> mut(fig, ["s", "c"], ["", "nope"]), "$(who)!: `parents[2]`")
		@test json(fig) == before
	end
end

@testset "r1 apia-07: colour strings that are no colour are ArgumentErrors" begin
	sf = subplots(1, 1; sync = false)
	plot_scatter!(sf, 1:5, [1.0, 3, 2, 4, 3])
	before = json(sf.plot)
	@test _r1_argerr(() -> inset!(sf, (0.5, 0.5, 0.4, 0.4); background = "nocolor"), "inset!: `background`")
	@test json(sf.plot) == before
	inset!(sf, (0.5, 0.5, 0.4, 0.4); background = "white")
	pie = plot_pie([1])
	snapshot = json(pie)
	@test _r1_argerr(() -> plot_pie!(pie, [2]; colors = ["nocolor"]), "plot_pie!: `colors[1]`")
	@test json(pie) == snapshot
	funnel = plot_funnelarea([1])
	@test _r1_argerr(() -> plot_funnelarea!(funnel, [2]; colors = ["nocolor"]), "plot_funnelarea!: `colors[1]`")
	pc = plot_parcoords(["a" => [1, 2]])
	@test _r1_argerr(() -> plot_parcoords!(pc, ["a" => [1, 2]]; line_color = "nocolor"), "plot_parcoords!: `line_color`")
	# Valid spellings still pass and are written unchanged.
	@test plot_pie([1, 2]; colors = ["red", "#00ff00"]).data[1][:marker][:colors] == ["red", "#00ff00"]
	@test plot_parcoords(["a" => [1, 2]]; line_color = "teal").data[1][:line][:color] == "teal"
	legend_entry!(plot_scatter(1:2, 1:2), "open"; mode = "markers", marker_color = "none")
end

@testset "r1 numerics-06: a histogram bin count beyond what a figure shows is an ArgumentError" begin
	t = @elapsed err = _r1_err(() -> plot_histogram([0.5]; bins = (0, 1, 1e-12)))
	@test err isa ArgumentError && startswith(err.msg, "plot_histogram: `bins` (0, 1, 1.0e-12) declares 1.0e12 bins; at most 100000")
	@test t < 5
	@test plot_histogram([0.5]; bins = (0, 1, 1e-5)) isa Plot   # 100 000 bins: the bound itself
	@test _r1_argerr(() -> plot_histogram([0.5]; bins = (0, 1, 9.9e-6)), "plot_histogram: `bins`")
end

@testset "r1 errors-inputs-13: geo/map scatter modes, geo scope and projection, bar base" begin
	lon, lat = [0.0, 10.0], [0.0, 10.0]
	@test _r1_argerr(() -> plot_scattergeo(lon, lat; mode = "zzqq"), "plot_scattergeo: `mode` must combine")
	@test _r1_argerr(() -> plot_scattermap(lon, lat; mode = "zzqq"), "plot_scattermap: `mode` must combine")
	@test _r1_argerr(() -> plot_scattermapbox(lon, lat; mode = "zzqq"), "plot_scattermapbox: `mode` must combine")
	@test _r1_argerr(() -> plot_scattergeo(lon, lat; projection = "zzqq"), "plot_scattergeo: `projection` must be one of")
	@test _r1_argerr(() -> plot_scattergeo(lon, lat; scope = "zzqq"), "plot_scattergeo: `scope` must be one of")
	@test _r1_argerr(() -> plot_choropleth(["USA"], [1.0]; scope = "mars"), "plot_choropleth: `scope`")
	g = plot_scattergeo(lon, lat; mode = "lines+markers", projection = "natural earth", scope = "europe")
	snapshot = json(g)
	@test _r1_argerr(() -> plot_scattergeo!(g, lon, lat; projection = "zzqq"), "plot_scattergeo!: `projection`")
	@test json(g) == snapshot
	@test g.data[1][:mode] == "lines+markers"
	@test g.layout[:geo][:projection][:type] == "natural earth"
	@test _r1_argerr(() -> plot_bar(["a", "b"], [1, 2]; base = "zzqq"), "plot_bar: `base` entries must be finite numbers")
	@test _r1_argerr(() -> plot_bar(["a", "b"], [1, 2]; base = "NaN"), "plot_bar: `base`")
	@test plot_bar(["a", "b"], [1, 2]; base = "2020-01-02").data[1][:base] == "2020-01-02"
	@test plot_bar(["a", "b"], [1, 2]; base = ["1.5", "2020-01-02 03:04"]).data[1][:base] == ["1.5", "2020-01-02 03:04"]
end

@testset "r1 seams-08: heatmap/contour coordinates follow the scatter rules" begin
	Z = [1.0 2 3; 4 5 6; 7 8 9; 10 11 12]
	Time = _R1.Dates.Time; Second = _R1.Dates.Second; Minute = _R1.Dates.Minute
	@test _r1_argerr(() -> plot_heatmap([Time(1), Time(2), Time(4), Time(8)], 1:3, Z), "plot_heatmap: `x` holds Time values")
	@test _r1_argerr(() -> plot_heatmap(Second.([1, 2, 4, 8]), 1:3, Z), "plot_heatmap: `x` holds Second values")
	@test _r1_argerr(() -> plot_contour(1:4, Minute.([1, 5, 10]), Z), "plot_contour: `y` holds Minute values")
	@test _r1_argerr(() -> plot_heatmap(Any[3.0, 1, 2, 4], 1:3, Z), "plot_heatmap: `x` must be strictly monotonic")
	@test _r1_argerr(() -> plot_heatmap(["a", "a", "b", "c"], 1:3, Z), "plot_heatmap: `x` repeats the category \"a\"")
	@test plot_heatmap(Any[1, 2.5, 3, 4], 1:3, Z) isa Plot
	@test plot_heatmap(["a", "b", "c", "d"], 1:3, Z) isa Plot
	@test plot_heatmap(_R1.Dates.Date(2020, 1, 1) .+ _R1.Dates.Day.(0:3), 1:3, Z) isa Plot
end

@testset "r1 mr-04/mr-07: field exports send customdata as typed arrays; pcolormesh keeps C" begin
	U = [1.0 + i + j for i in 1:300, j in 1:300]   # 90 000 values, above the typed-array minimum
	hm = plot_heatmap(U; colornorm = :log)
	@test hm.data[1][:customdata] isa AbstractMatrix
	prepared = _R1._prepare_renderer_export(hm, NamedTuple())
	@test occursin("\"customdata\":{\"bdata\":", prepared.data_js) || occursin("\"customdata\":{\"dtype\":\"f8\"", prepared.data_js)
	@test sizeof(prepared.data_js) < 3 * 8 * length(U)   # two typed arrays (z, customdata), not JSON text
	# pcolormesh on a rectilinear grid: one heatmap trace that references C.
	edges = collect(0.0:300.0)
	C = [sin(i / 7) * cos(j / 5) for i in 1:300, j in 1:300]
	C[3, 4] = NaN
	fig = plot_pcolormesh(edges, edges, C)
	# One copy of C (the validated cell values) plus a size-independent
	# overhead, not the Union{Nothing, Float64} rows on top of it (measured
	# 9.3 MB here; the rows alone were another 9 MB).
	big_edges = collect(0.0:1000.0)
	B = [sin(i / 7) * cos(j / 5) for i in 1:1000, j in 1:1000]
	alloc = @allocated plot_pcolormesh(big_edges, big_edges, B)
	@test alloc < 1.5 * sizeof(B)
	z = fig.data[1][:z]
	@test z isa AbstractMatrix{Float64} && isequal(z, C)
	@test C[3, 4] !== nothing && isnan(C[3, 4])   # the user's matrix is not written
	rows = PlotlyBase.JSON.parse(json(fig))["data"][1]["z"]
	@test rows[4][3] === nothing && rows[5][2] == C[2, 5]   # row j of plotly's z is C[:, j]
	L = abs.(C) .+ 0.1
	log_fig = plot_pcolormesh(edges, edges, L; colornorm = :log, hover = true)
	@test log_fig.data[1][:customdata] isa AbstractMatrix{Float64}
	@test isequal(log_fig.data[1][:customdata], L)
end

@testset "r1 sm-09: a live equal-aspect field shows the model's domains after a mutation" begin
	JSON = PlotlyBase.JSON
	state_js = """
	(function() {
	  const div = document.querySelector('.js-plotly-plot');
	  const F = div._fullLayout;
	  return JSON.stringify({x: F.xaxis.domain, y: F.yaxis.domain, w: F._size.w, h: F._size.h});
	})();
	"""
	state(sp) = JSON.parse(String(Base.invokelatest(() -> _R1._syncplot_backend(sp).run(sp.window, state_js))))
	same(a, b) = all(k -> isapprox(Float64.(a[k]), Float64.(b[k]); atol = 1e-9), ("x", "y", "w", "h"))
	Z = [sin(i / 3) * cos(j / 4) for i in 1:15, j in 1:12]
	for (style, change!) in ((:ieee, sp -> figsize!(sp, :ieee; columns = 2)), (:ieee, sp -> figsize!(sp, 500, 500)),
			(:default, sp -> figsize!(sp, 900, 400)))
		sp = to_syncplot(with_style(() -> plot_heatmap(1:15, 1:12, Z; equalar = true, colorbar_title = "u"), style); show = false)
		try
			change!(sp)
			fresh = to_syncplot(deepcopy(sp.plot); show = false)
			try
				live, ref = state(sp), state(fresh)
				@test same(live, ref)
				same(live, ref) || @info "sm-09 window differs from a fresh render" style live ref
			finally
				close(fresh)
			end
		finally
			close(sp)
		end
	end
end

# O18: the wave-7 export and window changes, rendered and measured. With
# R1_RENDER_DIR set, the renders are also written there to be looked at.
_r1_u32(b, i) = (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
function _r1_png_chunk(png::Vector{UInt8}, kind::String)
	i = 9
	while i + 7 <= length(png)
		len = Int(_r1_u32(png, i))
		String(png[(i + 4):(i + 7)]) == kind && return png[(i + 8):(i + 7 + len)]
		i += 12 + len
	end
	return nothing
end
_r1_keep(name, bytes) = (dir = get(ENV, "R1_RENDER_DIR", ""); isempty(dir) || write(joinpath(dir, name), bytes); nothing)

@testset "r1 O18: sized-style rasters, 3-D scene resolution, EPS translucency" begin
	# A sized journal style exports PNG at 300 dpi: pixel size and pHYs.
	fig = with_style(:ieee) do
		plot_scatter(1:10, sin.(1:10); xlabel = "x", ylabel = "y", legend = "sin")
	end
	o = _R1._normalize_export_options(fig, (;))
	png = savefig(fig; format = "png")
	_r1_keep("o18_ieee.png", png)
	@test (Int(_r1_u32(png, 17)), Int(_r1_u32(png, 21))) == (round(Int, o.width * 300 / 96), round(Int, o.height * 300 / 96))
	phys = _r1_png_chunk(png, "pHYs")
	@test phys !== nothing && Int(_r1_u32(phys, 1)) == Int(_r1_u32(phys, 5)) == round(Int, 300 / 0.0254) && phys[9] == 0x01
	# A 3-D scene is embedded in SVG and PDF at 384 ppi or more.
	x = collect(range(-2, 2; length = 30))
	surf = plot_surface(x, x, [exp(-a^2 - b^2) for a in x, b in x]; xlabel = "x", ylabel = "y", zlabel = "z")
	svg = String(savefig(surf; format = "svg"))
	_r1_keep("o18_surface.svg", codeunits(svg))
	m = match(r"<image[^>]*\bwidth=\"([0-9.]+)\"[^>]*href=\"data:image/png;base64,([^\"]+)\""s, svg)
	m === nothing && (m = match(r"<image[^>]*href=\"data:image/png;base64,([^\"]+)\"[^>]*\bwidth=\"([0-9.]+)\""s, svg))
	@test m !== nothing
	if m !== nothing
		drawn, data = occursin(r"^[0-9.]+$", m.captures[1]) ? (m.captures[1], m.captures[2]) : (m.captures[2], m.captures[1])
		raster = base64decode(data)
		ppi = Int(_r1_u32(raster, 17)) / (parse(Float64, drawn) / 96)
		@test ppi >= 384 * 0.99
		pdf = savefig(surf; format = "pdf")
		_r1_keep("o18_surface.pdf", pdf)
		widths = [parse(Int, w.captures[1]) for w in eachmatch(r"/Width\s+(\d+)", String(copy(pdf)))]
		@test !isempty(widths) && maximum(widths) / (parse(Float64, drawn) / 96) >= 384 * 0.99
	end
	# EPS has no transparency: a translucent paper and scene background are
	# flattened over white once (rgba(255,0,0,0.5) -> (255,128,128)).
	if _R1._ghostscript_available()
		relayout!(surf; paper_bgcolor = "rgba(255,0,0,0.5)", scene_bgcolor = "rgba(0,0,255,0.25)")
		mktempdir() do dir
			eps = joinpath(dir, "o18.eps"); out = joinpath(dir, "o18.png")
			savefig(surf, eps)
			run(pipeline(`$(_R1._ghostscript_command()) -q -dSAFER -dBATCH -dNOPAUSE -dEPSCrop -sDEVICE=png16m -r96 -sOutputFile=$out $eps`; stdout = devnull))
			raster = read(out)
			_r1_keep("o18_translucent_eps.png", raster)
			w, h, channels, pixels = _R1._png_decode(raster)
			corner = Int.(pixels[1:3])
			@test all(abs.(corner .- [255, 128, 128]) .<= 3)
			centre = Int.(pixels[(((h ÷ 2) * w + 3) * channels + 1):(((h ÷ 2) * w + 3) * channels + 3)])
			@test all(abs.(centre .- [255, 128, 128]) .<= 3)   # the left edge, outside the scene
			# Inside the scene, above the box: the scene background blended
			# once over the flattened paper, 0.25 (0,0,255) + 0.75 (255,128,128).
			sx, sy = round(Int, 0.1 * w), round(Int, 0.16 * h)
			scene = Int.(pixels[((sy * w + sx) * channels + 1):((sy * w + sx) * channels + 3)])
			@test all(abs.(scene .- [191, 96, 160]) .<= 3)
		end
	end
end

@testset "r1 O18: windows settle raw figures and drop removed ranges and contours (lw03, lw05)" begin
	JSON = PlotlyBase.JSON
	run_js(sp, code) = JSON.parse(String(Base.invokelatest(() -> _R1._syncplot_backend(sp).run(sp.window, code))))
	axes_js = """(function(){ const F = document.querySelector('.js-plotly-plot')._fullLayout;
	  return JSON.stringify({xr: F.xaxis.range, xa: F.xaxis.autorange, yr: F.yaxis.range, ya: F.yaxis.autorange}); })();"""
	contours_js = """(function(){ const d = document.querySelector('.js-plotly-plot')._fullData[0];
	  return JSON.stringify({auto: d.autocontour, start: d.contours.start, end: d.contours.end, size: d.contours.size}); })();"""
	function fresh_state(sp, js)
		fresh = to_syncplot(deepcopy(sp.plot); show = false)
		try
			return run_js(fresh, js)
		finally
			close(fresh)
		end
	end
	# A raw make_subplots figure is settled (by the verbs themselves since
	# apia-04, and again when its window is made): the window draws the whole
	# shared range, and the model has nothing left to settle.
	p = make_subplots(rows = 1, cols = 2, shared_yaxes = true)
	add_trace!(p, scatter(x = 1:3, y = [0.0, 1.0, 2.0]); row = 1, col = 1)
	add_trace!(p, scatter(x = 1:3, y = [0.0, 100.0, 200.0]); row = 1, col = 2)
	sp = to_syncplot(p; show = false)
	try
		@test _R1._finalize_figure!(p) === false
		state = run_js(sp, axes_js)
		@test state["yr"][1] <= 0 && state["yr"][2] >= 200
	finally
		close(sp)
	end
	# lw03: a removed range autoranges the window as a fresh render of the model.
	sp = to_syncplot(plot_scatter(1:3, [1.0, 3.0, 2.0]); show = false)
	try
		relayout!(sp; xaxis_range = [0, 1])
		@test run_js(sp, axes_js)["xr"] == [0, 1]
		relayout!(sp; xaxis_range = nothing)
		live = run_js(sp, axes_js)
		@test live["xa"] === true && live["xr"][1] <= 1 && live["xr"][2] >= 3
		@test live == fresh_state(sp, axes_js)
	finally
		close(sp)
	end
	# lw05: removed contour levels give the automatic levels back.
	U = [sin(a) * cos(b) for a in range(0, 3; length = 20), b in range(0, 3; length = 20)]
	sp = to_syncplot(plot_contour(U); show = false)
	try
		auto = run_js(sp, contours_js)
		restyle!(sp, 1; contours_start = 0.1, contours_end = 0.5, contours_size = 0.1)
		@test run_js(sp, contours_js)["size"] ≈ 0.1
		restyle!(sp, 1; contours_start = nothing, contours_end = nothing, contours_size = nothing)
		live = run_js(sp, contours_js)
		@test live == fresh_state(sp, contours_js)
		@test live == auto
	finally
		close(sp)
	end
end

# O12: a cell mutation stages on a copy of the layout and the containers it
# touches, never of the trace data: its cost follows the layout (cells,
# decorations), not the data. Measured on a 6x6 grid (Julia 1.13): 2.9 MB for
# 100 or 100 000 points per trace (57.6 MB of data).
@testset "r1 O12: a cell mutation does not copy trace data" begin
	function cells(n, npts)
		sf = subplots(n, n; sync = false)
		x = collect(range(0, 1; length = npts))
		for r in 1:n, c in 1:n
			plot_scatter!(sf, x, sin.(x .* (r + c)); row = r, col = c)
		end
		xlabel!(sf, "warm"; row = 1, col = 1); hline!(sf, 0.5; row = 1, col = 1)
		plot_scatter!(sf, [0.0, 1.0], [0.0, 1.0]; row = 1, col = 1)
		return sf
	end
	cost(sf) = (
		@allocated(xlabel!(sf, "x"; row = 1, col = 1)),
		@allocated(hline!(sf, 0.25; row = 1, col = 1)),
		@allocated(plot_scatter!(sf, [0.0, 1.0], [1.0, 0.0]; row = 1, col = 1)),
	)
	small, large = cells(6, 100), cells(6, 100_000)
	data = sum(sizeof(tr.fields[:x]) + sizeof(tr.fields[:y]) for tr in large.plot.data if haskey(tr.fields, :y))
	@test data > 50_000_000
	cs, cl = cost(small), cost(large)
	for (s, l) in zip(cs, cl)
		@test l < s + 1_000_000          # independent of the data
		@test l < 8_000_000              # bounded: 3 MB measured, layout-sized
	end
end

# O13: the transaction machinery is compiled once, not once per mutator,
# argument types and keywords (`_ErasedMutation`). Measured in a fresh
# process, nine first calls with keyword sets the workload does not use:
# 12.1 s of compilation before, 4.7 s after.
@testset "r1 O13: transaction wrappers are not specialized per call" begin
	machinery = (
		_R1._transactional_high_level_model_mutation!,
		_R1._prepare_high_level_plot_mutation_transaction,
		_R1._finish_high_level_plot_fast_transaction,
		_R1._prepare_full_model_mutation_transaction,
		_R1._transactional_full_plot_mutation!,
		_R1._try_local_plot_mutation!,
	)
	count_specializations() = sum(length(collect(Base.specializations(m))) for f in machinery for m in methods(f))
	x = collect(range(0, 1; length = 5)); y = x .^ 2
	fig = plot_scatter(x, y)
	sf = subplots(1, 2; sync = false)
	# Each path once.
	plot_scatter!(fig, x, y; legend = "w"); hline!(fig, 0.5; dash = "dot")
	plot_scatter!(sf, x, y; row = 1, col = 1); xlabel!(sf, "x"; row = 1, col = 1)
	plot_surface!(subplots(1, 1; sync = false, specs = [Spec(kind = "scene")]), x, x, x * x'; row = 1, col = 1)
	before = count_specializations()
	# Calls whose mutator, arguments or keywords are new to this process.
	plot_scatter!(fig, x, y; opacity = 0.5, legend = "o")
	hline!(fig, 0.25; linewidth = 3, color = "red")
	vline!(fig, 0.5; color = "blue", dash = "dash")
	plot_scatter!(sf, x, y; row = 1, col = 2, marker_size = 4, mode = "markers")
	ylabel!(sf, "y"; row = 1, col = 2, wrap = false)
	@test count_specializations() == before
end
