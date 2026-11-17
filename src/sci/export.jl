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

# ── Raster pixel counts ─────────────────────────────────────────────

"""
	_raster_pixels(css_px::Real, scale::Real) -> Int

Number of device pixels for a length of `css_px` CSS pixels drawn at `scale`
(`dpi / 96` for a `dpi` export): the nearest integer (halves round up), at least 1.
Rounding (not truncating) keeps a physical size exact to half a pixel, e.g.
6.35 cm (2.5 in) at 300 dpi is 750 px although `_physical_to_px(6.35, :cm) *
3.125` evaluates to 749.9999999999999.
"""
function _raster_pixels(css_px::Real, scale::Real)::Int
	value = Float64(css_px) * Float64(scale)
	isfinite(value) && value > 0 ||
		throw(ArgumentError("savefig: the raster size must be positive and finite; got $(value) px."))
	return max(1, round(Int, value, RoundNearestTiesUp))
end

# ── zlib / DEFLATE decoding (RFC 1950, RFC 1951) ────────────────────
# Used to read the PNG the renderer draws when the TIFF encoder needs its
# pixels. Base Julia ships no inflate implementation and the package takes no
# binary dependency for it.

mutable struct _InflateState
	data::Vector{UInt8}
	pos::Int            # next unread byte of `data`
	buf::UInt64         # bit buffer, least significant bit first
	nbits::Int          # valid bits in `buf` (including zero padding past the end)
	padding::Int        # zero bits appended after the last byte of `data`
end

@inline function _inflate_fill!(s::_InflateState, n::Int)
	while s.nbits < n
		if s.pos <= length(s.data)
			@inbounds s.buf |= UInt64(s.data[s.pos]) << s.nbits
			s.pos += 1
		else
			s.padding += 8
		end
		s.nbits += 8
	end
	return s
end

@inline function _inflate_drop!(s::_InflateState, n::Int)
	s.buf >>= n
	s.nbits -= n
	# Padding bits are the most significant bits of the buffer: consuming
	# into them means the stream ended early.
	s.nbits < s.padding && throw(ArgumentError("inflate: the compressed stream is truncated."))
	return s
end

@inline function _inflate_bits!(s::_InflateState, n::Int)::Int
	n == 0 && return 0
	_inflate_fill!(s, n)
	value = Int(s.buf & ((UInt64(1) << n) - 1))
	_inflate_drop!(s, n)
	return value
end

# Canonical Huffman code as a direct lookup table indexed by the next
# `maxlen` input bits (least significant bit first); entry = symbol << 4 | length,
# 0 for bit patterns no code uses.
struct _HuffmanTable
	lookup::Vector{UInt16}
	maxlen::Int
end

function _huffman_table(lengths::AbstractVector{<:Integer})
	maxlen = maximum(lengths; init = 0)
	maxlen <= 15 || throw(ArgumentError("inflate: Huffman code length above 15."))
	maxlen == 0 && return _HuffmanTable(UInt16[], 0)
	counts = zeros(Int, maxlen)
	for len in lengths
		len > 0 && (counts[len] += 1)
	end
	left = 1
	for len in 1:maxlen
		left = (left << 1) - counts[len]
		left < 0 && throw(ArgumentError("inflate: over-subscribed Huffman code."))
	end
	next_code = zeros(Int, maxlen)
	code = 0
	previous = 0
	for len in 1:maxlen
		code = (code + previous) << 1
		next_code[len] = code
		previous = counts[len]
	end
	size = 1 << maxlen
	lookup = zeros(UInt16, size)
	for (index, len) in enumerate(lengths)
		len == 0 && continue
		code = next_code[len]
		next_code[len] += 1
		reversed = 0
		for bit in 0:(len - 1)
			reversed |= ((code >> bit) & 1) << (len - 1 - bit)
		end
		entry = UInt16(((index - 1) << 4) | len)
		j = reversed
		while j < size
			@inbounds lookup[j + 1] = entry
			j += 1 << len
		end
	end
	return _HuffmanTable(lookup, maxlen)
end

@inline function _inflate_symbol!(s::_InflateState, table::_HuffmanTable)::Int
	table.maxlen == 0 && throw(ArgumentError("inflate: a code was read from an empty Huffman table."))
	_inflate_fill!(s, table.maxlen)
	@inbounds entry = table.lookup[Int(s.buf & ((UInt64(1) << table.maxlen) - 1)) + 1]
	len = Int(entry & 0x000f)
	len == 0 && throw(ArgumentError("inflate: invalid Huffman code in the compressed stream."))
	_inflate_drop!(s, len)
	return Int(entry >> 4)
end

const _INFLATE_LENGTH_BASE = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
	35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258)
const _INFLATE_LENGTH_EXTRA = (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
	3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0)
const _INFLATE_DIST_BASE = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
	257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577)
const _INFLATE_DIST_EXTRA = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
	7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13)
# Order of the code-length code lengths in a dynamic block header.
const _INFLATE_CLEN_ORDER = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15)

const _INFLATE_FIXED_LITERALS = _huffman_table(vcat(fill(8, 144), fill(9, 112), fill(7, 24), fill(8, 8)))
const _INFLATE_FIXED_DISTANCES = _huffman_table(fill(5, 30))

