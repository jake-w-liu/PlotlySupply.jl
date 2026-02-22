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

# display the quiver plot first, then animate by adding contours + trajectory
display(fig)
sleep(1)

# add energy contours — window updates live
addtraces!(fig, cont)
sleep(1)

# animate a trajectory using RK4 integration
θ0, ω0 = 1.0, 0.0
dt = 0.05
θ_traj = [θ0]
ω_traj = [ω0]

for _ in 1:300
    # RK4 step for (dθ/dt = ω, dω/dt = -(g/l)sin(θ))
    k1θ = ω_traj[end]
    k1ω = -(g/l) * sin(θ_traj[end])
    k2θ = ω_traj[end] + 0.5dt * k1ω
    k2ω = -(g/l) * sin(θ_traj[end] + 0.5dt * k1θ)
    k3θ = ω_traj[end] + 0.5dt * k2ω
    k3ω = -(g/l) * sin(θ_traj[end] + 0.5dt * k2θ)
    k4θ = ω_traj[end] + dt * k3ω
    k4ω = -(g/l) * sin(θ_traj[end] + dt * k3θ)

    push!(θ_traj, θ_traj[end] + dt/6 * (k1θ + 2k2θ + 2k3θ + k4θ))
    push!(ω_traj, ω_traj[end] + dt/6 * (k1ω + 2k2ω + 2k3ω + k4ω))
end

# animate the trajectory point-by-point using react!
traj_trace = scatter(x=[θ_traj[1]], y=[ω_traj[1]],
    mode="lines+markers", line=attr(color="crimson", width=2),
    marker=attr(size=6), name="trajectory",
)
addtraces!(fig, traj_trace)

for i in 2:5:length(θ_traj)
    fig.data[end][:x] = θ_traj[1:i]
    fig.data[end][:y] = ω_traj[1:i]
    restyle!(fig, length(fig.data), Dict(:x => [θ_traj[1:i]], :y => [ω_traj[1:i]]))
    sleep(0.03)
end

savefig(fig, "./pendulum.pdf")
