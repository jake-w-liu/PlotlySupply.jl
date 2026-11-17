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
of its own. Math in windows and exports is typeset by MathJax from a CDN.
