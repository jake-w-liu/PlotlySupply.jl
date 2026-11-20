# PlotlySupply 2.0 scientific-plotting extensions: title!, panel_labels!, legend extensions, legend_entry!.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_TEXT_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# The three mutators only append a trace (`legend_entry!`) or write layout
# (`title!`, `panel_labels!`), so their Plot/SyncPlot wrappers may take the
# append-only fast transaction path. Each also has an explicit SubplotFigure
# method that runs through `_transactional_subplot_mutation!`.
#
# The legend placement machinery (`_legend_placement`, `_apply_subplot_legends!`,
# `_legend_dedupe!`, the `set_legend!`/`subplot_legends!` methods) lives next to
# the 1.x legend code in api.jl; this file provides the option validation
# (`_legend_options`) and the F15 extension fields (`_legend_layout_ext`) those
# methods share.

const _SCI_TEXT_MUTATORS = (:title!, :panel_labels!, :legend_entry!)

export title!, panel_labels!, legend_entry!

# ─────────────────────────────────────────────────────────────────────────────
# Shared validation
# ─────────────────────────────────────────────────────────────────────────────

function _text_reject_show(show, who::AbstractString)
	show === nothing && return nothing
	throw(ArgumentError(
		"$(who): `show` is not supported; $(who) modifies an existing figure. " *
		"Open a window for it with `to_syncplot(fig)` (or create the figure " *
		"with `show=true`).",
	))
end

function _text_real(value, who::AbstractString, name::AbstractString; nonnegative::Bool = true)
	(value isa Real && !(value isa Bool) && isfinite(value) && (!nonnegative || value >= 0)) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a " * (nonnegative ? "non-negative " : "") *
			"finite number; got $(repr(value)).",
		))
	return Float64(value)
end

# A pair given as a 2-tuple or a 2-element vector of finite reals.
function _text_pair(value, who::AbstractString, name::AbstractString; nonnegative::Bool = false)
	ok = (value isa Tuple || value isa AbstractVector) && length(value) == 2
	ok || throw(ArgumentError(
		"$(who): `$(name)` must be a 2-tuple (or 2-element vector) of numbers; got $(repr(value)).",
	))
	a = _text_real(value[1], who, "$(name)[1]"; nonnegative = nonnegative)
	b = _text_real(value[2], who, "$(name)[2]"; nonnegative = nonnegative)
	return (a, b)
end

# Plotly emits integral sizes as integers in JSON (`12`, not `12.0`).
_text_number(x::Real) = (isinteger(x) && abs(x) < 2.0^53) ? Int(x) : Float64(x)

# `_label(s)` with its mathtext errors (unbalanced `$`, HTML tags around
# math, …) reported under the public function's name.
function _text_checked_label(s::AbstractString, who::AbstractString; align::Symbol = :c)
	try
		return _label(s; align = align)
	catch err
		err isa ArgumentError || rethrow()
		throw(ArgumentError("$(who): invalid label $(repr(String(s))): $(err.msg)"))
	end
end

# ─────────────────────────────────────────────────────────────────────────────
# Text extent estimates (tight_layout!, legend columns, decoration stacking)
# ─────────────────────────────────────────────────────────────────────────────
#
# Text is measured without the renderer, from advance widths measured in it
# (D19). In the export window (Electron's Chromium, plotly.js 2.35.2, MathJax
# 2.7.9) every character of `_TEXT_ADVANCE_CHARS` was measured, for each
# family below, with canvas `measureText` at 100 px, regular and bold (the
# shaping SVG <text> gets), with the family's CSS x-height (the `ex` MathJax
# sizes math by); and for the Latin-Modern and STIX-Web MathJax fonts, the
# width (math em) of the SVG box MathJax draws for each math token, with the
# spacing TeX puts around it between two ordinary letters; and the pair
# adjustment (kerning, ligatures) of every pair of printable ASCII characters
# and typographic quotes and dashes, width("ab") - width("a") - width("b").
# Values are rounded up to 1/1000 em, so a run's estimate is never below the
# drawn width. test/mathjax_text_metrics.jl draws random strings under every
# preset and checks the estimates against the renderer.

# Metrics of one font family: its CSS x-height (em), the advance (em) of each
# character of `_TEXT_ADVANCE_CHARS`, regular and bold, how far its ink
# reaches left of its origin and right of its advance (em, `ink_left`/
# `ink_right`, nonnegative): plotly.js sizes text by its bounding box, which
# Chromium takes over the ink as well as the advances (a leading "j" of Times
# reaches 0.08 em to the left), and the pair adjustments (`kern`, em; "Y,"
# is -0.129 em in Times New Roman). `fallback` is the widest letter, used for
# a character the table does not list.
struct _TextFamilyMetrics
	name::String
	ex::Float64
	regular::Vector{Float64}
	bold::Vector{Float64}
	ink_left::Vector{Float64}
	ink_right::Vector{Float64}
	ink_left_bold::Vector{Float64}
	ink_right_bold::Vector{Float64}
	kern::Dict{Tuple{Char, Char}, Float64}
	kern_bold::Dict{Tuple{Char, Char}, Float64}
	fallback::Float64
	fallback_bold::Float64
end

# Characters the family tables list: printable ASCII, then CJK and Hangul
# samples, typographic symbols, Greek letters and arrows.
const _TEXT_ADVANCE_CHARS = " !\"#\$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~日本語한국°±×÷µ·–—‘’“”…€£¥§©®™ÅαβγδεθλμπσφωΩΔ√∞≤≥≈≠→←↔"
const _TEXT_ADVANCE_INDEX = Dict{Char, Int}(c => k for (k, c) in enumerate(_TEXT_ADVANCE_CHARS))

# `ink_regular`/`ink_bold`: the characters whose ink overhangs, with the
# overhangs (1/1000 em) on the left and on the right.
# `kern_regular`/`kern_bold`: the pairs (two characters each, concatenated)
# and their adjustments (1/1000 em).
function _text_family_metrics(name::String, ex::Float64, regular::Vector{Int16}, bold::Vector{Int16},
	ink_regular::Tuple{String, Vector{Int16}, Vector{Int16}}, ink_bold::Tuple{String, Vector{Int16}, Vector{Int16}},
	kern_regular::Tuple{String, Vector{Int16}}, kern_bold::Tuple{String, Vector{Int16}})
	n = length(_TEXT_ADVANCE_CHARS)
	(length(regular) == n && length(bold) == n) ||
		error("text metrics of $(name): $(length(regular))/$(length(bold)) advances for $(n) characters")
	function overhangs(spec)
		chars, left, right = spec
		(length(chars) == length(left) == length(right)) ||
			error("text metrics of $(name): $(length(left))/$(length(right)) overhangs for $(length(chars)) characters")
		l = zeros(n)
		r = zeros(n)
		for (c, a, b) in zip(chars, left, right)
			k = _TEXT_ADVANCE_INDEX[c]
			l[k] = a / 1000
			r[k] = b / 1000
		end
		return l, r
	end
	il, ir = overhangs(ink_regular)
	bl, br = overhangs(ink_bold)
	function pairs(spec)
		chars, values = collect(spec[1]), spec[2]
		length(chars) == 2 * length(values) ||
			error("text metrics of $(name): $(length(values)) pair adjustments for $(length(chars)) characters")
		return Dict((chars[2k - 1], chars[2k]) => values[k] / 1000 for k in eachindex(values))
	end
	r = regular ./ 1000
	b = bold ./ 1000
	letters = [k for (k, c) in enumerate(_TEXT_ADVANCE_CHARS) if 'A' <= c <= 'Z' || 'a' <= c <= 'z']
	return _TextFamilyMetrics(name, ex, r, b, il, ir, bl, br, pairs(kern_regular), pairs(kern_bold),
		maximum(r[letters]), maximum(b[letters]))
end

# The elementwise maximum of `families`: the metrics assumed for a family
# that was not measured (a pair one family does not adjust counts 0 there).
function _text_family_max(name::String, families)
	elementwise(field) = reduce((a, b) -> max.(a, b), (getfield(f, field) for f in families))
	function pairs(field)
		out = Dict{Tuple{Char, Char}, Float64}()
		for pair in union((keys(getfield(f, field)) for f in families)...)
			value = maximum(f -> get(getfield(f, field), pair, 0.0), families)
			value == 0 || (out[pair] = value)
		end
		return out
	end
	return _TextFamilyMetrics(
		name, maximum(f.ex for f in families), elementwise(:regular), elementwise(:bold),
		elementwise(:ink_left), elementwise(:ink_right), elementwise(:ink_left_bold), elementwise(:ink_right_bold),
		pairs(:kern), pairs(:kern_bold),
		maximum(f.fallback for f in families), maximum(f.fallback_bold for f in families),
	)
end

# Metrics of one MathJax SVG font, in math em: math-mode letters and digits
# (`italic`), text-mode characters (`roman`, `\text{…}` without
# `inherit_text_font`, and `\mathrm`), math-mode punctuation and operators
# with their spacing between two letters (`ops`), named commands (`commands`,
# symbols with their spacing), the text-mode space and the radical sign.
struct _TextMathMetrics
	name::String
	italic::Dict{Char, Float64}
	roman::Dict{Char, Float64}
	ops::Dict{Char, Float64}
	commands::Dict{String, Float64}
	space::Float64
	radical::Float64
end

function _text_math_metrics(name::String; italic, roman, ops, commands, space::Integer, radical::Integer)
	table(chars, values) = (length(chars) == length(values) ||
		error("math metrics of $(name): $(length(values)) values for $(length(chars)) entries");
		Dict(zip(chars, values ./ 1000)))
	return _TextMathMetrics(
		name, table(collect(italic[1]), italic[2]), table(collect(roman[1]), roman[2]),
		table(collect(ops[1]), ops[2]), table(String.(commands[1]), commands[2]),
		space / 1000, radical / 1000,
	)
end

function _text_math_max(name::String, a::_TextMathMetrics, b::_TextMathMetrics)
	merged(x, y) = mergewith(max, x, y)
	return _TextMathMetrics(
		name, merged(a.italic, b.italic), merged(a.roman, b.roman), merged(a.ops, b.ops),
		merged(a.commands, b.commands), max(a.space, b.space), max(a.radical, b.radical),
	)
end

