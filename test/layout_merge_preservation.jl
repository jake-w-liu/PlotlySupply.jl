using Test
using PlotlySupply

_layout_merge_fields(value) =
    value isa AbstractDict ? value : value.fields

_layout_merge_layout_fields(target) =
    _layout_merge_fields(target.layout)

struct _LayoutMergeUnsafeKey
    value::Symbol
end

Base.Symbol(key::_LayoutMergeUnsafeKey) = key.value
Base.convert(
    ::Type{_LayoutMergeUnsafeKey},
    key::Symbol,
) = _LayoutMergeUnsafeKey(key)
Base.hash(key::_LayoutMergeUnsafeKey, seed::UInt) =
    hash(key.value, seed)
Base.isequal(
    left::_LayoutMergeUnsafeKey,
    right::_LayoutMergeUnsafeKey,
) = isequal(left.value, right.value)

mutable struct _LayoutMergeRejectingDict <:
               AbstractDict{Symbol,Any}
    data::Dict{Symbol,Any}
    reject_writes::Bool
end

Base.length(value::_LayoutMergeRejectingDict) =
    length(value.data)
Base.iterate(
    value::_LayoutMergeRejectingDict,
    state...,
) = iterate(value.data, state...)
Base.getindex(
    value::_LayoutMergeRejectingDict,
    key::Symbol,
) = value.data[key]
Base.get(
    value::_LayoutMergeRejectingDict,
    key::Symbol,
    default,
) = get(value.data, key, default)
function Base.setindex!(
    value::_LayoutMergeRejectingDict,
    item,
    key::Symbol,
)
    value.reject_writes &&
        error("test dictionary rejected a write")
    value.data[key] = item
    return item
end
Base.delete!(
    value::_LayoutMergeRejectingDict,
    key::Symbol,
) = delete!(value.data, key)
Base.empty!(value::_LayoutMergeRejectingDict) =
    (empty!(value.data); value)
Base.convert(
    ::Type{_LayoutMergeRejectingDict},
    value::Dict{Symbol,Any},
) = _LayoutMergeRejectingDict(value, false)

struct _LayoutMergeImmutableWrapperDict <:
       AbstractDict{Symbol,Any}
    data::Dict{Symbol,Any}
end

struct _LayoutMergeProjectionToken
    data::Dict{Symbol,Any}
end

Base.length(value::_LayoutMergeImmutableWrapperDict) =
    length(value.data)
Base.iterate(
    value::_LayoutMergeImmutableWrapperDict,
    state...,
) = iterate(value.data, state...)
Base.getindex(
    value::_LayoutMergeImmutableWrapperDict,
    key::Symbol,
) = value.data[key]
Base.get(
    value::_LayoutMergeImmutableWrapperDict,
    key::Symbol,
    default,
) = get(value.data, key, default)
Base.setindex!(
    value::_LayoutMergeImmutableWrapperDict,
    item,
    key::Symbol,
) = setindex!(value.data, item, key)
Base.delete!(
    value::_LayoutMergeImmutableWrapperDict,
    key::Symbol,
) = delete!(value.data, key)
Base.empty!(value::_LayoutMergeImmutableWrapperDict) =
    (empty!(value.data); value)

function _layout_merge_seed_cartesian_axis!(
    target,
    key::Symbol,
    text::String,
)
    axis = _layout_merge_fields(
        _layout_merge_layout_fields(target)[key],
    )
    axis[:title] = attr(
        text=text,
        font=attr(color="red", size=18),
    )
    axis[:tickfont] = attr(color="blue")
    axis[:showgrid] = false
    return axis
end

function _layout_merge_assert_cartesian_axis(
    target,
    key::Symbol,
    text::String,
)
    axis = _layout_merge_fields(
        _layout_merge_layout_fields(target)[key],
    )
    title = _layout_merge_fields(axis[:title])
    @test title[:text] == text
    @test _layout_merge_fields(title[:font])[:color] ==
          "red"
    @test _layout_merge_fields(title[:font])[:size] == 18
    @test _layout_merge_fields(axis[:tickfont])[:color] ==
          "blue"
    @test axis[:showgrid] === false
    return nothing
end

function _layout_merge_seed_polar!(target)
    layout = _layout_merge_layout_fields(target)
    haskey(layout, :polar) || (layout[:polar] = attr())
    polar = _layout_merge_fields(layout[:polar])
    polar[:radialaxis] = attr(
        range=[0, 9],
        tickfont=attr(color="red", size=14),
        title=attr(
            text="radius",
            font=attr(color="green"),
        ),
        linecolor="purple",
    )
    polar[:angularaxis] = attr(
        tickfont=attr(color="blue", size=13),
        rotation=25,
        linecolor="orange",
    )
    polar[:sector] = [0, 360]
    return haskey(polar, :domain) ?
           deepcopy(polar[:domain]) :
           nothing
end

function _layout_merge_assert_polar(
    target;
    expected_domain=nothing,
)
    polar = _layout_merge_fields(
        _layout_merge_layout_fields(target)[:polar],
    )
    radial = _layout_merge_fields(polar[:radialaxis])
    angular = _layout_merge_fields(polar[:angularaxis])
    radial_title = _layout_merge_fields(radial[:title])

    @test radial[:range] == [0, 5]
    @test radial[:showgrid] === false
    @test radial[:linecolor] == "purple"
    @test _layout_merge_fields(
        radial[:tickfont],
    )[:color] == "red"
    @test radial_title[:text] == "radius"
    @test _layout_merge_fields(
        radial_title[:font],
    )[:color] == "green"

    @test angular[:showgrid] === false
    @test angular[:rotation] == 25
    @test angular[:linecolor] == "orange"
    @test _layout_merge_fields(
        angular[:tickfont],
    )[:color] == "blue"
    @test polar[:sector] == [10, 200]
    expected_domain === nothing ||
        @test polar[:domain] == expected_domain
    return nothing
end

function _layout_merge_raw_map(kind::Symbol)
    if kind === :map
        return plot_scattermap(
            [0.0],
            [0.0];
            style="white-bg",
        )
    elseif kind === :mapbox
        return plot_scattermapbox(
            [0.0],
            [0.0];
            style="white-bg",
        )
    end
    throw(ArgumentError("unsupported map kind: $kind"))
end

function _layout_merge_subplot_map(kind::Symbol)
    return subplots(
        1,
        1;
        sync=false,
        show=false,
        per_subplot_legends=false,
        specs=fill(Spec(kind=String(kind)), 1, 1),
    )
end

function _layout_merge_seed_map_aliases!(
    target,
    kind::Symbol,
)
    layout = _layout_merge_layout_fields(target)
    root = layout[kind]
    root_fields = _layout_merge_fields(root)
    center = attr(lon=1.0, lat=2.0)
    root_fields[:style] = "white-bg"
    root_fields[:center] = center

    bounds = if kind === :map
        value = attr(
            west=-4.0,
            east=4.0,
            south=-3.0,
            north=3.0,
        )
        root_fields[:bounds] = value
        value
    else
        nothing
    end
    holder = Dict{Symbol,Any}(
        :root => root,
        :center => center,
    )
    bounds === nothing || (holder[:bounds] = bounds)
    layout[:meta] = holder
    return (
        root=root,
        center=center,
        bounds=bounds,
        holder=holder,
    )
end

function _layout_merge_append_map!(
    target,
    kind::Symbol,
    center_lat;
    subplot::Bool,
)
    if kind === :map
        if subplot
            return plot_scattermap!(
                target,
                [1.0],
                [2.0];
                center_lat=center_lat,
                row=1,
                col=1,
            )
        end
        return plot_scattermap!(
            target,
            [1.0],
            [2.0];
            center_lat=center_lat,
        )
    elseif kind === :mapbox
        if subplot
            return plot_scattermapbox!(
                target,
                [1.0],
                [2.0];
                center_lat=center_lat,
                row=1,
                col=1,
            )
        end
        return plot_scattermapbox!(
            target,
            [1.0],
            [2.0];
            center_lat=center_lat,
        )
    end
    throw(ArgumentError("unsupported map kind: $kind"))
end

function _layout_merge_update_map!(
    target,
    kind::Symbol,
    center_lat;
    subplot::Bool,
)
    if kind === :map
        if subplot
            return update_maps!(
                target;
                center_lat=center_lat,
                bounds_east=5.0,
                row=1,
                col=1,
            )
        end
        return update_maps!(
            target;
            center_lat=center_lat,
            bounds_east=5.0,
        )
    elseif kind === :mapbox
        if subplot
            return update_mapboxes!(
                target;
                center_lat=center_lat,
                row=1,
                col=1,
            )
        end
        return update_mapboxes!(
            target;
            center_lat=center_lat,
        )
    end
    throw(ArgumentError("unsupported map kind: $kind"))
end

function _layout_merge_assert_map_aliases(
    target,
    kind::Symbol,
    original;
    center_lat,
    bounds_east=4.0,
    expect_replacement::Bool=true,
)
    layout = _layout_merge_layout_fields(target)
    root = layout[kind]
    root_fields = _layout_merge_fields(root)
    holder = layout[:meta]
    center = root_fields[:center]

    @test root === holder[:root]
    @test center === holder[:center]
    if expect_replacement
        @test root !== original.root
        @test center !== original.center
        @test _layout_merge_fields(
            original.center,
        )[:lat] == 2.0
    end
    @test _layout_merge_fields(center)[:lon] == 1.0
    @test _layout_merge_fields(center)[:lat] == center_lat

    if kind === :map
        bounds = root_fields[:bounds]
        @test bounds === holder[:bounds]
        @test _layout_merge_fields(bounds)[:west] == -4.0
        @test _layout_merge_fields(bounds)[:east] ==
              bounds_east
    end
    return nothing
