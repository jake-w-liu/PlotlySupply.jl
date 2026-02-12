const _PLOTLYKALEIDO_PKGID =
	Base.PkgId(Base.UUID("f2990250-8cf9-495f-b13a-cce12b45703c"), "PlotlyKaleido")

function _plotlykaleido()
	try
		return Base.root_module(_PLOTLYKALEIDO_PKGID)
	catch
		try
			Base.require(_PLOTLYKALEIDO_PKGID)
			return Base.root_module(_PLOTLYKALEIDO_PKGID)
		catch
			error(
				"PlotlyKaleido.jl is required for image export. " *
				"Run `import Pkg; Pkg.add(\"PlotlyKaleido\")` once in your environment.",
			)
		end
	end
end

function _ensure_plotlykaleido_running()
	pk = _plotlykaleido()
	Base.invokelatest(() -> pk.is_running()) || Base.invokelatest(() -> pk.start())
	return pk
end

function make_subplots(; kwargs...)
	fig = plot(Layout(Subplots(; kwargs...)))
	p = _plot_obj(fig)
	_apply_default_template!(p)
	_apply_default_cartesian_axes!(p)
	_refresh!(fig)
	return fig
end

function mgrid(arrays...)
	lengths = collect(length.(arrays))
	ones_vec = ones(Int, length(arrays))
	out = []
	for i in eachindex(arrays)
		repeats = copy(lengths)
		repeats[i] = 1

		shape = copy(ones_vec)
		shape[i] = lengths[i]
		push!(out, reshape(arrays[i], shape...) .* ones(repeats...))
	end
	return out
end

function _savefig_html(io::IO, p::Plot)
	show(
		io,
		MIME("text/html"),
		p;
		include_mathjax = "cdn",
		include_plotlyjs = "cdn",
		full_html = true,
	)
	return nothing
end

const _KALEIDO_EXPORT_KW = Set((:height, :width, :scale))

_is_nan_json_error(err) =
	err isa ArgumentError &&
	occursin("NaN not allowed to be written in JSON spec", sprint(showerror, err))

function _savefig_kaleido(io::IO, p::Plot, fmt::String, pk::Module; kwargs...)
	try
		Base.invokelatest(() -> pk.savefig(io, p; format = fmt, kwargs...))
		return nothing
	catch err
		_is_nan_json_error(err) || rethrow(err)

		# Keep behavior strict: only Kaleido's documented export kwargs are supported.
		for k in keys(kwargs)
			k in _KALEIDO_EXPORT_KW || rethrow(err)
		end

		height = get(kwargs, :height, 500)
		width = get(kwargs, :width, 700)
		scale = get(kwargs, :scale, 1)
		payload = PlotlyBase.JSON.json(
			(; height = height, width = width, scale = scale, format = fmt, data = p);
			allownan = true,
			nan = "null",
			inf = "null",
			ninf = "null",
		)

		if isdefined(pk, :save_payload)
			Base.invokelatest(() -> pk.save_payload(io, payload, fmt))
		else
			# Fallback for older/newer PlotlyKaleido APIs: pass serialized plot directly.
			Base.invokelatest(() -> pk.savefig(io, payload; format = fmt, kwargs...))
		end
		return nothing
	end
end

function savefig(io::IO, p::Plot; format::AbstractString = "png", kwargs...)
	fmt = lowercase(String(format))
	if fmt == "html"
		return _savefig_html(io, p)
	end

	pk = _ensure_plotlykaleido_running()
	_savefig_kaleido(io, p, fmt, pk; kwargs...)
	return nothing
end

savefig(io::IO, sp::SyncPlot; kwargs...) = savefig(io, sp.plot; kwargs...)

function savefig(p::Union{Plot, SyncPlot}; kwargs...)
	io = IOBuffer()
	savefig(io, p; kwargs...)
	return take!(io)
end

