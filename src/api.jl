#region 1D Plot

"""
function plot_scatter(
	x::Union{AbstractRange, Vector},
	y::Union{AbstractRange, Vector};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	grid::Bool = true,
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
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)

"""
function plot_scatter(
	x::Union{AbstractRange, Vector},
	y::Union{AbstractRange, Vector};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	grid::Bool = true,
)
	if isa(y, Vector) && eltype(y) <: Vector
		trace = Vector{GenericTrace}(undef, length(y))
		modeV = fill("line", length(y))
		colorV = fill("", length(y))
		legendV = fill("", length(y))

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
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				trace[n] = scatter(
					y = y[n],
					x = x[n],
					mode = modeV[n],
					line = attr(color = colorV[n]),
					name = legendV[n],
				)
			end
		else
			for n in eachindex(y)
				trace[n] = scatter(
					y = y[n],
					x = x,
					mode = modeV[n],
					line = attr(color = colorV[n]),
					name = legendV[n],
				)
			end
		end
	else
		trace = scatter(y = y, x = x, mode = mode, line = attr(color = color), legend = legend)
	end
	layout = Layout(
		title = title,
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
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	relayout!(fig, template = :plotly_white)
	return fig
end

"""
function plot_scatter(
	y::Union{AbstractRange, Vector}; 
    xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	grid::Bool = true,
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
- `legend`: legend of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)

"""
function plot_scatter(
	y::Union{AbstractRange, Vector}; 
    xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	grid::Bool = true,
)
	if isa(y, Vector) && eltype(y) <: Vector
		x = Vector{Vector{Int}}(undef, length(y))
		for n in eachindex(y)
			x[n] = 0:length(y[n])-1
		end
	else
		x = 0:length(y)-1
	end

	return plot_scatter(
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
		legend = legend,
		title = title,
		grid = grid,
	)
end

"""
function plot_scatterpolar(
	theta::Union{AbstractRange, Vector},
	r::Union{AbstractRange, Vector};
	trange::Vector = [0, 0],
	rrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	grid::Bool = true,
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
- `legend`: legend of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)

"""
function plot_scatterpolar(
	theta::Union{AbstractRange, Vector},
	r::Union{AbstractRange, Vector};
	trange::Vector = [0, 0],
	rrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	grid::Bool = true,
)
	if isa(r, Vector) && eltype(r) <: Vector
		trace = Vector{GenericTrace}(undef, length(r))
		modeV = fill("line", length(r))
		colorV = fill("", length(r))
		legendV = fill("", length(r))

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
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end

		if isa(theta, Vector) && eltype(theta) <: Vector
			for n in eachindex(r)
				trace[n] = scatterpolar(
					r = r[n],
					theta = theta[n],
					mode = modeV[n],
					line = attr(color = colorV[n]),
					name = legendV[n],
				)
			end
		else
			for n in scatterpolar(r)
				trace[n] = scatter(
					r = r[n],
					theta = theta,
					mode = modeV[n],
					line = attr(color = colorV[n]),
					name = legendV[n],
				)
			end
		end
	else
		trace = scatterpolar(
			r = r,
			theta = theta,
			mode = mode,
			line = attr(color = color),
			name = legend,
		)
	end

	layout = Layout(
		title = title,
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
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	relayout!(fig, template = :plotly_white)
	return fig
end

#endregion

#region 2D Plot

"""
function plot_heatmap(
	x::Union{AbstractRange, Vector},
	y::Union{AbstractRange, Vector},
	U::Array; 
    xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	ref_size::Int = 500,
	colorscale::String = "Jet",
	title::String = "",
	grid::Bool = true,
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
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)

"""
function plot_heatmap(
	x::Union{AbstractRange, Vector},
	y::Union{AbstractRange, Vector},
	U::Array; 
    xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	ref_size::Int = 500,
	colorscale::String = "Jet",
	title::String = "",
	grid::Bool = true,
)
	#calculate figure size
	height_ref = length(y)
	width_ref = length(x)
	ratio = height_ref / (width_ref)
	if width_ref > height_ref
		width_ref = ref_size
		height_ref = round(Int64, width_ref * ratio)
	else
		height_ref = ref_size
		width_ref = round(Int64, height_ref / ratio)
	end
	if height_ref >= width_ref
		width_ref += round(Int, ratio) * 45
	elseif height_ref < width_ref
		height_ref += round(Int, 1 / ratio) * 20
	end

	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
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
		title = title,
		height = height_ref,
		width = width_ref,
		scene = attr(aspectmode = "data"),
		xaxis = attr(
			title = xlabel,
			constrain = "domain",
			automargin = true,
			zeroline = false,
			showline = true,
			mirror = true,
			ticks = "outside",
		),
		yaxis = attr(
			title = ylabel,
			constrain = "domain",
			zeroline = false,
			automargin = true,
			showline = true,
			mirror = true,
			ticks = "outside",
		),
		margin = attr(r = 0, b = 0, t = 0, l = 0),
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
	update_xaxes!(fig,
		scaleanchor = "y",
		scaleratio = 1,
	)
	relayout!(fig, template = :plotly_white)
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	return fig
end

"""
function plot_heatmap(
	U::Array; 
    xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	ref_size::Int = 500,
	colorscale::String = "Jet",
	title::String = "",
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
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)

"""
function plot_heatmap(
	U::Array; 
    xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	ref_size::Int = 500,
	colorscale::String = "Jet",
	title::String = "",
    grid::Bool = true,
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_heatmap(x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		ref_size = ref_size,
		colorscale = colorscale,
		title = title,
		width = width,
		height = heigh,
		grid = grid,
	)
end

"""
function plot_quiver(
	x::Vector,
	y::Vector,
	u::Vector,
	v::Vector; 
    color::String = "RoyalBlue",
	sizeref::Real = 1,
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	ref_size::Int = 500,
	colorscale::String = "Jet",
	title::String = "",
	grid::Bool = true,
)
"""
function plot_quiver(
	x::Vector,
	y::Vector,
	u::Vector,
	v::Vector; 
    color::String = "RoyalBlue",
	sizeref::Real = 1,
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	ref_size::Int = 500,
	colorscale::String = "Jet",
	title::String = "",
	grid::Bool = true,
)
	p_max = maximum(sqrt.(u .^ 2 .+ v .^ 2))
	u_ref = u ./ p_max .* sizeref
	v_ref = v ./ p_max .* sizeref
	end_x = x .+ u_ref .* 2 / 3
	end_y = y .+ v_ref .* 2 / 3

	vect_nans = repeat([NaN], length(x))

	arrow_length = sqrt.(u_ref .^ 2 .+ v_ref .^ 2)
	barb_angle = atan.(v_ref, u_ref)

	ang1 = barb_angle .+ atan(1 / 4)
	ang2 = barb_angle .- atan(1 / 4)

	seg1_x = arrow_length .* cos.(ang1) .* sqrt(1.0625)
	seg1_y = arrow_length .* sin.(ang1) .* sqrt(1.0625)

	seg2_x = arrow_length .* cos.(ang2) .* sqrt(1.0625)
	seg2_y = arrow_length .* sin.(ang2) .* sqrt(1.0625)

	arrowend1_x = end_x .- seg1_x
	arrowend1_y = end_y .- seg1_y
	arrowend2_x = end_x .- seg2_x
	arrowend2_y = end_y .- seg2_y
	arrow_x = tuple_interleave((arrowend1_x, end_x, arrowend2_x, vect_nans))
	arrow_y = tuple_interleave((arrowend1_y, end_y, arrowend2_y, vect_nans))

	arrow = scatter(x = arrow_x, y = arrow_y, mode = "lines", line_color = color,
		fill = "toself", fillcolor = color, hoverinfo = "skip")

	layout = Layout(
		title = title,
		scene = attr(aspectmode = "data"),
		xaxis = attr(
			title = xlabel,
			constrain = "domain",
			automargin = true,
			zeroline = false,
			showline = true,
			mirror = true,
			ticks = "outside",
		),
		yaxis = attr(
			title = ylabel,
			constrain = "domain",
			zeroline = false,
			automargin = true,
			showline = true,
			mirror = true,
			ticks = "outside",
		),
		margin = attr(r = 0, b = 0, t = 0, l = 0),
	)

	fig = plot(arrow, layout)
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

	update_xaxes!(fig,
		scaleanchor = "y",
		scaleratio = 1,
	)
	if !grid
		update_xaxes!(fig, showgrid = false)
		update_yaxes!(fig, showgrid = false)
	end
	relayout!(fig, template = :plotly_white)
	return fig
end

#endregion

#region 3D Plot
"""
function plot_surface(
	X::Array,
	Y::Array,
	Z::Array; 
    surfacecolor::Array = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	colorscale::String = "Jet",
	title::String = "",
	grid::Bool = true,
	showaxis::Bool = true,
)
"""
function plot_surface(
	X::Array,
	Y::Array,
	Z::Array; 
    surfacecolor::Array = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	colorscale::String = "Jet",
	title::String = "",
	grid::Bool = true,
	showaxis::Bool = true,
)
	if isempty(surfacecolor)
		trace = surface(x = X, y = Y, z = Z, colorscale = colorscale)
	else
		trace = surface(x = X, y = Y, z = Z, surfacecolor = surfacecolor, colorscale = colorscale)
	end

	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	layout = Layout(
		title = title,
		scene = attr(
			aspectmode = aspectmode,
			xaxis = attr(title = xlabel, zeroline = false),
			yaxis = attr(title = ylabel, zeroline = false),
			zaxis = attr(title = zlabel, zeroline = false),
		),
		# coloraxis = attr(cmax = maximum(C), cmin = minimum(C)),
	)

	fig = plot(trace, layout)
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		relayout!(fig, scene = attr(
			xaxis = attr(showgrid = false),
			yaxis = attr(showgrid = false),
			zaxis = attr(showgrid = false),
		))
	end
	if !showaxis
		relayout!(fig, scene = attr(
			xaxis = attr(visible = false),
			yaxis = attr(visible = false),
			zaxis = attr(visible = false),
		))
	end
	relayout!(fig, template = :plotly_white)
	return fig
end

"""
function plot_surface(
	Z::Array; surfacecolor::Array = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	colorscale::String = "Jet",
	title::String = "",
	grid::Bool = true,
	showaxis::Bool = true,
)
"""
function plot_surface(
	Z::Array; surfacecolor::Array = [],
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	colorscale::String = "Jet",
	title::String = "",
	grid::Bool = true,
	showaxis::Bool = true,
)
	return plot_surface(
		collect(0:size(Z, 1)-1),
		collect(0:size(Z, 2)-1),
		Z;
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		width = width,
		height = height,
		surfacecolor = surfacecolor,
		xlabel = xlabel,
		ylabel = ylabel,
		zlabel = zlabel,
		aspectmode = aspectmode,
		colorscale = colorscale,
		title = title,
		grid = grid,
		showaxis = showaxis,
	)
end

"""
function plot_scatter3d(
	x::Vector,
	y::Vector,
	z::Vector; xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
)
"""
function plot_scatter3d(
	x::Vector,
	y::Vector,
	z::Vector; xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
)
	if isa(z, Vector) && eltype(z) <: Vector
		modeV = fill("line", length(z))
		colorV = fill("", length(z))
		legendV = fill("", length(z))
		trace = Vector{GenericTrace}(undef, length(z))
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
		if !(legend isa Vector)
			fill!(legendV, legend)
		else
			for n in eachindex(legend)
				legendV[n] = legend[n]
			end
		end
		for n in eachindex(y)
			trace[n] = scatter3d(
				y = y[n],
				x = x[n],
				z = z[n],
				mode = modeV[n],
				line = attr(color = colorV[n]),
				name = legendV[n],
			)
		end
	else
		trace = scatter3d(x = x, y = y, z = z, mode = mode, line = line, name = legend)
	end

	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	layout = Layout(
		title = title,
		scene = attr(
			aspectmode = aspectmode,
			xaxis = attr(title = xlabel, zeroline = false),
			yaxis = attr(title = ylabel, zeroline = false),
			zaxis = attr(title = zlabel, zeroline = false),
		),
	)

	fig = plot(trace, layout)
	if !perspective
		relayout!(fig, scene = attr(camera = attr(projection = attr(type = "orthographic"))))
	end

	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		relayout!(fig, scene = attr(
			xaxis = attr(showgrid = false),
			yaxis = attr(showgrid = false),
			zaxis = attr(showgrid = false),
		))
	end
	if !showaxis
		relayout!(fig, scene = attr(
			xaxis = attr(visible = false),
			yaxis = attr(visible = false),
			zaxis = attr(visible = false),
		))
	end
	relayout!(fig, template = :plotly_white)
	return fig
end

"""
function plot_quiver3d(
	x::Vector,
	y::Vector,
	z::Vector,
	u::Vector,
	v::Vector,
	w::Vector; sizeref::Real = 1,
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	colorscale::String = "Jet", xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
)
"""
function plot_quiver3d(
	x::Vector,
	y::Vector,
	z::Vector,
	u::Vector,
	v::Vector,
	w::Vector; sizeref::Real = 1,
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	colorscale::String = "Jet", xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
)
	trace = cone(
		x = x,
		y = y,
		z = z,
		u = u,
		v = v,
		w = w,
		sizemode = "absolute",
		sizeref = sizeref,
		anchor = "cm",
		colorscale = colorscale,
	)
	if color != "" # use single color
		trace.colorscale = [[0, color], [1, color]]
		trace.showscale = false
	end
	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	layout = Layout(
		title = title,
		scene = attr(
			aspectmode = aspectmode,
			xaxis = attr(title = xlabel, zeroline = false),
			yaxis = attr(title = ylabel, zeroline = false),
			zaxis = attr(title = zlabel, zeroline = false),
		),
	)

	fig = plot(trace, layout)
	if !perspective
		relayout!(fig, scene = attr(camera = attr(projection = attr(type = "orthographic"))))
	end

	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if !all(zrange .== [0, 0])
		update_yaxes!(fig, range = zrange)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	if !grid
		relayout!(fig, scene = attr(
			xaxis = attr(showgrid = false),
			yaxis = attr(showgrid = false),
			zaxis = attr(showgrid = false),
		))
	end
	if !showaxis
		relayout!(fig, scene = attr(
			xaxis = attr(visible = false),
			yaxis = attr(visible = false),
			zaxis = attr(visible = false),
		))
	end
	relayout!(fig, template = :plotly_white)
	return fig
end

#endregion

function tuple_interleave(tu::Union{NTuple{3, Vector}, NTuple{4, Vector}})
	#auxilliary function to interleave elements of a NTuple of vectors, N = 3 or 4
	zipped_data = collect(zip(tu...))
	vv_zdata = [collect(elem) for elem in zipped_data]
	return reduce(vcat, vv_zdata)
end

