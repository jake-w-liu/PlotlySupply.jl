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
date: 14 June 2025
bibliography: paper.bib
---

# Summary

`PlotlySupply.jl` is a high-level visualization toolkit for the Julia programming language, offering concise and consistent APIs for 2D, and 3D plotting [@plotly]. Built on top of `PlotlyJS.jl`, it is designed to streamline the generation of scientific figures while maintaining full access to Plotly’s interactivity and styling options.

The Plotly backend has a strong advantage in 3D rendering, and it is widely used among front-end engineers. However, its API is not so user-friendly for researchers. The API design of `PlotlySupply.jl` is intentionally similar to MATLAB-style plotting, making it intuitive for researchers transitioning to Julia or working in multi-language environments. It supports line plots, surface plots, vector field visualizations (quiver plots), heatmaps, and 3D scatter plots with minimal setup and boilerplate code. This makes it especially suitable for rapid prototyping, numerical simulations, and exploratory data visualization in scientific computing.

# Statement of need

Many research projects involve the frequent creation of diagnostic and publication-quality figures. While `PlotlyJS.jl` is highly customizable, it requires verbose code for routine tasks. One often needs to define the trace and layout separately before generating the plot. `PlotlySupply.jl` addresses this by wrapping low-level PlotlyJS calls with streamlined functions that follow predictable keyword conventions, automated axis labeling, and sensible visual defaults.

Compared to other visualization ecosystems such as `Plots.jl` or `Makie.jl`, `PlotlySupply.jl` focuses specifically on interactive, web-ready figures with a MATLAB-like syntax. It provides convenience without sacrificing flexibility, making it ideal for researchers working in simulation-heavy domains such as physics, signal processing, and applied mathematics.

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

The package has been employed in visualization tasks for optical field simulations [@liu2024near] and electromagnetic scattering problems [@liu2024circularly]. It provides an efficient plotting interface for projects requiring dynamic inspection of scalar or vector fields over time and space.

# Acknowledgements

The author thanks the developers of `PlotlyJS.jl`, and the Julia open-source community for their tools and documentation. No external financial support was received for the development of this software.

# References

