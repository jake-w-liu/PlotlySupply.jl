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

# Escape every "</" as "<\/" so no close-tag sequence (in any case, e.g.
# "</script", "</SCRIPT", "</Style") can break out of the inline <script> block.
# In a JS string literal "\/" decodes back to "/", so JSON semantics are intact.
_json_js(x) = replace(PlotlyBase.JSON.json(x; allownan = true), "</" => "<\\/")

# Build a well-formed file:// URI from an absolute local path. On Windows a
# drive-letter path needs a leading '/' and backslashes become forward slashes;
# spaces (common in temp paths) are percent-encoded so Chromium loads the file.
function _file_uri(path::AbstractString)
	p = replace(path, "\\" => "/")
	Sys.iswindows() && !startswith(p, "/") && (p = "/" * p)
	p = replace(p, " " => "%20")
	return "file://" * p
end

# Env vars that signal a CI / agent-sandbox environment where Electron's
# chrome-sandbox SUID helper is unavailable or local socket bind is blocked.
# `PLOTLYSUPPLY_DISABLE_ELECTRON_SANDBOX` is the explicit user escape hatch.
const _SANDBOX_ENV_VARS = (
	"GITHUB_ACTIONS", "CI",
	"CODEX_SANDBOX", "CODEX_AUTOMATION",
	"CLAUDE_CODE_SANDBOX", "AGENT_SANDBOX", "SANDBOX",
	"PLOTLYSUPPLY_DISABLE_ELECTRON_SANDBOX",
)

_is_sandboxed_env() = any(
	v -> lowercase(get(ENV, v, "")) in ("1", "true", "yes", "on"),
	_SANDBOX_ENV_VARS,
)

