# Render the whole gallery: every other script in this directory, each in its own
# module, failures reported at the end, exit status 1 if any script failed.
#
#     julia --project=. docs/gallery/runall.jl [outdir [name ...]]
#
# `outdir` is where the PNGs go (default: next to each script); `name ...` limits the run
# to the scripts with those names (with or without `.jl`).
using PlotlySupply

const GALLERY_DIR = @__DIR__

# Stand-in for `savefig` in a dry run: the figure is built (every call of the script runs) but
# nothing is rendered; an empty file is written so that scripts that read their output back work.
function _gallery_dry_savefig(fig, path::AbstractString; kwargs...)
	write(path, "")
	return path
end
function _gallery_dry_savefig(fig, paths::AbstractVector{<:AbstractString}; kwargs...)
	foreach(p -> write(p, ""), paths)
	return paths
end

"""
    run_gallery(args; render = true) -> Int

Run the gallery scripts. `args = [outdir, names...]` as on the command line. With
`render = false` every `savefig` call is replaced by a stand-in that writes an empty file, so the
scripts are executed in full without the cost of exporting. Returns the exit status: 0 when every
script ran, 1 otherwise.
"""
function run_gallery(args::Vector{String}; render::Bool = true)
	outdir = isempty(args) ? nothing : mkpath(abspath(first(args)))
	wanted = [endswith(a, ".jl") ? a : a * ".jl" for a in args[2:end]]
	scripts = sort!(filter(f -> endswith(f, ".jl") && f != "runall.jl", readdir(GALLERY_DIR)))
	isempty(wanted) || (scripts = filter(in(wanted), scripts))
	for w in wanted
		w in scripts || (println("unknown gallery script: ", w); return 1)
	end
	# The scripts read their output directory from ARGS[1] (or use their own directory).
	saved_args = copy(ARGS)
	empty!(ARGS)
	outdir === nothing || push!(ARGS, outdir)
	failed = String[]
	try
		for f in scripts
			m = Module(Symbol("gallery_", replace(f, "." => "_")))
			t0 = time()
			try
				path = joinpath(GALLERY_DIR, f)
				if render
					Base.include(m, path)
				else
					Core.eval(m, :(_gallery_savefig = $(_gallery_dry_savefig)))
					src = replace(read(path, String), r"\bsavefig\(" => "_gallery_savefig(")
					Base.include_string(m, src, path)
				end
				println("ok    ", f, "  ", round(time() - t0; digits = 1), " s")
			catch err
				push!(failed, f)
				println("FAIL  ", f, "  ", sprint(showerror, err)[1:min(end, 600)])
			end
			flush(stdout)
		end
	finally
		empty!(ARGS)
		append!(ARGS, saved_args)
	end
	println(length(scripts) - length(failed), " of ", length(scripts), " gallery scripts ran")
	foreach(f -> println("failed: ", f), failed)
	return isempty(failed) ? 0 : 1
end

# Run when invoked as a script; `include`-ing the file only defines `run_gallery`.
abspath(PROGRAM_FILE) == (@__FILE__) && exit(run_gallery(copy(ARGS)))
