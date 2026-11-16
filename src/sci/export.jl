# PlotlySupply 2.0 scientific-plotting extensions: physical size / dpi, deterministic PDF and SVG bytes, EPS, multi-format export helpers.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_EXPORT_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# This file holds only pure byte/number helpers (no Electron, no figure
# mutation). The `savefig` plumbing that uses them lives in plotlyjs_compat.jl.

const _SCI_EXPORT_MUTATORS = ()

# ── Physical units ──────────────────────────────────────────────────

# The CSS reference pixel: 96 px per inch (CSS Values and Units, absolute
# lengths). Plotly lays figures out in CSS px and Chromium prints 96 px to the
# inch, so this is the conversion every physical export size goes through.
const _CSS_PX_PER_INCH = 96.0

# Inherent unit definitions: 1 in = 2.54 cm = 25.4 mm = 72 pt (PostScript/PDF
# point) = 96 px (CSS reference pixel).
function _export_units_per_inch(units::Symbol, who::AbstractString)
	units === :px && return _CSS_PX_PER_INCH
	units === :in && return 1.0
	units === :cm && return 2.54
	units === :mm && return 25.4
	units === :pt && return 72.0
	throw(ArgumentError(
		"$(who): unknown `units` $(repr(units)); use :px, :in, :cm, :mm or :pt.",
	))
end

"""
	_physical_to_px(v::Real, units::Symbol; who = "savefig") -> Float64

Convert a length `v` given in `units` (`:px`, `:in`, `:cm`, `:mm`, `:pt`) to
CSS pixels at 96 px/in. Non-finite or `Bool` values and unknown units throw
`ArgumentError` prefixed with `who`.
"""
function _physical_to_px(v::Real, units::Symbol; who::AbstractString = "savefig")::Float64
	per_inch = _export_units_per_inch(units, who)
	v isa Bool && throw(ArgumentError("$(who): a length must be a real number, not a Bool."))
	value = Float64(v)
	isfinite(value) || throw(ArgumentError("$(who): a length must be finite; got $(v)."))
	units === :px && return value
	return value * _CSS_PX_PER_INCH / per_inch
end

# ── CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) ─────────────
# PNG chunk checksums use this CRC (PNG spec §5.5). Base ships only CRC-32C,
# which uses a different polynomial, so the 256-entry table is built here.

const _CRC32_TABLE = let table = Vector{UInt32}(undef, 256)
	for n in 0:255
		c = UInt32(n)
		for _ in 1:8
			c = isodd(c) ? (0xedb88320 ⊻ (c >> 1)) : (c >> 1)
		end
		table[n + 1] = c
	end
	table
end

function _crc32(bytes::AbstractVector{UInt8}, crc::UInt32 = 0x00000000)
	c = ~crc
	@inbounds for byte in bytes
		c = _CRC32_TABLE[((c ⊻ byte) & 0xff) + 1] ⊻ (c >> 8)
	end
	return ~c
end

# ── PNG physical resolution (pHYs) ──────────────────────────────────

const _PNG_SIGNATURE = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
# PNG four-byte unsigned integers are limited to 0 .. 2^31 - 1 (PNG spec §7.1).
const _PNG_MAX_UINT = 0x7fffffff
# Upper bound for `dpi`: JPEG/JFIF stores the density as a 16-bit integer, and
# no output device comes close to this resolution.
const _EXPORT_MAX_DPI = 65535

