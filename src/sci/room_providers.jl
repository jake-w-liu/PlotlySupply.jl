# PlotlySupply 2.0: the D12 room providers of panel titles, panel labels,
# legends and the figure title (room owner `:legend_titles`; the engine and
# its contract are in finalize.jl, `_request_room!`).
#
# What these providers place, nearest the axes first on each side of a plot
# area (`order` of the request in parentheses; colorbars use 10):
# - above: a top x axis (own or `secondary_xaxis!`, counted by the engine as
#   the area's own labels), a cell legend anchored above the axes (20), then
#   the title line: the panel title (`title!(…; row, col)`, `subplot_titles`)
#   with an outside top panel label on its line (30);
# - below: the x axis, a cell legend below the axes (20), an outside bottom
#   panel label (30);
# - right / left: a cell legend outside the axes (20), after the colorbars;
# - above the whole grid: an `:outside_top` figure legend (20), then the
#   figure title (90, only for the margin: plotly draws it at the top of the
#   figure); right of the grid: an `:outside_right` figure legend (20);
# - below everything: the band of the captions at the bottom of the figure
#   (`annotate!(…; coords = :figure)` text reaching below the plot area, 40),
#   with an `:outside_bottom` figure legend (20) stacked on top of them.
# Annotations placed in figure fractions (`coords = :figure`) are re-placed
# for the final margins (their `xshift`/`yshift`), so they stay at their
# fraction of the figure whatever the margins become.
# A title line or cell legend above the axes that reaches past the plot
# area's x span (a label beside its title, a wide legend over a narrow cell)
# rises clear of the top y tick label there (`_lt_tick_clearance`).
# A figure with a single plot area places its legend like a cell legend of
# that area. Inside panel labels and inside legends take no room; they follow
# the corners of their plot area when its domain changes (an equal-aspect
# cell: its fitted plot box).
#
# Each decoration is placed at its slot after the solve, as a function of
# the final domains only: annotations get the paper `x`/`y` of the slot and
# keep their own `xshift`/`yshift` (the gap `title!`/`panel_labels!` give
# them and the user's `offset`), legends get the paper `x`/`y` of the slot.
# The engine takes the room from the cell (rows move apart: a lower row's
# title never meets the x axis of the row above) or from the figure margin
# at the paper edge, which it raises (`margin_pushed = false`) for every
# decoration placed here: plotly does not push the margin for annotations,
# and when a legend outside the plot area pushes it, plotly.js 2.35.2 draws
# the legends that do not push (one inside a plot area) at the position the
# plot area had before the push (measured: 23 px off at 504 x 374 px when a
# figure legend above the plot raised the top margin from 25 to 59 px; at
# their place when the margin already held it).
#
# Ownership: a title or label is ours when it carries our name and sits on
# its side of the plot area it names, anchored at the area's x edges or
# centre; a legend when it is anchored against the area's edge on the outer
# side, or at the corner `_legend_placement` gives it. Anything the user
# moved elsewhere is neither requested nor moved.

const _LT_OWNER = :legend_titles
const _LT_ORDER_LEGEND = 20
const _LT_ORDER_LINE = 30
const _LT_ORDER_CAPTION = 40
const _LT_ORDER_TITLE = 90
# Paper tolerance for "at the domain edge" (positions written from domains).
const _LT_EDGE_TOL = 1e-6
# Paper tolerance against the plot box of an equal-aspect cell, which is
# estimated from its domain (the fit pads the domain by `_fin_bias`), and
# against a legend's estimated position along an edge.
const _LT_BOX_TOL = 3e-3
# Anchoring evidence (`anchored`) for a decoration placed above or below the
# axes: its px offset from the current edge matches the slot it would get
# within this many px plus this share of that offset (as for colorbars:
# the plot height a placement was converted with moves with the margins).
const _LT_ANCHOR_TOL = 2.0
const _LT_ANCHOR_SHARE = 0.5
# How far (tick font sizes) the box of a y tick label at the top of the
# range reaches above the plot area (probe p31, plotly.js 2.35.2: 0.65 f for
# Verdana 12 px, 0.53-0.56 f for Times and Arial at 8-20 px).
const _LT_TICK_REACH = 0.65
const _LT_TITLE_NAME = r"^plotlysupply:title:(\d+):(\d+)$"
const _LT_LABEL_NAME = r"^plotlysupply:panel_label:(\d+):(\d+)$"

_lt_real(value) = _fin_isfinite_real(value) ? Float64(value) : nothing
_lt_mid(span) = (span[1] + span[2]) / 2
_lt_within(v::Float64, span, tol::Float64) = span[1] - tol <= v <= span[2] + tol

# One decoration: its request (`side === :none` for one that takes no room)
# and what the place phase needs (`role`, `id`: annotation name or legend id,
# `data`: role-specific).
struct _LtDecor
	key::String
	area::Symbol
	side::Symbol
	px::Float64
	order::Int
	anchored::Bool
	margin_pushed::Bool
	role::Symbol
	id::String
	data::Any
end

# (row, col) => plot-area key of every occupied grid cell the plan has.
function _lt_cell_areas(plan)
	out = Dict{Tuple{Int, Int}, Symbol}()
	grid_ref = plan.layout.subplots.grid_ref
	for r in axes(grid_ref, 1), c in axes(grid_ref, 2)
		(isassigned(grid_ref, r, c) && !isempty(grid_ref[r, c])) || continue
		entry = first(grid_ref[r, c])
		fields = entry.trace_kwargs.fields
		key = nothing
		if String(entry.subplot_kind) == "xy"
			key = _fin_axis_key(_fin_string(get(fields, :xaxis, nothing)))
		else
			for k in (:scene, :geo, :subplot)
				name = _fin_string(get(fields, k, nothing))
				name === nothing || (key = Symbol(name); break)
			end
		end
		(key !== nothing && haskey(plan.areas, key)) && (out[(r, c)] = key)
	end
	return out
end

# The plot box of an equal-aspect cell estimated from its current domain:
# `_fin_fit_cells` widens the box of width w by `_fin_bias(w)` on the left
# (a linear function of w).
function _lt_fitted_box(plan, a)
	(x0, x1), yd = a.current
	b = _fin_bias(0.0)
	slope = _fin_bias(1.0) - b
	w = ((x1 - x0) * plan.Wp - b) / (1 + slope)
	w > 0 || return a.current
	return ((max(x0, x1 - w / plan.Wp), x1), yd)
end

