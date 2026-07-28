using Test
using PlotlySupply
using Base64

struct _UnsupportedTrace <: AbstractTrace end

mutable struct _CountingTraceVector <: AbstractVector{GenericTrace}
    data::Vector{GenericTrace}
end
Base.IndexStyle(::Type{_CountingTraceVector}) = IndexLinear()
Base.size(v::_CountingTraceVector) = size(v.data)
Base.getindex(v::_CountingTraceVector, i::Int) = v.data[i]
Base.setindex!(v::_CountingTraceVector, x, i::Int) = (v.data[i] = x)
Base.push!(v::_CountingTraceVector, xs...) = (push!(v.data, xs...); v)
Base.append!(v::_CountingTraceVector, xs) = (append!(v.data, xs); v)
Base.sizehint!(v::_CountingTraceVector, n::Integer) = (sizehint!(v.data, n); v)

mutable struct _LifecycleFakeWindow
    exists::Bool
    msg_channel::Channel{Any}
    uri::String
    close_calls::Int
    throw_on_close::Bool
    throw_on_isopen::Bool
    on_close::Any
    close_entered::Union{Nothing,Channel{Nothing}}
    close_release::Union{Nothing,Channel{Nothing}}
end

mutable struct _LifecycleFakeElectron
    windows::Vector{_LifecycleFakeWindow}
    fail_window::Bool
    throw_on_close::Bool
    throw_on_isopen::Bool
    block_close::Bool
end