const _TEXT_FAMILY_TIMES_NEW_ROMAN = _text_family_metrics("Times New Roman", 0.4473,
	Int16[
		250, 334, 409, 500, 500, 834, 778, 181, 334, 334, 500, 564, 250, 334, 250, 278, 500, 500, 500,
		500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444, 921, 723, 667, 667, 723, 611,
		557, 723, 723, 334, 390, 723, 611, 890, 723, 723, 557, 723, 667, 557, 611, 723, 723, 944, 723,
		723, 611, 334, 278, 334, 470, 500, 334, 444, 500, 444, 500, 444, 334, 500, 500, 278, 278, 500,
		278, 778, 500, 500, 500, 500, 334, 390, 278, 500, 500, 723, 500, 500, 444, 480, 201, 480, 542,
		1000, 1000, 1000, 1000, 1000, 400, 549, 564, 549, 577, 334, 500, 1000, 334, 334, 444, 444, 1000,
		500, 500, 500, 500, 760, 760, 980, 723, 524, 509, 442, 472, 420, 480, 485, 537, 505, 540, 578,
		659, 744, 644, 549, 713, 549, 549, 549, 549, 1000, 1000, 1000,
	],
	Int16[
		250, 334, 556, 500, 500, 1000, 834, 278, 334, 334, 500, 570, 250, 334, 250, 278, 500, 500, 500,
		500, 500, 500, 500, 500, 500, 500, 334, 334, 570, 570, 570, 500, 931, 723, 667, 723, 723, 667,
		611, 778, 778, 390, 500, 778, 667, 944, 723, 778, 611, 778, 723, 557, 667, 723, 723, 1000, 723,
		723, 667, 334, 278, 334, 582, 500, 334, 500, 557, 444, 557, 444, 334, 500, 557, 278, 334, 557,
		278, 834, 557, 500, 557, 557, 444, 390, 334, 557, 500, 723, 500, 500, 444, 395, 221, 395, 521,
		1000, 1000, 1000, 1000, 1000, 400, 549, 570, 549, 577, 334, 500, 1000, 334, 334, 500, 500, 1000,
		500, 500, 500, 500, 748, 748, 1000, 723, 559, 527, 468, 520, 428, 522, 492, 567, 548, 544, 625,
		731, 801, 627, 549, 713, 549, 549, 549, 549, 1000, 1000, 1000,
	],
	("/KNR\\_bdfjkprt–—€λ", Int16[0, 0, 14, 0, 0, 9, 3, 0, 0, 77, 0, 4, 0, 0, 9, 10, 12, 0], Int16[3, 9, 0, 9, 2, 9, 0, 3, 102, 0, 6, 0, 7, 2, 9, 9, 0, 5]),
	("/KR\\_fjk~–—€™λ", Int16[0, 0, 0, 0, 10, 0, 28, 0, 0, 9, 10, 12, 2, 0], Int16[3, 12, 9, 3, 10, 75, 0, 10, 18, 8, 10, 0, 6, 12]),
	(
		"11ATAVAWAYAvAwAyA’F,F.FALTLVLWLYLyL’P,P.PARTRVRWRYRyT,T-T.T:" *
		"T;TATOTaTcTeTiToTrTsTuTwTyV,V-V.V:V;VAVaVeViVoVrVuVyW,W-W.W:" *
		"W;WAWaWeWiWoWrWuWyY,Y-Y.Y:Y;YAYaYeYiYoYpYqYuYvfff’r,r-r.rgr’" *
		"v,v.w,w.y,y.‘‘’s’t’’",
		Int16[
			-37, -110, -128, -80, -91, -74, -91, -91, -110, -80, -80, -74, -91, -91, -74, -100, -55, -91,
			-110, -110, -91, -60, -80, -55, -55, -40, -74, -91, -74, -49, -55, -80, -18, -69, -69, -69, -35,
			-69, -35, -69, -35, -69, -69, -128, -91, -128, -74, -74, -128, -110, -110, -60, -128, -60, -60,
			-110, -91, -55, -91, -37, -37, -110, -80, -80, -40, -80, -40, -40, -60, -128, -110, -128, -91,
			-91, -110, -100, -100, -55, -100, -91, -110, -110, -100, -18, 56, -40, -20, -55, -18, 38, -64,
			-64, -64, -64, -64, -64, -74, -55, -18, -74,
		],
	),
	(
		"11ATAVAWAYAvAwAyA’F,F.FALTLVLWLYLyL’P,P.PARTRVRWRYRyT,T-T.T:" *
		"T;TATOTaTcTeTiToTrTsTuTwTyV,V-V.V:V;VAVOVaVeViVoVrVuVyW,W-W." *
		"W:W;WAWaWeWiWoWrWuWyY,Y-Y.Y:Y;YAYaYeYiYoYpYqYuYvf’r,r-r.rcre" *
		"rorqr’v,v.w,w.y,y.‘‘’s’’",
		Int16[
			-55, -74, -128, -110, -91, -74, -74, -74, -74, -91, -91, -74, -91, -91, -91, -91, -55, -91, -91,
			-91, -74, -35, -35, -35, -35, -35, -74, -91, -74, -74, -74, -74, -18, -91, -91, -91, -18, -91,
			-74, -91, -91, -74, -74, -128, -74, -128, -91, -91, -128, -20, -91, -91, -37, -91, -74, -91, -91,
			-91, -37, -91, -55, -55, -110, -55, -55, -18, -55, -18, -18, -37, -91, -91, -91, -91, -91, -91,
			-110, -110, -37, -110, -91, -110, -91, -110, 56, -91, -37, -91, -18, -18, -18, -18, 19, -55, -55,
			-55, -55, -55, -55, -74, -37, -74,
		],
	),
)
const _TEXT_FAMILY_TIMES = _text_family_metrics("Times", 0.4487,
	Int16[
		250, 334, 409, 500, 500, 834, 778, 181, 334, 334, 500, 564, 250, 334, 250, 278, 500, 500, 500,
		500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444, 921, 723, 667, 667, 723, 611,
		557, 723, 723, 334, 390, 723, 611, 890, 723, 723, 557, 723, 667, 557, 611, 723, 723, 944, 723,
		723, 611, 334, 278, 334, 470, 500, 334, 444, 500, 444, 500, 444, 334, 500, 500, 278, 278, 500,
		278, 778, 500, 500, 500, 500, 334, 390, 278, 500, 500, 723, 500, 500, 444, 480, 201, 480, 542,
		1000, 1000, 1000, 1000, 1000, 400, 549, 564, 549, 577, 250, 500, 1000, 334, 334, 444, 444, 1000,
		745, 500, 500, 500, 760, 760, 980, 723, 611, 557, 500, 557, 444, 557, 500, 557, 549, 557, 667,
		723, 769, 723, 549, 713, 549, 549, 549, 549, 1000, 1000, 1000,
	],
	Int16[
		250, 334, 556, 500, 500, 1000, 834, 278, 334, 334, 500, 570, 250, 334, 250, 278, 500, 500, 500,
		500, 500, 500, 500, 500, 500, 500, 334, 334, 570, 570, 570, 500, 931, 723, 667, 723, 723, 667,
		611, 778, 778, 390, 500, 778, 667, 944, 723, 778, 611, 778, 723, 557, 667, 723, 723, 1000, 723,
		723, 667, 334, 278, 334, 582, 500, 334, 500, 557, 444, 557, 444, 334, 500, 557, 278, 334, 557,
		278, 834, 557, 500, 557, 557, 444, 390, 334, 557, 500, 723, 500, 500, 444, 395, 221, 395, 521,
		1000, 1000, 1000, 1000, 1000, 400, 549, 570, 549, 577, 250, 500, 1000, 334, 334, 500, 500, 1000,
		745, 500, 500, 500, 748, 748, 1000, 723, 611, 557, 557, 557, 444, 557, 500, 611, 549, 557, 667,
		723, 769, 778, 549, 713, 549, 549, 549, 549, 1000, 1000, 1000,
	],
	("\\`fjrtµ–¥μπ√", Int16[32, 10, 0, 58, 0, 0, 77, 3, 0, 0, 0, 11], Int16[31, 0, 50, 0, 4, 1, 0, 0, 4, 32, 27, 100]),
	("#,/\\`fj~µ–¥πΩ√", Int16[4, 0, 15, 48, 21, 0, 59, 0, 65, 10, 0, 0, 0, 11], Int16[1, 14, 14, 46, 0, 56, 0, 50, 0, 5, 227, 28, 7, 93]),
	(
		"11ATAVAWAYAvAwAyA’F,F.FALTLVLWLYLyL’P,P.PARTRVRWRYRyT,T-T.T:" *
		"T;TATOTaTcTeTiToTrTsTuTwTyV,V-V.V:V;VAVaVeViVoVrVuVyW,W-W.W:" *
		"W;WAWaWeWiWoWrWuWyY,Y-Y.Y:Y;YAYaYeYiYoYpYqYuYvfffiflf’r,r-r." *
		"rgr’v,v.w,w.y,y.‘‘’s’t’’",
		Int16[
			-36, -110, -128, -79, -91, -73, -91, -91, -110, -79, -79, -73, -91, -91, -73, -99, -54, -91,
			-110, -110, -91, -59, -79, -54, -54, -39, -73, -91, -73, -49, -54, -79, -17, -69, -69, -69, -34,
			-69, -34, -69, -34, -69, -69, -128, -91, -128, -73, -73, -128, -110, -110, -59, -128, -59, -59,
			-110, -91, -54, -91, -36, -36, -110, -79, -79, -39, -79, -39, -39, -59, -128, -110, -128, -91,
			-91, -110, -99, -99, -54, -99, -91, -110, -110, -99, -17, -54, -54, 56, -39, -19, -54, -17, 38,
			-64, -64, -64, -64, -64, -64, -73, -54, -17, -73,
		],
	),
	(
		"11ATAVAWAYAvAwAyA’F,F.FALTLVLWLYLyL’P,P.PARTRVRWRYRyT,T-T.T:" *
		"T;TATOTaTcTeTiToTrTsTuTwTyV,V-V.V:V;VAVOVaVeViVoVrVuVyW,W-W." *
		"W:W;WAWaWeWiWoWrWuWyY,Y-Y.Y:Y;YAYaYeYiYoYpYqYuYvfiflf’r,r-r." *
		"rcrerorqr’v,v.w,w.y,y.‘‘’s’’",
		Int16[
			-54, -73, -128, -110, -91, -73, -73, -73, -73, -91, -91, -73, -91, -91, -91, -91, -54, -91, -91,
			-91, -73, -34, -34, -34, -34, -34, -73, -91, -73, -73, -73, -73, -17, -91, -91, -91, -17, -91,
			-73, -91, -91, -73, -73, -128, -73, -128, -91, -91, -128, -19, -91, -91, -36, -91, -73, -91, -91,
			-91, -36, -91, -54, -54, -110, -54, -54, -17, -54, -17, -17, -36, -91, -91, -91, -91, -91, -91,
			-110, -110, -36, -110, -91, -110, -91, -110, -54, -54, 56, -91, -36, -91, -17, -17, -17, -17, 19,
			-54, -54, -54, -54, -54, -54, -73, -36, -73,
		],
	),
)
const _TEXT_FAMILY_ARIAL = _text_family_metrics("Arial", 0.5185,
	Int16[
		278, 278, 355, 557, 557, 890, 667, 191, 334, 334, 390, 584, 278, 334, 278, 278, 557, 557, 557,
		557, 557, 557, 557, 557, 557, 557, 278, 278, 584, 584, 584, 557, 1016, 667, 667, 723, 723, 667,
		611, 778, 723, 278, 500, 667, 557, 834, 723, 778, 667, 778, 723, 667, 611, 723, 667, 944, 667,
		667, 611, 278, 278, 278, 470, 557, 334, 557, 557, 500, 557, 557, 278, 557, 557, 223, 223, 500,
		223, 834, 557, 557, 557, 557, 334, 500, 278, 557, 500, 723, 500, 500, 500, 334, 260, 334, 584,
		1000, 1000, 1000, 865, 865, 400, 549, 584, 549, 577, 334, 557, 1000, 223, 223, 334, 334, 1000,
		557, 557, 557, 557, 737, 737, 1000, 667, 579, 576, 500, 557, 446, 557, 500, 577, 690, 618, 649,
		781, 748, 668, 549, 713, 549, 549, 549, 549, 1000, 1000, 1000,
	],
	Int16[
		278, 334, 475, 557, 557, 890, 723, 238, 334, 334, 390, 584, 278, 334, 278, 278, 557, 557, 557,
		557, 557, 557, 557, 557, 557, 557, 334, 334, 584, 584, 584, 611, 976, 723, 723, 723, 723, 667,
		611, 778, 723, 278, 557, 723, 611, 834, 723, 778, 667, 778, 723, 667, 611, 723, 667, 944, 667,
		667, 611, 334, 278, 334, 584, 557, 334, 557, 611, 557, 611, 557, 334, 611, 611, 278, 278, 557,
		278, 890, 611, 611, 611, 611, 390, 557, 334, 611, 557, 778, 557, 557, 500, 390, 280, 390, 584,
		1000, 1000, 1000, 865, 865, 400, 549, 584, 549, 577, 334, 557, 1000, 278, 278, 500, 500, 1000,
		557, 557, 557, 557, 737, 737, 1000, 723, 615, 611, 557, 607, 475, 541, 557, 612, 766, 685, 716,
		845, 802, 719, 549, 713, 549, 549, 549, 549, 1000, 1000, 1000,
	],
	("A_fjr–€¥©®ÅΔ", Int16[2, 16, 0, 46, 0, 2, 14, 2, 0, 0, 2, 1], Int16[2, 12, 35, 0, 14, 0, 0, 0, 2, 2, 2, 1]),
	("/VY\\_fjr–€©®", Int16[2, 1, 2, 2, 10, 0, 46, 0, 2, 16, 5, 5], Int16[1, 0, 1, 1, 5, 30, 0, 13, 0, 0, 7, 7]),
	(
		"11ATAVAWAYAvAwAyA’F,F.FALTLVLWLYLyL’P,P.PARTRVRWRYT,T-T.T:T;" *
		"TATOTaTcTeTiToTrTsTuTwTyV,V-V.V:V;VAVaVeViVoVrVuVyW,W-W.W:W;" *
		"WAWaWeWoWrWuWyY,Y-Y.Y:Y;YAYaYeYiYoYpYqYuYvfff’r,r.r’v,v.w,w." *
		"y,y.‘‘’s’’",
		Int16[
			-74, -74, -74, -37, -74, -18, -18, -18, -74, -110, -110, -55, -74, -74, -74, -74, -37, -55, -128,
			-128, -74, -18, -18, -18, -18, -110, -55, -110, -110, -110, -74, -18, -110, -110, -110, -37,
			-110, -37, -110, -37, -55, -55, -91, -55, -91, -37, -37, -74, -74, -55, -18, -55, -37, -37, -37,
			-55, -18, -55, -18, -18, -37, -37, -18, -18, -18, -18, -8, -128, -91, -128, -55, -64, -74, -74,
			-91, -37, -91, -74, -91, -55, -55, -18, 19, -55, -55, 38, -74, -74, -55, -55, -74, -74, -18, -18,
			-18,
		],
	),
	(
		"11ATAVAWAYAvAwAyA’F,F.FALTLVLWLYLyL’P,P.PARVRWRYT,T-T.T:T;TA" *
		"TOTaTcTeTiToTrTsTuTwTyV,V-V.V:V;VAVaVeViVoVrVuVyW,W-W.W:W;WA" *
		"WaWeWiWoWrWuWyY,Y-Y.Y:Y;YAYaYeYiYoYpYqYuYvf’r,r.r’v,v.w,w.y," *
		"y.‘‘’s’’",
		Int16[
			-55, -74, -74, -55, -91, -37, -18, -37, -55, -110, -110, -55, -74, -74, -55, -91, -37, -55, -128,
			-128, -74, -18, -18, -37, -110, -55, -110, -110, -110, -74, -18, -74, -74, -74, -18, -74, -55,
			-74, -74, -74, -74, -91, -55, -91, -55, -55, -74, -55, -55, -18, -74, -55, -37, -37, -55, -20,
			-55, -18, -18, -55, -37, -18, -8, -18, -18, -18, -18, -110, -55, -110, -74, -74, -91, -55, -55,
			-37, -74, -55, -74, -55, -55, 19, -55, -55, 38, -74, -74, -37, -37, -74, -74, -37, -37, -37,
		],
	),
)
const _TEXT_FAMILY_HELVETICA = _text_family_metrics("Helvetica", 0.5230,
	Int16[
		278, 278, 355, 557, 557, 890, 667, 191, 334, 334, 390, 584, 278, 334, 278, 278, 557, 557, 557,
		557, 557, 557, 557, 557, 557, 557, 278, 278, 584, 584, 584, 557, 1016, 667, 667, 723, 723, 667,
		611, 778, 723, 278, 500, 667, 557, 834, 723, 778, 667, 778, 723, 667, 611, 723, 667, 944, 667,
		667, 611, 278, 278, 278, 470, 557, 334, 557, 557, 500, 557, 557, 278, 557, 557, 223, 223, 500,
		223, 834, 557, 557, 557, 557, 334, 500, 278, 557, 500, 723, 500, 500, 500, 334, 260, 334, 584,
		1000, 1000, 1000, 865, 865, 400, 549, 584, 549, 577, 278, 557, 1000, 223, 223, 334, 334, 1000,
		745, 557, 557, 557, 737, 737, 1000, 667, 611, 611, 557, 611, 557, 612, 557, 611, 549, 611, 723,
		758, 778, 723, 549, 713, 549, 549, 549, 549, 1000, 1000, 916,
	],
	Int16[
		278, 334, 475, 557, 557, 890, 723, 238, 334, 334, 390, 584, 278, 334, 278, 278, 557, 557, 557,
		557, 557, 557, 557, 557, 557, 557, 334, 334, 584, 584, 584, 611, 976, 723, 723, 723, 723, 667,
		611, 778, 723, 278, 557, 723, 611, 834, 723, 778, 667, 778, 723, 667, 611, 723, 667, 944, 667,
		667, 611, 334, 278, 334, 584, 557, 334, 557, 611, 557, 611, 557, 334, 611, 611, 278, 278, 557,
		278, 890, 611, 611, 611, 611, 390, 557, 334, 611, 557, 778, 557, 557, 500, 390, 280, 390, 584,
		1000, 1000, 1000, 865, 865, 400, 549, 584, 549, 577, 278, 557, 1000, 278, 278, 500, 500, 1000,
		745, 557, 557, 557, 737, 737, 1000, 723, 612, 605, 557, 611, 557, 610, 557, 610, 549, 612, 723,
		723, 778, 723, 549, 713, 549, 549, 549, 549, 1000, 1000, 975,
	],
	("/<>\\^j{}~±÷µ–¥π√≤≥", Int16[0, 0, 0, 34, 0, 19, 21, 0, 0, 0, 0, 38, 3, 16, 0, 9, 0, 0], Int16[24, 1, 1, 44, 9, 0, 0, 21, 6, 6, 6, 0, 2, 4, 46, 101, 5, 6]),
	("/<>\\`~±÷µ–¥π√≤≥", Int16[55, 0, 0, 55, 25, 0, 0, 0, 26, 3, 11, 0, 21, 0, 0], Int16[63, 3, 3, 63, 0, 12, 16, 16, 17, 2, 11, 42, 85, 15, 16]),
	(
		"11ATAVAWAYAvAwAyA’F,F.FALTLVLWLYLyL’P,P.PARTRVRWRYT,T-T.T:T;" *
		"TATOTaTcTeTiToTrTsTuTwTyV,V-V.V:V;VAVaVeViVoVrVuVyW,W-W.W:W;" *
		"WAWaWeWoWrWuWyY,Y-Y.Y:Y;YAYaYeYiYoYpYqYuYvfff’r,r.r’v,v.w,w." *
		"y,y.‘‘’s’’",
		Int16[
			-73, -73, -73, -36, -73, -17, -17, -17, -73, -110, -110, -54, -73, -73, -73, -73, -36, -54, -128,
			-128, -73, -17, -17, -17, -17, -110, -54, -110, -110, -110, -73, -17, -110, -110, -110, -36,
			-110, -36, -110, -36, -54, -54, -91, -54, -91, -36, -36, -73, -73, -54, -17, -54, -36, -36, -36,
			-54, -17, -54, -17, -17, -36, -36, -17, -17, -17, -17, -8, -128, -91, -128, -54, -64, -73, -73,
			-91, -36, -91, -73, -91, -54, -54, -17, 19, -54, -54, 38, -73, -73, -54, -54, -73, -73, -17, -17,
			-17,
		],
	),
	(
		"11ATAVAWAYAvAwAyA’F,F.FALTLVLWLYLyL’P,P.PARVRWRYT,T-T.T:T;TA" *
		"TOTaTcTeTiToTrTsTuTwTyV,V-V.V:V;VAVaVeViVoVrVuVyW,W-W.W:W;WA" *
		"WaWeWiWoWrWuWyY,Y-Y.Y:Y;YAYaYeYiYoYpYqYuYvf’r,r.r’v,v.w,w.y," *
		"y.‘‘’s’’",
		Int16[
			-54, -73, -73, -54, -91, -36, -17, -36, -54, -110, -110, -54, -73, -73, -54, -91, -36, -54, -128,
			-128, -73, -17, -17, -36, -110, -54, -110, -110, -110, -73, -17, -73, -73, -73, -17, -73, -54,
			-73, -73, -73, -73, -91, -54, -91, -54, -54, -73, -54, -54, -17, -73, -54, -36, -36, -54, -19,
			-54, -17, -17, -54, -36, -17, -8, -17, -17, -17, -17, -110, -54, -110, -73, -73, -91, -54, -54,
			-36, -73, -54, -73, -54, -54, 19, -54, -54, 38, -73, -73, -36, -36, -73, -73, -36, -36, -36,
		],
	),
)
const _TEXT_FAMILY_VERDANA = _text_family_metrics("Verdana", 0.5453,
	Int16[
		352, 394, 459, 819, 636, 1077, 727, 269, 455, 455, 636, 819, 364, 455, 364, 455, 636, 636, 636,
		636, 636, 636, 636, 636, 636, 636, 455, 455, 819, 819, 819, 546, 1000, 684, 686, 699, 771, 633,
		575, 776, 752, 421, 455, 693, 557, 843, 749, 788, 604, 788, 696, 684, 617, 732, 684, 989, 686,
		616, 686, 455, 455, 455, 819, 636, 636, 601, 624, 521, 624, 596, 352, 624, 633, 275, 345, 592,
		275, 973, 633, 607, 624, 624, 427, 521, 395, 633, 592, 819, 592, 592, 526, 635, 455, 635, 819,
		1000, 1000, 1000, 865, 865, 542, 819, 819, 819, 642, 364, 636, 1000, 269, 269, 459, 459, 819, 636,
		636, 636, 636, 1000, 1000, 977, 684, 624, 621, 592, 608, 513, 625, 592, 640, 638, 631, 791, 814,
		819, 704, 819, 1000, 819, 819, 819, 819, 1000, 1000, 916,
	],
	Int16[
		342, 403, 588, 868, 711, 1272, 863, 333, 544, 544, 711, 868, 362, 480, 362, 690, 711, 711, 711,
		711, 711, 711, 711, 711, 711, 711, 403, 403, 868, 868, 868, 617, 964, 777, 762, 724, 831, 684,
		651, 812, 838, 546, 556, 771, 638, 948, 847, 851, 733, 851, 783, 711, 682, 813, 764, 1129, 764,
		737, 692, 544, 690, 544, 868, 711, 711, 668, 700, 589, 700, 665, 423, 700, 713, 342, 403, 671,
		342, 1059, 713, 687, 700, 700, 498, 594, 456, 713, 650, 980, 669, 651, 597, 711, 544, 711, 868,
		1000, 1000, 1000, 865, 865, 588, 868, 868, 868, 722, 362, 711, 1000, 333, 333, 588, 588, 1049,
		711, 711, 711, 711, 964, 964, 964, 777, 700, 717, 651, 687, 585, 701, 651, 722, 720, 726, 915,
		895, 844, 806, 868, 1059, 868, 868, 868, 868, 1000, 1000, 975,
	],
	("&/LR\\_fjr‘’“”σ√", Int16[0, 15, 0, 0, 0, 2, 0, 31, 0, 10, 0, 10, 0, 0, 0], Int16[33, 0, 1, 4, 15, 2, 33, 0, 4, 0, 10, 0, 10, 2, 30]),
	("&KR_fj√", Int16[0, 0, 0, 8, 0, 29, 0], Int16[18, 1, 11, 8, 17, 0, 60]),
	(
		"!’!”'A,’,”-A-I-J-S-T-V-W-X-Y-Z-a-v-w-x-y-z.,.-.’.”.–.—:—A-AS" *
		"ATAUAVAWAYAtAuAvAwAyA‘A’A“A”A–A—B,B-B.BTB–B—B…C-C–C—D,D.DTDW" *
		"DXDYDZD…F,F.F:F;F?FAFTFaFeFoF…I-I–I—J,J.JAJ…K-KOKaKeKoKuKvKw" *
		"KyK–K—L'L-LCLGLJLOLTLVLWLYLvLyL’L”L–L—O,O.OTOXOYOZO…P,P.PAPY" *
		"PaPePoP…Q,Q.Q…R-RTRYRaReRoRuRyR’R”R–R—S,S.SASSSvSwSyS…T,T-T." *
		"T:T;T?TATCTGTOTSTTTaTcTeTgToTrTsTuTvTwTyTzT–T—T…U,U.UAU…V,V-" *
		"V.V:V;VAVaVeVoVuVyV–V—V…W,W-W.W:W;WAWaWeWoWrWuWyW–W—W…X-XCXG" *
		"XOXaXeXoXuXyX–X—Y,Y-Y.Y:Y;YAYOYaYdYeYgYmYnYoYpYqYrYsYuYvY–Y—" *
		"Y…Z-ZCZGZOZZZaZeZoZwZyZ–Z—avawayb,b.byb…c-cTc–c—eTf\"f'f)f*f," *
		"f-f.f?f\\f]fyf}f’f”f–f—f…hvhwhyk-kekok–k—mvmwmynvnwnyo,o.ovox" *
		"oyo…p,p.pyp…r,r-r.rar’r”r–r—r…t-tyt’t”t–t—v,v-v.vavevov–v—v…" *
		"w,w-w.waw–w—w…x-xcxdxexgxox–x—y,y-y.yaycydyeygyoyqy–y—y…z-zc" *
		"zdzezgzozqz–z—‘A’,’.’A’T’V’W’Y’s’t’…“A”,”.”A”T”V”W”Y”s”t”…–A" *
		"–I–J–S–T–V–W–X–Y–Z–a–v–w–x–y–z—A—I—J—S—T—V—W—X—Y—Z—a—v—w—x—y" *
		"—z…’…”",
		Int16[
			-48, -48, -48, -102, -102, -24, -14, -48, -9, -73, -24, -24, -39, -68, -14, -9, -19, -9, -24,
			-19, -19, -63, -78, -102, -102, -58, -58, -68, -24, -4, -58, -4, -29, -24, -39, -9, -4, -24, -14,
			-24, -24, -58, -24, -58, -24, -24, -9, 5, -9, -29, 5, 5, -9, -24, -24, -24, -24, -24, -24, -9,
			-4, -9, -9, -24, -146, -146, -29, -29, 30, -48, 15, -48, -24, -24, -146, -14, -14, -14, -9, -9,
			-4, -9, -53, -9, -29, -34, -34, -24, -39, -34, -39, -53, -53, -58, -78, -9, -9, 49, -9, -83, -53,
			-48, -78, -53, -53, -78, -78, -78, -78, -14, -14, -24, -4, -9, -9, -14, -146, -146, -24, 10, -24,
			-24, -24, -146, -14, -14, -14, -48, -29, -9, -19, -24, -24, -9, -26, -34, -34, -48, -48, -9, -9,
			-9, -10, -14, -9, -14, -9, -141, -73, -141, -97, -97, 30, -58, -19, -19, -24, -5, -34, -117,
			-107, -107, -102, -107, -97, -87, -97, -97, -97, -97, -83, -73, -73, -141, -9, -9, -4, -9, -141,
			-24, -141, -39, -39, -29, -48, -48, -48, -29, -31, -24, -24, -141, -141, -24, -107, -39, -39,
			-24, -48, -48, -48, -29, -29, -31, -24, -24, -107, -39, -4, -4, -4, -24, -29, -29, -14, -39, -39,
			-39, -141, -68, -141, -97, -97, -39, -9, -68, -58, -63, -63, -48, -48, -63, -48, -63, -48, -53,
			-53, -48, -68, -68, -141, -29, -9, -9, -9, -4, -24, -29, -29, -19, -31, -24, -24, -7, -4, -7,
			-14, -9, -2, -9, -9, -29, -9, -9, -68, 30, 30, 49, 25, -63, -24, -58, 54, 49, 49, -4, 49, 25, 25,
			-24, -24, -58, -9, -4, -9, -48, -9, -9, -48, -48, -9, -4, -9, -9, -4, -9, -14, -9, -7, -9, -7,
			-9, -14, -9, -2, -9, -141, -9, -141, -17, 15, 15, -9, -9, -141, -19, -4, 10, 10, -19, -19, -87,
			-19, -87, -19, -8, -8, -19, -19, -87, -34, -9, -34, -9, -9, -9, -34, -24, -9, -4, -11, -4, -11,
			-24, -24, -92, -19, -92, -19, -8, -4, -8, -4, -8, -4, -19, -19, -87, -9, -4, -4, -5, -4, -5, -4,
			-9, -9, -48, -102, -102, -48, 54, 49, 30, 54, -34, 20, -102, -48, -102, -102, -48, 54, 49, 30,
			54, -34, 20, -102, -24, -14, -48, -9, -73, -24, -24, -39, -68, -4, -9, -19, -9, -24, -19, -19,
			-24, -14, -48, -9, -73, -24, -24, -39, -68, -4, -9, -19, -9, -24, -19, -19, -102, -102,
		],
	),
	(
		"",
		Int16[
		],
	),
)
const _TEXT_FAMILY_DEJAVU_SANS = _text_family_metrics("DejaVu Sans", 0.5468,
	Int16[
		318, 401, 460, 838, 637, 951, 780, 275, 391, 391, 500, 838, 318, 361, 318, 337, 637, 637, 637,
		637, 637, 637, 637, 637, 637, 637, 337, 337, 838, 838, 838, 531, 1000, 685, 687, 699, 771, 632,
		576, 775, 752, 295, 295, 656, 558, 863, 749, 788, 604, 788, 695, 635, 611, 732, 685, 989, 686,
		611, 686, 391, 337, 391, 838, 500, 500, 613, 635, 550, 635, 616, 353, 635, 634, 278, 278, 580,
		278, 975, 634, 612, 635, 635, 412, 521, 393, 634, 592, 818, 592, 592, 525, 637, 337, 637, 838,
		1000, 1000, 1000, 865, 865, 500, 838, 838, 838, 637, 318, 500, 1000, 318, 318, 519, 519, 1000,
		637, 637, 637, 500, 1000, 1000, 1000, 685, 660, 639, 592, 612, 541, 612, 592, 637, 603, 634, 660,
		838, 765, 685, 638, 834, 838, 838, 838, 838, 838, 838, 838,
	],
	Int16[
		349, 457, 521, 838, 696, 1002, 873, 307, 458, 458, 523, 838, 380, 416, 380, 366, 696, 696, 696,
		696, 696, 696, 696, 696, 696, 696, 400, 400, 838, 838, 838, 581, 1000, 774, 763, 734, 831, 684,
		684, 821, 837, 373, 373, 775, 638, 996, 837, 851, 733, 851, 771, 721, 683, 813, 774, 1104, 771,
		725, 726, 458, 366, 458, 838, 500, 500, 675, 716, 593, 716, 679, 436, 716, 712, 343, 343, 666,
		343, 1042, 712, 688, 716, 716, 494, 596, 479, 712, 652, 924, 646, 652, 583, 712, 366, 712, 838,
		1000, 1000, 1000, 865, 865, 500, 838, 838, 838, 736, 380, 500, 1000, 380, 380, 658, 658, 1000,
		696, 696, 696, 500, 1000, 1000, 1000, 774, 688, 716, 682, 688, 557, 688, 633, 736, 792, 779, 783,
		870, 851, 774, 667, 834, 838, 838, 838, 838, 838, 838, 838,
	],
	("JKTY_fj", Int16[52, 0, 3, 2, 10, 0, 19], Int16[0, 21, 3, 2, 10, 20, 0]),
	("JKYfjk€√", Int16[57, 0, 10, 0, 34, 0, 20, 0], Int16[0, 31, 10, 9, 0, 20, 0, 2]),
	(
		"-A-B-G-J-O-Q-T-V-W-X-Y-o-v-yA-A.A:AAACAGAOAQATAVAWAYAcAdAeAf" *
		"AoAqAtAvAwAyA“A”BCBGBOBSBVBWBYB“B”CYC”DADVDYD“D”F.F:FAFSFTFa" *
		"FeFiFoFrFuFyF“GTGYG“G”H.H“H”J-JAJ“J”K-KAKCKOKTKUKWKYKaKeKoKu" *
		"KyK“K”L-LALOLTLULVLWLYLeLoLuLyL“L”O-O.O:OAOVOXOYO“O”P-P.PAPY" *
		"PaPePiPnPoPrPsPuP“P”Q-Q“Q”R-R.R:RARCRTRVRWRYRaReRoRuRyR“R”SA" *
		"T-T.T:TATCTTTaTcTeTiToTrTsTuTwTyT”UZV-V.V:VAVOVaVeViVoVuVyW-" *
		"W.W:WAWaWeWiWoWrWuWyW“X-XCXOXTXeX“X”Y-Y.Y:YAYCYOYaYeYiYoYuY“" *
		"Y”Z-Z“Z”exf-f.f:ffftfwfyf“kakekokukyn“n”o-o.oxo“o”r-r.r:rcrd" *
		"rergrhrmrnrorqrrrxr”v-v.v:v”w.w:xcxexoy-y.y:“A“B“C“D“F“G“H“J" *
		"“K“L“O“P“Q“R“X“Z“f“n“o“r“v“w“y",
		Int16[
			-21, -35, 37, 56, 28, 37, -91, -58, -40, -49, -118, 19, -26, -17, -21, -17, -17, 28, -17, -17,
			-17, -17, -77, -63, -54, -77, -17, -17, -17, -35, -17, -17, -17, -58, -40, -67, -128, -123, -17,
			-17, -17, -17, -30, -35, -54, -54, -54, -17, 19, -17, -17, -54, -21, -26, -160, -77, -91, -17,
			-17, -91, -54, -72, -35, -72, -54, -91, -21, -35, -49, -21, -21, -17, -35, -30, -35, -17, -35,
			-30, -104, -17, -54, -54, -77, -26, -35, -35, -17, -49, -49, -49, -72, -30, -30, -17, 23, -35,
			-137, -49, -109, -91, -132, -17, -17, -17, -91, -202, -262, 28, -40, -17, -17, -17, -63, -54,
			-21, -17, -21, -155, -63, -21, -44, -35, -21, -17, -35, -17, -17, -17, 19, 19, 28, -21, -17, -40,
			-35, -30, -40, -49, -72, -54, -40, -63, -21, -44, -44, -44, -54, -72, -63, 19, -91, -118, -109,
			-77, -58, -17, -165, -169, -169, -30, -169, -146, -165, -151, -165, -155, -21, -17, -58, -128,
			-81, -63, -17, -77, -77, -21, -77, -67, -26, -40, -114, -58, -54, -63, -58, -21, -58, -44, -35,
			-17, -17, -49, -72, -63, -17, -44, -77, -40, -118, -202, -132, -77, -54, -54, -137, -132, -35,
			-132, -114, -54, -17, -17, -17, -17, -17, -54, -72, -35, -15, -17, -17, -17, 32, -17, -35, -35,
			-30, -35, -72, -54, 19, -17, -30, -72, -35, -63, -91, -17, -21, -17, -21, -17, -17, -17, -17,
			-21, -17, -17, -26, 42, -26, -77, -54, -17, -91, -54, -17, -30, -30, -17, -142, -72, -128, -30,
			-35, -30, -30, -35, -30, -30, -30, -30, -35, -30, -35, -30, -58, -17, -35, -54, -72, -54, -35,
			-35, -35,
		],
	),
	(
		"-T-V-W-X-YA,A.A:A;ATAUAVAWAYAvAyA’A”BVBWBYC-CSC’C”D-DYF,F-F." *
		"F:F;FAFaFeFoFrFuFyF’GTGYK-KCKOKUKeKoKuKyLOLTLULVLWLYLyL’L”O," *
		"O-O.OAOVOXOYP,P-P.PAPaPsPyP’P”Q-R,R.RTRYRySST,T-T.T:T;TATTTa" *
		"TcTeToTrTsTuTwTyUAV,V-V.V:V;VAVOVaVeViVoVuW,W-W.W:W;WAWaWeWo" *
		"WrX-XCXOXeY,Y-Y.Y:Y;YAYCYOYaYeYoYuZ-ayf,f-f.fffiflf’f”kekor," *
		"r.r’r”v,v.w,w.y,y.‘A‘J‘V‘Y“A“J“Y",
		Int16[
			-146, -72, -44, -81, -146, 19, 19, 19, 19, -77, -30, -67, -44, -95, -35, -35, -91, -91, -40, -54,
			-54, 23, 19, 37, 37, 19, -72, -160, -30, -146, -54, -54, -114, -58, -40, -40, -63, -49, -54, 19,
			-17, -21, -86, -44, -44, -17, -17, -17, -17, -63, -35, -165, -35, -137, -77, -155, -67, -229,
			-239, -21, 19, -21, -26, -26, -35, -35, -183, -17, -183, -91, -26, -17, 19, 28, 19, 19, 19, 19,
			-44, -54, -44, -44, -142, -146, -151, -54, -54, -77, 23, -128, -132, -132, -132, -109, -132,
			-109, -109, -118, -30, -128, -72, -128, -44, -44, -67, -17, -54, -54, -17, -54, -35, -81, -44,
			-81, -30, -30, -44, -35, -35, -35, -17, -81, -35, -35, -26, -165, -146, -165, -86, -86, -95, -35,
			-35, -91, -91, -91, -72, -17, -30, -54, -17, -54, -60, -36, -36, 69, 42, -26, -26, -146, -142,
			42, 19, -81, -81, -63, -63, -77, -91, -114, -44, 19, 37, -128, -44, 19,
		],
	),
)
const _TEXT_FAMILY_COURIER_NEW = _text_family_metrics("Courier New", 0.4228,
	Int16[
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		1000, 1000, 1000, 865, 865, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
	],
	Int16[
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		1000, 1000, 1000, 865, 865, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
		601, 601, 601, 601, 601, 601, 601, 601, 601, 601, 601,
	],
	("—", Int16[8], Int16[7]),
	("<>AJKMNRVW_bdmpqvw—©®™Å≤≥", Int16[13, 0, 23, 0, 0, 19, 8, 0, 23, 11, 40, 11, 0, 17, 9, 0, 0, 2, 30, 3, 3, 42, 23, 13, 0], Int16[0, 14, 23, 14, 5, 24, 0, 21, 23, 12, 44, 0, 14, 26, 0, 17, 4, 2, 30, 3, 3, 2, 23, 0, 14]),
	(
		"",
		Int16[
		],
	),
	(
		"",
		Int16[
		],
	),
)
const _TEXT_FAMILY_MONOSPACE = _text_family_metrics("monospace", 0.5468,
	Int16[
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		1000, 1000, 1000, 865, 865, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
	],
	Int16[
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		1000, 1000, 1000, 865, 865, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
		603, 603, 603, 603, 603, 603, 603, 603, 603, 603, 603,
	],
	("#", Int16[0], Int16[5]),
	("&", Int16[0], Int16[1]),
	(
		"",
		Int16[
		],
	),
	(
		"",
		Int16[
		],
	),
)
const _TEXT_MATH_LATIN_MODERN = _text_math_metrics("Latin-Modern";
	italic = ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", Int16[
		530, 430, 434, 521, 467, 553, 478, 577, 346, 414, 522, 299, 879, 601, 486, 507, 453, 452, 470,
		362, 573, 486, 717, 573, 491, 468, 751, 760, 761, 829, 764, 749, 787, 882, 498, 634, 890, 682,
		1045, 882, 764, 755, 792, 760, 646, 705, 761, 770, 1049, 852, 763, 724, 501, 501, 501, 501, 501,
		501, 501, 501, 501, 501,
	]),
	roman = ("!\"\$'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]`abcdefghijklmnopqrstuvwxyz{|}", Int16[
		279, 375, 501, 279, 390, 390, 501, 779, 279, 334, 279, 501, 501, 501, 501, 501, 501, 501, 501,
		501, 501, 501, 279, 279, 779, 779, 779, 473, 779, 751, 709, 723, 765, 682, 654, 786, 751, 362,
		515, 779, 626, 918, 751, 779, 682, 779, 737, 557, 723, 751, 751, 1029, 751, 751, 612, 279, 279,
		501, 501, 557, 445, 557, 445, 312, 501, 557, 279, 311, 529, 279, 834, 557, 501, 557, 529, 393,
		395, 390, 557, 529, 723, 529, 529, 445, 501, 279, 501,
	]),
	ops = ("+-=<>*/,.;:!?'()[]|", Int16[1223, 1223, 1334, 1334, 1334, 945, 501, 446, 446, 446, 834, 278, 473, 388, 390, 390, 278, 278, 278]),
	commands = (
		split("""
		alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa lambda mu nu xi pi
		varpi rho varrho sigma varsigma tau upsilon phi varphi chi psi omega Gamma Delta Theta Lambda Xi
		Pi Sigma Upsilon Phi Psi Omega infty partial nabla hbar ell imath jmath aleph emptyset varnothing
		Re Im wp prime angle triangle cdot times pm mp div ast star circ bullet otimes oplus odot wedge
		vee cup cap setminus leq geq le ge neq ne approx sim simeq equiv propto ll gg perp parallel mid in
		notin ni subset supset subseteq supseteq cong doteq models to rightarrow leftarrow Rightarrow
		Leftarrow leftrightarrow Leftrightarrow longrightarrow Longrightarrow longleftarrow Longleftarrow
		longleftrightarrow Longleftrightarrow mapsto longmapsto uparrow downarrow Uparrow Downarrow
		nearrow searrow hookrightarrow ldots cdots dots vdots ddots langle rangle lfloor rfloor lceil
		rceil vert Vert backslash sum prod int iint oint coprod bigcup bigcap bigoplus bigotimes sin cos
		tan cot sec csc arcsin arccos arctan sinh cosh tanh log ln lg exp max min sup inf lim det arg dim
		ker deg gcd Pr quad qquad enspace thinspace checkmark dagger ddagger S
		"""),
		Int16[
			641, 575, 544, 453, 407, 467, 475, 498, 470, 592, 355, 577, 584, 604, 525, 447, 571, 829, 518,
			518, 572, 410, 512, 541, 597, 655, 627, 652, 623, 626, 834, 779, 695, 668, 751, 723, 779, 723,
			779, 723, 1001, 587, 834, 577, 418, 279, 347, 612, 501, 501, 829, 555, 637, 408, 779, 969, 723,
			1223, 1223, 1223, 1223, 945, 945, 857, 945, 1223, 1223, 1223, 1112, 1112, 1112, 1112, 1013, 1334,
			1334, 1334, 1334, 1334, 1334, 1329, 1329, 1334, 1334, 1334, 1556, 1556, 1334, 1056, 834, 1223,
			1223, 1223, 1334, 1334, 1334, 1334, 1334, 1334, 1168, 1556, 1556, 1556, 1556, 1556, 1556, 1556,
			2019, 2013, 2019, 2013, 1998, 2090, 1533, 1999, 1056, 1056, 1167, 1167, 1556, 1556, 1553, 1171,
			1110, 1171, 219, 947, 390, 390, 445, 445, 445, 445, 279, 399, 569, 1390, 1278, 999, 1369, 999,
			1278, 1167, 1167, 1445, 1445, 1563, 1673, 1780, 1668, 1617, 1617, 2900, 3010, 3117, 2119, 2229,
			2336, 1613, 1168, 1112, 1863, 2196, 2002, 1841, 1475, 1724, 1724, 1727, 2002, 1699, 1835, 1835,
			1407, 1001, 2000, 500, 167, 834, 889, 889, 445,
		],
	),
	space = 332,
	radical = 834,
)
const _TEXT_MATH_STIX = _text_math_metrics("STIX-Web";
	italic = ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", Int16[
		503, 471, 416, 533, 446, 616, 493, 514, 312, 391, 543, 319, 711, 498, 459, 493, 464, 409, 441,
		314, 475, 507, 776, 551, 497, 500, 718, 697, 712, 791, 735, 724, 735, 924, 531, 621, 803, 709,
		1056, 902, 733, 705, 782, 741, 681, 671, 776, 761, 1102, 811, 696, 803, 501, 501, 501, 501, 501,
		501, 501, 501, 501, 501,
	]),
	roman = ("!\"\$'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]`abcdefghijklmnopqrstuvwxyz{|}", Int16[
		334, 409, 501, 181, 334, 334, 501, 686, 251, 334, 251, 281, 501, 501, 501, 501, 501, 501, 501,
		501, 501, 501, 279, 279, 686, 686, 686, 445, 922, 723, 668, 668, 723, 612, 557, 723, 723, 334,
		375, 723, 612, 890, 723, 723, 558, 723, 668, 557, 612, 723, 723, 945, 723, 723, 613, 334, 334,
		334, 445, 501, 445, 501, 445, 339, 501, 501, 279, 286, 501, 279, 779, 501, 501, 501, 501, 334,
		390, 279, 501, 501, 723, 501, 501, 445, 481, 321, 481,
	]),
	ops = ("+-=<>*/,.;:!?'()[]|", Int16[1131, 1131, 1242, 1242, 1242, 968, 279, 418, 418, 446, 834, 334, 445, 341, 334, 334, 334, 334, 321]),
	commands = (
		split("""
		alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa lambda mu nu xi pi
		varpi rho varrho sigma varsigma tau upsilon phi varphi chi psi omega Gamma Delta Theta Lambda Xi
		Pi Sigma Upsilon Phi Psi Omega infty partial nabla hbar ell imath jmath aleph emptyset varnothing
		Re Im wp prime angle triangle cdot times pm mp div ast star circ bullet otimes oplus odot wedge
		vee cup cap setminus leq geq le ge neq ne approx sim simeq equiv propto ll gg perp parallel mid in
		notin ni subset supset subseteq supseteq cong doteq models to rightarrow leftarrow Rightarrow
		Leftarrow leftrightarrow Leftrightarrow longrightarrow Longrightarrow longleftarrow Longleftarrow
		longleftrightarrow Longleftrightarrow mapsto longmapsto uparrow downarrow Uparrow Downarrow
		nearrow searrow hookrightarrow ldots cdots dots vdots ddots langle rangle lfloor rfloor lceil
		rceil vert Vert backslash sum prod int iint oint coprod bigcup bigcap bigoplus bigotimes sin cos
		tan cot sec csc arcsin arccos arctan sinh cosh tanh log ln lg exp max min sup inf lim det arg dim
		ker deg gcd Pr quad qquad enspace thinspace checkmark dagger ddagger S
		"""),
		Int16[
			530, 519, 459, 464, 431, 485, 481, 461, 485, 555, 268, 550, 542, 580, 463, 444, 569, 867, 503,
			510, 548, 465, 473, 461, 646, 667, 646, 712, 682, 588, 723, 723, 703, 644, 723, 625, 723, 764,
			747, 745, 927, 472, 732, 580, 580, 279, 403, 683, 763, 524, 875, 763, 827, 341, 686, 1146, 731,
			1085, 1131, 1131, 1010, 968, 1145, 796, 796, 1287, 1287, 1207, 1065, 1065, 1065, 1065, 968, 1242,
			1242, 1242, 1242, 1242, 1242, 1242, 1242, 1242, 1242, 1242, 1490, 1490, 1242, 1079, 822, 1242,
			1242, 1242, 1242, 1242, 1242, 1242, 1242, 1242, 1242, 1482, 1482, 1482, 1482, 1482, 1482, 1482,
			2130, 2130, 2130, 2130, 2130, 2130, 1482, 2130, 1068, 1068, 1242, 1242, 1482, 1482, 1482, 1334,
			1260, 1334, 512, 1260, 401, 401, 470, 470, 470, 470, 321, 524, 524, 1248, 1334, 973, 1215, 973,
			1334, 1258, 1258, 1460, 1460, 1502, 1668, 1557, 1557, 1612, 1612, 2725, 2890, 2779, 2003, 2168,
			2058, 1613, 1113, 1113, 1779, 2057, 1891, 1724, 1446, 1669, 1557, 1612, 1891, 1612, 1779, 1779,
			1225, 1001, 2000, 500, 167, 865, 945, 945, 501,
		],
	),
	space = 250,
	radical = 929,
)
const _TEXT_MATH_DEFAULT = _text_math_max("default", _TEXT_MATH_LATIN_MODERN, _TEXT_MATH_STIX)

