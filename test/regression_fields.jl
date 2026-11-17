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

	@testset "X23 range keywords: sentinels and validation" begin
		builds = (
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
		for (who, build) in builds, (key, axis) in ((:xrange, :xaxis), (:yrange, :yaxis))
			for sentinel in ([0, 0], (0, 0), nothing, [nothing, nothing], (nothing, nothing))
				fig = build(NamedTuple{(key,)}((sentinel,)))
				@test !haskey(_rf_axis(fig, axis), :range)
			end
			# plot_image (origin = :upper) reorders an explicit y range so the
			# image stays upright; every other range is written as given.
			flipped = who == "plot_image" && key === :yrange
			for given in ((1, 3), [1, 3], [1.0, 3.0])
				ax = _rf_axis(build(NamedTuple{(key,)}((given,))), axis)
				@test collect(ax[:range]) == (flipped ? [3, 1] : [1, 3]) && ax[:autorange] === false
			end
			@test occursin("$(who): `$(key)` cannot be partial", _rfv3_msg(() -> build(NamedTuple{(key,)}(([nothing, 2],)))))
			@test occursin("$(who): `$(key)` cannot be partial", _rfv3_msg(() -> build(NamedTuple{(key,)}(((missing, 2),)))))
			@test occursin("$(who): the `$(key)` bounds must differ", _rfv3_msg(() -> build(NamedTuple{(key,)}(([2, 2],)))))
			@test occursin("$(who): `$(key)` bounds must be numbers", _rfv3_msg(() -> build(NamedTuple{(key,)}(((true, false),)))))
			@test occursin("$(who): `$(key)` bounds must be numbers", _rfv3_msg(() -> build(NamedTuple{(key,)}((Any[false, 1],)))))
		end
		@test collect(_rf_axis(plot_image(zeros(UInt8, 2, 2, 3); origin = :lower, yrange = (1, 3)), :yaxis)[:range]) == [1, 3]
		# A failing mutator leaves the figure unchanged.
		f = plot_heatmap(U)
		@test _rf_thrown(() -> plot_heatmap!(f, U; xrange = [1, 1])) isa ArgumentError
		@test length(f.data) == 1
	end

	@testset "X23 ranges are data units on log axes, also in subplot cells" begin
		f = plot_heatmap([1.0, 10.0, 100.0], [1.0, 2.0], rand(3, 2); xscale = "log", xrange = (1, 1000))
		@test _rf_axis(f, :xaxis)[:range] == [0.0, 3.0] && _rf_axis(f, :xaxis)[:autorange] === false
		@test occursin("plot_heatmap: `xrange` bounds on a logarithmic axis are data values and must be positive", _rfv3_msg(() ->
			plot_heatmap([1.0, 10.0], [1.0, 2.0], rand(2, 2); xscale = "log", xrange = (0, 10))))
		sf = subplots(1, 2; sync = false)
		plot_heatmap!(sf, [1.0, 10.0, 100.0], [1.0, 2.0], rand(3, 2); row = 1, col = 2, xscale = "log")
		plot_quiver!(sf, [2.0], [1.5], [1.0], [0.0]; row = 1, col = 2, xrange = (1, 1000), equalar = false)
		@test _rf_axis(sf, :xaxis2)[:range] == [0.0, 3.0] && _rf_axis(sf, :xaxis2)[:autorange] === false
		n = length(_rfv3_data(sf))
		@test occursin("plot_heatmap!", _rfv3_msg(() -> plot_heatmap!(sf, rand(2, 2); row = 1, col = 2, xrange = (0, 10))))
		@test occursin("plot_contour!: `yrange` cannot be partial", _rfv3_msg(() ->
			plot_contour!(sf, rand(2, 2); row = 1, col = 1, yrange = [nothing, 1])))
		@test length(_rfv3_data(sf)) == n
		@test occursin("plot_matrix!: unsupported keyword argument(s) `xrange`", _rfv3_msg(() ->
			plot_matrix!(sf, rand(2, 2); xrange = (0, 1))))
		# Shared x: plotly.js reads a matched axis's range from the group root
		# only, so a cell range is written there (row 1 matches row 2 here).
		shared = subplots(2, 1; sync = false, shared_xaxes = true)
		@test PlotlySupply._symbol_dict(_rf_axis(shared, :xaxis))[:matches] == "x2"
		plot_heatmap!(shared, U; row = 1, col = 1, xrange = (0, 5))
		@test collect(_rf_axis(shared, :xaxis2)[:range]) == [0, 5]
		@test !haskey(_rf_axis(shared, :xaxis), :range)
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

	@testset "D10 field constructors and mutators finalize the figure" begin
		# `_finalize_figure!` states autorange = true on every `matches` root
		# without a range; a mutator on a Plot runs it.
		for mutate! in (
			p -> plot_heatmap!(p, U),
			p -> plot_contour!(p, U),
			p -> plot_quiver!(p, [0.0], [0.0], [1.0], [1.0]),
			p -> plot_image!(p, zeros(UInt8, 2, 2, 3)),
			p -> plot_matrix!(p, U),
			p -> plot_streamlines!(p, 0:3, 0:3, ones(4, 4), ones(4, 4)),
		)
			p = Plot(GenericTrace[], Layout(xaxis2 = attr(matches = "x", anchor = "y2"), yaxis2 = attr(anchor = "x2")))
			mutate!(p)
			@test _rf_axis(p, :xaxis)[:autorange] === true
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
