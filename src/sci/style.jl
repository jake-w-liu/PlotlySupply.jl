# PlotlySupply 2.0 scientific-plotting extensions: PlotStyle presets (incl. journal presets), set_fonts!, tight_layout!, figsize!, journal_width.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_STYLE_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# `set_fonts!` is deliberately NOT in `_SCI_STYLE_MUTATORS`: it rewrites the
# colorbar fonts of existing traces, which the registry's fast path (append
# traces + relayout only) can neither stage nor send to the renderer. It gets
# explicit `Plot`/`SyncPlot` methods that run through
# `_transactional_high_level_plot_mutation!` with an unregistered impl, which
# always takes the full (trace-cloning) transaction path.
#
# ─────────────────────────────────────────────────────────────────────────────
# Internal style API (C37 wiring). Every helper reads only its arguments (plus
# the active style / default template for omitted ones) and returns fresh
# values; none mutates a figure unless its name ends in `!`. With the built-in
# `:default` style every helper reproduces the 1.x constants exactly, so the
# wiring changes no 1.x output.
#
# Already wired in api.jl (style-template owner): `_apply_default_template!`
# (template → `_apply_default_cartesian_axes!` → `_apply_default_legend!` with
# `_style_legend_defaults` → `_apply_style_layout!`), `_cartesian_axis_style` /
# `_default_cartesian_layout` (axis defaults at construction),
# `_apply_basic_plot_options!` and `set_template!` (re-derives
# template-derived colours).
#
# Rules for constructors and mutators (other owners):
# - A constructor gets the whole default look by calling
#   `_apply_default_template!` once (directly or through
#   `_apply_cartesian_plot_options!` / `_apply_basic_plot_options!` /
#   `_apply_scene_options!` with `apply_template = true`). Call it AFTER the
#   title, axis titles and paper-referenced annotations exist (the style sizes
#   their fonts and fits the margins around them) and BEFORE an explicit
#   `fontsize` (`_apply_figure_fontsize!`, which merges `font.size` and keeps the
#   style's family/colour), so the caller's base size wins over the style's.
#   Per-role sizes written by the style (title, axis titles, ticks, legend)
#   stay; `set_fonts!` changes those.
# - The template re-writes the 1.x frame keys of every x/y axis (zeroline,
#   showline, mirror, ticks, automargin, linecolor, linewidth, tickcolor); an
#   option that must override one of them (e.g. tick direction) is applied
#   after `_apply_default_template!`. `showgrid` set before it is kept.
# - A mutator never calls `_apply_default_template!` (it would reset a
#   user-set template). A legend it creates should use
#   `_apply_default_legend!(fig; _figure_legend_defaults(fig)...)` (and
#   `_style_legend_font()` for its font size), and an
#   axis it adds (twin/secondary) `_figure_axis_defaults(fig; axis = :y)`, so
#   both match the figure's template (dark on plotly_dark).
# - Trace builders call `_apply_style_trace_defaults!` (below) on the traces
#   they add; code that builds traces on a temporary figure and appends them
#   elsewhere wraps that in `_with_style_trace_offset`.
#
#   _active_style()::PlotStyle
#       The style constructors must consult. Internal callers must not mutate it.
#
#   _style_template(style = _active_style())::PlotlyBase.Template
#       The template a new figure gets. `style.template === nothing` (the
#       `:default` style) follows `get_default_template()`, so
#       `set_default_template!` keeps working exactly as in 1.x.
#
#   _figure_template(fig_or_layout)::Union{Nothing,PlotlyBase.Template}
#       The template an existing figure uses (`layout.template`, a Template or a
#       registered name), `nothing` when it has none. Pass it as `template` to
#       the helpers below when styling something added to an existing figure
#       (e.g. a legend created by a mutator) so the colours match that figure.
#
#   _figure_style_template(fig; style)::PlotlyBase.Template
#       `_figure_template(fig)`, else the style's template.
#
#   _figure_legend_defaults(fig; style)::NamedTuple   (bgcolor, bordercolor, borderwidth)
#   _figure_axis_defaults(fig; axis = :x, style)::Dict{Symbol,Any}
#       `_style_legend_defaults` / `_style_axis_defaults` in the colours of the
#       figure's template, for legends and axes created on an existing figure.
#
#   _style_legend_font(style = _active_style())::Dict{Symbol,Any}
#       `Dict(:size => style.legend_fontsize)` (empty for `:default`): merge
#       into the `font` of a legend created after construction (SubplotFigure
#       per-cell legends), so it matches the legends the style sized.
#
#   _style_axis_defaults(style = _active_style(); template = _style_template(style),
#                        axis::Symbol = :x)::Dict{Symbol,Any}
#       Cartesian axis defaults. Keys: zeroline, showline, mirror, ticks,
#       automargin, linecolor, linewidth, tickcolor (+ showgrid=false when
#       `style.grid` is false; + tickwidth/gridwidth when the style sets
#       `axis_linewidth`, ticklen when it sets `tick_length`; mirror is
#       "ticks" for `mirror_ticks = true`). Plain attribute names, safe for both
#       `attr(; d...)` and `update_xaxes!(fig; d...)`. linecolor/tickcolor are
#       `_template_ink(template)` (black on light templates, the template's font
#       colour on dark ones: audit findings 119/131/216/266/283). When the
#       style's template is a custom (non-built-in) one, `ticks` and `mirror`
#       are omitted where that template defines them for the `axis` direction,
#       so the template wins (C37 / publication evidence E18).
#
#   _style_legend_defaults(style = _active_style(); template = _style_template(style))
#       ::NamedTuple{(:bgcolor, :bordercolor, :borderwidth)}
#       Splat into `_apply_default_legend!(fig; _style_legend_defaults(...)...)`.
#       Light templates give the 1.x `_DEFAULT_LEGEND_*` values; dark templates a
#       translucent box in the template's paper colour with a light border;
#       `legend_frame=false` a transparent, borderless box.
#
#   _style_layout_defaults(style = _active_style(); template = _style_template(style))
#       ::Dict{Symbol,Any}
#       Root layout values: `:font` (Dict family/size/color), `:colorway`
#       (Vector{String}; for the ink cycles `:bw`/`:bw_dash_marker` the single
#       ink colour of `template`) and `:margin` (Dict l/r/t/b/pad), each present
#       only when the style sets it. Empty for `:default`. Dict values are
#       merged key by key into the same-named root layout key by
#       `_apply_style_layout!`.
#
#   _apply_style_layout!(fig, style = _active_style(); template = …)
#       Called once at the end of `_apply_default_template!` (after the
#       template, axes and legend, and after title/annotations such as subplot
#       titles exist, because the margin fit measures them). Merges
#       `_style_layout_defaults`; when the style sets a margin, uses it as the
#       per-side minimum plus the room paper-referenced annotations and the
#       title need (the `tight_layout!` computation) and sets
#       `title.automargin=true` (no top margin is reserved for an empty title).
#       Under a sized style (`width > 0`) it writes layout.width/height where
#       the figure has none (see `_style_default_figure_size`). Writes the style's title/label/tick/legend font sizes to every existing
#       axis (cartesian, scene, polar, ternary), the title, the legends and (tick
#       and label sizes) the colorbars through the same code path as
#       `set_fonts!` (bare-String titles are converted, never broken). A no-op
#       for `:default`. Because colorbar fonts live on traces, call it only on a
#       figure under construction or inside a full, trace-cloning transaction —
#       never from a registered fast-path mutator.
#
#   _style_trace_defaults(style, position::Integer)::Dict{Symbol,Any}
#       Per-trace defaults in PlotlySupply keyword vocabulary for the
#       `position`-th line-style trace of a figure: `:linewidth`,
#       `:marker_size`, `:errorbar_width`, and per `style.cycle` `:dash`,
#       `:marker_symbol`, `:markers` (true = the cycle needs visible markers, so
#       a "lines" mode should become "lines+markers"). Colour is NOT a per-trace
#       default: the ink cycles' black comes from the figure colorway
#       (`_style_layout_defaults`), so `set_template!` can re-derive it and
#       `_default_trace_color` reports it. Empty for `:default`. Prefer
#       `_apply_style_trace_defaults!`, which applies these to finished traces.
#
#   _apply_style_trace_defaults!(fig, trace_indices; style = _active_style(), explicit = ())
#       Fill the active style's line width, marker size, dash/marker cycle,
#       error-bar thickness and contour line width into the traces at
#       `trace_indices` (1-based positions in the figure's
#       data, normally the traces the calling constructor or mutator just
#       added) wherever the trace leaves them unset. See its docstring.
#
#   _with_style_trace_offset(f, fig)
#       Run `f()` so that `_apply_style_trace_defaults!` inside it continues
#       the cycle of `fig` (for builders that work on a temporary figure).
#
#   _style_mathsize(style = _active_style())::String
#       "" or a MathJax 2 size switch for the mathtext pipeline (`:publication`
#       gives "\\large"). `_label` and `mathtext` (src/sci/mathtext.jl,
#       `_mathtext_default_size`) fall back to it when the
#       `set_default_mathtext!` size is "", so every math label of a figure
#       built under the style gets the same size.
#
#   _template_is_dark(t), _template_ink(t), _template_legend_colors(t)
#       Template-derived colours; `set_template!` re-derives every layout value
#       that still equals the previous template's colour.
#
#   _style_default_figure_size(style = _active_style())::Tuple{Float64,Float64}
#       (width, height) in CSS px of a figure that has no layout.width/height
#       of its own: the style's `width` and `width * aspect` when the style
#       sets a width (every journal preset), else the 1.x export default
#       700 x 500. Not rounded (89 mm = 336.378 px). `_apply_style_layout!`
#       writes it into every new figure built under a sized style, so the
#       export honours it through the layout; savefig (math-export) uses it
#       for figures that carry no size at all. Contract:
#       <scratch>/v4/publication-style/CONTRACT.md.
#
#   _style_ink(fig)::String
#       Default colour of lines PlotlySupply draws on its own (reference
#       lines, outlines, arrows): the ink of the figure's template (black on
#       light templates, light on dark ones).
#
#   _style_line_width(role::Symbol; default, style = _active_style())::Float64
#       px width of a line role (:data, :reference, :axis, :errorbar,
#       :contour, :mesh) under `style`; `default` when the style leaves the
#       role unset. Code that draws lines of its own (shapes, mesh edges) uses
#       it so the style reaches them.
#
#   _JOURNALS / _journal_spec(name, who)
#       The journal presets (`:ieee`, `:aps`, `:nature`, `:elsevier`,
#       `:springer`, `:aip`): column widths, fonts and line weights taken from
#       each publisher's author guidelines (cited next to each entry). They
#       back the built-in styles of the same names, `figsize!(fig, journal)`
#       and `journal_width`.
# ─────────────────────────────────────────────────────────────────────────────

export PlotStyle, set_default_style!, get_default_style, with_style, register_style!
export set_fonts!, tight_layout!, figsize!, journal_width

const _SCI_STYLE_MUTATORS = (:tight_layout!, :figsize!)

# ── Small shared helpers ─────────────────────────────────────────────────────

# Plotly accepts any number for sizes; integral values are emitted as `Int` so
# JSON stays `12` rather than `12.0`, matching the 1.x integer keywords.
_style_number(x::Real) = (isinteger(x) && abs(x) < 2.0^53) ? Int(x) : Float64(x)

# 1 in = 96 CSS px = 72 pt is the CSS reference-pixel definition that Chromium
# (and therefore every PlotlySupply export) uses; cm/mm follow from 2.54 cm/in.
const _STYLE_PX_PER_UNIT = (
	px = 1.0,
	pt = 96.0 / 72.0,
	in = 96.0,
	cm = 96.0 / 2.54,
	mm = 96.0 / 25.4,
)

function _style_px_per_unit(units::Symbol, allowed::Tuple, who::AbstractString)
	units in allowed ||
		throw(ArgumentError(
			"$(who): `units` must be one of $(join(repr.(allowed), ", ")); got $(repr(units)).",
		))
	return Float64(getfield(_STYLE_PX_PER_UNIT, units))
end

function _style_real(value, who::AbstractString, name::AbstractString)
	(value isa Real && !(value isa Bool)) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a real number; got $(repr(value)).",
		))
	isfinite(value) ||
		throw(ArgumentError("$(who): `$(name)` must be finite; got $(value)."))
	return Float64(value)
end

function _style_nonnegative(value, who::AbstractString, name::AbstractString)
	v = _style_real(value, who, name)
	v >= 0 ||
		throw(ArgumentError(
			"$(who): `$(name)` must be >= 0 (0 means unset); got $(value).",
		))
	return v
end

# Font sizes: 0 means unset; plotly's minimum font size is 1 px.
function _style_font_size(value, who::AbstractString, name::AbstractString)
	v = _style_nonnegative(value, who, name)
	(v == 0 || v >= 1) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be 0 (unset) or at least 1 px; got $(value).",
		))
	return v
end

# Parse a CSS/plotly colour string. Returns `nothing` when Colors cannot parse
# it; only Colors' own ArgumentError is treated as "not a colour".
function _style_try_parse_color(value::AbstractString)
	try
		return PlotlyBase.Colors.parse(PlotlyBase.Colors.Colorant, String(value))
	catch err
		err isa ArgumentError || rethrow()
		return nothing
	end
end

function _style_colorant_string(c::PlotlyBase.Colors.Colorant)
	rgba = convert(PlotlyBase.Colors.RGBA{Float64}, c)
	if rgba.alpha >= 1
		return "#" * PlotlyBase.Colors.hex(convert(PlotlyBase.Colors.RGB{Float64}, rgba))
	end
	r, g, b = (round(Int, 255 * clamp(u, 0, 1)) for u in (rgba.r, rgba.g, rgba.b))
	return "rgba($(r),$(g),$(b),$(round(rgba.alpha; digits = 4)))"
end

# Validate a user colour. `""` means unset. Strings and Symbols are passed
# through unchanged (after checking they parse), except matplotlib grey levels
# ("0.35"), which become "#RRGGBB"; Colorants become hex/rgba.
function _style_color(value, who::AbstractString, name::AbstractString; allow_empty::Bool = true)
	if value isa PlotlyBase.Colors.Colorant
		return _style_colorant_string(value)
	end
	(value isa AbstractString || value isa Symbol) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a colour string, Symbol or Colorant; got $(repr(value)).",
		))
	s = String(value)
	if isempty(s)
		allow_empty && return ""
		throw(ArgumentError("$(who): `$(name)` must not be empty."))
	end
	# A number is a matplotlib grey level ("0.35" == "#595959", A1/G16). CSS
	# and plotly.js know no numeric colours, so it is converted to hex here
	# rather than passed through (plotly.js would silently use its default).
	level = tryparse(Float64, strip(s))
	if level !== nothing
		(isfinite(level) && 0 <= level <= 1) ||
			throw(ArgumentError(
				"$(who): `$(name)` = $(repr(s)) is a matplotlib grey level and must lie in [0, 1].",
			))
		return _color_hex(s; who = who)
	end
	_style_try_parse_color(s) === nothing &&
		throw(ArgumentError(
			"$(who): `$(name)` is not a recognised colour: $(repr(s)).",
		))
	return s
end

# Relative luminance (WCAG 2.x) of a colour composited over white, so a
# transparent background counts as the white page it is exported onto.
function _style_luminance(c::PlotlyBase.Colors.Colorant)
	rgba = convert(PlotlyBase.Colors.RGBA{Float64}, c)
	a = clamp(rgba.alpha, 0.0, 1.0)
	channel(u) = begin
		v = a * clamp(u, 0.0, 1.0) + (1 - a)
		v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055)^2.4
	end
	return 0.2126 * channel(rgba.r) + 0.7152 * channel(rgba.g) + 0.0722 * channel(rgba.b)
end

_style_contrast(l1::Real, l2::Real) = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)

# ── Template-derived colours ─────────────────────────────────────────────────

# Names of the plotly.py templates bundled with PlotlyBase. Compound names whose
# parts are all built-in (e.g. "plotly_dark+xgridoff") also count as built-in.
const _STYLE_BUILTIN_TEMPLATES = (
	:ggplot2,
	:gridon,
	:plotly,
	:plotly_dark,
	:plotly_white,
	:presentation,
	:seaborn,
	:simple_white,
	:xgridoff,
	:ygridoff,
)

function _template_layout_fields(t::PlotlyBase.Template)
	layout = t.layout
	return layout isa PlotlyBase.Layout ? layout.fields : _symbol_dict(layout)
end

# The colour the axes, tick labels and legend sit on: paper_bgcolor, then
# plot_bgcolor; `nothing` when the template sets neither (overlay templates such
# as xgridoff inherit plotly's white default) or the value cannot be parsed.
function _template_background(t::PlotlyBase.Template)
	fields = _template_layout_fields(t)
	for key in (:paper_bgcolor, :plot_bgcolor)
		value = get(fields, key, nothing)
		value isa AbstractString || continue
		c = _style_try_parse_color(value)
		c === nothing || return c
	end
	return nothing
end

# Dark means black text would contrast worse than white text: relative
# luminance below 0.179, the point where both contrast ratios are equal.
function _template_is_dark(t::PlotlyBase.Template)
	bg = _template_background(t)
	return bg !== nothing && _style_luminance(bg) < 0.179
end

# Spine and tick colour for a template: the 1.x black on light templates; on
# dark templates the template's own font colour when it contrasts with the
# background (plotly_dark gives "#f2f5fa"), otherwise white.
function _template_ink(t::PlotlyBase.Template)
	_template_is_dark(t) || return _DEFAULT_AXIS_LINECOLOR
	bg_luminance = _style_luminance(_template_background(t))
	font = _symbol_dict(get(_template_layout_fields(t), :font, nothing))
	font_color = get(font, :color, nothing)
	if font_color isa AbstractString
		c = _style_try_parse_color(font_color)
		if c !== nothing && _style_contrast(_style_luminance(c), bg_luminance) >= 4.5
			return String(font_color)
		end
	end
	return "#ffffff"
end

