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
	html = String(savefig(p; format = "html"))
	@test occursin("<!DOCTYPE html>", html)
	@test !occursin("__pwned = 1</script>", html)
	@test !occursin("<!--<script>", html)
	@test !occursin("NaN", html)
	@test !occursin("Infinity", html)
	# Exactly the template's five script elements (PlotlyConfig, MathJax
	# config, MathJax, plotly.js, newPlot), each closed once.
	@test length(collect(eachmatch(r"<script\b", html))) == 5
	@test length(collect(eachmatch(r"</script>", html))) == 5
	@test occursin(PlotlySupply._PLOTLY_CDN_URL, html)
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
