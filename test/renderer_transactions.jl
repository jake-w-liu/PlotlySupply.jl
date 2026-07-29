using Test
using PlotlySupply

mutable struct _TransactionCustomTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
end

PlotlyBase.JSON.lower(trace::_TransactionCustomTrace) = trace.fields
Base.getindex(trace::_TransactionCustomTrace, key) =
    trace.fields[Symbol(key)]
Base.setindex!(trace::_TransactionCustomTrace, value, key) =
    (trace.fields[Symbol(key)] = value)
function PlotlyBase.restyle!(
    trace::_TransactionCustomTrace,
    ::Int,
    update::AbstractDict=Dict();
    kwargs...,
)
    for (key, value) in update
        trace[key] = value
    end
    for (key, value) in pairs(kwargs)
        trace[key] = value
    end
    return trace
end

mutable struct _TransactionTaggedDict <: AbstractDict{Symbol,Any}
    values::Dict{Symbol,Any}
    tag::Any
end

Base.length(values::_TransactionTaggedDict) = length(values.values)
Base.getindex(values::_TransactionTaggedDict, key::Symbol) =
    values.values[key]
Base.setindex!(
    values::_TransactionTaggedDict,
    value,
    key::Symbol,
) = (values.values[key] = value)
Base.iterate(values::_TransactionTaggedDict, state...) =
    iterate(values.values, state...)

mutable struct _TransactionTaggedVector <: AbstractVector{Any}
    values::Vector{Any}
    tag::Any
end

Base.IndexStyle(::Type{_TransactionTaggedVector}) = IndexLinear()
Base.size(values::_TransactionTaggedVector) = size(values.values)
Base.getindex(values::_TransactionTaggedVector, ind::Int) =
    values.values[ind]
Base.setindex!(
    values::_TransactionTaggedVector,
    value,
    ind::Int,
) = (values.values[ind] = value)

mutable struct _TransactionEmptyToken end

mutable struct _TransactionSharedNode
    value::Int
end

mutable struct _TransactionLyingNumber <: Number
    state::Int
end

struct _TransactionLyingBits
    state::Int
end

struct _TransactionAliasWrapper
    child::Any
end

mutable struct _TransactionMutableAliasWrapper
    child::Any
end

struct _TransactionImmutableCycleWrapper
    changed::Any
    public_child::Any
    child::Any
end

mutable struct _TransactionConstCycleWrapper
    const public_child::Any
    changed::Any
    link::Any
end

mutable struct _TransactionClosureCycleWrapper
    const callback::Function
    const public_child::Any
    shared::Any
end

mutable struct _TransactionSelfCopyDict <: AbstractDict{Symbol,Any}
    values::Dict{Symbol,Any}
end

Base.length(values::_TransactionSelfCopyDict) =
    length(values.values)
Base.getindex(values::_TransactionSelfCopyDict, key::Symbol) =
    values.values[key]
Base.setindex!(
    values::_TransactionSelfCopyDict,
    value,
    key::Symbol,
) = (values.values[key] = value)
Base.iterate(values::_TransactionSelfCopyDict, state...) =
    iterate(values.values, state...)
Base.haskey(values::_TransactionSelfCopyDict, key) =
    haskey(values.values, key)
Base.get(values::_TransactionSelfCopyDict, key, default) =
    get(values.values, key, default)
Base.copy(values::_TransactionSelfCopyDict) = values

mutable struct _TransactionSideEffectDict <: AbstractDict{Symbol,Any}
    values::Dict{Symbol,Any}
    tag::Symbol
end

Base.length(values::_TransactionSideEffectDict) =
    length(values.values)
Base.getindex(values::_TransactionSideEffectDict, key::Symbol) =
    values.values[key]
function Base.setindex!(
    values::_TransactionSideEffectDict,
    value,
    ::Symbol,
)
    values.tag = :changed
    return value
end
Base.iterate(values::_TransactionSideEffectDict, state...) =
    iterate(values.values, state...)
Base.haskey(values::_TransactionSideEffectDict, key) =
    haskey(values.values, key)
Base.get(values::_TransactionSideEffectDict, key, default) =
    get(values.values, key, default)

Base.isequal(
    ::_TransactionLyingNumber,
    ::_TransactionLyingNumber,
) = true
Base.isequal(
    ::_TransactionLyingBits,
    ::_TransactionLyingBits,
) = true

mutable struct _TransactionScalarMutatingTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
end

mutable struct _TransactionLockedTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
    lock::ReentrantLock
end

mutable struct _TransactionDetachingModelTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
    target::Symbol
end

mutable struct _TransactionNodeMutatingTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
    path::Symbol
end

mutable struct _TransactionModelMutatingFields <:
               AbstractDict{Symbol,Any}
    values::Dict{Symbol,Any}
    target::Symbol
    owner::Any
end

mutable struct _TransactionCustomLayout <: AbstractLayout
    fields::Dict{Symbol,Any}
end

mutable struct _TransactionTaggedAttribute <:
               PlotlyBase.AbstractPlotlyAttribute
    fields::Dict{Symbol,Any}
    tag::Any
end

mutable struct _TransactionSelfCopyAliasDict <:
               AbstractDict{Symbol,Any}
    values::Dict{Symbol,Any}
    writes::Int
end

mutable struct _TransactionZeroBasedVector <: AbstractVector{Any}
    values::Vector{Any}
end

mutable struct _TransactionDataRootMutatingTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
    action::Symbol
end

mutable struct _TransactionRootValueMutatingTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
    target::Symbol
end

mutable struct _TransactionFrameVector <: AbstractVector{PlotlyFrame}
    values::Vector{PlotlyFrame}
end

mutable struct _TransactionFailingInputTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
end

mutable struct _TransactionIgnoringTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
end

struct _TransactionOpaqueValue
    value::BigInt
end

mutable struct _TransactionCountingVector <: AbstractVector{Any}
    values::Vector{Any}
    reads::Base.RefValue{Int}
end

PlotlyBase.JSON.lower(trace::_TransactionLockedTrace) =
    trace.fields
Base.getindex(trace::_TransactionLockedTrace, key) =
    trace.fields[Symbol(key)]
Base.setindex!(trace::_TransactionLockedTrace, value, key) =
    (trace.fields[Symbol(key)] = value)

PlotlyBase.JSON.lower(trace::_TransactionDetachingModelTrace) =
    trace.fields
Base.getindex(trace::_TransactionDetachingModelTrace, key) =
    trace.fields[Symbol(key)]
function Base.setindex!(
    trace::_TransactionDetachingModelTrace,
    value,
    key,
)
    symbol = Symbol(key)
    if symbol === :y && haskey(trace.fields, :shared)
        root = trace.fields[:shared]
        if trace.target === :config
            root.scrollZoom = false
        elseif trace.target === :frames
            push!(root, frame(name="detached-side-effect"))
        elseif trace.target === :shared_roots
            root.modeBarButtonsToAdd[1][:value] = 2
        elseif trace.target === :config_structure
            push!(root.modeBarButtonsToAdd, "added")
        elseif trace.target === :frames_structure
            push!(root, frame(name="added"))
        elseif trace.target === :frames_delete
            deleteat!(root, 1)
        end
        delete!(trace.fields, :shared)
    end
    trace.fields[symbol] = value
    return value
end

PlotlyBase.JSON.lower(trace::_TransactionNodeMutatingTrace) =
    trace.fields
Base.getindex(trace::_TransactionNodeMutatingTrace, key) =
    trace.fields[Symbol(key)]
Base.setindex!(
    trace::_TransactionNodeMutatingTrace,
    value,
    key,
) = (trace.fields[Symbol(key)] = value)
function PlotlyBase.restyle!(
    trace::_TransactionNodeMutatingTrace,
    ::Int,
    ::AbstractDict=Dict();
    node_value,
)
    holder = trace.fields[:holder]
    node = if trace.path === :direct
        holder
    elseif trace.path === :wrapper
        holder.child
    else
        holder[1]
    end
    node.value = node_value
    return trace
end

Base.length(values::_TransactionModelMutatingFields) =
    length(values.values)
Base.iterate(
    values::_TransactionModelMutatingFields,
    state...,
) = iterate(values.values, state...)
Base.getindex(
    values::_TransactionModelMutatingFields,
    key::Symbol,
) = values.values[key]
Base.haskey(values::_TransactionModelMutatingFields, key) =
    haskey(values.values, key)
Base.get(
    values::_TransactionModelMutatingFields,
    key,
    default,
) = get(values.values, key, default)
function Base.setindex!(
    values::_TransactionModelMutatingFields,
    value,
    key::Symbol,
)
    if key === :y
        if values.target === :config
            values.owner.scrollZoom = false
        elseif values.target === :frames
            push!(values.owner, frame(name="generic-side-effect"))
        end
    end
    values.values[key] = value
    return value
end

PlotlyBase.JSON.lower(layout::_TransactionCustomLayout) =
    layout.fields
Base.getindex(layout::_TransactionCustomLayout, key) =
    layout.fields[Symbol(key)]
Base.setindex!(
    layout::_TransactionCustomLayout,
    value,
    key,
) = (layout.fields[Symbol(key)] = value)

Base.length(values::_TransactionSelfCopyAliasDict) =
    length(values.values)
Base.iterate(
    values::_TransactionSelfCopyAliasDict,
    state...,
) = iterate(values.values, state...)
Base.getindex(
    values::_TransactionSelfCopyAliasDict,
    key::Symbol,
) = values.values[key]
Base.haskey(values::_TransactionSelfCopyAliasDict, key) =
    haskey(values.values, key)
Base.get(
    values::_TransactionSelfCopyAliasDict,
    key,
    default,
) = get(values.values, key, default)
function Base.setindex!(
    values::_TransactionSelfCopyAliasDict,
    value,
    key::Symbol,
)
    values.writes += 1
    values.values[key] = value
    return value
end
Base.copy(values::_TransactionSelfCopyAliasDict) = values

Base.IndexStyle(::Type{_TransactionZeroBasedVector}) =
    IndexLinear()
Base.size(values::_TransactionZeroBasedVector) =
    size(values.values)
Base.axes(values::_TransactionZeroBasedVector) =
    (0:(length(values.values) - 1),)
Base.eachindex(values::_TransactionZeroBasedVector) =
    axes(values, 1)
Base.firstindex(::_TransactionZeroBasedVector) = 0
Base.lastindex(values::_TransactionZeroBasedVector) =
    length(values.values) - 1
Base.getindex(
    values::_TransactionZeroBasedVector,
    ind::Int,
) = values.values[ind + 1]
Base.setindex!(
    values::_TransactionZeroBasedVector,
    value,
    ind::Int,
) = (values.values[ind + 1] = value)
Base.copy(values::_TransactionZeroBasedVector) =
    copy(values.values)

function PlotlyBase.JSON.lower(
    trace::_TransactionDataRootMutatingTrace,
)
    return Dict{Symbol,Any}(
        :type => get(trace.fields, :type, "scatter"),
        :name => get(trace.fields, :name, nothing),
        :data_length => length(trace.fields[:shared_data]),
    )
end
Base.getindex(trace::_TransactionDataRootMutatingTrace, key) =
    trace.fields[Symbol(key)]
function Base.setindex!(
    trace::_TransactionDataRootMutatingTrace,
    value,
    key,
)
    if Symbol(key) === :name
        root = trace.fields[:shared_data]
        if trace.action === :push
            push!(root, scatter(y=[2], name="side-effect"))
        elseif trace.action === :delete
            deleteat!(root, lastindex(root))
        elseif trace.action === :reverse
            reverse!(root)
        end
    end
    trace.fields[Symbol(key)] = value
    return value
end

function PlotlyBase.JSON.lower(
    trace::_TransactionRootValueMutatingTrace,
)
    root = trace.fields[:root]
    value = if trace.target === :config
        root.toImageButtonOptions[:size]
    elseif trace.target === :frames
        length(root)
    else
        root.fields[:audit_value]
    end
    return Dict{Symbol,Any}(
        :type => get(trace.fields, :type, "scatter"),
        :name => get(trace.fields, :name, nothing),
        :root_value => value,
    )
end
Base.getindex(trace::_TransactionRootValueMutatingTrace, key) =
    trace.fields[Symbol(key)]
function Base.setindex!(
    trace::_TransactionRootValueMutatingTrace,
    value,
    key,
)
    if Symbol(key) === :name
        root = trace.fields[:root]
        if trace.target === :config
            root.toImageButtonOptions[:size] = 20
        elseif trace.target === :frames
            push!(root, frame(name="custom-frame-side-effect"))
        else
            root.fields[:audit_value] = 20
        end
    end
    trace.fields[Symbol(key)] = value
    return value
end

function PlotlyBase.restyle!(
    trace::Union{
        _TransactionDataRootMutatingTrace,
        _TransactionRootValueMutatingTrace,
    },
    ::Int,
    update::AbstractDict=Dict();
    kwargs...,
)
    for (key, value) in update
        trace[key] = value
    end
    for (key, value) in pairs(kwargs)
        trace[key] = value
    end
    return trace
end

Base.IndexStyle(::Type{_TransactionFrameVector}) = IndexLinear()
Base.size(values::_TransactionFrameVector) = size(values.values)
Base.getindex(values::_TransactionFrameVector, ind::Int) =
    values.values[ind]
Base.setindex!(
    values::_TransactionFrameVector,
    value,
    ind::Int,
) = (values.values[ind] = value)
Base.push!(values::_TransactionFrameVector, value) =
    (push!(values.values, value); values)

PlotlyBase.JSON.lower(trace::_TransactionFailingInputTrace) =
    trace.fields
Base.getindex(trace::_TransactionFailingInputTrace, key) =
    trace.fields[Symbol(key)]
function PlotlyBase.restyle!(
    trace::_TransactionFailingInputTrace,
    ::Int,
    ::AbstractDict=Dict();
    payload,
)
    child = payload[1]
    if child isa Integer
        payload[1] = 9
    else
        child.child[:size] = 9
    end
    throw(ErrorException("injected-third-party-setter-failure"))
end

PlotlyBase.JSON.lower(trace::_TransactionIgnoringTrace) =
    trace.fields
Base.getindex(trace::_TransactionIgnoringTrace, key) =
    trace.fields[Symbol(key)]
Base.setindex!(trace::_TransactionIgnoringTrace, value, key) =
    (trace.fields[Symbol(key)] = value)
PlotlyBase.restyle!(
    trace::_TransactionIgnoringTrace,
    ::Int,
    ::AbstractDict=Dict();
    kwargs...,
) = trace

Base.IndexStyle(::Type{_TransactionCountingVector}) = IndexLinear()
Base.size(values::_TransactionCountingVector) = size(values.values)
function Base.getindex(
    values::_TransactionCountingVector,
    ind::Int,
)
    values.reads[] += 1
    return values.values[ind]
end
Base.setindex!(
    values::_TransactionCountingVector,
    value,
    ind::Int,
) = (values.values[ind] = value)

PlotlyBase.JSON.lower(trace::_TransactionScalarMutatingTrace) =
    trace.fields
Base.getindex(trace::_TransactionScalarMutatingTrace, key) =
    trace.fields[Symbol(key)]
function Base.setindex!(
    trace::_TransactionScalarMutatingTrace,
    value,
    key,
)
    token = trace.fields[:token]
    if token isa _TransactionLyingNumber
        token.state += 1
    else
        trace.fields[:token] =
            _TransactionLyingBits(token.state + 1)
    end
    trace.fields[Symbol(key)] = value
    return value
end

mutable struct _TransactionSelfCopyVector <: AbstractVector{Any}
    values::Vector{Any}
    writes::Int
end

Base.IndexStyle(::Type{_TransactionSelfCopyVector}) =
    IndexLinear()
Base.size(values::_TransactionSelfCopyVector) =
    size(values.values)
Base.getindex(values::_TransactionSelfCopyVector, ind::Int) =
    values.values[ind]
function Base.setindex!(
    values::_TransactionSelfCopyVector,
    value,
    ind::Int,
)
    values.writes += 1
    values.values[ind] = value
    return value
end
Base.copy(values::_TransactionSelfCopyVector) = values

mutable struct _TransactionRendererState
    open::Bool
    scripts::Vector{String}
    outcomes::Vector{Any}
end

_TransactionRendererState(outcomes=Any[]) =
    _TransactionRendererState(true, String[], collect(Any, outcomes))

function _transaction_backend(state::_TransactionRendererState)
    return (
        isopen=window -> state.open,
        close=window -> begin
            state.open = false
            return nothing
        end,
        run=(window, script) -> begin
            push!(state.scripts, String(script))
            outcome =
                isempty(state.outcomes) ? "ok" : popfirst!(state.outcomes)
            outcome isa Exception && throw(outcome)
            return outcome
        end,
    )
end

function _transaction_fixture(;
    register::Bool=false,
    outcomes=Any[],
)
    state = _TransactionRendererState(outcomes)
    p = Plot(
        [
            scatter(
                x=[1, 2, 3],
                y=[10_001, 10_002, 10_003],
                name="old-first",
            ),
            scatter(
                x=[4, 5, 6],
                y=[20_001, 20_002, 20_003],
                name="old-second",
            ),
        ],
        Layout(title="old-transaction-title"),
    )
    resources = PlotlySupply._SyncPlotResources(
        nothing,
        _transaction_backend(state),
    )
    sp = SyncPlot(p, nothing, :transaction_window, "transaction-div", resources)
    if register
        old, registered =
            PlotlySupply._register_displayed_syncplot!(p, sp)
        old === nothing || error("unexpected prior transaction fixture")
        registered || error("failed to register transaction fixture")
    end
    return p, sp, state
end

function _transaction_snapshot(p::Plot)
    return (
        json=PlotlyBase.JSON.json(p; allownan=true),
        data=p.data,
        layout=p.layout,
        frames=p.frames,
        config=p.config,
        trace=p.data[1],
        trace_fields=p.data[1].fields,
        layout_fields=p.layout.fields,
        y=p.data[1][:y],
    )
end

function _test_transaction_snapshot(p::Plot, snapshot)
    @test PlotlyBase.JSON.json(p; allownan=true) == snapshot.json
    @test p.data === snapshot.data
    @test p.layout === snapshot.layout
    @test p.frames === snapshot.frames
    @test p.config === snapshot.config
    @test p.data[1] === snapshot.trace
    @test p.data[1].fields === snapshot.trace_fields
    @test p.layout.fields === snapshot.layout_fields
    @test p.data[1][:y] === snapshot.y
end

function _apply_transaction_operation!(target, operation::Symbol)
    if operation === :relayout
        return relayout!(target; title="candidate-relayout")
    elseif operation === :restyle_int
        return restyle!(target, 1; marker_size=17)
    elseif operation === :restyle_vector
        return restyle!(
            target,
            [1, 2],
            Dict(:name => ["candidate-first", "candidate-second"]),
        )
    elseif operation === :restyle_all
        return restyle!(
            target,
            Dict(:opacity => [0.25, 0.75]),
        )
    elseif operation === :update_index
        return update!(
            target,
            1,
            Dict(:name => "candidate-update");
            layout=Layout(title="candidate-update-layout"),
        )
    elseif operation === :update_all
        return update!(
            target,
            Dict(:name => ["candidate-a", "candidate-b"]);
            layout=Layout(title="candidate-update-all"),
        )
    elseif operation === :react
        p = target isa SyncPlot ? target.plot : target
        return react!(
            target,
            copy(p.data),
            Layout(title="candidate-react"),
        )
    end
    error("unsupported transaction test operation: $operation")
end

function _operation_script_name(operation::Symbol)
    operation === :relayout && return "Plotly.relayout"
    operation in (:restyle_int, :restyle_vector, :restyle_all) &&
        return "Plotly.restyle"
    operation in (:update_index, :update_all) && return "Plotly.update"
    operation === :react && return "Plotly.react"
    error("unsupported transaction test operation: $operation")