# Legend box colours: the 1.x translucent white box on light templates; on dark
# templates the same 0.72 opacity in the template's own background colour with
# a light border, so legend text keeps the template's contrast.
function _template_legend_colors(t::PlotlyBase.Template)
	_template_is_dark(t) ||
		return (
			bgcolor = _DEFAULT_LEGEND_BGCOLOR[],
			bordercolor = _DEFAULT_LEGEND_BORDERCOLOR[],
		)
	rgb = convert(PlotlyBase.Colors.RGB{Float64}, _template_background(t))
	r, g, b = (round(Int, 255 * clamp(u, 0, 1)) for u in (rgb.r, rgb.g, rgb.b))
	return (
		bgcolor = "rgba($(r),$(g),$(b),0.72)",
		bordercolor = "rgba(255,255,255,0.25)",
	)
end

# ── PlotStyle ────────────────────────────────────────────────────────────────

const _STYLE_TICKS = ("outside", "inside", "")
const _STYLE_SPINES = (:box, :open, :none)
const _STYLE_CYCLES = (:none, :bw, :dash, :marker, :dash_marker, :dash_symbol, :bw_dash_marker)
# Cycles that fill `line.dash` / `marker.symbol`, and those that also add the
# markers flag to a lines-only mode so the symbol shows.
const _STYLE_DASH_CYCLES = (:bw, :dash, :dash_marker, :dash_symbol, :bw_dash_marker)
const _STYLE_SYMBOL_CYCLES = (:marker, :dash_marker, :dash_symbol, :bw_dash_marker)
const _STYLE_MARKER_FLAG_CYCLES = (:marker, :dash_marker, :bw_dash_marker)
# Cycles drawn in the template's single ink colour (the colorway is the ink).
const _STYLE_INK_CYCLES = (:bw, :bw_dash_marker)
# Height / width of a sized style that sets no `aspect`: matplotlib's default
# `figure.figsize` of 6.4 x 4.8 in.
const _STYLE_DEFAULT_ASPECT = 0.75
# plotly.js rejects layout.width/height below 10 px; the upper bound only
# keeps `round(Int, ·)` in range (no canvas comes near 2^31 px).
const _STYLE_MIN_FIGURE_PX = 10.0
const _STYLE_MAX_FIGURE_PX = Float64(typemax(Int32))
# `mathsize` accepts exactly the MathJax 2 size switches the mathtext pipeline
# accepts (`_MATHTEXT_SIZES`, src/sci/mathtext.jl): `\footnotesize` does not
# exist in MathJax 2 and would render as a red undefined macro.
const _STYLE_MATHSIZES = ("", ("\\" * name for name in _MATHTEXT_SIZES)...)
const _STYLE_LOG_TICKS = (:auto, :decades)
const _STYLE_MARGIN_KEYS = (:l, :r, :t, :b, :pad)
const _STYLE_DASH_CYCLE = ("solid", "dash", "dot", "dashdot")
const _STYLE_MARKER_CYCLE = (
	"circle",
	"square",
	"diamond",
	"triangle-up",
	"x",
	"triangle-down",
	"cross",
	"star",
)

"""
	PlotStyle(; template=nothing, font_family="", fontsize=0, title_fontsize=0,
		label_fontsize=0, tick_fontsize=0, legend_fontsize=0, font_color="",
		colorway=nothing, linewidth=0, marker_size=0, ticks="outside", spines=:box,
		grid=true, legend_frame=true, margin=nothing, mathsize="", cycle=:none,
		width=0, aspect=0, axis_linewidth=0, tick_length=0, mirror_ticks=false,
		errorbar_width=0, reference_linewidth=0, log_ticks=:auto)

A named bundle of figure defaults (the PlotlySupply analogue of matplotlib
`rcParams`). The active style is chosen with [`set_default_style!`](@ref) or
temporarily with [`with_style`](@ref); styles are registered by name with
[`register_style!`](@ref). Built-in styles:

- `:default` — exactly the PlotlySupply 1.x look: the package default template
  (see `set_default_template!`), black closed spines, outside ticks, plotly's
  default fonts, colours and margins.
- `:publication` — black Times text (`font_family="Times New Roman, Times,
  Liberation Serif, serif"`, `fontsize=14`, `title_fontsize=16`,
  `label_fontsize=14`, `tick_fontsize=12`, `legend_fontsize=12`; TrueType
  faces, so PDF exports embed TrueType rather than Type 3 fonts), the
  Okabe–Ito colour-blind-safe
  colorway (`COLOR_CYCLES[:okabe_ito]`, high-contrast colours first), a closed
  box, a frameless legend, `\\large` math and a 10 px margin that grows
  automatically to fit labels and the title, and decade-only tick labels on
  logarithmic axes spanning two decades or more (`log_ticks = :decades`). It
  sets no figure size and no per-trace defaults.
- Journal presets `:ieee`, `:aps`, `:nature`, `:elsevier`, `:springer`, `:aip`
  — sized for the journal's single column (`width`, `aspect = 0.75`), in the
  journal's font family and sizes, with print line weights (1 pt data lines,
  0.75 pt axes, ticks, error bars and reference lines, 3.5 pt ticks), the
  Okabe–Ito colorway, the greyscale-safe `:dash_symbol` cycle and decade-only
  log tick labels. Their
  numbers, and where each comes from, are listed by [`journal_width`](@ref);
  [`figsize!`](@ref)`(fig, :ieee; columns = 2)` sizes a figure for any
  column count the journal defines.

Every field is validated by the constructor and on assignment
(`style.fontsize = 12`), so an invalid style cannot be built.

# Keywords (fields)
- `template`: `nothing` (follow `get_default_template()`), a template name
  (`Symbol`/`String`, `+` compounds allowed) or a `PlotlyBase.Template`.
- `font_family::AbstractString=""`: CSS font family list for all text.
- `fontsize::Real=0`: base font size in px (`layout.font.size`).
- `title_fontsize`, `label_fontsize`, `tick_fontsize`, `legend_fontsize`
  (`Real`, default 0): per-role sizes in px for the figure title, axis titles,
  tick labels and legend text.
- `font_color=""`: colour of all text (`layout.font.color`).
- `colorway=nothing`: trace colour cycle; a name from
  [`COLOR_CYCLES`](@ref PlotlySupply.COLOR_CYCLES) (`:okabe_ito`,
  `:tol_bright`, `:tol_vibrant`, `:tol_muted`, `:tol_high_contrast`:
  colour-blind-safe, in an order that puts the colours readable as thin
  lines on white first), any other palette name `Symbol` from
  `PlotlyBase.colors` (e.g. `:tab10`), a vector of colours (matplotlib grey
  levels such as `"0.35"` become `"#595959"`), or a `ColorScheme`. Stored as a
  `Vector{String}`.
- `linewidth::Real=0`, `marker_size::Real=0`: default trace line width and
  marker size in px.
- `ticks="outside"`: `"outside"`, `"inside"` or `""`/`:none` (no tick marks).
- `spines=:box`: `:box` (closed frame), `:open` (left and bottom only) or
  `:none` (no axis lines).
- `grid::Bool=true`: `false` hides cartesian grid lines.
- `legend_frame::Bool=true`: `false` draws legends without box or border.
- `margin=nothing`: plot margins in px: a number (all four sides), or a
  `NamedTuple`/`Dict` with any of `l`, `r`, `t`, `b`, `pad`. When set, the
  figure title is given `automargin=true` so it never overlaps the plot.
- `mathsize=""`: MathJax size switch applied to math labels by the mathtext
  pipeline when `set_default_mathtext!` sets no size: `""` or one of
  `"\\\\tiny"`, `"\\\\Tiny"`, `"\\\\scriptsize"`, `"\\\\small"`,
  `"\\\\normalsize"`, `"\\\\large"`, `"\\\\Large"`, `"\\\\LARGE"`, `"\\\\huge"`,
  `"\\\\Huge"` (MathJax 2 has no `\\footnotesize`).
- `cycle=:none`: per-trace line-style cycle used where the caller does not pass
  `dash`/`marker_symbol`: `:dash` (solid, dash, dot, dashdot), `:marker`
  (circle, square, diamond, triangle-up, x, triangle-down, cross, star; a
  `"lines"` mode becomes `"lines+markers"`), `:dash_marker` (both), or `:bw`
  (the dash cycle drawn in one ink colour: the figure colorway becomes the
  template's ink, black on light templates, light on dark ones, so `colorway`
  is not used), `:dash_symbol` (the dash cycle and the marker-symbol cycle,
  without adding markers to a lines-only trace: lines differ by dash, marked
  series by dash and symbol, so every series stays distinct in greyscale) or
  `:bw_dash_marker` (`:bw` plus the marker cycle with markers shown: the
  monochrome cycle). The cycle counts the line-style (scatter-type) traces of
  a figure, so it continues across `plot_*!` appends.
- `width::Real=0`: figure width in CSS px given to every new figure that sets
  no `width` of its own (`0`: unset, plotly's autosize and the 700 × 500 px
  export default). At least 10 px.
- `aspect::Real=0`: height / width of such a figure (`0`: 0.75, matplotlib's
  6.4 × 4.8 in). Used only with `width`; between 0.01 and 100. A figure given
  only a `width` gets `width * aspect` as height; one given only a `height`
  keeps the style's width.
- `axis_linewidth::Real=0`: spine, tick and grid line width in px (`0`: the
  1.x 1 px spines and plotly's tick and grid widths).
- `tick_length::Real=0`: tick mark length in px (`0`: plotly's 5 px).
- `mirror_ticks::Bool=false`: with `spines=:box` and visible ticks, also draw
  tick marks on the top and right spines (physics-journal style).
- `errorbar_width::Real=0`: error-bar line thickness in px for traces whose
  error bars leave it unset.
- `reference_linewidth::Real=0`: width in px for reference lines and shapes
  (the `:reference` role of the internal `_style_line_width`): the default
  line width of `hline!`, `vline!`, `arrow!`, `arc!`, the schematic shapes
  (`circle!`, `ellipse!`, `rectangle!`, `polygon!`) and an `hspan!`/`vspan!`
  outline. `0` keeps their 1 px default.
- `log_ticks=:auto`: tick labels of a logarithmic axis that has no tick
  setting of its own. `:auto` keeps plotly's adaptive labels; `:decades` labels
  decades only (every k-th decade on a long axis, unlabelled minor ticks
  between) once the axis shows two decades or more, so that the minor labels
  `2`, `5` of a narrow column-width panel never collide. `:publication` and
  every journal preset use `:decades`; `:default` keeps `:auto`. An axis
  that has `tickvals`, `dtick`, `tickmode` or `ticktext` set by the user is
  never changed.

Numeric fields use `0` as "unset"; negative and non-finite values throw an
`ArgumentError`. Sizes and widths are CSS px (1 pt = 4/3 px, 1 in = 96 px).

`template` defaults to `nothing` rather than `"plotly_white"` so that the
`:default` style keeps honouring `set_default_template!` exactly as 1.x did.

# How a style meets the constructor keywords
The active style is applied when a figure is created; existing figures are not
restyled. A constructor's explicit keywords then win: `fontsize` sets the base
size (`layout.font.size`, keeping the style's family and colour) while the
style's per-role sizes stay (change those with [`set_fonts!`](@ref)); a
`grid` keyword other than the constructor default `true` (`false`, `:x`,
`:y`, `:both`, `:none`) wins over the style's `grid`; `title`/`xlabel`/`ylabel`
get the style's role sizes. Spine,
tick and legend colours follow the template (light ink on dark templates) and
are re-derived by `set_template!`.

# Example
```julia
style = PlotStyle(; font_family = "Arial", fontsize = 12, tick_fontsize = 10,
	colorway = :tab10, spines = :open, grid = false)
register_style!(:paper, style)
with_style(:paper) do
	plot_scatter(1:10, (1:10) .^ 2; xlabel = "x", ylabel = "y")
end
```
"""
mutable struct PlotStyle
	template::Union{Nothing, Symbol, PlotlyBase.Template}
	font_family::String
	fontsize::Float64
	title_fontsize::Float64
	label_fontsize::Float64
	tick_fontsize::Float64
	legend_fontsize::Float64
	font_color::String
	colorway::Union{Nothing, Vector{String}}
	linewidth::Float64
	marker_size::Float64
	ticks::String
	spines::Symbol
	grid::Bool
	legend_frame::Bool
	margin::Union{Nothing, Dict{Symbol, Float64}}
	mathsize::String
	cycle::Symbol
	width::Float64
	aspect::Float64
	axis_linewidth::Float64
	tick_length::Float64
	mirror_ticks::Bool
	errorbar_width::Float64
	reference_linewidth::Float64
	log_ticks::Symbol

	function PlotStyle(
		template,
		font_family,
		fontsize,
		title_fontsize,
		label_fontsize,
		tick_fontsize,
		legend_fontsize,
		font_color,
		colorway,
		linewidth,
		marker_size,
		ticks,
		spines,
		grid,
		legend_frame,
		margin,
		mathsize,
		cycle,
		width = 0,
		aspect = 0,
		axis_linewidth = 0,
		tick_length = 0,
		mirror_ticks = false,
		errorbar_width = 0,
		reference_linewidth = 0,
		log_ticks = :auto;
		who::AbstractString = "PlotStyle",
	)
		v(name, value) = _style_validate_field(name, value, who)
		style = new(
			v(:template, template),
			v(:font_family, font_family),
			v(:fontsize, fontsize),
			v(:title_fontsize, title_fontsize),
			v(:label_fontsize, label_fontsize),
			v(:tick_fontsize, tick_fontsize),
			v(:legend_fontsize, legend_fontsize),
			v(:font_color, font_color),
			v(:colorway, colorway),
			v(:linewidth, linewidth),
			v(:marker_size, marker_size),
			v(:ticks, ticks),
			v(:spines, spines),
			v(:grid, grid),
			v(:legend_frame, legend_frame),
			v(:margin, margin),
			v(:mathsize, mathsize),
			v(:cycle, cycle),
			v(:width, width),
			v(:aspect, aspect),
			v(:axis_linewidth, axis_linewidth),
			v(:tick_length, tick_length),
			v(:mirror_ticks, mirror_ticks),
			v(:errorbar_width, errorbar_width),
			v(:reference_linewidth, reference_linewidth),
			v(:log_ticks, log_ticks),
		)
		_style_check_figure_size(style.width, style.aspect, who)
		return style
	end
end

# `width` and `aspect` together must give a height plotly accepts. Checked
# wherever either field changes, so a style can never produce a figure size
# plotly rejects.
function _style_check_figure_size(width::Float64, aspect::Float64, who::AbstractString)
	width == 0 && return nothing
	height = width * (aspect > 0 ? aspect : _STYLE_DEFAULT_ASPECT)
	_STYLE_MIN_FIGURE_PX <= height <= _STYLE_MAX_FIGURE_PX ||
		throw(ArgumentError(
			"$(who): `width` = $(_style_number(width)) px with `aspect` = $(_style_number(aspect > 0 ? aspect : _STYLE_DEFAULT_ASPECT)) " *
			"gives a height of $(height) px; plotly needs between $(_style_number(_STYLE_MIN_FIGURE_PX)) and " *
			"$(_style_number(_STYLE_MAX_FIGURE_PX)) px.",
		))
	return nothing
end

function PlotStyle(
	;
	template = nothing,
	font_family::AbstractString = "",
	fontsize::Real = 0,
	title_fontsize::Real = 0,
	label_fontsize::Real = 0,
	tick_fontsize::Real = 0,
	legend_fontsize::Real = 0,
	font_color = "",
	colorway = nothing,
	linewidth::Real = 0,
	marker_size::Real = 0,
	ticks::Union{AbstractString, Symbol} = "outside",
	spines::Union{AbstractString, Symbol} = :box,
	grid::Bool = true,
	legend_frame::Bool = true,
	margin = nothing,
	mathsize::AbstractString = "",
	cycle::Union{AbstractString, Symbol} = :none,
	width::Real = 0,
	aspect::Real = 0,
	axis_linewidth::Real = 0,
	tick_length::Real = 0,
	mirror_ticks::Bool = false,
	errorbar_width::Real = 0,
	reference_linewidth::Real = 0,
	log_ticks::Union{AbstractString, Symbol} = :auto,
)
	return PlotStyle(
		template,
		font_family,
		fontsize,
		title_fontsize,
		label_fontsize,
		tick_fontsize,
		legend_fontsize,
		font_color,
		colorway,
		linewidth,
		marker_size,
		ticks,
		spines,
		grid,
		legend_frame,
		margin,
		mathsize,
		cycle,
		width,
		aspect,
		axis_linewidth,
		tick_length,
		mirror_ticks,
		errorbar_width,
		reference_linewidth,
		log_ticks,
	)
end

function _style_template_spec(value, who::AbstractString)
	value === nothing && return nothing
	value isa PlotlyBase.Template && return value
	(value isa Symbol || value isa AbstractString) ||
		throw(ArgumentError(
			"$(who): `template` must be nothing, a template name or a PlotlyBase.Template; got $(typeof(value)).",
		))
	parts = strip.(split(String(value), '+'))
	known = keys(PlotlyBase.templates)
	if !isempty(parts) && all(part -> !isempty(part) && Symbol(part) in known, parts)
		return Symbol(join(parts, '+'))
	end
	valid = join(sort!(String.(collect(known))), ", ")
	throw(ArgumentError(
		"$(who): unknown template $(repr(value)); registered templates: $(valid).",
	))
end

function _style_colorway(value, who::AbstractString)
	value === nothing && return nothing
	if value isa Symbol
		# The curated cycles (`COLOR_CYCLES`, src/sci/color.jl) win over the
		# ColorSchemes palettes of the same name: same colours, line-safe order.
		# User-added cycles are validated here, like any colour vector.
		haskey(COLOR_CYCLES, value) && return _style_colorway(collect(COLOR_CYCLES[value]), who)
		haskey(PlotlyBase.colors.all, value) ||
			throw(ArgumentError(
				"$(who): unknown palette $(repr(value)); use a name from " *
				"`PlotlySupply.COLOR_CYCLES` ($(join(repr.(sort!(collect(keys(COLOR_CYCLES)))), ", "))) " *
				"or `PlotlyBase.colors` (e.g. :tab10), a vector of colours, or a ColorScheme.",
			))
		return String[_style_colorant_string(c) for c in PlotlyBase.colors.all[value].colors]
	elseif value isa PlotlyBase.ColorSchemes.ColorScheme
		isempty(value.colors) &&
			throw(ArgumentError("$(who): `colorway` ColorScheme has no colours."))
		return String[_style_colorant_string(c) for c in value.colors]
	elseif value isa AbstractVector
		isempty(value) &&
			throw(ArgumentError("$(who): `colorway` must contain at least one colour."))
		return String[
			_style_color(c, who, "colorway[$(i)]"; allow_empty = false)
			for (i, c) in enumerate(value)
		]
	end
	throw(ArgumentError(
		"$(who): `colorway` must be nothing, a palette Symbol, a vector of colours or a ColorScheme; got $(typeof(value)).",
	))
