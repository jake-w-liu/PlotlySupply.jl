using Pkg, Revise
Pkg.activate(".")

using Infiltrator

using PlotlySupply
using FFTW


srate = 20
dt = 1/srate
tb = 4
t = collect(-tb : 1/srate : tb-1/srate)
sig = exp.(-pi.*t.^2)
N = length(t)

display(plot_scatter(t, sig, xrange=[-tb,tb]))

f = collect(-N/2:1:N/2-1) .* srate ./ N

sig_fourier = zeros(ComplexF64, N)
for n in eachindex(sig_fourier)
    for m in eachindex(sig)
        sig_fourier[n] += sig[m] .* exp(-1im*2pi*f[n]*t[m]) .*dt
    end
end

sig_dft = zeros(ComplexF64, N)
sig_dft = fft(sig) .* dt
sig_dft .= fftshift(sig_dft)
# display(plot_scatter(f, [abs.(sig_fourier), abs.(sig_dft)], xrange=[-tb,tb]))
display(plot_scatter([t,f], [sig, abs.(sig_dft)], 
    xrange=[-tb,tb], legend=["g(t)", "G(f)"]))