# Family names (lower case) with a table. Liberation, Tinos/Arimo/Cousine
# and the URW Nimbus faces are the metric-compatible substitutes Linux
# systems draw for Times New Roman, Arial, Courier New, Times and Helvetica
# (their published design goal; not measured here).
const _TEXT_FAMILIES = Dict{String, _TextFamilyMetrics}(
	"times new roman" => _TEXT_FAMILY_TIMES_NEW_ROMAN,
	"liberation serif" => _TEXT_FAMILY_TIMES_NEW_ROMAN,
	"tinos" => _TEXT_FAMILY_TIMES_NEW_ROMAN,
	"times" => _TEXT_FAMILY_TIMES,
	"nimbus roman" => _TEXT_FAMILY_TIMES,
	"nimbus roman no9 l" => _TEXT_FAMILY_TIMES,
	"arial" => _TEXT_FAMILY_ARIAL,
	"liberation sans" => _TEXT_FAMILY_ARIAL,
	"arimo" => _TEXT_FAMILY_ARIAL,
	"helvetica" => _TEXT_FAMILY_HELVETICA,
	"nimbus sans" => _TEXT_FAMILY_HELVETICA,
	"nimbus sans l" => _TEXT_FAMILY_HELVETICA,
	"verdana" => _TEXT_FAMILY_VERDANA,
	"dejavu sans" => _TEXT_FAMILY_DEJAVU_SANS,
	"bitstream vera sans" => _TEXT_FAMILY_DEJAVU_SANS,
	"courier new" => _TEXT_FAMILY_COURIER_NEW,
	"courier" => _TEXT_FAMILY_COURIER_NEW,
	"liberation mono" => _TEXT_FAMILY_COURIER_NEW,
	"cousine" => _TEXT_FAMILY_COURIER_NEW,
)
# A family that was not measured (plotly's default "Open Sans" among them:
# it is not installed where the tables were made) gets the elementwise
# maximum of the proportional families. A face wider than all of them can
# still exceed it.
const _TEXT_FAMILY_DEFAULT = _text_family_max("default", (
	_TEXT_FAMILY_TIMES_NEW_ROMAN, _TEXT_FAMILY_TIMES, _TEXT_FAMILY_ARIAL,
	_TEXT_FAMILY_HELVETICA, _TEXT_FAMILY_VERDANA, _TEXT_FAMILY_DEJAVU_SANS,
))
# Generic families, as the renderer resolved them (serif: Times, sans-serif:
# Helvetica). They count only when no named family precedes them.
const _TEXT_GENERIC_FAMILIES = Dict{String, _TextFamilyMetrics}(
	"serif" => _TEXT_FAMILY_TIMES,
	"sans-serif" => _TEXT_FAMILY_HELVETICA,
	"monospace" => _TEXT_FAMILY_MONOSPACE,
)
# plotly.js's default font stack (layout.font.family).
const _TEXT_PLOTLY_DEFAULT_FAMILY = "\"Open Sans\", verdana, arial, sans-serif"

# The families a CSS family list may be drawn in: every named family it lists
# (the browser takes the first one installed, which is unknown here), the
# conservative default for a name without a table, the generic family when
# nothing else is listed. Cached per list.
const _TEXT_FAMILY_CACHE = Dict{String, Vector{_TextFamilyMetrics}}()
const _TEXT_FAMILY_CACHE_LOCK = ReentrantLock()
const _TEXT_FAMILY_CACHE_MAX = 256

function _text_family_candidates(family::AbstractString)
	key = String(family)
	lock(_TEXT_FAMILY_CACHE_LOCK) do
		cached = get(_TEXT_FAMILY_CACHE, key, nothing)
		cached === nothing || return cached
		list = isempty(strip(key)) ? _TEXT_PLOTLY_DEFAULT_FAMILY : key
		out = _TextFamilyMetrics[]
		generic = nothing
		for part in split(list, ',')
			name = lowercase(strip(strip(part), ['"', '\'', ' ', '\t']))
			isempty(name) && continue
			metrics = get(_TEXT_FAMILIES, name, nothing)
			if metrics === nothing && haskey(_TEXT_GENERIC_FAMILIES, name)
				generic === nothing && (generic = _TEXT_GENERIC_FAMILIES[name])
				continue
			end
			metrics === nothing && (metrics = _TEXT_FAMILY_DEFAULT)
			any(m -> m === metrics, out) || push!(out, metrics)
		end
		isempty(out) && push!(out, something(generic, _TEXT_FAMILY_DEFAULT))
		length(_TEXT_FAMILY_CACHE) >= _TEXT_FAMILY_CACHE_MAX && empty!(_TEXT_FAMILY_CACHE)
		_TEXT_FAMILY_CACHE[key] = out
		return out
	end
end

# The text family of the style in scope (`_with_figure_style` puts a figure's
# own style in scope for its mutators, the finalizer and exports).
_text_scope_family() = _active_style().font_family

# Advance and ink overhangs (left, right; em) of `c` in family `m`. A
# character the table does not list: nothing for a zero-width one, 1 em for a
# wide (CJK) one (every family's fallback measured 1 em or less), the base
# letter's for an accented letter, else the widest letter.
function _text_family_glyph(m::_TextFamilyMetrics, c::Char, bold::Bool)
	k = get(_TEXT_ADVANCE_INDEX, c, 0)
	# plotly.js draws raw newlines and tabs as spaces (svg_text_utils).
	k == 0 && c in ('\n', '\r', '\t') && (k = 1)
	if k == 0 && isvalid(c)
		w = textwidth(c)
		w == 0 && return (0.0, 0.0, 0.0)
		w >= 2 && return (1.0, 0.0, 0.0)
		base = first(Base.Unicode.normalize(string(c), :NFD))
		base == c || (k = get(_TEXT_ADVANCE_INDEX, base, 0))
	end
	k == 0 && return (bold ? m.fallback_bold : m.fallback, 0.0, 0.0)
	return bold ? (m.bold[k], m.ink_left_bold[k], m.ink_right_bold[k]) :
		(m.regular[k], m.ink_left[k], m.ink_right[k])
end

_text_family_advance(m::_TextFamilyMetrics, c::Char, bold::Bool) = _text_family_glyph(m, c, bold)[1]

# Width (em) of a run of characters as Chromium boxes it: from the leftmost
# ink or origin to the rightmost ink or advance end, the pair adjustments
# applied between neighbours of one weight and size (one shaping run; across
# a `<b>`/`<sub>` boundary only an adjustment that widens is counted).
# `glyphs` counts the characters drawn.
mutable struct _TextRunBox
	x::Float64
	lo::Float64
	hi::Float64
	prev::Char
	prev_bold::Bool
	prev_scale::Float64
	glyphs::Int
end
_TextRunBox() = _TextRunBox(0.0, 0.0, 0.0, '\0', false, 1.0, 0)

function _text_run_add!(box::_TextRunBox, m::_TextFamilyMetrics, c::Char, bold::Bool, scale::Float64)
	if box.prev != '\0'
		pair = (box.prev, c)
		if box.prev_bold == bold && box.prev_scale == scale
			box.x += scale * get(bold ? m.kern_bold : m.kern, pair, 0.0)
		else
			widen = max(get(m.kern, pair, 0.0), get(m.kern_bold, pair, 0.0))
			widen > 0 && (box.x += max(scale, box.prev_scale) * widen)
		end
	end
	advance, left, right = _text_family_glyph(m, c, bold)
	box.lo = min(box.lo, box.x - scale * left)
	box.x += scale * advance
	box.hi = max(box.hi, box.x + scale * right, box.x)
	box.prev, box.prev_bold, box.prev_scale = c, bold, scale
	box.glyphs += 1
	return box
end

_text_run_width(box::_TextRunBox) = box.hi - box.lo

# A markup tag ends the shaping run (plotly.js draws each styled part as its
# own <tspan>): the next character is not adjusted against the previous one
# (beyond an adjustment that widens).
_text_run_break!(box::_TextRunBox) = (box.prev_scale = -1.0; box)

# Drawn text runs measured up to 0.003 px wider than their advances, pair
# adjustments and ink (D19 probe: "u{2" at 10.67 px Times New Roman, 15.789
# drawn vs 15.787 px): glyph positions are rounded to Chromium's layout unit,
# 1/64 px, allowed once per glyph.
const _TEXT_GLYPH_ROUNDING_PX = 1 / 64

# Character a named or numeric HTML entity (`amp`, `#38`, `#x26`) stands for,
# or `nothing`.
const _TEXT_ENTITIES = Dict(
	"amp" => '&', "lt" => '<', "gt" => '>', "quot" => '"', "apos" => '\'', "nbsp" => ' ',
	"deg" => '°', "plusmn" => '±', "times" => '×', "divide" => '÷', "micro" => 'µ',
	"middot" => '·', "ndash" => '–', "mdash" => '—', "hellip" => '…', "copy" => '©',
	"reg" => '®', "trade" => '™', "euro" => '€', "pound" => '£', "yen" => '¥', "sect" => '§',
)

function _text_entity_char(name::AbstractString)
	c = get(_TEXT_ENTITIES, name, nothing)
	c === nothing || return c
	m = match(r"^#(?:[xX]([0-9A-Fa-f]{1,6})|([0-9]{1,7}))$", name)
	m === nothing && return nothing
	code = m.captures[1] !== nothing ? parse(Int, m.captures[1]; base = 16) : parse(Int, m.captures[2])
	return (0 <= code <= 0x10ffff && !(0xd800 <= code <= 0xdfff)) ? Char(code) : nothing
end

# Width (em) of plain text in family `m` after HTML markup is removed: tags
# are dropped (`<b>`/`<strong>` set bold, `<sub>`/`<sup>` the script size),
# an entity counts as its character.
_text_plain_em(s::AbstractString, m::_TextFamilyMetrics, bold::Bool = false) =
	_text_run_width(_text_plain_run(s, m, bold))

# The run box (`_TextRunBox`) of plain text `s` in family `m`.
function _text_plain_run(s::AbstractString, m::_TextFamilyMetrics, bold::Bool = false)
	box = _TextRunBox()
	scale = 1.0
	weight = bold
	chars = collect(s)
	i = 1
	n = length(chars)
	while i <= n
		c = chars[i]
		if c == '<'
			close = findnext(==('>'), chars, i)
			if close !== nothing
				tag = lowercase(strip(String(chars[(i + 1):(close - 1)])))
				name = something(match(r"^/?\s*([a-z0-9]*)", tag), (; captures = [""])).captures[1]
				closing = startswith(tag, "/")
				if name in ("sub", "sup")
					scale = closing ? 1.0 : _TEXT_SCRIPT_SCALE
				elseif name in ("b", "strong")
					weight = closing ? bold : true
				end
				_text_run_break!(box)
				i = close + 1
				continue
			end
		elseif c == '&'
			semi = findnext(==(';'), chars, i)
			if semi !== nothing && semi - i <= 9
				e = _text_entity_char(String(chars[(i + 1):(semi - 1)]))
				if e !== nothing
					_text_run_add!(box, m, e, weight, scale)
					i = semi + 1
					continue
				end
			end
		end
		_text_run_add!(box, m, c, weight, scale)
		i += 1
	end
	return box
end

# The same in the scoped style's family (the widest of the families it may be
# drawn in).
_text_plain_em(s::AbstractString) =
	maximum(m -> _text_plain_em(s, m), _text_family_candidates(_text_scope_family()))

# plotly.js lays plain text out at 1.3 em per line (svg_text_utils
# LINE_SPACING). A MathJax row with scripts or parentheses is ~1.2 em tall
# (array rows are spaced 1.2 em apart), one with a fraction, root or stacked
# operator up to ~1.9 em.
const _TEXT_PLAIN_LINE_EM = 1.3
const _TEXT_MATH_ROW_EM = 1.3
const _TEXT_MATH_TALL_ROW_EM = 1.9
# Script size relative to its base: plotly.js <sub>/<sup> (70 %).
const _TEXT_SCRIPT_SCALE = 0.7
# plotly.js line break (svg_text_utils BR_TAG_ALL, applied to `<…>` tokens).
const _TEXT_BR_TAG = r"<br(\s+[^<>]*)?>"i

# ── MathJax ──────────────────────────────────────────────────────────────────
# MathJax 2 sizes math so that its x-height (TeX x_height, 0.430554 em) is the
# ex of the <div> plotly.js typesets in: the label's family under
# `inherit_text_font` (the page sets it, `_MATHJAX_PAGE_EXTENSIONS_JS`), else
# the page's default font (Chromium: Times, `_TEXT_FAMILY_TIMES`).
const _TEXT_MATH_X_HEIGHT = 0.430554
# Style levels: display, text, script, scriptscript (MathJax 2
# scriptsizemultiplier 0.71, scriptminsize lifted by the page).
const _TEXT_LEVEL_SCALE = (1.0, 1.0, 0.7071, 0.5)
# Space after a script (scriptspace 0.05 em) and the italic correction
# MathJax adds before it (measured: x^2, x_2, x_{aa}^{aa}).
const _TEXT_SCRIPT_EXTRA_EM = 0.1
# A fraction or binomial: the null delimiters and the rule overhang
# (measured: \frac{a}{a} 0.734 em at text size, 0.889 em in display).
const _TEXT_FRACTION_EXTRA_EM = 0.36
# A \left/\right or \big delimiter (measured 0.39 to 0.42 em around rows of
# one line).
const _TEXT_DELIMITER_EM = 0.45
const _TEXT_BIG_DELIMITER_EM = 0.6
const _TEXT_NULL_DELIMITER_EM = 0.12
# \mathbf over \mathrm (measured 5.594 / 5.004).
const _TEXT_MATH_BOLD = 1.12
# A large operator in display style over text style (\sum 1.444 / 1.056).
const _TEXT_DISPLAY_OPERATOR = 1.4
# A character the math font has no glyph for (CJK, most symbols): MathJax
# draws it as text at the label's size (CJK measured 1.1 em of the label).
const _TEXT_MATH_FOREIGN_EM = 1.1
# A math-mode character or command without a measured width; arrows named by
# a command the table does not list (`\Longleftrightarrow`-like when "long").
const _TEXT_MATH_UNKNOWN_EM = 1.0
const _TEXT_MATH_ARROW_EM = 1.56
const _TEXT_MATH_LONG_ARROW_EM = 2.13
# A literal that MathJax prints from its text font (`\%`, `\#`, `\&`, `\_`):
# the widest of them, 0.834 em.
const _TEXT_MATH_ESCAPED_EM = 0.834
# Spacing on both sides of a binary/relation command, an operator name
# (`\sin`) beside a letter, the gap between array columns.
const _TEXT_MATH_OPERATOR_SPACE_EM = 0.333
const _TEXT_ARRAY_COLUMN_GAP_EM = 1.0
# The brace of `cases`, two delimiters of a matrix environment.
const _TEXT_CASES_BRACE_EM = 0.9

# MathJax 2 size switches (relative to \normalsize; MathJax 2 has no
# \footnotesize, kept at LaTeX's 0.8 for labels written by hand).
const _TEXT_TEX_SIZES = Dict(
	"tiny" => 0.5, "Tiny" => 0.6, "scriptsize" => 0.7, "footnotesize" => 0.8, "small" => 0.85,
	"normalsize" => 1.0, "large" => 1.2, "Large" => 1.44, "LARGE" => 1.73,
	"huge" => 2.07, "Huge" => 2.49,
)
# Style switches: the level the rest of the group is set at.
const _TEXT_TEX_STYLES = Dict("displaystyle" => 0, "textstyle" => 1, "scriptstyle" => 2, "scriptscriptstyle" => 3)
# Commands whose single argument is set in text mode (literal characters).
const _TEXT_TEX_TEXT_MODE = Set([
	"text", "textbf", "textit", "textrm", "textsf", "texttt", "textup", "textnormal", "emph", "mbox", "hbox",
])
const _TEXT_TEX_TEXT_BOLD = Set(["textbf"])
# Commands whose argument is set in a math alphabet.
const _TEXT_TEX_ALPHABETS = Dict(
	"mathrm" => :mathrm, "mathsf" => :mathrm, "mathtt" => :mathrm, "mathup" => :mathrm,
	"operatorname" => :mathrm, "mathbf" => :mathbf, "boldsymbol" => :mathbf, "bm" => :mathbf,
	"pmb" => :mathbf, "mathcal" => :mathbf, "mathscr" => :mathbf, "mathfrak" => :mathbf,
	"mathbb" => :mathbf, "mathit" => :math, "mathnormal" => :math,
)
# Commands whose argument keeps its width (accents, over/underlines, class
# changes, colour boxes).
const _TEXT_TEX_WRAPPERS = Set([
	"hat", "bar", "vec", "tilde", "dot", "ddot", "dddot", "check", "breve", "acute", "grave",
	"widehat", "widetilde", "overline", "underline", "mathring", "overrightarrow",
	"overleftarrow", "mathord", "mathopen", "mathclose", "mathpunct", "mathinner", "boxed",
	"phantom", "hphantom", "smash", "cancel", "bcancel", "xcancel",
])
# Two-argument constructs drawn one above the other.
const _TEXT_TEX_FRACTIONS = Dict(
	"frac" => :auto, "cfrac" => :auto, "binom" => :auto, "genfrac" => :auto,
	"dfrac" => :display, "dbinom" => :display, "tfrac" => :text, "tbinom" => :text,
)
const _TEXT_TEX_STACKED = Set(["overset", "underset", "stackrel"])
const _TEXT_TEX_BIG_OPERATORS = Set([
	"sum", "prod", "int", "iint", "iiint", "oint", "coprod", "bigcup", "bigcap", "bigoplus",
	"bigotimes", "bigodot", "biguplus", "bigvee", "bigwedge", "bigsqcup",
])
const _TEXT_TEX_DELIMITER_SIZES = Set([
	"big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr",
	"bigm", "Bigm", "biggm", "Biggm",
])
# Explicit spaces (em).
const _TEXT_TEX_SPACES = Dict(
	"quad" => 1.0, "qquad" => 2.0, "enspace" => 0.5, "thinspace" => 0.17, "enskip" => 0.5,
	"," => 0.17, ":" => 0.22, ">" => 0.22, ";" => 0.28, "!" => -0.17, " " => 0.333,
	"negthinspace" => -0.17, "medspace" => 0.22, "thickspace" => 0.28,
)
# Commands drawn as nothing.
const _TEXT_TEX_INVISIBLE = Set(["limits", "nolimits", "displaylimits", "label", "nonumber", "notag", "hline", "vphantom", "strut", "relax"])

