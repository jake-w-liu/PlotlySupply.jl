# Load time and time-to-first-figure (TTFX) of PlotlySupply, each scenario in
# a fresh Julia process (a warm process would hide exactly the compile time
# this measures). Included by `benchmarks.jl`; run alone with
#
#     julia --project=benchmark benchmark/ttfx.jl [--repeats N] [--no-electron] [--baseline DIR]
#
# Every scenario prints `RESULT <key>=<seconds>` lines; the driver parses them
# and reports the minimum, median and maximum over the repeats. With
# `--baseline DIR` (an environment that loads another PlotlySupply checkout,
# e.g. an older commit) both are measured, interleaved run by run.

using Printf
using Statistics: median

const TTFX_ROOT = normpath(joinpath(@__DIR__, ".."))

# Code run in the child process. `PlotlySupply` is the package under test
# (resolved through the benchmark project's `[sources]` entry, or through the
# repository project when the driver is started with `--project=.`).
const TTFX_SCENARIOS = [
	(
		name = "load",
		electron = false,
		code = raw"""
		t0 = time_ns()
		using PlotlySupply
		println("RESULT using=", (time_ns() - t0) / 1e9)
		""",
	),
	(
		name = "scatter",
		electron = false,
		code = raw"""
		using PlotlySupply
		x = collect(range(0, 2pi; length = 50))
		println("RESULT first_plot_scatter=", @elapsed plot_scatter(x, sin.(x); xlabel = "x", ylabel = "y", legend = "sin"))
		println("RESULT second_plot_scatter=", @elapsed plot_scatter(x, cos.(x); xlabel = "x", ylabel = "y", legend = "cos"))
		""",
	),
	(
		name = "heatmap",
		electron = false,
		code = raw"""
		using PlotlySupply
		x = collect(range(0, 1; length = 40)); y = collect(range(0, 2; length = 60))
		U = [sin(3xi) * cos(2yj) for xi in x, yj in y]
		println("RESULT first_plot_heatmap=", @elapsed plot_heatmap(x, y, U; xlabel = "x", ylabel = "y"))
		println("RESULT second_plot_heatmap=", @elapsed plot_heatmap(x, y, 2 .* U; xlabel = "x", ylabel = "y"))
		""",
	),
	(
		name = "subplots",
		electron = false,
		code = raw"""
		using PlotlySupply
		x = collect(range(0, 1; length = 40)); U = [sin(3a) * cos(2b) for a in x, b in x]
		t = @elapsed begin
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, x, x .^ 2; row = 1, col = 1, legend = "x^2")
			plot_heatmap!(sf, x, x, U; row = 1, col = 2)
		end
		println("RESULT first_subplots_2mutators=", t)
		t = @elapsed begin
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, x, x .^ 3; row = 1, col = 1, legend = "x^3")
			plot_heatmap!(sf, x, x, 2 .* U; row = 1, col = 2)
		end
		println("RESULT second_subplots_2mutators=", t)
		""",
	),
	(
		name = "export_model",
		electron = false,
		code = raw"""
		using PlotlySupply
		x = collect(range(0, 2pi; length = 50))
		fig = plot_scatter(x, sin.(x); xlabel = "x", ylabel = "y", legend = "sin")
		dir = mktempdir()
		# The Julia side of a png/pdf export (export copy, finalizer, JSON
		# for the renderer) and the complete html export: no Electron.
		println("RESULT first_export_model=", @elapsed PlotlySupply._prepare_export(fig, ("png", "pdf"), NamedTuple()))
		println("RESULT first_savefig_html=", @elapsed savefig(fig, joinpath(dir, "f.html")))
		println("RESULT second_savefig_html=", @elapsed savefig(fig, joinpath(dir, "g.html")))
		""",
	),
	(
		name = "export_png",
		electron = true,
		code = raw"""
		using PlotlySupply
		x = collect(range(0, 2pi; length = 50))
		fig = plot_scatter(x, sin.(x); xlabel = "x", ylabel = "y", legend = "sin")
		dir = mktempdir()
		println("RESULT first_savefig_png=", @elapsed savefig(fig, joinpath(dir, "a.png"); width = 700, height = 500))
		println("RESULT second_savefig_png=", @elapsed savefig(fig, joinpath(dir, "b.png"); width = 700, height = 500))
		println("RESULT first_savefig_pdf_after_png=", @elapsed savefig(fig, joinpath(dir, "c.pdf"); width = 700, height = 500))
		println("RESULT second_savefig_pdf=", @elapsed savefig(fig, joinpath(dir, "d.pdf"); width = 700, height = 500))
		# A second export window (a fresh export state) on the Electron
		# application that is already running, with every Julia method
		# compiled: the cost of a window and its page alone.
		println("RESULT second_export_window=", @elapsed PlotlySupply._ensure_export_window(PlotlySupply._ExportState()))
		""",
	),
	(
		name = "export_split",
		electron = true,
		code = raw"""
		using PlotlySupply
		x = collect(range(0, 2pi; length = 50))
		fig = plot_scatter(x, sin.(x); xlabel = "x", ylabel = "y", legend = "sin")
		dir = mktempdir()
		# The same first PNG export, split into its stages. `@timed` also
		# reports the time this process spent compiling (inference and code
		# generation) inside each stage; the rest of the first window is the
		# Electron application's start-up and the window's page load.
		println("RESULT split_export_model=", @elapsed PlotlySupply._prepare_export(fig, ("png",), NamedTuple()))
		println("RESULT split_load_electroncall=", @elapsed PlotlySupply._electroncall())
		s = @timed PlotlySupply._ensure_export_window()
		println("RESULT split_first_window=", s.time)
		println("RESULT split_first_window_julia_compile=", s.compile_time)
		println("RESULT split_first_window_electron_and_page=", s.time - s.compile_time)
		s = @timed savefig(fig, joinpath(dir, "a.png"); width = 700, height = 500)
		println("RESULT split_first_png_render=", s.time)
		println("RESULT split_first_png_render_julia_compile=", s.compile_time)
		""",
	),
	(
		name = "export_pdf",
		electron = true,
		code = raw"""
		using PlotlySupply
		x = collect(range(0, 2pi; length = 50))
		fig = plot_scatter(x, sin.(x); xlabel = "x", ylabel = "y", legend = "sin")
		dir = mktempdir()
		println("RESULT first_savefig_pdf=", @elapsed savefig(fig, joinpath(dir, "a.pdf"); width = 700, height = 500))
		""",
	),
]

