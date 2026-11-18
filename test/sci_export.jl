using Test, PlotlySupply
using PlotlySupply: PlotlyBase

# Export tests that need no renderer: byte-level helpers, option validation,
# HTML/JSON output and file publication. Live Electron export is covered by
# test/regression_export.jl.

const _SciExportJSON = PlotlyBase.JSON

_sci_u32(x::Integer) = collect(reinterpret(UInt8, [hton(UInt32(x))]))

function _sci_png_chunk(kind::String, data::Vector{UInt8})
	body = vcat(collect(codeunits(kind)), data)
	return vcat(_sci_u32(length(data)), body, _sci_u32(PlotlySupply._crc32(body)))
end

function _sci_png(; extra::Vector{Vector{UInt8}} = Vector{UInt8}[], trailing::Vector{UInt8} = UInt8[])
	ihdr = vcat(_sci_u32(1), _sci_u32(1), UInt8[8, 6, 0, 0, 0])
	return vcat(
		UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
		_sci_png_chunk("IHDR", ihdr),
		extra...,
		_sci_png_chunk("IDAT", UInt8[0x78, 0x9c, 0x01, 0x02]),
		_sci_png_chunk("IEND", UInt8[]),
		trailing,
	)
end

# (kind, data, stored crc) of every chunk up to IEND.
function _sci_png_chunks(bytes::Vector{UInt8})
	chunks = Tuple{String,Vector{UInt8},UInt32}[]
	i = 9
	while i <= length(bytes)
		len = Int(ntoh(reinterpret(UInt32, bytes[i:(i + 3)])[1]))
		kind = String(bytes[(i + 4):(i + 7)])
		data = bytes[(i + 8):(i + 7 + len)]
		crc = ntoh(reinterpret(UInt32, bytes[(i + 8 + len):(i + 11 + len)])[1])
		push!(chunks, (kind, data, crc))
		i += 12 + len
		kind == "IEND" && break
	end
	return chunks
end

# A minimal single-page PDF with a classic xref table and an Info dictionary.
function _sci_pdf(media::String)
	objects = [
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox $media /Contents 4 0 R >>",
		"<< /Length 0 >>\nstream\n\nendstream",
		"<< /Producer (test) /CreationDate (D:20261116104745+00'00') /ModDate (D:20261116104745+00'00') >>",
	]
	io = IOBuffer()
	write(io, "%PDF-1.4\n")
	offsets = Int[]
	for (index, body) in enumerate(objects)
		push!(offsets, position(io))
		write(io, "$index 0 obj\n$body\nendobj\n")
	end
	xref = position(io)
	write(io, "xref\n0 $(length(objects) + 1)\n0000000000 65535 f \n")
	for offset in offsets
		write(io, lpad(string(offset), 10, '0'), " 00000 n \n")
	end
	write(io, "trailer\n<< /Size $(length(objects) + 1) /Root 1 0 R /Info 5 0 R >>\n")
	write(io, "startxref\n$xref\n%%EOF\n")
	return take!(io)
end

# Every in-use xref entry must point at "<n> 0 obj" and startxref at "xref".
function _sci_pdf_xref_valid(bytes::Vector{UInt8})
	text = String(copy(bytes))
	starts = collect(eachmatch(r"startxref\s+(\d+)", text))
	xref = parse(Int, last(starts).captures[1])
	text[(xref + 1):(xref + 4)] == "xref" || return false
	entries = collect(eachmatch(r"(\d{10}) 00000 n", text))
	isempty(entries) && return false
	for (index, entry) in enumerate(entries)
		offset = parse(Int, entry.captures[1])
		startswith(text[(offset + 1):end], "$index 0 obj") || return false
	end
	return true
end

function _sci_media_box(bytes::Vector{UInt8})
	m = match(r"/MediaBox\s*\[([^\]]*)\]", String(copy(bytes)))
	return parse.(Float64, split(m.captures[1]))
end

_sci_plot() = plot_scatter([1.0, 2.0, 3.0], [1.0, 3.0, 2.0]; title = "export")

_sci_options(p; kwargs...) = PlotlySupply._normalize_export_options(p, (; kwargs...))

@testset "sci export: physical units" begin
	@test PlotlySupply._physical_to_px(3.5, :in) == 336.0
	@test PlotlySupply._physical_to_px(2.54, :cm) ≈ 96.0
	@test PlotlySupply._physical_to_px(25.4, :mm) ≈ 96.0
	@test PlotlySupply._physical_to_px(72, :pt) == 96.0
	@test PlotlySupply._physical_to_px(123.5, :px) == 123.5
	@test PlotlySupply._physical_to_px(floatmax(Float64), :px) == floatmax(Float64)
	@test_throws ArgumentError PlotlySupply._physical_to_px(1, :furlong)
	@test_throws ArgumentError PlotlySupply._physical_to_px(true, :in)
	@test_throws ArgumentError PlotlySupply._physical_to_px(NaN, :in)
	@test_throws ArgumentError PlotlySupply._physical_to_px(Inf, :px)
end

@testset "sci export: PNG pHYs" begin
	# The CRC-32 check value of "123456789" (CRC-32/ISO-HDLC, as used by PNG).
	@test PlotlySupply._crc32(collect(codeunits("123456789"))) == 0xcbf43926

	png = _sci_png(trailing = UInt8[0x01, 0x02])
	out = PlotlySupply._png_set_phys(png, 300)
	chunks = _sci_png_chunks(out)
	@test [c[1] for c in chunks] == ["IHDR", "pHYs", "IDAT", "IEND"]
	kind, data, crc = chunks[2]
	ppm = round(Int, 300 / 0.0254)   # 11811 px/m
	@test data == vcat(_sci_u32(ppm), _sci_u32(ppm), UInt8[0x01])
	@test crc == PlotlySupply._crc32(vcat(collect(codeunits("pHYs")), data))
	@test out[(end - 1):end] == UInt8[0x01, 0x02]
	@test length(out) == length(png) + 21
	@test png == _sci_png(trailing = UInt8[0x01, 0x02])   # input not mutated

	# An existing pHYs (wherever it is) is replaced, never duplicated.
	again = PlotlySupply._png_set_phys(out, 600)
	chunks = _sci_png_chunks(again)
	@test count(c -> c[1] == "pHYs", chunks) == 1
	@test chunks[2][2][1:4] == _sci_u32(round(Int, 600 / 0.0254))

	@test_throws ArgumentError PlotlySupply._png_set_phys(UInt8[0x01, 0x02], 300)
	@test_throws ArgumentError PlotlySupply._png_set_phys(png[1:20], 300)
	@test_throws ArgumentError PlotlySupply._png_set_phys(png, 0)
	@test_throws ArgumentError PlotlySupply._png_set_phys(png, NaN)
	@test_throws ArgumentError PlotlySupply._png_set_phys(png, true)
	@test_throws ArgumentError PlotlySupply._png_set_phys(png, 70_000)
end

