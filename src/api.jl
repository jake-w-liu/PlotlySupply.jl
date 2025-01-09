"""
function plot_rect(
    x::Union{AbstractRange, Vector},
    y::Union{AbstractRange, Vector};
    xlabel::String= "",
    ylabel::String = "",
    xrange::Vector = [0, 0],
    yrange::Vector = [0, 0],
    width::Int = 0,
    height::Int = 0,
    mode::String = "lines",
    color::String = "",
    name::String = "",
)
Plots a rectangular (Cartesian) plot.

#### Arguments

- `x`: x-coordinate data (can be vector of vectors)
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `name`: Name of the plot lines (default: `""`, can be vector)
"""
function plot_rect(
    x::Union{AbstractRange, Vector},
    y::Union{AbstractRange, Vector};
    xlabel::String= "",
    ylabel::String = "",
    xrange::Vector = [0, 0],
    yrange::Vector = [0, 0],
    width::Int = 0,
    height::Int = 0,
    mode::String = "lines",
    color::String = "",
    name::String = "",
)
    if isa(y, Vector) && eltype(y) <: Vector
        trace = Vector{GenericTrace}(undef, length(y))
        modeV = fill("line", length(y))
        colorV = fill("", length(y))
        nameV = fill("", length(y))
        
        if !(mode isa Vector)
            fill!(modeV, mode)
        else
            for n in eachindex(mode)
                modeV[n] = mode[n]
            end
        end
        if !(color isa Vector)
            fill!(colorV, color)
        else
            for n in eachindex(color)
                colorV[n] = color[n]
            end
        end
        if !(name isa Vector)
            fill!(nameV, name)
        else
            for n in eachindex(name)
                nameV[n] = name[n]
            end
        end

        if isa(x, Vector) && eltype(x) <: Vector
            for n in eachindex(y)
                trace[n] = scatter(
                    y = y[n],
                    x = x[n],
                    mode = modeV[n],
                    line = attr(color = colorV[n]),
                    name = nameV[n],
                )
            end
        else
            for n in eachindex(y)
                trace[n] = scatter(
                    y = y[n],
                    x = x,
                    mode = modeV[n],
                    line = attr(color = colorV[n]),
                    name = nameV[n],
                )
            end
        end
    else
        trace = scatter(y = y, x = x, mode = mode, line = attr(color = color), name = name)
    end
    layout = Layout(
        template = :plotly_white,
        yaxis = attr(
            title_text = ylabel,
            zeroline = false,
            showline = true,
            mirror = true,
            ticks = "outside",
            tick0 = minimum(y),
            automargin = true,
        ),
        xaxis = attr(
            title_text = xlabel,
            zeroline = false,
            showline = true,
            mirror = true,
            ticks = "outside",
            tick0 = minimum(x),
            automargin = true,
        ),
    )
    fig = plot(trace, layout)
    if !all(xrange .== [0, 0])
        update_xaxes!(fig, range = xrange)
    end
    if !all(yrange .== [0, 0])
        update_yaxes!(fig, range = yrange)
    end
    if width > 0
        relayout!(fig, width = width)
    end
    if height > 0
        relayout!(fig, height = height)
    end

    return fig
end

"""
function plot_rect(
    y::Union{AbstractRange, Vector};
    xlabel::String = "",
    ylabel::String = "",
    xrange::Vector = [0, 0],
    yrange::Vector = [0, 0],
    width::Int = 0,
    height::Int = 0,
    mode::String = "lines",
    color::String = "",
    name::String = "",
)
Plots a rectangular (Cartesian) plot (x-axis not specified).

#### Arguments

- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `name`: Name of the plot lines (default: `""`, can be vector)
"""
function plot_rect(
    y::Union{AbstractRange, Vector};
    xlabel::String = "",
    ylabel::String = "",
    xrange::Vector = [0, 0],
    yrange::Vector = [0, 0],
    width::Int = 0,
    height::Int = 0,
    mode::String = "lines",
    color::String = "",
    name::String = "",
)
    if isa(y, Vector) && eltype(y) <: Vector
        x = Vector{Vector{Int}}(undef, length(y))
        for n in eachindex(y)
            x[n] = 0:length(y[n])-1
        end
    else
        x = 0:length(y)-1
    end
    
    return plot_rect(
        x,
        y;
        xlabel = xlabel,
        ylabel = ylabel,
        xrange = xrange,
        yrange = yrange,
        width = width,
        height = height,
        mode = mode,
        color = color,
        name = name,
    )
end

