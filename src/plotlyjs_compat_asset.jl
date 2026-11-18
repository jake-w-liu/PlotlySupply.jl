import SHA

const _PLOTLYJS_MATH_FONT_SOURCE_SHA256 =
	"6d21266ce1bd7d9e5ab4e115989c70c20de0382fd973a8f26ab58619eba4d603"
const _PLOTLYJS_LICENSE_SHA256 =
	"67a26cf80f03ff388f26945dfc1f6caed1a0746ff43871190339b3aee49b94bb"
const _PLOTLYJS_MATH_FONT_SEAM =
	raw""".attr({"pointer-events":"none","data-unformatted":S,"data-math":"Y"});l.node()"""
const _PLOTLYJS_MATH_FONT_REPLACEMENT =
	raw""".attr({"pointer-events":"none","data-unformatted":S,"data-math":"Y"}).style({"font-family":t.node().style.fontFamily,"font-size":r+"px"});l.node()"""
# Keep XMLSerializer's attribute quotes and retire the old quote placeholders.
const _PLOTLYJS_SVG_QUOTE_TRANSFORMS = (
	raw"""var e=this.style.fontFamily;e&&-1!==e.indexOf('"')&&t.style("font-family",e.replace(l,c));var r=this.style.fontWeight;""" =>
		raw"""var r=this.style.fontWeight;""",
	raw"""p.selectAll(".gradient_filled,.pattern_filled").each((function(){var t=n.select(this),e=this.style.fill;e&&-1!==e.indexOf("url(")&&t.style("fill",e.replace(l,c));var r=this.style.stroke;r&&-1!==r.indexOf("url(")&&t.style("stroke",r.replace(l,c))})),"pdf"!==e&&"eps"!==e""" =>
		raw""""pdf"!==e&&"eps"!==e""",
	raw"""return"&lt;"===t?"&#60;":"&rt;"===t?"&#62;":""" =>
		raw"""return"&quot;"===t?t:"&lt;"===t?"&#60;":"&rt;"===t?"&#62;":""",
	raw""".replace(u,"'"),i.isIE()&&(w=(w=(w=w.replace(/"/gi,"'"))""" =>
		raw""",i.isIE()&&(w=(w=(w=w.replace(/"/gi,"'"))""",
)
const _PLOTLYJS_COMPAT_TRANSFORMS = (
	_PLOTLYJS_MATH_FONT_SEAM => _PLOTLYJS_MATH_FONT_REPLACEMENT,
	_PLOTLYJS_SVG_QUOTE_TRANSFORMS...,
)

struct _PlotlyJSCompatAsset
	source::String
	directory::String
	path::String
	digest::String
end

mutable struct _PlotlyJSCompatAssetState
	lock::ReentrantLock
	asset::Union{Nothing,_PlotlyJSCompatAsset}
	unpublished::Set{String}
	atexit_registered::Bool
end
_PlotlyJSCompatAssetState() =
	_PlotlyJSCompatAssetState(ReentrantLock(), nothing, Set{String}(), false)
const _PLOTLYJS_COMPAT_ASSET_STATE = _PlotlyJSCompatAssetState()

_plotlyjs_text_digest(text::AbstractString) = bytes2hex(SHA.sha256(IOBuffer(text)))
_plotlyjs_file_digest(path::AbstractString) =
	open(io -> bytes2hex(SHA.sha256(io)), path)
_remove_plotlyjs_compat_directory(path) = rm(path; recursive = true, force = true)

function _patch_plotlyjs_math_fonts(source::AbstractString)
	patched = source
	for (needle, replacement) in _PLOTLYJS_COMPAT_TRANSFORMS
		count(needle, patched) == 1 || error("Plotly.js compatibility seam must occur exactly once")
		patched = replace(patched, needle => replacement; count = 1)
	end
	restored = patched
	for (needle, replacement) in reverse(_PLOTLYJS_COMPAT_TRANSFORMS)
		count(replacement, restored) == 1 || error("Plotly.js compatibility inverse seam must occur exactly once")
		restored = replace(restored, replacement => needle; count = 1)
	end
	restored == source || error("Plotly.js compatibility inverse did not restore the source")
	return patched
end

function _cleanup_plotlyjs_compat_asset!(
	state::_PlotlyJSCompatAssetState = _PLOTLYJS_COMPAT_ASSET_STATE;
	remove_directory = _remove_plotlyjs_compat_directory,
)
	lock(state.lock) do
		if state.asset !== nothing
			remove_directory(state.asset.directory)
			state.asset = nothing
		end
		for directory in collect(state.unpublished)
			remove_directory(directory)
			delete!(state.unpublished, directory)
		end
	end
	return nothing
end

