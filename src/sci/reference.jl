# PlotlySupply 2.0 scientific-plotting extensions: hline!/vline!/hspan!/vspan!, schematic shapes, arrows, slope guides.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_REFERENCE_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# Conventions shared by every helper in this file (spec F16a-d):
# - Target: a `Plot`, a `SyncPlot`, or one Cartesian cell of a `SubplotFigure`
#   (`row`/`col`, both or neither, default the active cell; `inset = k` for an
#   inset registered by `inset!`). `secondary_y = true` addresses the cell's
#   secondary y axis; on a plain figure that axis is created on first use with
#   `_ensure_twin_y!`, as the trace mutators do.
# - Every coordinate argument is a DATA value on every axis type. Shapes
#   (lines, rectangles, circles, paths) are written in data units, which
#   plotly.js maps through the axis (`d2r`, i.e. log10 on a log axis).
#   Annotations (arrows and text labels) are written in axis units: log10 of
#   the value on a log axis. Both conventions were checked by rendering
#   (probe1_log.png in the reference scratch directory). Non-positive values on
#   a log axis are an `ArgumentError`.
# - Additive: every call appends new shapes, annotations and traces. Nothing
#   drawn earlier is replaced or de-duplicated, so `hline!(fig, 1)` twice
#   draws two lines. Items are named `"plotlysupply:<helper>:<row>:<col>"`
#   (`0:0` on a plain figure) so the cell they belong to can be recovered
#   (`set_fonts!(sf; row, col)` uses that pattern); the name is not unique.
# - Shapes and annotations are rewritten as whole arrays through `relayout!`
#   (the staged fast-path target has no `update_shapes!`); legend entries are
#   legend-only proxy traces (`_proxy_trace`).
# - Everything is validated before the first write; errors are
#   `ArgumentError("<helper>: ...")`, and the transactional wrappers leave the
#   figure unchanged when one is raised.
# - Plot/SyncPlot methods return `nothing`; SubplotFigure methods return `sf`.

const _SCI_REFERENCE_MUTATORS = (
	:hline!,
	:vline!,
	:hspan!,
	:vspan!,
	:circle!,
	:ellipse!,
	:rectangle!,
	:polygon!,
	:arrow!,
	:arc!,
	:slope_guide!,
	:slope_triangle!,
)

export hline!, vline!, hspan!, vspan!
export circle!, ellipse!, rectangle!, polygon!, arrow!, arc!
export slope_guide!, slope_triangle!

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Plotly line dash names (layout.shapes[].line.dash, scatter line.dash).
const _REF_DASH_NAMES = ("solid", "dot", "dash", "longdash", "dashdot", "longdashdot")
# matplotlib linestyle codes and their Plotly equivalents.
const _REF_DASH_ALIASES = Dict{String, String}(
	"-" => "solid",
	"--" => "dash",
	":" => "dot",
	"-." => "dashdot",
)
# Plotly dash-length list, e.g. "5px,10px,2px,2px" or "5%,10%".
const _REF_DASH_LIST = r"^\s*\d+(\.\d+)?(px|%)?(\s*,\s*\d+(\.\d+)?(px|%)?)*\s*$"

# Shape layers of plotly.js 2.35.2: "between" draws above the grid lines and
# below the traces.
const _REF_LAYERS = ("above", "below", "between")

# layout.shapes[].label.textposition values of plotly.js 2.35.2.
const _REF_LINE_LABEL_POSITIONS = ("start", "middle", "end")
const _REF_AREA_LABEL_POSITIONS = (
	"top left",
	"top center",
	"top right",
	"middle left",
	"middle center",
	"middle right",
	"bottom left",
	"bottom center",
	"bottom right",
)

# Plotly annotation limits (plotly.js 2.35.2 annotation attributes):
# `arrowwidth >= 0.1` and `arrowsize >= 0.3`; smaller values are discarded by
# plotly.js and replaced by its defaults.
const _REF_MIN_ARROW_WIDTH = 0.1
const _REF_MIN_ARROW_SIZE = 0.3
# Plotly arrowhead style 2: the narrow filled head used by the spec (F16c).
const _REF_ARROWHEAD = 2

# Path sampling of curved schematics (spec F16c): a full ellipse uses 128
# vertices; an arc uses 128 per full turn and never fewer than 32.
const _REF_ELLIPSE_POINTS = 128
const _REF_ARC_POINTS_PER_TURN = 128
const _REF_ARC_MIN_POINTS = 32

# Arc arrowheads are annotations whose (invisible) tail sits on the tangent at
# the arc end, this fraction of the radius back from the tip (capped at half
# the arc length). The tangent segment deviates from the arc by about
# (0.1 r)^2 / (2 r) = 0.005 r, under a pixel for radii below 200 px, while
# leaving a shaft long enough that plotly.js keeps the head (it hides heads on
# arrows shorter than the head's back-off, about 1.3 px per unit width).
const _REF_ARC_HEAD_TAIL = 0.1

# Slope guides off log-log axes are curves; 64 samples follow them smoothly
# (spec F16d).
const _REF_SLOPE_SAMPLES = 64
# Gap in px between a guide/triangle and its label, so the text does not
# touch the line it annotates.
const _REF_LABEL_GAP = 4

# ---------------------------------------------------------------------------
# Keyword validation
# ---------------------------------------------------------------------------

# Every helper takes `kwargs...` only to turn `show` and misspelled keywords
# into ArgumentErrors (a MethodError would name the internal staged type).
function _ref_reject_extra_kwargs(who::AbstractString, kwargs)
	for (key, _) in kwargs
		key === :show && throw(ArgumentError(
			"$(who): `show` is not accepted; $(who) draws into the figure it is " *
			"given. Display that figure with `display(fig)` or open a window " *
			"with `to_syncplot(fig)`.",
		))
		throw(ArgumentError("$(who): unsupported keyword argument `$(key)`."))
	end
	return nothing
end

# vline!/vspan! span the whole cell height, which is the same for the primary
# and the secondary y axis, so they take no `secondary_y` (the shared
# implementation receives it as a keyword; anything but the default is an
# error rather than silently meaningless).
function _ref_reject_vertical_secondary_y(who::AbstractString, secondary_y)
	secondary_y === false || throw(ArgumentError(
		"$(who): unsupported keyword argument `secondary_y`; a vertical " *
		"$(who == "vline!" ? "line" : "span") covers the whole cell height, " *
		"which is the same for the primary and the secondary y axis.",
	))
	return nothing
end

_ref_is_real(v) = v isa Real && !(v isa Bool)

function _ref_finite(v, who::AbstractString, name::AbstractString)::Float64
	(_ref_is_real(v) && isfinite(v)) || throw(ArgumentError(
		"$(who): `$(name)` must be a finite real number; got $(repr(v)).",
	))
	return Float64(v)
end

function _ref_positive(v, who::AbstractString, name::AbstractString)::Float64
	x = _ref_finite(v, who, name)
	x > 0 || throw(ArgumentError("$(who): `$(name)` must be positive; got $(repr(v))."))
	return x
end

function _ref_nonnegative(v, who::AbstractString, name::AbstractString)::Float64
	x = _ref_finite(v, who, name)
	x >= 0 || throw(ArgumentError("$(who): `$(name)` must be >= 0; got $(repr(v))."))
	return x
end

function _ref_opacity(v, who::AbstractString)::Float64
	x = _ref_finite(v, who, "opacity")
	0 <= x <= 1 || throw(ArgumentError(
		"$(who): `opacity` must lie in [0, 1]; got $(repr(v)).",
	))
	return x
end

function _ref_bool(v, who::AbstractString, name::AbstractString)::Bool
	v isa Bool || throw(ArgumentError(
		"$(who): `$(name)` must be true or false; got $(repr(v)).",
	))
	return v
end

function _ref_string(s, who::AbstractString, name::AbstractString)::String
	s isa AbstractString || throw(ArgumentError(
		"$(who): `$(name)` must be a string; got $(repr(s)).",
	))
	return String(s)
end

# A string or Symbol option, returned as a lower-case-preserving String.
function _ref_name_option(s, who::AbstractString, name::AbstractString)::String
	(s isa AbstractString || s isa Symbol) || throw(ArgumentError(
		"$(who): `$(name)` must be a string or Symbol; got $(repr(s)).",
	))
	return String(s)
end

# Font size in px; 0 keeps the layout default.
_ref_fontsize(v, who::AbstractString)::Float64 = _ref_nonnegative(v, who, "fontsize")

# A pair of finite reals given as a 2-tuple or a 2-element vector.
function _ref_pair(v, who::AbstractString, name::AbstractString)::NTuple{2, Float64}
	(v isa Tuple || v isa AbstractVector) || throw(ArgumentError(
		"$(who): `$(name)` must be a 2-tuple or 2-element vector of real numbers; " *
		"got $(repr(v)).",
	))
	length(v) == 2 || throw(ArgumentError(
		"$(who): `$(name)` must have exactly 2 elements; got $(length(v)).",
	))
	a, b = first(v), last(v)
	(_ref_is_real(a) && _ref_is_real(b) && isfinite(a) && isfinite(b)) ||
		throw(ArgumentError(
			"$(who): `$(name)` must hold two finite real numbers; got $(repr(v)).",
		))
	return (Float64(a), Float64(b))
end

# Colour keyword -> canonical CSS colour ("#RRGGBB", or "rgba(...)" when not
# opaque) via `_color_hex`, so Symbols and every colour form color.jl parses
# work. `""` means "not set" (Plotly's default is used); with
# `none_is_empty = true`, `"none"` (matplotlib's "no colour") is the same.
function _ref_color(c, who::AbstractString, name::AbstractString; none_is_empty::Bool = false)::String
	(c isa AbstractString || c isa Symbol) || throw(ArgumentError(
		"$(who): `$(name)` must be a colour string or Symbol; got $(repr(c)).",
	))
	s = strip(String(c))
	isempty(s) && return ""
	none_is_empty && lowercase(s) == "none" && return ""
	return _color_hex(s; who = who)
end

function _ref_dash(d, who::AbstractString)::String
	s = _ref_name_option(d, who, "dash")
	isempty(s) && return ""
	s in _REF_DASH_NAMES && return s
	haskey(_REF_DASH_ALIASES, s) && return _REF_DASH_ALIASES[s]
	occursin(_REF_DASH_LIST, s) && return replace(s, r"\s+" => "")
	throw(ArgumentError(
		"$(who): `dash` must be \"\" (solid), one of " *
		"$(join(repr.(_REF_DASH_NAMES), ", ")), a matplotlib code " *
		"(\"-\", \"--\", \":\", \"-.\") or a dash-length list such as " *
		"\"5px,3px\"; got $(repr(d)).",
	))
end

function _ref_layer(l, who::AbstractString)::String
	s = _ref_name_option(l, who, "layer")
	s in _REF_LAYERS || throw(ArgumentError(
		"$(who): `layer` must be one of $(join(repr.(_REF_LAYERS), ", ")); " *
		"got $(repr(l)).",
	))
	return s
