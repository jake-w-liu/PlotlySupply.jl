using Test
using PlotlySupply

const _MUTATOR_REFRESH_CALLS = Ref(0)
const _MutatorProbeTrace = GenericTrace{IdDict{Symbol,Any}}

struct _FailingSpliceVector <: AbstractVector{Int} end
Base.IndexStyle(::Type{_FailingSpliceVector}) = IndexLinear()
Base.size(::_FailingSpliceVector) = (1,)
Base.getindex(::_FailingSpliceVector, ::Int) =
    error("injected splice read failure")

function PlotlySupply._plotlyjs_refresh!(
    ::SyncPlot,
    ::Vector{_MutatorProbeTrace},
    ::Layout;
    kwargs...,
)
    _MUTATOR_REFRESH_CALLS[] += 1
    return nothing
end

function _mutator_probe_plot(; trace_count::Int=2)
    traces = [
        GenericTrace(IdDict{Symbol,Any}(
            :type => "scatter",
            :x => [1, 2, 3],
            :y => [1, 2, 3],
        ))
        for _ in 1:trace_count
    ]
    layout = Layout(
        geo=attr(showcoastlines=true),
        mapbox=attr(zoom=1),
        scene=attr(aspectmode="auto"),
        ternary=attr(sum=1),
        annotations=[attr(text="old-annotation")],
        shapes=[attr(type="line")],
        images=[attr(source="old-image")],
    )
    return Plot(traces, layout)
end

function _attach_mutator_refresh_probe(p::Plot)
    backend = (
        isopen=window -> true,
        close=window -> nothing,
    )
    resources = PlotlySupply._SyncPlotResources(nothing, backend)
    sp = SyncPlot(p, nothing, nothing, "mutator-refresh-probe", resources)
    old, registered = PlotlySupply._register_displayed_syncplot!(p, sp)
    old === nothing || error("unexpected existing refresh probe")
    registered || error("failed to register refresh probe")
    return sp
end

function _layout_update_value(p::Plot, field::Symbol)
    value = p.layout.fields[field]
    return field in (:annotations, :shapes, :images) ? only(value) : value
end

function _exercise_splice_overload!(
    splice!,
    target_kind::Symbol,
    form::Symbol,
)
    p = _mutator_probe_plot()
    sp = _attach_mutator_refresh_probe(p)
    target = target_kind === :plot ? p : sp
    data_ref = p.data
    trace_ref = p.data[1]
    x_ref = p.data[1][:x]
    _MUTATOR_REFRESH_CALLS[] = 0

    try
        result = if form === :default
            splice!(target; y=4)
        elseif form === :vector_index
            splice!(target, [1, 2], 3; y=[[4], [5, 6]])
        elseif form === :int_index
            splice!(target, 1; y=[4, 5])
        elseif form === :flat_range
            splice!(target, 1; y=4:5)
        elseif form === :nested_ranges
            splice!(target, [1, 2], 3; y=UnitRange{Int}[4:4, 5:6])
        elseif form === :range_indices
            splice!(target, 1:2, 3; y=[[4], [5, 6]])
        elseif form === :dict_plus_int
            splice!(target, Dict(:y => [[4]]), 1, 3)
        else
            error("unsupported splice test form: $form")
        end

        prepend = splice! === prependtraces!
        expected_first = if form === :default
            prepend ? [4, 1, 2, 3] : [1, 2, 3, 4]
        elseif form in (
            :vector_index,
            :nested_ranges,
            :range_indices,
            :dict_plus_int,
        )
            prepend ? [4, 1, 2] : [2, 3, 4]
        else
            prepend ? [4, 5, 1, 2, 3] : [1, 2, 3, 4, 5]
        end

        @test result === target
        @test p.data === data_ref
        @test p.data[1] === trace_ref
        @test p.data[1][:x] === x_ref
        @test p.data[1][:y] == expected_first
        if form in (:vector_index, :nested_ranges, :range_indices)
            @test p.data[2][:y] == (prepend ? [5, 6, 1] : [3, 5, 6])
        else
            @test p.data[2][:y] == [1, 2, 3]
        end
        @test _MUTATOR_REFRESH_CALLS[] == 1
    finally
        close(sp)
    end
