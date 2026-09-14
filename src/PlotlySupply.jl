module PlotlySupply

using LazyArtifacts
using Reexport
@reexport using PlotlyBase
include("modern_map_subplots.jl")
# Re-export so the documented `meshgrid(y, x)` workflow works after `using
# PlotlySupply` (the heatmap/surface/quiver examples rely on it).
@reexport using MeshGrid

# PlotlyBase exports `json`, but recent JSON.jl releases no longer export that
# function for `using JSON` to import. Restore the documented binding while
# retaining forward compatibility with a PlotlyBase release that defines it.
if !isdefined(@__MODULE__, :json)
	const json = PlotlyBase.JSON.json
end

struct _SyncPlotCreationSpec
	width::Int
	height::Int
	title::String
	show::Bool
	autoplay::Bool
	timeout_s::Float64
end

mutable struct _SyncPlotResources
	lock::ReentrantLock
	render_lock::ReentrantLock
	transaction_owner::Union{Nothing,Task}
	tempdir::Union{Nothing,String}
	backend::Any
	renderer_desynchronized::Bool
	close_started::Bool
	close_owner::Union{Nothing,Task}
	close_done::Base.Event
	cleanup_in_progress::Bool
	cleanup_done::Base.Event
	tempdir_remover::Any
	creation_spec::Union{Nothing,_SyncPlotCreationSpec}
end

_SyncPlotResources(
	tempdir::Union{Nothing,String} = nothing,
	backend = nothing,
	creation_spec::Union{Nothing,_SyncPlotCreationSpec} = nothing,
) = _SyncPlotResources(
	ReentrantLock(),
	ReentrantLock(),
	nothing,
	tempdir,
	backend,
	false,
	false,
	nothing,
	Base.Event(),
	false,
	Base.Event(),
	nothing,
	creation_spec,
)

struct _SyncPlotDesynchronizationError <: Exception
	operation_error::Any
	recovery_error::Any
end

function Base.showerror(io::IO, err::_SyncPlotDesynchronizationError)
	if err.operation_error === nothing
		print(
			io,
			"SyncPlot renderer recovery failed; the Julia model remains " *
			"unchanged, but the renderer state is unknown. Recovery error: ",
		)
	else
		print(
			io,
			"SyncPlot renderer operation failed and recovery also failed; " *
			"the Julia model was not committed, but the renderer state is " *
			"unknown. Operation error: ",
		)
		showerror(io, err.operation_error)
		print(io, ". Recovery error: ")
	end
	showerror(io, err.recovery_error)
	return nothing
end

"""
	SyncPlot

A `PlotlyBase.Plot` displayed in a live Electron desktop window. Construct one
via [`to_syncplot`](@ref), `plot(...; sync = true)`, or any high-level `plot_*`
or `subplots` constructor with `show = true`.

Mutating calls (`plot_*!`, `relayout!`, `restyle!`, `add_trace!`, …) committed
on a `SyncPlot` refresh the open window transactionally. `sp.plot` is the
wrapped `Plot`; `sp.app`, `sp.window`, and `sp.divid` expose the underlying
Electron objects, and any other property access forwards to `sp.plot` (e.g.
`sp.data`, `sp.layout`). See also [`msgchannel`](@ref),
[`toggle_devtools`](@ref), and [`savefig`](@ref).
"""
mutable struct SyncPlot
	plot::Plot
	app::Any
	window::Any
	divid::String
	_resources::_SyncPlotResources
end

function _require_syncplot_model(plot::Plot)
	plot.data isa Vector || throw(ArgumentError(
		"SyncPlot requires `plot.data` to be a concrete Vector so renderer " *
		"transactions can commit trace insertion, deletion, and reordering " *
		"atomically. Rebuild the model with `PlotlySupply.plot(plot.data, " *
		"plot.layout; frames=plot.frames, config=plot.config)`.",
	))
	return plot
end

