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
# Text is measured without the renderer, so these are estimates that err on
# the large side. The glyph classes follow Verdana, the widest face in
# plotly's default font stack ("Open Sans", verdana, arial, sans-serif), and
# MathJax 2's TeX fonts; the calibration renders (plotly.js 2.35.2, 12 and
# 20 px annotations) are listed with the tests in test/sci_style.jl.
#
# Glyph advance classes in em (narrow: i, l, t, punctuation, space; wide: M,
# W, m, w, @, %; capitals; everything else).
const _TEXT_EM_NARROW = 0.36
const _TEXT_EM_WIDE = 0.9
const _TEXT_EM_CAPITAL = 0.7
const _TEXT_EM_NORMAL = 0.62
# plotly.js turns raw newlines into spaces (svg_text_utils), so they are
# measured as one.
const _TEXT_NARROW_CHARS = Set("iljtfrI.,:;!|'` ()[]\n\r\t")
const _TEXT_WIDE_CHARS = Set("MWmw@%")
# plotly.js line break (svg_text_utils BR_TAG_ALL, applied to `<…>` tokens).
const _TEXT_BR_TAG = r"<br(\s+[^<>]*)?>"i
# plotly.js lays plain text out at 1.3 em per line (svg_text_utils
# LINE_SPACING). A MathJax row with scripts or parentheses is ~1.2 em tall
# (array rows are spaced 1.2 em apart), one with a fraction, root or stacked
# operator up to ~1.9 em.
const _TEXT_PLAIN_LINE_EM = 1.3
const _TEXT_MATH_ROW_EM = 1.3
const _TEXT_MATH_TALL_ROW_EM = 1.9
# Width (em) of a TeX relation or binary-operator glyph (0.78 em) with the
# thick/medium space MathJax puts on each side, of a Greek letter or other
# symbol command, and of a command the estimator does not know.
const _TEXT_EM_MATH_OPERATOR = 1.25
const _TEXT_EM_SYMBOL = 0.62
const _TEXT_EM_UNKNOWN = 0.7
# Script (sub/superscript) size relative to its base.
const _TEXT_SCRIPT_SCALE = 0.7
# MathJax 2 size switches (relative to \normalsize).
const _TEXT_TEX_SIZES = Dict(
	"tiny" => 0.5, "scriptsize" => 0.7, "footnotesize" => 0.8, "small" => 0.9,
	"normalsize" => 1.0, "large" => 1.2, "Large" => 1.44, "LARGE" => 1.73,
	"huge" => 2.07, "Huge" => 2.49,
)
# Commands whose single argument is typeset as it is (its width counts).
const _TEXT_TEX_WRAPPERS = Set([
	"text", "textbf", "textit", "textrm", "textsf", "texttt", "textup", "emph",
	"mbox", "hbox", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal",
	"mathbb", "mathfrak", "mathscr", "boldsymbol", "bm", "operatorname", "mathnormal",
	"hat", "bar", "vec", "tilde", "dot", "ddot", "check", "breve", "acute", "grave",
	"widehat", "widetilde", "overline", "underline", "mathring", "pmb", "displaystyle",
	"textstyle", "underbrace", "overbrace",
])
const _TEXT_TEX_TEXT_MODE = Set([
	"text", "textbf", "textit", "textrm", "textsf", "texttt", "textup", "emph", "mbox", "hbox",
])
# Two-argument constructs drawn one above the other (width = the wider part).
const _TEXT_TEX_STACKED = Set(["frac", "dfrac", "tfrac", "cfrac", "binom", "dbinom", "tbinom", "overset", "underset", "stackrel"])
const _TEXT_TEX_BIG_OPERATORS = Set(["sum", "prod", "int", "iint", "iiint", "oint", "coprod", "bigcup", "bigcap", "bigoplus", "bigotimes"])
const _TEXT_TEX_OPERATORS = Set([
	"cdot", "times", "pm", "mp", "div", "leq", "geq", "le", "ge", "neq", "ne", "approx",
	"sim", "simeq", "equiv", "propto", "to", "rightarrow", "leftarrow", "Rightarrow",
	"Leftarrow", "leftrightarrow", "Leftrightarrow", "mapsto", "in", "notin", "subset",
	"supset", "subseteq", "supseteq", "cup", "cap", "wedge", "vee", "otimes", "oplus",
	"ll", "gg", "perp", "parallel", "mid", "circ", "ast", "star", "bullet", "longrightarrow",
])
# Explicit spaces (em).
const _TEXT_TEX_SPACES = Dict(
	"quad" => 1.0, "qquad" => 2.0, "enspace" => 0.5, "thinspace" => 0.17,
	"," => 0.17, ":" => 0.22, ";" => 0.28, "!" => -0.17, " " => 0.33,
)

