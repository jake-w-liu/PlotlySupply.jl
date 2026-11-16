# PlotlySupply 2.0 scientific-plotting extensions: colormap resolution and sampling, colour utilities, colour norms, colorbar attribute/carrier builders.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_COLOR_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# Conventions used by every helper in this file:
# - A *resolved colorscale* is either `""` (unset: the template decides), the
#   canonical name of a plotly.js built-in that is passed through verbatim
#   (`"Picnic"`, …), or a `Vector{Vector{Any}}` of `[t::Float64, colour::String]`
#   stops with `t[1] == 0`, `t[end] == 1`, non-decreasing `t`, and colours in
#   the canonical form produced by `_color_hex` ("#RRGGBB", or
#   "rgba(r,g,b,a)" when the colour is not opaque).
# - Interpolation is linear in sRGB with straight (non-premultiplied) alpha,
#   like plotly.js and matplotlib's LinearSegmentedColormap.
# - `who` keywords name the public function for `ArgumentError` messages.

import Colors
import ColorSchemes

const _SCI_COLOR_MUTATORS = ()

export colormap, colormap_colors, lighten, discrete_colormap
public COLORMAPS

#region Colour parsing and formatting

# Straight-alpha RGBA, every channel in [0, 1].
const _RGBA4 = NTuple{4,Float64}

const _RGB_FUNCTION_REGEX =
	r"^rgba?\(\s*([^\s,()]+)\s*,\s*([^\s,()]+)\s*,\s*([^\s,()]+)\s*(?:,\s*([^\s,()]+)\s*)?\)$"i

function _invalid_colour_error(c, who::AbstractString)
	return ArgumentError(
		"$(who): invalid colour $(repr(c)); use a CSS colour name, \"#RRGGBB\", " *
		"\"#RRGGBBAA\", \"rgb(r,g,b)\", \"rgba(r,g,b,a)\", \"hsl(...)\", a grey " *
		"level such as \"0.35\" (in [0, 1]), a Symbol, or a Colors.jl Colorant.",
	)
end

# One `rgb()`/`rgba()` component. Colour channels are 0-255 or a percentage;
# alpha is 0-1 or a percentage. Out-of-range values are clamped, as CSS and
# plotly.js (tinycolor) do. Returns `nothing` when the text is not a number.
function _parse_rgb_component(text::AbstractString, is_alpha::Bool)
	percent = endswith(text, "%")
	number = tryparse(Float64, percent ? chop(text) : text)
	(number === nothing || !isfinite(number)) && return nothing
	value = percent ? number / 100 : (is_alpha ? number : number / 255)
	return clamp(value, 0.0, 1.0)
end

function _parse_hex_colour(digits::AbstractString)
	(isascii(digits) && all(isxdigit, digits)) || return nothing
	n = ncodeunits(digits)
	channels = if n == 3 || n == 4
		[parse(Int, digits[i:i]; base = 16) * 17 for i in 1:n]
	elseif n == 6 || n == 8
		[parse(Int, digits[i:(i + 1)]; base = 16) for i in 1:2:n]
	else
		return nothing
	end
	alpha = length(channels) == 4 ? channels[4] / 255 : 1.0
	return (channels[1] / 255, channels[2] / 255, channels[3] / 255, alpha)
end

function _colorant_rgba(c::Colors.Colorant, original, who::AbstractString)::_RGBA4
	rgba = try
		convert(Colors.RGBA{Float64}, c)
	catch err
		err isa MethodError || rethrow()
		throw(_invalid_colour_error(original, who))
	end
	channels = (
		Float64(Colors.red(rgba)),
		Float64(Colors.green(rgba)),
		Float64(Colors.blue(rgba)),
		Float64(Colors.alpha(rgba)),
	)
	all(isfinite, channels) || throw(_invalid_colour_error(original, who))
	return map(v -> clamp(v, 0.0, 1.0), channels)
end

function _parse_colour_string(text::AbstractString, original, who::AbstractString)::_RGBA4
	s = strip(text)
	isempty(s) && throw(_invalid_colour_error(original, who))
	# matplotlib grey levels: a numeric string in [0, 1] is an opaque grey
	# ("0" black, "1" white, "0.35" == "#595959"). No CSS colour is a bare
	# number, so any other numeric string is an error rather than a fallback.
	level = tryparse(Float64, s)
	if level !== nothing
		(isfinite(level) && 0 <= level <= 1) || throw(ArgumentError(
			"$(who): a numeric colour string is a matplotlib grey level and " *
			"must lie in [0, 1]; got $(repr(original)).",
		))
		return (level, level, level, 1.0)
	end
	if startswith(s, '#')
		parsed = _parse_hex_colour(s[2:end])
		parsed === nothing && throw(_invalid_colour_error(original, who))
		return parsed
	end
	m = match(_RGB_FUNCTION_REGEX, s)
	if m !== nothing
		is_rgba = startswith(lowercase(s), "rgba")
		has_alpha = m.captures[4] !== nothing
		# rgb() takes three components and rgba() four (CSS Color 3).
		is_rgba == has_alpha || throw(_invalid_colour_error(original, who))
		channels = Float64[]
		for (index, capture) in enumerate(m.captures)
			capture === nothing && continue
			value = _parse_rgb_component(capture, index == 4)
			value === nothing && throw(_invalid_colour_error(original, who))
			push!(channels, value)
		end
		return (channels[1], channels[2], channels[3], has_alpha ? channels[4] : 1.0)
	end
	lowercase(s) == "transparent" && return (0.0, 0.0, 0.0, 0.0)
	colorant = try
		parse(Colors.Colorant, s)
	catch err
		err isa ArgumentError || rethrow()
		throw(_invalid_colour_error(original, who))
	end
	return _colorant_rgba(colorant, original, who)
end

# Parse any supported colour value into straight-alpha RGBA channels. Strings
# and Symbols are CSS colours or matplotlib grey levels ("0.35").
function _parse_color(c, who::AbstractString = "_parse_color")::_RGBA4
	c isa Colors.Colorant && return _colorant_rgba(c, c, who)
	c isa Symbol && return _parse_colour_string(String(c), c, who)
	c isa AbstractString && return _parse_colour_string(c, c, who)
	throw(ArgumentError(
		"$(who): colours must be strings, symbols or Colors.jl Colorants; got $(typeof(c)).",
	))
end

_channel_byte(v::Float64) = round(Int, clamp(v, 0.0, 1.0) * 255)
_hex_byte(v::Float64) = uppercase(string(_channel_byte(v); base = 16, pad = 2))

# Alpha is written with at most four decimals ("0.35", "0.3333", "1").
function _format_alpha(a::Float64)
	rounded = round(clamp(a, 0.0, 1.0); digits = 4)
	return isinteger(rounded) ? string(Int(rounded)) : string(rounded)
end

# Canonical CSS text for a colour: "#RRGGBB" when opaque (alpha rounds to 1),
# otherwise "rgba(r,g,b,a)" with integer channels.
function _rgba_string(c::_RGBA4)
	r, g, b, a = c
	if round(clamp(a, 0.0, 1.0); digits = 4) == 1
		return "#" * _hex_byte(r) * _hex_byte(g) * _hex_byte(b)
	end
	return "rgba($(_channel_byte(r)),$(_channel_byte(g)),$(_channel_byte(b)),$(_format_alpha(a)))"
end

function _checked_unit_fraction(value, who::AbstractString, name::AbstractString)
	(value isa Real && !(value isa Bool) && isfinite(value) && 0 <= value <= 1) ||
		throw(ArgumentError("$(who): `$(name)` must be a number in [0, 1]; got $(repr(value))."))
	return Float64(value)
end

# String | Symbol | Colorant -> "#RRGGBB" (opaque) or "rgba(r,g,b,a)".
_color_hex(c; who::AbstractString = "_color_hex") = _rgba_string(_parse_color(c, who))

