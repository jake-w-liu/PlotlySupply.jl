using Test, PlotlySupply

const _AX = PlotlySupply
# The tests below assume the package's default style. Earlier test files of a
# full run can leave another default style behind (the full suite showed a
# 9 px tick / 11 px title style here), so start from the default.
set_default_style!(:default)
const _AX_PB = PlotlySupply.PlotlyBase
const _AX_BREAK = PlotlySupply._FIN_WRAP_BREAK   # the finalizer's title line break

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
        # axes-ticks-13: an unknown keyword names the public function.
        @test _ax_throws(() -> xticks!(fig; secondary_y = true), "xticks!: unsupported keyword argument(s) `secondary_y`")

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
        @test _ax_throws(() -> xticks!(fig, [1e-3]; bogus = 1), "xticks!: unsupported keyword argument(s) `bogus`")
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
        # Wave 5 (W5): `side = :bottom` on a bottom primary is a second label
        # row; the same side is still rejected on a top primary.
        topfig = deepcopy(fig)
        relayout!(topfig; xaxis_side = "top")
        @test _ax_throws(() -> secondary_xaxis!(topfig, l -> c / l, ν -> c / ν; side = :top), "already on the top")
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
        # `layout.meta` is the finalizer's bookkeeping: its record of where the
        # inset sits in its host (inset-01) goes once `axis_equal!` hands the
        # inset to its own equal-aspect fit.
        others = Dict(kk => _ax_json(v) for (kk, v) in sf.plot.layout.fields if !(kk in (:xaxis5, :yaxis5, :meta)))
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
        # Z36: :axes bounds may leave the cell, not the figure (cell (2, 1) is
        # about [0, 0.45] x [0, 0.43] of the paper).
        @test _ax_throws(() -> inset!(sf, (0.5, 0.5, 2.0, 0.4)), "inset!: the inset's x extent is paper")
        @test _ax_throws(() -> inset!(sf, (0.5, 0.5, 2.0, 0.4)), "outside the figure")
        @test _ax_throws(() -> inset!(sf, (0.5, 0.7, 0.4, 2.0)), "inset!: the inset's y extent is paper")
        @test _ax_throws(() -> inset!(sf, (-0.1, 0.5, 0.4, 0.4)), "inset!: the inset's x extent is paper")
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
        @test _ax_throws(() -> xrange!(cat, ("a", "c")), "xrange!: `range` bounds on a category axis must be numbers")
        @test _ax_throws(() -> yrange!(cat, ("a", "c")), "yrange!: `range` bounds on a linear axis must be numbers")
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
        style_x!(f) = relayout!(f; xaxis_tickfont = attr(size = 16), xaxis_title_font = attr(size = 18, family = "Arial"),
            xaxis_linecolor = "#123456", xaxis_linewidth = 2)
        # tick labels 16 px, title 18 px, standoff 15, ticks 5, linewidth 2.
        depth = 5 + 1.3 * 16 + 1 + 15 + 1.3 * 18
        # A constructor title has the `title!` placement (Z28): it stays at the
        # top of the figure and the decoration stack (D12) moves the plot area
        # down below it and the top axis.
        fig = plot_scatter(λ, y; title = "spectrum")
        style_x!(fig)
        placed_title = deepcopy(fig.layout.fields[:title])
        secondary_xaxis!(fig, l -> c / l, ν -> c / ν; title = "frequency (THz)")
        @test _ax_json(fig.layout.fields[:title]) == _ax_json(placed_title)
        # ... and the room engine holds the margin for both when it finalizes.
        _AX._finalize_figure!(fig; size = (700, 500))
        @test _ax_get(fig.layout.fields[:margin], :t) >= _AX._text_title_band(fig) + depth - 8
        @test _ax_json(fig.layout.fields[:title]) == _ax_json(placed_title)
        # A title set without a placement sits on the plot area, lifted by pad.b.
        fig = plot_scatter(λ, y)
        relayout!(fig; title_text = "spectrum")
        style_x!(fig)
        secondary_xaxis!(fig, l -> c / l, ν -> c / ν; title = "frequency (THz)")
        title = fig.layout.fields[:title]
        @test _ax_get(title, :text) == "spectrum"
        @test (_ax_get(title, :yref), _ax_get(title, :y), _ax_get(title, :yanchor)) == ("paper", 1, "bottom")
        @test _ax_get(title, :automargin) === true
        pad = _ax_get(_ax_get(title, :pad), :b)
        # The top axis and a gap of 6 px.
        @test pad == ceil(depth + 6)
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
        placed = plot_scatter(λ, y)
        relayout!(placed; title_text = "placed", title_y = 0.95)
        user_title = deepcopy(placed.layout.fields[:title])
        secondary_xaxis!(placed, l -> c / l, ν -> c / ν)
        @test _ax_json(placed.layout.fields[:title]) == _ax_json(user_title)
        @test _ax_get(placed.layout.fields[:title], :y) == 0.95
        bottom = plot_scatter(λ, y)
        relayout!(bottom; title_text = "b", xaxis_side = "top")
        secondary_xaxis!(bottom, l -> c / l, ν -> c / ν; side = :bottom)
        @test _ax_get(bottom.layout.fields[:title], :yref) === nothing
        @test _ax_get(_ax_get(bottom.layout.fields[:title], :pad), :b) === nothing
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
        @test _ax_throws(() -> inset!(sf, (0.9, 0.9, 0.2, 0.2)), "outside the figure")
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
                # A math figure title also records its pin shift in
                # `layout.meta` (v7 tm-title-top-clip, `_lt_pin_title!`).
                push!(cases, ("title!", f -> title!(f, L"Run $\alpha$"; tkw...),
                    tkey === :title ? Set([:title, :meta]) : Set([tkey]), f -> true))
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
        # Open frame (L12): mirrored ticks need the opposite line, so
        # `ticks = :mirror` leaves no ticks floating on the open sides; the
        # own lines stay native, no shapes.
        spines!(fig; style = :open, ticks = :mirror)
        @test _ax_field(fig, :xaxis, :showline) === true && _ax_field(fig, :xaxis, :mirror) === false
        @test _ax_field(fig, :yaxis, :showline) === true && _ax_field(fig, :yaxis, :mirror) === false
        @test isempty(sh(fig))
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
        # Bottom and top drawn: x2 mirrors its ticks onto the top line; the
        # right side is open, so y2 mirrors nothing (L12).
        @test isempty(sh(sf))
        @test _ax_field(sf, :xaxis2, :mirror) == "ticks" && _ax_field(sf, :yaxis2, :mirror) === false
        @test _ax_field(sf, :xaxis, :mirror) === true
        # Errors before any change.
        before = _ax_json(fig.layout)
        @test _ax_throws(() -> spines!(fig; ticks = :all), "spines!: `ticks` must be :mirror, :primary, :none or `nothing`")
        @test _ax_throws(() -> spines!(fig; style = :closed), "spines!: `style` must be :box, :open or :none")
        @test _ax_throws(() -> spines!(fig; left = 1), "spines!: `left` must be true, false, `nothing` or a data interval")
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

    @testset "wave 5: one-sided limits on groups, clips and aspect-linked axes (Z38)" begin
        # Keyword path on a shared axis: every member of the matches group
        # carries the limit (the cell's scratch result is synced group-wide).
        sf = subplots(1, 2; sync = false, shared_yaxes = true)
        plot_scatter!(sf, 1:3, [1.0, 2, 3]; row = 1, col = 1)
        plot_scatter!(sf, 1:3, [2.0, 5, 3]; row = 1, col = 2, yrange = (0, nothing))
        for key in (:yaxis, :yaxis2)
            opts = _ax_field(sf, key, :autorangeoptions)
            @test _ax_get(opts, :minallowed) == 0
            @test _ax_get(opts, :clipmin) === nothing
        end
        @test _ax_field(sf, :yaxis, :autorange) === true

        # A user `matches` group on a plain figure: the limit lands on root and member.
        f = plot_scatter(1:3, [1.0, 2, 3])
        relayout!(f; yaxis2 = attr(matches = "y", anchor = "x", domain = [0.5, 1]))
        _AX._apply_axis_range_to_key!(f, :yaxis2, (0, nothing), "t"; name = "yrange")
        @test _ax_get(_ax_field(f, :yaxis, :autorangeoptions), :minallowed) == 0
        @test _ax_get(_ax_field(f, :yaxis2, :autorangeoptions), :minallowed) == 0

        # The finalizer's sticky clip is replaced, not merged into.
        fh = plot_heatmap(1:5, 1:4, reshape(collect(1.0:20.0), 5, 4))
        @test _AX._fin_sticky_clip(_ax_axis(fh, :xaxis)) == (0.5, 5.5)
        xrange!(fh, (0, nothing))
        @test _ax_json(_ax_field(fh, :xaxis, :autorangeoptions)) == _ax_json(Dict(:minallowed => 0))

        # Aspect-linked axes: the one-sided limit pins the range, the other
        # end at the field edge (not padded data), and drops the clip.
        fe = plot_heatmap(1:10, 1:6, reshape(collect(1.0:60.0), 10, 6); equalar = true)
        @test _ax_field(fe, :xaxis, :range) == [0.5, 10.5]
        xrange!(fe, (0, nothing))
        @test _ax_field(fe, :xaxis, :range) == [0.0, 10.5]
        @test _ax_field(fe, :xaxis, :autorange) === false
        @test _ax_field(fe, :xaxis, :autorangeoptions) === nothing
        before = _ax_json(_AX._cmn_plot(fe).layout)
        @test _ax_throws(() -> xrange!(fe, (11, nothing)), "xrange!: `range` fixes one end of the axis beyond all of its data")
        @test _ax_json(_AX._cmn_plot(fe).layout) == before
        xrange!(fe, (10.4, nothing))     # inside the last cell: allowed
        @test _ax_field(fe, :xaxis, :range) == [10.4, 10.5]
    end

    @testset "wave 5: constructor title placement equals title! (Z28)" begin
        f1 = plot_scatter(1:3, 1:3; title = "Constructor title")
        f2 = plot_scatter(1:3, 1:3)
        title!(f2, "Constructor title")
        t1 = _AX._cmn_plot(f1).layout.fields[:title]
        @test _ax_json(t1) == _ax_json(_AX._cmn_plot(f2).layout.fields[:title])
        @test _ax_get(t1, :yref) == "container" && _ax_get(t1, :yanchor) == "top"
        @test _ax_get(t1, :x) == 0.5 && _ax_get(t1, :xanchor) == "center"
        @test _ax_json(_AX._cmn_plot(f1).layout.fields[:margin]) == _ax_json(_AX._cmn_plot(f2).layout.fields[:margin])
        f3 = plot_scatter(1:3, 1:3; title = "")
        @test isempty(_AX._tight_title_text(get(_AX._cmn_plot(f3).layout.fields, :title, nothing)))
    end

    @testset "wave 5: remove_inset! rejects row/col (Z22)" begin
        sf = _ax_grid(2, 2)
        k = inset!(sf, (0.5, 0.5, 0.4, 0.4); row = 2, col = 2)
        before = _ax_json(sf.plot.layout)
        @test _ax_throws(() -> remove_inset!(sf, k; row = 2, col = 2), "remove_inset!: unsupported keyword(s) `row`, `col`")
        @test _ax_throws(() -> remove_inset!(sf, k; col = 2), "remove_inset!: unsupported keyword(s) `col`")
        @test _ax_json(sf.plot.layout) == before && length(sf.insets) == 1
        @test remove_inset!(sf, k) === sf
        @test isempty(sf.insets)
    end

    @testset "wave 5: insets beside the axes, inside the figure (Z36)" begin
        sf = subplots(1, 2; sync = false, horizontal_spacing = 0.3)
        x = collect(range(0, 1; length = 20))
        plot_scatter!(sf, x, sin.(4 .* x); row = 1, col = 1)
        plot_scatter!(sf, x, cos.(4 .* x); row = 1, col = 2)
        host = _AX._cell_target(sf; row = 1, col = 1)
        k = inset!(sf, (1.05, 0.0, 0.25, 1.0); row = 1, col = 1, sharey = true)
        rec = sf.insets[k]
        hx = host.xdomain
        @test collect(rec.xdomain) ≈ [hx[1] + 1.05 * (hx[2] - hx[1]), hx[1] + 1.30 * (hx[2] - hx[1])]
        @test rec.xdomain[1] > hx[2] && rec.xdomain[2] < 1
        @test collect(rec.ydomain) ≈ collect(host.ydomain)
        @test _ax_field(sf, rec.ykey, :matches) == "y"
        before = _ax_json(sf.plot.layout)
        @test _ax_throws(() -> inset!(sf, (0.0, -0.4, 0.5, 0.3); row = 1, col = 1), "inset!: the inset's y extent is paper -0.4")
        @test _ax_throws(() -> inset!(sf, (1.05, 0.0, 0.25, 1.0); row = 1, col = 2), "outside the figure")
        @test _ax_throws(() -> inset!(sf, (1.05, 0.0, 0.25, 1.0); row = 1, col = 2), "width_ratios")
        @test _ax_throws(() -> inset!(sf, (0.9, 0.0, 0.25, 1.0); coords = :paper), "x0 + width = 1.15 exceeds 1")
        @test _ax_throws(() -> inset!(sf, (NaN, 0.0, 0.25, 1.0)), "inset!")
        @test _ax_json(sf.plot.layout) == before && length(sf.insets) == 1
    end

    @testset "wave 5: spines! bounds per side in data units (Z37)" begin
        f = plot_scatter(collect(1.0:10.0), collect(range(0, 1; length = 10)))
        spines!(f; style = :open, bottom = (2, 9), left = (0, 1))
        spine(fig, n) = only(s for s in _AX._cmn_plot(fig).layout.fields[:shapes] if _ax_get(s, :name) == "plotlysupply:spine:xy:$n")
        b, l = spine(f, 1), spine(f, 2)
        @test (_ax_get(b, :xref), _ax_get(b, :yref)) == ("x", "y domain")
        @test (_ax_get(b, :x0), _ax_get(b, :x1), _ax_get(b, :y0), _ax_get(b, :y1)) == (2.0, 9.0, 0, 0)
        @test (_ax_get(l, :xref), _ax_get(l, :yref)) == ("x domain", "y")
        @test (_ax_get(l, :y0), _ax_get(l, :y1)) == (0.0, 1.0)
        @test _ax_field(f, :xaxis, :showline) === false && _ax_field(f, :yaxis, :showline) === false
        before = _ax_json(_AX._cmn_plot(f).layout)
        @test _ax_throws(() -> spines!(f; left = (1, 1)), "spines!: `left` bounds must differ; got (1, 1).")
        @test _ax_throws(() -> spines!(f; left = "a"), "spines!: `left` must be true, false, `nothing` or a data interval (lo, hi)")
        @test _ax_throws(() -> spines!(f; bottom = (1, Inf)), "spines!: `bottom`")
        @test _ax_throws(() -> spines!(f; bottom = (1, 2, 3)), "spines!: `bottom`")
        @test _ax_json(_AX._cmn_plot(f).layout) == before
        flog = plot_scatter([1.0, 10, 100], [1.0, 2, 3]; xscale = "log")
        @test _ax_throws(() -> spines!(flog; bottom = (0, 10)), "spines!: `bottom` is drawn along logarithmic axis :xaxis; its bounds are data values and must be positive")
        spines!(flog; style = :open, bottom = (1, 100))
        @test (_ax_get(spine(flog, 1), :x0), _ax_get(spine(flog, 1), :x1)) == (1.0, 100.0)
        fd = plot_scatter([_AX.Dates.Date(2020, 1, 1), _AX.Dates.Date(2020, 6, 1)], [1.0, 2.0])
        spines!(fd; style = :open, bottom = (_AX.Dates.Date(2020, 2, 1), _AX.Dates.Date(2020, 5, 1)))
        @test (_ax_get(spine(fd, 1), :x0), _ax_get(spine(fd, 1), :x1)) == ("2020-02-01", "2020-05-01")
        # An untyped axis is typed by its data, as plotly.js types it.
        @test _AX._axis_type(fd, :xaxis) == "-"
        @test _ax_throws(() -> spines!(fd; bottom = (1, 2)), "spines!: `bottom` is drawn along date axis :xaxis; give dates")
        @test _ax_throws(() -> spines!(f; bottom = (_AX.Dates.Date(2020, 2, 1), _AX.Dates.Date(2020, 5, 1))),
            "spines!: `bottom` has date bounds but axis :xaxis holds numeric data")
        g = plot_scatter(1:3, 1:3)
        spines!(g; style = :open, bottom = true)
        @test _ax_field(g, :xaxis, :showline) === true
    end

    @testset "wave 5: 3-D labels run the scene finish steps (Z45)" begin
        f = plot_surface(reshape(collect(1.0:25.0), 5, 5))
        relayout!(_AX._cmn_plot(f); scene_camera = nothing)
        @test _ax_get(_ax_get(_ax_axis(f, :scene), :camera), :eye) === nothing
        xlabel!(f, "a long x axis title")
        scene = _ax_axis(f, :scene)
        @test _ax_get(_ax_get(_ax_get(scene, :xaxis), :title), :text) == "a long x axis title"
        eye = _ax_get(_ax_get(scene, :camera), :eye)
        @test eye !== nothing && all(isfinite, (_ax_get(eye, :x), _ax_get(eye, :y), _ax_get(eye, :z)))
    end

    @testset "wave 5: secondary_xaxis! restacks the figure title (Z15)" begin
        margin_t(f) = _ax_get(_AX._cmn_plot(f).layout.fields[:margin], :t)
        f0 = plot_scatter(collect(1.0:10.0), collect(1.0:10.0); title = "A title")
        f1 = plot_scatter(collect(1.0:10.0), collect(1.0:10.0); title = "A title")
        secondary_xaxis!(f1, x -> 2x, y -> y / 2; title = "doubled")
        f2 = plot_scatter(collect(1.0:10.0), collect(1.0:10.0); title = "A title")
        secondary_xaxis!(f2, x -> 2x, y -> y / 2; title = "doubled<br>twice")
        for f in (f0, f1, f2)
            _AX._finalize_figure!(f; size = (700, 500))
        end
        @test margin_t(f1) > margin_t(f0)
        layout = _AX._cmn_plot(f2).layout
        size = _AX._axes_title_font(layout, :xaxis2)
        @test margin_t(f2) - margin_t(f1) ≈ _AX._text_extent("a<br>b", size)[2] - _AX._text_extent("a", size)[2] atol = 1.5
    end

    @testset "wave 5: log-axis tick labels never collide (Z70) and the paper rule (W7)" begin
        P(f) = _AX._cmn_plot(f)
        upd(f, size; mode = :auto) = _AX._axes_log_tick_updates!(Dict{Symbol, Any}(), P(f), size; mode = mode)
        narrow = plot_scatter([0.0125, 0.2], [1.0, 2.0]; xscale = "log")
        # 700 x 500: plotly's "D1" labels fit (rendered gaps measured, v05).
        @test isempty(upd(narrow, (700, 500)))
        # A journal-column panel: they collide, so decade labels only.
        u = upd(narrow, (250, 200))
        @test u[:xaxis_tick0] == 0 && u[:xaxis_dtick] == 1
        @test u[:xaxis_minor_tickmode] == "linear" && u[:xaxis_minor_dtick] == "D1" && u[:xaxis_minor_tick0] == 0
        @test u[:xaxis_minor_ticks] == "outside" && u[:xaxis_minor_ticklen] > 0
        @test !haskey(u, :xaxis_tickmode) && !haskey(u, :xaxis_exponentformat)
        @test !any(k -> startswith(String(k), "yaxis"), keys(u))
        # Applied, idempotent, and handed back to plotly when the labels fit again.
        @test _AX._axes_apply_style_log_ticks!(narrow; size = (250, 200), mode = :auto)
        @test _AX._axes_log_tick_state(_ax_axis(narrow, :xaxis)) === :fitted
        @test !_AX._axes_apply_style_log_ticks!(narrow; size = (250, 200), mode = :auto)
        @test _AX._axes_apply_style_log_ticks!(narrow; size = (1400, 1000), mode = :auto)
        @test _AX._axes_log_tick_state(_ax_axis(narrow, :xaxis)) === :auto
        @test _ax_field(narrow, :xaxis, :dtick) === nothing && _ax_field(narrow, :xaxis, :tick0) === nothing
        @test _ax_field(narrow, :xaxis, :exponentformat) == "power"
        @test _AX._axes_apply_style_log_ticks!(narrow; size = (250, 200), mode = :auto)
        @test _AX._axes_log_tick_state(_ax_axis(narrow, :xaxis)) === :fitted
        @test _ax_throws(() -> _AX._axes_apply_style_log_ticks!(narrow; mode = :sparse), "`mode` must be :auto or :decades")

        # A user's tick setting is never touched, the `:decades` preset included.
        user = plot_scatter([0.0125, 0.2], [1.0, 2.0]; xscale = "log")
        xticks!(user, [0.02, 0.05, 0.1])
        @test isempty(upd(user, (150, 120)))
        preset = plot_scatter([1.0, 1e6], [1.0, 2.0]; xscale = "log")
        xticks!(preset, :decades)
        @test _AX._axes_log_tick_state(_ax_axis(preset, :xaxis)) === :user
        @test isempty(upd(preset, (120, 100); mode = :decades))
        tf = plot_scatter([0.0125, 0.2], [1.0, 2.0]; xscale = "log")
        relayout!(P(tf); xaxis_tickformat = "")
        @test isempty(upd(tf, (150, 120)))

        # W7: under a paper style (mode :decades) an axis that shows two
        # decade ticks or more shows decade labels at any size; one decade
        # tick keeps plotly's labels.
        three = plot_scatter([1.0, 1000.0], [1.0, 2.0]; xscale = "log")
        @test isempty(upd(three, (700, 500)))
        d = upd(three, (700, 500); mode = :decades)
        @test d[:xaxis_dtick] == 1 && d[:xaxis_minor_dtick] == "D1"
        # 1..30 shows the decade ticks 1 and 10 (less than one decade and a
        # half, but two decade ticks); 2..30 shows 10 only.
        two_ticks = plot_scatter([1.0, 30.0], [1.0, 2.0]; xscale = "log")
        @test upd(two_ticks, (700, 500); mode = :decades)[:xaxis_dtick] == 1
        few = plot_scatter([2.0, 30.0], [1.0, 2.0]; xscale = "log")
        @test isempty(upd(few, (700, 500); mode = :decades))
        @test _AX._style_log_ticks() in (:auto, :decades)
        @test hasfield(PlotStyle, :log_ticks) || _AX._style_log_ticks(PlotStyle()) === :auto

        # The decade step: D9's ceil(n / 8), raised until the labels clear.
        wide = plot_scatter([1e-12, 1.0], [1.0, 2.0]; xscale = "log")
        w = upd(wide, (700, 500); mode = :decades)
        @test w[:xaxis_dtick] == 2 && w[:xaxis_minor_dtick] == 1
        @test upd(wide, (160, 140); mode = :decades)[:xaxis_dtick] > 2
        a, b = _AX._axes_log_view(P(wide).layout, :xaxis, [:xaxis], _AX._fin_collect_axes(P(wide)))
        @test a ≈ -12 - 12 * _AX._AXES_AUTORANGE_PAD && b ≈ 12 * _AX._AXES_AUTORANGE_PAD
        # y axes: the ink of stacked labels (plotly's 2-decade "D1" y axis at
        # 700 x 500 keeps its labels; on a short axis they collide).
        ylog = plot_scatter([1.0, 2.0], [1.0, 100.0]; yscale = "log")
        @test isempty(upd(ylog, (700, 500)))
        # Shorter, plotly labels 1, 2, 5 per decade ("D2"), which still fit.
        @test isempty(upd(ylog, (300, 220)))
        @test upd(ylog, (250, 150))[:yaxis_dtick] == 1

        # A shared log axis is decided once for the group and written on its members.
        sf = subplots(1, 2; sync = false, shared_xaxes = true)
        plot_scatter!(sf, [0.0125, 0.2], [1.0, 2.0]; row = 1, col = 1, xscale = "log")
        plot_scatter!(sf, [0.0125, 0.2], [2.0, 3.0]; row = 1, col = 2, xscale = "log")
        @test isempty(_AX._axes_log_tick_updates!(Dict{Symbol, Any}(), sf.plot, (500, 250); mode = :auto))
        g = _AX._axes_log_tick_updates!(Dict{Symbol, Any}(), sf.plot, (400, 250); mode = :auto)
        @test g[:xaxis_dtick] == 1 && g[:xaxis2_dtick] == 1
        @test g[:xaxis_minor_dtick] == "D1" && g[:xaxis2_minor_dtick] == "D1"

        # The finalizer applies the rule at the figure's own size after each
        # mutation, and at the export size on the export copy only.
        live = plot_scatter([0.0125, 0.2], [1.0, 2.0]; xscale = "log")
        relayout!(P(live); width = 250, height = 200)
        xlabel!(live, "h")
        @test _AX._axes_log_tick_state(_ax_axis(live, :xaxis)) === :fitted
        big = plot_scatter([0.0125, 0.2], [1.0, 2.0]; xscale = "log")
        copy_plot = _AX._finalize_export_copy(P(big), (width = 250, height = 200))
        @test copy_plot !== P(big)
        @test _AX._axes_log_tick_state(copy_plot.layout.fields[:xaxis]) === :fitted
        @test _AX._axes_log_tick_state(_ax_axis(big, :xaxis)) === :auto
    end

    @testset "wave 5: axis titles that run off the figure are wrapped once (W5)" begin
        # ONE scheme: the finalizer's (`_fin_wrap_axis_titles!`, `_FIN_WRAP_BREAK` breaks);
        # xlabel!/ylabel! only keep `wrap = false` titles on one line.
        P(f) = _AX._cmn_plot(f)
        long = "a fairly long y-axis label that matplotlib would split"
        text(f, key) = _AX._axes_title_text(_ax_axis(f, key))[1]
        unwrap(t) = replace(t, _AX_BREAK => " ")
        # Longer than its axis but inside the figure: one line, as matplotlib draws it.
        mid = "relative complex-frequency error of the reduced model"
        m = plot_scatter(collect(0:0.1:1), collect(0:0.1:1) .^ 2)
        relayout!(P(m); width = 700, height = 500)
        ylabel!(m, mid)
        _AX._finalize_figure!(m)
        @test text(m, :yaxis) == mid
        # Longer than the figure is high: broken between words.
        f = plot_scatter(collect(0:0.1:1), collect(0:0.1:1) .^ 2)
        relayout!(P(f); width = 400, height = 200)
        ylabel!(f, long)
        _AX._finalize_figure!(f)
        wrapped = text(f, :yaxis)
        @test occursin(_AX_BREAK, wrapped)
        @test unwrap(wrapped) == long
        @test length(split(wrapped, _AX_BREAK)) >= 2
        # Idempotent; a taller figure puts the title back on one line.
        before = _ax_json(P(f).layout)
        _AX._finalize_figure!(f)
        @test _ax_json(P(f).layout) == before
        relayout!(P(f); height = 1200)
        _AX._finalize_figure!(f)
        @test text(f, :yaxis) == long
        # The export copy is wrapped for its size; the figure is not.
        g = plot_scatter(collect(0:0.1:1), collect(0:0.1:1) .^ 2)
        ylabel!(g, long)
        c = _AX._finalize_export_copy(P(g), (width = 400, height = 200))
        @test occursin(_AX_BREAK, _AX._axes_title_text(c.layout.fields[:yaxis])[1])
        @test text(g, :yaxis) == long

        # wrap = false: no-break spaces, never wrapped.
        h = plot_scatter(collect(0:0.1:1), collect(0:0.1:1) .^ 2)
        relayout!(P(h); width = 400, height = 200)
        ylabel!(h, long; wrap = false)
        _AX._finalize_figure!(h)
        @test text(h, :yaxis) == replace(long, ' ' => '\u00a0')
        sf = subplots(1, 2; sync = false)
        plot_scatter!(sf, 1:3, 1:3; row = 1, col = 1)
        relayout!(sf.plot; width = 300, height = 260)
        xlabel!(sf, "x axis title words that do not fit"; row = 1, col = 1, wrap = false)
        _AX._finalize_figure!(sf)
        @test !occursin("<br", text(sf, :xaxis))
        ylabel!(sf, long; row = 1, col = 1)
        _AX._finalize_figure!(sf)
        @test occursin(_AX_BREAK, text(sf, :yaxis))
        @test unwrap(text(sf, :yaxis)) == long
        # x titles: wider than the figure.
        xw = plot_scatter(1:3, 1:3)
        relayout!(P(xw); width = 300, height = 300)
        xlabel!(xw, long)
        _AX._finalize_figure!(xw)
        @test occursin(_AX_BREAK, text(xw, :xaxis))
        @test unwrap(text(xw, :xaxis)) == long
        # A line break of the user's is kept (each line is wrapped on its own);
        # MathJax and markup are left as written.
        u = plot_scatter(1:3, 1:3)
        relayout!(P(u); width = 300, height = 300)
        xlabel!(u, long * "<br>and more")
        _AX._finalize_figure!(u)
        @test occursin("<br>and more", text(u, :xaxis))
        # L7: our breaks are bare `<br>`s like the user's; the wrap record in
        # `layout.meta` keeps the title as written and as wrapped.
        rec = _AX._fin_wrap_record(P(u).layout)["xaxis"]
        @test rec == (long * "<br>and more", text(u, :xaxis))
        @test count("<br>", text(u, :xaxis)) > 1
        @test _AX._axes_keep_on_one_line("a <span style=\"x y\">b c</span>") == "a\u00a0<span style=\"x y\">b\u00a0c</span>"
        @test _AX._axes_keep_on_one_line("\$a b\$") == "\$a b\$"
        # A bare-string title is rewritten as a title mapping.
        q = plot_scatter(collect(0:0.1:1), collect(0:0.1:1))
        relayout!(P(q); width = 400, height = 200, yaxis_title = long)
        _AX._finalize_figure!(q)
        @test occursin(_AX_BREAK, text(q, :yaxis))
    end

    @testset "wave 5: the margin estimate reads plotly's log decade labels (W5)" begin
        # plotly formatLog labels a log axis by decades: "10⁻⁹" (power format,
        # 1.25 x the tick font, its exponent at 70 %: 5 characters' room),
        # "100μ" (the default "B"), "1e−9" ("e"); only a `tickformat`, the
        # "none" format or an "L" step print decimals ("0.000000001").
        chars(lo, hi; kw...) = _AX._fin_tick_chars(Dict{Symbol, Any}(kw...), lo, hi, 300.0, true, true)
        @test chars(-8.3, -1.7; exponentformat = "power") == 5
        # 10^-3 is "0.001" (5 characters) under the default "B" format; "1m" only
        # past minexponent (render probe: logB2.png).
        @test chars(-8.3, -1.7) == 5
        @test chars(-8.3, -1.7; exponentformat = "e") == 4
        @test chars(-8.3, -1.7; exponentformat = "none") == 11
        @test chars(-8.3, -1.7; tickformat = ".1e") == 11
        @test chars(0.0, 5.2) == 4
        # The estimate places the plot area, so an x title that fits beside a
        # log axis of small values stays on one line (gallery
        # optical_validation (d): the "0.000000001" estimate moved the axis
        # right, and its title, 5 px inside the figure edge, was broken).
        P(f) = _AX._cmn_plot(f)
        text(f) = _AX._axes_title_text(_ax_axis(f, :xaxis))[1]
        title = "width of the largest design in the whole set (nm)"
        f = plot_scatter(collect(1.0:7.0), exp10.(collect(-8.0:-2.0)); yscale = "log")
        # At 380 x 300 plotly.js draws the plot area from x = 54 px and the
        # one-line title 16 px inside the figure edge.
        @test _AX._axes_fit_plan(P(f), (380, 300)).ml < 60
        relayout!(P(f); width = 380, height = 300)
        xlabel!(f, title)
        _AX._finalize_figure!(f)
        @test text(f) == title
        # Narrower, it runs off the figure and is broken.
        relayout!(P(f); width = 300)
        _AX._finalize_figure!(f)
        @test occursin(_AX_BREAK, text(f))
        @test replace(text(f), _AX_BREAK => " ") == title
    end

    @testset "wave 5: tick values on a shared group and dates (Z29, Z42)" begin
        sf = subplots(1, 2; sync = false, shared_yaxes = true)
        plot_scatter!(sf, 1:3, [1.0, 10, 100]; row = 1, col = 1, yscale = "log")
        plot_scatter!(sf, 1:3, [2.0, 20, 50]; row = 1, col = 2, yscale = "log")
        yticks!(sf, [1, 10, 100]; row = 1, col = 2)
        @test _ax_field(sf, :yaxis, :tickvals) == _ax_field(sf, :yaxis2, :tickvals) == [1.0, 10.0, 100.0]
        fd = plot_scatter([_AX.Dates.Date(2020, 1, 1), _AX.Dates.Date(2020, 6, 1)], [1.0, 2.0])
        xticks!(fd, [_AX.Dates.Date(2020, 1, 1), _AX.Dates.Date(2020, 3, 1)], ["Jan", "Mar"])
        @test _ax_field(fd, :xaxis, :tickvals) == ["2020-01-01", "2020-03-01"]
        @test _ax_field(fd, :xaxis, :ticktext) == ["Jan", "Mar"]
        fk = plot_scatter([_AX.Dates.Date(2020, 1, 1), _AX.Dates.Date(2020, 6, 1)], [1.0, 2.0];
            xticks = [_AX.Dates.DateTime(2020, 1, 1, 12), _AX.Dates.DateTime(2020, 3, 1)])
        @test _ax_field(fk, :xaxis, :tickvals) == ["2020-01-01T12:00:00", "2020-03-01T00:00:00"]
        flog = plot_scatter([1.0, 10, 100], [1.0, 2, 3]; xscale = "log")
        @test _ax_throws(() -> xticks!(flog, [_AX.Dates.Date(2020, 1, 1)]), "xticks!: a logarithmic axis needs numeric tick values; got dates.")
    end
