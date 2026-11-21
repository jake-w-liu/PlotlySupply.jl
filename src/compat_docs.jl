# Help text (`?relayout!`, ...) for the PlotlyBase update verbs that PlotlySupply
# extends to `SyncPlot` and `SubplotFigure`. Only documentation lives here: the
# methods themselves are defined in api.jl and electron_backend.jl.

const _COMPAT_VERB_NOTE = """
PlotlySupply extends this PlotlyBase verb to the figure types it adds:

- On a [`SyncPlot`](@ref) the Julia figure and the open window change in one
  transaction (if the renderer fails the Julia figure is left unchanged);
  after the window is closed it throws an `InvalidStateException`.
- On a [`SubplotFigure`](@ref) the verb acts on the whole figure. The cell
  keywords `row`, `col`, `secondary_y`, `inset` and `show` are rejected with an
  `ArgumentError`; use the `update_*` functions or the `plot_*!` mutators for
  one cell.
"""

for (verb, extra) in (
	(:relayout!, "A change to an axis of a shared-axis group of a `SubplotFigure` acts on the whole group (`relayout!(sf; yaxis2_type = \"log\")` makes the group logarithmic)."),
	(:update!, "The layout part of `update!` on a `SubplotFigure` follows the same shared-group rule as `relayout!`."),
	(:restyle!, "Trace attributes: `restyle!(sp, 1; line_color = \"red\")` changes trace 1."),
	(:deletetraces!, "Removes traces by index."),
	(:movetraces!, "Moves traces to new positions."),
	(:extendtraces!, "Appends points to existing traces."),
	(:prependtraces!, "Prepends points to existing traces."),
)
	@eval @doc $(string("`", verb, "(fig, ...)`: the PlotlyBase verb (see its own help above).\n\n", _COMPAT_VERB_NOTE, "\n", extra, "\n")) PlotlyBase.$verb
end

@doc """
`addtraces!(fig, traces...)`: the PlotlyBase verb. On a [`SyncPlot`](@ref) the
traces are added to the Julia figure and the open window in one transaction
(an `InvalidStateException` once the window is closed); on a
[`SubplotFigure`](@ref) the traces go to the figure as given (use `row`/`col`
mutators such as [`plot_scatter!`](@ref) to draw into a cell).
""" PlotlyBase.addtraces!
