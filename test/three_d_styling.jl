using Test
using PlotlySupply

_three_d_fields(value) =
    value isa AbstractDict ? value : value.fields

function _three_d_axis_title(scene, axis::Symbol)
    axis_fields = _three_d_fields(_three_d_fields(scene)[axis])
    title = get(axis_fields, :title, nothing)
    if title isa AbstractDict ||
       title isa PlotlySupply.PlotlyBase.PlotlyAttribute
        return get(_three_d_fields(title), :text, nothing)
    end
    return title
end

function _three_d_trace_style(trace)
    trace_fields = trace.fields
    line_fields = _three_d_fields(trace_fields[:line])
    marker_fields = haskey(trace_fields, :marker) ?
                    _three_d_fields(trace_fields[:marker]) :
                    nothing
    return (
        mode=trace_fields[:mode],
        color=get(line_fields, :color, nothing),
        legend=trace_fields[:name],
        marker_size=marker_fields === nothing ?
                    nothing :
                    get(marker_fields, :size, nothing),
        marker_symbol=marker_fields === nothing ?
                      nothing :
                      get(marker_fields, :symbol, nothing),
        linewidth=get(line_fields, :width, nothing),
        showlegend=get(trace_fields, :showlegend, nothing),
    )
end

function _apply_three_d_mutator!(kind::Symbol, figure; kwargs...)
    if kind === :surface_xyz
        grid_x = [i for i in 1:2, _ in 1:2]
        grid_y = [j for _ in 1:2, j in 1:2]
        return plot_surface!(
            figure,
            grid_x,
            grid_y,
            [1.0 2.0; 3.0 4.0];
            kwargs...,
        )
    elseif kind === :surface_z
        return plot_surface!(
            figure,
            [1.0 2.0; 3.0 4.0];
            kwargs...,
        )
    elseif kind === :scatter3d
        return plot_scatter3d!(
            figure,
            1:3,
            1:3,
            1:3;
            kwargs...,
        )
    elseif kind === :quiver3d
        return plot_quiver3d!(
            figure,
            1:3,
            1:3,
            1:3,
            ones(3),
            ones(3),
            ones(3);
            kwargs...,
        )
    end
    throw(ArgumentError("unknown 3D mutator test kind: $kind"))
end

function _seed_rich_three_d_scene!(figure)
    scene = _three_d_fields(_three_d_fields(figure.layout)[:scene])
    for (axis, axis_range, title) in (
        (:xaxis, [1.0, 9.0], "old-x"),
        (:yaxis, [2.0, 8.0], "old-y"),
        (:zaxis, [3.0, 7.0], "old-z"),
    )
        scene[axis] = attr(
            title=attr(
                text=title,
                font=attr(color="red", size=20),
            ),
            range=axis_range,
            showgrid=false,
            visible=false,
            tickfont=attr(color="blue"),
        )
    end
    scene[:camera] = attr(
        eye=attr(x=1.25, y=1.5, z=1.75),
        up=attr(x=0.0, y=0.0, z=1.0),
        projection=attr(type="orthographic"),
    )
    return figure
end

function _test_rich_three_d_scene(
    figure;
    projection::String,
)
    scene = _three_d_fields(_three_d_fields(figure.layout)[:scene])
    for (axis, axis_range, title) in (
        (:xaxis, [1.0, 9.0], "updated-x"),
        (:yaxis, [2.0, 8.0], "old-y"),
        (:zaxis, [3.0, 7.0], "old-z"),
    )
        axis_fields = _three_d_fields(scene[axis])
        title_fields = _three_d_fields(axis_fields[:title])
        title_font = _three_d_fields(title_fields[:font])
        @test title_fields[:text] == title
        @test title_font[:color] == "red"
        @test title_font[:size] == 20
        @test axis_fields[:range] == axis_range
        @test axis_fields[:showgrid] === true
        @test axis_fields[:visible] === true
        @test _three_d_fields(axis_fields[:tickfont])[:color] ==
              "blue"
    end
    camera = _three_d_fields(scene[:camera])
    eye = _three_d_fields(camera[:eye])
    up = _three_d_fields(camera[:up])
    @test (eye[:x], eye[:y], eye[:z]) == (1.25, 1.5, 1.75)
    @test (up[:x], up[:y], up[:z]) == (0.0, 0.0, 1.0)
    @test _three_d_fields(camera[:projection])[:type] ==
          projection
    return nothing
