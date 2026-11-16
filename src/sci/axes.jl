# PlotlySupply 2.0 scientific-plotting extensions: xticks!/yticks!, axis_equal!, axis_off!, spines!, grid!, secondary_xaxis!, inset!, zlabel!/zrange!, and the shared machinery of xlabel!/ylabel!/xrange!/yrange! (whose public methods live in api.jl).
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_AXES_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# Every helper resolves its target with `_cell_target` (common.jl): a plain
# figure, the active or `row`/`col` cell of a SubplotFigure, or inset `k`
# (`inset=k`). The untyped method serves `Plot`/`SyncPlot` (through the
# generated transactional wrapper) and returns `nothing`; the explicit
# `SubplotFigure` method runs one `_transactional_subplot_mutation!`, makes the
# target cell (an inset's host cell) the active cell, and returns `sf`.
# Inputs are validated before the first write.

const _SCI_AXES_MUTATORS = (
	:xlabel!,
	:ylabel!,
	:zlabel!,
	:xrange!,
	:yrange!,
	:zrange!,
	:xticks!,
	:yticks!,
	:axis_equal!,
	:axis_off!,
	:spines!,
	:grid!,
	:secondary_xaxis!,
)

export zlabel!, zrange!, xticks!, yticks!, axis_equal!, axis_off!, spines!, grid!
export secondary_xaxis!, inset!

# ---------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------

# `show` belongs to the constructors; a helper that accepted it silently would
# suggest it opens a window.
function _axes_reject_show(show, who::AbstractString)
	show === nothing || throw(ArgumentError(
		"$(who): figure helpers have no `show` keyword; display the figure " *
		"with `display(fig)`, or create it with `show=true`.",
	))
	return nothing
end

# A SubplotFigure helper makes its target cell the active cell, as
# `xlabel!(sf; row, col)` always did. An inset selects its host cell.
_axes_select!(fig, t::_CellTarget) = nothing
function _axes_select!(sf::SubplotFigure, t::_CellTarget)
	sf.current_row = t.row
	sf.current_col = t.col
	return nothing
end

_axes_finish!(fig) = _refresh!(_cmn_relayout_target(fig))

function _axes_require_xy(t::_CellTarget, who::AbstractString, what::AbstractString)
	t.kind === :xy || throw(ArgumentError(
		"$(who): $(what) applies to Cartesian (xy) cells; this cell is " *
		":$(t.kind)" *
		(t.kind === :scene ? " (3-D scene axes are set with `scene!`)." : "."),
	))
	return nothing
end

# 3-D scene axis titles cannot typeset MathJax (ADDENDUM A8/B3). `_label3d`
# (scene3d.jl) converts the documented TeX subset to HTML/Unicode; until that
# file defines it, `_label_plain` keeps the text readable.
function _axes_label3d(s::AbstractString)
	if isdefined(@__MODULE__, :_label3d)
		return getfield(@__MODULE__, :_label3d)(s)
	end
	return _label_plain(s)
end

# Follow `matches` from axis `key` to the axis that owns the shared range.
# plotly.js takes the range of a matched group from that root axis, so a range
# written on a follower is ignored (finding #265).
function _axes_match_root(layout::Layout, key::Symbol, who::AbstractString)
	letter = String(key)[1]
	chain = Symbol[key]
	current = key
	while true
		ref = _cmn_mapping_get(get(layout.fields, current, nothing), :matches)
		ref isa Symbol && (ref = String(ref))
		(ref isa AbstractString && _cmn_axis_ref_index(ref, letter) !== nothing) ||
			return current
		next = _axis_layout_key(ref, Symbol(letter))
		next in chain && throw(ArgumentError(
			"$(who): the `matches` references of $(repr(key)) form a cycle " *
			"($(join(string.(vcat(chain, next)), " -> "))).",
		))
		push!(chain, next)
		current = next
	end
end

# Highest x/y axis index used by the layout or referenced by a trace.
function _axes_highest_axis_index(p::Plot, letter::Char)
	highest = 1
	for key in keys(p.layout.fields)
		index = _cmn_axis_index(key, letter)
		index === nothing || (highest = max(highest, index))
	end
	field = letter == 'x' ? :xaxis : :yaxis
	for trace in p.data
		trace isa GenericTrace || continue
		ref = get(trace.fields, field, nothing)
		index = _cmn_axis_ref_index(ref isa Symbol ? String(ref) : ref, letter)
		index === nothing || (highest = max(highest, index))
	end
	return highest
end

# Every xy cell of a SubplotFigure (top-left first), each axis pair once.
function _axes_xy_cells(sf::SubplotFigure, who::AbstractString)
	grid_ref = _cmn_layout(sf).subplots.grid_ref
	targets = _CellTarget[]
	seen = Set{Symbol}()
	for r in 1:getfield(sf, :rows), c in 1:getfield(sf, :cols)
		(
			checkbounds(Bool, grid_ref, r, c) &&
			isassigned(grid_ref, r, c) &&
			!isempty(grid_ref[r, c]) &&
			String(grid_ref[r, c][1].subplot_kind) == "xy"
		) || continue
		t = _cell_target(sf; row = r, col = c, who = who)
		t.xkey in seen && continue
		push!(seen, t.xkey)
		push!(targets, t)
	end
	isempty(targets) && throw(ArgumentError(
		"$(who): `cells=:all` found no Cartesian (xy) cell in this figure.",
	))
	return targets
end

# Targets of a styling helper: one cell, or every xy cell with `cells=:all`.
# The second value says whether the target cell becomes the active cell.
function _axes_styling_targets(fig, who::AbstractString; row, col, inset, cells)
	if cells === nothing
		t = _cell_target(fig; row = row, col = col, inset = inset, who = who)
		_axes_require_xy(t, who, who)
		return (_CellTarget[t], true)
	end
	cells === :all || throw(ArgumentError(
		"$(who): `cells` must be :all or `nothing`; got $(repr(cells)).",
	))
	(row === nothing && col === nothing && inset === nothing) ||
		throw(ArgumentError(
			"$(who): `cells=:all` styles every xy cell; do not combine it " *
			"with `row`/`col`/`inset`.",
		))
	if fig isa SubplotFigure
		return (_axes_xy_cells(fig, who), false)
	end
	t = _cell_target(fig; who = who)
	_axes_require_xy(t, who, who)
	return (_CellTarget[t], false)
end

_axes_is_unset_color(color) =
	color === nothing || (color isa AbstractString && isempty(color))

function _axes_check_size(value, name::AbstractString, who::AbstractString)
	(value isa Real && !(value isa Bool) && isfinite(value) && value >= 0) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a finite number >= 0 (0 leaves it " *
			"unchanged); got $(repr(value)).",
		))
	return nothing
end

# ---------------------------------------------------------------------------
# Axis titles (xlabel!/ylabel!/zlabel!)
# ---------------------------------------------------------------------------

# Same merge as the 1.x SubplotFigure `xlabel!`: nested title styling is
# kept and aliased layout containers are updated in place.
function _axes_write_axis_title!(fig, key::Symbol, text::String)
	p = _cmn_plot(fig)
	preserve_root = _preserve_layout_mapping_root(p, key)
	_merge_layout_attr!(
		p.layout,
		key,
		attr(title_text = text);
		deep_merge_paths = _AXIS_LAYOUT_MERGE_PATHS,
		mutate_builtin_target = preserve_root,
		allow_unsupported_replacement = true,
	)
	return nothing
end