end

function _style_ticks(value, who::AbstractString)
	if value isa Symbol
		value === :outside && return "outside"
		value === :inside && return "inside"
		value === :none && return ""
	elseif value isa AbstractString
		s = String(value)
		s in _STYLE_TICKS && return s
	end
	throw(ArgumentError(
		"$(who): `ticks` must be \"outside\", \"inside\" or \"\" (:outside, :inside, :none); got $(repr(value)).",
	))
end

function _style_symbol_choice(value, choices::Tuple, who::AbstractString, name::AbstractString)
	(value isa Symbol || value isa AbstractString) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be one of $(join(repr.(choices), ", ")); got $(repr(value)).",
		))
	s = Symbol(value)
	s in choices ||
		throw(ArgumentError(
			"$(who): `$(name)` must be one of $(join(repr.(choices), ", ")); got $(repr(value)).",
		))
	return s
end

function _style_margin(value, who::AbstractString)
	value === nothing && return nothing
	if value isa Real && !(value isa Bool)
		m = _style_nonnegative(value, who, "margin")
		return Dict{Symbol, Float64}(:l => m, :r => m, :t => m, :b => m)
	end
	entries = if value isa NamedTuple
		pairs(value)
	elseif value isa AbstractDict || value isa PlotlyBase.PlotlyAttribute
		pairs(_symbol_dict(value))
	else
		throw(ArgumentError(
			"$(who): `margin` must be nothing, a number, or a NamedTuple/Dict with keys l, r, t, b, pad; got $(typeof(value)).",
		))
	end
	out = Dict{Symbol, Float64}()
	for (key, side) in entries
		k = Symbol(key)
		k in _STYLE_MARGIN_KEYS ||
			throw(ArgumentError(
				"$(who): unknown margin key $(repr(key)); allowed keys are l, r, t, b, pad.",
			))
		out[k] = _style_nonnegative(side, who, "margin.$(k)")
	end
	isempty(out) &&
		throw(ArgumentError("$(who): `margin` must set at least one of l, r, t, b, pad."))
	return out
end

function _style_validate_field(name::Symbol, value, who::AbstractString)
	if name === :template
		return _style_template_spec(value, who)
	elseif name === :font_family
		value isa AbstractString ||
			throw(ArgumentError("$(who): `font_family` must be a string; got $(repr(value))."))
		return String(value)
	elseif name in (:fontsize, :title_fontsize, :label_fontsize, :tick_fontsize, :legend_fontsize)
		return _style_font_size(value, who, String(name))
	elseif name === :font_color
		return _style_color(value, who, "font_color")
	elseif name === :colorway
		return _style_colorway(value, who)
	elseif name in (:linewidth, :marker_size, :axis_linewidth, :tick_length, :errorbar_width, :reference_linewidth)
		return _style_nonnegative(value, who, String(name))
	elseif name === :width
		v = _style_nonnegative(value, who, "width")
		(v == 0 || _STYLE_MIN_FIGURE_PX <= v <= _STYLE_MAX_FIGURE_PX) ||
			throw(ArgumentError(
				"$(who): `width` must be 0 (unset) or between $(_style_number(_STYLE_MIN_FIGURE_PX)) and $(_style_number(_STYLE_MAX_FIGURE_PX)) px; got $(value).",
			))
		return v
	elseif name === :aspect
		v = _style_nonnegative(value, who, "aspect")
		# A figure is a page element: anything outside 1/100 .. 100 is a typo,
		# not a layout (and would push the other side past plotly's limits).
		(v == 0 || 0.01 <= v <= 100) ||
			throw(ArgumentError(
				"$(who): `aspect` (height / width) must be 0 (unset) or between 0.01 and 100; got $(value).",
			))
		return v
	elseif name === :ticks
		return _style_ticks(value, who)
	elseif name === :spines
		return _style_symbol_choice(value, _STYLE_SPINES, who, "spines")
	elseif name in (:grid, :legend_frame, :mirror_ticks)
		value isa Bool ||
			throw(ArgumentError("$(who): `$(name)` must be a Bool; got $(repr(value))."))
		return value
	elseif name === :margin
		return _style_margin(value, who)
	elseif name === :mathsize
		value isa AbstractString && String(value) in _STYLE_MATHSIZES ||
			throw(ArgumentError(
				"$(who): `mathsize` must be \"\" or one of $(join(_STYLE_MATHSIZES[2:end], ", ")); got $(repr(value)).",
			))
		return String(value)
	elseif name === :cycle
		return _style_symbol_choice(value, _STYLE_CYCLES, who, "cycle")
	elseif name === :log_ticks
		return _style_symbol_choice(value, _STYLE_LOG_TICKS, who, "log_ticks")
	end
	throw(ArgumentError(
		"$(who): unknown PlotStyle field `$(name)`; fields are $(join(fieldnames(PlotStyle), ", ")).",
	))
end

function Base.setproperty!(style::PlotStyle, name::Symbol, value)
	hasfield(PlotStyle, name) ||
		throw(ArgumentError(
			"PlotStyle: unknown field `$(name)`; fields are $(join(fieldnames(PlotStyle), ", ")).",
		))
	checked = _style_validate_field(name, value, "PlotStyle")
	if name === :width || name === :aspect
		_style_check_figure_size(
			name === :width ? checked : style.width,
			name === :aspect ? checked : style.aspect,
			"PlotStyle",
		)
	end
	return setfield!(style, name, checked)
end

function Base.copy(style::PlotStyle)
	return PlotStyle((getfield(style, f) for f in fieldnames(PlotStyle))...)
end

# Template objects compare by identity (two distinct Template objects are
# different styles even if equal in content); every other field by value.
_style_field_equal(a::PlotlyBase.Template, b::PlotlyBase.Template) = a === b
_style_field_equal(a, b) = isequal(a, b)

function Base.:(==)(a::PlotStyle, b::PlotStyle)
	return all(_style_field_equal(getfield(a, f), getfield(b, f)) for f in fieldnames(PlotStyle))
end

_style_field_hash(x::PlotlyBase.Template, h::UInt) = hash(objectid(x), h)
_style_field_hash(x, h::UInt) = hash(x, h)

function Base.hash(style::PlotStyle, h::UInt)
	h = hash(:PlotStyle, h)
	for f in fieldnames(PlotStyle)
		h = _style_field_hash(getfield(style, f), h)
	end
	return h
end

function Base.show(io::IO, ::MIME"text/plain", style::PlotStyle)
	print(io, "PlotStyle:")
	for f in fieldnames(PlotStyle)
		value = getfield(style, f)
		shown = value isa PlotlyBase.Template ? "PlotlyBase.Template(…)" : repr(value)
		print(io, "\n  ", f, " = ", shown)
	end
	return nothing
end

# ── Registry and active style ────────────────────────────────────────────────

_default_plot_style() = PlotStyle()

# Font families of the built-in styles: TrueType faces first, so PDF/EPS
# exports embed real (CID TrueType) fonts. STIXGeneral, the 2.0 betas' first
# choice, is installed as OpenType-CFF (.otf) on macOS and came out of a
# measured PDF export as Type 3 fonts, which many submission systems reject
# (D14). Liberation Serif/Sans are the metric-compatible Times/Arial of most
# Linux systems.
const _SERIF_FONTS = "Times New Roman, Times, Liberation Serif, serif"
const _SANS_FONTS = "Arial, Helvetica, Liberation Sans, sans-serif"

_publication_plot_style() = PlotStyle(
	;
	template = :plotly_white,
	font_family = _SERIF_FONTS,
	fontsize = 14,
	title_fontsize = 16,
	label_fontsize = 14,
	tick_fontsize = 12,
	legend_fontsize = 12,
	font_color = "#000000",
	colorway = :okabe_ito,
	spines = :box,
	legend_frame = false,
	margin = 10,
	mathsize = "\\large",
	log_ticks = :decades,
)

# ── Journal presets (D14) ────────────────────────────────────────────────────
#
# Column widths, page heights, fonts and minimum sizes are taken from each
# publisher's author guidelines (read 2026-11; the source is next to each
# entry). Where a guideline is silent the value is a package choice and says
# so. Every guideline below that sets a minimum line weight asks for 0.3–0.5 pt
# at most, so all presets share: data lines 1 pt, spines/ticks/error bars/
# reference lines 0.75 pt, 3.5 pt tick marks (matplotlib's major tick length)
# and 4.5 pt (6 px) markers. Optica is not offered: its figure widths could
# not be confirmed from Optica's own guidelines.
#
# `columns` lists (column count, width, unit) exactly as published, so a width
# converts to the exact page size (89 mm stays 336.378 px, 252.28 pt).
struct _JournalSpec
	name::Symbol
	publisher::String
	columns::Vector{Tuple{Float64, Float64, Symbol}}
	max_height::Tuple{Float64, Symbol}   # (0.0, :mm): the guideline sets none
	font_family::String
	fontsize_pt::Float64                 # every text role
	ticks::String
	mirror_ticks::Bool
	spines::Symbol
	source::String
end

const _JOURNALS = (
	# IEEE Author Center, "Resolution and Size"
	# (journals.ieeeauthorcenter.ieee.org/create-your-ieee-journal-article/
	# create-graphics-for-your-article/resolution-and-size/): one column 3.5 in
	# (88.9 mm, 21 picas), two columns 7.16 in (182 mm, 43 picas). IEEE journal
	# template: "Use 8 point Times New Roman for Figure labels". Inside,
	# mirrored ticks: choice (the common IEEE/physics look).
	_JournalSpec(:ieee, "IEEE", [(1.0, 3.5, :in), (2.0, 7.16, :in)], (0.0, :mm),
		_SERIF_FONTS, 8.0, "inside", true, :box,
		"IEEE Author Center, Resolution and Size: 3.5 in / 7.16 in; IEEE template: 8 pt Times New Roman labels"),
	# APS Physical Review, Information for Authors
	# (journals.aps.org/prb/info/infoB.html): single column 8.6 cm (3 3/8 in),
	# lettering at least 2 mm high, lines at least 0.18 mm (0.5 pt); 17.2 cm is
	# the two-column width of the APS (REVTeX) Word template. 1.5 columns are
	# allowed but no width is published, so none is offered. Font: choice
	# (Times, the journal's text face); 9 pt gives a 2.1 mm Times capital.
	_JournalSpec(:aps, "APS (Physical Review)", [(1.0, 8.6, :cm), (2.0, 17.2, :cm)], (0.0, :mm),
		_SERIF_FONTS, 9.0, "inside", true, :box,
		"APS information for authors: 8.6 cm column, lettering >= 2 mm, lines >= 0.5 pt; 17.2 cm from the APS template"),
	# Nature research figure guide (research-figure-guide.nature.com/figures/
	# building-and-exporting-figure-panels/): single column 89 mm, double column
	# 183 mm, at most 170 mm high, Arial or Helvetica, text 5-7 pt. 7 pt is the
	# largest allowed size; open spines and outside ticks: choice.
	_JournalSpec(:nature, "Nature", [(1.0, 89.0, :mm), (2.0, 183.0, :mm)], (170.0, :mm),
		_SANS_FONTS, 7.0, "outside", false, :open,
		"Nature research figure guide: 89 mm / 183 mm, <= 170 mm high, Arial/Helvetica 5-7 pt"),
	# Elsevier artwork sizing (www.elsevier.com/about/policies-and-standards/
	# author/artwork-and-media-instructions/artwork-sizing): single column
	# 90 mm, 1.5 columns 140 mm, double column 190 mm; text at least 7 pt and
	# sub/superscripts at least 6 pt; fonts Arial, Courier, Symbol, Times. 9 pt
	# is chosen so that plotly's superscripts (70 % of the size: <sup> is
	# "font-size:70%" in plotly.js) stay >= 6 pt (6.3 pt).
	_JournalSpec(:elsevier, "Elsevier", [(1.0, 90.0, :mm), (1.5, 140.0, :mm), (2.0, 190.0, :mm)], (0.0, :mm),
		_SANS_FONTS, 9.0, "outside", false, :box,
		"Elsevier artwork sizing: 90 / 140 / 190 mm; text >= 7 pt, sub/superscripts >= 6 pt"),
	# Springer Nature instructions for authors (journal figure section, e.g.
	# Mathematics in Computer Science): "39 mm, 84 mm, 129 mm, or 174 mm wide
	# and not higher than 234 mm"; Helvetica or Arial, lettering "about 2-3 mm
	# (8-12 pt)" and consistently sized; lines at least 0.1 mm (0.3 pt). 84 mm
	# is the single column, 129 mm 1.5 and 174 mm two columns.
	_JournalSpec(:springer, "Springer", [(1.0, 84.0, :mm), (1.5, 129.0, :mm), (2.0, 174.0, :mm)], (234.0, :mm),
		"Helvetica, Arial, Liberation Sans, sans-serif", 8.0, "outside", false, :box,
		"Springer instructions for authors: 84 / 129 / 174 mm, <= 234 mm high, Helvetica/Arial 8-12 pt"),
	# AIP Publishing author instructions (publishing.aip.org/resources/
	# researchers/author-instructions/): one column 3.37 in (8.5 cm), two
	# columns 6.69 in (17 cm), at most 8.25 in deep, lettering at least 8 pt,
	# lines at least 0.5 pt, figures must read in black and white. Font:
	# choice (Times).
	_JournalSpec(:aip, "AIP Publishing", [(1.0, 3.37, :in), (2.0, 6.69, :in)], (8.25, :in),
		_SERIF_FONTS, 8.0, "inside", true, :box,
		"AIP author instructions: 3.37 in / 6.69 in, <= 8.25 in deep, lettering >= 8 pt, lines >= 0.5 pt"),
)

const _JOURNAL_NAMES = Tuple(spec.name for spec in _JOURNALS)

function _journal_spec(name, who::AbstractString)
	journal = name isa AbstractString ? Symbol(name) : name
	if journal isa Symbol
		for spec in _JOURNALS
			spec.name === journal && return spec
		end
	end
	throw(ArgumentError(
		"$(who): unknown journal $(repr(name)); journals are $(join(repr.(_JOURNAL_NAMES), ", ")).",
	))
end

# Width in CSS px (unrounded) of `columns` columns of `spec`.
function _journal_width_px(spec::_JournalSpec, columns, who::AbstractString)
	(columns isa Real && !(columns isa Bool)) ||
		throw(ArgumentError("$(who): `columns` must be a number; got $(repr(columns))."))
	for (count, value, unit) in spec.columns
		count == columns && return value * _STYLE_PX_PER_UNIT[unit]
	end
	available = join((_style_number(count) for (count, _, _) in spec.columns), ", ")
	throw(ArgumentError(
		"$(who): $(repr(spec.name)) defines figure widths for $(available) column(s); got `columns` = $(repr(columns)).",
	))
end

const _PT_PX = 96.0 / 72.0

function _journal_plot_style(spec::_JournalSpec)
	size_px = spec.fontsize_pt * _PT_PX
	return PlotStyle(
		;
		template = :plotly_white,
		font_family = spec.font_family,
		fontsize = size_px,
		title_fontsize = size_px,
		label_fontsize = size_px,
		tick_fontsize = size_px,
		legend_fontsize = size_px,
		font_color = "#000000",
		colorway = :okabe_ito,
		linewidth = 1.0 * _PT_PX,
		marker_size = 4.5 * _PT_PX,
		ticks = spec.ticks,
		spines = spec.spines,
		grid = false,
		legend_frame = false,
		margin = 4,
		mathsize = "\\large",
		cycle = :dash_symbol,
		width = _journal_width_px(spec, 1.0, "PlotStyle"),
		aspect = _STYLE_DEFAULT_ASPECT,
		axis_linewidth = 0.75 * _PT_PX,
		tick_length = 3.5 * _PT_PX,
		mirror_ticks = spec.mirror_ticks,
		errorbar_width = 0.75 * _PT_PX,
		reference_linewidth = 0.75 * _PT_PX,
		log_ticks = :decades,
	)
end

const _BUILTIN_STYLE_NAMES = (:default, :publication, _JOURNAL_NAMES...)
const _STYLE_LOCK = ReentrantLock()
const _STYLE_REGISTRY = Dict{Symbol, PlotStyle}(
	:default => _default_plot_style(),
	:publication => _publication_plot_style(),
	(spec.name => _journal_plot_style(spec) for spec in _JOURNALS)...,
)
const _ACTIVE_STYLE = Ref{PlotStyle}(_default_plot_style())

"""
	_active_style()::PlotStyle

The style constructors consult (see the internal-API comment at the top of
src/sci/style.jl). Returned by reference: internal callers must not mutate it.
"""
_active_style() = _ACTIVE_STYLE[]

function _style_lookup(style::PlotStyle, ::AbstractString)
	return style
end

function _style_lookup(name::Symbol, who::AbstractString)
	return lock(_STYLE_LOCK) do
		haskey(_STYLE_REGISTRY, name) && return _STYLE_REGISTRY[name]
		names = join(repr.(sort!(collect(keys(_STYLE_REGISTRY)))), ", ")
		throw(ArgumentError(
			"$(who): unknown style $(repr(name)); registered styles: $(names).",
		))
	end
end

function _style_with_overrides(base::PlotStyle, overrides, who::AbstractString)
	style = copy(base)
	for (name, value) in pairs(overrides)
		hasfield(PlotStyle, name) ||
			throw(ArgumentError(
				"$(who): unknown PlotStyle field `$(name)`; fields are $(join(fieldnames(PlotStyle), ", ")).",
			))
		setfield!(style, name, _style_validate_field(name, value, who))
	end
	_style_check_figure_size(style.width, style.aspect, who)
	return style
end

"""
	get_default_style()::PlotStyle

Return a copy of the active [`PlotStyle`](@ref). Mutating the copy does not
change the active style; pass it to [`set_default_style!`](@ref) to apply it.

# Example
```julia
style = get_default_style()
style.fontsize      # 0.0 under the built-in :default style
```
"""
get_default_style() = copy(_active_style())

