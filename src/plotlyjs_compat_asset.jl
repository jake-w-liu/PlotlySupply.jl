import SHA

const _PLOTLYJS_MATH_FONT_SOURCE_SHA256 =
	"6d21266ce1bd7d9e5ab4e115989c70c20de0382fd973a8f26ab58619eba4d603"
const _PLOTLYJS_LICENSE_SHA256 =
	"67a26cf80f03ff388f26945dfc1f6caed1a0746ff43871190339b3aee49b94bb"
const _PLOTLYJS_MATH_FONT_SEAM =
	raw""".attr({"pointer-events":"none","data-unformatted":S,"data-math":"Y"});l.node()"""
const _PLOTLYJS_MATH_FONT_REPLACEMENT =
	raw""".attr({"pointer-events":"none","data-unformatted":S,"data-math":"Y"}).style({"font-family":t.node().style.fontFamily,"font-size":r+"px"});l.node()"""
# plotly.js reads a label's font size with parseInt before typesetting it, so
# a fractional size (8 pt = 10.667 px, every journal preset) typeset the math
# at 10 px while the plain labels beside it stay at 10.667 px (L9). The size
# is read whole.
const _PLOTLYJS_MATH_SIZE_SEAM =
	raw"""var r=parseInt(t.node().style.fontSize,10),o={fontSize:r}"""
const _PLOTLYJS_MATH_SIZE_REPLACEMENT =
	raw"""var r=parseFloat(t.node().style.fontSize),o={fontSize:r}"""
# legend.js computeTextDimensions measures and places the legend title's
# MathJax group with `scrollbox.select("g[class*=math-group]")`, which finds
# the group of the first math ENTRY when one comes earlier in the scroll box
# (tm-legend-math-title-clip, measured: the title group kept no transform and
# drew 8.3 px above the legend box, and the title height was the entry's).
# The title reads its own group (class "<legend id>titletext-math-group").
const _PLOTLYJS_LEGEND_TITLE_MATH_SEAM =
	raw"""var a=t.select("g[class*=math-group]"),o=a.node(),s=P(r);"""
const _PLOTLYJS_LEGEND_TITLE_MATH_REPLACEMENT =
	raw"""var a=t.select(n===b?"g[class*=titletext-math-group]":"g[class*=math-group]"),o=a.node(),s=P(r);"""
# plotly.js counts the lines of an axis title by its `<br>` tags only: in
# the automargin room (axes.js approxTitleDepth) and in the title's distance
# from the axis (drawTitle). A math title of several rows (`mathtext` writes
# them as one MathJax array, rows split by `\\`) got the room of one line,
# and its svg, which convertToTspans centres on the title's anchor, grew
# half its extra rows towards the tick labels (tm-twoline-math-axis-title,
# measured: the plot area kept its size for 2 and 3 rows and the x title
# drew 1.7 px into the tick labels under :ieee). Each extra row of a
# `$...$` title gets 1.6 em of room, and the title's anchor moves away from
# the axis by half of it: the svg of 2 and 3 rows measured 1.50 and 1.55 em
# per extra row under :ieee (Times), 1.86 and 1.64 em under :default.
const _PLOTLYJS_AXIS_TITLE_ROOM_SEAM =
	raw"""function St(t){var e=t.title.font.size,r=(t.title.text.match(c.BR_TAG_ALL)||[]).length;return t.title.hasOwnProperty("standoff")?e*(q+r*H):r?e*(r+1)*H:e}"""
const _PLOTLYJS_AXIS_TITLE_ROOM_REPLACEMENT =
	raw"""function St(t){var e=t.title.font.size,r=(t.title.text.match(c.BR_TAG_ALL)||[]).length,_m=/^\$[\s\S]*\$$/.test(t.title.text)?(t.title.text.match(/\\\\/g)||[]).length:0;return _m*1.6*e+(t.title.hasOwnProperty("standoff")?e*(q+r*H):r?e*(r+1)*H:e)}"""
const _PLOTLYJS_AXIS_TITLE_SHIFT_SEAM =
	raw"""}var p,d,m,g,y=Z.getPxPosition(t,e);"""
const _PLOTLYJS_AXIS_TITLE_SHIFT_REPLACEMENT =
	raw"""}/^\$[\s\S]*\$$/.test(e.title.text)&&(r+=(e.title.text.match(/\\\\/g)||[]).length*.8*o);var p,d,m,g,y=Z.getPxPosition(t,e);"""
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
# gl-axes3d pushes scene tick labels and axis titles out of the box by the
# constants tickPad = 18 and labelPad = 30 that no layout attribute reaches.
# A scene reads its own pair from `layout.meta["plotlysupply:gl3d"][scene id]`
# (written by PlotlySupply's 3-D framing, src/sci/scene3d.jl) and keeps the
# constants without it.
const _PLOTLYJS_GL3D_PAD_SEAM =
	raw"""o.prototype.merge=function(t,e){for(var r=this,o=0;o<3;++o){var s=e[a[o]];s.visible?("""