end

function _layout_merge_snapshot(
    target,
    kind::Symbol,
)
    layout = _layout_merge_layout_fields(target)
    root = layout[kind]
    root_fields = _layout_merge_fields(root)
    return (
        root=root,
        center=root_fields[:center],
        bounds=get(root_fields, :bounds, nothing),
        holder=layout[:meta],
        root_fields=deepcopy(root_fields),
        data_length=length(target.data),
        selection=target isa SubplotFigure ?
                  (target.current_row, target.current_col) :
                  nothing,
    )
end

function _layout_merge_assert_rollback(
    target,
    kind::Symbol,
    before,
)
    layout = _layout_merge_layout_fields(target)
    root = layout[kind]
    root_fields = _layout_merge_fields(root)
    @test root === before.root
    @test root_fields[:center] === before.center
    @test get(root_fields, :bounds, nothing) ===
          before.bounds
    @test layout[:meta] === before.holder
    @test root_fields == before.root_fields
    @test length(target.data) == before.data_length
    if target isa SubplotFigure
        @test (target.current_row, target.current_col) ==
              before.selection
    end
    return nothing
end

@testset "CRC: Cartesian partial layout merges preserve title styling" begin
    raw = plot_scatter([0.0], [0.0])
    _layout_merge_seed_cartesian_axis!(
        raw,
        :xaxis,
        "old-x",
    )
    _layout_merge_seed_cartesian_axis!(
        raw,
        :yaxis,
        "old-y",
    )
    @test plot_scatter!(
        raw,
        [1.0],
        [2.0];
        xlabel="raw-x",
        ylabel="raw-y",
    ) === nothing
    _layout_merge_assert_cartesian_axis(
        raw,
        :xaxis,
        "raw-x",
    )
    _layout_merge_assert_cartesian_axis(
        raw,
        :yaxis,
        "raw-y",
    )

    subplot = subplots(
        1,
        1;
        sync=false,
        show=false,
        per_subplot_legends=false,
    )
    xaxis = _layout_merge_seed_cartesian_axis!(
        subplot,
        :xaxis,
        "old-x",
    )
    yaxis = _layout_merge_seed_cartesian_axis!(
        subplot,
        :yaxis,
        "old-y",
    )
    xdomain = deepcopy(xaxis[:domain])
    ydomain = deepcopy(yaxis[:domain])

    @test plot_scatter!(
        subplot,
        [1.0],
        [2.0];
        xlabel="subplot-x",
        ylabel="subplot-y",
        row=1,
        col=1,
    ) === subplot
    _layout_merge_assert_cartesian_axis(
        subplot,
        :xaxis,
        "subplot-x",
    )
    _layout_merge_assert_cartesian_axis(
        subplot,
        :yaxis,
        "subplot-y",
    )
    @test _layout_merge_fields(
        _layout_merge_layout_fields(subplot)[:xaxis],
    )[:domain] == xdomain
    @test _layout_merge_fields(
        _layout_merge_layout_fields(subplot)[:yaxis],
    )[:domain] == ydomain

    @test xlabel!(
        subplot,
        "direct-x";
        row=1,
        col=1,
    ) === subplot
    @test ylabel!(
        subplot,
        "direct-y";
        row=1,
        col=1,
    ) === subplot
    _layout_merge_assert_cartesian_axis(
        subplot,
        :xaxis,
        "direct-x",
    )
    _layout_merge_assert_cartesian_axis(
        subplot,
        :yaxis,
        "direct-y",
    )
end

@testset "CRC: polar partial layout merges preserve axis siblings" begin
    raw = plot_scatterpolar([0.0], [1.0])
    _layout_merge_seed_polar!(raw)
    @test plot_scatterpolar!(
        raw,
        [10.0],
        [2.0];
        rrange=[0, 5],
        trange=[10, 200],
        grid=false,
    ) === nothing
    _layout_merge_assert_polar(raw)

    subplot = subplots(
        1,
        1;
        sync=false,
        show=false,
        per_subplot_legends=false,
        specs=fill(Spec(kind="polar"), 1, 1),
    )
    domain = _layout_merge_seed_polar!(subplot)
    @test plot_scatterpolar!(
        subplot,
        [10.0],
        [2.0];
        rrange=[0, 5],
        trange=[10, 200],
        grid=false,
        row=1,
        col=1,
    ) === subplot
    _layout_merge_assert_polar(
        subplot;
        expected_domain=domain,
    )
end

@testset "CRC: map partial merges preserve aliases and roll back" begin
    for kind in (:map, :mapbox)
        for subplot_case in (false, true)
            target = subplot_case ?
                     _layout_merge_subplot_map(kind) :
                     _layout_merge_raw_map(kind)
            original =
                _layout_merge_seed_map_aliases!(
                    target,
                    kind,
                )
            original_length = length(target.data)

            _layout_merge_append_map!(
                target,
                kind,
                3.0;
                subplot=subplot_case,
            )
            @test length(target.data) ==
                  original_length + 1
            _layout_merge_assert_map_aliases(
                target,
                kind,
                original;
                center_lat=3.0,
            )

            before_failed_append =
                _layout_merge_snapshot(target, kind)
            @test_throws ArgumentError _layout_merge_append_map!(
                target,
                kind,
                NaN;
                subplot=subplot_case,
            )
            _layout_merge_assert_rollback(
                target,
                kind,
                before_failed_append,
            )

            before_update =
                _layout_merge_snapshot(target, kind)
            _layout_merge_update_map!(
                target,
                kind,
                4.0;
                subplot=subplot_case,
            )
            _layout_merge_assert_map_aliases(
                target,
                kind,
                before_update;
                center_lat=4.0,
                bounds_east=5.0,
                expect_replacement=false,
            )

            before_failed_update =
                _layout_merge_snapshot(target, kind)
            @test_throws ArgumentError _layout_merge_update_map!(
                target,
                kind,
                NaN;
                subplot=subplot_case,
            )
            _layout_merge_assert_rollback(
                target,
                kind,
                before_failed_update,
            )
        end
    end

    for nested_key in (:center, :bounds)
        target = _layout_merge_raw_map(:map)
        original =
            _layout_merge_seed_map_aliases!(target, :map)
        original_nested = getproperty(original, nested_key)
        target.layout.fields[:meta] =
            Dict(:nested => original_nested)

        if nested_key === :center
            update_maps!(target; center_lat=6.0)
        else
            update_maps!(target; bounds_east=6.0)
        end

        root = _layout_merge_layout_fields(target)[:map]
        committed_nested =
            _layout_merge_fields(root)[nested_key]
        @test committed_nested ===
              target.layout.fields[:meta][:nested]
        @test committed_nested !== original_nested
        if nested_key === :center
            @test _layout_merge_fields(
                committed_nested,
            )[:lat] == 6.0
            @test _layout_merge_fields(
                original_nested,
            )[:lat] == 2.0
        else
            @test _layout_merge_fields(
                committed_nested,
            )[:east] == 6.0
            @test _layout_merge_fields(
                original_nested,
            )[:east] == 4.0
        end
    end
end

@testset "CRC: typed map aliases reject widening atomically" begin
    for kind in (:map, :mapbox)
        update! = kind === :map ? update_maps! : update_mapboxes!

        for make_storage in (
            () -> Dict{Symbol,Float64}(:zoom => 1.0),
            () -> IdDict{Symbol,Float64}(:zoom => 1.0),
        )
            target = _layout_merge_raw_map(kind)
            root = make_storage()
            holder = Dict{Symbol,Any}(:root => root)
            target.layout.fields[kind] = root
            target.layout.fields[:meta] = holder
            original_data_length = length(target.data)

            @test_throws ArgumentError update!(
                target;
                center_lon=2.0,
            )
            @test target.layout.fields[kind] === root
            @test target.layout.fields[:meta] === holder
            @test holder[:root] === root
            @test root == make_storage()
            @test length(target.data) ==
                  original_data_length
        end

        target = _layout_merge_raw_map(kind)
        center = Dict{Symbol,Float64}(
            :lon => 1.0,
            :lat => 2.0,
        )
        root = Dict{Symbol,Any}(
            :zoom => 1.0,
            :center => center,
        )
        holder = Dict{Symbol,Any}(:center => center)
        target.layout.fields[kind] = root
        target.layout.fields[:meta] = holder

        # `nothing` is a valid Plotly center value, but cannot be stored in
        # the narrow Float64 dictionary without replacing this aliased edge.
        @test_throws ArgumentError update!(
            target;
            center_lon=nothing,
        )
        @test target.layout.fields[kind] === root
        @test target.layout.fields[:meta] === holder
        @test root[:center] === center
        @test holder[:center] === center
        @test center == Dict{Symbol,Float64}(
            :lon => 1.0,
            :lat => 2.0,
        )
    end
end