end

@testset "CRC: 3D appenders preserve omitted scene styling" begin
    for kind in (:surface_xyz, :surface_z, :scatter3d, :quiver3d)
        @testset "$kind" begin
            figure = plot_scatter3d(
                1:3,
                1:3,
                1:3;
                xlabel="existing-x",
                ylabel="existing-y",
                zlabel="existing-z",
                aspectmode="cube",
                perspective=false,
            )
            scene_before =
                deepcopy(_three_d_fields(figure.layout)[:scene])
            initial_trace_count = length(figure.data)

            @test _apply_three_d_mutator!(kind, figure) === nothing
            @test length(figure.data) == initial_trace_count + 1
            @test _three_d_fields(figure.layout)[:scene] ==
                  scene_before
        end
    end
end

@testset "CRC: 3D appenders apply explicit scene styling" begin
    for kind in (:surface_xyz, :surface_z, :scatter3d, :quiver3d)
        @testset "$kind" begin
            figure = plot_scatter3d(
                1:3,
                1:3,
                1:3;
                xlabel="existing-x",
                ylabel="existing-y",
                zlabel="existing-z",
                aspectmode="cube",
                perspective=false,
            )

            @test _apply_three_d_mutator!(
                kind,
                figure;
                xlabel="updated-x",
                ylabel="updated-y",
                zlabel="updated-z",
                aspectmode="auto",
                grid=false,
                showaxis=false,
            ) === nothing

            scene = _three_d_fields(figure.layout)[:scene]
            scene_fields = _three_d_fields(scene)
            @test scene_fields[:aspectmode] == "auto"
            @test _three_d_axis_title(scene, :xaxis) ==
                  "updated-x"
            @test _three_d_axis_title(scene, :yaxis) ==
                  "updated-y"
            @test _three_d_axis_title(scene, :zaxis) ==
                  "updated-z"
            for axis in (:xaxis, :yaxis, :zaxis)
                axis_fields =
                    _three_d_fields(scene_fields[axis])
                @test axis_fields[:showgrid] === false
                @test axis_fields[:visible] === false
            end
            camera =
                _three_d_fields(scene_fields[:camera])
            projection =
                _three_d_fields(camera[:projection])
            @test projection[:type] == "orthographic"
        end
    end
end

@testset "CRC: 3D appenders preserve rich scene siblings" begin
    for kind in (:surface_xyz, :surface_z, :scatter3d, :quiver3d)
        @testset "$kind raw Plot" begin
            figure = _seed_rich_three_d_scene!(
                plot_scatter3d(1:3, 1:3, 1:3),
            )
            options = kind in (:scatter3d, :quiver3d) ?
                      (
                          xlabel="updated-x",
                          perspective=true,
                          grid=true,
                          showaxis=true,
                      ) :
                      (
                          xlabel="updated-x",
                          grid=true,
                          showaxis=true,
                      )
            @test _apply_three_d_mutator!(
                kind,
                figure;
                options...,
            ) === nothing
            _test_rich_three_d_scene(
                figure;
                projection=kind in (:scatter3d, :quiver3d) ?
                           "perspective" :
                           "orthographic",
            )
        end

        @testset "$kind SubplotFigure" begin
            specs = Union{Missing, Spec}[Spec(kind="scene");;]
            figure = _seed_rich_three_d_scene!(
                subplots(
                    1,
                    1;
                    sync=false,
                    specs=specs,
                    per_subplot_legends=false,
                ),
            )
            options = kind in (:scatter3d, :quiver3d) ?
                      (
                          xlabel="updated-x",
                          perspective=true,
                          grid=true,
                          showaxis=true,
                      ) :
                      (
                          xlabel="updated-x",
                          grid=true,
                          showaxis=true,
                      )
            @test _apply_three_d_mutator!(
                kind,
                figure;
                options...,
            ) === figure
            _test_rich_three_d_scene(
                figure;
                projection=kind in (:scatter3d, :quiver3d) ?
                           "perspective" :
                           "orthographic",
            )
        end
    end