const _PLOTLYJS_GL3D_PAD_REPLACEMENT =
	raw"""o.prototype.merge=function(t,e){var _g=t.meta&&t.meta["plotlysupply:gl3d"],_h=_g&&e._scene&&_g[e._scene.id];for(var r=this,o=0;o<3;++o){var s=e[a[o]];_h&&_h.length>=2&&isFinite(_h[0])&&isFinite(_h[1])&&_h[0]>=0&&_h[1]>=0&&(r.tickPad[o]=+_h[0],r.labelPad[o]=+_h[1]);s.visible?("""
# Power-format tick labels (D21, vm-powerfmt). plotly.js takes the common
# exponent of a linear axis from the larger END of its range (axes.js
# autoTickRound), so ticks 2000 ... 8000 on a range that ends at 1.04e4 read
# "0.2×10^4" ... "0.8×10^4", and a tick below the largest tick's decade
# (5000 next to 15000) reads "0.5×10^4". A journal figure never prints a
# mantissa below 1. (a) The exponent of a linear axis (colorbars included)
# is taken from its largest tick inside the range (the range end when no
# tick lies inside), so 2000 ... 8000 print plainly, as matplotlib does.
# (b) Under exponentformat = "power" every tick label that carries an
# exponent is written with its own decade, so its mantissa is in [1, 10):
# "5×10^3", "1×10^4", "1.5×10^4". Hover labels and the other formats keep
# plotly's text.
const _PLOTLYJS_POWER_EXPONENT_SEAM =
	raw"""var l=Math.max(Math.abs(s[0]),Math.abs(s[1])),c=Math.floor(Math.log(l)/Math.LN10+.01),u=void 0===t.minexponent?3:t.minexponent;"""
const _PLOTLYJS_POWER_EXPONENT_REPLACEMENT =
	raw"""var l=Math.max(Math.abs(s[0]),Math.abs(s[1]));if("linear"===t.type&&i(e)&&e>0&&isFinite(s[0])&&isFinite(s[1])){var _p0=i(t.tick0)?+t.tick0:0,_pa=_p0+Math.ceil((Math.min(s[0],s[1])-_p0)/e-1e-9)*e,_pb=_p0+Math.floor((Math.max(s[0],s[1])-_p0)/e+1e-9)*e,_pm=Math.max(Math.abs(_pa),Math.abs(_pb));_pa<=_pb&&_pm>0&&isFinite(_pm)&&(l=_pm)}var c=Math.floor(Math.log(l)/Math.LN10+.01),u=void 0===t.minexponent?3:t.minexponent;"""
const _PLOTLYJS_POWER_MANTISSA_SEAM =
	raw"""if(t+=d,c&&(t*=Math.pow(10,-c),o+=c),0===o)"""
const _PLOTLYJS_POWER_MANTISSA_REPLACEMENT =
	raw"""if(t+=d,c&&"power"===l&&!n&&t>0&&isFinite(t)&&(c=Math.min(c,Math.floor(Math.log(t)/Math.LN10+1e-9))),c&&(t*=Math.pow(10,-c),o+=c),0===o)"""
# apia-11: text and hover templates ("%{z:.2f}" in plot_matrix cells) format
# numbers through the figure's d3 locale, whose minus sign is the ASCII
# hyphen in plotly.js' d3-format 1.4, while plotly's own tick and colorbar
# labels print U+2212. The locale's minus is U+2212 unless the locale gives
# one, so every number of a figure is written with the same glyph.
const _PLOTLYJS_LOCALE_MINUS_SEAM =
	raw"""s._d3locale=function(t,e){return t.decimal=e.charAt(0),t.thousands=e.charAt(1),{numberFormat:"""
const _PLOTLYJS_LOCALE_MINUS_REPLACEMENT =
	raw"""s._d3locale=function(t,e){return t.decimal=e.charAt(0),t.thousands=e.charAt(1),void 0===t.minus&&(t.minus="−"),{numberFormat:"""
