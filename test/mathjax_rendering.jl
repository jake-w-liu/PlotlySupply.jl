# Standalone Electron integration: julia --project=. test/mathjax_rendering.jl OUT MODE
# Modes run in separate processes so order tests start with an empty renderer cache.
# 2.0 clears the export window after every export, so the figure is drawn in the
# export window again (the PDF draw step) and measured there, in the same state
# the exported file was made from. The desktop window loads MathJax itself.
using PlotlySupply
const PS=PlotlySupply
const JSON=PS.PlotlyBase.JSON
const ROOT=normpath(joinpath(@__DIR__,".."))
realpath(dirname(dirname(pathof(PS))))==realpath(ROOT) || error("unexpected package source")
const METRICS=read(joinpath(@__DIR__,"mathjax_render_metrics.js"),String)
const SVG_ROUNDTRIP=read(joinpath(@__DIR__,"mathjax_svg_roundtrip.js"),String)
count("__PS_SVG_TEXT__",SVG_ROUNDTRIP)==1 || error("unexpected SVG oracle template")
const PLAIN=("Field","Profile derivative","Finite difference hybrid")
const MATH=(raw"$\mathit{Field}$",raw"$\mathit{Profile\ derivative}$",raw"$\mathit{Finite\ difference\ hybrid}$")
const DEFAULT_FAMILY="\"Open Sans\", verdana, arial, sans-serif"

function data_fixture()
    rows=[parse.(Float64,split(line,',')) for line in readlines(joinpath(@__DIR__,"fixtures","mathjax_legend_lines.csv"))[2:end]]
    length(rows)==9 || error("missing analytical rows")
    x=first.(rows);ys=ntuple(k->[r[k+1] for r in rows],3)
    x==collect(0.:8.) || error("unexpected abscissae")
    all(k->all(i->4(ys[k][i]-k)==x[i],eachindex(x)),1:3) || error("affine oracle failed")
    return x,ys
end
function figure(font,mode,columns,family)
    x,ys=data_fixture();sf=subplots(1,columns;sync=false,show=false,width=504columns,height=288,per_subplot_legends=true)
    names=mode===:math ? MATH : PLAIN
    for col in 1:columns
        subplot!(sf,1,col)
        for k in 1:3
            plot_scatter!(sf,x,ys[k];mode="lines",legend=names[k],linewidth=2,fontsize=font,
                color=("#0072B2","#D55E00","#009E73")[k],xlabel="x",ylabel="y")
        end
        suffix=col==1 ? "" : string(col)
        for (a,r) in (("x",[0.,8.]),("y",[0.,10.]))
            axis=sf.fig.layout.fields[Symbol(a*"axis"*suffix)]
            axis[:range]=r;axis[:autorange]=false;axis[:showgrid]=true;axis[:gridcolor]="#C5CCD6";axis[:gridwidth]=1
        end
    end
    subplot_legends!(sf;position=:topright)
    relayout!(sf;title="",font=attr(size=font,family=family),margin=attr(l=72,r=14,t=14,b=56))
    return sf
end
function checked_metrics(ec,window,path,font,mode,columns)
    raw=Base.invokelatest(()->ec.run(window,METRICS));raw isa AbstractString || error("metrics were not serialized")
    d=JSON.parse(raw);write(path*".json",raw*"\n")
    haskey(d,"diagnostic_error") && error(d["diagnostic_error"]*"\n"*d["stack"])
    html=Base.invokelatest(()->ec.run(window,"document.querySelector('.js-plotly-plot').outerHTML"))
    write(path*".html",html)
    d["plotly_version"]=="2.35.2" && d["font"]["size"]==font || error("wrong rendered version/font")
    length(d["legends"])==columns || error("missing legend")
    for l in d["legends"]
        length(l["entries"])==3 || error("missing legend entry")
        [e["label"] for e in l["entries"]]==collect(mode===:math ? MATH : PLAIN) || error("changed labels")
        for e in l["entries"]
            maximum(values(e["overflow"]))<=.5 || error("actual legend glyphs exceed their clip")
            e["math"]==(mode===:math) || error("wrong text representation")
            if mode===:math
                e["math_font_size"]=="$(font)px" || error("math group font size was not explicit")
                occursin("font-family",e["math_style"]) && occursin("font-size",e["math_style"]) || error("missing inline font context")
            end
        end
    end
    return d
