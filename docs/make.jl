using Documenter
using PlotlySupply

# The manual, in navigation order. Every page under docs/src is listed exactly
# once; Documenter's strict build (warnonly = false) fails on a page that exists
# but is missing here, and on one listed here that does not exist.
const PAGES = Any[
	"Introduction" => "index.md",
	"Guides" => [
		"Lines and markers" => "lines.md",
		"Statistical plots" => "statistics.md",
		"2-D fields" => "fields.md",
		"3-D plots" => "threed.md",
		"Subplots" => "subplots.md",
		"Axes and ticks" => "axes.md",
		"Text and math" => "text.md",
		"Colours" => "colors.md",
		"Reference lines and shapes" => "shapes.md",
		"Styles and templates" => "styles.md",
		"Export" => "export.md",
		"Live windows" => "windows.md",
		"Other charts and maps" => "charts.md",
	],
	"Figures for papers" => "papers.md",
	"Examples" => "example.md",
	"Coming from matplotlib" => "matplotlib.md",
	"Migrating from 1.x" => "migration.md",
	"API reference" => "api.md",
	"Re-exported API (PlotlyJS compatibility)" => "compat.md",
]

makedocs(
	sitename = "PlotlySupply.jl",
	format = Documenter.HTML(
		# api.md is a single @autodocs page holding every exported docstring,
		# well above Documenter's 200 KiB hard limit for one page. Other pages
		# keep the default limits. Drop this entry once api.md is split.
		size_threshold_ignore = ["api.md"],
		# The search index of the complete manual is about 660 KiB, over the 500 KiB
		# default warning limit; the pages are one reference manual, not a size problem.
		search_size_threshold_warn = 1024 * 1024,
		# compat.md (the re-exported PlotlyJS API) is about 180 KiB; warn only when a
		# page nears Documenter's 200 KiB hard limit instead of at the 100 KiB default.
		size_threshold_warn = 190 * 1024,
	),
	modules = [PlotlySupply],
	# Every exported name must have a docstring that appears in the manual.
	checkdocs = :exports,
	# Strict: any Documenter warning (missing docstring, broken @ref, ...) fails the build.
	warnonly = false,
	pages = PAGES,
)

deploydocs(
	repo = "github.com/jake-w-liu/PlotlySupply.jl.git",
)
