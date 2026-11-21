using Test, PlotlySupply
using Base64
using PlotlySupply: PlotlyBase

# Two exports of a 3-D scene: equal apart from the WebGL bitmap, whose pixels
# differ by at most a few anti-aliasing levels on a small fraction of pixels.
function _reg_same_pixels(a::Vector{UInt8}, b::Vector{UInt8})
	wa, ha, ca, pa = PlotlySupply._png_decode(a)
	wb, hb, cb, pb = PlotlySupply._png_decode(b)
	(wa, ha, ca) == (wb, hb, cb) || return false
	diff = abs.(Int.(pa) .- Int.(pb))
	return count(>(0), diff) <= 0.01 * length(diff) && maximum(diff; init = 0) <= 96
end
function _reg_same_scene_export(a::Vector{UInt8}, b::Vector{UInt8}, fmt::String)
	a == b && return true
	fmt == "png" && return _reg_same_pixels(a, b)
	bitmap = r"data:image/png;base64,([A-Za-z0-9+/=]+)"
	sa, sb = String(copy(a)), String(copy(b))
	replace(sa, bitmap => "BITMAP") == replace(sb, bitmap => "BITMAP") || return false
	ma, mb = collect(eachmatch(bitmap, sa)), collect(eachmatch(bitmap, sb))
	length(ma) == length(mb) || return false
	return all(_reg_same_pixels(base64decode(x.captures[1]), base64decode(y.captures[1])) for (x, y) in zip(ma, mb))
end

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
	@test err isa ErrorException  # the documented renderer-failure type (export-06)
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

# ── 2.0 wave 4 (math-export) ────────────────────────────────────────

# First-IFD tags of a little-endian TIFF: tag => (type, count, value-or-offset),
# plus the X resolution as a Float64.
function _reg_tiff(bytes::Vector{UInt8})
	u16(i) = Int(bytes[i]) | Int(bytes[i + 1]) << 8
	u32(i) = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
	bytes[1:4] == UInt8['I', 'I', 42, 0] || error("not a little-endian TIFF")
	ifd = u32(5)
	tags = Dict{Int,Tuple{Int,Int,Int}}()
	for k in 0:(u16(ifd + 1) - 1)
		entry = ifd + 3 + 12k
		tags[u16(entry)] = (u16(entry + 2), u32(entry + 4), u32(entry + 8))
	end
	xres = u32(tags[282][3] + 1) / u32(tags[282][3] + 5)
	return tags, xres
end

# Physical page size in points of `value` `units`.
_reg_points(value, units) = value / PlotlySupply._export_units_per_inch(units, "test") * 72

_reg_page_size(pdf::Vector{UInt8}) = (b = _reg_media_box(pdf); (b[3] - b[1], b[4] - b[2]))

# The PDF page is `w` x `h` pt to 0.01 pt.
_reg_page_is(pdf::Vector{UInt8}, w, h) =
	(s = _reg_page_size(pdf); abs(s[1] - w) < 0.01 && abs(s[2] - h) < 0.01)

# A square filled with 30 % red covering the middle of the plot area, no grid.
function _reg_translucent_square()
	p = Plot(scatter(
		x = [0.0, 1.0, 1.0, 0.0, 0.0], y = [0.0, 0.0, 1.0, 1.0, 0.0],
		fill = "toself", fillcolor = "rgba(255,0,0,0.3)", mode = "lines", line = attr(width = 0),
	))
	relayout!(p;
		xaxis = attr(range = [-0.1, 1.1], visible = false),
		yaxis = attr(range = [-0.1, 1.1], visible = false),
		showlegend = false, margin = attr(l = 20, r = 20, t = 20, b = 20),
		paper_bgcolor = "white", plot_bgcolor = "white",
	)
	return p
end

# RGB of the pixel at the centre of an RGB(A) PNG.
function _reg_png_centre(png::Vector{UInt8})
	w, h, channels, pixels = PlotlySupply._png_decode(png)
	i = ((h ÷ 2) * w + w ÷ 2) * channels
	return Int.(pixels[(i + 1):(i + 3)])
end

