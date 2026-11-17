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
        # #19/#56 (mutator part): LaTeXString and SubString labels are accepted.
        xlabel!(fig, L"\alpha^2")
        @test fig.layout[:xaxis_title_text] == PlotlySupply._label("\$\\alpha^2\$")
        ylabel!(fig, split("signal level")[1])
        @test fig.layout[:yaxis_title_text] == "signal"
        f3l = plot_scatter3d([1.0, 2.0], [1.0, 2.0], [1.0, 2.0])
        zlabel!(f3l, L"z")
        @test _ax_get(_ax_get(_ax_get(f3l.layout.fields[:scene], :zaxis), :title), :text) ==
            _AX._axes_label3d("\$z\$")
        ylabel!(fig, "signal")
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
        @test _ax_throws(() -> xrange!(fig, (1, missing)), "xrange!: `range`: an open bound of a one-sided limit is written `nothing`")
        @test _ax_throws(() -> xrange!(fig, [nothing, 0.5]), "xrange!: `range` fixes one end of the axis beyond all of its data")
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

    @testset "D11/G41: one-sided limits through xrange!/yrange!/zrange!" begin
        _ao(p, key) = _ax_field(p, key, :autorangeoptions)
        fig = plot_scatter([1.0, 2.0, 3.0], [1.0, 4.0, 2.0])
        @test yrange!(fig, (0, nothing)) === nothing
        @test _ax_field(fig, :yaxis, :autorange) === true
        @test _ax_field(fig, :yaxis, :range) === nothing
        @test _ax_get(_ao(fig, :yaxis), :minallowed) == 0
        xrange!(fig, (nothing, 10))
        @test _ax_get(_ao(fig, :xaxis), :maxallowed) == 10
        @test _ax_get(_ao(fig, :xaxis), :minallowed) === nothing
        # A full range replaces the limit; the sentinel clears both.
        xrange!(fig, (0, 5))
        @test _ax_field(fig, :xaxis, :range) == [0, 5] && _ao(fig, :xaxis) === nothing
        yrange!(fig, nothing)
        @test _ax_field(fig, :yaxis, :autorange) === true && _ao(fig, :yaxis) === nothing
        # Reversed axes keep their direction; the first bound is the start.
        xrange!(fig, (5, 0))
        xrange!(fig, (nothing, -2))
        @test _ax_field(fig, :xaxis, :autorange) == "reversed"
        @test _ax_get(_ao(fig, :xaxis), :minallowed) == -2
        xrange!(fig, nothing)
        @test _ax_field(fig, :xaxis, :autorange) == "reversed"
        # Log axes take data units.
        lg = plot_scatter([0.1, 10.0], [1.0, 2.0]; xscale = "log")
        xrange!(lg, (0.01, nothing))
        @test _ax_get(_ao(lg, :xaxis), :minallowed) ≈ -2.0
        before = _ax_json(lg.layout)
        @test _ax_throws(() -> xrange!(lg, (0, nothing)), "xrange!: `range` bounds on a logarithmic axis are data values and must be positive")
        @test _ax_json(lg.layout) == before
        # Matched groups: the limit is on every member (plotly.js reads
        # autorangeoptions per axis), the autorange on the root.
        sf = subplots(2, 1; sync = false, shared_xaxes = true)
        plot_scatter!(sf, 1:10, collect(1.0:10.0); row = 1, col = 1)
        plot_scatter!(sf, 1:10, collect(10.0:-1:1.0); row = 2, col = 1)
        follower = _AX._cell_target(sf; row = 1, col = 1).xkey
        root = _AX._axes_match_root(sf, follower, "test")
        @test xrange!(sf, (-4, nothing); row = 1, col = 1) === sf
        for key in (root, follower)
            @test _ax_get(_ao(sf, key), :minallowed) == -4
        end
        @test _ax_field(sf, root, :autorange) === true
        xrange!(sf, (0, 3); row = 2, col = 1)
        @test _ax_field(sf, root, :range) == [0, 3]
        @test _ao(sf, root) === nothing && _ao(sf, follower) === nothing
        # Date axes: milliseconds since 1970.
        dt = plot_scatter(["2020-01-05", "2020-02-01"], [1.0, 2.0])
        relayout!(dt; xaxis_type = "date")
        xrange!(dt, ("2020-01-01", nothing))
        @test _ax_get(_ao(dt, :xaxis), :minallowed) == 1.5778368e12
        # Aspect-linked axes: resolved to a full range from the data now, also
        # when axis_equal! comes after the limit.
        e = plot_scatter([0.0, 2.0], [0.0, 1.0])
        xrange!(e, (-2, nothing))
        axis_equal!(e)
        @test _ax_field(e, :xaxis, :autorange) === false
        @test _ax_field(e, :xaxis, :range) ≈ [-2.0, 2.1]
        @test _ao(e, :xaxis) === nothing
        yrange!(e, (nothing, 3))
        @test _ax_field(e, :yaxis, :range) ≈ [-0.05, 3.0]
        @test _ax_field(e, :yaxis, :autorange) === false
        # Errors leave the figure unchanged.
        q = plot_scatter([1.0, 2.0], [1.0, 4.0])
        before = _ax_json(q.layout)
        @test _ax_throws(() -> yrange!(q, (20, nothing)), "yrange!: `range` fixes one end of the axis beyond all of its data")
        @test _ax_throws(() -> yrange!(q, (missing, 3)), "an open bound of a one-sided limit is written `nothing`")
        @test _ax_json(q.layout) == before
        # 3-D scenes: the open end comes from the data (+1/32 of the extent).
        f3 = plot_scatter3d([0.0, 1.0], [0.0, 1.0], [0.0, 1.0])
        zrange!(f3, (nothing, 2))
        zaxis = _ax_get(f3.layout.fields[:scene], :zaxis)
        @test _ax_get(zaxis, :range) ≈ [-1 / 32, 2.0]
        @test _ax_get(zaxis, :autorange) === false
        xrange!(f3, (-1, nothing))
        @test _ax_get(_ax_get(f3.layout.fields[:scene], :xaxis), :range) ≈ [-1.0, 1 + 1 / 32]
        before = _ax_json(f3.layout)
        @test _ax_throws(() -> zrange!(f3, (5, nothing)), "zrange!: `range` = (5, nothing) leaves no room for the data on the z axis")
        empty3 = subplots(1, 1; sync = false, specs = [Spec(kind = "scene");;])
        @test _ax_throws(() -> zrange!(empty3, (0, nothing)), "zrange!: `range` = (0, nothing) is a one-sided limit; on a 3-D scene its open end is taken from the data")
        @test _ax_json(f3.layout) == before
        # The docstrings describe the one-sided form.
        for f in (xrange!, yrange!, zrange!)
            doc = lowercase(replace(string(Base.Docs.doc(f)), r"\s+" => " "))
            @test occursin("nothing)", doc) && occursin("one-sided", doc)
        end
    end

    @testset "G33: equal bounds are an ArgumentError on every range path" begin
        fig = plot_scatter([1.0, 2.0], [1.0, 2.0])
        before = _ax_json(fig.layout)
        for (f, r) in ((xrange!, (2, 2)), (yrange!, [5.0, 5]), (xrange!, ("a", "a")))
            @test _ax_throws(() -> f(fig, r), "the range bounds must differ")
        end
        @test _ax_throws(() -> zrange!(plot_scatter3d([0.0], [0.0], [0.0]), (1, 1)), "zrange!: `range`: the range bounds must differ")
        @test _ax_json(fig.layout) == before
        @test _ax_throws(() -> _AX._validate_cartesian_options(fig, "t"; xrange = (2, 2)), "t: `xrange`: the range bounds must differ")
        @test _ax_throws(() -> plot_scatter([1.0, 2.0], [1.0, 2.0]; yrange = (5, 5)), "plot_scatter: `yrange`: the range bounds must differ")
    end

    @testset "Y26: scene ranges and axis_equal! keep the scene's proportions" begin
        pts = collect(0.0:0.1:1.0)
        f = plot_scatter3d(pts, pts, pts; aspectmode = "data")
        zrange!(f, [0, 4])
        scene = f.layout.fields[:scene]
        @test _ax_get(scene, :aspectmode) == "manual"
        ratio = _ax_get(scene, :aspectratio)
        # Drawn spans: x and y autorange 1 + 2/32, z the explicit 4.
        @test _ax_get(ratio, :z) ≈ 1.0
        @test _ax_get(ratio, :x) ≈ (17 / 16) / 4
        @test _ax_get(ratio, :y) ≈ (17 / 16) / 4
        # Back to automatic: the pinned ratios follow the data again.
        zrange!(f, nothing)
        ratio = _ax_get(f.layout.fields[:scene], :aspectratio)
        @test _ax_get(ratio, :x) ≈ 1.0 && _ax_get(ratio, :z) ≈ 1.0
        # An automatic camera is re-framed for the new box.
        g = plot_scatter3d(pts, pts, pts; aspectmode = "data")
        eye0 = _ax_get(_ax_get(_ax_get(g.layout.fields[:scene], :camera), :eye), :x)
        zrange!(g, [0, 4])
        eye1 = _ax_get(_ax_get(_ax_get(g.layout.fields[:scene], :camera), :eye), :x)
        @test eye0 !== nothing && eye1 !== nothing && eye1 != eye0
        # axis_equal! on a scene with an explicit range pins it too.
        h = plot_scatter3d(pts, 2 .* pts, pts)
        zrange!(h, [0, 2])
        axis_equal!(h)
        scene = h.layout.fields[:scene]
        @test _ax_get(scene, :aspectmode) == "manual"
        @test _ax_get(_ax_get(scene, :aspectratio), :z) ≈ 2 / (2 * 17 / 16)
        # Subplot scene cells get tick counts for their size.
        sf = subplots(1, 2; sync = false, specs = [Spec(kind = "scene") Spec(kind = "scene")])
        plot_scatter3d!(sf, pts, pts, pts; row = 1, col = 1)
        zrange!(sf, (0, 3); row = 1, col = 1)
        t = _AX._cell_target(sf; row = 1, col = 1)
        zaxis = _ax_get(sf.plot.layout.fields[t.scenekey], :zaxis)
        @test _ax_get(zaxis, :nticks) isa Integer
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
        # G7: a `which = :major` call leaves the minor grid alone.
        grid!(lg; which = :major)
        @test _ax_get(_ax_get(_ax_axis(lg, :xaxis), :minor), :showgrid) === true
        grid!(lg; axis = :none)
        @test _ax_get(_ax_get(_ax_axis(lg, :xaxis), :minor), :showgrid) === false
        @test _ax_field(lg, :xaxis, :showgrid) === false
        sf = _ax_grid(1, 2)
        grid!(sf; axis = :x, cells = :all)
        @test all(_ax_field(sf, k, :showgrid) === false for k in (:yaxis, :yaxis2))
        @test all(_ax_field(sf, k, :showgrid) === true for k in (:xaxis, :xaxis2))
    end

    @testset "G7: major and minor grids are set and styled separately" begin
        g = plot_scatter([1e-2, 1e2], [1.0, 2.0]; xscale = "log")
        grid!(g; which = :major, alpha = 0.5)
        grid!(g; which = :minor, alpha = 0.1, dash = ":")
        for k in (:xaxis, :yaxis)
            # The minor call styled axis.minor and left the major grid as set.
            @test _ax_field(g, k, :showgrid) === true
            @test _ax_field(g, k, :gridcolor) == "rgba(0,0,0,0.5)"
            @test _ax_field(g, k, :griddash) === nothing
            mn = _ax_get(_ax_axis(g, k), :minor)
            @test _ax_get(mn, :showgrid) === true
            @test _ax_get(mn, :gridcolor) == "rgba(0,0,0,0.1)"
            @test _ax_get(mn, :griddash) == "dot"
        end
        # A later major call restyles only the major grid.
        grid!(g; which = :major, width = 2)
        @test _ax_field(g, :xaxis, :gridwidth) == 2
        @test _ax_get(_ax_get(_ax_axis(g, :xaxis), :minor), :gridwidth) === nothing
        @test _ax_get(_ax_get(_ax_axis(g, :xaxis), :minor), :gridcolor) == "rgba(0,0,0,0.1)"
        # `axis` selects the axes of the named kind; the other axis hides it.
        grid!(g; axis = :y, which = :minor)
        @test _ax_get(_ax_get(_ax_axis(g, :xaxis), :minor), :showgrid) === false
        @test _ax_get(_ax_get(_ax_axis(g, :yaxis), :minor), :showgrid) === true
        @test _ax_field(g, :xaxis, :showgrid) === true
        # `which = :both` styles the major lines; the minor lines follow them.
        b = plot_scatter([0.0, 1.0], [0.0, 1.0])
        grid!(b; which = :both, color = :blue)
        @test _ax_field(b, :xaxis, :gridcolor) == "#0000FF"
        @test _ax_get(_ax_get(_ax_axis(b, :xaxis), :minor), :showgrid) === true
        @test _ax_get(_ax_get(_ax_axis(b, :xaxis), :minor), :gridcolor) === nothing
        # Linear axes get plotly.js's automatic minor positions.
        @test _ax_get(_ax_get(_ax_axis(b, :xaxis), :minor), :tickvals) === nothing
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

    @testset "helpers on every target write only the addressed axes (v3)" begin
        # Layout keys whose JSON differs between two snapshots.
        snapshot(fig) = Dict{Symbol, String}(Symbol(k) => _ax_json(v) for (k, v) in _AX._cmn_plot(fig).layout.fields)
        changed(a, b) = Set(k for k in union(keys(a), keys(b)) if get(a, k, nothing) != get(b, k, nothing))
        line_plot() = plot_scatter([1.0, 2.0, 3.0], [1.0, 4.0, 9.0])
        function inset_grid()
            sf = _ax_grid(2, 2)
            k = inset!(sf, (0.5, 0.5, 0.4, 0.4); row = 2, col = 1)
            plot_scatter!(sf, [1.0, 2.0], [3.0, 4.0]; inset = k)
            return sf
        end
        function twin_plot()
            p = line_plot()
            plot_scatter!(p, [1.0, 2.0, 3.0], [10.0, 20.0, 30.0]; secondary_y = true)
            return p
        end
        # name, factory, x keywords, y keywords, cell keywords (`nothing`: the
        # helper does not apply), title/panel keywords and the top-level key
        # they write, whether a secondary x axis there moves the figure title.
        targets = (
            (:plot, line_plot, (;), (;), (;), (;), :title, (;), true),
            (:syncplot, () -> first(_ax_syncplot(line_plot())), (;), (;), (;), (;), :title, (;), true),
            (:cell11, () -> _ax_grid(2, 2), (row = 1, col = 1), (row = 1, col = 1), (row = 1, col = 1),
                (row = 1, col = 1), :annotations, (cells = [(1, 1)],), true),
            (:cell22, () -> _ax_grid(2, 2), (row = 2, col = 2), (row = 2, col = 2), (row = 2, col = 2),
                (row = 2, col = 2), :annotations, (cells = [(2, 2)],), false),
            (:inset21, inset_grid, (inset = 1,), (inset = 1,), (inset = 1,), nothing, nothing, nothing, false),
            (:secondary_y, twin_plot, (;), (secondary_y = true,), nothing, nothing, nothing, nothing, false),
        )
        resolved = Dict{Symbol, Tuple{Symbol, Symbol}}()
        for (name, make, xkw, ykw, ckw, tkw, tkey, pkw, top) in targets
            probe = make()
            X = _AX._cell_target(probe; xkw...).xkey
            Y = _AX._cell_target(probe; ykw...).ykey
            resolved[name] = (X, Y)
            cases = Any[
                ("xlabel!", f -> xlabel!(f, L"$t$ (s)"; xkw...), Set([X]),
                    f -> _ax_get(_ax_field(f, X, :title), :text) == PlotlySupply._label(L"$t$ (s)")),
                ("ylabel!", f -> ylabel!(f, "amplitude"; ykw...), Set([Y]),
                    f -> _ax_get(_ax_field(f, Y, :title), :text) == "amplitude"),
                ("xrange!", f -> xrange!(f, (1.5, 2.5); xkw...), Set([X]),
                    f -> _ax_field(f, X, :range) == [1.5, 2.5] && _ax_field(f, X, :autorange) === false),
                ("yrange!", f -> yrange!(f, (2, 8); ykw...), Set([Y]),
                    f -> _ax_field(f, Y, :range) == [2, 8]),
                ("xticks!", f -> xticks!(f, [1, 2, 3]; xkw...), Set([X]),
                    f -> _ax_field(f, X, :tickvals) == [1.0, 2.0, 3.0]),
                ("yticks!", f -> yticks!(f, [2, 4], ["two", "four"]; ykw...), Set([Y]),
                    f -> _ax_field(f, Y, :ticktext) == ["two", "four"]),
            ]
            if ckw !== nothing
                append!(cases, Any[
                    ("grid!", f -> grid!(f; color = "#ff0000", ckw...), Set([X, Y]),
                        f -> _ax_field(f, X, :gridcolor) !== nothing && _ax_field(f, X, :gridcolor) == _ax_field(f, Y, :gridcolor)),
                    ("spines!", f -> spines!(f; style = :open, ckw...), Set([X, Y]),
                        f -> _ax_field(f, X, :mirror) === false && _ax_field(f, Y, :mirror) === false),
                    ("axis_equal!", f -> axis_equal!(f; ckw...), Set([X, Y]),
                        f -> _ax_field(f, Y, :scaleanchor) == _AX._cmn_axis_ref(X)),
                    ("axis_off!", f -> axis_off!(f; ckw...), Set([X, Y]),
                        f -> _ax_field(f, X, :visible) === false && _ax_field(f, Y, :visible) === false),
                    # A secondary x axis is a new axis overlaying X; it freezes
                    # X's automatic range (its ticks are computed for it) and,
                    # in a top cell, lifts the figure title above it.
                    ("secondary_xaxis!", f -> secondary_xaxis!(f, v -> 2v, v -> v / 2; ckw...), nothing,
                        f -> _ax_field(f, X, :autorange) === false),
                ])
            end
            if tkw !== nothing
                push!(cases, ("title!", f -> title!(f, L"Run $\alpha$"; tkw...), Set([tkey]), f -> true))
                push!(cases, ("panel_labels!", f -> panel_labels!(f; pkw...), Set([:annotations]), f -> true))
            end
            for (helper, call, expected, check) in cases
                fig = make()
                if expected === nothing
                    new_key = Symbol("xaxis", _AX._axes_highest_axis_index(_AX._cmn_plot(fig), 'x') + 1)
                    expected = Set([X, new_key])
                    top && push!(expected, :title)
                end
                before = snapshot(fig)
                call(fig)
                written = changed(before, snapshot(fig))
                @test (name, helper, written) == (name, helper, expected)
                @test (name, helper, check(fig)) == (name, helper, true)
            end
        end
        # The targets resolve to the axes they name.
        @test resolved[:plot] == (:xaxis, :yaxis)
        @test resolved[:syncplot] == (:xaxis, :yaxis)
        @test resolved[:cell11] == (:xaxis, :yaxis)
        @test resolved[:cell22] == (:xaxis4, :yaxis4)
        @test resolved[:inset21] == (:xaxis5, :yaxis5)
        @test resolved[:secondary_y] == (:xaxis, :yaxis2)
        # axis_off! on a cell hides the axes overlaying it (the twin y) too.
        p = twin_plot()
        before = snapshot(p)
        axis_off!(p)
        @test changed(before, snapshot(p)) == Set([:xaxis, :yaxis, :yaxis2])
    end

    @testset "D9 tick presets through xticks!/yticks! on every target" begin
        xs = exp10.(range(-3, 5; length = 30))   # 8 decades -> dtick 1
        ys = exp10.(range(-6, 7; length = 30))   # 13 decades -> dtick 2
        loglog() = plot_scatter(xs, ys; xscale = "log", yscale = "log")
        function check_decades(fig, X, Y)
            @test _ax_field(fig, X, :tickmode) == "linear"
            @test _ax_field(fig, X, :tick0) == 0
            @test _ax_field(fig, X, :dtick) == 1
            @test _ax_get(_ax_field(fig, X, :minor), :dtick) == "D1"
            @test _ax_field(fig, Y, :dtick) == 2
            @test _ax_get(_ax_field(fig, Y, :minor), :dtick) == 1
            @test _ax_field(fig, Y, :exponentformat) == "power"
        end
        function check_auto(fig, X)
            for name in (:tickmode, :tick0, :dtick, :tickvals, :ticktext)
                @test _ax_field(fig, X, name) === nothing
            end
            @test _ax_get(_ax_field(fig, X, :minor), :ticks) == ""
        end
        # Plot
        p = loglog()
        @test xticks!(p, :decades) === nothing
        yticks!(p, :decades)
        check_decades(p, :xaxis, :yaxis)
        xticks!(p, :auto)
        check_auto(p, :xaxis)
        @test _ax_field(p, :yaxis, :dtick) == 2   # the other axis keeps its preset
        # SyncPlot: one renderer update per call, none for a rejected call.
        sp, state = _ax_syncplot(loglog())
        n = length(state.scripts)
        xticks!(sp, :decades)
        yticks!(sp, :decades)
        check_decades(sp, :xaxis, :yaxis)
        @test length(state.scripts) == n + 2
        lin_sp, lin_state = _ax_syncplot(plot_scatter([1.0, 2.0], [1.0, 2.0]))
        before = _ax_json(lin_sp.plot.layout)
        m = length(lin_state.scripts)
        @test _ax_throws(() -> xticks!(lin_sp, :decades), "xticks!: the `:decades` tick preset labels powers of ten and needs a logarithmic axis; :xaxis has type")
        @test _ax_json(lin_sp.plot.layout) == before
        @test length(lin_state.scripts) == m
        xticks!(lin_sp, :auto)
        @test _ax_field(lin_sp, :xaxis, :tickmode) === nothing
        # SubplotFigure cell (2,2) and an inset of cell (2,1).
        sf = _ax_grid(2, 2)
        plot_scatter!(sf, xs, ys; row = 2, col = 2, xscale = "log", yscale = "log")
        @test xticks!(sf, :decades; row = 2, col = 2) === sf
        yticks!(sf, :decades; row = 2, col = 2)
        check_decades(sf, :xaxis4, :yaxis4)
        @test _ax_field(sf, :xaxis, :tickmode) === nothing
        k = inset!(sf, (0.5, 0.5, 0.4, 0.4); row = 2, col = 1)
        plot_scatter!(sf, xs, ys; inset = k, xscale = "log", yscale = "log")
        rec = sf.insets[k]
        xticks!(sf, :decades; inset = k)
        yticks!(sf, :decades; inset = k)
        check_decades(sf, rec.xkey, rec.ykey)
        @test _ax_field(sf, :xaxis3, :tickmode) === nothing   # the host cell
        yticks!(sf, :auto; inset = k)
        check_auto(sf, rec.ykey)
        before = _ax_json(sf.plot.layout)
        @test _ax_throws(() -> xticks!(sf, :decades; row = 1, col = 1), "has type \"-\"")
        @test _ax_throws(() -> xticks!(sf, :decades, ["a"]; row = 2, col = 2), "chooses the ticks and their labels")
        @test _ax_throws(() -> yticks!(sf, :decade; row = 2, col = 2), "yticks!: unknown tick preset :decade")
        @test _ax_json(sf.plot.layout) == before
        # A log twin y axis (secondary_y).
        t = plot_scatter(xs, collect(1.0:30))
        plot_scatter!(t, xs, ys; secondary_y = true)
        relayout!(t; yaxis2_type = "log")
        yticks!(t, :decades; secondary_y = true)
        @test _ax_field(t, :yaxis2, :dtick) == 2
        @test _ax_field(t, :yaxis, :tickmode) === nothing
        @test _ax_throws(() -> yticks!(t, :decades), ":yaxis has type")
        # The constructor keyword path shared by the families.
        c = plot_scatter([1.0, 10.0], [1.0, 2.0])
        _AX._apply_cartesian_plot_options!(c; xscale = "log", xticks = :decades, who = "t")
        @test _ax_field(c, :xaxis, :dtick) == 1
        @test _ax_throws(() -> _AX._apply_cartesian_plot_options!(c; yticks = :decades, who = "t"), "t: the `:decades` tick preset")
        @test _ax_throws(() -> _AX._apply_cartesian_plot_options!(c; xticks = :decades, xticklabels = ["a"], who = "t"), "`xticklabels` need explicit `xticks` values")
    end

    @testset "inset!: background, halo, sharing, removal and re-creation" begin
        z = [sin(i / 3) * cos(j / 4) for i in 1:8, j in 1:6]
        sf = subplots(1, 2; sync = false)
        xs = exp10.(range(0, 4; length = 20))
        plot_scatter!(sf, xs, 1 ./ xs; row = 1, col = 1, xscale = "log", yscale = "log")
        plot_heatmap!(sf, collect(1.0:8), collect(1.0:6), z; row = 1, col = 2)
        # Over a heatmap: an opaque background shape and haloed labels.
        k = inset!(sf, (0.5, 0.5, 0.4, 0.4); row = 1, col = 2, background = "#fff8e7")
        rec = sf.insets[k]
        bg_name = "plotlysupply:inset_background:$(rec.xref)"
        bg = only(filter(sh -> _ax_get(sh, :name) == bg_name, sf.plot.layout.fields[:shapes]))
        @test _ax_get(bg, :xref) == "$(rec.xref) domain" && _ax_get(bg, :yref) == "$(rec.yref) domain"
        @test (_ax_get(bg, :x0), _ax_get(bg, :x1), _ax_get(bg, :y0), _ax_get(bg, :y1)) == (0, 1, 0, 1)
        @test _ax_get(bg, :layer) == "below" && _ax_get(bg, :fillcolor) == "#fff8e7"
        for key in (rec.xkey, rec.ykey)
            @test _ax_get(_ax_field(sf, key, :tickfont), :shadow) == "auto"
            @test _ax_get(_ax_get(_ax_field(sf, key, :title), :font), :shadow) == "auto"
            @test _ax_field(sf, key, :automargin) === false
        end
        # The halo survives an axis title.
        xlabel!(sf, "f (Hz)"; inset = k)
        @test _ax_get(_ax_get(_ax_field(sf, rec.xkey, :title), :font), :shadow) == "auto"
        @test _ax_get(_ax_field(sf, rec.xkey, :title), :text) == "f (Hz)"
        # Its own log axes, ranges in data units.
        plot_scatter!(sf, [1.0, 10.0, 100.0], [2.0, 1.0, 3.0]; inset = k, xscale = "log")
        @test _ax_field(sf, rec.xkey, :type) == "log"
        xrange!(sf, (1, 1000); inset = k)
        @test _ax_field(sf, rec.xkey, :range) == [0.0, 3.0]
        @test _ax_throws(() -> xrange!(sf, (0, 10); inset = k), "must be positive")
        # Shared with a log host: same type, `matches`, explicit root autorange.
        s = inset!(sf, (0.1, 0.1, 0.45, 0.45); row = 1, col = 1, sharex = true, sharey = true, ticklabel_halo = false)
        srec = sf.insets[s]
        @test _ax_field(sf, srec.xkey, :matches) == "x" && _ax_field(sf, srec.ykey, :matches) == "y"
        @test _ax_field(sf, srec.xkey, :type) == "log" && _ax_field(sf, srec.ykey, :type) == "log"
        @test _ax_field(sf, :xaxis, :autorange) === true && _ax_field(sf, :yaxis, :autorange) === true
        # No halo; the tick font is still one step smaller than the host's.
        @test _ax_get(_ax_field(sf, srec.xkey, :tickfont), :shadow) === nothing
        @test _ax_get(_ax_field(sf, srec.xkey, :tickfont), :size) == 10.0
        @test !any(sh -> _ax_get(sh, :name) == "plotlysupply:inset_background:$(srec.xref)", sf.plot.layout.fields[:shapes])
        # A root with an explicit range but no `autorange` key gets false.
        sf2 = subplots(1, 1; sync = false)
        plot_scatter!(sf2, [1.0, 2.0], [3.0, 4.0]; xrange = (0, 5))
        _AX._cmn_delete_layout_fields!(sf2, :xaxis, (:autorange,))
        inset!(sf2, (0.5, 0.5, 0.4, 0.4); sharex = true)
        @test _ax_field(sf2, :xaxis, :autorange) === false
        @test _ax_field(sf2, :xaxis, :range) == [0, 5]
        # Validation before any write.
        before = _ax_json(sf.plot.layout)
        ninsets = length(sf.insets)
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.3, 0.3); background = 3), "inset!: `background` must be a colour string or symbol")
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.3, 0.3); background = ""), "inset!: `background` must be a colour or `nothing`")
        @test _ax_json(sf.plot.layout) == before && length(sf.insets) == ninsets

        # Removal: axes, the overlaying secondary x axis, traces, background.
        secondary_xaxis!(sf, v -> 2v, v -> v / 2; inset = k)
        n_before = length(sf.plot.data)
        on_inset = count(tr -> get(tr.fields, :yaxis, "y") == rec.yref, sf.plot.data)
        axis_keys = _AX._axes_cell_axis_keys(sf.plot.layout, _AX._cell_target(sf; inset = k))
        @test length(axis_keys) == 3
        @test remove_inset!(sf, k) === sf
        @test length(sf.insets) == ninsets - 1
        @test sf.insets[1].xkey == srec.xkey          # later ids move down
        for key in axis_keys
            @test !haskey(sf.plot.layout.fields, key)
        end
        @test length(sf.plot.data) == n_before - on_inset
        @test !any(sh -> _ax_get(sh, :name) == bg_name, sf.plot.layout.fields[:shapes])
        @test (sf.current_row, sf.current_col) == (1, 2)
        # Re-creation works.
        k2 = inset!(sf, (0.5, 0.5, 0.4, 0.4); row = 1, col = 2)
        @test k2 == length(sf.insets) == 2
        plot_scatter!(sf, [1.0, 2.0], [1.0, 2.0]; inset = k2)
        @test haskey(sf.plot.layout.fields, sf.insets[k2].xkey)
        # Errors leave the figure unchanged.
        before = _ax_json(sf.plot.layout)
        @test _ax_throws(() -> remove_inset!(sf, 9), "remove_inset!: unknown inset id 9; valid ids are 1:2.")
        @test _ax_throws(() -> remove_inset!(sf, true), "the inset id must be an integer")
        @test _ax_json(sf.plot.layout) == before
        relayout!(sf; xaxis9 = attr(matches = sf.insets[k2].xref))
        before = _ax_json(sf.plot.layout)
        @test _ax_throws(() -> remove_inset!(sf, k2), "remove_inset!: :xaxis9 shares its range with inset 2")
        @test _ax_json(sf.plot.layout) == before
        @test _ax_throws(() -> remove_inset!(plot_scatter([1.0], [1.0]), 1), "only a SubplotFigure has insets")
        @test _ax_throws(() -> remove_inset!(subplots(1, 1; sync = false), 1), "this figure has no insets")

        # A SyncPlot-backed SubplotFigure: one renderer update per call, none
        # for a rejected one.
        sp, state = _ax_syncplot(Plot(GenericTrace[], Layout(Subplots(rows = 1, cols = 1))))
        sfs = SubplotFigure(sp, 1, 1, 1, 1, true, :topright, (0.02, 0.03), "white", "black", 1.0)
        plot_scatter!(sfs, [1.0, 2.0], [1.0, 2.0])
        ks = inset!(sfs, (0.5, 0.5, 0.4, 0.4); background = "white")
        plot_scatter!(sfs, [1.0, 2.0], [2.0, 1.0]; inset = ks)
        n = length(state.scripts)
        ntr = length(sp.plot.data)
        remove_inset!(sfs, ks)
        @test length(state.scripts) == n + 1
        @test isempty(sfs.insets) && length(sp.plot.data) == ntr - 1
        @test !haskey(sp.plot.layout.fields, :xaxis2)
        @test _ax_throws(() -> remove_inset!(sfs, 1), "this figure has no insets")
        @test length(state.scripts) == n + 1
    end
    @testset "G46/G69: spines! sides, mirrored ticks, tick removal" begin
        sh(p) = [x for x in something(get(_AX._cmn_plot(p).layout.fields, :shapes, nothing), Any[])
                 if startswith(string(_ax_get(x, :name)), "plotlysupply:spine:")]
        fig = plot_scatter([0.0, 1.0], [0.0, 1.0])
        # Ticks on all four sides: a closed frame with mirrored ticks.
        @test spines!(fig; ticks = :mirror) === nothing
        for k in (:xaxis, :yaxis)
            @test _ax_field(fig, k, :mirror) == "ticks" && _ax_field(fig, k, :showline) === true
        end
        @test isempty(sh(fig))
        # `ticks = nothing` keeps the mirrored ticks; `:primary` drops them.
        spines!(fig; linewidth = 2)
        @test _ax_field(fig, :xaxis, :mirror) == "ticks" && _ax_field(fig, :xaxis, :linewidth) == 2
        spines!(fig; ticks = :primary)
        @test _ax_field(fig, :xaxis, :mirror) === true
        # Per side: the left line off keeps bottom/top natively and draws the
        # right line as a shape in the given colour and width.
        spines!(fig; left = false, color = "#336699", linewidth = 1.5)
        @test _ax_field(fig, :yaxis, :showline) === false && _ax_field(fig, :yaxis, :mirror) === false
        @test _ax_field(fig, :xaxis, :showline) === true && _ax_field(fig, :xaxis, :mirror) === true
        right = only(sh(fig))
        @test _ax_get(right, :name) == "plotlysupply:spine:xy:1"
        @test _ax_get(right, :xref) == "x domain" && _ax_get(right, :yref) == "y domain"
        @test (_ax_get(right, :x0), _ax_get(right, :x1), _ax_get(right, :y0), _ax_get(right, :y1)) == (1, 1, 0, 1)
        @test _ax_get(_ax_get(right, :line), :color) == "#336699"
        @test _ax_get(_ax_get(right, :line), :width) == 1.5
        @test _ax_get(right, :layer) == "above"
        # Repeating replaces the line instead of adding one.
        spines!(fig; left = false)
        @test length(sh(fig)) == 1
        # Open frame with mirrored ticks: plotly.js cannot mirror the ticks
        # without the line, so both own lines become shapes, `mirror = "ticks"`.
        spines!(fig; style = :open, ticks = :mirror)
        @test _ax_field(fig, :xaxis, :showline) === false && _ax_field(fig, :xaxis, :mirror) == "ticks"
        @test _ax_field(fig, :yaxis, :showline) === false && _ax_field(fig, :yaxis, :mirror) == "ticks"
        edges = sort([(_ax_get(x, :x0), _ax_get(x, :y0), _ax_get(x, :x1), _ax_get(x, :y1)) for x in sh(fig)])
        @test edges == [(0, 0, 0, 1), (0, 0, 1, 0)]
        # Top and right only.
        spines!(fig; style = :none, top = true, right = true, ticks = :primary)
        edges = sort([(_ax_get(x, :x0), _ax_get(x, :y0), _ax_get(x, :x1), _ax_get(x, :y1)) for x in sh(fig)])
        @test edges == [(0, 1, 1, 1), (1, 0, 1, 1)]
        # The box again: native lines, every spine shape removed.
        spines!(fig)
        @test isempty(sh(fig)) && _ax_field(fig, :yaxis, :showline) === true
        @test _ax_field(fig, :yaxis, :mirror) === true
        # An x axis on top has its own line on the top side.
        top = plot_scatter([0.0, 1.0], [0.0, 1.0])
        _AX._cmn_merge_layout_key!(top, :xaxis, Dict{Symbol, Any}(:side => "top"))
        spines!(top; bottom = false)
        @test _ax_field(top, :xaxis, :showline) === true && _ax_field(top, :xaxis, :mirror) === false
        @test isempty(sh(top))
        # ticks = :none removes the tick marks, minor ticks included.
        xticks!(fig; minor = true)
        spines!(fig; ticks = :none)
        @test _ax_field(fig, :xaxis, :ticks) == "" && _ax_field(fig, :yaxis, :ticks) == ""
        @test _ax_get(_ax_field(fig, :xaxis, :minor), :ticks) == ""
        # The shape colour falls back to the ink of the figure's template.
        dark = plot_scatter([0.0, 1.0], [0.0, 1.0])
        set_template!(dark, "plotly_dark")
        _AX._cmn_delete_layout_fields!(dark, :yaxis, (:linecolor,))
        spines!(dark; left = false)
        ink = _AX._template_ink(_AX._figure_style_template(_AX._cmn_plot(dark)))
        @test ink != "#000000"
        @test _ax_get(_ax_get(only(sh(dark)), :line), :color) == ink
        # Cells: lines named per cell; other cells untouched.
        sf = _ax_grid(1, 2)
        spines!(sf; style = :open, top = true, ticks = :mirror, row = 1, col = 2)
        names = [_ax_get(x, :name) for x in sh(sf)]
        @test names == ["plotlysupply:spine:x2y2:1"]
        @test _ax_field(sf, :xaxis, :mirror) === true
        # Errors before any change.
        before = _ax_json(fig.layout)
        @test _ax_throws(() -> spines!(fig; ticks = :all), "spines!: `ticks` must be :mirror, :primary, :none or `nothing`")
        @test _ax_throws(() -> spines!(fig; style = :closed), "spines!: `style` must be :box, :open or :none")
        @test_throws TypeError spines!(fig; left = 1)
        @test _ax_json(fig.layout) == before
    end

    @testset "G69/G46: tick direction none, minor ticks on linear axes, length/width" begin
        fig = plot_scatter(collect(0.0:10.0), collect(0.0:10.0))
        xticks!(fig; minor = true, ticklen = 8, tickwidth = 2)
        @test _ax_field(fig, :xaxis, :ticklen) == 8 && _ax_field(fig, :xaxis, :tickwidth) == 2
        mn = _ax_field(fig, :xaxis, :minor)
        @test _ax_get(mn, :ticks) == "outside" && _ax_get(mn, :ticklen) ≈ 0.6 * 8
        @test _ax_get(mn, :tickvals) === nothing   # plotly.js's automatic minor positions
        xticks!(fig; direction = :none)
        @test _ax_field(fig, :xaxis, :ticks) == ""
        @test _ax_get(_ax_field(fig, :xaxis, :minor), :ticks) == ""
        xticks!(fig; direction = :inside)
        @test _ax_field(fig, :xaxis, :ticks) == "inside"
        before = _ax_json(fig.layout)
        @test _ax_throws(() -> xticks!(fig; direction = :both), "plotly.js draws ticks on one side of the axis line only")
        @test _ax_throws(() -> yticks!(fig; direction = "inout"), "yticks!: `direction` must be")
        @test _ax_throws(() -> xticks!(fig; direction = :none, minor = true), "cannot be combined with `minor = true`")
        @test _ax_json(fig.layout) == before
    end

    @testset "G75: scientific offset text (offset = :auto | k | :none)" begin
        ann(p) = [a for a in something(get(_AX._cmn_plot(p).layout.fields, :annotations, nothing), Any[])
                  if startswith(string(_ax_get(a, :name)), "plotlysupply:offset:")]
        f = plot_scatter(collect(1.0:10.0), 1e-6 .* collect(1.0:10.0))
        @test yticks!(f; offset = :auto) === nothing
        vals = _ax_field(f, :yaxis, :tickvals)
        txt = _ax_field(f, :yaxis, :ticktext)
        @test _ax_field(f, :yaxis, :tickmode) == "array"
        @test length(vals) == length(txt) && issorted(vals)
        @test vals[1] < 1e-6 && vals[end] > 1e-5   # beyond the data on both sides
        i = findfirst(==(2.0e-6), vals)
        @test i !== nothing && txt[i] == "0.2"
        @test txt[findfirst(==(1.0e-5), vals)] == "1"
        @test "0" in txt && "−0.2" in txt
        a = only(ann(f))
        @test _ax_get(a, :name) == "plotlysupply:offset:y"
        @test _ax_get(a, :text) == _AX._label("\$\\times 10^{-5}\$")
        @test (_ax_get(a, :xref), _ax_get(a, :yref)) == ("x domain", "y domain")
        @test (_ax_get(a, :x), _ax_get(a, :xanchor), _ax_get(a, :y), _ax_get(a, :yanchor)) == (0, "right", 1, "bottom")
        @test _ax_get(a, :showarrow) === false
        # An explicit exponent and explicit values on the x axis.
        xticks!(f, [0, 5, 10]; offset = 1)
        @test _ax_field(f, :xaxis, :tickvals) == [0.0, 5.0, 10.0]
        @test _ax_field(f, :xaxis, :ticktext) == ["0", "0.5", "1"]
        xa = only(filter(x -> _ax_get(x, :name) == "plotlysupply:offset:x", ann(f)))
        @test _ax_get(xa, :text) == _AX._label("\$\\times 10^{1}\$")
        @test (_ax_get(xa, :x), _ax_get(xa, :xanchor), _ax_get(xa, :y), _ax_get(xa, :yanchor)) == (1, "right", 0, "top")
        @test _ax_get(xa, :yshift) < 0
        # Repeating replaces the label.
        yticks!(f; offset = -6)
        @test count(x -> _ax_get(x, :name) == "plotlysupply:offset:y", ann(f)) == 1
        @test _ax_field(f, :yaxis, :ticktext)[findfirst(==(2.0e-6), _ax_field(f, :yaxis, :tickvals))] == "2"
        # New tick values without `offset` replace the scaled labels: the
        # factor goes with them.
        xticks!(f, [0, 10])
        @test count(x -> _ax_get(x, :name) == "plotlysupply:offset:x", ann(f)) == 0
        @test _ax_field(f, :xaxis, :ticktext) === nothing
        # :auto without a large or small magnitude writes nothing.
        g = plot_scatter(collect(1.0:10.0), collect(1.0:10.0))
        yticks!(g; offset = :auto)
        @test isempty(ann(g)) && _ax_field(g, :yaxis, :tickvals) === nothing
        # :none removes the factor and its ticks; minor ticks stay.
        yticks!(g; offset = 2, minor = true)
        @test length(ann(g)) == 1
        yticks!(g; offset = :none)
        @test isempty(ann(g))
        @test _ax_field(g, :yaxis, :tickvals) === nothing && _ax_field(g, :yaxis, :tickmode) === nothing
        @test _ax_field(g, :yaxis, :ticktext) === nothing
        @test _ax_get(_ax_field(g, :yaxis, :minor), :ticks) == "outside"
        # :auto after a factor that is no longer needed removes it as well.
        yticks!(g; offset = 3)
        yticks!(g; offset = :auto)
        @test isempty(ann(g)) && _ax_field(g, :yaxis, :tickvals) === nothing
        # Array ticks already on the axis are kept and relabelled.
        h = plot_scatter(collect(1.0:10.0), 1e7 .* collect(1.0:10.0))
        yticks!(h, [2e7, 6e7, 1e8])
        yticks!(h; offset = :auto)
        @test _ax_field(h, :yaxis, :tickvals) == [2e7, 6e7, 1e8]
        @test _ax_field(h, :yaxis, :ticktext) == ["0.2", "0.6", "1"]
        @test _ax_get(only(ann(h)), :text) == _AX._label("\$\\times 10^{8}\$")
        # A top x axis puts the label above its tick labels.
        topx = plot_scatter(collect(1.0:10.0), collect(1.0:10.0))
        _AX._cmn_merge_layout_key!(topx, :xaxis, Dict{Symbol, Any}(:side => "top"))
        xticks!(topx; offset = 1)
        ta = only(ann(topx))
        @test (_ax_get(ta, :y), _ax_get(ta, :yanchor)) == (1, "bottom") && _ax_get(ta, :yshift) > 0
        # Cells use their own axis references.
        sf = _ax_grid(1, 2)
        yticks!(sf; offset = 3, row = 1, col = 2)
        @test _ax_get(only(ann(sf)), :name) == "plotlysupply:offset:y2"
        @test _ax_get(only(ann(sf)), :xref) == "x2 domain"
        # Errors before any change.
        before = _ax_json(f.layout)
        lg = plot_scatter([1.0, 10.0], [1.0, 2.0]; xscale = "log")
        @test _ax_throws(() -> xticks!(lg; offset = 2), "xticks!: `offset` scales the labels of a linear axis")
        cat = plot_scatter(["a", "b", "c"], [1.0, 2.0, 3.0])
        @test _ax_throws(() -> xticks!(cat, [0, 1]; offset = 2), "shows text or date data")
        @test _ax_throws(() -> yticks!(f, [1e-6], ["a"]; offset = -6), "cannot be combined with `labels`")
        @test _ax_throws(() -> yticks!(f; offset = -6, format = ".2f"), "`format` and `exponentformat`")
        @test _ax_throws(() -> yticks!(f, :auto; offset = -6), "cannot be combined with `subs` or a tick preset")
        @test _ax_throws(() -> yticks!(f; offset = 1.5), "`offset` must be :auto, :none, an integer exponent")
        @test _ax_throws(() -> yticks!(f; offset = true), "`offset` must be")
        @test _ax_throws(() -> yticks!(f; offset = 400), "`offset` must be")
        @test _ax_throws(() -> yticks!(f; offset = :sci), "`offset` must be")
        @test _ax_throws(() -> yticks!(f, [1.0, NaN]; offset = 1), "tick values must be finite numbers")
        @test _ax_throws(() -> yticks!(f, Float64[]; offset = 1), "`values` must not be empty")
        @test _ax_throws(() -> yticks!(Plot(); offset = 2), "set a range or add data")
        @test _ax_json(f.layout) == before
    end

    @testset "Y9 + insets: template ink, smaller tick font, data coordinates" begin
        sf = subplots(1, 1; sync = false)
        plot_heatmap!(sf, collect(0.0:9), collect(0.0:4), rand(10, 5))
        set_template!(sf, "plotly_dark")
        ink = _AX._template_ink(_AX._figure_style_template(sf.plot))
        @test ink != "#000000"
        # coords = :data on a field plot's tight range (cell edges -0.5 .. 9.5).
        k = inset!(sf, (5.0, 1.0, 3.0, 2.5); coords = :data)
        rec = sf.insets[k]
        @test collect(rec.xdomain) ≈ [0.55, 0.85] && collect(rec.ydomain) ≈ [0.3, 0.8]
        for key in (rec.xkey, rec.ykey)
            @test _ax_field(sf, key, :linecolor) == ink && _ax_field(sf, key, :tickcolor) == ink
            @test _ax_get(_ax_field(sf, key, :tickfont), :size) == 10.0   # 12 / 1.2
            @test _ax_get(_ax_field(sf, key, :tickfont), :shadow) == "auto"
        end
        # The step follows the host's tick font; `fontsize` overrides it.
        _AX._cmn_merge_layout_key!(sf, :xaxis, Dict{Symbol, Any}(:tickfont => Dict{Symbol, Any}(:size => 18)); nested = (:tickfont,))
        k2 = inset!(sf, (0.05, 0.05, 0.3, 0.3))
        @test _ax_get(_ax_field(sf, sf.insets[k2].xkey, :tickfont), :size) == 15.0
        k3 = inset!(sf, (0.05, 0.6, 0.3, 0.3); fontsize = 7)
        @test _ax_get(_ax_field(sf, sf.insets[k3].xkey, :tickfont), :size) == 7.0
        overlaying(fig) = only(Symbol(k) for k in keys(_AX._cmn_plot(fig).layout.fields)
            if _AX._cmn_axis_index(Symbol(k), 'x') !== nothing && _ax_field(fig, Symbol(k), :overlaying) == "x")
        # secondary_xaxis! places its ticks over the field plot's tight range
        # (cell edges -0.5 .. 9.5, not the centres 0 .. 9), which stays pinned
        # by the figure's clip: f(-0.5) = -0.25 puts a tick 0 at x = -0.25.
        secondary_xaxis!(sf, v -> v + 0.25, v -> v - 0.25)
        sec = overlaying(sf)
        @test _ax_field(sf, sec, :linecolor) == _ax_field(sf, :xaxis, :linecolor)
        @test any(≈(-0.25), _ax_field(sf, sec, :tickvals))
        @test all(x -> -0.5 <= x <= 9.5, _ax_field(sf, sec, :tickvals))
        @test _ax_field(sf, :xaxis, :range) === nothing
        @test _ax_get(_ax_field(sf, :xaxis, :autorangeoptions), :clipmin) == -0.5
        @test _ax_get(_ax_field(sf, :xaxis, :autorangeoptions), :clipmax) == 9.5
        # Y9: without a primary colour the secondary axis takes the template ink.
        plain = subplots(1, 1; sync = false)
        plot_scatter!(plain, [1.0, 2.0], [1.0, 2.0])
        set_template!(plain, "plotly_dark")
        _AX._cmn_delete_layout_fields!(plain, :xaxis, (:linecolor, :tickcolor))
        secondary_xaxis!(plain, v -> 2v, v -> v / 2)
        @test _ax_field(plain, overlaying(plain), :linecolor) == ink
        @test _ax_field(plain, overlaying(plain), :tickcolor) == ink
        # Errors before any change.
        before = _ax_json(sf.plot.layout)
        n = length(sf.insets)
        @test _ax_throws(() -> inset!(sf, (8.0, 1.0, 3.0, 1.0); coords = :data), "inset!: the inset's x extent 8.0 .. 11.0 is not inside the host x range")
        @test _ax_throws(() -> inset!(sf, (1.0, 1.0, -1.0, 1.0); coords = :data), "width and height must be positive")
        @test _ax_throws(() -> inset!(sf, (1.0, 1.0, 1.0); coords = :data), "4-tuple or 4-vector")
        @test _ax_throws(() -> inset!(sf, (1.0, NaN, 1.0, 1.0); coords = :data), "must be a finite number")
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.2, 0.2); fontsize = 0), "`fontsize` must be a positive number")
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.2, 0.2); fontsize = Inf), "`fontsize` must be a positive number")
        @test _ax_throws(() -> inset!(sf, (0.1, 0.1, 0.2, 0.2); coords = :figure), "`coords` must be :axes")
        @test _ax_json(sf.plot.layout) == before && length(sf.insets) == n
        auto = subplots(1, 1; sync = false)
        plot_scatter!(auto, [1.0, 2.0], [1.0, 2.0])
        @test _ax_throws(() -> inset!(auto, (1.0, 1.0, 0.5, 0.5); coords = :data), "`coords = :data` needs a fixed numeric x range")
        # Explicit ranges, a reversed y axis.
        xrange!(auto, (0, 4)); yrange!(auto, (4, 0))
        ki = inset!(auto, (1.0, 1.0, 2.0, 2.0); coords = :data)
        @test collect(auto.insets[ki].xdomain) ≈ [0.25, 0.75] && collect(auto.insets[ki].ydomain) ≈ [0.25, 0.75]
        # Log host axes take data values.
        lg = subplots(1, 1; sync = false)
        plot_scatter!(lg, [1.0, 1000.0], [1.0, 2.0]; xscale = "log")
        xrange!(lg, (1, 1000)); yrange!(lg, (0, 4))
        kl = inset!(lg, (10.0, 1.0, 90.0, 2.0); coords = :data)
        @test collect(lg.insets[kl].xdomain) ≈ [1 / 3, 2 / 3] && collect(lg.insets[kl].ydomain) ≈ [0.25, 0.75]
        @test _ax_throws(() -> inset!(lg, (-1.0, 1.0, 5.0, 1.0); coords = :data), "logarithmic axis and must be positive")
    end

    @testset "G11/G12/G46/G75: static export (SVG)" begin
        ticktexts(svg, cls) = [m.captures[1] for m in
            eachmatch(Regex("<g class=\"$(cls)\"><text[^>]*>([^<]*)</text>"), svg)]
        # Tick marks drawn: one "M" segment per tick and side (plotly.js puts a
        # mirrored tick in the same path as its primary tick).
        marks(svg, cls) = sum((count(==('M'), m.captures[1]) for m in
            eachmatch(Regex("<path class=\"$(cls) ticks[^\"]*\" d=\"([^\"]*)\""), svg)); init = 0)
        result = try
            # G11: log ticks at 4, 8, 16, 24, 32 without SI suffixes.
            lg = plot_scatter([4.0, 8.0, 16.0, 24.0, 32.0], [1.0, 2.0, 3.0, 4.0, 5.0]; xscale = "log")
            xticks!(lg, [4, 8, 16, 24, 32])
            log_svg = String(savefig(lg; format = "svg", width = 600, height = 400))
            # G12: secondary_xaxis! tick labels in the export.
            λ = collect(400.0:10.0:700.0)
            sec = plot_scatter(λ, sin.(λ ./ 50))
            secondary_xaxis!(sec, l -> 299792.458 / l, ν -> 299792.458 / ν; ticks = [450, 550, 650], ticklabels = ["P", "Q", "R"])
            sec_svg = String(savefig(sec; format = "svg", width = 600, height = 400))
            # G46: mirrored ticks double the tick marks.
            plain = plot_scatter(collect(0.0:10.0), collect(0.0:10.0))
            mirrored = plot_scatter(collect(0.0:10.0), collect(0.0:10.0))
            spines!(mirrored; ticks = :mirror)
            plain_svg = String(savefig(plain; format = "svg", width = 600, height = 400))
            mirror_svg = String(savefig(mirrored; format = "svg", width = 600, height = 400))
            # G75: scaled tick labels in the export.
            off = plot_scatter(collect(1.0:10.0), 1e-6 .* collect(1.0:10.0))
            yticks!(off; offset = -6)
            off_svg = String(savefig(off; format = "svg", width = 600, height = 400))
            (log_svg, sec_svg, plain_svg, mirror_svg, off_svg)
        catch err
            message = sprint(showerror, err)
            @test occursin("ElectronCall", message) || occursin("Plotly.js", message) ||
                occursin("Electron", message)
            nothing
        end
        if result !== nothing
            log_svg, sec_svg, plain_svg, mirror_svg, off_svg = result
            labels = ticktexts(log_svg, "xtick")
            @test labels == ["4", "8", "16", "24", "32"]
            @test !any(l -> occursin(r"[kµmMG]", l), labels)
            @test ticktexts(sec_svg, "x2tick") == ["P", "Q", "R"]
            @test ticktexts(sec_svg, "xtick") == ["400", "450", "500", "550", "600", "650", "700"]
            for cls in ("xtick", "ytick")
                @test marks(plain_svg, cls) > 0
                @test marks(mirror_svg, cls) == 2 * marks(plain_svg, cls)
            end
            ylabels = ticktexts(off_svg, "ytick")
            @test !isempty(ylabels) && all(l -> occursin(r"^[\x{2212}0-9.]+$", l), ylabels)
            @test "10" in ylabels && "2" in ylabels
            @test occursin("class=\"annotation\"", off_svg)
        end
    end
end
