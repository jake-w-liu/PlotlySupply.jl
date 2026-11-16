using Test, PlotlySupply

# Regression tests for geographic / map plotting and the subplot grid
# (v2 "maps" track). Every testset fails on the pre-fix code.

const _REG_MAP_SQUARE = Dict(
	"type" => "FeatureCollection",
	"features" => [
		Dict(
			"type" => "Feature",
			"id" => "A",
			"properties" => Dict("name" => "Alpha"),
			"geometry" => Dict(
				"type" => "Polygon",
				"coordinates" => [[[0, 0], [0, 5], [5, 5], [5, 0], [0, 0]]],
			),
		),
	],
)

_reg_fields(value) = value isa PlotlyBase.PlotlyAttribute ? value.fields : value
_reg_layout(fig) = fig isa SubplotFigure ? fig.plot.layout.fields : fig.layout.fields
_reg_axis(fig, key) = _reg_fields(_reg_layout(fig)[key])
_reg_matches(fig, key) = get(_reg_axis(fig, key), :matches, nothing)
_reg_ticklabels(fig, key) = get(_reg_axis(fig, key), :showticklabels, true)
_reg_annotations(fig) = [
	Dict(k => v for (k, v) in _reg_fields(a)) for a in _reg_layout(fig)[:annotations]
]

