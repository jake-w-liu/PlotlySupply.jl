# Introduction

[![Build Status](https://github.com/jake-w-liu/PlotlySupply.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jake-w-liu/PlotlySupply.jl/actions/workflows/CI.yml?query=branch%3Amain)

[![Coverage](https://codecov.io/gh/jake-w-liu/PlotlySupply.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jake-w-liu/PlotlySupply.jl) 

**PlotlySupply.jl** is a lightweight Julia module that wraps `PlotlyBase.jl` to supply high-level abstractions for 2D and 3D plot visualizations. It simplifies the creation of line plots, heatmaps, quiver plots, polar plots, and surface plots, with consistent options for customization and layout control. High-level constructors open independent desktop windows through `ElectronCall.jl` via `PlotlySupply.SyncPlot`.

---


## Overview of Functions

### 2D Cartesian Plots

- `plot_scatter(x, y; ...)`: Line or marker plot for 1D data.
- `plot_scatter(y; ...)`: Uses index as x-axis.
- `plot_stem(x, y; ...)`: Stem plot using markers and vertical lines.
- `plot_stem(y; ...)`: Uses index as x-axis.
- `plot_bar(x, y; ...)` / `plot_bar(y; ...)`: Bar plot.
- `plot_histogram(x; ...)`: Histogram plot.
- `plot_box(x, y; ...)` / `plot_box(y; ...)`: Box plot.
- `plot_violin(x, y; ...)` / `plot_violin(y; ...)`: Violin plot.

### 2D Polar Plots

- `plot_scatterpolar(theta, r; ...)`: Polar plot in angular-radial coordinates.

### 2D Heatmap and Vector Plots

- `plot_heatmap(x, y, U; ...)`: Heatmap of matrix `U` over grid `x`, `y`.
- `plot_heatmap(U; ...)`: Uses default x/y indices.
- `plot_contour(x, y, U; ...)`: Contour plot of matrix `U` over grid `x`, `y`.
- `plot_contour(U; ...)`: Uses default x/y indices.
- `plot_quiver(x, y, u, v; ...)`: 2D quiver plot with arrows from vectors `(u,v)` at locations `(x,y)`.

### 3D Plots

- `plot_surface(X, Y, Z; ...)`: 3D surface plot with optional surface coloring.
- `plot_surface(Z; ...)`: Uses index grids as X/Y.
- `plot_scatter3d(x, y, z; ...)`: 3D scatter or line plot with multiple trace support.
- `plot_quiver3d(x, y, z, u, v, w; ...)`: 3D vector field rendered with cones.

### Utilities

- `set_template!(fig, template)`: Apply Plotly template style to a figure.
- `set_default_template!(template)` / `get_default_template()`: Configure package-wide default template.
- `set_legend!(fig; position=:topright, ...)`: Place legend with transparent box and symbolic positions (including `:outside_right`).
- `set_default_legend_position!(...)` / `get_default_legend_position()`: Configure package-wide default legend position.
- `to_syncplot(fig)`: Convert a `PlotlyBase.Plot` into a desktop `SyncPlot`.
- `plot(...)`: PlotlyJS-style constructor. Returns `Plot` by default; pass `sync=true` to get a `SyncPlot`.
- `savefig(...)`: PlotlyJS-style export helper (requires `PlotlyKaleido.jl` to be installed).
- `make_subplots(...)`, `mgrid(...)`: PlotlyJS-style helper utilities.
- `subplots(rows, cols; ...)`: High-level subplot canvas; pass `sync=false` for headless mode.
- `subplot!(sf, row, col)` / `subplot!(sf, index)`: Select active subplot cell.
- `subplot_legends!(fig; position=:topright, ...)`: Split legends by subplot and place them in-panel.
- `xlabel!(sf, ...)`, `ylabel!(sf, ...)`, `xrange!(sf, ...)`, `yrange!(sf, ...)`: Per-subplot axis helpers.

`ElectronCall.jl` and `PlotlyKaleido.jl` are loaded internally by PlotlySupply when needed, so you do not need `using ElectronCall` or `using PlotlyKaleido`.

### Mutating APIs

- `plot_*!(fig, ...)`: A set of mutating convenience functions (for example `plot_scatter!`, `plot_stem!`, `plot_bar!`, `plot_histogram!`, `plot_box!`, `plot_violin!`, `plot_heatmap!`, `plot_contour!`, `plot_surface!`, `plot_scatter3d!`, `plot_quiver!`, `plot_quiver3d!`) that append traces to an existing figure. These work with both `PlotlyBase.Plot` and `PlotlySupply.SyncPlot`.

Use the mutating APIs when you want MATLAB-style `hold on` behavior (append traces to an existing figure) instead of creating a new figure.

### Return Type and Display Behavior

- All high-level constructor APIs (`plot_scatter`, `plot_stem`, `plot_heatmap`, `plot_surface`, etc.) return a `PlotlyBase.Plot` by default.
- In the REPL, typing `plot_scatter(x, y)` without assignment triggers Julia's display system, which automatically opens an Electron window.
- Assigning to a variable (`fig = plot_scatter(x, y)`) suppresses display — no window opens. Use `display(fig)` to open the window later.
- Pass `show=true` to open a window immediately: `plot_scatter(x, y; show=true)` returns a `SyncPlot`.
- `SyncPlot` forwards properties like `fig.data` and `fig.layout`.
- The wrapped `PlotlyBase.Plot` is available at `fig.plot`.

---

## Examples

Please refer the [API documentation](https://jake-w-liu.github.io/PlotlySupply.jl/dev/) for full functionality.

### 2D Line Plot

```julia
plot_scatter(0:0.1:2π, sin.(0:0.1:2π); xlabel="x", ylabel="sin(x)", title="Sine Wave")
```

### PlotlyJS-Style API Compatibility

```julia
tr = scatter(x=1:10, y=rand(10), mode="lines+markers")
lay = Layout(title="Compatibility Mode")
fig = plot(tr, lay) # returns Plot; use display(fig) to open Electron window
```

### MATLAB-Like Subplots

```julia
sf = subplots(2, 2; show=true, legend_position=:topright)
plot!(sf, 1:100, cumsum(randn(100)); legend="run A")
subplot!(sf, 1, 2)
plot_stem!(sf, 1:100, abs.(randn(100)); legend="run B")
subplot!(sf, 3)
plot_contour!(sf, rand(30, 30))
subplot!(sf, 2, 2)
plot_heatmap!(sf, rand(30, 30))
xlabel!(sf, "time")
ylabel!(sf, "value")
xrange!(sf, [0, 100])
```

### 2D Heatmap

```julia
x = -5:0.1:5
y = -5:0.1:5
U = [sin(sqrt(xi^2 + yj^2)) for yj in y, xi in x]
plot_heatmap(x, y, U; xlabel="x", ylabel="y", title="Radial Sine")
```

### 2D Contour

```julia
x = -5:0.1:5
y = -5:0.1:5
U = [sin(sqrt(xi^2 + yj^2)) for yj in y, xi in x]
plot_contour(x, y, U; xlabel="x", ylabel="y", title="Radial Sine Contour")
```

### 3D Surface

```julia
x = y = -2π:0.1:2π
Y, X = meshgrid(y, x) ## uses MeshGrid.jl
Z = sin.(sqrt.(X.^2 .+ Y.^2))
plot_surface(X, Y, Z; title="3D Surface", colorscale="Viridis")
```

---

## Common Keyword Arguments

Most functions accept the following options:

| Keyword        | Description                                | Default         |
|----------------|--------------------------------------------|-----------------|
| `xlabel`, `ylabel`, `zlabel` | Axis labels               | `""` or `"x/y/z"` |
| `xrange`, `yrange`, `zrange` | Axis ranges as `[min, max]` | `[0, 0]`         |
| `width`, `height` | Plot size in pixels                     | `0` (auto)       |
| `color`, `colorscale` | Line or surface color settings    | `""` or `"Jet"`  |
| `title`         | Plot title                                | `""`             |
| `fontsize`      | Global font size                          | `0` (auto)       |
| `grid`          | Show/hide grid lines                      | `true`           |
| `showaxis`      | Show/hide axis lines and ticks            | `true`           |
| `aspectmode`    | `"auto"`, `"cube"`, `"data"`              | `"auto"`         |
| `mode`          | `"lines"`, `"markers"`, `"lines+markers"` | `"lines"`        |
| `linewidth`     | Line width in pixels (scalar or vector)    | `0` (auto)       |
| `show`          | Open Electron window immediately           | `false`          |

---

## Notes

- All plots use the `:plotly_white` template by default.
- Most functions support both scalar and vectorized input (e.g., multiple traces).

---

## License

This package is distributed under the MIT License.

---

## Author

Developed by Jake W. Liu. Contributions and issues are welcome.
