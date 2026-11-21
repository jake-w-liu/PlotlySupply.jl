# Styles and templates

## PlotStyle

A [`PlotStyle`](@ref) bundles figure defaults (the analogue of matplotlib's
`rcParams`): font family and sizes per role, font colour, colour cycle, line
width, marker size, tick direction, spines, grid, legend frame, margins, the
math size and a line-style cycle. The active style applies to figures created
afterwards; explicit keywords of a call win over it.

Built-in styles:

- `:default` is the PlotlySupply 1.x look: the default template
  (`plotly_white`), black closed spines, outside ticks, plotly's fonts,
  colours and margins.
- `:publication` uses black Times New Roman text (14 px labels, 12 px ticks and
  legend, 16 px title; a TrueType face, so PDF export embeds real fonts), the
  Okabe-Ito colour-blind-safe palette, a closed frame, a frameless legend and a
  10 px margin that grows to fit labels and title. Math is drawn at the size of
  the surrounding text (no style sets a MathJax size switch). It sets no
  figure size.
- `:ieee`, `:aps`, `:nature`, `:elsevier`, `:springer`, `:aip` are the journal
  presets: the journal's font family and size in points, 1 pt data lines,
  0.75 pt axes, ticks, error bars and reference lines, 3.5 pt ticks (inside and
  mirrored on all four sides for `:ieee`, `:aps`, `:aip`; outside otherwise;
  `:nature` draws only the left and bottom axes), Okabe-Ito colours with the
  greyscale-safe `:dash_symbol` cycle, and the single-column width at aspect
  ratio 0.75 as the default figure size. The table with widths, maximum heights
  and sources is in [Figures for papers](papers.md); `journal_width` returns
  any width and `figsize!(fig, :ieee; columns = 2)` sizes a figure.

```julia
using PlotlySupply

set_default_style!(:publication)
fig = plot_scatter(1:10, (1:10) .^ 2; xlabel = "\$n\$", ylabel = "\$n^2\$")
set_default_style!(; tick_fontsize = 11)    # change one field of the active style
set_default_style!(:default)                # back to the 1.x look
```

[`with_style`](@ref) applies a style for one block and restores the previous
one afterwards, also on error. The block's style belongs to the task that runs
it (and to the tasks started inside the block): other tasks keep their own
active style, and overlapping blocks of two tasks do not change each other.
[`set_default_style!`](@ref) is the global setting that every task sees
outside a `with_style` block.

```julia
fig = with_style(:publication; fontsize = 12) do
    plot_scatter(1:10, sin.(1:10); xlabel = "t", ylabel = "sin t")
end
```

A figure carries the style it was built under: a figure made under a style
other than `:default` records the fields in which that style differs from
`PlotStyle()` in `layout.meta.plotlysupply.style` (the template is not part of
it; the record survives `JSON`). Mutators, the layout engine and `savefig` read
that record, not the active style, so `with_style(:aps) do xlabel!(fig, "x")
end` does not restyle a figure that was built under `:ieee`; a figure
without a record (built under `:default`) that a mutator changes inside
`with_style(:x)` adopts `:x` from then on. A figure without a size exports
at the size of its carried style. A public mutator that bypasses the
PlotlySupply wrappers (a direct PlotlyBase verb such as `relayout!` on a
plain `Plot`) runs under the active style and does not adopt.

[`register_style!`](@ref) stores a style under a name, and
[`get_default_style`](@ref) returns a copy of the active one.

```julia
register_style!(:talk, PlotStyle(; fontsize = 18, tick_fontsize = 16, linewidth = 3,
    colorway = :tab10, spines = :open, grid = false))
fig = with_style(:talk) do
    plot_scatter(1:10, (1:10) .^ 2; xlabel = "x", ylabel = "y")
end
get_default_style()
```

`cycle = :dash`, `:marker`, `:dash_marker`, `:dash_symbol` or `:bw` give
successive line traces different dash patterns or markers (`:bw` also draws
them all in one ink colour), so figures stay readable in greyscale.

Fields added in 2.0 to `PlotStyle`: `width` and `aspect` (the default figure
size: a new figure that sets no size of its own gets `width` px and height
`aspect * width`, and `savefig` uses it), `axis_linewidth` (spine, tick and
grid width), `tick_length`, `mirror_ticks` (ticks on the top and right of a
closed frame), `errorbar_width` and `reference_linewidth`. Sizes are CSS px;
1 pt = 4/3 px. `colorway` takes a name from `COLOR_CYCLES` (`:okabe_ito`,
`:tol_bright`, `:tol_vibrant`, `:tol_muted`, `:tol_high_contrast`), a
`PlotlyBase.colors` palette name, or a list of colours; grey levels such as
`"0.35"` are accepted in colours. Under a style that sets `linewidth`,
`errorbar_width`, `axis_linewidth` or `tick_length`, contour line widths,
error-bar thickness and trace colorbar fonts, outline and ticks follow it;
under `:default` nothing new is written. The colorbar defaults write no
colours (a colorbar keeps plotly's grey, so a template switch cannot leave a
stale colour behind). `reference_linewidth` is the default width of `hline!`,
`vline!`, `arrow!`, `arc!`, the schematic shapes and span outlines.

## Templates

Plotly templates set the background, grid and default colours.
[`set_default_template!`](@ref) chooses the template of new figures
(`"plotly_white"` by default); [`set_template!`](@ref) changes an existing
figure. Axis spines, tick marks and the default legend box follow the
template: black on light templates, light on dark ones.

```julia
fig = plot_scatter(1:10, (1:10) .^ 2; legend = "n²")
set_template!(fig, "plotly_dark")
set_template!(fig)                         # back to the default template
set_default_template!(:simple_white)
fig2 = plot_scatter(1:10, rand(10))
set_default_template!()
get_default_template()
```

## Figure size and margins

[`figsize!`](@ref) sets the figure size in pixels, physical units (96 px per
inch) or a journal (`figsize!(fig, :nature; columns = 2, aspect = 0.6)`, or
`height = 6, units = :cm`; a figure taller than the journal's maximum is an
`ArgumentError`); [`tight_layout!`](@ref) shrinks the margins to a small pad while
keeping room for tick labels, axis titles and the title.

```julia
fig = plot_scatter(1:10, rand(10); xlabel = "x", ylabel = "y", title = "Tight")
figsize!(fig, 3.5, 2.5; units = :in)      # 336 x 240 px
tight_layout!(fig)
```

`savefig` also takes the size directly (see [Export](export.md)).

## Default legend position

[`set_default_legend_position!`](@ref) sets where new figures put their
legend (`:topright`, `:bottomleft`, ..., or outside: `:outside_right`,
`:outside_bottom`, ...); [`get_default_legend_position`](@ref) returns it.

```julia
set_default_legend_position!(:outside_bottom)
fig = plot_scatter(1:3, [[1, 2, 3], [3, 2, 1]]; legend = ["a", "b"])
set_default_legend_position!()
```
