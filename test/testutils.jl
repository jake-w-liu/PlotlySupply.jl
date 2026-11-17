# Shared fixtures for the PlotlySupply test files: fake Electron backends and
# lifecycle/subplot helpers. `runtests.jl` includes this file once; a test file
# that needs them starts with
#     isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")
# so that it also runs on its own: `julia --project=. test/<file>.jl`.

using Test
using PlotlySupply

const _PLOTLYSUPPLY_TESTUTILS = true

# Test files that runtests.jl runs first, in this order (the static suite checks
# first, then the pre-2.0 suites in the order they were added).
const _TEST_FILES_RUN_FIRST = (
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

# Every test file in `testdir`, in the order runtests.jl runs them: the files of
# `_TEST_FILES_RUN_FIRST`, then every other `*.jl` file except the runner and
# this file in name order, so a new test file runs without being registered.
# A listed file that no longer exists is skipped here, so the rest of the suite
# still runs, and reported by hygiene.jl.
function _test_files_in_run_order(testdir::AbstractString)
    available = sort!(filter(
        name -> endswith(name, ".jl") && !(name in ("runtests.jl", "testutils.jl")) &&
            isfile(joinpath(testdir, name)),
        readdir(testdir),
    ))
    return vcat(
        filter(in(available), collect(_TEST_FILES_RUN_FIRST)),
        filter(!in(_TEST_FILES_RUN_FIRST), available),
    )
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

function _wait_for_lifecycle(predicate; timeout::Float64=5.0, collect::Bool=false)
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
