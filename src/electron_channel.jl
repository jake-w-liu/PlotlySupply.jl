# ── Starting Electron and pairing requests with replies ─────────────
#
# ElectronCall pairs a reply with its request by position on an application's
# single connection (write one line, read the next line) and carries no
# request id. A request abandoned after its line was written (Ctrl-C while
# plotly.js draws a large export, an interrupted `redraw!`) leaves its reply in
# the pipe, and every later request then read the reply of the one before it:
# an export wrote the previous figure, `to_image` returned "ok". Renderer
# scripts are asynchronous and can finish out of order, so skipping "one line"
# after an interrupt would not be enough either.
#
# PlotlySupply's own scripts therefore go through `_ec_run`: the script's value
# (or error) comes back tagged with a request id, the request line is written
# with Ctrl-C deferred (the connection never holds half a request), and the
# reply loop skips replies that are not its own. ElectronCall's main.js answers
# every line it reads with exactly one line, so the number of replies that
# abandoned requests still owe is counted per application; an untagged line
# read while none is owed is the request's own reply (a script that failed
# before its tagging wrapper ran). ElectronCall's own commands (`Window`,
# `load`, `close`), which read one line themselves, run through `_ec_native`
# once the owed replies have arrived, with Ctrl-C deferred. A connection that
# cannot be resynchronised (owed replies that never arrive) is given up: its
# application is shut down (`_ec_poison!`) and a new one is started on demand.

# Serializes the start of the shared default application: ElectronCall's
# `default_application` checks and creates without a lock, so concurrent first
# uses (savefig and to_syncplot in several tasks) each started an Electron
# process, and all but one stayed unused until exit.
const _DEFAULT_ELECTRON_APP_LOCK = ReentrantLock()

# Bound (seconds) on starting Electron for a live window: generous, because a
# first launch (macOS checks a new binary) or a loaded machine takes many
# seconds; an export uses its own `timeout` instead.
const _ELECTRON_START_TIMEOUT_S = 120.0

"""
	_default_electron_app(ec; timeout_s = _ELECTRON_START_TIMEOUT_S, who = "PlotlySupply")

PlotlySupply's shared Electron application (ElectronCall's default
application), started at most once even under concurrent first use. A start
that does not finish within `timeout_s` seconds (Electron cannot start: no
display, a broken install) is an error naming `who`, not a hang. An
application whose connection was given up (`_ec_poisoned`) is not returned.
"""
function _default_electron_app(
	ec;
	timeout_s::Real = _ELECTRON_START_TIMEOUT_S,
	who::AbstractString = "PlotlySupply",
)
	start = if _is_sandboxed_env() && isdefined(ec, :development_config)
		() -> begin
			security = Base.invokelatest(() -> ec.development_config())
			Base.invokelatest(() -> ec.default_application(security))
		end
	else
		() -> Base.invokelatest(() -> ec.default_application())
	end
	lock(_DEFAULT_ELECTRON_APP_LOCK) do
		app = _bounded_electron_start(start, timeout_s, who)
		if _ec_poisoned(app)
			# A given-up application is being shut down; ElectronCall hands
			# out a new default once the old one no longer `exists`.
			hasproperty(app, :exists) && (app.exists = false)
			app = _bounded_electron_start(start, timeout_s, who)
		end
		_record_owned_electron_app!(app)
		return app
	end
end