@testset "sci export: JPEG density" begin
	jfif = UInt8[
		0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, codeunits("JFIF")..., 0x00, 0x01, 0x01,
		0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xd9,
	]
	out = PlotlySupply._jpeg_set_density(jfif, 300)
	@test length(out) == length(jfif)
	@test out[14] == 0x01                       # dots per inch
	@test out[15:18] == UInt8[0x01, 0x2c, 0x01, 0x2c]   # 300 = 0x012c
	@test out[[1:13; 19:end]] == jfif[[1:13; 19:end]]

	exif_only = UInt8[0xff, 0xd8, 0xff, 0xe1, 0x00, 0x04, 0xaa, 0xbb, 0xff, 0xd9]
	inserted = PlotlySupply._jpeg_set_density(exif_only, 72)
	@test inserted[1:2] == UInt8[0xff, 0xd8]
	@test inserted[3:4] == UInt8[0xff, 0xe0]
	@test inserted[7:11] == collect(codeunits("JFIF\0"))
	@test inserted[14:18] == UInt8[0x01, 0x00, 0x48, 0x00, 0x48]
	@test inserted[21:end] == exif_only[3:end]

	@test_throws ArgumentError PlotlySupply._jpeg_set_density(UInt8[0x89, 0x50, 0x4e, 0x47], 300)
	@test_throws ArgumentError PlotlySupply._jpeg_set_density(jfif, -1)
end

@testset "sci export: PDF dates and page box" begin
	pdf = _sci_pdf("[0 0 252 189.12]")
	@test _sci_pdf_xref_valid(pdf)

	blank = PlotlySupply._pdf_blank_dates(pdf)
	@test length(blank) == length(pdf)
	@test !occursin("CreationDate", String(copy(blank)))
	@test !occursin("ModDate", String(copy(blank)))
	@test occursin("/Producer (test)", String(copy(blank)))
	@test _sci_pdf_xref_valid(blank)
	@test PlotlySupply._pdf_blank_dates(blank) == blank
	# A value that is not a PDF date is left alone.
	odd = collect(codeunits("<< /CreationDate (yesterday) >>"))
	@test PlotlySupply._pdf_blank_dates(odd) == odd

	# Chromium's 1/300-in rounding: 252 x 189 pt requested, 189.12 printed.
	fixed = PlotlySupply._pdf_set_page_box(pdf, 252, 189)
	@test _sci_media_box(fixed) == [0.0, 0.12, 252.0, 189.12]
	@test _sci_pdf_xref_valid(fixed)
	@test length(fixed) == length(pdf) + 3   # y0 "0" became "0.12"
	@test PlotlySupply._pdf_set_page_box(fixed, 252, 189) == fixed   # already exact

	# 2.0 (G17): savefig asks Chromium for ceil(size) + 1 whole points and
	# crops the page to the exact size at its top-left corner; 8.3 x 6 cm is
	# 235.2756 x 170.0787 pt, requested as 237 x 172 pt.
	@test PlotlySupply._pdf_request_points(235.2755905511811) == 237.0
	@test PlotlySupply._pdf_request_points(252.0) == 253.0
	@test PlotlySupply._pdf_request_points(252.0 + 1e-12) == 253.0
	large = _sci_pdf("[0 0 237 172.08]")
	cropped = PlotlySupply._pdf_set_page_box(large, 8.3 / 2.54 * 72, 6.0 / 2.54 * 72)
	box = _sci_media_box(cropped)
	@test box[3] - box[1] ≈ 235.2756 atol = 1e-4
	@test box[4] - box[2] ≈ 170.0787 atol = 1e-4
	@test box[4] == 172.08   # top edge kept
	@test _sci_pdf_xref_valid(cropped)

	# A page box far from the request, or a layout the patcher cannot rewrite,
	# is an error: a wrong page size is never returned silently.
	far = try
		PlotlySupply._pdf_set_page_box(pdf, 300, 200)
		nothing
	catch err
		err
	end
	@test far isa ErrorException
	@test occursin("no page box near the requested 300.0 x 200.0 pt", sprint(showerror, far))
	@test occursin("252.0 x 189.12", sprint(showerror, far))
	@test_throws ErrorException PlotlySupply._pdf_set_page_box(collect(codeunits("%PDF-1.4\n%%EOF")), 252, 189)
	stream_xref = copy(pdf)
	xref_at = findlast("xref\n0 6", String(copy(pdf)))
	stream_xref[first(xref_at):(first(xref_at) + 3)] = codeunits("XREF")
	@test_throws ErrorException PlotlySupply._pdf_set_page_box(stream_xref, 252, 189)
	@test_throws ArgumentError PlotlySupply._pdf_set_page_box(pdf, 0, 189)
	@test_throws ArgumentError PlotlySupply._pdf_set_page_box(pdf, 252, Inf)

	@test PlotlySupply._format_pdf_number(189.12) == "189.12"
	@test PlotlySupply._format_pdf_number(0.12) == "0.12"
	@test PlotlySupply._format_pdf_number(252.0) == "252"
	@test PlotlySupply._format_pdf_number(-0.5) == "-0.5"
	@test PlotlySupply._format_pdf_number(1.0e-9) == "0"
	@test PlotlySupply._format_pdf_number(12345.00005) == "12345"
end

@testset "sci export: SVG ids and EPS dates" begin
	svg = """<svg><defs id="defs-1a2b3c"><g class="clips"><clipPath id="clip1a2b3cxyplot"></clipPath></g>""" *
		  """<linearGradient id="g1a2b3c-cbt0"></linearGradient></defs>""" *
		  """<g clip-path="url(#clip1a2b3cxyplot)"><rect style="fill: url('#g1a2b3c-cbt0');"/>""" *
		  """<use href="#clip1a2b3cxy"/><text>1a2b3c</text></g></svg>"""
	stable = PlotlySupply._svg_stable_ids(svg)
	@test !occursin("defs-1a2b3c", stable)
	@test occursin("""<defs id="defs-000000">""", stable)
	@test occursin("""<clipPath id="clip000000xyplot">""", stable)
	@test occursin("url(#clip000000xyplot)", stable)
	@test occursin("url('#g000000-cbt0')", stable)
	@test occursin("""href="#clip000000xy\"""", stable)
	@test occursin("<text>1a2b3c</text>", stable)   # text content untouched
	@test PlotlySupply._svg_stable_ids(stable) == stable
	@test PlotlySupply._svg_stable_ids("<svg></svg>") == "<svg></svg>"

	eps = collect(codeunits("%!PS-Adobe-3.0 EPSF-3.0\n%%CreationDate: D:20261116\n%%Pages: 1\nx %%CreationDate: keep\n"))
	blank = String(PlotlySupply._eps_blank_dates(eps))
	@test occursin("%%CreationDate:           \n", blank)
	@test occursin("x %%CreationDate: keep", blank)
	@test length(blank) == length(eps)

	@test PlotlySupply._ghostscript_output_path("a%d.eps") == "a%%d.eps"
	mktempdir() do empty_path
		withenv("PATH" => empty_path) do
			err = try
				PlotlySupply._ghostscript_command()
				nothing
			catch caught
				caught
			end
			@test err isa ArgumentError
			@test occursin("Ghostscript", sprint(showerror, err))
		end
	end
end