function _adler32(bytes::AbstractVector{UInt8})::UInt32
	a = UInt32(1)
	b = UInt32(0)
	n = length(bytes)
	i = 1
	# 5552 is the largest block for which b cannot overflow 32 bits before the
	# modulo (zlib's NMAX).
	@inbounds while i <= n
		stop = min(n, i + 5551)
		for k in i:stop
			a += bytes[k]
			b += a
		end
		a %= UInt32(65521)
		b %= UInt32(65521)
		i = stop + 1
	end
	return (b << 16) | a
end

function _inflate_dynamic_tables(s::_InflateState)
	nlit = _inflate_bits!(s, 5) + 257
	ndist = _inflate_bits!(s, 5) + 1
	nclen = _inflate_bits!(s, 4) + 4
	(nlit <= 286 && ndist <= 30) ||
		throw(ArgumentError("inflate: too many literal/length or distance codes."))
	clen = zeros(Int, 19)
	for k in 1:nclen
		clen[_INFLATE_CLEN_ORDER[k] + 1] = _inflate_bits!(s, 3)
	end
	clen_table = _huffman_table(clen)
	lengths = zeros(Int, nlit + ndist)
	k = 1
	while k <= nlit + ndist
		symbol = _inflate_symbol!(s, clen_table)
		if symbol < 16
			lengths[k] = symbol
			k += 1
			continue
		end
		value, repeat = if symbol == 16
			k == 1 && throw(ArgumentError("inflate: a length repeat has no previous length."))
			(lengths[k - 1], 3 + _inflate_bits!(s, 2))
		elseif symbol == 17
			(0, 3 + _inflate_bits!(s, 3))
		else
			(0, 11 + _inflate_bits!(s, 7))
		end
		k + repeat - 1 <= nlit + ndist ||
			throw(ArgumentError("inflate: code lengths overflow the header counts."))
		lengths[k:(k + repeat - 1)] .= value
		k += repeat
	end
	lengths[257] == 0 && throw(ArgumentError("inflate: the block has no end-of-block code."))
	return (_huffman_table(view(lengths, 1:nlit)), _huffman_table(view(lengths, (nlit + 1):(nlit + ndist))))
end

# Make room for `extra` more output bytes after the first `n`.
@inline function _inflate_reserve!(out::Vector{UInt8}, n::Int, extra::Int, expected::Int)
	if n + extra > length(out)
		expected >= 0 && throw(ArgumentError(
			"inflate: the stream holds more than the expected $(expected) bytes.",
		))
		resize!(out, max(2 * length(out), n + extra))
	end
	return out
end

"""
	_inflate_zlib(data::Vector{UInt8}; expected::Int = -1) -> Vector{UInt8}

Decompress a zlib stream (RFC 1950 wrapper around RFC 1951 DEFLATE data) and
verify its Adler-32 checksum. With `expected >= 0` the output must have exactly
that many bytes (it is preallocated). Malformed or truncated input raises
`ArgumentError`.
"""
function _inflate_zlib(data::Vector{UInt8}; expected::Int = -1)::Vector{UInt8}
	length(data) >= 6 || throw(ArgumentError("inflate: the zlib stream is too short."))
	cmf, flg = data[1], data[2]
	(cmf & 0x0f) == 8 && (cmf >> 4) <= 7 ||
		throw(ArgumentError("inflate: not a DEFLATE zlib stream."))
	((UInt16(cmf) << 8) | flg) % 31 == 0 || throw(ArgumentError("inflate: corrupt zlib header."))
	(flg & 0x20) == 0 || throw(ArgumentError("inflate: zlib preset dictionaries are not supported."))
	s = _InflateState(data, 3, UInt64(0), 0, 0)
	out = Vector{UInt8}(undef, expected >= 0 ? expected : max(1024, 4 * length(data)))
	n = 0   # bytes written
	final = false
	while !final
		final = _inflate_bits!(s, 1) == 1
		kind = _inflate_bits!(s, 2)
		if kind == 0
			_inflate_drop!(s, s.nbits % 8)
			len = _inflate_bits!(s, 16)
			nlen = _inflate_bits!(s, 16)
			len == (~nlen & 0xffff) || throw(ArgumentError("inflate: corrupt stored block length."))
			_inflate_reserve!(out, n, len, expected)
			for _ in 1:len
				# Whole bytes left in the bit buffer come first, then the input.
				if s.nbits >= 8
					n += 1
					@inbounds out[n] = UInt8(_inflate_bits!(s, 8))
				else
					s.pos <= length(data) || throw(ArgumentError("inflate: the compressed stream is truncated."))
					n += 1
					@inbounds out[n] = data[s.pos]
					s.pos += 1
				end
			end
			continue
		end
		kind == 3 && throw(ArgumentError("inflate: invalid block type."))
		literals, distances = kind == 1 ?
			(_INFLATE_FIXED_LITERALS, _INFLATE_FIXED_DISTANCES) : _inflate_dynamic_tables(s)
		while true
			symbol = _inflate_symbol!(s, literals)
			if symbol < 256
				_inflate_reserve!(out, n, 1, expected)
				n += 1
				@inbounds out[n] = UInt8(symbol)
				continue
			end
			symbol == 256 && break
			symbol <= 285 || throw(ArgumentError("inflate: invalid length code."))
			index = symbol - 256
			len = _INFLATE_LENGTH_BASE[index] + _inflate_bits!(s, _INFLATE_LENGTH_EXTRA[index])
			dsym = _inflate_symbol!(s, distances)
			dsym <= 29 || throw(ArgumentError("inflate: invalid distance code."))
			dist = _INFLATE_DIST_BASE[dsym + 1] + _inflate_bits!(s, _INFLATE_DIST_EXTRA[dsym + 1])
			dist <= n || throw(ArgumentError("inflate: a match refers before the start of the output."))
			_inflate_reserve!(out, n, len, expected)
			start = n - dist
			@inbounds for k in 1:len
				out[n + k] = out[start + k]   # sequential, so overlapping copies repeat
			end
			n += len
		end
	end
	expected >= 0 && n != expected && throw(ArgumentError(
		"inflate: the stream holds $(n) bytes; expected $(expected).",
	))
	resize!(out, n)
	# The Adler-32 checksum follows the last block, byte aligned.
	_inflate_drop!(s, s.nbits % 8)
	checksum = UInt32(0)
	for _ in 1:4
		checksum = (checksum << 8) | UInt32(_inflate_bits!(s, 8))
	end
	checksum == _adler32(out) || throw(ArgumentError("inflate: Adler-32 checksum mismatch."))
	return out
