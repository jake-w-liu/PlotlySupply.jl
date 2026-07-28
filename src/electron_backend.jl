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

const _SYNC_WINDOW_WATCH_INTERVAL_SECONDS = 0.05

function _syncplot_native_window_closed(window, message_channel)
	try
		if hasproperty(window, :exists)
			return getproperty(window, :exists) === false
		end
	catch
	end

	if message_channel !== nothing
		try
			return !isopen(message_channel)
		catch
		end
	end
	return false
end

function _watch_syncplot_window!(sp::SyncPlot, ec)
	weak_sp = WeakRef(sp)
	window = getfield(sp, :window)
	message_channel = try
		Base.invokelatest(() -> ec.msgchannel(window))
	catch
		nothing
	end

	task = @async begin
		while !_syncplot_native_window_closed(window, message_channel)
			# Inspect the weak reference only before yielding and never retain its
			# value in a local across sleep. This lets an otherwise-unreferenced
			# SyncPlot reach its finalizer while the watcher is active.
			isnothing(weak_sp.value) && return nothing
			sleep(_SYNC_WINDOW_WATCH_INTERVAL_SECONDS)
		end

		obj = weak_sp.value
		if obj !== nothing
			try
				close(obj)
			catch err
				@warn "Failed to release a natively closed SyncPlot." exception = (
					err,
					catch_backtrace(),
				)
			finally
				obj = nothing
			end
		end
		return nothing
	end
	errormonitor(task)
	return nothing
end

function _finalize_syncplot!(sp::SyncPlot)
	try
		close(sp)
	catch
	end
	return nothing
end

function _create_syncplot_window(
	p::Plot;
	kwargs...,
)
	return _create_syncplot_window(_electroncall(), p; kwargs...)
end

function _create_syncplot_window(
	ec,
	p::Plot;
	app = nothing,
	width::Int = 960,
	height::Int = 720,
	title::String = "PlotlySupply",
	show::Bool = true,
	autoplay::Bool = true,
)
	electron_app = app === nothing ? _default_electron_app(ec) : app
	divid = _next_syncplot_id()
	html = _syncplot_html(p, divid; autoplay = autoplay)

	# Own a dedicated temp directory and load its index via file://. ElectronCall
	# converts HTML strings to data: URIs which have a ~2 MB size limit in
	# Chromium, causing blank windows for large datasets.
	tempdir = mktempdir(; prefix = "plotlysupply-sync-")
	tmpfile = joinpath(tempdir, "index.html")
	window = nothing
	sp = nothing
	try
		write(tmpfile, html)
		file_uri = _file_uri(tmpfile)

		window = Base.invokelatest(() -> ec.Window(
			electron_app,
			file_uri;
			width = width,
			height = height,
			title = title,
			show = show,
		))
		resources = _SyncPlotResources(tempdir, ec)
		sp = SyncPlot(p, electron_app, window, divid, resources)
		finalizer(_finalize_syncplot!, sp)
		_watch_syncplot_window!(sp, ec)
		return sp
	catch
		if sp !== nothing
			try
				close(sp)
			catch cleanup_error
				@warn "Failed to close a partially constructed SyncPlot." exception = (
					cleanup_error,
					catch_backtrace(),
				)
			end
		elseif window !== nothing
			# This exact window was created in the transaction above, so it is
			# safe to close here even if setup failed before SyncPlot existed.
			try
				Base.invokelatest(() -> ec.close(window))
			catch cleanup_error
				@warn "Failed to close a partially constructed Electron window." exception = (
					cleanup_error,
					catch_backtrace(),
				)
			end
		end

		if ispath(tempdir)
			try
				rm(tempdir; recursive = true, force = true)
			catch cleanup_error
				@warn "Failed to remove a partially constructed SyncPlot temp directory." exception = (
					cleanup_error,
					catch_backtrace(),
				)
			end
		end
		rethrow()
	end
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
const _SYNCPLOT_REGISTRY_LOCK = ReentrantLock()
const _PLOT_SYNCPLOT_MAP = IdDict{Plot,SyncPlot}()
const _DISPLAYED_PLOTS = SyncPlot[]

function _maybe_sync_refresh!(p::Plot)
	sp = lock(_SYNCPLOT_REGISTRY_LOCK) do
		get(_PLOT_SYNCPLOT_MAP, p, nothing)
	end
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

# Copy only containers that PlotlyBase's setters can mutate. Large array
# payloads remain shared because restyle/relayout replace them rather than
# mutating their elements.
_copy_mutation_container(value) =
	_copy_mutation_container(value, IdDict{Any,Any}())