_be_u32(x::Integer) = UInt8[(x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff]

function _read_be_u32(bytes::AbstractVector{UInt8}, i::Int)
	return (UInt32(bytes[i]) << 24) | (UInt32(bytes[i + 1]) << 16) |
		   (UInt32(bytes[i + 2]) << 8) | UInt32(bytes[i + 3])
end

function _validated_export_dpi(dpi, who::AbstractString)
	(dpi isa Real && !(dpi isa Bool)) ||
		throw(ArgumentError("$(who): `dpi` must be a positive real number; got $(repr(dpi))."))
	value = Float64(dpi)
	isfinite(value) && value > 0 ||
		throw(ArgumentError("$(who): `dpi` must be positive and finite; got $(dpi)."))
	value <= _EXPORT_MAX_DPI ||
		throw(ArgumentError("$(who): `dpi` must not exceed $(_EXPORT_MAX_DPI); got $(dpi)."))
	return value
end

"""
	_png_set_phys(bytes::Vector{UInt8}, dpi::Real) -> Vector{UInt8}

Return a copy of the PNG `bytes` whose `pHYs` chunk records `dpi` (stored as
`round(dpi / 0.0254)` pixels per metre, unit 1). Any existing `pHYs` chunk is
removed and the new one is placed right after `IHDR`, so it always precedes the
image data. Throws `ArgumentError` for a malformed PNG or an invalid `dpi`.
"""
function _png_set_phys(bytes::Vector{UInt8}, dpi::Real)::Vector{UInt8}
	value = _validated_export_dpi(dpi, "savefig")
	# 1 inch = 0.0254 m (inherent definition).
	ppm = round(Int64, value / 0.0254)
	1 <= ppm <= _PNG_MAX_UINT ||
		throw(ArgumentError("savefig: `dpi` $(dpi) cannot be stored in a PNG pHYs chunk."))
	n = length(bytes)
	n >= 8 && bytes[1:8] == _PNG_SIGNATURE ||
		throw(ArgumentError("savefig: the renderer did not return a PNG image."))

	chunks = Tuple{Int,Int}[]   # (start index, total chunk length) of every chunk
	i = 9
	seen_iend = false
	while i <= n
		i + 7 <= n || throw(ArgumentError("savefig: truncated PNG chunk header."))
		len = Int(_read_be_u32(bytes, i))
		total = 12 + len
		i + total - 1 <= n || throw(ArgumentError("savefig: truncated PNG chunk."))
		push!(chunks, (i, total))
		kind = @view bytes[(i + 4):(i + 7)]
		if kind == codeunits("IEND")
			seen_iend = true
			break
		end
		i += total
	end
	seen_iend || throw(ArgumentError("savefig: PNG image has no IEND chunk."))
	first_start, first_total = first(chunks)
	@view(bytes[(first_start + 4):(first_start + 7)]) == codeunits("IHDR") ||
		throw(ArgumentError("savefig: PNG image does not start with an IHDR chunk."))

	payload = vcat(collect(codeunits("pHYs")), _be_u32(ppm), _be_u32(ppm), UInt8[0x01])
	phys = vcat(_be_u32(9), payload, _be_u32(_crc32(payload)))

	out = UInt8[]
	sizehint!(out, n + length(phys))
	append!(out, @view bytes[1:8])
	for (k, (start, total)) in enumerate(chunks)
		kind = @view bytes[(start + 4):(start + 7)]
		kind == codeunits("pHYs") && continue
		append!(out, @view bytes[start:(start + total - 1)])
		k == 1 && append!(out, phys)
	end
	# Anything after IEND is not part of the PNG datastream; keep it verbatim
	# so the transformation never loses bytes.
	last_start, last_total = last(chunks)
	tail = last_start + last_total
	tail <= n && append!(out, @view bytes[tail:n])
	return out
end

# ── JPEG density (JFIF APP0) ────────────────────────────────────────

"""
	_jpeg_set_density(bytes::Vector{UInt8}, dpi::Real) -> Vector{UInt8}

Return a copy of the JPEG `bytes` whose JFIF APP0 segment records `dpi` (units
= dots per inch, X and Y density `round(dpi)`). A JFIF segment is inserted
after SOI when the stream has none.
"""
function _jpeg_set_density(bytes::Vector{UInt8}, dpi::Real)::Vector{UInt8}
	value = _validated_export_dpi(dpi, "savefig")
	density = clamp(round(Int, value), 1, _EXPORT_MAX_DPI)
	hi, lo = UInt8(density >> 8), UInt8(density & 0xff)
	length(bytes) >= 4 && bytes[1] == 0xff && bytes[2] == 0xd8 ||
		throw(ArgumentError("savefig: the renderer did not return a JPEG image."))
	out = copy(bytes)
	jfif = codeunits("JFIF\0")
	if length(out) >= 18 && out[3] == 0xff && out[4] == 0xe0 && @view(out[7:11]) == jfif
		out[14] = 0x01           # units: dots per inch
		out[15], out[16] = hi, lo  # X density
		out[17], out[18] = hi, lo  # Y density
		return out
	end
	segment = UInt8[
		0xff, 0xe0, 0x00, 0x10, jfif..., 0x01, 0x01, 0x01, hi, lo, hi, lo, 0x00, 0x00,
	]
	return vcat(out[1:2], segment, out[3:end])
end

# ── PDF post-processing ─────────────────────────────────────────────

function _find_bytes(haystack::AbstractVector{UInt8}, needle::AbstractVector{UInt8}, from::Int)
	m = length(needle)
	last_start = length(haystack) - m + 1
	i = from
	@inbounds while i <= last_start
		if haystack[i] == needle[1]
			matched = true
			for j in 2:m
				if haystack[i + j - 1] != needle[j]
					matched = false
					break
				end
			end
			matched && return i
		end
		i += 1
	end
	return nothing
end

_is_pdf_whitespace(b::UInt8) = b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09 || b == 0x0c || b == 0x00

# Characters of a PDF date string `D:YYYYMMDDHHmmSSOHH'mm'` (PDF 32000 §7.9.4).
_is_pdf_date_byte(b::UInt8) =
	(0x30 <= b <= 0x39) || b == UInt8('D') || b == UInt8(':') || b == UInt8('+') ||
	b == UInt8('-') || b == UInt8('Z') || b == UInt8('\'')

"""
	_pdf_blank_dates(bytes::Vector{UInt8}) -> Vector{UInt8}

Return a copy of the PDF `bytes` in which every `/CreationDate (D:…)` and
`/ModDate (D:…)` entry (key and value) is overwritten with spaces of the same
length. Byte offsets, and therefore the xref table, stay valid; only literal
strings made of PDF-date characters are touched.
"""
function _pdf_blank_dates(bytes::Vector{UInt8})::Vector{UInt8}
	out = copy(bytes)
	for key in (codeunits("/CreationDate"), codeunits("/ModDate"))
		i = 1
		while true
			start = _find_bytes(out, key, i)
			start === nothing && break
			j = start + length(key)
			while j <= length(out) && _is_pdf_whitespace(out[j])
				j += 1
			end
			if j <= length(out) && out[j] == UInt8('(')
				k = j + 1
				while k <= length(out) && k - j <= 64 && _is_pdf_date_byte(out[k])
					k += 1
				end
				if k <= length(out) && out[k] == UInt8(')') && k > j + 1
					fill!(@view(out[start:k]), 0x20)
					i = k + 1
					continue
				end
			end
			i = start + length(key)
		end
	end
	return out
end

function _parse_pdf_number(text::AbstractString)
	value = tryparse(Float64, text)
	value === nothing && return nothing
	isfinite(value) || return nothing
	return value
end

# Plain decimal (no exponent, which PDF number syntax does not allow) rounded
# to 1e-4 pt, far below Chromium's 1/300-in device unit.
function _format_pdf_number(x::Float64)
	scaled = round(Int64, x * 10_000)
	digits = lpad(string(abs(scaled)), 5, '0')
	integer_part = digits[1:(end - 4)]
	fraction = rstrip(digits[(end - 3):end], '0')
	text = isempty(fraction) ? integer_part : integer_part * "." * fraction
	return scaled < 0 ? "-" * text : text
end

# Parse the classic (non-stream) cross-reference table that `startxref` points
# to. Returns `(xref_start, startxref_digits_range, entries)` where `entries`
# holds the byte range of every in-use entry's 10-digit offset field, or
# `nothing` when the file uses an xref stream, incremental updates, or any
# layout this helper does not understand.
function _pdf_classic_xref(bytes::Vector{UInt8})
	n = length(bytes)
	marker = codeunits("startxref")
	pos = nothing
	i = 1
	while (found = _find_bytes(bytes, marker, i)) !== nothing
		pos = found
		i = found + 1
	end
	pos === nothing && return nothing
	j = pos + length(marker)
	while j <= n && _is_pdf_whitespace(bytes[j])
		j += 1
	end
	digits_start = j
	while j <= n && 0x30 <= bytes[j] <= 0x39
		j += 1
	end
	j == digits_start && return nothing
	digits_range = digits_start:(j - 1)
	xref_offset = parse(Int, String(bytes[digits_range]))
	xref_start = xref_offset + 1
	xref_start + 3 <= n && @view(bytes[xref_start:(xref_start + 3)]) == codeunits("xref") ||
		return nothing
	k = xref_start + 4
	entries = UnitRange{Int}[]
	while true
		while k <= n && _is_pdf_whitespace(bytes[k])
			k += 1
		end
		k > n && return nothing
		bytes[k] == UInt8('t') && break   # "trailer"
		line_end = k
		while line_end <= n && bytes[line_end] != 0x0a && bytes[line_end] != 0x0d
			line_end += 1
		end
		header = split(strip(String(bytes[k:(line_end - 1)])))
		length(header) == 2 || return nothing
		count = tryparse(Int, header[2])
		count === nothing && return nothing
		k = line_end
		while k <= n && (bytes[k] == 0x0a || bytes[k] == 0x0d)
			k += 1
		end
		for _ in 1:count
			k + 19 <= n || return nothing
			kind = bytes[k + 17]
			kind == UInt8('n') && push!(entries, k:(k + 9))
			kind == UInt8('n') || kind == UInt8('f') || return nothing
			k += 20
		end
	end
	trailer_end = _find_bytes(bytes, codeunits("startxref"), k)
	trailer_end === nothing && return nothing
	# An incremental update chains to an earlier xref section via /Prev.
	_find_bytes(@view(bytes[k:trailer_end]), codeunits("/Prev"), 1) === nothing ||
		return nothing
	return (xref_start, digits_range, entries)
end

"""
	_pdf_set_page_box(bytes::Vector{UInt8}, width_pt::Real, height_pt::Real) -> Vector{UInt8}

Chromium's printToPDF rounds the page size to whole 1/300-inch device units
(a 336 x 252 px page becomes 252 x 189.12 pt instead of 252 x 189 pt). Rewrite
every page `/MediaBox` that is within 1 pt of the requested `width_pt` x
`height_pt` so the page is exact, keeping the top-left corner (the figure is
drawn from the top-left, so only the blank sliver of the rounding is cut) and
fixing the cross-reference offsets. A PDF whose boxes already match, or whose
structure is not a single classic xref table, is returned unchanged.
"""
function _pdf_set_page_box(bytes::Vector{UInt8}, width_pt::Real, height_pt::Real)::Vector{UInt8}
	w = Float64(width_pt)
	h = Float64(height_pt)
	(isfinite(w) && w > 0 && isfinite(h) && h > 0) ||
		throw(ArgumentError("savefig: the PDF page size must be positive and finite."))
	# Chromium's rounding error is at most half a 1/300-in device unit
	# (0.12 pt); anything larger means the box is not the one we requested.
	tolerance = 1.0
	key = codeunits("/MediaBox")
	edits = Tuple{Int,Int,Vector{UInt8}}[]   # (first byte, last byte, replacement)
	i = 1
	while (start = _find_bytes(bytes, key, i)) !== nothing
		open_bracket = start + length(key)
		while open_bracket <= length(bytes) && _is_pdf_whitespace(bytes[open_bracket])
			open_bracket += 1
		end
		i = start + length(key)
		open_bracket <= length(bytes) && bytes[open_bracket] == UInt8('[') || continue
		close_bracket = open_bracket + 1
		while close_bracket <= length(bytes) && close_bracket - open_bracket <= 128 &&
			bytes[close_bracket] != UInt8(']')
			close_bracket += 1
		end
		close_bracket <= length(bytes) && bytes[close_bracket] == UInt8(']') || continue
		fields = split(String(bytes[(open_bracket + 1):(close_bracket - 1)]))
		length(fields) == 4 || continue
		values = map(_parse_pdf_number, fields)
		any(isnothing, values) && continue
		x0, y0, x1, y1 = values
		bw, bh = x1 - x0, y1 - y0
		abs(bw - w) <= tolerance && abs(bh - h) <= tolerance || continue
		abs(bw - w) < 1e-6 && abs(bh - h) < 1e-6 && continue
		box = "[" * join(_format_pdf_number.((x0, y1 - h, x0 + w, y1)), " ") * "]"
		push!(edits, (open_bracket, close_bracket, collect(codeunits(box))))
		i = close_bracket + 1
	end
	isempty(edits) && return copy(bytes)

	xref = _pdf_classic_xref(bytes)
	xref === nothing && return copy(bytes)
	xref_start, digits_range, entries = xref
	# Every edited box must lie in an object body, i.e. before the xref table.
	all(edit -> edit[2] < xref_start, edits) || return copy(bytes)

	# Growth of the file contributed by every edit that ends before byte `pos`.
	growth_before(pos) =
		sum((length(r) - (b - a + 1) for (a, b, r) in edits if b < pos); init = 0)
	total_growth = growth_before(length(bytes) + 1)

	out = UInt8[]
	sizehint!(out, length(bytes) + total_growth + 16)
	cursor = 1
	for (a, b, replacement) in edits
		append!(out, @view bytes[cursor:(a - 1)])
		append!(out, replacement)
		cursor = b + 1
	end
	append!(out, @view bytes[cursor:end])

	# xref entries hold 0-based byte offsets of object starts; an object that
	# starts after an edit moves by that edit's growth. The table itself lies
	# after every edit, so each entry's own position moves by `total_growth`.
	for range in entries
		old_offset = parse(Int, String(bytes[range]))
		new_offset = old_offset + growth_before(old_offset + 1)
		text = lpad(string(new_offset), 10, '0')
		length(text) == 10 || return copy(bytes)
		out[range .+ total_growth] = codeunits(text)
	end
	new_xref_offset = string(xref_start - 1 + total_growth)
	digits_out = digits_range .+ total_growth
	return vcat(
		out[1:(first(digits_out) - 1)],
		codeunits(new_xref_offset),
		out[(last(digits_out) + 1):end],
	)
end

# ── SVG ids ─────────────────────────────────────────────────────────

"""
	_svg_stable_ids(svg::String) -> String

plotly.js names the `<defs>`, clip paths and gradients of an exported SVG after
a random six-hex layout uid (`defs-1a2b3c`, `clip1a2b3cxy`, `g1a2b3c-cb…`).
Replace that uid with `000000` inside `id="…"` attributes and `#…` references
(`url(#…)`, `href="#…"`), so two exports of the same figure are
byte-identical. Text content is left untouched.
"""
function _svg_stable_ids(svg::String)::String
	m = match(r"<defs id=\"defs-([0-9a-f]{6})\"", svg)
	m === nothing && return svg
	uid = String(m.captures[1])
	uid == "000000" && return svg
	# An id attribute value, or the target of a url(#…) / href="#…" reference.
	token = r"(?:id=\"|url\(['\"]?#|href=\"#)[^\"'()\s<>]*"
	return replace(svg, token => t -> replace(t, uid => "000000"))
end

# ── EPS via Ghostscript ─────────────────────────────────────────────

const _GHOSTSCRIPT_CANDIDATES = Sys.iswindows() ? ("gswin64c", "gswin32c", "gs") : ("gs",)

"""
	_ghostscript_command() -> String

Path of the Ghostscript executable used for EPS export. Throws
`ArgumentError` with install guidance when Ghostscript is not on `PATH`.
"""
function _ghostscript_command()
	for name in _GHOSTSCRIPT_CANDIDATES
		path = Sys.which(name)
		path === nothing || return path
	end
	throw(ArgumentError(
		"savefig: EPS export needs Ghostscript (`gs`), which was not found on PATH. " *
		"Install it (macOS: `brew install ghostscript`; Debian/Ubuntu: " *
		"`apt install ghostscript`; Windows: https://ghostscript.com/releases/) " *
		"or export \"pdf\" or \"svg\" instead.",
	))
end

# Ghostscript expands `%d`-style page templates in -sOutputFile; a literal
# percent sign is written as `%%`.
_ghostscript_output_path(path::AbstractString) = replace(String(path), "%" => "%%")

"""
	_pdf_to_eps(pdf_path, eps_path; timeout_s = 300.0) -> eps_path

Convert a single-page PDF to EPS with Ghostscript's `eps2write` device:
`gs -q -dSAFER -dBATCH -dNOPAUSE -dNOTRANSPARENCY -sDEVICE=eps2write`.
`-dNOTRANSPARENCY` flattens translucent fills to opaque ones (EPS has no
transparency). A missing Ghostscript raises `ArgumentError`; a failed or
timed-out conversion raises an error carrying Ghostscript's stderr.
"""
function _pdf_to_eps(pdf_path::AbstractString, eps_path::AbstractString; timeout_s::Real = 300.0)
	gs = _ghostscript_command()
	isfile(pdf_path) || throw(ArgumentError("savefig: PDF input not found: $(repr(pdf_path))."))
	timeout = Float64(timeout_s)
	isfinite(timeout) && timeout > 0 ||
		throw(ArgumentError("savefig: the Ghostscript timeout must be positive and finite."))
	cmd = `$gs -q -dSAFER -dBATCH -dNOPAUSE -dNOTRANSPARENCY -sDEVICE=eps2write -sOutputFile=$(_ghostscript_output_path(eps_path)) $pdf_path`
	stdout_buffer = IOBuffer()
	stderr_buffer = IOBuffer()
	process = run(
		pipeline(ignorestatus(cmd); stdin = devnull, stdout = stdout_buffer, stderr = stderr_buffer);
		wait = false,
	)
	status = timedwait(() -> process_exited(process), timeout; pollint = 0.02)
	if status !== :ok
		# This is the Ghostscript child started just above (its Process handle),
		# not a matched or pre-existing process.
		kill(process)
		wait(process)
		error("savefig(eps): Ghostscript did not finish within $(timeout) s.")
	end
	wait(process)
	if !success(process)
		message = strip(String(take!(stderr_buffer)) * "\n" * String(take!(stdout_buffer)))
		error("savefig(eps): Ghostscript failed (exit code $(process.exitcode)): $(message)")
	end
	isfile(eps_path) && filesize(eps_path) > 0 ||
		error("savefig(eps): Ghostscript reported success but wrote no EPS output.")
	return eps_path
end

"""
	_eps_blank_dates(bytes::Vector{UInt8}) -> Vector{UInt8}

Return a copy of the EPS `bytes` whose `%%CreationDate:` DSC comment value is
replaced by spaces of the same length, so repeated exports are byte-identical.
"""
function _eps_blank_dates(bytes::Vector{UInt8})::Vector{UInt8}
	out = copy(bytes)
	key = codeunits("%%CreationDate:")
	i = 1
	while (start = _find_bytes(out, key, i)) !== nothing
		# DSC comments start a line.
		if start == 1 || out[start - 1] == 0x0a || out[start - 1] == 0x0d
			k = start + length(key)
			while k <= length(out) && out[k] != 0x0a && out[k] != 0x0d
				out[k] = 0x20
				k += 1
			end
			i = k
		else
			i = start + length(key)
		end
	end
	return out
end
