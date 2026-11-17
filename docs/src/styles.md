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
- `:publication` uses black STIX/Times text (14 px labels, 12 px ticks and
  legend, 16 px title), the Okabe–Ito colour-blind-safe palette, a closed
  frame, a frameless legend, `\large` math and a 10 px margin that grows to
  fit labels and title.

```julia
using PlotlySupply

set_default_style!(:publication)
fig = plot_scatter(1:10, (1:10) .^ 2; xlabel = "\$n\$", ylabel = "\$n^2\$")
set_default_style!(; tick_fontsize = 11)    # change one field of the active style
set_default_style!(:default)                # back to the 1.x look
```

[`with_style`](@ref) applies a style for one block and restores the previous
one afterwards, also on error. The active style is global, not per task.

```julia
fig = with_style(:publication; fontsize = 12) do
    plot_scatter(1:10, sin.(1:10); xlabel = "t", ylabel = "sin t")
end
```

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

`cycle = :dash`, `:marker`, `:dash_marker` or `:bw` give successive line
traces different dash patterns or markers (`:bw` also draws them all in one
ink colour), so figures stay readable in greyscale.

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

[`figsize!`](@ref) sets the figure size in pixels or physical units (96 px per
inch); [`tight_layout!`](@ref) shrinks the margins to a small pad while
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