# Reference boxes (paper) a decoration of area `a` may have been placed
# against, with their tolerance: the current domain; for an equal-aspect
# cell also its plot box; for a single figure also the whole paper (its
# legend is placed in paper fractions).
function _lt_ref_boxes(plan, a, single::Bool)
	boxes = Tuple{_RoomBox, Float64}[(a.current, _LT_EDGE_TOL)]
	# The estimate is off by up to 4/1.025 px over the plot width the box was
	# fitted at (the design size, when this is the export copy).
	a.aspect && push!(boxes, (_lt_fitted_box(plan, a), _LT_BOX_TOL + 8 / plan.Wp))
	single && push!(boxes, (((0.0, 1.0), (0.0, 1.0)), _LT_EDGE_TOL))
	return boxes
end

# The plot box a decoration of `a` is placed against after the solve.
_lt_final_box(a) = a.final

# Font size (px) of an annotation: its own, else the layout's.
_lt_font(plan, item) = _fin_mapping_font_size(item, :font, plan.font)

# Room (px) an annotation takes on its side of the plot area: its text
# (`_text_extent`: lines, MathJax rows) plus plotly's frame around it
# (borderpad + borderwidth on each side), plus the part of its own `yshift`
# beyond the `_TEXT_PANEL_GAP` gap that moves it farther out (a `title!`
# `offset`). `outward` is +1 above the plot area, -1 below it.
function _lt_annotation_px(plan, item, outward::Float64)
	text = _cmn_mapping_get(item, :text)
	(text isa AbstractString && !isempty(strip(text))) || return 0.0
	shift = something(_lt_real(_cmn_mapping_get(item, :yshift, 0)), 0.0)
	return _text_extent(text, _lt_font(plan, item))[2] + _TEXT_ANNOTATION_FRAME +
		max(0.0, outward * shift - _TEXT_PANEL_GAP)
end

# The x of an annotation anchored at `anchor` ("left"/"right"/else centre) of
# `span`.
_lt_anchor_x(anchor, span) = anchor == "left" ? span[1] : anchor == "right" ? span[2] : _lt_mid(span)

# Role of a panel title / panel label annotation of area `a` (`nothing`: not
# ours). Titles: on the title line. Labels: `:line` (outside top), `:below`
# (outside bottom), `:inside_top`, `:inside_bottom`; `left` is the corner.
function _lt_annotation_role(item, kind::Symbol, boxes)
	_fin_string(_cmn_mapping_get(item, :xref, "paper")) == "paper" || return nothing
	_fin_string(_cmn_mapping_get(item, :yref, "paper")) == "paper" || return nothing
	x = _lt_real(_cmn_mapping_get(item, :x))
	y = _lt_real(_cmn_mapping_get(item, :y))
	(x === nothing || y === nothing) && return nothing
	yanchor = something(_fin_string(_cmn_mapping_get(item, :yanchor)), "auto")
	if kind === :title
		yanchor == "bottom" || return nothing
		xanchor = something(_fin_string(_cmn_mapping_get(item, :xanchor)), "auto")
		for (box, tol) in boxes
			y >= box[2][2] - tol || continue
			abs(x - _lt_anchor_x(xanchor, box[1])) <= tol && return (role = :line, left = false)
		end
		return nothing
	end
	for (box, tol) in boxes
		(xd, yd) = box
		left = abs(x - xd[1]) <= tol
		(left || abs(x - xd[2]) <= tol) || continue
		if yanchor == "bottom" && y >= yd[2] - tol
			return (role = :line, left = left)
		elseif yanchor == "top" && y <= yd[1] + tol
			return (role = :below, left = left)
		elseif yanchor == "top" && abs(y - yd[2]) <= tol
			return (role = :inside_top, left = left)
		elseif yanchor == "bottom" && abs(y - yd[1]) <= tol
			return (role = :inside_bottom, left = left)
		end
	end
	return nothing
end

# Whether an annotation placed `offset` px (its own `yshift` excluded) from
# the current edge `edge` (paper) of an area sits at `y`, converted with the
# plot height of the figure's own size: the anchoring evidence of D12.
function _lt_anchored_at(plan, y::Float64, edge::Float64, offset::Float64, outward::Float64)
	_, Hp = _room_design_px(plan)
	return abs((y - edge) * outward * Hp - offset) <= _LT_ANCHOR_TOL + _LT_ANCHOR_SHARE * offset
end

# Legend box `id` of `p` as a Dict, or `nothing` when it draws nothing.
function _lt_legend_box(plan, id::String)
	d = _symbol_dict(get(plan.layout.fields, Symbol(id), nothing))
	get(d, :visible, true) === false && return nothing
	return d
end

# The inset legends of this figure are placed with (`_legend_placement`).
function _lt_legend_inset(plan)
	sf = plan.ctx.sf
	return sf === nothing ? _DEFAULT_LEGEND_INSET[] : sf.legend_inset
end

# Plot-area key of a `_legend_subplot_assignment` key ("xy:x2|y2" -> :xaxis2,
# "scene:scene2" -> :scene2), or `nothing`.
function _lt_legend_area(key::AbstractString)
	if startswith(key, "xy:")
		return _fin_axis_key(first(split(key[4:end], '|')))
	end
	i = findfirst(':', key)
	i === nothing && return nothing
	name = key[(i + 1):end]
	return occursin(_FIN_DOMAIN_SUBPLOT, name) ? Symbol(name) : nothing
end

# Positions `_legend_placement` gives inside a plot area.
const _LT_INSIDE_POSITIONS = (:topright, :topleft, :bottomleft, :bottomright, :right, :left, :bottom, :top, :center)

