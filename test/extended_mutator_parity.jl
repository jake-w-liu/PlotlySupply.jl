using Test
using PlotlySupply

_extended_fields(value) =
    value isa AbstractDict ? value : value.fields

function _extended_title_text(value)
    if value isa AbstractDict ||
       value isa PlotlySupply.PlotlyBase.PlotlyAttribute
        return get(_extended_fields(value), :text, nothing)
    end
    return value
end

function _extended_axis(layout, root::Symbol, axis::Symbol)
    root_fields = _extended_fields(
        _extended_fields(layout)[root],
    )
    return _extended_fields(root_fields[axis])
end

function _seed_extended_scene!(figure)
    scene = _extended_fields(
        _extended_fields(figure.layout)[:scene],
    )
    for (axis, label) in (
        (:xaxis, "old-x"),
        (:yaxis, "old-y"),
        (:zaxis, "old-z"),
    )
        scene[axis] = attr(
            title=attr(
                text=label,
                font=attr(color="red", size=18),
            ),
            range=[-2.0, 2.0],
            showgrid=false,
            visible=false,
            tickfont=attr(color="blue"),
        )
    end
    scene[:aspectmode] = "data"
    scene[:camera] = attr(
        eye=attr(x=1.25, y=1.5, z=1.75),
        projection=attr(type="orthographic"),
    )
    return figure
end

function _test_extended_scene(figure)
    layout = _extended_fields(figure.layout)
    scene = _extended_fields(layout[:scene])
    @test scene[:aspectmode] == "cube"
    @test _extended_title_text(layout[:title]) ==
          "updated-title"

    for (axis, label) in (
        (:xaxis, "updated-x"),
        (:yaxis, "updated-y"),
        (:zaxis, "updated-z"),
    )
        axis_fields = _extended_fields(scene[axis])
        title_fields = _extended_fields(axis_fields[:title])
        @test title_fields[:text] == label
        @test _extended_fields(title_fields[:font])[:color] ==
              "red"
        @test axis_fields[:range] == [0.0, 5.0]
        @test axis_fields[:showgrid] === true
        @test axis_fields[:visible] === true
        @test _extended_fields(axis_fields[:tickfont])[:color] ==
              "blue"
    end

    camera = _extended_fields(scene[:camera])
    @test _extended_fields(camera[:projection])[:type] ==
          "perspective"
    eye = _extended_fields(camera[:eye])
    @test (eye[:x], eye[:y], eye[:z]) ==
          (1.25, 1.5, 1.75)
    return nothing
end

function _extended_constructor_keywords(function_object)
    result = Set{Symbol}()
    for method in methods(function_object)
        union!(
            result,
            filter(
                !=(Symbol("kwargs...")),
                Base.kwarg_decl(method),
            ),
        )
    end
    delete!(result, :show)
    return result
end

function _extended_mutator_keywords(function_object)
    result = Set{Symbol}()
    for method in methods(function_object)
        signature =
            Base.unwrap_unionall(method.sig).parameters
        length(signature) >= 2 || continue
        signature[2] === Any || continue
        union!(
            result,
            filter(
                !=(Symbol("kwargs...")),
                Base.kwarg_decl(method),
            ),
        )
    end
    return result
end

@testset "CRC: extended constructors and mutators expose the same options" begin
    for (constructor, mutator) in (
        (plot_area, plot_area!),
        (plot_candlestick, plot_candlestick!),
        (plot_ohlc, plot_ohlc!),
        (plot_histogram2d, plot_histogram2d!),
        (plot_ternary, plot_ternary!),
        (plot_mesh3d, plot_mesh3d!),
        (plot_isosurface, plot_isosurface!),
        (plot_volume, plot_volume!),
        (plot_streamtube, plot_streamtube!),
    )
        @test _extended_constructor_keywords(constructor) ==
              _extended_mutator_keywords(mutator)
    end
end