end

@testset "v7 axes-style: log labels, scale switches, shared axes (style-02, axes-ticks-01/03/04/12, docs-10, D21, L8, L12)" begin
    g(x, ks...) = (for k in ks; x = _AX._cmn_mapping_get(x, k); end; x)
    L(f) = _AX._cmn_layout(f).fields
    ieee_tick = _AX._STYLE_REGISTRY[:ieee].tick_fontsize
    export_failed(err) = (m = sprint(showerror, err); occursin("Electron", m) || occursin("Plotly.js", m))

    @testset "style-02: decade labels at the style's tick size" begin
        # plotly draws power-format decade labels at 1.25 x the tick font: a
        # styled log axis gets the compensated font, linear axes keep theirs.
        f = with_style(() -> plot_scatter(1:10, 10.0 .^ range(-2, 4; length = 10); yscale = "log"), :ieee)
        @test g(L(f)[:yaxis], :tickfont, :size) ≈ ieee_tick / 1.25
        @test g(L(f)[:xaxis], :tickfont, :size) ≈ ieee_tick
        @test !_AX._finalize_figure!(f)
        d = plot_scatter(1:10, 10.0 .^ range(-2, 4; length = 10); yscale = "log")
        @test g(L(d)[:yaxis], :tickfont, :size) === nothing        # :default keeps plotly's look
        # A figure-wide set_fonts! is the new intended size.
        s = with_style(() -> plot_scatter(1:10, 10.0 .^ range(-2, 4; length = 10); yscale = "log"), :aip)
        set_fonts!(s; tick = 8, units = :pt)
        @test g(L(s)[:yaxis], :tickfont, :size) ≈ 8 * 96 / 72 / 1.25
        @test !_AX._finalize_figure!(s)
        sizes(svg, letter) = [parse(Float64, m.captures[1]) for m in
            eachmatch(Regex("<g class=\"$(letter)tick\"><text[^>]*?font-size: ([0-9.]+)px"), svg)]
        result = try
            (String(savefig(f; format = "svg")), String(savefig(s; format = "svg")))
        catch err
            @test export_failed(err)
            nothing
        end
        if result !== nothing
            fsvg, ssvg = result
            @test !isempty(sizes(fsvg, "y")) && all(v -> isapprox(v, ieee_tick; atol = 0.01), sizes(fsvg, "y"))
            @test all(v -> isapprox(v, 8 * 96 / 72; atol = 0.01), vcat(sizes(ssvg, "y"), sizes(ssvg, "x")))
        end
    end

    @testset "axes-ticks-03: log tick state goes with the log scale" begin
        f = with_style(() -> plot_scatter(1:10, 10.0 .^ (0:9); yscale = "log"), :ieee)
        _AX._finalize_figure!(f)
        @test g(L(f)[:yaxis], :dtick) == 2 && g(L(f)[:yaxis], :minor, :tickmode) == "linear"
        plot_scatter!(f, 1:10, 1:10; yscale = "linear")
        @test g(L(f)[:yaxis], :dtick) === nothing && g(L(f)[:yaxis], :tick0) === nothing
        @test g(L(f)[:yaxis], :minor, :dtick) === nothing && g(L(f)[:yaxis], :minor, :tickmode) === nothing
        @test g(L(f)[:yaxis], :tickfont, :size) ≈ ieee_tick
        @test !_AX._finalize_figure!(f)
        p = plot_scatter(1:10, 10.0 .^ (0:9); yscale = "log")
        yticks!(p, :decades)
        plot_scatter!(p, 1:10, 100:100:1000; yscale = "linear")
        @test g(L(p)[:yaxis], :tickmode) === nothing && g(L(p)[:yaxis], :dtick) === nothing
        # Linear ticks stated by the user with the same numbers are kept.
        u = plot_scatter(0:10, 0:10)
        relayout!(u; yaxis_tickmode = "linear", yaxis_tick0 = 0, yaxis_dtick = 1,
            yaxis_minor = attr(tickmode = "linear", tick0 = 0, dtick = 1))
        _AX._finalize_figure!(u)
        @test g(L(u)[:yaxis], :dtick) == 1 && g(L(u)[:yaxis], :minor, :dtick) == 1
    end

    @testset "axes-ticks-01: the offset factor sits at the labelled axis of a shared group" begin
        anns(sf) = [(g(a, :name), g(a, :xref), g(a, :yref)) for a in L(sf)[:annotations]]
        sf = subplots(1, 2; shared_yaxes = true, sync = false)
        plot_scatter!(sf, 1:3, [1e5, 1e6, 2e6]; row = 1, col = 1)
        plot_scatter!(sf, 1:3, [1e5, 1e6, 2e6]; row = 1, col = 2)
        yticks!(sf; offset = :auto, row = 1, col = 2)
        @test anns(sf) == [("plotlysupply:offset:y", "x domain", "y domain")]
        yticks!(sf; offset = :auto, row = 1, col = 1)            # same factor, not a second one
        @test length(anns(sf)) == 1
        sc = subplots(2, 1; shared_xaxes = true, sync = false)
        plot_scatter!(sc, [1e5, 1e6], 1:2; row = 1, col = 1)
        plot_scatter!(sc, [1e5, 1e6], 1:2; row = 2, col = 1)
        xticks!(sc; offset = :auto, row = 1, col = 1)
        labelled = first(k for k in (:xaxis, :xaxis2) if g(L(sc)[k], :showticklabels) !== false)
        ref = labelled === :xaxis ? "x" : "x2"
        @test anns(sc) == [("plotlysupply:offset:$(ref)", "$(ref) domain", "$(g(L(sc)[labelled], :anchor)) domain")]
    end

    @testset "axes-ticks-04: axis_equal! on a cell with a shared y axis" begin
        sf = subplots(1, 2; shared_yaxes = true, sync = false)
        th = range(0, 2pi; length = 50)
        plot_scatter!(sf, cos.(th), sin.(th); row = 1, col = 1)
        plot_scatter!(sf, 2 .* cos.(th), sin.(th); row = 1, col = 2)
        axis_equal!(sf; row = 1, col = 2, ratio = 2)
        # plotly.js ignores scaleanchor on an axis with `matches`: the cell's x
        # axis carries the constraint (rendered at ratio 1: 67.5 px per unit on
        # both x2 and y2, probe scratch v7/axes-style/p/a1.jl).
        @test g(L(sf)[:xaxis2], :scaleanchor) == "y2" && g(L(sf)[:xaxis2], :scaleratio) ≈ 0.5
        @test g(L(sf)[:yaxis2], :scaleanchor) === nothing
        both = subplots(2, 2; shared_xaxes = true, shared_yaxes = true, sync = false)
        plot_scatter!(both, 1:3, 1:3; row = 1, col = 2)
        before = _AX.PlotlyBase.JSON.json(both.plot)
        @test _ax_throws(() -> axis_equal!(both; row = 1, col = 2), "both axes of this cell are shared")
        @test _AX.PlotlyBase.JSON.json(both.plot) == before
    end

    @testset "axes-ticks-12 / docs-10: decades past 1e±154, one label format for subs" begin
        for (lim, step) in ((1e-160, 40), (1e-300, 75))
            f = plot_scatter([1, 2], [lim, 1 / lim]; yscale = "log")
            yticks!(f, :decades)
            @test g(L(f)[:yaxis], :dtick) == step
        end
        f = plot_scatter(10.0 .^ (-3:3), 10.0 .^ (-2:4); xscale = "log", yscale = "log")
        yticks!(f; subs = (1, 2, 5), minor = true)
        @test g(L(f)[:yaxis], :ticktext) == ["10<sup>−2</sup>", "2×10<sup>−2</sup>", "5×10<sup>−2</sup>",
            "10<sup>−1</sup>", "2×10<sup>−1</sup>", "5×10<sup>−1</sup>", "1", "2", "5", "10", "20", "50",
            "10<sup>2</sup>", "2×10<sup>2</sup>", "5×10<sup>2</sup>", "10<sup>3</sup>", "2×10<sup>3</sup>",
            "5×10<sup>3</sup>", "10<sup>4</sup>"]
        h = plot_scatter(10.0 .^ (-3:3), 10.0 .^ (-2:4); yscale = "log")
        yticks!(h; subs = (1, 2, 5), format = "~g")             # a format of the user's wins
        @test g(L(h)[:yaxis], :ticktext) === nothing
    end

    @testset "L12 / axes-ticks-05: open frames and twin axes never float mirrored ticks" begin
        f = with_style(() -> plot_scatter(1:3, 1:3), :ieee)
        spines!(f; style = :open)
        @test g(L(f)[:xaxis], :mirror) === false && g(L(f)[:xaxis], :showline) === true
        spines!(f; style = :box)
        @test g(L(f)[:xaxis], :mirror) == "ticks" && g(L(f)[:yaxis], :mirror) == "ticks"
        t = with_style(:ieee) do
            t = plot_scatter(1:3, 1:3)
            plot_scatter!(t, 1:3, [30, 10, 20]; secondary_y = true)
            t
        end
        _AX._finalize_figure!(t)
        @test g(L(t)[:yaxis], :mirror) === true        # the line, not the primary's ticks
        @test g(L(t)[:yaxis2], :ticks) == "inside"
    end

    @testset "D21: power exponents everywhere, SI on request (rendered)" begin
        labels(svg, cls) = [replace(m.captures[1], r"<[^>]+>" => "") for m in
            eachmatch(Regex("<g class=\"$(cls)\"><text[^>]*>(.*?)</text>"), svg)]
        tpl = _AX._plot_obj(plot_scatter(1:2, 1:2)).layout.fields[:template].layout.fields
        @test g(tpl[:xaxis], :exponentformat) == "power" && g(tpl[:polar], :radialaxis, :exponentformat) == "power"
        @test g(tpl[:ternary], :aaxis, :exponentformat) == "power" && g(tpl[:scene], :zaxis, :exponentformat) == "power"
        # The layout engine sizes the power labels ("−0.5×10⁴", not "−5k"):
        # sign, mantissa, "×10" and a 70 % exponent.
        @test _AX._fin_power_chars(-5000.0, 1e4, 3.0) == 8
        @test _AX._fin_power_chars(1e4, 1e4, 3.0) == 5 && _AX._fin_power_chars(0.0, 1e4, 3.0) == 1
        @test _AX._fin_power_chars(1.5e-4, 2e-4, 3.0) == 8 && _AX._fin_power_chars(2000.0, 4000.0, 3.0) === nothing
        unset, si = Dict{Symbol, Any}(), Dict{Symbol, Any}(:exponentformat => "SI")
        @test _AX._fin_tick_chars(unset, -1e4, 1e4, 300.0, false, true) == 8 > _AX._fin_tick_chars(si, -1e4, 1e4, 300.0, false, true)
        result = try
            svgs = [String(savefig(plot_scatter([v, 2v, 3v], [v, 2v, 3v]); format = "svg", width = 600, height = 400))
                for v in (2e-4, 5e3, 1e9)]
            si = plot_scatter([2e-4, 4e-4], [5e3, 1e4])
            yticks!(si; exponentformat = "SI")
            # A polar radial axis and a colour bar with the same values.
            others = [String(savefig(make(v); format = "svg", width = 500, height = 400)) for v in (2e-4, 5e3, 1e9),
                make in (v -> plot_scatterpolar([0, 90, 180], [v, 2v, 3v]), v -> plot_heatmap([v 2v; 3v 4v]))]
            (svgs, String(savefig(si; format = "svg", width = 600, height = 400)), others)
        catch err
            @test export_failed(err)
            nothing
        end
        if result !== nothing
            svgs, sisvg, others = result
            for svg in svgs, cls in ("xtick", "ytick")
                ls = labels(svg, cls)
                @test !isempty(ls) && !any(l -> occursin(r"[A-Za-zµ]", l), ls)
            end
            # Radial ticks are "xtick" in the polar frame, colour bar ticks "ycb<id>tick".
            for svg in others
                ls = [replace(m.captures[1], r"<[^>]+>" => "") for m in
                    eachmatch(r"<g class=\"(?:xtick|ycb[a-z0-9]*tick)\"[^>]*><text[^>]*>(.*?)</text>", svg)]
                @test any(l -> occursin("×10", l), ls) && !any(l -> occursin(r"[A-Za-zµ]", l), ls)
            end
            @test any(l -> occursin(r"[kµ]", l), labels(sisvg, "ytick"))
        end
    end

    @testset "L8: tick labels clear the ticks and the spine (rendered)" begin
        geom_js = raw"""
(function(svgText){
var c=document.createElement('div');c.style.position='absolute';c.style.left='0px';c.style.top='0px';
c.innerHTML=svgText;document.body.appendChild(c);
try{var R=c.querySelector('svg').getBoundingClientRect();
var b=function(e){var r=e.getBoundingClientRect();if(r.width===0&&r.height===0)return null;return [r.left-R.left,r.top-R.top,r.right-R.left,r.bottom-R.top];};
var out={};
c.querySelectorAll('g.xaxislayer-above, g.yaxislayer-above').forEach(function(layer){
 var l=layer.getAttribute('class').charAt(0); var a=out[l]=out[l]||{labels:[],marks:[]};
 layer.querySelectorAll('g.'+l+'tick text').forEach(function(t){var x=b(t);if(x)a.labels.push(x);});
 layer.querySelectorAll('path').forEach(function(p){var x=b(p);if(x)a.marks.push(x);});});
c.querySelectorAll('g.overlines-above > path, g.overaxes-above path').forEach(function(p){
 var m=/^([xy])lines-above/.exec(p.getAttribute('class')||'');if(!m)return;var x=b(p);if(!x)return;
 var a=out[m[1]]=out[m[1]]||{labels:[],marks:[]};a.marks.push(x);});
return JSON.stringify(out);}finally{c.remove();}})
"""
        # Gap (px) between each label box and the nearest tick mark or spine on
        # its label side (left of a y label's box, above an x label's).
        function gap(geo, letter)
            a = geo[letter]
            worst = Inf
            for lb in a["labels"], m in a["marks"]
                if letter == "y"
                    (m[4] < lb[2] || m[2] > lb[4]) && continue
                    m[1] >= lb[3] - 0.5 || continue
                    worst = min(worst, m[1] - lb[3])
                else
                    (m[3] < lb[1] || m[1] > lb[3]) && continue
                    m[4] <= lb[2] + 0.5 || continue
                    worst = min(worst, lb[2] - m[4])
                end
            end
            return worst
        end
        result = try
            out = Tuple{Symbol, String, Float64, Float64}[]
            # Every sized preset (and :publication), x and y, linear and log.
            for st in (:ieee, :aps, :nature, :elsevier, :springer, :aip, :publication), scale in ("linear", "log")
                f = with_style(() -> plot_scatter(10.0 .^ range(-1, 3; length = 10), 10.0 .^ range(-2, 4; length = 10);
                    xscale = scale, yscale = scale, xlabel = "x", ylabel = "y"), st)
                svg = String(savefig(f; format = "svg"))
                raw = _AX._with_export_window(_AX._EXPORT_STATE) do ec, app, win, divid
                    Base.invokelatest(() -> ec.run(win, geom_js * "(" * _AX._json_js(svg) * ")"))
                end
                geo = _AX.PlotlyBase.JSON.parse(String(raw))
                push!(out, (st, scale, gap(geo, "x"), gap(geo, "y")))
            end
            out
        catch err
            @test export_failed(err)
            nothing
        end
        if result !== nothing
            @test length(result) == 14
            for (st, scale, gx, gy) in result
                @test 2 <= gx < Inf && 2 <= gy < Inf
            end
        end
    end