function _axes_write_scene_axis!(fig, scenekey::Symbol, letter::Char, fields::AbstractDict{Symbol})
	_merge_scene_layout_attr!(
		_cmn_layout(fig),
		scenekey,
		attr(; (Symbol(letter, "axis") => attr(; fields...),)...),
	)
	return nothing
end

function _axes_scene_axis_entry(layout::Layout, scenekey::Symbol, letter::Char)
	scene = get(layout.fields, scenekey, nothing)
	return _cmn_mapping_get(scene, Symbol(letter, "axis"))
end

"""
	_axes_label!(fig_or_sf, letter, label; row, col, inset, secondary_y, who)

Write the title of axis `letter` ('x', 'y' or 'z') of the target cell: an xy
axis gets `title.text = _label(label)`, a 3-D scene axis
`scene.<letter>axis.title.text = _label3d(label)`. An empty `label` clears the
title. Other cell kinds (and 'z' on an xy cell) are an `ArgumentError`.
"""
function _axes_label!(
	fig,
	letter::Char,
	label::AbstractString;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
	who::AbstractString,
)
	t = _cell_target(
		fig;
		row = row,
		col = col,
		inset = inset,
		secondary_y = secondary_y,
		who = who,
	)
	if t.kind === :xy
		letter == 'z' && throw(ArgumentError(
			"$(who): a Cartesian (xy) cell has no z axis; `zlabel!` needs a " *
			"3-D scene cell.",
		))
		text = _label(label)
		_axes_write_axis_title!(fig, letter == 'x' ? t.xkey : t.ykey, text)
	elseif t.kind === :scene
		text = _axes_label3d(label)
		_axes_write_scene_axis!(
			fig,
			t.scenekey,
			letter,
			Dict{Symbol, Any}(:title => attr(text = text)),
		)
	else
		throw(ArgumentError(
			"$(who): axis titles apply to Cartesian (xy) and 3-D scene cells; " *
			"this cell is :$(t.kind).",
		))
	end
	_axes_select!(fig, t)
	_axes_finish!(fig)
	return nothing
end

# ---------------------------------------------------------------------------
# Axis ranges (xrange!/yrange!/zrange!)
# ---------------------------------------------------------------------------

# A validated range: `nothing` for the automatic sentinel ([0, 0], (0, 0),
# `nothing`, [nothing, nothing]), otherwise the two bounds. Partial ranges
# are rejected: plotly.js 2.35 ignored `range = [null, hi]` with
# `autorange = "min"` in a render test (probe2_partial.png).
function _axes_checked_range(range, who::AbstractString)
	if (range isa AbstractVector || range isa Tuple) &&
		length(range) == 2 &&
		all(b -> b === nothing, range)
		return nothing
	end
	checked = _checked_range(range, who, "range")
	checked === nothing && return nothing
	for bound in checked
		(bound === nothing || bound === missing) && throw(ArgumentError(
			"$(who): partial ranges are not supported; give both bounds, or " *
			"[0, 0] / `nothing` for an automatic range. Got $(repr(range)).",
		))
		bound isa Bool && throw(ArgumentError(
			"$(who): range bounds must be numbers (or date/category values); " *
			"got $(repr(range)).",
		))
	end
	lower, upper = checked
	(lower isa Real && upper isa Real && lower == upper) && throw(ArgumentError(
		"$(who): the range bounds must differ; got $(repr(range)) (use " *
		"[0, 0] or `nothing` for an automatic range).",
	))
	return checked
end

# Write an xy axis range (`nothing` = autorange). The same alias-preserving
# merge as the 1.x SubplotFigure `xrange!`.
function _axes_write_xy_range!(fig, key::Symbol, value)
	p = _cmn_plot(fig)
	preserve_root = _preserve_layout_mapping_root(p, key, ())
	source = value === nothing ?
		attr(autorange = true) :
		attr(range = value, autorange = false)
	_merge_layout_attr!(
		p.layout,
		key,
		source;
		mutate_builtin_target = preserve_root,
	)
	value === nothing && _cmn_delete_layout_fields!(fig, key, (:range,))
	return nothing
end

function _axes_log10_bound(bound, who::AbstractString)
	(bound isa Real && isfinite(bound) && bound > 0) || throw(ArgumentError(
		"$(who): $(repr(bound)) cannot be a bound of a logarithmic axis; " *
		"log-axis ranges are data values and must be positive.",
	))
	return log10(Float64(bound))
end

"""
	_axes_range!(fig_or_sf, letter, range; row, col, inset, secondary_y, who)

Set the range of axis `letter` of the target cell in DATA units (spec C13):
on a logarithmic axis the bounds are converted to the log10 values Plotly
stores. A full range also sets `autorange = false` (finding #25); the
automatic sentinel deletes the range and sets `autorange = true`. On an xy
cell whose axis `matches` another, the range is written on the root of the
matched group, the only axis plotly.js reads it from (finding #265).
"""
function _axes_range!(
	fig,
	letter::Char,
	range;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
	who::AbstractString,
)
	checked = _axes_checked_range(range, who)
	t = _cell_target(
		fig;
		row = row,
		col = col,
		inset = inset,
		secondary_y = secondary_y,
		who = who,
	)
	layout = _cmn_layout(fig)
	if t.kind === :xy
		letter == 'z' && throw(ArgumentError(
			"$(who): a Cartesian (xy) cell has no z axis; `zrange!` needs a " *
			"3-D scene cell.",
		))
		key = _axes_match_root(layout, letter == 'x' ? t.xkey : t.ykey, who)
		value = checked
		if checked !== nothing && _axis_type(layout, key) == "log"
			value = _to_axis_range(layout, key, checked; who = who)
		end
		_axes_write_xy_range!(fig, key, value)
	elseif t.kind === :scene
		value = checked
		if checked !== nothing
			axis_type = _cmn_mapping_get(
				_axes_scene_axis_entry(layout, t.scenekey, letter),
				:type,
			)
			if axis_type == "log"
				# Scene log axes store log10 ranges too (verified render,
				# probe2_scene_log.png).
				value = Float64[_axes_log10_bound(b, who) for b in checked]
			end
		end
		fields = value === nothing ?
			Dict{Symbol, Any}(:autorange => true) :
			Dict{Symbol, Any}(:range => value, :autorange => false)
		_axes_write_scene_axis!(fig, t.scenekey, letter, fields)
		if value === nothing
			_cmn_mapping_delete!(
				_axes_scene_axis_entry(_cmn_layout(fig), t.scenekey, letter),
				(:range,),
			)
		end
	else
		throw(ArgumentError(
			"$(who): axis ranges apply to Cartesian (xy) and 3-D scene cells; " *
			"this cell is :$(t.kind).",
		))
	end
	_axes_select!(fig, t)
	_axes_finish!(fig)
	return nothing
end

# ---------------------------------------------------------------------------
# zlabel! / zrange!
# ---------------------------------------------------------------------------

"""
	zlabel!(fig, label; row=nothing, col=nothing)
	zlabel!(sf::SubplotFigure, label; row=nothing, col=nothing)

Set the z-axis title of a 3-D scene: the scene of a `Plot`/`SyncPlot`, or of
the active (or `row`/`col`) cell of a [`SubplotFigure`](@ref). The title is
written to `scene.zaxis.title.text`; 3-D axis titles cannot typeset MathJax,
so TeX in `label` is converted to HTML/Unicode. `""` clears the title.

# Arguments
- `fig`: a `Plot`, `SyncPlot` or `SubplotFigure` whose target cell is a 3-D
  scene (anything else is an `ArgumentError`).
- `label::AbstractString`: the title.

# Keywords
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active). An `ArgumentError` on a plain figure.

Returns `nothing` (`sf` for a SubplotFigure).

# Example
```julia
fig = plot_surface(rand(10, 10))
zlabel!(fig, "height (m)")
```
"""
function zlabel!(
	fig,
	label::AbstractString;
	row = nothing,
	col = nothing,
	show = nothing,
)
	_axes_reject_show(show, "zlabel!")
	_axes_label!(fig, 'z', label; row = row, col = col, who = "zlabel!")
	return nothing