# The colour `c` with its opacity replaced by `alpha` (matplotlib `to_rgba`
# semantics), always written as "rgba(r,g,b,a)".
function _rgba(c, alpha::Real; who::AbstractString = "_rgba")
	a = _checked_unit_fraction(alpha, who, "alpha")
	r, g, b, _ = _parse_color(c, who)
	return "rgba($(_channel_byte(r)),$(_channel_byte(g)),$(_channel_byte(b)),$(_format_alpha(a)))"
end

# Composite `c` drawn at opacity `alpha` (times its own alpha) over
# `background` (Porter-Duff "over" in sRGB, as browsers composite). An opaque
# background gives an opaque "#RRGGBB" result: the pre-blend used where plotly
# has no per-element opacity (3-D lines, shared fills).
function _blend_over(c, alpha::Real, background = "#ffffff"; who::AbstractString = "_blend_over")
	a = _checked_unit_fraction(alpha, who, "alpha")
	sr, sg, sb, sa = _parse_color(c, who)
	br, bg, bb, ba = _parse_color(background, who)
	source_alpha = sa * a
	out_alpha = source_alpha + ba * (1 - source_alpha)
	out_alpha == 0 && return _rgba_string((0.0, 0.0, 0.0, 0.0))
	blend(s, d) = (s * source_alpha + d * ba * (1 - source_alpha)) / out_alpha
	return _rgba_string((blend(sr, br), blend(sg, bg), blend(sb, bb), out_alpha))
end

#endregion

#region Colormap tables

"""
	PlotlySupply.COLORMAPS :: Dict{String,Vector{String}}

Named colormaps resolved by every `colorscale` keyword, by [`colormap`](@ref) and by
[`colormap_colors`](@ref). Each entry is a list of colours spaced evenly over
`[0, 1]`, in matplotlib (and plotly.py) orientation: `"RdBu"` runs from dark red at
the low end to dark blue at the high end, `"Blues"` from white to dark blue.

Lookup is case-insensitive and a `"_r"` suffix reverses a map (`"RdBu_r"`).
Built-in entries (ColorSchemes.jl data; each agrees with matplotlib within 3/255
per channel, except `cividis`, which is the plotly.js/plotly.py version):
perceptual `viridis plasma inferno magma cividis turbo twilight`, diverging
`coolwarm seismic bwr RdBu PuOr RdYlBu Spectral PiYG PRGn RdGy BrBG`, colorbrewer
sequential `Blues Greys Reds Greens Oranges Purples YlGnBu YlOrRd`, and classic
`hot jet rainbow gray grey`. Names not in this table may still be plotly.js
built-ins (`Bluered Picnic Portland Electric Blackbody Earth`) or ColorSchemes.jl
scheme names.

You may register your own map by adding an entry, e.g.
`PlotlySupply.COLORMAPS["ice"] = ["#000033", "#3366cc", "#ffffff"]`; colours are
validated when the map is used.
"""
const COLORMAPS = Dict{String,Vector{String}}()

# Canonical name => ColorSchemes.jl key, or the explicit colour list of a map
# that matplotlib defines by a few evenly spaced anchors (matplotlib
# lib/matplotlib/_cm.py: `_bwr_data`, `_seismic_data`, `_gray_data`; the
# ColorSchemes copies are 100/101-entry samples that miss bwr's white centre by
# 3/255). `jet1` and `rainbow1` are the ColorSchemes copies of matplotlib's jet
# and rainbow (ColorSchemes' `jet` and `rainbow` are different maps), and
# `BrBG_11` is the 11-class colorbrewer BrBG that matplotlib uses. Every entry
# agrees with matplotlib within 3/255 per channel except cividis, which follows
# the plotly.js/plotly.py (viridisLite) definition, up to 23/255 from
# matplotlib's.
const _COLORMAP_SOURCES = (
	"viridis" => :viridis,
	"plasma" => :plasma,
	"inferno" => :inferno,
	"magma" => :magma,
	"cividis" => :cividis,
	"turbo" => :turbo,
	"twilight" => :twilight,
	"coolwarm" => :coolwarm,
	"seismic" => ["#00004C", "#0000FF", "#FFFFFF", "#FF0000", "#800000"],
	"bwr" => ["#0000FF", "#FFFFFF", "#FF0000"],
	"RdBu" => :RdBu,
	"PuOr" => :PuOr,
	"RdYlBu" => :RdYlBu,
	"Spectral" => :Spectral,
	"PiYG" => :PiYG,
	"PRGn" => :PRGn,
	"RdGy" => :RdGy,
	"BrBG" => :BrBG_11,
	"Blues" => :Blues,
	"Greys" => :Greys,
	"Reds" => :Reds,
	"Greens" => :Greens,
	"Oranges" => :Oranges,
	"Purples" => :Purples,
	"YlGnBu" => :YlGnBu,
	"YlOrRd" => :YlOrRd,
	"hot" => :hot,
	"jet" => :jet1,
	"rainbow" => :rainbow1,
	"gray" => ["#000000", "#FFFFFF"],
	"grey" => ["#000000", "#FFFFFF"],
)

for (name, source) in _COLORMAP_SOURCES
	colours = source isa Symbol ? ColorSchemes.colorschemes[source].colors : source
	COLORMAPS[name] = [_color_hex(c) for c in colours]
end

# plotly.js built-in scales that have no matplotlib/ColorSchemes counterpart.
# They are passed through by name; the stops (copied verbatim from
# plotly.js 2.35.2, src/components/colorscale/scales.js, and checked against
# the bundled plotly.min.js by test/sci_color.jl) are used only where a scale
# must be sampled or remapped in Julia.
const _PLOTLYJS_PASSTHROUGH_SCALES = (
	"Bluered" => [(0.0, "rgb(0,0,255)"), (1.0, "rgb(255,0,0)")],
	"Picnic" => [
		(0.0, "rgb(0,0,255)"), (0.1, "rgb(51,153,255)"), (0.2, "rgb(102,204,255)"),
		(0.3, "rgb(153,204,255)"), (0.4, "rgb(204,204,255)"), (0.5, "rgb(255,255,255)"),
		(0.6, "rgb(255,204,255)"), (0.7, "rgb(255,153,255)"), (0.8, "rgb(255,102,204)"),
		(0.9, "rgb(255,102,102)"), (1.0, "rgb(255,0,0)"),
	],
	"Portland" => [
		(0.0, "rgb(12,51,131)"), (0.25, "rgb(10,136,186)"), (0.5, "rgb(242,211,56)"),
		(0.75, "rgb(242,143,56)"), (1.0, "rgb(217,30,30)"),
	],
	"Electric" => [
		(0.0, "rgb(0,0,0)"), (0.15, "rgb(30,0,100)"), (0.4, "rgb(120,0,100)"),
		(0.6, "rgb(160,90,0)"), (0.8, "rgb(230,200,0)"), (1.0, "rgb(255,250,220)"),
	],
	"Blackbody" => [
		(0.0, "rgb(0,0,0)"), (0.2, "rgb(230,0,0)"), (0.4, "rgb(230,210,0)"),
		(0.7, "rgb(255,255,255)"), (1.0, "rgb(160,200,255)"),
	],
	"Earth" => [
		(0.0, "rgb(0,0,130)"), (0.1, "rgb(0,180,180)"), (0.2, "rgb(40,210,40)"),
		(0.4, "rgb(230,230,50)"), (0.6, "rgb(120,70,20)"), (1.0, "rgb(255,255,255)"),
	],
)

const _PLOTLYJS_PASSTHROUGH_NAMES = Tuple(first.(_PLOTLYJS_PASSTHROUGH_SCALES))

function _passthrough_stops(name::AbstractString)::Vector{Vector{Any}}
	for (canonical, stops) in _PLOTLYJS_PASSTHROUGH_SCALES
		canonical == name &&
			return [Any[t, _color_hex(c; who = "_passthrough_stops")] for (t, c) in stops]
	end
	throw(ArgumentError("_passthrough_stops: $(repr(name)) is not a plotly.js pass-through colorscale."))