@testset "CRC: extended Cartesian mutators apply layout options" begin
    area_figure = plot_scatter(1:3, 1:3)
    @test plot_area!(
        area_figure,
        1:3,
        [2.0, 1.0, 3.0];
        xlabel="area-x",
        ylabel="area-y",
        xrange=[0.0, 4.0],
        yrange=[-1.0, 5.0],
        grid=false,
    ) === nothing
    area_layout = _extended_fields(area_figure.layout)
    @test _extended_title_text(
        _extended_fields(area_layout[:xaxis])[:title],
    ) == "area-x"
    @test _extended_title_text(
        _extended_fields(area_layout[:yaxis])[:title],
    ) == "area-y"
    @test _extended_fields(area_layout[:xaxis])[:range] ==
          [0.0, 4.0]
    @test _extended_fields(area_layout[:yaxis])[:range] ==
          [-1.0, 5.0]
    @test _extended_fields(area_layout[:xaxis])[:showgrid] ===
          false
    @test _extended_fields(area_layout[:yaxis])[:showgrid] ===
          false
    @test plot_area!(
        area_figure,
        1:3,
        [3.0, 2.0, 1.0],
    ) === nothing
    @test _extended_fields(
        _extended_fields(area_figure.layout)[:xaxis],
    )[:showgrid] === false
    @test _extended_fields(
        _extended_fields(area_figure.layout)[:yaxis],
    )[:showgrid] === false
    @test plot_area!(
        area_figure,
        1:3,
        [3.0, 2.0, 1.0];
        grid=true,
    ) === nothing
    @test _extended_fields(
        _extended_fields(area_figure.layout)[:xaxis],
    )[:showgrid] === true
    @test _extended_fields(
        _extended_fields(area_figure.layout)[:yaxis],
    )[:showgrid] === true

    financial_data = (
        1:3,
        [1.0, 2.0, 3.0],
        [2.0, 3.0, 4.0],
        [0.0, 1.0, 2.0],
        [1.5, 2.5, 3.5],
    )
    for (mutator, prefix) in (
        (plot_candlestick!, "candlestick"),
        (plot_ohlc!, "ohlc"),
    )
        figure = plot_scatter(1:3, 1:3)
        @test mutator(
            figure,
            financial_data...;
            xlabel="$prefix-x",
            ylabel="$prefix-y",
            grid=false,
        ) === nothing
        layout = _extended_fields(figure.layout)
        @test _extended_title_text(
            _extended_fields(layout[:xaxis])[:title],
        ) == "$prefix-x"
        @test _extended_title_text(
            _extended_fields(layout[:yaxis])[:title],
        ) == "$prefix-y"
        @test _extended_fields(layout[:xaxis])[:showgrid] ===
              false
        @test _extended_fields(layout[:yaxis])[:showgrid] ===
              false
        @test mutator(
            figure,
            financial_data...;
            grid=true,
        ) === nothing
        layout = _extended_fields(figure.layout)
        @test _extended_fields(
            layout[:xaxis],
        )[:showgrid] === true
        @test _extended_fields(
            layout[:yaxis],
        )[:showgrid] === true
    end

    histogram_figure = plot_scatter(1:3, 1:3)
    @test plot_histogram2d!(
        histogram_figure,
        [1.0, 2.0, 3.0],
        [3.0, 2.0, 1.0];
        xlabel="histogram-x",
        ylabel="histogram-y",
        grid=false,
    ) === nothing
    histogram_layout = _extended_fields(
        histogram_figure.layout,
    )
    @test _extended_title_text(
        _extended_fields(histogram_layout[:xaxis])[:title],
    ) == "histogram-x"
    @test _extended_title_text(
        _extended_fields(histogram_layout[:yaxis])[:title],
    ) == "histogram-y"
    @test _extended_fields(
        histogram_layout[:xaxis],
    )[:showgrid] === false
    @test _extended_fields(
        histogram_layout[:yaxis],
    )[:showgrid] === false
    @test plot_histogram2d!(
        histogram_figure,
        [1.0, 2.0, 3.0],
        [3.0, 2.0, 1.0];
        grid=true,
    ) === nothing
    histogram_layout = _extended_fields(
        histogram_figure.layout,
    )
    @test _extended_fields(
        histogram_layout[:xaxis],
    )[:showgrid] === true
    @test _extended_fields(
        histogram_layout[:yaxis],
    )[:showgrid] === true

    subplot_figure = subplots(
        1,
        1;
        sync=false,
        per_subplot_legends=false,
    )
    @test plot_area!(
        subplot_figure,
        1:3,
        [1.0, 2.0, 3.0];
        grid=false,
    ) === subplot_figure
    subplot_layout = _extended_fields(
        subplot_figure.layout,
    )
    @test _extended_fields(
        subplot_layout[:xaxis],
    )[:showgrid] === false
    @test plot_area!(
        subplot_figure,
        1:3,
        [3.0, 2.0, 1.0];
        grid=true,
    ) === subplot_figure
    subplot_layout = _extended_fields(
        subplot_figure.layout,
    )
    @test _extended_fields(
        subplot_layout[:xaxis],
    )[:showgrid] === true
    @test _extended_fields(
        subplot_layout[:yaxis],
    )[:showgrid] === true
end