"""
	set_default_style!(style::Union{PlotStyle,Symbol}; kwargs...)::PlotStyle
	set_default_style!(; kwargs...)::PlotStyle

Make `style` the active style used by every subsequently created figure.
`style` is a [`PlotStyle`](@ref) or the name of a registered style (`:default`,
`:publication`, a journal preset `:ieee`, `:aps`, `:nature`, `:elsevier`,
`:springer`, `:aip`, or a name given to [`register_style!`](@ref)). Keyword arguments
override individual `PlotStyle` fields on top of `style`; with no positional
argument they update fields of the current default. Everything is validated
before the active style changes, so an invalid call leaves it untouched.
Returns a copy of the new active style. Existing figures are not modified.

`set_default_style!(:default)` restores the PlotlySupply 1.x look.

# Example
```julia
set_default_style!(:publication)
set_default_style!(; tick_fontsize = 11)   # tweak one field
set_default_style!(:default)                # back to the 1.x defaults
```
"""
function set_default_style!(style::Union{PlotStyle, Symbol}; kwargs...)
	new_style = _style_with_overrides(
		_style_lookup(style, "set_default_style!"),
		kwargs,
		"set_default_style!",
	)
	lock(_STYLE_LOCK) do
		_ACTIVE_STYLE[] = new_style
	end
	return copy(new_style)
end

set_default_style!(; kwargs...) = set_default_style!(_active_style(); kwargs...)

"""
	with_style(f, style::Union{PlotStyle,Symbol}; kwargs...)
	with_style(f; kwargs...)

Run `f()` with `style` (plus keyword field overrides, validated first) as the
active style and restore the previous style afterwards, also when `f` throws.
Returns the value of `f()`. The active style is a global setting, not a
task-local one: figures created concurrently by other tasks while `f` runs also
see `style`.

# Example
```julia
fig = with_style(:publication; fontsize = 12) do
	plot_scatter(1:10, sin.(1:10); xlabel = "t", ylabel = "sin t")
end
```
"""
function with_style(f, style::Union{PlotStyle, Symbol}; kwargs...)
	new_style = _style_with_overrides(
		_style_lookup(style, "with_style"),
		kwargs,
		"with_style",
	)
	previous = lock(_STYLE_LOCK) do
		old = _ACTIVE_STYLE[]
		_ACTIVE_STYLE[] = new_style
		old
	end
	try
		return f()
	finally
		lock(_STYLE_LOCK) do
			_ACTIVE_STYLE[] = previous
		end
	end
end

with_style(f; kwargs...) = with_style(f, _active_style(); kwargs...)

"""
	register_style!(name::Symbol, style::PlotStyle)::Symbol

Register a copy of `style` under `name` so it can be selected with
`set_default_style!(name)` or `with_style(f, name)`. Re-registering a user name
replaces it; the built-in names (`:default`, `:publication` and the journal
presets `:ieee`, `:aps`, `:nature`, `:elsevier`, `:springer`, `:aip`) cannot
be redefined (`ArgumentError`). Returns `name`.

# Example
```julia
register_style!(:talk, PlotStyle(; fontsize = 18, tick_fontsize = 16, linewidth = 3))
set_default_style!(:talk)
```
"""
function register_style!(name::Symbol, style::PlotStyle)
	name in _BUILTIN_STYLE_NAMES &&
		throw(ArgumentError(
			"register_style!: $(repr(name)) is a built-in style and cannot be redefined; register the style under another name.",
		))
	stored = copy(style)
	lock(_STYLE_LOCK) do
		_STYLE_REGISTRY[name] = stored
	end
	return name
end

# ── Internal style API (see the header comment) ──────────────────────────────

function _style_template(style::PlotStyle = _active_style())
	spec = style.template
	spec === nothing && return _resolve_template(_DEFAULT_TEMPLATE[])
	return _resolve_template(spec)
end

# The template an existing figure uses: its `layout.template` when that is a
# `PlotlyBase.Template` or a registered template name, else `nothing`.
function _figure_template(fig)
	layout = fig isa PlotlyBase.Layout ? fig : _plot_layout(fig)
	value = get(layout.fields, :template, nothing)
	value isa PlotlyBase.Template && return value
	if value isa AbstractString || value isa Symbol
		name = _template_name_or_nothing(value)
		name === nothing || return _resolve_template(name)
	end
	return nothing
end

# The template the colours of something added to an EXISTING figure must match:
# the figure's own template, else (none usable) the active style's.
_figure_style_template(fig; style::PlotStyle = _active_style()) =
	something(_figure_template(fig), _style_template(style))

# Legend box for a legend that a mutator creates on an existing figure: the
# style's frame choice in the colours of the figure's template (a dark box on
# a plotly_dark figure). Splat into `_apply_default_legend!(fig; ...)`.
_figure_legend_defaults(fig; style::PlotStyle = _active_style()) =
	_style_legend_defaults(style; template = _figure_style_template(fig; style = style))

# Font of a legend created after the figure was built (e.g. a SubplotFigure's
# per-cell `legend2`…): the style's legend size, which `_apply_style_layout!`
# wrote only onto the legends that existed at construction. Empty when the
# style leaves the legend size unset (`:default`), so 1.x output is unchanged.
# Merge it into the new legend's `font`.
_style_legend_font(style::PlotStyle = _active_style()) =
	style.legend_fontsize > 0 ? Dict{Symbol, Any}(:size => style.legend_fontsize) : Dict{Symbol, Any}()

# Frame of a Cartesian axis that is added to an existing figure (a twin or
# secondary axis): `_style_axis_defaults` in the ink of the figure's template.
_figure_axis_defaults(fig; axis::Symbol = :x, style::PlotStyle = _active_style()) =
	_style_axis_defaults(style; template = _figure_style_template(fig; style = style), axis = axis)

# Whether a template specification (as stored in `PlotStyle.template` or
# `_DEFAULT_TEMPLATE`) is one of plotly's built-in templates or a `+`
# compound of them. `nothing` means the package default template.
function _template_spec_is_builtin(spec)
	spec === nothing && return _template_spec_is_builtin(_DEFAULT_TEMPLATE[])
	if spec isa PlotlyBase.Template
		# A built-in Template object can only come from `PlotlyBase.templates[name]`,
		# which caches it in the (lazily filled) `templates.templates` dict; looking
		# there avoids loading every built-in template from disk.
		loaded = PlotlyBase.templates.templates
		return any(name -> get(loaded, name, missing) === spec, _STYLE_BUILTIN_TEMPLATES)
	end
	parts = Symbol.(strip.(split(String(spec), '+')))
	return all(in(_STYLE_BUILTIN_TEMPLATES), parts)
end

_style_template_is_builtin(style::PlotStyle) = _template_spec_is_builtin(style.template)

function _style_axis_defaults(
	style::PlotStyle = _active_style();
	template::PlotlyBase.Template = _style_template(style),
	axis::Symbol = :x,
)
	axis in (:x, :y) ||
		throw(ArgumentError("_style_axis_defaults: `axis` must be :x or :y; got $(repr(axis))."))
	ink = _template_ink(template)
	boxed = style.spines === :box
	defaults = Dict{Symbol, Any}(
		:zeroline => false,
		:showline => style.spines !== :none,
		# plotly's mirror = "ticks" draws the opposite spine with tick marks.
		:mirror => boxed && style.mirror_ticks && !isempty(style.ticks) ? "ticks" : boxed,
		:ticks => style.ticks,
		:automargin => true,
		:linecolor => ink,
		:linewidth => style.axis_linewidth > 0 ? _style_number(style.axis_linewidth) : _DEFAULT_AXIS_LINEWIDTH,
		:tickcolor => ink,
	)
	if style.axis_linewidth > 0
		defaults[:tickwidth] = _style_number(style.axis_linewidth)
		style.grid && (defaults[:gridwidth] = _style_number(style.axis_linewidth))
	end
	style.tick_length > 0 && (defaults[:ticklen] = _style_number(style.tick_length))
	style.grid || (defaults[:showgrid] = false)
	if !_style_template_is_builtin(style)
		template_axis = _symbol_dict(get(
			_template_layout_fields(template),
			axis === :x ? :xaxis : :yaxis,
			nothing,
		))
		for key in (:ticks, :mirror)
			haskey(template_axis, key) && delete!(defaults, key)
		end
	end
	return defaults
end

function _style_legend_defaults(
	style::PlotStyle = _active_style();
	template::PlotlyBase.Template = _style_template(style),
)
	if !style.legend_frame
		return (
			bgcolor = "rgba(0,0,0,0)",
			bordercolor = "rgba(0,0,0,0)",
			borderwidth = 0.0,
		)
	end
	colors = _template_legend_colors(template)
	return (
		bgcolor = colors.bgcolor,
		bordercolor = colors.bordercolor,
		borderwidth = Float64(_DEFAULT_LEGEND_BORDERWIDTH[]),
	)
end

function _style_layout_defaults(
	style::PlotStyle = _active_style();
	template::PlotlyBase.Template = _style_template(style),
)
	defaults = Dict{Symbol, Any}()
	font = Dict{Symbol, Any}()
	isempty(style.font_family) || (font[:family] = style.font_family)
	style.fontsize > 0 && (font[:size] = _style_number(style.fontsize))
	isempty(style.font_color) || (font[:color] = style.font_color)
	isempty(font) || (defaults[:font] = font)
	if style.cycle in _STYLE_INK_CYCLES
		# Every trace without an explicit colour is drawn in the template's ink.
		# A one-colour colorway (rather than per-trace colours) keeps the colour
		# a template-derived layout value that `set_template!` can re-derive.
		defaults[:colorway] = String[_template_ink(template)]
	elseif style.colorway !== nothing
		defaults[:colorway] = copy(style.colorway)
	end
	if style.margin !== nothing
		defaults[:margin] = Dict{Symbol, Any}(
			key => _style_number(value) for (key, value) in style.margin
		)
	end
	return defaults
end

function _style_trace_defaults(style::PlotStyle, trace_index::Integer)
	trace_index >= 1 ||
		throw(ArgumentError("_style_trace_defaults: `trace_index` must be >= 1; got $(trace_index)."))
	defaults = Dict{Symbol, Any}()
	style.linewidth > 0 && (defaults[:linewidth] = _style_number(style.linewidth))
	style.marker_size > 0 && (defaults[:marker_size] = _style_number(style.marker_size))
	style.errorbar_width > 0 && (defaults[:errorbar_width] = _style_number(style.errorbar_width))
	cycle = style.cycle
	if cycle in _STYLE_DASH_CYCLES
		defaults[:dash] = _STYLE_DASH_CYCLE[mod1(trace_index, length(_STYLE_DASH_CYCLE))]
	end
	if cycle in _STYLE_SYMBOL_CYCLES
		defaults[:marker_symbol] =
			_STYLE_MARKER_CYCLE[mod1(trace_index, length(_STYLE_MARKER_CYCLE))]
		cycle in _STYLE_MARKER_FLAG_CYCLES && (defaults[:markers] = true)
	end
	return defaults
end

_style_mathsize(style::PlotStyle = _active_style()) = style.mathsize

# Trace types whose `line.dash`, `line.width`, `marker.symbol`, `marker.size`
# and `mode` (flags lines/markers/text) have the scatter meaning (plotly.js
# 2.35 schema). Map scatter types are excluded: they have no `line.dash`, and
# their `marker.symbol` names map icons.
const _STYLE_LINE_TRACE_TYPES = Set{String}([
	"scatter",
	"scattergl",
	"scatterpolar",
	"scatterpolargl",
	"scatter3d",
	"scatterternary",
	"scattersmith",
	"scattercarpet",
	"scattergeo",
])

# scatter3d accepts only these eight marker symbols (plotly.js 2.35 schema);
# the order keeps the first four of `_STYLE_MARKER_CYCLE`'s shapes where they
# exist in 3-D.
const _STYLE_MARKER_CYCLE_3D = (
	"circle",
	"square",
	"diamond",
	"x",
	"cross",
	"circle-open",
	"square-open",
	"diamond-open",
)

# The keyword names `explicit` may list in `_apply_style_trace_defaults!`.
const _STYLE_TRACE_DEFAULT_KEYWORDS = (:linewidth, :marker_size, :dash, :marker_symbol, :mode)

# Number of line-style traces that precede the figure `_apply_style_trace_defaults!`
# is called on. Non-zero only inside `_with_style_trace_offset`, i.e. while a
# trace builder runs on a temporary figure whose traces are appended to a
# larger one afterwards (the SubplotFigure delegate). A ScopedValue, so
# concurrent tasks never see each other's offset.
const _STYLE_TRACE_OFFSET = Base.ScopedValues.ScopedValue(0)

"""
	_with_style_trace_offset(f, fig)

Run `f()` with the style cycle offset by the number of line-style traces
already in `fig` (a `Plot`, `SyncPlot`, `SubplotFigure` or staged target), and
return its value. Internal; for code that builds traces on a temporary figure
and then appends them to `fig` (the `plot_*!(sf::SubplotFigure, …)` delegate
builds into an empty `Plot`): calls to [`_apply_style_trace_defaults!`](@ref)
inside `f` then continue the dash/marker cycle of `fig` instead of restarting
it at 1.

```julia
_with_style_trace_offset(target_plot) do
	mutator(_StagedPlotMutation(tmp), args...; kwargs...)
end
```
"""
function _with_style_trace_offset(f, fig)
	offset = count(_style_is_line_trace, _plot_obj(fig).data)
	return Base.ScopedValues.with(f, _STYLE_TRACE_OFFSET => offset)
end

function _style_trace_type(trace::GenericTrace)
	value = get(trace.fields, :type, "scatter")
	return value isa Union{AbstractString, Symbol} ? String(value) : ""
end

# Only `GenericTrace`s carry plotly attributes PlotlySupply can read; any other
# `AbstractTrace` subtype in a figure's data is never styled or counted.
_style_is_line_trace(trace) =
	trace isa GenericTrace && _style_trace_type(trace) in _STYLE_LINE_TRACE_TYPES

# A trace attribute the constructor left at its "not set" sentinel.
_style_value_unset(value) =
	value === nothing || value === missing || (value isa AbstractString && isempty(value))

"""
	_apply_style_trace_defaults!(fig, trace_indices; style = _active_style(), explicit = ())

Fill the per-trace defaults of `style` (the active [`PlotStyle`](@ref) unless
given) into the traces of `fig` at `trace_indices`, wherever the trace leaves
them unset. Internal; for the trace constructors and their `!` mutators.

# Arguments
- `fig`: a `Plot`, `SyncPlot`, `SubplotFigure` or staged mutation target. Only
  the model is written (no renderer refresh), so call it while building the
  traces: in a constructor before the figure is returned or shown, in a
  mutator inside its transaction before `_refresh!`.
- `trace_indices`: an `Integer` or a collection of 1-based positions in the
  figure's data, normally exactly the traces the calling function just added
  (an empty collection does nothing). A position that is not an integer
  (`Bool` included) or not in `1:length(data)` throws an `ArgumentError`
  before anything is written; repeated positions are styled once.
- `style::PlotStyle`: the style whose `linewidth`, `marker_size`, `cycle` and
  `errorbar_width` are applied.
- `explicit`: a `Symbol` or a collection of the caller's keyword names that the
  user passed, from `(:linewidth, :marker_size, :dash, :marker_symbol, :mode)`;
  any other name throws an `ArgumentError`. A listed keyword is never filled,
  even where its trace value is a sentinel (needed for `mode`, whose 1.x
  default `"lines"` cannot be told apart from an explicit `"lines"`).

# Which traces and attributes
Only `GenericTrace`s whose `type` (absent means `"scatter"`) is one of the
line-style types `scatter`, `scattergl`, `scatterpolar`, `scatterpolargl`,
`scatter3d`, `scatterternary`, `scattersmith`, `scattercarpet` and
`scattergeo` are styled; every one of them has `line.width`, `line.dash`,
`marker.size`, `marker.symbol` and `mode` in the plotly.js 2.35 schema, and
the values written are in each type's allowed set. Three more roles are
filled on these and other trace types:

- contour lines: `line.width` ← `style.linewidth` on `contour`,
  `histogram2dcontour` and `contourcarpet` traces whose `contours.coloring`
  is `"lines"` or `"none"` (the lines are the data; filled contours keep
  plotly's thin level boundaries);
- error bars: `thickness` ← `style.errorbar_width` in every `error_x`/`error_y`
  (and `error_z` on `scatter3d`) container a `scatter`, `scattergl`, `bar`,
  `histogram` or `scatter3d` trace already has, unless the bars are hidden
  (`visible = false`). No error-bar container is created.

- colorbars: the colorbar a trace draws itself (trace-level `colorbar` of a
  colorbar trace type — heatmap, contour, surface, mesh3d, … — and
  `marker.colorbar`/`line.colorbar` where `showscale = true`; not a trace
  bound to a layout `coloraxis`) gets `tickfont.size` ← `style.tick_fontsize`,
  `title.font.size` ← `style.label_fontsize`, and, when the style sets
  `axis_linewidth`/`tick_length`, the outline and ticks of the axes
  (`outlinewidth`, `ticks`, `tickwidth`, `ticklen`; no colour, so a later
  `set_template!` leaves nothing stale). Construction gets the same through
  `_apply_style_layout!`; this reaches colorbars added later.

Every other trace and attribute (box, violin, pie, the map scatter types,
non-`GenericTrace` traces, …) is skipped and never written, so no attribute is
ever added to a trace type that lacks it.

A value counts as unset when the attribute is absent, `nothing`, `missing` or
`""` (the 1.x `line.dash = ""` sentinel); any other value — a number, a name,
a per-point vector — is the caller's and is kept. Filled where unset:

- `line.width` ← `style.linewidth`, `marker.size` ← `style.marker_size`
  (each only when the style sets it, i.e. > 0);
- `line.dash` ← the dash cycle `solid, dash, dot, dashdot` (`cycle` `:bw`,
  `:dash`, `:dash_marker`, `:dash_symbol`, `:bw_dash_marker`);
- `marker.symbol` ← the marker cycle (`:marker`, `:dash_marker`,
  `:dash_symbol`, `:bw_dash_marker`):
  `circle, square, diamond, triangle-up, x, triangle-down, cross, star`, and
  for `scatter3d` (which accepts only eight symbols) `circle, square,
  diamond, x, cross, circle-open, square-open, diamond-open`. When the symbol
  is filled by `:marker`, `:dash_marker` or `:bw_dash_marker` and `mode` (a
  string or `Symbol`, not in `explicit`) draws lines but no markers, the
  `markers` flag is added so the symbol shows (`"lines"` → `"lines+markers"`,
  `"lines+text"` → `"lines+markers+text"`); `:dash_symbol` never adds it.
  An absent `mode` is left to plotly's own default.

The cycle position of a trace is its rank among the figure's line-style traces
(1 for the first), so the cycle continues across `plot_*!` appends and skips
non-line traces; inside [`_with_style_trace_offset`](@ref) the line-style
traces of the outer figure are counted too. Colour is never set here: the
`:bw` cycle's single ink colour is the figure colorway (written by
`_apply_default_template!`).

# Guarantees
- Idempotent: a second call with the same arguments changes nothing (every
  value it would fill is now set).
- Atomic: all updates are computed (and every `line`/`marker` value checked to
  be an attribute container, else `ArgumentError`) before the first write.
- Nested `line`/`marker` containers are replaced, never mutated in place, so a
  container shared between traces or with the caller is not changed.
- Under a style with no trace defaults (`:default`: `linewidth = 0`,
  `marker_size = 0`, `errorbar_width = 0`, `cycle = :none`, no font sizes,
  no axis line weights) nothing is touched.

Returns `nothing`.

# Example
Call it after the traces are in the figure and before the figure is returned
(constructor) or refreshed (mutator):

```julia
first_new = length(_plot_data(fig)) + 1
push!(_plot_data(fig), traces...)
# `mode` defaults to "lines" in the signature, so say when the caller chose it.
_apply_style_trace_defaults!(fig, first_new:length(_plot_data(fig));
	explicit = haskey(kwargs, :mode) ? (:mode,) : ())
```
"""
function _apply_style_trace_defaults!(
	fig,
	trace_indices;
	style::PlotStyle = _active_style(),
	explicit = (),
)
	who = "_apply_style_trace_defaults!"
	explicit_names = explicit isa Symbol ? (explicit,) : explicit
	for name in explicit_names
		name in _STYLE_TRACE_DEFAULT_KEYWORDS ||
			throw(ArgumentError(
				"$(who): `explicit` entries must be among $(_STYLE_TRACE_DEFAULT_KEYWORDS); got $(repr(name)).",
			))
	end
	data = _plot_obj(fig).data
	indices = trace_indices isa Integer ? (trace_indices,) : trace_indices
	for index in indices
		(index isa Integer && !(index isa Bool) && 1 <= index <= length(data)) ||
			throw(ArgumentError(
				"$(who): trace index $(repr(index)) is not in 1:$(length(data)).",
			))
	end
	# Nothing to do for a style without trace defaults (`:default`).
	plain_defaults = _style_trace_defaults(style, 1)
	colorbar_defaults = _style_colorbar_trace_defaults(style)
	isempty(plain_defaults) && isempty(colorbar_defaults) && return nothing

	# All updates are computed first, then committed.
	pending = Tuple{Int, Dict{Symbol, Any}}[]
	offset = _STYLE_TRACE_OFFSET[]
	for index in unique(indices)
		trace = data[index]
		trace isa GenericTrace || continue
		where = "$(who): data[$(index)]"
		updates = Dict{Symbol, Any}()
		if _style_is_line_trace(trace)
			position = offset + count(_style_is_line_trace, view(data, 1:index))
			merge!(updates, _style_trace_default_updates(
				trace,
				_style_trace_defaults(style, position),
				position,
				explicit_names,
				where,
			))
		elseif _style_trace_type(trace) in _STYLE_CONTOUR_TRACE_TYPES
			merge!(updates, _style_contour_default_updates(trace, plain_defaults, explicit_names, where))
		end
		merge!(updates, _style_errorbar_default_updates(trace, plain_defaults, where))
		# Built on top of the marker/line updates above (same containers).
		merge!(updates, _style_colorbar_default_updates(trace, updates, colorbar_defaults, where))
		isempty(updates) || push!(pending, (Int(index), updates))
	end
	for (index, updates) in pending
		fields = data[index].fields
		for (key, value) in updates
			fields[key] = value
		end
	end
	return nothing
