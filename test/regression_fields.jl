using Test, PlotlySupply
using PlotlySupply: PlotlyBase

# These tests assert on the package's own defaults: an earlier file of the full run
# may leave a publication style active (`set_default_style!()` without an
# argument keeps the active style), which changes colorbar fonts and line widths.
set_default_style!(:default)

# Regression tests for the audit findings fixed in the 2-D field functions
# (plot_heatmap, plot_contour, plot_quiver, plot_image and their mutators).
# Each testset names the finding ids it covers.

const _RF_JSON = PlotlyBase.JSON

_rf_layout(fig) = PlotlySupply._plot_obj(fig).layout.fields
_rf_axis(fig, key) = PlotlySupply._symbol_dict(get(_rf_layout(fig), key, Dict{Symbol, Any}()))

function _rf_thrown(f)
	try
		f()
	catch err
		return err
	end
	return nothing
end

@testset "regression: 2-D fields" begin
	@testset "#78 quiver figures serialise (no NaN separators)" begin
		fig = plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 0.0], [0.0, 1.0])
		@test all(v -> v === nothing || isfinite(v), fig.data[1].fields[:x])
		json = _RF_JSON.json(fig)                       # strict JSON: throws on NaN
		@test occursin("null", json) && !occursin("NaN", json)
		@test !isempty(sprint(show, MIME"text/html"(), fig))
		@test !isempty(sprint(show, MIME"application/vnd.plotly.v1+json"(), fig))
		plot_quiver!(fig, [0.5], [0.5], [1.0], [1.0])
		@test !occursin("NaN", _RF_JSON.json(fig))
	end

	@testset "#79 #230 #274 #298 U[ix, iy] shape is validated" begin
		x = [0.0, 1.0, 2.0, 3.0]
		y = [10.0, 20.0]
		good = [xi + yi for xi in x, yi in y]               # size (4, 2)
		bad = permutedims(good)                             # size (2, 4)
		for f in (
			() -> plot_heatmap(x, y, bad),
			() -> plot_contour(x, y, bad),
			() -> plot_heatmap!(plot_heatmap(x, y, good), x, y, bad),
			() -> plot_contour!(plot_heatmap(x, y, good), x, y, bad),
		)
			err = _rf_thrown(f)
			@test err isa ArgumentError
			msg = sprint(showerror, err)
			@test occursin("(length(x), length(y)) = (4, 2)", msg)
			@test occursin("permutedims(U)", msg)
		end
		@test _rf_thrown(() -> plot_heatmap([1.0, 2, 3], [1.0, 2], rand(10, 10))) isa ArgumentError
		# Correct shapes and heatmap cell edges are still accepted.
		@test plot_heatmap(x, y, good) isa Plot
		@test plot_heatmap(0:4, 0:2, zeros(4, 2)) isa Plot
		@test _rf_thrown(() -> plot_contour(0:4, 0:2, zeros(4, 2))) isa ArgumentError
		# The documented orientation lands value f(x[i], y[j]) at (x[i], y[j]).
		z = _RF_JSON.parse(_RF_JSON.json(plot_heatmap(x, y, good).data[1]))["z"]
		@test all(z[i][j] == x[i] + y[j] for i in 1:4, j in 1:2)
		for f in (plot_heatmap, plot_heatmap!, plot_contour, plot_contour!)
			@test occursin("U[ix, iy]", string(Base.Docs.doc(f)))
		end
	end

	@testset "#81 implicit axes on a log axis start at 1" begin
		U = [Float64(i) for i in 1:4, j in 1:3]
		@test all(>(0), plot_heatmap(U; xscale = "log").data[1].fields[:x])
		@test all(>(0), plot_contour(U; yscale = "log").data[1].fields[:y])
		p = Plot()
		plot_heatmap!(p, U; xscale = "log")
		@test all(>(0), p.data[1].fields[:x])
		p2 = Plot()
		plot_contour!(p2, U; yscale = "log")
		@test all(>(0), p2.data[1].fields[:y])
		@test collect(plot_heatmap(U).data[1].fields[:x]) == 0:3
	end

	@testset "#85 #236 quiver traces can be named; unnamed ones stay out of the legend" begin
		q = plot_quiver([0.0], [0.0], [1.0], [0.0]; legend = "E")
		@test q.data[1].fields[:name] == "E" && q.data[1].fields[:showlegend] == true
		plot_quiver!(q, [0.0], [1.0], [1.0], [0.0]; legend = "B")
		@test q.data[2].fields[:name] == "B"
		anonymous = plot_scatter([1, 2, 3]; legend = "measured")
		plot_quiver!(anonymous, [0.0], [0.0], [1.0], [1.0])
		@test anonymous.data[2].fields[:showlegend] == false
		sf = subplots(1, 1; sync = false)
		plot_quiver!(sf, [0.0], [0.0], [1.0], [0.0]; legend = "S")
		@test any(t -> get(t.fields, :name, nothing) == "S", sf.plot.data)
	end

	@testset "#97 #113 axis titles are nested and styling survives mutators" begin
		for build in (
			() -> plot_heatmap(rand(3, 2); xlabel = "x", ylabel = "y"),
			() -> plot_contour(rand(3, 2); xlabel = "x", ylabel = "y"),
			() -> plot_quiver([0.0], [0.0], [1.0], [1.0]; xlabel = "x", ylabel = "y"),
		)
			fig = build()
			@test _rf_axis(fig, :xaxis)[:title] isa AbstractDict
			# A later labelled append writes title.text into the nested title.
			plot_scatter!(fig, [1.0, 2.0], [1.0, 2.0]; xlabel = "new x")
			@test PlotlySupply._symbol_dict(_rf_axis(fig, :xaxis)[:title])[:text] == "new x"
		end
		for mutate! in (
			f -> plot_heatmap!(f, rand(3, 3); xlabel = "new"),
			f -> plot_contour!(f, rand(3, 3); xlabel = "new"),
			f -> plot_quiver!(f, [0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 1.0]; xlabel = "new"),
		)
			p = plot_scatter([1, 2, 3]; xlabel = "old")
			relayout!(p, xaxis_title_font = attr(color = "red", size = 30))
			mutate!(p)
			t = PlotlySupply._symbol_dict(_rf_axis(p, :xaxis)[:title])
			@test t[:text] == "new"
			@test PlotlySupply._symbol_dict(t[:font])[:color] == "red"
		end
		# grid = true re-enables a hidden grid; the default leaves it alone (#113a).
		p = plot_scatter([1, 2, 3]; grid = false)
		plot_quiver!(p, [0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 1.0])
		@test _rf_axis(p, :xaxis)[:showgrid] === false
		plot_quiver!(p, [0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 1.0]; grid = true)
		@test _rf_axis(p, :xaxis)[:showgrid] === true && _rf_axis(p, :yaxis)[:showgrid] === true
	end

	@testset "#92 Bool masks draw as 0/1" begin
		mask = [true false; false true; true true]
		for build in (plot_heatmap, plot_contour)
			z = _RF_JSON.parse(_RF_JSON.json(build(mask).data[1]))["z"]
			@test z == [[1, 0], [0, 1], [1, 1]]
		end
	end

	@testset "#93 range keywords are validated" begin
		U = rand(3, 2)
		for f in (plot_heatmap, plot_contour), kw in (:xrange, :yrange, :zrange, :crange)
			err = _rf_thrown(() -> f(U; kw => [1]))
			@test err isa ArgumentError && occursin(string(kw), sprint(showerror, err))
		end
		@test _rf_thrown(() -> plot_quiver([0.0], [0.0], [1.0], [1.0]; xrange = [0, 1, 2])) isa ArgumentError
		@test _rf_thrown(() -> plot_image(zeros(UInt8, 2, 2, 3); yrange = [1])) isa ArgumentError
	end

	@testset "#98 #109 #229 #29 #37 equal aspect stays inside its subplot cell" begin
		sf = subplots(1, 2; sync = false)
		plot_scatter!(sf, [0.0, 100.0], [0.0, 1.0]; row = 1, col = 1)
		plot_quiver!(sf, collect(0.0:4.0), collect(0.0:4.0), ones(5), fill(0.5, 5); row = 1, col = 2)
		l = sf.plot.layout.fields
		@test PlotlySupply._symbol_dict(l[:yaxis2])[:scaleanchor] == "x2"
		@test !haskey(PlotlySupply._symbol_dict(l[:xaxis2]), :scaleanchor)
		@test !haskey(PlotlySupply._symbol_dict(l[:xaxis]), :scaleanchor)
		@test !haskey(PlotlySupply._symbol_dict(get(l, :yaxis, Dict())), :scaleanchor)
		sf2 = subplots(2, 2; sync = false)
		plot_heatmap!(sf2, rand(3, 4); row = 2, col = 1, equalar = true)
		plot_contour!(sf2, rand(3, 4); row = 2, col = 2, equalar = true)
		l2 = sf2.plot.layout.fields
		@test PlotlySupply._symbol_dict(l2[:yaxis3])[:scaleanchor] == "x3"
		@test PlotlySupply._symbol_dict(l2[:yaxis4])[:scaleanchor] == "x4"
		@test all(!haskey(PlotlySupply._symbol_dict(l2[k]), :scaleanchor) for k in (:xaxis3, :xaxis4))
		# Cell (1, 1) keeps its own anchor.
		sf3 = subplots(1, 2; sync = false)
		plot_quiver!(sf3, [0.0, 1.0], [0.0, 1.0], [1.0, 0.0], [0.0, 1.0]; row = 1, col = 1)
		@test PlotlySupply._symbol_dict(sf3.plot.layout.fields[:yaxis])[:scaleanchor] == "x"
		@test !haskey(PlotlySupply._symbol_dict(get(sf3.plot.layout.fields, :xaxis2, Dict())), :scaleanchor)
	end

	@testset "#118 #127 #232 #233 plot_image input forms and alpha" begin
		@test _rf_thrown(() -> plot_image(rand(4, 5))) isa ArgumentError
		@test _rf_thrown(() -> plot_image(UInt8[1 2; 3 4])) isa ArgumentError
		@test _rf_thrown(() -> plot_image(rand(4))) isa ArgumentError
		@test _rf_thrown(() -> plot_image(rand(UInt8, 2, 2, 3, 1))) isa ArgumentError
		@test _rf_thrown(() -> plot_image([[1.0, 2.0], [3.0, 4.0]])) isa ArgumentError
		fig = plot_image(zeros(UInt8, 2, 2, 3))
		@test _rf_thrown(() -> plot_image!(fig, rand(4, 5))) isa ArgumentError
		@test length(fig.data) == 1
		@test !haskey(fig.data[1].fields, :colormodel)
		@test plot_image(rand(UInt8, 2, 2, 4)).data[1].fields[:colormodel] == "rgba256"
		@test plot_image(rand(2, 2, 4)).data[1].fields[:colormodel] == "rgba"
		@test plot_image(rand(UInt8, 2, 2, 4); colormodel = "hsla").data[1].fields[:colormodel] == "hsla"
		plot_image!(fig, rand(2, 2, 4))
		@test fig.data[end].fields[:colormodel] == "rgba"
		# A Colors.jl matrix becomes rows of RGB bytes in display order.
		C = PlotlySupply.Colors
		z = _RF_JSON.parse(_RF_JSON.json(plot_image([C.RGB(1, 0, 0) C.RGB(0, 1, 0)]).data[1]))["z"]
		@test z == [[[255, 0, 0], [0, 255, 0]]]
		@test plot_image([[[255, 0, 0], [0, 255, 0]]]).data[1].fields[:type] == "image"
		@test plot_image([[255, 0, 0] for i in 1:2, j in 1:2]) isa Plot
	end

	@testset "#234 complex matrices throw" begin
		@test _rf_thrown(() -> plot_heatmap(ComplexF64[1 2; 3 4])) isa ArgumentError
		@test _rf_thrown(() -> plot_contour(1:2, 1:2, ComplexF64[1 2; 3 4])) isa ArgumentError
		fig = plot_heatmap([1.0 2.0; 3.0 4.0])
		@test _rf_thrown(() -> plot_heatmap!(fig, ComplexF64[1 2; 3 4])) isa ArgumentError
		@test length(fig.data) == 1
		@test plot_heatmap(abs.(ComplexF64[1 2; 3 4])).data[1].fields[:type] == "heatmap"
	end

	@testset "#235 quiver sizeref documented in data units" begin
		for f in (plot_quiver, plot_quiver!)
			d = string(Base.Docs.doc(f))
			@test occursin("2/3", d) && occursin("data units", d)
		end
		q = plot_quiver([0.0, 0.0, 0.0], [0.0, 1.0, 2.0], [0.3, 0.3, 1.5], [0.0, 0.0, 0.0]; sizeref = 1.5)
		xs = q.data[1].fields[:x]
		@test xs[16] - xs[15] ≈ 1.0                         # longest = 2/3 * sizeref
		@test xs[2] - xs[1] ≈ 0.2
	end

	@testset "#100 mutators only change the primary axes" begin
		p = PlotlySupply.make_subplots(rows = 1, cols = 2)
		plot_quiver!(p, [1.0, 2.0], [1.0, 2.0], [1.0, 1.0], [1.0, 0.0]; xrange = (1, 3), xscale = "log")
		l = p.layout.fields
		@test PlotlySupply._symbol_dict(l[:yaxis])[:scaleanchor] == "x"
		@test PlotlySupply._symbol_dict(l[:xaxis])[:type] == "log"
		x2 = PlotlySupply._symbol_dict(get(l, :xaxis2, Dict()))
		y2 = PlotlySupply._symbol_dict(get(l, :yaxis2, Dict()))
		@test !haskey(x2, :type) && !haskey(x2, :range) && !haskey(y2, :scaleanchor)
	end

	@testset "#96 #302 every keyword of the field functions is documented" begin
		# A mutator docstring refers to its constructor for the shared keywords.
		for (ctor, mut) in ((plot_heatmap, plot_heatmap!), (plot_contour, plot_contour!),
				(plot_quiver, plot_quiver!), (plot_image, plot_image!))
			@test occursin("[`$(nameof(ctor))`](@ref)", string(Base.Docs.doc(mut)))
			d = string(Base.Docs.doc(ctor)) * string(Base.Docs.doc(mut))
			for f in (ctor, mut), m in methods(f)
				parentmodule(m) === PlotlySupply || continue
				for k in Base.kwarg_decl(m)
					endswith(string(k), "...") && continue
					@test occursin("`$(k)", d)
				end
			end
		end
	end

	@testset "#87 no stale commented-out layout code in the field constructors" begin
		src = read(joinpath(pkgdir(PlotlySupply), "src", "api.jl"), String)
		@test !occursin("# margin = attr(r = 0, b = 0, t = 0, l = 0)", src)
	end
end

# ── 2.0 integration wave 3 (fields-int): X1, X23, X45, X20, D10, X10, #239,
# U[ix, iy] orientation and the keyword consistency sweep. ──────────────────

_rfv3_d(x) = PlotlySupply._symbol_dict(x)
_rfv3_anns(fig) = [_rfv3_d(a) for a in get(_rf_layout(fig), :annotations, Any[])]
_rfv3_names(fig) = String[String(get(a, :name, "")) for a in _rfv3_anns(fig)]
_rfv3_data(fig) = PlotlySupply._plot_obj(fig).data
# The one-sided limit (D11) on an axis: `(:pinned, range)` on an
# aspect-constrained axis, else `(autorange, minallowed, maxallowed)`.
function _rf_limit(fig, key)
	ax = _rf_axis(fig, key)
	get(ax, :autorange, true) === false && return (:pinned, collect(ax[:range]))
	opts = _rfv3_d(get(ax, :autorangeoptions, Dict{Symbol, Any}()))
	return (get(ax, :autorange, true), get(opts, :minallowed, nothing), get(opts, :maxallowed, nothing))
