using Test
using PlotlySupply

const _MUTATOR_REFRESH_CALLS = Ref(0)
const _MutatorProbeTrace = GenericTrace{IdDict{Symbol,Any}}

struct _FailingSpliceVector <: AbstractVector{Int} end
Base.IndexStyle(::Type{_FailingSpliceVector}) = IndexLinear()
Base.size(::_FailingSpliceVector) = (1,)
Base.getindex(::_FailingSpliceVector, ::Int) =
    error("injected splice read failure")

mutable struct _RendererProbeState
    open::Any
    scripts::Vector{String}
    result::Any
    run_error::Union{Nothing,Exception}
    isopen_error::Union{Nothing,Exception}
end

_RendererProbeState() =
    _RendererProbeState(true, String[], "ok", nothing, nothing)

function _renderer_probe_syncplot()
    state = _RendererProbeState()
    backend = (
        isopen=function (window)
            state.isopen_error === nothing ||
                throw(state.isopen_error)
            return state.open
        end,
        close=window -> (state.open = false; nothing),
        run=function (window, script)
            push!(state.scripts, String(script))
            state.run_error === nothing || throw(state.run_error)
            return state.result
        end,
    )
    resources = PlotlySupply._SyncPlotResources(nothing, backend)
    plot = Plot(scatter(y=[1, 2, 3]), Layout(title="renderer-probe"))
    sp = SyncPlot(plot, nothing, :renderer_probe_window, "renderer-probe", resources)
    return sp, state
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
        run=(window, script) -> begin
            _MUTATOR_REFRESH_CALLS[] += 1
            return "ok"
        end,
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

function _stem_color_signature(traces)
    return map(traces) do trace
        marker = get(trace.fields, :marker, nothing)
        line = get(trace.fields, :line, nothing)
        (
            marker=marker === nothing ? nothing :
                   get(marker, :color, nothing),
            line=line === nothing ? nothing :
                 get(line, :color, nothing),
        )
    end
end

function _series_style_signature(trace)
    line = get(trace.fields, :line, attr())
    marker = get(trace.fields, :marker, attr())
    return (
        mode=get(trace.fields, :mode, nothing),
        dash=get(line, :dash, nothing),
        color=get(line, :color, nothing),
        legend=get(trace.fields, :name, nothing),
        marker_size=get(marker, :size, nothing),
        marker_symbol=get(marker, :symbol, nothing),
        linewidth=get(line, :width, nothing),
        showlegend=get(trace.fields, :showlegend, nothing),
    )
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

@testset "plot_stem! matches constructor colors" begin
    cases = (
        (
            x=[1, 2, 3],
            y=[2.0, 4.0, 3.0],
            color="crimson",
        ),
        (
            x=[1, 2, 3],
            y=[[2.0, 4.0, 3.0], [1.0, 3.0, 5.0]],
            color=["crimson", "navy"],
        ),
        (
            x=[[1, 2, 3], [4, 5, 6]],
            y=[[2.0, 4.0, 3.0], [1.0, 3.0, 5.0]],
            color=["crimson", "navy"],
        ),
    )

    for case in cases
        expected = plot_stem(
            case.x,
            case.y;
            color=case.color,
        )
        target = Plot(scatter(x=[0], y=[0]), Layout())
        initial_count = length(target.data)

        @test plot_stem!(
            target,
            case.x,
            case.y;
            color=case.color,
        ) === nothing
        appended = target.data[(initial_count + 1):end]
        @test _stem_color_signature(appended) ==
              _stem_color_signature(expected.data)
    end

    expected_first_color = plot_stem(
        [1, 2],
        [3.0, 4.0];
        color=["purple", "ignored"],
        legend=["first", "ignored"],
        showlegend=[false, true],
    )
    target = Plot(scatter(x=[0], y=[0]), Layout())
    initial_count = length(target.data)
    plot_stem!(
        target,
        [1, 2],
        [3.0, 4.0];
        color=["purple", "ignored"],
        legend=["first", "ignored"],
        showlegend=[false, true],
    )
    appended = target.data[(initial_count + 1):end]
    @test _stem_color_signature(appended) ==
          _stem_color_signature(expected_first_color.data)
    @test appended[1].fields[:name] ==
          expected_first_color.data[1].fields[:name]
    @test appended[1].fields[:name] == "first"
    @test appended[1].fields[:showlegend] ===
          expected_first_color.data[1].fields[:showlegend]
    @test appended[1].fields[:showlegend] === false