# How legend box `d` sits relative to plot area `a`: `(side, …)` for a box
# anchored outside one of its edges (`:top`, `:bottom`, `:right`, `:left`),
# `(side = :none, position)` for one at an inside position, or `nothing`.
function _lt_legend_role(plan, d::AbstractDict, a, boxes, figure::Bool)
	_fin_string(get(d, :xref, "paper")) == "paper" || return nothing
	x = _lt_real(get(d, :x, nothing))
	y = _lt_real(get(d, :y, nothing))
	(x === nothing || y === nothing) && return nothing
	xanchor = something(_fin_string(get(d, :xanchor, nothing)), "auto")
	yanchor = something(_fin_string(get(d, :yanchor, nothing)), "auto")
	yref = something(_fin_string(get(d, :yref, nothing)), "paper")
	inset = _lt_legend_inset(plan)
	# The legacy form of a single figure's `:outside_top` legend (moved to the
	# container under the title by the 2.0 wave-4 stacking pass).
	if yref == "container"
		(figure && yanchor == "top" && y > 0.5 && xanchor == "center" && abs(x - 0.5) <= _LT_EDGE_TOL) &&
			return (side = :top, box = last(boxes)[1], tol = _LT_EDGE_TOL, legacy = true, canonical = true)
		return nothing
	end
	for (box, tol) in boxes
		(xd, yd) = box
		# `canonical`: where `_legend_placement` puts an `:outside_*` legend
		# (centred above/below, top-aligned beside); any other box outside an
		# edge is the user's (a tuple position): it is only moved outward.
		top_y = _legend_placement(:outside_right, xd, yd, inset; figure = false)[:y]
		if yanchor == "bottom" && y >= yd[2] - tol && _lt_within(x, xd, tol)
			return (side = :top, box = box, tol = tol, legacy = false,
				canonical = xanchor == "center" && abs(x - _lt_mid(xd)) <= tol)
		elseif yanchor == "top" && y <= yd[1] + tol && _lt_within(x, xd, tol)
			return (side = :bottom, box = box, tol = tol, legacy = false,
				canonical = xanchor == "center" && abs(x - _lt_mid(xd)) <= tol)
		elseif xanchor == "left" && x >= xd[2] - tol && _lt_within(y, yd, tol)
			return (side = :right, box = box, tol = tol, legacy = false, canonical = yanchor == "top" && abs(y - top_y) <= tol)
		elseif xanchor == "right" && x <= xd[1] + tol && _lt_within(y, yd, tol)
			return (side = :left, box = box, tol = tol, legacy = false, canonical = yanchor == "top" && abs(y - top_y) <= tol)
		end
	end
	for (box, tol) in boxes, position in _LT_INSIDE_POSITIONS
		want = _legend_placement(position, box[1], box[2], inset; figure = false)
		(want[:xanchor] == xanchor && want[:yanchor] == yanchor) || continue
		(abs(want[:x] - x) <= tol && abs(want[:y] - y) <= tol) || continue
		return (side = :none, position = position)
	end
	return nothing
end

# Depth (px) of a legend box perpendicular to `side`.
function _lt_legend_depth(plan, id::String, side::Symbol)
	size = _legend_box_size(plan.p, id)
	size === nothing && return 0.0
	return side in (:top, :bottom) ? Float64(size[2]) : Float64(size[1])
end

# Px the requests of this provider take on `side` of area `key` before
# `order` (nearest the axes first), with the gaps the engine puts between
# them: the offset a decoration of that order gets.
function _lt_expected_offset(plan, out::Vector{_LtDecor}, key::Symbol, side::Symbol, order::Int)
	a = plan.areas[key]
	offset = _room_label_px(a.own[side]) + _ROOM_GAP
	for d in out
		(d.area === key && d.side === side && d.order < order) || continue
		offset += d.px + _ROOM_GAP
	end
	return offset
end

"""
	_lt_decorations(plan) -> Vector{_LtDecor}

Every decoration of `plan.p` the `:legend_titles` providers place, with the
room it requests (pure; the same list in the measure and place phases).
"""
function _lt_decorations(plan)
	out = _LtDecor[]
	p = plan.p
	layout = plan.layout
	cells = _lt_cell_areas(plan)
	single = layout.subplots.rows * layout.subplots.cols == 1
	boxes_of = Dict{Symbol, Vector{Tuple{_RoomBox, Float64}}}()
	boxes(key) = get!(() -> _lt_ref_boxes(plan, plan.areas[key], single), boxes_of, key)

	# Legends first: they sit nearer the axes than the title line.
	if get(layout.fields, :showlegend, nothing) !== false
		_lt_legend_decorations!(out, plan, cells, single, boxes)
	end

	# Panel titles and labels.
	items = get(layout.fields, :annotations, nothing)
	# area => (name, left, px, baseline depth or `nothing`)
	lines = Dict{Symbol, Vector{Tuple{String, Bool, Float64, Union{Nothing, Float64}}}}()
	if items isa AbstractVector
		for item in items
			name = _cmn_item_name(item)
			name isa AbstractString || continue
			m = match(_LT_TITLE_NAME, name)
			kind = :title
			if m === nothing
				m = match(_LT_LABEL_NAME, name)
				m === nothing && continue
				kind = :label
			end
			key = get(cells, (parse(Int, m.captures[1]), parse(Int, m.captures[2])), nothing)
			key === nothing && continue
			role = _lt_annotation_role(item, kind, boxes(key))
			role === nothing && continue
			px = _lt_annotation_px(plan, item, role.role === :below ? -1.0 : 1.0)
			if role.role === :line
				text = _cmn_mapping_get(item, :text)
				depth = text isa AbstractString ? _text_baseline_depth(text, _lt_font(plan, item)) : nothing
				push!(get!(Vector{Tuple{String, Bool, Float64, Union{Nothing, Float64}}}, lines, key),
					(String(name), role.left, px, depth))
			elseif role.role === :below
				y = Float64(_cmn_mapping_get(item, :y))
				expected = _lt_expected_offset(plan, out, key, :bottom, _LT_ORDER_LINE)
				anchored = _lt_anchored_at(plan, y, plan.areas[key].current[2][1], expected - _ROOM_GAP, -1.0)
				push!(out, _LtDecor("label:" * name, key, :bottom, px, _LT_ORDER_LINE, anchored, false,
					:below_label, String(name), role.left))
			else
				push!(out, _LtDecor("label:" * name, key, :none, 0.0, 0, false, false,
					role.role, String(name), role.left))
			end
		end
	end
	# One baseline for the title lines of the areas sharing a top edge (a row
	# of the grid): each title or label is raised by its baseline depth's
	# shortfall to the deepest one there (`_text_baseline_depth`; plotly.js
	# aligns the bottoms of the boxes). Its room grows by as much.
	deepest = Dict{Float64, Float64}()
	for (key, list) in lines, entry in list
		entry[4] === nothing && continue
		edge = round(plan.areas[key].current[2][2]; digits = 6)
		deepest[edge] = max(get(deepest, edge, 0.0), entry[4])
	end
	# (name, left, raise px) per area
	raised = Dict{Symbol, Vector{Tuple{String, Bool, Float64}}}()
	for (key, list) in lines
		edge = round(plan.areas[key].current[2][2]; digits = 6)
		raised[key] = [(name, left, depth === nothing ? 0.0 : deepest[edge] - depth) for (name, left, _, depth) in list]
	end
	# A title or label reaching past the cell's x span (a label beside its
	# title) sits over the tick labels of the y axis there: the row's lines
	# rise clear of the top tick label (all of them, to keep the baseline).
	lift = Dict{Float64, Float64}()
	for (key, entries) in raised
		edge = round(plan.areas[key].current[2][2]; digits = 6)
		expected = _lt_expected_offset(plan, out, key, :top, _LT_ORDER_LINE)
		lift[edge] = max(get(lift, edge, 0.0), _lt_line_lift(plan, items, key, entries, expected))
	end
	for (key, list) in lines
		edge = round(plan.areas[key].current[2][2]; digits = 6)
		entries = [(name, left, raise + lift[edge]) for (name, left, raise) in raised[key]]
		px = maximum(entry[3] + raise for (entry, (_, _, raise)) in zip(list, entries))
		px > 0 || continue
		expected = _lt_expected_offset(plan, out, key, :top, _LT_ORDER_LINE)
		top = plan.areas[key].current[2][2]
		anchored = any(entries) do (name, _, raise)
			item = _lt_find_annotation(items, name)
			item !== nothing && _lt_anchored_at(plan, Float64(_cmn_mapping_get(item, :y)), top, expected - _ROOM_GAP + raise, 1.0)
		end
		push!(out, _LtDecor("line:" * String(key), key, :top, px, _LT_ORDER_LINE, anchored, false,
			:line, String(key), entries))
	end

	# The captions at the bottom of the figure, under everything else.
	_lt_caption_decorations!(out, plan)
	# The figure title above everything placed at the top of the figure.
	_lt_title_decoration!(out, plan)
	return out
