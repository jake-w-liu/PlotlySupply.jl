# PlotlySupply 2.0 scientific-plotting extensions: plot_polygons3d, view!, scene!, 3-D annotate!, wireframes, 3-D segments, 3-D arrows.
#
# Public names defined here are exported from this file. Untyped-first-argument
# mutators that must run as one renderer transaction on `Plot`/`SyncPlot` are
# listed in `_SCI_SCENE3D_MUTATORS`; api.jl splices that tuple into the
# transactional wrapper registry.

const _SCI_SCENE3D_MUTATORS = ()
