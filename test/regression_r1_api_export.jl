using Test, PlotlySupply
using PlotlySupply: PlotlyBase
using Base64

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

@testset "r1 tests-ci-06: runtests.jl is many small top-level statements" begin
	path = joinpath(@__DIR__, "runtests.jl")
	ex = Meta.parseall(read(path, String); filename = path)
	lines = [a.line for a in ex.args if a isa LineNumberNode]
	nlines = countlines(path)
	spans = diff(vcat(lines, nlines + 1))
	# The file was one 5550-line @testset compiled as one thunk (52+ minutes
	# of codegen before its first statement). It is now ~150 statements; the
	# largest (about 970 lines) lowers in about 3 s.
	@test length(lines) > 50
	@test maximum(spans) < 1500
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
	isdefined(@__MODULE__, :_global_registries_snapshot) || include(joinpath(@__DIR__, "testutils.jl"))
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
