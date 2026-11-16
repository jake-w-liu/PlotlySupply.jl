# PlotlySupply 2.0 scientific-plotting extensions: PlotStyle presets, set_fonts!, tight_layout!, figsize!.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_STYLE_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_STYLE_MUTATORS = ()