@testset "CRC: representable typed map aliases retain topology" begin
    for kind in (:map, :mapbox)
        update! = kind === :map ? update_maps! : update_mapboxes!

        target = _layout_merge_raw_map(kind)
        original_root =
            Dict{Symbol,Float64}(:zoom => 1.0)
        target.layout.fields[kind] = original_root
        target.layout.fields[:meta] = original_root

        @test update!(target; zoom=2.0) === target
        committed_root = target.layout.fields[kind]
        @test committed_root ===
              target.layout.fields[:meta]
        @test committed_root !== original_root
        @test typeof(committed_root) ===
              typeof(original_root)
        @test committed_root[:zoom] == 2.0
        @test original_root[:zoom] == 1.0

        original_center = Dict{Symbol,Float64}(
            :lon => 1.0,
            :lat => 2.0,
        )
        original_root = Dict{Symbol,Any}(
            :zoom => 1.0,
            :center => original_center,
        )
        target.layout.fields[kind] = original_root
        target.layout.fields[:meta] = original_center

        @test update!(target; center_lon=3.0) === target
        committed_center = _layout_merge_fields(
            target.layout.fields[kind],
        )[:center]
        @test committed_center ===
              target.layout.fields[:meta]
        @test committed_center !== original_center
        @test typeof(committed_center) ===
              typeof(original_center)
        @test committed_center[:lon] == 3.0
        @test committed_center[:lat] == 2.0
        @test original_center[:lon] == 1.0
    end
end

@testset "CRC: multi-map preparation rolls back every root" begin
    for kind in (:map, :mapbox)
        layout = Layout()
        first = Dict{Symbol,Any}(:zoom => 1.0)
        narrow =
            Dict{Symbol,Float64}(:zoom => 2.0)
        second_key = Symbol(string(kind), "2")
        layout.fields[kind] = first
        layout.fields[second_key] = narrow

        if kind === :map
            @test_throws ArgumentError update_maps!(
                layout;
                center_lon=4.0,
            )
        else
            @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
                layout;
                center_lon=4.0,
            )
        end

        @test layout.fields[kind] === first
        @test layout.fields[second_key] === narrow
        @test first == Dict{Symbol,Any}(
            :zoom => 1.0,
        )
        @test narrow == Dict{Symbol,Float64}(
            :zoom => 2.0,
        )
    end

    layout = Layout()
    center = Dict{Symbol,Any}(
        :lon => 1.0,
        :lat => 2.0,
    )
    root = Dict{Symbol,Any}(
        :zoom => 1.0,
        :center => center,
    )
    layout.fields[:mapbox] = root
    @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
        layout;
        center_lon=NaN,
    )
    @test layout.fields[:mapbox] === root
    @test root[:center] === center
    @test center == Dict{Symbol,Any}(
        :lon => 1.0,
        :lat => 2.0,
    )
end

@testset "CRC: nested map preparation coalesces or rolls back" begin
    layout = Layout()
    center = Dict{Symbol,Any}(
        :lon => 1.0,
        :lat => 2.0,
    )
    bounds = Dict{Symbol,Float64}(
        :west => -4.0,
        :east => 4.0,
        :south => -3.0,
        :north => 3.0,
    )
    root = Dict{Symbol,Any}(
        :center => center,
        :bounds => bounds,
    )
    layout.fields[:map] = root

    @test_throws ArgumentError update_maps!(
        layout;
        center_lat=3.0,
        bounds_east=nothing,
    )
    @test layout.fields[:map] === root
    @test root[:center] === center
    @test root[:bounds] === bounds
    @test center[:lat] == 2.0
    @test bounds[:east] == 4.0

    layout = Layout()
    center = Dict{Symbol,Any}(
        :lon => 1.0,
        :lat => 2.0,
    )
    root =
        Dict{Symbol,Dict{Symbol,Any}}(:center => center)
    layout.fields[:map] = root
    @test_throws ArgumentError update_maps!(
        layout;
        center_lat=3.0,
        style="white-bg",
    )
    @test layout.fields[:map] === root
    @test root[:center] === center
    @test center[:lat] == 2.0
    @test !haskey(root, :style)

    for alias_shape in (:same_dict, :shared_fields, :attribute_fields)
        layout = Layout()
        shared = Dict{Symbol,Any}(
            :lon => 1.0,
            :lat => 2.0,
            :west => -4.0,
            :east => 4.0,
            :south => -3.0,
            :north => 3.0,
        )
        if alias_shape === :same_dict
            center_value = shared
            bounds_value = shared
        elseif alias_shape === :shared_fields
            attribute_type = typeof(attr())
            center_value = attribute_type(shared)
            bounds_value = attribute_type(shared)
        else
            center_value = typeof(attr())(shared)
            bounds_value = shared
        end
        root = Dict{Symbol,Any}(
            :center => center_value,
            :bounds => bounds_value,
        )
        layout.fields[:map] = root

        @test update_maps!(
            layout;
            center_lat=3.0,
            bounds_east=6.0,
        ) === layout
        @test root[:center] === center_value
        @test root[:bounds] === bounds_value
        @test _layout_merge_fields(center_value) === shared
        @test _layout_merge_fields(bounds_value) === shared
        @test shared[:lat] == 3.0
        @test shared[:east] == 6.0
    end

    layout = Layout()
    cyclic_root = Dict{Symbol,Any}()
    cyclic_root[:center] = cyclic_root
    layout.fields[:map] = cyclic_root
    @test update_maps!(layout; center_lat=3.0) ===
          layout
    @test cyclic_root[:center] === cyclic_root
    @test cyclic_root[:lat] == 3.0
end

@testset "CRC: heterogeneous String-key map storage stays String-keyed" begin
    for kind in (:map, :mapbox)
        layout = Layout()
        center = Dict{String,Float64}(
            "lon" => 1.0,
            "lat" => 2.0,
        )
        root = Dict{Any,Any}(
            "zoom" => 1.0,
            "center" => center,
        )
        layout.fields[kind] = root

        if kind === :map
            @test update_maps!(
                layout;
                center_lat=3.0,
                bearing=4.0,
            ) === layout
        else
            @test PlotlySupply._update_mapboxes_preserving_aliases!(
                layout;
                center_lat=3.0,
                bearing=4.0,
            ) === layout
        end

        @test layout.fields[kind] === root
        @test root["center"] === center
        @test center["lat"] == 3.0
        @test root["bearing"] == 4.0
        @test !haskey(root, :center)
        @test !haskey(root, :bearing)
    end
end

@testset "CRC: converted map values are revalidated before commit" begin
    for kind in (:map, :mapbox)
        layout = Layout()
        root =
            Dict{Symbol,Float32}(:zoom => 1.0f0)
        layout.fields[kind] = root

        if kind === :map
            @test_throws ArgumentError update_maps!(
                layout;
                zoom=1e100,
            )
        else
            @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
                layout;
                zoom=1e100,
            )
        end
        @test layout.fields[kind] === root
        @test root[:zoom] == 1.0f0
        @test isfinite(root[:zoom])

        center = Dict{Symbol,Float32}(
            :lon => 1.0f0,
            :lat => 2.0f0,
        )
        root = Dict{Symbol,Any}(:center => center)
        layout.fields[kind] = root
        if kind === :map
            @test_throws ArgumentError update_maps!(
                layout;
                center_lon=1e100,
            )
        else
            @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
                layout;
                center_lon=1e100,
            )
        end
        @test layout.fields[kind] === root
        @test root[:center] === center
        @test center[:lon] == 1.0f0
        @test isfinite(center[:lon])
    end

    # Exercise the public transactional path that previously committed Inf32.
    target = _layout_merge_raw_map(:mapbox)
    root = Dict{Symbol,Float32}(:zoom => 1.0f0)
    target.layout.fields[:mapbox] = root
    target.layout.fields[:meta] = root
    @test_throws ArgumentError update_mapboxes!(
        target;
        zoom=1e100,
    )
    @test target.layout.fields[:mapbox] === root
    @test target.layout.fields[:meta] === root
    @test root[:zoom] == 1.0f0
end

@testset "CRC: mapbox view validation is JSON-safe and atomic" begin
    huge = big(10)^1000
    for kwargs in (
        (; bearing=Inf),
        (; pitch=NaN),
        (; zoom=huge),
        (; center_lon=huge),
        (; center_lat=huge),
    )
        layout = Layout()
        root = attr(zoom=1.0)
        layout.fields[:mapbox] = root
        before = deepcopy(root.fields)

        @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
            layout;
            kwargs...,
        )
        @test layout.fields[:mapbox] === root
        @test root.fields == before
    end

    for malformed_center in (1, "invalid", [1, 2])
        layout = Layout()
        root = attr(
            center=malformed_center,
            zoom=1.0,
        )
        layout.fields[:mapbox] = root
        before = deepcopy(root.fields)

        @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
            layout;
            zoom=2.0,
        )
        @test layout.fields[:mapbox] === root
        @test root.fields == before
    end

    layout = Layout()
    root = Dict{Symbol,Float32}(:bearing => 0.0f0)
    layout.fields[:mapbox] = root
    @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
        layout;
        bearing=1e100,
    )
    @test layout.fields[:mapbox] === root
    @test root == Dict{Symbol,Float32}(
        :bearing => 0.0f0,
    )
end

