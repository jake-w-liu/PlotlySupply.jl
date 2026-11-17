using Documenter
using PlotlySupply

# The manual's main pages, in navigation order.
const MAIN_PAGES = [
	"Introduction" => "index.md",
	"Examples" => "example.md",
	"API Documentation" => "api.md",
	"Re-exported API (PlotlyJS compatibility)" => "compat.md",
]

# Every other page under docs/src follows them in path order, titled by its
# first heading, so a new page is never built without a place in the navigation.
const OTHER_PAGES = let src = joinpath(@__DIR__, "src"), pages = String[]
	for (root, _, files) in walkdir(src), file in files
		endswith(file, ".md") || continue
		# Documenter names pages by their path relative to src, '/'-separated.
		page = join(splitpath(relpath(joinpath(root, file), src)), '/')
		page in last.(MAIN_PAGES) || push!(pages, page)
	end
	sort!(pages)
end

makedocs(
	sitename = "PlotlySupply.jl",
	format = Documenter.HTML(
		# api.md is a single @autodocs page holding every exported docstring,
		# well above Documenter's 200 KiB hard limit for one page. Other pages
		# keep the default limits. Drop this entry once api.md is split.
		size_threshold_ignore = ["api.md"],
	),
	modules = [PlotlySupply],
	# Every exported name must have a docstring that appears in the manual.
	checkdocs = :exports,
	# Strict: any Documenter warning (missing docstring, broken @ref, ...) fails the build.
	warnonly = false,
	pages = Any[MAIN_PAGES..., OTHER_PAGES...],
)

deploydocs(
	repo = "github.com/jake-w-liu/PlotlySupply.jl.git",
)
