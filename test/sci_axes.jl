using Test, PlotlySupply

const _AX = PlotlySupply
const _AX_PB = PlotlySupply.PlotlyBase

function _ax_throws(f, needle::AbstractString)
    err = try
        f()
        nothing
    catch caught
        caught
    end
    err isa ArgumentError || return false
    return occursin(needle, err.msg)
end

_ax_json(x) = _AX_PB.JSON.json(x)
_ax_get(m, key) = PlotlySupply._cmn_mapping_get(m, key)
_ax_axis(p, key) = _AX._cmn_plot(p).layout.fields[key]
_ax_field(p, key, name) = _ax_get(get(_AX._cmn_plot(p).layout.fields, key, nothing), name)

# Fake renderer backend (as in test/sci_common.jl) so a SyncPlot runs real
# renderer transactions without Electron.
mutable struct _AxRendererState
    open::Bool
    scripts::Vector{String}
end

function _ax_syncplot(p)
    state = _AxRendererState(true, String[])
    backend = (
        isopen = window -> state.open,
        close = window -> (state.open = false; nothing),
        run = (window, script) -> (push!(state.scripts, String(script)); "ok"),
    )
    sp = SyncPlot(
        p,
        nothing,
        :sci_axes_window,
        "sci-axes-div",
        PlotlySupply._SyncPlotResources(nothing, backend),
    )
    return sp, state
end

function _ax_grid(rows, cols)
    sf = subplots(rows, cols; sync = false)
    for r in 1:rows, c in 1:cols
        plot_scatter!(sf, [1.0, 2.0, 3.0], [1.0, 4.0, 9.0]; row = r, col = c)
    end
    return sf
end