end

@testset "renderer-backed mutation success is staged and incremental" begin
    operations = (
        :relayout,
        :restyle_int,
        :restyle_vector,
        :restyle_all,
        :update_index,
        :update_all,
        :react,
    )
    for registered in (false, true), operation in operations
        p, sp, state = _transaction_fixture(; register=registered)
        target = registered ? p : sp
        old_data = p.data
        old_layout = p.layout
        old_trace = p.data[1]
        old_y = p.data[1][:y]
        try
            @test _apply_transaction_operation!(target, operation) === target
            @test length(state.scripts) == 1
            script = only(state.scripts)
            @test occursin(_operation_script_name(operation), script)
            if operation !== :react
                @test !occursin("10001,10002,10003", script)
            end

            @test p.data[1] === old_trace
            @test p.data[1][:y] === old_y
            if operation === :react
                @test p.data !== old_data
                @test p.layout !== old_layout
            else
                @test p.data === old_data
                @test p.layout === old_layout
            end
        finally
            close(sp)
        end
    end
end

@testset "renderer failure rolls back direct and registered mutations" begin
    operations = (
        :relayout,
        :restyle_int,
        :restyle_vector,
        :restyle_all,
        :update_index,
        :update_all,
        :react,
    )
    for registered in (false, true), operation in operations
        primary = ErrorException(
            "injected-$registered-$operation-renderer-failure",
        )
        p, sp, state = _transaction_fixture(
            ;
            register=registered,
            outcomes=Any[primary, "ok"],
        )
        target = registered ? p : sp
        snapshot = _transaction_snapshot(p)
        try
            caught = try
                _apply_transaction_operation!(target, operation)
                nothing
            catch err
                err
            end
            @test caught === primary
            _test_transaction_snapshot(p, snapshot)
            @test length(state.scripts) == 2
            @test occursin(
                _operation_script_name(operation),
                state.scripts[1],
            )
            @test occursin("Plotly.newPlot", state.scripts[2])
            @test occursin("old-transaction-title", state.scripts[2])
            @test !sp._resources.renderer_desynchronized
        finally
            close(sp)
        end
    end
end

function _apply_full_refresh_operation!(target, operation::Symbol)
    if operation === :addtraces
        return addtraces!(
            target,
            scatter(y=[31, 32], name="candidate-added"),
        )
    elseif operation === :addtraces_index
        return addtraces!(
            target,
            2,
            scatter(y=[31, 32], name="candidate-inserted"),
        )
    elseif operation === :deletetraces
        return deletetraces!(target, 2)
    elseif operation === :movetraces
        return movetraces!(target, 1)
    elseif operation === :movetraces_vectors
        return movetraces!(target, [1, 2], [2, 1])
    elseif operation === :extendtraces
        return extendtraces!(
            target,
            Dict(:y => [[99]]),
            [1],
        )
    elseif operation === :prependtraces
        return prependtraces!(
            target,
            Dict(:y => [[99]]),
            [1],
        )
    elseif operation === :update_geos
        return update_geos!(target; bgcolor="candidate-red")
    elseif operation === :add_trace
        return add_trace!(
            target,
            scatter(y=[41, 42], name="candidate-singular"),
        )
    elseif operation === :add_hline
        return add_hline!(target, 12)
    elseif operation === :plot_pie
        return plot_pie!(
            target,
            [3, 5, 8];
            title="candidate-pie",
        )
    elseif operation === :set_legend
        return set_legend!(
            target;
            position=:bottom,
            showlegend=true,
        )
    end
    error("unsupported full-refresh transaction operation: $operation")
end

@testset "full-refresh compatibility mutations roll back on renderer failure" begin
    operations = (
        :addtraces,
        :addtraces_index,
        :deletetraces,
        :movetraces,
        :movetraces_vectors,
        :extendtraces,
        :prependtraces,
        :update_geos,
        :add_trace,
        :add_hline,
        :plot_pie,
        :set_legend,
    )
    for registered in (false, true), operation in operations
        primary = ErrorException(
            "injected-$registered-$operation-full-refresh-failure",
        )
        p, sp, state = _transaction_fixture(
            ;
            register=registered,
            outcomes=Any[primary, "ok"],
        )
        target = registered ? p : sp
        snapshot = _transaction_snapshot(p)
        try
            caught = try
                _apply_full_refresh_operation!(target, operation)
                nothing
            catch err
                err
            end
            @test caught === primary
            _test_transaction_snapshot(p, snapshot)
            @test length(state.scripts) == 2
            expected_operation =
                operation === :plot_pie ? "Plotly.addTraces" :
                operation === :set_legend ? "Plotly.relayout" :
                "Plotly.react"
            @test occursin(
                expected_operation,
                state.scripts[1],
            )
            @test occursin("Plotly.newPlot", state.scripts[2])
            @test occursin(
                "old-transaction-title",
                state.scripts[2],
            )
            @test !sp._resources.renderer_desynchronized
        finally
            close(sp)
        end
    end
end

function _large_high_level_map_fixture(
    count::Int;
    outcomes=Any[],
    register::Bool=false,
)
    features = [
        Dict{String,Any}(
            "type" => "Feature",
            "id" => index,
            "properties" => Dict{String,Any}(
                "value" => index,
            ),
        )
        for index in 1:count
    ]
    geojson = Dict{String,Any}(
        "type" => "FeatureCollection",
        "features" => features,
    )
    layers = [
        Dict{String,Any}(
            "id" => "existing-layer-$index",
            "type" => "fill",
        )
        for index in 1:count
    ]
    sources = Dict(
        "existing-source-$index" => Dict{String,Any}(
            "type" => "geojson",
            "data" => Dict{String,Any}(
                "type" => "FeatureCollection",
                "features" => Any[],
            ),
        )
        for index in 1:count
    )
    style = Dict{String,Any}(
        "version" => 8,
        "sources" => sources,
        "layers" => layers,
    )
    p = plot_choroplethmap(
        geojson,
        1:count,
        1:count;
        style=style,
    )
    state = _TransactionRendererState(outcomes)
    sp = SyncPlot(
        p,
        nothing,
        :high_level_map_window,
        "high-level-map-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    if register
        old, registered =
            PlotlySupply._register_displayed_syncplot!(p, sp)
        old === nothing ||
            error("unexpected high-level map registration")
        registered ||
            error("failed to register high-level map fixture")
    end
    return (; p, sp, state, geojson, features, style, layers, sources)
end

@testset "high-level append transactions stay incremental and bounded" begin
    for function_name in
        PlotlySupply._TRANSACTIONAL_HIGH_LEVEL_PLOT_MUTATORS
        @test PlotlySupply._is_transactional_high_level_plot_mutator(
            getfield(PlotlySupply, function_name),
        )
    end
    @test !PlotlySupply._is_transactional_high_level_plot_mutator(
        PlotlyBase.relayout!,
    )

    for registered in (false, true)
        fixture = _large_high_level_map_fixture(
            1_000;
            register=registered,
        )
        p = fixture.p
        target = registered ? p : fixture.sp
        data = p.data
        layout = p.layout
        original_trace = only(p.data)
        try
            @test plot_scattermap!(
                target,
                [121.5],
                [25.0];
                legend="incremental-map",
            ) === nothing
            @test length(fixture.state.scripts) == 1
            script = only(fixture.state.scripts)
            @test occursin("Plotly.addTraces", script)
            @test occursin("Plotly.relayout", script)
            @test !occursin("Plotly.react", script)
            @test !occursin("FeatureCollection", script)
            @test !occursin("\"features\"", script)
            @test !occursin("\"layers\"", script)
            @test !occursin("\"sources\"", script)
            @test ncodeunits(script) < 10_000

            @test p.data === data
            @test p.layout === layout
            @test p.data[1] === original_trace
            @test original_trace.fields[:geojson] ===
                  fixture.geojson
            @test fixture.geojson["features"] ===
                  fixture.features
            @test p.layout.fields[:map][:style] ===
                  fixture.style
            @test fixture.style["layers"] === fixture.layers
            @test fixture.style["sources"] === fixture.sources
            @test p.data[2].fields[:name] == "incremental-map"
        finally
            close(fixture.sp)
        end
    end
end

@testset "high-level append renderer failure restores old payload" begin
    for registered in (false, true)
        primary = ErrorException(
            "injected-$registered-high-level-map-failure",
        )
        fixture = _large_high_level_map_fixture(
            250;
            outcomes=Any[primary, "ok"],
            register=registered,
        )
        p = fixture.p
        target = registered ? p : fixture.sp
        snapshot = (
            json=PlotlyBase.JSON.json(p; allownan=true),
            data=p.data,
            layout=p.layout,
            frames=p.frames,
            config=p.config,
            trace=p.data[1],
            trace_fields=p.data[1].fields,
            layout_fields=p.layout.fields,
        )
        try
            caught = try
                plot_scattermap!(
                    target,
                    [121.5],
                    [25.0];
                    legend="must-roll-back",
                )
                nothing
            catch err
                err
            end
            @test caught === primary
            @test PlotlyBase.JSON.json(p; allownan=true) ==
                  snapshot.json
            @test p.data === snapshot.data
            @test p.layout === snapshot.layout
            @test p.frames === snapshot.frames
            @test p.config === snapshot.config
            @test p.data[1] === snapshot.trace
            @test p.data[1].fields === snapshot.trace_fields
            @test p.layout.fields === snapshot.layout_fields
            @test length(fixture.state.scripts) == 2
            @test occursin(
                "Plotly.addTraces",
                fixture.state.scripts[1],
            )
            @test !occursin(
                "FeatureCollection",
                fixture.state.scripts[1],
            )
            @test occursin(
                "Plotly.newPlot",
                fixture.state.scripts[2],
            )
            @test occursin(
                "FeatureCollection",
                fixture.state.scripts[2],
            )
            @test p.data[1].fields[:geojson] ===
                  fixture.geojson
            @test p.layout.fields[:map][:style] ===
                  fixture.style
        finally
            close(fixture.sp)
        end
    end
end

@testset "high-level fast path falls back for mutable aliases" begin
    shared = Dict{Symbol,Any}(:size => 10)
    trace = scatter(x=[1], y=[1])
    trace.fields[:marker] = shared
    layout = Layout()
    layout.fields[:font] = shared
    p = Plot([trace], layout)
    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :high_level_alias_window,
        "high-level-alias-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test plot_scatter!(
            sp,
            [2],
            [2];
            fontsize=20,
        ) === nothing
        @test p.data[1].fields[:marker] ===
              p.layout.fields[:font]
        @test p.layout.fields[:font][:size] == 20
        @test occursin("Plotly.react", only(state.scripts))
        @test !occursin(
            "Plotly.addTraces",
            only(state.scripts),
        )
    finally
        close(sp)
    end

    shared_font = Dict{Symbol,Any}(:size => 10)
    style = Dict{String,Any}(
        "version" => 8,
        "sources" => Dict{String,Any}(),
        "layers" => Any[],
        "font-alias" => shared_font,
    )
    layout = Layout()
    layout.fields[:font] = shared_font
    map_attribute = attr()
    map_attribute.fields[:style] = style
    layout.fields[:map] = map_attribute
    p = Plot(scattermap(lon=[0.0], lat=[0.0]), layout)
    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :high_level_style_alias_window,
        "high-level-style-alias-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test plot_scattermap!(
            sp,
            [1.0],
            [1.0];
            fontsize=20,
        ) === nothing
        committed_style = p.layout.fields[:map][:style]
        @test committed_style["font-alias"] ===
              p.layout.fields[:font]
        @test p.layout.fields[:font][:size] == 20
        @test style["font-alias"] === shared_font
        @test shared_font[:size] == 10
        @test occursin("Plotly.react", only(state.scripts))
    finally
        close(sp)
    end

    captured_font = Dict{Symbol,Any}(:size => 10)
    callback = ((value) -> () -> value)(captured_font)
    layout = Layout()
    layout.fields[:font] = captured_font
    layout.fields[:callback] = callback
    p = Plot(scatter(x=[1], y=[1]), layout)
    @test PlotlySupply._prepare_high_level_plot_fast_context(
        p,
    ) === nothing
    @test plot_scatter!(
        p,
        [2],
        [2];
        fontsize=20,
    ) === nothing
    committed_callback = p.layout.fields[:callback]
    @test committed_callback() === p.layout.fields[:font]
    @test p.layout.fields[:font][:size] == 20
    @test captured_font[:size] == 10
end

@testset "existing-trace high-level mutations retain full staging" begin
    old_surface = surface(z=[1.0 2.0; 3.0 4.0])
    p = Plot(old_surface)
    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :shared_coloraxis_window,
        "shared-coloraxis-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test plot_surface!(
            sp,
            [5.0 6.0; 7.0 8.0];
            shared_coloraxis=true,
        ) === nothing
        @test p.data[1] === old_surface
        @test p.data[1].fields[:coloraxis] == "coloraxis"
        @test p.data[2].fields[:coloraxis] == "coloraxis"
        @test occursin("Plotly.react", only(state.scripts))
        @test !occursin(
            "Plotly.addTraces",
            only(state.scripts),
        )
    finally
        close(sp)
    end
end

@testset "model-root aliases roll back on renderer failure" begin
    for registered in (false, true),
        model_field in (:data, :frames, :config)
        primary = ErrorException(
            "injected-$registered-$model_field-model-root-failure",
        )
        custom = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1, 2],
            ),
        )
        p = Plot(AbstractTrace[custom], Layout())
        original_model_root = getfield(p, model_field)
        custom.fields[:shared_model_root] = original_model_root
        state = _TransactionRendererState(Any[primary, "ok"])
        sp = SyncPlot(
            p,
            nothing,
            Symbol(model_field, :_rollback_window),
            string(model_field, "-rollback-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        registered &&
            PlotlySupply._register_displayed_syncplot!(p, sp)
        target = registered ? p : sp
        snapshot = _transaction_snapshot(p)
        try
            caught = try
                extendtraces!(
                    target,
                    Dict(:y => [[3]]),
                    [1],
                )
                nothing
            catch err
                err
            end
            @test caught === primary
            _test_transaction_snapshot(p, snapshot)
            @test custom.fields[:shared_model_root] ===
                  original_model_root
            @test length(state.scripts) == 2
            @test occursin("Plotly.react", state.scripts[1])
            @test occursin("Plotly.newPlot", state.scripts[2])
            @test !sp._resources.renderer_desynchronized
        finally
            close(sp)
        end
    end
end

@testset "model-root side effects commit without splitting aliases" begin
    for target in (:frames, :config)
        fields = _TransactionModelMutatingFields(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1, 2],
            ),
            target,
            nothing,
        )
        trace = GenericTrace(fields)
        p = Plot(
            AbstractTrace[trace],
            Layout(),
            PlotlyFrame[],
        )
        original_root = getfield(p, target)
        fields.owner = original_root
        state = _TransactionRendererState()
        sp = SyncPlot(
            p,
            nothing,
            Symbol(target, :_generic_side_effect_window),
            string(target, "-generic-side-effect-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        try
            @test extendtraces!(
                sp,
                Dict(:y => [[3]]),
                [1],
            ) === sp
            @test getfield(p, target) === original_root
            @test p.data[1] === trace
            @test trace.fields.owner === original_root
            @test trace[:y] == [1, 2, 3]
            if target === :frames
                @test length(p.frames) == 1
                @test p.frames[1].fields[:name] ==
                      "generic-side-effect"
                @test occursin("Plotly.newPlot", only(state.scripts))
                @test occursin("Plotly.addFrames", only(state.scripts))
            else
                @test p.config.scrollZoom === false
                @test occursin("Plotly.react", only(state.scripts))
            end
        finally
            close(sp)
        end
    end

    for target in (:frames, :config)
        trace = _TransactionDetachingModelTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1, 2],
            ),
            target,
        )
        p = Plot(
            AbstractTrace[trace],
            Layout(),
            PlotlyFrame[],
        )
        original_root = getfield(p, target)
        trace.fields[:shared] = original_root
        @test extendtraces!(
            p,
            Dict(:y => [[3]]),
            [1],
        ) === p
        @test getfield(p, target) === original_root
        @test p.data[1] !== trace
        @test !haskey(p.data[1].fields, :shared)
        @test p.data[1][:y] == [1, 2, 3]
        if target === :frames
            @test length(p.frames) == 1
            @test p.frames[1].fields[:name] ==
                  "detached-side-effect"
        else
            @test p.config.scrollZoom === false
        end
    end

    shared = Dict{Symbol,Any}(:value => 1)
    trace = _TransactionDetachingModelTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
        ),
        :shared_roots,
    )
    config = PlotConfig(modeBarButtonsToAdd=Any[shared])
    p = Plot(
        AbstractTrace[trace],
        Layout(),
        [
            frame(
                Dict{Symbol,Any}(
                    :name => "shared-frame",
                    :shared => shared,
                ),
            ),
        ];
        config=config,
    )
    original_frames = p.frames
    original_config = p.config
    trace.fields[:shared] = p.config
    @test extendtraces!(
        p,
        Dict(:y => [[3]]),
        [1],
    ) === p
    @test p.frames === original_frames
    @test p.config === original_config
    @test !haskey(p.data[1].fields, :shared)
    @test p.frames[1].fields[:shared] ===
          p.config.modeBarButtonsToAdd[1]
    @test p.frames[1].fields[:shared][:value] == 2

    for target in (:config_structure, :frames_structure)
        shared = Dict{Symbol,Any}(:value => 1)
        trace = _TransactionDetachingModelTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1, 2],
            ),
            target,
        )
        config = PlotConfig(modeBarButtonsToAdd=Any[shared])
        p = Plot(
            AbstractTrace[trace],
            Layout(),
            [
                frame(
                    Dict{Symbol,Any}(
                        :name => "shared-frame",
                        :shared => shared,
                    ),
                ),
            ];
            config=config,
        )
        original_frames = p.frames
        original_config = p.config
        trace.fields[:shared] =
            target === :config_structure ?
            p.config :
            p.frames
        @test extendtraces!(
            p,
            Dict(:y => [[3]]),
            [1],
        ) === p
        @test p.frames === original_frames
        @test p.config === original_config
        @test p.frames[1].fields[:shared] ===
              p.config.modeBarButtonsToAdd[1]
        @test p.frames[1].fields[:shared][:value] == 1
        if target === :config_structure
            @test length(p.frames) == 1
            @test p.config.modeBarButtonsToAdd[2] == "added"
        else
            @test length(p.frames) == 2
            @test length(p.config.modeBarButtonsToAdd) == 1
        end
    end

    trace = _TransactionDetachingModelTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
        ),
        :frames,
    )
    p = Plot(
        AbstractTrace[trace],
        Layout(),
        [frame(name="owner-frame")],
    )
    original_frames = p.frames
    p.frames[1].fields[:owner] = p.frames
    trace.fields[:shared] = p.frames
    @test extendtraces!(
        p,
        Dict(:y => [[3]]),
        [1],
    ) === p
    @test p.frames === original_frames
    @test p.frames[1].fields[:owner] === p.frames

    trace = _TransactionDetachingModelTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
        ),
        :config,
    )
    p = Plot(
        AbstractTrace[trace],
        Layout(),
        PlotlyFrame[],
    )
    original_config = p.config
    p.config.modeBarButtonsToAdd = Any[p.config, p.frames]
    trace.fields[:shared] = p.config
    @test extendtraces!(
        p,
        Dict(:y => [[3]]),
        [1],
    ) === p
    @test p.config === original_config
    @test p.config.modeBarButtonsToAdd[1] === p.config
    @test p.config.modeBarButtonsToAdd[2] === p.frames
end