end

# ── PNG decoding ────────────────────────────────────────────────────

# (width, height) from a PNG's IHDR chunk, which the format requires first.
function _png_size(bytes::AbstractVector{UInt8})
	length(bytes) >= 24 && bytes[1:8] == _PNG_SIGNATURE && bytes[13:16] == codeunits("IHDR") ||
		throw(ArgumentError("savefig: the renderer did not return a PNG image."))
	return (Int(_read_be_u32(bytes, 17)), Int(_read_be_u32(bytes, 21)))
end

@inline function _png_paeth(a::Int, b::Int, c::Int)
	p = a + b - c
	pa = abs(p - a)
	pb = abs(p - b)
	pc = abs(p - c)
	return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
end

"""
	_png_decode(bytes::Vector{UInt8}) -> (width, height, channels, pixels)

Decode a non-interlaced 8-bit RGB (`channels = 3`) or RGBA (`channels = 4`)
PNG, the formats Chromium's canvas encoder writes, into row-major pixel bytes
(`pixels[(y * width + x) * channels + c + 1]`, top row first, alpha not
premultiplied). Other PNG kinds and malformed data raise `ArgumentError`.
"""
function _png_decode(bytes::Vector{UInt8})
	n = length(bytes)
	n >= 8 && bytes[1:8] == _PNG_SIGNATURE ||
		throw(ArgumentError("savefig: the renderer did not return a PNG image."))
	width = height = channels = 0
	idat = UInt8[]
	i = 9
	seen_header = false
	while true
		i + 7 <= n || throw(ArgumentError("savefig: truncated PNG chunk header."))
		len = Int(_read_be_u32(bytes, i))
		i + 11 + len <= n || throw(ArgumentError("savefig: truncated PNG chunk."))
		kind = String(bytes[(i + 4):(i + 7)])
		body = @view bytes[(i + 8):(i + 7 + len)]
		if kind == "IHDR"
			len == 13 || throw(ArgumentError("savefig: malformed PNG IHDR chunk."))
			width = Int(_read_be_u32(body, 1))
			height = Int(_read_be_u32(body, 5))
			depth, colour, compression, filter, interlace = body[9], body[10], body[11], body[12], body[13]
			(width >= 1 && height >= 1) || throw(ArgumentError("savefig: PNG image has zero size."))
			depth == 8 && colour in (0x02, 0x06) || throw(ArgumentError(
				"savefig: unsupported PNG kind (bit depth $(depth), colour type $(colour)); expected 8-bit RGB or RGBA.",
			))
			compression == 0 && filter == 0 && interlace == 0 ||
				throw(ArgumentError("savefig: unsupported PNG compression, filter or interlace method."))
			channels = colour == 0x06 ? 4 : 3
			seen_header = true
		elseif kind == "IDAT"
			seen_header || throw(ArgumentError("savefig: PNG image data precedes its header."))
			append!(idat, body)
		elseif kind == "IEND"
			break
		end
		i += 12 + len
	end
	seen_header || throw(ArgumentError("savefig: PNG image has no IHDR chunk."))
	stride = width * channels
	raw = _inflate_zlib(idat; expected = height * (stride + 1))
	pixels = Vector{UInt8}(undef, height * stride)
	bpp = channels
	@inbounds for y in 0:(height - 1)
		src = y * (stride + 1) + 1          # index of the filter-type byte
		dst = y * stride                    # bytes of `pixels` before this row
		prior = dst - stride                # bytes before the previous row
		kind = raw[src]
		if kind == 0
			copyto!(pixels, dst + 1, raw, src + 1, stride)
		elseif kind == 1
			for k in 1:stride
				left = k > bpp ? Int(pixels[dst + k - bpp]) : 0
				pixels[dst + k] = (Int(raw[src + k]) + left) % UInt8
			end
		elseif kind == 2
			for k in 1:stride
				up = y > 0 ? Int(pixels[prior + k]) : 0
				pixels[dst + k] = (Int(raw[src + k]) + up) % UInt8
			end
		elseif kind == 3
			for k in 1:stride
				left = k > bpp ? Int(pixels[dst + k - bpp]) : 0
				up = y > 0 ? Int(pixels[prior + k]) : 0
				pixels[dst + k] = (Int(raw[src + k]) + ((left + up) >> 1)) % UInt8
			end
		elseif kind == 4
			for k in 1:stride
				left = k > bpp ? Int(pixels[dst + k - bpp]) : 0
				up = y > 0 ? Int(pixels[prior + k]) : 0
				upleft = (k > bpp && y > 0) ? Int(pixels[prior + k - bpp]) : 0
				pixels[dst + k] = (Int(raw[src + k]) + _png_paeth(left, up, upleft)) % UInt8
			end
		else
			throw(ArgumentError("savefig: invalid PNG filter type $(kind)."))
		end
	end
	return (width, height, channels, pixels)
