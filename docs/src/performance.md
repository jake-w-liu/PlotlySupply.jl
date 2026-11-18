# Performance

Load time and time to the first figure are part of the package. The numbers
below were recorded with the benchmark suite in `benchmark/` (Apple M5,
Julia 1.13.1, one thread, on a busy machine with a load average of 26 to 49, so
absolute times are inflated). They come from `benchmark/README.md` and
`benchmark/RESULTS.md`; they were not re-measured for this page.

## The precompile workload

While the package image is built, `src/precompile.jl` runs a
[PrecompileTools](https://github.com/JuliaLang/PrecompileTools.jl) workload:
the 1-D families with their mutators and figure options, fields, meshes, vector
fields, 3-D, a `SubplotFigure` with cell mutators, the publication style, and the in-process
side of every export. It starts no window, touches no network and no file, and
changes no package setting. `ElectronCall` stays lazily loaded: `using
PlotlySupply` does not start or load the export backend.

Time to first figure in a fresh process (minimum of three runs):

| Measurement | Without the workload | With it |
|---|---:|---:|
| first `plot_scatter` | 36.6 s | 0.55 s |
| first `plot_heatmap` | 40.8 s | 0.46 s |
| first `subplots` + `plot_scatter!` + `plot_heatmap!` | 41.4 s | 1.03 s |
| first `savefig` to HTML | 2.49 s | 0.005 s |
| first `savefig` to PNG or PDF | about 21 s | about 7 s |

The first PNG or PDF still takes about 7 s: 4.4 s to start Electron and load
the page, and 2.5 to 2.9 s to compile the window code of ElectronCall, which
is loaded on first use. Later exports in the same session take 0.05 to 0.13 s.

The price of the workload:

- building the package image takes minutes instead of seconds (161 s instead
  of 28 s in the recorded run), once per install or dependency update;
- the package image grows from 16.8 MB to 69.5 MB;
- `using PlotlySupply` takes 0.4 to 0.6 s longer.

### Turning it off

To build the image without the workload (faster precompilation, slower first
figure), set the PrecompileTools preference in the active environment and
restart Julia:

```julia
# fragment: changes the project's LocalPreferences.toml
using Preferences, PlotlySupply
set_preferences!(PlotlySupply, "precompile_workload" => false; force = true)
```

## Scaling

Pinned by `test/regression_perf.jl` (allocated bytes, not wall-clock time):

- Constructors reference your arrays instead of copying them: `plot_scatter`,
  `plot_bar` and `plot_histogram` allocate the same 1.8 MB for 1e3 or 1e6
  values; `plot_heatmap` and `plot_contour` about 2 MB from 250 x 250 to
  2000 x 2000.
- Mutating a figure does not copy its data: `plot_scatter!` with ten points on
  a figure holding 1e6 points allocates about 0.05 MB.
- JSON and HTML output and the model side of an export are linear in the data
  size.

Costs found by the benchmarks (see `benchmark/RESULTS.md` for the current
state): the data-avoiding legend search of the line family allocated about
8.6 KB per data point of a named series, and every mutation of a figure scans the extent of every trace's data. An SVG
export of a figure with 1e6 markers is slow, because plotly.js draws every
marker as a DOM node.

## Running the benchmarks

```julia
# fragment: shell commands, start a Julia benchmark run
# julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'
# julia --project=benchmark benchmark/benchmarks.jl [--quick] [--baseline DIR] [--precompile-cost]
```

`benchmark/README.md` lists the options and records the summary; the full
tables are in `benchmark/RESULTS.md`. For a before and after comparison, run
both sides with the same `Manifest.toml`: the benchmark environment resolves
its own dependency versions.