# TeX parser state: the characters and read position, the math font, the
# label's text family when text runs are drawn in it (`inherit_text_font`),
# the math em per px of font size `k`, and the style level (0 display,
# 1 text, 2 script, 3 scriptscript).
mutable struct _TextTeX
	chars::Vector{Char}
	pos::Int
	math::_TextMathMetrics
	text::Union{Nothing, _TextFamilyMetrics}
	k::Float64
	level::Int
end

_TextTeX(chars::Vector{Char}, pos::Int) = _TextTeX(chars, pos, _TEXT_MATH_LATIN_MODERN, nothing, 1.0, 1)

_text_tex_peek(t::_TextTeX) = t.pos <= length(t.chars) ? t.chars[t.pos] : nothing
_text_tex_scale(t::_TextTeX) = _TEXT_LEVEL_SCALE[t.level + 1]

function _text_tex_skip_spaces!(t::_TextTeX)
	while (c = _text_tex_peek(t)) !== nothing && isspace(c)
		t.pos += 1
	end
	return nothing
end

# Read a command name after a backslash (letters, or one non-letter).
function _text_tex_command!(t::_TextTeX)
	t.pos += 1  # the backslash
	start = t.pos
	while t.pos <= length(t.chars) && isletter(t.chars[t.pos])
		t.pos += 1
	end
	if t.pos == start
		t.pos > length(t.chars) && return ""
		t.pos += 1
		return string(t.chars[start])
	end
	return String(t.chars[start:(t.pos - 1)])
end

# A `{…}` group read and thrown away (colour names, column specs); returns
# its content.
function _text_tex_skip_group!(t::_TextTeX)
	_text_tex_skip_spaces!(t)
	_text_tex_peek(t) == '{' || return ""
	start = t.pos + 1
	depth = 0
	while (c = _text_tex_peek(t)) !== nothing
		t.pos += 1
		if c == '\\'
			t.pos += 1
		elseif c == '{'
			depth += 1
		elseif c == '}'
			depth -= 1
			depth == 0 && return String(t.chars[start:(t.pos - 2)])
		end
	end
	return String(t.chars[start:end])
end

# Width (math em, at the base size) of one text-mode character.
function _text_tex_text_char(t::_TextTeX, c::Char, bold::Bool)
	if t.text !== nothing
		# Drawn in the label's family at the label's size: em of the label.
		return _text_family_advance(t.text, c, bold) / t.k
	end
	c == ' ' && return t.math.space
	w = get(t.math.roman, c, nothing)
	w !== nothing && return bold ? _TEXT_MATH_BOLD * w : w
	c in "#%&_^~\\" && return _TEXT_MATH_ESCAPED_EM
	return _text_tex_foreign_char(t, c)
end

function _text_tex_foreign_char(t::_TextTeX, c::Char)
	textwidth(c) == 0 && !isspace(c) && return 0.0
	return _TEXT_MATH_FOREIGN_EM / t.k
end

# Width of one math-mode character in alphabet `mode`.
function _text_tex_math_char(t::_TextTeX, c::Char, mode::Symbol)
	isspace(c) && return 0.0  # TeX ignores spaces in math mode
	m = t.math
	if mode !== :math && (isletter(c) || isdigit(c))
		w = get(m.roman, c, nothing)
		w !== nothing && return mode === :mathbf ? _TEXT_MATH_BOLD * w : w
	end
	w = get(m.italic, c, nothing)
	w === nothing || return w
	w = get(m.ops, c, nothing)
	w === nothing || return w
	w = get(m.roman, c, nothing)
	w === nothing || return w
	c in "#%&_^~\\" && return _TEXT_MATH_ESCAPED_EM
	return _text_tex_foreign_char(t, c)
end

# The argument of a text-mode command: MathJax prints it literally (`\$`,
# `\{`, `\}` and `\\` stand for the character; inner braces are printed).
function _text_tex_text_argument!(t::_TextTeX, bold::Bool)
	s = _text_tex_scale(t)
	_text_tex_skip_spaces!(t)
	c = _text_tex_peek(t)
	c === nothing && return 0.0
	if c != '{'
		t.pos += 1
		return s * _text_tex_text_char(t, c, bold)
	end
	t.pos += 1
	depth = 1
	run = Char[]
	while (c = _text_tex_peek(t)) !== nothing
		t.pos += 1
		if c == '}'
			depth -= 1
			depth == 0 && break
		elseif c == '{'
			depth += 1
		elseif c == '\\' && (n = _text_tex_peek(t)) !== nothing && n in "\${}\\"
			t.pos += 1
			c = n
		end
		push!(run, c)
	end
	if t.text !== nothing
		# One <text> in the label's family: MathJax sizes it by its bounding box.
		box = _TextRunBox()
		foreach(c -> _text_run_add!(box, t.text, c, bold, 1.0), run)
		return s * _text_run_width(box) / t.k
	end
	return s * sum((_text_tex_text_char(t, c, bold) for c in run); init = 0.0)
end

# One argument at `level`: a `{…}` group, a command, or one character.
# Returns (width, tall).
function _text_tex_argument!(t::_TextTeX, mode::Symbol; level::Int = t.level)
	outer = t.level
	t.level = level
	try
		_text_tex_skip_spaces!(t)
		c = _text_tex_peek(t)
		c === nothing && return (0.0, false)
		if c == '{'
			t.pos += 1
			return _text_tex_sequence!(t, mode; stop = '}')
		end
		return _text_tex_token!(t, mode)
	finally
		t.level = outer
	end
end

_text_tex_script_level(level::Int) = level <= 1 ? 2 : 3
_text_tex_fraction_level(level::Int, kind::Symbol) =
	kind === :display ? 1 : kind === :text ? 2 : level == 0 ? 1 : level == 1 ? 2 : 3

# One token at the current position (a command with its arguments, a group, a
# script with no base, a character). Returns (width, tall).
function _text_tex_token!(t::_TextTeX, mode::Symbol)
	s = _text_tex_scale(t)
	c = _text_tex_peek(t)
	c === nothing && return (0.0, false)
	if c == '{'
		t.pos += 1
		return _text_tex_sequence!(t, mode; stop = '}')
	elseif c == '}'
		# A closing brace with no group open here (literal braces are \{ \}).
		t.pos += 1
		return (0.0, false)
	elseif c == '^' || c == '_'
		t.pos += 1
		w, tall = _text_tex_argument!(t, mode; level = _text_tex_script_level(t.level))
		return (w + s * _TEXT_SCRIPT_EXTRA_EM, tall)
	elseif c == '&'
		# A raw `&` outside an array: MathJax reports "Misplaced &".
		t.pos += 1
		return (s * _TEXT_MATH_ESCAPED_EM, false)
	elseif c != '\\'
		t.pos += 1
		return (s * _text_tex_math_char(t, c, mode), false)
	end
	name = _text_tex_command!(t)
	isempty(name) && return (0.0, false)
	haskey(_TEXT_TEX_SPACES, name) && return (s * _TEXT_TEX_SPACES[name], false)
	name in ("{", "}") && return (s * 0.5, false)
	name == "\$" && return (s * 0.5, false)
	name in ("%", "#", "&", "_") && return (s * _TEXT_MATH_ESCAPED_EM, false)
	name == "|" && return (s * get(t.math.commands, "Vert", 0.4), false)
	name in ("\\", "cr", "newline") && return (0.0, false)
	name in _TEXT_TEX_INVISIBLE && (name == "vphantom" && _text_tex_skip_group!(t); return (0.0, false))
	name in _TEXT_TEX_TEXT_MODE && return (_text_tex_text_argument!(t, name in _TEXT_TEX_TEXT_BOLD), false)
	if haskey(_TEXT_TEX_ALPHABETS, name)
		w, tall = _text_tex_argument!(t, _TEXT_TEX_ALPHABETS[name])
		name == "operatorname" && (w += s * _TEXT_MATH_OPERATOR_SPACE_EM)
		return (w, tall)
	end
	name in _TEXT_TEX_WRAPPERS && return _text_tex_argument!(t, mode)
	if name in ("underbrace", "overbrace")
		w, _ = _text_tex_argument!(t, mode)
		_text_tex_skip_spaces!(t)
		if _text_tex_peek(t) in ('_', '^')
			t.pos += 1
			label, _ = _text_tex_argument!(t, mode; level = _text_tex_script_level(t.level))
			w = max(w, label)
		end
		return (w, true)
	elseif haskey(_TEXT_TEX_FRACTIONS, name)
		kind = _TEXT_TEX_FRACTIONS[name]
		name == "genfrac" && foreach(_ -> _text_tex_skip_group!(t), 1:4)
		level = _text_tex_fraction_level(t.level, kind)
		w1, _ = _text_tex_argument!(t, mode; level = level)
		w2, _ = _text_tex_argument!(t, mode; level = level)
		extra = startswith(name, "binom") || endswith(name, "binom") ? 2 * _TEXT_DELIMITER_EM : 0.0
		return (max(w1, w2) + s * (_TEXT_FRACTION_EXTRA_EM + extra), true)
	elseif name in _TEXT_TEX_STACKED
		w1, _ = _text_tex_argument!(t, mode; level = _text_tex_script_level(t.level))
		w2, _ = _text_tex_argument!(t, mode)
		return (max(w1, w2) + s * _TEXT_MATH_OPERATOR_SPACE_EM, true)
	elseif name == "sqrt"
		index = 0.0
		_text_tex_skip_spaces!(t)
		if _text_tex_peek(t) == '['
			close = findnext(==(']'), t.chars, t.pos)
			if close !== nothing
				inner = _TextTeX(t.chars[(t.pos + 1):(close - 1)], 1, t.math, t.text, t.k, 3)
				index, _ = _text_tex_sequence!(inner, mode)
				t.pos = close + 1
			end
		end
		w, _ = _text_tex_argument!(t, mode)
		return (w + index + s * t.math.radical, true)
	elseif name in ("left", "right", "middle")
		_text_tex_skip_spaces!(t)
		if _text_tex_peek(t) == '.'
			t.pos += 1
			return (s * _TEXT_NULL_DELIMITER_EM, false)
		end
		w, _ = _text_tex_argument!(t, mode)
		return (max(w, s * _TEXT_DELIMITER_EM), false)
	elseif name in _TEXT_TEX_DELIMITER_SIZES
		w, _ = _text_tex_argument!(t, mode)
		return (max(w, s * _TEXT_BIG_DELIMITER_EM), name[1] == 'B' || startswith(name, "bigg"))
	elseif name in ("color", "hspace", "kern", "mkern", "hskip", "mskip")
		spec = _text_tex_skip_group!(t)
		name == "color" && return (0.0, false)
		return (s * _text_tex_length_em(spec), false)
	elseif name in ("textcolor", "colorbox")
		_text_tex_skip_group!(t)
		return _text_tex_argument!(t, mode)
	elseif name == "unicode"
		code = tryparse(Int, strip(_text_tex_skip_group!(t)))
		return (s * (code == 36 ? 0.5 : _TEXT_MATH_FOREIGN_EM / t.k), false)
	elseif name in ("mathbin", "mathrel", "mathop")
		w, tall = _text_tex_argument!(t, mode)
		return (w + s * 2 * _TEXT_MATH_OPERATOR_SPACE_EM, tall)
	elseif name == "not"
		return _text_tex_token!(t, mode)
	elseif name == "begin"
		return _text_tex_environment!(t, mode)
	elseif name == "end"
		_text_tex_skip_group!(t)
		return (0.0, false)
	elseif haskey(_TEXT_TEX_SIZES, name) || haskey(_TEXT_TEX_STYLES, name)
		return (0.0, false)  # switches: handled by the enclosing sequence
	end
	w = get(t.math.commands, name, nothing)
	if w !== nothing
		big = name in _TEXT_TEX_BIG_OPERATORS
		return (s * w * (big && t.level == 0 ? _TEXT_DISPLAY_OPERATOR : 1.0), big)
	end
	occursin("arrow", lowercase(name)) &&
		return (s * (startswith(lowercase(name), "long") ? _TEXT_MATH_LONG_ARROW_EM : _TEXT_MATH_ARROW_EM), false)
	return (s * _TEXT_MATH_UNKNOWN_EM, false)
end

# Length (em) of a TeX dimension (`1em`, `0.5ex`, `3pt`, `2mu`); an unknown
# one counts as 1 em.
function _text_tex_length_em(spec::AbstractString)
	m = match(r"^\s*(-?[0-9]*\.?[0-9]+)\s*(em|ex|pt|mu|px)?\s*$", spec)
	m === nothing && return 1.0
	value = parse(Float64, m.captures[1])
	unit = something(m.captures[2], "em")
	unit == "ex" && return value * _TEXT_MATH_X_HEIGHT
	unit == "pt" && return value / 10
	unit == "mu" && return value / 18
	unit == "px" && return value / 12
	return value
end

# A token sequence up to `stop` (consumed) or the end; with `cells`, up to an
# unconsumed `&`, `\\` or `\end` (an array cell). Size and style switches
# apply to the rest of the sequence; a token's scripts follow it (both share
# one column). Returns (width, tall).
function _text_tex_sequence!(t::_TextTeX, mode::Symbol; stop = nothing, cells::Bool = false)
	width = 0.0
	tall = false
	scale = 1.0
	outer = t.level
	try
		while (c = _text_tex_peek(t)) !== nothing
			if stop !== nothing && c == stop
				t.pos += 1
				break
			end
			cells && c == '&' && break
			if c == '\\'
				save = t.pos
				name = _text_tex_command!(t)
				if haskey(_TEXT_TEX_SIZES, name)
					scale = _TEXT_TEX_SIZES[name]
					continue
				elseif haskey(_TEXT_TEX_STYLES, name)
					t.level = _TEXT_TEX_STYLES[name]
					continue
				elseif cells && name in ("\\", "cr", "end")
					t.pos = save
					break
				end
				t.pos = save
			end
			w, h = _text_tex_token!(t, mode)
			# Scripts of this token: a superscript and a subscript share a column.
			sup = -1.0
			sub = -1.0
			while true
				_text_tex_skip_spaces!(t)
				n = _text_tex_peek(t)
				if n == '^' && sup < 0
					t.pos += 1
					sup, sh = _text_tex_argument!(t, mode; level = _text_tex_script_level(t.level))
					h |= sh
				elseif n == '_' && sub < 0
					t.pos += 1
					sub, sh = _text_tex_argument!(t, mode; level = _text_tex_script_level(t.level))
					h |= sh
				elseif n == '\'' && sup < 0
					# A prime is a superscript.
					t.pos += 1
					sup = _TEXT_LEVEL_SCALE[_text_tex_script_level(t.level) + 1] * get(t.math.commands, "prime", 0.41)
				else
					break
				end
			end
			(sup >= 0 || sub >= 0) && (w += max(sup, sub) + _text_tex_scale(t) * _TEXT_SCRIPT_EXTRA_EM)
			width += scale * w
			tall |= h
		end
	finally
		t.level = outer
	end
	return (width, tall)
end

# An environment after `\begin`: its rows, each the sum of its `&`-separated
# cells and the column gaps, plus a matrix's delimiters or the brace of
# `cases`. Returns (width, tall).
function _text_tex_environment!(t::_TextTeX, mode::Symbol)
	name = strip(_text_tex_skip_group!(t))
	name == "array" && _text_tex_skip_group!(t)   # column spec
	gap = name in ("aligned", "align", "align*", "alignedat", "eqnarray", "split", "gathered") ? 0.0 :
		_TEXT_ARRAY_COLUMN_GAP_EM
	rows = _text_tex_rows!(t, mode, gap)
	width = isempty(rows) ? 0.0 : maximum(first, rows)
	s = _text_tex_scale(t)
	name in ("pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix") && (width += s * 2 * _TEXT_DELIMITER_EM)
	name in ("cases", "rcases") && (width += s * _TEXT_CASES_BRACE_EM)
	return (width, length(rows) > 1 || any(last, rows))
end

# Rows of an environment body up to `\end{…}` (consumed): each row is the sum
# of its `&`-separated cells, `gap` em between cells. Returns [(width, tall), …].
function _text_tex_rows!(t::_TextTeX, mode::Symbol, gap::Float64 = _TEXT_ARRAY_COLUMN_GAP_EM)
	rows = Tuple{Float64, Bool}[]
	row_width = 0.0
	row_tall = false
	cells = 0
	while true
		w, tall = _text_tex_sequence!(t, mode; cells = true)
		row_width += w + (cells > 0 ? _text_tex_scale(t) * gap : 0.0)
		row_tall |= tall
		cells += 1
		c = _text_tex_peek(t)
		if c == '&'
			t.pos += 1
			continue
		end
		push!(rows, (row_width, row_tall))
		row_width, row_tall, cells = 0.0, false, 0
		c === nothing && break
		save = t.pos
		name = _text_tex_command!(t)
		if name in ("\\", "cr")
			continue
		elseif name == "end"
			_text_tex_skip_group!(t)
			break
		end
		t.pos = save + 1  # not a row end: skip the backslash and go on
	end
	return rows
end

# Rows (width, size scale, tall) of one math expression (math em at the base
# size). A top-level environment (as `mathtext` writes multi-line labels)
# gives one row per environment row.
function _text_tex_box(math::AbstractString, metrics::_TextMathMetrics,
	text::Union{Nothing, _TextFamilyMetrics}, k::Float64, display::Bool)
	t = _TextTeX(collect(math), 1, metrics, text, k, display ? 0 : 1)
	scale = 1.0
	# Leading size and style switches and braces around the whole expression.
	while true
		while (c = _text_tex_peek(t)) !== nothing && (isspace(c) || c == '{')
			t.pos += 1
		end
		_text_tex_peek(t) == '\\' || break
		save = t.pos
		name = _text_tex_command!(t)
		if haskey(_TEXT_TEX_SIZES, name)
			scale = _TEXT_TEX_SIZES[name]
			continue
		elseif haskey(_TEXT_TEX_STYLES, name)
			t.level = _TEXT_TEX_STYLES[name]
			continue
		elseif name == "begin"
			name_env = strip(_text_tex_skip_group!(t))
			name_env == "array" && _text_tex_skip_group!(t)
			rows = _text_tex_rows!(t, :math)
			# Anything after the environment (rare) extends the last row.
			rest, rest_tall = _text_tex_sequence!(t, :math)
			isempty(rows) && push!(rows, (0.0, false))
			rows[end] = (rows[end][1] + rest, rows[end][2] || rest_tall)
			return [(scale * w, scale, tall) for (w, tall) in rows]
		end
		t.pos = save
		break
	end
	# The sequence applies the leading switches itself.
	t.pos = 1
	t.level = display ? 0 : 1
	w, tall = _text_tex_sequence!(t, :math)
	return [(w, scale, tall)]
end

# Split `s` at unescaped `$` signs into (is_math, segment, display) triples;
# `$$…$$` is display math.
function _text_math_segments(s::AbstractString)
	segments = Tuple{Bool, String, Bool}[]
	buf = IOBuffer()
	math = false
	display = false
	escaped = false
	chars = collect(s)
	k = 1
	while k <= length(chars)
		c = chars[k]
		if c == '$' && !escaped
			double = k < length(chars) && chars[k + 1] == '$'
			push!(segments, (math, String(take!(buf)), display))
			if math
				math = false
				display && double && (k += 1)
				display = false
			else
				math = true
				display = double
				double && (k += 1)
			end
			escaped = false
			k += 1
			continue
		end
		print(buf, c)
		escaped = c == '\\' && !escaped
		k += 1
	end
	push!(segments, (math, String(take!(buf)), display))
	return [x for x in segments if !isempty(x[2])]
end

# Mathjax font metrics of the SVG font in effect (`set_default_mathtext!(;
# font)`); a font that was not measured gets the larger of the two.
function _text_math_font_metrics()
	name = try
		_mathjax_svg_font()
	catch err
		err isa ArgumentError || rethrow()
		""
	end
	name == "Latin-Modern" && return _TEXT_MATH_LATIN_MODERN
	name == "STIX-Web" && return _TEXT_MATH_STIX
	return _TEXT_MATH_DEFAULT
end

"""
	_text_inherits_text_font() -> Bool

Whether MathJax draws the text runs of a math label (`\\text{…}`) in the
label's own font: `set_default_mathtext!(; inherit_text_font)` when set, else
whether the style in scope sets a text font family (every journal preset and
`:publication` do; `:default` does not). The page decides the same per figure
from the style it records (`_MATHJAX_PAGE_EXTENSIONS_JS`).
"""
function _text_inherits_text_font()
	forced = _MATHTEXT_SETTINGS[].inherit_text_font
	forced === nothing || return forced
	return !isempty(strip(_active_style().font_family))
end

"""
	_text_extent(text, fontsize; family = nothing, bold = false) -> (width_px, height_px)

Estimated size of `text` as plotly.js draws it in an annotation, title or
legend entry at `fontsize` px, without any frame or padding: plain text with
HTML markup (`<br>`/newline line breaks, tags stripped, `<b>` bold,
`<sub>`/`<sup>` at script size) at 1.3 em per line, and MathJax (`\$…\$`, as
[`mathtext`](@ref) writes it) with TeX commands, braces, scripts, fractions
and size switches interpreted: a top-level environment gives one row per
`\\\\`. Widths come from advances measured in the renderer for the font family
`family` (a CSS list; default: the scoped style's, `_text_scope_family`) and
the MathJax font in effect; with several possible families, the widest. Never
throws: an unknown character or command counts as a wide glyph.
"""
function _text_extent(text::AbstractString, fontsize::Real; family::Union{Nothing, AbstractString} = nothing, bold::Bool = false)
	fs = (fontsize isa Real && isfinite(fontsize) && fontsize > 0) ? Float64(fontsize) : 12.0
	s = String(text)
	isempty(strip(s)) && return (0.0, 0.0)
	candidates = _text_family_candidates(family === nothing ? _text_scope_family() : family)
	segments = _text_math_segments(s)
	inherit = any(first, segments) && _text_inherits_text_font()
	math = any(first, segments) ? _text_math_font_metrics() : _TEXT_MATH_LATIN_MODERN
	width = 0.0
	height = 0.0
	for m in candidates
		w, h = _text_extent_in(segments, fs, m, math, inherit, bold)
		width = max(width, w)
		height = max(height, h)
	end
	return (width, height)
end

function _text_extent_in(segments, fs::Float64, m::_TextFamilyMetrics, math::_TextMathMetrics, inherit::Bool, bold::Bool)
	# Math em per px of font size: MathJax matches its x-height to the ex of
	# the label's family (inherit) or of the page's default font.
	k = (inherit ? m.ex : _TEXT_FAMILY_TIMES.ex) / _TEXT_MATH_X_HEIGHT
	# Lines: plain text breaks at <br>/newline; a math segment contributes
	# its rows (the first continues the current line, further rows add lines).
	lines = Tuple{Float64, Float64}[(0.0, _TEXT_PLAIN_LINE_EM)]  # (width_px, height_em)
	for (is_math, segment, display) in segments
		if is_math
			rows = _text_tex_box(segment, math, inherit ? m : nothing, k, display)
			for (index, (w, scale, tall)) in enumerate(rows)
				index > 1 && push!(lines, (0.0, 0.0))
				lw, lh = lines[end]
				lines[end] = (lw + w * k * fs, max(lh, scale * (tall ? _TEXT_MATH_TALL_ROW_EM : _TEXT_MATH_ROW_EM)))
			end
		else
			parts = split(segment, _TEXT_BR_TAG)
			for (index, part) in enumerate(parts)
				index > 1 && push!(lines, (0.0, _TEXT_PLAIN_LINE_EM))
				lw, lh = lines[end]
				run = _text_plain_run(part, m, bold)
				lines[end] = (
					lw + _text_run_width(run) * fs + run.glyphs * _TEXT_GLYPH_ROUNDING_PX,
					max(lh, _TEXT_PLAIN_LINE_EM),
				)
			end
		end
	end
	return (maximum(first, lines), sum(last, lines) * fs)
end