end

# ── TIFF (baseline RGB, LZW) ────────────────────────────────────────

mutable struct _LZWBitWriter
	out::Vector{UInt8}
	buf::UInt64     # pending bits, most significant first
	pending::Int    # number of valid bits in `buf` (< 8 between calls)
end

@inline function _lzw_put!(w::_LZWBitWriter, code::Int, width::Int)
	w.buf = (w.buf << width) | UInt64(code)
	w.pending += width
	while w.pending >= 8
		push!(w.out, UInt8((w.buf >> (w.pending - 8)) & 0xff))
		w.pending -= 8
	end
	w.buf &= (UInt64(1) << w.pending) - 1
	return w
end

# Forget every string added to the LZW dictionary since the last reset.
function _lzw_reset!(child::Vector{UInt16}, used::Vector{Int})
	@inbounds for key in used
		child[key] = 0x0000
	end
	empty!(used)
	return child
end

"""
	_tiff_lzw_encode(data, child = zeros(UInt16, 4096 * 256), used = Int[]) -> Vector{UInt8}

Compress one TIFF strip with TIFF 6.0 LZW (section 13): codes are packed most
significant bit first, start at 9 bits after a Clear code, widen one code early
(the TIFF convention) and restart after code 4093, as libtiff's encoder does,
and end with End-of-Information. `child` and `used` are a reusable dictionary
workspace: `child` must be all zero on entry and is all zero again on return.
"""
function _tiff_lzw_encode(
	data::AbstractVector{UInt8},
	child::Vector{UInt16} = zeros(UInt16, 4096 * 256),
	used::Vector{Int} = Int[],
)::Vector{UInt8}
	# Codes 256 and 257 are fixed by TIFF 6.0 section 13; 258 is the first
	# string code and 4094 (libtiff CODE_MAX - 1) the point where the
	# 12-bit table is considered full.
	clear, eoi, first_code, table_full = 256, 257, 258, 4094
	length(child) == 4096 * 256 || throw(ArgumentError("savefig: bad LZW dictionary workspace."))
	w = _LZWBitWriter(UInt8[], UInt64(0), 0)
	sizehint!(w.out, length(data) ÷ 2 + 16)
	nbits = 9
	maxcode = 511
	next_free = first_code
	_lzw_put!(w, clear, nbits)
	if isempty(data)
		_lzw_put!(w, eoi, nbits)
	else
		prefix = Int(data[firstindex(data)])
		@inbounds for i in (firstindex(data) + 1):lastindex(data)
			byte = data[i]
			key = ((prefix << 8) | Int(byte)) + 1
			code = child[key]
			if code != 0
				prefix = Int(code)
				continue
			end
			_lzw_put!(w, prefix, nbits)
			child[key] = UInt16(next_free)
			push!(used, key)
			next_free += 1
			prefix = Int(byte)
			if next_free == table_full
				_lzw_put!(w, clear, nbits)
				_lzw_reset!(child, used)
				next_free = first_code
				nbits = 9
				maxcode = 511
			elseif next_free > maxcode
				nbits += 1
				maxcode = (1 << nbits) - 1
			end
		end
		_lzw_put!(w, prefix, nbits)
		# The decoder adds one more table entry after the last code; the
		# End-of-Information code is written at the width it then expects.
		next_free += 1
		if next_free == table_full
			_lzw_put!(w, clear, nbits)
			nbits = 9
		elseif next_free > maxcode
			nbits += 1
		end
		_lzw_put!(w, eoi, nbits)
	end
	w.pending > 0 && push!(w.out, UInt8((w.buf << (8 - w.pending)) & 0xff))
	_lzw_reset!(child, used)
	return w.out
end

# TIFF RATIONAL for a resolution: numerator / 1000, reduced.
function _tiff_rational(value::Float64)
	numerator = round(Int64, value * 1000)
	denominator = Int64(1000)
	g = gcd(numerator, denominator)
	return (UInt32(numerator ÷ g), UInt32(denominator ÷ g))
end

