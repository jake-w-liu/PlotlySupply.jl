# PlotlySupply benchmarks

Load time, time to first figure (TTFX), the cost of the precompile workload,
scaling of the hot paths with the problem size, and what a figure keeps of the
caller's data (decision D14). The full output of the last recorded run is in
[RESULTS.md](RESULTS.md); this page summarizes it and records the decisions
taken from it.

## Running

```sh
julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'
julia --project=benchmark benchmark/benchmarks.jl            # tens of minutes
julia --project=benchmark benchmark/benchmarks.jl --quick    # a few minutes
```

`benchmarks.jl` prints every table and writes them to `benchmark/RESULTS.md`
with the date, commit, machine, Julia version and load average. Options:

| option | effect |
|---|---|
| `--quick` | smaller sizes and fewer calls |
| `--repeats N` | fresh processes per TTFX scenario (default 3) |
| `--no-electron` | skip the png/pdf scenarios (they start Electron) |
| `--no-ttfx`, `--no-scaling` | skip a part |
| `--precompile-cost` | also time a rebuild of the package image (minutes) |
| `--baseline DIR` | also measure the environment in `DIR` (for example a checkout of an older commit), interleaved run by run with this one |
| `--baseline-note TEXT` | what the baseline is, for the report |
| `--output FILE` | write the report elsewhere |

The parts also run alone: `benchmark/ttfx.jl`, `benchmark/scaling.jl`
(`--quick`, `--only constructors|repeated|figure|memory`) and
`benchmark/precompile_cost.jl` (`--repeats N`).

The benchmark environment resolves its own dependency versions. For a
before/after comparison both sides must load the same versions: the recorded
run used the repository environment (`julia --project=. benchmark/benchmarks.jl`)
for this tree and a copy of the starting commit with the same `Manifest.toml`
as the baseline.

Timings are minima over fresh processes (TTFX) or repeated calls (scaling),
reported with the median/maximum so the noise is visible. Allocated bytes are
deterministic and are what `test/regression_perf.jl` pins: wall-clock bounds
would fail on a busy machine.

## Recorded results (wave 6, 2026-11-19)

Apple M5 (10 cores, 32 GB), macOS, Julia 1.13.1, 1 thread, the 2.0 tree of
this repository against release 1.9.4 (an export of its tag, same
`Manifest.toml`); `benchmark/RESULTS.md` holds the complete output. Two runs,
because the machine was shared:

- the full run (everything, with Electron; commit `26c6473`) started at load
  average 126 / 111 / 89 and stayed near 100 (three full test suites ran next
  to it), so its absolute times are inflated 2-4x; the PNG/PDF rows below come
  from it. Baseline and current were interleaved run by run, so read the ratios;
- a repeat of the load and time-to-first-figure part (`--no-scaling
  --no-electron --repeats 4`) at load 9, which is the record to compare with
  earlier ones.

### Time to first figure: the precompile workload

`src/precompile.jl` runs a PrecompileTools workload while the package image is
built: the 1-D families with their mutators and figure options, fields,
meshes, vector fields, 3-D, a `SubplotFigure` with cell mutators, the
publication style, and the in-process side of every export (no Electron, no
network, no files). Baseline: release 1.9.4, which has no workload. Minimum of
4 fresh processes at load 9 (median in brackets); wave-4 record in the last
column (load 26-49, baseline there: this tree without the workload):

| measurement | 1.9.4 (s) | 2.0 (s) | speed-up | wave-4 2.0 (s) |
|---|---:|---:|---:|---:|
| `using PlotlySupply` | 0.89 (0.94) | 1.49 (1.52) | 0.6x (+0.6 s) | 1.84 |
| first `plot_scatter` | 14.4 (16.0) | 0.30 (0.31) | 47x | 0.55 |
| first `plot_heatmap` | 14.7 (14.8) | 0.34 (0.36) | 43x | 0.46 |
| first `subplots` + `plot_scatter!` + `plot_heatmap!` | 19.6 (19.9) | 0.66 (0.67) | 30x | 1.03 |
| first `savefig` html | 2.51 (2.55) | 0.146 (0.153) | 17x | 0.005 |
| whole process: start, load, first scatter | 15.4 (17.2) | 1.67 (1.80) | 9.2x | 2.90 |
| first `savefig` png (load 100) | 19.9 (21.3) | 11.7 (12.9) | 1.7x | 7.09 |
| first `savefig` pdf, fresh process (load 100) | 29.8 (29.9) | 14.5 (17.8) | 2.1x | 7.05 |

