using Pkg
Pkg.activate("..")

using Documenter
using PlotlySupply

makedocs(
    sitename="PlotlySupply.jl",
)

deploydocs(
    repo = "github.com/jake-w-liu/PlotlySupply.jl.git",
)