@testset "regression export: exact physical sizes (G17)" begin
	p = plot_scatter([1.0, 2.0, 3.0], [1.0, 3.0, 2.0]; title = "exact size")
	# PDF pages are exact to 0.01 pt for any size; Chromium alone rounds the
	# page up to whole points and then to 1/300 in.
	for (w, h, units) in (
		(8.3, 6, :cm), (85, 60, :mm), (8.89, 6.35, :cm), (3.5, 2.5, :in),
		(7.16, 4, :in), (88, 66, :mm), (180, 120, :mm),
	)
		pw, ph = _reg_page_size(savefig(p; format = "pdf", width = w, height = h, units = units))
		@test abs(pw - _reg_points(w, units)) < 0.01
		@test abs(ph - _reg_points(h, units)) < 0.01
	end
	pdfinfo = Sys.which("pdfinfo")
	if pdfinfo !== nothing
		mktempdir() do dir
			path = joinpath(dir, "cm.pdf")
			savefig(p, path; width = 8.3, height = 6, units = :cm)
			m = match(r"Page size:\s+([0-9.]+) x ([0-9.]+) pts", read(`$pdfinfo $path`, String))
			@test abs(parse(Float64, m.captures[1]) - 235.276) < 0.01
			@test abs(parse(Float64, m.captures[2]) - 170.079) < 0.01
		end
	end

	# Raster images have round(width_in * dpi) pixels and record the dpi.
	for (w, units) in ((3.5, :in), (7.16, :in), (88, :mm), (180, :mm)), dpi in (300, 600, 1200)
		h = units === :in ? 1.0 : 25.0   # short pages keep the 1200-dpi images small
		inches_w, inches_h = w / PlotlySupply._export_units_per_inch(units, "test"),
			h / PlotlySupply._export_units_per_inch(units, "test")
		png = savefig(p; format = "png", width = w, height = h, units = units, dpi = dpi)
		@test _reg_png_size(png) == (round(Int, inches_w * dpi), round(Int, inches_h * dpi))
		phys = _reg_png_chunk(png, "pHYs")
		@test _reg_u32(phys, 1) == round(Int, dpi / 0.0254)
	end
	# 6.35 cm at 300 dpi is 749.9999999999999 CSS px * scale: 750 rows, not 749.
	tall = savefig(p; format = "png", width = 8.89, height = 6.35, units = :cm, dpi = 300)
	@test _reg_png_size(tall) == (1050, 750)
	# Every pixel is opaque: the drawing fills the canvas to its edges.
	_, _, channels, pixels = PlotlySupply._png_decode(tall)
	@test channels == 4 && all(==(0xff), @view pixels[4:4:end])
	# JPEG records the dpi in its JFIF header.
	jpeg = savefig(p; format = "jpeg", width = 88, height = 25, units = :mm, dpi = 600)
	@test jpeg[14:18] == UInt8[0x01, 0x02, 0x58, 0x02, 0x58]   # dots per inch, 600 x 600

	# Two back-to-back exports of different sizes do not affect each other.
	small = savefig(p; format = "png", width = 300, height = 200)
	@test _reg_png_size(small) == (300, 200)
	@test _reg_png_size(savefig(p; format = "png", width = 640, height = 480)) == (640, 480)
	@test savefig(p; format = "png", width = 300, height = 200) == small
	@test _reg_page_is(savefig(p; format = "pdf", width = 300, height = 200), 225, 150)
	@test _reg_page_is(savefig(p; format = "pdf", width = 640, height = 480), 480, 360)
end