end

# (bottom, top) px from the bottom of the figure of an annotation placed in
# figure fractions (`spec` from `_figure_annotation_spec`, with a `fy`): the
# height `annotate!` reserves for it (`_figure_annotation_text_height`).
function _lt_caption_span(plan, item, spec)
	height = _figure_annotation_text_height(_cmn_mapping_get(item, :text), _figure_annotation_fontsize(item, plan.layout))
	anchor = something(_fin_string(_cmn_mapping_get(item, :yanchor)), "auto")
	anchor == "auto" && (anchor = _annotation_auto_yanchor(spec.fy))
	below = anchor == "top" ? height : anchor == "middle" ? height / 2 : 0.0
	bottom = spec.fy * plan.H + spec.dy - below
	return (bottom, bottom + height)
end

# The id of an `:outside_bottom` figure legend: centred, at the bottom edge
# of the figure container (`_legend_placement` with `figure = true`), else
# `nothing`.
function _lt_bottom_figure_legend(plan)
	ids = ["legend"]
	any(_trace_is_figure_legend_entry, plan.p.data) && push!(ids, _FIGURE_LEGEND_ID)
	for id in ids
		d = _lt_legend_box(plan, id)
		(d === nothing || isempty(d)) && continue
		_fin_string(get(d, :xref, "paper")) == "paper" || continue
		something(_fin_string(get(d, :yref, nothing)), "paper") == "container" || continue
		something(_fin_string(get(d, :yanchor, nothing)), "auto") == "bottom" || continue
		something(_fin_string(get(d, :xanchor, nothing)), "auto") == "center" || continue
		x, y = _lt_real(get(d, :x, nothing)), _lt_real(get(d, :y, nothing))
		(x === nothing || y === nothing) && continue
		(abs(x - 0.5) <= _LT_EDGE_TOL && 0 <= y < 0.5) || continue
		return id
	end
	return nothing
end

# The band of the captions at the bottom of the figure: the annotations
# placed in figure fractions without an arrow whose box reaches below the
# plot area (the captions `annotate!` reserves the bottom margin for). The
# band (their top plus `_FIGURE_ANNOTATION_GAP`, at most half the figure)
# is requested at the bottom of the figure, beyond the x axes and what is
# stacked under them, so the margin holds the captions whatever else
# changes it (`tight_layout!`, a new legend). An `:outside_bottom` figure
# legend (container-referenced) is stacked on the band instead of on the
# bottom edge of the figure, where the captions are.
function _lt_caption_decorations!(out, plan)
	items = get(plan.layout.fields, :annotations, nothing)
	items isa AbstractVector || return out
	top = -Inf
	for item in items
		spec = _figure_annotation_spec(item)
		(spec === nothing || spec.fy === nothing) && continue
		_cmn_mapping_get(item, :showarrow) === false || continue
		_cmn_mapping_get(item, :visible) === false && continue
		bottom, item_top = _lt_caption_span(plan, item, spec)
		bottom < plan.margins.b || continue
		top = max(top, item_top)
	end
	isfinite(top) || return out
	band = min(max(top, 0.0) + _FIGURE_ANNOTATION_GAP, plan.H / 2)
	legend = _lt_bottom_figure_legend(plan)
	if legend !== nothing && get(plan.layout.fields, :showlegend, nothing) !== false
		px = _lt_legend_depth(plan, legend, :bottom)
		px > 0 && push!(out, _LtDecor("figure_legend:" * legend, :figure, :bottom, px, _LT_ORDER_LEGEND, false, false,
			:bottom_figure_legend, legend, band))
	end
	push!(out, _LtDecor("figure_captions", :figure, :bottom, band, _LT_ORDER_CAPTION, false, false,
		:figure_captions, "", band))
	return out
end

function _lt_find_annotation(items, name::AbstractString)
	items isa AbstractVector || return nothing
	for item in items
		_cmn_item_name(item) == name && return item
	end
	return nothing
end

