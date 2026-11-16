# PlotlySupply 2.0 scientific-plotting extensions: plot_polygons, plot_pcolormesh, plot_tripcolor, plot_triplot, plot_tricontour.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_MESH2D_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_MESH2D_MUTATORS = ()
