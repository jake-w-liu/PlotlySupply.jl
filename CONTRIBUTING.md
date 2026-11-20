# Contributing to PlotlySupply.jl

First off, thank you for considering contributing to PlotlySupply.jl. It's people like you that make open source such a great community.

## Where do I go from here?

If you've noticed a bug or have a feature request, [make one](https://github.com/jake-w-liu/PlotlySupply.jl/issues/new)! It's generally best if you get confirmation of your bug or approval for your feature request this way before starting to code.

### Reporting Bugs

When reporting a bug, please include as much detail as possible. This might include:

- A description of the bug and the behavior you expected.
- A minimal, reproducible example.
- The version of PlotlySupply.jl you are using.
- Your Julia version.

### Suggesting Enhancements

If you have an idea for a new feature, please provide a clear and detailed explanation of the proposed enhancement. Include why you think it would be a valuable addition to the project and, if possible, provide a code snippet or pseudo-code demonstrating its usage.

## Project Scope

PlotlySupply.jl is a high-level plotting layer on top of [PlotlyBase.jl](https://github.com/sglyon/PlotlyBase.jl). It provides scientific 2D and 3D plot functions with a consistent API, renders and exports figures through its own [ElectronCall.jl](https://github.com/IanButterworth/ElectronCall.jl) desktop backend, and ships plotly.js 2.35.2 as a lazy artifact. It does not require PlotlyJS.jl or WebIO.jl.

Contributions should align with this scope. We are particularly interested in:

- Improving existing plotting functions.
- Adding new high-level plotting functions that are commonly used.
- Enhancing documentation and examples.
- Fixing bugs and improving performance.

We are generally not looking to:

- Add highly specialized or niche plot types.
- Replicate the full functionality of PlotlyBase.jl/plotly.js (the raw trace and layout API stays available through the re-exported PlotlyBase names).
- Introduce significant new dependencies.

## Development

1.  Fork the repository and create a new branch from `main`.
2.  Make your changes.
3.  Add tests for your changes (see below).
4.  Ensure your code is well-documented: every exported function needs a complete docstring, because the documentation build (`docs/make.jl`) fails on missing docstrings and on any other Documenter warning. A new page under `docs/src` must be listed in `PAGES` in `docs/make.jl` to appear in the navigation.
5.  Open a pull request.

### Running the tests

The test suite opens real (hidden) Electron windows and exports images, so it needs a display:

- macOS and Windows: run it from a normal desktop session.
- Headless Linux: run it inside a virtual X server, as CI does, e.g.
  `xvfb-run -a -s "-screen 0 1920x1080x24" julia --project -e 'using Pkg; Pkg.test()'`.

Run the whole suite with `julia --project -e 'using Pkg; Pkg.test()'` (or `julia --project=. test/runtests.jl`).
Every file in `test/` also runs on its own, e.g. `julia --project=. test/regression_scatter.jl`: it starts with `using Test` and `using PlotlySupply`, and a file that uses the shared fixtures in `test/testutils.jl` loads them with `isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")`.
`test/runtests.jl` runs every `test/*.jl` file, so a new test file needs no registration: the files listed in `_TEST_FILES_RUN_FIRST` (`test/testutils.jl`) run first, then all others in name order. Packages a test file loads with `using` must be listed in `Project.toml` (`[deps]`, or `[extras]` plus `[targets]`), because `Pkg.test()` cannot load anything else. Assert the exception type a call throws (`@test_throws ArgumentError ...`), not `Exception`. `test/hygiene.jl` checks these rules.

### Package defaults are guarded per test file

The package has global defaults: the active style (`set_default_style!`), the default template, the default legend position and the mathtext settings (`set_default_mathtext!`). A test file that changes one of them and does not put it back changes what every later file of the full run measures, so the suite guards them: `test/runtests.jl` snapshots the four defaults (`_global_defaults_snapshot()` in `test/testutils.jl`) around every file and fails the file that leaves one changed, and a file run on its own is checked when its process ends (`julia --project=. test/<file>.jl` exits with status 1 and prints which defaults leaked). Change a default only inside `with_style(...) do ... end`, or restore it in a `try ... finally`:

```julia
old = get_default_legend_position()
try
    set_default_legend_position!(:bottom)
    # ... assertions ...
finally
    set_default_legend_position!(old)
end
```

A style you register by name with `register_style!` is not a default and need not be removed. `test/hygiene.jl` tests the guard itself.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