# Cell legends (per-subplot legends; a single figure's legend counts as the
# legend of its plot area) and the figure legends of a grid.
function _lt_legend_decorations!(out, plan, cells, single::Bool, boxes)
	p = plan.p
	cell_mode = any(t -> t isa GenericTrace && haskey(t.fields, :legend) && !_trace_is_figure_legend_entry(t), p.data)
	cell_ids = Tuple{String, Symbol}[]
	if cell_mode
		order, ids, _, _ = try
			_legend_subplot_assignment(p)
		catch err
			err isa ArgumentError || rethrow()
			return out      # more cell legends than legend ids: nothing is placed
		end
		for key in order
			area = _lt_legend_area(key)
			(area !== nothing && haskey(plan.areas, area)) || continue
			push!(cell_ids, (_legend_id(ids[key]), area))
		end
	elseif single && haskey(cells, (1, 1))
		push!(cell_ids, ("legend", cells[(1, 1)]))
	end
	for (id, area) in cell_ids
		d = _lt_legend_box(plan, id)
		d === nothing && continue
		role = _lt_legend_role(plan, d, plan.areas[area], boxes(area), single)
		role === nothing && continue
		if role.side === :none
			push!(out, _LtDecor("legend:" * id, area, :none, 0.0, 0, false, false, :inside_legend, id, role.position))
			continue
		end
		px = _lt_legend_depth(plan, id, role.side)
		px > 0 || continue
		edge = _room_edge(plan.areas[area].current, role.side)
		expected = _lt_expected_offset(plan, out, area, role.side, _LT_ORDER_LEGEND)
		# Above the axes and wider than the plot area, it rises clear of the
		# top tick labels it reaches over.
		lift = role.side === :top ? max(0.0, _lt_legend_tick_clearance(plan, plan.areas[area], id, d) - expected) : 0.0
		px += lift
		coordinate = role.side in (:top, :bottom) ? Float64(d[:y]) : Float64(d[:x])
		outward = role.side in (:top, :right) ? 1.0 : -1.0
		anchored = !role.legacy && _lt_anchored_legend(plan, coordinate, edge, expected + lift, outward, role.side)
		# Attached to the edge (its outward coordinate is the slot's): placed
		# by `set_legend!` at an `:outside_*` position or at the edge itself
		# (a tuple position on the edge, matplotlib's `bbox_to_anchor`), or
		# already at its slot. A box the user put farther out is only moved
		# outward.
		attached = role.legacy || role.canonical || anchored ||
			abs(coordinate - _room_edge(role.box, role.side)) <= role.tol
		push!(out, _LtDecor("legend:" * id, area, role.side, px, _LT_ORDER_LEGEND, anchored, false,
			:cell_legend, id, merge(role, (attached = attached, lift = lift))))
	end
	single && return out
	# Figure legends of a grid: "legend" without cell legends, and the
	# reserved figure legend of `legend_entry!(…; legend_target = :figure)`.
	figure_ids = String[]
	cell_mode || push!(figure_ids, "legend")
	any(_trace_is_figure_legend_entry, p.data) && push!(figure_ids, _FIGURE_LEGEND_ID)
	for id in figure_ids
		d = _lt_legend_box(plan, id)
		d === nothing && continue
		side = _lt_figure_legend_side(d)
		side === nothing && continue
		px = _lt_legend_depth(plan, id, side)
		px > 0 || continue
		push!(out, _LtDecor("figure_legend:" * id, :figure, side, px, _LT_ORDER_LEGEND, false, false,
			:figure_legend, id, side))
	end
	return out
end

# Anchoring evidence of a legend placed `offset` px outside `edge`.
function _lt_anchored_legend(plan, coordinate::Float64, edge::Float64, offset::Float64, outward::Float64, side::Symbol)
	Wp, Hp = _room_design_px(plan)
	px = (coordinate - edge) * outward * (side in (:top, :bottom) ? Hp : Wp)
	return abs(px - offset) <= _LT_ANCHOR_TOL + _LT_ANCHOR_SHARE * offset
end

# Side of the grid a figure legend is placed on by these providers: `:top`
# for an `:outside_top` legend (centred, anchored at its bottom above the
# plot area; or the legacy container form under the title), `:right` for an
# `:outside_right` one; `nothing` for any other placement.
function _lt_figure_legend_side(d::AbstractDict)
	_fin_string(get(d, :xref, "paper")) == "paper" || return nothing
	x = _lt_real(get(d, :x, nothing))
	y = _lt_real(get(d, :y, nothing))
	(x === nothing || y === nothing) && return nothing
	xanchor = something(_fin_string(get(d, :xanchor, nothing)), "auto")
	yanchor = something(_fin_string(get(d, :yanchor, nothing)), "auto")
	yref = something(_fin_string(get(d, :yref, nothing)), "paper")
	if xanchor == "center" && abs(x - 0.5) <= _LT_EDGE_TOL
		yref == "paper" && yanchor == "bottom" && y >= 1 - _LT_EDGE_TOL && return :top
		yref == "container" && yanchor == "top" && y > 0.5 && return :top
		return nothing
	end
	(yref == "paper" && xanchor == "left" && x >= 1 - _LT_EDGE_TOL && -_LT_EDGE_TOL <= y <= 1 + _LT_EDGE_TOL) &&
		return :right
	return nothing
end

# The band (px) a container-referenced figure title takes at the top of the
# figure (`_text_title_band` plus a `pad.b` of its own); the margin must hold
# it on top of what is stacked above the top row, which plotly does not add
# up for annotations. Requested only when something of ours sits at the top
# edge of the figure.
function _lt_title_decoration!(out, plan)
	p = plan.p
	d = _text_title_dict(p)
	d === nothing && return out
	get(d, :yref, "container") == "container" || return out
	tops = [a.current[2][2] for a in values(plan.areas)]
	isempty(tops) && return out
	highest = maximum(tops)
	at_top = any(out) do decor
		decor.side === :top || return false
		decor.area === :figure && return true
		plan.areas[decor.area].current[2][2] >= highest - _LT_EDGE_TOL
	end
	# A top x axis (own or `secondary_xaxis!`) at the top edge counts too: its
	# tick labels and title are drawn up to the margin edge.
	at_top = at_top || any(a -> a.own[:top] > 0 && a.current[2][2] >= highest - _LT_EDGE_TOL,
		values(plan.areas))
	at_top || return out
	pad = _symbol_dict(get(d, :pad, nothing))
	pad_b = something(_legend_real(get(pad, :b, nothing)), 0.0)
	# A title at plotly's automatic height is pinned with the default pad.t
	# (`_lt_pin_title!`).
	y = get(d, :y, "auto")
	pin = (y === nothing || y == "auto") && !haskey(pad, :t) ? Float64(_TEXT_TITLE_TOP_PAD) : 0.0
	band = _text_title_band(p) + pad_b + pin
	band > 0 || return out
	push!(out, _LtDecor("figure_title", :figure, :top, band, _LT_ORDER_TITLE, false, false, :figure_title, "title", nothing))
	return out
end

function _room_requests!(plan, ::Val{:legend_titles})
	for d in _lt_decorations(plan)
		d.side === :none && continue
		_request_room!(plan, d.area, d.side, d.px; owner = _LT_OWNER, key = d.key, order = d.order,
			anchored = d.anchored, margin_pushed = d.margin_pushed)
	end
	return nothing
end

# Paper coordinate `px` px outside `edge` on `side` (positive outward).
function _lt_outside(plan, edge::Float64, px::Float64, side::Symbol)
	scale = side in (:top, :bottom) ? plan.Hp : plan.Wp
	sign = side in (:top, :right) ? 1.0 : -1.0
	return round(edge + sign * px / scale; digits = 6)
