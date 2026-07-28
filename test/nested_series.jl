function _nested_series_auto_x_allocated(values)
    PlotlySupply._auto_xvalues(values)
    return @allocated PlotlySupply._auto_xvalues(values)
end

@testset "CRC: abstract nested-series routing and compact auto coordinates" begin
    series_ranges = UnitRange{Int}[1:3, 4:6]
    coordinate_ranges = UnitRange{Int}[10:12, 20:22]

    nested_vectors = [[1, 2, 3], [4, 5, 6]]
    outer_view = view(nested_vectors, :)
    inner_view_parent = [[1, 2, 3, 99], [4, 5, 6, 99]]
    inner_views = [view(values, 1:3) for values in inner_view_parent]
    mixed_series = AbstractVector[1:3, view([4, 5, 6, 99], 1:3)]
    nested_range = LinRange([1.0, 2.0], [3.0, 4.0], 2)
    flat_parent = [1, 2, 3, 4]
    flat_view = view(flat_parent, 1:3)

    @test PlotlySupply._is_nested_series(series_ranges)
    @test PlotlySupply._is_nested_series(outer_view)
    @test PlotlySupply._is_nested_series(inner_views)
    @test PlotlySupply._is_nested_series(mixed_series)
    @test PlotlySupply._is_nested_series(nested_range)
    @test !PlotlySupply._is_nested_series(1:3)
    @test !PlotlySupply._is_nested_series(flat_view)

    for values in (series_ranges, outer_view, inner_views, mixed_series, nested_range)
        fig = plot_scatter(values)
        @test length(fig.data) == 2
        @test collect(fig.data[1].fields[:y]) == collect(values[1])
        @test collect(fig.data[2].fields[:y]) == collect(values[2])
    end

    empty_nested = AbstractVector[]
    @test PlotlySupply._is_nested_series(empty_nested)
    @test isempty(plot_scatter(empty_nested).data)

    auto_x = PlotlySupply._auto_xvalues(series_ranges)
    @test auto_x isa Vector{UnitRange{Int}}
    @test auto_x == [0:2, 0:2]
    @test PlotlySupply._auto_xvalues(1:3) == 0:2
    @test PlotlySupply._auto_xvalues(empty_nested) isa Vector{UnitRange{Int}}
    @test isempty(PlotlySupply._auto_xvalues(empty_nested))

    # The generated coordinates retain one range per series, not one integer
    # per point. This bound is independent of the 6.4 million represented
    # coordinates.
    compact_x = PlotlySupply._auto_xvalues(fill(1:100_000, 64))
    @test Base.summarysize(compact_x) < 2_048

    linear_series = LinRange(zeros(100_000), ones(100_000), 64)
    stepped_series = range(
        zeros(100_000);
        step=ones(100_000),
        length=64,
    )
    for lazy_series in (linear_series, stepped_series)
        lazy_x = PlotlySupply._auto_xvalues(lazy_series)
        @test lazy_x == fill(0:99_999, 64)
        @test Base.summarysize(lazy_x) < 2_048
        @test _nested_series_auto_x_allocated(lazy_series) < 16_384
    end

    constructors = (
        ("scatter", () -> plot_scatter(coordinate_ranges, series_ranges), 2),
        ("stem", () -> plot_stem(coordinate_ranges, series_ranges), 8),
        ("bar", () -> plot_bar(coordinate_ranges, series_ranges), 2),
        ("histogram", () -> plot_histogram(series_ranges), 2),
        ("box", () -> plot_box(coordinate_ranges, series_ranges), 2),
        ("violin", () -> plot_violin(coordinate_ranges, series_ranges), 2),
        ("scatterpolar", () -> plot_scatterpolar(coordinate_ranges, series_ranges), 2),
        (
            "scatter3d",
            () -> plot_scatter3d(
                coordinate_ranges,
                coordinate_ranges,
                series_ranges,
            ),
            2,
        ),
        ("area", () -> plot_area(coordinate_ranges, series_ranges), 2),
    )
    for (name, make_figure, expected) in constructors
        @testset "$name constructor" begin
            fig = make_figure()
            @test length(fig.data) == expected
        end
    end

    y_only_constructors = (
        ("scatter", () -> plot_scatter(series_ranges), 2),
        ("stem", () -> plot_stem(series_ranges), 8),
        ("bar", () -> plot_bar(series_ranges), 2),
        ("box", () -> plot_box(series_ranges), 2),
        ("violin", () -> plot_violin(series_ranges), 2),
        ("area", () -> plot_area(series_ranges), 2),
    )
    for (name, make_figure, expected) in y_only_constructors
        @testset "$name y-only constructor" begin
            fig = make_figure()
            @test length(fig.data) == expected
            @test collect(fig.data[1].fields[:y]) == [1, 2, 3]
        end
    end

    explicit_mutators = (
        ("scatter!", fig -> plot_scatter!(fig, coordinate_ranges, series_ranges), 2),
        ("stem!", fig -> plot_stem!(fig, coordinate_ranges, series_ranges), 8),
        ("bar!", fig -> plot_bar!(fig, coordinate_ranges, series_ranges), 2),
        ("histogram!", fig -> plot_histogram!(fig, series_ranges), 2),
        ("box!", fig -> plot_box!(fig, coordinate_ranges, series_ranges), 2),
        ("violin!", fig -> plot_violin!(fig, coordinate_ranges, series_ranges), 2),
        (
            "scatterpolar!",
            fig -> plot_scatterpolar!(fig, coordinate_ranges, series_ranges),
            2,
        ),
        (
            "scatter3d!",
            fig -> plot_scatter3d!(
                fig,
                coordinate_ranges,
                coordinate_ranges,
                series_ranges,
            ),
            2,
        ),
        ("area!", fig -> plot_area!(fig, coordinate_ranges, series_ranges), 2),
    )
    for (name, mutate!, expected_delta) in explicit_mutators
        @testset "$name explicit coordinates" begin
            fig = plot_scatter(1:3, 1:3)
            initial_count = length(fig.data)
            @test mutate!(fig) === nothing
            @test length(fig.data) == initial_count + expected_delta
        end
    end

    y_only_mutators = (
        ("scatter!", fig -> plot_scatter!(fig, series_ranges), 2, true),
        ("stem!", fig -> plot_stem!(fig, series_ranges), 8, true),
        ("bar!", fig -> plot_bar!(fig, series_ranges), 2, true),
        ("box!", fig -> plot_box!(fig, series_ranges), 2, false),
        ("violin!", fig -> plot_violin!(fig, series_ranges), 2, false),
        ("area!", fig -> plot_area!(fig, series_ranges), 2, true),
    )
    for (name, mutate!, expected_delta, has_generated_x) in y_only_mutators
        @testset "$name generated coordinates" begin
            fig = plot_scatter(1:3, 1:3)
            initial_count = length(fig.data)
            @test mutate!(fig) === nothing
            @test length(fig.data) == initial_count + expected_delta
            if has_generated_x
                @test collect(fig.data[initial_count + 1].fields[:x]) == [0, 1, 2]
            else
                @test collect(fig.data[initial_count + 1].fields[:y]) == [1, 2, 3]
            end
        end
    end

    empty_nested_errors = Vector{Vector{Float64}}()
    no_errors = plot_scatter(
        coordinate_ranges,
        series_ranges;
        error_x=empty_nested_errors,
        error_y=empty_nested_errors,
    )
    @test all(!haskey(trace.fields, :error_x) for trace in no_errors.data)
    @test all(!haskey(trace.fields, :error_y) for trace in no_errors.data)

    mismatch_mutators = (
        fig -> plot_scatter!(fig, coordinate_ranges[1:1], series_ranges),
        fig -> plot_stem!(fig, coordinate_ranges[1:1], series_ranges),
        fig -> plot_bar!(fig, coordinate_ranges[1:1], series_ranges),
        fig -> plot_box!(fig, coordinate_ranges[1:1], series_ranges),
        fig -> plot_violin!(fig, coordinate_ranges[1:1], series_ranges),
        fig -> plot_scatterpolar!(fig, coordinate_ranges[1:1], series_ranges),
        fig -> plot_scatter3d!(
            fig,
            coordinate_ranges[1:1],
            1:3,
            series_ranges,
        ),
        fig -> plot_area!(fig, coordinate_ranges[1:1], series_ranges),
    )
    for mutate! in mismatch_mutators
        fig = plot_scatter(1:3, 1:3)
        initial_count = length(fig.data)
        @test_throws ArgumentError mutate!(fig)
        @test length(fig.data) == initial_count
    end

    @test_throws ArgumentError plot_scatter(
        coordinate_ranges[1:1],
        series_ranges,
    )
    @test_throws ArgumentError plot_scatter(coordinate_ranges, 1:3)

    sf = PlotlySupply.subplots(1, 1; sync=false)
    @test plot_scatter!(sf, outer_view) === sf
    @test length(sf.plot.data) == 2
    @test all(trace.fields[:xaxis] == "x" for trace in sf.plot.data)