# ── Baseline depth ──────────────────────────────────────────────────────────
# plotly.js aligns annotations by their box: titles of one line placed at the
# same `y` with `yanchor = "bottom"` share the bottom of their boxes, not their
# baselines, and the baseline sits higher in a plain-text box (the font's
# descent) than in a MathJax box (the depth of the expression). The depths
# below (em; MathJax 2 TeX font metrics, rounded) estimate where it sits:
# descenders (g, j, p, q, y, Q, comma, semicolon; also an italic f and the
# Greek letters with a tail) 0.2, delimiters ((, ), [, ], \{, \}, |, /, a
# radical) 0.25, large operators 0.36, a fraction 0.47; a subscript is lowered
# 0.15 em (0.25 with a superscript on the same base) and set at script size.
const _TEXT_DEPTH_DESCENDER_EM = 0.2
const _TEXT_DEPTH_DELIMITER_EM = 0.25
const _TEXT_DEPTH_BIG_OPERATOR_EM = 0.36
const _TEXT_DEPTH_FRACTION_EM = 0.47
const _TEXT_DEPTH_SUB_EM = 0.15
const _TEXT_DEPTH_SUBSUP_EM = 0.25
const _TEXT_DEPTH_DESCENDERS = Set("gjpqyQ,;")
const _TEXT_DEPTH_DELIMITERS = Set("()[]|/")
const _TEXT_DEPTH_GREEK = Set([
	"beta", "gamma", "zeta", "eta", "mu", "xi", "rho", "varrho", "phi", "varphi", "chi", "psi",
])
const _TEXT_DEPTH_DELIMITER_COMMANDS = Set([
	"{", "}", "|", "langle", "rangle", "lfloor", "rfloor", "lceil", "rceil", "vert", "Vert",
	"lvert", "rvert", "lVert", "rVert", "backslash",
])
# Upright fonts and text mode, where an f has no tail.
const _TEXT_DEPTH_UPRIGHT = Set([
	"text", "textbf", "textrm", "textsf", "texttt", "textup", "mbox", "hbox", "mathrm", "mathbf",
	"mathsf", "mathtt", "operatorname", "boldsymbol", "bm", "pmb",
])
# Commands whose argument sets the depth as it is, and constructs drawn one
# above the other (a fraction's depth, or the base's under \overset).
const _TEXT_DEPTH_WRAPPERS = Set([
	"text", "textbf", "textit", "textrm", "textsf", "texttt", "textup", "emph",
	"mbox", "hbox", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal",
	"mathbb", "mathfrak", "mathscr", "boldsymbol", "bm", "operatorname", "mathnormal",
	"hat", "bar", "vec", "tilde", "dot", "ddot", "check", "breve", "acute", "grave",
	"widehat", "widetilde", "overline", "underline", "mathring", "pmb", "displaystyle",
	"textstyle", "underbrace", "overbrace",
])
const _TEXT_DEPTH_STACKED = Set(["frac", "dfrac", "tfrac", "cfrac", "binom", "dbinom", "tbinom", "overset", "underset", "stackrel"])
const _TEXT_DEPTH_SWITCHES = Dict("rm" => true, "bf" => true, "sf" => true, "tt" => true, "it" => false)
# Box bottom to baseline, px, beyond the depth: half of `_TEXT_ANNOTATION_FRAME`
# plus the font descent (0.2 em) for plain text, 0.25 px for MathJax.
# Calibrated against the plotly.js 2.35.2 renderer (the bottom of the box
# plotly anchors, to the baseline; titles at 12 and 13 px, sans and serif,
# plain, scripts, delimiters, fractions and large operators): plain text
# within 0.4 px, MathJax within 0.8 px. plotly.js rounds box sizes and
# positions to whole px, so baselines meet within about 1 px; at 16 px it
# draws MathJax up to 5 px below its box (measured), deeper than estimated.
const _TEXT_PLAIN_DESCENT_EM = 0.2
const _TEXT_MATH_BASELINE_PX = 0.25
# With `inherit_text_font` (`set_default_mathtext!`), MathJax 2.7.9 draws the
# text runs of a math label (`\text{…}`, `\textbf{…}`, `\mbox{…}`) in the
# label's font, measured by the browser: their depth is the font's descent at
# a size of MathJax's own (measured 2.45 to 3.48 px for 12 to 16 px labels,
# sans and serif), whatever the glyphs.
const _TEXT_INHERITED_TEXT_DEPTH_PX = 3.0

# A depth scan of a TeX fragment: the parser state, whether text runs are
# drawn in the label's font (`inherit`; they are skipped and noted in `text`).
mutable struct _TextDepthScan
	t::_TextTeX
	inherit::Bool
	text::Bool
end

# Depth (em) of one TeX argument (group, command or character).
function _text_tex_depth_argument!(scan::_TextDepthScan, upright::Bool)
	t = scan.t
	while (c = _text_tex_peek(t)) !== nothing && c == ' '
		t.pos += 1
	end
	c = _text_tex_peek(t)
	c === nothing && return 0.0
	c == '{' && (t.pos += 1; return _text_tex_depth_sequence!(scan, upright; stop = '}'))
	c == '\\' && return _text_tex_depth_command!(scan, upright)
	t.pos += 1
	return _text_tex_depth_char(c, upright)
end

function _text_tex_depth_char(c::Char, upright::Bool)
	c in _TEXT_DEPTH_DELIMITERS && return _TEXT_DEPTH_DELIMITER_EM
	(c in _TEXT_DEPTH_DESCENDERS || (!upright && c == 'f')) && return _TEXT_DEPTH_DESCENDER_EM
	return 0.0
end

# Depth (em) of the command at the current position, with its arguments.
function _text_tex_depth_command!(scan::_TextDepthScan, upright::Bool)
	t = scan.t
	name = _text_tex_command!(t)
	isempty(name) && return 0.0
	if scan.inherit && name in _TEXT_TEX_TEXT_MODE
		# Drawn in the label's font: its depth is the font's (the caller).
		_text_tex_depth_argument!(scan, true)
		scan.text = true
		return 0.0
	end
	name in _TEXT_DEPTH_DELIMITER_COMMANDS && return _TEXT_DEPTH_DELIMITER_EM
	name in _TEXT_DEPTH_UPRIGHT && return _text_tex_depth_argument!(scan, true)
	name in ("textit", "mathit", "emph") && return _text_tex_depth_argument!(scan, false)
	name in _TEXT_DEPTH_WRAPPERS && return _text_tex_depth_argument!(scan, upright)
	if name in _TEXT_DEPTH_STACKED
		_text_tex_depth_argument!(scan, upright)
		base = _text_tex_depth_argument!(scan, upright)
		return name in ("overset", "stackrel") ? base : _TEXT_DEPTH_FRACTION_EM
	elseif name == "sqrt"
		if _text_tex_peek(t) == '['
			close = findnext(==(']'), t.chars, t.pos)
			close === nothing || (t.pos = close + 1)
		end
		return max(_TEXT_DEPTH_DELIMITER_EM, _text_tex_depth_argument!(scan, upright))
	elseif name in ("left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr")
		delimiter = _text_tex_depth_argument!(scan, upright)
		return delimiter > 0 ? max(delimiter, _TEXT_DEPTH_DELIMITER_EM) : 0.0
	elseif name in ("color", "label", "hspace", "vspace", "phantom", "hphantom", "vphantom", "unicode")
		_text_tex_skip_group!(t)
		return 0.0
	elseif name == "textcolor"
		_text_tex_skip_group!(t)
		return _text_tex_depth_argument!(scan, upright)
	elseif name in _TEXT_TEX_BIG_OPERATORS
		return _TEXT_DEPTH_BIG_OPERATOR_EM
	elseif name in _TEXT_DEPTH_GREEK
		return _TEXT_DEPTH_DESCENDER_EM
	end
	return 0.0
end

# Depth (em) of a TeX sequence up to `stop` (consumed) or the end. A size
# switch scales the rest of the sequence.
function _text_tex_depth_sequence!(scan::_TextDepthScan, upright::Bool; stop::Union{Nothing, Char} = nothing)
	t = scan.t
	depth = 0.0
	scale = 1.0
	superscript = false     # the current base already has a superscript
	while (c = _text_tex_peek(t)) !== nothing
		if stop !== nothing && c == stop
			t.pos += 1
			break
		elseif c == ' '
			t.pos += 1
		elseif c == '^'
			t.pos += 1
			_text_tex_depth_argument!(scan, upright)       # raised: no depth
			superscript = true
		elseif c == '_'
			t.pos += 1
			script = _text_tex_depth_argument!(scan, upright)
			while (n = _text_tex_peek(t)) !== nothing && n == ' '
				t.pos += 1
			end
			shift = (superscript || _text_tex_peek(t) == '^') ? _TEXT_DEPTH_SUBSUP_EM : _TEXT_DEPTH_SUB_EM
			depth = max(depth, scale * (shift + _TEXT_SCRIPT_SCALE * script))
		elseif c == '\\'
			save = t.pos
			name = _text_tex_command!(t)
			if haskey(_TEXT_DEPTH_SWITCHES, name)
				upright = _TEXT_DEPTH_SWITCHES[name]
				continue
			elseif haskey(_TEXT_TEX_SIZES, name)
				scale = _TEXT_TEX_SIZES[name]
				continue
			end
			t.pos = save
			depth = max(depth, scale * _text_tex_depth_command!(scan, upright))
			superscript = false
		else
			depth = max(depth, scale * _text_tex_depth_argument!(scan, upright))
			superscript = false
		end
	end
	return depth
end

"""
	_text_baseline_depth(text, fontsize) -> Union{Float64, Nothing}

Estimated px from the bottom of the box plotly.js draws around annotation
`text` at `fontsize` px (its default 1 px padding and border included) up to
the baseline of its last line: half the frame plus the font descent for plain
text, the depth of the expression for MathJax (the first `\$…\$` segment, the
part plotly.js typesets; its text runs as the label's font draws them under
`inherit_text_font`). `nothing` when it is not estimated: a multi-row MathJax
array or `<sub>` markup.
"""
function _text_baseline_depth(text::AbstractString, fontsize::Real)
	fs = (fontsize isa Real && isfinite(fontsize) && fontsize > 0) ? Float64(fontsize) : 12.0
	s = String(text)
	isempty(strip(s)) && return nothing
	segments = _text_math_segments(s)
	index = findfirst(first, segments)
	if index === nothing
		occursin(r"<sub\b"i, s) && return nothing
		return _TEXT_ANNOTATION_FRAME / 2 + _TEXT_PLAIN_DESCENT_EM * fs
	end
	math = segments[index][2]
	(occursin("\\begin", math) || occursin("\\\\", math)) && return nothing
	scan = _TextDepthScan(_TextTeX(collect(math), 1), _text_inherits_text_font(), false)
	depth = _TEXT_MATH_BASELINE_PX + fs * _text_tex_depth_sequence!(scan, false)
	return scan.text ? max(depth, _TEXT_INHERITED_TEXT_DEPTH_PX) : depth
end

# ─────────────────────────────────────────────────────────────────────────────
# F15: set_legend! extensions
# ─────────────────────────────────────────────────────────────────────────────

const _LEGEND_XANCHORS = ("", "auto", "left", "center", "right")
const _LEGEND_YANCHORS = ("", "auto", "top", "middle", "bottom")
# plotly.js `legend.itemwidth` has `min: 30` (px).
const _LEGEND_MIN_ITEMWIDTH = 30

function _legend_orientation(orientation, who::AbstractString)
	orientation === nothing && return nothing
	(orientation isa Symbol || orientation isa AbstractString) || throw(ArgumentError(
		"$(who): `orientation` must be :v, :h or nothing; got $(repr(orientation)).",
	))
	name = lowercase(String(orientation))
	name in ("v", "vertical") && return "v"
	name in ("h", "horizontal") && return "h"
	throw(ArgumentError(
		"$(who): `orientation` must be :v (vertical) or :h (horizontal); got $(repr(orientation)).",
	))
end

function _legend_position_option(position, who::AbstractString)
	position === nothing && return nothing
	(position isa Symbol || position isa AbstractString) &&
		return _normalize_legend_position(position)
	(position isa Tuple || position isa AbstractVector) || throw(ArgumentError(
		"$(who): `position` must be a Symbol, a string or an (x, y) tuple of " *
		"axes fractions; got $(repr(position)).",
	))
	return _text_pair(position, who, "position")
end

# plotly.js `legend.title.side` values, by the Symbol `title_side` takes.
const _LEGEND_TITLE_SIDES = (
	top = "top", left = "left", top_left = "top left", top_center = "top center",
	top_right = "top right",
)

function _legend_title_side(side, who::AbstractString)
	side === nothing && return nothing
	(side isa Symbol || side isa AbstractString) || throw(ArgumentError(
		"$(who): `title_side` must be a Symbol or string; got $(repr(side)).",
	))
	name = Symbol(replace(lowercase(strip(String(side))), r"[\s-]+" => "_"))
	haskey(_LEGEND_TITLE_SIDES, name) || throw(ArgumentError(
		"$(who): `title_side` must be one of $(join(repr.(keys(_LEGEND_TITLE_SIDES)), ", ")); " *
		"got $(repr(side)).",
	))
	return _LEGEND_TITLE_SIDES[name]
end

"""
	_legend_options(who; position, inset, bgcolor, bordercolor, borderwidth, showlegend, xanchor, yanchor, orientation, ncols, title, fontsize, frame, dedupe, itemwidth, entrywidth, legend_target, title_side)

Validate the keywords of `set_legend!` / `subplot_legends!` before anything is
written and return them normalized as a NamedTuple (`who`; `position` is
`nothing`, a normalized Symbol or a `Float64` tuple; colours are `String`s;
`inset` is a `Float64` tuple with `inset_given` telling whether the caller
chose it; `title` is already passed through `_label`; `title_side` is a
plotly `legend.title.side` string or `nothing`). Throws
`ArgumentError("<who>: …")`.
"""
function _legend_options(
	who::AbstractString;
	position = nothing,
	inset = nothing,
	bgcolor = nothing,
	bordercolor = nothing,
	borderwidth = nothing,
	showlegend = nothing,
	xanchor = "",
	yanchor = "",
	orientation = nothing,
	ncols = 0,
	title::AbstractString = "",
	fontsize = 0,
	frame = nothing,
	dedupe::Bool = true,
	itemwidth = 0,
	entrywidth = 0,
	legend_target = nothing,
	title_side = nothing,
)
	pos = _legend_position_option(position, who)
	inset_value = inset === nothing ? _DEFAULT_LEGEND_INSET[] :
		_text_pair(inset, who, "inset"; nonnegative = true)
	bg = bgcolor === nothing ? nothing : _cmn_check_color(bgcolor, "bgcolor", who)
	border = bordercolor === nothing ? nothing : _cmn_check_color(bordercolor, "bordercolor", who)
	for (name, value) in (("bgcolor", bg), ("bordercolor", border))
		value === nothing || !isempty(value) || throw(ArgumentError(
			"$(who): `$(name)` must not be empty (use `nothing` to keep the current colour).",
		))
	end
	bw = borderwidth === nothing ? nothing : _text_real(borderwidth, who, "borderwidth")
	(showlegend === nothing || showlegend isa Bool) || throw(ArgumentError(
		"$(who): `showlegend` must be true, false or nothing; got $(repr(showlegend)).",
	))
	xa = String(xanchor)
	ya = String(yanchor)
	xa in _LEGEND_XANCHORS || throw(ArgumentError(
		"$(who): `xanchor` must be one of $(join(repr.(_LEGEND_XANCHORS), ", ")); got $(repr(xanchor)).",
	))
	ya in _LEGEND_YANCHORS || throw(ArgumentError(
		"$(who): `yanchor` must be one of $(join(repr.(_LEGEND_YANCHORS), ", ")); got $(repr(yanchor)).",
	))
	orient = _legend_orientation(orientation, who)
	n = _text_real(ncols, who, "ncols")
	isinteger(n) || throw(ArgumentError("$(who): `ncols` must be a whole number; got $(repr(ncols))."))
	fs = _text_real(fontsize, who, "fontsize")
	iw = _text_real(itemwidth, who, "itemwidth")
	(iw == 0 || iw >= _LEGEND_MIN_ITEMWIDTH) || throw(ArgumentError(
		"$(who): `itemwidth` must be 0 (unchanged) or at least $(_LEGEND_MIN_ITEMWIDTH) px " *
		"(Plotly's minimum); got $(repr(itemwidth)).",
	))
	ew = _text_real(entrywidth, who, "entrywidth")
	(n > 0 && ew > 0) && throw(ArgumentError(
		"$(who): pass either `ncols` (columns as wide as their labels) " *
		"or `entrywidth` (px), not both.",
	))
	(n > 1 && orient == "v") && throw(ArgumentError(
		"$(who): `ncols=$(Int(n))` lays entries out in columns of a horizontal " *
		"legend; it cannot be combined with `orientation=:v`.",
	))
	(frame === nothing || frame isa Bool) || throw(ArgumentError(
		"$(who): `frame` must be true, false or nothing; got $(repr(frame)).",
	))
	if frame === false && (bg !== nothing || border !== nothing || bw !== nothing)
		throw(ArgumentError(
			"$(who): `frame=false` draws no box; drop `bgcolor`/`bordercolor`/`borderwidth` " *
			"or use `frame=true`.",
		))
	end
	(legend_target === nothing || legend_target in (:cell, :figure)) || throw(ArgumentError(
		"$(who): `legend_target` must be :cell, :figure or nothing; got $(repr(legend_target)).",
	))
	title_label = isempty(title) ? "" : _text_checked_label(title, who)
	side = _legend_title_side(title_side, who)
	return (
		who = String(who),
		title_side = side,
		position = pos,
		inset = inset_value,
		inset_given = inset !== nothing,
		bgcolor = bg,
		bordercolor = border,
		borderwidth = bw,
		showlegend = showlegend,
		xanchor = xa,
		yanchor = ya,
		orientation = orient,
		ncols = Int(n),
		title = title_label,
		fontsize = fs,
		frame = frame,
		dedupe = dedupe,
		itemwidth = iw,
		entrywidth = ew,
		legend_target = legend_target,
	)
end

"""
	_legend_layout_ext(opts; span = 1.0)::Dict{Symbol,Any}

Legend fields of the F15/A3 keywords (validated by `_legend_options`):
`orientation` (explicit, or "h" when `ncols > 0`), `entrywidth` +
`entrywidthmode` (px, "pixels"), `itemwidth`, `title.text`, `title.side` and
`font.size`. Keywords left at their sentinel produce no field, so the current
value is kept. Nested values are Dicts that `_legend_apply_ext!` merges into
the existing `title`/`font`. `ncols` itself is laid out by
[`_legend_apply_columns!`](@ref) (legend groups, one per column), which needs
the entries; `span` is accepted for the callers' convenience and unused.
"""
function _legend_layout_ext(opts; span::Real = 1.0)
	ext = Dict{Symbol, Any}()
	if opts.orientation !== nothing
		ext[:orientation] = opts.orientation
	elseif opts.ncols > 1
		ext[:orientation] = "h"
	elseif opts.ncols == 1
		ext[:orientation] = "v"  # one column: plotly's vertical legend
	end
	if opts.entrywidth > 0
		ext[:entrywidth] = _text_number(opts.entrywidth)
		ext[:entrywidthmode] = "pixels"
	end
	opts.itemwidth > 0 && (ext[:itemwidth] = _text_number(opts.itemwidth))
	title = Dict{Symbol, Any}()
	isempty(opts.title) || (title[:text] = opts.title)
	opts.title_side === nothing || (title[:side] = opts.title_side)
	isempty(title) || (ext[:title] = title)
	opts.fontsize > 0 && (ext[:font] = Dict{Symbol, Any}(:size => _text_number(opts.fontsize)))
	return ext
end

# ── Legend columns (`ncols`, wrapped horizontal cell legends) ────────────────
#
# plotly.js 2.35.2 (components/legend/draw.js, computeLegendDimensions) draws a
# horizontal legend whose `traceorder` contains "grouped" as one column per
# legendgroup: the group's entries are stacked, the column is as wide as its
# widest entry plus `itemGap`, and whole columns wrap onto a new row only when
# they would pass the legend's maximum width (`_maxWidth`, the plot-area width
# for a legend anchored inside the paper). Ungrouped horizontal legends instead
# give every entry the width of the widest one (or an `entrywidth` fraction of
# `_maxWidth`, which made labels longer than the fraction overlap - G43/G57/G58
# - and, being proportional to the plot area, fed back into the margin
# pushing). Columns are therefore legend groups named by the package; the name
# records the legend id, the fill order ('c' column-major as matplotlib's
# `ncols`, 'r' row-major for wrapped horizontal cell legends), the column and
# the column count, so entries added later can join the layout.
const _LEGEND_COLUMN_GROUP_PREFIX = "plotlysupply:col:"
const _LEGEND_COLUMN_GROUP_REGEX = r"^plotlysupply:col:(legend[0-9]*):([cr]):([0-9]{1,6})/([0-9]{1,6})$"
# plotly.js legend constants (components/legend/constants.js itemGap) and
# attribute defaults (legend.itemwidth, legend.indentation, legend.borderwidth).
const _LEGEND_ITEM_GAP = 5
const _LEGEND_DEFAULT_ITEMWIDTH = 30
# plotly.js layout defaults used to estimate the plot-area width: width 700
# (the package's savefig default, as tight_layout!) and margin.l/r 80.
const _LEGEND_DEFAULT_MARGIN_LR = 80.0

_legend_column_group(legend_id::AbstractString, fill::Char, k::Integer, n::Integer) =
	string(_LEGEND_COLUMN_GROUP_PREFIX, legend_id, ":", fill, ":", k, "/", n)

# (legend id, fill, column, column count) of a package column group, else nothing.
function _legend_column_info(group)
	group isa AbstractString || return nothing
	m = match(_LEGEND_COLUMN_GROUP_REGEX, group)
	m === nothing && return nothing
	k = parse(Int, m[3])
	n = parse(Int, m[4])
	(1 <= k <= n) || return nothing
	return (String(m[1]), m[2][1], k, n)
end

_legend_is_column_group(group) =
	group isa AbstractString && startswith(group, _LEGEND_COLUMN_GROUP_PREFIX)

# plotly.js sorts legend entries by `legendrank` (default 1000), then by trace order.
function _legend_rank(trace::GenericTrace)
	r = get(trace.fields, :legendrank, nothing)
	return (r isa Real && !(r isa Bool) && isfinite(r)) ? Float64(r) : 1000.0
end

# Trace indices of the entries legend `legend_id` lists, in plotly's order.
function _legend_entry_indices(p::Plot, legend_id::AbstractString)
	indices = Int[]
	for (index, trace) in enumerate(p.data)
		trace isa GenericTrace || continue
		_legend_trace_legend_id(trace) == legend_id || continue
		_trace_will_showlegend(trace) || continue
		push!(indices, index)
	end
	sort!(indices; by = index -> (_legend_rank(p.data[index]), index))
	return indices
end

# Pie-like traces list one entry per slice, which cannot be split over columns.
_legend_lists_slices(p::Plot, legend_id::AbstractString) = any(p.data) do trace
	trace isa GenericTrace && _trace_has_slice_legend(trace) &&
		_legend_trace_legend_id(trace) == legend_id
end

# Font size (px) plotly.js uses for the entries of legend box `box`: the box's
# font, the template's legend font, the layout font, the template font, 12.
function _legend_entry_font_size(p::Plot, box::AbstractDict)
	for value in (
		get(_symbol_dict(get(box, :font, nothing)), :size, nothing),
		_legend_template_layout_value(p, (:legend, :font, :size)),
		get(_symbol_dict(get(p.layout.fields, :font, nothing)), :size, nothing),
		_legend_template_layout_value(p, (:font, :size)),
	)
		size = _legend_real(value)
		(size === nothing || size <= 0) || return size
	end
	return Float64(_PLOTLY_DEFAULT_FONT_SIZE)
end

# Font family (CSS list) of the entries of legend box `box`: the box's font,
# the template's legend font, the layout font, the template font, else the
# scoped style's family.
function _legend_entry_font_family(p::Plot, box::AbstractDict)
	for value in (
		get(_symbol_dict(get(box, :font, nothing)), :family, nothing),
		_legend_template_layout_value(p, (:legend, :font, :family)),
		get(_symbol_dict(get(p.layout.fields, :font, nothing)), :family, nothing),
		_legend_template_layout_value(p, (:font, :family)),
	)
		value isa AbstractString && !isempty(strip(value)) && return String(value)
	end
	return _text_scope_family()
end

# Font size (px) of the title of legend box `box`: its own, else plotly.js's
# default, the entry font enlarged by 1.2 and rounded (legend/defaults.js
# `Lib.bigFont`).
function _legend_title_size(p::Plot, box::AbstractDict)
	title = _symbol_dict(get(box, :title, nothing))
	own = _legend_real(get(_symbol_dict(get(title, :font, nothing)), :size, nothing))
	(own === nothing || own <= 0) || return own
	return Float64(round(1.2 * _legend_entry_font_size(p, box)))
end

# Estimated px width of each entry of `indices` as plotly.js lays it out
# (legend/draw.js `getLegendItemWidth`): textGap (indentation + itemwidth + 2
# itemGap) plus the trace's own `legendwidth`, else the box's `entrywidth` in
# pixels, else the label.
function _legend_entry_widths(p::Plot, box::AbstractDict, indices::Vector{Int})
	fontsize = _legend_entry_font_size(p, box)
	family = _legend_entry_font_family(p, box)
	itemwidth = something(_legend_real(get(box, :itemwidth, nothing)), Float64(_LEGEND_DEFAULT_ITEMWIDTH))
	indentation = something(_legend_real(get(box, :indentation, nothing)), 0.0)
	textgap = indentation + itemwidth + 2 * _LEGEND_ITEM_GAP
	entrywidth = get(box, :entrywidthmode, "pixels") == "fraction" ? nothing :
		_legend_real(get(box, :entrywidth, nothing))
	return map(indices) do index
		fields = p.data[index].fields
		own = _legend_real(get(fields, :legendwidth, nothing))
		(own !== nothing && own > 0) && return textgap + own
		(entrywidth !== nothing && entrywidth > 0) && return textgap + entrywidth
		name = get(fields, :name, "")
		return textgap + _text_extent(name isa AbstractString ? name : string(name), fontsize; family = family)[1]
	end
end

# Column (1-based) of each of `m` entries in `n` columns: column-major ('c',
# matplotlib's distribution - the first `m mod n` columns take one entry more)
# or row-major ('r').
function _legend_column_assignment(m::Int, n::Int, order::Char)
	n = max(min(n, m), 1)
	order == 'r' && return [mod1(j, n) for j in 1:m]
	rows, large = divrem(m, n)
	columns = Int[]
	for k in 1:n
		append!(columns, Iterators.repeated(k, k <= large ? rows + 1 : rows))
	end
	return columns