end
# Draw `plot` in the export window exactly as the PDF/EPS export does (same
# prepared copy, same `Plotly.newPlot` step) and call `f(ec, window)` while the
# drawn figure is in the page.
function drawn(f,plot,width,height)
    prepared=PS._prepare_export(plot,("pdf",),(width=width,height=height)).renderer
    PS._with_export_window(PS._EXPORT_STATE) do ec,app,win,divid
        drawing=Base.invokelatest(()->ec.run(win,PS._pdf_render_script(divid,prepared)))
        drawing=="ok" || error("the export window did not draw the figure: "*repr(drawing))
        f(ec,win)
    end
end
function svg_roundtrip_metrics(ec,win,svg,path)
    js=replace(SVG_ROUNDTRIP,"__PS_SVG_TEXT__"=>PS._json_js(svg);count=1)
    raw=Base.invokelatest(()->ec.run(win,js))
    raw isa AbstractString || error("SVG roundtrip was not serialized")
    d=JSON.parse(raw);write(path,raw*"\n")
    haskey(d,"diagnostic_error") && error(d["diagnostic_error"]*"\n"*d["stack"])
    d["passed"]===true && d["live_dom_unchanged"]===true || error("SVG roundtrip failed")
    return d
end
function html_metrics(file,path,font,mode,columns)
    ec=PS._electroncall();app=PS._default_electron_app(ec)
    win=Base.invokelatest(()->ec.Window(app,PS._file_uri(file);width=1100,height=500,title="Math legend HTML test",show=false))
    success=false
    try
        start=time()
        while true
            ready=Base.invokelatest(()->ec.run(win,"""(function(){const g=document.querySelector('.js-plotly-plot');return g&&g._fullLayout&&g._fullLayout.legend&&g._fullLayout.legend._width>0&&g.querySelectorAll('g.traces').length>=3?'ready':'waiting';})()"""))
            ready=="ready" && break
            time()-start<30 || error("portable HTML did not finish rendering")
            sleep(.05)
        end
        result=checked_metrics(ec,win,path,font,mode,columns)
        success=true
        return result
    finally
        if success
            Base.invokelatest(()->ec.close(win))
            Base.invokelatest(()->ec.isopen(win)) && error("HTML test window did not close")
        else
            try Base.invokelatest(()->ec.close(win)) catch cleanup_error
                @warn "HTML test window cleanup also failed" exception=(cleanup_error,catch_backtrace())
            end
        end
    end
end
# The desktop window loads MathJax by itself (2.0): wait for it, check its
# version and that reading the model JSON does not change it.
function check_live_mathjax(ec,sp,out)
    deadline=time()+30
    local state
    while true
        raw=Base.invokelatest(()->ec.run(sp.window,"""JSON.stringify({mathjax_type:typeof MathJax,
          version:typeof MathJax==='undefined'?null:MathJax.version,
          scripts:Array.from(document.scripts).map(s=>s.src).filter(Boolean),
          math_groups:document.querySelectorAll('g[data-math="Y"]').length})"""))
        state=JSON.parse(raw)
        state["mathjax_type"]=="object" && state["math_groups"]>0 && break
        time()<deadline || error("the desktop window did not load MathJax: "*raw)
        sleep(.1)
    end
    write(joinpath(out,"live_setup_ready.json"),raw*"\n")
    state["version"]=="2.7.9" || error("unexpected desktop MathJax version")
    before=savefig(sp.plot;format="json")
    before==savefig(sp.plot;format="json") || error("reading the model JSON changed it")
end