@testset "sci axes.jl" begin
    @testset "registration and exports" begin
        for name in (:xlabel!, :ylabel!, :zlabel!, :xrange!, :yrange!, :zrange!,
                     :xticks!, :yticks!, :axis_equal!, :axis_off!, :spines!, :grid!,
                     :secondary_xaxis!)
            @test name in _AX._TRANSACTIONAL_HIGH_LEVEL_PLOT_MUTATORS
        end
        for name in (:zlabel!, :zrange!, :xticks!, :yticks!, :axis_equal!, :axis_off!,
                     :spines!, :grid!, :secondary_xaxis!, :inset!)
            @test name in names(PlotlySupply)
        end
        @test hasmethod(xlabel!, Tuple{Plot, String})
        @test hasmethod(xrange!, Tuple{SyncPlot, Tuple{Int, Int}})
        @test hasmethod(xticks!, Tuple{Plot, Vector{Float64}, Vector{String}})
    end

    @testset "xlabel!/ylabel!/xrange!/yrange! on Plot and SyncPlot (C15, #318)" begin
        fig = plot_scatter([1.0, 2.0, 3.0], [4.0, 5.0, 6.0])
        @test xlabel!(fig, "time (s)") === nothing
        @test ylabel!(fig, "signal") === nothing
        @test fig.layout[:xaxis_title_text] == "time (s)"
        @test fig.layout[:yaxis_title_text] == "signal"
        # Mixed text + math goes through the mathtext layer.
        xlabel!(fig, "Time \$t\$ (s)")
        @test fig.layout[:xaxis_title_text] == PlotlySupply._label("Time \$t\$ (s)")
        xlabel!(fig, "")
        @test fig.layout[:xaxis_title_text] == ""
        @test xrange!(fig, (0, 5)) === nothing
        @test _ax_field(fig, :xaxis, :range) == [0, 5]
        @test _ax_field(fig, :xaxis, :autorange) === false
        yrange!(fig, [1.5, 7])
        @test _ax_field(fig, :yaxis, :range) == [1.5, 7]
        # Reversed ranges are kept.
        xrange!(fig, (5, 0))
        @test _ax_field(fig, :xaxis, :range) == [5, 0]

        sp, state = _ax_syncplot(plot_scatter([1.0, 2.0], [3.0, 4.0]))
        n = length(state.scripts)
        @test xrange!(sp, (1, 2)) === nothing
        @test _ax_field(sp.plot, :xaxis, :range) == [1, 2]
        @test length(state.scripts) > n
        @test xlabel!(sp, "renderer") === nothing
        @test sp.plot.layout[:xaxis_title_text] == "renderer"
        # A failing call changes neither the model nor the renderer.
        before = _ax_json(sp.plot.layout)
        n = length(state.scripts)
        @test _ax_throws(() -> xrange!(sp, (1, 2, 3)), "xrange!: `range` must have exactly 2 elements")
        @test _ax_json(sp.plot.layout) == before
        @test length(state.scripts) == n

        @test _ax_throws(() -> xlabel!(fig, "a"; row = 1, col = 1), "xlabel!: `row`/`col` select a SubplotFigure cell")
        @test _ax_throws(() -> xrange!(fig, (0, 1); inset = 1), "xrange!: `inset` needs a SubplotFigure")
        @test _ax_throws(() -> xlabel!(fig, "a"; show = true), "xlabel!: figure helpers have no `show` keyword")
        @test _ax_throws(() -> yrange!(fig, (0, 1); show = false), "yrange!: figure helpers have no `show` keyword")
    end

    @testset "#25: an explicit autorange no longer hides the range" begin
        fig = plot_scatter([1.0, 2.0], [1.0, 2.0])
        relayout!(fig; xaxis_autorange = true, yaxis_autorange = "reversed")
        xrange!(fig, [0, 3])
        yrange!(fig, [0, 4])
        @test _ax_field(fig, :xaxis, :autorange) === false
        @test _ax_field(fig, :yaxis, :autorange) === false
        sf = _ax_grid(1, 2)
        relayout!(sf; xaxis2_autorange = true)
        @test xrange!(sf, [0, 1]; row = 1, col = 2) === sf
        @test _ax_field(sf, :xaxis2, :autorange) === false
        @test _ax_field(sf, :xaxis2, :range) == [0, 1]
        @test (sf.current_row, sf.current_col) == (1, 2)
    end

    @testset "automatic sentinel restores autorange" begin
        for sentinel in (nothing, [0, 0], (0, 0), (0.0, 0.0), [nothing, nothing])
            fig = plot_scatter([1.0, 2.0], [1.0, 2.0])
            xrange!(fig, (0, 3))
            xrange!(fig, sentinel)
            @test _ax_field(fig, :xaxis, :autorange) === true
            @test _ax_field(fig, :xaxis, :range) === nothing
        end
        sf = _ax_grid(2, 1)
        yrange!(sf, (0, 1); row = 2, col = 1)
        yrange!(sf, nothing; row = 2, col = 1)
        @test _ax_field(sf, :yaxis2, :autorange) === true
        @test _ax_field(sf, :yaxis2, :range) === nothing
    end

    @testset "range validation (#18/#93/#112/#219 xrange! paths)" begin
        fig = plot_scatter([1.0, 2.0], [1.0, 2.0])
        before = _ax_json(fig.layout)
        @test _ax_throws(() -> xrange!(fig, [1]), "exactly 2 elements")
        @test _ax_throws(() -> xrange!(fig, 1:3), "exactly 2 elements")
        @test _ax_throws(() -> xrange!(fig, 5), "must be a 2-element vector or tuple")
        @test _ax_throws(() -> xrange!(fig, [nothing, 5]), "partial ranges are not supported")
        @test _ax_throws(() -> xrange!(fig, (1, missing)), "partial ranges are not supported")
        @test _ax_throws(() -> xrange!(fig, [1, Inf]), "bounds must be finite")
        @test _ax_throws(() -> xrange!(fig, [2, 2]), "the range bounds must differ")
        @test _ax_throws(() -> xrange!(fig, [true, false]), "range bounds must be numbers")
        @test _ax_json(fig.layout) == before
        sf = _ax_grid(1, 1)
        before = _ax_json(sf.plot.layout)
        @test _ax_throws(() -> xrange!(sf, [1, 2, 3]), "xrange!: `range` must have exactly 2 elements")
        @test _ax_throws(() -> yrange!(sf, (0, 1); row = 1), "`row` and `col` must be given together")
        @test _ax_throws(() -> yrange!(sf, (0, 1); row = 3, col = 1), "`row` must be in 1:1")
        @test _ax_json(sf.plot.layout) == before
    end

    @testset "C13: log-axis ranges are data units (#36/#52/#76/#209)" begin
        fig = plot_scatter([1e-3, 1.0, 1e3], [1.0, 2.0, 3.0]; xscale = "log", yscale = "log")
        xrange!(fig, (1e-3, 1e2))
        @test _ax_field(fig, :xaxis, :range) ≈ [-3.0, 2.0]
        yrange!(fig, [1, 1e4])
        @test _ax_field(fig, :yaxis, :range) ≈ [0.0, 4.0]
        before = _ax_json(fig.layout)
        @test _ax_throws(() -> xrange!(fig, (0, 10)), "log-axis values must be positive")
        @test _ax_throws(() -> yrange!(fig, (-1, 10)), "log-axis values must be positive")
        @test _ax_json(fig.layout) == before
        sf = subplots(1, 2; sync = false)
        plot_scatter!(sf, [0.1, 10.0], [1.0, 2.0]; row = 1, col = 2, xscale = "log")
        xrange!(sf, (0.1, 10); row = 1, col = 2)
        @test _ax_field(sf, :xaxis2, :range) ≈ [-1.0, 1.0]
        # #36: the docstrings say that log ranges are data values.
        for f in (xrange!, yrange!)
            doc = replace(string(Base.Docs.doc(f)), r"\s+" => " ")
            @test occursin("logarithmic", doc) && occursin("DATA units", doc)
        end
    end

    @testset "#265: ranges on shared (matched) axes reach the whole group" begin
        sf = subplots(2, 1; sync = false, shared_xaxes = true)
        plot_scatter!(sf, 0:20, collect(0.0:20.0); row = 1, col = 1)
        plot_scatter!(sf, 0:20, collect(20.0:-1:0.0); row = 2, col = 1)
        follower = _AX._cell_target(sf; row = 1, col = 1).xkey
        root = _AX._axes_match_root(sf, follower, "test")
        @test root != follower
        xrange!(sf, [0, 5]; row = 1, col = 1)
        @test _ax_field(sf, root, :range) == [0, 5]
        @test _ax_field(sf, root, :autorange) === false
        @test _ax_field(sf, follower, :range) === nothing
        sy = subplots(1, 2; sync = false, shared_yaxes = true)
        plot_scatter!(sy, 0:20, collect(0.0:20.0); row = 1, col = 1)
        plot_scatter!(sy, 0:20, collect(0.0:20.0); row = 1, col = 2)
        yrange!(sy, [0, 5]; row = 1, col = 2)
        @test PlotlySupply._symbol_dict(sy.plot.layout.fields[:yaxis])[:range] == [0, 5]
        # A cycle of `matches` references is reported, not followed forever.
        cyc = plot_scatter([1.0, 2.0], [1.0, 2.0])
        relayout!(cyc; xaxis_matches = "x2", xaxis2 = attr(matches = "x"))
        @test _ax_throws(() -> xrange!(cyc, (0, 1)), "form a cycle")
    end

    @testset "3-D scenes: labels, ranges, zlabel!/zrange!" begin
        f3 = plot_scatter3d([1.0, 10.0, 100.0], [1.0, 2.0, 3.0], [1.0, 2.0, 3.0]; xlabel = "X0")
        xlabel!(f3, "X")
        ylabel!(f3, "Y")
        @test zlabel!(f3, "Z") === nothing
        scene = f3.layout.fields[:scene]
        for (letter, text) in (('x', "X"), ('y', "Y"), ('z', "Z"))
            axis = _ax_get(scene, Symbol(letter, "axis"))
            @test _ax_get(_ax_get(axis, :title), :text) == text
        end
        @test zrange!(f3, (0, 2)) === nothing
        zaxis = _ax_get(f3.layout.fields[:scene], :zaxis)
        @test _ax_get(zaxis, :range) == [0, 2] && _ax_get(zaxis, :autorange) === false
        zrange!(f3, nothing)
        zaxis = _ax_get(f3.layout.fields[:scene], :zaxis)
        @test _ax_get(zaxis, :range) === nothing && _ax_get(zaxis, :autorange) === true
        relayout!(f3; scene_xaxis_type = "log")
        xrange!(f3, (1, 100))
        @test _ax_get(_ax_get(f3.layout.fields[:scene], :xaxis), :range) ≈ [0.0, 2.0]
        @test _ax_throws(() -> xrange!(f3, (0, 100)), "must be positive")
        @test _ax_throws(() -> zlabel!(plot_scatter([1.0], [1.0]), "z"), "zlabel!: a Cartesian (xy) cell has no z axis")
        @test _ax_throws(() -> zrange!(plot_scatter([1.0], [1.0]), (0, 1)), "zrange!: a Cartesian (xy) cell has no z axis")

        mixed = subplots(1, 3; sync = false, specs = [Spec(kind = "xy") Spec(kind = "scene") Spec(kind = "polar")])
        @test zlabel!(mixed, "height"; row = 1, col = 2) === mixed
        tscene = _AX._cell_target(mixed; row = 1, col = 2)
        zaxis = _ax_get(mixed.plot.layout.fields[tscene.scenekey], :zaxis)
        @test _ax_get(_ax_get(zaxis, :title), :text) == "height"
        @test (mixed.current_row, mixed.current_col) == (1, 2)
        zrange!(mixed, [-1, 1]; row = 1, col = 2)
        @test _ax_get(_ax_get(mixed.plot.layout.fields[tscene.scenekey], :zaxis), :range) == [-1, 1]
        @test _ax_throws(() -> xlabel!(mixed, "r"; row = 1, col = 3), "axis titles apply to Cartesian (xy) and 3-D scene cells")
        @test _ax_throws(() -> xrange!(mixed, (0, 1); row = 1, col = 3), "axis ranges apply to Cartesian (xy) and 3-D scene cells")
        @test _ax_throws(() -> zlabel!(mixed, "z"; row = 1, col = 1), "needs a 3-D scene cell")
    end

    @testset "secondary y targets" begin
        fig = plot_scatter([1.0, 2.0], [3.0, 4.0]; ylabel = "left")
        @test _ax_throws(() -> ylabel!(fig, "right"; secondary_y = true), "has no secondary y-axis")
        key = _AX._ensure_twin_y!(fig)
        ylabel!(fig, "right"; secondary_y = true)
        yrange!(fig, (0, 10); secondary_y = true)
        @test fig.layout[Symbol(key, :_title_text)] == "right"
        @test _ax_field(fig, key, :range) == [0, 10]
        @test fig.layout[:yaxis_title_text] == "left"
        @test _ax_field(fig, :yaxis, :range) === nothing
        sf = subplots(1, 1; sync = false, specs = fill(Spec(secondary_y = true), 1, 1))
        plot_scatter!(sf, 1:3, [1.0, 2, 3])
        plot_scatter!(sf, 1:3, [10.0, 20, 30]; secondary_y = true)
        ylabel!(sf, "secondary"; secondary_y = true)
        yrange!(sf, (0, 40); secondary_y = true)
        tsec = _AX._cell_target(sf; secondary_y = true)
        @test sf.plot.layout[Symbol(tsec.ykey, :_title_text)] == "secondary"
        @test _ax_field(sf, tsec.ykey, :range) == [0, 40]
    end

    @testset "_ensure_twin_y! copies the primary y fonts (style request)" begin
        fig = plot_scatter([1.0, 2.0], [3.0, 4.0])
        relayout!(fig; yaxis_title_font = attr(size = 20, family = "Arial"), yaxis_tickfont = attr(size = 14))
        key = _AX._ensure_twin_y!(fig)
        twin = fig.layout.fields[key]
        @test _ax_get(_ax_get(_ax_get(twin, :title), :font), :size) == 20
        @test _ax_get(_ax_get(_ax_get(twin, :title), :font), :family) == "Arial"
        @test _ax_get(_ax_get(twin, :tickfont), :size) == 14
        @test _ax_get(twin, :tickfont) !== _ax_get(fig.layout.fields[:yaxis], :tickfont)
        plain = plot_scatter([1.0, 2.0], [3.0, 4.0])
        k2 = _AX._ensure_twin_y!(plain)
        @test _ax_get(plain.layout.fields[k2], :tickfont) === nothing
    end

    @testset "xticks!/yticks! (F8, A6, B1)" begin
        fig = plot_scatter([1e-3, 0.5, 1.0], [1.0, 2.0, 3.0]; xscale = "log")
        @test xticks!(fig, [1e-3, 1e-2, 1e-1, 1.0]) === nothing
        ax = _ax_axis(fig, :xaxis)
        @test ax[:tickvals] == [1e-3, 1e-2, 1e-1, 1.0]
        @test occursin("\"tickvals\":[0.001,0.01,0.1,1.0]", _ax_json(fig.layout))
        # B1: no "~g" on a log axis; the power exponent format stays.
        @test _ax_get(ax, :tickformat) === nothing
        @test ax[:exponentformat] == "power"
        # subs over the explicit range.
        xrange!(fig, (1e-3, 1))
        xticks!(fig; subs = (1, 2, 5))
        @test _ax_axis(fig, :xaxis)[:tickvals] == [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]
        # minor ticks: explicit mantissas on a log axis with array majors.
        xticks!(fig; minor = true)
        mn = _ax_get(_ax_axis(fig, :xaxis), :minor)
        @test _ax_get(mn, :tickmode) == "array" && _ax_get(mn, :ticklen) == 3
        @test _ax_get(mn, :tickvals)[1:3] ≈ [0.003, 0.004, 0.006]
        xticks!(fig; minor = false)
        mn = _ax_get(_ax_axis(fig, :xaxis), :minor)
        @test _ax_get(mn, :ticks) == "" && _ax_get(mn, :tickvals) === nothing
        # mismatched labels throw, nothing changes.
        before = _ax_json(fig.layout)
        @test _ax_throws(() -> xticks!(fig, [1e-3, 1e-2], ["a"]), "xticks!: got 1 tick labels for 2 tick values")
        @test _ax_throws(() -> xticks!(fig, [0.0, 1.0]), "log-axis values must be positive")
        @test _ax_throws(() -> xticks!(fig; tickwidth = -1), "xticks!: `tickwidth` must be a finite number >= 0")
        @test _ax_throws(() -> xticks!(fig; direction = :both), "`direction` must be")
        @test _ax_json(fig.layout) == before
        @test_throws MethodError xticks!(fig; secondary_y = true)

        # Base-2 log ticks keep the exponent format (no SI suffixes).
        l2 = plot_scatter([4, 8, 16, 24, 32], [1.0, 2, 3, 4, 5]; xscale = "log")
        xticks!(l2, 2 .^ (2:5))
        @test _ax_axis(l2, :xaxis)[:tickvals] == [4.0, 8.0, 16.0, 32.0]
        @test _ax_get(_ax_axis(l2, :xaxis), :tickformat) === nothing
        @test _ax_axis(l2, :xaxis)[:exponentformat] == "power"
        # A log axis created by relayout gets the power format with array ticks.
        rl = plot_scatter([1.0, 100.0], [1.0, 2.0])
        relayout!(rl; xaxis_type = "log")
        xticks!(rl, [1, 10, 100])
        @test _ax_axis(rl, :xaxis)[:exponentformat] == "power"
        @test _ax_get(_ax_axis(rl, :xaxis), :tickformat) === nothing

        # Linear axis: "~g" default; a later exponentformat drops it; a stale
        # "~g" goes when the axis becomes logarithmic.
        lin = plot_scatter([0.0, 1.0], [2.0, 3.0])
        xticks!(lin, [0, 0.5, 1])
        @test _ax_axis(lin, :xaxis)[:tickformat] == "~g"
        xticks!(lin; exponentformat = "e")
        @test _ax_get(_ax_axis(lin, :xaxis), :tickformat) === nothing
        @test _ax_axis(lin, :xaxis)[:exponentformat] == "e"
        lin2 = plot_scatter([1.0, 10.0], [2.0, 3.0])
        xticks!(lin2, [1, 10])
        relayout!(lin2; xaxis_type = "log")
        xticks!(lin2, [1, 10])
        @test _ax_get(_ax_axis(lin2, :xaxis), :tickformat) === nothing
        # An explicit user format is kept.
        xticks!(lin, [0, 1]; format = ".2f")
        xticks!(lin, [0, 0.5])
        @test _ax_axis(lin, :xaxis)[:tickformat] == ".2f"

        # A6: tick width/length; explicit minor ticks follow the length.
        xticks!(lin; tickwidth = 2, ticklen = 8, minor = true, direction = :inside, angle = 30)
        ax = _ax_axis(lin, :xaxis)
        @test (ax[:tickwidth], ax[:ticklen], ax[:ticks], ax[:tickangle]) == (2, 8, "inside", 30)
        @test _ax_get(_ax_get(ax, :minor), :ticklen) ≈ 4.8
        @test _ax_get(_ax_get(ax, :minor), :ticks) == "inside"
        xticks!(lin; ticklen = 10)
        @test _ax_get(_ax_get(_ax_axis(lin, :xaxis), :minor), :ticklen) ≈ 6.0

        # pi-fraction labels go through the mathtext layer.
        pf = plot_scatter(collect(range(0, 2π; length = 20)), sin.(range(0, 2π; length = 20)))
        xticks!(pf, [0, π, 2π], ["0", "\$\\pi\$", "\$2\\pi\$"])
        @test _ax_axis(pf, :xaxis)[:ticktext] == PlotlySupply._label.(["0", "\$\\pi\$", "\$2\\pi\$"])

        # Cell (1,2) only changes xaxis2; yticks! secondary_y on a twin cell.
        sf = _ax_grid(1, 2)
        others = Dict(k => _ax_json(v) for (k, v) in sf.plot.layout.fields if k != :xaxis2)
        @test xticks!(sf, [1, 2, 3]; row = 1, col = 2) === sf
        @test _ax_axis(sf, :xaxis2)[:tickvals] == [1.0, 2.0, 3.0]
        @test all(_ax_json(sf.plot.layout.fields[k]) == v for (k, v) in others)
        st = subplots(1, 1; sync = false, specs = fill(Spec(secondary_y = true), 1, 1))
        plot_scatter!(st, 1:3, [1.0, 2, 3])
        plot_scatter!(st, 1:3, [10.0, 20, 30]; secondary_y = true)
        yticks!(st, [10, 20, 30]; secondary_y = true)
        tsec = _AX._cell_target(st; secondary_y = true)
        @test _ax_axis(st, tsec.ykey)[:tickvals] == [10.0, 20.0, 30.0]
        @test _ax_get(_ax_axis(st, :yaxis), :tickvals) === nothing
        scene = plot_scatter3d([1.0, 2.0], [1.0, 2.0], [1.0, 2.0])
        @test _ax_throws(() -> xticks!(scene, [1, 2]), "xticks!: tick control applies to Cartesian (xy) cells")
        @test _ax_throws(() -> yticks!(fig, [1]; show = true), "yticks!: figure helpers have no `show` keyword")
        @test_throws MethodError xticks!(fig, [1e-3]; bogus = 1)
    end

    @testset "axis_equal! (F9)" begin
        sf = _ax_grid(2, 2)
        xrange!(sf, (-3, 3); row = 2, col = 1)
        @test axis_equal!(sf; row = 2, col = 1, ratio = 2) === sf
        t = _AX._cell_target(sf; row = 2, col = 1)
        y = _ax_axis(sf, t.ykey)
        @test (y[:scaleanchor], y[:scaleratio], y[:constrain]) == (t.xref, 2.0, "domain")
        @test _ax_axis(sf, t.xkey)[:constrain] == "domain"
        @test _ax_axis(sf, t.xkey)[:range] == [-3, 3]
        @test _ax_get(_ax_axis(sf, :yaxis), :scaleanchor) === nothing
        fig = plot_scatter([0.0, 1.0], [0.0, 1.0])
        @test axis_equal!(fig) === nothing
        @test _ax_axis(fig, :yaxis)[:scaleanchor] == "x"
        @test _ax_throws(() -> axis_equal!(fig; ratio = 0), "axis_equal!: `ratio` must be finite and positive")
        sc = subplots(1, 1; sync = false, specs = fill(Spec(kind = "scene"), 1, 1))
        axis_equal!(sc)
        @test _ax_get(sc.plot.layout.fields[:scene], :aspectmode) == "data"
    end

    @testset "axis_off! (F9)" begin
        fig = plot_scatter([0.0, 1.0], [0.0, 1.0])
        key = _AX._ensure_twin_y!(fig)
        @test axis_off!(fig) === nothing
        for k in (:xaxis, :yaxis, key)
            @test _ax_field(fig, k, :visible) === false
        end
        sf = _ax_grid(1, 2)
        axis_off!(sf; row = 1, col = 2)
        @test _ax_field(sf, :xaxis2, :visible) === false
        @test _ax_field(sf, :yaxis2, :visible) === false
        @test _ax_field(sf, :xaxis, :visible) === nothing
        sc = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "polar")])
        axis_off!(sc; row = 1, col = 1)
        scene = sc.plot.layout.fields[:scene]
        for letter in ('x', 'y', 'z')
            axis = _ax_get(scene, Symbol(letter, "axis"))
            @test _ax_get(axis, :visible) === false && _ax_get(axis, :showbackground) === false
        end
        @test _ax_throws(() -> axis_off!(sc; row = 1, col = 2), "axis_off!: applies to Cartesian (xy) and 3-D scene cells")
    end

    @testset "spines! (F10)" begin
        fig = plot_scatter([0.0, 1.0], [0.0, 1.0])
        @test spines!(fig; style = :open) === nothing
        for k in (:xaxis, :yaxis)
            @test _ax_field(fig, k, :mirror) === false && _ax_field(fig, k, :showline) === true
        end
        spines!(fig; style = "none")
        @test _ax_field(fig, :xaxis, :showline) === false
        spines!(fig; color = :red, linewidth = 2)
        @test _ax_field(fig, :xaxis, :showline) === true && _ax_field(fig, :xaxis, :mirror) === true
        @test _ax_field(fig, :yaxis, :linecolor) == "#FF0000" && _ax_field(fig, :yaxis, :linewidth) == 2
        before = _ax_json(fig.layout)
        @test _ax_throws(() -> spines!(fig; style = :half), "spines!: `style` must be :box, :open or :none")
        @test _ax_throws(() -> spines!(fig; linewidth = -1), "`linewidth` must be a finite number >= 0")
        @test _ax_throws(() -> spines!(fig; color = "notacolor"), "spines!")
        @test _ax_json(fig.layout) == before
        sf = _ax_grid(2, 2)
        subplot!(sf, 1, 2)
        @test spines!(sf; style = :open, cells = :all) === sf
        for k in (:xaxis, :xaxis2, :xaxis3, :xaxis4, :yaxis, :yaxis2, :yaxis3, :yaxis4)
            @test _ax_field(sf, k, :mirror) === false
        end
        @test (sf.current_row, sf.current_col) == (1, 2)
        @test _ax_throws(() -> spines!(sf; cells = :all, row = 1, col = 1), "do not combine it")
        @test _ax_throws(() -> spines!(sf; cells = :some), "`cells` must be :all")
        spines!(sf; style = :none, row = 2, col = 2)
        @test _ax_field(sf, :xaxis4, :showline) === false && _ax_field(sf, :xaxis, :showline) === true
        @test (sf.current_row, sf.current_col) == (2, 2)
    end

    @testset "grid! (F10)" begin
        fig = plot_scatter([0.0, 1.0], [0.0, 1.0])
        @test grid!(fig; axis = :y, alpha = 0.2) === nothing
        @test _ax_field(fig, :xaxis, :showgrid) === false
        @test _ax_field(fig, :yaxis, :showgrid) === true
        @test _ax_field(fig, :yaxis, :gridcolor) == "rgba(0,0,0,0.2)"
        @test _ax_field(fig, :xaxis, :gridcolor) === nothing
        grid!(fig; color = "red", alpha = 0.5, width = 2, dash = "--")
        for k in (:xaxis, :yaxis)
            @test _ax_field(fig, k, :gridcolor) == "rgba(255,0,0,0.5)"
            @test _ax_field(fig, k, :gridwidth) == 2
            @test _ax_field(fig, k, :griddash) == "dash"
        end
        grid!(fig; dash = "4px,2px")
        @test _ax_field(fig, :xaxis, :griddash) == "4px,2px"
        grid!(fig; axis = :none)
        @test _ax_field(fig, :xaxis, :showgrid) === false && _ax_field(fig, :yaxis, :showgrid) === false
        before = _ax_json(fig.layout)
        @test _ax_throws(() -> grid!(fig; axis = :z), "grid!: `axis` must be")
        @test _ax_throws(() -> grid!(fig; which = :all), "`which` must be")
        @test _ax_throws(() -> grid!(fig; dash = "wiggly"), "`dash` must be one of")
        @test _ax_throws(() -> grid!(fig; alpha = 2), "`alpha` must be a number in [0, 1]")
        @test _ax_throws(() -> grid!(fig; axis = :none, color = "red"), "`axis = :none` hides them all")
        @test _ax_json(fig.layout) == before

        # Minor grid on a log axis with explicit majors: mantissas 1..9.
        lg = plot_scatter([1e-2, 1e2], [1.0, 2.0]; xscale = "log")
        xticks!(lg, [1e-2, 1, 1e2])
        grid!(lg; which = :both)
        mn = _ax_get(_ax_axis(lg, :xaxis), :minor)
        @test _ax_get(mn, :showgrid) === true && _ax_get(mn, :tickmode) == "array"
        @test _ax_get(mn, :tickvals)[1:2] ≈ [0.02, 0.03]
        @test _ax_field(lg, :xaxis, :showgrid) === true
        # The y axis has automatic ticks: Plotly's own minor positions.
        @test _ax_get(_ax_get(_ax_axis(lg, :yaxis), :minor), :tickvals) === nothing
        grid!(lg; which = :major)
        @test _ax_get(_ax_get(_ax_axis(lg, :xaxis), :minor), :showgrid) === false
        sf = _ax_grid(1, 2)
        grid!(sf; axis = :x, cells = :all)
        @test all(_ax_field(sf, k, :showgrid) === false for k in (:yaxis, :yaxis2))
        @test all(_ax_field(sf, k, :showgrid) === true for k in (:xaxis, :xaxis2))
    end

    @testset "secondary_xaxis! (F11)" begin
        c = 299792.458
        λ = collect(400.0:5:700.0)
        fig = plot_scatter(λ, exp.(-((λ .- 550) ./ 60) .^ 2))
        ticks = [450.0, 500.0, 600.0, 700.0]
        @test secondary_xaxis!(fig, l -> c / l, ν -> c / ν; ticks = ticks, title = "frequency (THz)") === nothing
        ax2 = _ax_axis(fig, :xaxis2)
        @test (ax2[:overlaying], ax2[:matches], ax2[:anchor], ax2[:side]) == ("x", "x", "y", "top")
        @test ax2[:tickvals] ≈ c ./ ticks
        @test ax2[:ticktext] == ["450", "500", "600", "700"]
        @test ax2[:showgrid] === false && ax2[:tickmode] == "array"
        @test fig.layout[:xaxis2_title_text] == "frequency (THz)"
        # The automatic primary range is frozen to the data extent.
        @test _ax_field(fig, :xaxis, :range) == [400.0, 700.0]
        @test _ax_field(fig, :xaxis, :autorange) === false
        dummies = [t for t in fig.data if get(t.fields, :name, "") == "plotlysupply:secondary_xaxis:x"]
        @test length(dummies) == 1
        @test dummies[1].fields[:visible] === false && dummies[1].fields[:xaxis] == "x2"
        # Idempotent: a second call reuses the axis and the dummy trace.
        ntraces = length(fig.data)
        secondary_xaxis!(fig, l -> c / l, ν -> c / ν; ticks = ticks, title = "frequency (THz)")
        @test length(fig.data) == ntraces
        @test !haskey(fig.layout.fields, :xaxis3)
        # Automatic ticks: 1-2-5 values inside f(range), positioned at finv.
        secondary_xaxis!(fig, l -> c / l, ν -> c / ν)
        ax2 = _ax_axis(fig, :xaxis2)
        @test all(400 - 1e-9 <= x <= 700 + 1e-9 for x in ax2[:tickvals])
        @test length(ax2[:tickvals]) >= 3
        @test all(t -> !endswith(t, ".0"), ax2[:ticktext])
        @test ax2[:ticktext] == ["450", "500", "550", "600", "650", "700"]
        @test ax2[:tickvals] ≈ c ./ [450, 500, 550, 600, 650, 700]

        before = _ax_json(fig.layout)
        @test _ax_throws(() -> secondary_xaxis!(fig, l -> (l - 550)^2, identity), "`f` must be strictly monotone")
        @test _ax_throws(() -> secondary_xaxis!(fig, l -> c / l, ν -> ν), "`finv` does not invert `f`")
        @test _ax_throws(() -> secondary_xaxis!(fig, l -> c / l, ν -> c / ν; side = :bottom), "already on the bottom")
        @test _ax_throws(() -> secondary_xaxis!(fig, l -> c / l, ν -> c / ν; side = :left), "`side` must be :top or :bottom")
        @test _ax_throws(() -> secondary_xaxis!(fig, l -> c / l, ν -> c / ν; ticklabels = ["a"]), "`ticklabels` need explicit `ticks`")
        @test _ax_throws(() -> secondary_xaxis!(fig, l -> c / l, ν -> c / ν; ticks = [500.0], ticklabels = ["a", "b"]), "got 2 tick labels for 1 tick values")
        @test _ax_throws(() -> secondary_xaxis!(fig, l -> c / l, ν -> c / ν; ticks = [NaN]), "a tick value must be a finite real number")
        @test _ax_json(fig.layout) == before

        # Log primary axis: the secondary axis is log too, with decade ticks.
        lg = plot_scatter([1.0, 10.0, 100.0, 1000.0], [1.0, 2.0, 3.0, 4.0]; xscale = "log")
        secondary_xaxis!(lg, x -> 1 / x, y -> 1 / y; title = "1/x")
        a2 = _ax_axis(lg, :xaxis2)
        @test a2[:type] == "log"
        @test _ax_field(lg, :xaxis, :range) ≈ [0.0, 3.0]
        @test a2[:ticktext][1] == "0.001" && a2[:ticktext][end] == "1"
        @test a2[:tickvals] ≈ 1 ./ parse.(Float64, a2[:ticktext])

        # Unknown range and non-numeric axes are errors.
        empty = Plot(GenericTrace[], Layout(xaxis = attr(type = "linear")))
        @test _ax_throws(() -> secondary_xaxis!(empty, x -> 2x, y -> y / 2), "the x range of this cell is unknown")

        # A SubplotFigure cell other than (1,1).
        sf = _ax_grid(1, 2)
        @test secondary_xaxis!(sf, x -> 2x, y -> y / 2; ticks = [2, 4, 6], row = 1, col = 2) === sf
        t = _AX._cell_target(sf; row = 1, col = 2)
        key = Symbol("xaxis", _AX._axes_highest_axis_index(sf.plot, 'x'))
        sec = _ax_axis(sf, key)
        @test (sec[:overlaying], sec[:anchor], sec[:matches]) == (t.xref, t.yref, t.xref)
        @test sec[:tickvals] ≈ [1.0, 2.0, 3.0]
        @test (sf.current_row, sf.current_col) == (1, 2)

        # Number formatting and 1-2-5 linear ticks.
        @test _AX._axes_format_number(0.3) == "0.3"
        @test _AX._axes_format_number(450.0) == "450"
        @test _AX._axes_format_number(-0.0) == "0"
        @test _AX._axes_format_number(1e-5) == "1e-5"
        @test _AX._axes_format_number(2.5e-7) == "2.5e-7"
        @test _AX._axes_format_number(3.0e20) == "3e20"
        @test _AX._axes_linear_ticks(0.0, 1.0, "t") == [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
        @test _AX._axes_linear_ticks(428.3, 749.5, "t") == [450.0, 500.0, 550.0, 600.0, 650.0, 700.0]
        @test _AX._axes_linear_ticks(-0.031, 0.029, "t") == [-0.03, -0.02, -0.01, 0.0, 0.01, 0.02]
        @test _ax_throws(() -> _AX._axes_linear_ticks(1e17, 1e17 + 16, "t"), "too narrow for its magnitude")
    end

    @testset "inset! (F12)" begin
        sf = _ax_grid(2, 2)
        host = _AX._cell_target(sf; row = 2, col = 1)
        k = inset!(sf, (0.5, 0.5, 0.4, 0.4); row = 2, col = 1)
        @test k == 1 && length(sf.insets) == 1
        rec = sf.insets[1]
        @test (rec.row, rec.col) == (2, 1)
        @test rec.xkey == :xaxis5 && rec.ykey == :yaxis5 && (rec.xref, rec.yref) == ("x5", "y5")
        hx, hy = host.xdomain, host.ydomain
        @test collect(rec.xdomain) ≈ [hx[1] + 0.5 * (hx[2] - hx[1]), hx[1] + 0.9 * (hx[2] - hx[1])]
        @test collect(rec.ydomain) ≈ [hy[1] + 0.5 * (hy[2] - hy[1]), hy[1] + 0.9 * (hy[2] - hy[1])]
        xi = _ax_axis(sf, :xaxis5)
        @test xi[:anchor] == "y5" && _ax_axis(sf, :yaxis5)[:anchor] == "x5"
        @test xi[:domain] ≈ collect(rec.xdomain)
        @test (xi[:showline], xi[:mirror], xi[:ticks], xi[:automargin]) == (true, true, "outside", false)
        @test (sf.current_row, sf.current_col) == (2, 1)
        ti = _AX._cell_target(sf; inset = k)
        @test (ti.xkey, ti.ykey) == (:xaxis5, :yaxis5)

        # coords = :paper and a shared, logarithmic host axis.
        lgsf = subplots(1, 1; sync = false)
        plot_scatter!(lgsf, [1.0, 10.0, 100.0], [1.0, 2.0, 3.0]; yscale = "log")
        k2 = inset!(lgsf, [0.1, 0.6, 0.3, 0.3]; coords = :paper, sharey = true)
        r2 = lgsf.insets[k2]
        @test collect(r2.xdomain) ≈ [0.1, 0.4] && collect(r2.ydomain) ≈ [0.6, 0.9]
        yi = _ax_axis(lgsf, r2.ykey)
        @test yi[:matches] == "y" && yi[:type] == "log"
        @test _ax_get(_ax_axis(lgsf, r2.xkey), :matches) === nothing

        # Traces routed by explicit axis references land on the inset axes.
        addtraces!(sf.plot, scatter(x = [1.5, 2.0], y = [2.0, 4.0], xaxis = rec.xref, yaxis = rec.yref))
        @test _AX._axis_data_extent(sf, rec.xkey) == (1.5, 2.0)

        # Every helper accepts inset = k and touches only the inset axes.
        others = Dict(kk => _ax_json(v) for (kk, v) in sf.plot.layout.fields if !(kk in (:xaxis5, :yaxis5)))
        xlabel!(sf, "zoom x"; inset = k)
        ylabel!(sf, "zoom y"; inset = k)
        xrange!(sf, (1.5, 2.0); inset = k)
        yrange!(sf, (2, 4); inset = k)
        xticks!(sf, [1.5, 1.75, 2.0]; inset = k)
        yticks!(sf, [2, 3, 4]; inset = k, minor = true)
        grid!(sf; axis = :y, inset = k)
        spines!(sf; color = "gray", inset = k)
        axis_equal!(sf; inset = k)
        @test all(_ax_json(sf.plot.layout.fields[kk]) == v for (kk, v) in others)
        @test sf.plot.layout[:xaxis5_title_text] == "zoom x"
        @test _ax_field(sf, :xaxis5, :range) == [1.5, 2.0]
        @test _ax_field(sf, :yaxis5, :scaleanchor) == "x5"
        @test _ax_field(sf, :xaxis5, :linecolor) == "#808080"
        secondary_xaxis!(sf, x -> 10x, y -> y / 10; ticks = [16, 18, 20], inset = k)
        @test _ax_axis(sf, :xaxis6)[:overlaying] == "x5"
        axis_off!(sf; inset = k)
        @test all(_ax_field(sf, kk, :visible) === false for kk in (:xaxis5, :yaxis5, :xaxis6))
        @test _ax_field(sf, :xaxis, :visible) === nothing

        # Validation; a failed call registers nothing.
        before = _ax_json(sf.plot.layout)
        n = length(sf.insets)
        @test _ax_throws(() -> inset!(sf, (0.5, 0.5, 0.6, 0.4)), "inset!: x0 + width = 1.1 exceeds 1")
        @test _ax_throws(() -> inset!(sf, (0.5, 0.7, 0.4, 0.4)), "y0 + height")
        @test _ax_throws(() -> inset!(sf, (-0.1, 0.5, 0.4, 0.4)), "bounds `x0` must be a number in [0, 1]")
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.0, 0.2)), "width and height must be positive")
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.2)), "`bounds` must be (x0, y0, width, height)")
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.2, 0.2); coords = :figure), "`coords` must be :axes")
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.2, 0.2); show = true), "inset!: figure helpers have no `show` keyword")
        @test _ax_throws(() -> xlabel!(sf, "x"; inset = 9), "unknown inset id 9")
        @test _ax_throws(() -> xlabel!(sf, "x"; inset = k, row = 1, col = 1), "inset 1 belongs to cell (2, 1)")
        @test _ax_json(sf.plot.layout) == before && length(sf.insets) == n
        sc = subplots(1, 1; sync = false, specs = fill(Spec(kind = "scene"), 1, 1))
        @test _ax_throws(() -> inset!(sc, (0.1, 0.1, 0.2, 0.2)), "inset!: an inset applies to Cartesian (xy) cells")
        @test isempty(sc.insets)
        @test _ax_throws(() -> inset!(plot_scatter([1.0], [1.0]), (0.1, 0.1, 0.2, 0.2)), "inset! needs a SubplotFigure; use subplots(1,1; sync=false)")
        # Ids follow creation order.
        @test inset!(sf, (0.05, 0.05, 0.3, 0.3); row = 1, col = 2) == 2
    end

    @testset "range bounds by axis type; matches to unknown axes" begin
        cat = plot_scatter([1.0, 2.0, 3.0], [1.0, 2.0, 3.0])
        relayout!(cat; xaxis_type = "category", yaxis_type = "linear")
        before = _ax_json(cat.layout)
        @test _ax_throws(() -> xrange!(cat, ("a", "c")), "xrange!: a category axis needs numeric range bounds")
        @test _ax_throws(() -> yrange!(cat, ("a", "c")), "yrange!: a linear axis needs numeric range bounds")
        @test _ax_json(cat.layout) == before
        xrange!(cat, (-0.5, 2.5))
        @test _ax_field(cat, :xaxis, :range) == [-0.5, 2.5]
        dt = plot_scatter(["2020-01-01", "2020-03-01"], [1.0, 2.0])
        relayout!(dt; xaxis_type = "date")
        xrange!(dt, ("2020-01-15", "2020-02-15"))
        @test _ax_field(dt, :xaxis, :range) == ["2020-01-15", "2020-02-15"]
        @test _ax_throws(() -> xrange!(dt, ("2020-01-15", "2020-01-15")), "the range bounds must differ")
        # A `matches` reference to an axis plotly.js does not know is ignored
        # by plotly.js, so the range stays on the axis itself.
        m = plot_scatter([1.0, 2.0], [1.0, 2.0])
        relayout!(m; xaxis_matches = "x7")
        xrange!(m, (0, 1))
        @test _ax_field(m, :xaxis, :range) == [0, 1]
        @test !haskey(m.layout.fields, :xaxis7)
        # An axis that only a trace references exists for plotly.js.
        m2 = plot_scatter([1.0, 2.0], [1.0, 2.0])
        push!(m2.data, scatter(x = [0.0, 5.0], y = [1.0, 2.0], xaxis = "x3"))
        relayout!(m2; xaxis_matches = "x3")
        xrange!(m2, (0, 4))
        @test _ax_field(m2, :xaxis3, :range) == [0, 4]
        @test _ax_field(m2, :xaxis, :range) === nothing
        # Scene axes: numeric bounds on a category scene axis.
        f3 = plot_scatter3d([1.0, 2.0], [1.0, 2.0], [1.0, 2.0])
        relayout!(f3; scene_yaxis_type = "category")
        @test _ax_throws(() -> yrange!(f3, ("a", "b")), "a category axis needs numeric range bounds")
    end

    @testset "secondary_xaxis!: figure title clearance, copied axis style" begin
        c = 299792.458
        λ = collect(400.0:5:700.0)
        y = exp.(-((λ .- 550) ./ 60) .^ 2)
        fig = plot_scatter(λ, y; title = "spectrum")
        relayout!(fig; xaxis_tickfont = attr(size = 16), xaxis_title_font = attr(size = 18, family = "Arial"),
            xaxis_linecolor = "#123456", xaxis_linewidth = 2)
        secondary_xaxis!(fig, l -> c / l, ν -> c / ν; title = "frequency (THz)")
        title = fig.layout.fields[:title]
        @test _ax_get(title, :text) == "spectrum"
        @test (_ax_get(title, :yref), _ax_get(title, :y), _ax_get(title, :yanchor)) == ("paper", 1, "bottom")
        @test _ax_get(title, :automargin) === true
        pad = _ax_get(_ax_get(title, :pad), :b)
        # tick labels 16 px, title 18 px, standoff 15, ticks 5, linewidth 2, gap 6.
        @test pad == ceil(5 + 1.3 * 16 + 1 + 15 + 1.3 * 18 + 6)
        ax2 = _ax_axis(fig, :xaxis2)
        @test _ax_get(_ax_get(ax2, :tickfont), :size) == 16
        @test _ax_get(_ax_get(_ax_get(ax2, :title), :font), :family) == "Arial"
        @test _ax_get(_ax_get(ax2, :title), :text) == "frequency (THz)"
        @test (ax2[:linecolor], ax2[:linewidth]) == ("#123456", 2)
        @test _ax_get(ax2, :tickfont) !== _ax_get(fig.layout.fields[:xaxis], :tickfont)
        @test ax2[:automargin] === true
        # Re-calling keeps the larger clearance (idempotent placement).
        secondary_xaxis!(fig, l -> c / l, ν -> c / ν)
        @test _ax_get(_ax_get(fig.layout.fields[:title], :pad), :b) == pad
        # Larger fonts need more room.
        big = plot_scatter(λ, y; fontsize = 20)
        secondary_xaxis!(big, l -> c / l, ν -> c / ν; title = "THz")
        small = plot_scatter(λ, y)
        secondary_xaxis!(small, l -> c / l, ν -> c / ν; title = "THz")
        pad_of(f) = _ax_get(_ax_get(f.layout.fields[:title], :pad), :b)
        @test pad_of(big) > pad_of(small)
        # Without an axis title only the tick labels need room.
        notitle = plot_scatter(λ, y)
        secondary_xaxis!(notitle, l -> c / l, ν -> c / ν)
        @test pad_of(notitle) < pad_of(small)
        # A title the user placed is left alone; side = :bottom never moves it.
        placed = plot_scatter(λ, y; title = "placed")
        relayout!(placed; title_y = 0.95)
        secondary_xaxis!(placed, l -> c / l, ν -> c / ν)
        @test _ax_get(placed.layout.fields[:title], :yref) === nothing
        @test _ax_get(placed.layout.fields[:title], :y) == 0.95
        bottom = plot_scatter(λ, y; title = "b")
        relayout!(bottom; xaxis_side = "top")
        secondary_xaxis!(bottom, l -> c / l, ν -> c / ν; side = :bottom)
        @test _ax_get(bottom.layout.fields[:title], :yref) === nothing
        # A bare-string title keeps its text.
        bare = plot_scatter(λ, y)
        bare.layout.fields[:title] = "bare"
        secondary_xaxis!(bare, l -> c / l, ν -> c / ν)
        @test _ax_get(bare.layout.fields[:title], :text) == "bare"
        @test _ax_get(bare.layout.fields[:title], :yref) == "paper"

        # Subplots: only a top-row cell moves the figure title; an inset never.
        sf = _ax_grid(2, 1)
        secondary_xaxis!(sf, x -> 2x, v -> v / 2; row = 2, col = 1)
        @test _ax_get(get(sf.plot.layout.fields, :title, nothing), :yref) === nothing
        secondary_xaxis!(sf, x -> 2x, v -> v / 2; row = 1, col = 1)
        @test _ax_get(sf.plot.layout.fields[:title], :yref) == "paper"
        si = _ax_grid(1, 1)
        k = inset!(si, (0.5, 0.5, 0.4, 0.4))
        addtraces!(si.plot, scatter(x = [1.0, 2.0], y = [1.0, 2.0], xaxis = si.insets[k].xref, yaxis = si.insets[k].yref))
        secondary_xaxis!(si, x -> 2x, v -> v / 2; inset = k)
        sec = Symbol("xaxis", _AX._axes_highest_axis_index(si.plot, 'x'))
        @test _ax_axis(si, sec)[:automargin] === false
        @test _ax_axis(si, sec)[:overlaying] == si.insets[k].xref
        @test _ax_get(get(si.plot.layout.fields, :title, nothing), :yref) === nothing
    end

    @testset "_ensure_twin_y! copies the primary y line styling" begin
        fig = plot_scatter([1.0, 2.0], [3.0, 4.0])
        relayout!(fig; yaxis_linecolor = "#abcdef", yaxis_linewidth = 3, yaxis_ticklen = 7)
        key = _AX._ensure_twin_y!(fig)
        twin = fig.layout.fields[key]
        @test (twin[:linecolor], twin[:linewidth], twin[:ticklen]) == ("#abcdef", 3, 7)
        @test twin[:overlaying] == "y" && twin[:side] == "right"
    end

    @testset "labels keep title fonts; insets survive later cell plotting" begin
        f = plot_scatter([1.0, 2.0], [1.0, 2.0])
        relayout!(f; xaxis_title_font = attr(size = 21, family = "Arial"))
        xlabel!(f, "new")
        @test _ax_get(_ax_get(_ax_get(f.layout.fields[:xaxis], :title), :font), :size) == 21
        @test _ax_get(_ax_get(f.layout.fields[:xaxis], :title), :text) == "new"
        f3 = plot_scatter3d([1.0, 2.0], [1.0, 2.0], [1.0, 2.0])
        relayout!(f3; scene_zaxis_title_font = attr(size = 19))
        zlabel!(f3, "Z")
        ztitle = _ax_get(_ax_get(f3.layout.fields[:scene], :zaxis), :title)
        @test _ax_get(ztitle, :text) == "Z"
        @test _ax_get(_ax_get(ztitle, :font), :size) == 19

        sf = subplots(1, 2; sync = false)
        xs = collect(0:0.5:10)
        plot_scatter!(sf, xs, sin.(xs); row = 1, col = 1, legend = "sin")
        k = inset!(sf, (0.5, 0.55, 0.45, 0.4); row = 1, col = 1)
        rec = sf.insets[k]
        addtraces!(sf.plot, scatter(x = xs[1:5], y = xs[1:5], xaxis = rec.xref, yaxis = rec.yref))
        xrange!(sf, (0, 2); inset = k)
        secondary_xaxis!(sf, x -> 2x, v -> v / 2; row = 1, col = 1)
        plot_scatter!(sf, xs, cos.(xs); row = 1, col = 2, legend = "cos")
        plot_scatter!(sf, xs, xs; row = 1, col = 1, legend = "line")
        @test length(sf.insets) == 1
        @test _ax_field(sf, rec.xkey, :range) == [0, 2]
        @test _ax_field(sf, rec.xkey, :anchor) == rec.yref
        cell12 = _AX._cell_target(sf; row = 1, col = 2)
        cos_trace = only(filter(tr -> get(tr.fields, :name, nothing) == "cos", sf.plot.data))
        @test (cos_trace.fields[:xaxis], cos_trace.fields[:yaxis]) == (cell12.xref, cell12.yref)
        line_trace = only(filter(tr -> get(tr.fields, :name, nothing) == "line", sf.plot.data))
        @test (line_trace.fields[:xaxis], line_trace.fields[:yaxis]) == ("x", "y")
        dummy = only(filter(tr -> startswith(string(get(tr.fields, :name, "")), "plotlysupply:secondary_xaxis"), sf.plot.data))
        @test dummy.fields[:visible] === false && dummy.fields[:showlegend] === false
        # The next new axis index skips the inset's and the secondary axis's.
        k2 = inset!(sf, (0.1, 0.1, 0.3, 0.3); row = 1, col = 2)
        used = Set([rec.xkey, _AX._axis_layout_key(String(dummy.fields[:xaxis]), :x)])
        @test length(used) == 2
        @test !(sf.insets[k2].xkey in used)
    end

    @testset "SyncPlot-backed SubplotFigure: inset!, helpers, rollback" begin
        base = subplots(1, 2; sync = false)
        plot_scatter!(base, [1.0, 2.0, 3.0], [1.0, 4.0, 9.0]; row = 1, col = 1)
        plot_scatter!(base, [1.0, 2.0, 3.0], [1.0, 4.0, 9.0]; row = 1, col = 2)
        sp, state = _ax_syncplot(base.plot)
        sf = SubplotFigure(sp, 1, 2, 1, 1, false, :topright, (0.02, 0.03), "", "", 1.0)
        n = length(state.scripts)
        k = inset!(sf, (0.55, 0.55, 0.4, 0.4); row = 1, col = 2)
        @test k == 1 && length(sf.insets) == 1 && sf.insets[1].row == 1 && sf.insets[1].col == 2
        @test length(state.scripts) > n
        @test haskey(sp.plot.layout.fields, sf.insets[1].xkey)
        xlabel!(sf, "zoom"; inset = k)
        xrange!(sf, (1.5, 2.5); inset = k)
        grid!(sf; axis = :none, inset = k)
        @test sp.plot.layout[Symbol(sf.insets[1].xkey, :_title_text)] == "zoom"
        @test _ax_field(sp.plot, sf.insets[1].xkey, :range) == [1.5, 2.5]
        @test (sf.current_row, sf.current_col) == (1, 2)
        before = _ax_json(sp.plot.layout)
        n = length(state.scripts)
        @test _ax_throws(() -> inset!(sf, (0.9, 0.9, 0.2, 0.2)), "exceeds 1")
        @test _ax_throws(() -> xrange!(sf, (1, 1); inset = k), "the range bounds must differ")
        @test _ax_json(sp.plot.layout) == before
        @test length(state.scripts) == n && length(sf.insets) == 1
    end
end