end

# plotly.js `Color.defaults` (src/components/color/attributes.js): the colorway
# plotly.js uses when neither the layout nor its template sets one.
const _PLOTLYJS_DEFAULT_COLORWAY = (
	"#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
	"#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf",
)

#endregion

#region Colorscale resolution

const _COLORSCALE_FORMS =
	"a colormap name (keys(PlotlySupply.COLORMAPS), case-insensitive, optional \"_r\" suffix), " *
	"a plotly.js name ($(join(_PLOTLYJS_PASSTHROUGH_NAMES, ", "))), a ColorSchemes.jl scheme name, " *
	"a vector of colours, a vector of (t, colour) pairs, or a ColorScheme"

_is_colour_entry(e) = e isa AbstractString || e isa Symbol || e isa Colors.Colorant

function _stop_entry_parts(e)
	if e isa Pair && first(e) isa Real
		return (first(e), last(e))
	elseif (e isa Tuple || e isa AbstractVector) && length(e) == 2 && e[1] isa Real
		return (e[1], e[2])
	end
	return nothing
end

# Evenly spaced stops for a list of colours (one colour gives a constant scale).
function _even_stops(colours, who::AbstractString)::Vector{Vector{Any}}
	n = length(colours)
	n == 0 && throw(ArgumentError("$(who): a colorscale needs at least one colour."))
	hexes = [_color_hex(c; who) for c in colours]
	n == 1 && return [Any[0.0, hexes[1]], Any[1.0, hexes[1]]]
	return [Any[k == n ? 1.0 : (k - 1) / (n - 1), hexes[k]] for k in 1:n]
end

function _normalize_stop_vector(entries, who::AbstractString)::Vector{Vector{Any}}
	stops = Vector{Vector{Any}}(undef, length(entries))
	previous = -Inf
	for (index, entry) in enumerate(entries)
		t, colour = _stop_entry_parts(entry)
		(t isa Bool || !isfinite(t) || !(0 <= t <= 1)) && throw(ArgumentError(
			"$(who): colorscale stop $(index) has position $(repr(t)); positions must be finite numbers in [0, 1].",
		))
		tf = Float64(t)
		tf < previous && throw(ArgumentError(
			"$(who): colorscale stop positions must be non-decreasing; stop $(index) (t = $(tf)) follows t = $(previous).",
		))
		previous = tf
		stops[index] = Any[tf, _color_hex(colour; who)]
	end
	length(stops) >= 2 || throw(ArgumentError(
		"$(who): a colorscale given as (t, colour) pairs needs at least two stops; got $(length(stops)).",
	))
	(stops[1][1] == 0 && stops[end][1] == 1) || throw(ArgumentError(
		"$(who): colorscale stops must start at t = 0 and end at t = 1 (plotly.js ignores other scales); " *
		"got t = $(stops[1][1]) … $(stops[end][1]).",
	))
	return stops
end

function _normalize_scale_vector(v::AbstractVector, who::AbstractString)::Vector{Vector{Any}}
	isempty(v) && throw(ArgumentError("$(who): an empty vector is not a colorscale; expected $(_COLORSCALE_FORMS)."))
	all(e -> _stop_entry_parts(e) !== nothing, v) && return _normalize_stop_vector(v, who)
	all(_is_colour_entry, v) && return _even_stops(v, who)
	throw(ArgumentError(
		"$(who): a colorscale vector must hold either colours or (t, colour) pairs, not $(eltype(v)) " *
		"entries such as $(repr(first(v))); expected $(_COLORSCALE_FORMS).",
	))
end

function _reverse_stops(stops::AbstractVector)::Vector{Vector{Any}}
	out = [Any[1.0 - Float64(s[1]), s[2]] for s in Iterators.reverse(stops)]
	out[1][1] = 0.0
	out[end][1] = 1.0
	return out
end

# Name lookups. Each returns the canonical key/symbol or `nothing`; an
# ambiguous case-insensitive match throws.
function _colormap_table_key(name::AbstractString, who::AbstractString)
	haskey(COLORMAPS, name) && return String(name)
	lname = lowercase(name)
	matches = sort!([k for k in keys(COLORMAPS) if lowercase(k) == lname])
	length(matches) == 1 && return matches[1]
	length(matches) > 1 && throw(ArgumentError(
		"$(who): colorscale $(repr(name)) matches several COLORMAPS entries ($(join(matches, ", "))); use the exact name.",
	))
	return nothing
end

function _passthrough_name(name::AbstractString)
	lname = lowercase(name)
	for canonical in _PLOTLYJS_PASSTHROUGH_NAMES
		lowercase(canonical) == lname && return canonical
	end
	return nothing
end

function _colorschemes_key(name::AbstractString, who::AbstractString)
	key = Symbol(name)
	haskey(ColorSchemes.colorschemes, key) && return key
	lname = lowercase(name)
	matches = sort!([k for k in keys(ColorSchemes.colorschemes) if lowercase(String(k)) == lname])
	length(matches) == 1 && return matches[1]
	length(matches) > 1 && throw(ArgumentError(
		"$(who): colorscale $(repr(name)) matches several ColorSchemes.jl schemes " *
		"($(join(String.(matches), ", "))); use the exact (case-sensitive) name.",
	))
	return nothing
end

# Resolve a bare name (no "_r" handling): expanded stops, a pass-through name,
# or `nothing` when unknown.
function _named_scale(name::AbstractString, who::AbstractString)
	key = _colormap_table_key(name, who)
	key === nothing || return _even_stops(COLORMAPS[key], who)
	passthrough = _passthrough_name(name)
	passthrough === nothing || return passthrough
	scheme = _colorschemes_key(name, who)
	scheme === nothing || return _even_stops(ColorSchemes.colorschemes[scheme].colors, who)
	return nothing
end

function _levenshtein(a::AbstractString, b::AbstractString)
	ca, cb = collect(a), collect(b)
	previous = collect(0:length(cb))
	current = similar(previous)
	for i in eachindex(ca)
		current[1] = i
		for j in eachindex(cb)
			cost = ca[i] == cb[j] ? 0 : 1
			current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
		end
		previous, current = current, previous
	end
	return previous[end]
end

const _MAX_COLORSCALE_SUGGESTIONS = 5

function _colorscale_suggestions(name::AbstractString)
	reversed = length(name) > 2 && endswith(lowercase(name), "_r")
	base = lowercase(reversed ? chop(name; tail = 2) : name)
	suffix = reversed ? "_r" : ""
	scored = Tuple{Int,String}[]
	for candidate in Iterators.flatten((keys(COLORMAPS), _PLOTLYJS_PASSTHROUGH_NAMES))
		lc = lowercase(candidate)
		distance = _levenshtein(base, lc)
		related = length(base) >= 3 && (startswith(lc, base) || occursin(base, lc) || occursin(lc, base))
		if distance <= max(2, length(base) ÷ 3) || related
			push!(scored, (related ? min(distance, 1) : distance, candidate))
		end
	end
	sort!(scored)
	suggestions = unique!([candidate * suffix for (_, candidate) in scored])
	if length(suggestions) < _MAX_COLORSCALE_SUGGESTIONS
		extra = sort!([String(k) for k in keys(ColorSchemes.colorschemes)
			if _levenshtein(base, lowercase(String(k))) <= 1])
		for candidate in extra
			candidate * suffix in suggestions || push!(suggestions, candidate * suffix)
		end
	end
	return first(suggestions, _MAX_COLORSCALE_SUGGESTIONS)
end

function _resolve_colorscale_name(name::AbstractString, who::AbstractString)
	scale = _named_scale(name, who)
	scale === nothing || return (scale = scale, reversescale = false)
	if length(name) > 2 && endswith(lowercase(name), "_r")
		scale = _named_scale(chop(name; tail = 2), who)
		if scale !== nothing
			stops = scale isa AbstractString ? _passthrough_stops(scale) : scale
			return (scale = _reverse_stops(stops), reversescale = false)
		end
	end
	suggestions = _colorscale_suggestions(name)
	hint = isempty(suggestions) ? "" : "; did you mean: " * join(suggestions, ", ")
	throw(ArgumentError("$(who): unknown colorscale $(repr(String(name)))$(hint). Expected $(_COLORSCALE_FORMS)."))