end

@testset "v7 axes-style: quick audit fixes (log-01, stream-01, oned-cat-range-strings, axes-ticks-07/08/13/14, vm-11, vm-15, perf-02, oned-area-stack-nested-x)" begin
    g(x, ks...) = (for k in ks; x = _AX._cmn_mapping_get(x, k); end; x)
    L(f) = _AX._cmn_layout(f).fields
    msg(f) = try
        f(); "no error"
    catch err
        err isa ArgumentError ? err.msg : string(typeof(err))
    end
    x = 0:3; y = 0:4
    U = [-(yj - 2.0) for xi in x, yj in y]; V = [xi - 1.5 for xi in x, yj in y]
    # log-01: an ArgumentError naming the field, not a DomainError.
    @test startswith(msg(() -> (p = plot_streamlines(x, y, U, V); plot_scatter!(p, 1:5, [15, 11, 4, 15, 18]; yscale = "log"))),
        "plot_scatter!: the y axis shows a field over")
    # stream-01: RK4 trial points outside the grid end the line at the edge
    # (this field threw BoundsError [31, 5] on 45446e8).
    Ub = [0.088 0.015 0.108 0.43 1.54; 0.184 -1.136 -0.421 2.44 1.147; 1.688 -0.863 -2.556 -0.463 -0.15; -0.112 0.561 -0.801 0.186 1.562]
    Vb = [-0.302 -0.375 -0.327 -0.558 0.164; -1.119 0.273 -1.09 0.21 -0.473; 0.357 -1.35 -1.28 1.186 -1.938; 1.016 -0.769 0.76 -0.263 -0.312]
    @test !isempty(plot_streamlines(0:3, 0:4, Ub, Vb).data)
    @test all(1:60) do s
        U = [sin(1e3 * s + 7.3 * i + 3.1 * j) for i in 1:4, j in 1:5]
        V = [cos(2e3 * s + 5.7 * i - 1.9 * j) for i in 1:4, j in 1:5]
        plot_streamlines(0:3, 0:4, U, V) isa Plot
    end
    # oned-cat-range-strings / axes-ticks-02
    @test msg(() -> plot_scatter(["a", "b", "c"], 1:3; xrange = ("a", "c"))) ==
        "plot_scatter: `xrange` bounds must be numbers (data values; 0-based positions on a category axis) or dates; got (\"a\", \"c\")."
    @test msg(() -> xrange!(plot_scatter(["a", "b", "c"], 1:3), ("a", "c"))) ==
        "xrange!: `range` bounds on a category axis must be numbers (0-based category positions); got (\"a\", \"c\")."
    # axes-ticks-07 / tm-tickformat-g: explicit values keep plotly's power format.
    e = plot_scatter([0, 1e6, 2e6, 3e6], 1:4)
    xticks!(e, [0, 1e6, 2e6, 3e6])
    @test g(L(e)[:xaxis], :tickformat) === nothing
    # axes-ticks-08: Dates.Time is refused with a remedy.
    @test occursin("`x` holds Time values", msg(() -> plot_scatter([_AX.Dates.Time(1), _AX.Dates.Time(2)], [1.0, 2.0])))
    @test occursin("`y` holds Second values", msg(() -> plot_scatter([1.0, 2.0], Any[1.0, _AX.Dates.Second(2)])))
    # axes-ticks-13: unknown keywords are ArgumentErrors naming public API.
    pf = plot_scatter(1:3, 1:3)
    for (name, call) in (("xticks!", () -> xticks!(pf; formatt = "x")), ("xrange!", () -> xrange!(pf, (0, 1); foo = 1)),
            ("spines!", () -> spines!(pf; colr = "red")), ("grid!", () -> grid!(pf; foo = 1)),
            ("axis_equal!", () -> axis_equal!(pf; rato = 2)), ("secondary_xaxis!", () -> secondary_xaxis!(pf, identity, identity; foo = 1)))
        @test startswith(msg(call), "$(name): unsupported keyword argument(s)")
    end
    @test !occursin("_ensure_twin", msg(() -> yticks!(pf; secondary_y = true)))
    # axes-ticks-14
    d = plot_scatter([_AX.Dates.Date(2024, 1, 1), _AX.Dates.Date(2024, 6, 1)], [1, 2])
    xrange!(d, (_AX.Dates.Date(2024, 1, 1), _AX.Dates.Date(2024, 6, 1)))
    @test occursin("needs a numeric (linear or log) x axis", msg(() -> secondary_xaxis!(d, identity, identity)))
    # vm-11: fewer secondary ticks in a narrow cell.
    sn = with_style(:nature) do
        sn = subplots(1, 2; sync = false)
        plot_scatter!(sn, collect(400.0:10:700), sin.(1:31); row = 1, col = 1)
        secondary_xaxis!(sn, l -> 299792.458 / l, n -> 299792.458 / n; row = 1, col = 1)
        sn
    end
    sec = first(k for k in keys(L(sn)) if occursin(r"^xaxis\d+$", String(k)) && g(L(sn)[k], :overlaying) !== nothing)
    s1 = plot_scatter(collect(400.0:10:700), sin.(1:31))
    secondary_xaxis!(s1, l -> 299792.458 / l, n -> 299792.458 / n)
    @test length(g(L(sn)[sec], :tickvals)) < length(g(L(s1)[:xaxis2], :tickvals))
    # vm-15: insets follow the style's grid.
    sf = with_style(:ieee) do
        sf = subplots(1, 1; sync = false)
        plot_scatter!(sf, 1:10, 1:10)
        k = inset!(sf, (0.6, 0.6, 0.3, 0.3))
        plot_scatter!(sf, 1:3, 1:3; inset = k)
        sf
    end
    @test all(k -> g(L(sf)[k], :showgrid) === false, (:xaxis2, :yaxis2))
    # oned-area-stack-nested-x: a series is interpolated at another's x, not
    # taken as zero.
    nest = plot_area([[0.0, 1, 2, 3, 4], [0.0, 2, 4]], [[1.0, 1, 1, 1, 1], [1.0, 1, 1]]; stack = true)
    @test all(t -> t.fields[:stackgaps] == "interpolate", nest.data)
    # perf-02: no per-value message string (was 510-940 B per value; the copies
    # of the values themselves cost 8 B per array).
    n = 10^5
    px = collect(range(0, 1; length = n)); lo = sin.(px); hi = lo .+ 1
    plot_band(px, lo, hi); plot_segments(px, lo, px, hi)
    @test (@allocated plot_band(px, lo, hi)) / n < 150
    @test (@allocated plot_segments(px, lo, px, hi)) / n < 150