end

@testset "raw Plot layout updater parity" begin
    updater_fields = (
        update_geos! => :geo,
        update_mapboxes! => :mapbox,
        update_scenes! => :scene,
        update_ternaries! => :ternary,
        update_annotations! => :annotations,
        update_shapes! => :shapes,
        update_images! => :images,
    )

    for target_kind in (:plot, :syncplot)
        for (updater!, field) in updater_fields
            p = _mutator_probe_plot()
            sp = _attach_mutator_refresh_probe(p)
            target = target_kind === :plot ? p : sp
            layout_ref = p.layout
            data_ref = p.data
            trace_ref = p.data[1]
            vector_value_ref = field in (:annotations, :shapes, :images) ?
                               only(p.layout.fields[field]) : nothing
            _MUTATOR_REFRESH_CALLS[] = 0

            try
                result = updater!(target, attr(visible=false); opacity=0.25)
                updated = _layout_update_value(p, field)

                @test result === target
                @test p.layout === layout_ref
                @test p.data === data_ref
                @test p.data[1] === trace_ref
                @test updated[:visible] == false
                @test updated[:opacity] == 0.25
                if vector_value_ref !== nothing
                    @test updated === vector_value_ref
                end
                @test _MUTATOR_REFRESH_CALLS[] == 1
                @test which(updater!, (typeof(p),)).module === PlotlySupply
                @test which(
                    updater!,
                    (typeof(p), typeof(attr())),
                ).module === PlotlySupply
            finally
                close(sp)
            end
        end
    end
end

@testset "extend/prepend keyword conversion" begin
    scalar = PlotlySupply._trace_splice_tovec(4)
    @test scalar == Vector[[4]]

    flat = [4, 5]
    converted_flat = PlotlySupply._trace_splice_tovec(flat)
    @test converted_flat == Vector[[4, 5]]
    @test only(converted_flat) === flat

    nested = [[4], [5, 6]]
    @test PlotlySupply._trace_splice_tovec(nested) === nested

    flat_range = 4:5
    converted_flat_range = PlotlySupply._trace_splice_tovec(flat_range)
    @test length(converted_flat_range) == 1
    @test only(converted_flat_range) === flat_range

    flat_parent = [4, 5, 6]
    flat_view = view(flat_parent, 1:2)
    converted_flat_view = PlotlySupply._trace_splice_tovec(flat_view)
    @test length(converted_flat_view) == 1
    @test only(converted_flat_view) === flat_view

    nested_ranges = UnitRange{Int}[4:5, 6:7]
    @test PlotlySupply._trace_splice_tovec(nested_ranges) === nested_ranges

    nested_parent = [[4, 5], [6, 7]]
    outer_view = view(nested_parent, :)
    @test PlotlySupply._trace_splice_tovec(outer_view) === outer_view

    inner_views = [view(values, :) for values in nested_parent]
    @test PlotlySupply._trace_splice_tovec(inner_views) === inner_views

    mixed_nested = AbstractVector[4:5, [6, 7]]
    @test PlotlySupply._trace_splice_tovec(mixed_nested) === mixed_nested

    empty_nested = Vector{Vector{Int}}()
    @test PlotlySupply._trace_splice_tovec(empty_nested) === empty_nested

    empty_nested_ranges = UnitRange{Int}[]
    @test PlotlySupply._trace_splice_tovec(empty_nested_ranges) ===
          empty_nested_ranges
    for splice! in (extendtraces!, prependtraces!)
        p = _mutator_probe_plot()
        before = [copy(trace[:y]) for trace in p.data]
        @test_throws ArgumentError splice!(p, [1]; y=empty_nested_ranges)
        @test [trace[:y] for trace in p.data] == before
        @test splice!(p, Int[]; y=empty_nested_ranges) === p
        @test [trace[:y] for trace in p.data] == before
    end

    empty_flat = Int[]
    converted_empty = PlotlySupply._trace_splice_tovec(empty_flat)
    @test length(converted_empty) == 1
    @test only(converted_empty) === empty_flat

    abstractly_typed = Any[[4], [5]]
    converted_abstract = PlotlySupply._trace_splice_tovec(abstractly_typed)
    @test length(converted_abstract) == 1
    @test only(converted_abstract) === abstractly_typed

    tuple_value = (4, 5)
    converted_tuple = PlotlySupply._trace_splice_tovec(tuple_value)
    @test converted_tuple == Vector[[(4, 5)]]
