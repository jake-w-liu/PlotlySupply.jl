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

# `f()` throws an ArgumentError whose message contains `needle`.
function _reg_map_throws(f, needle::AbstractString)
	try
		f()
	catch err
		err isa ArgumentError || return false
		return occursin(needle, err.msg)
	end
	return false
end

# A call that throws leaves the figure exactly as it was.
function _reg_map_atomic(fig, f, needle::AbstractString)
	before = json(fig)
	return _reg_map_throws(f, needle) && json(fig) == before
end

# Nested layout value as plain Dicts (PlotlyAttribute compares by identity).
_reg_plain(value) =
	value isa Union{PlotlyBase.PlotlyAttribute, AbstractDict} ?
	Dict{Symbol, Any}(Symbol(key) => _reg_plain(item) for (key, item) in pairs(_reg_fields(value))) :
	value

@testset "regression: maps, v3 consistency" begin
	# (constructor, mutator, data (ranges and views), empty data, cell kind,
	#  name of the empty argument, the trace's subplot key)
	map_cases = (
		(plot_choropleth, plot_choropleth!, (["France", "Spain"], 1:2), (String[], Float64[]), "geo", "locations", :geo),
		(plot_scattergeo, plot_scattergeo!, (1:2, view([1.0, 2.0], :)), (Float64[], Float64[]), "geo", "lon", :geo),
		(plot_scattermapbox, plot_scattermapbox!, (1:2, [1.0, 2.0]), (Float64[], Float64[]), "mapbox", "lon", :subplot),
		(plot_choroplethmapbox, plot_choroplethmapbox!, (_REG_MAP_SQUARE, ["A"], 1:1), (_REG_MAP_SQUARE, String[], Float64[]), "mapbox", "locations", :subplot),
		(plot_densitymapbox, plot_densitymapbox!, (1:2, [1.0, 2.0], 1:2), (Float64[], Float64[], Float64[]), "mapbox", "lon", :subplot),
		(plot_scattermap, plot_scattermap!, (1:2, view([1.0, 2.0], :)), (Float64[], Float64[]), "map", "lon", :subplot),
		(plot_choroplethmap, plot_choroplethmap!, (_REG_MAP_SQUARE, ["A"], 1:1), (_REG_MAP_SQUARE, String[], Float64[]), "map", "locations", :subplot),
		(plot_densitymap, plot_densitymap!, (1:2, [1.0, 2.0]), (Float64[], Float64[]), "map", "lon", :subplot),
	)

	@testset "figure options go through the D7 primitives (X14)" begin
		title = L"Map $\alpha$"
		for (ctor, _, data) in map_cases
			fig = ctor(data...; title = title, width = 600.4, height = 400, fontsize = 12)
			layout = _reg_layout(fig)
			# The title used to be stored raw, so plotly drew the `$` signs.
			@test _reg_fields(layout[:title])[:text] == PlotlySupply._label(title)
			@test layout[:width] === 600
			@test layout[:height] === 400
			@test _reg_fields(layout[:font])[:size] == 12
		end
		# Under a style with a margin the title gets the same fitted padding
		# and automargin as every other chart's title (geo used to skip the
		# fit), and an explicit fontsize still wins over the style's size.
		with_style(:publication) do
			geo = plot_scattergeo([1.0], [2.0]; title = "Pub", fontsize = 20)
			pie = plot_pie([1, 2]; title = "Pub", fontsize = 20)
			@test _reg_plain(_reg_layout(geo)[:title]) == _reg_plain(_reg_layout(pie)[:title])
			@test haskey(_reg_plain(_reg_layout(geo)[:title]), :pad)
			@test _reg_fields(_reg_layout(geo)[:font])[:size] == 20
		end
		# Invalid titles and sizes name the public function and change nothing.
		target = plot_scattermap([1.0], [2.0]; title = "A")
		@test _reg_map_atomic(target, () -> plot_scattermap!(target, [3.0], [4.0]; title = "cost \$5"), "plot_scattermap!: `title`")
		@test _reg_map_atomic(target, () -> plot_scattermap!(target, [3.0], [4.0]; width = 5), "plot_scattermap!: `width`")
		@test _reg_map_throws(() -> plot_choropleth(["France"], [1.0]; fontsize = -1), "plot_choropleth: `fontsize`")
	end

	@testset "keywords, show, empty data and errors on every map function (consistency sweep)" begin
		for (ctor, mut, data, empty, kind, first_name, subplot_key) in map_cases
			who = String(nameof(ctor))
			# G23: raw plotly trace attributes pass through ONE explicit keyword,
			# `trace` (attr, Dict or NamedTuple; nested names with underscores).
			for raw in (
				attr(hovertemplate = "%{lon}", hoverlabel_bgcolor = "white", legendgroup = "g"),
				Dict(:hovertemplate => "%{lon}", "hoverlabel_bgcolor" => "white", :legendgroup => "g"),
				(hovertemplate = "%{lon}", hoverlabel_bgcolor = "white", legendgroup = "g"),
			)
				trace = only(ctor(data...; trace = raw).data)
				@test trace.fields[:hovertemplate] == "%{lon}"
				@test _reg_fields(trace.fields[:hoverlabel])[:bgcolor] == "white"
				@test trace.fields[:legendgroup] == "g"
			end
			for (call, needle) in (
				# Bare plotly attributes are no longer keywords (2.0).
				(() -> ctor(data...; hovertemplate = "%{lon}"), "$(who): unknown keyword argument(s) `hovertemplate`"),
				(() -> ctor(data...; no_such_kw = 1), "$(who): unknown keyword argument(s) `no_such_kw`"),
				(() -> ctor(data...; xaxis_type = "log"), "$(who): unknown keyword argument(s) `xaxis_type`"),
				(() -> ctor(data...; trace = (no_such_attr = 1,)), "$(who): `trace` attribute `no_such_attr` is not a plotly.js"),
				(() -> ctor(data...; trace = Dict(:xaxis_type => "log")), "$(who): `trace` attribute `xaxis_type` is not a plotly.js"),
				(() -> ctor(data...; trace = attr(bogus = 1)), "$(who): `trace` attribute `bogus` is not a plotly.js"),
				(() -> ctor(data...; trace = (type = "bar",)), "$(who): `trace` attribute `type` sets the trace's `type`, which is fixed"),
				(() -> ctor(data...; trace = Dict(Symbol(first_name) => [0])), "$(who): `trace` attribute `$(first_name)` sets the trace's"),
				(() -> ctor(data...; trace = attr(name = "raw")), "which comes from the `legend` keyword"),
				(() -> ctor(data...; trace = attr(colorscale = "RdBu")), "$(who): `trace` "),
				(() -> ctor(data...; trace = "hovertemplate"), "$(who): `trace` must be an `attr(...)`"),
				(() -> ctor(empty...), "$(who): `$(first_name)` is empty"),
			)
				@test _reg_map_throws(call, needle)
			end
			# The caller's `trace` attributes are never mutated.
			raw = attr(hoverlabel = attr(bgcolor = "white"))
			ctor(data...; trace = raw, legend = "named")
			@test _reg_plain(raw) == Dict(:hoverlabel => Dict(:bgcolor => "white"))

			target = ctor(data...)
			@test mut(target, data...; title = L"New $\beta$") === nothing
			@test length(target.data) == 2
			@test _reg_fields(_reg_layout(target)[:title])[:text] == PlotlySupply._label(L"New $\beta$")
			@test mut(target, data...; trace = attr(legendgroup = "m")) === nothing
			@test last(target.data).fields[:legendgroup] == "m"
			for (call, needle) in (
				# `show` and `row`/`col` used to become trace attributes.
				(() -> mut(target, data...; show = true), "$(who)!: mutators do not take `show`"),
				(() -> mut(target, data...; row = 1, col = 1), "$(who)!: `row`/`col` select a SubplotFigure cell"),
				(() -> mut(target, data...; no_such_kw = 1), "$(who)!: unknown keyword argument(s) `no_such_kw`"),
				(() -> mut(target, data...; hovertemplate = "x"), "$(who)!: unknown keyword argument(s) `hovertemplate`"),
				(() -> mut(target, data...; trace = (no_such_attr = 1,)), "$(who)!: `trace` attribute `no_such_attr`"),
				(() -> mut(target, empty...), "$(who)!: `$(first_name)` is empty"),
			)
				@test _reg_map_atomic(target, call, needle)
			end

			sf = subplots(1, 2; sync = false, show = false, specs = [Spec(kind = kind) Spec(kind = kind)])
			@test mut(sf, data...; row = 1, col = 2, trace = attr(legendgroup = "s")) === sf
			@test last(sf.fig.data).fields[subplot_key] == "$(kind)2"
			@test last(sf.fig.data).fields[:legendgroup] == "s"
			for (call, needle) in (
				(() -> mut(sf, data...; show = true), "mutators do not take `show`"),
				(() -> mut(sf, data...; row = 1, col = 2, no_such_kw = 1), "$(who)!: unknown keyword argument(s) `no_such_kw`"),
				(() -> mut(sf, data...; row = 1, col = 2, trace = (no_such_attr = 1,)), "$(who)!: `trace` attribute `no_such_attr`"),
				(() -> mut(sf, empty...; row = 1, col = 1), "$(who)!: `$(first_name)` is empty"),
				(() -> mut(sf, data...; row = 3, col = 1), "`row` must be in 1:1"),
			)
				@test _reg_map_atomic(sf.fig, call, needle)
			end
		end
		# Errors raised by the shared validators name the public function.
		for (call, needle) in (
			(() -> plot_scattergeo([0.0], [1.0, 2.0]), "plot_scattergeo: lon, lat must share length"),
			(() -> plot_scattermapbox([0.0], [1.0]; marker_size = -1), "plot_scattermapbox: marker_size"),
			(() -> plot_densitymap([0.0], [1.0]; radius = 0.5), "plot_densitymap: radius"),
			(() -> plot_choropleth(["USA"], [1.0]; locationmode = "zip"), "plot_choropleth: `locationmode`"),
			(() -> plot_choroplethmap(nothing, ["A"], [1.0]), "plot_choroplethmap: `geojson`"),
			(() -> plot_scattermap([0.0], [1.0]; zoom = NaN), "plot_scattermap: zoom"),
			(() -> plot_densitymapbox([0.0], [1.0], [1.0]; style = ""), "plot_densitymapbox: style"),
			(() -> plot_scattermapbox!(Plot(), [0.0], [1.0]; center_lat = Inf), "plot_scattermapbox!: center_lat"),
			(() -> plot_choroplethmap!(Plot(), _REG_MAP_SQUARE, ["A"], [1.0]; style = ""), "plot_choroplethmap!: style"),
		)
			@test _reg_map_throws(call, needle)
		end
	end

	@testset "colour scales resolve like every other colorscale keyword; legends are mathtext" begin
		resolved(name) = PlotlySupply._resolve_colorscale(name; who = "test").scale
		@test plot_choropleth(["France"], [1.0]; colorscale = :viridis).data[1].fields[:colorscale] == resolved("viridis")
		@test plot_choroplethmap(_REG_MAP_SQUARE, ["A"], [1.0]; colorscale = "magma_r").data[1].fields[:colorscale] == resolved("magma_r")
		@test plot_densitymapbox([0.0], [1.0], [1.0]; colorscale = ["white", "red"]).data[1].fields[:colorscale] == resolved(["white", "red"])
		# "Blues" means the same colours (light to dark) as on a heatmap.
		@test plot_choroplethmapbox(_REG_MAP_SQUARE, ["A"], [1.0]; colorscale = "Blues").data[1].fields[:colorscale] ==
			plot_heatmap(rand(2, 2); colorscale = "Blues").data[1].fields[:colorscale]
		@test !haskey(plot_densitymap([0.0], [1.0]).data[1].fields, :colorscale)
		@test _reg_map_throws(() -> plot_densitymap([0.0], [1.0]; colorscale = "nope"), "plot_densitymap: unknown colorscale")
		@test _reg_map_throws(() -> plot_choropleth(["France"], [1.0]; colorscale = "nope"), "plot_choropleth: unknown colorscale")

		legend = L"route $\alpha$"
		@test plot_scattermap([1.0], [2.0]; legend = legend).data[1].fields[:name] == PlotlySupply._label(legend)
		@test plot_choroplethmapbox(_REG_MAP_SQUARE, ["A"], [1.0]; legend = legend).data[1].fields[:name] == PlotlySupply._label(legend)
		@test plot_scattergeo([1.0], [2.0]; legend = "plain").data[1].fields[:name] == "plain"
		@test _reg_map_throws(() -> plot_scattergeo([1.0], [2.0]; legend = "a \$b"), "plot_scattergeo: `legend`")

		# G24: numeric scatter-map colours go through the same resolution (no
		# raw `marker_colorscale` route any more; RdBu runs red to blue).
		for (ctor, mut) in (
			(plot_scattergeo, plot_scattergeo!),
			(plot_scattermap, plot_scattermap!),
			(plot_scattermapbox, plot_scattermapbox!),
		)
			who = String(nameof(ctor))
			marker = _reg_fields(ctor([0.0, 1.0], [0.0, 1.0]; color = [1.0, 2.0], colorscale = "RdBu").data[1].fields[:marker])
			@test marker[:colorscale] == resolved("RdBu")
			@test first(marker[:colorscale])[2] == "#67001F" && last(marker[:colorscale])[2] == "#053061"
			@test marker[:color] == [1.0, 2.0]
			@test !haskey(_reg_fields(ctor([0.0], [1.0]; color = [3]).data[1].fields[:marker]), :colorscale)
			target = ctor([0.0], [1.0])
			@test mut(target, [1.0], [2.0]; color = [5], colorscale = :viridis) === nothing
			@test _reg_fields(last(target.data).fields[:marker])[:colorscale] == resolved("viridis")
			for (call, needle) in (
				(() -> ctor([0.0], [1.0]; color = [1.0], colorscale = "nope"), "$(who): unknown colorscale"),
				(() -> ctor([0.0], [1.0]; color = "red", colorscale = "RdBu"), "$(who): `colorscale` colours numeric `color` values"),
				(() -> ctor([0.0], [1.0]; colorscale = "RdBu"), "$(who): `colorscale` colours numeric `color` values"),
				(() -> ctor([0.0], [1.0]; trace = attr(marker_colorscale = "RdBu")), "$(who): `trace` may not set a `colorscale`"),
				(() -> ctor([0.0], [1.0]; trace = attr(marker = attr(line = attr(colorscale = "RdBu")))), "$(who): `trace` may not set a `colorscale`"),
				(() -> ctor([0.0], [1.0]; trace = attr(marker_color = "red")), "$(who): `trace` attribute `marker_color` is set by the `color` keyword"),
				(() -> ctor([0.0], [1.0]; trace = attr(marker_size = 3)), "$(who): `trace` attribute `marker_size` is set by the `marker_size` keyword"),
				(() -> ctor([0.0], [1.0]; trace = attr(mode = "lines")), "which comes from the `mode` keyword"),
			)
				@test _reg_map_throws(call, needle)
			end
			@test _reg_map_atomic(target, () -> mut(target, [1.0], [2.0]; color = [1], colorscale = "nope"), "$(who)!: unknown colorscale")
			# Other marker attributes still pass through `trace`.
			marker = _reg_fields(ctor([0.0], [1.0]; color = "red", trace = attr(marker_symbol = "square")).data[1].fields[:marker])
			@test (marker[:color], marker[:symbol]) == ("red", "square")
		end
		@test _reg_map_throws(() -> plot_choropleth(["USA"], [1.0]; trace = attr(locationmode = "ISO-3")), "which comes from the `locationmode` keyword")
		@test _reg_map_throws(() -> plot_choropleth(["USA"], [1.0]; trace = attr(geojson = _REG_MAP_SQUARE)), "which comes from the `geojson` keyword")
		@test _reg_map_throws(() -> plot_densitymap([0.0], [1.0]; trace = attr(radius = 3)), "which comes from the `radius` keyword")
		@test _reg_map_throws(() -> plot_choroplethmap(_REG_MAP_SQUARE, ["A"], [1.0]; trace = attr(marker_opacity = 0.5)), "is set by the `marker_opacity` keyword")
		@test _reg_map_throws(() -> plot_choroplethmapbox(_REG_MAP_SQUARE, ["A"], [1.0]; trace = attr(marker_line_width = 2)), "is set by the `marker_line_width` keyword")

		# G25: every map function names its trace through `legend` (mathtext via
		# `_label`). plot_choropleth and the density maps had no `legend`
		# keyword, so `legend = "..."` became plotly's trace `legend` id. A
		# name turns on the entry of the trace types plotly hides by default.
		mixed = "Stations \$\\alpha\$ network"
		for (ctor, mut, data) in map_cases
			who = String(nameof(ctor))
			trace = only(ctor(data...; legend = mixed).data)
			@test trace.fields[:name] == PlotlySupply._label(mixed)
			@test occursin("\\text{Stations }", trace.fields[:name]) && occursin("\\text{ network}", trace.fields[:name])
			@test !haskey(trace.fields, :legend)
			kind = trace.fields[:type]
			if kind in ("scattergeo", "scattermap", "scattermapbox")
				@test !haskey(trace.fields, :showlegend)
			else
				@test trace.fields[:showlegend] === true
				@test only(ctor(data...; legend = "x", trace = attr(showlegend = false)).data).fields[:showlegend] === false
			end
			@test !haskey(only(ctor(data...).data).fields, :name)
			@test !haskey(only(ctor(data...).data).fields, :showlegend)
			target = ctor(data...)
			@test mut(target, data...; legend = L"two $\beta$") === nothing
			@test last(target.data).fields[:name] == PlotlySupply._label(L"two $\beta$")
			@test _reg_map_atomic(target, () -> mut(target, data...; legend = "a \$b"), "$(who)!: `legend`")
		end
	end

	@testset "scattergeo applies the active style's trace defaults (X10)" begin
		with_style(PlotStyle(; linewidth = 3, marker_size = 9, cycle = :dash_marker)) do
			reference = plot_scatter(1:2, [1, 2]; mode = "lines")
			plot_scatter!(reference, 1:2, [2, 1]; mode = "lines")
			fig = plot_scattergeo([1.0, 2.0], [2.0, 3.0]; mode = "lines")
			@test plot_scattergeo!(fig, [1.0, 2.0], [3.0, 4.0]; mode = "lines", marker_size = 4) === nothing
			for index in 1:2
				line = _reg_fields(fig.data[index].fields[:line])
				@test line[:width] == 3
				@test line[:dash] == _reg_fields(reference.data[index].fields[:line])[:dash]
				@test fig.data[index].fields[:mode] == "lines"
			end
			@test _reg_fields(fig.data[1].fields[:marker])[:size] == 9
			@test _reg_fields(fig.data[2].fields[:marker])[:size] == 4
			# Tile-map scatter traces are not line-style traces (no `line.dash`,
			# icon `marker.symbol`): the style leaves them alone.
			@test !haskey(plot_scattermap([1.0], [2.0]; mode = "lines").data[1].fields, :line)
			@test !haskey(plot_scattermapbox([1.0], [2.0]; mode = "lines").data[1].fields, :line)
		end
		@test !haskey(plot_scattergeo([1.0], [2.0]).data[1].fields, :line)
	end

	@testset "update_* docstrings name the receivers and the SubplotFigure rules (#304)" begin
		for fn in (update_xaxes!, update_yaxes!, update_polars!, update_scenes!, update_ternaries!,
			update_geos!, update_mapboxes!, update_maps!, update_annotations!, update_images!, update_shapes!)
			text = string(Base.Docs.doc(fn))
			# "`scene`2" used to be generated for the numbered objects.
			@test !occursin(r"`\d", text)
			@test occursin("SyncPlot", text)
			@test occursin("SubplotFigure", text)
			@test occursin("row", text)
			@test !occursin("has no `SubplotFigure` method", text)
		end
		@test occursin("(`scene`, `scene2`, `scene3`, …)", string(Base.Docs.doc(update_scenes!)))
		@test occursin("object of ONE cell", string(Base.Docs.doc(update_geos!)))
		# The documented behaviour: whole figure without row/col, one cell with them.
		sf = subplots(1, 2; sync = false, show = false, specs = [Spec(kind = "scene") Spec(kind = "scene")])
		@test update_scenes!(sf; row = 1, col = 2, aspectmode = "cube") === sf
		@test _reg_fields(_reg_layout(sf)[:scene2])[:aspectmode] == "cube"
		@test !haskey(_reg_fields(_reg_layout(sf)[:scene]), :aspectmode)
		@test update_scenes!(sf; dragmode = "orbit") === sf
		@test all(_reg_fields(_reg_layout(sf)[key])[:dragmode] == "orbit" for key in (:scene, :scene2))
		geo = subplots(1, 2; sync = false, show = false, specs = [Spec(kind = "geo") Spec(kind = "geo")])
		@test update_geos!(geo; showland = true) === geo
		@test _reg_fields(_reg_layout(geo)[:geo])[:showland] === true
		@test !haskey(_reg_fields(_reg_layout(geo)[:geo2]), :showland)
	end

	@testset "map figures are built offline; tile maps render without network" begin
		# Every constructor builds a plain figure value: nothing is fetched.
		# A style whose only layer is a background and whose glyph URL is a
		# closed local port makes any network request fail the export
		# ("Map error"), so a successful export needed no network.
		offline_style = Dict(
			"version" => 8,
			"sources" => Dict{String, Any}(),
			"glyphs" => "http://127.0.0.1:9/{fontstack}/{range}.pbf",
			"layers" => [Dict("id" => "bg", "type" => "background", "paint" => Dict("background-color" => "#eeeeff"))],
		)
		png_magic = UInt8[0x89, 0x50, 0x4e, 0x47]
		for fig in (
			plot_scattermap([2.35, 13.4], [48.86, 52.52]; style = offline_style, zoom = 3, center_lon = 8, center_lat = 50),
			plot_choroplethmap(_REG_MAP_SQUARE, ["A"], [1.0]; style = offline_style, zoom = 3, center_lon = 2.5, center_lat = 2.5),
			plot_densitymap([0.0, 0.5], [0.0, 0.5], [1, 2]; radius = 20, style = offline_style, zoom = 5),
			plot_scattermapbox([2.35, 13.4], [48.86, 52.52]; style = offline_style, zoom = 3),
			plot_choroplethmapbox(_REG_MAP_SQUARE, ["A"], [1.0]; style = offline_style, zoom = 3),
			plot_densitymapbox([0.0, 0.5], [0.0, 0.5], [1, 2]; radius = 20, style = offline_style, zoom = 5),
		)
			bytes = savefig(fig; format = "png", width = 300, height = 200)
			@test bytes[1:4] == png_magic
		end
		# Geo maps fetch their outlines (topojson) from cdn.plot.ly when drawn:
		# offline the export fails with plotly.js' topojson error, and the
		# rendering check is skipped rather than failed.
		geo_bytes = try
			savefig(plot_scattergeo([2.35], [48.86]; scope = "europe"); format = "png", width = 300, height = 200)
		catch err
			occursin("topojson", sprint(showerror, err)) || rethrow()
			nothing
		end
		if geo_bytes === nothing
			@test_skip geo_bytes !== nothing
		else
			@test geo_bytes[1:4] == png_magic
		end
	end
