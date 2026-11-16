# PlotlySupply 2.0 scientific-plotting extensions: xticks!/yticks!, axis_equal!, axis_off!, spines!, grid!, secondary_xaxis!, inset!.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_AXES_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_AXES_MUTATORS = ()