@testset "CRC: cross-schema map aliases validate before commit" begin
    target = _layout_merge_raw_map(:mapbox)
    shared_root = target.layout.fields[:mapbox]
    target.layout.fields[:map] = shared_root
    before_root = deepcopy(
        _layout_merge_fields(shared_root),
    )
    before_data_length = length(target.data)

    @test_throws ArgumentError plot_scattermapbox!(
        target,
        [1.0],
        [2.0];
        style="",
    )
    @test length(target.data) == before_data_length
    @test target.layout.fields[:map] === shared_root
    @test target.layout.fields[:mapbox] === shared_root
    @test _layout_merge_fields(shared_root) ==
          before_root

    modern_root =
        Dict{Symbol,Any}(:style => "white-bg")
    legacy_root =
        Dict{Symbol,Any}(:center => modern_root)
    layout = Layout()
    layout.fields[:map] = modern_root
    layout.fields[:mapbox] = legacy_root
    modern_before = deepcopy(modern_root)

    @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
        layout,
        attr(center=attr(style="")),
    )
    @test layout.fields[:map] === modern_root
    @test layout.fields[:mapbox] === legacy_root
    @test legacy_root[:center] === modern_root
    @test modern_root == modern_before

    legacy_root = Dict{Symbol,Any}(
        :style => "white-bg",
        :bearing => 0.0,
    )
    modern_root = Dict{Symbol,Any}(
        :style => "white-bg",
        :center => legacy_root,
    )
    layout = Layout()
    layout.fields[:map] = modern_root
    layout.fields[:mapbox] = legacy_root
    legacy_before = deepcopy(legacy_root)

    @test_throws ArgumentError update_maps!(
        layout;
        center_bearing=Inf,
    )
    @test layout.fields[:map] === modern_root
    @test layout.fields[:mapbox] === legacy_root
    @test modern_root[:center] === legacy_root
    @test legacy_root == legacy_before

    for make_root in (
        (good, bad) -> Dict{Any,Any}(
            :style => "white-bg",
            :bounds => good,
            "bounds" => bad,
        ),
        (good, bad) -> IdDict{Any,Any}(
            :style => "white-bg",
            :bounds => good,
            "bounds" => bad,
        ),
    )
        bad = Dict{Symbol,Any}(:west => 0.0)
        good = Dict{Symbol,Any}(:west => 1.0)
        modern_root = make_root(good, bad)
        legacy_root =
            Dict{Symbol,Any}(:center => bad)
        layout = Layout()
        layout.fields[:map] = modern_root
        layout.fields[:mapbox] = legacy_root
        bad_before = deepcopy(bad)

        @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
            layout,
            attr(center=attr(west=NaN)),
        )
        @test layout.fields[:map] === modern_root
        @test layout.fields[:mapbox] === legacy_root
        @test legacy_root[:center] === bad
        @test bad == bad_before
    end

    for make_root in (
        bad -> Dict{Any,Any}(
            :style => "white-bg",
            _LayoutMergeUnsafeKey(:bounds) => bad,
        ),
        bad -> IdDict{Any,Any}(
            :style => "white-bg",
            _LayoutMergeUnsafeKey(:bounds) => bad,
        ),
    )
        bad = Dict{Symbol,Any}(:west => 0.0)
        modern_root = make_root(bad)
        legacy_root =
            Dict{Symbol,Any}(:center => bad)
        layout = Layout()
        layout.fields[:map] = modern_root
        layout.fields[:mapbox] = legacy_root
        bad_before = deepcopy(bad)

        @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
            layout,
            attr(center=attr(west=NaN)),
        )
        @test layout.fields[:map] === modern_root
        @test layout.fields[:mapbox] === legacy_root
        @test legacy_root[:center] === bad
        @test bad == bad_before
    end

    for make_root in (
        bad -> Dict{Any,Any}(
            :style => "white-bg",
            bad => :opaque,
        ),
        bad -> IdDict{Any,Any}(
            :style => "white-bg",
            bad => :opaque,
        ),
    )
        bad = Dict{Symbol,Any}(:west => 0.0)
        modern_root = make_root(bad)
        legacy_root =
            Dict{Symbol,Any}(:center => bad)
        layout = Layout()
        layout.fields[:map] = modern_root
        layout.fields[:mapbox] = legacy_root
        bad_before = deepcopy(bad)

        @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
            layout,
            attr(center=attr(west=NaN)),
        )
        @test layout.fields[:map] === modern_root
        @test layout.fields[:mapbox] === legacy_root
        @test legacy_root[:center] === bad
        @test bad == bad_before
    end
end

@testset "CRC: immutable map roots remain updateable" begin
    for make_original in (
        () -> Base.ImmutableDict(:zoom => 1.0),
        () -> Base.PersistentDict(:zoom => 1.0),
    )
        for kind in (:map, :mapbox)
            original = make_original()
            layout = Layout()
            layout.fields[kind] = original

            if kind === :map
                @test update_maps!(
                    layout;
                    bearing=2.0,
                ) === layout
            else
                @test PlotlySupply._update_mapboxes_preserving_aliases!(
                    layout;
                    bearing=2.0,
                ) === layout
            end

            committed =
                _layout_merge_fields(layout.fields[kind])
            @test layout.fields[kind] !== original
            @test Dict(original) == Dict(:zoom => 1.0)
            @test committed[:zoom] == 1.0
            @test committed[:bearing] == 2.0
        end
    end
end

@testset "CRC: hash-indexed mapping keys cannot be corrupted" begin
    for kind in (:map, :mapbox)
        root = Dict{Symbol,Any}(:zoom => 1.0)
        holder = Dict{Any,Any}(root => :held)
        layout = Layout()
        layout.fields[kind] = root
        layout.fields[:meta] = holder

        if kind === :map
            @test_throws ArgumentError update_maps!(
                layout;
                zoom=2.0,
            )
        else
            @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
                layout;
                zoom=2.0,
            )
        end
        @test layout.fields[kind] === root
        @test layout.fields[:meta] === holder
        @test root == Dict{Symbol,Any}(
            :zoom => 1.0,
        )
        @test haskey(holder, root)
        @test holder[root] === :held

        identity_root =
            Dict{Symbol,Any}(:zoom => 1.0)
        identity_holder =
            IdDict{Any,Any}(identity_root => :held)
        layout = Layout()
        layout.fields[kind] = identity_root
        layout.fields[:meta] = identity_holder

        if kind === :map
            @test update_maps!(
                layout;
                zoom=2.0,
            ) === layout
        else
            @test PlotlySupply._update_mapboxes_preserving_aliases!(
                layout;
                zoom=2.0,
            ) === layout
        end
        @test layout.fields[kind] === identity_root
        @test layout.fields[:meta] === identity_holder
        @test identity_root[:zoom] == 2.0
        @test haskey(identity_holder, identity_root)
        @test identity_holder[identity_root] === :held
    end
end

@testset "CRC: unsafe or ambiguous map keys are rejected atomically" begin
    for kind in (:map, :mapbox)
        for duplicate in (
            Dict{Any,Any}(
                :zoom => 1.0,
                "zoom" => 2.0,
            ),
            IdDict{Any,Any}(
                :zoom => 1.0,
                "zoom" => 2.0,
            ),
        )
            string_key = only(
                key for key in keys(duplicate)
                if key isa String
            )
            layout = Layout()
            layout.fields[kind] = duplicate
            if kind === :map
                @test_throws ArgumentError update_maps!(
                    layout;
                    bearing=3.0,
                )
            else
                @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
                    layout;
                    bearing=3.0,
                )
            end
            @test layout.fields[kind] === duplicate
            @test length(duplicate) == 2
            @test duplicate[:zoom] == 1.0
            @test duplicate[string_key] == 2.0
        end

        unsafe_key = _LayoutMergeUnsafeKey(:zoom)
        unsafe =
            Dict{_LayoutMergeUnsafeKey,Any}(
                unsafe_key => 1.0,
            )
        layout = Layout()
        layout.fields[kind] = unsafe
        if kind === :map
            @test_throws ArgumentError update_maps!(
                layout;
                bearing=3.0,
            )
        else
            @test_throws ArgumentError PlotlySupply._update_mapboxes_preserving_aliases!(
                layout;
                bearing=3.0,
            )
        end
        @test layout.fields[kind] === unsafe
        @test length(unsafe) == 1
        @test unsafe[unsafe_key] == 1.0
    end
end

@testset "CRC: unsupported outer storage cannot expose a partial commit" begin
    seed = _LayoutMergeRejectingDict(
        Dict{Symbol,Any}(),
        false,
    )
    layout =
        Layout{_LayoutMergeRejectingDict}(seed)
    root = Dict{Symbol,Any}(:zoom => 1.0)
    layout.fields.data[:map] = root
    layout.fields.data[:map2] = (zoom=2.0,)
    layout.fields.reject_writes = true

    @test_throws ArgumentError update_maps!(
        layout;
        center_lat=3.0,
    )
    @test layout.fields.data[:map] === root
    @test root == Dict{Symbol,Any}(:zoom => 1.0)
    @test layout.fields.data[:map2] ==
          (zoom=2.0,)
end

function _layout_merge_subplot(kind::Union{Nothing,Symbol}=nothing)
    if kind === nothing
        return subplots(
            1,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
        )
    end
    return subplots(
        1,
        1;
        sync=false,
        show=false,
        per_subplot_legends=false,
        specs=fill(Spec(kind=String(kind)), 1, 1),
    )
end

function _layout_merge_attach!(parent, key::Symbol, child)
    _layout_merge_fields(parent)[key] = child
    return child
end

