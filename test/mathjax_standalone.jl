using Test, PlotlySupply

isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")

# The MathJax rendering regressions (math legend sizing, font context of math
# text, SVG serialization) measure the real renderer and need it untouched when
# they start, so each mode runs in a fresh Julia process. A script reports a
# failed check by raising, i.e. by a non-zero exit status; its output is shown
# only then.
function _mathjax_standalone_passes(script::AbstractString, args::AbstractString...)
	output = IOBuffer()
	command = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no $(joinpath(@__DIR__, script)) $(collect(args))`
	passed = success(pipeline(ignorestatus(command); stdout = output, stderr = output))
	passed || @error "standalone test failed" script args output = String(take!(output))
	return passed
end

@testset "MathJax rendering regressions (fresh renderer per mode)" begin
	mktempdir() do directory
		# Each run creates its own output directory and refuses an existing one.
		for mode in ("matrix", "order12", "order18", "custom", "live")
			@test _mathjax_standalone_passes("mathjax_rendering.jl", joinpath(directory, mode), mode)
		end
		@test _mathjax_standalone_passes("mathjax_svg_serialization.jl", joinpath(directory, "svg"))
	end
end