end

@testset "regression: a single geo/map figure keeps its legend off the colorbar (Z49)" begin
	legend(fig) = _reg_fields(_reg_layout(fig)[:legend])
	at(fig) = (legend(fig)[:x], legend(fig)[:xanchor], legend(fig)[:y], legend(fig)[:yanchor])
	# The default legend sits at the top right, placed by its right edge; a
	# legend name with typeset math is widened after placement and grew over
	# the colorbar plotly draws right of the map. With a vertical bar the
	# default legend now takes the mirrored top-left corner.
	geo = plot_choropleth(["France", "Germany"], [1.0, 2.0]; colorscale = "Blues",
		legend = "Regions \$\\alpha\$", scope = "europe")
	@test at(geo) == (0.02, "left", 0.97, "top")
	plot_scattergeo!(geo, [2.35], [48.86]; legend = "cities \$x_1\$")
	@test at(geo) == (0.02, "left", 0.97, "top")
	map = plot_choroplethmap(_REG_MAP_SQUARE, ["A"], [1.0]; legend = "areas", style = "white-bg")
	@test at(map) == (0.02, "left", 0.97, "top")
	density = plot_densitymap([2.0, 2.5], [2.0, 2.5], [1.0, 2.0]; legend = "density", style = "white-bg")
	@test at(density) == (0.02, "left", 0.97, "top")

	# No colorbar: the default corner stays.
	points = plot_scattergeo([2.35, 13.4], [48.86, 52.52]; legend = "cities")
	@test at(points) == (0.98, "right", 0.97, "top")
	# Numeric marker colours draw no bar unless `marker_showscale = true`.
	coloured = plot_scattermap([2.0, 3.0], [48.0, 49.0]; color = [1.0, 2.0], colorscale = "Viridis", legend = "pts")
	@test at(coloured) == (0.98, "right", 0.97, "top")
	plot_scattermap!(coloured, [4.0], [50.0]; color = [3.0], colorscale = "Viridis", legend = "bar",
		trace = attr(marker_showscale = true))
	@test at(coloured) == (0.02, "left", 0.97, "top")
	# A horizontal bar below the map does not move the legend.
	flat = plot_choropleth(["France"], [1.0]; legend = "r", trace = attr(colorbar_orientation = "h"))
	@test at(flat) == (0.98, "right", 0.97, "top")
	# A legend placed by the user is left where it is.
	placed = plot_scattergeo([2.35], [48.86]; legend = "p")
	set_legend!(placed; position = :bottomright)
	before = at(placed)
	plot_choropleth!(placed, ["France"], [1.0]; legend = "r")
	@test at(placed) == before
	# A Cartesian figure with a colorbar and the default legend is not a map:
	# left as it is.
	heat = plot_heatmap([1 2; 3 4])
	plot_scatter!(heat, [0, 1], [0, 1]; legend = "line")
	set_legend!(heat; position = :topright)
	before = at(heat)
	@test before == (0.98, "right", 0.97, "top")
	PlotlySupply._geo_legend_clear_of_colorbar!(heat)
	@test at(heat) == before
end
