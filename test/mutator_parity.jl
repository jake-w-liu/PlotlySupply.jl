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

function _command_probe_syncplot(p::Plot; register::Bool=false)
    scripts = String[]
    backend = (
        isopen=window -> true,
        close=window -> nothing,
        run=(window, script) -> (push!(scripts, script); "ok"),
    )
    resources = PlotlySupply._SyncPlotResources(nothing, backend)
    sp = SyncPlot(p, nothing, nothing, "command-probe", resources)
    if register
        old, registered = PlotlySupply._register_displayed_syncplot!(p, sp)
        old === nothing || error("unexpected existing command probe")
        registered || error("failed to register command probe")
    end
    return sp, scripts
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

@testset "redraw/purge use their exact renderer operations" begin
    for target_kind in (:syncplot, :registered_syncplot, :registered_plot)
        p = _mutator_probe_plot()
        sp, scripts = _command_probe_syncplot(
            p;
            register=target_kind !== :syncplot,
        )
        target = target_kind === :registered_plot ? p : sp
        data_ref = p.data
        layout_ref = p.layout
        frames_ref = p.frames
        config_ref = p.config
        divid = sp.divid

        try
            @test redraw!(target) === target
            @test p.data === data_ref
            @test p.layout === layout_ref
            @test p.frames === frames_ref
            @test p.config === config_ref
            @test sp.divid == divid
            @test length(scripts) == 1
            @test occursin("await Plotly.redraw(div);", only(scripts))
            @test !occursin("Plotly.react", only(scripts))

            empty!(scripts)
            @test purge!(target) === target
            @test p.data === data_ref
            @test isempty(p.data)
            @test p.layout == Layout()
            @test p.layout !== layout_ref
            @test p.frames === frames_ref
            @test p.config === config_ref
            @test sp.divid == divid
            @test length(scripts) == 1
            @test occursin("Plotly.purge(div);", only(scripts))
            @test !occursin("Plotly.react", only(scripts))

            first_purged_layout = p.layout
            empty!(scripts)
            @test purge!(target) === target
            @test p.data === data_ref
            @test isempty(p.data)
            @test p.layout == Layout()
            @test p.layout !== first_purged_layout
            @test p.frames === frames_ref
            @test p.config === config_ref
            @test sp.divid == divid
            @test length(scripts) == 1
            @test occursin("Plotly.purge(div);", only(scripts))
        finally
            close(sp)
        end
    end

    p = _mutator_probe_plot()
    data_ref = p.data
    @test redraw!(p) === p
    @test p.data === data_ref
    @test purge!(p) === p
    @test p.data === data_ref
    @test isempty(p.data)
    @test p.layout == Layout()
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

function _animated_config_plot()
    plot_frames = [
        frame(
            name="frame-1",
            data=[scatter(y=[3, 2, 1])],
            layout=attr(title=attr(text="frame title")),
        ),
    ]
    config = PlotConfig(
        staticPlot=true,
        locale="fr",
        toImageButtonOptions=Dict(:format => "svg", :width => 640),
        modeBarButtonsToAdd=[Dict(:name => "probe")],
    )
    return Plot(
        GenericTrace[
            scatter(y=[1, 2, 3], name="first"),
            scatter(y=[3, 2, 1], name="second"),
        ],
        Layout(
            title=attr(text="source"),
            annotations=[attr(text="annotation")],
        ),
        plot_frames;
        config=config,
    )
end

function _test_plot_metadata_clone(
    source::Plot,
    clone::Plot;
    content_equal::Bool=true,
)
    @test clone !== source
    @test clone isa PlotlySupply._RefreshablePlot
    @test clone.divid != source.divid
    @test clone.data !== source.data
    @test clone.layout !== source.layout
    if content_equal
        @test clone.data == source.data
        @test clone.data[1] !== source.data[1]
        @test clone.layout == source.layout
    end
    @test clone.frames == source.frames
    @test clone.frames !== source.frames
    @test clone.frames[1] !== source.frames[1]
    @test clone.config !== source.config
    @test PlotlyBase.JSON.lower(clone.config) ==
          PlotlyBase.JSON.lower(source.config)
    @test clone.config.toImageButtonOptions !==
          source.config.toImageButtonOptions
    @test clone.config.modeBarButtonsToAdd !==
          source.config.modeBarButtonsToAdd
    return nothing
