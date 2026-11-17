# PlotlySupply 2.0 scientific-plotting extensions: PlotStyle presets, set_fonts!, tight_layout!, figsize!.
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
#       `style.grid` is false). Plain attribute names, safe for both
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
#       (Vector{String}; for `cycle = :bw` the single ink colour of `template`)
#       and `:margin` (Dict l/r/t/b/pad), each present only when the style sets
#       it. Empty for `:default`. Dict values are merged key by key into the
#       same-named root layout key by `_apply_style_layout!`.
#
#   _apply_style_layout!(fig, style = _active_style(); template = …)
#       Called once at the end of `_apply_default_template!` (after the
#       template, axes and legend, and after title/annotations such as subplot
#       titles exist, because the margin fit measures them). Merges
#       `_style_layout_defaults`; when the style sets a margin, uses it as the
#       per-side minimum plus the room paper-referenced annotations and the
#       title need (the `tight_layout!` computation) and sets
#       `title.automargin=true` (no top margin is reserved for an empty title).
#       Writes the style's title/label/tick/legend font sizes to every existing
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
#       `:marker_size`, and for `style.cycle != :none` `:dash`,
#       `:marker_symbol`, `:markers` (true = the cycle needs visible markers, so
#       a "lines" mode should become "lines+markers"). Colour is NOT a per-trace
#       default: the `:bw` cycle's black comes from the figure colorway
#       (`_style_layout_defaults`), so `set_template!` can re-derive it and
#       `_default_trace_color` reports it. Empty for `:default`. Prefer
#       `_apply_style_trace_defaults!`, which applies these to finished traces.
#
#   _apply_style_trace_defaults!(fig, trace_indices; style = _active_style(), explicit = ())
#       Fill the active style's line width, marker size and dash/marker cycle
#       into the traces at `trace_indices` (1-based positions in the figure's
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
# ─────────────────────────────────────────────────────────────────────────────

export PlotStyle, set_default_style!, get_default_style, with_style, register_style!
export set_fonts!, tight_layout!, figsize!

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
# through unchanged (after checking they parse); Colorants become hex/rgba.
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
const _STYLE_CYCLES = (:none, :bw, :dash, :marker, :dash_marker)
# `mathsize` accepts exactly the MathJax 2 size switches the mathtext pipeline
# accepts (`_MATHTEXT_SIZES`, src/sci/mathtext.jl): `\footnotesize` does not
# exist in MathJax 2 and would render as a red undefined macro.
const _STYLE_MATHSIZES = ("", ("\\" * name for name in _MATHTEXT_SIZES)...)
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
		grid=true, legend_frame=true, margin=nothing, mathsize="", cycle=:none)

A named bundle of figure defaults (the PlotlySupply analogue of matplotlib
`rcParams`). The active style is chosen with [`set_default_style!`](@ref) or
temporarily with [`with_style`](@ref); styles are registered by name with
[`register_style!`](@ref). Built-in styles:

- `:default` — exactly the PlotlySupply 1.x look: the package default template
  (see `set_default_template!`), black closed spines, outside ticks, plotly's
  default fonts, colours and margins.
- `:publication` — black STIX/Times text (`font_family="STIXGeneral, Times New
  Roman, serif"`, `fontsize=14`, `title_fontsize=16`, `label_fontsize=14`,
  `tick_fontsize=12`, `legend_fontsize=12`), the Okabe–Ito colour-blind-safe
  colorway, a closed box, a frameless legend, `\\large` math and a 10 px margin
  that grows automatically to fit labels and the title.

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
- `colorway=nothing`: trace colour cycle; a palette name `Symbol` from
  `PlotlyBase.colors` (e.g. `:okabe_ito`, `:tab10`, `:tol_bright`), a vector
  of colours, or a `ColorScheme`. Stored as a `Vector{String}`.
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
  is not used). The cycle counts the line-style (scatter-type) traces of a
  figure, so it continues across `plot_*!` appends.

