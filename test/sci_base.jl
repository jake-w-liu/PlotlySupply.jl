using Test, PlotlySupply

# D7 figure-option primitives (src/sci/base.jl): range validation, DATA-unit
# ranges on log axes, the scale-switch range conversion, the call-order
# contract, and that each primitive writes only the axis it addresses.

const _BS = PlotlySupply
const _BS_PB = PlotlySupply.PlotlyBase

function _bs_error(f)
	try
		f()
	catch err
		return err
	end
	return nothing
end

function _bs_throws(f, needle::AbstractString)
	err = _bs_error(f)
	err isa ArgumentError || return false
	return occursin(needle, err.msg)
end

_bs_fields(fig) = _BS._cmn_plot(fig).layout.fields
_bs_get(fig, key, name) = _BS._cmn_mapping_get(get(_bs_fields(fig), key, nothing), name)
_bs_json(x) = _BS_PB.JSON.json(x)
_bs_layout_json(fig) = _bs_json(_BS._cmn_plot(fig).layout)
_bs_axis_json(fig, key) = _bs_json(get(_bs_fields(fig), key, nothing))

# Primary axes plus a second log subplot (xaxis2/yaxis2) and a twin y axis
# (yaxis3), each with an explicit range, to check that the primitives only
# write the axis they address.
function _bs_multi_axis_plot()
	return Plot(
		[
			scatter(x = [1.0, 2.0], y = [1.0, 2.0]),
			scatter(x = [1.0, 10.0], y = [1.0, 100.0], xaxis = "x2", yaxis = "y2"),
			scatter(x = [1.0, 2.0], y = [5.0, 6.0], yaxis = "y3"),
		],
		Layout(
			xaxis = attr(domain = [0.0, 0.45]),
			xaxis2 = attr(domain = [0.55, 1.0], anchor = "y2", type = "log", range = [0, 1]),
			yaxis2 = attr(anchor = "x2", type = "log", range = [0, 2], title = attr(text = "y2")),
			yaxis3 = attr(overlaying = "y", side = "right", range = [0, 5], showgrid = false),
		),
	)
end

