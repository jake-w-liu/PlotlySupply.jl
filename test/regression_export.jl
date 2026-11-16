using Test, PlotlySupply
using PlotlySupply: PlotlyBase

# Live-renderer export regressions (hidden Electron export window). Pure byte
# helpers and HTML/JSON output are covered by test/sci_export.jl.

const _RegExportJSON = PlotlyBase.JSON

# Bytes as text for regex searches; non-ASCII stream bytes become '?', so the
# offsets of ASCII structure are preserved.
_reg_ascii(bytes::Vector{UInt8}) = String(map(b -> b < 0x80 ? b : UInt8('?'), bytes))

_reg_u32(bytes::Vector{UInt8}, i::Int) = Int(ntoh(reinterpret(UInt32, bytes[i:(i + 3)])[1]))

_reg_png_size(png::Vector{UInt8}) = (_reg_u32(png, 17), _reg_u32(png, 21))

function _reg_png_chunk(png::Vector{UInt8}, kind::String)
	i = 9
	while i + 7 <= length(png)
		len = _reg_u32(png, i)
		String(png[(i + 4):(i + 7)]) == kind && return png[(i + 8):(i + 7 + len)]
		i += 12 + len
	end
	return nothing
end

function _reg_media_box(pdf::Vector{UInt8})
	m = match(r"/MediaBox\s*\[([^\]]*)\]", _reg_ascii(pdf))
	return parse.(Float64, split(m.captures[1]))
end

function _reg_heatmap(title)
	z = [Float64(i * j) for i in 1:5, j in 1:4]
	return plot_heatmap(collect(1.0:5), collect(1.0:4), z; title = title)
end

function _reg_constrained(title)
	p = plot_scatter([0.0, 1.0, 2.0], [0.0, 2.0, 1.0]; title = title)
	relayout!(p; yaxis = attr(scaleanchor = "x", scaleratio = 1))
	return p
end

_reg_has_ghostscript() =
	try
		PlotlySupply._ghostscript_command()
		true
	catch err
		err isa ArgumentError || rethrow()
		false
	end

@testset "regression export: each export starts from a clean renderer" begin
	a = plot_scatter([1.0, 2.0, 3.0], [3.0, 1.0, 2.0]; title = "first")
	b = _reg_heatmap("second")
	c = _reg_constrained("third")
	for fmt in ("png", "svg", "pdf")
		first_bytes = savefig(a; format = fmt)
		savefig(b; format = fmt)
		savefig(c; format = fmt)
		@test savefig(a; format = fmt) == first_bytes
	end

	# Repeated PDF exports leave exactly one (flattened) colorbar in the page.
	savefig(_reg_heatmap("h1"); format = "pdf")
	savefig(_reg_heatmap("h2"); format = "pdf")
	counts = PlotlySupply._with_export_window(PlotlySupply._EXPORT_STATE) do ec, app, win, divid
		script = "(function(){var d=document.getElementById($(PlotlySupply._json_js(divid)));" *
				 "return [d.querySelectorAll('.cbfills').length, d.querySelectorAll('.colorbar').length];})()"
		Base.invokelatest(() -> ec.run(win, script))
	end
	@test collect(counts) == [1, 1]

	# A layout transition must not leave the previous figure's title on screen.
	ta = plot_scatter([1.0, 2.0], [1.0, 2.0]; title = "AAA-title")
	relayout!(ta; transition = attr(duration = 3000))
	tb = plot_scatter([1.0, 2.0], [2.0, 1.0]; title = "BBB-title")
	relayout!(tb; transition = attr(duration = 3000))
	savefig(ta; format = "svg")
	svg = String(savefig(tb; format = "svg"))
	@test occursin("BBB-title", svg)
	@test !occursin("AAA-title", svg)

	# NaN separators (quiver-style traces) export in every renderer format.
	gaps = Plot(scatter(x = [1.0, 2.0, NaN, 3.0], y = [1.0, 2.0, NaN, 3.0]))
	for fmt in ("png", "svg", "pdf")
		@test !isempty(savefig(gaps; format = fmt))
	end
end

@testset "regression export: deterministic bytes" begin
	p = _reg_heatmap("deterministic")
	for fmt in ("png", "jpeg", "svg", "pdf")
		@test savefig(p; format = fmt) == savefig(p; format = fmt)
	end
	pdf = _reg_ascii(savefig(p; format = "pdf"))
	@test !occursin("/CreationDate", pdf)
	@test !occursin("/ModDate", pdf)
	svg = String(savefig(p; format = "svg"))
	@test occursin("defs-000000", svg)
	# Random ids are kept on request (the layout uid is drawn per figure).
	loose = String(savefig(p; format = "svg", deterministic = false))
	@test !occursin("defs-000000", loose)
	@test occursin("/CreationDate", _reg_ascii(savefig(p; format = "pdf", deterministic = false)))