@testset "sci export: options" begin
	p = _sci_plot()
	o = _sci_options(p)
	@test (o.width, o.height, o.scale, o.dpi) == (700.0, 500.0, 1.0, nothing)
	@test o.deterministic && !o.tight && o.background === nothing
	@test o.timeout == 300.0

	sized = _sci_plot()
	relayout!(sized; width = 400, height = 300)
	@test (_sci_options(sized).width, _sci_options(sized).height) == (400.0, 300.0)
	@test _sci_options(sized; width = 200).width == 200.0
	tiny = _sci_plot()
	relayout!(tiny; width = 5, height = 5)   # plotly.js would ignore these
	@test (_sci_options(tiny).width, _sci_options(tiny).height) == (700.0, 500.0)

	inches = _sci_options(p; width = 3.5, height = 2.5, units = :in, dpi = 300)
	@test (inches.width, inches.height) == (336.0, 240.0)
	@test PlotlySupply._format_scale(inches, "png") == 300 / 96
	@test PlotlySupply._format_scale(inches, "jpeg") == 300 / 96
	@test PlotlySupply._format_scale(inches, "pdf") == 1.0
	@test PlotlySupply._format_scale(inches, "svg") == 1.0
	@test PlotlySupply._format_scale(_sci_options(p; scale = 2), "pdf") == 2.0
	@test _sci_options(p; width = 89, units = :mm).width ≈ 89 * 96 / 25.4

	for bad in (
		(width = 9,),
		(width = 0.1, units = :in),
		(height = -1,),
		(width = 10, scale = 0.05),
		(dpi = 300, scale = 2),
		(dpi = 0,),
		(units = "in",),
		(units = :furlong,),
		(deterministic = 1,),
		(tight = "yes",),
		(timeout = 0,),
		(timeout = -1,),
		(timeout = Inf,),
		(timeout = true,),
		(timeout = 2.0^40,),
		(background = 42,),
		(background = "notacolour",),
		(background = "url(javascript:alert(1))",),
		(unknown_option = 1,),
	)
		@test_throws ArgumentError _sci_options(p; bad...)
	end
	@test _sci_options(p; timeout = 0.5).timeout == 0.5

	for (given, stored) in (
		("white", "white"),
		(:white, "white"),
		(" #FFF ", "#FFF"),
		("#11223344", "#11223344"),
		("rgba(0, 0, 0, 0.5)", "rgba(0, 0, 0, 0.5)"),
		("hsl(120, 50%, 50%)", "hsl(120, 50%, 50%)"),
		("rebeccapurple", "rebeccapurple"),
		(:transparent, "rgba(0,0,0,0)"),
		("none", "rgba(0,0,0,0)"),
	)
		@test _sci_options(p; background = given).background == stored
	end

	if isdefined(PlotlySupply, :tight_layout!)
		@test _sci_options(p; tight = true).tight
	else
		@test_throws ArgumentError _sci_options(p; tight = true)
	end

	@test PlotlySupply._validate_export_format("jpg") == "jpeg"
	@test PlotlySupply._validate_export_format("JPG") == "jpeg"
	@test PlotlySupply._validate_export_format("eps") == "eps"
	@test_throws ErrorException PlotlySupply._validate_export_format("bmp")
	@test PlotlySupply._filename_export_format("figure.jpg", nothing) == "jpeg"
	@test PlotlySupply._filename_export_format("figure.EPS", nothing) == "eps"
	@test PlotlySupply._filename_export_format("figure.png", "SVG") == "svg"
end

@testset "sci export: renderer payload never touches the figure" begin
	p = plot_scatter([1.0, 2.0], [3.0, 4.0])
	add_trace!(p, scatter(x = [1, 2], y = [2, 1], uid = "t0"))
	add_trace!(p, scatter3d(x = [1], y = [2], z = [3], scene = "scene2"))
	before = _SciExportJSON.json(p)

	prepared = PlotlySupply._prepare_renderer_export(p, (background = :transparent,))
	data = _SciExportJSON.parse(prepared.data_js)
	layout = _SciExportJSON.parse(prepared.layout_js)
	uids = [trace["uid"] for trace in data]
	@test uids == ["t1", "t0", "t2"]
	@test allunique(uids)
	@test layout["paper_bgcolor"] == "rgba(0,0,0,0)"
	@test layout["plot_bgcolor"] == "rgba(0,0,0,0)"
	@test layout["scene2"]["bgcolor"] == "rgba(0,0,0,0)"
	@test _SciExportJSON.json(p) == before

	random = PlotlySupply._prepare_renderer_export(p, (deterministic = false,))
	@test [get(trace, "uid", nothing) for trace in _SciExportJSON.parse(random.data_js)] ==
		  [nothing, "t0", nothing]

	coloured = PlotlySupply._prepare_renderer_export(p, (background = "black",))
	coloured_layout = _SciExportJSON.parse(coloured.layout_js)
	@test coloured_layout["paper_bgcolor"] == "black"
	@test !haskey(coloured_layout, "scene2")
	@test _SciExportJSON.json(p) == before
end

@testset "sci export: HTML is inert and NaN-safe" begin
	hostile = "</script><script>window.__pwned = 1</script><!--<script>"
	p = Plot(
		scatter(x = [1.0, NaN, 3.0], y = [1.0, Inf, -Inf], name = hostile),
		Layout(title = hostile, width = 400, height = 300),
	)
	page = String(savefig(p; format = "html"))
	@test occursin("<!DOCTYPE html>", page)
	# The page embeds plotly.js (the patched renderer of desktop plots and
	# image exports, with its license notice) instead of loading it from the
	# CDN. Everything else on the page is checked without that library text,
	# which legitimately contains "NaN", "Infinity" and "plotlyServerURL".
	library = PlotlySupply._compatible_plotlyjs_inline_script()
	@test count(library, page) == 1
	@test !occursin(PlotlySupply._PLOTLY_CDN_URL, page)
	@test occursin(PlotlySupply._PLOTLYJS_MATH_FONT_REPLACEMENT, library)
	@test occursin(read(joinpath(dirname(PlotlySupply._plotlyjs_asset_path()), "LICENSE"), String), library)
	html = replace(page, library => "<script>/* plotly.js */</script>"; count = 1)
	@test !occursin("__pwned = 1</script>", html)
	@test !occursin("<!--<script>", html)
	@test !occursin("NaN", html)
	@test !occursin("Infinity", html)
	# Exactly the template's five script elements (PlotlyConfig, MathJax
	# config, MathJax, plotly.js, newPlot), each closed once.
	@test length(collect(eachmatch(r"<script\b", html))) == 5
	@test length(collect(eachmatch(r"</script>", html))) == 5
	@test occursin("mathjax/2.7.9/MathJax.js", html)
	@test occursin("SVG: {font: \"Latin-Modern\"}", html)
	@test occursin("width:400.0px", html) && occursin("height:300.0px", html)
	@test occursin("""id="$(p.divid)\"""", html)
	@test !occursin("plotlyServerURL", html)

	# The escaped JSON decodes to the original strings.
	@test _SciExportJSON.parse(PlotlySupply._json_html(Dict("t" => hostile)))["t"] == hostile
	@test PlotlySupply._json_html([1.0, NaN, Inf]) == "[1.0,null,null]"
	@test PlotlySupply._json_html("a b&") == "\"a\\u2028b\\u0026\""

	withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => "TeX") do
		@test occursin("SVG: {font: \"TeX\"}", String(savefig(p; format = "html")))
	end
	withenv("PLOTLYSUPPLY_MATHJAX_SVG_FONT" => "bad\"font") do
		@test_throws ErrorException savefig(p; format = "html")
	end
	@test_throws ArgumentError PlotlySupply._mathjax_config_script("x\"); alert(1); (\"")
	@test_throws ArgumentError PlotlySupply._export_window_html("bad id")
	@test occursin("MathJax.js", PlotlySupply._mathjax_head_html("STIX-Web"))

	unsized = String(savefig(_sci_plot(); format = "html"))
	@test occursin("height:100%; width:100%", unsized)

	framed = _sci_plot()
	push!(framed.frames, PlotlyBase.frame(name = "f1", data = [attr(y = [3.0, 2.0, 1.0])]))
	framed_html = String(savefig(framed; format = "html"))
	@test occursin("Plotly.addFrames", framed_html)

	clear = String(savefig(_sci_plot(); format = "html", background = :transparent))
	@test occursin("rgba(0,0,0,0)", clear)
	@test_throws ArgumentError savefig(_sci_plot(); format = "html", width = -1)
	@test_throws ArgumentError savefig(_sci_plot(); format = "html", unknown_option = 1)

	linked = _sci_plot()
	linked.config.showLink = true
	@test occursin("window.PLOTLYENV.BASE_URL = \"https://plot.ly\"", String(savefig(linked; format = "html")))