end

@testset "per-series styling ignores surplus vector entries" begin
    coordinates = UnitRange{Int}[1:3, 4:6]
    style = (
        mode=["markers", "lines", "lines+markers"],
        dash=["dot", "dash", "dashdot"],
        color=["crimson", "navy", "green"],
        legend=["first", "second", "surplus"],
        marker_size=[5, 7, 9],
        marker_symbol=["circle", "diamond", "square"],
        linewidth=[1, 2, 3],
        showlegend=[true, false, true],
    )

    constructor_cases = (
        (
            make=() -> plot_scatter(
                coordinates,
                coordinates;
                style...,
            ),
            append=(figure) -> plot_scatter!(
                figure,
                coordinates,
                coordinates;
                style...,
            ),
        ),
        (
            make=() -> plot_scatterpolar(
                coordinates,
                coordinates;
                style...,
            ),
            append=(figure) -> plot_scatterpolar!(
                figure,
                coordinates,
                coordinates;
                style...,
            ),
        ),
    )

    for case in constructor_cases
        expected = case.make()
        @test length(expected.data) == 2
        @test getfield.(
            _series_style_signature.(expected.data),
            :legend,
        ) == ["first", "second"]

        target = Plot(scatter(x=[0], y=[0]), Layout())
        initial_count = length(target.data)
        @test case.append(target) === nothing
        appended = target.data[(initial_count + 1):end]
        @test _series_style_signature.(appended) ==
              _series_style_signature.(expected.data)
    end

    expected_stem = plot_stem(
        coordinates,
        coordinates;
        color=["crimson", "navy", "surplus"],
        legend=["first", "second", "surplus"],
        showlegend=[true, false, true],
    )
    target = Plot(scatter(x=[0], y=[0]), Layout())
    initial_count = length(target.data)
    @test plot_stem!(
        target,
        coordinates,
        coordinates;
        color=["crimson", "navy", "surplus"],
        legend=["first", "second", "surplus"],
        showlegend=[true, false, true],
    ) === nothing
    appended_stem = target.data[(initial_count + 1):end]
    @test _stem_color_signature(appended_stem) ==
          _stem_color_signature(expected_stem.data)
    @test getfield.(
        _series_style_signature.(appended_stem[1:2]),
        :legend,
    ) == ["first", "second"]
end

@testset "pie-like traces receive default legend styling" begin
    constructors = (
        () -> plot_pie(
            [3, 2, 1];
            labels=["alpha", "beta", "gamma"],
        ),
        () -> plot_pie([3, 2, 1]),
        () -> plot_funnelarea(
            [3, 2, 1];
            labels=["alpha", "beta", "gamma"],
        ),
        () -> plot_funnelarea([3, 2, 1]),
    )

    for constructor in constructors
        figure = constructor()
        trace = only(figure.data)
        @test PlotlySupply._trace_will_showlegend(trace)
        @test figure.layout.fields[:showlegend] === true
        legend = figure.layout.fields[:legend]
        for key in (
            :x,
            :y,
            :xanchor,
            :yanchor,
            :bgcolor,
            :bordercolor,
            :borderwidth,
        )
            @test haskey(legend, key)
        end
    end

    appenders = (
        figure -> plot_pie!(
            figure,
            [3, 2, 1];
            labels=["alpha", "beta", "gamma"],
        ),
        figure -> plot_funnelarea!(
            figure,
            [3, 2, 1];
            labels=["alpha", "beta", "gamma"],
        ),
    )
    for append! in appenders
        figure = Plot(scatter(y=[1, 2, 3]), Layout())
        @test append!(figure) === nothing
        @test figure.layout.fields[:showlegend] === true
        @test haskey(figure.layout.fields, :legend)
    end

    symbolic = GenericTrace(Dict{Symbol,Any}(
        :type => :pie,
        :values => [3, 2, 1],
    ))
    @test PlotlySupply._trace_will_showlegend(symbolic)

    subplot_appenders = (
        figure -> plot_pie!(
            figure,
            [3, 2, 1];
            labels=["alpha", "beta", "gamma"],
            row=1,
            col=1,
        ),
        figure -> plot_funnelarea!(
            figure,
            [3, 2, 1];
            labels=["alpha", "beta", "gamma"],
            row=1,
            col=1,
        ),
    )
    for append! in subplot_appenders
        figure = PlotlySupply.subplots(
            1,
            1;
            sync=false,
            per_subplot_legends=true,
            specs=fill(
                PlotlySupply.Spec(kind="domain"),
                1,
                1,
            ),
        )
        @test append!(figure) === figure
        trace = only(figure.data)
        @test trace.fields[:showlegend] === true
        @test trace.fields[:legend] == "legend"
        @test figure.layout.fields[:showlegend] === true
        @test haskey(figure.layout.fields, :legend)
    end

    hidden = Plot(
        pie(
            values=[3, 2, 1],
            labels=["alpha", "beta", "gamma"],
            showlegend=false,
        ),
        Layout(),
    )
    PlotlySupply._apply_default_legend!(hidden)
    @test !PlotlySupply._trace_will_showlegend(only(hidden.data))
    @test !haskey(hidden.layout.fields, :legend)
    @test !haskey(hidden.layout.fields, :showlegend)