end

function zlabel!(
	sf::SubplotFigure,
	label::AbstractString;
	row = nothing,
	col = nothing,
	show = nothing,
)
	_axes_reject_show(show, "zlabel!")
	_transactional_subplot_mutation!(
		_axes_label!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		'z',
		label;
		row = row,
		col = col,
		who = "zlabel!",
	)
	return sf
end

"""
	zrange!(fig, range; row=nothing, col=nothing)
	zrange!(sf::SubplotFigure, range; row=nothing, col=nothing)

Set the z-axis range of a 3-D scene (the plain figure's scene, or the active
or `row`/`col` cell of a SubplotFigure) in DATA units, also on a logarithmic
scene axis (where Plotly stores log10 values; bounds must be positive).

# Arguments
- `range`: `(lo, hi)` or `[lo, hi]`. `[0, 0]`, `(0, 0)` and `nothing` restore
  automatic ranging. Partial ranges and equal bounds are an `ArgumentError`.

# Keywords
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active).

Writes `scene.zaxis.range` with `autorange = false`. Returns `nothing` (`sf`
for a SubplotFigure).

# Example
```julia
fig = plot_surface(rand(10, 10))
zrange!(fig, (0, 2))
```
"""
function zrange!(fig, range; row = nothing, col = nothing, show = nothing)
	_axes_reject_show(show, "zrange!")
	_axes_range!(fig, 'z', range; row = row, col = col, who = "zrange!")
	return nothing
end

function zrange!(
	sf::SubplotFigure,
	range;
	row = nothing,
	col = nothing,
	show = nothing,
)
	_axes_reject_show(show, "zrange!")
	_transactional_subplot_mutation!(
		_axes_range!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		'z',
		range;
		row = row,
		col = col,
		who = "zrange!",
	)
	return sf
end

# ---------------------------------------------------------------------------
# F8: xticks! / yticks!
# ---------------------------------------------------------------------------

function _axes_ticks!(
	fig,
	letter::Char,
	secondary_y::Bool,
	values,
	labels;
	format::AbstractString = "",
	exponentformat::AbstractString = "",
	subs = nothing,
	minor::Union{Nothing, Bool} = nothing,
	angle::Union{Nothing, Real} = nothing,
	direction::Union{AbstractString, Symbol} = "",
	tickwidth::Real = 0,
	ticklen::Real = 0,
	row = nothing,
	col = nothing,
	inset = nothing,
	who::AbstractString,
)
	t = _cell_target(
		fig;
		row = row,
		col = col,
		inset = inset,
		secondary_y = secondary_y,
		who = who,
	)
	_axes_require_xy(t, who, "tick control")
	_apply_ticks!(
		fig,
		letter == 'x' ? t.xkey : t.ykey;
		values = values,
		labels = labels,
		format = format,
		exponentformat = exponentformat,
		minor = minor,
		subs = subs,
		angle = angle,
		direction = String(direction),
		tickwidth = tickwidth,
		ticklen = ticklen,
		who = who,
	)
	_axes_select!(fig, t)
	_axes_finish!(fig)
	return nothing
end

# `secondary_y` is a y-only keyword; `_axes_ticks!` takes it positionally, so
# `xticks!(...; secondary_y=true)` is an unknown-keyword MethodError.
_axes_xticks!(fig, values, labels; kwargs...) =
	_axes_ticks!(fig, 'x', false, values, labels; kwargs..., who = "xticks!")

_axes_yticks!(fig, values, labels; secondary_y::Bool = false, kwargs...) =
	_axes_ticks!(fig, 'y', secondary_y, values, labels; kwargs..., who = "yticks!")

const _AXES_TICKS_DOC_KEYWORDS = """
# Keywords
- `format::AbstractString = ""`: d3 tick format (`tickformat`), e.g. `".2f"`,
  `"~g"`, `".0%"`. It takes precedence over `exponentformat` in plotly.js.
- `exponentformat::AbstractString = ""`: one of `"none"`, `"e"`, `"E"`,
  `"power"`, `"SI"`, `"B"`.
- `subs = nothing`: log axes only; mantissas per decade (`(1, 2, 5)`, `1:9`);
  ticks are `log_ticks` over the explicit range, else the data extent.
  Mutually exclusive with `values`.
- `minor::Union{Nothing,Bool} = nothing`: `true` draws minor ticks (0.6 of
  the major length; on a log axis with explicit major ticks at mantissas 1..9
  of every decade); `false` removes them; `nothing` leaves them.
- `angle::Union{Nothing,Real} = nothing`: tick-label angle in degrees.
- `direction = ""`: `"inside"`, `"outside"` (or the Symbols); `""` keeps it.
- `tickwidth::Real = 0`, `ticklen::Real = 0`: major tick width/length in px
  (0 keeps them); explicit minor ticks follow the new length.
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active). `inset = k` targets inset `k` (see
  [`inset!`](@ref)). Both are an `ArgumentError` on a plain figure.
"""

"""
	xticks!(fig, values=nothing, labels=nothing; format="", exponentformat="", subs=nothing, minor=nothing, angle=nothing, direction="", tickwidth=0, ticklen=0, row=nothing, col=nothing, inset=nothing)
	xticks!(sf::SubplotFigure, values=nothing, labels=nothing; ...)

Set the x-axis ticks of a figure, of one SubplotFigure cell or of an inset.
Only that axis changes (other cells keep their ticks).

# Arguments
- `values`: tick positions in DATA units, also on log axes (vector, range or
  tuple; strings on category axes). Sets `tickmode = "array"`.
- `labels`: one label per value; each goes through the mathtext layer, so a
  TeX label such as `L"\\pi/2"` (LaTeXStrings) typesets. Without labels,
  numeric ticks on a linear axis are printed with the d3 format `"~g"`
  (0.0025, 16) unless a format is set; a logarithmic axis keeps Plotly's
  power exponent format (1×10⁻⁶ … 1000 …).

$(_AXES_TICKS_DOC_KEYWORDS)
Errors (`ArgumentError`, before anything changes): mismatched label count,
non-finite or (log axis) non-positive values, `subs` on a linear axis, an
unknown `exponentformat`/`direction`, a non-xy cell. Returns `nothing` (`sf`
for a SubplotFigure).

# Example
```julia
x = collect(range(0, 2π; length = 100))
fig = plot_scatter(x, sin.(x))
xticks!(fig, [0, π/2, π, 3π/2, 2π], ["0", "π/2", "π", "3π/2", "2π"])
lg = plot_scatter([4, 8, 16, 32], [1.0, 2, 3, 4]; xscale = "log")
xticks!(lg, 2 .^ (2:5); minor = true)
```
"""
function xticks!(fig, values = nothing, labels = nothing; show = nothing, kwargs...)
	_axes_reject_show(show, "xticks!")
	_axes_xticks!(fig, values, labels; kwargs...)
	return nothing
end

