using PlotlySupply
using Test
using PlotlyJS

@testset "PlotlySupply.jl" begin
    @testset "plot_scatter" begin
        @test plot_scatter(1:10, 1:10) isa PlotlyJS.SyncPlot
        @test plot_scatter(1:10) isa PlotlyJS.SyncPlot
        @test plot_scatter(1:10, 1:10, xlabel="x", ylabel="y", title="title", legend="legend") isa PlotlyJS.SyncPlot
        @test plot_scatter(1:10, [1:10, 2:11], mode=["lines", "markers"]) isa PlotlyJS.SyncPlot
    end

    @testset "plot_heatmap" begin
        @test plot_heatmap(rand(10, 10)) isa PlotlyJS.SyncPlot
        @test plot_heatmap(1:10, 1:10, rand(10, 10)) isa PlotlyJS.SyncPlot
        @test plot_heatmap(1:10, 1:10, rand(10, 10), xlabel="x", ylabel="y", title="title") isa PlotlyJS.SyncPlot
    end

    @testset "plot_surface" begin
        @test plot_surface(rand(10,10)) isa PlotlyJS.SyncPlot
        @test plot_surface(collect(1:10), collect(1:10), rand(10,10)) isa PlotlyJS.SyncPlot
        @test plot_surface(collect(1:10), collect(1:10), rand(10,10), xlabel="x", ylabel="y", zlabel="z", title="title") isa PlotlyJS.SyncPlot
    end

    @testset "plot_quiver" begin
        @test plot_quiver(1:10, 1:10, 1:10, 1:10) isa PlotlyJS.SyncPlot
        @test plot_quiver(1:10, 1:10, 1:10, 1:10, xlabel="x", ylabel="y", title="title") isa PlotlyJS.SyncPlot
    end

    @testset "plot_scatter3d" begin
        @test plot_scatter3d(1:10, 1:10, 1:10) isa PlotlyJS.SyncPlot
        @test plot_scatter3d(1:10, 1:10, 1:10, xlabel="x", ylabel="y", zlabel="z", title="title") isa PlotlyJS.SyncPlot
    end

    @testset "plot_quiver3d" begin
        @test plot_quiver3d(1:10, 1:10, 1:10, 1:10, 1:10, 1:10) isa PlotlyJS.SyncPlot
        @test plot_quiver3d(1:10, 1:10, 1:10, 1:10, 1:10, 1:10, xlabel="x", ylabel="y", zlabel="z", title="title") isa PlotlyJS.SyncPlot
    end

    @testset "plot_stem" begin
        @test plot_stem(1:10, 1:10) isa PlotlyJS.SyncPlot
        @test plot_stem(1:10) isa PlotlyJS.SyncPlot
        @test plot_stem(1:10, 1:10, xlabel="x", ylabel="y", title="title", legend="legend") isa PlotlyJS.SyncPlot
    end

    @testset "plot_scatterpolar" begin
        @test plot_scatterpolar(1:10, 1:10) isa PlotlyJS.SyncPlot
        @test plot_scatterpolar(1:10, 1:10, title="title", legend="legend") isa PlotlyJS.SyncPlot
    end

    @testset "set_template!" begin
        fig = plot_scatter(1:10)
        set_template!(fig, "plotly_dark")
        @test fig.plot.layout.template.layout.paper_bgcolor == "rgb(17,17,17)"
    end
end