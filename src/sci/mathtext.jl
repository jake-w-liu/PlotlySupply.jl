# PlotlySupply 2.0 scientific-plotting extensions: mixed text + LaTeX label pipeline (`mathtext`, `_label`).
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_MATHTEXT_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_MATHTEXT_MUTATORS = ()
