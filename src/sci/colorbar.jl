# PlotlySupply 2.0 scientific-plotting extensions: per-cell colorbar placement, colorbar!, shared_colorbar!.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_COLORBAR_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_COLORBAR_MUTATORS = ()
