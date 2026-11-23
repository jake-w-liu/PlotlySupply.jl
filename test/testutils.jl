# Shared fixtures for the PlotlySupply test files: fake Electron backends and
# lifecycle/subplot helpers. `runtests.jl` includes this file once; a test file
# that needs them starts with
#     isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")
# so that it also runs on its own: `julia --project=. test/<file>.jl`.

using Test
using PlotlySupply

const _PLOTLYSUPPLY_TESTUTILS = true

# Test files that runtests.jl runs first, in this order (the core testsets that
# runtests.jl once held inline, the static suite checks, then the pre-2.0
# suites in the order they were added).
const _TEST_FILES_RUN_FIRST = (
    "core_suite.jl",
    "hygiene.jl",
    "nested_series.jl",
    "three_d_styling.jl",
    "extended_mutator_parity.jl",
    "layout_merge_preservation.jl",
    "lazy_payloads.jl",
    "export_transactions.jl",
    "mutator_parity.jl",
    "renderer_transactions.jl",
    "modern_maps.jl",
)

# Scripts that must start with a renderer nobody has used yet, so they cannot
# be included into the suite's process: each runs in a fresh Julia process,
# started by mathjax_standalone.jl (`julia --project=. test/<file>.jl ARGS`
# runs one by hand; the usage line is at the top of each).
const _TEST_FILES_STANDALONE = (
    "mathjax_rendering.jl",
    "mathjax_svg_serialization.jl",
)

# Every test file in `testdir`, in the order runtests.jl runs them: the files of
# `_TEST_FILES_RUN_FIRST`, then every other `*.jl` file except the runner, this
# file and the standalone scripts in name order, so a new test file runs
# without being registered. A listed file that no longer exists is skipped
# here, so the rest of the suite still runs, and reported by hygiene.jl.
function _test_files_in_run_order(testdir::AbstractString)
    skipped = ("runtests.jl", "testutils.jl", _TEST_FILES_STANDALONE...)
    available = sort!(filter(
        name -> endswith(name, ".jl") && !(name in skipped) &&
            isfile(joinpath(testdir, name)),
        readdir(testdir),
    ))
    return vcat(
        filter(in(available), collect(_TEST_FILES_RUN_FIRST)),
        filter(!in(_TEST_FILES_RUN_FIRST), available),
    )
end

# The package-wide defaults a test file must leave as it found them: the active
# style, the default template, the default legend position and the mathtext
# settings. (Styles a file registers by name are not defaults: the docs
# examples register `:talk` and `:paper`, and nothing reads those back.) A file that changes one and
# does not restore it changes what every later file of the full run measures
# (a style or margin leaking from an earlier file), so runtests.jl compares
# this snapshot at the end of every file and restores it.
_global_defaults_snapshot() = (
    style = deepcopy(PlotlySupply._ACTIVE_STYLE[]),
    style_ref = PlotlySupply._ACTIVE_STYLE[],
    template = PlotlySupply._DEFAULT_TEMPLATE[],
    legend_position = PlotlySupply._DEFAULT_LEGEND_POSITION[],
    mathtext = PlotlySupply._MATHTEXT_SETTINGS[],
)

# Field-by-field equality of two values (mutable structs compare by identity
# with `==`, and a PlotStyle holds vectors and tuples).
function _same_value(a, b)
    a === b && return true
    typeof(a) === typeof(b) || return false
    if a isa AbstractArray || a isa AbstractDict || a isa Tuple || a isa NamedTuple
        return isequal(a, b)
    end
    if isstructtype(typeof(a)) && fieldcount(typeof(a)) > 0
        return all(i -> _same_value(getfield(a, i), getfield(b, i)), 1:fieldcount(typeof(a)))
    end
    return isequal(a, b)
end

# Names of the defaults that differ between two snapshots (empty when equal).
function _global_defaults_diff(before, after)
    changed = Symbol[]
    _same_value(before.style, after.style) || push!(changed, :style)
    _same_value(before.template, after.template) || push!(changed, :template)
    before.legend_position == after.legend_position || push!(changed, :legend_position)
    _same_value(before.mathtext, after.mathtext) || push!(changed, :mathtext)
    return changed
