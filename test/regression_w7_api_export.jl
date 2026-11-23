using Test, PlotlySupply
using PlotlySupply: PlotlyBase

# Wave 7 (api-export): export defaults, subplots/specs validation, user-error
# types, JSON with non-finite numbers, HTML export cost and MathJax, asset
# state. No renderer is needed.

_w7_msg(f) = try
	f()
	nothing
catch err
	err
end

@testset "w7 D18: sized journal styles export rasters at 300 dpi" begin
	for preset in (:ieee, :aps, :nature, :elsevier, :springer, :aip)
		fig = with_style(preset) do
			plot_scatter(1:3, 1:3)
		end
		o = PlotlySupply._normalize_export_options(fig, (;))
		@test o.sized
		for fmt in ("png", "jpeg", "tiff")
			@test PlotlySupply._format_scale(o, fmt) ≈ 300 / 96
			@test PlotlySupply._format_dpi(o, fmt) ≈ 300
			w, h = PlotlySupply._format_pixels(o, fmt)
			@test w == round(Int, o.width * 300 / 96) && h == round(Int, o.height * 300 / 96)
		end
		# Vector formats keep their physical size; dpi and scale win.
		@test PlotlySupply._format_scale(o, "pdf") == 1.0
		o600 = PlotlySupply._normalize_export_options(fig, (dpi = 600,))
		@test PlotlySupply._format_scale(o600, "png") ≈ 600 / 96
		o2 = PlotlySupply._normalize_export_options(fig, (scale = 2,))
		@test PlotlySupply._format_scale(o2, "png") == 2.0
		@test PlotlySupply._format_dpi(o2, "png") === nothing
	end
	# A figure that carries a style is exported under it whatever style is
	# active; one that carries none (made under :default) follows the active
	# style (`_export_style_is_sized`, docs/src/export.md).
	ieee = with_style(:ieee) do
		plot_scatter(1:3, 1:3)
	end
	plain = plot_scatter(1:3, 1:3)
	with_style(:ieee) do
		@test PlotlySupply._normalize_export_options(plain, (;)).sized
		@test PlotlySupply._normalize_export_options(ieee, (;)).sized
	end
	with_style(:publication) do
		@test PlotlySupply._normalize_export_options(ieee, (;)).sized
	end
	@test PlotlySupply._normalize_export_options(ieee, (;)).sized
	po = PlotlySupply._normalize_export_options(plain, (;))
	@test !po.sized
	@test PlotlySupply._format_scale(po, "png") == 1.0
	@test PlotlySupply._format_scale(po, "tiff") ≈ 300 / 96
	@test PlotlySupply._format_dpi(po, "png") === nothing
end

@testset "w7 L5 / specs-01 / msg-01: subplots validation" begin
	g = subplots(2, 2; sync = false, specs = [Spec() Spec(rowspan = 2); Spec() nothing])
	@test g isa SubplotFigure
	col = subplots(2, 1; sync = false, specs = [Spec(secondary_y = true); Spec()])
	@test col isa SubplotFigure
	row = subplots(1, 2; sync = false, specs = [Spec(kind = "polar"), Spec()])
	@test row isa SubplotFigure
	bad = Dict(
		"non-Spec cell" => () -> subplots(1, 2; sync = false, specs = [Spec() 3]),
		"wrong size" => () -> subplots(2, 2; sync = false, specs = [Spec() Spec()]),
		"not an array" => () -> subplots(2, 2; sync = false, specs = 3),
		"vector for 2x2" => () -> subplots(2, 2; sync = false, specs = [Spec(), Spec()]),
		"span beyond" => () -> subplots(2, 2; sync = false, specs = [Spec(colspan = 3) missing; Spec() Spec()]),
		"span overlaps" => () -> subplots(2, 2; sync = false, specs = [Spec(colspan = 2) Spec(); Spec() Spec()]),
		"zero span" => () -> subplots(2, 2; sync = false, specs = [Spec(rowspan = 0) Spec(); Spec() Spec()]),
		"unknown kind" => () -> subplots(1, 2; sync = false, specs = [Spec(kind = "foo") Spec()]),
		"shared_xaxes" => () -> subplots(2, 1; sync = false, shared_xaxes = "diag"),
		"shared_yaxes" => () -> subplots(2, 1; sync = false, shared_yaxes = 3),
		"width_ratios" => () -> subplots(1, 2; sync = false, width_ratios = [1, 0]),
		"width_ratios length" => () -> subplots(1, 2; sync = false, width_ratios = [1, 1, 1]),
		"column_widths" => () -> subplots(1, 2; sync = false, column_widths = [1, -1]),
		"row_heights length" => () -> subplots(2, 1; sync = false, row_heights = [1]),
		"too many titles" => () -> subplots(1, 2; sync = false, subplot_titles = ["a", "b", "c"]),
	)
	for (label, f) in bad
		err = _w7_msg(f)
		@test err isa ArgumentError
		err isa ArgumentError && @test startswith(err.msg, "subplots:")
	end
	err = _w7_msg(() -> subplots(1, 2; sync = false, specs = [Spec() 3]))
	@test occursin("specs[1, 2]", err.msg)
end

