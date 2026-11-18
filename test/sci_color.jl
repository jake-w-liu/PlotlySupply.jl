using Test, PlotlySupply

@testset "sci color (src/sci/color.jl)" begin
	P = PlotlySupply
	J = PlotlyBase.JSON
	resolve(cs; who = "test") = P._resolve_colorscale(cs; who)
	rgb_bytes(h) = (parse(Int, h[2:3]; base = 16), parse(Int, h[4:5]; base = 16), parse(Int, h[6:7]; base = 16))
	near(a, b; tol = 1) = maximum(abs.(rgb_bytes(a) .- rgb_bytes(b))) <= tol
	thrown(f) = try
		f()
		nothing
	catch err
		err
	end
	message(f) = (err = thrown(f); err === nothing ? "" : sprint(showerror, err))
	json_roundtrip(x) = J.parse(J.json(x))

	@testset "named colormaps follow matplotlib (published endpoints)" begin
		# First/last colours of matplotlib's colormaps (matplotlib _cm.py /
		# _cm_listed.py, rendered to 8-bit hex).
		ends = Dict(
			"viridis" => ("#440154", "#FDE725"), "plasma" => ("#0D0887", "#F0F921"),
			"inferno" => ("#000004", "#FCFFA4"), "magma" => ("#000004", "#FCFDBF"),
			"turbo" => ("#30123B", "#7A0403"), "twilight" => ("#E2D9E2", "#E2D9E2"),
			"coolwarm" => ("#3B4CC0", "#B40426"), "seismic" => ("#00004C", "#800000"),
			"bwr" => ("#0000FF", "#FF0000"), "RdBu" => ("#67001F", "#053061"),
			"PuOr" => ("#7F3B08", "#2D004B"), "RdYlBu" => ("#A50026", "#313695"),
			"Spectral" => ("#9E0142", "#5E4FA2"), "PiYG" => ("#8E0152", "#276419"),
			"PRGn" => ("#40004B", "#00441B"), "RdGy" => ("#67001F", "#1A1A1A"),
			"BrBG" => ("#543005", "#003C30"), "Blues" => ("#F7FBFF", "#08306B"),
			"Greys" => ("#FFFFFF", "#000000"), "Reds" => ("#FFF5F0", "#67000D"),
			"Greens" => ("#F7FCF5", "#00441B"), "Oranges" => ("#FFF5EB", "#7F2704"),
			"Purples" => ("#FCFBFD", "#3F007D"), "YlGnBu" => ("#FFFFD9", "#081D58"),
			"YlOrRd" => ("#FFFFCC", "#800026"), "hot" => ("#0B0000", "#FFFFFF"),
			"jet" => ("#000080", "#800000"), "rainbow" => ("#8000FF", "#FF0000"),
			"gray" => ("#000000", "#FFFFFF"), "grey" => ("#000000", "#FFFFFF"),
			# cividis follows plotly.js/plotly.py (viridisLite), not matplotlib.
			"cividis" => ("#00204D", "#FFEA46"),
		)
		# The registry holds exactly the built-in maps, apart from "ice": test/docs_examples.jl
		# runs the registration example of docs/src/colors.md before this file when the
		# whole suite runs, and COLORMAPS is a user-extensible global.
		@test Set(keys(P.COLORMAPS)) ∪ Set(["ice"]) == Set(keys(ends)) ∪ Set(["ice"])
		for (name, (first_colour, last_colour)) in ends
			scale = resolve(name).scale
			@test scale[1] == Any[0.0, first_colour]
			@test scale[end] == Any[1.0, last_colour]
			@test resolve(name).reversescale == false
			@test issorted(first.(scale))
		end
		@test length(resolve("viridis").scale) == 256
		@test length(resolve("twilight").scale) == 510
		@test length(resolve("RdBu").scale) == 11
		# Interior samples of matplotlib's maps (same reference), within 1/255.
		interior = Dict(
			"viridis" => ("#3B528B", "#21908C", "#5DC963"), "magma" => ("#50127C", "#B63779", "#FB8761"),
			"RdBu" => ("#E58268", "#F7F7F7", "#6AACD0"), "coolwarm" => ("#8DB0FE", "#DDDDDD", "#F49A7B"),
			"BrBG" => ("#CFA255", "#F5F5F5", "#5AB2A8"), "twilight" => ("#6275BA", "#2F1437", "#B25652"),
		)
		for (name, expected) in interior, (t, colour) in zip((0.25, 0.5, 0.75), expected)
			@test near(P._sample_colorscale(name, t), colour)
		end
		# jet, rainbow and hot are matplotlib's segment maps, sampled to 101/100 entries.
		for (name, expected) in ("jet" => ("#0080FF", "#7BFF7B", "#FF9700"), "rainbow" => ("#00B4EC", "#80FFB4", "#FFB462"),
				"hot" => ("#B20000", "#FF5A00", "#FFFF04"))
			for (t, colour) in zip((0.25, 0.5, 0.75), expected)
				@test near(P._sample_colorscale(name, t), colour; tol = 3)
			end
		end
		@test P._sample_colorscale("bwr", 0.5) == "#FFFFFF"
		@test P._sample_colorscale("seismic", 0.5) == "#FFFFFF"
		@test P._sample_colorscale("gray", 0.5) == "#808080"
	end

	@testset "names are case-insensitive, Symbols work, _r reverses" begin
		reference = resolve("magma").scale
		for variant in ("Magma", "MAGMA", :magma, " magma ", SubString("xmagma", 2))
			@test resolve(variant).scale == reference
		end
		for name in ("RdBu", "viridis", "coolwarm", "twilight", "BrBG")
			forward = resolve(name).scale
			backward = resolve(name * "_r").scale
			@test [s[2] for s in backward] == reverse([s[2] for s in forward])
			@test backward[1][1] == 0.0 && backward[end][1] == 1.0
			@test issorted(first.(backward))
			@test all(isapprox.(first.(backward), 1 .- reverse(first.(forward)); atol = 1e-12))
			@test resolve(lowercase(name) * "_R").scale == backward
		end
		@test resolve("RdBu_r").scale[1] == Any[0.0, "#053061"]
		@test resolve("RdBu_r").scale[end] == Any[1.0, "#67001F"]
		@test resolve(:RdBu_r).reversescale == false
	end

	@testset "BREAKING: plotly.js-reversed names now follow matplotlib/plotly.py" begin
		# plotly.js 2.35.2 starts these at their dark/blue end; 2.0 resolves the
		# matplotlib orientation (the low end is the light/red end).
		@test resolve("RdBu").scale[1][2] == "#67001F"   # plotly.js: rgb(5,10,172)
		@test resolve("Blues").scale[1][2] == "#F7FBFF"  # plotly.js: rgb(5,10,172)
		@test resolve("Greys").scale[1][2] == "#FFFFFF"  # plotly.js: rgb(0,0,0)
		@test resolve("Greens").scale[1][2] == "#F7FCF5" # plotly.js: rgb(0,68,27)
		@test resolve("YlGnBu").scale[1][2] == "#FFFFD9" # plotly.js: rgb(8,29,88)
		@test resolve("YlOrRd").scale[1][2] == "#FFFFCC" # plotly.js: rgb(128,0,38)
		# Viridis/Jet/Hot are expanded too (no silent reliance on plotly.js names).
		@test resolve("Viridis").scale isa Vector
	end

	@testset "plotly.js-only names pass through; _r expands" begin
		@test resolve("Picnic") == (scale = "Picnic", reversescale = false)
		@test resolve("picnic").scale == "Picnic"
		@test resolve(:EARTH).scale == "Earth"
		for name in ("Bluered", "Portland", "Electric", "Blackbody")
			@test resolve(lowercase(name)).scale == name
		end
		reversed = resolve("Picnic_r")
		@test reversed.reversescale == false
		@test length(reversed.scale) == 11
		@test reversed.scale[1] == Any[0.0, "#FF0000"]
		@test reversed.scale[end] == Any[1.0, "#0000FF"]
		@test reversed.scale[6] == Any[0.5, "#FFFFFF"]
		# The embedded stops equal the definitions in the bundled plotly.js.
		bundle = read(P._plotlyjs_asset_path(), String)
		for name in P._PLOTLYJS_PASSTHROUGH_NAMES
			m = match(Regex("\\b" * name * ":(\\[\\[.*?\\]\\])"), bundle)
			@test m !== nothing
			m === nothing && continue
			definition = J.parse(replace(m.captures[1], "[." => "[0."))
			expected = [Any[Float64(t), P._color_hex(c)] for (t, c) in definition]
			@test P._passthrough_stops(name) == expected
		end
	end

	@testset "unknown names throw with suggestions" begin
		@test_throws ArgumentError resolve("magmma")
		msg = message(() -> resolve("magmma"; who = "plot_heatmap"))
		@test startswith(msg, "ArgumentError: plot_heatmap: unknown colorscale \"magmma\"; did you mean: magma")
		@test occursin("did you mean: RdBu_r", message(() -> resolve("RdBuu_r")))
		@test occursin("unknown colorscale \"definitely_not_a_map\"", message(() -> resolve("definitely_not_a_map")))
		# Ambiguous case-insensitive ColorSchemes.jl names are rejected.
		@test occursin("Spring, spring", message(() -> resolve("SPRING")))
		@test_throws ArgumentError resolve(42)
		@test_throws ArgumentError resolve((0, "red"))
	end

	@testset "ColorSchemes.jl names and ColorScheme objects" begin
		batlow = P.ColorSchemes.colorschemes[:batlow]
		scale = resolve("batlow").scale
		@test length(scale) == length(batlow.colors)
		@test scale[1][2] == P._color_hex(batlow.colors[1])
		@test scale[end][2] == P._color_hex(batlow.colors[end])
		@test resolve("BATLOW").scale == scale
		@test resolve("batlow_r").scale[1][2] == scale[end][2]
		@test resolve(P.ColorSchemes.colorschemes[:viridis]).scale == resolve("viridis").scale
	end

	@testset "custom colorscale vectors are validated and round-trip" begin
		expected = [Any[0.0, "#FF0000"], Any[0.5, "#008000"], Any[1.0, "#0000FF"]]
		@test resolve([(0, "red"), (0.5, :green), (1, "#00f")]).scale == expected
		@test resolve([0 => "red", 0.5 => "green", 1 => "blue"]).scale == expected
		@test resolve(Any[Any[0, "red"], Any[0.5, "green"], Any[1, "blue"]]).scale == expected
		@test resolve(["red", "green", "blue"]).scale == expected
		@test resolve([:red, :green, :blue]).scale == expected
		@test resolve([P.Colors.RGB(1, 0, 0), P.Colors.RGB(0, 0, 1)]).scale ==
			[Any[0.0, "#FF0000"], Any[1.0, "#0000FF"]]
		@test resolve(["red"]).scale == [Any[0.0, "#FF0000"], Any[1.0, "#FF0000"]]
		@test resolve("[[0, \"red\"], [1, \"blue\"]]").scale == [Any[0.0, "#FF0000"], Any[1.0, "#0000FF"]]
		@test resolve([(0, "rgba(255,0,0,0.5)"), (1, "blue")]).scale[1] == Any[0.0, "rgba(255,0,0,0.5)"]
		# Steps (repeated positions) are allowed.
		@test length(resolve([(0, "red"), (0.5, "red"), (0.5, "blue"), (1, "blue")]).scale) == 4
		# colormap() output is accepted back unchanged.
		@test resolve(colormap("viridis")).scale == resolve("viridis").scale
		@test resolve(discrete_colormap(["red", "blue"])).scale ==
			[Any[0.0, "#FF0000"], Any[0.5, "#FF0000"], Any[0.5, "#0000FF"], Any[1.0, "#0000FF"]]
		for bad in (
			Any[], [(0.1, "red"), (1, "blue")], [(0, "red"), (0.9, "blue")],
			[(0, "red"), (0.6, "green"), (0.5, "blue"), (1, "black")], [(0, "red"), (NaN, "blue"), (1, "black")],
			[(0, "red"), (1.5, "blue")], [(0, "red"), (1, "notacolour")], [(0, "red")], ["red", (1, "blue")],
			[(0, "red", 1)], [0.0, 1.0], ["red", "nope"], "[[0, \"red\"], [1, ", "{\"a\": 1}",
			["red" => 0, "blue" => 1], [(true, "red"), (1, "blue")], [(0, "red"), (missing, "blue")],
		)
			@test_throws ArgumentError resolve(bad)
		end
		@test occursin("start at t = 0 and end at t = 1", message(() -> resolve([(0.1, "red"), (1, "blue")])))
		@test occursin("non-decreasing", message(() -> resolve([(0, "red"), (0.6, "green"), (0.5, "blue"), (1, "black")])))
	end

	@testset "unset colorscale" begin
		for unset in ("", "  ", nothing, Symbol(""))
			@test resolve(unset) == (scale = "", reversescale = false)
		end
	end

	@testset "colour parsing and formatting" begin
		@test P._color_hex("red") == "#FF0000"
		@test P._color_hex(:red) == "#FF0000"
		@test P._color_hex("Red") == "#FF0000"
		@test P._color_hex("#f00") == "#FF0000"
		@test P._color_hex("#1f77b4") == "#1F77B4"
		@test P._color_hex("rgb(31, 119, 180)") == "#1F77B4"
		@test P._color_hex("rgb(100%, 0%, 50%)") == "#FF0080"
		@test P._color_hex("rgba(255,0,0,0.5)") == "rgba(255,0,0,0.5)"
		@test P._color_hex("rgba(0,0,0,.25)") == "rgba(0,0,0,0.25)"
		@test P._color_hex("rgba(255,0,0,1)") == "#FF0000"
		@test P._color_hex("#ff000080") == "rgba(255,0,0,0.502)"
		@test P._color_hex("#f008") == "rgba(255,0,0,0.5333)"
		@test P._color_hex("transparent") == "rgba(0,0,0,0)"
		@test P._color_hex("hsl(120, 100%, 25%)") == "#008000"
		@test P._color_hex(P.Colors.RGB(1, 0, 0)) == "#FF0000"
		@test P._color_hex(P.Colors.RGBA(0, 0, 1, 0.25)) == "rgba(0,0,255,0.25)"
		@test P._color_hex(P.Colors.Gray(0.5)) == "#808080"
		@test P._color_hex("rgb(300, -5, 0)") == "#FF0000"   # clamped like CSS/tinycolor
		for bad in ("", "  ", "notacolour", "#12", "#gggggg", "rgb(1,2)", "rgba(1,2,3)", "rgb(1,2,3,0.5)", "rgb(a,b,c)", 1, nothing)
			@test_throws ArgumentError P._color_hex(bad)
		end
		@test startswith(message(() -> P._color_hex("nope"; who = "plot_scatter")), "ArgumentError: plot_scatter: invalid colour \"nope\"")

		@test P._rgba("#FF0000", 0.35) == "rgba(255,0,0,0.35)"
		@test P._rgba("rgba(0,0,255,0.2)", 1) == "rgba(0,0,255,1)"
		@test P._rgba(:white, 1 / 3) == "rgba(255,255,255,0.3333)"
		@test_throws ArgumentError P._rgba("red", 1.5)
		@test_throws ArgumentError P._rgba("red", -0.1)
		@test_throws ArgumentError P._rgba("red", NaN)

		@test P._blend_over("#000000", 0.5) == "#808080"
		@test P._blend_over("#FF0000", 0.25, "#0000FF") == "#4000BF"
		@test P._blend_over("#FF0000", 0) == "#FFFFFF"
		@test P._blend_over("#FF0000", 1) == "#FF0000"
		@test P._blend_over("rgba(255,0,0,0.5)", 0.5, "#FFFFFF") == P._blend_over("#FF0000", 0.25, "#FFFFFF")
		@test P._blend_over("#FF0000", 0.5, "rgba(0,0,0,0)") == "rgba(255,0,0,0.5)"
		@test P._blend_over("#FF0000", 0, "rgba(0,0,0,0)") == "rgba(0,0,0,0)"
		@test_throws ArgumentError P._blend_over("#FF0000", 2)
		@test_throws ArgumentError P._blend_over("#FF0000", 0.5, "nope")
	end

	@testset "lighten" begin
		@test lighten("#000000", 0.5) == "#808080"
		@test lighten("#1f77b4", 0) == "#1F77B4"
		@test lighten("#1f77b4", 1) == "#FFFFFF"
		@test lighten(:red, 0.25) == "#FF4040"
		@test lighten("rgba(0,0,0,0.5)", 0.5) == "rgba(128,128,128,0.5)"
		@test lighten(P.Colors.RGB(0, 0, 0), 1 // 2) == "#808080"
		@test_throws ArgumentError lighten("#000000", 1.5)
		@test_throws ArgumentError lighten("#000000", -0.5)
		@test_throws ArgumentError lighten("#000000", NaN)
		@test_throws ArgumentError lighten("nope", 0.5)
		@test startswith(message(() -> lighten("#000", 2)), "ArgumentError: lighten:")
	end

	@testset "colormap" begin
		native = colormap("viridis")
		@test native isa Vector{Tuple{Float64,String}}
		@test length(native) == 256
		@test native[1] == (0.0, "#440154") && native[end] == (1.0, "#FDE725")
		@test length(colormap("RdBu")) == 11
		five = colormap("RdBu"; n = 5)
		@test first.(five) == [0.0, 0.25, 0.5, 0.75, 1.0]
		@test last.(five) == P._sample_colorscale("RdBu", [0.0, 0.25, 0.5, 0.75, 1.0])
		@test last.(five)[3] == "#F7F7F7"
		@test near(last.(five)[2], "#E58268") && near(last.(five)[4], "#6AACD0")
		reversed = colormap("RdBu"; reverse = true)
		@test last.(reversed) == last.(resolve("RdBu_r").scale)
		@test first.(reversed) ≈ first.(resolve("RdBu_r").scale)
		double = colormap("RdBu_r"; reverse = true)
		@test last.(double) == last.(colormap("RdBu"))
		@test first.(double) ≈ first.(colormap("RdBu"))
		picnic = colormap("Picnic")
		@test length(picnic) == 11 && picnic[1] == (0.0, "#0000FF") && picnic[end] == (1.0, "#FF0000")
		@test colormap(["red", "blue"]; n = 3) == [(0.0, "#FF0000"), (0.5, "#800080"), (1.0, "#0000FF")]
		@test colormap(:magma; n = 2) == [(0.0, "#000004"), (1.0, "#FCFDBF")]
		@test_throws ArgumentError colormap("viridis"; n = 1)
		@test_throws ArgumentError colormap("viridis"; n = -3)
		@test_throws ArgumentError colormap("")
		@test_throws ArgumentError colormap(nothing)
		@test_throws ArgumentError colormap("magmma")
		@test startswith(message(() -> colormap("magmma")), "ArgumentError: colormap: unknown colorscale")
	end

	@testset "colormap_colors" begin
		@test colormap_colors("viridis", 3) == ["#440154", P._sample_colorscale("viridis", 0.5), "#FDE725"]
		@test near(colormap_colors("viridis", 3)[2], "#21908C")
		@test colormap_colors("viridis", 1) == [P._sample_colorscale("viridis", 0.5)]
		@test colormap_colors("viridis", 1; range = (0.2, 0.6)) == [P._sample_colorscale("viridis", 0.4)]
		@test colormap_colors("viridis", 4; range = (0.2, 0.8)) == P._sample_colorscale("viridis", [0.2, 0.4, 0.6, 0.8])
		@test colormap_colors("viridis", 4; range = [0.2, 0.8]) == colormap_colors("viridis", 4; range = (0.2, 0.8))
		@test colormap_colors("viridis", 5; range = (1, 0)) == reverse(colormap_colors("viridis", 5))
		@test colormap_colors("viridis", 5; reverse = true) == reverse(colormap_colors("viridis", 5))
		@test all(near.(colormap_colors("viridis", 3; reverse = true, range = (0, 0.5)),
			colormap_colors("viridis_r", 3; range = (0, 0.5))))
		@test colormap_colors("RdBu", 3) == ["#67001F", "#F7F7F7", "#053061"]
		@test colormap_colors("gray", 3; range = (0.5, 0.5)) == fill("#808080", 3)
		@test_throws ArgumentError colormap_colors("viridis", 0)
		@test_throws ArgumentError colormap_colors("viridis", 3; range = (0, 1.5))
		@test_throws ArgumentError colormap_colors("viridis", 3; range = (NaN, 1))
		@test_throws ArgumentError colormap_colors("viridis", 3; range = (0, 0.5, 1))
		@test_throws ArgumentError colormap_colors("viridis", 3; range = 0.5)
		@test_throws ArgumentError colormap_colors("", 3)
	end

	@testset "discrete_colormap" begin
		stops = discrete_colormap(["red", "green", "blue"])
		@test stops == [(0.0, "#FF0000"), (1 / 3, "#FF0000"), (1 / 3, "#008000"), (2 / 3, "#008000"),
			(2 / 3, "#0000FF"), (1.0, "#0000FF")]
		@test length(stops) == 6
		@test issorted(first.(stops))
		@test all(stops[2i][1] == stops[2i + 1][1] for i in 1:2)   # duplicated step positions
		@test P._sample_colorscale(stops, 0.5) == "#008000"
		@test P._sample_colorscale(stops, 1 / 3) == "#008000"         # the upper bin owns its boundary
		@test P._sample_colorscale(stops, 1 / 3 - 1e-9) == "#FF0000"
		@test discrete_colormap([:red]) == [(0.0, "#FF0000"), (1.0, "#FF0000")]
		@test last.(discrete_colormap(colormap_colors("viridis", 5)))[1:2:end] == colormap_colors("viridis", 5)
		@test_throws ArgumentError discrete_colormap(String[])
		@test_throws ArgumentError discrete_colormap(["red", "nope"])
		@test startswith(message(() -> discrete_colormap(["nope"])), "ArgumentError: discrete_colormap: invalid colour")
	end

	@testset "_sample_colorscale" begin
		bw = [Any[0.0, "#000000"], Any[1.0, "#FFFFFF"]]
		@test P._sample_colorscale(bw, 0.5) == "#808080"
		@test P._sample_colorscale(bw, -1) == "#000000"
		@test P._sample_colorscale(bw, 2) == "#FFFFFF"
		@test P._sample_colorscale(bw, Inf) == "#FFFFFF"
		@test P._sample_colorscale(bw, -Inf) == "#000000"
		@test P._sample_colorscale(bw, 1) == "#FFFFFF"
		@test P._sample_colorscale(bw, [0, 0.25, 1]) == ["#000000", "#404040", "#FFFFFF"]
		@test_throws ArgumentError P._sample_colorscale(bw, NaN)
		@test P._sample_colorscale([(0, "rgba(255,0,0,0)"), (1, "#FF0000")], 0.5) == "rgba(255,0,0,0.5)"
		@test P._sample_colorscale("Picnic", 0.5) == "#FFFFFF"
		@test_throws ArgumentError P._sample_colorscale("", 0.5)
	end

	@testset "_default_trace_color" begin
		fig = plot_scatter(1:3, 1:3)                          # plotly_white template
		@test P._default_trace_color(fig, 1) == "#636EFA"
		@test P._default_trace_color(fig, 2) == "#EF553B"
		@test P._default_trace_color(fig, 11) == "#636EFA"   # cycles
		custom = Plot()
		relayout!(custom; colorway = ["red", "#00f"])
		@test P._default_trace_color(custom, 1) == "#FF0000"
		@test P._default_trace_color(custom, 4) == "#0000FF"
		named = Plot()
		relayout!(named; template = "ggplot2")
		@test P._default_trace_color(named, 1) == "#F8766D"
		compound = Plot()
		relayout!(compound; template = "simple_white+xgridoff")
		@test P._default_trace_color(compound, 1) == "#1F77B4"
		bare = Plot()
		delete!(bare.layout.fields, :template)
		@test P._default_trace_color(bare, 1) == "#1F77B4"   # plotly.js D3 default
		@test P._default_trace_color(bare, 3) == "#2CA02C"
		unknown = Plot()
		relayout!(unknown; template = "no_such_template")
		@test P._default_trace_color(unknown, 2) == "#FF7F0E"
		sf = subplots(1, 2; sync = false)
		@test P._default_trace_color(sf, 2) == "#EF553B"
		@test P._default_trace_color(fig.layout, 1) == "#636EFA"
		@test_throws ArgumentError P._default_trace_color(fig, 0)
	end

	@testset "_template_colorscale" begin
		default = P._template_colorscale()
		@test default[1] == Any[0.0, "#0D0887"] && default[end] == Any[1.0, "#F0F921"]
		@test P._template_colorscale(plot_heatmap(rand(2, 2))) == default
		ggplot = P._template_colorscale("ggplot2")
		@test ggplot[1][2] == P._color_hex(PlotlyBase.templates[:ggplot2].data[:heatmap][1][:colorscale][1][2])
		bare = Plot()
		delete!(bare.layout.fields, :template)
		@test_throws ArgumentError P._template_colorscale(bare)
	end

	@testset "_apply_color_norm: linear, crange, cmid (two-slope)" begin
		z = [0.0 1.0; 2.0 3.0]
		auto = P._apply_color_norm(z)
		@test auto.values === z
		@test auto.cmin === nothing && auto.cmax === nothing && auto.cmid === nothing
		@test auto.stops == "" && auto.tickvals === nothing && auto.ticktext === nothing && auto.customdata === nothing
		lazy = transpose(z)
		@test P._apply_color_norm(lazy; stops = "viridis").values === lazy
		explicit = P._apply_color_norm(z; crange = (0, 2), stops = "viridis")
		@test explicit.cmin == 0.0 && explicit.cmax == 2.0
		@test explicit.stops == resolve("viridis").scale
		@test P._apply_color_norm(z; crange = [0, 0]).cmin === nothing
		@test P._apply_color_norm(z; cmid = 0.3).cmid == 0.3
		@test P._apply_color_norm(z; cmid = 0.3, stops = "Picnic").stops == "Picnic"

		# TwoSlopeNorm: crange [-1, 3], cmid 0 -> colour 0.5 sits at p = 0.25.
		original = resolve("RdBu").scale
		two = P._apply_color_norm(z; crange = [-1, 3], cmid = 0, stops = "RdBu")
		@test two.cmin == -1.0 && two.cmax == 3.0 && two.cmid === nothing
		@test any(s -> s[1] == 0.25 && s[2] == "#F7F7F7", two.stops)
		@test P._sample_colorscale(two.stops, 0.25) == P._sample_colorscale(original, 0.5)
		@test P._sample_colorscale(two.stops, 0.125) == P._sample_colorscale(original, 0.25)
		@test P._sample_colorscale(two.stops, 0.625) == P._sample_colorscale(original, 0.75)
		@test two.stops[1] == Any[0.0, "#67001F"] && two.stops[end] == Any[1.0, "#053061"]
		@test issorted(first.(two.stops))
		# A scale without a stop at 0.5 gets one inserted at p.
		vir = P._apply_color_norm(z; crange = [0, 10], cmid = 8, stops = "viridis")
		@test any(s -> s[1] == 0.8 && s[2] == P._sample_colorscale("viridis", 0.5), vir.stops)
		@test length(vir.stops) == 257
		@test P._sample_colorscale(vir.stops, 0.4) == P._sample_colorscale("viridis", 0.25)
		# Pass-through names are expanded before remapping; _r stays correct.
		picnic = P._apply_color_norm(z; crange = [-1, 3], cmid = 0, stops = resolve("Picnic_r").scale)
		@test P._sample_colorscale(picnic.stops, 0.25) == "#FFFFFF"
		@test picnic.stops[1][2] == "#FF0000"
		# A centred cmid leaves the scale (and an unset scale) untouched.
		@test P._apply_color_norm(z; crange = [-2, 2], cmid = 0, stops = "").stops == ""
		@test P._apply_color_norm(z; crange = [-2, 2], cmid = 0, stops = "Picnic").stops == "Picnic"
		# Unset scale: the template default (or fallback_stops) is remapped.
		fallback = P._apply_color_norm(z; crange = [-1, 3], cmid = 0)
		@test fallback.stops[1] == Any[0.0, "#0D0887"]
		@test P._sample_colorscale(fallback.stops, 0.25) == P._sample_colorscale(P._template_colorscale(), 0.5)
		chosen = P._apply_color_norm(z; crange = [-1, 3], cmid = 0, fallback_stops = "RdBu")
		@test chosen.stops == two.stops

		@test_throws ArgumentError P._apply_color_norm(z; crange = [-1, 3], cmid = 5)
		@test_throws ArgumentError P._apply_color_norm(z; crange = [-1, 3], cmid = 3)
		@test_throws ArgumentError P._apply_color_norm(z; crange = [-1, 3], cmid = -1)
		@test_throws ArgumentError P._apply_color_norm(z; cmid = NaN)
		@test_throws ArgumentError P._apply_color_norm(z; cmid = true)
		@test_throws ArgumentError P._apply_color_norm(z; crange = [3, 1])
		@test_throws ArgumentError P._apply_color_norm(z; crange = [1, 1])
		@test_throws ArgumentError P._apply_color_norm(z; crange = [0, Inf])
		@test_throws ArgumentError P._apply_color_norm(z; crange = [0, 1, 2])
		@test_throws ArgumentError P._apply_color_norm(z; crange = ["a", "b"])
		@test_throws ArgumentError P._apply_color_norm(z; colornorm = :symlog)
		@test_throws ArgumentError P._apply_color_norm(z; stops = "magmma")
		@test_throws ArgumentError P._apply_color_norm(1.0)
		@test occursin("plot_heatmap: `cmid` = 5", message(() -> P._apply_color_norm(z; crange = [-1, 3], cmid = 5, who = "plot_heatmap")))
	end

	@testset "_apply_color_norm: colornorm = :log" begin
		raw = [1e-3 1e2; 1.0 0.0]
		lognorm = P._apply_color_norm(raw; colornorm = :log)
		@test lognorm.values[1, 1] == -3.0 && lognorm.values[1, 2] == 2.0 && lognorm.values[2, 1] == 0.0
		@test isnan(lognorm.values[2, 2])
		@test lognorm.customdata === raw
		@test lognorm.cmin === nothing && lognorm.cmax === nothing
		@test lognorm.tickvals == [-3.0, -2.0, -1.0, 0.0, 1.0, 2.0]
		@test "10<sup>-3</sup>" in lognorm.ticktext && lognorm.ticktext[end] == "10<sup>2</sup>"
		@test P._apply_color_norm(raw; colornorm = "LOG").tickvals == lognorm.tickvals

		clipped = P._apply_color_norm(raw; colornorm = :log, crange = [1e-2, 1e2])
		@test clipped.cmin ≈ -2 && clipped.cmax ≈ 2
		@test clipped.values[2, 2] ≈ -2        # non-positive floored at crange[1]
		@test clipped.values[1, 1] ≈ -3        # below cmin: plotly clamps to the lowest colour
		@test clipped.tickvals == [-2.0, -1.0, 0.0, 1.0, 2.0]

		special = P._apply_color_norm(Any[missing, NaN, Inf, -Inf, 10]; colornorm = :log)
		@test all(isnan, special.values[1:4]) && special.values[5] == 1.0
		@test P._apply_color_norm([-1.0, 10.0]; colornorm = :log, crange = (1, 100)).values == [0.0, 1.0]
		lazy = transpose([1.0 10.0 100.0; 1000.0 1e4 1e5])
		@test P._apply_color_norm(lazy; colornorm = :log).values == log10.(Matrix(lazy))

		narrow = P._apply_color_norm([2.0, 8.0]; colornorm = :log)
		@test narrow.tickvals ≈ [log10(2), log10(5)]
		@test narrow.ticktext == ["2×10<sup>0</sup>", "5×10<sup>0</sup>"]
		@test length(P._apply_color_norm([3.1, 3.3]; colornorm = :log).tickvals) == 2
		wide = P._apply_color_norm([1e-30, 1e30]; colornorm = :log)
		@test 2 <= length(wide.tickvals) <= 9
		@test all(isinteger, wide.tickvals) && issorted(wide.tickvals)

		@test_throws ArgumentError P._apply_color_norm([0.0, -1.0]; colornorm = :log)
		@test_throws ArgumentError P._apply_color_norm([1.0]; colornorm = :log, crange = [0, 10])
		@test_throws ArgumentError P._apply_color_norm([1.0]; colornorm = :log, crange = [-1, 10])
		@test_throws ArgumentError P._apply_color_norm(["a"]; colornorm = :log)
		@test_throws ArgumentError P._apply_color_norm(nothing; colornorm = :log)
		@test_throws ArgumentError P._apply_color_norm([1.0]; colornorm = :log, cmid = 1)
		explicit_only = P._apply_color_norm(nothing; colornorm = :log, crange = [1, 1000])
		@test explicit_only.values === nothing && explicit_only.tickvals == [0.0, 1.0, 2.0, 3.0]
	end

	@testset "_apply_color_norm: levels (BoundaryNorm)" begin
		z = rand(3, 3)
		uniform = P._apply_color_norm(z; levels = [0, 0.25, 0.5, 0.75, 1.0], stops = "viridis")
		@test length(uniform.stops) == 8                                   # 2k stops
		@test first.(uniform.stops) == [0.0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1.0]
		@test last.(uniform.stops)[1:2:end] == P._sample_colorscale("viridis", [0.125, 0.375, 0.625, 0.875])
		@test uniform.cmin == 0.0 && uniform.cmax == 1.0
		@test uniform.tickvals == [0.0, 0.25, 0.5, 0.75, 1.0]
		@test uniform.ticktext === nothing && uniform.values === z
		uneven = P._apply_color_norm(z; levels = [-1, -0.5, 0, 1], stops = "RdBu")
		@test first.(uneven.stops) == [0.0, 0.25, 0.25, 0.5, 0.5, 1.0]
		@test last.(uneven.stops)[1:2:end] == P._sample_colorscale("RdBu", [1 / 6, 0.5, 5 / 6])
		@test P._sample_colorscale(uneven.stops, 0.5) == P._sample_colorscale("RdBu", 5 / 6)
		logged = P._apply_color_norm([5.0 50.0]; levels = [1, 10, 100, 1000], colornorm = :log, stops = "magma")
		@test first.(logged.stops) ≈ [0, 1 / 3, 1 / 3, 2 / 3, 2 / 3, 1]
		@test logged.cmin == 0.0 && logged.cmax ≈ 3.0
		@test logged.tickvals ≈ [0, 1, 2, 3]
		@test logged.ticktext == ["10<sup>0</sup>", "10<sup>1</sup>", "10<sup>2</sup>", "10<sup>3</sup>"]
		@test logged.values ≈ [log10(5) log10(50)]
		@test P._apply_color_norm(z; levels = [0, 1]).stops == [Any[0.0, P._sample_colorscale(P._template_colorscale(), 0.5)],
			Any[1.0, P._sample_colorscale(P._template_colorscale(), 0.5)]]
		@test_throws ArgumentError P._apply_color_norm(z; levels = [0.5])
		@test_throws ArgumentError P._apply_color_norm(z; levels = [0, 1, 1])
		@test_throws ArgumentError P._apply_color_norm(z; levels = [1, 0])
		@test_throws ArgumentError P._apply_color_norm(z; levels = [0, NaN, 1])
		@test_throws ArgumentError P._apply_color_norm(z; levels = [0, 1], crange = [0, 1])
		@test_throws ArgumentError P._apply_color_norm(z; levels = [0, 1], cmid = 0.5)
		@test_throws ArgumentError P._apply_color_norm(z; levels = [0, 1, 10], colornorm = :log)
		@test_throws ArgumentError P._apply_color_norm(z; levels = 5)
	end

	@testset "_apply_color_norm: user colorbar ticks (data units)" begin
		z = [1.0 10.0; 100.0 1000.0]
		linear = P._apply_color_norm(z; ticks = [0, 500, 1000], ticklabels = ["lo", L"$m$", :hi])
		@test linear.tickvals == [0.0, 500.0, 1000.0] && linear.ticktext == ["lo", "\$m\$", "hi"]
		@test P._apply_color_norm(z; ticks = 1:3).ticktext === nothing
		logticks = P._apply_color_norm(z; colornorm = :log, ticks = [1, 100])
		@test logticks.tickvals == [0.0, 2.0] && logticks.ticktext == ["10<sup>0</sup>", "10<sup>2</sup>"]
		labelled = P._apply_color_norm(z; colornorm = :log, ticks = [1, 100], ticklabels = ["one", "hundred"])
		@test labelled.ticktext == ["one", "hundred"]
		@test P._apply_color_norm(z; colornorm = :log, ticks = [3]).ticktext == ["3"]
		@test_throws ArgumentError P._apply_color_norm(z; ticklabels = ["a"])
		@test_throws ArgumentError P._apply_color_norm(z; ticks = [1, 2], ticklabels = ["a"])
		@test_throws ArgumentError P._apply_color_norm(z; ticks = [1, NaN])
		@test_throws ArgumentError P._apply_color_norm(z; colornorm = :log, ticks = [0, 1])
	end

	@testset "_colorbar_attr" begin
		@test P._colorbar_attr() === nothing
		@test P._colorbar_attr(; title = "") === nothing
		cb = json_roundtrip(P._colorbar_attr(; title = SubString("xTemperature", 2), ticks = [0, 0.5, 1],
			ticklabels = ["cold", "mild", "hot"], len = 0.6, thickness = 12, x = 1.02, y = 0.5))
		@test cb == Dict("title" => Dict("text" => "Temperature"), "tickmode" => "array", "tickvals" => [0, 0.5, 1],
			"ticktext" => ["cold", "mild", "hot"], "len" => 0.6, "lenmode" => "fraction", "thickness" => 12,
			"x" => 1.02, "y" => 0.5)
		@test json_roundtrip(P._colorbar_attr(; ticks = [1, 2])) == Dict("tickmode" => "array", "tickvals" => [1, 2])
		@test json_roundtrip(P._colorbar_attr(; x = -0.1)) == Dict("x" => -0.1)
		@test_throws ArgumentError P._colorbar_attr(; ticklabels = ["a"])
		@test_throws ArgumentError P._colorbar_attr(; ticks = [1, 2], ticklabels = ["a"])
		@test_throws ArgumentError P._colorbar_attr(; ticks = [1, Inf])
		@test_throws ArgumentError P._colorbar_attr(; len = -1)
		@test_throws ArgumentError P._colorbar_attr(; thickness = NaN)
		@test_throws ArgumentError P._colorbar_attr(; x = Inf)
		@test_throws ArgumentError P._colorbar_attr(; y = "top")
	end

	@testset "_colorbar_carrier_trace" begin
		carrier = P._colorbar_carrier_trace(; stops = "magma", cmin = -1, cmax = 2.5,
			colorbar = P._colorbar_attr(; title = "v"), xref = "x3", yref = "y3")
		@test carrier isa GenericTrace
		d = json_roundtrip(carrier)
		@test d["type"] == "scatter" && d["mode"] == "markers"
		@test d["x"] == [nothing] && d["y"] == [nothing]
		@test d["hoverinfo"] == "skip" && d["showlegend"] == false && d["name"] == ""
		@test d["xaxis"] == "x3" && d["yaxis"] == "y3"
		@test d["marker"]["color"] == [-1, 2.5] && d["marker"]["cmin"] == -1 && d["marker"]["cmax"] == 2.5
		@test d["marker"]["colorscale"][1] == [0.0, "#000004"] && length(d["marker"]["colorscale"]) == 256
		@test d["marker"]["showscale"] == true
		@test d["marker"]["colorbar"] == Dict("title" => Dict("text" => "v"))
		@test json_roundtrip(P._colorbar_carrier_trace(; stops = "Picnic", cmin = 0, cmax = 1, showscale = false))["marker"]["colorscale"] == "Picnic"
		@test json_roundtrip(P._colorbar_carrier_trace(; stops = "Picnic", cmin = 0, cmax = 1, showscale = false))["marker"]["showscale"] == false
		shared = json_roundtrip(P._colorbar_carrier_trace(; cmin = 0, cmax = 1, coloraxis = :shared))
		@test shared["marker"] == Dict("color" => [0, 1], "coloraxis" => "coloraxis")
		@test json_roundtrip(P._colorbar_carrier_trace(; cmin = 0, cmax = 1, coloraxis = "coloraxis2"))["marker"]["coloraxis"] == "coloraxis2"
		@test_throws ArgumentError P._colorbar_carrier_trace(; cmin = 0, cmax = 1)
		@test_throws ArgumentError P._colorbar_carrier_trace(; stops = "", cmin = 0, cmax = 1)
		@test_throws ArgumentError P._colorbar_carrier_trace(; stops = "viridis", cmin = 1, cmax = 1)
		@test_throws ArgumentError P._colorbar_carrier_trace(; stops = "viridis", cmin = 0, cmax = Inf)
		@test_throws ArgumentError P._colorbar_carrier_trace(; stops = "viridis", cmin = 0, cmax = 1, xref = "x1")
		@test_throws ArgumentError P._colorbar_carrier_trace(; stops = "viridis", cmin = 0, cmax = 1, yref = "x")
		@test_throws ArgumentError P._colorbar_carrier_trace(; stops = "viridis", cmin = 0, cmax = 1, coloraxis = "coloraxis1")
		@test_throws ArgumentError P._colorbar_carrier_trace(; cmin = 0, cmax = 1, coloraxis = :shared,
			colorbar = P._colorbar_attr(; title = "x"))
		@test_throws ArgumentError P._colorbar_carrier_trace(; stops = "viridis", cmin = 0, cmax = 1, colorbar = "x")
		@test P._normalize_coloraxis(:shared, "t") == "coloraxis"
		@test P._normalize_coloraxis("coloraxis12", "t") == "coloraxis12"
		@test_throws ArgumentError P._normalize_coloraxis("foo", "t")
		@test_throws ArgumentError P._normalize_coloraxis(2, "t")
	end

	@testset "public names and the COLORMAPS registry" begin
		for name in (:colormap, :colormap_colors, :lighten, :discrete_colormap)
			@test Base.isexported(PlotlySupply, name)
		end
		@test Base.ispublic(PlotlySupply, :COLORMAPS) && !Base.isexported(PlotlySupply, :COLORMAPS)
		@test P._SCI_COLOR_MUTATORS == ()
		@test P.COLORMAPS["viridis"][1] == "#440154"
		key = "PlotlySupplyTestIce"
		@test !haskey(P.COLORMAPS, key)
		P.COLORMAPS[key] = ["#000033", "#3366cc", "#ffffff"]
		try
			@test resolve("plotlysupplytestice").scale == [Any[0.0, "#000033"], Any[0.5, "#3366CC"], Any[1.0, "#FFFFFF"]]
			@test resolve("plotlysupplytestice_r").scale[1] == Any[0.0, "#FFFFFF"]
			P.COLORMAPS[key] = ["#000033", "not a colour"]
			@test_throws ArgumentError resolve(key)
		finally
			delete!(P.COLORMAPS, key)
		end
	end

	@testset "COLOR_CYCLES: colour-blind-safe cycles in line-safe order (D14)" begin
		@test Base.ispublic(PlotlySupply, :COLOR_CYCLES) && !Base.isexported(PlotlySupply, :COLOR_CYCLES)
		@test Set(keys(P.COLOR_CYCLES)) == Set([:okabe_ito, :tol_bright, :tol_vibrant, :tol_muted, :tol_high_contrast])
		lin(u) = u <= 0.04045 ? u / 12.92 : ((u + 0.055) / 1.055)^2.4
		contrast_on_white(h) = begin
			r, g, b = rgb_bytes(h) ./ 255
			1.05 / (0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) + 0.05)
		end
		lightness(h) = Float64(P.Colors.Lab(parse(P.Colors.RGB, h)).l)
		# Same colours as the published palettes (ColorSchemes.jl copies of
		# Okabe-Ito and Paul Tol's schemes); only the order is PlotlySupply's.
		sources = Dict(:okabe_ito => :okabe_ito, :tol_bright => :tol_bright, :tol_vibrant => :tol_vibrant,
			:tol_muted => :tol_muted, :tol_high_contrast => :tol_highcontrast)
		# The documented number of leading colours with contrast >= 3 on white.
		line_safe = Dict(:okabe_ito => 5, :tol_bright => 4, :tol_vibrant => 4, :tol_muted => 6, :tol_high_contrast => 2)
		for (name, colours) in P.COLOR_CYCLES
			published = Set(P._color_hex(c) for c in P.ColorSchemes.colorschemes[sources[name]].colors)
			@test allunique(colours)
			@test Set(colours) == published
			ratios = contrast_on_white.(colours)
			k = line_safe[name]
			@test all(>=(3), ratios[1:k])
			@test all(<(3), ratios[(k + 1):end])
			@test all(c -> occursin(r"^#[0-9A-F]{6}$", c), colours)
		end
		# :tol_high_contrast is the greyscale-safe cycle: well-separated L*.
		L = lightness.(P.COLOR_CYCLES[:tol_high_contrast])
		@test issorted(L) && minimum(diff(L)) > 20
		# Okabe-Ito's first four line colours share a lightness band (why the
		# journal presets add a dash/symbol cycle).
		@test maximum(lightness.(P.COLOR_CYCLES[:okabe_ito][1:4])) - minimum(lightness.(P.COLOR_CYCLES[:okabe_ito][1:4])) < 16
		# Used by PlotStyle; a ColorScheme keeps its own order.
		@test PlotStyle(; colorway = :tol_vibrant).colorway == P.COLOR_CYCLES[:tol_vibrant]
		@test PlotStyle(; colorway = :tol_vibrant).colorway !== P.COLOR_CYCLES[:tol_vibrant]
		@test PlotStyle(; colorway = :tab10).colorway[1] == "#1F77B4"
		err = thrown(() -> PlotStyle(; colorway = :no_such_cycle))
		@test err isa ArgumentError && occursin(":tol_high_contrast", sprint(showerror, err))
		# A user cycle is validated when a style uses it.
		P.COLOR_CYCLES[:plotlysupply_test] = ["#000000", "0.5"]
		try
			@test PlotStyle(; colorway = :plotlysupply_test).colorway == ["#000000", "#808080"]
			P.COLOR_CYCLES[:plotlysupply_test] = ["#000000", "nope"]
			@test occursin("colorway[2]", message(() -> PlotStyle(; colorway = :plotlysupply_test)))
		finally
			delete!(P.COLOR_CYCLES, :plotlysupply_test)
		end
	end

	@testset "colormap print classes: uniform and greyscale-safe maps (D14)" begin
		classes = P._COLORMAP_PRINT_CLASSES
		@test Set(keys(classes)) == setdiff(Set(keys(P.COLORMAPS)), Set(["ice"]))  # "ice": docs example, see above
		lightness(h) = Float64(P.Colors.Lab(parse(P.Colors.RGB, h)).l)
		step_cv(L) = (d = abs.(diff(L)); m = sum(d) / length(d); sqrt(sum((d .- m) .^ 2) / length(d)) / m)
		for (name, info) in classes
			L = lightness.(colormap_colors(name, 64))
			monotone = all(>(0), diff(L)) || all(<(0), diff(L))
			# "greyscale-safe" is exactly "L* strictly monotonic" (measured).
			@test monotone == info.greyscale
			if info.class === :sequential && info.uniform
				# Perceptually uniform maps: nearly constant L* steps (CV of
				# the 63 steps <= 0.2; measured 0.12 viridis .. 0.20 magma).
				@test step_cv(L) <= 0.2
			elseif info.class === :rainbow
				# jet/rainbow/turbo: lightness reverses, steps vary wildly.
				@test step_cv(L) > 0.5
			elseif info.class === :diverging
				# Both ends darker than the middle: the sign is lost in greyscale.
				@test maximum(L) > max(L[1], L[end]) + 10
			end
		end
		@test classes["twilight"].class === :cyclic
		@test abs(lightness(colormap_colors("twilight", 2)[1]) - lightness(colormap_colors("twilight", 2)[2])) < 1
		@test [n for (n, i) in classes if i.uniform && i.greyscale] |> sort == ["cividis", "inferno", "magma", "plasma", "viridis"]
		# The docstring table lists every map with its class.
		doc = string(@doc P.COLORMAPS)
		for name in keys(classes)
			@test occursin(name, doc)
		end
	end

	@testset "_color_option: colour keywords for plotly attributes (G16)" begin
		opt(v; name = "color") = P._color_option(v; who = "plot_test", name = name)
		@test opt("0.35") == "#595959"
		@test opt(" 0 ") == "#000000" && opt("1") == "#FFFFFF"
		@test opt("red") == "red"
		@test opt(:steelblue) == "steelblue"
		@test opt("#AbC") == "#AbC"
		@test opt("rgba(1,2,3,0.5)") == "rgba(1,2,3,0.5)"
		@test opt(P.Colors.RGB(1, 0, 0)) == "#FF0000"
		@test opt("") == "" && opt(nothing) === nothing && opt(missing) === missing
		@test opt(0.5) === 0.5 && opt(3) === 3
		@test opt(["0.35", "red", 1.5, P.Colors.RGBA(0, 0, 1, 0.5)]) == Any["#595959", "red", 1.5, "rgba(0,0,255,0.5)"]
		@test opt(String[]) == Any[]
		for (bad, needle) in (("1.5", "grey level"), ("-0.1", "grey level"), ("notacolour", "invalid colour"),
			(true, "must be a colour"), ([["red"]], "must be a colour"), (Dict(), "must be a colour"))
			msg = message(() -> opt(bad))
			@test startswith(msg, "ArgumentError: plot_test: `color")
			@test occursin(needle, msg)
		end
		@test occursin("`marker_color[2]`", message(() -> opt(["red", "nope"]; name = "marker_color")))
	end

	@testset "rendered colorbar uses the resolved scale (SVG gradient)" begin
		gradient_ends(svg) = begin
			stops = [m.captures[1] for m in eachmatch(r"<stop[^>]*stop-color=\"([^\"]+)\"", svg)]
			isempty(stops) ? nothing : (first(stops), last(stops))
		end
		try
			coolwarm = Plot(heatmap(; z = [1 2; 3 4], colorscale = resolve("coolwarm").scale), Layout(width = 400, height = 300))
			default = Plot(heatmap(; z = [1 2; 3 4]), Layout(width = 400, height = 300))
			P._apply_default_template!(default)
			cw = gradient_ends(String(savefig(coolwarm; format = "svg", width = 400, height = 300)))
			df = gradient_ends(String(savefig(default; format = "svg", width = 400, height = 300)))
			@test cw == ("rgb(59, 76, 192)", "rgb(180, 4, 38)")      # matplotlib coolwarm ends
			@test df !== nothing && df != cw
		catch err
			@test occursin("ElectronCall", sprint(showerror, err)) || occursin("Plotly.js", sprint(showerror, err))
		end
	end
end