function _text_char_em(c::Char)
	c in _TEXT_NARROW_CHARS && return _TEXT_EM_NARROW
	c in _TEXT_WIDE_CHARS && return _TEXT_EM_WIDE
	isuppercase(c) && return _TEXT_EM_CAPITAL
	return _TEXT_EM_NORMAL
end

# Width (em) of plain text after HTML markup is removed: tags are dropped,
# entities count as one glyph, and <sub>/<sup> content is set at script size.
function _text_plain_em(s::AbstractString)
	width = 0.0
	scale = 1.0
	chars = collect(s)
	i = 1
	n = length(chars)
	while i <= n
		c = chars[i]
		if c == '<'
			close = findnext(==('>'), chars, i)
			if close !== nothing
				tag = lowercase(String(chars[(i + 1):(close - 1)]))
				if startswith(tag, "sub") || startswith(tag, "sup")
					scale = _TEXT_SCRIPT_SCALE
				elseif startswith(tag, "/sub") || startswith(tag, "/sup")
					scale = 1.0
				end
				i = close + 1
				continue
			end
		elseif c == '&'
			semi = findnext(==(';'), chars, i)
			if semi !== nothing && semi - i <= 8
				width += scale * _TEXT_EM_NORMAL
				i = semi + 1
				continue
			end
		end
		width += scale * _text_char_em(c)
		i += 1
	end
	return width
end

# TeX fragment parser state: `chars` and the read position.
mutable struct _TextTeX
	chars::Vector{Char}
	pos::Int
end

_text_tex_peek(t::_TextTeX) = t.pos <= length(t.chars) ? t.chars[t.pos] : nothing

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

# Skip spaces; read one argument: a `{…}` group, a command, or one character.
# Returns (width_em, tall).
function _text_tex_argument!(t::_TextTeX, text_mode::Bool)
	while (c = _text_tex_peek(t)) !== nothing && c == ' '
		t.pos += 1
	end
	c = _text_tex_peek(t)
	c === nothing && return (0.0, false)
	if c == '{'
		t.pos += 1
		return _text_tex_sequence!(t, text_mode; stop = '}')
	elseif c == '\\'
		return _text_tex_token!(t, text_mode)
	end
	t.pos += 1
	return (text_mode ? _text_char_em(c) : _text_tex_math_char_em(c), false)
end

# A `{…}` group read and thrown away (colour names, array column specs).
function _text_tex_skip_group!(t::_TextTeX)
	while (c = _text_tex_peek(t)) !== nothing && c == ' '
		t.pos += 1
	end
	_text_tex_peek(t) == '{' || return nothing
	depth = 0
	while (c = _text_tex_peek(t)) !== nothing
		t.pos += 1
		c == '{' && (depth += 1)
		c == '}' && (depth -= 1; depth == 0 && return nothing)
	end
	return nothing
end

function _text_tex_math_char_em(c::Char)
	isspace(c) && return 0.0  # TeX ignores spaces in math mode
	c in "=+<>" && return _TEXT_EM_MATH_OPERATOR
	c == '-' && return _TEXT_EM_MATH_OPERATOR
	return _text_char_em(c)
end

# One token at the current position (a command with its arguments, a group, a
# script, a character). Returns (width_em, tall).
function _text_tex_token!(t::_TextTeX, text_mode::Bool)
	c = _text_tex_peek(t)
	c === nothing && return (0.0, false)
	if c == '{'
		t.pos += 1
		return _text_tex_sequence!(t, text_mode; stop = '}')
	elseif c == '^' || c == '_'
		t.pos += 1
		w, tall = _text_tex_argument!(t, text_mode)
		return (_TEXT_SCRIPT_SCALE * w, tall)
	elseif c != '\\'
		t.pos += 1
		return (text_mode ? _text_char_em(c) : _text_tex_math_char_em(c), false)
	end
	name = _text_tex_command!(t)
	isempty(name) && return (0.0, false)
	haskey(_TEXT_TEX_SPACES, name) && return (_TEXT_TEX_SPACES[name], false)
	name in ("{", "}", "\$", "%", "#", "&", "_") && return (_TEXT_EM_NORMAL, false)
	name in _TEXT_TEX_WRAPPERS && return _text_tex_argument!(t, name in _TEXT_TEX_TEXT_MODE)
	if name in _TEXT_TEX_STACKED
		w1, _ = _text_tex_argument!(t, text_mode)
		w2, _ = _text_tex_argument!(t, text_mode)
		return (max(w1, w2) + 0.2, true)
	elseif name == "sqrt"
		if _text_tex_peek(t) == '['
			close = findnext(==(']'), t.chars, t.pos)
			close === nothing || (t.pos = close + 1)
		end
		w, _ = _text_tex_argument!(t, text_mode)
		return (w + 0.9, true)
	elseif name in ("left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr")
		# The delimiter that follows is one glyph.
		w, _ = _text_tex_argument!(t, text_mode)
		return (max(w, 0.4), name in ("Big", "bigg", "Bigg", "Bigl", "Bigr"))
	elseif name in ("color", "label", "hspace", "vspace", "phantom", "hphantom", "vphantom")
		_text_tex_skip_group!(t)
		return (0.0, false)
	elseif name == "textcolor"
		_text_tex_skip_group!(t)
		return _text_tex_argument!(t, text_mode)
	elseif name == "unicode"
		_text_tex_skip_group!(t)
		return (_TEXT_EM_NORMAL, false)
	elseif name == "begin"
		_text_tex_skip_group!(t)
		# Optional column spec of an array: `{c|c}`.
		_text_tex_peek(t) == '{' && _text_tex_skip_group!(t)
		rows = _text_tex_rows!(t, text_mode)
		width = isempty(rows) ? 0.0 : maximum(first, rows)
		return (width, length(rows) > 1 || any(last, rows))
	elseif name == "end"
		_text_tex_skip_group!(t)
		return (0.0, false)
	elseif haskey(_TEXT_TEX_SIZES, name)
		return (0.0, false)  # handled by the enclosing sequence
	elseif name in _TEXT_TEX_BIG_OPERATORS
		return (1.0, true)
	elseif name in _TEXT_TEX_OPERATORS
		return (_TEXT_EM_MATH_OPERATOR, false)
	elseif length(name) == 1
		return (_TEXT_EM_NORMAL, false)
	elseif all(isletter, name) && length(name) <= 7 && !isuppercase(name[1])
		# Greek letters and named symbols (\alpha, \infty, \partial, …).
		return (_TEXT_EM_SYMBOL, false)
	end
	return (_TEXT_EM_UNKNOWN, false)
