using Test, PlotlySupply

# Restore the package-wide mathtext settings after a block that changes them.
function _with_mathtext_settings(f, enabled::Bool; size::AbstractString = "")
	previous = get_default_mathtext()
	set_default_mathtext!(enabled; size = size)
	try
		return f()
	finally
		set_default_mathtext!(previous.enabled; size = previous.size)
	end
end

@testset "sci mathtext: mixed text + math labels" begin
	@testset "spec examples" begin
		@test mathtext("(a) Mesh study, \$\\lambda=10^8\$") ==
			"\$\\text{(a) Mesh study, }\\lambda=10^8\$"
		@test mathtext("Time \$t\$ (s)") == "\$\\text{Time }t\\text{ (s)}\$"
		@test mathtext("line one\nline two") == "line one<br>line two"
		@test mathtext("5% done") == "5% done"
		@test mathtext("Error 5% \$\\epsilon\$") == "\$\\text{Error 5% }\\epsilon\$"
		@test_throws ArgumentError mathtext("cost \$5")
		@test mathtext("") == ""
		@test mathtext("   ") == "   "
	end

	@testset "plain labels are untouched except newlines and escaped dollars" begin
		for s in (
			"Plain <b>bold</b> x<sup>2</sup> H<sub>2</sub>O",
			"a<br>b",
			"<span style=\"color:red\">red</span> &amp; &lt; &#36; &deg;",
			"5% & #3 a_b x^2 ~ {set} }{ unicode λ é 温度",
			"\\alpha without math",
			"C:\\temp\\file",
			"x < y > z",
		)
			@test mathtext(s) == s
		end
		@test mathtext("a\r\nb\rc\nd") == "a<br>b<br>c<br>d"
		@test mathtext("trailing\n") == "trailing<br>"
		# A literal dollar becomes the entity plotly decodes (two raw `$` would be
		# taken for math by plotly and everything outside them dropped).
		@test mathtext("cost \\\$5") == "cost &#36;5"
		@test mathtext("\\\$5 to \\\$10") == "&#36;5 to &#36;10"
		# Backslash parity: an odd run escapes, the escaping backslash is removed.
		@test mathtext("a\\\\\\\$b") == "a\\\\&#36;b"
		@test mathtext("\\\\") == "\\\\"
	end

	@testset "unescaped dollar detection uses backslash parity" begin
		# `\\$x$`: the even backslash run leaves both dollars unescaped.
		@test mathtext("a\\\\\$x\$") == "\$\\text{a}\\backslash\\backslash x\$"
		@test_throws ArgumentError mathtext("a\\\\\$x")
		# `\$x$` has one unescaped dollar.
		@test_throws ArgumentError mathtext("\\\$x\$")
	end

	@testset "unbalanced dollars throw" begin
		for s in ("\$x", "a \$x\$ b \$y", "\$a\$\$", "\$\$a\$", "\$\$a", "x\$")
			err = try
				mathtext(s)
				nothing
			catch e
				e
			end
			@test err isa ArgumentError
			@test startswith(err.msg, "mathtext:")
		end
		@test occursin("unbalanced \$", sprint(showerror, try
			mathtext("price \$5")
		catch e
			e
		end))
	end

	@testset "whole-math labels are unchanged" begin
		for s in (
			"\$x\$",
			"\$\\alpha^2 + \\beta_1\$",
			"\$\$\\sum_i x_i^2\$\$",
			"\$\\text{whole text}\$",
			"\$\\text{5% & #}x\$",
			"\$\\left(\\frac{a}{b}\\right)\$",
			"\$\\begin{array}{c}a\\\\b\\end{array}\$",
			"\$\\{1, 2\\}\$",
			"\$\\%\$",
			"\$ \$",
		)
			@test mathtext(s) == s
		end
	end

	@testset "LaTeXString and SubString inputs" begin
		@test mathtext(L"\alpha^2") == "\$\\alpha^2\$"
		@test mathtext(L"Area $A$ (m)") == "\$\\text{Area }A\\text{ (m)}\$"
		@test mathtext(SubString("xx Time \$t\$", 4)) == "\$\\text{Time }t\$"
		@test mathtext(L"\alpha") isa String
		@test PlotlySupply._label(L"\beta") == "\$\\beta\$"
		@test PlotlySupply._label(SubString("ab", 1, 1)) == "a"
		# A literal dollar inside LaTeXString math cannot be typeset by plotly.
		@test_throws ArgumentError mathtext(L"\$5")
	end

	@testset "text segments render literally" begin
		@test mathtext("Err 5% & #3 a_b x^2 ~ {set} \$\\alpha\$") ==
			"\$\\text{Err 5% & #3 a_b x^2 ~ {set} }\\alpha\$"
		@test mathtext("Lamé é 温度 \$\\lambda\$") == "\$\\text{Lamé é 温度 }\\lambda\$"
		# Unbalanced braces move out of \text{} as math-mode \{ and \}.
		@test mathtext("open { brace \$x\$") == "\$\\text{open }\\{\\text{ brace }x\$"
		@test mathtext("close } brace \$x\$") == "\$\\text{close }\\}\\text{ brace }x\$"
		@test mathtext("}{ \$x\$") == "\$\\}\\{\\text{ }x\$"
		@test mathtext("{a} } {b \$x\$") == "\$\\text{{a} }\\}\\text{ }\\{\\text{b }x\$"
		# Backslashes print literally (MathJax's \text would otherwise eat `\{`,
		# `\\` and `\(`).
		@test mathtext("C:\\temp \$x\$") == "\$\\text{C:}\\backslash\\text{temp }x\$"
		@test mathtext("f\\(x\\) \$y\$") == "\$\\text{f}\\backslash\\text{(x}\\backslash\\text{) }y\$"
		@test mathtext("\$x\$ ends \\") == "\$x\\text{ ends }\\backslash\$"
		# `\$` in text is a literal dollar sign (rendered with \unicode).
		@test mathtext("cost \\\$5 \$\\gamma\$") == "\$\\text{cost }\\unicode{36}\\text{5 }\\gamma\$"
		# `<` and `>` cannot sit inside \text{} (plotly rewrites them to \lt/\gt).
		@test mathtext("a < b, \$x\$ > c") == "\$\\text{a }{<}\\text{ b, }x\\text{ }{>}\\text{ c}\$"
		@test mathtext("\\\$x\$y\$") == "\$\\unicode{36}\\text{x}y\$"
		@test mathtext("\\ \$x\$") == "\$\\backslash\\text{ }x\$"
		# A control word is never merged with a following letter.
		@test mathtext("\\\\\$z\$") == "\$\\backslash\\backslash z\$"
		@test mathtext("\$\\alpha\$\$z\$") == "\$\\alpha z\$"
	end

	@testset "HTML entities and tags in mixed labels" begin
		@test mathtext("a&amp;b &lt; c \$x\$") == "\$\\text{a&b }{<}\\text{ c }x\$"
		@test mathtext("20&deg;C &mu; &times; \$x\$") == "\$\\text{20°C μ × }x\$"
		@test mathtext("&#36;5 &#x3b1; \$x\$") == "\$\\unicode{36}\\text{5 α }x\$"
		@test mathtext("&#123; \$x\$") == "\$\\{\\text{ }x\$"
		@test mathtext("&#92; \$x\$") == "\$\\backslash\\text{ }x\$"
		# Unknown or invalid entities stay as typed.
		@test mathtext("&foo; &#0; &#xD800; &#99999999999; \$x\$") ==
			"\$\\text{&foo; &#0; &#xD800; &#99999999999; }x\$"
		# Literal text that plotly would turn into \lt / \gt is broken up.
		@test mathtext("&amp;lt; \$x\$") == "\$\\&\\text{lt; }x\$"
		# <br> variants start a new line; unknown tags are literal text.
		for br in ("<br>", "<BR>", "<br/>", "<br />", "</br>")
			@test mathtext("a$(br)b \$x\$") == "\$\\begin{array}{c}{\\text{a}}\\\\{\\text{b }x}\\end{array}\$"
		end
		@test mathtext("<foo> \$x\$") == "\${<}\\text{foo}{>}\\text{ }x\$"
		@test mathtext("x<=5 and y>3 \$z\$") == "\$\\text{x}{<}\\text{=5 and y}{>}\\text{3 }z\$"
		# Other plotly HTML tags cannot be combined with MathJax.
		for tag in ("<b>bold</b>", "<i>it</i>", "x<sup>2</sup>", "H<sub>2</sub>", "<span>s</span>",
			"<a href=\"u\">l</a>", "<em>e</em>", "<s>s</s>", "<u>u</u>", "<B>b</B>", "<b/>")
			err = try
				mathtext("$(tag) \$x\$")
				nothing
			catch e
				e
			end
			@test err isa ArgumentError
			@test occursin("HTML tag", err.msg)
		end
		# The same tags in plain labels pass through.
		@test mathtext("<b>bold</b> x<sup>2</sup>") == "<b>bold</b> x<sup>2</sup>"
	end

	@testset "math segments: matplotlib macros, comments, validation" begin
		@test mathtext("\$\\mathdefault{10^{3}}\$") == "\${10^{3}}\$"
		@test mathtext("\$\\mathregular{abc}\$ text") == "\$\\mathrm{abc}\\text{ text}\$"
		@test mathtext("\$20\\degree\$C") == "\$20{^\\circ}\\text{C}\$"
		@test mathtext("\$5\\,\\AA\$") == "\$5\\,\\mathring{\\mathrm{A}}\$"
		@test mathtext("\$\\mathdefault x\$") == "\$ x\$"
		# Only whole control words are rewritten, and not inside raw arguments.
		@test mathtext("\$\\mathdefaultx \\degrees\$") == "\$\\mathdefaultx \\degrees\$"
		@test mathtext("\$\\text{\\degree}\$") == "\$\\text{\\degree}\$"
		# `\\` followed by letters is a line break, not a macro.
		@test mathtext("\$a\\\\degree\$") == "\$a\\\\degree\$"
		# A raw `%` would comment out the rest of the label; a raw `#` blanks it.
		@test mathtext("\$50%\$ rate") == "\$50\\%\\text{ rate}\$"
		@test mathtext("\$a#b\$") == "\$a\\#b\$"
		@test mathtext("\$\\text{5% #}\\textbf{9%}x%\$") == "\$\\text{5% #}\\textbf{9%}x\\%\$"
		@test mathtext("\$\\color{#ff0000}{x}\$") == "\$\\color{#ff0000}{x}\$"
		@test mathtext("\$\\newcommand{\\f}[1]{#1^2}\\f{x}\$") == "\$\\newcommand{\\f}[1]{#1^2}\\f{x}\$"
		@test mathtext("\$\\%\\#\$") == "\$\\%\\#\$"
		# Literal `\$` inside math blanks the label in plotly.
		for s in ("\$\\\$5\$", "Cost \$\\text{\\\$5}\$", "\$a\\\$\$")
			err = try
				mathtext(s)
				nothing
			catch e
				e
			end
			@test err isa ArgumentError
			@test occursin("\\unicode{36}", err.msg)
		end
		# Structural errors that MathJax would render as a blank label.
		for s in ("\$x}\$", "\$\\frac{a}{b\$", "a \${x\$", "\$\\left( x\$", "\$x\\right)\$",
			"\$\\begin{array}{c}a\$", "\$a\\end{array}\$")
			@test_throws ArgumentError mathtext(s)
		end
		@test mathtext("\$\\left\\{ x \\right.\$") == "\$\\left\\{ x \\right.\$"
		@test mathtext("\$\\leftarrow \\rightarrow\$") == "\$\\leftarrow \\rightarrow\$"
	end

	@testset "switches inside a math segment do not restyle the following text" begin
		@test mathtext("\$\\bf X\$ after") == "\${\\bf X}\\text{ after}\$"
		@test mathtext("\$\\large x\$ after") == "\${\\large x}\\text{ after}\$"
		@test mathtext("\$a \\over b\$ c") == "\${a \\over b}\\text{ c}\$"
		@test mathtext("\${\\bf X}\$ after") == "\${\\bf X}\\text{ after}\$"
		@test mathtext("before \$\\mathbf{X}\$") == "\$\\text{before }\\mathbf{X}\$"
		# A whole-math label keeps its switch unwrapped.
		@test mathtext("\$\\bf X\$") == "\$\\bf X\$"
		# Display segments inside mixed labels keep display style locally.
		@test mathtext("sum \$\$\\sum_i x_i\$\$ end") == "\$\\text{sum }{\\displaystyle \\sum_i x_i}\\text{ end}\$"
		# Adjacent math segments are separated so control words do not merge.
		@test mathtext("\$\\alpha\$\$x\$") == "\$\\alpha x\$"
		@test mathtext("\$a\$\$b\$") == "\$a b\$"
	end

	@testset "multi-line labels become an array" begin
		@test mathtext("(a) Mixed strain\n\$-u_2(0,1)=0.17\$") ==
			"\$\\begin{array}{c}{\\text{(a) Mixed strain}}\\\\{-u_2(0,1)=0.17}\\end{array}\$"
		@test mathtext("a\n\$x\$\nccc"; align = :l) ==
			"\$\\begin{array}{l}{\\text{a}}\\\\{x}\\\\{\\text{ccc}}\\end{array}\$"
		@test mathtext("a\n\$x\$"; align = :right) == "\$\\begin{array}{r}{\\text{a}}\\\\{x}\\end{array}\$"
		@test mathtext("a\n\$x\$"; align = :left) == mathtext("a\n\$x\$"; align = :l)
		@test mathtext("a\n\$x\$"; align = :center) == mathtext("a\n\$x\$")
		@test mathtext("a\r\n\$x\$\rb") == "\$\\begin{array}{c}{\\text{a}}\\\\{x}\\\\{\\text{b}}\\end{array}\$"
		# Newlines inside math split the math across rows; a whole-math label too.
		@test mathtext("\$a\nb\$") == "\$\\begin{array}{c}{a}\\\\{b}\\end{array}\$"
		@test mathtext("\$x\$\n") == "\$\\begin{array}{c}{x}\\\\{}\\end{array}\$"
		# Rows are braced so a row starting with `[` is not read as `\\[dim]`.
		@test mathtext("\$x\$\n\$[0,1]\$") == "\$\\begin{array}{c}{x}\\\\{[0,1]}\\end{array}\$"
		# A switch in one row does not leak into the next.
		@test mathtext("\$\\bf a\$\nb \$c\$") == "\$\\begin{array}{c}{{\\bf a}}\\\\{\\text{b }c}\\end{array}\$"
		# A line break inside a braced math group cannot be honoured.
		@test_throws ArgumentError mathtext("\$\\frac{a\n}{b}\$")
		@test_throws ArgumentError mathtext("\$a\\\nb\$")
		@test_throws ArgumentError mathtext("\$\\left(a\nb\\right)\$")
		# Plain multi-line labels stay plain.
		@test mathtext("a\nb"; align = :l) == "a<br>b"
	end

	@testset "size prefix" begin
		@test mathtext("Time \$t\$"; size = "large") == "\$\\large{\\text{Time }t}\$"
		@test mathtext("Time \$t\$"; size = "\\Large") == "\$\\Large{\\text{Time }t}\$"
		@test mathtext("\$x\$"; size = "\\large") == "\$\\large{x}\$"
		@test mathtext("\$\$x\$\$"; size = "\\large") == "\$\$\\large{x}\$\$"
		@test mathtext("a\n\$x\$"; size = "\\small") ==
			"\$\\small{\\begin{array}{c}{\\text{a}}\\\\{x}\\end{array}}\$"
		# Plain labels are not resized; math that already starts with a size
		# switch is not prefixed again (so the pipeline is idempotent).
		@test mathtext("plain"; size = "\\large") == "plain"
		@test mathtext("\$\\small{x}\$"; size = "\\large") == "\$\\small{x}\$"
		@test mathtext(mathtext("Time \$t\$"; size = "\\large"); size = "\\large") ==
			"\$\\large{\\text{Time }t}\$"
		for size in ("\\tiny", "\\Tiny", "\\scriptsize", "\\small", "\\normalsize",
			"\\large", "\\Large", "\\LARGE", "\\huge", "\\Huge", " \\huge ")
			@test startswith(mathtext("\$x\$"; size = size), "\$" * strip(size) * "{")
		end
		for size in ("\\footnotesize", "big", "\\large{", "12pt", "\\\\large")
			@test_throws ArgumentError mathtext("\$x\$"; size = size)
		end
	end

	@testset "align validation" begin
		@test_throws ArgumentError mathtext("x"; align = :middle)
		@test_throws ArgumentError PlotlySupply._label("x"; align = :top)
		@test_throws ArgumentError _with_mathtext_settings(() -> PlotlySupply._label("x"; align = :bogus), false)
	end

	@testset "invalid UTF-8 is rejected" begin
		bad = String(UInt8[0x61, 0xff, 0x24, 0x78, 0x24])
		@test_throws ArgumentError mathtext(bad)
		@test_throws ArgumentError PlotlySupply._label(bad)
		@test_throws ArgumentError PlotlySupply._label_plain(bad)
	end

	@testset "_label is a fixed point" begin
		corpus = [
			"(a) Mesh study, \$\\lambda=10^8\$", "plain\nline", "cost \\\$5 and \\\$10",
			"a < b, \$x\$ > c", "open { \$x\$", "C:\\temp \$x\$", "\$50%\$ rate",
			"(a) Mixed strain\n\$-u_2(0,1)=0.17\$", "\$\\bf X\$ after", "&amp;lt; \$x\$",
			"sum \$\$\\sum_i\$\$ end", "\$\\mathdefault{10^{3}}\$", "line1<br>line2 \$x\$",
			"cost \\\$5 \$\\gamma\$", "Lamé 温度 \$\\lambda\$", "\$x\$\n\$[0,1]\$",
		]
		for s in corpus
			once = PlotlySupply._label(s)
			@test PlotlySupply._label(once) == once
			@test PlotlySupply._label(once; align = :l) == PlotlySupply._label(once)
		end
		_with_mathtext_settings(true; size = "\\large") do
			for s in corpus
				once = PlotlySupply._label(s)
				@test PlotlySupply._label(once) == once
			end
		end
	end

	@testset "default settings" begin
		@test get_default_mathtext() == (enabled = true, size = "", font = "", inherit_text_font = false)
		_with_mathtext_settings(true; size = "large") do
			@test get_default_mathtext() == (enabled = true, size = "\\large", font = "", inherit_text_font = false)
			@test PlotlySupply._label("Time \$t\$") == "\$\\large{\\text{Time }t}\$"
			@test mathtext("\$x\$") == "\$\\large{x}\$"
			@test mathtext("\$x\$"; size = "") == "\$x\$"
			@test PlotlySupply._label("plain") == "plain"
		end
		@test get_default_mathtext() == (enabled = true, size = "", font = "", inherit_text_font = false)
		# Validation happens before the settings change.
		@test_throws ArgumentError set_default_mathtext!(true; size = "\\footnotesize")
		@test get_default_mathtext() == (enabled = true, size = "", font = "", inherit_text_font = false)
		# Return value and replacement semantics.
		try
			@test set_default_mathtext!(false; size = "\\small") == (enabled = false, size = "\\small", font = "", inherit_text_font = false)
			@test set_default_mathtext!() == (enabled = true, size = "", font = "", inherit_text_font = false)
		finally
			set_default_mathtext!()
		end
		# Disabled: only newlines change, so 1.x labels pass through.
		_with_mathtext_settings(false) do
			@test PlotlySupply._label("Time \$t\$ (s)") == "Time \$t\$ (s)"
			@test PlotlySupply._label("price \$5") == "price \$5"
			@test PlotlySupply._label("a\nb \\\$") == "a<br>b \\\$"
			@test PlotlySupply._label_plain("Time \$t\$\n") == "Time \$t\$<br>"
			# mathtext itself still converts.
			@test mathtext("Time \$t\$") == "\$\\text{Time }t\$"
		end
		# Enabled (the default): an unbalanced label is an error, not garbage.
		@test_throws ArgumentError PlotlySupply._label("price \$5")
	end

	@testset "_label_plain for text plotly draws without MathJax" begin
		P = PlotlySupply._label_plain
		@test P("Height \$h\$ (m)") == "Height h (m)"
		@test P("\$\\alpha^2 + \\beta_{1}\$") == "α<sup>2</sup> + β<sub>1</sub>"
		@test P("\$10^{-3}\\,\\mathrm{s}^{-1}\$") == "10<sup>−3</sup>\u2009s<sup>−1</sup>"
		@test P("\$\\frac{a+b}{2}\$, \$\\frac{1}{2}\$, \$\\sqrt{x}\$, \$\\sqrt[3]{8}\$, \$\\sqrt[n]{y+1}\$") ==
			"(a+b)/2, 1/2, √x, ∛8, <sup>n</sup>√(y+1)"
		@test P("\$\\text{Re}\\{z\\}\$ cost \\\$5") == "Re{z} cost \$5"
		@test P("\$\\hat{x}\$ \$\\overline{ab}\$ \$\\vec{vw}\$") == "x\u0302 a\u0305b\u0305 vw"
		@test P("\$20\\degree\$C, \$\\mathdefault{10^{3}}\$, \$\\mathregular{abc}\$") == "20°C, 10<sup>3</sup>, abc"
		@test P("\$\\mathbb{R}^n\$ \$\\left(\\frac{1}{2}\\right)\$ \$\\left.x\\right|_0^1\$") ==
			"ℝ<sup>n</sup> (1/2) x|<sub>0</sub><sup>1</sup>"
		@test P("\$\\sin\\theta\$ \$\\sin(x)\$ \$\\log x\$") == "sin θ sin(x) log x"
		@test P("\$\\unicode{36}\\unicode{x3B1}\$ \$\\foo{x}\$ \$\\bar\$") == "\$α \\foo{x} "
		@test P("\$\\not= \\color{red}{x} \\textcolor{blue}{y} \\bf z\$") == "=\u0338 x y  z"
		@test P("\$x'\$ \$a \\leq b\$ \$\\{1,2\\}\$ \$a~b\$ \$x}\$") == "x′ a ≤ b {1,2} a\u00a0b x}"
		@test P("two\n\$x\$ lines\r\n") == "two<br>x lines<br>"
		@test P("\$a\\\\b\$") == "a<br>b"
		@test P("\$\\begin{array}{c}a\\\\b\\end{array}\$") == "a<br>b"
		@test P("plain <b>bold</b> &amp;") == "plain <b>bold</b> &amp;"
		@test P(L"\alpha") == "α"
		@test P("") == ""
		# The same $ rules as mathtext.
		@test_throws ArgumentError P("price \$5")
		# Plain labels keep a raw dollar (no MathJax there, entities undecoded in WebGL).
		@test P("cost \\\$5 and \\\$10") == "cost \$5 and \$10"
	end
