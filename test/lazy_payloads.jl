using Test
using PlotlySupply

_lazy_payload_json(value) =
    PlotlyBase.JSON.json(value; allownan=true)

function _test_lazy_payload_reference(stored, original)
    @test stored === original
    @test _lazy_payload_json(stored) ==
          _lazy_payload_json(collect(original))
    return nothing
end

function _append_large_lazy_subplot!(
    sf::SubplotFigure,
    payload::AbstractRange,
)
    return plot_scatter!(sf, payload, payload)
end

@testset "CRC: large payloads stay lazy" begin
    lazy_x = reinterpret(
        Float64,
        UInt64[
            0x3ff0000000000000,
            0x4000000000000000,
        ],
    )
    lazy_y = reinterpret(
        Float64,
        UInt64[
            0x4008000000000000,
            0x4010000000000000,
            0x4014000000000000,
        ],
    )
    matrix_parent = reshape(collect(1.0:6.0), 3, 2)
    lazy_matrix = PermutedDimsArray(matrix_parent, (2, 1))

    @testset "matrix traces accept lazy arrays" begin
        for (constructor, mutator) in (
            (plot_heatmap, plot_heatmap!),
            (plot_contour, plot_contour!),
        )
            explicit = constructor(lazy_x, lazy_y, lazy_matrix)
            trace = only(explicit.data)
            _test_lazy_payload_reference(trace.fields[:x], lazy_x)
            _test_lazy_payload_reference(trace.fields[:y], lazy_y)
            @test parent(trace.fields[:z]) === lazy_matrix
            @test _lazy_payload_json(trace.fields[:z]) ==
                  _lazy_payload_json(collect(trace.fields[:z]))

            implicit = constructor(lazy_matrix)
            implicit_trace = only(implicit.data)
            @test implicit_trace.fields[:x] isa AbstractRange
            @test implicit_trace.fields[:y] isa AbstractRange
            @test implicit_trace.fields[:x] == 0:1
            @test implicit_trace.fields[:y] == 0:2
            @test parent(implicit_trace.fields[:z]) === lazy_matrix

            target = Plot()
            @test mutator(
                target,
                lazy_x,
                lazy_y,
                lazy_matrix,
            ) === nothing
            mutated_trace = only(target.data)
            _test_lazy_payload_reference(
                mutated_trace.fields[:x],
                lazy_x,
            )
            _test_lazy_payload_reference(
                mutated_trace.fields[:y],
                lazy_y,
            )
            @test parent(mutated_trace.fields[:z]) === lazy_matrix

            implicit_target = Plot()
            @test mutator(
                implicit_target,
                lazy_matrix,
            ) === nothing
            implicit_mutated_trace = only(implicit_target.data)
            @test implicit_mutated_trace.fields[:x] isa AbstractRange
            @test implicit_mutated_trace.fields[:y] isa AbstractRange
            @test parent(implicit_mutated_trace.fields[:z]) ===
                  lazy_matrix

            subplot_figure = subplots(
                1,
                1;
                sync=false,
                show=false,
            )
            @test mutator(
                subplot_figure,
                lazy_x,
                lazy_y,
                lazy_matrix,
            ) === subplot_figure
            subplot_trace = only(subplot_figure.data)
            _test_lazy_payload_reference(
                subplot_trace.fields[:x],
                lazy_x,
            )
            @test parent(subplot_trace.fields[:z]) === lazy_matrix
        end

        color_parent = reshape(collect(7.0:12.0), 2, 3)
        lazy_color = @view color_parent[:, :]
        surface_plot = plot_surface(
            lazy_matrix,
            lazy_matrix,
            lazy_matrix;
            surfacecolor=lazy_color,
        )
        surface_trace = only(surface_plot.data)
        for field in (:x, :y, :z)
            _test_lazy_payload_reference(
                surface_trace.fields[field],
                lazy_matrix,
            )
        end
        _test_lazy_payload_reference(
            surface_trace.fields[:surfacecolor],
            lazy_color,
        )

        implicit_surface = plot_surface(lazy_matrix)
        implicit_surface_trace = only(implicit_surface.data)
        @test implicit_surface_trace.fields[:x] isa AbstractRange
        @test implicit_surface_trace.fields[:y] isa AbstractRange
        _test_lazy_payload_reference(
            implicit_surface_trace.fields[:z],
            lazy_matrix,
        )

        surface_target = Plot()
        @test plot_surface!(
            surface_target,
            lazy_matrix;
            color=lazy_color,
        ) === nothing
        mutated_surface = only(surface_target.data)
        @test mutated_surface.fields[:x] isa AbstractRange
        @test mutated_surface.fields[:y] isa AbstractRange
        _test_lazy_payload_reference(
            mutated_surface.fields[:z],
            lazy_matrix,
        )
        _test_lazy_payload_reference(
            mutated_surface.fields[:surfacecolor],
            lazy_color,
        )

        scene_subplot = subplots(
            1,
            1;
            sync=false,
            show=false,
            specs=fill(Spec(kind="scene"), 1, 1),
        )
        @test plot_surface!(
            scene_subplot,
            lazy_matrix;
            surfacecolor=lazy_color,
        ) === scene_subplot
        subplot_surface = only(scene_subplot.data)
        @test subplot_surface.fields[:x] isa AbstractRange
        _test_lazy_payload_reference(
            subplot_surface.fields[:z],
            lazy_matrix,
        )
        _test_lazy_payload_reference(
            subplot_surface.fields[:surfacecolor],
            lazy_color,
        )

        # The old signatures admitted matrix views through their broad
        # `SubArray` arm. Keep that dispatch compatibility while widening
        # ordinary vectors and arrays.
        matrix_view = @view matrix_parent[:, :]
        @test applicable(
            plot_heatmap,
            matrix_view,
            lazy_y,
            lazy_matrix,
        )
        @test applicable(
            plot_contour,
            matrix_view,
            lazy_y,
            lazy_matrix,
        )
        @test applicable(
            plot_mesh3d,
            matrix_view,
            matrix_view,
            matrix_view,
        )
        @test applicable(
            plot_isosurface,
            matrix_view,
            matrix_view,
            matrix_view,
            matrix_view,
        )
        @test applicable(
            plot_volume,
            matrix_view,
            matrix_view,
            matrix_view,
            matrix_view,
        )
        @test applicable(
            plot_waterfall,
            matrix_view,
            matrix_view,
        )

        cartesian_dispatch_subplot = subplots(
            1,
            1;
            sync=false,
            show=false,
        )
        @test applicable(
            plot_waterfall!,
            cartesian_dispatch_subplot,
            matrix_view,
            matrix_view,
        )
        scene_dispatch_subplot = subplots(
            1,
            1;
            sync=false,
            show=false,
            specs=fill(Spec(kind="scene"), 1, 1),
        )
        @test applicable(
            plot_mesh3d!,
            scene_dispatch_subplot,
            matrix_view,
            matrix_view,
            matrix_view,
        )
        @test applicable(
            plot_isosurface!,
            scene_dispatch_subplot,
            matrix_view,
            matrix_view,
            matrix_view,
            matrix_view,
        )
        @test applicable(
            plot_volume!,
            scene_dispatch_subplot,
            matrix_view,
            matrix_view,
            matrix_view,
            matrix_view,
        )
    end

    @testset "extended traces retain caller payloads" begin
        labels_parent = ["root", "left", "right"]
        labels = @view labels_parent[:]
        parents_parent = ["", "root", "root"]
        parents = @view parents_parent[:]
        values_parent = [3.0, 1.0, 2.0]
        values = @view values_parent[:]
        colors_parent = [0.5, 0.25, 0.75]
        colors = @view colors_parent[:]
        lazy_values = reinterpret(
            Float64,
            UInt64[
                0x4008000000000000,
                0x3ff0000000000000,
                0x4000000000000000,
            ],
        )
        lazy_colors = reinterpret(
            Float64,
            UInt64[
                0x3fe0000000000000,
                0x3fd0000000000000,
                0x3fe8000000000000,
            ],
        )

        pie_plot = plot_pie(values; labels=labels)
        pie_trace = only(pie_plot.data)
        _test_lazy_payload_reference(
            pie_trace.fields[:values],
            values,
        )
        _test_lazy_payload_reference(
            pie_trace.fields[:labels],
            labels,
        )
        pie_target = Plot()
        @test plot_pie!(
            pie_target,
            values;
            labels=labels,
        ) === nothing
        _test_lazy_payload_reference(
            only(pie_target.data).fields[:values],
            values,
        )

        for (constructor, mutator) in (
            (plot_sunburst, plot_sunburst!),
            (plot_treemap, plot_treemap!),
        )
            hierarchy_plot = constructor(
                labels,
                parents;
                values=values,
                colors=colors,
            )
            hierarchy_trace = only(hierarchy_plot.data)
            for (field, payload) in (
                (:labels, labels),
                (:parents, parents),
                (:values, values),
            )
                _test_lazy_payload_reference(
                    hierarchy_trace.fields[field],
                    payload,
                )
            end
            _test_lazy_payload_reference(
                hierarchy_trace.fields[:marker][:colors],
                colors,
            )

            hierarchy_target = Plot()
            @test mutator(
                hierarchy_target,
                labels,
                parents;
                values=values,
                colors=colors,
            ) === nothing
            _test_lazy_payload_reference(
                only(hierarchy_target.data).fields[:values],
                values,
            )
        end

        derived_colors = plot_sunburst(
            labels,
            parents;
            values=values,
            colorscale="Viridis",
        )
        derived_trace = only(derived_colors.data)
        @test derived_trace.fields[:marker][:colors] === values

        funnelarea_plot = plot_funnelarea(
            values;
            labels=labels,
        )
        funnelarea_trace = only(funnelarea_plot.data)
        _test_lazy_payload_reference(
            funnelarea_trace.fields[:values],
            values,
        )
        _test_lazy_payload_reference(
            funnelarea_trace.fields[:labels],
            labels,
        )
        funnelarea_target = Plot()
        @test plot_funnelarea!(
            funnelarea_target,
            values;
            labels=labels,
        ) === nothing
        _test_lazy_payload_reference(
            only(funnelarea_target.data).fields[:values],
            values,
        )
        _test_lazy_payload_reference(
            only(funnelarea_target.data).fields[:labels],
            labels,
        )

        measure_parent = [
            "relative",
            "relative",
            "total",
        ]
        measure = @view measure_parent[:]
        waterfall_plot = plot_waterfall(
            labels,
            lazy_values;
            measure=measure,
        )
        waterfall_trace = only(waterfall_plot.data)
        for (field, payload) in (
            (:x, labels),
            (:y, lazy_values),
            (:measure, measure),
        )
            _test_lazy_payload_reference(
                waterfall_trace.fields[field],
                payload,
            )
        end
        waterfall_target = Plot()
        @test plot_waterfall!(
            waterfall_target,
            labels,
            lazy_values;
            measure=measure,
        ) === nothing
        _test_lazy_payload_reference(
            only(waterfall_target.data).fields[:y],
            lazy_values,
        )
        _test_lazy_payload_reference(
            only(waterfall_target.data).fields[:measure],
            measure,
        )

        source = reinterpret(
            Int64,
            UInt64[0x0000000000000000, 0x0000000000000001],
        )
        target = reinterpret(
            Int64,
            UInt64[0x0000000000000001, 0x0000000000000002],
        )
        links = @view values_parent[1:2]
        node_labels = @view labels_parent[1:3]
        sankey_plot = plot_sankey(
            source,
            target,
            links;
            label=node_labels,
        )
        sankey_trace = only(sankey_plot.data)
        _test_lazy_payload_reference(
            sankey_trace.fields[:node][:label],
            node_labels,
        )
        for (field, payload) in (
            (:source, source),
            (:target, target),
            (:value, links),
        )
            _test_lazy_payload_reference(
                sankey_trace.fields[:link][field],
                payload,
            )
        end
        sankey_target = Plot()
        @test plot_sankey!(
            sankey_target,
            source,
            target,
            links;
            label=node_labels,
        ) === nothing
        _test_lazy_payload_reference(
            only(sankey_target.data).fields[:link][:value],
            links,
        )

        dimensions = ["value" => values, "color" => colors]
        parcoords_plot = plot_parcoords(
            dimensions;
            line_color=colors,
        )
        parcoords_trace = only(parcoords_plot.data)
        _test_lazy_payload_reference(
            parcoords_trace.fields[:dimensions][1][:values],
            values,
        )
        _test_lazy_payload_reference(
            parcoords_trace.fields[:line][:color],
            colors,
        )
        parcoords_target = Plot()
        @test plot_parcoords!(
            parcoords_target,
            dimensions;
            line_color=colors,
        ) === nothing
        _test_lazy_payload_reference(
            only(parcoords_target.data).fields[:line][:color],
            colors,
        )

        stateful_plot = plot_parcoords(
            ["stateful" => Iterators.Stateful(1:3)],
        )
        stateful_dimension =
            only(stateful_plot.data).fields[:dimensions][1]
        @test stateful_dimension[:values] isa Vector
        @test stateful_dimension[:values] == [1, 2, 3]

        mesh_plot = plot_mesh3d(
            lazy_values,
            lazy_colors,
            lazy_values;
            intensity=lazy_colors,
        )
        mesh_trace = only(mesh_plot.data)
        for (field, payload) in (
            (:x, lazy_values),
            (:y, lazy_colors),
            (:z, lazy_values),
            (:intensity, lazy_colors),
        )
            _test_lazy_payload_reference(
                mesh_trace.fields[field],
                payload,
            )
        end
        mesh_target = Plot()
        @test plot_mesh3d!(
            mesh_target,
            lazy_values,
            lazy_colors,
            lazy_values;
            intensity=lazy_colors,
        ) === nothing
        _test_lazy_payload_reference(
            only(mesh_target.data).fields[:intensity],
            lazy_colors,
        )

        for (constructor, mutator) in (
            (plot_isosurface, plot_isosurface!),
            (plot_volume, plot_volume!),
        )
            field_plot = constructor(
                lazy_values,
                lazy_colors,
                lazy_values,
                lazy_colors,
            )
            field_trace = only(field_plot.data)
            for (field, payload) in (
                (:x, lazy_values),
                (:y, lazy_colors),
                (:z, lazy_values),
                (:value, lazy_colors),
            )
                _test_lazy_payload_reference(
                    field_trace.fields[field],
                    payload,
                )
            end

            field_target = Plot()
            @test mutator(
                field_target,
                lazy_values,
                lazy_colors,
                lazy_values,
                lazy_colors,
            ) === nothing
            _test_lazy_payload_reference(
                only(field_target.data).fields[:value],
                lazy_colors,
            )
        end

        scene_specs = fill(Spec(kind="scene"), 1, 3)
        scene_subplot = subplots(
            1,
            3;
            sync=false,
            show=false,
            specs=scene_specs,
        )
        @test plot_mesh3d!(
            scene_subplot,
            lazy_values,
            lazy_colors,
            lazy_values;
            intensity=lazy_colors,
            row=1,
            col=1,
        ) === scene_subplot
        @test plot_isosurface!(
            scene_subplot,
            lazy_values,
            lazy_colors,
            lazy_values,
            lazy_colors;
            row=1,
            col=2,
        ) === scene_subplot
        @test plot_volume!(
            scene_subplot,
            lazy_values,
            lazy_colors,
            lazy_values,
            lazy_colors;
            row=1,
            col=3,
        ) === scene_subplot
        _test_lazy_payload_reference(
            scene_subplot.data[1].fields[:intensity],
            lazy_colors,
        )
        _test_lazy_payload_reference(
            scene_subplot.data[2].fields[:value],
            lazy_colors,
        )
        _test_lazy_payload_reference(
            scene_subplot.data[3].fields[:value],
            lazy_colors,
        )

        waterfall_subplot = subplots(
            1,
            1;
            sync=false,
            show=false,
        )
        @test plot_waterfall!(
            waterfall_subplot,
            labels,
            lazy_values;
            measure=measure,
        ) === waterfall_subplot
        _test_lazy_payload_reference(
            only(waterfall_subplot.data).fields[:y],
            lazy_values,
        )
        _test_lazy_payload_reference(
            only(waterfall_subplot.data).fields[:measure],
            measure,
        )

        live_values = [1.0, 2.0]
        live_plot = plot_pie(live_values)
        live_values[1] = 9.0
        @test only(live_plot.data).fields[:values][1] == 9.0
    end

    @testset "error-bar arrays are shared without flattening" begin
        x = 1:3
        series = [
            [1.0, 2.0, 3.0],
            [3.0, 2.0, 1.0],
        ]
        flat_parent = [0.1, 0.2, 0.3]
        flat = @view flat_parent[:]
        nested_parent = [
            [0.3, 0.2, 0.1],
            [0.4, 0.5, 0.6],
        ]
        nested = [
            @view(nested_parent[1][:]),
            @view(nested_parent[2][:]),
        ]

        error_plot = plot_scatter(
            x,
            series;
            error_x=flat,
            error_y=nested,
        )
        @test length(error_plot.data) == 2
        for (index, trace) in enumerate(error_plot.data)
            _test_lazy_payload_reference(
                trace.fields[:error_x][:array],
                flat,
            )
            _test_lazy_payload_reference(
                trace.fields[:error_y][:array],
                nested[index],
            )
        end

        error_target = Plot()
        @test plot_scatter!(
            error_target,
            x,
            series;
            error_x=flat,
            error_y=nested,
        ) === nothing
        for (index, trace) in enumerate(error_target.data)
            _test_lazy_payload_reference(
                trace.fields[:error_x][:array],
                flat,
            )
            _test_lazy_payload_reference(
                trace.fields[:error_y][:array],
                nested[index],
            )
        end
    end

    @testset "million-element constructors stay allocation bounded" begin
        payload = 1:1_000_000
        field = reshape(payload, length(payload), 1)
        measure = fill("relative", length(payload))
        dimensions = ["a" => payload, "b" => payload]
        constructors = (
            () -> plot_pie(payload; labels=payload),
            () -> plot_scatter(
                payload,
                payload;
                error_x=payload,
                error_y=payload,
            ),
            () -> plot_heatmap(field),
            () -> plot_contour(field),
            () -> plot_surface(field),
            () -> plot_sunburst(
                payload,
                payload;
                values=payload,
                colors=payload,
            ),
            () -> plot_sunburst(
                payload,
                payload;
                values=payload,
                colorscale="Viridis",
            ),
            () -> plot_funnelarea(payload; labels=payload),
            () -> plot_waterfall(
                payload,
                payload;
                measure=measure,
            ),
            () -> plot_sankey(
                payload,
                payload,
                payload;
                label=payload,
            ),
            () -> plot_parcoords(
                dimensions;
                line_color=payload,
            ),
            () -> plot_mesh3d(
                payload,
                payload,
                payload;
                intensity=payload,
            ),
            () -> plot_isosurface(
                payload,
                payload,
                payload,
                payload,
            ),
            () -> plot_volume(
                payload,
                payload,
                payload,
                payload,
            ),
        )

        for construct in constructors
            construct()
            GC.gc()
            @test @allocated(construct()) < 2_000_000
        end

        warm_subplot = subplots(
            1,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
        )
        _append_large_lazy_subplot!(warm_subplot, payload)

        target_subplot = subplots(
            1,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
        )
        GC.gc()
        append_allocations = @allocated(
            _append_large_lazy_subplot!(
                target_subplot,
                payload,
            )
        )
        @test append_allocations < 128 * 1024
        appended_trace = only(target_subplot.data)
        @test appended_trace.fields[:x] === payload
        @test appended_trace.fields[:y] === payload
    end
end
