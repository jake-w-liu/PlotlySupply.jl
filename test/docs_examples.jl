# Documentation tests: every ```julia block of README.md, CHANGELOG.md and
# docs/src/*.md runs on the current code, and the claims the docs make about
# the API (keyword tables, the function overview, the API reference coverage,
# the matrix orientation of the examples) are checked against the package.
#
# A block whose first line is `# fragment` (optionally followed by a reason,
# e.g. `# fragment: opens a window`) is not run: use it for snippets that open
# windows, install packages or show a pattern with placeholder names.
#
# Runs inside test/runtests.jl or on its own:
#     julia --project=. test/docs_examples.jl

isdefined(@__MODULE__, :_PLOTLYSUPPLY_TESTUTILS) || include("testutils.jl")
using Test, PlotlySupply

const _DOCS_ROOT = normpath(joinpath(@__DIR__, ".."))
const _DOCS_SRC = joinpath(_DOCS_ROOT, "docs", "src")

_docs_read(rel::AbstractString) = read(joinpath(_DOCS_ROOT, rel), String)

# Every documentation file whose code blocks must run, relative to the package root.
function _docs_files()
	files = ["README.md", "CHANGELOG.md"]
	for name in sort!(readdir(_DOCS_SRC))
		endswith(name, ".md") && push!(files, joinpath("docs", "src", name))
	end
	return files
end

struct _DocsBlock
	file::String   # path relative to the package root
	line::Int      # line number of the first code line (after the fence)
	code::String
end

# Split a Markdown file into its ```julia blocks. Fences must start at column 1;
# an unterminated block is an error, so a broken fence cannot hide code.
function _docs_blocks(rel::AbstractString)
	lines = split(_docs_read(rel), '\n')
	blocks = _DocsBlock[]
	i = 1
	while i <= length(lines)
		if occursin(r"^```julia\s*$", lines[i])
			start = i + 1
			j = start
			while j <= length(lines) && !occursin(r"^```\s*$", lines[j])
				j += 1
			end
			j > length(lines) && error("$(rel):$(i): unterminated ```julia block")
			push!(blocks, _DocsBlock(String(rel), start, join(lines[start:j-1], '\n')))
			i = j + 1
		else
			i += 1
		end
	end
	return blocks
end

_docs_is_fragment(b::_DocsBlock) = occursin(r"^\s*#\s*fragment\b", b.code)

# Package-wide settings the examples may change; reset before and after each
# file so the files do not depend on each other or on the rest of the suite.
function _docs_reset_defaults()
	set_default_style!(:default)
	set_default_mathtext!()
	set_default_template!()
	set_default_legend_position!()
	return nothing
end

# Evaluate `b` in `mod` with the file's own line numbers in errors and backtraces.
function _docs_eval(mod::Module, b::_DocsBlock)
	Base.include_string(mod, "\n"^(b.line - 1) * b.code, b.file)
	return true
end

function _docs_new_module()
	mod = Module(gensym(:DocsExample))
	Core.eval(mod, :(using PlotlySupply))
	return mod
end

# Run the blocks of each file in order, in one fresh module per file, inside a
# temporary directory so that files written by `savefig` land there.
@testset "documentation examples run" begin
	for rel in _docs_files()
		blocks = filter(!_docs_is_fragment, _docs_blocks(rel))
		isempty(blocks) && continue
		@testset "$(rel)" begin
			mod = _docs_new_module()
			_docs_reset_defaults()
			try
				mktempdir() do dir
					cd(dir) do
						for b in blocks
							@testset "$(b.file):$(b.line)" begin
								@test _docs_eval(mod, b)
							end
						end
					end
				end
			finally
				_docs_reset_defaults()
			end
		end
	end
end

@testset "fragments are marked with a reason" begin
	for rel in _docs_files(), b in _docs_blocks(rel)
		_docs_is_fragment(b) || continue
		# `# fragment: <reason>` - an unexplained skip hides an untested example.
		@test occursin(r"^\s*#\s*fragment:\s*\S", b.code)
	end
end

# Audit #287 / X34: matrices are U[ix, iy]. A comprehension that loops over y
# first builds U[iy, ix], which is transposed for plot_heatmap and friends.
@testset "examples build matrices as U[ix, iy]" begin
	transposed = r"for\s+y\w*\s+in\s+[^,\]]+,\s*x\w*\s+in"
	for rel in _docs_files()
		text = _docs_read(rel)
		for (k, line) in enumerate(split(text, '\n'))
			if occursin(transposed, line)
				@error "transposed comprehension (y outer, x inner) in $(rel):$(k)" line
				@test false
			end
		end
	end
	# The documented convention, on a non-square grid.
	x = 1:3
	y = 1:2
	U = [10xi + yj for xi in x, yj in y]
	for ctor in (plot_heatmap, plot_contour)
		@test Matrix(only(ctor(x, y, U).data).fields[:z]) == [11 21 31; 12 22 32]
	end
	@test_throws ArgumentError plot_heatmap(x, y, permutedims(U))
end

# --- keyword tables (audit #251, #293, #306; Y16) -------------------------------------