function _layout_merge_assert_holder_path(
    holder,
    holder_key::Symbol,
    parent,
    parent_key::Symbol,
)
    child = _layout_merge_fields(parent)[parent_key]
    @test child === holder[holder_key]
    return child
end

@testset "CRC: public Cartesian merges retain external and internal aliases" begin
    external = _layout_merge_subplot()
    @test plot_scatter!(
        external,
        [0.0],
        [0.0],
    ) === external
    shared = external.layout.fields[:xaxis]
    external.data[1].fields[:meta] = shared

    @test plot_scatter!(
        external,
        [1.0],
        [2.0];
        xlabel="external-x",
    ) === external
    committed = external.layout.fields[:xaxis]
    @test external.data[1].fields[:meta] === committed
    committed_title =
        _layout_merge_fields(committed)[:title]
    @test _layout_merge_fields(
        committed_title,
    )[:text] == "external-x"

    for operation in (:xlabel, :scatter, :xrange)
        routed = _layout_merge_subplot()
        routed_axis = routed.layout.fields[:xaxis]
        routed_ref =
            routed.layout.subplots.grid_ref[1, 1][1]
        routed_ref.trace_kwargs.fields[:meta] =
            routed_axis

        if operation === :xlabel
            @test xlabel!(
                routed,
                "routed-direct",
            ) === routed
        elseif operation === :scatter
            @test plot_scatter!(
                routed,
                [1.0],
                [2.0];
                xlabel="routed-delegated",
            ) === routed
        else
            @test xrange!(
                routed,
                [1.0, 4.0],
            ) === routed
        end

        committed_ref =
            routed.layout.subplots.grid_ref[1, 1][1]
        committed_axis =
            routed.layout.fields[:xaxis]
        @test committed_ref.trace_kwargs.fields[
            :meta
        ] === committed_axis
        if operation === :xrange
            @test committed_axis[:range] ==
                  [1.0, 4.0]
        else
            expected = operation === :xlabel ?
                       "routed-direct" :
                       "routed-delegated"
            @test _layout_merge_fields(
                _layout_merge_fields(
                    committed_axis,
                )[:title],
            )[:text] == expected
        end
    end

    routed_noop = _layout_merge_subplot()
    @test plot_scatter!(
        routed_noop,
        [0.0],
        [0.0],
    ) === routed_noop
    noop_axis =
        Dict{Symbol,Any}(:showgrid => false)
    routed_noop.layout.fields[:xaxis] = noop_axis
    noop_ref =
        routed_noop.layout.subplots.grid_ref[1, 1][1]
    noop_ref.trace_kwargs.fields[:meta] =
        noop_axis
    noop_subplots = routed_noop.layout.subplots
    noop_ref.trace_kwargs.fields[:trace] =
        routed_noop.data[1]
    noop_ref.trace_kwargs.fields[:layout] =
        routed_noop.layout
    noop_axis[:back] = noop_subplots
    routed_noop.data[1].fields[:axis] =
        noop_axis
    noop_fields = routed_noop.layout.fields
    @test relayout!(
        routed_noop;
        xaxis_showgrid=false,
    ) === routed_noop
    @test routed_noop.layout.fields[:xaxis] ===
          noop_axis
    @test routed_noop.layout.subplots ===
          noop_subplots
    @test routed_noop.layout.fields ===
          noop_fields
    @test routed_noop.layout.subplots.grid_ref[1, 1][
        1
    ].trace_kwargs.fields[:meta] === noop_axis
    @test routed_noop.layout.subplots.grid_ref[1, 1][
        1
    ].trace_kwargs.fields[:trace] ===
          routed_noop.data[1]
    @test routed_noop.layout.subplots.grid_ref[1, 1][
        1
    ].trace_kwargs.fields[:layout] ===
          routed_noop.layout
    @test routed_noop.data[1].fields[:axis] ===
          noop_axis
    @test noop_axis[:back] === noop_subplots

    for operation in (:direct, :delegated)
        cyclic = _layout_merge_subplot()
        @test plot_scatter!(
            cyclic,
            [0.0],
            [0.0],
        ) === cyclic
        cyclic_layout = cyclic.layout
        cyclic_axis =
            cyclic_layout.fields[:xaxis]
        cyclic_subplots = cyclic_layout.subplots
        cyclic_ref =
            cyclic_subplots.grid_ref[1, 1][1]
        cyclic_ref.trace_kwargs.fields[:axis] =
            cyclic_axis
        cyclic_ref.trace_kwargs.fields[:layout] =
            cyclic_layout
        cyclic_axis[:back] = cyclic_subplots
        cyclic.data[1].fields[:axis] =
            cyclic_axis
        old_length = length(cyclic.data)

        if operation === :direct
            @test xlabel!(
                cyclic,
                "cyclic-direct",
            ) === cyclic
        else
            @test plot_scatter!(
                cyclic,
                [1.0],
                [2.0];
                xlabel="cyclic-delegated",
            ) === cyclic
        end

        committed_axis =
            cyclic.layout.fields[:xaxis]
        committed_subplots =
            cyclic.layout.subplots
        committed_ref =
            committed_subplots.grid_ref[1, 1][1]
        @test cyclic.layout === cyclic_layout
        @test length(cyclic.data) ==
              old_length +
              (operation === :delegated)
        @test committed_ref.trace_kwargs.fields[
            :axis
        ] === committed_axis
        @test committed_ref.trace_kwargs.fields[
            :layout
        ] === cyclic.layout
        @test committed_axis[:back] ===
              committed_subplots
        @test cyclic.data[1].fields[:axis] ===
              committed_axis
        expected = operation === :direct ?
                   "cyclic-direct" :
                   "cyclic-delegated"
        @test _layout_merge_fields(
            _layout_merge_fields(
                committed_axis,
            )[:title],
        )[:text] == expected
    end

    incremental = _layout_merge_subplot()
    @test plot_scatter!(
        incremental,
        [0.0],
        [0.0],
    ) === incremental
    incremental_axis =
        incremental.layout.fields[:xaxis]
    incremental_axis[:showgrid] = false
    incremental_subplots =
        incremental.layout.subplots
    incremental_ref =
        incremental_subplots.grid_ref[1, 1][1]
    incremental_ref.trace_kwargs.fields[
        :axis
    ] = incremental_axis
    incremental_ref.trace_kwargs.fields[
        :trace
    ] = incremental.data[1]
    incremental_axis[:back] =
        incremental_subplots
    incremental.data[1].fields[:axis] =
        incremental_axis
    token_storage =
        Dict{Symbol,Any}(:value => 1)
    token =
        _LayoutMergeProjectionToken(
            token_storage,
        )
    incremental_ref.trace_kwargs.fields[
        :token
    ] = token
    incremental.data[1].fields[:token] =
        token
    @test relayout!(
        incremental;
        xaxis_showgrid=true,
    ) === incremental
    committed_incremental_axis =
        incremental.layout.fields[:xaxis]
    committed_incremental_subplots =
        incremental.layout.subplots
    committed_incremental_ref =
        committed_incremental_subplots.grid_ref[
            1,
            1,
        ][1]
    @test committed_incremental_ref.trace_kwargs.fields[
        :axis
    ] === committed_incremental_axis
    @test committed_incremental_ref.trace_kwargs.fields[
        :trace
    ] === incremental.data[1]
    @test incremental.data[1].fields[:axis] ===
          committed_incremental_axis
    @test committed_incremental_axis[:back] ===
          committed_incremental_subplots
    @test incremental.data[1].fields[:token] ===
          token
    @test committed_incremental_ref.trace_kwargs.fields[
        :token
    ] === token
    @test committed_incremental_ref.trace_kwargs.fields[
        :token
    ].data === token_storage

    for make_immutable in (
        () -> Base.ImmutableDict(
            :showgrid => false,
        ),
        () -> Base.PersistentDict(
            :showgrid => false,
        ),
    )
        immutable_alias = _layout_merge_subplot()
        immutable_axis = make_immutable()
        immutable_alias.layout.fields[:xaxis] =
            immutable_axis
        immutable_alias.layout.fields[:meta] =
            Dict{Symbol,Any}(
                :axis => immutable_axis,
            )
        @test xlabel!(
            immutable_alias,
            "immutable-replacement",
        ) === immutable_alias
        @test immutable_alias.layout.fields[
            :xaxis
        ] !== immutable_axis
        @test Dict(
            immutable_alias.layout.fields[
                :meta
            ][:axis],
        ) == Dict(immutable_axis)
        @test Dict(immutable_axis) ==
              Dict(:showgrid => false)
        @test immutable_alias.layout.fields[
            :xaxis
        ][:title_text] ==
              "immutable-replacement"
    end

    delegated = _layout_merge_subplot()
    old_xaxis = delegated.layout.fields[:xaxis]
    old_yaxis = delegated.layout.fields[:yaxis]
    @test plot_scatter!(
        delegated,
        [0.0],
        [1.0];
        xlabel="delegated-x",
        ylabel="delegated-y",
    ) === delegated
    @test delegated.layout.fields[:xaxis] !==
          old_xaxis
    @test delegated.layout.fields[:yaxis] !==
          old_yaxis
    @test delegated.layout.fields[:xaxis][
        :title_text
    ] == "delegated-x"
    @test delegated.layout.fields[:yaxis][
        :title_text
    ] == "delegated-y"

    nested_direct = _layout_merge_subplot()
    nested_direct_root =
        nested_direct.layout.fields[:xaxis]
    nested_direct_title = attr(
        text="old-direct",
        font=attr(color="red"),
    )
    _layout_merge_fields(nested_direct_root)[
        :title
    ] = nested_direct_title
    nested_direct.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :title => nested_direct_title,
        )
    @test xlabel!(
        nested_direct,
        "nested-direct",
    ) === nested_direct
    committed_nested_direct =
        nested_direct.layout.fields[:xaxis]
    committed_nested_direct_title =
        _layout_merge_fields(
            committed_nested_direct,
        )[:title]
    @test committed_nested_direct_title ===
          nested_direct.layout.fields[:meta][:title]
    @test _layout_merge_fields(
        committed_nested_direct_title,
    )[:text] == "nested-direct"
    @test _layout_merge_fields(
        committed_nested_direct_title,
    )[:font][:color] == "red"

    nested_delegated = _layout_merge_subplot()
    nested_delegated_root =
        nested_delegated.layout.fields[:xaxis]
    nested_delegated_title = attr(
        text="old-delegated",
        font=attr(color="blue"),
    )
    _layout_merge_fields(nested_delegated_root)[
        :title
    ] = nested_delegated_title
    nested_delegated.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :title => nested_delegated_title,
        )
    @test plot_scatter!(
        nested_delegated,
        [0.0],
        [1.0];
        xlabel="nested-delegated",
    ) === nested_delegated
    committed_nested_delegated =
        nested_delegated.layout.fields[:xaxis]
    committed_nested_delegated_title =
        _layout_merge_fields(
            committed_nested_delegated,
        )[:title]
    @test committed_nested_delegated_title ===
          nested_delegated.layout.fields[
              :meta
          ][:title]
    @test _layout_merge_fields(
        committed_nested_delegated_title,
    )[:text] == "nested-delegated"
    @test _layout_merge_fields(
        committed_nested_delegated_title,
    )[:font][:color] == "blue"

    direct = _layout_merge_subplot()
    direct_root = direct.layout.fields[:xaxis]
    direct.layout.fields[:meta] =
        Dict{Symbol,Any}(:axis => direct_root)
    @test xlabel!(direct, "direct-alias-x") === direct
    @test direct.layout.fields[:xaxis] ===
          direct.layout.fields[:meta][:axis]
    direct_title = _layout_merge_fields(
        direct.layout.fields[:xaxis],
    )[:title]
    @test _layout_merge_fields(
        direct_title,
    )[:text] == "direct-alias-x"

    compatibility = _layout_merge_subplot()
    @test xlabel!(
        compatibility,
        "flattened-x",
    ) === compatibility
    @test compatibility.layout.fields[:xaxis][
        :title_text
    ] == "flattened-x"

    plain_ranges = _layout_merge_subplot()
    plain_xaxis = plain_ranges.layout.fields[:xaxis]
    plain_yaxis = plain_ranges.layout.fields[:yaxis]
    @test xrange!(
        plain_ranges,
        [0.0, 2.0],
    ) === plain_ranges
    @test yrange!(
        plain_ranges,
        [-1.0, 3.0],
    ) === plain_ranges
    @test plain_ranges.layout.fields[:xaxis] !==
          plain_xaxis
    @test plain_ranges.layout.fields[:yaxis] !==
          plain_yaxis
    @test plain_ranges.layout.fields[:xaxis][
        :range
    ] == [0.0, 2.0]
    @test plain_ranges.layout.fields[:yaxis][
        :range
    ] == [-1.0, 3.0]

    aliased_range = _layout_merge_subplot()
    aliased_range_root =
        aliased_range.layout.fields[:xaxis]
    aliased_range.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :axis => aliased_range_root,
        )
    @test xrange!(
        aliased_range,
        [1.0, 4.0],
    ) === aliased_range
    committed_aliased_range =
        aliased_range.layout.fields[:xaxis]
    @test committed_aliased_range ===
          aliased_range.layout.fields[:meta][:axis]
    @test committed_aliased_range[:range] ==
          [1.0, 4.0]

    custom_range = _layout_merge_subplot()
    custom_range_root = _LayoutMergeRejectingDict(
        Dict{Symbol,Any}(:showgrid => false),
        false,
    )
    custom_range.layout.fields[:xaxis] =
        custom_range_root
    @test xrange!(
        custom_range,
        [2.0, 5.0],
    ) === custom_range
    @test custom_range.layout.fields[:xaxis] !==
          custom_range_root
    @test custom_range.layout.fields[:xaxis][
        :range
    ] == [2.0, 5.0]
    @test custom_range_root.data ==
          Dict{Symbol,Any}(:showgrid => false)

    custom_alias = _layout_merge_subplot()
    custom_root = _LayoutMergeRejectingDict(
        Dict{Symbol,Any}(:showgrid => false),
        false,
    )
    custom_alias.layout.fields[:xaxis] = custom_root
    custom_alias.layout.fields[:meta] =
        Dict{Symbol,Any}(:axis => custom_root)
    @test_throws ArgumentError xlabel!(
        custom_alias,
        "must-not-split",
    )
    @test custom_alias.layout.fields[:xaxis] ===
          custom_root
    @test custom_alias.layout.fields[:meta][:axis] ===
          custom_root
    @test custom_root.data ==
          Dict{Symbol,Any}(:showgrid => false)

    custom_backing_alias = _layout_merge_subplot()
    backing_root = _LayoutMergeRejectingDict(
        Dict{Symbol,Any}(:showgrid => false),
        false,
    )
    custom_backing_alias.layout.fields[:xaxis] =
        backing_root
    custom_backing_alias.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :backing => backing_root.data,
        )
    @test_throws ArgumentError xlabel!(
        custom_backing_alias,
        "must-not-split-backing",
    )
    @test custom_backing_alias.layout.fields[
        :xaxis
    ] === backing_root
    @test custom_backing_alias.layout.fields[
        :meta
    ][:backing] === backing_root.data
    @test backing_root.data ==
          Dict{Symbol,Any}(:showgrid => false)

    for operation in (:xlabel, :scatter, :xrange)
        immutable_wrapper = _layout_merge_subplot()
        wrapper_root =
            _LayoutMergeImmutableWrapperDict(
                Dict{Symbol,Any}(
                    :showgrid => false,
                ),
            )
        immutable_wrapper.layout.fields[:xaxis] =
            wrapper_root
        immutable_wrapper.layout.fields[:meta] =
            Dict{Symbol,Any}(
                :axis => wrapper_root,
                :backing => wrapper_root.data,
            )
        data_length = length(immutable_wrapper.data)

        if operation === :xlabel
            @test_throws ArgumentError xlabel!(
                immutable_wrapper,
                "immutable-wrapper",
            )
        elseif operation === :scatter
            @test_throws ArgumentError plot_scatter!(
                immutable_wrapper,
                [1.0],
                [2.0];
                xlabel="immutable-wrapper",
            )
        else
            @test_throws ArgumentError xrange!(
                immutable_wrapper,
                [1.0, 2.0],
            )
        end

        @test length(immutable_wrapper.data) ==
              data_length
        @test immutable_wrapper.layout.fields[
            :xaxis
        ] === wrapper_root
        @test immutable_wrapper.layout.fields[
            :meta
        ][:axis] === wrapper_root
        @test immutable_wrapper.layout.fields[
            :meta
        ][:backing] === wrapper_root.data
        @test wrapper_root.data ==
              Dict{Symbol,Any}(
                  :showgrid => false,
              )
    end

    immutable_nested = _layout_merge_subplot()
    immutable_nested_root = attr(showgrid=false)
    immutable_nested_title =
        _LayoutMergeImmutableWrapperDict(
            Dict{Symbol,Any}(
                :text => "old-immutable-title",
            ),
        )
    immutable_nested_root.fields[:title] =
        immutable_nested_title
    immutable_nested.layout.fields[:xaxis] =
        immutable_nested_root
    immutable_nested.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :title => immutable_nested_title,
            :backing => immutable_nested_title.data,
        )
    @test_throws ArgumentError xlabel!(
        immutable_nested,
        "must-not-split-immutable-title",
    )
    @test immutable_nested.layout.fields[
        :xaxis
    ] === immutable_nested_root
    @test immutable_nested_root.fields[:title] ===
          immutable_nested_title
    @test immutable_nested.layout.fields[
        :meta
    ][:title] === immutable_nested_title
    @test immutable_nested.layout.fields[
        :meta
    ][:backing] === immutable_nested_title.data
    @test immutable_nested_title.data[:text] ==
          "old-immutable-title"

    custom_unaliased = _layout_merge_subplot()
    unaliased_root = _LayoutMergeRejectingDict(
        Dict{Symbol,Any}(:showgrid => false),
        false,
    )
    custom_unaliased.layout.fields[:xaxis] =
        unaliased_root
    @test xlabel!(
        custom_unaliased,
        "custom-replacement",
    ) === custom_unaliased
    @test custom_unaliased.layout.fields[:xaxis] !==
          unaliased_root
    @test custom_unaliased.layout.fields[:xaxis][
        :title_text
    ] == "custom-replacement"
    @test unaliased_root.data ==
          Dict{Symbol,Any}(:showgrid => false)

    custom_attribute_alias = _layout_merge_subplot()
    custom_attribute = PlotlyBase.PlotlyAttribute(
        _LayoutMergeRejectingDict(
            Dict{Symbol,Any}(:showgrid => false),
            false,
        ),
    )
    custom_attribute_alias.layout.fields[:xaxis] =
        custom_attribute
    custom_attribute_alias.layout.fields[:meta] =
        Dict{Symbol,Any}(:axis => custom_attribute)
    @test_throws ArgumentError xlabel!(
        custom_attribute_alias,
        "must-not-split-attribute",
    )
    @test custom_attribute_alias.layout.fields[
        :xaxis
    ] === custom_attribute
    @test custom_attribute_alias.layout.fields[
        :meta
    ][:axis] === custom_attribute

    custom_attribute_unaliased =
        _layout_merge_subplot()
    replacement_attribute =
        PlotlyBase.PlotlyAttribute(
            _LayoutMergeRejectingDict(
                Dict{Symbol,Any}(
                    :showgrid => false,
                ),
                false,
            ),
        )
    custom_attribute_unaliased.layout.fields[
        :xaxis
    ] = replacement_attribute
    @test xlabel!(
        custom_attribute_unaliased,
        "attribute-replacement",
    ) === custom_attribute_unaliased
    @test custom_attribute_unaliased.layout.fields[
        :xaxis
    ] !== replacement_attribute
    @test custom_attribute_unaliased.layout.fields[
        :xaxis
    ][:title_text] == "attribute-replacement"

    custom_title_unaliased = _layout_merge_subplot()
    custom_title_root = attr(showgrid=false)
    custom_title = _LayoutMergeRejectingDict(
        Dict{Symbol,Any}(
            :text => "old-custom-title",
        ),
        false,
    )
    custom_title_root.fields[:title] =
        custom_title
    custom_title_unaliased.layout.fields[:xaxis] =
        custom_title_root
    @test xlabel!(
        custom_title_unaliased,
        "new-custom-title",
    ) === custom_title_unaliased
    committed_custom_title_root =
        custom_title_unaliased.layout.fields[
            :xaxis
        ]
    @test committed_custom_title_root.fields[
        :title
    ] !==
          custom_title
    @test committed_custom_title_root[
        :title_text
    ] ==
          "new-custom-title"
    @test custom_title.data[:text] ==
          "old-custom-title"

    custom_title_alias = _layout_merge_subplot()
    aliased_title_root = attr(showgrid=false)
    aliased_custom_title =
        _LayoutMergeRejectingDict(
            Dict{Symbol,Any}(
                :text => "old-aliased-title",
            ),
            false,
        )
    aliased_title_root.fields[:title] =
        aliased_custom_title
    custom_title_alias.layout.fields[:xaxis] =
        aliased_title_root
    custom_title_alias.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :title => aliased_custom_title,
        )
    @test_throws ArgumentError xlabel!(
        custom_title_alias,
        "must-not-split-custom-title",
    )
    @test custom_title_alias.layout.fields[
        :xaxis
    ] === aliased_title_root
    @test aliased_title_root.fields[:title] ===
          aliased_custom_title
    @test custom_title_alias.layout.fields[
        :meta
    ][:title] === aliased_custom_title
    @test aliased_custom_title.data[:text] ==
          "old-aliased-title"

    custom_title_backing_alias =
        _layout_merge_subplot()
    backing_title_root = attr(showgrid=false)
    backing_custom_title =
        _LayoutMergeRejectingDict(
            Dict{Symbol,Any}(
                :text => "old-backing-title",
            ),
            false,
        )
    backing_title_root.fields[:title] =
        backing_custom_title
    custom_title_backing_alias.layout.fields[
        :xaxis
    ] = backing_title_root
    custom_title_backing_alias.layout.fields[
        :meta
    ] = Dict{Symbol,Any}(
        :backing => backing_custom_title.data,
    )
    @test_throws ArgumentError xlabel!(
        custom_title_backing_alias,
        "must-not-split-title-backing",
    )
    @test custom_title_backing_alias.layout.fields[
        :xaxis
    ] === backing_title_root
    @test backing_title_root.fields[:title] ===
          backing_custom_title
    @test custom_title_backing_alias.layout.fields[
        :meta
    ][:backing] === backing_custom_title.data
    @test backing_custom_title.data[:text] ==
          "old-backing-title"

    named_title_alias = _layout_merge_subplot()
    named_title = Dict{Symbol,Any}(
        :text => "old-named-title",
        :font => attr(color="purple"),
    )
    named_root = (
        title=named_title,
        showgrid=false,
    )
    named_title_alias.layout.fields[:xaxis] =
        named_root
    named_title_alias.layout.fields[:meta] =
        Dict{Symbol,Any}(:title => named_title)
    @test xlabel!(
        named_title_alias,
        "new-named-title",
    ) === named_title_alias
    @test named_title_alias.layout.fields[:xaxis] !==
          named_root
    committed_named_title =
        _layout_merge_fields(
            named_title_alias.layout.fields[
                :xaxis
            ],
        )[:title]
    @test committed_named_title ===
          named_title_alias.layout.fields[:meta][
              :title
          ]
    @test _layout_merge_fields(
        committed_named_title,
    )[:text] == "new-named-title"
    @test named_title[:text] == "old-named-title"

    named_root_alias = _layout_merge_subplot()
    immutable_root = (
        showgrid=false,
        label="nonbits",
    )
    named_root_alias.layout.fields[:xaxis] =
        immutable_root
    named_root_alias.layout.fields[:meta] =
        Dict{Symbol,Any}(:axis => immutable_root)
    @test xlabel!(
        named_root_alias,
        "named-root-replacement",
    ) === named_root_alias
    @test named_root_alias.layout.fields[:xaxis] !==
          immutable_root
    @test named_root_alias.layout.fields[:xaxis][
        :title_text
    ] == "named-root-replacement"
    @test named_root_alias.layout.fields[:meta][
        :axis
    ] === immutable_root

    no_label_custom = _layout_merge_subplot()
    no_label_x = _LayoutMergeRejectingDict(
        Dict{Symbol,Any}(:showgrid => false),
        false,
    )
    no_label_y = _LayoutMergeRejectingDict(
        Dict{Symbol,Any}(:showgrid => false),
        false,
    )
    no_label_custom.layout.fields[:xaxis] =
        no_label_x
    no_label_custom.layout.fields[:yaxis] =
        no_label_y
    no_label_custom.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :xaxis => no_label_x,
            :yaxis => no_label_y,
        )
    @test plot_scatter!(
        no_label_custom,
        [0.0],
        [1.0],
    ) === no_label_custom
    @test length(no_label_custom.data) == 1
    @test no_label_custom.layout.fields[:xaxis] ===
          no_label_x
    @test no_label_custom.layout.fields[:yaxis] ===
          no_label_y
    @test no_label_custom.layout.fields[:meta][
        :xaxis
    ] === no_label_x
    @test no_label_custom.layout.fields[:meta][
        :yaxis
    ] === no_label_y

    internal = _layout_merge_subplot()
    internal.layout.fields[:yaxis] =
        internal.layout.fields[:xaxis]
    @test plot_scatter!(
        internal,
        [1.0],
        [2.0];
        xlabel="X",
        ylabel="Y",
    ) === internal
    @test internal.layout.fields[:xaxis] ===
          internal.layout.fields[:yaxis]
    shared_title = _layout_merge_fields(
        internal.layout.fields[:xaxis],
    )[:title]
    # Both layout keys intentionally name one storage node. Updates therefore
    # coalesce in Cartesian traversal order, with the later y update winning.
    @test _layout_merge_fields(shared_title)[:text] ==
          "Y"