@testset "model-root side effects roll back before commit" begin
    for target in (:frames, :config)
        fields = _TransactionModelMutatingFields(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1, 2],
            ),
            target,
            nothing,
        )
        trace = GenericTrace(fields)
        p = Plot(
            AbstractTrace[trace],
            Layout(),
            PlotlyFrame[],
        )
        original_root = getfield(p, target)
        fields.owner = original_root
        primary = ErrorException(
            "injected-$target-side-effect-failure",
        )
        state = _TransactionRendererState(Any[primary, "ok"])
        sp = SyncPlot(
            p,
            nothing,
            Symbol(target, :_side_effect_rollback_window),
            string(target, "-side-effect-rollback-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        snapshot = _transaction_snapshot(p)
        try
            caught = try
                extendtraces!(
                    sp,
                    Dict(:y => [[3]]),
                    [1],
                )
                nothing
            catch err
                err
            end
            @test caught === primary
            _test_transaction_snapshot(p, snapshot)
            @test fields.owner === original_root
            @test isempty(p.frames)
            @test p.config.scrollZoom === true
            @test length(state.scripts) == 2
            if target === :frames
                @test occursin("Plotly.newPlot", state.scripts[1])
                @test occursin(
                    "generic-side-effect",
                    state.scripts[1],
                )
            else
                @test occursin("Plotly.react", state.scripts[1])
            end
        finally
            close(sp)
        end
    end

    for target in (:frames, :config)
        p = Plot(
            scatter(y=[1, 2]),
            Layout(),
            PlotlyFrame[],
        )
        original_frames = p.frames
        original_config = p.config
        caught = try
            PlotlySupply._transactional_full_plot_mutation!(p) do candidate
                if target === :frames
                    push!(
                        candidate.frames,
                        frame(name="unscoped-abort"),
                    )
                else
                    candidate.config.scrollZoom = false
                end
                error("unscoped-$target-abort")
            end
            nothing
        catch err
            err
        end
        @test caught isa ErrorException
        @test occursin(
            "unscoped-$target-abort",
            sprint(showerror, caught),
        )
        @test p.frames === original_frames
        @test isempty(p.frames)
        @test p.config === original_config
        @test p.config.scrollZoom === true
        @test p.data[1][:y] == [1, 2]
    end

    p = Plot(
        scatter(y=[1, 2]),
        Layout(),
        PlotlyFrame[],
    )
    original_frames = p.frames
    result = PlotlySupply._transactional_full_plot_mutation!(p) do candidate
        candidate.config.modeBarButtonsToAdd =
            Any[original_frames]
    end
    @test result === p
    @test p.frames === original_frames
    @test p.config.modeBarButtonsToAdd[1] === p.frames
end

@testset "custom layouts retain model-root aliases" begin
    trace = scatter(y=[1, 2])
    layout = _TransactionCustomLayout(
        Dict{Symbol,Any}(:title => "custom-layout"),
    )
    p = Plot(
        AbstractTrace[trace],
        layout,
        PlotlyFrame[],
    )
    layout.fields[:data_root] = p.data
    layout.fields[:frames_root] = p.frames
    layout.fields[:config_root] = p.config
    layout.fields[:trace_root] = trace
    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :custom_layout_model_roots_window,
        "custom-layout-model-roots-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test extendtraces!(
            sp,
            Dict(:y => [[3]]),
            [1],
        ) === sp
        @test p.layout !== layout
        @test p.data[1] !== trace
        @test p.layout.fields[:data_root] === p.data
        @test p.layout.fields[:frames_root] === p.frames
        @test p.layout.fields[:config_root] === p.config
        @test p.layout.fields[:trace_root] === p.data[1]
        @test p.data[1][:y] == [1, 2, 3]
        @test occursin("Plotly.react", only(state.scripts))
    finally
        close(sp)
    end
end

@testset "structural data transactions preserve public roots" begin
    p, sp, state = _transaction_fixture()
    original_data = p.data
    first, second = p.data
    appended = scatter(y=[31, 32], name="appended-root")
    try
        @test addtraces!(sp, appended) === sp
        @test p.data === original_data
        @test p.data == [first, second, appended]
        @test p.data[1] === first
        @test p.data[2] === second
        @test p.data[3] === appended

        @test movetraces!(sp, 1) === sp
        @test p.data === original_data
        @test p.data == [second, appended, first]
        @test all(
            trace === expected
            for (trace, expected) in
                zip(p.data, (second, appended, first))
        )

        @test movetraces!(sp, [1, 3], [3, 1]) === sp
        @test p.data === original_data
        @test all(
            trace === expected
            for (trace, expected) in
                zip(p.data, (second, appended, first))
        )

        @test deletetraces!(sp, 2) === sp
        @test p.data === original_data
        @test p.data == [second, first]
        @test p.data[1] === second
        @test p.data[2] === first

        inserted = scatter(y=[41, 42], name="inserted-root")
        prior_data = p.data
        @test addtraces!(sp, 2, inserted) === sp
        @test p.data !== prior_data
        @test p.data[1] === second
        @test p.data[2] === inserted
        @test p.data[3] === first
        @test length(state.scripts) == 5
        @test all(
            occursin("Plotly.react", script)
            for script in state.scripts
        )
    finally
        close(sp)
    end

end

@testset "full-model staging preserves unchanged custom trace identities" begin
    for mode in (:raw, :direct, :registered)
        custom = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1, 2, 3],
                :name => "custom-old",
            ),
        )
        p = Plot(AbstractTrace[custom], Layout())
        data = p.data
        state = _TransactionRendererState()
        sp = SyncPlot(
            p,
            nothing,
            Symbol(mode, :_custom_trace_window),
            string(mode, "-custom-trace-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        mode === :registered &&
            PlotlySupply._register_displayed_syncplot!(p, sp)
        target = mode === :direct ? sp : p
        try
            @test addtraces!(
                target,
                scatter(y=[4, 5], name="added"),
            ) === target
            @test p.data === data
            @test p.data[1] === custom
            @test length(p.data) == 2
            @test length(state.scripts) == (mode === :raw ? 0 : 1)
        finally
            close(sp)
        end
    end

    cycle = Dict{Symbol,Any}()
    cycle[:self] = cycle
    cyclic = _TransactionCustomTrace(
        Dict{Symbol,Any}(:type => "scatter", :meta => cycle),
    )
    cyclic_plot = Plot(AbstractTrace[cyclic], Layout())
    @test addtraces!(cyclic_plot, scatter(y=[1])) === cyclic_plot
    @test cyclic_plot.data[1] === cyclic

    scalar_trace = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :bigint => big(typemax(Int)) + 1,
            :bigfloat => BigFloat("1.234567890123456789"),
        ),
    )
    scalar_plot = Plot(AbstractTrace[scalar_trace], Layout())
    @test addtraces!(scalar_plot, scatter(y=[1])) === scalar_plot
    @test scalar_plot.data[1] === scalar_trace

    composite_key = (big"12345678901234567890",)
    keyed_trace = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :dict => Dict{Any,Any}(composite_key => "value"),
            :iddict => IdDict{Any,Any}(composite_key => "value"),
        ),
    )
    keyed_plot = Plot(AbstractTrace[keyed_trace], Layout())
    @test addtraces!(keyed_plot, scatter(y=[1])) === keyed_plot
    @test keyed_plot.data[1] === keyed_trace

    if isdefined(Core, :Memory)
        memory_type = getfield(Core, :Memory)
        memory = memory_type{Int}(undef, 3)
        copyto!(memory, [1, 2, 3])
        memory_trace = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :memory => memory,
            ),
        )
        memory_plot = Plot(AbstractTrace[memory_trace], Layout())
        @test addtraces!(memory_plot, scatter(y=[1])) === memory_plot
        @test memory_plot.data[1] === memory_trace
    end

    empty_trace = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :token => _TransactionEmptyToken(),
        ),
    )
    empty_plot = Plot(AbstractTrace[empty_trace], Layout())
    @test addtraces!(empty_plot, scatter(y=[1])) === empty_plot
    @test empty_plot.data[1] === empty_trace

    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2, 3],
            :name => "custom-old",
        ),
    )
    p = Plot(AbstractTrace[custom], Layout())
    mutation_result =
        PlotlySupply._transactional_full_plot_mutation!(p) do candidate
        candidate.data[1].fields[:name] = "custom-new"
        candidate.data[1].fields[:y][1] = 99
    end
    @test mutation_result === p
    @test p.data[1] !== custom
    @test p.data[1].fields[:name] == "custom-new"
    @test p.data[1].fields[:y] == [99, 2, 3]
    @test custom.fields[:name] == "custom-old"
    @test custom.fields[:y] == [1, 2, 3]

    shared = Dict{Symbol,Any}(:value => 1)
    aliased = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :a => shared,
            :b => shared,
        ),
    )
    aliased_plot = Plot(AbstractTrace[aliased], Layout())
    alias_result =
        PlotlySupply._transactional_full_plot_mutation!(
            aliased_plot,
        ) do candidate
            candidate.data[1].fields[:b] = shared
        end
    @test alias_result === aliased_plot
    @test aliased_plot.data[1] !== aliased
    @test aliased_plot.data[1].fields[:a] !==
          aliased_plot.data[1].fields[:b]
    @test aliased_plot.data[1].fields[:b] === shared
    @test aliased.fields[:a] === aliased.fields[:b]

    backing = [1, 2, 3]
    payload = @view backing[1:2]
    wrapped = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :backing => backing,
            :payload => payload,
        ),
    )
    wrapped_plot = Plot(AbstractTrace[wrapped], Layout())
    wrapper_result =
        PlotlySupply._transactional_full_plot_mutation!(
            wrapped_plot,
        ) do candidate
            staged_backing =
                candidate.data[1].fields[:backing]
            candidate.data[1].fields[:payload] =
                view(copy(staged_backing), 1:2)
        end
    @test wrapper_result === wrapped_plot
    @test wrapped_plot.data[1] !== wrapped
    @test collect(wrapped_plot.data[1].fields[:payload]) == [1, 2]
    @test parent(wrapped_plot.data[1].fields[:payload]) !==
          wrapped_plot.data[1].fields[:backing]
    @test parent(wrapped.fields[:payload]) === backing

    tagged_dict =
        _TransactionTaggedDict(Dict{Symbol,Any}(:value => 1), :old)
    tagged_vector = _TransactionTaggedVector(Any[1, 2], :old)
    tagged = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :dict => tagged_dict,
            :vector => tagged_vector,
        ),
    )
    tagged_plot = Plot(AbstractTrace[tagged], Layout())
    tagged_result =
        PlotlySupply._transactional_full_plot_mutation!(
            tagged_plot,
        ) do candidate
            candidate.data[1].fields[:dict].tag = :new
            candidate.data[1].fields[:vector].tag = :new
        end
    @test tagged_result === tagged_plot
    @test tagged_plot.data[1] !== tagged
    @test tagged_plot.data[1].fields[:dict].tag == :new
    @test tagged_plot.data[1].fields[:vector].tag == :new
    @test tagged.fields[:dict].tag == :old
    @test tagged.fields[:vector].tag == :old

    shared = Dict{Symbol,Any}(:value => 1)
    first = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :shared => shared,
        ),
    )
    second = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [4, 5],
            :shared => shared,
        ),
    )
    shared_plot = Plot(AbstractTrace[first, second], Layout())
    @test extendtraces!(
        shared_plot,
        Dict(:y => [[3]]),
        [1],
    ) === shared_plot
    @test shared_plot.data[1] !== first
    @test shared_plot.data[2] !== second
    @test shared_plot.data[1].fields[:y] == [1, 2, 3]
    @test shared_plot.data[1].fields[:shared] ===
          shared_plot.data[2].fields[:shared]

    shared = Dict{Symbol,Any}(:value => 2)
    trace = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :shared => shared,
        ),
    )
    shared_layout = Layout()
    shared_layout.fields[:meta] = shared
    trace_layout_plot = Plot(AbstractTrace[trace], shared_layout)
    @test extendtraces!(
        trace_layout_plot,
        Dict(:y => [[3]]),
        [1],
    ) === trace_layout_plot
    @test trace_layout_plot.data[1] !== trace
    @test trace_layout_plot.layout !== shared_layout
    @test trace_layout_plot.data[1].fields[:shared] ===
          trace_layout_plot.layout.fields[:meta]

    subplot_layout = Layout()
    subplot_metadata = getfield(subplot_layout, :subplots)
    trace = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :shared => subplot_metadata,
        ),
    )
    subplot_alias_plot =
        Plot(AbstractTrace[trace], subplot_layout)
    @test extendtraces!(
        subplot_alias_plot,
        Dict(:y => [[3]]),
        [1],
    ) === subplot_alias_plot
    @test subplot_alias_plot.data[1] !== trace
    @test subplot_alias_plot.layout !== subplot_layout
    @test subplot_alias_plot.data[1].fields[:shared] ===
          getfield(subplot_alias_plot.layout, :subplots)

    first = _TransactionCustomTrace(
        Dict{Symbol,Any}(:type => "scatter", :y => [1, 2]),
    )
    independent = _TransactionCustomTrace(
        Dict{Symbol,Any}(:type => "scatter", :y => [4, 5]),
    )
    independent_plot =
        Plot(AbstractTrace[first, independent], Layout())
    @test extendtraces!(
        independent_plot,
        Dict(:y => [[3]]),
        [1],
    ) === independent_plot
    @test independent_plot.data[1] !== first
    @test independent_plot.data[2] === independent

    shared_y = [1, 2]
    first = _TransactionCustomTrace(
        Dict{Symbol,Any}(:type => "scatter", :y => shared_y),
    )
    second = _TransactionCustomTrace(
        Dict{Symbol,Any}(:type => "scatter", :y => shared_y),
    )
    detached_plot = Plot(AbstractTrace[first, second], Layout())
    @test extendtraces!(
        detached_plot,
        Dict(:y => [[3]]),
        [1],
    ) === detached_plot
    @test detached_plot.data[1] !== first
    @test detached_plot.data[2] === second
    @test detached_plot.data[1].fields[:y] == [1, 2, 3]
    @test detached_plot.data[2].fields[:y] === shared_y
    @test detached_plot.data[1].fields[:y] !==
          detached_plot.data[2].fields[:y]

    shared_node = _TransactionSharedNode(7)
    first = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :nodes => [shared_node],
        ),
    )
    second = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [4, 5],
            :nodes => [shared_node],
        ),
    )
    node_plot = Plot(AbstractTrace[first, second], Layout())
    @test extendtraces!(
        node_plot,
        Dict(:y => [[3]]),
        [1],
    ) === node_plot
    @test node_plot.data[1] !== first
    @test node_plot.data[2] !== second
    @test node_plot.data[1].fields[:nodes][1] ===
          node_plot.data[2].fields[:nodes][1]

    captured = Ref(11)
    callback = () -> captured[]
    first = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :callback => callback,
        ),
    )
    second = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [4, 5],
            :callback => callback,
        ),
    )
    closure_plot = Plot(AbstractTrace[first, second], Layout())
    @test extendtraces!(
        closure_plot,
        Dict(:y => [[3]]),
        [1],
    ) === closure_plot
    @test closure_plot.data[1] !== first
    @test closure_plot.data[2] !== second
    @test closure_plot.data[1].fields[:callback] ===
          closure_plot.data[2].fields[:callback]
    @test closure_plot.data[1].fields[:callback]() == 11

    lying_number = _TransactionLyingNumber(0)
    scalar_mutating = _TransactionScalarMutatingTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :token => lying_number,
        ),
    )
    scalar_mutating_plot =
        Plot(AbstractTrace[scalar_mutating], Layout())
    @test extendtraces!(
        scalar_mutating_plot,
        Dict(:y => [[3]]),
        [1],
    ) === scalar_mutating_plot
    @test scalar_mutating_plot.data[1] !== scalar_mutating
    @test scalar_mutating_plot.data[1].fields[:token].state == 1
    @test lying_number.state == 0

    lying_bits = _TransactionLyingBits(0)
    bits_mutating = _TransactionScalarMutatingTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :token => lying_bits,
        ),
    )
    bits_mutating_plot =
        Plot(AbstractTrace[bits_mutating], Layout())
    @test extendtraces!(
        bits_mutating_plot,
        Dict(:y => [[3]]),
        [1],
    ) === bits_mutating_plot
    @test bits_mutating_plot.data[1] !== bits_mutating
    @test bits_mutating_plot.data[1].fields[:token].state == 1
    @test lying_bits.state == 0

    id_trace = GenericTrace(
        IdDict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
        ),
    )
    id_trace_plot = Plot(AbstractTrace[id_trace], Layout())
    @test extendtraces!(
        id_trace_plot,
        Dict(:y => [[3]]),
        [1],
    ) === id_trace_plot
    @test id_trace_plot.data[1] === id_trace
    @test id_trace_plot.data[1].fields isa IdDict{Symbol,Any}
    @test id_trace_plot.data[1][:y] == [1, 2, 3]

    id_layout = Layout(
        IdDict{Symbol,Any}(:title => "id-layout"),
    )
    id_layout_plot =
        Plot(AbstractTrace[scatter(y=[1, 2])], id_layout)
    @test update_geos!(
        id_layout_plot;
        bgcolor="id-layout-blue",
    ) === id_layout_plot
    @test id_layout_plot.layout === id_layout
    @test id_layout_plot.layout.fields isa IdDict{Symbol,Any}
    @test id_layout_plot.layout.fields[:geo][:bgcolor] ==
          "id-layout-blue"

    for dict_type in (Dict{Symbol,Any}, IdDict{Symbol,Any})
        trace_fields = dict_type()
        cyclic_trace = GenericTrace(trace_fields)
        trace_fields[:type] = "scatter"
        trace_fields[:y] = [1, 2]
        trace_fields[:self] = cyclic_trace
        cyclic_trace_plot =
            Plot(AbstractTrace[cyclic_trace], Layout())
        @test extendtraces!(
            cyclic_trace_plot,
            Dict(:y => [[3]]),
            [1],
        ) === cyclic_trace_plot
        @test cyclic_trace_plot.data[1] === cyclic_trace
        @test cyclic_trace.fields[:self] === cyclic_trace

        cyclic_layout = Layout(dict_type())
        cyclic_layout.fields[:self] = cyclic_layout
        cyclic_layout_plot = Plot(
            AbstractTrace[scatter(y=[1, 2])],
            cyclic_layout,
        )
        @test update_geos!(
            cyclic_layout_plot;
            bgcolor="cycle-blue",
        ) === cyclic_layout_plot
        @test cyclic_layout_plot.layout === cyclic_layout
        @test cyclic_layout.fields[:self] === cyclic_layout
    end

    self_attribute = attr()
    self_attribute.fields[:self] = self_attribute
    self_clone = PlotlySupply._copy_mutation_container(
        self_attribute,
    )
    @test self_clone !== self_attribute
    @test self_clone.fields[:self] === self_clone
    setter_clone = PlotlySupply._copy_setter_input(
        self_attribute,
        IdDict{Any,Any}(),
    )
    @test setter_clone !== self_attribute
    @test setter_clone.fields[:self] === setter_clone

    valid_frame = frame(name="cycle-clone-frame")
    frame_clone = @test_logs(
        PlotlySupply._copy_mutation_container(valid_frame)
    )
    frame_setter_clone = @test_logs(
        PlotlySupply._copy_setter_input(
            valid_frame,
            IdDict{Any,Any}(),
        )
    )
    @test frame_clone.fields[:name] == "cycle-clone-frame"
    @test frame_setter_clone.fields[:name] ==
          "cycle-clone-frame"

    left_attribute = attr()
    right_attribute = attr()
    left_attribute.fields[:right] = right_attribute
    right_attribute.fields[:left] = left_attribute
    left_clone = PlotlySupply._copy_mutation_container(
        left_attribute,
    )
    @test left_clone !== left_attribute
    @test left_clone.fields[:right] !== right_attribute
    @test left_clone.fields[:right].fields[:left] ===
          left_clone

    map_root = attr()
    cyclic_style = Dict{Symbol,Any}(:owner => map_root)
    map_root.fields[:style] = cyclic_style
    cyclic_map_layout = Layout()
    cyclic_map_layout.fields[:map] = map_root
    cyclic_map_plot = Plot(
        scattermap(lon=[0.0], lat=[0.0]),
        cyclic_map_layout,
    )
    @test plot_scattermap!(
        cyclic_map_plot,
        [1.0],
        [1.0];
        zoom=2,
    ) === nothing
    committed_map = cyclic_map_plot.layout.fields[:map]
    @test committed_map.fields[:style][:owner] ===
          committed_map
    @test committed_map.fields[:zoom] == 2

    first = scatter(y=[1, 2])
    second = scatter(y=[4, 5])
    first.fields[:other] = second
    second.fields[:other] =
        _TransactionAliasWrapper(
            _TransactionAliasWrapper(first),
        )
    root_cycle_plot = Plot([first, second], Layout())
    @test extendtraces!(
        root_cycle_plot,
        Dict(:y => [[3]]),
        [1],
    ) === root_cycle_plot
    @test root_cycle_plot.data[1] === first
    @test root_cycle_plot.data[2] === second
    @test first.fields[:other] === second
    @test second.fields[:other].child.child === first

    wrapped_layout = Layout()
    wrapped_trace = scatter(y=[1, 2])
    wrapped_trace.fields[:layout] = wrapped_layout
    wrapped_layout.fields[:trace] =
        _TransactionMutableAliasWrapper(wrapped_trace)
    wrapped_root_plot =
        Plot(AbstractTrace[wrapped_trace], wrapped_layout)
    @test extendtraces!(
        wrapped_root_plot,
        Dict(:y => [[3]]),
        [1],
    ) === wrapped_root_plot
    @test wrapped_root_plot.data[1] === wrapped_trace
    @test wrapped_root_plot.layout === wrapped_layout
    @test wrapped_trace.fields[:layout] === wrapped_layout
    @test wrapped_layout.fields[:trace].child === wrapped_trace

    shared_ref = Ref(19)
    shared_wrapper = _TransactionAliasWrapper(shared_ref)
    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :wrapper => shared_wrapper,
        ),
    )
    generic = scatter(y=[4, 5])
    generic.fields[:wrapper] = shared_wrapper
    wrapper_alias_plot =
        Plot(AbstractTrace[custom, generic], Layout())
    @test extendtraces!(
        wrapper_alias_plot,
        Dict(:y => [[3]]),
        [1],
    ) === wrapper_alias_plot
    @test wrapper_alias_plot.data[1] !== custom
    @test wrapper_alias_plot.data[2] !== generic
    @test wrapper_alias_plot.data[1].fields[:wrapper] ===
          wrapper_alias_plot.data[2].fields[:wrapper]
    @test wrapper_alias_plot.data[1].fields[:wrapper].child ===
          wrapper_alias_plot.data[2].fields[:wrapper].child

    for shared_map in (
        Dict{Any,Any}(Ref(1) => "value"),
        IdDict{Any,Any}(Ref(1) => "value"),
    )
        custom = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1, 2],
                :shared => shared_map,
            ),
        )
        generic = scatter(y=[4, 5])
        generic.fields[:shared] = shared_map
        keyed_alias_plot =
            Plot(AbstractTrace[custom, generic], Layout())
        @test extendtraces!(
            keyed_alias_plot,
            Dict(:y => [[6]]),
            [2],
        ) === keyed_alias_plot
        @test keyed_alias_plot.data[1] === custom
        @test keyed_alias_plot.data[2] === generic
        @test custom.fields[:shared] === generic.fields[:shared]
        @test generic.fields[:shared] === shared_map
    end

    shared_key = Ref(7)
    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :keyed => IdDict{Any,Any}(
                shared_key => :custom,
            ),
        ),
    )
    generic = scatter(y=[4, 5])
    generic.fields[:keyed] =
        IdDict{Any,Any}(shared_key => :generic)
    separate_key_plot =
        Plot(AbstractTrace[custom, generic], Layout())
    @test extendtraces!(
        separate_key_plot,
        Dict(:y => [[3]]),
        [1],
    ) === separate_key_plot
    custom_key = only(keys(
        separate_key_plot.data[1].fields[:keyed],
    ))
    generic_key = only(keys(
        separate_key_plot.data[2].fields[:keyed],
    ))
    @test custom_key === generic_key
    @test custom_key[] == 7

    side_effect_fields = _TransactionSideEffectDict(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
        ),
        :unchanged,
    )
    side_effect_trace = GenericTrace(side_effect_fields)
    side_effect_plot =
        Plot(AbstractTrace[side_effect_trace], Layout())
    @test extendtraces!(
        side_effect_plot,
        Dict(:y => [[3]]),
        [1],
    ) === side_effect_plot
    @test side_effect_plot.data[1] === side_effect_trace
    @test side_effect_trace.fields.tag == :changed
    @test side_effect_trace[:y] == [1, 2]

    for mode in (:raw, :direct, :registered)
        locked = _TransactionLockedTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [7, 8],
            ),
            ReentrantLock(),
        )
        generic = scatter(y=[1, 2])
        opaque_plot =
            Plot(AbstractTrace[locked, generic], Layout())
        state = _TransactionRendererState()
        sp = SyncPlot(
            opaque_plot,
            nothing,
            Symbol(mode, :_opaque_window),
            string(mode, "-opaque-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        mode === :registered &&
            PlotlySupply._register_displayed_syncplot!(
                opaque_plot,
                sp,
            )
        target = mode === :direct ? sp : opaque_plot
        try
            @test extendtraces!(
                target,
                Dict(:y => [[3]]),
                [2],
            ) === target
            @test opaque_plot.data[1] === locked
            @test update_geos!(
                target;
                bgcolor="opaque-blue",
            ) === target
            @test opaque_plot.data[1] === locked
            @test length(state.scripts) ==
                  (mode === :raw ? 0 : 2)
        finally
            close(sp)
        end
    end

    holes = Vector{Any}(undef, 3)
    holes[2] = "assigned"
    hole_trace = scatter(y=[1, 2])
    hole_trace.fields[:holes] = holes
    hole_plot = Plot([hole_trace], Layout())
    @test extendtraces!(
        hole_plot,
        Dict(:y => [[3]]),
        [1],
    ) === hole_plot
    @test hole_trace[:y] == [1, 2, 3]
    @test hole_trace.fields[:holes] === holes
    @test !isassigned(holes, 1)
    @test holes[2] == "assigned"
    @test !isassigned(holes, 3)

    mutable_holes = Vector{Any}(undef, 3)
    mutable_holes[2] = Dict(:assigned => true)
    mutable_hole_trace = scatter(y=[1, 2])
    mutable_hole_trace.fields[:holes] = mutable_holes
    mutable_hole_plot = Plot([mutable_hole_trace], Layout())
    @test extendtraces!(
        mutable_hole_plot,
        Dict(:y => [[3]]),
        [1],
    ) === mutable_hole_plot
    @test mutable_hole_trace[:y] == [1, 2, 3]
    @test mutable_hole_trace.fields[:holes] === mutable_holes
    @test !isassigned(mutable_holes, 1)
    @test mutable_holes[2] ===
          mutable_hole_trace.fields[:holes][2]
    @test mutable_holes[2] == Dict(:assigned => true)
    @test !isassigned(mutable_holes, 3)

    for model_field in (:data, :frames, :config)
        custom = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1, 2],
            ),
        )
        model_alias_plot =
            Plot(AbstractTrace[custom], Layout())
        original_model_root =
            getfield(model_alias_plot, model_field)
        custom.fields[:shared_model_root] =
            original_model_root
        @test extendtraces!(
            model_alias_plot,
            Dict(:y => [[3]]),
            [1],
        ) === model_alias_plot
        @test model_alias_plot.data[1] !== custom
        @test getfield(model_alias_plot, model_field) !==
              original_model_root
        @test getfield(
            model_alias_plot.data[1],
            :fields,
        )[:shared_model_root] ===
              getfield(model_alias_plot, model_field)
        @test model_alias_plot.data[1][:y] == [1, 2, 3]
    end

    generic = scatter(y=[7, 8], name="generic-root")
    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :other => generic,
        ),
    )
    trace_root_plot =
        Plot(AbstractTrace[custom, generic], Layout())
    @test extendtraces!(
        trace_root_plot,
        Dict(:y => [[3]]),
        [1],
    ) === trace_root_plot
    @test trace_root_plot.data[1] !== custom
    @test trace_root_plot.data[2] !== generic
    @test trace_root_plot.data[1].fields[:other] ===
          trace_root_plot.data[2]

    shared_values = [10, 20]
    generic = scatter(y=[7, 8], name="generic-numeric-alias")
    generic.fields[:shared] = shared_values
    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :shared => shared_values,
        ),
    )
    numeric_alias_plot =
        Plot(AbstractTrace[generic, custom], Layout())
    @test extendtraces!(
        numeric_alias_plot,
        Dict(:y => [[3]]),
        [2],
    ) === numeric_alias_plot
    @test numeric_alias_plot.data[1] !== generic
    @test numeric_alias_plot.data[2] !== custom
    @test numeric_alias_plot.data[1].fields[:shared] ===
          numeric_alias_plot.data[2].fields[:shared]

    layout_root = Layout()
    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
            :other => layout_root,
        ),
    )
    layout_root_plot = Plot(AbstractTrace[custom], layout_root)
    @test extendtraces!(
        layout_root_plot,
        Dict(:y => [[3]]),
        [1],
    ) === layout_root_plot
    @test layout_root_plot.data[1] !== custom
    @test layout_root_plot.layout !== layout_root
    @test layout_root_plot.data[1].fields[:other] ===
          layout_root_plot.layout