function definitions(mode)
    if mode=="matrix"
        return [(id="font$(f)_$(m)_cols$(c)",font=f,mode=m,columns=c,family=DEFAULT_FAMILY)
            for f in (12,18) for m in (:plain,:math) for c in (1,2)]
    elseif mode in ("order12","order18")
        fonts=mode=="order12" ? (12,18,12) : (18,12,18)
        return [(id="step$(i)_font$(f)",font=f,mode=:math,columns=1,family=DEFAULT_FAMILY) for (i,f) in enumerate(fonts)]
    elseif mode=="custom"
        return [(id="$(familyid)_font$(f)_cols$(c)",font=f,mode=:math,columns=c,family=family)
            for (familyid,family) in (("times","Times New Roman"),("arial","Arial")) for f in (12,18) for c in (1,2)]
    end
    error("unsupported static mode")
end

function main()
length(ARGS)==2 || error("usage: mathjax_rendering.jl FRESH_OUT matrix|order12|order18|custom|live")
out=abspath(ARGS[1]);mode=ARGS[2];ispath(out) && error("output directory must be fresh");mkpath(out)
PS._EXPORT_STATE.window===nothing || error("renderer was primed")
if mode=="live"
    sf=figure(12,:math,1,DEFAULT_FAMILY)
    sp=to_syncplot(sf.fig;show=false,width=504,height=288)
    ec=PS._electroncall();success=false
    try
        original_data=JSON.json(sp.plot.data)
        check_live_mathjax(ec,sp,out)
        for (i,(font,family)) in enumerate(((12,DEFAULT_FAMILY),(18,DEFAULT_FAMILY),(12,DEFAULT_FAMILY),(18,"Times New Roman"),(18,"Arial")))
            relayout!(sp;font=attr(size=font,family=family))
            checked_metrics(ec,sp.window,joinpath(out,"live$(i)"),font,:math,1)
            JSON.json(sp.plot.data)==original_data || error("live relayout changed data")
        end
        success=true
    finally
        if success
            close(sp);isopen(sp) && error("live window did not close")
        else
            try close(sp) catch cleanup_error
                @warn "Live test window cleanup also failed" exception=(cleanup_error,catch_backtrace())
            end
        end
    end
    write(joinpath(out,"complete.json"),JSON.json((mode=mode,live_states=5,closed=true,data_unchanged=true,explicit_fixture_mathjax=false,automatic_desktop_mathjax_loading=true))*"\n")
else
    records=Any[]
    for c in definitions(mode)
        folder=joinpath(out,c.id);mkpath(folder)
        sf=figure(c.font,c.mode,c.columns,c.family);stem=joinpath(folder,"legend")
        savefig(sf,stem*".json");before=read(stem*".json")
        savefig(sf,stem*".pdf";width=504c.columns,height=288)
        savefig(sf,stem*".svg";width=504c.columns,height=288)
        svgtext=read(stem*".svg",String)
        drawn(sf.fig,504c.columns,288) do ec,win
            checked_metrics(ec,win,joinpath(folder,"after_export"),c.font,c.mode,c.columns)
            svg_roundtrip_metrics(ec,win,svgtext,joinpath(folder,"svg_roundtrip.json"))
        end
        savefig(sf,stem*".html")
        html=html_metrics(stem*".html",joinpath(folder,"after_html"),c.font,c.mode,c.columns)
        before==savefig(sf.fig;format="json") || error("exports changed model JSON")
        push!(records,merge(c,(mode=string(c.mode),json_unchanged=true,drawn_passed=true,svg_dom_passed=true,html_passed=true)))
        write(joinpath(out,"cases.json"),JSON.json(records)*"\n")
        println("passed ",mode,"/",c.id);flush(stdout)
    end
    write(joinpath(out,"complete.json"),JSON.json((mode=mode,cases=length(records),module_path=pathof(PS),raw_asset=PS._plotlyjs_asset_path(),
        compatible_asset=PS._plotlyjs_render_asset_path(),raw_digest=PS._plotlyjs_file_digest(PS._plotlyjs_asset_path()),
        compatible_digest=PS._plotlyjs_file_digest(PS._plotlyjs_render_asset_path())))*"\n")
end
end
abspath(PROGRAM_FILE)==(@__FILE__) && main()
