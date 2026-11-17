# Export

[`savefig`](@ref) writes a `Plot`, `SyncPlot` or `SubplotFigure` to a file,
several files, a stream or a byte vector. The figure itself is not changed.

## Formats

The format comes from the file extension (`format` overrides it):

| Format | Written by | Notes |
|---|---|---|
| `png`, `jpeg` (`.jpg`) | plotly.js in a hidden Electron window | raster; `dpi` is stored in the file |
| `svg`, `pdf` | plotly.js in a hidden Electron window | vector, text as text |
| `eps` | Ghostscript from the PDF | `gs` must be on `PATH`; translucent fills become opaque |
| `html` | Julia | interactive page; plotly.js and MathJax come from CDNs |
| `json` | Julia | the plotly figure JSON |

No Kaleido or Python is needed. `NaN` and `Inf` are written as `null` in
JSON and HTML, which plotly.js draws as gaps.

```julia
using PlotlySupply

fig = plot_scatter(1:10, rand(10); xlabel = "x", ylabel = "y")
savefig(fig, "figure.pdf")
savefig(fig, "figure.svg"; background = :transparent)
savefig(fig, "figure.html")
bytes = savefig(fig; format = "png")      # Vector{UInt8}
```

```julia
# fragment: needs Ghostscript (gs) on PATH
savefig(fig, "figure.eps")
```

## Size and resolution

`width` and `height` are in `units`: `:px` (default, 1/96 in), `:in`, `:cm`,
`:mm` or `:pt` (1/72 in). Without them the figure's `layout.width`/`height`
is used, else 700 x 500 px. Vector formats get exactly that page size. For PNG
and JPEG, `dpi` sets the resolution (it is an alternative to `scale`):
`width = 3.5, units = :in, dpi = 300` gives a 1050 px wide image that prints
3.5 in wide.

```julia
savefig(fig, "column.pdf"; width = 3.5, height = 2.5, units = :in)
savefig(fig, "column.png"; width = 3.5, height = 2.5, units = :in, dpi = 600)
savefig(fig, "wide.png"; width = 90, height = 60, units = :mm, dpi = 300)
```

`scale = 2` doubles the pixels of a raster, or the page of a vector file with
the same layout.

## Other options

- `background`: `nothing` keeps the figure's colours; a colour sets the paper
  background; `:transparent` clears the paper and plot backgrounds.
- `tight = true` applies [`tight_layout!`](@ref) to the exported copy.
- `deterministic = true` (default): repeated exports of the same figure are
  byte-identical (no creation dates, fixed element ids).
- `timeout = 300`: seconds allowed for each renderer step.

Several files from one render, and export to a stream:

```julia
savefig(fig, ["figure_a.pdf", "figure_a.png"]; width = 3.5, height = 2.5, units = :in)
open("figure_b.svg", "w") do io
    savefig(io, fig; format = "svg")
end
```

A file is written to a temporary file in the same directory and then renamed
over the destination, so an interrupted export never leaves a half-written
file.

## Fields at their final size

Equal-aspect fields and the other layout fits are recomputed for the export
size, so a figure exported at 3.5 x 2.5 in has its field and colorbar fitted
to that size, not to the size it had on screen.

## Math in exported files

LaTeX labels are typeset by MathJax with the `Latin-Modern` font unless
[`set_default_mathtext!`](@ref) or the environment variable
`PLOTLYSUPPLY_MATHJAX_SVG_FONT` chooses another. MathJax is loaded from a
CDN, so exporting a figure with math needs network access.
