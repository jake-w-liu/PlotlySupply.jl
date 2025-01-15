module PlotlySupply

using BatchAssign
using Reexport
using Infiltrator
@reexport using PlotlyJS

include("api.jl")

# acronyms


export plot_scatter, plot_scatterpolar, plot_heatmap, plot_quiver, plot_surface, plot_scatter3d

end
