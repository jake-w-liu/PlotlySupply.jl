using Test
using PlotlySupply

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
        try
            svg_bytes = savefig(plot_scatter(1:3, rand(3)); format="svg")
            @test length(svg_bytes) > 0
        catch err
            @test occursin("PlotlyKaleido", sprint(showerror, err))
        end

        # Regression: NaN separators (used by quiver-like traces) should still export.
        p_nan = Plot(scatter(x=[1.0, 2.0, NaN, 3.0], y=[1.0, 2.0, NaN, 3.0]), Layout(title="nan-export"))
        try
            svg_nan = savefig(p_nan; format="svg")
            @test length(svg_nan) > 0
        catch err
            @test occursin("PlotlyKaleido", sprint(showerror, err))
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
end