@testset "regression export: TIFF" begin
	p = _reg_heatmap("tiff")
	tiff = savefig(p; format = "tiff", width = 88, height = 66, units = :mm, dpi = 600)
	tags, xres = _reg_tiff(tiff)
	@test (tags[256][3], tags[257][3]) == (2079, 1559)
	@test tags[259][3] == 5 && tags[296][3] == 2
	@test xres == 600.0
	# Lossless: the same pixels as the PNG of the same export.
	png = savefig(p; format = "png", width = 88, height = 66, units = :mm, dpi = 600)
	@test PlotlySupply._png_size(png) == (2079, 1559)
	# Default: 300 dpi; `scale` sets 96 * scale dpi.
	default_tags, default_res = _reg_tiff(savefig(p; format = "tiff", width = 336, height = 252))
	@test (default_tags[256][3], default_tags[257][3], default_res) == (1050, 788, 300.0)
	_, scaled_res = _reg_tiff(savefig(p; format = "tiff", width = 336, height = 252, scale = 2))
	@test scaled_res == 192.0
	# A transparent background keeps an alpha sample; an opaque one is RGB.
	@test default_tags[277][3] == 3 && !haskey(default_tags, 338)
	clear_tags, _ = _reg_tiff(savefig(p; format = "tiff", width = 336, height = 252, background = :transparent))
	@test clear_tags[277][3] == 4 && clear_tags[338][3] == 2
	@test savefig(p; format = "tiff", width = 336, height = 252) == savefig(p; format = "tiff", width = 336, height = 252)

	mktempdir() do dir
		path = joinpath(dir, "figure.tif")
		@test savefig(p, path; width = 88, height = 66, units = :mm, dpi = 600) == path
		@test read(path) == tiff
		tiffinfo = Sys.which("tiffinfo")
		if tiffinfo !== nothing
			info = read(`$tiffinfo $path`, String)
			@test occursin("Image Width: 2079 Image Length: 1559", info)
			@test occursin(r"Resolution: 600, 600 pixels/inch", info)
			@test occursin("LZW", info)
		end
		sips = Sys.which("sips")
		if sips !== nothing
			info = read(`$sips -g pixelWidth -g pixelHeight -g dpiWidth $path`, String)
			@test occursin("pixelWidth: 2079", info)
			@test occursin("pixelHeight: 1559", info)
			@test occursin("dpiWidth: 600", info)
		end
		magick = Sys.which("magick")
		if magick !== nothing
			@test strip(read(`$magick identify -format "%w %h %x %U" $path`, String)) ==
				  "2079 1559 600 PixelsPerInch"
			# Decoded pixels equal the PNG's pixels.
			rgb = read(`$magick $path -depth 8 rgb:-`)
			w, h, channels, pixels = PlotlySupply._png_decode(png)
			@test channels == 4
			@test rgb == pixels[[k for k in eachindex(pixels) if k % 4 != 0]]
		end
	end
end

@testset "regression export: SVG physical units" begin
	p = plot_scatter([1.0, 2.0, 3.0], [1.0, 3.0, 2.0]; title = "units")
	root(svg) = match(r"<svg\b[^>]*>", svg).match
	mm = root(String(savefig(p; format = "svg", width = 88, height = 66, units = :mm)))
	@test occursin("width=\"88mm\" height=\"66mm\"", mm)
	viewbox = parse.(Float64, split(match(r"viewBox=\"([^\"]*)\"", mm).captures[1]))
	@test viewbox[3] ≈ 88 / 25.4 * 96 && viewbox[4] ≈ 66 / 25.4 * 96
	@test occursin("width=\"3.5in\" height=\"2.5in\"",
		root(String(savefig(p; format = "svg", width = 3.5, height = 2.5, units = :in))))
	@test occursin("width=\"8.3cm\" height=\"6cm\"",
		root(String(savefig(p; format = "svg", width = 8.3, height = 6, units = :cm))))
	# Pixel sizes stay unitless CSS px, as in 1.x.
	px = root(String(savefig(p; format = "svg", width = 400, height = 300)))
	@test occursin("width=\"400\" height=\"300\"", px)
end