# Run `start()`, which starts (or returns) an Electron application, with a
# bound: ElectronCall's `Application()` waits in `accept` for the new Electron
# process to connect, forever if the process exited at once (no display) or
# hangs. On timeout the waiting task is interrupted (ElectronCall then closes
# its pipe servers) and an error is raised, so the caller's locks are released
# and Julia stays able to exit.
function _bounded_electron_start(start, timeout_s::Real, who::AbstractString)
	timeout = Float64(timeout_s)
	(isfinite(timeout) && timeout > 0) || throw(ArgumentError(
		"$(who): the Electron start timeout must be a positive finite number of " *
		"seconds; got $(timeout_s).",
	))
	task = @async start()
	if timedwait(() -> istaskdone(task), timeout; pollint = 0.05) !== :ok
		istaskdone(task) || schedule(task, InterruptException(); error = true)
		timedwait(() -> istaskdone(task), 5.0; pollint = 0.05)
		error(
			"$(who): the Electron renderer did not start within $(timeout) s. Electron " *
			"needs a display (on a headless Linux machine run Julia under `xvfb-run`) " *
			"and a working Electron_jll installation.",
		)
	end
	try
		return fetch(task)
	catch err
		err isa TaskFailedException || rethrow()
		throw(err.task.exception)
	end
end

mutable struct _ECChannelState
	owed::Int        # replies abandoned requests still owe
	poisoned::Bool   # the connection was given up
end

const _EC_CHANNELS = WeakKeyDict{Any, _ECChannelState}()
const _EC_CHANNELS_LOCK = ReentrantLock()
const _EC_REQUEST_COUNTER = Threads.Atomic{UInt64}(0)
const _EC_REPLY_TAG = "__plotlysupply_reply"
# Bound (seconds) on waiting for the replies abandoned requests still owe
# before an ElectronCall command may use the connection. An abandoned export
# script settles within its own `timeout` (300 s by default), a live-window
# script within seconds.
const _EC_SETTLE_TIMEOUT_S = Ref(330.0)

# Whether `ec` is the real ElectronCall module; test doubles keep their own `run`.
_ec_is_real(ec) = ec isa Module && nameof(ec) === :ElectronCall

# The application of an ElectronCall window (`nothing` for other objects).
_ec_window_app(window) = hasproperty(window, :app) ? getproperty(window, :app) : nothing

function _ec_state(app)
	return lock(_EC_CHANNELS_LOCK) do
		get!(() -> _ECChannelState(0, false), _EC_CHANNELS, app)
	end
end

# The number of replies abandoned requests on `app` still owe.
function _ec_owed(app)
	app === nothing && return 0
	return lock(_EC_CHANNELS_LOCK) do
		state = get(_EC_CHANNELS, app, nothing)
		state === nothing ? 0 : state.owed
	end
end

function _ec_poisoned(app)
	app === nothing && return false
	return lock(_EC_CHANNELS_LOCK) do
		state = get(_EC_CHANNELS, app, nothing)
		state !== nothing && state.poisoned
	end
end

# Give up the connection of `app`: its replies can no longer be matched to
# requests, so an application PlotlySupply started is shut down with every
# window on it (a new one is started on demand); one the caller passed in is
# only marked, and requests to it fail.
function _ec_poison!(app, reason::AbstractString)
	state = _ec_state(app)
	state.poisoned && return nothing
	state.poisoned = true
	owned = lock(_OWNED_ELECTRON_APPS_LOCK) do
		any(a -> a === app, _OWNED_ELECTRON_APPS)
	end
	@warn "PlotlySupply: $(reason); the Electron connection can no longer pair " *
		"requests with replies, so " * (owned ?
		"its application and windows are closed. Display the figures again to reopen them." :
		"requests to it now fail.")
	if owned
		# Requests on this connection cannot be answered reliably, so it is not
		# closed by request: closing the pipe makes Electron's main process
		# quit, and `_shutdown_electron_app!` (which skips `close` for an
		# application that no longer `exists`) waits for that, then signals it.
		hasproperty(app, :exists) && (app.exists = false)
		try
			close(app.connection)
		catch err
			err isa Base.IOError || @warn "PlotlySupply: closing an unusable Electron connection failed." exception = err
		end
		@async try
			_shutdown_electron_app!(app)
		catch err
			@warn "PlotlySupply: shutting down an unusable Electron application failed." exception = err
		end
	end
	return nothing
end

