(function () {
  try {
  const root=document.querySelector('.js-plotly-plot');
  if(!root||!root._fullLayout) throw new Error('actual plot missing');
  const fl=root._fullLayout;
  function box(b){return {x:b.x,y:b.y,width:b.width,height:b.height};}
  function mapped(b,m){
    const p=[[b.x,b.y],[b.x+b.width,b.y],[b.x,b.y+b.height],[b.x+b.width,b.y+b.height]]
      .map(([x,y])=>[m.a*x+m.c*y+m.e,m.b*x+m.d*y+m.f]);
    return {left:Math.min(...p.map(a=>a[0])),right:Math.max(...p.map(a=>a[0])),
      top:Math.min(...p.map(a=>a[1])),bottom:Math.max(...p.map(a=>a[1]))};
  }
  const legends=Array.from(root.querySelectorAll('g'))
    .filter(n=>Array.from(n.classList).some(c=>/^legend\d*$/.test(c)))
    .map(n=>{
      const key=Array.from(n.classList).find(c=>/^legend\d*$/.test(c));
      const scroll=n.querySelector('.scrollbox'),url=scroll.getAttribute('clip-path');
      const id=/#([^'"()]+)/.exec(url)[1],clip=document.getElementById(id);
      if(clip.getAttribute('clipPathUnits')&&clip.getAttribute('clipPathUnits')!=='userSpaceOnUse')throw new Error('unexpected clip units');
      const rect=clip.querySelector('rect'),matrix=scroll.getScreenCTM();
      const cb=mapped(rect.getBBox(),matrix);
      const entries=Array.from(n.querySelectorAll('g.traces')).map(e=>{
        const math=e.querySelector('g[class$="text-math-group"]');
        const ink=math||e.querySelector('text');
        if(!ink)throw new Error('legend ink missing');
        const b=ink.getBoundingClientRect(),d=e.__data__[0];
        const overflow={left:cb.left-b.left,right:b.right-cb.right,top:cb.top-b.top,bottom:b.bottom-cb.bottom};
        return {label:d.trace.name,math:!!math,ink:box(b),overflow,stored_width:d.width,
          math_style:math?math.getAttribute('style'):null,
          math_font_family:math?getComputedStyle(math).fontFamily:null,
          math_font_size:math?getComputedStyle(math).fontSize:null,
          math_key:math?(math.getAttribute('data-unformatted')+math.getAttribute('data-math')+
            math.getAttribute('text-anchor')+math.getAttribute('style')):null};
      });
      return {key,font:fl[key].font,width:fl[key]._width,height:fl[key]._height,clip:cb,
        clip_rect:box(rect.getBBox()),clip_owner_screen_ctm:[matrix.a,matrix.b,matrix.c,matrix.d,matrix.e,matrix.f],entries};
    });
  return JSON.stringify({plotly_version:Plotly.version,font:fl.font,width:fl.width,height:fl.height,
    plotly_script_sources:Array.from(document.scripts).map(s=>s.src).filter(Boolean),legends});
  } catch(error) {
    return JSON.stringify({diagnostic_error:String(error),stack:error.stack});
  }
})()