"""
	_tiff_encode(width, height, channels, pixels, dpi) -> Vector{UInt8}

Write a baseline TIFF 6.0 file (little-endian) of 8-bit RGB pixels with LZW
compression in strips of at most 64 KiB, and `XResolution = YResolution = dpi`
with `ResolutionUnit = inch`. `pixels` holds `channels = 3` (RGB) or `4` (RGBA,
not premultiplied) bytes per pixel, row-major from the top row; a fully opaque
RGBA image is written as RGB, otherwise the alpha is stored as an unassociated
alpha sample (`ExtraSamples = 2`). The file is deterministic (no dates or
software tags). Files of 4 GiB or more raise `ArgumentError` (BigTIFF is not
written).
"""
function _tiff_encode(width::Int, height::Int, channels::Int, pixels::Vector{UInt8}, dpi::Real)::Vector{UInt8}
	(width >= 1 && height >= 1) || throw(ArgumentError("savefig: a TIFF image needs a positive size."))
	channels in (3, 4) || throw(ArgumentError("savefig: TIFF pixels must be RGB or RGBA."))
	length(pixels) == width * height * channels ||
		throw(ArgumentError("savefig: the TIFF pixel buffer does not match its size."))
	resolution = _validated_export_dpi(dpi, "savefig")
	samples = channels
	data = pixels
	if channels == 4 && all(k -> @inbounds(pixels[k]) == 0xff, 4:4:length(pixels))
		samples = 3
		data = Vector{UInt8}(undef, width * height * 3)
		@inbounds for p in 0:(width * height - 1)
			data[3p + 1] = pixels[4p + 1]
			data[3p + 2] = pixels[4p + 2]
			data[3p + 3] = pixels[4p + 3]
		end
	end
	rowbytes = width * samples
	rows_per_strip = clamp(65536 ÷ rowbytes, 1, height)
	nstrips = cld(height, rows_per_strip)
	strips = Vector{Vector{UInt8}}(undef, nstrips)
	child = zeros(UInt16, 4096 * 256)
	used = Int[]
	for s in 1:nstrips
		first_row = (s - 1) * rows_per_strip
		last_row = min(height, first_row + rows_per_strip)
		strips[s] = _tiff_lzw_encode(view(data, (first_row * rowbytes + 1):(last_row * rowbytes)), child, used)
	end

	io = IOBuffer()
	write(io, UInt8['I', 'I'], htol(UInt16(42)), htol(UInt32(0)))   # IFD offset patched below
	offsets = UInt32[]
	for strip in strips
		position(io) + length(strip) < typemax(UInt32) ||
			throw(ArgumentError("savefig: the TIFF image is too large (4 GiB or more)."))
		push!(offsets, UInt32(position(io)))
		write(io, strip)
	end
	isodd(position(io)) && write(io, 0x00)
	# Out-of-line values (word aligned).
	bits_at = UInt32(position(io))
	foreach(_ -> write(io, htol(UInt16(8))), 1:samples)
	offsets_at = UInt32(position(io))
	nstrips > 1 && foreach(o -> write(io, htol(o)), offsets)
	counts_at = UInt32(position(io))
	nstrips > 1 && foreach(strip -> write(io, htol(UInt32(length(strip)))), strips)
	res_num, res_den = _tiff_rational(resolution)
	xres_at = UInt32(position(io))
	write(io, htol(res_num), htol(res_den))
	yres_at = UInt32(position(io))
	write(io, htol(res_num), htol(res_den))
	isodd(position(io)) && write(io, 0x00)
	ifd_at = UInt32(position(io))

	# (tag, type, count, value-or-offset); SHORT = 3, LONG = 4, RATIONAL = 5.
	short(v) = UInt32(v)   # a SHORT value sits in the low-order (first) two bytes
	entries = Tuple{UInt16,UInt16,UInt32,UInt32}[
		(256, 4, 1, UInt32(width)),
		(257, 4, 1, UInt32(height)),
		(258, 3, samples, samples <= 2 ? short(8) : bits_at),
		(259, 3, 1, short(5)),            # LZW
		(262, 3, 1, short(2)),            # RGB
		(273, 4, nstrips, nstrips == 1 ? offsets[1] : offsets_at),
		(277, 3, 1, short(samples)),
		(278, 4, 1, UInt32(rows_per_strip)),
		(279, 4, nstrips, nstrips == 1 ? UInt32(length(strips[1])) : counts_at),
		(282, 5, 1, xres_at),
		(283, 5, 1, yres_at),
		(284, 3, 1, short(1)),            # chunky (interleaved) samples
		(296, 3, 1, short(2)),            # inch
	]
	samples == 4 && push!(entries, (338, 3, 1, short(2)))   # unassociated alpha
	write(io, htol(UInt16(length(entries))))
	for (tag, kind, count, value) in entries
		write(io, htol(UInt16(tag)), htol(UInt16(kind)), htol(UInt32(count)), htol(UInt32(value)))
	end
	write(io, htol(UInt32(0)))   # no further IFD
	position(io) < typemax(UInt32) ||
		throw(ArgumentError("savefig: the TIFF image is too large (4 GiB or more)."))
	bytes = take!(io)
	bytes[5:8] = reinterpret(UInt8, [htol(ifd_at)])
	return bytes
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

# Chromium's printToPDF does not print the page size it is given: it rounds
# the size up to whole points and then to whole 1/300-inch device units, an
# error of -0.12 to +1.12 pt (8.3 cm = 235.28 pt became 235.92 pt). savefig
# therefore requests a page of `_pdf_request_points(size) = ceil(size) + 1`
# whole points, which holds the figure with room to spare (the 1/300-in
# rounding of a whole-point size is at most 0.12 pt), and crops it to the
# exact size with `_pdf_set_page_box`.
_pdf_request_points(points::Real) = ceil(Float64(points) - 1e-9) + 1.0