@testset "regression export: fonts (G44)" begin
	x = collect(range(0, 1; length = 20))
	stix = plot_scatter(x, x .^ 2; xlabel = "time (s)", ylabel = raw"$\alpha$ amplitude", title = "STIX title")
	relayout!(stix; font = attr(family = "STIXGeneral"))
	plain = plot_scatter(x, x .^ 2; xlabel = "time (s)", ylabel = "amplitude", title = "Plain title")
	font_objects(pdf) = length(collect(eachmatch(r"/Type\s*/Font\b", _reg_ascii(pdf))))

	# Text drawn in TrueType fonts stays text in :auto: nothing to outline, so
	# :auto and :embed give the same file.
	plain_embed = savefig(plain; format = "pdf", fonts = :embed)
	if isempty(PlotlySupply._pdf_type3_fonts(plain_embed))
		@test savefig(plain; format = "pdf") == plain_embed
		@test font_objects(plain_embed) > 0
		pdftotext = Sys.which("pdftotext")
		if pdftotext !== nothing
			mktempdir() do dir
				path = joinpath(dir, "plain.pdf")
				write(path, plain_embed)
				@test occursin("Plain title", read(`$pdftotext $path -`, String))
			end
		end
	end

	# A CFF font (STIX, when installed) is a Type 3 font in Chromium's PDF.
	stix_embed = savefig(stix; format = "pdf", fonts = :embed)
	has_type3 = !isempty(PlotlySupply._pdf_type3_fonts(stix_embed))
	if has_type3
		# Without Ghostscript :auto keeps them and warns.
		mktempdir() do empty_path
			withenv("PATH" => empty_path) do
				kept = @test_logs (:warn, r"Type 3 fonts") match_mode = :any savefig(stix; format = "pdf")
				@test !isempty(PlotlySupply._pdf_type3_fonts(kept))
			end
		end
	end
	if _reg_has_ghostscript()
		w, h = 3.5, 2.6
		stix_auto = savefig(stix; format = "pdf", width = w, height = h, units = :in)
		@test isempty(PlotlySupply._pdf_type3_fonts(stix_auto))
		has_type3 && @test font_objects(stix_auto) == 0
		outlined = savefig(plain; format = "pdf", width = w, height = h, units = :in, fonts = :outline)
		@test font_objects(outlined) == 0
		# Outlining keeps the exact page and is deterministic.
		for pdf in (stix_auto, outlined)
			pw, ph = _reg_page_size(pdf)
			@test abs(pw - 252) < 0.01 && abs(ph - 187.2) < 0.01
		end
		@test savefig(plain; format = "pdf", width = w, height = h, units = :in, fonts = :outline) == outlined
		pdffonts = Sys.which("pdffonts")
		if pdffonts !== nothing
			mktempdir() do dir
				path = joinpath(dir, "outlined.pdf")
				write(path, outlined)
				listing = split(strip(read(`$pdffonts $path`, String)), '\n')
				@test length(listing) == 2   # the two header lines, no font
			end
		end

		# EPS: text is outlines unless fonts = :embed.
		embedded_font(eps) = occursin("%%BeginResource: procset (PDF Font", _reg_ascii(eps))
		@test !embedded_font(savefig(plain; format = "eps"))
		@test embedded_font(savefig(plain; format = "eps", fonts = :embed))
	else
		@test_throws ArgumentError savefig(plain; format = "pdf", fonts = :outline)
	end
end

@testset "regression export: EPS translucency and page box (G40)" begin
	if _reg_has_ghostscript()
		p = _reg_translucent_square()
		# The PNG shows 30 % red over white at the centre.
		@test all(abs.(_reg_png_centre(savefig(p; format = "png", width = 400, height = 300)) .- [255, 179, 179]) .<= 2)
		eps = savefig(p; format = "eps", width = 400, height = 300)
		text = _reg_ascii(eps)
		@test occursin("%%BoundingBox: 0 0 300 225", text)
		@test occursin("%%HiResBoundingBox: 0 0 300 225", text)
		mktempdir() do dir
			eps_path = joinpath(dir, "square.eps")
			png_path = joinpath(dir, "square.png")
			write(eps_path, eps)
			gs = PlotlySupply._ghostscript_command()
			run(pipeline(`$gs -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=png16m -r96 -dEPSCrop -sOutputFile=$png_path $eps_path`;
				stdout = devnull, stderr = devnull))
			drawn = read(png_path)
			@test PlotlySupply._png_size(drawn) == (400, 300)
			# The square prints light red (blended), not opaque red.
			@test all(abs.(_reg_png_centre(drawn) .- [255, 179, 179]) .<= 3)
		end
		# A fractional page: the HiRes box is exact, the integer box rounds up.
		cm = _reg_ascii(savefig(p; format = "eps", width = 8.3, height = 6, units = :cm))
		@test occursin("%%BoundingBox: 0 0 236 171", cm)
		@test occursin("%%HiResBoundingBox: 0 0 235.2756 170.0787", cm)
	else
		@test_throws ArgumentError savefig(_reg_translucent_square(); format = "eps")
	end
end

# P6 (ppmraw) image as (width, height, bytes of r, g, b triples).
function _reg_ppm(data::Vector{UInt8})
	text = String(UInt8[b < 0x80 ? b : UInt8('?') for b in data[1:min(end, 120)]])
	m = match(r"^P6\s+(?:#[^\n]*\n\s*)?(\d+)\s+(\d+)\s+255\s", text)
	m === nothing && error("not a P6 image")
	w, h = parse(Int, m.captures[1]), parse(Int, m.captures[2])
	return w, h, data[(ncodeunits(m.match) + 1):end]
end