end

# A token sequence up to `stop` (consumed) or the end. A size switch scales
# the rest of the sequence. Returns (width_em, tall).
function _text_tex_sequence!(t::_TextTeX, text_mode::Bool; stop = nothing)
	width = 0.0
	tall = false
	scale = 1.0
	while (c = _text_tex_peek(t)) !== nothing
		if stop !== nothing && c == stop
			t.pos += 1
			break
		end
		if c == '\\'
			save = t.pos
			name = _text_tex_command!(t)
			if haskey(_TEXT_TEX_SIZES, name)
				scale = _TEXT_TEX_SIZES[name]
				continue
			end
			(name == "\\" || name == "end") && (t.pos = save; break)
			t.pos = save
		elseif c == '&'
			break
		end
		w, h = _text_tex_token!(t, text_mode)
		width += scale * w
		tall |= h
	end
	return (width, tall)
end

# Rows of an environment body up to `\end{…}`: each row is the sum of its
# `&`-separated cells (1 em gap between cells). Returns [(width_em, tall), …].
function _text_tex_rows!(t::_TextTeX, text_mode::Bool)
	rows = Tuple{Float64, Bool}[]
	row_width = 0.0
	row_tall = false
	cells = 0
	while true
		w, tall = _text_tex_sequence!(t, text_mode)
		row_width += w + (cells > 0 ? 1.0 : 0.0)
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
		if name == "\\"
			continue
		elseif name == "end"
			_text_tex_skip_group!(t)
			break
		end
		t.pos = save + 1  # not a row end: skip the backslash and go on
	end
	return rows
end

# Rows (width_em, height_em) of one `$…$` expression. A top-level array (as
# `mathtext` writes multi-line labels) gives one row per array row.
function _text_tex_box(math::AbstractString)
	t = _TextTeX(collect(math), 1)
	scale = 1.0
	# Leading size switches and braces around the whole expression.
	while true
		while (c = _text_tex_peek(t)) !== nothing && (c == ' ' || c == '{')
			t.pos += 1
		end
		_text_tex_peek(t) == '\\' || break
		save = t.pos
		name = _text_tex_command!(t)
		if haskey(_TEXT_TEX_SIZES, name)
			scale = _TEXT_TEX_SIZES[name]
			continue
		elseif name == "begin"
			_text_tex_skip_group!(t)
			_text_tex_peek(t) == '{' && _text_tex_skip_group!(t)
			rows = _text_tex_rows!(t, false)
			# Anything after the environment (rare) extends the last row.
			rest, rest_tall = _text_tex_sequence!(t, false)
			isempty(rows) && push!(rows, (0.0, false))
			rows[end] = (rows[end][1] + rest, rows[end][2] || rest_tall)
			return [(scale * w, scale * (tall ? _TEXT_MATH_TALL_ROW_EM : _TEXT_MATH_ROW_EM)) for (w, tall) in rows]
		end
		t.pos = save
		break
	end
	t.pos = 1
	w, tall = _text_tex_sequence!(t, false)
	return [(scale * w, scale * (tall ? _TEXT_MATH_TALL_ROW_EM : _TEXT_MATH_ROW_EM))]
end

