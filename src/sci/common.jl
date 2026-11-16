# PlotlySupply 2.0 scientific-plotting extensions: cell targeting, log-aware axis coordinates, named annotation/shape upsert, tick/aspect/marker/hatch primitives, legend proxy traces.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_COMMON_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.
#
# Contract for every primitive in this file:
# - `fig` may be a `Plot`, a `SyncPlot`, a staged mutation target
#   (`_StagedPlotMutation`, `_HighLevelStagedPlotMutation`) or a
#   `SubplotFigure` (normally the staged copy handed to an `_impl!` by
#   `_transactional_subplot_mutation!`).
# - All inputs are validated before the first write, so an `ArgumentError`
#   leaves the figure untouched. Messages start with `who`, which callers set
#   to the public function name.
# - Layout writes go through `relayout!` or `_merge_layout_attr!` on the
#   (staged) model; stale keys are removed from the (staged) model in place.
#   Primitives never refresh a renderer: the calling mutator ends with
#   `_refresh!(fig)` as usual.

const _SCI_COMMON_MUTATORS = ()

export log_ticks

# ---------------------------------------------------------------------------
# Model access shared by every primitive
# ---------------------------------------------------------------------------

# The Plot that holds the model a primitive reads and writes. A SubplotFigure
# is unwrapped explicitly (its `fig` field), every other target through
# `_plot_obj` (Plot, SyncPlot and the staged mutation types).
_cmn_plot(fig::SubplotFigure) = _plot_obj(getfield(fig, :fig))
_cmn_plot(fig) = _plot_obj(fig)

_cmn_layout(fig) = _cmn_plot(fig).layout

# Target for `relayout!`: a SubplotFigure forwards to its wrapped figure, which
# is the staged candidate Plot inside a subplot transaction.
_cmn_relayout_target(fig::SubplotFigure) = getfield(fig, :fig)
_cmn_relayout_target(fig) = fig

# Whether an AbstractDict can hold keys of type `T`. Layout containers may be
# user-supplied AbstractDicts that only define `get`/`haskey` for their own key
# type (e.g. Symbol), so a lookup with a String key must not be attempted on
# them: `haskey(d, "x")` would fall back to a `get(d, ::String, ...)` method
# that does not exist.
_cmn_accepts_key(mapping::AbstractDict, ::Type{T}) where {T} =
	T <: keytype(mapping)

# Look up `key` in a layout mapping (PlotlyAttribute, Dict with Symbol or String
# keys, or NamedTuple) without copying it.
function _cmn_mapping_get(mapping, key::Symbol, default = nothing)
	if mapping isa PlotlyBase.PlotlyAttribute
		return _cmn_mapping_get(mapping.fields, key, default)
	elseif mapping isa AbstractDict
		_cmn_accepts_key(mapping, Symbol) && haskey(mapping, key) &&
			return mapping[key]
		if _cmn_accepts_key(mapping, String)
			skey = String(key)
			haskey(mapping, skey) && return mapping[skey]
		end
		return default
	elseif mapping isa NamedTuple
		return get(mapping, key, default)
	end
	return default
end

# Remove `names` from a mutable layout mapping in place. Callers only pass
# containers of the staged model (or a plain Plot they own).
function _cmn_mapping_delete!(mapping, names)
	if mapping isa PlotlyBase.PlotlyAttribute
		return _cmn_mapping_delete!(mapping.fields, names)
	elseif mapping isa AbstractDict
		for name in names
			_cmn_accepts_key(mapping, Symbol) && haskey(mapping, name) &&
				delete!(mapping, name)
			if _cmn_accepts_key(mapping, String)
				skey = String(name)
				haskey(mapping, skey) && delete!(mapping, skey)
			end
		end
	end
	return nothing
end

# Merge `fields` (Symbol => value) into `layout.<key>` without replacing
# sibling attributes; nested mappings named in `nested` (e.g. `:minor`) are
# merged one level deeper instead of being replaced wholesale.
function _cmn_merge_layout_key!(
	fig,
	key::Symbol,
	fields::AbstractDict{Symbol};
	nested::Tuple{Vararg{Symbol}} = (),
)
	isempty(fields) && return nothing
	p = _cmn_plot(fig)
	preserve_root = _preserve_layout_mapping_root(p, key, nested)
	_merge_layout_attr!(
		p.layout,
		key,
		attr(Dict{Symbol, Any}(fields));
		deep_merge_paths = Tuple((name,) for name in nested),
		mutate_builtin_target = preserve_root,
		allow_unsupported_replacement = true,
	)
	return nothing
end

# Delete `names` from `layout.<key>` (or from `layout.<key>.<nested>`).
function _cmn_delete_layout_fields!(
	fig,
	key::Symbol,
	names::Tuple{Vararg{Symbol}};
	nested::Union{Nothing, Symbol} = nothing,
)
	container = get(_cmn_layout(fig).fields, key, nothing)
	nested === nothing ||
		(container = _cmn_mapping_get(container, nested))
	_cmn_mapping_delete!(container, names)
	return nothing
end

# ---------------------------------------------------------------------------
# Axis keys and references
# ---------------------------------------------------------------------------

# Plotly axis ids are "x", "x2", "x3", ...; "x1"/"x0" are not valid ids, so the
# layout keys are `:xaxis`, `:xaxis2`, ... (no `:xaxis1`).
const _CMN_AXIS_KEY_PATTERN = r"^([xy])axis([2-9]|[1-9][0-9]+)?$"

function _cmn_check_axis_key(key::Symbol, who::AbstractString)
	occursin(_CMN_AXIS_KEY_PATTERN, String(key)) ||
		throw(ArgumentError(
			"$(who): $(repr(key)) is not a Cartesian axis layout key " *
			"(expected :xaxis, :xaxis2, ..., :yaxis, :yaxis2, ...).",
		))
	return nothing
end

# `:xaxis3 -> "x3"`, `:yaxis -> "y"`.
function _cmn_axis_ref(key::Symbol; who::AbstractString = "_cmn_axis_ref")
	m = match(_CMN_AXIS_KEY_PATTERN, String(key))
	m === nothing && _cmn_check_axis_key(key, who)
	suffix = m.captures[2]
	return m.captures[1] * (suffix === nothing ? "" : suffix)
end

# 1 for `:xaxis`, N for `:xaxisN`; `nothing` for anything that is not an axis
# key of the given letter.
function _cmn_axis_index(key, letter::Char)
	(key isa Symbol || key isa AbstractString) || return nothing
	m = match(_CMN_AXIS_KEY_PATTERN, String(key))
	(m === nothing || m.captures[1][1] != letter) && return nothing
	suffix = m.captures[2]
	return suffix === nothing ? 1 : parse(Int, suffix)
end

# 1 for "y", N for "yN"; `nothing` otherwise.
function _cmn_axis_ref_index(ref, letter::Char)
	ref isa AbstractString || return nothing
	m = match(r"^([xy])([2-9]|[1-9][0-9]+)?$", ref)
	(m === nothing || m.captures[1][1] != letter) && return nothing
	suffix = m.captures[2]
	return suffix === nothing ? 1 : parse(Int, suffix)
end

# Domain of a y axis. Overlaying axes (secondary/twin y) carry no domain of
# their own and share the domain of the axis they overlay.
function _cmn_y_axis_domain(layout::Layout, ykey::Symbol)
	domain = _layout_axis_domain(layout, ykey)
	domain === nothing || return domain
	overlaying = _cmn_mapping_get(get(layout.fields, ykey, nothing), :overlaying)
	if overlaying isa AbstractString &&
		_cmn_axis_ref_index(overlaying, 'y') !== nothing
		base_key = _axis_layout_key(overlaying, :y)
		if base_key !== ykey
			domain = _layout_axis_domain(layout, base_key)
			domain === nothing || return domain
		end
	end
	return (0.0, 1.0)
end

# ---------------------------------------------------------------------------
# F1: cell targeting
# ---------------------------------------------------------------------------

"""
	_CellTarget

Resolved drawing target of one figure cell (spec §2):

- `kind`: `:xy`, `:scene`, `:polar`, `:ternary`, `:geo`, `:map`, `:mapbox` or
  `:domain`.
- `row`, `col`: the SubplotFigure cell (`0, 0` for a plain Plot/SyncPlot). For
  an inset these are the host cell.
- `xkey`, `ykey`: layout axis keys (`:xaxis3`, `:yaxis3`); `:none` unless
  `kind == :xy`.
- `xref`, `yref`: the matching trace/shape references (`"x3"`, `"y3"`); `""`
  unless `kind == :xy`.
- `scenekey`: `:scene`, `:scene2`, ...; `:none` unless `kind == :scene`.
- `xdomain`, `ydomain`: paper fractions of the cell's plot area.
"""
struct _CellTarget
	kind::Symbol
	row::Int
	col::Int
	xkey::Symbol
	ykey::Symbol
	xref::String
	yref::String
	scenekey::Symbol
	xdomain::NTuple{2, Float64}
	ydomain::NTuple{2, Float64}
end

const _CMN_CELL_KINDS = (
	:xy,
	:scene,
	:polar,
	:ternary,
	:geo,
	:map,
	:mapbox,
	:domain,
)