end

@testset "mapbox updaters reject invalid view values atomically" begin
    invalid_values = (true, NaN, Inf, -Inf, "not-a-number")
    for target_kind in (:plot, :syncplot)
        for option in (:zoom, :center_lon, :center_lat)
            for invalid in invalid_values
                for via_with in (false, true)
                    p = _mutator_probe_plot()
                    sp = _attach_mutator_refresh_probe(p)
                    target = target_kind === :plot ? p : sp
                    layout_ref = p.layout
                    layout_before = deepcopy(p.layout)
                    data_ref = p.data
                    _MUTATOR_REFRESH_CALLS[] = 0

                    try
                        if via_with
                            with = if option === :zoom
                                attr(zoom=invalid)
                            elseif option === :center_lon
                                attr(center=attr(lon=invalid))
                            else
                                attr(center=attr(lat=invalid))
                            end
                            @test_throws ArgumentError update_mapboxes!(
                                target,
                                with,
                            )
                        else
                            options = NamedTuple{(option,)}((invalid,))
                            @test_throws ArgumentError update_mapboxes!(
                                target;
                                options...,
                            )
                        end
                        @test p.layout === layout_ref
                        @test p.layout == layout_before
                        @test p.data === data_ref
                        @test _MUTATOR_REFRESH_CALLS[] == 0
                    finally
                        close(sp)
                    end
                end
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
            # 2.0 (#165): redraw! rebuilds the window from the Julia model.
            @test occursin("await Plotly.newPlot(div,", only(scripts))
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

