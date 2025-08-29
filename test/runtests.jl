using Test
using PlotlySupply

@testset "PlotlySupply.jl" begin
    # Write your tests here.

    @testset "plot_scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false)
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
end