@testset "regression: maps and subplot grid" begin
	@testset "shared axes \"all\" follow plotly.py (bottom-left reference)" begin
		# plotly.py `_configure_shared_axes`: rows outer (bottom row first),
		# columns inner; only the first column keeps y tick labels and only
		# the bottom row keeps x tick labels.
		for fig in (
			make_subplots(rows=2, cols=2, shared_xaxes="all", shared_yaxes="all"),
			subplots(2, 2; sync=false, show=false, shared_xaxes="all", shared_yaxes="all"),
		)
			@test _reg_matches(fig, :xaxis3) === nothing
			@test _reg_matches(fig, :yaxis3) === nothing
			for key in (:xaxis, :xaxis2, :xaxis4)
				@test _reg_matches(fig, key) == "x3"
			end
			for key in (:yaxis, :yaxis2, :yaxis4)
				@test _reg_matches(fig, key) == "y3"
			end
			@test _reg_ticklabels(fig, :xaxis) === false
			@test _reg_ticklabels(fig, :xaxis2) === false
			@test _reg_ticklabels(fig, :xaxis3) === true
			@test _reg_ticklabels(fig, :xaxis4) === true
			@test _reg_ticklabels(fig, :yaxis) === true
			@test _reg_ticklabels(fig, :yaxis2) === false
			@test _reg_ticklabels(fig, :yaxis3) === true
			@test _reg_ticklabels(fig, :yaxis4) === false
		end

		top = make_subplots(rows=3, cols=3, shared_xaxes="all", shared_yaxes="all")
		@test _reg_matches(top, :xaxis7) === nothing
		@test all(_reg_matches(top, Symbol("xaxis", i == 1 ? "" : i)) == "x7" for i in (1:6..., 8, 9))
		@test all(_reg_matches(top, Symbol("yaxis", i == 1 ? "" : i)) == "y7" for i in (1:6..., 8, 9))
		@test all(_reg_ticklabels(top, Symbol("xaxis", i == 1 ? "" : i)) === false for i in 1:6)
		@test all(_reg_ticklabels(top, Symbol("xaxis", i)) === true for i in 7:9)
		@test all(_reg_ticklabels(top, Symbol("yaxis", i)) === false for i in (2, 3, 5, 6, 8, 9))
		@test all(_reg_ticklabels(top, Symbol("yaxis", i == 1 ? "" : i)) === true for i in (1, 4, 7))

		# bottom-left: row 1 is the bottom row and holds x/y.
		bottom = make_subplots(
			rows=3,
			cols=3,
			start_cell="bottom-left",
			shared_xaxes="all",
			shared_yaxes="all",
		)
		@test _reg_matches(bottom, :xaxis) === nothing
		@test all(_reg_matches(bottom, Symbol("xaxis", i)) == "x" for i in 2:9)
		@test all(_reg_matches(bottom, Symbol("yaxis", i)) == "y" for i in 2:9)
		@test all(_reg_ticklabels(bottom, Symbol("xaxis", i == 1 ? "" : i)) === true for i in 1:3)
		@test all(_reg_ticklabels(bottom, Symbol("xaxis", i)) === false for i in 4:9)
		@test all(_reg_ticklabels(bottom, Symbol("yaxis", i)) === false for i in (2, 3, 5, 6, 8, 9))

		# A non-xy bottom-left cell is skipped; the next cell of the bottom
		# row becomes the reference.
		mixed = subplots(
			2,
			2;
			sync=false,
			show=false,
			specs=[Spec() Spec(); Spec(kind="map") Spec()],
			shared_xaxes="all",
		)
		@test _reg_matches(mixed, :xaxis3) === nothing
		@test _reg_matches(mixed, :xaxis) == "x3"
		@test _reg_matches(mixed, :xaxis2) == "x3"
	end

	@testset "specs must match the grid size" begin
		@test_throws ArgumentError subplots(2, 2; sync=false, show=false, specs=[Spec() Spec()])
		@test_throws ArgumentError subplots(1, 1; sync=false, show=false, specs=[Spec() Spec(kind="map")])
		@test_throws ArgumentError make_subplots(rows=2, cols=2, specs=[Spec() Spec()])
		err = try
			subplots(2, 2; sync=false, show=false, specs=[Spec() Spec()])
		catch caught
			caught
		end
		@test err isa ArgumentError
		@test occursin("(2, 2)", err.msg) && occursin("(1, 2)", err.msg)
	end

	@testset "subplot_titles accept the plotly 1xN list form" begin
		row_form = subplots(2, 2; sync=false, show=false, subplot_titles=["P1" "P2" "P3" "P4"])
		grid_form = subplots(2, 2; sync=false, show=false, subplot_titles=["P1" "P2"; "P3" "P4"])
		@test _reg_annotations(row_form) == _reg_annotations(grid_form)
		@test [a[:text] for a in _reg_annotations(row_form)] == ["P1", "P2", "P3", "P4"]

		spans = Union{Missing,Spec}[Spec(colspan=2) missing; Spec() Spec()]
		spanned = subplots(2, 2; sync=false, show=false, specs=spans, subplot_titles=["Top" "BL" "BR"])
		spanned_grid = subplots(
			2,
			2;
			sync=false,
			show=false,
			specs=spans,
			subplot_titles=Union{Missing,String}["Top" missing; "BL" "BR"],
		)
		@test _reg_annotations(spanned) == _reg_annotations(spanned_grid)
		@test [a[:text] for a in _reg_annotations(spanned)] == ["Top", "BL", "BR"]

		# Fewer titles than cells label the first cells only.
		partial = subplots(2, 2; sync=false, show=false, subplot_titles=["only" "two"])
		@test [a[:text] for a in _reg_annotations(partial)] == ["only", "two"]

		@test_throws ArgumentError subplots(2, 2; sync=false, show=false, subplot_titles=["a" "b" "c" "d" "e"])
		@test_throws ArgumentError subplots(2, 2; sync=false, show=false, subplot_titles=reshape(["a", "b", "c"], 3, 1))
	end

	@testset "mapbox targets without a style get the token-free default" begin
		for build! in (
			p -> plot_scattermapbox!(p, [1.0], [2.0]),
			p -> plot_densitymapbox!(p, [1.0], [2.0], [3.0]),
			p -> plot_choroplethmapbox!(p, _REG_MAP_SQUARE, ["A"], [1.0]),
		)
			p = Plot()
			build!(p)
			@test _reg_fields(p.layout.fields[:mapbox])[:style] == "open-street-map"
		end

		kept = plot_scattermapbox([1.0], [2.0]; style="carto-darkmatter", zoom=2)
		plot_scattermapbox!(kept, [3.0], [4.0])
		@test _reg_fields(kept.layout.fields[:mapbox])[:style] == "carto-darkmatter"
		plot_densitymapbox!(kept, [3.0], [4.0], [1.0]; style="white-bg")
		@test _reg_fields(kept.layout.fields[:mapbox])[:style] == "white-bg"

		sf = subplots(1, 2; sync=false, show=false, specs=[Spec(kind="mapbox") Spec(kind="mapbox")])
		@test plot_scattermapbox!(sf, [1.0], [2.0]; row=1, col=2) === sf
		@test _reg_fields(sf.plot.layout.fields[:mapbox2])[:style] == "open-street-map"
		@test !haskey(_reg_fields(sf.plot.layout.fields[:mapbox]), :style)
		@test haskey(_reg_fields(sf.plot.layout.fields[:mapbox2]), :domain)

		update_mapboxes!(sf; row=1, col=2, style="white-bg")
		plot_densitymapbox!(sf, [1.0], [2.0], [3.0]; row=1, col=2)
		@test _reg_fields(sf.plot.layout.fields[:mapbox2])[:style] == "white-bg"

		style_object = Dict("version" => 8, "sources" => Dict(), "layers" => Any[])
		_reg_fields(sf.plot.layout.fields[:mapbox2])[:style] = style_object
		plot_choroplethmapbox!(sf, _REG_MAP_SQUARE, ["A"], [1.0]; row=1, col=2)
		@test _reg_fields(sf.plot.layout.fields[:mapbox2])[:style] == style_object

		plot_scattermapbox!(sf, [1.0], [2.0]; row=1, col=1, style="carto-positron")
		@test _reg_fields(sf.plot.layout.fields[:mapbox])[:style] == "carto-positron"

		# A non-mapbox cell still fails atomically.
		geo = subplots(1, 1; sync=false, show=false, specs=reshape([Spec(kind="geo")], 1, 1))
		ntraces = length(geo.plot.data)
		@test_throws ArgumentError plot_scattermapbox!(geo, [1.0], [2.0]; row=1, col=1)
		@test length(geo.plot.data) == ntraces
		@test !haskey(geo.plot.layout.fields, :mapbox)
	end

	@testset "mapbox style is validated everywhere" begin
		for bad in ("", "   ", 7, Dict{String,Any}())
			@test_throws ArgumentError plot_scattermapbox([1.0], [2.0]; style=bad)
			@test_throws ArgumentError plot_densitymapbox([1.0], [2.0], [3.0]; style=bad)
			p = plot_scattermapbox([1.0], [2.0])
			@test_throws ArgumentError plot_scattermapbox!(p, [1.0], [2.0]; style=bad)
			if bad isa AbstractDict
				# PlotlyBase's keyword setter expands a Dict into its (zero)
				# entries, so an empty style object is a no-op update.
				update_mapboxes!(p; style=bad)
			else
				@test_throws ArgumentError update_mapboxes!(p; style=bad)
			end
			@test length(p.data) == 1
			@test _reg_fields(p.layout.fields[:mapbox])[:style] == "open-street-map"
		end
		sf = subplots(1, 2; sync=false, show=false, specs=[Spec(kind="mapbox") Spec(kind="mapbox")])
		@test_throws ArgumentError update_mapboxes!(sf; row=1, col=2, style="  ")
		@test !haskey(_reg_fields(sf.plot.layout.fields[:mapbox2]), :style)
	end

	@testset "choropleth locationmode follows geojson" begin
		with_geojson = plot_choropleth(["A"], [1.0]; geojson=_REG_MAP_SQUARE)
		trace = with_geojson.data[1].fields
		@test trace[:locationmode] == "geojson-id"
		@test trace[:geojson] === _REG_MAP_SQUARE
		@test plot_choropleth(["France"], [1.0]).data[1].fields[:locationmode] == "country names"
		@test plot_choropleth(["FRA"], [1.0]; locationmode="ISO-3").data[1].fields[:locationmode] == "ISO-3"
		@test plot_choropleth(["FRA"], [1.0]; locationmode=SubString("ISO-3xyz", 1, 5)).data[1].fields[:locationmode] == "ISO-3"
		named = plot_choropleth(["Alpha"], [1.0]; geojson=_REG_MAP_SQUARE, featureidkey="properties.name")
		@test named.data[1].fields[:featureidkey] == "properties.name"

		p = plot_choropleth(["France"], [1.0])
		plot_choropleth!(p, ["A"], [2.0]; geojson="https://example.invalid/regions.geojson")
		@test p.data[2].fields[:locationmode] == "geojson-id"

		@test_throws ArgumentError plot_choropleth(["A"], [1.0]; locationmode="geojson-id")
		@test_throws ArgumentError plot_choropleth(["A"], [1.0]; locationmode="countries")
		@test_throws ArgumentError plot_choropleth(["A"], [1.0]; featureidkey="properties.name")
		@test_throws ArgumentError plot_choropleth(["A"], [1.0]; geojson=5)
		@test_throws ArgumentError plot_choropleth(["A"], [1.0]; geojson="")
		@test_throws ArgumentError plot_choropleth!(p, ["A"], [1.0]; locationmode="geojson-id")
		@test length(p.data) == 2
	end

	@testset "per-point vectors must match the coordinates" begin
		@test_throws ArgumentError plot_scattergeo([1.0, 2.0], [3.0, 4.0]; color=["red"])
		@test_throws ArgumentError plot_scattergeo([1.0, 2.0], [3.0, 4.0]; marker_size=[4.0])
		@test_throws ArgumentError plot_scattermapbox([1.0, 2.0], [3.0, 4.0]; color=[1.0, 2.0, 3.0])
		@test_throws ArgumentError plot_scattermapbox([1.0, 2.0], [3.0, 4.0]; marker_size=[4.0])
		@test_throws ArgumentError plot_choroplethmapbox(_REG_MAP_SQUARE, ["A", "B"], [1.0, 2.0]; marker_opacity=[0.5])
		@test_throws ArgumentError plot_choroplethmapbox(_REG_MAP_SQUARE, ["A", "B"], [1.0, 2.0]; marker_line_width=[1.0])
		@test_throws ArgumentError plot_choroplethmapbox(_REG_MAP_SQUARE, ["A", "B"], [1.0, 2.0]; marker_line_color=["red"])
		@test_throws ArgumentError plot_densitymapbox([1.0, 2.0], [3.0, 4.0], [1.0, 1.0]; radius=[5.0])
		p = plot_scattergeo([0.0], [0.0])
		@test_throws ArgumentError plot_scattergeo!(p, [1.0, 2.0], [3.0, 4.0]; color=["red"])
		@test length(p.data) == 1

		ok = plot_scattergeo([1.0, 2.0], [3.0, 4.0]; color=["red", "blue"], marker_size=[4, 6])
		marker = ok.data[1].fields[:marker]
		@test marker[:color] == ["red", "blue"]
		@test marker[:size] == [4, 6]
		@test plot_densitymapbox([1.0, 2.0], [3.0, 4.0], [1.0, 1.0]; radius=[5, 6]).data[1].fields[:radius] == [5, 6]
		err = try
			plot_scattergeo([1.0], [2.0]; marker_size=-1)
		catch caught
			caught
		end
		@test err isa ArgumentError && occursin("scattergeo", err.msg)
	end

	@testset "geographic mutators on SubplotFigure route every signature" begin
		sm = subplots(1, 2; sync=false, show=false, specs=[Spec(kind="map") Spec(kind="map")])
		@test plot_densitymap!(sm, [1.0], [2.0], nothing; row=1, col=2) === sm
		trace = sm.plot.data[end].fields
		@test trace[:type] == "densitymap"
		@test trace[:subplot] == "map2"
		@test !haskey(trace, :z)
		plot_densitymap!(sm, [1.0], [2.0]; row=1, col=1)
		@test sm.plot.data[end].fields[:subplot] == "map"
		plot_densitymap!(sm, [1.0], [2.0], [5.0]; row=1, col=2)
		@test sm.plot.data[end].fields[:z] == [5.0]
		plot_scattermap!(sm, [1.0], [2.0]; row=1, col=2)
		@test sm.plot.data[end].fields[:subplot] == "map2"
		plot_choroplethmap!(sm, _REG_MAP_SQUARE, ["A"], [1.0]; row=1, col=1)
		@test sm.plot.data[end].fields[:subplot] == "map"

		sg = subplots(1, 2; sync=false, show=false, specs=[Spec(kind="geo") Spec(kind="geo")])
		plot_scattergeo!(sg, [1.0], [2.0]; row=1, col=2)
		@test sg.plot.data[end].fields[:geo] == "geo2"
		plot_choropleth!(sg, ["France"], [1.0]; row=1, col=1)
		@test sg.plot.data[end].fields[:geo] == "geo"
		@test_throws ArgumentError plot_densitymap!(sg, [1.0], [2.0], nothing; row=1, col=1)
	end

	@testset "nothing map roots are treated as empty" begin
		p = plot_scattermap([1.0], [2.0]; center_lon=1, center_lat=2)
		p.layout.fields[:map2] = nothing
		update_maps!(p.layout; zoom=3)
		@test _reg_fields(p.layout.fields[:map2])[:zoom] == 3
		@test _reg_fields(p.layout.fields[:map])[:zoom] == 3

		q = plot_scattermap([1.0], [2.0])
		q.layout.fields[:map2] = nothing
		@test update_maps!(q; zoom=4) === q
		@test _reg_fields(q.layout.fields[:map2])[:zoom] == 4

		sm = subplots(1, 2; sync=false, show=false, specs=[Spec(kind="map") Spec(kind="map")])
		relayout!(sm; map2=nothing)
		update_maps!(sm; row=1, col=2, zoom=3)
		@test _reg_fields(sm.plot.layout.fields[:map2])[:zoom] == 3

		sg = subplots(1, 2; sync=false, show=false, specs=[Spec(kind="geo") Spec(kind="geo")])
		relayout!(sg; geo2=nothing)
		update_geos!(sg; row=1, col=2, showland=true)
		@test _reg_fields(sg.plot.layout.fields[:geo2])[:showland] === true
	end

	@testset "update_maps! combines structured and flattened center" begin
		for target in (:layout, :plot)
			p = plot_scattermap([1.0], [2.0]; center_lon=1, center_lat=2)
			obj = target === :layout ? p.layout : p
			update_maps!(obj; center_lon=3, center=attr(lat=9))
			@test _reg_fields(_reg_fields(p.layout.fields[:map])[:center]) == Dict(:lon => 3, :lat => 9)

			p = plot_scattermap([1.0], [2.0]; center_lon=1, center_lat=2)
			obj = target === :layout ? p.layout : p
			update_maps!(obj, attr(center=attr(lon=4)); center=attr(lat=7))
			@test _reg_fields(_reg_fields(p.layout.fields[:map])[:center]) == Dict(:lon => 4, :lat => 7)

			p = plot_scattermap([1.0], [2.0]; center_lon=1, center_lat=2)
			obj = target === :layout ? p.layout : p
			@test_throws ArgumentError update_maps!(obj; center=nothing, center_lon=3)
			@test_throws ArgumentError update_maps!(obj; center_lon=3, center=nothing)
			@test_throws ArgumentError update_maps!(obj; bounds_west=0, bounds=nothing)
			@test _reg_fields(_reg_fields(p.layout.fields[:map])[:center]) == Dict(:lon => 1, :lat => 2)

			update_maps!(obj; center=nothing)
			@test _reg_fields(p.layout.fields[:map])[:center] === nothing
		end
		caller_center = attr(lat=5)
		p = plot_scattermap([1.0], [2.0])
		update_maps!(p; center_lon=1, center=caller_center)
		@test caller_center.fields == Dict(:lat => 5)
	end

	@testset "removed and internal map paths" begin
		@test !hasmethod(update_maps!, Tuple{PlotlySupply._StagedPlotMutation})
		sm = subplots(1, 1; sync=false, show=false, specs=reshape([Spec(kind="map")], 1, 1))
		@test_throws ArgumentError PlotlySupply._subplot_geographic_layout_key(sm, 1, 1, :map)
	end

	@testset "SubplotFigure updater docs and domain warning" begin
		for (fn, kind) in (
			(update_geos!, "geo"),
			(update_mapboxes!, "mapbox"),
			(update_maps!, "map"),
		)
			doc = string(Docs.doc(fn, Tuple{SubplotFigure}))
			@test occursin("sf::SubplotFigure", doc)
			@test occursin("active cell", doc)
			@test occursin("row", doc) && occursin("col", doc)
			@test occursin("sf.fig", doc)
			@test occursin("domain", doc)
		end
		generic = string(Docs.doc(update_maps!, Tuple{Layout}))
		@test occursin("SyncPlot", generic) && occursin("Plot", generic)

		sg = subplots(1, 2; sync=false, show=false, specs=[Spec(kind="geo") Spec(kind="geo")])
		domain_before = deepcopy(_reg_fields(sg.plot.layout.fields[:geo])[:domain])
		@test_logs (:warn, r"ignores `domain`") update_geos!(sg; row=1, col=1, domain=attr(x=[0.0, 0.2]))
		@test _reg_fields(sg.plot.layout.fields[:geo])[:domain] == domain_before
		@test_logs (:warn, r"ignores `domain`") update_geos!(sg, attr(domain=attr(x=[0.0, 0.2])); row=1, col=1)
		@test_logs update_geos!(sg; row=1, col=1, showland=true)

		sb = subplots(1, 1; sync=false, show=false, specs=reshape([Spec(kind="mapbox")], 1, 1))
		@test_logs (:warn, r"ignores `domain`") update_mapboxes!(sb; domain_x=[0.0, 0.5])
		sm = subplots(1, 1; sync=false, show=false, specs=reshape([Spec(kind="map")], 1, 1))
		@test_logs (:warn, r"ignores `domain`") update_maps!(sm; domain_x=[0.0, 0.5])
		@test_logs update_maps!(sm; zoom=2)
	end

	@testset "figure options: widened types, nested titles, validation" begin
		fig = plot_scattergeo(
			[1.0],
			[2.0];
			title=SubString("abc", 1, 2),
			width=600.4,
			height=400.0,
			fontsize=12.5,
			color=:red,
		)
		layout = fig.layout.fields
		@test _reg_fields(layout[:title]) == Dict(:text => "ab")
		@test layout[:width] === 600
		@test layout[:height] === 400
		@test _reg_fields(layout[:font])[:size] == 12.5
		@test fig.data[1].fields[:marker][:color] == "red"

		for build in (
			() -> plot_choropleth(["France"], [1.0]),
			() -> plot_scattermapbox([1.0], [2.0]),
			() -> plot_scattermap([1.0], [2.0]),
			() -> plot_densitymap([1.0], [2.0]),
			() -> plot_choroplethmap(_REG_MAP_SQUARE, ["A"], [1.0]),
		)
			@test !haskey(build().layout.fields, :title)
		end

		line = plot_choroplethmapbox(_REG_MAP_SQUARE, ["A"], [1.0]; marker_line_color=:white)
		@test line.data[1].fields[:marker][:line][:color] == "white"
		@test plot_scattermap([1.0], [2.0]; color=:blue).data[1].fields[:marker][:color] == "blue"

		for (name, value) in (
			(:width, -1),
			(:width, 5),
			(:width, Inf),
			(:height, NaN),
			(:height, true),
			(:fontsize, 0.5),
			(:fontsize, -2),
		)
			@test_throws ArgumentError plot_scattergeo([1.0], [2.0]; (name => value,)...)
			@test_throws ArgumentError plot_densitymap([1.0], [2.0]; (name => value,)...)
		end

		p = plot_scattergeo([1.0], [2.0]; title="A")
		p.layout.fields[:title] = attr(text="A", font=attr(size=20))
		@test_throws ArgumentError plot_scattergeo!(p, [3.0], [4.0]; width=-1)
		@test length(p.data) == 1
		plot_scattergeo!(p, [3.0], [4.0]; title="B")
		title = _reg_fields(p.layout.fields[:title])
		@test title[:text] == "B"
		@test _reg_fields(title[:font])[:size] == 20
		@test length(p.data) == 2
	end
end