"""
function plot_polar(
    theta::Union{AbstractRange, Vector},
    r::Union{AbstractRange, Vector};
    trange::Vector = [0, 0],
    rrange::Vector = [0, 0],
    width::Int = 0,
    height::Int = 0,
    mode::String = "lines",
    color::String = "",
    name::String = "",
)

Plots a polar plot.

#### Arguments

- `theta`: Angular coordinate data (can be vector of vectors)
- `r`: Radial coordinate data (can be vector of vectors)

#### Keywords

- `trange`: Range for the angular axis (default: `[0, 0]`)
- `rrange`: Range for the radial axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `name`: Name of the plot lines (default: `""`, can be vector)
"""
function plot_polar(
    theta::Union{AbstractRange, Vector},
    r::Union{AbstractRange, Vector};
    trange::Vector = [0, 0],
    rrange::Vector = [0, 0],
    width::Int = 0,
    height::Int = 0,
    mode::String = "lines",
    color::String = "",
    name::String = "",
)
    if isa(r, Vector) && eltype(r) <: Vector
        trace = Vector{GenericTrace}(undef, length(r))
        modeV = fill("line", length(r))
        colorV = fill("", length(r))
        nameV = fill("", length(r))
        
        if !(mode isa Vector)
            fill!(modeV, mode)
        else
            for n in eachindex(mode)
                modeV[n] = mode[n]
            end
        end
        if !(color isa Vector)
            fill!(colorV, color)
        else
            for n in eachindex(color)
                colorV[n] = color[n]
            end
        end
        if !(name isa Vector)
            fill!(nameV, name)
        else
            for n in eachindex(name)
                nameV[n] = name[n]
            end
        end

        if isa(theta, Vector) && eltype(theta) <: Vector
            for n in eachindex(r)
                trace[n] = scatterpolar(
                    r = r[n],
                    theta = theta[n],
                    mode = modeV[n],
                    line = attr(color = colorV[n]),
                    name = nameV[n],
                )
            end
        else
            for n in scatterpolar(r)
                trace[n] = scatter(
                    r = r[n],
                    theta = theta,
                    mode = modeV[n],
                    line = attr(color = colorV[n]),
                    name = nameV[n],
                )
            end
        end
    else
        trace = scatterpolar(
            r = r,
            theta = theta,
            mode = mode,
            line = attr(color = color),
            name = name,
        )
    end

    layout = Layout(
        template = :plotly_white,
        polar = attr(sector = [minimum(theta), maximum(theta)]),
    )
    fig = plot(trace, layout)
    if !all(rrange .== [0, 0])
        update_polars!(fig, radialaxis = attr(range = rrange))
    end
    if !all(trange .== [0, 0])
        update_polars!(fig, attr(sector = trange))
    end
    if width > 0
        relayout!(fig, width = width)
    end
    if height > 0
        relayout!(fig, height = height)
    end

    return fig
end

"""
function plot_holo(
    x::Union{AbstractRange, Vector},
    y::Union{AbstractRange, Vector},
    U::Array;
    xlabel::String = "",
    ylabel::String = "",
    zrange::Vector = [0, 0],
    ref_size::Int = 500,
    colorscale::String = "Jet",
)

Plots holographic data.

#### Arguments

- 'x::AbstractRange': x-axis range
- 'y::AbstractRange': x-axis range
- `U`: 2D hologram data

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `ref_size`: ref size of the plot in pixels (default: `500`)
- `colorscale`: Color scale for the heatmap (default: `"Jet"`)
"""
function plot_holo(
    x::Union{AbstractRange, Vector},
    y::Union{AbstractRange, Vector},
    U::Array;
    xlabel::String = "",
    ylabel::String = "",
    zrange::Vector = [0, 0],
    ref_size::Int = 500,
    colorscale::String = "Jet",
)
    #calculate figure size
    height = length(y)
    width = length(x)
    ratio = height / (width)
    if width > height
        width = ref_size
        height = round(Int64, width * ratio)
    else
        height = ref_size
        width = round(Int64, height / ratio)
    end
    if height >= width
        width += round(Int, ratio) * 45
    elseif height < width
        height += round(Int, 1/ratio) * 20
    end

    FV = @view U[:, :]
    FV = transpose(FV)
    trace = heatmap(x = x, y = y, z = FV, colorscale = colorscale)
    if !all(zrange .== [0, 0])
        trace.zmin = zrange[1]
        trace.zmax = zrange[2]
    end
    if length(x) > 1
        dx = x[2] - x[1]
    else
        dx = 0
    end
    if length(y) > 1
        dy = y[2] - y[1]
    else
        dy = 0
    end
    if dx == 0 && dy != 0
        dx = dy
    elseif dy == 0 && dx != 0
        dy = dx
    end
    layout = Layout(
        height = height,
        width = width,
        plot_bgcolor = "white",
        scene = attr(aspectmode = "data"),
        xaxis = attr(
            title = xlabel,
            range = [minimum(x) - dx / 2, maximum(x) + dx / 2],
            automargin = true,
            scaleanchor = "y",
        ),
        yaxis = attr(
            title = ylabel,
            range = [minimum(y) - dy / 2, maximum(y) + dy / 2],
            automargin = true,
        ),
        margin = attr(r = 0, b = 0),
    )
    fig = plot(trace, layout)

    return fig
end

"""
function plot_holo(
    U::Array;
    xlabel::String = "",
    ylabel::String = "",
    zrange::Vector = [0, 0],
    ref_size::Int = 500,
    colorscale::String = "Jet",
)

Plots holographic data.

#### Arguments

- `U`: 2D hologram data

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `ref_size`: ref size of the plot in pixels (default: `500`)
- `colorscale`: Color scale for the heatmap (default: `"Jet"`)
"""
function plot_holo(
    U::Array;
    xlabel::String = "",
    ylabel::String = "",
    zrange::Vector = [0, 0],
    ref_size::Int = 500,
    colorscale::String = "Jet",
)
    x = collect(0:1:size(U, 1)-1)
    y = collect(0:1:size(U, 2)-1)
    return plot_holo(x, y, U; xlabel=xlabel, ylabel=ylabel, zrange=zrange, ref_size=ref_size, colorscale=colorscale)
end

function plot_surf(
    X::Array,
    Y::Array,
    Z::Array;
    xlabel::String = "",
    ylabel::String = "",
    zlabel::String = "",
    aspectmode::String = "",
    colorscale::String = "Jet",
)
    # trace = surface(x = X, y = Y, z = Z, surfacecolor = S, colorscale = "Jet")
    trace = surface(x = X, y = Y, z = Z, colorscale = "Jet")
    layout = Layout(
        scene = attr(
            aspectmode = aspectmode,
            xaxis = attr(title = xlabel),
            yaxis = attr(title = ylabel),
            zaxis = attr(title = zlabel),
        ),

        # coloraxis = attr(cmax = maximum(C), cmin = minimum(C)),
        # template = :plotly_white,
    )

    # fig = plot(trace, layout)

    return plot(trace, layout)
end
