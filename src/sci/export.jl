# PlotlySupply 2.0 scientific-plotting extensions: physical size / dpi, deterministic PDF and SVG bytes, EPS, multi-format export helpers.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_EXPORT_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_EXPORT_MUTATORS = ()
