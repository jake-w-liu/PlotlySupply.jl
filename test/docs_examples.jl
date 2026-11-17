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