_LifecycleFakeElectron(;
    fail_window::Bool=false,
    throw_on_close::Bool=false,
    throw_on_isopen::Bool=false,
    block_close::Bool=false,
) = _LifecycleFakeElectron(
    _LifecycleFakeWindow[],
    fail_window,
    throw_on_close,
    throw_on_isopen,
    block_close,
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
    end
    return getfield(ec, name)
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
        (
            length(PlotlySupply._PLOT_SYNCPLOT_MAP),
            length(PlotlySupply._DISPLAYED_PLOTS),
        )
    end
end

function _lifecycle_is_registered(plot, sp)
    return lock(PlotlySupply._SYNCPLOT_REGISTRY_LOCK) do
        get(PlotlySupply._PLOT_SYNCPLOT_MAP, plot, nothing) === sp &&
            any(candidate -> candidate === sp, PlotlySupply._DISPLAYED_PLOTS)
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
function PlotlySupply._plotlyjs_refresh!(
    ::SyncPlot,
    ::_CountingTraceVector,
    ::Layout;
    kwargs...,
)
    _subplot_refresh_calls[] += 1
    return nothing
end

@testset "PlotlySupply.jl" begin
    # Write your tests here.

    @testset "plot_scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false, fontsize=12)
        @test fig isa Plot

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, legend=["trace1", "trace2"], mode=["markers", "lines+markers"], color=["red", "blue"])
        @test fig2 isa Plot
    end

    @testset "plot_stem" begin
        x = 1:10
        y = rand(10)
        fig = plot_stem(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false)
        @test fig isa Plot

        y2 = [rand(10), rand(10)]
        fig2 = plot_stem(x, y2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test fig2 isa Plot
    end

    @testset "plot_bar" begin
        x = 1:10
        y = rand(10)
        fig = plot_bar(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false)
        @test fig isa Plot

        y2 = [rand(10), rand(10)]
        fig2 = plot_bar(x, y2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test fig2 isa Plot
    end

    @testset "plot_histogram" begin
        x = randn(200)
        fig = plot_histogram(x, title="Histogram", xlabel="x", ylabel="count", nbinsx=30, width=500, height=500)
        @test fig isa Plot

        xmulti = [randn(100), randn(100) .+ 1.0]
        fig2 = plot_histogram(xmulti, legend=["h1", "h2"], color=["red", "blue"], histnorm="probability")
        @test fig2 isa Plot
    end

    @testset "plot_box" begin
        x = fill("group A", 20)
        y = randn(20)
        fig = plot_box(x, y, title="Box", xlabel="group", ylabel="value", width=500, height=500)
        @test fig isa Plot

        y2 = [randn(20), randn(20) .+ 0.5]
        fig2 = plot_box(y2, legend=["b1", "b2"], color=["red", "blue"])
        @test fig2 isa Plot
    end

    @testset "plot_violin" begin
        x = fill("group A", 20)
        y = randn(20)
        fig = plot_violin(x, y, title="Violin", xlabel="group", ylabel="value", width=500, height=500)
        @test fig isa Plot

        y2 = [randn(20), randn(20) .+ 0.5]
        fig2 = plot_violin(y2, legend=["v1", "v2"], color=["red", "blue"], side="positive")
        @test fig2 isa Plot
    end

    @testset "plot_scatterpolar" begin
        theta = 0:0.1:2*pi
        r = sin.(theta)
        fig = plot_scatterpolar(theta, r, title="My Title", trange=[0, 360], rrange=[0, 1], width=500, height=500, grid=false)
        @test fig isa Plot

        r2 = [sin.(theta), cos.(theta)]
        fig2 = plot_scatterpolar(theta, r2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test fig2 isa Plot
    end

    @testset "plot_heatmap" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_heatmap(x, y, U, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", equalar=true)
        @test fig isa Plot

        fig2 = plot_heatmap(U)
        @test fig2 isa Plot
    end

    @testset "plot_contour" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_contour(x, y, U, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", equalar=true, fontsize=11)
        @test fig isa Plot

        fig2 = plot_contour(U)
        @test fig2 isa Plot
    end

    @testset "plot_quiver" begin
        x = 1:10
        y = 1:10
        u = rand(10)
        v = rand(10)
        fig = plot_quiver(x, y, u, v, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 10], width=500, height=500, color="red", sizeref=0.5, grid=false)
        @test fig isa Plot
    end

    @testset "plot_surface" begin
        x = 1:10
        y = 1:20
        X = [i for i in x, j in y]
        Y = [j for i in x, j in y]
        Z = rand(10, 20)
        fig = plot_surface(X, Y, Z, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", aspectmode="cube", grid=false, showaxis=false)
        @test fig isa Plot

        fig2 = plot_surface(Z, surfacecolor=rand(10, 20))
        @test fig2 isa Plot
    end

    @testset "plot_scatter3d" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        fig = plot_scatter3d(x, y, z, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 10], zrange=[0, 1], width=500, height=500, mode="markers", color="red", legend="trace1", aspectmode="cube", perspective=false, grid=false, showaxis=false)
        @test fig isa Plot

        z2 = [rand(10), rand(10)]
        x2 = [1:10, 1:10]
        y2 = [1:10, 1:10]
        fig2 = plot_scatter3d(x2, y2, z2, color=["red", "blue"], legend=["trace1", "trace2"], mode=["markers", "lines+markers"])
        @test fig2 isa Plot
    end

    @testset "plot_quiver3d" begin
        x = 1:10
        y = 1:10
        z = 1:10
        u = rand(10)
        v = rand(10)
        w = rand(10)
        fig = plot_quiver3d(x, y, z, u, v, w, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 10], zrange=[0, 10], width=500, height=500, color="red", colorscale="Viridis", sizeref=0.5, aspectmode="cube", perspective=false, grid=false, showaxis=false)
        @test fig isa Plot
    end

    @testset "set_template!" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y)
        set_template!(fig, "plotly_dark")
        @test fig.layout.template == :plotly_dark
        set_template!(fig, "ggplot2")
        @test fig.layout.template == :ggplot2
        set_template!(fig, "seaborn")
        @test fig.layout.template == :seaborn
        set_template!(fig, "simple_white")
        @test fig.layout.template == :simple_white
        set_template!(fig, "presentation")
        @test fig.layout.template == :presentation
        set_template!(fig, "xgridoff")
        @test fig.layout.template == :xgridoff
        set_template!(fig, "ygridoff")
        @test fig.layout.template == :ygridoff
        set_template!(fig, "gridon")
        @test fig.layout.template == :gridon
        set_template!(fig, "none")
        @test fig.layout.template == :plotly_white

        prev_default = get_default_template()
        set_default_template!("plotly_dark")
        @test get_default_template() == :plotly_dark
        fig2 = plot_scatter(x, y)
        @test fig2.layout.template == :plotly_dark
        set_default_template!(prev_default)
    end

    @testset "Legend Defaults and Positioning" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y; legend="trace")
        @test fig.layout.fields[:legend][:xanchor] == "right"
        @test fig.layout.fields[:legend][:yanchor] == "top"
        @test fig.layout.fields[:legend][:bgcolor] == "rgba(255,255,255,0.72)"
        @test fig.layout.fields[:legend][:x] ≈ 0.98
        @test fig.layout.fields[:legend][:y] ≈ 0.97

        set_legend!(fig; position=:top, inset=(0.01, 0.02))
        @test fig.layout.fields[:legend][:xanchor] == "center"
        @test fig.layout.fields[:legend][:yanchor] == "top"
        @test fig.layout.fields[:legend][:x] ≈ 0.5
        @test fig.layout.fields[:legend][:y] ≈ 0.98
        set_legend!(fig; position=:outside_right, inset=(0.02, 0.03))
        @test fig.layout.fields[:legend][:xanchor] == "left"
        @test fig.layout.fields[:legend][:yanchor] == "top"
        @test fig.layout.fields[:legend][:x] ≈ 1.02
        plot_scatter!(fig, x, rand(10); legend="trace-next")
        @test fig.layout.fields[:legend][:xanchor] == "left"
        @test fig.layout.fields[:legend][:yanchor] == "top"

        prev_legend_pos = get_default_legend_position()
        set_default_legend_position!(:bottomleft)
        @test get_default_legend_position() == :bottomleft
        fig2 = plot_scatter(x, y; legend="trace2")
        @test fig2.layout.fields[:legend][:xanchor] == "left"
        @test fig2.layout.fields[:legend][:yanchor] == "bottom"
        set_default_legend_position!(prev_legend_pos)
    end

    @testset "Mutating Functions - plot_scatter!" begin
        x = 1:10
        y = rand(10)
        y2 = rand(10)
        y3 = rand(10)
        
        # Test basic scatter! with x and y
        fig = plot_scatter(x, y, title="Scatter Test")
        initial_trace_count = length(fig.data)
        plot_scatter!(fig, x, y2, color="red", legend="added trace")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
        
        # Test chaining multiple scatter! calls
        plot_scatter!(fig, x, y3, color="blue", legend="third trace")
        @test length(fig.data) == initial_trace_count + 2
        
        # Test scatter! without x (uses indices)
        fig2 = plot_scatter(y, title="Scatter Test 2")
        initial_count = length(fig2.data)
        plot_scatter!(fig2, y2, color="green", legend="appended")
        @test length(fig2.data) == initial_count + 1
        
        # Test scatter! with vector of vectors
        y_multi = [rand(10), rand(10)]
        fig3 = plot_scatter(y, title="Multi Scatter")
        initial_count = length(fig3.data)
        plot_scatter!(fig3, x, y_multi, color=["purple", "orange"], legend=["m1", "m2"])
        @test length(fig3.data) == initial_count + 2
    end

    @testset "Mutating Functions - plot_stem!" begin
        x = 1:10
        y = rand(10)
        y2 = rand(10)
        
        # Test basic stem! with x and y
        fig = plot_stem(x, y, title="Stem Test")
        initial_trace_count = length(fig.data)
        plot_stem!(fig, x, y2, color="red", legend="added stem")
        @test fig isa Plot
        @test length(fig.data) > initial_trace_count  # stem creates 2 traces per call
        
        # Test stem! without x (uses indices)
        fig2 = plot_stem(y, title="Stem Test 2")
        initial_count = length(fig2.data)
        plot_stem!(fig2, y2, color="green", legend="appended")
        @test length(fig2.data) > initial_count
        
        # Test stem! with vector of vectors
        y_multi = [rand(10), rand(10)]
        fig3 = plot_stem(y, title="Multi Stem")
        initial_count = length(fig3.data)
        plot_stem!(fig3, x, y_multi, color=["blue", "red"], legend=["s1", "s2"])
        @test length(fig3.data) > initial_count
    end

    @testset "Mutating Functions - plot_bar!" begin
        x = 1:10
        y = rand(10)
        y2 = rand(10)

        fig = plot_bar(x, y, title="Bar Test")
        initial_trace_count = length(fig.data)
        plot_bar!(fig, x, y2, color="red", legend="added bar")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1

        fig2 = plot_bar(y, title="Bar Test 2")
        initial_count = length(fig2.data)
        plot_bar!(fig2, y2, color="green", legend="appended")
        @test length(fig2.data) == initial_count + 1
    end

    @testset "Mutating Functions - plot_histogram!" begin
        x = randn(200)
        fig = plot_histogram(x, title="Histogram Test")
        initial_trace_count = length(fig.data)
        plot_histogram!(fig, randn(200) .+ 1.0, color="red", legend="h2", nbinsx=20)
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_box!" begin
        x = fill("A", 20)
        y = randn(20)
        y2 = randn(20) .+ 0.5

        fig = plot_box(x, y, title="Box Test")
        initial_trace_count = length(fig.data)
        plot_box!(fig, fill("B", 20), y2, color="red", legend="B")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1

        fig2 = plot_box(y, title="Box Test 2")
        initial_count = length(fig2.data)
        plot_box!(fig2, y2, color="green", legend="appended")
        @test length(fig2.data) == initial_count + 1
    end

    @testset "Mutating Functions - plot_violin!" begin
        x = fill("A", 20)
        y = randn(20)
        y2 = randn(20) .+ 0.5

        fig = plot_violin(x, y, title="Violin Test")
        initial_trace_count = length(fig.data)
        plot_violin!(fig, fill("B", 20), y2, color="red", legend="B", side="negative")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1

        fig2 = plot_violin(y, title="Violin Test 2")
        initial_count = length(fig2.data)
        plot_violin!(fig2, y2, color="green", legend="appended")
        @test length(fig2.data) == initial_count + 1
    end

    @testset "Mutating Functions - plot_scatterpolar!" begin
        theta = 0:0.1:2*pi
        r = sin.(theta)
        r2 = cos.(theta)
        
        fig = plot_scatterpolar(theta, r, title="Polar Test")
        initial_trace_count = length(fig.data)
        plot_scatterpolar!(fig, theta, r2, color="red", legend="cos trace")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_heatmap!" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        U2 = rand(10, 20)
        
        fig = plot_heatmap(x, y, U, title="Heatmap Test")
        initial_trace_count = length(fig.data)
        plot_heatmap!(fig, x, y, U2, title="Added Heatmap")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_contour!" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        U2 = rand(10, 20)
        
        fig = plot_contour(x, y, U, title="Contour Test")
        initial_trace_count = length(fig.data)
        plot_contour!(fig, x, y, U2, title="Added Contour")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_quiver!" begin
        x = 1:10
        y = 1:10
        u = rand(10)
        v = rand(10)
        u2 = rand(10)
        v2 = rand(10)
        
        fig = plot_quiver(x, y, u, v, title="Quiver Test")
        initial_trace_count = length(fig.data)
        plot_quiver!(fig, x, y, u2, v2, color="red")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_surface!" begin
        x = 1:10
        y = 1:20
        X = [i for i in x, j in y]
        Y = [j for i in x, j in y]
        Z = rand(10, 20)
        Z2 = rand(10, 20)
        
        fig = plot_surface(X, Y, Z, title="Surface Test")
        initial_trace_count = length(fig.data)
        plot_surface!(fig, X, Y, Z2, zlabel="Added Surface")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
        
        # Test with color matrix
        color_map = rand(10, 20)
        fig2 = plot_surface(X, Y, Z)
        initial_count = length(fig2.data)
        plot_surface!(fig2, X, Y, Z2, color=color_map)
        @test length(fig2.data) == initial_count + 1
    end

    @testset "Mutating Functions - plot_scatter3d!" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        z2 = rand(10)
        
        fig = plot_scatter3d(x, y, z, title="3D Scatter Test")
        initial_trace_count = length(fig.data)
        plot_scatter3d!(fig, x, y, z2, color="red", legend="added trace")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
        
        # Test with vector of vectors
        z_multi = [rand(10), rand(10)]
        x_multi = [1:10, 1:10]
        y_multi = [1:10, 1:10]
        fig2 = plot_scatter3d(x, y, z)
        initial_count = length(fig2.data)
        plot_scatter3d!(fig2, x_multi, y_multi, z_multi, color=["blue", "green"], legend=["m1", "m2"])
        @test length(fig2.data) > initial_count
    end

    @testset "Mutating Functions - plot_quiver3d!" begin
        x = 1:10
        y = 1:10
        z = 1:10
        u = rand(10)
        v = rand(10)
        w = rand(10)
        u2 = rand(10)
        v2 = rand(10)
        w2 = rand(10)
        
        fig = plot_quiver3d(x, y, z, u, v, w, title="3D Quiver Test")
        initial_trace_count = length(fig.data)
        plot_quiver3d!(fig, x, y, z, u2, v2, w2, color="red")
        @test fig isa Plot
        @test length(fig.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - Chaining" begin
        # Test method chaining with multiple mutating calls
        x = 1:10
        y1 = rand(10)
        y2 = rand(10)
        y3 = rand(10)
        y4 = rand(10)
        
        fig = plot_scatter(x, y1, title="Chained Mutations", xlabel="x", ylabel="y")
        
        # Chain multiple operations
        plot_scatter!(fig, x, y2, color="red", legend="trace 2") |> 
            _ -> plot_scatter!(fig, x, y3, color="blue", legend="trace 3")
        
        plot_scatter!(fig, x, y4, color="green", legend="trace 4")
        
        @test fig isa Plot
        @test length(fig.data) >= 4
    end

    @testset "Subplots API" begin
        sf = PlotlySupply.subplots(2, 2; show=false, title="subplot-api")
        @test sf isa PlotlySupply.SubplotFigure
        @test sf.rows == 2
        @test sf.cols == 2
        @test sf.legend_position == get_default_legend_position()
        @test sf.plot.layout.template == get_default_template()

        PlotlySupply.plot!(sf, 1:5, rand(5); legend="A")
        PlotlySupply.subplot!(sf, 1, 2)
        PlotlySupply.plot_stem!(sf, 1:5, rand(5); legend="B")
        PlotlySupply.subplot!(sf, 3) # row 2, col 1
        PlotlySupply.plot_contour!(sf, rand(5, 5); title="contour")
        PlotlySupply.subplot!(sf, 2, 2)
        PlotlySupply.plot_heatmap!(sf, rand(5, 5); title="heat")

        xlabel!(sf, "x22")
        ylabel!(sf, "y22")
        xrange!(sf, [0, 6])
        yrange!(sf, [0, 6])

        @test length(sf.plot.data) >= 4
        @test sf.plot.data[1].fields[:legend] == "legend"
        @test sf.plot.data[2].fields[:legend] == "legend2"
        @test sf.plot.data[end - 1].fields[:legend] == "legend3"
        @test sf.plot.data[end].fields[:legend] == "legend4"
        @test haskey(sf.plot.layout.fields, :legend)
        @test haskey(sf.plot.layout.fields, :legend2)
        @test haskey(sf.plot.layout.fields, :legend3)
        @test haskey(sf.plot.layout.fields, :legend4)
        @test sf.plot.data[1].fields[:showlegend] == true
        @test sf.plot.data[2].fields[:showlegend] == true
        @test sf.plot.layout.fields[:showlegend] == true

        @test sf.plot.layout.fields[:legend2][:x] > sf.plot.layout.fields[:legend][:x]
        @test sf.plot.layout.fields[:legend3][:y] < sf.plot.layout.fields[:legend][:y]
        @test subplot_legends!(sf) === sf
        @test set_legend!(sf; position=:bottomleft, inset=(0.01, 0.01)) === sf
        @test sf.legend_position == :bottomleft
        @test sf.plot.layout.fields[:legend][:xanchor] == "left"
        @test sf.plot.layout.fields[:legend][:yanchor] == "bottom"
        @test sf.plot.layout.fields[:xaxis4][:title_text] == "x22"
        @test sf.plot.layout.fields[:yaxis4][:title_text] == "y22"
        @test sf.plot.layout.fields[:xaxis4][:range] == [0, 6]
        @test sf.plot.layout.fields[:yaxis4][:range] == [0, 6]

        close(sf.fig)

        sf_raw = PlotlySupply.subplots(1, 2; sync=false, title="raw-subplots")
        @test sf_raw isa PlotlySupply.SubplotFigure
        @test sf_raw.fig isa Plot
        set_legend!(sf_raw; position=:top)
        PlotlySupply.plot_scatter!(sf_raw, 1:5, rand(5); legend="raw")
        PlotlySupply.subplot!(sf_raw, 2)
        PlotlySupply.plot_scatter!(sf_raw, 1:5, rand(5); legend="raw2")
        @test length(sf_raw.plot.data) == 2
        @test sf_raw.plot.layout.template == get_default_template()
        @test sf_raw.plot.layout.fields[:showlegend] == true
    end

    @testset "Subplots API - Statistical Traces" begin
        sf = PlotlySupply.subplots(2, 2; sync=false, title="subplot-stats")
        @test sf.fig isa Plot

        subplot!(sf, 1, 1)
        plot_bar!(sf, 1:5, rand(5); legend="bar")
        subplot!(sf, 1, 2)
        plot_histogram!(sf, randn(200); legend="hist")
        subplot!(sf, 2, 1)
        plot_box!(sf, randn(30); legend="box")
        subplot!(sf, 2, 2)
        plot_violin!(sf, randn(30); legend="violin")

        @test length(sf.plot.data) == 4
        @test sf.plot.data[1].fields[:type] == "bar"
        @test sf.plot.data[2].fields[:type] == "histogram"
        @test sf.plot.data[3].fields[:type] == "box"
        @test sf.plot.data[4].fields[:type] == "violin"
        @test sf.plot.layout.fields[:showlegend] == true
        @test haskey(sf.plot.layout.fields, :legend)
        @test haskey(sf.plot.layout.fields, :legend2)
        @test haskey(sf.plot.layout.fields, :legend3)
        @test haskey(sf.plot.layout.fields, :legend4)
    end

    @testset "Desktop SyncPlot Interop" begin
        fig = plot_scatter(1:5, rand(5))

        try
            sp = to_syncplot(fig; show=false)
            @test sp isa SyncPlot
            close(sp)
        catch err
            # Accept environments where ElectronCall is not installed.
            @test err isa Exception
            @test occursin("ElectronCall", sprint(showerror, err))
        end
    end

    @testset "Coverage Branches - Constructors" begin
        x_multi = [collect(0:3), collect(1:4)]
        y_multi = [rand(4), rand(4)]

        # plot_scatter branches: x/y vectors, mode string fill!, dash vector loop, color/legend fill!
        fig_scatter_multi = plot_scatter(
            x_multi,
            y_multi;
            mode="markers",
            dash=["dash", "dot"],
            color="purple",
            legend="bundle",
        )
        @test fig_scatter_multi isa Plot
        @test length(fig_scatter_multi.data) == 2

        # y-only vector-of-vectors branch
        fig_scatter_yonly = plot_scatter(y_multi)
        @test fig_scatter_yonly isa Plot

        # plot_stem branches: x/y vectors and fontsize path
        fig_stem_multi = plot_stem(x_multi, y_multi; color="black", legend="stem", fontsize=10)
        @test fig_stem_multi isa Plot
        @test length(fig_stem_multi.data) > 2
        fig_stem_yonly = plot_stem(y_multi)
        @test fig_stem_yonly isa Plot

        # plot_scatterpolar branches: theta vectors, mode/dash vector loops, color/legend fill!, fontsize
        theta_multi = [collect(0:30:90), collect(15:30:105)]
        r_multi = [rand(4), rand(4)]
        fig_polar_multi = plot_scatterpolar(
            theta_multi,
            r_multi;
            mode=["lines", "markers"],
            dash=["dash", "dot"],
            color="red",
            legend="polar",
            fontsize=11,
        )
        @test fig_polar_multi isa Plot
        @test length(fig_polar_multi.data) == 2

        # heatmap/contour edge branches for dx/dy fallback and fontsize
        U13 = rand(1, 3)
        U31 = rand(3, 1)
        fig_heat_dx0 = plot_heatmap([0.0], [0.0, 1.0, 2.0], U13; equalar=true, fontsize=9)
        fig_heat_dy0 = plot_heatmap([0.0, 1.0, 2.0], [0.0], U31; equalar=true)
        @test fig_heat_dx0 isa Plot
        @test fig_heat_dy0 isa Plot

        fig_contour_dx0 = plot_contour([0.0], [0.0, 1.0, 2.0], U13; equalar=true, fontsize=9)
        fig_contour_dy0 = plot_contour([0.0, 1.0, 2.0], [0.0], U31; equalar=true)
        @test fig_contour_dx0 isa Plot
        @test fig_contour_dy0 isa Plot

        fig_quiver_font = plot_quiver(1:5, 1:5, rand(5), rand(5); fontsize=10)
        @test fig_quiver_font isa Plot

        # plot_surface shared coloraxis branches (with and without explicit colorscale)
        X = [i for i in 1:3, j in 1:3]
        Y = [j for i in 1:3, j in 1:3]
        Z = rand(3, 3)
        C = rand(3, 3)
        fig_surface_shared_default = plot_surface(
            X,
            Y,
            Z;
            surfacecolor=C,
            shared_coloraxis=true,
            colorscale="",
            fontsize=10,
        )
        fig_surface_shared_scaled = plot_surface(
            X,
            Y,
            Z;
            surfacecolor=C,
            shared_coloraxis=true,
            colorscale="Viridis",
        )
        @test fig_surface_shared_default isa Plot
        @test fig_surface_shared_scaled isa Plot

        # plot_scatter3d multi branch with fill! paths for mode/color/legend
        x3 = [collect(1:4), collect(1:4)]
        y3 = [collect(1:4), collect(1:4)]
        z3 = [rand(4), rand(4)]
        fig_scatter3d_multi_fill = plot_scatter3d(x3, y3, z3; mode="lines+markers", color="orange", legend="traj", fontsize=10)
        @test fig_scatter3d_multi_fill isa Plot

        fig_quiver3d_font = plot_quiver3d(1:5, 1:5, 1:5, rand(5), rand(5), rand(5); fontsize=10)
        @test fig_quiver3d_font isa Plot
    end

    @testset "Coverage Branches - Mutating APIs" begin
        x_multi = [collect(0:3), collect(1:4)]
        y_multi = [rand(4), rand(4)]

        fig_scatter = plot_scatter(1:4, rand(4))
        plot_scatter!(
            fig_scatter,
            x_multi,
            y_multi;
            mode=["markers", "lines"],
            dash=["dash", "dot"],
            color="purple",
            legend="bundle",
            title="scatter mut",
            xlabel="x",
            ylabel="y",
            xrange=[0, 4],
            yrange=[0, 1],
            width=420,
            height=320,
            grid=false,
            fontsize=9,
        )
        plot_scatter!(fig_scatter, y_multi)
        @test fig_scatter isa Plot

        fig_stem = plot_stem(1:4, rand(4))
        plot_stem!(
            fig_stem,
            x_multi,
            y_multi;
            color="black",
            legend="stem",
            title="stem mut",
            xlabel="x",
            ylabel="y",
            xrange=[0, 4],
            yrange=[0, 1],
            width=420,
            height=320,
            grid=false,
            fontsize=9,
        )
        plot_stem!(fig_stem, y_multi)
        @test fig_stem isa Plot

        theta_multi = [collect(0:30:90), collect(15:30:105)]
        r_multi = [rand(4), rand(4)]
        fig_polar = plot_scatterpolar(collect(0:30:90), rand(4))
        plot_scatterpolar!(
            fig_polar,
            theta_multi,
            r_multi;
            mode=["lines", "markers"],
            dash=["dash", "dot"],
            color="red",
            legend="polar",
            title="polar mut",
            trange=[0, 120],
            rrange=[0, 1],
            width=420,
            height=320,
            grid=false,
            fontsize=9,
        )
        # mixed branch: theta scalar-vector + r vector-of-vectors, mode/dash scalar, color/legend vectors
        plot_scatterpolar!(
            fig_polar,
            collect(0:30:90),
            r_multi;
            mode="lines+markers",
            dash="dash",
            color=["teal", "brown"],
            legend=["r1", "r2"],
        )
        @test fig_polar isa Plot

        U13 = rand(1, 3)
        U31 = rand(3, 1)
        fig_heat = plot_heatmap(rand(3, 3))
        plot_heatmap!(
            fig_heat,
            [0.0],
            [0.0, 1.0, 2.0],
            U13;
            zrange=[0, 1],
            title="heat mut",
            xlabel="x",
            ylabel="y",
            xrange=[0, 1],
            yrange=[0, 2],
            equalar=true,
            width=400,
            height=300,
            fontsize=9,
        )
        plot_heatmap!(fig_heat, U31; xlabel="x2")
        @test fig_heat isa Plot

        fig_cont = plot_contour(rand(3, 3))
        plot_contour!(
            fig_cont,
            [0.0],
            [0.0, 1.0, 2.0],
            U13;
            zrange=[0, 1],
            title="cont mut",
            xlabel="x",
            ylabel="y",
            xrange=[0, 1],
            yrange=[0, 2],
            equalar=true,
            width=400,
            height=300,
            fontsize=9,
        )
        plot_contour!(fig_cont, U31; xlabel="x2")
        @test fig_cont isa Plot

        fig_quiver = plot_quiver(1:5, 1:5, rand(5), rand(5))
        plot_quiver!(
            fig_quiver,
            1:5,
            1:5,
            rand(5),
            rand(5);
            color="green",
            title="q mut",
            xlabel="x",
            ylabel="y",
            xrange=[0, 6],
            yrange=[0, 6],
            width=400,
            height=300,
            grid=false,
            fontsize=9,
        )
        @test fig_quiver isa Plot

        X = [i for i in 1:3, j in 1:3]
        Y = [j for i in 1:3, j in 1:3]
        Z = rand(3, 3)
        C = rand(3, 3)
        fig_surface = plot_surface(Z)
        plot_surface!(
            fig_surface,
            X,
            Y,
            Z;
            color=C,
            shared_coloraxis=true,
            colorscale="",
            title="s mut",
            xrange=[0, 4],
            yrange=[0, 4],
            zrange=[0, 1],
            width=420,
            height=320,
            grid=false,
            showaxis=false,
            fontsize=9,
        )
        plot_surface!(fig_surface, X, Y, Z; color=C, shared_coloraxis=true, colorscale="Viridis")
        @test fig_surface isa Plot

        x3 = [collect(1:4), collect(1:4)]
        y3 = [collect(1:4), collect(1:4)]
        z3 = [rand(4), rand(4)]
        fig_s3 = plot_scatter3d(1:4, 1:4, rand(4))
        plot_scatter3d!(
            fig_s3,
            x3,
            y3,
            z3;
            mode=["markers", "lines"],
            color="orange",
            legend="traj",
            title="s3 mut",
            aspectmode="cube",
            perspective=false,
            xrange=[0, 5],
            yrange=[0, 5],
            zrange=[0, 1],
            width=420,
            height=320,
            grid=false,
            showaxis=false,
            fontsize=9,
        )
        @test fig_s3 isa Plot

        fig_q3 = plot_quiver3d(1:4, 1:4, 1:4, rand(4), rand(4), rand(4))
        plot_quiver3d!(
            fig_q3,
            1:4,
            1:4,
            1:4,
            rand(4),
            rand(4),
            rand(4);
            color="magenta",
            title="q3 mut",
            aspectmode="cube",
            perspective=false,
            xrange=[0, 5],
            yrange=[0, 5],
            zrange=[0, 5],
            width=420,
            height=320,
            grid=false,
            showaxis=false,
            fontsize=9,
        )
        @test fig_q3 isa Plot
    end

    @testset "Coverage Branches - Internal + SyncPlot" begin
        @test PlotlySupply._tuple_interleave(([1, 2], [3, 4], [5, 6])) == [1, 3, 5, 2, 4, 6]
        @test_throws ArgumentError PlotlySupply._plot_obj(1)

        html_bytes = savefig(plot_scatter(1:3, rand(3)); format="html")
        @test length(html_bytes) > 0

        # Image export now uses Electron; skip if display backend unavailable.
        try
            svg_bytes = savefig(plot_scatter(1:3, rand(3)); format="svg")
            @test length(svg_bytes) > 0
        catch err
            @test occursin("ElectronCall", sprint(showerror, err)) || occursin("Plotly.js", sprint(showerror, err))
        end

        # JSON export
        json_bytes = savefig(plot_scatter(1:3, rand(3)); format="json")
        @test length(json_bytes) > 0

        # EPS should error with suggestion
        @test_throws ErrorException savefig(plot_scatter(1:3, rand(3)); format="eps")

        # Regression: NaN separators (used by quiver-like traces) should still export.
        p_nan = Plot(scatter(x=[1.0, 2.0, NaN, 3.0], y=[1.0, 2.0, NaN, 3.0]), Layout(title="nan-export"))
        try
            svg_nan = savefig(p_nan; format="svg")
            @test length(svg_nan) > 0
        catch err
            @test occursin("ElectronCall", sprint(showerror, err)) || occursin("Plotly.js", sprint(showerror, err))
        end

        html_fn = tempname() * ".html"
        savefig(html_fn, plot_scatter(1:3, rand(3)); format="html")
        @test isfile(html_fn)
        @test occursin("<html", lowercase(read(html_fn, String)))

        mg = mgrid(1:2, 1:3)
        @test length(mg) == 2
        @test size(mg[1]) == (2, 3)
        @test size(mg[2]) == (2, 3)

        # Exercise syncplot API paths; skip only if backend fails at runtime.
        try
            fig = plot_scatter(1:4, rand(4))
            sp = to_syncplot(fig; show=false, title="coverage-sync")
            @test sp isa SyncPlot
            @test to_syncplot(sp) === sp
            @test PlotlySupply._plot_obj(sp) isa Plot
            @test isopen(sp) isa Bool
            @test occursin("SyncPlot", sprint(show, sp))
            @test msgchannel(sp) isa Channel

            # plot(...) compatibility entry points
            sp1 = plot(scatter(x=[1, 2], y=[2, 1]); sync=true, show=false, title="p1")
            sp2 = plot([scatter(x=[1, 2], y=[1, 2])]; sync=true, show=false, title="p2")
            sp3 = plot(scatter(x=[1], y=[1]), scatter(x=[1], y=[2]); sync=true, show=false, title="p3")
            sp4 = plot(; layout=Layout(title="empty"), sync=true, show=false, title="p4")
            sp5 = plot(Plot(scatter(x=[1, 2], y=[2, 1]), Layout(title="fig")); sync=true, show=false, title="p5")
            raw = plot(scatter(x=[1, 2], y=[2, 1]); sync=false, title="raw")
            @test sp1 isa SyncPlot
            @test sp2 isa SyncPlot
            @test sp3 isa SyncPlot
            @test sp4 isa SyncPlot
            @test sp5 isa SyncPlot
            @test raw isa Plot

            # Sync mutating wrappers
            react!(sp, [scatter(x=[1, 2], y=[2, 1])], Layout(title="react1"))
            react!(sp, Plot(scatter(x=[1, 2], y=[1, 2]), Layout(title="react2")))
            relayout!(sp, title="layout")
            restyle!(sp, marker=attr(size=8))
            addtraces!(sp, scatter(x=[1, 2], y=[3, 4]))
            movetraces!(sp, 1)
            extendtraces!(sp, Dict(:y => [[5, 6]]), [1], -1)
            prependtraces!(sp, Dict(:y => [[0]]), [1], -1)
            update!(sp, Dict(:name => "updated"), layout=Layout(title="updated"))
            update_xaxes!(sp, range=[0, 3])
            update_yaxes!(sp, range=[0, 6])
            update_polars!(sp, radialaxis=attr(range=[0, 2]))
            deletetraces!(sp, length(sp.plot.data))

            add_trace!(sp, scatter(x=[0], y=[0]))
            redraw!(sp)
            to_image(sp)
            download_image(sp)

            sp_relayout = relayout(sp, title="copy")
            @test sp_relayout isa SyncPlot

            # fallback false branch in isopen catch
            bogus = SyncPlot(Plot(scatter(y=[1])), nothing, nothing, "bogus")
            @test !isopen(bogus)
            @test PlotlySupply._syncplot_app((bogus,)) === nothing

            # concat overloads
            hsp = hcat(sp1, sp2)
            vsp = vcat(sp1, sp2)
            hvsp = hvcat((1, 1), sp1, sp2)
            @test hsp isa SyncPlot
            @test vsp isa SyncPlot
            @test hvsp isa SyncPlot

            close(sp)
            close(sp1)
            close(sp2)
            close(sp3)
            close(sp4)
            close(sp5)
            close(hsp)
            close(vsp)
            close(hvsp)
        catch err
            @test err isa Exception
        end
    end

    # ============================================================
    # New feature tests: xscale/yscale, marker_size/marker_symbol, showlegend
    # ============================================================

    @testset "xscale/yscale - scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, xscale="log", yscale="log")
        @test fig isa Plot

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, xscale="log")
        @test fig2 isa Plot

        # y-only variant
        fig3 = plot_scatter(y, yscale="log")
        @test fig3 isa Plot

        fig3m = plot_scatter(y2, xscale="log", yscale="log")
        @test fig3m isa Plot
    end

    @testset "marker_size/marker_symbol - scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, mode="markers", marker_size=10, marker_symbol="circle-open")
        @test fig isa Plot

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, mode="markers", marker_size=[8, 12], marker_symbol=["circle", "square"])
        @test fig2 isa Plot

        # scalar marker on multi-trace
        fig3 = plot_scatter(x, y2, mode="markers", marker_size=6, marker_symbol="diamond")
        @test fig3 isa Plot

        # y-only with markers
        fig4 = plot_scatter(y, mode="markers", marker_size=5)
        @test fig4 isa Plot
    end

    @testset "showlegend - scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, showlegend=false)
        @test fig isa Plot

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, showlegend=[true, false])
        @test fig2 isa Plot

        fig3 = plot_scatter(x, y2, showlegend=true)
        @test fig3 isa Plot

        # y-only
        fig4 = plot_scatter(y2, showlegend=[false, true])
        @test fig4 isa Plot
    end

    @testset "xscale/yscale - stem" begin
        x = 1:10
        y = rand(10)
        fig = plot_stem(x, y, xscale="log", yscale="log")
        @test fig isa Plot

        y2 = [rand(10), rand(10)]
        fig2 = plot_stem(x, y2, xscale="log")
        @test fig2 isa Plot

        fig3 = plot_stem(y, yscale="log")
        @test fig3 isa Plot
    end

    @testset "showlegend - stem" begin
        x = 1:10
        y2 = [rand(10), rand(10)]
        fig = plot_stem(x, y2, showlegend=[true, false])
        @test fig isa Plot

        fig2 = plot_stem(x, y2, showlegend=true)
        @test fig2 isa Plot

        # single trace
        fig3 = plot_stem(x, rand(10), showlegend=false)
        @test fig3 isa Plot

        # y-only
        fig4 = plot_stem(y2, showlegend=[false, true])
        @test fig4 isa Plot
    end

    @testset "xscale/yscale/showlegend - bar" begin
        x = 1:5
        y = rand(5)
        fig = plot_bar(x, y, xscale="log", yscale="log")
        @test fig isa Plot

        y2 = [rand(5), rand(5)]
        fig2 = plot_bar(x, y2, showlegend=[true, false], xscale="log")
        @test fig2 isa Plot

        fig3 = plot_bar(x, y2, showlegend=true)
        @test fig3 isa Plot

        fig4 = plot_bar(x, y, showlegend=false)
        @test fig4 isa Plot

        # y-only
        fig5 = plot_bar(y, xscale="log", yscale="log", showlegend=false)
        @test fig5 isa Plot

        fig6 = plot_bar(y2, showlegend=[true, false])
        @test fig6 isa Plot
    end

    @testset "xscale/yscale/showlegend - histogram" begin
        x = randn(200)
        fig = plot_histogram(x, xscale="log", yscale="log")
        @test fig isa Plot

        xmulti = [randn(100), randn(100) .+ 1.0]
        fig2 = plot_histogram(xmulti, showlegend=[true, false])
        @test fig2 isa Plot

        fig3 = plot_histogram(xmulti, showlegend=true)
        @test fig3 isa Plot

        fig4 = plot_histogram(x, showlegend=false)
        @test fig4 isa Plot
    end

    @testset "xscale/yscale/showlegend - box" begin
        x = fill("A", 20)
        y = randn(20)
        fig = plot_box(x, y, xscale="log", yscale="log")
        @test fig isa Plot

        y2 = [randn(20), randn(20)]
        x2 = [fill("A", 20), fill("B", 20)]
        fig2 = plot_box(x2, y2, showlegend=[true, false])
        @test fig2 isa Plot

        fig3 = plot_box(x, y, showlegend=false)
        @test fig3 isa Plot

        # y-only
        fig4 = plot_box(y2, xscale="log", showlegend=[true, false])
        @test fig4 isa Plot

        fig5 = plot_box(y, showlegend=false)
        @test fig5 isa Plot

        fig6 = plot_box(y2, showlegend=true)
        @test fig6 isa Plot
    end

    @testset "xscale/yscale/showlegend - violin" begin
        x = fill("A", 20)
        y = randn(20)
        fig = plot_violin(x, y, xscale="log", yscale="log")
        @test fig isa Plot

        y2 = [randn(20), randn(20)]
        x2 = [fill("A", 20), fill("B", 20)]
        fig2 = plot_violin(x2, y2, showlegend=[true, false])
        @test fig2 isa Plot

        fig3 = plot_violin(x, y, showlegend=false)
        @test fig3 isa Plot

        # y-only
        fig4 = plot_violin(y2, yscale="log", showlegend=[false, true])
        @test fig4 isa Plot

        fig5 = plot_violin(y, showlegend=false)
        @test fig5 isa Plot

        fig6 = plot_violin(y2, showlegend=true)
        @test fig6 isa Plot
    end

    @testset "xscale/yscale - heatmap" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_heatmap(x, y, U, xscale="log", yscale="log")
        @test fig isa Plot

        fig2 = plot_heatmap(U, xscale="log")
        @test fig2 isa Plot
    end

    @testset "xscale/yscale - contour" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_contour(x, y, U, xscale="log", yscale="log")
        @test fig isa Plot

        fig2 = plot_contour(U, yscale="log")
        @test fig2 isa Plot
    end

    @testset "marker_size/marker_symbol/showlegend - scatterpolar" begin
        theta = 0:10:350
        r = rand(36)
        fig = plot_scatterpolar(theta, r, mode="markers", marker_size=8, marker_symbol="circle-open")
        @test fig isa Plot

        r2 = [rand(36), rand(36)]
        fig2 = plot_scatterpolar(theta, r2, marker_size=[6, 10], marker_symbol=["circle", "square"], showlegend=[true, false])
        @test fig2 isa Plot

        fig3 = plot_scatterpolar(theta, r2, showlegend=true, marker_size=5)
        @test fig3 isa Plot

        fig4 = plot_scatterpolar(theta, r, showlegend=false)
        @test fig4 isa Plot
    end

    @testset "marker_size/marker_symbol/showlegend - scatter3d" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        fig = plot_scatter3d(x, y, z, mode="markers", marker_size=8, marker_symbol="circle-open")
        @test fig isa Plot

        z2 = [rand(10), rand(10)]
        x2 = [1:10, 1:10]
        y2 = [1:10, 1:10]
        fig2 = plot_scatter3d(x2, y2, z2, marker_size=[6, 10], marker_symbol=["circle", "square"], showlegend=[true, false])
        @test fig2 isa Plot

        fig3 = plot_scatter3d(x2, y2, z2, showlegend=true, marker_size=5)
        @test fig3 isa Plot

        fig4 = plot_scatter3d(x, y, z, showlegend=false)
        @test fig4 isa Plot
    end

    @testset "mutating variants - new features" begin
        # scatter!
        fig = plot_scatter(1:10, rand(10))
        plot_scatter!(fig, 1:10, rand(10), xscale="log", yscale="log", marker_size=5, marker_symbol="square", showlegend=false)
        @test fig isa Plot

        y2 = [rand(10), rand(10)]
        plot_scatter!(fig, 1:10, y2, marker_size=[4, 8], marker_symbol=["circle", "diamond"], showlegend=[true, false])
        @test fig isa Plot

        plot_scatter!(fig, y2, xscale="log", marker_size=6, showlegend=true)
        @test fig isa Plot

        # stem!
        fig2 = plot_stem(1:5, rand(5))
        plot_stem!(fig2, 1:5, rand(5), xscale="log", yscale="log", showlegend=false)
        @test fig2 isa Plot

        plot_stem!(fig2, 1:5, [rand(5), rand(5)], showlegend=[true, false])
        @test fig2 isa Plot

        plot_stem!(fig2, [rand(5), rand(5)], showlegend=true, xscale="log")
        @test fig2 isa Plot

        # bar!
        fig3 = plot_bar(1:5, rand(5))
        plot_bar!(fig3, 1:5, rand(5), xscale="log", yscale="log", showlegend=false)
        @test fig3 isa Plot

        plot_bar!(fig3, 1:5, [rand(5), rand(5)], showlegend=[true, false])
        @test fig3 isa Plot

        plot_bar!(fig3, [rand(5), rand(5)], xscale="log", showlegend=true)
        @test fig3 isa Plot

        # histogram!
        fig4 = plot_histogram(randn(100))
        plot_histogram!(fig4, randn(100), xscale="log", showlegend=false)
        @test fig4 isa Plot

        plot_histogram!(fig4, [randn(100), randn(100)], showlegend=[true, false])
        @test fig4 isa Plot

        # box!
        fig5 = plot_box(fill("A", 20), randn(20))
        plot_box!(fig5, fill("A", 20), randn(20), xscale="log", showlegend=false)
        @test fig5 isa Plot

        plot_box!(fig5, [fill("A", 20), fill("B", 20)], [randn(20), randn(20)], showlegend=[true, false])
        @test fig5 isa Plot

        plot_box!(fig5, randn(20), showlegend=false)
        @test fig5 isa Plot

        plot_box!(fig5, [randn(20), randn(20)], showlegend=[true, false])
        @test fig5 isa Plot

        # violin!
        fig6 = plot_violin(fill("A", 20), randn(20))
        plot_violin!(fig6, fill("A", 20), randn(20), yscale="log", showlegend=false)
        @test fig6 isa Plot

        plot_violin!(fig6, [fill("A", 20), fill("B", 20)], [randn(20), randn(20)], showlegend=[true, false])
        @test fig6 isa Plot

        plot_violin!(fig6, randn(20), showlegend=false)
        @test fig6 isa Plot

        plot_violin!(fig6, [randn(20), randn(20)], showlegend=[true, false])
        @test fig6 isa Plot

        # heatmap!
        fig7 = plot_heatmap(1:10, 1:20, rand(10, 20))
        plot_heatmap!(fig7, 1:10, 1:20, rand(10, 20), xscale="log", yscale="log")
        @test fig7 isa Plot

        plot_heatmap!(fig7, rand(10, 20), xscale="log")
        @test fig7 isa Plot

        # contour!
        fig8 = plot_contour(1:10, 1:20, rand(10, 20))
        plot_contour!(fig8, 1:10, 1:20, rand(10, 20), xscale="log", yscale="log")
        @test fig8 isa Plot

        plot_contour!(fig8, rand(10, 20), yscale="log")
        @test fig8 isa Plot

        # scatterpolar!
        fig9 = plot_scatterpolar(0:10:350, rand(36))
        plot_scatterpolar!(fig9, 0:10:350, rand(36), marker_size=8, marker_symbol="square", showlegend=false)
        @test fig9 isa Plot

        plot_scatterpolar!(fig9, 0:10:350, [rand(36), rand(36)], marker_size=[4, 8], showlegend=[true, false])
        @test fig9 isa Plot

        # scatter3d!
        fig10 = plot_scatter3d(1:10, 1:10, rand(10))
        plot_scatter3d!(fig10, 1:10, 1:10, rand(10), marker_size=8, marker_symbol="square", showlegend=false)
        @test fig10 isa Plot

        plot_scatter3d!(fig10, [1:10, 1:10], [1:10, 1:10], [rand(10), rand(10)], marker_size=[4, 8], showlegend=[true, false])
        @test fig10 isa Plot
    end

    @testset "scatter x-vector-of-vectors" begin
        x2 = [collect(1:10), collect(1:10)]
        y2 = [rand(10), rand(10)]
        fig = plot_scatter(x2, y2, marker_size=[4, 8], marker_symbol=["circle", "square"], showlegend=[true, false], xscale="log")
        @test fig isa Plot

        fig2 = plot_scatter(x2, y2, dash=["solid", "dash"])
        @test fig2 isa Plot
    end

    @testset "stem x-vector-of-vectors" begin
        x2 = [collect(1:5), collect(1:5)]
        y2 = [rand(5), rand(5)]
        fig = plot_stem(x2, y2, showlegend=[true, false], xscale="log")
        @test fig isa Plot
    end

    @testset "scatterpolar theta-vector-of-vectors" begin
        theta2 = [collect(0:10:350), collect(0:10:350)]
        r2 = [rand(36), rand(36)]
        fig = plot_scatterpolar(theta2, r2, marker_size=[4, 8], showlegend=[true, false])
        @test fig isa Plot
    end

    @testset "_apply_showlegend! helper" begin
        # Test the helper directly
        t1 = scatter(x=[1,2], y=[1,2])
        PlotlySupply._apply_showlegend!(t1, nothing)
        # nothing should not change the trace

        PlotlySupply._apply_showlegend!(t1, false)
        @test t1.showlegend == false

        traces = [scatter(x=[1,2], y=[1,2]), scatter(x=[1,2], y=[2,1])]
        PlotlySupply._apply_showlegend!(traces, true)
        @test traces[1].showlegend == true
        @test traces[2].showlegend == true

        traces2 = [scatter(x=[1,2], y=[1,2]), scatter(x=[1,2], y=[2,1])]
        PlotlySupply._apply_showlegend!(traces2, [false, true])
        @test traces2[1].showlegend == false
        @test traces2[2].showlegend == true
    end

    @testset "Legend position normalization" begin
        # Test _normalize_legend_position for all branches
        nlp = PlotlySupply._normalize_legend_position
        @test nlp(:top_left) == :topleft
        @test nlp(:upperleft) == :topleft
        @test nlp(:upper_left) == :topleft
        @test nlp("top-right") == :topright
        @test nlp(:bottom_right) == :bottomright
        @test nlp(:lowerright) == :bottomright
        @test nlp(:lower_right) == :bottomright
        @test nlp(:bottom_left) == :bottomleft
        @test nlp(:lowerleft) == :bottomleft
        @test nlp(:lower_left) == :bottomleft
        @test nlp(:outside_left) == :outside_left
        @test nlp(:left_outside) == :outside_left
        @test nlp(:outsideleft) == :outside_left
        @test nlp(:outside_top) == :outside_top
        @test nlp(:top_outside) == :outside_top
        @test nlp(:outsidetop) == :outside_top
        @test nlp(:outside_bottom) == :outside_bottom
        @test nlp(:bottom_outside) == :outside_bottom
        @test nlp(:outsidebottom) == :outside_bottom
        # Invalid position defaults to :topright
        @test nlp(:invalid_position_xyz) == :topright
    end

    @testset "Legend positions in set_legend!" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y; legend="trace")

        set_legend!(fig; position=:topleft)
        @test fig.layout.fields[:legend][:xanchor] == "left"
        @test fig.layout.fields[:legend][:yanchor] == "top"

        set_legend!(fig; position=:right)
        @test fig.layout.fields[:legend][:xanchor] == "right"
        @test fig.layout.fields[:legend][:yanchor] == "middle"

        set_legend!(fig; position=:center)
        @test fig.layout.fields[:legend][:xanchor] == "center"
        @test fig.layout.fields[:legend][:yanchor] == "middle"

        set_legend!(fig; position=:left)
        @test fig.layout.fields[:legend][:xanchor] == "left"
        @test fig.layout.fields[:legend][:yanchor] == "middle"

        set_legend!(fig; position=:bottomright)
        @test fig.layout.fields[:legend][:xanchor] == "right"
        @test fig.layout.fields[:legend][:yanchor] == "bottom"

        set_legend!(fig; position=:bottom)
        @test fig.layout.fields[:legend][:xanchor] == "center"
        @test fig.layout.fields[:legend][:yanchor] == "bottom"

        set_legend!(fig; position=:bottomleft)
        @test fig.layout.fields[:legend][:xanchor] == "left"
        @test fig.layout.fields[:legend][:yanchor] == "bottom"

        set_legend!(fig; position=:outside_left)
        @test fig.layout.fields[:legend][:xanchor] == "right"
        @test fig.layout.fields[:legend][:yanchor] == "top"

        set_legend!(fig; position=:outside_top)
        @test fig.layout.fields[:legend][:xanchor] == "center"
        @test fig.layout.fields[:legend][:yanchor] == "bottom"

        set_legend!(fig; position=:outside_bottom)
        @test fig.layout.fields[:legend][:xanchor] == "center"
        @test fig.layout.fields[:legend][:yanchor] == "top"
    end

    @testset "box/violin shared-x multi-trace (non-!)" begin
        # plot_box with shared x (not vector-of-vectors) and multi y
        x_shared = fill("A", 20)
        y_multi = [randn(20), randn(20) .+ 1.0]
        fig = plot_box(x_shared, y_multi, legend=["g1", "g2"], color=["red", "blue"])
        @test fig isa Plot
        @test length(fig.data) == 2

        # plot_violin with shared x and multi y
        fig2 = plot_violin(x_shared, y_multi, legend=["v1", "v2"], color=["red", "blue"])
        @test fig2 isa Plot
        @test length(fig2.data) == 2
    end

    @testset "box!/violin! shared-x multi-trace" begin
        x_shared = fill("A", 20)
        y_multi = [randn(20), randn(20) .+ 1.0]

        # plot_box! with shared x and multi y
        fig = plot_box(randn(20))
        n0 = length(fig.data)
        plot_box!(fig, x_shared, y_multi, legend=["g1", "g2"], color=["red", "blue"])
        @test length(fig.data) == n0 + 2

        # plot_violin! with shared x and multi y
        fig2 = plot_violin(randn(20))
        n0 = length(fig2.data)
        plot_violin!(fig2, x_shared, y_multi, legend=["v1", "v2"], color=["red", "blue"])
        @test length(fig2.data) == n0 + 2
    end

    @testset "surface!(fig, Z) delegation" begin
        Z = rand(5, 5)
        fig = plot_surface(rand(5, 5))
        n0 = length(fig.data)
        # Z-only variant delegates to X,Y,Z variant internally
        plot_surface!(fig, Z)
        @test length(fig.data) == n0 + 1
    end

    @testset "scatterpolar! vector marker_symbol" begin
        theta = collect(0:10:350)
        r_multi = [rand(36), rand(36)]
        fig = plot_scatterpolar(theta, rand(36))
        n0 = length(fig.data)
        plot_scatterpolar!(fig, theta, r_multi, marker_symbol=["circle", "square"], marker_size=[4, 8], showlegend=[true, false])
        @test length(fig.data) == n0 + 2
    end

    @testset "scatterpolar! Bool showlegend (multi-trace)" begin
        theta = collect(0:10:350)
        r_multi = [rand(36), rand(36)]
        fig = plot_scatterpolar(theta, rand(36))
        n0 = length(fig.data)
        plot_scatterpolar!(fig, theta, r_multi, showlegend=false)
        @test length(fig.data) == n0 + 2
    end

    @testset "scatter3d! vector marker kwargs" begin
        x = [1:5, 1:5]
        y = [1:5, 1:5]
        z = [rand(5), rand(5)]
        fig = plot_scatter3d(1:5, 1:5, rand(5))
        n0 = length(fig.data)
        plot_scatter3d!(fig, x, y, z, marker_size=[4, 8], marker_symbol=["circle", "diamond"], showlegend=[true, false])
        @test length(fig.data) == n0 + 2
    end

    @testset "scatter3d! Bool showlegend (multi-trace)" begin
        x = [1:5, 1:5]
        y = [1:5, 1:5]
        z = [rand(5), rand(5)]
        fig = plot_scatter3d(1:5, 1:5, rand(5))
        n0 = length(fig.data)
        plot_scatter3d!(fig, x, y, z, showlegend=true)
        @test length(fig.data) == n0 + 2
    end

    @testset "fontsize in helper-using functions" begin
        # Cover fontsize > 0 branch in _apply_cartesian_plot_options!
        fig = plot_bar(1:5, rand(5), fontsize=14)
        @test fig isa Plot
    end

    @testset "SubplotFigure property access" begin
        sf = PlotlySupply.subplots(1, 2; sync=false)
        # Test propertynames
        pnames = propertynames(sf)
        @test :fig in pnames
        @test :rows in pnames
        @test :cols in pnames

        # Test getproperty for known SubplotFigure fields
        @test sf.rows == 1
        @test sf.cols == 2

        # Test getproperty fallback to fig's :plot
        @test sf.plot isa Plot

        # Test getproperty delegation to fig's own properties (covers hasproperty path)
        @test sf.data isa Vector
        @test sf.layout isa Layout
    end

    @testset "SubplotFigure _resolve_subplot_cell error" begin
        sf = PlotlySupply.subplots(2, 2; sync=false)
        # Providing only row should error
        @test_throws ArgumentError PlotlySupply._resolve_subplot_cell(sf; row=1)
        # Providing only col should error
        @test_throws ArgumentError PlotlySupply._resolve_subplot_cell(sf; col=1)
        # Providing both should work
        r, c = PlotlySupply._resolve_subplot_cell(sf; row=1, col=2)
        @test r == 1
        @test c == 2
    end

    @testset "SubplotFigure add_trace! and addtraces!" begin
        sf = PlotlySupply.subplots(1, 2; sync=false)
        t1 = scatter(x=[1,2], y=[1,2], name="t1")
        PlotlyBase.add_trace!(sf, t1; row=1, col=1)
        @test length(sf.plot.data) >= 1
        @test sf.current_row == 1
        @test sf.current_col == 1

        t2 = scatter(x=[3,4], y=[3,4], name="t2")
        t3 = scatter(x=[5,6], y=[5,6], name="t3")
        PlotlyBase.addtraces!(sf, t2, t3; row=1, col=2)
        @test length(sf.plot.data) >= 3
        @test sf.current_row == 1
        @test sf.current_col == 2
    end

    @testset "SubplotFigure addtraces! batches atomically" begin
        sf = PlotlySupply.subplots(1, 2; sync=false)
        seed = scatter(x=[0], y=[0], name="seed", legendgroup="seed-group")
        PlotlyBase.add_trace!(sf, seed; row=1, col=1)

        t1 = scatter(
            x=[1,2],
            y=[3,4],
            name="one",
            legendgroup="group",
            showlegend=false,
        )
        t2 = scatter(x=[5,6], y=[7,8], name="two", legendgroup="group")
        @test PlotlyBase.addtraces!(sf, t1, t2; row=1, col=2) === sf
        @test length(sf.plot.data) == 3
        @test all(
            t.fields[:xaxis] == "x2" && t.fields[:yaxis] == "y2"
            for t in sf.plot.data[2:3]
        )
        @test all(t.fields[:legend] == "legend2" for t in sf.plot.data[2:3])
        @test sf.plot.data[2].fields[:showlegend] == false
        @test sf.plot.data[3].fields[:showlegend] == true
        @test all(t.fields[:legendgroup] == "group" for t in sf.plot.data[2:3])
        @test !haskey(t1.fields, :xaxis) && !haskey(t2.fields, :xaxis)
        @test (sf.current_row, sf.current_col) == (1, 2)

        atomic = PlotlySupply.subplots(1, 2; sync=false)
        layout_before = deepcopy(atomic.plot.layout.fields)
        cell_before = (atomic.current_row, atomic.current_col)
        valid = scatter(x=[1], y=[1], name="valid")
        @test_throws ArgumentError PlotlyBase.addtraces!(
            atomic,
            valid,
            _UnsupportedTrace();
            row=1,
            col=2,
        )
        @test isempty(atomic.plot.data)
        @test atomic.plot.layout.fields == layout_before
        @test (atomic.current_row, atomic.current_col) == cell_before

        @test_throws Exception PlotlyBase.addtraces!(atomic, valid; row=2, col=1)
        @test isempty(atomic.plot.data)
        @test_throws Exception PlotlyBase.addtraces!(
            atomic,
            valid;
            row=1,
            col=1,
            secondary_y=true,
        )
        @test isempty(atomic.plot.data)

        @test PlotlyBase.addtraces!(atomic; row=99, col=99) === atomic
        @test isempty(atomic.plot.data)
        @test (atomic.current_row, atomic.current_col) == cell_before
    end

    @testset "SubplotFigure addtraces! refreshes once" begin
        sf = PlotlySupply.subplots(1, 1; sync=false)
        p = Plot(_CountingTraceVector(copy(sf.plot.data)), sf.plot.layout)
        sf.fig = SyncPlot(p, nothing, nothing, "counting")
        traces = ntuple(
            i -> scatter(x=[1,2], y=[i,i+1], name="trace-$i"),
            4,
        )
        _subplot_refresh_calls[] = 0
        PlotlyBase.addtraces!(sf, traces...)
        @test _subplot_refresh_calls[] == 1
        @test length(sf.plot.data) == 4
    end

    @testset "SubplotFigure y-only delegations" begin
        sf = PlotlySupply.subplots(2, 3; sync=false)

        # scatter!(sf, y) - y-only
        PlotlySupply.subplot!(sf, 1, 1)
        PlotlySupply.plot_scatter!(sf, rand(5))
        @test length(sf.plot.data) >= 1

        # stem!(sf, y) - y-only
        PlotlySupply.subplot!(sf, 1, 2)
        PlotlySupply.plot_stem!(sf, rand(5))
        @test length(sf.plot.data) >= 2

        # bar!(sf, y) - y-only
        PlotlySupply.subplot!(sf, 1, 3)
        PlotlySupply.plot_bar!(sf, rand(5))
        @test length(sf.plot.data) >= 3

        # box!(sf, x, y) - x,y variant
        PlotlySupply.subplot!(sf, 2, 1)
        PlotlySupply.plot_box!(sf, fill("A", 10), randn(10))
        @test length(sf.plot.data) >= 4

        # violin!(sf, x, y) - x,y variant
        PlotlySupply.subplot!(sf, 2, 2)
        PlotlySupply.plot_violin!(sf, fill("A", 10), randn(10))
        @test length(sf.plot.data) >= 5
    end

    @testset "SubplotFigure heatmap/contour x,y,U delegations" begin
        sf = PlotlySupply.subplots(1, 2; sync=false)

        # heatmap!(sf, x, y, U) - x,y,U variant
        PlotlySupply.subplot!(sf, 1, 1)
        PlotlySupply.plot_heatmap!(sf, 1:5, 1:5, rand(5, 5))
        @test length(sf.plot.data) >= 1

        # contour!(sf, x, y, U) - x,y,U variant
        PlotlySupply.subplot!(sf, 1, 2)
        PlotlySupply.plot_contour!(sf, 1:5, 1:5, rand(5, 5))
        @test length(sf.plot.data) >= 2
    end

    @testset "SubplotFigure quiver delegation" begin
        sf = PlotlySupply.subplots(1, 1; sync=false)
        PlotlySupply.plot_quiver!(sf, collect(1.0:5.0), collect(1.0:5.0), rand(5), rand(5))
        @test length(sf.plot.data) >= 1
    end

    @testset "SubplotFigure 3D delegations" begin
        scene_specs = Union{Missing, Spec}[Spec(kind="scene") Spec(kind="scene"); Spec(kind="scene") Spec(kind="scene")]
        sf = PlotlySupply.subplots(2, 2; sync=false, specs=scene_specs)

        # surface!(sf, X, Y, Z)
        X = [Float64(i) for i in 1:3, j in 1:3]
        Y = [Float64(j) for i in 1:3, j in 1:3]
        PlotlySupply.subplot!(sf, 1, 1)
        PlotlySupply.plot_surface!(sf, X, Y, rand(3, 3))
        @test length(sf.plot.data) >= 1

        # surface!(sf, Z)
        PlotlySupply.subplot!(sf, 1, 2)
        PlotlySupply.plot_surface!(sf, rand(3, 3))
        @test length(sf.plot.data) >= 2

        # scatter3d!(sf, x, y, z)
        PlotlySupply.subplot!(sf, 2, 1)
        PlotlySupply.plot_scatter3d!(sf, collect(1.0:3.0), collect(1.0:3.0), rand(3))
        @test length(sf.plot.data) >= 3

        # quiver3d!(sf, x, y, z, u, v, w)
        PlotlySupply.subplot!(sf, 2, 2)
        PlotlySupply.plot_quiver3d!(sf, collect(1.0:3.0), collect(1.0:3.0), collect(1.0:3.0), rand(3), rand(3), rand(3))
        @test length(sf.plot.data) >= 4
    end

    @testset "SubplotFigure polar delegation" begin
        polar_specs = Union{Missing, Spec}[Spec(kind="polar");;]
        sf = PlotlySupply.subplots(1, 1; sync=false, specs=polar_specs)

        PlotlySupply.plot_scatterpolar!(sf, collect(0.0:30.0:330.0), rand(12))
        @test length(sf.plot.data) >= 1
    end

    @testset "SubplotFigure set_legend! non-per-subplot path" begin
        sf = PlotlySupply.subplots(1, 2; sync=false, per_subplot_legends=false)
        PlotlySupply.plot_scatter!(sf, 1:5, rand(5); legend="A")
        PlotlySupply.subplot!(sf, 1, 2)
        PlotlySupply.plot_scatter!(sf, 1:5, rand(5); legend="B")
        # This should call the non-per-subplot branch (set_legend! on sf.fig)
        ret = set_legend!(sf; position=:bottomleft)
        @test ret === sf
        # Check the underlying fig layout has the legend positioned
        @test sf.plot.layout.fields[:legend][:xanchor] == "left"
        @test sf.plot.layout.fields[:legend][:yanchor] == "bottom"
    end

    @testset "_first_or_empty edge case" begin
        @test PlotlySupply._first_or_empty(String[]) == ""
        @test PlotlySupply._first_or_empty(["hello", "world"]) == "hello"
        @test PlotlySupply._first_or_empty("test") == "test"
    end

    # ─────────────────────────────────────────────────────────────────
    # Regression tests for the CRC (correct/robust/complete) bug-fix pass
    # ─────────────────────────────────────────────────────────────────

    @testset "CRC: helpers _scalar_or_first / _safe_tick0" begin
        @test PlotlySupply._scalar_or_first(5, 0) == 5
        @test PlotlySupply._scalar_or_first([7, 8], 0) == 7
        @test PlotlySupply._scalar_or_first(Int[], 0) == 0
        @test PlotlySupply._safe_tick0([3, 1, 2]) == 1.0
        @test PlotlySupply._safe_tick0([[3.0, 4.0], [1.0, 2.0]]) == 1.0   # nested
        @test PlotlySupply._safe_tick0(Float64[]) === nothing            # empty
        @test PlotlySupply._safe_tick0([NaN, Inf]) === nothing           # non-finite
    end

    @testset "CRC: scatter mode is valid 'lines' (never 'line')" begin
        f = plot_scatter(1:10, [sin.(1:10), cos.(1:10)]; mode=["markers"])
        @test f.data[1].fields[:mode] == "markers"
        @test f.data[2].fields[:mode] == "lines"          # trailing default, not "line"
        fp = plot_scatterpolar([[0,90,180],[0,90,180]], [[1,2,3],[3,2,1]]; mode=["markers"])
        @test fp.data[2].fields[:mode] == "lines"
    end

    @testset "CRC: multi-series tick0 is scalar, not a Vector" begin
        f = plot_scatter(1:10, [sin.(1:10), cos.(1:10)])
        @test get(f.layout.yaxis, :tick0, 0.0) isa Real
        @test get(f.layout.xaxis, :tick0, 0.0) isa Real
    end

    @testset "CRC: single-trace Vector kwargs are scalarized" begin
        f = plot_scatter([1.0, 2, 3]; mode=["markers"], color=["red"], dash=["dot"], legend=["foo"])
        tr = f.data[1].fields
        @test tr[:mode] == "markers"
        @test tr[:name] == "foo"
        @test tr[:line][:color] == "red"
        @test tr[:line][:dash] == "dot"
    end

    @testset "CRC: empty input does not crash" begin
        @test plot_scatter(Float64[]) isa Plot
        @test plot_stem(Float64[]) isa Plot
    end

    @testset "CRC: stem honors color (marker + stem lines)" begin
        f = plot_stem([0, 1, 2], [3.0, 4.0, 5.0]; color="red")
        @test f.data[1].fields[:marker][:color] == "red"        # head marker colored
        @test !haskey(f.data[1].fields, :line)                  # no unused line on markers trace
        @test f.data[2].fields[:line][:color] == "red"          # stem line colored
        # default (no color) keeps black stems
        g = plot_stem([0, 1], [1.0, 2.0])
        @test g.data[2].fields[:line][:color] == "black"
    end

    @testset "CRC: scatterpolar has no default sector (full circle)" begin
        f = plot_scatterpolar([0, 90, 180], [1, 2, 3])
        @test !haskey(f.layout.fields, :polar)
        f2 = plot_scatterpolar([0, 90, 180], [1, 2, 3]; trange=[0, 180])
        @test haskey(f2.layout.fields, :polar)
        # mutating variant: no data-extent sector, polar grid (not cartesian)
        g = plot_scatterpolar([0, 90, 180], [1, 2, 3])
        plot_scatterpolar!(g, [0, 90, 180], [3, 2, 1]; grid=false)
        @test !haskey(g.layout.fields, :xaxis)   # grid=false must not touch cartesian axes
        sect = haskey(g.layout.fields, :polar) ?
            get(PlotlySupply._symbol_dict(g.layout.fields[:polar]), :sector, nothing) : nothing
        @test sect === nothing                     # no auto-clip to data extent
    end

    @testset "CRC: box/violin points=true normalized; group mode" begin
        b = plot_box([1, 2], [[1.0, 2, 3], [4.0, 5, 6]]; points=true)
        @test b.data[1].fields[:boxpoints] == "all"
        @test b.layout.fields[:boxmode] == "group"
        v = plot_violin([1, 2], [[1.0, 2, 3], [4.0, 5, 6]]; points=true)
        @test v.data[1].fields[:points] == "all"
        @test v.layout.fields[:violinmode] == "group"
    end

    @testset "CRC: heatmap/contour omit empty colorscale, keep given one" begin
        @test !haskey(plot_heatmap(rand(3, 3)).data[1].fields, :colorscale)
        @test plot_heatmap(rand(3, 3); colorscale="Viridis").data[1].fields[:colorscale] == "Viridis"
        @test !haskey(plot_contour(rand(3, 3)).data[1].fields, :colorscale)
        # mutating variants too
        h = plot_heatmap(rand(3, 3)); plot_heatmap!(h, rand(3, 3))
        @test !haskey(h.data[2].fields, :colorscale)
    end

    @testset "CRC: dead dx/dy removed; no stray scene in 2-D layouts" begin
        @test !haskey(plot_heatmap(rand(3, 3)).layout.fields, :scene)
        @test !haskey(plot_contour(rand(3, 3)).layout.fields, :scene)
    end

    @testset "CRC: 3-D ranges target scene axes (not top-level)" begin
        for f in (plot_surface(rand(4, 4); xrange=[0, 3], yrange=[1, 2], zrange=[-1, 1]),
                  plot_scatter3d(1:3, 1:3, 1:3; zrange=[-1, 1]),
                  plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; zrange=[-1, 1]))
            @test !haskey(f.layout.fields, :yaxis)   # no stray top-level cartesian axis
            sc = PlotlySupply._symbol_dict(f.layout.fields[:scene])
            zr = PlotlySupply._symbol_dict(sc[:zaxis])
            @test get(zr, :range, nothing) == [-1, 1]
        end
        f = plot_surface(rand(4, 4); xrange=[0, 3], yrange=[1, 2])
        sc = PlotlySupply._symbol_dict(f.layout.fields[:scene])
        @test PlotlySupply._symbol_dict(sc[:xaxis])[:range] == [0, 3]
        @test PlotlySupply._symbol_dict(sc[:yaxis])[:range] == [1, 2]
    end

    @testset "CRC: scatter3d broadcasts shared 1-D x/y over z-series" begin
        f = plot_scatter3d(1:3, 1:3, [[1.0, 2, 3], [4.0, 5, 6]]; legend=["a", "b"])
        @test length(f.data) == 2
        @test collect(f.data[2].fields[:x]) == [1, 2, 3]
        @test collect(f.data[2].fields[:z]) == [4.0, 5.0, 6.0]
        # mutating variant
        g = plot_scatter3d(1:3, 1:3, 1:3)
        plot_scatter3d!(g, 1:3, 1:3, [[7.0, 8, 9]])
        @test length(g.data) == 2
    end

    @testset "CRC: quiver3d accepts vector color uniformly" begin
        q = plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]; color=["red"])
        @test q.data[1].fields[:colorscale] == [[0, "red"], [1, "red"]]
        @test q.data[1].fields[:showscale] == false
        @test !haskey(plot_quiver3d([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]).data[1].fields, :colorscale)
    end

    @testset "CRC: quiver geometry and robustness" begin
        @test_throws ArgumentError plot_quiver([1.0], [1.0], [1.0, 2.0], [1.0])
        @test_throws ArgumentError plot_quiver!(plot_scatter(1:2, 1:2), [1.0], [1.0], [1.0, 2.0], [1.0])

        q = plot_quiver([10.0], [20.0], [3.0], [0.0])
        xs = q.data[1].fields[:x]
        ys = q.data[1].fields[:y]
        @test length(xs) == length(ys) == 7
        @test xs[1:2] ≈ [10.0, 10.0 + 2 / 3]
        @test ys[1:2] ≈ [20.0, 20.0]
        @test isnan(xs[3]) && isnan(ys[3])
        @test xs[4] < xs[2] && xs[6] < xs[2]
        @test ys[4] < ys[2] < ys[6]
        @test q.data[1].fields[:mode] == "lines"
        @test !haskey(q.data[1].fields, :fill)

        empty_q = plot_quiver(Float64[], Float64[], Float64[], Float64[])
        @test isempty(empty_q.data[1].fields[:x])
        @test isempty(empty_q.data[1].fields[:y])

        mixed = @test_logs (:warn, r"skipped 1") plot_quiver(
            [0.0, 10.0],
            [0.0, 10.0],
            [2.0, NaN],
            [0.0, 0.0],
        )
        @test length(mixed.data[1].fields[:x]) == 7
        @test mixed.data[1].fields[:x][1:2] ≈ [0.0, 2 / 3]

        zero_q = @test_logs (:warn, r"zero magnitude") plot_quiver(
            [0.0, 1.0],
            [0.0, 1.0],
            [0.0, 0.0],
            [0.0, 0.0],
        )
        @test isempty(zero_q.data[1].fields[:x])

        mixed_zero = plot_quiver(
            [0.0, 10.0],
            [0.0, 20.0],
            [0.0, 2.0],
            [0.0, 0.0],
        )
        @test length(mixed_zero.data[1].fields[:x]) == 7
        @test mixed_zero.data[1].fields[:x][1] == 10.0
        @test mixed_zero.data[1].fields[:y][1] == 20.0

        scaled = plot_quiver(
            [0.0, 0.0],
            [0.0, 1.0],
            [2.0, 1.0],
            [0.0, 0.0],
        )
        @test scaled.data[1].fields[:x][2] ≈ 2 / 3
        @test scaled.data[1].fields[:x][9] ≈ 1 / 3

        for (u, v) in (
            ([1e308], [1e308]),
            ([floatmax(Float64)], [floatmax(Float64)]),
            ([nextfloat(0.0)], [nextfloat(0.0)]),
            ([typemin(Int)], [typemin(Int)]),
        )
            extreme = plot_quiver([0.0], [0.0], u, v)
            xv = extreme.data[1].fields[:x]
            yv = extreme.data[1].fields[:y]
            @test all(z -> isnan(z) || isfinite(z), xv)
            @test all(z -> isnan(z) || isfinite(z), yv)
            @test hypot(xv[2] - xv[1], yv[2] - yv[1]) ≈ 2 / 3 rtol=2e-15
        end

        @test_throws ArgumentError plot_quiver(
            [0.0], [0.0], [1.0], [0.0]; sizeref=-1,
        )
        @test_throws ArgumentError plot_quiver(
            [0.0], [0.0], [1.0], [0.0]; sizeref=NaN,
        )
        @test_throws ArgumentError plot_quiver(
            [0.0], [0.0], Any["bad"], [0.0],
        )

        base = plot_scatter(1:2, 1:2)
        initial_count = length(base.data)
        @test_throws ArgumentError plot_quiver!(
            base,
            [0.0],
            [0.0],
            [1.0],
            [0.0];
            sizeref=-1,
        )
        @test length(base.data) == initial_count
        @test_throws ArgumentError plot_quiver!(
            base,
            [floatmax(Float64)],
            [0.0],
            [1.0],
            [0.0];
            sizeref=floatmax(Float64),
        )
        @test length(base.data) == initial_count
    end

    @testset "CRC: mutating constructors preserve a user template" begin
        f = plot_scatter(1:5, rand(5)); set_template!(f, "plotly_dark")
        plot_scatter!(f, 1:5, rand(5))
        @test f.layout.fields[:template] == :plotly_dark
        g = plot_bar(1:3, rand(3)); set_template!(g, "seaborn"); plot_bar!(g, 1:3, rand(3))
        @test g.layout.fields[:template] == :seaborn
        h = plot_heatmap(rand(3, 3)); set_template!(h, "plotly_dark"); plot_heatmap!(h, rand(3, 3))
        @test h.layout.fields[:template] == :plotly_dark
    end

    @testset "CRC: _apply_showlegend! tolerates over-long vector" begin
        @test plot_bar([1, 2, 3]; showlegend=[true, false, true, false]) isa Plot
        b = plot_box([1.0, 2, 3]; showlegend=[true])   # vector for single trace
        @test b.data[1].fields[:showlegend] == true
    end

    @testset "CRC: legend block gating + forced visibility" begin
        f = plot_scatter(1:5, rand(5))                    # unnamed single trace
        @test !haskey(f.layout.fields, :legend)
        @test plot_scatter(1:5, rand(5); legend="a").layout.fields[:legend][:xanchor] == "right"
        set_legend!(f; position=:topright, showlegend=true)
        @test f.layout.fields[:showlegend] == true
        @test haskey(f.layout.fields, :legend)
    end

    @testset "CRC: normalize warns on invalid template / legend position" begin
        @test (@test_logs (:warn,) PlotlySupply._normalize_template("does_not_exist")) == :plotly_white
        @test (@test_logs (:warn,) PlotlySupply._normalize_legend_position("nowhere")) == :topright
    end

    @testset "CRC: _json_js escapes all close-tag sequences" begin
        @test !occursin("</", PlotlySupply._json_js("</SCRIPT>"))
        @test occursin("<\\/", PlotlySupply._json_js("</SCRIPT>"))
        @test !occursin("</", PlotlySupply._json_js(Dict(:k => "a</Style>b")))
    end

    @testset "CRC: _file_uri encodes spaces" begin
        @test PlotlySupply._file_uri("/tmp/a b.html") == "file:///tmp/a%20b.html"
    end

    @testset "CRC: _urldecode_bytes preserves UTF-8" begin
        @test String(PlotlySupply._urldecode_bytes("%E4%B8%AD%E6%96%87")) == "中文"
        @test String(PlotlySupply._urldecode_bytes("a%2Fb")) == "a/b"
        @test String(PlotlySupply._urldecode_bytes("a%20b%2Fc")) == "a b/c"
        @test String(PlotlySupply._urldecode_bytes("100%")) == "100%"
        @test String(PlotlySupply._urldecode_bytes("%A")) == "%A"
        @test_throws ArgumentError PlotlySupply._urldecode_bytes("%GG")
    end

    @testset "CRC: image export validates and streams data URLs" begin
        p = plot_scatter(1:2, 1:2)

        function export_data_url(data_url, format)
            io = IOBuffer()
            ec = (run = (win, js) -> data_url,)
            PlotlySupply._export_image(io, ec, nothing, "test-export", p, format)
            return take!(io)
        end

        raster_bytes = UInt8[0x00, 0x01, 0x7f, 0x80, 0xff]
        raster_payload = base64encode(raster_bytes)
        @test export_data_url("data:image/png;base64,$raster_payload", "png") == raster_bytes
        @test export_data_url("data:image/jpeg;base64,$raster_payload", "jpeg") == raster_bytes

        svg = "<svg><text>α中文</text></svg>"
        svg_url = "data:image/svg+xml,%3Csvg%3E%3Ctext%3E%CE%B1%E4%B8%AD%E6%96%87%3C%2Ftext%3E%3C%2Fsvg%3E"
        @test String(export_data_url(svg_url, "svg")) == svg
        @test export_data_url(
            "data:image/svg+xml;base64,$(base64encode(codeunits(svg)))",
            "svg",
        ) == collect(codeunits(svg))

        for n in (0, 1, 2, 3, 65_535, 65_536, 65_537)
            bytes = [UInt8(i % 251) for i in 0:(n - 1)]
            io = IOBuffer()
            PlotlySupply._write_base64_payload!(io, base64encode(bytes))
            @test take!(io) == bytes
        end

        malformed = (
            "A",
            "AA=A",
            "A===",
            "AA!A",
            "AAAA\n",
        )
        for payload in malformed
            io = IOBuffer()
            @test_throws ArgumentError PlotlySupply._write_base64_payload!(io, payload)
            @test isempty(take!(io))
        end

        late_invalid = collect(codeunits(base64encode(fill(UInt8(0x5a), 2 * 65_536))))
        late_invalid[end - 4] = UInt8('!')
        io = IOBuffer()
        @test_throws ArgumentError PlotlySupply._write_base64_payload!(
            io,
            String(late_invalid),
        )
        @test isempty(take!(io))

        for (url, format) in (
            ("not-a-data-url", "svg"),
            ("data:image/png;base64,$raster_payload", "svg"),
            ("data:image/jpeg;base64,$raster_payload", "png"),
            ("data:text/plain;base64,$raster_payload", "png"),
        )
            io = IOBuffer()
            ec = (run = (win, js) -> url,)
            @test_throws ErrorException PlotlySupply._export_image(
                io,
                ec,
                nothing,
                "test-export",
                p,
                format,
            )
            @test isempty(take!(io))
        end

        io = IOBuffer()
        ec = (run = (win, js) -> 42,)
        err = try
            PlotlySupply._export_image(io, ec, nothing, "test-export", p, "png")
            nothing
        catch caught
            caught
        end
        @test err isa ErrorException
        @test occursin("non-string", sprint(showerror, err))
        @test isempty(take!(io))
    end

    @testset "CRC: savefig validates before opening destinations" begin
        p = plot_scatter(1:2, 1:2)
        @test_throws ErrorException savefig(IOBuffer(), p; format="unsupported")

        mktempdir() do dir
            filename = joinpath(dir, "existing.unsupported")
            write(filename, "sentinel")
            @test_throws ErrorException savefig(filename, p; format="unsupported")
            @test read(filename, String) == "sentinel"
        end
    end

    @testset "CRC: mgrid is type-stable and value-correct" begin
        g = mgrid(1:3, 1:2)
        @test eltype(g[1]) == Int && eltype(g[2]) == Int
        @test g[1] == [1 1; 2 2; 3 3]
        @test g[2] == [1 2; 1 2; 1 2]
        @test eltype(mgrid(1.0:3.0, 1.0:2.0)[1]) == Float64
    end

    @testset "CRC: meshgrid is reexported" begin
        Y, X = meshgrid(1:2, 1:3)
        @test size(X) == (3, 2)
    end

    @testset "CRC: json is a working reexport" begin
        @test isdefined(PlotlySupply, :json)
        p = plot_scatter(1:2, [3.0, NaN])
        @test json(p; allownan=true) == PlotlyBase.JSON.json(p; allownan=true)
        io = IOBuffer()
        @test json(io, Dict("answer" => 42)) === nothing
        @test String(take!(io)) == "{\"answer\":42}"
    end

    @testset "CRC: Plot methods are additive and dispatchable" begin
        p = plot_scatter(1:3, 1:3)
        @test p isa PlotlySupply._RefreshablePlot
        @test which(restyle!, (typeof(p), Dict{Symbol, Any})).module === PlotlySupply
        @test which(update_xaxes!, (typeof(p),)).module === PlotlySupply
        @test which(
            update_xaxes!,
            (typeof(p), typeof(attr())),
        ).module === PlotlySupply

        @test update_xaxes!(p; showgrid=false) === p
        @test p.layout.fields[:xaxis][:showgrid] == false
        @test update_xaxes!(p, attr(zeroline=false)) === p
        @test p.layout.fields[:xaxis][:zeroline] == false

        ambiguities = Test.detect_ambiguities(
            PlotlyBase,
            PlotlySupply;
            recursive=false,
        )
        relevant = filter(ambiguities) do pair
            any(method -> method.module === PlotlySupply, pair)
        end
        @test isempty(relevant)

        project_file = something(
            Base.active_project(),
            normpath(joinpath(@__DIR__, "..", "Project.toml")),
        )
        output = IOBuffer()
        command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=no --warn-overwrite=yes --project=$(dirname(project_file)) -e $("using PlotlySupply")`
        process = run(pipeline(ignorestatus(command), stdout=output, stderr=output))
        diagnostics = String(take!(output))
        @test success(process)
        @test !occursin("overwritten in module PlotlySupply", diagnostics)
    end

    @testset "CRC: savefig json/html work headlessly" begin
        f = plot_scatter(1:5, rand(5); title="α中文")
        io = IOBuffer(); savefig(io, f; format="json"); js = String(take!(io))
        @test occursin("scatter", js)
        io2 = IOBuffer(); savefig(io2, f; format="html"); html = String(take!(io2))
        @test occursin("Plotly", html)
        bytes = savefig(f; format="json")
        @test bytes isa Vector{UInt8} && !isempty(bytes)
    end

    @testset "CRC: SubplotFigure delegations + secondary-y" begin
        sf = PlotlySupply.subplots(1, 1; sync=false, show=false)
        @test relayout!(sf; title="t") === sf
        @test sf.plot.layout.fields[:title] == "t"
        @test update_xaxes!(sf; showgrid=false) === sf
        io = IOBuffer(); savefig(io, sf; format="json")
        @test !isempty(take!(io))
        # secondary-y label targets yaxis2
        sf2 = PlotlySupply.subplots(1, 1; sync=false, show=false,
            specs=fill(PlotlySupply.Spec(secondary_y=true), 1, 1))
        plot_scatter!(sf2, 1:3, [1.0, 2, 3])
        plot_scatter!(sf2, 1:3, [10.0, 20, 30]; secondary_y=true)
        ylabel!(sf2, "secondary"; secondary_y=true)
        @test haskey(sf2.plot.layout.fields, :yaxis2)
    end

    @testset "CRC: extended mutators route to heterogeneous subplots" begin
        specs = [
            PlotlySupply.Spec(kind="domain") PlotlySupply.Spec(kind="xy") PlotlySupply.Spec(kind="scene")
            PlotlySupply.Spec(kind="geo") PlotlySupply.Spec(kind="ternary") PlotlySupply.Spec(kind="mapbox")
        ]
        sf = PlotlySupply.subplots(
            2,
            3;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=specs,
        )
        scene_domain = deepcopy(sf.layout.fields[:scene][:domain])

        calls = (
            () -> plot_pie!(sf, [3, 2]; row=1, col=1),
            () -> plot_sunburst!(sf, ["root", "leaf"], ["", "root"]; row=1, col=1),
            () -> plot_treemap!(sf, ["root", "leaf"], ["", "root"]; row=1, col=1),
            () -> plot_funnelarea!(sf, [3, 2]; row=1, col=1),
            () -> plot_indicator!(sf, 42; row=1, col=1),
            () -> plot_sankey!(sf, [0], [1], [2.0]; row=1, col=1),
            () -> plot_parcoords!(sf, ["a" => [1, 2], "b" => [3, 4]]; row=1, col=1),
            () -> plot_funnel!(sf, [3, 2], ["a", "b"]; row=1, col=2),
            () -> plot_waterfall!(sf, ["a", "b"], [1.0, -0.5]; row=1, col=2),
            () -> plot_area!(sf, [1.0, 2.0]; row=1, col=2),
            () -> plot_area!(sf, 1:2, [2.0, 3.0]; row=1, col=2),
            () -> plot_candlestick!(
                sf,
                1:2,
                [1.0, 2.0],
                [2.0, 3.0],
                [0.5, 1.5],
                [1.5, 2.5];
                row=1,
                col=2,
            ),
            () -> plot_ohlc!(
                sf,
                1:2,
                [1.0, 2.0],
                [2.0, 3.0],
                [0.5, 1.5],
                [1.5, 2.5];
                row=1,
                col=2,
            ),
            () -> plot_histogram2d!(sf, [1.0, 2.0], [2.0, 3.0]; row=1, col=2),
            () -> plot_image!(sf, reshape(UInt8.(0:11), 2, 2, 3); row=1, col=2),
            () -> plot_mesh3d!(
                sf,
                [0.0, 1.0, 0.0],
                [0.0, 0.0, 1.0],
                [0.0, 0.0, 0.0];
                row=1,
                col=3,
                perspective=false,
            ),
            () -> plot_isosurface!(
                sf,
                [0.0, 1.0],
                [0.0, 1.0],
                [0.0, 1.0],
                [1.0, 2.0];
                row=1,
                col=3,
            ),
            () -> plot_volume!(
                sf,
                [0.0, 1.0],
                [0.0, 1.0],
                [0.0, 1.0],
                [1.0, 2.0];
                row=1,
                col=3,
            ),
            () -> plot_streamtube!(
                sf,
                [0.0, 1.0],
                [0.0, 1.0],
                [0.0, 1.0],
                [1.0, 1.0],
                [0.0, 0.0],
                [0.0, 0.0];
                row=1,
                col=3,
            ),
            () -> plot_choropleth!(sf, ["CAN", "USA"], [1.0, 2.0]; row=2, col=1),
            () -> plot_scattergeo!(sf, [0.0, 1.0], [2.0, 3.0]; row=2, col=1),
            () -> plot_ternary!(
                sf,
                [0.2, 0.3],
                [0.3, 0.3],
                [0.5, 0.4];
                row=2,
                col=2,
            ),
            () -> plot_scattermapbox!(sf, [0.0, 1.0], [2.0, 3.0]; row=2, col=3),
            () -> plot_densitymapbox!(
                sf,
                [0.0, 1.0],
                [2.0, 3.0],
                [1.0, 2.0];
                row=2,
                col=3,
            ),
        )

        for call in calls
            old_length = length(sf.data)
            @test call() === sf
            @test length(sf.data) == old_length + 1
        end
        @test length(sf.data) == 24
        @test (sf.current_row, sf.current_col) == (2, 3)

        for trace in sf.data
            kind = PlotlyBase.get_subplotkind_from_trace_type(Symbol(trace.fields[:type]))
            if kind == "domain"
                @test haskey(trace.fields, :domain)
            elseif kind == "xy"
                @test haskey(trace.fields, :xaxis)
                @test haskey(trace.fields, :yaxis)
            elseif kind == "scene"
                @test trace.fields[:scene] == "scene"
            elseif kind == "geo"
                @test trace.fields[:geo] == "geo"
            else
                @test trace.fields[:subplot] == kind
            end
        end
        @test sf.layout.fields[:scene][:camera][:projection][:type] == "orthographic"
        @test sf.layout.fields[:scene][:domain] == scene_domain
    end

    @testset "CRC: subplot routing rejects incompatible traces atomically" begin
        sf = PlotlySupply.subplots(
            1,
            2;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=[
                PlotlySupply.Spec(kind="domain") PlotlySupply.Spec(kind="xy")
            ],
        )
        before = json(sf.plot)

        @test_throws ArgumentError plot_scatter!(sf, 1:2, [1.0, 2.0]; row=1, col=1)
        @test json(sf.plot) == before
        @test_throws ArgumentError plot_pie!(sf, [1.0, 2.0]; row=1, col=2)
        @test json(sf.plot) == before
        @test_throws ArgumentError plot_pie!(
            sf,
            [1.0, 2.0];
            row=1,
            col=1,
            secondary_y=true,
        )
        @test json(sf.plot) == before

        @test_throws ArgumentError PlotlyBase.add_trace!(
            sf,
            pie(values=[1.0, 2.0]);
            row=1,
            col=2,
        )
        @test json(sf.plot) == before
        @test_throws ArgumentError PlotlyBase.addtraces!(
            sf,
            scatter(x=1:2, y=[1.0, 2.0]),
            pie(values=[1.0, 2.0]);
            row=1,
            col=2,
        )
        @test json(sf.plot) == before

        sf_empty = PlotlySupply.subplots(
            1,
            2;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=[missing PlotlySupply.Spec()],
        )
        @test_throws ArgumentError plot_scatter!(
            sf_empty,
            1:2,
            [1.0, 2.0];
            row=1,
            col=1,
        )
        @test isempty(sf_empty.data)
    end

    @testset "CRC: domain and geo traces receive per-subplot legends" begin
        sf = PlotlySupply.subplots(
            1,
            2;
            sync=false,
            show=false,
            specs=[
                PlotlySupply.Spec(kind="domain") PlotlySupply.Spec(kind="geo")
            ],
        )
        PlotlyBase.add_trace!(
            sf,
            pie(values=[2.0, 1.0], name="domain");
            row=1,
            col=1,
        )
        PlotlyBase.add_trace!(
            sf,
            scattergeo(lon=[0.0], lat=[0.0], name="geo");
            row=1,
            col=2,
        )
        @test sf.data[1].fields[:legend] == "legend"
        @test sf.data[2].fields[:legend] == "legend2"
        @test sf.data[1].fields[:showlegend] == true
        @test sf.data[2].fields[:showlegend] == true
        @test haskey(sf.layout.fields, :legend)
        @test haskey(sf.layout.fields, :legend2)
    end

    # ─────────────────────────────────────────────────────────────────
    # Extended chart types (v1.8.0 additions)
    # ─────────────────────────────────────────────────────────────────

    ttype(f) = f.data[1].fields[:type]

    @testset "Extended: pie / funnelarea" begin
        f = plot_pie([3, 2, 1]; labels=["a", "b", "c"], hole=0.3, colors=["red", "green", "blue"])
        @test ttype(f) == "pie"
        @test f.data[1].fields[:hole] == 0.3
        @test f.data[1].fields[:marker][:colors] == ["red", "green", "blue"]
        @test plot_funnelarea([5, 3, 1]; labels=["x", "y", "z"]).data[1].fields[:type] == "funnelarea"
        g = plot_pie([1, 2]); plot_pie!(g, [3, 4]); @test length(g.data) == 2
    end

    @testset "Extended: sunburst / treemap" begin
        @test ttype(plot_sunburst(["a", "b", "c"], ["", "a", "a"]; values=[10, 3, 2])) == "sunburst"
        @test ttype(plot_treemap(["a", "b"], ["", ""]; values=[1, 2])) == "treemap"
        @test_throws ArgumentError plot_sunburst(["a", "b"], [""])   # length mismatch
        g = plot_sunburst(["a"], [""]); plot_sunburst!(g, ["b"], [""]); @test length(g.data) == 2
    end

    @testset "Extended: funnel / waterfall" begin
        @test ttype(plot_funnel([100, 60, 30], ["A", "B", "C"])) == "funnel"
        w = plot_waterfall(["a", "b", "c"], [10, -3, 5]; measure=["absolute", "relative", "total"])
        @test ttype(w) == "waterfall"
        @test w.data[1].fields[:measure] == ["absolute", "relative", "total"]
        @test_throws ArgumentError plot_waterfall(["a", "b"], [1, 2]; measure=["total"])
    end

    @testset "Extended: indicator" begin
        f = plot_indicator(72; reference=50, gauge_range=[0, 100])
        @test ttype(f) == "indicator"
        @test occursin("gauge", f.data[1].fields[:mode])
        @test f.data[1].fields[:delta][:reference] == 50
        @test f.data[1].fields[:gauge][:axis][:range] == [0, 100]
    end

    @testset "Extended: area" begin
        @test plot_area(1:5, rand(5)).data[1].fields[:fill] == "tozeroy"
        s = plot_area(1:5, [rand(5), rand(5)]; stack=true)
        @test length(s.data) == 2 && s.data[1].fields[:stackgroup] == "one"
        @test plot_area(rand(5)) isa Plot   # y-only form
    end

    @testset "Extended: candlestick / ohlc" begin
        @test ttype(plot_candlestick(1:3, [1, 2, 3], [2, 3, 4], [0, 1, 2], [1.5, 2.5, 3.5])) == "candlestick"
        @test ttype(plot_ohlc(1:3, [1, 2, 3], [2, 3, 4], [0, 1, 2], [1.5, 2.5, 3.5])) == "ohlc"
        @test_throws ArgumentError plot_candlestick(1:3, [1, 2], [2, 3, 4], [0, 1, 2], [1.5, 2.5, 3.5])
    end

    @testset "Extended: histogram2d" begin
        f = plot_histogram2d(randn(50), randn(50); nbinsx=10, colorscale="Viridis")
        @test ttype(f) == "histogram2d"
        @test f.data[1].fields[:colorscale] == "Viridis"
    end

    @testset "Extended: error bars" begin
        f = plot_scatter(1:5, rand(5); error_y=fill(0.1, 5))
        @test f.data[1].fields[:error_y][:array] == fill(0.1, 5)
        @test f.data[1].fields[:error_y][:visible] == true
        # nested per-series
        m = plot_scatter(1:3, [[1, 2, 3], [4, 5, 6]]; error_y=[[0.1, 0.1, 0.1], [0.2, 0.2, 0.2]])
        @test m.data[2].fields[:error_y][:array] == [0.2, 0.2, 0.2]
        # bar error_x + only-new-trace on mutate
        b = plot_bar([3, 2, 4]; error_y=[0.2, 0.3, 0.1])
        @test haskey(b.data[1].fields, :error_y)
        g = plot_scatter(1:3, [1, 2, 3]); plot_scatter!(g, 1:3, [3, 2, 1]; error_y=[0.1, 0.1, 0.1])
        @test haskey(g.data[2].fields, :error_y) && !haskey(g.data[1].fields, :error_y)
    end

    @testset "Extended: bar orientation / barmode" begin
        h = plot_bar([3, 2, 4], ["a", "b", "c"]; orientation="h")
        @test h.data[1].fields[:orientation] == "h"
        @test plot_bar(["a", "b"], [[1, 2], [3, 4]]; barmode="stack").layout.fields[:barmode] == "stack"
    end

    @testset "Extended: annotate!" begin
        a = plot_scatter(1:5, rand(5))
        annotate!(a, 3, 0.5, "peak"; arrowhead=2)
        annotate!(a, 1, 0.1, "start"; showarrow=false)
        @test length(a.layout.fields[:annotations]) == 2
        @test a.layout.fields[:annotations][1][:text] == "peak"
        @test a.layout.fields[:annotations][2][:showarrow] == false
    end

    @testset "Extended: sankey" begin
        f = plot_sankey([0, 1], [1, 2], [5, 3]; label=["a", "b", "c"])
        @test ttype(f) == "sankey"
        @test f.data[1].fields[:link][:value] == [5, 3]
        @test_throws ArgumentError plot_sankey([0], [1, 2], [5])
    end

    @testset "Extended: parcoords / ternary" begin
        p = plot_parcoords(["A" => [1, 2, 3], "B" => [3, 2, 1]]; line_color=[1, 2, 3], colorscale="Viridis")
        @test ttype(p) == "parcoords"
        @test p.data[1].fields[:dimensions][1][:label] == "A"
        @test p.data[1].fields[:line][:colorscale] == "Viridis"
        t = plot_ternary([1, 2], [2, 1], [1, 1]; alabel="A", marker_size=8)
        @test ttype(t) == "scatterternary"
        @test t.layout.fields[:ternary][:aaxis][:title] == "A"
    end

    @testset "Extended: image" begin
        rgb_data = reshape(collect(0:11), 2, 2, 3)
        rgb = plot_image(rgb_data)
        @test ttype(rgb) == "image"
        @test rgb.data[1].fields[:z] isa PermutedDimsArray
        @test parent(rgb.data[1].fields[:z]) === rgb_data
        expected = [[[rgb_data[i, j, ch] for ch in axes(rgb_data, 3)]
            for j in axes(rgb_data, 2)] for i in axes(rgb_data, 1)]
        @test PlotlyBase.JSON.json(rgb.data[1].fields[:z]) ==
            PlotlyBase.JSON.json(expected)
        rgba_data = reshape(UInt8.(0:23), 2, 3, 4)
        rgba_expected = [[[rgba_data[i, j, ch] for ch in axes(rgba_data, 3)]
            for j in axes(rgba_data, 2)] for i in axes(rgba_data, 1)]
        @test PlotlyBase.JSON.json(PlotlySupply._image_z(rgba_data)) ==
            PlotlyBase.JSON.json(rgba_expected)
        @test ttype(plot_image([[[255, 0, 0], [0, 255, 0]]])) == "image"
        @test_throws ArgumentError plot_image(zeros(UInt8, 2, 2, 2))
        @test_throws ArgumentError plot_image!(rgb, zeros(UInt8, 2, 2, 2))
        @test length(rgb.data) == 1
    end

    @testset "Extended: 3D mesh / field / streamtube" begin
        @test ttype(plot_mesh3d([0, 1, 0], [0, 0, 1], [0, 0, 0]; i=[0], j=[1], k=[2], color="lightblue")) == "mesh3d"
        iso = plot_isosurface([0, 1, 0, 1], [0, 0, 1, 1], [0, 0, 0, 0], [1.0, 2, 3, 4]; surface_count=3, zrange=[-1, 1])
        @test ttype(iso) == "isosurface"
        @test iso.data[1].fields[:surface][:count] == 3
        sc = PlotlySupply._symbol_dict(iso.layout.fields[:scene])
        @test PlotlySupply._symbol_dict(sc[:zaxis])[:range] == [-1, 1]   # range on scene, not 2D axis
        @test !haskey(iso.layout.fields, :yaxis)
        @test plot_volume([0, 1], [0, 1], [0, 1], [1.0, 2]).data[1].fields[:opacity] == 0.1
        @test ttype(plot_streamtube([0, 1], [0, 0], [0, 0], [1, 1], [0, 0], [0, 0]; sizeref=0.5)) == "streamtube"
    end

    @testset "Extended: geo / mapbox" begin
        c = plot_choropleth(["USA", "CAN"], [1.0, 2.0]; colorscale="Blues", scope="north america")
        @test ttype(c) == "choropleth"
        @test PlotlySupply._symbol_dict(c.layout.fields[:geo])[:scope] == "north america"
        @test ttype(plot_scattergeo([-100.0, 0.0], [40.0, 0.0]; marker_size=8)) == "scattergeo"
        m = plot_scattermapbox([-122.4, -73.9], [37.8, 40.7]; zoom=2, center_lon=-100, center_lat=40)
        @test ttype(m) == "scattermapbox"
        @test PlotlySupply._symbol_dict(m.layout.fields[:mapbox])[:style] == "open-street-map"
        @test ttype(plot_densitymapbox([-122.4], [37.8], [1.0]; radius=20)) == "densitymapbox"
        @test_throws ArgumentError plot_scattergeo([0.0], [1.0, 2.0])
    end

    @testset "Extended: mutating preserves template" begin
        for (mk, add!) in (
            (() -> plot_pie([1, 2]), (g) -> plot_pie!(g, [3, 4])),
            (() -> plot_waterfall(["a"], [1]), (g) -> plot_waterfall!(g, ["b"], [2])),
            (() -> plot_mesh3d([0, 1, 0], [0, 0, 1], [0, 0, 0]; i=[0], j=[1], k=[2]),
                (g) -> plot_mesh3d!(g, [1, 2, 1], [1, 1, 2], [1, 1, 1]; i=[0], j=[1], k=[2])),
            (() -> plot_choropleth(["USA"], [1.0]), (g) -> plot_choropleth!(g, ["CAN"], [2.0])),
        )
            g = mk(); set_template!(g, "plotly_dark"); add!(g)
            @test g.layout.fields[:template] == :plotly_dark
            @test length(g.data) == 2
        end
    end

    @testset "CRC: atomic restyle/update/movetraces" begin
        snapshot_atomic = p -> PlotlyBase.JSON.json(
            Dict(:data => p.data, :layout => p.layout);
            allownan=true,
        )
        make_atomic_plot = () -> Plot(
            [
                scatter(
                    x=[1, 2],
                    y=[1, 2],
                    name="one",
                    marker=attr(size=2),
                ),
                scatter(x=[3, 4], y=[3, 4], name="two"),
                scatter(x=[5, 6], y=[5, 6], name="three"),
            ],
            Layout(title="old"),
        )

        p = make_atomic_plot()
        update_dict = Dict{Symbol,Any}(:name => ["a", "b"])
        update_before = deepcopy(update_dict)
        data_ref = p.data
        trace_ref = p.data[1]
        x_ref = p.data[1][:x]
        restyle!(p, [1, 2, 3], update_dict)
        @test update_dict == update_before
        @test [trace[:name] for trace in p.data] == ["a", "b", "a"]
        @test p.data === data_ref
        @test p.data[1] === trace_ref
        @test p.data[1][:x] === x_ref

        p = make_atomic_plot()
        before = snapshot_atomic(p)
        update_dict = Dict{Symbol,Any}(:name => ["changed"])
        update_before = deepcopy(update_dict)
        @test_throws BoundsError restyle!(p, [1, 4], update_dict)
        @test snapshot_atomic(p) == before
        @test update_dict == update_before

        p = make_atomic_plot()
        p.data[2][:marker] = 7
        before = snapshot_atomic(p)
        @test_throws MethodError restyle!(p, [1, 2]; marker_color="red")
        @test snapshot_atomic(p) == before

        p = make_atomic_plot()
        before = snapshot_atomic(p)
        layout_ref = p.layout
        update_dict = Dict{Symbol,Any}(:name => ["changed"])
        update_before = deepcopy(update_dict)
        @test_throws BoundsError update!(
            p,
            [1, 4],
            update_dict;
            layout=Layout(title="new"),
        )
        @test snapshot_atomic(p) == before
        @test p.layout === layout_ref
        @test update_dict == update_before

        p = make_atomic_plot()
        data_ref = p.data
        layout_ref = p.layout
        trace_ref = p.data[1]
        x_ref = p.data[1][:x]
        update!(
            p,
            [1, 2],
            Dict(:opacity => [0.2, 0.4]);
            layout=Layout(title="new"),
            marker_symbol=["circle", "square"],
        )
        @test p.data === data_ref
        @test p.layout === layout_ref
        @test p.data[1] === trace_ref
        @test p.data[1][:x] === x_ref
        @test p.layout[:title] == "new"
        @test [trace[:opacity] for trace in p.data[1:2]] == [0.2, 0.4]

        shared = scatter(name="old")
        p = Plot([shared, shared])
        restyle!(p, [1, 2], Dict(:name => ["first", "second"]))
        @test p.data[1] === shared
        @test p.data[2] === shared
        @test shared[:name] == "second"

        shared_nested = Dict{Symbol,Any}(:color => "red")
        trace = scatter()
        trace.fields[:marker] = shared_nested
        trace.fields[:line] = shared_nested
        p = Plot([trace])
        restyle!(p, 1; marker_size=5)
        @test p.data[1].fields[:marker] === p.data[1].fields[:line]
        @test p.data[1].fields[:line][:size] == 5

        p = make_atomic_plot()
        before = snapshot_atomic(p)
        data_ref = p.data
        @test_throws BoundsError movetraces!(p, [1, 9], [3, 1])
        @test snapshot_atomic(p) == before
        @test p.data === data_ref
        @test_throws DimensionMismatch movetraces!(p, [1, 2], [3])
        @test snapshot_atomic(p) == before
        movetraces!(p, [1, 3], [2, 1])
        @test [trace[:name] for trace in p.data] == ["three", "two", "one"]
        @test p.data === data_ref

        p = make_atomic_plot()
        data_ref = p.data
        movetraces!(p, 2)
        @test [trace[:name] for trace in p.data] == ["one", "three", "two"]
        @test p.data === data_ref
        before = snapshot_atomic(p)
        @test_throws BoundsError movetraces!(p, 9)
        @test snapshot_atomic(p) == before

        p = make_atomic_plot()
        restyle!(p, 1; x=[10, 20])
        @test p.data[1][:x] == 10
        p = make_atomic_plot()
        restyle!(p, [1]; x=[10, 20])
        @test p.data[1][:x] == 10

        p = make_atomic_plot()
        sp = SyncPlot(p, nothing, nothing, "atomic-test")
        before = snapshot_atomic(p)
        @test_throws BoundsError restyle!(
            sp,
            [1, 4],
            Dict(:name => ["x", "y"]),
        )
        @test snapshot_atomic(p) == before
        @test_throws BoundsError update!(
            sp,
            [1, 4],
            Dict(:name => ["x", "y"]);
            layout=Layout(title="new"),
        )
        @test snapshot_atomic(p) == before
        @test_throws BoundsError movetraces!(sp, [1, 9], [3, 1])
        @test snapshot_atomic(p) == before
    end

    @testset "CRC: bounded extend/prepend traces" begin
        p = Plot(scatter(x=[1, 2, 3], y=[10, 20, 30]))
        extendtraces!(p, Dict(:x => [[4, 5]], :y => [[40, 50]]), [1], 3)
        @test p.data[1][:x] == [3, 4, 5]
        @test p.data[1][:y] == [30, 40, 50]

        prependtraces!(p, Dict(:x => [[-1, 0]], :y => [[-10, 0]]), [1], 4)
        @test p.data[1][:x] == [-1, 0, 3, 4]
        @test p.data[1][:y] == [-10, 0, 30, 40]

        extendtraces!(p, Dict(:x => [[6]], :y => [[60]]), [1], 0)
        @test isempty(p.data[1][:x])
        @test isempty(p.data[1][:y])

        multi = Plot([
            scatter(x=[1, 2], y=[10, 20]),
            scatter(x=[3, 4], y=[30, 40]),
        ])
        limits = Dict(:x => [2, 3], :y => [1, 4])
        extendtraces!(
            multi,
            Dict(:x => [[5, 6], [7, 8]], :y => [[50, 60], [70, 80]]),
            [1, 2],
            limits,
        )
        @test multi.data[1][:x] == [5, 6]
        @test multi.data[1][:y] == [60]
        @test multi.data[2][:x] == [4, 7, 8]
        @test multi.data[2][:y] == [30, 40, 70, 80]

        unchanged = copy(multi.data[1][:x])
        @test_throws ArgumentError extendtraces!(
            multi,
            Dict(:x => [[9], [10]], :y => [[90]]),
            [1, 2],
            3,
        )
        @test multi.data[1][:x] == unchanged
        @test_throws ArgumentError prependtraces!(
            multi,
            Dict(:x => [[9], [10]]),
            [1, 2],
            Dict(:y => [2, 2]),
        )
    end

    @testset "CRC: plot frames reach desktop renderer" begin
        fr = frame(name="frame-sentinel", data=[scatter(y=[2, 3])])

        keyword_plot = plot(scatter(y=[1, 2]); frames=[fr])
        @test keyword_plot.frames == [fr]

        positional_plot = plot(scatter(y=[1, 2]), Layout(), [fr])
        @test positional_plot.frames == [fr]

        vector_plot = plot([scatter(y=[1, 2])], Layout(), [fr])
        @test vector_plot.frames == [fr]

        empty_plot = plot(; frames=[fr])
        @test empty_plot.frames == [fr]

        html = PlotlySupply._syncplot_html(positional_plot, "frame-test")
        @test occursin("frame-sentinel", html)
        @test occursin("Plotly.addFrames", html)
        @test occursin("Plotly.animate", html)

        no_autoplay = PlotlySupply._syncplot_html(
            positional_plot,
            "frame-test";
            autoplay=false,
        )
        @test occursin("Plotly.addFrames", no_autoplay)
        @test occursin("if (false)", no_autoplay)

        rebuild = PlotlySupply._plotlyjs_newplot_script(
            positional_plot,
            "frame-test";
            purge=true,
        )
        @test occursin("Plotly.purge", rebuild)
        @test occursin("frame-sentinel", rebuild)
    end

    @testset "SyncPlot lifecycle ownership" begin
        @testset "constructor failure rolls back its temp directory" begin
            mktempdir() do temp_root
                ec = _LifecycleFakeElectron(; fail_window=true)
                plot = Plot(scatter(y=[1, 2, 3]))
                withenv("TMPDIR" => temp_root) do
                    @test_throws ErrorException PlotlySupply._create_syncplot_window(
                        ec,
                        plot;
                        app=:fake,
                        show=false,
                    )
                end
                @test isempty(readdir(temp_root))
                @test isempty(ec.windows)
            end
        end

        @testset "explicit close is synchronous and idempotent" begin
            ec = _LifecycleFakeElectron()
            plot = Plot(scatter(y=[1, 2, 3]))
            sp = PlotlySupply._create_syncplot_window(
                ec,
                plot;
                app=:fake,
                show=false,
            )
            tempdir = getfield(sp, :_resources).tempdir
            window = only(ec.windows)
            old, registered = PlotlySupply._register_displayed_syncplot!(plot, sp)

            @test registered
            @test old === nothing
            @test _lifecycle_is_registered(plot, sp)
            @test isfile(joinpath(tempdir, "index.html"))
            @test isopen(sp)
            @test :_resources ∉ propertynames(sp)
            @test :_resources ∈ propertynames(sp, true)

            @test close(sp) === nothing
            @test window.close_calls == 1
            @test !ispath(tempdir)
            @test !_lifecycle_is_registered(plot, sp)
            @test !isopen(sp)

            @test close(sp) === nothing
            @test window.close_calls == 1
            @test !ispath(tempdir)
        end

        @testset "unknown backend state still attempts explicit close" begin
            ec = _LifecycleFakeElectron(; throw_on_isopen=true)
            plot = Plot(scatter(y=[1, 2, 3]))
            sp = PlotlySupply._create_syncplot_window(
                ec,
                plot;
                app=:fake,
                show=false,
            )
            tempdir = getfield(sp, :_resources).tempdir
            window = only(ec.windows)
            _, registered = PlotlySupply._register_displayed_syncplot!(plot, sp)
            @test registered

            # Public status remains conservative when the backend query fails,
            # but explicit close must not interpret "unknown" as "closed".
            @test !isopen(sp)
            @test window.exists
            @test close(sp) === nothing
            @test window.close_calls == 1
            @test !window.exists
            @test !ispath(tempdir)
            @test !_lifecycle_is_registered(plot, sp)
        end

        @testset "backend close may re-enter close on the owner task" begin
            ec = _LifecycleFakeElectron()
            plot = Plot(scatter(y=[1, 2, 3]))
            sp = PlotlySupply._create_syncplot_window(
                ec,
                plot;
                app=:fake,
                show=false,
            )
            tempdir = getfield(sp, :_resources).tempdir
            window = only(ec.windows)
            window.on_close = () -> close(sp)

            task = @async close(sp)
            status = timedwait(() -> istaskdone(task), 2.0; pollint=0.01)
            if status === :timed_out
                # Keep a regression failure from leaving its test task blocked.
                notify(getfield(sp, :_resources).close_done)
                timedwait(() -> istaskdone(task), 2.0; pollint=0.01)
            end

            @test status === :ok
            @test fetch(task) === nothing
            @test window.close_calls == 1
            @test !ispath(tempdir)
            window.on_close = nothing
        end

        @testset "concurrent close waits without holding resource lock" begin
            ec = _LifecycleFakeElectron(; block_close=true)
            plot = Plot(scatter(y=[1, 2, 3]))
            sp = PlotlySupply._create_syncplot_window(
                ec,
                plot;
                app=:fake,
                show=false,
            )
            tempdir = getfield(sp, :_resources).tempdir
            window = only(ec.windows)
            _, registered = PlotlySupply._register_displayed_syncplot!(plot, sp)
            @test registered

            first_close = Threads.@spawn close(sp)
            take!(window.close_entered)

            resource_lock = getfield(sp, :_resources).lock
            lock_available = trylock(resource_lock)
            @test lock_available
            lock_available && unlock(resource_lock)

            second_close = Threads.@spawn close(sp)
            sleep(0.05)
            @test !istaskdone(second_close)
            @test ispath(tempdir)

            put!(window.close_release, nothing)
            @test fetch(first_close) === nothing
            @test fetch(second_close) === nothing
            @test window.close_calls == 1
            @test !ispath(tempdir)
            @test !_lifecycle_is_registered(plot, sp)
        end

        @testset "same-task close retries failed temp cleanup" begin
            owned_tempdir = mktempdir(; prefix="plotlysupply-cleanup-retry-")
            try
                write(joinpath(owned_tempdir, "index.html"), "owned")
                ec = _LifecycleFakeElectron()
                window = _lifecycle_fake_window(
                    ec,
                    :fake,
                    "file://cleanup-retry";
                    width=1,
                    height=1,
                    title="cleanup-retry",
                    show=false,
                )
                resources = PlotlySupply._SyncPlotResources(owned_tempdir, ec)
                attempts = Ref(0)
                resources.tempdir_remover = path -> begin
                    attempts[] += 1
                    attempts[] == 1 && error("injected temp cleanup failure")
                    rm(path; recursive=true, force=true)
                end
                sp = SyncPlot(
                    Plot(scatter(y=[1])),
                    :fake,
                    window,
                    "cleanup-retry",
                    resources,
                )

                @test_throws ErrorException close(sp)
                @test attempts[] == 1
                @test resources.close_owner === nothing
                @test ispath(owned_tempdir)
                @test window.close_calls == 1

                @test close(sp) === nothing
                @test attempts[] == 2
                @test !ispath(owned_tempdir)
                @test window.close_calls == 1
            finally
                ispath(owned_tempdir) &&
                    rm(owned_tempdir; recursive=true, force=true)
            end
        end

        @testset "throwing backend close still releases owned resources" begin
            ec = _LifecycleFakeElectron(; throw_on_close=true)
            plot = Plot(scatter(y=[1, 2, 3]))
            sp = PlotlySupply._create_syncplot_window(
                ec,
                plot;
                app=:fake,
                show=false,
            )
            tempdir = getfield(sp, :_resources).tempdir
            window = only(ec.windows)
            _, registered = PlotlySupply._register_displayed_syncplot!(plot, sp)
            @test registered

            @test_throws ErrorException close(sp)
            @test window.close_calls == 1
            @test !ispath(tempdir)
            @test !_lifecycle_is_registered(plot, sp)
            @test !isopen(sp)

            # Closing the same SyncPlot again neither retries the native close
            # nor rethrows after its package-owned resources were released.
            @test close(sp) === nothing
            @test window.close_calls == 1

            # End the fake native lifecycle so its weak watcher can exit.
            window.exists = false
            isopen(window.msg_channel) && close(window.msg_channel)
        end

        @testset "registry mutation is thread-safe" begin
            baseline = _lifecycle_registry_counts()
            ec = _LifecycleFakeElectron()
            plots = [Plot(scatter(y=[i, i + 1])) for i in 1:24]
            syncplots = [
                PlotlySupply._create_syncplot_window(
                    ec,
                    plot;
                    app=:fake,
                    show=false,
                )
                for plot in plots
            ]
            tempdirs = [getfield(sp, :_resources).tempdir for sp in syncplots]

            tasks = map(eachindex(plots)) do index
                Threads.@spawn begin
                    _, registered = PlotlySupply._register_displayed_syncplot!(
                        plots[index],
                        syncplots[index],
                    )
                    registered || error("SyncPlot closed before registration")
                    yield()
                    close(syncplots[index])
                end
            end
            foreach(fetch, tasks)

            @test _lifecycle_registry_counts() == baseline
            @test all(!ispath(tempdir) for tempdir in tempdirs)
            @test all(window.close_calls == 1 for window in ec.windows)
        end

        @testset "native close releases registries and large payload" begin
            ec = _LifecycleFakeElectron()
            baseline = _lifecycle_registry_counts()
            fixture = _native_close_lifecycle_fixture(ec)

            @test fixture.registered
            @test fixture.old === nothing
            @test fixture.retained_size > 1_500_000
            @test all(ref -> ref.value !== nothing, fixture.refs)
            @test _lifecycle_registry_counts() == (baseline[1] + 1, baseline[2] + 1)

            @test _wait_for_lifecycle() do
                !ispath(fixture.tempdir) &&
                    _lifecycle_registry_counts() == baseline
            end
            @test fixture.window.close_calls == 0

            @test _wait_for_lifecycle(; collect=true) do
                all(ref -> isnothing(ref.value), fixture.refs)
            end
        end

        @testset "open-window watcher remains weak" begin
            ec = _LifecycleFakeElectron()
            fixture = _open_watcher_lifecycle_fixture(ec)

            @test fixture.initially_open
            @test fixture.initial_close_calls == 0
            @test fixture.retained_size > 1_500_000
            @test fixture.window === only(ec.windows)

            @test _wait_for_lifecycle(; collect=true) do
                !ispath(fixture.tempdir) &&
                    fixture.window.close_calls == 1 &&
                    !fixture.window.exists &&
                    all(ref -> isnothing(ref.value), fixture.refs)
            end
            @test !isopen(fixture.window.msg_channel)
        end
    end

    include("export_transactions.jl")
    include("mutator_parity.jl")
end
