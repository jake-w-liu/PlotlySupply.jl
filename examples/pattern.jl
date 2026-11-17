using PlotlySupply # re-exports meshgrid from MeshGrid.jl

# Radiation pattern r(θ) = cos θ drawn as a surface in spherical coordinates
# (θ: polar angle from +z, φ: azimuth, both in degrees), coloured by |r|.
tht = 0:1:180
phi = 0:1:360
P, T = meshgrid(phi, tht)
A_plt = cosd.(T)
S = abs.(A_plt)
Zd = A_plt .* cosd.(T)
Xd = A_plt .* sind.(T) .* cosd.(P)
Yd = A_plt .* sind.(T) .* sind.(P)
fig = plot_surface(Xd, Yd, Zd;
    surfacecolor=S, colorbar_title="|r|",
    xlabel="x", ylabel="y", zlabel="z",
    aspectmode="data", view=(25, -60),
    title="Radiation pattern r = cos θ")
display(fig)