end

"""
	_resolve_colorscale(cs; who) -> (scale, reversescale)

Resolve a user `colorscale` value to what plotly.js receives. `scale` is `""`
(unset, the template decides), the canonical name of a plotly.js-only built-in
(`"Bluered"`, `"Picnic"`, `"Portland"`, `"Electric"`, `"Blackbody"`, `"Earth"`,
passed through), or a `Vector{Vector{Any}}` of `[t, "#RRGGBB"]` stops.

Accepted: `""`/`nothing` (unset); a String/Symbol name looked up case-insensitively
in `COLORMAPS`, then among the plotly.js names, then among ColorSchemes.jl scheme
names (exact case first, then a unique case-insensitive match), each optionally
with a `"_r"` suffix that reverses the stops themselves (so colorbars and shared
coloraxes agree); a JSON array string (as plotly.js accepts); a vector of colours
(evenly spaced); a vector of `(t, colour)` tuples, `t => colour` pairs or
`[t, colour]` vectors (t from 0 to 1, non-decreasing); a `ColorScheme`.
`reversescale` is always `false`: reversal is applied to the stops. Unknown names
throw an `ArgumentError` with suggestions.
"""
function _resolve_colorscale(cs; who::AbstractString)
	cs === nothing && return (scale = "", reversescale = false)
	cs isa Symbol && (cs = String(cs))
	if cs isa AbstractString
		name = strip(cs)
		isempty(name) && return (scale = "", reversescale = false)
		if startswith(name, '[')
			parsed = try
				PlotlyBase.JSON.parse(name)
			catch err
				throw(ArgumentError(
					"$(who): colorscale string $(repr(String(cs))) starts with '[' but is not valid JSON: " *
					sprint(showerror, err),
				))
			end
			parsed isa AbstractVector || throw(ArgumentError(
				"$(who): colorscale JSON must be an array of [t, colour] pairs; got $(repr(String(cs))).",
			))
			return (scale = _normalize_scale_vector(parsed, who), reversescale = false)
		end
		return _resolve_colorscale_name(name, who)
	end
	cs isa ColorSchemes.ColorScheme && return (scale = _even_stops(cs.colors, who), reversescale = false)
	cs isa AbstractVector && return (scale = _normalize_scale_vector(cs, who), reversescale = false)
	throw(ArgumentError("$(who): unsupported colorscale of type $(typeof(cs)); expected $(_COLORSCALE_FORMS)."))
end

_is_unset_colorscale(cs) = cs === nothing || (cs isa AbstractString && isempty(strip(cs))) ||
	(cs isa Symbol && isempty(strip(String(cs))))

# Fully expanded stops for any non-empty colorscale (pass-through names are
# expanded with their plotly.js stops).
function _colorscale_stops(cs; who::AbstractString)::Vector{Vector{Any}}
	_is_unset_colorscale(cs) && throw(ArgumentError("$(who): a colormap name or colorscale is required; got $(repr(cs))."))
	resolved = _resolve_colorscale(cs; who)
	stops = resolved.scale isa AbstractString ? _passthrough_stops(resolved.scale) : resolved.scale
	return resolved.reversescale ? _reverse_stops(stops) : stops
end

#endregion

#region Sampling

struct _ParsedColorscale
	t::Vector{Float64}
	colours::Vector{_RGBA4}
end

function _parsed_colorscale(stops::AbstractVector{<:AbstractVector})
	return _ParsedColorscale(
		Float64[Float64(s[1]) for s in stops],
		_RGBA4[_parse_color(s[2], "_sample_colorscale") for s in stops],
	)
end

# Linear interpolation; at a repeated position (a step) the colour after the
# step wins, like matplotlib's ListedColormap bins and plotly.js.
function _sample_parsed(p::_ParsedColorscale, t::Float64)::_RGBA4
	isnan(t) && throw(ArgumentError("_sample_colorscale: the sample position must not be NaN."))
	t = clamp(t, 0.0, 1.0)
	j = searchsortedlast(p.t, t)
	j >= length(p.t) && return p.colours[end]
	j < 1 && return p.colours[1]
	t0, t1 = p.t[j], p.t[j + 1]
	f = (t - t0) / (t1 - t0)
	c0, c1 = p.colours[j], p.colours[j + 1]
	return ntuple(k -> c0[k] + f * (c1[k] - c0[k]), 4)
end

_sample_input_stops(stops) = _parsed_colorscale(_colorscale_stops(stops; who = "_sample_colorscale"))

"""
	_sample_colorscale(stops, t::Real) -> String
	_sample_colorscale(stops, ts::AbstractVector{<:Real}) -> Vector{String}

Colour of a colorscale at position `t` (clamped to `[0, 1]`; NaN throws), by linear
sRGB interpolation between stops. `stops` is a resolved colorscale or anything
`_resolve_colorscale` accepts (pass-through names are expanded).
"""
function _sample_colorscale(stops, t::Real)::String
	return _rgba_string(_sample_parsed(_sample_input_stops(stops), Float64(t)))
end

function _sample_colorscale(stops, ts::AbstractVector{<:Real})::Vector{String}
	parsed = _sample_input_stops(stops)
	return [_rgba_string(_sample_parsed(parsed, Float64(t))) for t in ts]
end

#endregion

#region Public colormap API

"""
	colormap(name_or_scale; n::Integer = 0, reverse::Bool = false) -> Vector{Tuple{Float64,String}}

Return plotly-ready colorscale stops `(t, colour)` for a named colormap or any
colorscale value accepted by the `colorscale` keywords.

# Arguments
- `name_or_scale`: a colormap name (`"viridis"`, `"RdBu_r"`, `:magma`; see
  `PlotlySupply.COLORMAPS`, case-insensitive, `"_r"` reverses), a plotly.js name
  (`"Picnic"`, …), a ColorSchemes.jl scheme name, a vector of colours, a vector of
  `(t, colour)` pairs, or a `ColorScheme`.

# Keywords
- `n::Integer = 0`: `0` keeps the map's native stops; `n ≥ 2` resamples `n` evenly
  spaced stops (`n = 1` or negative throws an `ArgumentError`).
- `reverse::Bool = false`: reverse the map (`t → 1 - t`).

# Returns
A `Vector{Tuple{Float64,String}}` whose first position is `0.0` and last `1.0`;
colours are `"#RRGGBB"` (or `"rgba(...)"` for translucent colours). The result can
be passed back as `colorscale=`.

# Example
```julia
stops = colormap("RdBu"; n = 5)   # [(0.0, "#67001F"), (0.25, …), …, (1.0, "#053061")]
plot_heatmap(rand(10, 10); colorscale = colormap("magma"; reverse = true))
```
"""
function colormap(name_or_scale; n::Integer = 0, reverse::Bool = false)
	(n == 0 || n >= 2) ||
		throw(ArgumentError("colormap: `n` must be 0 (native stops) or at least 2; got $(n)."))
	stops = _colorscale_stops(name_or_scale; who = "colormap")
	if n >= 2
		parsed = _parsed_colorscale(stops)
		count = Int(n)
		stops = [Any[t, _rgba_string(_sample_parsed(parsed, t))]
			for t in (k == count ? 1.0 : (k - 1) / (count - 1) for k in 1:count)]
	end
	reverse && (stops = _reverse_stops(stops))
	return Tuple{Float64,String}[(Float64(s[1]), String(s[2])) for s in stops]
end

