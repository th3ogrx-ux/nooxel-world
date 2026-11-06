/* Statistiques du commerçant : envoie, par petits lots, « quelqu'un a vu / cliqué ». Aucune donnée personnelle côté page ;
   la base ne garde que des compteurs par jour et compte une personne une seule fois par jour et par élément.
   Un échec est ignoré : une statistique ne doit jamais gêner l'application. */
(function () {
  const queue = new Map(); let timer = null; const sent = new Set();
  function flush() {
    timer = null; if (!queue.size || typeof sb === "undefined" || !sb) return Promise.resolve();
    const events = [...queue.values()]; queue.clear();
    try { return Promise.resolve(sb.rpc("track_events", { p_events: events })).then(() => {}, () => {}); } catch (e) { return Promise.resolve(); }
  }
  window.nxTrack = function (metric, merchant, item) {
    if (!merchant || !metric) return;
    const key = metric + "|" + merchant + "|" + (item || ""); if (sent.has(key)) return; sent.add(key);      // une fois par chargement de page
    queue.set(key, { metric, merchant, item: item || null }); if (!timer) timer = setTimeout(flush, 800);
  };
  window.nxFlush = () => { clearTimeout(timer); return flush(); };       // envoie tout de suite (avant de changer de page)
  addEventListener("pagehide", flush);
})();