# Minimal valid arguments for every exported constructor, so that keyword
# acceptance is checked by calling the function (several constructors take
# `kwargs...` and validate them at run time).
const _DOCS_O = [1.0, 2, 3, 4]
const _DOCS_GEO = Dict(
	"type" => "FeatureCollection",
	"features" => [Dict(
		"type" => "Feature", "id" => "a", "properties" => Dict{String,Any}(),
		"geometry" => Dict("type" => "Polygon",
			"coordinates" => [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 0.0]]]),
	)],
)
const _DOCS_G = range(0.0, 1.0; length = 3)
const _DOCS_GX = vec([x for x in _DOCS_G, y in _DOCS_G, z in _DOCS_G])
const _DOCS_GY = vec([y for x in _DOCS_G, y in _DOCS_G, z in _DOCS_G])
const _DOCS_GZ = vec([z for x in _DOCS_G, y in _DOCS_G, z in _DOCS_G])
const _DOCS_TX = [0.0, 1, 0, 1]
const _DOCS_TY = [0.0, 0, 1, 1]
const _DOCS_TRI = [1 2 3; 2 4 3]
const _DOCS_S = range(0.0, 1.0; length = 5)
const _DOCS_CTOR_ARGS = Dict{Symbol,Tuple}(
	:plot_area => (1:3, [1.0, 2, 3]),
	:plot_band => (1:3, zeros(3), [1.0, 2, 3]),
	:plot_bar => ([1.0, 2, 3],),
	:plot_box => ([1.0, 2, 3],),
	:plot_candlestick => (1:4, _DOCS_O, _DOCS_O .+ 1, _DOCS_O .- 1, _DOCS_O .+ 0.5),
	:plot_choropleth => (["USA", "CAN"], [1.0, 2.0]),
	:plot_choroplethmap => (_DOCS_GEO, ["a"], [1.0]),
	:plot_choroplethmapbox => (_DOCS_GEO, ["a"], [1.0]),
	:plot_complex => ([1.0 + 1im, 2.0 + 0im],),
	:plot_contour => (rand(3, 3),),
	:plot_densitymap => ([0.0, 1.0], [0.0, 1.0]),
	:plot_densitymapbox => ([0.0, 1.0], [0.0, 1.0], [1.0, 2.0]),
	:plot_ecdf => ([1.0, 2, 3],),
	:plot_funnel => ([3.0, 2, 1], ["a", "b", "c"]),
	:plot_funnelarea => ([3.0, 2, 1],),
	:plot_heatmap => (rand(3, 3),),
	:plot_histogram => ([1.0, 2, 3],),
	:plot_histogram2d => ([1.0, 2, 3], [1.0, 2, 3]),
	:plot_hlines => ([1.0, 2.0], 0.0, 1.0),
	:plot_image => (rand(4, 4, 3),),
	:plot_indicator => (5,),
	:plot_isosurface => (_DOCS_GX, _DOCS_GY, _DOCS_GZ, _DOCS_GX .+ _DOCS_GY),
	:plot_kde => ([1.0, 2, 3, 4],),
	:plot_matrix => (rand(3, 3),),
	:plot_mesh3d => ([0.0, 1, 0], [0.0, 0, 1], [0.0, 0, 0]),
	:plot_ohlc => (1:4, _DOCS_O, _DOCS_O .+ 1, _DOCS_O .- 1, _DOCS_O .+ 0.5),
	:plot_parcoords => (["a" => [1.0, 2], "b" => [2.0, 1]],),
	:plot_pcolormesh => (0:3, 0:2, rand(3, 2)),
	:plot_pie => ([1.0, 2],),
	:plot_polygons => ([[0.0, 1, 0]], [[0.0, 0, 1]], [1.0]),
	:plot_polygons3d => ([0.0, 1, 0], [0.0, 0, 1], [0.0, 0, 0], [[1, 2, 3]], [1.0]),
	:plot_quiver => ([0.0, 1], [0.0, 1], [1.0, 1], [0.0, 1]),
	:plot_quiver3d => ([0.0], [0.0], [0.0], [1.0], [0.0], [0.0]),
	:plot_sankey => ([0], [1], [1.0]),
	:plot_scatter => (1:3, [1.0, 2, 3]),
	:plot_scatter3d => ([0.0, 1], [0.0, 1], [0.0, 1]),
	:plot_scattergeo => ([0.0], [0.0]),
	:plot_scattermap => ([0.0], [0.0]),
	:plot_scattermapbox => ([0.0], [0.0]),
	:plot_scatterpolar => ([0, 90], [1.0, 2]),
	:plot_segments => ([0.0], [0.0], [1.0], [1.0]),
	:plot_segments3d => ([0.0], [0.0], [0.0], [1.0], [1.0], [1.0]),
	:plot_stem => ([1.0, 2, 3],),
	:plot_streamlines => (_DOCS_S, _DOCS_S, [-y for x in _DOCS_S, y in _DOCS_S], [x for x in _DOCS_S, y in _DOCS_S]),
	:plot_streamtube => (_DOCS_GX, _DOCS_GY, _DOCS_GZ, ones(27), zeros(27), zeros(27)),
	:plot_sunburst => (["a", "b"], ["", "a"]),
	:plot_surface => (rand(3, 3),),
	:plot_ternary => ([1.0], [1.0], [1.0]),
	:plot_treemap => (["a", "b"], ["", "a"]),
	:plot_tricontour => (_DOCS_TX, _DOCS_TY, _DOCS_TRI, [0.0, 1, 1, 2]),
	:plot_tripcolor => (_DOCS_TX, _DOCS_TY, _DOCS_TRI, [0.0, 1, 1, 2]),
	:plot_triplot => (_DOCS_TX, _DOCS_TY, _DOCS_TRI),
	:plot_violin => ([1.0, 2, 3],),
	:plot_vlines => ([1.0, 2.0], 0.0, 1.0),
	:plot_volume => (_DOCS_GX, _DOCS_GY, _DOCS_GZ, _DOCS_GX .+ _DOCS_GY),
	:plot_waterfall => (["a", "b"], [1.0, 2]),
	:plot_wireframe => (0:2, 0:2, rand(3, 3)),
)

# A value of the right type for every keyword the tables name.
const _DOCS_KW_VALUE = Dict{Symbol,Any}(
	:title => "t", :width => 400, :height => 300, :fontsize => 12, :show => false,
	:xlabel => "x", :ylabel => "y", :zlabel => "z", :grid => false,
	:xrange => [0, 1], :yrange => [0, 1], :zrange => [0, 1],
	:xscale => "linear", :yscale => "linear",
	:xticks => [0, 1], :yticks => [0, 1], :xticklabels => ["a", "b"], :yticklabels => ["a", "b"],
	:xtickformat => ".1f", :ytickformat => ".1f", :equalar => true, :tight => false,
	:legend => "L", :showlegend => true, :color => "red", :opacity => 0.5,
	:mode => "lines", :dash => "dash", :linewidth => 2, :marker_size => 5, :marker_symbol => "circle",
	:colorscale => "viridis", :crange => [0, 1], :cmid => 0.5, :colornorm => :linear,
	:showscale => false, :colorbar_title => "c",
	:aspectmode => "cube", :perspective => false, :showaxis => false, :view => (30, -60),
	:trange => [0, 90], :rrange => [0, 2], :rlabel_angle => 45, :thetaunit => "degrees",
	:direction => "clockwise", :rotation => 90,
)