# Subplot kind of one trace ("xy", "scene", ...), or `nothing` when PlotlyBase
# does not know the trace type. Such traces are skipped when a plain Plot's
# kind is inferred: an unknown trace type must not block axis helpers on the
# known traces next to it. Only the classifier's ArgumentError is absorbed.
function _cmn_trace_kind(trace, cache::Dict{Any, Union{Nothing, String}})
	trace isa GenericTrace || return nothing
	type_value = get(trace.fields, :type, "scatter")
	return get!(cache, type_value) do
		try
			return first(_trace_subplot_kind(trace))
		catch err
			err isa ArgumentError || rethrow()
			return nothing
		end
	end
end

# (kind, layout key) of a plain Plot. 3-D traces win (spec F1); otherwise any
# Cartesian trace makes it :xy; otherwise the first non-Cartesian trace decides.
# An empty figure is classified by its layout (`:xaxis`/`:yaxis` first).
function _cmn_plot_kind(p::Plot)
	cache = Dict{Any, Union{Nothing, String}}()
	has_xy = false
	first_other = nothing
	for trace in p.data
		kind = _cmn_trace_kind(trace, cache)
		kind === nothing && continue
		if kind == "scene"
			ref = get(trace.fields, :scene, "scene")
			return (:scene, Symbol(String(ref)))
		elseif kind == "xy"
			has_xy = true
		elseif first_other === nothing
			first_other = (kind, trace)
		end
	end
	has_xy && return (:xy, :none)
	if first_other !== nothing
		kind_name, trace = first_other
		kind = Symbol(kind_name)
		kind in _CMN_CELL_KINDS || return (:xy, :none)
		kind === :domain && return (:domain, :none)
		ref = kind === :geo ?
			get(trace.fields, :geo, "geo") :
			get(trace.fields, :subplot, kind_name)
		return (kind, Symbol(String(ref)))
	end
	fields = p.layout.fields
	(haskey(fields, :xaxis) || haskey(fields, :yaxis)) && return (:xy, :none)
	for kind in (:scene, :polar, :ternary, :geo, :map, :mapbox)
		haskey(fields, kind) && return (kind, kind)
	end
	return (:xy, :none)
end

# The y axis of a plain Plot that overlays "y" (the twin created by
# `_ensure_twin_y!` or by hand), lowest index first; `nothing` if none.
function _cmn_twin_y_key(layout::Layout)
	best = nothing
	best_index = typemax(Int)
	for (key, value) in layout.fields
		index = _cmn_axis_index(key, 'y')
		(index === nothing || index == 1) && continue
		_cmn_mapping_get(value, :overlaying) == "y" || continue
		if index < best_index
			best = Symbol(key)
			best_index = index
		end
	end
	return best
end

function _cmn_plain_domain(layout::Layout, key::Symbol)
	domain = _layout_subplot_domain(layout, key)
	return domain === nothing ? ((0.0, 1.0), (0.0, 1.0)) : domain
end

function _cmn_check_row_col_types(row, col, who::AbstractString)
	for (name, value) in (("row", row), ("col", col))
		value === nothing && continue
		(value isa Integer && !(value isa Bool)) ||
			throw(ArgumentError(
				"$(who): `$(name)` must be an integer or `nothing`; got $(repr(value)).",
			))
	end
	return nothing
end

"""
	_cell_target(fig_or_sf; row=nothing, col=nothing, secondary_y=false, inset=nothing, who="_cell_target")

Resolve the drawing target (a [`_CellTarget`](@ref)) of a `Plot`, `SyncPlot`,
staged mutation target or `SubplotFigure` cell. `row`/`col` (both or neither)
select a SubplotFigure cell, defaulting to the active cell; they are an
`ArgumentError` on a plain figure. `secondary_y=true` returns the cell's
secondary y axis (a plain Plot needs one from [`_ensure_twin_y!`](@ref)
first). `inset=k` returns inset `k` registered in `sf.insets`. Pure query:
nothing is written.
"""
function _cell_target(
	fig;
	row = nothing,
	col = nothing,
	secondary_y::Bool = false,
	inset = nothing,
	who::AbstractString = "_cell_target",
)
	_cmn_check_row_col_types(row, col, who)
	(row === nothing && col === nothing) ||
		throw(ArgumentError(
			"$(who): `row`/`col` select a SubplotFigure cell; a single " *
			"figure has one cell, so omit them.",
		))
	inset === nothing ||
		throw(ArgumentError(
			"$(who): `inset` needs a SubplotFigure (create one with " *
			"`subplots(1, 1; sync=false)` and add the inset with `inset!`).",
		))
	p = _plot_obj(fig)
	layout = p.layout
	kind, key = _cmn_plot_kind(p)
	if kind === :xy
		ykey = :yaxis
		if secondary_y
			twin = _cmn_twin_y_key(layout)
			twin === nothing && throw(ArgumentError(
				"$(who): this figure has no secondary y-axis (a y axis " *
				"overlaying \"y\"); `secondary_y=true` mutators create it " *
				"with `_ensure_twin_y!`.",
			))
			ykey = twin
		end
		xdomain = something(_layout_axis_domain(layout, :xaxis), (0.0, 1.0))
		return _CellTarget(
			:xy,
			0,
			0,
			:xaxis,
			ykey,
			"x",
			_cmn_axis_ref(ykey; who = who),
			:none,
			xdomain,
			_cmn_y_axis_domain(layout, ykey),
		)
	end
	secondary_y && throw(ArgumentError(
		"$(who): `secondary_y=true` needs Cartesian x/y axes; this figure " *
		"is a :$(kind) figure.",
	))
	if kind === :domain
		xdomain = (0.0, 1.0)
		ydomain = (0.0, 1.0)
		for trace in p.data
			trace isa GenericTrace || continue
			domain_value = get(trace.fields, :domain, nothing)
			domain_value === nothing && continue
			xd = _domain_tuple(_cmn_mapping_get(domain_value, :x))
			yd = _domain_tuple(_cmn_mapping_get(domain_value, :y))
			xd === nothing || (xdomain = xd)
			yd === nothing || (ydomain = yd)
			break
		end
		return _CellTarget(
			:domain, 0, 0, :none, :none, "", "", :none, xdomain, ydomain,
		)
	end
	xdomain, ydomain = _cmn_plain_domain(layout, key)
	return _CellTarget(
		kind,
		0,
		0,
		:none,
		:none,
		"",
		"",
		kind === :scene ? key : :none,
		xdomain,
		ydomain,
	)
end

function _cell_target(
	sf::SubplotFigure;
	row = nothing,
	col = nothing,
	secondary_y::Bool = false,
	inset = nothing,
	who::AbstractString = "_cell_target",
)
	_cmn_check_row_col_types(row, col, who)
	(row === nothing) == (col === nothing) ||
		throw(ArgumentError("$(who): `row` and `col` must be given together."))
	rows = getfield(sf, :rows)
	cols = getfield(sf, :cols)
	if row === nothing
		r = getfield(sf, :current_row)
		c = getfield(sf, :current_col)
	else
		r = Int(row)
		c = Int(col)
		1 <= r <= rows || throw(ArgumentError(
			"$(who): `row` must be in 1:$(rows); got $(r).",
		))
		1 <= c <= cols || throw(ArgumentError(
			"$(who): `col` must be in 1:$(cols); got $(c).",
		))
	end
	p = _cmn_plot(sf)
	layout = p.layout

	if inset !== nothing
		(inset isa Integer && !(inset isa Bool)) ||
			throw(ArgumentError(
				"$(who): `inset` must be an integer inset id or `nothing`; " *
				"got $(repr(inset)).",
			))
		secondary_y && throw(ArgumentError(
			"$(who): an inset has no secondary y-axis; drop `secondary_y` " *
			"or `inset`.",
		))
		insets = getfield(sf, :insets)
		k = Int(inset)
		1 <= k <= length(insets) || throw(ArgumentError(
			"$(who): unknown inset id $(k); " *
			(isempty(insets) ?
				"this figure has no insets (create one with `inset!`)." :
				"valid ids are 1:$(length(insets))."),
		))
		record = insets[k]
		if row !== nothing && (r, c) != (record.row, record.col)
			throw(ArgumentError(
				"$(who): inset $(k) belongs to cell " *
				"($(record.row), $(record.col)), not ($(r), $(c)).",
			))
		end
		return _CellTarget(
			:xy,
			record.row,
			record.col,
			record.xkey,
			record.ykey,
			record.xref,
			record.yref,
			:none,
			something(_layout_axis_domain(layout, record.xkey), record.xdomain),
			something(_layout_axis_domain(layout, record.ykey), record.ydomain),
		)
	end

	grid_ref = layout.subplots.grid_ref
	if !checkbounds(Bool, grid_ref, r, c) ||
		!isassigned(grid_ref, r, c) ||
		isempty(grid_ref[r, c])
		throw(ArgumentError(
			"$(who): subplot cell ($(r), $(c)) is empty (a `missing` spec " *
			"or covered by a row/column span).",
		))
	end
	refs = grid_ref[r, c]
	ref = refs[1]
	kind_name = String(ref.subplot_kind)
	if secondary_y
		(kind_name == "xy" && length(refs) >= 2) ||
			throw(ArgumentError(
				"$(who): subplot cell ($(r), $(c)) has no secondary y-axis; " *
				"create it with `specs=[Spec(secondary_y=true) ...]`.",
			))
		ref = refs[2]
	end
	kind = Symbol(kind_name)
	kind in _CMN_CELL_KINDS || throw(ArgumentError(
		"$(who): subplot cell ($(r), $(c)) has unsupported kind " *
		"$(repr(kind_name)).",
	))

	if kind === :xy
		length(ref.layout_keys) >= 2 || throw(ArgumentError(
			"$(who): subplot cell ($(r), $(c)) has no x/y axis pair.",
		))
		xkey = ref.layout_keys[1]
		ykey = ref.layout_keys[2]
		trace_refs = ref.trace_kwargs.fields
		xref = String(get(trace_refs, :xaxis, _cmn_axis_ref(xkey; who = who)))
		yref = String(get(trace_refs, :yaxis, _cmn_axis_ref(ykey; who = who)))
		return _CellTarget(
			:xy,
			r,
			c,
			xkey,
			ykey,
			xref,
			yref,
			:none,
			something(_layout_axis_domain(layout, xkey), (0.0, 1.0)),
			_cmn_y_axis_domain(layout, ykey),
		)
	elseif kind === :domain
		domain_value = get(ref.trace_kwargs.fields, :domain, nothing)
		xdomain = something(
			_domain_tuple(_cmn_mapping_get(domain_value, :x)),
			(0.0, 1.0),
		)
		ydomain = something(
			_domain_tuple(_cmn_mapping_get(domain_value, :y)),
			(0.0, 1.0),
		)
		return _CellTarget(
			:domain, r, c, :none, :none, "", "", :none, xdomain, ydomain,
		)
	end
	isempty(ref.layout_keys) && throw(ArgumentError(
		"$(who): subplot cell ($(r), $(c)) has no layout key.",
	))
	key = ref.layout_keys[1]
	xdomain, ydomain = _cmn_plain_domain(layout, key)
	return _CellTarget(
		kind,
		r,
		c,
		:none,
		:none,
		"",
		"",
		kind === :scene ? key : :none,
		xdomain,
		ydomain,
	)
