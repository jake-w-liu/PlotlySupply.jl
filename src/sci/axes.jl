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
export secondary_xaxis!, inset!, remove_inset!

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

# A keyword the helper does not take is an ArgumentError naming the public
# function and what it takes (invariant 4), not a MethodError naming the
# private implementation. `names`: the accepted keywords besides `show`.
function _axes_reject_unknown(kwargs, names, who::AbstractString)
	unknown = Symbol[k for k in keys(kwargs) if !(k in names)]
	isempty(unknown) && return nothing
	throw(ArgumentError(
		"$(who): unsupported keyword argument(s) " *
		"$(join(("`$(k)`" for k in unknown), ", ")); it takes " *
		"$(join(("`$(k)`" for k in names), ", ")).",
	))
end

const _AXES_TICKS_KEYWORDS = (
	:format, :exponentformat, :subs, :minor, :angle, :direction, :tickwidth,
	:ticklen, :offset, :row, :col, :inset,
)
const _AXES_YTICKS_KEYWORDS = (_AXES_TICKS_KEYWORDS..., :secondary_y)
const _AXES_EQUAL_KEYWORDS = (:ratio, :row, :col, :inset)
const _AXES_OFF_KEYWORDS = (:row, :col, :inset)
const _AXES_SPINES_KEYWORDS = (
	:style, :color, :linewidth, :ticks, :bottom, :top, :left, :right, :row,
	:col, :inset, :cells,
)
const _AXES_GRID_KEYWORDS = (
	:axis, :which, :color, :width, :dash, :alpha, :row, :col, :inset, :cells,
)
const _AXES_SECONDARY_X_KEYWORDS = (:ticks, :ticklabels, :title, :side, :row, :col, :inset)
const _AXES_INSET_KEYWORDS = (
	:row, :col, :coords, :sharex, :sharey, :background, :ticklabel_halo, :fontsize,
)

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

# Whether plotly.js knows axis `key`: it has a layout entry or a trace uses it
# (plotly.js creates implicit axes for trace references).
function _axes_axis_exists(p::Plot, key::Symbol)
	haskey(p.layout.fields, key) && return true
	letter = String(key)[1]
	index = _cmn_axis_index(key, letter)
	index === nothing && return false
	field = letter == 'x' ? :xaxis : :yaxis
	for trace in p.data
		trace isa GenericTrace || continue
		ref = get(trace.fields, field, letter == 'x' ? "x" : "y")
		ref isa Symbol && (ref = String(ref))
		_cmn_axis_ref_index(ref, letter) == index && return true
	end
	return false
end

# Follow `matches` from axis `key` to the axis that owns the shared range.
# plotly.js takes the range of a matched group from that root axis, so a range
# written on a follower is ignored (finding #265). A `matches` reference to an
# axis that does not exist is dropped by plotly.js, so the chain stops there.
function _axes_match_root(fig, key::Symbol, who::AbstractString)
	p = _cmn_plot(fig)
	layout = p.layout
	letter = String(key)[1]
	chain = Symbol[key]
	current = key
	while true
		ref = _cmn_mapping_get(get(layout.fields, current, nothing), :matches)
		ref isa Symbol && (ref = String(ref))
		(ref isa AbstractString && _cmn_axis_ref_index(ref, letter) !== nothing) ||
			return current
		next = _axis_layout_key(ref, Symbol(letter))
		_axes_axis_exists(p, next) || return current
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
	_axes_label!(fig_or_sf, letter, label; row, col, inset, secondary_y, wrap = true, who)

Write the title of axis `letter` ('x', 'y' or 'z') of the target cell: an xy
axis gets `title.text = _label(label)` (with `wrap = false` passed through
`_axes_keep_on_one_line`, so `_finalize_figure!` never breaks it into
lines; see "Axis titles that run off the figure"), a 3-D scene axis
`scene.<letter>axis.title.text = _label3d(label)`, after which the scene3d
finish steps (`_s3_finish_scene!`, `_s3_finish_ticks!`) keep the scene's
automatic camera and tick counts current, as a range change does. An empty
`label` clears the title. Other cell kinds (and 'z' on an xy cell) are an
`ArgumentError`.
"""
function _axes_label!(
	fig,
	letter::Char,
	label::AbstractString;
	row = nothing,
	col = nothing,
	inset = nothing,
	secondary_y::Bool = false,
	wrap::Bool = true,
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
		wrap || (text = _axes_keep_on_one_line(text))
		_axes_write_axis_title!(fig, letter == 'x' ? t.xkey : t.ykey, text)
	elseif t.kind === :scene
		text = _axes_label3d(label)
		# The scene3d finish step keeps an automatic camera at the automatic
		# distance and the cell's tick counts current (Z45), as `zrange!` does.
		state = _s3_scene_state(fig, t)
		_axes_write_scene_axis!(
			fig,
			t.scenekey,
			letter,
			Dict{Symbol, Any}(:title => attr(text = text)),
		)
		_s3_finish_scene!(fig, t, state)
		_s3_finish_ticks!(fig, t, state)
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
# `nothing`, [nothing, nothing]), otherwise the two bounds, one of which may
# be `nothing` (a one-sided limit, D11). `_checked_range` (base.jl) rejects
# wrong lengths, Bool and non-finite bounds and equal bounds.
_axes_checked_range(range, who::AbstractString) =
	_checked_range(range, who, "range"; partial = true)

# The checked range in the units Plotly stores for an axis of type
# `axis_type`: `to_log(checked)` (log10 of the bounds) on a log axis; numeric
# bounds are required on linear and category axes (a category range is in
# 0-based category positions). Date axes and autotyped ("-") axes take the
# bounds of a full range as given. The fixed bound of a one-sided limit is
# converted by `_axis_limit_bound` (log10; milliseconds on date axes).
function _axes_axis_range_value(checked, axis_type, who::AbstractString, to_log)
	checked === nothing && return nothing
	if axis_type in _NUMERIC_RANGE_AXIS_TYPES && axis_type != "log"
		all(b -> b === nothing || b isa Real, checked) || throw(ArgumentError(
			"$(who): a $(axis_type) axis needs numeric range bounds; got " *
			"$(repr(Tuple(checked))).",
		))
	end
	_is_one_sided_range(checked) &&
		return _axis_range_store_value(checked, axis_type, who, "range")
	axis_type == "log" && return to_log(checked)
	return checked
end

# Every axis of a `matches` group whose root is `root` (the root first).
function _axes_match_members(fig, root::Symbol, who::AbstractString)
	letter = String(root)[1]
	members = Symbol[root]
	for key in keys(_cmn_layout(fig).fields)
		k = key isa Symbol ? key : (key isa AbstractString ? Symbol(key) : nothing)
		(k === nothing || k === root || _cmn_axis_index(k, letter) === nothing) && continue
		_axes_match_root(fig, k, who) === root && push!(members, k)
	end
	return members
end

# Whether a scene axis is drawn reversed: a reversed `autorange`, or a
# decreasing explicit range in effect.
function _axes_scene_axis_reversed(axis)
	auto = _cmn_mapping_get(axis, :autorange)
	auto isa Symbol && (auto = String(auto))
	auto isa AbstractString && return auto in _REVERSED_AUTORANGES
	stored = _s3_explicit_range(axis)
	return auto !== true && stored !== nothing && stored[2] < stored[1]
end

# A one-sided limit on a 3-D scene axis as a full range, in axis units: the
# open end is the data end of the axis widened by 1/32 of the data extent
# (plotly.js gl3d autorange; ±1 around a single value), taken when the call
# runs. plotly.js sizes "auto"/"data" scenes by the data extents, not by the
# ranges, so a scene range must be complete for `_s3_finish_scene!` to pin
# the proportions (Y26); this is also matplotlib's `set_zlim(bottom = 0)`,
# which fixes the other end at its current value.
function _axes_scene_limit_range(fig, scenekey::Symbol, letter::Char, value, who::AbstractString)
	p = _cmn_plot(fig)
	d = letter == 'x' ? 1 : letter == 'y' ? 2 : 3
	bounds = _s3_data_bounds(p, scenekey, d)
	bounds === nothing && throw(ArgumentError(
		"$(who): `range` = $(repr(Tuple(value))) is a one-sided limit; on a 3-D " *
		"scene its open end is taken from the data on the axis, and the $(letter) " *
		"axis has none yet. Add the data first, or give both bounds.",
	))
	extent = bounds[2] - bounds[1]
	pad = extent > 0 ? extent / 32 : 1.0
	lower, upper = bounds[1] - pad, bounds[2] + pad
	reversed = _axes_scene_axis_reversed(_axes_scene_axis_entry(_cmn_layout(fig), scenekey, letter))
	start, stop = value[1], value[2]
	fixed_min, fixed_max = reversed ? (stop, start) : (start, stop)
	lo = fixed_min === nothing ? lower : Float64(fixed_min)
	hi = fixed_max === nothing ? upper : Float64(fixed_max)
	lo < hi || throw(ArgumentError(
		"$(who): `range` = $(repr(Tuple(value))) leaves no room for the data on the " *
		"$(letter) axis (its open end, taken from the data, is not beyond the fixed " *
		"bound); give both bounds.",
	))
	return reversed ? Any[hi, lo] : Any[lo, hi]
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
automatic sentinel deletes the range and sets `autorange = true` (`"reversed"`
on a reversed axis). On xy axes the write is the package's range encoder
(`_write_axis_group_range!`, the half of `_apply_axis_range_to_key!` after
the bound checks): a one-sided limit (D11) as `autorangeoptions` limits, the
range on the root of a `matches` group, the only axis plotly.js reads it from
(finding #265), and the limits on every member (plotly.js reads
`autorangeoptions` per axis; measured, probe p04). On scene axes a one-sided
limit becomes a full range from the data (`_axes_scene_limit_range`). A scene
call keeps the scene's proportions and camera framing with the scene3d
helpers (Y26).
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
		key = _axes_match_root(fig, letter == 'x' ? t.xkey : t.ykey, who)
		# The bounds the axis can show (D3, axes-ticks-02): numbers on a
		# numeric axis, 0-based positions on a category axis, dates on a date
		# axis; on an autotyped axis what its data make of it.
		checked === nothing || _require_range_bound_types(
			checked,
			_axes_bound_axis_type(fig, _axes_match_members(fig, key, who), _axis_type(layout, key)),
			who,
			"range",
		)
		value = _axes_axis_range_value(
			checked,
			_axis_type(layout, key),
			who,
			r -> _to_axis_range(layout, key, r; who = who),
		)
		# The package's one range encoder (base.jl), as the range keywords.
		_write_axis_group_range!(fig, key, value, who, "range")
	elseif t.kind === :scene
		# Scene log axes store log10 ranges too (verified render,
		# probe2_scene_log.png).
		axis_type = _cmn_mapping_get(
			_axes_scene_axis_entry(layout, t.scenekey, letter),
			:type,
		)
		axis_type isa Symbol && (axis_type = String(axis_type))
		axis_type isa AbstractString || (axis_type = "-")
		value = _axes_axis_range_value(
			checked,
			axis_type,
			who,
			r -> Float64[_axes_log10_bound(b, who) for b in r],
		)
		_is_one_sided_range(value) &&
			(value = _axes_scene_limit_range(fig, t.scenekey, letter, value, who))
		state = _s3_scene_state(fig, t)
		reversed = _axes_scene_axis_reversed(_axes_scene_axis_entry(layout, t.scenekey, letter))
		fields = value === nothing ?
			Dict{Symbol, Any}(:autorange => reversed ? "reversed" : true) :
			Dict{Symbol, Any}(:range => value, :autorange => false)
		_axes_write_scene_axis!(fig, t.scenekey, letter, fields)
		if value === nothing
			_cmn_mapping_delete!(
				_axes_scene_axis_entry(_cmn_layout(fig), t.scenekey, letter),
				(:range,),
			)
		end
		_s3_finish_scene!(fig, t, state)
		_s3_finish_ticks!(fig, t, state)
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
	kwargs...,
)
	_axes_reject_show(show, "zlabel!")
	_axes_reject_unknown(kwargs, (:row, :col), "zlabel!")
	_axes_label!(fig, 'z', label; row = row, col = col, who = "zlabel!")
	return nothing
end

function zlabel!(
	sf::SubplotFigure,
	label::AbstractString;
	row = nothing,
	col = nothing,
	show = nothing,
	kwargs...,
)
	_axes_reject_show(show, "zlabel!")
	_axes_reject_unknown(kwargs, (:row, :col), "zlabel!")
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
- `range`: `(lo, hi)` or `[lo, hi]`; `hi < lo` reverses the axis. `[0, 0]`,
  `(0, 0)`, `nothing` and `(nothing, nothing)` restore automatic ranging.
  `(lo, nothing)` / `(nothing, hi)` is a one-sided limit: the given end is
  fixed and the other end is taken from the data when the call runs (the
  data end widened by 1/32 of the data extent, as plotly.js autoranges a
  scene axis; matplotlib's `set_zlim(bottom = lo)` also fixes the other end
  at its current value). It needs data on the axis, and a fixed bound
  beyond the data is an `ArgumentError`. Equal, `Bool` and non-finite bounds
  are an `ArgumentError`.

# Keywords
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active).

Writes `scene.zaxis.range` with `autorange = false`. The scene keeps its
proportions: with `aspectmode` `"data"` or `"auto"` (which plotly.js derives
from the data, ignoring ranges) the scene gets the manual aspect ratios of
the drawn ranges, an automatic camera is re-framed for the new box, and the
tick counts of a subplot cell are updated. Returns `nothing` (`sf` for a
SubplotFigure).

# Example
```julia
fig = plot_surface(rand(10, 10))
zrange!(fig, (0, 2))
zrange!(fig, (0, nothing))   # bottom at 0, top from the data
```
"""
function zrange!(fig, range; row = nothing, col = nothing, show = nothing, kwargs...)
	_axes_reject_show(show, "zrange!")
	_axes_reject_unknown(kwargs, (:row, :col), "zrange!")
	_axes_range!(fig, 'z', range; row = row, col = col, who = "zrange!")
	return nothing
end

function zrange!(
	sf::SubplotFigure,
	range;
	row = nothing,
	col = nothing,
	show = nothing,
	kwargs...,
)
	_axes_reject_show(show, "zrange!")
	_axes_reject_unknown(kwargs, (:row, :col), "zrange!")
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

# Scientific offset text (G75, matplotlib `ScalarFormatter(useMathText =
# True)`): the tick labels show `value / 10^k` and one "×10^k" label sits at
# the end of the axis. matplotlib's default `axes.formatter.limits = (-5, 6)`
# decides `:auto`: a factor is used when the largest |tick| has order of
# magnitude <= -5 or >= 6.
const _AXES_OFFSET_LIMITS = (-5, 6)
# Largest |k| accepted: 10^k must stay a finite Float64 with room for ticks.
const _AXES_OFFSET_MAX_EXPONENT = 300
# Owner name of the offset annotation ("plotlysupply:offset:<axis ref>").
const _AXES_OFFSET_NAME = "plotlysupply:offset"
# Gap in px between the tick labels and the offset text.
const _AXES_OFFSET_GAP = 3.0

_axes_offset_owner(key::Symbol) = "$(_AXES_OFFSET_NAME):$(_cmn_axis_ref(key))"

function _axes_has_offset(fig, key::Symbol)
	existing = get(_cmn_layout(fig).fields, :annotations, nothing)
	existing isa AbstractVector || return false
	owner = _axes_offset_owner(_axes_offset_label_axis(fig, key))
	return any(item -> _cmn_name_matches(_cmn_item_name(item), owner), existing)
end

# Tick label for `v / 10^k`: six (`sigdigits`) significant digits, plotly's
# minus sign.
_axes_offset_label(v::Float64; sigdigits::Int = 6) =
	replace(_axes_format_number(v; sigdigits = sigdigits), "-" => "\u2212")

# Whether a trace on Cartesian axis `key` places a coordinate `v` with
# `pred(v)` there (its `x`/`y` values; implied coordinates are numbers).
function _axes_axis_values_any(pred, fig, key::Symbol)
	p = _cmn_plot(fig)
	letter = String(key)[1]
	target_ref = _cmn_axis_ref(key)
	field = letter == 'x' ? :xaxis : :yaxis
	default_ref = string(letter)
	cache = Dict{Any, Union{Nothing, String}}()
	for trace in p.data
		trace isa GenericTrace || continue
		_cmn_trace_kind(trace, cache) == "xy" || continue
		trace_ref = get(trace.fields, field, default_ref)
		(trace_ref isa AbstractString || trace_ref isa Symbol) || continue
		String(trace_ref) == target_ref || continue
		values = get(trace.fields, Symbol(letter), nothing)
		(values isa AbstractArray || values isa Tuple) || continue
		any(pred, values) && return true
	end
	return false
end

# Whether a trace on Cartesian axis `key` places non-numeric coordinates
# (strings, dates, nested category lists) there: plotly.js then types an
# untyped ("-") axis as a date or category axis.
_axes_has_nonnumeric_data(fig, key::Symbol) = _axes_axis_values_any(
	v -> !(v === nothing || v === missing || (v isa Real && !(v isa Bool))),
	fig,
	key,
)

# Whether a trace on Cartesian axis `key` places `Date`/`DateTime` values
# there: plotly.js then types an untyped ("-") axis as a date axis.
_axes_has_date_data(fig, key::Symbol) =
	_axes_axis_values_any(v -> v isa Union{Dates.Date, Dates.DateTime}, fig, key)

# The axis type whose range bounds an axis of group `members` takes: its
# declared `axis_type`, or for an autotyped ("-") axis the type plotly.js
# derives from the data: "linear" when a trace places numbers there, "date"
# for dates (`Date`/`DateTime` or date strings), "category" for other text;
# "-" while the group has no data (numbers and dates are then accepted).
function _axes_bound_axis_type(fig, members, axis_type::AbstractString)
	axis_type == "-" || return axis_type
	is_number(v) = v isa Real && !(v isa Bool)
	is_date(v) = v isa Union{Dates.Date, Dates.DateTime} ||
		(v isa AbstractString && occursin(_PLOTLY_DATE_PATTERN, v))
	any(m -> _axes_axis_values_any(is_number, fig, m), members) && return "linear"
	any(m -> _axes_axis_values_any(is_date, fig, m), members) && return "date"
	any(m -> _axes_has_nonnumeric_data(fig, m), members) && return "category"
	return "-"
end

# What `offset` asks of axis `key` (before any write): `(values, labels, k,
# clear)`. A factor 10^k comes with the scaled tick values and labels; without
# a factor (k === nothing) `values`/`labels` pass on unchanged, and `clear`
# says the array ticks of an earlier factor are to be removed (Plotly's
# automatic ticks again; minor ticks and formats are kept).
function _axes_offset_plan(fig, key::Symbol, values, labels, offset, subs, format, exponentformat, who::AbstractString)
	(offset === :auto || offset === :none ||
		(offset isa Integer && !(offset isa Bool) && abs(offset) <= _AXES_OFFSET_MAX_EXPONENT)) ||
		throw(ArgumentError(
			"$(who): `offset` must be :auto, :none, an integer exponent k (|k| <= " *
			"$(_AXES_OFFSET_MAX_EXPONENT)) or `nothing`; got $(repr(offset)).",
		))
	if offset === :none
		return (values, labels, nothing, values === nothing && subs === nothing && _axes_has_offset(fig, key))
	end
	labels === nothing || throw(ArgumentError(
		"$(who): `offset` writes the tick labels (value / 10^k); it cannot be " *
		"combined with `labels`.",
	))
	(isempty(format) && isempty(exponentformat)) || throw(ArgumentError(
		"$(who): `offset` writes the tick labels; `format` and `exponentformat` " *
		"would be ignored by plotly.js, so they cannot be combined with it.",
	))
	(subs === nothing && !(values isa Symbol)) || throw(ArgumentError(
		"$(who): `offset` needs tick values (or the automatic 1-2-5 ticks it " *
		"computes); it cannot be combined with `subs` or a tick preset.",
	))
	layout = _cmn_layout(fig)
	axis_type = _axis_type(layout, key)
	axis_type in ("linear", "-") || throw(ArgumentError(
		"$(who): `offset` scales the labels of a linear axis; $(repr(key)) has " *
		"type $(repr(axis_type)).",
	))
	root = _axes_match_root(fig, key, who)
	axis_type == "-" && any(m -> _axes_has_nonnumeric_data(fig, m), _axes_match_members(fig, root, who)) &&
		throw(ArgumentError(
			"$(who): `offset` scales the labels of a linear axis; $(repr(key)) " *
			"shows text or date data (plotly.js makes it a category or date axis).",
		))
	# The ticks the `:auto` decision looks at (matplotlib: the visible ones).
	visible = nothing
	ticks = if values !== nothing
		(values isa AbstractVector || values isa Tuple || values isa AbstractRange) || throw(ArgumentError(
			"$(who): tick `values` must be a vector, range or tuple of numbers; got $(typeof(values)).",
		))
		out = Float64[]
		for v in values
			_is_plain_real(v) || throw(ArgumentError(
				"$(who): with `offset`, tick values must be finite numbers; got $(repr(v)).",
			))
			push!(out, Float64(v))
		end
		isempty(out) && throw(ArgumentError("$(who): `values` must not be empty."))
		out
	else
		existing = _cmn_array_tickvals(get(layout.fields, key, nothing))
		if existing !== nothing && !_axes_has_offset(fig, key) &&
			!isempty(existing) && all(_is_plain_real, existing)
			Float64.(existing)
		else
			limits = _from_axis_range(layout, root)
			limits === nothing && (limits = _axes_group_extent(fig, root, who))
			limits === nothing && throw(ArgumentError(
				"$(who): `offset` places its own ticks over the axis range; set a " *
				"range or add data to $(repr(key)) first, or pass tick values.",
			))
			lo, hi = minmax(Float64(limits[1]), Float64(limits[2]))
			lo < hi || throw(ArgumentError(
				"$(who): the axis range $(lo) .. $(hi) is empty; `offset` cannot " *
				"place ticks there.",
			))
			inner = _axes_linear_ticks(lo, hi, who)
			# numerics-10: the ticks are multiples of the 1-2-5 step m·10^e of
			# `inner`, built from integers (`_cmn_log_tick_value`, correctly
			# rounded), never from a difference of two large tick values.
			m, e = _axes_nice_step(inner[2] - inner[1])
			step = m * exp10(e)
			span = hi - lo
			# Ticks over one more span on each side: the autorange padding and
			# moderate later changes stay labelled (plotly.js draws only the
			# ticks inside the range).
			kmin, kmax = floor(Int, (lo - span) / step), ceil(Int, (hi + span) / step)
			visible = inner
			Float64[_cmn_log_tick_value(Float64(k * m), 10.0, e) for k in kmin:kmax]
		end
	end
	k = if offset === :auto
		largest = maximum(abs, something(visible, ticks))
		oom = largest == 0 ? 0 : floor(Int, log10(largest))
		(oom <= _AXES_OFFSET_LIMITS[1] || oom >= _AXES_OFFSET_LIMITS[2]) ? oom : nothing
	else
		Int(offset)
	end
	if k === nothing
		return (values, labels, nothing, values === nothing && _axes_has_offset(fig, key))
	end
	factor = exp10(k)
	return (ticks, _axes_offset_labels(ticks, factor), k, false)