end

# Colorbar defaults of `style` for a trace: the tick-label and title sizes
# `_apply_style_layout!` gives colorbars at construction (`tick_fontsize`,
# `label_fontsize`) and the axis-like outline and ticks
# (`_style_colorbar_line_defaults`).
function _style_colorbar_trace_defaults(style::PlotStyle)
	defaults = Dict{Symbol, Any}()
	style.tick_fontsize > 0 &&
		(defaults[:tickfont] = Dict{Symbol, Any}(:size => _style_number(style.tick_fontsize)))
	style.label_fontsize > 0 &&
		(defaults[:title] = Dict{Symbol, Any}(:font => Dict{Symbol, Any}(:size => _style_number(style.label_fontsize))))
	merge!(defaults, _style_colorbar_line_defaults(style))
	return defaults
end

# Fill `defaults` into the colorbars a trace draws itself: the trace-level
# `colorbar` of a colorbar trace type, and `marker.colorbar`/`line.colorbar`
# where that scale is shown. A trace bound to a layout `coloraxis` has its
# colorbar there and is skipped (the coloraxis is styled at construction).
# `pending` holds this trace's updates computed so far, which are built on.
function _style_colorbar_default_updates(trace, pending, defaults, who::AbstractString)
	updates = Dict{Symbol, Any}()
	isempty(defaults) && return updates
	fields = trace.fields
	current(key) = haskey(pending, key) ? pending[key] : get(fields, key, nothing)
	bound(d) = !isempty(_style_ref_string(get(d, :coloraxis, nothing)))
	if _style_trace_type(trace) in _STYLE_TRACE_COLORBAR_TYPES && !bound(fields)
		filled, changed = _style_fill_nested(current(:colorbar), defaults, "colorbar", who)
		changed && (updates[:colorbar] = filled)
	end
	for sub in (:marker, :line)
		value = current(sub)
		(value isa AbstractDict || value isa PlotlyBase.PlotlyAttribute) || continue
		d = _symbol_dict(value)
		(get(d, :showscale, false) === true || haskey(d, :colorbar)) || continue
		bound(d) && continue
		filled, changed = _style_fill_nested(value, Dict{Symbol, Any}(:colorbar => defaults), String(sub), who)
		changed && (updates[sub] = filled)
	end
	return updates
end

# Contour trace types (plotly.js 2.35) whose `line.width` draws the contour
# lines; with `contours.coloring` "lines" or "none" those lines are the data.
const _STYLE_CONTOUR_TRACE_TYPES = Set{String}(["contour", "histogram2dcontour", "contourcarpet"])

# Trace types with error bars (plotly.js 2.35 schema: `error_x`/`error_y`,
# plus `error_z` on scatter3d).
const _STYLE_ERRORBAR_TRACE_TYPES = Dict{String, Tuple{Vararg{Symbol}}}(
	"scatter" => (:error_x, :error_y),
	"scattergl" => (:error_x, :error_y),
	"bar" => (:error_x, :error_y),
	"histogram" => (:error_x, :error_y),
	"scatter3d" => (:error_x, :error_y, :error_z),
)

# `line.width` of a line contour (Y22): the style's line width, as matplotlib's
# `contour.linewidth` falls back to `lines.linewidth`. Filled contours keep
# plotly's thin level boundaries (the fill is the data); so does a trace whose
# `contours.coloring` is not a plain string.
function _style_contour_default_updates(trace, defaults, explicit, who::AbstractString)
	(haskey(defaults, :linewidth) && !(:linewidth in explicit)) || return Dict{Symbol, Any}()
	fields = trace.fields
	contours = _style_container_dict(get(fields, :contours, nothing), "contours", who)
	coloring = get(contours, :coloring, "fill")
	(coloring isa Union{AbstractString, Symbol} && String(coloring) in ("lines", "none")) ||
		return Dict{Symbol, Any}()
	line = _style_container_dict(get(fields, :line, nothing), "line", who)
	_style_value_unset(get(line, :width, nothing)) || return Dict{Symbol, Any}()
	return Dict{Symbol, Any}(
		:line => _style_update_path(get(fields, :line, nothing), (), Dict(:width => defaults[:linewidth]), "line", who),
	)
end

# `thickness` of every error-bar container the trace already has (none is
# created), where it is unset and the bars are not hidden (`visible = false`).
function _style_errorbar_default_updates(trace, defaults, who::AbstractString)
	updates = Dict{Symbol, Any}()
	haskey(defaults, :errorbar_width) || return updates
	keys_for_type = get(_STYLE_ERRORBAR_TRACE_TYPES, _style_trace_type(trace), ())
	fields = trace.fields
	for key in keys_for_type
		container = get(fields, key, nothing)
		container === nothing && continue
		bars = _style_container_dict(container, String(key), who)
		(isempty(bars) || get(bars, :visible, true) === false) && continue
		_style_value_unset(get(bars, :thickness, nothing)) || continue
		updates[key] = _style_update_path(container, (), Dict(:thickness => defaults[:errorbar_width]), String(key), who)
	end
	return updates
end

# Field updates (`:line`, `:marker`, `:mode`) that fill `defaults` into one
# line-style trace where it leaves them unset.
function _style_trace_default_updates(trace, defaults, position::Integer, explicit, who::AbstractString)
	fields = trace.fields
	line = _style_container_dict(get(fields, :line, nothing), "line", who)
	marker = _style_container_dict(get(fields, :marker, nothing), "marker", who)
	fillable(d, key, name) =
		haskey(defaults, name) && !(name in explicit) && _style_value_unset(get(d, key, nothing))
	line_updates = Dict{Symbol, Any}()
	marker_updates = Dict{Symbol, Any}()
	fillable(line, :width, :linewidth) && (line_updates[:width] = defaults[:linewidth])
	fillable(line, :dash, :dash) && (line_updates[:dash] = defaults[:dash])
	fillable(marker, :size, :marker_size) && (marker_updates[:size] = defaults[:marker_size])
	symbol_filled = fillable(marker, :symbol, :marker_symbol)
	if symbol_filled
		marker_updates[:symbol] = _style_trace_type(trace) == "scatter3d" ?
			_STYLE_MARKER_CYCLE_3D[mod1(position, length(_STYLE_MARKER_CYCLE_3D))] :
			defaults[:marker_symbol]
	end
	updates = Dict{Symbol, Any}()
	isempty(line_updates) ||
		(updates[:line] = _style_update_path(get(fields, :line, nothing), (), line_updates, "line", who))
	isempty(marker_updates) ||
		(updates[:marker] = _style_update_path(get(fields, :marker, nothing), (), marker_updates, "marker", who))
	# The cycle's symbol must be visible: a mode that draws lines but no
	# markers gets the markers flag (only when this call chose the symbol).
	mode = get(fields, :mode, nothing)
	if symbol_filled && get(defaults, :markers, false) === true && !(:mode in explicit) &&
	   mode isa Union{AbstractString, Symbol}
		flags = split(String(mode), '+')
		if "lines" in flags && !("markers" in flags)
			updates[:mode] = join((flag == "lines" ? "lines+markers" : flag for flag in flags), '+')
		end
	end
	return updates
end

function _apply_style_layout!(
	fig,
	style::PlotStyle = _active_style();
	template::PlotlyBase.Template = _style_template(style),
)
	p = _plot_obj(fig)
	fields = p.layout.fields
	updates = Dict{Symbol, Any}()
	for (key, value) in _style_layout_defaults(style; template = template)
		key === :margin && continue
		updates[key] = value isa AbstractDict ?
			_style_update_path(get(fields, key, nothing), (), value, "layout.$(key)", "PlotStyle") :
			value
	end
	roles = _FontRoles(
		"",
		0.0,
		"",
		style.title_fontsize,
		style.label_fontsize,
		style.tick_fontsize,
		style.legend_fontsize,
		0.0,
		0.0,
	)
	# Every value is computed against the layout as it will be after the
	# earlier updates, then everything is committed together.
	role_layout, role_traces = _font_role_updates(
		p,
		roles,
		nothing,
		"PlotStyle";
		base = updates,
		colorbar_lines = _style_colorbar_line_defaults(style),
	)
	merge!(updates, role_layout)
	# Line weights of 3-D, polar and ternary axes (Cartesian axes get theirs
	# from `_style_axis_defaults`).
	axis_lines = _style_axis_line_defaults(style)
	if !isempty(axis_lines)
		for key in _style_figure_axis_keys(p)
			name = String(key)
			subaxes = occursin(r"^scene\d*$", name) ? (:xaxis, :yaxis, :zaxis) :
				occursin(r"^polar\d*$", name) ? (:radialaxis, :angularaxis) :
				occursin(r"^ternary\d*$", name) ? (:aaxis, :baxis, :caxis) : ()
			isempty(subaxes) && continue
			current = haskey(updates, key) ? updates[key] : get(fields, key, nothing)
			filled, changed = _style_fill_nested(
				current,
				Dict{Symbol, Any}(axis => axis_lines for axis in subaxes),
				"layout.$(key)",
				"PlotStyle",
			)
			changed && (updates[key] = filled)
		end
	end
	if style.margin !== nothing
		# The style margin is the minimum on each side; paper-referenced
		# annotations (subplot titles) and the title get the room they need on
		# top of it, exactly as `tight_layout!` computes it. The title gets
		# `automargin=true` even before it has text, so a title set later fits.
		margin, title = _fit_margin_updates(
			p,
			style.margin,
			"PlotStyle";
			pending = updates,
			always_automargin = true,
		)
		updates[:margin] = margin
		title === nothing || (updates[:title] = title)
	end
	merge!(updates, _style_figure_size_updates(fields, style))
	for (key, value) in updates
		fields[key] = value
	end
	_commit_trace_updates!(p, role_traces)
	return nothing
end

# A layout width/height the figure already has (a positive number; anything
# else, including an absent key or `nothing`, counts as unset).
_style_size_is_set(value) = value isa Real && !(value isa Bool) && isfinite(value) && value > 0

_style_aspect(style::PlotStyle) = style.aspect > 0 ? style.aspect : _STYLE_DEFAULT_ASPECT

# layout.width/height written by a sized style (`width > 0`) into a new
# figure: both when the figure has neither; the height that keeps the style's
# aspect when only a width was given; the style's width when only a height was
# given. A size the caller gave is never changed. Heights are clamped to
# plotly's accepted range (only reachable with an extreme `aspect`).
function _style_figure_size_updates(fields, style::PlotStyle)
	updates = Dict{Symbol, Any}()
	style.width > 0 || return updates
	has_width = _style_size_is_set(get(fields, :width, nothing))
	has_height = _style_size_is_set(get(fields, :height, nothing))
	has_width && has_height && return updates
	width, height = _style_default_figure_size(style)
	if has_width
		height = clamp(Float64(fields[:width]) * _style_aspect(style), _STYLE_MIN_FIGURE_PX, _STYLE_MAX_FIGURE_PX)
	else
		updates[:width] = _style_number(width)
	end
	has_height || (updates[:height] = _style_number(height))
	return updates
end

# Colorbar outline and tick marks drawn like the axes: the spine width, the
# style's tick direction and length. Empty unless the style sets
# `axis_linewidth` / `tick_length` (not `:default` or `:publication`), so
# plotly's own colorbar look is kept there. No colour is written: colorbars
# live on traces, which `set_template!` (a layout-only mutation) cannot
# re-derive, so they keep plotly's template-independent "#444".
function _style_colorbar_line_defaults(style::PlotStyle)
	defaults = Dict{Symbol, Any}()
	if style.axis_linewidth > 0
		width = _style_number(style.axis_linewidth)
		defaults[:outlinewidth] = width
		defaults[:ticks] = style.ticks
		defaults[:tickwidth] = width
	end
	style.tick_length > 0 && (defaults[:ticklen] = _style_number(style.tick_length))
	return defaults
end

# Line weights for one 3-D/polar/ternary axis: spine, tick and grid width and
# tick length. Tick direction and spine visibility stay with the code that
# builds those axes.
function _style_axis_line_defaults(style::PlotStyle)
	defaults = Dict{Symbol, Any}()
	if style.axis_linewidth > 0
		width = _style_number(style.axis_linewidth)
		defaults[:linewidth] = width
		defaults[:tickwidth] = width
		defaults[:gridwidth] = width
	end
	style.tick_length > 0 && (defaults[:ticklen] = _style_number(style.tick_length))
	return defaults
end

# Fill `defaults` (nested Dicts are sub-containers) into `container` wherever
# it leaves a value unset (`_style_value_unset`). Returns `(new, changed)`;
# `new` is `container` itself when nothing changed, else a fresh container
# (shared containers are never mutated).
function _style_fill_nested(container, defaults::AbstractDict, where::AbstractString, who::AbstractString)
	isempty(defaults) && return (container, false)
	d = _style_container_dict(container, where, who)
	changed = false
	for (key, value) in defaults
		if value isa AbstractDict
			sub, sub_changed = _style_fill_nested(get(d, key, nothing), value, "$(where).$(key)", who)
			if sub_changed
				d[key] = sub
				changed = true
			end
		elseif _style_value_unset(get(d, key, nothing))
			d[key] = value
			changed = true
		end
	end
	return changed ? (_style_wrap_like(container, d), true) : (container, false)
end

"""
	_style_default_figure_size(style::PlotStyle = _active_style()) -> Tuple{Float64,Float64}

`(width, height)` in CSS px (unrounded) of a figure that has no
`layout.width`/`layout.height`: the style's `width` and `width * aspect`
(`aspect` 0 means 0.75) when the style sets a width (every journal preset:
its single column), else the 1.x export default 700 × 500 px. Internal; the
export fallback for figures without a size (`savefig`) and the size
`_apply_style_layout!` writes into figures built under a sized style.
"""
function _style_default_figure_size(style::PlotStyle = _active_style())
	style.width > 0 || return (_DEFAULT_EXPORT_WIDTH_PX, _DEFAULT_EXPORT_HEIGHT_PX)
	return (style.width, style.width * _style_aspect(style))
end

"""
	_style_log_ticks(style::PlotStyle = _active_style()) -> Symbol

The style's rule for logarithmic axes without a user tick setting (lead
decision D15, rule 2): `:decades` (decade labels only on an axis spanning two
decades or more; `:publication` and the journal presets) or `:auto` (plotly's
adaptive labels). Reads `PlotStyle.log_ticks`. Internal; `_axes_log_tick_updates!` (src/sci/axes.jl) applies it.
"""
_style_log_ticks(style::PlotStyle = _active_style()) = style.log_ticks