# Split `s` at unescaped `$` signs into (is_math, segment) pairs.
function _text_math_segments(s::AbstractString)
	segments = Tuple{Bool, String}[]
	buf = IOBuffer()
	math = false
	escaped = false
	for c in s
		if c == '$' && !escaped
			push!(segments, (math, String(take!(buf))))
			math = !math
		else
			print(buf, c)
		end
		escaped = c == '\\' && !escaped
	end
	push!(segments, (math, String(take!(buf))))
	return [(m, seg) for (m, seg) in segments if !isempty(seg)]
end

"""
	_text_extent(text, fontsize) -> (width_px, height_px)

Estimated size of `text` as plotly.js draws it in an annotation, title or
legend entry at `fontsize` px, without any frame or padding: plain text with
HTML markup (`<br>`/newline line breaks, tags stripped, `<sub>`/`<sup>` at
script size) at 1.3 em per line, and MathJax (`\$…\$`, as [`mathtext`](@ref)
writes it) with TeX commands, braces and size switches interpreted: a
top-level `array` gives one row per `\\\\`, `\\frac`/`\\sqrt` rows are taller.
Estimates err on the large side (see the calibration note above). Never
throws: unknown commands count as one glyph.
"""
function _text_extent(text::AbstractString, fontsize::Real)
	fs = (fontsize isa Real && isfinite(fontsize) && fontsize > 0) ? Float64(fontsize) : 12.0
	s = String(text)
	isempty(strip(s)) && return (0.0, 0.0)
	segments = _text_math_segments(s)
	# Lines: plain text breaks at <br>/newline; a math segment contributes
	# its rows (the first continues the current line, further rows add lines).
	lines = Tuple{Float64, Float64}[(0.0, _TEXT_PLAIN_LINE_EM)]  # (width_em, height_em)
	for (math, segment) in segments
		if math
			rows = _text_tex_box(segment)
			for (k, (w, h)) in enumerate(rows)
				k > 1 && push!(lines, (0.0, 0.0))
				lw, lh = lines[end]
				lines[end] = (lw + w, max(lh, h))
			end
		else
			parts = split(segment, _TEXT_BR_TAG)
			for (k, part) in enumerate(parts)
				k > 1 && push!(lines, (0.0, _TEXT_PLAIN_LINE_EM))
				lw, lh = lines[end]
				lines[end] = (lw + _text_plain_em(part), max(lh, _TEXT_PLAIN_LINE_EM))
			end
		end
	end
	width = maximum(first, lines)
	height = sum(last, lines)
	return (width * fs, height * fs)
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

# Estimated px width of each entry of `indices` as plotly.js lays it out
# (legend/draw.js `getLegendItemWidth`): textGap (indentation + itemwidth + 2
# itemGap) plus the trace's own `legendwidth`, else the box's `entrywidth` in
# pixels, else the label.
function _legend_entry_widths(p::Plot, box::AbstractDict, indices::Vector{Int})
	fontsize = _legend_entry_font_size(p, box)
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
		return textgap + _text_extent(name isa AbstractString ? name : string(name), fontsize)[1]
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
# `layout.width` (else 700 px, the export default) and the left/right margins
# (layout, template, plotly default 80 px). Automatic margins only shrink it,
# which the column fit absorbs through the generous label estimates.
function _legend_plot_area_width(p::Plot)
	width = _tight_real(get(p.layout.fields, :width, nothing), _TIGHT_DEFAULT_WIDTH)
	margin = _symbol_dict(get(p.layout.fields, :margin, nothing))
	side(key) = something(
		_legend_real(get(margin, key, nothing)),
		_legend_real(_legend_template_layout_value(p, (:margin, key))),
		_LEGEND_DEFAULT_MARGIN_LR,
	)
	return max(width - side(:l) - side(:r), 1.0)
end

# Width (px) a legend may take before plotly.js wraps it: the cell's share of
# the plot area for a cell legend, the plot area for a legend anchored inside
# the paper, half the figure for one anchored left or right of it.
function _legend_available_width(p::Plot, box::AbstractDict, span::Float64)
	x = _legend_real(get(box, :x, nothing))
	area = _legend_plot_area_width(p)
	if get(box, :xref, "paper") == "paper" && x !== nothing && (x < 0 || x > 1)
		return _tight_real(get(p.layout.fields, :width, nothing), _TIGHT_DEFAULT_WIDTH) / 2
	end
	return area * clamp(span, 0.0, 1.0)
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
	title_left = has_title && occursin("left", string(get(title, :side, "top")))
	title_width = title_left ? _text_extent(title_text, _legend_entry_font_size(p, box))[1] + 2 * _LEGEND_ITEM_GAP : 0.0
	available = _legend_available_width(p, box, Float64(span))
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
	# D12: above a top axis / a cell legend above the axes; a figure legend
	# above the plot area moves above the new title.
	_text_restack!(fig)
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
# the figure legends and, at the top of the figure, the figure title.
# `_text_restack!` enforces that order after every change of one of them
# (`title!`, `panel_labels!`, every legend placement). Panel titles, labels
# and cell legends are only RAISED when they would overlap what is below
# them, so a figure that fits keeps its layout and a decoration the user moved
# higher stays there; the top margin is only raised. A decoration is not
# lowered again when what was below it goes away (call `title!` /
# `panel_labels!` again for that). Room between rows is not made here: a
# raised panel title of a lower row can reach the x axis of the row above
# (the layout engine reserves that room, D12). Pixel offsets of legends are
# converted with the figure height (`layout.height`, else the 500 px export
# default).

