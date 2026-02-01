using Test
using PlotlySupply

@testset "PlotlySupply.jl" begin
    # Write your tests here.

    @testset "plot_scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false, fontsize=12)
        @test fig isa PlotlyJS.SyncPlot

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, legend=["trace1", "trace2"], mode=["markers", "lines+markers"], color=["red", "blue"])
        @test fig2 isa PlotlyJS.SyncPlot
    end

    @testset "plot_stem" begin
        x = 1:10
        y = rand(10)
        fig = plot_stem(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false)
        @test fig isa PlotlyJS.SyncPlot

        y2 = [rand(10), rand(10)]
        fig2 = plot_stem(x, y2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test fig2 isa PlotlyJS.SyncPlot
    end

    @testset "plot_scatterpolar" begin
        theta = 0:0.1:2*pi
        r = sin.(theta)
        fig = plot_scatterpolar(theta, r, title="My Title", trange=[0, 360], rrange=[0, 1], width=500, height=500, grid=false)
        @test fig isa PlotlyJS.SyncPlot

        r2 = [sin.(theta), cos.(theta)]
        fig2 = plot_scatterpolar(theta, r2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test fig2 isa PlotlyJS.SyncPlot
    end

    @testset "plot_heatmap" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_heatmap(x, y, U, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", equalar=true)
        @test fig isa PlotlyJS.SyncPlot

        fig2 = plot_heatmap(U)
        @test fig2 isa PlotlyJS.SyncPlot
    end

    @testset "plot_contour" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_contour(x, y, U, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", equalar=true, fontsize=11)
        @test fig isa PlotlyJS.SyncPlot

        fig2 = plot_contour(U)
        @test fig2 isa PlotlyJS.SyncPlot
    end

    @testset "plot_quiver" begin
        x = 1:10
        y = 1:10
        u = rand(10)
        v = rand(10)
        fig = plot_quiver(x, y, u, v, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 10], width=500, height=500, color="red", sizeref=0.5, grid=false)
        @test fig isa PlotlyJS.SyncPlot
    end

    @testset "plot_surface" begin
        x = 1:10
        y = 1:20
        X = [i for i in x, j in y]
        Y = [j for i in x, j in y]
        Z = rand(10, 20)
        fig = plot_surface(X, Y, Z, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", aspectmode="cube", grid=false, showaxis=false)
        @test fig isa PlotlyJS.SyncPlot

        fig2 = plot_surface(Z, surfacecolor=rand(10, 20))
        @test fig2 isa PlotlyJS.SyncPlot
    end

    @testset "plot_scatter3d" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        fig = plot_scatter3d(x, y, z, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 10], zrange=[0, 1], width=500, height=500, mode="markers", color="red", legend="trace1", aspectmode="cube", perspective=false, grid=false, showaxis=false)
        @test fig isa PlotlyJS.SyncPlot

        z2 = [rand(10), rand(10)]
        x2 = [1:10, 1:10]
        y2 = [1:10, 1:10]
        fig2 = plot_scatter3d(x2, y2, z2, color=["red", "blue"], legend=["trace1", "trace2"], mode=["markers", "lines+markers"])
        @test fig2 isa PlotlyJS.SyncPlot
    end

    @testset "plot_quiver3d" begin
        x = 1:10
        y = 1:10
        z = 1:10
        u = rand(10)
        v = rand(10)
        w = rand(10)
        fig = plot_quiver3d(x, y, z, u, v, w, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 10], zrange=[0, 10], width=500, height=500, color="red", colorscale="Viridis", sizeref=0.5, aspectmode="cube", perspective=false, grid=false, showaxis=false)
        @test fig isa PlotlyJS.SyncPlot
    end

    @testset "set_template!" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y)
        set_template!(fig, "plotly_dark")
        @test fig.plot.layout.template == PlotlyJS.templates.plotly_dark
        set_template!(fig, "ggplot2")
        @test fig.plot.layout.template == PlotlyJS.templates.ggplot2
        set_template!(fig, "seaborn")
        @test fig.plot.layout.template == PlotlyJS.templates.seaborn
        set_template!(fig, "simple_white")
        @test fig.plot.layout.template == PlotlyJS.templates.simple_white
        set_template!(fig, "presentation")
        @test fig.plot.layout.template == PlotlyJS.templates.presentation
        set_template!(fig, "xgridoff")
        @test fig.plot.layout.template == PlotlyJS.templates.xgridoff
        set_template!(fig, "ygridoff")
        @test fig.plot.layout.template == PlotlyJS.templates.ygridoff
        set_template!(fig, "gridon")
        @test fig.plot.layout.template == PlotlyJS.templates.gridon
        set_template!(fig, "none")
        @test fig.plot.layout.template == PlotlyJS.templates.plotly_white
    end

    @testset "Mutating Functions - plot_scatter!" begin
        x = 1:10
        y = rand(10)
        y2 = rand(10)
        y3 = rand(10)
        
        # Test basic scatter! with x and y
        fig = plot_scatter(x, y, title="Scatter Test")
        initial_trace_count = length(fig.plot.data)
        plot_scatter!(fig, x, y2, color="red", legend="added trace")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) == initial_trace_count + 1
        
        # Test chaining multiple scatter! calls
        plot_scatter!(fig, x, y3, color="blue", legend="third trace")
        @test length(fig.plot.data) == initial_trace_count + 2
        
        # Test scatter! without x (uses indices)
        fig2 = plot_scatter(y, title="Scatter Test 2")
        initial_count = length(fig2.plot.data)
        plot_scatter!(fig2, y2, color="green", legend="appended")
        @test length(fig2.plot.data) == initial_count + 1
        
        # Test scatter! with vector of vectors
        y_multi = [rand(10), rand(10)]
        fig3 = plot_scatter(y, title="Multi Scatter")
        initial_count = length(fig3.plot.data)
        plot_scatter!(fig3, x, y_multi, color=["purple", "orange"], legend=["m1", "m2"])
        @test length(fig3.plot.data) == initial_count + 2
    end

    @testset "Mutating Functions - plot_stem!" begin
        x = 1:10
        y = rand(10)
        y2 = rand(10)
        
        # Test basic stem! with x and y
        fig = plot_stem(x, y, title="Stem Test")
        initial_trace_count = length(fig.plot.data)
        plot_stem!(fig, x, y2, color="red", legend="added stem")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) > initial_trace_count  # stem creates 2 traces per call
        
        # Test stem! without x (uses indices)
        fig2 = plot_stem(y, title="Stem Test 2")
        initial_count = length(fig2.plot.data)
        plot_stem!(fig2, y2, color="green", legend="appended")
        @test length(fig2.plot.data) > initial_count
        
        # Test stem! with vector of vectors
        y_multi = [rand(10), rand(10)]
        fig3 = plot_stem(y, title="Multi Stem")
        initial_count = length(fig3.plot.data)
        plot_stem!(fig3, x, y_multi, color=["blue", "red"], legend=["s1", "s2"])
        @test length(fig3.plot.data) > initial_count
    end

    @testset "Mutating Functions - plot_scatterpolar!" begin
        theta = 0:0.1:2*pi
        r = sin.(theta)
        r2 = cos.(theta)
        
        fig = plot_scatterpolar(theta, r, title="Polar Test")
        initial_trace_count = length(fig.plot.data)
        plot_scatterpolar!(fig, theta, r2, color="red", legend="cos trace")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_heatmap!" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        U2 = rand(10, 20)
        
        fig = plot_heatmap(x, y, U, title="Heatmap Test")
        initial_trace_count = length(fig.plot.data)
        plot_heatmap!(fig, x, y, U2, title="Added Heatmap")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_contour!" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        U2 = rand(10, 20)
        
        fig = plot_contour(x, y, U, title="Contour Test")
        initial_trace_count = length(fig.plot.data)
        plot_contour!(fig, x, y, U2, title="Added Contour")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_quiver!" begin
        x = 1:10
        y = 1:10
        u = rand(10)
        v = rand(10)
        u2 = rand(10)
        v2 = rand(10)
        
        fig = plot_quiver(x, y, u, v, title="Quiver Test")
        initial_trace_count = length(fig.plot.data)
        plot_quiver!(fig, x, y, u2, v2, color="red")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) == initial_trace_count + 1
    end

    @testset "Mutating Functions - plot_surface!" begin
        x = 1:10
        y = 1:20
        X = [i for i in x, j in y]
        Y = [j for i in x, j in y]
        Z = rand(10, 20)
        Z2 = rand(10, 20)
        
        fig = plot_surface(X, Y, Z, title="Surface Test")
        initial_trace_count = length(fig.plot.data)
        plot_surface!(fig, X, Y, Z2, zlabel="Added Surface")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) == initial_trace_count + 1
        
        # Test with color matrix
        color_map = rand(10, 20)
        fig2 = plot_surface(X, Y, Z)
        initial_count = length(fig2.plot.data)
        plot_surface!(fig2, X, Y, Z2, color=color_map)
        @test length(fig2.plot.data) == initial_count + 1
    end

    @testset "Mutating Functions - plot_scatter3d!" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        z2 = rand(10)
        
        fig = plot_scatter3d(x, y, z, title="3D Scatter Test")
        initial_trace_count = length(fig.plot.data)
        plot_scatter3d!(fig, x, y, z2, color="red", legend="added trace")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) == initial_trace_count + 1
        
        # Test with vector of vectors
        z_multi = [rand(10), rand(10)]
        x_multi = [1:10, 1:10]
        y_multi = [1:10, 1:10]
        fig2 = plot_scatter3d(x, y, z)
        initial_count = length(fig2.plot.data)
        plot_scatter3d!(fig2, x_multi, y_multi, z_multi, color=["blue", "green"], legend=["m1", "m2"])
        @test length(fig2.plot.data) > initial_count
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
        initial_trace_count = length(fig.plot.data)
        plot_quiver3d!(fig, x, y, z, u2, v2, w2, color="red")
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) == initial_trace_count + 1
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
        
        @test fig isa PlotlyJS.SyncPlot
        @test length(fig.plot.data) >= 4
    end
end