# Run `code` in a fresh process; returns key => seconds, or throws with the
# child's output when it fails or reports nothing.
function ttfx_run(code::AbstractString; project::AbstractString)
	cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(project) -e $(code)`
	out = IOBuffer()
	proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out); wait = true)
	text = String(take!(out))
	results = Dict{String, Float64}()
	for line in eachline(IOBuffer(text))
		m = match(r"^RESULT ([A-Za-z0-9_]+)=([-+0-9.eE]+)$", strip(line))
		m === nothing && continue
		results[m.captures[1]] = parse(Float64, m.captures[2])
	end
	(success(proc) && !isempty(results)) ||
		error("TTFX scenario failed (exit code $(proc.exitcode)):\n$(text)")
	return results
end

"""
	ttfx_measure(projects; repeats = 3, electron = true) -> (keys, rows)

Run every scenario `repeats` times per environment, each run in a fresh
process. `projects` is a vector of `label => project_dir` pairs; the runs of
the environments are interleaved (scenario by scenario, repeat by repeat) so
that a before/after comparison sees the same machine load. Returns the
measured keys in order and, per label, a `key => (min, median, max, n)`
dictionary of seconds. Each scenario also records `process_wall_<name>`, the
wall time of the whole child process (Julia start-up included).
"""
function ttfx_measure(projects::AbstractVector{<:Pair}; repeats::Integer = 3, electron::Bool = true)
	repeats >= 1 || throw(ArgumentError("ttfx_measure: `repeats` must be >= 1; got $(repeats)."))
	isempty(projects) && throw(ArgumentError("ttfx_measure: no project to measure."))
	samples = Dict(String(label) => Dict{String, Vector{Float64}}() for (label, _) in projects)
	length(samples) == length(projects) || throw(ArgumentError("ttfx_measure: project labels must be distinct."))
	order = String[]
	# Untimed: load each environment once, so a stale package image is
	# rebuilt here and not inside the first timed `using`.
	for (_, dir) in projects
		ttfx_run("using PlotlySupply; println(\"RESULT ready=1\")"; project = dir)
	end
	for scenario in TTFX_SCENARIOS
		(scenario.electron && !electron) && continue
		for _ in 1:repeats, (label, dir) in projects
			wall = @elapsed result = ttfx_run(scenario.code; project = dir)
			result["process_wall_" * scenario.name] = wall
			for (key, value) in result
				key in order || push!(order, key)
				push!(get!(Vector{Float64}, samples[String(label)], key), value)
			end
		end
	end
	stats = Dict(label => Dict(key => (min = minimum(v), median = median(v), max = maximum(v), n = length(v))
		for (key, v) in per_key) for (label, per_key) in samples)
	return order, stats
end

# Markdown table of `ttfx_measure`'s result: min / median / max per
# environment and, with two or more, the ratio of the first label's minimum to
# each other label's minimum.
function ttfx_table(order, stats, labels::AbstractVector{<:AbstractString})
	io = IOBuffer()
	print(io, "| measurement |")
	for label in labels
		print(io, " $(label) min (s) | $(label) median (s) | $(label) max (s) |")
	end
	for label in labels[2:end]
		print(io, " $(labels[1]) / $(label) (min) |")
	end
	println(io, " runs |")
	println(io, "|---|", repeat("---:|", 3 * length(labels) + length(labels) - 1), "---:|")
	for key in order
		print(io, "| ", key, " |")
		for label in labels
			s = get(stats[label], key, nothing)
			s === nothing ? print(io, " - | - | - |") : @printf(io, " %.3f | %.3f | %.3f |", s.min, s.median, s.max)
		end
		first_stat = get(stats[labels[1]], key, nothing)
		for label in labels[2:end]
			s = get(stats[label], key, nothing)
			(first_stat === nothing || s === nothing || s.min <= 0) ? print(io, " - |") :
				@printf(io, " %.1fx |", first_stat.min / s.min)
		end
		println(io, " ", maximum(get(stats[label], key, (n = 0,)).n for label in labels), " |")
	end
	return String(take!(io))
end

# The project directory the child processes use: the one this driver runs in.
ttfx_project_dir() = dirname(something(Base.active_project(), joinpath(TTFX_ROOT, "Project.toml")))

# Arguments: `--repeats N` (default 3), `--no-electron` (skip the png/pdf
# scenarios), `--project DIR` (the environment the children load
# PlotlySupply from; default: this driver's active project), `--baseline DIR`
# (also measure the environment in DIR, interleaved, labelled "baseline").
function ttfx_parse_args(args)
	repeats = 3
	electron = true
	project = ttfx_project_dir()
	baseline = nothing
	i = 1
	while i <= length(args)
		arg = args[i]
		if arg == "--repeats" && i < length(args)
			repeats = parse(Int, args[i + 1])
			i += 1
		elseif arg == "--project" && i < length(args)
			project = abspath(args[i + 1])
			i += 1
		elseif arg == "--baseline" && i < length(args)
			baseline = abspath(args[i + 1])
			i += 1
		elseif arg == "--no-electron"
			electron = false
		else
			error("ttfx.jl: unknown argument $(repr(arg))")
		end
		i += 1
	end
	projects = baseline === nothing ? ["current" => project] : ["baseline" => baseline, "current" => project]
	return (repeats = repeats, electron = electron, projects = projects)
end

function ttfx_main(args)
	opts = ttfx_parse_args(args)
	order, stats = ttfx_measure(opts.projects; repeats = opts.repeats, electron = opts.electron)
	print(ttfx_table(order, stats, [String(first(p)) for p in opts.projects]))
	return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
	ttfx_main(ARGS)
end