end

# `value` mapped from span `from` to span `to` (same fraction).
function _lt_map(value::Float64, from, to)
	span = from[2] - from[1]
	span > 0 || return value
	return round(to[1] + (value - from[1]) / span * (to[2] - to[1]); digits = 6)
end

# The x (or y) of a legend along the edge it sits on, in the final box: the
# same fraction of the domain for an exact reference box; the centre or an
# edge when it sat there on an estimated (equal-aspect) box; else unchanged.
function _lt_along(value::Float64, from, to, exact::Bool)
	exact && return _lt_map(value, from, to)
	for (a, b) in ((from[1], to[1]), (_lt_mid(from), _lt_mid(to)), (from[2], to[2]))
		abs(value - a) <= _LT_BOX_TOL && return round(b; digits = 6)
	end
	return value
end

# Replace the named annotation `name` of the shared annotation vector by a
# copy with `updates` applied, when a value changes (numbers compare within
# 1e-9; an `xshift` of 0 and a missing one are the same).
function _lt_update_annotation!(plan, name::AbstractString, updates::AbstractDict{Symbol})
	existing = plan.annotations === nothing ? get(plan.layout.fields, :annotations, nothing) : plan.annotations
	existing isa AbstractVector || return nothing
	index = findfirst(item -> _cmn_item_name(item) == name, existing)
	index === nothing && return nothing
	return _lt_update_annotation_at!(plan, index, updates)
end

# `_lt_update_annotation!` for the annotation at `index`.
function _lt_update_annotation_at!(plan, index::Integer, updates::AbstractDict{Symbol})
	existing = plan.annotations === nothing ? get(plan.layout.fields, :annotations, nothing) : plan.annotations
	entry = _symbol_dict(existing[index])
	changed = false
	for (key, value) in updates
		current = get(entry, key, nothing)
		if value isa Real
			have = _lt_real(current)
			if key === :xshift && value == 0
				# No shift is written as none (as `title!`/`panel_labels!` do).
				current === nothing && continue
				delete!(entry, :xshift)
				changed = true
				continue
			end
			(have !== nothing && isapprox(have, value; atol = 1e-9)) && continue
		else
			isequal(current, value) && continue
		end
		entry[key] = value
		changed = true
	end
	changed || return nothing
	anns = _room_annotations!(plan)
	anns[index] = attr(; entry...)
	return nothing
end

# Width (px) of an annotation's text box (`_text_extent` plus the frame).
function _lt_annotation_width(plan, item)
	text = _cmn_mapping_get(item, :text)
	(text isa AbstractString && !isempty(strip(text))) || return 0.0
	return _text_extent(text, _lt_font(plan, item))[1] + _TEXT_ANNOTATION_FRAME
end

# `xanchor` / `xshift` of an outside top panel label at the `left` (else
# right) corner of `span` on the title line: at the corner, inside the
# cell's x span; beside the corner, outside the span and clear of the panel
# title (`_text_panel_label_xplacement`), when the title is aligned to that
# corner or, at the final size, would reach the label (a centred title in
# a narrow cell) and the figure has room beside the corner for it. Beside a
# centred title wider than the span, the label clears the title's end.
function _lt_label_xplacement(plan, label, title, left::Bool, span)
	corner = (left ? "left" : "right", 0.0)
	title === nothing && return corner
	beside = (left ? "right" : "left", left ? -Float64(_TEXT_PANEL_GAP) : Float64(_TEXT_PANEL_GAP))
	xanchor = something(_fin_string(_cmn_mapping_get(title, :xanchor)), "auto")
	xanchor == (left ? "left" : "right") && return beside
	Wp = plan.Wp
	lo, hi = span[1] * Wp, span[2] * Wp
	tw = _lt_annotation_width(plan, title)
	lw = _lt_annotation_width(plan, label)
	dx = something(_lt_real(_cmn_mapping_get(title, :xshift, 0)), 0.0)
	anchor = _lt_anchor_x(xanchor, (lo, hi)) + dx
	t_lo, t_hi = xanchor == "left" ? (anchor, anchor + tw) :
		xanchor == "right" ? (anchor - tw, anchor) : (anchor - tw / 2, anchor + tw / 2)
	reach = left ? t_lo < lo + lw + _TEXT_PANEL_GAP : t_hi > hi - lw - _TEXT_PANEL_GAP
	reach || return corner
	over = left ? max(lo - t_lo, 0.0) : max(t_hi - hi, 0.0)
	room = left ? plan.margins.l + lo : plan.margins.r + (Wp - hi)
	room >= lw + _TEXT_PANEL_GAP + over || return corner
	return (beside[1], left ? beside[2] - over : beside[2] + over)
end

# Px a decoration spanning `lo`..`hi` (px from the left of the plot width
# `plan.Wp`) right above area `a` keeps between its bottom and the plot
# area's top, so that it clears the top tick label of a y axis on a side it
# reaches past (at the current domain); 0 when it stays over the plot area
# or that side has no tick labels.
function _lt_tick_clearance(plan, a, lo::Float64, hi::Float64)
	span = (a.current[1][1] * plan.Wp, a.current[1][2] * plan.Wp)
	need = 0.0
	for (side, past) in ((:left, lo < span[1] - 0.5), (:right, hi > span[2] + 0.5))
		(past && a.own[side] > 0) || continue
		font = _lt_y_tick_font(plan, a, side)
		font > 0 && (need = max(need, _LT_TICK_REACH * font + 1))
	end
	return need
end

# `_lt_tick_clearance` of the legend `id` (layout entry `d`) above area `a`,
# from its estimated width and `x`/`xanchor` (`"auto"`: plotly.js anchors
# left up to x = 1/3, right from 2/3, centred between).
function _lt_legend_tick_clearance(plan, a, id::String, d::AbstractDict)
	size = _legend_box_size(plan.p, id)
	x = _lt_real(get(d, :x, nothing))
	(size === nothing || x === nothing) && return 0.0
	w = Float64(size[1])
	px = get(d, :xref, "paper") == "container" ? x * plan.W - plan.margins.l : x * plan.Wp
	xanchor = string(get(d, :xanchor, "auto"))
	xanchor == "auto" && (xanchor = x <= 1 / 3 ? "left" : x >= 2 / 3 ? "right" : "center")
	lo = xanchor == "left" ? px : xanchor == "right" ? px - w : px - w / 2
	return _lt_tick_clearance(plan, a, lo, lo + w)