# V4 (lead visual review): plotly.js counts a layout shape in the autorange of
# a data axis without padding (shapes/calc_autorange.js), so a reference line
# (hline!/vline!, any line spanning its cell: drawn from 0 to 1 of the other
# axis's domain or the paper) below the data lands on the frame, where it
# cannot be seen (gallery log_bars (b): the 0.8 floor on the bottom spine).
# Such a line is padded like data, as matplotlib's axhline/axvline, which
# join the data limits before the margins are added; a range the user fixes
# is never changed.
const _PLOTLYJS_SHAPE_PAD_SEAM =
	raw"""function s(t){return c(t.line.width,t.xsizemode,t.x0,t.x1,t.path,!1)}function l(t){return c(t.line.width,t.ysizemode,t.y0,t.y1,t.path,!0)}"""
const _PLOTLYJS_SHAPE_PAD_REPLACEMENT =
	raw"""function s(t){var _s=c(t.line.width,t.xsizemode,t.x0,t.x1,t.path,!1);return"line"===t.type&&"scaled"===t.xsizemode&&t.x0===t.x1&&/(domain|paper)$/.test(String(t.yref))&&(_s.padded=!0),_s}function l(t){var _s=c(t.line.width,t.ysizemode,t.y0,t.y1,t.path,!0);return"line"===t.type&&"scaled"===t.ysizemode&&t.y0===t.y1&&/(domain|paper)$/.test(String(t.xref))&&(_s.padded=!0),_s}"""
# D24 (axis-title gap, src/sci/axes.jl `_axes_title_gap_updates!`): an axis
# whose `title.standoff` is the one recorded in
# `layout.meta["plotlysupply:titlegap"]` (axis name => [standoff, gap px])
# asks for its title box to sit exactly `gap` px beyond the union of its tick
# label boxes. plotly.js places a title by formula (baseline or centre line
# `standoff` px past the labels' depth), so the box gap depends on the font,
# the side and, for MathJax, on the expression; it then only pushes a title
# out of the labels it overlaps (`titles.draw` avoid, scootTitle). The first
# seam hands the recorded gap to the title's avoid options; the second
# measures, once the title is drawn, the rendered boxes of the title and of
# every tick label (getBoundingClientRect, scaled to layout px: Drawing.bBox
# measures a detached clone, which misses a MathJax title's glyph sizes by up
# to 3 px) and moves the title to the gap, nearer or further, never beyond
# the paper (its `maxShift`). Every other title is placed as before.
const _PLOTLYJS_TITLE_GAP_SEAM =
	raw"""e.title.hasOwnProperty("standoff")&&(g.pad=0)}return e._titleStandoff=r,u.draw"""
const _PLOTLYJS_TITLE_GAP_REPLACEMENT =
	raw"""e.title.hasOwnProperty("standoff")&&(g.pad=0);var _G=n.meta&&n.meta["plotlysupply:titlegap"],_g=_G&&_G[e._name];Array.isArray(_g)&&_g[0]===e.title.standoff&&"number"==typeof _g[1]&&isFinite(_g[1])&&(g.gap=_g[1])}return e._titleStandoff=r,u.draw"""
const _PLOTLYJS_TITLE_SCOOT_SEAM =
	raw"""T=b.maxShift||u*(w[b.side]-f[b.side]),k=0;if(T<0)k=T;else{var A=b.offsetLeft||0,M=b.offsetTop||0;f.left-=A,f.right-=A,f.top-=M,f.bottom-=M,b.selection.each((function(){var t=c.bBox(this);s.bBoxIntersect(f,t,h)&&(k=Math.max(k,u*(t[b.side]-f[o])+h))})),k=Math.min(T,k),y._titleScoot=Math.abs(k)}if(k>0||T<0){"""
const _PLOTLYJS_TITLE_SCOOT_REPLACEMENT =
	raw"""T,k=0;if(i(b.gap)){var _r=a.node().getBoundingClientRect(),_p=g._paper.node().getBoundingClientRect(),_q=_p.width>0?g.width/_p.width:1,_f={left:(_r.left-_p.left)*_q,right:(_r.right-_p.left)*_q,top:(_r.top-_p.top)*_q,bottom:(_r.bottom-_p.top)*_q},_k=-1/0;T=b.maxShift||u*(w[b.side]-_f[b.side]),b.selection.each((function(){var t=this.getBoundingClientRect();t.width>0&&t.height>0&&(_k=Math.max(_k,u*(t[b.side]-_r[o])))})),k=isFinite(_k)?Math.min(T,_k*_q+b.gap):0,y._titleScoot=Math.max(k,0)}else if((T=b.maxShift||u*(w[b.side]-f[b.side]))<0)k=T;else{var A=b.offsetLeft||0,M=b.offsetTop||0;f.left-=A,f.right-=A,f.top-=M,f.bottom-=M,b.selection.each((function(){var t=c.bBox(this);s.bBoxIntersect(f,t,h)&&(k=Math.max(k,u*(t[b.side]-f[o])+h))})),k=Math.min(T,k),y._titleScoot=Math.abs(k)}if(0!==k){"""