@testset "renderer promises and statuses are observable" begin
    sp, state = _renderer_probe_syncplot()
    p = sp.plot

    try
        refresh_script = PlotlySupply._plotlyjs_refresh_script(
            sp,
            p.data,
            p.layout,
        )
        @test PlotlySupply._run_plotlyjs_script!(
            sp,
            refresh_script,
            "react",
        ) === nothing
        @test length(state.scripts) == 1
        @test only(state.scripts) == refresh_script
        @test occursin("(async function()", refresh_script)
        @test occursin(
            "await Plotly.react(div,",
            refresh_script,
        )

        state.result = SubString("ok", 1, 2)
        @test PlotlySupply._run_plotlyjs_script!(
            sp,
            refresh_script,
            "react",
        ) === nothing

        for result in (
            "plotly-not-loaded",
            "plot-div-not-found",
            "unexpected-renderer-result",
            nothing,
            missing,
            false,
            1,
        )
            state.result = result
            call_count = length(state.scripts)
            caught = try
                PlotlySupply._run_plotlyjs_script!(
                    sp,
                    refresh_script,
                    "react",
                )
                nothing
            catch err
                err
            end
            @test caught isa ErrorException
            @test occursin(
                "did not complete successfully",
                sprint(showerror, caught),
            )
            @test occursin(
                repr(result),
                sprint(showerror, caught),
            )
            @test length(state.scripts) == call_count + 1
        end

        injected_error =
            ErrorException("injected renderer transport failure")
        state.result = "ok"
        state.run_error = injected_error
        call_count = length(state.scripts)
        caught = try
            PlotlySupply._run_plotlyjs_script!(
                sp,
                refresh_script,
                "react",
            )
            nothing
        catch err
            err
        end
        @test caught === injected_error
        @test length(state.scripts) == call_count + 1
        state.run_error = nothing

        empty!(state.scripts)
        state.result = "ok"
        rebuild_script = PlotlySupply._plotlyjs_refresh_script(
            sp,
            p.data,
            p.layout;
            rebuild=true,
            autoplay=true,
        )
        @test PlotlySupply._run_plotlyjs_script!(
            sp,
            rebuild_script,
            "newPlot",
        ) === nothing
        @test only(state.scripts) == rebuild_script
        @test occursin("await Plotly.newPlot", rebuild_script)
        @test occursin("Plotly.animate(div, null)", rebuild_script)
        @test !occursin("await Plotly.animate", rebuild_script)

        for command in (:redraw, :purge)
            empty!(state.scripts)
            state.result = "ok"
            @test PlotlySupply._plotlyjs_command!(sp, command) ===
                  nothing
            @test length(state.scripts) == 1
            @test occursin(
                command === :redraw ?
                "await Plotly.redraw(div);" :
                "Plotly.purge(div);",
                only(state.scripts),
            )

            state.result = "plot-div-not-found"
            caught = try
                PlotlySupply._plotlyjs_command!(sp, command)
                nothing
            catch err
                err
            end
            @test caught isa ErrorException
            @test occursin(
                string(command),
                sprint(showerror, caught),
            )
        end

        call_count = length(state.scripts)
        @test_throws ArgumentError PlotlySupply._plotlyjs_command!(
            sp,
            :unsupported,
        )
        @test length(state.scripts) == call_count

        empty!(state.scripts)
        state.open = false
        state.result = "plot-div-not-found"
        @test_throws InvalidStateException PlotlySupply._require_open_syncplot_window(
            sp,
        )
        @test_throws InvalidStateException PlotlySupply._plotlyjs_command!(
            sp,
            :redraw,
        )
        @test isempty(state.scripts)

        state.open = "not-a-boolean"
        caught = try
            PlotlySupply._require_open_syncplot_window(sp)
            nothing
        catch err
            err
        end
        @test caught isa ErrorException
        @test occursin(
            "non-Boolean isopen result",
            sprint(showerror, caught),
        )
        @test isempty(state.scripts)

        state.open = true
        isopen_error =
            ErrorException("injected renderer isopen failure")
        state.isopen_error = isopen_error
        caught = try
            PlotlySupply._plotlyjs_command!(sp, :redraw)
            nothing
        catch err
            err
        end
        @test caught === isopen_error
        @test isempty(state.scripts)
        state.isopen_error = nothing
    finally
        state.run_error = nothing
        state.isopen_error = nothing
        close(sp)
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

# Julia's method-overwrite warning names the module that loses the method
# ("Method definition f(...) in module PlotlySupply at a overwritten at b") or,
# for a method of another module, the module that redefines it ("... overwritten
# in module PlotlySupply at b").
const _OVERWRITE_BY_PLOTLYSUPPLY =
    r"Method definition [^\n]* in module PlotlySupply [^\n]*overwritten|overwritten in module PlotlySupply"

# Runs `code` in a fresh Julia process with method-overwrite warnings enabled and
# the flags of this test process (`Base.julia_cmd()`: same compiled-module and
# coverage settings, hence the same package cache); returns (process, output).
function _run_with_overwrite_warnings(code::AbstractString; project::AbstractString)
    output = IOBuffer()
    command = `$(Base.julia_cmd()) --startup-file=no --warn-overwrite=yes --project=$project -e $code`
    process = run(pipeline(ignorestatus(command), stdout=output, stderr=output))
    return process, String(take!(output))
end