The first figure of every family is faster than in the wave-4 record (the
machine is also quieter), `using` 0.6 s longer than 1.9.4 for the larger
image. Not better: the first html export takes 0.15 s and every html export
about 45 ms (wave 4: 5 ms and 2 ms), probably because html files now embed the
compatibility-patched plotly.js of release 1.9.4 (a few MB written per file;
not profiled; 1.9.4 itself takes 49 ms per call).

Second calls in the same process (load 9): scatter 0.017 s (1.9.4: 0.035 s),
heatmap 0.058 s (0.058 s), subplots 0.108 s (0.107 s); at load 100 png
0.063 s (0.078 s) and pdf 0.201 s (0.174 s). The model side of a png/pdf
export, which 1.9.4 has no entry point for, takes 0.04 s the first time.

The first PNG, split into stages (load 100): model side 0.34 s, loading ElectronCall
0.05 s, first export window 12.3 s (5.3 s of Electron application start-up
and page load, 7.0 s of Julia compilation of ElectronCall's window code at this
load), render 0.9 s. A second export window on the running application takes
0.47 s.

The second export of a session used to cost 0.7-1.0 s more than it should
(measured as `second_savefig_png` 0.84 s instead of 0.06 s): the first export
loads ElectronCall, whose dependency URIs defines `isvalid(::URI)`, and an
untyped closure in `src/sci/scene3d.jl` had compiled `isvalid(::Any)`, so that
loading invalidated about 3000 compiled methods (`savefig` among them) and
the second export recompiled them. The closure is typed now (`c::Char`) and
`test/regression_perf.jl` counts the PlotlySupply methods that loading the
export backend invalidates (0 now, 3021 before).

Cost of the workload: building the package image takes 483 s at this load
(158 s at load 23-27 in an interrupted earlier run of the same tree) instead of
19 s for 1.9.4, once per install or dependency update; the image is 87.6 MB
instead of 5.9 MB; `using PlotlySupply` takes 0.6x the 1.9.4 speed.

Export of a large field: a 2000 x 2000 heatmap used to be sent to the export
window as 76 MiB of JSON text. Dense numeric arrays of 50 000 elements or more
(`x`, `y`, `z`, `r`, `theta`, `lat`, `lon`) are now sent as plotly.js typed
arrays (base64 of the raw bytes): 40.7 MiB, 589 -> 332 MiB allocated, and the
whole `savefig` png took 3.4-4.4 s before and 2.0-2.4 s after (load 14-23; the
JSON text took 0.8-1.5 s to build and 1.3-2.2 s to send and parse, the bytes
0.26-0.67 s and 0.6-1.2 s). The picture is byte-identical (`test/regression_export.jl`).

What was kept, and why (each measured with a variant of `src/precompile.jl`
built in a scratch copy, minimum of 2 fresh processes):

- Everything in the workload pays. The families a plain script reaches less
  often (quiver, streamlines, curvilinear pcolormesh, tripcolor, surface,
  scatter3d) add about 4.6 MB to the image (64.8 MB without them) and 0.09 s
  of `using` time (1.51 s vs 1.60 s); without them their first call takes
  1.4-2.9 s, with them 0.39-0.81 s (23-46 s with no workload at all), so one
  first call of any of them repays the load time.
- Two `precompile` directives compile `savefig(fig, path)` and
  `savefig(fig, path; width, height)` without running them (running a file
  export would start Electron): the first PNG render drops from 0.62-0.67 s to
  0.37-0.40 s (compilation inside it 0.49-0.54 s -> 0.25-0.27 s), image +0.1 MB.
  A directive for `_ensure_export_window` did not change the first window and
  was left out.