end

# ---------------------------------------------------------------------------
# F1: log-aware coordinates
# ---------------------------------------------------------------------------

"""
	_axis_type(layout_or_fig, key::Symbol)::String

The declared `type` of Cartesian axis `key` ("linear", "log", "category",
"date", ...), or `"-"` when unset (Plotly autotypes it; treated as linear).
"""
function _axis_type(layout::Layout, key::Symbol)
	_cmn_check_axis_key(key, "_axis_type")
	value = _cmn_mapping_get(get(layout.fields, key, nothing), :type)
	(value isa AbstractString || value isa Symbol) || return "-"
	type_name = String(value)
	return isempty(type_name) ? "-" : type_name
end

_axis_type(fig, key::Symbol) = _axis_type(_cmn_layout(fig), key)

_cmn_is_log_axis(layout::Layout, key::Symbol) =
	_axis_type(layout, key) == "log"

"""
	_to_axis_coord(layout_or_fig, key, v; who)::Float64

Data value `v` in the units Plotly uses for positions on axis `key`:
`log10(v)` on a log axis (annotation `x`/`y`, axis `range`), `v` otherwise.
Non-finite values, and values `<= 0` on a log axis, are an `ArgumentError`.
"""
function _to_axis_coord(
	layout::Layout,
	key::Symbol,
	v::Real;
	who::AbstractString = "_to_axis_coord",
)
	_cmn_check_axis_key(key, who)
	isfinite(v) || throw(ArgumentError(
		"$(who): coordinate $(v) is not finite.",
	))
	if _cmn_is_log_axis(layout, key)
		v > 0 || throw(ArgumentError(
			"$(who): $(v) cannot be placed on logarithmic axis " *
			"$(repr(key)); log-axis values must be positive.",
		))
		return log10(Float64(v))
	end
	return Float64(v)
end

_to_axis_coord(fig, key::Symbol, v::Real; who::AbstractString = "_to_axis_coord") =
	_to_axis_coord(_cmn_layout(fig), key, v; who = who)

"""
	_to_axis_range(layout_or_fig, key, r; who)::Vector{Float64}

Two-element data range `r` (vector or tuple) converted with
[`_to_axis_coord`](@ref). Reversed ranges are kept as given.
"""
function _to_axis_range(
	layout::Layout,
	key::Symbol,
	r;
	who::AbstractString = "_to_axis_range",
)
	(r isa AbstractVector || r isa Tuple) ||
		throw(ArgumentError(
			"$(who): a range must be a 2-element vector or tuple; got $(typeof(r)).",
		))
	length(r) == 2 || throw(ArgumentError(
		"$(who): a range must have exactly 2 elements; got $(length(r)).",
	))
	lower, upper = first(r), last(r)
	(lower isa Real && upper isa Real) ||
		throw(ArgumentError(
			"$(who): range bounds must be real numbers; got $(repr(r)).",
		))
	return Float64[
		_to_axis_coord(layout, key, lower; who = who),
		_to_axis_coord(layout, key, upper; who = who),
	]
end

_to_axis_range(fig, key::Symbol, r; who::AbstractString = "_to_axis_range") =
	_to_axis_range(_cmn_layout(fig), key, r; who = who)

"""
	_from_axis_range(layout_or_fig, key)::Union{Nothing,NTuple{2,Float64}}

The explicit range of axis `key` in data units (`10 .^ range` on a log axis),
or `nothing` when the axis autoranges (no range, `autorange` other than
`false`, or a partial/non-numeric range).
"""
function _from_axis_range(layout::Layout, key::Symbol)
	_cmn_check_axis_key(key, "_from_axis_range")
	entry = get(layout.fields, key, nothing)
	autorange = _cmn_mapping_get(entry, :autorange)
	(autorange === nothing || autorange === false) || return nothing
	range = _cmn_mapping_get(entry, :range)
	(range isa AbstractVector || range isa Tuple) || return nothing
	length(range) == 2 || return nothing
	lower, upper = first(range), last(range)
	for bound in (lower, upper)
		(bound isa Real && !(bound isa Bool) && isfinite(bound)) ||
			return nothing
	end
	if _cmn_is_log_axis(layout, key)
		return (exp10(Float64(lower)), exp10(Float64(upper)))
	end
	return (Float64(lower), Float64(upper))
end

_from_axis_range(fig, key::Symbol) = _from_axis_range(_cmn_layout(fig), key)

# Trace types whose missing coordinate array is implied by the other one
# (`x0 + dx * (0:n-1)`), and the gridded types whose missing coordinates are
# implied by the shape of `z`. Other types (histograms, boxes, ...) have no
# data values on the axis they do not carry explicitly.
const _CMN_IMPLICIT_VECTOR_TRACES = ("scatter", "scattergl", "bar")
const _CMN_IMPLICIT_GRID_TRACES = (
	"heatmap",
	"heatmapgl",
	"contour",
	"histogram2d",
	"histogram2dcontour",
)

# Number of z samples along the x (`letter == 'x'`) or y direction as Plotly
# reads `z`: rows are y, columns are x, swapped by `transpose=true`. A Julia
# matrix is serialized column by column, so its columns are Plotly rows.
function _cmn_grid_count(z, letter::Char, transposed::Bool)
	along_rows = (letter == 'y') != transposed
	if z isa AbstractMatrix
		return along_rows ? size(z, 2) : size(z, 1)
	elseif z isa AbstractVector && !isempty(z) &&
		all(row -> row isa AbstractVector, z)
		return along_rows ? length(z) : maximum(length, z)
	end
	return nothing
end

function _cmn_implicit_coordinates(fields, letter::Char)
	type_value = get(fields, :type, "scatter")
	type_name = type_value isa Symbol ? String(type_value) : type_value
	type_name isa AbstractString || return nothing
	start = get(fields, Symbol(letter, "0"), 0)
	step = get(fields, Symbol("d", letter), 1)
	(start isa Real && step isa Real && isfinite(start) && isfinite(step)) ||
		return nothing
	count = nothing
	if type_name in _CMN_IMPLICIT_VECTOR_TRACES
		other = get(fields, letter == 'x' ? :y : :x, nothing)
		other isa AbstractVector && (count = length(other))
	elseif type_name in _CMN_IMPLICIT_GRID_TRACES
		count = _cmn_grid_count(
			get(fields, :z, nothing),
			letter,
			get(fields, :transpose, false) === true,
		)
	end
	(count === nothing || count == 0) && return nothing
	return (start + step * i for i in 0:(count - 1))
end

function _cmn_extend_extent(extent, value, positive_only::Bool)
	if value isa AbstractArray || value isa Tuple || value isa Base.Generator
		for item in value
			extent = _cmn_extend_extent(extent, item, positive_only)
		end
		return extent
	end
	(value isa Real && !(value isa Bool)) || return extent
	isfinite(value) || return extent
	(positive_only && value <= 0) && return extent
	v = Float64(value)
	return (min(extent[1], v), max(extent[2], v))
end

"""
	_axis_data_extent(fig, key::Symbol)::Union{Nothing,NTuple{2,Float64}}

`(min, max)` of the finite numeric data that Cartesian traces place on axis
`key` (only positive values on a log axis), including coordinates implied by
`x0`/`dx` (scatter, bar) or by the shape of `z` (heatmap, contour). `nothing`
when no such value exists.
"""
function _axis_data_extent(fig, key::Symbol)
	_cmn_check_axis_key(key, "_axis_data_extent")
	p = _cmn_plot(fig)
	letter = String(key)[1]
	target_ref = _cmn_axis_ref(key)
	field = letter == 'x' ? :xaxis : :yaxis
	default_ref = letter == 'x' ? "x" : "y"
	positive_only = _cmn_is_log_axis(p.layout, key)
	cache = Dict{Any, Union{Nothing, String}}()
	extent = (Inf, -Inf)
	for trace in p.data
		trace isa GenericTrace || continue
		_cmn_trace_kind(trace, cache) == "xy" || continue
		fields = trace.fields
		trace_ref = get(fields, field, default_ref)
		(trace_ref isa AbstractString || trace_ref isa Symbol) || continue
		String(trace_ref) == target_ref || continue
		values = get(fields, Symbol(letter), nothing)
		values === nothing &&
			(values = _cmn_implicit_coordinates(fields, letter))
		values === nothing && continue
		extent = _cmn_extend_extent(extent, values, positive_only)
	end
	return extent[1] <= extent[2] ? extent : nothing