end

@testset "custom field dictionaries stage without touching originals" begin
    fields = _TransactionSelfCopyDict(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [1, 2],
        ),
    )
    trace = GenericTrace(fields)
    p = Plot(AbstractTrace[trace], Layout())
    state = _TransactionRendererState(
        Any[ErrorException("self-copy-render-failure"), "ok"],
    )
    sp = SyncPlot(
        p,
        nothing,
        :self_copy_dict_window,
        "self-copy-dict-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    original_y = trace[:y]
    caught = try
        extendtraces!(sp, Dict(:y => [[3]]), [1])
        nothing
    catch err
        err
    end
    try
        @test caught isa ErrorException
        @test occursin(
            "self-copy-render-failure",
            sprint(showerror, caught),
        )
        @test p.data[1] === trace
        @test trace.fields === fields
        @test trace[:y] === original_y
        @test trace[:y] == [1, 2]
        @test length(state.scripts) == 2
        @test occursin("Plotly.react", state.scripts[1])
        @test occursin("Plotly.newPlot", state.scripts[2])
    finally
        close(sp)
    end

    shared_marker = Dict{Symbol,Any}(:size => 10)
    first = scatter(y=[1])
    second = scatter(y=[2])
    first.fields[:marker] = shared_marker
    marker_holes = Vector{Any}(undef, 3)
    marker_holes[2] = shared_marker
    second.fields[:customdata] = marker_holes
    p = Plot([first, second])
    @test restyle!(p, 1; marker_size=20) === p
    @test p.data[1].fields[:marker] ===
          p.data[2].fields[:customdata][2]
    @test p.data[1].fields[:marker][:size] == 20
    @test !isassigned(p.data[2].fields[:customdata], 1)
    @test !isassigned(p.data[2].fields[:customdata], 3)
end

function _subplot_transaction_fixture(;
    registered::Bool=false,
    outcomes=Any[],
)
    layout = Layout(Subplots(rows=1, cols=1))
    p = Plot(GenericTrace[], layout)
    add_trace!(
        p,
        scatter(x=[1, 2], y=[3, 4], name="subplot-old");
        row=1,
        col=1,
    )
    relayout!(p; title="subplot-old-title")
    state = _TransactionRendererState(outcomes)
    sp = SyncPlot(
        p,
        nothing,
        :subplot_transaction_window,
        "subplot-transaction-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    registered &&
        PlotlySupply._register_displayed_syncplot!(p, sp)
    fig = registered ? p : sp
    sf = SubplotFigure(
        fig,
        1,
        1,
        1,
        1,
        true,
        :topright,
        (0.02, 0.03),
        "white",
        "black",
        1.0,
    )
    return p, sp, sf, state
end

function _subplot_metadata_snapshot(sf::SubplotFigure)
    return (
        sf.current_row,
        sf.current_col,
        sf.per_subplot_legends,
        sf.legend_position,
        sf.legend_inset,
        sf.legend_bgcolor,
        sf.legend_bordercolor,
        sf.legend_borderwidth,
    )
end

function _apply_subplot_transaction_operation!(
    sf::SubplotFigure,
    operation::Symbol,
)
    if operation === :addtraces
        return addtraces!(
            sf,
            scatter(x=[5, 6], y=[7, 8], name="subplot-added"),
        )
    elseif operation === :plot_scatter
        return plot_scatter!(
            sf,
            [5, 6],
            [7, 8];
            legend="subplot-high-level",
        )
    elseif operation === :xlabel
        return xlabel!(sf, "candidate-x-label")
    elseif operation === :set_legend
        return set_legend!(
            sf;
            position=:bottom,
            borderwidth=3,
        )
    end
    error("unsupported subplot transaction operation: $operation")
end

@testset "subplot composites roll back model and metadata together" begin
    operations = (
        :addtraces,
        :plot_scatter,
        :xlabel,
        :set_legend,
    )
    for registered in (false, true), operation in operations
        primary = ErrorException(
            "injected-$registered-$operation-subplot-failure",
        )
        p, sp, sf, state = _subplot_transaction_fixture(
            ;
            registered=registered,
            outcomes=Any[primary, "ok"],
        )
        snapshot = _transaction_snapshot(p)
        metadata = _subplot_metadata_snapshot(sf)
        try
            caught = try
                _apply_subplot_transaction_operation!(sf, operation)
                nothing
            catch err
                err
            end
            @test caught === primary
            _test_transaction_snapshot(p, snapshot)
            @test _subplot_metadata_snapshot(sf) == metadata
            @test length(state.scripts) == 2
            @test occursin("Plotly.react", state.scripts[1])
            @test occursin("Plotly.newPlot", state.scripts[2])
            @test occursin("subplot-old-title", state.scripts[2])
            @test !sp._resources.renderer_desynchronized
        finally
            close(sp)
        end
    end
end

@testset "purge commits only after its renderer command" begin
    for registered in (false, true)
        primary = ErrorException(
            "injected-$registered-purge-renderer-failure",
        )
        p, sp, state = _transaction_fixture(
            ;
            register=registered,
            outcomes=Any[primary, "ok"],
        )
        target = registered ? p : sp
        snapshot = _transaction_snapshot(p)
        try
            caught = try
                purge!(target)
                nothing
            catch err
                err
            end
            @test caught === primary
            _test_transaction_snapshot(p, snapshot)
            @test length(state.scripts) == 2
            @test occursin("Plotly.purge(div);", state.scripts[1])
            @test occursin("Plotly.newPlot", state.scripts[2])
            @test !sp._resources.renderer_desynchronized
        finally
            close(sp)
        end
    end

    p, sp, state = _transaction_fixture()
    try
        @test purge!(sp) === sp
        @test isempty(p.data)
        @test p.layout == Layout()
        @test length(state.scripts) == 1
        @test occursin("Plotly.purge(div);", only(state.scripts))
    finally
        close(sp)
    end

    parent_data = GenericTrace[scatter(y=[1, 2])]
    viewed_data = @view parent_data[:]
    unsupported = Plot(
        viewed_data,
        Layout(title="view-backed"),
    )
    state = _TransactionRendererState()
    sp = SyncPlot(
        unsupported,
        nothing,
        :view_backed_window,
        "view-backed-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    snapshot = _transaction_snapshot(unsupported)
    try
        @test_throws ArgumentError purge!(sp)
        @test isempty(state.scripts)
        _test_transaction_snapshot(unsupported, snapshot)
        @test !sp._resources.renderer_desynchronized
    finally
        close(sp)
    end
end

@testset "failed recovery marks desync and next mutation repairs it" begin
    primary = ErrorException("injected-primary-renderer-failure")
    recovery = ErrorException("injected-renderer-recovery-failure")
    p, sp, state = _transaction_fixture(
        ;
        outcomes=Any[primary, recovery],
    )
    snapshot = _transaction_snapshot(p)
    try
        caught = try
            relayout!(sp; title="uncommitted-title")
            nothing
        catch err
            err
        end
        @test caught isa PlotlySupply._SyncPlotDesynchronizationError
        @test caught.operation_error === primary
        @test caught.recovery_error === recovery
        @test sp._resources.renderer_desynchronized
        _test_transaction_snapshot(p, snapshot)
        @test length(state.scripts) == 2

        append!(state.outcomes, Any["ok", "ok"])
        @test relayout!(sp; title="repaired-title") === sp
        @test p.layout.fields[:title] == "repaired-title"
        @test !sp._resources.renderer_desynchronized
        @test length(state.scripts) == 4
        @test occursin("Plotly.newPlot", state.scripts[3])
        @test occursin("old-transaction-title", state.scripts[3])
        @test occursin("Plotly.relayout", state.scripts[4])
    finally
        close(sp)
    end
end

@testset "post-render interruption forces synchronization recovery" begin
    p, sp, state = _transaction_fixture()
    resources = sp._resources
    prepare = function (target, current)
        script = PlotlySupply._plotlyjs_relayout_script(
            target,
            Dict("title" => "interrupted-after-render"),
        )
        commit = () -> throw(InterruptException())
        return (
            script=script,
            operation="relayout",
            commit=commit,
        )
    end
    caught = try
        PlotlySupply._syncplot_transaction!(sp, prepare)
        nothing
    catch err
        err
    end
    @test caught isa InterruptException
    @test p.layout.fields[:title] == "old-transaction-title"
    @test resources.renderer_desynchronized
    @test length(state.scripts) == 1

    @test relayout!(sp; title="after-interrupt-repair") === sp
    @test !resources.renderer_desynchronized
    @test p.layout.fields[:title] == "after-interrupt-repair"
    @test length(state.scripts) == 3
    @test occursin("Plotly.newPlot", state.scripts[2])
    @test occursin("old-transaction-title", state.scripts[2])
    @test occursin("Plotly.relayout", state.scripts[3])
    close(sp)
end

struct _TransactionJSONFailure end

PlotlyBase.JSON.lower(::_TransactionJSONFailure) =
    error("injected transaction JSON failure")

@testset "preflight and serialization failures never touch renderer" begin
    p, sp, state = _transaction_fixture()
    snapshot = _transaction_snapshot(p)
    try
        caught = try
            relayout!(sp; title=_TransactionJSONFailure())
            nothing
        catch err
            err
        end
        @test caught isa ErrorException
        @test occursin(
            "injected transaction JSON failure",
            sprint(showerror, caught),
        )
        @test isempty(state.scripts)
        @test !sp._resources.renderer_desynchronized
        _test_transaction_snapshot(p, snapshot)
    finally
        close(sp)
    end

    p, sp, state = _transaction_fixture()
    snapshot = _transaction_snapshot(p)
    try
        @test_throws BoundsError deletetraces!(sp, 3)
        @test_throws Exception deletetraces!(sp, 1, 1)
        @test_throws DimensionMismatch movetraces!(
            sp,
            [1],
            [1, 2],
        )
        @test_throws BoundsError movetraces!(sp, [3], [1])
        @test_throws BoundsError addtraces!(
            sp,
            4,
            scatter(y=[1]),
        )
        @test isempty(state.scripts)
        @test !sp._resources.renderer_desynchronized
        _test_transaction_snapshot(p, snapshot)
    finally
        close(sp)
    end

    p, sp, state = _transaction_fixture()
    state.open = false
    snapshot = _transaction_snapshot(p)
    try
        @test_throws InvalidStateException relayout!(
            sp;
            title="closed-candidate",
        )
        @test isempty(state.scripts)
        @test !sp._resources.renderer_desynchronized
        _test_transaction_snapshot(p, snapshot)
    finally
        close(sp)
    end
end

@testset "react conversion and model replacement commit only after render" begin
    for registered in (false, true)
        p, sp, state = _transaction_fixture(; register=registered)
        target = registered ? p : sp
        try
            exact_data = copy(p.data)
            exact_layout = Layout(title="exact-react-layout")
            @test react!(target, exact_data, exact_layout) === target
            @test p.data === exact_data
            @test p.layout === exact_layout

            abstract_data = AbstractTrace[
                scatter(y=[31, 32, 33]),
                scatter(y=[41, 42, 43]),
            ]
            next_layout = Layout(title="converted-react-layout")
            @test react!(target, abstract_data, next_layout) === target
            @test p.data !== abstract_data
            @test p.data == abstract_data
            @test p.layout === next_layout

            incompatible_layout =
                Layout(IdDict{Symbol,Any}(:title => "incompatible"))
            snapshot = _transaction_snapshot(p)
            call_count = length(state.scripts)
            @test_throws MethodError react!(
                target,
                copy(p.data),
                incompatible_layout,
            )
            @test length(state.scripts) == call_count
            _test_transaction_snapshot(p, snapshot)
        finally
            close(sp)
        end
    end

    old, sp, state = _transaction_fixture(; register=true)
    replacement =
        Plot(scatter(y=[91, 92]), Layout(title="replacement-model"))
    try
        @test react!(sp, replacement) === sp
        @test sp.plot === replacement
        @test !haskey(PlotlySupply._PLOT_SYNCPLOT_MAP, old)
        @test PlotlySupply._PLOT_SYNCPLOT_MAP[replacement] === sp
        @test occursin("Plotly.newPlot", only(state.scripts))
        @test occursin("replacement-model", only(state.scripts))
    finally
        close(sp)
    end

    primary = ErrorException("injected-model-replacement-failure")
    old, sp, state = _transaction_fixture(
        ;
        register=true,
        outcomes=Any[primary, "ok"],
    )
    replacement =
        Plot(scatter(y=[101, 102]), Layout(title="uncommitted-model"))
    try
        caught = try
            react!(sp, replacement)
            nothing
        catch err
            err
        end
        @test caught === primary
        @test sp.plot === old
        @test PlotlySupply._PLOT_SYNCPLOT_MAP[old] === sp
        @test !haskey(PlotlySupply._PLOT_SYNCPLOT_MAP, replacement)
        @test occursin("old-transaction-title", state.scripts[2])
        @test !occursin("uncommitted-model", state.scripts[2])
    finally
        close(sp)
    end
end

@testset "shared nested aliases and large payloads stay efficient" begin
    state = _TransactionRendererState()
    payload = collect(1:1_000_000)
    shared_marker = Dict{Symbol,Any}(:color => payload)
    first_trace = scatter(y=[1, 2, 3])
    second_trace = scatter(y=[4, 5, 6])
    first_trace.fields[:marker] = shared_marker
    second_trace.fields[:marker] = shared_marker
    p = Plot([first_trace, second_trace])
    sp = SyncPlot(
        p,
        nothing,
        :allocation_window,
        "allocation-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        restyle!(sp, 1; marker_size=8)
        @test p.data[1].fields[:marker] ===
              p.data[2].fields[:marker]
        @test p.data[2].fields[:marker][:size] == 8
        @test p.data[1].fields[:marker][:color] === payload
        script = only(state.scripts)
        @test occursin("Plotly.restyle", script)
        @test occursin("[0,1]", script)
        @test !occursin("1,2,3,4,5,6,7,8,9,10", script)
        @test sizeof(script) < 2_000

        empty!(state.scripts)
        GC.gc()
        allocated = @allocated restyle!(sp, 1; marker_size=9)
        @test allocated < 1_000_000
        @test sizeof(only(state.scripts)) < 2_000
        @test p.data[1].fields[:marker][:color] === payload
    finally
        close(sp)
    end
end

@testset "associative attributes remain atomic renderer values" begin
    original = Dict{Symbol,Any}(
        :labelalias => Dict("a.b" => "old"),
        :geojson => Dict(
            "type" => "Feature",
            "properties" => Dict("dotted.key" => "old"),
        ),
        :meta => Dict("a.b" => "old"),
    )
    staged = deepcopy(original)
    staged[:labelalias]["a.b"] = "new"
    staged[:geojson]["properties"]["dotted.key"] = "new"
    staged[:meta]["a.b"] = "new"
    deltas = PlotlySupply._plotly_leaf_deltas(original, staged)
    @test Set(keys(deltas)) == Set(["labelalias", "geojson", "meta"])
    @test deltas["labelalias"] === staged[:labelalias]
    @test deltas["geojson"] === staged[:geojson]
    @test deltas["meta"] === staged[:meta]
    @test !haskey(deltas, "labelalias.a.b")
    @test !haskey(deltas, "geojson.properties.dotted.key")
    @test !haskey(deltas, "meta.a.b")

    state = _TransactionRendererState()
    trace = scatter(y=[1])
    trace.fields[:labelalias] = original[:labelalias]
    p = Plot(trace)
    sp = SyncPlot(
        p,
        nothing,
        :atomic_dict_window,
        "atomic-dict-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        restyle!(
            sp,
            1,
            Dict(:labelalias => Dict("a.b" => "renderer-new")),
        )
        script = only(state.scripts)
        @test occursin("\"labelalias\"", script)
        @test occursin("\"a.b\":\"renderer-new\"", script)
        @test !occursin("labelalias.a.b", script)

        empty!(state.scripts)
        p.data[1].fields[:meta] =
            Dict{Symbol,Any}(Symbol("a.b") => "old")
        restyle!(
            sp,
            1;
            meta=Dict{Symbol,Any}(Symbol("a.b") => "renderer-new"),
        )
        script = only(state.scripts)
        @test occursin("\"meta\"", script)
        @test occursin("\"a.b\":\"renderer-new\"", script)
        @test !occursin("meta.a.b", script)
    finally
        close(sp)
    end
end

@testset "single-trace staging does not clone unrelated trace metadata" begin
    trace_count = 20_000
    p = Plot([
        scatter(y=[ind], name="trace-$ind")
        for ind in 1:trace_count
    ])
    memo = IdDict{Any,Any}()
    staged = PlotlySupply._stage_restyle(
        p,
        (1,),
        Dict(),
        pairs((; marker_size=3));
        vectorized=false,
        memo=memo,
    )
    @test length(staged) == 1
    @test haskey(staged, p.data[1])
    @test all(
        !haskey(staged, p.data[ind])
        for ind in 2:trace_count
    )

    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :many_trace_window,
        "many-trace-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        restyle!(sp, 1; marker_size=4)
        restyle!(sp, 1; marker_size=5)
        empty!(state.scripts)
        GC.gc()
        if Base.JLOptions().compile_enabled == 1
            allocated = @allocated restyle!(sp, 1; marker_size=6)
            @test allocated < 2_000_000
        else
            @test_skip "allocation accounting requires normal compilation"
            restyle!(sp, 1; marker_size=6)
        end
        @test length(state.scripts) == 1
        @test sizeof(only(state.scripts)) < 2_000
    finally
        close(sp)
    end
end

@testset "layout and trace aliases remain one staged graph" begin
    state = _TransactionRendererState()
    shared_font = Dict{Symbol,Any}(:size => 10)
    trace = scatter(y=[1, 2, 3], mode="text", text=["a", "b", "c"])
    trace.fields[:textfont] = shared_font
    layout = Layout()
    layout.fields[:font] = shared_font
    p = Plot(trace, layout)
    sp = SyncPlot(
        p,
        nothing,
        :cross_alias_window,
        "cross-alias-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test relayout!(sp; font_size=20) === sp
        @test p.layout.fields[:font] === p.data[1].fields[:textfont]
        @test p.layout.fields[:font][:size] == 20
        @test p.data[1].fields[:textfont][:size] == 20
        @test occursin("Plotly.update", only(state.scripts))
        @test occursin("font.size", only(state.scripts))
        @test occursin("textfont.size", only(state.scripts))

        empty!(state.scripts)
        @test restyle!(sp, 1; textfont_size=30) === sp
        @test p.layout.fields[:font] === p.data[1].fields[:textfont]
        @test p.layout.fields[:font][:size] == 30
        @test p.data[1].fields[:textfont][:size] == 30
        @test occursin("Plotly.update", only(state.scripts))
        @test occursin("font.size", only(state.scripts))
        @test occursin("textfont.size", only(state.scripts))
    finally
        close(sp)
    end

    shared_font = Dict{Symbol,Any}(:size => 10)
    trace = scatter(y=[1], mode="text", text=["a"])
    trace.fields[:textfont] = shared_font
    layout = Layout()
    layout.fields[:font] = shared_font
    raw = Plot(trace, layout)
    @test relayout!(raw; font_size=40) === raw
    @test raw.layout.fields[:font] === raw.data[1].fields[:textfont]
    @test raw.data[1].fields[:textfont][:size] == 40
    @test restyle!(raw, 1; textfont_size=50) === raw
    @test raw.layout.fields[:font] === raw.data[1].fields[:textfont]
    @test raw.layout.fields[:font][:size] == 50
end

@testset "aliases through roots and arrays remain one staged graph" begin
    state = _TransactionRendererState()
    layout = Layout(title="old")
    trace = scatter(y=[1])
    trace.fields[:meta] = layout.fields
    p = Plot(trace, layout)
    sp = SyncPlot(
        p,
        nothing,
        :root_nested_alias_window,
        "root-nested-alias-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test relayout!(sp; title="new") === sp
        @test p.layout.fields === p.data[1].fields[:meta]
        @test p.data[1].fields[:meta][:title] == "new"
        script = only(state.scripts)
        @test occursin("Plotly.update", script)
        @test occursin("\"meta\"", script)
    finally
        close(sp)
    end

    state = _TransactionRendererState()
    shared_marker = Dict{Symbol,Any}(:size => 10)
    trace = scatter(y=[1])
    trace.fields[:marker] = shared_marker
    trace.fields[:customdata] = Any[shared_marker]
    p = Plot(trace)
    sp = SyncPlot(
        p,
        nothing,
        :same_root_array_alias_window,
        "same-root-array-alias-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test restyle!(sp, 1; marker_size=20) === sp
        @test p.data[1].fields[:marker] ===
              p.data[1].fields[:customdata][1]
        @test p.data[1].fields[:customdata][1][:size] == 20
        script = only(state.scripts)
        @test occursin("\"marker.size\"", script)
        @test occursin("\"customdata\"", script)
    finally
        close(sp)
    end

    state = _TransactionRendererState()
    shared_marker = Dict{Symbol,Any}(:size => 10)
    first = scatter(y=[1])
    second = scatter(y=[2])
    first.fields[:marker] = shared_marker
    second.fields[:customdata] = Any[shared_marker]
    p = Plot([first, second])
    sp = SyncPlot(
        p,
        nothing,
        :cross_root_array_alias_window,
        "cross-root-array-alias-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test restyle!(sp, 1; marker_size=30) === sp
        @test p.data[1].fields[:marker] ===
              p.data[2].fields[:customdata][1]
        @test p.data[2].fields[:customdata][1][:size] == 30
        script = only(state.scripts)
        @test occursin("\"marker.size\"", script)
        @test occursin("\"customdata\"", script)
        @test occursin("[1]", script)
    finally
        close(sp)
    end
end

@testset "incremental alias expansion covers custom graph nodes" begin
    for mode in (:raw, :direct)
        shared = Dict{Symbol,Any}(:size => 10)
        trace = scatter(y=[1])
        trace.fields[:marker] = shared
        config = PlotConfig(
            toImageButtonOptions=
                Dict{Symbol,Any}(:shared => shared),
        )
        p = Plot(
            [trace],
            Layout(),
            [
                frame(
                    Dict{Symbol,Any}(
                        :name => "shared-marker-frame",
                        :shared => shared,
                    ),
                ),
            ];
            config=config,
        )
        original_frames = p.frames
        original_config = p.config
        state = _TransactionRendererState()
        sp = SyncPlot(
            p,
            nothing,
            Symbol(mode, :_outer_alias_window),
            string(mode, "-outer-alias-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        target = mode === :raw ? p : sp
        try
            @test restyle!(
                target,
                1;
                marker_size=20,
            ) === target
            @test p.frames === original_frames
            @test p.config === original_config
            @test p.data[1].fields[:marker] ===
                  p.frames[1].fields[:shared]
            @test p.data[1].fields[:marker] ===
                  p.config.toImageButtonOptions[:shared]
            @test p.data[1].fields[:marker][:size] == 20
            if mode === :direct
                @test occursin(
                    "Plotly.newPlot",
                    only(state.scripts),
                )
                @test occursin(
                    "Plotly.addFrames",
                    only(state.scripts),
                )
            else
                @test isempty(state.scripts)
            end
        finally
            close(sp)
        end
    end

    for model_field in (:data, :layout, :frames, :config)
        custom = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1],
            ),
        )
        p = Plot(
            AbstractTrace[custom],
            Layout(),
            PlotlyFrame[],
        )
        original_model_root = getfield(p, model_field)
        custom.fields[:shared_model_root] =
            original_model_root
        @test restyle!(
            p,
            1;
            name="changed",
        ) === p
        @test getfield(p, model_field) ===
              original_model_root
        @test p.data[1] !== custom
        @test p.data[1].fields[:shared_model_root] ===
              getfield(p, model_field)
        @test p.data[1][:name] == "changed"
    end

    shared = Dict{Symbol,Any}(:size => 10)
    generic = scatter(y=[1])
    generic.fields[:marker] = shared
    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :y => [2],
            :meta => shared,
        ),
    )
    p = Plot(AbstractTrace[generic, custom], Layout())
    @test restyle!(p, 1; marker_size=20) === p
    @test p.data[1] === generic
    @test p.data[2] !== custom
    @test p.data[1].fields[:marker] ===
          p.data[2].fields[:meta]
    @test p.data[2].fields[:meta][:size] == 20

    for path in (:direct, :wrapper, :array, :simplevector)
        shared_node = _TransactionSharedNode(10)
        holder = if path === :direct
            shared_node
        elseif path === :wrapper
            _TransactionAliasWrapper(shared_node)
        elseif path === :simplevector
            Core.svec(shared_node)
        else
            Any[shared_node]
        end
        first = _TransactionNodeMutatingTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [1],
                :holder => holder,
            ),
            path,
        )
        second = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :y => [2],
                :node => shared_node,
            ),
        )
        p = Plot(AbstractTrace[first, second], Layout())
        @test restyle!(
            p,
            1;
            node_value=20,
        ) === p
        first_node = if path === :direct
            p.data[1].fields[:holder]
        elseif path === :wrapper
            p.data[1].fields[:holder].child
        else
            p.data[1].fields[:holder][1]
        end
        @test p.data[1] !== first
        @test p.data[2] !== second
        @test first_node === p.data[2].fields[:node]
        @test first_node.value == 20
        @test shared_node.value == 10
    end

    shared = Dict{Symbol,Any}(:size => 10)
    first = scatter(y=[1])
    second = scatter(y=[2])
    first.fields[:marker] = shared
    second.fields[:meta] = _TransactionAliasWrapper(shared)
    p = Plot([first, second])
    @test restyle!(p, 1; marker_size=30) === p
    @test p.data[1].fields[:marker] ===
          p.data[2].fields[:meta].child
    @test p.data[2].fields[:meta].child[:size] == 30

    shared = Dict{Symbol,Any}(:size => 10)
    first = scatter(y=[1])
    second = scatter(y=[2])
    first.fields[:marker] = shared
    simple = Core.svec(shared)
    second.fields[:meta] = simple
    p = Plot([first, second])
    @test restyle!(p, 1; marker_size=32) === p
    committed_simple = p.data[2].fields[:meta]
    @test p.data[1] === first
    @test p.data[2] === second
    @test committed_simple isa Core.SimpleVector
    @test committed_simple !== simple
    @test committed_simple[1] === p.data[1].fields[:marker]
    @test committed_simple[1][:size] == 32
    @test shared[:size] == 10

    shared = Dict{Symbol,Any}(:size => 10)
    trace = scatter(y=[1])
    untouched = scatter(y=[2])
    trace.fields[:marker] = shared
    frame_simple = Core.svec(shared, untouched)
    config_simple = Core.svec(shared, untouched)
    p = Plot(
        [trace, untouched],
        Layout(),
        [
            frame(
                Dict{Symbol,Any}(
                    :name => "simple-vector-frame",
                    :meta => frame_simple,
                ),
            ),
        ];
        config=PlotConfig(
            toImageButtonOptions=Dict{Symbol,Any}(
                :meta => config_simple,
            ),
        ),
    )
    @test restyle!(p, 1; marker_size=33) === p
    committed_marker = p.data[1].fields[:marker]
    committed_frame_simple = p.frames[1].fields[:meta]
    committed_config_simple =
        p.config.toImageButtonOptions[:meta]
    @test committed_frame_simple isa Core.SimpleVector
    @test committed_config_simple isa Core.SimpleVector
    @test committed_frame_simple !== frame_simple
    @test committed_config_simple !== config_simple
    @test committed_frame_simple[1] === committed_marker
    @test committed_config_simple[1] === committed_marker
    @test p.data[2] === untouched
    @test committed_frame_simple[2] === untouched
    @test committed_config_simple[2] === untouched
    @test committed_marker[:size] == 33
    @test shared[:size] == 10

    if isdefined(Core, :GenericMemory)
        make_memory = function (values...)
            memory = Memory{Any}(undef, length(values))
            for ind in eachindex(values)
                memory[ind] = values[ind]
            end
            return memory
        end

        shared = Dict{Symbol,Any}(:size => 10)
        selected = scatter(y=[1])
        selected.fields[:marker] = shared
        custom_memory = make_memory(shared, nothing)
        custom_holder = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :meta => custom_memory,
            ),
        )
        generic_holder = scatter(y=[3])
        untouched = scatter(y=[4])
        custom_holder.fields[:meta][2] = untouched
        generic_memory = make_memory(shared, untouched)
        generic_holder.fields[:meta] = generic_memory
        layout_memory = make_memory(shared, untouched)
        frame_memory = make_memory(shared, untouched)
        config_memory = make_memory(shared, untouched)
        layout = Layout()
        layout.fields[:memory_meta] = layout_memory
        frames = [
            frame(
                Dict{Symbol,Any}(
                    :name => "generic-memory-frame",
                    :meta => frame_memory,
                ),
            ),
        ]
        config = PlotConfig(
            toImageButtonOptions=Dict{Symbol,Any}(
                :meta => config_memory,
            ),
        )
        p = Plot(
            AbstractTrace[
                selected,
                custom_holder,
                generic_holder,
                untouched,
            ],
            layout,
            frames;
            config=config,
        )
        data_root = p.data
        layout_root = p.layout
        frames_root = p.frames
        config_root = p.config
        original_memories = (
            custom_memory,
            generic_memory,
            layout_memory,
            frame_memory,
            config_memory,
        )
        @test restyle!(p, 1; marker_size=34) === p
        committed_marker = p.data[1].fields[:marker]
        memories = (
            p.data[2].fields[:meta],
            p.data[3].fields[:meta],
            p.layout.fields[:memory_meta],
            p.frames[1].fields[:meta],
            p.config.toImageButtonOptions[:meta],
        )
        @test p.data === data_root
        @test p.layout === layout_root
        @test p.frames === frames_root
        @test p.config === config_root
        @test p.data[1] === selected
        @test p.data[2] !== custom_holder
        @test p.data[3] === generic_holder
        @test p.data[4] === untouched
        @test all(memory -> memory[1] === committed_marker, memories)
        @test all(memory -> memory[2] === untouched, memories)
        @test committed_marker[:size] == 34
        @test shared[:size] == 10
        @test all(
            pair -> pair[1] !== pair[2],
            zip(memories, original_memories),
        )
    end

    cycle_kinds = isdefined(Core, :GenericMemory) ?
                  (:dict, :vector, :memory, :attribute) :
                  (:dict, :vector, :attribute)
    for cycle_kind in cycle_kinds
        shared = Dict{Symbol,Any}(:size => 10)
        selected = scatter(y=[1])
        selected.fields[:marker] = shared
        cycle = if cycle_kind === :dict
            value = Dict{Symbol,Any}(:changed => shared)
            value[:self] = value
            value
        elseif cycle_kind === :vector
            value = Any[shared, nothing]
            value[2] = value
            value
        elseif cycle_kind === :memory
            value = Memory{Any}(undef, 2)
            value[1] = shared
            value[2] = value
            value
        else
            value = attr()
            value.fields[:changed] = shared
            value.fields[:self] = value
            value
        end
        holder = scatter(y=[2])
        holder.fields[:meta] = cycle
        p = Plot([selected, holder])
        @test restyle!(p, 1; marker_size=35) === p
        committed_marker = p.data[1].fields[:marker]
        committed_cycle = p.data[2].fields[:meta]
        committed_changed =
            cycle_kind in (:dict, :attribute) ?
            committed_cycle[:changed] :
            committed_cycle[1]
        committed_self =
            cycle_kind in (:dict, :attribute) ?
            committed_cycle[:self] :
            committed_cycle[2]
        @test committed_cycle !== cycle
        @test committed_changed === committed_marker
        @test committed_self === committed_cycle
        @test committed_marker[:size] == 35
        @test shared[:size] == 10
        original_self =
            cycle_kind in (:dict, :attribute) ?
            cycle[:self] :
            cycle[2]
        @test original_self === cycle
    end

    shared = Dict{Symbol,Any}(:size => 10)
    selected = scatter(y=[1])
    selected.fields[:marker] = shared
    left = Any[shared, nothing]
    right = Dict{Symbol,Any}(:back => left)
    left[2] = right
    holder = scatter(y=[2])
    holder.fields[:meta] = left
    p = Plot([selected, holder])
    @test restyle!(p, 1; marker_size=36) === p
    committed_marker = p.data[1].fields[:marker]
    committed_left = p.data[2].fields[:meta]
    @test committed_left !== left
    @test committed_left[1] === committed_marker
    @test committed_left[2][:back] === committed_left
    @test committed_marker[:size] == 36
    @test shared[:size] == 10
    @test left[2] === right
    @test right[:back] === left

    for attribute_first in (true, false)
        shared_attribute = attr(text="old")
        cycle = Any[nothing, nothing]
        backedge = Dict{Symbol,Any}(:back => cycle)
        if attribute_first
            cycle[1] = shared_attribute
            cycle[2] = backedge
        else
            cycle[1] = backedge
            cycle[2] = shared_attribute
        end
        holder = scatter(y=[1])
        holder.fields[:meta] = cycle
        layout = Layout(annotations=[shared_attribute])
        p = Plot([holder], layout)
        data_root = p.data
        layout_root = p.layout
        annotations_root = p.layout[:annotations]
        @test update_annotations!(p, attr(visible=false)) === p
        @test p.data === data_root
        @test p.data[1] === holder
        @test p.layout === layout_root
        @test p.layout[:annotations] === annotations_root
        @test p.layout[:annotations][1] === shared_attribute
        @test p.data[1].fields[:meta] === cycle
        @test cycle[attribute_first ? 1 : 2] === shared_attribute
        @test cycle[attribute_first ? 2 : 1] === backedge
        @test backedge[:back] === cycle
        @test shared_attribute[:text] == "old"
        @test shared_attribute[:visible] === false
    end

    public_cycle_kinds = isdefined(Core, :GenericMemory) ?
                         (:vector, :memory) :
                         (:vector,)
    for cycle_kind in public_cycle_kinds,
        public_first in (true, false)
        shared = Dict{Symbol,Any}(:size => 10)
        selected = scatter(y=[1])
        untouched = scatter(y=[2])
        selected.fields[:marker] = shared
        untouched.fields[:marker] = shared
        cycle = if cycle_kind === :vector
            Any[nothing, nothing]
        else
            Memory{Any}(undef, 2)
        end
        cycle[public_first ? 1 : 2] = untouched
        cycle[public_first ? 2 : 1] = cycle
        selected.fields[:meta] = cycle
        p = Plot([selected, untouched])
        @test restyle!(p, 1; marker_size=37) === p
        @test p.data[1] === selected
        @test p.data[2] === untouched
        @test p.data[1].fields[:meta] === cycle
        @test cycle[public_first ? 1 : 2] === untouched
        @test cycle[public_first ? 2 : 1] === cycle
        @test selected.fields[:marker] ===
              untouched.fields[:marker]
        @test selected.fields[:marker][:size] == 37
        @test shared[:size] == 10
    end

    cycle_orders = (
        (:changed, :public, :self),
        (:changed, :self, :public),
        (:public, :changed, :self),
        (:public, :self, :changed),
        (:self, :changed, :public),
        (:self, :public, :changed),
    )
    for cycle_kind in public_cycle_kinds,
        order in cycle_orders
        shared = Dict{Symbol,Any}(:size => 10)
        selected = scatter(y=[1])
        untouched = scatter(y=[2])
        selected.fields[:marker] = shared
        untouched.fields[:alias] = shared
        cycle = if cycle_kind === :vector
            Any[nothing, nothing, nothing]
        else
            Memory{Any}(undef, 3)
        end
        changed_ind = findfirst(isequal(:changed), order)
        public_ind = findfirst(isequal(:public), order)
        self_ind = findfirst(isequal(:self), order)
        cycle[changed_ind] = shared
        cycle[public_ind] = untouched
        cycle[self_ind] = cycle
        selected.fields[:meta] = cycle
        p = Plot([selected, untouched])
        @test restyle!(p, 1; marker_size=39) === p
        committed_cycle = p.data[1].fields[:meta]
        committed_marker = p.data[1].fields[:marker]
        @test p.data[1] === selected
        @test p.data[2] === untouched
        @test committed_cycle !== cycle
        @test committed_cycle[changed_ind] === committed_marker
        @test committed_cycle[public_ind] === untouched
        @test committed_cycle[self_ind] === committed_cycle
        @test untouched.fields[:alias] === committed_marker
        @test committed_marker[:size] == 39
        @test cycle[changed_ind] === shared
        @test cycle[public_ind] === untouched
        @test cycle[self_ind] === cycle
        @test shared[:size] == 10
    end

    if isdefined(Core, :GenericMemory)
        shared = Dict{Symbol,Any}(:size => 10)
        selected = scatter(y=[1])
        untouched = scatter(y=[2])
        selected.fields[:marker] = shared
        untouched.fields[:alias] = shared
        left = Memory{Any}(undef, 3)
        right = Memory{Any}(undef, 1)
        left[1] = shared
        left[2] = untouched
        left[3] = right
        right[1] = left
        selected.fields[:meta] = left
        p = Plot([selected, untouched])
        @test restyle!(p, 1; marker_size=40) === p
        committed_left = p.data[1].fields[:meta]
        committed_right = committed_left[3]
        committed_marker = p.data[1].fields[:marker]
        @test committed_left !== left
        @test committed_right !== right
        @test committed_left[1] === committed_marker
        @test committed_left[2] === untouched
        @test committed_right[1] === committed_left
        @test untouched.fields[:alias] === committed_marker
        @test committed_marker[:size] == 40
        @test left[1] === shared
        @test left[2] === untouched
        @test left[3] === right
        @test right[1] === left
        @test shared[:size] == 10
    end

    shared = Dict{Symbol,Any}(:size => 10)
    selected = scatter(y=[1])
    untouched = scatter(y=[2])
    selected.fields[:marker] = shared
    untouched.fields[:alias] = shared
    dictionary_child = Dict{Symbol,Any}()
    immutable_cycle = _TransactionImmutableCycleWrapper(
        shared,
        untouched,
        dictionary_child,
    )
    dictionary_child[:back] = immutable_cycle
    selected.fields[:meta] = immutable_cycle
    p = Plot([selected, untouched])
    @test restyle!(p, 1; marker_size=41) === p
    committed_immutable = p.data[1].fields[:meta]
    committed_marker = p.data[1].fields[:marker]
    @test committed_immutable !== immutable_cycle
    @test committed_immutable.changed === committed_marker
    @test committed_immutable.public_child === untouched
    @test committed_immutable.child[:back] ===
          committed_immutable
    @test untouched.fields[:alias] === committed_marker
    @test committed_marker[:size] == 41
    @test dictionary_child[:back] === immutable_cycle
    @test shared[:size] == 10

    shared = Dict{Symbol,Any}(:size => 10)
    selected = scatter(y=[1])
    untouched = scatter(y=[2])
    selected.fields[:marker] = shared
    untouched.fields[:alias] = shared
    left = _TransactionConstCycleWrapper(
        untouched,
        shared,
        nothing,
    )
    right = _TransactionConstCycleWrapper(
        untouched,
        shared,
        left,
    )
    left.link = right
    selected.fields[:meta] = left
    p = Plot([selected, untouched])
    @test restyle!(p, 1; marker_size=42) === p
    committed_left = p.data[1].fields[:meta]
    committed_right = committed_left.link
    committed_marker = p.data[1].fields[:marker]
    @test committed_left !== left
    @test committed_right !== right
    @test committed_left.public_child === untouched
    @test committed_right.public_child === untouched
    @test committed_left.changed === committed_marker
    @test committed_right.changed === committed_marker
    @test committed_right.link === committed_left
    @test untouched.fields[:alias] === committed_marker
    @test committed_marker[:size] == 42
    @test right.link === left
    @test shared[:size] == 10

    make_closure_cycle = function (public_trace, shared_value)
        holder = Ref{Any}()
        callback = () -> holder[]
        wrapper = _TransactionClosureCycleWrapper(
            callback,
            public_trace,
            shared_value,
        )
        holder[] = wrapper
        return wrapper
    end
    shared = Dict{Symbol,Any}(:size => 10)
    selected = scatter(y=[1])
    untouched = scatter(y=[2])
    selected.fields[:marker] = shared
    untouched.fields[:alias] = shared
    closure_cycle = make_closure_cycle(untouched, shared)
    selected.fields[:meta] = closure_cycle
    p = Plot([selected, untouched])
    @test restyle!(p, 1; marker_size=43) === p
    committed_closure = p.data[1].fields[:meta]
    committed_marker = p.data[1].fields[:marker]
    @test committed_closure !== closure_cycle
    @test committed_closure.callback() === committed_closure
    @test committed_closure.public_child === untouched
    @test committed_closure.shared === committed_marker
    @test untouched.fields[:alias] === committed_marker
    @test committed_marker[:size] == 43
    @test closure_cycle.callback() === closure_cycle
    @test shared[:size] == 10

    shared = Dict{Symbol,Any}(:size => 10)
    selected = scatter(y=[1])
    selected.fields[:marker] = shared
    trace_root = scatter(y=[2])
    trace_root.fields[:alias] = shared
    trace_root.fields[:self] = trace_root
    layout_root = Layout()
    layout_root.fields[:alias] = shared
    layout_root.fields[:self] = layout_root
    p = Plot([selected, trace_root], layout_root)
    @test restyle!(p, 1; marker_size=38) === p
    @test p.data[1] === selected
    @test p.data[2] === trace_root
    @test p.layout === layout_root
    @test trace_root.fields[:self] === trace_root
    @test layout_root.fields[:self] === layout_root
    @test trace_root.fields[:alias] ===
          selected.fields[:marker]
    @test layout_root.fields[:alias] ===
          selected.fields[:marker]
    @test selected.fields[:marker][:size] == 38
    @test shared[:size] == 10

    shared_key = Dict{Symbol,Any}(:size => 10)
    first = scatter(y=[1])
    second = scatter(y=[2])
    first.fields[:marker] = shared_key
    keyed = IdDict{Any,Any}(shared_key => :value)
    second.fields[:meta] = keyed
    p = Plot([first, second])
    @test restyle!(p, 1; marker_size=35) === p
    committed_key = p.data[1].fields[:marker]
    @test only(keys(p.data[2].fields[:meta])) ===
          committed_key
    @test committed_key[:size] == 35
    @test p.data[2].fields[:meta][committed_key] === :value

    for dictionary_kind in (:dict, :iddict),
        self_cycle in (false, true)
        shared = Dict{Symbol,Any}(:size => 10)
        selected = scatter(y=[1])
        untouched = scatter(y=[2])
        selected.fields[:marker] = shared
        untouched.fields[:alias] = shared
        keyed = dictionary_kind === :dict ?
                Dict{Any,Any}(untouched => shared) :
                IdDict{Any,Any}(untouched => shared)
        self_cycle && (keyed[:self] = keyed)
        selected.fields[:meta] = keyed
        p = Plot([selected, untouched])
        @test restyle!(p, 1; marker_size=40) === p
        committed_keyed = p.data[1].fields[:meta]
        committed_marker = p.data[1].fields[:marker]
        exact_public_key = if committed_keyed isa Dict
            getkey(
                committed_keyed,
                untouched,
                Ref(nothing),
            ) === untouched
        else
            haskey(committed_keyed, untouched)
        end
        @test p.data[1] === selected
        @test p.data[2] === untouched
        @test committed_keyed !== keyed
        @test exact_public_key
        @test committed_keyed[untouched] === committed_marker
        @test untouched.fields[:alias] === committed_marker
        @test !self_cycle ||
              committed_keyed[:self] === committed_keyed
        @test keyed[untouched] === shared
        @test !self_cycle || keyed[:self] === keyed
        @test shared[:size] == 10
    end

    for dictionary_kind in (:dict, :iddict),
        public_first in (true, false)
        shared = Dict{Symbol,Any}(:size => 10)
        selected = scatter(y=[1])
        untouched = scatter(y=[2])
        selected.fields[:marker] = shared
        untouched.fields[:alias] = shared
        keyed = dictionary_kind === :dict ?
                Dict{Any,Any}() :
                IdDict{Any,Any}()
        if public_first
            keyed[untouched] = :value
            keyed[:self] = keyed
        else
            keyed[:self] = keyed
            keyed[untouched] = :value
        end
        selected.fields[:meta] = keyed
        p = Plot([selected, untouched])
        @test restyle!(p, 1; marker_size=41) === p
        committed_marker = p.data[1].fields[:marker]
        @test p.data[1] === selected
        @test p.data[2] === untouched
        @test p.data[1].fields[:meta] === keyed
        @test keyed[:self] === keyed
        @test keyed[untouched] === :value
        @test untouched.fields[:alias] === committed_marker
        @test committed_marker[:size] == 41
        @test shared[:size] == 10
    end

    for dictionary_kind in (:dict, :iddict),
        key_kind in (:tuple, :namedtuple)
        shared = Dict{Symbol,Any}(:size => 10)
        selected = scatter(y=[1])
        untouched = scatter(y=[2])
        selected.fields[:marker] = shared
        untouched.fields[:alias] = shared
        composite_key =
            key_kind === :tuple ?
            (untouched,) :
            (trace=untouched,)
        keyed = dictionary_kind === :dict ?
                Dict{Any,Any}(
                    composite_key => :value,
                ) :
                IdDict{Any,Any}(
                    composite_key => :value,
                )
        keyed[:self] = keyed
        selected.fields[:meta] = keyed
        p = Plot([selected, untouched])
        @test restyle!(p, 1; marker_size=42) === p
        stored_key = only(
            key for key in keys(keyed)
            if key !== :self
        )
        committed_marker = p.data[1].fields[:marker]
        @test p.data[1] === selected
        @test p.data[2] === untouched
        @test p.data[1].fields[:meta] === keyed
        @test stored_key === composite_key
        @test keyed[composite_key] === :value
        @test keyed[:self] === keyed
        @test untouched.fields[:alias] === committed_marker
        @test committed_marker[:size] == 42
        @test shared[:size] == 10
    end

    shared = Dict{Symbol,Any}(:size => 10)
    first = scatter(y=[1])
    second = scatter(y=[2])
    first.fields[:marker] = shared
    second.fields[:meta] = _TransactionTaggedAttribute(
        Dict{Symbol,Any}(:marker => shared),
        :keep,
    )
    p = Plot([first, second])
    @test restyle!(p, 1; marker_size=40) === p
    committed_attribute = p.data[2].fields[:meta]
    @test committed_attribute isa _TransactionTaggedAttribute
    @test committed_attribute.tag === :keep
    @test committed_attribute.fields[:marker] ===
          p.data[1].fields[:marker]
    @test committed_attribute.fields[:marker][:size] == 40

    shared = Dict{Symbol,Any}(:size => 10)
    trace = scatter(y=[1])
    trace.fields[:marker] = shared
    layout = _TransactionCustomLayout(
        Dict{Symbol,Any}(:shared => shared),
    )
    p = Plot([trace], layout)
    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :custom_layout_incremental_window,
        "custom-layout-incremental-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test restyle!(sp, 1; marker_size=50) === sp
        @test p.layout isa _TransactionCustomLayout
        @test p.layout.fields[:shared] ===
              p.data[1].fields[:marker]
        @test p.layout.fields[:shared][:size] == 50
        @test occursin("Plotly.react", only(state.scripts))
    finally
        close(sp)
    end