end
function _rfv3_msg(f)
	err = _rf_thrown(f)
	return err isa ArgumentError ? sprint(showerror, err) : repr(err)
end
function _rfv3_inset_sf()
	sf = subplots(2, 2; sync = false)
	inset!(sf, (0.6, 0.6, 0.35, 0.35); row = 2, col = 2)
	sf.current_row = 1
	sf.current_col = 1
	return sf, getfield(sf, :insets)[1]
end

@testset "regression: 2-D fields, 2.0 integration (fields-int)" begin
	U = [Float64(i + 10j) for i in 1:4, j in 1:3]

	@testset "X1 colorbar_title_side on the bar title" begin
		for (fig, side) in (
			(plot_heatmap(U; colorbar_title = "u", colorbar_title_side = :right), "right"),
			(plot_heatmap(U; colorbar_title = "u"), "top"),
			(plot_contour(U; colorbar_title = "u", colorbar_title_side = "bottom"), "bottom"),
			(plot_matrix(U; colorbar_title = "u", colorbar_title_side = " Right "), "right"),
		)
			title = _rfv3_d(_rfv3_d(fig.data[1].fields[:colorbar])[:title])
			@test title[:text] == "u" && title[:side] == side
		end
		f = plot_streamlines(0:3, 0:3, ones(4, 4), [Float64(x) for x in 0:3, y in 0:3];
			colorby = :speed, colorbar_title = "s", colorbar_title_side = :right)
		carrier = only(t for t in f.data if haskey(_rfv3_d(get(t.fields, :marker, Dict())), :colorbar))
		@test _rfv3_d(_rfv3_d(_rfv3_d(carrier.fields[:marker])[:colorbar])[:title])[:side] == "right"
		for (who, call) in (
			("plot_heatmap", () -> plot_heatmap(U; colorbar_title_side = :left)),
			("plot_contour", () -> plot_contour(U; colorbar_title_side = "middle")),
			("plot_matrix", () -> plot_matrix(U; colorbar_title_side = :left)),
			("plot_streamlines", () -> plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4); colorbar_title_side = :left)),
			("plot_heatmap!", () -> plot_heatmap!(plot_heatmap(U), U; colorbar_title_side = :left)),
		)
			@test occursin("$(who): `colorbar_title_side` must be :top, :right or :bottom", _rfv3_msg(call))
		end
	end

	@testset "X1 math colorbar titles become annotations (figures and cells)" begin
		math = L"\alpha"
		for (fig, name) in (
			(plot_heatmap(U; colorbar_title = math, colorbar_title_side = :right), "plotlysupply:colorbar_title:x:right"),
			(plot_contour(U; colorbar_title = math, colorbar_title_side = :bottom), "plotlysupply:colorbar_title:x:bottom"),
			(plot_contour(U; levels = [10, 12, 20, 35], colorbar_title = math), "plotlysupply:colorbar_title:x:top"),
			(plot_matrix(U; colorbar_title = math), "plotlysupply:colorbar_title:x:top"),
			(plot_heatmap(U; colorbar_title = math, coloraxis = :shared), "plotlysupply:colorbar_title:coloraxis:top"),
			(plot_streamlines(0:3, 0:3, ones(4, 4), [Float64(x) for x in 0:3, y in 0:3]; colorby = :speed,
				colorbar_title = math), "plotlysupply:colorbar_title:x:top"),
		)
			@test name in _rfv3_names(fig)
			ann = only(a for a in _rfv3_anns(fig) if a[:name] == name)
			@test ann[:text] == "\$\\alpha\$"
		end
		# The converted bar keeps no plotly title of its own.
		f = plot_heatmap(U; colorbar_title = math)
		@test !haskey(_rfv3_d(f.data[1].fields[:colorbar]), :title)
		# Mutator on a Plot, and a SubplotFigure cell (the delegate converts it
		# after placing the cell's bar).
		plot_heatmap!(f, U; colorbar_title = L"\beta", colorbar_title_side = :right)
		@test count(==("plotlysupply:colorbar_title:x:right"), _rfv3_names(f)) == 1
		sf = subplots(1, 2; sync = false)
		plot_contour!(sf, U; row = 1, col = 2, colorbar_title = math, colorbar_title_side = :right)
		@test "plotlysupply:colorbar_title:x2:right" in _rfv3_names(sf)
		plot_matrix!(sf, U; row = 1, col = 1, colorbar_title = math)
		@test "plotlysupply:colorbar_title:x:top" in _rfv3_names(sf)
	end

	# The clip `_finalize_figure!` owns on an axis (D10 sticky contract), or
	# `nothing` (no field on the axis, a user range or a one-sided limit).
	_rf_clip(fig, key) = PlotlySupply._fin_sticky_clip(get(_rf_layout(fig), key, nothing))
	range_builds = (
		("plot_heatmap", r -> plot_heatmap(U; r...)),
		("plot_contour", r -> plot_contour(U; r...)),
		("plot_quiver", r -> plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0]; r...)),
		("plot_image", r -> plot_image(zeros(UInt8, 2, 2, 3); r...)),
		("plot_streamlines", r -> plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4); r...)),
		("plot_heatmap!", r -> (f = plot_heatmap(U); plot_heatmap!(f, U; r...); f)),
		("plot_contour!", r -> (f = plot_heatmap(U); plot_contour!(f, U; r...); f)),
		("plot_quiver!", r -> (f = plot_heatmap(U); plot_quiver!(f, [1.0], [1.0], [1.0], [1.0]; r...); f)),
		("plot_image!", r -> (f = plot_heatmap(U); plot_image!(f, zeros(UInt8, 2, 2, 3); r...); f)),
		("plot_streamlines!", r -> (f = plot_heatmap(U); plot_streamlines!(f, 0:3, 0:3, ones(4, 4), ones(4, 4); r...); f)),
	)

	@testset "X23 K1 range sentinels are automatic: the sticky field extent, no user range" begin
		# Field extents per build (heatmap U: brick edges of 0:3 x 0:2; contour:
		# nodes; the mutators draw on plot_heatmap(U)). `pinned`: an
		# equal-aspect group, which finalize pins to its clip.
		# K5 / D16: a field alone, or with overlays whose anchors lie inside it,
		# is exactly tight (the quiver! anchor (1, 1) is inside). An overlay
		# whose anchors lie outside widens the axis to them plus
		# `_FIN_OVERLAY_PAD` (2.5 %) of the span on that side only: the
		# streamlines! grid reaches y = 3, past the field's top edge 2.5.
		hm = ((-0.5, 3.5), (-0.5, 2.5))
		pad(lo, hi) = PlotlySupply._FIN_OVERLAY_PAD * (hi - lo)
		# Extrema of every finite coordinate the traces draw on `axis`.
		function drawn(fig, axis)
			letter = Symbol(string(axis)[1])
			vals = Float64[v for t in fig.data for v in get(t.fields, letter, ()) if v isa Real && isfinite(v)]
			return extrema(vals)
		end
		sticky = Dict(
			"plot_heatmap" => (hm, false),
			"plot_contour" => (((0.0, 3.0), (0.0, 2.0)), false),
			"plot_heatmap!" => (hm, false),
			"plot_contour!" => (hm, false),
			"plot_quiver!" => (hm, true),
			"plot_streamlines!" => ((hm[1], (-0.5, 3.0 + pad(-0.5, 3.0))), false),
		)
		for (who, build) in range_builds, (index, (key, axis)) in enumerate(((:xrange, :xaxis), (:yrange, :yaxis)))
			for sentinel in ([0, 0], (0, 0), nothing, [nothing, nothing], (nothing, nothing))
				fig = build(NamedTuple{(key,)}((sentinel,)))
				ax = _rf_axis(fig, axis)
				if haskey(sticky, who)
					extents, pinned = sticky[who]
					@test _rf_clip(fig, axis) == extents[index]
					if pinned
						@test ax[:autorange] === false && Tuple(Float64.(ax[:range])) == extents[index]
					else
						@test !haskey(ax, :range) && get(ax, :autorange, true) !== false
					end
				elseif who in ("plot_quiver", "plot_streamlines")
					# D13: glyphs without a field span what they draw plus the
					# overlay pad on both sides (plotly.js autoranges line traces
					# unpadded and would cut the arrowheads at the frame); the
					# quiver's default equal aspect pins that clip.
					lo, hi = drawn(fig, axis)
					clip = _rf_clip(fig, axis)
					@test clip !== nothing && collect(clip) ≈ [lo - pad(lo, hi), hi + pad(lo, hi)]
					if who == "plot_quiver"
						@test ax[:autorange] === false && collect(ax[:range]) ≈ collect(clip)
					else
						@test !haskey(ax, :range) && get(ax, :autorange, true) !== false
					end
				else
					# An image: finalize measures its pixel edges; the
					# aspect-linked axes are pinned to them (a y axis
					# descending: plotly shows row 1 at the top).
					clip = _rf_clip(fig, axis)
					@test clip !== nothing
					@test ax[:autorange] === false && sort(Float64.(ax[:range])) == collect(clip)
				end
			end
		end
		# No user range was recorded: a later trace widens the automatic axis,
		# while an explicit range stays put. A marker is its own anchor: one
		# past the field's right edge widens the axis to it plus the overlay
		# pad on that side (the left edge stays at the field).
		widened = (-0.5, 10.0 + pad(-0.5, 10.0))
		f = plot_heatmap(U; xrange = nothing)
		plot_scatter!(f, [10.0], [1.0]; mode = "markers")
		@test _rf_clip(f, :xaxis) == widened && !haskey(_rf_axis(f, :xaxis), :range)
		g = plot_heatmap(U; xrange = (1, 3))
		plot_scatter!(g, [10.0], [1.0]; mode = "markers")
		@test collect(_rf_axis(g, :xaxis)[:range]) == [1, 3] && _rf_clip(g, :xaxis) === nothing
		q = plot_heatmap(U)
		plot_quiver!(q, [1.0], [1.0], [1.0], [1.0]; xrange = [0, 0])
		plot_scatter!(q, [10.0], [1.0]; mode = "markers")
		@test _rf_clip(q, :xaxis) == widened && Tuple(_rf_axis(q, :xaxis)[:range]) == widened
	end

	@testset "D13 glyphs without a field are padded in axis units (log axes, other traces)" begin
		q = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
			plot_quiver([1.0, 10.0], [1.0, 10.0], [1.0, 1.0], [0.0, 0.0]; xscale = "log", yscale = "log")
		end
		drawn_x = Float64[v for v in q.data[1].fields[:x] if v !== nothing]
		clip = _rf_clip(q, :xaxis)
		@test clip !== nothing && 0 < clip[1] < minimum(drawn_x) && clip[2] > maximum(drawn_x)
		# the pad is the overlay pad of the span in decades, on both sides
		span = log10(maximum(drawn_x)) - log10(minimum(drawn_x))
		@test log10(clip[2]) - log10(maximum(drawn_x)) ≈ PlotlySupply._FIN_OVERLAY_PAD * span
		@test log10(minimum(drawn_x)) - log10(clip[1]) ≈ PlotlySupply._FIN_OVERLAY_PAD * span
		# another trace on the group widens the glyph view by what it draws
		plot_scatter!(q, [1000.0], [5.0]; mode = "markers")
		@test _rf_clip(q, :xaxis)[2] >= 1000.0
	end

	@testset "D16 K5 quiver and streamline overlays count with their anchors" begin
		pad(lo, hi) = PlotlySupply._FIN_OVERLAY_PAD * (hi - lo)
		# hm_06: a quiver on the field's own grid. The anchors are the cell
		# centres, inside the brick edges, so both axes are exactly the field
		# (no white band) although the arrows reach past the top and right.
		xg = range(0, 4; length = 9)
		hm = plot_heatmap(xg, xg, [x * y for x in xg, y in xg]; equalar = true)
		plot_quiver!(hm, xg, xg, [1.0 for x in xg, y in xg], [0.5 for x in xg, y in xg]; sizeref = 0.5)
		glyph_x = filter(v -> v !== nothing, hm.data[2].fields[:x])
		@test maximum(glyph_x) > 4.25
		for axis in (:xaxis, :yaxis)
			@test _rf_clip(hm, axis) == (-0.25, 4.25)
			@test _rf_axis(hm, axis)[:autorange] === false && collect(_rf_axis(hm, axis)[:range]) == [-0.25, 4.25]
		end
		@test hm.data[2].fields[:meta] == Dict(:plotlysupply_anchor_extent => [0.0, 4.0, 0.0, 4.0])
		# Anchors outside the field: the axis reaches the anchors plus the pad,
		# on that side only.
		out = plot_heatmap(U)
		plot_quiver!(out, [6.0], [1.0], [1.0], [0.0]; equalar = false)
		@test _rf_clip(out, :xaxis) == (-0.5, 6.0 + pad(-0.5, 6.0)) && _rf_clip(out, :yaxis) == (-0.5, 2.5)
		# Streamlines on the field's grid: tight on the field.
		st = plot_heatmap(0:3, 0:2, U)
		plot_streamlines!(st, 0:3, 0:2, ones(4, 3), fill(0.5, 4, 3))
		@test _rf_clip(st, :xaxis) == (-0.5, 3.5) && _rf_clip(st, :yaxis) == (-0.5, 2.5)
		@test all(t -> t.fields[:meta] == Dict(:plotlysupply_anchor_extent => [0.0, 3.0, 0.0, 2.0]), st.data[2:end])
		# Without a field the axes show the drawn glyphs whole (D13): their
		# extent padded by the overlay pad on both sides (plotly.js autoranges
		# line traces without padding, which cut the arrowheads at the frame);
		# pinned on the equal-aspect quiver, an autorange clip without it.
		alone = plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0])
		for (axis, coords) in ((:xaxis, :x), (:yaxis, :y))
			lo, hi = extrema(filter(!isnothing, alone.data[1].fields[coords]))
			want = (lo - pad(lo, hi), hi + pad(lo, hi))
			@test _rf_clip(alone, axis) == want
			@test _rf_limit(alone, axis) == (:pinned, collect(want))
		end
		free = plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0]; equalar = false)
		lo, hi = extrema(filter(!isnothing, free.data[1].fields[:x]))
		@test _rf_clip(free, :xaxis) == (lo - pad(lo, hi), hi + pad(lo, hi)) && !haskey(_rf_axis(free, :xaxis), :range)
		# Streamlines alone: the lines' extent, padded the same way.
		sl = plot_streamlines(0:3, 0:2, ones(4, 3), fill(0.5, 4, 3))
		lo, hi = extrema(v for t in sl.data for v in get(t.fields, :x, Any[]) if v isa Real && isfinite(v))
		@test _rf_clip(sl, :xaxis) == (lo - pad(lo, hi), hi + pad(lo, hi))
		# A later trace widens the glyph view (the sticky contract).
		plot_scatter!(free, [9.0], [0.5]; mode = "markers")
		@test _rf_clip(free, :xaxis)[2] == 9.0 + pad(lo, 9.0)
		# The anchor extent is every finite position, drawn or not (a zero or
		# NaN vector still anchors), over the colorby traces too; the colorbar
		# carrier has none.
		cb = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
			plot_quiver([0.0, 1.0, 5.0, NaN], [0.0, 2.0, -1.0, 3.0], [1.0, 0.0, 1.0, 1.0], [0.0, 0.0, NaN, 1.0]; colorby = :magnitude)
		end
		# (The carrier's own meta holds its colour-bin record, O3.)
		glyphs = filter(t -> !PlotlySupply._cbar_is_carrier(t), cb.data)
		@test !isempty(glyphs) && length(glyphs) == length(cb.data) - 1
		@test PlotlySupply._cmn_mapping_get(get(cb.data[end].fields, :meta, nothing), :plotlysupply_anchor_extent) === nothing
		@test all(t -> t.fields[:meta] == Dict(:plotlysupply_anchor_extent => [0.0, 5.0, -1.0, 2.0]), glyphs)
		@test PlotlySupply._fin_field_kind(glyphs[1]) === nothing
	end

	@testset "X23 D11 K2 range keywords: two-sided, one-sided and invalid limits" begin
		msg(build, key, value) = _rfv3_msg(() -> build(NamedTuple{(key,)}((value,))))
		for (who, build) in range_builds, (key, axis) in ((:xrange, :xaxis), (:yrange, :yaxis))
			# plot_image (origin = :upper) reorders an explicit y range so the
			# image stays upright; every other range is written as given.
			flipped = who == "plot_image" && key === :yrange
			for given in ((1, 3), [1, 3], [1.0, 3.0])
				ax = _rf_axis(build(NamedTuple{(key,)}((given,))), axis)
				@test collect(ax[:range]) == (flipped ? [3, 1] : [1, 3]) && ax[:autorange] === false
			end
			# D11 (Z53: the shared `_checked_range(...; partial = true)` and range
			# primitives, as `xrange!`): a one-sided limit fixes the START (first
			# bound) or the STOP of the axis and autoranges the other end
			# (`autorangeoptions.minallowed`/`maxallowed`, which `savefig` keeps).
			# On an aspect-constrained axis (equal aspect, an image's axes) it is
			# pinned to the bound and the current view's other end, as matplotlib
			# does. An image's y axis is reversed (plotly's default, also when
			# plot_image! adds one), where the start is the larger value.
			reversed = who in ("plot_image", "plot_image!") && key === :yrange
			fig = build(NamedTuple{(key,)}(((1, nothing),)))
			aspect = haskey(_rf_axis(fig, :yaxis), :scaleanchor) || who in ("plot_image", "plot_image!")
			lim = _rf_limit(fig, axis)
			@test (lim[1] === :pinned) == aspect
			if aspect
				@test lim[2][1] == 1 && (lim[2][1] > lim[2][2]) == reversed
			else
				@test lim == (reversed ? "reversed" : true, 1, nothing) && !haskey(_rf_axis(fig, axis), :range)
			end
			# The limit is the user's: no finalize clip is left on the axis (a
			# pinned full range equal to a clip would be taken for finalize's
			# own and moved by the next trace).
			@test _rf_clip(fig, axis) === nothing
			lim = _rf_limit(build(NamedTuple{(key,)}(([nothing, 1],))), axis)
			if aspect
				@test lim[1] === :pinned && lim[2][2] == 1 && (lim[2][1] > lim[2][2]) == reversed
			else
				@test lim == (reversed ? "reversed" : true, nothing, 1)
			end
			# Invalid limits name the function and the keyword (the D11 messages
			# of the shared range check).
			@test occursin("$(who): `$(key)`: an open bound of a one-sided limit is written `nothing`",
				msg(build, key, (missing, 2)))
			@test occursin("$(who): `$(key)`: the range bounds must differ", msg(build, key, [2, 2]))
			@test occursin("$(who): `$(key)` range bounds must be numbers (or date/category values), not Bool",
				msg(build, key, (true, false)))
			@test occursin("$(who): `$(key)` range bounds must be numbers", msg(build, key, Any[false, 1]))
			@test occursin("$(who): `$(key)` bounds must be finite", msg(build, key, (Inf, nothing)))
			# The fixed end of a one-sided limit on an autotyped axis is a number
			# or a date (plotly.js reads date limits in milliseconds).
			@test occursin("$(who): `$(key)` bounds must be numbers (data values; 0-based positions on a " *
				"category axis) or dates; got (nothing, [1, 2]).", msg(build, key, (nothing, [1, 2])))
			@test occursin("$(who): `$(key)` bounds must be numbers (data values; 0-based positions on a " *
				"category axis) or dates; got (\"a\", nothing).", msg(build, key, ("a", nothing)))
		end
		@test collect(_rf_axis(plot_image(zeros(UInt8, 2, 2, 3); origin = :lower, yrange = (1, 3)), :yaxis)[:range]) == [1, 3]
		# Pinned on an image: the fixed bound and the image's pixel edge. With
		# `origin = :upper` (y reversed) the start is the bottom of the image,
		# the larger y, as matplotlib's `set_ylim(bottom = 1)` on an inverted
		# axis.
		@test _rf_limit(plot_image(zeros(UInt8, 2, 2, 3); origin = :lower, yrange = (nothing, 1)), :yaxis) == (:pinned, [-0.5, 1.0])
		@test _rf_limit(plot_image(zeros(UInt8, 2, 2, 3); yrange = (1, nothing)), :yaxis) == (:pinned, [1.0, -0.5])
		@test _rf_limit(plot_image(zeros(UInt8, 2, 2, 3); yrange = (nothing, 0)), :yaxis) == (:pinned, [1.5, 0.0])
		@test _rf_limit(plot_image(zeros(UInt8, 2, 3, 3); xrange = (nothing, 1)), :xaxis) == (:pinned, [-0.5, 1.0])
		# A stop beyond the data on the far side leaves no room: an error.
		# (the message is the shared D11 one, `_require_limit_meets_data`)
		@test occursin("plot_image: `yrange` fixes one end of the axis beyond all of its data",
			_rfv3_msg(() -> plot_image(zeros(UInt8, 2, 2, 3); yrange = (nothing, 2))))
		# ... also for a bilinear image, sized from its PNG header.
		@test _rf_limit(plot_image(zeros(UInt8, 2, 3, 3); interpolation = :bilinear, xrange = (1, nothing)), :xaxis) == (:pinned, [1.0, 2.5])
		# ... `xrange!` on an image takes the same view (Z53: one implementation).
		im = plot_image(zeros(UInt8, 2, 3, 3))
		xrange!(im, (1, nothing))
		@test _rf_limit(im, :xaxis) == (:pinned, [1.0, 2.5])
		# ... and on an equal-aspect quiver without a field: the glyph view
		# (their extent and the overlay pad, as finalize shows them), so the
		# glyphs at the open end stay whole; `xrange!` gives the same.
		qv = plot_quiver([0.0, 1, 2, 3], [0.0, 1, 0, 1], ones(4), [1.0, 0, -1, 0]; xrange = (nothing, 2.5))
		gx = filter(v -> v !== nothing, qv.data[1].fields[:x])
		ql = _rf_limit(qv, :xaxis)
		@test ql[1] === :pinned && ql[2][2] == 2.5 &&
			ql[2][1] ≈ minimum(gx) - PlotlySupply._FIN_OVERLAY_PAD * (maximum(gx) - minimum(gx))
		qv2 = plot_quiver([0.0, 1, 2, 3], [0.0, 1, 0, 1], ones(4), [1.0, 0, -1, 0])
		xrange!(qv2, (nothing, 2.5))
		@test _rf_limit(qv2, :xaxis) == ql
		# On a reversed axis without an aspect lock the first bound is the
		# start too: `maxallowed` (the bottom of an `origin = :upper` heatmap).
		h = plot_heatmap(U; origin = :upper, yrange = (0.5, nothing))
		@test _rf_limit(h, :yaxis) == ("reversed", nothing, 0.5) && !haskey(_rf_axis(h, :yaxis), :range)
		h = plot_heatmap(U; origin = :upper, yrange = (nothing, 1.5))
		@test _rf_limit(h, :yaxis) == ("reversed", 1.5, nothing)
		# The keyword and `yrange!` write the same limit (Z53).
		h2 = plot_heatmap(U; origin = :upper)
		yrange!(h2, (0.5, nothing))
		@test _rf_limit(h2, :yaxis) == _rf_limit(plot_heatmap(U; origin = :upper, yrange = (0.5, nothing)), :yaxis)
		# A one-sided limit on an axis finalize had clipped drops that clip (the
		# open side would otherwise stay clipped to the old extent); a new
		# one-sided limit replaces the old.
		f = plot_heatmap(U)
		@test _rf_clip(f, :xaxis) == (-0.5, 3.5)
		plot_heatmap!(f, U; xrange = (nothing, 3))
		@test _rf_limit(f, :xaxis) == (true, nothing, 3) && _rf_clip(f, :xaxis) === nothing
		@test _rfv3_d(_rf_axis(f, :xaxis)[:autorangeoptions]) == Dict(:maxallowed => 3)
		plot_heatmap!(f, U; xrange = (1, nothing))
		@test _rf_limit(f, :xaxis) == (true, 1, nothing)
		# The open side follows the data: later traces leave the limit and the
		# autorange in place (finalize writes no range over it).
		w = plot_heatmap(U; xrange = (nothing, 3))
		plot_scatter!(w, [-20.0], [1.0]; mode = "markers")
		plot_heatmap!(w, -10:-7, 0:2, rand(4, 3))
		@test _rf_limit(w, :xaxis) == (true, nothing, 3) && !haskey(_rf_axis(w, :xaxis), :range)
		# A one-sided limit replaces the limit and autorange-clip entries of
		# `autorangeoptions` (`_write_axis_range!`: an `include` or clip left on
		# the open end would freeze it), as `xrange!` does.
		k = plot_heatmap(U)
		relayout!(k; xaxis_autorangeoptions_include = -5, xaxis_autorangeoptions_minallowed = -1)
		plot_heatmap!(k, U; xrange = (nothing, 3))
		# (the user's own `include` stays: "other autorangeoptions the user set
		# are kept", `_write_axis_range!`; the earlier `minallowed` is replaced)
		opts = _rfv3_d(_rf_axis(k, :xaxis)[:autorangeoptions])
		@test opts[:maxallowed] == 3 && !haskey(opts, :minallowed) && opts[:include] == -5
		# A date bound is written in epoch milliseconds (plotly.js ignores a date
		# string in the autorange options).
		Dt = Base.require(Base.PkgId(Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), "Dates"))
		d = plot_heatmap(collect(Dt.Date(2024, 1, 1):Dt.Day(1):Dt.Date(2024, 1, 4)), 0:2, U; xrange = (Dt.Date(2024, 1, 3), nothing))
		@test _rf_limit(d, :xaxis) == (true, 1704240000000, nothing)
		# A failing mutator leaves the figure unchanged.
		f = plot_heatmap(U)
		@test _rf_thrown(() -> plot_heatmap!(f, U; xrange = [1, 1])) isa ArgumentError
		@test _rf_thrown(() -> plot_heatmap!(f, U; xrange = (missing, 1))) isa ArgumentError
		@test _rf_thrown(() -> plot_heatmap!(f, U; xrange = (10, nothing))) isa ArgumentError
		@test length(f.data) == 1 && _rf_clip(f, :xaxis) == (-0.5, 3.5)
	end

	@testset "X23 D11 ranges are data units on log axes, also in subplot cells" begin
		Dt = Base.require(Base.PkgId(Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), "Dates"))
		f = plot_heatmap([1.0, 10.0, 100.0], [1.0, 2.0], rand(3, 2); xscale = "log", xrange = (1, 1000))
		@test _rf_axis(f, :xaxis)[:range] == [0.0, 3.0] && _rf_axis(f, :xaxis)[:autorange] === false
		@test occursin("plot_heatmap: `xrange` bounds on a logarithmic axis are data values and must be positive", _rfv3_msg(() ->
			plot_heatmap([1.0, 10.0], [1.0, 2.0], rand(2, 2); xscale = "log", xrange = (0, 10))))
		# One-sided limits on a log axis: the bound in data units, stored as log10.
		f = plot_heatmap([1.0, 10.0, 100.0], [1.0, 2.0], rand(3, 2); xscale = "log", xrange = (10, nothing))
		@test _rf_limit(f, :xaxis) == (true, 1.0, nothing)
		f = plot_contour([1.0, 10.0, 100.0], [1.0, 2.0], rand(3, 2); yscale = "log", yrange = (nothing, 1000))
		@test _rf_limit(f, :yaxis) == (true, nothing, 3.0)
		for bad in ((0, nothing), (nothing, -1))
			@test occursin("plot_heatmap: `xrange` bounds on a logarithmic axis are data values and must be positive", _rfv3_msg(() ->
				plot_heatmap([1.0, 10.0], [1.0, 2.0], rand(2, 2); xscale = "log", xrange = bad)))
		end
		@test occursin("plot_quiver: `xrange` bounds on a linear axis must be numbers", _rfv3_msg(() ->
			plot_quiver([0.0], [0.0], [1.0], [1.0]; xscale = "linear", xrange = (Dt.Date(2024, 1, 1), nothing))))
		sf = subplots(1, 2; sync = false)
		plot_heatmap!(sf, [1.0, 10.0, 100.0], [1.0, 2.0], rand(3, 2); row = 1, col = 2, xscale = "log")
		plot_quiver!(sf, [2.0], [1.5], [1.0], [0.0]; row = 1, col = 2, xrange = (1, 1000), equalar = false)
		@test _rf_axis(sf, :xaxis2)[:range] == [0.0, 3.0] && _rf_axis(sf, :xaxis2)[:autorange] === false
		plot_heatmap!(sf, [1.0, 10.0, 100.0], [1.0, 2.0], rand(3, 2); row = 1, col = 2, xrange = (10, nothing))
		@test _rf_limit(sf, :xaxis2) == (true, 1.0, nothing)
		n = length(_rfv3_data(sf))
		@test occursin("plot_heatmap!", _rfv3_msg(() -> plot_heatmap!(sf, rand(2, 2); row = 1, col = 2, xrange = (0, 10))))
		@test occursin("plot_heatmap!: `xrange` bounds on a logarithmic axis are data values and must be positive",
			_rfv3_msg(() -> plot_heatmap!(sf, [1.0, 10.0], [1.0, 2.0], rand(2, 2); row = 1, col = 2, xrange = (0, nothing))))
		@test length(_rfv3_data(sf)) == n
		plot_contour!(sf, rand(2, 2); row = 1, col = 1, yrange = [nothing, 1])
		@test _rf_limit(sf, :yaxis) == (true, nothing, 1)
		# An image in a cell keeps plotly's reversed y default under a one-sided
		# limit (pinned: an image's axes are aspect-constrained), as on a Plot:
		# the stop is the top of the image, the smaller y.
		sfi = subplots(1, 2; sync = false)
		plot_image!(sfi, zeros(UInt8, 2, 2, 3); row = 1, col = 2, yrange = (nothing, 1))
		@test _rf_limit(sfi, :yaxis2) == (:pinned, [1.5, 1.0])
		@test occursin("plot_matrix!: unsupported keyword argument(s) `xrange`", _rfv3_msg(() ->
			plot_matrix!(sf, rand(2, 2); xrange = (0, 1))))
		# Shared x: plotly.js reads a matched axis's range from the group root
		# only, so a cell range is written there (row 1 matches row 2 here).
		shared = subplots(2, 1; sync = false, shared_xaxes = true)
		@test PlotlySupply._symbol_dict(_rf_axis(shared, :xaxis))[:matches] == "x2"
		plot_heatmap!(shared, U; row = 1, col = 1, xrange = (0, 5))
		@test collect(_rf_axis(shared, :xaxis2)[:range]) == [0, 5]
		@test !haskey(_rf_axis(shared, :xaxis), :range)
		shared = subplots(2, 1; sync = false, shared_xaxes = true)
		plot_heatmap!(shared, U; row = 1, col = 1, xrange = (nothing, 5))
		# The root autoranges; every member carries the option (plotly unites
		# the members' autoranges).
		@test _rf_limit(shared, :xaxis2) == (true, nothing, 5)
		@test _rfv3_d(_rf_axis(shared, :xaxis)[:autorangeoptions])[:maxallowed] == 5
		@test !haskey(_rf_axis(shared, :xaxis), :range) && _rf_clip(shared, :xaxis) === nothing
	end

	@testset "X45 #92 Bool fields draw as 0/1 (matrix too)" begin
		mask = [true false; false true; true true]
		z = _RF_JSON.parse(_RF_JSON.json(plot_matrix(mask).data[1]))["z"]
		@test sort(unique(reduce(vcat, z))) == [0, 1]
		p = plot_heatmap(U)
		plot_heatmap!(p, mask)
		@test _RF_JSON.parse(_RF_JSON.json(p.data[2]))["z"] == [[1, 0], [0, 1], [1, 1]]
	end

	@testset "X20 inset = k on every field mutator of a SubplotFigure" begin
		for (name, call) in (
			("heatmap!", (s) -> plot_heatmap!(s, rand(3, 3); inset = 1, equalar = true)),
			("heatmap!(x, y, U)", (s) -> plot_heatmap!(s, 0:2, 0:2, rand(3, 3); inset = 1, equalar = true)),
			("contour!", (s) -> plot_contour!(s, rand(3, 3); inset = 1, equalar = true)),
			("quiver!", (s) -> plot_quiver!(s, [1.0, 2.0], [1.0, 2.0], [1.0, 0.0], [0.0, 1.0]; inset = 1)),
			("image!", (s) -> plot_image!(s, fill(UInt8(9), 2, 2, 3); inset = 1)),
			("matrix!", (s) -> plot_matrix!(s, rand(2, 2); inset = 1)),
			("streamlines!", (s) -> plot_streamlines!(s, 0:3, 0:3, ones(4, 4), ones(4, 4); inset = 1, equalar = true)),
		)
			sf, rec = _rfv3_inset_sf()
			@test call(sf) === sf
			data = _rfv3_data(sf)
			@test !isempty(data)
			@test all(t -> t.fields[:xaxis] == rec.xref && t.fields[:yaxis] == rec.yref, data)
			# The equal aspect binds the inset's own axes, not the host cell's.
			@test get(_rf_axis(sf, rec.ykey), :scaleanchor, nothing) == rec.xref
			@test !haskey(_rf_axis(sf, :yaxis4), :scaleanchor)
			@test (sf.current_row, sf.current_col) == (2, 2)
		end
		sf, rec = _rfv3_inset_sf()
		relayout!(sf.plot; Symbol(rec.xkey) => attr(type = "log"))
		plot_heatmap!(sf, rand(3, 3); inset = 1)
		@test collect(_rfv3_data(sf)[end].fields[:x]) == [1, 2, 3]
		@test occursin("on a logarithmic axis", _rfv3_msg(() -> plot_heatmap!(sf, 0:2, 0:2, rand(3, 3); inset = 1)))
		@test occursin("unknown inset id 2", _rfv3_msg(() -> plot_quiver!(sf, [1.0], [1.0], [1.0], [1.0]; inset = 2)))
		@test occursin("inset 1 belongs to cell (2, 2), not (1, 1)", _rfv3_msg(() ->
			plot_heatmap!(sf, rand(2, 2); row = 1, col = 1, inset = 1)))
	end

	@testset "D10 M5 streamline arrowheads are solid in the line colour" begin
		f = plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4); color = :black)
		m = _rfv3_d(f.data[1].fields[:marker])
		@test m[:symbol] == "arrow" && m[:opacity] == 1 && _rfv3_d(m[:line])[:width] == 0
		@test m[:color] == "black" == _rfv3_d(f.data[1].fields[:line])[:color]
		g = plot_streamlines(0:3, 0:3, ones(4, 4), [Float64(x) for x in 0:3, y in 0:3]; colorby = :speed)
		for t in g.data
			haskey(t.fields, :marker) && get(t.fields, :mode, "") == "lines+markers" || continue
			mk = _rfv3_d(t.fields[:marker])
			@test mk[:color] == _rfv3_d(t.fields[:line])[:color] && mk[:opacity] == 1
		end
		# Without a colour the marker colour is left to plotly, which uses the
		# trace colour for both line and marker.
		@test !haskey(_rfv3_d(plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4)).data[1].fields[:marker]), :color)
	end

	@testset "D10 tight: field traces carry the finalize meta, overlays do not" begin
		tight, loose = "plotlysupply:field", "plotlysupply:field:loose"
		@test plot_heatmap(U).data[1].fields[:meta] == tight
		@test plot_heatmap(U; tight = false).data[1].fields[:meta] == loose
		@test plot_contour(U).data[1].fields[:meta] == tight
		@test !haskey(plot_contour(U; coloring = "lines").data[1].fields, :meta)
		@test plot_contour(U; coloring = "lines", tight = false).data[1].fields[:meta] == loose
		bands = plot_contour(U; levels = [10, 12, 20, 35])
		@test all(t -> get(t.fields, :meta, nothing) == tight, filter(t -> get(t.fields, :type, "") == "contour", bands.data))
		@test plot_image(zeros(UInt8, 2, 2, 3); tight = false).data[1].fields[:meta] == loose
		@test plot_matrix(U).data[1].fields[:meta] == tight
		# Overlays carry no field `meta`; quiver and streamline traces carry
		# their anchor extent there instead (D16), which is not a field mark.
		for overlay in (plot_quiver([0.0], [0.0], [1.0], [1.0]), plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4)))
			@test all(t -> PlotlySupply._fin_field_kind(t) === nothing, overlay.data)
		end
		@test plot_quiver([0.0], [0.0], [1.0], [1.0]).data[1].fields[:meta] == Dict(:plotlysupply_anchor_extent => [0.0, 0.0, 0.0, 0.0])
		@test plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4)).data[1].fields[:meta] == Dict(:plotlysupply_anchor_extent => [0.0, 3.0, 0.0, 3.0])
		p = plot_heatmap(U)
		plot_heatmap!(p, U; tight = false)
		@test p.data[2].fields[:meta] == loose
		for (who, call) in (
			("plot_heatmap", () -> plot_heatmap(U; tight = 1)),
			("plot_contour", () -> plot_contour(U; tight = nothing)),
			("plot_image", () -> plot_image(zeros(UInt8, 2, 2, 3); tight = "yes")),
			("plot_matrix!", () -> plot_matrix!(plot_heatmap(U), U; tight = 0)),
		)
			@test occursin("$(who): `tight` must be true or false", _rfv3_msg(call))
		end
	end

	@testset "D10 K3 field mutators finalize the figure (sticky contract)" begin
		# A mutator on a Plot runs `_finalize_figure!`: the `matches` root that
		# holds a field gets finalize's clip of the field extent (autoranging
		# within it, or pinned to it on an equal-aspect group), which a later
		# trace widens; a root without a field keeps plotly's autorange, unless
		# it holds quiver/streamline glyphs (`:glyphs`, D13): then the clip is
		# what they draw plus the overlay pad on both sides.
		for (name, mutate!, extent, pinned) in (
			("heatmap!", p -> plot_heatmap!(p, U), (-0.5, 3.5), false),
			("contour!", p -> plot_contour!(p, U), (0.0, 3.0), false),
			("matrix!", p -> plot_matrix!(p, U), (0.5, 3.5), true),
			("quiver!", p -> plot_quiver!(p, [0.0], [0.0], [1.0], [1.0]), :glyphs, true),
			("image!", p -> plot_image!(p, zeros(UInt8, 2, 2, 3)), (-0.5, 1.5), true),
			("streamlines!", p -> plot_streamlines!(p, 0:3, 0:3, ones(4, 4), ones(4, 4)), :glyphs, false),
		)
			p = Plot(GenericTrace[], Layout(xaxis2 = attr(matches = "x", anchor = "y2"), yaxis2 = attr(anchor = "x2")))
			mutate!(p)
			ax = _rf_axis(p, :xaxis)
			if extent === :glyphs
				lo, hi = extrema(Float64[v for t in p.data for v in get(t.fields, :x, ()) if v isa Real && isfinite(v)])
				pad = PlotlySupply._FIN_OVERLAY_PAD * (hi - lo)
				clip = _rf_clip(p, :xaxis)
				@test clip !== nothing && collect(clip) ≈ [lo - pad, hi + pad]
				if pinned
					@test ax[:autorange] === false && collect(ax[:range]) ≈ collect(clip)
				else
					@test get(ax, :autorange, true) === true && !haskey(ax, :range)
				end
				continue
			end
			@test _rf_clip(p, :xaxis) == extent
			if pinned
				@test ax[:autorange] === false && Tuple(Float64.(ax[:range])) == extent
			else
				@test ax[:autorange] === true && !haskey(ax, :range)
			end
			# A marker past the field: the axis reaches it plus the overlay pad
			# (2.5 % of the span) on that side; the field side stays tight.
			marker = extent[2] + 10.0
			plot_scatter!(p, [marker], [0.5]; mode = "markers")
			widened = (extent[1], marker + PlotlySupply._FIN_OVERLAY_PAD * (marker - extent[1]))
			@test _rf_clip(p, :xaxis) == widened
			pinned && @test Tuple(Float64.(_rf_axis(p, :xaxis)[:range])) == widened
		end
		# SubplotFigure path with a cell range: the other shared-x group keeps
		# autoranging (the plotly.js empty-range collapse finalize prevents).
		sf = subplots(2, 2; sync = false, shared_xaxes = true)
		roots = sort!(collect(PlotlySupply._fin_match_roots(sf.plot.layout)))
		@test length(roots) == 2
		for root in roots
			ax = sf.plot.layout.fields[root]
			delete!(ax isa AbstractDict ? ax : ax.fields, :autorange)
		end
		plot_heatmap!(sf, U; row = 1, col = 1, xrange = (0, 2))
		ranged = [r for r in roots if haskey(_rf_axis(sf, r), :range)]
		@test length(ranged) == 1
		other = only(setdiff(roots, ranged))
		@test _rf_axis(sf, other)[:autorange] === true
	end

	@testset "X10 field overlays take the style's line width, not its cycle" begin
		with_style(; linewidth = 3, cycle = :dash_marker) do
			q = plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0])
			@test _rfv3_d(q.data[1].fields[:line])[:width] == 3
			@test q.data[1].fields[:mode] == "lines" && !haskey(_rfv3_d(q.data[1].fields[:line]), :dash)
			s = plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4))
			@test _rfv3_d(s.data[1].fields[:line])[:width] == 3
			@test _rfv3_d(s.data[1].fields[:marker])[:symbol] == "arrow"
			@test _rfv3_d(plot_contour(U; coloring = "lines").data[1].fields[:line])[:width] == 3
			@test !haskey(plot_contour(U).data[1].fields, :line)
			# An explicit width wins.
			@test _rfv3_d(plot_quiver([0.0], [0.0], [1.0], [1.0]; linewidth = 1.5).data[1].fields[:line])[:width] == 1.5
			@test _rfv3_d(plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4); linewidth = 2).data[1].fields[:line])[:width] == 2
			# The SubplotFigure path applies it too.
			sf = subplots(1, 2; sync = false)
			plot_quiver!(sf, [0.0], [0.0], [1.0], [1.0]; row = 1, col = 2)
			@test _rfv3_d(_rfv3_data(sf)[end].fields[:line])[:width] == 3
		end
		# Without a style: plotly's quiver default (unset) and 1 px streamlines.
		@test !haskey(_rfv3_d(plot_quiver([0.0], [0.0], [1.0], [1.0]).data[1].fields[:line]), :width)
		@test _rfv3_d(plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4)).data[1].fields[:line])[:width] == 1
	end

	@testset "#239 unknown colorscale names throw; plotly names resolve" begin
		for call in (
			() -> plot_heatmap(U; colorscale = "nosuchmap"),
			() -> plot_contour(U; colorscale = "nosuchmap"),
			() -> plot_matrix(U; colorscale = "nosuchmap"),
			() -> plot_streamlines(0:3, 0:3, ones(4, 4), [Float64(x) for x in 0:3, y in 0:3]; colorby = :speed, colorscale = "nosuchmap"),
			() -> plot_heatmap!(plot_heatmap(U), U; colorscale = "nosuchmap"),
		)
			@test occursin("nosuchmap", _rfv3_msg(call))
		end
		for name in ("Plasma", "plasma", "Viridis_r")
			f = plot_heatmap(U; colorscale = name)
			@test haskey(f.data[1].fields, :colorscale)
		end
	end

	@testset "#237 #287 U[ix, iy] is drawn at (x[ix], y[iy]) (non-square, non-symmetric)" begin
		x = [0.0, 1.0, 2.0, 3.0, 4.0]
		y = [10.0, 20.0, 30.0]
		F = [xi + 100 * yi for xi in x, yi in y]            # size (5, 3)
		for fig in (plot_heatmap(x, y, F), plot_contour(x, y, F))
			j = _RF_JSON.parse(_RF_JSON.json(fig.data[1]))
			@test j["transpose"] == true && j["x"] == x && j["y"] == y
			@test all(j["z"][i][k] == x[i] + 100 * y[k] for i in 1:5, k in 1:3)
		end
		# pcolormesh: C[i, k] colours the cell [x[i], x[i+1]] x [y[k], y[k+1]].
		C = [i + 10k for i in 1:4, k in 1:2]
		pm = plot_pcolormesh(x, y, C; equalar = false).data[1]
		# What plotly.js draws is the JSON: row k of `z` is C[:, k] (the trace
		# keeps C itself, mr-07).
		z = _RF_JSON.parse(_RF_JSON.json(pm))["z"]
		@test pm.fields[:x] == x && pm.fields[:y] == y && pm.fields[:transpose] == false
		@test all(z[k][i] == C[i, k] for i in 1:4, k in 1:2)
		# quiver: the arrow of u[ix, iy], v[ix, iy] starts at (x[ix], y[iy]).
		u = [ix == 5 && iy == 1 ? 1.0 : 0.0 for ix in 1:5, iy in 1:3]
		q = plot_quiver(x, y, u, zeros(5, 3); sizeref = 1, equalar = false).data[1]
		xs = filter(!isnothing, q.fields[:x])
		ys = filter(!isnothing, q.fields[:y])
		@test xs[1] == 4.0 && ys[1] == 10.0 && maximum(xs) > 4.0 && all(==(10.0), ys[1:2])
		# streamlines: U = 0, V = +1 right of x = 2 and -1 left of it, so a
		# streamline seeded on the right moves up and one on the left down.
		V = [xi > 2 ? 1.0 : -1.0 for xi in x, yi in y]
		for (seed, up) in (((3.5, 20.0), true), ((0.5, 20.0), false))
			s = plot_streamlines(x, y, zeros(5, 3), V; seeds = [seed], direction = :forward, arrows = false).data[1]
			sy = filter(!isnothing, s.fields[:y])
			@test (sy[end] > sy[1]) == up
			@test all(xv -> isapprox(xv, seed[1]; atol = 1e-9), filter(!isnothing, s.fields[:x]))
		end
		# plot_matrix keeps the printed convention: A[i, j] is row i, column j.
		A = [10i + j for i in 1:2, j in 1:3]
		m = plot_matrix(A)
		mj = _RF_JSON.parse(_RF_JSON.json(m.data[1]))
		@test _rf_axis(m, :yaxis)[:autorange] === false && issorted(_rf_axis(m, :yaxis)[:range]; rev = true)  # K4: pinned descending, row 1 at the top
		cell(i, j) = mj["transpose"] ? mj["z"][j][i] : mj["z"][i][j]
		@test all(cell(i, j) == A[i, j] for i in 1:2, j in 1:3)
	end

	@testset "consistency sweep: field constructors and mutators" begin
		xr = 0:3                                            # range
		yv = view([0.0, 1.0, 2.0, 9.0], 1:3)               # SubArray
		Uadj = permutedims([1.0 2.0 3.0 4.0; 5.0 NaN 7.0 8.0; 9.0 10.0 11.0 12.0])'  # Adjoint, size (3, 4)
		Uf = collect(Uadj')                                # size (4, 3), NaN field
		labels = (xlabel = L"\alpha", ylabel = L"\beta")
		ranges = (xrange = (0, 3), yrange = [0, 2])
		calls = (
			(plot_heatmap, plot_heatmap!, (xr, yv, Uf), (colorscale = :viridis,)),
			(plot_contour, plot_contour!, (xr, yv, Uf), (linecolor = :black,)),
			(plot_quiver, plot_quiver!, (xr, yv, Uf, Uf), (color = :red,)),
			(plot_streamlines, plot_streamlines!, (xr, yv, Uf, Uf), (color = :black,)),
			(plot_image, plot_image!, (fill(UInt8(7), 3, 4, 3),), NamedTuple()),
			(plot_matrix, plot_matrix!, (Uadj,), NamedTuple()),
		)
		for (ctor, mut, args, extra) in calls
			has_ranges = ctor !== plot_matrix
			kw = has_ranges ? merge(labels, ranges, extra) : merge(labels, extra)
			fig = ctor(args...; kw...)
			@test fig isa Plot
			@test _rfv3_d(_rf_axis(fig, :xaxis)[:title])[:text] == "\$\\alpha\$"
			if has_ranges
				@test collect(_rf_axis(fig, :xaxis)[:range]) == [0, 3]
				# plot_image keeps row 1 at the top: its y range is written downward.
				@test collect(_rf_axis(fig, :yaxis)[:range]) == (ctor === plot_image ? [2, 0] : [0, 2])
			end
			# Mutator on a Plot: same keywords; `show` and unknown keywords throw.
			p = plot_heatmap(U)
			@test mut(p, args...; kw...) === nothing
			@test length(p.data) > 1
			@test _rf_thrown(() -> mut(p, args...; show = true)) isa ArgumentError
			@test _rf_thrown(() -> mut(p, args...; bogus_keyword = 1)) isa ArgumentError
			@test _rf_thrown(() -> ctor(args...; bogus_keyword = 1)) isa Union{ArgumentError, MethodError}
			# Mutator on SubplotFigure cell (2, 2).
			sf = subplots(2, 2; sync = false)
			@test mut(sf, args...; row = 2, col = 2, kw...) === sf
			@test all(t -> t.fields[:xaxis] == "x4" && t.fields[:yaxis] == "y4", _rfv3_data(sf))
			if has_ranges
				@test collect(_rf_axis(sf, :xaxis4)[:range]) == [0, 3]
				@test collect(_rf_axis(sf, :yaxis4)[:range]) == [0, 2]
			end
			n = length(_rfv3_data(sf))
			@test _rf_thrown(() -> mut(sf, args...; row = 2, col = 2, show = true)) isa ArgumentError
			@test _rf_thrown(() -> mut(sf, args...; row = 2, col = 2, bogus_keyword = 1)) isa ArgumentError
			@test length(_rfv3_data(sf)) == n
		end
	end
end

# Wave 4 (fields): G15 contour line colours, D13 quiver glyphs, G67
# interpolation, G30 plot_matrix ticks, Y3 SubplotFigure field methods, Y25
# dates.
const _RF_Dates = Base.require(Base.PkgId(Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), "Dates"))

