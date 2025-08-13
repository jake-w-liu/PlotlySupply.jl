using PlotlySupply
using Test

@testset "PlotlySupply.jl" begin
    @testset "plot_scatter" begin
        @test plot_scatter(1:10, 1:10) isa PlotlyJS.SyncPlot
        @test plot_scatter(1:10) isa PlotlyJS.SyncPlot
    end

    @testset "plot_heatmap" begin
        @test plot_heatmap(rand(10, 10)) isa PlotlyJS.SyncPlot
        @test plot_heatmap(1:10, 1:10, rand(10, 10)) isa PlotlyJS.SyncPlot
    end

    @testset "plot_surface" begin
        @test plot_surface(rand(10,10)) isa PlotlyJS.SyncPlot
    end

    @testset "plot_quiver" begin
        @test plot_quiver(1:10, 1:10, 1:10, 1:10) isa PlotlyJS.SyncPlot
    end

    @testset "plot_scatter3d" begin
        @test plot_scatter3d(1:10, 1:10, 1:10) isa PlotlyJS.SyncPlot
    end

    @testset "plot_quiver3d" begin
        @test plot_quiver3d(1:10, 1:10, 1:10, 1:10, 1:10, 1:10) isa PlotlyJS.SyncPlot
    end

    @testset "plot_stem" begin
        @test plot_stem(1:10, 1:10) isa PlotlyJS.SyncPlot
        @test plot_stem(1:10) isa PlotlyJS.SyncPlot
    end

    @testset "plot_scatterpolar" begin
        @test plot_scatterpolar(1:10, 1:10) isa PlotlyJS.SyncPlot
    end
end