end

@testset "regression export: physical size, dpi and scale" begin
	p = plot_scatter([1.0, 2.0, 3.0], [1.0, 3.0, 2.0]; title = "size")

	png = savefig(p; format = "png", width = 3.5, height = 2.5, units = :in, dpi = 300)
	@test _reg_png_size(png) == (1050, 750)
	phys = _reg_png_chunk(png, "pHYs")
	@test phys !== nothing
	@test _reg_u32(phys, 1) == round(Int, 300 / 0.0254)
	@test _reg_u32(phys, 5) == round(Int, 300 / 0.0254)
	@test phys[9] == 0x01

	jpeg = savefig(p; format = "jpeg", width = 3.5, height = 2.5, units = :in, dpi = 300)
	@test jpeg[1:2] == UInt8[0xff, 0xd8]
	@test jpeg[7:11] == collect(codeunits("JFIF\0"))
	@test jpeg[14:18] == UInt8[0x01, 0x01, 0x2c, 0x01, 0x2c]

	# Vector output keeps the physical size; 3.5 in x 2.625 in = 252 x 189 pt.
	pdf = savefig(p; format = "pdf", width = 3.5, height = 2.625, units = :in, dpi = 300)
	x0, y0, x1, y1 = _reg_media_box(pdf)
	@test abs((x1 - x0) - 252) < 0.01
	@test abs((y1 - y0) - 189) < 0.01
	pdfinfo = Sys.which("pdfinfo")
	if pdfinfo !== nothing
		mktempdir() do dir
			path = joinpath(dir, "size.pdf")
			write(path, pdf)
			info = read(`$pdfinfo $path`, String)
			m = match(r"Page size:\s+([0-9.]+) x ([0-9.]+) pts", info)
			@test m !== nothing
			@test abs(parse(Float64, m.captures[1]) - 252) < 0.01
			@test abs(parse(Float64, m.captures[2]) - 189) < 0.01
		end
	end

	# scale magnifies the PDF page like the raster image.
	scaled = savefig(p; format = "pdf", width = 300, height = 200, scale = 2)
	sx0, sy0, sx1, sy1 = _reg_media_box(scaled)
	@test abs((sx1 - sx0) - 450) < 0.01
	@test abs((sy1 - sy0) - 300) < 0.01
	@test _reg_png_size(savefig(p; format = "png", width = 300, height = 200, scale = 2)) == (600, 400)

	# scale < 1 shrinks the whole figure onto the smaller page (it used to be
	# clipped to its top-left corner, losing the x-axis title).
	labelled = plot_scatter(collect(1.0:10), collect(1.0:10) .^ 2; title = "small", xlabel = "x axis label")
	small = savefig(labelled; format = "pdf", width = 600, height = 400, scale = 0.5)
	hx0, hy0, hx1, hy1 = _reg_media_box(small)
	@test abs((hx1 - hx0) - 225) < 0.01
	@test abs((hy1 - hy0) - 150) < 0.01
	pdftotext = Sys.which("pdftotext")
	if pdftotext !== nothing
		mktempdir() do dir
			path = joinpath(dir, "small.pdf")
			write(path, small)
			@test occursin("x axis label", read(`$pdftotext $path -`, String))
		end
	end

	# layout.width/height are the default export size.
	sized = plot_scatter([1.0, 2.0], [2.0, 1.0])
	relayout!(sized; width = 400, height = 300)
	@test _reg_png_size(savefig(sized; format = "png")) == (400, 300)
	@test _reg_png_size(savefig(sized; format = "png", width = 500)) == (500, 300)

	@test_throws ArgumentError savefig(p; format = "png", width = 9)
	err = try
		savefig(p; format = "png", width = 17_000, height = 17_000)
		nothing
	catch caught
		caught
	end
	@test err isa ErrorException
	@test occursin("canvas", sprint(showerror, err))
end