const _DOCS_CONSTRUCTORS = sort!([n for n in names(PlotlySupply)
	if startswith(string(n), "plot_") && !endswith(string(n), "!")])

# true when `ctor` accepts keyword `kw`: the call succeeds, or fails for a
# reason other than an unknown keyword (e.g. `xticklabels` without `xticks`).
function _docs_accepts(ctor::Symbol, kw::Symbol)
	f = getfield(PlotlySupply, ctor)
	try
		f(_DOCS_CTOR_ARGS[ctor]...; (kw => _DOCS_KW_VALUE[kw],)...)
		return true
	catch err
		err isa MethodError && return false
		msg = sprint(showerror, err)
		if err isa ArgumentError && occursin(r"unsupported keyword|unknown keyword", msg) &&
				occursin(string(kw), msg)
			return false
		end
		return true
	end
end

_docs_backticked(s::AbstractString) =
	[String(m.captures[1]) for m in eachmatch(r"`(@?[A-Za-z_][A-Za-z0-9_]*!?)", s)]

# The family definitions: lines `- **<family> constructors:** `plot_a`, `plot_b`, ...`.
function _docs_families(text::AbstractString)
	fam = Dict{String,Vector{Symbol}}()
	for m in eachmatch(r"(?m)^- \*\*(.+?) constructors:\*\* (.+)$", text)
		fam[m.captures[1]] = Symbol.(_docs_backticked(m.captures[2]))
	end
	fam["every"] = copy(_DOCS_CONSTRUCTORS)
	return fam
end

# Rows of the table under the heading "Common keywords": (keywords, accepted-by, except).
function _docs_keyword_rows(text::AbstractString)
	start = findfirst("## Common keywords", text)
	start === nothing && error("no \"## Common keywords\" section")
	rest = text[last(start)+1:end]
	stop = findfirst(r"\n## ", rest)
	section = stop === nothing ? rest : rest[1:first(stop)-1]
	rows = Tuple{Vector{Symbol},String,Vector{Symbol}}[]
	for line in split(section, '\n')
		startswith(line, "| `") || continue
		cells = strip.(split(strip(line, '|'), '|'))
		length(cells) == 4 || error("keyword table row must have 4 cells: $(line)")
		push!(rows, (Symbol.(_docs_backticked(cells[1])), String(cells[3]), Symbol.(_docs_backticked(cells[4]))))
	end
	return section, rows
end

function _docs_family_members(families, accepted_by::AbstractString)
	if startswith(accepted_by, "every")
		return families["every"]
	end
	listed = Symbol.(_docs_backticked(accepted_by))
	isempty(listed) || return listed
	for (name, members) in families
		occursin(name, accepted_by) && return members
	end
	error("unknown family in keyword table: $(accepted_by)")
end

@testset "keyword tables match the constructors" begin
	@test Set(keys(_DOCS_CTOR_ARGS)) == Set(_DOCS_CONSTRUCTORS)
	for ctor in _DOCS_CONSTRUCTORS
		@test (getfield(PlotlySupply, ctor)(_DOCS_CTOR_ARGS[ctor]...); true)
	end
	sections = String[]
	for rel in ("README.md", "docs/src/index.md")
		text = _docs_read(rel)
		families = _docs_families(text)
		@test haskey(families, "2-D Cartesian") && haskey(families, "3-D") && haskey(families, "Colour-mapped")
		for members in values(families), f in members
			@test f in _DOCS_CONSTRUCTORS
		end
		section, rows = _docs_keyword_rows(text)
		push!(sections, String(strip(section)))
		@test length(rows) >= 10
		for (kws, accepted_by, except) in rows
			members = _docs_family_members(families, accepted_by)
			for f in except
				@test f in members
			end
			for kw in kws, f in members
				expected = !(f in except)
				ok = _docs_accepts(f, kw) == expected
				ok || @error "$(rel): keyword table says `$(f)` $(expected ? "accepts" : "rejects") `$(kw)`"
				@test ok
			end
		end
	end
	# README and the manual's index carry the same table (#293: they had drifted).
	@test sections[1] == sections[2]
	# Y16: the exceptions the audit named explicitly.
	@test !_docs_accepts(:plot_histogram2d, :legend)
	@test !_docs_accepts(:plot_complex, :xscale)
	for kw in (:xlabel, :xrange, :xscale)
		@test !_docs_accepts(:plot_scatterpolar, kw)
	end
	@test _docs_accepts(:plot_scatterpolar, :trange) && _docs_accepts(:plot_scatterpolar, :rlabel_angle)
end

# --- function overview and API reference --------------------------------------------

# Exported names with a docstring written in PlotlySupply (re-exported PlotlyBase
# names are documented on the compatibility page instead).
function _docs_own_names()
	meta = Base.Docs.meta(PlotlySupply)
	own = Symbol[]
	for n in names(PlotlySupply)
		n === :PlotlySupply && continue
		b = Base.Docs.Binding(PlotlySupply, n)
		b.mod === PlotlySupply && haskey(meta, b) && push!(own, n)
	end
	return sort!(own)
end

@testset "README function overview lists every export once" begin
	text = _docs_read("README.md")
	start = findfirst("## Function overview", text)
	@test start !== nothing
	rest = text[last(start)+1:end]
	stop = findfirst(r"\n## ", rest)
	section = rest[1:first(stop)-1]
	mentioned = _docs_backticked(section)
	own = _docs_own_names()
	exported = Set(names(PlotlySupply))
	for n in own
		c = count(==(string(n)), mentioned)
		c == 1 || @error "README overview mentions `$(n)` $(c) times"
		@test c == 1
	end
	for m in mentioned
		ok = Symbol(m) in exported
		ok || @error "README overview mentions `$(m)`, which PlotlySupply does not export"
		@test ok
	end
end

