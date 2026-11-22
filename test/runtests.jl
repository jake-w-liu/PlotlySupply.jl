using Test
using PlotlySupply

isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")

# The whole run is one test set, "PlotlySupply.jl", whose body is only the
# loop below: every test file is `include`d inside it, and `include` lowers and
# compiles a file's top-level statements one at a time, as the run reaches
# them. (One `@testset` block holding the 5550 lines of core_suite.jl was a
# single thunk whose compilation alone took longer than the CI job,
# tests-ci-06.) It relies on nothing but `@testset` and `include`, so it runs
# on every supported Julia (Test's internal testset stack is a ScopedValue
# from 1.13 on). Every result is recorded in the root set, whose summary is
# printed at the end and fails the run.
_runtests_t0 = time()
@testset "PlotlySupply.jl" begin
    # Every test/*.jl file: the ones in `_TEST_FILES_RUN_FIRST` (testutils.jl)
    # first, core_suite.jl leading, then all the rest, including the sci_* and
    # regression_* suites, in name order. A new file needs no registration.
    # Each file runs inside its own test set, so an error a file raises outside
    # its testsets is recorded against that file and the run goes on.
    for test_file in _test_files_in_run_order(@__DIR__)
        defaults_before = _global_defaults_snapshot()
        registries_before = _global_registries_snapshot()
        file_t0 = time()
        @testset "$(basename(test_file))" begin
            include(test_file)
        end
        # A file that changes a package-wide default must put it back: what it
        # leaves would change every later file of this run.
        leaked = _global_defaults_diff(defaults_before, _global_defaults_snapshot())
        @testset "$(basename(test_file)) leaves the package defaults as it found them" begin
            @test leaked == Symbol[]
        end
        isempty(leaked) || _global_defaults_restore!(defaults_before)
        # What a file added to the registries does not reach the next file.
        isempty(_global_registries_diff(registries_before, _global_registries_snapshot())) ||
            _global_registries_restore!(registries_before)
        println("runtests: ", basename(test_file), " done in ", round(time() - file_t0; digits = 1),
            " s (", round(time() - _runtests_t0; digits = 1), " s total)")
        flush(stdout)
    end
end