end

@testset "CRC: recursive geographic and polar aliases stay connected" begin
    geographic = _layout_merge_subplot(:geo)
    geo = geographic.layout.fields[:geo]
    projection = attr()
    rotation = attr(lon=10.0)
    projection.fields[:type] = "equirectangular"
    projection.fields[:rotation] = rotation
    _layout_merge_attach!(geo, :projection, projection)
    geographic.layout.fields[:meta] = Dict{Symbol,Any}(
        :root => geo,
        :projection => projection,
        :rotation => rotation,
    )

    @test plot_scattergeo!(
        geographic,
        [0.0],
        [1.0];
        scope="world",
        projection="mercator",
    ) === geographic
    geo_holder = geographic.layout.fields[:meta]
    committed_geo = geographic.layout.fields[:geo]
    @test committed_geo === geo_holder[:root]
    committed_projection =
        _layout_merge_assert_holder_path(
            geo_holder,
            :projection,
            committed_geo,
            :projection,
        )
    @test _layout_merge_fields(
        committed_projection,
    )[:type] == "mercator"
    @test _layout_merge_fields(
        committed_projection,
    )[:rotation] === geo_holder[:rotation]
    @test _layout_merge_fields(committed_geo)[:scope] ==
          "world"

    polar = _layout_merge_subplot(:polar)
    polar_root = polar.layout.fields[:polar]
    shared_axis = attr()
    axis_title = attr(
        text="radius",
        font=attr(color="red"),
    )
    shared_axis.fields[:title] = axis_title
    shared_axis.fields[:linecolor] = "purple"
    _layout_merge_attach!(
        polar_root,
        :radialaxis,
        shared_axis,
    )
    _layout_merge_attach!(
        polar_root,
        :angularaxis,
        shared_axis,
    )
    polar.layout.fields[:meta] = Dict{Symbol,Any}(
        :root => polar_root,
        :axis => shared_axis,
        :title => axis_title,
    )

    @test plot_scatterpolar!(
        polar,
        [0.0, 90.0],
        [1.0, 2.0];
        rrange=[0.0, 5.0],
        grid=false,
    ) === polar
    polar_holder = polar.layout.fields[:meta]
    committed_polar = polar.layout.fields[:polar]
    @test committed_polar === polar_holder[:root]
    radial = _layout_merge_assert_holder_path(
        polar_holder,
        :axis,
        committed_polar,
        :radialaxis,
    )
    angular = _layout_merge_assert_holder_path(
        polar_holder,
        :axis,
        committed_polar,
        :angularaxis,
    )
    @test radial === angular
    @test _layout_merge_fields(radial)[:title] ===
          polar_holder[:title]
    @test _layout_merge_fields(radial)[:range] ==
          [0.0, 5.0]
    @test _layout_merge_fields(radial)[:showgrid] ===
          false
    @test _layout_merge_fields(radial)[:linecolor] ==
          "purple"
