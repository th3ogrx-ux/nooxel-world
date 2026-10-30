// Barre de navigation du bas : un seul composant, construit au même endroit du code pour tous les écrans (carte, fil, compte).
// Utilisation : <script src="tabbar.js" data-active="map|feed|account"></script> à l'endroit où la barre doit apparaître.
(function () {
  const me = document.currentScript, active = me && me.dataset.active || "";
  const svg = (inner) => `<svg viewBox="0 0 24 24" aria-hidden="true">${inner}</svg>`;
  const TABS = [
    ["map", "tab-map", "/", "Carte", svg('<path d="M4 11l8-7 8 7v8a1 1 0 0 1-1 1h-4v-6H9v6H5a1 1 0 0 1-1-1z"/>')],
    ["search", "tab-search", "/?search=1", "Chercher", svg('<circle cx="12" cy="12" r="9"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>')],
    ["locate", "tab-locate", "/", null, svg('<path d="M12 21s7-5.6 7-11.2A7 7 0 0 0 5 9.8C5 15.4 12 21 12 21z"/><circle cx="12" cy="10" r="2.4"/>')],
    ["feed", "tab-feed", "fil.html", "Fil", svg('<path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"/>')],
    ["account", "tab-account", "compte.html", "Compte", svg('<circle cx="12" cy="8" r="3.6"/><path d="M5 20a7 7 0 0 1 14 0z"/>')],
  ];
  const nav = document.createElement("nav"); nav.id = "tabbar"; nav.setAttribute("aria-label", "Navigation principale");
  for (const [key, id, href, label, icon] of TABS) {
    const a = document.createElement("a"); a.id = id; a.href = href;
    if (label) { a.className = "tab" + (key === active ? " on" : ""); a.innerHTML = icon + "<span>" + label + "</span>"; } else { a.setAttribute("aria-label", "Ma position"); a.innerHTML = icon; }
    if (key === active) a.setAttribute("aria-current", "page");
    nav.append(a);
  }
  me.before(nav);
})();