function xticks!(
	sf::SubplotFigure,
	values = nothing,
	labels = nothing;
	show = nothing,
	kwargs...,
)
	_axes_reject_show(show, "xticks!")
	_transactional_subplot_mutation!(
		_axes_xticks!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		values,
		labels;
		kwargs...,
	)
	return sf
end

"""
	yticks!(fig, values=nothing, labels=nothing; format="", exponentformat="", subs=nothing, minor=nothing, angle=nothing, direction="", tickwidth=0, ticklen=0, row=nothing, col=nothing, inset=nothing, secondary_y=false)
	yticks!(sf::SubplotFigure, values=nothing, labels=nothing; ...)

Set the y-axis ticks; identical to [`xticks!`](@ref) for the y axis.
`secondary_y = true` targets the secondary y axis (a twin created by a
`secondary_y=true` plot call, or a `Spec(secondary_y=true)` subplot cell).

$(_AXES_TICKS_DOC_KEYWORDS)- `secondary_y::Bool = false`: target the secondary y axis.

Returns `nothing` (`sf` for a SubplotFigure).

# Example
```julia
fig = plot_scatter([1e-3, 1e3], [1e-2, 1e4]; xscale = "log", yscale = "log")
yticks!(fig; subs = (1, 2, 5), minor = true)
```
"""
function yticks!(fig, values = nothing, labels = nothing; show = nothing, kwargs...)
	_axes_reject_show(show, "yticks!")
	_axes_yticks!(fig, values, labels; kwargs...)
	return nothing
end

function yticks!(
	sf::SubplotFigure,
	values = nothing,
	labels = nothing;
	show = nothing,
	kwargs...,
)
	_axes_reject_show(show, "yticks!")
	_transactional_subplot_mutation!(
		_axes_yticks!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		values,
		labels;
		kwargs...,
	)
	return sf
end

# ---------------------------------------------------------------------------
# F9: axis_equal! / axis_off!
# ---------------------------------------------------------------------------

function _axes_equal!(
	fig;
	ratio::Real = 1,
	row = nothing,
	col = nothing,
	inset = nothing,
)
	who = "axis_equal!"
	t = _cell_target(fig; row = row, col = col, inset = inset, who = who)
	_apply_equal_aspect!(fig, t; ratio = ratio, who = who)
	_axes_select!(fig, t)
	_axes_finish!(fig)
	return nothing
end

"""
	axis_equal!(fig; ratio=1, row=nothing, col=nothing, inset=nothing)
	axis_equal!(sf::SubplotFigure; ratio=1, row=nothing, col=nothing, inset=nothing)

Lock the data aspect ratio of a figure, SubplotFigure cell or inset
(matplotlib `set_aspect`). One y data unit spans `ratio` times the pixels of
one x data unit: the cell's y axis gets `scaleanchor = <cell x>`,
`scaleratio = ratio`, and both axes get `constrain = "domain"`, so explicit
ranges are honoured and the plot area shrinks instead. A 3-D scene cell gets
`aspectmode = "data"` (only `ratio = 1`).

# Keywords
- `ratio::Real = 1`: finite and positive.
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active); `inset = k` targets inset `k`.

Returns `nothing` (`sf` for a SubplotFigure).

# Example
```julia
θ = range(0, 2π; length = 200)
fig = plot_scatter(cos.(θ), sin.(θ))
axis_equal!(fig)
```
"""
function axis_equal!(fig; show = nothing, kwargs...)
	_axes_reject_show(show, "axis_equal!")
	_axes_equal!(fig; kwargs...)
	return nothing
end

function axis_equal!(sf::SubplotFigure; show = nothing, kwargs...)
	_axes_reject_show(show, "axis_equal!")
	_transactional_subplot_mutation!(
		_axes_equal!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS;
		kwargs...,
	)
	return sf
end

# The cell's x and y axes plus every axis overlaying them (a twin y, a
# secondary x axis), in a stable order.
function _axes_cell_axis_keys(layout::Layout, t::_CellTarget)
	out = Symbol[t.xkey, t.ykey]
	overlays = Symbol[]
	for (key, value) in layout.fields
		(key isa Symbol || key isa AbstractString) || continue
		k = Symbol(key)
		occursin(_CMN_AXIS_KEY_PATTERN, String(k)) || continue
		k in out && continue
		overlaying = _cmn_mapping_get(value, :overlaying)
		overlaying isa Symbol && (overlaying = String(overlaying))
		overlaying in (t.xref, t.yref) && push!(overlays, k)
	end
	sort!(overlays; by = String)
	return vcat(out, overlays)
end

function _axes_off!(fig; row = nothing, col = nothing, inset = nothing)
	who = "axis_off!"
	t = _cell_target(fig; row = row, col = col, inset = inset, who = who)
	if t.kind === :xy
		for key in _axes_cell_axis_keys(_cmn_layout(fig), t)
			_cmn_merge_layout_key!(fig, key, Dict{Symbol, Any}(:visible => false))
		end
	elseif t.kind === :scene
		hidden = attr(visible = false, showbackground = false)
		_merge_scene_layout_attr!(
			_cmn_layout(fig),
			t.scenekey,
			attr(xaxis = hidden, yaxis = hidden, zaxis = hidden),
		)
	else
		throw(ArgumentError(
			"$(who): applies to Cartesian (xy) and 3-D scene cells; this cell " *
			"is :$(t.kind).",
		))
	end
	_axes_select!(fig, t)
	_axes_finish!(fig)
	return nothing
end

"""
	axis_off!(fig; row=nothing, col=nothing, inset=nothing)
	axis_off!(sf::SubplotFigure; row=nothing, col=nothing, inset=nothing)

Hide the axes of a figure, SubplotFigure cell or inset (matplotlib
`axis("off")`): an xy cell's x and y axes, and any axis overlaying them (a
secondary y or secondary x axis), get `visible = false`, which hides their
lines, ticks, labels, titles and grid. A 3-D scene cell hides all three axes
and their background planes (`visible = false`, `showbackground = false`).

# Keywords
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active); `inset = k` targets inset `k`.

Returns `nothing` (`sf` for a SubplotFigure).

# Example
```julia
θ = range(0, 2π; length = 100)
fig = plot_scatter(cos.(θ), sin.(θ))
axis_equal!(fig)
axis_off!(fig)
```
"""
function axis_off!(fig; show = nothing, kwargs...)
	_axes_reject_show(show, "axis_off!")
	_axes_off!(fig; kwargs...)
	return nothing
end

function axis_off!(sf::SubplotFigure; show = nothing, kwargs...)
	_axes_reject_show(show, "axis_off!")
	_transactional_subplot_mutation!(
		_axes_off!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS;
		kwargs...,
	)
	return sf
end

# ---------------------------------------------------------------------------
# F10: spines! / grid!
# ---------------------------------------------------------------------------

const _AXES_SPINE_STYLES = (:box, :open, :none)