_ec_poisoned_error(who::AbstractString) = ErrorException(
	"$(who): the Electron connection was given up after an interrupted request (its " *
	"replies could no longer be matched to requests); open the figure in a new window.",
)

# `code` (one JavaScript expression, optionally followed by `;`) wrapped so its
# value or error comes back tagged with `id`. Renderer scripts may return
# promises; main-process scripts are evaluated synchronously by main.js.
function _ec_wrapped_script(code::AbstractString, id::String, window::Bool)
	expression = rstrip(c -> isspace(c) || c == ';', code)
	tag = _json_js(id)
	failure = "function (e) { return {$(_EC_REPLY_TAG): $(tag), error: {message: " *
		"String((e && e.message) || e), stack: (e && e.stack) || null}}; }"
	success = "function (v) { return {$(_EC_REPLY_TAG): $(tag), value: v === undefined ? null : v}; }"
	if window
		return "(function () { var p; try { p = Promise.resolve((\n$(expression)\n)); } " *
			"catch (e) { p = Promise.reject(e); } return p.then($(success), $(failure)); })()"
	end
	return "(function () { try { return ($(success))((\n$(expression)\n)); } " *
		"catch (e) { return ($(failure))(e); } })()"
end

# The tag of a parsed reply, or `nothing` for an untagged one.
function _ec_reply_tag(reply)
	reply isa AbstractDict || return nothing
	data = get(reply, "data", nothing)
	data isa AbstractDict || return nothing
	tag = get(data, _EC_REPLY_TAG, nothing)
	return tag isa AbstractString ? String(tag) : nothing
end

function _ec_js_error(ec, info, context::String)
	message = info isa AbstractDict ? string(get(info, "message", "Unknown JavaScript error")) : string(info)
	stack = info isa AbstractDict ? get(info, "stack", nothing) : nothing
	return Base.invokelatest(() -> ec.JSExecutionError(
		message;
		stack = stack isa AbstractString ? String(stack) : nothing,
		context = context,
	))
end

# The value of a reply as ElectronCall's `run` returns it, or its error.
function _ec_decode_reply(ec, reply, window::Bool)
	reply isa AbstractDict || error("PlotlySupply: unexpected reply from Electron: $(repr(reply))")
	context = window ? "renderer" : "main"
	data = get(reply, "data", nothing)
	if data isa AbstractDict && haskey(data, _EC_REPLY_TAG)
		haskey(data, "error") && throw(_ec_js_error(ec, data["error"], context))
		return get(data, "value", nothing)
	end
	# An untagged reply: what ElectronCall's `run` makes of it.
	if window
		status = get(reply, "status", nothing)
		status == "success" && return data
		status == "error" && throw(_ec_js_error(ec, get(reply, "error", nothing), context))
		error("PlotlySupply: invalid response format from Electron: $(repr(reply))")
	end
	haskey(reply, "error") && throw(_ec_js_error(ec, reply["error"], context))
	return data
end

# Read and parse one reply line of `app`; the caller holds its `comm_lock`.
function _ec_read_reply(ec, app)
	line = try
		readline(app.connection)
	catch err
		err isa Base.IOError || rethrow()
		app.exists = false
		throw(Base.invokelatest(() -> ec.CommunicationError("Lost connection to Electron process", err)))
	end
	if isempty(line)
		app.exists = false
		throw(Base.invokelatest(() -> ec.CommunicationError("Empty response from Electron process")))
	end
	return Base.invokelatest(ec.JSON.parse, line)
end