end

# Px the title line of area `key` rises (added to the `raise` of every
# entry) so that a title or label reaching past the plot area's x span (a
# label beside its title, a centred title wider than the cell) clears the
# top tick label there (`_lt_tick_clearance`). `entries` are
# (name, left, raise) and `expected` is the line's slot offset.
function _lt_line_lift(plan, items, key::Symbol, entries, expected::Float64)
	a = plan.areas[key]
	span = a.current[1]
	lo, hi = span[1] * plan.Wp, span[2] * plan.Wp
	t = findfirst(entry -> match(_LT_TITLE_NAME, entry[1]) !== nothing, entries)
	title = t === nothing ? nothing : _lt_find_annotation(items, entries[t][1])
	lift = 0.0
	for (name, left, raise) in entries
		item = _lt_find_annotation(items, name)
		item === nothing && continue
		w = _lt_annotation_width(plan, item)
		if item === title
			xanchor = something(_fin_string(_cmn_mapping_get(item, :xanchor)), "auto")
			x = _lt_anchor_x(xanchor, (lo, hi)) + something(_lt_real(_cmn_mapping_get(item, :xshift, 0)), 0.0)
		else
			xanchor, xshift = _lt_label_xplacement(plan, item, title, left, span)
			x = (left ? lo : hi) + xshift
		end
		extent = xanchor == "left" ? (x, x + w) : xanchor == "right" ? (x - w, x) : (x - w / 2, x + w / 2)
		lift = max(lift, _lt_tick_clearance(plan, a, extent[1], extent[2]) - (expected + raise))
	end
	return lift
end

# Largest tick font (px) of the y axes of area `a` showing tick labels on
# `side` (its own and those overlaying it); 0 when none do.
function _lt_y_tick_font(plan, a, side::Symbol)
	a.ykey === nothing && return 0.0
	yref = _fin_axis_ref(a.ykey)
	size = 0.0
	for (key, axis) in plan.layout.fields
		(_fin_is_axis_key(key) && String(key)[1] == 'y') || continue
		(key === a.ykey || _fin_string(_cmn_mapping_get(axis, :overlaying)) == yref) || continue
		_cmn_mapping_get(axis, :visible) === false && continue
		_cmn_mapping_get(axis, :showticklabels) === false && continue
		something(_fin_string(_cmn_mapping_get(axis, :side)), "left") == String(side) || continue
		size = max(size, _fin_mapping_font_size(axis, :tickfont, plan.font))
	end
	return size
end

function _room_place!(plan, ::Val{:legend_titles})
	items = get(plan.layout.fields, :annotations, nothing)
	single = plan.layout.subplots.rows * plan.layout.subplots.cols == 1
	decorations = _lt_decorations(plan)
	any(d -> d.role in (:inside_legend, :cell_legend, :figure_legend), decorations) &&
		_lt_hold_pushed_margins!(plan)
	for d in decorations
		if d.role === :line
			slot = _room_slot(plan, _LT_OWNER, d.key)
			slot === nothing && continue
			fx, fy = slot.domain_x, slot.domain_y
			# Annotations keep their own `yshift` (the `_TEXT_PANEL_GAP` gap and
			# any user offset): the slot offset beyond that gap, and the raise
			# that puts them on the row's baseline, go into `y`.
			title_name = findfirst(entry -> match(_LT_TITLE_NAME, entry[1]) !== nothing, d.data)
			title = title_name === nothing ? nothing : _lt_find_annotation(items, d.data[title_name][1])
			for (name, left, raise) in d.data
				item = _lt_find_annotation(items, name)
				item === nothing && continue
				y = _lt_outside(plan, slot.edge, slot.offset - _ROOM_GAP + raise, :top)
				if item === title
					x = _lt_anchor_x(something(_fin_string(_cmn_mapping_get(item, :xanchor)), "auto"), fx)
					_lt_update_annotation!(plan, name, Dict{Symbol, Any}(:x => round(x; digits = 9), :y => y))
				else
					xanchor, xshift = _lt_label_xplacement(plan, item, title, left, fx)
					_lt_update_annotation!(plan, name, Dict{Symbol, Any}(:x => round(left ? fx[1] : fx[2]; digits = 9),
						:y => y, :xanchor => xanchor, :xshift => xshift))
				end
			end
		elseif d.role === :below_label
			slot = _room_slot(plan, _LT_OWNER, d.key)
			slot === nothing && continue
			y = _lt_outside(plan, slot.edge, slot.offset - _ROOM_GAP, :bottom)
			x = d.data ? slot.domain_x[1] : slot.domain_x[2]
			_lt_update_annotation!(plan, d.id, Dict{Symbol, Any}(:x => round(x; digits = 9), :y => y))
		elseif d.role === :inside_top || d.role === :inside_bottom
			box = _lt_final_box(plan.areas[d.area])
			x = d.data ? box[1][1] : box[1][2]
			y = d.role === :inside_top ? box[2][2] : box[2][1]
			_lt_update_annotation!(plan, d.id, Dict{Symbol, Any}(:x => round(x; digits = 9), :y => round(y; digits = 9)))
		elseif d.role === :cell_legend
			slot = _room_slot(plan, _LT_OWNER, d.key)
			slot === nothing && continue
			_lt_place_cell_legend!(plan, d, slot)
		elseif d.role === :inside_legend
			a = plan.areas[d.area]
			box = _lt_final_box(a)
			want = _legend_placement(d.data, box[1], box[2], _lt_legend_inset(plan); figure = false)
			_room_relayout!(plan, Symbol(d.id, :_x), round(want[:x]; digits = 6))
			_room_relayout!(plan, Symbol(d.id, :_y), round(want[:y]; digits = 6))
		elseif d.role === :figure_title
			_lt_pin_title!(plan)
		elseif d.role === :bottom_figure_legend
			# Container-referenced: its bottom on the caption band, whatever
			# the margins (plotly.js 2.35.2 reserves the legend's height plus
			# `y` x the figure height under the x axes' automargin push; the
			# margin raised for the band holds that).
			_room_relayout!(plan, Symbol(d.id, :_y), round(d.data / plan.H; digits = 6))
		elseif d.role === :figure_legend
			slot = _room_slot(plan, _LT_OWNER, d.key)
			slot === nothing && continue
			box = _lt_legend_box(plan, d.id)
			if d.data === :top
				_room_relayout!(plan, Symbol(d.id, :_y), _lt_outside(plan, 1.0, slot.offset, :top))
				_room_relayout!(plan, Symbol(d.id, :_yanchor), "bottom")
				get(box, :yref, "paper") == "paper" || _room_relayout!(plan, Symbol(d.id, :_yref), "paper")
			else
				_room_relayout!(plan, Symbol(d.id, :_x), _lt_outside(plan, 1.0, slot.offset, :right))
			end
		end
	end
	_lt_place_figure_annotations!(plan)
	return nothing