end

# ── v8 axes-style (round 1) ──────────────────────────────────────────────────
# Rendered geometry is measured in the export window on the exported SVG
# (element boxes, getBoundingClientRect), as the L8 testset above does.
const _V8AX_GEOM_JS = raw"""
(function(svgText){
var c=document.createElement('div');c.style.position='absolute';c.style.left='0px';c.style.top='0px';
c.innerHTML=svgText;document.body.appendChild(c);
try{var R=c.querySelector('svg').getBoundingClientRect();
var one=function(e){var r=e.getBoundingClientRect();if(r.width<=0&&r.height<=0)return null;return [r.left-R.left,r.top-R.top,r.right-R.left,r.bottom-R.top];};
var box=function(els){var b=null;for(var i=0;i<els.length;i++){var q=one(els[i]);if(!q||q[2]-q[0]<=0||q[3]-q[1]<=0)continue;
 b=b===null?q:[Math.min(b[0],q[0]),Math.min(b[1],q[1]),Math.max(b[2],q[2]),Math.max(b[3],q[3])];}return b;};
var out={axes:{},frames:{x:[],y:[]},shapes:[],bartext:[],contour:[]};
c.querySelectorAll('g').forEach(function(g){var m=/^g-([xy]\d*)title$/.exec(g.getAttribute('class')||'');if(!m)return;
 var t=box(g.querySelectorAll('text, svg'));var l=box(c.querySelectorAll('g.'+m[1]+'tick text'));
 if(t&&l)out.axes[m[1]]={title:t,labels:l};});
c.querySelectorAll('path').forEach(function(p){var m=/^([xy])lines-above/.exec(p.getAttribute('class')||'');if(!m)return;var q=one(p);if(q)out.frames[m[1]].push(q);});
c.querySelectorAll('g.shapelayer path').forEach(function(p){var q=one(p);if(q)out.shapes.push(q);});
c.querySelectorAll('text.bartext').forEach(function(t){var q=one(t);if(q)out.bartext.push(q);});
c.querySelectorAll('g.contourlabels').forEach(function(g){var clips=[];for(var n=g;n&&n.tagName!=='svg';n=n.parentNode){var a=n.getAttribute&&n.getAttribute('clip-path');if(a)clips.push(a);}
 out.contour.push({clips:clips,labels:g.querySelectorAll('text').length,linesclip:(g.parentNode.querySelector('g.contourlines')||{getAttribute:function(){return null;}}).getAttribute('clip-path')});});
return JSON.stringify(out);}finally{c.remove();}})
"""