end

@testset "CRC: nested distribution layout modes" begin
    nested = UnitRange{Int}[1:3, 4:6]
    nested_x = UnitRange{Int}[10:12, 20:22]
    singleton = UnitRange{Int}[1:3]
    empty_nested = UnitRange{Int}[]

    constructor_cases = (
        (() -> plot_histogram(nested), :barmode, "overlay"),
        (() -> plot_box(nested_x, nested), :boxmode, "group"),
        (() -> plot_box(nested), :boxmode, "group"),
        (() -> plot_violin(nested_x, nested), :violinmode, "group"),
        (() -> plot_violin(nested), :violinmode, "group"),
    )
    for (make_figure, key, expected) in constructor_cases
        @test make_figure().layout.fields[key] == expected
    end

    for (make_figure, key) in (
        (() -> plot_histogram(singleton), :barmode),
        (() -> plot_histogram(empty_nested), :barmode),
        (() -> plot_box(singleton), :boxmode),
        (() -> plot_box(empty_nested), :boxmode),
        (() -> plot_violin(singleton), :violinmode),
        (() -> plot_violin(empty_nested), :violinmode),
    )
        @test !haskey(make_figure().layout.fields, key)
    end

    mutator_cases = (
        (plot_histogram!, :barmode, "overlay", "group"),
        (plot_box!, :boxmode, "group", "overlay"),
        (plot_violin!, :violinmode, "group", "overlay"),
    )
    for (mutate!, key, automatic, existing) in mutator_cases
        p = plot_scatter(1:3, 1:3)
        @test mutate!(p, nested) === nothing
        @test p.layout.fields[key] == automatic

        p = plot_scatter(1:3, 1:3)
        p.layout.fields[key] = existing
        @test mutate!(p, nested) === nothing
        @test p.layout.fields[key] == existing
    end

    p = plot_scatter(1:3, 1:3)
    @test plot_box!(p, nested_x, nested) === nothing
    @test p.layout.fields[:boxmode] == "group"
    @test plot_violin!(p, nested_x, nested) === nothing
    @test p.layout.fields[:violinmode] == "group"

    p = plot_histogram(nested)
    @test p.layout.fields[:barmode] == "overlay"
    @test plot_bar!(p, nested) === nothing
    @test p.layout.fields[:barmode] == "overlay"
    @test plot_bar!(p, nested; barmode="stack") === nothing
    @test p.layout.fields[:barmode] == "stack"
    @test plot_histogram!(p, nested) === nothing
    @test p.layout.fields[:barmode] == "stack"

    before_count = length(p.data)
    @test plot_bar!(p, empty_nested; barmode="group") === nothing
    @test length(p.data) == before_count
    @test p.layout.fields[:barmode] == "group"

    sf = PlotlySupply.subplots(
        1,
        1;
        sync=false,
        per_subplot_legends=false,
    )
    @test plot_box!(sf, nested) === sf
    @test plot_violin!(sf, nested) === sf
    @test plot_histogram!(sf, nested) === sf
    @test sf.plot.layout.fields[:boxmode] == "group"
    @test sf.plot.layout.fields[:violinmode] == "group"
    @test sf.plot.layout.fields[:barmode] == "overlay"
    for axis_key in (:xaxis, :yaxis)
        for mode_key in (:barmode, :boxmode, :violinmode)
            @test !haskey(sf.plot.layout.fields[axis_key], mode_key)
        end
    end

    sf.plot.layout.fields[:boxmode] = "overlay"
    sf.plot.layout.fields[:violinmode] = "overlay"
    sf.plot.layout.fields[:barmode] = "stack"
    @test plot_box!(sf, nested) === sf
    @test plot_violin!(sf, nested) === sf
    @test plot_histogram!(sf, nested) === sf
    @test sf.plot.layout.fields[:boxmode] == "overlay"
    @test sf.plot.layout.fields[:violinmode] == "overlay"
    @test sf.plot.layout.fields[:barmode] == "stack"
    @test plot_bar!(sf, nested; barmode="group") === sf
    @test sf.plot.layout.fields[:barmode] == "group"

    subplot_count = length(sf.plot.data)
    @test plot_bar!(sf, empty_nested; barmode="stack") === sf
    @test length(sf.plot.data) == subplot_count
    @test sf.plot.layout.fields[:barmode] == "stack"

    invalid_sf = PlotlySupply.subplots(
        1,
        1;
        sync=false,
        per_subplot_legends=false,
        specs=fill(PlotlySupply.Spec(kind="polar"), 1, 1),
    )
    invalid_layout_before = deepcopy(invalid_sf.plot.layout)
    @test_throws ArgumentError plot_box!(invalid_sf, nested)
    @test isempty(invalid_sf.plot.data)
    @test invalid_sf.plot.layout == invalid_layout_before

    counted_data = GenericTrace[scatter(x=1:3, y=1:3)]
    counted_plot = Plot(counted_data, Layout())
    counted_sync = _subplot_counting_syncplot(
        counted_plot,
        "mode-refresh-count",
    )
    for mutate! in (
        fig -> plot_histogram!(fig, nested),
        fig -> plot_box!(fig, nested),
        fig -> plot_violin!(fig, nested),
        fig -> plot_bar!(fig, nested; barmode="stack"),
    )
        _subplot_refresh_calls[] = 0
        @test mutate!(counted_sync) === nothing
        @test _subplot_refresh_calls[] == 1
    end
end
