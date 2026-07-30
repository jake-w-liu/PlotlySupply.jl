const _PLOTLYJS_VERSION = "2.35.2"
const _PLOTLY_CDN_URL =
	"https://cdn.plot.ly/plotly-$(_PLOTLYJS_VERSION).min.js"
const _PLOTLYJS_ARTIFACT_RELATIVE_PATH =
	joinpath("package", "plotly.min.js")
const _ELECTRONCALL_PKGID = Base.PkgId(Base.UUID("8ddd578f-0c94-4c64-8c65-f083f291b266"), "ElectronCall")
const _SYNC_ID_COUNTER = Ref(0)
const _SYNCPLOT_STARTUP_TIMEOUT_SECONDS = 15.0
const _SYNCPLOT_MODEL_FILENAME = "model.js"
# Browser timers store the millisecond delay in a signed 32-bit integer.
const _SYNCPLOT_MAX_STARTUP_TIMEOUT_SECONDS = typemax(Int32) / 1_000
# Bound the JSON writer's scratch buffer independently of the model size. The
# serializer flushes to disk whenever this threshold is reached.
const _SYNCPLOT_MODEL_JSON_BUFFER_BYTES = 16 * 1024

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

function _plotlyjs_asset_path()
	path = joinpath(artifact"plotlyjs", _PLOTLYJS_ARTIFACT_RELATIVE_PATH)
	isfile(path) || error(
		"Plotly.js artifact is incomplete: expected file $(repr(path))",
	)
	return path
end

_plotlyjs_asset_uri() = _file_uri(_plotlyjs_asset_path())

function _validated_timeout_seconds(timeout_s::Real, operation::AbstractString)
	timeout = try
		Float64(timeout_s)
	catch
		throw(ArgumentError("$operation timeout must be a finite, non-negative number"))
	end
	isfinite(timeout) && timeout >= 0 ||
		throw(ArgumentError("$operation timeout must be a finite, non-negative number"))
	return timeout
end

function _validated_syncplot_startup_timeout_seconds(timeout_s::Real)
	timeout = _validated_timeout_seconds(timeout_s, "SyncPlot startup")
	timeout <= _SYNCPLOT_MAX_STARTUP_TIMEOUT_SECONDS || throw(ArgumentError(
		"SyncPlot startup timeout must not exceed " *
		"$(_SYNCPLOT_MAX_STARTUP_TIMEOUT_SECONDS) seconds",
	))
	return timeout
end

@inline _is_uri_unreserved(byte::UInt8) =
	0x41 <= byte <= 0x5a || # A-Z
	0x61 <= byte <= 0x7a || # a-z
	0x30 <= byte <= 0x39 || # 0-9
	byte in (0x2d, 0x2e, 0x5f, 0x7e) # - . _ ~

@inline function _file_uri_byte_is_safe(
	bytes,
	index::Int,
	windows_drive::Bool,
)
	byte = bytes[index]
	return _is_uri_unreserved(byte) ||
		byte == 0x2f || # '/'
		(windows_drive && index == 3 && byte == 0x3a) # '/C:'
end

# Build a well-formed file URI from an absolute local path without relying on
# Base.Filesystem.uripath (which is unavailable on supported Julia 1.10).
# Encode UTF-8 bytes outside RFC 3986's unreserved set so a valid depot/temp
# path containing '#', '?', '%', quotes, or non-ASCII text cannot be parsed as
# a fragment/query or break the surrounding JavaScript/HTML literal.
function _file_uri(path::AbstractString)
	p = replace(path, "\\" => "/")
	Sys.iswindows() && !startswith(p, "/") && (p = "/" * p)
	bytes = codeunits(p)
	windows_drive =
		Sys.iswindows() &&
		length(bytes) >= 3 &&
		bytes[1] == 0x2f &&
		(
			0x41 <= bytes[2] <= 0x5a ||
			0x61 <= bytes[2] <= 0x7a
		) &&
		bytes[3] == 0x3a

	encoded_length = length(bytes)
	for index in eachindex(bytes)
		_file_uri_byte_is_safe(bytes, index, windows_drive) ||
			(encoded_length += 2)
	end

	hex = codeunits("0123456789ABCDEF")
	encoded = Vector{UInt8}(undef, encoded_length)
	output_index = 1
	for index in eachindex(bytes)
		byte = bytes[index]
		if _file_uri_byte_is_safe(bytes, index, windows_drive)
			@inbounds encoded[output_index] = byte
			output_index += 1
		else
			@inbounds begin
				encoded[output_index] = 0x25 # '%'
				encoded[output_index + 1] =
					hex[Int(byte >> 4) + 1]
				encoded[output_index + 2] =
					hex[Int(byte & 0x0f) + 1]
			end
			output_index += 3
		end
	end

	# A Windows UNC path already begins with "//server"; `file:` produces the
	# required `file://server/...`. All other absolute paths use `file://` plus
	# their leading slash, yielding `file:///...`.
	prefix =
		Sys.iswindows() && startswith(p, "//") ?
		"file:" :
		"file://"
	return prefix * String(encoded)
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

function _syncplot_html(
	divid::String;
	autoplay::Bool,
	timeout_s::Float64,
)
	plotlyjs_uri = _plotlyjs_asset_uri()
	divid_js = _json_js(divid)
	autoplay_js = autoplay ? "true" : "false"
	timeout_ms = timeout_s * 1_000
	timeout_message_js = _json_js(
		"SyncPlot initial render timed out after $(timeout_s) seconds",
	)

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
  <script>
    (function() {
      window.__plotlysupply_render_deadline =
        performance.now() + $timeout_ms;
      const loader = new Promise(function(resolve) {
        const script = document.createElement("script");
        script.src = "$plotlyjs_uri";
        script.charset = "utf-8";
        script.onload = function() {
          resolve(
            typeof Plotly === "undefined" ?
              "Plotly.js loaded without defining the Plotly global" :
              null
          );
        };
        script.onerror = function() {
          resolve("Plotly.js failed to load from $plotlyjs_uri");
        };
        document.head.appendChild(script);
      });
      loader.catch(function() {});
      window.__plotlysupply_plotly_loader = loader;
    })();
  </script>
  <script src="$_SYNCPLOT_MODEL_FILENAME" charset="utf-8"></script>
  <script>
    (function() {
      const deadline = window.__plotlysupply_render_deadline;
      if (!Number.isFinite(deadline)) {
        const missingDeadline = Promise.reject(
          new Error("SyncPlot render deadline was not initialized")
        );
        missingDeadline.catch(function() {});
        window.__plotlysupply_initial_render = missingDeadline;
        window.__plotlysupply_render_deadline = null;
        window.__plotlysupply_plotly_loader = null;
        window.__plotlysupply_model = null;
        return;
      }

      let timeoutId = null;
      const timeoutMessage = $timeout_message_js;
      const requireTimeRemaining = function() {
        if (performance.now() >= deadline) {
          throw new Error(timeoutMessage);
        }
      };
      const timeout = new Promise(function(_, reject) {
        timeoutId = setTimeout(
          function() { reject(new Error(timeoutMessage)); },
          Math.max(0, deadline - performance.now())
        );
      });
      const render = (async function() {
        requireTimeRemaining();
        const loader = window.__plotlysupply_plotly_loader;
        if (!loader || typeof loader.then !== "function") {
          throw new Error("SyncPlot Plotly.js loader was not initialized");
        }
        const loadError = await loader;
        requireTimeRemaining();
        if (loadError !== null) throw new Error(String(loadError));
        if (typeof Plotly === "undefined") {
          throw new Error("Plotly.js is unavailable after its loader completed");
        }
        const div = document.getElementById($divid_js);
        if (!div) throw new Error("SyncPlot plot div was not found");
        const model = window.__plotlysupply_model;
        window.__plotlysupply_model = null;
        if (!model || typeof model !== "object") {
          throw new Error("SyncPlot model was not loaded");
        }
        await Plotly.newPlot(div, model.data, model.layout, model.config);
        requireTimeRemaining();
        if (Array.isArray(model.frames) && model.frames.length > 0) {
          await Plotly.addFrames(div, model.frames);
          requireTimeRemaining();
          if ($autoplay_js) {
            await Plotly.animate(div, null);
            requireTimeRemaining();
          }
        }
        return "ok";
      })();
      const readiness = Promise.race([render, timeout]).finally(
        function() {
          if (timeoutId !== null) clearTimeout(timeoutId);
          window.__plotlysupply_render_deadline = null;
          window.__plotlysupply_plotly_loader = null;
          window.__plotlysupply_model = null;
        }
      );
      // A reload has no Julia waiter. Attach a rejection observer immediately
      // while retaining the original promise for the constructor handshake.
      readiness.catch(function() {});
      window.__plotlysupply_initial_render = readiness;
    })();
  </script>
</body>
</html>
"""
end

function _write_syncplot_model(path::AbstractString, p::Plot)
	open(path, "w") do io
		write(io, "window.__plotlysupply_model = ")
		PlotlyBase.JSON.json(
			io,
			p;
			allownan = true,
			bufsize = _SYNCPLOT_MODEL_JSON_BUFFER_BYTES,
		)
		write(io, ";\n")
	end
	return nothing
end

function _syncplot_readiness_script()
	return """
(async function() {
  const readiness = window.__plotlysupply_initial_render;
  if (!readiness || typeof readiness.then !== "function") {
    throw new Error("SyncPlot initial render was not initialized");
  }
  try {
    return await readiness;
  } finally {
    window.__plotlysupply_initial_render = null;
  }
})()
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
	timeout_s::Real = _SYNCPLOT_STARTUP_TIMEOUT_SECONDS,
)
	_require_syncplot_model(p)
	startup_timeout = _validated_syncplot_startup_timeout_seconds(timeout_s)
	electron_app = app === nothing ? _default_electron_app(ec) : app
	divid = _next_syncplot_id()
	html = _syncplot_html(
		divid;
		autoplay = autoplay,
		timeout_s = startup_timeout,
	)
	readiness_js = _syncplot_readiness_script()

	# Own a dedicated temp directory and load its index via file://. ElectronCall
	# converts HTML strings to data: URIs which have a ~2 MB size limit in
	# Chromium, causing blank windows for large datasets.
	tempdir = mktempdir(; prefix = "plotlysupply-sync-")
	tmpfile = joinpath(tempdir, "index.html")
	model_file = joinpath(tempdir, _SYNCPLOT_MODEL_FILENAME)
	window = nothing
	sp = nothing
	try
		write(tmpfile, html)
		_write_syncplot_model(model_file, p)
		file_uri = _file_uri(tmpfile)

		window = Base.invokelatest(() -> ec.Window(
			electron_app,
			file_uri;
			width = width,
			height = height,
			title = title,
			show = show,
		))
		render_result = Base.invokelatest(
			() -> ec.run(window, readiness_js),
		)
		_require_plotlyjs_success(render_result, "initial render")
		creation_spec = _SyncPlotCreationSpec(
			width,
			height,
			title,
			show,
			autoplay,
			startup_timeout,
		)
		resources = _SyncPlotResources(tempdir, ec, creation_spec)
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
	timeout_s::Real = _SYNCPLOT_STARTUP_TIMEOUT_SECONDS,
)
	return _create_syncplot_window(
		fig;
		app = app,
		width = width,
		height = height,
		title = title,
		show = show,
		autoplay = autoplay,
		timeout_s = timeout_s,
	)
end

to_syncplot(sp::SyncPlot; kwargs...) = sp

function _maybe_syncplot(fig::Plot; sync::Bool = false, kwargs...)
	return sync ? to_syncplot(fig; kwargs...) : fig
end

# PlotlySupply's Plot mutators resize and reorder trace containers, and its
# metadata-preserving clone methods deliberately target vector-backed models.
# Preserve already-owned Vectors without copying, but materialize views and
# other AbstractVectors at the public `plot` boundary so every model produced
# here has the same safe dispatch and ownership semantics.
_owned_plot_vector(items::Vector) = items
_owned_plot_vector(items::AbstractVector{T}) where {T} = Vector{T}(items)

function plot(
	trace::AbstractTrace,
	layout::AbstractLayout = Layout();
	config::PlotConfig = PlotConfig(),
	frames::AbstractVector{<:PlotlyFrame} = PlotlyFrame[],
	sync::Bool = false,
	kwargs...,
)
	owned_frames = _owned_plot_vector(frames)
	return _maybe_syncplot(Plot([trace], layout, owned_frames; config = config); sync = sync, kwargs...)
end