@testset "mutator parity loads without method overwrite" begin
    project = dirname(something(
        Base.active_project(),
        normpath(joinpath(@__DIR__, "..", "Project.toml")),
    ))
    # The pattern matches both forms of the warning Julia prints.
    probe = """
        module _OverwriteOwner; g(x::Int) = 1; end
        module PlotlySupply
            import .._OverwriteOwner
            f(x::Int) = 1
            f(x::Int) = 2
            _OverwriteOwner.g(x::Int) = 2
        end
        """
    process, diagnostics = _run_with_overwrite_warnings(probe; project)
    @test success(process)
    @test length(collect(eachmatch(_OVERWRITE_BY_PLOTLYSUPPLY, diagnostics))) == 2

    # Since Julia 1.10 a method overwrite while precompiling is an error: the
    # package then loads from source without a cache, printing the warning, and
    # `Base.isprecompiled` is false. Overwrites at load time (`__init__`) print the
    # warning too. A cached load is therefore the complete check; the former
    # `--compiled-modules=no` reload of every dependency added ~2 minutes.
    process, diagnostics = _run_with_overwrite_warnings(
        "using PlotlySupply; print(\"cached=\", Base.isprecompiled(Base.PkgId(PlotlySupply)))";
        project,
    )
    @test success(process)
    @test !occursin(_OVERWRITE_BY_PLOTLYSUPPLY, diagnostics)
    if Base.JLOptions().use_compiled_modules == 1
        @test occursin("cached=true", diagnostics)
    end
end

# ---------------------------------------------------------------------------
# C44 / G36: every exported `plot_*` constructor and its `plot_*!` mutator take
# the same keywords, the mutator without `show`. The pairs and their keyword
# sets are read from the method signatures, so a new function or keyword cannot
# be left out of the comparison.
# ---------------------------------------------------------------------------

# Keywords a Plot/SyncPlot mutator may declare beyond its constructor's: the
# SubplotFigure cell selectors and `show`, which it accepts only to reject them
# with an ArgumentError naming the function.
const _PARITY_GUARD_KEYWORDS = (:row, :col, :secondary_y, :inset, :show)

_parity_is_slurp(keyword) = endswith(string(keyword), "...")
_parity_keywords(ms) = Set{Symbol}(
    keyword for m in ms for keyword in Base.kwarg_decl(m) if !_parity_is_slurp(keyword)
)
function _parity_first_argument(m::Method)
    parameters = Base.unwrap_unionall(m.sig).parameters
    return length(parameters) >= 2 ? parameters[2] : Union{}
end
_parity_own_methods(f) = [m for m in methods(f) if m.module === PlotlySupply]

# Exported (constructor, mutator) name pairs: `plot_x` with a `plot_x!`.
function _plot_function_pairs()
    found = Tuple{Symbol, Symbol}[]
    for name in names(PlotlySupply)
        text = string(name)
        (startswith(text, "plot_") && !endswith(text, "!")) || continue
        bang = Symbol(text, "!")
        isdefined(PlotlySupply, bang) && push!(found, (name, bang))
    end
    return sort!(found)
end

@testset "every plot_* constructor and mutator take the same keywords (C44, G36)" begin
    pairs = _plot_function_pairs()
    # Discovery reaches every family (api.jl, sci/lines.jl, sci/fields.jl,
    # sci/mesh2d.jl, sci/scene3d.jl and the map sources).
    for pair in ((:plot_scatter, :plot_scatter!), (:plot_bar, :plot_bar!),
            (:plot_band, :plot_band!), (:plot_heatmap, :plot_heatmap!),
            (:plot_streamlines, :plot_streamlines!), (:plot_polygons, :plot_polygons!),
            (:plot_surface, :plot_surface!), (:plot_polygons3d, :plot_polygons3d!),
            (:plot_scattermap, :plot_scattermap!), (:plot_pie, :plot_pie!))
        @test pair in pairs
    end
    for (ctor_name, mut_name) in pairs
        ctor = getfield(PlotlySupply, ctor_name)
        mut = getfield(PlotlySupply, mut_name)
        ctor_keywords = _parity_keywords(_parity_own_methods(ctor))
        # The Plot/SyncPlot implementation: methods whose first argument takes a Plot.
        figure_methods = [m for m in _parity_own_methods(mut) if Plot <: _parity_first_argument(m)]
        cell_methods = [m for m in _parity_own_methods(mut) if _parity_first_argument(m) === SubplotFigure]
        mut_keywords = _parity_keywords(figure_methods)
        @testset "$mut_name" begin
            @test :show in ctor_keywords
            @test !isempty(figure_methods)
            @test setdiff(ctor_keywords, (:show,)) == setdiff(mut_keywords, _PARITY_GUARD_KEYWORDS)
            # The SubplotFigure method takes the cell selectors and forwards the
            # constructor keywords it does not declare itself to the Plot
            # implementation; it declares none the constructor lacks.
            @test !isempty(cell_methods)
            @test all(m -> any(_parity_is_slurp, Base.kwarg_decl(m)), cell_methods)
            @test issubset(_parity_keywords(cell_methods), union(ctor_keywords, _PARITY_GUARD_KEYWORDS))
        end
    end
