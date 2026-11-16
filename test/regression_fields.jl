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
