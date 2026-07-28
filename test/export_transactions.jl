mutable struct _ExportTestApp
    exists::Bool
end

mutable struct _ExportTestWindow
    app::Any
    id::Int
    exists::Bool
    uri::String
    close_calls::Int
end

mutable struct _ExportTestBackend
    app::_ExportTestApp
    windows::Vector{_ExportTestWindow}
    construct_error::Bool
    ready_mode::Symbol
    readiness_calls::Int
    block_readiness::Bool
    readiness_entered::Channel{Nothing}
    readiness_release::Channel{Nothing}
    isopen_error::Bool
    close_calls::Int
    image_urls::Vector{String}
    image_calls::Int
    image_scripts::Vector{String}
    image_error::Bool
    pdf_payloads::Vector{Vector{UInt8}}
    pdf_complete_immediately::Bool
    pdf_start_count::Int
    pdf_jobs::Dict{String,Dict{Symbol,Any}}
    pdf_job_ids::Vector{String}
    pdf_tempdirs::Vector{String}
    pdf_callbacks::Vector{Any}
    pdf_poll_error::Bool
    pdf_start_error_after_registration::Bool
    block_pdf_poll::Bool
    pdf_poll_entered::Channel{Nothing}
    pdf_poll_release::Channel{Nothing}
    development_config::Any
    default_application::Any
    Window::Any
    run::Any
    isopen::Any
    close::Any
end

function _export_test_match(script::String, pattern::Regex, description::String)
    matched = match(pattern, script)
    matched === nothing && error("fake could not find $description in renderer script")
    return String(only(matched.captures))
end

function _export_test_run(ec::_ExportTestBackend, target, script::String)
    if occursin("typeof Plotly !== 'undefined'", script)
        ec.readiness_calls += 1
        if ec.block_readiness
            ec.block_readiness = false
            put!(ec.readiness_entered, nothing)
            take!(ec.readiness_release)
        end
        ec.ready_mode === :interrupt && throw(InterruptException())
        return ec.ready_mode === :ready ? "ready" : "waiting"
    elseif occursin("Plotly.toImage", script)
        ec.image_calls += 1
        push!(ec.image_scripts, script)
        ec.image_error && error("injected image renderer failure")
        isempty(ec.image_urls) && error("fake image response queue is empty")
        return popfirst!(ec.image_urls)
    elseif occursin("__ps_print_css", script)
        return "ok"
    elseif occursin("jobs.delete", script)
        job_id = _export_test_match(
            script,
            r"""jobs\.delete\("([^"]+)"\)""",
            "PDF delete key",
        )
        return pop!(ec.pdf_jobs, job_id, nothing) !== nothing
    elseif occursin("printToPDF", script) &&
           occursin("__plotlysupply_pdf_jobs", script)
        job_id = _export_test_match(
            script,
            r"""const key = "([^"]+)";""",
            "PDF job key",
        )
        path = _export_test_match(
            script,
            r"""writeFileSync\("([^"]+)", buf\)""",
            "PDF output path",
        )
        ec.pdf_start_count += 1
        payload_index = min(ec.pdf_start_count, length(ec.pdf_payloads))
        payload = ec.pdf_payloads[payload_index]
        job = Dict{Symbol,Any}(
            :done => false,
            :error => nothing,
        )
        ec.pdf_jobs[job_id] = job
        callback = () -> begin
            get(ec.pdf_jobs, job_id, nothing) === job || return false
            write(path, payload)
            job[:done] = true
            return true
        end
        push!(ec.pdf_callbacks, callback)
        push!(ec.pdf_job_ids, job_id)
        push!(ec.pdf_tempdirs, dirname(path))
        ec.pdf_complete_immediately && callback()
        ec.pdf_start_error_after_registration &&
            error("injected start transport failure")
        return "started"
    elseif occursin("return job === undefined", script)
        job_id = _export_test_match(
            script,
            r"""jobs\.get\("([^"]+)"\)""",
            "PDF status key",
        )
        if ec.block_pdf_poll
            ec.block_pdf_poll = false
            put!(ec.pdf_poll_entered, nothing)
            take!(ec.pdf_poll_release)
        end
        ec.pdf_poll_error && error("injected PDF poll transport failure")
        return get(ec.pdf_jobs, job_id, nothing)
    end
    error("unexpected fake Electron script: $(first(script, min(100, length(script))))")
end

