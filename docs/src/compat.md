# Re-exported API (PlotlyJS compatibility)

PlotlySupply re-exports the `PlotlyBase` API surface for PlotlyJS-style usage:
trace constructors such as `scatter`/`bar`/`heatmap`, attribute builders
(`attr`, `Layout`, `GenericTrace`), the `restyle!`/`relayout!`/`addtraces!`
update verbs, and helpers like `fork`, `frame`, `templates`, and `colors`.
These names resolve to their upstream `PlotlyBase` (or `MeshGrid`) bindings;
where a `SyncPlot` method exists it is listed with the entry.

```@autodocs
Modules = [PlotlySupply, PlotlyBase]
Order   = [:function, :type, :constant, :macro]
Public  = true
Private = false
Filter  = s -> try parentmodule(s) !== PlotlySupply catch; true end
```
