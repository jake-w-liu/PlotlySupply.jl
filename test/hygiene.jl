# Static checks on the test suite itself, so that every file keeps running on
# its own (`julia --project=. test/<file>.jl`) and under Pkg.test, every file
# is run by runtests.jl, and failure assertions name the exception they expect.

using Test
using PlotlySupply

isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")

# Package names declared in a section of a Project.toml: the `Name = "uuid"`
# entries of [deps]/[extras] and the names in `test = [...]` of [targets].
# Pkg writes these sections in this flat form; the file is read as text because
# the TOML stdlib is not a test dependency.
function _hygiene_project_names(path::AbstractString)
    names = Dict{String, Set{Symbol}}()
    section = ""
    for line in eachline(path)
        stripped = strip(line)
        header = match(r"^\[([^\[\]]+)\]$", stripped)
        if header !== nothing
            section = header.captures[1]
            continue
        end
        if section in ("deps", "extras")
            entry = match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\"[0-9a-fA-F-]+\"", stripped)
            entry === nothing || push!(get!(Set{Symbol}, names, section), Symbol(entry.captures[1]))
        elseif section == "targets"
            target = match(r"^test\s*=\s*\[(.*)\]", stripped)
            target === nothing && continue
            for name in eachmatch(r"\"([^\"]+)\"", target.captures[1])
                push!(get!(Set{Symbol}, names, "test"), Symbol(name.captures[1]))
            end
        end
    end
    return names
end

# Root module of every `using`/`import` in an expression tree (relative
# imports such as `using ..M` are skipped).
function _hygiene_imported_roots!(roots::Set{Symbol}, ex)
    ex isa Expr || return roots
    if ex.head in (:using, :import)
        for arg in ex.args
            path = arg isa Expr && arg.head === :(:) ? arg.args[1] : arg
            path = path isa Expr && path.head === :as ? path.args[1] : path
            if path isa Expr && path.head === :. && !isempty(path.args) && path.args[1] !== :.
                push!(roots, path.args[1])
            end
        end
    else
        foreach(arg -> _hygiene_imported_roots!(roots, arg), ex.args)
    end
    return roots
end

# Names a file defines at top level: functions, structs, consts and globals.
function _hygiene_defined_names(toplevel)
    names = Set{Symbol}()
    for ex in toplevel.args
        ex isa Expr || continue
        while ex isa Expr && ex.head in (:const, :global)
            ex = ex.args[1]
        end
        ex isa Expr || continue
        if ex.head === :struct
            name = ex.args[2]
            name = name isa Expr && name.head === :<: ? name.args[1] : name
            name isa Symbol && push!(names, name)
        elseif ex.head in (:function, :(=))
            lhs = ex.args[1]
            lhs = lhs isa Expr && lhs.head === :where ? lhs.args[1] : lhs
            lhs = lhs isa Expr && lhs.head === :(::) ? lhs.args[1] : lhs
            name = lhs isa Expr && lhs.head === :call ? lhs.args[1] : lhs
            name isa Symbol && push!(names, name)
        end
    end
    return names
end

function _hygiene_symbols!(symbols::Set{Symbol}, ex)
    if ex isa Symbol
        push!(symbols, ex)
    elseif ex isa Expr
        foreach(arg -> _hygiene_symbols!(symbols, arg), ex.args)
    end
    return symbols
end

# Whether an expression calls `include(<file>)` (also inside the
# `isdefined(...) || include(...)` guard); `file` is a literal name or the
# variable holding it.
function _hygiene_includes(ex, file::Union{AbstractString, Symbol})
    ex isa Expr || return false
    ex.head === :call && ex.args[1] === :include && length(ex.args) == 2 &&
        ex.args[2] == file && return true
    return any(arg -> _hygiene_includes(arg, file), ex.args)
end

# Whether an expression holds `for f in _test_files_in_run_order(...)` with a
# body that calls `include(f)`.
function _hygiene_runs_listed_files(ex)
    ex isa Expr || return false
    if ex.head === :for
        spec = ex.args[1]
        if Meta.isexpr(spec, :(=)) && spec.args[1] isa Symbol &&
           Meta.isexpr(spec.args[2], :call) && spec.args[2].args[1] === :_test_files_in_run_order &&
           _hygiene_includes(ex.args[2], spec.args[1])
            return true
        end
    end
    return any(_hygiene_runs_listed_files, ex.args)
end