end

# ---------------------------------------------------------------------------
# F1: idempotent named annotations / shapes
# ---------------------------------------------------------------------------

_cmn_item_name(item) = _cmn_mapping_get(item, :name)

_cmn_name_matches(item_name, name::AbstractString) =
	item_name isa AbstractString &&
	(item_name == name || startswith(item_name, name * ":"))

"""
	_upsert_named!(fig, field::Symbol, name::AbstractString, items::AbstractVector; who)

Replace the `layout.annotations` or `layout.shapes` (`field`) entries owned by
`name` with `items`. An entry is owned when its `name` equals `name` or starts
with `name * ":"`; other entries keep their order and the new items are
appended. Items without a `name` are tagged with `name` (one item) or
`"\$name:\$k"` (several), so repeating the call never duplicates them; an item
named outside that namespace is an `ArgumentError`. Written with `relayout!`.
"""
function _upsert_named!(
	fig,
	field::Symbol,
	name::AbstractString,
	items::AbstractVector;
	who::AbstractString = "_upsert_named!",
)
	field in (:annotations, :shapes) || throw(ArgumentError(
		"$(who): `field` must be :annotations or :shapes; got $(repr(field)).",
	))
	isempty(name) && throw(ArgumentError(
		"$(who): the owner name must be non-empty.",
	))
	new_items = Any[]
	for (k, item) in enumerate(items)
		_is_layout_mapping(item) || throw(ArgumentError(
			"$(who): item $(k) must be an attr(...)/Dict; got $(typeof(item)).",
		))
		entry = _symbol_dict(item)
		item_name = get(entry, :name, nothing)
		if item_name === nothing
			entry[:name] = length(items) == 1 ? String(name) : "$(name):$(k)"
		elseif !_cmn_name_matches(item_name, name)
			throw(ArgumentError(
				"$(who): item $(k) is named $(repr(item_name)); it must be " *
				"$(repr(name)) or start with $(repr(name * ":")) so a later " *
				"call can replace it.",
			))
		end
		push!(new_items, attr(entry))
	end
	existing = get(_cmn_layout(fig).fields, field, nothing)
	(existing === nothing || existing isa AbstractVector) ||
		throw(ArgumentError(
			"$(who): layout.$(field) must be a vector; got $(typeof(existing)).",
		))
	kept = Any[]
	if existing !== nothing
		for item in existing
			_cmn_name_matches(_cmn_item_name(item), name) && continue
			push!(kept, item)
		end
	end
	relayout!(
		_cmn_relayout_target(fig);
		(field => vcat(kept, new_items),)...,
	)
	return nothing
end

# ---------------------------------------------------------------------------
# F8: ticks
# ---------------------------------------------------------------------------

# Plotly cannot draw more than a few hundred ticks legibly; capping the decade
# count keeps a degenerate base/range (e.g. base 1 + 1e-9) from allocating an
# unbounded tick vector.
const _CMN_MAX_LOG_DECADES = 2000

function _cmn_normalized_subs(subs, base::Float64, who::AbstractString)
	values = if subs isa Real
		(subs,)
	elseif subs isa Tuple || subs isa AbstractVector
		subs
	else
		throw(ArgumentError(
			"$(who): `subs` must be a real number, tuple or vector of reals; " *
			"got $(typeof(subs)).",
		))
	end
	isempty(values) && throw(ArgumentError("$(who): `subs` must not be empty."))
	out = Float64[]
	for s in values
		(s isa Real && !(s isa Bool) && isfinite(s)) || throw(ArgumentError(
			"$(who): `subs` entries must be finite reals; got $(repr(s)).",
		))
		1 <= s < base || throw(ArgumentError(
			"$(who): `subs` entries must lie in [1, base) = [1, $(base)); " *
			"got $(s).",
		))
		push!(out, Float64(s))
	end
	return sort!(unique!(out))
end

# `mantissa * base^k`, computed so that integer mantissas and integral powers
# of an integral base are correctly rounded (`5 / 1000 == 0.005`, whereas
# `5 * 10.0^-3` is one ulp off).
function _cmn_log_tick_value(mantissa::Float64, base::Float64, k::Int)
	return k >= 0 ? mantissa * base^k : mantissa / base^(-k)
end

function _cmn_log_ticks(lo::Float64, hi::Float64, subs::Vector{Float64}, base::Float64, who::AbstractString)
	lower, upper = minmax(lo, hi)
	kmin = floor(Int, log(base, lower)) - 1
	kmax = ceil(Int, log(base, upper)) + 1
	kmax - kmin <= _CMN_MAX_LOG_DECADES || throw(ArgumentError(
		"$(who): [$(lower), $(upper)] spans more than " *
		"$(_CMN_MAX_LOG_DECADES) powers of $(base).",
	))
	# Relative slack for bounds that are themselves computed powers
	# (`exp10(range)`), so an end tick is not lost to one ulp of rounding.
	slack = 1e-9
	out = Float64[]
	for k in kmin:kmax, s in subs
		v = _cmn_log_tick_value(s, base, k)
		(isfinite(v) && v > 0) || continue
		lower * (1 - slack) <= v <= upper * (1 + slack) && push!(out, v)
	end
	return sort!(unique!(out))
end

"""
	log_ticks(lo::Real, hi::Real; subs=(1,), base::Real=10) -> Vector{Float64}

Tick positions for a logarithmic axis between `lo` and `hi` (data units,
either order): every `s * base^k` with `s` in `subs` that falls inside
`[min(lo, hi), max(lo, hi)]`, sorted ascending. This is matplotlib's
`LogLocator(base, subs)`.

# Arguments
- `lo`, `hi`: finite, positive range bounds in data units.

# Keywords
- `subs = (1,)`: mantissas (a real, tuple or vector of reals) in `[1, base)`;
  `(1, 2, 5)` gives 1-2-5 ticks, `1:9` every integer multiple.
- `base::Real = 10`: logarithm base, finite and `> 1`.

Integer mantissas of an integral base are correctly rounded, so
`log_ticks(1e-3, 1; subs=(1, 2, 5))` is exactly
`[0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]`.
Throws `ArgumentError` for non-positive or non-finite bounds, an invalid
`base` or `subs`, or a span of more than 2000 powers of `base`.

# Example
```julia
fig = plot_scatter([1e-3, 1.0], [1.0, 2.0]; xscale = "log")
xticks!(fig, log_ticks(1e-3, 1; subs = (1, 2, 5)))
log_ticks(4, 32; base = 2)   # [4.0, 8.0, 16.0, 32.0]
```
"""
function log_ticks(lo::Real, hi::Real; subs = (1,), base::Real = 10)
	who = "log_ticks"
	for (name, value) in (("lo", lo), ("hi", hi))
		(isfinite(value) && value > 0) || throw(ArgumentError(
			"$(who): `$(name)` must be finite and positive; got $(value).",
		))
	end
	(isfinite(base) && base > 1) || throw(ArgumentError(
		"$(who): `base` must be finite and greater than 1; got $(base).",
	))
	b = Float64(base)
	return _cmn_log_ticks(
		Float64(lo),
		Float64(hi),
		_cmn_normalized_subs(subs, b, who),
		b,
		who,
	)
end

const _CMN_EXPONENT_FORMATS = ("none", "e", "E", "power", "SI", "B")
const _CMN_TICK_DIRECTIONS = ("inside", "outside", "")
# Minor tick length in px chosen by the 2.0 spec (F8): short enough to read
# as minor next to Plotly's 5 px major ticks.
const _CMN_MINOR_TICKLEN = 3
# plotly.js 2.35 defaults `minor.ticklen` to 0.6 * (major `ticklen` || 5)
# (verified in the bundled plotly.min.js tick-defaults code); an explicit minor
# length keeps that ratio when the major length is set (`ticklen` keyword).
const _CMN_MINOR_TICKLEN_RATIO = 0.6
# The d3 format written by default for numeric array ticks on linear axes.
const _CMN_AUTO_TICKFORMAT = "~g"

function _cmn_tick_values(values, log_axis::Bool, who::AbstractString)
	(values isa AbstractVector || values isa Tuple) || throw(ArgumentError(
		"$(who): tick values must be a vector or tuple; got $(typeof(values)).",
	))
	isempty(values) && return Float64[]
	if all(v -> v isa AbstractString, values)
		log_axis && throw(ArgumentError(
			"$(who): a logarithmic axis needs numeric tick values; got strings.",
		))
		return String[String(v) for v in values]
	end
	out = Float64[]
	for v in values
		(v isa Real && !(v isa Bool)) || throw(ArgumentError(
			"$(who): tick values must all be real numbers (or all strings " *
			"on a category/date axis); got $(repr(v)).",
		))
		isfinite(v) || throw(ArgumentError(
			"$(who): tick value $(v) is not finite.",
		))
		(log_axis && v <= 0) && throw(ArgumentError(
			"$(who): tick value $(v) cannot be placed on a logarithmic " *
			"axis; log-axis values must be positive.",
		))
		push!(out, Float64(v))
	end
	return out