function savefig(
	filename::AbstractString,
	p::Union{Plot, SyncPlot};
	format::Union{Nothing, AbstractString} = nothing,
	kwargs...,
)
	ext = lowercase(splitext(filename)[2])
	fmt = isnothing(format) ? (isempty(ext) ? "png" : lstrip(ext, '.')) : lowercase(String(format))

	open(filename, "w") do io
		savefig(io, p; format = fmt, kwargs...)
	end
	return filename
end

savefig(p::Union{Plot, SyncPlot}, filename::AbstractString; kwargs...) =
	savefig(filename, p; kwargs...)

PlotlyBase.savejson(sp::SyncPlot, fn::String) = PlotlyBase.savejson(sp.plot, fn)
PlotlyBase.trace_map(sp::SyncPlot, axis) = PlotlyBase.trace_map(sp.plot, axis)
PlotlyBase._is3d(sp::SyncPlot) = PlotlyBase._is3d(sp.plot)

Base.size(sp::SyncPlot) = size(sp.plot)

function PlotlyBase.add_trace!(sp::SyncPlot, trace::GenericTrace; kw...)
	PlotlyBase.add_trace!(sp.plot, trace; kw...)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.redraw!(sp::SyncPlot)
	PlotlyBase.redraw!(sp.plot)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

function PlotlyBase.purge!(sp::SyncPlot)
	PlotlyBase.purge!(sp.plot)
	_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
	return sp
end

PlotlyBase.to_image(sp::SyncPlot; kwargs...) = PlotlyBase.to_image(sp.plot; kwargs...)
PlotlyBase.download_image(sp::SyncPlot; kwargs...) = PlotlyBase.download_image(sp.plot; kwargs...)

function _clone_syncplot(sp::SyncPlot)
	return to_syncplot(deepcopy(sp.plot); app = sp.app)
end

for f in (
	:restyle,
	:relayout,
	:update,
	:addtraces,
	:deletetraces,
	:movetraces,
	:extendtraces,
	:prependtraces,
	:react,
)
	f_bang = Symbol(f, "!")
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; kwargs...)
		out = _clone_syncplot(sp)
		PlotlyBase.$f_bang(out, args...; kwargs...)
		return out
	end
end

const _SYNCPLOT_DEFINED_LAYOUT_UPDATERS = Set((:update_xaxes!, :update_yaxes!, :update_polars!))

for (f, _) in vcat(PlotlyBase._layout_obj_updaters, PlotlyBase._layout_vector_updaters)
	f in _SYNCPLOT_DEFINED_LAYOUT_UPDATERS && continue
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; kwargs...)
		PlotlyBase.$f(sp.plot, args...; kwargs...)
		_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
		return sp
	end
end

for f in (:add_hrect!, :add_hline!, :add_vrect!, :add_vline!, :add_shape!, :add_layout_image!)
	@eval function PlotlyBase.$f(sp::SyncPlot, args...; kwargs...)
		PlotlyBase.$f(sp.plot, args...; kwargs...)
		_plotlyjs_refresh!(sp, sp.plot.data, sp.plot.layout)
		return sp
	end
end

function PlotlyBase.add_recession_bands!(sp::SyncPlot; kwargs...)
	new_shapes = PlotlyBase.add_recession_bands!(sp.plot; kwargs...)
	PlotlyBase.relayout!(sp, shapes = new_shapes)
	return new_shapes
end

function _syncplot_app(sps::Tuple{Vararg{SyncPlot}})
	for sp in sps
		sp.app === nothing || return sp.app
	end
	return nothing
end

function Base.hcat(sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(hcat(plots...); app = _syncplot_app(sps))
end

function Base.vcat(sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(vcat(plots...); app = _syncplot_app(sps))
end

function Base.hvcat(rows::Tuple{Vararg{Int}}, sps::SyncPlot...)
	plots = Plot[sp.plot for sp in sps]
	return to_syncplot(hvcat(rows, plots...); app = _syncplot_app(sps))
end