end

@testset "sci export: JSON is valid and NaN-safe" begin
	finite = _sci_plot()
	@test String(savefig(finite; format = "json")) == _SciExportJSON.json(finite)

	p = Plot(scatter(x = [1.0, NaN, 3.0], y = [Inf, 2.0, -Inf]))
	parsed = _SciExportJSON.parse(String(savefig(p; format = "json")))
	@test parsed["data"][1]["x"] == [1.0, nothing, 3.0]
	@test parsed["data"][1]["y"] == [nothing, 2.0, nothing]

	coloured = _SciExportJSON.parse(String(savefig(finite; format = "json", background = "#123456")))
	@test coloured["layout"]["paper_bgcolor"] == "#123456"
	@test get(finite.layout.fields, :paper_bgcolor, nothing) != "#123456"

	mktempdir() do dir
		sync = SyncPlot(p, nothing, nothing, "headless-json")
		target = joinpath(dir, "sync.json")
		@test PlotlyBase.savejson(sync, target) === sync.plot
		@test _SciExportJSON.parse(read(target, String))["data"][1]["x"] == [1.0, nothing, 3.0]
		@test_throws ArgumentError PlotlyBase.savejson(sync, joinpath(dir, "sync.txt"))
	end
end

@testset "sci export: files are published like ordinary writes" begin
	p = _sci_plot()
	mktempdir() do dir
		reference = joinpath(dir, "reference.txt")
		write(reference, "x")
		target = joinpath(dir, "figure.json")
		@test savefig(target, p) == target
		@test filemode(target) & 0o777 == filemode(reference) & 0o777

		chmod(target, 0o640)
		savefig(p, target)
		@test filemode(target) & 0o777 == 0o640
		@test sort(readdir(dir)) == ["figure.json", "reference.txt"]

		real = joinpath(dir, "real.json")
		write(real, "old")
		link = joinpath(dir, "link.json")
		symlink(real, link)
		savefig(p, link)
		@test islink(link)
		@test readlink(link) == real
		@test startswith(read(real, String), "{")

		dangling = joinpath(dir, "dangling.json")
		symlink(joinpath(dir, "created.json"), dangling)
		savefig(p, dangling)
		@test islink(dangling)
		@test isfile(joinpath(dir, "created.json"))

		relative = joinpath(dir, "relative.json")
		symlink("real.json", relative)
		write(real, "old")
		savefig(p, relative)
		@test startswith(read(real, String), "{")

		loop_a = joinpath(dir, "loop_a.json")
		loop_b = joinpath(dir, "loop_b.json")
		symlink(loop_b, loop_a)
		symlink(loop_a, loop_b)
		@test_throws ArgumentError savefig(p, loop_a)

		@test_throws ArgumentError savefig(p, joinpath(dir, "missing", "figure.json"))
		mkdir(joinpath(dir, "folder.json"))
		@test_throws ArgumentError savefig(p, joinpath(dir, "folder.json"))
		mkfifo = Sys.which("mkfifo")
		if mkfifo !== nothing
			fifo = joinpath(dir, "fifo.json")
			run(`$mkfifo $fifo`)
			@test_throws ArgumentError savefig(p, fifo)
		end
		@test !any(name -> startswith(name, "jl_"), readdir(dir))
	end
end

@testset "sci export: several files in one call" begin
	p = _sci_plot()
	mktempdir() do dir
		names = [joinpath(dir, "a.json"), joinpath(dir, "a.html")]
		@test savefig(p, names) == names
		@test startswith(read(names[1], String), "{")
		@test occursin("<!DOCTYPE html>", read(names[2], String))
		sf = PlotlySupply.subplots(1, 1; sync = false, show = false)
		sf_names = [joinpath(dir, "sf.json")]
		@test savefig(sf, sf_names) == sf_names

		untouched = joinpath(dir, "keep.json")
		write(untouched, "sentinel")
		for bad in (
			(String[], (;)),
			([untouched, untouched], (;)),
			([untouched, joinpath(dir, ".", "keep.json")], (;)),
			([untouched, 42], (;)),
			([untouched], (format = "json",)),
			([untouched, joinpath(dir, "missing", "x.json")], (;)),
			([untouched], (width = -1,)),
		)
			names_bad, kwargs = bad
			@test_throws ArgumentError savefig(p, names_bad; kwargs...)
			@test read(untouched, String) == "sentinel"
		end
		@test_throws ErrorException savefig(p, [untouched, joinpath(dir, "x.bmp")])
		@test read(untouched, String) == "sentinel"
		mktempdir() do empty_path
			withenv("PATH" => empty_path) do
				@test_throws ArgumentError savefig(p, [untouched, joinpath(dir, "x.eps")])
			end
		end
		@test read(untouched, String) == "sentinel"
		@test !isfile(joinpath(dir, "x.eps"))
	end
end

@testset "sci export: concatenated SyncPlots inherit window options" begin
	spec(show, autoplay, timeout) =
		PlotlySupply._SyncPlotCreationSpec(800, 600, "t", show, autoplay, timeout)
	headless(s) = SyncPlot(
		_sci_plot(),
		nothing,
		nothing,
		"concat",
		PlotlySupply._SyncPlotResources(nothing, nothing, s),
	)
	hidden = headless(spec(false, false, 5.0))
	shown = headless(spec(true, true, 20.0))
	unknown = SyncPlot(_sci_plot(), nothing, nothing, "unknown")
	@test PlotlySupply._syncplot_concat_window_options((hidden, unknown)) ==
		  (show = false, autoplay = false, timeout_s = 5.0)
	@test PlotlySupply._syncplot_concat_window_options((hidden, shown)) ==
		  (show = true, autoplay = true, timeout_s = 20.0)
	@test PlotlySupply._syncplot_concat_window_options((unknown,)) == NamedTuple()