end

# The 1-2-5 step (m, e), m·10^e with m in (1, 2, 5), nearest to `d` (a
# difference of two neighbouring `_axes_linear_ticks` values, which carries
# their rounding error).
function _axes_nice_step(d::Float64)
	e = floor(Int, log10(d) + 1e-9)
	m = round(Int, d / exp10(e))
	m >= 10 && return (1, e + 1)
	return (m < 2 ? 1 : m < 4 ? 2 : 5, e)
end

# numerics-10: labels `v / factor` of the ticks `ticks` with plotly's minus
# sign: six significant digits, or as many more (up to 17) as distinct tick
# values need to keep distinct labels (data with a large constant part:
# 1000000.2 and 1000000.4 under ×10^6 read "1.0000002" and "1.0000004").
function _axes_offset_labels(ticks::AbstractVector{Float64}, factor::Float64)
	scaled = Float64[v / factor for v in ticks]
	distinct = length(unique(ticks))
	for digits in 6:17
		labels = String[_axes_offset_label(v; sigdigits = digits) for v in scaled]
		length(unique(labels)) >= distinct && return labels
	end
	return String[_axes_offset_label(v; sigdigits = 17) for v in scaled]
end

# The "×10^k" annotation at the end of axis `key` of cell `t`: an x axis at
# its right end below (above, for a top axis) the tick labels, a y axis above
# its top end (right-aligned with a left axis's tick labels).
# axes-ticks-01: the axis of `key`'s shared (`matches`) group that shows the
# tick labels the factor applies to: `key` itself when it shows labels, else
# the first member that does (subplots with shared axes show the labels on
# one cell only), else `key`.
function _axes_offset_label_axis(fig, key::Symbol)
	fields = _cmn_layout(fig).fields
	shows(k) = (entry = get(fields, k, nothing);
		_cmn_mapping_get(entry, :showticklabels) !== false && _cmn_mapping_get(entry, :visible) !== false)
	shows(key) && return key
	root = _fin_match_root(fields, key)
	root === nothing && return key
	letter = String(key)[1]
	members = sort!(
		Symbol[k for k in keys(fields) if _fin_is_axis_key(k) && String(k)[1] == letter && _fin_match_root(fields, k) === root];
		by = k -> (length(String(k)), String(k)),
	)
	for k in members
		shows(k) && return k
	end
	return key
end

# The factor annotation of axis `key` (the labelled axis of its group): in
# the domain of `key` and of the axis it is anchored to.
function _axes_offset_annotation(fig, t::_CellTarget, key::Symbol, letter::Char, k::Int)
	layout = _cmn_layout(fig)
	entry = get(layout.fields, key, nothing)
	anchor = _cmn_mapping_get(entry, :anchor)
	own_ref = _cmn_axis_ref(key)
	other_ref = anchor isa AbstractString && occursin(r"^[xy]\d*$", anchor) ? String(anchor) :
		(letter == 'x' ? t.yref : t.xref)
	xref, yref = letter == 'x' ? (own_ref, other_ref) : (other_ref, own_ref)
	root_size = _tight_root_font_size(name -> get(layout.fields, name, nothing))
	tickfont = _cmn_mapping_get(entry, :tickfont)
	size = _axes_size(_cmn_mapping_get(tickfont, :size), root_size)
	ticks = _cmn_mapping_get(entry, :ticks)
	ticklen = ticks == "outside" ? _axes_size(_cmn_mapping_get(entry, :ticklen), _AXES_PLOTLY_TICKLEN) : 0.0
	side = _cmn_mapping_get(entry, :side)
	side isa Symbol && (side = String(side))
	font = Dict{Symbol, Any}(:size => size)
	color = _cmn_mapping_get(tickfont, :color)
	color isa AbstractString && !isempty(color) && (font[:color] = color)
	fields = Dict{Symbol, Any}(
		:text => _label("\$\\times 10^{$(k)}\$"),
		:showarrow => false,
		:xref => "$(xref) domain",
		:yref => "$(yref) domain",
		:font => attr(; font...),
	)
	if letter == 'x'
		top = side == "top"
		fields[:x] = 1
		fields[:xanchor] = "right"
		fields[:y] = top ? 1 : 0
		fields[:yanchor] = top ? "bottom" : "top"
		depth = ticklen + _AXES_LINE_HEIGHT_EM * size + _AXES_OFFSET_GAP
		fields[:yshift] = top ? depth : -depth
	else
		right = side == "right"
		fields[:x] = right ? 1 : 0
		fields[:xanchor] = right ? "left" : "right"
		fields[:y] = 1
		fields[:yanchor] = "bottom"
		fields[:yshift] = _AXES_OFFSET_GAP
	end
	return attr(; fields...)
end

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
	offset = nothing,
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
	key = letter == 'x' ? t.xkey : t.ykey
	exponent = nothing
	clear = false
	if offset !== nothing
		values, labels, exponent, clear = _axes_offset_plan(
			fig, key, values, labels, offset, subs, format, exponentformat, who,
		)
	end
	# New tick values (or a preset/`subs`) replace the labels a factor wrote,
	# so a factor that `offset` does not write again is removed.
	drop_factor = exponent === nothing &&
		(clear || values !== nothing || subs !== nothing) && _axes_has_offset(fig, key)
	_apply_ticks!(
		fig,
		key;
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
	clear && _cmn_delete_layout_fields!(fig, key, (:tickmode, :tickvals, :ticktext))
	label_key = _axes_offset_label_axis(fig, key)
	if exponent !== nothing
		_upsert_named!(
			fig,
			:annotations,
			_axes_offset_owner(label_key),
			[_axes_offset_annotation(fig, t, label_key, letter, exponent)];
			who = who,
		)
	elseif drop_factor
		_upsert_named!(fig, :annotations, _axes_offset_owner(label_key), Any[]; who = who)
	end
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
  the major length, on the side of the major ticks; on a log axis with
  explicit major ticks at mantissas 1..9 of every decade); `false` removes
  them; `nothing` leaves them. A new `direction` turns the minor ticks too.
- `angle::Union{Nothing,Real} = nothing`: tick-label angle in degrees,
  positive CLOCKWISE (plotly's `tickangle`: `angle = 45` makes the labels
  run down to the right). matplotlib's `rotation = 45` is counter-clockwise,
  so it corresponds to `angle = -45`.
- `direction = ""`: `"inside"`, `"outside"`, `"none"` (no tick marks, minor
  ticks included; matplotlib `tick_params(length = 0)`), or the Symbols; `""`
  keeps it. plotly.js has no ticks crossing the axis line (matplotlib
  `"inout"`), so `:both`/`:inout` are an `ArgumentError`. Ticks on the top
  and right frame lines: [`spines!`](@ref)`(fig; ticks = :mirror)`.
- `tickwidth::Real = 0`, `ticklen::Real = 0`: major tick width/length in px
  (0 keeps them); explicit minor ticks follow the new length.
- `offset = nothing`: scientific offset text (matplotlib's `×10⁻⁵` at the
  axis end, `ScalarFormatter(useMathText = True)`), linear axes only. An
  integer `k` labels the ticks with `value / 10^k` and draws one
  `"×10^k"` label (mathtext) at the right end of an x axis, below its tick
  labels, or above the top of a y axis; `:auto` does so with k the order of
  magnitude of the largest |tick| when that is <= -5 or >= 6 (matplotlib's
  default limits) and removes the factor otherwise; `:none` removes the
  factor (and the ticks it placed); `nothing` leaves it, unless the call
  sets new tick values, `subs` or a preset, which replace the scaled labels
  and so remove the factor too. The ticks are
  `values` when given, else the array ticks already on the axis, else 1-2-5
  ticks computed over the explicit range or the data when the call runs (call
  it again after changing the range a lot). The text is the annotation named
  `"plotlysupply:offset:<axis ref>"`. Cannot be combined with `labels`,
  `subs`, a preset, `format` or `exponentformat`.
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active). `inset = k` targets inset `k` (see
  [`inset!`](@ref)). Both are an `ArgumentError` on a plain figure.
"""

"""
	xticks!(fig, values=nothing, labels=nothing; format="", exponentformat="", subs=nothing, minor=nothing, angle=nothing, direction="", tickwidth=0, ticklen=0, offset=nothing, row=nothing, col=nothing, inset=nothing)
	xticks!(sf::SubplotFigure, values=nothing, labels=nothing; ...)

Set the x-axis ticks of a figure, of one SubplotFigure cell or of an inset.
Only that axis changes (other cells keep their ticks).