end

function _cmn_tick_labels(labels, n::Int, who::AbstractString)
	(labels isa AbstractVector || labels isa Tuple) || throw(ArgumentError(
		"$(who): tick labels must be a vector or tuple of strings; got " *
		"$(typeof(labels)).",
	))
	length(labels) == n || throw(ArgumentError(
		"$(who): got $(length(labels)) tick labels for $(n) tick values.",
	))
	out = String[]
	for label in labels
		label isa AbstractString || throw(ArgumentError(
			"$(who): tick labels must be strings; got $(repr(label)).",
		))
		push!(out, _label(label))
	end
	return out
end

# Matplotlib-style minor ticks for a log axis whose major ticks are explicit:
# mantissas 1..9 in every decade between `lower` and `upper`, minus positions
# that already carry a major tick.
function _cmn_log_minor_values(lower::Float64, upper::Float64, majors, who::AbstractString)
	candidates = _cmn_log_ticks(
		lower,
		upper,
		collect(1.0:9.0),
		10.0,
		who,
	)
	major_values = Float64[v for v in majors if v isa Real]
	return Float64[
		v for v in candidates
		if !any(m -> isapprox(v, m; rtol = 1e-9), major_values)
	]
end

# The explicit array major ticks of an axis layout entry, or `nothing`.
function _cmn_array_tickvals(axis_entry)
	_cmn_mapping_get(axis_entry, :tickmode) == "array" || return nothing
	existing = _cmn_mapping_get(axis_entry, :tickvals)
	return existing isa AbstractVector ? existing : nothing
end

# Explicit minor tick values for log axis `key` whose major ticks are the array
# `majors`: mantissas 1..9 per decade over the explicit range, otherwise over
# the span of the majors and the data extent. `nothing` when the axis is not
# logarithmic or `majors` holds no positive number (Plotly's automatic minor
# ticks are then correct).
function _cmn_log_minor_tickvals(fig, key::Symbol, majors, who::AbstractString)
	layout = _cmn_layout(fig)
	_cmn_is_log_axis(layout, key) || return nothing
	numeric_majors = majors === nothing ? Float64[] :
		Float64[
			v for v in majors
			if v isa Real && !(v isa Bool) && isfinite(v) && v > 0
		]
	isempty(numeric_majors) && return nothing
	limits = _from_axis_range(layout, key)
	if limits === nothing
		lower, upper = extrema(numeric_majors)
		extent = _axis_data_extent(fig, key)
		if extent !== nothing
			lower = min(lower, extent[1])
			upper = max(upper, extent[2])
		end
		limits = (lower, upper)
	end
	return _cmn_log_minor_values(
		minimum(limits),
		maximum(limits),
		numeric_majors,
		who,
	)
end

# Explicit minor tick length: `_CMN_MINOR_TICKLEN_RATIO` times the major
# length (`ticklen` when positive, else the axis's own `ticklen`, else Plotly's
# 5 px default, giving `_CMN_MINOR_TICKLEN`).
function _cmn_minor_ticklen(axis_entry, ticklen::Real)
	major = ticklen > 0 ? ticklen : _cmn_mapping_get(axis_entry, :ticklen)
	(major isa Real && !(major isa Bool) && isfinite(major) && major > 0) ||
		return _CMN_MINOR_TICKLEN
	return _CMN_MINOR_TICKLEN_RATIO * Float64(major)
end

function _cmn_check_tick_size(value, name::AbstractString, who::AbstractString)
	(value isa Real && !(value isa Bool) && isfinite(value) && value >= 0) ||
		throw(ArgumentError(
			"$(who): `$(name)` must be a finite number >= 0 (0 leaves it " *
			"unchanged); got $(repr(value)).",
		))
	return nothing
end

"""
	_apply_ticks!(fig, key::Symbol; values=nothing, labels=nothing, format="", exponentformat="", minor=nothing, subs=nothing, angle=nothing, direction="", tickwidth=0, ticklen=0, who)

Set the ticks of Cartesian axis `key` (spec F8). Only that axis is touched.

- `values`: tick positions in data units (also on log axes); sets
  `tickmode="array"`. Numbers, or strings on category/date axes.
- `labels`: one label per value, each passed through `_label`. Without labels,
  numeric array ticks on a linear axis default to `tickformat="~g"` unless
  `format`, `exponentformat` or an existing `tickformat` says otherwise. On a
  log axis "~g" is never written (it prints 1e+06, ADDENDUM B1): the axis
  keeps its exponent format, and gets `exponentformat="power"` when it has
  none (C17), and an earlier automatic "~g" is removed. Stale `ticktext` from
  an earlier call is removed.
- `subs`: log axes only; ticks are `log_ticks` over the explicit range, else
  over the data extent (`ArgumentError` if neither exists, or if no tick falls
  inside). Mutually exclusive with `values`.
- `format`: d3 `tickformat`; `exponentformat` in
  ("none", "e", "E", "power", "SI", "B"). A d3 `tickformat` takes precedence
  over `exponentformat` in plotly.js, so an `exponentformat` given without
  `format` removes an automatic "~g".
- `minor=true`: minor ticks (`ticks` = `direction` or "outside", length 0.6
  times the major length, 3 px by default); on a log axis with array major
  ticks also explicit minor tick values (mantissas 1..9 per decade).
  `minor=false` removes minor ticks.
- `angle`: `tickangle`; `direction` in ("inside", "outside", "") sets `ticks`
  ("" leaves it unchanged).
- `tickwidth`, `ticklen`: major tick width/length in px (ADDENDUM A6); 0
  leaves them unchanged. A new `ticklen` also rescales explicit minor ticks.
"""
function _apply_ticks!(
	fig,
	key::Symbol;
	values = nothing,
	labels = nothing,
	format::AbstractString = "",
	exponentformat::AbstractString = "",
	minor::Union{Nothing, Bool} = nothing,
	subs = nothing,
	angle::Union{Nothing, Real} = nothing,
	direction::AbstractString = "",
	tickwidth::Real = 0,
	ticklen::Real = 0,
	who::AbstractString = "_apply_ticks!",
)
	_cmn_check_axis_key(key, who)
	layout = _cmn_layout(fig)
	log_axis = _cmn_is_log_axis(layout, key)
	axis_entry = get(layout.fields, key, nothing)

	# --- validate everything before the first write ---
	(exponentformat == "" || exponentformat in _CMN_EXPONENT_FORMATS) ||
		throw(ArgumentError(
			"$(who): `exponentformat` must be one of $(_CMN_EXPONENT_FORMATS) " *
			"or \"\"; got $(repr(exponentformat)).",
		))
	direction in _CMN_TICK_DIRECTIONS || throw(ArgumentError(
		"$(who): `direction` must be \"inside\", \"outside\" or \"\"; got " *
		"$(repr(direction)).",
	))
	(angle === nothing || isfinite(angle)) || throw(ArgumentError(
		"$(who): `angle` must be finite; got $(angle).",
	))
	_cmn_check_tick_size(tickwidth, "tickwidth", who)
	_cmn_check_tick_size(ticklen, "ticklen", who)
	(subs !== nothing && values !== nothing) && throw(ArgumentError(
		"$(who): pass either tick `values` or `subs`, not both.",
	))

	tickvals = nothing
	if subs !== nothing
		log_axis || throw(ArgumentError(
			"$(who): `subs` places ticks per decade and needs a logarithmic " *
			"axis; $(repr(key)) has type $(repr(_axis_type(layout, key))).",
		))
		limits = _from_axis_range(layout, key)
		limits === nothing && (limits = _axis_data_extent(fig, key))
		limits === nothing && throw(ArgumentError(
			"$(who): `subs` needs the extent of $(repr(key)); set an explicit " *
			"range or add data first.",
		))
		tickvals = _cmn_log_ticks(
			limits[1],
			limits[2],
			_cmn_normalized_subs(subs, 10.0, who),
			10.0,
			who,
		)
		isempty(tickvals) && throw(ArgumentError(
			"$(who): no `subs` tick falls inside [$(minimum(limits)), " *
			"$(maximum(limits))]; add mantissas or widen the range.",
		))
	elseif values !== nothing
		tickvals = _cmn_tick_values(values, log_axis, who)
	end

	ticktext = nothing
	if labels !== nothing
		tickvals === nothing && throw(ArgumentError(
			"$(who): tick `labels` need tick `values` (or `subs`).",
		))
		ticktext = _cmn_tick_labels(labels, length(tickvals), who)
	end

	minor_fields = nothing
	clear_minor_array = false
	if minor === true
		minor_fields = Dict{Symbol, Any}(
			:ticks => direction == "" ? "outside" : direction,
			:ticklen => _cmn_minor_ticklen(axis_entry, ticklen),
		)
		majors = tickvals === nothing ? _cmn_array_tickvals(axis_entry) : tickvals
		minor_values = _cmn_log_minor_tickvals(fig, key, majors, who)
		if minor_values === nothing
			clear_minor_array = true
		else
			minor_fields[:tickmode] = "array"
			minor_fields[:tickvals] = minor_values
		end
	elseif minor === false
		minor_fields = Dict{Symbol, Any}(:ticks => "")
		clear_minor_array = true
	elseif ticklen > 0 &&
		_cmn_mapping_get(_cmn_mapping_get(axis_entry, :minor), :ticklen) !== nothing
		# Keep explicit minor ticks proportional to the new major length.
		minor_fields = Dict{Symbol, Any}(
			:ticklen => _cmn_minor_ticklen(axis_entry, ticklen),
		)
	end

	# --- write ---
	existing_format = _cmn_mapping_get(axis_entry, :tickformat)
	numeric_array = tickvals !== nothing && eltype(tickvals) === Float64
	# An automatic "~g" left by an earlier call goes when it would hide the
	# requested exponent format, or when the axis is (now) logarithmic.
	drop_auto_format =
		format == "" &&
		existing_format == _CMN_AUTO_TICKFORMAT &&
		(exponentformat != "" || (log_axis && numeric_array && ticktext === nothing))
	fields = Dict{Symbol, Any}()
	if tickvals !== nothing
		fields[:tickmode] = "array"
		fields[:tickvals] = tickvals
		ticktext === nothing || (fields[:ticktext] = ticktext)
		has_format =
			!drop_auto_format &&
			existing_format isa AbstractString &&
			!isempty(existing_format)
		if ticktext === nothing &&
			numeric_array &&
			format == "" &&
			exponentformat == "" &&
			!has_format
			if log_axis
				existing_exponent = _cmn_mapping_get(axis_entry, :exponentformat)
				(existing_exponent isa AbstractString && !isempty(existing_exponent)) ||
					(fields[:exponentformat] = "power")
			else
				fields[:tickformat] = _CMN_AUTO_TICKFORMAT
			end
		end
	end
	format == "" || (fields[:tickformat] = String(format))
	exponentformat == "" || (fields[:exponentformat] = String(exponentformat))
	angle === nothing || (fields[:tickangle] = angle)
	direction == "" || (fields[:ticks] = String(direction))
	tickwidth > 0 && (fields[:tickwidth] = tickwidth)
	ticklen > 0 && (fields[:ticklen] = ticklen)
	minor_fields === nothing || (fields[:minor] = attr(minor_fields))

	_cmn_merge_layout_key!(fig, key, fields; nested = (:minor,))
	drop_auto_format && _cmn_delete_layout_fields!(fig, key, (:tickformat,))
	if tickvals !== nothing && ticktext === nothing
		_cmn_delete_layout_fields!(fig, key, (:ticktext,))
	end
	if clear_minor_array
		_cmn_delete_layout_fields!(
			fig,
			key,
			(:tickmode, :tickvals);
			nested = :minor,
		)
	end
	return nothing
