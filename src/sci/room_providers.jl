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
# A panel label below its axes (`panel_labels!(; position = :bottomleft)`)
# sits right under them, nearer than a colorbar (10) or a legend below the
# cell: it labels the plot area, and a bar shared by a row of cells reserves
# room only under the cells of its colour axis, so a label placed beyond it
# was far from its cell, and the label of a cell without the bar was drawn
# over the bar (layout-fuzz-15).
const _LT_ORDER_BELOW_LABEL = 5
const _LT_ORDER_CAPTION = 40
const _LT_ORDER_TITLE = 90
# Paper tolerance for "at the domain edge" (positions written from domains):
# the snap within which a legend is left where it is (`_room_relayout!`,
# `_FIN_SNAP_PAPER`) plus the rounding of a written position. At 1e-6, an
# inside legend left 1.2e-5 from the corner of a cell its colorbar margin
# had narrowed was taken for the user's on the next pass, which then gave
# the margin back, and the figure went between the two (layout-fuzz-01).
const _LT_EDGE_TOL = _FIN_SNAP_PAPER + 1e-6
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

# Whether `layout` (of `p`) holds anything `_lt_decorations` places: a legend
# box (`legend`, `legend2`, ...), annotations, or a figure title with text.
function _lt_has_decorations(layout, p)
	items = get(layout.fields, :annotations, nothing)
	(items isa AbstractVector && !isempty(items)) && return true
	for key in keys(layout.fields)
		key isa Symbol && startswith(String(key), "legend") && return true
	end
	return _text_title_dict(p) !== nothing
end

# Legend box `id` of `p` as a Dict, or `nothing` when it draws nothing:
# hidden, or listing no entry (plotly.js draws no legend then; the empty box
# of a lone heatmap's cell, taken for an inside legend, held the margins its
# colorbar pushed on one pass and not on the next, layout-fuzz-01).
function _lt_legend_box(plan, id::String)
	id in _lt_listed_legends(plan) || return nothing
	d = _symbol_dict(get(plan.layout.fields, Symbol(id), nothing))
	get(d, :visible, true) === false && return nothing
	return d
end

# The `:inside_legend` decoration (no room) of grid cell legend `id`, which
# lists no entry, when its box is visible and sits at an inside position of
# its cell (`_lt_legend_role`); else nothing (a box the user put outside
# stays where it is and takes no room while it is empty).
function _lt_empty_cell_legend!(out, plan, id::String, area::Symbol, boxes)
	d = _symbol_dict(get(plan.layout.fields, Symbol(id), nothing))
	(isempty(d) || get(d, :visible, true) === false) && return out
	role = _lt_legend_role(plan, d, plan.areas[area], boxes(area), false)
	(role === nothing || role.side !== :none) && return out
	push!(out, _LtDecor("legend:" * id, area, :none, 0.0, 0, false, false, :inside_legend, id, role.position))
	return out
end

