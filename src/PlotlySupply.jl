module PlotlySupply

using BatchAssign
using Infiltrator
using Reexport
@reexport using PlotlyBase
# Re-export so the documented `meshgrid(y, x)` workflow works after `using
# PlotlySupply` (the heatmap/surface/quiver examples rely on it).
@reexport using MeshGrid

mutable struct SyncPlot
	plot::Plot
	app::Any
	window::Any
	divid::String
end

function Base.getproperty(sp::SyncPlot, name::Symbol)
	if name === :plot || name === :app || name === :window || name === :divid
		return getfield(sp, name)
	end

	p = getfield(sp, :plot)
	if hasproperty(p, name)
		return getproperty(p, name)
	end
	return getfield(sp, name)
end

function Base.propertynames(sp::SyncPlot, private::Bool = false)
	return (fieldnames(SyncPlot)..., propertynames(getfield(sp, :plot), private)...)
end

_plotlyjs_refresh!(fig, data, layout) = nothing

to_syncplot(fig; kwargs...) = error(
	"`to_syncplot` requires ElectronCall.jl. " *
	"Install it once in your environment: `import Pkg; Pkg.add(\"ElectronCall\")`.",
)

plot(args...; kwargs...) = error(
	"`plot` compatibility API requires ElectronCall.jl. " *
	"Install it once in your environment: `import Pkg; Pkg.add(\"ElectronCall\")`.",
)

include("api.jl")
include("electron_backend.jl")
include("plotlyjs_compat.jl")

function __init__()
	pushdisplay(ElectronDisplay())
	# Skip method overrides when running inside another package's precompilation
	# to avoid eval-into-closed-module errors on Julia ≥ 1.12.
	if ccall(:jl_generating_output, Cint, ()) == 0
		_install_plot_method_overrides!()
	end
end

export plot_scatter, plot_scatter!, plot_stem, plot_stem!, plot_bar, plot_bar!, plot_histogram, plot_histogram!, plot_box, plot_box!, plot_violin, plot_violin!, plot_scatterpolar, plot_scatterpolar!, plot_heatmap, plot_heatmap!, plot_contour, plot_contour!, plot_quiver, plot_quiver!, plot_surface, plot_surface!, plot_scatter3d, plot_scatter3d!, plot_quiver3d, plot_quiver3d!
export plot_pie, plot_pie!, plot_sunburst, plot_sunburst!, plot_treemap, plot_treemap!
export plot_funnel, plot_funnel!, plot_funnelarea, plot_funnelarea!, plot_waterfall, plot_waterfall!
export plot_indicator, plot_indicator!
export plot_area, plot_area!, plot_candlestick, plot_candlestick!, plot_ohlc, plot_ohlc!
export plot_histogram2d, plot_histogram2d!, annotate!
export plot_sankey, plot_sankey!, plot_parcoords, plot_parcoords!, plot_ternary, plot_ternary!, plot_image, plot_image!
export plot_mesh3d, plot_mesh3d!, plot_isosurface, plot_isosurface!, plot_volume, plot_volume!, plot_streamtube, plot_streamtube!
export plot_choropleth, plot_choropleth!, plot_scattergeo, plot_scattergeo!
export plot_scattermapbox, plot_scattermapbox!, plot_densitymapbox, plot_densitymapbox!
export set_template!, get_default_template, set_default_template!
export set_legend!, get_default_legend_position, set_default_legend_position!
export xlabel!, ylabel!, xrange!, yrange!
export SyncPlot, SubplotFigure, plot, plot!, to_syncplot, msgchannel, toggle_devtools, savefig, make_subplots, subplots, subplot!, subplot_legends!, mgrid

end