function plot(
	trace::AbstractTrace,
	layout::AbstractLayout,
	frames::AbstractVector{<:PlotlyFrame};
	config::PlotConfig = PlotConfig(),
	sync::Bool = false,
	kwargs...,
)
	owned_frames = _owned_plot_vector(frames)
	return _maybe_syncplot(Plot([trace], layout, owned_frames; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractVector{<:AbstractTrace},
	layout::AbstractLayout = Layout();
	config::PlotConfig = PlotConfig(),
	frames::AbstractVector{<:PlotlyFrame} = PlotlyFrame[],
	sync::Bool = false,
	kwargs...,
)
	owned_traces = _owned_plot_vector(traces)
	owned_frames = _owned_plot_vector(frames)
	return _maybe_syncplot(Plot(owned_traces, layout, owned_frames; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractVector{<:AbstractTrace},
	layout::AbstractLayout,
	frames::AbstractVector{<:PlotlyFrame};
	config::PlotConfig = PlotConfig(),
	sync::Bool = false,
	kwargs...,
)
	owned_traces = _owned_plot_vector(traces)
	owned_frames = _owned_plot_vector(frames)
	return _maybe_syncplot(Plot(owned_traces, layout, owned_frames; config = config); sync = sync, kwargs...)
end

function plot(
	traces::AbstractTrace...;
	layout::AbstractLayout = Layout(),
	config::PlotConfig = PlotConfig(),
	frames::AbstractVector{<:PlotlyFrame} = PlotlyFrame[],
	sync::Bool = false,
	kwargs...,
)
	owned_frames = _owned_plot_vector(frames)
	return _maybe_syncplot(Plot(collect(traces), layout, owned_frames; config = config); sync = sync, kwargs...)
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
	owned_frames = _owned_plot_vector(frames)
	return _maybe_syncplot(Plot(empty_traces, layout, owned_frames; config = config); sync = sync, kwargs...)
end

# Positional-layout form. `make_subplots` and other PlotlyJS-compat helpers call
# `plot(Layout(...))` with the layout passed positionally; without this method
# such calls fall through to the variadic error stub in PlotlySupply.jl.
plot(layout::AbstractLayout; kwargs...) = plot(; layout = layout, kwargs...)
plot(layout::AbstractLayout, frames::AbstractVector{<:PlotlyFrame}; kwargs...) =
	plot(; layout = layout, frames = frames, kwargs...)

function _require_open_syncplot_window(sp::SyncPlot)
	resources = getfield(sp, :_resources)
	lock(resources.lock) do
		resources.close_started && throw(InvalidStateException(
			"SyncPlot window is not open",
			:not_open,
		))
	end

	ec = _syncplot_backend(sp)
	window = getfield(sp, :window)
	open_result = Base.invokelatest(() -> ec.isopen(window))
	open_result === true && return nothing
	open_result === false && throw(InvalidStateException(
		"SyncPlot window is not open",
		:not_open,
	))
	throw(ErrorException(
		"SyncPlot backend returned a non-Boolean isopen result: " *
		repr(open_result),
	))
end

function _require_plotlyjs_success(result, operation::AbstractString)
	result isa AbstractString && result == "ok" && return nothing
	throw(ErrorException(
		"Plotly.js $operation did not complete successfully; " *
		"renderer returned $(repr(result)).",
	))
end

function _plotlyjs_refresh_script(
	sp::SyncPlot,
	data,
	layout;
	model::Plot = sp.plot,
	rebuild::Bool = false,
	autoplay::Bool = false,
)
	return if rebuild
		_plotlyjs_newplot_script(model, sp.divid; autoplay = autoplay, purge = true)
	else
		divid_js = _json_js(sp.divid)
		data_js = _json_js(data)
		layout_js = _json_js(layout)
		config_js = _json_js(model.config)
		"""
(async function() {
  if (typeof Plotly === "undefined") return "plotly-not-loaded";
  const div = document.getElementById($divid_js);
  if (!div) return "plot-div-not-found";
  await Plotly.react(div, $data_js, $layout_js, $config_js);
  return "ok";
})();
"""
	end
end

function _plotlyjs_refresh_payload_script(
	sp::SyncPlot,
	payload;
	rebuild::Bool = false,
	autoplay::Bool = false,
)
	divid_js = _json_js(sp.divid)
	if rebuild
		payload.frames === nothing && throw(ArgumentError(
			"A rebuilding renderer payload must include frames.",
		))
		autoplay_js = autoplay ? "true" : "false"
		return """
(async function() {
  if (typeof Plotly === "undefined") return "plotly-not-loaded";
  const div = document.getElementById($divid_js);
  if (!div) return "plot-div-not-found";
  const frames = $(payload.frames);
  Plotly.purge(div);
  await Plotly.newPlot(div, $(payload.data), $(payload.layout), $(payload.config));
  if (frames.length > 0) {
    await Plotly.addFrames(div, frames);
    if ($autoplay_js) await Plotly.animate(div, null);
  }
  return "ok";
})()
"""
	end
	return """
(async function() {
  if (typeof Plotly === "undefined") return "plotly-not-loaded";
  const div = document.getElementById($divid_js);
  if (!div) return "plot-div-not-found";
  await Plotly.react(div, $(payload.data), $(payload.layout), $(payload.config));
  return "ok";
})();
"""
end

function _run_plotlyjs_script!(
	sp::SyncPlot,
	js::AbstractString,
	operation::AbstractString,
)
	ec = _syncplot_backend(sp)
	result = Base.invokelatest(() -> ec.run(sp.window, js))
	_require_plotlyjs_success(result, operation)
	return nothing
end

function _plotlyjs_refresh!(
	sp::SyncPlot,
	data,
	layout;
	model::Plot = sp.plot,
	rebuild::Bool = false,
	autoplay::Bool = false,
)
	_require_open_syncplot_window(sp)
	js = _plotlyjs_refresh_script(
		sp,
		data,
		layout;
		model = model,
		rebuild = rebuild,
		autoplay = autoplay,
	)
	# Serialization can be material for large models. Recheck after it finishes
	# so a concurrently closed window never receives a stale renderer command.
	_require_open_syncplot_window(sp)
	_run_plotlyjs_script!(
		sp,
		js,
		rebuild ? "newPlot" : "react",
	)
	return nothing
end

function _plotlyjs_command_script(sp::SyncPlot, command::Symbol)
	command in (:redraw, :purge) ||
		throw(ArgumentError("unsupported Plotly.js command: $command"))

	divid_js = _json_js(sp.divid)
	call_js = command === :redraw ?
		"await Plotly.redraw(div);" :
		"Plotly.purge(div);"
	js = """
(async function() {
  if (typeof Plotly === "undefined") return "plotly-not-loaded";
  const div = document.getElementById($divid_js);
  if (!div) return "plot-div-not-found";
  $call_js
  return "ok";
})();
"""
	return js
end

function _plotlyjs_command!(sp::SyncPlot, command::Symbol)
	_require_open_syncplot_window(sp)
	js = _plotlyjs_command_script(sp, command)
	ec = _syncplot_backend(sp)
	result = Base.invokelatest(() -> ec.run(sp.window, js))
	_require_plotlyjs_success(result, string(command))
	return nothing
end

# ── Auto-refresh infrastructure ─────────────────────────────────────
# Maps a displayed Plot to its SyncPlot so that mutating the Plot
# (react!, addtraces!, …) automatically refreshes the Electron window.
const _SYNCPLOT_REGISTRY_LOCK = ReentrantLock()
const _PLOT_SYNCPLOT_MAP = IdDict{Plot,SyncPlot}()
struct _SyncPlotReservation
	syncplot::Union{Nothing,SyncPlot}
	kind::Symbol
	owner::Task
	done::Union{Nothing,Base.Event}
end
const _PLOT_SYNCPLOT_RESERVATIONS =
	IdDict{Plot,_SyncPlotReservation}()
mutable struct _PlotSyncPlotGeneration end
const _PLOT_SYNCPLOT_VERSIONS =
	WeakKeyDict{Plot,_PlotSyncPlotGeneration}()
const _DISPLAYED_PLOTS = SyncPlot[]

function _plot_syncplot_version(p::Plot)
	return get(_PLOT_SYNCPLOT_VERSIONS, p, nothing)
end

function _bump_plot_syncplot_version!(p::Plot)
	version = _PlotSyncPlotGeneration()
	_PLOT_SYNCPLOT_VERSIONS[p] = version
	return version
end

function _reserve_plot_for_syncplot!(
	p::Plot,
	sp::SyncPlot,
	kind::Symbol,
)
	kind in (:current, :candidate) || throw(ArgumentError(
		"unsupported SyncPlot reservation kind: $kind",
	))
	existing = get(_PLOT_SYNCPLOT_RESERVATIONS, p, nothing)
	if existing !== nothing
		existing.syncplot === sp && existing.kind === kind &&
			return existing, false
		throw(InvalidStateException(
			"Plot is already participating in another SyncPlot transaction",
			:busy,
		))
	end
	reservation = _SyncPlotReservation(
		sp,
		kind,
		current_task(),
		nothing,
	)
	_PLOT_SYNCPLOT_RESERVATIONS[p] = reservation
	_bump_plot_syncplot_version!(p)
	return reservation, true
end

function _release_plot_syncplot_reservation!(
	p::Plot,
	reservation::_SyncPlotReservation,
)
	get(_PLOT_SYNCPLOT_RESERVATIONS, p, nothing) === reservation ||
		return false
	delete!(_PLOT_SYNCPLOT_RESERVATIONS, p)
	_bump_plot_syncplot_version!(p)
	return true
end

function _maybe_sync_refresh!(p::Plot)
	while true
		sp = lock(_SYNCPLOT_REGISTRY_LOCK) do
			get(_PLOT_SYNCPLOT_MAP, p, nothing)
		end
		sp === nothing && return nothing

		prepare = function (target, current)
			script = _plotlyjs_refresh_script(
				target,
				current.data,
				current.layout;
				model = current,
			)
			commit = () -> current
			return (
				script = script,
				operation = "react",
				commit = commit,
			)
		end
		status = _syncplot_transaction_status!(
			sp,
			prepare;
			required_plot = p,
		)
		status === :committed && return nothing
		yield()
	end
end

function _try_local_plot_mutation!(mutation, p::Plot)
	reservation = lock(_SYNCPLOT_REGISTRY_LOCK) do
		(haskey(_PLOT_SYNCPLOT_MAP, p) ||
		 haskey(_PLOT_SYNCPLOT_RESERVATIONS, p)) &&
			return nothing
		claimed = _SyncPlotReservation(
			nothing,
			:local,
			current_task(),
			Base.Event(),
		)
		_PLOT_SYNCPLOT_RESERVATIONS[p] = claimed
		_bump_plot_syncplot_version!(p)
		return claimed
	end
	reservation === nothing && return :retry

	try
		mutation()
		return :committed
	finally
		try
			lock(_SYNCPLOT_REGISTRY_LOCK) do
				_release_plot_syncplot_reservation!(p, reservation)
			end
		finally
			notify(reservation.done::Base.Event)
		end
	end
end

function _maybe_sync_command!(p::Plot, command::Symbol)
	while true
		sp = lock(_SYNCPLOT_REGISTRY_LOCK) do
			get(_PLOT_SYNCPLOT_MAP, p, nothing)
		end
		sp === nothing && return nothing

		resources = getfield(sp, :_resources)
		lock(resources.render_lock)
		try
			still_mapped = lock(_SYNCPLOT_REGISTRY_LOCK) do
				get(_PLOT_SYNCPLOT_MAP, p, nothing) === sp
			end
			still_mapped || continue
			_plotlyjs_command!(sp, command)
			return nothing
		finally
			unlock(resources.render_lock)
		end
	end
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

function _do_purge!(p::Plot)
	empty!(p.data)
	p.layout = Layout()
	return p
end

function _do_relayout!(p::Plot, args...; kwargs...)
	memo = IdDict{Any,Any}()
	setter_origins = IdDict{Any,Nothing}()
	staged_layout = _clone_layout_for_mutation(p.layout, memo)
	staged_traces = IdDict{AbstractTrace,AbstractTrace}()
	prepared_args, prepared_kwargs =
		_prepare_relayout_inputs(
			args,
			kwargs,
			memo,
			setter_origins,
			;
			strict = !(p.layout isa Layout),
		)
	relayout!(staged_layout, prepared_args...; prepared_kwargs...)
	_rebase_staged_layout!(p.layout, staged_layout, memo)
	expanded = _expand_staged_alias_roots!(
		p,
		staged_traces,
		staged_layout,
		memo;
		setter_origins = setter_origins,
	)
	staged_layout = expanded.layout
	_prepare_incremental_outer_root_commit!(p, expanded)
	replacement_data =
		expanded.data === nothing ?
		_prepare_restyle_replacement_data(p, staged_traces) :
		nothing
	_commit_restyle!(p, staged_traces, replacement_data)
	_commit_layout!(p, staged_layout)
	_commit_incremental_outer_roots!(p, expanded)
	return p
end

# Copy only containers that PlotlyBase's setters can mutate. Dense numeric
# payloads remain shared. Arrays are copied only when they contain dictionaries
# or Plotly attributes, because a nested setter can otherwise mutate one of
# those elements through a caller-owned wrapper.
_copy_mutation_container(value) =
	_copy_mutation_container(value, IdDict{Any,Any}())
const _BuiltinMutationDict = Union{Dict,IdDict}
const _BuiltinPlotlyAttribute = Union{
	PlotlyBase.PlotlyAttribute,
	PlotlyBase.PlotlyFrame,
}

function _copy_mutation_container(
	value,
	memo::IdDict{Any,Any},
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String
		return value
	end
	haskey(memo, value) && return memo[value]
	if _graph_reaches_staged_node(value, memo)
		staged = Base.deepcopy_internal(value, memo)
		# deepcopy does not memo immutable wrapper roots. Recording the rebuilt
		# counterpart explicitly lets commit-time rebasing translate preserved
		# trace/layout roots nested inside arbitrary wrappers.
		memo[value] = staged
		return staged
	end
	return value
end

function _array_elements_may_be_mutation_containers(
	::Type{T},
) where {T}
	# Skip only element types that provably cannot carry mutable identity.
	# Concrete wrapper structs can contain dictionaries or attributes even
	# when they are not themselves plotting containers.
	return !(
		isbitstype(T) ||
		Base.isbitsunion(T) ||
		T <: String ||
		T <: Symbol ||
		T <: Type ||
		T <: Module
	)
end

function _setter_input_requires_copy(
	value,
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			value isa Function ||
			value isa BigInt ||
			value isa BigFloat
		return false
	end
	value isa AbstractDict && return true
	value isa PlotlyBase.AbstractPlotlyAttribute && return true
	value isa AbstractArray &&
		return _array_contains_mutation_container(value, seen)
	ismutable(value) && return true
	haskey(seen, value) && return false
	seen[value] = nothing
	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_setter_input_requires_copy(
			getfield(value, ind),
			seen,
		) && return true
	end
	return false
end

function _array_contains_mutation_container(
	value::AbstractArray,
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	_array_elements_may_be_mutation_containers(eltype(value)) ||
		return false
	haskey(seen, value) && return false
	seen[value] = nothing
	for ind in eachindex(value)
		isassigned(value, ind) || continue
		_setter_input_requires_copy(value[ind], seen) &&
			return true
	end
	return false
end

function _copy_mutation_container(
	value::_BuiltinMutationDict,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	staged = empty(value)
	memo[value] = staged
	for (key, child) in value
		staged[
			_copy_mutation_container(key, memo)
		] = _copy_mutation_container(child, memo)
	end
	return staged
end

function _copy_mutation_container(
	value::_BuiltinPlotlyAttribute,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	original_fields = value.fields
	original_fields isa _BuiltinMutationDict ||
		return Base.deepcopy_internal(value, memo)
	if haskey(memo, original_fields)
		staged_fields = memo[original_fields]
		staged = typeof(value)(copy(original_fields))
		setfield!(staged, :fields, staged_fields)
		memo[value] = staged
		return staged
	end
	staged_fields = copy(original_fields)
	if staged_fields === original_fields ||
			typeof(staged_fields) !== typeof(original_fields)
		return Base.deepcopy_internal(value, memo)
	end
	staged = typeof(value)(staged_fields)
	memo[value] = staged
	memo[original_fields] = staged_fields
	for (key, child) in original_fields
		staged_fields[key] =
			_copy_mutation_container(child, memo)
	end
	return staged
end

function _copy_setter_input(
	value,
	memo::IdDict{Any,Any},
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String
		return value
	end
	# Arbitrary setter payloads can contain live callbacks, locks, or model
	# handles. Stage every mutable payload graph before invoking third-party
	# setters; if a value cannot be copied independently, reject it before any
	# model or renderer side effect instead of exposing caller-owned state.
	haskey(memo, value) && return memo[value]
	_setter_input_requires_copy(value) || return value
	staged = Base.deepcopy_internal(value, memo)
	(
		typeof(staged) === typeof(value) &&
		(!ismutable(value) || staged !== value)
	) || throw(ArgumentError(
		"Setter value cannot be staged independently.",
	))
	memo[value] = staged
	return staged
end

function _copy_setter_input(
	value::_BuiltinMutationDict,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	staged = empty(value)
	memo[value] = staged
	for (key, child) in value
		staged[
			_copy_setter_input(key, memo)
		] = _copy_setter_input(child, memo)
	end
	return staged
end

function _copy_setter_input(
	value::AbstractDict,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	staged = Base.deepcopy_internal(value, memo)
	(staged === value || typeof(staged) !== typeof(value)) &&
		throw(ArgumentError(
			"Setter dictionary cannot be staged independently.",
		))
	return staged
end

function _copy_setter_input(
	value::_BuiltinPlotlyAttribute,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	original_fields = value.fields
	original_fields isa _BuiltinMutationDict ||
		return _copy_setter_input_strict(value, memo)
	if haskey(memo, original_fields)
		staged_fields = memo[original_fields]
		staged = typeof(value)(copy(original_fields))
		setfield!(staged, :fields, staged_fields)
		memo[value] = staged
		return staged
	end
	staged_fields = copy(original_fields)
	if staged_fields === original_fields ||
			typeof(staged_fields) !== typeof(original_fields)
		return _copy_setter_input_strict(value, memo)
	end
	staged = typeof(value)(staged_fields)
	memo[value] = staged
	memo[original_fields] = staged_fields
	for (key, child) in original_fields
		staged_fields[key] =
			_copy_setter_input(child, memo)
	end
	return staged
end

function _copy_setter_input(
	value::PlotlyBase.AbstractPlotlyAttribute,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	staged = Base.deepcopy_internal(value, memo)
	(staged === value || typeof(staged) !== typeof(value)) &&
		throw(ArgumentError(
			"Setter Plotly attribute cannot be staged independently.",
		))
	return staged
end

function _copy_setter_input(
	value::AbstractArray,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	_array_contains_mutation_container(value) || return value
	staged = copy(value)
	if staged === value ||
			typeof(staged) !== typeof(value) ||
			axes(staged) != axes(value)
		staged = Base.deepcopy_internal(value, memo)
		(staged === value ||
		 typeof(staged) !== typeof(value) ||
		 axes(staged) != axes(value)) &&
			throw(ArgumentError(
				"Setter array cannot be staged independently.",
			))
		return staged
	end
	memo[value] = staged
	for ind in eachindex(value)
		isassigned(value, ind) || continue
		staged[ind] = _copy_setter_input(value[ind], memo)
	end
	return staged
end

function _strict_setter_input_requires_copy(
	value,
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			value isa Function ||
			value isa BigInt ||
			value isa BigFloat
		return false
	end
	ismutable(value) && return true
	haskey(seen, value) && return false
	seen[value] = nothing
	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_strict_setter_input_requires_copy(
			getfield(value, ind),
			seen,
		) && return true
	end
	return false
end

function _copy_setter_input_strict(
	value,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	_strict_setter_input_requires_copy(value) || return value
	staged = Base.deepcopy_internal(value, memo)
	(
		typeof(staged) === typeof(value) &&
		(!ismutable(value) || staged !== value)
	) || throw(ArgumentError(
		"Third-party setter value cannot be staged independently.",
	))
	memo[value] = staged
	return staged
end

_prepare_setter_input(value, memo, strict::Bool) =
	strict ?
	_copy_setter_input_strict(value, memo) :
	_copy_setter_input(value, memo)

function _clone_trace_for_mutation(
	trace::GenericTrace,
	memo::IdDict{Any,Any},
)
	haskey(memo, trace) &&
		return memo[trace]::GenericTrace

	original_fields = getfield(trace, :fields)
	original_fields isa _BuiltinMutationDict ||
		return Base.deepcopy_internal(trace, memo)
	if haskey(memo, original_fields)
		staged_fields = memo[original_fields]
		staged = typeof(trace)(staged_fields)
		memo[trace] = staged
		return staged
	end

	# Construct the cycle-breaking shell with the trace's exact dictionary
	# type. GenericTrace is parametric in that type, so a canonical Dict shell
	# cannot later accept (for example) cloned IdDict fields.
	staged_fields = copy(original_fields)
	if staged_fields === original_fields ||
			typeof(staged_fields) !== typeof(original_fields)
		return Base.deepcopy_internal(trace, memo)
	end
	staged = typeof(trace)(staged_fields)
	memo[trace] = staged
	memo[original_fields] = staged_fields
	for (key, child) in original_fields
		staged_fields[key] = _copy_mutation_container(child, memo)
	end
	return staged
end
_clone_trace_for_mutation(
	trace::AbstractTrace,
	memo::IdDict{Any,Any},
) = Base.deepcopy_internal(trace, memo)
_clone_trace_for_mutation(trace::AbstractTrace) =
	_clone_trace_for_mutation(trace, IdDict{Any,Any}())

function _clone_layout_for_mutation(
	layout::Layout,
	memo::IdDict{Any,Any},
)
	haskey(memo, layout) &&
		return memo[layout]::Layout

	original_fields = getfield(layout, :fields)
	original_fields isa _BuiltinMutationDict ||
		return Base.deepcopy_internal(layout, memo)
	if haskey(memo, original_fields)
		staged_fields = memo[original_fields]
		staged = typeof(layout)(staged_fields)
		memo[layout] = staged
	else
		# Preserve Layout's exact parametric dictionary type while installing
		# the root in the memo before recursively copying its values. This also
		# keeps cycles through the Layout root intact.
		staged_fields = copy(original_fields)
		if staged_fields === original_fields ||
				typeof(staged_fields) !== typeof(original_fields)
			staged = Base.deepcopy_internal(layout, memo)
			setfield!(
				staged,
				:subplots,
				_copy_mutation_container(
					getfield(layout, :subplots),
					memo,
				),
			)
			return staged
		end
		staged = typeof(layout)(staged_fields)
		memo[layout] = staged
		memo[original_fields] = staged_fields
		for (key, child) in original_fields
			staged_fields[key] =
				_copy_mutation_container(child, memo)
		end
	end
	# Layout's public constructor merges defaults. Restore the exact cloned
	# dictionary so staging cannot reintroduce a field the caller removed.
	setfield!(staged, :fields, staged_fields)
	# Subplot routing metadata is read-only during model staging, so it can
	# normally remain shared. If a custom root already caused deepcopy to
	# clone it, however, reuse that clone to preserve cross-root aliases.
	original_subplots = getfield(layout, :subplots)
	setfield!(
		staged,
		:subplots,
		_copy_mutation_container(original_subplots, memo),
	)
	return staged
end
_clone_layout_for_mutation(
	layout::AbstractLayout,
	memo::IdDict{Any,Any},
) = Base.deepcopy_internal(layout, memo)
_clone_layout_for_mutation(layout::AbstractLayout) =
	_clone_layout_for_mutation(layout, IdDict{Any,Any}())

function _prepare_relayout_inputs(
	args,
	kwargs,
	memo::IdDict{Any,Any},
	setter_origins::Union{Nothing,IdDict{Any,Nothing}} = nothing,
	;
	strict::Bool = false,
)
	prepared_args = map(
		arg -> _prepare_setter_input(arg, memo, strict),
		args,
	)
	prepared_kwargs = Dict{Symbol,Any}(
		key => _prepare_setter_input(value, memo, strict)
		for (key, value) in pairs(kwargs)
	)
	if setter_origins !== nothing
		seen = IdDict{Any,Nothing}()
		for (value, prepared) in zip(args, prepared_args)
			_collect_setter_memoized_identities!(
				setter_origins,
				value,
				memo,
				seen,
			)
			prepared === value &&
				_collect_passthrough_setter_roots!(
					setter_origins,
					prepared,
				)
		end
		for (key, value) in pairs(kwargs)
			_collect_setter_memoized_identities!(
				setter_origins,
				value,
				memo,
				seen,
			)
			prepared = prepared_kwargs[key]
			prepared === value &&
				_collect_passthrough_setter_roots!(
					setter_origins,
					prepared,
				)
		end
	end
	return prepared_args, prepared_kwargs
end

function _seal_unchanged_projection_target!(
	projection::Union{Nothing,IdDict},
	target,
)
	projection === nothing ||
		_seal_projection_target!(
			projection,
			target,
			IdDict{Any,Nothing}(),
		)
	return target
end

function _rebase_unchanged_mutation_container!(
	original,
	staged,
	memo::IdDict{Any,Any},
	preserved_roots::Union{Nothing,IdDict} = nothing,
	seen::IdDict{Any,Any} = IdDict{Any,Any}(),
)
	if preserved_roots !== nothing &&
			haskey(preserved_roots, staged)
		rebased = preserved_roots[staged]
		original === rebased &&
			_seal_unchanged_projection_target!(
				preserved_roots,
				original,
			)
		return rebased, original === rebased
	end
	preserved_roots === nothing &&
		return staged, original === staged
	typeof(original) === typeof(staged) ||
		return staged, false
	if original isa BigInt || original isa BigFloat
		unchanged = isequal(original, staged)
		rebased = unchanged ? original : staged
		ismutable(staged) &&
			(preserved_roots[staged] = rebased)
		return rebased, unchanged
	end
	if original isa Type ||
			original isa Module ||
			isbits(original) ||
			original isa Symbol ||
			original isa String
		return staged, original === staged
	end
	memoized_counterpart =
		haskey(memo, original) &&
		memo[original] === staged
	if !memoized_counterpart && ismutable(original)
		original === staged &&
			_seal_unchanged_projection_target!(
				preserved_roots,
				original,
			)
		return staged, original === staged
	end
	if haskey(seen, original)
		seen[original] === staged ||
			return staged, false
		unchanged =
			_staged_graph_unchanged(
				original,
				staged,
				memo,
				IdDict{Any,Any}(),
				preserved_roots,
			)
		rebased = unchanged ? original : staged
		# A changed generic wrapper or non-Array element store is rebuilt
		# after its children have accumulated their final projections. Do not
		# memoize staged → staged at this unresolved backedge: doing so would
		# make deepcopy_internal return early and skip those child mappings.
		unchanged &&
			ismutable(staged) &&
			(preserved_roots[staged] = rebased)
		unchanged &&
			_seal_unchanged_projection_target!(
				preserved_roots,
				original,
			)
		return rebased, unchanged
	end
	seen[original] = staged

	if _is_builtin_element_storage(original)
		unchanged = axes(original) == axes(staged)
		writable_storage =
			unchanged && _is_generic_memory(staged)
		common_length = min(length(original), length(staged))
		for ind in 1:common_length
			original_assigned = isassigned(original, ind)
			staged_assigned = isassigned(staged, ind)
			if original_assigned != staged_assigned
				unchanged = false
				writable_storage = false
				continue
			end
			original_assigned || continue
			original_child = original[ind]
			staged_child = staged[ind]
			if (
				haskey(memo, original_child) &&
				memo[original_child] === staged_child
			) || haskey(preserved_roots, staged_child) || (
				!ismutable(original_child) &&
				typeof(original_child) === typeof(staged_child)
			)
				rebased_child, child_unchanged =
					_rebase_unchanged_mutation_container!(
						original_child,
						staged_child,
						memo,
						preserved_roots,
						seen,
					)
				if writable_storage
					staged[ind] = rebased_child
				elseif child_unchanged ||
						rebased_child !== staged_child
					ismutable(staged_child) &&
						(preserved_roots[staged_child] =
							rebased_child)
				end
				unchanged &= child_unchanged
			else
				child_unchanged =
					original_child === staged_child
				child_unchanged &&
					ismutable(staged_child) &&
					(preserved_roots[staged_child] =
						staged_child)
				unchanged &= child_unchanged
			end
		end
		if haskey(preserved_roots, staged) &&
				preserved_roots[staged] !== staged
			projected = preserved_roots[staged]
			return projected, projected === original
		end
		if unchanged
			preserved_roots[staged] = original
			_seal_unchanged_projection_target!(
				preserved_roots,
				original,
			)
			return original, true
		end
		if writable_storage
			preserved_roots[staged] = staged
			return staged, false
		end
		# Core.SimpleVector and GenericMemory are element stores without
		# reflected fields. GenericMemory with unchanged axes/assignment state
		# was projected in place above; rebuild immutable SimpleVector (or a
		# store whose defined-slot shape changed) through the accumulated root
		# translations.
		return _rebuild_projected_component!(
			staged,
			preserved_roots,
		), false
	end

	unchanged = true
	writable_wrapper = ismutable(staged)
	for ind in 1:fieldcount(typeof(original))
		original_defined = isdefined(original, ind)
		staged_defined = isdefined(staged, ind)
		if original_defined != staged_defined
			unchanged = false
			writable_wrapper = false
			continue
		end
		original_defined || continue
		original_child = getfield(original, ind)
		staged_child = getfield(staged, ind)
		if (
				haskey(memo, original_child) &&
				memo[original_child] === staged_child
			) ||
				haskey(preserved_roots, staged_child) ||
				(
					!ismutable(original_child) &&
					typeof(original_child) ===
						typeof(staged_child)
				)
			rebased_child, child_unchanged =
				_rebase_unchanged_mutation_container!(
					original_child,
					staged_child,
					memo,
					preserved_roots,
					seen,
				)
			if writable_wrapper &&
					!Base.isconst(typeof(staged), ind) &&
					!Base.isfieldatomic(
						typeof(staged),
						ind,
					)
				setfield!(staged, ind, rebased_child)
			elseif rebased_child !== staged_child
				writable_wrapper = false
				ismutable(staged_child) &&
					(preserved_roots[staged_child] =
						rebased_child)
			elseif child_unchanged
				ismutable(staged_child) &&
					(preserved_roots[staged_child] =
						rebased_child)
			end
			unchanged &= child_unchanged
		else
			child_unchanged =
				original_child === staged_child
			child_unchanged &&
				ismutable(staged_child) &&
				(preserved_roots[staged_child] =
					staged_child)
			unchanged &= child_unchanged
		end
	end
	if haskey(preserved_roots, staged) &&
			preserved_roots[staged] !== staged
		projected = preserved_roots[staged]
		return projected, projected === original
	end
	if unchanged
		ismutable(staged) &&
			(preserved_roots[staged] = original)
		_seal_unchanged_projection_target!(
			preserved_roots,
			original,
		)
		return original, true
	end

	if writable_wrapper
		preserved_roots[staged] = staged
		return staged, false
	end

	# Reconstruct changed arbitrary wrappers through the staged-to-committed
	# memo accumulated above. This translates preserved roots without mutating
	# third-party structs or cloning already-rebased mutable children.
	return _rebuild_projected_component!(
		staged,
		preserved_roots,
	), false
end

function _rebase_unchanged_mutation_container!(
	original::_BuiltinMutationDict,
	staged::_BuiltinMutationDict,
	memo::IdDict{Any,Any},
	preserved_roots::Union{Nothing,IdDict} = nothing,
	seen::IdDict{Any,Any} = IdDict{Any,Any}(),
)
	if preserved_roots !== nothing &&
			haskey(preserved_roots, staged)
		rebased = preserved_roots[staged]
		return rebased, original === rebased
	end
	if !haskey(memo, original) || memo[original] !== staged
		return staged, original === staged
	end
	if haskey(seen, original)
		seen[original] === staged ||
			return staged, false
		unchanged =
			_staged_graph_unchanged(
				original,
				staged,
				memo,
				IdDict{Any,Any}(),
				preserved_roots,
			)
		rebased = unchanged ? original : staged
		preserved_roots === nothing ||
			(preserved_roots[staged] = rebased)
		return rebased, unchanged
	end
	seen[original] = staged

	unchanged = length(original) == length(staged)
	missing_key = Ref(nothing)
	processed_staged_keys = IdDict{Any,Nothing}()
	for (original_key, original_child) in original
		exact_original_key_present = if staged isa Dict
			getkey(staged, original_key, missing_key) ===
				original_key
		elseif staged isa IdDict
			haskey(staged, original_key)
		else
			haskey(staged, original_key)
		end
		staged_key = if exact_original_key_present
			original_key
		elseif staged isa Dict || staged isa IdDict
			Base.deepcopy_internal(original_key, memo)
		else
			original_key
		end
		key_present = if staged isa Dict
			getkey(staged, staged_key, missing_key) === staged_key
		else
			haskey(staged, staged_key)
		end
		if !key_present
			unchanged = false
			continue
		end
		processed_staged_keys[staged_key] = nothing
		staged_child = staged[staged_key]
		rebased_key = staged_key

		if (
			haskey(memo, original_key) &&
			memo[original_key] === staged_key
		) || (
			preserved_roots !== nothing &&
			haskey(preserved_roots, staged_key)
		) || (
			!ismutable(original_key) &&
			typeof(original_key) === typeof(staged_key)
		)
			rebased_key, key_unchanged =
				_rebase_unchanged_mutation_container!(
					original_key,
					staged_key,
					memo,
					preserved_roots,
					seen,
				)
			unchanged &= key_unchanged
		else
			unchanged &= original_key === staged_key
		end

		if rebased_key !== staged_key
			preserved_roots === nothing ||
				(preserved_roots[staged_key] = rebased_key)
			existing_key = if staged isa Dict
				getkey(staged, rebased_key, missing_key)
			else
				haskey(staged, rebased_key) ?
					rebased_key :
					missing_key
			end
			(
				existing_key === missing_key ||
				existing_key === staged_key
			) || throw(ArgumentError(
				"Projected dictionary keys collide during transaction commit.",
			))
			delete!(staged, staged_key)
			staged[rebased_key] = staged_child
			delete!(processed_staged_keys, staged_key)
			processed_staged_keys[rebased_key] = nothing
			staged_key = rebased_key
		end

		if (
			haskey(memo, original_child) &&
			memo[original_child] === staged_child
		) || (
			!ismutable(original_child) &&
			typeof(original_child) === typeof(staged_child)
		)
			rebased_child, child_unchanged =
				_rebase_unchanged_mutation_container!(
					original_child,
					staged_child,
					memo,
					preserved_roots,
					seen,
				)
			staged[staged_key] = rebased_child
			unchanged &= child_unchanged
		elseif preserved_roots !== nothing &&
				haskey(preserved_roots, staged_child)
			rebased_child =
				preserved_roots[staged_child]
			staged[staged_key] = rebased_child
			unchanged &= original_child === rebased_child
		else
			unchanged &= original_child === staged_child
		end
	end
	if preserved_roots !== nothing
		for (staged_key, staged_child) in collect(staged)
			haskey(processed_staged_keys, staged_key) &&
				continue
			projected_key =
				Base.deepcopy_internal(staged_key, preserved_roots)
			projected_child =
				Base.deepcopy_internal(staged_child, preserved_roots)
			if projected_key !== staged_key
				delete!(staged, staged_key)
			end
			staged[projected_key] = projected_child
		end
	end
	if preserved_roots !== nothing &&
			haskey(preserved_roots, staged) &&
			preserved_roots[staged] !== staged
		projected = preserved_roots[staged]
		return projected, projected === original
	end
	rebased = unchanged ? original : staged
	preserved_roots === nothing ||
		(preserved_roots[staged] = rebased)
	return rebased, unchanged
end

function _rebase_unchanged_mutation_container!(
	original::_BuiltinPlotlyAttribute,
	staged::_BuiltinPlotlyAttribute,
	memo::IdDict{Any,Any},
	preserved_roots::Union{Nothing,IdDict} = nothing,
	seen::IdDict{Any,Any} = IdDict{Any,Any}(),
)
	if preserved_roots !== nothing &&
			haskey(preserved_roots, staged)
		rebased = preserved_roots[staged]
		return rebased, original === rebased
	end
	if !haskey(memo, original) || memo[original] !== staged
		return staged, original === staged
	end
	if haskey(seen, original)
		seen[original] === staged ||
			return staged, false
		unchanged =
			_staged_graph_unchanged(
				original,
				staged,
				memo,
				IdDict{Any,Any}(),
				preserved_roots,
			)
		rebased = unchanged ? original : staged
		preserved_roots === nothing ||
			(preserved_roots[staged] = rebased)
		return rebased, unchanged
	end
	seen[original] = staged

	rebased_fields, unchanged =
		_rebase_unchanged_mutation_container!(
			original.fields,
			staged.fields,
			memo,
			preserved_roots,
			seen,
		)
	rebased_fields === staged.fields ||
		setfield!(staged, :fields, rebased_fields)
	if preserved_roots !== nothing &&
			haskey(preserved_roots, staged) &&
			preserved_roots[staged] !== staged
		projected = preserved_roots[staged]
		return projected, projected === original
	end
	rebased = unchanged ? original : staged
	preserved_roots === nothing ||
		(preserved_roots[staged] = rebased)
	return rebased, unchanged
end

function _rebase_unchanged_mutation_container!(
	original::Array,
	staged::Array,
	memo::IdDict{Any,Any},
	preserved_roots::Union{Nothing,IdDict} = nothing,
	seen::IdDict{Any,Any} = IdDict{Any,Any}(),
)
	if preserved_roots !== nothing &&
			haskey(preserved_roots, staged)
		rebased = preserved_roots[staged]
		return rebased, original === rebased
	end
	if !haskey(memo, original) || memo[original] !== staged
		return staged, original === staged
	end
	if haskey(seen, original)
		seen[original] === staged ||
			return staged, false
		unchanged =
			_staged_graph_unchanged(
				original,
				staged,
				memo,
				IdDict{Any,Any}(),
				preserved_roots,
			)
		rebased = unchanged ? original : staged
		preserved_roots === nothing ||
			(preserved_roots[staged] = rebased)
		return rebased, unchanged
	end
	seen[original] = staged

	unchanged = axes(original) == axes(staged)
	common_length = min(length(original), length(staged))
	for ind in 1:common_length
		original_assigned = isassigned(original, ind)
		staged_assigned = isassigned(staged, ind)
		if original_assigned != staged_assigned
			unchanged = false
			if staged_assigned &&
				preserved_roots !== nothing
				staged[ind] = Base.deepcopy_internal(
					staged[ind],
					preserved_roots,
				)
			end
			continue
		end
		original_assigned || continue
		original_child = original[ind]
		staged_child = staged[ind]
		if (
			haskey(memo, original_child) &&
			memo[original_child] === staged_child
		) || (
			preserved_roots !== nothing &&
			haskey(preserved_roots, staged_child)
		) || (
			!ismutable(original_child) &&
			typeof(original_child) === typeof(staged_child)
		)
			rebased_child, child_unchanged =
				_rebase_unchanged_mutation_container!(
					original_child,
					staged_child,
					memo,
					preserved_roots,
					seen,
				)
			staged[ind] = rebased_child
			unchanged &= child_unchanged
		else
			unchanged &= original_child === staged_child
		end
	end
	if length(staged) > common_length &&
			preserved_roots !== nothing
		for ind in (common_length + 1):length(staged)
			isassigned(staged, ind) || continue
			staged[ind] = Base.deepcopy_internal(
				staged[ind],
				preserved_roots,
			)
		end
	end
	if preserved_roots !== nothing &&
			haskey(preserved_roots, staged) &&
			preserved_roots[staged] !== staged
		projected = preserved_roots[staged]
		return projected, projected === original
	end
	rebased = unchanged ? original : staged
	preserved_roots === nothing ||
		(preserved_roots[staged] = rebased)
	return rebased, unchanged
end

function _rebase_staged_trace!(
	original::GenericTrace,
	trace::GenericTrace,
	memo::IdDict{Any,Any},
	preserved_roots::Union{Nothing,IdDict} = nothing,
)
	fields, _ = _rebase_unchanged_mutation_container!(
		original.fields,
		trace.fields,
		memo,
		preserved_roots,
	)
	fields === trace.fields || setfield!(trace, :fields, fields)
	return trace
end

function _rebase_staged_traces!(
	staged::IdDict{AbstractTrace,AbstractTrace},
	memo::IdDict{Any,Any},
)
	for (original, trace) in staged
		if original isa GenericTrace && trace isa GenericTrace
			_rebase_staged_trace!(original, trace, memo)
		end
	end
	return staged
end

function _seal_projection_target!(
	projection::IdDict,
	target,
	seen::IdDict{Any,Nothing},
)
	_projection_graph_terminal(target) && return projection
	haskey(seen, target) && return projection
	seen[target] = nothing
	if ismutable(target)
		haskey(projection, target) ||
			(projection[target] = target)
		return projection
	end
	if _is_builtin_element_storage(target)
		for index in eachindex(target)
			isassigned(target, index) || continue
			_seal_projection_target!(
				projection,
				target[index],
				seen,
			)
		end
		return projection
	end
	for index in 1:fieldcount(typeof(target))
		isdefined(target, index) || continue
		_seal_projection_target!(
			projection,
			getfield(target, index),
			seen,
		)
	end
	return projection
end

function _seal_projection_targets!(projection::IdDict)
	seen = IdDict{Any,Nothing}()
	for target in collect(values(projection))
		_seal_projection_target!(
			projection,
			target,
			seen,
		)
	end
	return projection
end

function _rebase_staged_layout!(
	original::AbstractLayout,
	staged::AbstractLayout,
	memo::IdDict{Any,Any},
	preserved_roots::Union{Nothing,IdDict} = nothing,
)
	if original isa Layout && staged isa Layout
		if preserved_roots === nothing &&
				_staged_graph_unchanged(
					original,
					staged,
					memo,
				)
			setfield!(staged, :fields, original.fields)
			setfield!(
				staged,
				:subplots,
				original.subplots,
			)
			return staged
		end
		if preserved_roots !== nothing
			haskey(preserved_roots, staged) ||
				(preserved_roots[staged] = original)
		end
		original_subplots = getfield(original, :subplots)
		staged_subplots = getfield(staged, :subplots)
		unchanged_subplots =
			preserved_roots === nothing &&
			original_subplots !== staged_subplots &&
			_staged_graph_unchanged(
				original_subplots,
				staged_subplots,
				memo,
			)
		fields, _ = _rebase_unchanged_mutation_container!(
			original.fields,
			staged.fields,
			memo,
			preserved_roots,
		)
		fields === staged.fields || setfield!(staged, :fields, fields)
		if original_subplots !== staged_subplots
			if preserved_roots === nothing
				unchanged_subplots && setfield!(
					staged,
					:subplots,
					original_subplots,
				)
			else
				subplots, _ =
					_rebase_unchanged_mutation_container!(
						original_subplots,
						staged_subplots,
						memo,
						preserved_roots,
					)
				subplots === staged_subplots ||
					setfield!(
						staged,
						:subplots,
						subplots,
					)
			end
		end
	end
	return staged
end

# `deepcopy` is the only safe general staging strategy for third-party trace
# implementations, but an unrelated structural/layout mutation must not
# replace an otherwise untouched public trace object. Compare the original and
# staged graphs through deepcopy's identity memo, using their field structure
# instead of user equality for structured values. `seen` handles cycles and
# verifies that aliases still point to the same staged counterpart.
function _is_generic_memory(value)
	isdefined(Core, :GenericMemory) || return false
	return isa(value, getfield(Core, :GenericMemory))
end

function _is_builtin_element_storage(value)
	(value isa Array || value isa Core.SimpleVector) &&
		return true
	return _is_generic_memory(value)
end

function _projection_graph_terminal(value)
	return isbits(value) ||
		value isa Symbol ||
		value isa String ||
		value isa Type ||
		value isa Module ||
		(
			value isa Function &&
			fieldcount(typeof(value)) == 0
		) ||
		value isa BigInt ||
		value isa BigFloat
end

# Rebuild a non-writable staged root without splitting cycles. Earlier rebase
# steps may have memoized mutable members of the root's strongly connected
# component to themselves. Those entries are valid only after the whole
# component is resolved; leaving them in deepcopy's memo would retain stale
# backedges. Remove exactly that SCC while retaining every external public-root
# and completed-child translation, then let deepcopy rebuild the component as
# one alias-preserving graph.
function _rebuild_projected_component!(
	staged,
	preserved_roots::IdDict,
)
	nodes = Any[staged]
	node_indices = IdDict{Any,Int}(staged => 1)
	reverse_edges = Vector{Vector{Int}}([Int[]])

	function register_child!(child, parent_ind)
		_projection_graph_terminal(child) && return
		if haskey(preserved_roots, child) &&
				preserved_roots[child] !== child
			# This edge is already projected outside the staged component.
			return
		end
		child_ind = get(node_indices, child, 0)
		if child_ind == 0
			push!(nodes, child)
			child_ind = length(nodes)
			node_indices[child] = child_ind
			push!(reverse_edges, Int[])
		end
		push!(reverse_edges[child_ind], parent_ind)
		return
	end

	next_ind = 1
	while next_ind <= length(nodes)
		value = nodes[next_ind]
		if value isa Dict || value isa IdDict
			for (key, child) in value
				register_child!(key, next_ind)
				register_child!(child, next_ind)
			end
		elseif _is_builtin_element_storage(value)
			for ind in eachindex(value)
				isassigned(value, ind) || continue
				register_child!(value[ind], next_ind)
			end
		else
			for ind in 1:fieldcount(typeof(value))
				isdefined(value, ind) || continue
				register_child!(
					getfield(value, ind),
					next_ind,
				)
			end
		end
		next_ind += 1
	end

	in_component = falses(length(nodes))
	component_stack = Int[1]
	in_component[1] = true
	while !isempty(component_stack)
		child_ind = pop!(component_stack)
		for parent_ind in reverse_edges[child_ind]
			in_component[parent_ind] && continue
			in_component[parent_ind] = true
			push!(component_stack, parent_ind)
		end
	end

	component = IdDict{Any,Nothing}()
	for ind in eachindex(nodes)
		in_component[ind] || continue
		component[nodes[ind]] = nothing
	end

	projection_memo = copy(preserved_roots)
	# Earlier child rebases can publish new staged-to-public targets after the
	# transaction's initial projection seal. Seal those targets now so
	# rebuilding this component cannot clone a public mutable root (including
	# one nested inside an immutable wrapper).
	_seal_projection_targets!(projection_memo)
	for value in keys(component)
		delete!(projection_memo, value)
	end
	rebased = Base.deepcopy_internal(staged, projection_memo)
	projection_memo[staged] = rebased

	# If an existing alias translation targeted an old component member,
	# redirect it to that member's rebuilt counterpart before publishing the
	# completed memo.
	for (key, value) in collect(projection_memo)
		haskey(component, value) || continue
		haskey(projection_memo, value) || continue
		projection_memo[key] = projection_memo[value]
	end
	merge!(preserved_roots, projection_memo)
	return rebased
end

function _staged_graph_unchanged(
	original,
	staged,
	memo::IdDict{Any,Any},
	seen::IdDict{Any,Any} = IdDict{Any,Any}(),
	projected_roots::Union{Nothing,IdDict} = nothing,
)
	if isbits(original) || original isa Symbol
		return typeof(original) === typeof(staged) &&
			original === staged
	end
	if original isa String
		return staged isa String && isequal(original, staged)
	end
	if haskey(memo, original)
		memoized = memo[original]
		# A surrounding container observes only the identity of a child that
		# has its own in-place commit. Treat that edge as unchanged when the
		# commit projection proves the staged child resolves to this exact
		# original object. Accept both the not-yet-projected and already
		# projected slot so cyclic rebasing is independent of child order.
		identity_projected =
			projected_roots !== nothing &&
			haskey(projected_roots, memoized) &&
			projected_roots[memoized] === original &&
			(staged === memoized || staged === original)
		identity_projected && return true
		memoized === staged || return false
	end
	typeof(original) === typeof(staged) || return false
	if original isa BigInt ||
			original isa BigFloat
		return isequal(original, staged)
	end
	if original isa Type || original isa Module
		return original === staged
	end
	if haskey(seen, original)
		return seen[original] === staged
	end
	if original === staged
		ismutable(original) && (seen[original] = staged)
		return true
	end
	seen[original] = staged

	# Entry-wise comparison is valid only for built-in storage maps and element
	# stores, whose plotting state is their contents. Array/dictionary
	# wrappers and third-party container subtypes may carry parent links, tags,
	# or other metadata, so they fall through to structural field comparison.
	if original isa Dict || original isa IdDict
		length(original) == length(staged) || return false
		missing_key = Ref(nothing)
		for (original_key, original_value) in original
			# Immutable composite keys (for example, a tuple containing a
			# BigInt) are rebuilt by deepcopy without receiving their own memo
			# entry. Reconstruct the expected key through the populated memo so
			# its cloned children point at the exact staged counterparts.
			memoized_key =
				Base.deepcopy_internal(original_key, memo)
			projected_key =
				projected_roots !== nothing &&
				haskey(projected_roots, memoized_key) ?
				projected_roots[memoized_key] :
				memoized_key
			projected_key_present = if staged isa Dict
				getkey(
					staged,
					projected_key,
					missing_key,
				) === projected_key
			else
				haskey(staged, projected_key)
			end
			memoized_key_present = if staged isa Dict
				getkey(
					staged,
					memoized_key,
					missing_key,
				) === memoized_key
			else
				haskey(staged, memoized_key)
			end
			staged_key =
				projected_key_present ?
				projected_key :
				memoized_key
			key_present = if staged isa Dict
				getkey(staged, staged_key, missing_key) === staged_key
			else
				haskey(staged, staged_key)
			end
			(
				projected_key_present ||
				memoized_key_present
			) || return false
			key_present || return false
			_staged_graph_unchanged(
				original_key,
				staged_key,
				memo,
				seen,
				projected_roots,
			) || return false
			_staged_graph_unchanged(
				original_value,
				staged[staged_key],
				memo,
				seen,
				projected_roots,
			) || return false
		end
		return true
	elseif _is_builtin_element_storage(original)
		axes(original) == axes(staged) || return false
		for ind in eachindex(original)
			original_assigned = isassigned(original, ind)
			staged_assigned = isassigned(staged, ind)
			original_assigned == staged_assigned || return false
			original_assigned || continue
			_staged_graph_unchanged(
				original[ind],
				staged[ind],
				memo,
				seen,
				projected_roots,
			) || return false
		end
		return true
	end

	field_count = fieldcount(typeof(original))
	if field_count == 0
		return ismutable(original) ?
			haskey(memo, original) && memo[original] === staged :
			isequal(original, staged)
	end
	for ind in 1:field_count
		original_defined = isdefined(original, ind)
		staged_defined = isdefined(staged, ind)
		original_defined == staged_defined || return false
		original_defined || continue
		_staged_graph_unchanged(
			getfield(original, ind),
			getfield(staged, ind),
			memo,
			seen,
			projected_roots,
		) || return false
	end
	return true
end

function _component_find!(parents::Vector{Int}, ind::Int)
	root = ind
	while parents[root] != root
		root = parents[root]
	end
	while parents[ind] != ind
		next = parents[ind]
		parents[ind] = root
		ind = next
	end
	return root
end

function _component_union!(
	parents::Vector{Int},
	left::Int,
	right::Int,
)
	left_root = _component_find!(parents, left)
	right_root = _component_find!(parents, right)
	left_root == right_root ||
		(parents[right_root] = left_root)
	return nothing
end

function _candidate_array_elements_may_carry_identity(
	::Type{T},
) where {T}
	# Skip only element types whose values provably cannot carry mutable
	# identity. Concrete user structs, heap-backed numbers, and closures may
	# all contain mutable children even when they are not plotting containers.
	return !(
		isbitstype(T) ||
		Base.isbitsunion(T) ||
		T <: String ||
		T <: Symbol ||
		T <: Type ||
		T <: Module
	)
end

function _connect_candidate_graph_nodes!(
	root_index::Int,
	value,
	owners::IdDict{Any,Int},
	parents::Vector{Int},
	seen::IdDict{Any,Nothing},
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module
		return nothing
	end
	haskey(seen, value) && return nothing
	seen[value] = nothing

	if ismutable(value)
		owner = get(owners, value, 0)
		if owner == 0
			owners[value] = root_index
		else
			_component_union!(parents, root_index, owner)
			# The prior root already visited this mutable subgraph, so its
			# descendants cannot introduce a component the union missed.
			return nothing
		end
	end

	if value isa BigInt
		return nothing
	elseif value isa Dict || value isa IdDict
		for (key, child) in value
			_connect_candidate_graph_nodes!(
				root_index,
				key,
				owners,
				parents,
				seen,
			)
			_connect_candidate_graph_nodes!(
				root_index,
				child,
				owners,
				parents,
				seen,
			)
		end
		return nothing
	elseif _is_builtin_element_storage(value)
		_candidate_array_elements_may_carry_identity(eltype(value)) ||
			return nothing
		for ind in eachindex(value)
			isassigned(value, ind) || continue
			_connect_candidate_graph_nodes!(
				root_index,
				value[ind],
				owners,
				parents,
				seen,
			)
		end
		return nothing
	end

	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_connect_candidate_graph_nodes!(
			root_index,
			getfield(value, ind),
			owners,
			parents,
			seen,
		)
	end
	return nothing
end

function _graph_reaches_staged_node(
	value,
	memo::IdDict{Any,Any},
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module
		return false
	end
	haskey(memo, value) && return true
	value isa BigInt && return false
	haskey(seen, value) && return false
	seen[value] = nothing

	if value isa AbstractDict ||
			value isa PlotlyBase.AbstractPlotlyAttribute
		# Optimized staging always clones these mutable plotting containers.
		return true
	elseif value isa AbstractArray
		_array_contains_mutation_container(value) && return true
	end

	if value isa Dict || value isa IdDict
		for (key, child) in value
			_graph_reaches_staged_node(key, memo, seen) &&
				return true
			_graph_reaches_staged_node(child, memo, seen) &&
				return true
		end
		return false
	elseif _is_builtin_element_storage(value)
		_candidate_array_elements_may_carry_identity(eltype(value)) ||
			return false
		for ind in eachindex(value)
			isassigned(value, ind) || continue
			_graph_reaches_staged_node(value[ind], memo, seen) &&
				return true
		end
		return false
	end

	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_graph_reaches_staged_node(
			getfield(value, ind),
			memo,
			seen,
		) && return true
	end
	return false
end

function _graph_contains_memoized_identity(
	value,
	memo::IdDict{Any,Any},
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			value isa BigInt ||
			value isa BigFloat
		return false
	end
	haskey(memo, value) && return true
	haskey(seen, value) && return false
	seen[value] = nothing

	if value isa Dict || value isa IdDict
		for (key, child) in value
			_graph_contains_memoized_identity(
				key,
				memo,
				seen,
			) && return true
			_graph_contains_memoized_identity(
				child,
				memo,
				seen,
			) && return true
		end
		return false
	elseif _is_builtin_element_storage(value)
		_candidate_array_elements_may_carry_identity(eltype(value)) ||
			return false
		for ind in eachindex(value)
			isassigned(value, ind) || continue
			_graph_contains_memoized_identity(
				value[ind],
				memo,
				seen,
			) && return true
		end
		return false
	end

	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_graph_contains_memoized_identity(
			getfield(value, ind),
			memo,
			seen,
		) && return true
	end
	return false
end

function _collect_graph_mutable_identities!(
	identities::IdDict{Any,Nothing},
	value,
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			value isa BigInt ||
			value isa BigFloat
		return identities
	end
	haskey(seen, value) && return identities
	seen[value] = nothing
	ismutable(value) && (identities[value] = nothing)

	if value isa Dict || value isa IdDict
		for (key, child) in value
			_collect_graph_mutable_identities!(
				identities,
				key,
				seen,
			)
			_collect_graph_mutable_identities!(
				identities,
				child,
				seen,
			)
		end
		return identities
	elseif _is_builtin_element_storage(value)
		_candidate_array_elements_may_carry_identity(eltype(value)) ||
			return identities
		for ind in eachindex(value)
			isassigned(value, ind) || continue
			_collect_graph_mutable_identities!(
				identities,
				value[ind],
				seen,
			)
		end
		return identities
	end

	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_collect_graph_mutable_identities!(
			identities,
			getfield(value, ind),
			seen,
		)
	end
	return identities
end

function _collect_model_memoized_identities!(
	identities::IdDict{Any,Nothing},
	value,
	memo::IdDict{Any,Any},
	targets::IdDict{Any,Nothing},
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			value isa BigInt ||
			value isa BigFloat
		return identities
	end
	haskey(seen, value) && return identities
	seen[value] = nothing
	haskey(targets, value) &&
		haskey(memo, value) &&
		(identities[value] = nothing)

	if value isa Dict || value isa IdDict
		for (key, child) in value
			_collect_model_memoized_identities!(
				identities,
				key,
				memo,
				targets,
				seen,
			)
			_collect_model_memoized_identities!(
				identities,
				child,
				memo,
				targets,
				seen,
			)
		end
		return identities
	elseif _is_builtin_element_storage(value)
		_candidate_array_elements_may_carry_identity(eltype(value)) ||
			return identities
		for ind in eachindex(value)
			isassigned(value, ind) || continue
			_collect_model_memoized_identities!(
				identities,
				value[ind],
				memo,
				targets,
				seen,
			)
		end
		return identities
	end

	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_collect_model_memoized_identities!(
			identities,
			getfield(value, ind),
			memo,
			targets,
			seen,
		)
	end
	return identities
end

function _collect_setter_memoized_identities!(
	identities::IdDict{Any,Nothing},
	value,
	memo::IdDict{Any,Any},
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			value isa Function ||
			value isa BigInt ||
			value isa BigFloat
		return identities
	end
	haskey(seen, value) && return identities
	seen[value] = nothing
	haskey(memo, value) && (identities[value] = nothing)

	if value isa Dict || value isa IdDict
		for (key, child) in value
			_collect_setter_memoized_identities!(
				identities,
				key,
				memo,
				seen,
			)
			_collect_setter_memoized_identities!(
				identities,
				child,
				memo,
				seen,
			)
		end
		return identities
	elseif _is_builtin_element_storage(value)
		_candidate_array_elements_may_carry_identity(eltype(value)) ||
			return identities
		for ind in eachindex(value)
			isassigned(value, ind) || continue
			_collect_setter_memoized_identities!(
				identities,
				value[ind],
				memo,
				seen,
			)
		end
		return identities
	end

	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_collect_setter_memoized_identities!(
			identities,
			getfield(value, ind),
			memo,
			seen,
		)
	end
	return identities
end

function _collect_passthrough_setter_roots!(
	identities::IdDict{Any,Nothing},
	value,
	seen::IdDict{Any,Nothing} = IdDict{Any,Nothing}(),
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module
		return identities
	end
	haskey(seen, value) && return identities
	seen[value] = nothing
	# `deepcopy` reconstructs immutable wrappers and closures even when their
	# wrapper roots are pre-populated in its memo. Preserving the first mutable
	# identity on every path retains the exact pass-through value graph while
	# avoiding a traversal of large arrays, dictionaries, or captured models.
	if ismutable(value)
		identities[value] = nothing
		return identities
	end
	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		_collect_passthrough_setter_roots!(
			identities,
			getfield(value, ind),
			seen,
		)
	end
	return identities
end

function _stage_cross_aliased_model_root(
	value,
	memo::IdDict{Any,Any},
)
	haskey(memo, value) && return memo[value]
	_graph_contains_memoized_identity(value, memo) ||
		return value
	return Base.deepcopy_internal(value, memo)
end

function _full_model_replacement_roots(
	p::Plot,
	candidate::Plot,
	staged_traces::IdDict{AbstractTrace,AbstractTrace},
	memo::IdDict{Any,Any},
	affected_roots::Union{Nothing,IdDict} = nothing,
)
	(
		any(
			original -> !(original isa GenericTrace),
			keys(staged_traces),
		) ||
		!(p.layout isa Layout)
	) ||
		return nothing

	original_roots = Any[]
	staged_roots = Any[]
	third_party = Bool[]
	root_indices = IdDict{Any,Int}()

	push!(original_roots, p.data)
	push!(staged_roots, candidate.data)
	push!(third_party, false)
	root_indices[p.data] = length(original_roots)
	data_root_index = length(original_roots)

	for original in p.data
		haskey(root_indices, original) && continue
		push!(original_roots, original)
		push!(staged_roots, staged_traces[original])
		push!(third_party, !(original isa GenericTrace))
		root_indices[original] = length(original_roots)
	end
	push!(original_roots, p.layout)
	push!(staged_roots, candidate.layout)
	push!(third_party, !(p.layout isa Layout))
	root_indices[p.layout] = length(original_roots)
	push!(original_roots, p.frames)
	push!(staged_roots, candidate.frames)
	push!(third_party, false)
	root_indices[p.frames] = length(original_roots)
	push!(original_roots, p.config)
	push!(staged_roots, candidate.config)
	push!(third_party, false)
	root_indices[p.config] = length(original_roots)

	parents = collect(eachindex(original_roots))
	# The data vector is itself an aliasable model root, but its trace elements
	# must not make every trace one replacement component. Register the vector
	# as an opaque owner and traverse each trace root independently.
	owners = IdDict{Any,Int}(
		candidate.data => data_root_index,
	)
	for ind in eachindex(original_roots)
		ind == data_root_index && continue
		# Component membership follows the post-mutation candidate graph.
		# A setter may deliberately detach one root from a formerly shared
		# object; retaining the original edge would replace an untouched root.
		_connect_candidate_graph_nodes!(
			ind,
			staged_roots[ind],
			owners,
			parents,
			IdDict{Any,Nothing}(),
		)
	end

	affected_original_parents = nothing
	affected_original_components = nothing
	if affected_roots !== nothing
		affected_original_parents =
			collect(eachindex(original_roots))
		affected_owners = IdDict{Any,Int}(
			p.data => data_root_index,
		)
		for ind in eachindex(original_roots)
			ind == data_root_index && continue
			_connect_candidate_graph_nodes!(
				ind,
				original_roots[ind],
				affected_owners,
				affected_original_parents,
				IdDict{Any,Nothing}(),
			)
		end
		affected_original_components =
			falses(length(original_roots))
		for ind in eachindex(original_roots)
			haskey(affected_roots, original_roots[ind]) ||
				continue
			affected_original_components[
				_component_find!(
					affected_original_parents,
					ind,
				)
			] = true
		end
	end

	dirty_custom_components = falses(length(original_roots))
	for ind in eachindex(original_roots)
		third_party[ind] || continue
		if affected_original_components !== nothing
			affected_original_components[
				_component_find!(
					affected_original_parents,
					ind,
				)
			] || continue
		end
		_staged_graph_unchanged(
			original_roots[ind],
			staged_roots[ind],
			memo,
		) && continue
		dirty_custom_components[
			_component_find!(parents, ind)
		] = true
	end

	replace = IdDict{Any,Bool}()
	for ind in eachindex(original_roots)
		replace[original_roots[ind]] =
			dirty_custom_components[
				_component_find!(parents, ind)
			]
	end
	return replace
end

function _full_model_mutation_affected_roots(
	p::Plot,
	mutation_scope,
)
	mutation_scope === nothing && return nothing
	affected = IdDict{Any,Nothing}()
	for ind in mutation_scope.trace_indices
		checkbounds(Bool, p.data, ind) ||
			throw(BoundsError(p.data, ind))
		affected[p.data[ind]] = nothing
	end
	mutation_scope.layout &&
		(affected[p.layout] = nothing)
	return affected
end

function _prepare_restyle_inputs(
	update::AbstractDict,
	kwargs,
	trace_count::Int;
	vectorized::Bool,
	memo::IdDict{Any,Any},
	setter_origins::Union{Nothing,IdDict{Any,Nothing}} = nothing,
	strict::Bool = false,
)
	# Widen the copied dictionary so vector preparation can replace narrowly
	# typed values without changing the caller's object.
	prepared_update = Dict{Any,Any}(pairs(update))
	prepared_kwargs = Dict{Symbol,Any}(kwargs)
	for values in (prepared_update, prepared_kwargs)
		for (key, value) in values
			prepared = vectorized ?
				PlotlyBase._prep_restyle_vec_setindex(
					value,
					trace_count,
				) :
				value
			staged_value =
				_prepare_setter_input(prepared, memo, strict)
			values[key] = staged_value
			setter_origins === nothing ||
				_collect_setter_memoized_identities!(
					setter_origins,
					prepared,
					memo,
				)
			if setter_origins !== nothing &&
					staged_value === prepared
				_collect_passthrough_setter_roots!(
					setter_origins,
					staged_value,
				)
				if vectorized &&
						(
							staged_value isa AbstractArray ||
							staged_value isa Tuple
						)
					for position in 1:trace_count
						child = staged_value[position]
						_collect_passthrough_setter_roots!(
							setter_origins,
							child,
						)
					end
				end
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
	memo::IdDict{Any,Any} = IdDict{Any,Any}(),
	setter_origins::Union{Nothing,IdDict{Any,Nothing}} = nothing,
)
	for ind in inds
		checkbounds(Bool, p.data, ind) || throw(BoundsError(p.data, ind))
	end

	# A repeated trace object is staged only once, retaining PlotlyBase's
	# sequential behavior when the same object appears at multiple indices.
	staged = IdDict{AbstractTrace,AbstractTrace}()
	for ind in inds
		original = p.data[ind]
		get!(
			() -> _clone_trace_for_mutation(original, memo),
			staged,
			original,
		)
	end

	# Clone setter inputs only after the selected model graph has populated the
	# memo. If a caller passes a dictionary already shared by the model, both
	# references then resolve to the same staged clone.
	prepared_update, prepared_kwargs = _prepare_restyle_inputs(
		update,
		kwargs,
		length(inds);
		vectorized = vectorized,
		memo = memo,
		setter_origins = setter_origins,
		strict = any(
			original -> !(original isa GenericTrace),
			keys(staged),
		),
	)

	for (position, ind) in enumerate(inds)
		trace = staged[p.data[ind]]
		restyle!(trace, position, prepared_update; prepared_kwargs...)
	end
	return staged
end

function _collect_changed_mutation_containers!(
	changed::IdDict{Any,Nothing},
	original,
	staged,
	memo::IdDict{Any,Any},
)
	original === staged && return false
	container_changed =
		!_staged_graph_unchanged(original, staged, memo)
	if container_changed &&
			!(
				isbits(original) ||
				original isa Symbol ||
				original isa String ||
				original isa Type ||
				original isa Module ||
				original isa BigInt ||
				original isa BigFloat
			)
		changed[original] = nothing
	end
	return container_changed
end

function _collect_changed_mutation_containers!(
	changed::IdDict{Any,Nothing},
	original::AbstractDict,
	staged::AbstractDict,
	memo::IdDict{Any,Any},
)
	original === staged && return false
	if !haskey(memo, original) || memo[original] !== staged
		return true
	end

	container_changed = length(original) != length(staged)
	for (key, original_child) in original
		if !haskey(staged, key)
			container_changed = true
			continue
		end
		staged_child = staged[key]
		if haskey(memo, original_child) &&
				memo[original_child] === staged_child
			container_changed |=
				_collect_changed_mutation_containers!(
					changed,
					original_child,
					staged_child,
					memo,
				)
		else
			container_changed |= original_child !== staged_child
		end
	end
	container_changed && (changed[original] = nothing)
	return container_changed
end

function _collect_changed_mutation_containers!(
	changed::IdDict{Any,Nothing},
	original::PlotlyBase.AbstractPlotlyAttribute,
	staged::PlotlyBase.AbstractPlotlyAttribute,
	memo::IdDict{Any,Any},
)
	original === staged && return false
	if !haskey(memo, original) || memo[original] !== staged
		return true
	end
	container_changed = _collect_changed_mutation_containers!(
		changed,
		original.fields,
		staged.fields,
		memo,
	)
	container_changed && (changed[original] = nothing)
	return container_changed
end

function _collect_changed_graph_nodes!(
	changed::IdDict{Any,Nothing},
	original,
	staged,
	memo::IdDict{Any,Any},
	seen::IdDict{Any,Any},
)
	if isbits(original) || original isa Symbol
		return !(
			typeof(original) === typeof(staged) &&
			original === staged
		)
	elseif original isa String
		return !(staged isa String && isequal(original, staged))
	elseif original isa BigInt || original isa BigFloat
		return !(
			typeof(original) === typeof(staged) &&
			isequal(original, staged)
		)
	elseif original isa Type || original isa Module
		return original !== staged
	end
	typeof(original) === typeof(staged) || return true
	original === staged && return false
	memoized_counterpart =
		haskey(memo, original) &&
		memo[original] === staged
	ismutable(original) &&
		!memoized_counterpart &&
		return true
	if haskey(seen, original)
		return seen[original] !== staged
	end
	seen[original] = staged

	node_changed = false
	if original isa Dict || original isa IdDict
		node_changed = length(original) != length(staged)
		missing_key = Ref(nothing)
		for (original_key, original_child) in original
			staged_key =
				Base.deepcopy_internal(original_key, memo)
			key_present = if staged isa Dict
				getkey(staged, staged_key, missing_key) ===
					staged_key
			else
				haskey(staged, staged_key)
			end
			if !key_present
				node_changed = true
				continue
			end
			node_changed |= _collect_changed_graph_nodes!(
				changed,
				original_key,
				staged_key,
				memo,
				seen,
			)
			node_changed |= _collect_changed_graph_nodes!(
				changed,
				original_child,
				staged[staged_key],
				memo,
				seen,
			)
		end
	elseif _is_builtin_element_storage(original)
		node_changed = axes(original) != axes(staged)
		common_length = min(length(original), length(staged))
		for ind in 1:common_length
			original_assigned = isassigned(original, ind)
			staged_assigned = isassigned(staged, ind)
			if original_assigned != staged_assigned
				node_changed = true
				continue
			end
			original_assigned || continue
			node_changed |= _collect_changed_graph_nodes!(
				changed,
				original[ind],
				staged[ind],
				memo,
				seen,
			)
		end
	else
		field_count = fieldcount(typeof(original))
		if field_count == 0
			node_changed = ismutable(original) ?
				!memoized_counterpart :
				!isequal(original, staged)
		else
			for ind in 1:field_count
				original_defined = isdefined(original, ind)
				staged_defined = isdefined(staged, ind)
				if original_defined != staged_defined
					node_changed = true
					continue
				end
				original_defined || continue
				node_changed |= _collect_changed_graph_nodes!(
					changed,
					getfield(original, ind),
					getfield(staged, ind),
					memo,
					seen,
				)
			end
		end
	end
	node_changed &&
		ismutable(original) &&
		memoized_counterpart &&
		(changed[original] = nothing)
	return node_changed
end

function _contains_changed_mutation_container(
	value,
	changed::IdDict{Any,Nothing},
)
	return _contains_changed_mutation_container(
		value,
		changed,
		IdDict{Any,Any}(),
	)
end

mutable struct _ContainsVisitMarker end
const _CONTAINS_VISIT_ACTIVE = _ContainsVisitMarker()
const _CONTAINS_VISIT_FALSE = _ContainsVisitMarker()
const _CONTAINS_BACKEDGE_COUNT = _ContainsVisitMarker()

function _contains_visit_enter!(visiting::IdDict{Any,Any}, value)
	state = get(visiting, value, nothing)
	state === _CONTAINS_VISIT_FALSE && return :cached_false
	if state === _CONTAINS_VISIT_ACTIVE
		visiting[_CONTAINS_BACKEDGE_COUNT] =
			get(visiting, _CONTAINS_BACKEDGE_COUNT, 0) + 1
		return :backedge
	end
	visiting[value] = _CONTAINS_VISIT_ACTIVE
	return :entered
end

function _contains_changed_mutation_container(
	value,
	changed::IdDict{Any,Nothing},
	visiting::IdDict{Any,Any},
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			value isa BigInt ||
			value isa BigFloat
		return false
	end
	haskey(changed, value) && return true
	_contains_visit_enter!(visiting, value) === :entered ||
		return false
	if _is_builtin_element_storage(value)
		backedges_before =
			get(visiting, _CONTAINS_BACKEDGE_COUNT, 0)
		if _array_elements_may_be_mutation_containers(
			eltype(value),
		)
			for ind in eachindex(value)
				isassigned(value, ind) || continue
				if _contains_changed_mutation_container(
					value[ind],
					changed,
					visiting,
				)
					delete!(visiting, value)
					return true
				end
			end
		end
		if get(visiting, _CONTAINS_BACKEDGE_COUNT, 0) ==
				backedges_before
			visiting[value] = _CONTAINS_VISIT_FALSE
		else
			delete!(visiting, value)
		end
		return false
	end
	for ind in 1:fieldcount(typeof(value))
		isdefined(value, ind) || continue
		if _contains_changed_mutation_container(
			getfield(value, ind),
			changed,
			visiting,
		)
			delete!(visiting, value)
			return true
		end
	end
	delete!(visiting, value)
	return false
end

function _contains_changed_mutation_container(
	value::AbstractDict,
	changed::IdDict{Any,Nothing},
	visiting::IdDict{Any,Any},
)
	haskey(changed, value) && return true
	_contains_visit_enter!(visiting, value) === :entered ||
		return false
	for (key, child) in value
		if _contains_changed_mutation_container(
			key,
			changed,
			visiting,
		) || _contains_changed_mutation_container(
			child,
			changed,
			visiting,
		)
			delete!(visiting, value)
			return true
		end
	end
	if !(value isa _BuiltinMutationDict)
		for ind in 1:fieldcount(typeof(value))
			isdefined(value, ind) || continue
			if _contains_changed_mutation_container(
				getfield(value, ind),
				changed,
				visiting,
			)
				delete!(visiting, value)
				return true
			end
		end
	end
	delete!(visiting, value)
	return false
end

function _contains_changed_mutation_container(
	value::PlotlyBase.AbstractPlotlyAttribute,
	changed::IdDict{Any,Nothing},
	visiting::IdDict{Any,Any},
)
	haskey(changed, value) && return true
	_contains_visit_enter!(visiting, value) === :entered ||
		return false
	result = false
	if value isa _BuiltinPlotlyAttribute
		result = _contains_changed_mutation_container(
			value.fields,
			changed,
			visiting,
		)
	else
		for ind in 1:fieldcount(typeof(value))
			isdefined(value, ind) || continue
			result = _contains_changed_mutation_container(
				getfield(value, ind),
				changed,
				visiting,
			)
			result && break
		end
	end
	delete!(visiting, value)
	return result
end

function _contains_changed_mutation_container(
	value::AbstractArray,
	changed::IdDict{Any,Nothing},
	visiting::IdDict{Any,Any},
)
	haskey(changed, value) && return true
	scan_elements =
		_array_elements_may_be_mutation_containers(eltype(value))
	builtin_storage = _is_builtin_element_storage(value)
	builtin_storage && !scan_elements &&
		return false
	_contains_visit_enter!(visiting, value) === :entered ||
		return false
	backedges_before =
		get(visiting, _CONTAINS_BACKEDGE_COUNT, 0)
	found = false
	if scan_elements
		for ind in eachindex(value)
			isassigned(value, ind) || continue
			child = value[ind]
			found = _contains_changed_mutation_container(
				child,
				changed,
				visiting,
			)
			found && break
		end
	end
	if !found && !builtin_storage
		for ind in 1:fieldcount(typeof(value))
			isdefined(value, ind) || continue
			found = _contains_changed_mutation_container(
				getfield(value, ind),
				changed,
				visiting,
			)
			found && break
		end
	end
	# Cache a completed false result only when this traversal encountered no
	# backedge. Acyclic shared arrays are then scanned once, while unresolved
	# false cycles are deliberately retraversed rather than cached unsafely.
	if !found &&
			get(visiting, _CONTAINS_BACKEDGE_COUNT, 0) ==
				backedges_before
		visiting[value] = _CONTAINS_VISIT_FALSE
	else
		delete!(visiting, value)
	end
	return found
end

_copy_alias_mutation_container(
	value,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
) = _copy_alias_mutation_container(
	value,
	memo,
	changed,
	IdDict{Any,Nothing}(),
)

_copy_alias_mutation_container(
	value,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
	::IdDict{Any,Nothing},
) = begin
	_contains_changed_mutation_container(value, changed) ||
		return value
	if haskey(memo, value)
		staged = memo[value]
		ismutable(value) && staged === value &&
			throw(ArgumentError(
				"Aliased value cannot be staged independently.",
			))
		return staged
	end
	staged = Base.deepcopy_internal(value, memo)
	ismutable(value) && staged === value &&
		throw(ArgumentError(
			"Aliased value cannot be staged independently.",
		))
	return staged
end

function _dictionary_key_contains_changed(
	value::AbstractDict,
	changed::IdDict{Any,Nothing},
)
	for key in keys(value)
		_contains_changed_mutation_container(key, changed) &&
			return true
	end
	return false
end

function _copy_alias_mutation_container(
	value::_BuiltinMutationDict,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
	visiting::IdDict{Any,Nothing},
)
	if haskey(visiting, value)
		haskey(memo, value) || throw(AssertionError(
			"Active alias dictionary has no staged counterpart.",
		))
		return memo[value]
	end
	keys_changed =
		_dictionary_key_contains_changed(value, changed)
	if haskey(memo, value)
		staged = memo[value]
		(haskey(changed, value) ||
			_contains_changed_mutation_container(value, changed)) ||
			return value
		if keys_changed
			staged === value && throw(ArgumentError(
				"Aliased dictionary cannot be staged independently.",
			))
			visiting[value] = nothing
			try
				empty!(staged)
				for (key, child) in value
					staged[
						_copy_alias_mutation_container(
							key,
							memo,
							changed,
							visiting,
						)
					] = _copy_alias_mutation_container(
						child,
						memo,
						changed,
						visiting,
					)
				end
			finally
				delete!(visiting, value)
			end
			return staged
		end
		visiting[value] = nothing
		try
			for (key, child) in value
				haskey(staged, key) || continue
				staged_child = staged[key]
				if staged_child === child ||
						(haskey(memo, child) &&
						 memo[child] === staged_child)
					staged[key] = _copy_alias_mutation_container(
						child,
						memo,
						changed,
						visiting,
					)
				end
			end
		finally
			delete!(visiting, value)
		end
		return staged
	end
	_contains_changed_mutation_container(value, changed) ||
		return value
	staged = keys_changed ? empty(value) : copy(value)
	memo[value] = staged
	visiting[value] = nothing
	try
		for (key, child) in value
			staged[
				keys_changed ?
				_copy_alias_mutation_container(
					key,
					memo,
					changed,
					visiting,
				) :
				key
			] = _copy_alias_mutation_container(
				child,
				memo,
				changed,
				visiting,
			)
		end
	finally
		delete!(visiting, value)
	end
	return staged
end

function _copy_alias_mutation_container(
	value::AbstractDict,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
	::IdDict{Any,Nothing},
)
	_contains_changed_mutation_container(value, changed) ||
		return value
	if haskey(memo, value)
		staged = memo[value]
		staged === value && throw(ArgumentError(
			"Aliased dictionary cannot be staged independently.",
		))
		return staged
	end
	staged = Base.deepcopy_internal(value, memo)
	staged === value && throw(ArgumentError(
		"Aliased dictionary cannot be staged independently.",
	))
	return staged
end

function _copy_alias_mutation_container(
	value::_BuiltinPlotlyAttribute,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
	visiting::IdDict{Any,Nothing},
)
	if haskey(visiting, value)
		haskey(memo, value) || throw(AssertionError(
			"Active Plotly attribute has no staged counterpart.",
		))
		return memo[value]
	end
	if haskey(memo, value)
		staged = memo[value]
		(haskey(changed, value) ||
			_contains_changed_mutation_container(value, changed)) ||
			return value
		visiting[value] = nothing
		fields = try
			_copy_alias_mutation_container(
				value.fields,
				memo,
				changed,
				visiting,
			)
		finally
			delete!(visiting, value)
		end
		fields === staged.fields ||
			setfield!(staged, :fields, fields)
		return staged
	end
	_contains_changed_mutation_container(value, changed) ||
		return value
	# A shallow field copy provides a cycle-safe shell without triggering
	# PlotlyFrame's missing-name warning; recursive alias projection replaces
	# the shell fields before it can escape.
	staged = typeof(value)(copy(value.fields))
	memo[value] = staged
	visiting[value] = nothing
	fields = try
		_copy_alias_mutation_container(
			value.fields,
			memo,
			changed,
			visiting,
		)
	finally
		delete!(visiting, value)
	end
	setfield!(staged, :fields, fields)
	return staged
end

function _copy_alias_mutation_container(
	value::PlotlyBase.AbstractPlotlyAttribute,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
	::IdDict{Any,Nothing},
)
	_contains_changed_mutation_container(value, changed) ||
		return value
	if haskey(memo, value)
		staged = memo[value]
		staged === value && throw(ArgumentError(
			"Aliased Plotly attribute cannot be staged independently.",
		))
		return staged
	end
	staged = Base.deepcopy_internal(value, memo)
	staged === value && throw(ArgumentError(
		"Aliased Plotly attribute cannot be staged independently.",
	))
	return staged
end

function _copy_alias_mutation_container(
	value::AbstractArray,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
	visiting::IdDict{Any,Nothing},
)
	if haskey(visiting, value)
		haskey(memo, value) || throw(AssertionError(
			"Active alias array has no staged counterpart.",
		))
		return memo[value]
	end
	if haskey(memo, value)
		staged = memo[value]
		(haskey(changed, value) ||
			_contains_changed_mutation_container(value, changed)) ||
			return value
		axes(value) == axes(staged) || return staged
		visiting[value] = nothing
		try
			for ind in eachindex(value, staged)
				isassigned(value, ind) || continue
				isassigned(staged, ind) || continue
				child = value[ind]
				staged_child = staged[ind]
				if staged_child === child ||
						(haskey(memo, child) &&
						 memo[child] === staged_child)
					staged[ind] = _copy_alias_mutation_container(
						child,
						memo,
						changed,
						visiting,
					)
				end
			end
		finally
			delete!(visiting, value)
		end
		return staged
	end
	_contains_changed_mutation_container(value, changed) ||
		return value
	staged = copy(value)
	if staged === value ||
			typeof(staged) !== typeof(value) ||
			axes(staged) != axes(value)
		staged = Base.deepcopy_internal(value, memo)
		(staged === value ||
		 typeof(staged) !== typeof(value) ||
		 axes(staged) != axes(value)) &&
			throw(ArgumentError(
				"Aliased array cannot be staged independently.",
			))
		return staged
	end
	memo[value] = staged
	visiting[value] = nothing
	try
		for ind in eachindex(value)
			isassigned(value, ind) || continue
			staged[ind] = _copy_alias_mutation_container(
				value[ind],
				memo,
				changed,
				visiting,
			)
		end
	finally
		delete!(visiting, value)
	end
	return staged
end

function _clone_trace_for_alias_expansion(
	trace::GenericTrace,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
)
	if haskey(memo, trace)
		staged = memo[trace]
		(staged isa GenericTrace && staged !== trace) ||
			throw(ArgumentError(
				"Aliased trace cannot be staged independently.",
			))
		fields = _copy_alias_mutation_container(
			trace.fields,
			memo,
			changed,
		)
		fields === staged.fields ||
			setfield!(staged, :fields, fields)
		return staged
	end

	original_fields = getfield(trace, :fields)
	original_fields isa _BuiltinMutationDict || begin
		staged = Base.deepcopy_internal(trace, memo)
		staged !== trace || throw(ArgumentError(
			"Aliased trace cannot be staged independently.",
		))
		return staged::GenericTrace
	end

	if haskey(memo, original_fields)
		staged_fields = _copy_alias_mutation_container(
			original_fields,
			memo,
			changed,
		)
		staged = typeof(trace)(staged_fields)
		memo[trace] = staged
		return staged
	end

	# Install both shells before descending so a cycle through the trace root
	# reuses this exact staged trace instead of creating a second clone.
	staged_fields = copy(original_fields)
	(
		staged_fields !== original_fields &&
		typeof(staged_fields) === typeof(original_fields)
	) || begin
		staged = Base.deepcopy_internal(trace, memo)
		staged !== trace || throw(ArgumentError(
			"Aliased trace cannot be staged independently.",
		))
		return staged::GenericTrace
	end
	staged = typeof(trace)(staged_fields)
	memo[trace] = staged
	memo[original_fields] = staged_fields
	fields = _copy_alias_mutation_container(
		original_fields,
		memo,
		changed,
	)
	fields === staged_fields ||
		setfield!(staged, :fields, fields)
	return staged
end

function _clone_trace_for_alias_expansion(
	trace::AbstractTrace,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
)
	_contains_changed_mutation_container(trace, changed) ||
		return trace
	if haskey(memo, trace)
		staged = memo[trace]
		staged === trace && throw(ArgumentError(
			"Aliased trace cannot be staged independently.",
		))
		return staged::AbstractTrace
	end
	staged = Base.deepcopy_internal(trace, memo)
	staged === trace && throw(ArgumentError(
		"Aliased trace cannot be staged independently.",
	))
	return staged::AbstractTrace
end

function _clone_layout_for_alias_expansion(
	layout::Layout,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
)
	if haskey(memo, layout)
		staged = memo[layout]
		(staged isa Layout && staged !== layout) ||
			throw(ArgumentError(
				"Aliased layout cannot be staged independently.",
			))
	else
		original_fields = getfield(layout, :fields)
		original_fields isa _BuiltinMutationDict || begin
			staged = Base.deepcopy_internal(layout, memo)
			staged !== layout || throw(ArgumentError(
				"Aliased layout cannot be staged independently.",
			))
			return staged::Layout
		end
		if haskey(memo, original_fields)
			staged_fields = _copy_alias_mutation_container(
				original_fields,
				memo,
				changed,
			)
			staged = typeof(layout)(staged_fields)
			memo[layout] = staged
		else
			# As for traces, publish the layout and field shells before
			# recursively projecting aliases that may point back to the root.
			staged_fields = copy(original_fields)
			(
				staged_fields !== original_fields &&
				typeof(staged_fields) ===
					typeof(original_fields)
			) || begin
				staged = Base.deepcopy_internal(layout, memo)
				staged !== layout || throw(ArgumentError(
					"Aliased layout cannot be staged independently.",
				))
				return staged::Layout
			end
			staged = typeof(layout)(staged_fields)
			memo[layout] = staged
			memo[original_fields] = staged_fields
		end
	end

	fields = _copy_alias_mutation_container(
		layout.fields,
		memo,
		changed,
	)
	# Layout's constructor merges defaults; restore the exact staged fields.
	fields === staged.fields ||
		setfield!(staged, :fields, fields)
	subplots = _copy_alias_mutation_container(
		getfield(layout, :subplots),
		memo,
		changed,
	)
	setfield!(staged, :subplots, subplots)
	return staged
end

function _clone_layout_for_alias_expansion(
	layout::AbstractLayout,
	memo::IdDict{Any,Any},
	changed::IdDict{Any,Nothing},
)
	_contains_changed_mutation_container(layout, changed) ||
		return layout
	if haskey(memo, layout)
		staged = memo[layout]
		staged === layout && throw(ArgumentError(
			"Aliased layout cannot be staged independently.",
		))
		return staged::AbstractLayout
	end
	staged = Base.deepcopy_internal(layout, memo)
	staged === layout && throw(ArgumentError(
		"Aliased layout cannot be staged independently.",
	))
	return staged::AbstractLayout
end

function _data_membership_changed(
	original::AbstractVector,
	staged::AbstractVector,
	memo::IdDict{Any,Any},
)
	axes(original) == axes(staged) || return true
	for ind in eachindex(original, staged)
		original_assigned = isassigned(original, ind)
		staged_assigned = isassigned(staged, ind)
		original_assigned == staged_assigned || return true
		original_assigned || continue
		original_trace = original[ind]
		staged_trace = staged[ind]
		(
			staged_trace === original_trace ||
			(
				haskey(memo, original_trace) &&
				memo[original_trace] === staged_trace
			)
		) || return true
	end
	return false
end

function _expand_staged_alias_roots!(
	p::Plot,
	staged_traces::IdDict{AbstractTrace,AbstractTrace},
	staged_layout::Union{Nothing,AbstractLayout},
	memo::IdDict{Any,Any},
	;
	for_renderer::Bool = false,
	setter_origins::Union{Nothing,IdDict{Any,Nothing}} = nothing,
)
	pruned_roots = IdDict{Any,Any}()
	for (original, staged) in collect(staged_traces)
		original isa GenericTrace && continue
		if _staged_graph_unchanged(original, staged, memo)
			pruned_roots[staged] = original
			delete!(staged_traces, original)
		end
	end
	changed = IdDict{Any,Nothing}()
	contains_visiting = IdDict{Any,Any}()
	# Setter inputs can be caller-owned containers that also appear elsewhere
	# in the model. They are not necessarily reachable from the original side
	# of a newly inserted field, so inspect both staged model roots and every
	# copy-on-write memo pair. Structural graph diffing records the deepest
	# changed mutable nodes, including nodes behind arbitrary wrappers.
	diff_seen = IdDict{Any,Any}()
	for (original, staged) in staged_traces
		_collect_changed_graph_nodes!(
			changed,
			original,
			staged,
			memo,
			diff_seen,
		)
	end
	if staged_layout !== nothing
		_collect_changed_graph_nodes!(
			changed,
			p.layout,
			staged_layout,
			memo,
			diff_seen,
		)
	end
	for (original, staged) in collect(memo)
		_collect_changed_graph_nodes!(
			changed,
			original,
			staged,
			memo,
			diff_seen,
		)
	end
	isempty(changed) && return (
		data = nothing,
		layout = staged_layout,
		frames = nothing,
		config = nothing,
		render_payload = nothing,
	)

	if _contains_changed_mutation_container(
				p.layout,
				changed,
				contains_visiting,
			)
		if staged_layout === nothing
			staged_layout = _clone_layout_for_alias_expansion(
				p.layout,
				memo,
				changed,
			)
		elseif p.layout isa Layout &&
				staged_layout isa Layout
			fields = _copy_alias_mutation_container(
				p.layout.fields,
				memo,
				changed,
			)
			fields === staged_layout.fields ||
				setfield!(staged_layout, :fields, fields)
		end
	end

	for original in p.data
		_contains_changed_mutation_container(
			original,
			changed,
			contains_visiting,
		) || continue
		if haskey(staged_traces, original)
			trace = staged_traces[original]
			if original isa GenericTrace &&
					trace isa GenericTrace
				fields = _copy_alias_mutation_container(
					original.fields,
					memo,
					changed,
				)
				fields === trace.fields ||
					setfield!(trace, :fields, fields)
			end
		else
			staged_traces[original] = _clone_trace_for_alias_expansion(
				original,
				memo,
				changed,
			)
		end
	end

	staged_frames =
		_contains_changed_mutation_container(
			p.frames,
			changed,
			contains_visiting,
		) ?
		_copy_alias_mutation_container(
			p.frames,
			memo,
			changed,
		) :
		nothing
	staged_config =
		_contains_changed_mutation_container(
			p.config,
			changed,
			contains_visiting,
		) ?
		_copy_alias_mutation_container(
			p.config,
			memo,
			changed,
		) :
		nothing

	data_candidate = get(memo, p.data, nothing)
	data_changed =
		data_candidate !== nothing &&
		(
			_data_membership_changed(p.data, data_candidate, memo) ||
			(
				!(p.data isa Vector && data_candidate isa Vector) &&
				!_staged_graph_unchanged(
					p.data,
					data_candidate,
					memo,
				)
			)
		)
	needs_full_renderer_refresh =
		data_changed ||
		staged_frames !== nothing ||
		staged_config !== nothing ||
		any(
			original -> !(original isa GenericTrace),
			keys(staged_traces),
		) ||
		(
			staged_layout !== nothing &&
			!(p.layout isa Layout && staged_layout isa Layout)
		)
	render_payload =
		for_renderer && needs_full_renderer_refresh ?
		(
			data = _json_js(
				data_candidate === nothing ?
				_staged_candidate_data(p, staged_traces) :
				data_candidate,
			),
			layout = _json_js(
				staged_layout === nothing ?
					p.layout :
					staged_layout,
			),
			config = _json_js(
				staged_config === nothing ?
					p.config :
					staged_config,
			),
			frames = staged_frames === nothing ?
				nothing :
				_json_js(staged_frames),
		) :
		nothing

	preserved_roots = copy(pruned_roots)
	preserve_data_root =
		data_candidate !== nothing &&
		(
			!data_changed ||
			(p.data isa Vector && data_candidate isa Vector)
		)
	preserve_data_root &&
		(preserved_roots[data_candidate] = p.data)
	data_candidate !== nothing &&
		data_changed &&
		!preserve_data_root &&
		(preserved_roots[data_candidate] = data_candidate)
	# Any public trace cloned incidentally through an arbitrary wrapper must
	# project back to that trace when it is otherwise unchanged. This is
	# independent of whether the data vector itself was staged.
	for original in p.data
		haskey(memo, original) || continue
		staged = memo[original]
		_staged_graph_unchanged(original, staged, memo) &&
			(preserved_roots[staged] = original)
	end
	for (original, staged) in staged_traces
		original isa GenericTrace &&
			staged isa GenericTrace &&
			(preserved_roots[staged] = original)
	end
	if staged_layout !== nothing &&
			p.layout isa Layout &&
			staged_layout isa Layout
		preserved_roots[staged_layout] = p.layout
	end
	memoized_layout = get(memo, p.layout, nothing)
	if memoized_layout !== nothing &&
			(
				staged_layout === nothing ||
				(p.layout isa Layout && staged_layout isa Layout)
			)
		preserved_roots[memoized_layout] = p.layout
	end
	frame_candidate =
		staged_frames === nothing ?
		get(memo, p.frames, nothing) :
		staged_frames
	preserve_frames_root =
		frame_candidate !== nothing &&
		(
			staged_frames === nothing ||
			(p.frames isa Vector && frame_candidate isa Vector)
		)
	preserve_frames_root &&
		(preserved_roots[frame_candidate] = p.frames)
	config_candidate =
		staged_config === nothing ?
		get(memo, p.config, nothing) :
		staged_config
	config_candidate === nothing ||
		(preserved_roots[config_candidate] = p.config)

	model_memoized = IdDict{Any,Nothing}()
	if setter_origins !== nothing && !isempty(setter_origins)
		model_seen = IdDict{Any,Nothing}()
		for root in (p.data, p.layout, p.frames, p.config)
			_collect_model_memoized_identities!(
				model_memoized,
				root,
				memo,
				setter_origins,
				model_seen,
			)
		end
	end
	for original in keys(model_memoized)
		staged = memo[original]
		_staged_graph_unchanged(original, staged, memo) &&
			(preserved_roots[staged] = original)
	end

	root_translation = copy(preserved_roots)
	root_translation[p.data] = p.data
	root_translation[p.layout] = p.layout
	root_translation[p.frames] = p.frames
	root_translation[p.config] = p.config
	_seal_projection_targets!(
		root_translation,
	)
	if setter_origins !== nothing
		# Values that the optimized setter staging deliberately passed through
		# must retain their identity when a newly inserted plotting dictionary
		# is projected onto committed model roots. Memoized model identities
		# are excluded here because their staged counterparts require the
		# translations assembled below.
		for root in keys(setter_origins)
			haskey(memo, root) && continue
			haskey(root_translation, root) ||
				(root_translation[root] = root)
		end
	end
	if staged_layout !== nothing &&
			!(
				p.layout isa Layout &&
				staged_layout isa Layout
			)
		original_staged_layout = staged_layout
		staged_layout =
			Base.deepcopy_internal(
				original_staged_layout,
				root_translation,
			)
		root_translation[original_staged_layout] =
			staged_layout
	end
	if staged_frames !== nothing
		original_staged_frames = staged_frames
		delete!(root_translation, staged_frames)
		staged_frames, _ =
			_rebase_unchanged_mutation_container!(
				p.frames,
				staged_frames,
				memo,
				root_translation,
			)
		root_translation[original_staged_frames] =
			preserve_frames_root ? p.frames : staged_frames
	end
	if staged_config !== nothing
		original_staged_config = staged_config
		delete!(root_translation, staged_config)
		staged_config, _ =
			_rebase_unchanged_mutation_container!(
				p.config,
				staged_config,
				memo,
				root_translation,
			)
		root_translation[original_staged_config] = p.config
	end
	for (original, staged) in collect(staged_traces)
		original isa GenericTrace && continue
		rebased =
			Base.deepcopy_internal(
				staged,
				root_translation,
			)
		root_translation[staged] = rebased
		staged_traces[original] = rebased
	end
	for (original, staged) in staged_traces
		original isa GenericTrace &&
			staged isa GenericTrace &&
			_rebase_staged_trace!(
				original,
				staged,
				memo,
				root_translation,
			)
	end
	staged_layout === nothing ||
		_rebase_staged_layout!(
			p.layout,
			staged_layout,
			memo,
			root_translation,
		)

	if staged_frames !== nothing && preserve_frames_root
		root_translation[staged_frames] = p.frames
		projected_frames = copy(staged_frames)
		for ind in eachindex(staged_frames)
			isassigned(staged_frames, ind) || continue
			projected_frames[ind] =
				Base.deepcopy_internal(
					staged_frames[ind],
					root_translation,
				)
		end
		staged_frames = projected_frames
	end
	if staged_config !== nothing
		root_translation[staged_config] = p.config
		projected_config = typeof(p.config)()
		for ind in 1:fieldcount(typeof(staged_config))
			isdefined(staged_config, ind) || continue
			setfield!(
				projected_config,
				ind,
				Base.deepcopy_internal(
					getfield(staged_config, ind),
					root_translation,
				),
			)
		end
		staged_config = projected_config
	end
	staged_data = nothing
	if data_changed
		projected_data =
			preserve_data_root ? copy(data_candidate) : data_candidate
		for ind in eachindex(data_candidate)
			isassigned(data_candidate, ind) || continue
			projected_data[ind] = Base.deepcopy_internal(
				data_candidate[ind],
				root_translation,
			)
		end
		staged_data = projected_data
	end
	return (
		data = staged_data,
		layout = staged_layout,
		frames = staged_frames,
		config = staged_config,
		render_payload = render_payload,
	)
end

function _prepare_incremental_outer_root_commit!(
	p::Plot,
	expanded,
)
	if expanded.data !== nothing &&
			p.data isa Vector &&
			expanded.data isa Vector
		sizehint!(p.data, length(expanded.data))
	end
	if expanded.frames !== nothing &&
			p.frames isa Vector &&
			expanded.frames isa Vector
		sizehint!(p.frames, length(expanded.frames))
	end
	return expanded
end

function _commit_incremental_outer_roots!(
	p::Plot,
	expanded,
)
	if expanded.data !== nothing
		if p.data isa Vector &&
				expanded.data isa Vector
			resize!(p.data, length(expanded.data))
			copyto!(p.data, expanded.data)
		else
			setfield!(p, :data, expanded.data)
		end
	end
	if expanded.frames !== nothing
		if p.frames isa Vector &&
				expanded.frames isa Vector
			resize!(p.frames, length(expanded.frames))
			copyto!(p.frames, expanded.frames)
		else
			setfield!(p, :frames, expanded.frames)
		end
	end
	if expanded.config !== nothing
		for ind in 1:fieldcount(typeof(p.config))
			setfield!(
				p.config,
				ind,
				getfield(expanded.config, ind),
			)
		end
	end
	return p
end

function _incremental_candidate_model(
	p::Plot,
	data,
	layout,
	expanded,
)
	return Plot(
		data,
		layout,
		expanded.frames === nothing ?
			p.frames :
			expanded.frames,
		p.divid,
		expanded.config === nothing ?
			p.config :
			expanded.config,
	)
end

function _prepare_restyle_replacement_data(
	p::Plot,
	staged::IdDict{AbstractTrace,AbstractTrace},
)
	any(original -> !(original isa GenericTrace), keys(staged)) ||
		return nothing
	replacement_data = copy(p.data)
	for ind in eachindex(replacement_data)
		original = p.data[ind]
		if !(original isa GenericTrace) && haskey(staged, original)
			replacement_data[ind] = staged[original]
		end
	end
	return replacement_data
end

function _commit_restyle!(
	p::Plot,
	staged::IdDict{AbstractTrace,AbstractTrace},
	replacement_data,
)
	# Standard traces keep their identity by swapping the successfully staged
	# field dictionary. Third-party trace implementations are replaced only
	# after every staged update succeeds. For renderer transactions the
	# replacement vector is prepared before the renderer call.
	if replacement_data !== nothing
		copyto!(p.data, replacement_data)
	end
	for (original, trace) in staged
		if original isa GenericTrace
			setfield!(original, :fields, getfield(trace, :fields))
		end
	end
	return p
end

function _commit_restyle!(
	p::Plot,
	staged::IdDict{AbstractTrace,AbstractTrace},
)
	replacement_data = _prepare_restyle_replacement_data(p, staged)
	return _commit_restyle!(p, staged, replacement_data)
end

function _commit_layout!(p::Plot, staged::AbstractLayout)
	if p.layout isa Layout && staged isa Layout
		# Preserve Layout identity. Subplot routing metadata normally rebases
		# to the original value, but a projected replacement is required when
		# it carries an alias to a changed layout or trace container.
		setfield!(p.layout, :fields, staged.fields)
		setfield!(p.layout, :subplots, staged.subplots)
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
	memo = IdDict{Any,Any}()
	setter_origins = IdDict{Any,Nothing}()
	staged = _stage_restyle(
		p,
		(ind,),
		update,
		kwargs;
		vectorized = false,
		memo = memo,
		setter_origins = setter_origins,
	)
	_rebase_staged_traces!(staged, memo)
	expanded =
		_expand_staged_alias_roots!(
			p,
			staged,
			nothing,
			memo;
			setter_origins = setter_origins,
		)
	staged_layout = expanded.layout
	_prepare_incremental_outer_root_commit!(p, expanded)
	replacement_data =
		expanded.data === nothing ?
		_prepare_restyle_replacement_data(p, staged) :
		nothing
	_commit_restyle!(p, staged, replacement_data)
	staged_layout === nothing ||
		_commit_layout!(p, staged_layout)
	_commit_incremental_outer_roots!(p, expanded)
	return p
end

function _do_restyle!(
	p::Plot,
	inds::AbstractVector{Int},
	update::AbstractDict = Dict();
	kwargs...,
)
	memo = IdDict{Any,Any}()
	setter_origins = IdDict{Any,Nothing}()
	staged = _stage_restyle(
		p,
		inds,
		update,
		kwargs;
		vectorized = true,
		memo = memo,
		setter_origins = setter_origins,
	)
	_rebase_staged_traces!(staged, memo)
	expanded =
		_expand_staged_alias_roots!(
			p,
			staged,
			nothing,
			memo;
			setter_origins = setter_origins,
		)
	staged_layout = expanded.layout
	_prepare_incremental_outer_root_commit!(p, expanded)
	replacement_data =
		expanded.data === nothing ?
		_prepare_restyle_replacement_data(p, staged) :
		nothing
	_commit_restyle!(p, staged, replacement_data)
	staged_layout === nothing ||
		_commit_layout!(p, staged_layout)
	_commit_incremental_outer_roots!(p, expanded)
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
	memo = IdDict{Any,Any}()
	setter_origins = IdDict{Any,Nothing}()
	staged_layout = _clone_layout_for_mutation(p.layout, memo)
	_, prepared_layout = _prepare_relayout_inputs(
		(),
		layout.fields,
		memo,
		setter_origins,
		;
		strict = !(p.layout isa Layout),
	)
	relayout!(staged_layout; prepared_layout...)
	inds = ind isa Int ? (ind,) : ind
	staged_traces = _stage_restyle(
		p,
		inds,
		update,
		kwargs;
		vectorized = !(ind isa Int),
		memo = memo,
		setter_origins = setter_origins,
	)
	_rebase_staged_layout!(p.layout, staged_layout, memo)
	_rebase_staged_traces!(staged_traces, memo)
	expanded = _expand_staged_alias_roots!(
		p,
		staged_traces,
		staged_layout,
		memo;
		setter_origins = setter_origins,
	)
	staged_layout = expanded.layout
	_prepare_incremental_outer_root_commit!(p, expanded)

	replacement_data =
		expanded.data === nothing ?
		_prepare_restyle_replacement_data(p, staged_traces) :
		nothing
	_commit_restyle!(p, staged_traces, replacement_data)
	_commit_layout!(p, staged_layout)
	_commit_incremental_outer_roots!(p, expanded)
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

# ── Transactional renderer mutation helpers ────────────────────────

struct _CurrentPlotLayout end
const _CURRENT_PLOT_LAYOUT = _CurrentPlotLayout()

function _resolve_update_layout(p::Plot, requested)
	requested === _CURRENT_PLOT_LAYOUT && return p.layout
	requested isa AbstractLayout || throw(TypeError(
		:update!,
		"keyword argument `layout`",
		AbstractLayout,
		requested,
	))
	return requested
end

_plotly_delta_path(prefix::AbstractString, key) =
	isempty(prefix) ? string(key) : string(prefix, '.', key)

function _is_atomic_plotly_delta_attribute(key, original, staged)
	(original isa AbstractDict || staged isa AbstractDict) || return false
	(key isa Symbol || key isa AbstractString) || return false
	# `meta` is an arbitrary JSON value, not a schema-addressable object.
	# Emit it whole so literal dots in user keys never become Plotly.js paths.
	return Symbol(key) in (:geojson, :labelalias, :meta)
end

_is_plotly_delta_container(value) =
	value isa AbstractDict ||
	value isa PlotlyBase.AbstractPlotlyAttribute

function _is_staged_mutation_clone(original, staged, memo)
	memo === nothing && return false
	return haskey(memo, original) && memo[original] === staged
end

function _plotly_leaf_deltas!(
	deltas::Dict{String,Any},
	original,
	staged,
	path::String,
	memo,
)
	original === staged && return deltas
	isempty(path) || (deltas[path] = staged)
	return deltas
end

function _plotly_leaf_deltas!(
	deltas::Dict{String,Any},
	original::AbstractDict,
	staged::AbstractDict,
	path::String,
	memo,
)
	original === staged && return deltas
	for (key, original_value) in original
		child_path = _plotly_delta_path(path, key)
		if haskey(staged, key)
			staged_value = staged[key]
			if _is_atomic_plotly_delta_attribute(
				key,
				original_value,
				staged_value,
			)
				original_value === staged_value ||
					(deltas[child_path] = staged_value)
			elseif (_is_plotly_delta_container(original_value) ||
					_is_plotly_delta_container(staged_value)) &&
					!_is_staged_mutation_clone(
						original_value,
						staged_value,
						memo,
					)
				# A dictionary/attribute assigned wholesale is an atomic Plotly
				# value. Flatten only structural clones created by our nested
				# setter staging; otherwise dotted user keys (for example in
				# `meta`) would be misinterpreted as property paths.
				original_value === staged_value ||
					(deltas[child_path] = staged_value)
			else
				_plotly_leaf_deltas!(
					deltas,
					original_value,
					staged_value,
					child_path,
					memo,
				)
			end
		else
			# Plotly.js uses null to clear/reset a property.
			deltas[child_path] = nothing
		end
	end
	for (key, staged_value) in staged
		haskey(original, key) && continue
		deltas[_plotly_delta_path(path, key)] = staged_value
	end
	return deltas
end

function _plotly_leaf_deltas!(
	deltas::Dict{String,Any},
	original::PlotlyBase.AbstractPlotlyAttribute,
	staged::PlotlyBase.AbstractPlotlyAttribute,
	path::String,
	memo,
)
	original === staged && return deltas
	return _plotly_leaf_deltas!(
		deltas,
		original.fields,
		staged.fields,
		path,
		memo,
	)
end

function _plotly_leaf_deltas(
	original,
	staged,
	memo = nothing,
)
	deltas = Dict{String,Any}()
	_plotly_leaf_deltas!(deltas, original, staged, "", memo)
	return deltas
end

function _trace_delta_operations(
	p::Plot,
	staged::IdDict{AbstractTrace,AbstractTrace},
	memo::IdDict{Any,Any},
)
	deltas_by_trace = IdDict{AbstractTrace,Dict{String,Any}}()
	for (original, trace) in staged
		if original isa GenericTrace && trace isa GenericTrace
			deltas_by_trace[original] =
				_plotly_leaf_deltas(
					original.fields,
					trace.fields,
					memo,
				)
		end
	end

	grouped =
		Dict{String,Tuple{Vector{Int},Vector{Any}}}()
	for ind in eachindex(p.data)
		original = p.data[ind]
		haskey(deltas_by_trace, original) || continue
		for (path, value) in deltas_by_trace[original]
			indices, values = get!(
				() -> (Int[], Any[]),
				grouped,
				path,
			)
			push!(indices, Int(ind) - 1)
			push!(values, value)
		end
	end

	paths = sort!(collect(keys(grouped)))
	return [
		(
			path = path,
			indices = grouped[path][1],
			values = grouped[path][2],
		)
		for path in paths
	]
end

function _plotlyjs_delta_script(
	sp::SyncPlot,
	calls::Vector{String},
)
	isempty(calls) && return nothing
	divid_js = _json_js(sp.divid)
	body = join(calls, '\n')
	return """
(async function() {
  if (typeof Plotly === "undefined") return "plotly-not-loaded";
  const div = document.getElementById($divid_js);
  if (!div) return "plot-div-not-found";
$body
  return "ok";
})();
"""
end

function _plotlyjs_relayout_script(
	sp::SyncPlot,
	layout_delta::AbstractDict,
)
	isempty(layout_delta) && return nothing
	call = "  await Plotly.relayout(div, $(_json_js(layout_delta)));"
	return _plotlyjs_delta_script(sp, [call])
end

function _plotlyjs_restyle_script(sp::SyncPlot, operations)
	calls = String[]
	sizehint!(calls, length(operations))
	for operation in operations
		update = Dict{String,Any}(
			operation.path => operation.values,
		)
		push!(
			calls,
			"  await Plotly.restyle(div, $(_json_js(update)), " *
			"$(_json_js(operation.indices)));",
		)
	end
	return _plotlyjs_delta_script(sp, calls)
end

function _plotlyjs_update_script(
	sp::SyncPlot,
	trace_operations,
	layout_delta::AbstractDict,
)
	if isempty(trace_operations)
		return _plotlyjs_relayout_script(sp, layout_delta)
	end

	calls = String[]
	sizehint!(calls, length(trace_operations))
	first_operation = first(trace_operations)
	first_update = Dict{String,Any}(
		first_operation.path => first_operation.values,
	)
	push!(
		calls,
		"  await Plotly.update(div, $(_json_js(first_update)), " *
		"$(_json_js(layout_delta)), " *
		"$(_json_js(first_operation.indices)));",
	)
	for operation in Iterators.drop(trace_operations, 1)
		update = Dict{String,Any}(
			operation.path => operation.values,
		)
		push!(
			calls,
			"  await Plotly.restyle(div, $(_json_js(update)), " *
			"$(_json_js(operation.indices)));",
		)
	end
	return _plotlyjs_delta_script(sp, calls)
end

function _staged_candidate_data(
	p::Plot,
	staged::IdDict{AbstractTrace,AbstractTrace},
)
	data = copy(p.data)
	for ind in eachindex(data)
		original = p.data[ind]
		haskey(staged, original) && (data[ind] = staged[original])
	end
	return data
end

_has_third_party_staged_trace(
	staged::IdDict{AbstractTrace,AbstractTrace},
) = any(original -> !(original isa GenericTrace), keys(staged))

function _prepare_react_values(p::Plot, data, layout)
	data_type = fieldtype(typeof(p), :data)
	layout_type = fieldtype(typeof(p), :layout)
	# Mutable struct assignment converts to the declared field type. Perform
	# both conversions before rendering so commit cannot fail halfway through.
	return convert(data_type, data), convert(layout_type, layout)
end

function _syncplot_recovery_autoplay(sp::SyncPlot)
	spec = getfield(sp, :_resources).creation_spec
	return spec === nothing ? false : spec.autoplay
end

function _set_renderer_desynchronized!(
	sp::SyncPlot,
	value::Bool,
)
	getfield(sp, :_resources).renderer_desynchronized = value
	return nothing
end

function _rebuild_committed_renderer!(
	sp::SyncPlot,
	committed_model::Plot,
	operation_error = nothing,
)
	try
		_require_open_syncplot_window(sp)
		script = _plotlyjs_refresh_script(
			sp,
			committed_model.data,
			committed_model.layout;
			model = committed_model,
			rebuild = true,
			autoplay = _syncplot_recovery_autoplay(sp),
		)
		_require_open_syncplot_window(sp)
		_run_plotlyjs_script!(sp, script, "renderer recovery")
	catch recovery_error
		_set_renderer_desynchronized!(sp, true)
		throw(_SyncPlotDesynchronizationError(
			operation_error,
			recovery_error,
		))
	end
	_set_renderer_desynchronized!(sp, false)
	return nothing
end

function _ensure_renderer_synchronized!(
	sp::SyncPlot,
	committed_model::Plot,
)
	getfield(sp, :_resources).renderer_desynchronized || return nothing
	_rebuild_committed_renderer!(sp, committed_model)
	return nothing
end

function _run_transaction_renderer_script!(
	sp::SyncPlot,
	script::String,
	operation::String,
	committed_model::Plot,
)
	# Staging, diffing, JSON encoding, and both open checks have completed
	# before this try block. Therefore every caught error follows an actual
	# renderer attempt and requires recovery of the committed model.
	try
		_run_plotlyjs_script!(sp, script, operation)
	catch operation_error
		if operation_error isa InterruptException
			_set_renderer_desynchronized!(sp, true)
			throw(operation_error)
		end
		_rebuild_committed_renderer!(
			sp,
			committed_model,
			operation_error,
		)
		throw(operation_error)
	end
	return nothing
end

function _syncplot_registration_matches_locked(
	sp::SyncPlot,
	p::Plot,
	expectation::Symbol,
	expected_version::Union{Nothing,_PlotSyncPlotGeneration},
)
	getfield(sp, :plot) === p || return false
	_plot_syncplot_version(p) === expected_version || return false
	mapped = get(_PLOT_SYNCPLOT_MAP, p, nothing)
	if expectation === :mapped
		return mapped === sp
	elseif expectation === :unregistered
		return mapped === nothing
	end
	throw(ArgumentError(
		"unsupported SyncPlot registration expectation: $expectation",
	))
end

function _syncplot_registration_matches(
	sp::SyncPlot,
	p::Plot,
	expectation::Symbol,
	expected_version::Union{Nothing,_PlotSyncPlotGeneration},
)
	return lock(_SYNCPLOT_REGISTRY_LOCK) do
		_syncplot_registration_matches_locked(
			sp,
			p,
			expectation,
			expected_version,
		)
	end
end

function _execute_syncplot_transaction_locked!(
	sp::SyncPlot,
	prepare;
	expected_plot::Union{Nothing,Plot} = nothing,
	registration_expectation::Symbol = :mapped,
	expected_version::Union{Nothing,_PlotSyncPlotGeneration} = nothing,
)
	if expected_plot !== nothing &&
			!_syncplot_registration_matches(
				sp,
				expected_plot,
				registration_expectation,
				expected_version,
			)
		return :stale
	end

	committed_model = getfield(sp, :plot)
	expected_plot === nothing || committed_model === expected_plot ||
		return :stale
	prepared = prepare(sp, committed_model)
	rendered = prepared.script !== nothing

	# Preparation performs bounds/type validation and JSON serialization. Check
	# the registration generation again before the first renderer effect so an
	# invalid call or concurrent remap remains side-effect free.
	if expected_plot !== nothing &&
			!_syncplot_registration_matches(
				sp,
				expected_plot,
				registration_expectation,
				expected_version,
			)
		return :stale
	end

	_require_open_syncplot_window(sp)
	_ensure_renderer_synchronized!(sp, committed_model)
	if expected_plot !== nothing &&
			!_syncplot_registration_matches(
				sp,
				expected_plot,
				registration_expectation,
				expected_version,
			)
		return :stale
	end
	if rendered
		_require_open_syncplot_window(sp)
		_run_transaction_renderer_script!(
			sp,
			prepared.script,
			prepared.operation,
			committed_model,
		)
	end

	resources = getfield(sp, :_resources)
	status = try
		lock(resources.lock) do
			resources.close_started && throw(InvalidStateException(
				"SyncPlot window is not open",
				:not_open,
			))
			lock(_SYNCPLOT_REGISTRY_LOCK) do
				if expected_plot !== nothing
					if !_syncplot_registration_matches_locked(
							sp,
							expected_plot,
							registration_expectation,
							expected_version,
						)
						return :stale
					end
				end
				prepared.commit()
				return :committed
			end
		end
	catch post_render_error
		# The renderer has accepted the candidate, but Julia commit did not
		# return normally. Its exact linearization point is unknowable under an
		# asynchronous exception, so force a committed-model rebuild before the
		# next mutation instead of claiming synchronization.
		rendered && _set_renderer_desynchronized!(sp, true)
		throw(post_render_error)
	end

	if status === :stale && rendered
		_rebuild_committed_renderer!(
			sp,
			committed_model,
			ErrorException(
				"SyncPlot registration changed before transaction commit.",
			),
		)
	end
	return status
end

function _syncplot_transaction_status!(
	sp::SyncPlot,
	prepare;
	required_plot::Union{Nothing,Plot} = nothing,
	reserved_plot::Union{Nothing,Plot} = nothing,
)
	resources = getfield(sp, :_resources)
	lock(resources.render_lock)
	reservations = Tuple{Plot,_SyncPlotReservation}[]
	owner_claimed = false
	try
		resources.transaction_owner === nothing ||
			throw(InvalidStateException(
				"Reentrant SyncPlot mutation is not supported",
				:reentrant,
			))
		resources.transaction_owner = current_task()
		owner_claimed = true

		current = getfield(sp, :plot)
		_require_syncplot_model(current)
		reserved_plot === nothing ||
			_require_syncplot_model(reserved_plot)
		required_plot === nothing || current === required_plot ||
			return :stale

		expectation, version = lock(_SYNCPLOT_REGISTRY_LOCK) do
			mapped = get(_PLOT_SYNCPLOT_MAP, current, nothing)
			if mapped !== nothing && mapped !== sp
				required_plot === nothing ||
					return (:stale, nothing)
				throw(InvalidStateException(
					"SyncPlot model is displayed by a different SyncPlot",
					:remapped,
				))
			end

			current_reservation, current_added =
				_reserve_plot_for_syncplot!(
					current,
					sp,
					:current,
				)
			current_added &&
				push!(reservations, (current, current_reservation))

			if reserved_plot !== nothing && reserved_plot !== current
				candidate_mapping =
					get(_PLOT_SYNCPLOT_MAP, reserved_plot, nothing)
				candidate_mapping === nothing ||
					throw(InvalidStateException(
						"Replacement Plot is already displayed by a SyncPlot",
						:remapped,
					))
				candidate_reservation, candidate_added =
					_reserve_plot_for_syncplot!(
						reserved_plot,
						sp,
						:candidate,
					)
				candidate_added &&
					push!(
						reservations,
						(reserved_plot, candidate_reservation),
					)
			end

			registration_expectation =
				mapped === sp ? :mapped : :unregistered
			return (
				registration_expectation,
				_plot_syncplot_version(current),
			)
		end

		expectation === :stale && return :stale
		status = _execute_syncplot_transaction_locked!(
			sp,
			prepare;
			expected_plot = current,
			registration_expectation = expectation,
			expected_version = version,
		)
		return status
	finally
		try
			lock(_SYNCPLOT_REGISTRY_LOCK) do
				for (plot, reservation) in Iterators.reverse(reservations)
					_release_plot_syncplot_reservation!(
						plot,
						reservation,
					)
				end
			end
		finally
			try
				owner_claimed &&
					(resources.transaction_owner = nothing)
			finally
				unlock(resources.render_lock)
			end
		end
	end
end

function _syncplot_transaction!(
	sp::SyncPlot,
	prepare;
	reserved_plot::Union{Nothing,Plot} = nothing,
)
	status = _syncplot_transaction_status!(
		sp,
		prepare;
		reserved_plot = reserved_plot,
	)
	status === :committed || throw(InvalidStateException(
		"SyncPlot registration changed before transaction commit",
		:remapped,
	))
	return sp
end

function _transactional_plot_mutation!(
	p::Plot,
	prepare,
	local_mutation,
)
	while true
		route = lock(_SYNCPLOT_REGISTRY_LOCK) do
			reservation =
				get(_PLOT_SYNCPLOT_RESERVATIONS, p, nothing)
			if reservation === nothing
				return (
					:syncplot,
					get(_PLOT_SYNCPLOT_MAP, p, nothing),
					nothing,
				)
			elseif reservation.kind === :local
				return (
					:wait,
					nothing,
					reservation,
				)
			end
			return (:syncplot, reservation.syncplot, nothing)
		end
		action, sp, reservation = route
		if action === :wait
			if reservation.owner === current_task()
				throw(InvalidStateException(
					"Reentrant Plot mutation is not supported",
					:reentrant,
				))
			end
			wait(reservation.done::Base.Event)
			continue
		end

		if sp === nothing
			outcome =
				_try_local_plot_mutation!(local_mutation, p)
			outcome === :committed && return p
			continue
		end

		status = _syncplot_transaction_status!(
			sp,
			prepare;
			required_plot = p,
		)
		status === :committed && return p
		yield()
	end
end

function _prepare_relayout_transaction(
	sp::SyncPlot,
	p::Plot,
	args,
	kwargs,
)
	memo = IdDict{Any,Any}()
	setter_origins = IdDict{Any,Nothing}()
	staged_layout = _clone_layout_for_mutation(p.layout, memo)
	staged_traces = IdDict{AbstractTrace,AbstractTrace}()
	prepared_args, prepared_kwargs =
		_prepare_relayout_inputs(
			args,
			kwargs,
			memo,
			setter_origins,
			;
			strict = !(p.layout isa Layout),
		)
	relayout!(staged_layout, prepared_args...; prepared_kwargs...)
	_rebase_staged_layout!(p.layout, staged_layout, memo)
	expanded = _expand_staged_alias_roots!(
		p,
		staged_traces,
		staged_layout,
		memo,
		;
		for_renderer = true,
		setter_origins = setter_origins,
	)
	staged_layout = expanded.layout
	_prepare_incremental_outer_root_commit!(p, expanded)
	replacement_data =
		expanded.data === nothing ?
		_prepare_restyle_replacement_data(p, staged_traces) :
		nothing

	outer_root_changed =
		expanded.data !== nothing ||
		expanded.frames !== nothing ||
		expanded.config !== nothing
	full_refresh =
		outer_root_changed ||
		_has_third_party_staged_trace(staged_traces) ||
		!(p.layout isa Layout && staged_layout isa Layout)
	script = if !full_refresh &&
			p.layout isa Layout &&
			staged_layout isa Layout
		trace_operations =
			_trace_delta_operations(p, staged_traces, memo)
		layout_delta =
			_plotly_leaf_deltas(
				p.layout.fields,
				staged_layout.fields,
				memo,
			)
		isempty(trace_operations) ?
		_plotlyjs_relayout_script(sp, layout_delta) :
		_plotlyjs_update_script(
			sp,
			trace_operations,
			layout_delta,
		)
	else
		expanded.render_payload === nothing && throw(AssertionError(
			"Missing coherent renderer payload for relayout refresh.",
		))
		_plotlyjs_refresh_payload_script(
			sp,
			expanded.render_payload;
			rebuild = expanded.frames !== nothing,
		)
	end
	commit = () -> begin
		_commit_restyle!(p, staged_traces, replacement_data)
		_commit_layout!(p, staged_layout)
		_commit_incremental_outer_roots!(p, expanded)
		return p
	end
	operation = expanded.frames !== nothing ?
		"newPlot" :
		(full_refresh ? "react" : "relayout")
	return (script = script, operation = operation, commit = commit)
end

function _prepare_restyle_transaction(
	sp::SyncPlot,
	p::Plot,
	inds,
	update,
	kwargs;
	vectorized::Bool,
)
	memo = IdDict{Any,Any}()
	setter_origins = IdDict{Any,Nothing}()
	staged = _stage_restyle(
		p,
		inds,
		update,
		kwargs;
		vectorized = vectorized,
		memo = memo,
		setter_origins = setter_origins,
	)
	_rebase_staged_traces!(staged, memo)
	expanded =
		_expand_staged_alias_roots!(
			p,
			staged,
			nothing,
			memo;
			for_renderer = true,
			setter_origins = setter_origins,
		)
	staged_layout = expanded.layout
	_prepare_incremental_outer_root_commit!(p, expanded)
	replacement_data =
		expanded.data === nothing ?
		_prepare_restyle_replacement_data(p, staged) :
		nothing

	outer_root_changed =
		expanded.data !== nothing ||
		expanded.frames !== nothing ||
		expanded.config !== nothing
	full_refresh =
		outer_root_changed ||
			_has_third_party_staged_trace(staged) ||
			(staged_layout !== nothing &&
			 !(p.layout isa Layout && staged_layout isa Layout))
	script = if full_refresh
		expanded.render_payload === nothing && throw(AssertionError(
			"Missing coherent renderer payload for restyle refresh.",
		))
		_plotlyjs_refresh_payload_script(
			sp,
			expanded.render_payload;
			rebuild = expanded.frames !== nothing,
		)
	else
		trace_operations = _trace_delta_operations(p, staged, memo)
		layout_delta = staged_layout === nothing ?
			Dict{String,Any}() :
			_plotly_leaf_deltas(
				p.layout.fields,
				staged_layout.fields,
				memo,
			)
		isempty(layout_delta) ?
		_plotlyjs_restyle_script(sp, trace_operations) :
		_plotlyjs_update_script(sp, trace_operations, layout_delta)
	end
	commit = () -> begin
		_commit_restyle!(p, staged, replacement_data)
		staged_layout === nothing ||
			_commit_layout!(p, staged_layout)
		_commit_incremental_outer_roots!(p, expanded)
		return p
	end
	operation = expanded.frames !== nothing ?
		"newPlot" :
		(full_refresh ? "react" : "restyle")
	return (script = script, operation = operation, commit = commit)
end

function _prepare_update_transaction(
	sp::SyncPlot,
	p::Plot,
	ind,
	update,
	layout,
	kwargs,
)
	memo = IdDict{Any,Any}()
	setter_origins = IdDict{Any,Nothing}()
	staged_layout = _clone_layout_for_mutation(p.layout, memo)
	_, prepared_layout = _prepare_relayout_inputs(
		(),
		layout.fields,
		memo,
		setter_origins,
		;
		strict = !(p.layout isa Layout),
	)
	relayout!(staged_layout; prepared_layout...)
	inds = ind isa Int ? (ind,) : ind
	staged = _stage_restyle(
		p,
		inds,
		update,
		kwargs;
		vectorized = !(ind isa Int),
		memo = memo,
		setter_origins = setter_origins,
	)
	_rebase_staged_layout!(p.layout, staged_layout, memo)
	_rebase_staged_traces!(staged, memo)
	expanded = _expand_staged_alias_roots!(
		p,
		staged,
		staged_layout,
		memo,
		;
		for_renderer = true,
		setter_origins = setter_origins,
	)
	staged_layout = expanded.layout
	_prepare_incremental_outer_root_commit!(p, expanded)
	replacement_data =
		expanded.data === nothing ?
		_prepare_restyle_replacement_data(p, staged) :
		nothing

	outer_root_changed =
		expanded.data !== nothing ||
		expanded.frames !== nothing ||
		expanded.config !== nothing
	full_refresh =
		outer_root_changed ||
			!(p.layout isa Layout && staged_layout isa Layout) ||
			_has_third_party_staged_trace(staged)
	script = if full_refresh
		expanded.render_payload === nothing && throw(AssertionError(
			"Missing coherent renderer payload for update refresh.",
		))
		_plotlyjs_refresh_payload_script(
			sp,
			expanded.render_payload;
			rebuild = expanded.frames !== nothing,
		)
	else
		_plotlyjs_update_script(
			sp,
			_trace_delta_operations(p, staged, memo),
			_plotly_leaf_deltas(
				p.layout.fields,
				staged_layout.fields,
				memo,
			),
		)
	end
	commit = () -> begin
		_commit_restyle!(p, staged, replacement_data)
		_commit_layout!(p, staged_layout)
		_commit_incremental_outer_roots!(p, expanded)
		return p
	end
	operation = expanded.frames !== nothing ?
		"newPlot" :
		(full_refresh ? "react" : "update")
	return (script = script, operation = operation, commit = commit)
end

function _prepare_purge_transaction(sp::SyncPlot, p::Plot)
	# Validate every field update before the renderer effect. Standard
	# vector-backed models preserve their public data-container identity.
	# Other Plot parameterizations must admit an empty field-compatible
	# replacement; otherwise fail without purging the renderer.
	layout_type = fieldtype(typeof(p), :layout)
	staged_layout = convert(layout_type, Layout())
	replacement_data = if p.data isa Vector
		nothing
	else
		data_type = fieldtype(typeof(p), :data)
		convert(
			data_type,
			Vector{eltype(p.data)}(undef, 0),
		)
	end
	script = _plotlyjs_command_script(sp, :purge)
	commit = () -> begin
		if replacement_data === nothing
			empty!(p.data)
		else
			setfield!(p, :data, replacement_data)
		end
		setfield!(p, :layout, staged_layout)
		return p
	end
	return (script = script, operation = "purge", commit = commit)
end

# ── SyncPlot methods ────────────────────────────────────────────────
# Renderer-backed model mutations stage and encode their complete candidate,
# render it, and only then publish non-allocating pointer swaps to Julia.

function PlotlyBase.react!(sp::SyncPlot, data::AbstractVector{<:AbstractTrace}, layout::AbstractLayout)
	prepare = function (target, current)
		staged_data, staged_layout =
			_prepare_react_values(current, data, layout)
		script = _plotlyjs_refresh_script(
			target,
			staged_data,
			staged_layout;
			model = current,
		)
		commit = () -> begin
			setfield!(current, :data, staged_data)
			setfield!(current, :layout, staged_layout)
			return current
		end
		return (script = script, operation = "react", commit = commit)
	end
	return _syncplot_transaction!(sp, prepare)
end

function PlotlyBase.react!(sp::SyncPlot, p::Plot)
	prepare = function (target, current)
		script = _plotlyjs_refresh_script(
			target,
			p.data,
			p.layout;
			model = p,
			rebuild = true,
			autoplay = true,
		)
		commit = () -> begin
			if p !== current
				reservation =
					get(_PLOT_SYNCPLOT_RESERVATIONS, p, nothing)
				(reservation !== nothing &&
				 reservation.syncplot === target &&
				 reservation.kind === :candidate) ||
					throw(InvalidStateException(
						"Replacement Plot reservation was lost",
						:remapped,
					))

				current_mapping =
					get(_PLOT_SYNCPLOT_MAP, current, nothing)
				candidate_mapping =
					get(_PLOT_SYNCPLOT_MAP, p, nothing)
				candidate_mapping === nothing ||
					throw(InvalidStateException(
						"Replacement Plot became displayed before commit",
						:remapped,
					))
				if current_mapping === target
					# Publish the replacement mapping before removing the old
					# key so insertion cannot orphan the committed model.
					_PLOT_SYNCPLOT_MAP[p] = target
					_bump_plot_syncplot_version!(p)
					delete!(_PLOT_SYNCPLOT_MAP, current)
					_bump_plot_syncplot_version!(current)
				elseif current_mapping !== nothing
					throw(InvalidStateException(
						"SyncPlot model was remapped before replacement commit",
						:remapped,
					))
				end
			end
			setfield!(target, :plot, p)
			return target
		end
		return (script = script, operation = "newPlot", commit = commit)
	end
	return _syncplot_transaction!(
		sp,
		prepare;
		reserved_plot = p,
	)
end

function PlotlyBase.relayout!(sp::SyncPlot, args...; kwargs...)
	prepare = (target, current) ->
		_prepare_relayout_transaction(
			target,
			current,
			args,
			kwargs,
		)
	return _syncplot_transaction!(sp, prepare)
end

function PlotlyBase.restyle!(sp::SyncPlot, ind::Int, update::AbstractDict = Dict(); kwargs...)
	prepare = (target, current) ->
		_prepare_restyle_transaction(
			target,
			current,
			(ind,),
			update,
			kwargs;
			vectorized = false,
		)
	return _syncplot_transaction!(sp, prepare)
end

function PlotlyBase.restyle!(sp::SyncPlot, inds::AbstractVector{Int}, update::AbstractDict = Dict(); kwargs...)
	prepare = (target, current) ->
		_prepare_restyle_transaction(
			target,
			current,
			inds,
			update,
			kwargs;
			vectorized = true,
		)
	return _syncplot_transaction!(sp, prepare)
end

function PlotlyBase.restyle!(sp::SyncPlot, update::AbstractDict = Dict(); kwargs...)
	prepare = (target, current) ->
		_prepare_restyle_transaction(
			target,
			current,
			1:length(current.data),
			update,
			kwargs;
			vectorized = true,
		)
	return _syncplot_transaction!(sp, prepare)
end

_noop_plot_commit(::Plot) = nothing

function _prepare_full_model_mutation_transaction(
	sp::Union{Nothing,SyncPlot},
	p::Plot,
	mutation,
	commit_callback = _noop_plot_commit,
	mutation_scope = nothing,
	preserve_layout_vector::Union{Nothing,Symbol} = nothing,
)
	# Full-refresh compatibility mutators can change the data vector, trace
	# attributes, and layout in one call. Stage the complete mutable model graph
	# while retaining immutable and bulk numeric payloads. A shared memo keeps
	# aliases between traces and layout intact without deep-copying plot data.
	memo = IdDict{Any,Any}()
	staged_traces = IdDict{AbstractTrace,AbstractTrace}()
	staged_data = copy(p.data)
	memo[p.data] = staged_data
	# Clone custom roots first. Their general deepcopy discovers every shared
	# object; optimized GenericTrace/Layout cloning can then reuse those memoized
	# counterparts without deep-copying ordinary numeric payloads globally.
	for original in p.data
		original isa GenericTrace && continue
		get!(
			() -> _clone_trace_for_mutation(original, memo),
			staged_traces,
			original,
		)
	end
	for ind in eachindex(staged_data)
		original = p.data[ind]
		staged_data[ind] = get!(
			() -> _clone_trace_for_mutation(original, memo),
			staged_traces,
			original,
		)
	end
	staged_layout = _clone_layout_for_mutation(p.layout, memo)
	if p.layout isa Layout && staged_layout isa Layout
		# PlotlyBase.add_trace! and the shape helpers route through the subplot
		# grid metadata. They only read it, so sharing it during staging avoids
		# a large deepcopy unless a custom root already cloned that metadata to
		# preserve a cross-root alias.
		original_subplots = getfield(p.layout, :subplots)
		setfield!(
			staged_layout,
			:subplots,
			_copy_mutation_container(
				original_subplots,
				memo,
			),
		)
	end
	if mutation_scope === nothing
		# An unscoped internal mutation may address any Plot field directly.
		# Isolate both outer roots before invoking an unknown callback.
		staged_frames = Base.deepcopy_internal(p.frames, memo)
		staged_config = Base.deepcopy_internal(p.config, memo)
	else
		# Scoped public mutators address traces/layout directly. Stage
		# frames/config only when those roots reach them (or descendants)
		# through identity aliases. Revisit both roots once so an alias first
		# discovered while cloning config also pulls in frames, and vice versa.
		staged_frames =
			_stage_cross_aliased_model_root(p.frames, memo)
		staged_config =
			_stage_cross_aliased_model_root(p.config, memo)
		staged_frames =
			_stage_cross_aliased_model_root(p.frames, memo)
		staged_config =
			_stage_cross_aliased_model_root(p.config, memo)
	end

	candidate = Plot(
		staged_data,
		staged_layout,
		staged_frames,
		p.divid,
		staged_config,
	)
	mutation(candidate)
	affected_roots =
		_full_model_mutation_affected_roots(
			p,
			mutation_scope,
		)

	# A changed third-party root cannot be committed in place. Replace only its
	# alias-connected component, including GenericTrace or Layout roots when a
	# custom object points at them. Unrelated components retain public roots.
	replace_roots = _full_model_replacement_roots(
		p,
		candidate,
		staged_traces,
		memo,
		affected_roots,
	)
	replace_layout_root =
		replace_roots !== nothing && replace_roots[p.layout]
	replace_data_root =
		replace_roots !== nothing && replace_roots[p.data]
	replace_frames_root =
		replace_roots !== nothing && replace_roots[p.frames]
	replace_config_root =
		replace_roots !== nothing && replace_roots[p.config]
	frames_changed =
		candidate.frames !== p.frames &&
		!_staged_graph_unchanged(
			p.frames,
			candidate.frames,
			memo,
		)
	config_changed =
		candidate.config !== p.config &&
		!_staged_graph_unchanged(
			p.config,
			candidate.config,
			memo,
		)
	# Concrete vectors can publish changed frame membership without replacing
	# their public root. Other AbstractVector implementations have no
	# non-allocating, method-independent commit contract, so retain the exact
	# staged root and let alias rebasing target it.
	replace_frames_root |=
		frames_changed &&
		!(p.frames isa Vector && candidate.frames isa Vector)

	preserved_layout_attributes = IdDict{Any,Any}()
	if preserve_layout_vector !== nothing &&
			!replace_layout_root &&
			p.layout isa Layout &&
			candidate.layout isa Layout
		original_values =
			get(p.layout.fields, preserve_layout_vector, nothing)
		staged_values =
			get(candidate.layout.fields, preserve_layout_vector, nothing)
		if original_values isa AbstractVector &&
				staged_values isa AbstractVector &&
				axes(original_values) == axes(staged_values)
			for ind in eachindex(original_values)
				isassigned(original_values, ind) || continue
				isassigned(staged_values, ind) || continue
				original = original_values[ind]
				staged = staged_values[ind]
				if original isa _BuiltinPlotlyAttribute &&
						staged isa _BuiltinPlotlyAttribute &&
						haskey(memo, original) &&
						memo[original] === staged
					preserved_layout_attributes[original] = staged
				end
			end
		end
	end

	# Vector layout updaters mutate their existing PlotlyAttribute elements in
	# PlotlyBase. Serialize the coherent staged graph before commit projection
	# maps those staged elements back onto their public identities.
	early_script =
		sp !== nothing && !isempty(preserved_layout_attributes) ?
		_plotlyjs_refresh_script(
			sp,
			candidate.data,
			candidate.layout;
			model = candidate,
			rebuild = frames_changed,
		) :
		nothing

	preserved_staged_roots = IdDict{Any,Any}()
	for (original, staged) in staged_traces
		(
			replace_roots === nothing ||
			!replace_roots[original]
		) &&
			(preserved_staged_roots[staged] = original)
	end
	if !replace_layout_root &&
			haskey(memo, p.layout)
		preserved_staged_roots[memo[p.layout]] = p.layout
	end
	if !replace_data_root &&
			haskey(memo, p.data)
		preserved_staged_roots[memo[p.data]] = p.data
	end
	if !replace_frames_root &&
			haskey(memo, p.frames)
		preserved_staged_roots[memo[p.frames]] = p.frames
	end
	if !replace_config_root &&
			haskey(memo, p.config)
		preserved_staged_roots[memo[p.config]] = p.config
	end
	for (original, staged) in preserved_layout_attributes
		preserved_staged_roots[staged] = original
	end
	_seal_projection_targets!(
		preserved_staged_roots,
	)

	committed_layout_attribute_fields = IdDict{Any,Any}()
	for (original, staged) in preserved_layout_attributes
		fields, _ = _rebase_unchanged_mutation_container!(
			original.fields,
			staged.fields,
			memo,
			preserved_staged_roots,
		)
		committed_layout_attribute_fields[original] = fields
	end
	for (original, staged) in staged_traces
		if original isa GenericTrace &&
				staged isa GenericTrace &&
				(
					replace_roots === nothing ||
					!replace_roots[original]
				)
			_rebase_staged_trace!(
				original,
				staged,
				memo,
				preserved_staged_roots,
			)
		end
	end
	if !replace_layout_root
		_rebase_staged_layout!(
			p.layout,
			candidate.layout,
			memo,
			preserved_staged_roots,
		)
	end

	committed_frames = candidate.frames
	committed_config = candidate.config
	if (frames_changed && !replace_frames_root) ||
			(config_changed && !replace_config_root)
		# First traverse unchanged roots to record staged-descendant → original
		# mappings. Then clone changed roots through that same memo. This keeps
		# cross-root aliases exact even when a changed vector reordered or
		# deleted elements, where positional rebasing is not meaningful.
		translated_roots = copy(preserved_staged_roots)
		# An unscoped callback may deliberately insert an original public root
		# into a changed outer root. Treat those captured originals as terminal
		# identities instead of deepcopying them during commit preparation.
		translated_roots[p.data] = p.data
		translated_roots[p.layout] = p.layout
		translated_roots[p.frames] = p.frames
		translated_roots[p.config] = p.config
		for original in p.data
			translated_roots[original] = original
		end
		!replace_frames_root &&
			candidate.frames !== p.frames &&
			delete!(translated_roots, candidate.frames)
		!replace_config_root &&
			candidate.config !== p.config &&
			delete!(translated_roots, candidate.config)
		reachable_staged_nodes = IdDict{Any,Nothing}()
		!replace_frames_root &&
			_collect_graph_mutable_identities!(
				reachable_staged_nodes,
				candidate.frames,
			)
		!replace_config_root &&
			_collect_graph_mutable_identities!(
				reachable_staged_nodes,
				candidate.config,
			)
		for (original, staged) in collect(memo)
			haskey(reachable_staged_nodes, staged) || continue
			haskey(translated_roots, staged) && continue
			_staged_graph_unchanged(
				original,
				staged,
				memo,
			) || continue
			translated_roots[staged] = original
		end
		!replace_frames_root &&
			candidate.frames !== p.frames &&
			delete!(translated_roots, candidate.frames)
		!replace_config_root &&
			candidate.config !== p.config &&
			delete!(translated_roots, candidate.config)
		if !replace_frames_root &&
				!frames_changed &&
				candidate.frames !== p.frames
			_, unchanged =
				_rebase_unchanged_mutation_container!(
					p.frames,
					candidate.frames,
					memo,
					translated_roots,
				)
			unchanged || throw(ArgumentError(
				"Frame change detection disagreed with root rebasing.",
			))
		end
		if !replace_config_root &&
				!config_changed &&
				candidate.config !== p.config
			_, unchanged =
				_rebase_unchanged_mutation_container!(
					p.config,
					candidate.config,
					memo,
					translated_roots,
				)
			unchanged || throw(ArgumentError(
				"Config change detection disagreed with root rebasing.",
			))
		end
		!replace_frames_root &&
			(translated_roots[candidate.frames] = p.frames)
		!replace_config_root &&
			(translated_roots[candidate.config] = p.config)
		if frames_changed && !replace_frames_root
			committed_frames = copy(candidate.frames)
			for ind in eachindex(candidate.frames)
				isassigned(candidate.frames, ind) || continue
				committed_frames[ind] =
					Base.deepcopy_internal(
						candidate.frames[ind],
						translated_roots,
					)
			end
		end
		if config_changed && !replace_config_root
			committed_config = typeof(p.config)()
			for ind in 1:fieldcount(typeof(candidate.config))
				isdefined(candidate.config, ind) || continue
				setfield!(
					committed_config,
					ind,
					Base.deepcopy_internal(
						getfield(candidate.config, ind),
						translated_roots,
					),
				)
			end
		end
	end
	if frames_changed && !replace_frames_root
		committed_frames isa Vector ||
			throw(ArgumentError(
				"Changed frames cannot preserve their public root.",
			))
		sizehint!(p.frames, length(committed_frames))
	end
	if config_changed && !replace_config_root
		typeof(committed_config) === typeof(p.config) ||
			throw(ArgumentError(
				"Changed config cannot preserve its public root.",
			))
	end

	# Restore roots outside dirty custom components. Roots inside such a
	# component remain the exact staged objects, preserving root and nested
	# alias topology without rewriting arbitrary third-party structs.
	committed_data =
		replace_data_root ?
		candidate.data :
		copy(candidate.data)
	for ind in eachindex(committed_data)
		committed_data[ind] = get(
			preserved_staged_roots,
			candidate.data[ind],
			candidate.data[ind],
		)
	end

	data_unchanged =
		!replace_data_root &&
		_data_roots_unchanged(committed_data, p.data)

	# Mutators that operate on a concrete Vector in place preserve its public
	# identity. Reserve required capacity before the renderer effect so the
	# commit consists only of non-allocating resize/copy operations. If neither
	# an in-place commit nor a field-compatible replacement is possible, the
	# conversion fails here before Plotly.js observes the candidate.
	preserve_data_identity =
		!data_unchanged &&
		!replace_data_root &&
		candidate.data === staged_data &&
		p.data isa Vector
	if data_unchanged
		nothing
	elseif preserve_data_identity
		sizehint!(p.data, length(committed_data))
	else
		data_type = fieldtype(typeof(p), :data)
		if replace_data_root
			committed_data isa data_type ||
				throw(ArgumentError(
					"Aliased staged data cannot be committed " *
					"without changing its identity.",
				))
		else
			committed_data =
				convert(data_type, committed_data)
		end
	end

	script = if sp === nothing
		nothing
	elseif early_script !== nothing
		early_script
	else
		_plotlyjs_refresh_script(
			sp,
			candidate.data,
			candidate.layout;
			model = candidate,
			rebuild = frames_changed,
		)
	end
	commit = () -> begin
		for (original, fields) in committed_layout_attribute_fields
			setfield!(original, :fields, fields)
		end
		for (original, staged) in staged_traces
			if original isa GenericTrace &&
					staged isa GenericTrace &&
					(
						replace_roots === nothing ||
						!replace_roots[original]
					)
				setfield!(
					original,
					:fields,
					getfield(staged, :fields),
				)
			end
		end
		if replace_layout_root
			setfield!(p, :layout, candidate.layout)
		elseif p.layout isa Layout &&
				candidate.layout isa Layout
				_commit_layout!(p, candidate.layout)
		end
		if replace_frames_root
			setfield!(p, :frames, candidate.frames)
		elseif frames_changed
			resize!(p.frames, length(committed_frames))
			copyto!(p.frames, committed_frames)
		end
		if replace_config_root
			setfield!(p, :config, candidate.config)
		elseif config_changed
			for ind in 1:fieldcount(typeof(p.config))
				setfield!(
					p.config,
					ind,
					getfield(committed_config, ind),
				)
			end
		end
		if data_unchanged
			nothing
		elseif preserve_data_identity
			resize!(p.data, length(committed_data))
			copyto!(p.data, committed_data)
		else
			setfield!(p, :data, committed_data)
		end
		commit_callback(p)
		return p
	end
	return (
		script = script,
		operation = frames_changed ? "newPlot" : "react",
		commit = commit,
	)
end

function _data_roots_unchanged(
	candidate::AbstractVector{<:AbstractTrace},
	original::AbstractVector{<:AbstractTrace},
)
	length(candidate) == length(original) || return false
	for (candidate_trace, original_trace) in zip(candidate, original)
		candidate_trace === original_trace || return false
	end
	return true
end

function _copy_high_level_layout_container(
	value,
	memo::IdDict{Any,Any},
	shared_roots::Vector{Any},
	supported::Base.RefValue{Bool},
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			(
				value isa Function &&
				fieldcount(typeof(value)) == 0
			) ||
			value isa BigInt ||
			value isa BigFloat
		return value
	end
	haskey(memo, value) && return memo[value]
	if value isa AbstractArray
		# High-level plotting helpers replace layout arrays; they never mutate
		# an existing array or one of its elements. Keep large annotations,
		# layers, and template payloads shared, then reject the fast path below
		# if one reaches a layout container that the helper can mutate.
		push!(shared_roots, value)
		return value
	end
	if value isa AbstractDict ||
			value isa PlotlyBase.AbstractPlotlyAttribute ||
			ismutable(value)
		supported[] = false
		return value
	end

	# Immutable wrappers cannot themselves be changed. Their mutable members
	# remain read-only on this path and are included in the alias check.
	push!(shared_roots, value)
	return value
end

function _is_high_level_readonly_layout_payload(key, value)
	(key isa Symbol || key isa AbstractString) || return false
	Symbol(key) in (
		:geojson,
		:labelalias,
		:meta,
		:style,
		:template,
	) || return false
	return value isa AbstractDict ||
		value isa AbstractArray ||
		value isa PlotlyBase.AbstractPlotlyAttribute
end

function _copy_high_level_layout_container(
	value::_BuiltinMutationDict,
	memo::IdDict{Any,Any},
	shared_roots::Vector{Any},
	supported::Base.RefValue{Bool},
)
	haskey(memo, value) && return memo[value]
	staged = empty(value)
	memo[value] = staged
	for (key, child) in value
		staged[
			_copy_high_level_layout_container(
				key,
				memo,
				shared_roots,
				supported,
			)
		] = if _is_high_level_readonly_layout_payload(
			key,
			child,
		)
			push!(shared_roots, child)
			child
		else
			_copy_high_level_layout_container(
				child,
				memo,
				shared_roots,
				supported,
			)
		end
	end
	return staged
end

function _copy_high_level_layout_container(
	value::_BuiltinPlotlyAttribute,
	memo::IdDict{Any,Any},
	shared_roots::Vector{Any},
	supported::Base.RefValue{Bool},
)
	haskey(memo, value) && return memo[value]
	original_fields = value.fields
	original_fields isa _BuiltinMutationDict || begin
		supported[] = false
		return value
	end
	if haskey(memo, original_fields)
		staged_fields = memo[original_fields]
		staged = typeof(value)(copy(original_fields))
		setfield!(staged, :fields, staged_fields)
		memo[value] = staged
		return staged
	end
	staged_fields = copy(original_fields)
	if staged_fields === original_fields ||
			typeof(staged_fields) !== typeof(original_fields)
		supported[] = false
		return value
	end
	staged = typeof(value)(staged_fields)
	memo[value] = staged
	memo[original_fields] = staged_fields
	for (key, child) in original_fields
		staged_fields[key] = if _is_high_level_readonly_layout_payload(
			key,
			child,
		)
			push!(shared_roots, child)
			child
		else
			_copy_high_level_layout_container(
				child,
				memo,
				shared_roots,
				supported,
			)
		end
	end
	return staged
end

function _clone_high_level_layout_for_mutation(layout::Layout)
	original_fields = getfield(layout, :fields)
	original_fields isa _BuiltinMutationDict || return nothing
	staged_fields = copy(original_fields)
	(
		staged_fields !== original_fields &&
		typeof(staged_fields) === typeof(original_fields)
	) || return nothing

	staged_layout = typeof(layout)(staged_fields)
	setfield!(staged_layout, :fields, staged_fields)
	setfield!(
		staged_layout,
		:subplots,
		getfield(layout, :subplots),
	)
	memo = IdDict{Any,Any}(
		layout => staged_layout,
		original_fields => staged_fields,
	)
	shared_roots = Any[]
	supported = Ref(true)
	for (key, child) in original_fields
		staged_fields[key] = if _is_high_level_readonly_layout_payload(
			key,
			child,
		)
			push!(shared_roots, child)
			child
		else
			_copy_high_level_layout_container(
				child,
				memo,
				shared_roots,
				supported,
			)
		end
	end
	supported[] || return nothing
	return (
		layout = staged_layout,
		memo = memo,
		shared_roots = shared_roots,
	)
end

function _high_level_layout_has_external_alias(
	p::Plot,
	memo::IdDict{Any,Any},
	shared_roots::Vector{Any},
)
	identities = IdDict{Any,Nothing}()
	for (original, staged) in memo
		original === staged && continue
		ismutable(original) || continue
		identities[original] = nothing
	end
	isempty(identities) && return false

	path = Any[]
	for root in shared_roots
		_modern_map_graph_contains_identity(
			root,
			identities,
			path,
		) && return true
	end
	for root in (
		p.data,
		p.frames,
		p.config,
		getfield(p.layout, :subplots),
	)
		_modern_map_graph_contains_identity(
			root,
			identities,
			path,
		) && return true
	end
	return false
end

function _prepare_high_level_plot_fast_context(p::Plot)
	p.data isa Vector || return nothing
	p.layout isa Layout || return nothing
	cloned = _clone_high_level_layout_for_mutation(p.layout)
	cloned === nothing && return nothing
	_high_level_layout_has_external_alias(
		p,
		cloned.memo,
		cloned.shared_roots,
	) && return nothing

	staged_data = copy(p.data)
	(
		staged_data !== p.data &&
		typeof(staged_data) === typeof(p.data)
	) || return nothing
	candidate = Plot(
		staged_data,
		cloned.layout,
		p.frames,
		p.divid,
		p.config,
	)
	(
		candidate.data === staged_data &&
		candidate.layout === cloned.layout &&
		candidate.frames === p.frames &&
		candidate.config === p.config
	) || return nothing
	return (
		candidate = candidate,
		staged_data = staged_data,
		staged_layout = cloned.layout,
		memo = cloned.memo,
	)
end

function _plotlyjs_high_level_append_script(
	sp::SyncPlot,
	new_traces::AbstractVector{<:AbstractTrace},
	layout_delta::AbstractDict,
)
	calls = String[]
	if !isempty(new_traces)
		push!(
			calls,
			"  await Plotly.addTraces(div, $(_json_js(new_traces)));",
		)
	end
	if !isempty(layout_delta)
		push!(
			calls,
			"  await Plotly.relayout(div, $(_json_js(layout_delta)));",
		)
	end
	return _plotlyjs_delta_script(sp, calls)
end

function _finish_high_level_plot_fast_transaction(
	sp::Union{Nothing,SyncPlot},
	p::Plot,
	context,
	mutation,
	commit_callback = _noop_plot_commit,
)
	candidate = context.candidate
	mutation(candidate)
	(
		candidate.data === context.staged_data &&
		candidate.layout === context.staged_layout &&
		candidate.frames === p.frames &&
		candidate.config === p.config
	) || throw(ArgumentError(
		"High-level plot mutators may only append traces and update layout.",
	))

	original_length = length(p.data)
	length(candidate.data) >= original_length ||
		throw(ArgumentError(
			"High-level plot mutators may not remove traces.",
		))
	for index in eachindex(p.data)
		candidate.data[index] === p.data[index] ||
			throw(ArgumentError(
				"High-level plot mutators may not replace existing traces.",
			))
	end

	_rebase_staged_layout!(
		p.layout,
		context.staged_layout,
		context.memo,
	)
	new_trace_count = length(candidate.data) - original_length
	new_traces = candidate.data[(original_length + 1):end]
	sizehint!(p.data, length(candidate.data))

	layout_delta = sp === nothing ?
		Dict{String,Any}() :
		_plotly_leaf_deltas(
			p.layout.fields,
			context.staged_layout.fields,
			context.memo,
		)
	script = sp === nothing ?
		nothing :
		_plotlyjs_high_level_append_script(
			sp,
			new_traces,
			layout_delta,
		)
	commit = () -> begin
		if new_trace_count > 0
			resize!(p.data, length(candidate.data))
			copyto!(
				p.data,
				original_length + 1,
				candidate.data,
				original_length + 1,
				new_trace_count,
			)
		end
		_commit_layout!(p, context.staged_layout)
		commit_callback(p)
		return p
	end
	operation = if new_trace_count > 0
		isempty(layout_delta) ? "addTraces" : "addTraces/relayout"
	else
		"relayout"
	end
	return (script = script, operation = operation, commit = commit)
end

function _prepare_high_level_plot_mutation_transaction(
	sp::Union{Nothing,SyncPlot},
	p::Plot,
	fast_mutation,
	full_mutation,
	commit_callback = _noop_plot_commit,
)
	context = _prepare_high_level_plot_fast_context(p)
	context === nothing &&
		return _prepare_full_model_mutation_transaction(
			sp,
			p,
			full_mutation,
			commit_callback,
		)
	return _finish_high_level_plot_fast_transaction(
		sp,
		p,
		context,
		fast_mutation,
		commit_callback,
	)
end

function _prepare_structural_data_mutation_transaction(
	sp::Union{Nothing,SyncPlot},
	p::Plot,
	mutation,
)
	# Membership and ordering operations do not mutate trace/layout graphs.
	# Stage only the data container so existing and newly supplied trace roots
	# retain their exact public identities.
	staged_data = copy(p.data)
	candidate = Plot(
		staged_data,
		p.layout,
		p.frames,
		p.divid,
		p.config,
	)
	mutation(candidate)

	committed_data = candidate.data
	data_unchanged =
		_data_roots_unchanged(committed_data, p.data)
	preserve_data_identity =
		!data_unchanged &&
		candidate.data === staged_data &&
		p.data isa Vector
	if data_unchanged
		nothing
	elseif preserve_data_identity
		# Reserve growth before the renderer effect. The post-render commit can
		# then resize/copy without failing from an allocation.
		sizehint!(p.data, length(committed_data))
	else
		data_type = fieldtype(typeof(p), :data)
		committed_data = convert(data_type, committed_data)
	end

	script = sp === nothing ?
		nothing :
		_plotlyjs_refresh_script(
			sp,
			candidate.data,
			candidate.layout;
			model = candidate,
		)
	commit = () -> begin
		if data_unchanged
			nothing
		elseif preserve_data_identity
			resize!(p.data, length(committed_data))
			copyto!(p.data, committed_data)
		else
			setfield!(p, :data, committed_data)
		end
		return p
	end
	return (
		script = script,
		operation = "react",
		commit = commit,
	)
end

function _mutate_and_refresh_syncplot!(
	mutation,
	sp::SyncPlot;
	commit_callback = _noop_plot_commit,
	mutation_scope = nothing,
	preserve_layout_vector::Union{Nothing,Symbol} = nothing,
)
	prepare = (target, current) ->
		_prepare_full_model_mutation_transaction(
			target,
			current,
			mutation,
			commit_callback,
			mutation_scope,
			preserve_layout_vector,
		)
	_syncplot_transaction!(sp, prepare)
	return sp
end

function _mutate_structural_data_and_refresh_syncplot!(
	mutation,
	sp::SyncPlot,
)
	prepare = (target, current) ->
		_prepare_structural_data_mutation_transaction(
			target,
			current,
			mutation,
		)
	_syncplot_transaction!(sp, prepare)
	return sp
end

function _transactional_model_plot_mutation!(
	p::Plot;
	prepare,
	local_mutation,
)
	while true
		route = lock(_SYNCPLOT_REGISTRY_LOCK) do
			reservation =
				get(_PLOT_SYNCPLOT_RESERVATIONS, p, nothing)
			if reservation === nothing
				return (
					:syncplot,
					get(_PLOT_SYNCPLOT_MAP, p, nothing),
					nothing,
				)
			elseif reservation.kind === :local
				return (
					:wait,
					nothing,
					reservation,
				)
			elseif reservation.kind === :candidate
				state = reservation.owner === current_task() ?
					:reentrant :
					:busy
				throw(InvalidStateException(
					"Plot is participating in a model replacement",
					state,
				))
			end
			return (:syncplot, reservation.syncplot, nothing)
		end
		action, sp, reservation = route
		if action === :wait
			if reservation.owner === current_task()
				throw(InvalidStateException(
					"Reentrant Plot mutation is not supported",
					:reentrant,
				))
			end
			wait(reservation.done::Base.Event)
			continue
		end

		if sp === nothing
			outcome =
				_try_local_plot_mutation!(local_mutation, p)
			outcome === :committed && return p
			continue
		end

		status = _syncplot_transaction_status!(
			sp,
			prepare;
			required_plot = p,
		)
		status === :committed && return p
		yield()
	end
end

function _transactional_full_plot_mutation!(
	mutation,
	p::Plot;
	commit_callback = _noop_plot_commit,
	mutation_scope = nothing,
	preserve_layout_vector::Union{Nothing,Symbol} = nothing,
)
	prepare = (target, current) ->
		_prepare_full_model_mutation_transaction(
			target,
			current,
			mutation,
			commit_callback,
			mutation_scope,
			preserve_layout_vector,
		)
	local_mutation = () -> begin
		prepared = _prepare_full_model_mutation_transaction(
			nothing,
			p,
			mutation,
			commit_callback,
			mutation_scope,
			preserve_layout_vector,
		)
		prepared.commit()
		return p
	end
	return _transactional_model_plot_mutation!(
		p;
		prepare = prepare,
		local_mutation = local_mutation,
	)
end

function _transactional_high_level_model_mutation!(
	fast_mutation,
	full_mutation,
	p::Plot,
	commit_callback = _noop_plot_commit,
)
	prepare = (target, current) ->
		_prepare_high_level_plot_mutation_transaction(
			target,
			current,
			fast_mutation,
			full_mutation,
			commit_callback,
		)
	local_mutation = () -> begin
		prepared =
			_prepare_high_level_plot_mutation_transaction(
				nothing,
				p,
				fast_mutation,
				full_mutation,
				commit_callback,
			)
		prepared.commit()
		return p
	end
	return _transactional_model_plot_mutation!(
		p;
		prepare = prepare,
		local_mutation = local_mutation,
	)
end

function _transactional_structural_plot_mutation!(
	mutation,
	p::Plot,
)
	prepare = (target, current) ->
		_prepare_structural_data_mutation_transaction(
			target,
			current,
			mutation,
		)
	local_mutation = () -> begin
		prepared = _prepare_structural_data_mutation_transaction(
			nothing,
			p,
			mutation,
		)
		prepared.commit()
		return p
	end
	return _transactional_model_plot_mutation!(
		p;
		prepare = prepare,
		local_mutation = local_mutation,
	)
end

_trace_mutation_scope(indices) = (
	trace_indices = collect(indices),
	layout = false,
)
const _LAYOUT_ONLY_MUTATION_SCOPE = (
	trace_indices = (),
	layout = true,
)

function PlotlyBase.addtraces!(sp::SyncPlot, traces::AbstractTrace...)
	return _mutate_structural_data_and_refresh_syncplot!(sp) do current
		_do_addtraces!(current, traces...)
	end
end

function PlotlyBase.addtraces!(sp::SyncPlot, i::Int, traces::AbstractTrace...)
	return _mutate_structural_data_and_refresh_syncplot!(sp) do current
		_do_addtraces!(current, i, traces...)
	end
end

function PlotlyBase.deletetraces!(sp::SyncPlot, inds::Int...)
	return _mutate_structural_data_and_refresh_syncplot!(sp) do current
		_do_deletetraces!(current, inds...)
	end
end

function PlotlyBase.movetraces!(sp::SyncPlot, to_end::Int...)
	return _mutate_structural_data_and_refresh_syncplot!(sp) do current
		_do_movetraces!(current, to_end...)
	end
end

function PlotlyBase.movetraces!(sp::SyncPlot, src::AbstractVector{Int}, dest::AbstractVector{Int})
	return _mutate_structural_data_and_refresh_syncplot!(sp) do current
		_do_movetraces!(current, src, dest)
	end
end

function PlotlyBase.extendtraces!(sp::SyncPlot, update::AbstractDict, indices::AbstractVector{Int} = [1], maxpoints = -1)
	stable_indices = collect(indices)
	return _mutate_and_refresh_syncplot!(
		sp;
		mutation_scope =
			_trace_mutation_scope(stable_indices),
	) do current
		_do_extendtraces!(
			current,
			update,
			stable_indices,
			maxpoints,
		)
	end
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
	stable_indices = collect(indices)
	return _mutate_and_refresh_syncplot!(
		sp;
		mutation_scope =
			_trace_mutation_scope(stable_indices),
	) do current
		_do_prependtraces!(
			current,
			update,
			stable_indices,
			maxpoints,
		)
	end
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

function PlotlyBase.update!(
	sp::SyncPlot,
	ind::Union{AbstractVector{Int},Int},
	update::AbstractDict = Dict();
	layout = _CURRENT_PLOT_LAYOUT,
	kwargs...,
)
	prepare = function (target, current)
		resolved_layout = _resolve_update_layout(current, layout)
		return _prepare_update_transaction(
			target,
			current,
			ind,
			update,
			resolved_layout,
			kwargs,
		)
	end
	return _syncplot_transaction!(sp, prepare)
end

function PlotlyBase.update!(
	sp::SyncPlot,
	update = Dict();
	layout = _CURRENT_PLOT_LAYOUT,
	kwargs...,
)
	prepare = function (target, current)
		resolved_layout = _resolve_update_layout(current, layout)
		return _prepare_update_transaction(
			target,
			current,
			1:length(current.data),
			update,
			resolved_layout,
			kwargs,
		)
	end
	return _syncplot_transaction!(sp, prepare)
end

function PlotlyBase.update_xaxes!(sp::SyncPlot, args...; kwargs...)
	return _mutate_and_refresh_syncplot!(
		sp;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_do_update_xaxes!(current, args...; kwargs...)
	end
end

function PlotlyBase.update_yaxes!(sp::SyncPlot, args...; kwargs...)
	return _mutate_and_refresh_syncplot!(
		sp;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_do_update_yaxes!(current, args...; kwargs...)
	end
end

function PlotlyBase.update_polars!(sp::SyncPlot, args...; kwargs...)
	return _mutate_and_refresh_syncplot!(
		sp;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_do_update_polars!(current, args...; kwargs...)
	end
end

function PlotlyBase.update_mapboxes!(
	sp::SyncPlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _mutate_and_refresh_syncplot!(
		sp;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_update_mapboxes_preserving_aliases!(
			current.layout,
			with;
			kwargs...,
		)
	end
end

function _shallow_clone_modern_map_container(value)
	if value isa _BuiltinPlotlyAttribute &&
		(value.fields isa Dict || value.fields isa IdDict)
		return typeof(value)(copy(value.fields))
	elseif value isa Dict || value isa IdDict
		return copy(value)
	end
	return value
end

function _memoize_modern_map_clone!(
	memo::IdDict{Any,Any},
	original,
	staged,
)
	staged === original && return nothing
	ismutable(original) || return nothing
	memo[original] = staged
	if original isa _BuiltinPlotlyAttribute &&
		staged isa _BuiltinPlotlyAttribute &&
		original.fields !== staged.fields
		memo[original.fields] = staged.fields
	end
	return nothing
end

function _modern_map_builtin_storage(value)
	if value isa _BuiltinPlotlyAttribute &&
		(value.fields isa Dict || value.fields isa IdDict)
		return value.fields
	elseif value isa Dict || value isa IdDict
		return value
	end
	return nothing
end

function _stage_modern_map_nested_containers!(
	original,
	staged,
	memo::IdDict{Any,Any},
	staged_nested::IdDict{Any,Any},
)
	original_storage = _modern_map_builtin_storage(original)
	staged_storage = _modern_map_builtin_storage(staged)
	(
		original_storage === nothing ||
		staged_storage === nothing
	) && return nothing

	for (stored_key, original_nested) in original_storage
		Symbol(stored_key) in (:center, :bounds) || continue
		staged_value = get(staged_nested, original_nested, nothing)
		if staged_value === nothing
			staged_value =
				_shallow_clone_modern_map_container(original_nested)
			if staged_value !== original_nested
				staged_nested[original_nested] = staged_value
				_memoize_modern_map_clone!(
					memo,
					original_nested,
					staged_value,
				)
			end
		end
		staged_storage[stored_key] = staged_value
	end
	return nothing
end

function _modern_map_update_keys(
	layout::Layout,
	target_key::Union{Nothing,Symbol},
)
	target_key === nothing || return Symbol[target_key]
	targets = Symbol[
		key for key in keys(layout.fields)
		if _is_modern_map_layout_key(key)
	]
	:map in targets || pushfirst!(targets, :map)
	return targets
end

function _copy_map_update_without_domain(
	update::PlotlyBase.PlotlyAttribute,
)
	filtered = attr()
	for (key, value) in update.fields
		Symbol(key) === :domain && continue
		filtered.fields[Symbol(key)] = value
	end
	return filtered
end

function _stage_modern_map_layout_update(
	layout::Layout,
	with::PlotlyBase.PlotlyAttribute,
	kwargs;
	target_key::Union{Nothing,Symbol} = nothing,
	protect_domain::Bool = false,
)
	update = _combined_map_update(with, kwargs)
	if target_key === nothing
		_require_valid_map_update(layout, update)
	else
		current = get(layout.fields, target_key, attr())
		probe = Layout()
		probe.fields[:map] = current
		_require_valid_map_update(probe, update)
	end

	staged_fields = copy(layout.fields)
	staged_layout = typeof(layout)(staged_fields)
	# Layout's public constructor may merge defaults. Publish the exact shallow
	# shell and retain read-only subplot routing metadata for the candidate.
	setfield!(staged_layout, :fields, staged_fields)
	setfield!(
		staged_layout,
		:subplots,
		getfield(layout, :subplots),
	)

	memo = IdDict{Any,Any}(
		layout => staged_layout,
		layout.fields => staged_fields,
	)
	staged_roots = IdDict{Any,Any}()
	staged_nested = IdDict{Any,Any}()
	targets = _modern_map_update_keys(layout, target_key)
	for key in targets
		haskey(layout.fields, key) || continue
		original = layout.fields[key]
		staged = get(
			staged_roots,
			original,
			nothing,
		)
		if staged === nothing
			staged = _shallow_clone_modern_map_container(
				original,
			)
			staged !== original &&
				(staged_roots[original] = staged)
		end
		staged_fields[key] = staged
		if staged !== original
			_memoize_modern_map_clone!(memo, original, staged)
			_stage_modern_map_nested_containers!(
				original,
				staged,
				memo,
				staged_nested,
			)
		end
	end

	if target_key === nothing
		_update_all_maps!(staged_layout, update)
	else
		effective_update =
			protect_domain ?
			_copy_map_update_without_domain(update) :
			update
		_merge_layout_attr!(
			staged_layout,
			target_key,
			effective_update;
			deep_merge_keys = (:center, :bounds),
			mutate_builtin_target = true,
		)
	end
	_require_valid_map_layouts(staged_layout)
	return staged_layout, memo, staged_roots, staged_nested
end

function _commit_modern_map_layout!(
	p::Plot,
	staged_layout::Layout,
	::IdDict{Any,Any},
)
	# Changed, unaliased map containers are copy-on-write roots. Sharing one
	# root among multiple target map keys is retained by staging it once.
	# Alias-connected roots take the general graph-preserving transaction path
	# before this commit is constructed.
	_commit_layout!(p, staged_layout)
	return p
end

function _modern_map_graph_contains_identity(
	value,
	identities::IdDict{Any,Nothing},
	path::Vector{Any},
)
	if isbits(value) ||
			value isa Symbol ||
			value isa String ||
			value isa Type ||
			value isa Module ||
			value isa BigInt ||
			value isa BigFloat
		return false
	end
	haskey(identities, value) && return true
	for ancestor in path
		ancestor === value && return false
	end
	push!(path, value)
	try
		if value isa AbstractDict
			for (key, child) in value
				_modern_map_graph_contains_identity(
					key,
					identities,
					path,
				) && return true
				_modern_map_graph_contains_identity(
					child,
					identities,
					path,
				) && return true
			end
			# Third-party dictionaries can keep public alias-bearing metadata
			# outside their key/value iteration.
			if value isa Dict || value isa IdDict
				return false
			end
		elseif value isa AbstractArray
			if _array_elements_may_be_mutation_containers(
				eltype(value),
			)
				for index in eachindex(value)
					isassigned(value, index) || continue
					_modern_map_graph_contains_identity(
						value[index],
						identities,
						path,
					) && return true
				end
			end
			# Built-in storage has no public graph beyond its elements.
			_is_builtin_element_storage(value) && return false
		end

		for index in 1:fieldcount(typeof(value))
			isdefined(value, index) || continue
			_modern_map_graph_contains_identity(
				getfield(value, index),
				identities,
				path,
			) && return true
		end
		return false
	finally
		pop!(path)
	end
end

function _modern_map_root_contents_have_alias(
	root,
	identities::IdDict{Any,Nothing},
	path::Vector{Any},
)
	storage =
		root isa _BuiltinPlotlyAttribute ?
		root.fields :
		root
	storage isa AbstractDict || return false
	for (key, value) in storage
		_modern_map_graph_contains_identity(
			key,
			identities,
			path,
		) && return true
		_modern_map_graph_contains_identity(
			value,
			identities,
			path,
		) && return true
	end
	return false
end

function _modern_map_roots_have_external_alias(
	p::Plot,
	target_key::Union{Nothing,Symbol},
	staged_roots::IdDict{Any,Any},
	staged_nested::IdDict{Any,Any},
)
	(
		isempty(staged_roots) &&
		isempty(staged_nested)
	) && return false
	target_keys = _modern_map_update_keys(
		p.layout,
		target_key,
	)
	identities = IdDict{Any,Nothing}()
	for root in keys(staged_roots)
		identities[root] = nothing
		if root isa _BuiltinPlotlyAttribute
			identities[root.fields] = nothing
		end
	end
	path = Any[]

	# A shallow clone also needs a full graph transaction when one target root
	# contains another target root (or a back-reference to its own storage).
	for root in keys(staged_roots)
		_modern_map_root_contents_have_alias(
			root,
			identities,
			path,
		) && return true
	end
	for (key, value) in p.layout.fields
		key in target_keys && continue
		_modern_map_graph_contains_identity(
			value,
			identities,
			path,
		) && return true
	end
	for root in (p.data, p.frames, p.config, p.layout.subplots)
		_modern_map_graph_contains_identity(
			root,
			identities,
			path,
		) && return true
	end

	nested_identities = IdDict{Any,Nothing}()
	for nested in keys(staged_nested)
		nested_identities[nested] = nothing
		if nested isa _BuiltinPlotlyAttribute
			nested_identities[nested.fields] = nothing
		end
	end
	if !isempty(nested_identities)
		for key in target_keys
			root = get(p.layout.fields, key, nothing)
			storage = _modern_map_builtin_storage(root)
			storage === nothing && continue
			for (stored_key, value) in storage
				_modern_map_graph_contains_identity(
					stored_key,
					nested_identities,
					path,
				) && return true
				if Symbol(stored_key) in (:center, :bounds) &&
					haskey(nested_identities, value)
					_modern_map_root_contents_have_alias(
						value,
						nested_identities,
						path,
					) && return true
					continue
				end
				_modern_map_graph_contains_identity(
					value,
					nested_identities,
					path,
				) && return true
			end
		end
		for (key, value) in p.layout.fields
			key in target_keys && continue
			_modern_map_graph_contains_identity(
				value,
				nested_identities,
				path,
			) && return true
		end
		for root in (
			p.data,
			p.frames,
			p.config,
			p.layout.subplots,
		)
			_modern_map_graph_contains_identity(
				root,
				nested_identities,
				path,
			) && return true
		end
	end
	return false
end

function _apply_modern_map_update_for_transaction!(
	layout::Layout,
	with::PlotlyBase.PlotlyAttribute,
	kwargs;
	target_key::Union{Nothing,Symbol},
	protect_domain::Bool,
)
	if target_key === nothing
		update_maps!(layout, with; kwargs...)
		return layout
	end

	update = _combined_map_update(with, kwargs)
	current = get(layout.fields, target_key, attr())
	probe = Layout()
	probe.fields[:map] = current
	_require_valid_map_update(probe, update)
	effective_update =
		protect_domain ?
		_copy_map_update_without_domain(update) :
		update
	_merge_layout_attr!(
		layout,
		target_key,
		effective_update;
		deep_merge_keys = (:center, :bounds),
		mutate_builtin_target = true,
	)
	_require_valid_map_layouts(layout)
	return layout
end

function _prepare_modern_map_layout_transaction(
	sp::Union{Nothing,SyncPlot},
	p::Plot,
	with::PlotlyBase.PlotlyAttribute,
	kwargs;
	target_key::Union{Nothing,Symbol} = nothing,
	protect_domain::Bool = false,
	commit_callback::Function = _noop_plot_commit,
)
	staged_layout, memo, staged_roots, staged_nested =
		_stage_modern_map_layout_update(
		p.layout,
		with,
		kwargs;
		target_key = target_key,
		protect_domain = protect_domain,
	)
	layout_delta =
		_plotly_leaf_deltas(
			p.layout.fields,
			staged_layout.fields,
			memo,
		)
	if isempty(layout_delta)
		commit = () -> begin
			commit_callback(p)
			return p
		end
		return (
			script = nothing,
			operation = "relayout",
			commit = commit,
		)
	end
	# A layout-only relayout cannot update another renderer field that aliases
	# the same Julia map object. Detect arbitrary wrappers and custom trace
	# roots with a path-only walk: numeric arrays are skipped by element type,
	# and traversal allocates in proportion to graph depth rather than payload
	# size. Alias-connected models use the general topology-preserving react
	# transaction.
	if _modern_map_roots_have_external_alias(
		p,
		target_key,
		staged_roots,
		staged_nested,
	)
		mutation = current ->
			_apply_modern_map_update_for_transaction!(
				current.layout,
				with,
				kwargs;
				target_key = target_key,
				protect_domain = protect_domain,
			)
		return _prepare_full_model_mutation_transaction(
			sp,
			p,
			mutation,
			commit_callback,
			_LAYOUT_ONLY_MUTATION_SCOPE,
		)
	end
	script =
		sp === nothing ?
		nothing :
		_plotlyjs_relayout_script(sp, layout_delta)
	commit = () -> begin
		_commit_modern_map_layout!(
			p,
			staged_layout,
			staged_roots,
		)
		commit_callback(p)
		return p
	end
	return (
		script = script,
		operation = "relayout",
		commit = commit,
	)
end

function _transactional_modern_map_plot_update!(
	p::Plot,
	with::PlotlyBase.PlotlyAttribute,
	kwargs,
)
	prepare = (target, current) ->
		_prepare_modern_map_layout_transaction(
			target,
			current,
			with,
			kwargs,
		)
	local_mutation = () -> begin
		prepared = _prepare_modern_map_layout_transaction(
			nothing,
			p,
			with,
			kwargs,
		)
		prepared.commit()
		return p
	end
	return _transactional_plot_mutation!(
		p,
		prepare,
		local_mutation,
	)
end

function _modern_map_subplot_layout_key(
	p::Plot,
	row::Int,
	col::Int,
)
	target_ref = _subplot_target_ref(p, row, col)
	actual_kind = String(target_ref.subplot_kind)
	actual_kind == "map" || throw(ArgumentError(
		"Selected subplot cell ($(row), $(col)) is '$actual_kind', not 'map'.",
	))
	length(target_ref.layout_keys) == 1 || throw(ArgumentError(
		"Selected map subplot cell ($(row), $(col)) has invalid routing metadata.",
	))
	return only(target_ref.layout_keys)
end

function _transactional_modern_map_subplot_update!(
	sf::SubplotFigure,
	with::PlotlyBase.PlotlyAttribute = attr();
	row::Union{Nothing,Integer} = nothing,
	col::Union{Nothing,Integer} = nothing,
	kwargs...,
)
	metadata_lock = getfield(sf, :_lock)
	lock(metadata_lock)
	try
		r, c = _resolve_subplot_cell(sf; row = row, col = col)
		commit_selection = _ -> begin
			sf.current_row = r
			sf.current_col = c
			return nothing
		end
		prepare = function (target, current)
			key = _modern_map_subplot_layout_key(
				current,
				r,
				c,
			)
			return _prepare_modern_map_layout_transaction(
				target,
				current,
				with,
				kwargs;
				target_key = key,
				protect_domain = true,
				commit_callback = commit_selection,
			)
		end

		fig = getfield(sf, :fig)
		if fig isa SyncPlot
			_syncplot_transaction!(fig, prepare)
		else
			local_mutation = () -> begin
				key = _modern_map_subplot_layout_key(
					fig,
					r,
					c,
				)
				prepared =
					_prepare_modern_map_layout_transaction(
						nothing,
						fig,
						with,
						kwargs;
						target_key = key,
						protect_domain = true,
						commit_callback =
							commit_selection,
					)
				prepared.commit()
				return fig
			end
			_transactional_plot_mutation!(
				fig,
				prepare,
				local_mutation,
			)
		end
		return sf
	finally
		unlock(metadata_lock)
	end
end

function update_maps!(
	sp::SyncPlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	prepare = (target, current) ->
		_prepare_modern_map_layout_transaction(
			target,
			current,
			with,
			kwargs,
		)
	return _syncplot_transaction!(sp, prepare)
end

# ── Plot auto-refresh methods ───────────────────────────────────────
# Restrict these additions to the concrete vector-backed Plot shape emitted by
# PlotlySupply. They remain more specific than PlotlyBase's Plot methods, so
# loading this package adds dispatch without replacing methods owned upstream.
const _RefreshablePlot = Plot{TT, TL, TF} where {
	TT <: Vector{<:AbstractTrace},
	TL <: Layout,
	TF <: AbstractVector{<:PlotlyFrame},
}

function _clone_plot_model(p::Plot)
	data, layout, frames, config = deepcopy((
		p.data,
		p.layout,
		p.frames,
		p.config,
	))
	return Plot(
		data,
		layout,
		frames;
		config = config,
	)
end

function _clone_plot_model(p::Plot, stackdict::IdDict)
	cloned = if haskey(stackdict, p)
		stackdict[p]::typeof(p)
	else
		Base.deepcopy_internal(p, stackdict)::typeof(p)
	end
	cloned.divid = PlotlyBase.uuid4()
	return cloned
end

_clone_refreshable_plot(p::_RefreshablePlot) = _clone_plot_model(p)

Base.copy(p::_RefreshablePlot) = _clone_refreshable_plot(p)
PlotlyBase.fork(p::_RefreshablePlot) = _clone_refreshable_plot(p)

function PlotlyBase.redraw!(p::_RefreshablePlot)
	_maybe_sync_command!(p, :redraw)
	return p
end

function PlotlyBase.purge!(p::_RefreshablePlot)
	prepare = (target, current) ->
		_prepare_purge_transaction(target, current)
	local_mutation = () -> _do_purge!(p)
	return _transactional_plot_mutation!(
		p,
		prepare,
		local_mutation,
	)
end

function PlotlyBase.react!(
	p::_RefreshablePlot,
	data::AbstractVector{<:AbstractTrace},
	layout::Layout,
)
	prepare = function (target, current)
		staged_data, staged_layout =
			_prepare_react_values(current, data, layout)
		script = _plotlyjs_refresh_script(
			target,
			staged_data,
			staged_layout;
			model = current,
		)
		commit = () -> begin
			setfield!(current, :data, staged_data)
			setfield!(current, :layout, staged_layout)
			return current
		end
		return (script = script, operation = "react", commit = commit)
	end
	local_mutation = () -> _do_react!(p, data, layout)
	return _transactional_plot_mutation!(p, prepare, local_mutation)
end

function PlotlyBase.relayout!(p::_RefreshablePlot, args...; kwargs...)
	prepare = (target, current) ->
		_prepare_relayout_transaction(
			target,
			current,
			args,
			kwargs,
		)
	local_mutation = () -> _do_relayout!(p, args...; kwargs...)
	return _transactional_plot_mutation!(p, prepare, local_mutation)
end

function PlotlyBase.restyle!(
	p::_RefreshablePlot,
	ind::Int,
	update::AbstractDict = Dict();
	kwargs...,
)
	prepare = (target, current) ->
		_prepare_restyle_transaction(
			target,
			current,
			(ind,),
			update,
			kwargs;
			vectorized = false,
		)
	local_mutation = () -> _do_restyle!(p, ind, update; kwargs...)
	return _transactional_plot_mutation!(p, prepare, local_mutation)
end

function PlotlyBase.restyle!(
	p::_RefreshablePlot,
	inds::AbstractVector{Int},
	update::AbstractDict = Dict();
	kwargs...,
)
	prepare = (target, current) ->
		_prepare_restyle_transaction(
			target,
			current,
			inds,
			update,
			kwargs;
			vectorized = true,
		)
	local_mutation = () -> _do_restyle!(p, inds, update; kwargs...)
	return _transactional_plot_mutation!(p, prepare, local_mutation)
end

function PlotlyBase.restyle!(
	p::_RefreshablePlot,
	update::AbstractDict = Dict();
	kwargs...,
)
	prepare = (target, current) ->
		_prepare_restyle_transaction(
			target,
			current,
			1:length(current.data),
			update,
			kwargs;
			vectorized = true,
		)
	local_mutation = () -> _do_restyle!(p, update; kwargs...)
	return _transactional_plot_mutation!(p, prepare, local_mutation)
end

function PlotlyBase.addtraces!(p::_RefreshablePlot, traces::AbstractTrace...)
	return _transactional_structural_plot_mutation!(p) do current
		_do_addtraces!(current, traces...)
	end
end

function PlotlyBase.addtraces!(
	p::_RefreshablePlot,
	i::Int,
	traces::AbstractTrace...,
)
	return _transactional_structural_plot_mutation!(p) do current
		_do_addtraces!(current, i, traces...)
	end
end

function PlotlyBase.deletetraces!(p::_RefreshablePlot, inds::Int...)
	return _transactional_structural_plot_mutation!(p) do current
		_do_deletetraces!(current, inds...)
	end
end

function PlotlyBase.movetraces!(p::_RefreshablePlot, to_end::Int...)
	return _transactional_structural_plot_mutation!(p) do current
		_do_movetraces!(current, to_end...)
	end
end

function PlotlyBase.movetraces!(
	p::_RefreshablePlot,
	src::AbstractVector{Int},
	dest::AbstractVector{Int},
)
	return _transactional_structural_plot_mutation!(p) do current
		_do_movetraces!(current, src, dest)
	end
end

function PlotlyBase.extendtraces!(
	p::_RefreshablePlot,
	update::AbstractDict,
	indices::AbstractVector{Int} = [1],
	maxpoints = -1,
)
	stable_indices = collect(indices)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope =
			_trace_mutation_scope(stable_indices),
	) do current
		_do_extendtraces!(
			current,
			update,
			stable_indices,
			maxpoints,
		)
	end
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
	stable_indices = collect(indices)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope =
			_trace_mutation_scope(stable_indices),
	) do current
		_do_prependtraces!(
			current,
			update,
			stable_indices,
			maxpoints,
		)
	end
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
	layout = _CURRENT_PLOT_LAYOUT,
	kwargs...,
)
	prepare = function (target, current)
		resolved_layout = _resolve_update_layout(current, layout)
		return _prepare_update_transaction(
			target,
			current,
			ind,
			update,
			resolved_layout,
			kwargs,
		)
	end
	local_mutation = function ()
		resolved_layout = _resolve_update_layout(p, layout)
		return _do_update!(
			p,
			ind,
			update;
			layout = resolved_layout,
			kwargs...,
		)
	end
	return _transactional_plot_mutation!(p, prepare, local_mutation)
end

function PlotlyBase.update!(
	p::_RefreshablePlot,
	update = Dict();
	layout = _CURRENT_PLOT_LAYOUT,
	kwargs...,
)
	prepare = function (target, current)
		resolved_layout = _resolve_update_layout(current, layout)
		return _prepare_update_transaction(
			target,
			current,
			1:length(current.data),
			update,
			resolved_layout,
			kwargs,
		)
	end
	local_mutation = function ()
		resolved_layout = _resolve_update_layout(p, layout)
		return _do_update!(
			p,
			update;
			layout = resolved_layout,
			kwargs...,
		)
	end
	return _transactional_plot_mutation!(p, prepare, local_mutation)
end

function PlotlyBase.update_xaxes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_do_update_xaxes!(current, with; kwargs...)
	end
end

function PlotlyBase.update_yaxes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_do_update_yaxes!(current, with; kwargs...)
	end
end

function PlotlyBase.update_polars!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_do_update_polars!(current, with; kwargs...)
	end
end

function PlotlyBase.update_geos!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		PlotlyBase.update_geos!(current.layout, with; kwargs...)
	end
end

function PlotlyBase.update_mapboxes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		_update_mapboxes_preserving_aliases!(
			current.layout,
			with;
			kwargs...,
		)
	end
end

function update_maps!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_modern_map_plot_update!(
		p,
		with,
		kwargs,
	)
end

function PlotlyBase.update_scenes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		PlotlyBase.update_scenes!(current.layout, with; kwargs...)
	end
end

function PlotlyBase.update_ternaries!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
	) do current
		PlotlyBase.update_ternaries!(current.layout, with; kwargs...)
	end
end

function PlotlyBase.update_annotations!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
		preserve_layout_vector = :annotations,
	) do current
		PlotlyBase.update_annotations!(current.layout, with; kwargs...)
	end
end

function PlotlyBase.update_shapes!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
		preserve_layout_vector = :shapes,
	) do current
		PlotlyBase.update_shapes!(current.layout, with; kwargs...)
	end
end

function PlotlyBase.update_images!(
	p::_RefreshablePlot,
	with::PlotlyBase.PlotlyAttribute = attr();
	kwargs...,
)
	return _transactional_full_plot_mutation!(
		p;
		mutation_scope = _LAYOUT_ONLY_MUTATION_SCOPE,
		preserve_layout_vector = :images,
	) do current
		PlotlyBase.update_images!(current.layout, with; kwargs...)
	end
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
			if _PLOT_SYNCPLOT_MAP[plot] === sp
				delete!(_PLOT_SYNCPLOT_MAP, plot)
				_bump_plot_syncplot_version!(plot)
			end
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
	# Claim closure only after every earlier renderer transaction has finished.
	# Later transactions observe close_started and fail before touching either
	# renderer or model. Native close itself runs without render_lock because a
	# backend callback may re-enter close from another task.
	lock(resources.render_lock)
	render_lock_held = true
	close_state, close_done = try
		lock(resources.lock) do
			if resources.close_started
				state =
					resources.close_owner === caller ? :reentrant : :wait
				return (state, resources.close_done)
			end
			resources.close_started = true
			resources.close_owner = caller
			return (:owner, resources.close_done)
		end
	catch
		unlock(resources.render_lock)
		render_lock_held = false
		rethrow()
	end

	if close_state !== :owner
		unlock(resources.render_lock)
		render_lock_held = false
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
			unlock(resources.render_lock)
			render_lock_held = false
			if _syncplot_raw_window_state(sp) !== :closed
				ec = _syncplot_backend(sp)
				window = getfield(sp, :window)
				Base.invokelatest(() -> ec.close(window))
			end
		catch
			if render_lock_held
				unlock(resources.render_lock)
				render_lock_held = false
			end
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
			if render_lock_held
				unlock(resources.render_lock)
				render_lock_held = false
			end
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
	_require_syncplot_model(p)
	_require_syncplot_model(getfield(sp, :plot))
	resources = getfield(sp, :_resources)
	lock(resources.render_lock)
	try
		lock(resources.lock)
		try
			resources.close_started && return (nothing, false)
			return lock(_SYNCPLOT_REGISTRY_LOCK) do
				reservation =
					get(_PLOT_SYNCPLOT_RESERVATIONS, p, nothing)
				if reservation !== nothing &&
						reservation.kind in (:candidate, :local)
					throw(InvalidStateException(
						"Plot is reserved by an active mutation",
						:busy,
					))
				end
				old = get(_PLOT_SYNCPLOT_MAP, p, nothing)
				_PLOT_SYNCPLOT_MAP[p] = sp
				old === sp || _bump_plot_syncplot_version!(p)
				push!(_DISPLAYED_PLOTS, sp)
				(old, true)
			end
		finally
			unlock(resources.lock)
		end
	finally
		unlock(resources.render_lock)
	end
end

function Base.display(d::ElectronDisplay, p::Plot)
	sp = to_syncplot(p)
	old, registered = try
		_register_displayed_syncplot!(p, sp)
	catch
		try
			close(sp)
		catch cleanup_error
			@warn "Failed to close an unregistered SyncPlot." exception = (
				cleanup_error,
				catch_backtrace(),
			)
		end
		rethrow()
	end
	if !registered
		close(sp)
		return nothing
	end

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
	plotlyjs_uri = _plotlyjs_asset_uri()
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
  <script src="$plotlyjs_uri" charset="utf-8"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.9/MathJax.js?config=TeX-AMS-MML_SVG"></script>
</body>
</html>
"""
end

function _export_timeout_seconds(timeout_s::Real, operation::AbstractString)
	return _validated_timeout_seconds(timeout_s, operation)
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
