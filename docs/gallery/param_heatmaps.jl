# Two parameter-space heatmaps with a shared y axis and one colorbar.
#
# Catalogue: optical "side-by-side pcolormesh parameter-space heatmaps (magma) sharey, one colorbar".
# Replaces: plt.subplots(1, 2, sharey=True), pcolormesh(vmin=0, vmax=.6) with the default
#   'auto' aspect, the y label on the left panel only, fig.colorbar(im, ax=axes).
# 2.0: `equalar = false` keeps matplotlib's auto aspect (the mesh functions default to equal
#   aspect); `shared_yaxes` hides the right panel's tick labels; `shared_colorbar!` draws the bar.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

ϕ = collect(range(-1, 1; length = 121))              # node coordinates, units of pi
θ = collect(range(0, 1; length = 61))
err_fixed(p, q) = 0.55 * sinpi(q)^2 * (1 - cospi(p)) / 2 + 0.05
err_refit(p, q) = 0.12 * sinpi(q)^2 * (1 - cospi(p - 0.3)) / 2 + 0.02 * sinpi(2q)^2

fig = with_style(:aps) do
	sf = subplots(1, 2; sync = false, shared_yaxes = true)
	figsize!(sf, :aps; columns = 2, aspect = 0.4)
	for (c, (f, name)) in enumerate(((err_fixed, "fixed encoder"), (err_refit, "re-fitted encoder")))
		plot_pcolormesh!(sf, ϕ, θ, [f(p, q) for p in ϕ, q in θ]; row = 1, col = c, colorscale = "magma",
			crange = (0, 0.6), equalar = false)
		xlabel!(sf, "relative phase \$\\phi/\\pi\$"; row = 1, col = c)
		title!(sf, name; row = 1, col = c)
	end
	ylabel!(sf, "amplitude angle \$\\theta/\\pi\$"; row = 1, col = 1)
	shared_colorbar!(sf; title = "maximum relative field error", title_side = :right)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "param_heatmaps.png"); scale = 2)