end

# Every annotation placed in figure fractions (`coords = :figure`, named
# `plotlysupply:figure:…`) re-placed for the margins plotly will draw with:
# the paper `x`/`y` stay, the shifts become `f * (l + r) - l + dx` and
# `f * (t + b) - b + dy` (`_figure_annotations_place!`'s rule) with the plan's
# margins raised by the margin updates of this pass. A figure whose margins
# change later is re-placed by the next pass.
function _lt_place_figure_annotations!(plan)
	existing = plan.annotations === nothing ? get(plan.layout.fields, :annotations, nothing) : plan.annotations
	existing isa AbstractVector || return nothing
	any(item -> _figure_annotation_spec(item) !== nothing, existing) || return nothing
	_room_margin_updates!(plan)
	final(letter) = begin
		queued = get(plan.updates, Symbol(:margin_, letter), nothing)
		have = Float64(getfield(plan.margins, letter))
		_fin_isfinite_real(queued) ? max(have, Float64(queued)) : have
	end
	l, r, t, b = final(:l), final(:r), final(:t), final(:b)
	for index in eachindex(existing)
		spec = _figure_annotation_spec(existing[index])
		spec === nothing && continue
		updates = Dict{Symbol, Any}()
		spec.fx === nothing || (updates[:xshift] = round(spec.fx * (l + r) - l + spec.dx; digits = 2))
		spec.fy === nothing || (updates[:yshift] = round(spec.fy * (t + b) - b + spec.dy; digits = 2))
		_lt_update_annotation_at!(plan, index, updates)
	end
	return nothing
end

# A legend that does not push the margin (inside a plot area, or at its slot
# here) is drawn by plotly.js 2.35.2 at the plot area the figure had before
# another component (a colorbar) pushed the margin: measured, a top-right
# legend 40 px into the colorbar of a 700 x 500 px heatmap whose colorbar
# pushed the right margin from 50 to 102 px. With a legend placed here, the
# margin at each paper edge is raised to what plotly would push it to there
# (the reach past the plot area plus `_FIN_AUTOMARGIN_EXTRA`), so plotly
# finds nothing left to push and draws the legend where it belongs. It only
# raises margins.
function _lt_hold_pushed_margins!(plan)
	base = _fin_margins_base(plan.layout)
	need = Dict{Symbol, Float64}()
	for request in plan.requests
		request.margin_pushed || continue
		for slot in _room_slots(plan, request.owner, request.key)
			(slot.area === request.area && slot.side === request.side) || continue
			if slot.area !== :figure
				_room_neighbour(plan, plan.areas[slot.area], slot.side) === nothing || continue
			end
			paper = slot.side in (:right, :top) ? 1.0 : 0.0
			inside = abs(slot.edge - paper) * _room_px(plan, slot.side)
			reach = slot.offset + slot.px - inside
			reach > 0 || continue
			need[slot.side] = max(get(need, slot.side, 0.0), reach + _FIN_AUTOMARGIN_EXTRA)
		end
	end
	for (side, px) in need
		letter = Symbol(String(side)[1])
		key = Symbol(:margin_, letter)
		current = _cmn_mapping_get(get(plan.layout.fields, :margin, nothing), letter)
		have = _fin_isfinite_real(current) ? Float64(current) : getfield(base, letter)
		queued = get(plan.updates, key, nothing)
		_fin_isfinite_real(queued) && (have = max(have, Float64(queued)))
		px > have + 0.5 && _room_relayout!(plan, key, ceil(px))
	end
	return nothing
end

# A figure title at plotly's automatic height (the vertical centre of the top
# margin, `y = "auto"`) would sit in the middle of what is stacked above the
# top row: it is pinned to the top of the figure as `title!` places it
# (`y = 1`, `yanchor = "top"`, `pad.t = _TEXT_TITLE_TOP_PAD` unless it has a
# `pad.t`), so the band `_lt_title_decoration!` requests is where it is drawn.
function _lt_pin_title!(plan)
	d = _text_title_dict(plan.p)
	d === nothing && return nothing
	y = get(d, :y, "auto")
	(y === nothing || y == "auto") || return nothing
	_room_relayout!(plan, :title_y, 1)
	_room_relayout!(plan, :title_yanchor, "top")
	haskey(_symbol_dict(get(d, :pad, nothing)), :t) || _room_relayout!(plan, :title_pad_t, _TEXT_TITLE_TOP_PAD)
	return nothing
end

# A cell legend (or the legend of a single figure) outside one edge of its
# plot area: the outward coordinate at the slot, the other one carried along
# the edge into the final domain.
function _lt_place_cell_legend!(plan, d::_LtDecor, slot)
	box = _lt_legend_box(plan, d.id)
	box === nothing && return nothing
	role = d.data
	vertical = role.side in (:top, :bottom)
	outward_key, along_key = vertical ? (:y, :x) : (:x, :y)
	target = _lt_outside(plan, slot.edge, slot.offset + role.lift, role.side)
	if role.legacy
		_room_relayout!(plan, Symbol(d.id, :_yref), "paper")
		_room_relayout!(plan, Symbol(d.id, :_yanchor), "bottom")
		_room_relayout!(plan, Symbol(d.id, :_y), target)
		return nothing
	end
	current = Float64(box[outward_key])
	if !role.attached
		# A box the user placed farther out is only moved outward, clear of
		# what the slot holds nearer the axes.
		outward = role.side in (:top, :right) ? 1.0 : -1.0
		(target - current) * outward > 0 && _room_relayout!(plan, Symbol(d.id, :_, outward_key), target)
		return nothing
	end
	_room_relayout!(plan, Symbol(d.id, :_, outward_key), target)
	# Along the edge: the same place in the final domain (the same fraction
	# of an exact reference box; on an estimated equal-aspect box, its
	# centre or ends).
	from = role.box
	to = (slot.domain_x, slot.domain_y)
	index = vertical ? 1 : 2
	exact = !vertical || (from == plan.areas[d.area].current && !plan.areas[d.area].aspect)
	_room_relayout!(plan, Symbol(d.id, :_, along_key), _lt_along(Float64(box[along_key]), from[index], to[index], exact))
	return nothing
end