end

# Shape-label position: "start"/"middle"/"end" along a line shape, or one of
# the nine "<vertical> <horizontal>" positions inside an area shape. Symbols
# may use underscores (`:top_left`); "mid" and "center" are accepted for
# "middle" and "middle center". `""` keeps Plotly's default.
function _ref_label_position(pos, line::Bool, who::AbstractString)::String
	s = replace(_ref_name_option(pos, who, "labelpos"), '_' => ' ')
	isempty(s) && return ""
	if line
		s == "mid" && (s = "middle")
		s in _REF_LINE_LABEL_POSITIONS && return s
		allowed = _REF_LINE_LABEL_POSITIONS
	else
		s in ("center", "middle", "mid") && (s = "middle center")
		s in _REF_AREA_LABEL_POSITIONS && return s
		allowed = _REF_AREA_LABEL_POSITIONS
	end
	throw(ArgumentError(
		"$(who): `labelpos` must be \"\" (Plotly's default) or one of " *
		"$(join(repr.(allowed), ", ")); got $(repr(pos)).",
	))
end

# Plotly shape `label` attribute, or `nothing` without text. Shape labels are
# never typeset by MathJax (data-notex), so the text goes through
# `_label_plain` (TeX approximated with Unicode and <sup>/<sub>).
function _ref_shape_label(who::AbstractString, label, labelpos, fontsize; line::Bool)
	text = _ref_string(label, who, "label")
	position = _ref_label_position(labelpos, line, who)
	size = _ref_fontsize(fontsize, who)
	isempty(text) && return nothing
	fields = Dict{Symbol, Any}(:text => _label_plain(text))
	isempty(position) || (fields[:textposition] = position)
	size > 0 && (fields[:font] = attr(Dict{Symbol, Any}(:size => size)))
	return attr(fields)
end

# Annotation font: `color` (may be "") and `size` (0 = default).
function _ref_font(color::String, size::Float64)
	fields = Dict{Symbol, Any}()
	isempty(color) || (fields[:color] = color)
	size > 0 && (fields[:size] = size)
	return isempty(fields) ? nothing : attr(fields)
end

# One data value or a vector of them, each finite (and positive on a log
# axis). An abstractly typed vector (`Any[1, 2.5]`) is accepted when every
# element is a real number.
function _ref_values(v, log::Bool, who::AbstractString, name::AbstractString)::Vector{Float64}
	values = v isa AbstractVector ? v : (v,)
	out = Float64[]
	sizehint!(out, length(values))
	for (k, value) in enumerate(values)
		label = v isa AbstractVector ? "$(name)[$(k)]" : name
		push!(out, _ref_coord(value, log, who, label))
	end
	return out
end

# Data value for a position on an axis: finite, and positive on a log axis.
function _ref_coord(v, log::Bool, who::AbstractString, name::AbstractString)::Float64
	x = _ref_finite(v, who, name)
	log && x <= 0 && throw(ArgumentError(
		"$(who): `$(name)` = $(x) cannot be placed on a logarithmic axis; " *
		"log-axis values must be positive.",
	))
	return x
end

# Data value -> annotation coordinate (log10 on a log axis), as
# `_to_axis_coord` does; the value was validated by `_ref_coord`.
_ref_axis_unit(x::Float64, log::Bool) = log ? log10(x) : x
_ref_from_axis_unit(u::Float64, log::Bool) = log ? exp10(u) : u

# Shapes whose geometry is a length in data units (a radius, semi-axes, a
# corner radius) have no fixed size on a logarithmic axis.
function _ref_require_linear(target, who::AbstractString, what::AbstractString)
	(target.xlog || target.ylog) && throw(ArgumentError(
		"$(who): $(what) is defined by lengths in data units, which have no " *
		"fixed size on a logarithmic axis; use it on linear axes (`polygon!` " *
		"and `rectangle!` without `rounded` work on log axes).",
	))
	return nothing
end

# ---------------------------------------------------------------------------
# Target resolution and writes
# ---------------------------------------------------------------------------

# Resolved drawing target of one call: the Cartesian cell, whether its x / y
# axes are logarithmic, and whether a twin y axis still has to be created on
# a plain figure (`secondary_y = true` before any twin exists; the new axis is
# linear).
struct _RefTarget
	cell::_CellTarget
	xlog::Bool
	ylog::Bool
	create_twin::Bool
end

function _ref_require_xy(cell::_CellTarget, who::AbstractString)
	cell.kind === :xy || throw(ArgumentError(
		"$(who): needs Cartesian x/y axes; " *
		(cell.row == 0 ? "this figure is" : "subplot cell ($(cell.row), $(cell.col)) is") *
		" a :$(cell.kind) subplot.",
	))
	return nothing
end

function _ref_target(fig, who::AbstractString; row, col, secondary_y, inset)
	twin = _ref_bool(secondary_y, who, "secondary_y")
	layout = _cmn_layout(fig)
	if twin && !(fig isa SubplotFigure)
		base = _cell_target(fig; row = row, col = col, secondary_y = false, inset = inset, who = who)
		_ref_require_xy(base, who)
		if _cmn_twin_y_key(layout) === nothing
			return _RefTarget(base, _axis_type(layout, base.xkey) == "log", false, true)
		end
	end
	cell = _cell_target(fig; row = row, col = col, secondary_y = twin, inset = inset, who = who)
	_ref_require_xy(cell, who)
	return _RefTarget(
		cell,
		_axis_type(layout, cell.xkey) == "log",
		_axis_type(layout, cell.ykey) == "log",
		false,
	)
end

# First write of every helper: create the twin y axis when it was requested
# and missing, and return the final cell.
function _ref_commit_target!(fig, target::_RefTarget, who::AbstractString)::_CellTarget
	target.create_twin || return target.cell
	_ensure_twin_y!(fig; who = who)
	return _cell_target(fig; secondary_y = true, who = who)
end

_ref_item_name(who::AbstractString, cell::_CellTarget) =
	"plotlysupply:$(who):$(cell.row):$(cell.col)"

# Validation part of an array write: the existing layout array must be a
# vector (a hand-written scalar would otherwise fail half-way).
function _ref_check_layout_array(fig, field::Symbol, who::AbstractString)
	existing = get(_cmn_layout(fig).fields, field, nothing)
	(existing === nothing || existing isa AbstractVector) || throw(ArgumentError(
		"$(who): layout.$(field) must be a vector; got $(typeof(existing)).",
	))
	return nothing
end

# Append `items` to layout.shapes / layout.annotations as one whole-array
# `relayout!` (existing items keep their order and identity).
function _ref_append_items!(fig, field::Symbol, items::Vector{Any})
	isempty(items) && return nothing
	existing = get(_cmn_layout(fig).fields, field, nothing)
	combined = Any[]
	existing === nothing || append!(combined, existing)
	append!(combined, items)
	relayout!(_cmn_relayout_target(fig); (field => combined,)...)
	return nothing
end

# Append a trace to the target cell: a SubplotFigure trace carries the cell's
# axis references (an inset's axes for `inset = k`); on a plain figure only a
# twin y axis needs an explicit reference.
function _ref_push_trace!(fig, cell::_CellTarget, trace::GenericTrace)
	if fig isa SubplotFigure
		trace.fields[:xaxis] = cell.xref
		trace.fields[:yaxis] = cell.yref
		push!(_cmn_plot(fig).data, trace)
	else
		cell.yref == "y" || (trace.fields[:yaxis] = cell.yref)
		push!(_plot_data(fig), trace)
	end
	return nothing
end

# Legend bookkeeping after traces were added: per-cell legends on a
# SubplotFigure (as `add_trace!(sf, ...)` does), the styled default legend on
# a plain figure (written only when some trace shows in the legend).
function _ref_refresh_legends!(fig)
	if fig isa SubplotFigure
		if getfield(fig, :per_subplot_legends)
			_apply_subplot_legends!(
				_cmn_plot(fig);
				legend_position = fig.legend_position,
				legend_inset = fig.legend_inset,
				legend_bgcolor = fig.legend_bgcolor,
				legend_bordercolor = fig.legend_bordercolor,
				legend_borderwidth = fig.legend_borderwidth,
			)
		end
	else
		_apply_default_legend!(fig)
	end
	return nothing
end

# Last step of every helper: a SubplotFigure call makes the target cell
# active and returns the (staged) figure; a Plot/SyncPlot call returns
# `nothing` (`_refresh!` is a no-op on the staged targets of the wrappers).
function _ref_done!(fig, cell::_CellTarget)
	if fig isa SubplotFigure
		fig.current_row = cell.row
		fig.current_col = cell.col
		return fig
	end
	_refresh!(fig)
	return nothing
end

# Run `impl!` on one SubplotFigure cell as a single transaction.
_ref_subplot_call!(impl!, sf::SubplotFigure, args...; kwargs...) =
	_transactional_subplot_mutation!(
		impl!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		args...;
		kwargs...,
	)

# ---------------------------------------------------------------------------
# Shape styles
# ---------------------------------------------------------------------------

# Line style of a line/path outline: colour ("" = Plotly default), width
# (px, >= 0), dash, opacity, layer.
function _ref_line_style(who::AbstractString; color, dash, linewidth, opacity, layer)
	return (
		color = _ref_color(color, who, "color"),
		width = _ref_nonnegative(linewidth, who, "linewidth"),
		dash = _ref_dash(dash, who),
		opacity = _ref_opacity(opacity, who),
		layer = _ref_layer(layer, who),
	)
end

function _ref_line_attr(color::String, width::Float64, dash::String)
	fields = Dict{Symbol, Any}(:width => width)
	isempty(color) || (fields[:color] = color)
	isempty(dash) || (fields[:dash] = dash)
	return attr(fields)
end

# Fill/edge style of an area shape. `fill == ""` leaves it unfilled; the
# outline is drawn when `edge != ""` and `width > 0`.
function _ref_area_style(who::AbstractString; fillcolor, edgecolor, linewidth, dash, opacity, layer)
	return (
		fill = _ref_color(fillcolor, who, "fillcolor"; none_is_empty = true),
		edge = _ref_color(edgecolor, who, "edgecolor"; none_is_empty = true),
		width = _ref_nonnegative(linewidth, who, "linewidth"),
		dash = _ref_dash(dash, who),
		opacity = _ref_opacity(opacity, who),
		layer = _ref_layer(layer, who),
	)
end

function _ref_area_fields!(fields::Dict{Symbol, Any}, style)
	isempty(style.fill) || (fields[:fillcolor] = style.fill)
	fields[:line] = if isempty(style.edge) || style.width == 0
		attr(Dict{Symbol, Any}(:width => 0))
	else
		_ref_line_attr(style.edge, style.width, style.dash)
	end
	style.opacity == 1 || (fields[:opacity] = style.opacity)
	fields[:layer] = style.layer
	return fields
end