end

# ---------------------------------------------------------------------------
# F9: equal aspect
# ---------------------------------------------------------------------------

"""
	_apply_equal_aspect!(fig, t::_CellTarget; ratio=1, who)

Lock the data aspect of cell `t` (spec F9). For an `:xy` cell the y axis gets
`scaleanchor = t.xref`, `scaleratio = ratio` (one y unit spans `ratio` times
the pixels of one x unit, as matplotlib `set_aspect(ratio)`), and both axes
get `constrain = "domain"` so explicit ranges are honoured. A stale
`scaleanchor`/`scaleratio` on the x axis is removed: it would form a loop or
chain this cell to another cell's axis. A `:scene` cell gets
`aspectmode = "data"` (`ratio` must be 1). Other kinds are an `ArgumentError`.
"""
function _apply_equal_aspect!(
	fig,
	t::_CellTarget;
	ratio::Real = 1,
	who::AbstractString = "_apply_equal_aspect!",
)
	(isfinite(ratio) && ratio > 0) || throw(ArgumentError(
		"$(who): `ratio` must be finite and positive; got $(ratio).",
	))
	if t.kind === :xy
		_cmn_check_axis_key(t.xkey, who)
		_cmn_check_axis_key(t.ykey, who)
		_cmn_merge_layout_key!(
			fig,
			t.ykey,
			Dict{Symbol, Any}(
				:scaleanchor => t.xref,
				:scaleratio => Float64(ratio),
				:constrain => "domain",
			),
		)
		_cmn_merge_layout_key!(
			fig,
			t.xkey,
			Dict{Symbol, Any}(:constrain => "domain"),
		)
		_cmn_delete_layout_fields!(fig, t.xkey, (:scaleanchor, :scaleratio))
		return nothing
	elseif t.kind === :scene
		ratio == 1 || throw(ArgumentError(
			"$(who): a 3-D scene cell supports only `ratio = 1` (equal data " *
			"units on all three axes); got $(ratio).",
		))
		_merge_scene_layout_attr!(
			_cmn_layout(fig),
			t.scenekey,
			attr(aspectmode = "data"),
		)
		return nothing
	end
	throw(ArgumentError(
		"$(who): equal aspect applies to Cartesian (xy) and 3-D scene " *
		"cells; this cell is :$(t.kind).",
	))
end

# ---------------------------------------------------------------------------
# F11: twin y axis on a plain figure
# ---------------------------------------------------------------------------

# Spine and tick styling that a new overlaying axis (twin y, secondary x)
# copies from the axis it overlays, so both read alike under styles, dark
# templates and `spines!` colours.
const _CMN_COPIED_AXIS_LINE_FIELDS = (:linecolor, :linewidth, :tickcolor, :ticklen, :tickwidth)

# Add to `fields` (the new axis's attributes) copies of the primary axis's
# line styling (`_CMN_COPIED_AXIS_LINE_FIELDS`), `tickfont` and `title.font`
# where the primary sets them, so fonts set before the new axis exists
# (set_fonts!, styles) carry over. Mappings are copied, never aliased; a
# `:title` already in `fields` keeps its other entries.
function _cmn_copy_axis_style!(fields::AbstractDict{Symbol}, primary)
	for name in _CMN_COPIED_AXIS_LINE_FIELDS
		value = _cmn_mapping_get(primary, name)
		value === nothing || (fields[name] = value)
	end
	tickfont = _cmn_mapping_get(primary, :tickfont)
	_is_layout_mapping(tickfont) &&
		(fields[:tickfont] = attr(; _symbol_dict(tickfont)...))
	title_font = _cmn_mapping_get(_cmn_mapping_get(primary, :title), :font)
	if _is_layout_mapping(title_font)
		title = get(fields, :title, nothing)
		title_fields = title === nothing ? Dict{Symbol, Any}() : _symbol_dict(title)
		title_fields[:font] = attr(; _symbol_dict(title_font)...)
		fields[:title] = attr(; title_fields...)
	end
	return fields
end

"""
	_ensure_twin_y!(fig; who)::Symbol

Layout key of the y axis that overlays `"y"` on a plain `Plot`/`SyncPlot`
(or staged target), creating it when missing: the next free `yaxisN` with
`overlaying="y"`, `side="right"`, `anchor="x"`, no grid, and the package's
black outside-tick spine style without `mirror`; the primary y axis's
`title.font`, `tickfont`, `linecolor`, `linewidth`, `tickcolor`, `ticklen`
and `tickwidth`, when set, are copied. Idempotent. A SubplotFigure
cell gets its secondary y axis from `subplots(...; specs=...)` instead, so it
is an `ArgumentError` here, as is a figure without Cartesian axes.
"""
function _ensure_twin_y!(fig; who::AbstractString = "_ensure_twin_y!")
	fig isa SubplotFigure && throw(ArgumentError(
		"$(who): SubplotFigure cells get a secondary y-axis from " *
		"`subplots(...; specs=[Spec(secondary_y=true) ...])`; then pass " *
		"`secondary_y=true` with `row`/`col`.",
	))
	p = _plot_obj(fig)
	kind, _ = _cmn_plot_kind(p)
	kind === :xy || throw(ArgumentError(
		"$(who): a secondary y-axis needs Cartesian x/y axes; this figure is " *
		"a :$(kind) figure.",
	))
	existing = _cmn_twin_y_key(p.layout)
	existing === nothing || return existing

	# Next free index: above every y axis in the layout and every y reference
	# used by a trace (Plotly creates implicit axes for those).
	highest = 1
	for key in keys(p.layout.fields)
		index = _cmn_axis_index(key, 'y')
		index === nothing || (highest = max(highest, index))
	end
	for trace in p.data
		trace isa GenericTrace || continue
		ref = get(trace.fields, :yaxis, nothing)
		index = _cmn_axis_ref_index(ref isa Symbol ? String(ref) : ref, 'y')
		index === nothing || (highest = max(highest, index))
	end
	key = Symbol("yaxis", highest + 1)
	fields = Dict{Symbol, Any}(
		:overlaying => "y",
		:side => "right",
		:anchor => "x",
		:showgrid => false,
		:zeroline => false,
		:showline => true,
		:ticks => "outside",
		:automargin => true,
		:linecolor => _DEFAULT_AXIS_LINECOLOR,
		:linewidth => _DEFAULT_AXIS_LINEWIDTH,
		:tickcolor => _DEFAULT_AXIS_LINECOLOR,
	)
	# Fonts and spine styling set on the primary y axis before the twin exists
	# (set_fonts!, styles, dark templates) carry over, so both y axes read
	# alike. Copied, never aliased.
	_cmn_copy_axis_style!(fields, get(p.layout.fields, :yaxis, nothing))
	_cmn_merge_layout_key!(fig, key, fields; nested = (:title,))
	return key
end

# ---------------------------------------------------------------------------
# F17: markers
# ---------------------------------------------------------------------------