function _checked_sample_range(range, who::AbstractString)
	valid_container = (range isa Tuple || range isa AbstractVector) && length(range) == 2
	valid_container || throw(ArgumentError(
		"$(who): `range` must be a 2-element tuple or vector (lo, hi) with values in [0, 1]; got $(repr(range)).",
	))
	lo = _checked_unit_fraction(range[1], who, "range[1]")
	hi = _checked_unit_fraction(range[2], who, "range[2]")
	return lo, hi
end

"""
	colormap_colors(name_or_scale, n::Integer; reverse::Bool = false, range = (0.0, 1.0)) -> Vector{String}

Sample `n` colours evenly spaced over `range` from a colormap, e.g. to colour a
family of lines (matplotlib's `cmap(np.linspace(lo, hi, n))`).

# Arguments
- `name_or_scale`: any value accepted by [`colormap`](@ref).
- `n::Integer`: number of colours, at least 1. `n == 1` returns the colour at the
  midpoint of `range`.

# Keywords
- `reverse::Bool = false`: sample the reversed map.
- `range = (0.0, 1.0)`: a 2-element tuple or vector `(lo, hi)` with values in
  `[0, 1]`; `lo > hi` samples in descending order.

# Returns
A `Vector{String}` of `"#RRGGBB"` colours (`"rgba(...)"` for translucent maps).

# Example
```julia
colors = colormap_colors("viridis", 4; range = (0.1, 0.9))
plot_scatter(1:10, [rand(10) for _ in 1:4]; color = colors)
```
"""
function colormap_colors(
	name_or_scale,
	n::Integer;
	reverse::Bool = false,
	range = (0.0, 1.0),
)
	n >= 1 || throw(ArgumentError("colormap_colors: `n` must be at least 1; got $(n)."))
	lo, hi = _checked_sample_range(range, "colormap_colors")
	parsed = _parsed_colorscale(_colorscale_stops(name_or_scale; who = "colormap_colors"))
	count = Int(n)
	positions = count == 1 ? [(lo + hi) / 2] :
		[k == count ? hi : lo + (hi - lo) * (k - 1) / (count - 1) for k in 1:count]
	reverse && (positions = 1.0 .- positions)
	return [_rgba_string(_sample_parsed(parsed, t)) for t in positions]
end

"""
	lighten(color, frac::Real) -> String

Mix `color` towards white by the fraction `frac` (`0` returns the colour, `1` white),
in sRGB, keeping its alpha. Equivalent to drawing the colour at opacity `1 - frac`
over a white background.

# Arguments
- `color`: a CSS colour string (`"red"`, `"#1f77b4"`, `"rgb(…)"`, `"rgba(…)"`, …),
  a matplotlib grey level (a numeric string in `[0, 1]`: `"0.35"` is `"#595959"`),
  a `Symbol`, or a Colors.jl `Colorant`.
- `frac::Real`: mixing fraction in `[0, 1]`; anything else throws an `ArgumentError`.

# Returns
`"#RRGGBB"`, or `"rgba(r,g,b,a)"` when the colour is translucent.

# Example
```julia
lighten("#000000", 0.5)              # "#808080"
fill = lighten("#1f77b4", 0.7)       # pale fill for a band behind a line
```
"""
function lighten(color, frac::Real)
	f = _checked_unit_fraction(frac, "lighten", "frac")
	r, g, b, a = _parse_color(color, "lighten")
	return _rgba_string((r + (1 - r) * f, g + (1 - g) * f, b + (1 - b) * f, a))
end

"""
	discrete_colormap(colors::AbstractVector) -> Vector{Tuple{Float64,String}}

Build a stepped colorscale (matplotlib `ListedColormap`) in which each of the `k`
colours fills an equal share of `[0, 1]`: `[(0, c1), (1/k, c1), (1/k, c2), …, (1, ck)]`.

# Arguments
- `colors::AbstractVector`: one or more colours (strings, symbols or Colorants).
  An empty vector throws an `ArgumentError`.

# Returns
A `Vector{Tuple{Float64,String}}` with `2k` stops, usable as `colorscale=`. At a
step boundary the colour of the upper bin applies.

# Example
```julia
cs = discrete_colormap(["#2166ac", "#f7f7f7", "#b2182b"])
plot_heatmap(rand(20, 20); colorscale = cs)
discrete_colormap(colormap_colors("viridis", 5))   # five-band viridis
```
"""
function discrete_colormap(colors::AbstractVector)
	k = length(colors)
	k == 0 && throw(ArgumentError("discrete_colormap: at least one colour is required."))
	hexes = [_color_hex(c; who = "discrete_colormap") for c in colors]
	stops = Tuple{Float64,String}[]
	sizehint!(stops, 2k)
	for i in 1:k
		push!(stops, ((i - 1) / k, hexes[i]))
		push!(stops, (i == k ? 1.0 : i / k, hexes[i]))
	end
	return stops
end

#endregion

#region Defaults from the figure / template

_colour_layout(fig::Layout) = fig
_colour_layout(fig::SubplotFigure) = getproperty(fig, :plot).layout
_colour_layout(fig) = _plot_layout(fig)

# A Template object for a layout `template` value, or `nothing` when it is not
# a registered template (plotly.js ignores unknown template names too).
function _template_object(template)
	template isa PlotlyBase.Template && return template
	(template isa AbstractString || template isa Symbol) || return nothing
	name = strip(String(template))
	isempty(name) && return nothing
	Symbol(name) in keys(PlotlyBase.templates) && return PlotlyBase.templates[Symbol(name)]
	parts = strip.(split(name, '+'))
	(length(parts) > 1 && all(p -> !isempty(p) && Symbol(p) in keys(PlotlyBase.templates), parts)) ||
		return nothing
	return PlotlyBase.templates[join(parts, '+')]
end

_attr_fields(x::PlotlyBase.PlotlyAttribute) = x.fields
_attr_fields(x::Layout) = x.fields
_attr_fields(x::AbstractDict) = x
_attr_fields(x) = nothing

function _field(container, key::Symbol)
	fields = _attr_fields(container)
	fields === nothing && return nothing
	return get(fields, key, get(fields, String(key), nothing))
end

_nonempty_vector(v) = v isa AbstractVector && !isempty(v) ? v : nothing

"""
	_default_trace_color(fig, index::Integer) -> String

The colour plotly.js gives the trace at 1-based position `index` of `fig.data`
when the trace sets none: `layout.colorway`, else the layout template's colorway,
else plotly.js's default (D3 category10) list, cycled. `fig` is a `Plot`,
`SyncPlot`, `SubplotFigure`, staged mutation or `Layout`.
"""
function _default_trace_color(fig, index::Integer)
	index >= 1 || throw(ArgumentError("_default_trace_color: `index` must be at least 1; got $(index)."))
	layout = _colour_layout(fig)
	colorway = _nonempty_vector(_field(layout, :colorway))
	if colorway === nothing
		template = _template_object(_field(layout, :template))
		template === nothing || (colorway = _nonempty_vector(_field(template.layout, :colorway)))
	end
	colorway === nothing && (colorway = _PLOTLYJS_DEFAULT_COLORWAY)
	return _color_hex(colorway[mod1(index, length(colorway))]; who = "_default_trace_color")
end

"""
	_template_colorscale(fig_or_template = nothing; trace_type = "heatmap") -> Vector{Vector{Any}}

Expanded stops of the colorscale a template applies to a `trace_type` trace that
sets no colorscale: the template's trace default, else its
`layout.colorscale.sequential`. `fig_or_template` is a figure (its layout
template is used), a `Template`, a template name, or `nothing` for the package
default template (`get_default_template()`). Throws when the template defines
neither.
"""
function _template_colorscale(fig_or_template = nothing; trace_type::AbstractString = "heatmap")
	template = if fig_or_template === nothing
		_resolve_template(get_default_template())
	elseif fig_or_template isa PlotlyBase.Template || fig_or_template isa AbstractString ||
			fig_or_template isa Symbol
		_template_object(fig_or_template)
	else
		_template_object(_field(_colour_layout(fig_or_template), :template))
	end
	if template !== nothing
		trace_defaults = get(template.data, Symbol(trace_type), nothing)
		if trace_defaults isa AbstractVector && !isempty(trace_defaults)
			scale = _field(first(trace_defaults), :colorscale)
			scale === nothing || return _colorscale_stops(scale; who = "_template_colorscale")
		end
		sequential = _field(_field(template.layout, :colorscale), :sequential)
		sequential === nothing || return _colorscale_stops(sequential; who = "_template_colorscale")
	end
	throw(ArgumentError(
		"_template_colorscale: the template defines no default colorscale for $(trace_type) traces; pass an explicit colorscale.",
	))