end

@testset "CRC: scene, font, and coloraxis aliases merge recursively" begin
    scene_figure = _layout_merge_subplot(:scene)
    scene = scene_figure.layout.fields[:scene]
    xaxis = attr()
    axis_title = attr()
    title_font = attr(color="red")
    axis_title.fields[:text] = "old-x"
    axis_title.fields[:font] = title_font
    xaxis.fields[:title] = axis_title
    xaxis.fields[:showgrid] = true
    _layout_merge_attach!(scene, :xaxis, xaxis)

    camera = attr()
    projection = attr(type="perspective")
    camera.fields[:projection] = projection
    _layout_merge_attach!(scene, :camera, camera)

    font = Dict{Symbol,Any}(
        :family => "monospace",
        :size => 10,
    )
    coloraxis = Dict{Symbol,Any}(:cmin => 0.0)
    scene_figure.layout.fields[:font] = font
    scene_figure.layout.fields[:coloraxis] = coloraxis
    scene_figure.layout.fields[:meta] = Dict{Symbol,Any}(
        :scene => scene,
        :xaxis => xaxis,
        :title => axis_title,
        :title_font => title_font,
        :camera => camera,
        :projection => projection,
        :font => font,
        :coloraxis => coloraxis,
    )

    z = [1.0 2.0; 3.0 4.0]
    @test plot_surface!(
        scene_figure,
        z;
        xlabel="surface-x",
        fontsize=21,
        shared_coloraxis=true,
        colorscale="Viridis",
    ) === scene_figure
    holder = scene_figure.layout.fields[:meta]
    committed_scene = scene_figure.layout.fields[:scene]
    @test committed_scene === holder[:scene]
    committed_xaxis = _layout_merge_assert_holder_path(
        holder,
        :xaxis,
        committed_scene,
        :xaxis,
    )
    committed_title = _layout_merge_assert_holder_path(
        holder,
        :title,
        committed_xaxis,
        :title,
    )
    @test _layout_merge_fields(committed_title)[:text] ==
          "surface-x"
    @test _layout_merge_fields(committed_title)[:font] ===
          holder[:title_font]
    @test scene_figure.layout.fields[:font] ===
          holder[:font]
    @test holder[:font][:family] == "monospace"
    @test holder[:font][:size] == 21
    @test scene_figure.layout.fields[:coloraxis] ===
          holder[:coloraxis]
    @test holder[:coloraxis][:cmin] == 0.0
    @test holder[:coloraxis][:colorscale] == "Viridis"

    @test plot_scatter3d!(
        scene_figure,
        [0.0, 1.0],
        [0.0, 1.0],
        [0.0, 1.0];
        perspective=false,
    ) === scene_figure
    holder = scene_figure.layout.fields[:meta]
    committed_scene = scene_figure.layout.fields[:scene]
    @test committed_scene === holder[:scene]
    committed_camera = _layout_merge_assert_holder_path(
        holder,
        :camera,
        committed_scene,
        :camera,
    )
    committed_projection =
        _layout_merge_assert_holder_path(
            holder,
            :projection,
            committed_camera,
            :projection,
        )
    @test _layout_merge_fields(
        committed_projection,
    )[:type] == "orthographic"
