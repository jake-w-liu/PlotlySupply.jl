# PlotlySupply 2.0 scientific-plotting extensions: colormap resolution and sampling, colour utilities, colour norms, colorbar attribute/carrier builders.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_COLOR_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_COLOR_MUTATORS = ()