end

@testset "incremental outer-root candidates commit coherently" begin
    custom = _TransactionDataRootMutatingTrace(
        Dict{Symbol,Any}(:type => "scatter"),
        :push,
    )
    p = Plot(AbstractTrace[custom], Layout())
    data_root = p.data
    custom.fields[:shared_data] = data_root
    @test restyle!(p, 1; name="changed") === p
    @test p.data === data_root
    @test length(p.data) == 2
    @test p.data[1] !== custom
    @test p.data[1].fields[:shared_data] === p.data
    @test p.data[1].fields[:name] == "changed"
    @test p.data[2][:name] == "side-effect"

    for action in (:delete, :reverse)
        custom = _TransactionDataRootMutatingTrace(
            Dict{Symbol,Any}(:type => "scatter"),
            action,
        )
        other = scatter(y=[2], name="other")
        p = Plot(AbstractTrace[custom, other], Layout())
        custom.fields[:shared_data] = p.data
        @test restyle!(p, 1; name=string(action)) === p
        if action === :delete
            @test length(p.data) == 1
            @test p.data[1].fields[:name] == "delete"
        else
            @test length(p.data) == 2
            @test p.data[1] === other
            @test p.data[2].fields[:name] == "reverse"
            @test p.data[2].fields[:shared_data] === p.data
        end
    end

    custom = _TransactionDataRootMutatingTrace(
        Dict{Symbol,Any}(:type => "scatter"),
        :push,
    )
    p = Plot(AbstractTrace[custom], Layout())
    custom.fields[:shared_data] = p.data
    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :data_root_success_window,
        "data-root-success-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test restyle!(sp, 1; name="changed") === sp
        @test length(p.data) == 2
        @test p.data[1].fields[:shared_data] === p.data
        script = only(state.scripts)
        @test occursin("Plotly.react", script)
        @test occursin("\"data_length\":2", script)
        @test occursin("\"side-effect\"", script)
    finally
        close(sp)
    end

    custom = _TransactionDataRootMutatingTrace(
        Dict{Symbol,Any}(:type => "scatter"),
        :push,
    )
    p = Plot(AbstractTrace[custom], Layout())
    data_root = p.data
    custom.fields[:shared_data] = data_root
    primary = ErrorException("injected-data-root-failure")
    state = _TransactionRendererState(Any[primary, "ok"])
    sp = SyncPlot(
        p,
        nothing,
        :data_root_failure_window,
        "data-root-failure-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        caught = try
            restyle!(sp, 1; name="changed")
            nothing
        catch err
            err
        end
        @test caught === primary
        @test p.data === data_root
        @test length(p.data) == 1
        @test p.data[1] === custom
        @test !haskey(custom.fields, :name)
        @test custom.fields[:shared_data] === p.data
        @test length(state.scripts) == 2
        @test occursin("\"data_length\":2", state.scripts[1])
        @test occursin("\"data_length\":1", state.scripts[2])
    finally
        close(sp)
    end

    for target in (:layout, :config)
        layout = Layout(audit_value=10)
        config = PlotConfig(
            toImageButtonOptions=Dict{Symbol,Any}(:size => 10),
        )
        custom = _TransactionRootValueMutatingTrace(
            Dict{Symbol,Any}(:type => "scatter"),
            target,
        )
        p = Plot(
            AbstractTrace[custom],
            layout,
            PlotlyFrame[];
            config=config,
        )
        root = target === :layout ? p.layout : p.config
        custom.fields[:root] = root
        state = _TransactionRendererState()
        sp = SyncPlot(
            p,
            nothing,
            Symbol(target, :_root_value_window),
            string(target, "-root-value-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        try
            @test restyle!(sp, 1; name="changed") === sp
            @test p.data[1].fields[:root] ===
                  getfield(p, target)
            @test occursin(
                "\"root_value\":20",
                only(state.scripts),
            )
            @test occursin(
                "Plotly.react",
                only(state.scripts),
            )
            if target === :layout
                @test p.layout.fields[:audit_value] == 20
            else
                @test p.config.toImageButtonOptions[:size] == 20
            end
        finally
            close(sp)
        end
    end

    shared = Dict{Symbol,Any}(:size => 10)
    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :meta => shared,
        ),
    )
    layout = Layout()
    layout.fields[:font] = shared
    p = Plot(AbstractTrace[custom], layout)
    @test p.data[1].fields[:meta] === p.layout.fields[:font]
    @test relayout!(p; font_size=20) === p
    @test p.data[1] !== custom
    @test p.data[1].fields[:meta] === p.layout.fields[:font]
    @test p.data[1].fields[:meta][:size] == 20

    for should_fail in (false, true)
        shared = Dict{Symbol,Any}(:size => 10)
        custom = _TransactionCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :meta => shared,
            ),
        )
        layout = Layout()
        layout.fields[:font] = shared
        p = Plot(AbstractTrace[custom], layout)
        primary = ErrorException(
            "injected-relayout-custom-alias-failure",
        )
        state = _TransactionRendererState(
            should_fail ? Any[primary, "ok"] : Any[],
        )
        sp = SyncPlot(
            p,
            nothing,
            Symbol(:relayout_custom_, should_fail),
            string("relayout-custom-", should_fail),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        try
            caught = try
                relayout!(sp; font_size=20)
                nothing
            catch err
                err
            end
            if should_fail
                @test caught === primary
                @test p.data[1] === custom
                @test p.layout === layout
                @test p.data[1].fields[:meta] === shared
                @test p.layout.fields[:font] === shared
                @test shared[:size] == 10
                @test length(state.scripts) == 2
            else
                @test caught === nothing
                @test p.data[1] !== custom
                @test p.data[1].fields[:meta] ===
                      p.layout.fields[:font]
                @test p.layout.fields[:font][:size] == 20
                @test occursin(
                    "Plotly.react",
                    only(state.scripts),
                )
            end
        finally
            close(sp)
        end
    end

    shared_node = _TransactionSharedNode(10)
    first = _TransactionNodeMutatingTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :holder => shared_node,
        ),
        :direct,
    )
    second = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :node => Any[
                _TransactionAliasWrapper(shared_node),
            ],
        ),
    )
    p = Plot(AbstractTrace[first, second], Layout())
    @test restyle!(p, 1; node_value=20) === p
    @test p.data[2] !== second
    @test p.data[2].fields[:node][1].child ===
          p.data[1].fields[:holder]
    @test p.data[2].fields[:node][1].child.value == 20
    @test shared_node.value == 10

    for wrapper_kind in (:dict, :array, :attribute)
        shared = Dict{Symbol,Any}(:size => 10)
        wrapper = if wrapper_kind === :dict
            _TransactionTaggedDict(
                Dict{Symbol,Any}(),
                shared,
            )
        elseif wrapper_kind === :array
            _TransactionTaggedVector(Any[], shared)
        else
            _TransactionTaggedAttribute(
                Dict{Symbol,Any}(),
                shared,
            )
        end
        first = scatter(y=[1])
        second = scatter(y=[2])
        first.fields[:marker] = shared
        second.fields[:meta] = wrapper
        p = Plot([first, second])
        @test restyle!(p, 1; marker_size=20) === p
        committed_wrapper = p.data[2].fields[:meta]
        @test committed_wrapper !== wrapper
        @test committed_wrapper.tag ===
              p.data[1].fields[:marker]
        @test committed_wrapper.tag[:size] == 20
        @test shared[:size] == 10
    end

    shared = Dict{Symbol,Any}(:size => 10)
    trace = scatter(y=[1])
    trace.fields[:marker] = shared
    p = Plot(trace)
    caller = Dict{Symbol,Any}(:nested => shared)
    @test restyle!(
        p,
        1,
        Dict{Symbol,Any}(:meta => caller),
    ) === p
    @test p.data[1].fields[:marker] === shared
    @test p.data[1].fields[:meta][:nested] === shared
    @test caller[:nested] === shared

    shared = Dict{Symbol,Any}(:size => 10)
    config = PlotConfig(
        toImageButtonOptions=Dict{Symbol,Any}(:shared => shared),
    )
    p = Plot(scatter(y=[1]); config=config)
    @test restyle!(
        p,
        1,
        Dict{Symbol,Any}(:meta => shared),
    ) === p
    @test p.data[1].fields[:meta] ===
          p.config.toImageButtonOptions[:shared]

    frames = _TransactionFrameVector(
        PlotlyFrame[frame(name="original")],
    )
    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(:type => "scatter"),
    )
    p = Plot(AbstractTrace[custom], Layout(), frames)
    frames_root = p.frames
    custom.fields[:shared_frames] = frames_root
    @test restyle!(p, 1; name="changed") === p
    @test p.frames === frames_root
    @test p.data[1].fields[:shared_frames] === p.frames

    frames = _TransactionFrameVector(
        PlotlyFrame[frame(name="original")],
    )
    custom = _TransactionRootValueMutatingTrace(
        Dict{Symbol,Any}(:type => "scatter"),
        :frames,
    )
    p = Plot(AbstractTrace[custom], Layout(), frames)
    frames_root = p.frames
    custom.fields[:root] = frames_root
    @test restyle!(p, 1; name="changed") === p
    @test p.frames !== frames_root
    @test length(p.frames) == 2
    @test p.data[1].fields[:root] === p.frames

    for payload in (
        [1, 2],
        Any[
            _TransactionAliasWrapper(
                Dict{Symbol,Any}(:size => 3),
            ),
        ],
    )
        custom = _TransactionFailingInputTrace(
            Dict{Symbol,Any}(:type => "scatter"),
        )
        p = Plot(AbstractTrace[custom], Layout())
        caught = try
            restyle!(p, 1; payload=payload)
            nothing
        catch err
            err
        end
        @test caught isa ErrorException
        @test sprint(showerror, caught) ==
              "injected-third-party-setter-failure"
        @test p.data[1] === custom
        if eltype(payload) <: Integer
            @test payload == [1, 2]
        else
            @test payload[1].child[:size] == 3
        end
    end

    custom = _TransactionCustomTrace(
        Dict{Symbol,Any}(
            :type => "scatter",
            :name => "same",
        ),
    )
    p = Plot(AbstractTrace[custom], Layout())
    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :idempotent_custom_window,
        "idempotent-custom-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test restyle!(sp, 1; name="same") === sp
        @test p.data[1] === custom
        @test isempty(state.scripts)
    finally
        close(sp)
    end

    ignored = _TransactionIgnoringTrace(
        Dict{Symbol,Any}(:type => "scatter"),
    )
    generic = scatter(y=[2])
    p = Plot(AbstractTrace[ignored, generic], Layout())
    @test restyle!(
        p,
        [1, 2],
        Dict{Symbol,Any}(
            :link => Any[nothing, ignored],
        ),
    ) === p
    @test p.data[1] === ignored
    @test p.data[2] === generic
    @test p.data[2].fields[:link] === ignored

    trace_count = 200
    reads = Ref(0)
    shared_payload = _TransactionCountingVector(
        Any[
            _TransactionOpaqueValue(BigInt(ind))
            for ind in 1:trace_count
        ],
        reads,
    )
    p = Plot([
        begin
            trace = scatter(y=[ind])
            trace.fields[:meta] = shared_payload
            trace
        end
        for ind in 1:trace_count
    ])
    reads[] = 0
    @test restyle!(p, 1; name="changed") === p
    @test reads[] <= 8 * trace_count