function _register_plotlyjs_compat_cleanup!(state::_PlotlyJSCompatAssetState)
	state === _PLOTLYJS_COMPAT_ASSET_STATE || return
	state.atexit_registered && return
	atexit() do
		try
			_cleanup_plotlyjs_compat_asset!(state)
		catch err
			@warn "Failed to remove the owned Plotly.js compatibility asset." exception = (err, catch_backtrace())
		end
	end
	state.atexit_registered = true
	return nothing
end

function _plotlyjs_render_asset_path(;
	state::_PlotlyJSCompatAssetState = _PLOTLYJS_COMPAT_ASSET_STATE,
	source_path::AbstractString = _plotlyjs_asset_path(),
	cache_parent::AbstractString = tempdir(),
	write_file = write,
	remove_directory = _remove_plotlyjs_compat_directory,
)
	lock(state.lock) do
		source = read(source_path, String)
		_plotlyjs_text_digest(source) == _PLOTLYJS_MATH_FONT_SOURCE_SHA256 ||
			error("Unexpected Plotly.js source for math-font compatibility")
		license_path = joinpath(dirname(source_path), "LICENSE")
		license = read(license_path, String)
		_plotlyjs_text_digest(license) == _PLOTLYJS_LICENSE_SHA256 ||
			error("Unexpected Plotly.js license for math-font compatibility")
		if state.asset !== nothing
			asset = state.asset
			asset.source == abspath(source_path) || error("Plotly.js compatibility source changed")
			isfile(asset.path) && _plotlyjs_file_digest(asset.path) == asset.digest ||
				error("The owned Plotly.js compatibility asset changed or is missing")
			isfile(joinpath(asset.directory, "LICENSE")) &&
				_plotlyjs_file_digest(joinpath(asset.directory, "LICENSE")) == _PLOTLYJS_LICENSE_SHA256 ||
				error("The owned Plotly.js compatibility license changed or is missing")
			return asset.path
		end
		patched = _patch_plotlyjs_math_fonts(source)
		digest = _plotlyjs_text_digest(patched)
		_register_plotlyjs_compat_cleanup!(state)
		directory = mktempdir(cache_parent; prefix = "plotlysupply-render-", cleanup = false)
		push!(state.unpublished, directory)
		try
			staged = joinpath(directory, "plotly.part")
			staged_license = joinpath(directory, "LICENSE.part")
			write_file(staged, patched)
			write_file(staged_license, license)
			_plotlyjs_file_digest(staged) == digest || error("Incomplete Plotly.js compatibility write")
			_plotlyjs_file_digest(staged_license) == _PLOTLYJS_LICENSE_SHA256 || error("Incomplete Plotly.js license write")
			path = joinpath(directory, "plotly.min.js")
			Base.Filesystem.rename(staged, path)
			Base.Filesystem.rename(staged_license, joinpath(directory, "LICENSE"))
			state.asset = _PlotlyJSCompatAsset(abspath(source_path), directory, path, digest)
			delete!(state.unpublished, directory)
			return path
		catch
			try
				remove_directory(directory)
				delete!(state.unpublished, directory)
			catch cleanup_error
				@warn "Failed to remove an unpublished Plotly.js compatibility asset." directory exception = (cleanup_error, catch_backtrace())
			end
			rethrow()
		end
	end
end

_plotlyjs_render_asset_uri() = _file_uri(_plotlyjs_render_asset_path())

# The `<script>` element that carries Plotly.js `source` inline, preceded by its
# license notice as a comment.
function _plotlyjs_inline_script(source::AbstractString, license::AbstractString)
	occursin(r"</script"i, source) && error("Plotly.js contains a closing-script token and cannot be inlined")
	occursin("*/", license) && error("Plotly.js license cannot be placed in the inline notice")
	return "<script type=\"text/javascript\">\n/*\n" * license * "\n*/\n" * source * "\n</script>"
end

# The inline `<script>` of the compatibility-patched Plotly.js that desktop
# plots and image exports render with (HTML export embeds it instead of
# loading Plotly.js from the CDN, so a saved file draws exactly like them).
function _compatible_plotlyjs_inline_script()
	path = _plotlyjs_render_asset_path()
	return _plotlyjs_inline_script(read(path, String), read(joinpath(dirname(path), "LICENSE"), String))
end

function _inline_plotlyjs_source(html::AbstractString, source::AbstractString, license::AbstractString)
	tag = "<script src=\"$(_PLOTLY_CDN_URL)\"></script>"
	count(tag, html) == 1 || error("Expected exactly one Plotly.js CDN script in HTML export")
	script = _plotlyjs_inline_script(source, license)
	return replace(html, tag => script; count = 1)
end

function _inline_compatible_plotlyjs(html::AbstractString)
	tag = "<script src=\"$(_PLOTLY_CDN_URL)\"></script>"
	count(tag, html) == 1 || error("Expected exactly one Plotly.js CDN script in HTML export")
	path = _plotlyjs_render_asset_path()
	return _inline_plotlyjs_source(html, read(path, String),
		read(joinpath(dirname(path), "LICENSE"), String))
end
