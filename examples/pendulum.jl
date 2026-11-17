using PlotlySupply

# Phase portrait of a simple pendulum, θ'' = -(g/l) sin θ, written as the
# first-order system dθ/dt = ω, dω/dt = -(g/l) sin θ.
g, l = 9.8, 5.0
energy(θ, ω) = 0.5 * ω^2 + (g / l) * (1 - cos(θ))

# grid
θs = range(-π, π, length=25)
ωs = range(-3, 3, length=25)

Θ = Float64[]; Ω = Float64[]; U = Float64[]; V = Float64[]
for θ in θs, ω in ωs
    push!(Θ, θ); push!(Ω, ω)
    push!(U, ω)                 # dθ/dt
    push!(V, -(g / l) * sin(θ)) # dω/dt
end

# base quiver: the longest arrow is about one grid spacing long, and the axes
# keep an equal data aspect (plot_quiver's default), so arrow angles are true.
fig = plot_quiver(
    Θ, Ω, U, V;
    sizeref=0.3, color="DarkOrange",
    xlabel="θ", ylabel="dθ/dt",
    xrange=[-π, π], yrange=[-3, 3],
    title="Phase Space of a Simple Pendulum",
)

# energy levels H(θ, ω) = ω²/2 + (g/l)(1 - cos θ) on a finer grid than the
# arrows, for smooth contour lines. Matrices are indexed H[ix, iy] = H[iθ, iω],
# with size (length(θf), length(ωf)).
θf = range(-π, π, length=121)
ωf = range(-3, 3, length=121)
H = [energy(θ, ω) for θ in θf, ω in ωf]

# display the quiver plot first, then animate by adding contours + trajectory
display(fig)
sleep(1)

# add energy contours (one colour, no colorbar) — the window updates live
plot_contour!(fig, θf, ωf, H; ncontours=12, linecolor="SlateGray", linewidth=1.5)
sleep(1)

# integrate a trajectory with RK4
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

# animate the trajectory point by point: restyle! updates the model and the window
plot_scatter!(fig, θ_traj[1:1], ω_traj[1:1];
    mode="lines", color="crimson", linewidth=2.5,
    legend="trajectory, H = $(round(energy(θ0, ω0); digits=3))")
set_legend!(fig; position=:outside_right)
traj = length(fig.data)
n = length(θ_traj)
for i in [2:5:n; n]
    # A single-trace restyle! takes one value per trace, hence the [ ] wrapper.
    restyle!(fig, traj, Dict(:x => [θ_traj[1:i]], :y => [ω_traj[1:i]]))
    sleep(0.03)
end

savefig(fig, "pendulum.pdf")