end

# ── 2.0 wave 4 (math-export): exact sizes, TIFF, fonts, EPS ─────────

@testset "sci export: raster pixel counts round, never truncate (G17)" begin
	# 6.35 cm (2.5 in) at 300 dpi is 749.9999999999999 CSS px * scale; the
	# canvas used to truncate it to 749.
	for (dpi, pixels) in ((300, 750), (600, 1500), (1200, 3000))
		value = PlotlySupply._physical_to_px(6.35, :cm) * (dpi / 96)
		@test value < pixels && trunc(Int, value) == pixels - 1
		@test PlotlySupply._raster_pixels(PlotlySupply._physical_to_px(6.35, :cm), dpi / 96) == pixels
	end
	@test PlotlySupply._raster_pixels(PlotlySupply._physical_to_px(8.89, :cm), 300 / 96) == 1050
	@test PlotlySupply._raster_pixels(10.5, 1) == 11      # halves round up
	@test PlotlySupply._raster_pixels(10.49, 1) == 10
	@test PlotlySupply._raster_pixels(0.3, 1) == 1        # at least one pixel
	@test_throws ArgumentError PlotlySupply._raster_pixels(NaN, 1)
	@test_throws ArgumentError PlotlySupply._raster_pixels(10, -1)
	# Journal widths at 300/600/1200 dpi: round(width_in * dpi) pixels.
	for (width, units) in ((3.5, :in), (7.16, :in), (88, :mm), (180, :mm)), dpi in (300, 600, 1200)
		o = _sci_options(_sci_plot(); width = width, height = 0.75 * width, units = units, dpi = dpi)
		inches = width / PlotlySupply._export_units_per_inch(units, "test")
		@test PlotlySupply._format_pixels(o, "png")[1] == round(Int, inches * dpi)
		@test PlotlySupply._format_pixels(o, "tiff")[1] == round(Int, inches * dpi)
		@test PlotlySupply._format_dpi(o, "png") == dpi
		@test PlotlySupply._format_dpi(o, "svg") === nothing
	end
end

@testset "sci export: TIFF format, resolution and font options" begin
	@test PlotlySupply._validate_export_format("tif") == "tiff"
	@test PlotlySupply._validate_export_format("TIFF") == "tiff"
	@test PlotlySupply._filename_export_format("figure.TIF", nothing) == "tiff"
	@test PlotlySupply._filename_export_format("figure.tiff", nothing) == "tiff"
	@test_throws ErrorException PlotlySupply._validate_export_format("bmp")

	p = _sci_plot()
	o = _sci_options(p)
	@test o.fonts === :auto && o.units === :px && !o.scale_given
	# A TIFF without dpi or scale is drawn at 300 dpi; png keeps scale 1 and,
	# for a pixel size, records no resolution (as in 1.x).
	@test PlotlySupply._format_scale(o, "tiff") == 300 / 96
	@test PlotlySupply._format_dpi(o, "tiff") == 300.0
	@test PlotlySupply._format_pixels(o, "tiff") == (2188, 1563)   # 700 x 500 px at 300/96
	@test PlotlySupply._format_scale(o, "png") == 1.0
	@test PlotlySupply._format_dpi(o, "png") === nothing
	scaled = _sci_options(p; scale = 2)
	@test scaled.scale_given
	@test PlotlySupply._format_scale(scaled, "tiff") == 2.0
	@test PlotlySupply._format_dpi(scaled, "tiff") == 192.0
	@test PlotlySupply._format_dpi(scaled, "png") === nothing
	# A physical size records 96 * scale dpi in png/jpeg too.
	physical = _sci_options(p; width = 3.5, height = 2.5, units = :in, scale = 2)
	@test PlotlySupply._format_dpi(physical, "png") == 192.0
	@test PlotlySupply._format_dpi(physical, "jpeg") == 192.0
	@test PlotlySupply._format_pixels(physical, "png") == (672, 480)

	@test _sci_options(p; fonts = :outline).fonts === :outline
	@test _sci_options(p; fonts = :embed).fonts === :embed
	for bad in (:type3, "outline", true, 1)
		err = try
			_sci_options(p; fonts = bad)
			nothing
		catch caught
			caught
		end
		@test err isa ArgumentError
		@test startswith(sprint(showerror, err), "ArgumentError: savefig: `fonts` must be :auto, :embed or :outline")
	end
	# Without the publication style's accessor (or under the default style)
	# a figure without a size exports at the 1.x default.
	@test PlotlySupply._export_default_size() == (700.0, 500.0)
	if isdefined(PlotlySupply, :_style_default_figure_size) && isdefined(PlotlySupply, :with_style)
		# With the publication-style accessor merged: a figure without a
		# layout size exports at the active style's default size (D14).
		unsized = _sci_plot()
		@test !haskey(unsized.layout.fields, :width)
		PlotlySupply.with_style(:ieee) do
			expected = PlotlySupply._style_default_figure_size()
			@test expected != (700.0, 500.0)
			@test PlotlySupply._export_default_size() == expected
			@test (_sci_options(unsized).width, _sci_options(unsized).height) == expected
			@test _sci_options(unsized; width = 300).width == 300.0
		end
	end
	mktempdir() do dir
		withenv("PATH" => dir) do
			# Outlined PDF text needs Ghostscript; rejected before rendering.
			@test_throws ArgumentError savefig(p; format = "pdf", fonts = :outline)
			@test_throws ArgumentError savefig(p, joinpath(dir, "x.pdf"); fonts = :outline)
			@test !isfile(joinpath(dir, "x.pdf"))
		end
	end
end

# A zlib stream of stored (uncompressed) DEFLATE blocks.
function _sci_zlib_stored(data::Vector{UInt8}; block::Int = 65_535)
	out = UInt8[0x78, 0x01]
	chunks = isempty(data) ? [UInt8[]] : [data[i:min(end, i + block - 1)] for i in 1:block:length(data)]
	for (k, chunk) in enumerate(chunks)
		push!(out, k == length(chunks) ? 0x01 : 0x00)
		n = length(chunk)
		append!(out, UInt8[n & 0xff, n >> 8, ~n & 0xff, (~n >> 8) & 0xff])
		append!(out, chunk)
	end
	return vcat(out, _sci_u32(PlotlySupply._adler32(data)))
end

# Pseudo-random text over a skewed alphabet (zvec2.py's generator); zlib
# level 9 compresses it with one dynamic-Huffman block.
function _sci_skewed_text()
	alphabet = codeunits("eeeeeeeetttttaaaaooooiinnsshrdlu  ")
	state = 12345
	out = UInt8[]
	for _ in 1:600
		state = (1103515245 * state + 12345) % (1 << 31)
		push!(out, alphabet[state % length(alphabet) + 1])
	end
	return out
end