@testset "regression export: backgrounds, tight and the caller's figure" begin
	p = _reg_heatmap("background")
	before = _RegExportJSON.json(p)
	opaque = savefig(p; format = "png")
	clear = savefig(p; format = "png", background = :transparent)
	@test clear != opaque
	@test clear[26] == 0x06   # IHDR colour type 6: RGBA
	# plotly.js paints the SVG paper rect as `fill` + `fill-opacity`; the
	# transparent export also clears the plot-area rect.
	paper_rect(svg) = match(r"<rect x=\"0\" y=\"0\" [^>]*style=\"([^\"]*)\"", svg).captures[1]
	plot_rect(svg) = match(r"<rect class=\"bg\" [^>]*style=\"([^\"]*)\"", svg).captures[1]
	clear_svg = String(savefig(p; format = "svg", background = :transparent))
	@test occursin("fill-opacity: 0;", paper_rect(clear_svg))
	@test occursin("fill-opacity: 0;", plot_rect(clear_svg))
	black_svg = String(savefig(p; format = "svg", background = "black"))
	@test occursin("fill: rgb(0, 0, 0); fill-opacity: 1;", paper_rect(black_svg))
	if isdefined(PlotlySupply, :tight_layout!)
		@test !isempty(savefig(p; format = "png", tight = true))
	end
	@test _RegExportJSON.json(p) == before
end

@testset "regression export: EPS" begin
	p = plot_scatter([1.0, 2.0, 3.0], [1.0, 3.0, 2.0]; title = "eps")
	if _reg_has_ghostscript()
		eps = savefig(p; format = "eps", width = 336, height = 252)
		text = _reg_ascii(eps)
		@test startswith(text, "%!PS-Adobe-3.0 EPSF-3.0")
		@test occursin("%%BoundingBox: 0 0 252 189", text)
		@test !occursin(r"%%CreationDate: \S", text)
		@test savefig(p; format = "eps", width = 336, height = 252) == eps
	else
		@test_throws ArgumentError savefig(p; format = "eps")
	end
end

@testset "regression export: files" begin
	p = _reg_heatmap("files")
	mktempdir() do dir
		jpg = joinpath(dir, "figure.jpg")
		@test savefig(p, jpg) == jpg
		@test read(jpg)[1:2] == UInt8[0xff, 0xd8]

		reference = joinpath(dir, "reference.txt")
		write(reference, "x")
		real = joinpath(dir, "real.png")
		write(real, "old")
		chmod(real, 0o640)
		link = joinpath(dir, "link.png")
		symlink(real, link)
		savefig(p, link)
		@test islink(link)
		@test read(real)[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]
		@test filemode(real) & 0o777 == 0o640
		fresh = joinpath(dir, "fresh.png")
		savefig(p, fresh)
		@test filemode(fresh) & 0o777 == filemode(reference) & 0o777

		formats = ["png", "svg", "pdf", "json", "html"]
		_reg_has_ghostscript() && push!(formats, "eps")
		names = [joinpath(dir, "multi.$fmt") for fmt in formats]
		@test savefig(p, names) == names
		@test all(isfile, names)
		@test read(names[1]) == savefig(p; format = "png")
		@test read(names[2]) == savefig(p; format = "svg")
		@test read(names[3]) == savefig(p; format = "pdf")
	end
end

@testset "regression export: renderer bounds and window state" begin
	big = plot_scatter(collect(1.0:200_000), rand(200_000))
	err = try
		savefig(big; format = "png", timeout = 0.001)
		nothing
	catch caught
		caught
	end
	@test err isa PlotlySupply._ExportTimeoutError
	@test occursin("timeout", sprint(showerror, err))
	# The busy window was retired; the next export gets a fresh one.
	@test PlotlySupply._EXPORT_STATE.window === nothing
	@test !isempty(savefig(plot_scatter([1.0, 2.0], [1.0, 2.0]); format = "png"))

	withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => "TeX") do
		savefig(plot_scatter([1.0, 2.0], [1.0, 2.0]); format = "png")
		@test PlotlySupply._EXPORT_STATE.mathjax_font == "TeX"
	end
	withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => nothing) do
		savefig(plot_scatter([1.0, 2.0], [1.0, 2.0]); format = "png")
		@test PlotlySupply._EXPORT_STATE.mathjax_font == "Latin-Modern"
	end
end

@testset "regression export: concatenated hidden SyncPlots stay hidden" begin
	a = to_syncplot(plot_scatter([1.0, 2.0], [1.0, 2.0]); show = false)
	b = to_syncplot(plot_scatter([1.0, 2.0], [2.0, 1.0]); show = false)
	joined = Any[]
	try
		push!(joined, hcat(a, b))
		push!(joined, vcat(a, b))
		push!(joined, hvcat((1, 1), a, b))
		for sp in joined
			spec = PlotlySupply._syncplot_creation_spec(sp)
			@test !spec.show
		end
	finally
		foreach(close, joined)
		close(a)
		close(b)
	end
end
