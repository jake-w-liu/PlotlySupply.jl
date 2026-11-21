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
