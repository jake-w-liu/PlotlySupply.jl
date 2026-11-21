using Test, PlotlySupply

@testset "MathJax font-context compatibility asset" begin
    @testset "public update! remains the PlotlyBase binding" begin
        @test isdefined(PlotlySupply, :update!)
        @test PlotlySupply.update! === PlotlySupply.PlotlyBase.update!
        @test update! === PlotlySupply.PlotlyBase.update!
        p = plot_scatter([0.0,1.0], [1.0,2.0])
        update!(p, 1, Dict(:opacity => 0.25))
        @test p.data[1][:opacity] == 0.25
        @test p.data[1][:y] == [1.0,2.0]
    end
    raw = PlotlySupply._plotlyjs_asset_path()
    source = read(raw, String)
    license_path = joinpath(dirname(raw), "LICENSE")
    license = read(license_path, String)
    raw_digest = PlotlySupply._plotlyjs_file_digest(raw)
    @test raw_digest == "6d21266ce1bd7d9e5ab4e115989c70c20de0382fd973a8f26ab58619eba4d603"
    @test PlotlySupply._plotlyjs_file_digest(license_path) == "67a26cf80f03ff388f26945dfc1f6caed1a0746ff43871190339b3aee49b94bb"
    needle = PlotlySupply._PLOTLYJS_MATH_FONT_SEAM
    replacement = PlotlySupply._PLOTLYJS_MATH_FONT_REPLACEMENT
    patched = PlotlySupply._patch_plotlyjs_math_fonts(source)

    @testset "guarded reversible font and serialization changes" begin
        @test count(needle, source) == 1
        @test count(replacement, patched) == 1
        @test !occursin(needle, patched)
        restored = patched
        for (old, new) in reverse(PlotlySupply._PLOTLYJS_COMPAT_TRANSFORMS)
            restored = replace(restored, new => old; count=1)
        end
        @test restored == source
        @test startswith(patched, first(source, 180))
        @test occursin("\"font-family\":t.node().style.fontFamily,\"font-size\":r+\"px\"", replacement)
        @test_throws ErrorException PlotlySupply._patch_plotlyjs_math_fonts(replace(source, needle => ""))
        @test_throws ErrorException PlotlySupply._patch_plotlyjs_math_fonts(source * needle)
        @test_throws ErrorException PlotlySupply._patch_plotlyjs_math_fonts(patched)
        for (old, new) in PlotlySupply._PLOTLYJS_SVG_QUOTE_TRANSFORMS
            @test count(old, source) == 1
            @test count(new, patched) == 1
            @test_throws ErrorException PlotlySupply._patch_plotlyjs_math_fonts(replace(source, old => ""))
            @test_throws ErrorException PlotlySupply._patch_plotlyjs_math_fonts(source * old)
        end
        @test occursin(raw"""return"&quot;"===t?t:""", patched)
        # tm-legend-math-title-clip: the legend title reads its own MathJax group
        @test count(PlotlySupply._PLOTLYJS_LEGEND_TITLE_MATH_SEAM, source) == 1
        @test count(PlotlySupply._PLOTLYJS_LEGEND_TITLE_MATH_REPLACEMENT, patched) == 1
        @test !occursin(PlotlySupply._PLOTLYJS_LEGEND_TITLE_MATH_SEAM, patched)
        # tm-twoline-math-axis-title: the rows of a math axis title count as lines
        for (seam, replacement) in (
            PlotlySupply._PLOTLYJS_AXIS_TITLE_ROOM_SEAM => PlotlySupply._PLOTLYJS_AXIS_TITLE_ROOM_REPLACEMENT,
            PlotlySupply._PLOTLYJS_AXIS_TITLE_SHIFT_SEAM => PlotlySupply._PLOTLYJS_AXIS_TITLE_SHIFT_REPLACEMENT,
        )
            @test count(seam, source) == 1
            @test count(replacement, patched) == 1
            @test !occursin(seam, patched)
        end
        @test PlotlySupply._plotlyjs_file_digest(raw) == raw_digest
    end

    @testset "lazy state, shared publication and explicit cleanup" begin
        mktempdir() do parent
            state = PlotlySupply._PlotlyJSCompatAssetState()
            @test state.asset === nothing
            @test isempty(state.unpublished)
            @test isempty(readdir(parent))
            path = PlotlySupply._plotlyjs_render_asset_path(;state,cache_parent=parent)
            @test path != raw
            @test read(path, String) == patched
            @test read(joinpath(dirname(path), "LICENSE"), String) == license
            @test PlotlySupply._plotlyjs_render_asset_path(;state,cache_parent=parent) == path
            @test length(readdir(parent)) == 1
            PlotlySupply._cleanup_plotlyjs_compat_asset!(state)
            @test state.asset === nothing
            @test isempty(state.unpublished)
            @test !ispath(path)
            @test isempty(readdir(parent))
            @test isfile(raw)
            PlotlySupply._cleanup_plotlyjs_compat_asset!(state)
            @test isempty(readdir(parent))
        end
    end

    @testset "concurrent callers publish one complete asset" begin
        mktempdir() do parent
            state = PlotlySupply._PlotlyJSCompatAssetState()
            writes = Threads.Atomic{Int}(0)
            writer = (path, text) -> (Threads.atomic_add!(writes, 1); write(path, text))
            paths = Vector{String}(undef, 8)
            @sync for i in eachindex(paths)
                Threads.@spawn paths[i] = PlotlySupply._plotlyjs_render_asset_path(
                    ;state,cache_parent=parent,write_file=writer)
            end
            @test length(unique(paths)) == 1
            @test writes[] == 2
            @test length(readdir(parent)) == 1
            @test read(first(paths), String) == patched
            PlotlySupply._cleanup_plotlyjs_compat_asset!(state)
            @test isempty(readdir(parent))
        end
    end

    @testset "source, license and write failures do not publish" begin
        mktempdir() do parent
            input = joinpath(parent, "input");mkdir(input)
            copied = joinpath(input, "plotly.min.js")
            copied_license = joinpath(input, "LICENSE")
            write(copied, source);write(copied_license, license)
            state = PlotlySupply._PlotlyJSCompatAssetState()
            write(copied, source * " ")
            @test_throws ErrorException PlotlySupply._plotlyjs_render_asset_path(
                ;state,source_path=copied,cache_parent=parent)
            @test readdir(parent) == ["input"]
            write(copied, source);write(copied_license, "wrong license")
            @test_throws ErrorException PlotlySupply._plotlyjs_render_asset_path(
                ;state,source_path=copied,cache_parent=parent)
            @test readdir(parent) == ["input"]
            write(copied_license, license)
            failure = ErrorException("injected compatibility write failure")
            caught = try
                PlotlySupply._plotlyjs_render_asset_path(;state,source_path=copied,cache_parent=parent,
                    write_file=(path,text)->(write(path,"partial");throw(failure)))
                nothing
            catch err
                err
            end
            @test caught === failure
            @test state.asset === nothing
            @test isempty(state.unpublished)
            @test readdir(parent) == ["input"]
            @test_throws ErrorException PlotlySupply._plotlyjs_render_asset_path(
                ;state,source_path=copied,cache_parent=parent,write_file=(path,text)->write(path,"truncated"))
            @test state.asset === nothing
            @test readdir(parent) == ["input"]
            @test read(copied, String) == source
        end
    end

    @testset "failed cleanup retains ownership and the primary error" begin
        mktempdir() do parent
            state = PlotlySupply._PlotlyJSCompatAssetState()
            failure = ErrorException("primary write failure")
            caught = Ref{Any}(nothing)
            @test_logs (:warn,r"unpublished Plotly.js") begin
                try
                    PlotlySupply._plotlyjs_render_asset_path(;state,cache_parent=parent,
                        write_file=(path,text)->throw(failure),
                        remove_directory=path->error("injected cleanup failure"))
                catch err
                    caught[] = err
                end
            end
            @test caught[] === failure
            @test state.asset === nothing
            @test length(state.unpublished) == 1
            @test all(isdir, state.unpublished)
            PlotlySupply._cleanup_plotlyjs_compat_asset!(state)
            @test isempty(state.unpublished)
            @test isempty(readdir(parent))
            path = PlotlySupply._plotlyjs_render_asset_path(;state,cache_parent=parent)
            asset = state.asset
            @test_throws ErrorException PlotlySupply._cleanup_plotlyjs_compat_asset!(state;
                remove_directory=path->error("injected published cleanup failure"))
            @test state.asset === asset
            @test isfile(path)
            PlotlySupply._cleanup_plotlyjs_compat_asset!(state)
            @test !ispath(path)
        end
    end

    @testset "changed published data fail closed without touching the artifact" begin
        mktempdir() do parent
            state = PlotlySupply._PlotlyJSCompatAssetState()
            path = PlotlySupply._plotlyjs_render_asset_path(;state,cache_parent=parent)
            asset = state.asset
            write(path, "changed")
            @test_throws ErrorException PlotlySupply._plotlyjs_render_asset_path(;state,cache_parent=parent)
            @test state.asset === asset
            @test read(path, String) == "changed"
            @test PlotlySupply._plotlyjs_file_digest(raw) == raw_digest
            PlotlySupply._cleanup_plotlyjs_compat_asset!(state)
            path = PlotlySupply._plotlyjs_render_asset_path(;state,cache_parent=parent)
            write(joinpath(dirname(path), "LICENSE"), "changed license")
            @test_throws ErrorException PlotlySupply._plotlyjs_render_asset_path(;state,cache_parent=parent)
            PlotlySupply._cleanup_plotlyjs_compat_asset!(state)
            @test isempty(readdir(parent))
        end
    end

    @testset "portable HTML source guard and shared rendering routes" begin
        tag = "<script src=\"$(PlotlySupply._PLOTLY_CDN_URL)\"></script>"
        @test_throws ErrorException PlotlySupply._inline_plotlyjs_source("none", patched, license)
        @test_throws ErrorException PlotlySupply._inline_plotlyjs_source(tag*tag, patched, license)
        for token in ("</script", "</SCRIPT>", "</ScRiPt >")
            @test_throws ErrorException PlotlySupply._inline_plotlyjs_source(tag, "prefix"*token, license)
        end
        @test_throws ErrorException PlotlySupply._inline_plotlyjs_source(tag, patched, "*/")
        html = PlotlySupply._inline_plotlyjs_source(tag, patched, license)
        @test !occursin(tag, html)
        @test occursin(patched, html)
        @test occursin(license, html)
        @test count(replacement, html) == 1
        uri = PlotlySupply._plotlyjs_render_asset_uri()
        @test occursin(uri, PlotlySupply._syncplot_html("font-live";autoplay=false,timeout_s=1.0))
        @test occursin(uri, PlotlySupply._export_window_html("font-export"))
        @test PlotlySupply._plotlyjs_asset_uri() != uri
        p = plot_scatter(0:2, 0:2;legend=raw"$\mathit{Field}$",fontsize=18)
        before = savefig(p;format="json")
        exported = String(savefig(p;format="html"))
        @test occursin(replacement, exported)
        @test occursin(license, exported)
        @test !occursin(tag, exported)
        @test occursin("Latin-Modern", exported)
        @test savefig(p;format="json") == before
        @test PlotlySupply._plotlyjs_file_digest(raw) == raw_digest
    end
end