# Legend proxy of an area shape: a filled square for a filled shape (with its
# edge when one is drawn), else a line sample of the outline.
function _ref_area_proxy(legend::String, style, who::AbstractString)
	isempty(legend) && return nothing
	edge_drawn = !isempty(style.edge) && style.width > 0
	if !isempty(style.fill)
		return _proxy_trace(
			legend;
			patch = true,
			color = style.fill,
			marker_line_color = edge_drawn ? style.edge : "",
			marker_line_width = edge_drawn ? style.width : 0,
			opacity = style.opacity,
			who = who,
		)
	end
	return _proxy_trace(
		legend;
		mode = "lines",
		color = style.edge,
		dash = style.dash,
		linewidth = edge_drawn ? style.width : 0,
		opacity = style.opacity,
		who = who,
	)
end

# Path coordinates are written with Julia's shortest round-trip form
# ("2.5", "1.0e-5"); plotly.js splits path parameters on spaces/commas and
# converts each with Number().
_ref_path_number(v::Float64) = string(v)

function _ref_path(xs::AbstractVector{Float64}, ys::AbstractVector{Float64}; closed::Bool)
	io = IOBuffer()
	for k in eachindex(xs, ys)
		print(io, k == firstindex(xs) ? "M" : " L", _ref_path_number(xs[k]), ",", _ref_path_number(ys[k]))
	end
	closed && print(io, " Z")
	return String(take!(io))
end

# Generic area-shape item (circle/rect/path) with style, label and name. The
# builder may set its own references (spans use "<axis> domain"); otherwise
# both are the cell's data axes.
function _ref_area_item(fields::Dict{Symbol, Any}, cell::_CellTarget, style, label, name::String)
	get!(fields, :xref, cell.xref)
	get!(fields, :yref, cell.yref)
	_ref_area_fields!(fields, style)
	label === nothing || (fields[:label] = label)
	fields[:name] = name
	return attr(fields)
end

# Shared body of the area schematics (circle!, ellipse!, rectangle!,
# polygon!): `build(cell)` returns the shape fields once the target is final.
function _ref_draw_area!(fig, who::AbstractString, target::_RefTarget, style, label, legend::String, build)
	proxy = _ref_area_proxy(legend, style, who)
	_ref_check_layout_array(fig, :shapes, who)
	cell = _ref_commit_target!(fig, target, who)
	_ref_append_items!(fig, :shapes, Any[_ref_area_item(build(cell), cell, style, label, _ref_item_name(who, cell))])
	if proxy !== nothing
		_ref_push_trace!(fig, cell, proxy)
		_ref_refresh_legends!(fig)
	end
	return _ref_done!(fig, cell)
end

# ---------------------------------------------------------------------------
# F16a: hline! / vline!
# ---------------------------------------------------------------------------

