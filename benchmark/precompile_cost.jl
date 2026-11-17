# Cost of building PlotlySupply's package image (precompilation, including
# the PrecompileTools workload of src/precompile.jl) and the size of the
# image. Each repeat rebuilds the image from scratch in a child process:
#
#     julia --project=benchmark benchmark/precompile_cost.jl [--repeats N]
#
# Prints `RESULT compilecache=<seconds>` and `RESULT image_megabytes=<MB>`
# per repeat. Included by `benchmarks.jl` (`--precompile-cost`).

function precompile_cost_measure(; repeats::Integer = 1)
	repeats >= 1 || throw(ArgumentError("precompile_cost_measure: `repeats` must be >= 1; got $(repeats)."))
	pkg = Base.identify_package("PlotlySupply")
	pkg === nothing && error("precompile_cost.jl: PlotlySupply is not in the active environment.")
	# Load it once first: this compiles every dependency (and PlotlySupply
	# itself if its image is stale), so the timed builds below rebuild only
	# PlotlySupply's own image.
	Base.require(pkg)
	seconds = Float64[]
	megabytes = Float64[]
	for _ in 1:repeats
		t = @elapsed result = Base.compilecache(pkg)
		# `compilecache` returns the image path, or (image path, native code
		# library path) when native code is cached separately.
		paths = result isa Tuple ? [p for p in result if p isa AbstractString] : [result]
		push!(seconds, t)
		push!(megabytes, sum(p -> isfile(p) ? filesize(p) : 0, paths; init = 0) / 2^20)
		println("RESULT compilecache=", t)
		println("RESULT image_megabytes=", megabytes[end])
	end
	return (seconds = seconds, megabytes = megabytes)
end

function precompile_cost_main(args)
	repeats = 1
	i = findfirst(==("--repeats"), args)
	if i !== nothing
		i < length(args) || error("precompile_cost.jl: `--repeats` needs a number.")
		repeats = parse(Int, args[i + 1])
	end
	precompile_cost_measure(; repeats = repeats)
	return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
	precompile_cost_main(ARGS)
end