# Size differences (box minus requested, pt) `_pdf_set_page_box` accepts: the
# cropped request is 0.88 to 2.12 pt larger, an exact-size request -0.12 to
# +1.12 pt, and Ghostscript's pdfwrite rounds a box to 0.01 pt.
const _PDF_BOX_SLACK = (-0.25, 2.25)

"""
	_pdf_set_page_box(bytes::Vector{UInt8}, width_pt::Real, height_pt::Real) -> Vector{UInt8}

Make every page `/MediaBox` of the PDF `bytes` exactly `width_pt` x
`height_pt`, keeping its top-left corner (the figure is drawn from the
top-left, so only blank page is cut), and fix the cross-reference offsets.
A box qualifies when it is between 0.25 pt smaller and 2.25 pt larger than the
requested size in both directions (see `_pdf_request_points`). Raises an
error when no page box qualifies or the file does not use a single classic
xref table, so a wrong page size is never returned silently.
"""
function _pdf_set_page_box(bytes::Vector{UInt8}, width_pt::Real, height_pt::Real)::Vector{UInt8}
	w = Float64(width_pt)
	h = Float64(height_pt)
	(isfinite(w) && w > 0 && isfinite(h) && h > 0) ||
		throw(ArgumentError("savefig: the PDF page size must be positive and finite."))
	low, high = _PDF_BOX_SLACK
	fits(box, requested) = low <= box - requested <= high
	key = codeunits("/MediaBox")
	edits = Tuple{Int,Int,Vector{UInt8}}[]   # (first byte, last byte, replacement)
	matched = 0
	seen = String[]
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
		push!(seen, "$(bw) x $(bh)")
		fits(bw, w) && fits(bh, h) || continue
		matched += 1
		abs(bw - w) < 1e-6 && abs(bh - h) < 1e-6 && continue
		box = "[" * join(_format_pdf_number.((x0, y1 - h, x0 + w, y1)), " ") * "]"
		push!(edits, (open_bracket, close_bracket, collect(codeunits(box))))
		i = close_bracket + 1
	end
	matched > 0 || error(
		"savefig: the PDF has no page box near the requested $(w) x $(h) pt " *
		"(found: $(isempty(seen) ? "none" : join(seen, ", ")) pt).",
	)
	isempty(edits) && return copy(bytes)

	unsupported() = error(
		"savefig: cannot set the PDF page to $(w) x $(h) pt: the file does not " *
		"use a single classic cross-reference table.",
	)
	xref = _pdf_classic_xref(bytes)
	xref === nothing && unsupported()
	xref_start, digits_range, entries = xref
	# Every edited box must lie in an object body, i.e. before the xref table.
	all(edit -> edit[2] < xref_start, edits) || unsupported()

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
		length(text) == 10 || unsupported()
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

# Attribute order of the canonical root <svg> tag; any other attribute
# follows in its original order.
const _SVG_ROOT_ATTRIBUTE_ORDER =
	("class", "xmlns", "xmlns:xlink", "width", "height", "viewBox", "preserveAspectRatio", "style")

"""
	_svg_canonical_root(svg::String) -> String

Rewrite the attributes of the root `<svg>` start tag in a fixed order.
plotly.js does not always set them in the same order (after some figures
have been drawn in the export window, `style` is serialized after `viewBox`
instead of before it), which would make two exports of the same figure differ
by that order alone. A root tag with an attribute that is not a plain
`name="value"` pair is left unchanged.
"""
function _svg_canonical_root(svg::String)::String
	root = match(r"^(\s*<svg)((?:\s+[A-Za-z_:][-A-Za-z0-9_:.]*=\"[^\"]*\")*)(\s*/?>)", svg)
	root === nothing && return svg
	attributes = [(String(m.captures[1]), String(m.captures[2])) for m in
		eachmatch(r"\s+([A-Za-z_:][-A-Za-z0-9_:.]*)=\"([^\"]*)\"", root.captures[2])]
	rank(name) = something(findfirst(==(name), _SVG_ROOT_ATTRIBUTE_ORDER), length(_SVG_ROOT_ATTRIBUTE_ORDER) + 1)
	ordered = sort(attributes; by = a -> rank(a[1]), alg = MergeSort)   # stable: others keep their order
	tag = root.captures[1] * join((" $(name)=\"$(value)\"" for (name, value) in ordered)) * root.captures[3]
	return tag * svg[(ncodeunits(root.match) + 1):end]
end

# A length for an SVG attribute: plain decimal, at most 6 decimals (1e-6 of a
# unit; floating-point noise such as 8.299999999999999 cm prints as 8.3).
# Export sizes are at least 1 px (0.0104 in) and finite, so Julia's shortest
# float printing never uses an exponent here; the check guards that claim.
function _svg_length_text(x::Float64)
	text = string(round(x; digits = 6))
	endswith(text, ".0") && (text = text[1:(end - 2)])
	occursin(r"^[0-9]+(\.[0-9]+)?$", text) ||
		throw(ArgumentError("savefig: SVG length $(x) cannot be written as a plain decimal."))
	return text
end