end

@testset "self-copying alias wrappers remain isolated on failure" begin
    for wrapper_kind in (:array, :dict)
        shared = Dict{Symbol,Any}(:size => 10)
        first = scatter(y=[1])
        second = scatter(y=[2])
        first.fields[:marker] = shared
        wrapper = if wrapper_kind === :array
            _TransactionSelfCopyVector(Any[shared], 0)
        else
            _TransactionSelfCopyAliasDict(
                Dict{Symbol,Any}(:marker => shared),
                0,
            )
        end
        second.fields[:meta] = wrapper
        p = Plot([first, second])
        first_root, second_root = p.data
        primary = ErrorException(
            "injected-$wrapper_kind-alias-wrapper-failure",
        )
        state = _TransactionRendererState(Any[primary, "ok"])
        sp = SyncPlot(
            p,
            nothing,
            Symbol(wrapper_kind, :_alias_wrapper_window),
            string(wrapper_kind, "-alias-wrapper-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _transaction_backend(state),
            ),
        )
        try
            caught = try
                restyle!(sp, 1; marker_size=60)
                nothing
            catch err
                err
            end
            @test caught === primary
            @test p.data[1] === first_root
            @test p.data[2] === second_root
            @test p.data[1].fields[:marker] === shared
            @test p.data[2].fields[:meta] === wrapper
            @test wrapper.writes == 0
            wrapped_shared = wrapper_kind === :array ?
                wrapper[1] :
                wrapper[:marker]
            @test wrapped_shared === shared
            @test shared[:size] == 10
            @test length(state.scripts) == 2
        finally
            close(sp)
        end
    end

    caller = _TransactionSelfCopyAliasDict(
        Dict{Symbol,Any}(:size => 3),
        0,
    )
    p = Plot(scatter(y=[1]))
    trace = p.data[1]
    primary = ErrorException(
        "injected-custom-dictionary-setter-failure",
    )
    state = _TransactionRendererState(Any[primary, "ok"])
    sp = SyncPlot(
        p,
        nothing,
        :custom_dictionary_setter_window,
        "custom-dictionary-setter-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        caught = try
            restyle!(
                sp,
                1,
                Dict(:marker => caller);
                marker_size=9,
            )
            nothing
        catch err
            err
        end
        @test caught === primary
        @test p.data[1] === trace
        @test !haskey(trace.fields, :marker)
        @test caller.writes == 0
        @test caller[:size] == 3
        @test length(state.scripts) == 2
    finally
        close(sp)
    end

    caller = _TransactionZeroBasedVector(
        Any[Dict{Symbol,Any}(:value => 1)],
    )
    committed = PlotlySupply._copy_setter_input(
        caller,
        IdDict{Any,Any}(),
    )
    @test committed isa _TransactionZeroBasedVector
    @test axes(committed) == (0:0,)
    @test committed !== caller
    @test committed[0] !== caller[0]
    @test committed[0] == Dict(:value => 1)
    @test caller[0] == Dict(:value => 1)
end

@testset "caller-owned setter containers roll back atomically" begin
    primary = ErrorException("injected-caller-restyle-failure")
    shared = Dict{Symbol,Any}(:size => 3)
    first = scatter(y=[1])
    second = scatter(y=[2])
    second.fields[:marker] = shared
    p = Plot([first, second])
    state = _TransactionRendererState(Any[primary, "ok"])
    sp = SyncPlot(
        p,
        nothing,
        :caller_restyle_window,
        "caller-restyle-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        caught = try
            restyle!(
                sp,
                1,
                Dict(:marker => shared);
                marker_size=9,
            )
            nothing
        catch err
            err
        end
        @test caught === primary
        @test shared[:size] == 3
        @test p.data[2].fields[:marker] === shared
        @test !haskey(p.data[1].fields, :marker)
        @test occursin("Plotly.newPlot", state.scripts[2])
        @test !occursin("\"size\":9", state.scripts[2])
    finally
        close(sp)
    end

    primary = ErrorException("injected-caller-relayout-failure")
    shared = Dict{Symbol,Any}(:size => 4)
    trace = scatter(y=[1], mode="text", text=["a"])
    trace.fields[:textfont] = shared
    p = Plot(trace)
    state = _TransactionRendererState(Any[primary, "ok"])
    sp = SyncPlot(
        p,
        nothing,
        :caller_relayout_window,
        "caller-relayout-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        caught = try
            relayout!(
                sp,
                Dict(:font => shared);
                font_size=21,
            )
            nothing
        catch err
            err
        end
        @test caught === primary
        @test shared[:size] == 4
        @test p.data[1].fields[:textfont] === shared
        @test !haskey(p.layout.fields, :font)
        @test occursin("Plotly.newPlot", state.scripts[2])
        @test !occursin("\"size\":21", state.scripts[2])
    finally
        close(sp)
    end

    primary = ErrorException("injected-self-copy-array-failure")
    child = Dict{Symbol,Any}(:value => 1)
    caller_array =
        _TransactionSelfCopyVector(Any[child], 0)
    p = Plot(scatter(y=[1]))
    state = _TransactionRendererState(Any[primary, "ok"])
    sp = SyncPlot(
        p,
        nothing,
        :self_copy_array_window,
        "self-copy-array-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        caught = try
            restyle!(sp, 1; meta=caller_array)
            nothing
        catch err
            err
        end
        @test caught === primary
        @test caller_array.writes == 0
        @test caller_array[1] === child
        @test !haskey(p.data[1].fields, :meta)
        @test length(state.scripts) == 2
        @test occursin("Plotly.newPlot", state.scripts[2])
    finally
        close(sp)
    end
end

struct _RegistryProbeDict <: AbstractDict{Symbol,Any}
    callback::Function
end

Base.length(::_RegistryProbeDict) = 1
Base.getindex(::_RegistryProbeDict, key::Symbol) =
    key === :name ? "local-update" : throw(KeyError(key))
function Base.iterate(values::_RegistryProbeDict, state::Int=1)
    state == 1 || return nothing
    values.callback()
    return (:name => "local-update", 2)
end

@testset "unregistered mutations release the global registry lock" begin
    p = Plot(scatter(y=[1, 2], name="old"))
    observation = Ref{Any}(nothing)
    update = _RegistryProbeDict(
        () -> begin
            registry_locked =
                islocked(PlotlySupply._SYNCPLOT_REGISTRY_LOCK)
            reservation = lock(
                PlotlySupply._SYNCPLOT_REGISTRY_LOCK,
            ) do
                get(
                    PlotlySupply._PLOT_SYNCPLOT_RESERVATIONS,
                    p,
                    nothing,
                )
            end
            observation[] = (
                registry_locked=registry_locked,
                reservation=reservation,
            )
        end,
    )

    @test restyle!(p, 1, update) === p
    @test observation[] !== nothing
    @test !observation[].registry_locked
    @test observation[].reservation isa
          PlotlySupply._SyncPlotReservation
    @test observation[].reservation.kind === :local
    @test !haskey(
        PlotlySupply._PLOT_SYNCPLOT_RESERVATIONS,
        p,
    )
    @test p.data[1][:name] == "local-update"
end

@testset "unregistered reentrant mutations are rejected atomically" begin
    p = Plot(scatter(y=[1, 2], name="old"))
    nested_error = Ref{Any}(nothing)
    update = _RegistryProbeDict(
        () -> begin
            nested_error[] = try
                restyle!(p, 1; marker_color="nested")
                nothing
            catch err
                err
            end
        end,
    )

    @test restyle!(p, 1, update) === p
    @test nested_error[] isa InvalidStateException
    @test nested_error[].state == :reentrant
    @test p.data[1][:name] == "local-update"
    @test !haskey(p.data[1].fields, :marker)
    @test !haskey(
        PlotlySupply._PLOT_SYNCPLOT_RESERVATIONS,
        p,
    )
end

@testset "unregistered full-model mutations wait for local owners" begin
    p = Plot(scatter(y=[1, 2], name="old"))
    entered = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    first_iteration = Ref(true)
    update = _RegistryProbeDict(
        () -> begin
            first_iteration[] || return
            first_iteration[] = false
            put!(entered, nothing)
            take!(release)
        end,
    )

    first_task = @async restyle!(p, 1, update)
    take!(entered)
    second_task =
        @async addtraces!(p, scatter(y=[3, 4], name="second"))
    for _ in 1:10
        yield()
    end
    @test !istaskdone(second_task)

    put!(release, nothing)
    @test fetch(first_task) === p
    @test fetch(second_task) === p
    @test length(p.data) == 2
    @test p.data[1][:name] == "local-update"
    @test p.data[2][:name] == "second"
    @test !haskey(
        PlotlySupply._PLOT_SYNCPLOT_RESERVATIONS,
        p,
    )
end

struct _ReentrantTransactionValue
    callback::Function
end

function PlotlyBase.JSON.lower(value::_ReentrantTransactionValue)
    value.callback()
    return 17
end

@testset "same-task serialization cannot reenter model mutation" begin
    p, sp, state = _transaction_fixture()
    snapshot = _transaction_snapshot(p)
    try
        value = _ReentrantTransactionValue(
            () -> restyle!(p, 1; name="nested-commit"),
        )
        caught = try
            restyle!(sp, 1; marker_size=value)
            nothing
        catch err
            err
        end
        @test caught isa InvalidStateException
        @test caught.state == :reentrant
        @test isempty(state.scripts)
        _test_transaction_snapshot(p, snapshot)
        @test !sp._resources.renderer_desynchronized

        token = Ref(23)
        safe_value = _ReentrantTransactionValue(
            () -> token[],
        )
        @test restyle!(
            sp,
            1;
            marker_size=safe_value,
        ) === sp
        @test p.data[1][:marker][:size] === safe_value
        @test token[] == 23
        @test length(state.scripts) == 1
    finally
        close(sp)
    end
end

mutable struct _BlockingRendererState
    open::Bool
    scripts::Vector{String}
    entered::Channel{String}
    release::Channel{Nothing}
end

function _blocking_backend(state::_BlockingRendererState)
    return (
        isopen=window -> state.open,
        close=window -> begin
            state.open = false
            return nothing
        end,
        run=(window, script) -> begin
            text = String(script)
            push!(state.scripts, text)
            put!(state.entered, text)
            take!(state.release)
            return "ok"
        end,
    )
end

function _blocking_fixture(; register::Bool=false)
    state = _BlockingRendererState(
        true,
        String[],
        Channel{String}(4),
        Channel{Nothing}(4),
    )
    p = Plot(scatter(y=[1, 2, 3]), Layout(title="blocking-old"))
    sp = SyncPlot(
        p,
        nothing,
        :blocking_window,
        "blocking-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _blocking_backend(state),
        ),
    )
    if register
        PlotlySupply._register_displayed_syncplot!(p, sp)
    end
    return p, sp, state
end

@testset "renderer transactions serialize mutation, close, and remapping" begin
    p, sp, state = _blocking_fixture()
    first_task = @async relayout!(sp; title="first")
    take!(state.entered)
    second_task = @async restyle!(sp, 1; marker_size=4)
    for _ in 1:10
        yield()
    end
    @test !isready(state.entered)
    put!(state.release, nothing)
    second_script = take!(state.entered)
    @test occursin("Plotly.restyle", second_script)
    put!(state.release, nothing)
    @test fetch(first_task) === sp
    @test fetch(second_task) === sp
    @test p.layout.fields[:title] == "first"
    @test p.data[1][:marker][:size] == 4
    close(sp)

    p, sp, state = _blocking_fixture()
    mutation_task = @async relayout!(sp; title="before-close")
    take!(state.entered)
    close_task = @async close(sp)
    for _ in 1:10
        yield()
    end
    @test !istaskdone(close_task)
    @test !sp._resources.close_started
    put!(state.release, nothing)
    @test fetch(mutation_task) === sp
    @test fetch(close_task) === nothing
    @test p.layout.fields[:title] == "before-close"
    @test !state.open

    p, old_sp, old_state = _blocking_fixture(; register=true)
    mutation_task = @async relayout!(p; title="remapped-title")
    take!(old_state.entered)
    new_state = _TransactionRendererState()
    new_sp = SyncPlot(
        p,
        nothing,
        :replacement_window,
        "replacement-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(new_state),
        ),
    )
    prior, registered =
        PlotlySupply._register_displayed_syncplot!(p, new_sp)
    @test prior === old_sp
    @test registered
    put!(old_state.release, nothing)
    recovery_script = take!(old_state.entered)
    @test occursin("Plotly.newPlot", recovery_script)
    put!(old_state.release, nothing)
    @test fetch(mutation_task) === p
    @test p.layout.fields[:title] == "remapped-title"
    @test PlotlySupply._PLOT_SYNCPLOT_MAP[p] === new_sp
    @test length(old_state.scripts) == 2
    @test length(new_state.scripts) == 1
    @test occursin("Plotly.relayout", only(new_state.scripts))
    close(old_sp)
    close(new_sp)

    p, old_sp, old_state = _blocking_fixture(; register=true)
    direct_error = Ref{Any}(nothing)
    mutation_task = @async try
        relayout!(old_sp; title="direct-remap-title")
    catch err
        direct_error[] = err
        nothing
    end
    take!(old_state.entered)
    new_state = _TransactionRendererState()
    new_sp = SyncPlot(
        p,
        nothing,
        :direct_remap_replacement_window,
        "direct-remap-replacement-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(new_state),
        ),
    )
    prior, registered =
        PlotlySupply._register_displayed_syncplot!(p, new_sp)
    @test prior === old_sp
    @test registered
    put!(old_state.release, nothing)
    recovery_script = take!(old_state.entered)
    @test occursin("Plotly.newPlot", recovery_script)
    put!(old_state.release, nothing)
    @test fetch(mutation_task) === nothing
    @test direct_error[] isa InvalidStateException
    @test p.layout.fields[:title] == "blocking-old"
    @test PlotlySupply._PLOT_SYNCPLOT_MAP[p] === new_sp
    @test length(old_state.scripts) == 2
    @test isempty(new_state.scripts)
    close(old_sp)
    close(new_sp)

    p, sp, state = _blocking_fixture()
    replacement =
        Plot(scatter(y=[7, 8, 9], name="replacement"), Layout(title="new"))
    react_task = @async react!(sp, replacement)
    first_script = take!(state.entered)
    @test occursin("Plotly.newPlot", first_script)
    update_task = @async update!(
        sp,
        1,
        Dict(:name => "updated-after-react"),
    )
    for _ in 1:10
        yield()
    end
    @test !isready(state.entered)
    put!(state.release, nothing)
    second_script = take!(state.entered)
    @test occursin("Plotly.update", second_script)
    @test !occursin("\"title\":\"blocking-old\"", second_script)
    put!(state.release, nothing)
    @test fetch(react_task) === sp
    @test fetch(update_task) === sp
    @test sp.plot === replacement
    @test replacement.layout.fields[:title] == "new"
    @test replacement.data[1][:name] == "updated-after-react"
    close(sp)
end

@testset "replacement reservations and registry generations prevent races" begin
    p, sp, state = _blocking_fixture()
    frame_storage = [
        frame(
            name="replacement-frame",
            data=[scatter(y=[9, 8, 7])],
        ),
    ]
    replacement = Plot(
        scatter(y=[7, 8, 9]),
        Layout(title="replacement-old"),
        @view(frame_storage[:]),
    )
    @test replacement.frames isa SubArray
    react_task = @async react!(sp, replacement)
    first_script = take!(state.entered)
    @test occursin("Plotly.newPlot", first_script)

    legacy_error = try
        addtraces!(
            replacement,
            scatter(y=[10], name="must-not-bypass-reservation"),
        )
        nothing
    catch err
        err
    end
    @test legacy_error isa InvalidStateException
    @test legacy_error.state == :busy
    @test length(replacement.data) == 1

    high_level_error = try
        plot_pie!(
            replacement,
            [987654321, 2],
        )
        nothing
    catch err
        err
    end
    @test high_level_error isa InvalidStateException
    @test high_level_error.state == :busy
    @test length(replacement.data) == 1

    legend_error = try
        set_legend!(
            replacement;
            position=:bottom,
            showlegend=true,
        )
        nothing
    catch err
        err
    end
    @test legend_error isa InvalidStateException
    @test legend_error.state == :busy
    @test !haskey(replacement.layout.fields, :legend)
    @test !haskey(replacement.layout.fields, :showlegend)

    singular_error = try
        add_trace!(
            replacement,
            scatter(y=[11], name="must-also-not-bypass"),
        )
        nothing
    catch err
        err
    end
    @test singular_error isa InvalidStateException
    @test singular_error.state == :busy
    @test length(replacement.data) == 1

    shape_error = try
        add_hline!(replacement, 5)
        nothing
    catch err
        err
    end
    @test shape_error isa InvalidStateException
    @test shape_error.state == :busy
    @test isempty(replacement.layout[:shapes])

    queued_task =
        @async relayout!(replacement; title="replacement-queued")
    for _ in 1:10
        yield()
    end
    @test !istaskdone(queued_task)
    @test !isready(state.entered)

    put!(state.release, nothing)
    second_script = take!(state.entered)
    @test occursin("Plotly.relayout", second_script)
    put!(state.release, nothing)
    @test fetch(react_task) === sp
    @test fetch(queued_task) === replacement
    @test sp.plot === replacement
    @test replacement.layout.fields[:title] == "replacement-queued"
    @test !haskey(
        PlotlySupply._PLOT_SYNCPLOT_RESERVATIONS,
        replacement,
    )
    close(sp)

    first, first_sp, first_state =
        _transaction_fixture(; register=true)
    second, second_sp, second_state =
        _transaction_fixture(; register=true)
    try
        first_mapping = PlotlySupply._PLOT_SYNCPLOT_MAP[first]
        second_mapping = PlotlySupply._PLOT_SYNCPLOT_MAP[second]
        caught = try
            react!(first_sp, second)
            nothing
        catch err
            err
        end
        @test caught isa InvalidStateException
        @test caught.state == :remapped
        @test isempty(first_state.scripts)
        @test isempty(second_state.scripts)
        @test first_sp.plot === first
        @test second_sp.plot === second
        @test PlotlySupply._PLOT_SYNCPLOT_MAP[first] === first_mapping
        @test PlotlySupply._PLOT_SYNCPLOT_MAP[second] === second_mapping
    finally
        close(first_sp)
        close(second_sp)
    end

    p, old_sp, old_state = _blocking_fixture()
    mutation_error = Ref{Any}(nothing)
    mutation_task = @async try
        restyle!(old_sp, 1; marker_size=12)
    catch err
        mutation_error[] = err
        nothing
    end
    take!(old_state.entered)

    new_state = _TransactionRendererState()
    new_sp = SyncPlot(
        p,
        nothing,
        :aba_replacement_window,
        "aba-replacement-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(new_state),
        ),
    )
    prior, registered =
        PlotlySupply._register_displayed_syncplot!(p, new_sp)
    @test prior === nothing
    @test registered
    close(new_sp)
    @test !haskey(PlotlySupply._PLOT_SYNCPLOT_MAP, p)

    put!(old_state.release, nothing)
    recovery_script = take!(old_state.entered)
    @test occursin("Plotly.newPlot", recovery_script)
    put!(old_state.release, nothing)
    @test fetch(mutation_task) === nothing
    @test mutation_error[] isa InvalidStateException
    @test mutation_error[].state == :remapped
    @test !haskey(p.data[1].fields, :marker)
    @test length(old_state.scripts) == 2
    close(old_sp)