function _axes_spines!(
	fig;
	style::Union{Symbol, AbstractString} = :box,
	color = "",
	linewidth::Real = 0,
	row = nothing,
	col = nothing,
	inset = nothing,
	cells = nothing,
)
	who = "spines!"
	style_name = Symbol(style)
	style_name in _AXES_SPINE_STYLES || throw(ArgumentError(
		"$(who): `style` must be :box, :open or :none; got $(repr(style)).",
	))
	_axes_check_size(linewidth, "linewidth", who)
	fields = Dict{Symbol, Any}()
	if style_name === :box
		fields[:showline] = true
		fields[:mirror] = true
	elseif style_name === :open
		fields[:showline] = true
		fields[:mirror] = false
	else
		fields[:showline] = false
	end
	_axes_is_unset_color(color) || (fields[:linecolor] = _color_hex(color; who = who))
	linewidth > 0 && (fields[:linewidth] = linewidth)
	targets, select = _axes_styling_targets(
		fig,
		who;
		row = row,
		col = col,
		inset = inset,
		cells = cells,
	)
	for t in targets, key in (t.xkey, t.ykey)
		_cmn_merge_layout_key!(fig, key, fields)
	end
	select && _axes_select!(fig, only(targets))
	_axes_finish!(fig)
	return nothing
end

"""
	spines!(fig; style=:box, color="", linewidth=0, row=nothing, col=nothing, inset=nothing, cells=nothing)
	spines!(sf::SubplotFigure; ...)

Style the axis lines ("spines") of a figure, SubplotFigure cell or inset.

# Keywords
- `style = :box`: `:box` closes the frame (`showline = true`,
  `mirror = true`, the package default); `:open` keeps only the bottom and
  left lines (`mirror = false`); `:none` hides the lines (`showline = false`;
  ticks stay). Strings are accepted.
- `color = ""`: line colour (CSS/hex string, Symbol or Colors.jl colour);
  `""` keeps it.
- `linewidth::Real = 0`: line width in px; 0 keeps it.
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active); `inset = k` targets inset `k`.
- `cells = nothing`: `:all` styles every xy cell of a SubplotFigure (insets
  excluded) and leaves the active cell unchanged.

Only the cell's primary x/y axes change; secondary axes keep their own line.
Returns `nothing` (`sf` for a SubplotFigure).

# Example
```julia
fig = plot_scatter(1:10, rand(10))
spines!(fig; style = :open, linewidth = 1.5)
```
"""
function spines!(fig; show = nothing, kwargs...)
	_axes_reject_show(show, "spines!")
	_axes_spines!(fig; kwargs...)
	return nothing
end

function spines!(sf::SubplotFigure; show = nothing, kwargs...)
	_axes_reject_show(show, "spines!")
	_transactional_subplot_mutation!(
		_axes_spines!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS;
		kwargs...,
	)
	return sf
end

const _AXES_GRID_AXES = (:both, :x, :y, :none)
const _AXES_GRID_WHICH = (:major, :minor, :both)
# Plotly dash names, and the matplotlib line-style codes mapped onto them.
const _AXES_DASH_NAMES = ("solid", "dot", "dash", "longdash", "dashdot", "longdashdot")
const _AXES_DASH_ALIASES = Dict(
	"-" => "solid",
	"--" => "dash",
	":" => "dot",
	"-." => "dashdot",
)
# Plotly's custom dash list: lengths in px or % ("5px,10px,2px,2px").
const _AXES_DASH_LIST = r"^\s*\d+(\.\d+)?(px|%)?(\s*,\s*\d+(\.\d+)?(px|%)?)*\s*$"

function _axes_dash(dash, who::AbstractString)
	(dash isa AbstractString || dash isa Symbol) || throw(ArgumentError(
		"$(who): `dash` must be a string; got $(repr(dash)).",
	))
	name = String(dash)
	isempty(name) && return ""
	haskey(_AXES_DASH_ALIASES, name) && return _AXES_DASH_ALIASES[name]
	(name in _AXES_DASH_NAMES || occursin(_AXES_DASH_LIST, name)) && return name
	throw(ArgumentError(
		"$(who): `dash` must be one of $(join(repr.(_AXES_DASH_NAMES), ", ")), " *
		"a matplotlib style (\"-\", \"--\", \":\", \"-.\") or a px/% list " *
		"such as \"5px,3px\"; got $(repr(dash)).",
	))
end

function _axes_grid!(
	fig;
	axis::Union{Symbol, AbstractString} = :both,
	which::Union{Symbol, AbstractString} = :major,
	color = "",
	width::Real = 0,
	dash = "",
	alpha::Union{Nothing, Real} = nothing,
	row = nothing,
	col = nothing,
	inset = nothing,
	cells = nothing,
)
	who = "grid!"
	axis_name = Symbol(axis)
	axis_name in _AXES_GRID_AXES || throw(ArgumentError(
		"$(who): `axis` must be :both, :x, :y or :none; got $(repr(axis)).",
	))
	which_name = Symbol(which)
	which_name in _AXES_GRID_WHICH || throw(ArgumentError(
		"$(who): `which` must be :major, :minor or :both; got $(repr(which)).",
	))
	_axes_check_size(width, "width", who)
	dash_name = _axes_dash(dash, who)
	gridcolor = if alpha !== nothing
		_rgba(_axes_is_unset_color(color) ? "#000000" : color, alpha; who = who)
	elseif !_axes_is_unset_color(color)
		_color_hex(color; who = who)
	else
		nothing
	end
	styled = gridcolor !== nothing || width > 0 || !isempty(dash_name)
	(axis_name === :none && styled) && throw(ArgumentError(
		"$(who): `color`, `alpha`, `width` and `dash` style visible grid " *
		"lines; `axis = :none` hides them all.",
	))
	targets, select = _axes_styling_targets(
		fig,
		who;
		row = row,
		col = col,
		inset = inset,
		cells = cells,
	)
	major_on = which_name in (:major, :both)
	minor_on = which_name in (:minor, :both)
	for t in targets
		for (key, on) in (
			(t.xkey, axis_name in (:both, :x)),
			(t.ykey, axis_name in (:both, :y)),
		)
			entry = get(_cmn_layout(fig).fields, key, nothing)
			fields = Dict{Symbol, Any}(:showgrid => on && major_on)
			if on
				gridcolor === nothing || (fields[:gridcolor] = gridcolor)
				width > 0 && (fields[:gridwidth] = width)
				isempty(dash_name) || (fields[:griddash] = dash_name)
			end
			minor_entry = _cmn_mapping_get(entry, :minor)
			if on && minor_on
				minor_fields = Dict{Symbol, Any}(:showgrid => true)
				# Log axis with explicit majors: Plotly's automatic minor
				# ticks smear (spec F8), so place them at mantissas 1..9.
				minor_values = _cmn_log_minor_tickvals(
					fig,
					key,
					_cmn_array_tickvals(entry),
					who,
				)
				if minor_values !== nothing
					minor_fields[:tickmode] = "array"
					minor_fields[:tickvals] = minor_values
				end
				fields[:minor] = attr(minor_fields)
			elseif minor_entry !== nothing
				fields[:minor] = attr(showgrid = false)
			end
			_cmn_merge_layout_key!(fig, key, fields; nested = (:minor,))
		end
	end
	select && _axes_select!(fig, only(targets))
	_axes_finish!(fig)
	return nothing
end

