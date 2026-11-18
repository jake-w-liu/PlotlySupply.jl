(function (svgText) {
  let diagnostic;
  try {
  const live = document.querySelector('.js-plotly-plot');
  if (!live) throw new Error('live plot is missing');
  if (svgText.includes('TOBESTRIPPED')) throw new Error('SVG contains a quote placeholder');
  const parsed = new DOMParser().parseFromString(svgText, 'image/svg+xml');
  if (parsed.querySelector('parsererror')) throw new Error('exported SVG is not valid XML');
  const before = live.outerHTML;
  const inserted = document.importNode(parsed.documentElement, true);
  inserted.style.position = 'absolute';
  inserted.style.left = '0';
  inserted.style.top = '0';
  function fonts(root, selector, visibleOnly) {
    return Array.from(root.querySelectorAll(selector)).filter(n => {
      const s = getComputedStyle(n);
      return !visibleOnly || (s.display !== 'none' && s.visibility !== 'hidden');
    }).map(n => ({tag:n.localName, class:n.getAttribute('class'), text:n.textContent,
      styleFamily:n.style.fontFamily, computedFamily:getComputedStyle(n).fontFamily,
      styleSize:n.style.fontSize, computedSize:getComputedStyle(n).fontSize}));
  }
  function gradients(root) {
    function reference(id, seen) {
      if (seen.includes(id)) throw new Error('cyclic gradient reference');
      const target = root.querySelector('[id="' + CSS.escape(id) + '"]');
      if (!target) throw new Error('gradient or pattern reference has no target');
      return describe(target, [...seen, id]);
    }
    function value(input, seen) {
      if (!input.includes('url(')) return input;
      const match = /#([^"')]+)/.exec(input);
      if (!match) throw new Error('gradient reference is not local');
      return reference(match[1], seen);
    }
    function describe(node, seen) {
      const attributes = Array.from(node.attributes).filter(a => a.name !== 'id').map(a => {
        if (a.name === 'style') return [a.name, Array.from(node.style).sort().map(k => [k, value(node.style[k], seen)])];
        if ((a.name === 'href' || a.name === 'xlink:href') && a.value.startsWith('#')) {
          return [a.name, reference(a.value.slice(1), seen)];
        }
        return [a.name, value(a.value, seen)];
      }).sort((a,b) => a[0].localeCompare(b[0]));
      return {tag:node.localName, attributes, children:Array.from(node.children).map(n => describe(n, seen))};
    }
    return Array.from(root.querySelectorAll('*')).filter(n =>
      (n.style.fill || '').includes('url(') || (n.style.stroke || '').includes('url('))
    .map(n => {
      return {tag:n.localName, class:n.getAttribute('class'), fill:value(n.style.fill, []), stroke:value(n.style.stroke, []),
        computedFill:value(getComputedStyle(n).fill, []), computedStroke:value(getComputedStyle(n).stroke, [])};
    });
  }
  document.body.appendChild(inserted);
  let report;
  try {
    const sourceText = fonts(live, 'text', true), parsedText = fonts(inserted, 'text', true);
    const sourceMath = fonts(live, 'g[data-math="Y"]', false), parsedMath = fonts(inserted, 'g[data-math="Y"]', false);
    const sourceGradients = gradients(live), parsedGradients = gradients(inserted);
    diagnostic = {sourceText, parsedText, sourceMath, parsedMath, sourceGradients, parsedGradients};
    if (JSON.stringify(sourceText) !== JSON.stringify(parsedText)) throw new Error('ordinary text font identity changed');
    if (JSON.stringify(sourceMath) !== JSON.stringify(parsedMath)) throw new Error('math group font identity changed');
    if (JSON.stringify(sourceGradients) !== JSON.stringify(parsedGradients)) throw new Error('gradient or pattern identity changed');
    report = {passed:true, xml_parses:true, placeholders_absent:true,
      text_nodes:sourceText.length, math_groups:sourceMath.length, gradient_nodes:sourceGradients.length,
      source_text:sourceText, parsed_text:parsedText, source_math:sourceMath, parsed_math:parsedMath,
      source_gradients:sourceGradients, parsed_gradients:parsedGradients};
    function rawUrls(root) {
      return Array.from(root.querySelectorAll('*')).filter(n =>
        (n.style.fill || '').includes('url(') || (n.style.stroke || '').includes('url('))
      .map(n => ({fill:n.style.fill, stroke:n.style.stroke}));
    }
    report.source_gradient_urls = rawUrls(live);
    report.parsed_gradient_urls = rawUrls(inserted);
  } finally {
    inserted.remove();
  }
  if (live.outerHTML !== before) throw new Error('SVG readback changed the live plot');
  report.live_dom_unchanged = true;
  return JSON.stringify(report);
  } catch (error) {
    return JSON.stringify({passed:false, diagnostic_error:String(error), stack:error.stack, diagnostic});
  }
})(__PS_SVG_TEXT__)
