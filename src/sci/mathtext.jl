# PlotlySupply 2.0 scientific-plotting extensions: mixed text + LaTeX label pipeline (`mathtext`, `_label`).
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_MATHTEXT_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# How plotly.js 2.35.2 typesets text (svg_text_utils.js, read from the bundled
# plotly.min.js) and why this file exists:
# - A label is sent to MathJax when it matches /([^$]*)([$]+[^$]*[$]+)([^$]*)/.
#   Only the first `$…$` group is typeset; the text before and after it is
#   dropped. Mixed "text $math$ text" labels therefore lose their text, and any
#   label with two literal `$` characters is mistaken for math.
# - Before typesetting, `<`, `&lt;`, `&#60;` become `\lt ` and `>`, `&gt;`,
#   `&#62;` become `\gt ` (inside `\text{}` these print as "\lt"/"\gt").
# - Plain (non-math) labels: newlines are replaced by spaces, a small set of
#   HTML tags is interpreted and entities are decoded.
# `mathtext` turns a matplotlib-style label into one MathJax expression
# (`\text{…}` for the text parts) so nothing is dropped. Every rule below was
# checked by exporting figures through the MathJax 2.7.9 export window.

export mathtext, set_default_mathtext!, get_default_mathtext

const _SCI_MATHTEXT_MUTATORS = ()

struct _MathtextSettings
	enabled::Bool
	# MathJax size switch ("" defers to the active PlotStyle's `mathsize`).
	size::String
	# MathJax SVG font ("" defers to PLOTLYSUPPLY_MATHJAX_SVG_FONT, then
	# "Latin-Modern"); read by the export window and live SyncPlot pages.
	font::String
	# Typeset `\text{…}` in the label's own font instead of the MathJax font.
	inherit_text_font::Bool
end

const _MATHTEXT_SETTINGS = Ref(_MathtextSettings(true, "", "", false))

# The fonts of MathJax 2.7's SVG output (jax/output/SVG/fonts/<name>). Each was
# verified to load from the pinned MathJax 2.7.9 CDN by exporting a math label
# and checking the glyph ids of the SVG (e.g. GYRETERMESMAIN-…). MathJax
# silently typesets any other name in its TeX font (verified with "bogus":
# MJMAIN-/MJMATHI- glyphs), so other names are rejected instead of ignored.
const _MATHJAX_SVG_FONTS = (
	"TeX", "STIX-Web", "Asana-Math", "Neo-Euler",
	"Gyre-Pagella", "Gyre-Termes", "Latin-Modern",
)

# The canonical spelling of a MathJax SVG font name (case-insensitive match),
# or `nothing` when the name is not one of `_MATHJAX_SVG_FONTS`.
function _mathjax_font_name(name::AbstractString)
	wanted = lowercase(strip(String(name)))
	for font in _MATHJAX_SVG_FONTS
		lowercase(font) == wanted && return font
	end
	return nothing
end

# MathJax 2.7 size switches. `\footnotesize` is NOT defined in MathJax 2 (it
# renders as a red undefined macro), so it is not accepted.
const _MATHTEXT_SIZES = (
	"tiny", "Tiny", "scriptsize", "small", "normalsize",
	"large", "Large", "LARGE", "huge", "Huge",
)

# Plotly's HTML tags (svg_text_utils.js TAG_STYLES plus `br`).
const _MATHTEXT_HTML_TAGS = ("br", "sup", "sub", "s", "u", "b", "i", "a", "span", "em")

# Named entities that plotly decodes in plain labels (svg_text_utils.js).
const _MATHTEXT_ENTITIES = Dict(
	"mu" => 'μ', "amp" => '&', "lt" => '<', "gt" => '>', "nbsp" => '\u00a0',
	"times" => '×', "plusmn" => '±', "deg" => '°',
)

# matplotlib-only macros and their MathJax 2 equivalents. `\mathdefault{x}` is
# an identity wrapper (deleting the name leaves the `{x}` group);
# `\degree` and `\AA` are undefined in MathJax 2 (red in the render).
const _MATHTEXT_MACRO_REWRITES = Dict(
	"mathdefault" => "",
	"mathregular" => "\\mathrm",
	"degree" => "{^\\circ}",
	"AA" => "\\mathring{\\mathrm{A}}",
)

# Macros whose first braced argument is not math (text, URLs, CSS, colours):
# `%`/`#` there are literal and must not be escaped, and no macro inside it is
# rewritten.
const _MATHTEXT_RAW_ARG_MACROS = Set([
	"text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal",
	"textup", "textmd", "textsl", "mbox", "hbox", "fbox", "tag",
	"href", "url", "class", "cssId", "style",
	"color", "textcolor", "colorbox", "fcolorbox", "definecolor",
])

# Declarations that act on the rest of the current group (font, style and size
# switches, and the infix fraction commands). A math segment containing one at
# its top level is wrapped in braces before text follows it, otherwise the
# switch would also restyle the following `\text{…}` (verified: `\bf X\text{a}`
# renders "a" bold, `\large x\text{a}` renders "a" large).
const _MATHTEXT_SWITCH_MACROS = Set([
	"rm", "it", "bf", "sf", "tt", "cal", "mit", "oldstyle", "scr", "frak",
	"bbFont", "bold",
	"displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle",
	_MATHTEXT_SIZES...,
	"color",
	"over", "atop", "above", "choose", "brace", "brack",
	"overwithdelims", "atopwithdelims", "abovewithdelims",
])

# Macro definitions use `#1`, `#2`, … parameters; `#` is left alone after one.
const _MATHTEXT_DEFINITION_MACROS = Set([
	"def", "gdef", "edef", "xdef", "let",
	"newcommand", "renewcommand", "newenvironment", "renewenvironment",
])

