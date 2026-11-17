# Figures for papers

This page goes from data to a camera-ready file: choose a style, fix the
physical size first, set fonts in points, make the figure readable without
colour, place legends and panel labels, and export in the format the journal
asks for.

## 1. Choose a style

The `:publication` style sets serif (STIX/Times) text in black, the
Okabe–Ito colour-blind-safe palette, a closed frame with outside ticks, a
frameless legend, larger math (`\large`, so math matches the text height) and
small margins that grow to fit the labels. Use it for one figure with
[`with_style`](@ref), or for a whole session with
[`set_default_style!`](@ref).

```julia
using PlotlySupply

t = range(0, 10; length = 400)
fig = with_style(:publication) do
    plot_scatter(t, [exp.(-t ./ 4) .* cos.(2t), exp.(-t ./ 4)];
        legend = ["response", "envelope"], dash = ["solid", "dash"],
        xlabel = "time \$t\$ (s)", ylabel = "displacement \$x\$ (mm)")
end
```

A journal's own sizes go into a [`PlotStyle`](@ref) that you register once
(sizes are in px; 1 pt = 96/72 px, so 8 pt is about 10.7 px):

```julia
pt = 96 / 72
register_style!(:mypaper, PlotStyle(; template = :plotly_white,
    font_family = "Times New Roman, serif", font_color = "#000000",
    fontsize = 9pt, label_fontsize = 9pt, tick_fontsize = 8pt, legend_fontsize = 8pt,
    title_fontsize = 9pt, linewidth = 1.5, marker_size = 5, colorway = :okabe_ito,
    legend_frame = false, margin = 4, mathsize = "\\large", cycle = :dash))
```

## 2. Fix the size first

Decide the printed size from the journal's column width and set it on the
figure before adjusting anything else: layout decisions (equal-aspect fields,
colorbar lengths, legend placement, margins) depend on the size. PlotlySupply
uses 96 px per inch, so a font of 12 px prints at 9 pt when the figure is
exported at its own size.

```julia
figsize!(fig, 3.5, 2.4; units = :in)       # single column, 336 x 230 px
```

Export at the same size (or pass the size to [`savefig`](@ref) directly).
Exporting at a different size rescales nothing: text keeps its size in points
and the plot area changes instead.

## 3. Fonts and math

- Set sizes in points with `set_fonts!(fig; label = 9, tick = 8, legend = 8,
  units = :pt)`.
- Text and math in one label: `"time \$t\$ (s)"`. The math is typeset by
  MathJax; `set_default_mathtext!(; font = "TeX")` (or `"STIX-Web"`) picks the
  math font, and `inherit_text_font = true` draws the text parts in the
  figure's font.
- 3-D axis titles cannot typeset TeX; their `$...$` is converted to Unicode.

```julia
set_fonts!(fig; label = 9, tick = 8, legend = 8, units = :pt)
```

## 4. Colour, greyscale and line styles

- The Okabe–Ito palette of `:publication` stays distinguishable for the
  common forms of colour blindness.
- For figures that may be printed in greyscale, give the lines different dash
  patterns or markers: `dash`/`marker_symbol` per series, or a style with
  `cycle = :dash`, `:marker`, `:dash_marker` or `:bw` (all black, dash cycle).
- Colour maps: use a perceptually uniform map (`viridis`, `cividis`,
  `magma`) for sequential data and a diverging map with `cmid` for signed
  data (`colorscale = "RdBu_r", cmid = 0`). Avoid `jet` and `rainbow`.

## 5. Legends, labels and panels

```julia
sf = with_style(:publication) do
    s = subplots(1, 2; sync = false, width = 672, height = 260)
    x = range(0, 1; length = 50)
    for (c, k) in enumerate((1, 2))
        plot_scatter!(s, x, [sin.(k * π .* x), cos.(k * π .* x)]; row = 1, col = c,
            legend = ["\$\\sin\$", "\$\\cos\$"], dash = ["solid", "dash"], color = ["#0072B2", "#D55E00"])
        xlabel!(s, "\$x\$"; row = 1, col = c)
    end
    ylabel!(s, "amplitude"; row = 1, col = 1)
    s
end
set_legend!(sf; position = :outside_bottom, ncols = 2, frame = false)
panel_labels!(sf; labels = :abc, format = "({})")
tight_layout!(sf)
```

Panel labels outside the axes are annotations, which do not enlarge the
margins by themselves; under the small margins of `:publication` call
[`tight_layout!`](@ref) after adding them (or export with `tight = true`), or
put them inside the axes with `outside = false`.

- Outside legends merge the entries of all panels into one legend without
  duplicates.
- [`panel_labels!`](@ref) labels the panels in row-major order;
  [`title!`](@ref) with `row`/`col` and `align = :left` gives panel titles.
- Log axes: `xticks = :decades` labels powers of ten only.
- Reference lines, spans and slope markers: see
  [Reference lines and shapes](shapes.md).

## 6. Export

- Line art (plots, schematics): a vector format, PDF or EPS (or SVG). The
  page has the requested physical size and text stays text.
- Images and dense rasters: PNG (lossless) at the resolution the journal asks
  for, with `dpi` stored in the file.
- `deterministic = true` (the default) makes repeated exports byte-identical,
  so figures can live in version control.
- EPS is converted from the PDF by Ghostscript; translucent fills become
  opaque.

```julia
savefig(sf, "figure2.pdf"; width = 7, height = 2.7, units = :in)
savefig(sf, "figure2.png"; width = 7, height = 2.7, units = :in, dpi = 600)
```

## Checklist before submission

| Journals reject | Check |
|---|---|
| Text too small after the figure is scaled to the column | Export at the final width; tick labels at least the journal's minimum (often 6 to 8 pt). |
| Raster line art, or rasters below the required resolution | Vector PDF/EPS for plots; `dpi` for PNG. |
| Information carried by colour alone (red against green) | Okabe–Ito palette, dash or marker cycles, direct labels. |
| Axis labels without quantities and units | `"time \$t\$ (s)"`, `"\$E\$ (V/m)"`. |
| Inconsistent fonts and sizes between panels and figures | One registered style for the whole paper. |
| Transparency in EPS | Translucent fills become opaque in EPS; check the colours, or use PDF. |
| Missing or inconsistent panel labels | `panel_labels!` on every multi-panel figure. |
| Legends or labels covering data | `set_legend!` with an outside position, or a position chosen for the data. |
| Large blank margins | `tight_layout!`, or `savefig(...; tight = true)`. |
| Wrong page size in the PDF | `pdfinfo figure.pdf` shows the page size; `savefig(...; width, height, units = :in)` gives exactly that size (`figsize!` rounds to whole px). |