end

#endregion

#region Colour norms

function _normalize_colornorm(colornorm, who::AbstractString)
	(colornorm isa Symbol || colornorm isa AbstractString) || throw(ArgumentError(
		"$(who): `colornorm` must be :linear or :log; got $(repr(colornorm)).",
	))
	norm = Symbol(lowercase(strip(String(colornorm))))
	norm in (:linear, :log) || throw(ArgumentError("$(who): `colornorm` must be :linear or :log; got $(repr(colornorm))."))
	return norm
end

function _checked_real_vector(v, who::AbstractString, name::AbstractString)
	(v isa AbstractVector || v isa Tuple) || throw(ArgumentError(
		"$(who): `$(name)` must be a vector of finite numbers; got $(typeof(v)).",
	))
	out = Vector{Float64}(undef, length(v))
	for (i, x) in enumerate(v)
		(x isa Real && !(x isa Bool) && isfinite(x)) || throw(ArgumentError(
			"$(who): `$(name)` must contain finite numbers; entry $(i) is $(repr(x)).",
		))
		out[i] = Float64(x)
	end
	return out
end

# Compact plain-text number for colorbar labels: "0.05", "250", "2×10<sup>-7</sup>".
function _format_colorbar_number(v::Float64)
	v == 0 && return "0"
	r = round(v; sigdigits = 4)
	if 1e-4 <= abs(r) < 1e6
		return isinteger(r) ? string(Int(r)) : string(r)
	end
	exponent = floor(Int, log10(abs(r)))
	mantissa = round(r / 10.0^exponent; sigdigits = 4)
	if abs(mantissa) >= 10
		mantissa /= 10
		exponent += 1
	end
	mtext = isinteger(mantissa) ? string(Int(mantissa)) : string(mantissa)
	return mtext == "1" ? "10<sup>$(exponent)</sup>" :
		mtext == "-1" ? "-10<sup>$(exponent)</sup>" : "$(mtext)×10<sup>$(exponent)</sup>"
end

# Label of a tick at data value `v` on a log colorbar: exact decades are
# "10<sup>k</sup>" (HTML, no MathJax needed); other values use the compact form.
function _log_tick_label(v::Float64)
	exponent = log10(v)
	k = round(Int, exponent)
	isapprox(exponent, k; atol = 1e-9) && return "10<sup>$(k)</sup>"
	return _format_colorbar_number(v)
end

const _LOG_TICK_TOLERANCE = 1e-9
const _MAX_LOG_DECADE_TICKS = 9

# Tick positions (log10 units) and labels for a log colorbar spanning [lo, hi].
function _log_colorbar_ticks(lo::Float64, hi::Float64)
	first_decade = ceil(Int, lo - _LOG_TICK_TOLERANCE)
	last_decade = floor(Int, hi + _LOG_TICK_TOLERANCE)
	ndecades = last_decade - first_decade + 1
	if ndecades >= 2
		stride = max(1, cld(ndecades - 1, _MAX_LOG_DECADE_TICKS - 1))
		decades = [k for k in first_decade:last_decade if mod(k, stride) == 0]
		length(decades) >= 2 || (decades = collect(first_decade:stride:last_decade))
		return Float64.(decades), ["10<sup>$(k)</sup>" for k in decades]
	end
	# Less than two decades: add 1-2-5 (then 1…9) sub-decade ticks.
	for mantissas in ((1, 2, 5), (1, 2, 3, 4, 5, 6, 7, 8, 9))
		positions = Float64[]
		labels = String[]
		for exponent in (floor(Int, lo) - 1):(ceil(Int, hi) + 1), m in mantissas
			position = log10(m) + exponent
			if lo - _LOG_TICK_TOLERANCE <= position <= hi + _LOG_TICK_TOLERANCE
				push!(positions, position)
				push!(labels, m == 1 ? "10<sup>$(exponent)</sup>" : "$(m)×10<sup>$(exponent)</sup>")
			end
		end
		length(positions) >= 2 && return positions, labels
	end
	# A range narrower than one 1…9 step: label its ends.
	positions = lo == hi ? [lo] : [lo, hi]
	return positions, [_format_colorbar_number(10.0^p) for p in positions]
end

# log10 of the colour values: non-positive values become `floor_value` (NaN
# when there is no explicit positive crange), missing/NaN/±Inf become NaN.
function _log10_color_values(values::AbstractArray, floor_value::Float64, who::AbstractString)
	return map(values) do v
		v === missing && return NaN
		(v isa Real && !(v isa Bool)) || throw(ArgumentError(
			"$(who): colour values must be real numbers for colornorm=:log; got $(repr(v)).",
		))
		isnan(v) && return NaN
		v == Inf && return NaN
		v <= 0 && return floor_value
		return log10(Float64(v))
	end
end

function _finite_extrema(values)
	lo, hi = Inf, -Inf
	for v in values
		if v isa Real && isfinite(v)
			lo = min(lo, Float64(v))
			hi = max(hi, Float64(v))
		end
	end
	return isfinite(lo) ? (lo, hi) : nothing
end

# Stops for a two-slope norm: the colour at t = 0.5 moves to `p`, the lower
# half is compressed/stretched onto [0, p] and the upper half onto [p, 1].
function _two_slope_stops(stops::Vector{Vector{Any}}, p::Float64)
	parsed = _parsed_colorscale(stops)
	has_half = any(s -> Float64(s[1]) == 0.5, stops)
	midpoint = has_half ? nothing : _rgba_string(_sample_parsed(parsed, 0.5))
	remap(t) = clamp(t <= 0.5 ? 2p * t : p + (t - 0.5) * 2 * (1 - p), 0.0, 1.0)
	out = Vector{Vector{Any}}()
	for s in stops
		t = Float64(s[1])
		if midpoint !== nothing && t > 0.5
			push!(out, Any[p, midpoint])
			midpoint = nothing
		end
		push!(out, Any[remap(t), s[2]])
	end
	out[1][1] = 0.0
	out[end][1] = 1.0
	return out
end

function _concrete_norm_stops(stops, fallback_stops, who::AbstractString)
	if _is_unset_colorscale(stops)
		source = fallback_stops === nothing ? _template_colorscale(nothing) : fallback_stops
		return _colorscale_stops(source; who)
	end
	return _colorscale_stops(stops; who)
end