@testset "sci export: zlib inflate (fixed, dynamic, stored blocks)" begin
	# Produced by CPython's zlib 1.3 (level 9; Z_FIXED for the first).
	fixed_data = vcat(UInt8[(i * 7 + i ÷ 13) % 256 for i in 0:199], repeat(codeunits("PlotlySupply "), 12))
	fixed_z = hex2bytes(
		"78016360e7139551d632b4b077f30d8949ce2aaca86feb9d327bd1ca0d3bf61f3b7be5f6a3971fbeff63e511" *
		"9156d23430b773f5098e4acc2828af6bed993c6be18af5dbf61e3973f9d6c317efbffd65e1169254d0d037b375" *
		"f10e8a4c48cf2bad69e99e3473c1f2755bf71c3e75f1c683e7efbefe61e612949057d335b171f60a8c884fcb2d" *
		"a96eea9c3063feb2b55b761f3a79e1fabda76fbefc66e214109753d531b672f408088f4bcd29ae6aece89f3677" *
		"c99acdbb0e9e387fedee93d79f7e3270f08bc9aa681b593ab8fb85c6a46417553604e4e497e45406971614e454" *
		"2a0c320e00b1cd9d11",
	)
	dynamic_data = _sci_skewed_text()
	dynamic_z = hex2bytes(
		"78da2591010a04310803bfe2d784062a14054dff7fe9dec242ab5627660cc5743f8e3c5996748fcd153b7c3677" *
		"3bab89d55330368071380878a070bd46d9bc47b7f2787d6ed130bb41752bdd0f90d8009dffa7a9e8227a8201c3" *
		"9b0195624c4f95afba318a66adf2d498d42b2e4e7374abe4ad10c987129ca18dbabaf5726592b32443baaaba10" *
		"152cba8d85c7b99aa011e275325e3f8acb4b7847bdd263292b4cdb1aa4746d3a3e2afd9a2e7141681d3e62b32d" *
		"b230d5cf85693ffeeab454e01a8f544b39f3a2247e79f615999597e866a4fabed25a93bd0fec0a83fd78c2dfb1" *
		"ac5269a95b7226b4871a1da820a39e36711c41f18e0469f6b8fa9f9087c463abf3362e1aa9789ea9dbeb6cd5a2" *
		"b4cf117dda45433e4ff8e799598a4d3b35cd71e93d91722c2df20b673da572ff1dfee6751df9ddcf291ffc00ff" *
		"13f163",
	)
	@test (fixed_z[3] >> 1) & 0x03 == 0x01      # BTYPE 01: fixed Huffman
	@test (dynamic_z[3] >> 1) & 0x03 == 0x02    # BTYPE 10: dynamic Huffman
	@test PlotlySupply._adler32(dynamic_data) == 0xff13f163
	@test PlotlySupply._inflate_zlib(fixed_z) == fixed_data
	@test PlotlySupply._inflate_zlib(dynamic_z) == dynamic_data
	@test PlotlySupply._inflate_zlib(dynamic_z; expected = 600) == dynamic_data
	for data in (UInt8[], UInt8[0x41], UInt8[(i % 251) for i in 1:150_000])
		@test PlotlySupply._inflate_zlib(_sci_zlib_stored(data)) == data
	end

	inflate_error(bytes; kwargs...) =
		try
			PlotlySupply._inflate_zlib(bytes; kwargs...)
			nothing
		catch err
			err
		end
	@test inflate_error(dynamic_z[1:(end - 30)]) isa ArgumentError                    # truncated
	@test inflate_error(vcat(dynamic_z[1:(end - 1)], dynamic_z[end] ⊻ 0x01)) isa ArgumentError   # Adler-32
	@test occursin("expected 599", sprint(showerror, inflate_error(dynamic_z; expected = 599)))
	@test inflate_error(vcat(UInt8[0x78, 0x9d], dynamic_z[3:end])) isa ArgumentError    # header check
	@test inflate_error(UInt8[0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x00]) isa ArgumentError   # BTYPE 11
end

# PNG scanline filters (PNG spec §9), applied by the test so `_png_decode`
# is checked against an independent encoder.
function _sci_png_filter(kind::Int, row::Vector{UInt8}, prior::Vector{UInt8}, bpp::Int)
	out = similar(row)
	for k in eachindex(row)
		a = k > bpp ? Int(row[k - bpp]) : 0
		b = Int(prior[k])
		c = k > bpp ? Int(prior[k - bpp]) : 0
		predictor = kind == 0 ? 0 : kind == 1 ? a : kind == 2 ? b : kind == 3 ? (a + b) ÷ 2 :
			(p = a + b - c; pa = abs(p - a); pb = abs(p - b); pc = abs(p - c);
			 pa <= pb && pa <= pc ? a : pb <= pc ? b : c)
		out[k] = (Int(row[k]) - predictor) % UInt8
	end
	return out
end

function _sci_encode_png(width::Int, height::Int, channels::Int, pixels::Vector{UInt8})
	stride = width * channels
	raw = UInt8[]
	prior = zeros(UInt8, stride)
	for y in 0:(height - 1)
		row = pixels[(y * stride + 1):((y + 1) * stride)]
		kind = y % 5   # every filter type
		push!(raw, UInt8(kind))
		append!(raw, _sci_png_filter(kind, row, prior, channels))
		prior = row
	end
	ihdr = vcat(_sci_u32(width), _sci_u32(height), UInt8[8, channels == 4 ? 6 : 2, 0, 0, 0])
	return vcat(
		UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
		_sci_png_chunk("IHDR", ihdr),
		_sci_png_chunk("IDAT", _sci_zlib_stored(raw)),
		_sci_png_chunk("IEND", UInt8[]),
	)
end

@testset "sci export: PNG decoding (all five filters)" begin
	for (width, height, channels) in ((1, 1, 4), (7, 11, 4), (13, 10, 3))
		pixels = UInt8[(i * 37 + i ÷ 5) % 256 for i in 1:(width * height * channels)]
		png = _sci_encode_png(width, height, channels, pixels)
		@test PlotlySupply._png_size(png) == (width, height)
		@test PlotlySupply._png_decode(png) == (width, height, channels, pixels)
	end
	@test_throws ArgumentError PlotlySupply._png_decode(UInt8[0x01, 0x02])
	@test_throws ArgumentError PlotlySupply._png_size(UInt8[0x01, 0x02])
	png = _sci_encode_png(2, 2, 4, zeros(UInt8, 16))
	@test_throws ArgumentError PlotlySupply._png_decode(png[1:(end - 20)])   # truncated
	sixteen_bit = copy(png)
	sixteen_bit[25] = 16   # IHDR bit depth (CRC not rechecked by the decoder)
	@test_throws ArgumentError PlotlySupply._png_decode(sixteen_bit)
end

# TIFF 6.0 LZW decoding as libtiff does it (codes MSB-first, Clear = 256,
# EOI = 257, width grows one code early), written independently of the
# encoder.
function _sci_lzw_decode(bytes::Vector{UInt8})
	out = UInt8[]
	table = Vector{Vector{UInt8}}()
	reset!() = (empty!(table); foreach(i -> push!(table, UInt8[i]), 0:255); push!(table, UInt8[], UInt8[]))
	reset!()
	nbits, bitpos = 9, 0
	previous = UInt8[]
	function next_code()
		code = 0
		for _ in 1:nbits
			byte = bytes[bitpos ÷ 8 + 1]
			code = (code << 1) | ((byte >> (7 - bitpos % 8)) & 0x01)
			bitpos += 1
		end
		return code
	end
	while true
		code = next_code()
		if code == 256
			reset!()
			nbits = 9
			previous = UInt8[]
			continue
		end
		code == 257 && break
		if isempty(previous)
			entry = copy(table[code + 1])
		else
			entry = code < length(table) ? copy(table[code + 1]) :
				code == length(table) ? vcat(previous, previous[1]) : error("bad LZW code $code")
			push!(table, vcat(previous, entry[1]))
		end
		append!(out, entry)
		previous = entry
		length(table) + 1 >= (1 << nbits) && nbits < 12 && (nbits += 1)
	end
	return out