end

@testset "copy/fork preserve animated plot metadata" begin
    source = _animated_config_plot()
    @test source isa PlotlySupply._RefreshablePlot
    @test which(copy, (typeof(source),)).module === PlotlySupply
    @test which(PlotlyBase.fork, (typeof(source),)).module === PlotlySupply

    for clone in (copy(source), PlotlyBase.fork(source))
        _test_plot_metadata_clone(source, clone)

        clone.data[1].fields[:y][1] = 99
        clone.layout.fields[:annotations][1].fields[:text] = "changed"
        clone.frames[1].fields[:data][1].fields[:y][1] = 77
        clone.config.toImageButtonOptions[:width] = 320
        clone.config.modeBarButtonsToAdd[1][:name] = "changed"

        @test source.data[1].fields[:y] == [1, 2, 3]
        @test source.layout.fields[:annotations][1].fields[:text] ==
              "annotation"
        @test source.frames[1].fields[:data][1].fields[:y] == [3, 2, 1]
        @test source.config.toImageButtonOptions[:width] == 640
        @test source.config.modeBarButtonsToAdd[1][:name] == "probe"
    end

    shared_payload = [1.0, 2.0, 3.0]
    shared_layout = Layout()
    shared_layout.fields[:meta] = Dict(:payload => shared_payload)
    shared_config = PlotConfig(
        toImageButtonOptions=Dict(:payload => shared_payload),
    )
    shared_source = Plot(
        GenericTrace[scatter(y=shared_payload)],
        shared_layout,
        [
            frame(
                name="shared-frame",
                data=[scatter(y=shared_payload)],
            ),
        ];
        config=shared_config,
    )
    for clone in (copy(shared_source), PlotlyBase.fork(shared_source))
        cloned_payload = clone.data[1].fields[:y]
        @test cloned_payload !== shared_payload
        @test clone.frames[1].fields[:data][1].fields[:y] ===
              cloned_payload
        @test clone.layout.fields[:meta][:payload] === cloned_payload
        @test clone.config.toImageButtonOptions[:payload] ===
              cloned_payload
    end

    empty_source = Plot()
    for clone in (copy(empty_source), PlotlyBase.fork(empty_source))
        @test isempty(clone.data)
        @test isempty(clone.frames)
        @test clone.divid != empty_source.divid
    end

    view_backed = Plot(
        view(GenericTrace[scatter(y=[1, 2, 3])], :),
        Layout(),
    )
    @test !(view_backed isa PlotlySupply._RefreshablePlot)
    @test which(copy, (typeof(view_backed),)).module === PlotlyBase
    @test which(PlotlyBase.fork, (typeof(view_backed),)).module ===
          PlotlyBase
end

