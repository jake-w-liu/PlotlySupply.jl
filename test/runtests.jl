using Test
using PlotlySupply
using Base64

isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")

@testset "PlotlySupply.jl" begin
    @testset "plot_scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false, fontsize=12)
        tr = only(fig.data)
        @test (tr[:type], tr[:mode]) == ("scatter", "lines")
        @test tr[:x] == x && tr[:y] == y
        _test_cartesian_options(fig; title="My Title", xlabel="x", ylabel="y",
            xrange=[0, 10], yrange=[0, 1], width=500, height=500, fontsize=12, showgrid=false)

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, legend=["trace1", "trace2"], mode=["markers", "lines+markers"], color=["red", "blue"])
        @test [t[:type] for t in fig2.data] == ["scatter", "scatter"]
        @test [t[:y] for t in fig2.data] == y2
        @test all(t -> t[:x] == x, fig2.data)
        @test [t[:name] for t in fig2.data] == ["trace1", "trace2"]
        @test [t[:mode] for t in fig2.data] == ["markers", "lines+markers"]
        @test [t[:line][:color] for t in fig2.data] == ["red", "blue"]
        @test fig2.layout[:showlegend] == true
    end

    @testset "default cartesian spines stay black after template" begin
        function spine_fields(axis)
            return axis isa AbstractDict ? axis : axis.fields
        end
        fig = plot_scatter(1:4, 1:4; show=false)
        for axis in (fig.layout[:xaxis], fig.layout[:yaxis])
            fields = spine_fields(axis)
            @test fields[:showline] == true
            @test fields[:mirror] == true
            @test fields[:linecolor] == "#000000"
            @test fields[:linewidth] == 1 || fields[:linewidth] == 1.0
            @test fields[:tickcolor] == "#000000"
            @test fields[:linecolor] != "#EBF0F8"
        end
        # Template application must not restore the wash-out gray.
        PlotlySupply._apply_default_template!(fig)
        for axis in (fig.layout[:xaxis], fig.layout[:yaxis])
            fields = spine_fields(axis)
            @test fields[:linecolor] == "#000000"
            @test fields[:linewidth] == 1 || fields[:linewidth] == 1.0
        end
    end

    @testset "plot_stem" begin
        x = 1:10
        y = rand(10)
        fig = plot_stem(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false)
        heads, stems = _stem_parts(fig)
        @test only(heads)[:x] == x && only(heads)[:y] == y
        # One stem per point, from the y = 0 baseline to the point, gap-separated.
        @test only(stems)[:x] == collect(Iterators.flatten((xi, xi, nothing) for xi in x))
        @test only(stems)[:y] == collect(Iterators.flatten((0, yi, nothing) for yi in y))
        @test only(heads)[:legendgroup] == only(stems)[:legendgroup]
        _test_cartesian_options(fig; title="My Title", xlabel="x", ylabel="y",
            xrange=[0, 10], yrange=[0, 1], width=500, height=500, showgrid=false)

        y2 = [rand(10), rand(10)]
        fig2 = plot_stem(x, y2, legend=["trace1", "trace2"], color=["red", "blue"])
        heads2, stems2 = _stem_parts(fig2)
        @test [t[:y] for t in heads2] == y2
        @test [t[:name] for t in heads2] == ["trace1", "trace2"]
        @test [t[:marker][:color] for t in heads2] == ["red", "blue"]
        @test [t[:line][:color] for t in stems2] == ["red", "blue"]
        @test all(t -> t[:showlegend] == false, stems2)
    end

    @testset "plot_bar" begin
        x = 1:10
        y = rand(10)
        fig = plot_bar(x, y, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 1], width=500, height=500, grid=false)
        tr = only(fig.data)
        @test tr[:type] == "bar"
        @test tr[:x] == x && tr[:y] == y
        _test_cartesian_options(fig; title="My Title", xlabel="x", ylabel="y",
            xrange=[0, 10], yrange=[0, 1], width=500, height=500, showgrid=false)

        y2 = [rand(10), rand(10)]
        fig2 = plot_bar(x, y2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test [t[:type] for t in fig2.data] == ["bar", "bar"]
        @test [t[:y] for t in fig2.data] == y2
        @test [t[:name] for t in fig2.data] == ["trace1", "trace2"]
        @test [t[:marker][:color] for t in fig2.data] == ["red", "blue"]
    end

    @testset "plot_histogram" begin
        x = randn(200)
        fig = plot_histogram(x, title="Histogram", xlabel="x", ylabel="count", nbinsx=30, width=500, height=500)
        tr = only(fig.data)
        @test tr[:type] == "histogram"
        @test tr[:x] == x
        @test tr[:nbinsx] == 30
        _test_cartesian_options(fig; title="Histogram", xlabel="x", ylabel="count", width=500, height=500)

        xmulti = [randn(100), randn(100) .+ 1.0]
        fig2 = plot_histogram(xmulti, legend=["h1", "h2"], color=["red", "blue"], histnorm="probability")
        @test [t[:type] for t in fig2.data] == ["histogram", "histogram"]
        @test [t[:x] for t in fig2.data] == xmulti
        @test [t[:name] for t in fig2.data] == ["h1", "h2"]
        @test [t[:marker][:color] for t in fig2.data] == ["red", "blue"]
        @test all(t -> t[:histnorm] == "probability", fig2.data)
        # Several series overlay on shared bins.
        @test fig2.layout[:barmode] == "overlay"
        @test fig2.data[1][:bingroup] == fig2.data[2][:bingroup]
    end

    @testset "plot_box" begin
        x = fill("group A", 20)
        y = randn(20)
        fig = plot_box(x, y, title="Box", xlabel="group", ylabel="value", width=500, height=500)
        tr = only(fig.data)
        @test tr[:type] == "box"
        @test tr[:x] == x && tr[:y] == y
        _test_cartesian_options(fig; title="Box", xlabel="group", ylabel="value", width=500, height=500)

        y2 = [randn(20), randn(20) .+ 0.5]
        fig2 = plot_box(y2, legend=["b1", "b2"], color=["red", "blue"])
        @test [t[:type] for t in fig2.data] == ["box", "box"]
        @test [t[:y] for t in fig2.data] == y2
        @test [t[:name] for t in fig2.data] == ["b1", "b2"]
        @test [t[:marker][:color] for t in fig2.data] == ["red", "blue"]
        @test [t[:line][:color] for t in fig2.data] == ["red", "blue"]
    end

    @testset "plot_violin" begin
        x = fill("group A", 20)
        y = randn(20)
        fig = plot_violin(x, y, title="Violin", xlabel="group", ylabel="value", width=500, height=500)
        tr = only(fig.data)
        @test tr[:type] == "violin"
        @test tr[:x] == x && tr[:y] == y
        _test_cartesian_options(fig; title="Violin", xlabel="group", ylabel="value", width=500, height=500)

        y2 = [randn(20), randn(20) .+ 0.5]
        fig2 = plot_violin(y2, legend=["v1", "v2"], color=["red", "blue"], side="positive")
        @test [t[:type] for t in fig2.data] == ["violin", "violin"]
        @test [t[:y] for t in fig2.data] == y2
        @test [t[:name] for t in fig2.data] == ["v1", "v2"]
        @test [t[:line][:color] for t in fig2.data] == ["red", "blue"]
        @test all(t -> t[:side] == "positive", fig2.data)
    end

    @testset "plot_scatterpolar" begin
        theta = 0:0.1:2*pi
        r = sin.(theta)
        fig = plot_scatterpolar(theta, r, title="My Title", trange=[0, 360], rrange=[0, 1], width=500, height=500, grid=false)
        tr = only(fig.data)
        @test tr[:type] == "scatterpolar"
        @test tr[:theta] == theta && tr[:r] == r
        polar = fig.layout[:polar]
        @test polar[:sector] == [0, 360]
        @test polar[:radialaxis][:range] == [0, 1]
        @test polar[:radialaxis][:showgrid] == false
        @test polar[:angularaxis][:showgrid] == false
        @test !haskey(fig.layout.fields, :xaxis)
        _test_cartesian_options(fig; title="My Title", width=500, height=500)

        r2 = [sin.(theta), cos.(theta)]
        fig2 = plot_scatterpolar(theta, r2, legend=["trace1", "trace2"], color=["red", "blue"])
        @test [t[:type] for t in fig2.data] == ["scatterpolar", "scatterpolar"]
        @test [t[:r] for t in fig2.data] == r2
        @test [t[:name] for t in fig2.data] == ["trace1", "trace2"]
        @test [t[:line][:color] for t in fig2.data] == ["red", "blue"]
    end

    @testset "plot_heatmap" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_heatmap(x, y, U, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", equalar=true)
        _test_field_trace(only(fig.data), "heatmap", x, y, U)
        @test (only(fig.data)[:zmin], only(fig.data)[:zmax]) == (0, 1)
        @test only(fig.data)[:colorscale] ==
              PlotlySupply._resolve_colorscale("Viridis"; who="plot_heatmap").scale
        # equalar: one data unit is as long on y as on x
        @test fig.layout[:yaxis][:scaleanchor] == "x"
        @test fig.layout[:yaxis][:scaleratio] == 1
        _test_cartesian_options(fig; title="My Title", xlabel="x", ylabel="y",
            xrange=[0, 10], yrange=[0, 20], width=500, height=500)

        fig2 = plot_heatmap(U)
        _test_field_trace(only(fig2.data), "heatmap", 0:9, 0:19, U)
        @test !haskey(fig2.layout[:yaxis], :scaleanchor)
    end

    @testset "plot_contour" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_contour(x, y, U, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", equalar=true, fontsize=11)
        _test_field_trace(only(fig.data), "contour", x, y, U)
        @test (only(fig.data)[:zmin], only(fig.data)[:zmax]) == (0, 1)
        @test only(fig.data)[:colorscale] ==
              PlotlySupply._resolve_colorscale("Viridis"; who="plot_contour").scale
        @test fig.layout[:yaxis][:scaleanchor] == "x"
        _test_cartesian_options(fig; title="My Title", xlabel="x", ylabel="y",
            xrange=[0, 10], yrange=[0, 20], width=500, height=500, fontsize=11)

        fig2 = plot_contour(U)
        _test_field_trace(only(fig2.data), "contour", 0:9, 0:19, U)
    end

    @testset "heatmap and contour preserve x-y matrix orientation without copies" begin
        x = [10, 20]
        y = [100, 200, 300]
        U = [11 12 13; 21 22 23]
        expected_rendered_z = [11 21; 12 22; 13 23]

        for constructor in (plot_heatmap, plot_contour)
            explicit = constructor(x, y, U)
            trace = only(explicit.data)
            @test trace.fields[:x] === x
            @test trace.fields[:y] === y
            @test trace.fields[:transpose] === true
            @test Matrix(trace.fields[:z]) == expected_rendered_z
            @test parent(trace.fields[:z]) === U
            @test PlotlyBase.JSON.json(trace.fields[:z]) ==
                  "[[11,12,13],[21,22,23]]"

            implicit = constructor(U)
            implicit_trace = only(implicit.data)
            @test implicit_trace.fields[:x] == [0, 1]
            @test implicit_trace.fields[:y] == [0, 1, 2]
            @test Matrix(implicit_trace.fields[:z]) == expected_rendered_z
            @test parent(implicit_trace.fields[:z]) === U

            square = constructor([1, 2], [3, 4], [11 12; 21 22])
            @test Matrix(only(square.data).fields[:z]) ==
                  [11 21; 12 22]
        end

        for mutator in (plot_heatmap!, plot_contour!)
            explicit = Plot()
            @test mutator(explicit, x, y, U) === nothing
            trace = only(explicit.data)
            @test trace.fields[:transpose] === true
            @test Matrix(trace.fields[:z]) == expected_rendered_z
            @test parent(trace.fields[:z]) === U

            implicit = Plot()
            @test mutator(implicit, U) === nothing
            implicit_trace = only(implicit.data)
            @test implicit_trace.fields[:x] == [0, 1]
            @test implicit_trace.fields[:y] == [0, 1, 2]
            @test Matrix(implicit_trace.fields[:z]) == expected_rendered_z
            @test parent(implicit_trace.fields[:z]) === U
        end

        storage = [0 0 0 0; 11 12 13 0; 21 22 23 0; 0 0 0 0]
        U_view = @view storage[2:3, 1:3]
        for constructor in (plot_heatmap, plot_contour)
            trace = only(constructor(x, y, U_view).data)
            @test Matrix(trace.fields[:z]) == expected_rendered_z
            @test parent(trace.fields[:z]) === U_view
        end
    end

    @testset "plot_quiver" begin
        x = 1:10
        y = 1:10
        u = rand(10) .+ 0.1
        v = rand(10)
        fig = plot_quiver(x, y, u, v, title="My Title", xlabel="x", ylabel="y", xrange=[0, 10], yrange=[0, 10], width=500, height=500, color="red", sizeref=0.5, grid=false)
        tr = only(fig.data)
        @test (tr[:type], tr[:mode]) == ("scatter", "lines")
        @test tr[:line][:color] == "red"
        # Shafts start at the grid points; the longest arrow is 2/3 * sizeref
        # data units long and the others scale with their magnitude.
        shafts = _quiver_shafts(tr)
        @test length(shafts) == length(x)
        speed = hypot.(u, v)
        for (i, (p0, p1)) in enumerate(shafts)
            @test p0 == (x[i], y[i])
            @test collect(p1 .- p0) ≈ [u[i], v[i]] ./ maximum(speed) .* (2 / 3 * 0.5)
        end
        @test fig.layout[:yaxis][:scaleanchor] == "x"   # equal aspect by default
        _test_cartesian_options(fig; title="My Title", xlabel="x", ylabel="y",
            xrange=[0, 10], yrange=[0, 10], width=500, height=500, showgrid=false)
    end

    @testset "plot_surface" begin
        x = 1:10
        y = 1:20
        X = [i for i in x, j in y]
        Y = [j for i in x, j in y]
        Z = rand(10, 20)
        fig = plot_surface(X, Y, Z, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 20], zrange=[0, 1], width=500, height=500, colorscale="Viridis", aspectmode="cube", grid=false, showaxis=false)
        tr = only(fig.data)
        @test tr[:type] == "surface"
        @test tr[:x] == X && tr[:y] == Y && tr[:z] == Z
        @test tr[:colorscale] == PlotlySupply._resolve_colorscale("Viridis"; who="plot_surface").scale
        _test_scene_options(fig; xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10],
            yrange=[0, 20], zrange=[0, 1], aspectmode="cube", showgrid=false, visible=false)
        _test_cartesian_options(fig; title="My Title", width=500, height=500)
        @test !haskey(fig.layout.fields, :xaxis)

        C = rand(10, 20)
        fig2 = plot_surface(Z, surfacecolor=C)
        tr2 = only(fig2.data)
        # Z[ix, iy]: implicit 0-based x along the first dimension, y along the second.
        @test tr2[:x] == 0:9 && tr2[:y] == 0:19
        @test tr2[:z] == Z && tr2[:surfacecolor] == C
    end

    @testset "plot_scatter3d" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        fig = plot_scatter3d(x, y, z, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 10], zrange=[0, 1], width=500, height=500, mode="markers", color="red", legend="trace1", aspectmode="cube", perspective=false, grid=false, showaxis=false)
        tr = only(fig.data)
        @test (tr[:type], tr[:mode], tr[:name]) == ("scatter3d", "markers", "trace1")
        @test tr[:x] == x && tr[:y] == y && tr[:z] == z
        @test tr[:line][:color] == "red"
        _test_scene_options(fig; xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10],
            yrange=[0, 10], zrange=[0, 1], aspectmode="cube", showgrid=false, visible=false)
        @test fig.layout[:scene][:camera][:projection][:type] == "orthographic"
        _test_cartesian_options(fig; title="My Title", width=500, height=500)

        z2 = [rand(10), rand(10)]
        x2 = [1:10, 1:10]
        y2 = [1:10, 1:10]
        fig2 = plot_scatter3d(x2, y2, z2, color=["red", "blue"], legend=["trace1", "trace2"], mode=["markers", "lines+markers"])
        @test [t[:type] for t in fig2.data] == ["scatter3d", "scatter3d"]
        @test [t[:z] for t in fig2.data] == z2
        @test [t[:name] for t in fig2.data] == ["trace1", "trace2"]
        @test [t[:mode] for t in fig2.data] == ["markers", "lines+markers"]
        @test [t[:line][:color] for t in fig2.data] == ["red", "blue"]
    end

    @testset "plot_quiver3d" begin
        x = 1:10
        y = 1:10
        z = 1:10
        u = rand(10)
        v = rand(10)
        w = rand(10)
        fig = @test_logs (:warn, r"plot_quiver3d: `colorscale` is ignored") plot_quiver3d(x, y, z, u, v, w, title="My Title", xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10], yrange=[0, 10], zrange=[0, 10], width=500, height=500, color="red", colorscale="Viridis", sizeref=0.5, aspectmode="cube", perspective=false, grid=false, showaxis=false)
        tr = only(fig.data)
        @test tr[:type] == "cone"
        @test (tr[:x], tr[:y], tr[:z]) == (x, y, z)
        @test (tr[:u], tr[:v], tr[:w]) == (u, v, w)
        @test (tr[:sizemode], tr[:sizeref], tr[:anchor]) == ("scaled", 0.5, "cm")
        # One uniform colour wins over the colorscale (with the warning above).
        @test tr[:colorscale] == [[0, "red"], [1, "red"]]
        @test tr[:showscale] == false
        _test_scene_options(fig; xlabel="x", ylabel="y", zlabel="z", xrange=[0, 10],
            yrange=[0, 10], zrange=[0, 10], aspectmode="cube", showgrid=false, visible=false)
        _test_cartesian_options(fig; title="My Title", width=500, height=500)
    end

    @testset "set_template!" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y)
        serialized = value -> PlotlyBase.JSON.parse(
            PlotlyBase.JSON.json(value; allownan=true),
        )
        for name in (
            :plotly_dark,
            :ggplot2,
            :seaborn,
            :simple_white,
            :presentation,
            :xgridoff,
            :ygridoff,
            :gridon,
        )
            set_template!(fig, string(name))
            expected = PlotlyBase.templates[name]
            @test fig.layout.fields[:template] isa PlotlyBase.Template
            @test fig.layout.fields[:template] === expected
            @test serialized(fig.layout)["template"] == serialized(expected)
        end
        @test_logs (:warn,) set_template!(fig, "none")
        @test fig.layout.fields[:template] ===
            PlotlyBase.templates[:plotly_white]

        custom_name = :plotlysupply_test_custom
        custom = PlotlyBase.Template(
            layout=attr(paper_bgcolor="rgb(12, 34, 56)"),
        )
        previous_default = get_default_template()
        registered_templates = PlotlyBase.templates.templates
        had_previous_custom = haskey(registered_templates, custom_name)
        previous_custom = get(registered_templates, custom_name, missing)
        PlotlyBase.templates[custom_name] = custom
        try
            compound_name = Symbol("plotly_white+xgridoff")
            compound = PlotlyBase.templates[String(compound_name)]
            set_template!(fig, " plotly_white + xgridoff ")
            @test fig.layout.fields[:template] isa PlotlyBase.Template
            @test fig.layout.fields[:template] == compound
            @test serialized(fig.layout)["template"] ==
                serialized(compound)
            @test set_default_template!("plotly_white + xgridoff") ===
                compound_name
            compound_default = plot_scatter(x, y)
            @test compound_default.layout.fields[:template] == compound
            @test serialized(compound_default.layout)["template"] ==
                serialized(compound)

            set_template!(fig, custom)
            @test fig.layout.fields[:template] === custom
            @test serialized(fig.layout)["template"] == serialized(custom)

            set_template!(fig, custom_name)
            @test fig.layout.fields[:template] === custom
            @test set_default_template!(custom_name) === custom_name
            @test get_default_template() === custom_name
            fig2 = plot_scatter(x, y)
            @test fig2.layout.fields[:template] isa PlotlyBase.Template
            @test fig2.layout.fields[:template] == custom
            @test serialized(fig2.layout)["template"] == serialized(custom)

            # 2.0 (spec C38): a Template object is accepted as the default.
            @test set_default_template!(custom) === custom
            @test get_default_template() === custom
            fig3 = plot_scatter(x, y)
            @test fig3.layout.fields[:template] == custom
            @test serialized(fig3.layout)["template"] == serialized(custom)
        finally
            set_default_template!(previous_default)
            if had_previous_custom
                registered_templates[custom_name] = previous_custom
            else
                delete!(registered_templates, custom_name)
            end
        end
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
        try
            set_default_legend_position!(:bottomleft)
            @test get_default_legend_position() == :bottomleft
            fig2 = plot_scatter(x, y; legend="trace2")
            @test fig2.layout.fields[:legend][:xanchor] == "left"
            @test fig2.layout.fields[:legend][:yanchor] == "bottom"
        finally
            # a failure above must not leak the default into later testsets
            set_default_legend_position!(prev_legend_pos)
        end
        @test get_default_legend_position() == prev_legend_pos
    end

    @testset "Mutating Functions - plot_scatter!" begin
        x = 1:10
        y = rand(10)
        y2 = rand(10)
        y3 = rand(10)
        
        # Test basic scatter! with x and y
        fig = plot_scatter(x, y, title="Scatter Test")
        initial_trace_count = length(fig.data)
        @test plot_scatter!(fig, x, y2, color="red", legend="added trace") === nothing
        @test length(fig.data) == initial_trace_count + 1
        added = fig.data[end]
        @test added[:type] == "scatter"
        @test added[:x] == x && added[:y] == y2
        @test (added[:name], added[:line][:color]) == ("added trace", "red")
        @test fig.data[1][:y] == y                       # existing trace untouched
        @test _lookup(fig.layout, :title, :text) == "Scatter Test"
        @test fig.layout[:showlegend] == true

        # Test chaining multiple scatter! calls
        @test plot_scatter!(fig, x, y3, color="blue", legend="third trace") === nothing
        @test length(fig.data) == initial_trace_count + 2
        @test (fig.data[end][:y], fig.data[end][:name]) == (y3, "third trace")

        # Test scatter! without x (uses indices)
        fig2 = plot_scatter(y, title="Scatter Test 2")
        initial_count = length(fig2.data)
        @test plot_scatter!(fig2, y2, color="green", legend="appended") === nothing
        @test length(fig2.data) == initial_count + 1
        @test fig2.data[end][:x] == 0:9 && fig2.data[end][:y] == y2
        @test fig2.data[end][:line][:color] == "green"

        # Test scatter! with vector of vectors
        y_multi = [rand(10), rand(10)]
        fig3 = plot_scatter(y, title="Multi Scatter")
        initial_count = length(fig3.data)
        @test plot_scatter!(fig3, x, y_multi, color=["purple", "orange"], legend=["m1", "m2"]) === nothing
        @test length(fig3.data) == initial_count + 2
        @test [t[:y] for t in fig3.data[end-1:end]] == y_multi
        @test [t[:name] for t in fig3.data[end-1:end]] == ["m1", "m2"]
        @test [t[:line][:color] for t in fig3.data[end-1:end]] == ["purple", "orange"]
    end

    @testset "Mutating Functions - plot_stem!" begin
        x = 1:10
        y = rand(10)
        y2 = rand(10)
        
        # Test basic stem! with x and y
        fig = plot_stem(x, y, title="Stem Test")
        initial_trace_count = length(fig.data)
        @test plot_stem!(fig, x, y2, color="red", legend="added stem") === nothing
        # one marker (heads) trace + one stems trace per series
        @test length(fig.data) == initial_trace_count + 2
        heads, stems = _stem_parts(Plot(fig.data[initial_trace_count+1:end]))
        @test only(heads)[:y] == y2
        @test (only(heads)[:name], only(heads)[:marker][:color]) == ("added stem", "red")
        @test only(stems)[:line][:color] == "red"
        @test _lookup(fig.layout, :title, :text) == "Stem Test"

        # Test stem! without x (uses indices)
        fig2 = plot_stem(y, title="Stem Test 2")
        initial_count = length(fig2.data)
        @test plot_stem!(fig2, y2, color="green", legend="appended") === nothing
        @test length(fig2.data) == initial_count + 2
        heads2, _ = _stem_parts(Plot(fig2.data[initial_count+1:end]))
        @test only(heads2)[:x] == 0:9 && only(heads2)[:y] == y2

        # Test stem! with vector of vectors
        y_multi = [rand(10), rand(10)]
        fig3 = plot_stem(y, title="Multi Stem")
        initial_count = length(fig3.data)
        @test plot_stem!(fig3, x, y_multi, color=["blue", "red"], legend=["s1", "s2"]) === nothing
        @test length(fig3.data) == initial_count + 4
        heads3, stems3 = _stem_parts(Plot(fig3.data[initial_count+1:end]))
        @test [t[:y] for t in heads3] == y_multi
        @test [t[:name] for t in heads3] == ["s1", "s2"]
        @test [t[:line][:color] for t in stems3] == ["blue", "red"]
    end

    @testset "Mutating Functions - plot_bar!" begin
        x = 1:10
        y = rand(10)
        y2 = rand(10)

        fig = plot_bar(x, y, title="Bar Test")
        initial_trace_count = length(fig.data)
        @test plot_bar!(fig, x, y2, color="red", legend="added bar") === nothing
        @test length(fig.data) == initial_trace_count + 1
        @test fig.data[end][:type] == "bar"
        @test fig.data[end][:x] == x && fig.data[end][:y] == y2
        @test (fig.data[end][:name], fig.data[end][:marker][:color]) == ("added bar", "red")
        @test _lookup(fig.layout, :title, :text) == "Bar Test"

        fig2 = plot_bar(y, title="Bar Test 2")
        initial_count = length(fig2.data)
        @test plot_bar!(fig2, y2, color="green", legend="appended") === nothing
        @test length(fig2.data) == initial_count + 1
        @test fig2.data[end][:x] == 0:9 && fig2.data[end][:y] == y2
        @test fig2.data[end][:marker][:color] == "green"
    end

    @testset "Mutating Functions - plot_histogram!" begin
        x = randn(200)
        fig = plot_histogram(x, title="Histogram Test")
        initial_trace_count = length(fig.data)
        x2 = randn(200) .+ 1.0
        @test plot_histogram!(fig, x2, color="red", legend="h2", nbinsx=20) === nothing
        @test length(fig.data) == initial_trace_count + 1
        added = fig.data[end]
        @test added[:type] == "histogram"
        @test added[:x] == x2
        @test (added[:name], added[:marker][:color], added[:nbinsx]) == ("h2", "red", 20)
        @test fig.data[1][:x] == x
    end

    @testset "Mutating Functions - plot_box!" begin
        x = fill("A", 20)
        y = randn(20)
        y2 = randn(20) .+ 0.5

        fig = plot_box(x, y, title="Box Test")
        initial_trace_count = length(fig.data)
        @test plot_box!(fig, fill("B", 20), y2, color="red", legend="B") === nothing
        @test length(fig.data) == initial_trace_count + 1
        added = fig.data[end]
        @test added[:type] == "box"
        @test added[:x] == fill("B", 20) && added[:y] == y2
        @test (added[:name], added[:marker][:color]) == ("B", "red")

        fig2 = plot_box(y, title="Box Test 2")
        initial_count = length(fig2.data)
        @test plot_box!(fig2, y2, color="green", legend="appended") === nothing
        @test length(fig2.data) == initial_count + 1
        @test fig2.data[end][:y] == y2
        @test (fig2.data[end][:name], fig2.data[end][:marker][:color]) == ("appended", "green")
    end

    @testset "Mutating Functions - plot_violin!" begin
        x = fill("A", 20)
        y = randn(20)
        y2 = randn(20) .+ 0.5

        fig = plot_violin(x, y, title="Violin Test")
        initial_trace_count = length(fig.data)
        @test plot_violin!(fig, fill("B", 20), y2, color="red", legend="B", side="negative") === nothing
        @test length(fig.data) == initial_trace_count + 1
        added = fig.data[end]
        @test added[:type] == "violin"
        @test added[:x] == fill("B", 20) && added[:y] == y2
        @test (added[:name], added[:line][:color], added[:side]) == ("B", "red", "negative")

        fig2 = plot_violin(y, title="Violin Test 2")
        initial_count = length(fig2.data)
        @test plot_violin!(fig2, y2, color="green", legend="appended") === nothing
        @test length(fig2.data) == initial_count + 1
        @test fig2.data[end][:y] == y2
        @test (fig2.data[end][:name], fig2.data[end][:line][:color]) == ("appended", "green")
    end

    @testset "Mutating Functions - plot_scatterpolar!" begin
        theta = 0:0.1:2*pi
        r = sin.(theta)
        r2 = cos.(theta)
        
        fig = plot_scatterpolar(theta, r, title="Polar Test")
        initial_trace_count = length(fig.data)
        @test plot_scatterpolar!(fig, theta, r2, color="red", legend="cos trace") === nothing
        @test length(fig.data) == initial_trace_count + 1
        added = fig.data[end]
        @test added[:type] == "scatterpolar"
        @test added[:theta] == theta && added[:r] == r2
        @test (added[:name], added[:line][:color]) == ("cos trace", "red")
        @test _lookup(fig.layout, :title, :text) == "Polar Test"
    end

    @testset "Mutating Functions - plot_heatmap!" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        U2 = rand(10, 20)
        
        fig = plot_heatmap(x, y, U, title="Heatmap Test")
        initial_trace_count = length(fig.data)
        @test plot_heatmap!(fig, x, y, U2, title="Added Heatmap") === nothing
        @test length(fig.data) == initial_trace_count + 1
        _test_field_trace(fig.data[end], "heatmap", x, y, U2)
        _test_field_trace(fig.data[1], "heatmap", x, y, U)
        # a mutator's explicit title replaces the figure title
        @test _lookup(fig.layout, :title, :text) == "Added Heatmap"
    end

    @testset "Mutating Functions - plot_contour!" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        U2 = rand(10, 20)
        
        fig = plot_contour(x, y, U, title="Contour Test")
        initial_trace_count = length(fig.data)
        @test plot_contour!(fig, x, y, U2, title="Added Contour") === nothing
        @test length(fig.data) == initial_trace_count + 1
        _test_field_trace(fig.data[end], "contour", x, y, U2)
        _test_field_trace(fig.data[1], "contour", x, y, U)
        @test _lookup(fig.layout, :title, :text) == "Added Contour"
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
        @test plot_quiver!(fig, x, y, u2, v2, color="red") === nothing
        @test length(fig.data) == initial_trace_count + 1
        added = fig.data[end]
        @test (added[:type], added[:mode], added[:line][:color]) == ("scatter", "lines", "red")
        @test [p0 for (p0, _) in _quiver_shafts(added)] == [(xi, yi) for (xi, yi) in zip(x, y)]
        @test _lookup(fig.layout, :title, :text) == "Quiver Test"
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
        @test plot_surface!(fig, X, Y, Z2, zlabel="Added Surface") === nothing
        @test length(fig.data) == initial_trace_count + 1
        @test fig.data[end][:type] == "surface"
        @test fig.data[end][:x] == X && fig.data[end][:y] == Y && fig.data[end][:z] == Z2
        @test fig.data[1][:z] == Z
        _test_scene_options(fig; zlabel="Added Surface")

        # Test with color matrix (`color` is the surfacecolor alias)
        color_map = rand(10, 20)
        fig2 = plot_surface(X, Y, Z)
        initial_count = length(fig2.data)
        @test plot_surface!(fig2, X, Y, Z2, color=color_map) === nothing
        @test length(fig2.data) == initial_count + 1
        @test fig2.data[end][:surfacecolor] == color_map
    end

    @testset "Mutating Functions - plot_scatter3d!" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        z2 = rand(10)
        
        fig = plot_scatter3d(x, y, z, title="3D Scatter Test")
        initial_trace_count = length(fig.data)
        @test plot_scatter3d!(fig, x, y, z2, color="red", legend="added trace") === nothing
        @test length(fig.data) == initial_trace_count + 1
        added = fig.data[end]
        @test added[:type] == "scatter3d"
        @test added[:x] == x && added[:y] == y && added[:z] == z2
        @test (added[:name], added[:line][:color]) == ("added trace", "red")

        # Test with vector of vectors
        z_multi = [rand(10), rand(10)]
        x_multi = [1:10, 1:10]
        y_multi = [1:10, 1:10]
        fig2 = plot_scatter3d(x, y, z)
        initial_count = length(fig2.data)
        @test plot_scatter3d!(fig2, x_multi, y_multi, z_multi, color=["blue", "green"], legend=["m1", "m2"]) === nothing
        @test length(fig2.data) == initial_count + 2
        @test [t[:z] for t in fig2.data[end-1:end]] == z_multi
        @test [t[:name] for t in fig2.data[end-1:end]] == ["m1", "m2"]
        @test [t[:line][:color] for t in fig2.data[end-1:end]] == ["blue", "green"]
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
        @test plot_quiver3d!(fig, x, y, z, u2, v2, w2, color="red") === nothing
        @test length(fig.data) == initial_trace_count + 1
        added = fig.data[end]
        @test added[:type] == "cone"
        @test (added[:u], added[:v], added[:w]) == (u2, v2, w2)
        @test added[:colorscale] == [[0, "red"], [1, "red"]]
        @test fig.data[1][:u] == u
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

        @test length(fig.data) == 4
        @test [t[:y] for t in fig.data] == [y1, y2, y3, y4]
        @test [t[:name] for t in fig.data] == ["", "trace 2", "trace 3", "trace 4"]
        @test [t[:line][:color] for t in fig.data[2:4]] == ["red", "blue", "green"]
        # the constructor's figure options survive the appends
        _test_cartesian_options(fig; title="Chained Mutations", xlabel="x", ylabel="y")
    end

    @testset "Subplots API" begin
        sf = PlotlySupply.subplots(2, 2; show=false, title="subplot-api")
        @test sf isa PlotlySupply.SubplotFigure
        @test sf.rows == 2
        @test sf.cols == 2
        @test sf.legend_position == get_default_legend_position()
        @test sf.plot.layout.fields[:template] isa PlotlyBase.Template
        @test sf.plot.layout.fields[:template] ==
            PlotlyBase.templates[get_default_template()]

        PlotlySupply.plot!(sf, 1:5, rand(5); legend="A")
        PlotlySupply.subplot!(sf, 1, 2)
        PlotlySupply.plot_stem!(sf, 1:5, rand(5); legend="B")
        PlotlySupply.subplot!(sf, 3) # row 2, col 1
        @test_logs (:warn, r"ignores figure-level keyword\(s\) \[:title\]") PlotlySupply.plot_contour!(sf, rand(5, 5); title="contour")
        PlotlySupply.subplot!(sf, 2, 2)
        @test_logs (:warn, r"ignores figure-level keyword\(s\) \[:title\]") PlotlySupply.plot_heatmap!(sf, rand(5, 5); title="heat")

        xlabel!(sf, "x22")
        ylabel!(sf, "y22")
        xrange!(sf, [0, 6])
        yrange!(sf, [0, 6])

        # scatter + stem (heads and stems traces) + contour + heatmap
        @test length(sf.plot.data) == 5
        @test [t[:type] for t in sf.plot.data] == ["scatter", "scatter", "scatter", "contour", "heatmap"]
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
        @test sf_raw.plot.layout.fields[:template] isa PlotlyBase.Template
        @test sf_raw.plot.layout.fields[:template] ==
            PlotlyBase.templates[get_default_template()]
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

        sp = nothing
        try
            sp = to_syncplot(fig; show=false)
            @test sp isa SyncPlot
            ec = PlotlySupply._syncplot_backend(sp)
            divid_js = PlotlySupply._json_js(sp.divid)
            function renderer_ready()
                return Base.invokelatest(() -> ec.run(
                    sp.window,
                    """
(() => {
  const div = document.getElementById($divid_js);
  return !!div &&
    Array.isArray(div.calcdata) &&
    !!div._fullLayout &&
    window.__plotlysupply_model === null &&
    window.__plotlysupply_plotly_loader === null &&
    window.__plotlysupply_initial_render === null;
})()
""",
                ))
            end
            @test renderer_ready() === true

            resources = getfield(sp, :_resources)
            index_uri = PlotlySupply._file_uri(
                joinpath(resources.tempdir, "index.html"),
            )
            @test Base.invokelatest(
                () -> ec.load(sp.window, index_uri),
            ) === nothing
            @test Base.invokelatest(
                () -> ec.run(
                    sp.window,
                    PlotlySupply._syncplot_readiness_script(),
                ),
            ) == "ok"
            @test renderer_ready() === true
        finally
            # ElectronCall is a hard dependency: a failure above is a test error,
            # and the window is closed either way.
            sp === nothing || close(sp)
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
        @test [t[:x] for t in fig_scatter_multi.data] == x_multi
        @test [t[:y] for t in fig_scatter_multi.data] == y_multi
        @test [t[:mode] for t in fig_scatter_multi.data] == ["markers", "markers"]
        @test [t[:line][:dash] for t in fig_scatter_multi.data] == ["dash", "dot"]
        @test [t[:line][:color] for t in fig_scatter_multi.data] == ["purple", "purple"]
        @test [t[:name] for t in fig_scatter_multi.data] == ["bundle", "bundle"]

        # y-only vector-of-vectors branch: implicit 0-based x, unnamed series
        fig_scatter_yonly = plot_scatter(y_multi)
        @test [t[:y] for t in fig_scatter_yonly.data] == y_multi
        @test all(t -> t[:x] == 0:3 && t[:name] == "" && t[:showlegend] == false,
            fig_scatter_yonly.data)

        # plot_stem branches: x/y vectors and fontsize path
        fig_stem_multi = plot_stem(x_multi, y_multi; color="black", legend="stem", fontsize=10)
        heads, stems = _stem_parts(fig_stem_multi)
        @test [t[:x] for t in heads] == x_multi
        @test [t[:y] for t in heads] == y_multi
        @test [t[:name] for t in heads] == ["stem", "stem"]
        @test [t[:marker][:color] for t in heads] == ["black", "black"]
        @test [t[:legendgroup] for t in heads] == [t[:legendgroup] for t in stems]
        @test _lookup(fig_stem_multi.layout, :font, :size) == 10
        fig_stem_yonly = plot_stem(y_multi)
        heads_y, _ = _stem_parts(fig_stem_yonly)
        @test [t[:y] for t in heads_y] == y_multi
        @test all(t -> t[:x] == 0:3, heads_y)

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
        @test [t[:theta] for t in fig_polar_multi.data] == theta_multi
        @test [t[:r] for t in fig_polar_multi.data] == r_multi
        @test [t[:mode] for t in fig_polar_multi.data] == ["lines", "markers"]
        @test [t[:line][:dash] for t in fig_polar_multi.data] == ["dash", "dot"]
        @test [t[:line][:color] for t in fig_polar_multi.data] == ["red", "red"]
        @test [t[:name] for t in fig_polar_multi.data] == ["polar", "polar"]
        @test _lookup(fig_polar_multi.layout, :font, :size) == 11

        # heatmap/contour on a single-column / single-row grid (no spacing to
        # infer) with an equal aspect ratio and fontsize
        U13 = rand(1, 3)
        U31 = rand(3, 1)
        fig_heat_dx0 = plot_heatmap([0.0], [0.0, 1.0, 2.0], U13; equalar=true, fontsize=9)
        fig_heat_dy0 = plot_heatmap([0.0, 1.0, 2.0], [0.0], U31; equalar=true)
        _test_field_trace(only(fig_heat_dx0.data), "heatmap", [0.0], [0.0, 1.0, 2.0], U13)
        _test_field_trace(only(fig_heat_dy0.data), "heatmap", [0.0, 1.0, 2.0], [0.0], U31)

        fig_contour_dx0 = plot_contour([0.0], [0.0, 1.0, 2.0], U13; equalar=true, fontsize=9)
        fig_contour_dy0 = plot_contour([0.0, 1.0, 2.0], [0.0], U31; equalar=true)
        _test_field_trace(only(fig_contour_dx0.data), "contour", [0.0], [0.0, 1.0, 2.0], U13)
        _test_field_trace(only(fig_contour_dy0.data), "contour", [0.0, 1.0, 2.0], [0.0], U31)
        for f in (fig_heat_dx0, fig_heat_dy0, fig_contour_dx0, fig_contour_dy0)
            @test _lookup(f.layout, :yaxis, :scaleanchor) == "x"
            @test _lookup(f.layout, :yaxis, :scaleratio) == 1
        end
        @test _lookup(fig_heat_dx0.layout, :font, :size) == 9
        @test _lookup(fig_contour_dx0.layout, :font, :size) == 9

        fig_quiver_font = plot_quiver(1:5, 1:5, rand(5), rand(5); fontsize=10)
        @test only(fig_quiver_font.data)[:type] == "scatter"
        @test _lookup(fig_quiver_font.layout, :font, :size) == 10

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
        tr_default = only(fig_surface_shared_default.data)
        @test tr_default[:coloraxis] == "coloraxis"
        @test tr_default[:surfacecolor] == C
        # an empty colorscale leaves the shared axis on plotly's default scale
        @test !haskey(PlotlySupply._symbol_dict(
            get(fig_surface_shared_default.layout.fields, :coloraxis, nothing)), :colorscale)
        @test _lookup(fig_surface_shared_default.layout, :font, :size) == 10
        tr_scaled = only(fig_surface_shared_scaled.data)
        @test tr_scaled[:coloraxis] == "coloraxis"
        # the colour scale lives on the shared axis, not on the trace
        @test !haskey(tr_scaled.fields, :colorscale)
        @test _lookup(fig_surface_shared_scaled.layout, :coloraxis, :colorscale) ==
              PlotlySupply._resolve_colorscale("Viridis"; who="plot_surface").scale

        # plot_scatter3d multi branch with fill! paths for mode/color/legend
        x3 = [collect(1:4), collect(1:4)]
        y3 = [collect(1:4), collect(1:4)]
        z3 = [rand(4), rand(4)]
        fig_scatter3d_multi_fill = plot_scatter3d(x3, y3, z3; mode="lines+markers", color="orange", legend="traj", fontsize=10)
        @test [t[:z] for t in fig_scatter3d_multi_fill.data] == z3
        @test [t[:mode] for t in fig_scatter3d_multi_fill.data] == ["lines+markers", "lines+markers"]
        @test [t[:line][:color] for t in fig_scatter3d_multi_fill.data] == ["orange", "orange"]
        @test [t[:name] for t in fig_scatter3d_multi_fill.data] == ["traj", "traj"]
        @test _lookup(fig_scatter3d_multi_fill.layout, :font, :size) == 10

        fig_quiver3d_font = plot_quiver3d(1:5, 1:5, 1:5, rand(5), rand(5), rand(5); fontsize=10)
        @test only(fig_quiver3d_font.data)[:type] == "cone"
        @test _lookup(fig_quiver3d_font.layout, :font, :size) == 10
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
        @test length(fig_scatter.data) == 1 + 2 + 2
        bundle = fig_scatter.data[2:3]
        @test [t[:x] for t in bundle] == x_multi
        @test [t[:y] for t in bundle] == y_multi
        @test [t[:mode] for t in bundle] == ["markers", "lines"]
        @test [t[:line][:dash] for t in bundle] == ["dash", "dot"]
        @test [t[:line][:color] for t in bundle] == ["purple", "purple"]
        @test [t[:name] for t in bundle] == ["bundle", "bundle"]
        @test [t[:y] for t in fig_scatter.data[4:5]] == y_multi
        @test all(t -> t[:x] == 0:3, fig_scatter.data[4:5])
        _test_cartesian_options(fig_scatter; title="scatter mut", xlabel="x", ylabel="y",
            xrange=[0, 4], yrange=[0, 1], width=420, height=320, fontsize=9, showgrid=false)

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
        @test length(fig_stem.data) == 2 + 4 + 4
        heads, stems = _stem_parts(Plot(fig_stem.data[3:6]))
        @test [t[:x] for t in heads] == x_multi
        @test [t[:y] for t in heads] == y_multi
        @test [t[:name] for t in heads] == ["stem", "stem"]
        @test [t[:line][:color] for t in stems] == ["black", "black"]
        heads_y, _ = _stem_parts(Plot(fig_stem.data[7:10]))
        @test [t[:y] for t in heads_y] == y_multi
        @test all(t -> t[:x] == 0:3, heads_y)
        _test_cartesian_options(fig_stem; title="stem mut", xlabel="x", ylabel="y",
            xrange=[0, 4], yrange=[0, 1], width=420, height=320, fontsize=9, showgrid=false)

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
        @test length(fig_polar.data) == 1 + 2 + 2
        multi = fig_polar.data[2:3]
        @test [t[:theta] for t in multi] == theta_multi
        @test [t[:r] for t in multi] == r_multi
        @test [t[:mode] for t in multi] == ["lines", "markers"]
        @test [t[:line][:dash] for t in multi] == ["dash", "dot"]
        @test [t[:line][:color] for t in multi] == ["red", "red"]
        mixed = fig_polar.data[4:5]
        @test all(t -> t[:theta] == 0:30:90, mixed)
        @test [t[:r] for t in mixed] == r_multi
        @test [t[:mode] for t in mixed] == ["lines+markers", "lines+markers"]
        @test [t[:line][:dash] for t in mixed] == ["dash", "dash"]
        @test [t[:line][:color] for t in mixed] == ["teal", "brown"]
        @test [t[:name] for t in mixed] == ["r1", "r2"]
        @test _lookup(fig_polar.layout, :polar, :sector) == [0, 120]
        @test _lookup(fig_polar.layout, :polar, :radialaxis, :range) == [0, 1]
        @test _lookup(fig_polar.layout, :polar, :radialaxis, :showgrid) == false
        @test _lookup(fig_polar.layout, :polar, :angularaxis, :showgrid) == false
        _test_cartesian_options(fig_polar; title="polar mut", width=420, height=320, fontsize=9)

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

        for (f, type, title) in ((fig_heat, "heatmap", "heat mut"), (fig_cont, "contour", "cont mut"))
            @test length(f.data) == 3
            _test_field_trace(f.data[2], type, [0.0], [0.0, 1.0, 2.0], U13)
            @test (f.data[2][:zmin], f.data[2][:zmax]) == (0, 1)
            _test_field_trace(f.data[3], type, 0:2, 0:0, U31)
            # the last mutator's xlabel wins; the others persist
            _test_cartesian_options(f; title, xlabel="x2", ylabel="y", xrange=[0, 1],
                yrange=[0, 2], width=400, height=300, fontsize=9)
            @test _lookup(f.layout, :yaxis, :scaleanchor) == "x"
        end

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
        @test length(fig_quiver.data) == 2
        @test fig_quiver.data[2][:line][:color] == "green"
        _test_cartesian_options(fig_quiver; title="q mut", xlabel="x", ylabel="y",
            xrange=[0, 6], yrange=[0, 6], width=400, height=300, fontsize=9, showgrid=false)

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
        @test length(fig_surface.data) == 3
        # shared_coloraxis binds every surface of the figure to one colour axis
        @test all(t -> t[:coloraxis] == "coloraxis", fig_surface.data)
        @test all(t -> t[:surfacecolor] == C, fig_surface.data[2:3])
        @test _lookup(fig_surface.layout, :coloraxis, :colorscale) ==
              PlotlySupply._resolve_colorscale("Viridis"; who="plot_surface!").scale
        _test_scene_options(fig_surface; xrange=[0, 4], yrange=[0, 4], zrange=[0, 1],
            showgrid=false, visible=false)
        _test_cartesian_options(fig_surface; title="s mut", width=420, height=320, fontsize=9)

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
        @test length(fig_s3.data) == 3
        @test [t[:z] for t in fig_s3.data[2:3]] == z3
        @test [t[:mode] for t in fig_s3.data[2:3]] == ["markers", "lines"]
        @test [t[:line][:color] for t in fig_s3.data[2:3]] == ["orange", "orange"]
        @test [t[:name] for t in fig_s3.data[2:3]] == ["traj", "traj"]
        _test_scene_options(fig_s3; xrange=[0, 5], yrange=[0, 5], zrange=[0, 1],
            aspectmode="cube", showgrid=false, visible=false)
        @test _lookup(fig_s3.layout, :scene, :camera, :projection, :type) == "orthographic"
        _test_cartesian_options(fig_s3; title="s3 mut", width=420, height=320, fontsize=9)

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
        @test length(fig_q3.data) == 2
        @test fig_q3.data[2][:colorscale] == [[0, "magenta"], [1, "magenta"]]
        _test_scene_options(fig_q3; xrange=[0, 5], yrange=[0, 5], zrange=[0, 5],
            aspectmode="cube", showgrid=false, visible=false)
        @test _lookup(fig_q3.layout, :scene, :camera, :projection, :type) == "orthographic"
        _test_cartesian_options(fig_q3; title="q3 mut", width=420, height=320, fontsize=9)
    end

    @testset "Coverage Branches - Internal + SyncPlot" begin
        @test_throws ArgumentError PlotlySupply._plot_obj(1)

        html_bytes = savefig(plot_scatter(1:3, rand(3)); format="html")
        @test length(html_bytes) > 0

        # Image export renders in the hidden Electron export window (ElectronCall
        # is a hard dependency, so a renderer failure is a test error). Check each
        # format's signature and the requested pixel size, not just "non-empty".
        export_fig = plot_scatter(1:3, [1.0, 3.0, 2.0])
        svg_text = String(savefig(export_fig; format="svg", width=400, height=300))
        @test startswith(svg_text, "<svg")
        @test occursin(r"<svg[^>]*\bwidth=\"400\"", svg_text)
        @test occursin(r"<svg[^>]*\bheight=\"300\"", svg_text)
        @test occursin("class=\"scatterlayer", svg_text)
        png_bytes = savefig(export_fig; format="png", width=400, height=300)
        @test png_bytes[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        @test String(png_bytes[13:16]) == "IHDR"
        @test ntoh(reinterpret(UInt32, png_bytes[17:20])[1]) == 400
        @test ntoh(reinterpret(UInt32, png_bytes[21:24])[1]) == 300
        jpeg_bytes = savefig(export_fig; format="jpeg", width=400, height=300)
        @test jpeg_bytes[1:3] == UInt8[0xff, 0xd8, 0xff]
        @test jpeg_bytes[end-1:end] == UInt8[0xff, 0xd9]
        pdf_bytes = savefig(
            plot_heatmap(1:3, 1:2, [1.0 2.0; 3.0 4.0; 5.0 6.0]);
            format="pdf",
            width=400,
            height=300,
        )
        @test String(pdf_bytes[1:5]) == "%PDF-"
        @test occursin("%%EOF", String(pdf_bytes[max(1, end - 1023):end]))

        # JSON export
        json_bytes = savefig(plot_scatter(1:3, rand(3)); format="json")
        @test length(json_bytes) > 0

        # EPS (2.0) is converted from the PDF export by Ghostscript; without
        # Ghostscript it is rejected with install guidance before rendering.
        has_ghostscript = try
            PlotlySupply._ghostscript_command()
            true
        catch err
            err isa ArgumentError || rethrow()
            false
        end
        if has_ghostscript
            eps_bytes = savefig(plot_scatter(1:3, rand(3)); format="eps")
            @test startswith(String(eps_bytes), "%!PS-Adobe")
        else
            @test_throws ArgumentError savefig(plot_scatter(1:3, rand(3)); format="eps")
        end

        # Regression: NaN separators (used by quiver-like traces) should still export.
        p_nan = Plot(scatter(x=[1.0, 2.0, NaN, 3.0], y=[1.0, 2.0, NaN, 3.0]), Layout(title="nan-export"))
        svg_nan = String(savefig(p_nan; format="svg"))
        @test startswith(svg_nan, "<svg")
        @test occursin("nan-export", svg_nan)
        # The NaN splits the line into two drawn segments (two "M" moves).
        line_paths = [m.captures[1] for m in eachmatch(r"<path class=\"js-line\" d=\"([^\"]*)\"", svg_nan)]
        @test !isempty(line_paths)
        @test sum(d -> count(==('M'), d), line_paths) == 2

        html_fn = tempname() * ".html"
        savefig(html_fn, plot_scatter(1:3, rand(3)); format="html")
        @test isfile(html_fn)
        @test occursin("<html", lowercase(read(html_fn, String)))

        mg = mgrid(1:2, 1:3)
        @test length(mg) == 2
        @test size(mg[1]) == (2, 3)
        @test size(mg[2]) == (2, 3)

        # SyncPlot entry points and mutators on real hidden windows. ElectronCall
        # is a hard dependency, so any exception is a test error; every window
        # opened here is closed in the `finally`, also when an assertion fails.
        opened = SyncPlot[]
        keep!(sp) = (push!(opened, sp); sp)
        function live(sp, expression)
            divid_js = PlotlySupply._json_js(sp.divid)
            backend = PlotlySupply._syncplot_backend(sp)
            return Base.invokelatest(() -> backend.run(
                sp.window,
                "(() => { const d = document.getElementById($divid_js); " *
                "return JSON.stringify($expression); })()",
            ))
        end
        live_title(sp) = live(sp, "d._fullLayout.title.text")
        live_y(sp) = live(sp, "d.data.map(t => Array.from(t.y))")
        try
            sp = keep!(to_syncplot(plot_scatter(1:4, [4.0, 3.0, 2.0, 1.0]); show=false, title="coverage-sync"))
            @test sp isa SyncPlot
            @test to_syncplot(sp) === sp
            @test PlotlySupply._plot_obj(sp) === sp.plot
            @test isopen(sp) === true
            @test startswith(sprint(show, sp), "SyncPlot(open")
            @test msgchannel(sp) isa Channel

            # plot(...) compatibility entry points
            sp1 = keep!(plot(scatter(x=[1, 2], y=[2, 1]); sync=true, show=false, title="p1"))
            sp2 = keep!(plot([scatter(x=[1, 2], y=[1, 2])]; sync=true, show=false, title="p2"))
            sp3 = keep!(plot(scatter(x=[1], y=[1]), scatter(x=[1], y=[2]); sync=true, show=false, title="p3"))
            sp4 = keep!(plot(; layout=Layout(title="empty"), sync=true, show=false, title="p4"))
            sp5 = keep!(plot(Plot(scatter(x=[1, 2], y=[2, 1]), Layout(title="fig")); sync=true, show=false, title="p5"))
            raw = plot(scatter(x=[1, 2], y=[2, 1]); sync=false, title="raw")
            @test all(s -> s isa SyncPlot && isopen(s), (sp1, sp2, sp3, sp4, sp5))
            @test raw isa Plot
            @test sp1.plot.data[1][:y] == [2, 1]
            @test live_y(sp1) == "[[2,1]]"
            @test length(sp3.plot.data) == 2
            @test live(sp3, "d.data.length") == "2"
            @test isempty(sp4.plot.data)
            @test live_title(sp4) == "\"empty\""
            @test live_title(sp5) == "\"fig\""

            # Sync mutating wrappers: each commits to the model and the window.
            @test react!(sp, [scatter(x=[1, 2], y=[2, 1])], Layout(title="react1")) === sp
            @test sp.plot.data[1][:y] == [2, 1]
            @test live_title(sp) == "\"react1\""
            replacement = Plot(scatter(x=[1, 2], y=[1, 2]), Layout(title="react2"))
            @test react!(sp, replacement) === sp
            @test sp.plot === replacement
            @test live_title(sp) == "\"react2\""
            @test relayout!(sp, title="layout") === sp
            @test live_title(sp) == "\"layout\""
            @test restyle!(sp, marker=attr(size=8)) === sp
            @test sp.plot.data[1][:marker][:size] == 8
            @test live(sp, "d._fullData[0].marker.size") == "8"
            @test addtraces!(sp, scatter(x=[1, 2], y=[3, 4])) === sp
            @test length(sp.plot.data) == 2
            @test movetraces!(sp, 1) === sp
            @test [t[:y] for t in sp.plot.data] == [[3, 4], [1, 2]]
            @test live_y(sp) == "[[3,4],[1,2]]"
            @test extendtraces!(sp, Dict(:y => [[5, 6]]), [1], -1) === sp
            @test prependtraces!(sp, Dict(:y => [[0]]), [1], -1) === sp
            @test sp.plot.data[1][:y] == [0, 3, 4, 5, 6]
            @test live_y(sp) == "[[0,3,4,5,6],[1,2]]"
            @test update!(sp, Dict(:name => "updated"), layout=Layout(title="updated")) === sp
            @test all(t -> t[:name] == "updated", sp.plot.data)
            @test live_title(sp) == "\"updated\""
            @test live(sp, "d.data.map(t => t.name)") == "[\"updated\",\"updated\"]"
            @test update_xaxes!(sp, range=[0, 3]) === sp
            @test update_yaxes!(sp, range=[0, 6]) === sp
            @test sp.plot.layout[:xaxis][:range] == [0, 3]
            @test sp.plot.layout[:yaxis][:range] == [0, 6]
            @test live(sp, "[d._fullLayout.xaxis.range, d._fullLayout.yaxis.range]") == "[[0,3],[0,6]]"
            @test update_polars!(sp, radialaxis=attr(range=[0, 2])) === sp
            @test deletetraces!(sp, length(sp.plot.data)) === sp
            @test length(sp.plot.data) == 1
            @test add_trace!(sp, scatter(x=[0], y=[0])) === sp
            @test live_y(sp) == "[[0,3,4,5,6],[0]]"
            @test redraw!(sp) === sp
            @test live(sp, "d.data.length") == "2"
            @test !getfield(sp, :_resources).renderer_desynchronized

            sp_relayout = keep!(relayout(sp, title="copy"))
            @test sp_relayout isa SyncPlot && sp_relayout !== sp
            @test live_title(sp_relayout) == "\"copy\""
            @test live_title(sp) == "\"updated\""

            # fallback false branch in isopen catch
            bogus = SyncPlot(Plot(scatter(y=[1])), nothing, nothing, "bogus")
            @test !isopen(bogus)
            @test PlotlySupply._syncplot_app((bogus,)) === nothing

            # concat overloads place both sources side by side / stacked.
            hsp = keep!(hcat(sp1, sp2))
            vsp = keep!(vcat(sp1, sp2))
            hvsp = keep!(hvcat((1, 1), sp1, sp2))
            for joined in (hsp, vsp, hvsp)
                @test joined isa SyncPlot && isopen(joined)
                @test [t[:y] for t in joined.plot.data] == [[2, 1], [1, 2]]
                @test live(joined, "d.data.length") == "2"
            end
            @test live(hsp, "d._fullLayout.xaxis2.domain[0] > d._fullLayout.xaxis.domain[1]") == "true"
            @test live(vsp, "d._fullLayout.yaxis.domain[0] > d._fullLayout.yaxis2.domain[1]") == "true"
        finally
            for opened_sp in opened
                close(opened_sp)
            end
        end
        @test all(s -> !isopen(s), opened)
    end

    # ============================================================
    # New feature tests: xscale/yscale, marker_size/marker_symbol, showlegend
    # ============================================================

    @testset "xscale/yscale - scatter" begin
        x = 1:10
        y = rand(10) .+ 0.1
        fig = plot_scatter(x, y, xscale="log", yscale="log")
        _test_log_axes(fig; x=true, y=true)
        # data stay in data units; only the axes are logarithmic
        @test only(fig.data)[:x] == x && only(fig.data)[:y] == y

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, xscale="log")
        _test_log_axes(fig2; x=true, y=false)
        @test [t[:y] for t in fig2.data] == y2

        # y-only variant
        fig3 = plot_scatter(y, yscale="log")
        _test_log_axes(fig3; x=false, y=true)
        @test only(fig3.data)[:x] == 0:9 && only(fig3.data)[:y] == y

        fig3m = plot_scatter(y2, xscale="log", yscale="log")
        _test_log_axes(fig3m; x=true, y=true)
        @test [t[:y] for t in fig3m.data] == y2
    end

    @testset "marker_size/marker_symbol - scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, mode="markers", marker_size=10, marker_symbol="circle-open")
        @test only(fig.data)[:mode] == "markers"
        @test _marker_sizes(fig.data) == [10]
        @test _marker_symbols(fig.data) == ["circle-open"]

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, mode="markers", marker_size=[8, 12], marker_symbol=["circle", "square"])
        @test _marker_sizes(fig2.data) == [8, 12]
        @test _marker_symbols(fig2.data) == ["circle", "square"]

        # scalar marker on multi-trace
        fig3 = plot_scatter(x, y2, mode="markers", marker_size=6, marker_symbol="diamond")
        @test _marker_sizes(fig3.data) == [6, 6]
        @test _marker_symbols(fig3.data) == ["diamond", "diamond"]

        # y-only with markers
        fig4 = plot_scatter(y, mode="markers", marker_size=5)
        @test _marker_sizes(fig4.data) == [5]
        @test only(fig4.data)[:x] == 0:9
    end

    @testset "showlegend - scatter" begin
        x = 1:10
        y = rand(10)
        fig = plot_scatter(x, y, showlegend=false)
        @test _showlegends(fig.data) == [false]

        y2 = [rand(10), rand(10)]
        fig2 = plot_scatter(x, y2, showlegend=[true, false])
        @test _showlegends(fig2.data) == [true, false]
        @test fig2.layout[:showlegend] == true

        fig3 = plot_scatter(x, y2, showlegend=true)
        @test _showlegends(fig3.data) == [true, true]

        # y-only
        fig4 = plot_scatter(y2, showlegend=[false, true])
        @test _showlegends(fig4.data) == [false, true]
        @test [t[:y] for t in fig4.data] == y2
    end

    @testset "xscale/yscale - stem" begin
        x = 1:10
        y = rand(10) .+ 0.1
        fig = plot_stem(x, y, xscale="log", yscale="log")
        _test_log_axes(fig; x=true, y=true)
        heads, _ = _stem_parts(fig)
        @test only(heads)[:x] == x && only(heads)[:y] == y

        y2 = [rand(10), rand(10)]
        fig2 = plot_stem(x, y2, xscale="log")
        _test_log_axes(fig2; x=true, y=false)
        @test [t[:y] for t in first(_stem_parts(fig2))] == y2

        fig3 = plot_stem(y, yscale="log")
        _test_log_axes(fig3; x=false, y=true)
        @test only(first(_stem_parts(fig3)))[:x] == 0:9
    end

    @testset "showlegend - stem" begin
        # a series' legend entry is its head (marker) trace; stems never show
        x = 1:10
        y2 = [rand(10), rand(10)]
        fig = plot_stem(x, y2, showlegend=[true, false])
        heads, stems = _stem_parts(fig)
        @test _showlegends(heads) == [true, false]
        @test _showlegends(stems) == [false, false]

        fig2 = plot_stem(x, y2, showlegend=true)
        @test _showlegends(first(_stem_parts(fig2))) == [true, true]

        # single trace
        fig3 = plot_stem(x, rand(10), showlegend=false)
        @test _showlegends(first(_stem_parts(fig3))) == [false]

        # y-only
        fig4 = plot_stem(y2, showlegend=[false, true])
        heads4, _ = _stem_parts(fig4)
        @test _showlegends(heads4) == [false, true]
        @test [t[:y] for t in heads4] == y2
    end

    @testset "xscale/yscale/showlegend - bar" begin
        x = 1:5
        y = rand(5) .+ 0.1
        fig = plot_bar(x, y, xscale="log", yscale="log")
        _test_log_axes(fig; x=true, y=true)
        @test only(fig.data)[:type] == "bar"
        @test only(fig.data)[:y] == y

        y2 = [rand(5), rand(5)]
        fig2 = plot_bar(x, y2, showlegend=[true, false], xscale="log")
        _test_log_axes(fig2; x=true, y=false)
        @test _showlegends(fig2.data) == [true, false]

        fig3 = plot_bar(x, y2, showlegend=true)
        @test _showlegends(fig3.data) == [true, true]

        fig4 = plot_bar(x, y, showlegend=false)
        @test _showlegends(fig4.data) == [false]

        # y-only
        fig5 = plot_bar(y, xscale="log", yscale="log", showlegend=false)
        _test_log_axes(fig5; x=true, y=true)
        @test _showlegends(fig5.data) == [false]

        fig6 = plot_bar(y2, showlegend=[true, false])
        @test _showlegends(fig6.data) == [true, false]
        @test all(t -> t[:x] == 0:4, fig6.data)
    end

    @testset "xscale/yscale/showlegend - histogram" begin
        # On a log x axis the histogram is binned in log10 and drawn as bars
        # (binning details: regression_stats.jl).
        x = exp.(randn(200))
        fig = plot_histogram(x, xscale="log", yscale="log")
        _test_log_axes(fig; x=true, y=true)
        @test only(fig.data)[:type] == "bar"
        @test sum(only(fig.data)[:y]) == length(x)

        xmulti = [randn(100), randn(100) .+ 1.0]
        fig2 = plot_histogram(xmulti, showlegend=[true, false])
        @test [t[:type] for t in fig2.data] == ["histogram", "histogram"]
        @test _showlegends(fig2.data) == [true, false]

        fig3 = plot_histogram(xmulti, showlegend=true)
        @test _showlegends(fig3.data) == [true, true]

        fig4 = plot_histogram(x, showlegend=false)
        @test _showlegends(fig4.data) == [false]
        @test only(fig4.data)[:x] == x
    end

    @testset "xscale/yscale/showlegend - box" begin
        x = fill("A", 20)
        y = rand(20) .+ 0.1
        fig = plot_box(x, y, xscale="log", yscale="log")
        _test_log_axes(fig; x=true, y=true)
        @test only(fig.data)[:y] == y

        y2 = [randn(20), randn(20)]
        x2 = [fill("A", 20), fill("B", 20)]
        fig2 = plot_box(x2, y2, showlegend=[true, false])
        @test _showlegends(fig2.data) == [true, false]
        @test [t[:x] for t in fig2.data] == x2

        fig3 = plot_box(x, y, showlegend=false)
        @test _showlegends(fig3.data) == [false]

        # y-only
        fig4 = plot_box(y2, xscale="log", showlegend=[true, false])
        _test_log_axes(fig4; x=true, y=false)
        @test _showlegends(fig4.data) == [true, false]
        @test [t[:y] for t in fig4.data] == y2

        fig5 = plot_box(y, showlegend=false)
        @test _showlegends(fig5.data) == [false]

        fig6 = plot_box(y2, showlegend=true)
        @test _showlegends(fig6.data) == [true, true]
    end

    @testset "xscale/yscale/showlegend - violin" begin
        x = fill("A", 20)
        y = rand(20) .+ 0.1
        fig = plot_violin(x, y, xscale="log", yscale="log")
        _test_log_axes(fig; x=true, y=true)
        @test only(fig.data)[:y] == y

        y2 = [rand(20) .+ 0.1, rand(20) .+ 0.1]
        x2 = [fill("A", 20), fill("B", 20)]
        fig2 = plot_violin(x2, y2, showlegend=[true, false])
        @test _showlegends(fig2.data) == [true, false]
        @test [t[:x] for t in fig2.data] == x2

        fig3 = plot_violin(x, y, showlegend=false)
        @test _showlegends(fig3.data) == [false]

        # y-only
        fig4 = plot_violin(y2, yscale="log", showlegend=[false, true])
        _test_log_axes(fig4; x=false, y=true)
        @test _showlegends(fig4.data) == [false, true]
        @test [t[:y] for t in fig4.data] == y2

        fig5 = plot_violin(y, showlegend=false)
        @test _showlegends(fig5.data) == [false]

        fig6 = plot_violin(y2, showlegend=true)
        @test _showlegends(fig6.data) == [true, true]
    end

    @testset "xscale/yscale - heatmap" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_heatmap(x, y, U, xscale="log", yscale="log")
        _test_log_axes(fig; x=true, y=true)
        _test_field_trace(only(fig.data), "heatmap", x, y, U)

        # implicit coordinates are 1-based on a log axis (0 cannot be drawn)
        fig2 = plot_heatmap(U, xscale="log")
        _test_log_axes(fig2; x=true, y=false)
        _test_field_trace(only(fig2.data), "heatmap", 1:10, 0:19, U)
    end

    @testset "xscale/yscale - contour" begin
        x = 1:10
        y = 1:20
        U = rand(10, 20)
        fig = plot_contour(x, y, U, xscale="log", yscale="log")
        _test_log_axes(fig; x=true, y=true)
        _test_field_trace(only(fig.data), "contour", x, y, U)

        fig2 = plot_contour(U, yscale="log")
        _test_log_axes(fig2; x=false, y=true)
        _test_field_trace(only(fig2.data), "contour", 0:9, 1:20, U)
    end

    @testset "marker_size/marker_symbol/showlegend - scatterpolar" begin
        theta = 0:10:350
        r = rand(36)
        fig = plot_scatterpolar(theta, r, mode="markers", marker_size=8, marker_symbol="circle-open")
        @test only(fig.data)[:mode] == "markers"
        @test _marker_sizes(fig.data) == [8]
        @test _marker_symbols(fig.data) == ["circle-open"]

        r2 = [rand(36), rand(36)]
        fig2 = plot_scatterpolar(theta, r2, marker_size=[6, 10], marker_symbol=["circle", "square"], showlegend=[true, false])
        @test _marker_sizes(fig2.data) == [6, 10]
        @test _marker_symbols(fig2.data) == ["circle", "square"]
        @test _showlegends(fig2.data) == [true, false]

        fig3 = plot_scatterpolar(theta, r2, showlegend=true, marker_size=5)
        @test _showlegends(fig3.data) == [true, true]
        @test _marker_sizes(fig3.data) == [5, 5]

        fig4 = plot_scatterpolar(theta, r, showlegend=false)
        @test _showlegends(fig4.data) == [false]
    end

    @testset "marker_size/marker_symbol/showlegend - scatter3d" begin
        x = 1:10
        y = 1:10
        z = rand(10)
        fig = plot_scatter3d(x, y, z, mode="markers", marker_size=8, marker_symbol="circle-open")
        @test only(fig.data)[:mode] == "markers"
        @test _marker_sizes(fig.data) == [8]
        @test _marker_symbols(fig.data) == ["circle-open"]

        z2 = [rand(10), rand(10)]
        x2 = [1:10, 1:10]
        y2 = [1:10, 1:10]
        fig2 = plot_scatter3d(x2, y2, z2, marker_size=[6, 10], marker_symbol=["circle", "square"], showlegend=[true, false])
        @test _marker_sizes(fig2.data) == [6, 10]
        @test _marker_symbols(fig2.data) == ["circle", "square"]
        @test _showlegends(fig2.data) == [true, false]

        fig3 = plot_scatter3d(x2, y2, z2, showlegend=true, marker_size=5)
        @test _showlegends(fig3.data) == [true, true]
        @test _marker_sizes(fig3.data) == [5, 5]

        fig4 = plot_scatter3d(x, y, z, showlegend=false)
        @test _showlegends(fig4.data) == [false]
    end

    @testset "mutating variants - new features" begin
        # scatter!
        fig = plot_scatter(1:10, rand(10))
        plot_scatter!(fig, 1:10, rand(10), xscale="log", yscale="log", marker_size=5, marker_symbol="square", showlegend=false)
        _test_log_axes(fig; x=true, y=true)
        @test _marker_sizes(fig.data[2:2]) == [5]
        @test _marker_symbols(fig.data[2:2]) == ["square"]
        @test _showlegends(fig.data[2:2]) == [false]

        y2 = [rand(10), rand(10)]
        plot_scatter!(fig, 1:10, y2, marker_size=[4, 8], marker_symbol=["circle", "diamond"], showlegend=[true, false])
        @test _marker_sizes(fig.data[3:4]) == [4, 8]
        @test _marker_symbols(fig.data[3:4]) == ["circle", "diamond"]
        @test _showlegends(fig.data[3:4]) == [true, false]

        plot_scatter!(fig, y2, xscale="log", marker_size=6, showlegend=true)
        @test length(fig.data) == 6
        @test [t[:y] for t in fig.data[5:6]] == y2
        @test _marker_sizes(fig.data[5:6]) == [6, 6]
        @test _showlegends(fig.data[5:6]) == [true, true]
        _test_log_axes(fig; x=true, y=true)   # later calls keep the log axes

        # stem!
        fig2 = plot_stem(1:5, rand(5))
        plot_stem!(fig2, 1:5, rand(5), xscale="log", yscale="log", showlegend=false)
        _test_log_axes(fig2; x=true, y=true)
        @test _showlegends(first(_stem_parts(Plot(fig2.data[3:4])))) == [false]

        plot_stem!(fig2, 1:5, [rand(5), rand(5)], showlegend=[true, false])
        @test _showlegends(first(_stem_parts(Plot(fig2.data[5:8])))) == [true, false]

        y_stem = [rand(5), rand(5)]
        plot_stem!(fig2, y_stem, showlegend=true, xscale="log")
        @test length(fig2.data) == 12
        heads, _ = _stem_parts(Plot(fig2.data[9:12]))
        @test _showlegends(heads) == [true, true]
        @test [t[:y] for t in heads] == y_stem

        # bar!
        fig3 = plot_bar(1:5, rand(5))
        plot_bar!(fig3, 1:5, rand(5), xscale="log", yscale="log", showlegend=false)
        _test_log_axes(fig3; x=true, y=true)
        @test _showlegends(fig3.data[2:2]) == [false]

        plot_bar!(fig3, 1:5, [rand(5), rand(5)], showlegend=[true, false])
        @test _showlegends(fig3.data[3:4]) == [true, false]

        plot_bar!(fig3, [rand(5), rand(5)], xscale="log", showlegend=true)
        @test length(fig3.data) == 6
        @test _showlegends(fig3.data[5:6]) == [true, true]
        @test all(t -> t[:type] == "bar", fig3.data)

        # histogram!: once the x axis is logarithmic, appended histograms are
        # log-binned bars
        fig4 = plot_histogram(randn(100))
        h_log = exp.(randn(100))
        plot_histogram!(fig4, h_log, xscale="log", showlegend=false)
        _test_log_axes(fig4; x=true, y=false)
        @test fig4.data[2][:type] == "bar"
        @test sum(fig4.data[2][:y]) == length(h_log)
        @test _showlegends(fig4.data[2:2]) == [false]

        plot_histogram!(fig4, [exp.(randn(100)), exp.(randn(100))], showlegend=[true, false])
        @test length(fig4.data) == 4
        @test [t[:type] for t in fig4.data[3:4]] == ["bar", "bar"]
        @test _showlegends(fig4.data[3:4]) == [true, false]

        # box!
        fig5 = plot_box(fill("A", 20), randn(20))
        plot_box!(fig5, fill("A", 20), randn(20), xscale="log", showlegend=false)
        _test_log_axes(fig5; x=true, y=false)
        @test _showlegends(fig5.data[2:2]) == [false]

        plot_box!(fig5, [fill("A", 20), fill("B", 20)], [randn(20), randn(20)], showlegend=[true, false])
        @test _showlegends(fig5.data[3:4]) == [true, false]
        @test [t[:x] for t in fig5.data[3:4]] == [fill("A", 20), fill("B", 20)]

        plot_box!(fig5, randn(20), showlegend=false)
        @test _showlegends(fig5.data[5:5]) == [false]

        plot_box!(fig5, [randn(20), randn(20)], showlegend=[true, false])
        @test length(fig5.data) == 7
        @test _showlegends(fig5.data[6:7]) == [true, false]

        # violin!
        fig6 = plot_violin(fill("A", 20), randn(20))
        plot_violin!(fig6, fill("A", 20), rand(20) .+ 0.1, yscale="log", showlegend=false)
        _test_log_axes(fig6; x=false, y=true)
        @test _showlegends(fig6.data[2:2]) == [false]

        plot_violin!(fig6, [fill("A", 20), fill("B", 20)], [randn(20), randn(20)], showlegend=[true, false])
        @test _showlegends(fig6.data[3:4]) == [true, false]

        plot_violin!(fig6, randn(20), showlegend=false)
        @test _showlegends(fig6.data[5:5]) == [false]

        plot_violin!(fig6, [randn(20), randn(20)], showlegend=[true, false])
        @test length(fig6.data) == 7
        @test _showlegends(fig6.data[6:7]) == [true, false]

        # heatmap!: after the axes became log, implicit coordinates are 1-based
        fig7 = plot_heatmap(1:10, 1:20, rand(10, 20))
        U7 = rand(10, 20)
        plot_heatmap!(fig7, 1:10, 1:20, rand(10, 20), xscale="log", yscale="log")
        _test_log_axes(fig7; x=true, y=true)
        plot_heatmap!(fig7, U7, xscale="log")
        @test length(fig7.data) == 3
        _test_field_trace(fig7.data[3], "heatmap", 1:10, 1:20, U7)

        # contour!
        fig8 = plot_contour(1:10, 1:20, rand(10, 20))
        U8 = rand(10, 20)
        plot_contour!(fig8, 1:10, 1:20, rand(10, 20), xscale="log", yscale="log")
        _test_log_axes(fig8; x=true, y=true)
        plot_contour!(fig8, U8, yscale="log")
        @test length(fig8.data) == 3
        _test_field_trace(fig8.data[3], "contour", 1:10, 1:20, U8)

        # scatterpolar!
        fig9 = plot_scatterpolar(0:10:350, rand(36))
        plot_scatterpolar!(fig9, 0:10:350, rand(36), marker_size=8, marker_symbol="square", showlegend=false)
        @test _marker_sizes(fig9.data[2:2]) == [8]
        @test _marker_symbols(fig9.data[2:2]) == ["square"]
        @test _showlegends(fig9.data[2:2]) == [false]

        plot_scatterpolar!(fig9, 0:10:350, [rand(36), rand(36)], marker_size=[4, 8], showlegend=[true, false])
        @test length(fig9.data) == 4
        @test _marker_sizes(fig9.data[3:4]) == [4, 8]
        @test _showlegends(fig9.data[3:4]) == [true, false]

        # scatter3d!
        fig10 = plot_scatter3d(1:10, 1:10, rand(10))
        plot_scatter3d!(fig10, 1:10, 1:10, rand(10), marker_size=8, marker_symbol="square", showlegend=false)
        @test _marker_sizes(fig10.data[2:2]) == [8]
        @test _marker_symbols(fig10.data[2:2]) == ["square"]
        @test _showlegends(fig10.data[2:2]) == [false]

        plot_scatter3d!(fig10, [1:10, 1:10], [1:10, 1:10], [rand(10), rand(10)], marker_size=[4, 8], showlegend=[true, false])
        @test length(fig10.data) == 4
        @test _marker_sizes(fig10.data[3:4]) == [4, 8]
        @test _showlegends(fig10.data[3:4]) == [true, false]
    end

    @testset "scatter x-vector-of-vectors" begin
        x2 = [collect(1:10), collect(1:10)]
        y2 = [rand(10), rand(10)]
        fig = plot_scatter(x2, y2, marker_size=[4, 8], marker_symbol=["circle", "square"], showlegend=[true, false], xscale="log")
        @test [t[:x] for t in fig.data] == x2
        @test [t[:y] for t in fig.data] == y2
        @test _marker_sizes(fig.data) == [4, 8]
        @test _marker_symbols(fig.data) == ["circle", "square"]
        @test _showlegends(fig.data) == [true, false]
        _test_log_axes(fig; x=true, y=false)

        fig2 = plot_scatter(x2, y2, dash=["solid", "dash"])
        @test [t[:line][:dash] for t in fig2.data] == ["solid", "dash"]
    end

    @testset "stem x-vector-of-vectors" begin
        x2 = [collect(1:5), collect(1:5)]
        y2 = [rand(5), rand(5)]
        fig = plot_stem(x2, y2, showlegend=[true, false], xscale="log")
        heads, _ = _stem_parts(fig)
        @test [t[:x] for t in heads] == x2
        @test [t[:y] for t in heads] == y2
        @test _showlegends(heads) == [true, false]
        _test_log_axes(fig; x=true, y=false)
    end

    @testset "scatterpolar theta-vector-of-vectors" begin
        theta2 = [collect(0:10:350), collect(0:10:350)]
        r2 = [rand(36), rand(36)]
        fig = plot_scatterpolar(theta2, r2, marker_size=[4, 8], showlegend=[true, false])
        @test [t[:theta] for t in fig.data] == theta2
        @test [t[:r] for t in fig.data] == r2
        @test _marker_sizes(fig.data) == [4, 8]
        @test _showlegends(fig.data) == [true, false]
    end

    @testset "_apply_showlegend! helper" begin
        # Test the helper directly
        t1 = scatter(x=[1,2], y=[1,2])
        PlotlySupply._apply_showlegend!(t1, nothing)
        # nothing should not change the trace
        @test !haskey(t1.fields, :showlegend)

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
        # 2.0 (C11): anchored to the left edge of the figure container
        @test fig.layout.fields[:legend][:xanchor] == "left"
        @test fig.layout.fields[:legend][:xref] == "container"
        @test fig.layout.fields[:legend][:yanchor] == "top"

        set_legend!(fig; position=:outside_top)
        @test fig.layout.fields[:legend][:xanchor] == "center"
        @test fig.layout.fields[:legend][:yanchor] == "bottom"

        set_legend!(fig; position=:outside_bottom)
        @test fig.layout.fields[:legend][:xanchor] == "center"
        # 2.0 (C11): anchored to the bottom edge of the figure container
        @test fig.layout.fields[:legend][:yanchor] == "bottom"
        @test fig.layout.fields[:legend][:yref] == "container"
    end

    @testset "box/violin shared-x multi-trace (non-!)" begin
        # plot_box with shared x (not vector-of-vectors) and multi y
        x_shared = fill("A", 20)
        y_multi = [randn(20), randn(20) .+ 1.0]
        fig = plot_box(x_shared, y_multi, legend=["g1", "g2"], color=["red", "blue"])
        @test [t[:type] for t in fig.data] == ["box", "box"]
        @test all(t -> t[:x] == x_shared, fig.data)
        @test [t[:y] for t in fig.data] == y_multi
        @test [t[:name] for t in fig.data] == ["g1", "g2"]
        @test [t[:marker][:color] for t in fig.data] == ["red", "blue"]
        # several boxes at one x sit side by side
        @test fig.layout[:boxmode] == "group"

        # plot_violin with shared x and multi y
        fig2 = plot_violin(x_shared, y_multi, legend=["v1", "v2"], color=["red", "blue"])
        @test [t[:type] for t in fig2.data] == ["violin", "violin"]
        @test all(t -> t[:x] == x_shared, fig2.data)
        @test [t[:y] for t in fig2.data] == y_multi
        @test [t[:name] for t in fig2.data] == ["v1", "v2"]
        @test [t[:line][:color] for t in fig2.data] == ["red", "blue"]
        @test fig2.layout[:violinmode] == "group"
    end

    @testset "box!/violin! shared-x multi-trace" begin
        x_shared = fill("A", 20)
        y_multi = [randn(20), randn(20) .+ 1.0]

        # plot_box! with shared x and multi y
        fig = plot_box(randn(20))
        n0 = length(fig.data)
        plot_box!(fig, x_shared, y_multi, legend=["g1", "g2"], color=["red", "blue"])
        @test length(fig.data) == n0 + 2
        @test all(t -> t[:type] == "box" && t[:x] == x_shared, fig.data[end-1:end])
        @test [t[:y] for t in fig.data[end-1:end]] == y_multi
        @test [t[:name] for t in fig.data[end-1:end]] == ["g1", "g2"]
        @test [t[:marker][:color] for t in fig.data[end-1:end]] == ["red", "blue"]
        @test fig.layout[:boxmode] == "group"

        # plot_violin! with shared x and multi y
        fig2 = plot_violin(randn(20))
        n0 = length(fig2.data)
        plot_violin!(fig2, x_shared, y_multi, legend=["v1", "v2"], color=["red", "blue"])
        @test length(fig2.data) == n0 + 2
        @test all(t -> t[:type] == "violin" && t[:x] == x_shared, fig2.data[end-1:end])
        @test [t[:y] for t in fig2.data[end-1:end]] == y_multi
        @test [t[:name] for t in fig2.data[end-1:end]] == ["v1", "v2"]
        @test [t[:line][:color] for t in fig2.data[end-1:end]] == ["red", "blue"]
        @test fig2.layout[:violinmode] == "group"
    end

    @testset "surface!(fig, Z) delegation" begin
        Z = rand(5, 5)
        fig = plot_surface(rand(5, 5))
        n0 = length(fig.data)
        # Z-only variant delegates to X,Y,Z variant internally
        plot_surface!(fig, Z)
        @test length(fig.data) == n0 + 1
        @test fig.data[end][:type] == "surface"
        @test fig.data[end][:z] == Z
        @test fig.data[end][:x] == 0:4 && fig.data[end][:y] == 0:4
    end

    @testset "scatterpolar! vector marker_symbol" begin
        theta = collect(0:10:350)
        r_multi = [rand(36), rand(36)]
        fig = plot_scatterpolar(theta, rand(36))
        n0 = length(fig.data)
        plot_scatterpolar!(fig, theta, r_multi, marker_symbol=["circle", "square"], marker_size=[4, 8], showlegend=[true, false])
        @test length(fig.data) == n0 + 2
        added = fig.data[end-1:end]
        @test [t[:r] for t in added] == r_multi
        @test _marker_symbols(added) == ["circle", "square"]
        @test _marker_sizes(added) == [4, 8]
        @test _showlegends(added) == [true, false]
    end

    @testset "scatterpolar! Bool showlegend (multi-trace)" begin
        theta = collect(0:10:350)
        r_multi = [rand(36), rand(36)]
        fig = plot_scatterpolar(theta, rand(36))
        n0 = length(fig.data)
        plot_scatterpolar!(fig, theta, r_multi, showlegend=false)
        @test length(fig.data) == n0 + 2
        @test _showlegends(fig.data[end-1:end]) == [false, false]
    end

    @testset "scatter3d! vector marker kwargs" begin
        x = [1:5, 1:5]
        y = [1:5, 1:5]
        z = [rand(5), rand(5)]
        fig = plot_scatter3d(1:5, 1:5, rand(5))
        n0 = length(fig.data)
        plot_scatter3d!(fig, x, y, z, marker_size=[4, 8], marker_symbol=["circle", "diamond"], showlegend=[true, false])
        @test length(fig.data) == n0 + 2
        added = fig.data[end-1:end]
        @test [t[:z] for t in added] == z
        @test _marker_sizes(added) == [4, 8]
        @test _marker_symbols(added) == ["circle", "diamond"]
        @test _showlegends(added) == [true, false]
    end

    @testset "scatter3d! Bool showlegend (multi-trace)" begin
        x = [1:5, 1:5]
        y = [1:5, 1:5]
        z = [rand(5), rand(5)]
        fig = plot_scatter3d(1:5, 1:5, rand(5))
        n0 = length(fig.data)
        plot_scatter3d!(fig, x, y, z, showlegend=true)
        @test length(fig.data) == n0 + 2
        @test _showlegends(fig.data[end-1:end]) == [true, true]
    end

    @testset "fontsize in helper-using functions" begin
        # Cover fontsize > 0 branch in _apply_cartesian_plot_options!
        fig = plot_bar(1:5, rand(5), fontsize=14)
        @test _lookup(fig.layout, :font, :size) == 14
        # the default (fontsize = 0) leaves the template's font alone
        @test !haskey(plot_bar(1:5, rand(5)).layout.fields, :font)
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

        # Test getproperty fallback to fig's :plot (sync=false: fig is the Plot)
        @test sf.plot === sf.fig

        # Test getproperty delegation to fig's own properties (covers hasproperty path)
        @test sf.data === sf.plot.data
        @test sf.layout === sf.plot.layout
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
        @test length(sf.plot.data) == 1
        @test (sf.plot.data[1][:xaxis], sf.plot.data[1][:yaxis]) == ("x", "y")
        @test sf.current_row == 1
        @test sf.current_col == 1

        t2 = scatter(x=[3,4], y=[3,4], name="t2")
        t3 = scatter(x=[5,6], y=[5,6], name="t3")
        PlotlyBase.addtraces!(sf, t2, t3; row=1, col=2)
        @test length(sf.plot.data) == 3
        @test [t[:name] for t in sf.plot.data] == ["t1", "t2", "t3"]
        @test all(t -> (t[:xaxis], t[:yaxis]) == ("x2", "y2"), sf.plot.data[2:3])
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

        @test_throws ArgumentError("addtraces!: `row` must be in 1:1; got 2.") PlotlyBase.addtraces!(atomic, valid; row=2, col=1)
        @test isempty(atomic.plot.data)
        @test_throws ArgumentError PlotlyBase.addtraces!(
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
        p = Plot(copy(sf.plot.data), sf.plot.layout)
        sf.fig = _subplot_counting_syncplot(p, "counting")
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

        # Each call lands in the active cell: cells (1,1), (1,2), (1,3), (2,1),
        # (2,2) of a 2x3 grid own the axes x/y, x2/y2, x3/y3, x4/y4, x5/y5.
        axes_of(t) = (t[:xaxis], t[:yaxis])

        # scatter!(sf, y) - y-only
        PlotlySupply.subplot!(sf, 1, 1)
        y_sc = rand(5)
        PlotlySupply.plot_scatter!(sf, y_sc)
        @test length(sf.plot.data) == 1
        @test sf.plot.data[1][:x] == 0:4 && sf.plot.data[1][:y] == y_sc
        @test axes_of(sf.plot.data[1]) == ("x", "y")

        # stem!(sf, y) - y-only: heads + stems traces
        PlotlySupply.subplot!(sf, 1, 2)
        y_st = rand(5)
        PlotlySupply.plot_stem!(sf, y_st)
        @test length(sf.plot.data) == 3
        @test [t[:mode] for t in sf.plot.data[2:3]] == ["markers", "lines"]
        @test sf.plot.data[2][:x] == 0:4 && sf.plot.data[2][:y] == y_st
        @test all(t -> axes_of(t) == ("x2", "y2"), sf.plot.data[2:3])

        # bar!(sf, y) - y-only
        PlotlySupply.subplot!(sf, 1, 3)
        y_bar = rand(5)
        PlotlySupply.plot_bar!(sf, y_bar)
        @test length(sf.plot.data) == 4
        @test sf.plot.data[4][:type] == "bar"
        @test sf.plot.data[4][:x] == 0:4 && sf.plot.data[4][:y] == y_bar
        @test axes_of(sf.plot.data[4]) == ("x3", "y3")

        # box!(sf, x, y) - x,y variant
        PlotlySupply.subplot!(sf, 2, 1)
        y_box = randn(10)
        PlotlySupply.plot_box!(sf, fill("A", 10), y_box)
        @test length(sf.plot.data) == 5
        @test sf.plot.data[5][:type] == "box" && sf.plot.data[5][:y] == y_box
        @test axes_of(sf.plot.data[5]) == ("x4", "y4")

        # violin!(sf, x, y) - x,y variant
        PlotlySupply.subplot!(sf, 2, 2)
        y_vio = randn(10)
        PlotlySupply.plot_violin!(sf, fill("A", 10), y_vio)
        @test length(sf.plot.data) == 6
        @test sf.plot.data[6][:type] == "violin" && sf.plot.data[6][:y] == y_vio
        @test axes_of(sf.plot.data[6]) == ("x5", "y5")
    end

    @testset "SubplotFigure heatmap/contour x,y,U delegations" begin
        sf = PlotlySupply.subplots(1, 2; sync=false)

        # heatmap!(sf, x, y, U) - x,y,U variant
        PlotlySupply.subplot!(sf, 1, 1)
        U_heat = rand(5, 5)
        PlotlySupply.plot_heatmap!(sf, 1:5, 1:5, U_heat)
        @test length(sf.plot.data) == 1
        _test_field_trace(sf.plot.data[1], "heatmap", 1:5, 1:5, U_heat)
        @test (sf.plot.data[1][:xaxis], sf.plot.data[1][:yaxis]) == ("x", "y")

        # contour!(sf, x, y, U) - x,y,U variant
        PlotlySupply.subplot!(sf, 1, 2)
        U_cont = rand(5, 5)
        PlotlySupply.plot_contour!(sf, 1:5, 1:5, U_cont)
        @test length(sf.plot.data) == 2
        _test_field_trace(sf.plot.data[2], "contour", 1:5, 1:5, U_cont)
        @test (sf.plot.data[2][:xaxis], sf.plot.data[2][:yaxis]) == ("x2", "y2")
    end

    @testset "SubplotFigure quiver delegation" begin
        sf = PlotlySupply.subplots(1, 1; sync=false)
        u = rand(5) .+ 0.1
        PlotlySupply.plot_quiver!(sf, collect(1.0:5.0), collect(1.0:5.0), u, rand(5))
        tr = only(sf.plot.data)
        @test (tr[:type], tr[:mode]) == ("scatter", "lines")
        @test [p0 for (p0, _) in _quiver_shafts(tr)] == [(i, i) for i in 1.0:5.0]
        # equal aspect on the cell's axes, as for a standalone quiver
        @test _lookup(sf.plot.layout, :yaxis, :scaleanchor) == "x"
    end

    @testset "SubplotFigure 3D delegations" begin
        scene_specs = Union{Missing, Spec}[Spec(kind="scene") Spec(kind="scene"); Spec(kind="scene") Spec(kind="scene")]
        sf = PlotlySupply.subplots(2, 2; sync=false, specs=scene_specs)

        # surface!(sf, X, Y, Z)
        X = [Float64(i) for i in 1:3, j in 1:3]
        Y = [Float64(j) for i in 1:3, j in 1:3]
        PlotlySupply.subplot!(sf, 1, 1)
        Z1 = rand(3, 3)
        PlotlySupply.plot_surface!(sf, X, Y, Z1)
        @test length(sf.plot.data) == 1
        @test sf.plot.data[1][:z] == Z1 && sf.plot.data[1][:x] == X

        # surface!(sf, Z)
        PlotlySupply.subplot!(sf, 1, 2)
        Z2 = rand(3, 3)
        PlotlySupply.plot_surface!(sf, Z2)
        @test length(sf.plot.data) == 2
        @test sf.plot.data[2][:z] == Z2 && sf.plot.data[2][:x] == 0:2

        # scatter3d!(sf, x, y, z)
        PlotlySupply.subplot!(sf, 2, 1)
        z3 = rand(3)
        PlotlySupply.plot_scatter3d!(sf, collect(1.0:3.0), collect(1.0:3.0), z3)
        @test length(sf.plot.data) == 3
        @test sf.plot.data[3][:z] == z3

        # quiver3d!(sf, x, y, z, u, v, w)
        PlotlySupply.subplot!(sf, 2, 2)
        PlotlySupply.plot_quiver3d!(sf, collect(1.0:3.0), collect(1.0:3.0), collect(1.0:3.0), rand(3), rand(3), rand(3))
        @test length(sf.plot.data) == 4

        # one scene per cell, row-major
        @test [t[:type] for t in sf.plot.data] == ["surface", "surface", "scatter3d", "cone"]
        @test [t[:scene] for t in sf.plot.data] == ["scene", "scene2", "scene3", "scene4"]
    end

    @testset "SubplotFigure polar delegation" begin
        polar_specs = Union{Missing, Spec}[Spec(kind="polar");;]
        sf = PlotlySupply.subplots(1, 1; sync=false, specs=polar_specs)

        theta = collect(0.0:30.0:330.0)
        r = rand(12)
        PlotlySupply.plot_scatterpolar!(sf, theta, r)
        tr = only(sf.plot.data)
        @test (tr[:type], tr[:subplot]) == ("scatterpolar", "polar")
        @test tr[:theta] == theta && tr[:r] == r
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
        # 2.0 (C14): the hidden tick0 = min(data) is gone, and so is its helper.
        @test !isdefined(PlotlySupply, :_safe_tick0)
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
        f = plot_scatter(Float64[])
        @test only(f.data)[:type] == "scatter"
        @test isempty(only(f.data)[:x]) && isempty(only(f.data)[:y])
        heads, stems = _stem_parts(plot_stem(Float64[]))
        @test isempty(only(heads)[:y]) && isempty(only(stems)[:y])
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
        b = plot_box([1, 2, 3], [[1.0, 2, 3], [4.0, 5, 6]]; points=true)
        @test b.data[1].fields[:boxpoints] == "all"
        @test b.layout.fields[:boxmode] == "group"
        v = plot_violin([1, 2, 3], [[1.0, 2, 3], [4.0, 5, 6]]; points=true)
        @test v.data[1].fields[:points] == "all"
        @test v.layout.fields[:violinmode] == "group"
    end

    @testset "CRC: heatmap/contour omit empty colorscale, keep given one" begin
        @test !haskey(plot_heatmap(rand(3, 3)).data[1].fields, :colorscale)
        @test plot_heatmap(rand(3, 3); colorscale="Viridis").data[1].fields[:colorscale] ==
              PlotlySupply._resolve_colorscale("Viridis"; who="plot_heatmap").scale
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
        @test xs[3] === nothing && ys[3] === nothing
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
            @test all(z -> z === nothing || isfinite(z), xv)
            @test all(z -> z === nothing || isfinite(z), yv)
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
        f_template = f.layout.fields[:template]
        plot_scatter!(f, 1:5, rand(5))
        @test f_template === PlotlyBase.templates[:plotly_dark]
        @test f.layout.fields[:template] === f_template
        g = plot_bar(1:3, rand(3)); set_template!(g, "seaborn"); plot_bar!(g, 1:3, rand(3))
        @test g.layout.fields[:template] === PlotlyBase.templates[:seaborn]
        h = plot_heatmap(rand(3, 3)); set_template!(h, "plotly_dark"); plot_heatmap!(h, rand(3, 3))
        @test h.layout.fields[:template] ===
            PlotlyBase.templates[:plotly_dark]
    end

    @testset "CRC: _apply_showlegend! tolerates over-long vector" begin
        # entries beyond the number of series are ignored
        @test _showlegends(plot_bar([1, 2, 3]; showlegend=[true, false, true, false]).data) == [true]
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

    @testset "CRC: _file_uri percent-encodes unsafe path bytes" begin
        @test PlotlySupply._file_uri("/tmp/a b.html") == "file:///tmp/a%20b.html"
        @test PlotlySupply._file_uri("/tmp/a#b?.html") ==
              "file:///tmp/a%23b%3F.html"
        @test PlotlySupply._file_uri("/tmp/100%.html") ==
              "file:///tmp/100%25.html"
        @test PlotlySupply._file_uri("/tmp/a\"b.html") ==
              "file:///tmp/a%22b.html"
        @test PlotlySupply._file_uri("/tmp/中文.html") ==
              "file:///tmp/%E4%B8%AD%E6%96%87.html"
        @test PlotlySupply._file_uri("/tmp/a:b.html") ==
              "file:///tmp/a%3Ab.html"
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
        prepared = PlotlySupply._prepare_renderer_export(p, NamedTuple())

        # Capture a data URL from a fake renderer and decode it, as savefig does.
        function export_through(io, ec, format)
            url = PlotlySupply._capture_image_data_url(ec, nothing, "test-export", prepared, format)
            PlotlySupply._write_image_data_url!(io, url, format)
            return nothing
        end

        function export_data_url(data_url, format)
            io = IOBuffer()
            ec = (run = (win, js) -> data_url,)
            export_through(io, ec, format)
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
            @test_throws ErrorException export_through(io, ec, format)
            @test isempty(take!(io))
        end

        io = IOBuffer()
        ec = (run = (win, js) -> 42,)
        err = try
            export_through(io, ec, "png")
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
        # No PlotlyBase/PlotlySupply method ambiguity and no method overwrite
        # while loading (a fresh `--compiled-modules=no` process): checked once,
        # in mutator_parity.jl ("mutator parity has no method ambiguity",
        # "mutator parity loads without method overwrite").
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
            () -> plot_choroplethmapbox!(
                sf,
                Dict(
                    "type" => "FeatureCollection",
                    "features" => Any[],
                ),
                ["a", "b"],
                [1.0, 2.0];
                row=2,
                col=3,
            ),
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
        @test length(sf.data) == 25
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
        @test_throws ArgumentError plot_sunburst(
            ["a", "b"],
            ["", "a"];
            values=[1],
        )
        derived = plot_sunburst(
            ["a", "b"],
            ["", "a"];
            colorscale="Viridis",
        )
        # 2.0 (C20): colormap names resolve to explicit stops.
        @test derived.data[1].fields[:marker][:colorscale] ==
              PlotlySupply._resolve_colorscale("Viridis"; who="test").scale
        @test !haskey(derived.data[1].fields[:marker], :colors)

        explicit_colors = plot_sunburst(
            ["a", "b"],
            ["", "a"];
            values=[2, 1],
            colors=["red", "blue"],
            colorscale="Viridis",
        )
        @test explicit_colors.data[1].fields[:marker][:colors] ==
              ["red", "blue"]
        @test explicit_colors.data[1].fields[:marker][:colorscale] ==
              PlotlySupply._resolve_colorscale("Viridis"; who="test").scale

        numeric_strings = plot_sunburst(
            ["a", "b"],
            ["", "a"];
            values=["2", "1"],
            colorscale="Viridis",
        )
        @test numeric_strings.data[1].fields[:marker][:colors] ==
              ["2", "1"]
        scaled = plot_sunburst(
            ["a", "b", "c"],
            ["", "a", "a"];
            values=[10, 3, 2],
            colorscale="Viridis",
        )
        scaled_marker = scaled.data[1].fields[:marker]
        @test scaled_marker[:colors] ===
              scaled.data[1].fields[:values]
        @test scaled_marker[:colors] == [10, 3, 2]
        @test scaled_marker[:colorscale] ==
              PlotlySupply._resolve_colorscale("Viridis"; who="test").scale

        colored = plot_treemap(
            ["a", "b"],
            ["", "a"];
            values=[2, 1],
            colors=[0.25, 0.75],
            colorscale="Cividis",
        )
        @test colored.data[1].fields[:marker][:colors] ==
              [0.25, 0.75]
        @test colored.data[1].fields[:marker][:colorscale] ==
              PlotlySupply._resolve_colorscale("Cividis"; who="test").scale

        g = plot_sunburst(["a"], [""]); plot_sunburst!(g, ["b"], [""]); @test length(g.data) == 2
        plot_treemap!(
            g,
            ["root", "leaf"],
            ["", "root"];
            values=[2, 1],
            colorscale="Blues",
        )
        @test last(g.data).fields[:marker][:colors] ===
              last(g.data).fields[:values]
        @test last(g.data).fields[:marker][:colorscale] ==
              PlotlySupply._resolve_colorscale("Blues"; who="test").scale
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
        y_area = rand(5)
        a = only(plot_area(y_area).data)   # y-only form
        @test a[:x] == 0:4 && a[:y] == y_area && a[:fill] == "tozeroy"
    end

    @testset "Extended: candlestick / ohlc" begin
        @test ttype(plot_candlestick(1:3, [1, 2, 3], [2, 3, 4], [0, 1, 2], [1.5, 2.5, 3.5])) == "candlestick"
        @test ttype(plot_ohlc(1:3, [1, 2, 3], [2, 3, 4], [0, 1, 2], [1.5, 2.5, 3.5])) == "ohlc"
        @test_throws ArgumentError plot_candlestick(1:3, [1, 2], [2, 3, 4], [0, 1, 2], [1.5, 2.5, 3.5])
    end

    @testset "Extended: histogram2d" begin
        f = plot_histogram2d(randn(50), randn(50); nbinsx=10, colorscale="Viridis")
        @test ttype(f) == "histogram2d"
        @test f.data[1].fields[:colorscale] ==
            PlotlySupply._resolve_colorscale("Viridis"; who="test").scale
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
        @test p.data[1].fields[:line][:colorscale] ==
              PlotlySupply._resolve_colorscale("Viridis"; who="test").scale
        t = plot_ternary([1, 2], [2, 1], [1, 1]; alabel="A", marker_size=8)
        @test ttype(t) == "scatterternary"
        @test t.layout.fields[:ternary][:aaxis][:title][:text] == "A"
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
        locations_parent = ["unused", "USA", "CAN", "unused"]
        locations = view(locations_parent, 2:3)
        values = 1.0:2.0
        customdata = 11:12
        c = plot_choropleth(
            locations,
            values;
            colorscale="Blues",
            scope="north america",
            trace=attr(hovertext=customdata),
        )
        @test ttype(c) == "choropleth"
        @test c.data[1].fields[:locations] === locations
        @test c.data[1].fields[:z] === values
        @test c.data[1].fields[:hovertext] === customdata
        @test PlotlySupply._symbol_dict(c.layout.fields[:geo])[:scope] == "north america"

        lon_parent = [-999.0, -122.4, -73.9, 999.0]
        lon = view(lon_parent, 2:3)
        lat = 37.8:2.9:40.7
        marker_color = 1:2
        marker_size = 8:9
        geo = plot_scattergeo(
            lon,
            lat;
            color=marker_color,
            marker_size=marker_size,
            scope="world",
            projection="mercator",
            trace=attr(customdata=customdata),
        )
        @test ttype(geo) == "scattergeo"
        @test geo.data[1].fields[:lon] === lon
        @test geo.data[1].fields[:lat] === lat
        @test geo.data[1].fields[:marker][:color] === marker_color
        @test geo.data[1].fields[:marker][:size] === marker_size
        @test geo.data[1].fields[:customdata] === customdata
        zero_marker = plot_scattergeo(
            lon,
            lat;
            marker_size=0,
        )
        @test zero_marker.data[1].fields[:marker][:size] == 0
        @test !haskey(
            plot_scattergeo(lon, lat).data[1].fields,
            :marker,
        )

        m = plot_scattermapbox(
            lon,
            lat;
            zoom=0,
            center_lon=-100,
            trace=attr(hovertext=customdata),
        )
        @test ttype(m) == "scattermapbox"
        @test m.data[1].fields[:lon] === lon
        @test m.data[1].fields[:lat] === lat
        @test m.data[1].fields[:hovertext] === customdata
        mapbox = PlotlySupply._symbol_dict(m.layout.fields[:mapbox])
        @test mapbox[:style] == "open-street-map"
        @test mapbox[:zoom] == 0
        center = PlotlySupply._symbol_dict(mapbox[:center])
        @test center[:lon] == -100
        @test !haskey(center, :lat)

        lat_center = plot_scattermapbox(
            lon,
            lat;
            center_lat=20,
        )
        lat_only_center = PlotlySupply._symbol_dict(
            PlotlySupply._symbol_dict(
                lat_center.layout.fields[:mapbox],
            )[:center],
        )
        @test lat_only_center[:lat] == 20
        @test !haskey(lat_only_center, :lon)

        density = plot_densitymapbox(
            lon,
            lat,
            values;
            radius=20,
            zoom=0,
            center_lat=10,
            trace=attr(hovertext=customdata),
        )
        @test ttype(density) == "densitymapbox"
        @test density.data[1].fields[:lon] === lon
        @test density.data[1].fields[:lat] === lat
        @test density.data[1].fields[:z] === values
        @test density.data[1].fields[:hovertext] === customdata
        density_mapbox = PlotlySupply._symbol_dict(
            density.layout.fields[:mapbox],
        )
        @test density_mapbox[:zoom] == 0
        radius_values = 20:21
        density_radius = plot_densitymapbox(
            lon,
            lat,
            values;
            radius=radius_values,
        )
        @test density_radius.data[1].fields[:radius] ===
              radius_values

        style_object = Dict(
            "version" => 8,
            "sources" => Dict{String,Any}(),
            "layers" => Any[],
        )
        object_styled = plot_scattermapbox(
            lon,
            lat;
            style=style_object,
        )
        @test PlotlySupply._symbol_dict(
            object_styled.layout.fields[:mapbox],
        )[:style] === style_object
        object_style_target = Plot()
        plot_scattermapbox!(
            object_style_target,
            lon,
            lat;
            style=style_object,
        )
        object_style_layout = PlotlySupply._symbol_dict(
            object_style_target.layout.fields[:mapbox],
        )
        @test object_style_layout[:style] == style_object
        plot_densitymapbox!(
            object_style_target,
            lon,
            lat,
            values;
            center_lon=15,
        )
        object_style_after_merge = PlotlySupply._symbol_dict(
            object_style_target.layout.fields[:mapbox],
        )
        @test object_style_after_merge[:style] == style_object
        @test PlotlySupply._symbol_dict(
            object_style_after_merge[:center],
        )[:lon] == 15

        geojson = Dict(
            "type" => "FeatureCollection",
            "features" => Any[],
        )
        tiled = plot_choroplethmapbox(
            geojson,
            locations,
            values;
            featureidkey="properties.id",
            marker_line_color="white",
            marker_line_width=2,
            marker_opacity=0.75,
            zoom=0,
            center_lon=-90,
            trace=attr(customdata=customdata),
        )
        @test ttype(tiled) == "choroplethmapbox"
        @test tiled.data[1].fields[:geojson] === geojson
        @test tiled.data[1].fields[:locations] === locations
        @test tiled.data[1].fields[:z] === values
        @test tiled.data[1].fields[:customdata] === customdata
        @test tiled.data[1].fields[:featureidkey] == "properties.id"
        @test tiled.data[1].fields[:marker][:opacity] == 0.75
        zero_boundary = plot_choroplethmapbox(
            geojson,
            locations,
            values;
            marker_line_width=0,
        )
        @test zero_boundary.data[1].fields[:marker][:line][:width] ==
              0
        line_colors = ["red", "blue"]
        line_widths = 0:1
        opacities = 0.5:0.25:0.75
        array_markers = plot_choroplethmapbox(
            geojson,
            locations,
            values;
            marker_line_color=line_colors,
            marker_line_width=line_widths,
            marker_opacity=opacities,
        )
        array_marker = array_markers.data[1].fields[:marker]
        @test array_marker[:line][:color] === line_colors
        @test array_marker[:line][:width] === line_widths
        @test array_marker[:opacity] === opacities

        @test_throws ArgumentError plot_scattergeo([0.0], [1.0, 2.0])
        @test_throws ArgumentError plot_choropleth(["USA"], [1.0, 2.0])
        @test_throws ArgumentError plot_scattermapbox([0.0], [1.0, 2.0])
        @test_throws ArgumentError plot_densitymapbox(
            [0.0],
            [1.0, 2.0],
            [3.0],
        )
        @test_throws ArgumentError plot_choroplethmapbox(
            geojson,
            ["USA"],
            [1.0, 2.0],
        )
        @test_throws ArgumentError plot_scattergeo(
            lon,
            lat;
            marker_size=-1,
        )
        @test_throws ArgumentError plot_scattermapbox(
            lon,
            lat;
            marker_size=[1, -1],
        )
        @test_throws ArgumentError plot_densitymapbox(
            lon,
            lat,
            values;
            radius=-1,
        )
        @test_throws ArgumentError plot_densitymapbox(
            lon,
            lat,
            values;
            radius=[20, 0],
        )
        @test_throws ArgumentError plot_choroplethmapbox(
            geojson,
            locations,
            values;
            marker_line_width=[0, -1],
        )
        @test_throws ArgumentError plot_choroplethmapbox(
            geojson,
            locations,
            values;
            marker_opacity=[0.5, 2],
        )
        invalid_view_values = (
            true,
            NaN,
            Inf,
            -Inf,
            "not-a-number",
        )
        mapbox_constructors = (
            options -> plot_scattermapbox(
                lon,
                lat;
                options...,
            ),
            options -> plot_densitymapbox(
                lon,
                lat,
                values;
                options...,
            ),
            options -> plot_choroplethmapbox(
                geojson,
                locations,
                values;
                options...,
            ),
        )
        mapbox_mutators = (
            (fig, options) -> plot_scattermapbox!(
                fig,
                lon,
                lat;
                options...,
            ),
            (fig, options) -> plot_densitymapbox!(
                fig,
                lon,
                lat,
                values;
                options...,
            ),
            (fig, options) -> plot_choroplethmapbox!(
                fig,
                geojson,
                locations,
                values;
                options...,
            ),
        )
        for option in (:zoom, :center_lon, :center_lat)
            for invalid in invalid_view_values
                options = NamedTuple{(option,)}((invalid,))
                for make_plot in mapbox_constructors
                    @test_throws ArgumentError make_plot(options)
                end
                for mutate! in mapbox_mutators
                    target = Plot()
                    layout_before = deepcopy(target.layout)
                    staged = PlotlySupply._StagedPlotMutation(
                        target,
                    )
                    @test_throws ArgumentError mutate!(
                        staged,
                        options,
                    )
                    @test isempty(target.data)
                    @test target.layout == layout_before
                end
            end
        end

        for invalid! in (
            p -> plot_choropleth!(p, ["USA"], [1.0, 2.0]),
            p -> plot_scattergeo!(p, [0.0], [1.0, 2.0]),
            p -> plot_scattermapbox!(p, [0.0], [1.0, 2.0]),
            p -> plot_densitymapbox!(
                p,
                [0.0],
                [1.0, 2.0],
                [3.0],
            ),
            p -> plot_choroplethmapbox!(
                p,
                geojson,
                ["USA"],
                [1.0, 2.0],
            ),
        )
            target = Plot()
            layout_before = deepcopy(target.layout)
            @test_throws ArgumentError invalid!(target)
            @test isempty(target.data)
            @test target.layout == layout_before
        end

        geographic_target = Plot(
            GenericTrace[],
            Layout(
                geo=attr(
                    projection=attr(
                        rotation=attr(lon=15),
                    ),
                ),
            ),
        )
        plot_choropleth!(
            geographic_target,
            locations,
            values;
            scope="north america",
            projection="mercator",
        )
        plot_scattergeo!(
            geographic_target,
            lon,
            lat;
            scope="world",
            projection="orthographic",
        )
        geo_layout = PlotlySupply._symbol_dict(
            geographic_target.layout.fields[:geo],
        )
        geo_projection = PlotlySupply._symbol_dict(
            geo_layout[:projection],
        )
        @test geo_layout[:scope] == "world"
        @test geo_projection[:type] == "orthographic"
        @test PlotlySupply._symbol_dict(
            geo_projection[:rotation],
        )[:lon] == 15

        mapbox_target = Plot(
            GenericTrace[],
            Layout(
                mapbox=attr(
                    center=attr(lat=25),
                ),
            ),
        )
        plot_scattermapbox!(
            mapbox_target,
            lon,
            lat;
            style="carto-positron",
            zoom=0,
            center_lon=-80,
        )
        plot_densitymapbox!(
            mapbox_target,
            lon,
            lat,
            values;
            style="open-street-map",
            zoom=0,
            center_lon=-70,
        )
        plot_choroplethmapbox!(
            mapbox_target,
            geojson,
            locations,
            values;
            zoom=0,
            center_lon=-60,
        )
        mutated_mapbox = PlotlySupply._symbol_dict(
            mapbox_target.layout.fields[:mapbox],
        )
        mutated_center = PlotlySupply._symbol_dict(
            mutated_mapbox[:center],
        )
        @test mutated_mapbox[:zoom] == 0
        @test mutated_mapbox[:style] == "open-street-map"
        @test mutated_center[:lon] == -60
        @test mutated_center[:lat] == 25
        @test length(mapbox_target.data) == 3

        preserved_target = Plot(
            GenericTrace[],
            Layout(
                mapbox=attr(
                    style="carto-darkmatter",
                    zoom=7,
                    center=attr(lon=30, lat=20),
                ),
            ),
        )
        plot_scattermapbox!(preserved_target, lon, lat)
        plot_densitymapbox!(
            preserved_target,
            lon,
            lat,
            values,
        )
        plot_choroplethmapbox!(
            preserved_target,
            geojson,
            locations,
            values,
        )
        preserved_mapbox = PlotlySupply._symbol_dict(
            preserved_target.layout.fields[:mapbox],
        )
        @test preserved_mapbox[:style] == "carto-darkmatter"
        @test preserved_mapbox[:zoom] == 7
        @test PlotlySupply._symbol_dict(
            preserved_mapbox[:center],
        ) == Dict{Symbol,Any}(
            :lon => 30,
            :lat => 20,
        )
    end

    @testset "CRC: geo/mapbox inputs stay lazy and allocation bounded" begin
        payload = 1:1_000_000
        geojson = Dict(
            "type" => "FeatureCollection",
            "features" => Any[],
        )
        constructors = (
            () -> plot_choropleth(payload, payload),
            () -> plot_scattergeo(payload, payload),
            () -> plot_scattermapbox(payload, payload),
            () -> plot_densitymapbox(
                payload,
                payload,
                payload,
            ),
            () -> plot_choroplethmapbox(
                geojson,
                payload,
                payload,
            ),
        )
        for make_plot in constructors
            make_plot()
            GC.gc()
            allocated = @allocated make_plot()
            @test allocated < 2_000_000
        end

        mutators = (
            p -> plot_choropleth!(p, payload, payload),
            p -> plot_scattergeo!(p, payload, payload),
            p -> plot_scattermapbox!(p, payload, payload),
            p -> plot_densitymapbox!(
                p,
                payload,
                payload,
                payload,
            ),
            p -> plot_choroplethmapbox!(
                p,
                geojson,
                payload,
                payload,
            ),
        )
        for mutate! in mutators
            mutate!(Plot())
            target = Plot()
            GC.gc()
            allocated = @allocated mutate!(target)
            @test allocated < 2_000_000
        end

        geo_subplot = () -> PlotlySupply.subplots(
            1,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=fill(PlotlySupply.Spec(kind="geo"), 1, 1),
        )
        mapbox_subplot = () -> PlotlySupply.subplots(
            1,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=fill(PlotlySupply.Spec(kind="mapbox"), 1, 1),
        )
        subplot_cases = (
            (
                geo_subplot,
                sf -> plot_choropleth!(
                    sf,
                    payload,
                    payload;
                    trace=attr(customdata=payload),
                ),
                (:locations, :z, :customdata),
            ),
            (
                geo_subplot,
                sf -> plot_scattergeo!(
                    sf,
                    payload,
                    payload;
                    color=payload,
                    marker_size=payload,
                    trace=attr(customdata=payload),
                ),
                (:lon, :lat, :customdata),
            ),
            (
                mapbox_subplot,
                sf -> plot_scattermapbox!(
                    sf,
                    payload,
                    payload;
                    color=payload,
                    marker_size=payload,
                    trace=attr(customdata=payload),
                ),
                (:lon, :lat, :customdata),
            ),
            (
                mapbox_subplot,
                sf -> plot_densitymapbox!(
                    sf,
                    payload,
                    payload,
                    payload,
                    trace=attr(customdata=payload),
                ),
                (:lon, :lat, :z, :customdata),
            ),
            (
                mapbox_subplot,
                sf -> plot_choroplethmapbox!(
                    sf,
                    geojson,
                    payload,
                    payload,
                    trace=attr(customdata=payload),
                ),
                (:locations, :z, :customdata),
            ),
        )
        for (make_subplot, mutate!, payload_fields) in subplot_cases
            mutate!(make_subplot())
            target = make_subplot()
            GC.gc()
            allocated = @allocated mutate!(target)
            @test allocated < 2_000_000
            for field in payload_fields
                @test only(target.data).fields[field] === payload
            end
            trace = only(target.data)
            if haskey(trace.fields, :marker)
                marker = trace.fields[:marker]
                if haskey(marker, :color)
                    @test marker[:color] === payload
                end
                if haskey(marker, :size)
                    @test marker[:size] === payload
                end
            end
            if get(trace.fields, :type, "") == "choroplethmapbox"
                @test trace.fields[:geojson] === geojson
            end
        end
    end

    @testset "CRC: cell-specific geo/mapbox updates" begin
        specs = [
            PlotlySupply.Spec(kind="geo") PlotlySupply.Spec(kind="geo")
            PlotlySupply.Spec(kind="mapbox") PlotlySupply.Spec(kind="mapbox")
        ]
        sf = PlotlySupply.subplots(
            2,
            2;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=specs,
        )
        geo_domain = deepcopy(sf.layout.fields[:geo2][:domain])
        mapbox_domain = deepcopy(sf.layout.fields[:mapbox2][:domain])

        @test update_geos!(
            sf;
            row=1,
            col=2,
            bgcolor="red",
            projection_type="mercator",
        ) === sf
        @test !haskey(
            PlotlySupply._symbol_dict(sf.layout.fields[:geo]),
            :bgcolor,
        )
        updated_geo = PlotlySupply._symbol_dict(
            sf.layout.fields[:geo2],
        )
        @test updated_geo[:bgcolor] == "red"
        @test PlotlySupply._symbol_dict(
            updated_geo[:projection],
        )[:type] == "mercator"
        @test updated_geo[:domain] == geo_domain

        @test update_mapboxes!(
            sf;
            row=2,
            col=2,
            zoom=0,
            center_lon=12,
        ) === sf
        @test !haskey(
            PlotlySupply._symbol_dict(
                sf.layout.fields[:mapbox],
            ),
            :zoom,
        )
        updated_mapbox = PlotlySupply._symbol_dict(
            sf.layout.fields[:mapbox2],
        )
        @test updated_mapbox[:zoom] == 0
        @test PlotlySupply._symbol_dict(
            updated_mapbox[:center],
        )[:lon] == 12
        @test updated_mapbox[:domain] == mapbox_domain
        style_object = Dict(
            "version" => 8,
            "sources" => Dict{String,Any}(),
            "layers" => Any[],
        )
        @test plot_scattermapbox!(
            sf,
            [0.0],
            [0.0];
            row=2,
            col=2,
            style=style_object,
        ) === sf
        @test PlotlySupply._symbol_dict(
            sf.layout.fields[:mapbox2],
        )[:style] == style_object
        @test plot_densitymapbox!(
            sf,
            [0.0],
            [0.0],
            [1.0];
            row=2,
            col=2,
            center_lat=8,
        ) === sf
        mapbox_after_center = PlotlySupply._symbol_dict(
            sf.layout.fields[:mapbox2],
        )
        @test mapbox_after_center[:style] == style_object
        @test PlotlySupply._symbol_dict(
            mapbox_after_center[:center],
        )[:lat] == 8

        selection_before = (
            sf.current_row,
            sf.current_col,
        )
        layout_before = deepcopy(sf.layout)
        @test_throws ArgumentError update_geos!(
            sf;
            row=2,
            col=1,
            bgcolor="invalid-cell",
        )
        @test sf.layout == layout_before
        @test (
            sf.current_row,
            sf.current_col,
        ) == selection_before
        @test_throws ArgumentError update_mapboxes!(
            sf;
            row=1,
            col=1,
            zoom=0,
        )
        @test sf.layout == layout_before
        @test (
            sf.current_row,
            sf.current_col,
        ) == selection_before
        for option in (:zoom, :center_lon, :center_lat)
            for invalid in (true, NaN, Inf, -Inf)
                options = NamedTuple{(option,)}((invalid,))
                @test_throws ArgumentError update_mapboxes!(
                    sf;
                    row=2,
                    col=1,
                    options...,
                )
                @test sf.layout == layout_before
                @test (
                    sf.current_row,
                    sf.current_col,
                ) == selection_before
            end
        end

        @test update_mapboxes!(
            sf;
            row=2,
            col=1,
            center_lat=5,
        ) === sf
        geojson = Dict(
            "type" => "FeatureCollection",
            "features" => Any[],
        )
        @test plot_choroplethmapbox!(
            sf,
            geojson,
            ["region"],
            [1.0];
            row=2,
            col=1,
            zoom=0,
            center_lon=-90,
        ) === sf
        @test sf.data[end].fields[:type] ==
              "choroplethmapbox"
        @test sf.data[end].fields[:subplot] == "mapbox"
        first_mapbox = PlotlySupply._symbol_dict(
            sf.layout.fields[:mapbox],
        )
        first_center = PlotlySupply._symbol_dict(
            first_mapbox[:center],
        )
        @test first_mapbox[:zoom] == 0
        @test first_center[:lon] == -90
        @test first_center[:lat] == 5
        @test update_mapboxes!(
            sf;
            row=2,
            col=1,
            style="carto-darkmatter",
            zoom=6,
        ) === sf
        @test plot_choroplethmapbox!(
            sf,
            geojson,
            ["region"],
            [2.0];
            row=2,
            col=1,
        ) === sf
        preserved_submap = PlotlySupply._symbol_dict(
            sf.layout.fields[:mapbox],
        )
        @test preserved_submap[:style] == "carto-darkmatter"
        @test preserved_submap[:zoom] == 6
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
            @test g.layout.fields[:template] ===
                PlotlyBase.templates[:plotly_dark]
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

        html = PlotlySupply._syncplot_html(
            "frame-test";
            autoplay=true,
            timeout_s=2.5,
        )
        @test occursin("<script src=\"model.js\"", html)
        @test occursin("__plotlysupply_plotly_loader", html)
        @test !occursin("frame-sentinel", html)
        @test occursin("Plotly.addFrames", html)
        @test occursin("Plotly.newPlot", html)
        @test occursin("Plotly.animate", html)
        @test occursin("2500.0", html)

        readiness = PlotlySupply._syncplot_readiness_script()
        @test occursin("__plotlysupply_initial_render", readiness)
        @test !occursin("Plotly.newPlot", readiness)
        @test !occursin("frame-sentinel", readiness)

        no_autoplay = PlotlySupply._syncplot_html(
            "frame-test";
            autoplay=false,
            timeout_s=2.5,
        )
        @test occursin("Plotly.addFrames", no_autoplay)
        @test occursin("if (false)", no_autoplay)

        hostile = "</ScRiPt><script>window.__plotlysupply_injected=true</script>"
        streamed_plot = Plot(
            scatter(
                y=[NaN, Inf, -Inf],
                text=[hostile, "safe", "safe"],
            ),
            Layout(),
            [fr],
        )
        mktempdir() do tempdir
            model_path = joinpath(tempdir, "model.js")
            @test PlotlySupply._write_syncplot_model(
                model_path,
                streamed_plot,
            ) === nothing
            model_js = read(model_path, String)
            @test startswith(
                model_js,
                "window.__plotlysupply_model = {",
            )
            @test endswith(model_js, ";\n")
            @test occursin("frame-sentinel", model_js)
            @test occursin(hostile, model_js)
            @test occursin("NaN", model_js)
            @test occursin("Infinity", model_js)
            @test !occursin(hostile, html)
        end

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

        @testset "constructor awaits and validates the initial render" begin
            plot = Plot(
                scatter(y=[1, 2, 3]),
                Layout(),
                [frame(name="startup-frame", data=[scatter(y=[2, 3, 4])])],
            )

            ec = _LifecycleFakeElectron()
            sp = PlotlySupply._create_syncplot_window(
                ec,
                plot;
                app=:fake,
                show=false,
                autoplay=false,
                timeout_s=3.25,
            )
            @test length(ec.scripts) == 1
            startup_script = only(ec.scripts)
            @test occursin(
                "await readiness",
                startup_script,
            )
            @test !occursin("Plotly.newPlot", startup_script)
            @test !occursin("startup-frame", startup_script)
            resources = getfield(sp, :_resources)
            @test resources.creation_spec.timeout_s == 3.25
            @test isfile(joinpath(resources.tempdir, "model.js"))
            @test occursin(
                "startup-frame",
                read(joinpath(resources.tempdir, "model.js"), String),
            )
            index_html =
                read(joinpath(resources.tempdir, "index.html"), String)
            @test !occursin("startup-frame", index_html)
            @test occursin("await Plotly.newPlot", index_html)
            @test occursin("await Plotly.addFrames", index_html)
            @test occursin("if (false)", index_html)
            @test occursin("3250.0", index_html)
            @test close(sp) === nothing

            for (run_result, run_error) in (
                ("plotly-not-loaded", nothing),
                (nothing, nothing),
                ("ok", ErrorException("injected startup transport failure")),
            )
                mktempdir() do temp_root
                    failed_ec = _LifecycleFakeElectron(
                        ;
                        run_result=run_result,
                        run_error=run_error,
                    )
                    caught = withenv("TMPDIR" => temp_root) do
                        try
                            PlotlySupply._create_syncplot_window(
                                failed_ec,
                                plot;
                                app=:fake,
                                show=false,
                            )
                            nothing
                        catch err
                            err
                        end
                    end
                    if run_error === nothing
                        @test caught isa ErrorException
                        @test occursin(
                            "initial render did not complete successfully",
                            sprint(showerror, caught),
                        )
                    else
                        @test caught === run_error
                    end
                    @test length(failed_ec.scripts) == 1
                    @test length(failed_ec.windows) == 1
                    failed_window = only(failed_ec.windows)
                    @test failed_window.close_calls == 1
                    @test !failed_window.exists
                    @test isempty(readdir(temp_root))
                end
            end

            for invalid_timeout in (
                -1.0,
                Inf,
                NaN,
                PlotlySupply._SYNCPLOT_MAX_STARTUP_TIMEOUT_SECONDS + 1,
            )
                mktempdir() do temp_root
                    invalid_ec = _LifecycleFakeElectron()
                    caught = withenv("TMPDIR" => temp_root) do
                        try
                            PlotlySupply._create_syncplot_window(
                                invalid_ec,
                                plot;
                                timeout_s=invalid_timeout,
                            )
                            nothing
                        catch err
                            err
                        end
                    end
                    @test caught isa ArgumentError
                    error_text = sprint(showerror, caught)
                    @test occursin("timeout", error_text)
                    @test occursin(
                        isfinite(invalid_timeout) &&
                        invalid_timeout >
                        PlotlySupply._SYNCPLOT_MAX_STARTUP_TIMEOUT_SECONDS ?
                        "must not exceed" :
                        "finite, non-negative",
                        error_text,
                    )
                    @test isempty(invalid_ec.windows)
                    @test isempty(invalid_ec.scripts)
                    @test isempty(readdir(temp_root))
                end
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
            @test isfile(joinpath(tempdir, "model.js"))
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

        @testset "live image commands use the source renderer exactly once" begin
            state = _ImageCommandState()
            backend = _image_command_backend(state)
            window = Ref(:image_command_window)
            plot = Plot(
                scatter(y=[1, 2, 3]),
                Layout(title="image-command");
                config=PlotConfig(staticPlot=true),
            )
            resources = PlotlySupply._SyncPlotResources(nothing, backend)
            hostile_divid =
                "plot\"\\\n</ScRiPt><script>window.injected=true</script>"
            sp = SyncPlot(
                plot,
                :fake,
                window,
                hostile_divid,
                resources,
            )
            model_json =
                PlotlyBase.JSON.json(plot; allownan=true)
            model_refs = (
                plot,
                plot.data,
                plot.layout,
                plot.frames,
                plot.config,
                window,
                resources,
            )

            push!(state.results, "data:image/png;base64,QUFBQQ==")
            call_count = length(state.calls)
            image_url = to_image(sp)
            @test image_url == "data:image/png;base64,QUFBQQ=="
            @test image_url isa String
            @test length(state.calls) == call_count + 1
            image_window, image_script = last(state.calls)
            @test image_window === window
            @test occursin("(async function()", image_script)
            @test occursin(
                "return await Plotly.toImage(div, {});",
                image_script,
            )
            @test occursin(
                "typeof Plotly.toImage !== \"function\"",
                image_script,
            )
            @test occursin(
                "SyncPlot plot div was not found",
                image_script,
            )
            @test occursin(
                PlotlySupply._json_js(hostile_divid),
                image_script,
            )
            @test !occursin("</script>", lowercase(image_script))
            @test !occursin("Plotly.react", image_script)
            @test !occursin("Plotly.newPlot", image_script)

            raw_result = SubString("renderer-image-data", 1)
            push!(state.results, raw_result)
            image_url = to_image(
                sp;
                format="full-json",
                width=641,
                height=479,
                scale=2.5,
                imageDataOnly=true,
                setBackground="rgba(0,0,0,0)",
            )
            @test image_url == raw_result
            @test image_url isa String
            option_script = last(state.calls)[2]
            for token in (
                "\"format\":\"full-json\"",
                "\"width\":641",
                "\"height\":479",
                "\"scale\":2.5",
                "\"imageDataOnly\":true",
                "\"setBackground\":\"rgba(0,0,0,0)\"",
            )
                @test occursin(token, option_script)
            end

            for invalid_result in (nothing, 1, Dict(:image => "x"), true)
                push!(state.results, invalid_result)
                call_count = length(state.calls)
                err = try
                    to_image(sp)
                    nothing
                catch caught
                    caught
                end
                @test err isa ErrorException
                @test occursin(
                    "non-string result",
                    sprint(showerror, err),
                )
                @test length(state.calls) == call_count + 1
            end

            hostile_filename =
                "plot\"\\\n</ScRiPt><script>window.injected=true</script>"
            push!(state.results, "renderer-private-filename.jpeg")
            call_count = length(state.calls)
            @test download_image(
                sp;
                format="jpeg",
                filename=hostile_filename,
                width=642,
                height=481,
                scale=1.75,
            ) === nothing
            @test length(state.calls) == call_count + 1
            download_window, download_script = last(state.calls)
            @test download_window === window
            @test occursin(
                "await Plotly.downloadImage(div,",
                download_script,
            )
            @test occursin("return null;", download_script)
            @test occursin(
                "typeof Plotly.downloadImage !== \"function\"",
                download_script,
            )
            for token in (
                "\"format\":\"jpeg\"",
                "\"width\":642",
                "\"height\":481",
                "\"scale\":1.75",
                PlotlySupply._json_js(hostile_filename),
            )
                @test occursin(token, download_script)
            end
            @test !occursin("</script>", lowercase(download_script))

            injected_error =
                ErrorException("injected renderer promise rejection")
            for image_operation in (to_image, download_image)
                state.run_error = injected_error
                call_count = length(state.calls)
                caught = try
                    image_operation(sp)
                    nothing
                catch err
                    err
                end
                @test caught === injected_error
                @test length(state.calls) == call_count + 1
                state.run_error = nothing
            end

            sf = SubplotFigure(
                sp,
                1,
                1,
                1,
                1,
                false,
                :topright,
                (0.02, 0.02),
                "white",
                "black",
                1.0,
            )
            subplot_state = (
                sf.rows,
                sf.cols,
                sf.current_row,
                sf.current_col,
            )
            push!(state.results, "subplot-renderer-image")
            @test to_image(sf; format="svg") ==
                  "subplot-renderer-image"
            push!(state.results, nothing)
            @test download_image(sf; filename="subplot") === nothing
            @test (
                sf.rows,
                sf.cols,
                sf.current_row,
                sf.current_col,
            ) == subplot_state

            raw_sf = SubplotFigure(
                Plot(scatter(y=[1, 2, 3])),
                1,
                1,
                1,
                1,
                false,
                :topright,
                (0.02, 0.02),
                "white",
                "black",
                1.0,
            )
            call_count = length(state.calls)
            # A windowless SubplotFigure has nothing to render in: it throws
            # (pointing to savefig) instead of returning `nothing`.
            @test_throws ArgumentError to_image(raw_sf)
            @test_throws ArgumentError download_image(raw_sf)
            @test length(state.calls) == call_count

            state.open = false
            for image_operation in (to_image, download_image)
                call_count = length(state.calls)
                err = try
                    image_operation(sp)
                    nothing
                catch caught
                    caught
                end
                @test err isa InvalidStateException
                @test occursin(
                    "window is not open",
                    sprint(showerror, err),
                )
                @test length(state.calls) == call_count
            end
            state.open = true

            @test PlotlyBase.JSON.json(plot; allownan=true) ==
                  model_json
            @test (
                sp.plot,
                sp.plot.data,
                sp.plot.layout,
                sp.plot.frames,
                sp.plot.config,
                sp.window,
                getfield(sp, :_resources),
            ) === model_refs
            @test sp.divid == hostile_divid
        end

        @testset "SyncPlot clones own independent windows and resources" begin
            ec = _LifecycleFakeElectron()
            shared_clone_payload = [10, 20, 30]
            plot = Plot(
                GenericTrace[
                    scatter(
                        y=[1, 2, 3],
                        name="source",
                        customdata=shared_clone_payload,
                    ),
                    scatter(
                        y=[3, 2, 1],
                        name="second",
                        customdata=shared_clone_payload,
                    ),
                ],
                Layout(title="source", meta=shared_clone_payload),
                [
                    frame(
                        name="source-frame",
                        data=[
                            scatter(
                                y=[2, 3, 4],
                                customdata=shared_clone_payload,
                            ),
                        ],
                    ),
                ];
                config=PlotConfig(
                    staticPlot=true,
                    locale="fr",
                    toImageButtonOptions=Dict(:width => 640),
                ),
            )
            source = PlotlySupply._create_syncplot_window(
                ec,
                plot;
                app=:fake,
                width=777,
                height=444,
                title="clone-source",
                show=false,
                autoplay=false,
                timeout_s=6.75,
            )
            source_window = source.window
            source_tempdir = getfield(source, :_resources).tempdir
            _, registered =
                PlotlySupply._register_displayed_syncplot!(plot, source)
            @test registered

            function check_clone(clone, window)
                resources = getfield(clone, :_resources)
                spec = resources.creation_spec
                @test clone !== source
                @test clone.plot !== source.plot
                @test clone.plot.data !== source.plot.data
                @test clone.plot.frames == source.plot.frames
                @test clone.plot.frames !== source.plot.frames
                cloned_shared =
                    clone.plot.data[1].fields[:customdata]
                @test cloned_shared !== shared_clone_payload
                @test cloned_shared ===
                      clone.plot.data[2].fields[:customdata]
                @test cloned_shared === clone.plot.layout.fields[:meta]
                cloned_frame_trace =
                    clone.plot.frames[1].fields[:data][1]
                @test cloned_shared ===
                      cloned_frame_trace.fields[:customdata]
                @test clone.plot.config.staticPlot
                @test clone.plot.config.locale == "fr"
                @test clone.plot.config.toImageButtonOptions ==
                      Dict(:width => 640)
                @test clone.plot.divid != source.plot.divid
                @test clone.divid != source.divid
                @test clone.app === source.app
                @test clone.window === window
                @test clone.window !== source.window
                @test resources !== getfield(source, :_resources)
                @test resources.backend === ec
                @test resources.tempdir != source_tempdir
                @test ispath(resources.tempdir)
                @test spec !== nothing
                @test spec.width == 777
                @test spec.height == 444
                @test spec.title == "clone-source"
                @test !spec.show
                @test !spec.autoplay
                @test spec.timeout_s == 6.75
                @test window.width == 777
                @test window.height == 444
                @test window.title == "clone-source"
                @test !window.show
                index_html =
                    read(joinpath(resources.tempdir, "index.html"), String)
                model_js =
                    read(joinpath(resources.tempdir, "model.js"), String)
                @test occursin("__plotlysupply_plotly_loader", index_html)
                @test occursin("if (false)", index_html)
                @test occursin("6750.0", index_html)
                @test !occursin("source-frame", index_html)
                @test occursin("source-frame", model_js)
                @test !_lifecycle_is_registered(clone.plot, clone)
                @test _lifecycle_is_registered(plot, source)
                return resources.tempdir
            end

            for clone_operation in (copy, PlotlyBase.fork, deepcopy)
                window_count = length(ec.windows)
                script_count = length(ec.scripts)
                clone = clone_operation(source)
                @test length(ec.windows) == window_count + 1
                @test length(ec.scripts) == script_count + 1
                @test occursin(
                    "__plotlysupply_initial_render",
                    last(ec.scripts),
                )
                clone_window = last(ec.windows)
                clone_tempdir = check_clone(clone, clone_window)

                @test close(clone) === nothing
                @test clone_window.close_calls == 1
                @test !ispath(clone_tempdir)
                @test isopen(source)
                @test source_window.close_calls == 0
                @test ispath(source_tempdir)
                @test _lifecycle_is_registered(plot, source)
            end

            for outer in (
                Any[source],
                Any[source, source],
                Any[source.plot, source],
                Any[source.plot.data, source],
                Any[source.plot.data[1], source],
            )
                window_count = length(ec.windows)
                nested_error = try
                    deepcopy(outer)
                    nothing
                catch caught
                    caught
                end
                @test nested_error isa ArgumentError
                @test occursin(
                    "Deepcopy the SyncPlot directly",
                    sprint(showerror, nested_error),
                )
                @test length(ec.windows) == window_count
                @test isopen(source)
            end

            function check_model_syncplot_rejection(embedded)
                source.plot.layout.fields[:embedded_syncplot] = embedded
                try
                    for clone_operation in (
                        copy,
                        PlotlyBase.fork,
                        deepcopy,
                        sp -> relayout(sp; title="unreachable"),
                    )
                        window_count = length(ec.windows)
                        clone_error = try
                            result = clone_operation(source)
                            result isa SyncPlot && close(result)
                            nothing
                        catch caught
                            caught
                        end
                        @test clone_error isa ArgumentError
                        @test occursin(
                            "plot model contains a SyncPlot reference",
                            sprint(showerror, clone_error),
                        )
                        @test length(ec.windows) == window_count
                        @test isopen(source)
                        @test isopen(embedded)
                    end

                    for outer in (
                        Any[source.plot, source],
                        Any[source.plot.layout, source],
                        Any[source.plot.layout.fields, source],
                    )
                        window_count = length(ec.windows)
                        model_first_error = try
                            deepcopy(outer)
                            nothing
                        catch caught
                            caught
                        end
                        @test model_first_error isa ArgumentError
                        @test length(ec.windows) == window_count
                        @test isopen(source)
                        @test isopen(embedded)
                    end
                finally
                    delete!(
                        source.plot.layout.fields,
                        :embedded_syncplot,
                    )
                end
                return nothing
            end

            check_model_syncplot_rejection(source)
            other = PlotlySupply._create_syncplot_window(
                ec,
                Plot(scatter(y=[4, 5, 6]));
                app=:fake,
                show=false,
            )
            other_tempdir = getfield(other, :_resources).tempdir
            other_window = other.window
            check_model_syncplot_rejection(other)

            window_count = length(ec.windows)
            collection_error = try
                deepcopy(Any[source, other])
                nothing
            catch caught
                caught
            end
            @test collection_error isa ArgumentError
            @test occursin(
                "native window creation cannot be rolled back",
                sprint(showerror, collection_error),
            )
            @test length(ec.windows) == window_count
            @test isopen(source)
            @test isopen(other)

            close(other)
            @test other_window.close_calls == 1
            @test !ispath(other_tempdir)

            script_count = length(ec.scripts)
            relayout_clone = relayout(source; title="clone-relayout")
            @test length(ec.scripts) == script_count + 2
            @test occursin(
                "__plotlysupply_initial_render",
                ec.scripts[script_count + 1],
            )
            @test occursin("Plotly.relayout", last(ec.scripts))
            @test relayout_clone.layout.fields[:title] == "clone-relayout"
            @test source.layout.fields[:title] == "source"
            check_clone(relayout_clone, last(ec.windows))
            close(relayout_clone)

            script_count = length(ec.scripts)
            redraw_clone = redraw(source)
            @test length(ec.scripts) == script_count + 2
            @test occursin(
                "__plotlysupply_initial_render",
                ec.scripts[script_count + 1],
            )
            # 2.0 (#165): redraw! rebuilds the window from the Julia model.
            @test occursin("Plotly.newPlot", last(ec.scripts))
            check_clone(redraw_clone, last(ec.windows))
            close(redraw_clone)

            script_count = length(ec.scripts)
            purge_clone = PlotlyBase.purge(source)
            @test length(ec.scripts) == script_count + 2
            @test occursin(
                "__plotlysupply_initial_render",
                ec.scripts[script_count + 1],
            )
            @test occursin("Plotly.purge", last(ec.scripts))
            @test isempty(purge_clone.plot.data)
            @test purge_clone.plot.layout == Layout()
            @test length(source.plot.data) == 2
            purge_window = last(ec.windows)
            purge_tempdir = getfield(purge_clone, :_resources).tempdir
            close(purge_clone)
            @test purge_window.close_calls == 1
            @test !ispath(purge_tempdir)

            window_count = length(ec.windows)
            @test_throws BoundsError restyle(
                source,
                [99],
                Dict(:name => ["invalid"]),
            )
            @test length(ec.windows) == window_count + 1
            failed_window = last(ec.windows)
            @test failed_window.close_calls == 1
            @test !failed_window.exists
            @test isopen(source)
            @test _lifecycle_is_registered(plot, source)

            @test close(source) === nothing
            @test source_window.close_calls == 1
            @test !ispath(source_tempdir)
            @test !_lifecycle_is_registered(plot, source)
        end

        @testset "manual SyncPlot clone requests fail before allocation" begin
            ec = _LifecycleFakeElectron()
            resources = PlotlySupply._SyncPlotResources(nothing, ec)
            manual = SyncPlot(
                Plot(scatter(y=[1, 2, 3])),
                :fake,
                nothing,
                "manual",
                resources,
            )
            window_count = length(ec.windows)

            for clone_operation in (copy, PlotlyBase.fork, deepcopy)
                err = try
                    clone_operation(manual)
                    nothing
                catch caught
                    caught
                end
                @test err isa ArgumentError
                @test occursin("sp.plot", sprint(showerror, err))
                @test occursin("to_syncplot", sprint(showerror, err))
            end
            @test_throws ArgumentError deepcopy(Any[manual])
            @test length(ec.windows) == window_count
            @test manual.plot.data[1].fields[:y] == [1, 2, 3]
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
            @test _lifecycle_registry_counts() == baseline + 1

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

    include("hygiene.jl")
    include("nested_series.jl")
    include("three_d_styling.jl")
    include("extended_mutator_parity.jl")
    include("layout_merge_preservation.jl")
    include("lazy_payloads.jl")
    include("export_transactions.jl")
    include("mutator_parity.jl")
    include("renderer_transactions.jl")
    include("modern_maps.jl")

    # 2.0 scientific-plotting extensions and regression suites: every
    # `test/sci_*.jl` and `test/regression_*.jl` file is picked up automatically.
    for test_file in sort!(filter(
        name -> endswith(name, ".jl") &&
            (startswith(name, "sci_") || startswith(name, "regression_")),
        readdir(@__DIR__),
    ))
        include(test_file)
    end
end
