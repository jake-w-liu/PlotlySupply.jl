# PlotlySupply 2.0 scientific-plotting extensions: cell targeting, log-aware axis coordinates, named annotation/shape upsert, tick/aspect/marker/hatch primitives, legend proxy traces.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_COMMON_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_COMMON_MUTATORS = ()