function _ExportTestBackend(;
    construct_error::Bool=false,
    ready_mode::Symbol=:ready,
    image_urls::Vector{String}=String[
        "data:image/png;base64,$(base64encode(UInt8[0x50, 0x4e, 0x47]))",
    ],
    pdf_payloads::Vector{Vector{UInt8}}=Vector{UInt8}[collect(codeunits("%PDF-test"))],
)
    ec = _ExportTestBackend(
        _ExportTestApp(true),
        _ExportTestWindow[],
        construct_error,
        ready_mode,
        0,
        false,
        Channel{Nothing}(1),
        Channel{Nothing}(1),
        false,
        0,
        copy(image_urls),
        0,
        String[],
        false,
        copy(pdf_payloads),
        true,
        0,
        Dict{String,Dict{Symbol,Any}}(),
        String[],
        String[],
        Any[],
        false,
        false,
        false,
        Channel{Nothing}(1),
        Channel{Nothing}(1),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
    )
    ec.development_config = () -> :fake_security
    ec.default_application = (_args...) -> ec.app
    ec.Window = function (app, uri; width, height, title, show)
        ec.construct_error && error("injected export Window construction failure")
        window = _ExportTestWindow(app, length(ec.windows) + 1, true, String(uri), 0)
        push!(ec.windows, window)
        return window
    end
    ec.run = (target, script) -> _export_test_run(ec, target, String(script))
    ec.isopen = window -> begin
        ec.isopen_error && error("injected isopen transport failure")
        window.exists
    end
    ec.close = window -> begin
        ec.close_calls += 1
        window.close_calls += 1
        window.exists = false
        nothing
    end
    return ec
end

function _cleanup_export_test_state(state)
    PlotlySupply._cleanup_export_state_at_exit!(state)
    return nothing
end

mutable struct _ExportLockCheckingIO <: IO
    buffer::IOBuffer
    state::PlotlySupply._ExportState
    lock_was_free::Bool
end

_ExportLockCheckingIO(state) = _ExportLockCheckingIO(IOBuffer(), state, true)

function Base.unsafe_write(
    io::_ExportLockCheckingIO,
    pointer::Ptr{UInt8},
    byte_count::UInt,
)
    io.lock_was_free &= !islocked(io.state.lock)
    return Base.unsafe_write(io.buffer, pointer, byte_count)
end

struct _ExportFailingIO <: IO end

Base.unsafe_write(::_ExportFailingIO, ::Ptr{UInt8}, ::UInt) =
    error("injected destination write failure")

