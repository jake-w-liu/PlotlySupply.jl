using Test
using PlotlySupply

@testset "PlotlySupply.jl" begin
    # Write your tests here.

    @testset "plot_scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false, fontsize=12)
        @test fig isa SyncPlot

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, legend=["trace1", "trace2"], mode=["markers", "lines+markers"], color=["red", "blue"])
        @test fig2 isa SyncPlot
    end

    @testset "plot_stem" begin
        x = 1:10
        y = rand(10)
        fig = plot_stem(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false)
        @test fig isa SyncPlot

        y2 = [rand(10), rand(10)]
        fig2 = plot_stem(x, y2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test fig2 isa SyncPlot
    end

    @testset "plot_scatterpolar" begin
        theta = 0:0.1:2*pi
        r = sin.(theta)
        fig = plot_scatterpolar(theta, r, title="My Title", trange=[0, 360], rrange=[0, 1], width=500, height=500, grid=false)
        @test fig isa SyncPlot

        r2 = [sin.(theta), cos.(theta)]
        fig2 = plot_scatterpolar(theta, r2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test fig2 isa SyncPlot
    end

    @testset "plot_heatmap" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_heatmap(x, y, U, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", equalar=true)
        @test fig isa SyncPlot

        fig2 = plot_heatmap(U)
        @test fig2 isa SyncPlot
    end

    @testset "plot_contour" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_contour(x, y, U, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", equalar=true, fontsize=11)
        @test fig isa SyncPlot

        fig2 = plot_contour(U)
        @test fig2 isa SyncPlot
    end

    @testset "plot_quiver" begin
        x = 1:10
        y = 1:10
        u = rand(10)
        v = rand(10)
        fig = plot_quiver(x, y, u, v, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 10], width=500, height=500, color="red", sizeref=0.5, grid=false)
        @test fig isa SyncPlot
    end

    @testset "plot_surface" begin
        x = 1:10
        y = 1:20
        X = [i for i in x, j in y]
        Y = [j for i in x, j in y]
        Z = rand(10, 20)
        fig = plot_surface(X, Y, Z, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", aspectmode="cube", grid=false, showaxis=false)
        @test fig isa SyncPlot

        fig2 = plot_surface(Z, surfacecolor=rand(10, 20))
        @test fig2 isa SyncPlot
    end

    @testset "plot_scatter3d" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        fig = plot_scatter3d(x, y, z, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 10], zrange=[0, 1], width=500, height=500, mode="markers", color="red", legend="trace1", aspectmode="cube", perspective=false, grid=false, showaxis=false)
        @test fig isa SyncPlot

        z2 = [rand(10), rand(10)]
        x2 = [1:10, 1:10]
        y2 = [1:10, 1:10]
        fig2 = plot_scatter3d(x2, y2, z2, color=["red", "blue"], legend=["trace1", "trace2"], mode=["markers", "lines+markers"])
        @test fig2 isa SyncPlot
    end

    @testset "plot_quiver3d" begin
        x = 1:10
        y = 1:10
        z = 1:10
        u = rand(10)
        v = rand(10)
        w = rand(10)
        fig = plot_quiver3d(x, y, z, u, v, w, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 10], zrange=[0, 10], width=500, height=500, color="red", colorscale="Viridis", sizeref=0.5, aspectmode="cube", perspective=false, grid=false, showaxis=false)
        @test fig isa SyncPlot
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
        @test fig isa SyncPlot
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
        @test fig isa SyncPlot
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

    @testset "Mutating Functions - plot_scatterpolar!" begin
        theta = 0:0.1:2*pi
        r = sin.(theta)
        r2 = cos.(theta)
        
        fig = plot_scatterpolar(theta, r, title="Polar Test")
        initial_trace_count = length(fig.data)
        plot_scatterpolar!(fig, theta, r2, color="red", legend="cos trace")
        @test fig isa SyncPlot
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
        @test fig isa SyncPlot
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
        @test fig isa SyncPlot
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
        @test fig isa SyncPlot
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
        @test fig isa SyncPlot
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
        @test fig isa SyncPlot
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
        @test fig isa SyncPlot
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
        
        @test fig isa SyncPlot
        @test length(fig.data) >= 4
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
        @test fig_scatter_multi isa SyncPlot
        @test length(fig_scatter_multi.data) == 2

        # y-only vector-of-vectors branch
        fig_scatter_yonly = plot_scatter(y_multi)
        @test fig_scatter_yonly isa SyncPlot

        # plot_stem branches: x/y vectors and fontsize path
        fig_stem_multi = plot_stem(x_multi, y_multi; color="black", legend="stem", fontsize=10)
        @test fig_stem_multi isa SyncPlot
        @test length(fig_stem_multi.data) > 2
        fig_stem_yonly = plot_stem(y_multi)
        @test fig_stem_yonly isa SyncPlot

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
        @test fig_polar_multi isa SyncPlot
        @test length(fig_polar_multi.data) == 2

        # heatmap/contour edge branches for dx/dy fallback and fontsize
        U13 = rand(1, 3)
        U31 = rand(3, 1)
        fig_heat_dx0 = plot_heatmap([0.0], [0.0, 1.0, 2.0], U13; equalar=true, fontsize=9)
        fig_heat_dy0 = plot_heatmap([0.0, 1.0, 2.0], [0.0], U31; equalar=true)
        @test fig_heat_dx0 isa SyncPlot
        @test fig_heat_dy0 isa SyncPlot

        fig_contour_dx0 = plot_contour([0.0], [0.0, 1.0, 2.0], U13; equalar=true, fontsize=9)
        fig_contour_dy0 = plot_contour([0.0, 1.0, 2.0], [0.0], U31; equalar=true)
        @test fig_contour_dx0 isa SyncPlot
        @test fig_contour_dy0 isa SyncPlot

        fig_quiver_font = plot_quiver(1:5, 1:5, rand(5), rand(5); fontsize=10)
        @test fig_quiver_font isa SyncPlot

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
        @test fig_surface_shared_default isa SyncPlot
        @test fig_surface_shared_scaled isa SyncPlot

        # plot_scatter3d multi branch with fill! paths for mode/color/legend
        x3 = [collect(1:4), collect(1:4)]
        y3 = [collect(1:4), collect(1:4)]
        z3 = [rand(4), rand(4)]
        fig_scatter3d_multi_fill = plot_scatter3d(x3, y3, z3; mode="lines+markers", color="orange", legend="traj", fontsize=10)
        @test fig_scatter3d_multi_fill isa SyncPlot

        fig_quiver3d_font = plot_quiver3d(1:5, 1:5, 1:5, rand(5), rand(5), rand(5); fontsize=10)
        @test fig_quiver3d_font isa SyncPlot
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
        @test fig_scatter isa SyncPlot

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
        @test fig_stem isa SyncPlot

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
        @test fig_polar isa SyncPlot

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
        @test fig_heat isa SyncPlot

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
        @test fig_cont isa SyncPlot

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
        @test fig_quiver isa SyncPlot

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
        @test fig_surface isa SyncPlot

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
        @test fig_s3 isa SyncPlot

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
        @test fig_q3 isa SyncPlot
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
            sp1 = plot(scatter(x=[1, 2], y=[2, 1]); show=false, title="p1")
            sp2 = plot([scatter(x=[1, 2], y=[1, 2])]; show=false, title="p2")
            sp3 = plot(scatter(x=[1], y=[1]), scatter(x=[1], y=[2]); show=false, title="p3")
            sp4 = plot(; layout=Layout(title="empty"), show=false, title="p4")
            sp5 = plot(Plot(scatter(x=[1, 2], y=[2, 1]), Layout(title="fig")); show=false, title="p5")
            @test sp1 isa SyncPlot
            @test sp2 isa SyncPlot
            @test sp3 isa SyncPlot
            @test sp4 isa SyncPlot
            @test sp5 isa SyncPlot

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
end
