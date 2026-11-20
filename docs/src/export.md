# Export

[`savefig`](@ref) writes a `Plot`, `SyncPlot` or `SubplotFigure` to a file,
several files, a stream or a byte vector. The figure itself is not changed.

## Formats

The format comes from the file extension (`format` overrides it):

| Format | Written by | Notes |
|---|---|---|
| `pdf` | plotly.js in a hidden Electron window | vector; page of exactly the figure's size in points; text as text (see `fonts`) |
| `svg` | plotly.js in a hidden Electron window | vector; with physical units the root `width`/`height` carry the unit (`88mm`) |
| `eps` | Ghostscript from the PDF | `gs` must be on `PATH`; text is outlines; translucent colours are blended over their background |
| `png`, `jpeg` (`.jpg`) | plotly.js in a hidden Electron window | raster, exactly `round(width * scale)` pixels; `dpi` is stored in the file; JPEG is lossy (quality 0.92) |
| `tiff` (`.tif`) | plotly.js in a hidden Electron window | raster, baseline TIFF 6.0, lossless LZW, 8-bit RGB (RGBA when a pixel is translucent), resolution tags set, 300 dpi unless `dpi`/`scale` say otherwise |
| `html` | Julia | interactive page; embeds the patched plotly.js (about 4.5 MB per file), MathJax comes from its CDN when the figure has math |
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
is used, else the size of the style the figure carries (a journal preset sets
one), else, for a figure that carries no style, the active style's default
size, else 700 x 500 px. PDF and EPS pages have exactly that size in points. For
PNG, JPEG and TIFF, `dpi` sets the resolution (it is an alternative to
`scale`; PNG and JPEG with a physical size and no `dpi` record 96 x `scale`
dpi, a pixel-size export records none):
`width = 3.5, units = :in, dpi = 300` gives a 1050 px wide image that prints
3.5 in wide.

```julia
savefig(fig, "column.pdf"; width = 3.5, height = 2.5, units = :in)
savefig(fig, "column.png"; width = 3.5, height = 2.5, units = :in, dpi = 600)
savefig(fig, "wide.png"; width = 90, height = 60, units = :mm, dpi = 300)
savefig(fig, "wide.tif"; width = 90, height = 60, units = :mm, dpi = 600)
```

`scale = 2` doubles the pixels of a raster, or the page of a vector file with
the same layout.

## Fonts in PDF and EPS

`fonts = :auto` (default) keeps PDF text as text in subset-embedded TrueType
(CID) fonts when the figure's fonts are TrueType (Arial, Times New Roman,
Liberation, DejaVu, ...), which is what the journal presets use. Chromium can
embed CFF/OpenType-PS fonts (STIX, Latin Modern) only as Type 3 fonts, which
many journal checks reject. When that happens and Ghostscript is on `PATH`,
`:auto` converts all text of that page to outlines (it prints the same but
cannot be selected or searched); without Ghostscript the Type 3 fonts are kept
and a warning names them. The trigger is any Type 3 font on the page, not only
the figure's own: one label with a glyph that the figure's font lacks (a
dingbat such as ✓ or ✗, some arrows, emoji) falls back to a system font that
Chromium embeds as Type 3, and `:auto` then outlines the whole page without a
warning. Use symbols the figure's font covers (math symbols go through
MathJax) or `fonts = :embed`. `fonts = :embed` keeps Chromium's fonts as they are;
`fonts = :outline` always draws outlines (needs Ghostscript). EPS text is
always outlines unless `fonts = :embed`. Math is drawn as glyph paths in every
format. Check a file with `pdffonts figure.pdf`.

## Other options

- `background`: `nothing` keeps the figure's colours; a colour sets the paper
  background; `:transparent` clears the paper and plot backgrounds.
- `tight = true` applies [`tight_layout!`](@ref) to the exported copy.
- `deterministic = true` (default): repeated exports of the same figure are
  byte-identical (no creation dates, fixed element ids).
- `timeout = 300`: seconds allowed for each renderer step.
- An unwritable destination directory, an unsupported `format` and an invalid
  `PLOTLYSUPPLY_MATHJAX_SVG_FONT` raise an `ArgumentError` before anything is
  drawn.
- Static exports (PDF, SVG, EPS, PNG, JPEG, TIFF) draw every vertex of a line
  (`line.simplify = false`), so the peaks of a dense curve do not show as
  corners at high resolution; windows and HTML files keep plotly.js' line
  simplification. `plot_scatter(...; simplify = true)` (or `false`) sets it
  for a trace explicitly, in every output.

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

## HTML and JSON documents

An HTML or JSON file is a document, not a picture: it keeps the figure's
`div` id, so exporting the same figure twice gives the same bytes. The cameras
of 3-D scenes keep the box centre as their centre: an image export may shift
the camera centre to fit the scene into its frame, but a document is rotated by
hand, and it pivots about the centre.

## Fields at their final size

Equal-aspect fields, 3-D scene framing and the other layout fits are
recomputed for the export size, so a figure exported at 3.5 x 2.5 in has its
field and colorbar fitted to that size, not to the size it had on screen.

## Math in exported files

LaTeX labels are typeset by MathJax with the `Latin-Modern` font unless
[`set_default_mathtext!`](@ref)`(; font = ...)` chooses another (`"TeX"`,
`"STIX-Web"`, `"Asana-Math"`, `"Neo-Euler"`, `"Gyre-Pagella"`,
`"Gyre-Termes"`); the environment variable `PLOTLYSUPPLY_MATHJAX_SVG_FONT`
(same names) is only the fallback. MathJax is loaded from a CDN, so exporting
a figure with math needs network access.

plotly.js is patched when it is loaded (windows, image export and the HTML
file all use the patched copy): math text groups get an explicit font family
and size, so legend entries with math keep their size and SVG output keeps
its quotes. An HTML file embeds that copy, so it needs no network for
plotly.js itself. Maps are the other network use: `plot_scattergeo` and
`plot_choropleth` fetch their topology (topojson) from `cdn.plot.ly`, and the
tile maps (`plot_scattermap`, `plot_choroplethmap`) fetch their tiles, when the
figure is shown or exported; offline, an HTML map draws no coastlines (a
`scattergeo` shows nothing at all). Draw such figures on a machine with
network access.