# matplotlib marker codes -> Plotly symbol names. "." also gets size 4 when no
# size is given (matplotlib's point marker is small); "x"/"+" map to the thin
# line symbols because matplotlib draws them as strokes, not filled glyphs.
const _CMN_MATPLOTLIB_MARKERS = Dict{String, String}(
	"o" => "circle",
	"." => "circle",
	"s" => "square",
	"^" => "triangle-up",
	"v" => "triangle-down",
	"<" => "triangle-left",
	">" => "triangle-right",
	"D" => "diamond",
	"d" => "diamond-tall",
	"x" => "x-thin",
	"+" => "cross-thin",
	"X" => "x",
	"P" => "cross",
	"*" => "star",
	"p" => "pentagon",
	"h" => "hexagon",
	"H" => "hexagon2",
	"8" => "octagon",
	"1" => "y-down",
	"2" => "y-up",
	"3" => "y-left",
	"4" => "y-right",
	"|" => "line-ns",
	"_" => "line-ew",
)

# Size (px) of matplotlib's "." point marker when no `marker_size` is given
# (spec F17).
const _CMN_POINT_MARKER_SIZE = 4

# Plotly symbols drawn only as strokes (`noFill` in plotly.js symbol_defs):
# they are invisible unless `marker.line.width > 0`.
const _CMN_LINE_MARKER_SYMBOLS = (
	"cross-thin",
	"x-thin",
	"asterisk",
	"hash",
	"y-up",
	"y-down",
	"y-left",
	"y-right",
	"line-ew",
	"line-ns",
	"line-ne",
	"line-nw",
)

# Default marker edge width (px) whenever an edge is implied by a face colour,
# a hollow marker or a line symbol (spec F17, verified on renders P1/e5_bw).
const _CMN_DEFAULT_MARKER_EDGE_WIDTH = 1.5

const _CMN_MARKER_SYMBOLS = Ref{Union{Nothing, Set{String}}}(nothing)

# Every symbol name Plotly accepts, from PlotlyBase's bundled plot schema
# (cached; building it twice concurrently is harmless).
function _cmn_marker_symbol_names()
	names = _CMN_MARKER_SYMBOLS[]
	names === nothing || return names
	schema_values = PlotlyBase.get_plotschema().traces[:scatter][:attributes][:marker][:symbol][:values]
	names = Set{String}(string(v) for v in schema_values)
	_CMN_MARKER_SYMBOLS[] = names
	return names
end

_cmn_color_string(c::AbstractString) = String(c)
_cmn_color_string(c::Symbol) = String(c)

function _cmn_check_color(value, name::AbstractString, who::AbstractString)
	(value isa AbstractString || value isa Symbol) || throw(ArgumentError(
		"$(who): `$(name)` must be a colour string or symbol; got $(repr(value)).",
	))
	return _cmn_color_string(value)
end

"""
	_plotly_marker_symbol(symbol; who)::String

Plotly symbol name for a matplotlib marker code (`"o"`, `"s"`, `"^"`, `"x"`,
...) or a Plotly symbol name; `""` stays `""`. Unknown names are an
`ArgumentError`.
"""
function _plotly_marker_symbol(symbol; who::AbstractString = "_plotly_marker_symbol")
	(symbol isa AbstractString || symbol isa Symbol) || throw(ArgumentError(
		"$(who): `marker_symbol` must be a string or symbol; got $(repr(symbol)).",
	))
	name = String(symbol)
	isempty(name) && return ""
	mapped = get(_CMN_MATPLOTLIB_MARKERS, name, name)
	mapped in _cmn_marker_symbol_names() || throw(ArgumentError(
		"$(who): unknown marker symbol $(repr(name)); use a Plotly symbol " *
		"name (\"circle\", \"square-open\", \"x-thin\", ...) or a matplotlib " *
		"code ($(join(sort!(collect(keys(_CMN_MATPLOTLIB_MARKERS))), " "))).",
	))
	return mapped
end

_cmn_is_open_symbol(symbol::AbstractString) = occursin("-open", symbol)

function _cmn_is_line_symbol(symbol::AbstractString)
	base = replace(symbol, r"-open$" => "", r"-open-dot$" => "", r"-dot$" => "")
	return base in _CMN_LINE_MARKER_SYMBOLS
end

function _cmn_open_variant(symbol::AbstractString)
	endswith(symbol, "-dot") &&
		return symbol[1:(end - 4)] * "-open-dot"
	return symbol * "-open"
end

"""
	_marker_attr(; color_series="", marker_color="", marker_line_color="", marker_line_width=0, marker_size=0, marker_symbol="", who)::PlotlyAttribute

Plotly `marker` attribute for one series (spec F17); only non-sentinel fields
are written, so an empty attr means "Plotly defaults". `color_series` is the
series colour (resolve it with `_default_trace_color` when the user gave
none): it is the default edge colour.

- `marker_symbol`: Plotly name or matplotlib code (`"o"`, `"s"`, `"^"`, `"x"`
  -> "x-thin", `"+"` -> "cross-thin", `"."` -> circle of size 4, ...).
- `marker_color`: face colour. `"none"` makes the marker hollow: the symbol
  becomes its `-open` variant (circle when unset) unless it is already open
  or a line symbol. Any other colour is the face; the edge is then
  `marker_line_color`, else `color_series`, with width 1.5 unless given.
- Open symbols stroke with `marker.color` in Plotly, so their edge colour
  (`marker_line_color`, else a non-"none" `marker_color`, else `color_series`)
  is written there.
- Line symbols ("x-thin", "cross-thin", "asterisk", "y-*", "line-*", ...) get
  `line.width` 1.5 and `line.color` = `marker_line_color`, else
  `marker_color`, else `color_series`; without them Plotly draws nothing.
- `marker_size`, `marker_line_width`: finite and `>= 0` (0 = unset).
"""
function _marker_attr(;
	color_series = "",
	marker_color = "",
	marker_line_color = "",
	marker_line_width::Real = 0,
	marker_size::Real = 0,
	marker_symbol = "",
	who::AbstractString = "_marker_attr",
)
	series = _cmn_check_color(color_series, "color_series", who)
	face = _cmn_check_color(marker_color, "marker_color", who)
	edge = _cmn_check_color(marker_line_color, "marker_line_color", who)
	for (name, value) in (
		("marker_line_width", marker_line_width),
		("marker_size", marker_size),
	)
		(isfinite(value) && value >= 0) || throw(ArgumentError(
			"$(who): `$(name)` must be finite and >= 0; got $(value).",
		))
	end
	requested_symbol = marker_symbol isa Symbol ? String(marker_symbol) : marker_symbol
	symbol = _plotly_marker_symbol(marker_symbol; who = who)

	hollow = face == "none"
	if hollow && !_cmn_is_line_symbol(symbol) && !_cmn_is_open_symbol(symbol)
		symbol = _cmn_open_variant(isempty(symbol) ? "circle" : symbol)
	end
	face_given = !isempty(face) && !hollow
	# Edge colour preference shared by every branch below.
	edge_color = !isempty(edge) ? edge : face_given ? face : series

	marker = Dict{Symbol, Any}()
	line = Dict{Symbol, Any}()
	isempty(symbol) || (marker[:symbol] = symbol)
	if marker_size > 0
		marker[:size] = marker_size
	elseif requested_symbol == "."
		marker[:size] = _CMN_POINT_MARKER_SIZE
	end

	if !isempty(symbol) && _cmn_is_line_symbol(symbol)
		face_given && (marker[:color] = face)
		isempty(edge_color) || (line[:color] = edge_color)
		line[:width] = marker_line_width > 0 ?
			marker_line_width : _CMN_DEFAULT_MARKER_EDGE_WIDTH
	elseif !isempty(symbol) && _cmn_is_open_symbol(symbol)
		isempty(edge_color) || (marker[:color] = edge_color)
		if marker_line_width > 0
			line[:width] = marker_line_width
		elseif hollow || !isempty(edge) || face_given
			line[:width] = _CMN_DEFAULT_MARKER_EDGE_WIDTH
		end
	else
		if face_given
			marker[:color] = face
			edge_face = isempty(edge) ? series : edge
			isempty(edge_face) || (line[:color] = edge_face)
			line[:width] = marker_line_width > 0 ?
				marker_line_width : _CMN_DEFAULT_MARKER_EDGE_WIDTH
		else
			isempty(edge) || (line[:color] = edge)
			if marker_line_width > 0
				line[:width] = marker_line_width
			elseif !isempty(edge)
				line[:width] = _CMN_DEFAULT_MARKER_EDGE_WIDTH
			end
		end
	end
	isempty(line) || (marker[:line] = attr(line))
	return attr(marker)
end