@testset "regression export: an EPS band does not hide the curves under it" begin
	if _reg_has_ghostscript()
		x = collect(range(0.0, 1.0; length = 50))
		p = plot_scatter(x, fill(0.5, 50); color = "#ff0000", linewidth = 8,
			xrange = [0, 1], yrange = [0, 1])
		plot_band!(p, x, fill(0.2, 50), fill(0.8, 50); color = "#0000ff", opacity = 0.3)
		red_pixels(raster) = begin
			w, h, bytes = _reg_ppm(raster)
			count(i -> bytes[i] > 200 && bytes[i + 1] < 90 && bytes[i + 2] < 90, 1:3:(3 * w * h))
		end
		mktempdir() do dir
			gs = PlotlySupply._ghostscript_command()
			function rasterize(bytes, name)
				path = joinpath(dir, name)
				write(path, bytes)
				return read(pipeline(`$gs -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=ppmraw -r96 -dEPSCrop -sOutputFile=- $path`;
					stderr = devnull))
			end
			eps_red = red_pixels(rasterize(savefig(p; format = "eps", width = 400, height = 300), "band.eps"))
			# The line is 8 px thick and about 300 px long: it is drawn at full
			# strength, not hidden by the blended band.
			@test eps_red > 1500
		end
	end
end

