# Performance

Load time and time to the first figure are part of the package. The numbers
below are the record of `benchmark/README.md` and `benchmark/RESULTS.md`
(wave 6 of the 2.0 development, commit `26c6473`, 2026-11-18/19): Apple M5
(10 cores, 32 GB), macOS, Julia 1.13.1, one thread, the 2.0 tree against
release 1.9.4 (an export of its tag with the same `Manifest.toml`, run
interleaved, minimum of fresh processes). They were not re-measured for this
page, and the machine was shared, so every row names the load it was taken at:

- the full run (Electron rows, scaling) started at a load average of 126 / 111 /
  89 and stayed near 100, which inflates absolute times 2 to 4 times; read the
  ratios there;
- the repeat of the load and time-to-first-figure rows (no Electron, minimum of
  4 processes) was taken at a load average of 9.

## The precompile workload

While the package image is built, `src/precompile.jl` runs a
[PrecompileTools](https://github.com/JuliaLang/PrecompileTools.jl) workload:
the 1-D families with their mutators and figure options, fields, meshes, vector
fields, 3-D, a `SubplotFigure` with cell mutators, the publication style, and the in-process
side of every export. It starts no window, touches no network and no file, and
changes no package setting. `ElectronCall` stays lazily loaded: `using
PlotlySupply` does not start or load the export backend.

Time to first figure in a fresh process (load average 9; 1.9.4 has no workload):

| Measurement | 1.9.4 | 2.0 |
|---|---:|---:|
| `using PlotlySupply` | 0.89 s | 1.49 s |
| first `plot_scatter` | 14.4 s | 0.30 s |
| first `plot_heatmap` | 14.7 s | 0.34 s |
| first `subplots` + `plot_scatter!` + `plot_heatmap!` | 19.6 s | 0.66 s |
| first `savefig` to HTML | 2.5 s | 0.15 s |
| start, load and first scatter in one process | 15.4 s | 1.67 s |

First export through the Electron backend (load average about 100, so
inflated): the first PNG takes 11.7 s (1.9.4: 19.9 s) and the first PDF in a
fresh process 14.5 s (29.8 s). Of the first PNG, 12.3 s are the first export
window: 5.3 s are the start of the Electron application and the page load and
7.0 s the compilation of ElectronCall's window code, which is loaded on first
use. The model side takes 0.34 s and the render 0.9 s. Later exports in the
same session are fast (load 100): PNG 0.06 s, PDF 0.2 s, a second export
window 0.47 s; HTML 0.045 s (load 9). HTML files now embed the
compatibility-patched plotly.js, so each export writes a few MB: the first
HTML export takes 0.15 s and every one about 45 ms (a record of an earlier
wave, 5 ms and 2 ms, was taken before that patch; 1.9.4 takes 49 ms).

The price of the workload:

- building the package image takes minutes instead of seconds (483 s at the
  load of the full run, 158 s at a load of 23 to 27, against 19 s for 1.9.4),
  once per install or dependency update;
- the package image grows from about 5 MB to about 110 MB (107 to 112 MB on
  Julia 1.12 and 1.13);
- `using PlotlySupply` takes 0.6 s longer (1.49 s against 0.89 s).

Loading the export backend no longer invalidates compiled PlotlySupply methods
(0 now, 3021 before; counted by `test/regression_perf.jl`), so the second export
of a session is as fast as the third.

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
  `plot_bar` and `plot_histogram` allocate the same 0.2 to 1.8 MB (depending on
  the measurement run) for 1e3 or 1e6 values, and `plot_heatmap` and
  `plot_contour` about 0.4 to 2 MB from 250 x 250 to 2000 x 2000; the figure
  keeps at most 0.08 MB beyond your data.
- Mutating a figure does not copy its data: `plot_scatter!` with ten points on
  a figure holding 1e6 points allocates about 0.07 MB, `relayout!` 0.06 MB and
  `xlabel!` 0.13 MB.
- The finalizer, `set_legend!`, `tight_layout!` (1 to 500 traces), JSON, HTML
  and the model side of an export (1e4 to 1e6 points) are linear in the data
  size (byte exponents 0.6 to 1.0).
- Large dense numeric arrays (at least 50 000 elements under `x`, `y`, `z`,
  `r`, `theta`, `lat`, `lon`; Int8 to Int32, UInt8 to UInt32, Float32/64) go to
  the export window as typed arrays instead of JSON text: a 2000 x 2000
  heatmap went from 76 MiB of JSON to 40.7 MiB, and the PNG export from 3.4 -
  4.4 s to 2.0 - 2.4 s (load 14 to 23). The picture is byte-identical.

Costs found by the benchmarks (the numbers are those of the recorded run; see
`benchmark/RESULTS.md` for the current state):

- every mutation of a figure scans the extent of every trace's data: 200
  unnamed `plot_scatter!` calls go from 0.3 ms to 2.4 ms per call, and `xlabel!`
  on a figure of 1e6 points takes 8 to 11 ms;
- a named `plot_scatter!` on a figure that already holds named traces grows
  with their number (200 calls: 0.9 ms to 39 ms), because the legend position
  is searched again;
- on a grid of 6 x 6 cells a mutation costs 40 to 115 ms and 3.6 to 11.6 MB
  per call from the first to the last cell;
- an SVG export of a figure with 1e6 markers is slow, because plotly.js draws
  every marker as a DOM node.

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