# plotly.js layout default margin.b (px).
const _TEXT_DEFAULT_MARGIN_B = 80.0
# plotly.js annotation box around the text: borderpad 1 + borderwidth 1 on
# each side (attribute defaults).
const _TEXT_ANNOTATION_FRAME = 4.0
# The plot-area height used to convert px to paper never goes below this
# fraction of the figure height (tiny figures would otherwise send a legend
# far above the plot).
const _TEXT_MIN_PLOT_FRACTION = 0.25
# Offsets within this many px of their target are left alone (paper `y` is
# rounded to 4 digits; a second pass must not move things by fractions of a px).
const _TEXT_STACK_TOL = 0.5

function _text_margin(p::Plot, key::Symbol, default::Float64)
	margin = _symbol_dict(get(p.layout.fields, :margin, nothing))
	return something(
		_legend_real(get(margin, key, nothing)),
		_legend_real(_legend_template_layout_value(p, (:margin, key))),
		default,
	)
end

_text_figure_height(p::Plot) = _tight_real(get(p.layout.fields, :height, nothing), _TIGHT_DEFAULT_HEIGHT)

# Plot-area height (px) the stacking pass converts paper offsets with: the
# figure height minus the top margin (which holds the title band and the
# stacks once `_text_restack!` has raised it), the bottom margin and the
# container legends at the bottom (at least a quarter of the figure height).
function _text_plot_height(p::Plot)
	H = _text_figure_height(p)
	hp = H - _legend_top_margin(p) - _text_margin(p, :b, _TEXT_DEFAULT_MARGIN_B) - _text_bottom_reserved(p)
	return max(hp, _TEXT_MIN_PLOT_FRACTION * H)
end

# Estimated height (px) of legend box `legend_id` as plotly.js 2.35.2 lays it
# out (legend/draw.js computeLegendDimensions): entry rows of max(text height,
# 16) + 3 px - one per entry for a vertical legend, the longest column for a
# column legend, rows of the plot-area width for a plain horizontal legend -,
# a title on top, and the frame + itemGap padding. 0 when it lists nothing.
function _legend_box_height(p::Plot, legend_id::AbstractString)
	box = _symbol_dict(get(p.layout.fields, Symbol(legend_id), nothing))
	get(box, :visible, true) === false && return 0.0
	indices = _legend_entry_indices(p, legend_id)
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

# A legend box drawn above paper height `edge`: paper-referenced, anchored at
# its bottom edge at or above it.
function _text_box_above(box::AbstractDict, edge::Float64)
	get(box, :visible, true) === false && return false
	get(box, :yref, "paper") == "paper" || return false
	get(box, :yanchor, nothing) == "bottom" || return false
	y = _legend_real(get(box, :y, nothing))
	return y !== nothing && y >= edge - 1e-9
end

# Top x axes (`side="top"`, own or `overlaying` another axis): the x domain,
# the top of the y domain they are drawn at, and their depth (px, tick labels
# + title, `_axes_top_axis_depth`).
function _text_top_axes(p::Plot)
	out = Tuple{Tuple{Float64, Float64}, Float64, Float64}[]
	layout = p.layout
	for (key, value) in layout.fields
		occursin(r"^xaxis([2-9]|[1-9][0-9]+)?$", String(key)) || continue
		axis = _symbol_dict(value)
		get(axis, :side, "bottom") == "top" || continue
		get(axis, :visible, true) === false && continue
		ref = _legend_base_axis_ref(layout, replace(String(key), "axis" => ""), :x)
		# plotly.js domain default [0, 1] (a plain Plot sets none).
		xdom = something(_layout_axis_domain(layout, _axis_layout_key(ref, :x)), (0.0, 1.0))
		anchor = get(axis, :anchor, get(_symbol_dict(get(layout.fields, _axis_layout_key(ref, :x), nothing)), :anchor, "y"))
		(anchor isa AbstractString && startswith(anchor, "y")) || continue
		ydom = something(_layout_axis_domain(layout, _axis_layout_key(anchor, :y)), (0.0, 1.0))
		push!(out, (xdom, ydom[2], _axes_top_axis_depth(layout, axis)))
	end
	return out
end

_text_in_span(x::Real, span) = span[1] - 1e-9 <= x <= span[2] + 1e-9