end

# (tag => (type, count, value-or-offset)) of the first IFD of a little-endian TIFF.
function _sci_tiff_tags(bytes::Vector{UInt8})
	u16(i) = Int(bytes[i]) | Int(bytes[i + 1]) << 8
	u32(i) = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
	@assert bytes[1:4] == UInt8['I', 'I', 42, 0]
	ifd = u32(5)
	tags = Dict{Int,Tuple{Int,Int,Int}}()
	for k in 0:(u16(ifd + 1) - 1)
		entry = ifd + 3 + 12k
		tags[u16(entry)] = (u16(entry + 2), u32(entry + 4), u32(entry + 8))
	end
	return tags, u16, u32
end

function _sci_tiff_pixels(bytes::Vector{UInt8})
	tags, u16, u32 = _sci_tiff_tags(bytes)
	n = tags[273][2]
	offsets = n == 1 ? [tags[273][3]] : [u32(tags[273][3] + 4k + 1) for k in 0:(n - 1)]
	counts = n == 1 ? [tags[279][3]] : [u32(tags[279][3] + 4k + 1) for k in 0:(n - 1)]
	return reduce(vcat, (_sci_lzw_decode(bytes[(o + 1):(o + c)]) for (o, c) in zip(offsets, counts)))
end

# Deterministic pseudo-random bytes (64-bit LCG, high bits).
function _sci_noise(n::Int; seed::UInt64 = 0x2545f4914f6cdd1d)
	state = seed
	out = Vector{UInt8}(undef, n)
	for i in 1:n
		state = state * 0x5851f42d4c957f2d + 0x14057b7ef767814f
		out[i] = UInt8(state >> 56)
	end
	return out
end

@testset "sci export: TIFF writer (baseline, LZW, resolution)" begin
	# Long runs, noise (12-bit codes and several table resets in one strip)
	# and a single byte.
	for data in (repeat(UInt8[0xff, 0xff, 0xff, 0x20, 0x40, 0x60], 5_000), _sci_noise(60_000), UInt8[0x07])
		@test _sci_lzw_decode(PlotlySupply._tiff_lzw_encode(data)) == data
	end
	noise = _sci_noise(97 * 41 * 3; seed = UInt64(7))
	tiff = PlotlySupply._tiff_encode(97, 41, 3, noise, 600)
	tags, u16, u32 = _sci_tiff_tags(tiff)
	@test tags[256][3] == 97 && tags[257][3] == 41
	@test tags[259][3] == 5           # LZW
	@test tags[262][3] == 2           # RGB
	@test tags[277][3] == 3           # samples per pixel
	@test [u16(tags[258][3] + 1 + 2k) for k in 0:2] == [8, 8, 8]
	@test tags[296][3] == 2           # inch
	for tag in (282, 283)
		@test (tags[tag][1], u32(tags[tag][3] + 1) / u32(tags[tag][3] + 5)) == (5, 600.0)
	end
	@test !haskey(tags, 338)
	@test _sci_tiff_pixels(tiff) == noise
	@test PlotlySupply._tiff_encode(97, 41, 3, noise, 600) == tiff   # deterministic

	# RGBA: opaque images are written as RGB; translucent ones keep an
	# unassociated alpha sample.
	opaque = vcat((UInt8[r, g, 0x10, 0xff] for r in 0x00:0x09 for g in 0x00:0x04)...)
	t_opaque = PlotlySupply._tiff_encode(10, 5, 4, opaque, 300)
	@test _sci_tiff_tags(t_opaque)[1][277][3] == 3
	@test _sci_tiff_pixels(t_opaque) == vcat((opaque[(4p + 1):(4p + 3)] for p in 0:49)...)
	translucent = copy(opaque)
	translucent[4] = 0x80
	t_alpha = PlotlySupply._tiff_encode(10, 5, 4, translucent, 254.5)
	tags_a, _, u32a = _sci_tiff_tags(t_alpha)
	@test tags_a[277][3] == 4 && tags_a[338][3] == 2
	@test u32a(tags_a[282][3] + 1) / u32a(tags_a[282][3] + 5) == 254.5
	@test _sci_tiff_pixels(t_alpha) == translucent

	@test_throws ArgumentError PlotlySupply._tiff_encode(0, 5, 3, UInt8[], 300)
	@test_throws ArgumentError PlotlySupply._tiff_encode(2, 2, 3, zeros(UInt8, 11), 300)
	@test_throws ArgumentError PlotlySupply._tiff_encode(2, 2, 2, zeros(UInt8, 8), 300)
	@test_throws ArgumentError PlotlySupply._tiff_encode(2, 2, 3, zeros(UInt8, 12), 0)
end

@testset "sci export: SVG physical size and canonical root" begin
	svg = """<svg class="main-svg" xmlns="http://www.w3.org/2000/svg" width="313.7007874015748" """ *
		  """height="226.77165354330708" style="" viewBox="0 0 313.7007874015748 226.77165354330708"><rect width="1"/></svg>"""
	cm = PlotlySupply._svg_set_physical_size(svg, 313.7007874015748, 226.77165354330708, :cm)
	@test occursin("""width="8.3cm" height="6cm" style=\"\" viewBox="0 0 313.7007874015748""", cm)
	@test endswith(cm, """><rect width="1"/></svg>""")      # only the root changes
	@test occursin("""width="252pt\"""", PlotlySupply._svg_set_physical_size(svg, 336, 240, :pt))
	@test occursin("""width="3.5in\"""", PlotlySupply._svg_set_physical_size(svg, 336, 240, :in))
	@test occursin("""height="63.5mm\"""", PlotlySupply._svg_set_physical_size(svg, 336, 240, :mm))
	@test PlotlySupply._svg_set_physical_size(svg, 336, 240, :px) == svg
	no_box = """<svg width="400" height="300"><g/></svg>"""
	@test PlotlySupply._svg_set_physical_size(no_box, 400, 300, :in) ==
		  """<svg width="4.166667in" height="3.125in" viewBox="0 0 400 300"><g/></svg>"""
	@test_throws ArgumentError PlotlySupply._svg_set_physical_size("<svg><g/></svg>", 400, 300, :in)

	# plotly.js does not always serialize the root attributes in one order.
	a = """<svg class="main-svg" xmlns="x" width="700" height="500" style="" viewBox="0 0 700 500"><g/></svg>"""
	b = """<svg class="main-svg" xmlns="x" width="700" height="500" viewBox="0 0 700 500" style=""><g/></svg>"""
	@test PlotlySupply._svg_canonical_root(a) == PlotlySupply._svg_canonical_root(b) == b
	@test PlotlySupply._svg_canonical_root("<svg><g/></svg>") == "<svg><g/></svg>"
	extra = """<svg data-x="1" class="c" width="2"><g/></svg>"""
	@test PlotlySupply._svg_canonical_root(extra) == """<svg class="c" width="2" data-x="1"><g/></svg>"""