@testset "transactional export lifecycle" begin
    p = plot_scatter(1:2, 1:2)

    @testset "numeric preflight is strict and precedes destination mutation" begin
        invalid = (
            (:width, true),
            (:width, 0),
            (:width, -1),
            (:height, Inf),
            (:height, NaN),
            (:scale, false),
            (:scale, "1); globalThis.injected = true; ("),
        )
        mktempdir() do dir
            target = joinpath(dir, "existing.png")
            for (name, value) in invalid
                write(target, "sentinel")
                kwargs = NamedTuple{(name,)}((value,))
                @test_throws ArgumentError PlotlySupply._prepare_renderer_export(p, kwargs)
                @test_throws ArgumentError savefig(target, p; format="png", kwargs...)
                @test read(target, String) == "sentinel"
                @test readdir(dir) == ["existing.png"]
            end
            write(target, "sentinel")
            @test_throws ArgumentError savefig(
                target,
                p;
                format="png",
                unsupported_export_option=1,
            )
            @test read(target, String) == "sentinel"

            write(target, "sentinel")
            overflow_kwargs = (width=floatmax(Float64), scale=2.0)
            @test_throws ArgumentError PlotlySupply._prepare_renderer_export(
                p,
                overflow_kwargs,
            )
            @test_throws ArgumentError savefig(
                target,
                p;
                format="png",
                overflow_kwargs...,
            )
            @test read(target, String) == "sentinel"
            @test readdir(dir) == ["existing.png"]
        end

        state = PlotlySupply._ExportState()
        payload = UInt8[0x01, 0x02, 0x03]
        ec = _ExportTestBackend(
            image_urls=[
                "data:image/png;base64,$(base64encode(payload))",
            ],
        )
        try
            prepared = PlotlySupply._prepare_renderer_export(
                p,
                (width=12.5, height=7//2, scale=2),
            )
            io = IOBuffer()
            PlotlySupply._savefig_prepared(
                io,
                p,
                "png",
                prepared;
                state=state,
                ec=ec,
            )
            @test take!(io) == payload
            script = only(ec.image_scripts)
            @test occursin("width: 12.5", script)
            @test occursin("height: 3.5", script)
            @test occursin("scale: 2.0", script)
        finally
            _cleanup_export_test_state(state)
        end
    end

    @testset "filename formats infer as concrete strings" begin
        @test PlotlySupply._filename_export_format("figure.PNG", nothing) == "png"
        @test PlotlySupply._filename_export_format("figure", nothing) == "png"
        mktempdir() do dir
            plot_json = joinpath(dir, "plot.json")
            @test savefig(plot_json, p) == plot_json
            @test occursin("\"data\"", read(plot_json, String))

            sync = SyncPlot(p, nothing, nothing, "headless-export")
            sync_html = joinpath(dir, "sync.html")
            @test savefig(sync_html, sync) == sync_html
            @test occursin("Plotly", read(sync_html, String))

            sf = PlotlySupply.subplots(1, 1; sync=false, show=false)
            subplot_json = joinpath(dir, "subplot.json")
            @test savefig(subplot_json, sf) == subplot_json
            @test occursin("\"data\"", read(subplot_json, String))
        end
    end

    @testset "window construction and readiness are transactional" begin
        state = PlotlySupply._ExportState()
        ec = _ExportTestBackend(; ready_mode=:waiting)
        try
            @test_throws ErrorException PlotlySupply._ensure_export_window(
                state;
                ec=ec,
                timeout_s=0.001,
            )
            @test length(ec.windows) == 1
            @test only(ec.windows).close_calls == 1
            @test state.window === nothing
            @test !state.ready
            @test isempty(state.pending_windows)
            @test isempty(state.owned_tempdirs)

            failed_window = only(ec.windows)
            ec.ready_mode = :ready
            _, _, ready_window, _ = PlotlySupply._ensure_export_window(
                state;
                ec=ec,
                timeout_s=1,
            )
            @test ready_window !== failed_window
            @test length(ec.windows) == 2
            @test state.window === ready_window
            @test state.ready

            # A failed status query is "unknown", not "closed": retirement
            # must attempt close through the backend that created this window,
            # even when the caller supplies a different backend for replacement.
            replacement_backend = _ExportTestBackend()
            ec.isopen_error = true
            _, _, replacement_window, _ =
                PlotlySupply._ensure_export_window(
                    state;
                    ec=replacement_backend,
                    timeout_s=1,
                )
            @test ready_window.close_calls == 1
            @test ec.close_calls == 2
            @test replacement_backend.close_calls == 0
            @test replacement_window === only(replacement_backend.windows)
            @test state.backend === replacement_backend
        finally
            _cleanup_export_test_state(state)
        end

        mktempdir() do temp_root
            state = PlotlySupply._ExportState()
            ec = _ExportTestBackend(; construct_error=true)
            try
                withenv("TMPDIR" => temp_root) do
                    @test_throws ErrorException PlotlySupply._ensure_export_window(
                        state;
                        ec=ec,
                        timeout_s=1,
                    )
                end
                @test isempty(readdir(temp_root))
                @test isempty(state.owned_tempdirs)
            finally
                _cleanup_export_test_state(state)
            end
        end

        state = PlotlySupply._ExportState()
        ec = _ExportTestBackend(; ready_mode=:interrupt)
        try
            @test_throws InterruptException PlotlySupply._ensure_export_window(
                state;
                ec=ec,
                timeout_s=1,
            )
            @test length(ec.windows) == 1
            @test only(ec.windows).close_calls == 1
            @test isempty(state.owned_tempdirs)
        finally
            _cleanup_export_test_state(state)
        end

        state = PlotlySupply._ExportState()
        ec = _ExportTestBackend(; ready_mode=:waiting)
        removal_attempts = Ref(0)
        state.tempdir_remover = path -> begin
            removal_attempts[] += 1
            removal_attempts[] == 1 &&
                error("injected export temp cleanup failure")
            rm(path; recursive=true, force=true)
        end
        try
            err = @test_logs (
                :warn,
                r"Failed to remove a partially constructed export temp directory",
            ) begin
                try
                    PlotlySupply._ensure_export_window(
                        state;
                        ec=ec,
                        timeout_s=0.001,
                    )
                    nothing
                catch caught
                    caught
                end
            end
            @test err isa ErrorException
            @test removal_attempts[] == 1
            stale_tempdir = only(state.owned_tempdirs)
            @test ispath(stale_tempdir)

            ec.ready_mode = :ready
            PlotlySupply._ensure_export_window(state; ec=ec, timeout_s=1)
            @test removal_attempts[] == 2
            @test !ispath(stale_tempdir)
            @test state.ready
        finally
            _cleanup_export_test_state(state)
        end
    end

    @testset "one state lock prevents duplicate and cross-format capture" begin
        state = PlotlySupply._ExportState()
        ec = _ExportTestBackend(
            image_urls=[
                "data:image/png;base64,$(base64encode(codeunits("IMAGE")))",
            ],
            pdf_payloads=[
                collect(codeunits("%PDF-A")),
                collect(codeunits("%PDF-B")),
                collect(codeunits("%PDF-C")),
            ],
        )
        try
            ec.block_readiness = true
            first = @async PlotlySupply._ensure_export_window(state; ec=ec)
            take!(ec.readiness_entered)
            second = @async PlotlySupply._ensure_export_window(state; ec=ec)
            yield()
            @test length(ec.windows) == 1
            put!(ec.readiness_release, nothing)
            first_result = fetch(first)
            second_result = fetch(second)
            @test first_result[3] === second_result[3]
            @test length(ec.windows) == 1

            prepared = PlotlySupply._prepare_renderer_export(p, NamedTuple())
            ec.block_pdf_poll = true
            pdf_io = IOBuffer()
            pdf_task = @async PlotlySupply._savefig_prepared(
                pdf_io,
                p,
                "pdf",
                prepared;
                state=state,
                ec=ec,
            )
            take!(ec.pdf_poll_entered)
            image_io = IOBuffer()
            image_task = @async PlotlySupply._savefig_prepared(
                image_io,
                p,
                "png",
                prepared;
                state=state,
                ec=ec,
            )
            yield()
            @test ec.image_calls == 0
            put!(ec.pdf_poll_release, nothing)
            @test fetch(pdf_task) === nothing
            @test fetch(image_task) === nothing
            @test String(take!(pdf_io)) == "%PDF-A"
            @test String(take!(image_io)) == "IMAGE"

            pdf_outputs = [IOBuffer(), IOBuffer()]
            jobs = [
                @async PlotlySupply._savefig_prepared(
                    pdf_outputs[index],
                    p,
                    "pdf",
                    prepared;
                    state=state,
                    ec=ec,
                )
                for index in eachindex(pdf_outputs)
            ]
            foreach(fetch, jobs)
            @test Set(String(take!(io)) for io in pdf_outputs) ==
                  Set(("%PDF-B", "%PDF-C"))
            @test length(unique(ec.pdf_job_ids)) == 3
            @test isempty(ec.pdf_jobs)
            @test all(path -> !ispath(path), ec.pdf_tempdirs)
        finally
            isready(ec.readiness_release) || put!(ec.readiness_release, nothing)
            isready(ec.pdf_poll_release) || put!(ec.pdf_poll_release, nothing)
            _cleanup_export_test_state(state)
        end
    end

    @testset "PDF failures reclaim private jobs and directories" begin
        for failure in (:poll, :start, :timeout)
            state = PlotlySupply._ExportState()
            ec = _ExportTestBackend()
            failure === :poll && (ec.pdf_poll_error = true)
            failure === :start && (ec.pdf_start_error_after_registration = true)
            failure === :timeout && (ec.pdf_complete_immediately = false)
            prepared = PlotlySupply._prepare_renderer_export(p, NamedTuple())
            try
                @test_throws ErrorException PlotlySupply._savefig_prepared(
                    IOBuffer(),
                    p,
                    "pdf",
                    prepared;
                    state=state,
                    ec=ec,
                    pdf_timeout_s=failure === :timeout ? 0.001 : 15.0,
                )
                @test isempty(ec.pdf_jobs)
                @test all(path -> !ispath(path), ec.pdf_tempdirs)
                if failure === :timeout
                    @test only(ec.pdf_callbacks)() === false
                    @test all(path -> !ispath(path), ec.pdf_tempdirs)
                end
            finally
                _cleanup_export_test_state(state)
            end
        end
    end

    @testset "captured output writes occur after releasing renderer lock" begin
        state = PlotlySupply._ExportState()
        image_bytes = collect(codeunits("image-payload"))
        pdf_bytes = collect(codeunits("%PDF-payload"))
        ec = _ExportTestBackend(
            image_urls=[
                "data:image/png;base64,$(base64encode(image_bytes))",
            ],
            pdf_payloads=[pdf_bytes],
        )
        prepared = PlotlySupply._prepare_renderer_export(p, NamedTuple())
        try
            image_io = _ExportLockCheckingIO(state)
            PlotlySupply._savefig_prepared(
                image_io,
                p,
                "png",
                prepared;
                state=state,
                ec=ec,
            )
            @test image_io.lock_was_free
            @test take!(image_io.buffer) == image_bytes

            pdf_io = _ExportLockCheckingIO(state)
            PlotlySupply._savefig_prepared(
                pdf_io,
                p,
                "pdf",
                prepared;
                state=state,
                ec=ec,
            )
            @test pdf_io.lock_was_free
            @test take!(pdf_io.buffer) == pdf_bytes
        finally
            _cleanup_export_test_state(state)
        end
    end

    @testset "PDF copy is exact and bounded" begin
        mktempdir() do dir
            small_path = joinpath(dir, "small.pdf")
            small = [UInt8(index % 251) for index in 0:65_536]
            write(small_path, small)
            io = IOBuffer()
            PlotlySupply._copy_pdf_file_chunked!(io, small_path)
            @test take!(io) == small

            large_path = joinpath(dir, "large.pdf")
            block = fill(UInt8(0x5a), 64 * 1024)
            open(large_path, "w") do output
                for _ in 1:128
                    write(output, block)
                end
            end
            PlotlySupply._copy_pdf_file_chunked!(devnull, large_path)
            allocated = @allocated PlotlySupply._copy_pdf_file_chunked!(
                devnull,
                large_path,
            )
            @test allocated < 512 * 1024

            captured_dir = mktempdir(dir)
            captured_path = joinpath(captured_dir, "output.pdf")
            write(captured_path, "%PDF-cleanup-precedence")
            cleanup_state = PlotlySupply._ExportState()
            push!(cleanup_state.owned_pdf_tempdirs, captured_dir)
            captured = PlotlySupply._CapturedPDF(
                captured_dir,
                captured_path,
                cleanup_state,
            )
            failing_remover = _path ->
                error("injected captured-PDF cleanup failure")
            err = @test_logs (:warn, r"Failed to remove a captured PDF") begin
                try
                    PlotlySupply._write_captured_pdf!(
                        _ExportFailingIO(),
                        captured;
                        tempdir_remover=failing_remover,
                    )
                    nothing
                catch caught
                    caught
                end
            end
            @test err isa ErrorException
            @test occursin("destination write failure", sprint(showerror, err))
            @test ispath(captured_dir)
            @test captured_dir in cleanup_state.owned_pdf_tempdirs
            _cleanup_export_test_state(cleanup_state)
            @test !ispath(captured_dir)
            @test isempty(cleanup_state.owned_pdf_tempdirs)
        end
    end

    @testset "filename publication is one atomic rename" begin
        mktempdir() do dir
            target = joinpath(dir, "figure.png")
            state = PlotlySupply._ExportState()
            ec = _ExportTestBackend(
                image_urls=[
                    "data:image/png;base64,$(base64encode(codeunits("new-one")))",
                    "data:image/png;base64,$(base64encode(codeunits("new-two")))",
                    "data:image/png;base64,$(base64encode(codeunits("new-three")))",
                ],
            )
            prepared = PlotlySupply._prepare_renderer_export(p, NamedTuple())
            try
                write(target, "sentinel")
                ec.image_error = true
                @test_throws ErrorException PlotlySupply._savefig_atomic(
                    target,
                    p,
                    "png",
                    prepared;
                    state=state,
                    ec=ec,
                )
                @test read(target, String) == "sentinel"
                @test readdir(dir) == ["figure.png"]

                ec.image_error = false
                rejecting_rename = (source, destination) ->
                    error("injected atomic commit failure")
                @test_throws ErrorException PlotlySupply._savefig_atomic(
                    target,
                    p,
                    "png",
                    prepared;
                    state=state,
                    ec=ec,
                    renamer=rejecting_rename,
                )
                @test read(target, String) == "sentinel"
                @test readdir(dir) == ["figure.png"]

                @test PlotlySupply._savefig_filename(
                    target,
                    p,
                    nothing,
                    NamedTuple();
                    state=state,
                    ec=ec,
                ) == target
                @test read(target, String) == "new-two"
                @test readdir(dir) == ["figure.png"]
            finally
                _cleanup_export_test_state(state)
            end
        end
    end
end
