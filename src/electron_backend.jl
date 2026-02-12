const _PLOTLY_CDN_URL = "https://cdn.plot.ly/plotly-2.35.2.min.js"
const _ELECTRONCALL_PKGID = Base.PkgId(Base.UUID("8ddd578f-0c94-4c64-8c65-f083f291b266"), "ElectronCall")
const _SYNC_ID_COUNTER = Ref(0)

function _electroncall()
	try
		return Base.root_module(_ELECTRONCALL_PKGID)
	catch
		try
			Base.require(_ELECTRONCALL_PKGID)
			return Base.root_module(_ELECTRONCALL_PKGID)
		catch
			error(
				"ElectronCall.jl is required for desktop SyncPlot windows. " *
				"Run `import Pkg; Pkg.add(\"ElectronCall\")` once in your environment.",
			)
		end
	end
end

_json_js(x) = replace(PlotlyBase.JSON.json(x; allownan = true), "</script" => "<\\/script")

_is_linux_github_actions_ci() =
	Sys.islinux() && get(ENV, "GITHUB_ACTIONS", "") == "true"

function _default_electron_app(ec)
	# GitHub Linux runners usually lack SUID sandbox setup for Electron.
	# Use ElectronCall's CI-friendly security config only in that environment.
	if _is_linux_github_actions_ci() && isdefined(ec, :development_config)
		security = Base.invokelatest(() -> ec.development_config())
		return Base.invokelatest(() -> ec.default_application(security))
	end
	return Base.invokelatest(() -> ec.default_application())
end

function _next_syncplot_id()
	_SYNC_ID_COUNTER[] += 1
	return "plotsupply-" * string(_SYNC_ID_COUNTER[]) * "-" * string(time_ns())
end

function _syncplot_html(p::Plot, divid::String)
	data_js = _json_js(p.data)
	layout_js = _json_js(p.layout)
	config_js = _json_js(p.config)

	return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>PlotlySupply</title>
  <style>
    html, body, #$divid {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
    }
  </style>
</head>
<body>
  <div id="$divid"></div>
  <script src="$_PLOTLY_CDN_URL" charset="utf-8"></script>
  <script>
    (function() {
      function boot() {
        if (typeof Plotly === "undefined") {
          setTimeout(boot, 25);
          return;
        }
        Plotly.newPlot("$divid", $data_js, $layout_js, $config_js);
      }
      boot();
    })();
  </script>
</body>
</html>
"""
end

function _create_syncplot_window(
	p::Plot;
	app = nothing,
	width::Int = 960,
	height::Int = 720,
	title::String = "PlotlySupply",
	show::Bool = true,
)
	ec = _electroncall()
	electron_app = app === nothing ? _default_electron_app(ec) : app
	divid = _next_syncplot_id()
	html = _syncplot_html(p, divid)
	win = Base.invokelatest(() -> ec.Window(
		electron_app,
		html;
		width = width,
		height = height,
		title = title,
		show = show,
	))
	sp = SyncPlot(p, electron_app, win, divid)
	finalizer(sp) do obj
		try
			close(obj)
		catch
		end
	end
	return sp
end

function to_syncplot(
	fig::Plot;
	app = nothing,
	width::Int = 960,
	height::Int = 720,
	title::String = "PlotlySupply",
	show::Bool = true,
)
	return _create_syncplot_window(
		fig;
		app = app,
		width = width,
		height = height,
		title = title,
		show = show,
	)
end

to_syncplot(sp::SyncPlot; kwargs...) = sp

function _maybe_syncplot(fig::Plot; sync::Bool = true, kwargs...)
	return sync ? to_syncplot(fig; kwargs...) : fig
end

function plot(
	trace::AbstractTrace,
	layout::AbstractLayout = Layout();
	config::PlotConfig = PlotConfig(),
	sync::Bool = true,
	kwargs...,
)
	return _maybe_syncplot(Plot([trace], layout; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractVector{<:AbstractTrace},
	layout::AbstractLayout = Layout();
	config::PlotConfig = PlotConfig(),
	sync::Bool = true,
	kwargs...,
)
	return _maybe_syncplot(Plot(traces, layout; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractTrace...;
	layout::AbstractLayout = Layout(),
	config::PlotConfig = PlotConfig(),
	sync::Bool = true,
	kwargs...,
)
	return _maybe_syncplot(Plot(collect(traces), layout; config = config); sync = sync, kwargs...)
end

plot(fig::Plot; sync::Bool = true, kwargs...) = _maybe_syncplot(fig; sync = sync, kwargs...)

function plot(
	;
	layout::AbstractLayout = Layout(),
	config::PlotConfig = PlotConfig(),
	sync::Bool = true,
	kwargs...,
)
	empty_traces = Vector{GenericTrace}(undef, 0)
	return _maybe_syncplot(Plot(empty_traces, layout; config = config); sync = sync, kwargs...)
end

function _plotlyjs_refresh!(sp::SyncPlot, data, layout)
	isopen(sp) || return nothing

	divid_js = _json_js(sp.divid)
	data_js = _json_js(data)
	layout_js = _json_js(layout)
	config_js = _json_js(sp.plot.config)

	js = """
(function() {
  if (typeof Plotly === "undefined") return "plotly-not-loaded";
  const div = document.getElementById($divid_js);
  if (!div) return "plot-div-not-found";
  Plotly.react(div, $data_js, $layout_js, $config_js);
  return "ok";
})();
"""
	try
		ec = _electroncall()
		Base.invokelatest(() -> ec.run(sp.window, js))
	catch err
		@warn "Failed to refresh SyncPlot window." exception = (err, catch_backtrace())
	end
	return nothing
end

function PlotlyBase.react!(sp::SyncPlot, data::AbstractVector{<:AbstractTrace}, layout::AbstractLayout)
	sp.plot = Plot(data, layout; config = sp.plot.config)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.react!(sp::SyncPlot, p::Plot)
	sp.plot = p
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.relayout!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.relayout!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.restyle!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.restyle!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.addtraces!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.addtraces!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.deletetraces!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.deletetraces!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.movetraces!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.movetraces!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.extendtraces!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.extendtraces!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.prependtraces!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.prependtraces!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.update!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update_xaxes!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.update_xaxes!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update_yaxes!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.update_yaxes!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update_polars!(sp::SyncPlot, args...; kwargs...)
	PlotlyBase.update_polars!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

Base.isopen(sp::SyncPlot) = try
	ec = _electroncall()
	Base.invokelatest(() -> ec.isopen(sp.window))
catch
	false
end

function Base.close(sp::SyncPlot)
	if isopen(sp)
		ec = _electroncall()
		Base.invokelatest(() -> ec.close(sp.window))
	end
	return nothing
end

function Base.show(io::IO, sp::SyncPlot)
	state = isopen(sp) ? "open" : "closed"
	print(io, "SyncPlot($state, div=\"$(sp.divid)\")")
end

function msgchannel(sp::SyncPlot)
	ec = _electroncall()
	return Base.invokelatest(() -> ec.msgchannel(sp.window))
end

function toggle_devtools(sp::SyncPlot)
	ec = _electroncall()
	return Base.invokelatest(() -> ec.toggle_devtools(sp.window))
end