end

@testset "sci export: EPS bounding box and Type 3 detection" begin
	eps = collect(codeunits(
		"%!PS-Adobe-3.0 EPSF-3.0\r\n%%BoundingBox: 7 10 200 127\r\n%%HiResBoundingBox: 7.50 10.50 199.80 126.50\n" *
		"%%Pages: 1\n%%EndComments\n%%BoundingBox: 1 2 3 4\nbody\n",
	))
	fixed = String(PlotlySupply._eps_set_bounding_box(eps, 249.4488188976378, 187.08661417322835))
	@test occursin("%%BoundingBox: 0 0 250 188\r\n", fixed)
	@test occursin("%%HiResBoundingBox: 0 0 249.4488 187.0866\n", fixed)
	@test occursin("%%EndComments\n%%BoundingBox: 1 2 3 4\nbody\n", fixed)   # header only
	@test occursin("%%BoundingBox: 0 0 252 180", String(PlotlySupply._eps_set_bounding_box(eps, 252, 180)))
	atend = collect(codeunits("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: (atend)\n%%EndComments\n"))
	@test_throws ErrorException PlotlySupply._eps_set_bounding_box(atend, 10, 10)
	@test_throws ArgumentError PlotlySupply._eps_set_bounding_box(eps, 0, 10)

	skia = collect(codeunits(
		"%PDF-1.4\n6 0 obj\n<</Type /Font\n/Subtype /Type3\n/FontDescriptor 21 0 R\n>>\nendobj\n" *
		"8 0 obj\n<</Type /Font\n/Subtype /Type0\n/BaseFont /AAAAAA+Verdana\n>>\nendobj\n" *
		"21 0 obj\n<</Type /FontDescriptor\n/FontName /AAAAAA+STIXGeneral-Regular\n>>\nendobj\n" *
		"30 0 obj\n<</Type/Font/Subtype/Type3/Name/F3>>\nendobj\n\xff\xfe binary\n",
	))
	@test PlotlySupply._pdf_type3_fonts(skia) == ["AAAAAA+STIXGeneral-Regular", "F3"]
	@test isempty(PlotlySupply._pdf_type3_fonts(collect(codeunits("<</Subtype /Type0>> /Type3x"))))
end

@testset "sci export: savefig documents fonts, TIFF and sizes (G22)" begin
	doc = string(@doc PlotlySupply.savefig)
	# The MathJax font is set with set_default_mathtext!(; font); the
	# environment variable is only the fallback (it used to be the only way
	# documented, with Latin-Modern as a fixed font).
	@test occursin("set_default_mathtext!", doc)
	@test occursin("PLOTLYSUPPLY_MATHJAX_SVG_FONT", doc)
	for font in PlotlySupply._MATHJAX_SVG_FONTS
		@test occursin("\"$(font)\"", doc)
	end
	@test occursin("\\mathcal", doc)
	for phrase in ("`\"tiff\"`", "fonts::Symbol = :auto", "Type 3", "XResolution/YResolution",
		"active style's default", "unwritable", "quality 0.92")
		@test occursin(phrase, doc)
	end
end

@testset "sci export: long renderer results arrive in slices" begin
	chunk = PlotlySupply._RENDERER_RESULT_CHUNK
	# A fake ElectronCall backend replying from a queue; scripts are recorded.
	function fake_backend(replies)
		scripts = String[]
		queue = Any[replies...]
		ec = (run = (win, js) -> (push!(scripts, String(js)); isempty(queue) ? error("no reply queued") : popfirst!(queue)),)
		return ec, scripts
	end
	fetch_error(total, replies) =
		try
			PlotlySupply._fetch_renderer_result(fake_backend(replies)[1], nothing, total, "svg")
			nothing
		catch err
			err
		end

	ec, scripts = fake_backend([Any["<svg>ab", false], Any["c</svg>", true]])
	@test PlotlySupply._fetch_renderer_result(ec, nothing, chunk + 1, "svg") == "<svg>abc</svg>"
	@test length(scripts) == 2 && all(==(PlotlySupply._FETCH_RESULT_SLICE_JS), scripts)
	# Malformed replies, a stalled transfer and bad lengths are errors.
	for (total, replies, needle) in (
		(chunk + 1, [Dict("error" => "the rendered image is no longer held")], "no longer held"),
		(chunk + 1, ["just a string"], "unexpected reply"),
		(chunk + 1, [Any["x", "yes"]], "unexpected reply"),
		(chunk + 1, [Any["", false]], "empty slice"),
		(chunk + 1, fill(Any["x", false], 10), "did not arrive in 3 slices"),
		(chunk, [], "invalid svg image length"),
		(chunk + 0.5, [], "invalid svg image length"),
		(true, [], "invalid svg image length"),
		("big", [], "invalid svg image length"),
	)
		err = fetch_error(total, replies)
		@test err isa ErrorException
		@test occursin(needle, sprint(showerror, err))
	end

	# The capture script hands a long result over by length; the markup is
	# then fetched and written as it is.
	prepared = PlotlySupply._prepare_renderer_export(_sci_plot(), (;))
	ec, scripts = fake_backend([
		Dict("resultLength" => chunk + 7),
		Any["<svg class=\"main-svg\">", false],
		Any["<g/></svg>", true],
	])
	markup = PlotlySupply._capture_image_data_url(ec, nothing, "export", prepared, "svg")
	@test markup == "<svg class=\"main-svg\"><g/></svg>"
	@test occursin("imageDataOnly: true", scripts[1])
	@test occursin("result.length <= $(chunk)", scripts[1])
	@test occursin("delete window.__plotlysupplyExportResult;", scripts[1])
	io = IOBuffer()
	PlotlySupply._write_image_data_url!(io, markup, "svg")
	@test String(take!(io)) == markup
	# A short result is returned directly, as before.
	ec, scripts = fake_backend(["<svg><g/></svg>"])
	@test PlotlySupply._capture_image_data_url(ec, nothing, "export", prepared, "svg") == "<svg><g/></svg>"
	@test length(scripts) == 1
end

@testset "sci export: unwritable destinations fail before rendering" begin
	p = _sci_plot()
	mktempdir() do dir
		locked = joinpath(dir, "locked")
		mkdir(locked)
		chmod(locked, 0o555)
		try
			# Skip where permissions are not enforced (e.g. running as root).
			probe = joinpath(locked, "probe")
			enforced = try
				touch(probe)
				rm(probe)
				false
			catch
				true
			end
			if enforced
				for target in (joinpath(locked, "x.json"), joinpath(locked, "x.png"))
					err = try
						savefig(p, target)
						nothing
					catch caught
						caught
					end
					@test err isa ArgumentError
					@test occursin("savefig: cannot write to the destination directory", sprint(showerror, err))
				end
				@test_throws ArgumentError savefig(p, [joinpath(dir, "ok.json"), joinpath(locked, "x.json")])
				@test !isfile(joinpath(dir, "ok.json"))
				@test isempty(readdir(locked))
			end
		finally
			chmod(locked, 0o755)
		end
	end
end
