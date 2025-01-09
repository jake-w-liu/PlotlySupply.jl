module PlotlySupply

using BatchAssign
using Reexport
@reexport using PlotlyJS

include("api.jl")

# acronyms
rplot = plot_rect
pplot = plot_polar
hplot = plot_holo
splot = plot_surf

export plot_rect, plot_polar, plot_holo, plot_surf
export rplot, pplot, hplot, splot

end
