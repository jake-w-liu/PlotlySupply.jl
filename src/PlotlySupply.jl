module PlotlySupply

using BatchAssign
using Reexport
@reexport using PlotlyJS

include("api.jl")

# acronyms
rplot = plot_rect
pplot = plot_polar
hplot = plot_holo

export plot_rect, plot_polar, plot_holo
export rplot, pplot, hplot

end