@testset "Test-suite hygiene" begin
    testdir = @__DIR__
    files = sort!(filter(name -> endswith(name, ".jl"), readdir(testdir)))
    parsed = Dict(
        name => Meta.parseall(read(joinpath(testdir, name), String); filename=name)
        for name in files
    )
    @test all(ast -> !Meta.isexpr(ast, :error) &&
        !any(ex -> Meta.isexpr(ex, (:error, :incomplete)), ast.args), values(parsed))

    @testset "checkers read the forms they look for" begin
        roots(src) = _hygiene_imported_roots!(Set{Symbol}(), Meta.parseall(src))
        @test roots("using Test, PlotlySupply") == Set([:Test, :PlotlySupply])
        @test roots("using PlotlySupply: PlotlyBase\nimport Dates as D") == Set([:PlotlySupply, :Dates])
        @test roots("@testset \"t\" begin\n using Base64\nend") == Set([:Base64])
        @test isempty(roots("using ..LocalModule"))
        @test _hygiene_defined_names(Meta.parseall(
            "struct A <: B end\nf(x) = x\nfunction g(y::Int) end\nconst C = 1\nh(x)::Int = x",
        )) == Set([:A, :f, :g, :C, :h])
        @test _hygiene_includes(
            Meta.parse("isdefined(@__MODULE__, :X) || include(\"testutils.jl\")"),
            "testutils.jl",
        )
        @test !_hygiene_includes(Meta.parse("include(\"other.jl\")"), "testutils.jl")
        @test _hygiene_runs_listed_files(Meta.parseall(
            "@testset \"all\" begin\n for f in _test_files_in_run_order(@__DIR__)\n include(f)\n end\nend",
        ))
        @test !_hygiene_runs_listed_files(Meta.parseall(
            "for f in _test_files_in_run_order(@__DIR__)\n println(f)\nend",
        ))
        @test !_hygiene_runs_listed_files(Meta.parseall("for f in readdir()\n include(f)\nend"))
        mktemp() do path, io
            write(io, "[deps]\nFoo = \"0a1b2c3d-0000-0000-0000-000000000000\"\n\n" *
                "[extras]\nBar = \"0a1b2c3d-0000-0000-0000-000000000001\"\n" *
                "Baz = \"0a1b2c3d-0000-0000-0000-000000000002\"\n\n[targets]\ntest = [\"Bar\"]\n")
            close(io)
            @test _hygiene_project_names(path) == Dict(
                "deps" => Set([:Foo]), "extras" => Set([:Bar, :Baz]), "test" => Set([:Bar]),
            )
        end
    end

    @testset "imports are declared test dependencies" begin
        project = joinpath(dirname(testdir), "Project.toml")
        declared = _hygiene_project_names(project)
        loadable = union(
            Set([:Base, :Core, :Main, :PlotlySupply]),
            get(declared, "deps", Set{Symbol}()),
            intersect(get(declared, "extras", Set{Symbol}()), get(declared, "test", Set{Symbol}())),
        )
        @test :Test in loadable
        undeclared = Dict{String, Vector{Symbol}}()
        for (name, ast) in parsed
            missing_roots = setdiff(_hygiene_imported_roots!(Set{Symbol}(), ast), loadable)
            isempty(missing_roots) || (undeclared[name] = sort!(collect(missing_roots)))
        end
        # Pkg.test loads only [deps] and the test target's [extras]; anything
        # else fails with "Package X not found in current path".
        @test isempty(undeclared)
    end

    @testset "every file runs standalone" begin
        helpers = _hygiene_defined_names(parsed["testutils.jl"])
        @test :_LifecycleFakeElectron in helpers && :_test_field_trace in helpers
        missing_using = String[]
        missing_helpers = Dict{String, Vector{Symbol}}()
        for (name, ast) in parsed
            roots = Set{Symbol}()
            for ex in ast.args
                Meta.isexpr(ex, :using) && _hygiene_imported_roots!(roots, ex)
            end
            (:Test in roots && :PlotlySupply in roots) || push!(missing_using, name)

            name == "testutils.jl" && continue
            used = intersect(
                setdiff(_hygiene_symbols!(Set{Symbol}(), ast), _hygiene_defined_names(ast)),
                helpers,
            )
            if !isempty(used) && !any(ex -> _hygiene_includes(ex, "testutils.jl"), ast.args)
                missing_helpers[name] = sort!(collect(used))
            end
        end
        # each file loads its own packages ...
        @test isempty(sort!(missing_using))
        # ... and the shared fixtures it uses (`isdefined(...) || include("testutils.jl")`)
        @test isempty(missing_helpers)
    end

    @testset "runtests.jl runs every test file" begin
        # The run order lists every test file once: the fixed first files, then
        # the rest in name order; files that are not `.jl` sources are left out.
        order = _test_files_in_run_order(testdir)
        @test sort(order) == filter(name -> !(name in ("runtests.jl", "testutils.jl")), files)
        @test allunique(order)
        # every file listed to run first exists (a renamed or removed one would be skipped)
        @test isempty(filter(!in(files), collect(_TEST_FILES_RUN_FIRST)))
        @test order[1:length(_TEST_FILES_RUN_FIRST)] == collect(_TEST_FILES_RUN_FIRST)
        mktempdir() do dir
            for name in ("zz_new.jl", "a_new.jl", "runtests.jl", "testutils.jl", "notes.md", _TEST_FILES_RUN_FIRST...)
                write(joinpath(dir, name), "")
            end
            mkdir(joinpath(dir, "fixtures.jl"))
            @test _test_files_in_run_order(dir) == [_TEST_FILES_RUN_FIRST..., "a_new.jl", "zz_new.jl"]
            rm(joinpath(dir, "nested_series.jl"))
            @test _test_files_in_run_order(dir) ==
                [filter(!=("nested_series.jl"), collect(_TEST_FILES_RUN_FIRST))..., "a_new.jl", "zz_new.jl"]
        end

        # runtests.jl includes that list, and no test file a second time.
        runner = parsed["runtests.jl"]
        @test _hygiene_runs_listed_files(runner)
        @test isempty(filter(
            name -> name != "testutils.jl" && _hygiene_includes(runner, name), files))
    end

    @testset "failure assertions name the exception" begin
        # A bare `Exception` type in @test_throws passes on any error,
        # including a typo or a MethodError from the test itself.
        loose = Regex("@test_throws\\s+" * "Exception\\b")
        offenders = String[]
        for name in files
            for (lineno, line) in enumerate(eachline(joinpath(testdir, name)))
                occursin(loose, line) && push!(offenders, "$name:$lineno")
            end
        end
        @test isempty(offenders)
    end
end
