using PlotlySupply
using MeshGrid
tht = 0:1:180
phi = 0:1:360
P, T = meshgrid(phi, tht)
A_plt = cosd.(T)
S = A_plt
Zd = A_plt .* cosd.(T)
Xd = A_plt .* sind.(T) .* cosd.(P)
Yd = A_plt .* sind.(T) .* sind.(P)
fig = plot_surface(Xd, Yd, Zd)
display(fig)