end

function _global_defaults_restore!(snapshot)
    # The saved reference unless that object was changed in place.
    PlotlySupply._ACTIVE_STYLE[] = _same_value(snapshot.style_ref, snapshot.style) ?
        snapshot.style_ref : deepcopy(snapshot.style)
    PlotlySupply._DEFAULT_TEMPLATE[] = snapshot.template
    PlotlySupply._DEFAULT_LEGEND_POSITION[] = snapshot.legend_position
    PlotlySupply._MATHTEXT_SETTINGS[] = snapshot.mathtext
    return nothing
end

# The user-extensible registries: `COLORMAPS`, `COLOR_CYCLES` and the styles
# `register_style!` adds. A file may extend them (the docs examples register
# `COLORMAPS["ice"]`, `:talk` and `:paper`), but what it adds must not reach
# later files, whose registry checks would otherwise depend on the run order.
# runtests.jl therefore restores them after every file.
_global_registries_snapshot() = (
    # The registered objects themselves (restored as they were, so identity
    # checks against them still hold) and value copies (to see in-place edits).
    refs = (copy(PlotlySupply.COLORMAPS), copy(PlotlySupply.COLOR_CYCLES), copy(PlotlySupply._STYLE_REGISTRY)),
    colormaps = Dict(k => copy(v) for (k, v) in PlotlySupply.COLORMAPS),
    color_cycles = Dict(k => copy(v) for (k, v) in PlotlySupply.COLOR_CYCLES),
    styles = Dict(k => deepcopy(v) for (k, v) in PlotlySupply._STYLE_REGISTRY),
)

# Names of the registries that differ between two snapshots.
function _global_registries_diff(before, after)
    changed = Symbol[]
    isequal(before.colormaps, after.colormaps) || push!(changed, :colormaps)
    isequal(before.color_cycles, after.color_cycles) || push!(changed, :color_cycles)
    (keys(before.styles) == keys(after.styles) &&
     all(k -> _same_value(before.styles[k], after.styles[k]), keys(before.styles))) ||
        push!(changed, :styles)
    return changed
end

function _global_registries_restore!(snapshot)
    registries = (PlotlySupply.COLORMAPS, PlotlySupply.COLOR_CYCLES, PlotlySupply._STYLE_REGISTRY)
    values = (snapshot.colormaps, snapshot.color_cycles, snapshot.styles)
    for (registry, refs, saved) in zip(registries, snapshot.refs, values)
        empty!(registry)
        for (k, v) in refs
            registry[k] = v
            # An entry changed in place gets its saved value back.
            _same_value(v, saved[k]) || (registry[k] = deepcopy(saved[k]))
        end
    end
    return nothing
end

# Run on its own (`julia --project=. test/<file>.jl`) a file that includes this
# one is checked when the process ends: the defaults it started with must be
# the defaults it leaves. (Under runtests.jl every file is checked as it ends.)
if !isdefined(@__MODULE__, :_GLOBAL_DEFAULTS_AT_START)
    const _GLOBAL_DEFAULTS_AT_START = _global_defaults_snapshot()
    atexit() do
        leaked = _global_defaults_diff(_GLOBAL_DEFAULTS_AT_START, _global_defaults_snapshot())
        if !isempty(leaked)
            println(stderr, "ERROR: the test run changed package defaults and did not restore them: ", leaked)
            exit(1)
        end
    end
end

struct _UnsupportedTrace <: AbstractTrace end

mutable struct _LifecycleFakeWindow
    exists::Bool
    msg_channel::Channel{Any}
    uri::String
    width::Int
    height::Int
    title::String
    show::Bool
    close_calls::Int
    throw_on_close::Bool
    throw_on_isopen::Bool
    on_close::Any
    close_entered::Union{Nothing,Channel{Nothing}}
    close_release::Union{Nothing,Channel{Nothing}}
