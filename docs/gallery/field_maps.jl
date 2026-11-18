# Stacked intensity maps on a non-uniform grid, one colorbar for all three.
#
# Catalogue: optical "stacked field-intensity maps (inferno, 0-1) sharex with shared colorbar".
# Replaces: plt.subplots(3, 1, sharex=True), pcolormesh on quadrature nodes with vmin=0, vmax=1,
#   a white ax.text in axes coordinates, fig.colorbar(im, ax=axes, label=...).
# 2.0: `plot_pcolormesh!` accepts the non-uniform node vector; `equalar = true` keeps the cells
#   square; `shared_colorbar!` spans the three panels; the figure is sized to the field first.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

t = range(0, 1; length = 181)
x = collect(6 .* (t .- 0.035 .* sin.(6π .* t)))           # denser near the scatterers
y = collect(range(0, 1.8; length = 61))
mode(y, m) = sin(m * π * y / 1.8)
inputs = [(1, 0), (1, im) ./ sqrt(2), (1, -im) ./ sqrt(2)]
labels = ["\$\\mathbf{a}=(1,0)^{\\mathrm{T}}\$", "\$\\mathbf{a}=(1,i)^{\\mathrm{T}}/\\sqrt{2}\$",
	"\$\\mathbf{a}=(1,-i)^{\\mathrm{T}}/\\sqrt{2}\$"]

fig = with_style(:aps) do
	sf = subplots(3, 1; sync = false, shared_xaxes = true,
		width = journal_width(:aps; columns = 1, units = :px), height = 330)
	for (r, (a1, a2)) in enumerate(inputs)
		E = [a1 * mode(b, 1) * cis(2.1 * a) + a2 * mode(b, 2) * cis(1.6 * a) * (1 + 0.2 * sin(a)) for a in x, b in y]
		I = abs2.(E)
		plot_pcolormesh!(sf, x, y, I ./ maximum(I); row = r, col = 1, colorscale = "inferno", crange = (0, 1),
			equalar = true)
		annotate!(sf, 0.02, 0.8, labels[r]; row = r, col = 1, coords = :axes, showarrow = false,
			anchor = :left, color = "white")
		ylabel!(sf, "\$y\$ (\$\\mu\$m)"; row = r, col = 1)
	end
	xlabel!(sf, "\$x\$ (\$\\mu\$m)"; row = 3, col = 1)
	shared_colorbar!(sf; title = "normalized \$|E_z|^2\$", title_side = :right)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "field_maps.png"); scale = 2)