function _ref_axis_lines!(
	fig,
	values,
	horizontal::Bool;
	color = "black",
	dash = "",
	linewidth = 1,
	opacity = 1,
	layer = "above",
	legend = "",
	label = "",
	labelpos = "",
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = horizontal ? "hline!" : "vline!"
	_ref_reject_extra_kwargs(who, kwargs)
	horizontal || _ref_reject_vertical_secondary_y(who, secondary_y)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	positions = _ref_values(values, horizontal ? target.ylog : target.xlog, who, horizontal ? "y" : "x")
	style = _ref_line_style(who; color = color, dash = dash, linewidth = linewidth, opacity = opacity, layer = layer)
	shape_label = _ref_shape_label(who, label, labelpos, fontsize; line = true)
	legend_text = _ref_string(legend, who, "legend")
	proxy = (isempty(legend_text) || isempty(positions)) ? nothing : _proxy_trace(
		legend_text;
		mode = "lines",
		color = style.color,
		dash = style.dash,
		linewidth = style.width,
		opacity = style.opacity,
		who = who,
	)
	_ref_check_layout_array(fig, :shapes, who)

	cell = _ref_commit_target!(fig, target, who)
	name = _ref_item_name(who, cell)
	items = Any[]
	for v in positions
		fields = Dict{Symbol, Any}(
			:type => "line",
			:line => _ref_line_attr(style.color, style.width, style.dash),
			:layer => style.layer,
			:name => name,
		)
		if horizontal
			fields[:xref] = cell.xref * " domain"
			fields[:x0] = 0
			fields[:x1] = 1
			fields[:yref] = cell.yref
			fields[:y0] = v
			fields[:y1] = v
		else
			fields[:yref] = cell.yref * " domain"
			fields[:y0] = 0
			fields[:y1] = 1
			fields[:xref] = cell.xref
			fields[:x0] = v
			fields[:x1] = v
		end
		style.opacity == 1 || (fields[:opacity] = style.opacity)
		shape_label === nothing || (fields[:label] = shape_label)
		push!(items, attr(fields))
	end
	_ref_append_items!(fig, :shapes, items)
	if proxy !== nothing
		_ref_push_trace!(fig, cell, proxy)
		_ref_refresh_legends!(fig)
	end
	return _ref_done!(fig, cell)
end

_ref_hline!(fig, y; kwargs...) = _ref_axis_lines!(fig, y, true; kwargs...)
_ref_vline!(fig, x; kwargs...) = _ref_axis_lines!(fig, x, false; kwargs...)

"""
	hline!(fig, y; color="black", dash="", linewidth=1, opacity=1, layer="above",
	       legend="", label="", labelpos="", fontsize=0, secondary_y=false)
	hline!(sf::SubplotFigure, y; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw horizontal reference lines (matplotlib `axhline`) across the full width
of the plot area at the data value(s) `y`.

`y` is one real number or a vector of them (one line each; an empty vector
draws nothing). Values are data values on every axis type, including log
axes, where they must be positive. Each value becomes a Plotly line shape with
`xref = "<x> domain"`, `x0 = 0`, `x1 = 1` and `yref` the y axis in data units.
Calls are additive: calling `hline!` again adds more lines.

# Keywords
- `color::Union{AbstractString,Symbol} = "black"`: line colour (any colour
  `colormap`/CSS understands; `""` uses Plotly's default).
- `dash::Union{AbstractString,Symbol} = ""`: `""` (solid), `"solid"`, `"dot"`,
  `"dash"`, `"longdash"`, `"dashdot"`, `"longdashdot"`, a matplotlib code
  (`"-"`, `"--"`, `":"`, `"-."`) or a dash-length list such as `"5px,3px"`.
- `linewidth::Real = 1`: line width in px (`>= 0`).
- `opacity::Real = 1`: opacity in `[0, 1]`.
- `layer::Union{AbstractString,Symbol} = "above"`: `"above"` the traces,
  `"below"` everything (grid lines included) or `"between"` the grid lines
  and the traces.
- `legend::AbstractString = ""`: when non-empty, adds one legend entry (a
  legend-only line sample in the same style) for all lines of this call.
- `label::AbstractString = ""`: text drawn on each line (Plotly shape label;
  never MathJax-typeset, so `\$...\$` is approximated with Unicode).
- `labelpos::Union{AbstractString,Symbol} = ""`: `"start"`, `"middle"` (or
  `:mid`) or `"end"` along the line; `""` is Plotly's default (middle).
- `fontsize::Real = 0`: label font size in px (0 = layout default).
- `secondary_y::Bool = false`: place the values on the secondary y axis (on a
  plain figure it is created when missing; in a SubplotFigure the cell needs
  `specs=[Spec(secondary_y=true) ...]`).
- SubplotFigure only: `row`, `col` (both or neither; default the active cell)
  and `inset::Integer` (an inset created by `inset!`). On a plain figure
  passing them is an `ArgumentError`.

`show` and unknown keywords raise `ArgumentError`, as do non-finite values,
non-positive values on a log axis and non-Cartesian targets; the figure is
then left unchanged.

Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a `SubplotFigure`
(whose target cell becomes the active cell).

# Example
```julia
fig = plot_scatter(1:10, (1:10) .^ 2; yscale = "log")
hline!(fig, [10, 50]; color = "red", dash = "dash", legend = "thresholds")
hline!(fig, 2; color = :gray, label = "floor", labelpos = :end)
```
"""
hline!(fig, y::Union{Real, AbstractVector}; kwargs...) = _ref_hline!(fig, y; kwargs...)
hline!(sf::SubplotFigure, y::Union{Real, AbstractVector}; kwargs...) =
	_ref_subplot_call!(_ref_hline!, sf, y; kwargs...)

"""
	vline!(fig, x; color="black", dash="", linewidth=1, opacity=1, layer="above",
	       legend="", label="", labelpos="", fontsize=0)
	vline!(sf::SubplotFigure, x; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw vertical reference lines (matplotlib `axvline`) over the full height of
the plot area at the data value(s) `x`: one real number or a vector of them
(positive on a log x axis). Each value becomes a Plotly line shape with
`yref = "<y> domain"`, `y0 = 0`, `y1 = 1` and `xref` the x axis in data
units. Calls are additive.

The keywords are those of [`hline!`](@ref) without `secondary_y` (a vertical
line spans the whole cell height, which is the same for both y axes).

Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a `SubplotFigure`.

# Example
```julia
sf = subplots(1, 2; sync = false)
plot_scatter!(sf, 0:0.1:2, sin.(0:0.1:2); row = 1, col = 2)
vline!(sf, [0.5, 1.5]; row = 1, col = 2, dash = :dot, legend = "events")
```
"""
vline!(fig, x::Union{Real, AbstractVector}; kwargs...) = _ref_vline!(fig, x; kwargs...)
vline!(sf::SubplotFigure, x::Union{Real, AbstractVector}; kwargs...) =
	_ref_subplot_call!(_ref_vline!, sf, x; kwargs...)

# ---------------------------------------------------------------------------
# F16b: hspan! / vspan!
# ---------------------------------------------------------------------------

function _ref_spans!(
	fig,
	lo,
	hi,
	horizontal::Bool;
	color = "#cccccc",
	opacity = 0.3,
	edgecolor = "",
	linewidth = nothing,
	layer = "below",
	legend = "",
	label = "",
	labelpos = "",
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = horizontal ? "hspan!" : "vspan!"
	_ref_reject_extra_kwargs(who, kwargs)
	horizontal || _ref_reject_vertical_secondary_y(who, secondary_y)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	log = horizontal ? target.ylog : target.xlog
	letter = horizontal ? "y" : "x"
	v0 = _ref_coord(lo, log, who, "$(letter)0")
	v1 = _ref_coord(hi, log, who, "$(letter)1")
	edge = _ref_color(edgecolor, who, "edgecolor"; none_is_empty = true)
	# The outline is drawn when an edge colour is given (width 1 unless
	# `linewidth` says otherwise) or when `linewidth > 0` (edge in the fill
	# colour, as matplotlib's axhspan draws it).
	width = linewidth === nothing ? (isempty(edge) ? 0.0 : 1.0) :
		_ref_nonnegative(linewidth, who, "linewidth")
	style = _ref_area_style(
		who;
		fillcolor = color,
		edgecolor = isempty(edge) ? color : edge,
		linewidth = width,
		dash = "",
		opacity = opacity,
		layer = layer,
	)
	shape_label = _ref_shape_label(who, label, labelpos, fontsize; line = false)
	legend_text = _ref_string(legend, who, "legend")
	# The rect spans the whole cell across the band: that direction uses the
	# "<axis> domain" reference (0..1 of the plot area).
	return _ref_draw_area!(fig, who, target, style, shape_label, legend_text, cell -> begin
		fields = Dict{Symbol, Any}(:type => "rect")
		if horizontal
			fields[:xref] = cell.xref * " domain"
			fields[:x0] = 0
			fields[:x1] = 1
			fields[:y0] = v0
			fields[:y1] = v1
		else
			fields[:yref] = cell.yref * " domain"
			fields[:x0] = v0
			fields[:x1] = v1
			fields[:y0] = 0
			fields[:y1] = 1
		end
		return fields
	end)
end

_ref_hspan!(fig, y0, y1; kwargs...) = _ref_spans!(fig, y0, y1, true; kwargs...)
_ref_vspan!(fig, x0, x1; kwargs...) = _ref_spans!(fig, x0, x1, false; kwargs...)

"""
	hspan!(fig, y0, y1; color="#cccccc", opacity=0.3, edgecolor="", linewidth=nothing,
	       layer="below", legend="", label="", labelpos="", fontsize=0, secondary_y=false)
	hspan!(sf::SubplotFigure, y0, y1; row=nothing, col=nothing, inset=nothing, kwargs...)

Shade the horizontal band between the data values `y0` and `y1` (either
order) across the full width of the plot area (matplotlib `axhspan`). The band
is a Plotly rect shape with `xref = "<x> domain"` (0 to 1) and `yref` the y
axis in data units; on a log y axis both values must be positive. Calls are
additive.

# Keywords
- `color::Union{AbstractString,Symbol} = "#cccccc"`: fill colour (`""` or
  `"none"` for no fill).
- `opacity::Real = 0.3`: opacity of the whole shape in `[0, 1]`.
- `edgecolor::Union{AbstractString,Symbol} = ""`: outline colour (`""`/`"none"`:
  the outline, when drawn, uses the fill colour).
- `linewidth::Union{Nothing,Real} = nothing`: outline width in px; `nothing`
  draws a 1 px outline when `edgecolor` is given and none otherwise.
- `layer = "below"`: `"below"` (under grid lines and traces), `"between"`
  (above the grid, under the traces) or `"above"`.
- `legend::AbstractString = ""`: when non-empty, adds a legend entry (a filled
  square in the band's colour and opacity).
- `label`, `labelpos`, `fontsize`: text inside the band (Plotly shape label,
  not MathJax-typeset). `labelpos` is one of `"top left"`, `"top center"`,
  `"top right"`, `"middle left"`, `"middle center"` (or `:center`),
  `"middle right"`, `"bottom left"`, `"bottom center"`, `"bottom right"`
  (Symbols may use underscores, e.g. `:top_left`); `""` is Plotly's default.
- `secondary_y::Bool = false`, and for a SubplotFigure `row`, `col`, `inset`:
  as for [`hline!`](@ref).

`show`, unknown keywords, non-finite bounds and non-positive bounds on a log
axis raise `ArgumentError`. Returns `nothing` for a `Plot`/`SyncPlot` and `sf`
for a `SubplotFigure`.

# Example
```julia
fig = plot_scatter(0:0.1:10, sin.(0:0.1:10))
hspan!(fig, -0.25, 0.25; color = "steelblue", legend = "tolerance")
```
"""
hspan!(fig, y0::Real, y1::Real; kwargs...) = _ref_hspan!(fig, y0, y1; kwargs...)
hspan!(sf::SubplotFigure, y0::Real, y1::Real; kwargs...) =
	_ref_subplot_call!(_ref_hspan!, sf, y0, y1; kwargs...)

"""
	vspan!(fig, x0, x1; color="#cccccc", opacity=0.3, edgecolor="", linewidth=nothing,
	       layer="below", legend="", label="", labelpos="", fontsize=0)
	vspan!(sf::SubplotFigure, x0, x1; row=nothing, col=nothing, inset=nothing, kwargs...)

Shade the vertical band between the data values `x0` and `x1` over the full
height of the plot area (matplotlib `axvspan`): a rect shape with
`yref = "<y> domain"` and `xref` the x axis in data units. The keywords are
those of [`hspan!`](@ref) without `secondary_y` (the band covers the whole
cell height for both y axes). Returns `nothing` for a `Plot`/`SyncPlot` and
`sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_scatter(1:100, cumsum(randn(100)))
vspan!(fig, 20, 35; color = :orange, label = "event", labelpos = :top_center)
```
"""
vspan!(fig, x0::Real, x1::Real; kwargs...) = _ref_vspan!(fig, x0, x1; kwargs...)
vspan!(sf::SubplotFigure, x0::Real, x1::Real; kwargs...) =
	_ref_subplot_call!(_ref_vspan!, sf, x0, x1; kwargs...)

# ---------------------------------------------------------------------------
# F16c: schematic primitives
# ---------------------------------------------------------------------------

# Keywords shared by circle!/ellipse!/rectangle!/polygon! are validated here
# (before the first write); returns (style, label, legend).
function _ref_schematic_options(
	who::AbstractString;
	fillcolor,
	edgecolor,
	linewidth,
	dash,
	opacity,
	layer,
	legend,
	label,
	labelpos,
	fontsize,
)
	style = _ref_area_style(
		who;
		fillcolor = fillcolor,
		edgecolor = edgecolor,
		linewidth = linewidth,
		dash = dash,
		opacity = opacity,
		layer = layer,
	)
	shape_label = _ref_shape_label(who, label, labelpos, fontsize; line = false)
	return style, shape_label, _ref_string(legend, who, "legend")
end

function _ref_circle!(
	fig,
	cx,
	cy,
	r;
	fillcolor = "",
	edgecolor = "black",
	linewidth = 1,
	dash = "",
	opacity = 1,
	layer = "above",
	legend = "",
	label = "",
	labelpos = "",
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = "circle!"
	_ref_reject_extra_kwargs(who, kwargs)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	_ref_require_linear(target, who, "a circle")
	x = _ref_finite(cx, who, "cx")
	y = _ref_finite(cy, who, "cy")
	radius = _ref_positive(r, who, "r")
	style, shape_label, legend_text = _ref_schematic_options(
		who;
		fillcolor, edgecolor, linewidth, dash, opacity, layer, legend, label, labelpos, fontsize,
	)
	return _ref_draw_area!(fig, who, target, style, shape_label, legend_text, cell -> Dict{Symbol, Any}(
		:type => "circle",
		:x0 => x - radius,
		:x1 => x + radius,
		:y0 => y - radius,
		:y1 => y + radius,
	))
end

"""
	circle!(fig, cx, cy, r; fillcolor="", edgecolor="black", linewidth=1, dash="",
	        opacity=1, layer="above", legend="", label="", labelpos="", fontsize=0,
	        secondary_y=false)
	circle!(sf::SubplotFigure, cx, cy, r; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw a circle of radius `r > 0` centred at `(cx, cy)`, all in data units
(matplotlib `patches.Circle`). It is a Plotly `"circle"` shape whose bounding
box is `cx ± r`, `cy ± r`, so it looks round only when both axes have the same
scale (use `axis_equal!` or `scaleanchor`); otherwise it is the corresponding
ellipse in data space. Not available on log axes (a radius has no fixed size
there): `ArgumentError`.

# Keywords
- `fillcolor = ""`: fill colour (`""`/`"none"`: unfilled).
- `edgecolor = "black"`: outline colour (`""`/`"none"`: no outline).
- `linewidth::Real = 1`: outline width in px (`0`: no outline).
- `dash = ""`: outline dash, as for [`hline!`](@ref).
- `opacity::Real = 1`, `layer = "above"`: as for [`hline!`](@ref).
- `legend::AbstractString = ""`: legend entry (a filled square for a filled
  shape, else a line sample of the outline).
- `label`, `labelpos`, `fontsize`: text inside the shape, as for
  [`hspan!`](@ref).
- `secondary_y::Bool = false`, and for a SubplotFigure `row`, `col`, `inset`:
  as for [`hline!`](@ref).

Calls are additive. Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a
`SubplotFigure`.

# Example
```julia
fig = plot_scatter(Float64[], Float64[]; xrange = [-2, 2], yrange = [-2, 2])
circle!(fig, 0, 0, 1; fillcolor = "lightblue", label = "Ω")
```
"""
circle!(fig, cx::Real, cy::Real, r::Real; kwargs...) = _ref_circle!(fig, cx, cy, r; kwargs...)
circle!(sf::SubplotFigure, cx::Real, cy::Real, r::Real; kwargs...) =
	_ref_subplot_call!(_ref_circle!, sf, cx, cy, r; kwargs...)

# Angle keyword in radians (`degrees = true` reads it in degrees).
_ref_angle(v, degrees::Bool, who::AbstractString, name::AbstractString) =
	(a = _ref_finite(v, who, name); degrees ? deg2rad(a) : a)

function _ref_ellipse!(
	fig,
	cx,
	cy,
	a,
	b;
	angle = 0,
	degrees = true,
	fillcolor = "",
	edgecolor = "black",
	linewidth = 1,
	dash = "",
	opacity = 1,
	layer = "above",
	legend = "",
	label = "",
	labelpos = "",
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = "ellipse!"
	_ref_reject_extra_kwargs(who, kwargs)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	_ref_require_linear(target, who, "an ellipse")
	x = _ref_finite(cx, who, "cx")
	y = _ref_finite(cy, who, "cy")
	semi_a = _ref_positive(a, who, "a")
	semi_b = _ref_positive(b, who, "b")
	phi = _ref_angle(angle, _ref_bool(degrees, who, "degrees"), who, "angle")
	style, shape_label, legend_text = _ref_schematic_options(
		who;
		fillcolor, edgecolor, linewidth, dash, opacity, layer, legend, label, labelpos, fontsize,
	)
	c, s = cos(phi), sin(phi)
	n = _REF_ELLIPSE_POINTS
	xs = Vector{Float64}(undef, n)
	ys = Vector{Float64}(undef, n)
	for k in 1:n
		t = 2π * (k - 1) / n
		u, v = semi_a * cos(t), semi_b * sin(t)
		xs[k] = x + u * c - v * s
		ys[k] = y + u * s + v * c
	end
	(all(isfinite, xs) && all(isfinite, ys)) || throw(ArgumentError(
		"$(who): the ellipse outline overflows Float64; reduce `a`/`b` or the centre.",
	))
	return _ref_draw_area!(fig, who, target, style, shape_label, legend_text, cell -> Dict{Symbol, Any}(
		:type => "path",
		:path => _ref_path(xs, ys; closed = true),
	))
end

"""
	ellipse!(fig, cx, cy, a, b; angle=0, degrees=true, fillcolor="", edgecolor="black",
	         linewidth=1, dash="", opacity=1, layer="above", legend="", label="",
	         labelpos="", fontsize=0, secondary_y=false)
	ellipse!(sf::SubplotFigure, cx, cy, a, b; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw an ellipse centred at `(cx, cy)` with semi-axes `a > 0` (along x before
rotation) and `b > 0`, rotated counter-clockwise by `angle` (degrees, or
radians with `degrees = false`), all in data units (matplotlib
`patches.Ellipse` takes full widths; these are semi-axes). The outline is a
closed Plotly path through 128 points. Not available on log axes
(`ArgumentError`).

The other keywords, the return value and additivity are as for
[`circle!`](@ref).

# Example
```julia
fig = plot_scatter(Float64[], Float64[]; xrange = [-3, 3], yrange = [-3, 3])
ellipse!(fig, 0, 0, 2, 1; angle = 30, fillcolor = "rgba(255,0,0,0.2)")
```
"""
ellipse!(fig, cx::Real, cy::Real, a::Real, b::Real; kwargs...) =
	_ref_ellipse!(fig, cx, cy, a, b; kwargs...)
ellipse!(sf::SubplotFigure, cx::Real, cy::Real, a::Real, b::Real; kwargs...) =
	_ref_subplot_call!(_ref_ellipse!, sf, cx, cy, a, b; kwargs...)

# Closed path of the rectangle [xl, xr] x [yb, yt] with corners rounded by a
# quadratic Bézier whose control point is the corner (matplotlib
# FancyBboxPatch "round" uses the same CURVE3 construction).
function _ref_rounded_rect_path(xl::Float64, xr::Float64, yb::Float64, yt::Float64, rho::Float64)
	n = _ref_path_number
	return "M$(n(xl + rho)),$(n(yb))" *
		" L$(n(xr - rho)),$(n(yb)) Q$(n(xr)),$(n(yb)) $(n(xr)),$(n(yb + rho))" *
		" L$(n(xr)),$(n(yt - rho)) Q$(n(xr)),$(n(yt)) $(n(xr - rho)),$(n(yt))" *
		" L$(n(xl + rho)),$(n(yt)) Q$(n(xl)),$(n(yt)) $(n(xl)),$(n(yt - rho))" *
		" L$(n(xl)),$(n(yb + rho)) Q$(n(xl)),$(n(yb)) $(n(xl + rho)),$(n(yb)) Z"
end

function _ref_rectangle!(
	fig,
	x0,
	y0,
	x1,
	y1;
	rounded = 0,
	fillcolor = "",
	edgecolor = "black",
	linewidth = 1,
	dash = "",
	opacity = 1,
	layer = "above",
	legend = "",
	label = "",
	labelpos = "",
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = "rectangle!"
	_ref_reject_extra_kwargs(who, kwargs)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	rho = _ref_nonnegative(rounded, who, "rounded")
	rho > 0 && _ref_require_linear(target, who, "a rounded rectangle")
	xa = _ref_coord(x0, target.xlog, who, "x0")
	ya = _ref_coord(y0, target.ylog, who, "y0")
	xb = _ref_coord(x1, target.xlog, who, "x1")
	yb = _ref_coord(y1, target.ylog, who, "y1")
	xl, xr = minmax(xa, xb)
	ylo, yhi = minmax(ya, yb)
	if rho > 0
		limit = min(xr - xl, yhi - ylo) / 2
		rho <= limit || throw(ArgumentError(
			"$(who): `rounded` = $(rho) exceeds half the shorter side ($(limit)) " *
			"of the rectangle.",
		))
	end
	style, shape_label, legend_text = _ref_schematic_options(
		who;
		fillcolor, edgecolor, linewidth, dash, opacity, layer, legend, label, labelpos, fontsize,
	)
	return _ref_draw_area!(fig, who, target, style, shape_label, legend_text, cell -> rho > 0 ?
		Dict{Symbol, Any}(:type => "path", :path => _ref_rounded_rect_path(xl, xr, ylo, yhi, rho)) :
		Dict{Symbol, Any}(:type => "rect", :x0 => xa, :x1 => xb, :y0 => ya, :y1 => yb))
end

"""
	rectangle!(fig, x0, y0, x1, y1; rounded=0, fillcolor="", edgecolor="black", linewidth=1,
	           dash="", opacity=1, layer="above", legend="", label="", labelpos="",
	           fontsize=0, secondary_y=false)
	rectangle!(sf::SubplotFigure, x0, y0, x1, y1; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw the axis-aligned rectangle with opposite corners `(x0, y0)` and
`(x1, y1)` in data units (matplotlib `patches.Rectangle`/`FancyBboxPatch`),
for example the blocks of a block diagram (put the text in with `label`).

`rounded::Real = 0` rounds the corners with radius `rounded` in data units on
both axes (`0 <= rounded <= min(width, height) / 2`); the outline is then a
Plotly path whose corners are quadratic Bézier curves (`Q`), like matplotlib's
`"round"` box style. Without rounding the shape is a Plotly `"rect"` and works
on log axes (corners positive there); a rounded rectangle on a log axis is an
`ArgumentError`.

The other keywords, the return value and additivity are as for
[`circle!`](@ref).

# Example
```julia
fig = plot_scatter(Float64[], Float64[]; xrange = [0, 10], yrange = [0, 4])
rectangle!(fig, 1, 1, 4, 3; rounded = 0.3, fillcolor = "#eeeeee", label = "Laser")
rectangle!(fig, 6, 1, 9, 3; label = "Detector")
arrow!(fig, 4, 2, 6, 2)
```
"""
rectangle!(fig, x0::Real, y0::Real, x1::Real, y1::Real; kwargs...) =
	_ref_rectangle!(fig, x0, y0, x1, y1; kwargs...)
rectangle!(sf::SubplotFigure, x0::Real, y0::Real, x1::Real, y1::Real; kwargs...) =
	_ref_subplot_call!(_ref_rectangle!, sf, x0, y0, x1, y1; kwargs...)

function _ref_polygon!(
	fig,
	x,
	y;
	closed = true,
	fillcolor = "",
	edgecolor = "black",
	linewidth = 1,
	dash = "",
	opacity = 1,
	layer = "above",
	legend = "",
	label = "",
	labelpos = "",
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = "polygon!"
	_ref_reject_extra_kwargs(who, kwargs)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	is_closed = _ref_bool(closed, who, "closed")
	length(x) == length(y) || throw(ArgumentError(
		"$(who): `x` and `y` must have the same length; got $(length(x)) and $(length(y)).",
	))
	minimum_points = is_closed ? 3 : 2
	length(x) >= minimum_points || throw(ArgumentError(
		"$(who): a$(is_closed ? " closed polygon" : "n open polyline") needs at " *
		"least $(minimum_points) vertices; got $(length(x)).",
	))
	xs = _ref_values(x, target.xlog, who, "x")
	ys = _ref_values(y, target.ylog, who, "y")
	style, shape_label, legend_text = _ref_schematic_options(
		who;
		fillcolor, edgecolor, linewidth, dash, opacity, layer, legend, label, labelpos, fontsize,
	)
	return _ref_draw_area!(fig, who, target, style, shape_label, legend_text, cell -> Dict{Symbol, Any}(
		:type => "path",
		:path => _ref_path(xs, ys; closed = is_closed),
	))
end

"""
	polygon!(fig, x, y; closed=true, fillcolor="", edgecolor="black", linewidth=1, dash="",
	         opacity=1, layer="above", legend="", label="", labelpos="", fontsize=0,
	         secondary_y=false)
	polygon!(sf::SubplotFigure, x, y; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw the polygon with vertices `(x[k], y[k])` in data units (matplotlib
`patches.Polygon`) as a Plotly path `M x1,y1 L x2,y2 ... Z`. `x` and `y` are
vectors of finite reals of equal length (at least 3 vertices when `closed`,
2 for an open polyline with `closed = false`). A `fillcolor` fills the shape
even when it is open, as SVG and matplotlib do.

On a log axis the vertices are data values (positive) placed exactly; the
edges are straight on screen, as matplotlib draws a polygon on log axes.

The other keywords, the return value and additivity are as for
[`circle!`](@ref).

# Example
```julia
fig = plot_scatter(Float64[], Float64[]; xrange = [0, 4], yrange = [0, 3])
polygon!(fig, [0.5, 3.5, 2.0], [0.5, 0.5, 2.5]; fillcolor = :gold, legend = "region")
```
"""
polygon!(fig, x::AbstractVector, y::AbstractVector; kwargs...) = _ref_polygon!(fig, x, y; kwargs...)
polygon!(sf::SubplotFigure, x::AbstractVector, y::AbstractVector; kwargs...) =
	_ref_subplot_call!(_ref_polygon!, sf, x, y; kwargs...)

# ---------------------------------------------------------------------------
# F16c: arrows and arcs
# ---------------------------------------------------------------------------

const _REF_ARROW_HEADS = (:end, :start, :both, :none)
const _REF_TEXT_POSITIONS = (:start, :mid, :end)

# A Symbol-valued option given as a Symbol or string.
function _ref_symbol_option(v, who::AbstractString, name::AbstractString, allowed)::Symbol
	s = Symbol(_ref_name_option(v, who, name))
	s === :middle && :mid in allowed && (s = :mid)
	s in allowed || throw(ArgumentError(
		"$(who): `$(name)` must be one of $(join(repr.(allowed), ", ")); got $(repr(v)).",
	))
	return s
end

function _ref_arrow_width(v, who::AbstractString)::Float64
	w = _ref_finite(v, who, "linewidth")
	w >= _REF_MIN_ARROW_WIDTH || throw(ArgumentError(
		"$(who): an arrow `linewidth` must be >= $(_REF_MIN_ARROW_WIDTH) px " *
		"(plotly.js minimum); got $(repr(v)).",
	))
	return w
end

function _ref_head_size(v, who::AbstractString)::Float64
	s = _ref_finite(v, who, "headsize")
	s >= _REF_MIN_ARROW_SIZE || throw(ArgumentError(
		"$(who): `headsize` must be >= $(_REF_MIN_ARROW_SIZE) (plotly.js minimum " *
		"arrow size, relative to the line width); got $(repr(v)).",
	))
	return s
end

# Annotation drawing an arrow from `tail` to `tip` (both in axis units, i.e.
# log10 on log axes) with heads per `head` (:end at the tip, :start at the
# tail, :both). The text is empty, so plotly.js starts the shaft exactly at
# the tail; standoffs are 0 so the head tips touch the end points.
function _ref_arrow_annotation(
	cell::_CellTarget,
	tip::NTuple{2, Float64},
	tail::NTuple{2, Float64},
	head::Symbol,
	color::String,
	width::Float64,
	size::Float64,
	opacity::Float64,
	name::String,
)
	fields = Dict{Symbol, Any}(
		:x => tip[1],
		:y => tip[2],
		:ax => tail[1],
		:ay => tail[2],
		:xref => cell.xref,
		:yref => cell.yref,
		:axref => cell.xref,
		:ayref => cell.yref,
		:text => "",
		:showarrow => true,
		:arrowhead => _REF_ARROWHEAD,
		:arrowsize => size,
		:arrowwidth => width,
		:arrowside => head === :end ? "end" : head === :start ? "start" : "end+start",
		:standoff => 0,
		:startstandoff => 0,
		:name => name,
	)
	isempty(color) || (fields[:arrowcolor] = color)
	if head !== :end
		fields[:startarrowhead] = _REF_ARROWHEAD
		fields[:startarrowsize] = size
	end
	opacity == 1 || (fields[:opacity] = opacity)
	return attr(fields)
end

# Text annotation (no arrow) at `pos` (axis units), shifted by `shift` px.
function _ref_text_annotation(
	cell::_CellTarget,
	pos::NTuple{2, Float64},
	text::String,
	color::String,
	size::Float64,
	shift::NTuple{2, Float64},
	name::String;
	xanchor::String = "",
	yanchor::String = "",
)
	fields = Dict{Symbol, Any}(
		:x => pos[1],
		:y => pos[2],
		:xref => cell.xref,
		:yref => cell.yref,
		:text => text,
		:showarrow => false,
		:name => name,
	)
	font = _ref_font(color, size)
	font === nothing || (fields[:font] = font)
	isempty(xanchor) || (fields[:xanchor] = xanchor)
	isempty(yanchor) || (fields[:yanchor] = yanchor)
	shift[1] == 0 || (fields[:xshift] = shift[1])
	shift[2] == 0 || (fields[:yshift] = shift[2])
	return attr(fields)
end

function _ref_arrow!(
	fig,
	x0,
	y0,
	x1,
	y1;
	head = :end,
	color = "black",
	linewidth = 1,
	headsize = 1,
	text = "",
	textpos = :mid,
	offset = (0, 0),
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = "arrow!"
	_ref_reject_extra_kwargs(who, kwargs)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	xa = _ref_coord(x0, target.xlog, who, "x0")
	ya = _ref_coord(y0, target.ylog, who, "y0")
	xb = _ref_coord(x1, target.xlog, who, "x1")
	yb = _ref_coord(y1, target.ylog, who, "y1")
	(xa, ya) == (xb, yb) && throw(ArgumentError(
		"$(who): the start ($(xa), $(ya)) and end point coincide; an arrow needs a direction.",
	))
	heads = _ref_symbol_option(head, who, "head", _REF_ARROW_HEADS)
	line_color = _ref_color(color, who, "color")
	width = heads === :none ? _ref_nonnegative(linewidth, who, "linewidth") : _ref_arrow_width(linewidth, who)
	size = _ref_head_size(headsize, who)
	label_text = _ref_string(text, who, "text")
	position = _ref_symbol_option(textpos, who, "textpos", _REF_TEXT_POSITIONS)
	shift = _ref_pair(offset, who, "offset")
	font_size = _ref_fontsize(fontsize, who)
	label = isempty(label_text) ? "" : _label(label_text)
	heads === :none && _ref_check_layout_array(fig, :shapes, who)
	(heads !== :none || !isempty(label)) && _ref_check_layout_array(fig, :annotations, who)

	cell = _ref_commit_target!(fig, target, who)
	name = _ref_item_name(who, cell)
	tail = (_ref_axis_unit(xa, target.xlog), _ref_axis_unit(ya, target.ylog))
	tip = (_ref_axis_unit(xb, target.xlog), _ref_axis_unit(yb, target.ylog))
	annotations = Any[]
	if heads === :none
		# A head-less arrow is a line shape (data units on every axis type).
		_ref_append_items!(fig, :shapes, Any[attr(Dict{Symbol, Any}(
			:type => "line",
			:xref => cell.xref,
			:yref => cell.yref,
			:x0 => xa,
			:y0 => ya,
			:x1 => xb,
			:y1 => yb,
			:line => _ref_line_attr(line_color, width, ""),
			:layer => "above",
			:name => name,
		))])
	else
		push!(annotations, _ref_arrow_annotation(cell, tip, tail, heads, line_color, width, size, 1.0, name))
	end
	if !isempty(label)
		# The midpoint is taken in axis units, i.e. the visual midpoint (the
		# geometric mean of the end values on a log axis).
		pos = position === :start ? tail : position === :end ? tip :
			((tail[1] + tip[1]) / 2, (tail[2] + tip[2]) / 2)
		push!(annotations, _ref_text_annotation(cell, pos, label, line_color, font_size, shift, name))
	end
	_ref_append_items!(fig, :annotations, annotations)
	return _ref_done!(fig, cell)
end

"""
	arrow!(fig, x0, y0, x1, y1; head=:end, color="black", linewidth=1, headsize=1, text="",
	       textpos=:mid, offset=(0, 0), fontsize=0, secondary_y=false)
	arrow!(sf::SubplotFigure, x0, y0, x1, y1; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw a straight arrow from `(x0, y0)` to `(x1, y1)` (data values on every axis
type; positive on log axes). This covers matplotlib `FancyArrowPatch`,
`ax.arrow` and `annotate("", xy, xytext, arrowprops=dict(arrowstyle="<->"))`.

The arrow is a Plotly annotation with `x, y` = the end point, `ax, ay` = the
start point, `axref`/`ayref` = the data axes, `arrowhead = 2` and empty text,
so the shaft runs exactly between the two points. Annotation coordinates are
in axis units: on a log axis they are written as `log10` of the values (this
is done for you).

# Keywords
- `head::Union{Symbol,AbstractString} = :end`: arrowheads at `:end`
  (`(x1, y1)`), `:start`, `:both` (`"<->"`, e.g. dimension arrows) or `:none`
  (a plain line, drawn as a Plotly line shape).
- `color = "black"`: arrow and text colour (`""` uses Plotly's default).
- `linewidth::Real = 1`: shaft width in px (`>= 0.1` when a head is drawn,
  plotly.js's minimum).
- `headsize::Real = 1`: head size relative to the line width (`>= 0.3`,
  plotly.js's minimum).
- `text::AbstractString = ""`: optional label, typeset like every annotation
  (`\$...\$` math works in exported figures).
- `textpos::Union{Symbol,AbstractString} = :mid`: label centred on `:start`,
  `:mid` (the visual midpoint) or `:end`.
- `offset::Tuple{Real,Real} = (0, 0)`: label shift in px (x right, y up);
  use it to lift a label off the shaft.
- `fontsize::Real = 0`: label font size in px (0 = layout default).
- `secondary_y::Bool = false`, and for a SubplotFigure `row`, `col`, `inset`:
  as for [`hline!`](@ref).

Calls are additive. `show`, unknown keywords, non-finite or coincident end
points and non-positive values on a log axis raise `ArgumentError`. Returns
`nothing` for a `Plot`/`SyncPlot` and `sf` for a `SubplotFigure`.

# Example
```julia
fig = plot_scatter([0, 10], [0, 5]; mode = "markers")
arrow!(fig, 1, 1, 9, 1; head = :both, text = "L = 8", offset = (0, 10))
arrow!(fig, 5, 4, 8, 2; color = "red", linewidth = 2)
```
"""
arrow!(fig, x0::Real, y0::Real, x1::Real, y1::Real; kwargs...) =
	_ref_arrow!(fig, x0, y0, x1, y1; kwargs...)
arrow!(sf::SubplotFigure, x0::Real, y0::Real, x1::Real, y1::Real; kwargs...) =
	_ref_subplot_call!(_ref_arrow!, sf, x0, y0, x1, y1; kwargs...)

function _ref_arc!(
	fig,
	cx,
	cy,
	r,
	theta0,
	theta1;
	degrees = true,
	arrow = :none,
	color = "black",
	linewidth = 1,
	dash = "",
	headsize = 1,
	opacity = 1,
	layer = "above",
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = "arc!"
	_ref_reject_extra_kwargs(who, kwargs)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	_ref_require_linear(target, who, "an arc")
	x = _ref_finite(cx, who, "cx")
	y = _ref_finite(cy, who, "cy")
	radius = _ref_positive(r, who, "r")
	in_degrees = _ref_bool(degrees, who, "degrees")
	t0 = _ref_angle(theta0, in_degrees, who, "theta0")
	t1 = _ref_angle(theta1, in_degrees, who, "theta1")
	span = t1 - t0
	span == 0 && throw(ArgumentError("$(who): `theta0` and `theta1` coincide; the arc is empty."))
	# One full turn at most (a 360-degree span is a full circle); the relative
	# slack absorbs the rounding of deg2rad.
	abs(span) <= 2π * (1 + 1e-12) || throw(ArgumentError(
		"$(who): the arc spans more than one full turn " *
		"($(in_degrees ? rad2deg(abs(span)) : abs(span)) $(in_degrees ? "degrees" : "rad")).",
	))
	heads = _ref_symbol_option(arrow, who, "arrow", _REF_ARROW_HEADS)
	style = _ref_line_style(who; color = color, dash = dash, linewidth = linewidth, opacity = opacity, layer = layer)
	heads === :none || _ref_arrow_width(linewidth, who)
	size = _ref_head_size(headsize, who)
	n = max(_REF_ARC_MIN_POINTS, ceil(Int, _REF_ARC_POINTS_PER_TURN * abs(span) / 2π))
	xs = Vector{Float64}(undef, n)
	ys = Vector{Float64}(undef, n)
	for k in 1:n
		t = t0 + span * (k - 1) / (n - 1)
		xs[k] = x + radius * cos(t)
		ys[k] = y + radius * sin(t)
	end
	(all(isfinite, xs) && all(isfinite, ys)) || throw(ArgumentError(
		"$(who): the arc overflows Float64; reduce `r` or the centre.",
	))
	_ref_check_layout_array(fig, :shapes, who)
	heads === :none || _ref_check_layout_array(fig, :annotations, who)

	cell = _ref_commit_target!(fig, target, who)
	name = _ref_item_name(who, cell)
	shape = Dict{Symbol, Any}(
		:type => "path",
		:xref => cell.xref,
		:yref => cell.yref,
		:path => _ref_path(xs, ys; closed = false),
		:line => _ref_line_attr(style.color, style.width, style.dash),
		:layer => style.layer,
		:name => name,
	)
	style.opacity == 1 || (shape[:opacity] = style.opacity)
	_ref_append_items!(fig, :shapes, Any[attr(shape)])
	if heads !== :none
		# Each head is an annotation whose tip is the arc end and whose tail
		# lies on the tangent there (direction of travel `sgn * (-sin t, cos t)`).
		sgn = sign(span)
		back = min(_REF_ARC_HEAD_TAIL * radius, abs(span) * radius / 2)
		heads_out = Any[]
		if heads in (:end, :both)
			tip = (xs[end], ys[end])
			tail = (tip[1] + back * sgn * sin(t1), tip[2] - back * sgn * cos(t1))
			push!(heads_out, _ref_arrow_annotation(cell, tip, tail, :end, style.color, style.width, size, style.opacity, name))
		end
		if heads in (:start, :both)
			tip = (xs[1], ys[1])
			tail = (tip[1] - back * sgn * sin(t0), tip[2] + back * sgn * cos(t0))
			push!(heads_out, _ref_arrow_annotation(cell, tip, tail, :end, style.color, style.width, size, style.opacity, name))
		end
		_ref_append_items!(fig, :annotations, heads_out)
	end
	return _ref_done!(fig, cell)
end

"""
	arc!(fig, cx, cy, r, theta0, theta1; degrees=true, arrow=:none, color="black",
	     linewidth=1, dash="", headsize=1, opacity=1, layer="above", secondary_y=false)
	arc!(sf::SubplotFigure, cx, cy, r, theta0, theta1; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw the circular arc of radius `r > 0` about `(cx, cy)` (data units) from
angle `theta0` to `theta1`, measured counter-clockwise from the +x axis
(matplotlib `patches.Arc`). The arc runs from `theta0` to `theta1` in the
direction of the sign of `theta1 - theta0` (so `(90, 0)` runs clockwise) and
spans at most one full turn. It is an open Plotly path through
`max(32, 128 |Δθ| / 2π)` points; it looks circular only on equal-aspect axes.
Not available on log axes (`ArgumentError`).

# Keywords
- `degrees::Bool = true`: angles in degrees (`false`: radians).
- `arrow::Union{Symbol,AbstractString} = :none`: arrowheads at the `:end`
  (`theta1`), `:start`, `:both` or `:none`, pointing along the arc (each head is
  an annotation on the tangent at that end).
- `color = "black"`, `linewidth::Real = 1` (`>= 0.1` with heads), `dash = ""`,
  `opacity::Real = 1`, `layer = "above"`: line style, as for [`hline!`](@ref).
- `headsize::Real = 1`: head size relative to the line width (`>= 0.3`).
- `secondary_y::Bool = false`, and for a SubplotFigure `row`, `col`, `inset`:
  as for [`hline!`](@ref).

Calls are additive. Returns `nothing` for a `Plot`/`SyncPlot` and `sf` for a
`SubplotFigure`.

# Example
```julia
fig = plot_scatter([0, 2], [0, 1]; mode = "lines")
arc!(fig, 0, 0, 0.5, 0, rad2deg(atan(0.5)); arrow = :end)
annotate!(fig, 0.6, 0.12, "θ"; showarrow = false)
```
"""
arc!(fig, cx::Real, cy::Real, r::Real, theta0::Real, theta1::Real; kwargs...) =
	_ref_arc!(fig, cx, cy, r, theta0, theta1; kwargs...)
arc!(sf::SubplotFigure, cx::Real, cy::Real, r::Real, theta0::Real, theta1::Real; kwargs...) =
	_ref_subplot_call!(_ref_arc!, sf, cx, cy, r, theta0, theta1; kwargs...)

# ---------------------------------------------------------------------------
# F16d: slope guides
# ---------------------------------------------------------------------------

# Display direction of an axis: -1 when it is reversed (`autorange` containing
# "reversed", or an explicit decreasing range), else +1.
function _ref_axis_direction(layout::Layout, key::Symbol)::Int
	entry = get(layout.fields, key, nothing)
	autorange = _cmn_mapping_get(entry, :autorange)
	autorange isa AbstractString && return occursin("reversed", autorange) ? -1 : 1
	autorange === true && return 1
	range = _cmn_mapping_get(entry, :range)
	if (range isa AbstractVector || range isa Tuple) && length(range) == 2
		lower, upper = first(range), last(range)
		_ref_is_real(lower) && _ref_is_real(upper) && upper < lower && return -1
	end
	return 1
end

# y = Y (x / X)^p, real-valued: a negative ratio is only allowed for an
# integer order (validated by the caller), with the sign of (-1)^p.
function _ref_power_law(x::Float64, X::Float64, Y::Float64, p::Float64)::Float64
	ratio = x / X
	ratio >= 0 && return Y * ratio^p
	magnitude = abs(ratio)^p
	return Y * (isinteger(p / 2) ? magnitude : -magnitude)
end

# Label text of a slope: "2" for an integral order, "1.5" otherwise.
_ref_order_string(p::Float64) = isinteger(p) && abs(p) < 1e15 ? string(Int(p)) : string(p)

function _ref_slope_guide!(
	fig,
	order;
	x = nothing,
	through = nothing,
	label = "",
	labelpos = :mid,
	offset = (0, 0),
	color = "#777777",
	dash = "dash",
	linewidth = 1,
	legend = "",
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = "slope_guide!"
	_ref_reject_extra_kwargs(who, kwargs)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	p = _ref_finite(order, who, "order")
	x === nothing && throw(ArgumentError(
		"$(who): the `x` keyword (the interval to draw over, e.g. `x = (1e-3, 1e-1)`) is required.",
	))
	through === nothing && throw(ArgumentError(
		"$(who): the `through` keyword (a point (x, y) on the guide) is required.",
	))
	xa, xb = _ref_pair(x, who, "x")
	xa == xb && throw(ArgumentError("$(who): `x` must span a non-empty interval; got $(repr(x))."))
	X, Y = _ref_pair(through, who, "through")
	X == 0 && throw(ArgumentError(
		"$(who): `through[1]` must be non-zero (the guide is y = through[2] * " *
		"(x / through[1])^order).",
	))
	if target.xlog
		_ref_coord(xa, true, who, "x[1]")
		_ref_coord(xb, true, who, "x[2]")
		_ref_coord(X, true, who, "through[1]")
	end
	target.ylog && _ref_coord(Y, true, who, "through[2]")
	if !isinteger(p) && (xa / X < 0 || xb / X < 0)
		throw(ArgumentError(
			"$(who): a non-integer `order` needs x / through[1] >= 0 over the whole " *
			"`x` interval (the power is not real otherwise).",
		))
	end
	p < 0 && xa * xb <= 0 && throw(ArgumentError(
		"$(who): a negative `order` has a pole at x = 0, which lies in the `x` interval.",
	))
	loglog = target.xlog && target.ylog
	straight = loglog || (!target.xlog && !target.ylog && (p == 0 || p == 1))
	n = straight ? 2 : _REF_SLOPE_SAMPLES
	ua, ub = _ref_axis_unit(xa, target.xlog), _ref_axis_unit(xb, target.xlog)
	xs = Float64[_ref_from_axis_unit(ua + (ub - ua) * (k - 1) / (n - 1), target.xlog) for k in 1:n]
	xs[1], xs[end] = xa, xb
	ys = Float64[_ref_power_law(v, X, Y, p) for v in xs]
	all(isfinite, ys) || throw(ArgumentError(
		"$(who): the guide is not finite over the `x` interval (overflow).",
	))
	target.ylog && any(<=(0), ys) && throw(ArgumentError(
		"$(who): the guide takes non-positive values over the `x` interval, which " *
		"cannot be drawn on a logarithmic y axis.",
	))
	style = _ref_line_style(who; color = color, dash = dash, linewidth = linewidth, opacity = 1, layer = "above")
	label_text = _ref_string(label, who, "label")
	position = _ref_symbol_option(labelpos, who, "labelpos", _REF_TEXT_POSITIONS)
	shift = _ref_pair(offset, who, "offset")
	font_size = _ref_fontsize(fontsize, who)
	legend_text = _ref_string(legend, who, "legend")
	legend_name = isempty(legend_text) ? "" : _label(legend_text)
	label_html = isempty(label_text) ? "" : _label(label_text)
	isempty(label_html) || _ref_check_layout_array(fig, :annotations, who)

	cell = _ref_commit_target!(fig, target, who)
	fields = Dict{Symbol, Any}(
		:type => "scatter",
		:x => xs,
		:y => ys,
		:mode => "lines",
		:line => _ref_line_attr(style.color, style.width, style.dash),
		:showlegend => !isempty(legend_name),
		:hoverinfo => "skip",
	)
	isempty(legend_name) || (fields[:name] = legend_name)
	_ref_push_trace!(fig, cell, GenericTrace("scatter", fields))
	_ref_refresh_legends!(fig)
	if !isempty(label_html)
		layout = _cmn_layout(fig)
		xdir = _ref_axis_direction(layout, cell.xkey)
		ydir = _ref_axis_direction(layout, cell.ykey)
		uL = position === :start ? ua : position === :end ? ub : (ua + ub) / 2
		xL = position === :start ? xa : position === :end ? xb : _ref_from_axis_unit(uL, target.xlog)
		vL = _ref_axis_unit(_ref_power_law(xL, X, Y, p), target.ylog)
		gap = Float64(_REF_LABEL_GAP)
		if position === :mid
			# Put the label in the screen quadrant above the guide: up-right of
			# a falling guide, up-left of a rising one; for a straight guide
			# that quadrant never contains the line.
			h = 1e-6 * abs(ub - ua)
			uA, uB = max(min(ua, ub), uL - h), min(max(ua, ub), uL + h)
			vA = _ref_axis_unit(_ref_power_law(_ref_from_axis_unit(uA, target.xlog), X, Y, p), target.ylog)
			vB = _ref_axis_unit(_ref_power_law(_ref_from_axis_unit(uB, target.xlog), X, Y, p), target.ylog)
			slope_sign = sign((vB - vA) * (uB - uA)) * xdir * ydir
			xanchor, dx = slope_sign < 0 ? ("left", gap) : slope_sign > 0 ? ("right", -gap) : ("center", 0.0)
			yanchor, dy = "bottom", gap
		else
			# Beyond the chosen end, on the side away from the rest of the guide.
			u_end, u_other = position === :end ? (ub, ua) : (ua, ub)
			outward = sign(u_end - u_other) * xdir
			xanchor, dx = outward > 0 ? ("left", gap) : ("right", -gap)
			yanchor, dy = "middle", 0.0
		end
		_ref_append_items!(fig, :annotations, Any[_ref_text_annotation(
			cell,
			(uL, vL),
			label_html,
			style.color,
			font_size,
			(dx + shift[1], dy + shift[2]),
			_ref_item_name(who, cell);
			xanchor = xanchor,
			yanchor = yanchor,
		)])
	end
	return _ref_done!(fig, cell)
end

"""
	slope_guide!(fig, order; x, through, label="", labelpos=:mid, offset=(0, 0),
	             color="#777777", dash="dash", linewidth=1, legend="", fontsize=0,
	             secondary_y=false)
	slope_guide!(sf::SubplotFigure, order; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw the reference power law `y = through[2] * (x / through[1])^order` over
the interval `x` (e.g. an O(h²) or N⁻⁴ convergence guide). On log-log axes it
is a straight line of slope `order` drawn from its two end points; otherwise
it is sampled at 64 points (log-spaced on a log x axis, linear otherwise).
The guide is a scatter trace (`hoverinfo = "skip"`), so it takes part in
autoranging.

# Keywords
- `x`: required interval `(x1, x2)` (2-tuple or 2-element vector of finite
  reals, `x1 != x2`; positive on a log x axis).
- `through`: required point `(X, Y)` on the guide, `X != 0` (both positive on
  log axes).
- `label::AbstractString = ""`: text placed next to the guide (MathJax
  `\$...\$` works, e.g. `"\\\$O(h^2)\\\$"`).
- `labelpos::Union{Symbol,AbstractString} = :mid`: `:mid` puts the label at
  the visual middle of the interval (the geometric mean of `x` on a log x
  axis) above the guide, on the side where it cannot touch the line;
  `:end`/`:start` put it just beyond that end of the guide.
- `offset::Tuple{Real,Real} = (0, 0)`: extra label shift in px (x right, y
  up), added to a 4 px gap from the line.
- `color = "#777777"`, `dash = "dash"`, `linewidth::Real = 1`: line style, as
  for [`hline!`](@ref); the label uses `color` too.
- `legend::AbstractString = ""`: legend entry of the guide (hidden when empty).
- `fontsize::Real = 0`: label font size in px (0 = layout default).
- `secondary_y::Bool = false`, and for a SubplotFigure `row`, `col`, `inset`:
  as for [`hline!`](@ref).

A non-integer `order` needs `x / through[1] >= 0` over the interval, a
negative order an interval that excludes 0, and on a log y axis the guide
must stay positive; violations, `show` and unknown keywords raise
`ArgumentError`. Calls are additive. Returns `nothing` for a `Plot`/`SyncPlot`
and `sf` for a `SubplotFigure`.

# Example
```julia
h = [0.1, 0.05, 0.025, 0.0125]
err = 3 .* h .^ 2 .* (1 .+ 0.1 .* h)
fig = plot_scatter(h, err; mode = "markers", xscale = "log", yscale = "log")
slope_guide!(fig, 2; x = (0.0125, 0.1), through = (0.1, 0.02), label = "\\\$O(h^2)\\\$")
```
"""
slope_guide!(fig, order::Real; kwargs...) = _ref_slope_guide!(fig, order; kwargs...)
slope_guide!(sf::SubplotFigure, order::Real; kwargs...) =
	_ref_subplot_call!(_ref_slope_guide!, sf, order; kwargs...)

function _ref_triangle_labels(labels, p::Float64, who::AbstractString)::NTuple{2, String}
	labels === nothing && return ("1", _ref_order_string(p))
	((labels isa Tuple || labels isa AbstractVector) && length(labels) == 2 &&
		all(l -> l isa AbstractString, labels)) || throw(ArgumentError(
		"$(who): `labels` must be a 2-tuple of strings (run, rise); \"\" omits " *
		"one. Got $(repr(labels)).",
	))
	return (String(first(labels)), String(last(labels)))
end

function _ref_slope_triangle!(
	fig,
	x0,
	y0,
	order;
	width = 0.3,
	below = true,
	labels = nothing,
	color = "gray",
	linewidth = 1,
	fillcolor = "",
	fontsize = 0,
	row = nothing,
	col = nothing,
	secondary_y = false,
	inset = nothing,
	kwargs...,
)
	who = "slope_triangle!"
	_ref_reject_extra_kwargs(who, kwargs)
	target = _ref_target(fig, who; row = row, col = col, secondary_y = secondary_y, inset = inset)
	xa = _ref_coord(x0, target.xlog, who, "x0")
	ya = _ref_coord(y0, target.ylog, who, "y0")
	p = _ref_finite(order, who, "order")
	p == 0 && throw(ArgumentError("$(who): a slope triangle needs a non-zero `order`."))
	w = _ref_finite(width, who, "width")
	w == 0 && throw(ArgumentError("$(who): `width` must be non-zero."))
	is_below = _ref_bool(below, who, "below")
	run_text, rise_text = _ref_triangle_labels(labels, p, who)
	edge = _ref_color(color, who, "color")
	line_width = _ref_nonnegative(linewidth, who, "linewidth")
	fill = _ref_color(fillcolor, who, "fillcolor"; none_is_empty = true)
	font_size = _ref_fontsize(fontsize, who)
	# Horizontal leg in axis units: decades on a log x axis, else a fraction
	# of the x range (explicit range, else the data extent of the x axis).
	du = if target.xlog
		w
	else
		limits = _from_axis_range(_cmn_layout(fig), target.cell.xkey)
		limits === nothing && (limits = _axis_data_extent(fig, target.cell.xkey))
		limits === nothing && throw(ArgumentError(
			"$(who): on a linear x axis `width` is a fraction of the x range; set " *
			"`xrange` or plot data on this axis first.",
		))
		extent = abs(limits[2] - limits[1])
		extent > 0 || throw(ArgumentError(
			"$(who): the x range has zero width; set `xrange` first.",
		))
		w * extent
	end
	u0 = _ref_axis_unit(xa, target.xlog)
	v0 = _ref_axis_unit(ya, target.ylog)
	u1 = u0 + du
	v1 = v0 + p * du
	x1 = _ref_from_axis_unit(u1, target.xlog)
	y1 = _ref_from_axis_unit(v1, target.ylog)
	(isfinite(u1) && isfinite(v1) && isfinite(x1) && isfinite(y1) && (!target.xlog || x1 > 0) && (!target.ylog || y1 > 0)) ||
		throw(ArgumentError(
			"$(who): the triangle does not fit in Float64 (width $(w), order $(p)); " *
			"reduce `width` or `order`.",
		))
	run_html = isempty(run_text) ? "" : _label(run_text)
	rise_html = isempty(rise_text) ? "" : _label(rise_text)
	(isempty(run_html) && isempty(rise_html)) || _ref_check_layout_array(fig, :annotations, who)

	cell = _ref_commit_target!(fig, target, who)
	layout = _cmn_layout(fig)
	xdir = _ref_axis_direction(layout, cell.xkey)
	ydir = _ref_axis_direction(layout, cell.ykey)
	# Hypotenuse A=(x0,y0) -> C=(x1,y1); the right-angle corner is (x1, y0) or
	# (x0, y1), whichever lies on the requested side of it on screen.
	rise = ydir * (v1 - v0)
	corner_right = (rise > 0) == is_below
	bx, by = corner_right ? (x1, ya) : (xa, y1)
	fields = Dict{Symbol, Any}(
		:type => "scatter",
		:x => Float64[xa, bx, x1, xa],
		:y => Float64[ya, by, y1, ya],
		:mode => "lines",
		:line => _ref_line_attr(edge, line_width, ""),
		:showlegend => false,
		:hoverinfo => "skip",
	)
	if !isempty(fill)
		fields[:fill] = "toself"
		fields[:fillcolor] = fill
	end
	_ref_push_trace!(fig, cell, GenericTrace("scatter", fields))
	_ref_refresh_legends!(fig)

	# Leg positions (axis units): horizontal leg at v_h, vertical leg at u_v;
	# each label goes on the outer side of its leg.
	v_h, v_third = corner_right ? (v0, v1) : (v1, v0)
	u_v, u_third = corner_right ? (u1, u0) : (u0, u1)
	gap = Float64(_REF_LABEL_GAP)
	name = _ref_item_name(who, cell)
	notes = Any[]
	if !isempty(run_html)
		above = ydir * (v_third - v_h) > 0
		push!(notes, _ref_text_annotation(
			cell,
			((u0 + u1) / 2, v_h),
			run_html,
			edge,
			font_size,
			(0.0, above ? -gap : gap),
			name;
			xanchor = "center",
			yanchor = above ? "top" : "bottom",
		))
	end
	if !isempty(rise_html)
		left = xdir * (u_third - u_v) < 0
		push!(notes, _ref_text_annotation(
			cell,
			(u_v, (v0 + v1) / 2),
			rise_html,
			edge,
			font_size,
			(left ? gap : -gap, 0.0),
			name;
			xanchor = left ? "left" : "right",
			yanchor = "middle",
		))
	end
	_ref_append_items!(fig, :annotations, notes)
	return _ref_done!(fig, cell)
end

"""
	slope_triangle!(fig, x0, y0, order; width=0.3, below=true, labels=("1", "<order>"),
	                color="gray", linewidth=1, fillcolor="", fontsize=0, secondary_y=false)
	slope_triangle!(sf::SubplotFigure, x0, y0, order; row=nothing, col=nothing, inset=nothing, kwargs...)

Draw a right-angled slope triangle (a "slope marker") whose hypotenuse starts
at `(x0, y0)` and rises `order` axis units per unit run, with the run labelled
`"1"` and the rise labelled with the order. Slopes are measured in axis
units: decades on log axes (a log-log triangle of order 2 spans one decade in
x for every two in y) and data units on linear axes.

The triangle is a closed scatter trace (`hoverinfo = "skip"`, not in the
legend) with corners `(x0, y0)`, the right-angle corner and
`(x1, y1)`; the labels are two annotations outside its legs.

# Keywords
- `width::Real = 0.3`: run of the triangle, in decades on a log x axis, else
  as a fraction of the x range (the explicit `xrange`, else the data extent of
  the axis; `ArgumentError` if neither exists). Negative widths extend to the
  left.
- `below::Bool = true`: put the right angle below the hypotenuse (`false`:
  above), as seen on screen (reversed axes are taken into account).
- `labels = ("1", string(order))`: run and rise labels, a 2-tuple or
  2-element vector of strings (`""` omits one; `\$...\$` math works). An
  integral order prints without decimals (`"2"`, not `"2.0"`).
- `color = "gray"`: outline and label colour; `linewidth::Real = 1`.
- `fillcolor = ""`: fill colour (`""`/`"none"`: unfilled).
- `fontsize::Real = 0`: label font size in px (0 = layout default).
- `secondary_y::Bool = false`, and for a SubplotFigure `row`, `col`, `inset`:
  as for [`hline!`](@ref).

`order` and `width` must be finite and non-zero; `(x0, y0)` positive on log
axes. Calls are additive. Returns `nothing` for a `Plot`/`SyncPlot` and `sf`
for a `SubplotFigure`.

# Example
```julia
N = [16, 32, 64, 128]
fig = plot_scatter(N, 10.0 .* N .^ -2.0; xscale = "log", yscale = "log")
slope_triangle!(fig, 32, 5e-3, -2; width = 0.3)
```
"""
slope_triangle!(fig, x0::Real, y0::Real, order::Real; kwargs...) =
	_ref_slope_triangle!(fig, x0, y0, order; kwargs...)
slope_triangle!(sf::SubplotFigure, x0::Real, y0::Real, order::Real; kwargs...) =
	_ref_subplot_call!(_ref_slope_triangle!, sf, x0, y0, order; kwargs...)