# Cell legends of `p` (per-subplot legends: the ids traces carry explicitly)
# with their paper domains; none in figure-legend mode or on a plain Plot.
function _text_cell_legends(p::Plot)
	out = Tuple{String, Tuple{Float64, Float64}, Tuple{Float64, Float64}}[]
	any(t -> t isa GenericTrace && haskey(t.fields, :legend) && !_trace_is_figure_legend_entry(t), p.data) || return out
	order, ids, domains, _ = _legend_subplot_assignment(p)
	for key in order
		xdom, ydom = domains[key]
		push!(out, (_legend_id(ids[key]), xdom, ydom))
	end
	return out
end

# Figure legends: `legend1000` (legend_entry! proxies) and, without cell
# legends, `legend`.
function _text_figure_legend_ids(p::Plot, cell_legends)
	ids = String[]
	isempty(cell_legends) && push!(ids, "legend")
	any(t -> t isa GenericTrace && _trace_is_figure_legend_entry(t), p.data) && push!(ids, _FIGURE_LEGEND_ID)
	return ids
end

const _TEXT_STACK_NAME = r"^plotlysupply:(title|panel_label):([0-9]+):([0-9]+)$"

# Text height (px) of annotation `item` at its font size (else the layout's).
function _text_annotation_height(p::Plot, item::AbstractDict)
	text = get(item, :text, "")
	text isa AbstractString || return 0.0
	size = _legend_real(get(_symbol_dict(get(item, :font, nothing)), :size, nothing))
	size === nothing && (size = _legend_real(get(_symbol_dict(get(p.layout.fields, :font, nothing)), :size, nothing)))
	return _text_extent(text, something(size, Float64(_PLOTLY_DEFAULT_FONT_SIZE)))[2]
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

# px a figure title placed on the plot area (`yref="paper"`, `y=1`,
# `yanchor="bottom"`, lifted by `pad.b`, as `secondary_xaxis!` places it)
# reaches above it; 0 for any other title.
function _text_paper_title_reach(p::Plot)
	d = _text_title_dict(p)
	d === nothing && return 0.0
	get(d, :yref, "container") == "paper" || return 0.0
	get(d, :yanchor, "auto") == "bottom" || return 0.0
	y = _legend_real(get(d, :y, nothing))
	(y !== nothing && isapprox(y, 1; atol = 1e-9)) || return 0.0
	pad = _symbol_dict(get(d, :pad, nothing))
	return something(_legend_real(get(pad, :b, nothing)), 0.0) +
		_text_extent(d[:text], _legend_title_font_size(p, d))[2]
end

# px container-referenced legends reserve at the bottom of the figure
# (`:outside_bottom` figure legends).
function _text_bottom_reserved(p::Plot)
	total = 0.0
	for (key, value) in p.layout.fields
		name = String(key)
		(name == "legend" || occursin(_LEGEND_ID_PATTERN, name)) || continue
		box = _symbol_dict(value)
		get(box, :yref, "paper") == "container" || continue
		y = _legend_real(get(box, :y, nothing))
		(y !== nothing && y < 0.5) || continue
		total = max(total, _legend_box_height(p, name))
	end
	return total
end

# A centred figure legend above the plot area (`:outside_top`), or one this
# pass already moved to the top of the figure (container-referenced, anchored
# at its top edge in the upper half). Other placements are the user's.
function _text_top_figure_legend(box::AbstractDict)
	get(box, :visible, true) === false && return false
	get(box, :xref, "paper") == "paper" || return false
	x = _legend_real(get(box, :x, nothing))
	(x !== nothing && isapprox(x, 0.5; atol = 1e-9) && get(box, :xanchor, nothing) == "center") || return false
	_text_box_above(box, 1.0) && return true
	y = _legend_real(get(box, :y, nothing))
	return get(box, :yref, "paper") == "container" && get(box, :yanchor, nothing) == "top" &&
		y !== nothing && y > 0.5
end

"""
	_text_restack!(fig) -> Bool

Enforce the stacking order above the axes (see the note above) on a `Plot`,
`SyncPlot`'s plot, staged figure or `SubplotFigure`. Layout only:

- panel title and outside top panel label annotations
  (`"plotlysupply:title:r:c"`, `"plotlysupply:panel_label:r:c"`,
  `yanchor="bottom"`) are raised (`yshift`) above a top x axis and a cell
  legend drawn above the same axes; a cell legend above its axes is raised
  (`y`) above a top x axis;
- when something is stacked above the top row, a centred figure legend above
  the plot area (`:outside_top`) moves to the top of the figure, under the
  figure title: container-referenced, `yanchor="top"`, at `1 - band / H`
  (`band` = the title's `pad.t` + text + 4 px; `H` = `layout.height`, else
  the 500 px export default). plotly.js places a legend above the plot area
  by pushing the top margin to the larger of its pushers, which let it
  overlap the panel titles (G38) and, once moved higher, the figure title;
  a container legend instead reserves its own band;
- `layout.margin.t` is raised (never lowered) to hold the title band, the
  top legends, `_LEGEND_TITLE_GAP` and the stacks.

Nothing is lowered and a decoration the user placed elsewhere is left alone,
so the pass is idempotent. Returns whether anything changed.

With `clearance = true` (every legend placement, `_legend_stack!`), a figure
with nothing stacked above the top row gets `_legend_title_clearance!`
instead (the figure title keeps clear of a legend pushed above the plot
area); when something is stacked, the margin computed here already holds the
title, so a `title.pad.b` that clearance wrote is removed.
"""
function _text_restack!(fig; clearance::Bool = false)
	p = _cmn_plot(fig)
	changed, managed = _text_restack_pass!(p)
	clearance && !managed && _legend_title_clearance!(p)
	return changed