function _default_electron_app(ec)
	if _is_sandboxed_env() && isdefined(ec, :development_config)
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
  <script src="$_PLOTLY_CDN_URL" charset="utf-8" async></script>
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

	# Write HTML to a temp file and load via file:// URI.
	# ElectronCall converts HTML strings to data: URIs which have a ~2 MB
	# size limit in Chromium, causing blank windows for large datasets.
	tmpfile = tempname() * ".html"
	write(tmpfile, html)
	file_uri = _file_uri(tmpfile)

	win = Base.invokelatest(() -> ec.Window(
		electron_app,
		file_uri;
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
		try
			rm(tmpfile; force = true)
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

function _maybe_syncplot(fig::Plot; sync::Bool = false, kwargs...)
	return sync ? to_syncplot(fig; kwargs...) : fig
end

function plot(
	trace::AbstractTrace,
	layout::AbstractLayout = Layout();
	config::PlotConfig = PlotConfig(),
	sync::Bool = false,
	kwargs...,
)
	return _maybe_syncplot(Plot([trace], layout; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractVector{<:AbstractTrace},
	layout::AbstractLayout = Layout();
	config::PlotConfig = PlotConfig(),
	sync::Bool = false,
	kwargs...,
)
	return _maybe_syncplot(Plot(traces, layout; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractTrace...;
	layout::AbstractLayout = Layout(),
	config::PlotConfig = PlotConfig(),
	sync::Bool = false,
	kwargs...,
)
	return _maybe_syncplot(Plot(collect(traces), layout; config = config); sync = sync, kwargs...)
end

plot(fig::Plot; sync::Bool = false, kwargs...) = _maybe_syncplot(fig; sync = sync, kwargs...)

function plot(
	;
	layout::AbstractLayout = Layout(),
	config::PlotConfig = PlotConfig(),
	sync::Bool = false,
	kwargs...,
)
	empty_traces = Vector{GenericTrace}(undef, 0)
	return _maybe_syncplot(Plot(empty_traces, layout; config = config); sync = sync, kwargs...)
end

# Positional-layout form. `make_subplots` and other PlotlyJS-compat helpers call
# `plot(Layout(...))` with the layout passed positionally; without this method
# such calls fall through to the variadic error stub in PlotlySupply.jl.
plot(layout::AbstractLayout; kwargs...) = plot(; layout = layout, kwargs...)

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

# ── Auto-refresh infrastructure ─────────────────────────────────────
# Maps a displayed Plot to its SyncPlot so that mutating the Plot
# (react!, addtraces!, …) automatically refreshes the Electron window.
const _PLOT_SYNCPLOT_MAP = IdDict{Plot,SyncPlot}()

function _maybe_sync_refresh!(p::Plot)
	sp = get(_PLOT_SYNCPLOT_MAP, p, nothing)
	if sp !== nothing && isopen(sp)
		_plotlyjs_refresh!(sp, p.data, p.layout)
	end
	return nothing
end

# ── Internal mutation helpers (no display refresh) ──────────────────
# These replicate PlotlyBase's Plot-level logic so that both SyncPlot
# and Plot methods can share them without dispatch loops.

function _do_react!(p::Plot, data::AbstractVector{<:AbstractTrace}, layout)
	p.data = data
	p.layout = layout
	return p
end

function _do_addtraces!(p::Plot, traces::AbstractTrace...)
	push!(p.data, traces...)
	return p
end

function _do_addtraces!(p::Plot, i::Int, traces::AbstractTrace...)
	p.data = vcat(p.data[1:i-1], traces..., p.data[i:end])
	return p
end

function _do_deletetraces!(p::Plot, inds::Int...)
	deleteat!(p.data, inds)
	return p
end

function _do_relayout!(p::Plot, args...; kwargs...)
	relayout!(p.layout, args...; kwargs...)
	return p
end

function _do_restyle!(p::Plot, ind::Int, update::AbstractDict = Dict(); kwargs...)
	restyle!(p.data[ind], 1, update; kwargs...)
	return p
end

function _do_restyle!(p::Plot, inds::AbstractVector{Int}, update::AbstractDict = Dict(); kwargs...)
	N = length(inds)
	kw = Dict{Symbol,Any}(kwargs)
	for d in (kw, update)
		for (k, v) in d
			d[k] = PlotlyBase._prep_restyle_vec_setindex(v, N)
		end
	end
	map((ind, i) -> restyle!(p.data[ind], i, update; kw...), inds, 1:N)
	return p
end

function _do_restyle!(p::Plot, update::AbstractDict = Dict(); kwargs...)
	_do_restyle!(p, 1:length(p.data), update; kwargs...)
	return p
end

function _do_movetraces!(p::Plot, to_end::Int...)
	ii = collect(to_end)
	x = p.data[ii]
	append!(deleteat!(p.data, ii), x)
	return p
end

function _do_movetraces!(p::Plot, src::AbstractVector{Int}, dest::AbstractVector{Int})
	map((i, j) -> PlotlyBase._move_one!(p.data, i, j), src, dest)
	return p
end

function _do_extendtraces!(p::Plot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
	for (ix, p_ix) in enumerate(indices)
		tr = p.data[p_ix]
		for k in keys(update)
			v = update[k][ix]
			tr[k] = vcat(tr[k], v)
		end
	end
	return p
end

function _do_prependtraces!(p::Plot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
	for (ix, p_ix) in enumerate(indices)
		tr = p.data[p_ix]
		for k in keys(update)
			v = update[k][ix]
			tr[k] = vcat(v, tr[k])
		end
	end
	return p
end

function _do_update!(p::Plot, ind::Union{AbstractVector{Int},Int}, update::AbstractDict = Dict(); layout::AbstractLayout = p.layout, kwargs...)
	_do_relayout!(p; layout.fields...)
	_do_restyle!(p, ind, update; kwargs...)
	return p
end

function _do_update!(p::Plot, update = Dict(); layout::AbstractLayout = p.layout, kwargs...)
	_do_update!(p, 1:length(p.data), update; layout = layout, kwargs...)
	return p
end

function _do_update_xaxes!(p::Plot, args...; kwargs...)
	update_xaxes!(p.layout, args...; kwargs...)
	return p
end

function _do_update_yaxes!(p::Plot, args...; kwargs...)
	update_yaxes!(p.layout, args...; kwargs...)
	return p
end

function _do_update_polars!(p::Plot, args...; kwargs...)
	update_polars!(p.layout, args...; kwargs...)
	return p
end

# ── SyncPlot methods ────────────────────────────────────────────────
# Each method mutates via _do_*, then pushes the update to Electron.

function PlotlyBase.react!(sp::SyncPlot, data::AbstractVector{<:AbstractTrace}, layout::AbstractLayout)
	_do_react!(sp.plot, data, layout)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.react!(sp::SyncPlot, p::Plot)
	old = sp.plot
	sp.plot = p
	if haskey(_PLOT_SYNCPLOT_MAP, old)
		delete!(_PLOT_SYNCPLOT_MAP, old)
		_PLOT_SYNCPLOT_MAP[p] = sp
	end
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.relayout!(sp::SyncPlot, args...; kwargs...)
	_do_relayout!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.restyle!(sp::SyncPlot, ind::Int, update::AbstractDict = Dict(); kwargs...)
	_do_restyle!(sp.plot, ind, update; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.restyle!(sp::SyncPlot, inds::AbstractVector{Int}, update::AbstractDict = Dict(); kwargs...)
	_do_restyle!(sp.plot, inds, update; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.restyle!(sp::SyncPlot, update::AbstractDict = Dict(); kwargs...)
	_do_restyle!(sp.plot, update; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.addtraces!(sp::SyncPlot, traces::AbstractTrace...)
	_do_addtraces!(sp.plot, traces...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.addtraces!(sp::SyncPlot, i::Int, traces::AbstractTrace...)
	_do_addtraces!(sp.plot, i, traces...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.deletetraces!(sp::SyncPlot, inds::Int...)
	_do_deletetraces!(sp.plot, inds...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.movetraces!(sp::SyncPlot, to_end::Int...)
	_do_movetraces!(sp.plot, to_end...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.movetraces!(sp::SyncPlot, src::AbstractVector{Int}, dest::AbstractVector{Int})
	_do_movetraces!(sp.plot, src, dest)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.extendtraces!(sp::SyncPlot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
	_do_extendtraces!(sp.plot, update, indices, maxpoints)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.prependtraces!(sp::SyncPlot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
	_do_prependtraces!(sp.plot, update, indices, maxpoints)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update!(sp::SyncPlot, ind::Union{AbstractVector{Int},Int}, update::AbstractDict = Dict(); layout::AbstractLayout = sp.plot.layout, kwargs...)
	_do_update!(sp.plot, ind, update; layout = layout, kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update!(sp::SyncPlot, update = Dict(); layout::AbstractLayout = sp.plot.layout, kwargs...)
	_do_update!(sp.plot, update; layout = layout, kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update_xaxes!(sp::SyncPlot, args...; kwargs...)
	_do_update_xaxes!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update_yaxes!(sp::SyncPlot, args...; kwargs...)
	_do_update_yaxes!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.update_polars!(sp::SyncPlot, args...; kwargs...)
	_do_update_polars!(sp.plot, args...; kwargs...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

# ── Plot method overrides (auto-refresh for displayed plots) ────────
# When a Plot has been `display()`ed, these overrides push the mutation
# to the associated Electron window automatically.
# Installed at runtime via __init__() behind a precompilation guard so
# that downstream packages can precompile without triggering
# eval-into-closed-module or method-overwriting errors (Julia ≥ 1.12).

function _install_plot_method_overrides!()
	@eval function PlotlyBase.react!(p::Plot, data::AbstractVector{<:AbstractTrace}, layout::Layout)
		_do_react!(p, data, layout)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.relayout!(p::Plot, args...; kwargs...)
		_do_relayout!(p, args...; kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.restyle!(p::Plot, ind::Int, update::AbstractDict = Dict(); kwargs...)
		_do_restyle!(p, ind, update; kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.restyle!(p::Plot, inds::AbstractVector{Int}, update::AbstractDict = Dict(); kwargs...)
		_do_restyle!(p, inds, update; kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.restyle!(p::Plot, update::AbstractDict = Dict(); kwargs...)
		_do_restyle!(p, update; kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.addtraces!(p::Plot, traces::AbstractTrace...)
		_do_addtraces!(p, traces...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.addtraces!(p::Plot, i::Int, traces::AbstractTrace...)
		_do_addtraces!(p, i, traces...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.deletetraces!(p::Plot, inds::Int...)
		_do_deletetraces!(p, inds...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.movetraces!(p::Plot, to_end::Int...)
		_do_movetraces!(p, to_end...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.movetraces!(p::Plot, src::AbstractVector{Int}, dest::AbstractVector{Int})
		_do_movetraces!(p, src, dest)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.extendtraces!(p::Plot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
		_do_extendtraces!(p, update, indices, maxpoints)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.prependtraces!(p::Plot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
		_do_prependtraces!(p, update, indices, maxpoints)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.update!(p::Plot, ind::Union{AbstractVector{Int},Int}, update::AbstractDict = Dict(); layout::Layout = p.layout, kwargs...)
		_do_update!(p, ind, update; layout = layout, kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.update!(p::Plot, update = Dict(); layout::Layout = p.layout, kwargs...)
		_do_update!(p, update; layout = layout, kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.update_xaxes!(p::Plot, args...; kwargs...)
		_do_update_xaxes!(p, args...; kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.update_yaxes!(p::Plot, args...; kwargs...)
		_do_update_yaxes!(p, args...; kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	@eval function PlotlyBase.update_polars!(p::Plot, args...; kwargs...)
		_do_update_polars!(p, args...; kwargs...)
		_maybe_sync_refresh!(p)
		return p
	end

	return nothing
end

# ── Window lifecycle ────────────────────────────────────────────────

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
	# Deregister so the SyncPlot is no longer pinned by the auto-refresh
	# registries; once unreferenced its finalizer can run and reclaim the temp
	# HTML file. (We only prune on an explicit close — never on a possibly
	# transient isopen()==false — so a live window is never dropped by mistake.)
	filter!(x -> x !== sp, _DISPLAYED_PLOTS)
	for k in collect(keys(_PLOT_SYNCPLOT_MAP))
		_PLOT_SYNCPLOT_MAP[k] === sp && delete!(_PLOT_SYNCPLOT_MAP, k)
	end
	return nothing
end

# ── Display ─────────────────────────────────────────────────────────

struct ElectronDisplay <: AbstractDisplay end
const _DISPLAYED_PLOTS = SyncPlot[]

function Base.display(d::ElectronDisplay, p::Plot)
	# If this exact Plot was displayed before, close the stale window first so
	# re-displaying does not leak the previous SyncPlot/window/temp file.
	old = get(_PLOT_SYNCPLOT_MAP, p, nothing)
	old === nothing || close(old)
	sp = to_syncplot(p)
	_PLOT_SYNCPLOT_MAP[p] = sp
	push!(_DISPLAYED_PLOTS, sp)
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

# ── Hidden export window (for savefig) ──────────────────────────────

const _EXPORT_WINDOW = Ref{Any}(nothing)
const _EXPORT_APP = Ref{Any}(nothing)
const _EXPORT_DIVID = Ref{String}("plotlysupply-export")
# Path of the export window's temp HTML file, so it can be reclaimed when the
# window is recreated and at process exit (the persistent window holds it open
# while alive, so we must not rm it immediately).
const _EXPORT_TMPFILE = Ref{String}("")
const _EXPORT_ATEXIT_REGISTERED = Ref{Bool}(false)

function _export_window_html(divid::String)
	return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <style>
    @page { margin: 0; }
    html, body, #$divid { margin:0; padding:0; width:100%; height:100%; overflow:hidden; }
  </style>
</head>
<body>
  <div id="$divid"></div>
  <script src="$_PLOTLY_CDN_URL" charset="utf-8"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.9/MathJax.js?config=TeX-AMS-MML_SVG"></script>
</body>
</html>
"""
end

function _wait_for_plotly(ec, win; timeout_s::Float64 = 10.0)
	t0 = time()
	while time() - t0 < timeout_s
		try
			result = Base.invokelatest(() -> ec.run(win, "typeof Plotly !== 'undefined' ? 'ready' : 'waiting'"))
			result == "ready" && return true
		catch
		end
		sleep(0.05)
	end
	error("Plotly.js did not load in the export window within $(timeout_s)s")
end

function _ensure_export_window()
	ec = _electroncall()
	# Check if existing window is still alive
	win_alive = false
	if _EXPORT_WINDOW[] !== nothing
		try
			win_alive = Base.invokelatest(() -> ec.isopen(_EXPORT_WINDOW[]))
		catch
			win_alive = false
		end
	end

	if !win_alive
		app = _EXPORT_APP[]
		# Drop cached app if its underlying Electron process has died — otherwise
		# the next Window() call fails on a dead handle.
		if app !== nothing && hasproperty(app, :exists) && !app.exists
			app = nothing
			_EXPORT_APP[] = nothing
		end
		if app === nothing
			app = _default_electron_app(ec)
			_EXPORT_APP[] = app
		end
		divid = _EXPORT_DIVID[]
		html = _export_window_html(divid)
		# Reclaim the previous export HTML file (its window is gone) before
		# orphaning it, and ensure a single atexit hook removes the last one.
		isempty(_EXPORT_TMPFILE[]) || (try rm(_EXPORT_TMPFILE[]; force = true) catch end)
		tmpfile = tempname() * ".html"
		write(tmpfile, html)
		_EXPORT_TMPFILE[] = tmpfile
		if !_EXPORT_ATEXIT_REGISTERED[]
			atexit() do
				isempty(_EXPORT_TMPFILE[]) || (try rm(_EXPORT_TMPFILE[]; force = true) catch end)
			end
			_EXPORT_ATEXIT_REGISTERED[] = true
		end
		file_uri = _file_uri(tmpfile)
		win = Base.invokelatest(() -> ec.Window(
			app,
			file_uri;
			width = 960,
			height = 720,
			title = "PlotlySupply Export",
			show = false,
		))
		_EXPORT_WINDOW[] = win
		_wait_for_plotly(ec, win)
	end

	return (ec, _EXPORT_APP[], _EXPORT_WINDOW[], _EXPORT_DIVID[])
end