@testset "public plot materializes abstract containers for safe dispatch" begin
    traces = _MutatorProbeTrace[
        GenericTrace(IdDict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2, 3],
        )),
        GenericTrace(IdDict{Symbol,Any}(
            :type => "scatter",
            :y => [3, 2, 1],
        )),
    ]
    frames = PlotlyFrame[
        frame(
            name="view-frame",
            data=[scatter(y=[3, 2, 1])],
        ),
    ]
    trace_view = view(traces, :)
    frame_view = view(frames, :)
    config = PlotConfig(staticPlot=true, locale="fr")

    builders = (
        (() -> plot(traces[1], Layout(); config=config, frames=frame_view), 1),
        (() -> plot(traces[1], Layout(), frame_view; config=config), 1),
        (() -> plot(trace_view, Layout(); config=config, frames=frame_view), 2),
        (() -> plot(trace_view, Layout(), frame_view; config=config), 2),
        (() -> plot(traces...; layout=Layout(), config=config, frames=frame_view), 2),
        (() -> plot(; layout=Layout(), config=config, frames=frame_view), 0),
        (() -> plot(Layout(), frame_view; config=config), 0),
    )

    for (build, expected_trace_count) in builders
        public_plot = build()
        @test public_plot isa PlotlySupply._RefreshablePlot
        @test public_plot.data isa Vector
        @test public_plot.frames isa Vector
        @test public_plot.frames !== frame_view
        @test only(public_plot.frames) === only(frames)
        @test length(public_plot.data) == expected_trace_count
        @test public_plot.config === config
        @test which(copy, (typeof(public_plot),)).module === PlotlySupply
        @test which(PlotlyBase.fork, (typeof(public_plot),)).module ===
              PlotlySupply
    end

    public_plot = plot(
        trace_view,
        Layout(title="source");
        config=config,
        frames=frame_view,
    )
    original_trace = public_plot.data[1]
    original_frame = public_plot.frames[1]
    traces[1] = GenericTrace(IdDict{Symbol,Any}(
        :type => "scatter",
        :y => [9, 9, 9],
    ))
    frames[1] = frame(name="replacement", data=[scatter(y=[9])])
    @test public_plot.data[1] === original_trace
    @test public_plot.frames[1] === original_frame

    for clone in (copy(public_plot), PlotlyBase.fork(public_plot))
        @test clone isa PlotlySupply._RefreshablePlot
        @test clone !== public_plot
        @test clone.divid != public_plot.divid
        @test clone.data !== public_plot.data
        @test clone.data[1] !== public_plot.data[1]
        @test clone.frames !== public_plot.frames
        @test clone.frames[1] !== public_plot.frames[1]
        @test clone.config !== public_plot.config
        @test clone.config.staticPlot === true
        @test clone.config.locale == "fr"
    end

    relayout_clone = relayout(public_plot; title="clone")
    @test length(relayout_clone.frames) == 1
    @test relayout_clone.config.staticPlot === true
    @test relayout_clone.config.locale == "fr"
    @test public_plot.layout.fields[:title] == "source"
    @test relayout_clone.layout.fields[:title] == "clone"

    refresh_plot = plot(
        view(traces, :),
        Layout();
        frames=frame_view,
    )
    sp = _attach_mutator_refresh_probe(refresh_plot)
    _MUTATOR_REFRESH_CALLS[] = 0
    try
        @test relayout!(refresh_plot; title="refreshed") === refresh_plot
        @test _MUTATOR_REFRESH_CALLS[] == 1
    finally
        close(sp)
    end

    owned_traces = copy(traces)
    owned_frames = copy(frames)
    owned_plot = plot(
        owned_traces,
        Layout();
        frames=owned_frames,
    )
    @test owned_plot.data === owned_traces
    @test owned_plot.frames === owned_frames
end

@testset "non-mutating verbs preserve frames and config" begin
    source = _animated_config_plot()
    operations = (
        p -> restyle(p, Dict(:name => "restyled")),
        p -> relayout(p; title="relayout"),
        p -> update(
            p,
            Dict(:name => "updated");
            layout=Layout(title="update"),
        ),
        p -> addtraces(p, scatter(y=[4, 5, 6])),
        p -> deletetraces(p, 2),
        p -> movetraces(p, 1),
        p -> redraw(p),
        p -> extendtraces(p, Dict(:y => [[4]]), [1], -1),
        p -> prependtraces(p, Dict(:y => [[0]]), [1], -1),
        p -> PlotlyBase.purge(p),
        p -> react(p, [scatter(y=[9, 8, 7])], Layout(title="react")),
    )

    for operation in operations
        clone = operation(source)
        _test_plot_metadata_clone(source, clone; content_equal=false)
    end

    @test length(source.data) == 2
    @test source.data[1].fields[:y] == [1, 2, 3]
    @test source.layout.fields[:title][:text] == "source"
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