_mathtext_isletter(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z')

function _mathtext_snippet(s::AbstractString)
	return length(s) <= 80 ? repr(s) : repr(first(s, 77) * "...")
end

function _mathtext_error(message::AbstractString, label::AbstractString)
	throw(ArgumentError("mathtext: $(message) in label $(_mathtext_snippet(label))."))
end

function _normalize_mathtext_size(size::AbstractString, who::AbstractString)
	name = strip(String(size))
	isempty(name) && return ""
	startswith(name, '\\') && (name = name[2:end])
	name in _MATHTEXT_SIZES && return "\\" * name
	valid = join(("\\" * s for s in _MATHTEXT_SIZES), ", ")
	throw(ArgumentError(
		"$(who): `size` must be \"\" or one of the MathJax size switches $(valid); got $(repr(size)).",
	))
end

# The size switch applied when a label writer or `mathtext` is not given one:
# the `set_default_mathtext!` size, or else the active PlotStyle's `mathsize`
# (`_style_mathsize`, src/sci/style.jl; `\large` under `:publication`).
function _mathtext_default_size()
	size = _MATHTEXT_SETTINGS[].size
	isempty(size) || return size
	style_size = _style_mathsize()
	isempty(style_size) && return ""
	name = startswith(style_size, '\\') ? style_size[2:end] : style_size
	name in _MATHTEXT_SIZES && return "\\" * name
	throw(ArgumentError(
		"mathtext: the active PlotStyle's mathsize $(repr(style_size)) is not a " *
		"MathJax 2 size switch (MathJax 2 has no \\footnotesize); set the style's " *
		"mathsize to one of $(join(("\\" * s for s in _MATHTEXT_SIZES), ", ")), " *
		"or override it with set_default_mathtext!(; size = ...).",
	))
end

function _mathtext_align_column(align::Symbol, who::AbstractString)
	align in (:c, :center) && return 'c'
	align in (:l, :left) && return 'l'
	align in (:r, :right) && return 'r'
	throw(ArgumentError(
		"$(who): `align` must be :c, :l or :r (or :center, :left, :right); got $(repr(align)).",
	))
end

"""
	get_default_mathtext()

Return the package-wide label settings as a `NamedTuple`
`(enabled, size, font, inherit_text_font)`, as set by
[`set_default_mathtext!`](@ref):

- `enabled::Bool`: every PlotlySupply label writer converts mixed text +
  `\$…\$` labels with [`mathtext`](@ref).
- `size::String`: the MathJax size switch (e.g. `"\\\\large"`) prefixed to math
  labels, or `""`, which defers to the active [`PlotStyle`](@ref)'s `mathsize`.
- `font::String`: the MathJax SVG font, or `""`, which defers to the
  `PLOTLYSUPPLY_MATHJAX_SVG_FONT` environment variable and then to
  `"Latin-Modern"`.
- `inherit_text_font::Bool`: the text parts of math labels are drawn in the
  label's own font.

The package default is
`(enabled = true, size = "", font = "", inherit_text_font = false)`.
"""
function get_default_mathtext()
	settings = _MATHTEXT_SETTINGS[]
	return (
		enabled = settings.enabled,
		size = settings.size,
		font = settings.font,
		inherit_text_font = settings.inherit_text_font,
	)
end

"""
	set_default_mathtext!(enabled::Bool = true; size::AbstractString = "",
	                      font::AbstractString = "", inherit_text_font::Bool = false)

Configure how PlotlySupply writes and typesets every user-visible label
(titles, axis titles, legend names, colorbar titles, tick labels, annotations).

#### Arguments
- `enabled::Bool = true`: when `true`, labels go through [`mathtext`](@ref), so
  mixed labels such as `"Time \\\$t\\\$ (s)"` render completely instead of losing
  their text, and an unbalanced `\$` raises an `ArgumentError`. When `false`,
  labels are passed to plotly unchanged except that newlines become `<br>`
  (the 1.x behaviour).

#### Keywords
- `size::AbstractString = ""`: MathJax size switch prefixed to every label that
  contains math: one of `\\tiny`, `\\Tiny`, `\\scriptsize`, `\\small`,
  `\\normalsize`, `\\large`, `\\Large`, `\\LARGE`, `\\huge`, `\\Huge` (the
  leading backslash is optional). `""` uses the active [`PlotStyle`](@ref)'s
  `mathsize` (`"\\\\large"` under `:publication`, none under `:default`); pass
  `"\\\\normalsize"` to switch sizing off under such a style. MathJax math
  renders at roughly 0.8× the height of plain text of the same font size, so
  `"\\\\large"` (1.2×) matches them closely. Plain labels are not affected. Other
  values throw an `ArgumentError` (`\\footnotesize` does not exist in MathJax 2).
  The size is written into the label strings when a figure is built, so it
  applies to figures created afterwards.
- `font::AbstractString = ""`: the MathJax SVG font used to typeset math, one of
  `"TeX"`, `"STIX-Web"`, `"Asana-Math"`, `"Neo-Euler"`, `"Gyre-Pagella"`,
  `"Gyre-Termes"`, `"Latin-Modern"` (case-insensitive). `""` falls back to the
  `PLOTLYSUPPLY_MATHJAX_SVG_FONT` environment variable (same names) and then to
  `"Latin-Modern"`. Other names throw an `ArgumentError`.
- `inherit_text_font::Bool = false`: when `true`, the text parts of a math label
  (the `\\text{…}` segments [`mathtext`](@ref) produces, `\\textbf{…}`, `\\mbox{…}`)
  are drawn in the font family, weight and style of the label itself (e.g. the
  figure's sans-serif font) instead of the MathJax font; math symbols keep the
  MathJax font, and MathJax scales them to the x-height of the label's font.
  When `false`, the whole label is typeset in the MathJax font.

`font` and `inherit_text_font` take effect at render time: every following
`savefig` (all formats, including HTML) uses them, and an open `SyncPlot`
window reloads its page with the new configuration before its next update
(`relayout!`, `react!`, `plot_*!`, …); until then it keeps its current
typesetting (the reload also resets any interactive zoom or pan in it). Math
labels are typeset by MathJax 2.7.9, which is loaded from a CDN, so they need
network access.

All four settings are replaced on every call (an omitted keyword resets it to
its default). Validation happens before anything changes. Returns the new
settings, like [`get_default_mathtext`](@ref).

#### Example
```julia
set_default_mathtext!(true; size = "\\\\large", font = "TeX", inherit_text_font = true)
fig = plot_scatter(1:3, [1, 4, 9]; xlabel = "Contrast \\\$\\\\lambda\\\$")
savefig(fig, "contrast.pdf")   # "Contrast" in the figure font, λ in MathJax TeX
set_default_mathtext!()          # back to the defaults
```
"""
function set_default_mathtext!(
	enabled::Bool = true;
	size::AbstractString = "",
	font::AbstractString = "",
	inherit_text_font::Bool = false,
)
	normalized = _normalize_mathtext_size(size, "set_default_mathtext!")
	font_name = if isempty(strip(font))
		""
	else
		canonical = _mathjax_font_name(font)
		canonical === nothing && throw(ArgumentError(
			"set_default_mathtext!: `font` must be \"\" or one of the MathJax SVG " *
			"fonts $(join(_MATHJAX_SVG_FONTS, ", ")); got $(repr(font)).",
		))
		canonical
	end
	_MATHTEXT_SETTINGS[] =
		_MathtextSettings(enabled, normalized, font_name, inherit_text_font)
	return get_default_mathtext()
end

# Internal label hook used by every label writer in the package for text plotly
# renders with MathJax (titles, axis titles, legend names, colorbar titles, tick
# labels, 2-D and 3-D annotations). Applies the mathtext pipeline when it is
# enabled (`set_default_mathtext!`); otherwise only converts newlines to `<br>`.
# Idempotent: `_label(_label(s)) == _label(s)`, so a label that passes through
# two writers is not mangled. Throws `ArgumentError` for labels that cannot be
# rendered (see `mathtext`). Text plotly draws WITHOUT MathJax (3-D scene axis
# titles and tick labels, hover/shape labels) must use `_label_plain` instead.
function _label(s::AbstractString; align::Symbol = :c)::String
	settings = _MATHTEXT_SETTINGS[]
	column = _mathtext_align_column(align, "mathtext")
	settings.enabled || return _mathtext_newlines_to_br(String(s))
	return _mathtext(String(s), column, nothing)
end

"""
	mathtext(s::AbstractString; align::Symbol = :c, size::Union{Nothing,AbstractString} = nothing)

Convert a matplotlib-style label, where math is written between `\$` signs and
everything else is text, into the single MathJax expression plotly can
typeset. Plotly typesets only the first `\$…\$` group of a label and silently
drops the text around it; `mathtext` keeps all of it. PlotlySupply's label
writers apply this automatically (see [`set_default_mathtext!`](@ref)); call it
directly when you write raw Plotly attributes.

#### Arguments
- `s::AbstractString`: the label. `String`, `SubString` and `LaTeXString`
  (`L"…"`, which wraps its content in `\$…\$`) are accepted.

#### Keywords
- `align::Symbol = :c`: horizontal alignment of the lines of a multi-line label
  that contains math: `:c`, `:l` or `:r` (`:center`, `:left`, `:right` are
  synonyms). Plain multi-line labels are aligned by the plotly element itself.
- `size::Union{Nothing,AbstractString} = nothing`: MathJax size switch for
  labels that contain math, one of `\\tiny … \\Huge`, or `""` for none.
  `nothing` uses the package setting ([`set_default_mathtext!`](@ref)) and,
  when that is `""`, the active [`PlotStyle`](@ref)'s `mathsize`.

#### Rules
- A `\$` preceded by an odd number of backslashes is escaped (`\\\$` is a
  literal dollar sign); every other `\$` delimits math. `\$\$…\$\$` is display math.
- **Plain labels** (no math) are returned unchanged, HTML tags such as `<b>`,
  `<sup>` and `<br>` included, except that newlines become `<br>` and `\\\$`
  becomes the entity `&#36;` (plotly renders it as `\$`; a raw `\$` would make a
  label with two of them look like math to plotly).
- An odd number of unescaped `\$` throws an `ArgumentError`.
- **Labels with math** become one `\$…\$` expression:
  - Text parts are written as `\\text{…}` and render literally, without TeX
    escaping: `% & # _ ^ ~`, balanced `{}` and unicode print as typed
    (`5\\%` prints the backslash). Backslashes, unbalanced braces, `<`, `>` and
    `\\\$` are emitted as math symbols so they print literally too. The HTML
    entities plotly knows (`&amp;`, `&lt;`, `&#36;`, …) are decoded, `<br>`
    starts a new line, and any other HTML tag throws an `ArgumentError` (use TeX
    such as `\\textbf{…}` inside the math instead).
  - Math parts are kept verbatim, except that the matplotlib-only macros
    `\\mathdefault{x}` → `{x}`, `\\mathregular` → `\\mathrm`, `\\degree` →
    `{^\\circ}` and `\\AA` → `\\mathring{\\mathrm{A}}` are rewritten, and `%` and
    `#` outside text arguments are escaped (a raw `%` would comment out the
    rest of the label, a raw `#` blanks it). Unbalanced braces, `\\begin`/`\\end`
    or `\\left`/`\\right`, and a literal `\\\$` inside math (which blanks the whole
    label in plotly; write `\\unicode{36}` instead) throw an `ArgumentError`.
  - A newline (or `<br>`) anywhere produces an `array` environment with one row
    per line, aligned by `align`.
  - A label that is already one `\$…\$` (or `\$\$…\$\$`) expression is returned
    unchanged apart from those rewrites, newlines and `size`.
  - `size` is applied as `\$\\large{…}\$`, unless the math already starts with a
    size switch.

Returns a `String`.

#### Examples
```julia
mathtext("(a) Mesh study, \\\$\\\\lambda=10^8\\\$")   # "\\\$\\\\text{(a) Mesh study, }\\\\lambda=10^8\\\$"
mathtext("Plain <b>bold</b>\\nline 2")             # "Plain <b>bold</b><br>line 2"
mathtext("Error 5% \\\$\\\\epsilon\\\$\\nsecond"; align = :l)
```
"""
function mathtext(
	s::AbstractString;
	align::Symbol = :c,
	size::Union{Nothing,AbstractString} = nothing,
)::String
	column = _mathtext_align_column(align, "mathtext")
	normalized_size = size === nothing ? nothing :
		_normalize_mathtext_size(size, "mathtext")
	return _mathtext(String(s), column, normalized_size)
end

# Newline handling shared by every path: "\r\n", "\r" and "\n" each count as one
# line break (plotly turns all three into spaces in plain text).
function _mathtext_newlines_to_br(s::String)
	occursin(r"[\r\n]", s) || return s
	return replace(s, r"\r\n|\r|\n" => "<br>")
end

# `size === nothing` means the default size (`_mathtext_default_size`). It is
# resolved only for labels that contain math, so plain labels never depend on
# (or fail because of) the active style's `mathsize`.
function _mathtext(s::String, column::Char, size::Union{Nothing,String})::String
	isvalid(s) || throw(ArgumentError("mathtext: label is not valid UTF-8: $(repr(s))."))
	chars = collect(s)
	segments = _mathtext_segments(chars, s)
	if all(segment -> segment[1] === :text, segments)
		return _mathtext_plain(chars)
	end
	resolved = size === nothing ? _mathtext_default_size() : size
	return _mathtext_compose(segments, s, column, resolved)
end

# Number of consecutive backslashes immediately before position `k`.
function _mathtext_backslashes_before(chars::Vector{Char}, k::Int)
	count = 0
	j = k - 1
	while j >= 1 && chars[j] == '\\'
		count += 1
		j -= 1
	end
	return count
end

# Split a label into (:text | :math | :display, content) segments at the
# unescaped `$` signs, with TeX's rules: outside math `$$` opens display math
# and `$` inline math; inside inline math the next `$` closes; inside display
# math only `$$` closes.
function _mathtext_segments(chars::Vector{Char}, label::String)
	segments = Tuple{Symbol, String}[]
	n = length(chars)
	mode = :text
	start = 1
	unescaped = 0
	k = 1
	while k <= n
		if chars[k] == '$' && iseven(_mathtext_backslashes_before(chars, k))
			double = k < n && chars[k + 1] == '$'
			if mode === :text
				k > start && push!(segments, (:text, String(chars[start:(k - 1)])))
				if double
					mode = :display
					unescaped += 2
					k += 2
				else
					mode = :math
					unescaped += 1
					k += 1
				end
				start = k
			elseif mode === :math
				push!(segments, (:math, String(chars[start:(k - 1)])))
				mode = :text
				unescaped += 1
				k += 1
				start = k
			else
				double || _mathtext_error(
					"a single unescaped \$ inside \$\$…\$\$ display math (write \\\$ for a literal dollar sign)",
					label,
				)
				push!(segments, (:display, String(chars[start:(k - 1)])))
				mode = :text
				unescaped += 2
				k += 2
				start = k
			end
			continue
		end
		k += 1
	end
	if mode !== :text
		opener = mode === :display ? "\$\$" : "\$"
		_mathtext_error(
			"unbalanced \$: the $(opener) opening math is never closed ($(unescaped) unescaped \$ found; " *
			"write \\\$ for a literal dollar sign)",
			label,
		)
	end
	start <= n && push!(segments, (:text, String(chars[start:n])))
	return segments
end

# Plain label (or a text segment): only escaped dollars and newlines change.
# `\$` becomes `dollar`: the entity `&#36;` for MathJax-capable text (a raw `$`
# pair would be taken for math by plotly), a raw `$` where plotly never
# typesets math (`_label_plain`).
function _mathtext_plain(chars::AbstractVector{Char}; dollar::AbstractString = "&#36;")
	out = IOBuffer()
	n = length(chars)
	k = 1
	while k <= n
		c = chars[k]
		if c == '\\' && k < n && chars[k + 1] == '$'
			# Every `$` of a plain label is escaped, i.e. preceded by an odd
			# backslash run; this backslash is the escaping one.
			print(out, dollar)
			k += 2
		elseif c == '\r'
			print(out, "<br>")
			k += (k < n && chars[k + 1] == '\n') ? 2 : 1
		elseif c == '\n'
			print(out, "<br>")
			k += 1
		elseif c == '\\'
			# Copy backslashes in pairs, so the backslash seen right before a `$`
			# above is always the odd (escaping) one of its run.
			print(out, c)
			if k < n && chars[k + 1] == '\\'
				print(out, '\\')
				k += 2
			else
				k += 1
			end
		else
			print(out, c)
			k += 1
		end
	end
	return String(take!(out))
end

# --- composing a math label ---------------------------------------------------

# A character that goes inside `\text{…}`.
struct _MathtextChar
	c::Char
end

# Math-mode TeX inserted verbatim (symbols that cannot live inside `\text{}`).
struct _MathtextAtom
	tex::String
end

# A user math piece (one line of a `$…$` segment).
struct _MathtextMath
	tex::String
	display::Bool
	leaks::Bool
end

const _MathtextItem = Union{_MathtextChar, _MathtextAtom, _MathtextMath}

function _mathtext_compose(segments, label::String, column::Char, size::String)
	if length(segments) == 1
		kind, content = segments[1]
		if !occursin(r"[\r\n]", content)
			rewritten = _mathtext_rewrite_math(content, label)
			delimiter = kind === :display ? "\$\$" : "\$"
			body = rewritten.tex
			if !isempty(size) && !_mathtext_starts_with_size(body)
				body = size * "{" * body * "}"
			end
			return delimiter * body * delimiter
		end
	end
	lines = Vector{_MathtextItem}[_MathtextItem[]]
	for (kind, content) in segments
		if kind === :text
			_mathtext_text_items!(lines, content, label)
		else
			pieces = split(content, r"\r\n|\r|\n")
			for (index, piece) in enumerate(pieces)
				index > 1 && push!(lines, _MathtextItem[])
				rewritten = _mathtext_rewrite_math(String(piece), label)
				isempty(strip(rewritten.tex)) && continue
				push!(lines[end], _MathtextMath(rewritten.tex, kind === :display, rewritten.leaks))
			end
		end
	end
	wrap_leaks = length(lines) > 1 || any(line -> length(line) > 1, lines)
	rows = [_mathtext_render_line(line, wrap_leaks) for line in lines]
	body = if length(rows) == 1
		rows[1]
	else
		# Each row is braced: MathJax would otherwise read a row starting with
		# `[` as the optional `\\[<dimension>]` argument, which blanks the label
		# (verified). A bare `\\{}` guard is not used because the empty group
		# turns a leading `-` into a binary minus.
		"\\begin{array}{$(column)}" * join(("{" * row * "}" for row in rows), "\\\\") * "\\end{array}"
	end
	isempty(size) || (body = size * "{" * body * "}")
	return "\$" * body * "\$"
end

function _mathtext_starts_with_size(tex::AbstractString)
	m = match(r"^\s*\\([A-Za-z]+)", tex)
	return m !== nothing && m.captures[1] in _MATHTEXT_SIZES
end

# Decode the entities plotly decodes in plain labels. Returns (char, literal)
# pairs; `literal` marks characters that came from an entity, which are always
# printed literally (a decoded `{` never balances a raw `}`).
function _mathtext_decode_entities(text::AbstractString)
	decoded = Tuple{Char, Bool}[]
	position = firstindex(text)
	for m in eachmatch(r"&(#\d+|#x[\da-fA-F]+|[a-z]+);", text)
		for c in SubString(text, position, prevind(text, m.offset))
			push!(decoded, (c, false))
		end
		name = m.captures[1]
		code = if startswith(name, "#x")
			tryparse(UInt32, name[3:end]; base = 16)
		elseif startswith(name, "#")
			tryparse(UInt32, name[2:end]; base = 10)
		else
			nothing
		end
		replacement = if code !== nothing
			(code != 0 && isvalid(Char, code)) ? Char(code) : nothing
		else
			get(_MATHTEXT_ENTITIES, name, nothing)
		end
		if replacement === nothing
			for c in m.match
				push!(decoded, (c, false))
			end
		else
			push!(decoded, (replacement, true))
		end
		position = m.offset + ncodeunits(m.match)
	end
	for c in SubString(text, position, lastindex(text))
		push!(decoded, (c, false))
	end
	return decoded
end

# Append the items of a text segment to `lines` (a new line starts at every
# newline or `<br>`).
function _mathtext_text_items!(lines, text::String, label::String)
	position = 1
	for m in eachmatch(r"<[^<>]*>", text)
		_mathtext_plain_text_items!(lines, SubString(text, position, prevind(text, m.offset)))
		tag = match(r"^<(/?)([^ >]*)(\s+(.*))?>$"s, m.match)
		name = tag === nothing ? "" : lowercase(tag.captures[2])
		if name in ("br", "br/")
			push!(lines, _MathtextItem[])
		elseif name in _MATHTEXT_HTML_TAGS || rstrip(name, '/') in _MATHTEXT_HTML_TAGS
			_mathtext_error(
				"HTML tag $(m.match) cannot be combined with \$…\$ math in one label (MathJax renders " *
				"the whole label; only <br> is supported). Use TeX inside the math instead, e.g. " *
				"\$\\textbf{…}\$, \$\\textit{…}\$, \$^{…}\$ or \$_{…}\$",
				label,
			)
		else
			_mathtext_plain_text_items!(lines, m.match)
		end
		position = m.offset + ncodeunits(m.match)
	end
	_mathtext_plain_text_items!(lines, SubString(text, position, lastindex(text)))
	return lines
end

function _mathtext_plain_text_items!(lines, text::AbstractString)
	isempty(text) && return lines
	decoded = _mathtext_decode_entities(text)
	n = length(decoded)
	k = 1
	while k <= n
		c, literal = decoded[k]
		if !literal && c == '\r'
			push!(lines, _MathtextItem[])
			k += (k < n && decoded[k + 1] == ('\n', false)) ? 2 : 1
			continue
		elseif !literal && c == '\n'
			push!(lines, _MathtextItem[])
		elseif !literal && c == '\\'
			if k < n && decoded[k + 1] == ('$', false)
				# `\$`: a literal dollar sign. The `$` character itself cannot
				# appear in a math label (plotly would split the label there);
				# MathJax's \unicode renders it (verified).
				push!(lines[end], _MathtextAtom("\\unicode{36}"))
				k += 2
				continue
			end
			push!(lines[end], _MathtextAtom("\\backslash"))
		elseif c == '$'
			push!(lines[end], _MathtextAtom("\\unicode{36}"))
		elseif c == '\\'
			push!(lines[end], _MathtextAtom("\\backslash"))
		elseif c == '<'
			push!(lines[end], _MathtextAtom("{<}"))
		elseif c == '>'
			push!(lines[end], _MathtextAtom("{>}"))
		elseif literal && c == '{'
			push!(lines[end], _MathtextAtom("\\{"))
		elseif literal && c == '}'
			push!(lines[end], _MathtextAtom("\\}"))
		else
			push!(lines[end], _MathtextChar(c))
		end
		k += 1
	end
	return lines
end

# Render one line: runs of text characters become `\text{…}` (unmatched braces
# split out as `\{`/`\}`), atoms and math pieces are inserted verbatim.
function _mathtext_render_line(items::Vector{_MathtextItem}, wrap_leaks::Bool)
	chunks = String[]
	run = Char[]
	for item in items
		if item isa _MathtextChar
			push!(run, item.c)
			continue
		end
		_mathtext_flush_text_run!(chunks, run)
		if item isa _MathtextAtom
			push!(chunks, item.tex)
		elseif item.display
			push!(chunks, "{\\displaystyle " * item.tex * "}")
		elseif item.leaks && wrap_leaks
			push!(chunks, "{" * item.tex * "}")
		else
			push!(chunks, item.tex)
		end
	end
	_mathtext_flush_text_run!(chunks, run)
	out = IOBuffer()
	for (index, chunk) in enumerate(chunks)
		# A control word followed by a letter would merge into another name
		# (`\backslash` + `x` -> `\backslashx`); a space separates them and is
		# ignored in math mode.
		if index > 1 && _mathtext_isletter(last(chunks[index - 1])) && _mathtext_isletter(first(chunk))
			print(out, ' ')
		end
		print(out, chunk)
	end
	return String(take!(out))
end

const _MATHTEXT_TEX_ESCAPE_ENTITIES = ("&lt;", "&gt;", "&#60;", "&#62;")

function _mathtext_flush_text_run!(chunks::Vector{String}, run::Vector{Char})
	isempty(run) && return chunks
	n = length(run)
	unmatched = falses(n)
	open = Int[]
	for (k, c) in enumerate(run)
		if c == '{'
			push!(open, k)
		elseif c == '}'
			isempty(open) ? (unmatched[k] = true) : pop!(open)
		end
	end
	for k in open
		unmatched[k] = true
	end
	text = Char[]
	flush_text() = if !isempty(text)
		push!(chunks, "\\text{" * String(text) * "}")
		empty!(text)
	end
	for k in 1:n
		c = run[k]
		if unmatched[k]
			flush_text()
			push!(chunks, c == '{' ? "\\{" : "\\}")
		elseif c == '&' && any(e -> _mathtext_run_has(run, k, e), _MATHTEXT_TEX_ESCAPE_ENTITIES)
			# plotly would turn this literal text into `\lt `/`\gt ` before
			# typesetting; an escaped `&` in math mode breaks the sequence.
			flush_text()
			push!(chunks, "\\&")
		else
			push!(text, c)
		end
	end
	flush_text()
	empty!(run)
	return chunks
end

function _mathtext_run_has(run::Vector{Char}, k::Int, needle::String)
	for (offset, c) in enumerate(needle)
		index = k + offset - 1
		(index <= length(run) && run[index] == c) || return false
	end
	return true
end

# Rewrite one math piece (no newlines): matplotlib-only macros, `%` and `#`
# outside raw arguments; validate braces, environments and \left/\right.
# Returns (tex, leaks), where `leaks` says the piece has a top-level switch.
function _mathtext_rewrite_math(piece::String, label::String)
	chars = collect(piece)
	n = length(chars)
	out = IOBuffer()
	depth = 0
	raw_depths = Int[]          # brace depths at which raw (text) arguments opened
	pending_raw = false         # a raw-argument macro was just read
	environments = 0
	delimiters = 0
	leaks = false
	definitions = false
	k = 1
	while k <= n
		c = chars[k]
		in_raw = !isempty(raw_depths)
		if c == '\\'
			k == n && _mathtext_error(
				"math $(repr(piece)) ends with a lone backslash (before a line break)",
				label,
			)
			next = chars[k + 1]
			if _mathtext_isletter(next)
				stop = k + 1
				while stop < n && _mathtext_isletter(chars[stop + 1])
					stop += 1
				end
				name = String(chars[(k + 1):stop])
				if in_raw
					print(out, '\\', name)
				else
					pending_raw && (pending_raw = false)
					print(out, get(_MATHTEXT_MACRO_REWRITES, name, "\\" * name))
					name in _MATHTEXT_RAW_ARG_MACROS && (pending_raw = true)
					name in _MATHTEXT_SWITCH_MACROS && depth == 0 && (leaks = true)
					name in _MATHTEXT_DEFINITION_MACROS && (definitions = true)
					if name == "begin"
						environments += 1
					elseif name == "end"
						environments -= 1
						environments < 0 && _mathtext_error(
							"\\end without a matching \\begin in math $(repr(piece))",
							label,
						)
					elseif name == "left"
						delimiters += 1
					elseif name == "right"
						delimiters -= 1
						delimiters < 0 && _mathtext_error(
							"\\right without a matching \\left in math $(repr(piece))",
							label,
						)
					end
				end
				k = stop + 1
			else
				next == '$' && _mathtext_error(
					"a literal \\\$ inside \$…\$ math cannot be rendered by plotly (it blanks the whole label); " *
					"write \\unicode{36} in the math, or put \\\$ in the text outside the math",
					label,
				)
				pending_raw && !in_raw && (pending_raw = false)
				print(out, '\\', next)
				k += 2
			end
			continue
		end
		if c == '{'
			depth += 1
			if pending_raw
				push!(raw_depths, depth)
				pending_raw = false
			end
			print(out, c)
		elseif c == '}'
			depth -= 1
			depth < 0 && _mathtext_error("unbalanced braces (an unmatched }) in math $(repr(piece))", label)
			!isempty(raw_depths) && raw_depths[end] == depth + 1 && pop!(raw_depths)
			print(out, c)
		elseif isspace(c)
			print(out, c)
		else
			# A raw-argument macro followed by a single token (`\text x`).
			pending_raw && (pending_raw = false)
			if !in_raw && c == '%'
				print(out, "\\%")
			elseif !in_raw && c == '#' && !definitions
				print(out, "\\#")
			else
				print(out, c)
			end
		end
		k += 1
	end
	depth > 0 && _mathtext_error("unbalanced braces (an unclosed {) in math $(repr(piece))", label)
	environments > 0 && _mathtext_error("\\begin without a matching \\end in math $(repr(piece))", label)
	delimiters > 0 && _mathtext_error("\\left without a matching \\right in math $(repr(piece))", label)
	return (tex = String(take!(out)), leaks = leaks)
end

# --- labels for text plotly draws without MathJax ------------------------------
#
# 3-D scene axis titles and tick labels are drawn by WebGL: `$…$` is printed raw
# there and HTML entities are not decoded, while `<br>` and `<b>` work
# (verified in an export). plotly also never typesets math in SVG text it marks
# `data-notex` (hover labels, shape labels, pie titles, slider/updatemenu
# labels). `_label_plain` is the label hook for those places: text segments are
# kept (with `\$` -> `$`), and math segments are approximated with Unicode
# symbols and `<sup>`/`<sub>`.

# Internal label hook for text plotly draws without MathJax (see above). The `$`
# rules and errors match `mathtext`; when mathtext is disabled only newlines
# change, as in `_label`.
function _label_plain(s::AbstractString)::String
	str = String(s)
	_MATHTEXT_SETTINGS[].enabled || return _mathtext_newlines_to_br(str)
	isvalid(str) || throw(ArgumentError("mathtext: label is not valid UTF-8: $(repr(str))."))
	segments = _mathtext_segments(collect(str), str)
	out = IOBuffer()
	for (kind, content) in segments
		if kind === :text
			print(out, _mathtext_plain(collect(content); dollar = "\$"))
		else
			print(out, _tex_to_plain(content))
		end
	end
	return _mathtext_newlines_to_br(String(take!(out)))
end

const _TEX_PLAIN_SYMBOLS = Dict{String, String}(
	# Greek (TeX's \epsilon and \phi are the lunate/closed forms)
	"alpha" => "α", "beta" => "β", "gamma" => "γ", "delta" => "δ", "epsilon" => "ϵ",
	"varepsilon" => "ε", "zeta" => "ζ", "eta" => "η", "theta" => "θ", "vartheta" => "ϑ",
	"iota" => "ι", "kappa" => "κ", "varkappa" => "ϰ", "lambda" => "λ", "mu" => "μ",
	"nu" => "ν", "xi" => "ξ", "omicron" => "ο", "pi" => "π", "varpi" => "ϖ", "rho" => "ρ",
	"varrho" => "ϱ", "sigma" => "σ", "varsigma" => "ς", "tau" => "τ", "upsilon" => "υ",
	"phi" => "ϕ", "varphi" => "φ", "chi" => "χ", "psi" => "ψ", "omega" => "ω",
	"Gamma" => "Γ", "Delta" => "Δ", "Theta" => "Θ", "Lambda" => "Λ", "Xi" => "Ξ",
	"Pi" => "Π", "Sigma" => "Σ", "Upsilon" => "Υ", "Phi" => "Φ", "Psi" => "Ψ", "Omega" => "Ω",
	# letter-like symbols
	"infty" => "∞", "partial" => "∂", "nabla" => "∇", "ell" => "ℓ", "hbar" => "ℏ",
	"Re" => "ℜ", "Im" => "ℑ", "aleph" => "ℵ", "emptyset" => "∅", "varnothing" => "∅",
	"degree" => "°", "AA" => "Å", "circ" => "∘", "prime" => "′", "dagger" => "†",
	"ddagger" => "‡", "angle" => "∠", "triangle" => "△", "square" => "□", "Box" => "□",
	# operators and relations
	"pm" => "±", "mp" => "∓", "times" => "×", "cdot" => "⋅", "div" => "÷", "ast" => "∗",
	"star" => "⋆", "bullet" => "•", "oplus" => "⊕", "otimes" => "⊗", "odot" => "⊙",
	"setminus" => "∖", "cup" => "∪", "cap" => "∩", "wedge" => "∧", "land" => "∧",
	"vee" => "∨", "lor" => "∨", "neg" => "¬", "lnot" => "¬",
	"approx" => "≈", "sim" => "∼", "simeq" => "≃", "cong" => "≅", "equiv" => "≡",
	"neq" => "≠", "ne" => "≠", "leq" => "≤", "le" => "≤", "geq" => "≥", "ge" => "≥",
	"ll" => "≪", "gg" => "≫", "lt" => "<", "gt" => ">", "propto" => "∝", "perp" => "⊥",
	"parallel" => "∥", "mid" => "|", "in" => "∈", "notin" => "∉", "ni" => "∋",
	"subset" => "⊂", "subseteq" => "⊆", "supset" => "⊃", "supseteq" => "⊇",
	"forall" => "∀", "exists" => "∃",
	# arrows
	"to" => "→", "rightarrow" => "→", "leftarrow" => "←", "gets" => "←",
	"leftrightarrow" => "↔", "Rightarrow" => "⇒", "Leftarrow" => "⇐",
	"Leftrightarrow" => "⇔", "mapsto" => "↦", "uparrow" => "↑", "downarrow" => "↓",
	# big operators
	"sum" => "∑", "prod" => "∏", "int" => "∫", "iint" => "∬", "iiint" => "∭", "oint" => "∮",
	# dots, delimiters, spacing
	"ldots" => "…", "dots" => "…", "cdots" => "⋯", "vdots" => "⋮", "ddots" => "⋱",
	"langle" => "⟨", "rangle" => "⟩", "lbrace" => "{", "rbrace" => "}", "lbrack" => "[",
	"rbrack" => "]", "vert" => "|", "lvert" => "|", "rvert" => "|", "Vert" => "‖",
	"lVert" => "‖", "rVert" => "‖", "lfloor" => "⌊", "rfloor" => "⌋", "lceil" => "⌈",
	"rceil" => "⌉", "backslash" => "\\", "colon" => ":",
	"quad" => " ", "qquad" => "  ",
)

# Named operators that TeX prints upright as their own name (`\sin` -> "sin").
const _TEX_PLAIN_FUNCTION_NAMES = Set([
	"sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh",
	"cosh", "tanh", "coth", "log", "ln", "lg", "exp", "lim", "liminf", "limsup",
	"max", "min", "sup", "inf", "det", "arg", "deg", "dim", "ker", "gcd", "hom", "Pr",
])

# Control symbols (backslash + non-letter). `\\` is a line break.
const _TEX_PLAIN_CONTROL_SYMBOLS = Dict{Char, String}(
	',' => " ", ':' => " ", '>' => " ", ';' => " ", '!' => "",
	' ' => " ", '\\' => "\n", '|' => "‖",
)

# Macros whose (math) argument is shown without the styling plain text cannot express.
const _TEX_PLAIN_FONT_MACROS = Set([
	"mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathfrak", "mathscr",
	"mathnormal", "boldsymbol", "bm", "pmb", "mathdefault", "mathregular", "operatorname",
	"mathop", "mathbin", "mathrel", "mathord", "mathopen", "mathclose", "mathpunct",
	"overbrace", "underbrace", "boxed",
])

# Macros whose argument is literal text.
const _TEX_PLAIN_TEXT_MACROS = Set([
	"text", "textrm", "textbf", "textit", "textsf", "texttt", "textnormal", "textup",
	"textmd", "textsl", "mbox", "hbox", "fbox",
])

# Declarations and spacing/sizing commands with no plain-text equivalent.
const _TEX_PLAIN_IGNORED = Set([
	"rm", "it", "bf", "sf", "tt", "cal", "mit", "oldstyle", "scr", "frak", "bbFont", "bold",
	"displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", _MATHTEXT_SIZES...,
	"limits", "nolimits", "displaylimits", "strut", "mathstrut", "relax", "nonumber", "notag",
])

const _TEX_PLAIN_DELIMITER_SIZES = Set([
	"left", "right", "middle", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl",
	"Bigr", "biggl", "biggr", "Biggl", "Biggr", "bigm", "Bigm", "biggm", "Biggm",
])

# Accents as Unicode combining marks.
const _TEX_PLAIN_ACCENTS = Dict{String, Char}(
	"hat" => '̂', "widehat" => '̂', "check" => '̌', "tilde" => '̃',
	"widetilde" => '̃', "acute" => '́', "grave" => '̀', "dot" => '̇',
	"ddot" => '̈', "breve" => '̆', "bar" => '̄', "vec" => '⃗',
	"mathring" => '̊', "overline" => '̅', "underline" => '̲',
)

const _TEX_PLAIN_BLACKBOARD = Dict{String, String}(
	"R" => "ℝ", "N" => "ℕ", "Z" => "ℤ", "Q" => "ℚ", "C" => "ℂ", "P" => "ℙ", "H" => "ℍ",
)

mutable struct _TexPlainCursor
	chars::Vector{Char}
	pos::Int
end

_tex_plain_done(cur::_TexPlainCursor) = cur.pos > length(cur.chars)

function _tex_plain_skip_spaces!(cur::_TexPlainCursor)
	while !_tex_plain_done(cur) && cur.chars[cur.pos] in (' ', '\t')
		cur.pos += 1
	end
	return cur
end

function _tex_to_plain(tex::AbstractString)
	cur = _TexPlainCursor(collect(tex), 1)
	return _tex_plain_until!(cur, false)
end

function _tex_plain_char(c::Char)
	c == '-' && return "−"
	c == '\'' && return "′"
	c == '~' && return "\u00a0"
	c == '&' && return " "
	return string(c)
end

# Convert until the end of input, or (in_group) until the closing `}`.
function _tex_plain_until!(cur::_TexPlainCursor, in_group::Bool)
	out = IOBuffer()
	while !_tex_plain_done(cur)
		c = cur.chars[cur.pos]
		if c == '}'
			cur.pos += 1
			in_group && return String(take!(out))
			print(out, '}')   # a stray `}` is shown rather than dropped
		elseif c == '{'
			cur.pos += 1
			print(out, _tex_plain_until!(cur, true))
		elseif c == '^' || c == '_'
			cur.pos += 1
			tag = c == '^' ? "sup" : "sub"
			print(out, "<", tag, ">", _tex_plain_arg!(cur), "</", tag, ">")
		elseif c == '\\'
			print(out, _tex_plain_control!(cur))
		else
			cur.pos += 1
			print(out, _tex_plain_char(c))
		end
	end
	return String(take!(out))
end

# One macro argument: a braced group or a single token, converted.
function _tex_plain_arg!(cur::_TexPlainCursor)
	_tex_plain_skip_spaces!(cur)
	_tex_plain_done(cur) && return ""
	c = cur.chars[cur.pos]
	if c == '{'
		cur.pos += 1
		return _tex_plain_until!(cur, true)
	elseif c == '\\'
		return _tex_plain_control!(cur)
	end
	cur.pos += 1
	return _tex_plain_char(c)
end

# One macro argument taken literally (text, colour names, environment names).
# `\{`, `\}`, `\$` and `\\` print the escaped character, as in MathJax's \text.
function _tex_plain_raw_arg!(cur::_TexPlainCursor)
	_tex_plain_skip_spaces!(cur)
	_tex_plain_done(cur) && return ""
	if cur.chars[cur.pos] != '{'
		c = cur.chars[cur.pos]
		cur.pos += 1
		return string(c)
	end
	cur.pos += 1
	out = IOBuffer()
	depth = 0
	n = length(cur.chars)
	while cur.pos <= n
		c = cur.chars[cur.pos]
		if c == '\\' && cur.pos < n && cur.chars[cur.pos + 1] in ('{', '}', '$', '\\')
			print(out, cur.chars[cur.pos + 1])
			cur.pos += 2
			continue
		elseif c == '{'
			depth += 1
		elseif c == '}'
			if depth == 0
				cur.pos += 1
				return String(take!(out))
			end
			depth -= 1
		end
		print(out, c)
		cur.pos += 1
	end
	return String(take!(out))
end

# Parenthesise a fraction/root operand unless it is a single "word" or number.
_tex_plain_operand(s::AbstractString) =
	occursin(r"^[\p{L}\p{M}\p{N}.]*$", s) ? String(s) : "(" * s * ")"

function _tex_plain_control!(cur::_TexPlainCursor)
	n = length(cur.chars)
	cur.pos += 1                    # the backslash
	cur.pos > n && return "\\"
	c = cur.chars[cur.pos]
	if !_mathtext_isletter(c)
		cur.pos += 1
		return get(_TEX_PLAIN_CONTROL_SYMBOLS, c, string(c))
	end
	stop = cur.pos
	while stop < n && _mathtext_isletter(cur.chars[stop + 1])
		stop += 1
	end
	name = String(cur.chars[cur.pos:stop])
	cur.pos = stop + 1
	return _tex_plain_macro!(cur, name)
end

function _tex_plain_macro!(cur::_TexPlainCursor, name::String)
	symbol = get(_TEX_PLAIN_SYMBOLS, name, nothing)
	symbol === nothing || return symbol
	if name in _TEX_PLAIN_FUNCTION_NAMES
		# TeX separates an operator name from a following symbol (`\sin\theta`).
		next = _tex_plain_done(cur) ? ' ' : cur.chars[cur.pos]
		return (next == '\\' || _mathtext_isletter(next)) ? name * " " : name
	end
	name in _TEX_PLAIN_IGNORED && return ""
	name in _TEX_PLAIN_FONT_MACROS && return _tex_plain_arg!(cur)
	name in _TEX_PLAIN_TEXT_MACROS && return _tex_plain_raw_arg!(cur)
	if name == "mathbb"
		arg = _tex_plain_arg!(cur)
		return get(_TEX_PLAIN_BLACKBOARD, arg, arg)
	elseif name in _TEX_PLAIN_DELIMITER_SIZES
		_tex_plain_skip_spaces!(cur)
		# `\left.` is an invisible delimiter.
		!_tex_plain_done(cur) && cur.chars[cur.pos] == '.' && (cur.pos += 1)
		return ""
	elseif haskey(_TEX_PLAIN_ACCENTS, name)
		mark = _TEX_PLAIN_ACCENTS[name]
		arg = _tex_plain_arg!(cur)
		length(arg) == 1 && return arg * mark
		if name in ("overline", "underline", "bar")
			return join(string(ch, mark) for ch in arg)
		end
		return arg
	elseif name in ("frac", "dfrac", "tfrac", "cfrac")
		numerator = _tex_plain_arg!(cur)
		denominator = _tex_plain_arg!(cur)
		return _tex_plain_operand(numerator) * "/" * _tex_plain_operand(denominator)
	elseif name == "sqrt"
		_tex_plain_skip_spaces!(cur)
		index = ""
		if !_tex_plain_done(cur) && cur.chars[cur.pos] == '['
			close = findnext(==(']'), cur.chars, cur.pos)
			if close !== nothing
				index = _tex_to_plain(String(cur.chars[(cur.pos + 1):(close - 1)]))
				cur.pos = close + 1
			end
		end
		radicand = _tex_plain_operand(_tex_plain_arg!(cur))
		index == "3" && return "∛" * radicand
		index == "4" && return "∜" * radicand
		isempty(index) && return "√" * radicand
		return "<sup>" * index * "</sup>√" * radicand
	elseif name == "not"
		return _tex_plain_arg!(cur) * "̸"
	elseif name in ("color", "label", "phantom", "hphantom", "vphantom", "tag", "end")
		# The argument is not printed (a colour name, a label, invisible content).
		_tex_plain_raw_arg!(cur)
		return ""
	elseif name == "textcolor"
		_tex_plain_raw_arg!(cur)
		return _tex_plain_arg!(cur)
	elseif name == "begin"
		environment = _tex_plain_raw_arg!(cur)
		environment in ("array", "tabular") && _tex_plain_raw_arg!(cur)   # column spec
		return ""
	elseif name == "unicode"
		arg = strip(_tex_plain_raw_arg!(cur))
		code = (startswith(arg, "x") || startswith(arg, "X")) ?
			tryparse(UInt32, arg[2:end]; base = 16) : tryparse(UInt32, arg; base = 10)
		(code !== nothing && code != 0 && isvalid(Char, code)) && return string(Char(code))
		return "\\unicode{" * arg * "}"
	end
	# Unknown macro: shown as written, with its braced arguments, so nothing is
	# silently lost.
	out = IOBuffer()
	print(out, '\\', name)
	while !_tex_plain_done(cur) && cur.chars[cur.pos] == '{'
		cur.pos += 1
		print(out, '{', _tex_plain_until!(cur, true), '}')
	end
	return String(take!(out))
end
