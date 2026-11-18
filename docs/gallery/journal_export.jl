# A two-panel figure at a journal's text width, exported tight and byte-identical.
#
# Catalogue: optical "layout-checker / post-processing infrastructure", chama-python A11
#   (print-fitting and vector-export machinery).
# Replaces: figure sizes in inches, bold left-aligned panel letters, bbox_inches='tight', a long y label
#   that matplotlib splits over lines, and stripping PDF dates so that repeated builds are identical.
# 2.0: a journal preset, `figsize!(fig, 153, 60; units = :mm)` (any width, here the text width of an
#   Elsevier-style two-column layout), `panel_labels!`, long labels wrapped by the layout engine,
#   `savefig(...; tight = true)` and deterministic exports by default.
using PlotlySupply

outdir = isempty(ARGS) ? (@__DIR__) : first(ARGS)

x = range(0, 1; length = 50)
fig = with_style(:elsevier) do
	sf = subplots(1, 2; sync = false)
	figsize!(sf, 153, 60; units = :mm)                       # the journal's text width x 60 mm
	plot_scatter!(sf, x, x .^ 2; row = 1, col = 1, legend = "\$x^2\$")
	plot_scatter!(sf, x, sqrt.(x); row = 1, col = 2, legend = "\$\\sqrt{x}\$")
	foreach(c -> xlabel!(sf, "\$x\$"; row = 1, col = c), 1:2)
	ylabel!(sf, "a fairly long y-axis label that matplotlib would split"; row = 1, col = 1)
	panel_labels!(sf; labels = :abc, format = "({})", bold = true)
	sf
end

png = joinpath(outdir, "journal_export.png")
savefig(fig, png; tight = true, scale = 2)
# One render, two files; two PDFs of the same figure are byte-identical (no dates in the file).
mktempdir() do tmp
	pdf1, pdf2 = joinpath(tmp, "a.pdf"), joinpath(tmp, "b.pdf")
	savefig(fig, [pdf1, joinpath(tmp, "a.png")]; tight = true)
	savefig(fig, pdf2; tight = true)
	read(pdf1) == read(pdf2) || error("journal_export: two exports of one figure differ")
end
