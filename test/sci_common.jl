using Test, PlotlySupply

# `_label` (mathtext.jl) is implemented in parallel; until it is merged an
# identity shim keeps these tests self-contained. The guard makes it inert once
# the real definition exists.
isdefined(PlotlySupply, :_label) ||
    @eval PlotlySupply _label(s::AbstractString; align::Symbol=:c) = String(s)

const _CMN = PlotlySupply
const _CMN_PB = PlotlySupply.PlotlyBase

function _cmn_throws(f, needle::AbstractString)
    err = try
        f()
        nothing
    catch caught
        caught
    end
    err isa ArgumentError || return false
    return occursin(needle, err.msg)
end

_cmn_json(x) = _CMN_PB.JSON.json(x)

# Fake renderer backend (same shape as test/renderer_transactions.jl) so a
# SyncPlot can run real renderer transactions without Electron.
mutable struct _CmnRendererState
    open::Bool
    scripts::Vector{String}
end

function _cmn_syncplot(p)
    state = _CmnRendererState(true, String[])
    backend = (
        isopen = window -> state.open,
        close = window -> (state.open = false; nothing),
        run = (window, script) -> (push!(state.scripts, String(script)); "ok"),
    )
    sp = SyncPlot(
        p,
        nothing,
        :sci_common_window,
        "sci-common-div",
        PlotlySupply._SyncPlotResources(nothing, backend),
    )
    return sp, state
end

_cmn_axis(p, key) = p.layout.fields[key]
_cmn_get(m, key) = PlotlySupply._cmn_mapping_get(m, key)

# A private mutator in the style of a registered `verb!(fig, ...)`: it only
# uses the common.jl primitives, so running it through the transactional
# helpers proves they work on staged targets.
function _cmn_test_mutator!(fig, values; fail::Bool = false)
    t = _CMN._cell_target(fig; who = "test_mutator!")
    _CMN._apply_ticks!(fig, t.xkey; values = values, labels = string.(values), who = "test_mutator!")
    _CMN._apply_equal_aspect!(fig, t; ratio = 2)
    _CMN._upsert_named!(fig, :annotations, "plotlysupply:test:0:0", [attr(text = "A", x = 0, y = 0, xref = "paper", yref = "paper")])
    _CMN._ensure_twin_y!(fig)
    fail && throw(ArgumentError("test_mutator!: injected failure after writes"))
    _CMN._refresh!(fig)
    return nothing
end

function _cmn_test_subplot_impl!(sf, values; row = nothing, col = nothing, fail::Bool = false)
    t = _CMN._cell_target(sf; row = row, col = col, who = "test_subplot!")
    _CMN._apply_ticks!(sf, t.xkey; values = values, who = "test_subplot!")
    _CMN._apply_equal_aspect!(sf, t)
    _CMN._upsert_named!(sf, :shapes, "plotlysupply:test:$(t.row):$(t.col)", [attr(type = "line", x0 = 0, x1 = 1, y0 = 0, y1 = 1, xref = t.xref, yref = t.yref)])
    sf.current_row = t.row
    sf.current_col = t.col
    fail && throw(ArgumentError("test_subplot!: injected failure after writes"))
    _CMN._refresh!(sf.fig)
    return sf
end

# Registers an inset (what `inset!` in axes.jl will do) on a staged figure.
function _cmn_add_inset_impl!(sf, row, col; fail::Bool = false)
    host = _CMN._cell_target(sf; row = row, col = col)
    n = length(sf.insets) + 1
    p = sf.plot
    xi = maximum(something(_CMN._cmn_axis_index(k, 'x'), 0) for k in keys(p.layout.fields)) + 1
    yi = maximum(something(_CMN._cmn_axis_index(k, 'y'), 0) for k in keys(p.layout.fields)) + 1
    xkey, ykey = Symbol("xaxis$(xi)"), Symbol("yaxis$(yi)")
    xd = (host.xdomain[1] + 0.6 * (host.xdomain[2] - host.xdomain[1]), host.xdomain[2])
    yd = (host.ydomain[1] + 0.6 * (host.ydomain[2] - host.ydomain[1]), host.ydomain[2])
    relayout!(sf.fig; (xkey => attr(domain = collect(xd), anchor = "y$(yi)"),)...)
    relayout!(sf.fig; (ykey => attr(domain = collect(yd), anchor = "x$(xi)"),)...)
    push!(sf.insets, _CMN._SubplotInset(host.row, host.col, xkey, ykey, "x$(xi)", "y$(yi)", xd, yd))
    fail && throw(ArgumentError("add_inset: injected failure"))
    return n
end

