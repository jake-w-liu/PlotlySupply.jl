using Pkg, Revise
Pkg.activate(".")

using PlotlySupply

rplot(1:3, 4:6, title = "dd", height =400, width = 400)