"""
	grid!(fig; axis=:both, which=:major, color="", width=0, dash="", alpha=nothing, row=nothing, col=nothing, inset=nothing, cells=nothing)
	grid!(sf::SubplotFigure; ...)

Set the grid lines of a figure, SubplotFigure cell or inset. Each call
defines the cell's grid completely: the axes selected by `axis` show the grid
lines selected by `which`; the other grid lines are hidden.

# Keywords
- `axis = :both`: `:both`, `:x`, `:y` or `:none` (no grid at all).
- `which = :major`: `:major`, `:minor` or `:both`. Minor grid lines on a log
  axis with explicit major ticks sit at mantissas 1..9 of every decade.
- `color = ""`: grid colour (string, Symbol or Colors.jl colour); `""` keeps
  Plotly's. Minor lines are drawn in a lighter blend of it by plotly.js.
- `alpha::Union{Nothing,Real} = nothing`: opacity in [0, 1]; turns `color`
  (black when unset) into an rgba colour, e.g. `alpha = 0.15`.
- `width::Real = 0`: grid line width in px; 0 keeps it.
- `dash = ""`: `"solid"`, `"dot"`, `"dash"`, `"longdash"`, `"dashdot"`,
  `"longdashdot"`, matplotlib `"-"`, `"--"`, `":"`, `"-."`, or a px list
  such as `"4px,2px"`.
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active); `inset = k` targets inset `k`.
- `cells = nothing`: `:all` applies to every xy cell of a SubplotFigure
  (insets excluded) without changing the active cell.

Styling keywords with `axis = :none` are an `ArgumentError`. Returns
`nothing` (`sf` for a SubplotFigure).

# Example
```julia
fig = plot_scatter(1:10, rand(10))
grid!(fig; axis = :y, alpha = 0.15, dash = "--")
```
"""
function grid!(fig; show = nothing, kwargs...)
	_axes_reject_show(show, "grid!")
	_axes_grid!(fig; kwargs...)
	return nothing
end

function grid!(sf::SubplotFigure; show = nothing, kwargs...)
	_axes_reject_show(show, "grid!")
	_transactional_subplot_mutation!(
		_axes_grid!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS;
		kwargs...,
	)
	return sf
end

# ---------------------------------------------------------------------------
# F11: secondary_xaxis!
# ---------------------------------------------------------------------------

# Number of samples used to check that `f` is monotone and `finv` inverts it
# (spec F11).
const _AXES_SECONDARY_SAMPLES = 101
# Relative tolerance of the `finv(f(x)) == x` check: loose enough for
# closed-form inverses evaluated in Float64, tight enough to catch a wrong one.
const _AXES_INVERSE_RTOL = 1e-6
# Target number of automatic secondary ticks (Plotly's own auto ticks show
# about 5-8 labels across a typical axis).
const _AXES_SECONDARY_TICK_TARGET = 6

function _axes_real_value(v, what::AbstractString, who::AbstractString)
	(v isa Real && !(v isa Bool) && isfinite(v)) || throw(ArgumentError(
		"$(who): $(what) must be a finite real number; got $(repr(v)).",
	))
	return Float64(v)
end

# Union of the data extents of every x axis whose `matches` chain ends at
# `root` (a shared axis group autoranges over all of them).
function _axes_group_extent(fig, root::Symbol, who::AbstractString)
	layout = _cmn_layout(fig)
	keys_in_group = Symbol[root]
	for key in keys(layout.fields)
		(key isa Symbol || key isa AbstractString) || continue
		k = Symbol(key)
		_cmn_axis_index(k, 'x') === nothing && continue
		k === root && continue
		_axes_match_root(layout, k, who) === root && push!(keys_in_group, k)
	end
	lower, upper = Inf, -Inf
	for key in keys_in_group
		extent = _axis_data_extent(fig, key)
		extent === nothing && continue
		lower = min(lower, extent[1])
		upper = max(upper, extent[2])
	end
	return lower <= upper ? (lower, upper) : nothing
end

# 1-2-5 ticks `k * m * 10^e` covering [lo, hi]: the step `m * 10^e`
# (m in 1, 2, 5) whose tick count is closest to the target, the larger step
# on a tie. Values are computed from integers so they are correctly rounded
# (0.3, not 0.30000000000000004).
function _axes_linear_ticks(lo::Float64, hi::Float64, who::AbstractString)
	span = hi - lo
	raw = span / _AXES_SECONDARY_TICK_TARGET
	e0 = floor(Int, log10(raw))
	# The smallest candidate step is 10^e0; k = value / step must fit an Int.
	max(abs(lo), abs(hi)) / exp10(e0) < 1e15 || throw(ArgumentError(
		"$(who): the secondary range [$(lo), $(hi)] is too narrow for its " *
		"magnitude to place automatic ticks; pass `ticks`.",
	))
	slack = 1e-9 * span
	best = nothing
	best_score = typemax(Int)
	for e in (e0, e0 + 1), m in (1, 2, 5)
		step = m * exp10(e)
		kmin = ceil(Int, (lo - slack) / step)
		kmax = floor(Int, (hi + slack) / step)
		count = kmax - kmin + 1
		count >= 2 || continue
		score = abs(count - _AXES_SECONDARY_TICK_TARGET)
		if score <= best_score
			best = (m, e, kmin, kmax)
			best_score = score
		end
	end
	# The step 10^e0 <= span / target always yields at least `target` ticks.
	m, e, kmin, kmax = something(best)
	return Float64[_cmn_log_tick_value(Float64(k * m), 10.0, e) for k in kmin:kmax]
end

function _axes_secondary_auto_ticks(lo::Float64, hi::Float64, log_axis::Bool, who::AbstractString)
	if log_axis && lo > 0
		decades = log10(hi / lo)
		if decades >= 1
			values = log_ticks(lo, hi; subs = decades <= 3 ? (1, 2, 5) : (1,))
			if length(values) > 2 * _AXES_SECONDARY_TICK_TARGET
				# Many decades: keep every n-th power of ten.
				stride = ceil(Int, length(values) / _AXES_SECONDARY_TICK_TARGET)
				values = values[1:stride:end]
			end
			length(values) >= 2 && return values
		end
	end
	return _axes_linear_ticks(lo, hi, who)
end

# Compact tick text: integers without ".0", six significant digits, plain
# decimals in [1e-4, 1e15) and "me±k" outside.
function _axes_format_number(v::Float64)
	v == 0 && return "0"
	r = round(v; sigdigits = 6)
	a = abs(r)
	if 1e-4 <= a < 1e15
		return isinteger(r) ? string(Int64(r)) : string(r)
	end
	e = floor(Int, log10(a))
	mantissa = round(r / exp10(e); sigdigits = 6)
	if abs(mantissa) >= 10
		mantissa /= 10
		e += 1
	end
	text = isinteger(mantissa) ? string(Int64(mantissa)) : string(mantissa)
	return "$(text)e$(e)"
end

