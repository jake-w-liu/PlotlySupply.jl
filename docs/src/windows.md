# Live windows

Figures are shown in desktop windows through Electron (ElectronCall.jl), with
no browser, PlotlyJS.jl or WebIO.jl involved. A shown figure is a
[`SyncPlot`](@ref): it wraps the `Plot` (`sp.plot`) and forwards property
access to it (`sp.data`, `sp.layout`).

## Opening a window

A constructor returns a plain `Plot`. Pass `show = true` to get a window, or
display the plot:

```julia
# fragment: opens a window
fig = plot_scatter(1:10, rand(10))          # a Plot, no window
display(fig)                                 # opens a window
sp = plot_scatter(1:10, rand(10); show = true)   # a SyncPlot
sp2 = to_syncplot(fig; title = "Run 3", width = 800, height = 600)
sf = subplots(1, 2)                          # sync = true: a live subplot window
```

In the REPL a `Plot` returned by an expression without a semicolon is shown
in a window by Julia's display system.

## Updating a window

Every mutator, `relayout!`, `restyle!`, `add_trace!` and the other PlotlyBase
update functions applied to a `SyncPlot` (or to a `SubplotFigure` created with
`sync = true`) update the window in one transaction; if the renderer fails,
the Julia figure is left unchanged.

```julia
# fragment: needs an open window
plot_scatter!(sp, 1:10, rand(10); legend = "second run")
relayout!(sp; title = "updated")
redraw!(sp)               # rebuild the page from the Julia figure
```

## Lifetime

`close(sp)` closes the window and deletes its temporary files; `isopen(sp)`
tells whether it is still open. A visible window stays open until it is
closed, even when no variable refers to it any more. A hidden window
(`to_syncplot(fig; show = false)`) is closed when its `SyncPlot` is garbage
collected. At Julia exit the Electron processes PlotlySupply started are
closed.

A closed window ends editing of its figure: every mutator on the `SyncPlot`
(`xlabel!`, `plot_scatter!`, `relayout!`, ...), and on a `subplots(...)` grid
made with the default `sync = true`, throws `InvalidStateException("SyncPlot
window is not open")`, and the figure stays as it was. [`savefig`](@ref) still
works. To keep building a figure after its window may be gone, build it
without a window (`subplots(...; sync = false)`, or a `Plot` from the
constructors; `sp.plot` is the plain `Plot` of a `SyncPlot`, `sf.fig` that of
a grid) and open it with [`to_syncplot`](@ref) when you want to look at it.

```julia
# fragment: opens a hidden window
sp = to_syncplot(plot_scatter(1:3, [1, 4, 9]); show = false)
png = to_image(sp; format = "png")
close(sp)
```

[`msgchannel`](@ref) returns the ElectronCall message channel of the window (for custom messages between Julia and the page), and
[`toggle_devtools`](@ref) opens the Chromium developer tools.

## Animations

`plot(traces, layout, frames)` and `plot(...; frames = ...)` keep plotly
animation frames; a window plays them when it opens unless `autoplay =
false` is passed to `to_syncplot` or `plot(...; sync = true)`.

## Without a display

Building and exporting figures needs no window: `subplots(...; sync = false)`
builds a grid without one, and [`savefig`](@ref) renders in a hidden window
of its own. Math in windows and exports is typeset by MathJax from a CDN, and
geo maps load their topology from `cdn.plot.ly`.

The hidden window is still an Electron process. On macOS and Windows that
needs nothing extra; on Linux without a display server run Julia inside a
virtual X server, for example
`xvfb-run -a -s "-screen 0 1920x1080x24" julia script.jl`. `using PlotlySupply`
alone starts no Electron process and loads no export code.

## Downloads and working offline

The Electron binary is installed with the package (Electron\_jll). The
plotly.js bundle (plotly.js-dist-min 2.35.2, from the npm registry, checked
against its SHA-256) is a lazy artifact: it is downloaded the first time a
window is opened or a figure is exported, not at install. To prepare a machine
that will work offline, fetch it once while online:

```julia
# fragment: downloads the plotly.js artifact
using Pkg, PlotlySupply
Pkg.Artifacts.ensure_artifact_installed("plotlyjs",
    joinpath(pkgdir(PlotlySupply), "Artifacts.toml"))
```

Offline, windows and PDF, SVG, PNG, JPEG, TIFF and EPS exports work once the
artifact is present; math labels and geo maps still need their CDNs (MathJax,
`cdn.plot.ly`).

## The Electron sandbox

Electron windows normally run with Chromium's sandbox. Some CI runners and
containers cannot start a sandboxed renderer, so PlotlySupply starts its
Electron application without the sandbox (ElectronCall's
`development_config()`: context isolation on, Node integration off, web
security on, sandbox off) when one of these environment variables is `1`,
`true`, `yes` or `on` (any case) at the time the first window or export
starts the application:

`GITHUB_ACTIONS`, `CI`, `CODEX_SANDBOX`, `CODEX_AUTOMATION`,
`CLAUDE_CODE_SANDBOX`, `AGENT_SANDBOX`, `SANDBOX` and
`PLOTLYSUPPLY_DISABLE_ELECTRON_SANDBOX`.

The pages PlotlySupply renders are its own (the figure's JSON and the bundled
plotly.js; MathJax and map topology from their CDNs), so the risk is small,
but the renderer then has the rights of the Julia process. Do not set these
variables to show figures built from untrusted input (for example a figure
JSON or HTML labels from a web form) on a machine you care about. An
application you pass yourself (`app = ...` to `to_syncplot` or `subplots`)
is used with the settings you gave it.