end

@testset "CRC: ternary title aliases merge recursively" begin
    ternary_figure = _layout_merge_subplot(:ternary)
    ternary = ternary_figure.layout.fields[:ternary]
    shared_axis = attr()
    title = attr()
    title_font = attr(color="green")
    title.fields[:text] = "old"
    title.fields[:font] = title_font
    shared_axis.fields[:title] = title
    shared_axis.fields[:tickfont] = attr(color="blue")
    _layout_merge_attach!(
        ternary,
        :aaxis,
        shared_axis,
    )
    _layout_merge_attach!(
        ternary,
        :baxis,
        shared_axis,
    )
    ternary_figure.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :root => ternary,
            :axis => shared_axis,
            :title => title,
            :font => title_font,
        )

    @test plot_ternary!(
        ternary_figure,
        [0.2, 0.3],
        [0.3, 0.3],
        [0.5, 0.4];
        alabel="shared",
        blabel="shared",
    ) === ternary_figure
    holder = ternary_figure.layout.fields[:meta]
    committed = ternary_figure.layout.fields[:ternary]
    @test committed === holder[:root]
    aaxis = _layout_merge_assert_holder_path(
        holder,
        :axis,
        committed,
        :aaxis,
    )
    baxis = _layout_merge_assert_holder_path(
        holder,
        :axis,
        committed,
        :baxis,
    )
    @test aaxis === baxis
    committed_title = _layout_merge_assert_holder_path(
        holder,
        :title,
        aaxis,
        :title,
    )
    @test _layout_merge_fields(committed_title)[:text] ==
          "shared"
    @test _layout_merge_fields(committed_title)[:font] ===
          holder[:font]
end

@testset "CRC: scalar title shorthand preserves nested styling" begin
    heatmap_figure = _layout_merge_subplot()
    xaxis = heatmap_figure.layout.fields[:xaxis]
    title = attr()
    title_font = attr(color="red", size=17)
    title.fields[:text] = "old"
    title.fields[:font] = title_font
    _layout_merge_attach!(xaxis, :title, title)
    heatmap_figure.layout.fields[:meta] =
        Dict{Symbol,Any}(
            :xaxis => xaxis,
            :title => title,
            :font => title_font,
        )

    @test plot_heatmap!(
        heatmap_figure,
        [0.0, 1.0],
        [0.0, 1.0],
        [1.0 2.0; 3.0 4.0];
        xlabel="heat-x",
    ) === heatmap_figure
    holder = heatmap_figure.layout.fields[:meta]
    committed_xaxis = heatmap_figure.layout.fields[:xaxis]
    @test committed_xaxis === holder[:xaxis]
    committed_title = _layout_merge_assert_holder_path(
        holder,
        :title,
        committed_xaxis,
        :title,
    )
    @test _layout_merge_fields(committed_title)[:text] ==
          "heat-x"
    @test _layout_merge_fields(committed_title)[:font] ===
          holder[:font]
    @test _layout_merge_fields(holder[:font])[:color] ==
          "red"
end

@testset "CRC: non-map preparation rejects atomically" begin
    trace = scatter(x=[0.0], y=[0.0])
    trace.fields[:xaxis] = "x"
    trace.fields[:yaxis] = "y"

    target_layout = Layout()
    xaxis = Dict{Symbol,Any}(:showgrid => false)
    yaxis = Dict{Symbol,Float64}(:tick0 => 0.0)
    target_layout.fields[:xaxis] = xaxis
    target_layout.fields[:yaxis] = yaxis
    holder = Dict{Symbol,Any}(
        :xaxis => xaxis,
        :yaxis => yaxis,
    )
    target_layout.fields[:meta] = holder
    target = Plot([trace], target_layout)

    source_layout = Layout()
    source_layout.fields[:xaxis] =
        attr(title_text="prepared-x")
    source_layout.fields[:yaxis] =
        attr(title_text="unrepresentable-y")
    source = Plot(
        Vector{GenericTrace}(undef, 0),
        source_layout,
    )
    xaxis_before = deepcopy(xaxis)
    yaxis_before = copy(yaxis)

    @test_throws ArgumentError PlotlySupply._apply_source_layout_to_added_traces!(
        target,
        source,
        1,
    )
    @test target.layout.fields[:xaxis] === xaxis
    @test target.layout.fields[:yaxis] === yaxis
    @test target.layout.fields[:meta] === holder
    @test holder[:xaxis] === xaxis
    @test holder[:yaxis] === yaxis
    @test xaxis == xaxis_before
    @test yaxis == yaxis_before

    ambiguous = Dict{Any,Any}(
        :showgrid => true,
        "showgrid" => false,
    )
    target.layout.fields[:xaxis] = ambiguous
    target.layout.fields[:yaxis] =
        Dict{Symbol,Any}(:tick0 => 0.0)
    holder[:xaxis] = ambiguous
    holder[:yaxis] =
        target.layout.fields[:yaxis]
    ambiguous_before = copy(ambiguous)

    @test_throws ArgumentError PlotlySupply._apply_source_layout_to_added_traces!(
        target,
        source,
        1,
    )
    @test target.layout.fields[:xaxis] === ambiguous
    @test ambiguous == ambiguous_before
end