"""
	_svg_set_physical_size(svg, width_px, height_px, units) -> String

Give the root `<svg>` element of a plotly.js export `width`/`height` in the
physical `units` (`:in`, `:cm`, `:mm` or `:pt`, written as the SVG/CSS unit
suffix `in`, `cm`, `mm`, `pt`) for a drawing of `width_px` x `height_px` CSS
pixels, so editors that do not assume 96 px/in (Illustrator reads a unitless
SVG length as 1/72 in) keep the physical size. The `viewBox` (the layout in
CSS px) is kept, or added when missing. Throws `ArgumentError` when the root
element has no width/height attributes.
"""
function _svg_set_physical_size(svg::String, width_px::Real, height_px::Real, units::Symbol)::String
	units === :px && return svg
	per_inch = _export_units_per_inch(units, "savefig")
	root = match(r"<svg\b[^>]*>", svg)
	root === nothing && throw(ArgumentError("savefig: the exported SVG has no <svg> element."))
	tag = root.match
	width_attr = match(r"(\s)width=\"([^\"]*)\"", tag)
	height_attr = match(r"(\s)height=\"([^\"]*)\"", tag)
	(width_attr === nothing || height_attr === nothing) &&
		throw(ArgumentError("savefig: the exported SVG root has no width/height attributes."))
	suffix = String(units)
	physical(px) = _svg_length_text(Float64(px) / _CSS_PX_PER_INCH * per_inch) * suffix
	new_tag = replace(tag, r"(\s)width=\"[^\"]*\"" => SubstitutionString("\\1width=\"$(physical(width_px))\""); count = 1)
	new_tag = replace(new_tag, r"(\s)height=\"[^\"]*\"" => SubstitutionString("\\1height=\"$(physical(height_px))\""); count = 1)
	if !occursin(r"\sviewBox=\"", new_tag)
		# The drawing's own coordinates are the unscaled layout px of the old
		# width/height attributes.
		box = "0 0 $(width_attr.captures[2]) $(height_attr.captures[2])"
		new_tag = new_tag[1:(end - 1)] * " viewBox=\"$(box)\">"
	end
	offset = root.offset
	return svg[1:prevind(svg, offset)] * new_tag * svg[(offset + ncodeunits(tag)):end]
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

# Run Ghostscript on the PDF `input_path` with the device arguments `args`,
# writing `output_path`. `label` names the output in error messages.
function _run_ghostscript(
	args::Cmd,
	input_path::AbstractString,
	output_path::AbstractString;
	timeout_s::Real,
	label::AbstractString,
)
	gs = _ghostscript_command()
	isfile(input_path) || throw(ArgumentError("savefig: PDF input not found: $(repr(input_path))."))
	timeout = Float64(timeout_s)
	isfinite(timeout) && timeout > 0 ||
		throw(ArgumentError("savefig: the Ghostscript timeout must be positive and finite."))
	cmd = `$gs -q -dSAFER -dBATCH -dNOPAUSE $args -sOutputFile=$(_ghostscript_output_path(output_path)) $input_path`
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
		error("savefig($(label)): Ghostscript did not finish within $(timeout) s.")
	end
	wait(process)
	if !success(process)
		message = strip(String(take!(stderr_buffer)) * "\n" * String(take!(stdout_buffer)))
		error("savefig($(label)): Ghostscript failed (exit code $(process.exitcode)): $(message)")
	end
	isfile(output_path) && filesize(output_path) > 0 ||
		error("savefig($(label)): Ghostscript reported success but wrote no output.")
	return output_path
end

"""
	_pdf_to_eps(pdf_path, eps_path; timeout_s = 300.0, outline = true) -> eps_path

Convert a single-page PDF to EPS with Ghostscript's `eps2write` device:
`gs -q -dSAFER -dBATCH -dNOPAUSE -dNOTRANSPARENCY [-dNoOutputFonts]
-sDEVICE=eps2write`. `-dNOTRANSPARENCY` keeps the output vector (with
transparency, eps2write would render the whole page to one image); savefig
blends translucent colours over their background before printing, so nothing
translucent is left for it to drop. `outline = true` (`-dNoOutputFonts`)
draws text as filled outlines, so the EPS holds no font (eps2write would
otherwise re-encode the PDF's fonts as Type 3 / Type 42 fonts). A missing
Ghostscript raises `ArgumentError`; a failed or timed-out conversion raises an
error carrying Ghostscript's stderr.
"""
function _pdf_to_eps(
	pdf_path::AbstractString,
	eps_path::AbstractString;
	timeout_s::Real = 300.0,
	outline::Bool = true,
)
	args = outline ? `-dNOTRANSPARENCY -dNoOutputFonts -sDEVICE=eps2write` :
		`-dNOTRANSPARENCY -sDEVICE=eps2write`
	return _run_ghostscript(args, pdf_path, eps_path; timeout_s = timeout_s, label = "eps")
end