@testset "API reference covers every export exactly once" begin
	text = _docs_read("docs/src/api.md")
	listed = Symbol[]
	for m in eachmatch(r"(?s)```@docs\n(.*?)\n```", text)
		for line in split(m.captures[1], '\n')
			s = strip(line)
			isempty(s) || push!(listed, Symbol(s))
		end
	end
	own = _docs_own_names()
	for n in own
		c = count(==(n), listed)
		c == 1 || @error "docs/src/api.md lists `$(n)` $(c) times"
		@test c == 1
	end
	# Nothing else, except the module itself.
	@test isempty(setdiff(Set(listed), Set(own), Set([:PlotlySupply])))
	# No other page has @docs blocks (Documenter rejects a docstring included twice).
	for name in readdir(_DOCS_SRC)
		(endswith(name, ".md") && name != "api.md") || continue
		@test !occursin("```@docs", read(joinpath(_DOCS_SRC, name), String))
	end
end

# --- audit #307 / Y8: the subplots showcase ------------------------------------------

@testset "subplots showcase targets the intended cells" begin
	for rel in ("README.md", "docs/src/index.md")
		showcase = filter(b -> occursin("legend = \"run A\"", b.code), _docs_blocks(rel))
		@test length(showcase) == 1
		mod = _docs_new_module()
		_docs_reset_defaults()
		@test _docs_eval(mod, only(showcase))
		sf = Base.invokelatest(getfield, mod, :sf)
		lay = sf.fig.layout
		# The axis helpers ran while cell (1, 1) - the 100-point line - was active.
		@test lay[:xaxis][:title][:text] == "time"
		@test lay[:yaxis][:title][:text] == "value"
		@test lay[:xaxis][:range] == [0, 100]
		@test get(lay[:xaxis4], :title, nothing) === nothing
		# The contour (cell 2, 1) and heatmap (cell 2, 2) colorbars sit next to their own cells.
		contour = only(filter(t -> t.fields[:type] == "contour", sf.fig.data))
		heatmap = only(filter(t -> t.fields[:type] == "heatmap", sf.fig.data))
		@test contour.fields[:colorbar][:x] < heatmap.fields[:colorbar][:x]
	end
end

# --- wave 5b: the touch-up pass -------------------------------------------------------

# Keyword names a docstring's signature block declares after the `;`.
function _docs_signature_keywords(doc::AbstractString, name::Symbol)
	m = match(r"(?s)^```julia\n(.*?)\n```", doc)
	m === nothing && return Set{Symbol}()
	sigs = String[]
	cur = ""
	for l in split(m.captures[1], '\n')
		if occursin(Regex("^\\s*" * string(name) * "\\("), l) || (!isempty(cur) && !occursin(r"\)\s*(->.*)?$", cur))
			cur = isempty(cur) ? String(l) : cur * " " * l
			if occursin(r"\)\s*(->.*)?$", cur)
				push!(sigs, cur)
				cur = ""
			end
		end
	end
	kws = Set{Symbol}()
	for sig in sigs
		i = findfirst(';', sig)
		i === nothing && continue
		rest = sig[i+1:end]
		j = findlast(')', rest)
		j === nothing || (rest = rest[1:j-1])
		depth = 0
		start = 1
		parts = String[]
		for (k, c) in enumerate(rest)
			if c in "([{"
				depth += 1
			elseif c in ")]}"
				depth -= 1
			elseif c == ',' && depth == 0
				push!(parts, rest[start:k-1])
				start = k + 1
			end
		end
		push!(parts, rest[start:end])
		for p in strip.(parts)
			(isempty(p) || endswith(p, "...")) && continue
			mm = match(r"^([A-Za-z_][A-Za-z0-9_]*)", p)
			mm === nothing || push!(kws, Symbol(mm.captures[1]))
		end
	end
	return kws
end

# Keyword names of every method of `f` (without the slurp), and whether one slurps.
function _docs_method_keywords(f)
	kws = Set{Symbol}()
	slurp = false
	for m in methods(f), k in Base.kwarg_decl(m)
		endswith(string(k), "...") ? (slurp = true) : push!(kws, k)
	end
	return kws, slurp
end

@testset "docstring keyword lists match the signatures" begin
	checked = 0
	for n in _docs_own_names()
		f = getfield(PlotlySupply, n)
		f isa Function || continue
		doc = string(Base.Docs.doc(Base.Docs.Binding(PlotlySupply, n)))
		keywords, slurps = _docs_method_keywords(f)
		# A mutator's docstring may refer to its constructor's keyword list.
		if endswith(string(n), "!") && isdefined(PlotlySupply, Symbol(chop(string(n))))
			doc *= string(Base.Docs.doc(Base.Docs.Binding(PlotlySupply, Symbol(chop(string(n))))))
		end
		# `show` is declared by mutators only to reject it with a clear message.
		undocumented = sort!([k for k in setdiff(keywords, Set([:show, :kwargs])) if
			!(occursin("`$(k)", doc) || occursin("$(k) =", doc) || occursin("$(k)=", doc))])
		listed = slurps ? Symbol[] : sort!(collect(setdiff(_docs_signature_keywords(doc, n), keywords, Set([:kwargs]))))
		ok = isempty(undocumented) && isempty(listed)
		ok || @error "docstring of `$(n)`: undocumented keywords $(undocumented), listed but not accepted $(listed)"
		@test ok
		checked += 1
	end
	@test checked > 150
end

# Archetype table of docs/src/matplotlib.md: every right-hand side runs on the block's data.
@testset "matplotlib archetype table runs" begin
	text = _docs_read("docs/src/matplotlib.md")
	i = findfirst("## Figure archetypes from real projects", text)
	@test i !== nothing
	section = text[first(i):end]
	data = match(r"(?s)```julia\n(.*?)\n```", section).captures[1]
	rows = String[]
	for line in split(section, '\n')
		startswith(line, "| ") || continue
		cells = split(line, r"(?<!\\)\|")
		length(cells) >= 4 || continue
		cell = strip(cells[3])
		(startswith(cell, "`") && endswith(cell, "`")) || continue
		push!(rows, replace(cell[2:end-1], "\\|" => "|"))
	end
	@test length(rows) >= 40
	mktempdir() do dir
		cd(dir) do
			for (k, code) in enumerate(rows)
				mod = _docs_new_module()
				@testset "row $(k)" begin
					@test (Base.include_string(mod, data, "matplotlib.md"); Base.include_string(mod, code, "matplotlib.md row $(k)"); true)
				end
			end
		end
	end
