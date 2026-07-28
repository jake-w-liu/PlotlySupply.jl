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

function _plotlyjs_newplot_script(
	p::Plot,
	divid::String;
	autoplay::Bool = true,
	purge::Bool = false,
)
	data_js = _json_js(p.data)
	layout_js = _json_js(p.layout)
	config_js = _json_js(p.config)
	frames_js = _json_js(p.frames)
	divid_js = _json_js(divid)
	purge_js = purge ? "Plotly.purge(div);" : ""
	autoplay_js = autoplay ? "true" : "false"

	return """
(async function() {
  if (typeof Plotly === "undefined") return "plotly-not-loaded";
  const div = document.getElementById($divid_js);
  if (!div) return "plot-div-not-found";
  const frames = $frames_js;
  $purge_js
  await Plotly.newPlot(div, $data_js, $layout_js, $config_js);
  if (frames.length > 0) {
    await Plotly.addFrames(div, frames);
    if ($autoplay_js) await Plotly.animate(div, null);
  }
  return "ok";
})()
"""
end

function _syncplot_html(p::Plot, divid::String; autoplay::Bool = true)
	newplot_js = _plotlyjs_newplot_script(p, divid; autoplay = autoplay)
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
        $newplot_js;
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
	autoplay::Bool = true,
)
	ec = _electroncall()
	electron_app = app === nothing ? _default_electron_app(ec) : app
	divid = _next_syncplot_id()
	html = _syncplot_html(p, divid; autoplay = autoplay)

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
	autoplay::Bool = true,
)
	return _create_syncplot_window(
		fig;
		app = app,
		width = width,
		height = height,
		title = title,
		show = show,
		autoplay = autoplay,
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
	frames::AbstractVector{<:PlotlyFrame} = PlotlyFrame[],
	sync::Bool = false,
	kwargs...,
)
	return _maybe_syncplot(Plot([trace], layout, frames; config = config); sync = sync, kwargs...)
end

