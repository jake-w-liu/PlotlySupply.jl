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
		legend = legend,
		title = title,
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
	relayout!(fig, template = :plotly_white)
	return fig
end

"""
function plot_heatmap(
	x::Union{AbstractRange, Vector},
	y::Union{AbstractRange, Vector},
	U::Array;
	xlabel::String = "",
	ylabel::String = "",
	zrange::Vector = [0, 0],
	ref_size::Int = 500,
	colorscale::String = "Jet",
	title::String = "",
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
function plot_heatmap(
	U::Array;
	xlabel::String = "",
	ylabel::String = "",
	zrange::Vector = [0, 0],
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
	x = collect(0:1:size(U, 1)-1)
	y = collect(0:1:size(U, 2)-1)
	return plot_heatmap(x, y, U; xlabel = xlabel, ylabel = ylabel, xrange = xrange, yrange = yrange, zrange = zrange, ref_size = ref_size, colorscale = colorscale, title = title, width = width, height = height)
end

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
)
	if isempty(surfacecolor)
		trace = surface(x = X, y = Y, z = Z, colorscale = "Jet")
	else
		trace = surface(x = X, y = Y, z = Z, surfacecolor = surfacecolor, colorscale = "Jet")
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
			xaxis = attr(title = xlabel),
			yaxis = attr(title = ylabel),
			zaxis = attr(title = zlabel),
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

	relayout!(fig, template = :plotly_white)
	return fig
end

function plot_surface(
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
	)
end

function plot_scatter3d(
	x::Vector,
	y::Vector,
	z::Vector;
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
	perspective::Bool = true,
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
			xaxis = attr(title = xlabel),
			yaxis = attr(title = ylabel),
			zaxis = attr(title = zlabel),
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
	relayout!(fig, template = :plotly_white)
	return fig
end