@testset "sci common.jl" begin
    @testset "SubplotFigure propertynames lists :plot once (finding 5/284)" begin
        sf = subplots(1, 2; sync = false)
        @test hasproperty(sf, :plot)
        @test count(==(:plot), propertynames(sf)) == 1
        @test :insets in propertynames(sf)
        @test !(:_lock in propertynames(sf))
        @test :_lock in propertynames(sf, true)
        @test sf.plot === sf.fig
        @test _CMN._plot_obj(sf) === sf.fig
        # Before the fix both helpers threw "Expected a PlotlyBase.Plot ..."
        # on a headless figure and set_template! had already mutated it.
        plot_scatter!(sf, 1:3, [1, 2, 3])
        set_template!(sf, "ggplot2")
        @test sf.plot.layout.fields[:template] == PlotlySupply._resolve_template(:ggplot2)
        annotate!(sf, 2, 2, "hi")
        @test count(a -> _cmn_get(a, :text) == "hi", sf.plot.layout.fields[:annotations]) == 1

        sp, _ = _cmn_syncplot(Plot(GenericTrace[], Layout(Subplots(rows = 1, cols = 2))))
        sf_sync = SubplotFigure(sp, 1, 2, 1, 1, true, :topright, (0.02, 0.03), "white", "black", 1.0)
        @test count(==(:plot), propertynames(sf_sync)) == 1
        @test hasproperty(sf_sync, :plot)
        @test sf_sync.insets == _CMN._SubplotInset[]
        close(sp)
    end

    @testset "_cell_target on a plain figure" begin
        p = Plot(GenericTrace[], Layout())
        t = _CMN._cell_target(p)
        @test t isa _CMN._CellTarget
        @test (t.kind, t.row, t.col, t.xkey, t.ykey, t.xref, t.yref, t.scenekey) ==
              (:xy, 0, 0, :xaxis, :yaxis, "x", "y", :none)
        @test (t.xdomain, t.ydomain) == ((0.0, 1.0), (0.0, 1.0))

        fig = plot_scatter([1.0, 2.0], [3.0, 4.0])
        relayout!(fig; xaxis_domain = [0.1, 0.9], yaxis_domain = [0.2, 0.8])
        t = _CMN._cell_target(fig)
        @test (t.xdomain, t.ydomain) == ((0.1, 0.9), (0.2, 0.8))
        @test _cmn_throws(() -> _CMN._cell_target(fig; row = 1, col = 1, who = "xticks!"), "xticks!: `row`/`col`")
        @test _cmn_throws(() -> _CMN._cell_target(fig; row = 1), "SubplotFigure cell")
        @test _cmn_throws(() -> _CMN._cell_target(fig; inset = 1), "`inset` needs a SubplotFigure")
        @test _cmn_throws(() -> _CMN._cell_target(fig; secondary_y = true), "no secondary y-axis")
        @test _cmn_throws(() -> _CMN._cell_target(fig; row = 1.0, col = 1), "`row` must be an integer")

        s3 = Plot(scatter3d(x = [1, 2], y = [1, 2], z = [1, 2]), Layout(xaxis = attr(title_text = "x")))
        t3 = _CMN._cell_target(s3)
        @test (t3.kind, t3.scenekey, t3.xkey, t3.xref) == (:scene, :scene, :none, "")
        @test _cmn_throws(() -> _CMN._cell_target(s3; secondary_y = true), "needs Cartesian")
        empty_scene = Plot(GenericTrace[], Layout(scene = attr(domain = attr(x = [0.0, 0.5], y = [0.0, 1.0]))))
        ts = _CMN._cell_target(empty_scene)
        @test (ts.kind, ts.scenekey, ts.xdomain) == (:scene, :scene, (0.0, 0.5))
        pol = plot_scatterpolar([0.0, 90.0], [1.0, 2.0])
        @test _CMN._cell_target(pol).kind == :polar
        pie_fig = Plot(pie(values = [1, 2], labels = ["a", "b"], domain = attr(x = [0.2, 0.6], y = [0.1, 0.9])))
        tp = _CMN._cell_target(pie_fig)
        @test (tp.kind, tp.xdomain, tp.ydomain) == (:domain, (0.2, 0.6), (0.1, 0.9))

        sp, _ = _cmn_syncplot(plot_scatter([1.0, 2.0], [3.0, 4.0]))
        @test _CMN._cell_target(sp).xref == "x"
        @test _CMN._cell_target(_CMN._HighLevelStagedPlotMutation(sp.plot)).yref == "y"
        close(sp)
    end

    @testset "_cell_target on SubplotFigure cells" begin
        sf = subplots(2, 2; sync = false)
        t = _CMN._cell_target(sf; row = 2, col = 1)
        @test (t.kind, t.row, t.col, t.xkey, t.ykey, t.xref, t.yref) == (:xy, 2, 1, :xaxis3, :yaxis3, "x3", "y3")
        layout = sf.plot.layout
        @test t.xdomain == Tuple(Float64.(layout.fields[:xaxis3][:domain]))
        @test t.ydomain == Tuple(Float64.(layout.fields[:yaxis3][:domain]))
        subplot!(sf, 1, 2)
        @test _CMN._cell_target(sf).xref == "x2"
        @test _cmn_throws(() -> _CMN._cell_target(sf; row = 1, who = "grid!"), "grid!: `row` and `col` must be given together")
        @test _cmn_throws(() -> _CMN._cell_target(sf; row = 3, col = 1), "`row` must be in 1:2")
        @test _cmn_throws(() -> _CMN._cell_target(sf; row = 1, col = 0), "`col` must be in 1:2")
        @test _cmn_throws(() -> _CMN._cell_target(sf; secondary_y = true), "has no secondary y-axis")
        @test _cmn_throws(() -> _CMN._cell_target(sf; inset = 1), "this figure has no insets")

        mixed = subplots(2, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "polar"); Spec(kind = "scene") Spec(kind = "domain")])
        tsc = _CMN._cell_target(mixed; row = 2, col = 1)
        @test (tsc.kind, tsc.scenekey, tsc.xkey, tsc.xref) == (:scene, :scene2, :none, "")
        scene2 = mixed.plot.layout.fields[:scene2]
        @test tsc.xdomain == Tuple(Float64.(scene2[:domain][:x]))
        @test _CMN._cell_target(mixed; row = 1, col = 2).kind == :polar
        td = _CMN._cell_target(mixed; row = 2, col = 2)
        @test td.kind == :domain
        @test td.xdomain[1] > 0.5

        twin = subplots(1, 2; sync = false, specs = [Spec(secondary_y = true) Spec()])
        tt = _CMN._cell_target(twin; row = 1, col = 1, secondary_y = true)
        @test (tt.ykey, tt.yref, tt.xref) == (:yaxis2, "y2", "x")
        # The overlaying axis has no domain of its own: it shares the host's.
        @test tt.ydomain == _CMN._cell_target(twin; row = 1, col = 1).ydomain
        @test _CMN._cell_target(twin; row = 1, col = 2).xref == "x2"

        holes = subplots(1, 2; sync = false, specs = [Spec() missing])
        @test _cmn_throws(() -> _CMN._cell_target(holes; row = 1, col = 2), "cell (1, 2) is empty")

        maps = subplots(1, 1; sync = false, specs = fill(Spec(kind = "map"), 1, 1))
        @test _CMN._cell_target(maps).kind == :map
    end

    @testset "SubplotFigure insets metadata stages and commits" begin
        sf = subplots(1, 2; sync = false)
        @test sf.insets == _CMN._SubplotInset[]
        # A failed mutation must not publish its staged inset list.
        @test_throws ArgumentError _CMN._transactional_subplot_mutation!(
            _cmn_add_inset_impl!, sf, _CMN._SUBPLOT_INSET_METADATA_FIELDS, 1, 2; fail = true)
        @test isempty(sf.insets)
        @test !haskey(sf.plot.layout.fields, :xaxis3)
        k = _CMN._transactional_subplot_mutation!(
            _cmn_add_inset_impl!, sf, _CMN._SUBPLOT_INSET_METADATA_FIELDS, 1, 2)
        @test k == 1
        @test length(sf.insets) == 1
        rec = only(sf.insets)
        @test (rec.row, rec.col, rec.xkey, rec.ykey, rec.xref, rec.yref) == (1, 2, :xaxis3, :yaxis3, "x3", "y3")
        t = _CMN._cell_target(sf; inset = 1)
        @test (t.kind, t.row, t.col, t.xkey, t.ykey, t.xref, t.yref) == (:xy, 1, 2, :xaxis3, :yaxis3, "x3", "y3")
        @test t.xdomain == rec.xdomain && t.ydomain == rec.ydomain
        @test _CMN._cell_target(sf; inset = 1, row = 1, col = 2).xref == "x3"
        @test _cmn_throws(() -> _CMN._cell_target(sf; inset = 1, row = 1, col = 1), "inset 1 belongs to cell (1, 2)")
        @test _cmn_throws(() -> _CMN._cell_target(sf; inset = 2, who = "plot_scatter!"), "plot_scatter!: unknown inset id 2; valid ids are 1:1")
        @test _cmn_throws(() -> _CMN._cell_target(sf; inset = 1, secondary_y = true), "an inset has no secondary y-axis")
        @test _cmn_throws(() -> _CMN._cell_target(sf; inset = "1"), "`inset` must be an integer")

        # Staged copies own their inset vector; selection-only commits keep it.
        staged = _CMN._staged_subplot_figure(sf, sf.plot)
        @test staged.insets == sf.insets && staged.insets !== sf.insets
        push!(staged.insets, rec)
        @test length(sf.insets) == 1
        _CMN._commit_subplot_metadata!(sf, staged, _CMN._SUBPLOT_SELECTION_METADATA_FIELDS)
        @test length(sf.insets) == 1
        plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row = 1, col = 1)
        @test length(sf.insets) == 1
        # A caller-supplied vector is copied, not aliased.
        records = [rec]
        own = SubplotFigure(Plot(), 1, 1, 1, 1, false, :topright, (0.02, 0.03), "white", "black", 1.0, records)
        push!(records, rec)
        @test length(own.insets) == 1
    end

    @testset "_axis_type / coordinate conversion" begin
        fig = plot_scatter([1.0, 10.0, 100.0], [1.0, 2.0, 3.0]; xscale = "log")
        layout = fig.layout
        @test _CMN._axis_type(layout, :xaxis) == "log"
        @test _CMN._axis_type(fig, :yaxis) == "-"
        @test _CMN._axis_type(Plot(), :xaxis2) == "-"
        @test _cmn_throws(() -> _CMN._axis_type(layout, :scene), "not a Cartesian axis layout key")
        @test _cmn_throws(() -> _CMN._axis_type(layout, :xaxis1), "not a Cartesian axis layout key")
        @test _CMN._to_axis_coord(layout, :xaxis, 100) == 2.0
        @test _CMN._to_axis_coord(fig, :xaxis, 1e-3) ≈ -3.0
        @test _CMN._to_axis_coord(layout, :yaxis, -5) == -5.0
        @test _CMN._to_axis_coord(layout, :yaxis, 3) isa Float64
        @test _cmn_throws(() -> _CMN._to_axis_coord(layout, :xaxis, 0; who = "annotate!"), "annotate!: 0 cannot be placed on logarithmic")
        @test _cmn_throws(() -> _CMN._to_axis_coord(layout, :xaxis, -1), "must be positive")
        @test _cmn_throws(() -> _CMN._to_axis_coord(layout, :yaxis, NaN), "not finite")
        @test _cmn_throws(() -> _CMN._to_axis_coord(layout, :yaxis, Inf), "not finite")
        @test _CMN._to_axis_range(layout, :xaxis, (1, 1000)) == [0.0, 3.0]
        @test _CMN._to_axis_range(layout, :xaxis, [1000, 1]) == [3.0, 0.0]
        @test _CMN._to_axis_range(layout, :yaxis, 0:1) == [0.0, 1.0]
        @test _cmn_throws(() -> _CMN._to_axis_range(layout, :xaxis, [0, 10]), "must be positive")
        @test _cmn_throws(() -> _CMN._to_axis_range(layout, :xaxis, [1, 2, 3]), "exactly 2 elements")
        @test _cmn_throws(() -> _CMN._to_axis_range(layout, :xaxis, 5), "2-element vector or tuple")
        @test _cmn_throws(() -> _CMN._to_axis_range(layout, :yaxis, ["a", "b"]), "real numbers")

        @test _CMN._from_axis_range(layout, :xaxis) === nothing
        relayout!(fig; xaxis_range = [-2, 1], yaxis_range = [0.5, 4])
        @test all(_CMN._from_axis_range(fig, :xaxis) .≈ (0.01, 10.0))
        @test _CMN._from_axis_range(fig, :yaxis) == (0.5, 4.0)
        relayout!(fig; yaxis_autorange = true)
        @test _CMN._from_axis_range(fig, :yaxis) === nothing
        relayout!(fig; yaxis_autorange = false)
        @test _CMN._from_axis_range(fig, :yaxis) == (0.5, 4.0)
        relayout!(fig; yaxis_autorange = "reversed")
        @test _CMN._from_axis_range(fig, :yaxis) === nothing
        partial = Plot(GenericTrace[], Layout(xaxis = attr(range = [nothing, 5])))
        @test _CMN._from_axis_range(partial, :xaxis) === nothing
        dates = Plot(GenericTrace[], Layout(xaxis = attr(range = ["2020-01-01", "2021-01-01"])))
        @test _CMN._from_axis_range(dates, :xaxis) === nothing
    end

    @testset "_axis_data_extent" begin
        p = Plot(
            [
                scatter(x = [3.0, NaN, -2.0, Inf], y = [1, 2, 3, 4]),
                scatter(x = Any[missing, nothing, "a", 7], y = [0.5, 0.25, 9, 1], yaxis = "y2"),
                scatter3d(x = [100, 200], y = [100, 200], z = [1, 2]),
                pie(values = [1, 2]),
            ],
            Layout(),
        )
        @test _CMN._axis_data_extent(p, :xaxis) == (-2.0, 7.0)
        @test _CMN._axis_data_extent(p, :yaxis) == (1.0, 4.0)
        @test _CMN._axis_data_extent(p, :yaxis2) == (0.25, 9.0)
        @test _CMN._axis_data_extent(p, :xaxis2) === nothing
        relayout!(p; xaxis_type = "log")
        @test _CMN._axis_data_extent(p, :xaxis) == (3.0, 7.0)

        implicit = Plot([
            scatter(y = [5.0, 6.0, 7.0]),
            bar(y = [1, 2], x0 = 10, dx = 0.5),
            histogram(x = [1.0, 2.0, 2.0]),
            heatmap(z = [1 2 3; 4 5 6], xaxis = "x2", yaxis = "y2"),
        ], Layout())
        @test _CMN._axis_data_extent(implicit, :xaxis) == (0.0, 10.5)
        # Histogram counts are not data on the y axis; only scatter/bar y.
        @test _CMN._axis_data_extent(implicit, :yaxis) == (1.0, 7.0)
        # PlotlyBase marks heatmaps transpose=true; Plotly then reads the 2x3
        # Julia matrix as 2 rows (y) x 3 columns (x).
        hm = implicit.data[4]
        @test hm.fields[:transpose] === true
        @test _CMN._axis_data_extent(implicit, :xaxis2) == (0.0, 2.0)
        @test _CMN._axis_data_extent(implicit, :yaxis2) == (0.0, 1.0)
        @test _CMN._axis_data_extent(Plot(), :xaxis) === nothing

        sf = subplots(1, 2; sync = false)
        plot_scatter!(sf, [10.0, 20.0], [1.0, 2.0]; row = 1, col = 2)
        @test _CMN._axis_data_extent(sf, :xaxis2) == (10.0, 20.0)
        @test _CMN._axis_data_extent(sf, :xaxis) === nothing
    end

    @testset "_upsert_named!" begin
        sf = subplots(1, 2; sync = false, subplot_titles = ["left" "right"])
        n_titles = length(sf.plot.layout.fields[:annotations])
        @test n_titles == 2
        # The grid titles are named per cell (Z60), so a named item for cell
        # (1, 2) replaces that cell's grid title and leaves the other alone.
        name = "plotlysupply:title:1:2"
        @test count(a -> _cmn_get(a, :name) == name, sf.plot.layout.fields[:annotations]) == 1
        _CMN._upsert_named!(sf, :annotations, name, [attr(text = "first", x = 0.5, y = 1.0, xref = "paper", yref = "paper")])
        _CMN._upsert_named!(sf, :annotations, name, [attr(text = "second", x = 0.5, y = 1.0, xref = "paper", yref = "paper")])
        anns = sf.plot.layout.fields[:annotations]
        @test length(anns) == n_titles
        @test count(a -> _cmn_get(a, :name) == name, anns) == 1
        @test _cmn_get(anns[end], :text) == "second"
        @test [_cmn_get(a, :text) for a in anns[1:(n_titles - 1)]] == ["left"]
        # An item under a name no grid title carries is added after them.
        _CMN._upsert_named!(sf, :annotations, "plotlysupply:note:1:2", [attr(text = "note", x = 0.5, y = 0.5, xref = "paper", yref = "paper")])
        anns = sf.plot.layout.fields[:annotations]
        @test [_cmn_get(a, :text) for a in anns] == ["left", "second", "note"]

        p = Plot()
        _CMN._upsert_named!(p, :shapes, "plotlysupply:span:0:0", [attr(type = "rect"), attr(type = "line")])
        names = [_cmn_get(s, :name) for s in p.layout.fields[:shapes]]
        @test names == ["plotlysupply:span:0:0:1", "plotlysupply:span:0:0:2"]
        _CMN._upsert_named!(p, :shapes, "plotlysupply:span:0:0", [attr(type = "circle", name = "plotlysupply:span:0:0:k")])
        @test [_cmn_get(s, :type) for s in p.layout.fields[:shapes]] == ["circle"]
        # Other owners (prefix must be followed by ':') are untouched.
        _CMN._upsert_named!(p, :shapes, "plotlysupply:span:0:00", [attr(type = "rect")])
        @test length(p.layout.fields[:shapes]) == 2
        _CMN._upsert_named!(p, :shapes, "plotlysupply:span:0:0", [])
        @test [_cmn_get(s, :name) for s in p.layout.fields[:shapes]] == ["plotlysupply:span:0:00"]
        before = _cmn_json(p.layout)
        @test _cmn_throws(() -> _CMN._upsert_named!(p, :images, "x", []), "must be :annotations or :shapes")
        @test _cmn_throws(() -> _CMN._upsert_named!(p, :shapes, "", []), "non-empty")
        @test _cmn_throws(() -> _CMN._upsert_named!(p, :shapes, "a", [attr(type = "rect", name = "b")]), "named \"b\"")
        @test _cmn_throws(() -> _CMN._upsert_named!(p, :shapes, "a", [1]), "must be an attr")
        @test _cmn_json(p.layout) == before
        weird = Plot(GenericTrace[], Layout(shapes = attr(type = "rect")))
        @test _cmn_throws(() -> _CMN._upsert_named!(weird, :shapes, "a", []), "must be a vector")
    end

    @testset "log_ticks" begin
        @test log_ticks(1e-3, 1; subs = (1, 2, 5)) ==
              [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]
        @test log_ticks(1, 1e-3; subs = [5, 2, 1, 2]) == log_ticks(1e-3, 1; subs = (1, 2, 5))
        @test log_ticks(4, 32; base = 2) == [4.0, 8.0, 16.0, 32.0]
        @test log_ticks(3, 33; base = 2, subs = (1, 1.5)) == [3.0, 4.0, 6.0, 8.0, 12.0, 16.0, 24.0, 32.0]
        @test log_ticks(1, 100) == [1.0, 10.0, 100.0]
        @test log_ticks(1, 100; subs = 1:9) == vcat(1.0:9.0, 10.0:10.0:90.0, 100.0)
        @test log_ticks(2, 3) == Float64[]
        @test log_ticks(7, 7; subs = 7) == [7.0]
        # Beyond 10^22 powers are not exact doubles; they stay within an ulp.
        @test log_ticks(1e-300, 1e-298) ≈ [1e-300, 1e-299, 1e-298]
        @test length(log_ticks(1e-300, 1e-298)) == 3
        @test _cmn_throws(() -> log_ticks(0, 1), "log_ticks: `lo` must be finite and positive")
        @test _cmn_throws(() -> log_ticks(1, Inf), "`hi` must be finite")
        @test _cmn_throws(() -> log_ticks(1, 10; base = 1), "`base` must be finite and greater than 1")
        @test _cmn_throws(() -> log_ticks(1, 10; subs = (0.5,)), "[1, base)")
        @test _cmn_throws(() -> log_ticks(1, 10; subs = (10,)), "[1, base)")
        @test _cmn_throws(() -> log_ticks(1, 10; subs = ()), "must not be empty")
        @test _cmn_throws(() -> log_ticks(1, 10; subs = "1"), "`subs` must be")
        @test _cmn_throws(() -> log_ticks(1, 1e300; base = 1.0001), "spans more than")
    end

    @testset "_apply_ticks!" begin
        fig = plot_scatter([1e-3, 0.5, 1.0], [1.0, 2.0, 3.0]; xscale = "log")
        _CMN._apply_ticks!(fig, :xaxis; values = [1e-3, 1e-2, 1e-1, 1.0])
        ax = _cmn_axis(fig, :xaxis)
        @test ax[:tickmode] == "array"
        @test ax[:tickvals] == [1e-3, 1e-2, 1e-1, 1.0]
        # ADDENDUM B1: no "~g" on a log axis (it prints 1e+06); the power
        # exponent format of the log axis stays in effect.
        @test _cmn_get(ax, :tickformat) === nothing
        @test ax[:exponentformat] == "power"
        # JSON tick values are data values even on a log axis.
        @test occursin("\"tickvals\":[0.001,0.01,0.1,1.0]", _cmn_json(fig.layout))
        @test _cmn_get(ax, :type) == "log" && _cmn_get(ax, :showline) == true

        _CMN._apply_ticks!(fig, :xaxis; values = [1e-3, 1.0], labels = ["\$10^{-3}\$", "1"])
        ax = _cmn_axis(fig, :xaxis)
        @test ax[:ticktext] == [PlotlySupply._label("\$10^{-3}\$"), PlotlySupply._label("1")]
        # A later call without labels drops the stale ticktext.
        _CMN._apply_ticks!(fig, :xaxis; values = [0.01, 0.1])
        @test _cmn_get(_cmn_axis(fig, :xaxis), :ticktext) === nothing

        lin = plot_scatter([0.0, 1.0], [2.0, 3.0])
        before = _cmn_json(lin.layout)
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; values = [1, 2], labels = ["a"], who = "xticks!"), "xticks!: got 1 tick labels for 2 tick values")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; labels = ["a"]), "need tick `values`")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; subs = (1, 2, 5)), "needs a logarithmic axis")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; values = [1], subs = (1,)), "either tick `values` or `subs`")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; values = [1, NaN]), "not finite")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; values = [1, nothing]), "must all be real numbers")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; values = 1:2, labels = [1, 2]), "tick labels must be strings")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; exponentformat = "pow"), "`exponentformat` must be one of")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; direction = "both"), "`direction` must be")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :xaxis; angle = NaN), "`angle` must be finite")
        @test _cmn_throws(() -> _CMN._apply_ticks!(lin, :zaxis; values = [1]), "not a Cartesian axis layout key")
        @test _cmn_throws(() -> _CMN._apply_ticks!(fig, :xaxis; values = [0.0, 1.0]), "log-axis values must be positive")
        @test _cmn_throws(() -> _CMN._apply_ticks!(fig, :xaxis; values = ["a"]), "needs numeric tick values")
        @test _cmn_json(lin.layout) == before

        _CMN._apply_ticks!(lin, :xaxis; values = 0:0.5:1, format = ".2f", angle = 45, direction = "inside")
        ax = _cmn_axis(lin, :xaxis)
        @test (ax[:tickformat], ax[:tickangle], ax[:ticks]) == (".2f", 45, "inside")
        @test ax[:tickvals] == [0.0, 0.5, 1.0]
        # An existing tickformat survives a later values-only call.
        _CMN._apply_ticks!(lin, :xaxis; values = [0, 1])
        @test _cmn_axis(lin, :xaxis)[:tickformat] == ".2f"
        _CMN._apply_ticks!(lin, :yaxis; values = [2, 3], exponentformat = "power")
        ay = _cmn_axis(lin, :yaxis)
        @test ay[:exponentformat] == "power" && _cmn_get(ay, :tickformat) === nothing
        cat = Plot(bar(x = ["a", "b", "c"], y = [1, 2, 3]))
        _CMN._apply_ticks!(cat, :xaxis; values = ["a", "c"], labels = ["A", "C"])
        @test _cmn_axis(cat, :xaxis)[:tickvals] == ["a", "c"]
        @test _cmn_get(_cmn_axis(cat, :xaxis), :tickformat) === nothing
        _CMN._apply_ticks!(lin, :xaxis; values = Int[])
        @test _cmn_axis(lin, :xaxis)[:tickvals] == Float64[]

        # subs over the explicit range, else the data extent.
        lg = plot_scatter([2e-3, 0.8], [1.0, 2.0]; xscale = "log", yscale = "log")
        _CMN._apply_ticks!(lg, :xaxis; subs = (1, 2, 5))
        @test _cmn_axis(lg, :xaxis)[:tickvals] == [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5]
        relayout!(lg; xaxis_range = [-3, 0])
        _CMN._apply_ticks!(lg, :xaxis; subs = (1, 2, 5))
        @test _cmn_axis(lg, :xaxis)[:tickvals] == [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]
        empty_log = Plot(GenericTrace[], Layout(xaxis = attr(type = "log")))
        @test _cmn_throws(() -> _CMN._apply_ticks!(empty_log, :xaxis; subs = (1,)), "set an explicit range or add data")
        narrow = Plot(scatter(x = [2.0, 3.0], y = [1, 2]), Layout(xaxis = attr(type = "log")))
        @test _cmn_throws(() -> _CMN._apply_ticks!(narrow, :xaxis; subs = (1,)), "no `subs` tick falls inside")

        # Minor ticks: explicit 1..9 mantissas on a log axis with array majors.
        _CMN._apply_ticks!(lg, :xaxis; minor = true)
        mn = _cmn_axis(lg, :xaxis)[:minor]
        @test _cmn_get(mn, :ticks) == "outside" && _cmn_get(mn, :ticklen) == 3
        @test _cmn_get(mn, :tickmode) == "array"
        mvals = _cmn_get(mn, :tickvals)
        @test mvals[1:4] ≈ [0.003, 0.004, 0.006, 0.007]
        @test !any(v -> any(m -> isapprox(v, m), _cmn_axis(lg, :xaxis)[:tickvals]), mvals)
        @test all(v -> 1e-3 <= v <= 1.0, mvals)
        _CMN._apply_ticks!(lg, :xaxis; minor = false)
        mn = _cmn_axis(lg, :xaxis)[:minor]
        @test _cmn_get(mn, :ticks) == ""
        @test _cmn_get(mn, :tickvals) === nothing && _cmn_get(mn, :tickmode) === nothing
        # Auto major ticks: plain minor ticks, no explicit values.
        _CMN._apply_ticks!(lg, :yaxis; minor = true, direction = "inside")
        my = _cmn_axis(lg, :yaxis)[:minor]
        @test _cmn_get(my, :ticks) == "inside" && _cmn_get(my, :tickvals) === nothing
        @test _cmn_axis(lg, :yaxis)[:ticks] == "inside"
        # Log-2 style ticks from powers of two.
        l2 = plot_scatter([4, 8, 16, 24, 32], [1.0, 2, 3, 4, 5]; xscale = "log")
        _CMN._apply_ticks!(l2, :xaxis; values = 2 .^ (2:5))
        @test _cmn_axis(l2, :xaxis)[:tickvals] == [4.0, 8.0, 16.0, 32.0]
        @test _cmn_get(_cmn_axis(l2, :xaxis), :tickformat) === nothing
        @test _cmn_axis(l2, :xaxis)[:exponentformat] == "power"

        # Only the target cell's axis changes on a SubplotFigure.
        sf = subplots(1, 2; sync = false)
        plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row = 1, col = 1)
        plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; row = 1, col = 2)
        others = Dict(k => _cmn_json(v) for (k, v) in sf.plot.layout.fields if k != :xaxis2)
        t = _CMN._cell_target(sf; row = 1, col = 2)
        _CMN._apply_ticks!(sf, t.xkey; values = [1, 1.5, 2])
        @test _cmn_axis(sf.plot, :xaxis2)[:tickvals] == [1.0, 1.5, 2.0]
        @test all(_cmn_json(sf.plot.layout.fields[k]) == v for (k, v) in others)
    end

    @testset "_apply_equal_aspect!" begin
        sf = subplots(2, 2; sync = false)
        xrange!(sf, [-3, 3]; row = 2, col = 1)
        relayout!(sf; xaxis3_scaleanchor = "y")   # the 1.x delegate's stale cross-cell anchor
        t = _CMN._cell_target(sf; row = 2, col = 1)
        _CMN._apply_equal_aspect!(sf, t; ratio = 2)
        y3 = _cmn_axis(sf.plot, :yaxis3)
        x3 = _cmn_axis(sf.plot, :xaxis3)
        @test (y3[:scaleanchor], y3[:scaleratio], y3[:constrain]) == ("x3", 2.0, "domain")
        @test x3[:constrain] == "domain"
        @test _cmn_get(x3, :scaleanchor) === nothing
        @test x3[:range] == [-3, 3]
        @test _cmn_get(_cmn_axis(sf.plot, :yaxis), :scaleanchor) === nothing

        fig = plot_scatter([0.0, 1.0], [0.0, 1.0])
        _CMN._apply_equal_aspect!(fig, _CMN._cell_target(fig))
        @test _cmn_axis(fig, :yaxis)[:scaleanchor] == "x"
        @test _cmn_axis(fig, :yaxis)[:scaleratio] == 1.0

        mixed = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "polar")])
        ts = _CMN._cell_target(mixed; row = 1, col = 1)
        _CMN._apply_equal_aspect!(mixed, ts)
        @test _cmn_get(mixed.plot.layout.fields[:scene], :aspectmode) == "data"
        @test _cmn_get(mixed.plot.layout.fields[:scene], :domain) !== nothing
        @test _cmn_throws(() -> _CMN._apply_equal_aspect!(mixed, ts; ratio = 2), "supports only `ratio = 1`")
        tp = _CMN._cell_target(mixed; row = 1, col = 2)
        @test _cmn_throws(() -> _CMN._apply_equal_aspect!(mixed, tp; who = "axis_equal!"), "axis_equal!: equal aspect applies")
        @test _cmn_throws(() -> _CMN._apply_equal_aspect!(fig, _CMN._cell_target(fig); ratio = 0), "`ratio` must be finite and positive")
        @test _cmn_throws(() -> _CMN._apply_equal_aspect!(fig, _CMN._cell_target(fig); ratio = Inf), "`ratio` must be finite and positive")
    end

    @testset "_ensure_twin_y!" begin
        fig = plot_scatter([1.0, 2.0], [3.0, 4.0])
        key = _CMN._ensure_twin_y!(fig)
        @test key == :yaxis2
        ax = _cmn_axis(fig, :yaxis2)
        @test (ax[:overlaying], ax[:side], ax[:anchor], ax[:showgrid]) == ("y", "right", "x", false)
        @test _CMN._ensure_twin_y!(fig) == :yaxis2
        t = _CMN._cell_target(fig; secondary_y = true)
        @test (t.ykey, t.yref, t.ydomain) == (:yaxis2, "y2", (0.0, 1.0))

        stacked = Plot(
            [scatter(x = [1], y = [1]), scatter(x = [1], y = [2], yaxis = "y3")],
            Layout(yaxis2 = attr(domain = [0.5, 1.0])),
        )
        @test _CMN._ensure_twin_y!(stacked) == :yaxis4
        @test _cmn_axis(stacked, :yaxis4)[:overlaying] == "y"

        @test _cmn_throws(() -> _CMN._ensure_twin_y!(Plot(scatter3d(x = [1], y = [1], z = [1]))), "needs Cartesian x/y axes")
        @test _cmn_throws(() -> _CMN._ensure_twin_y!(subplots(1, 1; sync = false); who = "plot_scatter!"), "plot_scatter!: SubplotFigure cells")
    end

    @testset "_marker_attr" begin
        m = _CMN._marker_attr(; color_series = "#1f77b4", marker_color = "white")
        @test m[:color] == "white"
        @test m[:line][:color] == "#1f77b4" && m[:line][:width] == 1.5
        m = _CMN._marker_attr(; color_series = "#1f77b4", marker_color = "white", marker_line_color = "black", marker_line_width = 0.5)
        @test (m[:line][:color], m[:line][:width]) == ("black", 0.5)
        m = _CMN._marker_attr(; color_series = "#1f77b4", marker_color = "none")
        @test m[:symbol] == "circle-open" && m[:color] == "#1f77b4" && m[:line][:width] == 1.5
        @test _CMN._marker_attr(; marker_color = "none", marker_symbol = "s")[:symbol] == "square-open"
        @test _CMN._marker_attr(; marker_color = "none", marker_symbol = "circle-dot")[:symbol] == "circle-open-dot"
        @test _CMN._marker_attr(; marker_color = "none", marker_symbol = "diamond-open")[:symbol] == "diamond-open"
        m = _CMN._marker_attr(; color_series = "red", marker_color = "none", marker_symbol = "x")
        @test m[:symbol] == "x-thin" && m[:line][:color] == "red"
        m = _CMN._marker_attr(; color_series = "#2ca02c", marker_symbol = "x")
        @test (m[:symbol], m[:line][:width], m[:line][:color]) == ("x-thin", 1.5, "#2ca02c")
        @test _CMN._marker_attr(; marker_symbol = "+", marker_color = "blue")[:line][:color] == "blue"
        @test _CMN._marker_attr(; marker_symbol = :asterisk, marker_line_width = 3)[:line][:width] == 3
        m = _CMN._marker_attr(; marker_symbol = ".")
        @test (m[:symbol], m[:size]) == ("circle", 4)
        @test _CMN._marker_attr(; marker_symbol = ".", marker_size = 7.5)[:size] == 7.5
        for (code, name) in ("o" => "circle", "s" => "square", "^" => "triangle-up", "v" => "triangle-down",
                "<" => "triangle-left", ">" => "triangle-right", "D" => "diamond", "d" => "diamond-tall",
                "*" => "star", "p" => "pentagon", "h" => "hexagon", "H" => "hexagon2")
            @test _CMN._marker_attr(; marker_symbol = code)[:symbol] == name
        end
        # Explicit open symbol: Plotly strokes it with marker.color.
        m = _CMN._marker_attr(; color_series = "gray", marker_symbol = "circle-open", marker_line_color = "red")
        @test m[:color] == "red" && m[:line][:width] == 1.5
        @test isempty(_CMN._marker_attr(; color_series = "gray", marker_symbol = "circle-open")[:line])
        @test isempty(_CMN._marker_attr().fields)
        m = _CMN._marker_attr(; marker_line_color = :black)
        @test (m[:line][:color], m[:line][:width]) == ("black", 1.5)
        @test _cmn_throws(() -> _CMN._marker_attr(; marker_symbol = "circel", who = "plot_scatter"), "plot_scatter: unknown marker symbol \"circel\"")
        @test _cmn_throws(() -> _CMN._marker_attr(; marker_size = -1), "`marker_size` must be finite and >= 0")
        @test _cmn_throws(() -> _CMN._marker_attr(; marker_line_width = NaN), "`marker_line_width`")
        @test _cmn_throws(() -> _CMN._marker_attr(; marker_color = 1), "`marker_color` must be a colour")
        @test _cmn_throws(() -> _CMN._marker_attr(; marker_symbol = 3), "must be a string or symbol")
    end

    @testset "_markevery_fields" begin
        f = _CMN._markevery_fields([2, 5], 6)
        @test f[:selectedpoints] == [1, 4]
        @test f[:unselected][:marker][:opacity] == 0
        @test _CMN._markevery_fields(3, 7)[:selectedpoints] == [0, 3, 6]
        @test _CMN._markevery_fields(2:2:6, 6)[:selectedpoints] == [1, 3, 5]
        @test _CMN._markevery_fields([5, 2, 5], 6)[:selectedpoints] == [1, 4]
        @test _CMN._markevery_fields([true, false, true], 3)[:selectedpoints] == [0, 2]
        @test _CMN._markevery_fields(BitVector([0, 1]), 2)[:selectedpoints] == [1]
        @test isempty(_CMN._markevery_fields(nothing, 5))
        @test _CMN._markevery_fields(Int[], 5)[:selectedpoints] == Int[]
        @test _CMN._markevery_fields(4, 0)[:selectedpoints] == Int[]
        @test _cmn_throws(() -> _CMN._markevery_fields([0, 1], 3), "index 0 is outside 1:3")
        @test _cmn_throws(() -> _CMN._markevery_fields([4], 3), "index 4 is outside 1:3")
        @test _cmn_throws(() -> _CMN._markevery_fields(0, 3), "must be >= 1")
        @test _cmn_throws(() -> _CMN._markevery_fields(true, 3), "Bool mask")
        @test _cmn_throws(() -> _CMN._markevery_fields([true], 3), "needs 3 entries")
        @test _cmn_throws(() -> _CMN._markevery_fields(0.5, 3), "must be nothing")
        @test _cmn_throws(() -> _CMN._markevery_fields([1.0], 3), "must be integers")
        # The JSON form Plotly reads: 0-based selection, transparent unselected markers.
        tr = GenericTrace("scatter", merge(Dict{Symbol,Any}(:x => 1:6, :y => 1:6), f))
        @test occursin("\"selectedpoints\":[1,4]", _cmn_json(tr))
        @test occursin("\"unselected\":{\"marker\":{\"opacity\":0}}", _cmn_json(tr))
    end

    @testset "_proxy_trace" begin
        t = _CMN._proxy_trace("Model A"; color = "red", dash = "dash", linewidth = 2, legendgroup = "g")
        @test t isa GenericTrace
        @test t.fields[:type] == "scatter"
        @test t.fields[:x] == [nothing] && t.fields[:y] == [nothing]
        @test t.fields[:name] == PlotlySupply._label("Model A")
        @test (t.fields[:showlegend], t.fields[:hoverinfo], t.fields[:mode]) == (true, "skip", "lines")
        @test (t.fields[:line][:color], t.fields[:line][:dash], t.fields[:line][:width]) == ("red", "dash", 2)
        @test t.fields[:legendgroup] == "g"
        js = _cmn_json(t)
        @test occursin("\"x\":[null]", js) && occursin("\"y\":[null]", js)
        @test !haskey(t.fields, :marker) && !haskey(t.fields, :opacity)

        m = _CMN._proxy_trace("pts"; mode = "markers", color = "blue", marker_symbol = "o", marker_size = 9)
        @test (m.fields[:marker][:symbol], m.fields[:marker][:color], m.fields[:marker][:size]) == ("circle", "blue", 9)
        h = _CMN._proxy_trace("hollow"; mode = "lines+markers", color = "green", marker_color = "none")
        @test h.fields[:marker][:symbol] == "circle-open" && h.fields[:marker][:color] == "green"
        @test h.fields[:line][:color] == "green"
        patch = _CMN._proxy_trace("region"; color = "#cccccc", patch = true, opacity = 0.3)
        @test patch.fields[:mode] == "markers"
        pm = patch.fields[:marker]
        @test (pm[:symbol], pm[:size], pm[:color], pm[:line][:width]) == ("square", 12, "#cccccc", 0)
        @test patch.fields[:opacity] == 0.3
        edged = _CMN._proxy_trace("edged"; color = "#cccccc", patch = true, marker_line_width = 1, marker_line_color = "black")
        @test (edged.fields[:marker][:line][:width], edged.fields[:marker][:line][:color]) == (1, "black")
        spacer = _CMN._proxy_trace(" ")
        @test spacer.fields[:name] == PlotlySupply._label(" ") && !haskey(spacer.fields, :line)
        @test _cmn_throws(() -> _CMN._proxy_trace("a"; mode = "text"), "`mode` must be")
        @test _cmn_throws(() -> _CMN._proxy_trace("a"; mode = ""), "`mode` must be")
        @test _cmn_throws(() -> _CMN._proxy_trace("a"; opacity = 2, who = "legend_entry!"), "legend_entry!: `opacity` must lie in [0, 1]")
        @test _cmn_throws(() -> _CMN._proxy_trace("a"; linewidth = -1), "`linewidth`")
        @test _cmn_throws(() -> _CMN._proxy_trace("a"; patch = true, marker_size = -2), "`marker_size`")
        @test _cmn_throws(() -> _CMN._proxy_trace("a"; mode = "markers", marker_symbol = "nope"), "unknown marker symbol")
    end

    @testset "_hatch_pattern" begin
        @test _CMN._hatch_pattern("") === nothing
        for (h, shape) in ("/" => "/", "\\" => "\\", "x" => "x", "-" => "-", "|" => "|", "+" => "+", "." => ".")
            pat = _CMN._hatch_pattern(h)
            @test pat[:shape] == shape
            @test pat[:fillmode] == "overlay"
            @test pat[:size] > 0
        end
        @test _CMN._hatch_pattern("|")[:size] ≈ 16.0
        @test _CMN._hatch_pattern("/")[:size] ≈ 16 / sqrt(2)
        @test _CMN._hatch_pattern("///")[:size] ≈ _CMN._hatch_pattern("/")[:size] / 3
        @test _CMN._hatch_pattern("||")[:solidity] ≈ (96 / 72) / 8
        @test 0 < _CMN._hatch_pattern("xx")[:solidity] <= 1
        @test _CMN._hatch_pattern("|||||||||||||||||||||||||")[:solidity] == 1.0
        @test !haskey(_CMN._hatch_pattern(".").fields, :solidity)
        @test _CMN._hatch_pattern("/\\")[:shape] == "x"
        @test _CMN._hatch_pattern("-|")[:shape] == "+"
        @test _CMN._hatch_pattern("//"; color = "black")[:fgcolor] == "black"
        @test _CMN._hatch_pattern("/"; color = :red)[:fgcolor] == "red"
        @test _cmn_throws(() -> _CMN._hatch_pattern("o"; who = "plot_bar"), "plot_bar: unsupported hatch \"o\"")
        @test _cmn_throws(() -> _CMN._hatch_pattern("/-"), "unsupported hatch")
        @test _cmn_throws(() -> _CMN._hatch_pattern("*"), "unsupported hatch")
        @test _cmn_throws(() -> _CMN._hatch_pattern("/"; color = 3), "`color` must be a colour")
        b = bar(x = [1], y = [2], marker = attr(color = "red", pattern = _CMN._hatch_pattern("//")))
        @test occursin("\"pattern\":{", _cmn_json(b)) && occursin("\"fillmode\":\"overlay\"", _cmn_json(b))
    end

    @testset "primitives inside real transactions" begin
        # Full staged path (_StagedPlotMutation) on a Plot.
        p = plot_scatter([1.0, 2.0, 3.0], [1.0, 4.0, 9.0])
        @test _CMN._transactional_high_level_plot_mutation!(_cmn_test_mutator!, p, [1, 2, 3]) === nothing
        @test _cmn_axis(p, :xaxis)[:tickvals] == [1.0, 2.0, 3.0]
        @test _cmn_axis(p, :xaxis)[:ticktext] == PlotlySupply._label.(["1", "2", "3"])
        @test _cmn_axis(p, :yaxis)[:scaleanchor] == "x"
        @test _cmn_axis(p, :yaxis2)[:overlaying] == "y"
        @test count(a -> _cmn_get(a, :name) == "plotlysupply:test:0:0", p.layout.fields[:annotations]) == 1
        # Re-running is idempotent for the named annotation and the twin axis.
        _CMN._transactional_high_level_plot_mutation!(_cmn_test_mutator!, p, [1, 2, 3])
        @test count(a -> _cmn_get(a, :name) == "plotlysupply:test:0:0", p.layout.fields[:annotations]) == 1
        @test !haskey(p.layout.fields, :yaxis3)

        # A failure after the writes leaves the figure untouched.
        q = plot_scatter([1.0, 2.0], [1.0, 2.0])
        snapshot = _cmn_json(q.layout)
        @test_throws ArgumentError _CMN._transactional_high_level_plot_mutation!(_cmn_test_mutator!, q, [1, 2]; fail = true)
        @test _cmn_json(q.layout) == snapshot

        # Fast path (_HighLevelStagedPlotMutation) used by registered mutators.
        r = plot_scatter([1.0, 2.0], [1.0, 2.0])
        fast = candidate -> (_cmn_test_mutator!(_CMN._HighLevelStagedPlotMutation(candidate), [1, 2]); nothing)
        full = candidate -> (_cmn_test_mutator!(_CMN._StagedPlotMutation(candidate), [1, 2]); nothing)
        _CMN._transactional_high_level_model_mutation!(fast, full, r)
        @test _cmn_axis(r, :xaxis)[:tickvals] == [1.0, 2.0]
        @test _cmn_axis(r, :yaxis)[:scaleratio] == 2.0
        @test _cmn_axis(r, :yaxis2)[:side] == "right"
        failing = candidate -> (_cmn_test_mutator!(_CMN._HighLevelStagedPlotMutation(candidate), [5, 6]; fail = true); nothing)
        snapshot = _cmn_json(r.layout)
        @test_throws ArgumentError _CMN._transactional_high_level_model_mutation!(failing, failing, r)
        @test _cmn_json(r.layout) == snapshot

        # SyncPlot: one renderer transaction, committed model.
        sp, state = _cmn_syncplot(plot_scatter([1.0, 2.0], [1.0, 2.0]))
        n_scripts = length(state.scripts)
        _CMN._transactional_high_level_plot_mutation!(_cmn_test_mutator!, sp, [1, 2])
        @test length(state.scripts) == n_scripts + 1
        @test _cmn_axis(sp.plot, :xaxis)[:tickvals] == [1.0, 2.0]
        @test _cmn_axis(sp.plot, :yaxis2)[:overlaying] == "y"
        snapshot = _cmn_json(sp.plot.layout)
        @test_throws ArgumentError _CMN._transactional_high_level_plot_mutation!(_cmn_test_mutator!, sp, [3]; fail = true)
        @test _cmn_json(sp.plot.layout) == snapshot
        close(sp)

        # Headless SubplotFigure through the subplot transaction helper.
        sf = subplots(2, 2; sync = false)
        plot_scatter!(sf, [1.0, 2.0], [3.0, 4.0]; row = 2, col = 2)
        @test _CMN._transactional_subplot_mutation!(_cmn_test_subplot_impl!, sf, _CMN._SUBPLOT_SELECTION_METADATA_FIELDS, [1, 2]; row = 2, col = 2) === sf
        @test (sf.current_row, sf.current_col) == (2, 2)
        @test _cmn_axis(sf.plot, :xaxis4)[:tickvals] == [1.0, 2.0]
        @test _cmn_axis(sf.plot, :yaxis4)[:scaleanchor] == "x4"
        @test _cmn_get(_cmn_axis(sf.plot, :xaxis), :tickvals) === nothing
        @test count(s -> _cmn_get(s, :name) == "plotlysupply:test:2:2", sf.plot.layout.fields[:shapes]) == 1
        subplot!(sf, 1, 1)
        snapshot = _cmn_json(sf.plot.layout)
        @test_throws ArgumentError _CMN._transactional_subplot_mutation!(_cmn_test_subplot_impl!, sf, _CMN._SUBPLOT_SELECTION_METADATA_FIELDS, [7]; row = 1, col = 2, fail = true)
        @test _cmn_json(sf.plot.layout) == snapshot
        @test (sf.current_row, sf.current_col) == (1, 1)

        # SyncPlot-backed SubplotFigure.
        sp2, state2 = _cmn_syncplot(Plot(GenericTrace[], Layout(Subplots(rows = 1, cols = 2))))
        sfs = SubplotFigure(sp2, 1, 2, 1, 1, true, :topright, (0.02, 0.03), "white", "black", 1.0)
        n_scripts = length(state2.scripts)
        _CMN._transactional_subplot_mutation!(_cmn_test_subplot_impl!, sfs, _CMN._SUBPLOT_SELECTION_METADATA_FIELDS, [0, 1]; row = 1, col = 2)
        @test length(state2.scripts) == n_scripts + 1
        @test _cmn_axis(sfs.plot, :yaxis2)[:scaleanchor] == "x2"
        @test sfs.current_col == 2
        close(sp2)
    end

    @testset "_apply_ticks! presets :decades / :auto (D9)" begin
        function decade_plot(lo, hi, letter)
            v = exp10.(range(log10(lo), log10(hi); length = 20))
            return letter === :x ?
                plot_scatter(v, collect(1.0:20); xscale = "log") :
                plot_scatter(collect(1.0:20), v; yscale = "log")
        end
        # k = max(1, ceil(n / 8)): 1.2, 3 and 8 decades label every decade
        # (unlabelled minor ticks at 2..9), 13 decades every second one (minor
        # ticks at every decade).
        for (lo, hi, step, minor_dtick) in (
            (1.0, 10^1.2, 1, "D1"),
            (0.1, 100.0, 1, "D1"),
            (1e-4, 1e4, 1, "D1"),
            (1e-6, 1e7, 2, 1),
        )
            for (letter, key) in ((:x, :xaxis), (:y, :yaxis))
                p = decade_plot(lo, hi, letter)
                _CMN._apply_ticks!(p, key; values = [lo, hi], labels = ["a", "b"], who = "t")
                _CMN._apply_ticks!(p, key; values = :decades, who = "t")
                ax = _cmn_axis(p, key)
                @test ax[:tickmode] == "linear"
                @test ax[:tick0] == 0
                @test ax[:dtick] == step
                @test ax[:exponentformat] == "power"
                @test _cmn_get(ax, :tickvals) === nothing
                @test _cmn_get(ax, :ticktext) === nothing
                minor = ax[:minor]
                @test _cmn_get(minor, :dtick) == minor_dtick
                @test _cmn_get(minor, :tickmode) == "linear"
                @test _cmn_get(minor, :tick0) == 0
                @test _cmn_get(minor, :ticks) == "outside"
                @test _cmn_get(minor, :tickvals) === nothing
                # The other axis is untouched.
                other = key === :xaxis ? :yaxis : :xaxis
                @test _cmn_get(_cmn_axis(p, other), :tickmode) === nothing
            end
        end
        # The explicit range wins over the data extent (13 decades of data,
        # 20-decade range: k = 3); a later call recomputes the step.
        p = decade_plot(1e-6, 1e7, :x)
        relayout!(p; xaxis_range = [-10, 10])
        _CMN._apply_ticks!(p, :xaxis; values = :decades)
        @test _cmn_axis(p, :xaxis)[:dtick] == 3
        relayout!(p; xaxis_range = [0, 2])
        _CMN._apply_ticks!(p, :xaxis; values = :decades)
        @test _cmn_axis(p, :xaxis)[:dtick] == 1
        # No range and no data: one decade.
        empty = Plot()
        relayout!(empty; xaxis_type = "log")
        _CMN._apply_ticks!(empty, :xaxis; values = :decades)
        @test _cmn_axis(empty, :xaxis)[:dtick] == 1
        # Keywords combine: an explicit exponent format, no minor ticks.
        p = decade_plot(1e-3, 1e3, :y)
        _CMN._apply_ticks!(p, :yaxis; values = :decades, exponentformat = "e", minor = false, direction = "inside")
        ax = _cmn_axis(p, :yaxis)
        @test ax[:exponentformat] == "e"
        @test _cmn_get(ax[:minor], :ticks) == ""
        @test _cmn_get(ax[:minor], :dtick) === nothing
        @test ax[:ticks] == "inside"
        # An automatic "~g" left by array ticks goes (it would print 1e+06).
        lin = plot_scatter([1.0, 10.0, 100.0], [1.0, 2.0, 3.0])
        _CMN._apply_ticks!(lin, :xaxis; values = [1, 10, 100])
        @test _cmn_axis(lin, :xaxis)[:tickformat] == "~g"
        relayout!(lin; xaxis_type = "log")
        _CMN._apply_ticks!(lin, :xaxis; values = :decades)
        @test _cmn_get(_cmn_axis(lin, :xaxis), :tickformat) === nothing

        # :auto: Plotly's automatic ticks again, on any axis type.
        p = decade_plot(1e-2, 1e3, :x)
        _CMN._apply_ticks!(p, :xaxis; values = :decades, format = ".0e")
        _CMN._apply_ticks!(p, :xaxis; values = :auto)
        ax = _cmn_axis(p, :xaxis)
        for name in (:tickmode, :tickvals, :ticktext, :tick0, :dtick)
            @test _cmn_get(ax, name) === nothing
        end
        @test ax[:tickformat] == ".0e"  # a format the user set is kept
        @test _cmn_get(ax[:minor], :ticks) == ""
        for name in (:tickmode, :tickvals, :tick0, :dtick)
            @test _cmn_get(ax[:minor], name) === nothing
        end
        @test ax[:type] == "log" && ax[:exponentformat] == "power"
        lin = plot_scatter([0.0, 1.0], [2.0, 3.0])
        _CMN._apply_ticks!(lin, :yaxis; values = [2, 3], labels = ["two", "three"], minor = true)
        _CMN._apply_ticks!(lin, :yaxis; values = :auto, minor = true)
        ax = _cmn_axis(lin, :yaxis)
        for name in (:tickmode, :tickvals, :ticktext, :tickformat)
            @test _cmn_get(ax, name) === nothing
        end
        @test _cmn_get(ax[:minor], :ticks) == "outside"

        # Errors, before anything changes.
        lin = plot_scatter([0.0, 1.0], [2.0, 3.0])
        lg = decade_plot(1.0, 100.0, :x)
        for (fig, kw, needle) in (
            (lin, (values = :decades,), "t: the `:decades` tick preset labels powers of ten and needs a logarithmic axis; :xaxis has type \"-\""),
            (lg, (values = :decade,), "t: unknown tick preset :decade; use :decades or :auto"),
            (lg, (values = :decades, labels = ["a"]), "t: the tick preset :decades chooses the ticks and their labels"),
            (lg, (values = :auto, subs = (1, 2)), "t: pass either the tick preset :auto or `subs`, not both"),
            (lg, (values = :decades, exponentformat = "bogus"), "`exponentformat` must be one of"),
        )
            before = _cmn_json(fig.layout)
            @test _cmn_throws(() -> _CMN._apply_ticks!(fig, :xaxis; who = "t", kw...), needle)
            @test _cmn_json(fig.layout) == before
        end
        cat = plot_bar(["a", "b"], [1.0, 2.0])
        relayout!(cat; xaxis_type = "category")
        @test _cmn_throws(() -> _CMN._apply_ticks!(cat, :xaxis; values = :decades, who = "t"), "has type \"category\"")
        _CMN._apply_ticks!(cat, :xaxis; values = :auto)
        @test _cmn_get(_cmn_axis(cat, :xaxis), :tickmode) === nothing
    end

    @testset "_validate_tick_option (constructor keywords)" begin
        lin = plot_scatter([0.0, 1.0], [2.0, 3.0])
        lg = plot_scatter([1.0, 10.0], [2.0, 3.0]; xscale = "log")
        v = _CMN._validate_tick_option
        @test v(lin, :xaxis, nothing, nothing, "", "t", "x") === nothing
        @test v(lin, :xaxis, :decades, nothing, "log", "t", "x") === nothing   # the call makes it log
        @test v(lg, :xaxis, :decades, nothing, "", "t", "x") === nothing
        @test v(lin, :yaxis, :auto, nothing, "", "t", "y") === nothing
        @test v(lin, nothing, :auto, nothing, "", "t", "y") === nothing        # axis not created yet
        @test v(lin, :xaxis, [1, 2], ["a", "b"], "", "t", "x") === nothing
        before = _cmn_json(lin.layout)
        for (args, needle) in (
            ((lin, :xaxis, :decades, nothing, "", "t", "x"), "t: the `:decades` tick preset labels powers of ten and needs a logarithmic axis; :xaxis has type \"-\""),
            ((lg, :xaxis, :decades, nothing, "linear", "t", "x"), "has type \"linear\""),
            ((lin, nothing, :decades, nothing, "", "t", "y"), "the axis has type \"-\""),
            ((lin, :xaxis, :tens, nothing, "", "t", "x"), "t: unknown tick preset :tens"),
            ((lg, :xaxis, :decades, ["a"], "", "t", "x"), "t: `xticks = :decades` chooses the tick labels; `xticklabels` need explicit `xticks` values."),
            ((lin, :yaxis, nothing, ["a"], "", "t", "y"), "t: `yticklabels` needs `yticks`"),
            ((lin, :xaxis, [1, 2], ["a"], "", "t", "x"), "got 1 tick labels for 2 tick values"),
            ((lg, :xaxis, [0, 10], nothing, "", "t", "x"), "positive"),
        )
            @test _cmn_throws(() -> v(args...), needle)
        end
        @test _cmn_json(lin.layout) == before
    end

    @testset "wave 5: date and string tick values (Z42)" begin
        D = _CMN.Dates
        @test _CMN._cmn_tick_values([D.Date(2020, 1, 1), D.Date(2020, 3, 1)], false, "t") == ["2020-01-01", "2020-03-01"]
        @test _CMN._cmn_tick_values([D.DateTime(2020, 1, 1, 6), D.DateTime(2020, 1, 2)], false, "t") ==
            ["2020-01-01T06:00:00", "2020-01-02T00:00:00"]
        @test _CMN._cmn_tick_values(Any[D.Date(2020, 1, 1), "2020-02-01"], false, "t") == ["2020-01-01", "2020-02-01"]
        @test _CMN._cmn_tick_values(["a", "b"], false, "t") == ["a", "b"]
        @test _cmn_throws(() -> _CMN._cmn_tick_values([D.Date(2020, 1, 1)], true, "t"),
            "t: a logarithmic axis needs numeric tick values; got dates.")
        @test _cmn_throws(() -> _CMN._cmn_tick_values(["a"], true, "t"),
            "t: a logarithmic axis needs numeric tick values; got strings.")
        @test _cmn_throws(() -> _CMN._cmn_tick_values(Any[1.0, D.Date(2020, 1, 1)], false, "t"),
            "(or all strings or dates on a category/date axis)")
        @test _CMN._cmn_tick_values([1, 2.5], false, "t") == [1.0, 2.5]
    end
end
