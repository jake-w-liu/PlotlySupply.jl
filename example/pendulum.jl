using PlotlySupply   

g, l = 9.8, 5.0

# grid
θs = range(-π, π, length=25)
ωs = range(-3, 3, length=25)

Θ = Float64[]; Ω = Float64[]; U = Float64[]; V = Float64[]
for θ in θs, ω in ωs
    dθ = ω
    dω = -(g/l) * sin(θ)
    push!(Θ, θ); push!(Ω, ω); push!(U, dθ); push!(V, dω)
end

# base quiver
fig = plot_quiver(
    Θ, Ω, U, V;
    sizeref=0.15, color="DarkOrange",
    xlabel=" θ", ylabel="d θ/dt",
    xrange=[-π, π], yrange=[minimum(ωs), maximum(ωs)],
    title="Phase Space of a Simple Pendulum",
)
relayout!(fig, scene = attr(aspectmode = "auto"))

# energy contours H(θ, ω) = 0.5 ω^2 + (g/l)(1 - cos θ)
Z = [0.5*ω^2 + (g/l)*(1 - cos(θ)) for ω in ωs, θ in θs]

cont = contour(
    x=collect(θs), y=collect(ωs), z=Z,
    contours=attr(coloring="lines", showlabels=false),
    line=attr(color="SlateGray", width=2),
    showscale=false, ncontours=12,
)

# separatrix H = g/l  → passes through (θ, ω) with ω=0 at θ=±π
addtraces!(fig, cont)

display(fig)