end

@testset "CRC: 3D appenders can select orthographic projection" begin
    for kind in (:scatter3d, :quiver3d)
        figure = _seed_rich_three_d_scene!(
            plot_scatter3d(1:3, 1:3, 1:3),
        )
        camera = _three_d_fields(
            _three_d_fields(_three_d_fields(figure.layout)[:scene])[:camera],
        )
        _three_d_fields(camera[:projection])[:type] = "perspective"

        @test _apply_three_d_mutator!(
            kind,
            figure;
            perspective=false,
        ) === nothing
        updated_camera = _three_d_fields(
            _three_d_fields(_three_d_fields(figure.layout)[:scene])[:camera],
        )
        @test _three_d_fields(updated_camera[:projection])[:type] ==
              "orthographic"
        eye = _three_d_fields(updated_camera[:eye])
        @test (eye[:x], eye[:y], eye[:z]) == (1.25, 1.5, 1.75)
    end
end

@testset "CRC: scatter3d constructor and mutator style parity" begin
    style_options = (
        mode=["markers", "lines"],
        color=["red", "blue"],
        legend=["first", "second"],
        marker_size=[7, 9],
        marker_symbol=["diamond", "circle"],
        linewidth=[3, 4],
        showlegend=[false, true],
    )

    constructor = plot_scatter3d(
        1:3,
        1:3,
        1:3;
        style_options...,
    )
    expected_single = (
        mode="markers",
        color="red",
        legend="first",
        marker_size=7,
        marker_symbol="diamond",
        linewidth=3,
        showlegend=false,
    )
    @test _three_d_trace_style(only(constructor.data)) ==
          expected_single

    mutated = plot_scatter3d(1:3, 1:3, 1:3)
    @test plot_scatter3d!(
        mutated,
        1:3,
        1:3,
        1:3;
        style_options...,
    ) === nothing
    @test _three_d_trace_style(last(mutated.data)) ==
          expected_single

    coordinates = UnitRange{Int}[1:3, 4:6]
    overlong_options = (
        mode=["markers", "lines", "lines+markers"],
        color=["red", "blue", "green"],
        legend=["first", "second", "third"],
        marker_size=[5, 6, 7],
        marker_symbol=["circle", "diamond", "square"],
        linewidth=[1, 2, 3],
        showlegend=[true, false, true],
    )
    multi_constructor = plot_scatter3d(
        coordinates,
        coordinates,
        coordinates;
        overlong_options...,
    )
    @test length(multi_constructor.data) == 2

    multi_mutated = plot_scatter3d(1:3, 1:3, 1:3)
    initial_trace_count = length(multi_mutated.data)
    @test plot_scatter3d!(
        multi_mutated,
        coordinates,
        coordinates,
        coordinates;
        overlong_options...,
    ) === nothing
    appended = multi_mutated.data[(initial_trace_count + 1):end]
    @test length(appended) == 2
    @test _three_d_trace_style.(appended) ==
          _three_d_trace_style.(multi_constructor.data)
    @test getfield.(
        _three_d_trace_style.(multi_constructor.data),
        :legend,
    ) == ["first", "second"]

    short_options = (
        mode=["markers"],
        color=["red"],
        legend=["first"],
        marker_size=[5],
        marker_symbol=["circle"],
        linewidth=[2],
        showlegend=[false],
    )
    short = plot_scatter3d(
        coordinates,
        coordinates,
        coordinates;
        short_options...,
    )
    @test _three_d_trace_style(short.data[1]) == (
        mode="markers",
        color="red",
        legend="first",
        marker_size=5,
        marker_symbol="circle",
        linewidth=2.0,
        showlegend=false,
    )
    @test _three_d_trace_style(short.data[2]) == (
        mode="lines",
        color="",
        legend="",
        marker_size=nothing,
        marker_symbol=nothing,
        linewidth=nothing,
        showlegend=nothing,
    )
end
