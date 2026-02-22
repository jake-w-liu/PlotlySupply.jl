module PlotlySupply

using BatchAssign
using Infiltrator
using Reexport
@reexport using PlotlyBase

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
export set_template!, get_default_template, set_default_template!
export set_legend!, get_default_legend_position, set_default_legend_position!
export xlabel!, ylabel!, xrange!, yrange!
export SyncPlot, SubplotFigure, plot, plot!, to_syncplot, msgchannel, toggle_devtools, savefig, make_subplots, subplots, subplot!, subplot_legends!, mgrid

end
