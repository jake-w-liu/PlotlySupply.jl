# A diverging strip with a power-of-ten colorbar, log-y cell edges, and a curvilinear cross-section.
#
# Catalogue: topo "pcolormesh strip/heatmaps with diverging or sequential norm, non-uniform edges,
#   log y, categorical ticks" (and the curvilinear meridian map).
# Replaces: pcolormesh with TwoSlopeNorm(0), pi-fraction x ticks, ScalarFormatter(useMathText),
#   geometric cell edges on a log y axis, pcolormesh on 2-D (rho, z) arrays with set_aspect('equal').
# 2.0: `cmid = 0`, `exponentformat = "power"` on the colorbar, `yscale = "log"` with edges, and
#   `plot_pcolormesh!` on node arrays with `equalar = true`.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

pi_ticks = [0, π / 2, π, 3π / 2, 2π]
pi_labels = ["\$0\$", "\$\\pi/2\$", "\$\\pi\$", "\$3\\pi/2\$", "\$2\\pi\$"]
θe = range(0, 2π; length = 241)                          # cell edges
θc = (θe[1:end-1] .+ θe[2:end]) ./ 2
alphas = [-0.3, 0.075, 0.3]
diff = [1.8e-5 * sign(a) * (abs(a) / 0.3)^0.6 * sin(3θ + a) * (1 + 0.3cos(θ)) for θ in θc, a in alphas]
m = maximum(abs, diff)

δ = [0.035, 0.05, 0.07, 0.1, 0.14, 0.2, 0.28, 0.4]
ratio = sqrt(δ[2] / δ[1])
δe = vcat(δ[1] / ratio, sqrt.(δ[1:end-1] .* δ[2:end]), δ[end] * ratio)         # geometric cell edges
θpk = [0.35, 0.35 + π]
dens = [sum(exp(-((θ - p) / (0.6 * sqrt(d)))^2) for p in θpk) * 1.9 / (1 + 4d) for θ in θc, d in δ]

R0, a, b, h = 3.0, 1.0, 0.7, 0.24                        # an elliptic meridian with a thin wall
θn, s = range(0, 2π; length = 121), range(-0.5, 0.5; length = 9)
nrm(t) = (n = (b * cos(t), a * sin(t)); n ./ hypot(n...))
Rr = [R0 + a * cos(t) + h * si * nrm(t)[1] for t in θn, si in s]
Zz = [b * sin(t) + h * si * nrm(t)[2] for t in θn, si in s]
mat = [1 + (0.65 + 0.2 * cos(2t)) * cos(2π * si) for t in θn[1:end-1], si in (s[1:end-1] .+ s[2:end]) ./ 2]

fig = with_style(:ieee) do
	sf = subplots(2, 2; sync = false, specs = [Spec(colspan = 2) missing; Spec() Spec()],
		height_ratios = [0.8, 1.2], width_ratios = [1.25, 1])
	figsize!(sf, :ieee; columns = 2, aspect = 0.62)
	plot_heatmap!(sf, θe, 0:3, diff; row = 1, col = 1, colorscale = "PuOr_r", crange = (-m, m), cmid = 0)
	yticks!(sf, [0.5, 1.5, 2.5], ["\$\\alpha_c=$(a >= 0 ? "+" : "-")$(abs(a))\$" for a in alphas]; row = 1, col = 1)
	xticks!(sf, pi_ticks, pi_labels; row = 1, col = 1)
	colorbar!(sf; row = 1, col = 1, exponentformat = "power", ticks = [-1e-5, 0, 1e-5])
	title!(sf, "cell-graph difference from the meridional reference"; row = 1, col = 1)
	plot_heatmap!(sf, θe, δe, dens; row = 2, col = 1, colorscale = "magma", yscale = "log")
	foreach(p -> vline!(sf, p; row = 2, col = 1, color = "white", dash = "dash"), θpk)
	yticks!(sf, [0.035, 0.07, 0.14, 0.28], ["0.035", "0.07", "0.14", "0.28"]; row = 2, col = 1)
	xticks!(sf, pi_ticks, pi_labels; row = 2, col = 1)
	colorbar!(sf; row = 2, col = 1, title = "energy density", title_side = :right)
	xlabel!(sf, "meridian angle \$\\theta\$"; row = 2, col = 1)
	ylabel!(sf, "thickness factor \$\\delta\$"; row = 2, col = 1)
	title!(sf, "normalized electric energy"; row = 2, col = 1)
	plot_pcolormesh!(sf, Rr, Zz, mat; row = 2, col = 2, colorscale = "viridis", equalar = true)
	plot_scatter!(sf, R0 .+ a .* cos.(θn), b .* sin.(θn); row = 2, col = 2, color = "black", dash = "dash",
		legend = "meridian \$\\gamma(\\theta)\$")
	plot_scatter!(sf, [Rr[:, 1], Rr[:, end]], [Zz[:, 1], Zz[:, end]]; row = 2, col = 2, color = "#333333",
		dash = "solid", showlegend = false)
	arrow!(sf, Rr[16, 1], Zz[16, 1], Rr[16, end], Zz[16, end]; row = 2, col = 2, head = :both)
	annotate!(sf, Rr[16, end], Zz[16, end], "\$\\delta\\tau(\\theta)\$"; row = 2, col = 2, showarrow = false,
		anchor = :bottomleft)
	set_legend!(sf; row = 2, col = 2, position = :center)            # the hole of the ring is free
	colorbar!(sf; row = 2, col = 2, title = "\$1+\\alpha\\cos(2\\pi s)\$", title_side = :right)
	xlabel!(sf, "cylindrical radius \$\\rho\$"; row = 2, col = 2)
	ylabel!(sf, "\$z\$"; row = 2, col = 2)
	title!(sf, "elliptic meridian"; row = 2, col = 2)
	panel_labels!(sf; labels = :abc, format = "({})")
	sf
end
savefig(fig, joinpath(outdir, "topo_pcolormesh.png"); scale = 2)
