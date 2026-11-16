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

"""
	_legend_options(who; position, inset, bgcolor, bordercolor, borderwidth, showlegend, xanchor, yanchor, orientation, ncols, title, fontsize, frame, dedupe, itemwidth, entrywidth, legend_target)

Validate the keywords of `set_legend!` / `subplot_legends!` before anything is
written and return them normalized as a NamedTuple (`position` is `nothing`,
a normalized Symbol or a `Float64` tuple; colours are `String`s; `inset` is a
`Float64` tuple with `inset_given` telling whether the caller chose it;
`title` is already passed through `_label`). Throws `ArgumentError("<who>: …")`.
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
		"$(who): pass either `ncols` (entry width as a fraction of the legend) " *
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
	title_label = isempty(title) ? "" : _label(title)
	return (
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
	_legend_layout_ext(opts)::Dict{Symbol,Any}

Legend fields of the F15/A3 keywords (validated by `_legend_options`):
`orientation` (explicit, or "h" when `ncols > 0`), `entrywidth` +
`entrywidthmode` (`1/ncols` "fraction", or px "pixels"), `itemwidth`,
`title.text` and `font.size`. Keywords left at their sentinel produce no
field, so the current value is kept. Nested values are Dicts that
`_legend_apply_ext!` merges into the existing `title`/`font`.
"""
function _legend_layout_ext(opts)
	ext = Dict{Symbol, Any}()
	if opts.orientation !== nothing
		ext[:orientation] = opts.orientation
	elseif opts.ncols > 0
		ext[:orientation] = "h"
	end
	if opts.ncols > 0
		ext[:entrywidth] = 1 / opts.ncols
		ext[:entrywidthmode] = "fraction"
	elseif opts.entrywidth > 0
		ext[:entrywidth] = _text_number(opts.entrywidth)
		ext[:entrywidthmode] = "pixels"
	end
	opts.itemwidth > 0 && (ext[:itemwidth] = _text_number(opts.itemwidth))
	isempty(opts.title) || (ext[:title] = Dict{Symbol, Any}(:text => opts.title))
	opts.fontsize > 0 && (ext[:font] = Dict{Symbol, Any}(:size => _text_number(opts.fontsize)))
	return ext
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

function _text_label(text::AbstractString, align::Symbol, bold::Bool)
	label = _label(text; align = _text_mathtext_align(align))
	return bold ? _text_bold(label) : label
end

function _text_figure_title!(fig, text, align::Symbol, fontsize::Float64, bold::Bool, offset)
	dx, dy = offset
	updates = Dict{Symbol, Any}()
	if isempty(text)
		updates[:title_text] = ""
	else
		updates[:title_text] = _text_label(text, align, bold)
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
		return nothing
	end
	xdom = target.xdomain
	ydom = target.ydomain
	x = align === :left ? xdom[1] : align === :right ? xdom[2] : (xdom[1] + xdom[2]) / 2
	annotation = Dict{Symbol, Any}(
		:name => name,
		:text => _text_label(text, align, bold),
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
	return nothing
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
  Existing title styling (font family/colour) is kept.
- Panel title: an annotation named `"plotlysupply:title:<row>:<col>"` placed
  just above the cell's axes (`x` = left edge / centre / right edge of the cell
  per `align`, `yanchor="bottom"`, 4 px gap). Calling it again replaces it; it
  also replaces a centred `subplot_titles`/`column_titles` annotation of that
  cell. [`set_fonts!`](@ref) styles it as a title.

`text` goes through mathtext (`"(a) Mesh study, \$\\lambda=10^8\$"` keeps its
text); `""` removes the title.

# Keywords
- `row`, `col` (`Integer`, both or neither): the panel (SubplotFigure only).
- `align::Symbol = :center`: `:left`, `:center` or `:right`.
- `fontsize::Real = 0`: font size in px (0 = unchanged / Plotly default).
- `bold::Bool = false`: plain text is wrapped in `<b>…</b>`; for labels with
  math, the text runs become `\\textbf{…}` (HTML tags cannot wrap math) and the
  math itself is unchanged.
- `offset::Tuple{Real,Real} = (0, 0)`: `(dx, dy)` shift in px, right and up.
  A centred figure title cannot be shifted horizontally (Plotly ignores the
  padding of centred titles): use `align=:left`/`:right` for a `dx`.

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
	offset::Union{Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = (0, 0),
	show = nothing,
)
	_text_reject_show(show, "title!")
	a, fs, off = _text_title_args(align, fontsize, offset)
	(row === nothing && col === nothing) || _cell_target(fig; row = row, col = col, who = "title!")
	a === :center && off[1] != 0 && !isempty(text) && throw(ArgumentError(
		"title!: a centred figure title cannot be shifted horizontally (Plotly " *
		"ignores the padding of centred titles); use `align=:left` or `:right` " *
		"with `offset`.",
	))
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
		a === :center && off[1] != 0 && !isempty(text) && throw(ArgumentError(
			"title!: a centred figure title cannot be shifted horizontally (Plotly " *
			"ignores the padding of centred titles); use `align=:left` or `:right` " *
			"with `offset`.",
		))
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
	offset::Union{Tuple{<:Real, <:Real}, AbstractVector{<:Real}} = (0, 0),
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

function _text_panel_label_annotation(target, text, position::Symbol, outside::Bool, fontsize::Float64, bold::Bool, row::Int, col::Int)
	left = position in (:topleft, :bottomleft)
	top = position in (:topleft, :topright)
	xdom = target.xdomain
	ydom = target.ydomain
	annotation = Dict{Symbol, Any}(
		:name => "plotlysupply:panel_label:$(row):$(col)",
		:text => _text_label(text, left ? :left : :right, bold),
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
			_text_panel_label_annotation(target, text, position, outside, fs, bold, row, col),
		))
	end
	for (name, annotation) in items
		_upsert_named!(fig, :annotations, name, [annotation]; who = "panel_labels!")
	end
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
  4 px from both edges.
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

function _text_proxy(label, who; mode, color, dash, linewidth, marker_symbol, marker_size, marker_color, marker_line_color, marker_line_width, patch, legendgroup, opacity)
	return _proxy_trace(
		label;
		mode = mode,
		color = color,
		dash = dash,
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
- `mode::AbstractString = "lines"`: `"lines"`, `"markers"` or `"lines+markers"`.
- `color` (string or Symbol): line colour; also the marker colour when
  `marker_color` is not given.
- `dash::AbstractString`, `linewidth::Real`: line style (`""`/0 = Plotly default).
- `marker_symbol`: Plotly name or matplotlib code (`"o"`, `"s"`, `"^"`, `"x"`, …).
- `marker_size::Real`, `marker_line_width::Real`: px (0 = default).
- `marker_color`: face colour; `"none"` draws a hollow marker.
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

`label` goes through mathtext; `" "` gives a blank spacer entry.

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
	mode::AbstractString = "lines",
	color::Union{AbstractString, Symbol} = "",
	dash::AbstractString = "",
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
	mode::AbstractString = "lines",
	color::Union{AbstractString, Symbol} = "",
	dash::AbstractString = "",
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