end

mutable struct _LifecycleFakeElectron
    windows::Vector{_LifecycleFakeWindow}
    scripts::Vector{String}
    fail_window::Bool
    throw_on_close::Bool
    throw_on_isopen::Bool
    block_close::Bool
    run_result::Any
    run_error::Union{Nothing,Exception}
end

_LifecycleFakeElectron(;
    fail_window::Bool=false,
    throw_on_close::Bool=false,
    throw_on_isopen::Bool=false,
    block_close::Bool=false,
    run_result="ok",
    run_error::Union{Nothing,Exception}=nothing,
) = _LifecycleFakeElectron(
    _LifecycleFakeWindow[],
    String[],
    fail_window,
    throw_on_close,
    throw_on_isopen,
    block_close,
    run_result,
    run_error,
)

function _lifecycle_fake_window(
    ec::_LifecycleFakeElectron,
    app,
    uri;
    width,
    height,
    title,
    show,
)
    ec.fail_window && error("injected Window construction failure")
    window = _LifecycleFakeWindow(
        true,
        Channel{Any}(1),
        String(uri),
        width,
        height,
        String(title),
        show,
        0,
        ec.throw_on_close,
        ec.throw_on_isopen,
        nothing,
        ec.block_close ? Channel{Nothing}(1) : nothing,
        ec.block_close ? Channel{Nothing}(1) : nothing,
    )
    push!(ec.windows, window)
    return window
end

function _lifecycle_fake_isopen(window::_LifecycleFakeWindow)
    window.throw_on_isopen && error("injected window isopen failure")
    return window.exists
end

function _lifecycle_fake_close(window::_LifecycleFakeWindow)
    window.close_calls += 1
    if window.close_entered !== nothing
        put!(window.close_entered, nothing)
        take!(window.close_release)
    end
    window.on_close === nothing || window.on_close()
    window.throw_on_close && error("injected window close failure")
    window.exists = false
    isopen(window.msg_channel) && close(window.msg_channel)
    return nothing
end

function Base.getproperty(ec::_LifecycleFakeElectron, name::Symbol)
    if name === :Window
        return (args...; kwargs...) ->
            _lifecycle_fake_window(ec, args...; kwargs...)
    elseif name === :isopen
        return _lifecycle_fake_isopen
    elseif name === :close
        return _lifecycle_fake_close
    elseif name === :msgchannel
        return window -> window.msg_channel
    elseif name === :run
        return function (window, script)
            push!(ec.scripts, String(script))
            ec.run_error === nothing || throw(ec.run_error)
            return ec.run_result
        end
    end
    return getfield(ec, name)
end

mutable struct _ImageCommandState
    open::Bool
    calls::Vector{Tuple{Any,String}}
    results::Vector{Any}
    run_error::Union{Nothing,Exception}
end

_ImageCommandState() =
    _ImageCommandState(true, Tuple{Any,String}[], Any[], nothing)

function _image_command_backend(state::_ImageCommandState)
    return (
        isopen=window -> state.open,
        close=window -> (state.open = false; nothing),
        run=function (window, script)
            push!(state.calls, (window, String(script)))
            state.run_error === nothing || throw(state.run_error)
            isempty(state.results) &&
                error("image command fake has no queued result")
            return popfirst!(state.results)
        end,
    )
end

function _wait_for_lifecycle(predicate; timeout::Float64=60.0, collect::Bool=false)
    deadline = time() + timeout
    while time() < deadline
        predicate() && return true
        collect && GC.gc(true)
        sleep(0.01)
    end
    collect && GC.gc(true)
    return predicate()
end

function _lifecycle_registry_counts()
    return lock(PlotlySupply._SYNCPLOT_REGISTRY_LOCK) do
        length(PlotlySupply._PLOT_SYNCPLOT_MAP)
    end
end

