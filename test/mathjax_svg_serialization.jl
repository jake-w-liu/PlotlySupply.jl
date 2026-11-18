# Standalone actual-SVG regression: julia --project=. test/mathjax_svg_serialization.jl FRESH_OUT
include("mathjax_rendering.jl")

function serialization_main()
    length(ARGS)==1 || error("usage: mathjax_svg_serialization.jl FRESH_OUT")
    out=abspath(ARGS[1]);ispath(out) && error("output directory must be fresh");mkpath(out)
    PS._EXPORT_STATE.window===nothing || error("renderer was primed")
    families=(("default",DEFAULT_FAMILY),("times","\"Times New Roman\", serif"),("arial","Arial, sans-serif"),
        ("comma","\"Example, Family\", serif"),("keyword","\"serif\", monospace"),
        ("apostrophe","\"Font's Name\", serif"),("quote","\"Font \\\"Quote\\\" Name\", serif"),
        ("ampersand","\"A&B Family\", serif"))
    records=Any[]
    function check(p,name;gradient=false)
        folder=joinpath(out,name);mkpath(folder)
        before=savefig(p;format="json");write(joinpath(folder,"model.json"),before)
        file=joinpath(folder,"figure.svg");savefig(p,file;width=504,height=288)
        d=svg_roundtrip_metrics(read(file,String),joinpath(folder,"svg_roundtrip.json"))
        gradient && d["gradient_nodes"]<1 && error("gradient/pattern control did not exercise a URL")
        if gradient
            negative=joinpath(out,"negative_controls");mkpath(negative)
            svg=read(file,String)
            selector,attribute,value=name=="heatmap_gradient" ?
                ("linearGradient stop","stop-color","#FF00FF") : ("pattern path","d","M0,0L0,1")
            js="""(function(){const d=new DOMParser().parseFromString($(PS._json_js(svg)), 'image/svg+xml');
              const n=d.querySelector($(PS._json_js(selector)));if(!n)throw new Error('missing mutation target');
              n.setAttribute($(PS._json_js(attribute)),$(PS._json_js(value)));return new XMLSerializer().serializeToString(d);})()"""
            s=PS._EXPORT_STATE
            bad=Base.invokelatest(()->s.backend.run(s.window,js))
            write(joinpath(negative,name*"_corrupted.svg"),bad)
            source=Base.invokelatest(()->s.backend.run(s.window,"document.querySelector('.js-plotly-plot').outerHTML"))
            rejected=try
                svg_roundtrip_metrics(bad,joinpath(negative,name*"_rejected.json"));false
            catch err
                err isa ErrorException && occursin("gradient or pattern identity changed",sprint(showerror,err))
            end
            rejected || error("corrupted gradient/pattern was not rejected for the intended reason")
            source==Base.invokelatest(()->s.backend.run(s.window,"document.querySelector('.js-plotly-plot').outerHTML")) ||
                error("negative SVG control changed the live plot")
        end
        before==savefig(p;format="json") || error("SVG export changed model JSON")
        push!(records,(id=name,text_nodes=d["text_nodes"],math_groups=d["math_groups"],
            gradient_nodes=d["gradient_nodes"],json_unchanged=true))
        write(joinpath(out,"cases.json"),JSON.json(records)*"\n")
        println("passed SVG ",name);flush(stdout)
    end
    for (id,family) in families, mode in (:plain,:math)
        sf=figure(18,mode,1,family)
        for (axis,label) in ((:xaxis,"x"),(:yaxis,"y"))
            a=sf.fig.layout.fields[axis]
            a[:tickfont]=attr(size=18,family=family)
            a[:title]=attr(text=label,font=attr(size=22,family=family))
        end
        check(sf,id*"_"*string(mode))
    end
    # Explicit analytical arrays exercise actual gradient and pattern URL serialization.
    gradient=plot(heatmap(z=[1 2;3 4],colorscale="Viridis",showscale=true))
    relayout!(gradient;width=504,height=288,font=attr(size=18,family=DEFAULT_FAMILY))
    check(gradient,"heatmap_gradient";gradient=true)
    pattern=plot(bar(x=["a","b"],y=[1,2],marker=attr(color="#0072B2",pattern=attr(shape="/"))))
    relayout!(pattern;width=504,height=288,font=attr(size=18,family=DEFAULT_FAMILY))
    check(pattern,"bar_pattern";gradient=true)
    write(joinpath(out,"complete.json"),JSON.json((cases=length(records),all_xml_and_font_identity_passed=true,
        analytical_controls_only=true))*"\n")
end
serialization_main()