"""
	_pdf_outline_text(pdf_path, out_path; timeout_s = 300.0) -> out_path

Rewrite a PDF with Ghostscript's `pdfwrite` device and `-dNoOutputFonts`, so
every glyph becomes a filled path and the file holds no font. Everything else
is kept: transparency, vector paths, and images, which are re-encoded
losslessly (Flate, no downsampling) instead of pdfwrite's default JPEG for
photographic images. `-dOmitInfoDate -dOmitID -dOmitXMP` make the output
deterministic and `-dWriteObjStms=false -dWriteXRefStm=false` keep the classic
cross-reference table `_pdf_set_page_box` patches.
"""
function _pdf_outline_text(pdf_path::AbstractString, out_path::AbstractString; timeout_s::Real = 300.0)
	args = `-sDEVICE=pdfwrite -dNoOutputFonts
		-dAutoFilterColorImages=false -dColorImageFilter=/FlateEncode
		-dAutoFilterGrayImages=false -dGrayImageFilter=/FlateEncode
		-dDownsampleColorImages=false -dDownsampleGrayImages=false -dDownsampleMonoImages=false
		-dOmitInfoDate -dOmitID -dOmitXMP -dWriteObjStms=false -dWriteXRefStm=false`
	return _run_ghostscript(args, pdf_path, out_path; timeout_s = timeout_s, label = "pdf")
end

"""
	_pdf_type3_fonts(bytes::Vector{UInt8}) -> Vector{String}

Names (`/BaseFont`, or `/Name`, else "unnamed") of the Type 3 fonts in a PDF
written by Chromium (Skia writes font dictionaries as plain, uncompressed
objects). Skia embeds TrueType (`glyf`) fonts as CID TrueType fonts and every
other font (CFF/OpenType-CFF such as STIX or Latin Modern, bitmap or
non-embeddable fonts) as Type 3 glyph procedures.
"""
function _pdf_type3_fonts(bytes::Vector{UInt8})::Vector{String}
	# Non-ASCII bytes (binary stream data) become '?', so the text is valid
	# UTF-8 for the regex engine; PDF syntax itself is ASCII.
	text = String(map(b -> b < 0x80 ? b : UInt8('?'), bytes))
	names = String[]
	for m in eachmatch(r"/Subtype\s*/Type3(?![A-Za-z0-9_.+-])", text)
		stop = findnext("endobj", text, m.offset)
		body = text[m.offset:(stop === nothing ? lastindex(text) : first(stop))]
		name = match(r"/(?:BaseFont|Name)\s*/([^\s/<>\[\]()]+)", body)
		if name === nothing
			descriptor = match(r"/FontDescriptor\s+(\d+)\s+(\d+)\s+R", body)
			if descriptor !== nothing
				object = match(Regex("(?<![0-9])$(descriptor[1])\\s+$(descriptor[2])\\s+obj\\b(.*?)endobj", "s"), text)
				object === nothing || (name = match(r"/FontName\s*/([^\s/<>\[\]()]+)", object[1]))
			end
		end
		push!(names, name === nothing ? "unnamed" : String(name.captures[1]))
	end
	return unique!(names)
end

# Plain decimal for an EPS DSC comment, at most 4 decimals.
_eps_number_text(x::Float64) = _format_pdf_number(x)

"""
	_eps_set_bounding_box(bytes::Vector{UInt8}, width_pt::Real, height_pt::Real) -> Vector{UInt8}

Replace the `%%BoundingBox:` and `%%HiResBoundingBox:` DSC comments of an EPS
written by Ghostscript's eps2write with the whole page, `0 0 ceil(w) ceil(h)`
and `0 0 w h`. eps2write places the PDF page at the origin but derives the box
from the painted marks, so a figure with a transparent or edge-snapped
background would otherwise shrink to its marks. Only the header comments (up
to `%%EndComments`) are changed; an EPS without a header `%%BoundingBox:` with
a value raises an error.
"""
function _eps_set_bounding_box(bytes::Vector{UInt8}, width_pt::Real, height_pt::Real)::Vector{UInt8}
	w = Float64(width_pt)
	h = Float64(height_pt)
	(isfinite(w) && w > 0 && isfinite(h) && h > 0) ||
		throw(ArgumentError("savefig: the EPS page size must be positive and finite."))
	replacements = (
		(codeunits("%%BoundingBox:"), " 0 0 $(Int(ceil(w - 1e-9))) $(Int(ceil(h - 1e-9)))"),
		(codeunits("%%HiResBoundingBox:"), " 0 0 $(_eps_number_text(w)) $(_eps_number_text(h))"),
	)
	end_comments = codeunits("%%EndComments")
	out = UInt8[]
	sizehint!(out, length(bytes) + 32)
	replaced = false
	n = length(bytes)
	start = 1
	while start <= n
		stop = start   # first byte after the line's content
		while stop <= n && bytes[stop] != 0x0a && bytes[stop] != 0x0d
			stop += 1
		end
		line = @view bytes[start:(stop - 1)]
		header_done = length(line) >= length(end_comments) &&
			@view(line[1:length(end_comments)]) == end_comments
		written = false
		for (key, value) in replacements
			length(line) >= length(key) && @view(line[1:length(key)]) == key || continue
			strip(String(line[(length(key) + 1):end])) == "(atend)" && break
			append!(out, key)
			append!(out, codeunits(value))
			written = true
			key == replacements[1][1] && (replaced = true)
			break
		end
		written || append!(out, line)
		# The line terminator (CR, LF or CRLF), unchanged.
		if stop <= n
			push!(out, bytes[stop])
			if bytes[stop] == 0x0d && stop < n && bytes[stop + 1] == 0x0a
				push!(out, 0x0a)
				stop += 1
			end
			stop += 1
		end
		start = stop
		if header_done
			start <= n && append!(out, @view bytes[start:n])
			break
		end
	end
	replaced || error("savefig(eps): the EPS has no %%BoundingBox comment to set.")
	return out
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
