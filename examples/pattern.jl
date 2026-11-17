using PlotlySupply # re-exports meshgrid from MeshGrid.jl

# Far-field radiation pattern |F(θ)| = |cos θ| drawn as a surface in spherical
# coordinates (θ: polar angle from +z, φ: azimuth, both in degrees): the point at
# (θ, φ) lies at distance |F| from the origin, so the two lobes along ±z are
# visible, and the surface is coloured by |F|.
tht = 0:1:180
phi = 0:1:360
P, T = meshgrid(phi, tht)      # P[i, j] = phi[j], T[i, j] = tht[i]
R = abs.(cosd.(T))
Xd = R .* sind.(T) .* cosd.(P)
Yd = R .* sind.(T) .* sind.(P)
Zd = R .* cosd.(T)
fig = plot_surface(Xd, Yd, Zd;
    surfacecolor=R, colorbar_title="|F|",
    xlabel="x", ylabel="y", zlabel="z",
    aspectmode="data", view=(25, -60),
    title="Radiation pattern |F(θ)| = |cos θ|")
display(fig)