end

# The pass of `_text_restack!`: (whether anything changed, whether something
# is stacked above the top row so that the top margin is computed here).
function _text_restack_pass!(p::Plot)
	items = get(p.layout.fields, :annotations, nothing)
	stack_items = Dict{Tuple{Int, Int}, Vector{Int}}()
	if items isa AbstractVector
		for (index, item) in enumerate(items)
			name = _cmn_item_name(item)
			name isa AbstractString || continue
			m = match(_TEXT_STACK_NAME, name)
			m === nothing && continue
			_cmn_mapping_get(item, :yanchor) == "bottom" || continue
			_cmn_mapping_get(item, :yref) == "paper" || continue
			push!(get!(stack_items, (parse(Int, m[2]), parse(Int, m[3])), Int[]), index)
		end
	end
	cell_legends = _text_cell_legends(p)
	figure_ids = filter(_text_figure_legend_ids(p, cell_legends)) do id
		_text_top_figure_legend(_symbol_dict(get(p.layout.fields, Symbol(id), nothing)))
	end
	cells_above = filter(cell_legends) do (id, _, ydom)
		_text_box_above(_symbol_dict(get(p.layout.fields, Symbol(id), nothing)), ydom[2])
	end
	top_axes = _text_top_axes(p)
	(isempty(stack_items) && isempty(figure_ids) && isempty(cells_above) && isempty(top_axes)) && return (false, false)

	changed = false
	axis_depth(x, edge) = maximum(
		(depth for (xdom, top, depth) in top_axes if isapprox(top, edge; atol = 1e-6) && _text_in_span(x, xdom));
		init = 0.0,
	)
	hp = _text_plot_height(p)
	reach = 0.0   # px the stacks reach above paper y = 1

	# Cell legends above their axes: px offset above the axes (at least the
	# depth of a top x axis + gap; placed after the margin is known) and top.
	legend_tops = Tuple{Tuple{Float64, Float64}, Float64, Float64}[]  # (xdom, edge, px above edge)
	legend_raises = Tuple{Symbol, Float64, Float64}[]  # (key, edge, px offset)
	for (id, xdom, ydom) in cells_above
		key = Symbol(id)
		box = _symbol_dict(p.layout.fields[key])
		height = _legend_box_height(p, id)
		height > 0 || continue
		edge = ydom[2]
		x = something(_legend_real(get(box, :x, nothing)), (xdom[1] + xdom[2]) / 2)
		depth = axis_depth(clamp(x, xdom[1], xdom[2]), edge)
		offset = (box[:y] - edge) * hp
		if depth > 0
			# the final paper `y` is set once the margin is known
			push!(legend_raises, (key, edge, depth + _TEXT_PANEL_GAP))
			offset = max(offset, depth + _TEXT_PANEL_GAP)
		end
		push!(legend_tops, (xdom, edge, offset + height))
		reach = max(reach, (edge - 1) * hp + offset + height)
	end

	# Panel titles and outside top panel labels: above the axis and legends.
	if !isempty(stack_items)
		updated = Any[item for item in items]
		raised = false
		for cell in sort!(collect(keys(stack_items)))
			indices = stack_items[cell]
			entries = [_symbol_dict(updated[index]) for index in indices]
			floor = 0.0
			for entry in entries
				edge = _legend_real(get(entry, :y, nothing))
				x = _legend_real(get(entry, :x, nothing))
				(edge === nothing || x === nothing) && continue
				below = axis_depth(x, edge)
				for (xdom, ledge, top) in legend_tops
					(isapprox(ledge, edge; atol = 1e-9) && _text_in_span(x, xdom)) && (below = max(below, top))
				end
				floor = max(floor, below)
			end
			shift_floor = floor + _TEXT_PANEL_GAP
			for (index, entry) in zip(indices, entries)
				edge = _legend_real(get(entry, :y, nothing))
				edge === nothing && continue
				shift = something(_legend_real(get(entry, :yshift, nothing)), 0.0)
				if floor > 0 && shift < shift_floor - _TEXT_STACK_TOL
					shift = shift_floor
					entry[:yshift] = _text_number(shift)
					updated[index] = attr(; entry...)
					raised = true
				end
				reach = max(reach, (edge - 1) * hp + shift + _text_annotation_height(p, entry) + _TEXT_ANNOTATION_FRAME)
			end
		end
		if raised
			p.layout.fields[:annotations] = updated
			changed = true
		end
	end
	for (_, top, depth) in top_axes
		reach = max(reach, (top - 1) * hp + depth)
	end
	reach = max(reach, _text_paper_title_reach(p))
	if reach <= 0
		changed |= _text_raise_cell_legends!(p, legend_raises)
		return (changed, false)
	end
	# A `title.pad.b` from `_legend_title_clearance` (it would reserve a band
	# as tall as the old top margin above everything placed here) goes.
	title = _text_title_dict(p)
	if title !== nothing && get(title, :automargin, nothing) === true
		pad = _symbol_dict(get(title, :pad, nothing))
		pad_b = _legend_real(get(pad, :b, nothing))
		if pad_b !== nothing && pad_b == _legend_title_clearance_pad(p, title)
			delete!(pad, :b)
			title[:pad] = attr(; pad...)
			p.layout.fields[:title] = attr(; title...)
			changed = true
		end
	end

	# Figure legends at the top of the figure, under the title band.
	H = _text_figure_height(p)
	band = _text_title_band(p)
	offset = band > 0 ? band : Float64(_TEXT_PANEL_GAP)
	stacked = false
	for id in figure_ids
		key = Symbol(id)
		box = _symbol_dict(p.layout.fields[key])
		height = _legend_box_height(p, id)
		height > 0 || continue
		placed = copy(box)
		placed[:yref] = "container"
		placed[:y] = round(1 - offset / H; digits = 4)
		placed[:yanchor] = "top"
		if placed != box
			p.layout.fields[key] = attr(; placed...)
			changed = true
		end
		offset += height + _TEXT_PANEL_GAP
		stacked = true
	end
	# Without a title the stacks keep `_TEXT_PANEL_GAP` from the figure edge.
	needed = ceil(stacked ? offset - _TEXT_PANEL_GAP + _LEGEND_TITLE_GAP + reach : max(band, _TEXT_PANEL_GAP) + reach)
	if needed > _legend_top_margin(p) + _TEXT_STACK_TOL
		margin = _symbol_dict(get(p.layout.fields, :margin, nothing))
		margin[:t] = needed
		p.layout.fields[:margin] = attr(; margin...)
		changed = true
	end
	changed |= _text_raise_cell_legends!(p, legend_raises)
	return (changed, true)