@testset "sci base.jl" begin
	@testset "_checked_range: every rejected shape is an ArgumentError" begin
		# Automatic sentinels.
		@test _BS._checked_range(nothing, "f", "xrange") === nothing
		@test _BS._checked_range([0, 0], "f", "xrange") === nothing
		@test _BS._checked_range((0.0, 0), "f", "xrange") === nothing
		@test _BS._checked_range([nothing, nothing], "f", "xrange") === nothing
		# Valid ranges come back as a 2-element vector; reversed ranges are kept
		# (they flip the axis), date strings are not converted.
		@test _BS._checked_range((1, 2), "f", "xrange") == Any[1, 2]
		@test _BS._checked_range([5.0, -5.0], "f", "xrange") == Any[5.0, -5.0]
		@test _BS._checked_range(("2020-01-01", "2021-01-01"), "f", "xrange") ==
			Any["2020-01-01", "2021-01-01"]
		for (bad, needle) in (
			(5, "f: `xrange` must be a 2-element vector or tuple; got Int64"),
			("ab", "f: `xrange` must be a 2-element vector or tuple"),
			([1, 2, 3], "f: `xrange` must have exactly 2 elements (lower, upper); got 3"),
			([1], "f: `xrange` must have exactly 2 elements (lower, upper); got 1"),
			(Int[], "got 0"),
			([nothing, 1], "f: `xrange`: partial ranges are not supported"),
			((1, nothing), "partial ranges are not supported"),
			([missing, 1], "partial ranges are not supported"),
			([true, false], "f: `xrange` range bounds must be numbers (or date/category values), not Bool"),
			((0, true), "not Bool"),  # a tuple: [0, true] promotes to [0, 1]
			((1, Inf), "f: `xrange` bounds must be finite"),
			([NaN, 1.0], "bounds must be finite"),
			([-Inf, 0.0], "bounds must be finite"),
			([1, 1], "f: `xrange`: the range bounds must differ"),
			((2.5, 2.5), "the range bounds must differ"),
			(("a", "a"), "the range bounds must differ"),
		)
			@test _bs_throws(() -> _BS._checked_range(bad, "f", "xrange"), needle)
		end
	end

	@testset "D11: _checked_range(partial = true) and _axis_limit_bound" begin
		# Colour ranges (default) stay strict; axis ranges accept one open end.
		@test _BS._checked_range((1, nothing), "f", "xrange"; partial = true) == Any[1, nothing]
		@test _BS._checked_range([nothing, -2.5], "f", "xrange"; partial = true) == Any[nothing, -2.5]
		@test _BS._checked_range((nothing, nothing), "f", "xrange"; partial = true) === nothing
		@test _BS._is_one_sided_range(Any[1, nothing])
		@test !_BS._is_one_sided_range(Any[1, 2])
		@test !_BS._is_one_sided_range(nothing)
		for (bad, needle) in (
			((missing, 1), "f: `xrange`: an open bound of a one-sided limit is written `nothing`"),
			((nothing, missing), "an open bound of a one-sided limit"),
			((nothing, Inf), "f: `xrange` bounds must be finite"),
			((true, nothing), "not Bool"),
			((1, nothing, 2), "exactly 2 elements"),
		)
			@test _bs_throws(() -> _BS._checked_range(bad, "f", "xrange"; partial = true), needle)
		end
		# Bounds in the units plotly.js reads in autorangeoptions.
		@test _BS._axis_limit_bound("log", 100, "f", "x") == 2.0
		@test _BS._axis_limit_bound("linear", -3, "f", "x") == -3
		@test _BS._axis_limit_bound("category", 1.5, "f", "x") == 1.5
		@test _BS._axis_limit_bound("date", "2020-01-01", "f", "x") == 1.5778368e12
		@test _BS._axis_limit_bound("date", "2020-01-01 12:30:15.5", "f", "x") ==
			1.5778368e12 + (12 * 3600 + 30 * 60 + 15.5) * 1000
		@test _BS._axis_limit_bound("-", "2020-01", "f", "x") == 1.5778368e12
		@test _BS._axis_limit_bound("-", 7, "f", "x") == 7
		@test _BS._axis_limit_bound("date", _BS.Dates.Date(2020, 1, 1), "f", "x") == 1.5778368e12
		@test _BS._axis_limit_bound("date", _BS.Dates.DateTime(2020, 1, 1, 0, 0, 1), "f", "x") == 1.5778368e12 + 1000
		@test _BS._axis_limit_bound("date", 1.0e12, "f", "x") == 1.0e12
		for (type_name, bound, needle) in (
			("log", 0, "f: `x` bounds on a logarithmic axis are data values and must be positive"),
			("log", -1.0, "must be positive"),
			("date", "01/02/2020", "f: `x`: \"01/02/2020\" is not a date"),
			("date", "2020-13-01", "is not a valid calendar date"),
			("date", "2021-02-29", "is not a valid calendar date"),
			("date", :x, "is not a date"),
			("linear", "a", "f: `x` bounds on a linear axis must be numbers"),
		)
			@test _bs_throws(() -> _BS._axis_limit_bound(type_name, bound, "f", "x"), needle)
		end
	end

	@testset "D11: one-sided limits through the key-based primitives" begin
		p = plot_scatter([1.0, 2.0, 3.0], [1.0, 4.0, 2.0])
		_BS._apply_axis_range!(p, :y, (0, nothing), "t")
		@test _bs_get(p, :yaxis, :autorange) === true
		@test _bs_get(p, :yaxis, :range) === nothing
		@test _BS._cmn_mapping_get(_bs_get(p, :yaxis, :autorangeoptions), :minallowed) == 0
		@test _BS._cmn_mapping_get(_bs_get(p, :yaxis, :autorangeoptions), :maxallowed) === nothing
		# The other end replaces the limit; a full range removes it.
		_BS._apply_axis_range!(p, :y, (nothing, 10), "t")
		opts = _bs_get(p, :yaxis, :autorangeoptions)
		@test _BS._cmn_mapping_get(opts, :minallowed) === nothing
		@test _BS._cmn_mapping_get(opts, :maxallowed) == 10
		_BS._apply_axis_range!(p, :y, (-1, 5), "t")
		@test _bs_get(p, :yaxis, :range) == [-1, 5]
		@test _bs_get(p, :yaxis, :autorange) === false
		@test _bs_get(p, :yaxis, :autorangeoptions) === nothing
		# Reversed axis: the first bound is still the start (its largest value).
		_BS._apply_axis_range!(p, :y, (5, -1), "t")
		_BS._apply_axis_range!(p, :y, (6, nothing), "t")
		@test _bs_get(p, :yaxis, :autorange) == "reversed"
		@test _BS._cmn_mapping_get(_bs_get(p, :yaxis, :autorangeoptions), :maxallowed) == 6
		# Log axis: data units in, log10 stored.
		lg = plot_scatter([1.0, 10.0], [1.0, 2.0]; xscale = "log")
		_BS._apply_axis_range!(lg, :x, (0.1, nothing), "t")
		@test _BS._cmn_mapping_get(_bs_get(lg, :xaxis, :autorangeoptions), :minallowed) ≈ -1.0
		# The limit keeps its data value across a log <-> linear switch.
		_BS._apply_axis_scale!(lg, :x, "linear", "t")
		@test _BS._cmn_mapping_get(_bs_get(lg, :xaxis, :autorangeoptions), :minallowed) ≈ 0.1
		_BS._apply_axis_scale!(lg, :x, "log", "t")
		@test _BS._cmn_mapping_get(_bs_get(lg, :xaxis, :autorangeoptions), :minallowed) ≈ -1.0
		# A limit that cannot be shown on the new type is rejected before any
		# write, unless the call sets a new range.
		neg = plot_scatter([1.0, 10.0], [1.0, 2.0])
		_BS._apply_axis_range!(neg, :x, (-5, nothing), "t")
		before = _bs_layout_json(neg)
		@test _bs_throws(
			() -> _BS._validate_cartesian_options(neg, "t"; xscale = "log"),
			"t: the current one-sided x limit (minimum = -5, maximum = nothing) cannot be shown on a \"log\" axis",
		)
		@test _BS._validate_cartesian_options(neg, "t"; xscale = "log", xrange = (1, nothing)) === nothing
		@test _bs_layout_json(neg) == before
		# Date axis: milliseconds (plotly.js ignores date strings there).
		d = plot_scatter(["2020-01-05", "2020-02-01"], [1.0, 2.0])
		relayout!(d; xaxis_type = "date")
		_BS._apply_axis_range!(d, :x, ("2020-01-01", nothing), "t")
		@test _BS._cmn_mapping_get(_bs_get(d, :xaxis, :autorangeoptions), :minallowed) == 1.5778368e12
		@test _bs_throws(
			() -> _BS._validate_cartesian_options(d, "t"; xrange = ("1/2/2020", nothing)),
			"t: `xrange`: \"1/2/2020\" is not a date",
		)
		# Sticky field clips are replaced by the limit (a clip on the open end
		# would freeze it at the data extent).
		hm = plot_heatmap(collect(0.0:9), collect(0.0:4), rand(10, 5))
		_BS._apply_axis_range!(hm, :x, (-3, nothing), "t")
		opts = _bs_get(hm, :xaxis, :autorangeoptions)
		@test _BS._cmn_mapping_get(opts, :minallowed) == -3
		for name in (:clipmin, :clipmax, :include)
			@test _BS._cmn_mapping_get(opts, name) === nothing
		end
		# A fixed end beyond every data value would show no data.
		q = plot_scatter([1.0, 2.0], [1.0, 4.0])
		before = _bs_layout_json(q)
		@test _bs_throws(() -> _BS._apply_axis_range!(q, :y, (20, nothing), "t"), "t: `yrange` fixes one end of the axis beyond all of its data")
		@test _bs_throws(() -> _BS._apply_axis_range!(q, :y, (nothing, 0.5), "t"), "beyond all of its data")
		@test _bs_layout_json(q) == before
		_BS._apply_axis_range!(q, :y, (4, nothing), "t")  # touching the data is fine
		@test _BS._cmn_mapping_get(_bs_get(q, :yaxis, :autorangeoptions), :minallowed) == 4
		# Aspect-linked axes: the open end comes from the data (5 % margin).
		e = plot_scatter([0.0, 2.0], [0.0, 1.0])
		_BS._apply_cartesian_plot_options!(e; xrange = (-2, nothing), equalar = true, apply_template = false, who = "t")
		@test _bs_get(e, :xaxis, :autorange) === false
		@test _bs_get(e, :xaxis, :range) ≈ [-2.0, 2.1]
		@test _bs_get(e, :xaxis, :autorangeoptions) === nothing
		empty_eq = Plot()
		_BS._apply_equal_aspect!(empty_eq, _BS._cell_target(empty_eq; who = "t"); who = "t")
		@test _bs_throws(
			() -> _BS._apply_axis_range!(empty_eq, :x, (0, nothing), "t"),
			"t: `xrange` = (0, nothing) is a one-sided limit on an axis with a locked aspect ratio",
		)
	end

	@testset "_apply_axis_range!: DATA units on log axes, checked before any write" begin
		p = plot_scatter([1.0, 10.0, 100.0], [1.0, 2.0, 3.0]; xscale = "log")
		@test _BS._apply_axis_range!(p, :x, (1, 1000), "t") === nothing
		@test _bs_get(p, :xaxis, :range) == [0.0, 3.0]
		@test _bs_get(p, :xaxis, :autorange) === false
		# Reversed: the axis is flipped, still in data units.
		_BS._apply_axis_range!(p, :x, (1000, 10), "t")
		@test _bs_get(p, :xaxis, :range) == [3.0, 1.0]
		# The automatic sentinel leaves the axis untouched.
		before = _bs_layout_json(p)
		_BS._apply_axis_range!(p, :x, [0, 0], "t")
		_BS._apply_axis_range!(p, :x, nothing, "t")
		@test _bs_layout_json(p) == before
		for (bad, needle) in (
			((-1, 10), "must be positive"),
			((0, 10), "must be positive"),
			((1, 1), "t: `xrange`: the range bounds must differ"),
			([true, false], "not Bool"),
			((1, Inf), "bounds must be finite"),
			([1, 2, 3], "exactly 2 elements"),
			(("1", "10"), "t: `xrange` bounds on a log axis must be numbers"),
		)
			@test _bs_throws(() -> _BS._apply_axis_range!(p, :x, bad, "t"), needle)
			@test _bs_layout_json(p) == before
		end

		lin = plot_scatter([1.0, 2.0], [1.0, 2.0]; yscale = "linear")
		_BS._apply_axis_range!(lin, :y, (5, -5), "t")
		@test _bs_get(lin, :yaxis, :range) == [5, -5]
		@test _bs_throws(
			() -> _BS._apply_axis_range!(lin, :y, ("a", "b"), "t"),
			"t: `yrange` bounds on a linear axis must be numbers",
		)
		@test _bs_get(lin, :yaxis, :range) == [5, -5]
	end

	@testset "date and category ranges are never converted" begin
		d = plot_scatter([1.0, 2.0], [1.0, 2.0])
		relayout!(d; xaxis_type = "date")
		_BS._apply_axis_range!(d, :x, ("2020-01-01", "2021-06-30"), "t")
		@test _bs_get(d, :xaxis, :range) == ["2020-01-01", "2021-06-30"]
		_BS._apply_axis_range!(d, :x, (1.5e12, 1.6e12), "t")
		@test _bs_get(d, :xaxis, :range) == [1.5e12, 1.6e12]
		# An autotyped axis may become a date axis: strings pass unchanged.
		a = plot_scatter([1.0, 2.0], [1.0, 2.0])
		_BS._apply_axis_range!(a, :x, ("2020-01-01", "2020-02-01"), "t")
		@test _bs_get(a, :xaxis, :range) == ["2020-01-01", "2020-02-01"]

		c = plot_bar(["a", "b", "c"], [1.0, 2.0, 3.0])
		relayout!(c; xaxis_type = "category")
		_BS._apply_axis_range!(c, :x, (-0.5, 2.5), "t")
		@test _bs_get(c, :xaxis, :range) == [-0.5, 2.5]
		@test _bs_throws(
			() -> _BS._apply_axis_range!(c, :x, ("a", "c"), "t"),
			"bounds on a category axis must be numbers (0-based category positions)",
		)
		# A switch to/from date or category never converts numbers.
		_BS._apply_axis_scale!(c, :x, "linear", "t")
		@test _bs_get(c, :xaxis, :range) == [-0.5, 2.5]
	end

	@testset "_validate_cartesian_options / _require_axis_range" begin
		p = plot_scatter([1.0, 2.0], [1.0, 2.0])
		v(; kw...) = _BS._validate_cartesian_options(p, "t"; kw...)
		@test v(xrange = (1, 2), yrange = [0, 0], xscale = "log") === nothing
		@test v(xrange = (2, 1)) === nothing  # reversed is valid
		for (kw, needle) in (
			((xrange = [1, 1],), "t: `xrange`: the range bounds must differ"),
			((yrange = (3, 3.0),), "t: `yrange`: the range bounds must differ"),
			((xrange = [1, 2, 3],), "t: `xrange` must have exactly 2 elements"),
			((yrange = [true, false],), "t: `yrange` range bounds must be numbers"),
			((xrange = (1, NaN),), "t: `xrange` bounds must be finite"),
			((yrange = [missing, 1],), "t: `yrange`: an open bound of a one-sided limit is written `nothing`"),
			((xrange = (0, nothing), xscale = "log"), "t: `xrange` bounds on a logarithmic axis are data values and must be positive"),
			((xrange = (0, 10), xscale = "log"), "t: `xrange` bounds on a logarithmic axis are data values and must be positive"),
			((yrange = (-1, 10), yscale = "log"), "t: `yrange` bounds on a logarithmic axis"),
			((xrange = ("a", "b"), xscale = "linear"), "t: `xrange` bounds on a linear axis must be numbers"),
			((xscale = "logarithmic",), "t: `xscale` must be one of"),
		)
			@test _bs_throws(() -> v(; kw...), needle)
		end
		# The final axis type counts: an existing log axis rejects non-positive
		# bounds without a scale keyword.
		lg = plot_scatter([1.0, 10.0], [1.0, 2.0]; xscale = "log")
		@test _bs_throws(
			() -> _BS._validate_cartesian_options(lg, "t"; xrange = (-1, 10)),
			"bounds on a logarithmic axis are data values and must be positive",
		)
		# Public constructors reject before creating anything.
		@test _bs_throws(() -> plot_scatter([1.0, 2.0], [1.0, 2.0]; xrange = [1, 1]), "plot_scatter: `xrange`: the range bounds must differ")
		@test _bs_throws(() -> plot_scatter([1.0, 2.0], [1.0, 2.0]; yrange = [true, false]), "not Bool")
		@test _bs_throws(() -> plot_scatter([1.0, 2.0], [1.0, 2.0]; xscale = "linear", xrange = ("a", "b")), "bounds on a linear axis must be numbers")
		auto = plot_scatter([1.0, 2.0], [1.0, 2.0]; xrange = [nothing, nothing])
		@test _bs_get(auto, :xaxis, :range) === nothing
	end

	@testset "scale switch converts the stored DATA range (log <-> linear)" begin
		h = plot_scatter([1.0, 10.0, 1000.0], [1.0, 2.0, 3.0]; xscale = "log", xrange = (1, 1000))
		@test _bs_get(h, :xaxis, :range) == [0.0, 3.0]
		plot_scatter!(h, [2.0], [1.0]; xscale = "linear")
		@test _bs_get(h, :xaxis, :type) == "linear"
		@test _bs_get(h, :xaxis, :range) ≈ [1.0, 1000.0]
		plot_scatter!(h, [3.0], [1.0]; xscale = "log")
		@test _bs_get(h, :xaxis, :type) == "log"
		@test _bs_get(h, :xaxis, :range) ≈ [0.0, 3.0]
		# Reversed ranges keep their direction.
		r = plot_scatter([1.0, 100.0], [1.0, 2.0]; xscale = "log", xrange = (100, 1))
		_BS._apply_axis_scale!(r, :x, "linear", "t")
		@test _bs_get(r, :xaxis, :range) ≈ [100.0, 1.0]
		# Non-positive bounds cannot be shown on a log axis: rejected before any
		# write, unless the same call sets a new range.
		k = plot_scatter([1.0, 10.0], [1.0, 2.0]; xrange = (-5, 10))
		before = _bs_layout_json(k)
		ntraces = length(k.data)
		@test _bs_throws(
			() -> plot_scatter!(k, [2.0], [1.0]; xscale = "log"),
			"plot_scatter!: the current x range (-5, 10) cannot be shown on a \"log\" axis",
		)
		@test _bs_layout_json(k) == before
		@test length(k.data) == ntraces
		plot_scatter!(k, [2.0], [1.0]; xscale = "log", xrange = (1, 100))
		@test _bs_get(k, :xaxis, :range) ≈ [0.0, 2.0]
		# The primitive itself drops a range with no meaning on the new type.
		dlog = plot_scatter([1.0, 10.0], [1.0, 2.0]; xscale = "log", xrange = (1, 10))
		_BS._apply_axis_scale!(dlog, :x, "date", "t")
		@test _bs_get(dlog, :xaxis, :range) === nothing
		@test _bs_get(dlog, :xaxis, :autorange) === true
		# The y axis error names the y keyword and the y helper.
		ky = plot_scatter([1.0, 2.0], [1.0, 10.0]; yrange = (0, 10))
		@test _bs_throws(
			() -> plot_scatter!(ky, [2.0], [1.0]; yscale = "log"),
			"clear the range first with `yrange!(fig, nothing)`",
		)
		# An autoranged axis has nothing to convert.
		free = plot_scatter([1.0, 10.0], [1.0, 2.0])
		plot_scatter!(free, [2.0], [1.0]; xscale = "log")
		@test _bs_get(free, :xaxis, :range) === nothing
		@test _bs_get(free, :xaxis, :exponentformat) == "power"
	end

	@testset "call order: ranges before or after the traces" begin
		# Range and scale first, traces afterwards: the range is unchanged.
		p = Plot()
		_BS._apply_axis_scale!(p, :x, "log", "t")
		_BS._apply_axis_range!(p, :x, (1, 100), "t")
		@test _bs_get(p, :xaxis, :range) == [0.0, 2.0]
		plot_scatter!(p, [3.0, 30.0], [1.0, 2.0])
		@test _bs_get(p, :xaxis, :range) == [0.0, 2.0]
		@test _bs_get(p, :xaxis, :type) == "log"
		# Data-unit ranges added together with new data on an existing log axis.
		f = plot_scatter([1.0, 10.0], [1.0, 2.0]; xscale = "log")
		plot_scatter!(f, [100.0], [3.0]; xrange = (1, 1e4))
		@test _bs_get(f, :xaxis, :range) ≈ [0.0, 4.0]
		plot_bar!(f, [5.0], [1.0]; xrange = (10, 1000))
		@test _bs_get(f, :xaxis, :range) ≈ [1.0, 3.0]
		hm = plot_heatmap([1.0, 10.0, 100.0], [1.0, 2.0], [1.0 2.0; 3.0 4.0; 5.0 6.0]; xscale = "log")
		plot_heatmap!(hm, [1.0, 10.0, 100.0], [3.0, 4.0], [1.0 2.0; 3.0 4.0; 5.0 6.0]; xrange = (1, 1e4))
		@test _bs_get(hm, :xaxis, :range) ≈ [0.0, 4.0]
		@test _bs_throws(
			() -> plot_bar!(f, [5.0], [1.0]; xrange = (-1, 10)),
			"bounds on a logarithmic axis are data values and must be positive",
		)
		@test _bs_get(f, :xaxis, :range) ≈ [1.0, 3.0]
	end

	@testset "twin y axis: the key-based primitives in _apply_cartesian_plot_options!" begin
		p = plot_scatter([1.0, 2.0], [1.0, 2.0])
		plot_scatter!(p, [1.0, 2.0], [10.0, 1000.0]; secondary_y = true, yscale = "log", yrange = (1, 1e4), ylabel = L"$P$ (W)")
		@test _bs_get(p, :yaxis2, :type) == "log"
		@test _bs_get(p, :yaxis2, :range) ≈ [0.0, 4.0]
		@test _bs_get(p, :yaxis2, :exponentformat) == "power"
		@test _BS._cmn_mapping_get(_bs_get(p, :yaxis2, :title), :text) == _BS._label(L"$P$ (W)")
		primary = _bs_axis_json(p, :yaxis)
		opts(; kw...) = _BS._apply_cartesian_plot_options!(p; ykey = :yaxis2, apply_template = false, who = "t", kw...)
		# A scale switch keeps the twin's data interval.
		opts(yscale = "linear")
		@test _bs_get(p, :yaxis2, :range) ≈ [1.0, 1e4]
		opts(yrange = (-5, 5))
		@test _bs_get(p, :yaxis2, :range) == [-5, 5]
		before = _bs_layout_json(p)
		@test _bs_throws(() -> opts(yrange = ("a", "b")), "t: `yrange` bounds on a linear axis must be numbers")
		@test _bs_throws(() -> opts(yscale = "log"), "t: the current y range (-5, 5) cannot be shown on a \"log\" axis")
		@test _bs_throws(() -> opts(yscale = "log", yrange = (0, 5)), "t: `yrange` bounds on a logarithmic axis are data values")
		@test _bs_throws(() -> opts(yrange = [2, 2]), "t: `yrange`: the range bounds must differ")
		@test _bs_throws(() -> opts(yticks = :decades), "t: the `:decades` tick preset")
		@test _bs_layout_json(p) == before
		opts(yscale = "log", yrange = (1, 10), yticks = :decades)
		@test _bs_get(p, :yaxis2, :range) == [0.0, 1.0]
		@test _bs_get(p, :yaxis2, :dtick) == 1
		@test _bs_axis_json(p, :yaxis) == primary
	end

	@testset "#100: each primitive writes only the axis it addresses" begin
		p = _bs_multi_axis_plot()
		others = Dict(key => _bs_axis_json(p, key) for key in (:xaxis2, :yaxis2, :yaxis3))
		_BS._apply_axis_title!(p, :x, "time")
		_BS._apply_axis_title!(p, :y, L"$\alpha$")
		_BS._apply_axis_scale!(p, :x, "log", "t")
		_BS._apply_axis_range!(p, :x, (1, 10), "t")
		_BS._apply_axis_scale!(p, :y, "linear", "t")
		_BS._apply_axis_range!(p, :y, (0, 3), "t")
		_BS._apply_axis_grid!(p, :x, "t")
		_BS._apply_ticks!(p, :xaxis; values = :decades, who = "t")
		_BS._apply_ticks!(p, :yaxis; values = [0, 1, 2], labels = ["a", "b", "c"], who = "t")
		_BS._apply_ticks!(p, :yaxis; values = :auto, who = "t")
		for (key, json) in others
			@test _bs_axis_json(p, key) == json
		end
		@test _bs_get(p, :xaxis, :range) == [0.0, 1.0]
		@test _bs_get(p, :yaxis, :range) == [0, 3]
		@test _bs_get(p, :xaxis, :showgrid) === true
		@test _bs_get(p, :yaxis, :showgrid) === false

		# The key-based variants address one non-primary axis.
		q = _bs_multi_axis_plot()
		snap = Dict(key => _bs_axis_json(q, key) for key in (:xaxis, :yaxis, :xaxis2, :yaxis3))
		_BS._apply_axis_scale_to_key!(q, :yaxis2, "linear", "t"; name = "yscale")
		@test _bs_get(q, :yaxis2, :range) ≈ [1.0, 100.0]
		_BS._apply_axis_range_to_key!(q, :yaxis2, (5, 50), "t"; name = "yrange")
		@test _bs_get(q, :yaxis2, :range) == [5, 50]
		@test _bs_get(q, :yaxis2, :title) !== nothing
		for (key, json) in snap
			@test _bs_axis_json(q, key) == json
		end
		@test _bs_throws(
			() -> _BS._require_axis_range_for_key(q, :yaxis3, (0, 5), "log", "t"; name = "yrange"),
			"t: `yrange` bounds on a logarithmic axis",
		)
		@test _bs_throws(
			() -> _BS._require_axis_range_for_key(q, :yaxis3, nothing, "log", "t"; name = "yrange"),
			"t: the current y range (0, 5) cannot be shown on a \"log\" axis",
		)
	end

	@testset "wave 5: the one encoder of one-sided limits (Z38)" begin
		# The view extent a one-sided limit is checked and completed against:
		# the finalizer's field extent (exact), else the data (to be padded).
		h = plot_heatmap(1:5, 1:4, reshape(collect(1.0:20.0), 5, 4))
		@test _BS._axis_group_view_extent(h, :xaxis, (:xaxis,), false) == ((0.5, 5.5), false)
		s = plot_scatter([1.0, 3.0], [2.0, 4.0])
		@test _BS._axis_group_view_extent(s, :xaxis, (:xaxis,), false) == ((1.0, 3.0), true)
		e = plot_scatter(Float64[], Float64[])
		@test _BS._axis_group_view_extent(e, :xaxis, (:xaxis,), false)[1] === nothing
		# A user clip is kept as the view; only the finalizer's clip is dropped.
		relayout!(_BS._cmn_plot(s); xaxis_autorangeoptions = attr(clipmin = 0.5, clipmax = 2.5))
		@test _BS._axis_group_view_extent(s, :xaxis, (:xaxis,), false) == ((0.5, 2.5), false)
		_BS._drop_finalizer_clip!(s, :xaxis)
		@test _bs_get(s, :xaxis, :autorangeoptions) !== nothing
		@test _BS._fin_sticky_clip(get(_bs_fields(h), :xaxis, nothing)) !== nothing
		_BS._drop_finalizer_clip!(h, :xaxis)
		@test _BS._fin_sticky_clip(get(_bs_fields(h), :xaxis, nothing)) === nothing
		# Every member of a matches group gets the limit; a full range clears it.
		g = plot_scatter([1.0, 3.0], [2.0, 4.0])
		relayout!(_BS._cmn_plot(g); yaxis2 = attr(matches = "y", anchor = "x", domain = [0.5, 1]))
		_BS._apply_axis_range_to_key!(g, :yaxis2, (nothing, 10), "yrange!"; name = "range")
		for key in (:yaxis, :yaxis2)
			@test _BS._cmn_mapping_get(_bs_get(g, key, :autorangeoptions), :maxallowed) == 10
		end
		_BS._apply_axis_range_to_key!(g, :yaxis, (0, 10), "yrange!"; name = "range")
		@test _bs_get(g, :yaxis, :range) == [0, 10]
		for key in (:yaxis, :yaxis2)
			@test _BS._cmn_mapping_get(_bs_get(g, key, :autorangeoptions), :maxallowed) === nothing
		end
		# Log axes store log10; a bound outside the data is refused before any write.
		l = plot_scatter([1.0, 10.0, 100.0], [1.0, 2.0, 3.0]; xscale = "log")
		_BS._apply_axis_range_to_key!(l, :xaxis, (10, nothing), "xrange!"; name = "range")
		@test _BS._cmn_mapping_get(_bs_get(l, :xaxis, :autorangeoptions), :minallowed) == 1.0
		before = _bs_layout_json(l)
		@test _bs_throws(() -> _BS._apply_axis_range_to_key!(l, :xaxis, (1000, nothing), "xrange!"; name = "range"),
			"xrange!: `range` fixes one end of the axis beyond all of its data")
		@test _bs_layout_json(l) == before
		# Z28: an empty constructor title writes nothing.
		t = plot_scatter([1.0, 2.0], [1.0, 2.0])
		before = _bs_layout_json(t)
		_BS._apply_figure_title!(t, "")
		@test _bs_layout_json(t) == before
	end
end
