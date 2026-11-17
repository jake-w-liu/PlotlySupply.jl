using Documenter
using PlotlySupply

makedocs(
	sitename = "PlotlySupply.jl",
	format = Documenter.HTML(
		# api.md is a single @autodocs page holding every exported docstring
		# (about 590 KiB of HTML in 2.0, above Documenter's 200 KiB hard limit).
		# Other pages keep the default limits. Drop this entry once api.md is
		# split into topic pages.
		size_threshold_ignore = ["api.md"],
	),
	modules = [PlotlySupply],
	# Every exported name must have a docstring that appears in the manual.
	checkdocs = :exports,
	# Strict: any Documenter warning (missing docstring, broken @ref, ...) fails the build.
	warnonly = false,
	pages = [
		"Introduction" => "index.md",
		"Examples" => "example.md",
		"API Documentation" => "api.md",
		"Re-exported API (PlotlyJS compatibility)" => "compat.md",
	],
)

deploydocs(
	repo = "github.com/jake-w-liu/PlotlySupply.jl.git",
)
