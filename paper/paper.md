---
title: 'PlotlySupply.jl: High-level research visualization wrappers in Julia with a user-friendly API, built on PlotlyJS.jl'
tags:
  - Julia
  - scientific visualization
  - plotting
  - 3D graphics
  - data analysis
authors:
  - name: Jake W. Liu
    affiliation: 1
    corresponding: true
affiliations:
  - name: Department of Electronic Engineering, National Taipei University of Technology, Taiwan
    index: 1
date: 2 September 2025
bibliography: paper.bib
---

# Summary

`PlotlySupply.jl` is a high-level visualization toolkit for the Julia programming language, offering concise and consistent APIs for 2D, and 3D plotting [@plotly]. Built on top of `PlotlyJS.jl`, it is designed to streamline the generation of scientific figures while maintaining full access to Plotly’s interactivity and styling options.

The Plotly backend has a strong advantage in 3D rendering, and it is widely used among front-end engineers. However, its API is not so user-friendly for researchers. The API design of `PlotlySupply.jl` is intentionally similar to MATLAB-style plotting, making it intuitive for researchers transitioning to Julia or working in multi-language environments. It supports line plots, surface plots, vector field visualizations (quiver plots), heatmaps, and 3D scatter plots with minimal setup and boilerplate code. This makes it especially suitable for rapid prototyping, numerical simulations, and exploratory data visualization in scientific computing.

# Statement of need

Many research projects involve the frequent creation of diagnostic and publication-quality figures. While `PlotlyJS.jl` is highly customizable, it requires verbose code for routine tasks. One often needs to define the trace and layout separately before generating the plot. `PlotlySupply.jl` addresses this by wrapping low-level PlotlyJS calls with streamlined functions that follow predictable keyword conventions, automated axis labeling, and sensible visual defaults.

The design philosophy of `PlotlySupply.jl` is to provide a user experience similar to MATLAB's plotting functions. In MATLAB, functions like `plot`, `surf`, and `quiver` accept data arrays as primary arguments and use key-value pairs for customization. This procedural approach is often more intuitive for quick data exploration than the object-oriented paradigm of constructing `Trace` and `Layout` objects, which is the standard practice in `PlotlyJS.jl`. `PlotlySupply.jl` adopts this procedural, single-function-call approach for common plot types, which can significantly reduce the cognitive load and lines of code for the user.

Compared to other visualization ecosystems such as `Plots.jl` or `Makie.jl`, `PlotlySupply.jl` focuses specifically on interactive, web-ready figures with a MATLAB-like syntax. It provides convenience without sacrificing flexibility, making it ideal for researchers working in simulation-heavy domains such as physics, signal processing, and applied mathematics.

# Comparison with PlotlyJS.jl

To illustrate the convenience of `PlotlySupply.jl`, consider the task of creating a simple 2D line plot. With `PlotlyJS.jl`, one must define a `trace` for the data and a `layout` for the plot's appearance separately. To meet typical publication requirements for figures, additional effort is often needed to adjust the `Layout`, which can also be very cumbersome:

```julia
# Using PlotlyJS.jl
using PlotlyJS
x_data = 0:0.1:2π
y_data = sin.(x_data)
trace = scatter(x=x_data, y=y_data, mode="lines")
layout = Layout(
		title = "Sine Wave",
		yaxis = attr(
			title_text = "sin(x)",
			zeroline = false,
			showline = true,
			mirror = true,
			ticks = "outside",
			tick0 = minimum(y),
			automargin = true,
		),
		xaxis = attr(
			title_text = "x",
			zeroline = false,
			showline = true,
			mirror = true,
			ticks = "outside",
			tick0 = minimum(x),
			automargin = true,
		),
	)
plot(trace, layout)
```

`PlotlySupply.jl` simplifies this into a single function call, where layout properties are passed as keyword arguments:

```julia
# Using PlotlySupply.jl
using PlotlySupply
x_data = 0:0.1:2π
y_data = sin.(x_data)
plot_scatter(x_data, y_data; 
  title="Sine Wave", xlabel="x", ylabel="sin(x)")
```

This abstraction becomes even more valuable for more complex plots, such as a 3D surface. The boilerplate code for setting up the 3D scene, aspect ratio, and color scales is handled automatically.

# Example usage

### 1D Line Plot

```julia
plot_scatter(0:0.1:2π, sin.(0:0.1:2π);
    xlabel="x", ylabel="sin(x)", title="Sine Wave")
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

# Research applications

The package has been employed in visualization tasks for optical field simulations [@liu2024near] and electromagnetic scattering problems [@liu2024circularly]. Beyond these specific examples, `PlotlySupply.jl` is well-suited for a wide range of research domains:

*   **Physics and Engineering:** Visualizing vector fields (e.g., electric or fluid flow fields with `plot_quiver` and `plot_quiver3d`), wave propagation, and visualizing 3D structures or topographies with `plot_surface`.
*   **Signal Processing:** Plotting time-series data with `plot_scatter` and `plot_stem`, or visualizing 2D data like spectrograms or field distributions with `plot_heatmap`.

The simplified API allows researchers to quickly generate these visualizations with minimal code, enabling them to focus on the interpretation of their data.

# Acknowledgements

The author thanks the developers of `PlotlyJS.jl`, and the Julia open-source community for their tools and documentation. No external financial support was received for the development of this software.

# References