# Element-wise comparison of glyph coordinates with `nothing` gaps.
_rf_coords_match(a, b) = length(a) == length(b) && all(eachindex(a, b)) do i
	(a[i] === nothing && b[i] === nothing) ||
		(a[i] !== nothing && b[i] !== nothing && isapprox(a[i], b[i]; atol = 1e-12))
end
_rf_traces(fig, type) = [t for t in _rfv3_data(fig) if get(t.fields, :type, "") == type]

# Decode an "image/png" data URI written by plot_image(...; interpolation =
# :bilinear): an 8-bit RGBA PNG whose zlib stream holds stored deflate blocks.
# Checks every chunk CRC, the block lengths and the Adler-32 sum; returns
# (width, height, 4×W×H bytes).
function _rf_png_rgba(uri::AbstractString)
	prefix = "data:image/png;base64,"
	@assert startswith(uri, prefix)
	bytes = PlotlySupply.Base64.base64decode(uri[(length(prefix) + 1):end])
	be32(i) = (UInt32(bytes[i]) << 24) | (UInt32(bytes[i + 1]) << 16) | (UInt32(bytes[i + 2]) << 8) | UInt32(bytes[i + 3])
	@assert bytes[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
	i = 9
	chunks = Pair{String, Vector{UInt8}}[]
	while i <= length(bytes)
		n = Int(be32(i))
		tag = bytes[(i + 4):(i + 7)]
		payload = bytes[(i + 8):(i + 7 + n)]
		@assert be32(i + 8 + n) == PlotlySupply._crc32(vcat(tag, payload))
		push!(chunks, String(copy(tag)) => payload)
		i += 12 + n
	end
	@assert first.(chunks) == ["IHDR", "IDAT", "IEND"]
	ihdr = chunks[1].second
	width = Int((UInt32(ihdr[1]) << 24) | (UInt32(ihdr[2]) << 16) | (UInt32(ihdr[3]) << 8) | ihdr[4])
	height = Int((UInt32(ihdr[5]) << 24) | (UInt32(ihdr[6]) << 16) | (UInt32(ihdr[7]) << 8) | ihdr[8])
	@assert ihdr[9:13] == UInt8[8, 6, 0, 0, 0]
	z = chunks[2].second
	@assert (UInt16(z[1]) << 8 | z[2]) % 31 == 0 && z[1] & 0x0f == 8
	raw = UInt8[]
	j = 3
	while true
		header = z[j]
		len = Int(z[j + 1]) | Int(z[j + 2]) << 8
		@assert (Int(z[j + 3]) | Int(z[j + 4]) << 8) == xor(len, 0xffff) && header & 0x06 == 0
		append!(raw, z[(j + 5):(j + 4 + len)])
		j += 5 + len
		header & 0x01 == 0x01 && break
	end
	a, b = 1, 0
	for x in raw
		a = (a + x) % 65521
		b = (b + a) % 65521
	end
	@assert j + 3 == length(z) && UInt32(b << 16 | a) == ((UInt32(z[j]) << 24) | (UInt32(z[j + 1]) << 16) | (UInt32(z[j + 2]) << 8) | z[j + 3])
	@assert length(raw) == height * (4width + 1) && all(r -> raw[(r - 1) * (4width + 1) + 1] == 0x00, 1:height)
	px = Array{UInt8}(undef, 4, width, height)
	for r in 1:height
		px[:, :, r] = reshape(raw[((r - 1) * (4width + 1) + 2):(r * (4width + 1))], 4, width)
	end
	return width, height, px
end

@testset "regression: 2-D fields, wave 4 (fields)" begin
	U = [Float64(i + 10j) for i in 1:4, j in 1:3]          # 11 .. 34

	@testset "G15 per-level contour lines take their level's colour" begin
		levels = [11.0, 13.0, 20.0, 33.0]                    # non-uniform: one trace per level
		f = plot_contour(U; levels = levels, coloring = "lines", colorscale = "Viridis", showlabels = true)
		lines = _rf_traces(f, "contour")
		@test length(lines) == 4
		expected = PlotlySupply._sample_colorscale("Viridis", (levels .- 11) ./ 22)
		@test [_rfv3_d(t.fields[:line])[:color] for t in lines] == expected
		@test length(unique(expected)) == 4
		for (t, colour, level) in zip(lines, expected, levels)
			c = _rfv3_d(t.fields[:contours])
			@test c[:coloring] == "none" && c[:start] == level == c[:end]
			@test _rfv3_d(c[:labelfont])[:color] == colour
			# plotly.js lists a coloring "none" contour in the legend unless told not to.
			@test t.fields[:showscale] == false && t.fields[:showlegend] == false
		end
		# One invisible carrier draws the colorbar over the level span, its
		# ticks at the levels (matplotlib's colorbar of a ContourSet).
		carrier = only(_rf_traces(f, "scatter"))
		m = _rfv3_d(carrier.fields[:marker])
		@test m[:cmin] == 11 && m[:cmax] == 33 && m[:showscale] == true
		@test _rfv3_d(m[:colorbar])[:tickvals] == levels
		# `crange` sets the norm.
		g = plot_contour(U; levels = levels, coloring = "lines", colorscale = "Viridis", crange = (0, 44))
		@test [_rfv3_d(t.fields[:line])[:color] for t in _rf_traces(g, "contour")] ==
			PlotlySupply._sample_colorscale("Viridis", levels ./ 44)
		# `cmid` centres a symmetric norm on it.
		V = U .- 22
		mid = [-2.0, -1.0, 0.5, 3.0]
		h = plot_contour(V; levels = mid, coloring = "lines", colorscale = "RdBu", cmid = 0)
		@test [_rfv3_d(t.fields[:line])[:color] for t in _rf_traces(h, "contour")] ==
			PlotlySupply._sample_colorscale("RdBu", (mid .+ 3) ./ 6)
		# Log norm: positions in log10, ticks at the levels with log labels.
		L = [10.0^(i - 1) for i in 1:4, j in 1:3]
		lv = [1.0, 3.0, 30.0, 1000.0]
		k = plot_contour(L; levels = lv, coloring = "lines", colornorm = :log, colorscale = "Plasma")
		@test [_rfv3_d(t.fields[:line])[:color] for t in _rf_traces(k, "contour")] ==
			PlotlySupply._sample_colorscale("Plasma", log10.(lv) ./ 3)
		kb = _rfv3_d(_rfv3_d(only(_rf_traces(k, "scatter")).fields[:marker])[:colorbar])
		@test kb[:tickvals] ≈ log10.(lv)
		@test kb[:ticktext] == ["1", "3", "30", "10<sup>3</sup>"]
		# Many levels: at most 10 colorbar ticks, all of them levels; explicit
		# `colorbar_ticks` win.
		many = cumsum(1.0:25.0) ./ 10 .+ 10
		mb = _rfv3_d(_rfv3_d(only(_rf_traces(plot_contour(U; levels = many, coloring = "lines"), "scatter")).fields[:marker])[:colorbar])
		@test 1 <= length(mb[:tickvals]) <= 10 && issubset(mb[:tickvals], many)
		ub = _rfv3_d(_rfv3_d(only(_rf_traces(plot_contour(U; levels = levels, coloring = "lines",
			colorbar_ticks = [15, 25]), "scatter")).fields[:marker])[:colorbar])
		@test ub[:tickvals] == [15, 25]
		# A single level is drawn in one colour from the data norm; uniform
		# levels stay one native trace coloured by plotly.
		s = plot_contour(U; levels = [22.5], colorscale = "Viridis")
		@test _rfv3_d(only(_rf_traces(s, "contour")).fields[:line])[:color] ==
			only(PlotlySupply._sample_colorscale("Viridis", [(22.5 - 11) / (34 - 11)]))
		n = plot_contour(U; levels = 12:4:32, coloring = "lines")
		@test length(_rfv3_data(n)) == 1 && _rfv3_d(n.data[1].fields[:contours])[:coloring] == "lines"
		# Single-colour lines keep no colorbar.
		@test isempty(_rf_traces(plot_contour(U; levels = levels, linecolor = "black"), "scatter"))
		@test occursin("take the colour of", string(Base.Docs.doc(plot_contour)))
	end

	@testset "D13 quiver glyph styles, pivots and scales" begin
		x, y, u, v = [0.0, 1.0], [0.0, 0.0], [1.0, 2.0], [0.0, 0.0]
		shaft(f) = Float64.(f.data[1].fields[:x][1:2])
		# Arrows: the longest is 2/3 sizeref long; the default pivot is :tail.
		@test shaft(plot_quiver(x, y, u, v)) ≈ [0.0, 1 / 3]
		@test shaft(plot_quiver(x, y, u, v; pivot = :middle)) ≈ [-1 / 6, 1 / 6]
		@test shaft(plot_quiver(x, y, u, v; pivot = "tip")) ≈ [-1 / 3, 0.0]
		@test shaft(plot_quiver(x, y, u, v; scale = :uniform)) ≈ [0.0, 2 / 3]
		@test shaft(plot_quiver(x, y, u, v; scale = :uniform, sizeref = 0.5)) ≈ [0.0, 1 / 3]
		# Triangles: base, apex, base, base, gap; base width = headwidth x
		# length; the default pivot is :middle.
		t = plot_quiver(x, y, u, v; style = :triangle).data[1].fields
		@test _rf_coords_match(t[:x], [-1 / 6, 1 / 6, -1 / 6, -1 / 6, nothing, 2 / 3, 4 / 3, 2 / 3, 2 / 3, nothing])
		@test _rf_coords_match(t[:y], [1 / 12, 0, -1 / 12, 1 / 12, nothing, 1 / 6, 0, -1 / 6, 1 / 6, nothing])
		@test t[:fill] == "toself" && t[:mode] == "lines" && t[:fillcolor] == "RoyalBlue"
		@test _rfv3_d(t[:line])[:width] == 0 && _rfv3_d(t[:line])[:simplify] == false
		w = plot_quiver(x, y, u, v; style = :triangle, headwidth = 1, pivot = :tail).data[1].fields
		@test _rf_coords_match(w[:x][1:4], [0.0, 1 / 3, 0.0, 0.0]) && _rf_coords_match(w[:y][1:4], [1 / 6, 0, -1 / 6, 1 / 6])
		e = plot_quiver(x, y, u, v; style = :triangle, edgecolor = :black, edgewidth = 1, opacity = 0.5, color = "red").data[1].fields
		@test _rfv3_d(e[:line])[:width] == 1 && _rfv3_d(e[:line])[:color] in ("black", "#000000")
		@test e[:fillcolor] == "red" && e[:opacity] == 0.5
		# Directions follow atan(v, u) for every pivot and scale.
		px, py = [0.0, 1.0, 2.0], [0.0, 1.0, 0.5]
		pu, pv = [1.0, -2.0, 0.5], [1.0, 0.5, -3.0]
		for style in (:arrow, :triangle), pivot in (:tail, :middle, :tip), scale in (:magnitude, :uniform)
			xs = plot_quiver(px, py, pu, pv; style, pivot, scale, equalar = false).data[1].fields
			stride = style === :arrow ? 7 : 5
			for k in 1:3
				base = (k - 1) * stride
				tail, tip = style === :arrow ? (base + 1, base + 2) : (nothing, base + 2)
				tx = style === :arrow ? xs[:x][tail] : (xs[:x][base + 1] + xs[:x][base + 3]) / 2
				ty = style === :arrow ? xs[:y][tail] : (xs[:y][base + 1] + xs[:y][base + 3]) / 2
				@test atan(xs[:y][tip] - ty, xs[:x][tip] - tx) ≈ atan(pv[k], pu[k]) atol = 1e-12
				anchor = pivot === :tail ? (tx, ty) : pivot === :tip ? (xs[:x][tip], xs[:y][tip]) :
					((tx + xs[:x][tip]) / 2, (ty + xs[:y][tip]) / 2)
				@test anchor[1] ≈ px[k] atol = 1e-12
				@test anchor[2] ≈ py[k] atol = 1e-12
			end
		end
		# Log axes: glyphs are laid out in decades.
		lg = plot_quiver([1.0, 10.0], [0.0, 1.0], [1.0, 1.0], [0.0, 0.0]; xscale = "log", equalar = false).data[1].fields
		@test Float64.(lg[:x][1:2]) ≈ [1.0, exp10(2 / 3)]
		# Validation.
		msg(f) = _rfv3_msg(f)
		@test occursin("plot_quiver: `style` must be :arrow or :triangle", msg(() -> plot_quiver(x, y, u, v; style = :circle)))
		@test occursin("plot_quiver: `pivot` must be :tail, :middle or :tip", msg(() -> plot_quiver(x, y, u, v; pivot = :center)))
		@test occursin("plot_quiver: `scale` must be :magnitude or :uniform", msg(() -> plot_quiver(x, y, u, v; scale = :log)))
		@test occursin("plot_quiver: `headwidth` sets the base of style = :triangle glyphs", msg(() -> plot_quiver(x, y, u, v; headwidth = 0.3)))
		@test occursin("plot_quiver: `headwidth` must be a finite number > 0", msg(() -> plot_quiver(x, y, u, v; style = :triangle, headwidth = 0)))
		@test occursin("plot_quiver: `edgecolor`/`edgewidth` outline style = :triangle glyphs", msg(() -> plot_quiver(x, y, u, v; edgecolor = "black")))
		@test occursin("plot_quiver: `linewidth` is the line width of arrows", msg(() -> plot_quiver(x, y, u, v; style = :triangle, linewidth = 2)))
		@test occursin("plot_quiver: `opacity` must be a number in [0, 1]", msg(() -> plot_quiver(x, y, u, v; opacity = 1.5)))
		@test occursin("plot_quiver!: `pivot` must be", msg(() -> plot_quiver!(plot_heatmap(U), x, y, u, v; pivot = 1)))
	end

	@testset "D13 quiver colorby: binned glyph traces, one legend entry, a colour bar" begin
		x, y, u, v = [0.0, 1.0, 2.0], [0.0, 0.0, 0.0], [1.0, 2.0, 3.0], [0.0, 0.0, 0.0]
		f = plot_quiver(x, y, u, v; colorby = :magnitude, colorscale = "Viridis", legend = "E", colorbar_title = "|E|")
		glyphs = filter(t -> get(t.fields, :legendgroup, "") == "plotlysupply:quiver:E", _rfv3_data(f))
		@test length(glyphs) == 3                              # one non-empty bin per magnitude here
		@test count(t -> t.fields[:showlegend] == true, glyphs) == 1
		@test glyphs[1].fields[:name] == "E" && glyphs[1].fields[:showlegend] == true
		colours = [_rfv3_d(t.fields[:line])[:color] for t in glyphs]
		@test length(unique(colours)) == 3
		carrier = only(filter(t -> haskey(t.fields, :marker), _rfv3_data(f)))
		m = _rfv3_d(carrier.fields[:marker])
		@test m[:cmin] == 1 && m[:cmax] == 3 && m[:showscale] == true
		# The smallest and largest magnitudes take the end colours of the bar
		# (their bins' colours: within one 8-bit step of the ends).
		hexrgb(c) = [parse(Int, c[i:(i + 1)]; base = 16) for i in (2, 4, 6)]
		near(a, b) = maximum(abs.(hexrgb(a) .- hexrgb(b))) <= 1
		@test near(first(colours), m[:colorscale][1][2]) && near(last(colours), m[:colorscale][end][2])
		# G14: the quiver colour bar takes `colorbar_title_side`; a math title
		# becomes the named annotation, as for the other field constructors.
		sidef = plot_quiver(x, y, u, v; colorby = :magnitude, colorbar_title = "s", colorbar_title_side = :right)
		sc = only(t for t in _rfv3_data(sidef) if haskey(_rfv3_d(get(t.fields, :marker, Dict())), :colorbar))
		st = _rfv3_d(_rfv3_d(_rfv3_d(sc.fields[:marker])[:colorbar])[:title])
		@test st[:text] == "s" && st[:side] == "right"
		mathf = plot_quiver(x, y, u, v; colorby = :magnitude, colorbar_title = "\$|E|\$")
		@test "plotlysupply:colorbar_title:x:top" in _rfv3_names(mathf)
		@test occursin("plot_quiver: `colorbar_title_side` must be :top, :right or :bottom",
			_rfv3_msg(() -> plot_quiver(x, y, u, v; colorby = :magnitude, colorbar_title_side = :left)))
		# Triangles colour the fill; an array colours by its own values.
		g = plot_quiver(x, y, u, v; style = :triangle, colorby = [3.0, 2.0, 1.0], colorscale = "Viridis")
		tg = filter(t -> get(t.fields, :fill, "") == "toself", _rfv3_data(g))
		@test length(tg) == 3 && all(t -> haskey(t.fields, :fillcolor), tg)
		# Shared colour axis and explicit limits.
		h = plot_quiver(x, y, u, v; colorby = :magnitude, crange = (0, 6), coloraxis = :shared)
		@test _rfv3_d(_rf_axis(h, :coloraxis))[:cmin] == 0 && _rfv3_d(_rf_axis(h, :coloraxis))[:cmax] == 6
		# Validation: `color` conflicts with colorby; colour keywords need it;
		# the array needs u's shape.
		msg(f) = _rfv3_msg(f)
		@test occursin("plot_quiver: `color` sets one colour for every glyph and conflicts with `colorby`",
			msg(() -> plot_quiver(x, y, u, v; color = :red, colorby = :magnitude)))
		@test occursin("plot_quiver: `colorscale` colours the glyphs by value and needs `colorby`",
			msg(() -> plot_quiver(x, y, u, v; colorscale = "Viridis")))
		two = msg(() -> plot_quiver(x, y, u, v; crange = (0, 1), showscale = true))
		@test occursin("`crange`", two) && occursin("`showscale`", two) && occursin("colour the glyphs by value and need `colorby`", two)
		@test occursin("plot_quiver: a `colorby` array needs one value per vector", msg(() -> plot_quiver(x, y, u, v; colorby = [1.0, 2.0])))
		@test occursin("plot_quiver: `colorby` must be :none or :magnitude", msg(() -> plot_quiver(x, y, u, v; colorby = :speed)))
		# Mutator and SubplotFigure cell (log x): every glyph trace and the
		# carrier land on the cell's axes; a failing call adds nothing.
		p = plot_heatmap(U)
		plot_quiver!(p, x, y, u, v; colorby = :magnitude, style = :triangle, showscale = false)
		@test count(t -> get(t.fields, :fill, "") == "toself", _rfv3_data(p)) == 3
		sf = subplots(1, 2; sync = false)
		relayout!(sf.plot; xaxis2 = attr(type = "log"))
		plot_quiver!(sf, [1.0, 10.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0]; row = 1, col = 2, style = :triangle, colorby = :magnitude)
		@test all(t -> t.fields[:xaxis] == "x2" && t.fields[:yaxis] == "y2", _rfv3_data(sf))
		n = length(_rfv3_data(sf))
		@test occursin("plot_quiver!: `color` sets one colour", _rfv3_msg(() ->
			plot_quiver!(sf, [1.0], [1.0], [1.0], [1.0]; row = 1, col = 2, color = :red, colorby = :magnitude)))
		@test length(_rfv3_data(sf)) == n
		doc = string(Base.Docs.doc(plot_quiver))
		@test all(k -> occursin(k, doc), ("`style", "`pivot", "`scale", "`headwidth", "`colorby", "`edgecolor", "plot_quiver3d"))
	end

	@testset "G67 interpolation keyword (imshow interpolation)" begin
		@test !haskey(plot_heatmap(U).data[1].fields, :zsmooth)
		@test !haskey(plot_heatmap(U; interpolation = :nearest).data[1].fields, :zsmooth)
		@test plot_heatmap(U; interpolation = :bilinear).data[1].fields[:zsmooth] == "best"
		@test plot_image(zeros(UInt8, 2, 2, 3); interpolation = "bilinear").data[1].fields[:zsmooth] == "fast"
		@test !haskey(plot_image(zeros(UInt8, 2, 2, 3)).data[1].fields, :zsmooth)
		p = plot_heatmap(U)
		plot_heatmap!(p, U; interpolation = :bilinear)
		plot_image!(p, zeros(UInt8, 2, 2, 3); interpolation = :bilinear)
		@test p.data[2].fields[:zsmooth] == "best" && p.data[3].fields[:zsmooth] == "fast"
		# plotly.js smooths only a `source` image (image/plot.js `_realImage`), so a
		# bilinear image is an RGBA PNG data URI holding plotly's colours of `z`.
		img = UInt8[10 20 30; 40 50 60;;; 70 80 90; 100 110 120;;; 130 140 150; 160 170 180]
		near = plot_image(img).data[1].fields
		@test haskey(near, :z) && !haskey(near, :source)
		bil = plot_image(img; interpolation = :bilinear).data[1].fields
		@test !haskey(bil, :z) && !haskey(bil, :colormodel) && startswith(bil[:source], "data:image/png;base64,")
		w, h, px = _rf_png_rgba(bil[:source])
		@test (w, h) == (3, 2)
		@test [px[:, c, r] for r in 1:2 for c in 1:3] ==
			[UInt8[img[r, c, 1], img[r, c, 2], img[r, c, 3], 255] for r in 1:2 for c in 1:3]
		# Colour models, clamping, alpha and non-finite channels.
		rgba = Float64[0 300;;; -5 128.4;;; 255 0;;; 0.4 2]
		_, _, px = _rf_png_rgba(plot_image(rgba; interpolation = :bilinear).data[1].fields[:source])
		@test px[:, 1, 1] == UInt8[0, 0, 255, 102] && px[:, 2, 1] == UInt8[255, 128, 0, 255]
		hsl = [[[0, 100, 50], [120, 100, 50], [240, 100, 25]], [[0, 0, 100], [0, NaN, 50], [400, -3, 50]]]
		_, _, px = _rf_png_rgba(plot_image(hsl; colormodel = "hsl", interpolation = :bilinear).data[1].fields[:source])
		@test [px[:, c, r] for r in 1:2 for c in 1:3] == [UInt8[255, 0, 0, 255], UInt8[0, 255, 0, 255], UInt8[0, 0, 128, 255],
			UInt8[255, 255, 255, 255], UInt8[0, 0, 0, 0], UInt8[128, 128, 128, 255]]
		_, _, px = _rf_png_rgba(plot_image(UInt8[1 2;;; 3 4;;; 5 6;;; 7 255]; interpolation = :bilinear).data[1].fields[:source])
		@test px[:, 1, 1] == UInt8[1, 3, 5, 7] && px[:, 2, 1] == UInt8[2, 4, 6, 255]
		# A reversed extent flips the pixels as for `z`; placement is kept.
		fl = plot_image(img; extent = (3, 0, 0, 2), interpolation = :bilinear).data[1].fields
		flz = plot_image(img; extent = (3, 0, 0, 2)).data[1].fields
		_, _, px = _rf_png_rgba(fl[:source])
		@test px[1:3, :, :] == collect(flz[:z]) && px[1:3, 1, 1] != img[1, 1, :]
		@test [fl[k] for k in (:x0, :dx, :y0, :dy)] == [flz[k] for k in (:x0, :dx, :y0, :dy)]
		# Several stored deflate blocks (> 65535 scanline bytes).
		big = [UInt8((7r + 3c + 11k) % 256) for r in 1:120, c in 1:200, k in 1:3]
		w, h, px = _rf_png_rgba(plot_image(big; interpolation = :bilinear).data[1].fields[:source])
		@test (w, h) == (200, 120) && px[1:3, :, :] == permutedims(big, (3, 2, 1)) && all(==(0xff), px[4, :, :])
		for (who, call) in (
			("plot_heatmap", () -> plot_heatmap(U; interpolation = :cubic)),
			("plot_image", () -> plot_image(zeros(UInt8, 2, 2, 3); interpolation = "lanczos")),
			("plot_heatmap!", () -> plot_heatmap!(plot_heatmap(U), U; interpolation = :spline)),
		)
			@test occursin("$(who): `interpolation` must be :nearest or :bilinear", _rfv3_msg(call))
		end
		@test _rf_thrown(() -> plot_heatmap(U; interpolation = 1)) isa Union{ArgumentError, MethodError}
		for f in (plot_heatmap, plot_heatmap!, plot_image, plot_image!)
			@test occursin("interpolation", string(Base.Docs.doc(f)))
		end
	end

	@testset "G30 plot_matrix tick keywords" begin
		M = [Float64(i + j) for i in 1:2, j in 1:3]
		ax = _rf_axis(plot_matrix(M; xticks = [1, 3], xticklabels = ["a", "c"], ytickformat = ".1f", yticks = [1, 2]), :xaxis)
		@test ax[:tickvals] == [1, 3] && ax[:ticktext] == ["a", "c"]
		ay = _rf_axis(plot_matrix(M; ytickformat = ".1f", yticks = [1, 2]), :yaxis)
		@test ay[:tickvals] == [1, 2] && ay[:tickformat] == ".1f"
		# xticklabels alone label the columns, as `xlabels` does.
		al = _rf_axis(plot_matrix(M; xticklabels = ["a", "b", "c"]), :xaxis)
		@test al[:tickvals] == [1, 2, 3] && al[:ticktext] == ["a", "b", "c"]
		@test occursin("plot_matrix: pass either `xlabels` (one label per column) or `xticks`/`xticklabels`, not both",
			_rfv3_msg(() -> plot_matrix(M; xlabels = ["a", "b", "c"], xticks = [1, 2])))
		@test occursin("plot_matrix: `xticklabels`", _rfv3_msg(() -> plot_matrix(M; xticklabels = ["a", "b"])))
		p = plot_heatmap(U)
		plot_matrix!(p, M; yticks = [1, 2], yticklabels = ["r1", "r2"])
		@test _rf_axis(p, :yaxis)[:ticktext] == ["r1", "r2"]
		sf = subplots(1, 2; sync = false)
		plot_matrix!(sf, M; row = 1, col = 2, xticks = [2], xticklabels = ["mid"])
		@test _rf_axis(sf, :xaxis2)[:ticktext] == ["mid"]
		doc = string(Base.Docs.doc(plot_matrix))
		@test all(k -> occursin(k, doc), ("`xticks", "`xticklabels", "`xtickformat", "`yticks"))
	end

	@testset "Y3 SubplotFigure field methods run the Plot path in the cell" begin
		sf = subplots(1, 2; sync = false)
		relayout!(sf.plot; xaxis2 = attr(type = "log"))
		# Implicit coordinates start at 1 on the log cell; positivity is checked
		# against the cell's axis type.
		plot_heatmap!(sf, rand(3, 3); row = 1, col = 2)
		@test collect(_rfv3_data(sf)[end].fields[:x]) == [1, 2, 3]
		plot_contour!(sf, rand(3, 3); row = 1, col = 2)
		@test collect(_rfv3_data(sf)[end].fields[:x]) == [1, 2, 3]
		@test occursin("plot_heatmap!: `x` is on a logarithmic axis", _rfv3_msg(() -> plot_heatmap!(sf, 0:2, 0:2, rand(3, 3); row = 1, col = 2)))
		@test occursin("plot_contour!", _rfv3_msg(() -> plot_contour!(sf, 0:2, 0:2, rand(3, 3); row = 1, col = 2)))
		# Quiver glyphs in decades on the log cell; streamlines integrate there.
		plot_quiver!(sf, [1.0, 10.0], [0.0, 1.0], [1.0, 1.0], [0.0, 0.0]; row = 1, col = 2, equalar = false)
		@test Float64.(_rfv3_data(sf)[end].fields[:x][1:2]) ≈ [1.0, exp10(2 / 3)]
		n = length(_rfv3_data(sf))
		plot_streamlines!(sf, [1.0, 10.0, 100.0, 1000.0], 1:4, ones(4, 4), ones(4, 4); row = 1, col = 2)
		new = _rfv3_data(sf)[n + 1:end]
		@test !isempty(new) && all(t -> t.fields[:xaxis] == "x2", new)
		@test all(t -> all(v -> v === nothing || v > 0, t.fields[:x]), new)
		# The linear cell is unaffected and implicit axes start at 0 there.
		plot_heatmap!(sf, rand(2, 2); row = 1, col = 1)
		@test collect(_rfv3_data(sf)[end].fields[:x]) == [0, 1]
		# show / unknown keywords name the mutator; nothing is added.
		n = length(_rfv3_data(sf))
		@test occursin("plot_streamlines!: mutators do not take `show`", _rfv3_msg(() ->
			plot_streamlines!(sf, 0:3, 0:3, ones(4, 4), ones(4, 4); row = 1, col = 1, show = true)))
		@test occursin("plot_quiver!: unsupported keyword argument(s) `bogus`", _rfv3_msg(() ->
			plot_quiver!(sf, [1.0], [1.0], [1.0], [1.0]; row = 1, col = 1, bogus = 1)))
		@test length(_rfv3_data(sf)) == n
	end

	@testset "Y25 field range and tick keywords take dates on a date axis" begin
		D = _RF_Dates
		days = collect(D.Date(2024, 1, 1):D.Day(1):D.Date(2024, 1, 10))
		Z = [Float64(i + j) for i in 1:10, j in 1:3]
		f = plot_heatmap(days, 1:3, Z; xrange = (D.Date(2024, 1, 3), D.Date(2024, 1, 6)),
			xticks = [D.Date(2024, 1, 3), D.DateTime(2024, 1, 6, 12)], xticklabels = ["a", "b"])
		ax = _rf_axis(f, :xaxis)
		@test collect(ax[:range]) == [D.Date(2024, 1, 3), D.Date(2024, 1, 6)] && ax[:autorange] === false
		# Julia promotes [Date, DateTime] to DateTime values.
		@test ax[:tickvals] == ["2024-01-03T00:00:00", "2024-01-06T12:00:00"] && ax[:ticktext] == ["a", "b"]
		@test _rf_axis(plot_heatmap(days, 1:3, Z; xticks = [D.Date(2024, 1, 4)]), :xaxis)[:tickvals] == ["2024-01-04"]
		g = plot_contour(days, 1:3, Z; xrange = (D.Date(2024, 1, 3), nothing))
		# One-sided date limits: epoch milliseconds in the autorange options.
		@test _rf_limit(g, :xaxis) == (true, 1704240000000, nothing) && !haskey(_rf_axis(g, :xaxis), :range)
		p = plot_heatmap(days, 1:3, Z)
		plot_heatmap!(p, days, 1:3, Z; xrange = (nothing, D.DateTime(2024, 1, 8, 6)), xticks = [D.Date(2024, 1, 5)])
		@test _rf_limit(p, :xaxis) == (true, nothing, 1704240000000 + 5 * 86_400_000 + 6 * 3_600_000)
		@test _rf_axis(p, :xaxis)[:tickvals] == ["2024-01-05"]
		# A date on a numeric axis is an error naming the keyword.
		@test occursin("plot_heatmap: `xrange` bounds on a linear axis must be numbers", _rfv3_msg(() ->
			plot_heatmap(U; xscale = "linear", xrange = (D.Date(2024, 1, 1), nothing))))
		@test occursin("plot_contour", _rfv3_msg(() -> plot_contour(U; xscale = "log", xticks = [D.Date(2024, 1, 1)])))
	end
end

@testset "regression: 2-D fields, wave 5 (fields)" begin
	U5 = [Float64(i + 2j) for i in 0:3, j in 0:2]   # U[ix, iy], 4 x 3
	pad(lo, hi) = PlotlySupply._FIN_OVERLAY_PAD * (hi - lo)

	@testset "Z3 zrange is an alias of crange: only different limits conflict" begin
		for (who, build) in (("plot_heatmap", kw -> plot_heatmap(U5; kw...)), ("plot_contour", kw -> plot_contour(U5; kw...)))
			# The same limits through both keywords (any spelling) are one request.
			for (z, c) in (((0, 10), [0, 10]), ([0.0, 10.0], (0, 10)), ((0, 10), (0, 10)))
				t = build((; zrange = z, crange = c)).data[1]
				@test t.fields[:zmin] == 0 && t.fields[:zmax] == 10
			end
			# A sentinel on either side leaves the other in charge.
			@test build((; zrange = (0, 10), crange = [0, 0])).data[1].fields[:zmax] == 10
			@test build((; zrange = nothing, crange = (1, 5))).data[1].fields[:zmax] == 5
			err = _rfv3_msg(() -> build((; zrange = (0, 1), crange = (0, 2))))
			@test occursin("$(who): `zrange` is an alias of `crange`, and they differ", err)
			@test occursin("zrange = (0, 1), crange = (0, 2)", err)
		end
		# The mutator checks the same.
		f = plot_heatmap(U5)
		@test occursin("plot_heatmap!: `zrange` is an alias of `crange`",
			_rfv3_msg(() -> plot_heatmap!(f, U5; zrange = (0, 1), crange = (0, 3))))
		@test length(f.data) == 1
	end

	@testset "Z25 field constructors show through the shared `_maybe_show`" begin
		# No private show helper is left in the field family; the constructors
		# return through the package's one `_maybe_show` (no window is opened
		# here: `show = false` is the identity).
		@test !isdefined(PlotlySupply, :_field2d_show)
		src = read(joinpath(pkgdir(PlotlySupply), "src", "api.jl"), String)
		@test !occursin("_field2d_show", src)
		f = plot_heatmap(U5)
		@test PlotlySupply._maybe_show(f, false, 0, 0, "") === f
	end

	@testset "Z31 secondary_y on the Plot/SyncPlot field and mesh mutators" begin
		tx, ty, tri = [0.0, 1.0, 0.0, 1.0], [0.0, 0.0, 1.0, 1.0], [1 2 3; 2 4 3]
		calls = (
			("plot_heatmap!", (f; kw...) -> plot_heatmap!(f, 0:3, 0:2, U5; kw...)),
			("plot_contour!", (f; kw...) -> plot_contour!(f, 0:3, 0:2, U5; kw...)),
			("plot_quiver!", (f; kw...) -> plot_quiver!(f, [1.0, 2.0], [1.0, 2.0], [1.0, 0.0], [0.0, 1.0]; kw...)),
			("plot_image!", (f; kw...) -> plot_image!(f, zeros(UInt8, 2, 2, 3); kw...)),
			("plot_streamlines!", (f; kw...) -> plot_streamlines!(f, 0:3, 0:2, ones(4, 3), ones(4, 3); kw...)),
			("plot_polygons!", (f; kw...) -> plot_polygons!(f, [[0.0, 1.0, 1.0]], [[0.0, 0.0, 1.0]]; kw...)),
			("plot_pcolormesh!", (f; kw...) -> plot_pcolormesh!(f, 0:4, 0:3, U5; kw...)),
			("plot_tripcolor!", (f; kw...) -> plot_tripcolor!(f, tx, ty, tri, [1.0, 2.0, 3.0, 4.0]; kw...)),
			("plot_triplot!", (f; kw...) -> plot_triplot!(f, tx, ty, tri; kw...)),
			("plot_tricontour!", (f; kw...) -> plot_tricontour!(f, tx, ty, tri, [1.0, 2.0, 3.0, 4.0]; levels = [2.5], kw...)),
		)
		for (who, call) in calls
			f = plot_scatter(1:3, [10.0, 20.0, 30.0])
			call(f; secondary_y = true, ylabel = "right", yrange = (0, 4))
			new = f.data[2:end]
			@test !isempty(new) && all(t -> get(t.fields, :yaxis, "y") == "y2", new)
			y2 = _rf_axis(f, :yaxis2)
			@test y2[:overlaying] == "y" && y2[:side] == "right"
			@test PlotlySupply._symbol_dict(y2[:title])[:text] == "right"
			@test collect(y2[:range]) == [0, 4] && y2[:autorange] === false
			# The y keywords address the twin only: the primary y axis keeps its
			# scatter state (no range, no title, no aspect lock).
			y = _rf_axis(f, :yaxis)
			@test !haskey(y, :range) && !haskey(y, :scaleanchor) && !haskey(y, :title)
			# A second call reuses the twin.
			call(f; secondary_y = true)
			@test !haskey(_rf_layout(f), :yaxis3)
			@test all(t -> get(t.fields, :yaxis, "y") == "y2", f.data[2:end])
			# `secondary_y` must be a Bool; a failing call leaves the figure as it
			# was (no twin, no traces).
			g = plot_scatter(1:3, 1:3)
			@test occursin("$(who): `secondary_y` must be true or false", _rfv3_msg(() -> call(g; secondary_y = 1)))
			@test occursin("$(who):", _rfv3_msg(() -> call(g; secondary_y = true, yrange = (1, 1))))
			@test length(g.data) == 1 && !haskey(_rf_layout(g), :yaxis2)
		end
		# plot_matrix! draws its rows downwards on the twin.
		f = plot_scatter(1:3, 1:3)
		plot_matrix!(f, U5; secondary_y = true)
		@test f.data[2].fields[:yaxis] == "y2"
		@test get(_rf_axis(f, :yaxis2), :autorange, nothing) == "reversed" ||
			(_rf_axis(f, :yaxis2)[:autorange] === false && issorted(_rf_axis(f, :yaxis2)[:range]; rev = true))
		# The equal aspect locks the twin to x (plot_quiver! default), not the
		# primary y axis.
		q = plot_scatter(1:3, 1:3)
		plot_quiver!(q, [1.0, 2.0], [1.0, 2.0], [1.0, 0.0], [0.0, 1.0]; secondary_y = true)
		@test _rf_axis(q, :yaxis2)[:scaleanchor] == "x" && !haskey(_rf_axis(q, :yaxis), :scaleanchor)
		# The twin overlays the primary axis and shares its domain: plotly.js
		# keeps the aspect by widening the twin's range (render probe p07).
		@test _rf_axis(q, :yaxis2)[:constrain] == "range"
		m = plot_scatter(1:3, 1:3)
		plot_polygons!(m, [[0.0, 1.0, 1.0]], [[0.0, 0.0, 1.0]]; secondary_y = true)
		@test _rf_axis(m, :yaxis2)[:constrain] == "range" && _rf_axis(m, :yaxis2)[:scaleanchor] == "x"
		@test get(_rf_axis(plot_quiver([0.0], [0.0], [1.0], [1.0]), :yaxis), :constrain, "domain") == "domain"
		# A log twin: implicit coordinates start at 1, the twin gets the type,
		# the primary axis does not; positivity is checked against the twin.
		h = plot_scatter(1:3, [-1.0, 0.0, 1.0])
		plot_heatmap!(h, U5; secondary_y = true, yscale = "log")
		@test _rf_axis(h, :yaxis2)[:type] == "log" && !haskey(_rf_axis(h, :yaxis), :type)
		@test collect(h.data[2].fields[:y]) == [1, 2, 3]
		h = plot_scatter(1:3, [-1.0, 0.0, 1.0])
		@test occursin("positive", _rfv3_msg(() -> plot_pcolormesh!(h, 0:4, 0:3, U5; secondary_y = true, yscale = "log")))
		@test length(h.data) == 1 && !haskey(_rf_layout(h), :yaxis2)
		# A one-sided limit on the twin (D11).
		s = plot_scatter(1:3, 1:3)
		plot_contour!(s, 0:3, 0:2, U5; secondary_y = true, yrange = (0.5, nothing))
		@test _rf_limit(s, :yaxis2) == (true, 0.5, nothing)
		# Constructors have no twin.
		@test occursin("unsupported keyword", _rfv3_msg(() -> plot_pcolormesh(0:4, 0:3, U5; secondary_y = true)))
		@test _rf_thrown(() -> plot_heatmap(U5; secondary_y = true)) isa MethodError
	end

	@testset "Z31 the six tick keywords on every field and mesh function" begin
		tx, ty, tri = [0.0, 1.0, 0.0, 1.0], [0.0, 0.0, 1.0, 1.0], [1 2 3; 2 4 3]
		ticks = (; xticks = [0, 1], xticklabels = ["a", "b"], yticks = [0, 1], yticklabels = ["c", "d"],
			xtickformat = "", ytickformat = "")
		fmts = (; xtickformat = ".1f", ytickformat = ".2f")
		for (who, build) in (
			("plot_heatmap", kw -> plot_heatmap(0:3, 0:2, U5; kw...)),
			("plot_contour", kw -> plot_contour(0:3, 0:2, U5; kw...)),
			("plot_quiver", kw -> plot_quiver([0.0, 1.0], [0.0, 1.0], [1.0, 0.0], [0.0, 1.0]; kw...)),
			("plot_image", kw -> plot_image(zeros(UInt8, 2, 2, 3); kw...)),
			("plot_streamlines", kw -> plot_streamlines(0:3, 0:2, ones(4, 3), ones(4, 3); kw...)),
			("plot_polygons", kw -> plot_polygons([[0.0, 1.0, 1.0]], [[0.0, 0.0, 1.0]]; kw...)),
			("plot_pcolormesh", kw -> plot_pcolormesh(0:4, 0:3, U5; kw...)),
			("plot_tripcolor", kw -> plot_tripcolor(tx, ty, tri, [1.0, 2.0, 3.0, 4.0]; kw...)),
			("plot_triplot", kw -> plot_triplot(tx, ty, tri; kw...)),
			("plot_tricontour", kw -> plot_tricontour(tx, ty, tri, [1.0, 2.0, 3.0, 4.0]; levels = [2.5], kw...)),
		)
			f = build(ticks)
			x, y = _rf_axis(f, :xaxis), _rf_axis(f, :yaxis)
			@test x[:tickvals] == [0, 1] && x[:ticktext] == ["a", "b"]
			@test y[:tickvals] == [0, 1] && y[:ticktext] == ["c", "d"]
			g = build(fmts)
			@test _rf_axis(g, :xaxis)[:tickformat] == ".1f" && _rf_axis(g, :yaxis)[:tickformat] == ".2f"
			@test occursin("$(who):", _rfv3_msg(() -> build((; xticks = [0, 1], xticklabels = ["a"]))))
		end
	end

	@testset "Z53 Z54 one-sided limits: one D11 implementation, pinned after the equal aspect" begin
		# The keyword writes what `xrange!` writes, on every axis kind.
		for (build, key, value, axis) in (
			(kw -> plot_heatmap(0:9, 0:4, rand(10, 5); kw...), :xrange, (2, nothing), :xaxis),
			(kw -> plot_heatmap(0:9, 0:4, rand(10, 5); origin = :upper, kw...), :yrange, (1, nothing), :yaxis),
			(kw -> plot_heatmap(1:10, 1:5, rand(10, 5); xscale = "log", kw...), :xrange, (2, nothing), :xaxis),
			(kw -> plot_contour(0:9, 0:4, rand(10, 5); kw...), :yrange, (nothing, 3), :yaxis),
			(kw -> plot_pcolormesh(0:10, 0:5, rand(10, 5); kw...), :xrange, (nothing, 7), :xaxis),
			(kw -> plot_streamlines(0:3, 0:2, ones(4, 3), ones(4, 3); kw...), :xrange, (1, nothing), :xaxis),
		)
			keyword = build(NamedTuple{(key,)}((value,)))
			verb = build((;))
			(axis === :xaxis ? xrange! : yrange!)(verb, value)
			@test _rf_limit(keyword, axis) == _rf_limit(verb, axis)
			@test _rf_limit(keyword, axis)[1] !== :pinned
		end
		# Z54: a one-sided limit on an equal-aspect field is pinned to the bound
		# and the field's edge (`_resolve_linked_limits!` after the aspect), as
		# `xrange!` on the same figure pins it.
		he = plot_heatmap(0:9, 0:4, rand(10, 5); equalar = true, xrange = (2, nothing))
		@test _rf_limit(he, :xaxis) == (:pinned, [2.0, 9.5])
		he2 = plot_heatmap(0:9, 0:4, rand(10, 5); equalar = true)
		xrange!(he2, (2, nothing))
		@test _rf_limit(he2, :xaxis) == (:pinned, [2.0, 9.5])
		# A limit set before the aspect lock is resolved when the lock arrives.
		pre = plot_heatmap(0:9, 0:4, rand(10, 5); yrange = (nothing, 3))
		@test _rf_limit(pre, :yaxis) == (true, nothing, 3)
		plot_heatmap!(pre, 0:9, 0:4, rand(10, 5); equalar = true)
		@test _rf_limit(pre, :yaxis) == (:pinned, [-0.5, 3.0])
		# The mesh path, and a SubplotFigure cell.
		pm = plot_pcolormesh(0:10, 0:5, rand(10, 5); equalar = true, yrange = (1, nothing))
		@test _rf_limit(pm, :yaxis) == (:pinned, [1.0, 5.0])
		sf = subplots(1, 2; sync = false)
		plot_heatmap!(sf, 0:3, 0:2, U5; row = 1, col = 2, xrange = (1, nothing), equalar = true)
		@test _rf_limit(sf, :xaxis2) == (:pinned, [1.0, 3.5])
		# A fixed bound equal to the field edge stays the user's: a later field
		# beyond it does not move it (keyword and `xrange!` alike).
		edge = plot_heatmap(0:3, 0:2, U5; equalar = true)
		plot_heatmap!(edge, 0:3, 0:2, U5; xrange = (-0.5, nothing))
		plot_heatmap!(edge, -6:-3, 0:2, U5)
		@test _rf_limit(edge, :xaxis) == (:pinned, [-0.5, 3.5])
		edge2 = plot_heatmap(0:3, 0:2, U5; equalar = true)
		xrange!(edge2, (-0.5, nothing))
		plot_heatmap!(edge2, -6:-3, 0:2, U5)
		@test _rf_limit(edge2, :xaxis) == (:pinned, [-0.5, 3.5])
		# The open end of a one-sided limit on a field mutator includes the new
		# field (measured now, not from the clip of the previous finalize).
		grow = plot_heatmap(0:3, 0:2, U5; equalar = true)
		plot_heatmap!(grow, 4:7, 0:2, U5; xrange = (1, nothing))
		@test _rf_limit(grow, :xaxis) == (:pinned, [1.0, 7.5])
		# A field with an overlay outside it: the open end carries the pad.
		ov = plot_heatmap(0:3, 0:2, U5; equalar = true)
		plot_scatter!(ov, [6.0], [1.0]; mode = "markers")
		plot_heatmap!(ov, 0:3, 0:2, U5; xrange = (0, nothing))
		@test _rf_limit(ov, :xaxis) == (:pinned, [0.0, 6.0 + pad(-0.5, 6.0)])
	end

	@testset "Z61 every field and mesh mutator applies the style's trace defaults" begin
		bar_keys = (:tickfont, :outlinewidth, :ticks, :ticklen, :tickwidth)
		bar(t) = PlotlySupply._symbol_dict(t.fields[:colorbar])
		carrier_bar(fig) = PlotlySupply._symbol_dict(
			PlotlySupply._symbol_dict(only(t for t in fig.data if haskey(t.fields, :marker) &&
				haskey(PlotlySupply._symbol_dict(t.fields[:marker]), :colorbar)).fields[:marker])[:colorbar])
		with_style(:ieee) do
			ref = bar(plot_heatmap(U5; colorbar_title = "c").data[1])
			@test all(k -> haskey(ref, k), bar_keys)
			for (name, mutate!, read) in (
				("heatmap!", f -> plot_heatmap!(f, U5; colorbar_title = "c"), f -> bar(f.data[end])),
				("contour!", f -> plot_contour!(f, U5), f -> bar(f.data[end])),
				("pcolormesh!", f -> plot_pcolormesh!(f, 0:4, 0:3, U5), f -> bar(f.data[end])),
				("tripcolor!", f -> plot_tripcolor!(f, [0.0, 1, 0], [0.0, 0, 1], [1 2 3], [1.0, 2, 3]; shading = :gouraud), f -> bar(only(t for t in f.data if haskey(t.fields, :colorbar)))),
				("quiver! colorby", f -> plot_quiver!(f, [0.0, 1.0], [0.0, 1.0], [1.0, 2.0], [0.0, 1.0]; colorby = :magnitude), carrier_bar),
				("streamlines! colorby", f -> plot_streamlines!(f, 0:3, 0:3, ones(4, 4), [Float64(x) for x in 0:3, y in 0:3]; colorby = :speed), carrier_bar),
			)
				f = plot_scatter(1:3, 1:3)
				mutate!(f)
				got = read(f)
				@test all(k -> get(got, k, nothing) == ref[k], bar_keys)
			end
			# Contour lines take the style's line width on a mutator too.
			lw = PlotlySupply._symbol_dict(plot_contour(U5; coloring = "lines").data[1].fields[:line])[:width]
			f = plot_scatter(1:3, 1:3)
			plot_contour!(f, U5; coloring = "lines")
			@test PlotlySupply._symbol_dict(f.data[end].fields[:line])[:width] == lw
		end
	end

	@testset "Z63 colour keywords go through the shared colour parser" begin
		grey = PlotlySupply._color_option("0.35"; who = "t", name = "color")
		@test grey == "#595959"
		line(t) = PlotlySupply._symbol_dict(t.fields[:line])
		@test line(plot_quiver([0.0], [0.0], [1.0], [1.0]; color = "0.35").data[1])[:color] == grey
		@test line(plot_quiver([0.0], [0.0], [1.0], [1.0]; color = :red).data[1])[:color] ==
			PlotlySupply._color_option(:red; who = "t", name = "color")
		@test line(plot_quiver([0.0], [0.0], [1.0], [1.0]; style = :triangle, edgecolor = "0.35", edgewidth = 1).data[1])[:color] == grey
		@test line(plot_contour(U5; linecolor = "0.35").data[1])[:color] == grey
		@test line(plot_streamlines(0:3, 0:2, ones(4, 3), ones(4, 3); color = "0.35").data[1])[:color] == grey
		rgba = "rgba(255, 0, 0, 0.5)"
		@test line(plot_quiver([0.0], [0.0], [1.0], [1.0]; color = rgba).data[1])[:color] ==
			PlotlySupply._color_option(rgba; who = "t", name = "color")
		C = PlotlySupply.Colors
		@test line(plot_quiver([0.0], [0.0], [1.0], [1.0]; color = C.RGB(1, 0, 0)).data[1])[:color] == "#FF0000"
		for (who, call) in (
			("plot_quiver", () -> plot_quiver([0.0], [0.0], [1.0], [1.0]; color = "notacolour")),
			("plot_contour", () -> plot_contour(U5; linecolor = "notacolour")),
			("plot_streamlines", () -> plot_streamlines(0:3, 0:2, ones(4, 3), ones(4, 3); color = "notacolour")),
			("plot_quiver!", () -> plot_quiver!(plot_heatmap(U5), [0.0], [0.0], [1.0], [1.0]; style = :triangle, edgecolor = "notacolour", edgewidth = 1)),
		)
			@test occursin("$(who): `", _rfv3_msg(call)) && occursin("invalid colour \"notacolour\"", _rfv3_msg(call))
		end
	end

	@testset "Z42 Date tick values on field and scatter axes" begin
		D = _RF_Dates
		days = collect(D.Date(2024, 1, 1):D.Day(1):D.Date(2024, 1, 5))
		s = plot_scatter(days, 1:5)
		xticks!(s, [D.Date(2024, 1, 3), D.DateTime(2024, 1, 4, 12)])
		@test _rf_axis(s, :xaxis)[:tickvals] == ["2024-01-03T00:00:00", "2024-01-04T12:00:00"]
		@test _rf_axis(plot_scatter(days, 1:5; xticks = [D.Date(2024, 1, 2)]), :xaxis)[:tickvals] == ["2024-01-02"]
		@test _rf_axis(plot_contour(days, 0:2, rand(5, 3); xticks = [D.Date(2024, 1, 2)]), :xaxis)[:tickvals] == ["2024-01-02"]
		h = plot_heatmap(days, 0:2, rand(5, 3))
		plot_heatmap!(h, days, 0:2, rand(5, 3); xticks = [D.DateTime(2024, 1, 2, 6)])
		@test _rf_axis(h, :xaxis)[:tickvals] == ["2024-01-02T06:00:00"]
		@test occursin("needs numeric tick values; got dates",
			_rfv3_msg(() -> plot_heatmap(U5; xscale = "log", xticks = [D.Date(2024, 1, 1)])))
	end
end

@testset "v7 axes-style: field colour fixes (fields-01, fields-04, fields-05)" begin
	PS = PlotlySupply
	g(x, ks...) = (for k in ks; x = PS._cmn_mapping_get(x, k); end; x)
	argmsg(f) = try
		f(); "no error"
	catch err
		err isa ArgumentError ? err.msg : string(typeof(err))
	end

	@testset "fields-01: colorbar!(ticks) on a log colour scale takes data values" begin
		x = collect(1.0:20.0); y = collect(1.0:10.0)
		D = [10.0^(3 * (a - 1) / 19) for a in x, b in y]
		made = plot_heatmap(x, y, D; colornorm = :log, colorbar_ticks = [1, 10, 100])
		f = plot_heatmap(x, y, D; colornorm = :log)
		colorbar!(f; ticks = [1, 10, 100])
		bar = f.data[1].fields[:colorbar]
		@test bar[:tickvals] == [0.0, 1.0, 2.0] == made.data[1].fields[:colorbar][:tickvals]
		@test bar[:ticktext] == ["1", "10", "10<sup>2</sup>"]
		colorbar!(f; ticks = [1, 100], ticklabels = ["low", "high"])
		@test f.data[1].fields[:colorbar][:ticktext] == ["low", "high"]
		@test occursin("must be positive", argmsg(() -> colorbar!(f; ticks = [0, 10])))
		lin = plot_heatmap(x, y, D)
		colorbar!(lin; ticks = [1, 10, 100])
		@test lin.data[1].fields[:colorbar][:tickvals] == [1.0, 10.0, 100.0]
	end

	@testset "fields-04: evenly spaced contour levels colour like uneven ones and heatmap(levels)" begin
		x = collect(range(0, 10; length = 101)); y = collect(range(0, 1; length = 11))
		U = [a for a in x, b in y]
		f = plot_contour(x, y, U; levels = [0, 2.5, 5, 7.5, 10], colorscale = "viridis")
		t = f.data[1]
		@test get(t.fields, :showscale, nothing) === false
		# plotly samples band i of k at t = i/(k+1) of the trace's scale.
		stops = PS._concrete_norm_stops(t.fields[:colorscale], nothing, "test")
		@test PS._sample_colorscale(stops, [1, 2, 3, 4] ./ 5) == ["#472D7B", "#2C728E", "#27AD81", "#AADC32"]
		# The bar is the carrier's: the levels as ticks, no extra end bands.
		@test g(f.data[end].fields[:marker], :colorbar, :tickvals) == [0.0, 2.5, 5.0, 7.5, 10.0]
	end

	@testset "fields-05: streamlines colour keywords" begin
		sx = range(-2, 2; length = 21); sy = range(-1, 1; length = 11)
		U = [-b for a in sx, b in sy]; V = [a for a in sx, b in sy]
		S = hypot.(U, V)
		# Joining a heatmap's colour axis: one bar over the field's full range.
		fig = plot_heatmap(sx, sy, S; colorscale = "viridis", coloraxis = :shared)
		plot_streamlines!(fig, sx, sy, U, V; colorby = :speed, colorscale = "viridis", coloraxis = :shared)
		axis = PS._cmn_layout(fig).fields[:coloraxis]
		@test g(axis, :cmin) ≈ 0 && g(axis, :cmax) ≈ maximum(S)
		@test !PS._finalize_figure!(fig)
		# Panels with a common crange share one bar.
		sf = subplots(1, 2; sync = false)
		plot_streamlines!(sf, sx, sy, U, V; row = 1, col = 1, colorby = :speed, crange = (0, 4.5))
		plot_streamlines!(sf, sx, sy, 2 .* U, 2 .* V; row = 1, col = 2, colorby = :speed, crange = (0, 4.5))
		@test shared_colorbar!(sf) === sf
		# Log norm, levels and showscale.
		lg = plot_streamlines(sx, sy, U, V; colorby = :speed, colornorm = :log, colorbar_ticks = [0.1, 1])
		@test g(lg.data[end].fields[:marker], :colorbar, :ticktext) == ["10<sup>−1</sup>", "1"]
		lv = plot_streamlines(sx, sy, U, V; colorby = :speed, levels = [0, 0.5, 1, 1.5, 2.5])
		@test length(unique(g(t.fields[:line], :color) for t in lv.data if haskey(t.fields, :line))) <= 4
		ns = plot_streamlines(sx, sy, U, V; colorby = :speed, showscale = false)
		@test all(t -> g(get(t.fields, :marker, nothing), :showscale) !== true, ns.data)
		for (kw, name) in (((; crange = (0, 1)), "crange"), ((; colornorm = :log), "colornorm"),
				((; coloraxis = :a), "coloraxis"), ((; levels = [0, 1]), "levels"), ((; showscale = true), "showscale"))
			@test argmsg(() -> plot_streamlines(sx, sy, U, V; kw...)) ==
				"plot_streamlines: `$(name)` applies to colorby = :speed; got colorby = :none."
		end
	end
end

@testset "v8 axes-style: contour level colours and streamlines (numerics-02, numerics-04, numerics-05)" begin
	Z = [Float64(a + b) for a in 0:9, b in 0:9]
	colours(f) = [(l = get(t.fields, :line, nothing); l === nothing ? nothing : get(l isa AbstractDict ? l : l.fields, :color, nothing))
		for t in f.data if get(t.fields, :type, "") == "contour"]
	# numerics-02: evenly spaced levels with a colour norm take their colours
	# on the norm, as uneven ones do.
	f = plot_contour(Z; coloring = "lines", levels = [2, 4, 6, 8], crange = (0, 20))
	@test length(f.data) == 5 && colours(f) == ["#40039D", "#6901A6", "#8F10A1", "#B02A90"]
	f = plot_contour(Z; coloring = "lines", levels = [2, 4, 6, 8], cmid = 7)
	@test colours(f) == ["#0D0887", "#6901A6", "#B02A90", "#E06561"]
	@test length(plot_contour(Z; coloring = "lines", levels = [2, 4, 6, 8]).data) == 1
	function polylines(fig)
		lines = Vector{Vector{NTuple{2, Float64}}}()
		for t in fig.data
			get(t.fields, :mode, "") in ("lines", "lines+markers") || continue
			cur = NTuple{2, Float64}[]
			for (a, b) in zip(t.fields[:x], t.fields[:y])
				if a === nothing
					isempty(cur) || push!(lines, cur); cur = NTuple{2, Float64}[]
				else
					push!(cur, (a, b))
				end
			end
			isempty(cur) || push!(lines, cur)
		end
		return lines
	end
	# numerics-04: on a log axis the field is integrated in decades: a
	# constant (1, 1) field gives y = log10(x) + c.
	x = exp10.(range(0, 2; length = 21)); y = collect(range(0, 1; length = 21))
	fig = plot_streamlines(x, y, ones(21, 21), ones(21, 21); xscale = "log", seeds = [(1.0, 0.0), (10.0, 0.0)], direction = :forward)
	ls = polylines(fig)
	@test length(ls) == 2
	for l in ls
		@test maximum(p -> abs((p[2] - log10(p[1])) - (l[1][2] - log10(l[1][1]))), l) < 1e-9
	end
	# numerics-05: a rigid rotation on non-uniform grids draws circles.
	for g in ([tanh(2s) / tanh(2) for s in range(-1, 1; length = 21)],
		vcat(collect(-1:0.2:-0.2), collect(-0.175:0.025:0.175), collect(0.2:0.2:1)))
		U = [-b for a in g, b in g]; V = [a for a in g, b in g]
		for r in (0.3, 0.6, 0.9)
			l = only(polylines(plot_streamlines(g, g, U, V; seeds = [(r, 0.0)], direction = :forward, maxlength = pi * r)))
			# Measured 3.4e-6 r at most, as on a uniform grid (the integrator's
			# step error); the per-cell index velocity drifted 3 % (0.3 -> 0.3094).
			@test maximum(p -> abs(hypot(p...) - r), l) < 1e-4 * r
		end
	end
end
