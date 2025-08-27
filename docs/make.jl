using Documenter
push!(LOAD_PATH,"../src/")
using PlotlySupply

makedocs(sitename="PlotlySupply.jl")

deploydocs(
    repo = "github.com/jake-w-liu/PlotlySupply.jl.git",
)