# Arguments
- `values`: tick positions in DATA units, also on log axes (vector, range or
  tuple; strings on category axes). Sets `tickmode = "array"`. Or a preset:
  - `:decades` (logarithmic axes only): labels at powers of ten only
    (1, 10, 10², …, matplotlib's look) with unlabelled minor ticks.
    Every decade is labelled up to 8 decades; a longer axis labels every
    k-th decade, k = ceil(n/8), and the minor ticks mark the decades in
    between (on ≤ 8 decades they mark 2..9). n is taken from the explicit
    axis range, else from the data on the axis, when the call runs: call it
    again after changing the range a lot. Writes `tickmode = "linear"`,
    `tick0 = 0`, `dtick = k`, `exponentformat = "power"` (or the
    `exponentformat` keyword) and `minor` (`dtick` `"D1"` or 1; `minor =
    false` omits it). A d3 `format` set earlier still takes precedence.
    Without the preset, Plotly's automatic log ticks label intermediate
    digits ("2", "5") on axes spanning less than about 4-7 decades. An axis
    spanning less than two decades gets only one or two labels this way;
    keep the automatic ticks (or pass values) there.
  - `:auto`: back to Plotly's automatic ticks on any axis type: removes
    `tickmode`, `tickvals`, `ticktext`, `tick0`, `dtick`, the automatic
    `"~g"` format and the minor tick placement; minor ticks are switched off
    unless `minor = true`.
  A log axis without any tick setting is labelled by Plotly, except where
  its labels would collide at the size the figure is drawn (a narrow
  journal-column panel: "5678" run together): there each render (`savefig`
  included) shows decade labels with unlabelled minor ticks, as `:decades`
  does, and Plotly's labels again once they fit. Tick values, the
  `:decades` preset or a `format` set with `xticks!` make the axis's ticks
  the user's and turn this off.
  A preset cannot be combined with `labels` or `subs`.
- `labels`: one label per value; each goes through the mathtext layer, so a
  TeX label such as `L"\\pi/2"` (LaTeXStrings) typesets. Without labels,
  numeric ticks on a linear axis are printed with the d3 format `"~g"`
  (0.0025, 16) unless a format is set; values outside 10⁻³ ≤ |v| < 10⁵
  (zero aside) are labelled in the axis's power exponent format instead
  (2×10⁶, 2.5×10⁻⁷; never computer e-notation); a logarithmic axis keeps
  Plotly's power exponent format (1×10⁻⁶ … 1000 …).

$(_AXES_TICKS_DOC_KEYWORDS)
Errors (`ArgumentError`, before anything changes): mismatched label count,
non-finite or (log axis) non-positive values, `subs` on a linear axis,
`:decades` on a non-logarithmic axis, an unknown preset Symbol, an unknown
`exponentformat`/`direction`, a non-xy cell. Returns `nothing` (`sf` for a
SubplotFigure).

# Example
```julia
x = collect(range(0, 2π; length = 100))
fig = plot_scatter(x, sin.(x))
xticks!(fig, [0, π/2, π, 3π/2, 2π], ["0", "π/2", "π", "3π/2", "2π"])
lg = plot_scatter([4, 8, 16, 32], [1.0, 2, 3, 4]; xscale = "log")
xticks!(lg, 2 .^ (2:5); minor = true)
f = plot_scatter([1e-3, 1e5], [1.0, 2.0]; xscale = "log")
xticks!(f, :decades)     # 10⁻³ … 10⁵, minor ticks at 2..9
xticks!(f, :auto)        # Plotly's automatic ticks again
```
"""
function xticks!(fig, values = nothing, labels = nothing; show = nothing, kwargs...)
	_axes_reject_show(show, "xticks!")
	_axes_reject_unknown(kwargs, _AXES_TICKS_KEYWORDS, "xticks!")
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
	_axes_reject_unknown(kwargs, _AXES_TICKS_KEYWORDS, "xticks!")
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
	yticks!(fig, values=nothing, labels=nothing; format="", exponentformat="", subs=nothing, minor=nothing, angle=nothing, direction="", tickwidth=0, ticklen=0, offset=nothing, row=nothing, col=nothing, inset=nothing, secondary_y=false)
	yticks!(sf::SubplotFigure, values=nothing, labels=nothing; ...)

Set the y-axis ticks; identical to [`xticks!`](@ref) for the y axis:
`values` in DATA units (also on log axes), or the presets `:decades` (log
axes: labels at powers of ten only, unlabelled minor ticks) and `:auto`
(Plotly's automatic ticks again).
`secondary_y = true` targets the secondary y axis (a twin created by a
`secondary_y=true` plot call, or a `Spec(secondary_y=true)` subplot cell).

$(_AXES_TICKS_DOC_KEYWORDS)- `secondary_y::Bool = false`: target the secondary y axis.

Returns `nothing` (`sf` for a SubplotFigure).

# Example
```julia
fig = plot_scatter([1e-3, 1e3], [1e-2, 1e4]; xscale = "log", yscale = "log")
yticks!(fig; subs = (1, 2, 5), minor = true)
yticks!(fig, :decades)
small = plot_scatter(1:10, 1e-5 .* rand(10))
yticks!(small; offset = :auto)   # labels 0..1 and "×10⁻⁵" above the axis
```
"""
function yticks!(fig, values = nothing, labels = nothing; show = nothing, kwargs...)
	_axes_reject_show(show, "yticks!")
	_axes_reject_unknown(kwargs, _AXES_YTICKS_KEYWORDS, "yticks!")
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
	_axes_reject_unknown(kwargs, _AXES_YTICKS_KEYWORDS, "yticks!")
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
# Log-axis tick labels: the paper-style rule (W7) and narrow axes (Z70)
# ---------------------------------------------------------------------------
#
# plotly.js 2.35.2 labels an automatic log axis (axes.js `calcTicks` /
# `autoTicks`, read in the bundled plotly.min.js): with nt = clamp(L / m, 4,
# 9) + 1 for an axis of L px (m = 80 on x, 40 on y) and e = (decades shown) /
# nt, the tick step is `ceil(e)` decades when e > 0.7, linear ticks ("L")
# when less than one decade is shown, else "D2" (labels at 1, 2, 5 of every
# decade) for e > 0.3 and "D1" (1, 2, ..., 9). Decade labels in the power
# format are drawn at 1.25 x the tick font, the digit labels of "D1"/"D2" at
# 0.75 x; under "D1" a decade label on an x axis moves right by 0.5
# (negative exponent) or 0.25 of its font size. nt ignores the label widths,
# so on a narrow axis (a journal column) the digit labels run into each
# other and into the decade labels (publication-style rep/small/aps.png: the
# "2" after 10⁻¹, "5678" read as one number).
#
# `_axes_log_tick_updates!` (run by `_finalize_figure!` after every mutation
# and on the export copy at its real size) therefore gives a log axis with no
# tick setting decade labels every k decades and unlabelled minor ticks at
# the other digits when
# - the active style says so (`_style_log_ticks() == :decades`, D15 rule 2:
#   `:publication` and the journal presets) and the axis shows two decade ticks
#   (10ⁿ) or more (W7), or
# - plotly's automatic labels would overlap at the axis's estimated length
#   (Z70; matplotlib labels no minor ticks on an axis spanning more than one
#   decade either);
# with k = ceil(decades / 8) (lead decision D9), raised until neighbouring
# decade labels clear each other. What it writes has its own signature
# (`_axes_is_fitted_decades`: `tick0`/`dtick` without `tickmode`), so later
# runs re-fit k, and hand the axis back to plotly's labels (removing exactly
# those fields) once they fit again. An axis with any tick setting of the
# user's, `xticks!(fig, :decades)` included, is never touched.
#
# Axis fields that place ticks or format their labels: an axis stating none
# of them shows plotly's automatic ticks.
const _AXES_TICK_PLACEMENT_KEYS = (
	:tickmode, :tickvals, :ticktext, :tick0, :dtick, :nticks, :tickformat, :ticklabelstep, :minor,
)
# plotly.js 2.35.2 log tick-label sizes relative to the tick font (formatLog).
const _AXES_LOG_DECADE_FONT = 1.25
const _AXES_LOG_DIGIT_FONT = 0.75
# Clear space (px) plotly's labels need before they collide: on an x axis
# their advance boxes (side bearings included) must not intersect; on a y axis
# their ink may touch, as on plotly's own "D1" axes at the default size ("9"
# just under "10"), but not overlap by more than 1 px. Checked against the
# label boxes plotly.js renders (scratch v5/axes/v05.jl: the modelled gaps of
# x labels are within 1.5 px of the rendered ones).
const _AXES_TICK_COLLISION_CLEARANCE_X = 0.0
const _AXES_TICK_COLLISION_CLEARANCE_Y = -1.0
# Space (in tick-font sizes) the decade labels the fit writes keep between
# each other.
const _AXES_DECADE_LABEL_GAP_EM = 0.5
# Share of the estimated axis length the label fit relies on: the estimate
# (`_fin_margins`, within 10 px of the rendered length without colorbars)
# does not see every margin push (colorbars), and an axis that comes out
# shorter must still fit its labels.
const _AXES_TICK_LENGTH_SAFETY = 0.95
# Vertical ink of a tick label on a y axis, in units of its font size s,
# from plotly.js 2.35.2 (svg_text_utils / axes.js): the baseline sits
# MID_SHIFT = 0.35 s below the tick, digits rise 0.72 s (cap height) above
# the baseline, and a `<sup>` (font 70 %, dy -0.6 em) tops out at
# 0.42 s + 0.72 x 0.7 s = 0.92 s above it.
const _AXES_TICK_BELOW = 0.35
const _AXES_TICK_DIGIT_ABOVE = 0.37
const _AXES_TICK_SUP_ABOVE = 0.57
# Decade ticks (10ⁿ) a log axis must show for decade-only labels under the
# paper styles (D15 rule 2, refined in wave 7: 5e1..2e3 shows 10² and 10³
# and is labelled with them alone, not plotly's "2", "5" digits between).
const _AXES_STYLE_DECADES_MIN_TICKS = 2
# Number of decade ticks (integer log10 values) on a log axis showing
# [a, b] (log10), ends included up to 1e-9 decades.
_axes_decade_tick_count(a::Float64, b::Float64) =
	max(0, floor(Int, b + 1e-9) - ceil(Int, a - 1e-9) + 1)
# Padding plotly.js gives an autoranged scatter axis, as a share of the data
# span on each side: 5 % of the axis length per side, the data filling 90 %.
const _AXES_AUTORANGE_PAD = 0.05 / 0.9

_axes_real_value_or(value, default) =
	(value isa Real && !(value isa Bool) && isfinite(value)) ? Float64(value) : default

# Whether an axis's `minor` entry states anything (`relayout!` leaves removed
# attributes behind as `nothing`).
function _axes_minor_stated(minor)
	minor === nothing && return false
	minor isa PlotlyBase.PlotlyAttribute && (minor = minor.fields)
	minor isa AbstractDict || return true
	return any(v -> v !== nothing, values(minor))
end

_axes_is_whole_number(value, low::Real) =
	value isa Real && !(value isa Bool) && isfinite(value) && isinteger(value) && value >= low

# Whether the tick fields of `axis` are the signature `_axes_log_tick_updates!`
# writes: `tick0 = 0` and an integer decade step `dtick` WITHOUT `tickmode`
# (plotly.js then takes tickmode "linear"; the `:decades` preset of
# `_apply_ticks!` states `tickmode = "linear"`, so a user's preset never
# matches), and a minor placement `tickmode = "linear"`, `tick0 = 0`,
# `dtick = "D1"` or 1.
function _axes_is_fitted_decades(axis; linear_mode::Bool = false)
	mode = _cmn_mapping_get(axis, :tickmode)
	(mode === nothing || (linear_mode && mode == "linear")) || return false
	_axes_real_value_or(_cmn_mapping_get(axis, :tick0), NaN) == 0 || return false
	_axes_is_whole_number(_cmn_mapping_get(axis, :dtick), 1) || return false
	for key in (:tickvals, :ticktext, :nticks, :tickformat, :ticklabelstep)
		_cmn_mapping_get(axis, key) === nothing || return false
	end
	minor = _cmn_mapping_get(axis, :minor)
	_cmn_mapping_get(minor, :tickmode) == "linear" || return false
	_axes_real_value_or(_cmn_mapping_get(minor, :tick0), NaN) == 0 || return false
	(_cmn_mapping_get(minor, :tickvals) === nothing && _cmn_mapping_get(minor, :nticks) === nothing) ||
		return false
	minor_dtick = _cmn_mapping_get(minor, :dtick)
	return minor_dtick == "D1" || (_axes_is_whole_number(minor_dtick, 1) && minor_dtick == 1)
end

# `:auto` (no tick setting: plotly's automatic ticks), `:fitted` (the decade
# ticks `_axes_log_tick_updates!` wrote) or `:user` (any other tick setting,
# the `:decades` preset of `xticks!` included).
function _axes_log_tick_state(axis)
	stated(key) = key === :minor ? _axes_minor_stated(_cmn_mapping_get(axis, :minor)) :
		_cmn_mapping_get(axis, key) !== nothing
	any(stated, _AXES_TICK_PLACEMENT_KEYS) || return :auto
	return _axes_is_fitted_decades(axis) ? :fitted : :user
end

# Tick-mark direction of axis `key` ("inside", "outside" or "" for none): its
# own `ticks`, else its template's, else plotly's default "".
function _axes_tick_direction(layout::Layout, key::Symbol)
	ticks = _cmn_mapping_get(get(layout.fields, key, nothing), :ticks)
	ticks === nothing &&
		(ticks = _cmn_mapping_get(_axes_template_entry(layout, Symbol(String(key)[1], "axis")), :ticks))
	return ticks in ("inside", "outside") ? String(ticks) : ""
end

# plotly.js's automatic choice for a log axis of `len` px showing `span`
# decades (see the comment above): an integer decade step, :D1, :D2, or
# :linear.
function _axes_plotly_log_dtick(span::Float64, len::Float64, letter::Char)
	nt = clamp(len / (letter == 'y' ? 40.0 : 80.0), 4.0, 9.0) + 1.0
	e = span / nt
	e > 0.7 && return ceil(Int, e)
	span < 1 && return :linear
	return e > 0.3 ? :D2 : :D1
end

# Whether plotly writes the label of decade `n` in the power format: the
# "power" exponent format, and the default "B" and "SI" ones past 10¹⁴ or
# under 10⁻¹⁵ (plotly formatLog).
_axes_power_decade(n::Int, exponentformat) =
	exponentformat == "power" ||
	((exponentformat === nothing || exponentformat in ("B", "SI")) && (n > 14 || n < -15))

# Text of the label of decade `n` (plotly formatLog / numFormat): "10ⁿ" in
# the power format (1 and 10 written out); "1e+n" in the "e"/"E" formats past
# two digits; an SI prefix ("1k", "100μ") in "B"/"SI" from the thousands on;
# else the number.
function _axes_decade_label(n::Int, exponentformat)
	if _axes_power_decade(n, exponentformat)
		n == 0 && return "1"
		n == 1 && return "10"
		return "10<sup>" * (n < 0 ? "−" : "") * string(abs(n)) * "</sup>"
	end
	if exponentformat in ("e", "E") && abs(n) > 2
		return "1" * exponentformat * (n > 0 ? "+" : "−") * string(abs(n))
	end
	if (exponentformat === nothing || exponentformat in ("B", "SI")) && abs(n) >= 3
		group = fld(n, 3)
		prefixes = Dict(-5 => "f", -4 => "p", -3 => "n", -2 => "μ", -1 => "m", 1 => "k", 2 => "M",
			3 => exponentformat == "SI" ? "G" : "B", 4 => "T")
		prefix = get(prefixes, group, nothing)
		prefix === nothing || return "1" * "0"^(n - 3 * group) * prefix
	end
	return _axes_format_number(exp10(Float64(n)))
end

# Font size (px) plotly draws the label of decade `n` at: 1.25 x the tick
# font `f` in the power format (also "1" and "10"), else `f`.
_axes_decade_font(n::Int, exponentformat, f::Float64) =
	_axes_power_decade(n, exponentformat) ? _AXES_LOG_DECADE_FONT * f : f

# Extent (px) of a tick label of text `text` drawn at font `s` on an axis of
# direction `letter`, towards lower and towards higher data values, measured
# from its tick: half its width each way on an x axis; its ink below and
# above the tick on a y axis (swapped on a reversed y axis).
function _axes_tick_label_extent(text::AbstractString, s::Float64, letter::Char, reversed::Bool)
	if letter == 'x'
		half = _text_extent(text, s)[1] / 2
		return (half, half)
	end
	above = (occursin("<sup>", text) ? _AXES_TICK_SUP_ABOVE : _AXES_TICK_DIGIT_ABOVE) * s
	below = _AXES_TICK_BELOW * s
	return reversed ? (above, below) : (below, above)
end

# The rows of labels (each: position px along the axis in increasing data
# order, extent towards lower values, extent towards higher values) plotly
# draws for `choice` (`_axes_plotly_log_dtick`, or an integer decade step)
# on a log axis showing [a, b] (log10) over `len` px; `reversed` for a
# reversed axis. Labels in different rows cannot collide: under "D1" plotly
# lowers the decade labels of an x axis by half their font size, below the
# digit labels, where only a superscript (the "−1" of 10⁻¹) reaches up into
# the digits' row.
function _axes_log_tick_labels(choice, a::Float64, b::Float64, len::Float64, letter::Char,
	f::Float64, exponentformat, reversed::Bool)
	digits = NTuple{3, Float64}[]
	decades = NTuple{3, Float64}[]
	choice === :linear && return (digits, decades)
	ppd = len / (b - a)
	toward_high = reversed ? -1.0 : 1.0
	lowered = choice === :D1 && letter == 'x'
	for n in floor(Int, a):ceil(Int, b)
		if a - 1e-9 <= n <= b + 1e-9 && (!(choice isa Integer) || mod(n, choice) == 0)
			text = _axes_decade_label(n, exponentformat)
			s = _axes_decade_font(n, exponentformat, f)
			lo, hi = _axes_tick_label_extent(text, s, letter, reversed)
			# plotly formatLog under "D1": a decade label moves along an x axis
			# by 0.5 s (negative exponent) or 0.25 s towards higher values, and
			# a plain-number one up a y axis by s / 6.
			shift = choice !== :D1 ? 0.0 :
				letter == 'x' ? s * (n < 0 ? 0.5 : 0.25) :
				_axes_power_decade(n, exponentformat) ? 0.0 : toward_high * s / 6
			centre = (n - a) * ppd + shift
			if lowered
				push!(decades, (centre, lo, hi))
				sup = match(r"<sup>(.*)</sup>", text)
				if sup !== nothing
					w = s * _TEXT_SCRIPT_SCALE * _text_plain_em(sup.captures[1])
					push!(digits, (centre + hi - w / 2, w / 2, w / 2))
				end
			else
				push!(digits, (centre, lo, hi))
			end
		end
		choice isa Integer && continue
		for m in (choice === :D1 ? (2:9) : (2, 5))
			position = n + log10(m)
			a - 1e-9 <= position <= b + 1e-9 || continue
			lo, hi = _axes_tick_label_extent(string(m), _AXES_LOG_DIGIT_FONT * f, letter, reversed)
			push!(digits, ((position - a) * ppd, lo, hi))
		end
	end
	return (sort!(digits; by = first), sort!(decades; by = first))
end

# Whether neighbouring labels in a row of `rows` (`_axes_log_tick_labels`)
# come closer than `clearance` px.
function _axes_tick_labels_overlap(rows, clearance::Float64)
	for labels in rows, i in 2:length(labels)
		(p0, _, hi0), (p1, lo1, _) = labels[i - 1], labels[i]
		p1 - p0 < hi0 + lo1 + clearance && return true
	end
	return false
end

# Decade step of the decade labels on a log axis showing [a, b] over `len`
# px: D9's ceil(n / 8), raised until neighbouring decade labels keep
# `_AXES_DECADE_LABEL_GAP_EM` between them (never past the decades shown, so
# one label always remains).
function _axes_decade_step(a::Float64, b::Float64, len::Float64, letter::Char, f::Float64,
	exponentformat, reversed::Bool)
	step = max(1, ceil(Int, (b - a) / _CMN_DECADES_MAX_LABELS))
	limit = max(step, floor(Int, b - a))
	gap = _AXES_DECADE_LABEL_GAP_EM * f
	while step < limit &&
		_axes_tick_labels_overlap(_axes_log_tick_labels(step, a, b, len, letter, f, exponentformat, reversed), gap)
		step += 1
	end
	return step
end

# Tick font size (px) of axis `key`: its `tickfont.size`, else the template's,
# else the layout font size.
function _axes_tick_font(layout::Layout, key::Symbol)
	root = _tight_root_font_size(k -> get(layout.fields, k, nothing))
	template_axis = _axes_template_entry(layout, Symbol(String(key)[1], "axis"))
	return _axes_size(
		_cmn_mapping_get(_cmn_mapping_get(get(layout.fields, key, nothing), :tickfont), :size),
		_axes_size(_cmn_mapping_get(_cmn_mapping_get(template_axis, :tickfont), :size), root),
	)
end

# What the axis fits of `_axes_finalize_updates!` read: the extents of the
# traces on every axis (`_fin_collect_axes`), the figure size `W` x `H` and
# the estimated plot area (px, `_fin_margins`): its size `Wp` x `Hp` and its
# left and bottom margins `ml`, `mb`.
struct _AxesFitPlan
	accs   # the `_FinAxes` of `_fin_collect_axes` (untyped: finalize.jl is included after this file)
	W::Float64
	H::Float64
	Wp::Float64
	Hp::Float64
	ml::Float64
	mb::Float64
end

function _axes_fit_plan(p::Plot, size, accs = _fin_collect_axes(p))
	W, H = Float64(size[1]), Float64(size[2])
	margins = _fin_margins(p.layout, accs, W, H, Dict{Symbol, Any}(), ())
	return _AxesFitPlan(
		accs,
		W,
		H,
		max(W - margins.l - margins.r, 1.0),
		max(H - margins.t - margins.b, 1.0),
		Float64(margins.l),
		Float64(margins.b),
	)
end

_axes_has_log_axis(layout::Layout) =
	any(k -> _fin_is_axis_key(k) && _fin_axis_type(layout, k) == "log", keys(layout.fields))

# Plot-area length (px) of axis `key` under `plan`.
function _axes_plan_length(layout::Layout, plan::_AxesFitPlan, key::Symbol)
	domain = _fin_domain(layout, key)
	return (domain[2] - domain[1]) * (String(key)[1] == 'x' ? plan.Wp : plan.Hp)
end

"""
	_axes_finalize_updates!(updates, p::Plot, size, accs = nothing) -> updates

The axis fits `_finalize_figure!` runs for a figure of `size = (width,
height)` px, after every mutation and on the export copy: log-axis tick
labels (`_axes_log_tick_updates!`, W7/Z70) and the room of bar labels drawn
outside their bars (`_axes_bar_label_updates!`). Figures with neither a log
axis nor such labels return at once, without reading the trace data. `accs` is the run's
`_fin_collect_axes(p)` when the caller already has it, so the extents are not
collected a second time.
"""
function _axes_finalize_updates!(updates::Dict{Symbol, Any}, p::Plot, size, accs = nothing)
	_axes_log_leftover_updates!(updates, p.layout)
	_axes_title_gap_updates!(updates, p.layout)
	has_log = _axes_has_log_axis(p.layout)
	has_labels = _axes_has_outside_bar_text(p)
	(has_log || has_labels) || return updates
	plan = accs === nothing ? _axes_fit_plan(p, size) : _axes_fit_plan(p, size, accs)
	has_log && _axes_log_tick_updates!(updates, p, plan)
	has_labels && _axes_bar_label_updates!(updates, p, plan)
	return updates
end

# ---------------------------------------------------------------------------
# D24: the axis-title gap of the sized styles
# ---------------------------------------------------------------------------
#
# plotly.js puts an axis title `title.standoff` px (plotly_white: 15) beyond
# the tick labels' depth, measured to the title's baseline (bottom, right) or
# its centre line (left, top), so the clear gap between the boxes was about
# 1.4 em of a journal style's 8 pt title, and it depends on the family, the
# side and, for MathJax, on the height of the expression. Under a style with
# a `title_gap` (`_style_title_gap`: 0.5 em for the sized styles) every
# Cartesian axis with a title gets
#
# - `title.standoff`: plotly's automargin, and the room estimates that follow
#   it (`_fin_title_push`), reserve `_depth + standoff + 0.7 f` (plus 1.3 f
#   per extra line) for the title, so the standoff is what makes that hold
#   the title as drawn at the gap (`_AXES_TITLE_GAP_RESERVE_EM`, more for
#   MathJax); a title that does not fit its margin is stopped at the paper
#   edge, nearer than the gap;
# - a record `layout.meta["plotlysupply:titlegap"]` (axis key => [standoff,
#   gap px]). plotly.js (src/plotlyjs_compat_asset.jl, the D24 title seams)
#   then moves a recorded title, once it is drawn, so that its box sits
#   exactly that many px beyond the union of the tick-label boxes: plain,
#   MathJax, wrapped and multi-line titles alike, on every side, whatever
#   the tick angle or axis type.
#
# A standoff that differs from the recorded one is the user's (it wins: the
# record is dropped and plotly places the title as usual); ours is removed
# again when the style has no gap or the title goes.

const _AXES_TITLE_GAP_META_KEY = Symbol("plotlysupply:titlegap")
# A plain title box is 1.125 em (Times, Arial, Helvetica) to 1.214 em (Open
# Sans) high (render probe j4); plotly reserves standoff + 0.7 em of it, so
# the standoff is the gap plus 0.55 em (with standoff 20 px, plotly itself
# drew the box 0.07-0.34 em nearer than the standoff, probe j3: the seam
# moves it in to the gap).
const _AXES_TITLE_GAP_RESERVE_EM = 0.55
# Room (em) a MathJax title gets beyond its estimated height (see
# `_axes_title_gap_updates!`): the largest excess drawn over a plain line.
const _AXES_TITLE_GAP_MATH_EM = 0.45

# Whether `key` names a Cartesian axis of a layout (xaxis, yaxis5, ...).
_axes_is_cartesian_key(key) = key isa Symbol && occursin(r"^[xy]axis([1-9][0-9]*)?$", String(key))

# The title gap record of `layout`: axis key (String) => (standoff, gap px).
function _axes_title_gap_record(layout::Layout)
	raw = _fin_meta_get(layout, _AXES_TITLE_GAP_META_KEY)
	out = Dict{String, Tuple{Float64, Float64}}()
	raw isa PlotlyBase.PlotlyAttribute && (raw = raw.fields)
	raw isa AbstractDict || return out
	for (k, v) in raw
		(v isa AbstractVector && length(v) == 2 && all(_fin_isfinite_real, v)) || continue
		out[String(k)] = (Float64(v[1]), Float64(v[2]))
	end
	return out
end

# Whether `layout` may need title gaps written or removed: its style has a
# gap, or it carries a record (so ours can be removed). Cheap: the style is
# in scope, the record one lookup.
_axes_wants_title_gaps(layout::Layout) =
	_style_title_gap(_active_style()) !== nothing ||
	_fin_meta_get(layout, _AXES_TITLE_GAP_META_KEY) !== nothing

# The size (px) plotly.js draws the title of axis `key` at: its own
# `title.font.size`, the template's for the axis letter, else round(1.2 x)
# the layout font size (plotly's `bigFont`).
function _axes_title_font_size(layout::Layout, key::Symbol, axis)
	own = _cmn_mapping_get(_cmn_mapping_get(_cmn_mapping_get(axis, :title), :font), :size)
	_fin_isfinite_real(own) && own > 0 && return Float64(own)
	template_axis = _axes_template_entry(layout, String(key)[1] == 'x' ? :xaxis : :yaxis)
	inherited = _cmn_mapping_get(_cmn_mapping_get(_cmn_mapping_get(template_axis, :title), :font), :size)
	_fin_isfinite_real(inherited) && inherited > 0 && return Float64(inherited)
	return Float64(round(_AXES_TITLE_FONT_FACTOR * _fin_font_size(layout)))
end

"""
	_axes_title_gap_updates!(updates, layout::Layout) -> updates

D24 (see the comment above): add to `updates` (`relayout!` keys, `nothing`
removes) the `title.standoff` of every titled Cartesian axis of `layout` under
the scoped style's `title_gap`, and write the matching record into
`layout.meta` in place. A standoff the user set is kept; ours is removed when
the style has no gap or the axis no title. A hidden axis keeps what it has.
"""
function _axes_title_gap_updates!(updates::Dict{Symbol, Any}, layout::Layout)
	gap_em = _style_title_gap(_active_style())
	record = _axes_title_gap_record(layout)
	gap_em === nothing && isempty(record) && return updates
	fresh = Dict{String, Tuple{Float64, Float64}}()
	wraps = nothing
	for (key, axis) in layout.fields
		_axes_is_cartesian_key(key) || continue
		name = String(key)
		rec = get(record, name, nothing)
		standoff = _cmn_mapping_get(_cmn_mapping_get(axis, :title), :standoff)
		ours = rec !== nothing && _fin_isfinite_real(standoff) && Float64(standoff) == rec[1]
		if _cmn_mapping_get(axis, :visible) === false
			ours && (fresh[name] = rec)
			continue
		end
		if gap_em === nothing || isempty(_fin_title_text(axis))
			ours && (updates[Symbol(key, :_title_standoff)] = nothing)
			continue
		end
		# A standoff of the user's wins (ours, if any, was replaced); the one
		# the title wrap writes with its line breaks (`_FIN_WRAP_STANDOFF`) is
		# not the user's.
		wrap_standoff = _fin_isfinite_real(standoff) && standoff == _FIN_WRAP_STANDOFF &&
			haskey(wraps === nothing ? (wraps = _fin_wrap_record(layout)) : wraps, name)
		(standoff === nothing || ours || wrap_standoff) || continue
		size = _axes_title_font_size(layout, key, axis)
		# A MathJax title taller than its plain line (a fraction, a root, a
		# script) is drawn by the seam at the same gap, but plotly reserves
		# margin by the standoff: the standoff takes the excess of its
		# estimated height, so the margin holds the title (the seam then moves
		# it in to the gap) instead of the paper edge capping the move.
		# The estimate runs short for scripts and delimiters (drawn 1.2-1.53 em
		# against 1.125 em for a plain line, render probe j4), so a MathJax
		# title also gets `_AXES_TITLE_GAP_MATH_EM`.
		text = _fin_title_text(axis)
		extra = occursin('$', text) ?
			max(0.0, _text_extent(text, size)[2] - _AXES_LINE_HEIGHT_EM * size * (1 + count(_FIN_LINE_BREAK, text))) +
			_AXES_TITLE_GAP_MATH_EM * size : 0.0
		# Rounded to 0.01 px so the value survives a JSON round trip as it is.
		want = round((gap_em + _AXES_TITLE_GAP_RESERVE_EM) * size + extra; digits = 2)
		gap = round(gap_em * size; digits = 2)
		if !(ours && rec[1] == want)
			title = _cmn_mapping_get(axis, :title)
			# A title given as a bare string becomes {text, standoff}.
			title isa AbstractString ?
				(updates[Symbol(key, :_title)] = Dict{Symbol, Any}(:text => String(title), :standoff => want)) :
				(updates[Symbol(key, :_title_standoff)] = want)
		end
		fresh[name] = (want, gap)
	end
	if fresh != record
		value = isempty(fresh) ? nothing :
			Dict{Any, Any}(Symbol(k) => Any[v[1], v[2]] for (k, v) in fresh)
		_fin_meta_set!(layout, _AXES_TITLE_GAP_META_KEY, value)
	end
	return updates
end

# ---------------------------------------------------------------------------
# Room for bar value labels drawn outside the bars
# (oned-bar-text-clipped, vm-10)
# ---------------------------------------------------------------------------
#
# plotly.js leaves the text of a bar with `textposition = "outside"` out of
# the autorange, and clips it at the plot area (`cliponaxis`): the label of
# the tallest bar was cut at the top, and under the boxed journal styles it
# was struck through by the top spine and its mirrored ticks. The finalizer
# gives every automatically ranged value axis with such labels the room of
# one label beyond its extreme bars (`autorangeoptions.include`), at the
# figure's size, as the log-tick fit does.

# plotly.js 2.35 bar text offset from the bar end (bar/plot.js TEXTPAD).
const _AXES_BAR_TEXT_PAD = 3.0
# Clear space (px) between a label and the edge of the plot area.
const _AXES_BAR_LABEL_CLEARANCE = 3.0
# Largest share of the axis length the labels may claim (a figure too small
# for that keeps plotly's range).
const _AXES_BAR_LABEL_MAX_SHARE = 0.4

_axes_is_bar_trace(trace) = trace isa GenericTrace && get(trace.fields, :type, nothing) == "bar"

# Whether `trace` (a bar trace) draws text outside its bars: a `text` or
# `texttemplate` with `textposition = "outside"` (or a vector holding it).
function _axes_bar_outside_text(trace)
	_cmn_mapping_get(trace.fields, :visible) === false && return false
	position = get(trace.fields, :textposition, nothing)
	outside = position == "outside" ||
		(position isa AbstractVector && any(==("outside"), position))
	outside || return false
	text = get(trace.fields, :text, nothing)
	template = get(trace.fields, :texttemplate, nothing)
	has(value) = value !== nothing && !(value isa AbstractString && isempty(value)) &&
		!(value isa AbstractVector && isempty(value))
	return has(text) || has(template)
end

_axes_has_outside_bar_text(p::Plot) =
	any(trace -> _axes_is_bar_trace(trace) && _axes_bar_outside_text(trace), p.data)

# Ends of the bars of `trace` along its value axis (`base` added), finite
# numbers only.
function _axes_bar_ends(trace, horizontal::Bool)
	values = get(trace.fields, horizontal ? :x : :y, nothing)
	values isa AbstractVector || return Float64[]
	base = get(trace.fields, :base, nothing)
	ends = Float64[]
	for (i, v) in enumerate(values)
		(v isa Real && !(v isa Bool) && isfinite(v)) || continue
		b = base isa AbstractVector ? (i <= length(base) ? base[i] : 0) : base
		b = (b isa Real && !(b isa Bool) && isfinite(b)) ? Float64(b) : 0.0
		push!(ends, Float64(v) + b)
	end
	return ends
end

# Lowest and highest stack ends of the bars on value axis `key` (orientation
# `horizontal`) in plotly's "stack" (running sums in trace order) or
# "relative" (positive and negative values stacked apart) bar mode.
function _axes_stacked_bar_extent(p::Plot, key::Symbol, horizontal::Bool, relative::Bool)
	up = Dict{Any, Float64}()
	down = Dict{Any, Float64}()
	lo = hi = 0.0
	for trace in p.data
		_axes_is_bar_trace(trace) || continue
		(get(trace.fields, :orientation, nothing) == "h") == horizontal || continue
		_cmn_mapping_get(trace.fields, :visible) === false && continue
		ref = get(trace.fields, horizontal ? :xaxis : :yaxis, horizontal ? "x" : "y")
		ref isa Symbol && (ref = String(ref))
		(ref isa AbstractString && _axis_layout_key(ref, horizontal ? :x : :y) === key) || continue
		values = get(trace.fields, horizontal ? :x : :y, nothing)
		values isa AbstractVector || continue
		positions = get(trace.fields, horizontal ? :y : :x, nothing)
		for (i, v) in enumerate(values)
			(v isa Real && !(v isa Bool) && isfinite(v)) || continue
			at = positions isa AbstractVector && i <= length(positions) ? positions[i] : i - 1
			if relative && v < 0
				down[at] = get(down, at, 0.0) + v
				lo = min(lo, down[at])
			else
				up[at] = get(up, at, 0.0) + v
				lo, hi = min(lo, up[at]), max(hi, up[at])
			end
		end
	end
	return lo, hi
end

# The px a label of `trace` needs beyond its bar along the value axis: one
# text line on a vertical bar, the widest label on a horizontal one, plus
# plotly's text pad and a clearance.
function _axes_bar_label_room(trace, horizontal::Bool, root_font::Float64)
	font = _cmn_mapping_get(trace.fields, :outsidetextfont)
	size = _cmn_mapping_get(font, :size)
	size isa Real || (size = _cmn_mapping_get(_cmn_mapping_get(trace.fields, :textfont), :size))
	s = (size isa Real && !(size isa Bool) && size > 0) ? Float64(size) : root_font
	extent = if horizontal
		text = get(trace.fields, :text, nothing)
		labels = text isa AbstractVector ? text : (text === nothing ? () : (text,))
		widest = 0.0
		for label in labels
			widest = max(widest, _text_extent(string(label), s)[1])
		end
		# A texttemplate's text is not known here: a short number.
		widest > 0 ? widest : _text_extent("0000", s)[1]
	else
		_AXES_LINE_HEIGHT_EM * s
	end
	return extent + _AXES_BAR_TEXT_PAD + _AXES_BAR_LABEL_CLEARANCE
end

# vm-hbartext: inside ticks of the counter axis reach into the plot area at
# the ends of the value axis: its mirrored ticks at the far frame (the
# journal presets mirror inside ticks), its own ticks at the near one, where
# the labels of negative bars go. Their length is room the labels also need
# (an outside label of the longest horizontal bar was struck through by the
# mirrored y ticks under :ieee and :aps).
function _axes_bar_counter_ticks(fields, trace, horizontal::Bool, negative::Bool)
	ref = get(trace.fields, horizontal ? :yaxis : :xaxis, horizontal ? "y" : "x")
	ref isa Symbol && (ref = String(ref))
	ref isa AbstractString || return 0.0
	axis = get(fields, _axis_layout_key(ref, horizontal ? :y : :x), nothing)
	_fin_string(_cmn_mapping_get(axis, :ticks)) == "inside" || return 0.0
	mirror = _cmn_mapping_get(axis, :mirror)
	mirrored = mirror == "ticks" || mirror == "allticks"
	(mirrored || negative) || return 0.0
	len = _cmn_mapping_get(axis, :ticklen)
	return _fin_isfinite_real(len) && len >= 0 ? Float64(len) : _AXES_PLOTLY_TICKLEN
end

# vm-hbartext: the category names of horizontal bars are the y tick labels,
# which the plan's margin counts as numbers (`_fin_y_labels_px`: 0.6 em per
# character of a numeric tick): "EfficientNet-B4" took 80 px against 40
# estimated, the x axis was 40 px shorter than planned and the room for the
# value labels came out that much short. The px by which the names (measured
# with the family's glyph widths, `_text_extent`) exceed the estimate, for a
# y axis on the left at the paper edge.
function _axes_bar_category_excess(layout::Layout, plan::_AxesFitPlan, trace)
	names = get(trace.fields, :y, nothing)
	(names isa AbstractVector && !isempty(names) && any(v -> v isa AbstractString, names)) || return 0.0
	ref = get(trace.fields, :yaxis, "y")
	ref isa Symbol && (ref = String(ref))
	ref isa AbstractString || return 0.0
	ykey = _axis_layout_key(ref, :y)
	axis = get(layout.fields, ykey, nothing)
	_cmn_mapping_get(axis, :visible) === false && return 0.0
	_cmn_mapping_get(axis, :showticklabels) === false && return 0.0
	_fin_string(_cmn_mapping_get(axis, :side)) == "right" && return 0.0
	font = _fin_font_size(layout)
	tickfont = _fin_mapping_font_size(axis, :tickfont, font)
	widest = 0.0
	for name in names
		name isa AbstractString && (widest = max(widest, _text_extent(name, tickfont)[1]))
	end
	dy = _cmn_y_axis_domain(layout, ykey)
	estimated = _fin_y_labels_px(layout, plan.accs, ykey, dy, plan.Hp) - _fin_title_push(axis, font) -
		_fin_tick_len(axis) - 2
	return max(0.0, widest - estimated)
end

function _axes_bar_label_updates!(updates::Dict{Symbol, Any}, p::Plot, plan::_AxesFitPlan)
	layout = p.layout
	fields = layout.fields
	root_font = Float64(_tight_root_font_size(k -> get(fields, k, nothing)))
	# value axis key => (lowest end, highest end, lowest positive end, room px)
	needs = Dict{Symbol, NTuple{4, Float64}}()
	# value axis key => px the plot area is shorter than the plan says
	short = Dict{Symbol, Float64}()
	for trace in p.data
		(_axes_is_bar_trace(trace) && _axes_bar_outside_text(trace)) || continue
		horizontal = get(trace.fields, :orientation, nothing) == "h"
		ref = get(trace.fields, horizontal ? :xaxis : :yaxis, horizontal ? "x" : "y")
		ref isa Symbol && (ref = String(ref))
		ref isa AbstractString || continue
		key = _axis_layout_key(ref, horizontal ? :x : :y)
		ends = _axes_bar_ends(trace, horizontal)
		isempty(ends) && continue
		lo, hi = extrema(ends)
		room = _axes_bar_label_room(trace, horizontal, root_font) +
			_axes_bar_counter_ticks(fields, trace, horizontal, lo < 0)
		pos = minimum(e -> e > 0 ? e : Inf, ends)
		# Stacked bars end at their stack's sum.
		barmode = _cmn_mapping_get(fields, :barmode)
		if barmode == "stack" || barmode == "relative"
			slo, shi = _axes_stacked_bar_extent(p, key, horizontal, barmode == "relative")
			lo, hi = min(lo, slo), max(hi, shi)
		end
		horizontal && (short[key] = max(get(short, key, 0.0), _axes_bar_category_excess(layout, plan, trace)))
		if haskey(needs, key)
			a, b, c, r = needs[key]
			needs[key] = (min(a, lo), max(b, hi), min(c, pos), max(r, room))
		else
			needs[key] = (lo, hi, pos, room)
		end
	end
	for (key, (lo, hi, pos, room)) in needs
		axis = get(fields, key, nothing)
		# Only an automatic range of an axis that is its own root.
		_cmn_mapping_get(axis, :matches) === nothing || continue
		auto = _fin_field(axis, :autorange)
		explicit = _fin_range_pair(_fin_field(axis, :range)) !== nothing && (auto === false || auto === nothing)
		explicit && continue
		options = _cmn_mapping_get(axis, :autorangeoptions)
		options isa PlotlyBase.PlotlyAttribute && (options = options.fields)
		# Only autorange options this fit wrote are replaced: an `include`
		# alone, every value beyond the bars and 0 (a field's tight range, or
		# options of the user's, are kept).
		current = nothing
		if options !== nothing
			options isa AbstractDict && length(options) == 1 || continue
			current = _cmn_mapping_get(options, :include)
			(current isa AbstractVector && !isempty(current) &&
				all(v -> v isa Real && !(v isa Bool) && (v > max(hi, 0.0) || v < min(lo, 0.0)), current)) || continue
		end
		wanted = _axes_bar_label_include(layout, plan, key, lo, hi, pos, room; short = get(short, key, 0.0))
		if wanted === nothing
			# The labels no longer fit (or need no room): plotly's range.
			current === nothing || (updates[Symbol(key, :_autorangeoptions)] = nothing)
			continue
		end
		same = current isa AbstractVector && length(current) == length(wanted) &&
			all(i -> isapprox(Float64(current[i]), wanted[i]; rtol = 1e-6), eachindex(wanted))
		same || (updates[Symbol(key, :_autorangeoptions_include)] = wanted)
	end
	return updates
end

# The `autorangeoptions.include` values that leave `room` px between the
# extreme bar ends (`lo`, `hi`) and the edge of the plot area on axis `key`:
# the bar end `e` and the axis end `t` satisfy (t - e) = share * (t - b) with
# `share = room / length` and `b` the other end of the range. Linear bars
# grow from 0; on a log axis plotly ranges the bars from their lowest
# positive end `pos` less its autorange pad (`_FIN_AUTORANGE_PAD` of the axis
# length). `nothing` when the axis is not numeric, the labels would claim
# more than `_AXES_BAR_LABEL_MAX_SHARE` of it, or there are no bars to make
# room for.
function _axes_bar_label_include(layout::Layout, plan::_AxesFitPlan, key::Symbol, lo::Float64, hi::Float64, pos::Float64, room::Float64;
		short::Float64 = 0.0)
	axis_type = _fin_axis_type(layout, key)
	axis_type in ("linear", "-", "log") || return nothing
	len = _axes_plan_length(layout, plan, key) - short
	len > 1 || return nothing
	share = room / len
	share < _AXES_BAR_LABEL_MAX_SHARE || return nothing
	wanted = Float64[]
	if axis_type == "log"
		(hi > 0 && isfinite(pos) && hi > pos) || return nothing
		share + _FIN_AUTORANGE_PAD < 1 || return nothing
		span = (log10(hi) - log10(pos)) / (1 - share - _FIN_AUTORANGE_PAD)
		push!(wanted, exp10(log10(hi) + share * span))
	else
		# Bars above and below 0 both need the room: (t - b) = (top - bottom)
		# / (1 - 2 share).
		bottom, top = min(0.0, lo), max(0.0, hi)
		up, down = hi > 0, lo < 0
		sides = up + down
		(top - bottom > 0 && sides * share < 1) || return nothing
		span = (top - bottom) / (1 - sides * share)
		up && push!(wanted, top + share * span)
		down && push!(wanted, bottom - share * span)
	end
	return isempty(wanted) ? nothing : wanted
end

"""
	_axes_log_tick_updates!(updates, p::Plot, size_or_plan; mode = _style_log_ticks(p.layout)) -> updates

Add to `updates` (`relayout!` keys, `nothing` removes) the tick settings the
log axes of `p` need for a figure of `size = (width, height)` px (or an
`_AxesFitPlan`; see the comment above): decade labels on a log axis without
a tick setting when `mode == :decades` and the axis shows two decade ticks
or more, or when plotly's automatic labels would overlap; a re-fitted decade
step on an axis that has them; plotly's automatic labels back when neither
holds any more. A `matches` group is decided once (any member whose labels
would overlap) and written on every member without a tick setting of the
user's. Axes with one are never touched. Figures without a log axis cost
nothing. Idempotent.
"""
function _axes_log_tick_updates!(updates::Dict{Symbol, Any}, p::Plot, size; mode::Symbol = _style_log_ticks(p.layout))
	_axes_has_log_axis(p.layout) || return updates
	return _axes_log_tick_updates!(updates, p, _axes_fit_plan(p, size); mode = mode)
end

function _axes_log_tick_updates!(updates::Dict{Symbol, Any}, p::Plot, plan::_AxesFitPlan; mode::Symbol = _style_log_ticks(p.layout))
	layout = p.layout
	fields = layout.fields
	groups = Dict{Symbol, Vector{Symbol}}()
	for key in keys(fields)
		_fin_is_axis_key(key) || continue
		_fin_axis_type(layout, key) == "log" || continue
		root = _fin_match_root(fields, key)
		root === nothing && continue
		push!(get!(Vector{Symbol}, groups, root), key)
	end
	# style-02: the tick size of the figure's style (0: no compensation).
	style = _figure_recorded_style(layout)
	tick = style === nothing ? 0.0 : style.tick_fontsize
	for (root, members) in groups
		(root in members || !haskey(fields, root)) || push!(members, root)
		states = Dict(m => _axes_log_tick_state(get(fields, m, nothing)) for m in members)
		writable = Symbol[m for m in members if states[m] !== :user]
		view = _axes_log_view(layout, root, members, plan.accs)
		# plotly's own dtick choice per axis (an Int: decade labels only).
		choices = Dict{Symbol, Any}()
		want = false
		step = 1
		if view !== nothing
			a, b = view
			letter = String(root)[1]
			reversed = _axis_is_reversed(p, root)
			for m in members
				full = _axes_plan_length(layout, plan, m)
				full > 1 && (choices[m] = _axes_plotly_log_dtick(b - a, full, letter))
			end
			want = !isempty(writable) && mode === :decades &&
				_axes_decade_tick_count(a, b) >= _AXES_STYLE_DECADES_MIN_TICKS
			for m in writable
				axis = get(fields, m, nothing)
				_cmn_mapping_get(axis, :showticklabels) === false && continue
				_cmn_mapping_get(axis, :visible) === false && continue
				full = _axes_plan_length(layout, plan, m)
				len = _AXES_TICK_LENGTH_SAFETY * full
				len > 1 || continue
				exponentformat = _axes_exponentformat(layout, m)
				power = exponentformat == "power"
				# The labels are measured at the size they are drawn at once
				# this pass is written (the compensated font of a style's axis,
				# whatever the axis holds now), so the result does not depend on
				# an earlier pass.
				own = _axes_log_font_is_style(axis, tick)
				f = _axes_tick_font(layout, m)
				if !want
					choice = choices[m]
					f_auto = own ? (choice isa Int && power ? tick / _AXES_LOG_DECADE_FONT : tick) : f
					want = _axes_tick_labels_overlap(
						_axes_log_tick_labels(choice, a, b, len, letter, f_auto, exponentformat, reversed),
						letter == 'x' ? _AXES_TICK_COLLISION_CLEARANCE_X : _AXES_TICK_COLLISION_CLEARANCE_Y,
					)
				end
				f_decades = own && power ? tick / _AXES_LOG_DECADE_FONT : f
				step = max(step, _axes_decade_step(a, b, len, letter, f_decades, exponentformat, reversed))
			end
		end
		for m in writable
			axis = get(fields, m, nothing)
			if want
				_axes_fitted_decades_updates!(updates, layout, m, axis, step)
			elseif states[m] === :fitted
				# plotly's own labels fit again (a wider figure, fewer decades):
				# hand the axis back to them.
				for name in (:tick0, :dtick, :minor_tickmode, :minor_tick0, :minor_dtick, :minor_ticks, :minor_ticklen)
					updates[Symbol(m, :_, name)] = nothing
				end
			end
		end
		tick > 0 || continue
		for m in members
			axis = get(fields, m, nothing)
			_axes_log_font_is_style(axis, tick) || continue
			# The dtick the axis is drawn with after this pass.
			dtick = if m in writable
				want ? step : get(choices, m, nothing)
			else
				_cmn_mapping_get(axis, :tickmode) == "array" ? nothing :
					something(_cmn_mapping_get(axis, :dtick), get(choices, m, nothing))
			end
			decade_labels = (dtick isa Real && !(dtick isa Bool)) &&
				_axes_exponentformat(layout, m) == "power" &&
				isempty(something(_cmn_mapping_get(axis, :tickformat), ""))
			target = decade_labels ? tick / _AXES_LOG_DECADE_FONT : tick
			current = _cmn_mapping_get(_cmn_mapping_get(axis, :tickfont), :size)
			isapprox(current, target; rtol = 1e-9) || (updates[Symbol(m, :_tickfont_size)] = target)
		end
	end
	return updates
end

# Exponent format of axis `key`: its own, else its template's (the package
# templates state "power", D21), else `nothing` (plotly's "B").
function _axes_exponentformat(layout::Layout, key::Symbol)
	value = _cmn_mapping_get(get(layout.fields, key, nothing), :exponentformat)
	value === nothing &&
		(value = _cmn_mapping_get(_axes_template_entry(layout, Symbol(String(key)[1], "axis")), :exponentformat))
	return value === nothing ? nothing : String(value)
end

# style-02. plotly.js formatLog draws the decade labels of a power-format log
# axis with a numeric dtick at 1.25 x the tick font ("D1"/"D2" axes: the
# decades at 1.25 x, the digits at 0.75 x). Under a figure style with a tick
# size (`:publication`, the journal presets, a `fontsize`-scaled one) the
# finalizer gives such an axis `tickfont.size = tick / 1.25`, so its labels
# come out at the style's size, and the style's size back once it shows other
# labels (a "D1"/"D2" axis keeps plotly's mixed sizes: no single font size
# serves both). Only an axis whose tick font is the style's size or its
# compensated size is the finalizer's; any other size is the user's
# (`set_fonts!` on a cell, `relayout!`) and stays.
function _axes_log_font_is_style(axis, tick::Float64)
	tick > 0 || return false
	current = _cmn_mapping_get(_cmn_mapping_get(axis, :tickfont), :size)
	(current isa Real && !(current isa Bool)) || return false
	return isapprox(current, tick; rtol = 1e-9) ||
		isapprox(current, tick / _AXES_LOG_DECADE_FONT; rtol = 1e-9)
end

# axes-ticks-03. Tick state written for a log axis on an axis that is no
# longer log (a scale switch): the finalizer's fitted decades, the
# `xticks!(:decades)` preset (the same signature with `tickmode =
# "linear"`) and the compensated tick font (style-02) would draw a label at
# every unit of the linear axis (1001 labels for 0..1000) and labels at
# 0.8 x. They are removed, so the axis shows plotly's automatic ticks at the
# style's size.
function _axes_log_leftover_updates!(updates::Dict{Symbol, Any}, layout::Layout)
	fields = layout.fields
	style = nothing
	for (key, axis) in fields
		_fin_is_axis_key(key) || continue
		_fin_axis_type(layout, key) == "log" && continue
		minor = _cmn_mapping_get(axis, :minor)
		_cmn_mapping_get(minor, :tickmode) == "linear" || _cmn_mapping_get(axis, :tickfont) !== nothing || continue
		if _axes_is_decades_signature(axis)
			_cmn_mapping_get(axis, :tickmode) === nothing || (updates[Symbol(key, :_tickmode)] = nothing)
			for name in (:tick0, :dtick, :minor_tickmode, :minor_tick0, :minor_dtick, :minor_ticks, :minor_ticklen)
				updates[Symbol(key, :_, name)] = nothing
			end
		end
		style === nothing && (style = something(_figure_recorded_style(layout), false))
		style === false && continue
		tick = style.tick_fontsize
		current = _cmn_mapping_get(_cmn_mapping_get(axis, :tickfont), :size)
		(tick > 0 && current isa Real && isapprox(current, tick / _AXES_LOG_DECADE_FONT; rtol = 1e-9)) &&
			(updates[Symbol(key, :_tickfont_size)] = tick)
	end
	return updates
end

# The decade signature (`_axes_is_fitted_decades`) with or without the
# `tickmode = "linear"` of the `:decades` preset.
# The preset variant also needs a mark of the log axis it was written for (a
# minor "D1" step or the preset's own power format), so linear ticks a user
# states with the same numbers are never taken for it.
function _axes_is_decades_signature(axis)
	_cmn_mapping_get(axis, :tickmode) === nothing && return _axes_is_fitted_decades(axis)
	_axes_is_fitted_decades(axis; linear_mode = true) || return false
	return _cmn_mapping_get(_cmn_mapping_get(axis, :minor), :dtick) == "D1" ||
		_cmn_mapping_get(axis, :exponentformat) == "power"
end

# Visible range (log10) of the log axis group `root` with `members`: the
# group's fixed range or clip, else the data extent of its members widened by
# the padding plotly gives an autorange (5 % of the axis length on each side,
# so the data fills 90 %); `nothing` without data.
function _axes_log_view(layout::Layout, root::Symbol, members, accs)
	shown = nothing
	for m in (root, members...)
		shown = _fin_shown_range(layout, m, accs)
		shown === nothing || break
	end
	shown === nothing && return nothing
	a, b = shown
	(isfinite(a) && isfinite(b) && b - a > 1e-9) || return nothing
	axis = get(layout.fields, root, nothing)
	auto = _fin_field(axis, :autorange)
	fixed = _fin_range_pair(_fin_field(axis, :range)) !== nothing && (auto === false || auto === nothing)
	if !fixed && _fin_sticky_clip(axis) === nothing
		# `_fin_shown_range` already widened the data extent by its own pad
		# (`_FIN_AUTORANGE_PAD` of the extent on each side): take that back
		# and apply plotly's exact one.
		extent = (b - a) / (1 + 2 * _FIN_AUTORANGE_PAD)
		a += _FIN_AUTORANGE_PAD * extent
		b -= _FIN_AUTORANGE_PAD * extent
		pad = _AXES_AUTORANGE_PAD * extent
		a, b = a - pad, b + pad
	end
	return (a, b)
end

# Add to `updates` what axis `key` (state `:auto` or `:fitted`) needs to show
# decade labels every `step` decades with unlabelled minor ticks: the
# signature of `_axes_is_fitted_decades`, minor ticks in the direction of the
# major ones (none when the axis has no tick marks). Only differences are
# written.
function _axes_fitted_decades_updates!(updates, layout::Layout, key::Symbol, axis, step::Int)
	minor = _cmn_mapping_get(axis, :minor)
	direction = _axes_tick_direction(layout, key)
	want = Pair{Symbol, Any}[
		:tick0 => 0,
		:dtick => step,
		:minor_tickmode => "linear",
		:minor_tick0 => 0,
		:minor_dtick => step == 1 ? "D1" : 1,
		:minor_ticks => direction,
	]
	isempty(direction) || push!(want, :minor_ticklen => _cmn_minor_ticklen(axis, 0))
	for (name, value) in want
		path = String(name)
		current = startswith(path, "minor_") ? _cmn_mapping_get(minor, Symbol(path[7:end])) :
			_cmn_mapping_get(axis, name)
		(current !== nothing && isequal(current, value)) && continue
		updates[Symbol(key, :_, name)] = value
	end
	return updates
end

"""
	_axes_apply_style_log_ticks!(fig; size = nothing, mode = nothing) -> Bool

Apply the log-axis tick rule (`_axes_log_tick_updates!`) to `fig` (a `Plot`,
`SyncPlot` or `SubplotFigure`) at `size = (width, height)` px (default: the
figure's layout size, else the active style's default figure size) with the
rule the figure was built under (`_style_log_ticks(layout)`; `mode` overrides
it). Returns
whether anything was written. Idempotent; never changes an axis with a tick
setting of its own. `_finalize_figure!` applies the rule after every
mutation and on the export copy, so callers rarely need this directly.
"""
function _axes_apply_style_log_ticks!(fig; size = nothing, mode::Union{Nothing, Symbol} = nothing)
	p = _cmn_plot(fig)
	mode === nothing && (mode = _style_log_ticks(p.layout))
	mode in (:auto, :decades) || throw(ArgumentError(
		"_axes_apply_style_log_ticks!: `mode` must be :auto or :decades; got $(repr(mode)).",
	))
	if size === nothing
		w = get(p.layout.fields, :width, nothing)
		h = get(p.layout.fields, :height, nothing)
		dw, dh = _figure_default_size(p)
		size = (_axes_real_value_or(w, dw), _axes_real_value_or(h, dh))
	end
	updates = _axes_log_tick_updates!(Dict{Symbol, Any}(), p, size; mode = mode)
	isempty(updates) && return false
	relayout!(_cmn_relayout_target(fig); updates...)
	return true
end

"""
	_axes_apply_fits!(fig) -> Bool

Write the axis fits of `_axes_finalize_updates!` (decade labels on log axes,
room for bar labels drawn outside their bars) into `fig` at its layout size
(default: `_figure_default_size`), the size `_finalize_figure!` fits a figure
without an export size for; returns whether anything was written. Used by
the constructors, which do not finalize, so that their figures are handed
out settled. The caller runs it under the style the figure carries.
"""
function _axes_apply_fits!(fig)
	p = _cmn_plot(fig)
	(_axes_has_log_axis(p.layout) || _axes_has_outside_bar_text(p) || _axes_wants_title_gaps(p.layout)) ||
		return false
	updates = _axes_finalize_updates!(Dict{Symbol, Any}(), p, _fin_layout_size(p.layout))
	isempty(updates) && return false
	relayout!(_cmn_relayout_target(fig); updates...)
	return true
end

# ---------------------------------------------------------------------------
# Axis titles that run off the figure (W5)
# ---------------------------------------------------------------------------
#
# plotly.js draws an axis title on one line centred on its axis, so a title
# longer than the figure around its axis is cut off at the figure edge
# (gallery optical_infra: a y title clipped at both ends). The finalizer
# breaks such a title between words (`_fin_wrap_axis_titles!`, which also
# keeps the margin of an export copy and the standoff of the extra lines);
# titles with a line break of the user's, MathJax titles and words joined by
# no-break spaces (U+00A0; what `xlabel!(...; wrap = false)` writes) are
# never broken.

"""
	_axes_keep_on_one_line(text) -> String

`text` with its breakable spaces (outside markup tags) turned into no-break
spaces (U+00A0), so `_finalize_figure!` never breaks it into lines; MathJax
text (`\$`) is returned unchanged. Used by `xlabel!`/`ylabel!` with
`wrap = false`.
"""
function _axes_keep_on_one_line(text::AbstractString)
	s = String(text)
	occursin('$', s) && return s
	out = IOBuffer()
	inside = false
	for c in s
		c == '<' && (inside = true)
		c == '>' && (inside = false)
		print(out, (c == ' ' && !inside) ? '\u00a0' : c)
	end
	return String(take!(out))
end

# Text of axis `key`'s title and whether it is stored as a bare string.
function _axes_title_text(axis)
	title = _cmn_mapping_get(axis, :title)
	title isa AbstractString && return (String(title), true)
	text = _cmn_mapping_get(title, :text)
	return (text isa AbstractString ? String(text) : "", false)
end

# Font size (px) of axis `key`'s title: its `title.font.size`, else the
# template's, else plotly's 1.2 x the layout font.
function _axes_title_font(layout::Layout, key::Symbol)
	root = _tight_root_font_size(k -> get(layout.fields, k, nothing))
	template_title = _cmn_mapping_get(_axes_template_entry(layout, Symbol(String(key)[1], "axis")), :title)
	title = _cmn_mapping_get(get(layout.fields, key, nothing), :title)
	return _axes_size(
		title isa AbstractString ? nothing : _cmn_mapping_get(_cmn_mapping_get(title, :font), :size),
		_axes_size(
			_cmn_mapping_get(_cmn_mapping_get(template_title, :font), :size),
			Float64(round(_AXES_TITLE_FONT_FACTOR * root)),
		),
	)
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
	if t.kind === :scene
		# Y26: an "data" scene with explicit ranges is pinned to their
		# proportions, an automatic camera re-framed, cell tick counts updated.
		state = _s3_scene_state(fig, t)
		_apply_equal_aspect!(fig, t; ratio = ratio, who = who)
		_s3_finish_scene!(fig, t, state)
		_s3_finish_ticks!(fig, t, state)
	else
		# axes-ticks-04: plotly.js 2.35 ignores `scaleanchor` on an axis that
		# has `matches` (a shared y of a subplot row), which left the cell
		# unconstrained. The constraint then goes on the cell's x axis
		# instead (one x unit = 1/ratio y units: the same aspect); with both
		# axes shared there is no free axis to constrain.
		swap = false
		if t.kind === :xy
			fields = _cmn_layout(fig).fields
			matched(key) = _cmn_mapping_get(get(fields, key, nothing), :matches) !== nothing
			if matched(t.ykey)
				matched(t.xkey) && throw(ArgumentError(
					"$(who): both axes of this cell are shared with other cells " *
					"(`matches`), and plotly.js cannot lock the aspect of a shared " *
					"axis; share at most one of them.",
				))
				swap = true
			end
		end
		_apply_equal_aspect!(fig, t; ratio = ratio, who = who)
		if swap
			_cmn_delete_layout_fields!(fig, t.ykey, (:scaleanchor, :scaleratio))
			_cmn_merge_layout_key!(
				fig,
				t.xkey,
				Dict{Symbol, Any}(:scaleanchor => t.yref, :scaleratio => 1 / Float64(ratio), :constrain => "domain"),
			)
		end
		# plotly.js ignores one-sided limits (D11) on aspect-linked axes.
		if t.kind === :xy
			roots = (_axes_match_root(fig, t.xkey, who), _axes_match_root(fig, t.ykey, who))
			_resolve_linked_limits!(
				fig,
				[(root, _axes_match_members(fig, root, who)) for root in roots],
				who,
			)
		end
	end
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
ranges are honoured and the plot area shrinks instead. When the cell's y axis
is shared with other cells (`subplots(...; shared_yaxes = true)`), which
plotly.js cannot constrain, its x axis gets `scaleanchor = <cell y>`,
`scaleratio = 1/ratio` (the same aspect); a cell whose x and y axes are both
shared throws an `ArgumentError`. A 3-D scene cell gets
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
	_axes_reject_unknown(kwargs, _AXES_EQUAL_KEYWORDS, "axis_equal!")
	_axes_equal!(fig; kwargs...)
	# The cell is fitted for its new aspect now, so the figure is settled
	# (fields-06).
	_finalize_figure!(fig)
	return nothing
end

function axis_equal!(sf::SubplotFigure; show = nothing, kwargs...)
	_axes_reject_show(show, "axis_equal!")
	_axes_reject_unknown(kwargs, _AXES_EQUAL_KEYWORDS, "axis_equal!")
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
	_axes_reject_unknown(kwargs, _AXES_OFF_KEYWORDS, "axis_off!")
	_axes_off!(fig; kwargs...)
	return nothing
end

function axis_off!(sf::SubplotFigure; show = nothing, kwargs...)
	_axes_reject_show(show, "axis_off!")
	_axes_reject_unknown(kwargs, _AXES_OFF_KEYWORDS, "axis_off!")
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
const _AXES_SPINE_TICKS = (:mirror, :primary, :none)
# Owner name of the frame lines `spines!` draws as shapes (see below).
const _AXES_SPINE_SHAPE = "plotlysupply:spine"

# The frame sides of `style` (bottom, top, left, right), adjusted by the
# per-side keywords.
function _axes_spine_sides(style_name::Symbol, sides)
	on = style_name === :box ? (true, true, true, true) :
		style_name === :open ? (true, false, true, false) : (false, false, false, false)
	return ntuple(i -> sides[i] === nothing ? on[i] : sides[i], 4)
end

# Whether a plotly `mirror` value mirrors the ticks.
_axes_mirrors_ticks(mirror) = mirror isa AbstractString && mirror in ("ticks", "allticks")
# The `mirror` value that keeps the mirrored line of `mirror` but no ticks.
_axes_unmirrored_ticks(mirror) = mirror == "allticks" ? "all" : true

# The side ("bottom"/"top" for x, "left"/"right" for y) axis `entry` is drawn on.
function _axes_axis_side(entry, letter::Char)
	side = _cmn_mapping_get(entry, :side)
	side isa Symbol && (side = String(side))
	letter == 'x' && return side == "top" ? "top" : "bottom"
	return side == "right" ? "right" : "left"
end

# Whether axis `key` (an `xaxis*`/`yaxis*` key) shares the plot area with an
# axis on its opposite side: one that overlays it, or that it overlays (a twin
# or secondary axis: `plot_scatter!(...; secondary_y = true)`,
# `Spec(secondary_y = true)`, `secondary_xaxis!`). That side shows the other
# axis's ticks, so `key` must not mirror its own there (axes-ticks-05).
function _axes_has_opposite_twin(layout::Layout, key::Symbol)
	name = String(key)
	letter = name[1]
	m = match(r"^[xy]axis(\d*)$", name)
	m === nothing && return false
	ref = string(letter, m.captures[1] == "1" ? "" : m.captures[1])
	fields = layout.fields
	entry = get(fields, key, nothing)
	own_side = _axes_axis_side(entry, letter)
	host = _cmn_mapping_get(entry, :overlaying)
	if host isa AbstractString && _cmn_axis_ref_index(host, letter) !== nothing
		host_key = _axis_layout_key(host, Symbol(letter))
		_axes_axis_side(get(fields, host_key, nothing), letter) != own_side && return true
	end
	for (other, other_entry) in fields
		other === key && continue
		occursin(Regex("^$(letter)axis\\d*\$"), String(other)) || continue
		_cmn_mapping_get(other_entry, :overlaying) == ref || continue
		_axes_axis_side(other_entry, letter) != own_side && return true
	end
	return false
end

"""
	_axes_twin_mirror_updates(layout::Layout) -> Dict{Symbol,Any}

`relayout!` updates (`<axis>_mirror`) that stop every Cartesian axis sharing
its plot area with an axis on the opposite side (`_axes_has_opposite_twin`)
from mirroring its ticks there: `mirror = "ticks"` becomes `true` (the line
stays, the ticks go), `"allticks"` becomes `"all"`. Each spine then carries
the ticks of its own scale only, as matplotlib's `twinx`/`secondary_xaxis`
(axes-ticks-05: under a journal style with mirrored ticks the twin's spine
also carried the primary's ticks at the primary's positions). Empty when
nothing mirrors onto a twin. Internal.
"""
function _axes_twin_mirror_updates(layout::Layout)
	updates = Dict{Symbol, Any}()
	for (key, entry) in layout.fields
		occursin(r"^[xy]axis\d*$", String(key)) || continue
		mirror = _cmn_mapping_get(entry, :mirror)
		_axes_mirrors_ticks(mirror) || continue
		_axes_has_opposite_twin(layout, key) || continue
		updates[Symbol(key, :_mirror)] = _axes_unmirrored_ticks(mirror)
	end
	return updates
end

# Apply `_axes_twin_mirror_updates` to `fig` (a figure or staged target).
function _axes_apply_twin_mirrors!(fig)
	for (name, value) in _axes_twin_mirror_updates(_cmn_layout(fig))
		key = Symbol(String(name)[1:(end - length("_mirror"))])
		_cmn_merge_layout_key!(fig, key, Dict{Symbol, Any}(:mirror => value))
	end
	return nothing
end

# plotly.js draws an axis line on the axis's own side (`showline`) and, with
# `mirror`, on the opposite side as well; it cannot draw the opposite line
# alone, nor mirror the ticks without mirroring the line. Those frames are
# drawn natively where possible: both lines `showline = true` + `mirror`, the
# own line alone `showline = true, mirror = false`. Otherwise `showline =
# false` (with `mirror = "ticks"` when the ticks are mirrored, which plotly.js
# draws without a line; render probe p06) and the wanted lines are layout
# shapes on the plot-area edge (`"<x> domain"`/`"<y> domain"` references, in
# the axis's line colour and width), returned as (edge, along-x) pairs.
function _axes_spine_axis_fields(own_on::Bool, other_on::Bool, mirror_ticks::Bool; bounded::Bool = false)
	if !bounded && own_on && other_on
		return (Dict{Symbol, Any}(:showline => true, :mirror => mirror_ticks ? "ticks" : true), (false, false))
	elseif !bounded && own_on && !mirror_ticks
		return (Dict{Symbol, Any}(:showline => true, :mirror => false), (false, false))
	end
	fields = Dict{Symbol, Any}(:showline => false, :mirror => mirror_ticks ? "ticks" : false)
	return (fields, (own_on, other_on))
end

const _AXES_SPINE_SIDE_NAMES = ("bottom", "top", "left", "right")

# A per-side keyword of `spines!`: `nothing` (from `style`), `true`/`false`,
# or a data interval `(lo, hi)` (the side is drawn over that interval only).
# Returns `(switch, interval)`: the side's on/off override and the interval
# as given, or `nothing`.
function _axes_spine_side_option(value, name::AbstractString, who::AbstractString)
	(value === nothing || value isa Bool) && return (value, nothing)
	((value isa Tuple || value isa AbstractVector) && length(value) == 2) || throw(ArgumentError(
		"$(who): `$(name)` must be true, false, `nothing` or a data interval " *
		"(lo, hi) over which the line is drawn; got $(repr(value)).",
	))
	lo, hi = value[1], value[2]
	for bound in (lo, hi)
		ok = (bound isa Real && !(bound isa Bool) && isfinite(bound)) ||
			bound isa Dates.Date || bound isa Dates.DateTime
		ok || throw(ArgumentError(
			"$(who): `$(name)` bounds must be finite numbers or dates (data " *
			"values of the axis); got $(repr(value)).",
		))
	end
	(lo isa Real) == (hi isa Real) || throw(ArgumentError(
		"$(who): `$(name)` bounds must both be numbers or both be dates; got $(repr(value)).",
	))
	isequal(lo, hi) && throw(ArgumentError(
		"$(who): `$(name)` bounds must differ; got $(repr(value)).",
	))
	return (true, (lo, hi))
end

# The ends of a bounded spine on axis `key` in the units plotly.js reads in
# shape coordinates: data values (plotly maps them through the axis, log10 on
# a log axis, where they must be positive), dates as date strings. An untyped
# ("-") axis is the type plotly.js gives it from its data: a date axis when it
# holds dates, numeric when it holds numbers (either kind of bound is taken
# while it holds neither).
function _axes_spine_interval(fig, key::Symbol, interval, name::AbstractString, who::AbstractString)
	axis_type = _axis_type(fig, key)
	dates = axis_type == "date" || (axis_type == "-" && _axes_has_date_data(fig, key))
	out = Any[]
	for bound in interval
		if bound isa Real
			dates && throw(ArgumentError(
				"$(who): `$(name)` is drawn along date axis $(repr(key)); give dates, " *
				"not numbers; got $(repr(interval)).",
			))
			(axis_type == "log" && bound <= 0) && throw(ArgumentError(
				"$(who): `$(name)` is drawn along logarithmic axis $(repr(key)); its " *
				"bounds are data values and must be positive; got $(repr(interval)).",
			))
			push!(out, Float64(bound))
		else
			(dates || (axis_type == "-" && _axis_data_extent(fig, key) === nothing)) ||
				throw(ArgumentError(
					"$(who): `$(name)` has date bounds but axis $(repr(key)) " *
					(axis_type == "-" ? "holds numeric data" : "has type $(repr(axis_type))") *
					"; give numbers.",
				))
			push!(out, string(bound))
		end
	end
	return out
end

# perf-spines: the axis writes of a styling call over many cells, collected
# as `relayout!` property paths (`xaxis3.showline`, `xaxis3.minor.ticks`: a
# nested `minor` mapping is merged one level deeper, siblings kept, as
# `_cmn_merge_layout_key!(...; nested = (:minor,))` merges it) and written
# in one call. A key queued twice flushes first, so a target that reads an
# axis an earlier target wrote sees the write, as one merge per key did.
struct _AxesLayoutBatch
	paths::Dict{Symbol, Any}
	keys::Set{Symbol}
end
_AxesLayoutBatch() = _AxesLayoutBatch(Dict{Symbol, Any}(), Set{Symbol}())

function _axes_queue_layout_fields!(batch::_AxesLayoutBatch, fig, key::Symbol, fields::AbstractDict{Symbol})
	isempty(fields) && return nothing
	key in batch.keys && _axes_flush_layout_fields!(batch, fig)
	# A container that is not a mapping (a user's scalar) is replaced as the
	# merge replaced it.
	entry = get(_cmn_layout(fig).fields, key, nothing)
	if !(entry === nothing || entry isa AbstractDict || entry isa PlotlyBase.PlotlyAttribute)
		_axes_flush_layout_fields!(batch, fig)
		_cmn_merge_layout_key!(fig, key, fields; nested = (:minor,))
		return nothing
	end
	push!(batch.keys, key)
	for (name, value) in fields
		inner = value isa PlotlyBase.PlotlyAttribute ? value.fields : value
		current = _cmn_mapping_get(entry, name)
		if name === :minor && inner isa AbstractDict &&
				(current === nothing || current isa AbstractDict || current isa PlotlyBase.PlotlyAttribute)
			for (k, v) in inner
				batch.paths[Symbol(key, '.', name, '.', k)] = v
			end
		else
			batch.paths[Symbol(key, '.', name)] = value
		end
	end
	return nothing
end

function _axes_flush_layout_fields!(batch::_AxesLayoutBatch, fig)
	isempty(batch.paths) && return nothing
	relayout!(_cmn_relayout_target(fig), copy(batch.paths))
	empty!(batch.paths)
	empty!(batch.keys)
	return nothing
end

# The shapes of `owners` replaced by `items` (each named into its owner's
# namespace) in one `layout.shapes` write; the other shapes keep their order.
function _axes_replace_named_shapes!(fig, owners::Vector{String}, items::Vector{Any}, who::AbstractString)
	isempty(owners) && return nothing
	length(owners) == 1 && return _upsert_named!(fig, :shapes, only(owners), items; who = who)
	existing = get(_cmn_layout(fig).fields, :shapes, nothing)
	(existing === nothing || existing isa AbstractVector) || throw(ArgumentError(
		"$(who): layout.shapes must be a vector; got $(typeof(existing)).",
	))
	kept = Any[]
	if existing !== nothing
		for item in existing
			name = _cmn_item_name(item)
			any(owner -> _cmn_name_matches(name, owner), owners) && continue
			push!(kept, item)
		end
	end
	relayout!(_cmn_relayout_target(fig); shapes = vcat(kept, items))
	return nothing
end

function _axes_spines!(
	fig;
	style::Union{Symbol, AbstractString} = :box,
	color = "",
	linewidth::Real = 0,
	ticks::Union{Nothing, Symbol, AbstractString} = nothing,
	bottom = nothing,
	top = nothing,
	left = nothing,
	right = nothing,
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
	ticks_name = ticks === nothing ? nothing : Symbol(ticks)
	(ticks_name === nothing || ticks_name in _AXES_SPINE_TICKS) || throw(ArgumentError(
		"$(who): `ticks` must be :mirror, :primary, :none or `nothing`; got $(repr(ticks)).",
	))
	_axes_check_size(linewidth, "linewidth", who)
	line_color = _axes_is_unset_color(color) ? nothing : _color_hex(color; who = who)
	options = ntuple(
		i -> _axes_spine_side_option((bottom, top, left, right)[i], _AXES_SPINE_SIDE_NAMES[i], who),
		4,
	)
	sides = _axes_spine_sides(style_name, map(first, options))
	intervals = map(last, options)
	targets, select = _axes_styling_targets(
		fig,
		who;
		row = row,
		col = col,
		inset = inset,
		cells = cells,
	)
	# Every target's bounded sides in shape units, checked before any write.
	# `side_axis(t, i)` is the axis a side's line runs along: bottom/top along
	# the x axis, left/right along the y axis.
	side_axis(t, i) = i <= 2 ? t.xkey : t.ykey
	target_intervals = map(targets) do t
		ntuple(4) do i
			intervals[i] === nothing ? nothing :
				_axes_spine_interval(fig, side_axis(t, i), intervals[i], _AXES_SPINE_SIDE_NAMES[i], who)
		end
	end
	ink = nothing
	# The figure's style mirrors its ticks (`PlotStyle(mirror_ticks = true)`
	# with tick marks, the :ieee/:aps/:aip look): what a closed frame gets back.
	style = _figure_style(fig)
	style_mirror = style.mirror_ticks && !isempty(style.ticks)
	# perf-spines: the axis fields of every target go out in one `relayout!`
	# and the lines of every cell in one `layout.shapes` write (a merge and a
	# shapes write per cell made `cells = :all` quadratic in the cells).
	batch = _AxesLayoutBatch()
	shape_owners = String[]
	shape_items = Any[]
	for (t, bounded) in zip(targets, target_intervals)
		shapes = Any[]
		for (key, letter) in ((t.xkey, 'x'), (t.ykey, 'y'))
			entry = get(_cmn_layout(fig).fields, key, nothing)
			side = _cmn_mapping_get(entry, :side)
			side isa Symbol && (side = String(side))
			# (own side, opposite side) of this axis in `sides` order.
			own_index, other_index = letter == 'x' ?
				(side == "top" ? (2, 1) : (1, 2)) :
				(side == "right" ? (4, 3) : (3, 4))
			# L12: a side without a line has no ticks, and a side that carries a
			# twin or secondary axis shows that axis's ticks only
			# (axes-ticks-05). `mirror = false` is what a frame without its
			# opposite line leaves (`:open`, `:none`, a side switched off), so a
			# closed frame (`ticks = nothing`) takes the style's mirrored ticks
			# back; `mirror = true` (a closed frame without mirrored ticks,
			# `ticks = :primary`) is the user's choice and is kept.
			current_mirror = _cmn_mapping_get(entry, :mirror)
			wanted = ticks_name === :mirror || (
				ticks_name === nothing && (
					_axes_mirrors_ticks(current_mirror) ||
					(current_mirror === false && style_mirror)
				)
			)
			mirror_ticks = wanted && sides[other_index] &&
				!_axes_has_opposite_twin(_cmn_layout(fig), key)
			# A bounded side is a shape over its interval; plotly.js's axis
			# line always spans the whole plot area (Z37).
			fields, drawn = _axes_spine_axis_fields(
				sides[own_index],
				sides[other_index],
				mirror_ticks;
				bounded = bounded[own_index] !== nothing || bounded[other_index] !== nothing,
			)
			line_color === nothing || (fields[:linecolor] = line_color)
			linewidth > 0 && (fields[:linewidth] = linewidth)
			if ticks_name === :none
				fields[:ticks] = ""
				_cmn_mapping_get(entry, :minor) === nothing || (fields[:minor] = attr(ticks = ""))
			end
			_axes_queue_layout_fields!(batch, fig, key, fields)
			any(drawn) || continue
			shape_color = something(line_color, _cmn_mapping_get(entry, :linecolor), Some(nothing))
			if shape_color === nothing
				ink === nothing && (ink = _template_ink(_figure_style_template(fig)))
				shape_color = ink
			end
			shape_width = linewidth > 0 ? linewidth :
				something(_cmn_mapping_get(entry, :linewidth), _DEFAULT_AXIS_LINEWIDTH)
			for (index, on) in ((own_index, drawn[1]), (other_index, drawn[2]))
				on || continue
				edge = index in (2, 4) ? 1 : 0   # top/right: the far edge
				line = attr(color = shape_color, width = shape_width)
				span = bounded[index]
				# Along the axis: the whole plot area ("<ref> domain", 0..1),
				# or the side's data interval (data units on the axis).
				along_ref, a0, a1 = span === nothing ?
					("$(letter == 'x' ? t.xref : t.yref) domain", 0, 1) :
					(letter == 'x' ? t.xref : t.yref, span[1], span[2])
				push!(shapes, letter == 'x' ?
					attr(type = "line", xref = along_ref, yref = "$(t.yref) domain",
						x0 = a0, x1 = a1, y0 = edge, y1 = edge, line = line, layer = "above") :
					attr(type = "line", xref = "$(t.xref) domain", yref = along_ref,
						x0 = edge, x1 = edge, y0 = a0, y1 = a1, line = line, layer = "above"))
			end
		end
		owner = "$(_AXES_SPINE_SHAPE):$(t.xref)$(t.yref)"
		named = Any[]
		for (k, shape) in enumerate(shapes)
			fields = _symbol_dict(shape)
			fields[:name] = "$(owner):$(k)"
			push!(named, attr(; fields...))
		end
		# Replaces (or removes) the lines an earlier call drew on this cell;
		# a frame drawn natively leaves `layout.shapes` untouched.
		existing = get(_cmn_layout(fig).fields, :shapes, nothing)
		had_lines = existing isa AbstractVector &&
			any(item -> _cmn_name_matches(_cmn_item_name(item), owner), existing)
		if !(isempty(named) && !had_lines)
			push!(shape_owners, owner)
			append!(shape_items, named)
		end
	end
	_axes_flush_layout_fields!(batch, fig)
	_axes_replace_named_shapes!(fig, shape_owners, shape_items, who)
	select && _axes_select!(fig, only(targets))
	_axes_finish!(fig)
	return nothing
end

"""
	spines!(fig; style=:box, color="", linewidth=0, ticks=nothing, bottom=nothing, top=nothing, left=nothing, right=nothing, row=nothing, col=nothing, inset=nothing, cells=nothing)
	spines!(sf::SubplotFigure; ...)

Style the axis lines ("spines") and the frame ticks of a figure,
SubplotFigure cell or inset (matplotlib `ax.spines[...]`, including
`set_bounds`, and `tick_params(top = True, right = True)`).

# Keywords
- `style = :box`: `:box` closes the frame (all four lines, the package
  default); `:open` keeps only the bottom and left lines; `:none` hides the
  lines (ticks stay). Strings are accepted.
- `bottom`, `top`, `left`, `right = nothing`: switch one side of the frame
  on (`true`) or off (`false`); `nothing` takes the side from `style` (e.g.
  `spines!(fig; left = false)` keeps bottom, top and right). A data interval
  `(lo, hi)` draws the side only over that interval (matplotlib
  `ax.spines["left"].set_bounds(lo, hi)`, a "range frame"): bottom/top run
  along the x axis, left/right along the y axis, in DATA units (data values
  on a log axis, where they must be positive; `Date`/`DateTime` values on a
  date axis). The axis line of that axis is then hidden and every side it
  owns is drawn as a shape; ticks and tick labels are unchanged.
  A side is the axis line where plotly.js can draw it (`showline`,
  `mirror`); a frame it cannot draw (an opposite line alone, mirrored ticks
  without the mirrored line, or a bounded side) gets that line as a layout
  shape on the plot-area edge in `color`/`linewidth`, else the axis's line
  colour (the template's ink when unset) and width (named
  `"plotlysupply:spine:<xy>:<k>"`; later `spines!` calls replace it).
- `ticks = nothing`: `:mirror` also draws the ticks on the top and right
  frame sides (plotly `mirror = "ticks"`); `:primary` keeps them on the
  bottom and left sides only; `:none` removes the tick marks (major and
  minor; `xticks!(fig; direction = :outside)` brings the major ticks back,
  `minor = true` the minor ones); `nothing` keeps the current choice, and a
  frame closed again after `:open`/`:none` gets the mirrored ticks of the
  figure's style back (`:ieee`, `:aps`, `:aip`). Mirrored ticks (major and
  minor) are drawn only on a side that has its line and carries no twin or
  secondary axis (whose own ticks are there): a side without a line has no
  ticks.
- `color = ""`: line colour (CSS/hex string, Symbol or Colors.jl colour);
  `""` keeps it.
- `linewidth::Real = 0`: line width in px; 0 keeps it.
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active); `inset = k` targets inset `k`.
- `cells = nothing`: `:all` styles every xy cell of a SubplotFigure (insets
  excluded) and leaves the active cell unchanged.

The sides refer to the frame of the plot area: an x axis placed on top
(`side = "top"`) has its own line on the top side. Only the cell's primary
x/y axes change; secondary axes keep their own line. Invalid keywords are an
`ArgumentError` before anything changes. Returns `nothing` (`sf` for a
SubplotFigure).

# Example
```julia
fig = plot_scatter(1:10, rand(10))
spines!(fig; style = :open, linewidth = 1.5)
spines!(fig; ticks = :mirror)        # ticks on all four sides, closed frame
xticks!(fig; direction = :inside); yticks!(fig; direction = :inside)
spines!(fig; left = false)           # bottom, top and right lines only
spines!(fig; style = :open, bottom = (1, 10), left = (0, 1))   # range frame
```
"""
function spines!(fig; show = nothing, kwargs...)
	_axes_reject_show(show, "spines!")
	_axes_reject_unknown(kwargs, _AXES_SPINES_KEYWORDS, "spines!")
	_axes_spines!(fig; kwargs...)
	return nothing
end

function spines!(sf::SubplotFigure; show = nothing, kwargs...)
	_axes_reject_show(show, "spines!")
	_axes_reject_unknown(kwargs, _AXES_SPINES_KEYWORDS, "spines!")
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
	# `axis = :none` hides every grid line; otherwise the call sets the grid
	# kinds named by `which` and leaves the other kind as it is (G7), so the
	# major and minor grids can be styled by separate calls.
	major_on = axis_name === :none || which_name in (:major, :both)
	minor_on = axis_name === :none || which_name in (:minor, :both)
	# Styling goes to the grid named by `which`; with `:both` it goes to the
	# major grid, whose colour, width and dash plotly.js's minor grid follows
	# (the minor colour as a lighter blend).
	style_key = which_name === :minor ? :minor : :major
	# perf-spines: one `relayout!` for every target (see `_AxesLayoutBatch`).
	batch = _AxesLayoutBatch()
	for t in targets
		for (key, on) in (
			(t.xkey, axis_name in (:both, :x)),
			(t.ykey, axis_name in (:both, :y)),
		)
			entry = get(_cmn_layout(fig).fields, key, nothing)
			style = Dict{Symbol, Any}()
			if on
				gridcolor === nothing || (style[:gridcolor] = gridcolor)
				width > 0 && (style[:gridwidth] = width)
				isempty(dash_name) || (style[:griddash] = dash_name)
			end
			fields = Dict{Symbol, Any}()
			if major_on
				fields[:showgrid] = on
				style_key === :major && merge!(fields, style)
			end
			minor_entry = _cmn_mapping_get(entry, :minor)
			if minor_on && on
				minor_fields = Dict{Symbol, Any}(:showgrid => true)
				style_key === :minor && merge!(minor_fields, style)
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
			elseif minor_on && minor_entry !== nothing
				fields[:minor] = attr(showgrid = false)
			end
			isempty(fields) || _axes_queue_layout_fields!(batch, fig, key, fields)
		end
	end
	_axes_flush_layout_fields!(batch, fig)
	select && _axes_select!(fig, only(targets))
	_axes_finish!(fig)
	return nothing
end

"""
	grid!(fig; axis=:both, which=:major, color="", width=0, dash="", alpha=nothing, row=nothing, col=nothing, inset=nothing, cells=nothing)
	grid!(sf::SubplotFigure; ...)

Set the grid lines of a figure, SubplotFigure cell or inset. A call defines
the grid kind(s) named by `which` on the cell: the axes selected by `axis`
show them, the cell's other axis hides them. The kind not named keeps its
state and style, so the major and minor grids are set (and styled) by
separate calls, as matplotlib's `ax.grid(which = ...)`.

# Keywords
- `axis = :both`: `:both`, `:x`, `:y` or `:none` (no grid at all: major and
  minor lines of both axes are hidden, whatever `which` says).
- `which = :major`: `:major`, `:minor` or `:both`. Minor grid lines on a log
  axis with explicit major ticks sit at mantissas 1..9 of every decade; on
  other axes plotly.js places them between the major ticks.
- `color = ""`: grid colour (string, Symbol or Colors.jl colour); `""` keeps
  Plotly's. The styling keywords style the kind named by `which`
  (`axis.minor.gridcolor` etc. for `:minor`); with `:both` they style the
  major lines and the minor lines follow them (plotly.js draws them in a
  lighter blend of the major colour unless a `:minor` call gave a colour).
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
grid!(fig; axis = :y, which = :minor, alpha = 0.05)   # fainter minor lines
```
"""
function grid!(fig; show = nothing, kwargs...)
	_axes_reject_show(show, "grid!")
	_axes_reject_unknown(kwargs, _AXES_GRID_KEYWORDS, "grid!")
	_axes_grid!(fig; kwargs...)
	return nothing
end

function grid!(sf::SubplotFigure; show = nothing, kwargs...)
	_axes_reject_show(show, "grid!")
	_axes_reject_unknown(kwargs, _AXES_GRID_KEYWORDS, "grid!")
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

# Union of the data extents of every axis (of the root's letter) whose
# `matches` chain ends at `root` (a shared axis group autoranges over all of
# them).
function _axes_group_extent(fig, root::Symbol, who::AbstractString)
	layout = _cmn_layout(fig)
	letter = String(root)[1]
	keys_in_group = Symbol[root]
	for key in keys(layout.fields)
		(key isa Symbol || key isa AbstractString) || continue
		k = Symbol(key)
		_cmn_axis_index(k, letter) === nothing && continue
		k === root && continue
		_axes_match_root(fig, k, who) === root && push!(keys_in_group, k)
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
# on a tie, among the steps whose labels `fits` (all when none does: the
# step with the fewest ticks, at least two). Values are computed from
# integers so they are correctly rounded (0.3, not 0.30000000000000004).
function _axes_linear_ticks(lo::Float64, hi::Float64, who::AbstractString; fits = _ -> true)
	span = hi - lo
	raw = span / _AXES_SECONDARY_TICK_TARGET
	e0 = floor(Int, log10(raw))
	# The smallest candidate step is 10^e0; k = value / step must fit an Int.
	max(abs(lo), abs(hi)) / exp10(e0) < 1e15 || throw(ArgumentError(
		"$(who): the range [$(lo), $(hi)] is too narrow for its magnitude to " *
		"place automatic ticks; pass explicit tick values.",
	))
	slack = 1e-9 * span
	# (score, -step order, values): the steps up to 10^(e0 + 2) >= 10 x span /
	# target reach down to two ticks.
	candidates = Tuple{Int, Int, Vector{Float64}}[]
	order = 0
	for e in e0:(e0 + 2), m in (1, 2, 5)
		order += 1
		step = m * exp10(e)
		kmin = ceil(Int, (lo - slack) / step)
		kmax = floor(Int, (hi + slack) / step)
		count = kmax - kmin + 1
		count >= 2 || continue
		values = Float64[_cmn_log_tick_value(Float64(k * m), 10.0, e) for k in kmin:kmax]
		push!(candidates, (abs(count - _AXES_SECONDARY_TICK_TARGET), -order, values))
	end
	# The step 10^e0 <= span / target always yields at least `target` ticks.
	sort!(candidates; by = c -> (c[1], c[2]))
	for (_, _, values) in candidates
		fits(values) && return values
	end
	return candidates[argmin([length(c[3]) for c in candidates])][3]
end

function _axes_secondary_auto_ticks(lo::Float64, hi::Float64, log_axis::Bool, who::AbstractString;
	fits = _ -> true)
	if log_axis && lo > 0
		decades = log10(hi / lo)
		if decades >= 1
			values = log_ticks(lo, hi; subs = decades <= 3 ? (1, 2, 5) : (1,))
			if length(values) > 2 * _AXES_SECONDARY_TICK_TARGET
				# Many decades: keep every n-th power of ten.
				stride = ceil(Int, length(values) / _AXES_SECONDARY_TICK_TARGET)
				values = values[1:stride:end]
			end
			if length(values) >= 2 && !fits(values)
				# Labels that collide: powers of ten only, then every n-th.
				decade_values = log_ticks(lo, hi; subs = (1,))
				stride = 1
				values = decade_values
				while length(values) > 2 && !fits(values)
					stride += 1
					values = decade_values[1:stride:end]
				end
			end
			length(values) >= 2 && return values
		end
	end
	return _axes_linear_ticks(lo, hi, who; fits = fits)
end

# Clear space between neighbouring secondary tick labels, in tick-font sizes.
const _AXES_SECONDARY_LABEL_GAP_EM = 0.5

# vm-11: a predicate on secondary tick values (in secondary units) that holds
# when their labels (`_axes_format_number` at the primary axis's tick font)
# keep `_AXES_SECONDARY_LABEL_GAP_EM` between them along the cell's x axis,
# whose length is estimated for the figure's size as the log-tick fit does
# (`_axes_fit_plan`). A narrow cell (a column of a 1 x 2 grid under a journal
# style) then gets fewer ticks instead of colliding labels, which plotly.js
# would tilt by 90 degrees.
function _axes_secondary_label_fit(fig, t, finv, lower::Float64, upper::Float64, log_axis::Bool)
	p = _cmn_plot(fig)
	layout = p.layout
	w = get(layout.fields, :width, nothing)
	h = get(layout.fields, :height, nothing)
	dw, dh = _figure_default_size(p)
	plan = _axes_fit_plan(p, (_axes_real_value_or(w, dw), _axes_real_value_or(h, dh)))
	len = _AXES_TICK_LENGTH_SAFETY * _axes_plan_length(layout, plan, t.xkey)
	f = _axes_tick_font(layout, t.xkey)
	gap = _AXES_SECONDARY_LABEL_GAP_EM * f
	at(x) = log_axis ? (log10(x) - log10(lower)) / (log10(upper) - log10(lower)) :
		(x - lower) / (upper - lower)
	return function (values)
		labels = Tuple{Float64, Float64}[]
		texts = _axes_power_ticktext(values, log_axis)
		for (v, text) in zip(values, texts)
			# A value `finv` cannot place is reported by the caller, which maps
			# the chosen ticks with the checks of `secondary_xaxis!`.
			x = try
				finv(v)
			catch err
				err isa InterruptException && rethrow()
				return true
			end
			(x isa Real && isfinite(x) && (!log_axis || x > 0)) || return true
			push!(labels, (at(Float64(x)) * len, _text_extent(text, f)[1]))
		end
		sort!(labels; by = first)
		for i in 2:length(labels)
			labels[i][1] - labels[i - 1][1] < (labels[i][2] + labels[i - 1][2]) / 2 + gap && return false
		end
		return true
	end
end

# numerics-03: automatic secondary tick labels in plotly's power format (D21),
# as the primary axes beside them. Linear: a set of ticks whose largest
# magnitude has a decade beyond plotly's `minexponent` (3) is written
# "m×10ⁿ", each label with its own decade so the mantissa is in [1, 10)
# (the package's patched power format, src/plotlyjs_compat_asset.jl); other
# sets print as plain numbers. On a logarithmic primary axis the labels read
# as plotly's log axes: "1", "10", "10ⁿ" and "m×10ⁿ". Negative numbers and
# exponents carry plotly's minus sign (U+2212).
const _AXES_POWER_MINEXPONENT = 3   # plotly.js' `minexponent` default
function _axes_power_ticktext(values, log_axis::Bool; sigdigits::Int = 6)
	big = 0.0
	for v in values
		a = abs(Float64(v))
		isfinite(a) && (big = max(big, a))
	end
	exponent_needed = log_axis ||
		(big > 0 && abs(floor(Int, log10(big) + 0.01)) > _AXES_POWER_MINEXPONENT)
	return String[_axes_power_number(Float64(v), exponent_needed; sigdigits = sigdigits) for v in values]
end

# `_axes_power_ticktext` of linear `values` with six significant digits, or
# as many more (up to 17) as distinct values need to keep distinct labels
# (numerics-08: levels 1000000.2 and 1000000.4 read "1.0000002×10⁶" and
# "1.0000004×10⁶", not both "1000000").
function _axes_distinct_power_ticktext(values::AbstractVector{Float64})
	distinct = length(unique(values))
	labels = String[]
	for digits in 6:17
		labels = _axes_power_ticktext(values, false; sigdigits = digits)
		length(unique(labels)) >= distinct && return labels
	end
	return labels
end

function _axes_power_number(v::Float64, exponent_needed::Bool; sigdigits::Int = 6)
	v == 0 && return "0"
	a = abs(v)
	(exponent_needed || !(1e-4 <= a < 1e15)) || return _axes_offset_label(v; sigdigits = sigdigits)
	n = floor(Int, log10(a) + 1e-9)
	m = round(a / exp10(n); sigdigits = sigdigits)
	if m >= 10
		m /= 10
		n += 1
	end
	mtext = isinteger(m) ? string(Int(m)) : string(m)
	return (v < 0 ? "−" : "") * _colour_power_text(mtext, n)
end

# Compact tick text: integers without ".0", six significant digits, plain
# decimals in [1e-4, 1e15) and "me±k" outside.
function _axes_format_number(v::Float64; sigdigits::Int = 6)
	v == 0 && return "0"
	r = round(v; sigdigits = sigdigits)
	a = abs(r)
	if 1e-4 <= a < 1e15
		return isinteger(r) ? string(Int64(r)) : string(r)
	end
	e = floor(Int, log10(a))
	mantissa = round(r / exp10(e); sigdigits = sigdigits)
	if abs(mantissa) >= 10
		mantissa /= 10
		e += 1
	end
	text = isinteger(mantissa) ? string(Int64(mantissa)) : string(mantissa)
	return "$(text)e$(e)"
end

# Text metrics used to estimate how far a top x axis (tick labels plus title)
# reaches above the plot area. Measured on plotly.js 2.35.2 SVG exports (tick
# label baselines and title boxes at layout font sizes 8, 12 and 20): a text
# box is 1.3 em per line (svg_text_utils LINE_SPACING); the axis title sits
# `title.standoff` px (plotly_white sets 15) above the tick labels; an axis
# title defaults to round(1.2 x) the layout font size, plotly's 5 px ticks.
const _AXES_LINE_HEIGHT_EM = 1.3
const _AXES_TITLE_FONT_FACTOR = 1.2
const _AXES_TITLE_STANDOFF = 15.0
const _AXES_PLOTLY_TICKLEN = 5.0
# Gap between the top axis title and the figure title placed above it.
const _AXES_FIGURE_TITLE_GAP = 6.0

_axes_size(value, default::Float64) =
	(value isa Real && !(value isa Bool) && isfinite(value) && value > 0) ?
	Float64(value) : default

# Template layout entry `key` (e.g. :xaxis), or `nothing`.
function _axes_template_entry(layout::Layout, key::Symbol)
	template = get(layout.fields, :template, nothing)
	template isa PlotlyBase.Template || return nothing
	return get(_template_layout_fields(template), key, nothing)
end

# Estimated height in px of a top x axis's tick labels and title above the
# plot area. `axis` holds the axis fields about to be written.
function _axes_top_axis_depth(layout::Layout, axis::AbstractDict{Symbol})
	root = _tight_root_font_size(key -> get(layout.fields, key, nothing))
	template_axis = _axes_template_entry(layout, :xaxis)
	tick_size = _axes_size(
		_cmn_mapping_get(get(axis, :tickfont, nothing), :size),
		_axes_size(_cmn_mapping_get(_cmn_mapping_get(template_axis, :tickfont), :size), root),
	)
	ticklen = get(axis, :ticks, "outside") == "outside" ?
		_axes_size(get(axis, :ticklen, nothing), _AXES_PLOTLY_TICKLEN) : 0.0
	linewidth = _axes_size(get(axis, :linewidth, nothing), 1.0)
	depth = ticklen + _AXES_LINE_HEIGHT_EM * tick_size + (linewidth - 1)
	title = get(axis, :title, nothing)
	text = _tight_title_text(title)
	if !isempty(text)
		template_title = _cmn_mapping_get(template_axis, :title)
		title_size = _axes_size(
			_cmn_mapping_get(_cmn_mapping_get(title, :font), :size),
			_axes_size(
				_cmn_mapping_get(_cmn_mapping_get(template_title, :font), :size),
				Float64(round(_AXES_TITLE_FONT_FACTOR * root)),
			),
		)
		standoff = _axes_size(
			_cmn_mapping_get(title, :standoff),
			_axes_size(_cmn_mapping_get(template_title, :standoff), _AXES_TITLE_STANDOFF),
		)
		# The text-extent estimate shared with the decoration stack (D12):
		# 1.3 em per plain line, taller rows for MathJax fractions and roots.
		depth += standoff + _text_extent(text, title_size)[2]
	end
	return depth
end

# Whether cell `t` reaches the top of the figure's plot region (no other cell
# above it), so a top axis there sits under the figure title.
function _axes_is_top_cell(fig, t::_CellTarget)
	fig isa SubplotFigure || return true
	top = t.ydomain[2]
	grid_ref = _cmn_layout(fig).subplots.grid_ref
	for r in 1:getfield(fig, :rows), c in 1:getfield(fig, :cols)
		(
			checkbounds(Bool, grid_ref, r, c) &&
			isassigned(grid_ref, r, c) &&
			!isempty(grid_ref[r, c])
		) || continue
		other = _cell_target(fig; row = r, col = c, who = "secondary_xaxis!")
		other.ydomain[2] > top + 1e-9 && return false
	end
	return true
end

# Title placement that keeps a figure title with no placement of its own clear
# of a top axis of depth `depth` px: the title sits on the plot area
# (`yref="paper"`, `y=1`, `yanchor="bottom"`) lifted by `pad.b`, and
# `automargin` grows the top margin to fit it (plotly.js grows a margin to the
# larger of its pushers, not their sum). The `title!`/constructor placement
# (container, top) is kept: the room engine clears it when the figure is
# finalized. `nothing` when that is so or the user placed the title (any of
# `y`, `yref`, `yanchor` set to something else). A larger `pad.b` from an
# earlier call (another top axis) is kept.
function _axes_title_clearance(layout::Layout, depth::Float64)
	title = get(layout.fields, :title, nothing)
	fields = Dict{Symbol, Any}()
	if title isa AbstractString
		fields[:text] = String(title)
		title = nothing
	end
	yref = _cmn_mapping_get(title, :yref)
	y = _cmn_mapping_get(title, :y)
	yanchor = _cmn_mapping_get(title, :yanchor)
	ours = yref == "paper" && y isa Real && y == 1 && yanchor == "bottom"
	untouched = yref === nothing && y === nothing && yanchor === nothing
	# The `title!` (and constructor) placement at the top of the container.
	container = yref == "container" && y isa Real && y == 1 && yanchor == "top"
	(ours || untouched || container) || return nothing
	# The `title!` placement (and the constructor's, Z28) is kept as it is: the
	# D12 room engine (`_lt_title_decoration!`) holds the top margin for the
	# title band above the top axis when the figure is finalized.
	container && return nothing
	pad_b = ceil(depth + _AXES_FIGURE_TITLE_GAP)
	if ours
		existing = _cmn_mapping_get(_cmn_mapping_get(title, :pad), :b)
		existing isa Real && !(existing isa Bool) && (pad_b = max(pad_b, Float64(existing)))
	end
	fields[:yref] = "paper"
	fields[:y] = 1
	fields[:yanchor] = "bottom"
	fields[:automargin] = true
	fields[:pad] = attr(b = pad_b)
	return fields
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
	root = _axes_match_root(fig, t.xkey, who)
	axis_type = _axis_type(layout, root)
	axis_type in ("-", "linear", "log") || throw(ArgumentError(
		"$(who): needs a numeric (linear or log) x axis; $(repr(root)) has " *
		"type $(repr(axis_type)).",
	))
	# An untyped axis is typed by plotly.js from its data: dates or text make it
	# a date or category axis, which has no numeric transform `f` could map.
	axis_type == "-" && any(m -> _axes_has_nonnumeric_data(fig, m), _axes_match_members(fig, root, who)) &&
		throw(ArgumentError(
			"$(who): needs a numeric (linear or log) x axis; $(repr(root)) " *
			"shows text or date data (plotly.js makes it a category or date axis).",
		))
	log_axis = axis_type == "log"
	primary_side = _cmn_mapping_get(get(layout.fields, t.xkey, nothing), :side)
	primary_side isa AbstractString || (primary_side = "bottom")
	# W5: on a bottom primary axis, `side = :bottom` is a second label row.
	stacked = primary_side == side_name
	(stacked && side_name != "bottom") && throw(ArgumentError(
		"$(who): the primary x axis is already on the $(side_name); put the " *
		"secondary axis on the other side.",
	))

	# Range of the primary axis in data units. plotly.js cannot link an axis
	# transform, so the ticks are computed for this range, and an automatic
	# range is frozen to the data extent below.
	explicit = _from_axis_range(layout, root)
	# A field plot's tight range (cell edges, not centres) is known too.
	known = explicit === nothing ? _axes_known_range(fig, root) : explicit
	limits = known === nothing ? _axes_group_extent(fig, root, who) : known
	limits === nothing && throw(ArgumentError(
		"$(who): the x range of this cell is unknown; add data or set it with " *
		"`xrange!` first.",
	))
	if known === nothing
		# A one-sided limit (D11) pins its end of the range frozen below.
		fixed_min, fixed_max = _stored_axis_limits(layout, root)
		to_data(v) = log_axis ? exp10(Float64(v)) : Float64(v)
		limits = (
			fixed_min === nothing ? limits[1] : to_data(fixed_min),
			fixed_max === nothing ? limits[2] : to_data(fixed_max),
		)
	end
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
		_axes_secondary_auto_ticks(
			lo2,
			hi2,
			log_axis,
			who;
			fits = _axes_secondary_label_fit(fig, t, finv, lower, upper, log_axis),
		)
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
		_axes_power_ticktext(tick_values, log_axis) :
		_cmn_tick_labels(ticklabels, length(tick_values), who)
	if stacked
		# A second label row starts one text line per primary label line lower.
		primary_text = _cmn_mapping_get(get(layout.fields, t.xkey, nothing), :ticktext)
		lines = primary_text isa AbstractVector ? maximum(
			(label isa AbstractString ? 1 + count(r"<br\s*/?>", label) : 1 for label in primary_text);
			init = 1) : 1
		text = String["<br>"^lines * label for label in text]
	end
	title_text = _label(title)

	# The axis: reuse the one a previous call created for this cell axis
	# (found through its named dummy trace), else the next free index.
	name = "plotlysupply:secondary_xaxis:" * t.xref * (stacked ? ":row" : "")
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
	# An inset's axes stay inside the host cell and must not push the figure
	# margins (as the inset's own axes).
	in_inset = fig isa SubplotFigure &&
		any(record -> record.xkey === t.xkey, getfield(fig, :insets))
	axis_ink = _figure_axis_defaults(_cmn_plot(fig); axis = :x)

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
		# The tick direction of the primary axis (the style's: "inside" under
		# :ieee, axes-ticks-05), "outside" when it has no tick marks.
		:ticks => let direction = _axes_tick_direction(layout, t.xkey)
			isempty(direction) ? "outside" : direction
		end,
		:automargin => !in_inset,
		# Y9: the ink of the figure's template (white lines on plotly_dark);
		# the primary axis's own line style is copied over it below.
		:linecolor => axis_ink[:linecolor],
		:linewidth => axis_ink[:linewidth],
		:tickcolor => axis_ink[:tickcolor],
		:title => attr(text = title_text),
	)
	axis_type == "-" || (fields[:type] = axis_type)
	_cmn_copy_axis_style!(fields, get(layout.fields, t.xkey, nothing))
	if stacked
		# The primary's tick direction and length (so the rows start alike),
		# with invisible marks and no axis line.
		primary_ticks = _cmn_mapping_get(get(layout.fields, t.xkey, nothing), :ticks)
		primary_ticks isa AbstractString ? (fields[:ticks] = primary_ticks) : delete!(fields, :ticks)
		fields[:tickcolor] = "rgba(0,0,0,0)"
		fields[:showline] = false
		# Horizontal: plotly.js tilts labels it finds close together, which
		# would break the line offset above (render: optical_cividis (d)).
		fields[:tickangle] = 0
		# plotly.js reserves a title line below an axis whose title text is ""
		# (render probe: a blank band under the row), so no title leaves the
		# text unset.
		if isempty(title_text)
			kept = _symbol_dict(fields[:title])
			delete!(kept, :text)
			isempty(kept) ? delete!(fields, :title) : (fields[:title] = attr(; kept...))
		end
	end
	title_clearance = (side_name == "top" && !in_inset && _axes_is_top_cell(fig, t)) ?
		_axes_title_clearance(layout, _axes_top_axis_depth(layout, fields)) :
		nothing

	# --- write ---
	# A field plot's tight range stays as `_finalize_figure!` keeps it (its
	# clip pins the autorange to exactly that interval; a range equal to the
	# clip is turned back into that autorange, finalize.jl `_fin_sticky_updates!`).
	if known === nothing
		# Frozen in the axis's direction; one-sided limits of the group go.
		reversed = _axis_is_reversed(fig, root)
		frozen = log_axis ? Float64[log10(lower), log10(upper)] : Float64[lower, upper]
		_write_axis_range!(
			fig,
			root,
			reversed ? reverse(frozen) : frozen;
			reversed = reversed,
			members = _axes_match_members(fig, root, who),
		)
	end
	# A row replaced without a title drops the previous row's title text.
	(stacked && isempty(title_text) && existing_ref !== nothing) &&
		_cmn_delete_layout_fields!(fig, key, (:text,); nested = :title)
	_cmn_merge_layout_key!(fig, key, fields; nested = (:title,))
	title_clearance === nothing ||
		_cmn_merge_layout_key!(fig, :title, title_clearance; nested = (:pad,))
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
	# The primary stops mirroring its ticks onto the new axis's side
	# (axes-ticks-05): that spine shows the secondary scale only.
	_axes_apply_twin_mirrors!(fig)
	# The stack above the axes changed (D12, Z15): panel titles, legends above
	# the cell and the figure title band move above the new top axis, and the
	# top margin grows to hold them.
	_text_restack!(fig)
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
the primary range: the explicit range when one is set, else the tight
cell-edge range of a heatmap/image cell (which the figure keeps), otherwise
the data extent of the (shared) axis with any one-sided limit of
[`xrange!`](@ref) applied, which is then written as an explicit range (in the
axis's direction).
Set the final range with [`xrange!`](@ref) before calling this.

# Arguments
- `f`: the transform, strictly monotone on the x range (checked at 101
  points; also on log axes).
- `finv`: its inverse; `finv(f(x)) ≈ x` is checked at the same points.

# Keywords
- `ticks = nothing`: tick values in the secondary units (data values of
  `f`, never log10 exponents, also on a logarithmic primary axis; each is
  placed at the DATA position `finv(tick)`); `nothing` chooses 1-2-5 values
  inside `f(range)` (powers of ten on a log axis spanning a decade or more).
- `ticklabels = nothing`: one label per tick (through the mathtext layer);
  requires `ticks`. Default: the values with six significant digits.
- `title::AbstractString = ""`: axis title.
- `side = :top`: `:top` or `:bottom`; must differ from the primary side,
  except `:bottom` on a bottom primary axis, which adds a second label row
  (below).
- `row`, `col`: SubplotFigure cell (both or neither; default the active cell,
  which the call makes active); `inset = k` targets inset `k`.

The new axis copies the primary x axis's `title.font`, `tickfont`,
`linecolor`, `linewidth`, `tickcolor`, `ticklen` and `tickwidth` where the
primary sets them (else the ink of the figure's template, light on a dark
template; later changes to the primary are not followed), has no
grid lines, and (except in an inset) pushes the
figure margin to fit its labels. Calling it again for the same axis replaces
the secondary axis (idempotent). The axis needs a hidden dummy trace (named
`"plotlysupply:secondary_xaxis:<x ref>"`, `":row"` appended for a second
label row, `visible = false`), because plotly.js only draws axes that a trace
uses.

Figure title: plotly.js sizes the top margin for the larger of the figure
title and the top axis, not their sum, so a default-placed title would
overlap a top secondary axis in the top row. The title is therefore placed
on the plot area (`title.yref = "paper"`, `y = 1`, `yanchor = "bottom"`,
`automargin = true`) and lifted by `title.pad.b`, the axis's estimated
height (from the font sizes at call time) plus 6 px. This also holds for a
title set later. A title at the top of the figure (`title!`, or a
constructor's `title`) keeps its place and gets the same room as
`title.pad.b`. Any other title the user placed (`y`, `yref` or `yanchor` set)
is left alone. Subplot titles of the same cell, and cells above an interior
cell, are not moved: leave room with `vertical_spacing`.

Second label row: `side = :bottom` on a bottom primary axis draws no axis
line and no tick marks; its labels sit one text line below the primary tick
labels (one line per line of the primary's tick labels at call time) and are
never tilted, which suits group captions under grouped ticks (`f = finv =
identity`, `ticks` at the group centres). Its `title` is drawn below that
row, so give the axis title there and leave the primary's empty:

```julia
fig = plot_scatter(1:7, rand(7))
xticks!(fig, 1:7, ["−40", "−20", "+20", "+40", "−0.1", "+0.1", "+0.2"])
secondary_xaxis!(fig, identity, identity; side = :bottom, ticks = [2.5, 6],
	ticklabels = ["wall shift (nm)", "detuning (%)"], title = "parameter")
```

Returns `nothing` (`sf` for a SubplotFigure).

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
	_axes_reject_unknown(kwargs, _AXES_SECONDARY_X_KEYWORDS, "secondary_xaxis!")
	_axes_secondary_xaxis!(fig, f, finv; kwargs...)
	return nothing
end

function secondary_xaxis!(sf::SubplotFigure, f, finv; show = nothing, kwargs...)
	_axes_reject_show(show, "secondary_xaxis!")
	_axes_reject_unknown(kwargs, _AXES_SECONDARY_X_KEYWORDS, "secondary_xaxis!")
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

# `(x0, y0, width, height)` of `inset!` as fractions. With `unit = true`
# (`coords = :paper`) every value and both far edges lie in [0, 1]. With
# `unit = false` (`coords = :axes`) the box may reach outside the host plot
# area (matplotlib `inset_axes([1.05, 0, 0.25, 1])`); `_axes_inset!` then
# checks that it stays inside the figure.
function _axes_inset_bounds(bounds, who::AbstractString; unit::Bool = true)
	((bounds isa Tuple || bounds isa AbstractVector) && length(bounds) == 4) ||
		throw(ArgumentError(
			"$(who): `bounds` must be (x0, y0, width, height) as a 4-tuple or " *
			"4-vector; got $(repr(bounds)).",
		))
	values = Float64[]
	for (name, v) in zip(("x0", "y0", "width", "height"), bounds)
		(v isa Real && !(v isa Bool) && isfinite(v)) || throw(ArgumentError(
			"$(who): bounds `$(name)` must be a finite number; got $(repr(v)).",
		))
		(unit && !(0 <= v <= 1)) && throw(ArgumentError(
			"$(who): bounds `$(name)` must be a number in [0, 1]; got $(repr(v)).",
		))
		push!(values, Float64(v))
	end
	x0, y0, w, h = values
	(w > 0 && h > 0) || throw(ArgumentError(
		"$(who): the inset width and height must be positive; got $(repr(bounds)).",
	))
	unit || return (x0, y0, w, h)
	# Tolerance for fractions such as 0.7 + 0.3, which exceed 1 by one ulp.
	x0 + w <= 1 + 1e-12 || throw(ArgumentError(
		"$(who): x0 + width = $(x0 + w) exceeds 1.",
	))
	y0 + h <= 1 + 1e-12 || throw(ArgumentError(
		"$(who): y0 + height = $(y0 + h) exceeds 1.",
	))
	return (x0, y0, w, h)
end

# Tolerance (paper fraction) for an inset domain computed from host-relative
# fractions: rounding of e.g. 0.55 + 0.45 * (0.6 - 0.55) may pass 1 by an ulp.
const _AXES_INSET_DOMAIN_TOL = 1e-9

function _axes_inset!(
	sf::SubplotFigure,
	bounds;
	row = nothing,
	col = nothing,
	coords::Union{Symbol, AbstractString} = :axes,
	sharex::Bool = false,
	sharey::Bool = false,
	background = nothing,
	ticklabel_halo::Bool = true,
	fontsize::Union{Nothing, Real} = nothing,
)
	who = "inset!"
	coords_name = Symbol(coords)
	coords_name in (:axes, :paper, :data) || throw(ArgumentError(
		"$(who): `coords` must be :axes (fractions of the host cell), :data " *
		"(host data coordinates) or :paper; got $(repr(coords)).",
	))
	host = _cell_target(sf; row = row, col = col, who = who)
	_axes_require_xy(host, who, "an inset")
	x0, y0, w, h = coords_name === :data ?
		_axes_inset_data_bounds(sf, host, bounds, who) :
		_axes_inset_bounds(bounds, who; unit = coords_name === :paper)
	fill = background === nothing ? nothing :
		_cmn_check_color(background, "background", who)
	(fill === nothing || !isempty(fill)) || throw(ArgumentError(
		"$(who): `background` must be a colour or `nothing` (the figure's " *
		"`plot_bgcolor`); got \"\".",
	))
	(fontsize === nothing || (_is_plain_real(fontsize) && fontsize > 0)) || throw(ArgumentError(
		"$(who): `fontsize` must be a positive number or `nothing` (one step " *
		"smaller than the host's tick labels); got $(repr(fontsize)).",
	))
	fraction(domain, a, b) = (
		domain[1] + a * (domain[2] - domain[1]),
		domain[1] + b * (domain[2] - domain[1]),
	)
	xdomain, ydomain = if coords_name === :paper
		((x0, min(x0 + w, 1.0)), (y0, min(y0 + h, 1.0)))
	else
		(fraction(host.xdomain, x0, x0 + w), fraction(host.ydomain, y0, y0 + h))
	end
	# An `:axes` box outside the host plot area (Z36) must still lie inside
	# the figure: plotly.js draws axes only within paper [0, 1] and clamps a
	# domain outside it, which would squeeze the inset and change its scale.
	for (letter, domain) in (("x", xdomain), ("y", ydomain))
		(domain[1] >= -_AXES_INSET_DOMAIN_TOL && domain[2] <= 1 + _AXES_INSET_DOMAIN_TOL) ||
			throw(ArgumentError(
				"$(who): the inset's $(letter) extent is paper " *
				"$(round(domain[1]; digits = 3)) .. $(round(domain[2]; digits = 3)), " *
				"outside the figure (plotly.js draws axes only inside paper [0, 1]). " *
				"Keep it inside the figure; for a panel beside the axes give it its own " *
				"grid cell, e.g. `subplots(1, 2; width_ratios = [4, 1], " *
				"shared_yaxes = true)`.",
			))
	end
	xdomain = (clamp(xdomain[1], 0.0, 1.0), clamp(xdomain[2], 0.0, 1.0))
	ydomain = (clamp(ydomain[1], 0.0, 1.0), clamp(ydomain[2], 0.0, 1.0))

	p = _cmn_plot(sf)
	layout = p.layout
	# Y9: frame in the ink of the figure's template (white on plotly_dark).
	ink = _figure_axis_defaults(p; axis = :x)
	# Tick labels one matplotlib size step (1.2x) below the host's.
	root_size = _tight_root_font_size(key -> get(layout.fields, key, nothing))
	host_tick = _axes_size(
		_cmn_mapping_get(_cmn_mapping_get(get(layout.fields, host.xkey, nothing), :tickfont), :size),
		_axes_size(
			_cmn_mapping_get(_cmn_mapping_get(_axes_template_entry(layout, :xaxis), :tickfont), :size),
			root_size,
		),
	)
	tick_size = fontsize === nothing ?
		round(host_tick / _AXES_INSET_FONT_STEP; digits = 1) : Float64(fontsize)
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
		:linecolor => ink[:linecolor],
		:linewidth => ink[:linewidth],
		:tickcolor => ink[:tickcolor],
		:tickfont => attr(size = tick_size),
	)
	if ticklabel_halo
		# The tick labels and titles sit outside the inset's (opaque) plot
		# area, over the host cell's data; plotly.js `font.shadow = "auto"`
		# draws a halo in the contrast colour of the text behind each glyph
		# (render-verified over a heatmap, inset_bg_shadow.png).
		frame[:tickfont] = attr(size = tick_size, shadow = _AXES_INSET_HALO)
		frame[:title] = attr(font = attr(shadow = _AXES_INSET_HALO))
	end
	xfields = merge(frame, Dict{Symbol, Any}(:domain => collect(xdomain), :anchor => yref))
	yfields = merge(frame, Dict{Symbol, Any}(:domain => collect(ydomain), :anchor => xref))
	# The inset shows a grid where its host does (vm-15): a grid-free style
	# writes `showgrid = false` on the host axes, which plotly.js would
	# otherwise not apply to the new axes (matplotlib insets follow rcParams).
	for (host_key, fields) in ((host.xkey, xfields), (host.ykey, yfields))
		host_grid = _cmn_mapping_get(get(layout.fields, host_key, nothing), :showgrid)
		host_grid isa Bool && (fields[:showgrid] = host_grid)
	end
	root_autorange = Dict{Symbol, Bool}()
	for (share, host_key, fields) in ((sharex, host.xkey, xfields), (sharey, host.ykey, yfields))
		share || continue
		root = _axes_match_root(sf, host_key, who)
		fields[:matches] = _cmn_axis_ref(root; who = who)
		# Matched axes must have the same type.
		axis_type = _axis_type(layout, root)
		axis_type == "-" || (fields[:type] = axis_type)
		root_entry = get(layout.fields, root, nothing)
		exponent = _cmn_mapping_get(root_entry, :exponentformat)
		exponent isa AbstractString && (fields[:exponentformat] = exponent)
		# plotly.js 2.35.2 (cartesian layout defaults) does not reset its
		# "explicit range seen" flag between match groups: a group whose root
		# leaves `autorange` unset gets `autorange = false`, and so the default
		# range [-1, 4], whenever an earlier group has an explicit range (an
		# `xrange!`, a `secondary_xaxis!`). Stating the root's autorange (true
		# unless it has a range) keeps the shared range as it was.
		_cmn_mapping_get(root_entry, :autorange) === nothing &&
			(root_autorange[root] = first(_stored_axis_range(layout, root)) === nothing)
	end
	_cmn_merge_layout_key!(sf, xkey, xfields; nested = (:title,))
	_cmn_merge_layout_key!(sf, ykey, yfields; nested = (:title,))
	for (root, value) in root_autorange
		_cmn_merge_layout_key!(sf, root, Dict{Symbol, Any}(:autorange => value))
	end
	if fill !== nothing
		# Drawn in the inset's own shape layer: above the plot-area fill and
		# the host cell, below the inset's traces.
		_upsert_named!(
			sf,
			:shapes,
			"$(_AXES_INSET_BACKGROUND_NAME):$(xref)",
			[attr(
				type = "rect",
				xref = "$(xref) domain",
				yref = "$(yref) domain",
				x0 = 0,
				x1 = 1,
				y0 = 0,
				y1 = 1,
				layer = "below",
				fillcolor = fill,
				line = attr(width = 0),
			)];
			who = who,
		)
	end
	insets = getfield(sf, :insets)
	push!(
		insets,
		_SubplotInset(host.row, host.col, xkey, ykey, xref, yref, xdomain, ydomain),
	)
	_axes_select!(sf, host)
	_axes_finish!(sf)
	return length(insets)
end

# plotly.js `font.shadow` value for inset tick labels and titles: "auto" is a
# halo in the contrast colour of the text (white behind dark text).
const _AXES_INSET_HALO = "auto"
# One step of matplotlib's relative font sizes ("small" = "medium" / 1.2).
const _AXES_INSET_FONT_STEP = 1.2

# The drawn range of Cartesian axis `root` in data units, in drawing order,
# when it is known before rendering: an explicit range, or the tight range of
# a field plot (`_finalize_figure!`'s autorange clip: `clipmin`/`clipmax`
# with `include` holding both, which pins the autorange to exactly that
# interval). `nothing` otherwise.
function _axes_known_range(fig, root::Symbol)
	layout = _cmn_layout(fig)
	explicit = _from_axis_range(layout, root)
	explicit === nothing || return explicit
	entry = get(layout.fields, root, nothing)
	_cmn_mapping_get(entry, :autorange) === false && return nothing
	options = _cmn_mapping_get(entry, :autorangeoptions)
	lo, hi = _cmn_mapping_get(options, :clipmin), _cmn_mapping_get(options, :clipmax)
	include = _cmn_mapping_get(options, :include)
	(_is_plain_real(lo) && _is_plain_real(hi) && lo < hi) || return nothing
	(include isa AbstractVector && any(v -> v == lo, include) && any(v -> v == hi, include)) ||
		return nothing
	_axis_is_reversed(fig, root) && return (Float64(hi), Float64(lo))
	return (Float64(lo), Float64(hi))
end

# `(x0, y0, width, height)` given in the host cell's DATA coordinates, as
# fractions of the host plot area: the host axes need a fixed range (data
# units, log axes in data values), and the box must lie inside it.
function _axes_inset_data_bounds(sf, host::_CellTarget, bounds, who::AbstractString)
	((bounds isa Tuple || bounds isa AbstractVector) && length(bounds) == 4) ||
		throw(ArgumentError(
			"$(who): `bounds` must be (x0, y0, width, height) as a 4-tuple or " *
			"4-vector; got $(repr(bounds)).",
		))
	for (name, v) in zip(("x0", "y0", "width", "height"), bounds)
		_is_plain_real(v) || throw(ArgumentError(
			"$(who): bounds `$(name)` must be a finite number; got $(repr(v)).",
		))
	end
	x0, y0, w, h = Float64.(Tuple(bounds))
	(w > 0 && h > 0) || throw(ArgumentError(
		"$(who): the inset width and height must be positive; got $(repr(bounds)).",
	))
	layout = _cmn_layout(sf)
	out = Float64[]
	for (letter, key, a, b) in (('x', host.xkey, x0, x0 + w), ('y', host.ykey, y0, y0 + h))
		root = _axes_match_root(sf, key, who)
		r = _axes_known_range(sf, root)
		r === nothing && throw(ArgumentError(
			"$(who): `coords = :data` needs a fixed numeric $(letter) range on the host " *
			"cell (the inset is placed when the call runs); set it with " *
			"`$(letter)range!(sf, (lo, hi); row, col)` first.",
		))
		log_axis = _axis_type(layout, root) == "log"
		if log_axis
			(a > 0 && b > 0) || throw(ArgumentError(
				"$(who): the $(letter) bounds of the inset are on a logarithmic axis " *
				"and must be positive; got $(a) .. $(b).",
			))
		end
		t(v) = log_axis ? log10(v) : v
		lo, hi = t(r[1]), t(r[2])
		fa, fb = (t(a) - lo) / (hi - lo), (t(b) - lo) / (hi - lo)
		fa, fb = minmax(fa, fb)   # a reversed host axis
		(fa >= -1e-9 && fb <= 1 + 1e-9) || throw(ArgumentError(
			"$(who): the inset's $(letter) extent $(a) .. $(b) is not inside the host " *
			"$(letter) range $(r[1]) .. $(r[2]).",
		))
		push!(out, clamp(fa, 0.0, 1.0), clamp(fb - fa, 0.0, 1.0))
	end
	return (out[1], out[3], out[2], out[4])
end
# Name prefix of the shape drawn by `inset!(...; background = colour)`.
const _AXES_INSET_BACKGROUND_NAME = "plotlysupply:inset_background"

"""
	inset!(sf::SubplotFigure, bounds; row=nothing, col=nothing, coords=:axes, sharex=false, sharey=false, background=nothing, ticklabel_halo=true, fontsize=nothing) -> Int

Add inset axes to a SubplotFigure cell and return the inset id `k`. Pass
`inset = k` to the axis helpers ([`xlabel!`](@ref), [`xrange!`](@ref),
[`xticks!`](@ref), [`grid!`](@ref), ...) to style it; plot calls route traces
there with `inset = k` (traces may also name the axes directly: `xaxis` /
`yaxis` are `sf.insets[k].xref` / `.yref`). [`remove_inset!`](@ref) deletes
it again.

# Arguments
- `bounds`: `(x0, y0, width, height)` (tuple or vector).
  With `coords = :axes` they are fractions of the host cell's plot area; the
  box may reach outside it (matplotlib `inset_axes([1.05, 0, 0.25, 1])`: a
  panel beside the axes, e.g. with `sharey = true`) as long as it stays
  inside the figure (plotly.js draws axes only inside the figure; a box past
  its edge is an `ArgumentError`). A panel beside a cell that already
  reaches the figure edge needs a grid cell of its own instead:
  `subplots(1, 2; width_ratios = [4, 1], shared_yaxes = true)`.
  With `coords = :paper` each is in [0, 1] (fractions of the whole figure),
  and `x0 + width`, `y0 + height` must not exceed 1.
  With `coords = :data` they are host DATA coordinates (data values on log
  axes; the inset spans `x0 .. x0 + width`), converted to fractions of the
  host plot area when the call runs: the host axes need a fixed range
  ([`xrange!`](@ref)/[`yrange!`](@ref), or a field plot's tight range) and
  the box must lie inside it.

# Keywords
- `row`, `col`: host cell (both or neither; default the active cell, which
  the call makes active). The host must be a Cartesian (xy) cell.
- `coords = :axes`: `:axes`, `:data` or `:paper`.
- `sharex`, `sharey`: share the host axis range (`matches`); the inset then
  also takes the host's axis type (and exponent format). The shared root
  axis gets an explicit `autorange` (`true` unless it has a range), which
  plotly.js 2.35 needs to keep the shared range automatic when another
  axis group of the figure has an explicit range. A log host axis
  gives a log inset axis; an unshared inset axis gets its own scale through
  the plot calls (`xscale = "log"` with `inset = k`) and its own range
  through `xrange!(sf, (lo, hi); inset = k)` (DATA units on log axes).
- `background = nothing`: the inset's plot-area colour. `nothing` uses the
  figure's `plot_bgcolor` (see below); a colour string (`"white"`,
  `"#f5f5f5"`, `"rgba(255,255,255,0.8)"`) draws a filled rectangle named
  `"$(_AXES_INSET_BACKGROUND_NAME):<x ref>"` on the inset's domain, above the
  host data and below the inset's traces. A translucent colour lets the
  `plot_bgcolor` fill show through, not the host data.
- `ticklabel_halo::Bool = true`: draw the inset's tick labels and axis
  titles with a halo in the contrasting colour (plotly.js
  `tickfont.shadow = "auto"`), so they stay readable where they extend over
  the host cell's data (images, heatmaps, dense lines). `false` draws plain
  labels. Browsers and the PNG/PDF exports render the halo; an exported SVG
  viewed outside a browser may ignore it (it is a CSS `text-shadow`).
- `fontsize = nothing`: inset tick-label size in px; `nothing` is one
  matplotlib size step (1/1.2) below the host cell's tick labels (their
  `tickfont.size`, else the template's, else the figure font size) when the
  call runs, as matplotlib insets usually are.

Background: the inset's plot area is always opaque. plotly.js fills the plot
area of axes that overlap another cell with the figure's `plot_bgcolor`
(white under the default template; `relayout!(sf, plot_bgcolor = ...)`
changes it for every cell), so host data never shows through the inset; use
`background` for an inset-only colour. The inset axes are boxed (lines and
ticks in the ink of the figure's template: black on light templates, light on
dark ones; outside ticks) and do not push the figure margins. Each call creates
a new inset (ids are 1, 2, ... in creation order; after
[`remove_inset!`](@ref) the later ids move down by one). `inset!` on a
`Plot`/`SyncPlot` is an `ArgumentError`.

Errors (`ArgumentError`, figure unchanged): malformed `bounds` (not four
finite numbers, a non-positive width or height, `:paper` values outside
[0, 1], an `:axes` box reaching outside the figure); with `coords = :data` a
host axis without a fixed numeric
range, non-positive bounds on a log host axis, or a box outside the host
range; an unknown `coords`; a `background` that is not a colour; a
`fontsize` that is not a positive number; a host cell that is not Cartesian.

# Example
```julia
sf = subplots(1, 1; sync = false)
x = collect(0:0.01:10)
plot_scatter!(sf, x, sin.(x) .* exp.(-x ./ 5))
k = inset!(sf, (0.55, 0.55, 0.4, 0.4))
plot_scatter!(sf, x, sin.(x) .* exp.(-x ./ 5); inset = k)
xrange!(sf, (2, 3); inset = k)
```
"""
function inset!(sf::SubplotFigure, bounds; show = nothing, kwargs...)
	_axes_reject_show(show, "inset!")
	_axes_reject_unknown(kwargs, _AXES_INSET_KEYWORDS, "inset!")
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
		"inset!: only a SubplotFigure has insets; got a $(nameof(typeof(fig))). Make one with subplots(1, 1; sync = false).",
	))
end

# Whether layout item `item` (annotation, shape, image) is placed on one of
# the axis references in `refs` ("x5", or "x5 domain").
function _axes_item_uses_refs(item, refs::Set{String})
	mapping = item isa PlotlyBase.AbstractLayoutAttribute ? item.fields : item
	for field in (:xref, :yref)
		ref = _cmn_mapping_get(mapping, field)
		ref isa Symbol && (ref = String(ref))
		ref isa AbstractString || continue
		base = replace(String(ref), r"\s*domain$" => "")
		base in refs && return true
	end
	return false
end

function _axes_remove_inset!(sf::SubplotFigure, k)
	who = "remove_inset!"
	(k isa Integer && !(k isa Bool)) || throw(ArgumentError(
		"$(who): the inset id must be an integer; got $(repr(k)).",
	))
	insets = getfield(sf, :insets)
	1 <= k <= length(insets) || throw(ArgumentError(
		"$(who): unknown inset id $(k); " *
		(isempty(insets) ?
			"this figure has no insets." :
			"valid ids are 1:$(length(insets))."),
	))
	p = _cmn_plot(sf)
	layout = p.layout
	t = _cell_target(sf; inset = Int(k), who = who)
	# The inset's axes and every axis overlaying them (a secondary x axis
	# added with `secondary_xaxis!(...; inset = k)`).
	axis_keys = _axes_cell_axis_keys(layout, t)
	refs = Set{String}(_cmn_axis_ref(key; who = who) for key in axis_keys)
	# Another axis that `matches` one of them would be left pointing at a
	# removed axis.
	for (key, value) in layout.fields
		(key isa Symbol || key isa AbstractString) || continue
		Symbol(key) in axis_keys && continue
		occursin(_CMN_AXIS_KEY_PATTERN, String(key)) || continue
		ref = _cmn_mapping_get(value, :matches)
		ref isa Symbol && (ref = String(ref))
		(ref isa AbstractString && ref in refs) && throw(ArgumentError(
			"$(who): $(repr(Symbol(key))) shares its range with inset $(k) " *
			"(`matches = $(repr(ref))`); remove that link first.",
		))
	end

	# --- write ---
	keep = Bool[
		!(
			trace isa GenericTrace && (
				(let r = get(trace.fields, :xaxis, nothing)
					(r isa Symbol || r isa AbstractString) && String(r) in refs
				end) ||
				(let r = get(trace.fields, :yaxis, nothing)
					(r isa Symbol || r isa AbstractString) && String(r) in refs
				end)
			)
		) for trace in p.data
	]
	all(keep) || keepat!(p.data, keep)
	for field in (:annotations, :shapes, :images)
		items = get(layout.fields, field, nothing)
		items isa AbstractVector || continue
		kept = filter(item -> !_axes_item_uses_refs(item, refs), items)
		length(kept) == length(items) && continue
		relayout!(_cmn_relayout_target(sf); (field => kept,)...)
	end
	for key in axis_keys
		_cmn_mapping_delete!(layout.fields, (key,))
	end
	deleteat!(insets, Int(k))
	_axes_select!(sf, t)
	_axes_finish!(sf)
	return sf
end

"""
	remove_inset!(sf::SubplotFigure, k::Integer) -> sf

Delete inset `k` of a [`SubplotFigure`](@ref) (an id returned by
[`inset!`](@ref)): its x/y axes, any axis overlaying them (a
[`secondary_xaxis!`](@ref) of the inset), the traces drawn on those axes and
the annotations, shapes (including the `background` rectangle) and images
placed on them. The ids of later insets
move down by one (`sf.insets` is a list); a new [`inset!`](@ref) can be
created afterwards. The host cell becomes the active cell.

Errors (`ArgumentError`, figure unchanged): an unknown id, another axis
that `matches` one of the inset's axes, or any keyword (an inset id is unique
in the figure, so `row`/`col` do not apply). On a `Plot`/`SyncPlot` it is an
`ArgumentError` (only SubplotFigures have insets).

# Example
```julia
sf = subplots(1, 1; sync = false)
plot_scatter!(sf, 1:10, rand(10))
k = inset!(sf, (0.6, 0.6, 0.35, 0.35))
remove_inset!(sf, k)
```
"""
function remove_inset!(sf::SubplotFigure, k; show = nothing, kwargs...)
	_axes_reject_show(show, "remove_inset!")
	isempty(kwargs) || throw(ArgumentError(
		"remove_inset!: unsupported keyword(s) " *
		"$(join(("`$(name)`" for name in keys(kwargs)), ", ")); an inset is " *
		"addressed by its id alone (`remove_inset!(sf, k)`; ids are unique in " *
		"the figure, so `row`/`col` do not apply).",
	))
	return _transactional_subplot_mutation!(
		_axes_remove_inset!,
		sf,
		_SUBPLOT_INSET_METADATA_FIELDS,
		k,
	)
end

function remove_inset!(fig, k; kwargs...)
	throw(ArgumentError(
		"remove_inset!: only a SubplotFigure has insets (see `inset!`).",
	))
end