"""
	_style_ink(fig) -> String

Colour of the lines PlotlySupply draws on its own in `fig` (reference lines,
outlines, arrows): the ink of the figure's template (`_template_ink`: black
on light templates, the template's light text colour on dark ones), else of
the active style's template. Internal.
"""
_style_ink(fig) = _template_ink(_figure_style_template(fig))

# Line roles `_style_line_width` knows, and the PlotStyle field each reads.
const _STYLE_LINE_ROLES = (
	data = :linewidth,
	contour = :linewidth,
	mesh = :linewidth,
	reference = :reference_linewidth,
	axis = :axis_linewidth,
	errorbar = :errorbar_width,
)

"""
	_style_line_width(role::Symbol; default::Real, style::PlotStyle = _active_style()) -> Float64

Width in px of a line of `role` under `style`, or `default` when the style
leaves the role unset (its field is 0). Roles: `:data` (trace lines,
`linewidth`), `:contour` and `:mesh` (contour lines and mesh edges, also
`linewidth`), `:reference` (reference lines and shapes,
`reference_linewidth`), `:axis` (spines, ticks, grid, `axis_linewidth`) and
`:errorbar` (`errorbar_width`). An unknown role or a `default` that is not a
finite number >= 0 throws an `ArgumentError`. Internal; for code that draws
lines the trace and axis defaults do not reach (shapes, mesh edges).
"""
function _style_line_width(role::Symbol; default::Real, style::PlotStyle = _active_style())
	who = "_style_line_width"
	haskey(_STYLE_LINE_ROLES, role) ||
		throw(ArgumentError(
			"$(who): unknown line role $(repr(role)); roles are $(join(repr.(keys(_STYLE_LINE_ROLES)), ", ")).",
		))
	fallback = _style_nonnegative(default, who, "default")
	width = getfield(style, _STYLE_LINE_ROLES[role])
	return width > 0 ? width : fallback
end

# ── Nested attribute updates (never mutate shared containers) ───────────────

# A fresh Dict{Symbol,Any} copy of an attribute container. A bare string at a
# `title` position is plotly's short form of `title.text`.
function _style_container_dict(container, where::AbstractString, who::AbstractString)
	container === nothing && return Dict{Symbol, Any}()
	if container isa PlotlyBase.PlotlyAttribute || container isa AbstractDict
		return _symbol_dict(container)
	end
	if container isa AbstractString && endswith(where, "title")
		return Dict{Symbol, Any}(:text => String(container))
	end
	throw(ArgumentError(
		"$(who): `$(where)` is a $(typeof(container)), expected an attribute container.",
	))
end

# Re-wrap updated contents in the original container kind. Bare-string titles
# become `attr(text=…)`, the canonical 2.0 title form.
function _style_wrap_like(original, d::Dict{Symbol, Any})
	if original isa PlotlyBase.PlotlyAttribute || original isa AbstractString
		return PlotlyBase.PlotlyAttribute(d)
	end
	return Dict{Any, Any}(d)
end

function _style_update_path(
	container,
	path::Tuple{Vararg{Symbol}},
	updates::AbstractDict,
	where::AbstractString,
	who::AbstractString,
)
	d = _style_container_dict(container, where, who)
	if isempty(path)
		for (key, value) in updates
			d[Symbol(key)] = value
		end
	else
		key = first(path)
		d[key] = _style_update_path(
			get(d, key, nothing),
			Base.tail(path),
			updates,
			where * "." * String(key),
			who,
		)
	end
	return _style_wrap_like(container, d)
end

# ── Font roles (shared by set_fonts! and _apply_style_layout!) ──────────────

struct _FontRoles
	family::String
	size::Float64
	color::String
	title::Float64
	label::Float64
	tick::Float64
	legend::Float64
	colorbar::Float64
	annotation::Float64
end

# The subplot cell targeted by `set_fonts!(sf; row, col)`. `trace_refs` holds,
# per subplot of the cell, its kind ("xy", "scene", "polar", …) and the trace
# keywords that place a trace in it.
struct _StyleCell
	row::Int
	col::Int
	layout_keys::Vector{Symbol}
	trace_refs::Vector{Tuple{String, Dict{Symbol, Any}}}
	xrefs::Set{String}
	yrefs::Set{String}
end

# A subplot reference value as a string; "" for anything that is not one.
_style_ref_string(value) = value isa Union{AbstractString, Symbol} ? String(value) : ""

# Trace types with a trace-level `colorbar` (plotly.js 2.35 schema, plus the
# MapLibre `*map` types added in 2.35).
const _STYLE_TRACE_COLORBAR_TYPES = Set{String}([
	"choropleth",
	"choroplethmap",
	"choroplethmapbox",
	"cone",
	"contour",
	"contourcarpet",
	"densitymap",
	"densitymapbox",
	"heatmap",
	"heatmapgl",
	"histogram2d",
	"histogram2dcontour",
	"isosurface",
	"mesh3d",
	"streamtube",
	"surface",
	"volume",
])

const _STYLE_PANEL_TITLE_NAME = r"^plotlysupply:title!?:(\d+):(\d+)(:.*)?$"
const _STYLE_CELL_ITEM_NAME = r"^plotlysupply:[^:]+:(\d+):(\d+)(:.*)?$"
const _STYLE_FIGURE_LABEL_NAME = r"^plotlysupply:[xy]_title$"

# Font dict for one element. Figure-wide calls write only role sizes (family,
# base size and colour go to layout.font and cascade); cell-scoped calls write
# family/colour and fall back to the base size, because a cell has no font of
# its own to cascade from.
function _role_font(roles::_FontRoles, role_size::Float64, in_cell::Bool)
	font = Dict{Symbol, Any}()
	size = role_size > 0 ? role_size : (in_cell ? roles.size : 0.0)
	size > 0 && (font[:size] = _style_number(size))
	if in_cell
		isempty(roles.family) || (font[:family] = roles.family)
		isempty(roles.color) || (font[:color] = roles.color)
	end
	return font
end

function _style_trace_kind(fields)
	type_value = get(fields, :type, "scatter")
	(type_value isa AbstractString || type_value isa Symbol) || return ""
	kind_symbol = Symbol(type_value)
	kind_symbol in _MODERN_MAP_TRACE_TYPES && return "map"
	kind_symbol in PlotlyBase._TRACE_TYPES || return ""
	kind = PlotlyBase.get_subplotkind_from_trace_type(kind_symbol)
	return kind isa AbstractString ? String(kind) : ""
end

# Layout keys of the axes/scene/polar/ternary a trace draws into, including the
# implicit `xaxis`/`yaxis`/`scene`/`polar`/`ternary` of a trace without refs.
function _style_trace_axis_keys(trace::GenericTrace)
	fields = trace.fields
	if haskey(fields, :xaxis) || haskey(fields, :yaxis)
		keys_found = Symbol[]
		for (field, letter, default) in ((:xaxis, :x, "x"), (:yaxis, :y, "y"))
			ref = _style_ref_string(get(fields, field, default))
			occursin(Regex("^$(letter)\\d*\$"), ref) && push!(keys_found, _axis_layout_key(ref, letter))
		end
		return keys_found
	end
	if haskey(fields, :scene)
		ref = _style_ref_string(fields[:scene])
		return occursin(r"^scene\d*$", ref) ? Symbol[Symbol(ref)] : Symbol[]
	end
	kind = _style_trace_kind(fields)
	kind == "xy" && return Symbol[:xaxis, :yaxis]
	kind == "scene" && return Symbol[:scene]
	if kind in ("polar", "ternary")
		ref = _style_ref_string(get(fields, :subplot, kind))
		return occursin(Regex("^$(kind)\\d*\$"), ref) ? Symbol[Symbol(ref)] : Symbol[]
	end
	return Symbol[]
end

const _STYLE_AXIS_KEY = r"^(?:[xy]axis\d*|scene\d*|polar\d*|ternary\d*)$"

function _style_figure_axis_keys(p::Plot)
	found = Set{Symbol}()
	for key in keys(p.layout.fields)
		occursin(_STYLE_AXIS_KEY, String(key)) && push!(found, Symbol(key))
	end
	for trace in p.data
		trace isa GenericTrace || continue
		union!(found, _style_trace_axis_keys(trace))
	end
	return sort!(collect(found))
end

_style_strip_digits(ref::AbstractString) = replace(String(ref), r"\d+$" => "")

# A trace belongs to a cell subplot when every placing keyword matches. A
# keyword the trace omits takes plotly's default id ("x", "scene", "polar", …),
# but only for a trace of that subplot kind: a 3-D trace has no `xaxis` and is
# never placed in an "xy" cell by default.
function _style_trace_in_cell(trace::GenericTrace, cell::_StyleCell)
	fields = trace.fields
	kind = _style_trace_kind(fields)
	for (ref_kind, ref) in cell.trace_refs
		matched = true
		for (key, value) in ref
			if key === :domain
				td = _symbol_dict(get(fields, :domain, nothing))
				rd = _symbol_dict(value)
				matched &= (
					_domain_tuple(get(td, :x, nothing)) == _domain_tuple(get(rd, :x, nothing)) &&
					_domain_tuple(get(td, :y, nothing)) == _domain_tuple(get(rd, :y, nothing))
				)
			else
				expected = _style_ref_string(value)
				actual = if haskey(fields, key)
					_style_ref_string(fields[key])
				elseif kind == ref_kind
					_style_strip_digits(expected)
				else
					""
				end
				matched &= !isempty(actual) && actual == expected
			end
			matched || break
		end
		matched && return true
	end
	return false
end

function _style_cell(p::Plot, row::Int, col::Int, who::AbstractString)
	grid_ref = p.layout.subplots.grid_ref
	(isassigned(grid_ref, row, col) && !isempty(grid_ref[row, col])) ||
		throw(ArgumentError("$(who): subplot cell ($(row), $(col)) is empty."))
	layout_keys = Symbol[]
	trace_refs = Tuple{String, Dict{Symbol, Any}}[]
	xrefs = Set{String}()
	yrefs = Set{String}()
	for ref in grid_ref[row, col]
		append!(layout_keys, Symbol.(ref.layout_keys))
		kwargs = _symbol_dict(ref.trace_kwargs)
		push!(trace_refs, (_style_ref_string(ref.subplot_kind), kwargs))
		haskey(kwargs, :xaxis) && push!(xrefs, _style_ref_string(kwargs[:xaxis]))
		haskey(kwargs, :yaxis) && push!(yrefs, _style_ref_string(kwargs[:yaxis]))
	end
	return _StyleCell(row, col, unique!(layout_keys), trace_refs, xrefs, yrefs)
end

_style_ref_base(ref) = replace(String(ref), r" domain$" => "")

# Which font (if any) one root-layout annotation receives.
function _annotation_role_font(annotation, cell, title_font, annotation_font)
	d = _symbol_dict(annotation)
	name = get(d, :name, nothing)
	name_string = name isa AbstractString ? String(name) : ""
	names_cell(m) = tryparse(Int, m[1]) == cell.row && tryparse(Int, m[2]) == cell.col
	title_match = match(_STYLE_PANEL_TITLE_NAME, name_string)
	if title_match !== nothing
		cell === nothing && return title_font
		return names_cell(title_match) ? title_font : nothing
	end
	# `subplots(...; x_title, y_title)`: labels of the whole grid, drawn in
	# the title size like the grid's other titles (plotly's make_subplots
	# gives them all one size); they belong to no cell.
	if occursin(_STYLE_FIGURE_LABEL_NAME, name_string)
		return cell === nothing ? title_font : nothing
	end
	cell === nothing && return annotation_font
	item_match = match(_STYLE_CELL_ITEM_NAME, name_string)
	if item_match !== nothing
		return names_cell(item_match) ? annotation_font : nothing
	end
	# plotly.js places an annotation without xref/yref on the first x/y axis.
	xref = _style_ref_string(get(d, :xref, "x"))
	yref = _style_ref_string(get(d, :yref, "y"))
	in_cell = _style_ref_base(xref) in cell.xrefs || _style_ref_base(yref) in cell.yrefs
	return in_cell ? annotation_font : nothing
end

function _style_update_annotation_vector(annotations, font_for, where::AbstractString, who::AbstractString)
	annotations isa AbstractVector ||
		throw(ArgumentError(
			"$(who): `$(where)` is a $(typeof(annotations)), expected a vector of annotations.",
		))
	changed = false
	updated = Any[]
	for (i, annotation) in enumerate(annotations)
		font = font_for(annotation)
		if font === nothing || isempty(font)
			push!(updated, annotation)
		else
			push!(updated, _style_update_path(annotation, (:font,), font, "$(where)[$(i)]", who))
			changed = true
		end
	end
	return changed ? updated : nothing
end

# Compute every layout/trace update for one set of font roles. Nothing is
# written: the caller commits the returned values after all of them were
# computed (so a malformed container throws before any change). `base` holds
# layout values already scheduled by the caller that the role updates build on.
function _font_role_updates(
	p::Plot,
	roles::_FontRoles,
	cell::Union{Nothing, _StyleCell},
	who::AbstractString;
	base::AbstractDict = Dict{Symbol, Any}(),
	colorbar_lines::AbstractDict = Dict{Symbol, Any}(),
)
	fields = p.layout.fields
	in_cell = cell !== nothing
	layout_new = Dict{Symbol, Any}()
	current(key) =
		haskey(layout_new, key) ? layout_new[key] :
		haskey(base, key) ? base[key] : get(fields, key, nothing)
	function update!(key::Symbol, path::Tuple{Vararg{Symbol}}, font::AbstractDict)
		isempty(font) && return nothing
		layout_new[key] = _style_update_path(current(key), path, font, "layout.$(key)", who)
		return nothing
	end

	label_font = _role_font(roles, roles.label, in_cell)
	tick_font = _role_font(roles, roles.tick, in_cell)
	title_font = _role_font(roles, roles.title, in_cell)
	legend_font = _role_font(roles, roles.legend, in_cell)
	annotation_font = _role_font(roles, roles.annotation, in_cell)
	colorbar_tick_font = _role_font(roles, roles.colorbar > 0 ? roles.colorbar : roles.tick, in_cell)
	colorbar_title_font = _role_font(roles, roles.colorbar > 0 ? roles.colorbar : roles.label, in_cell)

	if !in_cell
		root_font = Dict{Symbol, Any}()
		isempty(roles.family) || (root_font[:family] = roles.family)
		roles.size > 0 && (root_font[:size] = _style_number(roles.size))
		isempty(roles.color) || (root_font[:color] = roles.color)
		update!(:font, (), root_font)
		update!(:title, (:font,), title_font)
	end

	# Axes of every subplot kind.
	axis_keys = in_cell ? cell.layout_keys : _style_figure_axis_keys(p)
	for key in axis_keys
		name = String(key)
		if occursin(r"^[xy]axis\d*$", name)
			update!(key, (:title, :font), label_font)
			update!(key, (:tickfont,), tick_font)
		elseif occursin(r"^scene\d*$", name)
			for axis in (:xaxis, :yaxis, :zaxis)
				update!(key, (axis, :title, :font), label_font)
				update!(key, (axis, :tickfont), tick_font)
			end
			if !isempty(annotation_font)
				scene = _style_container_dict(current(key), "layout.$(name)", who)
				scene_annotations = get(scene, :annotations, nothing)
				if scene_annotations !== nothing
					updated = _style_update_annotation_vector(
						scene_annotations,
						_ -> annotation_font,
						"layout.$(name).annotations",
						who,
					)
					if updated !== nothing
						scene[:annotations] = updated
						layout_new[key] = _style_wrap_like(current(key), scene)
					end
				end
			end
		elseif occursin(r"^polar\d*$", name)
			update!(key, (:radialaxis, :title, :font), label_font)
			update!(key, (:radialaxis, :tickfont), tick_font)
			update!(key, (:angularaxis, :tickfont), tick_font)
		elseif occursin(r"^ternary\d*$", name)
			for axis in (:aaxis, :baxis, :caxis)
				update!(key, (axis, :title, :font), label_font)
				update!(key, (axis, :tickfont), tick_font)
			end
		end
	end

	# Traces in scope (all, or the cell's) for colorbars and legend ids.
	scoped = Int[]
	for (index, trace) in enumerate(p.data)
		trace isa GenericTrace || continue
		in_cell && !_style_trace_in_cell(trace, cell) && continue
		push!(scoped, index)
	end

	# Legends.
	if !isempty(legend_font)
		legend_keys = Set{Symbol}()
		if in_cell
			for index in scoped
				legend_id = _style_ref_string(get(p.data[index].fields, :legend, "legend"))
				occursin(r"^legend\d*$", legend_id) && push!(legend_keys, Symbol(legend_id))
			end
		else
			push!(legend_keys, :legend)
			for key in keys(fields)
				occursin(r"^legend\d+$", String(key)) && push!(legend_keys, Symbol(key))
			end
		end
		for key in sort!(collect(legend_keys))
			update!(key, (:font,), legend_font)
		end
	end

	# Colorbars: trace-level, marker/line-level, and layout coloraxes.
	trace_new = Pair{Int, Dict{Symbol, Any}}[]
	if !isempty(colorbar_tick_font) || !isempty(colorbar_title_font) || !isempty(colorbar_lines)
		coloraxis_keys = Set{Symbol}()
		function add_coloraxis!(ref)
			id = _style_ref_string(ref)
			occursin(r"^coloraxis\d*$", id) && push!(coloraxis_keys, Symbol(id))
			return nothing
		end
		if !in_cell
			for key in keys(fields)
				occursin(r"^coloraxis\d*$", String(key)) && push!(coloraxis_keys, Symbol(key))
			end
		end
		for index in scoped
			trace_fields = p.data[index].fields
			updates = Dict{Symbol, Any}()
			type_value = get(trace_fields, :type, "scatter")
			type_name = type_value isa Union{AbstractString, Symbol} ? String(type_value) : ""
			where = "data[$(index)]"
			if type_name in _STYLE_TRACE_COLORBAR_TYPES
				colorbar = get(trace_fields, :colorbar, nothing)
				isempty(colorbar_tick_font) ||
					(colorbar = _style_update_path(colorbar, (:tickfont,), colorbar_tick_font, "$(where).colorbar", who))
				isempty(colorbar_title_font) ||
					(colorbar = _style_update_path(colorbar, (:title, :font), colorbar_title_font, "$(where).colorbar", who))
				colorbar = first(_style_fill_nested(colorbar, colorbar_lines, "$(where).colorbar", who))
				updates[:colorbar] = colorbar
			end
			add_coloraxis!(get(trace_fields, :coloraxis, nothing))
			for sub in (:marker, :line)
				sub_value = get(trace_fields, sub, nothing)
				(sub_value isa AbstractDict || sub_value isa PlotlyBase.PlotlyAttribute) || continue
				sub_dict = _symbol_dict(sub_value)
				add_coloraxis!(get(sub_dict, :coloraxis, nothing))
				(haskey(sub_dict, :colorbar) || get(sub_dict, :showscale, false) === true) || continue
				new_sub = sub_value
				isempty(colorbar_tick_font) ||
					(new_sub = _style_update_path(new_sub, (:colorbar, :tickfont), colorbar_tick_font, "$(where).$(sub)", who))
				isempty(colorbar_title_font) ||
					(new_sub = _style_update_path(new_sub, (:colorbar, :title, :font), colorbar_title_font, "$(where).$(sub)", who))
				new_sub = first(_style_fill_nested(new_sub, Dict{Symbol, Any}(:colorbar => colorbar_lines), "$(where).$(sub)", who))
				updates[sub] = new_sub
			end
			isempty(updates) || push!(trace_new, index => updates)
		end
		for key in sort!(collect(coloraxis_keys))
			update!(key, (:colorbar, :tickfont), colorbar_tick_font)
			update!(key, (:colorbar, :title, :font), colorbar_title_font)
			if !isempty(colorbar_lines)
				filled, changed = _style_fill_nested(
					current(key),
					Dict{Symbol, Any}(:colorbar => colorbar_lines),
					"layout.$(key)",
					who,
				)
				changed && (layout_new[key] = filled)
			end
		end
	end

	# Root annotations (panel titles take the title role).
	if !isempty(annotation_font) || !isempty(title_font)
		annotations = current(:annotations)
		if annotations !== nothing
			updated = _style_update_annotation_vector(
				annotations,
				a -> _annotation_role_font(a, cell, title_font, annotation_font),
				"layout.annotations",
				who,
			)
			updated === nothing || (layout_new[:annotations] = updated)
		end
	end
	return layout_new, trace_new