# Preserve the original public constructor even though lifecycle state is kept
# privately on each SyncPlot.
function SyncPlot(plot::Plot, app, window, divid::String)
	_require_syncplot_model(plot)
	return SyncPlot(
		plot,
		app,
		window,
		divid,
		_SyncPlotResources(),
	)
end

function Base.getproperty(sp::SyncPlot, name::Symbol)
	if name in fieldnames(SyncPlot)
		return getfield(sp, name)
	end

	p = getfield(sp, :plot)
	if hasproperty(p, name)
		return getproperty(p, name)
	end
	return getfield(sp, name)
end

function Base.propertynames(sp::SyncPlot, private::Bool = false)
	fields = private ? fieldnames(SyncPlot) : (:plot, :app, :window, :divid)
	return (fields..., propertynames(getfield(sp, :plot), private)...)
end

_plotlyjs_refresh!(fig, data, layout) = nothing

"""
	to_syncplot(fig::Plot; app = nothing, width = 960, height = 720,
		title = "PlotlySupply", show = true, autoplay = true, timeout_s = 15)
	to_syncplot(sp::SyncPlot; kwargs...)

Convert a `Plot` into a [`SyncPlot`](@ref) displayed in a desktop Electron
window. Returns only after the initial Plotly render succeeds; `timeout_s`
bounds the renderer handshake after the window page loads, including frame
loading and autoplay. Calling `to_syncplot` on an existing `SyncPlot` returns
it unchanged.

Requires `ElectronCall.jl` (`import Pkg; Pkg.add("ElectronCall")`); PlotlySupply
loads it automatically when needed.
"""
to_syncplot(fig; kwargs...) = error(
	"`to_syncplot` requires ElectronCall.jl. " *
	"Install it once in your environment: `import Pkg; Pkg.add(\"ElectronCall\")`.",
)

"""
	plot(traces, layout = Layout(); config = PlotConfig(), frames = PlotlyFrame[], sync = false, kwargs...)
	plot(trace::AbstractTrace, layout::AbstractLayout = Layout(); kwargs...)
	plot(traces::AbstractTrace...; layout = Layout(), kwargs...)
	plot(fig::Plot; sync = false, kwargs...)
	plot(layout::AbstractLayout; kwargs...)

PlotlyJS-style figure constructor. `traces` is a single trace or vector of
traces (e.g. built with [`scatter`](@ref) or `attr`). Returns a
`PlotlyBase.Plot` by default; pass `sync = true` to open an Electron window and
return a [`SyncPlot`](@ref), forwarding extra keyword arguments such as
`width`, `height`, and `title` to [`to_syncplot`](@ref).

Desktop display requires `ElectronCall.jl`; headless `Plot` construction works
without it.
"""
plot(args...; kwargs...) = error(
	"`plot` compatibility API requires ElectronCall.jl. " *
	"Install it once in your environment: `import Pkg; Pkg.add(\"ElectronCall\")`.",
)

include("api.jl")
include("electron_backend.jl")
include("plotlyjs_compat.jl")

function __init__()
	# PlotlyBase owns the generic HTML/VS Code display paths. Keep its default
	# renderer aligned with the project-owned desktop/export artifact.
	PlotlyBase.set_plotly_version(_PLOTLYJS_VERSION)
	pushdisplay(ElectronDisplay())
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
export scattermap, choroplethmap, densitymap
export plot_scattermap, plot_scattermap!, plot_choroplethmap, plot_choroplethmap!, plot_densitymap, plot_densitymap!
export plot_scattermapbox, plot_scattermapbox!, plot_choroplethmapbox, plot_choroplethmapbox!, plot_densitymapbox, plot_densitymapbox!
export set_template!, get_default_template, set_default_template!
export set_legend!, get_default_legend_position, set_default_legend_position!
export xlabel!, ylabel!, xrange!, yrange!
export SyncPlot, SubplotFigure, plot, plot!, to_syncplot, msgchannel, toggle_devtools, savefig, make_subplots, subplots, subplot!, subplot_legends!, update_maps!, mgrid

end
