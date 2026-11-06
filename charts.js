/* Petits graphiques en courbe (SVG, sans bibliothèque) et découpage en jours / semaines / mois. */
const nxNum = (n) => Number(n || 0).toLocaleString("fr-FR");
const NX_MONTHS = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."];
const nxShort = (iso) => { const [, m, d] = iso.split("-"); return `${+d} ${NX_MONTHS[+m - 1]}`; };
const nxSvg = (t, a) => { const e = document.createElementNS("http://www.w3.org/2000/svg", t); for (const [k, v] of Object.entries(a || {})) e.setAttribute(k, v); return e; };
// days : [{ day: "2026-11-05", ... }] du plus ancien au plus récent
function nxBuckets(days, g) {
  const n = days.length, out = [];
  if (g === "day") { for (let i = Math.max(0, n - 30); i < n; i++) out.push({ label: nxShort(days[i].day), from: i, to: i }); }
  else if (g === "week") { for (let b = 11; b >= 0; b--) { const to = n - 1 - b * 7, from = to - 6; if (from >= 0) out.push({ label: "sem. du " + nxShort(days[from].day), from, to }); } }
  else { const groups = []; days.forEach((d, i) => { const k = d.day.slice(0, 7), last = groups[groups.length - 1]; if (last && last.k === k) last.to = i; else groups.push({ k, from: i, to: i }); });
    for (const g2 of groups.slice(-12)) { const [y, m] = g2.k.split("-"); out.push({ label: NX_MONTHS[+m - 1] + " " + y, from: g2.from, to: g2.to }); } }
  return out;
}
  function nxLine(box, labels, series, opts = {}) {
    box.replaceChildren(); const W = Math.max(280, box.clientWidth || 560), H = 230, pad = { l: 38, r: 12, t: 12, b: 28 };
    const max0 = Math.max(1, ...series.flatMap((s) => s.values)), step = Math.pow(10, Math.floor(Math.log10(max0))), top = Math.ceil(max0 / step * 1.0) * step || 1;
    const niceTop = max0 <= 4 ? 4 : top, iw = W - pad.l - pad.r, ih = H - pad.t - pad.b, n = labels.length;
    const X = (i) => pad.l + (n === 1 ? iw / 2 : iw * i / (n - 1)), Y = (v) => pad.t + ih - ih * v / niceTop;
    const svg = nxSvg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img", "aria-label": opts.label || "Graphique" });
    const uid = "g" + Math.random().toString(36).slice(2, 7), defs = nxSvg("defs");
    series.forEach((s, k) => { const g = nxSvg("linearGradient", { id: uid + k, x1: 0, y1: 0, x2: 0, y2: 1 }); g.append(nxSvg("stop", { offset: "0%", "stop-color": s.color, "stop-opacity": series.length === 1 ? .35 : .12 }), nxSvg("stop", { offset: "100%", "stop-color": s.color, "stop-opacity": 0 })); defs.append(g); });
    svg.append(defs);
    for (let k = 0; k <= 4; k++) { const v = niceTop * k / 4, y = Y(v);
      svg.append(nxSvg("line", { x1: pad.l, x2: W - pad.r, y1: y, y2: y, stroke: "rgba(140,170,255,.13)", "stroke-dasharray": k ? "3 4" : "" }));
      const t = nxSvg("text", { x: pad.l - 7, y: y + 4, "text-anchor": "end", fill: "#7388b8", "font-size": 10.5 }); t.textContent = nxNum(Math.round(v * 10) / 10); svg.append(t); }
    const every = Math.max(1, Math.ceil(n / 6)); labels.forEach((l, i) => { if ((i % every === 0 && (n - 1 - i >= every || i === n - 1)) || i === n - 1) { const t = nxSvg("text", { x: X(i), y: H - 8, "text-anchor": i === 0 ? "start" : i === n - 1 ? "end" : "middle", fill: "#7388b8", "font-size": 10.5 }); t.textContent = l; svg.append(t); } });
    series.forEach((s, k) => {
      const pts = s.values.map((v, i) => [X(i), Y(v)]), d = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
      svg.append(nxSvg("path", { d: d + ` L${pts[n - 1][0].toFixed(1)} ${Y(0)} L${pts[0][0].toFixed(1)} ${Y(0)} Z`, fill: `url(#${uid}${k})` }));
      svg.append(nxSvg("path", { d, fill: "none", stroke: s.color, "stroke-width": 2.4, "stroke-linejoin": "round", "stroke-linecap": "round" }));
    });
    const vline = nxSvg("line", { y1: pad.t, y2: H - pad.b, stroke: "rgba(160,190,255,.45)", visibility: "hidden" }), dots = series.map((s) => nxSvg("circle", { r: 4.5, fill: s.color, stroke: "#050c1f", "stroke-width": 2, visibility: "hidden" }));
    svg.append(vline, ...dots);
    const tip = (() => { const d = document.createElement("div"); d.className = "tip hidden"; return d; })(); box.append(svg, tip);
    const over = nxSvg("rect", { x: pad.l, y: 0, width: iw, height: H, fill: "transparent" });
    over.addEventListener("pointermove", (e) => {
      const r = svg.getBoundingClientRect(), x = (e.clientX - r.left) * (W / r.width), i = Math.max(0, Math.min(n - 1, Math.round((x - pad.l) / iw * (n - 1))));
      vline.setAttribute("x1", X(i)); vline.setAttribute("x2", X(i)); vline.setAttribute("visibility", "visible");
      dots.forEach((c, k) => { c.setAttribute("cx", X(i)); c.setAttribute("cy", Y(series[k].values[i])); c.setAttribute("visibility", "visible"); });
      tip.replaceChildren(); const b = document.createElement("b"); b.textContent = labels[i]; tip.append(b);
      for (const s of series) { const row = document.createElement("div"), dot = document.createElement("i"); dot.style.background = s.color; row.append(dot, `${s.name} : ${nxNum(s.values[i])}`); tip.append(row); }
      tip.classList.remove("hidden"); tip.style.left = Math.max(70, Math.min(W - 70, X(i))) + "px"; tip.style.top = Math.min(...series.map((s) => Y(s.values[i]))) + "px";
    });
    over.addEventListener("pointerleave", () => { vline.setAttribute("visibility", "hidden"); dots.forEach((c) => c.setAttribute("visibility", "hidden")); tip.classList.add("hidden"); });
    svg.append(over);
  }