end

function _commit_trace_updates!(p::Plot, trace_updates)
	for (index, updates) in trace_updates
		trace_fields = p.data[index].fields
		for (key, value) in updates
			trace_fields[key] = value
		end
	end
	return nothing
end

# ── set_fonts! ───────────────────────────────────────────────────────────────

const _SET_FONTS_UNITS = (:px, :pt)

function _set_fonts_roles(;
	family,
	size,
	title,
	label,
	tick,
	legend,
	colorbar,
	annotation,
	color,
	units,
)
	who = "set_fonts!"
	family isa AbstractString ||
		throw(ArgumentError("$(who): `family` must be a string; got $(repr(family))."))
	units isa Symbol ||
		throw(ArgumentError("$(who): `units` must be :px or :pt; got $(repr(units))."))
	scale = _style_px_per_unit(units, _SET_FONTS_UNITS, who)
	px(value, name) = _style_font_size(_style_nonnegative(value, who, name) * scale, who, name)
	return _FontRoles(
		String(family),
		px(size, "size"),
		_style_color(color, who, "color"),
		px(title, "title"),
		px(label, "label"),
		px(tick, "tick"),
		px(legend, "legend"),
		px(colorbar, "colorbar"),
		px(annotation, "annotation"),
	)
end

function _set_fonts_apply!(p::Plot, roles::_FontRoles, cell)
	layout_updates, trace_updates = _font_role_updates(p, roles, cell, "set_fonts!")
	for (key, value) in layout_updates
		p.layout.fields[key] = value
	end
	_commit_trace_updates!(p, trace_updates)
	return nothing
end