end

# Raise cell legends above their axes to at least `offset` px above paper
# `edge` (`raises` from `_text_restack_pass!`), converted with the plot-area height
# of the final margins (`_text_plot_height`, also used to read the offsets
# back, so a second pass changes nothing).
function _text_raise_cell_legends!(p::Plot, raises)
	isempty(raises) && return false
	hp = _text_plot_height(p)
	changed = false
	for (key, edge, offset) in raises
		box = _symbol_dict(p.layout.fields[key])
		(box[:y] - edge) * hp < offset - _TEXT_STACK_TOL || continue
		y = round(edge + offset / hp; digits = 4)
		box[:y] = y
		p.layout.fields[key] = attr(; box...)
		changed = true
	end
	return changed
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
  When a legend sits above the plot area (`set_legend!(…; position =
  :outside_top)`), `title.pad.b` is also set so the legend is laid out below
  the title (see [`set_legend!`](@ref)). Existing title styling (font
  family/colour) is kept.
- Panel title: an annotation named `"plotlysupply:title:<row>:<col>"` placed
  just above the cell's axes (`x` = left edge / centre / right edge of the cell
  per `align`, `yanchor="bottom"`, 4 px gap). Calling it again replaces it; it
  also replaces a centred `subplot_titles`/`column_titles` annotation of that
  cell. [`set_fonts!`](@ref) styles it as a title. A left/right-aligned panel
  title moves an outside [`panel_labels!`](@ref) label at the same top corner
  beside the corner (outside the axes), so they do not overlap.

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
	_text_restack!(fig)   # D12 stacking, as for panel titles
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
  4 px from both edges. When the cell has a panel title ([`title!`](@ref)
  with `row`/`col`) aligned to the same corner (`align = :left` for
  `:topleft`, `:right` for `:topright`), an outside label moves beside the
  corner, outside the axes on the title's line ("(a) Title"), so the two
  never overlap; centred titles (also `subplot_titles`) leave it in place.
- `bold::Bool = false`: bold label (`<b>`, or `\\textbf` for math labels).
- `fontsize::Real = 0`: font size in px (0 = Plotly default).
- `cells`: `:all` or a vector of `(row, col)` tuples (SubplotFigure only;
  labels are assigned in the given order).

Returns `nothing` for a `Plot`/`SyncPlot`, the `SubplotFigure` otherwise.

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
	show = nothing,
)
	who = "panel_labels!"
	_text_reject_show(show, who)
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
	show = nothing,
)
	_text_reject_show(show, "panel_labels!")
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