Numeric fields use `0` as "unset"; negative and non-finite values throw an
`ArgumentError`.

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
		cycle;
		who::AbstractString = "PlotStyle",
	)
		v(name, value) = _style_validate_field(name, value, who)
		return new(
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
		)
	end
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
		haskey(PlotlyBase.colors.all, value) ||
			throw(ArgumentError(
				"$(who): unknown palette $(repr(value)); use a palette name from " *
				"`PlotlyBase.colors` (e.g. :okabe_ito, :tab10, :tol_bright), a vector " *
				"of colours, or a ColorScheme.",
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
	elseif name in (:linewidth, :marker_size)
		return _style_nonnegative(value, who, String(name))
	elseif name === :ticks
		return _style_ticks(value, who)
	elseif name === :spines
		return _style_symbol_choice(value, _STYLE_SPINES, who, "spines")
	elseif name in (:grid, :legend_frame)
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
	return setfield!(style, name, _style_validate_field(name, value, "PlotStyle"))
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

_publication_plot_style() = PlotStyle(
	;
	template = :plotly_white,
	font_family = "STIXGeneral, Times New Roman, serif",
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
)

const _BUILTIN_STYLE_NAMES = (:default, :publication)
const _STYLE_LOCK = ReentrantLock()
const _STYLE_REGISTRY = Dict{Symbol, PlotStyle}(
	:default => _default_plot_style(),
	:publication => _publication_plot_style(),
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
`:publication`, or a name given to [`register_style!`](@ref)). Keyword arguments
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
replaces it; the built-in names `:default` and `:publication` cannot be
redefined (`ArgumentError`). Returns `name`.

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
	defaults = Dict{Symbol, Any}(
		:zeroline => false,
		:showline => style.spines !== :none,
		:mirror => style.spines === :box,
		:ticks => style.ticks,
		:automargin => true,
		:linecolor => ink,
		:linewidth => _DEFAULT_AXIS_LINEWIDTH,
		:tickcolor => ink,
	)
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
	if style.cycle === :bw
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
	cycle = style.cycle
	if cycle in (:bw, :dash, :dash_marker)
		defaults[:dash] = _STYLE_DASH_CYCLE[mod1(trace_index, length(_STYLE_DASH_CYCLE))]
	end
	if cycle in (:marker, :dash_marker)
		defaults[:marker_symbol] =
			_STYLE_MARKER_CYCLE[mod1(trace_index, length(_STYLE_MARKER_CYCLE))]
		defaults[:markers] = true
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
- `style::PlotStyle`: the style whose `linewidth`, `marker_size` and `cycle`
  are applied.
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
the values written are in each type's allowed set. Every other trace (bar,
histogram, box, violin, heatmap, contour, surface, mesh3d, cone, pie, the map
scatter types, non-`GenericTrace` traces, …) is skipped and never written, so
no attribute is ever added to a trace type that lacks it.

A value counts as unset when the attribute is absent, `nothing`, `missing` or
`""` (the 1.x `line.dash = ""` sentinel); any other value — a number, a name,
a per-point vector — is the caller's and is kept. Filled where unset:

- `line.width` ← `style.linewidth`, `marker.size` ← `style.marker_size`
  (each only when the style sets it, i.e. > 0);
- `line.dash` ← the dash cycle `solid, dash, dot, dashdot` (`cycle` `:bw`,
  `:dash`, `:dash_marker`);
- `marker.symbol` ← the marker cycle (`:marker`, `:dash_marker`):
  `circle, square, diamond, triangle-up, x, triangle-down, cross, star`, and
  for `scatter3d` (which accepts only eight symbols) `circle, square,
  diamond, x, cross, circle-open, square-open, diamond-open`. When the symbol
  is filled and `mode` (a string or `Symbol`, not in `explicit`) draws lines
  but no markers, the `markers` flag is added so the symbol shows
  (`"lines"` → `"lines+markers"`, `"lines+text"` → `"lines+markers+text"`).
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
  `marker_size = 0`, `cycle = :none`) nothing is touched.

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
	isempty(_style_trace_defaults(style, 1)) && return nothing

	# All updates are computed first, then committed.
	pending = Tuple{Int, Dict{Symbol, Any}}[]
	offset = _STYLE_TRACE_OFFSET[]
	for index in unique(indices)
		trace = data[index]
		_style_is_line_trace(trace) || continue
		position = offset + count(_style_is_line_trace, view(data, 1:index))
		updates = _style_trace_default_updates(
			trace,
			_style_trace_defaults(style, position),
			position,
			explicit_names,
			"$(who): data[$(index)]",
		)
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
	role_layout, role_traces = _font_role_updates(p, roles, nothing, "PlotStyle"; base = updates)
	merge!(updates, role_layout)
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
	for (key, value) in updates
		fields[key] = value
	end
	_commit_trace_updates!(p, role_traces)
	return nothing
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
	if !isempty(colorbar_tick_font) || !isempty(colorbar_title_font)
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
				updates[sub] = new_sub
			end
			isempty(updates) || push!(trace_new, index => updates)
		end
		for key in sort!(collect(coloraxis_keys))
			update!(key, (:colorbar, :tickfont), colorbar_tick_font)
			update!(key, (:colorbar, :title, :font), colorbar_title_font)
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
# Figure size assumed when the layout has none: the package's savefig default.
const _TIGHT_DEFAULT_WIDTH = 700.0
const _TIGHT_DEFAULT_HEIGHT = 500.0
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

# Pixels by which paper-referenced annotations overhang each side of the plot
# area. Plotly annotations never push margins themselves.
function _tight_annotation_overhang(layout::Layout, lookup, width::Float64, height::Float64, root_size::Float64)
	overhang = Dict(:l => 0.0, :r => 0.0, :t => 0.0, :b => 0.0)
	annotations = lookup(:annotations)
	annotations isa AbstractVector || return overhang
	for annotation in annotations
		d = _symbol_dict(annotation)
		get(d, :visible, true) === false && continue
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
	width = _tight_real(lookup(:width), _TIGHT_DEFAULT_WIDTH)
	height = _tight_real(lookup(:height), _TIGHT_DEFAULT_HEIGHT)
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
	_refresh!(fig)
	return nothing