function _set_fonts_impl!(
	fig;
	family::AbstractString = "",
	size::Real = 0,
	title::Real = 0,
	label::Real = 0,
	tick::Real = 0,
	legend::Real = 0,
	colorbar::Real = 0,
	annotation::Real = 0,
	color::Union{AbstractString, Symbol} = "",
	units::Symbol = :px,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	(row === nothing && col === nothing) ||
		throw(ArgumentError(
			"set_fonts!: `row`/`col` select a subplot cell and are only accepted for a SubplotFigure.",
		))
	roles = _set_fonts_roles(;
		family, size, title, label, tick, legend, colorbar, annotation, color, units,
	)
	_set_fonts_apply!(_plot_obj(fig), roles, nothing)
	_refresh!(fig)
	return nothing
end

function _set_fonts_subplot_impl!(
	sf::SubplotFigure;
	family::AbstractString = "",
	size::Real = 0,
	title::Real = 0,
	label::Real = 0,
	tick::Real = 0,
	legend::Real = 0,
	colorbar::Real = 0,
	annotation::Real = 0,
	color::Union{AbstractString, Symbol} = "",
	units::Symbol = :px,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	(row === nothing) == (col === nothing) ||
		throw(ArgumentError("set_fonts!: `row` and `col` must be provided together."))
	roles = _set_fonts_roles(;
		family, size, title, label, tick, legend, colorbar, annotation, color, units,
	)
	p = _plot_obj(sf.fig)
	cell = nothing
	if row !== nothing
		(1 <= row <= sf.rows) ||
			throw(ArgumentError("set_fonts!: `row` must be in 1:$(sf.rows); got $(row)."))
		(1 <= col <= sf.cols) ||
			throw(ArgumentError("set_fonts!: `col` must be in 1:$(sf.cols); got $(col)."))
		cell = _style_cell(p, Int(row), Int(col), "set_fonts!")
	end
	_set_fonts_apply!(p, roles, cell)
	_refresh!(sf.fig)
	return sf
end

"""
	set_fonts!(fig; family="", size=0, title=0, label=0, tick=0, legend=0,
		colorbar=0, annotation=0, color="", units=:px)
	set_fonts!(sf::SubplotFigure; ..., row=nothing, col=nothing)

Set figure fonts by role in one call. Every size keyword is a `Real`; `0`
(the default) leaves that role unchanged, negative or non-finite values throw an
`ArgumentError`. Only the roles you pass are written.

# Keywords
- `family::AbstractString=""`: font family for all text (`layout.font.family`).
- `size::Real=0`: base size of all text (`layout.font.size`).
- `color=""`: colour of all text (`layout.font.color`); a colour string or Symbol.
- `title::Real=0`: figure title (`layout.title.font.size`) and per-panel title
  annotations (annotations named `plotlysupply:title:<row>:<col>`).
- `label::Real=0`: axis titles of every cartesian axis (`xaxisN`/`yaxisN`),
  3-D scene axis (`sceneN.{x,y,z}axis`), polar radial axis and ternary axis.
- `tick::Real=0`: tick labels of the same axes (`tickfont.size`, including the
  polar angular axis).
- `legend::Real=0`: text of `legend` and every `legendN`.
- `colorbar::Real=0`: tick labels and title of every colorbar (trace
  `colorbar`, `marker.colorbar`/`line.colorbar` of traces that show one, and
  layout `coloraxisN.colorbar`). When `0`, colorbar ticks follow `tick` and
  colorbar titles follow `label`.
- `annotation::Real=0`: every other annotation (`layout.annotations` and 3-D
  scene annotations).
- `units::Symbol=:px`: `:px` or `:pt`; with `:pt` every size is converted with
  px = pt·96/72, so the printed size at 96 px/in equals the requested points
  (7.5 pt → 10 px).
- `row`, `col` (SubplotFigure only, both or neither): restrict the call to one
  cell — its axes (including a secondary y axis), the colorbars of its traces
  and their coloraxes, the legend(s) its traces use, its annotations, and its
  panel title. `family`/`color` are then written to those elements, and `size`
  sizes every one of them whose role size is `0`. Without `row`/`col` the call
  is figure-wide and `family`/`size`/`color` set `layout.font`, which every
  element without an explicit size inherits.

Titles stored as bare strings (1.x figures) are converted to
`attr(text=…, font=…)`; a missing title gives no error. Role sizes are written
to the elements that exist now: axes, legends and colorbars added later inherit
`layout.font` only.

Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a `SubplotFigure`. The
call is atomic: if validation fails, nothing changes.

# Example
```julia
fig = plot_scatter(1:10, (1:10) .^ 2; xlabel = "n", ylabel = "n²", title = "Squares")
set_fonts!(fig; family = "Arial", title = 18, label = 14, tick = 11, legend = 11)
set_fonts!(fig; tick = 7.5, units = :pt)   # 10 px tick labels
```
"""
function set_fonts!(
	fig::Union{Plot, SyncPlot};
	family::AbstractString = "",
	size::Real = 0,
	title::Real = 0,
	label::Real = 0,
	tick::Real = 0,
	legend::Real = 0,
	colorbar::Real = 0,
	annotation::Real = 0,
	color::Union{AbstractString, Symbol} = "",
	units::Symbol = :px,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	return _transactional_high_level_plot_mutation!(
		_set_fonts_impl!,
		fig;
		family, size, title, label, tick, legend, colorbar, annotation, color, units,
		row, col,
	)
end

function set_fonts!(
	sf::SubplotFigure;
	family::AbstractString = "",
	size::Real = 0,
	title::Real = 0,
	label::Real = 0,
	tick::Real = 0,
	legend::Real = 0,
	colorbar::Real = 0,
	annotation::Real = 0,
	color::Union{AbstractString, Symbol} = "",
	units::Symbol = :px,
	row::Union{Nothing, Integer} = nothing,
	col::Union{Nothing, Integer} = nothing,
)
	return _transactional_subplot_mutation!(
		_set_fonts_subplot_impl!,
		sf,
		();
		family, size, title, label, tick, legend, colorbar, annotation, color, units,
		row, col,
	)
end

# ── tight_layout! ────────────────────────────────────────────────────────────

# Text sizes (plain lines at 1.3 em, MathJax rows, glyph widths) come from
# `_text_extent` (src/sci/text.jl); plotly.js draws annotation text inside
# `borderpad`+`borderwidth` (defaults 1, 1) on each side.
# Figure size assumed when the layout has none: the size `savefig` exports it
# at, the active style's figure size (`_style_default_figure_size`: the
# style's width and aspect, else 700 x 500 px).
# plotly.js 2.35 layout defaults: font.size 12, title.font.size =
# round(1.4 * font.size), title.subtitle.font.size = round(0.7 * title size).
const _TIGHT_DEFAULT_FONT_SIZE = 12.0
const _TIGHT_TITLE_SIZE_FACTOR = 1.4
const _TIGHT_SUBTITLE_SIZE_FACTOR = 0.7
# The room added for annotations and the title is an estimate; it is capped at
# 45 % of the figure extent per side so that a wrong estimate can never leave
# less than 10 % of the figure for the plot area.
const _TIGHT_MAX_MARGIN_FRACTION = 0.45

function _tight_real(value, default::Float64)
	return (value isa Real && !(value isa Bool) && isfinite(value)) ? Float64(value) : default
end

function _tight_title_text(title)
	title === nothing && return ""
	title isa AbstractString && return String(title)
	if title isa AbstractDict || title isa PlotlyBase.PlotlyAttribute
		text = get(_symbol_dict(title), :text, "")
		text === nothing && return ""
		return text isa AbstractString ? String(text) : string(text)
	end
	return ""
end

_tight_lines(text::AbstractString) = split(String(text), r"<br\s*/?>"i)

function _tight_root_font_size(lookup)
	template = lookup(:template)
	template_font = template isa PlotlyBase.Template ?
		_symbol_dict(get(_template_layout_fields(template), :font, nothing)) :
		Dict{Symbol, Any}()
	fallback = _tight_real(get(template_font, :size, nothing), _TIGHT_DEFAULT_FONT_SIZE)
	return _tight_real(get(_symbol_dict(lookup(:font)), :size, nothing), fallback)
end

# Height in px of the figure title block as plotly.js lays it out (title and
# subtitle text, see `_text_extent`, plus title.pad.t/b), or 0 without title
# text.
function _tight_title_height(title, lookup, root_size::Float64)
	text = _tight_title_text(title)
	isempty(text) && return 0.0
	d = title isa AbstractString ? Dict{Symbol, Any}() : _symbol_dict(title)
	template = lookup(:template)
	template_title = template isa PlotlyBase.Template ?
		_symbol_dict(get(_template_layout_fields(template), :title, nothing)) :
		Dict{Symbol, Any}()
	default_size = _tight_real(
		get(_symbol_dict(get(template_title, :font, nothing)), :size, nothing),
		Float64(round(_TIGHT_TITLE_SIZE_FACTOR * root_size)),
	)
	size = _tight_real(get(_symbol_dict(get(d, :font, nothing)), :size, nothing), default_size)
	height = _text_extent(text, size)[2]
	subtitle = _symbol_dict(get(d, :subtitle, nothing))
	subtitle_text = get(subtitle, :text, "")
	if subtitle_text isa AbstractString && !isempty(subtitle_text)
		subtitle_size = _tight_real(
			get(_symbol_dict(get(subtitle, :font, nothing)), :size, nothing),
			Float64(round(_TIGHT_SUBTITLE_SIZE_FACTOR * size)),
		)
		height += _text_extent(subtitle_text, subtitle_size)[2]
	end
	pad = _symbol_dict(get(d, :pad, nothing))
	return height + _tight_real(get(pad, :t, nothing), 0.0) + _tight_real(get(pad, :b, nothing), 0.0)
end

# Paper coordinate of an annotation position, or `nothing` when it is in data
# units (no pixel position is known without the rendered axis ranges).
function _tight_paper_coordinate(layout::Layout, ref, value, letter::Symbol)
	(value isa Real && !(value isa Bool) && isfinite(value)) || return nothing
	ref isa AbstractString || return nothing
	ref == "paper" && return Float64(value)
	m = match(letter === :x ? r"^(x\d*) domain$" : r"^(y\d*) domain$", ref)
	m === nothing && return nothing
	domain = something(_layout_axis_domain(layout, _axis_layout_key(m[1], letter)), (0.0, 1.0))
	return domain[1] + Float64(value) * (domain[2] - domain[1])
end

# (start, stop) of a text box along one direction, relative to the anchor point.
function _tight_box_span(anchor::AbstractString, extent::Float64)
	anchor in ("bottom", "left") && return (0.0, extent)
	anchor in ("top", "right") && return (-extent, 0.0)
	return (-extent / 2, extent / 2)
end

function _tight_anchor(anchor, position::Float64, has_arrow::Bool, letter::Symbol)
	if anchor isa AbstractString && anchor != "auto"
		return String(anchor)
	end
	has_arrow && return letter === :x ? "center" : "middle"
	# plotly.js "auto": paper-referenced text without an arrow anchors on the
	# side closest to the figure edge it sits near.
	if position > 2 / 3
		return letter === :x ? "right" : "top"
	elseif position < 1 / 3
		return letter === :x ? "left" : "bottom"
	end
	return letter === :x ? "center" : "middle"
end

# Panel titles and panel labels (`title!(…; row, col)`, `subplot_titles`,
# `panel_labels!`): the D12 room providers place them and raise the margin
# they need (src/sci/room_providers.jl) whenever `_finalize_figure!` runs, so
# their current position (possibly the one of another figure size) is not
# measured here.
const _TIGHT_PROVIDER_PLACED = r"^plotlysupply:(title|panel_label):[0-9]+:[0-9]+$"

# Pixels by which paper-referenced annotations overhang each side of the plot
# area (those the room providers place excluded). Plotly annotations never
# push margins themselves.
function _tight_annotation_overhang(layout::Layout, lookup, width::Float64, height::Float64, root_size::Float64)
	overhang = Dict(:l => 0.0, :r => 0.0, :t => 0.0, :b => 0.0)
	annotations = lookup(:annotations)
	annotations isa AbstractVector || return overhang
	for annotation in annotations
		d = _symbol_dict(annotation)
		get(d, :visible, true) === false && continue
		name = get(d, :name, nothing)
		name isa AbstractString && occursin(_TIGHT_PROVIDER_PLACED, name) && continue
		text = get(d, :text, "")
		text isa AbstractString && !isempty(text) || continue
		px = _tight_paper_coordinate(layout, get(d, :xref, nothing), get(d, :x, nothing), :x)
		py = _tight_paper_coordinate(layout, get(d, :yref, nothing), get(d, :y, nothing), :y)
		(px === nothing && py === nothing) && continue

		size = _tight_real(get(_symbol_dict(get(d, :font, nothing)), :size, nothing), root_size)
		text_width, text_height = _text_extent(text, size)
		frame = 2 * (_tight_real(get(d, :borderpad, nothing), 1.0) + _tight_real(get(d, :borderwidth, nothing), 1.0))
		box_height = text_height + frame
		box_width = text_width + frame
		angle = mod(_tight_real(get(d, :textangle, nothing), 0.0), 180.0)
		if 45 < angle < 135
			box_height, box_width = box_width, box_height
		end
		has_arrow = get(d, :showarrow, true) !== false
		arrow_x = has_arrow ? _tight_real(get(d, :ax, nothing), -10.0) : 0.0
		# plotly's `ay` is positive downwards; convert to an upward offset.
		arrow_y = has_arrow ? -_tight_real(get(d, :ay, nothing), -30.0) : 0.0
		if px !== nothing
			anchor = _tight_anchor(get(d, :xanchor, nothing), px, has_arrow, :x)
			lo, hi = _tight_box_span(anchor, box_width)
			centre = px * width + _tight_real(get(d, :xshift, nothing), 0.0) + arrow_x
			overhang[:l] = max(overhang[:l], -(centre + lo))
			overhang[:r] = max(overhang[:r], centre + hi - width)
		end
		if py !== nothing
			anchor = _tight_anchor(get(d, :yanchor, nothing), py, has_arrow, :y)
			lo, hi = _tight_box_span(anchor, box_height)
			centre = py * height + _tight_real(get(d, :yshift, nothing), 0.0) + arrow_y
			overhang[:b] = max(overhang[:b], -(centre + lo))
			overhang[:t] = max(overhang[:t], centre + hi - height)
		end
	end
	return overhang
end

# New `margin` and `title` containers giving each side listed in `minimum`
# (keys l/r/t/b, px; an optional `pad` is passed through) that minimum plus
# the room needed by paper-referenced annotations and, when annotations sit
# above the plot area, by a container-referenced title. Nothing is written;
# returns `(margin, title)` with `title === nothing` when the title is
# unchanged. `pending` holds layout values the caller is about to commit, which
# take precedence over the figure's current ones.
#
# A title with text gets `automargin=true` (plotly then grows the top margin to
# fit it exactly) and, when it is container-referenced and has no `pad.t` of
# its own, `pad.t` = the top minimum so it keeps that gap to the figure edge.
# plotly.js grows a margin to the larger of its pushers rather than their sum,
# so when annotations also overhang the top their room and the estimated title
# height are added explicitly.
function _fit_margin_updates(
	p::Plot,
	minimum::AbstractDict{Symbol, <:Real},
	who::AbstractString;
	pending::AbstractDict = Dict{Symbol, Any}(),
	always_automargin::Bool = false,
)
	fields = p.layout.fields
	lookup(key) = haskey(pending, key) ? pending[key] : get(fields, key, nothing)
	default_width, default_height = _style_default_figure_size()
	width = _tight_real(lookup(:width), Float64(default_width))
	height = _tight_real(lookup(:height), Float64(default_height))
	root_size = _tight_root_font_size(lookup)
	overhang = _tight_annotation_overhang(p.layout, lookup, width, height, root_size)

	title = lookup(:title)
	has_title = !isempty(_tight_title_text(title))
	title_fields = title isa AbstractString ? Dict{Symbol, Any}() : _style_container_dict(title, "layout.title", who)
	container_title = has_title && get(title_fields, :yref, "container") != "paper"
	new_title = nothing
	if has_title || always_automargin
		new_title = _style_update_path(title, (), Dict{Symbol, Any}(:automargin => true), "layout.title", who)
		if container_title && haskey(minimum, :t) &&
		   !haskey(_symbol_dict(get(title_fields, :pad, nothing)), :t)
			new_title = _style_update_path(
				new_title,
				(:pad,),
				Dict{Symbol, Any}(:t => _style_number(minimum[:t])),
				"layout.title",
				who,
			)
		end
	end

	margin_updates = Dict{Symbol, Any}()
	for (key, extent) in ((:l, width), (:r, width), (:t, height), (:b, height))
		haskey(minimum, key) || continue
		base = Float64(minimum[key])
		extra = ceil(overhang[key])
		if key === :t && container_title && overhang[:t] > 0
			extra += ceil(_tight_title_height(something(new_title, title), lookup, root_size))
		end
		margin_updates[key] = _style_number(max(base, min(base + extra, _TIGHT_MAX_MARGIN_FRACTION * extent)))
	end
	haskey(minimum, :pad) && (margin_updates[:pad] = _style_number(minimum[:pad]))
	new_margin = _style_update_path(lookup(:margin), (), margin_updates, "layout.margin", who)
	return new_margin, new_title
end

function _tight_layout_impl!(fig; pad::Real = 4)
	pad_px = _style_nonnegative(pad, "tight_layout!", "pad")
	p = _plot_obj(fig)
	minimum = Dict{Symbol, Float64}(:l => pad_px, :r => pad_px, :t => pad_px, :b => pad_px)
	new_margin, new_title = _fit_margin_updates(p, minimum, "tight_layout!")
	fields = p.layout.fields
	fields[:margin] = new_margin
	new_title === nothing || (fields[:title] = new_title)
	# Panel titles and labels, legends outside the plot areas and the figure
	# title above them get their room back from the D12 room providers
	# (`_finalize_figure!`), which raise the margins from these minimums.
	_refresh!(fig)
	return nothing
end

# Keywords `tight_layout!` does not take, rejected before anything changes:
# it lays out the whole figure (no `row`/`col`) and modifies an existing one
# (no `show`).
function _tight_reject_keywords(kwargs)
	isempty(kwargs) && return nothing
	haskey(kwargs, :show) && _text_reject_show(kwargs[:show], "tight_layout!")
	names = join(("`$(k)`" for k in keys(kwargs)), ", ")
	throw(ArgumentError(
		"tight_layout!: unsupported keyword(s) $(names); it takes only `pad` and lays out the " *
		"whole figure (margins of every cell).",
	))
end

_tight_pad_value(pad) = pad isa Real ? pad :
	throw(ArgumentError("tight_layout!: `pad` must be a real number of px >= 0; got $(repr(pad))."))

"""
	tight_layout!(fig; pad=4)
	tight_layout!(sf::SubplotFigure; pad=4)

Shrink the figure margins to `pad` px (`pad::Real >= 0`) on every side, the
analogue of matplotlib's `tight_layout`/`bbox_inches="tight"`. Nothing is
clipped:

- tick labels and axis titles keep their room through the axes'
  `automargin=true` (set by every PlotlySupply constructor), and legends and
  colorbars outside the plot area push the margins automatically;
- a figure title gets `title.automargin=true`, so the top margin grows to fit
  it, and (unless it has its own `title.pad.t`) `title.pad.t = pad`, so it
  keeps `pad` px from the top edge;
- paper-referenced annotations above, below or beside the plot area are
  measured and the margin on that side is enlarged by their estimated extent
  (plain text 1.3 em per `<br>` line with
  per-glyph widths; TeX labels such as those [`mathtext`](@ref) writes are
  measured as typeset: one row per row of a multi-line `array`, commands,
  braces and `\\text{…}` wrappers stripped, scripts at 70 %, fractions and
  roots taller. The estimate errs on the large side, by up to about 20 % for
  text and more for very short TeX labels. Annotations in data coordinates
  are not measured). When such
  annotations sit above the plot area, the estimated title height is added to
  the top margin as well, so the title stays above them. Each enlargement is
  capped at 45 % of the figure width or height.
- panel titles and panel labels ([`title!`](@ref) with `row`/`col`,
  `subplot_titles`, [`panel_labels!`](@ref)), legends placed outside a plot
  area and the figure title above them keep their room: they are stacked and
  the margins raised to hold them whenever the figure changes (with or
  without `tight_layout!`; see [`set_legend!`](@ref)), so they are not
  measured here.

The figure size used for the measurement is `layout.width`/`layout.height`
(see [`figsize!`](@ref)), else the active style's figure size (700 × 500 px
without one). A title with `yref="paper"` is placed by plotly directly above
the plot area and is not moved. Bare-string titles are converted to
`attr(text=…, automargin=true, pad=attr(t=pad))`. Any other keyword (`row`,
`col`, `show`, …) or a `pad` that is not a real number >= 0 throws an
`ArgumentError` before anything changes. Returns `nothing` for a
`Plot`/`SyncPlot` and `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_scatter(1:10, (1:10) .^ 2; xlabel = "x", ylabel = "y", title = "Tight")
tight_layout!(fig)            # 4 px margins plus the room the labels need
tight_layout!(fig; pad = 0)
```
"""
function tight_layout!(fig; pad = 4, kwargs...)
	_tight_reject_keywords(kwargs)
	return _tight_layout_impl!(fig; pad = _tight_pad_value(pad))
end

function _tight_layout_subplot_impl!(sf::SubplotFigure; pad::Real = 4)
	_tight_layout_impl!(sf.fig; pad = pad)
	return sf
end

function tight_layout!(sf::SubplotFigure; pad = 4, kwargs...)
	_tight_reject_keywords(kwargs)
	pad = _tight_pad_value(pad)
	_style_nonnegative(pad, "tight_layout!", "pad")
	return _transactional_subplot_mutation!(
		_tight_layout_subplot_impl!,
		sf,
		();
		pad = pad,
	)
end

# ── figsize! ─────────────────────────────────────────────────────────────────

const _FIGSIZE_UNITS = (:px, :in, :cm, :mm, :pt)

# Rejects keywords a figure-size call does not take (`show` included: a
# mutator never opens a window), naming the function, before anything changes.
function _figsize_reject_keywords(who::AbstractString, kwargs)
	isempty(kwargs) && return nothing
	names = join(("`$(k)`" for k in keys(kwargs)), ", ")
	hint = haskey(kwargs, :show) ?
		" (mutators do not take `show`; display the figure with `display(fig)`)" : ""
	throw(ArgumentError("$(who): unsupported keyword argument(s) $(names)$(hint)."))
end

# One size in CSS px, unrounded: finite, positive, at least plotly's 10 px and
# at most `_STYLE_MAX_FIGURE_PX`.
function _figsize_length_px(value, scale::Float64, units::Symbol, who::AbstractString, name::AbstractString)
	v = _style_real(value, who, name)
	v > 0 || throw(ArgumentError("$(who): `$(name)` must be > 0; got $(value)."))
	px = v * scale
	px <= _STYLE_MAX_FIGURE_PX ||
		throw(ArgumentError(
			"$(who): `$(name)` = $(value) $(units) exceeds $(_style_number(_STYLE_MAX_FIGURE_PX)) px.",
		))
	px >= _STYLE_MIN_FIGURE_PX ||
		throw(ArgumentError(
			"$(who): `$(name)` is $(px) px after conversion from $(value) $(units); plotly requires at least $(_style_number(_STYLE_MIN_FIGURE_PX)) px.",
		))
	return px
end

function _figsize_scale(units, who::AbstractString)
	units isa Symbol ||
		throw(ArgumentError("$(who): `units` must be a Symbol; got $(repr(units))."))
	return _style_px_per_unit(units, _FIGSIZE_UNITS, who)
end

function _figsize_px(width, height, units, who::AbstractString)
	scale = _figsize_scale(units, who)
	return (
		_figsize_length_px(width, scale, units, who, "width"),
		_figsize_length_px(height, scale, units, who, "height"),
	)
end

function _figsize_write!(fig, w::Float64, h::Float64)
	fields = _plot_layout(fig).fields
	# Exact sizes: 89 mm stays 336.378 px so a vector export is 89 mm wide.
	# Whole sizes are written as Int (JSON `336`, as 1.x wrote them).
	fields[:width] = _style_number(w)
	fields[:height] = _style_number(h)
	_refresh!(fig)
	return nothing
end

function _figsize_impl!(fig, width::Real, height::Real; units = :px, kwargs...)
	_figsize_reject_keywords("figsize!", kwargs)
	w, h = _figsize_px(width, height, units, "figsize!")
	return _figsize_write!(fig, w, h)
end

# (width, height) in px of `columns` columns of `journal`; validated in full
# before anything is written.
function _figsize_journal_px(journal, columns, aspect, height, units, who::AbstractString)
	spec = _journal_spec(journal, who)
	width_px = _journal_width_px(spec, columns, who)
	aspect === nothing || height === nothing ||
		throw(ArgumentError("$(who): pass `aspect` or `height`, not both."))
	height_px = if height !== nothing
		_figsize_length_px(height, _figsize_scale(units, who), units, who, "height")
	else
		# `units` is still checked, so a typo never passes silently.
		_figsize_scale(units, who)
		ratio = if aspect === nothing
			_style_aspect(_active_style())
		else
			value = _style_real(aspect, who, "aspect")
			0.01 <= value <= 100 ||
				throw(ArgumentError(
					"$(who): `aspect` (height / width) must be between 0.01 and 100; got $(aspect).",
				))
			value
		end
		width_px * ratio
	end
	_STYLE_MIN_FIGURE_PX <= height_px ||
		throw(ArgumentError(
			"$(who): the height is $(height_px) px; plotly requires at least $(_style_number(_STYLE_MIN_FIGURE_PX)) px.",
		))
	limit, limit_unit = spec.max_height
	if limit > 0
		limit_px = limit * _STYLE_PX_PER_UNIT[limit_unit]
		# 1e-9: a height given as exactly the limit in another unit must pass.
		height_px <= limit_px * (1 + 1e-9) ||
			throw(ArgumentError(
				"$(who): $(spec.publisher) figures may be at most $(_style_number(limit)) $(limit_unit) high; " *
				"the height is $(round(height_px / _STYLE_PX_PER_UNIT[limit_unit]; digits = 2)) $(limit_unit).",
			))
	end
	return width_px, height_px
end

function _figsize_journal_impl!(fig, journal; columns = 1, aspect = nothing, height = nothing, units = :in, kwargs...)
	_figsize_reject_keywords("figsize!", kwargs)
	w, h = _figsize_journal_px(journal, columns, aspect, height, units, "figsize!")
	return _figsize_write!(fig, w, h)
end

"""
	figsize!(fig, width::Real, height::Real; units=:px)
	figsize!(fig, journal::Symbol; columns=1, aspect=nothing, height=nothing, units=:in)
	figsize!(sf::SubplotFigure, ...)

Set the figure size, stored as `layout.width`/`layout.height` in CSS pixels so
displays and exports pick it up.

With `width` and `height`, `units` is `:px`, `:in`, `:cm`, `:mm` or `:pt`,
converted at the CSS reference resolution of 96 px/in (1 pt = 1/72 in). The
size is stored exactly (not rounded to whole pixels), so a figure set to
89 mm is exported 89 mm wide; whole-pixel sizes are stored as integers.

With a `journal` (`:ieee`, `:aps`, `:nature`, `:elsevier`, `:springer`,
`:aip`; see [`journal_width`](@ref) for the widths and their sources), the
width is the journal's published width for `columns` columns (every journal
defines 1 and 2; `:elsevier` and `:springer` also 1.5). The height is
`height` (in `units`, default inches) or `aspect × width` (`aspect` is height
/ width, 0.01 to 100; default: the active style's aspect, 0.75 when it sets
none); pass one of `height` and `aspect`, not both. Journals that publish a
maximum figure height (`:nature` 170 mm, `:springer` 234 mm, `:aip` 8.25 in)
reject a taller figure.

Both sizes must be finite, positive and at least 10 px after conversion
(plotly's minimum). Invalid arguments, unknown keywords (`show` included)
and an unknown journal or column count throw an `ArgumentError` naming
`figsize!` before anything changes. Returns `nothing` for a
`Plot`/`SyncPlot` and `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_scatter(1:10, (1:10) .^ 2)
figsize!(fig, 3.5, 2.5; units = :in)          # 336 × 240 px
figsize!(fig, :nature)                         # 89 mm × 66.75 mm
figsize!(fig, :ieee; columns = 2, height = 3)  # 7.16 in × 3 in
savefig(fig, "fig.pdf")                        # exported at that size
```
"""
function figsize!(fig, width::Real, height::Real; kwargs...)
	return _figsize_impl!(fig, width, height; kwargs...)
end

function figsize!(fig, journal::Union{Symbol, AbstractString}; kwargs...)
	return _figsize_journal_impl!(fig, journal; kwargs...)
end

function _figsize_subplot_impl!(sf::SubplotFigure, width::Real, height::Real; kwargs...)
	_figsize_impl!(sf.fig, width, height; kwargs...)
	return sf
end

function _figsize_journal_subplot_impl!(sf::SubplotFigure, journal; kwargs...)
	_figsize_journal_impl!(sf.fig, journal; kwargs...)
	return sf
end

function figsize!(sf::SubplotFigure, width::Real, height::Real; kwargs...)
	# Validated before the transaction, so an invalid call never stages a copy.
	_figsize_impl_check(width, height; kwargs...)
	return _transactional_subplot_mutation!(_figsize_subplot_impl!, sf, (), width, height; kwargs...)
end

function figsize!(sf::SubplotFigure, journal::Union{Symbol, AbstractString}; kwargs...)
	_figsize_journal_check(journal; kwargs...)
	return _transactional_subplot_mutation!(_figsize_journal_subplot_impl!, sf, (), journal; kwargs...)
end

function _figsize_impl_check(width, height; units = :px, kwargs...)
	_figsize_reject_keywords("figsize!", kwargs)
	_figsize_px(width, height, units, "figsize!")
	return nothing
end

function _figsize_journal_check(journal; columns = 1, aspect = nothing, height = nothing, units = :in, kwargs...)
	_figsize_reject_keywords("figsize!", kwargs)
	_figsize_journal_px(journal, columns, aspect, height, units, "figsize!")
	return nothing
end

"""
	journal_width(journal::Symbol; columns = 1, units = :in) -> Float64

The published figure width of `columns` columns of `journal` in `units`
(`:in`, `:cm`, `:mm`, `:pt` or `:px`; 1 in = 96 px = 72 pt). The same numbers
size the built-in journal styles (single column) and
[`figsize!`](@ref)`(fig, journal; columns)`. An unknown journal, column count
or unit throws an `ArgumentError`.

| journal | columns → width | max. height | text (preset) | source |
|:--|:--|:--|:--|:--|
| `:ieee` | 1 → 3.5 in, 2 → 7.16 in | — | Times New Roman 8 pt | IEEE Author Center, "Resolution and Size"; IEEE template (8 pt Times New Roman labels) |
| `:aps` | 1 → 8.6 cm, 2 → 17.2 cm | — | Times 9 pt (lettering ≥ 2 mm) | APS Physical Review information for authors; APS Word template (17.2 cm) |
| `:nature` | 1 → 89 mm, 2 → 183 mm | 170 mm | Arial 7 pt (5–7 pt allowed) | Nature research figure guide |
| `:elsevier` | 1 → 90 mm, 1.5 → 140 mm, 2 → 190 mm | — | Arial 9 pt (≥ 7 pt, sub/superscripts ≥ 6 pt) | Elsevier artwork sizing |
| `:springer` | 1 → 84 mm, 1.5 → 129 mm, 2 → 174 mm | 234 mm | Helvetica 8 pt (8–12 pt) | Springer instructions for authors |
| `:aip` | 1 → 3.37 in, 2 → 6.69 in | 8.25 in | Times 8 pt (≥ 8 pt) | AIP Publishing author instructions |

Font families and sizes in the presets follow the guideline where it names
them and are a package choice otherwise (APS and AIP do not name a font).
plotly draws `<sup>`/`<sub>` text (e.g. log-axis exponents with
`exponentformat = "power"`) at 70 % of the font size, which under `:nature`
is 4.9 pt, below Nature's 5 pt minimum. Optica is not included: its figure
widths could not be confirmed from Optica's own guidelines.

# Example
```julia
journal_width(:ieee)                              # 3.5
journal_width(:nature; columns = 2, units = :mm)  # 183.0
```
"""
function journal_width(journal::Union{Symbol, AbstractString}; columns = 1, units = :in)
	who = "journal_width"
	spec = _journal_spec(journal, who)
	scale = _figsize_scale(units, who)
	return _journal_width_px(spec, columns, who) / scale
end
