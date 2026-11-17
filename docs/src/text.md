# Text and math

## Mathtext labels

Every user-visible label (figure and panel titles, axis titles, legend names,
colorbar titles, tick labels, annotations) goes through [`mathtext`](@ref):
text and `$...$` math may be mixed in one label, and the whole label is
typeset by MathJax.

```julia
using PlotlySupply

fig = plot_scatter(1:10, (1:10) .^ 2; xlabel = "time \$t\$ (s)",
    ylabel = "\$E = mc^2\$", legend = "\$\\alpha = 0.5\$", title = "Energy")
mathtext("Time \$t\$ (s)")          # the string sent to plotly
```

Rules:

- `$` opens and closes math. An odd number of unescaped `$` is an
  `ArgumentError`. Write `\$` (in Julia source `"\\\$"`) for a literal dollar
  sign in text.
- A newline becomes a line break (`<br>`).
- HTML tags other than `<br>` cannot be combined with math in one label: use
  TeX (`\textbf{...}`, `^{...}`) inside the math instead. Labels without math
  keep their HTML (`<b>`, `<sub>`, ...).
- 3-D scene axis titles and tick labels cannot be typeset (WebGL): their
  `$...$` is converted to Unicode and HTML.
- Math is typeset by MathJax 2.7.9 from a CDN, so math labels need network
  access in windows and exports.

```julia
mathtext("cost \\\$5 per unit")      # literal dollar sign
mathtext("line 1\nline 2")            # two lines
```

`set_default_mathtext!(false)` passes labels to plotly unchanged except for
the newline conversion (the 1.x behaviour).

## Math size and font

[`set_default_mathtext!`](@ref) sets the MathJax size switch for labels with
math (`size = "\\large"`, ...), the MathJax font (`font = "TeX"`,
`"STIX-Web"`, `"Latin-Modern"` (default), ...), and whether the text parts of
a math label use the figure's font (`inherit_text_font = true`). Every call
replaces all settings; `set_default_mathtext!()` restores the defaults.
MathJax math renders at about 0.8 of the height of plain text of the same
font size, so `"\\large"` matches the two closely; the `:publication` style
uses it.

```julia
set_default_mathtext!(true; size = "\\large", font = "TeX", inherit_text_font = true)
fig = plot_scatter(1:3, [1, 4, 9]; xlabel = "Contrast \$\\lambda\$")
set_default_mathtext!()
get_default_mathtext()
```

## Fonts by role

[`set_fonts!`](@ref) sets the font family, colour and the sizes of the title,
axis labels, tick labels, legend, colorbars and annotations of an existing
figure in one call; `units = :pt` converts points to pixels (1 pt = 96/72 px).
For every new figure, set them in a [`PlotStyle`](@ref)
(see [Styles and templates](styles.md)).

```julia
fig = plot_scatter(1:10, (1:10) .^ 2; xlabel = "n", ylabel = "\$n^2\$", title = "Squares")
set_fonts!(fig; family = "Arial", title = 18, label = 14, tick = 11, legend = 11)
set_fonts!(fig; tick = 7.5, units = :pt)   # 10 px tick labels
```

## Titles

[`title!`](@ref) sets the figure title (`align = :left` aligns it with the
plot area, like matplotlib's `loc = "left"`), or a panel title with
`row`/`col`. `bold = true` makes the text parts bold, also around math.

```julia
fig = plot_scatter(1:10, rand(10))
title!(fig, "(a) Mesh study, \$\\lambda = 10^8\$"; align = :left, bold = true)
```

## Annotations

[`annotate!`](@ref) places text at a data point, with an arrow by default.
`coords = :axes` uses fractions of the plot area, `offset = (dx, dy)` shifts
the text in pixels, and on log axes the coordinates are data values.

```julia
fig = plot_scatter([1, 10, 100], [1, 100, 10_000]; xscale = "log", yscale = "log")
annotate!(fig, 10, 100, "knee"; offset = (30, -20))
annotate!(fig, 0.05, 0.95, "\$\\propto x^2\$"; coords = :axes, showarrow = false)
```

A 3-D form `annotate!(fig, x, y, z, text)` labels a point of a scene.