function _v8ax_geometry(fig)
	svg = String(savefig(fig; format = "svg"))
	raw = PlotlySupply._with_export_window(PlotlySupply._EXPORT_STATE) do ec, app, win, divid
		Base.invokelatest(() -> ec.run(win, _V8AX_GEOM_JS * "(" * PlotlySupply._json_js(svg) * ")"))
	end
	return PlotlySupply.PlotlyBase.JSON.parse(String(raw)), svg
end

_v8ax_export_failed(err) = (m = sprint(showerror, err); occursin("Electron", m) || occursin("Plotly.js", m))

# The clear gap (px) between an axis's title box and its tick-label box.
function _v8ax_gap(entry, id::AbstractString)
	t, l = entry["title"], entry["labels"]
	return id[1] == 'x' ? max(t[2] - l[4], l[2] - t[4]) : max(l[1] - t[3], t[1] - l[3])
end

@testset "v8 axes-style: D24 axis-title gap (rendered)" begin
	PSX = PlotlySupply
	plain = ("polynomial degree", "normalized residual")
	math = ("\$\\alpha_1\\ (\\mathrm{m})\$", "\$\\sqrt{\\sigma}\\ (\\mathrm{s})\$")
	cases = Tuple{String, Any, Bool}[]   # (tag, figure, built by PlotlySupply calls only)
	for st in (:ieee, :aps, :nature, :elsevier, :springer, :aip)
		push!(cases, ("$st plain", with_style(() -> plot_scatter(1:5, [1, 4, 2, 5, 3]; xlabel = plain[1], ylabel = plain[2]), st), true))
		push!(cases, ("$st math", with_style(() -> plot_scatter(1:5, [1, 4, 2, 5, 3]; xlabel = math[1], ylabel = math[2]), st), true))
		flip = with_style(st) do
			f = plot_scatter(1:5, [1, 4, 2, 5, 3]; xlabel = plain[1], ylabel = math[2])
			relayout!(f; xaxis_side = "top", yaxis_side = "right")
			f
		end
		push!(cases, ("$st top/right", flip, false))
	end
	for st in (:ieee, :nature)
		push!(cases, ("$st two lines", with_style(() -> plot_scatter(1:5, [1, 4, 2, 5, 3];
			xlabel = "polynomial<br>degree", ylabel = "normalized<br>residual"), st), true))
		push!(cases, ("$st log", with_style(() -> plot_scatter([1, 10, 100, 1000], [3, 1, 4, 1];
			xscale = "log", yscale = "log", xlabel = "frequency (Hz)", ylabel = "power"), st), true))
		rot = with_style(st) do
			f = plot_bar(["alpha", "beta", "gamma"], [3, 1, 2]; xlabel = "category", ylabel = "count")
			relayout!(f; xaxis_tickangle = -45)
			f
		end
		push!(cases, ("$st category, rotated labels", rot, false))
		cell = with_style(st) do
			sf = subplots(2, 2)
			for r in 1:2, c in 1:2
				plot_scatter!(sf, 1:3, [1, 3, 2]; row = r, col = c)
			end
			xlabel!(sf, "time (s)"; row = 2, col = 2)
			ylabel!(sf, "\$v\$ (m/s)"; row = 2, col = 2)
			sf
		end
		push!(cases, ("$st cell (2,2)", cell, true))
	end
	# Every constructor-built case is settled with its gap records.
	for (tag, f, settled) in cases
		settled && @test !PSX._finalize_figure!(f)
	end
	result = try
		[(tag, f, _v8ax_geometry(f)[1]) for (tag, f, _) in cases]
	catch err
		@test _v8ax_export_failed(err)
		nothing
	end
	if result !== nothing
		measured = 0
		for (tag, f, geo) in result
			layout = PSX._cmn_plot(f).layout
			record = PSX._axes_title_gap_record(layout)
			for (id, entry) in geo["axes"]
				name = (id[1] == 'x' ? "xaxis" : "yaxis") * id[2:end]
				key = Symbol(name)
				size = PSX._axes_title_font_size(layout, key, get(layout.fields, key, nothing))
				# The record asks for 0.5 em, and the drawn gap is that to 1 px.
				@test haskey(record, name) && isapprox(record[name][2], 0.5 * size; atol = 0.01)
				gap = _v8ax_gap(entry, id)
				ok = isapprox(gap, 0.5 * size; atol = 1.0)
				ok || @info "D24 gap" tag id gap target = 0.5 * size
				@test ok
				measured += 1
			end
		end
		# Every case has its x and y title measured (the 2x2 grid: its titled cell).
		@test measured == 2 * length(result)
	end
	# :default and :publication keep plotly's placement: no record, no standoff.
	for st in (:default, :publication)
		f = with_style(() -> plot_scatter(1:5, [1, 4, 2, 5, 3]; xlabel = plain[1], ylabel = plain[2]), st)
		layout = PSX._cmn_plot(f).layout
		@test isempty(PSX._axes_title_gap_record(layout))
		@test PSX._cmn_mapping_get(PSX._cmn_mapping_get(layout.fields[:xaxis], :title), :standoff) === nothing
	end
	# A user standoff wins: its record goes, the other axis keeps the gap.
	f = with_style(() -> plot_scatter(1:5, [1, 4, 2, 5, 3]; xlabel = plain[1], ylabel = plain[2]), :ieee)
	relayout!(f; xaxis_title_standoff = 30)
	PSX._finalize_figure!(f)
	record = PSX._axes_title_gap_record(PSX._cmn_plot(f).layout)
	@test !haskey(record, "xaxis") && haskey(record, "yaxis")
	@test PSX._cmn_mapping_get(PSX._cmn_mapping_get(PSX._cmn_plot(f).layout.fields[:xaxis], :title), :standoff) == 30
	@test !PSX._finalize_figure!(f)
	# PlotStyle(title_gap = ...) sets the gap; `nothing` turns it off.
	@test PlotStyle(; title_gap = 0.8).title_gap == 0.8
	@test PSX._style_title_gap(PlotStyle(; width = 300, title_gap = nothing)) === nothing
	@test PSX._style_title_gap(PlotStyle(; width = 300)) == 0.5 && PSX._style_title_gap(PlotStyle()) === nothing
	@test_throws ArgumentError PlotStyle(; title_gap = -1)