end

# Estimated px width of a column legend: the columns (widest entry + itemGap
# each), the frame, and a title drawn at the left.
function _legend_columns_width(widths::Vector{Float64}, columns::Vector{Int}, frame::Float64, title_width::Float64)
	isempty(widths) && return 2 * frame + title_width
	total = 0.0
	for k in unique(columns)
		total += maximum(widths[j] for j in eachindex(widths) if columns[j] == k) + _LEGEND_ITEM_GAP
	end
	return total + 2 * frame + title_width
end

# Width (px) of the plot area plotly.js will lay the figure out in, from
# `layout.width` (else the export default, `_style_default_figure_size`) and the left/right margins
# (layout, template, plotly default 80 px). Automatic margins only shrink it,
# which the column fit absorbs through the generous label estimates.
function _legend_plot_area_width(p::Plot)
	width = _tight_real(get(p.layout.fields, :width, nothing), Float64(_figure_default_size(p)[1]))
	return max(width - _legend_margin_lr(p, :l) - _legend_margin_lr(p, :r), 1.0)
end

# Left or right figure margin (px): the layout's, the template's, else
# plotly.js' default.
function _legend_margin_lr(p::Plot, key::Symbol)
	margin = _symbol_dict(get(p.layout.fields, :margin, nothing))
	return something(
		_legend_real(get(margin, key, nothing)),
		_legend_real(_legend_template_layout_value(p, (:margin, key))),
		_LEGEND_DEFAULT_MARGIN_LR,
	)
end

# Width (px) a legend may take before plotly.js wraps it: the cell's share of
# the plot area for a cell legend (`span < 1`), the plot area for a legend
# anchored inside the paper, half the figure for one anchored left or right of
# it. A cell legend in the band above or below its cell (`legend_id` given) may
# reach from its anchor to the nearest plot area of the same row, or into the
# figure margin beside the grid (`_legend_band_interval`), as matplotlib's
# legends above the axes do.
function _legend_available_width(p::Plot, box::AbstractDict, span::Float64; legend_id = nothing)
	x = _legend_real(get(box, :x, nothing))
	area = _legend_plot_area_width(p)
	if get(box, :xref, "paper") == "paper" && x !== nothing && (x < 0 || x > 1)
		return _tight_real(get(p.layout.fields, :width, nothing), Float64(_figure_default_size(p)[1])) / 2
	end
	cell = area * clamp(span, 0.0, 1.0)
	(legend_id === nothing || span >= 1 || x === nothing) && return cell
	get(box, :yref, "paper") == "paper" || return cell
	domain = _legend_cell_domain(p, String(legend_id))
	domain === nothing && return cell
	xdom, ydom = domain
	y = _legend_real(get(box, :y, nothing))
	yanchor = get(box, :yanchor, nothing)
	in_band = y !== nothing && (
		(yanchor == "bottom" && y >= ydom[2] - 1e-9) || (yanchor == "top" && y <= ydom[1] + 1e-9)
	)
	in_band || return cell
	lo, hi = _legend_band_interval(p, xdom, ydom)
	reach = get(box, :xanchor, nothing) == "right" ? x - lo :
		get(box, :xanchor, nothing) == "left" ? hi - x :
		get(box, :xanchor, nothing) == "center" ? 2 * min(x - lo, hi - x) : nothing
	reach === nothing && return cell
	# plotly.js 2.35.2 wraps a horizontal legend anchored inside the paper at
	# the plot-area width (`computeLegendDimensions`, `_maxWidth = gs.w`).
	return clamp(reach * area, cell, area)
end

# Paper domains `(xdom, ydom)` of the cell legend `legend_id` lists (the cell
# of its first trace), or `nothing`.
function _legend_cell_domain(p::Plot, legend_id::String)
	for trace in p.data
		trace isa GenericTrace || continue
		_legend_trace_legend_id(trace) == legend_id || continue
		_trace_is_figure_legend_entry(trace) && continue
		key_domain = _trace_subplot_key_domain(p, trace)
		key_domain === nothing || return key_domain[2]
	end
	return nothing
end

# Paper x interval `(lo, hi)` free in the band above or below the cell with
# domains `xdom` x `ydom`: from the right edge of the nearest plot area to its
# left whose y domain overlaps the cell's (else the figure's left edge, in the
# margin) to the left edge of the nearest one to its right (else the figure's
# right edge).
function _legend_band_interval(p::Plot, xdom, ydom)
	area = _legend_plot_area_width(p)
	lo = -_legend_margin_lr(p, :l) / area
	hi = 1 + _legend_margin_lr(p, :r) / area
	for (key, value) in p.layout.fields
		name = String(key)
		domains = if occursin(r"^xaxis[0-9]*$", name)
			entry = _symbol_dict(value)
			cx = _domain_tuple(get(entry, :domain, nothing))
			anchor = get(entry, :anchor, nothing)
			(cx === nothing || !(anchor isa AbstractString) || !startswith(anchor, "y")) && continue
			cy = _layout_axis_domain(p.layout, _axis_layout_key(anchor, :y))
			cy === nothing && continue
			(cx, cy)
		elseif occursin(r"^(scene|polar|geo|ternary|smith|map|mapbox)[0-9]*$", name)
			_layout_subplot_domain(p.layout, key)
		else
			nothing
		end
		domains === nothing && continue
		cx, cy = domains
		# another row: no overlap with the cell's y domain
		(cy[2] <= ydom[1] + 1e-9 || cy[1] >= ydom[2] - 1e-9) && continue
		cx[2] <= xdom[1] + 1e-9 && (lo = max(lo, cx[2]))
		cx[1] >= xdom[2] - 1e-9 && (hi = min(hi, cx[1]))
	end
	return lo, hi
end

# Remove the column groups of legend `legend_id` (all legends when `nothing`)
# from the traces; returns the ids of the legends that had some. An entry whose
# merged duplicates (`_legend_dedupe!`: hidden members in the group named after
# the entry's trace index) still exist rejoins their group, so a click toggles
# them together again.
function _legend_clear_column_groups!(p::Plot, legend_id = nothing)
	cleared = Set{String}()
	merged = Set{String}()
	for trace in p.data
		trace isa GenericTrace || continue
		group = get(trace.fields, :legendgroup, nothing)
		(group isa AbstractString && startswith(group, _LEGEND_DEDUPE_GROUP_PREFIX)) && push!(merged, group)
	end
	for (index, trace) in enumerate(p.data)
		trace isa GenericTrace || continue
		info = _legend_column_info(get(trace.fields, :legendgroup, nothing))
		info === nothing && continue
		(legend_id === nothing || info[1] == legend_id) || continue
		delete!(trace.fields, :legendgroup)
		linked = _LEGEND_DEDUPE_GROUP_PREFIX * info[1] * ":" * string(index)
		linked in merged && (trace.fields[:legendgroup] = linked)
		push!(cleared, info[1])
	end
	return cleared
end

# Box fields of a legend after its columns are removed: plotly's own default
# order would become "grouped" again if other legend groups remain.
function _legend_uncolumn_box!(p::Plot, legend_id::AbstractString)
	key = Symbol(legend_id)
	haskey(p.layout.fields, key) || return nothing
	d = _symbol_dict(p.layout.fields[key])
	order = get(d, :traceorder, nothing)
	if order isa AbstractString && occursin("grouped", order)
		d[:traceorder] = occursin("reversed", order) ? "reversed" : "normal"
		p.layout.fields[key] = attr(; d...)
	end
	return nothing
end

"""
	_legend_apply_columns!(p, legend_id, ncols; fill='c', span=1.0, who="set_legend!") -> Int

Lay the entries of legend `legend_id` out in at most `ncols` columns (legend
groups, see the note above): column-major (`fill='c'`, as matplotlib's
`ncols`) or row-major (`fill='r'`, a horizontal legend wrapped into rows).
The column count is reduced until the estimated legend width fits the width
available to it (`span` = the cell's paper width for a cell legend), so a
legend never runs into the neighbouring cell; with `who` non-empty a reduction
is reported with a warning. Each entry's previous legend group (a stem or
merged-duplicate group, or a user group) is replaced; the box gets
`orientation="h"`, `traceorder="grouped"` (keeping "reversed"), no fraction
`entrywidth` (a pixel one is kept and sizes the entries), and a title on top
unless `title.side` is set; `layout.legend`
gets `groupclick="toggleitem"` so a click toggles one entry, not its column.
Legends that list pie slices, and legends without entries, get no columns.
Returns the number of columns used (0 = none).
"""
function _legend_apply_columns!(
	p::Plot,
	legend_id::AbstractString,
	ncols::Integer;
	fill::Char = 'c',
	span::Real = 1.0,
	who::AbstractString = "set_legend!",
)
	legend_id = String(legend_id)
	_legend_clear_column_groups!(p, legend_id)
	key = Symbol(legend_id)
	box = _symbol_dict(get(p.layout.fields, key, nothing))
	indices = _legend_entry_indices(p, legend_id)
	if ncols < 1 || isempty(indices) || _legend_lists_slices(p, legend_id)
		_legend_uncolumn_box!(p, legend_id)
		return 0
	end
	widths = _legend_entry_widths(p, box, indices)
	frame = something(_legend_real(get(box, :borderwidth, nothing)), 0.0)
	title = _symbol_dict(get(box, :title, nothing))
	title_text = get(title, :text, "")
	has_title = title_text isa AbstractString && !isempty(strip(title_text))
	# plotly.js 2.35.2 shifts the entries right by the title width for every
	# side containing "left" ("left" and "top left": `computeLegendDimensions`).
	title_left = has_title && occursin("left", string(get(title, :side, "top")))
	title_width = title_left ? _text_extent(title_text, _legend_entry_font_size(p, box))[1] + 2 * _LEGEND_ITEM_GAP : 0.0
	available = _legend_available_width(p, box, Float64(span); legend_id = legend_id)
	wanted = min(Int(ncols), length(indices))
	used = wanted
	columns = _legend_column_assignment(length(indices), used, fill)
	while used > 1 && _legend_columns_width(widths, columns, frame, title_width) > available
		used -= 1
		columns = _legend_column_assignment(length(indices), used, fill)
	end
	if used < wanted && !isempty(who)
		@warn "$(who): $(wanted) legend columns of these labels (about " *
			"$(round(Int, _legend_columns_width(widths, _legend_column_assignment(length(indices), wanted, fill), frame, title_width))) px) " *
			"do not fit the $(round(Int, available)) px available to legend " *
			"$(repr(legend_id)); using $(used). Shorten the labels, use a " *
			"smaller `fontsize`, or place the legend outside the axes."
	end
	for (j, index) in enumerate(indices)
		p.data[index].fields[:legendgroup] = _legend_column_group(legend_id, fill, columns[j], used)
	end
	order = get(box, :traceorder, nothing)
	box[:traceorder] = (order isa AbstractString && occursin("reversed", order)) ? "reversed+grouped" : "grouped"
	box[:orientation] = "h"
	# A fraction `entrywidth` scales with the plot area (G59); a pixel one is
	# kept, and the widths above already use it.
	if get(box, :entrywidthmode, "pixels") == "fraction"
		delete!(box, :entrywidth)
		delete!(box, :entrywidthmode)
	end
	if has_title && !haskey(title, :side)
		title[:side] = "top"
		box[:title] = attr(; title...)
	end
	p.layout.fields[key] = attr(; box...)
	_legend_set_groupclick!(p)
	return used
end

# plotly.js 2.35.2 reads `groupclick` from `layout.legend` for every legend.
function _legend_set_groupclick!(p::Plot)
	haskey(p.layout.fields, :legend) || return nothing
	d = _symbol_dict(p.layout.fields[:legend])
	get(d, :groupclick, nothing) == "toggleitem" && return nothing
	d[:groupclick] = "toggleitem"
	p.layout.fields[:legend] = attr(; d...)
	return nothing
end

# (fill, column count) of the column layout legend `legend_id` has, or nothing.
function _legend_column_layout(p::Plot, legend_id::AbstractString)
	for trace in p.data
		trace isa GenericTrace || continue
		info = _legend_column_info(get(trace.fields, :legendgroup, nothing))
		(info !== nothing && info[1] == legend_id) && return (info[2], info[4])
	end
	return nothing
end

_legend_box_orientation(p::Plot, legend_id::AbstractString) =
	get(_symbol_dict(get(p.layout.fields, Symbol(legend_id), nothing)), :orientation, "v")

"""
	_legend_relayout_columns!(p, legend_id, opts; span = 1.0, cell = false)

Column layout of legend `legend_id` after an explicit `set_legend!` /
`subplot_legends!` call with validated options `opts`: `ncols > 1` lays the
entries out in that many columns (fewer if they do not fit, with a warning);
`ncols = 1` (a vertical legend) and `orientation = :v` remove the columns;
otherwise an existing column layout
is rebalanced over the current entries. A cell legend (`cell = true`) that is
horizontal without `ncols` is wrapped into as many row-major columns as fit
the cell (G59), instead of plotly's wrapping at the width of the whole plot
area. `span` is the legend's share of the plot-area width.
"""
function _legend_relayout_columns!(p::Plot, legend_id::AbstractString, opts; span::Real = 1.0, cell::Bool = false)
	who = isempty(opts.who) ? "set_legend!" : opts.who
	if opts.ncols > 1 || (opts.ncols == 1 && opts.orientation == "h")
		_legend_apply_columns!(p, legend_id, opts.ncols; fill = 'c', span = span, who = who)
		return nothing
	end
	if opts.ncols == 1 || opts.orientation == "v"
		isempty(_legend_clear_column_groups!(p, legend_id)) || _legend_uncolumn_box!(p, legend_id)
		return nothing
	end
	layout = _legend_column_layout(p, legend_id)
	if layout !== nothing
		fill, n = layout
		count = fill == 'r' ? length(p.data) : n
		_legend_apply_columns!(p, legend_id, count; fill = fill, span = span, who = "")
	elseif cell && _legend_box_orientation(p, legend_id) == "h"
		_legend_apply_columns!(p, legend_id, length(p.data); fill = 'r', span = span, who = "")
	end
	return nothing
end

"""
	_legend_extend_columns!(p; first = 1)

Give entries that joined a column legend after its layout (traces from index
`first` on that list in a legend whose other entries carry its column groups)
their column: the next free column, else the last one, for a column-major
legend; the next slot of the row for a row-major one. Earlier entries are not
touched, so this is safe on the append-only transaction path; the columns are
rebalanced by the next `set_legend!`.
"""
function _legend_extend_columns!(p::Plot; first::Integer = 1)
	layouts = Dict{String, Tuple{Char, Int}}()
	for trace in p.data
		trace isa GenericTrace || continue
		info = _legend_column_info(get(trace.fields, :legendgroup, nothing))
		info === nothing && continue
		legend_id, fill, _, n = info
		_legend_trace_legend_id(trace) == legend_id || continue
		haskey(layouts, legend_id) || (layouts[legend_id] = (fill, n))
	end
	isempty(layouts) && return nothing
	for (legend_id, (fill, n)) in layouts
		indices = _legend_entry_indices(p, legend_id)
		used = Set{Int}()
		for (j, index) in enumerate(indices)
			trace = p.data[index]
			info = _legend_column_info(get(trace.fields, :legendgroup, nothing))
			if info !== nothing && info[1] == legend_id && info[2] == fill && info[4] == n
				push!(used, info[3])
				continue
			end
			index >= first || continue
			column = if fill == 'r'
				mod1(j, n)
			else
				length(used) < n ? something(findfirst(k -> !(k in used), 1:n), n) : n
			end
			trace.fields[:legendgroup] = _legend_column_group(legend_id, fill, column, n)
			push!(used, column)
		end
	end
	return nothing
end

# ── Data-avoiding placement of cell legends (Y17) ────────────────────────────
#
# A SubplotFigure cell legend at the package default (top right) goes to the
# position of `_SCAT_LEGEND_POSITIONS` that covers the least of the cell's
# data, as a Plot's legend does (`_scat_best_legend_position`): Cartesian
# cells (any y axes, so a secondary y counts) score their points, line
# segments and filled areas; polar cells rank the positions by the data they
# cover (points with their marker radius, line segments, `toself` areas),
# then by the tick labels they cover (the angular ones around the circle, the
# radial ones along `radialaxis.angle`), then by how far they reach into the
# polar disk (its grid), and never take the centre. When every position covers something, the one covering the
# least is used (ties keep the candidate order, top right first): a legend
# wider than the room beside a polar disk covers a tick label, and a large
# legend in a small Cartesian cell can still cross data (place it with
# `set_legend!(sf; row, col, position)`, e.g. `:outside_right`, then). Cells
# the estimate does not model (other trace types, categorical or date
# coordinates, polar sectors, holes or fills to another trace) keep the top
# right corner.

# Angular tick labels of a polar cell (measured on plotly.js 2.35.2 renders,
# 12 px font): one every 45 degrees (whatever the size) unless `dtick` or
# `tickvals` say otherwise, each about 26 x 15 px ("135°"), its near edge
# 3 px outside the circle.
const _LEGEND_POLAR_LABEL_GAP = 3.0
const _LEGEND_POLAR_LABEL_HALF = (13.0, 7.5)
const _LEGEND_POLAR_LABEL_STEP = 45.0
# Marker radius (px) assumed when a polar trace does not set `marker.size`
# (plotly.js' default size 6).
const _LEGEND_POLAR_MARKER_RADIUS = 3.0
# The radial tick labels run from the centre to the circle along
# `radialaxis.angle` (a screen angle, counterclockwise from east, whatever the
# angular rotation and direction; measured), within about this many px of
# that line.
const _LEGEND_POLAR_RADIAL_LABEL_PX = 10.0

# Size (px) of legend box `legend_id` as plotly.js lays it out: column
# legends by their columns, horizontal ones as one row, vertical ones by
# their widest entry, plus a title drawn at the left (a title on top widens
# the box to its own width); the height from `_legend_box_height`. `nothing`
# when the legend lists nothing or is hidden. `before > 0` counts only the
# entries of traces before index `before` (the legend before an append).
function _legend_box_size(p::Plot, legend_id::AbstractString; before::Integer = 0)
	box = _symbol_dict(get(p.layout.fields, Symbol(legend_id), nothing))
	get(box, :visible, true) === false && return nothing
	indices = _legend_entry_indices(p, legend_id)
	before > 0 && filter!(index -> index < before, indices)
	isempty(indices) && return nothing
	widths = _legend_entry_widths(p, box, indices)
	frame = something(_legend_real(get(box, :borderwidth, nothing)), 0.0)
	title = _symbol_dict(get(box, :title, nothing))
	title_text = get(title, :text, "")
	title_px = title_text isa AbstractString && !isempty(strip(title_text)) ?
		_text_extent(title_text, _legend_title_size(p, box); family = _legend_entry_font_family(p, box))[1] +
		2 * _LEGEND_ITEM_GAP : 0.0
	orientation = get(box, :orientation, "v")
	title_left = title_px > 0 &&
		occursin("left", string(get(title, :side, orientation == "h" ? "left" : "top")))
	width = if _legend_column_layout(p, legend_id) !== nothing
		columns = map(indices) do index
			info = _legend_column_info(get(p.data[index].fields, :legendgroup, nothing))
			info === nothing ? 0 : info[3]
		end
		_legend_columns_width(widths, columns, frame, 0.0)
	elseif orientation == "h"
		sum(widths) + _LEGEND_ITEM_GAP * length(widths) + 2 * frame
	else
		maximum(widths) + _LEGEND_ITEM_GAP + 2 * frame
	end
	width = title_left ? width + title_px : max(width, title_px + 2 * frame)
	return (width, _legend_box_height(p, legend_id, indices))
end

# Slack (px) added to the estimated (width, height) of a cell legend before
# scoring positions: `_legend_box_size` is within about 5 px of the width and
# exact in height for the boxes plotly.js 2.35.2 draws (measured: 74.8 vs 78,
# 107 vs 110, 246.7 vs 242 px wide; 31 and 50 px high), and a Cartesian marker
# reaches a few px beyond its centre.
const _LEGEND_CELL_SLACK_PX = (4.0, 2.0)

"""
	_legend_best_cell_position(p, legend_id, xdom, ydom; before = 0) -> Union{Symbol, Nothing}

The position of `_SCAT_LEGEND_POSITIONS` (relative to the cell's axes) where
cell legend `legend_id` of the cell with paper domains `xdom` x `ydom` covers
the least data (see the note above), or `nothing` when the estimate does not
apply. `before > 0` scores only the traces before index `before` (the cell as
it was before an append), to tell an automatic placement from the user's.
"""
function _legend_best_cell_position(p::Plot, legend_id::AbstractString, xdom, ydom; before::Integer = 0)
	indices = Int[]
	for (index, trace) in enumerate(p.data)
		before > 0 && index >= before && break
		trace isa GenericTrace || continue
		_trace_is_figure_legend_entry(trace) && continue
		_legend_trace_legend_id(trace) == legend_id || continue
		push!(indices, index)
	end
	isempty(indices) && return nothing
	width_px, height_px = _scat_legend_figure_px(p.layout)
	w = width_px * (xdom[2] - xdom[1])
	h = height_px * (ydom[2] - ydom[1])
	(w > 0 && h > 0) || return nothing
	legend_size = _legend_box_size(p, legend_id; before = before)
	legend_size === nothing && return nothing
	legend_size = (legend_size[1] + _LEGEND_CELL_SLACK_PX[1], legend_size[2] + _LEGEND_CELL_SLACK_PX[2])
	first_trace = p.data[indices[1]]
	if string(get(first_trace.fields, :type, "scatter")) in ("scatterpolar", "scatterpolargl")
		subplot = Symbol(string(get(first_trace.fields, :subplot, "polar")))
		return _legend_best_polar_position(p, indices, subplot, w, h, legend_size)
	end
	# Cartesian cell: the host's traces are scored as data; the traces of an
	# inset the cell hosts (listed in the host's legend, `_legend_inset_host`)
	# make the inset's rectangle an obstacle.
	cell_key = _trace_subplot_key_domain(p, first_trace)
	cell_key === nothing && return nothing
	startswith(cell_key[1], "xy:") || return nothing
	host_x = first(split(cell_key[1][4:end], '|'))
	main = Int[]
	obstacles = NTuple{4, Float64}[]
	for index in indices
		fields = p.data[index].fields
		base_x = _legend_base_axis_ref(p.layout, string(get(fields, :xaxis, "x")), :x)
		if base_x == host_x
			push!(main, index)
			continue
		end
		base_y = _legend_base_axis_ref(p.layout, string(get(fields, :yaxis, "y")), :y)
		inset_x = _layout_axis_domain(p.layout, _axis_layout_key(base_x, :x))
		inset_y = _layout_axis_domain(p.layout, _axis_layout_key(base_y, :y))
		(inset_x === nothing || inset_y === nothing) && return nothing
		rect = (
			(inset_x[1] - xdom[1]) / (xdom[2] - xdom[1]),
			(inset_x[2] - xdom[1]) / (xdom[2] - xdom[1]),
			(inset_y[1] - ydom[1]) / (ydom[2] - ydom[1]),
			(inset_y[2] - ydom[1]) / (ydom[2] - ydom[1]),
		)
		rect in obstacles || push!(obstacles, rect)
	end
	# With every position covering data the legend goes below its cell, when
	# its entries side by side fit the cell's width (a wider one would run
	# over its neighbours: it keeps the position covering the least).
	outside = _legend_row_width(p, legend_id, before) <= w ? :outside_bottom : nothing
	return _scat_best_legend_position(
		p, main, _axis_layout_key(host_x, :x), host_x, w, h, legend_size;
		obstacles = obstacles, outside = outside,
	)
end

# Width (px) of legend `legend_id` laid out as one row (the `:outside_bottom`
# orientation): its entries side by side with their gaps and the frame;
# `Inf` when it lists nothing. `before > 0` counts the entries before trace
# index `before` only.
function _legend_row_width(p::Plot, legend_id::AbstractString, before::Integer = 0)
	box = _symbol_dict(get(p.layout.fields, Symbol(legend_id), nothing))
	indices = _legend_entry_indices(p, legend_id)
	before > 0 && filter!(index -> index < before, indices)
	isempty(indices) && return Inf
	widths = _legend_entry_widths(p, box, indices)
	frame = something(_legend_real(get(box, :borderwidth, nothing)), 0.0)
	return sum(widths) + _LEGEND_ITEM_GAP * length(widths) + 2 * frame
end

# Box (fractions of the cell) of each candidate position for a legend of
# `box_w` x `box_h` (fractions), as `_scat_best_legend_position` builds them.
function _legend_candidate_boxes(box_w::Float64, box_h::Float64)
	return map(_SCAT_LEGEND_POSITIONS) do position
		x, y, xanchor, yanchor = _legend_anchor((0.0, 1.0), (0.0, 1.0), _DEFAULT_LEGEND_INSET[], position)
		u0 = xanchor == "left" ? x : xanchor == "right" ? x - box_w : x - box_w / 2
		v0 = yanchor == "bottom" ? y : yanchor == "top" ? y - box_h : y - box_h / 2
		(u0, u0 + box_w, v0, v0 + box_h)
	end
end