end

# Exports through the Electron/MathJax export window. Skipped when no display
# backend is available (as in runtests.jl); MathJax itself is loaded from its CDN.
# Returns the MathJax glyphs the exported title uses, as "<code point>" strings of
# the upright text font (MAIN) plus the full ids. Glyph `<defs>` accumulate in
# the shared export window, so only `<use>` references are counted.
function _mathtext_svg_glyph_uses(label::AbstractString)
	fig = Plot(scatter(x = [1, 2], y = [1, 2]), Layout(title = attr(text = label)))
	svg = String(savefig(fig; format = "svg", width = 600, height = 300))
	ids = Set(m.captures[1] for m in eachmatch(r"<use[^>]*href=\"#([A-Z]+-[0-9A-F]+)\"", svg))
	main = Set(last(split(id, '-')) for id in ids if occursin(r"^[A-Z]*MAIN-", id))
	return (main = main, ids = ids)
end

@testset "sci mathtext: MathJax render of converted labels (SVG glyphs)" begin
	mixed = "(a) Mesh study, \$\\lambda=10^8\$"
	result = try
		(
			raw = _mathtext_svg_glyph_uses(mixed),
			converted = _mathtext_svg_glyph_uses(mathtext(mixed)),
			literals = _mathtext_svg_glyph_uses(mathtext("a < b {c \\\$5 C:\\x \$y\$")),
			raw_lt = _mathtext_svg_glyph_uses("\$\\text{a < b}\\;y\$"),
		)
	catch err
		message = sprint(showerror, err)
		@test occursin("ElectronCall", message) || occursin("Plotly.js", message) ||
			occursin("Electron", message)
		nothing
	end
	if result !== nothing
		if isempty(result.raw.ids)
			# MathJax could not be loaded (offline): nothing was typeset.
			@test_skip "MathJax typeset the exported labels"
		else
			# Plotly alone typesets only `\lambda=10^8` and drops "(a) Mesh study,":
			# "(" = 0x28 and "M" = 0x4D are never drawn.
			@test !("28" in result.raw.main)
			@test !("4D" in result.raw.main)
			@test "3D" in result.raw.main
			# After mathtext the text is typeset too, along with the math.
			for code in ("28", "61", "29", "4D", "65", "73", "68", "74", "75", "64", "79", "2C", "3D", "31", "30", "38")
				@test code in result.converted.main
			end
			# math italic lambda (Latin-Modern or TeX font naming)
			@test any(id -> endswith(id, "-1D706") || id == "MJMATHI-3BB", result.converted.ids)
			# `<`, `{`, `$` and `\` in text print as glyphs ...
			for code in ("3C", "7B", "24", "61", "62", "63", "35", "43", "3A", "78")
				@test code in result.literals.main
			end
			@test "2216" in result.literals.main || "5C" in result.literals.main
			# ... and no stray "\lt": an "l" or "t" would come from a printed "\lt",
			# which is what a raw `<` inside \text{} produces.
			@test !("6C" in result.literals.main)
			@test !("74" in result.literals.main)
			@test "6C" in result.raw_lt.main && "74" in result.raw_lt.main
		end
	end
end