end

@testset "v8 axes-style: V4 reference lines inside an autoranged frame (rendered)" begin
	PSX = PlotlySupply
	figs = Tuple{String, Any}[]
	for st in (:default, :ieee)
		push!(figs, ("$st line", with_style(st) do
			f = plot_scatter(1:5, [2.0, 3, 2.5, 4, 3.5]); hline!(f, 1.0); vline!(f, 6.0); f
		end))
		push!(figs, ("$st bars", with_style(st) do
			f = plot_bar(["a", "b", "c"], [3.0, 5.0, 4.0]); hline!(f, 0.8; dash = "dot"); f
		end))
		push!(figs, ("$st log", with_style(st) do
			f = plot_scatter(1:5, [20.0, 300, 50, 4000, 800]; yscale = "log"); hline!(f, 5.0); f
		end))
		push!(figs, ("$st cell (1,2)", with_style(st) do
			sf = subplots(1, 2; sync = false)
			plot_scatter!(sf, 1:3, [1.0, 2, 3]; row = 1, col = 1)
			plot_scatter!(sf, 1:3, [5.0, 6, 7]; row = 1, col = 2)
			hline!(sf, 2.0; row = 1, col = 2)
			sf
		end))
	end
	for (tag, f) in figs
		@test !PSX._finalize_figure!(f)
	end
	result = try
		[(tag, _v8ax_geometry(f)[1]) for (tag, f) in figs]
	catch err
		@test _v8ax_export_failed(err)
		nothing
	end
	if result !== nothing
		for (tag, geo) in result
			@test !isempty(geo["shapes"])
			for s in geo["shapes"]
				horizontal = s[4] - s[2] < s[3] - s[1]
				# The frame of the line's subplot: the x spines (top and bottom)
				# for a horizontal line, the y spines for a vertical one.
				frames = horizontal ? geo["frames"]["x"] : geo["frames"]["y"]
				mid = horizontal ? (s[1] + s[3]) / 2 : (s[2] + s[4]) / 2
				fr = only(filter(b -> horizontal ? b[1] <= mid <= b[3] : b[2] <= mid <= b[4], frames))
				at = horizontal ? (s[2] + s[4]) / 2 : (s[1] + s[3]) / 2
				lo, hi = horizontal ? (fr[2], fr[4]) : (fr[1], fr[3])
				inside = lo + 3 < at < hi - 3
				inside || @info "V4 line on the frame" tag at lo hi
				@test inside
			end
		end
	end
	# A user range is never changed.
	f = plot_scatter(1:5, [2.0, 3, 2.5, 4, 3.5]; yrange = (1.5, 4.5))
	hline!(f, 1.0)
	@test collect(PSX._cmn_mapping_get(PSX._cmn_plot(f).layout.fields[:yaxis], :range)) == [1.5, 4.5]