@testset "CRC: ternary mutators preserve axis siblings" begin
    figure = plot_ternary(
        [0.2, 0.3],
        [0.3, 0.4],
        [0.5, 0.3];
        alabel="old-a",
        blabel="old-b",
        clabel="old-c",
    )
    ternary = _extended_fields(
        _extended_fields(figure.layout)[:ternary],
    )
    @test _extended_fields(
        ternary[:aaxis],
    )[:title] == "old-a"
    for axis in (:aaxis, :baxis, :caxis)
        fields = _extended_fields(ternary[axis])
        fields[:title] = attr(
            text=_extended_title_text(fields[:title]),
            font=attr(color="red"),
        )
        fields[:tickfont] = attr(color="blue")
    end

    @test plot_ternary!(
        figure,
        [0.4, 0.1],
        [0.2, 0.6],
        [0.4, 0.3];
        alabel="new-a",
        blabel="new-b",
        clabel="new-c",
    ) === nothing
    for (axis, label) in (
        (:aaxis, "new-a"),
        (:baxis, "new-b"),
        (:caxis, "new-c"),
    )
        fields = _extended_axis(
            figure.layout,
            :ternary,
            axis,
        )
        title = _extended_fields(fields[:title])
        @test title[:text] == label
        @test _extended_fields(title[:font])[:color] ==
              "red"
        @test _extended_fields(fields[:tickfont])[:color] ==
              "blue"
    end

    specs = Union{Missing, Spec}[Spec(kind="ternary");;]
    subplot_figure = subplots(
        1,
        1;
        sync=false,
        specs=specs,
        per_subplot_legends=false,
    )
    original_domain = deepcopy(
        _extended_fields(
            _extended_fields(
                subplot_figure.layout,
            )[:ternary],
        )[:domain],
    )
    @test plot_ternary!(
        subplot_figure,
        [0.2, 0.3],
        [0.3, 0.4],
        [0.5, 0.3];
        alabel="subplot-a",
    ) === subplot_figure
    subplot_ternary = _extended_fields(
        _extended_fields(
            subplot_figure.layout,
        )[:ternary],
    )
    @test _extended_title_text(
        _extended_fields(
            subplot_ternary[:aaxis],
        )[:title],
    ) == "subplot-a"
    @test subplot_ternary[:domain] == original_domain
end

@testset "CRC: extended 3D mutators apply and preserve scene options" begin
    x = [0.0, 1.0, 0.0, 0.0]
    y = [0.0, 0.0, 1.0, 0.0]
    z = [0.0, 0.0, 0.0, 1.0]
    value = [0.0, 1.0, 2.0, 3.0]
    calls = (
        (figure; kwargs...) -> plot_mesh3d!(
            figure,
            x,
            y,
            z;
            i=[0],
            j=[1],
            k=[2],
            kwargs...,
        ),
        (figure; kwargs...) -> plot_isosurface!(
            figure,
            x,
            y,
            z,
            value;
            kwargs...,
        ),
        (figure; kwargs...) -> plot_volume!(
            figure,
            x,
            y,
            z,
            value;
            kwargs...,
        ),
        (figure; kwargs...) -> plot_streamtube!(
            figure,
            x,
            y,
            z,
            value,
            value,
            value;
            kwargs...,
        ),
    )

    for call in calls
        figure = _seed_extended_scene!(
            plot_scatter3d(x, y, z),
        )
        original_count = length(figure.data)
        @test call(
            figure;
            xlabel="updated-x",
            ylabel="updated-y",
            zlabel="updated-z",
            aspectmode="cube",
            title="updated-title",
            xrange=[0.0, 5.0],
            yrange=[0.0, 5.0],
            zrange=[0.0, 5.0],
            perspective=true,
            grid=true,
            showaxis=true,
        ) === nothing
        @test length(figure.data) == original_count + 1
        _test_extended_scene(figure)
    end
end

@testset "CRC: mesh topology is validated atomically" begin
    x = [0.0, 1.0, 0.0, 0.0]
    y = [0.0, 0.0, 1.0, 0.0]
    z = [0.0, 0.0, 0.0, 1.0]

    @test_throws ArgumentError plot_mesh3d(
        x,
        y,
        z;
        i=[0],
    )
    @test_throws ArgumentError plot_mesh3d(
        x,
        y,
        z;
        i=[0, 1],
        j=[1],
        k=[2],
    )
    @test_throws ArgumentError plot_mesh3d(
        x,
        y,
        z;
        i=[0],
        j=[1],
        k=[4],
    )
    @test_throws ArgumentError plot_mesh3d(
        x,
        y[1:3],
        z,
    )
    @test_throws ArgumentError plot_mesh3d(
        x,
        y,
        z;
        intensity=[1.0, 2.0],
    )
    @test_throws ArgumentError plot_mesh3d(
        x,
        y,
        z;
        opacity=1.5,
    )
    for indices in (
        0,
        reshape([0], 1, 1),
    )
        @test_throws ArgumentError plot_mesh3d(
            x,
            y,
            z;
            i=indices,
            j=indices,
            k=indices,
        )
    end

    figure = plot_mesh3d(
        x,
        y,
        z;
        i=[0],
        j=[1],
        k=[2],
    )
    before = json(figure)
    @test_throws ArgumentError plot_mesh3d!(
        figure,
        x,
        y,
        z;
        i=[0],
    )
    @test json(figure) == before
    for indices in (
        0,
        reshape([0], 1, 1),
    )
        @test_throws ArgumentError plot_mesh3d!(
            figure,
            x,
            y,
            z;
            i=indices,
            j=indices,
            k=indices,
        )
        @test json(figure) == before
    end
end