// Mini courbe (sans axes) pour une carte de chiffre clé
function nxSpark(box, values, color) {
  box.replaceChildren(); const W = Math.max(60, box.clientWidth || 120), H = 38, n = values.length, max = Math.max(1, ...values);
  const X = (i) => n === 1 ? W / 2 : 2 + (W - 4) * i / (n - 1), Y = (v) => H - 4 - (H - 8) * v / max;
  const svg = nxSvg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, "aria-hidden": "true" }), uid = "s" + Math.random().toString(36).slice(2, 7);
  const defs = nxSvg("defs"), g = nxSvg("linearGradient", { id: uid, x1: 0, y1: 0, x2: 0, y2: 1 });
  g.append(nxSvg("stop", { offset: "0%", "stop-color": color, "stop-opacity": .4 }), nxSvg("stop", { offset: "100%", "stop-color": color, "stop-opacity": 0 })); defs.append(g); svg.append(defs);
  const d = values.map((v, i) => (i ? "L" : "M") + X(i).toFixed(1) + " " + Y(v).toFixed(1)).join(" ");
  svg.append(nxSvg("path", { d: d + ` L${X(n - 1).toFixed(1)} ${H} L${X(0).toFixed(1)} ${H} Z`, fill: `url(#${uid})` }), nxSvg("path", { d, fill: "none", stroke: color, "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round" }));
  box.append(svg);
}
// Anneau (jauge ou répartition) : parts = [{ value, color }]
function nxRing(box, parts, centerTop, centerBottom, size = 150) {
  box.replaceChildren(); const r = size / 2 - 12, c = 2 * Math.PI * r, total = parts.reduce((a, p) => a + p.value, 0);
  const svg = nxSvg("svg", { viewBox: `0 0 ${size} ${size}`, width: size, height: size, role: "img" });
  svg.append(nxSvg("circle", { cx: size / 2, cy: size / 2, r, fill: "none", stroke: "rgba(140,170,255,.14)", "stroke-width": 14 }));
  let off = 0;
  if (total > 0) for (const p of parts) { const len = c * p.value / total; if (len <= 0) continue;
    svg.append(nxSvg("circle", { cx: size / 2, cy: size / 2, r, fill: "none", stroke: p.color, "stroke-width": 14, "stroke-linecap": parts.length === 1 ? "round" : "butt",
      "stroke-dasharray": `${Math.max(0, len - (parts.length > 1 ? 2 : 0))} ${c}`, "stroke-dashoffset": -off, transform: `rotate(-90 ${size / 2} ${size / 2})` })); off += len; }
  const t1 = nxSvg("text", { x: size / 2, y: size / 2 + 2, "text-anchor": "middle", fill: "#fff", "font-size": 26, "font-weight": 700 }); t1.textContent = centerTop;
  const t2 = nxSvg("text", { x: size / 2, y: size / 2 + 20, "text-anchor": "middle", fill: "#8ea3d0", "font-size": 11 }); t2.textContent = centerBottom || "";
  svg.append(t1, t2); box.append(svg);
}
