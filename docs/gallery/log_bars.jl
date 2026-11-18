# Grouped bars on a log y axis beside a line plot with a dotted floor.
#
# Catalogue: optical "grouped bars on log y with custom ticks + power-vs-channel line".
# Replaces: ax.bar(np.arange(1, 4) + offset, ..., .3), set_yscale('log') with string tick labels,
#   'o--' and 's-' lines, a dotted ax.axhline with its own legend entry, hidden top/right spines.
# 2.0: `plot_bar!` groups series by itself, `yticks = [...]` with labels on a log axis takes data
#   values, `hline!(legend = ...)` adds the floor to the legend, `spines!(style = :open)`.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)
blue, red, orange = "#0072B2", "#D55E00", "#E69F00"
channels = [1, 2, 3]
rms = [[0.045, 0.11, 0.32], [0.038, 0.07, 0.15]]
power = [[0.93, 0.86, 0.81], [0.95, 0.9, 0.84]]
names = ["fixed basis", "re-fitted basis"]

fig = with_style(:ieee) do
	sf = subplots(1, 2; sync = false)
	figsize!(sf, :ieee; columns = 2, aspect = 0.4)
	plot_bar!(sf, channels, rms; row = 1, col = 1, color = [blue, red], legend = names, barmode = "group",
		yscale = "log")
	yrange!(sf, (0.03, 0.5); row = 1, col = 1)
	yticks!(sf, [0.03, 0.05, 0.1, 0.2, 0.4], ["0.03", "0.05", "0.1", "0.2", "0.4"]; row = 1, col = 1, minor = false)
	ylabel!(sf, "RMS waveform error"; row = 1, col = 1)
	set_legend!(sf; row = 1, col = 1, position = :topleft)     # the free corner above the short bars
	for (k, (marker, dash)) in enumerate((("circle", "dash"), ("square", "solid")))
		plot_scatter!(sf, channels, power[k]; row = 1, col = 2, mode = "lines+markers", marker_symbol = marker,
			dash = dash, color = (blue, red)[k], legend = names[k])
	end
	hline!(sf, 0.8; row = 1, col = 2, color = orange, dash = "dot", legend = "0.8 power floor")
	ylabel!(sf, "weakest channel power"; row = 1, col = 2)
	for c in 1:2
		xticks!(sf, channels; row = 1, col = c)
		xlabel!(sf, "number of channels"; row = 1, col = c)
		spines!(sf; style = :open, row = 1, col = c)
	end
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end
savefig(fig, joinpath(outdir, "log_bars.png"); scale = 2)