_copy_mutation_container(value, ::IdDict{Any,Any}) = value

function _copy_mutation_container(
	value::AbstractDict,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	staged = copy(value)
	memo[value] = staged
	for (key, child) in value
		staged[key] = _copy_mutation_container(child, memo)
	end
	return staged
end

function _copy_mutation_container(
	value::PlotlyBase.AbstractPlotlyAttribute,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	staged = typeof(value)(_copy_mutation_container(value.fields, memo))
	memo[value] = staged
	return staged
end

_clone_trace_for_mutation(trace::GenericTrace) =
	GenericTrace(_copy_mutation_container(trace.fields))
_clone_trace_for_mutation(trace::AbstractTrace) = deepcopy(trace)

function _clone_layout_for_mutation(layout::Layout)
	fields = _copy_mutation_container(layout.fields)
	staged = Layout(fields)
	# Layout's public constructor merges defaults. Restore the exact cloned
	# dictionary so staging cannot reintroduce a field the caller removed.
	setfield!(staged, :fields, fields)
	return staged
end
_clone_layout_for_mutation(layout::AbstractLayout) = deepcopy(layout)

function _prepare_restyle_inputs(
	update::AbstractDict,
	kwargs,
	trace_count::Int;
	vectorized::Bool,
)
	# Widen the copied dictionary so vector preparation can replace narrowly
	# typed values without changing the caller's object.
	prepared_update = Dict{Any,Any}(pairs(update))
	prepared_kwargs = Dict{Symbol,Any}(kwargs)
	if vectorized
		for values in (prepared_update, prepared_kwargs)
			for (key, value) in values
				values[key] =
					PlotlyBase._prep_restyle_vec_setindex(value, trace_count)
			end
		end
	end
	return prepared_update, prepared_kwargs
end

function _stage_restyle(
	p::Plot,
	inds,
	update::AbstractDict,
	kwargs;
	vectorized::Bool,
)
	for ind in inds
		checkbounds(Bool, p.data, ind) || throw(BoundsError(p.data, ind))
	end

	prepared_update, prepared_kwargs = _prepare_restyle_inputs(
		update,
		kwargs,
		length(inds);
		vectorized = vectorized,
	)

	# Stage a shared trace only once so aliased entries retain their sequential
	# restyle behavior.
	staged = IdDict{AbstractTrace,AbstractTrace}()
	for (position, ind) in enumerate(inds)
		original = p.data[ind]
		trace = get!(
			() -> _clone_trace_for_mutation(original),
			staged,
			original,
		)
		restyle!(trace, position, prepared_update; prepared_kwargs...)
	end
	return staged
end

function _commit_restyle!(
	p::Plot,
	staged::IdDict{AbstractTrace,AbstractTrace},
)
	# Standard traces keep their identity by swapping the successfully staged
	# field dictionary. Third-party trace implementations are replaced only
	# after every staged update succeeds.
	replacement_data = nothing
	for (original, _) in staged
		if !(original isa GenericTrace)
			replacement_data = copy(p.data)
			break
		end
	end
	if replacement_data !== nothing
		for ind in eachindex(replacement_data)
			original = p.data[ind]
			if !(original isa GenericTrace) && haskey(staged, original)
				replacement_data[ind] = staged[original]
			end
		end
		copyto!(p.data, replacement_data)
	end
	for (original, trace) in staged
		if original isa GenericTrace
			setfield!(original, :fields, getfield(trace, :fields))
		end
	end
	return p
end

function _commit_layout!(p::Plot, staged::AbstractLayout)
	if p.layout isa Layout && staged isa Layout
		# Preserve Layout identity and its Subplots routing metadata.
		setfield!(p.layout, :fields, staged.fields)
	else
		setfield!(p, :layout, staged)
	end
	return p
end

function _do_restyle!(
	p::Plot,
	ind::Int,
	update::AbstractDict = Dict();
	kwargs...,
)
	staged = _stage_restyle(
		p,
		(ind,),
		update,
		kwargs;
		vectorized = false,
	)
	_commit_restyle!(p, staged)
	return p
end

function _do_restyle!(
	p::Plot,
	inds::AbstractVector{Int},
	update::AbstractDict = Dict();
	kwargs...,
)
	staged = _stage_restyle(
		p,
		inds,
		update,
		kwargs;
		vectorized = true,
	)
	_commit_restyle!(p, staged)
	return p
end

function _do_restyle!(p::Plot, update::AbstractDict = Dict(); kwargs...)
	return _do_restyle!(p, 1:length(p.data), update; kwargs...)
end

function _do_movetraces!(p::Plot, to_end::Int...)
	staged = copy(p.data)
	inds = collect(to_end)
	moved = staged[inds]
	append!(deleteat!(staged, inds), moved)
	copyto!(p.data, staged)
	return p
end

function _do_movetraces!(
	p::Plot,
	src::AbstractVector{Int},
	dest::AbstractVector{Int},
)
	length(src) == length(dest) || throw(DimensionMismatch(
		"`src` and `dest` must contain the same number of indices.",
	))
	for ind in src
		checkbounds(Bool, p.data, ind) || throw(BoundsError(p.data, ind))
	end
	for ind in dest
		checkbounds(Bool, p.data, ind) || throw(BoundsError(p.data, ind))
	end

	staged = copy(p.data)
	for (from, to) in zip(src, dest)
		PlotlyBase._move_one!(staged, from, to)
	end
	copyto!(p.data, staged)
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

function _do_trace_splice!(
	p::Plot,
	update::AbstractDict,
	indices::AbstractVector{Int},
	maxpoints;
	prepend::Bool,
)
	_validate_trace_splice_args(p, update, indices, maxpoints)
	(isempty(indices) || isempty(update)) && return p

	# The overwhelmingly common one-trace/one-attribute case is already
	# transactional when its one result is computed before assignment. Avoid
	# allocating the general staging table for that path.
	if length(indices) == 1 && length(update) == 1
		p_ix = only(indices)
		k = only(keys(update))
		v = update[k][1]
		limit = _trace_window_limit(maxpoints, k, 1)
		staged = _windowed_concat(
			p.data[p_ix][k],
			v,
			limit;
			prepend = prepend,
		)
		p.data[p_ix][k] = staged
		return p
	end

	update_keys = collect(keys(update))
	staged = Matrix{Any}(undef, length(update_keys), length(indices))
	for (ix, p_ix) in enumerate(indices)
		tr = p.data[p_ix]
		for (key_ix, k) in enumerate(update_keys)
			v = update[k][ix]
			limit = _trace_window_limit(maxpoints, k, ix)
			staged[key_ix, ix] =
				_windowed_concat(tr[k], v, limit; prepend = prepend)
		end
	end

	# Do not publish any attribute until every input has been materialized
	# successfully. GenericTrace assignment is non-validating, so this commit
	# loop cannot expose a partially staged input failure.
	for (ix, p_ix) in enumerate(indices)
		tr = p.data[p_ix]
		for (key_ix, k) in enumerate(update_keys)
			tr[k] = staged[key_ix, ix]
		end
	end
	return p
end

function _do_extendtraces!(
	p::Plot,
	update::AbstractDict,
	indices::AbstractVector{Int} = [1],
	maxpoints = -1,
)
	return _do_trace_splice!(
		p,
		update,
		indices,
		maxpoints;
		prepend = false,
	)
end

function _do_prependtraces!(
	p::Plot,
	update::AbstractDict,
	indices::AbstractVector{Int} = [1],
	maxpoints = -1,
)
	return _do_trace_splice!(
		p,
		update,
		indices,
		maxpoints;
		prepend = true,
	)
end

_trace_splice_tovec(value) = [[value]]
_trace_splice_tovec(value::AbstractVector) = [value]
_trace_splice_tovec(value::AbstractVector{<:AbstractVector}) = value

function _trace_splice_keyword_update(update)
	return Dict(
		key => _trace_splice_tovec(value)
		for (key, value) in pairs(update)
	)
end

function _do_update!(
	p::Plot,
	ind::Union{AbstractVector{Int},Int},
	update::AbstractDict = Dict();
	layout::AbstractLayout = p.layout,
	kwargs...,
)
	# Commit neither side until layout and trace staging both succeed.
	staged_layout = _clone_layout_for_mutation(p.layout)
	relayout!(staged_layout; layout.fields...)
	inds = ind isa Int ? (ind,) : ind
	staged_traces = _stage_restyle(
		p,
		inds,
		update,
		kwargs;
		vectorized = !(ind isa Int),
	)

	_commit_restyle!(p, staged_traces)
	_commit_layout!(p, staged_layout)
	return p
end

function _do_update!(p::Plot, update = Dict(); layout::AbstractLayout = p.layout, kwargs...)
	return _do_update!(
		p,
		1:length(p.data),
		update;
		layout = layout,
		kwargs...,
	)
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
	lock(_SYNCPLOT_REGISTRY_LOCK) do
		if get(_PLOT_SYNCPLOT_MAP, old, nothing) === sp
			delete!(_PLOT_SYNCPLOT_MAP, old)
			_PLOT_SYNCPLOT_MAP[p] = sp
		end
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

function PlotlyBase.extendtraces!(
	sp::SyncPlot,
	indices::Vector{Int} = [1],
	maxpoints = -1;
	update...,
)
	converted = _trace_splice_keyword_update(update)
	return PlotlyBase.extendtraces!(sp, converted, indices, maxpoints)
end

function PlotlyBase.extendtraces!(
	sp::SyncPlot,
	indices::AbstractVector{Int},
	maxpoints = -1;
	update...,
)
	converted = _trace_splice_keyword_update(update)
	return PlotlyBase.extendtraces!(sp, converted, indices, maxpoints)
end

function PlotlyBase.extendtraces!(
	sp::SyncPlot,
	index::Int,
	maxpoints = -1;
	update...,
)
	return PlotlyBase.extendtraces!(sp, [index], maxpoints; update...)
end

function PlotlyBase.extendtraces!(
	sp::SyncPlot,
	update::AbstractDict,
	index::Int,
	maxpoints = -1,
)
	return PlotlyBase.extendtraces!(sp, update, [index], maxpoints)
end

function PlotlyBase.prependtraces!(sp::SyncPlot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
	_do_prependtraces!(sp.plot, update, indices, maxpoints)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.prependtraces!(
	sp::SyncPlot,
	indices::Vector{Int} = [1],
	maxpoints = -1;
	update...,
)
	converted = _trace_splice_keyword_update(update)
	return PlotlyBase.prependtraces!(sp, converted, indices, maxpoints)
end

function PlotlyBase.prependtraces!(
	sp::SyncPlot,
	indices::AbstractVector{Int},
	maxpoints = -1;
	update...,
)
	converted = _trace_splice_keyword_update(update)
	return PlotlyBase.prependtraces!(sp, converted, indices, maxpoints)
end

function PlotlyBase.prependtraces!(
	sp::SyncPlot,
	index::Int,
	maxpoints = -1;
	update...,
)
	return PlotlyBase.prependtraces!(sp, [index], maxpoints; update...)
end

function PlotlyBase.prependtraces!(
	sp::SyncPlot,
	update::AbstractDict,
	index::Int,
	maxpoints = -1,
)
	return PlotlyBase.prependtraces!(sp, update, [index], maxpoints)
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

# ── Plot auto-refresh methods ───────────────────────────────────────
# Restrict these additions to the concrete vector-backed Plot shape emitted by
# PlotlySupply. They remain more specific than PlotlyBase's Plot methods, so
# loading this package adds dispatch without replacing methods owned upstream.
const _RefreshablePlot = Plot{TT, TL, TF} where {
	TT <: Vector{<:AbstractTrace},
	TL <: Layout,
	TF <: Vector{<:PlotlyFrame},
}

function PlotlyBase.react!(
	p::_RefreshablePlot,
	data::AbstractVector{<:AbstractTrace},
	layout::Layout,
)
	_do_react!(p, data, layout)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.relayout!(p::_RefreshablePlot, args...; kwargs...)
	_do_relayout!(p, args...; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.restyle!(
	p::_RefreshablePlot,
	ind::Int,
	update::AbstractDict = Dict();
	kwargs...,
)
	_do_restyle!(p, ind, update; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.restyle!(
	p::_RefreshablePlot,
	inds::AbstractVector{Int},
	update::AbstractDict = Dict();
	kwargs...,
)
	_do_restyle!(p, inds, update; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.restyle!(
	p::_RefreshablePlot,
	update::AbstractDict = Dict();
	kwargs...,
)
	_do_restyle!(p, update; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.addtraces!(p::_RefreshablePlot, traces::AbstractTrace...)
	_do_addtraces!(p, traces...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.addtraces!(
	p::_RefreshablePlot,
	i::Int,
	traces::AbstractTrace...,
)
	_do_addtraces!(p, i, traces...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.deletetraces!(p::_RefreshablePlot, inds::Int...)
	_do_deletetraces!(p, inds...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.movetraces!(p::_RefreshablePlot, to_end::Int...)
	_do_movetraces!(p, to_end...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.movetraces!(
	p::_RefreshablePlot,
	src::AbstractVector{Int},
	dest::AbstractVector{Int},
)
	_do_movetraces!(p, src, dest)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.extendtraces!(
	p::_RefreshablePlot,
	update::AbstractDict,
	indices::AbstractVector{Int} = [1],
	maxpoints = -1,
)
	_do_extendtraces!(p, update, indices, maxpoints)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.extendtraces!(
	p::_RefreshablePlot,
	indices::Vector{Int} = [1],
	maxpoints = -1;
	update...,
)
	converted = _trace_splice_keyword_update(update)
	return PlotlyBase.extendtraces!(p, converted, indices, maxpoints)
end

function PlotlyBase.extendtraces!(
	p::_RefreshablePlot,
	indices::AbstractVector{Int},
	maxpoints = -1;
	update...,
)
	converted = _trace_splice_keyword_update(update)
	return PlotlyBase.extendtraces!(p, converted, indices, maxpoints)
end

function PlotlyBase.extendtraces!(
	p::_RefreshablePlot,
	index::Int,
	maxpoints = -1;
	update...,
)
	return PlotlyBase.extendtraces!(p, [index], maxpoints; update...)
end

function PlotlyBase.extendtraces!(
	p::_RefreshablePlot,
	update::AbstractDict,
	index::Int,
	maxpoints = -1,
)
	return PlotlyBase.extendtraces!(p, update, [index], maxpoints)
end

function PlotlyBase.prependtraces!(
	p::_RefreshablePlot,
	update::AbstractDict,
	indices::AbstractVector{Int} = [1],
	maxpoints = -1,
)
	_do_prependtraces!(p, update, indices, maxpoints)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.prependtraces!(
	p::_RefreshablePlot,
	indices::Vector{Int} = [1],
	maxpoints = -1;
	update...,
)
	converted = _trace_splice_keyword_update(update)
	return PlotlyBase.prependtraces!(p, converted, indices, maxpoints)
end

function PlotlyBase.prependtraces!(
	p::_RefreshablePlot,
	indices::AbstractVector{Int},
	maxpoints = -1;
	update...,
)
	converted = _trace_splice_keyword_update(update)
	return PlotlyBase.prependtraces!(p, converted, indices, maxpoints)
end

function PlotlyBase.prependtraces!(
	p::_RefreshablePlot,
	index::Int,
	maxpoints = -1;
	update...,
)
	return PlotlyBase.prependtraces!(p, [index], maxpoints; update...)
end

function PlotlyBase.prependtraces!(
	p::_RefreshablePlot,
	update::AbstractDict,
	index::Int,
	maxpoints = -1,
)
	return PlotlyBase.prependtraces!(p, update, [index], maxpoints)
end

function PlotlyBase.update!(
	p::_RefreshablePlot,
	ind::Union{AbstractVector{Int}, Int},
	update::AbstractDict = Dict();
	layout::Layout = p.layout,
	kwargs...,
)
	_do_update!(p, ind, update; layout = layout, kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update!(
	p::_RefreshablePlot,
	update = Dict();
	layout::Layout = p.layout,
	kwargs...,
)
	_do_update!(p, update; layout = layout, kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_xaxes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	_do_update_xaxes!(p, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_yaxes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	_do_update_yaxes!(p, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_polars!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	_do_update_polars!(p, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_geos!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	PlotlyBase.update_geos!(p.layout, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_mapboxes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	PlotlyBase.update_mapboxes!(p.layout, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_scenes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	PlotlyBase.update_scenes!(p.layout, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_ternaries!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	PlotlyBase.update_ternaries!(p.layout, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_annotations!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	PlotlyBase.update_annotations!(p.layout, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_shapes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	PlotlyBase.update_shapes!(p.layout, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

function PlotlyBase.update_images!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	PlotlyBase.update_images!(p.layout, with; kwargs...)
	_maybe_sync_refresh!(p)
	return p
end

# ── Window lifecycle ────────────────────────────────────────────────

function _syncplot_backend(sp::SyncPlot)
	resources = getfield(sp, :_resources)
	return resources.backend === nothing ? _electroncall() : resources.backend
end

function _syncplot_raw_window_state(sp::SyncPlot)
	try
		ec = _syncplot_backend(sp)
		window = getfield(sp, :window)
		is_open = Base.invokelatest(() -> ec.isopen(window))
		return is_open ? :open : :closed
	catch
		return :unknown
	end
end

function Base.isopen(sp::SyncPlot)
	resources = getfield(sp, :_resources)
	lock(resources.lock)
	try
		resources.close_started && return false
	finally
		unlock(resources.lock)
	end
	return _syncplot_raw_window_state(sp) === :open
end

function _deregister_syncplot!(sp::SyncPlot)
	lock(_SYNCPLOT_REGISTRY_LOCK) do
		filter!(x -> x !== sp, _DISPLAYED_PLOTS)
		for plot in collect(keys(_PLOT_SYNCPLOT_MAP))
			_PLOT_SYNCPLOT_MAP[plot] === sp && delete!(_PLOT_SYNCPLOT_MAP, plot)
		end
	end
	return nothing
end

function _cleanup_syncplot_tempdir!(resources::_SyncPlotResources)
	while true
		claim = lock(resources.lock) do
			if resources.tempdir === nothing
				return (:done, nothing, nothing, nothing)
			elseif resources.cleanup_in_progress
				return (:wait, nothing, resources.cleanup_done, nothing)
			end

			resources.cleanup_in_progress = true
			resources.cleanup_done = Base.Event()
			return (
				:clean,
				resources.tempdir,
				resources.cleanup_done,
				resources.tempdir_remover,
			)
		end

		action, tempdir, cleanup_done, tempdir_remover = claim
		action === :done && return nothing
		if action === :wait
			wait(cleanup_done)
			continue
		end

		succeeded = false
		try
			if tempdir_remover === nothing
				rm(tempdir; recursive = true, force = true)
			else
				tempdir_remover(tempdir)
			end
			succeeded = true
		finally
			try
				lock(resources.lock) do
					if succeeded && resources.tempdir == tempdir
						resources.tempdir = nothing
					end
					resources.cleanup_in_progress = false
				end
			finally
				notify(cleanup_done)
			end
		end
		return nothing
	end
end

function Base.close(sp::SyncPlot)
	resources = getfield(sp, :_resources)
	caller = current_task()
	close_state, close_done = lock(resources.lock) do
		if resources.close_started
			state = resources.close_owner === caller ? :reentrant : :wait
			return (state, resources.close_done)
		end
		resources.close_started = true
		resources.close_owner = caller
		return (:owner, resources.close_done)
	end

	close_state === :reentrant && return nothing
	if close_state === :wait
		wait(close_done)
		# A prior cleanup failure leaves tempdir populated so an idempotent
		# follow-up close can retry it without touching the native window.
		_deregister_syncplot!(sp)
		_cleanup_syncplot_tempdir!(resources)
		return nothing
	end

	try
		try
			_deregister_syncplot!(sp)
			if _syncplot_raw_window_state(sp) !== :closed
				ec = _syncplot_backend(sp)
				window = getfield(sp, :window)
				Base.invokelatest(() -> ec.close(window))
			end
		catch
			# Preserve the backend exception while still making the package-owned
			# HTML cleanup deterministic.
			try
				_cleanup_syncplot_tempdir!(resources)
			catch cleanup_error
				@warn "Failed to remove a SyncPlot temp directory after window close failed." exception = (
					cleanup_error,
					catch_backtrace(),
				)
			end
			rethrow()
		end

		_cleanup_syncplot_tempdir!(resources)
		return nothing
	finally
		try
			lock(resources.lock) do
				resources.close_owner = nothing
			end
		finally
			notify(close_done)
		end
	end
end

# ── Display ─────────────────────────────────────────────────────────

struct ElectronDisplay <: AbstractDisplay end

function _register_displayed_syncplot!(p::Plot, sp::SyncPlot)
	resources = getfield(sp, :_resources)
	lock(resources.lock)
	try
		resources.close_started && return (nothing, false)
		return lock(_SYNCPLOT_REGISTRY_LOCK) do
			old = get(_PLOT_SYNCPLOT_MAP, p, nothing)
			_PLOT_SYNCPLOT_MAP[p] = sp
			push!(_DISPLAYED_PLOTS, sp)
			(old, true)
		end
	finally
		unlock(resources.lock)
	end
end

function Base.display(d::ElectronDisplay, p::Plot)
	sp = to_syncplot(p)
	old, registered = _register_displayed_syncplot!(p, sp)
	registered || return nothing

	# Close the stale window only after its replacement is registered. If new
	# window construction fails, the existing display remains usable.
	old === nothing || close(old)
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

mutable struct _ExportState
	lock::ReentrantLock
	backend::Any
	app_backend::Any
	app::Any
	window::Any
	divid::String
	tempdir::Union{Nothing,String}
	ready::Bool
	pdf_job_counter::UInt64
	atexit_registered::Bool
	tempdir_remover::Any
	pending_windows::Vector{Tuple{Any,Any}}
	owned_tempdirs::Set{String}
	owned_pdf_tempdirs::Set{String}
end

function _ExportState(; divid::String = "plotlysupply-export")
	return _ExportState(
		ReentrantLock(),
		nothing,
		nothing,
		nothing,
		nothing,
		divid,
		nothing,
		false,
		zero(UInt64),
		false,
		nothing,
		Tuple{Any,Any}[],
		Set{String}(),
		Set{String}(),
	)
end

const _EXPORT_STATE = _ExportState()

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

function _export_timeout_seconds(timeout_s::Real, operation::AbstractString)
	timeout = try
		Float64(timeout_s)
	catch
		throw(ArgumentError("$operation timeout must be a finite, non-negative number"))
	end
	isfinite(timeout) && timeout >= 0 ||
		throw(ArgumentError("$operation timeout must be a finite, non-negative number"))
	return timeout
end

function _wait_for_plotly(ec, win; timeout_s::Real = 10.0)
	timeout = _export_timeout_seconds(timeout_s, "Plotly.js load")
	start_ns = time_ns()
	while (time_ns() - start_ns) / 1.0e9 < timeout
		try
			result = Base.invokelatest(() -> ec.run(win, "typeof Plotly !== 'undefined' ? 'ready' : 'waiting'"))
			result == "ready" && return true
		catch err
			err isa InterruptException && rethrow()
		end
		elapsed = (time_ns() - start_ns) / 1.0e9
		remaining = timeout - elapsed
		remaining > 0 && sleep(min(0.05, remaining))
	end
	error("Plotly.js did not load in the export window within $(timeout)s")
end

function _remove_export_tempdir_locked!(
	state::_ExportState,
	tempdir::String;
	throw_errors::Bool,
)
	try
		remover = state.tempdir_remover
		if remover === nothing
			rm(tempdir; recursive = true, force = true)
		else
			Base.invokelatest(remover, tempdir)
		end
	catch err
		if throw_errors
			rethrow()
		end
		@warn "Failed to remove an export temp directory." tempdir exception = (
			err,
			catch_backtrace(),
		)
		return false
	end

	delete!(state.owned_tempdirs, tempdir)
	state.tempdir == tempdir && (state.tempdir = nothing)
	return true
end

function _close_export_window(ec, win)
	should_close = true
	try
		should_close = Base.invokelatest(() -> ec.isopen(win))
	catch
		# Unknown backend state is not proof that the window is closed. Attempt
		# the close using the exact backend that created this exact window.
	end
	should_close && Base.invokelatest(() -> ec.close(win))
	return nothing
end

function _remove_pending_export_window_locked!(
	state::_ExportState,
	ec,
	win,
)
	index = findfirst(entry -> entry[1] === ec && entry[2] === win, state.pending_windows)
	index === nothing || deleteat!(state.pending_windows, index)
	return nothing
end

function _retry_pending_export_windows_locked!(
	state::_ExportState;
	throw_errors::Bool,
)
	for (ec, win) in copy(state.pending_windows)
		try
			_close_export_window(ec, win)
			_remove_pending_export_window_locked!(state, ec, win)
		catch err
			if throw_errors
				rethrow()
			end
			@warn "Failed to close a partially constructed export window." exception = (
				err,
				catch_backtrace(),
			)
		end
	end
	return nothing
end

function _cleanup_owned_export_tempdirs_locked!(
	state::_ExportState;
	throw_errors::Bool,
)
	for tempdir in copy(state.owned_tempdirs)
		tempdir == state.tempdir && state.window !== nothing && continue
		_remove_export_tempdir_locked!(state, tempdir; throw_errors = throw_errors)
	end
	return nothing
end

function _retire_export_window_locked!(
	state::_ExportState;
	throw_errors::Bool,
)
	win = state.window
	win === nothing && return nothing
	ec = state.backend
	tempdir = state.tempdir

	try
		_close_export_window(ec, win)
	catch err
		state.ready = false
		if throw_errors
			rethrow()
		end
		@warn "Failed to close the hidden export window." exception = (
			err,
			catch_backtrace(),
		)
		return nothing
	end

	state.backend = nothing
	state.window = nothing
	state.tempdir = nothing
	state.ready = false
	if tempdir !== nothing
		_remove_export_tempdir_locked!(
			state,
			tempdir;
			throw_errors = throw_errors,
		)
	end
	return nothing
end

function _cleanup_export_state_at_exit!(state::_ExportState)
	lock(state.lock)
	try
		_retire_export_window_locked!(state; throw_errors = false)
		_retry_pending_export_windows_locked!(state; throw_errors = false)
		_cleanup_owned_export_tempdirs_locked!(state; throw_errors = false)
		for tempdir in copy(state.owned_pdf_tempdirs)
			try
				rm(tempdir; recursive = true, force = true)
				delete!(state.owned_pdf_tempdirs, tempdir)
			catch err
				@warn "Failed to remove a captured PDF temp directory at exit." tempdir exception = (
					err,
					catch_backtrace(),
				)
			end
		end
	finally
		unlock(state.lock)
	end
	return nothing
end

function _register_export_atexit_locked!(state::_ExportState)
	if state === _EXPORT_STATE && !state.atexit_registered
		atexit(() -> _cleanup_export_state_at_exit!(state))
		state.atexit_registered = true
	end
	return nothing
end

function _export_window_is_alive_locked(state::_ExportState)
	state.window === nothing && return false
	state.ready || return false
	try
		return Base.invokelatest(() -> state.backend.isopen(state.window))
	catch
		return false
	end
end

function _export_app_is_alive(app)
	app === nothing && return false
	if hasproperty(app, :exists)
		try
			return getproperty(app, :exists) !== false
		catch
			return false
		end
	end
	return true
end

function _ensure_export_window_locked!(
	state::_ExportState,
	ec;
	timeout_s::Real,
)
	_register_export_atexit_locked!(state)

	if _export_window_is_alive_locked(state)
		return (state.backend, state.app, state.window, state.divid)
	end
	state.window === nothing ||
		_retire_export_window_locked!(state; throw_errors = true)
	_retry_pending_export_windows_locked!(state; throw_errors = true)
	_cleanup_owned_export_tempdirs_locked!(state; throw_errors = true)

	app = state.app
	if state.app_backend !== ec || !_export_app_is_alive(app)
		app = _default_electron_app(ec)
		state.app_backend = ec
		state.app = app
	end

	divid = state.divid
	tempdir = mktempdir(; prefix = "plotlysupply-export-")
	push!(state.owned_tempdirs, tempdir)
	tmpfile = joinpath(tempdir, "index.html")
	win = nothing
	try
		write(tmpfile, _export_window_html(divid))
		file_uri = _file_uri(tmpfile)
		win = Base.invokelatest(() -> ec.Window(
			app,
			file_uri;
			width = 960,
			height = 720,
			title = "PlotlySupply Export",
			show = false,
		))
		push!(state.pending_windows, (ec, win))
		_wait_for_plotly(ec, win; timeout_s = timeout_s)

		# Publish only after readiness succeeds. Until this assignment the local
		# transaction is not available to another export as a usable cache entry.
		_remove_pending_export_window_locked!(state, ec, win)
		state.backend = ec
		state.window = win
		state.tempdir = tempdir
		state.ready = true
		return (ec, app, win, divid)
	catch
		if win !== nothing
			try
				_close_export_window(ec, win)
				_remove_pending_export_window_locked!(state, ec, win)
			catch cleanup_error
				@warn "Failed to close a partially constructed export window." exception = (
					cleanup_error,
					catch_backtrace(),
				)
			end
		end
		try
			_remove_export_tempdir_locked!(
				state,
				tempdir;
				throw_errors = true,
			)
		catch cleanup_error
			@warn "Failed to remove a partially constructed export temp directory." tempdir exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		rethrow()
	end
end

function _ensure_export_window(
	state::_ExportState = _EXPORT_STATE;
	ec = nothing,
	timeout_s::Real = 10.0,
)
	backend = ec === nothing ? _electroncall() : ec
	lock(state.lock)
	try
		return _ensure_export_window_locked!(
			state,
			backend;
			timeout_s = timeout_s,
		)
	finally
		unlock(state.lock)
	end
end

function _with_export_window(
	f,
	state::_ExportState = _EXPORT_STATE;
	ec = nothing,
	timeout_s::Real = 10.0,
)
	backend = ec === nothing ? _electroncall() : ec
	lock(state.lock)
	try
		args = _ensure_export_window_locked!(
			state,
			backend;
			timeout_s = timeout_s,
		)
		return f(args...)
	finally
		unlock(state.lock)
	end
end

function _next_pdf_job_id_locked!(state::_ExportState)
	state.pdf_job_counter = Base.Checked.checked_add(
		state.pdf_job_counter,
		one(UInt64),
	)
	return "plotlysupply-pdf-" *
		   string(objectid(state)) *
		   "-" *
		   string(state.pdf_job_counter) *
		   "-" *
		   string(time_ns())
end