end

@testset "extend/prepend overload and refresh parity" begin
    for splice! in (extendtraces!, prependtraces!)
        for target_kind in (:plot, :syncplot)
            for form in (
                :default,
                :vector_index,
                :int_index,
                :flat_range,
                :nested_ranges,
                :range_indices,
                :dict_plus_int,
            )
                _exercise_splice_overload!(splice!, target_kind, form)
            end
        end
    end

    p = _mutator_probe_plot()
    sp = _attach_mutator_refresh_probe(p)
    try
        for splice! in (extendtraces!, prependtraces!)
            @test which(splice!, (typeof(p),)).module === PlotlySupply
            @test which(
                splice!,
                (typeof(p), Vector{Int}),
            ).module === PlotlySupply
            @test which(
                splice!,
                (typeof(p), UnitRange{Int}),
            ).module === PlotlySupply
            @test which(splice!, (typeof(p), Int)).module === PlotlySupply
            @test which(
                splice!,
                (typeof(p), Dict{Symbol,Vector{Vector{Int}}}, Int),
            ).module === PlotlySupply

            @test which(splice!, (typeof(sp),)).module === PlotlySupply
            @test which(
                splice!,
                (typeof(sp), Vector{Int}),
            ).module === PlotlySupply
            @test which(
                splice!,
                (typeof(sp), UnitRange{Int}),
            ).module === PlotlySupply
            @test which(splice!, (typeof(sp), Int)).module === PlotlySupply
            @test which(
                splice!,
                (typeof(sp), Dict{Symbol,Vector{Vector{Int}}}, Int),
            ).module === PlotlySupply
        end
    finally
        close(sp)
    end
end

@testset "extend/prepend staging is atomic" begin
    updates = AbstractVector[[4], _FailingSpliceVector()]
    for splice! in (extendtraces!, prependtraces!)
        for target_kind in (:plot, :syncplot)
            p = _mutator_probe_plot()
            sp = _attach_mutator_refresh_probe(p)
            target = target_kind === :plot ? p : sp
            data_ref = p.data
            trace_refs = copy(p.data)
            y_refs = [trace[:y] for trace in p.data]
            before = [copy(values) for values in y_refs]
            _MUTATOR_REFRESH_CALLS[] = 0

            try
                @test_throws ErrorException splice!(
                    target,
                    Dict(:y => updates),
                    [1, 2],
                )
                @test p.data === data_ref
                @test all(p.data[index] === trace_refs[index] for index in 1:2)
                @test all(p.data[index][:y] === y_refs[index] for index in 1:2)
                @test [trace[:y] for trace in p.data] == before
                @test _MUTATOR_REFRESH_CALLS[] == 0
            finally
                close(sp)
            end
        end
    end
end

@testset "mutator parity has no method ambiguity" begin
    ambiguities = Test.detect_ambiguities(
        PlotlyBase,
        PlotlySupply;
        recursive=false,
    )
    relevant = filter(ambiguities) do pair
        any(method -> method.module === PlotlySupply, pair)
    end
    @test isempty(relevant)
end

@testset "mutator parity loads without method overwrite" begin
    project_file = something(
        Base.active_project(),
        normpath(joinpath(@__DIR__, "..", "Project.toml")),
    )
    output = IOBuffer()
    command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=no --warn-overwrite=yes --project=$(dirname(project_file)) -e $("using PlotlySupply")`
    process = run(pipeline(ignorestatus(command), stdout=output, stderr=output))
    diagnostics = String(take!(output))
    @test success(process)
    @test !occursin("overwritten in module PlotlySupply", diagnostics)
end