"""
	_ec_run(ec, target, code::AbstractString) -> Any

Run the JavaScript expression `code` in `target` (an ElectronCall `Window`: in
its renderer; an `Application`: in Electron's main process) and return its
value; an error in the script raises `ElectronCall.JSExecutionError`. With the
real ElectronCall backend the reply is matched by a request id (see the top of
electron_channel.jl), so a request abandoned by an interrupt cannot hand its
reply to a later one. Other backends (test doubles) use their own `run`.
"""
function _ec_run(ec, target, code::AbstractString)
	_ec_is_real(ec) || return Base.invokelatest(() -> ec.run(target, code))
	window = Base.invokelatest(() -> target isa ec.Window)
	app = window ? target.app : target
	window && !target.exists &&
		throw(Base.invokelatest(() -> ec.WindowClosedError(target.id, "run")))
	app.exists || throw(Base.invokelatest(() -> ec.ApplicationError(
		"Cannot execute JavaScript in closed application",
	)))
	id = "ps" * string(Threads.atomic_add!(_EC_REQUEST_COUNTER, UInt64(1)) + 1)
	escaped = Base.invokelatest(ec.escape_json_string, String(_ec_wrapped_script(code, id, window)))
	command = window ?
		string("{\"cmd\":\"runcode\",\"target\":\"window\",\"winid\":", target.id,
			",\"code\":\"", escaped, "\"}") :
		string("{\"cmd\":\"runcode\",\"target\":\"app\",\"code\":\"", escaped, "\"}")
	state = _ec_state(app)
	return lock(app.comm_lock) do
		state.poisoned && throw(_ec_poisoned_error("PlotlySupply"))
		# Ctrl-C is deferred while the line is written (the connection never
		# holds half a request) and delivered while the reply is awaited.
		disable_sigint() do
			try
				write(app.connection, command, '\n')
				flush(app.connection)
			catch err
				err isa Base.IOError || rethrow()
				app.exists = false
				throw(Base.invokelatest(() -> ec.CommunicationError("Lost connection to Electron process", err)))
			end
		end
		answered = false
		try
			while true
				reply = _ec_read_reply(ec, app)
				tag = _ec_reply_tag(reply)
				if tag == id || (tag === nothing && state.owed == 0)
					answered = true
					return _ec_decode_reply(ec, reply, window)
				end
				# A reply an abandoned request owed.
				state.owed = max(state.owed - 1, 0)
			end
		finally
			# Interrupted (or failed) before the reply arrived: it is still owed.
			answered || (state.owed += 1)
		end
	end
end

"""
	_ec_native(f, ec, app; who = "PlotlySupply")

Run `f()`, which issues one ElectronCall command on `app` that reads its own
reply (`Window`, `load`, `close`), once every reply that abandoned requests owe
has arrived, with Ctrl-C deferred so the command cannot be abandoned half-way.
If the owed replies do not arrive within `_EC_SETTLE_TIMEOUT_S[]` seconds the
connection is given up (`_ec_poison!`) and an error is raised. Other backends
run `f()` directly.
"""
function _ec_native(f, ec, app; who::AbstractString = "PlotlySupply")
	(_ec_is_real(ec) && app !== nothing && hasproperty(app, :comm_lock)) || return f()
	state = _ec_state(app)
	return lock(app.comm_lock) do
		state.poisoned && throw(_ec_poisoned_error(who))
		if state.owed > 0
			reader = @async while state.owed > 0
				_ec_read_reply(ec, app)
				state.owed -= 1
			end
			settled = try
				timedwait(() -> istaskdone(reader), _EC_SETTLE_TIMEOUT_S[]; pollint = 0.05) === :ok
			catch
				# Interrupted while waiting: the reader must not go on reading
				# once the lock is released.
				istaskdone(reader) || schedule(reader, InterruptException(); error = true)
				rethrow()
			end
			if !settled
				istaskdone(reader) || schedule(reader, InterruptException(); error = true)
				_ec_poison!(app, "the replies of interrupted requests did not arrive")
				throw(_ec_poisoned_error(who))
			end
			try
				fetch(reader)
			catch
				_ec_poison!(app, "reading the replies of interrupted requests failed")
				throw(_ec_poisoned_error(who))
			end
		end
		return disable_sigint(f)
	end
end