"""
	_apply_color_norm(values; crange = [0, 0], cmid = nothing, colornorm = :linear, levels = nothing,
	                  stops = "", ticks = nothing, ticklabels = nothing, fallback_stops = nothing,
	                  who = "_apply_color_norm")
	    -> (values, cmin, cmax, stops, tickvals, ticktext, customdata, cmid)

Map colour data, limits and colorscale through a matplotlib-style norm. Callers write
`values` as the trace colour data (z / intensity / surfacecolor / marker.color),
`cmin`/`cmax` (when not `nothing`) as zmin/zmax or cmin/cmax, `cmid` (when not
`nothing`) as zmid/cmid, `stops` as the colorscale (unless `""`), and
`tickvals`/`ticktext` (when not `nothing`) into the colorbar (`_colorbar_attr`).
When `customdata` is not `nothing` it holds the raw values: set it on the trace and
show `%{customdata:.3g}` in the hovertemplate.

- `crange`: `[0, 0]`/`(0, 0)`/`nothing` is automatic; otherwise `lo < hi`.
- `cmid` (linear only): with an automatic crange it is returned as `cmid` (plotly
  zmid semantics); with an explicit crange it must lie strictly inside and the stops
  are remapped piecewise-linearly so colour 0.5 sits at `(cmid - lo)/(hi - lo)`
  (TwoSlopeNorm). A centred cmid leaves the stops unchanged.
- `colornorm = :log`: values become `log10(v)`; `v ≤ 0` becomes NaN, or
  `log10(crange[1])` when an explicit positive crange is given; cmin/cmax become
  `log10.(crange)`; ticks sit on integer decades labelled `"10<sup>k</sup>"`
  (1-2-5 sub-decade ticks when the range spans less than two decades; thinned to at
  most $(_MAX_LOG_DECADE_TICKS) decades).
- `levels` (k+1 strictly increasing boundaries, BoundaryNorm): k colours sampled at
  t = (i - 0.5)/k, a stepped colorscale with steps at `(b_i - b_0)/(b_k - b_0)`
  (2k stops), cmin = b_0, cmax = b_k, ticks at the boundaries. Combines with
  `:log` (boundaries in log10). Excludes an explicit crange and `cmid`.
- `ticks`/`ticklabels`: user colorbar ticks in DATA units (log10-transformed under
  `:log`); `ticklabels` needs `ticks` of the same length.
- `stops`: the resolved colorscale (anything `_resolve_colorscale` accepts). When it
  is unset and remapping is needed, `fallback_stops` (default: the package default
  template's heatmap colorscale) is used.

Linear data are returned as the same object (no copy); `:log` returns a new array.
"""
function _apply_color_norm(
	values;
	crange = [0, 0],
	cmid = nothing,
	colornorm = :linear,
	levels = nothing,
	stops = "",
	ticks = nothing,
	ticklabels = nothing,
	fallback_stops = nothing,
	who::AbstractString = "_apply_color_norm",
)
	norm = _normalize_colornorm(colornorm, who)
	(values === nothing || values isa AbstractArray) || throw(ArgumentError(
		"$(who): colour values must be an array; got $(typeof(values)).",
	))
	limits = _checked_range(crange, who, "crange")
	if limits !== nothing
		(limits[1] isa Real && limits[2] isa Real) || throw(ArgumentError(
			"$(who): `crange` bounds must be real numbers; got $(repr(crange)).",
		))
		limits = (Float64(limits[1]), Float64(limits[2]))
		limits[1] < limits[2] || throw(ArgumentError(
			"$(who): `crange` lower bound must be less than the upper bound; got $(repr(crange)).",
		))
	end
	if cmid !== nothing
		(cmid isa Real && !(cmid isa Bool) && isfinite(cmid)) ||
			throw(ArgumentError("$(who): `cmid` must be a finite number; got $(repr(cmid))."))
		norm === :log && throw(ArgumentError("$(who): `cmid` cannot be combined with colornorm=:log."))
		levels === nothing || throw(ArgumentError("$(who): `cmid` cannot be combined with `levels`."))
		if limits !== nothing && !(limits[1] < cmid < limits[2])
			throw(ArgumentError(
				"$(who): `cmid` = $(cmid) must lie strictly inside `crange` = $(repr(crange)).",
			))
		end
	end
	boundaries = nothing
	if levels !== nothing
		boundaries = _checked_real_vector(levels, who, "levels")
		length(boundaries) >= 2 || throw(ArgumentError(
			"$(who): `levels` needs at least two boundaries (one colour band); got $(length(boundaries)).",
		))
		all(i -> boundaries[i] < boundaries[i + 1], 1:(length(boundaries) - 1)) || throw(ArgumentError(
			"$(who): `levels` must be strictly increasing; got $(repr(levels)).",
		))
		limits === nothing || throw(ArgumentError(
			"$(who): `levels` already fixes the colour limits; do not also pass `crange`.",
		))
		norm === :log && boundaries[1] <= 0 && throw(ArgumentError(
			"$(who): `levels` must be positive for colornorm=:log; got $(repr(levels)).",
		))
	end
	user_ticks = ticks === nothing ? nothing : _checked_real_vector(ticks, who, "colorbar ticks")
	if ticklabels !== nothing
		user_ticks === nothing && throw(ArgumentError("$(who): colorbar tick labels need `ticks` of the same length."))
		(ticklabels isa AbstractVector || ticklabels isa Tuple) || throw(ArgumentError(
			"$(who): colorbar tick labels must be a vector; got $(typeof(ticklabels)).",
		))
		length(ticklabels) == length(user_ticks) || throw(ArgumentError(
			"$(who): $(length(ticklabels)) colorbar tick labels for $(length(user_ticks)) ticks.",
		))
	end
	norm === :log && user_ticks !== nothing && any(<=(0), user_ticks) && throw(ArgumentError(
		"$(who): colorbar ticks must be positive for colornorm=:log; got $(repr(ticks)).",
	))
	if norm === :log && limits !== nothing && limits[1] <= 0
		throw(ArgumentError("$(who): colornorm=:log needs a positive `crange`; got $(repr(crange))."))
	end
	resolved = _resolve_colorscale(stops; who)
	out_stops = resolved.reversescale ? _colorscale_stops(stops; who) : resolved.scale

	# --- values, limits and default ticks --------------------------------------
	out_values = values
	customdata = nothing
	cmin = cmax = nothing
	cmid_out = nothing
	tickvals = nothing
	ticktext = nothing
	if norm === :log
		floor_value = limits === nothing ? NaN : log10(limits[1])
		if values !== nothing
			out_values = _log10_color_values(values, floor_value, who)
			customdata = values
		end
		if boundaries === nothing
			if limits === nothing
				values === nothing && throw(ArgumentError(
					"$(who): colornorm=:log needs colour values or an explicit `crange`.",
				))
				extent = _finite_extrema(out_values)
				extent === nothing && throw(ArgumentError(
					"$(who): colornorm=:log needs at least one positive finite value (or an explicit positive `crange`).",
				))
				tickvals, ticktext = _log_colorbar_ticks(extent...)
			else
				cmin, cmax = log10(limits[1]), log10(limits[2])
				tickvals, ticktext = _log_colorbar_ticks(cmin, cmax)
			end
		end
	elseif limits !== nothing
		cmin, cmax = limits
		if cmid !== nothing
			p = (cmid - cmin) / (cmax - cmin)
			p == 0.5 || (out_stops = _two_slope_stops(_concrete_norm_stops(stops, fallback_stops, who), p))
		end
	elseif cmid !== nothing
		cmid_out = cmid
	end
	if boundaries !== nothing
		positions_in = norm === :log ? log10.(boundaries) : boundaries
		k = length(boundaries) - 1
		parsed = _parsed_colorscale(_concrete_norm_stops(stops, fallback_stops, who))
		band_colours = [_rgba_string(_sample_parsed(parsed, (i - 0.5) / k)) for i in 1:k]
		span = positions_in[end] - positions_in[1]
		steps = [i == 1 ? 0.0 : i == k + 1 ? 1.0 : (positions_in[i] - positions_in[1]) / span for i in 1:(k + 1)]
		out_stops = Vector{Vector{Any}}()
		for i in 1:k
			push!(out_stops, Any[steps[i], band_colours[i]])
			push!(out_stops, Any[steps[i + 1], band_colours[i]])
		end
		cmin, cmax = positions_in[1], positions_in[end]
		tickvals = collect(positions_in)
		ticktext = norm === :log ? [_log_tick_label(b) for b in boundaries] : nothing
	end
	if user_ticks !== nothing
		if norm === :log
			tickvals = log10.(user_ticks)
			ticktext = ticklabels === nothing ? [_log_tick_label(v) for v in user_ticks] :
				String[string(l) for l in ticklabels]
		else
			tickvals = user_ticks
			ticktext = ticklabels === nothing ? nothing : String[string(l) for l in ticklabels]
		end
	end
	return (
		values = out_values,
		cmin = cmin,
		cmax = cmax,
		stops = out_stops,
		tickvals = tickvals,
		ticktext = ticktext,
		customdata = customdata,
		cmid = cmid_out,
	)