# Polar cell of `w` x `h` px (subplot layout key `subplot`): the circle is
# centred in the cell with radius min(w, h) / 2 (plotly.js polar, full
# sector); `r` maps linearly from the radial range (explicit, else from
# min(0, r) to max(r)), `theta` in degrees from `angularaxis.rotation` in its
# `direction`. `nothing` for sectors, holes, non-linear or categorical axes,
# other trace types, or non-numeric coordinates.
function _legend_best_polar_position(p::Plot, indices, subplot::Symbol, w::Float64, h::Float64, legend_size)
	polar = _symbol_dict(get(p.layout.fields, subplot, nothing))
	radial = _symbol_dict(get(polar, :radialaxis, nothing))
	angular = _symbol_dict(get(polar, :angularaxis, nothing))
	sector = get(polar, :sector, nothing)
	if sector !== nothing
		(sector isa AbstractVector && length(sector) == 2 && all(v -> v isa Real, sector) &&
			abs(sector[2] - sector[1]) >= 360) || return nothing
	end
	something(_legend_real(get(polar, :hole, nothing)), 0.0) == 0 || return nothing
	get(angular, :thetaunit, "degrees") == "degrees" || return nothing
	get(angular, :type, "-") in ("-", "linear") || return nothing
	get(radial, :type, "-") in ("-", "linear") || return nothing
	rotation = something(_legend_real(get(angular, :rotation, nothing)), 0.0)
	turn = get(angular, :direction, "counterclockwise") == "clockwise" ? -1.0 : 1.0

	# (r, theta, draws lines, filled to itself, marker radius in px)
	series = Tuple{Vector{Float64}, Vector{Float64}, Bool, Bool, Float64}[]
	for index in indices
		fields = p.data[index].fields
		visible = get(fields, :visible, true)
		(visible === false || visible == "legendonly") && continue
		string(get(fields, :type, "scatter")) in ("scatterpolar", "scatterpolargl") || return nothing
		string(get(fields, :subplot, "polar")) == String(subplot) || return nothing
		fill = string(get(fields, :fill, "none"))
		fill in ("", "none", "toself") || return nothing
		r = _scat_legend_coords(get(fields, :r, nothing), false)
		theta = _scat_legend_coords(get(fields, :theta, nothing), false)
		(r === nothing || theta === nothing) && return nothing
		n = min(length(r), length(theta))
		n == 0 && continue
		mode = string(get(fields, :mode, "lines"))
		size = _legend_real(_cmn_mapping_get(get(fields, :marker, nothing), :size))
		marker = occursin("markers", mode) ?
			(size === nothing ? _LEGEND_POLAR_MARKER_RADIUS : size / 2) : 0.0
		push!(series, (r[1:n], theta[1:n], occursin("lines", mode), fill == "toself", marker))
	end
	range = get(radial, :range, nothing)
	lo, hi = if range isa AbstractVector && length(range) == 2 && all(v -> v isa Real && isfinite(v), range)
		Float64(range[1]), Float64(range[2])
	else
		finite = collect(Iterators.filter(isfinite, Iterators.flatten(s[1] for s in series)))
		isempty(finite) ? (0.0, 1.0) : (min(0.0, minimum(finite)), maximum(finite))
	end
	hi == lo && (hi = lo + 1)

	radius = min(w, h) / 2
	position(rho, angle) = (0.5 + rho * cosd(angle) / w, 0.5 + rho * sind(angle) / h)
	box_w = min(0.95, legend_size[1] / w)
	box_h = min(0.95, legend_size[2] / h)
	boxes = _legend_candidate_boxes(box_w, box_h)
	data = zeros(Int, length(boxes))
	for (rs, thetas, lines, filled, marker) in series
		stride = max(1, cld(length(rs), _SCAT_LEGEND_MAX_POINTS))
		pad_u, pad_v = marker / w, marker / h
		us = Float64[]
		vs = Float64[]
		previous = nothing
		for index in 1:stride:length(rs)
			if !(isfinite(rs[index]) && isfinite(thetas[index]))
				previous = nothing
				push!(us, NaN)
				push!(vs, NaN)
				continue
			end
			rho = clamp((rs[index] - lo) / (hi - lo), 0.0, 1.0) * radius
			u, v = position(rho, rotation + turn * thetas[index])
			push!(us, u)
			push!(vs, v)
			for (k, (u0, u1, v0, v1)) in enumerate(boxes)
				hit = (marker > 0 && u0 - pad_u <= u <= u1 + pad_u && v0 - pad_v <= v <= v1 + pad_v) ||
					(lines && previous !== nothing &&
						_scat_segment_hits_box(previous[1], previous[2], u, v, u0, u1, v0, v1))
				hit && (data[k] += 1)
			end
			previous = (u, v)
		end
		filled && _scat_legend_fill_scores!(data, us, vs, boxes)
	end
	labels = zeros(Int, length(boxes))
	if get(angular, :showticklabels, true) !== false
		half_u = _LEGEND_POLAR_LABEL_HALF[1] / w
		half_v = _LEGEND_POLAR_LABEL_HALF[2] / h
		for angle in _legend_polar_tick_angles(angular)
			direction = rotation + turn * angle
			# centre of the label box, its near edge `_LEGEND_POLAR_LABEL_GAP` px
			# outside the circle
			rho = radius + _LEGEND_POLAR_LABEL_GAP +
				abs(cosd(direction)) * _LEGEND_POLAR_LABEL_HALF[1] +
				abs(sind(direction)) * _LEGEND_POLAR_LABEL_HALF[2]
			u, v = position(rho, direction)
			for (k, (u0, u1, v0, v1)) in enumerate(boxes)
				(u0 < u + half_u && u - half_u < u1 && v0 < v + half_v && v - half_v < v1) &&
					(labels[k] += 1)
			end
		end
	end
	if get(radial, :visible, true) !== false && get(radial, :showticklabels, true) !== false
		start = sector isa AbstractVector && !isempty(sector) && sector[1] isa Real ? Float64(sector[1]) : 0.0
		angle = something(_legend_real(get(radial, :angle, nothing)), start)
		u_end, v_end = position(radius, angle)
		pad_u = _LEGEND_POLAR_RADIAL_LABEL_PX / w
		pad_v = _LEGEND_POLAR_RADIAL_LABEL_PX / h
		for (k, (u0, u1, v0, v1)) in enumerate(boxes)
			_scat_segment_hits_box(0.5, 0.5, u_end, v_end, u0 - pad_u, u1 + pad_u, v0 - pad_v, v1 + pad_v) &&
				(labels[k] += 1)
		end
	end
	# Depth (px) a box reaches into the disk: its grid lines.
	depth = map(boxes) do (u0, u1, v0, v1)
		du = max(u0 - 0.5, 0.0, 0.5 - u1) * w
		dv = max(v0 - 0.5, 0.0, 0.5 - v1) * h
		max(radius - hypot(du, dv), 0.0)
	end
	ranks = map(eachindex(boxes)) do k
		_SCAT_LEGEND_POSITIONS[k] === :center ? (typemax(Int), typemax(Int), Inf) :
			(data[k], labels[k], depth[k])
	end
	# `argmin` returns the first minimum: ties keep the candidate order.
	return _SCAT_LEGEND_POSITIONS[argmin(ranks)]
end

# Angles (degrees) of the angular tick labels of polar `angularaxis` settings
# `angular`: its numeric `tickvals`, else every `dtick` degrees (a positive
# number), else every `_LEGEND_POLAR_LABEL_STEP` (plotly.js' default).
function _legend_polar_tick_angles(angular::AbstractDict)
	tickvals = get(angular, :tickvals, nothing)
	if tickvals isa AbstractVector && !isempty(tickvals)
		return [Float64(v) for v in tickvals if v isa Real && !(v isa Bool) && isfinite(v)]
	end
	dtick = _legend_real(get(angular, :dtick, nothing))
	step = dtick !== nothing && dtick >= 1 ? dtick : _LEGEND_POLAR_LABEL_STEP
	return collect(0.0:step:(360.0 - step / 2))
end

# ─────────────────────────────────────────────────────────────────────────────
# F14: titles and panel labels
# ─────────────────────────────────────────────────────────────────────────────

# Gap (px) between the top edge of the figure and a `title!` figure title; the
# title is container-anchored with `automargin`, so the plot area moves down
# when the title needs more room (it never overlaps an outside-top legend).
const _TEXT_TITLE_TOP_PAD = 10
# Gap (px) between a panel title / outside panel label and the axes edge.
const _TEXT_PANEL_GAP = 4

function _text_align(align, who::AbstractString)
	(align isa Symbol || align isa AbstractString) || throw(ArgumentError(
		"$(who): `align` must be :left, :center or :right; got $(repr(align)).",
	))
	a = Symbol(lowercase(String(align)))
	a in (:left, :center, :right) || throw(ArgumentError(
		"$(who): `align` must be :left, :center or :right; got $(repr(align)).",
	))
	return a
end

_text_mathtext_align(align::Symbol) = align === :left ? :l : align === :right ? :r : :c

_text_is_math(label::AbstractString) =
	length(label) >= 2 && startswith(label, '$') && endswith(label, '$')

# B4: bold text without breaking math. Plain labels are wrapped in `<b>…</b>`;
# a mathtext label (one `$…$` expression, where `_label` writes the text runs
# as `\text{…}`) gets `\textbf{…}` for those runs instead, because an HTML tag
# around math stops plotly from typesetting it. Pure math stays as it is.
function _text_bold(label::String)
	isempty(label) && return label
	_text_is_math(label) || return "<b>" * label * "</b>"
	return replace(label, r"(?<!\\)((?:\\\\)*)\\text\{" => s"\1\\textbf{")
end

function _text_label(text::AbstractString, align::Symbol, bold::Bool, who::AbstractString)
	label = _text_checked_label(text, who; align = _text_mathtext_align(align))
	return bold ? _text_bold(label) : label
end

# Figure-title offset checks (`offset = (dx, dy)` in px). A centred title has
# no horizontal padding in plotly.js (pad.l/pad.r apply only to a left/right
# `xanchor`), and the title cannot move above the top edge of the figure.
function _text_check_figure_offset(text::AbstractString, align::Symbol, offset)
	isempty(text) && return nothing
	dx, dy = offset
	align === :center && dx != 0 && throw(ArgumentError(
		"title!: a centred figure title cannot be shifted horizontally (Plotly " *
		"ignores the padding of centred titles); use `align=:left` or `:right` " *
		"with `offset`.",
	))
	dy > _TEXT_TITLE_TOP_PAD && throw(ArgumentError(
		"title!: `offset[2] = $(_text_number(dy))` would move the figure title above the " *
		"top edge of the figure (it sits $(_TEXT_TITLE_TOP_PAD) px below it); use at most " *
		"$(_TEXT_TITLE_TOP_PAD).",
	))
	return nothing
end

function _text_figure_title!(fig, text, align::Symbol, fontsize::Float64, bold::Bool, offset)
	dx, dy = offset
	updates = Dict{Symbol, Any}()
	if isempty(text)
		updates[:title_text] = ""
	else
		updates[:title_text] = _text_label(text, align, bold, "title!")
		x, xanchor = align === :left ? (0, "left") : align === :right ? (1, "right") : (0.5, "center")
		updates[:title_x] = x
		updates[:title_xanchor] = xanchor
		updates[:title_xref] = "paper"
		updates[:title_yref] = "container"
		updates[:title_y] = 1
		updates[:title_yanchor] = "top"
		updates[:title_automargin] = true
		updates[:title_pad_t] = _text_number(_TEXT_TITLE_TOP_PAD - dy)
		# plotly.js shifts a left-anchored title right by pad.l and a
		# right-anchored one left by pad.r; a centred title ignores both.
		updates[:title_pad_l] = _text_number(align === :left ? dx : 0.0)
		updates[:title_pad_r] = _text_number(align === :right ? -dx : 0.0)
		fontsize > 0 && (updates[:title_font_size] = _text_number(fontsize))
	end
	relayout!(fig; updates...)
	# A legend already drawn above the axes stays clear of the new title, and
	# a figure legend there is re-stacked for the new title band.
	_legend_stack!(_cmn_plot(fig))
	return nothing
end

# PlotlyBase `subplot_titles` / `column_titles` annotation of a cell: unnamed,
# paper-referenced, centred on the cell top. A `title!` panel title replaces it.
function _text_is_centred_cell_title(item, xdom, ydom)
	_cmn_mapping_get(item, :name) === nothing || return false
	_cmn_mapping_get(item, :xref) == "paper" || return false
	_cmn_mapping_get(item, :yref) == "paper" || return false
	_cmn_mapping_get(item, :xanchor) == "center" || return false
	_cmn_mapping_get(item, :yanchor) == "bottom" || return false
	x = _cmn_mapping_get(item, :x)
	y = _cmn_mapping_get(item, :y)
	(x isa Real && y isa Real) || return false
	return isapprox(x, (xdom[1] + xdom[2]) / 2; atol = 1e-9) &&
		isapprox(y, ydom[2]; atol = 1e-9)
end

function _text_drop_centred_cell_title!(fig, xdom, ydom)
	existing = get(_cmn_layout(fig).fields, :annotations, nothing)
	existing isa AbstractVector || return nothing
	kept = Any[item for item in existing if !_text_is_centred_cell_title(item, xdom, ydom)]
	length(kept) == length(existing) && return nothing
	relayout!(_cmn_relayout_target(fig); annotations = kept)
	return nothing
end

function _text_panel_title!(fig, target, text, align::Symbol, fontsize::Float64, bold::Bool, offset)
	dx, dy = offset
	name = "plotlysupply:title:$(target.row):$(target.col)"
	if isempty(text)
		_upsert_named!(fig, :annotations, name, Any[]; who = "title!")
		_text_refit_panel_label!(fig, target)
		return nothing
	end
	xdom = target.xdomain
	ydom = target.ydomain
	x = align === :left ? xdom[1] : align === :right ? xdom[2] : (xdom[1] + xdom[2]) / 2
	annotation = Dict{Symbol, Any}(
		:name => name,
		:text => _text_label(text, align, bold, "title!"),
		:xref => "paper",
		:yref => "paper",
		:x => x,
		:y => ydom[2],
		:xanchor => String(align),
		:yanchor => "bottom",
		:align => String(align),
		:xshift => _text_number(dx),
		:yshift => _text_number(_TEXT_PANEL_GAP + dy),
		:showarrow => false,
	)
	fontsize > 0 && (annotation[:font] = attr(size = _text_number(fontsize)))
	_text_drop_centred_cell_title!(fig, xdom, ydom)
	_upsert_named!(fig, :annotations, name, [attr(annotation)]; who = "title!")
	_text_refit_panel_label!(fig, target)
	# D12: the room providers (room_providers.jl) stack it above a top axis
	# and a cell legend above the axes, and a figure legend above it, when
	# `_finalize_figure!` runs after this mutation.
	return nothing
end

# A panel title aligned to a corner and an outside panel label at that corner
# would print on top of each other: both sit `_TEXT_PANEL_GAP` px above it.
# The label then moves beside the corner, outside the axes (left of a top-left
# corner, right of a top-right one) on the title's line, where it reads
# "(a) Title"; the title keeps its place. `_text_panel_title_side` is the
# alignment of the panel title of cell (row, col) (`nothing` without one).
function _text_panel_title_side(fig, row::Integer, col::Integer)
	items = get(_cmn_layout(fig).fields, :annotations, nothing)
	items isa AbstractVector || return nothing
	name = "plotlysupply:title:$(row):$(col)"
	for item in items
		_cmn_item_name(item) == name || continue
		anchor = _cmn_mapping_get(item, :xanchor)
		anchor == "left" && return :left
		anchor == "right" && return :right
		return :center
	end
	return nothing
end

# `xanchor` and `xshift` of an outside top panel label at the left (`left`)
# or right corner, given the side of the cell's panel title.
function _text_panel_label_xplacement(left::Bool, title_side)
	title_side === (left ? :left : :right) ||
		return (left ? "left" : "right", 0)
	return (left ? "right" : "left", left ? -_TEXT_PANEL_GAP : _TEXT_PANEL_GAP)
end

# Re-place the outside top panel label of `target` after its panel title
# changed (see `_text_panel_title_side`). Other labels are left alone.
function _text_refit_panel_label!(fig, target)
	name = "plotlysupply:panel_label:$(target.row):$(target.col)"
	items = get(_cmn_layout(fig).fields, :annotations, nothing)
	items isa AbstractVector || return nothing
	index = findfirst(item -> _cmn_item_name(item) == name, items)
	index === nothing && return nothing
	label = items[index]
	_cmn_mapping_get(label, :yanchor) == "bottom" || return nothing
	x = _cmn_mapping_get(label, :x)
	y = _cmn_mapping_get(label, :y)
	(x isa Real && y isa Real) || return nothing
	isapprox(y, target.ydomain[2]; atol = 1e-9) || return nothing
	left = isapprox(x, target.xdomain[1]; atol = 1e-9)
	(left || isapprox(x, target.xdomain[2]; atol = 1e-9)) || return nothing
	xanchor, xshift = _text_panel_label_xplacement(
		left,
		_text_panel_title_side(fig, target.row, target.col),
	)
	entry = _symbol_dict(label)
	old_shift = get(entry, :xshift, 0)
	(get(entry, :xanchor, nothing) == xanchor && old_shift == xshift) && return nothing
	entry[:xanchor] = xanchor
	xshift == 0 ? delete!(entry, :xshift) : (entry[:xshift] = xshift)
	_upsert_named!(fig, :annotations, name, [attr(entry)]; who = "title!")
	return nothing
end

# ── Stacking above the axes (D12, G38, G60) ──────────────────────────────────
#
# Above a cell's axes sit, bottom to top: a top x axis (tick labels and title,
# own or `secondary_xaxis!`), a legend placed above the axes, then the panel
# title with the outside top panel label on its line. Above the top row come
# the figure legends and, at the top of the figure, the figure title. The room
# providers of src/sci/room_providers.jl (`_room_requests!` /
# `_room_place!(plan, ::Val{:legend_titles})`) enforce that order and give
# every one of them its own room; `_finalize_figure!` runs them after every
# mutation and on the `savefig` export copy at the export size.

# plotly.js annotation box around the text: borderpad 1 + borderwidth 1 on
# each side (attribute defaults).
const _TEXT_ANNOTATION_FRAME = 4.0

# Estimated height (px) of legend box `legend_id` as plotly.js 2.35.2 lays it
# out (legend/draw.js computeLegendDimensions): entry rows of max(text height,
# 16) + 3 px - one per entry for a vertical legend, the longest column for a
# column legend, rows of the plot-area width for a plain horizontal legend -,
# a title on top, and the frame + itemGap padding. 0 when it lists nothing.
function _legend_box_height(
	p::Plot,
	legend_id::AbstractString,
	indices::Vector{Int} = _legend_entry_indices(p, legend_id),
)
	box = _symbol_dict(get(p.layout.fields, Symbol(legend_id), nothing))
	get(box, :visible, true) === false && return 0.0
	isempty(indices) && return 0.0
	fontsize = _legend_entry_font_size(p, box)
	heights = map(indices) do index
		name = get(p.data[index].fields, :name, "")
		max(_text_extent(name isa AbstractString ? name : string(name), fontsize)[2], 16.0) + 3
	end
	orientation = get(box, :orientation, "v")
	order = get(box, :traceorder, "")
	body = if orientation != "h"
		sum(heights)
	elseif order isa AbstractString && occursin("grouped", order)
		columns = Dict{Any, Float64}()
		for (j, index) in enumerate(indices)
			group = get(p.data[index].fields, :legendgroup, "")
			key = (group isa AbstractString && !isempty(group)) ? group : index
			columns[key] = get(columns, key, 0.0) + heights[j]
		end
		maximum(values(columns))
	else
		widths = _legend_entry_widths(p, box, indices)
		rows = ceil(Int, (sum(widths) + _LEGEND_ITEM_GAP * length(widths)) / _legend_plot_area_width(p))
		max(rows, 1) * maximum(heights)
	end
	frame = something(_legend_real(get(box, :borderwidth, nothing)), 0.0)
	title = _symbol_dict(get(box, :title, nothing))
	title_text = get(title, :text, "")
	if title_text isa AbstractString && !isempty(strip(title_text))
		side = string(get(title, :side, orientation == "h" ? "left" : "top"))
		title_size = something(_legend_real(get(_symbol_dict(get(title, :font, nothing)), :size, nothing)), fontsize)
		h = _text_extent(title_text, title_size)[2]
		body = occursin("top", side) ? body + h : max(body, h)
	end
	return body + 2 * (frame + _LEGEND_ITEM_GAP)
end

# The figure title of `p` as a Dict when it has text, else `nothing`.
function _text_title_dict(p::Plot)
	title = get(p.layout.fields, :title, nothing)
	d = title isa AbstractString ? Dict{Symbol, Any}(:text => String(title)) : _symbol_dict(title)
	text = get(d, :text, "")
	(text isa AbstractString && !isempty(strip(text))) || return nothing
	return d
end

# Band (px) a container-referenced figure title takes at the top of the
# figure: `pad.t` + its text + `_TEXT_PANEL_GAP`; 0 without one.
function _text_title_band(p::Plot)
	d = _text_title_dict(p)
	d === nothing && return 0.0
	get(d, :yref, "container") == "container" || return 0.0
	pad = _symbol_dict(get(d, :pad, nothing))
	return something(_legend_real(get(pad, :t, nothing)), 0.0) +
		_text_extent(d[:text], _legend_title_font_size(p, d))[2] + _TEXT_PANEL_GAP
end

"""
	_text_restack!(fig; clearance = false) -> Bool

The layout pass every legend placement runs (`_legend_stack!`) on a `Plot`,
`SyncPlot`'s plot, staged figure or `SubplotFigure`. The stacking above the
axes (panel titles and labels above cell legends and top x axes, figure
legends above the top row, the figure title on top, the room and margins they
need) is done by the D12 room providers when `_finalize_figure!` runs after
the mutation; with `clearance = true` this pass keeps the figure title clear
of a legend above the plot area that those providers do not place (one the
user put there, `_legend_title_clearance!`). Returns whether anything changed.
"""
function _text_restack!(fig; clearance::Bool = false)
	clearance || return false
	p = _cmn_plot(fig)
	before = get(p.layout.fields, :title, nothing)
	_legend_title_clearance!(p)
	return get(p.layout.fields, :title, nothing) !== before
end


function _text_title_args(align, fontsize, offset)
	return (
		_text_align(align, "title!"),
		_text_real(fontsize, "title!", "fontsize"),
		_text_pair(offset, "title!", "offset"),
	)
end

"""
	title!(fig, text::AbstractString; row=nothing, col=nothing, align=:center, fontsize=0, bold=false, offset=(0, 0))

Set the figure title (suptitle) of a `Plot`, [`SyncPlot`](@ref) or
[`SubplotFigure`](@ref), or — with `row`/`col` on a `SubplotFigure` — the
title of one panel.

- Figure title: `layout.title` gets `text`, `x`/`xanchor` from `align`
  (`:left` → aligned with the left edge of the plot area, like matplotlib
  `loc="left"`; `:right` → right edge), `xref="paper"`, and is pinned
  `_TEXT_TITLE_TOP_PAD` (10) px below the top of the figure with
  `automargin=true`, so the plot area moves down instead of overlapping it.
  Panel titles, panel labels and legends placed above the top row stay
  below it: the top margin grows to hold them. A legend above the plot area
  that is not placed by the package (`relayout!`) gets a `title.pad.b`
  instead, so it is laid out below the title (see [`set_legend!`](@ref)).
  Existing title styling (font family/colour) is kept.
- Panel title: an annotation named `"plotlysupply:title:<row>:<col>"` placed
  just above the cell's axes (`x` = left edge / centre / right edge of the cell
  per `align`, `yanchor="bottom"`, 4 px gap). Calling it again replaces it; it
  also replaces a centred `subplot_titles`/`column_titles` annotation of that
  cell. [`set_fonts!`](@ref) styles it as a title. A left/right-aligned panel
  title moves an outside [`panel_labels!`](@ref) label at the same top corner
  beside the corner (outside the axes), so they do not overlap.
  The title sits above everything placed above the axes (a top x axis, also
  from [`secondary_xaxis!`](@ref), and a legend placed above the axes), and
  follows the axes whenever the layout changes (the fitted plot area of an
  equal-aspect cell). A title below the first row clears the x tick labels
  and x title of the cell above: the two cells give up height for it (each
  at most two thirds of its height; a figure too small for that still
  overlaps, so make it taller or widen `vertical_spacing`). The top margin grows for titles of
  the first row. `offset` moves it farther out and its room grows with it.

`text` goes through mathtext (`"(a) Mesh study, \$\\lambda=10^8\$"` keeps its
text); `""` removes the title.

# Keywords
- `row`, `col` (`Integer`, both or neither): the panel (SubplotFigure only).
- `align::Symbol = :center`: `:left`, `:center` or `:right`.
- `fontsize::Real = 0`: font size in px (0 = unchanged / Plotly default).
- `bold::Bool = false`: plain text is wrapped in `<b>…</b>`; for labels with
  math, the text runs become `\\textbf{…}` (HTML tags cannot wrap math) and the
  math itself is unchanged.
- `offset::Tuple{Real,Real} = (0, 0)` (or a 2-vector): `(dx, dy)` shift in
  px, right and up. A centred figure title cannot be shifted horizontally
  (Plotly ignores the padding of centred titles): use `align=:left`/`:right`
  for a `dx`. A figure title can move up by at most 10 px (`dy <= 10`), to
  the top edge of the figure.

Returns `nothing` for a `Plot`/`SyncPlot`, the `SubplotFigure` otherwise.
Invalid keywords throw an `ArgumentError` before anything changes; `show` is
not accepted (this modifies an existing figure).

# Example
```julia
sf = subplots(1, 2; sync = false)
plot_scatter!(sf, 1:3, [1, 4, 9]; row = 1, col = 1)
plot_scatter!(sf, 1:3, [9, 4, 1]; row = 1, col = 2)
title!(sf, "Convergence study"; align = :left, bold = true)
title!(sf, "(a) Mesh, \$h = 0.1\$"; row = 1, col = 1, align = :left)
title!(sf, "(b) Error"; row = 1, col = 2, align = :left)
```
"""
function title!(
	fig,
	text::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	align::Union{Symbol, AbstractString} = :center,
	fontsize::Real = 0,
	bold::Bool = false,
	offset::Union{Tuple, AbstractVector} = (0, 0),
	show = nothing,
)
	_text_reject_show(show, "title!")
	a, fs, off = _text_title_args(align, fontsize, offset)
	(row === nothing && col === nothing) || _cell_target(fig; row = row, col = col, who = "title!")
	_text_check_figure_offset(text, a, off)
	_text_figure_title!(fig, text, a, fs, bold, off)
	_refresh!(fig)
	return nothing