@testset "regression export: large data arrays travel as typed arrays" begin
	PS = PlotlySupply
	decode(payload, T) = reinterpret(T, Base64.base64decode(payload.bdata))
	old_min = PS._EXPORT_TYPED_ARRAY_MIN[]
	try
		PS._EXPORT_TYPED_ARRAY_MIN[] = 10
		# the JSON layout of a matrix is an array of its columns: same here
		m = reshape(collect(1.0:24.0), 4, 6)
		@test PlotlyBase.JSON.json(m) == "[[1.0,2.0,3.0,4.0],[5.0,6.0,7.0,8.0],[9.0,10.0,11.0,12.0],[13.0,14.0,15.0,16.0],[17.0,18.0,19.0,20.0],[21.0,22.0,23.0,24.0]]"
		mp = PS._typed_array_payload(m)
		@test (mp.dtype, mp.shape) == ("f8", "6, 4")
		@test decode(mp, Float64) == vec(m)
		@test PlotlyBase.JSON.lower(mp) == Dict("dtype" => "f8", "bdata" => mp.bdata, "shape" => "6, 4")

		# vectors, other dtypes, NaN and Inf, views, adjoints and ranges
		v = [1.5, NaN, Inf, -Inf, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
		vp = PS._typed_array_payload(v)
		@test vp.shape === nothing && vp.dtype == "f8"
		@test isequal(decode(vp, Float64), v)
		@test decode(PS._typed_array_payload(Float32.(1:20)), Float32) == Float32.(1:20)
		@test PS._typed_array_payload(Int32.(1:20)).dtype == "i4"
		@test PS._typed_array_payload(UInt8.(1:20)).dtype == "u1"
		@test decode(PS._typed_array_payload(view(collect(1.0:40.0), 1:2:40)), Float64) == collect(1.0:2:39)
		@test decode(PS._typed_array_payload(range(0, 1; length = 25)), Float64) == collect(range(0, 1; length = 25))
		adj = PS._typed_array_payload(adjoint(m))
		@test adj.shape == "4, 6" && decode(adj, Float64) == vec(collect(adjoint(m)))

		# what stays JSON: short arrays, 64-bit integers, non-numbers, 3-D arrays
		@test PS._typed_array_payload(collect(1.0:9)) === nothing
		@test PS._typed_array_payload(collect(1:20)) === nothing
		@test PS._typed_array_payload(string.(1:20)) === nothing
		@test PS._typed_array_payload(fill(missing, 20)) === nothing
		@test PS._typed_array_payload(zeros(3, 3, 3)) === nothing
		@test PS._typed_array_payload("text") === nothing
		@test PS._typed_array_payload(nothing) === nothing

		# a lowered trace is copied, not changed; only the data keys convert
		trace = Dict{Symbol,Any}(:type => "heatmap", :z => m, :x => collect(1:6),
			:marker => Dict(:color => collect(1.0:20)), :text => string.(1:20))
		out = PS._export_typed_arrays(Any[trace, "kept"])
		@test out[2] == "kept"
		@test trace[:z] === m
		@test out[1][:z] isa PS._TypedArrayPayload
		@test out[1][:x] === trace[:x] && out[1][:marker] === trace[:marker] && out[1][:text] === trace[:text]
		string_keyed = Dict{String,Any}("type" => "scatter", "y" => collect(1.0:20))
		@test PS._export_typed_arrays(Any[string_keyed])[1]["y"] isa PS._TypedArrayPayload
		@test string_keyed["y"] isa Vector{Float64}

		# the figure drawn from typed arrays is the figure drawn from JSON
		x = collect(range(-2, 2; length = 40)); y = collect(range(-1, 1; length = 30))
		z = [exp(-(a^2 + 3b^2)) for a in x, b in y]
		heat = plot_heatmap(x, y, z; show = false)
		surf = plot_surface(x, y, z; show = false)
		line = plot_scatter(x, sin.(x); show = false)
		for fig in (heat, surf, line), fmt in ("png", "svg")
			PS._EXPORT_TYPED_ARRAY_MIN[] = 10
			prepared = PS._prepare_savefig(fig, fmt, (;))
			@test occursin("\"bdata\"", prepared.data_js)
			typed = savefig(fig; format = fmt, width = 400, height = 300)
			PS._EXPORT_TYPED_ARRAY_MIN[] = typemax(Int)
			@test !occursin("\"bdata\"", PS._prepare_savefig(fig, fmt, (;)).data_js)
			plain = savefig(fig; format = fmt, width = 400, height = 300)
			if fig === surf
				# A 3-D scene is a WebGL bitmap, and two GPU draws of the same
				# scene may differ in a few anti-aliased pixels (O15). What is
				# promised: the same document around the bitmap, and the same
				# picture to within a few pixels.
				@test _reg_same_scene_export(typed, plain, fmt)
			else
				@test typed == plain
			end
		end
	finally
		PS._EXPORT_TYPED_ARRAY_MIN[] = old_min
	end

	# the default threshold: a 1000 x 1000 heatmap is sent as bytes (about
	# 10.7 characters per number, not about 19 as JSON text)
	z = [sin(0.01i) * cos(0.013j) for i in 1:1000, j in 1:1000]
	data_js = PS._prepare_savefig(plot_heatmap(z; show = false), "png", (;)).data_js
	@test occursin("\"bdata\"", data_js)
	@test sizeof(data_js) < 12 * length(z)
	# html and json documents keep plain arrays
	html = String(savefig(plot_heatmap(z[1:300, 1:300]; show = false); format = "html"))
	@test !occursin("\"bdata\":", html)   # (plotly.js itself mentions the word)
end

@testset "regression export: deterministic bytes in every format" begin
	p = _reg_heatmap("every format")
	formats = ["png", "jpeg", "tiff", "svg", "pdf", "html", "json"]
	_reg_has_ghostscript() && push!(formats, "eps")
	for fmt in formats
		@test savefig(p; format = fmt, width = 300, height = 220) == savefig(p; format = fmt, width = 300, height = 220)
	end
end

@testset "regression export: results longer than one renderer reply" begin
	chunk = PlotlySupply._RENDERER_RESULT_CHUNK
	# 20 000 SVG markers make an SVG of several slices.
	x = collect(1.0:20_000)
	many = plot_scatter(x, sin.(x); mode = "markers")
	svg = String(savefig(many; format = "svg"))
	@test ncodeunits(svg) > chunk
	@test startswith(svg, "<svg") && endswith(svg, "</svg>")
	@test count("class=\"point\"", svg) == 20_000
	@test savefig(many; format = "svg") == codeunits(svg)

	# A slice boundary never splits a UTF-16 surrogate pair: 'a' followed by
	# U+1D465 pairs puts a high surrogate at every odd index, including the
	# last unit of the first full slice.
	pairs = chunk + 500
	text = PlotlySupply._with_export_window(PlotlySupply._EXPORT_STATE) do ec, app, win, divid
		script = "(function() { const result = 'a' + '\\u{1D465}'.repeat($(pairs));\n" *
				 PlotlySupply._RENDERER_RESULT_HANDOFF_JS * "})()"
		reply = Base.invokelatest(() -> ec.run(win, script))
		@test reply["resultLength"] == 1 + 2 * pairs
		fetched = PlotlySupply._fetch_renderer_result(ec, win, reply["resultLength"], "svg")
		# The page releases the result after the last slice.
		@test Base.invokelatest(() -> ec.run(win, "typeof window.__plotlysupplyExportResult")) == "undefined"
		fetched
	end
	@test text == "a" * "\U1D465"^pairs
end

@testset "regression export: robustness" begin
	# A figure without traces exports at the default size.
	empty_fig = Plot()
	@test _reg_png_size(savefig(empty_fig; format = "png")) == (700, 500)
	@test _reg_page_is(savefig(empty_fig; format = "pdf"), 525, 375)
	@test _reg_tiff(savefig(empty_fig; format = "tiff"))[1][256][3] == 2188
	@test occursin("<svg", String(savefig(empty_fig; format = "svg")))

	# Twenty exports in a row reuse one export window.
	p = plot_scatter([1.0, 2.0, 3.0], [1.0, 3.0, 2.0]; title = "reuse")
	savefig(p; format = "png")
	window = PlotlySupply._EXPORT_STATE.window
	@test window !== nothing
	formats = ("png", "svg", "pdf", "jpeg", "tiff")
	for k in 1:20
		@test !isempty(savefig(p; format = formats[mod1(k, length(formats))], width = 300 + k, height = 200))
	end
	@test PlotlySupply._EXPORT_STATE.window === window

	# A live SubplotFigure exports while its window stays open and unchanged.
	sf = subplots(1, 2; show = false)
	try
		plot_scatter!(sf, [1.0, 2.0, 3.0], [3.0, 1.0, 2.0])
		before = _RegExportJSON.json(sf.plot)
		@test _reg_png_size(savefig(sf; format = "png", width = 500, height = 250)) == (500, 250)
		@test _reg_page_is(savefig(sf; format = "pdf", width = 500, height = 250), 375, 187.5)
		@test isopen(sf.fig)
		@test _RegExportJSON.json(sf.plot) == before
	finally
		close(sf)
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

@testset "regression export: SVG bytes are stable across many exports (Z58, Z90)" begin
	heat = _reg_heatmap("stable heat")
	line = plot_scatter([1.0, 2.0, 3.0], [3.0, 1.0, 2.0]; title = "stable line")
	reference = (heat = savefig(heat; format = "svg"), line = savefig(line; format = "svg"))
	for _ in 1:8
		@test savefig(heat; format = "svg") == reference.heat
		@test savefig(line; format = "svg") == reference.line
	end
	# No random plotly.js id survives: one uid in defs, clips and the colorbar gradient.
	svg = String(reference.heat)
	@test length(unique(m.captures[1] for m in eachmatch(r"\bg([0-9a-f]{6})-cb", svg))) == 1
	@test only(unique(m.captures[1] for m in eachmatch(r"\bg([0-9a-f]{6})-cb", svg))) == "000000"
	# The root tag's attributes come in the canonical order.
	root = match(r"^<svg[^>]*>", svg).match
	positions = [first(findfirst(name * "=\"", root)) for name in ("xmlns", "width", "height", "viewBox", "style")]
	@test issorted(positions)
end

@testset "regression export: exact page and pixel sizes for every units value (Z66)" begin
	fig = plot_scatter(1:5, [1, 3, 2, 5, 4.0]; xlabel = "x", ylabel = "y")
	points_per = Dict(:in => 72.0, :cm => 72 / 2.54, :mm => 72 / 25.4, :pt => 1.0, :px => 0.75)
	per_inch = Dict(:in => 1.0, :cm => 2.54, :mm => 25.4, :pt => 72.0, :px => 96.0)
	for (w, h, units) in ((8.3, 6.0, :cm), (3.5, 2.5, :in), (89, 60, :mm), (252, 180, :pt), (336, 252, :px), (7.16, 3, :in), (183, 100, :mm))
		box = _reg_media_box(savefig(fig; format = "pdf", width = w, height = h, units = units))
		@test isapprox(box[3] - box[1], w * points_per[units]; atol = 0.01)
		@test isapprox(box[4] - box[2], h * points_per[units]; atol = 0.01)
		if _reg_has_ghostscript()
			eps = _reg_ascii(savefig(fig; format = "eps", width = w, height = h, units = units))
			bb = parse.(Float64, match(r"%%HiResBoundingBox: (\S+) (\S+) (\S+) (\S+)", eps).captures)
			@test isapprox(bb[3], w * points_per[units]; atol = 0.01) && isapprox(bb[4], h * points_per[units]; atol = 0.01)
		end
		for dpi in (300, 600)
			png = savefig(fig; format = "png", width = w, height = h, units = units, dpi = dpi)
			@test _reg_png_size(png) == (round(Int, w / per_inch[units] * dpi), round(Int, h / per_inch[units] * dpi))
		end
	end
end