end

#endregion

#region Colorbar builders

function _optional_size(value, who::AbstractString, name::AbstractString)
	(value isa Real && !(value isa Bool) && isfinite(value) && value >= 0) || throw(ArgumentError(
		"$(who): `$(name)` must be a finite number ≥ 0 (0 = automatic); got $(repr(value)).",
	))
	return value
end

function _optional_position(value, who::AbstractString, name::AbstractString)
	value === nothing && return nothing
	(value isa Real && !(value isa Bool) && isfinite(value)) || throw(ArgumentError(
		"$(who): `$(name)` must be a finite number or nothing; got $(repr(value)).",
	))
	return value
end

"""
	_colorbar_attr(; title = "", ticks = nothing, ticklabels = nothing, len = 0, thickness = 0,
	               x = nothing, y = nothing, who = "_colorbar_attr") -> Union{Nothing,PlotlyAttribute}

Build a plotly `colorbar` attribute from the colorbar keywords, or `nothing` when
every argument is at its sentinel (nothing to write). `title` is stored as
`title.text` and written verbatim, as are `ticklabels`: callers pass user text
through `_label` first. `ticks` (finite numbers, in the trace's colour units) set
`tickmode = "array"`/`tickvals`; `ticklabels` (same length as `ticks`) set
`ticktext`. `len > 0` sets `len` with `lenmode = "fraction"`, `thickness > 0` sets
the pixel thickness, and `x`/`y` set the position (paper fractions).
"""
function _colorbar_attr(;
	title::AbstractString = "",
	ticks = nothing,
	ticklabels = nothing,
	len::Real = 0,
	thickness::Real = 0,
	x = nothing,
	y = nothing,
	who::AbstractString = "_colorbar_attr",
)
	fields = Dict{Symbol,Any}()
	title_value = _title_attr(title)
	title_value === nothing || (fields[:title] = title_value)
	if ticks !== nothing
		fields[:tickmode] = "array"
		fields[:tickvals] = _checked_real_vector(ticks, who, "ticks")
	end
	if ticklabels !== nothing
		ticks === nothing && throw(ArgumentError("$(who): `ticklabels` need `ticks` of the same length."))
		(ticklabels isa AbstractVector || ticklabels isa Tuple) || throw(ArgumentError(
			"$(who): `ticklabels` must be a vector; got $(typeof(ticklabels)).",
		))
		length(ticklabels) == length(fields[:tickvals]) || throw(ArgumentError(
			"$(who): $(length(ticklabels)) `ticklabels` for $(length(fields[:tickvals])) `ticks`.",
		))
		fields[:ticktext] = String[string(label) for label in ticklabels]
	end
	length_value = _optional_size(len, who, "len")
	if length_value > 0
		fields[:len] = length_value
		fields[:lenmode] = "fraction"
	end
	thickness_value = _optional_size(thickness, who, "thickness")
	thickness_value > 0 && (fields[:thickness] = thickness_value)
	x_value = _optional_position(x, who, "x")
	x_value === nothing || (fields[:x] = x_value)
	y_value = _optional_position(y, who, "y")
	y_value === nothing || (fields[:y] = y_value)
	isempty(fields) && return nothing
	return attr(; fields...)
end

const _COLORAXIS_ID_REGEX = r"^coloraxis([2-9]|[1-9][0-9]+)?$"
const _XAXIS_REF_REGEX = r"^x([2-9]|[1-9][0-9]+)?$"
const _YAXIS_REF_REGEX = r"^y([2-9]|[1-9][0-9]+)?$"

# `:shared` (or "shared") means the first shared axis "coloraxis"; otherwise a
# plotly coloraxis id ("coloraxis", "coloraxis2", …).
function _normalize_coloraxis(coloraxis, who::AbstractString)
	(coloraxis isa Symbol || coloraxis isa AbstractString) || throw(ArgumentError(
		"$(who): `coloraxis` must be :shared or a coloraxis id such as \"coloraxis2\"; got $(repr(coloraxis)).",
	))
	id = strip(String(coloraxis))
	id == "shared" && return "coloraxis"
	occursin(_COLORAXIS_ID_REGEX, id) || throw(ArgumentError(
		"$(who): `coloraxis` must be :shared or a coloraxis id such as \"coloraxis2\"; got $(repr(coloraxis)).",
	))
	return String(id)
end

"""
	_colorbar_carrier_trace(; stops = nothing, cmin, cmax, showscale = true, colorbar = nothing,
	                        coloraxis = nothing, xref = "x", yref = "y", who = "_colorbar_carrier_trace")
	    -> GenericTrace

An invisible `scatter` whose only job is to draw a colorbar for colours that were
sampled in Julia (plot_polygons, binned streamlines, …): `x = y = [null]` (no point,
no axis extent), `marker.color = [cmin, cmax]`, `hoverinfo = "skip"`,
`showlegend = false`, on axes `xref`/`yref` ("x", "x2", …).

Without `coloraxis` the marker carries `colorscale` (`stops`, required: anything
`_resolve_colorscale` accepts except unset), `cmin`, `cmax`, `showscale` and the
optional `colorbar` attribute. With `coloraxis` (`:shared` or "coloraxisN") it
carries only `marker.coloraxis`; the scale and colorbar then live on
`layout.<coloraxis>`, so passing `colorbar` throws. `cmin < cmax`, both finite.
"""
function _colorbar_carrier_trace(;
	stops = nothing,
	cmin::Real,
	cmax::Real,
	showscale::Bool = true,
	colorbar = nothing,
	coloraxis = nothing,
	xref::AbstractString = "x",
	yref::AbstractString = "y",
	who::AbstractString = "_colorbar_carrier_trace",
)
	(!(cmin isa Bool) && !(cmax isa Bool) && isfinite(cmin) && isfinite(cmax) && cmin < cmax) ||
		throw(ArgumentError("$(who): need finite `cmin` < `cmax`; got cmin = $(repr(cmin)), cmax = $(repr(cmax))."))
	occursin(_XAXIS_REF_REGEX, xref) ||
		throw(ArgumentError("$(who): `xref` must be an x-axis id such as \"x\" or \"x2\"; got $(repr(xref))."))
	occursin(_YAXIS_REF_REGEX, yref) ||
		throw(ArgumentError("$(who): `yref` must be a y-axis id such as \"y\" or \"y2\"; got $(repr(yref))."))
	(colorbar === nothing || colorbar isa PlotlyBase.PlotlyAttribute || colorbar isa AbstractDict) ||
		throw(ArgumentError("$(who): `colorbar` must be an attr(...) or nothing; got $(typeof(colorbar))."))
	marker = Dict{Symbol,Any}(:color => Any[cmin, cmax])
	if coloraxis !== nothing
		id = _normalize_coloraxis(coloraxis, who)
		colorbar === nothing || throw(ArgumentError(
			"$(who): a carrier bound to $(id) uses layout.$(id).colorbar; do not pass `colorbar`.",
		))
		marker[:coloraxis] = id
	else
		_is_unset_colorscale(stops) &&
			throw(ArgumentError("$(who): `stops` (the colorscale the colours were sampled from) is required."))
		resolved = _resolve_colorscale(stops; who)
		marker[:colorscale] = resolved.scale
		resolved.reversescale && (marker[:reversescale] = true)
		marker[:cmin] = cmin
		marker[:cmax] = cmax
		marker[:showscale] = showscale
		colorbar === nothing || (marker[:colorbar] = colorbar)
	end
	return scatter(;
		x = Any[_GAP],
		y = Any[_GAP],
		mode = "markers",
		marker = attr(; marker...),
		hoverinfo = "skip",
		showlegend = false,
		name = "",
		xaxis = String(xref),
		yaxis = String(yref),
	)
end

#endregion