end

function _text_title_sf_impl!(
	sf::SubplotFigure,
	text::AbstractString;
	row,
	col,
	align,
	fontsize,
	bold,
	offset,
)
	if row === nothing && col === nothing
		a, fs, off = _text_title_args(align, fontsize, offset)
		_text_check_figure_offset(text, a, off)
		_text_figure_title!(_cmn_relayout_target(sf), text, a, fs, bold, off)
	else
		(row === nothing) == (col === nothing) || throw(ArgumentError(
			"title!: `row` and `col` must be given together.",
		))
		a, fs, off = _text_title_args(align, fontsize, offset)
		target = _cell_target(sf; row = row, col = col, who = "title!")
		_text_panel_title!(sf, target, text, a, fs, bold, off)
	end
	_refresh!(getfield(sf, :fig))
	return sf
end

function title!(
	sf::SubplotFigure,
	text::AbstractString;
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	align::Union{Symbol, AbstractString} = :center,
	fontsize::Real = 0,
	bold::Bool = false,
	offset::Union{Tuple, AbstractVector} = (0, 0),
	show = nothing,
)
	_text_reject_show(show, "title!")
	# Validate before the transaction so a bad keyword never stages anything.
	_text_title_args(align, fontsize, offset)
	return _transactional_subplot_mutation!(
		_text_title_sf_impl!,
		sf,
		(),
		text;
		row = row,
		col = col,
		align = align,
		fontsize = fontsize,
		bold = bold,
		offset = offset,
	)
end

# ── panel_labels! ────────────────────────────────────────────────────────────

const _TEXT_LABEL_POSITIONS = (:topleft, :topright, :bottomleft, :bottomright)
# Roman numerals are defined up to 3999 (no symbol for 5000).
const _TEXT_MAX_ROMAN = 3999

function _text_alpha_label(k::Int)
	chars = Char[]
	while k > 0
		k -= 1
		pushfirst!(chars, Char('a' + k % 26))
		k ÷= 26
	end
	return String(chars)
end

function _text_roman_label(k::Int, who::AbstractString)
	1 <= k <= _TEXT_MAX_ROMAN || throw(ArgumentError(
		"$(who): roman labels exist for 1:$(_TEXT_MAX_ROMAN); got panel $(k).",
	))
	out = IOBuffer()
	for (value, numeral) in (
		(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
		(50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
	)
		while k >= value
			print(out, numeral)
			k -= value
		end
	end
	return String(take!(out))
end

function _text_panel_label_texts(labels, n::Int, who::AbstractString)
	if labels isa Symbol
		labels === :abc && return [_text_alpha_label(k) for k in 1:n]
		labels === :ABC && return [uppercase(_text_alpha_label(k)) for k in 1:n]
		labels === :roman && return [_text_roman_label(k, who) for k in 1:n]
		throw(ArgumentError(
			"$(who): `labels` must be :abc, :ABC, :roman or a vector of strings; got $(repr(labels)).",
		))
	end
	labels isa AbstractVector || throw(ArgumentError(
		"$(who): `labels` must be :abc, :ABC, :roman or a vector of strings; got $(typeof(labels)).",
	))
	all(label -> label isa AbstractString, labels) || throw(ArgumentError(
		"$(who): every entry of `labels` must be a string.",
	))
	length(labels) == n || throw(ArgumentError(
		"$(who): $(length(labels)) label(s) for $(n) panel(s); give one label per panel.",
	))
	return String[String(label) for label in labels]
end

# Occupied cells of a SubplotFigure in row-major order (blank `missing` specs
# and cells covered by a row/column span are skipped).
function _text_occupied_cells(sf::SubplotFigure)
	grid_ref = _cmn_layout(sf).subplots.grid_ref
	cells = Tuple{Int, Int}[]
	for r in 1:getfield(sf, :rows), c in 1:getfield(sf, :cols)
		checkbounds(Bool, grid_ref, r, c) || continue
		isassigned(grid_ref, r, c) || continue
		isempty(grid_ref[r, c]) && continue
		push!(cells, (r, c))
	end
	return cells
end

function _text_panel_cells(sf::SubplotFigure, cells, who::AbstractString)
	cells === :all && return _text_occupied_cells(sf)
	(cells isa AbstractVector && !isempty(cells)) || throw(ArgumentError(
		"$(who): `cells` must be :all or a non-empty vector of (row, col) tuples; got $(repr(cells)).",
	))
	out = Tuple{Int, Int}[]
	for cell in cells
		(cell isa Tuple && length(cell) == 2 &&
			all(v -> v isa Integer && !(v isa Bool), cell)) || throw(ArgumentError(
			"$(who): each entry of `cells` must be a (row, col) tuple of integers; got $(repr(cell)).",
		))
		push!(out, (Int(cell[1]), Int(cell[2])))
	end
	allunique(out) || throw(ArgumentError("$(who): `cells` lists a cell twice."))
	return out
end

function _text_panel_label_annotation(target, text, position::Symbol, outside::Bool, fontsize::Float64, bold::Bool, row::Int, col::Int, title_side = nothing)
	left = position in (:topleft, :bottomleft)
	top = position in (:topleft, :topright)
	xdom = target.xdomain
	ydom = target.ydomain
	annotation = Dict{Symbol, Any}(
		:name => "plotlysupply:panel_label:$(row):$(col)",
		:text => _text_label(text, left ? :left : :right, bold, "panel_labels!"),
		:xref => "paper",
		:yref => "paper",
		:x => left ? xdom[1] : xdom[2],
		:y => top ? ydom[2] : ydom[1],
		:xanchor => left ? "left" : "right",
		:showarrow => false,
	)
	if outside
		annotation[:yanchor] = top ? "bottom" : "top"
		annotation[:yshift] = top ? _TEXT_PANEL_GAP : -_TEXT_PANEL_GAP
		if top
			xanchor, xshift = _text_panel_label_xplacement(left, title_side)
			annotation[:xanchor] = xanchor
			xshift == 0 || (annotation[:xshift] = xshift)
		end
	else
		annotation[:yanchor] = top ? "top" : "bottom"
		annotation[:xshift] = left ? _TEXT_PANEL_GAP : -_TEXT_PANEL_GAP
		annotation[:yshift] = top ? -_TEXT_PANEL_GAP : _TEXT_PANEL_GAP
	end
	fontsize > 0 && (annotation[:font] = attr(size = _text_number(fontsize)))
	return attr(annotation)
end

function _text_panel_label_args(labels, format, position, fontsize, who)
	occursin("{}", format) || throw(ArgumentError(
		"$(who): `format` must contain \"{}\" where the label goes; got $(repr(format)).",
	))
	position isa Symbol && position in _TEXT_LABEL_POSITIONS || throw(ArgumentError(
		"$(who): `position` must be one of $(join(repr.(_TEXT_LABEL_POSITIONS), ", ")); got $(repr(position)).",
	))
	fs = _text_real(fontsize, who, "fontsize")
	(labels isa Symbol || labels isa AbstractVector) || throw(ArgumentError(
		"$(who): `labels` must be :abc, :ABC, :roman or a vector of strings; got $(typeof(labels)).",
	))
	return fs
end

function _text_write_panel_labels!(fig, targets, texts, format, position, outside, fs, bold)
	items = Tuple{String, Any}[]
	for ((row, col, target), label) in zip(targets, texts)
		text = replace(format, "{}" => label)
		push!(items, (
			"plotlysupply:panel_label:$(row):$(col)",
			_text_panel_label_annotation(
				target, text, position, outside, fs, bold, row, col,
				_text_panel_title_side(fig, row, col),
			),
		))
	end
	for (name, annotation) in items
		_upsert_named!(fig, :annotations, name, [annotation]; who = "panel_labels!")
	end
	# D12 stacking and room, as for panel titles (room_providers.jl).
	return nothing
end

"""
	panel_labels!(fig; labels=:abc, format="({})", position=:topleft, outside=true, bold=false, fontsize=0, cells=:all)

Label the panels of a [`SubplotFigure`](@ref) "(a)", "(b)", … (or the single
axes of a `Plot`/[`SyncPlot`](@ref)). Panels are labelled in row-major order,
skipping empty cells (`missing` specs, cells covered by a span). Each label is
an annotation named `"plotlysupply:panel_label:<row>:<col>"`, so calling it
again replaces the labels instead of adding more.

# Keywords
- `labels`: `:abc` (a, b, …, z, aa, …), `:ABC`, `:roman` (i, ii, iii, …) or a
  vector of strings, one per panel.
- `format::AbstractString = "({})"`: `{}` is replaced by the label (`"{})"`
  gives "a)"). The result goes through mathtext.
- `position::Symbol = :topleft`: corner of the axes — `:topleft`, `:topright`,
  `:bottomleft`, `:bottomright`.
- `outside::Bool = true`: `true` puts the label just outside the corner
  (above the axes for top corners, `yanchor="bottom"`); `false` inside it,
  4 px from both edges. An outside top label sits on the line of the cell's
  panel title, above a top x axis and a legend placed above the axes; an
  outside bottom label below the x axis. Rows move apart and the figure
  margins grow so that labels neither overlap anything nor are clipped, and
  every label follows its axes (the fitted plot area of an equal-aspect
  cell) whenever the layout changes. When the cell has a panel title
  ([`title!`](@ref) with `row`/`col`) aligned to the same corner
  (`align = :left` for `:topleft`, `:right` for `:topright`), or a centred
  title too wide to clear the label in a narrow cell, an outside label
  moves beside the corner, outside the axes on the title's line
  ("(a) Title"; past the end of a title wider than the cell), when the
  figure has room there. The line then rises clear of the top y tick label
  under the label.
- `bold::Bool = false`: bold label (`<b>`, or `\\textbf` for math labels).
- `fontsize::Real = 0`: font size in px (0 = Plotly default).
- `cells`: `:all` or a vector of `(row, col)` tuples (SubplotFigure only;
  labels are assigned in the given order).

Returns `nothing` for a `Plot`/`SyncPlot`, the `SubplotFigure` otherwise.
Invalid values throw an `ArgumentError` before anything is changed; `show`
is not accepted, nor are `row`/`col` (select cells with `cells`).

# Example
```julia
sf = subplots(2, 2; sync = false)
for r in 1:2, c in 1:2
	plot_scatter!(sf, 1:3, rand(3); row = r, col = c)
end
panel_labels!(sf; bold = true)                         # (a) (b) (c) (d)
panel_labels!(sf; labels = :roman, outside = false)     # replaces them
```
"""
function panel_labels!(
	fig;
	labels::Union{Symbol, AbstractVector} = :abc,
	format::AbstractString = "({})",
	position::Symbol = :topleft,
	outside::Bool = true,
	bold::Bool = false,
	fontsize::Real = 0,
	cells = :all,
	row = nothing,
	col = nothing,
	show = nothing,
)
	who = "panel_labels!"
	_text_reject_show(show, who)
	_text_reject_panel_cell(row, col)
	fs = _text_panel_label_args(labels, format, position, fontsize, who)
	cells === :all || throw(ArgumentError(
		"$(who): `cells` selects SubplotFigure cells; a single figure has one panel, so omit it.",
	))
	texts = _text_panel_label_texts(labels, 1, who)
	target = _cell_target(fig; who = who)
	_text_write_panel_labels!(fig, [(1, 1, target)], texts, format, position, outside, fs, bold)
	_refresh!(fig)
	return nothing
end

# `panel_labels!` labels a set of cells (`cells`), never one `row`/`col`.
function _text_reject_panel_cell(row, col)
	(row === nothing && col === nothing) && return nothing
	throw(ArgumentError(
		"panel_labels!: `row`/`col` are not supported; choose the labelled cells with " *
		"`cells = [(row, col), …]`.",
	))
end

function _text_panel_labels_sf_impl!(sf::SubplotFigure; labels, format, position, outside, bold, fontsize, cells)
	who = "panel_labels!"
	fs = _text_panel_label_args(labels, format, position, fontsize, who)
	chosen = _text_panel_cells(sf, cells, who)
	isempty(chosen) && throw(ArgumentError("$(who): the figure has no occupied cells."))
	texts = _text_panel_label_texts(labels, length(chosen), who)
	targets = [(r, c, _cell_target(sf; row = r, col = c, who = who)) for (r, c) in chosen]
	_text_write_panel_labels!(sf, targets, texts, format, position, outside, fs, bold)
	_refresh!(getfield(sf, :fig))
	return sf
end

function panel_labels!(
	sf::SubplotFigure;
	labels::Union{Symbol, AbstractVector} = :abc,
	format::AbstractString = "({})",
	position::Symbol = :topleft,
	outside::Bool = true,
	bold::Bool = false,
	fontsize::Real = 0,
	cells = :all,
	row = nothing,
	col = nothing,
	show = nothing,
)
	_text_reject_show(show, "panel_labels!")
	_text_reject_panel_cell(row, col)
	_text_panel_label_args(labels, format, position, fontsize, "panel_labels!")
	return _transactional_subplot_mutation!(
		_text_panel_labels_sf_impl!,
		sf,
		();
		labels = labels,
		format = format,
		position = position,
		outside = outside,
		bold = bold,
		fontsize = fontsize,
		cells = cells,
	)
end

# ─────────────────────────────────────────────────────────────────────────────
# F15: legend proxies
# ─────────────────────────────────────────────────────────────────────────────

# Legend-only trace for a cell of `kind`: `_proxy_trace` builds a Cartesian
# scatter; other subplot kinds need the matching scatter type with null
# coordinates (a scatter on a 3-D/polar/map cell would conjure x/y axes).
function _text_proxy_for_kind(proxy::GenericTrace, kind::Symbol, who::AbstractString)
	kind === :xy && return proxy
	fields = copy(proxy.fields)
	delete!(fields, :x)
	delete!(fields, :y)
	delete!(fields, :type)
	gap() = Any[_GAP]
	type = if kind === :scene
		fields[:x] = gap(); fields[:y] = gap(); fields[:z] = gap()
		"scatter3d"
	elseif kind === :polar
		fields[:r] = gap(); fields[:theta] = gap()
		"scatterpolar"
	elseif kind === :ternary
		fields[:a] = gap(); fields[:b] = gap(); fields[:c] = gap()
		"scatterternary"
	elseif kind in (:geo, :map, :mapbox)
		fields[:lat] = gap(); fields[:lon] = gap()
		kind === :geo ? "scattergeo" : kind === :map ? "scattermap" : "scattermapbox"
	else
		throw(ArgumentError(
			"$(who): a $(kind) cell (pie, sunburst, …) has no axes to hold a " *
			"legend entry; choose a cell with axes (`row`/`col`).",
		))
	end
	return GenericTrace(type, fields)
end

function _text_legend_target(legend_target, who::AbstractString)
	legend_target in (:cell, :figure) || throw(ArgumentError(
		"$(who): `legend_target` must be :cell or :figure; got $(repr(legend_target)).",
	))
	return legend_target
end

# plotly.js line dash values: the named styles, or a dash-length list such as
# "5px,10px,2px,2px" (px or % lengths).
const _TEXT_DASH_NAMES = ("solid", "dot", "dash", "longdash", "dashdot", "longdashdot")
const _TEXT_DASH_LIST = r"^\s*\d+(\.\d+)?(px|%)?(\s*,\s*\d+(\.\d+)?(px|%)?)*\s*$"

# One proxy colour keyword, validated and written as canonical CSS
# ("#RRGGBB" or "rgba(r,g,b,a)") so plotly.js draws what the user named:
# matplotlib grey levels ("0.35") and Colors.jl names are converted, anything
# unparseable is an ArgumentError (plotly.js would silently draw its default
# colour). "" stays "" (unset). "none" keeps its hollow-marker meaning for
# `marker_color` and is fully transparent for the other keywords.
function _text_proxy_color(value, name::AbstractString, who::AbstractString)
	s = strip(String(value))
	isempty(s) && return ""
	if lowercase(s) == "none"
		return name == "marker_color" ? "none" : "rgba(0,0,0,0)"
	end
	try
		return _color_hex(s; who = who)
	catch err
		err isa ArgumentError || rethrow()
		throw(ArgumentError(replace(err.msg, "$(who): " => "$(who): `$(name)`: "; count = 1)))
	end
end

function _text_proxy(label, who; mode, color, dash, linewidth, marker_symbol, marker_size, marker_color, marker_line_color, marker_line_width, patch, legendgroup, opacity)
	isempty(label) && throw(ArgumentError(
		"$(who): `label` is empty, which would be an entry without text; use " *
		"\" \" for a blank spacer entry.",
	))
	color = _text_proxy_color(color, "color", who)
	marker_color = _text_proxy_color(marker_color, "marker_color", who)
	marker_line_color = _text_proxy_color(marker_line_color, "marker_line_color", who)
	# A patch has no open-symbol variant: "none" is an unfilled square.
	patch === true && marker_color == "none" && (marker_color = "rgba(0,0,0,0)")
	dash_s = String(dash)
	(isempty(dash_s) || dash_s in _TEXT_DASH_NAMES || occursin(_TEXT_DASH_LIST, dash_s)) ||
		throw(ArgumentError(
			"$(who): `dash` must be one of $(join(repr.(_TEXT_DASH_NAMES), ", ")) or a " *
			"dash-length list such as \"5px,10px\"; got $(repr(dash_s)).",
		))
	# Report mathtext errors under this function's name (`_proxy_trace` labels
	# the name again; `_label` is idempotent).
	_text_checked_label(label, who)
	# A blank spacer entry without colours draws no symbol (Plotly would give it
	# the next colorway colour).
	spacer = isempty(strip(label)) && isempty(String(color)) &&
		isempty(String(marker_color)) && isempty(String(marker_line_color))
	return _proxy_trace(
		label;
		mode = String(mode),
		color = spacer ? "rgba(0,0,0,0)" : color,
		dash = String(dash),
		linewidth = linewidth,
		marker_symbol = marker_symbol,
		marker_size = marker_size,
		marker_color = marker_color,
		marker_line_color = marker_line_color,
		marker_line_width = marker_line_width,
		patch = patch,
		legendgroup = legendgroup,
		opacity = opacity,
		who = who,
	)
end

"""
	legend_entry!(fig, label::AbstractString; mode="lines", color="", dash="", linewidth=0, marker_symbol="", marker_size=0, marker_color="", marker_line_color="", marker_line_width=0, patch=false, legendgroup="", opacity=1, row=nothing, col=nothing, legend_target=:cell)

Add a legend-only entry (a proxy, like a matplotlib `Line2D`/`Patch` handle)
to a `Plot`, [`SyncPlot`](@ref) or [`SubplotFigure`](@ref) cell. The entry is
a trace with null coordinates (`x = y = [null]`, `hoverinfo="skip"`,
`showlegend=true`), so it draws nothing in the plot area.

# Keywords
- `mode = "lines"` (string or Symbol): `"lines"`, `"markers"` or `"lines+markers"`.
- `color` (string or Symbol): line colour; also the marker colour when
  `marker_color` is not given. Every colour keyword takes a CSS colour
  (`"red"`, `"#1f77b4"`, `"rgba(0,0,255,0.3)"`, `"hsl(…)"`), a matplotlib
  grey level (`"0.35"`) or a Colors.jl colour name, and is written as
  `"#RRGGBB"`/`"rgba(…)"`; anything else is an `ArgumentError`. `"none"` is
  transparent (for `marker_color`: a hollow marker, or an unfilled patch).
- `dash` (string or Symbol, `""` = solid) and `linewidth::Real` (0 = Plotly
  default): line style; `dash` is a Plotly dash name (`"dash"`, `"dot"`,
  `"dashdot"`, …).
- `marker_symbol`: Plotly name or matplotlib code (`"o"`, `"s"`, `"^"`, `"x"`, …).
- `marker_size::Real`, `marker_line_width::Real`: px (0 = default).
- `marker_color`: face colour; `"none"` draws a hollow marker (an unfilled
  square with `patch=true`; give it `marker_line_width > 0`).
- `marker_line_color`: marker edge colour.
- `patch::Bool = false`: a filled square (a matplotlib Rectangle handle) in
  `color`/`marker_color`; edge only when `marker_line_width > 0`.
- `legendgroup::AbstractString`: join an existing legend group (clicking the
  entry then toggles the group's traces).
- `opacity::Real = 1`: entry opacity in [0, 1].
- `row`, `col`: the SubplotFigure cell (default: the active cell); the
  entry lands in that cell's legend.
- `legend_target::Symbol = :cell`: `:figure` puts the entry in the
  figure-level legend instead (on a SubplotFigure with per-subplot legends a
  separate figure legend, placed below the plot area until
  `set_legend!(sf; legend_target=:figure, ...)` moves it). On a `Plot`/`SyncPlot`
  both targets mean its one legend.

`label` goes through mathtext and must not be empty; `" "` gives a blank
spacer entry (it draws no symbol unless a colour is given).

Returns `nothing` for a `Plot`/`SyncPlot`, the `SubplotFigure` otherwise.

# Example
```julia
fig = plot_scatter(1:10, rand(10); color = "black", mode = "markers")
legend_entry!(fig, "experiment"; mode = "markers", marker_symbol = "o", marker_color = "none", color = "black")
legend_entry!(fig, "theory"; color = "red", dash = "dash")
legend_entry!(fig, "tolerance band"; patch = true, color = "rgba(0,0,255,0.3)")
```
"""
function legend_entry!(
	fig,
	label::AbstractString;
	mode::Union{AbstractString, Symbol} = "lines",
	color::Union{AbstractString, Symbol} = "",
	dash::Union{AbstractString, Symbol} = "",
	linewidth::Real = 0,
	marker_symbol::Union{AbstractString, Symbol} = "",
	marker_size::Real = 0,
	marker_color::Union{AbstractString, Symbol} = "",
	marker_line_color::Union{AbstractString, Symbol} = "",
	marker_line_width::Real = 0,
	patch::Bool = false,
	legendgroup::AbstractString = "",
	opacity::Real = 1,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	legend_target::Symbol = :cell,
	show = nothing,
)
	who = "legend_entry!"
	_text_reject_show(show, who)
	_text_legend_target(legend_target, who)
	_cell_target(fig; row = row, col = col, who = who)
	proxy = _text_proxy(
		label,
		who;
		mode, color, dash, linewidth, marker_symbol, marker_size, marker_color,
		marker_line_color, marker_line_width, patch, legendgroup, opacity,
	)
	p = _plot_obj(fig)
	kind, key = _cmn_plot_kind(p)
	proxy = _text_proxy_for_kind(proxy, kind, who)
	if kind === :scene && key !== :scene
		proxy.fields[:scene] = String(key)
	elseif kind === :geo && key !== :geo
		proxy.fields[:geo] = String(key)
	elseif kind in (:polar, :ternary, :map, :mapbox) && key !== kind
		proxy.fields[:subplot] = String(key)
	end
	push!(_plot_data(fig), proxy)
	_apply_default_legend!(fig)
	_refresh!(fig)
	return nothing
end

function _text_legend_entry_sf_impl!(sf::SubplotFigure, label::AbstractString; row, col, legend_target, proxy_kwargs...)
	who = "legend_entry!"
	target = _cell_target(sf; row = row, col = col, who = who)
	proxy = _text_proxy(label, who; proxy_kwargs...)
	proxy = _text_proxy_for_kind(proxy, target.kind, who)
	legend_target === :figure && (proxy.fields[:meta] = _FIGURE_LEGEND_META)
	p = _cmn_plot(sf)
	_validate_subplot_traces!(p, (proxy,), target.row, target.col)
	PlotlyBase.add_trace!(p, proxy; row = target.row, col = target.col)
	_refresh_subplot_legends!(sf, p; first_new = length(p.data))
	_refresh!(getfield(sf, :fig))
	return sf
end

function legend_entry!(
	sf::SubplotFigure,
	label::AbstractString;
	mode::Union{AbstractString, Symbol} = "lines",
	color::Union{AbstractString, Symbol} = "",
	dash::Union{AbstractString, Symbol} = "",
	linewidth::Real = 0,
	marker_symbol::Union{AbstractString, Symbol} = "",
	marker_size::Real = 0,
	marker_color::Union{AbstractString, Symbol} = "",
	marker_line_color::Union{AbstractString, Symbol} = "",
	marker_line_width::Real = 0,
	patch::Bool = false,
	legendgroup::AbstractString = "",
	opacity::Real = 1,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
	legend_target::Symbol = :cell,
	show = nothing,
)
	who = "legend_entry!"
	_text_reject_show(show, who)
	_text_legend_target(legend_target, who)
	# Build once outside the transaction so invalid styling throws before
	# anything is staged.
	_text_proxy(
		label,
		who;
		mode, color, dash, linewidth, marker_symbol, marker_size, marker_color,
		marker_line_color, marker_line_width, patch, legendgroup, opacity,
	)
	return _transactional_subplot_mutation!(
		_text_legend_entry_sf_impl!,
		sf,
		(),
		label;
		row, col, legend_target,
		mode, color, dash, linewidth, marker_symbol, marker_size, marker_color,
		marker_line_color, marker_line_width, patch, legendgroup, opacity,
	)
end