end

# --- the papers page ----------------------------------------------------------------------

# Page size in points of a Chromium PDF (the /MediaBox of its first page).
function _docs_pdf_page(path)
	m = match(r"/MediaBox \[([-\d. ]+)\]", String(read(path)))
	m === nothing && error("no /MediaBox in $(path)")
	v = parse.(Float64, split(m.captures[1]))
	return (v[3] - v[1], v[4] - v[2])
end

# ImageWidth, ImageLength and the X resolution (dpi) of a little-endian baseline TIFF.
function _docs_tiff_info(path)
	b = read(path)
	String(b[1:2]) == "II" || error("not a little-endian TIFF")
	u16(o) = Int(b[o+1]) | Int(b[o+2]) << 8
	u32(o) = u16(o) | u16(o + 2) << 16
	ifd = u32(4)
	info = Dict{Int,Any}()
	for k in 0:u16(ifd)-1
		e = ifd + 2 + 12k
		tag, typ = u16(e), u16(e + 2)
		if typ == 3
			info[tag] = u16(e + 8)
		elseif typ == 4
			info[tag] = u32(e + 8)
		elseif typ == 5
			o = u32(e + 8)
			info[tag] = u32(o) / u32(o + 4)
		end
	end
	return info[256], info[257], info[282]
end