function _lifecycle_is_registered(plot, sp)
    return lock(PlotlySupply._SYNCPLOT_REGISTRY_LOCK) do
        get(PlotlySupply._PLOT_SYNCPLOT_MAP, plot, nothing) === sp
    end
end

function _native_close_lifecycle_fixture(ec::_LifecycleFakeElectron)
    payload = ones(Float64, 250_000)
    plot = Plot(scatter(y=payload))
    sp = PlotlySupply._create_syncplot_window(ec, plot; app=:fake, show=false)
    old, registered = PlotlySupply._register_displayed_syncplot!(plot, sp)
    tempdir = getfield(sp, :_resources).tempdir
    window = sp.window
    retained_size = Base.summarysize(sp)
    refs = (WeakRef(payload), WeakRef(plot), WeakRef(sp))

    # This is the notification ElectronCall applies on a native/UI close:
    # exists becomes false and the per-window message channel closes.
    window.exists = false
    close(window.msg_channel)
    return (; refs, tempdir, window, retained_size, old, registered)
end

function _open_watcher_lifecycle_fixture(ec::_LifecycleFakeElectron)
    payload = ones(Float64, 250_000)
    plot = Plot(scatter(y=payload))
    sp = PlotlySupply._create_syncplot_window(ec, plot; app=:fake, show=false)
    tempdir = getfield(sp, :_resources).tempdir
    window = sp.window
    retained_size = Base.summarysize(sp)
    refs = (WeakRef(payload), WeakRef(plot), WeakRef(sp))
    initially_open = isopen(sp)
    initial_close_calls = window.close_calls
    return (;
        refs,
        tempdir,
        window,
        retained_size,
        initially_open,
        initial_close_calls,
    )
end

const _subplot_refresh_calls = Ref(0)

function _subplot_counting_backend()
    open = Ref(true)
    return (
        isopen=window -> open[],
        close=window -> (open[] = false; nothing),
        run=(window, script) -> begin
            _subplot_refresh_calls[] += 1
            return "ok"
        end,
    )
end

function _subplot_counting_syncplot(p::Plot, divid::String)
    resources = PlotlySupply._SyncPlotResources(
        nothing,
        _subplot_counting_backend(),
    )
    return SyncPlot(p, nothing, nothing, divid, resources)
end

# ---------------------------------------------------------------------------
# Value assertions shared by the constructor/mutator testsets.
# ---------------------------------------------------------------------------

# Nested field of a layout, trace or attribute, e.g.
# `_lookup(fig.layout, :scene, :xaxis, :range)`. A missing level throws a
# KeyError, so a value that was never written fails the calling test.
function _lookup(obj, keys::Symbol...)
    for k in keys
        d = obj isa Union{PlotlyBase.Layout, PlotlyBase.GenericTrace} ? obj.fields : obj
        d isa PlotlyBase.PlotlyAttribute && (d = d.fields)
        d isa AbstractDict || throw(ArgumentError("_lookup: cannot index $(typeof(d)) with :$k"))
        obj = haskey(d, k) ? d[k] : haskey(d, String(k)) ? d[String(k)] : throw(KeyError(k))
    end
    return obj
end

# The figure-level options a Cartesian (or any 2-D/3-D) constructor wrote. Only
# the options passed are checked; ranges are linear-axis values here.
function _test_cartesian_options(fig; title=nothing, xlabel=nothing, ylabel=nothing,
        xrange=nothing, yrange=nothing, width=nothing, height=nothing,
        fontsize=nothing, showgrid=nothing)
    L = fig.layout
    title === nothing || @test _lookup(L, :title, :text) == title
    xlabel === nothing || @test _lookup(L, :xaxis, :title, :text) == xlabel
    ylabel === nothing || @test _lookup(L, :yaxis, :title, :text) == ylabel
    for (axis, range) in ((:xaxis, xrange), (:yaxis, yrange))
        range === nothing && continue
        @test _lookup(L, axis, :range) == range
        @test _lookup(L, axis, :autorange) == false
    end
    width === nothing || @test _lookup(L, :width) == width
    height === nothing || @test _lookup(L, :height) == height
    fontsize === nothing || @test _lookup(L, :font, :size) == fontsize
    if showgrid !== nothing
        @test _lookup(L, :xaxis, :showgrid) == showgrid
        @test _lookup(L, :yaxis, :showgrid) == showgrid
    end
    return nothing