const _PLOTLYJS_COMPAT_TRANSFORMS = (
	_PLOTLYJS_MATH_FONT_SEAM => _PLOTLYJS_MATH_FONT_REPLACEMENT,
	_PLOTLYJS_MATH_SIZE_SEAM => _PLOTLYJS_MATH_SIZE_REPLACEMENT,
	_PLOTLYJS_LEGEND_TITLE_MATH_SEAM => _PLOTLYJS_LEGEND_TITLE_MATH_REPLACEMENT,
	_PLOTLYJS_AXIS_TITLE_ROOM_SEAM => _PLOTLYJS_AXIS_TITLE_ROOM_REPLACEMENT,
	_PLOTLYJS_AXIS_TITLE_SHIFT_SEAM => _PLOTLYJS_AXIS_TITLE_SHIFT_REPLACEMENT,
	_PLOTLYJS_GL3D_PAD_SEAM => _PLOTLYJS_GL3D_PAD_REPLACEMENT,
	_PLOTLYJS_POWER_EXPONENT_SEAM => _PLOTLYJS_POWER_EXPONENT_REPLACEMENT,
	_PLOTLYJS_POWER_MANTISSA_SEAM => _PLOTLYJS_POWER_MANTISSA_REPLACEMENT,
	_PLOTLYJS_LOCALE_MINUS_SEAM => _PLOTLYJS_LOCALE_MINUS_REPLACEMENT,
	_PLOTLYJS_SHAPE_PAD_SEAM => _PLOTLYJS_SHAPE_PAD_REPLACEMENT,
	_PLOTLYJS_TITLE_GAP_SEAM => _PLOTLYJS_TITLE_GAP_REPLACEMENT,
	_PLOTLYJS_TITLE_SCOOT_SEAM => _PLOTLYJS_TITLE_SCOOT_REPLACEMENT,
	_PLOTLYJS_SVG_QUOTE_TRANSFORMS...,
)

# `stamp` is the (size, mtime) of the four files the asset depends on (source,
# source LICENSE, patched copy, copied LICENSE) as of the last full integrity
# check; `script` memoises the inline `<script>` text of the HTML export for
# that stamp. A call whose files still carry the stamp skips the read, hash and
# regex work (about 90 ms for the 4.4 MB text); a changed stamp falls back to
# the full digest check.
mutable struct _PlotlyJSCompatAsset
	source::String
	directory::String
	path::String
	digest::String
	stamp::Vector{Tuple{Int64,Float64}}
	script::Union{Nothing,String}
end
_PlotlyJSCompatAsset(source, directory, path, digest) =
	_PlotlyJSCompatAsset(source, directory, path, digest, Tuple{Int64,Float64}[], nothing)

function _plotlyjs_stamp(paths)
	stamp = Tuple{Int64,Float64}[]
	for path in paths
		st = stat(path)
		push!(stamp, (Int64(st.size), Float64(st.mtime)))
	end
	return stamp
end
_plotlyjs_asset_files(asset::_PlotlyJSCompatAsset) =
	(asset.source, joinpath(dirname(asset.source), "LICENSE"), asset.path, joinpath(asset.directory, "LICENSE"))

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
		if state.asset !== nothing
			asset = state.asset
			asset.source == abspath(source_path) || error("Plotly.js compatibility source changed")
			isempty(asset.stamp) || _plotlyjs_stamp(_plotlyjs_asset_files(asset)) == asset.stamp &&
				return asset.path
		end
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
			asset.stamp = _plotlyjs_stamp(_plotlyjs_asset_files(asset))
			asset.script = nothing
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
			asset = _PlotlyJSCompatAsset(abspath(source_path), directory, path, digest)
			asset.stamp = _plotlyjs_stamp(_plotlyjs_asset_files(asset))
			state.asset = asset
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
# The text is memoised on the asset (one 4.4 MB string per session) and rebuilt
# when the integrity check saw a changed stamp.
function _compatible_plotlyjs_inline_script(; state::_PlotlyJSCompatAssetState = _PLOTLYJS_COMPAT_ASSET_STATE)
	path = _plotlyjs_render_asset_path(; state)
	lock(state.lock) do
		asset = state.asset
		asset === nothing && error("The Plotly.js compatibility asset is not available")
		script = asset.script
		if script === nothing || asset.path != path
			script = _plotlyjs_inline_script(read(path, String), read(joinpath(dirname(path), "LICENSE"), String))
			asset.script = script
		end
		return script
	end
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