end

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
- paper-referenced annotations above, below or beside the plot area (subplot
  titles, panel labels) are measured and the margin on that side is enlarged
  by their estimated extent (plain text 1.3 em per `<br>` line with
  per-glyph widths; TeX labels such as those [`mathtext`](@ref) writes are
  measured as typeset: one row per row of a multi-line `array`, commands,
  braces and `\\text{…}` wrappers stripped, scripts at 70 %, fractions and
  roots taller. The estimate errs on the large side, by up to about 20 % for
  text and more for very short TeX labels. Annotations in data coordinates
  are not measured). When such
  annotations sit above the plot area, the estimated title height is added to
  the top margin as well, so the title stays above them. Each enlargement is
  capped at 45 % of the figure width or height.

The figure size used for the measurement is `layout.width`/`layout.height`
(see [`figsize!`](@ref)), else 700 × 500 px. A title with `yref="paper"` is
placed by plotly directly above the plot area and is not moved. Bare-string
titles are converted to `attr(text=…, automargin=true, pad=attr(t=pad))`.
Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_scatter(1:10, (1:10) .^ 2; xlabel = "x", ylabel = "y", title = "Tight")
tight_layout!(fig)            # 4 px margins plus the room the labels need
tight_layout!(fig; pad = 0)
```
"""
function tight_layout!(fig; pad::Real = 4)
	return _tight_layout_impl!(fig; pad = pad)
end

function _tight_layout_subplot_impl!(sf::SubplotFigure; pad::Real = 4)
	_tight_layout_impl!(sf.fig; pad = pad)
	return sf
end

function tight_layout!(sf::SubplotFigure; pad::Real = 4)
	return _transactional_subplot_mutation!(
		_tight_layout_subplot_impl!,
		sf,
		();
		pad = pad,
	)
end

# ── figsize! ─────────────────────────────────────────────────────────────────

const _FIGSIZE_UNITS = (:px, :in, :cm, :mm, :pt)
# plotly.js rejects layout.width/height below 10 px.
const _FIGSIZE_MIN_PX = 10
# Overflow guard only (round(Int, ·) must not throw InexactError); no display
# or export canvas comes anywhere near 2^31 px.
const _FIGSIZE_MAX_PX = typemax(Int32)

function _figsize_px(width, height, units, who::AbstractString)
	units isa Symbol ||
		throw(ArgumentError("$(who): `units` must be a Symbol; got $(repr(units))."))
	scale = _style_px_per_unit(units, _FIGSIZE_UNITS, who)
	result = map((("width", width), ("height", height))) do (name, value)
		v = _style_real(value, who, name)
		v > 0 || throw(ArgumentError("$(who): `$(name)` must be > 0; got $(value)."))
		v * scale <= _FIGSIZE_MAX_PX ||
			throw(ArgumentError(
				"$(who): `$(name)` = $(value) $(units) exceeds $(_FIGSIZE_MAX_PX) px.",
			))
		# Raster export and the browser canvas are whole CSS pixels.
		px = round(Int, v * scale)
		px >= _FIGSIZE_MIN_PX ||
			throw(ArgumentError(
				"$(who): `$(name)` is $(px) px after conversion from $(value) $(units); plotly requires at least $(_FIGSIZE_MIN_PX) px.",
			))
		px
	end
	return result[1], result[2]
end

function _figsize_impl!(fig, width::Real, height::Real; units::Symbol = :px)
	w, h = _figsize_px(width, height, units, "figsize!")
	fields = _plot_layout(fig).fields
	fields[:width] = w
	fields[:height] = h
	_refresh!(fig)
	return nothing
end

"""
	figsize!(fig, width::Real, height::Real; units=:px)
	figsize!(sf::SubplotFigure, width::Real, height::Real; units=:px)

Set the figure size, stored as `layout.width`/`layout.height` in CSS pixels so
displays and exports pick it up. `units` is `:px`, `:in`, `:cm`, `:mm` or
`:pt`, converted at the CSS reference resolution of 96 px/in (1 pt = 1/72 in)
and rounded to whole pixels (raster canvases are whole pixels; the rounding
error is below 0.5 px, 0.13 mm). Both sizes must be finite, positive and at
least 10 px after conversion (plotly's minimum). Returns `nothing` for a
`Plot`/`SyncPlot` and `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_scatter(1:10, (1:10) .^ 2)
figsize!(fig, 3.5, 2.5; units = :in)     # 336 × 240 px
savefig(fig, "fig.pdf"; width = 336, height = 240)
```
"""
function figsize!(fig, width::Real, height::Real; units::Symbol = :px)
	return _figsize_impl!(fig, width, height; units = units)
end

function _figsize_subplot_impl!(sf::SubplotFigure, width::Real, height::Real; units::Symbol = :px)
	_figsize_impl!(sf.fig, width, height; units = units)
	return sf
end

function figsize!(sf::SubplotFigure, width::Real, height::Real; units::Symbol = :px)
	return _transactional_subplot_mutation!(
		_figsize_subplot_impl!,
		sf,
		(),
		width,
		height;
		units = units,
	)
end
