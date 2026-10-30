// Barre de navigation du bas : un seul composant, construit au même endroit du code pour tous les écrans (carte, fil, compte).
// Utilisation : <script src="tabbar.js" data-active="notifications|account" (rien : la carte)></script> à l'endroit où la barre doit apparaître.
(function () {
  const me = document.currentScript, active = me && me.dataset.active || "";
  const svg = (inner) => `<svg viewBox="0 0 24 24" aria-hidden="true">${inner}</svg>`;
  const TABS = [
    ["map", "tab-map", null, "Carte", svg('<path d="M4 11l8-7 8 7v8a1 1 0 0 1-1 1h-4v-6H9v6H5a1 1 0 0 1-1-1z"/>')],      // bouton gardé mais volontairement sans action : la carte s'ouvre avec le bouton rond
    ["search", "tab-search", "/?search=1", "Chercher", svg('<circle cx="12" cy="12" r="9"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>')],
    ["locate", "tab-locate", "/", null, svg('<path d="M12 21s7-5.6 7-11.2A7 7 0 0 0 5 9.8C5 15.4 12 21 12 21z"/><circle cx="12" cy="10" r="2.4"/>')],
    ["notifications", "tab-notifs", "notifications.html", "Notifications", svg('<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4"/>')],
    ["account", "tab-account", "compte.html", "Compte", svg('<circle cx="12" cy="8" r="3.6"/><path d="M5 20a7 7 0 0 1 14 0z"/>')],
  ];
  const nav = document.createElement("nav"); nav.id = "tabbar"; nav.setAttribute("aria-label", "Navigation principale");
  for (const [key, id, href, label, icon] of TABS) {
    const a = document.createElement(href ? "a" : "button"); a.id = id; if (href) a.href = href; else a.type = "button";
    if (label) { a.className = "tab" + (key === active ? " on" : ""); a.innerHTML = icon + "<span>" + label + "</span>"; } else { a.setAttribute("aria-label", "Ma position"); a.innerHTML = icon; }
    if (key === active) a.setAttribute("aria-current", "page");
    nav.append(a);
  }
  me.before(nav);
  // Indicateur qui glisse sous l'onglet actif. Seule la propriété « transform » est animée (calculée par la carte graphique) : fluide même sur un petit téléphone.
  const ind = document.createElement("span"); ind.id = "tab-indicator"; ind.setAttribute("aria-hidden", "true"); nav.prepend(ind);
  const KEY = "nooxel_tab_prev", links = () => [...nav.querySelectorAll(".tab")];
  const place = (a) => { const r = a.getBoundingClientRect(), n = nav.getBoundingClientRect(); if (!r.width) return false; ind.style.width = (r.width - 12) + "px"; ind.style.transform = `translate3d(${r.left - n.left - nav.clientLeft + 6}px,0,0)`; ind.hidden = false; return true; };
  const current = () => nav.querySelector(".tab.on");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const jump = (a) => { ind.style.transition = "none"; place(a); void ind.offsetWidth; ind.style.transition = ""; };      // sans animation (démarrage, rotation)
  let last = null;
  const sync = (animate) => {
    const cur = current();
    if (!cur) { ind.style.opacity = "0"; last = null; try { sessionStorage.setItem(KEY, ""); } catch (e) {} return; }       // sur la carte : le bouton rond est « actif », pas d'indicateur
    ind.style.opacity = "";
    if (!animate || reduce || !last) jump(cur); else place(cur);
    last = cur; try { sessionStorage.setItem(KEY, cur.id); } catch (e) {}
  };
  // D'une page à l'autre : l'indicateur repart de l'onglet quitté puis glisse vers le nouveau.
  let prevId = null; try { prevId = sessionStorage.getItem(KEY); } catch (e) {}
  const prev = prevId ? nav.querySelector("#" + prevId + ".tab") : null;
  ind.hidden = true;
  const start = () => {
    const cur = current();
    if (!cur) { if (prev && !reduce && place(prev)) { ind.dataset.from = prev.id; ind.style.opacity = "1"; void ind.offsetWidth; requestAnimationFrame(() => requestAnimationFrame(() => { ind.style.opacity = "0"; })); } else ind.style.opacity = "0"; return; }
    if (prev && prev !== cur && !reduce && place(prev)) { ind.dataset.from = prev.id; last = prev; void ind.offsetWidth; requestAnimationFrame(() => requestAnimationFrame(() => sync(true))); }
    else sync(false);
  };
  if (document.readyState === "complete") start(); else addEventListener("load", start, { once: true });
  new MutationObserver(() => sync(true)).observe(nav, { subtree: true, attributes: true, attributeFilter: ["class"] });     // la carte change d'onglet sans changer de page
  new ResizeObserver(() => { if (last) sync(false); }).observe(nav);
  // Pastille du nombre de notifications non lues (la page peut aussi l'imposer : window.setNotifBadge(n)).
  const badge = document.createElement("span"); badge.id = "notif-badge"; badge.hidden = true; badge.setAttribute("aria-live", "polite");
  nav.querySelector("#tab-notifs").append(badge);
  window.setNotifBadge = (n) => { n = Math.max(0, n | 0); badge.hidden = !n; badge.textContent = n > 9 ? "9+" : String(n); nav.querySelector("#tab-notifs").setAttribute("aria-label", n ? `Notifications, ${n} non lue${n > 1 ? "s" : ""}` : "Notifications"); };
  let busy = false;
  const refresh = async () => {
    if (busy || document.hidden) return; busy = true;
    try { const c = typeof sb !== "undefined" ? sb : null; if (c) { const { data, error } = await c.rpc("my_unread_count"); if (!error && typeof data === "number") window.setNotifBadge(data); } } catch (e) {}
    busy = false;
  };
  addEventListener("load", () => setTimeout(refresh, 400)); document.addEventListener("visibilitychange", refresh); setInterval(refresh, 60000);
  window.addEventListener("notifs-changed", refresh);
})();
