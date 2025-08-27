module PlotlySupply

using BatchAssign
using Reexport
using Infiltrator
@reexport using PlotlyJS

include("api.jl")

export plot_scatter, plot_stem, plot_scatterpolar, plot_heatmap, plot_quiver, plot_surface, plot_scatter3d, plot_quiver3d
export set_template!

end