- Not adopted: loading ElectronCall during precompilation and adding
  directives for its window code cuts the first export window from 6.6-6.8 s
  to 5.2 s (compilation 2.2-2.3 s -> 0.68 s), but makes `using PlotlySupply`
  load ElectronCall, against the documented lazy loading in
  `src/electron_backend.jl`. That trade-off belongs to the Electron backend.

The only package state the workload leaves in the image is the cache of
Plotly's marker symbol names (`_CMN_MARKER_SYMBOLS`, read from PlotlyBase's
bundled schema, so it is rebuilt whenever PlotlyBase changes). With and
without the workload, every other module-level container has the same length
and every other `Ref` and atomic counter the same value after `using`.

To build the image without the workload (faster precompilation, slower first
figure), set the PrecompileTools preference in the active environment:

```julia
using Preferences, PlotlySupply
set_preferences!(PlotlySupply, "precompile_workload" => false; force = true)
```

### Scaling and memory

Good (pinned by `test/regression_perf.jl`):

- Constructors reference the caller's arrays (`===`; a heatmap's `z` is a lazy
  transpose of the caller's matrix), so `plot_scatter`, `plot_bar` and
  `plot_histogram` allocate 1.76 MB whether they get 1e3 or 1e6 values, and
  `plot_heatmap`/`plot_contour` 2.1-2.3 MB from 250x250 to 2000x2000.
- Mutating a figure does not copy its data: `plot_scatter!` with 10 points on a
  figure holding 1e6 points allocates 0.052 MB (0.053 MB on a 10-point figure),
  `relayout!` 0.275 MB, `xlabel!` 0.109 MB; on a `SubplotFigure` whose other
  cell holds 1e6 points, 0.486 MB. A `plot_scatter` or `plot_heatmap` figure
  keeps at most 0.08 MB beyond the caller's data.
- `_finalize_figure!`, `set_legend!`, `tight_layout!` (1-500 traces) and the
  JSON, html and export model side (1e4-1e6 points) are linear in the size
  (byte exponents 0.90-0.98).

Findings (sent to the owners of the code, with the measured causes):

| finding | measured |
|---|---|
| legend best-position search (`plot_scatter` family with a legend) allocates about 8.6 KB per data point (up to 1e5 scored points per trace) in a type-unstable loop, and runs twice per append | `plot_scatter(1e5 points; legend)` 640 ms, 865 MB; a named `plot_scatter!` on a figure with a named 1e6-point trace 1.81 GB per call; 200 named appends: 7.8 ms -> 276 ms and 10.7 MB -> 348 MB per call (27 s in all) |
| `plot_heatmap(field)`/`plot_contour(field)` with a 1e6-long coordinate | 59 MB per call (test/lazy_payloads.jl:770 allows 2 MB): the finalizer materializes the coordinates |
| every constructor's fixed cost | 1.76-2.2 MB, most of it from transactional `relayout!`/`update_*axes!` on the figure under construction |
| `SubplotFigure` mutators stage every trace by default (`per_subplot_legends = true`) | 200 `plot_scatter!` into one cell: 1.33 ms -> 10.2 ms per call (0.23 -> 3.3 ms with `per_subplot_legends = false`) |
| every mutation scans the extent of every trace's data, twice | 200 unnamed `plot_scatter!`: 0.17 ms -> 2.8 ms per call; `xlabel!` on a 1e6-point figure about 8-11 ms |
| every mutation of a figure with a heatmap scans all `z` values for the colour range (`colorbar!` twice) | `xlabel!` on a 2000x2000 heatmap 11 ms (0.4 ms at 250x250); `colorbar!` 28 ms |
| rectilinear `plot_pcolormesh` (drawn as one heatmap) | 1000x1000 cells: 224 ms and 168.5 MB for 7.6 MB of data (one 8.7 MB copy is kept, as it must be: the heatmap stores nullable values) |
| 6x6 grid filled with `plot_heatmap!` | 15 ms -> 32 ms and 3.2 MB -> 9.0 MB per call from the first to the last cells |