end

@testset "v8 axes-style: vm-hbartext value labels clear the mirrored ticks (rendered)" begin
	PSX = PlotlySupply
	names = ["ResNet-50", "ViT-B/16", "EfficientNet-B4", "ConvNeXt-T", "MobileNet-V3"]
	acc = [0.91, 0.87, 0.83, 0.79, 0.72]
	figs = [(st, with_style(() -> plot_bar(acc, names; orientation = "h", xlabel = "top-1 accuracy",
		text = string.(acc), textposition = "outside"), st)) for st in (:default, :ieee, :aps)]
	for (_, f) in figs
		@test !PSX._finalize_figure!(f)
	end
	result = try
		[(st, f, _v8ax_geometry(f)[1]) for (st, f) in figs]
	catch err
		@test _v8ax_export_failed(err)
		nothing
	end
	if result !== nothing
		for (st, f, geo) in result
			yaxis = PSX._cmn_plot(f).layout.fields[:yaxis]
			# Inside ticks mirrored on the right spine reach `ticklen` into the plot.
			mirrored = PSX._cmn_mapping_get(yaxis, :ticks) == "inside" && PSX._cmn_mapping_get(yaxis, :mirror) in ("ticks", "allticks")
			ticklen = mirrored ? Float64(PSX._cmn_mapping_get(yaxis, :ticklen)) : 0.0
			right = maximum(b -> b[3], geo["frames"]["y"])
			@test length(geo["bartext"]) == 5
			clear = all(b -> b[3] <= right - ticklen, geo["bartext"])
			clear || @info "vm-hbartext" st right ticklen ends = [b[3] for b in geo["bartext"]]
			@test clear
		end
	end
