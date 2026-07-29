mutable struct _ModernMapCustomTrace <: AbstractTrace
    fields::Dict{Symbol,Any}
end

PlotlyBase.JSON.lower(trace::_ModernMapCustomTrace) = trace.fields

@testset "Modern MapLibre maps" begin
    trace_type(trace) = String(trace.fields[:type])
    model_json(plot) =
        PlotlyBase.JSON.json(
            Dict(:data => plot.data, :layout => plot.layout);
            allownan=true,
        )

    @testset "renderer asset and HTML version alignment" begin
        @test PlotlySupply._PLOTLYJS_VERSION == "2.35.2"
        @test PlotlyBase.plotly_version() == "2.35.2"

        asset = PlotlySupply._plotlyjs_asset_path()
        asset_uri = PlotlySupply._plotlyjs_asset_uri()
        @test isfile(asset)
        @test filesize(asset) > 4_000_000
        @test startswith(asset_uri, "file://")
        asset_header = open(asset) do io
            String(read(io, 128))
        end
        @test occursin("plotly.js v2.35.2", asset_header)

        sync_html = PlotlySupply._syncplot_html(
            "modern-map-sync";
            autoplay=false,
            timeout_s=1.0,
        )
        export_html =
            PlotlySupply._export_window_html("modern-map-export")
        for html in (sync_html, export_html)
            @test occursin(asset_uri, html)
            @test !occursin(PlotlySupply._PLOTLY_CDN_URL, html)
        end

        figure = plot_scattermap(
            [0.0],
            [0.0];
            style="white-bg",
        )
        shown = IOBuffer()
        show(
            shown,
            MIME("text/html"),
            figure;
            include_mathjax=missing,
            include_plotlyjs="cdn",
            full_html=true,
        )
        shown_html = String(take!(shown))
        saved = IOBuffer()
        PlotlySupply._savefig_html(saved, figure)
        saved_html = String(take!(saved))
        for html in (shown_html, saved_html)
            @test occursin(
                "https://cdn.plot.ly/plotly-2.35.2.min.js",
                html,
            )
            @test !occursin("plotly-2.33.0", html)
            @test occursin("\"type\":\"scattermap\"", html)
            @test occursin("\"map\"", html)
        end
    end

    @testset "schema-independent trace constructors" begin
        lon = 1:3
        lat = 4:6
        z = 7:9
        geojson = Dict(
            "type" => "FeatureCollection",
            "features" => Any[],
        )

        fields = Dict{String,Any}(
            "lon" => lon,
            "lat" => lat,
        )
        scatter_trace = scattermap(fields; customdata=z)
        @test trace_type(scatter_trace) == "scattermap"
        @test scatter_trace.fields[:lon] === lon
        @test scatter_trace.fields[:lat] === lat
        @test scatter_trace.fields[:customdata] === z
        @test !haskey(fields, "type")

        choropleth_trace = choroplethmap(
            geojson=geojson,
            locations=lon,
            z=z,
        )
        @test trace_type(choropleth_trace) == "choroplethmap"
        @test choropleth_trace.fields[:geojson] === geojson
        @test choropleth_trace.fields[:locations] === lon
        @test choropleth_trace.fields[:z] === z

        density_trace = densitymap(lon=lon, lat=lat)
        @test trace_type(density_trace) == "densitymap"
        @test density_trace.fields[:lon] === lon
        @test density_trace.fields[:lat] === lat
        @test !haskey(density_trace.fields, :z)
    end

    @testset "high-level construction and validation" begin
        lon = 1.0:1.0:3.0
        lat = 11.0:1.0:13.0
        z = 21.0:1.0:23.0
        radius = 4.0:1.0:6.0
        marker_color = 31.0:1.0:33.0
        marker_size = 7.0:1.0:9.0
        geojson = Dict(
            "type" => "FeatureCollection",
            "features" => Any[],
        )
        style = Dict(
            "version" => 8,
            "sources" => Dict{String,Any}(),
            "layers" => Any[],
        )

        scatter_figure = plot_scattermap(
            lon,
            lat;
            color=marker_color,
            marker_size=marker_size,
            customdata=z,
            style=style,
            zoom=0,
            center_lon=120,
        )
        scatter_trace = only(scatter_figure.data)
        @test trace_type(scatter_trace) == "scattermap"
        @test scatter_trace.fields[:lon] === lon
        @test scatter_trace.fields[:lat] === lat
        @test scatter_trace.fields[:customdata] === z
        @test scatter_trace.fields[:marker][:color] === marker_color
        @test scatter_trace.fields[:marker][:size] === marker_size
        scatter_layout = PlotlySupply._symbol_dict(
            scatter_figure.layout.fields[:map],
        )
        @test scatter_layout[:style] === style
        @test scatter_layout[:zoom] == 0
        @test PlotlySupply._symbol_dict(
            scatter_layout[:center],
        ) == Dict(:lon => 120)

        choropleth_figure = plot_choroplethmap(
            geojson,
            1:3,
            z;
            marker_line_color=marker_color,
            marker_line_width=0,
            marker_opacity=0,
            style="white-bg",
        )
        choropleth_trace = only(choropleth_figure.data)
        @test trace_type(choropleth_trace) == "choroplethmap"
        @test choropleth_trace.fields[:geojson] === geojson
        @test choropleth_trace.fields[:z] === z
        @test choropleth_trace.fields[:marker][:line][:color] ===
              marker_color
        @test choropleth_trace.fields[:marker][:line][:width] == 0
        @test choropleth_trace.fields[:marker][:opacity] == 0

        unweighted = plot_densitymap(
            lon,
            lat;
            style="white-bg",
        )
        @test !haskey(only(unweighted.data).fields, :z)

        weighted = plot_densitymap(
            lon,
            lat,
            z;
            radius=radius,
            style="white-bg",
        )
        density_trace = only(weighted.data)
        @test density_trace.fields[:z] === z
        @test density_trace.fields[:radius] === radius

        @test_throws ArgumentError plot_scattermap(
            lon,
            1.0:2.0,
        )
        @test_throws ArgumentError plot_scattermap(
            lon,
            lat;
            color=1.0:2.0,
        )
        @test_throws ArgumentError plot_scattermap(
            lon,
            lat;
            marker_size=1.0:2.0,
        )
        @test_throws ArgumentError plot_choroplethmap(
            geojson,
            1:2,
            z,
        )
        @test_throws ArgumentError plot_choroplethmap(
            geojson,
            1:3,
            z;
            marker_line_color=1.0:2.0,
        )
        @test_throws ArgumentError plot_choroplethmap(
            geojson,
            1:3,
            z;
            marker_line_width=1.0:2.0,
        )
        @test_throws ArgumentError plot_choroplethmap(
            geojson,
            1:3,
            z;
            marker_opacity=[0.5, 0.5],
        )
        @test_throws ArgumentError plot_densitymap(
            lon,
            lat,
            1.0:2.0,
        )
        @test_throws ArgumentError plot_densitymap(
            lon,
            lat;
            radius=1.0:2.0,
        )
        for invalid_radius in (
            true,
            -1,
            NaN,
            big"1e400",
            big(10)^400,
            [1.0, 0.0, 2.0],
            [1.0, Inf, 2.0],
        )
            @test_throws ArgumentError plot_densitymap(
                lon,
                lat;
                radius=invalid_radius,
            )
        end
        for invalid_view in (
            true,
            NaN,
            Inf,
            -Inf,
            big"1e400",
            big(10)^400,
        )
            @test_throws ArgumentError plot_scattermap(
                lon,
                lat;
                zoom=invalid_view,
            )
            @test_throws ArgumentError plot_scattermap(
                lon,
                lat;
                center_lon=invalid_view,
            )
        end
        for invalid_style in ("", "   ", Dict(), 7)
            @test_throws ArgumentError plot_scattermap(
                lon,
                lat;
                style=invalid_style,
            )
        end

        target = plot_scattermap(
            lon,
            lat;
            style="white-bg",
        )
        before = model_json(target)
        @test_throws ArgumentError plot_densitymap!(
            target,
            lon,
            lat,
            1.0:2.0,
        )
        @test model_json(target) == before
    end

    @testset "update_maps! is isolated and atomic" begin
        style = Dict(
            "version" => 8,
            "sources" => Dict{String,Any}(),
            "layers" => Any[],
        )
        layout = Layout()
        layout.fields[:map] = attr(
            domain=attr(x=[0.0, 0.4], y=[0.0, 1.0]),
            center=attr(lon=10, lat=20),
            style="white-bg",
        )
        layout.fields[:map2] = attr(
            domain=attr(x=[0.6, 1.0], y=[0.0, 1.0]),
            center=attr(lon=30, lat=40),
            style="white-bg",
        )
        layout.fields[:mapbox] = attr(zoom=9)
        layout.fields[:map0] = attr(zoom=8)
        layout.fields[:map1] = attr(zoom=7)
        layout.fields[:map01] = attr(zoom=6)
        figure = Plot(GenericTrace[], layout)
        first_domain = deepcopy(layout.fields[:map][:domain])
        second_domain = deepcopy(layout.fields[:map2][:domain])

        @test update_maps!(
            figure;
            style=style,
            zoom=0,
            center_lat=5,
        ) === figure
        for (key, expected_lon, expected_domain) in (
            (:map, 10, first_domain),
            (:map2, 30, second_domain),
        )
            map_options = PlotlySupply._symbol_dict(
                figure.layout.fields[key],
            )
            center = PlotlySupply._symbol_dict(map_options[:center])
            @test map_options[:style] === style
            @test map_options[:zoom] == 0
            @test center == Dict(:lon => expected_lon, :lat => 5)
            @test map_options[:domain] == expected_domain
        end
        @test figure.layout.fields[:mapbox][:zoom] == 9
        @test figure.layout.fields[:map0][:zoom] == 8
        @test figure.layout.fields[:map1][:zoom] == 7
        @test figure.layout.fields[:map01][:zoom] == 6

        before = model_json(figure)
        for options in (
            (; zoom=NaN),
            (; center_lon=true),
            (; bearing=Inf),
            (; pitch=-Inf),
            (; style=Dict()),
            (; bounds=Dict(:west => NaN)),
        )
            @test_throws ArgumentError update_maps!(
                figure;
                options...,
            )
            @test model_json(figure) == before
        end

        # Explicit `nothing` replaces (and therefore clears) nested camera
        # objects; structured replacements still compose with flattened
        # center_/bounds_ keywords.
        @test update_maps!(
            figure;
            center=nothing,
            bounds=nothing,
        ) === figure
        for key in (:map, :map2)
            @test figure.layout.fields[key][:center] === nothing
            @test figure.layout.fields[key][:bounds] === nothing
        end

        caller_center = Dict("lon" => 12)
        caller_bounds = (west=-4,)
        with_objects = attr()
        with_objects.fields[:center] = caller_center
        with_objects.fields[:bounds] = caller_bounds
        @test update_maps!(
            figure,
            with_objects;
            center_lat=34,
            bounds_east=5,
        ) === figure
        @test caller_center == Dict("lon" => 12)
        @test caller_bounds == (west=-4,)
        @test figure.layout.fields[:map][:center] ==
              attr(lon=12, lat=34)
        @test figure.layout.fields[:map][:bounds] ==
              attr(west=-4, east=5)

        failed_center = attr(lon=56)
        failed_with = attr()
        failed_with.fields[:center] = failed_center
        before = model_json(figure)
        @test_throws ArgumentError update_maps!(
            figure,
            failed_with;
            center_lat=NaN,
        )
        @test failed_center == attr(lon=56)
        @test model_json(figure) == before

        string_root = Dict{String,Any}(
            "style" => style,
            "center" => Dict{String,Any}("lon" => 7),
        )
        string_layout = Layout()
        string_layout.fields[:map] = string_root
        string_figure = Plot(GenericTrace[], string_layout)
        @test update_maps!(string_figure; zoom=2) === string_figure
        updated_string_root =
            string_figure.layout.fields[:map]
        @test updated_string_root isa Dict{String,Any}
        @test updated_string_root["style"] === style
        @test updated_string_root["zoom"] == 2
        @test !haskey(string_root, "zoom")

        shared_map = attr(
            style="white-bg",
            center=attr(lon=1, lat=2),
        )
        aliased_trace = GenericTrace(
            "scatter";
            x=[1],
            y=[2],
        )
        aliased_trace.fields[:meta] = shared_map
        aliased_layout = Layout()
        aliased_layout.fields[:map] = shared_map
        aliased_layout.fields[:map2] = shared_map
        aliased_figure = Plot([aliased_trace], aliased_layout)
        aliased_sync = SyncPlot(
            aliased_figure,
            nothing,
            nothing,
            "modern-map-alias-probe",
        )
        aliased_prepared =
            PlotlySupply._prepare_modern_map_layout_transaction(
                aliased_sync,
                aliased_figure,
                attr(),
                (; zoom=3),
            )
        @test aliased_prepared.operation == "react"
        @test occursin(
            "Plotly.react",
            something(aliased_prepared.script, ""),
        )
        aliased_prepared.commit()
        committed_shared = aliased_figure.layout.fields[:map]
        @test aliased_figure.layout.fields[:map2] ===
              committed_shared
        @test only(aliased_figure.data).fields[:meta] ===
              committed_shared
        @test committed_shared[:zoom] == 3
        @test !haskey(shared_map, :zoom)

        no_op_root = committed_shared
        no_op_fields = no_op_root.fields
        no_op_prepared =
            PlotlySupply._prepare_modern_map_layout_transaction(
                aliased_sync,
                aliased_figure,
                attr(),
                NamedTuple(),
            )
        @test no_op_prepared.script === nothing
        no_op_prepared.commit()
        @test aliased_figure.layout.fields[:map] === no_op_root
        @test aliased_figure.layout.fields[:map].fields ===
              no_op_fields

        nested_map = attr(style="white-bg")
        nested_trace = scatter(y=[1])
        nested_trace.fields[:meta] =
            Dict(:wrapper => Dict(:map => nested_map))
        nested_layout = Layout()
        nested_layout.fields[:map] = nested_map
        nested_figure = Plot([nested_trace], nested_layout)
        nested_sync = SyncPlot(
            nested_figure,
            nothing,
            nothing,
            "modern-map-nested-alias-probe",
        )
        nested_prepared =
            PlotlySupply._prepare_modern_map_layout_transaction(
                nested_sync,
                nested_figure,
                attr(),
                (; zoom=4),
            )
        @test nested_prepared.operation == "react"
        nested_prepared.commit()
        nested_committed = nested_figure.layout.fields[:map]
        @test only(nested_figure.data).fields[:meta][:wrapper][:map] ===
              nested_committed
        @test nested_committed[:zoom] == 4
        @test !haskey(nested_map, :zoom)

        fields_map = attr(style="white-bg")
        fields_trace = scatter(y=[1])
        fields_trace.fields[:meta] =
            Dict(:wrapper => fields_map.fields)
        fields_layout = Layout()
        fields_layout.fields[:map] = fields_map
        fields_figure = Plot([fields_trace], fields_layout)
        fields_sync = SyncPlot(
            fields_figure,
            nothing,
            nothing,
            "modern-map-fields-alias-probe",
        )
        fields_prepared =
            PlotlySupply._prepare_modern_map_layout_transaction(
                fields_sync,
                fields_figure,
                attr(),
                (; zoom=5),
            )
        @test fields_prepared.operation == "react"
        fields_prepared.commit()
        @test only(fields_figure.data).fields[:meta][:wrapper] ===
              fields_figure.layout.fields[:map].fields
        @test fields_figure.layout.fields[:map][:zoom] == 5
        @test !haskey(fields_map, :zoom)

        custom_map = attr(style="white-bg")
        custom_trace = _ModernMapCustomTrace(
            Dict{Symbol,Any}(
                :type => "scatter",
                :meta => custom_map,
            ),
        )
        custom_layout = Layout()
        custom_layout.fields[:map] = custom_map
        custom_figure = Plot(
            AbstractTrace[custom_trace],
            custom_layout,
        )
        custom_sync = SyncPlot(
            custom_figure,
            nothing,
            nothing,
            "modern-map-custom-alias-probe",
        )
        custom_prepared =
            PlotlySupply._prepare_modern_map_layout_transaction(
                custom_sync,
                custom_figure,
                attr(),
                (; zoom=6),
            )
        @test custom_prepared.operation == "react"
        custom_prepared.commit()
        @test only(custom_figure.data).fields[:meta] ===
              custom_figure.layout.fields[:map]
        @test custom_figure.layout.fields[:map][:zoom] == 6
        @test !haskey(custom_map, :zoom)
    end

    @testset "mixed modern and legacy subplot routing" begin
        specs = [
            Spec(kind="map") Spec(kind="mapbox") Spec(kind="scattermap")
            Spec(kind="scattermapbox") missing Spec(kind="densitymap")
        ]
        insets = [
            Inset(cell=(1, 1), kind="choroplethmap"),
            Inset(cell=(1, 2), kind="densitymapbox"),
        ]
        sf = subplots(
            2,
            3;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=specs,
            insets=insets,
        )
        expected_refs = Dict(
            (1, 1) => ("map", :map),
            (1, 2) => ("mapbox", :mapbox),
            (1, 3) => ("map", :map2),
            (2, 1) => ("mapbox", :mapbox2),
            (2, 3) => ("map", :map3),
        )
        for ((row, col), (kind, key)) in expected_refs
            ref = only(sf.layout.subplots.grid_ref[row, col])
            @test ref.subplot_kind == kind
            @test only(ref.layout_keys) == key
            @test ref.trace_kwargs[:subplot] == String(key)
            @test haskey(sf.layout.fields, key)
            @test haskey(sf.layout.fields[key], :domain)
        end
        @test haskey(sf.layout.fields, :map4)
        @test haskey(sf.layout.fields, :mapbox3)
        @test sf.layout.fields[:map4][:domain] ==
              sf.layout.fields[:map][:domain]
        @test sf.layout.fields[:mapbox3][:domain] ==
              sf.layout.fields[:mapbox][:domain]
        @test isempty(sf.layout.subplots.grid_ref[2, 2])

        lon = 1.0:3.0
        lat = 4.0:6.0
        z = 7.0:9.0
        geojson = Dict(
            "type" => "FeatureCollection",
            "features" => Any[],
        )
        @test plot_scattermap!(
            sf,
            lon,
            lat;
            row=1,
            col=3,
        ) === sf
        @test sf.data[end].fields[:subplot] == "map2"
        @test plot_densitymap!(
            sf,
            lon,
            lat;
            row=2,
            col=3,
        ) === sf
        @test sf.data[end].fields[:subplot] == "map3"
        @test plot_choroplethmap!(
            sf,
            geojson,
            1:3,
            z;
            row=1,
            col=1,
        ) === sf
        @test sf.data[end].fields[:subplot] == "map"

        before = model_json(sf.plot)
        selection = (sf.current_row, sf.current_col)
        @test_throws ArgumentError plot_scattermap!(
            sf,
            lon,
            lat;
            row=1,
            col=2,
        )
        @test model_json(sf.plot) == before
        @test (sf.current_row, sf.current_col) == selection
        @test_throws ArgumentError plot_scattermapbox!(
            sf,
            lon,
            lat;
            row=1,
            col=1,
        )
        @test model_json(sf.plot) == before
        @test (sf.current_row, sf.current_col) == selection

        map2_domain = deepcopy(sf.layout.fields[:map2][:domain])
        @test update_maps!(
            sf;
            row=1,
            col=3,
            center_lon=100,
            zoom=0,
        ) === sf
        @test sf.layout.fields[:map2][:domain] == map2_domain
        @test sf.layout.fields[:map2][:zoom] == 0
        @test sf.layout.fields[:map2][:center][:lon] == 100
        @test !haskey(sf.layout.fields[:map], :zoom)

        simple = make_subplots(
            rows=1,
            cols=1,
            specs=fill(Spec(kind="map"), 1, 1),
        )
        @test simple isa Plot
        @test simple.layout.subplots.grid_ref[1, 1][1].subplot_kind ==
              "map"

        for kind in (:scattermap, :choroplethmap, :densitymap)
            @test PlotlySupply._plotlysupply_subplot_kind_from_trace_type(
                kind,
            ) == "map"
        end
        @test PlotlySupply._plotlysupply_subplot_kind_from_trace_type(
            :scattermapbox,
        ) == "mapbox"
    end

    @testset "blank cells, shared axes, and titles" begin
        blank = subplots(
            1,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=fill(missing, 1, 1),
        )
        @test isassigned(blank.layout.subplots.grid_ref, 1, 1)
        @test isempty(blank.layout.subplots.grid_ref[1, 1])
        blank_before = model_json(blank.plot)
        blank_selection = (blank.current_row, blank.current_col)
        @test_throws ArgumentError plot_scatter!(
            blank,
            [1.0],
            [2.0],
        )
        @test model_json(blank.plot) == blank_before
        @test (blank.current_row, blank.current_col) ==
              blank_selection

        blank_inset = subplots(
            1,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=fill(missing, 1, 1),
            insets=[Inset(cell=(1, 1), kind="map")],
        )
        @test isempty(blank_inset.layout.subplots.grid_ref[1, 1])
        @test only(blank_inset.layout.subplots.insets).kind == "map"
        @test haskey(blank_inset.layout.fields, :map)
        @test haskey(blank_inset.layout.fields[:map], :domain)
        inset_before = model_json(blank_inset.plot)
        @test_throws ArgumentError plot_scattermap!(
            blank_inset,
            [1.0],
            [2.0],
        )
        @test model_json(blank_inset.plot) == inset_before

        shared_specs = Union{Missing,Spec}[
            Spec(kind="xy") missing Spec(kind="xy")
            Spec(kind="xy") Spec(kind="map") Spec(kind="xy")
        ]
        shared = subplots(
            2,
            3;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=shared_specs,
            shared_xaxes=true,
            shared_yaxes=true,
        )
        @test shared.layout.subplots.shared_xaxes === true
        @test shared.layout.subplots.shared_yaxes === true
        @test isempty(shared.layout.subplots.grid_ref[1, 2])
        @test only(
            shared.layout.subplots.grid_ref[2, 2],
        ).subplot_kind == "map"
        @test shared.layout.fields[:xaxis][:matches] == "x3"
        @test shared.layout.fields[:xaxis2][:matches] == "x4"
        @test shared.layout.fields[:xaxis][:showticklabels] === false
        @test shared.layout.fields[:xaxis2][:showticklabels] === false
        @test shared.layout.fields[:yaxis2][:matches] == "y"
        @test shared.layout.fields[:yaxis4][:matches] == "y3"
        @test shared.layout.fields[:yaxis2][:showticklabels] === false
        @test shared.layout.fields[:yaxis4][:showticklabels] === false
        @test !haskey(shared.layout.fields[:xaxis3], :matches)
        @test !haskey(shared.layout.fields[:xaxis4], :matches)
        @test !haskey(shared.layout.fields[:yaxis], :matches)
        @test !haskey(shared.layout.fields[:yaxis3], :matches)

        title_specs = Union{Missing,Spec}[
            Spec(kind="map") missing
            Spec(kind="mapbox") Spec(kind="map")
        ]
        titled = subplots(
            2,
            2;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=title_specs,
            subplot_titles=[
                "map-11" "blank-cell"
                "legacy-21" "map-22"
            ],
        )
        annotations = titled.layout.fields[:annotations]
        @test [annotation[:text] for annotation in annotations] ==
              ["map-11", "legacy-21", "map-22"]
        annotations_by_text = Dict(
            annotation[:text] => annotation
            for annotation in annotations
        )
        for (text, key) in (
            ("map-11", :map),
            ("legacy-21", :mapbox),
            ("map-22", :map2),
        )
            domain = titled.layout.fields[key][:domain]
            annotation = annotations_by_text[text]
            @test annotation[:x] ≈
                  (domain[:x][1] + domain[:x][2]) / 2
            @test annotation[:y] ≈ domain[:y][2]
        end
        @test !haskey(annotations_by_text, "blank-cell")

        lane_specs =
            Matrix{Union{Missing,Spec}}(missing, 3, 3)
        lane_specs[1, 3] = Spec(kind="map")
        lane_specs[3, 1] = Spec(kind="mapbox")
        lanes = subplots(
            3,
            3;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=lane_specs,
            column_titles=[
                "left-column",
                "empty-column",
                "right-column",
            ],
            row_titles=[
                "top-row",
                "empty-row",
                "bottom-row",
            ],
            x_title="all-x",
            y_title="all-y",
        )
        lane_annotations = Dict(
            annotation[:text] => annotation
            for annotation in lanes.layout.fields[:annotations]
        )
        @test Set(keys(lane_annotations)) == Set([
            "left-column",
            "right-column",
            "top-row",
            "bottom-row",
            "all-x",
            "all-y",
        ])
        @test !haskey(lane_annotations, "empty-column")
        @test !haskey(lane_annotations, "empty-row")

        left_domain = lanes.layout.fields[:mapbox][:domain]
        right_domain = lanes.layout.fields[:map][:domain]
        @test lane_annotations["left-column"][:x] ≈
              (left_domain[:x][1] + left_domain[:x][2]) / 2
        @test lane_annotations["left-column"][:y] ≈
              left_domain[:y][2]
        @test lane_annotations["right-column"][:x] ≈
              (right_domain[:x][1] + right_domain[:x][2]) / 2
        @test lane_annotations["right-column"][:y] ≈
              right_domain[:y][2]
        @test lane_annotations["top-row"][:x] ≈ right_domain[:x][2]
        @test lane_annotations["top-row"][:y] ≈
              (right_domain[:y][1] + right_domain[:y][2]) / 2
        @test lane_annotations["bottom-row"][:x] ≈
              left_domain[:x][2]
        @test lane_annotations["bottom-row"][:y] ≈
              (left_domain[:y][1] + left_domain[:y][2]) / 2
        @test lane_annotations["top-row"][:textangle] == 90
        @test lane_annotations["bottom-row"][:textangle] == 90
        @test lane_annotations["all-x"][:y] == 0
        @test lane_annotations["all-y"][:x] == 0

        bottom_left = subplots(
            2,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
            start_cell="bottom-left",
            specs=reshape([
                Spec(kind="map")
                Spec(kind="mapbox")
            ], 2, 1),
            column_titles=["column-title"],
        )
        column_annotation =
            only(bottom_left.layout.fields[:annotations])
        top_domain =
            bottom_left.layout.fields[:mapbox][:domain]
        @test column_annotation[:x] ≈
              (top_domain[:x][1] + top_domain[:x][2]) / 2
        @test column_annotation[:y] ≈ top_domain[:y][2]
    end

    @testset "large lazy payloads stay bounded" begin
        payload = 1:1_000_000
        geojson = Dict(
            "type" => "FeatureCollection",
            "features" => Any[],
        )
        constructors = (
            () -> plot_scattermap(
                payload,
                payload;
                customdata=payload,
                style="white-bg",
            ),
            () -> plot_choroplethmap(
                geojson,
                payload,
                payload;
                customdata=payload,
                style="white-bg",
            ),
            () -> plot_densitymap(
                payload,
                payload,
                payload;
                radius=payload,
                customdata=payload,
                style="white-bg",
            ),
        )
        for construct in constructors
            figure = construct()
            trace = only(figure.data)
            @test any(value -> value === payload, values(trace.fields))
            construct()
            GC.gc()
            @test @allocated(construct()) < 2_000_000
        end

        mutators = (
            p -> plot_scattermap!(
                p,
                payload,
                payload;
                customdata=payload,
            ),
            p -> plot_choroplethmap!(
                p,
                geojson,
                payload,
                payload;
                customdata=payload,
            ),
            p -> plot_densitymap!(
                p,
                payload,
                payload,
                payload;
                radius=payload,
                customdata=payload,
            ),
        )
        for mutate! in mutators
            mutate!(Plot())
            target = Plot()
            GC.gc()
            @test @allocated(mutate!(target)) < 2_000_000
            @test any(
                value -> value === payload,
                values(only(target.data).fields),
            )
        end

        subplot_case = () -> subplots(
            1,
            1;
            sync=false,
            show=false,
            per_subplot_legends=false,
            specs=fill(Spec(kind="map"), 1, 1),
        )
        for mutate! in mutators
            warm = subplot_case()
            mutate!(warm)
            target = subplot_case()
            GC.gc()
            @test @allocated(mutate!(target)) < 2_000_000
            @test any(
                value -> value === payload,
                values(only(target.data).fields),
            )
        end

        # A small camera update must neither traverse/copy a large opaque
        # MapLibre style payload nor replace its public identity.
        realistic_size = 10_000
        style_payload = [
            Dict{String,Any}(
                "id" => "layer-$index",
                "type" => "fill",
            )
            for index in 1:realistic_size
        ]
        large_style = Dict{String,Any}(
            "version" => 8,
            "sources" => Dict{String,Any}(),
            "layers" => style_payload,
        )
        feature_payload = [
            Dict{String,Any}(
                "type" => "Feature",
                "id" => index,
                "properties" => Dict{String,Any}(
                    "value" => index,
                ),
            )
            for index in 1:realistic_size
        ]
        large_geojson = Dict{String,Any}(
            "type" => "FeatureCollection",
            "features" => feature_payload,
        )
        map_figure = plot_choroplethmap(
            large_geojson,
            1:realistic_size,
            1:realistic_size;
            style=large_style,
        )
        update_map_figure! =
            p -> update_maps!(p; center_lat=1.0)
        update_map_figure!(map_figure)
        update_map_figure!(map_figure)
        GC.gc()
        @test @allocated(update_map_figure!(map_figure)) <
              2_000_000
        @test map_figure.layout.fields[:map][:style] ===
              large_style
        @test map_figure.layout.fields[:map][:style]["layers"] ===
              style_payload
        @test only(map_figure.data).fields[:geojson] ===
              large_geojson
        @test only(map_figure.data).fields[:geojson]["features"] ===
              feature_payload

        delta_probe = SyncPlot(
            map_figure,
            nothing,
            nothing,
            "modern-map-delta-probe",
        )
        prepared_delta =
            PlotlySupply._prepare_modern_map_layout_transaction(
                delta_probe,
                map_figure,
                attr(),
                (; center_lon=3.0),
            )
        delta_script = something(prepared_delta.script, "")
        @test prepared_delta.operation == "relayout"
        @test occursin("Plotly.relayout", delta_script)
        @test !occursin("Plotly.react", delta_script)
        @test !occursin("\"layers\"", delta_script)
        @test !occursin("\"features\"", delta_script)
        @test ncodeunits(delta_script) < 1_000

        map_subplot = subplot_case()
        update_maps!(
            map_subplot;
            row=1,
            col=1,
            style=large_style,
        )
        update_map_subplot! = sf -> update_maps!(
            sf;
            row=1,
            col=1,
            center_lat=1.0,
        )
        update_map_subplot!(map_subplot)
        update_map_subplot!(map_subplot)
        GC.gc()
        @test @allocated(update_map_subplot!(map_subplot)) <
              2_000_000
        @test map_subplot.layout.fields[:map][:style] ===
              large_style
        @test map_subplot.layout.fields[:map][:style]["layers"] ===
              style_payload
    end

    @testset "SyncPlot renderer failure rolls back" begin
        ec = _LifecycleFakeElectron()
        initial = plot_scattermap(
            [0.0],
            [0.0];
            style="white-bg",
        )
        sp = PlotlySupply._create_syncplot_window(
            ec,
            initial;
            app=:fake,
            show=false,
        )
        before = model_json(sp.plot)
        map_root = sp.layout.fields[:map]
        map_fields = map_root.fields
        ec.run_error =
            ErrorException("injected modern-map renderer failure")
        caught = try
            update_maps!(sp; zoom=4)
            nothing
        catch err
            err
        end
        @test caught !== nothing
        @test model_json(sp.plot) == before
        @test sp.layout.fields[:map] === map_root
        @test sp.layout.fields[:map].fields === map_fields
        ec.run_error = nothing
        close(sp)
    end
end
