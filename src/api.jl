#region 1D Plot

"""
	function plot_scatter(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
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
- `dash`: line style ("dash, "dashdot", or "dot", default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_scatter(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
)
	if isa(y, Vector) && eltype(y) <: Vector
		trace = Vector{GenericTrace}(undef, length(y))
		modeV = fill("line", length(y))
		dashV = fill("", length(y))
		colorV = fill("", length(y))
		legendV = fill("", length(y))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(dash isa Vector)
			fill!(dashV, dash)
		else
			for n in eachindex(dash)
				dashV[n] = dash[n]
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
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
			end
		else
			for n in eachindex(y)
				trace[n] = scatter(
					y = y[n],
					x = x,
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
			end
		end
	else
		trace = scatter(y = y, x = x, mode = mode, line = attr(color = color, dash = dash), name = legend)
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return fig
end

"""
	function plot_scatter(
		y::Union{AbstractRange, Vector, SubArray}; 
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
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
- `dash`: line style ("dash, "dashdot", or "dot", default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: legend of the plot lines (default: `""`, can be vector)
- `title`: Title of thje figure (default: `""`)
- `grid`: Whether to show the grid or not (default: true)
- `grid`: Whether to show the grid or not (default: true)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_scatter(
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
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
		dash = dash,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
	)
end

"""
	function plot_stem(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Plots a rectangular stem plot.

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
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_stem(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
)
	if isa(y, Vector) && eltype(y) <: Vector
		trace = Vector{GenericTrace}(undef, length(y))
		colorV = fill("", length(y))
		legendV = fill("", length(y))

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
				# trace[n] = stem(
				# 	y = y[n],
				# 	x = x[n],
				# 	line = attr(color = colorV[n]),
				# 	name = legendV[n],
				# )
				trace[n] = scatter(
					y = y[n],
					x = x[n],
					line = attr(color = colorV[n]),
					name = legendV[n],
					mode = "markers",
				)
			end
		else
			for n in eachindex(y)
				# trace[n] = stem(
				# 	y = y[n],
				# 	x = x,
				# 	line = attr(color = colorV[n]),
				# 	name = legendV[n],
				# )
				trace[n] = scatter(
					y = y[n],
					x = x,
					line = attr(color = colorV[n]),
					name = legendV[n],
					mode = "markers",
				)
			end
		end
	else
		# trace = stem(y = y, x = x, line = attr(color = color), name = legend)
		trace = scatter(y = y, x = x, line = attr(color = color), name = legend, mode = "markers")
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end

	#exp
	if isa(y, Vector) && eltype(y) <: Vector
		if isa(x, Vector) && eltype(x) <: Vector
			for n in eachindex(y)
				for m in eachindex(y[n])
					# add_shape!(fig, line(
					# 	x0 = x[n][m], y0 = 0,
					# 	x1 = x[n][m], y1 = y[n][m],
					# 	line = attr(color = "black", width = 0.5),
					# )
					# )
					addtraces!(fig,
						scatter(
							x = [x[n][m], x[n][m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(color = "black", width = 0.5),
							showlegend = false,
						),
					)
				end
			end
		else
			for n in eachindex(y)
				for m in eachindex(y[n])
					# add_shape!(fig, line(
					# 	x0 = x[m], y0 = 0,
					# 	x1 = x[m], y1 = y[n][m],
					# 	line = attr(color = "black", width = 0.5),
					# )
					# )
					addtraces!(fig,
						scatter(
							x = [x[m], x[m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(color = "black", width = 0.5),
							showlegend = false,
						),
					)
				end
			end
		end
	else
		for m in eachindex(y)
			# add_shape!(fig, line(
			# 	x0 = x[m], y0 = 0,
			# 	x1 = x[m], y1 = y[m],
			# 	line = attr(color = "black", width = 0.5),
			# )
			# )
			addtraces!(fig,
				scatter(
					x = [x[m], x[m]],
					y = [0, y[m]],
					mode = "lines",
					line = attr(color = "black", width = 0.5),
					showlegend = false,
				),
			)
		end
	end
	return fig
end

"""
	function plot_stem(
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Plots a rectangular stem plot (x-axis not specified).

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
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_stem(
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
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

	return plot_stem(
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
	)
end

"""
	function plot_scatterpolar(
		theta::Union{AbstractRange, Vector, SubArray},
		r::Union{AbstractRange, Vector, SubArray};
		trange::Vector = [0, 0],
		rrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
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
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_scatterpolar(
	theta::Union{AbstractRange, Vector, SubArray},
	r::Union{AbstractRange, Vector, SubArray};
	trange::Vector = [0, 0],
	rrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
)
	if isa(r, Vector) && eltype(r) <: Vector
		trace = Vector{GenericTrace}(undef, length(r))
		modeV = fill("line", length(r))
		dashV = fill("", length(r))
		colorV = fill("", length(r))
		legendV = fill("", length(r))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(dash isa Vector)
			fill!(dashV, dash)
		else
			for n in eachindex(dash)
				dashV[n] = dash[n]
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
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
			end
		else
			for n in eachindex(r)
				trace[n] = scatterpolar(
					r = r[n],
					theta = theta,
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
			end
		end
	else
		trace = scatterpolar(
			r = r,
			theta = theta,
			mode = mode,
			line = attr(color = color, dash = dash),
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return fig
end

#endregion

#region 2D Plot

"""
	function plot_heatmap(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
	)

Plots heatmap (holographic) data.

#### Arguments

- 'x::AbstractRange': x-axis range
- 'y::AbstractRange': x-axis range
- `U`: 2D hologram data

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the heatmap (default: `""`)
- `title`: Title of thje figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- 'equalar': Whether to set equal aspect ratio (default: false)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_heatmap(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
)
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
		# margin = attr(r = 0, b = 0, t = 0, l = 0),
	)
	fig = plot(trace, layout)
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if equalar
		update_xaxes!(fig,
		scaleanchor = "y",
		scaleratio = 1,
	)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	
	relayout!(fig, template = :plotly_white)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return fig
end

"""
	function plot_heatmap(
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
	)

Plots heatmap (holographic) data (axes not specified).

#### Arguments

- `U`: 2D hologram data

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the heatmap (default: `""`)
- `title`: Title of thje figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- 'equalar': Whether to set equal aspect ratio (default: false)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_heatmap(
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_heatmap(x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		width = width,
		height = height,
		equalar = equalar,
	)
end


"""
	function plot_contour(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
	)

Plots contour data.

#### Arguments

- 'x::AbstractRange': x-axis range
- 'y::AbstractRange': x-axis range
- `U`: 2D data for contours

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the contour plot (default: `""`)
- `title`: Title of thje figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- 'equalar': Whether to set equal aspect ratio (default: false)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_contour(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = contour(x = x, y = y, z = FV, colorscale = colorscale)
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
		# margin = attr(r = 0, b = 0, t = 0, l = 0),
	)
	fig = plot(trace, layout)
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if equalar
		update_xaxes!(fig,
		scaleanchor = "y",
		scaleratio = 1,
	)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	
	relayout!(fig, template = :plotly_white)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return fig
end

"""
	function plot_contour(
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
	)

Plots contour data (axes not specified).

#### Arguments

- `U`: 2D data for contours

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `colorscale`: Color scale for the contour plot (default: `""`)
- `title`: Title of thje figure (default: `""`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- 'equalar': Whether to set equal aspect ratio (default: false)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_contour(
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_contour(x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		width = width,
		height = height,
		equalar = equalar,
	)
end


"""
	function plot_quiver(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		u::Union{AbstractRange, Vector, SubArray},
		v::Union{AbstractRange, Vector, SubArray};
		color::String = "RoyalBlue",
		sizeref::Real = 1,
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Plots a 2D quiver (vector field) diagram using arrow segments.

#### Arguments

- `x`: x-coordinates of vector origins
- `y`: y-coordinates of vector origins
- `u`: x-components of vector directions
- `v`: y-components of vector directions

#### Keywords

- `color`: Arrow color (default: `"RoyalBlue"`)
- `sizeref`: Reference scaling for arrow length (default: `1`)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to show the grid or not (default: `true`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
"""
function plot_quiver(
    x::Union{AbstractRange, Vector, SubArray},
    y::Union{AbstractRange, Vector, SubArray},
    u::Union{AbstractRange, Vector, SubArray},
    v::Union{AbstractRange, Vector, SubArray};
    color::String = "RoyalBlue",
    sizeref::Real = 1,
    xlabel::String = "",
    ylabel::String = "",
    xrange::Vector = [0, 0],
    yrange::Vector = [0, 0],
    width::Int = 0,
    height::Int = 0,
    title::String = "",
    fontsize::Int = 0,
    grid::Bool = true,
)
    x_vec = isa(x, AbstractRange) ? collect(x) : x
    y_vec = isa(y, AbstractRange) ? collect(y) : y
    u_vec = isa(u, AbstractRange) ? collect(u) : u
    v_vec = isa(v, AbstractRange) ? collect(v) : v

    p_max = maximum(sqrt.(u_vec .^ 2 .+ v_vec .^ 2))
    u_ref = u_vec ./ p_max .* sizeref
    v_ref = v_vec ./ p_max .* sizeref
    end_x = x_vec .+ u_ref .* 2 / 3
    end_y = y_vec .+ v_ref .* 2 / 3

    vect_nans = repeat([NaN], length(x_vec))

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
    arrow_x = _tuple_interleave((collect(arrowend1_x), collect(end_x), collect(arrowend2_x), collect(vect_nans)))
    arrow_y = _tuple_interleave((collect(arrowend1_y), collect(end_y), collect(arrowend2_y), collect(vect_nans)))

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
        # margin = attr(r = 0, b = 0, t = 0, l = 0),
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
    if fontsize > 0
        relayout!(fig, font = attr(size = fontsize))
    end
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
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Plots a 3D surface using x, y, z coordinate grids.

#### Arguments

- `X`: Grid of x-coordinates
- `Y`: Grid of y-coordinates
- `Z`: Grid of z-values defining the surface height

#### Keywords

- `surfacecolor`: Color values for each surface point (default: `[]`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `xlabel`: Label for the x-axis (default: `"x"`)
- `ylabel`: Label for the y-axis (default: `"y"`)
- `zlabel`: Label for the z-axis (default: `"z"`)
- `aspectmode`: Aspect mode setting (default: `"auto"`)
- `colorscale`: Color scale for the surface (default: `""`)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to display grid lines (default: `true`)
- `showaxis`: Whether to show axis lines and labels (default: `true`)
- `shared_coloraxis`: If `true`, uses a shared coloraxis (single colorbar) for multiple surfaces (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
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
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	showaxis::Bool = true,
	shared_coloraxis::Bool = false,
)
	if isempty(surfacecolor)
		trace = surface(x = X, y = Y, z = Z, colorscale = colorscale)
	else
		trace = surface(x = X, y = Y, z = Z, surfacecolor = surfacecolor, colorscale = colorscale)
	end
	if shared_coloraxis
		trace.coloraxis = "coloraxis"
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
	if shared_coloraxis
		if colorscale == ""
			relayout!(fig, coloraxis = attr())
		else
			relayout!(fig, coloraxis = attr(colorscale = colorscale))
		end
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return fig
end

"""
	plot_surface(
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
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Plots a 3D surface given a matrix of height values `Z`, using the array indices as x and y coordinates.

# Arguments
- `Z::Array`: 2D array representing surface height. The dimensions of `Z` define the surface grid, with x and y coordinates automatically generated as `0:size(Z, 1)-1` and `0:size(Z, 2)-1`.

# Keyword Arguments
- `surfacecolor::Array`: Optional array for surface coloring. If empty, `Z` is used for coloring.
- `xrange::Vector`: `[xmin, xmax]` range for the x-axis. `[0, 0]` disables manual range.
- `yrange::Vector`: `[ymin, ymax]` range for the y-axis.
- `zrange::Vector`: `[zmin, zmax]` range for the z-axis.
- `width::Int`: Width of the figure in pixels. `0` uses default.
- `height::Int`: Height of the figure in pixels. `0` uses default.
- `xlabel::String`: Label for x-axis (defaults to `"x"` if empty).
- `ylabel::String`: Label for y-axis (defaults to `"y"` if empty).
- `zlabel::String`: Label for z-axis (defaults to `"z"` if empty).
- `aspectmode::String`: 3D scene aspect mode (`"auto"`, `"cube"`, `"data"`).
- `colorscale::String`: Colorscale name (e.g., `""`, `"Viridis"`).
- `title::String`: Plot title.
- `grid::Bool`: If `false`, disables grid lines.
- `showaxis::Bool`: If `false`, hides all axes.
- `shared_coloraxis::Bool`: If `true`, uses a shared coloraxis (single colorbar) for multiple surfaces.
- `fontsize::Int`: Font size for plot text (default: `0`, uses Plotly default).

# Returns
- A `Plot` object rendered using PlotlyJS.

# Notes
- This function is a convenience wrapper for `plot_surface(X, Y, Z; ...)`, where `X` and `Y` are index grids derived from the shape of `Z`.
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
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	showaxis::Bool = true,
	shared_coloraxis::Bool = false,
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
		fontsize = fontsize,
		grid = grid,
		showaxis = showaxis,
		shared_coloraxis = shared_coloraxis,
	)
end

"""
	plot_scatter3d(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		z::Union{AbstractRange, Vector, SubArray};
		xrange::Vector = [0, 0],
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
		fontsize::Int = 0,
		perspective::Bool = true,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Plots a 3D scatter or line plot using `PlotlyJS`, with options for customizing appearance and handling multiple curves.

# Arguments
- `x`, `y`, `z`: Coordinate vectors. If `z` is a `Vector{Vector}` (i.e., multiple datasets), `x` and `y` must also be `Vector{Vector}` of the same length.

# Keyword Arguments
- `xrange`, `yrange`, `zrange`: Axis limits in the form `[min, max]`. If `[0, 0]`, auto-scaling is used.
- `width`, `height`: Plot dimensions in pixels.
- `mode`: Drawing mode (`"lines"`, `"markers"`, `"lines+markers"`). Can be a vector for multiple traces.
- `color`: Line color(s). Can be a single string or a vector of strings for multiple traces.
- `legend`: Trace label(s) for the legend. Can be a string or a vector.
- `xlabel`, `ylabel`, `zlabel`: Axis labels. Defaults are `"x"`, `"y"`, and `"z"`.
- `aspectmode`: Aspect mode for 3D view. Options include `"auto"`, `"cube"`, and `"data"`.
- `title`: Title of the plot.
- `perspective`: If `false`, uses orthographic projection. Defaults to perspective projection.
- `grid`: Whether to show grid lines.
- `showaxis`: Whether to show axis lines and labels.
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default).

# Returns
- A `Plot` object containing the 3D scatter or line plot.

# Notes
- This function supports plotting multiple lines by passing `Vector{Vector}` types to `x`, `y`, and `z`. In this case, corresponding vectors of `mode`, `color`, and `legend` will be used.
"""
function plot_scatter3d(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray}; 
	xrange::Vector = [0, 0],
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
	fontsize::Int = 0,
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
)
	if isa(z, Vector) && eltype(z) <: Vector
		modeV = fill("lines", length(z))
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
		trace = scatter3d(x = x, y = y, z = z, mode = mode, line = attr(color = color), name = legend)
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return fig
end

"""
	plot_quiver3d(
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		z::Union{AbstractRange, Vector, SubArray},
		u::Union{AbstractRange, Vector, SubArray},
		v::Union{AbstractRange, Vector, SubArray},
		w::Union{AbstractRange, Vector, SubArray};
		sizeref::Real = 1,
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		colorscale::String = "",
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		title::String = "",
		fontsize::Int = 0,
		perspective::Bool = true,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Generates a 3D vector field (quiver plot) using cones via `PlotlyJS`.

# Arguments
- `x`, `y`, `z`: Coordinates of vector origins.
- `u`, `v`, `w`: Components of the vector field at the corresponding positions.

# Keyword Arguments
- `sizeref`: Scaling factor for cone size (default: 1).
- `xrange`, `yrange`, `zrange`: Axis limits in the form `[min, max]`. If `[0, 0]`, auto-scaling is used.
- `width`, `height`: Dimensions of the figure in pixels.
- `color`: If specified, sets a uniform color for all vectors.
- `colorscale`: Name of the Plotly colorscale to use when `color` is not specified (default: `""`).
- `xlabel`, `ylabel`, `zlabel`: Labels for x, y, z axes.
- `aspectmode`: Aspect mode for 3D rendering. Options include `"auto"`, `"cube"`, `"data"`.
- `title`: Title of the plot.
- `perspective`: If `false`, uses orthographic projection. Defaults to perspective view.
- `grid`: Controls visibility of grid lines.
- `showaxis`: Controls visibility of axis lines and labels.
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default).

# Returns
- A `Plot` object containing the 3D quiver plot.

# Notes
- By default, the vector field is visualized using cones with magnitude scaling via `sizeref`.
- If `color` is specified, all cones are displayed in a uniform color without a color bar.
"""
function plot_quiver3d(
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray},
	w::Union{AbstractRange, Vector, SubArray}; 
	sizeref::Real = 1,
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	colorscale::String = "", xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	fontsize::Int = 0,
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	return fig
end

#endregion

#region Mutating Functions

"""
	function plot_scatter!(
		fig::PlotlyJS.SyncPlot,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Adds new scatter traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
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
- `dash`: line style (default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)

"""
function plot_scatter!(
	fig::PlotlyJS.SyncPlot,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
)
	if isa(y, Vector) && eltype(y) <: Vector
		modeV = fill("line", length(y))
		dashV = fill("", length(y))
		colorV = fill("", length(y))
		legendV = fill("", length(y))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(dash isa Vector)
			fill!(dashV, dash)
		else
			for n in eachindex(dash)
				dashV[n] = dash[n]
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
				trace = scatter(
					y = y[n],
					x = x[n],
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
				push!(fig.plot.data, trace)
			end
		else
			for n in eachindex(y)
				trace = scatter(
					y = y[n],
					x = x,
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
				push!(fig.plot.data, trace)
			end
		end
	else
		trace = scatter(y = y, x = x, mode = mode, line = attr(color = color, dash = dash), name = legend)
		push!(fig.plot.data, trace)
	end
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title_text = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title_text = ylabel))
	end
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

"""
	function plot_scatter!(
		fig::PlotlyJS.SyncPlot,
		y::Union{AbstractRange, Vector, SubArray}; 
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Adds new scatter traces to an existing figure (x-axis not specified, uses indices).

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `dash`: line style (default: `""`, can be vector)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)

"""
function plot_scatter!(
	fig::PlotlyJS.SyncPlot,
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
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

	return plot_scatter!(
		fig,
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		mode = mode,
		dash = dash,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
	)
end

"""
	function plot_stem!(
		fig::PlotlyJS.SyncPlot,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Adds new stem plot traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `x`: x-coordinate data (can be vector of vectors)
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)

"""
function plot_stem!(
	fig::PlotlyJS.SyncPlot,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
)
	if isa(y, Vector) && eltype(y) <: Vector
		colorV = fill("", length(y))
		legendV = fill("", length(y))

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
				trace_stem = scatter(
					y = y[n],
					x = x[n],
					line = attr(color = colorV[n]),
					name = legendV[n],
					mode = "markers",
				)
				push!(fig.plot.data, trace_stem)
			end
			for n in eachindex(y)
				for m in eachindex(y[n])
					push!(fig.plot.data,
						scatter(
							x = [x[n][m], x[n][m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(color = "black", width = 0.5),
							showlegend = false,
						),
					)
				end
			end
		else
			for n in eachindex(y)
				trace_stem = scatter(
					y = y[n],
					x = x,
					line = attr(color = colorV[n]),
					name = legendV[n],
					mode = "markers",
				)
				push!(fig.plot.data, trace_stem)
			end
			for n in eachindex(y)
				for m in eachindex(y[n])
					push!(fig.plot.data,
						scatter(
							x = [x[m], x[m]],
							y = [0, y[n][m]],
							mode = "lines",
							line = attr(color = "black", width = 0.5),
							showlegend = false,
						),
					)
				end
			end
		end
	else
		trace_stem = scatter(y = y, x = x, line = attr(color = color), name = legend, mode = "markers")
		push!(fig.plot.data, trace_stem)
		for m in eachindex(y)
			push!(fig.plot.data,
				scatter(
					x = [x[m], x[m]],
					y = [0, y[m]],
					mode = "lines",
					line = attr(color = "black", width = 0.5),
					showlegend = false,
				),
			)
		end
	end
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title_text = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title_text = ylabel))
	end
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

"""
	function plot_stem!(
		fig::PlotlyJS.SyncPlot,
		y::Union{AbstractRange, Vector, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Adds new stem plot traces to an existing figure (x-axis not specified, uses indices).

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `y`: y-coordinate data (can be vector of vectors)

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `color`: Color of the plot lines (default: `""`, can be vector)
- `legend`: Name of the plot lines (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)

"""
function plot_stem!(
	fig::PlotlyJS.SyncPlot,
	y::Union{AbstractRange, Vector, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
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

	return plot_stem!(
		fig,
		x,
		y;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		width = width,
		height = height,
		color = color,
		legend = legend,
		title = title,
		fontsize = fontsize,
		grid = grid,
	)
end

"""
	function plot_scatterpolar!(
		fig::PlotlyJS.SyncPlot,
		theta::Union{AbstractRange, Vector, SubArray},
		r::Union{AbstractRange, Vector, SubArray};
		trange::Vector = [0, 0],
		rrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		mode::Union{String, Vector{String}} = "lines",
		dash::Union{String, Vector{String}} = "",
		color::Union{String, Vector{String}} = "",
		legend::Union{String, Vector{String}} = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Adds new polar scatter traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `theta`: Angular coordinates
- `r`: Radial coordinates

#### Keywords

- `trange`: Range for the angular axis (default: `[0, 0]`)
- `rrange`: Range for the radial axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `dash`: line style (default: `""`, can be vector)
- `color`: Color of the plot (default: `""`, can be vector)
- `legend`: Legend name (default: `""`, can be vector)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)

"""
function plot_scatterpolar!(
	fig::PlotlyJS.SyncPlot,
	theta::Union{AbstractRange, Vector, SubArray},
	r::Union{AbstractRange, Vector, SubArray};
	trange::Vector = [0, 0],
	rrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	mode::Union{String, Vector{String}} = "lines",
	dash::Union{String, Vector{String}} = "",
	color::Union{String, Vector{String}} = "",
	legend::Union{String, Vector{String}} = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
)
	if isa(r, Vector) && eltype(r) <: Vector
		modeV = fill("line", length(r))
		dashV = fill("", length(r))
		colorV = fill("", length(r))
		legendV = fill("", length(r))

		if !(mode isa Vector)
			fill!(modeV, mode)
		else
			for n in eachindex(mode)
				modeV[n] = mode[n]
			end
		end
		if !(dash isa Vector)
			fill!(dashV, dash)
		else
			for n in eachindex(dash)
				dashV[n] = dash[n]
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
				trace = scatterpolar(
					r = r[n],
					theta = theta[n],
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
				push!(fig.plot.data, trace)
			end
		else
			for n in eachindex(r)
				trace = scatterpolar(
					r = r[n],
					theta = theta,
					mode = modeV[n],
					line = attr(color = colorV[n], dash = dashV[n]),
					name = legendV[n],
				)
				push!(fig.plot.data, trace)
			end
		end
	else
		trace = scatterpolar(
			r = r,
			theta = theta,
			mode = mode,
			line = attr(color = color, dash = dash),
			name = legend,
		)
		push!(fig.plot.data, trace)
	end
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if isa(theta, Vector) && eltype(theta) <: Vector
		min_theta = minimum(map(minimum, theta))
		max_theta = maximum(map(maximum, theta))
		relayout!(fig, polar = attr(sector = [min_theta, max_theta]))
	else
		relayout!(fig, polar = attr(sector = [minimum(theta), maximum(theta)]))
	end
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

"""
	function plot_heatmap!(
		fig::PlotlyJS.SyncPlot,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
	)

Adds new heatmap traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `x`: x-coordinate values
- `y`: y-coordinate values
- `U`: Matrix of values

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `colorscale`: Color scale for the heatmap (default: `""`)
- `title`: Title for the heatmap (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `equalar`: Whether to set equal aspect ratio (default: `false`)

"""
function plot_heatmap!(
	fig::PlotlyJS.SyncPlot,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = heatmap(x = x, y = y, z = FV, colorscale = colorscale)
	if !all(zrange .== [0, 0])
		trace.zmin = zrange[1]
		trace.zmax = zrange[2]
	end
	push!(fig.plot.data, trace)
	# apply optional layout updates if labels or title provided
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title = ylabel))
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if equalar
		update_xaxes!(fig,
			scaleanchor = "y",
			scaleratio = 1,
		)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	relayout!(fig, template = :plotly_white)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

function plot_heatmap!(
	fig::PlotlyJS.SyncPlot,
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_heatmap!(fig, x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		width = width,
		height = height,
		equalar = equalar,
	)
end

"""
	function plot_contour!(
		fig::PlotlyJS.SyncPlot,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		U::Union{Array, SubArray};
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		equalar::Bool = false,
	)

Adds new contour traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `x`: x-coordinate values
- `y`: y-coordinate values
- `U`: Matrix of values

#### Keywords

- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the plot (default: `0`)
- `height`: Height of the plot (default: `0`)
- `colorscale`: Color scale for the contour plot (default: `""`)
- `title`: Title for the contour (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `equalar`: Whether to set equal aspect ratio (default: `false`)

"""
function plot_contour!(
	fig::PlotlyJS.SyncPlot,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
)
	FV = @view U[:, :]
	FV = transpose(FV) # IMPORTANT! THIS FOLLOWS THE CONVENTION OF meshgrid(y,x)
	trace = contour(x = x, y = y, z = FV, colorscale = colorscale)
	if !all(zrange .== [0, 0])
		trace.zmin = zrange[1]
		trace.zmax = zrange[2]
	end
	push!(fig.plot.data, trace)
	# apply optional layout updates if labels or title provided
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title = ylabel))
	end
	if !all(xrange .== [0, 0])
		update_xaxes!(fig, range = xrange)
	end
	if !all(yrange .== [0, 0])
		update_yaxes!(fig, range = yrange)
	end
	if equalar
		update_xaxes!(fig,
			scaleanchor = "y",
			scaleratio = 1,
		)
	end
	if width > 0
		relayout!(fig, width = width)
	end
	if height > 0
		relayout!(fig, height = height)
	end
	relayout!(fig, template = :plotly_white)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

function plot_contour!(
	fig::PlotlyJS.SyncPlot,
	U::Union{Array, SubArray};
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	equalar::Bool = false,
)
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_contour!(fig, x, y, U;
		xlabel = xlabel,
		ylabel = ylabel,
		xrange = xrange,
		yrange = yrange,
		zrange = zrange,
		colorscale = colorscale,
		title = title,
		fontsize = fontsize,
		width = width,
		height = height,
		equalar = equalar,
	)
end

"""
	function plot_quiver!(
		fig::PlotlyJS.SyncPlot,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		u::Union{AbstractRange, Vector, SubArray},
		v::Union{AbstractRange, Vector, SubArray};
		color::String = "RoyalBlue",
		sizeref::Real = 1,
		xlabel::String = "",
		ylabel::String = "",
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
	)

Adds new quiver plot traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `x`: x-coordinate values
- `y`: y-coordinate values
- `u`: x-component of vector field
- `v`: y-component of vector field

#### Keywords

- `color`: Color of the arrows (default: `"RoyalBlue"`)
- `sizeref`: Reference scaling for arrow length (default: `1`)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `title`: Title of the figure (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `grid`: Whether to show the grid or not (default: `true`)

"""
function plot_quiver!(
	fig::PlotlyJS.SyncPlot,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray};
	color::String = "RoyalBlue",
	sizeref::Real = 1,
	xlabel::String = "",
	ylabel::String = "",
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
)
	x_vec = isa(x, AbstractRange) ? collect(x) : x
	y_vec = isa(y, AbstractRange) ? collect(y) : y
	u_vec = isa(u, AbstractRange) ? collect(u) : u
	v_vec = isa(v, AbstractRange) ? collect(v) : v

	p_max = maximum(sqrt.(u_vec .^ 2 .+ v_vec .^ 2))
	u_ref = u_vec ./ p_max .* sizeref
	v_ref = v_vec ./ p_max .* sizeref
	end_x = x_vec .+ u_ref .* 2 / 3
	end_y = y_vec .+ v_ref .* 2 / 3

	vect_nans = repeat([NaN], length(x_vec))

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
	arrow_x = _tuple_interleave((collect(arrowend1_x), collect(end_x), collect(arrowend2_x), collect(vect_nans)))
	arrow_y = _tuple_interleave((collect(arrowend1_y), collect(end_y), collect(arrowend2_y), collect(vect_nans)))

	arrow = scatter(x = arrow_x, y = arrow_y, mode = "lines", line_color = color,
		fill = "toself", fillcolor = color, hoverinfo = "skip")
	push!(fig.plot.data, arrow)
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
	if xlabel != ""
		relayout!(fig, xaxis = attr(title = xlabel))
	end
	if ylabel != ""
		relayout!(fig, yaxis = attr(title = ylabel))
	end
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
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

"""
	function plot_surface!(
		fig::PlotlyJS.SyncPlot,
		X::Matrix,
		Y::Matrix,
		Z::Matrix;
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
		colorscale::String = "",
		title::String = "",
		fontsize::Int = 0,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Adds new surface traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `X`: X-coordinates
- `Y`: Y-coordinates
- `Z`: Z-coordinates

#### Keywords

- `surfacecolor`: Color values for each surface point (default: `[]`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `zlabel`: Label for the z-axis (default: `""`)
- `aspectmode`: Aspect mode setting (default: `"auto"`)
- `colorscale`: Color scale for the surface (default: `""`)
- `title`: Title of the figure (default: `""`)
- `grid`: Whether to display grid lines (default: `true`)
- `showaxis`: Whether to show axis lines and labels (default: `true`)
- `shared_coloraxis`: If `true`, uses a shared coloraxis (single colorbar) for multiple surfaces (default: `false`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)

"""
function plot_surface!(
	fig::PlotlyJS.SyncPlot,
	X::Matrix,
	Y::Matrix,
	Z::Matrix;
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
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	showaxis::Bool = true,
	shared_coloraxis::Bool = false,
	color::Array = [],  # Alias for surfacecolor for backward compatibility
)
	# Handle color parameter as alias for surfacecolor
	if !isempty(color)
		surfacecolor = color
	end
	
	if isempty(surfacecolor)
		trace = surface(x = X, y = Y, z = Z, colorscale = colorscale)
	else
		trace = surface(x = X, y = Y, z = Z, surfacecolor = surfacecolor, colorscale = colorscale)
	end
	if shared_coloraxis
		trace.coloraxis = "coloraxis"
	end
	push!(fig.plot.data, trace)

	if shared_coloraxis
		for tr in fig.plot.data
			if get(tr, :type, "") == "surface"
				tr.coloraxis = "coloraxis"
			end
		end
		if colorscale == ""
			relayout!(fig, coloraxis = attr())
		else
			relayout!(fig, coloraxis = attr(colorscale = colorscale))
		end
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
	xaxis_attr = attr(title = xlabel, zeroline = false)
	yaxis_attr = attr(title = ylabel, zeroline = false)
	zaxis_attr = attr(title = zlabel, zeroline = false)
	if !grid
		xaxis_attr = merge(xaxis_attr, attr(showgrid = false))
		yaxis_attr = merge(yaxis_attr, attr(showgrid = false))
		zaxis_attr = merge(zaxis_attr, attr(showgrid = false))
	end
	if !showaxis
		xaxis_attr = merge(xaxis_attr, attr(visible = false))
		yaxis_attr = merge(yaxis_attr, attr(visible = false))
		zaxis_attr = merge(zaxis_attr, attr(visible = false))
	end
	scene_attr = attr(
		aspectmode = aspectmode,
		xaxis = xaxis_attr,
		yaxis = yaxis_attr,
		zaxis = zaxis_attr,
	)
	relayout!(fig, scene = scene_attr)
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
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
	relayout!(fig, template = :plotly_white)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

function plot_surface!(
	fig::PlotlyJS.SyncPlot,
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
	colorscale::String = "",
	title::String = "",
	fontsize::Int = 0,
	grid::Bool = true,
	showaxis::Bool = true,
	shared_coloraxis::Bool = false,
	color::Array = [],  # Alias for surfacecolor for backward compatibility
)
	return plot_surface!(
		fig,
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
		fontsize = fontsize,
		grid = grid,
		showaxis = showaxis,
		shared_coloraxis = shared_coloraxis,
		color = color,
	)
end

"""
	function plot_scatter3d!(
		fig::PlotlyJS.SyncPlot,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		z::Union{AbstractRange, Vector, SubArray};
		xrange::Vector = [0, 0],
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
		fontsize::Int = 0,
		perspective::Bool = true,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Adds new 3D scatter traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `x`: x-coordinate data (can be vector of vectors)
- `y`: y-coordinate data (can be vector of vectors)
- `z`: z-coordinate data (can be vector of vectors)

#### Keywords

- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `mode`: Plotting mode (default: `"lines"`, can be vector)
- `color`: Color of the plot (default: `""`, can be vector)
- `legend`: Legend name (default: `""`, can be vector)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `zlabel`: Label for the z-axis (default: `""`)
- `aspectmode`: Aspect mode for 3D view (default: `"auto"`)
- `title`: Title of the plot (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `perspective`: If `false`, uses orthographic projection (default: `true`)
- `grid`: Whether to show grid lines (default: `true`)
- `showaxis`: Whether to show axis lines and labels (default: `true`)

"""
function plot_scatter3d!(
	fig::PlotlyJS.SyncPlot,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray};
	xrange::Vector = [0, 0],
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
	fontsize::Int = 0,
	perspective::Bool = true,
	grid::Bool = true,
	showaxis::Bool = true,
)
	if isa(z, Vector) && eltype(z) <: Vector
		modeV = fill("lines", length(z))
		colorV = fill("", length(z))
		legendV = fill("", length(z))

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

		for n in eachindex(z)
			trace = scatter3d(
				y = y[n],
				x = x[n],
				z = z[n],
				mode = modeV[n],
				line = attr(color = colorV[n]),
				name = legendV[n],
			)
			push!(fig.plot.data, trace)
		end
	else
		trace = scatter3d(
			x = x,
			y = y,
			z = z,
			mode = mode,
			line = attr(color = color),
			name = legend,
		)
		push!(fig.plot.data, trace)
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
	xaxis_attr = attr(title = xlabel, zeroline = false)
	yaxis_attr = attr(title = ylabel, zeroline = false)
	zaxis_attr = attr(title = zlabel, zeroline = false)
	if !grid
		xaxis_attr = merge(xaxis_attr, attr(showgrid = false))
		yaxis_attr = merge(yaxis_attr, attr(showgrid = false))
		zaxis_attr = merge(zaxis_attr, attr(showgrid = false))
	end
	if !showaxis
		xaxis_attr = merge(xaxis_attr, attr(visible = false))
		yaxis_attr = merge(yaxis_attr, attr(visible = false))
		zaxis_attr = merge(zaxis_attr, attr(visible = false))
	end
	relayout!(fig, scene = attr(
		aspectmode = aspectmode,
		xaxis = xaxis_attr,
		yaxis = yaxis_attr,
		zaxis = zaxis_attr,
	))
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
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
	relayout!(fig, template = :plotly_white)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

"""
	function plot_quiver3d!(
		fig::PlotlyJS.SyncPlot,
		x::Union{AbstractRange, Vector, SubArray},
		y::Union{AbstractRange, Vector, SubArray},
		z::Union{AbstractRange, Vector, SubArray},
		u::Union{AbstractRange, Vector, SubArray},
		v::Union{AbstractRange, Vector, SubArray},
		w::Union{AbstractRange, Vector, SubArray};
		sizeref::Real = 1,
		xrange::Vector = [0, 0],
		yrange::Vector = [0, 0],
		zrange::Vector = [0, 0],
		width::Int = 0,
		height::Int = 0,
		color::String = "",
		colorscale::String = "",
		xlabel::String = "",
		ylabel::String = "",
		zlabel::String = "",
		aspectmode::String = "auto",
		title::String = "",
		fontsize::Int = 0,
		perspective::Bool = true,
		grid::Bool = true,
		showaxis::Bool = true,
	)

Adds new 3D quiver plot traces to an existing figure.

#### Arguments

- `fig`: Existing `PlotlyJS.SyncPlot` to append to
- `x`: x-coordinate values
- `y`: y-coordinate values
- `z`: z-coordinate values
- `u`: x-component of vector field
- `v`: y-component of vector field
- `w`: z-component of vector field

#### Keywords

- `sizeref`: Reference scaling for arrow length (default: `1`)
- `xrange`: Range for the x-axis (default: `[0, 0]`)
- `yrange`: Range for the y-axis (default: `[0, 0]`)
- `zrange`: Range for the z-axis (default: `[0, 0]`)
- `width`: Width of the figure in pixels (default: `0`)
- `height`: Height of the figure in pixels (default: `0`)
- `color`: Color of the arrows (default: `""`)
- `colorscale`: Colorscale for magnitude visualization (default: `""`)
- `xlabel`: Label for the x-axis (default: `""`)
- `ylabel`: Label for the y-axis (default: `""`)
- `zlabel`: Label for the z-axis (default: `""`)
- `aspectmode`: Aspect mode for 3D view (default: `"auto"`)
- `title`: Title of the plot (default: `""`)
- `fontsize`: Font size for plot text (default: `0`, uses Plotly default)
- `perspective`: If `false`, uses orthographic projection (default: `true`)
- `grid`: Whether to show grid lines (default: `true`)
- `showaxis`: Whether to show axis lines and labels (default: `true`)

"""
function plot_quiver3d!(
	fig::PlotlyJS.SyncPlot,
	x::Union{AbstractRange, Vector, SubArray},
	y::Union{AbstractRange, Vector, SubArray},
	z::Union{AbstractRange, Vector, SubArray},
	u::Union{AbstractRange, Vector, SubArray},
	v::Union{AbstractRange, Vector, SubArray},
	w::Union{AbstractRange, Vector, SubArray};
	sizeref::Real = 1,
	xrange::Vector = [0, 0],
	yrange::Vector = [0, 0],
	zrange::Vector = [0, 0],
	width::Int = 0,
	height::Int = 0,
	color::String = "",
	colorscale::String = "",
	xlabel::String = "",
	ylabel::String = "",
	zlabel::String = "",
	aspectmode::String = "auto",
	title::String = "",
	fontsize::Int = 0,
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
	# if a single color is requested, force a uniform colorscale and hide colorbar
	if color != ""
		trace.colorscale = [[0, color], [1, color]]
		trace.showscale = false
	end
	push!(fig.plot.data, trace)
	if xlabel == ""
		xlabel = "x"
	end
	if ylabel == ""
		ylabel = "y"
	end
	if zlabel == ""
		zlabel = "z"
	end
	xaxis_attr = attr(title = xlabel, zeroline = false)
	yaxis_attr = attr(title = ylabel, zeroline = false)
	zaxis_attr = attr(title = zlabel, zeroline = false)
	if !grid
		xaxis_attr = merge(xaxis_attr, attr(showgrid = false))
		yaxis_attr = merge(yaxis_attr, attr(showgrid = false))
		zaxis_attr = merge(zaxis_attr, attr(showgrid = false))
	end
	if !showaxis
		xaxis_attr = merge(xaxis_attr, attr(visible = false))
		yaxis_attr = merge(yaxis_attr, attr(visible = false))
		zaxis_attr = merge(zaxis_attr, attr(visible = false))
	end
	relayout!(fig, scene = attr(
		aspectmode = aspectmode,
		xaxis = xaxis_attr,
		yaxis = yaxis_attr,
		zaxis = zaxis_attr,
	))
	# apply optional layout updates
	if title != ""
		relayout!(fig, title = title)
	end
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
	relayout!(fig, template = :plotly_white)
	if fontsize > 0
		relayout!(fig, font = attr(size = fontsize))
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

#endregion

"""
	set_template!(fig, template = "plotly_white")

Applies a visual template to a PlotlyJS figure.

# Arguments
- `fig`: A `PlotlyJS.Plot` object.
- `template`: String specifying the template to apply (default: `:plotly_white`).

# Notes
- This modifies the figure in-place using `relayout!`.
- Available templates include `:plotly`, `:ggplot2`, `:seaborn`, `:simple_white`, `:plotly_dark`, etc.
"""
function set_template!(fig, template = "plotly_white")
	# relayout!(fig, template = template)
	if template == "plotly_white"
		fig.plot.layout.template = PlotlyJS.templates.plotly_white
	elseif template == "plotly_dark"
		fig.plot.layout.template = PlotlyJS.templates.plotly_dark
	elseif template == "plotly"
		fig.plot.layout.template = PlotlyJS.templates.plotly
	elseif template == "ggplot2"
		fig.plot.layout.template = PlotlyJS.templates.ggplot2	
	elseif template == "seaborn"
		fig.plot.layout.template = PlotlyJS.templates.seaborn	
	elseif template == "simple_white"
		fig.plot.layout.template = PlotlyJS.templates.simple_white	
	elseif template == "presentation"
		fig.plot.layout.template = PlotlyJS.templates.presentation	
	elseif template == "xgridoff"
		fig.plot.layout.template = PlotlyJS.templates.xgridoff	
	elseif template == "ygridoff"
		fig.plot.layout.template = PlotlyJS.templates.ygridoff	
	elseif template == "gridon"
		fig.plot.layout.template = PlotlyJS.templates.gridon	
	else # default
		fig.plot.layout.template = PlotlyJS.templates.plotly_white	
	end
	react!(fig, fig.plot.data, fig.plot.layout)
	return nothing
end

## additional auxilliary functions

function _tuple_interleave(tu::Union{NTuple{3, Vector}, NTuple{4, Vector}})
	#auxilliary function to interleave elements of a NTuple of vectors, N = 3 or 4
	zipped_data = collect(zip(tu...))
	vv_zdata = [collect(elem) for elem in zipped_data]
	return reduce(vcat, vv_zdata)
end
