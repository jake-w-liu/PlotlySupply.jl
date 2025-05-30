# Julia Plotting API Documentation

A comprehensive plotting library built on PlotlyJS for creating interactive 1D, 2D, and 3D visualizations.

## Table of Contents

- [1D Plotting Functions](#1d-plotting-functions)
  - [plot_scatter](#plot_scatter)
  - [plot_stem](#plot_stem)
  - [plot_scatterpolar](#plot_scatterpolar)
- [2D Plotting Functions](#2d-plotting-functions)
  - [plot_heatmap](#plot_heatmap)
  - [plot_quiver](#plot_quiver)
- [3D Plotting Functions](#3d-plotting-functions)
  - [plot_surface](#plot_surface)
  - [plot_scatter3d](#plot_scatter3d)
  - [plot_quiver3d](#plot_quiver3d)
- [Utility Functions](#utility-functions)
  - [set_template!](#set_template)
  - [tuple_interleave](#tuple_interleave)

---

## 1D Plotting Functions

### plot_scatter

Creates rectangular (Cartesian) scatter/line plots with extensive customization options.

#### Signatures

```julia
plot_scatter(x, y; kwargs...)
plot_scatter(y; kwargs...)
```

#### Arguments

- **`x`** (`Union{AbstractRange, Vector}`): x-coordinate data (can be vector of vectors)
- **`y`** (`Union{AbstractRange, Vector}`): y-coordinate data (can be vector of vectors)

When only `y` is provided, x-coordinates are automatically generated as `0:length(y)-1`.

#### Keywords

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `xlabel` | `String` | `""` | Label for the x-axis |
| `ylabel` | `String` | `""` | Label for the y-axis |
| `xrange` | `Vector` | `[0, 0]` | Range for the x-axis |
| `yrange` | `Vector` | `[0, 0]` | Range for the y-axis |
| `width` | `Int` | `0` | Width of the plot |
| `height` | `Int` | `0` | Height of the plot |
| `mode` | `Union{String, Vector{String}}` | `"lines"` | Plotting mode |
| `dash` | `Union{String, Vector{String}}` | `""` | Line style ("dash", "dashdot", or "dot") |
| `color` | `Union{String, Vector{String}}` | `""` | Color of the plot lines |
| `legend` | `Union{String, Vector{String}}` | `""` | Name of the plot lines |
| `title` | `String` | `""` | Title of the figure |
| `grid` | `Bool` | `true` | Whether to show the grid |

#### Examples

```julia
# Simple line plot
x = 1:10
y = x.^2
fig = plot_scatter(x, y, xlabel="X", ylabel="Y²", title="Quadratic Function")

# Multiple lines with different styles
y1 = sin.(x)
y2 = cos.(x)
fig = plot_scatter(x, [y1, y2], 
                   mode=["lines", "lines"], 
                   dash=["", "dash"],
                   color=["blue", "red"],
                   legend=["sin(x)", "cos(x)"])
```

---

### plot_stem

Creates stem plots (discrete data visualization with vertical lines and markers).

#### Signatures

```julia
plot_stem(x, y; kwargs...)
plot_stem(y; kwargs...)
```

#### Arguments

- **`x`** (`Union{AbstractRange, Vector}`): x-coordinate data (can be vector of vectors)
- **`y`** (`Union{AbstractRange, Vector}`): y-coordinate data (can be vector of vectors)

#### Keywords

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `xlabel` | `String` | `""` | Label for the x-axis |
| `ylabel` | `String` | `""` | Label for the y-axis |
| `xrange` | `Vector` | `[0, 0]` | Range for the x-axis |
| `yrange` | `Vector` | `[0, 0]` | Range for the y-axis |
| `width` | `Int` | `0` | Width of the plot |
| `height` | `Int` | `0` | Height of the plot |
| `color` | `Union{String, Vector{String}}` | `""` | Color of the plot lines |
| `legend` | `Union{String, Vector{String}}` | `""` | Name of the plot lines |
| `title` | `String` | `""` | Title of the figure |
| `grid` | `Bool` | `true` | Whether to show the grid |

#### Example

```julia
# Discrete signal visualization
n = 0:10
signal = [1, 0, -1, 0, 1, 0, -1, 0, 1, 0, -1]
fig = plot_stem(n, signal, xlabel="Sample", ylabel="Amplitude")
```

---

### plot_scatterpolar

Creates polar coordinate plots.

#### Signature

```julia
plot_scatterpolar(theta, r; kwargs...)
```

#### Arguments

- **`theta`** (`Union{AbstractRange, Vector}`): Angular coordinate data (can be vector of vectors)
- **`r`** (`Union{AbstractRange, Vector}`): Radial coordinate data (can be vector of vectors)

#### Keywords

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `trange` | `Vector` | `[0, 0]` | Range for the angular axis |
| `rrange` | `Vector` | `[0, 0]` | Range for the radial axis |
| `width` | `Int` | `0` | Width of the plot |
| `height` | `Int` | `0` | Height of the plot |
| `mode` | `Union{String, Vector{String}}` | `"lines"` | Plotting mode |
| `dash` | `Union{String, Vector{String}}` | `""` | Line style |
| `color` | `Union{String, Vector{String}}` | `""` | Color of the plot lines |
| `legend` | `Union{String, Vector{String}}` | `""` | Legend of the plot lines |
| `title` | `String` | `""` | Title of the figure |
| `grid` | `Bool` | `true` | Whether to show the grid |

#### Example

```julia
# Polar rose pattern
theta = 0:0.1:4π
r = sin.(4 * theta)
fig = plot_scatterpolar(theta, r, title="Rose Pattern")
```

---

## 2D Plotting Functions

### plot_heatmap

Creates 2D heatmap visualizations for matrix data.

#### Signatures

```julia
plot_heatmap(x, y, U; kwargs...)
plot_heatmap(U; kwargs...)
```

#### Arguments

- **`x`** (`Union{AbstractRange, Vector}`): x-axis range
- **`y`** (`Union{AbstractRange, Vector}`): y-axis range  
- **`U`** (`Array`): 2D data array

When only `U` is provided, coordinates are automatically generated as array indices.

#### Keywords

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `xlabel` | `String` | `""` | Label for the x-axis |
| `ylabel` | `String` | `""` | Label for the y-axis |
| `xrange` | `Vector` | `[0, 0]` | Range for the x-axis |
| `yrange` | `Vector` | `[0, 0]` | Range for the y-axis |
| `zrange` | `Vector` | `[0, 0]` | Range for the z-axis (color scale) |
| `width` | `Int` | `0` | Width of the plot |
| `height` | `Int` | `0` | Height of the plot |
| `ref_size` | `Int` | `500` | Reference size of the plot in pixels |
| `colorscale` | `String` | `"Jet"` | Color scale for the heatmap |
| `title` | `String` | `""` | Title of the figure |
| `grid` | `Bool` | `true` | Whether to show the grid |

#### Example

```julia
# Temperature distribution heatmap
x = -5:0.1:5
y = -5:0.1:5
X = repeat(x', length(y), 1)
Y = repeat(y, 1, length(x))
Z = exp.(-(X.^2 + Y.^2))
fig = plot_heatmap(x, y, Z, title="2D Gaussian", colorscale="Viridis")
```

---

### plot_quiver

Creates 2D vector field (quiver) plots using arrow segments.

#### Signature

```julia
plot_quiver(x, y, u, v; kwargs...)
```

#### Arguments

- **`x`** (`Union{AbstractRange, Vector}`): x-coordinates of vector origins
- **`y`** (`Union{AbstractRange, Vector}`): y-coordinates of vector origins
- **`u`** (`Union{AbstractRange, Vector}`): x-components of vector directions
- **`v`** (`Union{AbstractRange, Vector}`): y-components of vector directions

#### Keywords

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `color` | `String` | `"RoyalBlue"` | Arrow color |
| `sizeref` | `Real` | `1` | Reference scaling for arrow length |
| `xlabel` | `String` | `""` | Label for the x-axis |
| `ylabel` | `String` | `""` | Label for the y-axis |
| `xrange` | `Vector` | `[0, 0]` | Range for the x-axis |
| `yrange` | `Vector` | `[0, 0]` | Range for the y-axis |
| `width` | `Int` | `0` | Width of the figure in pixels |
| `height` | `Int` | `0` | Height of the figure in pixels |
| `ref_size` | `Int` | `500` | Reference size of the plot in pixels |
| `colorscale` | `String` | `"Jet"` | Not used but included for compatibility |
| `title` | `String` | `""` | Title of the figure |
| `grid` | `Bool` | `true` | Whether to show the grid |

#### Example

```julia
# Vector field visualization
x = -2:0.5:2
y = -2:0.5:2
X = repeat(x', length(y), 1)
Y = repeat(y, 1, length(x))
U = -Y[:]
V = X[:]
fig = plot_quiver(X[:], Y[:], U, V, title="Circulation Field")
```

---

## 3D Plotting Functions

### plot_surface

Creates 3D surface plots from coordinate grids or height matrices.

#### Signatures

```julia
plot_surface(X, Y, Z; kwargs...)
plot_surface(Z; kwargs...)
```

#### Arguments

- **`X`** (`Array`): Grid of x-coordinates
- **`Y`** (`Array`): Grid of y-coordinates
- **`Z`** (`Array`): Grid of z-values defining the surface height

When only `Z` is provided, coordinate grids are generated from array indices.

#### Keywords

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `surfacecolor` | `Array` | `[]` | Color values for each surface point |
| `xrange` | `Vector` | `[0, 0]` | Range for the x-axis |
| `yrange` | `Vector` | `[0, 0]` | Range for the y-axis |
| `zrange` | `Vector` | `[0, 0]` | Range for the z-axis |
| `width` | `Int` | `0` | Width of the figure in pixels |
| `height` | `Int` | `0` | Height of the figure in pixels |
| `xlabel` | `String` | `""` | Label for the x-axis (defaults to "x") |
| `ylabel` | `String` | `""` | Label for the y-axis (defaults to "y") |
| `zlabel` | `String` | `""` | Label for the z-axis (defaults to "z") |
| `aspectmode` | `String` | `"auto"` | Aspect mode setting |
| `colorscale` | `String` | `"Jet"` | Color scale for the surface |
| `title` | `String` | `""` | Title of the figure |
| `grid` | `Bool` | `true` | Whether to display grid lines |
| `showaxis` | `Bool` | `true` | Whether to show axis lines and labels |

#### Example

```julia
# 3D mountain surface
x = -3:0.1:3
y = -3:0.1:3
X = repeat(x', length(y), 1)
Y = repeat(y, 1, length(x))
Z = 3 * (1 .- X).^2 .* exp.(-(X.^2) - (Y .+ 1).^2)
fig = plot_surface(X, Y, Z, title="3D Surface", colorscale="Plasma")
```

---

### plot_scatter3d

Creates 3D scatter or line plots with support for multiple curves.

#### Signature

```julia
plot_scatter3d(x, y, z; kwargs...)
```

#### Arguments

- **`x`** (`Union{AbstractRange, Vector}`): x-coordinates (can be vector of vectors for multiple curves)
- **`y`** (`Union{AbstractRange, Vector}`): y-coordinates (can be vector of vectors for multiple curves)
- **`z`** (`Union{AbstractRange, Vector}`): z-coordinates (can be vector of vectors for multiple curves)

#### Keywords

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `xrange` | `Vector` | `[0, 0]` | Range for the x-axis |
| `yrange` | `Vector` | `[0, 0]` | Range for the y-axis |
| `zrange` | `Vector` | `[0, 0]` | Range for the z-axis |
| `width` | `Int` | `0` | Width of the figure in pixels |
| `height` | `Int` | `0` | Height of the figure in pixels |
| `mode` | `Union{String, Vector{String}}` | `"lines"` | Drawing mode |
| `color` | `Union{String, Vector{String}}` | `""` | Line color(s) |
| `legend` | `Union{String, Vector{String}}` | `""` | Trace label(s) for the legend |
| `xlabel` | `String` | `""` | Label for x-axis (defaults to "x") |
| `ylabel` | `String` | `""` | Label for y-axis (defaults to "y") |
| `zlabel` | `String` | `""` | Label for z-axis (defaults to "z") |
| `aspectmode` | `String` | `"auto"` | Aspect mode for 3D view |
| `title` | `String` | `""` | Title of the plot |
| `perspective` | `Bool` | `true` | If false, uses orthographic projection |
| `grid` | `Bool` | `true` | Whether to show grid lines |
| `showaxis` | `Bool` | `true` | Whether to show axis lines and labels |

#### Example

```julia
# 3D parametric curve
t = 0:0.1:4π
x = cos.(t)
y = sin.(t)
z = t
fig = plot_scatter3d(x, y, z, mode="lines", title="3D Helix")
```

---

### plot_quiver3d

Creates 3D vector field visualizations using cone glyphs.

#### Signature

```julia
plot_quiver3d(x, y, z, u, v, w; kwargs...)
```

#### Arguments

- **`x`** (`Union{AbstractRange, Vector}`): x-coordinates of vector origins
- **`y`** (`Union{AbstractRange, Vector}`): y-coordinates of vector origins
- **`z`** (`Union{AbstractRange, Vector}`): z-coordinates of vector origins
- **`u`** (`Union{AbstractRange, Vector}`): x-components of the vector field
- **`v`** (`Union{AbstractRange, Vector}`): y-components of the vector field
- **`w`** (`Union{AbstractRange, Vector}`): z-components of the vector field

#### Keywords

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `sizeref` | `Real` | `1` | Scaling factor for cone size |
| `xrange` | `Vector` | `[0, 0]` | Range for the x-axis |
| `yrange` | `Vector` | `[0, 0]` | Range for the y-axis |
| `zrange` | `Vector` | `[0, 0]` | Range for the z-axis |
| `width` | `Int` | `0` | Width of the figure in pixels |
| `height` | `Int` | `0` | Height of the figure in pixels |
| `color` | `Union{String, Vector{String}}` | `""` | Uniform color for all vectors |
| `colorscale` | `String` | `"Jet"` | Colorscale when color is not specified |
| `xlabel` | `String` | `""` | Label for x-axis (defaults to "x") |
| `ylabel` | `String` | `""` | Label for y-axis (defaults to "y") |
| `zlabel` | `String` | `""` | Label for z-axis (defaults to "z") |
| `aspectmode` | `String` | `"auto"` | Aspect mode for 3D rendering |
| `title` | `String` | `""` | Title of the plot |
| `perspective` | `Bool` | `true` | If false, uses orthographic projection |
| `grid` | `Bool` | `true` | Controls visibility of grid lines |
| `showaxis` | `Bool` | `true` | Controls visibility of axis lines and labels |

#### Example

```julia
# 3D magnetic field visualization
x = [-1, 0, 1]
y = [0, 0, 0]
z = [0, 0, 0]
u = [1, 0, -1]
v = [0, 1, 0]
w = [0, 0, 1]
fig = plot_quiver3d(x, y, z, u, v, w, sizeref=0.5, title="3D Vector Field")
```

---

## Utility Functions

### set_template!

Applies a visual template to a PlotlyJS figure.

#### Signature

```julia
set_template!(fig; template=:plotly_white)
```

#### Arguments

- **`fig`**: A PlotlyJS.Plot object
- **`template`**: Symbol or string specifying the template (default: `:plotly_white`)

#### Available Templates

- `:plotly` - Default Plotly theme
- `:plotly_white` - Clean white background
- `:plotly_dark` - Dark theme
- `:ggplot2` - ggplot2-style theme
- `:seaborn` - Seaborn-style theme
- `:simple_white` - Minimal white theme

please refer to [this page](https://plotly.com/python/templates/) for more information.

#### Example

```julia
fig = plot_scatter(1:10, (1:10).^2)
set_template!(fig, :plotly_dark)
```

---

### tuple_interleave

Auxiliary function to interleave elements of a NTuple of vectors (N = 3 or 4).

#### Signature

```julia
tuple_interleave(tu::Union{NTuple{3, Vector}, NTuple{4, Vector}})
```

#### Arguments

- **`tu`**: A tuple containing 3 or 4 vectors

#### Returns

- A single vector with interleaved elements from the input tuple

This function is primarily used internally for creating arrow visualizations in quiver plots.

---

## Common Patterns and Tips

### Multiple Data Series

Most plotting functions support multiple data series by passing vectors of vectors:

```julia
# Multiple y-series with shared x
x = 1:10
y1 = sin.(x)
y2 = cos.(x)
y3 = tan.(x/10)
fig = plot_scatter(x, [y1, y2, y3], 
                   legend=["sin", "cos", "tan"],
                   color=["red", "blue", "green"])
```

### Customizing Appearance

```julia
fig = plot_scatter(x, y, 
                   xlabel="Time (s)", 
                   ylabel="Amplitude", 
                   title="Signal Analysis",
                   width=800, 
                   height=600,
                   grid=false)
set_template!(fig, :plotly_dark)
display(fig)
```

### Axis Ranges

Set axis ranges using the `xrange`, `yrange`, and `zrange` parameters:

```julia
fig = plot_scatter(x, y, xrange=[0, 10], yrange=[-2, 2])
```

Use `[0, 0]` (default) for automatic range detection.

### Color Scales

Available colorscales include:
- `"Jet"` - Rainbow colors
- `"Viridis"` - Perceptually uniform
- `"Plasma"` - Purple to yellow
- `"Blues"` - Blue gradient
- `"Greens"` - Green gradient
- `"Reds"` - Red gradient
- And many more from Plotly's colorscale library

---

## Error Handling

- Ensure that vector dimensions match when plotting multiple series
- Check that `x`, `y`, and `z` coordinate arrays have compatible sizes for 3D plots
- Use valid colorscale names (case-sensitive)
- Template names should be valid Plotly template identifiers