end

@testset "purge serializes with later renderer mutations" begin
    p, sp, state = _blocking_fixture(; register=true)
    purge_task = @async purge!(p)
    purge_script = take!(state.entered)
    @test occursin("Plotly.purge(div);", purge_script)
    @test !isempty(p.data)

    relayout_task = @async relayout!(p; title="after-purge")
    for _ in 1:10
        yield()
    end
    @test !istaskdone(relayout_task)
    @test !isready(state.entered)

    put!(state.release, nothing)
    relayout_script = take!(state.entered)
    @test occursin("Plotly.relayout", relayout_script)
    put!(state.release, nothing)
    @test fetch(purge_task) === p
    @test fetch(relayout_task) === p
    @test isempty(p.data)
    @test p.layout.fields[:title] == "after-purge"
    close(sp)
end

@testset "compatibility layout updaters share the renderer lock" begin
    p, sp, state = _blocking_fixture()
    relayout_task =
        @async relayout!(sp; title="transaction-title")
    take!(state.entered)
    geo_task = @async update_geos!(sp; bgcolor="red")
    for _ in 1:10
        yield()
    end
    @test !istaskdone(geo_task)
    @test !isready(state.entered)

    put!(state.release, nothing)
    geo_script = take!(state.entered)
    @test occursin("Plotly.react", geo_script)
    @test occursin("\"bgcolor\":\"red\"", geo_script)
    put!(state.release, nothing)
    @test fetch(relayout_task) === sp
    @test fetch(geo_task) === sp
    @test p.layout.fields[:title] == "transaction-title"
    @test p.layout.fields[:geo][:bgcolor] == "red"
    close(sp)
