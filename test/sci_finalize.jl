using Test, PlotlySupply
using PlotlySupply.PlotlyBase

@testset "sci_finalize" begin

@testset "match-group roots are found through chains; bad references are ignored" begin
	layout = Layout(
		xaxis = attr(matches = "x3"),
		xaxis3 = attr(matches = "x5"),
		xaxis5 = attr(),
		yaxis = attr(),
		yaxis2 = attr(matches = "y"),
		yaxis4 = attr(matches = "z9"),      # not a Cartesian axis reference
		xaxis7 = attr(matches = "x8"),      # root without a layout entry
		xaxis9 = attr(matches = "x10"),
		xaxis10 = attr(matches = "x9"),     # cycle: no root
	)
	@test PlotlySupply._fin_match_roots(layout) == Set([:xaxis5, :yaxis, :xaxis8])
	@test PlotlySupply._fin_axis_key("x") === :xaxis
	@test PlotlySupply._fin_axis_key(:y12) === :yaxis12
	@test PlotlySupply._fin_axis_key("x1") === nothing
	@test PlotlySupply._fin_axis_key("paper") === nothing
	@test PlotlySupply._fin_axis_key(3) === nothing
end

@testset "roots without range/autorange get autorange=true; explicit settings are kept" begin
	layout = Layout(
		xaxis = attr(matches = "x3"),
		xaxis3 = attr(range = [-12, 126], autorange = false),   # fixed root: untouched
		xaxis2 = attr(matches = "x4"),
		xaxis4 = attr(),                                        # free root
		yaxis = attr(),                                         # free root
		yaxis2 = attr(matches = "y"),
		yaxis3 = attr(autorange = "reversed"),                  # explicit: untouched
		yaxis4 = attr(matches = "y3"),
		yaxis5 = attr(title = "free"),                         # not in a group
	)
	updates = PlotlySupply._fin_match_group_updates(layout)
	@test updates == Dict{Symbol, Any}(:xaxis4_autorange => true, :yaxis_autorange => true)

	p = Plot(GenericTrace[], layout)
	@test PlotlySupply._finalize_figure!(p) === nothing
	f(key, name) = PlotlySupply._fin_field(p.layout.fields[key], name)
	@test f(:xaxis4, :autorange) === true
	@test f(:yaxis, :autorange) === true
	@test f(:xaxis3, :autorange) === false
	@test f(:xaxis3, :range) == [-12, 126]
	@test f(:yaxis3, :autorange) == "reversed"
	@test f(:yaxis5, :autorange) === nothing
	@test f(:xaxis, :autorange) === nothing                     # members are left alone
	# idempotent: nothing left to write
	@test isempty(PlotlySupply._fin_match_group_updates(p.layout))
end

@testset "a figure without shared axes is not touched" begin
	p = plot_scatter(1:3, [1, 2, 3])
	before = deepcopy(p.layout.fields)
	PlotlySupply._finalize_figure!(p)
	@test p.layout.fields == before
end

@testset "subplots: every shared-axis group root autoranges explicitly" begin
	sf = subplots(2, 2; sync = false, shared_xaxes = true, shared_yaxes = true)
	fields = sf.plot.layout.fields
	roots = PlotlySupply._fin_match_roots(sf.plot.layout)
	@test !isempty(roots)
	for root in roots
		@test PlotlySupply._fin_field(fields[root], :autorange) === true
	end
	# A range set on one group's root must not remove the others' autorange.
	plot_scatter!(sf, 1:3, [1, 2, 3]; row = 2, col = 1, xrange = (0, 5))
	fields = sf.plot.layout.fields          # the mutation commits a new layout
	fixed = [k for k in roots if PlotlySupply._fin_has_range(fields[k])]
	@test length(fixed) == 1
	for root in setdiff(roots, fixed)
		@test PlotlySupply._fin_field(fields[root], :autorange) === true
	end
	# Unshared grids get no autorange entries.
	plain = subplots(2, 2; sync = false)
	@test all(PlotlySupply._fin_field(axis, :autorange) === nothing
		for (key, axis) in plain.plot.layout.fields if PlotlySupply._fin_is_axis_key(key))
end

end
