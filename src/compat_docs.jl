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
	# Attached to the `SyncPlot`/`SubplotFigure` signature, not to the bare
	# binding: PlotlyBase documents some of these verbs (`restyle!`, `update!`)
	# with a signature-free docstring, and a second one of ours would be the same
	# (binding, signature) pair, which Documenter's strict build rejects as a
	# duplicate on the compatibility page.
	@eval @doc $(string("`", verb, "(fig, ...)`: the PlotlyBase verb (see its own help above).\n\n", _COMPAT_VERB_NOTE, "\n", extra, "\n")) PlotlyBase.$verb(::Union{SyncPlot, SubplotFigure}, args...)
end

@doc """
`addtraces!(fig, traces...)`: the PlotlyBase verb. On a [`SyncPlot`](@ref) the
traces are added to the Julia figure and the open window in one transaction
(an `InvalidStateException` once the window is closed); on a
[`SubplotFigure`](@ref) the traces go to the figure as given (use `row`/`col`
mutators such as [`plot_scatter!`](@ref) to draw into a cell).
""" PlotlyBase.addtraces!

@doc """
	update_yaxes!(sf::SubplotFigure, with=attr(); row=nothing, col=nothing, secondary_y=false, inset=nothing, kwargs...)

Update y axes of a [`SubplotFigure`](@ref); the keywords are Plotly y-axis
attributes (`type = "log"`, `title_text = "t"`, …).

- Without `row`/`col`: every y axis of the figure is updated; the active cell
  is unchanged.
- With `row` and `col` (pass both): only that cell's y axis is updated
  (`secondary_y = true`: its secondary y axis), and the cell becomes the active
  cell. A cell without a y axis (scene, polar, ...) is an `ArgumentError` and
  nothing changes; a `domain` value is ignored with a warning (the grid owns
  the domains).
- `inset = k`: only the y axis of inset `k` of `sf.insets` ([`inset!`](@ref),
  `subplots(...; insets)`) is updated, and its host cell becomes the active
  cell; `row`/`col` may be omitted (when given they must name the host cell).
  An unknown id, or `secondary_y = true` with an inset, is an `ArgumentError`.

Returns `sf`. [`update_xaxes!`](@ref) is the x-axis counterpart.

# Example
```julia
sf = subplots(1, 2; sync=false)
plot_scatter!(sf, 1:3, [1.0, 10, 100]; row=1, col=2)
update_yaxes!(sf; row=1, col=2, type="log")       # only cell (1, 2)
k = inset!(sf, (0.6, 0.6, 0.35, 0.35); row=1, col=2)
update_yaxes!(sf; inset=k, showgrid=false)        # only the inset's y axis
```
""" PlotlyBase.update_yaxes!(::SubplotFigure)
