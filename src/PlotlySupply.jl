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
with [`to_syncplot`](@ref), `plot(...; sync = true)`, any high-level `plot_*`
constructor with `show = true`, or [`subplots`](@ref) with `sync = true` (its
default; the window is hidden when `show = false`).

Mutating calls (`plot_*!`, `relayout!`, `restyle!`, `add_trace!`, …) committed
on a `SyncPlot` refresh the open window transactionally. `sp.plot` is the
wrapped `Plot`; `sp.app`, `sp.window`, and `sp.divid` expose the underlying
Electron objects, and any other property access forwards to `sp.plot` (e.g.
`sp.data`, `sp.layout`).

Lifecycle: `close(sp)` closes the window and deletes its temporary files, and
`isopen(sp)` reports whether the window is still open. A visible window stays
open until the user closes it or `close(sp)` is called, even when no variable
refers to its `SyncPlot` any more. A hidden window (`show = false`) is closed
automatically once its `SyncPlot` has become unreachable and been
garbage-collected.

LaTeX labels such as `"\$x^2\$"` are typeset with MathJax in the window, as
in [`savefig`](@ref); MathJax is loaded from a CDN, so without network access
such labels are shown as plain text. See also [`msgchannel`](@ref) and
[`toggle_devtools`](@ref).
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
	# `Plot` has its own `divid`, shadowed by the SyncPlot field of that name;
	# list every name once.
	forwarded = filter(
		name -> !(name in fields),
		propertynames(getfield(sp, :plot), private),
	)
	return (fields..., forwarded...)
end

"""
	to_syncplot(fig::Plot; app = nothing, width = 960, height = 720,
		title = "PlotlySupply", show = true, autoplay = true, timeout_s = 15)
	to_syncplot(sp::SyncPlot; window options...)

Open `fig` in a desktop Electron window and return the live
[`SyncPlot`](@ref) that drives it. The call returns once the initial Plotly
render has succeeded.

# Keywords
- `app = nothing`: the ElectronCall `Application` that hosts the window;
  `nothing` uses PlotlySupply's shared default application.
- `width::Real = 960`, `height::Real = 720`: window size in pixels, rounded to
  whole pixels. `0` selects the default; negative, non-finite or sub-pixel
  sizes throw an `ArgumentError`.
- `title::AbstractString = "PlotlySupply"`: window title (`""` selects the
  default).
- `show::Bool = true`: show the window. `false` creates a hidden window, e.g.
  for scripted image capture with `to_image(sp)`.
- `autoplay::Bool = true`: start playing the figure's animation frames once the
  window is ready. Playback runs in the background and does not delay the
  return.
- `timeout_s::Real = 15`: bound in seconds on the renderer handshake after the
  window page has loaded (loading plotly.js, `Plotly.newPlot` and frame
  registration; not playback). Must be finite and non-negative.

Calling `to_syncplot` on an existing `SyncPlot` validates the keywords and
returns it unchanged, since its window already exists. Any other argument
throws an `ArgumentError`; for a [`SubplotFigure`](@ref) use
`subplots(...; sync = true)` or `display(sf)`.

The window lives until it is closed by the user or with `close(sp)`; see
[`SyncPlot`](@ref) for the lifecycle of unreferenced windows.

# Example
```julia
sp = to_syncplot(plot_scatter(1:3, [1, 4, 9]); title = "Squares")
relayout!(sp; title = "Squares, updated")
close(sp)
```
"""
function to_syncplot end

"""
	plot(trace::AbstractTrace, layout::AbstractLayout[, frames]; kwargs...)
	plot(traces::AbstractTrace...; layout = Layout(), kwargs...)
	plot(traces::AbstractVector[, layout::AbstractLayout[, frames]]; kwargs...)
	plot(layout::AbstractLayout[, frames]; kwargs...)
	plot(; layout = Layout(), kwargs...)
	plot(fig::Plot; sync = false, window options...)

PlotlyJS-style figure constructor. Builds a `PlotlyBase.Plot` from traces
(e.g. [`scatter`](@ref)), a layout and animation frames (built with `frame`).
With `sync = true` it opens the figure in an Electron window and returns a
[`SyncPlot`](@ref) instead.

`traces` may be any vector whose elements are all traces, including an untyped
`Vector{Any}` filled with `push!`; a `Vector{<:AbstractTrace}` is used without
copying. `frames` likewise accepts any vector of frames. `plot(fig::Plot)`
returns `fig` itself, or its window with `sync = true`.

# Keywords
- `layout::AbstractLayout = Layout()`: figure layout, when not given
  positionally.
- `frames::AbstractVector = PlotlyFrame[]`: animation frames, when not given
  positionally.
- `config::PlotConfig = PlotConfig()`: Plotly configuration.
- `sync::Bool = false`: open the figure in a window (see
  [`to_syncplot`](@ref)).
- `app`, `width`, `height`, `title`, `show`, `autoplay`, `timeout_s`: the
  window options of [`to_syncplot`](@ref). They are validated on every call
  and applied only with `sync = true`.

Passing `layout`, `frames` or `config` as a keyword when the same argument was
given positionally, or together with a prebuilt `Plot`, throws an
`ArgumentError`, as does any other keyword or an unsupported positional
argument. To plot data vectors directly use [`plot_scatter`](@ref) or another
`plot_*` function. `plot` applies no PlotlySupply template: the figure uses
PlotlyBase's defaults.

# Example
```julia
fig = plot([scatter(y = [1, 3, 2]), bar(y = [2, 1, 3])]; layout = Layout(title = "Mixed"))
sp = plot(scatter(y = [1, 2]); sync = true, title = "Window")
close(sp)
```
"""
function plot end

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
