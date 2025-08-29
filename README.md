# PlotlySupply

[![Build Status](https://github.com/jake-w-liu/PlotlySupply.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jake-w-liu/PlotlySupply.jl/actions/workflows/CI.yml?query=branch%3Amain)
<!-- [![Coverage](https://codecov.io/gh/jake-w-liu/PlotlySupply.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jake-w-liu/PlotlySupply.jl) -->


# PlotlySupply.jl

**PlotlySupply.jl** is a lightweight Julia module that wraps PlotlyJS to supply a set of high-level abstractions for 2D and 3D plot visualizations. It simplifies the creation of line plots, heatmaps, quiver plots, polar plots, and surface plots, with consistent options for customization and layout control. Notice that this module re-exprots [`PlotlyJS.jl`](https://github.com/JuliaPlots/PlotlyJS.jl).

---


## Overview of Functions

### 2D Cartesian Plots

- `plot_scatter(x, y; ...)`: Line or marker plot for 1D data.
- `plot_scatter(y; ...)`: Uses index as x-axis.
- `plot_stem(x, y; ...)`: Stem plot using markers and vertical lines.
- `plot_stem(y; ...)`: Uses index as x-axis.

### 2D Polar Plots

- `plot_scatterpolar(theta, r; ...)`: Polar plot in angular-radial coordinates.

### 2D Heatmap and Vector Plots

- `plot_heatmap(x, y, U; ...)`: Heatmap of matrix `U` over grid `x`, `y`.
- `plot_heatmap(U; ...)`: Uses default x/y indices.
- `plot_quiver(x, y, u, v; ...)`: 2D quiver plot with arrows from vectors `(u,v)` at locations `(x,y)`.

### 3D Plots

- `plot_surface(X, Y, Z; ...)`: 3D surface plot with optional surface coloring.
- `plot_surface(Z; ...)`: Uses index grids as X/Y.
- `plot_scatter3d(x, y, z; ...)`: 3D scatter or line plot with multiple trace support.
- `plot_quiver3d(x, y, z, u, v, w; ...)`: 3D vector field rendered with cones.

### Utilities

- `set_template!(fig, template)`: Apply Plotly template style to a figure.

---

## Examples

Please refer the [API documentation](https://jake-w-liu.github.io/PlotlySupply.jl/dev/) for full functionality.

### 2D Line Plot

```julia
plot_scatter(0:0.1:2π, sin.(0:0.1:2π); xlabel="x", ylabel="sin(x)", title="Sine Wave")
```

### 2D Heatmap

```julia
x = -5:0.1:5
y = -5:0.1:5
U = [sin(sqrt(xi^2 + yj^2)) for yj in y, xi in x]
plot_heatmap(x, y, U; xlabel="x", ylabel="y", title="Radial Sine")
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
| `grid`          | Show/hide grid lines                      | `true`           |
| `showaxis`      | Show/hide axis lines and ticks            | `true`           |
| `aspectmode`    | `"auto"`, `"cube"`, `"data"`              | `"auto"`         |
| `mode`          | `"lines"`, `"markers"`, `"lines+markers"` | `"lines"`        |

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