# The ids of the legends some trace of the plan's figure is listed in (as
# `_legend_entry_indices` counts entries), from one scan of the traces per
# plan: asked per legend, the emptiness check cost a 6 x 6 grid of heatmaps
# a fifth more per finalize (Q27).
function _lt_listed_legends(plan)
	memo = _lt_plan_memo(plan)
	ids = get(memo, :listed_legends, nothing)
	ids === nothing || return ids::Set{String}
	ids = Set{String}()
	for trace in plan.p.data
		trace isa GenericTrace || continue
		_trace_will_showlegend(trace) || continue
		push!(ids, _legend_trace_legend_id(trace))
	end
	memo[:listed_legends] = ids
	return ids
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
	size = _lt_box_size(plan, id)
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
	# Nothing to place: no legend box, no annotation (panel titles and
	# labels, captions) and no figure title.
	_lt_has_decorations(layout, p) || return out
	cells = _lt_cell_areas(plan)
	single = layout.subplots.rows * layout.subplots.cols == 1
	boxes_of = Dict{Symbol, Vector{Tuple{_RoomBox, Float64}}}()
	boxes(key) = get!(() -> _lt_ref_boxes(plan, plan.areas[key], single), boxes_of, key)

	# Legends first: they sit nearer the axes than the title line.
	if get(layout.fields, :showlegend, nothing) !== false
		_lt_legend_decorations!(out, plan, cells, single, boxes)
	end

	# Panel titles and labels, a title wider than its line broken into lines
	# first (`_lt_wrap_panel_titles!`, in the plan's annotations).
	_lt_wrap_panel_titles!(plan)
	items = _lt_items(plan)
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
				expected = _lt_expected_offset(plan, out, key, :bottom, _LT_ORDER_BELOW_LABEL)
				anchored = _lt_anchored_at(plan, y, plan.areas[key].current[2][1], expected - _ROOM_GAP, -1.0)
				push!(out, _LtDecor("label:" * name, key, :bottom, px, _LT_ORDER_BELOW_LABEL, anchored, false,
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
	# The lines of a row share one height too (topo_response, optical_bars:
	# a cell with a legend above its plot area had its title and label
	# higher than its neighbour's): each line rises to the highest offset of
	# its row and its room grows by as much (within the row's room, unless
	# the raised line is the taller one).
	placed = Dict{Symbol, Tuple{Vector{Tuple{String, Bool, Float64}}, Float64, Float64}}()
	highest = Dict{Float64, Float64}()   # top edge => highest line offset there
	for (key, list) in lines
		edge = round(plan.areas[key].current[2][2]; digits = 6)
		entries = [(name, left, raise + lift[edge]) for (name, left, raise) in raised[key]]
		px = maximum(entry[3] + raise for (entry, (_, _, raise)) in zip(list, entries))
		px > 0 || continue
		expected = _lt_expected_offset(plan, out, key, :top, _LT_ORDER_LINE)
		placed[key] = (entries, px, expected)
		highest[edge] = max(get(highest, edge, -Inf), expected)
	end
	for key in keys(lines)
		haskey(placed, key) || continue
		entries, px, expected = placed[key]
		rise = highest[round(plan.areas[key].current[2][2]; digits = 6)] - expected
		if rise > 1e-9
			entries = [(name, left, raise + rise) for (name, left, raise) in entries]
			px += rise
		end
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

# Per-plan memo of what the providers ask about the figure again in the
# measure and the place phase (`_room_build` makes one plan per pass; the
# traces and legend boxes of the figure do not change while a plan is solved,
# the providers only collect updates): the cell legend assignment and the
# size of each legend box. Weak keys: an entry goes with its plan.
const _LT_PLAN_MEMO = WeakKeyDict{Any, Dict{Any, Any}}()
_lt_plan_memo(plan) = get!(() -> Dict{Any, Any}(), _LT_PLAN_MEMO, plan)

# The cell legend assignment of the figure of `plan` (`(order, ids)`, or
# `nothing` when it needs more legends than there are legend ids).
function _lt_legend_assignment(plan)
	# One memo for the figure's assignment: the plan's own (`_room_legend_assignment`).
	order, ids, _, _ = try
		_room_legend_assignment(plan)
	catch err
		err isa ArgumentError || rethrow()
		return nothing
	end
	return (order, ids)
end

# `_legend_box_size` of legend `id` of the plan's figure, once per plan; a
# horizontal legend wraps at the plan's plot width, which counts the axes'
# automargins (vm-01: estimated at the layout margins, a two-row legend was
# given one row of room and plotly.js pushed the margin while drawing).
_lt_box_size(plan, id::AbstractString) =
	get!(() -> _legend_box_size(plan.p, id; wrap = plan.Wp), _lt_plan_memo(plan), (:box_size, String(id)))

# Cell legends (per-subplot legends; a single figure's legend counts as the
# legend of its plot area) and the figure legends of a grid.
function _lt_legend_decorations!(out, plan, cells, single::Bool, boxes)
	p = plan.p
	cell_mode = any(t -> t isa GenericTrace && haskey(t.fields, :legend) && !_trace_is_figure_legend_entry(t), p.data)
	cell_ids = Tuple{String, Symbol}[]
	if cell_mode
		assignment = _lt_legend_assignment(plan)
		assignment === nothing && return out    # more cell legends than legend ids: nothing is placed
		order, ids = assignment
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
		if d === nothing
			# A cell legend of a grid that lists no entry yet (a heatmap's
			# cell) draws nothing and takes no room, but while it sits at a
			# corner inside its cell it keeps following that corner as the
			# cell moves (its colorbar's room): its first entries are given to
			# the best-position rule only while the box is where the default
			# placement puts it for the cell's domain (`_apply_subplot_legends!`,
			# seams-01). No room and no other role: a grid holds its pushed
			# margins whatever its legends list (layout-fuzz-01, Q27).
			single || _lt_empty_cell_legend!(out, plan, id, area, boxes)
			continue
		end
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
# up for annotations. Requested when something of ours sits at the top edge
# of the figure, and for a pinned title of several lines or with math.
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
	# So does the math title of a colorbar (threed-f02; requested earlier).
	at_top = at_top || any(r -> r.side === :top && r.area !== :figure &&
		plan.areas[r.area].current[2][2] >= highest - _LT_EDGE_TOL, plan.requests)
	# A pinned title of several lines or with math is always given its band
	# (tm-title-top-clip): plotly.js must not push the margin for it, the
	# first line is placed for that (`_lt_title_pin`).
	pin = _lt_title_pin(plan, d)
	at_top || (pin !== nothing && (pin.shift > 0 || pin.recorded)) || return out
	pad = _symbol_dict(get(d, :pad, nothing))
	pad_b = something(_legend_real(get(pad, :b, nothing)), 0.0)
	band = if pin === nothing
		_text_title_band(p) + pad_b
	else
		# The text starts about where a one-line title's does (`pin.pad` less
		# the shift); plotly.js measures the band from `pin.pad`, so the
		# margin (the band, `_ROOM_GAP` and, for a positive margin,
		# `_FIN_AUTOMARGIN_EXTRA`, `_room_grow_margins`) must hold the shift
		# too, or plotly.js pushes it while drawing. A MathJax title keeps
		# the whole shift: plotly.js measures its svg box, taller than the
		# estimate (measured: 33.5 px against 27.7 px for a two-line math
		# title under :ieee, which the gap and extra alone did not cover).
		math = occursin(r"\$[^$]*\$", string(get(d, :text, "")))
		slack = math ? 0.0 :
			_ROOM_GAP + (_fin_isfinite_real(plan.margins.t) && plan.margins.t > 0 ? _FIN_AUTOMARGIN_EXTRA : 0.0)
		pin.pad - pin.shift + _text_extent(d[:text], _legend_title_font_size(p, d))[2] + _TEXT_PANEL_GAP + pad_b +
			max(pin.shift - slack, 0.0)
	end
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
# a narrow cell) and the title line has room beside the corner for it: up to
# `band` (px from the left of the plot width: the figure edges by default,
# else `_lt_title_band`, half way to the neighbouring cell on that line).
# Beside a centred title wider than the span, the label clears the title's
# end.
function _lt_label_xplacement(plan, label, title, left::Bool, span;
		band::Tuple{Float64, Float64} = (-Float64(plan.margins.l), plan.Wp + Float64(plan.margins.r)))
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
	room = left ? lo - band[1] : band[2] - hi
	room >= lw + _TEXT_PANEL_GAP + over || return corner
	return (beside[1], left ? beside[2] - over : beside[2] + over)
end

# ── Panel titles wider than their room (layout-fuzz-07) ─────────────────────
#
# A panel title (`title!(…; row, col)`, `subplot_titles`) is drawn on its
# cell's title line, between the cell's neighbours on that line and the
# figure edges, clear of the outside panel labels at the cell's top corners.
# One wider than that is broken between words when the figure is finalized
# (as an axis title longer than the figure, `_fin_wrap_axis_titles!`); the
# line's room grows with its lines. Which breaks are ours is recorded in
# `layout.meta` (`_LT_WRAP_RECORD_KEY`: annotation name => [title as
# written, title as wrapped]): every plan starts from the title as written
# while the annotation still shows our wrap, so a title that fits again (a
# larger export) is joined again, and a title the user changed is theirs.
# Math titles (`$…$`) and titles with markup other than `<b>`, `<i>` and line
# breaks are left as written.
const _LT_WRAP_RECORD_KEY = Symbol("plotlysupply:title_wrap")
const _LT_WRAP_MARKUP = r"<(?!/?(?:b|i)>|br\s*/?>)"i

# The wrap record of `layout`: annotation name => (as written, as wrapped).
function _lt_wrap_record(layout::Layout)
	raw = _fin_meta_get(layout, _LT_WRAP_RECORD_KEY)
	out = Dict{String, Tuple{String, String}}()
	(raw isa AbstractDict || raw isa PlotlyBase.PlotlyAttribute) || return out
	for (k, v) in (raw isa PlotlyBase.PlotlyAttribute ? raw.fields : raw)
		(v isa AbstractVector && length(v) == 2 && all(x -> x isa AbstractString, v)) || continue
		out[String(k)] = (String(v[1]), String(v[2]))
	end
	return out
end

# The annotations the providers read: the plan's (with the updates of this
# pass: wrapped titles) once it has its own, else the layout's.
_lt_items(plan) = plan.annotations === nothing ? get(plan.layout.fields, :annotations, nothing) : plan.annotations

# The grid row of each cell of `cells` (`_lt_cell_areas`; a cell spanning
# rows: its top row): the cells of a row share a title line, an
# equal-aspect cell fitted lower than its row too (its title is drawn lower,
# reaching the line of its neighbours' titles).
function _lt_cell_rows(cells)
	rows = Dict{Symbol, Int}()
	for ((r, _), key) in cells
		rows[key] = min(get(rows, key, r), r)
	end
	return rows
end

# Px span (from the left of the plot width `plan.Wp`) the title line of area
# `key` may use: from half way to the nearest grid cell on its left on the
# same title line (`_lt_cell_rows`; the figure's left edge when there is
# none) to half way to the nearest one on its right (the figure's right
# edge). `cells` as `_lt_cell_areas`.
function _lt_title_band(plan, key::Symbol, cells = _lt_cell_areas(plan))
	(lo, hi), _ = plan.areas[key].current
	rows = _lt_cell_rows(cells)
	row = get(rows, key, 0)
	left, right = -Float64(plan.margins.l), plan.Wp + Float64(plan.margins.r)
	for other in values(cells)
		other === key && continue
		(olo, ohi), _ = plan.areas[other].current
		rows[other] == row || continue
		ohi <= lo + _LT_EDGE_TOL && (left = max(left, (ohi + lo) / 2 * plan.Wp))
		olo >= hi - _LT_EDGE_TOL && (right = min(right, (olo + hi) / 2 * plan.Wp))
	end
	return (left, right)
end

# Width (px) of the widest box a panel title anchored at `xanchor` (+
# `xshift` px) on the span `span` (paper) may have on its line: within
# `band` (`_lt_title_wrap_band`), and clear of the outside top labels at the
# corners (`labels`: (left, width px) each) wherever they go
# (`_lt_label_xplacement`, within `label_band`, `_lt_title_band`): beside the
# corner when that band has room for them there, else at the corner. A
# title aligned to a corner pushes the label of that corner beside it, so
# that side does not limit it.
function _lt_title_room(plan, xanchor::AbstractString, xshift::Float64, span, band, labels; label_band = band)
	lo, hi = span[1] * plan.Wp, span[2] * plan.Wp
	low, high = band
	for (left, lw) in labels
		if left && xanchor != "left"
			low = lo - label_band[1] >= lw + _TEXT_PANEL_GAP ? label_band[1] + lw + _TEXT_PANEL_GAP : lo + lw + _TEXT_PANEL_GAP
		elseif !left && xanchor != "right"
			high = label_band[2] - hi >= lw + _TEXT_PANEL_GAP ? label_band[2] - lw - _TEXT_PANEL_GAP : hi - lw - _TEXT_PANEL_GAP
		end
	end
	anchor = _lt_anchor_x(xanchor, (lo, hi)) + xshift
	xanchor == "left" && return high - anchor
	xanchor == "right" && return anchor - low
	return 2 * min(anchor - low, high - anchor)
end

# `words` filled greedily into lines at most `width` px wide (`measure`); a
# longer word keeps a line of its own.
function _lt_fill_lines(words, measure, width::Float64)
	lines = String[]
	current = ""
	for word in words
		candidate = isempty(current) ? String(word) : current * " " * word
		if isempty(current) || measure(candidate) <= width
			current = candidate
		else
			push!(lines, current)
			current = String(word)
		end
	end
	isempty(current) || push!(lines, current)
	return lines
end

# `text` (no math, markup as `_LT_WRAP_MARKUP` allows) with every line (the
# user's breaks kept as written) broken between words into lines whose
# width at `font` px in `family` (`_text_drawn_extent`; `bold`: as bold, the
# wider) is at most `width` px; a longer word keeps a line of its own. The lines are balanced: as few as
# filling them greedily gives, each as short as that count allows (the
# narrowest fill width with that count, to `_LT_WRAP_BALANCE_PX`), so a
# title does not end in one short word ("A rather long panel" / "title for
# a cell", not "A rather long panel title for a" / "cell").
const _LT_WRAP_BALANCE_PX = 0.5
function _lt_wrap_title_text(text::AbstractString, font::Float64, width::Float64, bold::Bool;
	family::Union{Nothing, AbstractString} = nothing)
	measure(line) = _text_drawn_extent(line, font; family = family, bold = bold)[1]
	out = IOBuffer()
	start = 1
	wrap(line) = begin
		measure(line) <= width && return String(line)
		words = split(line, ' '; keepempty = false)
		lines = _lt_fill_lines(words, measure, width)
		length(lines) <= 1 && return join(lines, _FIN_WRAP_BREAK)
		# The widest word fills a line at any width; below it the count
		# cannot drop. Bisect the narrowest width keeping the greedy count.
		lo = maximum(measure, words)
		hi = width
		count = length(lines)
		while hi - lo > _LT_WRAP_BALANCE_PX
			mid = (lo + hi) / 2
			trial = _lt_fill_lines(words, measure, mid)
			length(trial) <= count ? (hi = mid; lines = trial) : (lo = mid)
		end
		return join(lines, _FIN_WRAP_BREAK)
	end
	for m in eachmatch(_FIN_LINE_BREAK, text)
		print(out, wrap(SubString(text, start, prevind(text, m.offset))), m.match)
		start = m.offset + ncodeunits(m.match)
	end
	print(out, wrap(SubString(text, start)))
	return String(take!(out))
end

# The x span (paper) a panel title of area `a` is placed on: its plot box
# (an equal-aspect cell's as fitted, `_lt_fitted_box`).
_lt_title_span(plan, a) = a.aspect ? _lt_fitted_box(plan, a)[1] : a.current[1]

# The CSS family list annotation `item` is drawn in: its own, else the
# figure's (`layout.font.family`), else the style's in scope.
function _lt_item_family(plan, item)
	for font in (_cmn_mapping_get(item, :font), get(plan.layout.fields, :font, nothing))
		family = font === nothing ? nothing : _cmn_mapping_get(font, :family)
		(family isa AbstractString && !isempty(strip(family))) && return String(family)
	end
	return _text_scope_family()
end

# Breaks every panel title of the plan wider than its room
# (`_lt_title_room`; the title measured in the family it is drawn in as far
# as the tables tell, `_text_drawn_extent`: a conservative width would break
# titles that fit) into lines, or joins one we broke that fits again, in
# the plan's annotations (measured by the requests and placed by the place
# phase of this plan). Once per plan; returns the wrap record as read and as
# it is now (written to `layout.meta` by the place phase).
function _lt_wrap_panel_titles!(plan)
	memo = _lt_plan_memo(plan)
	cached = get(memo, :title_wrap, nothing)
	cached === nothing || return cached
	record = _lt_wrap_record(plan.layout)
	result = (record, Dict{String, Tuple{String, String}}())
	memo[:title_wrap] = result
	items = _lt_items(plan)
	items isa AbstractVector || return result
	cells = _lt_cell_areas(plan)
	single = plan.layout.subplots.rows * plan.layout.subplots.cols == 1
	titles = Tuple{String, Any, Symbol}[]
	labels = Dict{Symbol, Vector{Tuple{Bool, Float64}}}()
	for item in items
		name = _cmn_item_name(item)
		name isa AbstractString || continue
		m = match(_LT_TITLE_NAME, name)
		kind = m === nothing ? :label : :title
		m === nothing && (m = match(_LT_LABEL_NAME, name))
		m === nothing && continue
		key = get(cells, (parse(Int, m.captures[1]), parse(Int, m.captures[2])), nothing)
		key === nothing && continue
		if kind === :title
			push!(titles, (String(name), item, key))
		else
			role = _lt_annotation_role(item, :label, _lt_ref_boxes(plan, plan.areas[key], single))
			(role !== nothing && role.role === :line) || continue
			push!(get!(Vector{Tuple{Bool, Float64}}, labels, key), (role.left, _lt_annotation_width(plan, item)))
		end
	end
	# The titles as written (`plain`; `text`: as the annotation shows it),
	# measured in the family they are drawn in: `box` (left, right) px and
	# width `w` of the box as written; `breakable`: plain text on the title
	# line, ours to break.
	written = NamedTuple[]
	for (name, item, key) in titles
		text = _cmn_mapping_get(item, :text)
		text isa AbstractString || continue
		rec = get(record, name, nothing)
		plain = rec !== nothing && text == rec[2] ? rec[1] : String(text)
		role = _lt_annotation_role(item, :title, _lt_ref_boxes(plan, plan.areas[key], single))
		breakable = role !== nothing && !occursin('$', plain) && !occursin(_LT_WRAP_MARKUP, plain)
		font = _lt_font(plan, item)
		family = _lt_item_family(plan, item)
		xanchor = something(_fin_string(_cmn_mapping_get(item, :xanchor)), "auto")
		xshift = something(_lt_real(_cmn_mapping_get(item, :xshift, 0)), 0.0)
		bold = occursin(r"<b>"i, plain)
		(lo, hi) = _lt_title_span(plan, plan.areas[key])
		anchor = _lt_anchor_x(xanchor, (lo * plan.Wp, hi * plan.Wp)) + xshift
		w = _text_drawn_extent(plain, font; family = family, bold = bold)[1] + _TEXT_ANNOTATION_FRAME
		box = xanchor == "left" ? (anchor, anchor + w) : xanchor == "right" ? (anchor - w, anchor) : (anchor - w / 2, anchor + w / 2)
		push!(written, (; name, item, key, text, plain, breakable, font, family, xanchor, xshift, bold, box, w))
	end
	boxes = Dict(t.key => t.box for t in written)
	for t in written
		wrapped = t.plain
		if t.breakable
			band = _lt_title_wrap_band(plan, t.key, cells, boxes, labels)
			room = _lt_title_room(plan, t.xanchor, t.xshift, _lt_title_span(plan, plan.areas[t.key]), band, get(labels, t.key, ());
				label_band = _lt_title_band(plan, t.key, cells))
			if t.w > room + 1e-9
				wrapped = _lt_wrap_title_text(t.plain, t.font, room - _TEXT_ANNOTATION_FRAME, t.bold; family = t.family)
			end
		end
		wrapped == t.plain || (result[2][t.name] = (t.plain, wrapped))
		wrapped == t.text || _lt_update_annotation!(plan, t.name, Dict{Symbol, Any}(:text => wrapped))
	end
	return result
end

# The px span (as `_lt_title_band`) a panel title of area `key` may be
# broken to fit: `_lt_title_band`, widened on a side with a neighbouring cell
# on the title line whose own title and outside top label stay in their half
# of the gap between the two cells: up to that title's box as written
# (`boxes`: area => (left, right) px, `_lt_wrap_panel_titles!`), that label
# (`labels`, as `_lt_wrap_panel_titles!`; taken beside its corner, as
# `_lt_label_xplacement` places it) and the neighbour's plot span less
# `_TEXT_PANEL_GAP` (the boxes may touch: each holds plotly's frame around
# its text, `_TEXT_ANNOTATION_FRAME`). A title as wide as its cell
# reaching into an empty gap stays whole (recreate_topo_phase; the room the
# solve gives the title line keeps it clear of the neighbour's top y tick
# label); a neighbour reaching past half way is broken to its half itself,
# which bounds it.
function _lt_title_wrap_band(plan, key::Symbol, cells, boxes, labels)
	left, right = _lt_title_band(plan, key, cells)
	(lo, hi), _ = plan.areas[key].current
	rows = _lt_cell_rows(cells)
	row = get(rows, key, 0)
	for other in values(cells)
		other === key && continue
		(olo, ohi), _ = plan.areas[other].current
		rows[other] == row || continue
		box = get(boxes, other, nothing)
		ospan = _lt_title_span(plan, plan.areas[other])
		if olo >= hi - _LT_EDGE_TOL
			# on the right: up to its leftmost drawn box, at most its plot
			# span less the gap
			half = (olo + hi) / 2 * plan.Wp
			limit = ospan[1] * plan.Wp - _TEXT_PANEL_GAP
			box === nothing || (limit = min(limit, box[1]))
			for (l, lw) in get(labels, other, ())
				l && (limit = min(limit, ospan[1] * plan.Wp - _TEXT_PANEL_GAP - lw))
			end
			limit > half && right == half && (right = limit)
		elseif ohi <= lo + _LT_EDGE_TOL
			half = (ohi + lo) / 2 * plan.Wp
			limit = ospan[2] * plan.Wp + _TEXT_PANEL_GAP
			box === nothing || (limit = max(limit, box[2]))
			for (l, lw) in get(labels, other, ())
				l || (limit = max(limit, ospan[2] * plan.Wp + _TEXT_PANEL_GAP + lw))
			end
			limit < half && left == half && (left = limit)
		end
	end
	return (left, right)
end

# Writes the wrap record of `_lt_wrap_panel_titles!` to `layout.meta` when it
# changed (place phase). Returns whether it wrote.
function _lt_write_wrap_record!(plan)
	record, now = _lt_wrap_panel_titles!(plan)
	now == record && return false
	value = isempty(now) ? nothing : Dict{Any, Any}(Symbol(k) => Any[v[1], v[2]] for (k, v) in now)
	return _fin_meta_set!(plan.layout, _LT_WRAP_RECORD_KEY, value)
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
	size = _lt_box_size(plan, id)
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
			xanchor, xshift = _lt_label_xplacement(plan, item, title, left, span; band = _lt_title_band(plan, key))
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
	single = plan.layout.subplots.rows * plan.layout.subplots.cols == 1
	decorations = _lt_decorations(plan)
	items = _lt_items(plan)
	_lt_write_wrap_record!(plan) && (plan.wrote = true)
	cells = _lt_cell_areas(plan)
	# A grid holds them always: its cells' legends come and go with their
	# entries, and a hold that followed them gave a grid of fields without
	# entries its margins on some passes only (layout-fuzz-01), and a 6 x 6
	# grid of heatmaps a quarter more allocations per finalize (Q27). Read
	# from the layout's grid, not the SubplotFigure: the export copy of a
	# grid (a Plot) must find it settled as the figure did.
	(!single || any(d -> d.role in (:inside_legend, :cell_legend, :figure_legend), decorations)) &&
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
					xanchor, xshift = _lt_label_xplacement(plan, item, title, left, fx;
						band = _lt_title_band(plan, d.area, cells))
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
			_lt_follow_rule!(plan, d) && continue
			_lt_place_cell_legend!(plan, d, slot)
		elseif d.role === :inside_legend
			_lt_follow_rule!(plan, d) && continue
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
		# Kept by `_room_settle_margins!` (margin-01).
		_room_note_margin!(plan, letter, px)
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
# The `pad.t` of a pinned title includes `_lt_title_shift`.
function _lt_pin_title!(plan)
	d = _text_title_dict(plan.p)
	d === nothing && return nothing
	pin = _lt_title_pin(plan, d)
	pin === nothing && return nothing
	_room_relayout!(plan, :title_y, 1)
	_room_relayout!(plan, :title_yanchor, "top")
	_room_relayout!(plan, :title_pad_t, pin.pad)
	if pin.shift > 0 || pin.recorded
		meta = _lt_meta_with_title_shift(plan.layout, [pin.pad, pin.shift])
		meta === nothing || _room_relayout!(plan, :meta, meta)
	end
	return nothing
end

# A copy of `layout.meta` with `plotlysupply.titleshift = value`; `nothing`
# when the meta is not a mapping the record can live in.
function _lt_meta_with_title_shift(layout, value)
	meta = get(layout.fields, :meta, nothing)
	(meta === nothing || meta isa AbstractDict || meta isa PlotlyBase.PlotlyAttribute) || return nothing
	fields = _symbol_dict(meta)
	own = _symbol_dict(_style_meta_get(fields, _STYLE_META_KEY))
	own[_LT_TITLE_SHIFT_META_KEY] = value
	fields[_STYLE_META_KEY] = own
	return fields
end

# tm-title-top-clip: plotly.js 2.35.2 draws a container-anchored title with
# `yanchor = "top"` and its `pad.t` below the top of the figure, but the
# first line of a title of several lines (`<br>`) with its baseline on that
# anchor (a one-line title sits 0.7 em, plotly's CAP_SHIFT, lower), and a
# MathJax title centred about 1/4 em above it; when its `automargin` pushes
# the top margin it moves every line of a multi-line title up by a further
# (1.3 n + 0.35) em (n line breaks). Measured: the first line of
# "Two-line\nfigure title" 7 px above the figure (17 px font), 17 px under
# :ieee; a fraction 5 px above it. A pinned title of several lines or with
# math therefore gets its band from the room providers (the margin holds it,
# plotly.js does not push) and `pad.t` grows by this shift (px), which puts
# its top where a one-line plain title's is (about 0.3 em above the pad);
# the text height estimate errs large, so a MathJax title lands lower.
function _lt_title_shift(p::Plot, d)
	text = string(get(d, :text, ""))
	size = _legend_title_font_size(p, d)
	occursin(r"\$[^$]*\$", text) && return max(_text_extent(text, size)[2] / 2 - 0.05 * size, 0.0)
	occursin(r"<br\s*/?>"i, text) && return 0.7 * size
	return 0.0
end

# Key (in `layout.meta.plotlysupply`; one word: it is a `relayout!` path
# part) of the `[pad.t, shift]` the last pin wrote.
const _LT_TITLE_SHIFT_META_KEY = :titleshift

# The pin of figure title `d`: `pad` (px, its `pad.t`: the user's pad, else
# `_TEXT_TITLE_TOP_PAD`, plus `shift`, `_lt_title_shift`) and whether a shift
# was recorded; `nothing` for a title the user placed (another `y` than "auto"
# or 1, another anchor or reference). The user's pad is the `pad.t` less the
# recorded shift while `pad.t` is still the value the pin wrote.
function _lt_title_pin(plan, d)
	y = get(d, :y, "auto")
	auto = y === nothing || y == "auto"
	if !auto
		(_legend_real(y) == 1 && get(d, :yanchor, nothing) == "top" &&
			get(d, :yref, "container") == "container") || return nothing
	end
	pad = _legend_real(get(_symbol_dict(get(d, :pad, nothing)), :t, nothing))
	base = something(pad, Float64(_TEXT_TITLE_TOP_PAD))
	own = _style_meta_get(get(plan.layout.fields, :meta, nothing), _STYLE_META_KEY)
	record = _style_meta_get(own, _LT_TITLE_SHIFT_META_KEY)
	recorded = record isa AbstractVector && length(record) == 2 && all(v -> v isa Real, record)
	recorded && pad !== nothing && abs(pad - record[1]) <= 1e-6 && (base = pad - Float64(record[2]))
	shift = round(_lt_title_shift(plan.p, d); digits = 3)
	return (pad = round(base + shift; digits = 3), shift = shift, recorded = recorded)
end

# A cell legend of a grid that the best-position rule placed (and the user
# did not place since, `_legend_cell_auto_ids`) and that sits at a position of
# the rule follows its cell's data: when a call changed the data without an
# append (`xrange!`, a style, the figure size) and the rule now gives another
# position, the legend is written there (anchors, orientation and its corner
# of the plot box) and `true` is returned; the next pass of the fit gives it
# its room. `false`: placed as it is.
#
# The rule scores the plot area the solve gives the cell without the
# legend's own room (a legend outside took that room from its cell; scored on
# the narrower area every inside position would stay covered once the data
# made room): the same area whether the legend is inside or outside (a
# neighbour's room on the same edge stays), so the answer does not flip
# between passes and a second finalize writes nothing.
function _lt_follow_rule!(plan, d::_LtDecor)
	plan.layout.subplots.rows * plan.layout.subplots.cols == 1 && return false
	auto = _legend_cell_auto_ids(plan.p)
	(auto === nothing || !(d.id in auto)) && return false
	current = if d.role === :inside_legend
		d.data
	else
		role = d.data
		(role.legacy || !role.canonical) && return false
		role.side === :bottom ? :outside_bottom : role.side === :right ? :outside_right : return false
	end
	box = _lt_final_box(plan.areas[d.area])
	# Scored on the plot area and plot px the figure has without the room of
	# any legend the rule places (each its own and the others'): where one
	# goes then does not depend on where it or another one is now
	# (docs-truth-16: the margin a legend raised beside the right column
	# narrowed the cell it was scored on, and it went below the cell and
	# back; vm-gridleg: three cell legends moved each other's cells). Every
	# candidate is scored at the inset it is drawn at.
	rule_keys = Set("legend:" * id for id in auto)
	xdom, ydom = _lt_box_without_room(plan, d; keys = rule_keys)
	px = _room_plot_px_without(plan, _LT_OWNER, rule_keys)
	best = _legend_best_cell_position(plan.p, d.id, xdom, ydom; plot_px = px,
		current = current in _SCAT_LEGEND_OUTSIDE_POSITIONS ? current : nothing,
		inset = _lt_legend_inset(plan))
	best === nothing && return false
	# Placed on the final box; a column below the cell when the row is wider
	# than the plot area the rule scored.
	want = _legend_placement(best, box[1], box[2], _lt_legend_inset(plan); figure = false)
	best === :outside_bottom &&
		(want[:orientation] = get(_legend_rule_placement(plan.p, d.id, best, xdom, ydom, (0.0, 0.0); plot_px = px),
			:orientation, "h"))
	if best === current
		# Below the cell already: only its orientation may follow. It is
		# still placed at its slot by the caller (layout-fuzz-11: placed on
		# no pass where it turned into a column while its cell narrowed, it
		# stayed centred under the old domain, which no longer took it for
		# ours, and `figsize!` left it in the cell below).
		best === :outside_bottom || return false
		now = something(_room_current(plan.layout, Symbol(d.id, :_orientation)), "v")
		now == want[:orientation] || _room_relayout!(plan, Symbol(d.id, :_orientation), want[:orientation])
		return false
	end
	_room_relayout!(plan, Symbol(d.id, :_x), round(Float64(want[:x]); digits = 6))
	_room_relayout!(plan, Symbol(d.id, :_y), round(Float64(want[:y]); digits = 6))
	_room_relayout!(plan, Symbol(d.id, :_xanchor), want[:xanchor])
	_room_relayout!(plan, Symbol(d.id, :_yanchor), want[:yanchor])
	# An inside box is vertical (the rule scores it so): "v" is written over
	# an outside row's "h" (`_legend_placement_matches` takes it as left out).
	orientation = get(want, :orientation, nothing)
	if orientation !== nothing
		_room_relayout!(plan, Symbol(d.id, :_orientation), orientation)
	elseif _room_current(plan.layout, Symbol(d.id, :_orientation)) == "h"
		_room_relayout!(plan, Symbol(d.id, :_orientation), "v")
	end
	return true
end

# The final box of the plot area of decoration `d` as the solve gives it
# without the room `d` requested (the requests of everything else kept), or
# without the room of every request of this provider keyed in `keys`. The
# solve is run again on the plan with `d`'s request left out; the plan's
# requests and every area's room, writable sides and final box are restored.
function _lt_box_without_room(plan, d::_LtDecor; keys = nothing)
	requests = plan.requests
	saved = Dict(key => (copy(a.room), copy(a.writable), a.final) for (key, a) in plan.areas)
	drop = keys === nothing ? (d.key,) : keys
	plan.requests = filter(r -> !(r.owner === _LT_OWNER && r.key in drop), requests)
	try
		_room_solve!(plan)
		return _lt_final_box(plan.areas[d.area])
	finally
		plan.requests = requests
		for (key, (room, writable, final)) in saved
			a = plan.areas[key]
			a.room = room
			a.writable = writable
			a.final = final
		end
	end
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