end

# The scene options a 3-D constructor wrote (titles, ranges, grid, visibility,
# aspect mode). Only the options passed are checked.
function _test_scene_options(fig; scene=:scene, xlabel=nothing, ylabel=nothing,
        zlabel=nothing, xrange=nothing, yrange=nothing, zrange=nothing,
        aspectmode=nothing, showgrid=nothing, visible=nothing)
    sc = _lookup(fig.layout, scene)
    for (axis, label, range) in ((:xaxis, xlabel, xrange), (:yaxis, ylabel, yrange), (:zaxis, zlabel, zrange))
        label === nothing || @test _lookup(sc, axis, :title, :text) == label
        range === nothing || @test _lookup(sc, axis, :range) == range
        showgrid === nothing || @test _lookup(sc, axis, :showgrid) == showgrid
        visible === nothing || @test _lookup(sc, axis, :visible) == visible
    end
    aspectmode === nothing || @test _lookup(sc, :aspectmode) == aspectmode
    return nothing
end

# A heatmap/contour trace draws `U[ix, iy]` at `(x[ix], y[iy])`: plotly gets
# the transpose of `U` (rows along y) with `transpose = true`.
function _test_field_trace(tr, type, x, y, U)
    @test tr[:type] == type
    @test tr[:x] == x && tr[:y] == y
    @test tr[:transpose] === true
    @test Matrix(tr[:z]) == permutedims(U)
    return nothing
end

# Axis type ("log", "linear", ...) or "-" when PlotlySupply wrote none.
_axis_type(fig, axis::Symbol=:xaxis) = string(get(PlotlySupply._symbol_dict(get(fig.layout.fields, axis, nothing)), :type, "-"))

# plot_stem draws one marker trace (the heads) and one gap-separated line
# trace (the stems) per series; return them as (heads, stems).
function _stem_parts(fig)
    heads = [t for t in fig.data if t[:mode] == "markers"]
    stems = [t for t in fig.data if t[:mode] == "lines"]
    @test length(heads) == length(stems) == length(fig.data) ÷ 2
    return heads, stems
end

# (tail, tip) of every arrow shaft of a plot_quiver trace: the 2-point
# segments between gap (`nothing`) separators; arrowheads are 3-point segments.
function _quiver_shafts(tr)
    xs, ys = tr[:x], tr[:y]
    shafts = Tuple{Tuple{Float64,Float64},Tuple{Float64,Float64}}[]
    start = 1
    for i in 1:(length(xs) + 1)
        if i > length(xs) || xs[i] === nothing
            if i - start == 2
                push!(shafts, ((xs[start], ys[start]), (xs[start + 1], ys[start + 1])))
            end
            start = i + 1
        end
    end
    return shafts
end

# xscale/yscale: the axes asked to be logarithmic are `type = "log"` with
# power-of-ten tick labels; the others are not logarithmic.
function _test_log_axes(fig; x::Bool, y::Bool, xaxis::Symbol=:xaxis, yaxis::Symbol=:yaxis)
    for (axis, islog) in ((xaxis, x), (yaxis, y))
        d = PlotlySupply._symbol_dict(get(fig.layout.fields, axis, nothing))
        if islog
            @test get(d, :type, "-") == "log"
            @test get(d, :exponentformat, "-") == "power"
        else
            @test get(d, :type, "-") != "log"
        end
    end
    return nothing
end

# Per-trace `showlegend` / marker values of `traces`.
_showlegends(traces) = [t[:showlegend] for t in traces]
_marker_sizes(traces) = [t[:marker][:size] for t in traces]
_marker_symbols(traces) = [t[:marker][:symbol] for t in traces]
