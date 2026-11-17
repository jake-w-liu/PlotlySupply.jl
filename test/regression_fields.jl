using Test, PlotlySupply
using PlotlySupply: PlotlyBase

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
		# nodes; the mutators draw on plot_heatmap(U), streamlines reach y = 3).
		# `pinned`: an equal-aspect group, which finalize pins to its clip.
		hm = ((-0.5, 3.5), (-0.5, 2.5))
		sticky = Dict(
			"plot_heatmap" => (hm, false),
			"plot_contour" => (((0.0, 3.0), (0.0, 2.0)), false),
			"plot_heatmap!" => (hm, false),
			"plot_contour!" => (hm, false),
			"plot_quiver!" => (hm, true),
			"plot_streamlines!" => ((hm[1], (-0.5, 3.0)), false),
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
				else
					# No field on the axis (quiver, streamlines), or an image, whose
					# 3-D z finalize does not measure yet (cross-request): plotly's
					# own autorange, nothing pinned.
					@test _rf_clip(fig, axis) === nothing
					@test !haskey(ax, :range) && get(ax, :autorange, true) !== false
				end
			end
		end
		# No user range was recorded: a later trace widens the automatic axis,
		# while an explicit range stays put.
		f = plot_heatmap(U; xrange = nothing)
		plot_scatter!(f, [10.0], [1.0]; mode = "markers")
		@test _rf_clip(f, :xaxis) == (-0.5, 10.0) && !haskey(_rf_axis(f, :xaxis), :range)
		g = plot_heatmap(U; xrange = (1, 3))
		plot_scatter!(g, [10.0], [1.0]; mode = "markers")
		@test collect(_rf_axis(g, :xaxis)[:range]) == [1, 3] && _rf_clip(g, :xaxis) === nothing
		q = plot_heatmap(U)
		plot_quiver!(q, [1.0], [1.0], [1.0], [1.0]; xrange = [0, 0])
		plot_scatter!(q, [10.0], [1.0]; mode = "markers")
		@test _rf_clip(q, :xaxis) == (-0.5, 10.0) && collect(_rf_axis(q, :xaxis)[:range]) == [-0.5, 10.0]
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
			# D11: a one-sided limit fixes that edge and autoranges the other
			# (`autorangeoptions.minallowed`/`maxallowed`, which `savefig` keeps).
			# On an aspect-constrained axis (equal aspect, an image's axes) it is
			# pinned to the bound and the data's other edge, as matplotlib does.
			# An image's y axis (reversed by default, also when plot_image! adds
			# one) keeps its direction.
			reversed = who in ("plot_image", "plot_image!") && key === :yrange
			fig = build(NamedTuple{(key,)}(((1, nothing),)))
			aspect = haskey(_rf_axis(fig, :yaxis), :scaleanchor) || who in ("plot_image", "plot_image!")
			lim = _rf_limit(fig, axis)
			@test (lim[1] === :pinned) == aspect
			if aspect
				@test minimum(lim[2]) == 1 && (lim[2][1] > lim[2][2]) == reversed
			else
				@test lim == (reversed ? "reversed" : true, 1, nothing) && !haskey(_rf_axis(fig, axis), :range)
			end
			@test _rf_clip(fig, axis) === nothing
			lim = _rf_limit(build(NamedTuple{(key,)}(([nothing, 2],))), axis)
			if aspect
				@test lim[1] === :pinned && maximum(lim[2]) == 2 && (lim[2][1] > lim[2][2]) == reversed
			else
				@test lim == (reversed ? "reversed" : true, nothing, 2)
			end
			# Invalid limits name the function and the keyword.
			@test occursin("$(who): `$(key)` bounds must be numbers (or date/category values); `missing` is not a bound",
				msg(build, key, (missing, 2)))
			equal = msg(build, key, [2, 2])
			@test startswith(equal, "ArgumentError: $(who):") && occursin("`$(key)`", equal) && occursin("must differ", equal)
			@test occursin("$(who): `$(key)` bounds must be numbers", msg(build, key, (true, false)))
			@test occursin("$(who): `$(key)` bounds must be numbers", msg(build, key, Any[false, 1]))
			@test occursin("$(who): `$(key)` bounds must be finite", msg(build, key, (Inf, nothing)))
			@test occursin("$(who): the bound of a one-sided `$(key)` must be a number", msg(build, key, (nothing, [1, 2])))
			@test occursin("$(who): the bound of a one-sided `$(key)` must be a number", msg(build, key, ("a", nothing)))
		end
		@test collect(_rf_axis(plot_image(zeros(UInt8, 2, 2, 3); origin = :lower, yrange = (1, 3)), :yaxis)[:range]) == [1, 3]
		# Pinned on an image: the fixed bound and the image's pixel edge.
		@test _rf_limit(plot_image(zeros(UInt8, 2, 2, 3); origin = :lower, yrange = (nothing, 1)), :yaxis) == (:pinned, [-0.5, 1.0])
		@test _rf_limit(plot_image(zeros(UInt8, 2, 2, 3); yrange = (1, nothing)), :yaxis) == (:pinned, [1.5, 1.0])
		@test _rf_limit(plot_image(zeros(UInt8, 2, 3, 3); xrange = (nothing, 1)), :xaxis) == (:pinned, [-0.5, 1.0])
		# ... also for a bilinear image, sized from its PNG header.
		@test _rf_limit(plot_image(zeros(UInt8, 2, 3, 3); interpolation = :bilinear, xrange = (1, nothing)), :xaxis) == (:pinned, [1.0, 2.5])
		# ... and on an equal-aspect quiver: the glyphs' extent (tails at x = 0).
		@test _rf_limit(plot_quiver([0.0, 1, 2, 3], [0.0, 1, 0, 1], ones(4), [1.0, 0, -1, 0]; xrange = (nothing, 2.5)), :xaxis) == (:pinned, [0.0, 2.5])
		# An explicitly reversed axis keeps its direction under a one-sided limit.
		h = plot_heatmap(U; origin = :upper, yrange = (0.5, nothing))
		@test _rf_limit(h, :yaxis) == ("reversed", 0.5, nothing) && !haskey(_rf_axis(h, :yaxis), :range)
		h = plot_heatmap(U; origin = :upper, yrange = (nothing, 1.5))
		@test _rf_limit(h, :yaxis) == ("reversed", nothing, 1.5)
		# A one-sided limit on an axis finalize had clipped drops that clip (the
		# open side would otherwise stay clipped to the old extent); other user
		# `autorangeoptions` are kept; a new one-sided limit replaces the old.
		f = plot_heatmap(U)
		@test _rf_clip(f, :xaxis) == (-0.5, 3.5)
		plot_heatmap!(f, U; xrange = (nothing, 3))
		@test _rf_limit(f, :xaxis) == (true, nothing, 3) && _rf_clip(f, :xaxis) === nothing
		@test _rfv3_d(_rf_axis(f, :xaxis)[:autorangeoptions]) == Dict(:maxallowed => 3)
		plot_heatmap!(f, U; xrange = (1, nothing))
		@test _rf_limit(f, :xaxis) == (true, 1, nothing)
		# A user-edited `autorangeoptions` is the user's (finalize no longer
		# updates it): its entries are kept; an earlier opposite limit is dropped.
		k = plot_heatmap(U)
		relayout!(k; xaxis_autorangeoptions_include = -5, xaxis_autorangeoptions_minallowed = -1)
		plot_heatmap!(k, U; xrange = (nothing, 3))
		ko = _rfv3_d(_rf_axis(k, :xaxis)[:autorangeoptions])
		@test ko[:include] == -5 && ko[:maxallowed] == 3 && !haskey(ko, :minallowed)
		@test ko[:clipmin] == -0.5 && ko[:clipmax] == 3.5
		# A date bound is written in epoch milliseconds (plotly.js ignores a date
		# string in the autorange options).
		Dt = Base.require(Base.PkgId(Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), "Dates"))
		d = plot_heatmap(collect(Dt.Date(2024, 1, 1):Dt.Day(1):Dt.Date(2024, 1, 4)), 0:2, U; xrange = (Dt.Date(2024, 1, 3), nothing))
		@test _rf_limit(d, :xaxis) == (true, 1704240000000, nothing)
		# A failing mutator leaves the figure unchanged.
		f = plot_heatmap(U)
		@test _rf_thrown(() -> plot_heatmap!(f, U; xrange = [1, 1])) isa ArgumentError
		@test _rf_thrown(() -> plot_heatmap!(f, U; xrange = (missing, 1))) isa ArgumentError
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
		# limit (pinned: an image's axes are aspect-constrained), as on a Plot.
		sfi = subplots(1, 2; sync = false)
		plot_image!(sfi, zeros(UInt8, 2, 2, 3); row = 1, col = 2, yrange = (nothing, 1))
		@test _rf_limit(sfi, :yaxis2) == (:pinned, [1.0, -0.5])
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
		@test all(t -> !haskey(t.fields, :meta), plot_quiver([0.0], [0.0], [1.0], [1.0]).data)
		@test all(t -> !haskey(t.fields, :meta), plot_streamlines(0:3, 0:3, ones(4, 4), ones(4, 4)).data)
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
		# trace widens; a root without a field keeps plotly's autorange.
		for (name, mutate!, extent, pinned) in (
			("heatmap!", p -> plot_heatmap!(p, U), (-0.5, 3.5), false),
			("contour!", p -> plot_contour!(p, U), (0.0, 3.0), false),
			("matrix!", p -> plot_matrix!(p, U), (0.5, 3.5), true),
			("quiver!", p -> plot_quiver!(p, [0.0], [0.0], [1.0], [1.0]), nothing, false),
			("image!", p -> plot_image!(p, zeros(UInt8, 2, 2, 3)), nothing, false),
			("streamlines!", p -> plot_streamlines!(p, 0:3, 0:3, ones(4, 4), ones(4, 4)), nothing, false),
		)
			p = Plot(GenericTrace[], Layout(xaxis2 = attr(matches = "x", anchor = "y2"), yaxis2 = attr(anchor = "x2")))
			mutate!(p)
			ax = _rf_axis(p, :xaxis)
			if extent === nothing
				@test _rf_clip(p, :xaxis) === nothing
				@test !haskey(ax, :range) && get(ax, :autorange, true) === true
				continue
			end
			@test _rf_clip(p, :xaxis) == extent
			if pinned
				@test ax[:autorange] === false && Tuple(Float64.(ax[:range])) == extent
			else
				@test ax[:autorange] === true && !haskey(ax, :range)
			end
			plot_scatter!(p, [extent[2] + 10.0], [0.5]; mode = "markers")
			widened = (extent[1], extent[2] + 10.0)
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
		z = pm.fields[:z]
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
		@test _rf_axis(m, :yaxis)[:autorange] == "reversed"
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
		@test kb[:ticktext] == ["10<sup>0</sup>", "3", "30", "10<sup>3</sup>"]
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