@testset "papers.md examples have the documented sizes" begin
	mod = _docs_new_module()
	mktempdir() do dir
		cd(dir) do
			for b in filter(!_docs_is_fragment, _docs_blocks("docs/src/papers.md"))
				@test _docs_eval(mod, b)
			end
			fig(name) = Base.invokelatest(getfield, mod, name)
			# Figure widths are the journals' column widths, in CSS px.
			@test fig(:fig_conv).fig.layout[:width] ≈ journal_width(:ieee; columns = 2, units = :px)
			@test fig(:fig_fields).fig.layout[:width] ≈ journal_width(:aps; columns = 2, units = :px)
			@test fig(:fig_surf).fig.layout[:width] ≈ journal_width(:nature; columns = 2, units = :px)
			@test fig(:fig_schem).layout[:width] ≈ journal_width(:ieee; units = :px)
			# PDF pages: exact sizes in points.
			w, h = _docs_pdf_page("signal.pdf")
			@test w ≈ 3.5 * 72 atol = 0.01
			@test h ≈ 3.5 * 72 * 0.75 atol = 0.01
			@test _docs_pdf_page("convergence.pdf")[1] ≈ 7.16 * 72 atol = 0.01
			@test _docs_pdf_page("fields.pdf")[1] ≈ journal_width(:aps; columns = 2, units = :pt) atol = 0.01
			@test _docs_pdf_page("surfaces.pdf")[1] ≈ journal_width(:nature; columns = 2, units = :pt) atol = 0.01
			@test _docs_pdf_page("schematic.pdf")[1] ≈ 252 atol = 0.01
			# Text is embedded TrueType, never Type 3.
			bytes = String(read("signal.pdf"))
			@test !occursin("/Type3", bytes)
			@test occursin("/TrueType", bytes) || occursin("/CIDFontType2", bytes)
			# TIFF and PNG pixel sizes at the stated dpi.
			tw, th, tdpi = _docs_tiff_info("fig1.tif")
			@test tdpi == 600
			@test tw == round(Int, 7.16 * 600)
			png = read("fig1.png")
			@test png[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
			@test (Int(png[17]) << 24 | Int(png[18]) << 16 | Int(png[19]) << 8 | Int(png[20])) == round(Int, 7.16 * 300)
			@test isfile("fig1.svg") && isfile("fig1b.pdf")
		end
	end
end

@testset "journal presets match the papers page" begin
	widths = (
		(:ieee, 1, 3.5, :in), (:ieee, 2, 7.16, :in),
		(:aps, 1, 8.6, :cm), (:aps, 2, 17.2, :cm),
		(:nature, 1, 89, :mm), (:nature, 2, 183, :mm),
		(:elsevier, 1, 90, :mm), (:elsevier, 1.5, 140, :mm), (:elsevier, 2, 190, :mm),
		(:springer, 1, 84, :mm), (:springer, 1.5, 129, :mm), (:springer, 2, 174, :mm),
		(:aip, 1, 3.37, :in), (:aip, 2, 6.69, :in),
	)
	for (j, c, w, u) in widths
		@test journal_width(j; columns = c, units = u) ≈ w
	end
	text = _docs_read("docs/src/papers.md")
	for (j, size_pt, ticks) in ((:ieee, 8, "inside"), (:aps, 9, "inside"), (:nature, 7, "outside"),
			(:elsevier, 9, "outside"), (:springer, 8, "outside"), (:aip, 8, "inside"))
		@test occursin("| `:$(j)` |", text)
		st = with_style(get_default_style, j)
		@test st.fontsize * 0.75 ≈ size_pt
		@test st.tick_fontsize * 0.75 ≈ size_pt
		@test st.label_fontsize * 0.75 ≈ size_pt
		@test st.legend_fontsize * 0.75 ≈ size_pt
		@test st.linewidth * 0.75 ≈ 1
		@test st.axis_linewidth * 0.75 ≈ 0.75
		@test st.tick_length * 0.75 ≈ 3.5
		@test st.ticks == ticks
		@test st.cycle === :dash_symbol
		@test st.colorway == PlotlySupply.COLOR_CYCLES[:okabe_ito]
		@test st.aspect == 0.75
		@test st.width ≈ journal_width(j; units = :px)
	end
	# Optica is documented as absent, and journals with a maximum height reject a taller figure.
	@test occursin("Optica is not included", text)
	@test_throws ArgumentError journal_width(:optica)
	fig = plot_scatter(1:3, 1:3)
	@test_throws ArgumentError figsize!(fig, :nature; height = 200, units = :mm)
	@test_throws ArgumentError figsize!(fig, :aip; height = 9, units = :in)
	figsize!(fig, :nature; columns = 2, height = 6, units = :cm)
	@test fig.layout[:width] ≈ 183 * 96 / 25.4
	@test fig.layout[:height] ≈ 60 * 96 / 25.4
end

@testset "colour scale orientation table of the migration page" begin
	text = _docs_read("docs/src/migration.md")
	for (name, low, high) in (("Greys", "#FFFFFF", "#000000"), ("Blues", "#F7FBFF", "#08306B"),
			("Greens", "#F7FCF5", "#00441B"), ("YlGnBu", "#FFFFD9", "#081D58"),
			("YlOrRd", "#FFFFCC", "#800026"), ("RdBu", "#67001F", "#053061"))
		stops = colormap(name)
		@test stops[1][2] == low
		@test stops[end][2] == high
		@test colormap(name * "_r")[1][2] == high      # the 1.x direction
		@test occursin("`\"$(name)\"`", text) && occursin("`\"$(name)_r\"`", text)
	end
	# The explicit-stops recipe of the page.
	fig = plot_heatmap(randn(4, 3); colorscale = [(0, "rgb(0,0,0)"), (1, "rgb(255,255,255)")])
	@test fig.data[1][:colorscale][1][2] in ("rgb(0,0,0)", "#000000")
	@test PlotlySupply.COLOR_CYCLES[:okabe_ito][1] == "#0072B2"
end

@testset "docs claims: one-sided limits, quiver kinds, maps, annotate coords" begin
	# One-sided limits (axes.md, README Conventions).
	fig = plot_scatter(1:10, (1:10) .^ 2)
	yrange!(fig, (0, nothing))
	ax = fig.layout[:yaxis]
	@test ax[:autorange] === true && ax[:autorangeoptions][:minallowed] == 0
	xrange!(fig, (nothing, 12))
	@test fig.layout[:xaxis][:autorangeoptions][:maxallowed] == 12
	@test_throws ArgumentError yrange!(fig, (nothing, 0))      # beyond all data
	@test_throws ArgumentError yrange!(fig, (1, 1))
	yrange!(fig, nothing)
	@test fig.layout[:yaxis][:autorange] === true && !haskey(fig.layout[:yaxis], :range)
	logfig = plot_scatter([1e-2, 1, 1e3], [1.0, 2, 3]; xscale = "log", xrange = (1e-3, nothing))
	@test logfig.layout[:xaxis][:autorangeoptions][:minallowed] ≈ -3
	@test plot_scatter(1:10, 1:10; yrange = (5, nothing)).layout[:yaxis][:autorangeoptions][:minallowed] == 5
	# Quiver kinds (fields.md).
	qx = [0.0, 1, 2]; qy = [0.0, 1, 0]; u = [1.0, 2, 3]; v = [0.0, 1, 1]
	arrows = plot_quiver(qx, qy, u, v)
	tri = plot_quiver(qx, qy, u, v; style = :triangle, pivot = :tip, scale = :uniform)
	@test arrows.data[1][:type] == "scatter" && tri.data[1][:fill] == "toself"
	byc = plot_quiver(qx, qy, u, v; style = :triangle, colorby = :magnitude, colorscale = "viridis")
	@test length(byc.data) >= 1
	@test_throws ArgumentError plot_quiver(qx, qy, u, v; colorby = :magnitude, color = "red")
	@test_throws ArgumentError plot_quiver(qx, qy, u, v; style = :square)
	@test_throws ArgumentError plot_quiver(qx, qy, u, v; pivot = :nose)
	# Maps: `trace` is the only pass-through; `legend` names choropleth traces (charts.md).
	@test_throws ArgumentError plot_scattergeo([2.35], [48.86]; hovertemplate = "x")
	@test_throws ArgumentError plot_scattergeo([2.35], [48.86]; trace = attr(name = "x"))
	geo = plot_scattergeo([2.35], [48.86]; trace = attr(hovertemplate = "%{lat}"))
	@test geo.data[1][:hovertemplate] == "%{lat}"
	chor = plot_choropleth(["France"], [1.0]; locationmode = "country names", legend = "GDP")
	@test chor.data[1][:name] == "GDP" && chor.data[1][:showlegend] === true
	# annotate! coordinates (text.md).
	fig = plot_scatter(1:3, 1:3)
	annotate!(fig, 0.5, 0.02, "Source"; coords = :figure, showarrow = false)
	@test_throws ArgumentError annotate!(fig, 0.5, 1.5, "x"; coords = :figure, showarrow = false)
	@test_throws ArgumentError annotate!(fig, 0.5, 0.5, "x"; coords = :figure, name = "n")
	annotate!(fig, 0.5, 1.2, "above"; coords = :paper, showarrow = false)
	annotate!(fig, 0.1, 0.9, "(a)"; coords = :axes, showarrow = false)
	# 3-D return values (threed.md).
	f3 = plot_surface(rand(5, 5))
	@test view!(f3; elev = 20, azim = 30) === nothing
	@test scene!(f3; nticks = 4) === nothing
	sf3 = subplots(1, 1; sync = false, specs = fill(Spec(kind = "scene"), 1, 1))
	plot_surface!(sf3, rand(5, 5))
	@test view!(sf3; elev = 20, azim = 30) === sf3
	# Tick keywords on every 2-D constructor (README keyword table).
	@test plot_waterfall(["a", "b"], [1.0, 2]; yticks = [0, 1, 2]).layout[:yaxis][:tickvals] == [0.0, 1.0, 2.0]
	@test plot_matrix(rand(3, 3); xticks = [1, 2], xticklabels = ["a", "b"]).layout[:xaxis][:ticktext] == ["a", "b"]
end

@testset "docs claims: export, styles and the performance page" begin
	mktempdir() do dir
		cd(dir) do
			fig = with_style(:ieee) do
				plot_scatter(1:5, rand(5); xlabel = "\$t\$ (s)")
			end
			# No size given: the style's default size (3.5 in x 2.625 in).
			savefig(fig, "a.pdf")
			w, h = _docs_pdf_page("a.pdf")
			@test w ≈ 252 atol = 0.01
			@test h ≈ 189 atol = 0.01
			# TIFF: default 300 dpi, tags set; PNG pixel count rounds.
			savefig(fig, "a.tiff")
			@test _docs_tiff_info("a.tiff") == (1050, 788, 300)      # 3.5 in x 2.625 in at 300 dpi
			# an unsupported format is invalid input (ArgumentError, Z89)
			@test_throws ArgumentError savefig(fig, "a.xyz")
			@test_throws ArgumentError savefig(fig, joinpath(dir, "missing-dir", "a.pdf"))
			@test_throws ArgumentError savefig(fig, "b.pdf"; fonts = :nothing)
			# Deterministic by default.
			savefig(fig, "c1.pdf"); savefig(fig, "c2.pdf")
			@test read("c1.pdf") == read("c2.pdf")
			# HTML embeds plotly.js.
			savefig(fig, "a.html")
			@test filesize("a.html") > 1_000_000
		end
	end
	# The opt-out preference named on the performance page is the PrecompileTools key.
	perf = _docs_read("docs/src/performance.md")
	@test occursin("precompile_workload", perf)
	wl = joinpath(dirname(dirname(pathof(PlotlySupply))), "src", "precompile.jl")
	@test isfile(wl)
	@test occursin("@compile_workload", read(wl, String))
	# Shared-axis groups (subplots.md).
	sf = subplots(2, 2; sync = false, shared_xaxes = true, shared_yaxes = true,
		column_titles = ["\$\\alpha = 1\$", "\$\\alpha = 2\$"])
	for r in 1:2, c in 1:2
		plot_scatter!(sf, 1:5, rand(5); row = r, col = c)
	end
	xrange!(sf, (1, 10); row = 1, col = 1)
	xlabel!(sf, "\$x\$"; row = 1, col = 1)
	lay = sf.fig.layout
	@test lay[:xaxis3][:range] == [1, 10]                       # the root of the shared column
	@test lay[:xaxis3][:title][:text] == "\$x\$"                # the label goes to the bottom cell
	@test lay[:xaxis][:matches] == "x3"
	names = [a[:name] for a in lay[:annotations] if haskey(a, :name)]
	@test "plotlysupply:title!:1:1:column" in names
	title!(sf, "T"; row = 1, col = 2)
	@test "plotlysupply:title:1:2" in [a[:name] for a in sf.fig.layout[:annotations] if haskey(a, :name)]
	@test_throws ArgumentError relayout!(sf; row = 1)
end

# --- wave 6: the gallery --------------------------------------------------------------------

const _GALLERY_DIR = joinpath(_DOCS_ROOT, "docs", "gallery")
_gallery_scripts() = sort!(filter(f -> endswith(f, ".jl") && f != "runall.jl", readdir(_GALLERY_DIR)))

# Width and height of a PNG from its IHDR chunk (and the signature check).
function _docs_png_size(path::AbstractString)
	bytes = read(path)
	length(bytes) >= 24 || return nothing
	bytes[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] || return nothing
	be32(i) = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
	return (be32(17), be32(21))
end

@testset "gallery scripts are self-contained and listed on the gallery page" begin
	scripts = _gallery_scripts()
	@test 35 <= length(scripts) <= 50
	page = _docs_read("docs/src/gallery.md")
	@test occursin("gallery.md", _docs_read("docs/make.jl"))
	for f in scripts
		name = f[1:end-3]
		src = _docs_read(joinpath("docs", "gallery", f))
		@testset "$name" begin
			@test count(==('\n'), src) <= 80                          # short enough to read in one go
			# header: what it shows, the catalogue entries it covers, the matplotlib idiom, the 2.0 calls
			@test occursin(r"\A# [^\n]+\.\n#\n# Catalogue: "m, src)
			@test occursin(r"^# Replaces: "m, src) && occursin(r"^# 2\.0: "m, src)
			@test !occursin(r"/Users/|/tmp|/home/|[A-Z]:[\\]", src)      # no absolute paths
			@test occursin("isempty(ARGS) ? (@__DIR__) : first(ARGS)", src)
			@test occursin("using PlotlySupply", src)
			@test occursin("scale = 2", src)                          # rendered at 2x
			@test occursin("`$(name)`", page) && occursin("(assets/gallery/$(name).png)", page)
			png = joinpath(_DOCS_SRC, "assets", "gallery", name * ".png")
			@test isfile(png)
			size = _docs_png_size(png)
			@test size !== nothing && size[1] >= 400 && size[2] >= 250
		end
	end
	# Every figure of the page belongs to a script.
	for m in eachmatch(r"\]\(assets/gallery/([A-Za-z0-9_]+)\.png\)", page)
		@test (m.captures[1] * ".jl") in scripts
	end
end

@testset "the gallery runner runs every script (dry run) and reports failures" begin
	runner = Module(:_GalleryRunner)
	Base.include(runner, joinpath(_GALLERY_DIR, "runall.jl"))
	args0 = copy(ARGS)
	mktempdir() do out
		# Every script of the gallery is executed in full; savefig is a stand-in, nothing is rendered.
		status = redirect_stdout(devnull) do
			Base.invokelatest(runner.run_gallery, String[out]; render = false)
		end
		@test status == 0
		@test sort(filter(endswith(".png"), readdir(out))) == [f[1:end-3] * ".png" for f in _gallery_scripts()]
		# Settled figures: after the last PlotlySupply call of a script, finalizing the figure (outside
		# the `with_style` block it was built in) writes nothing.
		# Five figures (all with equal-aspect cells, shared colorbars or hidden axes) are not yet
		# fixed points of the finalizer: the first call after the script writes again
		# (chama_a5_deformed_meshes never settles, device_geometry needs three rounds). They are
		# listed as broken so the layout engine's fix shows up as an unexpected pass; every
		# other gallery figure must be settled.
		known_unsettled = Set(["block_diagram.png", "chama_a5_deformed_meshes.png", "device_geometry.png",
			"field_maps.png", "optical_pixelmap.png"])
		@test known_unsettled <= Set(first.(runner.DRY_FIGURES))
		for (name, fig) in runner.DRY_FIGURES
			wrote = PlotlySupply._finalize_figure!(fig)
			if name in known_unsettled
				@test_broken !wrote
			else
				@test !wrote
			end
		end
		# One script is rendered for real: a PNG of twice the figure's pixels (3.5 in at 96 dpi, 2x).
		status = redirect_stdout(devnull) do
			Base.invokelatest(runner.run_gallery, String[out, "endpoint_star"])
		end
		@test status == 0
		size = _docs_png_size(joinpath(out, "endpoint_star.png"))
		@test size !== nothing && abs(size[1] - 672) <= 2
		@test ARGS == args0                                           # the runner restores ARGS
	end
	# A failing script is reported, the others still run, and the exit status is 1.
	mktempdir() do dir
		write(joinpath(dir, "good.jl"), "using PlotlySupply\nglobal ran_good = true\n")
		write(joinpath(dir, "bad.jl"), "error(\"boom\")\n")
		write(joinpath(dir, "runall.jl"), "# not a gallery script\n")
		out = redirect_stdout(devnull) do
			Base.invokelatest(runner.run_gallery, String[joinpath(dir, "o")]; render = false, dir = dir)
		end
		@test out == 1
		@test redirect_stdout(devnull) do
			Base.invokelatest(runner.run_gallery, String[joinpath(dir, "o"), "good"]; render = false, dir = dir)
		end == 0
		@test redirect_stdout(devnull) do
			Base.invokelatest(runner.run_gallery, String[joinpath(dir, "o"), "nosuch"]; render = false, dir = dir)
		end == 1
	end
end

@testset "docs claims of wave 6: paper log ticks, HTML export, migration before/after" begin
	# Under a paper style a log axis of two decades or more labels decades only by itself;
	# the default style keeps plotly's labels (axes.md, papers.md).
	x = 10.0 .^ range(-3, 1; length = 20)
	paper = with_style(:ieee) do
		plot_scatter(x, x .^ 2; xscale = "log", yscale = "log")
	end
	plain = plot_scatter(x, x .^ 2; xscale = "log", yscale = "log")
	PlotlySupply._finalize_figure!(paper); PlotlySupply._finalize_figure!(plain)
	@test paper.layout[:xaxis][:dtick] == 1
	@test !haskey(plain.layout[:xaxis], :dtick)
	@test paper.layout[:meta][:plotlysupply][:log_ticks] == "decades"
	@test !PlotlySupply._finalize_figure!(paper)                  # settled: a second call writes nothing
	# Optica is documented as absent; the six presets exist (papers.md).
	@test_throws ArgumentError journal_width(:optica)
	@test all(j -> journal_width(j) > 0, (:ieee, :aps, :nature, :elsevier, :springer, :aip))
	# Migration page, 2.0 side of the before/after blocks (the 1.x side was run on v1.9.4:
	# 1.x stored the colour scale name, accepted exponents on log axes, changed every cell on
	# update_xaxes!, drew one trace per stem point and read a colour vector per series).
	f = [1.0, 10, 100, 1000]; g = [1.0, 50, 100, 20]
	@test plot_scatter(f, g; xscale = "log", xrange = [1, 1000]).layout[:xaxis][:range] == [0.0, 3.0]
	@test_throws ArgumentError plot_scatter(f, g; xscale = "log", xrange = [0, 3])
	logfig = plot_scatter(f, g; xscale = "log"); annotate!(logfig, 10, 50, "peak")
	@test logfig.layout[:annotations][1][:x] == 1.0               # data value 10 is x = 1 in log10
	@test plot_stem(1:5, [1, 2, 3, 2, 1]).data |> length == 2
	bar = plot_bar([4.0, 2.0, 7.0]; orientation = "h").data[1]
	@test bar[:x] == [4.0, 2.0, 7.0] && collect(bar[:y]) == 0:2
	@test plot_bar(["a", "b", "c"], [1.0, 2, 3]; color = ["red", "green", "blue"]).data[1][:marker][:color] ==
		["red", "green", "blue"]
	@test !haskey(plot_scatter(1:5, 1:5).layout[:xaxis], :tick0)
	@test_throws ArgumentError plot_scatter(1:3, [1, 2])
	@test_throws ArgumentError plot_heatmap(1:4, 1:3, permutedims(randn(4, 3)))
	@test plot_scatter(1:3, [1, 2, 3]; title = "Run 3").layout[:title_text] == "Run 3"
	sf = subplots(1, 2; sync = false)
	@test !haskey(sf.fig.layout, :title)
	plot_scatter!(sf, 1:3, [1, 2, 3]; row = 1, col = 1); plot_scatter!(sf, 1:3, [3, 2, 1]; row = 1, col = 2)
	update_xaxes!(sf; row = 1, col = 2, title_text = "x")
	@test !haskey(sf.fig.layout[:xaxis], :title) && haskey(sf.fig.layout[:xaxis2], :title)
	# CHANGELOG 2.0.0 entries added with the wave-5b merge.
	@test plot_scatterpolar(0:10, 1:11; rrange = (nothing, 12)) isa Plot
	@test_throws ArgumentError plot_scatter(1:3, [1, 2, 3]; yrange = ("a", "b"))
	psf = subplots(1, 2; sync = false)
	@test_throws ArgumentError panel_labels!(psf; row = 1, col = 1)
	@test_throws ArgumentError update_xaxes!(plot_scatter(1:3, 1:3); row = 1, col = 1, title_text = "x")
	band = with_style(:ieee) do
		plot_band(1:3, [1, 1, 1], [2, 2, 2])
	end
	@test string(band.data[1][:fillcolor]) != "#636EFA" && !occursin("99, 110, 250", string(band.data[1][:fillcolor]))
	lf = plot_scatter(1:3, 1:3)
	xlabel!(lf, "a very long x axis title that has to be written on one line only"; wrap = false)
	ylabel!(lf, "a very long y axis title"; wrap = false)
	@test occursin("\u00a0", lf.layout[:xaxis][:title][:text])           # no-break spaces keep it on one line
	# HTML export: the page embeds plotly.js and two exports of one figure are the same bytes (export.md).
	mktempdir() do dir
		fig = plot_scatter(1:5, rand(5))
		savefig(fig, joinpath(dir, "a.html")); savefig(fig, joinpath(dir, "b.html"))
		@test filesize(joinpath(dir, "a.html")) > 1_000_000
		@test read(joinpath(dir, "a.html")) == read(joinpath(dir, "b.html"))
		# `simplify = true` is an option of the scatter constructors (export.md); the default exports every vertex.
		@test plot_scatter(1:5, 1:5; simplify = true).data[1][:line][:simplify] === true
	end
end