"""
	_markevery_fields(markevery, n::Int; who)::Dict{Symbol,Any}

Trace fields that show markers only at the selected points of an `n`-point
series (spec F17): `selectedpoints` (0-based) and
`unselected = attr(marker = attr(opacity = 0))`, which keeps a full-size legend
icon. `markevery` is `nothing` (empty Dict: every point), an `Integer` `k >= 1`
(points `1:k:n`), a range or vector of 1-based indices, or a `Bool` mask of
length `n`. Indices outside `1:n` are an `ArgumentError`. The caller adds
"markers" to the trace `mode`.
"""
function _markevery_fields(markevery, n::Integer; who::AbstractString = "_markevery_fields")
	n >= 0 || throw(ArgumentError("$(who): series length must be >= 0; got $(n)."))
	markevery === nothing && return Dict{Symbol, Any}()
	indices = if markevery isa Bool
		throw(ArgumentError(
			"$(who): `markevery` must be an integer step, indices or a Bool " *
			"mask; got $(markevery).",
		))
	elseif markevery isa Integer
		markevery >= 1 || throw(ArgumentError(
			"$(who): an integer `markevery` is a step and must be >= 1; got $(markevery).",
		))
		collect(1:Int(markevery):n)
	elseif markevery isa AbstractVector && eltype(markevery) === Bool
		length(markevery) == n || throw(ArgumentError(
			"$(who): a Bool `markevery` mask needs $(n) entries; got " *
			"$(length(markevery)).",
		))
		findall(markevery)
	elseif markevery isa AbstractVector
		out = Int[]
		for index in markevery
			(index isa Integer && !(index isa Bool)) || throw(ArgumentError(
				"$(who): `markevery` indices must be integers; got $(repr(index)).",
			))
			1 <= index <= n || throw(ArgumentError(
				"$(who): `markevery` index $(index) is outside 1:$(n).",
			))
			push!(out, Int(index))
		end
		sort!(unique!(out))
	else
		throw(ArgumentError(
			"$(who): `markevery` must be nothing, an integer step, a range or " *
			"vector of 1-based indices, or a Bool mask; got $(typeof(markevery)).",
		))
	end
	return Dict{Symbol, Any}(
		:selectedpoints => indices .- 1,
		:unselected => attr(Dict{Symbol, Any}(
			:marker => attr(Dict{Symbol, Any}(:opacity => 0)),
		)),
	)
end

# ---------------------------------------------------------------------------
# F15: legend proxy traces
# ---------------------------------------------------------------------------

# Size (px) of the filled square drawn by `patch=true` (spec F15), roughly a
# matplotlib Rectangle legend handle at Plotly's default legend font size.
const _CMN_PATCH_MARKER_SIZE = 12

"""
	_proxy_trace(label; mode="lines", color="", dash="", linewidth=0, marker_symbol="", marker_size=0, marker_color="", marker_line_color="", marker_line_width=0, patch=false, legendgroup="", opacity=1, who)::GenericTrace

Legend-only scatter trace (spec F15): `x = y = [nothing]`, `name =
_label(label)`, `showlegend = true`, `hoverinfo = "skip"`; it draws nothing in
the plot area. `mode` is "lines", "markers" or "lines+markers". Line style
comes from `color`/`dash`/`linewidth`; markers from [`_marker_attr`](@ref)
with `color` as the series colour (and as the face colour when
`marker_color` is unset). `patch=true` draws a filled square (size 12, no
edge unless `marker_line_width > 0`), standing in for a matplotlib Rectangle
handle. `label = " "` gives a blank spacer entry.
"""
function _proxy_trace(
	label::AbstractString;
	mode::AbstractString = "lines",
	color = "",
	dash::AbstractString = "",
	linewidth::Real = 0,
	marker_symbol = "",
	marker_size::Real = 0,
	marker_color = "",
	marker_line_color = "",
	marker_line_width::Real = 0,
	patch::Bool = false,
	legendgroup::AbstractString = "",
	opacity::Real = 1,
	who::AbstractString = "_proxy_trace",
)
	series = _cmn_check_color(color, "color", who)
	face = _cmn_check_color(marker_color, "marker_color", who)
	edge = _cmn_check_color(marker_line_color, "marker_line_color", who)
	parts = split(mode, '+')
	(!isempty(mode) && all(part -> part in ("lines", "markers"), parts)) ||
		throw(ArgumentError(
			"$(who): `mode` must be \"lines\", \"markers\" or " *
			"\"lines+markers\"; got $(repr(mode)).",
		))
	(isfinite(linewidth) && linewidth >= 0) || throw(ArgumentError(
		"$(who): `linewidth` must be finite and >= 0; got $(linewidth).",
	))
	(isfinite(opacity) && 0 <= opacity <= 1) || throw(ArgumentError(
		"$(who): `opacity` must lie in [0, 1]; got $(opacity).",
	))

	fields = Dict{Symbol, Any}(
		:x => Any[_GAP],
		:y => Any[_GAP],
		:name => _label(label),
		:showlegend => true,
		:hoverinfo => "skip",
	)
	if patch
		for (name, value) in (
			("marker_size", marker_size),
			("marker_line_width", marker_line_width),
		)
			(isfinite(value) && value >= 0) || throw(ArgumentError(
				"$(who): `$(name)` must be finite and >= 0; got $(value).",
			))
		end
		fill = isempty(face) ? series : face
		marker = Dict{Symbol, Any}(
			:symbol => "square",
			:size => marker_size > 0 ? marker_size : _CMN_PATCH_MARKER_SIZE,
		)
		isempty(fill) || (marker[:color] = fill)
		line = Dict{Symbol, Any}(:width => marker_line_width)
		if marker_line_width > 0
			edge_color = isempty(edge) ? series : edge
			isempty(edge_color) || (line[:color] = edge_color)
		end
		marker[:line] = attr(line)
		fields[:mode] = "markers"
		fields[:marker] = attr(marker)
	else
		fields[:mode] = String(mode)
		if "lines" in parts
			line = Dict{Symbol, Any}()
			isempty(series) || (line[:color] = series)
			isempty(dash) || (line[:dash] = String(dash))
			linewidth > 0 && (line[:width] = linewidth)
			isempty(line) || (fields[:line] = attr(line))
		end
		if "markers" in parts
			marker = _marker_attr(;
				color_series = series,
				marker_color = face,
				marker_line_color = edge,
				marker_line_width = marker_line_width,
				marker_size = marker_size,
				marker_symbol = marker_symbol,
				who = who,
			)
			# A legend-only trace has no line colour for markers to inherit
			# in "markers" mode, so the series colour becomes the face.
			if !haskey(marker.fields, :color) && !isempty(series)
				marker.fields[:color] = series
			end
			isempty(marker.fields) || (fields[:marker] = marker)
		end
	end
	isempty(legendgroup) || (fields[:legendgroup] = String(legendgroup))
	opacity == 1 || (fields[:opacity] = opacity)
	return GenericTrace("scatter", fields)
end

# ---------------------------------------------------------------------------
# F21: hatch patterns
# ---------------------------------------------------------------------------

# matplotlib draws `6 * n` hatch lines per inch for a pattern character
# repeated n times (hatch.py, density=6); CSS has 96 px per inch, and the
# hatch line width is 1 pt = 96/72 px (rcParams["hatch.linewidth"] = 1.0).
const _CMN_HATCH_LINES_PER_INCH = 6
const _CMN_PX_PER_INCH = 96
const _CMN_HATCH_LINEWIDTH_PX = 96 / 72

"""
	_hatch_pattern(hatch::AbstractString; color="", who)::Union{Nothing,PlotlyAttribute}

Plotly fill `pattern` for a matplotlib hatch string (spec F21), or `nothing`
for `""`. One character, possibly repeated for density (`"///"`), maps to
Plotly's shape: `/`, `\\`, `x`, `-`, `|`, `+`, `.`; the pairs `/\\` and `-|`
combine to `x` and `+`. Spacing and line width follow matplotlib (6 lines per
inch per repetition, 1 pt lines). `fillmode = "overlay"` keeps the base fill
colour underneath; `color` sets the hatch colour (`fgcolor`), otherwise Plotly
picks a contrasting one. Unsupported characters (`o`, `O`, `*`) or mixtures
are an `ArgumentError`. Use as `marker.pattern` (bar, histogram) or
`fillpattern` (scatter fills).
"""
function _hatch_pattern(
	hatch::AbstractString;
	color = "",
	who::AbstractString = "_hatch_pattern",
)
	fgcolor = _cmn_check_color(color, "color", who)
	isempty(hatch) && return nothing
	chars = collect(hatch)
	distinct = Set(chars)
	shape = if length(distinct) == 1
		only(distinct)
	elseif distinct == Set(['/', '\\'])
		'x'
	elseif distinct == Set(['-', '|'])
		'+'
	else
		nothing
	end
	(shape !== nothing && shape in ('/', '\\', 'x', '-', '|', '+', '.')) ||
		throw(ArgumentError(
			"$(who): unsupported hatch $(repr(hatch)); Plotly supports one of " *
			"'/', '\\\\', 'x', '-', '|', '+', '.' (repeat it for density, " *
			"e.g. \"///\").",
		))
	# Pattern repetitions: "//" is 2; a combined "/\\" counts once per pair.
	repeats = length(distinct) == 1 ? length(chars) :
		maximum(ch -> count(==(ch), chars), distinct)
	spacing = _CMN_PX_PER_INCH / (_CMN_HATCH_LINES_PER_INCH * repeats)
	diagonal = shape in ('/', '\\', 'x')
	# Plotly's `size` is the perpendicular line spacing; matplotlib spaces
	# diagonal lines by `spacing` along the cell edge, i.e. spacing/sqrt(2)
	# apart.
	size = diagonal ? spacing / sqrt(2) : spacing
	pattern = Dict{Symbol, Any}(
		:shape => string(shape),
		:fillmode => "overlay",
		:size => size,
	)
	# plotly.js stroke width: `solidity * size` for single-direction lines and
	# `size * (1 - sqrt(1 - solidity))` for crossed ones; solve for 1 pt.
	# Dots keep Plotly's default area fraction.
	if shape in ('/', '\\', '-', '|')
		pattern[:solidity] = clamp(_CMN_HATCH_LINEWIDTH_PX / size, 0.0, 1.0)
	elseif shape in ('x', '+')
		pattern[:solidity] =
			clamp(1 - (1 - min(_CMN_HATCH_LINEWIDTH_PX / size, 1.0))^2, 0.0, 1.0)
	end
	isempty(fgcolor) || (pattern[:fgcolor] = fgcolor)
	return attr(pattern)
end