function plot(
	trace::AbstractTrace,
	layout::AbstractLayout,
	frames::AbstractVector{<:PlotlyFrame};
	config::PlotConfig = PlotConfig(),
	sync::Bool = false,
	kwargs...,
)
	return _maybe_syncplot(Plot([trace], layout, frames; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractVector{<:AbstractTrace},
	layout::AbstractLayout = Layout();
	config::PlotConfig = PlotConfig(),
	frames::AbstractVector{<:PlotlyFrame} = PlotlyFrame[],
	sync::Bool = false,
	kwargs...,
)
	return _maybe_syncplot(Plot(traces, layout, frames; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractVector{<:AbstractTrace},
	layout::AbstractLayout,
	frames::AbstractVector{<:PlotlyFrame};
	config::PlotConfig = PlotConfig(),
	sync::Bool = false,
	kwargs...,
)
	return _maybe_syncplot(Plot(traces, layout, frames; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractTrace...;
	layout::AbstractLayout = Layout(),
	config::PlotConfig = PlotConfig(),
	frames::AbstractVector{<:PlotlyFrame} = PlotlyFrame[],
	sync::Bool = false,
	kwargs...,
)
	return _maybe_syncplot(Plot(collect(traces), layout, frames; config = config); sync = sync, kwargs...)
end

plot(fig::Plot; sync::Bool = false, kwargs...) = _maybe_syncplot(fig; sync = sync, kwargs...)

function plot(
	;
	layout::AbstractLayout = Layout(),
	config::PlotConfig = PlotConfig(),
	frames::AbstractVector{<:PlotlyFrame} = PlotlyFrame[],
	sync::Bool = false,
	kwargs...,
)
	empty_traces = Vector{GenericTrace}(undef, 0)
	return _maybe_syncplot(Plot(empty_traces, layout, frames; config = config); sync = sync, kwargs...)
end

# Positional-layout form. `make_subplots` and other PlotlyJS-compat helpers call
# `plot(Layout(...))` with the layout passed positionally; without this method
# such calls fall through to the variadic error stub in PlotlySupply.jl.
plot(layout::AbstractLayout; kwargs...) = plot(; layout = layout, kwargs...)
plot(layout::AbstractLayout, frames::AbstractVector{<:PlotlyFrame}; kwargs...) =
	plot(; layout = layout, frames = frames, kwargs...)

function _plotlyjs_refresh!(
	sp::SyncPlot,
	data,
	layout;
	rebuild::Bool = false,
	autoplay::Bool = false,
)
	isopen(sp) || return nothing

	js = if rebuild
		_plotlyjs_newplot_script(sp.plot, sp.divid; autoplay = autoplay, purge = true)
	else
		divid_js = _json_js(sp.divid)
		data_js = _json_js(data)
		layout_js = _json_js(layout)
		config_js = _json_js(sp.plot.config)
		"""
(function() {
  if (typeof Plotly === "undefined") return "plotly-not-loaded";
  const div = document.getElementById($divid_js);
  if (!div) return "plot-div-not-found";
  Plotly.react(div, $data_js, $layout_js, $config_js);
  return "ok";
})();
"""
	end
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

function _validate_trace_splice_args(
	p::Plot,
	update::AbstractDict,
	indices::AbstractVector{Int},
	maxpoints,
)
	allunique(indices) || throw(ArgumentError("`indices` must not contain duplicates."))
	for p_ix in indices
		checkbounds(Bool, p.data, p_ix) || throw(BoundsError(p.data, p_ix))
	end

	maxpoints_is_dict = maxpoints isa AbstractDict
	for (key, inserts) in update
		inserts isa AbstractVector ||
			throw(ArgumentError("update attribute $(repr(key)) must be a vector of per-trace vectors."))
		length(inserts) == length(indices) || throw(ArgumentError(
			"update attribute $(repr(key)) must contain one vector per trace index; " *
			"got $(length(inserts)) updates for $(length(indices)) indices.",
		))

		if maxpoints_is_dict
			haskey(maxpoints, key) || throw(ArgumentError(
				"`maxpoints` must contain an entry for update attribute $(repr(key)).",
			))
			limits = maxpoints[key]
			limits isa AbstractVector || throw(ArgumentError(
				"`maxpoints[$(repr(key))]` must be a vector with one limit per trace index.",
			))
			length(limits) == length(indices) || throw(ArgumentError(
				"`maxpoints[$(repr(key))]` must contain one limit per trace index; " *
				"got $(length(limits)) limits for $(length(indices)) indices.",
			))
		end

		for (ix, p_ix) in enumerate(indices)
			inserts[ix] isa AbstractVector || throw(ArgumentError(
				"update attribute $(repr(key)) at position $ix must be an `AbstractVector`.",
			))
			p.data[p_ix][key] isa AbstractVector || throw(ArgumentError(
				"cannot extend or prepend missing/non-vector trace attribute $(repr(key)) " *
				"on trace index $p_ix.",
			))
		end
	end
	return nothing
end

function _trace_window_limit(maxpoints, key, ix::Int)
	raw = maxpoints isa AbstractDict ? maxpoints[key][ix] : maxpoints
	(raw isa Real && isfinite(raw) && raw >= 0) || return nothing
	raw >= typemax(Int) && return typemax(Int)
	return floor(Int, raw)
end

function _copy_vector_segment!(
	dest::Vector,
	dest_start::Int,
	src::AbstractVector,
	src_start::Int,
	count::Int,
)
	@inbounds for offset in 0:(count - 1)
		dest[dest_start + offset] = src[src_start + offset]
	end
	return dest
end

function _windowed_concat(
	target::AbstractVector,
	insert::AbstractVector,
	limit::Union{Nothing, Int};
	prepend::Bool,
)
	limit === nothing && return prepend ? vcat(insert, target) : vcat(target, insert)

	total = Base.Checked.checked_add(length(target), length(insert))
	keep = min(limit, total)
	T = promote_type(eltype(target), eltype(insert))
	out = Vector{T}(undef, keep)
	keep == 0 && return out

	target_first = firstindex(target)
	insert_first = firstindex(insert)
	if prepend
		insert_count = min(keep, length(insert))
		_copy_vector_segment!(out, 1, insert, insert_first, insert_count)
		target_count = keep - insert_count
		target_count > 0 &&
			_copy_vector_segment!(out, insert_count + 1, target, target_first, target_count)
	else
		insert_count = min(keep, length(insert))
		target_count = keep - insert_count
		if target_count > 0
			target_start = target_first + length(target) - target_count
			_copy_vector_segment!(out, 1, target, target_start, target_count)
		end
		if insert_count > 0
			insert_start = insert_first + length(insert) - insert_count
			_copy_vector_segment!(out, target_count + 1, insert, insert_start, insert_count)
		end
	end
	return out
end

function _do_extendtraces!(p::Plot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
	_validate_trace_splice_args(p, update, indices, maxpoints)
	for (ix, p_ix) in enumerate(indices)
		tr = p.data[p_ix]
		for k in keys(update)
			v = update[k][ix]
			limit = _trace_window_limit(maxpoints, k, ix)
			tr[k] = _windowed_concat(tr[k], v, limit; prepend = false)
		end
	end
	return p
end

function _do_prependtraces!(p::Plot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
	_validate_trace_splice_args(p, update, indices, maxpoints)
	for (ix, p_ix) in enumerate(indices)
		tr = p.data[p_ix]
		for k in keys(update)
			v = update[k][ix]
			limit = _trace_window_limit(maxpoints, k, ix)
			tr[k] = _windowed_concat(tr[k], v, limit; prepend = true)
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
	_plotlyjs_refresh!(
		sp,
		sp.plot.data,
		sp.plot.layout;
		rebuild = true,
		autoplay = true,
	)
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
