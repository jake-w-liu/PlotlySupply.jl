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
			([nothing, 10], "partial ranges"),
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
			((yrange = [nothing, 1],), "t: `yrange`: partial ranges are not supported"),
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
		@test _bs_throws(() -> plot_scatter([1.0, 2.0], [1.0, 2.0]; xrange = [nothing, 1]), "partial ranges")
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
end