end

@testset "v8 axes-style: D23 contour labels beside a gap are not clipped (rendered)" begin
	x = range(-2, 2; length = 41); y = range(-2, 2; length = 41)
	Z = [hypot(a, b) for a in x, b in y]
	for i in eachindex(x), j in eachindex(y)
		(abs(x[i]) < 0.6 && y[j] > -0.2) && (Z[i, j] = NaN)
	end
	figs = [with_style(() -> plot_contour(x, y, Z; coloring = "lines", showlabels = true, ncontours = 8), st) for st in (:default, :ieee)]
	result = try
		[_v8ax_geometry(f)[1] for f in figs]
	catch err
		@test _v8ax_export_failed(err)
		nothing
	end
	if result !== nothing
		for geo in result
			entry = only(geo["contour"])
			@test entry["labels"] > 0
			# The lines keep the gap clip; the labels carry only the plot-area clip.
			@test entry["linesclip"] !== nothing
			@test all(c -> endswith(c, "plot)"), entry["clips"])
		end
	end
end

@testset "v8 axes-style: tick labels (vm-powerfmt, apia-11, numerics-10, numerics-03)" begin
	PSX = PlotlySupply
	ticks(svg, cls) = [replace(m.captures[1], r"<[^>]+>" => "") for m in
		eachmatch(Regex("<g class=\"$(cls)\"[^>]*>\\s*<text[^>]*>(.*?)</text>"), svg)]
	result = try
		(
			[String(savefig(with_style(() -> plot_scatter(collect(1:10), 950.0 .* (1:10); ylabel = "load (N)"), st); format = "svg"))
				for st in (:default, :ieee)],
			String(savefig(with_style(() -> plot_matrix([1.0 0.8 -0.2; 0.8 1.0 0.1; -0.2 0.1 1.0];
				xlabels = ["a", "b", "c"], ylabels = ["a", "b", "c"], crange = (-1, 1)), :ieee); format = "svg")),
		)
	catch err
		@test _v8ax_export_failed(err)
		nothing
	end
	if result !== nothing
		lines, matrix = result
		for svg in lines
			ls = ticks(svg, "ytick")
			# 950..9500: "2000", "4000", ... never "0.2×10⁴".
			@test !isempty(ls) && !any(l -> occursin(r"^[−-]?0\.\d+×10", l), ls)
		end
		# Matrix cell values carry the same minus sign (U+2212) as the colour bar.
		@test occursin(">−0.20<", matrix) && !occursin(">-0.20<", matrix)
	end
	# numerics-10: offset ticks of a narrow range far from zero are distinct.
	f = plot_scatter(1:9, collect(1e6 .+ (1:9) ./ 10))
	yticks!(f; offset = :auto)
	ya = PSX._cmn_plot(f).layout.fields[:yaxis]
	tv, tt = PSX._cmn_mapping_get(ya, :tickvals), PSX._cmn_mapping_get(ya, :ticktext)
	inside = [i for i in eachindex(tv) if 1e6 + 0.1 <= tv[i] <= 1e6 + 0.9]
	@test tt[inside] == ["1.0000002", "1.0000004", "1.0000006", "1.0000008"]
	err = try
		yticks!(plot_scatter(1:9, collect(1e15 .+ (1:9))); offset = :auto); nothing
	catch e
		e
	end
	@test err isa ArgumentError && startswith(err.msg, "yticks!: ") && occursin("too narrow", err.msg)
	# numerics-03: power tick labels on a secondary x axis.
	for (fwd, inv, x, want) in (
		(e -> 1.2398e-6 / e, m -> 1.2398e-6 / m, [1.0, 2.0], ["8×10<sup>−7</sup>", "10<sup>−6</sup>", "1.2×10<sup>−6</sup>"]),
		(g -> 1e9 * g, h -> h / 1e9, [1.0, 5.0], ["10<sup>9</sup>", "2×10<sup>9</sup>", "3×10<sup>9</sup>", "4×10<sup>9</sup>", "5×10<sup>9</sup>"]),
	)
		fig = plot_scatter(x, [1.0, 2.0])
		secondary_xaxis!(fig, fwd, inv)
		ax = only(v for (k, v) in PSX._cmn_plot(fig).layout.fields if occursin(r"^xaxis\d+$", String(k)))
		@test PSX._cmn_mapping_get(ax, :ticktext) == want
	end
end

@testset "v8 axes-style: errors-inputs-10 extreme ranges estimate, never InexactError" begin
	PSX = PlotlySupply
	X = [1.0, 2, 3]; Z = [1.0 2 3; 4 5 6; 7 8 9]
	f = plot_scatter(X, X; xrange = (-1e308, 1e308))
	@test !PSX._finalize_figure!(f)
	for xs in (X, ["2020-01-01", "2020-01-02", "2020-01-03"], ["a", "b", "c"])
		g = plot_scatter(xs, X)
		xrange!(g, (-1e308, 1e308))
		@test !PSX._finalize_figure!(g)
	end
	@test plot_heatmap(X, X, Z; crange = (-1e308, 1e308)) isa PSX.Plot
	@test plot_heatmap(X, X, [1e308 -1e308 0; 0 1 2; 3 4 5]) isa PSX.Plot
	sf = subplots(1, 2; sync = false)
	plot_heatmap!(sf, X, X, Z; row = 1, col = 1); plot_heatmap!(sf, X, X, Z; row = 1, col = 2)
	shared_colorbar!(sf; crange = (-1e308, 1e308))
	@test !PSX._finalize_figure!(sf)
	@test plot_surface(X, X, Z; zrange = (0.0, 5e-324)) isa PSX.Plot
	@test PSX._s3_nice_ticks((0.0, 5e-324), 5) == (Float64[], 0.0)
	@test PSX._fin_tick_chars(Dict{Symbol, Any}(), -1e308, 1e308, 300.0, false, true) == 4
end

@testset "v8 axes-style: state (sm-02, sm-11)" begin
	PSX = PlotlySupply
	for st in (:publication, :ieee, :default)
		@test !PSX._finalize_figure!(with_style(() -> plot_scatterpolar([0, 90, 180], [1.0, 2, 3]), st))
	end
	# A figure built under :default carries no style record and is not
	# re-styled by a finalize or an export inside with_style.
	sf = subplots(2, 2; sync = false)
	x = collect(range(0, 1; length = 20))
	plot_scatter!(sf, x, sin.(2pi .* x); row = 1, col = 1, legend = "a")
	plot_scatter!(sf, x, x .^ 2; row = 2, col = 1, xlabel = "a long x title that wraps maybe")
	before = PSX.PlotlyBase.JSON.json(PSX._cmn_plot(sf).layout)
	copy_ = deepcopy(sf)
	@test !with_style(() -> PSX._finalize_figure!(copy_), :ieee)
	@test PSX.PlotlyBase.JSON.json(PSX._cmn_plot(copy_).layout) == before
	result = try
		(String(savefig(sf; format = "svg")), with_style(() -> String(savefig(sf; format = "svg")), :ieee))
	catch err
		@test _v8ax_export_failed(err)
		nothing
	end
	if result !== nothing
		size_of(s) = match(r"<svg[^>]*width=\"([0-9.]+)[^\"]*\"[^>]*height=\"([0-9.]+)", s).captures
		@test size_of(result[1]) == size_of(result[2])
		@test PSX.PlotlyBase.JSON.json(PSX._cmn_plot(sf).layout) == before
	end
end

@testset "v8 axes-style: perf-spines all-cell spines!/grid! are linear in cells" begin
	function cost(n, f)
		sf = subplots(n, n; sync = false)
		for r in 1:n, c in 1:n
			plot_scatter!(sf, [1.0, 2.0, 3.0], [1.0, 4.0, 9.0]; row = r, col = c)
		end
		f(deepcopy(sf))     # compile
		g = deepcopy(sf)
		return @allocated f(g)
	end
	for f in (sf -> spines!(sf; style = :open, cells = :all), sf -> spines!(sf; bottom = (1, 4), cells = :all),
		sf -> grid!(sf; axis = :both, cells = :all))
		# 4x the cells: measured 3.2x (16 -> 64 cells); the per-cell merges of
		# the old code grew 8x.
		@test cost(8, f) / cost(4, f) < 4.5
	end
end