@testset "w7 oned-user-error-types and fields-02" begin
	err = _w7_msg(() -> plot_scatter(1:3, 1:3; foo = 1))
	@test err isa ArgumentError && startswith(err.msg, "plot_scatter:") && occursin("foo", err.msg)
	fig = plot_scatter(1:3, 1:3; mode = :lines)
	@test fig.data[1][:mode] == "lines"
	f = plot_scatter(1:3, 1:3)
	plot_scatter!(f, 1:3, 3:-1:1; mode = :markers)
	@test f.data[2][:mode] == "markers"
	for call in (() -> plot_area(1:3, 1:3; stack = "yes"), () -> plot_area!(plot_area(1:3, 1:3), 1:3, 1:3; stack = "yes"))
		err = _w7_msg(call)
		@test err isa ArgumentError && startswith(err.msg, "plot_area")
	end
	before = PlotlyBase.JSON.json(f)
	for call in (() -> vline!(f, "a"), () -> hline!(f, "a"))
		err = _w7_msg(call)
		@test err isa ArgumentError && (startswith(err.msg, "vline!:") || startswith(err.msg, "hline!:"))
	end
	@test PlotlyBase.JSON.json(f) == before

	U = rand(4, 2)
	for (name, call) in (
		("heatmap", x -> plot_heatmap(x, [0, 1], U)),
		("contour", x -> plot_contour(x, [0, 1], U)),
	)
		for x in ([0, 2, 1, 3], [0, 1, 1, 3])
			err = _w7_msg(() -> call(x))
			@test err isa ArgumentError && startswith(err.msg, "plot_$(name):") && occursin("monotonic", err.msg)
		end
		@test call([3, 2, 1, 0]) isa PlotlyBase.Plot
		@test call([0.0, 0.5, 1.5, 4.0]) isa PlotlyBase.Plot
	end
end

@testset "w7 savefig contract: symbols, messages" begin
	f = plot_scatter(1:3, 1:3)
	@test String(savefig(f; format = :json)) == String(savefig(f; format = "json"))
	dir = mktempdir()
	err = _w7_msg(() -> savefig(f, dir))
	@test err isa ArgumentError && startswith(err.msg, "savefig:") && occursin("directory", err.msg)
	withenv("PATH" => dir) do
		err = _w7_msg(() -> savefig(f; format = :pdf, fonts = :outline))
		@test err isa ArgumentError && occursin("outline", err.msg) && !occursin("EPS", err.msg)
		err = _w7_msg(() -> savefig(f; format = :eps))
		@test err isa ArgumentError && occursin("EPS", err.msg)
	end
end

@testset "w7 json: non-finite numbers are null" begin
	for fig in (plot_heatmap([1.0 NaN; 3.0 4.0]), plot_scatter([1, 2, 3], [1, NaN, Inf]))
		text = json(fig)
		@test occursin("null", text) && !occursin("NaN", text) && !occursin("Infinity", text)
		@test string(fig) == text
		path = joinpath(mktempdir(), "a.json")
		savejson(fig, path)
		@test read(path, String) == text
		@test occursin("null", repr(MIME("application/vnd.plotly.v1+json"), fig))
	end
	sf = subplots(1, 2; sync = false)
	plot_scatter!(sf, 1:3, [1, NaN, 3]; row = 1, col = 1)
	text = json(sf)
	@test occursin("\"data\"", text) && !occursin("\"rows\"", text) && occursin("null", text)
	@test json(sf) == json(getfield(sf, :fig))
end

@testset "w7 HTML export: MathJax only with math, cached asset" begin
	plain = String(savefig(plot_scatter(1:3, 1:3); format = "html"))
	@test !occursin("MathJax.js", plain)
	math = String(savefig(plot_scatter(1:3, 1:3; xlabel = "\$x^2\$"); format = "html"))
	@test occursin("mathjax/2.7.9/MathJax.js", math)

	# The patched plotly.js text is verified once per session per asset.
	a = PlotlySupply._compatible_plotlyjs_inline_script()
	@test PlotlySupply._compatible_plotlyjs_inline_script() === a
	f = plot_scatter(1:3, 1:3)
	savefig(IOBuffer(), f; format = "html")
	best = minimum(@elapsed(savefig(IOBuffer(), f; format = "html")) for _ in 1:5)
	@test best < 0.03   # the full integrity check costs about 0.1 s

	# A changed asset or license is still caught (fail closed) and the memo
	# is rebuilt after a legitimate refresh.
	mktempdir() do parent
		state = PlotlySupply._PlotlyJSCompatAssetState()
		path = PlotlySupply._plotlyjs_render_asset_path(; state, cache_parent = parent)
		s1 = PlotlySupply._compatible_plotlyjs_inline_script(; state)
		@test PlotlySupply._compatible_plotlyjs_inline_script(; state) === s1
		write(path, "changed")
		@test_throws ErrorException PlotlySupply._plotlyjs_render_asset_path(; state, cache_parent = parent)
		@test_throws ErrorException PlotlySupply._compatible_plotlyjs_inline_script(; state)
		PlotlySupply._cleanup_plotlyjs_compat_asset!(state)
		@test isempty(readdir(parent))
	end
end

@testset "w7 asset cleanup is registered by the session" begin
	# `__init__` resets what a package-image build may have left behind.
	state = PlotlySupply._PLOTLYJS_COMPAT_ASSET_STATE
	src = read(joinpath(pkgdir(PlotlySupply), "src", "precompile.jl"), String)
	@test !occursin(r"^\s*savefig\(IOBuffer\(\), fig; format = \"html\"\)"m, src)
	@test state.atexit_registered isa Bool
end

@testset "w7 compat verbs: errors name the verb" begin
	f = make_subplots(rows = 1, cols = 1)
	err = _w7_msg(() -> add_trace!(f, scatter(y = [1, 2]); row = 2, col = 1))
	@test err isa ArgumentError && startswith(err.msg, "add_trace!:")
	p = plot_scatter(1:3, 1:3)
	err = _w7_msg(() -> deletetraces!(p, 1, 1))
	@test err isa ArgumentError && startswith(err.msg, "deletetraces!:")
	@test length(p.data) == 1
	@test_throws ArgumentError deletetraces!(p, 5)
	@test_throws ArgumentError restyle!(p, 5; line_width = 2)
	@test length(p.data) == 1
end