end

# One valid call per pair, and the subplot kind its traces need. A new pair
# without an entry here fails the test below.
function _parity_sample_calls()
    U = [1.0 2.0 3.0; 4.0 5.0 6.0]
    g = [0.0, 1.0]
    X3 = [x for x in g, y in g, z in g]
    Y3 = [y for x in g, y in g, z in g]
    Z3 = [z for x in g, y in g, z in g]
    V3 = X3 .+ Y3 .+ Z3
    geojson = Dict(
        "type" => "FeatureCollection",
        "features" => [Dict(
            "type" => "Feature", "id" => "A", "properties" => Dict(),
            "geometry" => Dict("type" => "Polygon", "coordinates" => [[[0, 0], [1, 0], [1, 1], [0, 0]]]),
        )],
    )
    triangle = ([0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1 2 3])
    return Dict{Symbol, Tuple{Tuple, NamedTuple, String}}(
        :plot_area => (([1, 2, 3], [1.0, 2.0, 3.0]), (;), "xy"),
        :plot_band => (([1, 2, 3], [0.0, 0.0, 0.0], [1.0, 2.0, 3.0]), (;), "xy"),
        :plot_bar => (([1, 2, 3], [1.0, 2.0, 3.0]), (;), "xy"),
        :plot_box => (([1.0, 2.0, 3.0],), (;), "xy"),
        :plot_candlestick => (([1, 2], [1.0, 2.0], [2.0, 3.0], [0.5, 1.5], [1.5, 2.5]), (;), "xy"),
        :plot_choropleth => ((["FRA", "DEU"], [1.0, 2.0]), (;), "geo"),
        :plot_choroplethmap => ((geojson, ["A"], [1.0]), (;), "map"),
        :plot_choroplethmapbox => ((geojson, ["A"], [1.0]), (;), "mapbox"),
        :plot_complex => (([1.0 + 1im, 2.0 - 1im],), (;), "xy"),
        :plot_contour => ((U,), (;), "xy"),
        :plot_densitymap => (([0.0, 1.0], [1.0, 2.0]), (;), "map"),
        :plot_densitymapbox => (([0.0, 1.0], [1.0, 2.0], [1.0, 2.0]), (;), "mapbox"),
        :plot_ecdf => (([1.0, 2.0, 3.0],), (;), "xy"),
        :plot_funnel => (([3.0, 2.0, 1.0], ["a", "b", "c"]), (;), "xy"),
        :plot_funnelarea => (([3.0, 2.0, 1.0],), (;), "domain"),
        :plot_heatmap => ((U,), (;), "xy"),
        :plot_histogram => (([1.0, 2.0, 2.0, 3.0],), (;), "xy"),
        :plot_histogram2d => (([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]), (;), "xy"),
        :plot_hlines => (([1.0, 2.0], 0.0, 1.0), (;), "xy"),
        :plot_image => ((fill(UInt8(128), 2, 3, 3),), (;), "xy"),
        :plot_indicator => ((42,), (;), "domain"),
        :plot_isosurface => ((X3, Y3, Z3, V3), (;), "scene"),
        :plot_kde => (([1.0, 2.0, 2.5, 3.0],), (;), "xy"),
        :plot_matrix => (([1.0 2.0; 3.0 4.0],), (;), "xy"),
        :plot_mesh3d => ((g[[1, 2, 1, 1]], g[[1, 1, 2, 1]], g[[1, 1, 1, 2]]),
            (; i = [0, 0, 0, 1], j = [1, 2, 3, 2], k = [2, 3, 1, 3]), "scene"),
        :plot_ohlc => (([1, 2], [1.0, 2.0], [2.0, 3.0], [0.5, 1.5], [1.5, 2.5]), (;), "xy"),
        :plot_parcoords => ((["a" => [1.0, 2.0], "b" => [3.0, 4.0]],), (;), "domain"),
        :plot_pcolormesh => (([0.0, 1.0, 2.0], [0.0, 1.0], [1.0; 2.0;;]), (;), "xy"),
        :plot_pie => (([1.0, 2.0],), (;), "domain"),
        :plot_polygons => (([[0.0, 1.0, 1.0]], [[0.0, 0.0, 1.0]]), (;), "xy"),
        :plot_polygons3d => (([[0.0 0.0 0.0; 1.0 0.0 0.0; 0.0 1.0 0.0]],), (;), "scene"),
        :plot_quiver => (([0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [0.0, 1.0]), (;), "xy"),
        :plot_quiver3d => (([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]), (;), "scene"),
        :plot_sankey => (([0, 1], [1, 2], [1.0, 2.0]), (;), "domain"),
        :plot_scatter => (([1, 2, 3], [1.0, 2.0, 3.0]), (;), "xy"),
        :plot_scatter3d => (([1.0, 2.0], [1.0, 2.0], [1.0, 2.0]), (;), "scene"),
        :plot_scattergeo => (([0.0, 1.0], [1.0, 2.0]), (;), "geo"),
        :plot_scattermap => (([0.0, 1.0], [1.0, 2.0]), (;), "map"),
        :plot_scattermapbox => (([0.0, 1.0], [1.0, 2.0]), (;), "mapbox"),
        :plot_scatterpolar => (([0.0, 90.0], [1.0, 2.0]), (;), "polar"),
        :plot_segments => (([0.0], [0.0], [1.0], [1.0]), (;), "xy"),
        :plot_segments3d => (([0.0], [0.0], [0.0], [1.0], [1.0], [1.0]), (;), "scene"),
        :plot_stem => (([1.0, 2.0, 3.0],), (;), "xy"),
        :plot_streamlines => (([0.0, 1.0, 2.0], [0.0, 1.0, 2.0], ones(3, 3), ones(3, 3)), (;), "xy"),
        :plot_streamtube => ((vec(X3), vec(Y3), vec(Z3), ones(8), zeros(8), zeros(8)), (;), "scene"),
        :plot_sunburst => ((["root", "a"], ["", "root"]), (;), "domain"),
        :plot_surface => ((U,), (;), "scene"),
        :plot_ternary => (([0.2, 0.3], [0.3, 0.3], [0.5, 0.4]), (;), "ternary"),
        :plot_treemap => ((["root", "a"], ["", "root"]), (;), "domain"),
        :plot_tricontour => ((triangle..., [1.0, 2.0, 3.0]), (;), "xy"),
        :plot_tripcolor => ((triangle..., [1.0, 2.0, 3.0]), (;), "xy"),
        :plot_triplot => (triangle, (;), "xy"),
        :plot_violin => (([1.0, 2.0, 3.0],), (;), "xy"),
        :plot_vlines => (([1.0, 2.0], 0.0, 1.0), (;), "xy"),
        :plot_volume => ((X3, Y3, Z3, V3), (;), "scene"),
        :plot_waterfall => ((["a", "b"], [1.0, -0.5]), (;), "xy"),
        :plot_wireframe => (([0.0, 1.0], [0.0, 1.0], [1.0 2.0; 3.0 4.0]), (;), "scene"),
    )
end

function _parity_thrown(f)
    try
        f()
    catch err
        return err
    end
    return nothing
end

# A rejection of `keyword` by `who`: an ArgumentError whose message starts with
# the function name and names the keyword.
_parity_rejects(err, who, keyword) = err isa ArgumentError &&
    startswith(err.msg, "$who: ") && occursin(string(keyword), err.msg)

# Julia's own rejection of an undeclared keyword.
_parity_method_rejects(err, keyword) =
    err isa MethodError && occursin(string(keyword), sprint(showerror, err))

# Mutators that report an unknown keyword as a MethodError on an internal staging
# type (`plot_pie!(::PlotlySupply._HighLevelStagedPlotMutation, ...)`) instead of
# an ArgumentError naming the function (cross-requested in wave 4, G36). Empty
# since wave 5 (Z88): the twelve extended-chart mutators reject it themselves.
const _PARITY_UNKNOWN_KEYWORD_METHODERROR = ()

# Source file of a mutator's SubplotFigure method(s).
_parity_cell_source(mut) = minimum(
    basename(string(m.file)) for m in _parity_own_methods(mut) if _parity_first_argument(m) === SubplotFigure
)

@testset "every plot_* pair rejects unknown keywords and `show` atomically (G36)" begin
    samples = _parity_sample_calls()
    json = PlotlyBase.JSON.json
    unknown = :g36_not_a_keyword
    bad = NamedTuple{(unknown,)}((1,))
    # Every keyword set compiles its own specialization of a slurping method, and
    # the SubplotFigure methods forward their keywords to the Plot method, whose
    # rejection is checked for every pair, so the unknown keyword goes through a
    # cell once per (source file, subplot kind, error form) family; `show` goes
    # through every one.
    cell_families = Set{Tuple{String, String, Bool}}()
    for (ctor_name, mut_name) in _plot_function_pairs()
        @testset "$mut_name" begin
            @test haskey(samples, ctor_name)
            haskey(samples, ctor_name) || continue
            args, keywords, kind = samples[ctor_name]
            ctor = getfield(PlotlySupply, ctor_name)
            mut = getfield(PlotlySupply, mut_name)
            mut_rejects(err) = if mut_name in _PARITY_UNKNOWN_KEYWORD_METHODERROR
                @test _parity_method_rejects(err, unknown)
                @test_broken _parity_rejects(err, mut_name, unknown)
            else
                @test _parity_rejects(err, mut_name, unknown)
            end

            # Constructors: Julia's MethodError for a declared keyword list, or the
            # function's own ArgumentError where trace attributes pass through.
            err = _parity_thrown(() -> ctor(args...; keywords..., bad...))
            @test _parity_method_rejects(err, unknown) || _parity_rejects(err, ctor_name, unknown)

            # Plot: rejected before anything is written.
            fig = ctor(args...; keywords...)
            before = json(fig)
            mut_rejects(_parity_thrown(() -> mut(fig, args...; keywords..., bad...)))
            @test _parity_rejects(_parity_thrown(() -> mut(fig, args...; keywords..., show = true)), mut_name, :show)
            @test json(fig) == before

            # SubplotFigure cell of the kind the traces need.
            sf = kind == "xy" ? subplots(1, 2; sync = false) :
                subplots(1, 2; sync = false, specs = [Spec(kind = kind) Spec(kind = kind)])
            before = json(sf.plot)
            family = (_parity_cell_source(mut), kind, mut_name in _PARITY_UNKNOWN_KEYWORD_METHODERROR)
            if !(family in cell_families)
                push!(cell_families, family)
                mut_rejects(_parity_thrown(() -> mut(sf, args...; keywords..., row = 1, col = 2, bad...)))
            end
            @test _parity_rejects(
                _parity_thrown(() -> mut(sf, args...; keywords..., row = 1, col = 2, show = true)),
                mut_name, :show)
            @test json(sf.plot) == before
            # the same call without the bad keyword is accepted
            @test mut(sf, args...; keywords..., row = 1, col = 2) === sf
            @test json(sf.plot) != before
        end
    end
end

# G36 / Y38: a subplot title is a label like any other, so text mixed with
# `$...$` math is wrapped the same way as `title` and `xlabel`.
@testset "subplot_titles render mixed mathtext like title and axis labels (G36, Y38)" begin
    mixed = "Field \$E_z\$ (V/m)"
    expected = "\$\\text{Field }E_z\\text{ (V/m)}\$"
    fig = plot_scatter(1:3, [1.0, 2.0, 3.0]; title = mixed, xlabel = mixed)
    @test fig.layout.fields[:title][:text] == expected
    @test fig.layout.xaxis[:title][:text] == expected
    sf = subplots(1, 3; sync = false, subplot_titles = [mixed, "plain", "\$E_z\$"])
    @test [annotation[:text] for annotation in sf.plot.layout.fields[:annotations]] ==
        [expected, "plain", "\$E_z\$"]
end