end

@testset "layout vector updaters preserve public attribute identities" begin
    shared = attr(text="old-annotation")
    trace = scatter(y=[1])
    trace.fields[:meta] = shared
    frames = [
        frame(
            Dict{Symbol,Any}(
                :name => "shared-annotation-frame",
                :meta => shared,
            ),
        ),
    ]
    config = PlotConfig(
        toImageButtonOptions=Dict{Symbol,Any}(:meta => shared),
    )
    p = Plot(
        [trace],
        Layout(annotations=[shared]),
        frames;
        config=config,
    )
    data_root = p.data
    layout_root = p.layout
    frames_root = p.frames
    config_root = p.config
    state = _TransactionRendererState()
    sp = SyncPlot(
        p,
        nothing,
        :vector_updater_identity_window,
        "vector-updater-identity-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        @test update_annotations!(
            sp,
            attr(visible=false);
            opacity=0.25,
        ) === sp
        @test p.data === data_root
        @test p.layout === layout_root
        @test p.frames === frames_root
        @test p.config === config_root
        @test only(p.layout.annotations) === shared
        @test p.data[1].fields[:meta] === shared
        @test p.frames[1].fields[:meta] === shared
        @test p.config.toImageButtonOptions[:meta] === shared
        @test shared[:text] == "old-annotation"
        @test shared[:visible] == false
        @test shared[:opacity] == 0.25
        script = only(state.scripts)
        @test occursin("Plotly.newPlot", script)
        @test occursin("Plotly.addFrames", script)
        @test occursin("\"visible\":false", script)
        @test occursin("\"opacity\":0.25", script)
    finally
        close(sp)
    end

    shared = attr(text="rollback-annotation")
    trace = scatter(y=[1])
    trace.fields[:meta] = shared
    frames = [
        frame(
            Dict{Symbol,Any}(
                :name => "rollback-annotation-frame",
                :meta => shared,
            ),
        ),
    ]
    config = PlotConfig(
        toImageButtonOptions=Dict{Symbol,Any}(:meta => shared),
    )
    p = Plot(
        [trace],
        Layout(annotations=[shared]),
        frames;
        config=config,
    )
    data_root = p.data
    layout_root = p.layout
    frames_root = p.frames
    config_root = p.config
    primary = ErrorException("injected-vector-updater-failure")
    state = _TransactionRendererState(
        true,
        String[],
        Any[primary, "ok"],
    )
    sp = SyncPlot(
        p,
        nothing,
        :vector_updater_rollback_window,
        "vector-updater-rollback-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _transaction_backend(state),
        ),
    )
    try
        caught = try
            update_annotations!(
                sp,
                attr(visible=false);
                opacity=0.25,
            )
            nothing
        catch err
            err
        end
        @test caught === primary
        @test p.data === data_root
        @test p.layout === layout_root
        @test p.frames === frames_root
        @test p.config === config_root
        @test only(p.layout.annotations) === shared
        @test p.data[1].fields[:meta] === shared
        @test p.frames[1].fields[:meta] === shared
        @test p.config.toImageButtonOptions[:meta] === shared
        @test shared[:text] == "rollback-annotation"
        @test !haskey(shared, :visible)
        @test !haskey(shared, :opacity)
        @test length(state.scripts) == 2
        @test occursin("\"visible\":false", state.scripts[1])
        @test occursin("Plotly.newPlot", state.scripts[2])
        @test occursin("Plotly.addFrames", state.scripts[2])
        @test occursin("rollback-annotation", state.scripts[2])
        @test !occursin("\"visible\":false", state.scripts[2])
    finally
        close(sp)
    end
end

@testset "high-level composites wait before touching the live model" begin
    for operation in (:plot_pie, :set_legend)
        p, sp, state = _blocking_fixture()
        first_task =
            @async relayout!(sp; title="serialized-first")
        take!(state.entered)
        high_level_task = if operation === :plot_pie
            @async plot_pie!(sp, [13, 21])
        else
            @async set_legend!(
                sp;
                position=:bottom,
                showlegend=true,
            )
        end
        for _ in 1:10
            yield()
        end
        @test !istaskdone(high_level_task)
        @test !isready(state.entered)
        @test length(p.data) == 1
        @test !haskey(p.layout.fields, :showlegend)

        put!(state.release, nothing)
        high_level_script = take!(state.entered)
        if operation === :plot_pie
            @test occursin(
                "Plotly.addTraces",
                high_level_script,
            )
            @test occursin("13", high_level_script)
            @test occursin("21", high_level_script)
        else
            @test occursin(
                "Plotly.relayout",
                high_level_script,
            )
            @test occursin(
                "\"showlegend\":true",
                high_level_script,
            )
        end
        @test !occursin("Plotly.react", high_level_script)
        @test !occursin(
            "serialized-first",
            high_level_script,
        )
        put!(state.release, nothing)
        @test fetch(first_task) === sp
        expected = operation === :plot_pie ? nothing : sp
        @test fetch(high_level_task) === expected
        @test p.layout.fields[:title] == "serialized-first"
        if operation === :plot_pie
            @test length(p.data) == 2
        else
            @test p.layout.fields[:showlegend] == true
        end
        close(sp)
    end
end

@testset "subplot metadata commits do not overwrite unrelated state" begin
    state = _BlockingRendererState(
        true,
        String[],
        Channel{String}(4),
        Channel{Nothing}(4),
    )
    p = Plot(
        GenericTrace[],
        Layout(Subplots(rows=1, cols=2)),
    )
    sp = SyncPlot(
        p,
        nothing,
        :subplot_metadata_window,
        "subplot-metadata-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _blocking_backend(state),
        ),
    )
    sf = SubplotFigure(
        sp,
        1,
        2,
        1,
        1,
        true,
        :topright,
        (0.02, 0.03),
        "white",
        "black",
        1.0,
    )
    legend_task =
        @async subplot_legends!(sf; position=:bottom)
    take!(state.entered)
    selection_task = @async subplot!(sf, 1, 2)
    for _ in 1:10
        yield()
    end
    @test !istaskdone(selection_task)
    @test (sf.current_row, sf.current_col) == (1, 1)
    @test sf.legend_position == :topright

    put!(state.release, nothing)
    @test fetch(legend_task) === sf
    @test fetch(selection_task) === sf
    @test (sf.current_row, sf.current_col) == (1, 2)
    @test sf.legend_position == :bottom
    close(sp)

    state = _BlockingRendererState(
        true,
        String[],
        Channel{String}(4),
        Channel{Nothing}(4),
    )
    p = Plot(
        GenericTrace[],
        Layout(Subplots(rows=1, cols=2)),
    )
    sp = SyncPlot(
        p,
        nothing,
        :subplot_selection_window,
        "subplot-selection-div",
        PlotlySupply._SyncPlotResources(
            nothing,
            _blocking_backend(state),
        ),
    )
    sf = SubplotFigure(
        sp,
        1,
        2,
        1,
        1,
        true,
        :topright,
        (0.02, 0.03),
        "white",
        "black",
        1.0,
    )
    add_task = @async addtraces!(
        sf,
        scatter(x=[1, 2], y=[3, 4], name="implicit-cell"),
    )
    take!(state.entered)
    selection_task = @async subplot!(sf, 1, 2)
    for _ in 1:10
        yield()
    end
    @test !istaskdone(selection_task)
    @test (sf.current_row, sf.current_col) == (1, 1)

    put!(state.release, nothing)
    @test fetch(add_task) === sf
    @test fetch(selection_task) === sf
    @test (sf.current_row, sf.current_col) == (1, 2)
    @test length(p.data) == 1
    @test p.data[1].fields[:xaxis] == "x"
    @test p.data[1].fields[:yaxis] == "y"
    close(sp)
end

@testset "subplot legend defaults resolve after serialization" begin
    for operation in (:subplot_legends, :set_legend)
        state = _BlockingRendererState(
            true,
            String[],
            Channel{String}(4),
            Channel{Nothing}(4),
        )
        p = Plot(
            GenericTrace[],
            Layout(Subplots(rows=1, cols=1)),
        )
        add_trace!(
            p,
            scatter(x=[1, 2], y=[3, 4], name="legend-trace");
            row=1,
            col=1,
        )
        sp = SyncPlot(
            p,
            nothing,
            Symbol(operation, :_window),
            string(operation, "-div"),
            PlotlySupply._SyncPlotResources(
                nothing,
                _blocking_backend(state),
            ),
        )
        sf = SubplotFigure(
            sp,
            1,
            1,
            1,
            1,
            true,
            :topright,
            (0.02, 0.03),
            "white",
            "black",
            1.0,
        )

        first_task = operation === :subplot_legends ?
            @async(subplot_legends!(sf; position=:bottom)) :
            @async(set_legend!(sf; position=:bottom))
        first_script = take!(state.entered)
        @test occursin("\"yanchor\":\"bottom\"", first_script)

        second_task = operation === :subplot_legends ?
            @async(subplot_legends!(sf)) :
            @async(set_legend!(sf))
        for _ in 1:10
            yield()
        end
        @test !istaskdone(second_task)
        @test !isready(state.entered)

        put!(state.release, nothing)
        second_script = take!(state.entered)
        @test occursin("\"yanchor\":\"bottom\"", second_script)
        put!(state.release, nothing)
        @test fetch(first_task) === sf
        @test fetch(second_task) === sf
        @test sf.legend_position == :bottom
        close(sp)
    end
end