function _axes_secondary_xaxis!(
	fig,
	f,
	finv;
	ticks = nothing,
	ticklabels = nothing,
	title::AbstractString = "",
	side::Union{Symbol, AbstractString} = :top,
	row = nothing,
	col = nothing,
	inset = nothing,
)
	who = "secondary_xaxis!"
	side_name = String(side)
	side_name in ("top", "bottom") || throw(ArgumentError(
		"$(who): `side` must be :top or :bottom; got $(repr(side)).",
	))
	t = _cell_target(fig; row = row, col = col, inset = inset, who = who)
	_axes_require_xy(t, who, "a secondary x axis")
	layout = _cmn_layout(fig)
	root = _axes_match_root(layout, t.xkey, who)
	axis_type = _axis_type(layout, root)
	axis_type in ("-", "linear", "log") || throw(ArgumentError(
		"$(who): needs a numeric (linear or log) x axis; $(repr(root)) has " *
		"type $(repr(axis_type)).",
	))
	log_axis = axis_type == "log"
	primary_side = _cmn_mapping_get(get(layout.fields, t.xkey, nothing), :side)
	primary_side isa AbstractString || (primary_side = "bottom")
	primary_side == side_name && throw(ArgumentError(
		"$(who): the primary x axis is already on the $(side_name); put the " *
		"secondary axis on the other side.",
	))

	# Range of the primary axis in data units. plotly.js cannot link an axis
	# transform, so the ticks are computed for this range, and an automatic
	# range is frozen to the data extent below.
	explicit = _from_axis_range(layout, root)
	limits = explicit === nothing ? _axes_group_extent(fig, root, who) : explicit
	limits === nothing && throw(ArgumentError(
		"$(who): the x range of this cell is unknown; add data or set it with " *
		"`xrange!` first.",
	))
	lower, upper = minmax(limits...)
	lower < upper || throw(ArgumentError(
		"$(who): the x range [$(lower), $(upper)] is empty; set a wider range " *
		"with `xrange!`.",
	))

	# f must be strictly monotone on the range and finv its inverse.
	samples = log_axis ?
		exp10.(range(log10(lower), log10(upper); length = _AXES_SECONDARY_SAMPLES)) :
		collect(range(lower, upper; length = _AXES_SECONDARY_SAMPLES))
	mapped = Float64[_axes_real_value(f(x), "f($(x))", who) for x in samples]
	steps = diff(mapped)
	(all(>(0), steps) || all(<(0), steps)) || throw(ArgumentError(
		"$(who): `f` must be strictly monotone on the x range " *
		"[$(lower), $(upper)] (checked at $(_AXES_SECONDARY_SAMPLES) points).",
	))
	for (x, y) in zip(samples, mapped)
		back = _axes_real_value(finv(y), "finv(f($(x)))", who)
		scale = log_axis ? abs(x) : upper - lower
		abs(back - x) <= _AXES_INVERSE_RTOL * scale || throw(ArgumentError(
			"$(who): `finv` does not invert `f`: finv(f($(x))) = $(back).",
		))
	end

	# Tick values in secondary units and their positions on the primary axis.
	tick_values = if ticks === nothing
		ticklabels === nothing || throw(ArgumentError(
			"$(who): `ticklabels` need explicit `ticks`.",
		))
		lo2, hi2 = extrema(mapped)
		_axes_secondary_auto_ticks(lo2, hi2, log_axis, who)
	else
		(ticks isa AbstractVector || ticks isa Tuple) || throw(ArgumentError(
			"$(who): `ticks` must be a vector or tuple of numbers; got " *
			"$(typeof(ticks)).",
		))
		Float64[_axes_real_value(v, "a tick value", who) for v in ticks]
	end
	positions = Float64[]
	for v in tick_values
		x = _axes_real_value(finv(v), "finv($(v))", who)
		(log_axis && x <= 0) && throw(ArgumentError(
			"$(who): tick $(v) maps to x = $(x), which cannot be placed on the " *
			"logarithmic primary axis.",
		))
		push!(positions, x)
	end
	text = ticklabels === nothing ?
		String[_axes_format_number(v) for v in tick_values] :
		_cmn_tick_labels(ticklabels, length(tick_values), who)
	title_text = _label(title)

	# The axis: reuse the one a previous call created for this cell axis
	# (found through its named dummy trace), else the next free index.
	name = "plotlysupply:secondary_xaxis:" * t.xref
	data = _plot_data(_cmn_relayout_target(fig))
	existing_ref = nothing
	for trace in data
		trace isa GenericTrace || continue
		get(trace.fields, :name, nothing) == name || continue
		ref = get(trace.fields, :xaxis, nothing)
		ref isa Symbol && (ref = String(ref))
		_cmn_axis_ref_index(ref, 'x') === nothing || (existing_ref = String(ref))
		break
	end
	key = existing_ref === nothing ?
		Symbol("xaxis", _axes_highest_axis_index(_cmn_plot(fig), 'x') + 1) :
		_axis_layout_key(existing_ref, :x)
	ref = _cmn_axis_ref(key; who = who)

	# --- write ---
	if explicit === nothing
		_axes_write_xy_range!(
			fig,
			root,
			log_axis ? Float64[log10(limits[1]), log10(limits[2])] :
			Float64[limits[1], limits[2]],
		)
	end
	fields = Dict{Symbol, Any}(
		:overlaying => t.xref,
		:matches => _cmn_axis_ref(root; who = who),
		:anchor => t.yref,
		:side => side_name,
		:tickmode => "array",
		:tickvals => positions,
		:ticktext => text,
		:showgrid => false,
		:zeroline => false,
		:showline => true,
		:mirror => false,
		:ticks => "outside",
		:automargin => true,
		:linecolor => _DEFAULT_AXIS_LINECOLOR,
		:linewidth => _DEFAULT_AXIS_LINEWIDTH,
		:tickcolor => _DEFAULT_AXIS_LINECOLOR,
		:title => attr(text = title_text),
	)
	axis_type == "-" || (fields[:type] = axis_type)
	_cmn_merge_layout_key!(fig, key, fields; nested = (:title,))
	if existing_ref === nothing
		# plotly.js draws an axis only when a trace uses it (verified render,
		# probe3_secondary_noaxis_trace.png); `visible = false` keeps it out of
		# the legend and the hover layer (probe3_secondary_visfalse.png).
		push!(
			data,
			scatter(
				x = [nothing],
				y = [nothing],
				xaxis = ref,
				yaxis = t.yref,
				name = name,
				showlegend = false,
				hoverinfo = "skip",
				visible = false,
			),
		)
	end
	_axes_select!(fig, t)
	_axes_finish!(fig)
	return nothing
end

"""
	secondary_xaxis!(fig, f, finv; ticks=nothing, ticklabels=nothing, title="", side=:top, row=nothing, col=nothing, inset=nothing)
	secondary_xaxis!(sf::SubplotFigure, f, finv; ...)

Add a second x axis showing `f(x)` for the primary x axis of a figure,
SubplotFigure cell or inset (matplotlib `secondary_xaxis`), e.g. frequency
above a wavelength axis. The new axis overlays and `matches` the primary
axis, so its ticks sit at `x = finv(tick)` and follow zoom and pan.

plotly.js cannot link an axis transform, so the ticks are computed once for
the primary range: the explicit range when one is set, otherwise the data
extent of the (shared) axis, which is then written as an explicit range.
Set the final range with [`xrange!`](@ref) before calling this.

# Arguments
- `f`: the transform, strictly monotone on the x range (checked at 101
  points; also on log axes).
- `finv`: its inverse; `finv(f(x)) ≈ x` is checked at the same points.

# Keywords
- `ticks = nothing`: tick values in the secondary units; `nothing` chooses
  1-2-5 values inside `f(range)` (powers of ten on a log axis spanning a
  decade or more).
- `ticklabels = nothing`: one label per tick (through the mathtext layer);
  requires `ticks`. Default: the values with six significant digits.
- `title::AbstractString = ""`: axis title.
- `side = :top`: `:top` or `:bottom`; must differ from the primary side.
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active); `inset = k` targets inset `k`.

Calling it again for the same axis replaces the secondary axis (idempotent).
The axis needs a hidden dummy trace (named
`"plotlysupply:secondary_xaxis:<x ref>"`, `visible = false`), because
plotly.js only draws axes that a trace uses. Returns `nothing` (`sf` for a
SubplotFigure).

# Example
```julia
λ = collect(400.0:5:700.0)                     # wavelength in nm
fig = plot_scatter(λ, exp.(-((λ .- 550) ./ 60) .^ 2); xlabel = "wavelength (nm)")
c = 299792.458                                  # nm·THz
secondary_xaxis!(fig, l -> c / l, ν -> c / ν; title = "frequency (THz)")
```
"""
function secondary_xaxis!(fig, f, finv; show = nothing, kwargs...)
	_axes_reject_show(show, "secondary_xaxis!")
	_axes_secondary_xaxis!(fig, f, finv; kwargs...)
	return nothing
