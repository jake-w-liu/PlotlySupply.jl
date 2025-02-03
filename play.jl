using Pkg, Revise
Pkg.activate(".")

using Infiltrator

using PlotlySupply
using FFTW


# region section 1
s(t) = 0.5 * sin(2pi * t / 24) + sin(2pi * t / 24 / 7) + 1.5 # whatever vs. hour

hour = collect(1:24*7*1)
day = hour ./ 24
eng = s.(t)

ylabel = "energy"
fig1 = plot_scatter(day, eng; xlabel = "time (day)", ylabel = ylabel)
display(fig1)

fig2 = plot_scatter(hour, eng;
	xlabel = "time (hour)",
	ylabel = ylabel, xrange = [1, 24], yrange = [1.4, 2.4])
display(fig2)

sigf = fft(eng)

fig3 = plot_stem(abs.(engf)) # what is this???
display(fig3)

# our goal is to find the coefficient 0.5 & 1 in s(t) from engf
# some magic...
n = length(engf)
engf ./= n
srate = 1 ./ (hour[2] - hour[1])
if isodd(n)
	fac = (n - 1) / n
else
	fac = 1
end
f = LinRange(0, srate / 2 * fac, floor(Int64, n / 2 + 1))
fsig = engf[1:length(f)]
fsig[2:end] .= 2 .* abs.(fsig[2:end])

fig4 = plot_stem(f, abs.(fsig), xlabel = "frequency (1/hour)", ylabel = "coef.") 
display(fig4)
#endregion

#region section 2
function fft_fs(sig, srate = 1)
    Sig = fft(sig)
    N = length(Sig)
    Sig ./= N
    if isodd(N)
        f = LinRange(0, srate / 2 * (N - 1) / N, floor(Int64, N / 2 + 1))
    else
        f = LinRange(0, srate / 2 * 1, floor(Int64, N / 2 + 1))
    end

    sSig = Sig[1:length(f)]
    sSig[2:end] .= 2 .* abs.(sSig[2:end])

    return sSig, f
end

srate = 100
time = collect(0 : 1/srate : 1- 1/srate)
N = length(time)

# boring sinusoids
s1(t) = 2 + sin(2pi*5*t) + 3 * cos(2pi*30*t)  + 1.5 * sin(2pi*50*t + pi/5) 
S1, freq = fft_fs(s1.(time), srate)
fig_td = plot_scatter(time, s1.(time), xlabel = "time (sec.)", ylabel = "amplitude.") 
fig_fd = plot_stem(freq, abs.(S1), xlabel = "frequency (Hz)", ylabel = "coef.") 
fig = [fig_td; fig_fd]
set_template!(fig, :plotly_white)
display(fig)

#endregion

#region section 3
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
display(plot_scatter([t,f], [sig, abs.(sig_dft)], 
    xrange=[-tb,tb], legend=["g(t)", "G(f)"]))
#endregion
