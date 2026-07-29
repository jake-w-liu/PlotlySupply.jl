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