end

function secondary_xaxis!(sf::SubplotFigure, f, finv; show = nothing, kwargs...)
	_axes_reject_show(show, "secondary_xaxis!")
	_transactional_subplot_mutation!(
		_axes_secondary_xaxis!,
		sf,
		_SUBPLOT_SELECTION_METADATA_FIELDS,
		f,
		finv;
		kwargs...,
	)
	return sf
end

# ---------------------------------------------------------------------------
# F12: inset!
# ---------------------------------------------------------------------------

function _axes_inset_bounds(bounds, who::AbstractString)
	((bounds isa Tuple || bounds isa AbstractVector) && length(bounds) == 4) ||
		throw(ArgumentError(
			"$(who): `bounds` must be (x0, y0, width, height) as a 4-tuple or " *
			"4-vector; got $(repr(bounds)).",
		))
	values = Float64[]
	for (name, v) in zip(("x0", "y0", "width", "height"), bounds)
		(v isa Real && !(v isa Bool) && isfinite(v) && 0 <= v <= 1) ||
			throw(ArgumentError(
				"$(who): bounds `$(name)` must be a number in [0, 1]; got $(repr(v)).",
			))
		push!(values, Float64(v))
	end
	x0, y0, w, h = values
	(w > 0 && h > 0) || throw(ArgumentError(
		"$(who): the inset width and height must be positive; got $(repr(bounds)).",
	))
	# Tolerance for fractions such as 0.7 + 0.3, which exceed 1 by one ulp.
	x0 + w <= 1 + 1e-12 || throw(ArgumentError(
		"$(who): x0 + width = $(x0 + w) exceeds 1.",
	))
	y0 + h <= 1 + 1e-12 || throw(ArgumentError(
		"$(who): y0 + height = $(y0 + h) exceeds 1.",
	))
	return (x0, y0, w, h)
end

function _axes_inset!(
	sf::SubplotFigure,
	bounds;
	row = nothing,
	col = nothing,
	coords::Union{Symbol, AbstractString} = :axes,
	sharex::Bool = false,
	sharey::Bool = false,
)
	who = "inset!"
	x0, y0, w, h = _axes_inset_bounds(bounds, who)
	coords_name = Symbol(coords)
	coords_name in (:axes, :paper) || throw(ArgumentError(
		"$(who): `coords` must be :axes (fractions of the host cell) or " *
		":paper; got $(repr(coords)).",
	))
	host = _cell_target(sf; row = row, col = col, who = who)
	_axes_require_xy(host, who, "an inset")
	fraction(domain, a, b) = (
		clamp(domain[1] + a * (domain[2] - domain[1]), 0.0, 1.0),
		clamp(domain[1] + b * (domain[2] - domain[1]), 0.0, 1.0),
	)
	xdomain, ydomain = if coords_name === :axes
		(fraction(host.xdomain, x0, x0 + w), fraction(host.ydomain, y0, y0 + h))
	else
		((x0, min(x0 + w, 1.0)), (y0, min(y0 + h, 1.0)))
	end

	p = _cmn_plot(sf)
	layout = p.layout
	index = max(
		_axes_highest_axis_index(p, 'x'),
		_axes_highest_axis_index(p, 'y'),
	) + 1
	xkey, ykey = Symbol("xaxis", index), Symbol("yaxis", index)
	xref, yref = "x$(index)", "y$(index)"
	frame = Dict{Symbol, Any}(
		:showline => true,
		:mirror => true,
		:ticks => "outside",
		:zeroline => false,
		# Inset tick labels must not grow the figure margins.
		:automargin => false,
		:linecolor => _DEFAULT_AXIS_LINECOLOR,
		:linewidth => _DEFAULT_AXIS_LINEWIDTH,
		:tickcolor => _DEFAULT_AXIS_LINECOLOR,
	)
	xfields = merge(frame, Dict{Symbol, Any}(:domain => collect(xdomain), :anchor => yref))
	yfields = merge(frame, Dict{Symbol, Any}(:domain => collect(ydomain), :anchor => xref))
	for (share, host_key, fields) in ((sharex, host.xkey, xfields), (sharey, host.ykey, yfields))
		share || continue
		root = _axes_match_root(layout, host_key, who)
		fields[:matches] = _cmn_axis_ref(root; who = who)
		# Matched axes must have the same type.
		axis_type = _axis_type(layout, root)
		axis_type == "-" || (fields[:type] = axis_type)
		exponent = _cmn_mapping_get(get(layout.fields, root, nothing), :exponentformat)
		exponent isa AbstractString && (fields[:exponentformat] = exponent)
	end
	_cmn_merge_layout_key!(sf, xkey, xfields)
	_cmn_merge_layout_key!(sf, ykey, yfields)
	insets = getfield(sf, :insets)
	push!(
		insets,
		_SubplotInset(host.row, host.col, xkey, ykey, xref, yref, xdomain, ydomain),
	)
	_axes_select!(sf, host)
	_axes_finish!(sf)
	return length(insets)
end

"""
	inset!(sf::SubplotFigure, bounds; row=nothing, col=nothing, coords=:axes, sharex=false, sharey=false) -> Int

Add inset axes to a SubplotFigure cell and return the inset id `k`. Pass
`inset = k` to the axis helpers ([`xlabel!`](@ref), [`xrange!`](@ref),
[`xticks!`](@ref), [`grid!`](@ref), ...) to style it; plot calls route traces
there with `inset = k` (traces may also name the axes directly: `xaxis` /
`yaxis` are `sf.insets[k].xref` / `.yref`).

# Arguments
- `bounds`: `(x0, y0, width, height)` (tuple or vector), each in [0, 1]:
  fractions of the host cell's plot area (`coords = :axes`) or of the whole
  figure (`coords = :paper`); `x0 + width` and `y0 + height` must not exceed 1.

# Keywords
- `row`, `col`: host cell (both or neither; default the active cell, which
  the call makes active). The host must be a Cartesian (xy) cell.
- `coords = :axes`: `:axes` or `:paper`.
- `sharex`, `sharey`: share the host axis range (`matches`); the inset then
  also takes the host's axis type (and exponent format).

The inset axes are boxed (black lines, outside ticks) and do not push the
figure margins. Each call creates a new inset (ids are 1, 2, ... in creation
order). plotly.js has no opaque background for overlapping axes, so host data
under the inset stays visible. `inset!` on a `Plot`/`SyncPlot` is an
`ArgumentError`.

# Example
```julia
sf = subplots(1, 1; sync = false)
x = collect(0:0.01:10)
plot_scatter!(sf, x, sin.(x) .* exp.(-x ./ 5))
k = inset!(sf, (0.55, 0.55, 0.4, 0.4))
xrange!(sf, (2, 3); inset = k)
```
"""
function inset!(sf::SubplotFigure, bounds; show = nothing, kwargs...)
	_axes_reject_show(show, "inset!")
	return _transactional_subplot_mutation!(
		_axes_inset!,
		sf,
		_SUBPLOT_INSET_METADATA_FIELDS,
		bounds;
		kwargs...,
	)
end

function inset!(fig, bounds; kwargs...)
	throw(ArgumentError(
		"inset! needs a SubplotFigure; use subplots(1,1; sync=false)",
	))
end
