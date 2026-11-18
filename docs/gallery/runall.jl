# Render the whole gallery: every other script in this directory, each in its own
# module, failures reported at the end, exit status 1 if any script failed.
#
#     julia --project=. docs/gallery/runall.jl [outdir [name ...]]
#
# `outdir` is where the PNGs go (default: next to each script); `name ...` limits the run
# to the scripts with those names (with or without `.jl`).
using PlotlySupply

const GALLERY_DIR = @__DIR__

function run_gallery(args::Vector{String})
	outdir = isempty(args) ? nothing : mkpath(abspath(first(args)))
	wanted = [endswith(a, ".jl") ? a : a * ".jl" for a in args[2:end]]
	scripts = sort!(filter(f -> endswith(f, ".jl") && f != "runall.jl", readdir(GALLERY_DIR)))
	isempty(wanted) || (scripts = filter(in(wanted), scripts))
	for w in wanted
		w in scripts || (println("unknown gallery script: ", w); return 1)
	end
	# The scripts read their output directory from ARGS[1] (or use their own directory).
	empty!(ARGS)
	outdir === nothing || push!(ARGS, outdir)
	failed = String[]
	for f in scripts
		m = Module(Symbol("gallery_", replace(f, "." => "_")))
		t0 = time()
		try
			Base.include(m, joinpath(GALLERY_DIR, f))
			println("ok    ", f, "  ", round(time() - t0; digits = 1), " s")
		catch err
			push!(failed, f)
			println("FAIL  ", f, "  ", sprint(showerror, err)[1:min(end, 600)])
		end
		flush(stdout)
	end
	println(length(scripts) - length(failed), " of ", length(scripts), " gallery scripts ran")
	foreach(f -> println("failed: ", f), failed)
	return isempty(failed) ? 0 : 1
end

# Run when invoked as a script; `include`-ing the file only defines `run_gallery`.
abspath(PROGRAM_FILE) == (@__FILE__) && exit(run_gallery(copy(ARGS)))
