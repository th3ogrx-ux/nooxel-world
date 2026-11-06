/* Fenêtre de confirmation aux couleurs de l'app (remplace la boîte grise du navigateur).
   Utilisation : if (await nxConfirm({ title, text, ok: "Oui, annuler", cancel: "Non, la garder", danger: true })) { … } */
(function () {
  const CSS = `
  #nxc { position: fixed; inset: 0; z-index: 90; display: flex; align-items: center; justify-content: center; padding: 1.2rem; background: rgba(2,6,18,.72); backdrop-filter: blur(6px); animation: nxc-in .18s ease-out; }
  @keyframes nxc-in { from { opacity: 0; } to { opacity: 1; } } @keyframes nxc-pop { from { transform: translateY(14px) scale(.97); opacity: 0; } to { transform: none; opacity: 1; } }
  #nxc .box { width: 100%; max-width: 380px; border-radius: 28px; padding: 1.6rem 1.4rem 1.3rem; text-align: center; color: #e8efff; font: 16px/1.5 system-ui, -apple-system, sans-serif;
    background: radial-gradient(120% 80% at 50% 0%, #11307a 0%, #0a1a45 45%, #060f2a 100%); border: 1px solid rgba(120,160,255,.28); box-shadow: 0 24px 70px rgba(0,0,0,.65), inset 0 1px 0 rgba(255,255,255,.07); animation: nxc-pop .22s ease-out; }
  #nxc .ico { width: 70px; height: 70px; margin: 0 auto 1rem; border-radius: 50%; display: grid; place-items: center; background: rgba(255,90,60,.14); box-shadow: 0 0 0 1.5px rgba(255,120,100,.4), 0 0 30px rgba(255,90,60,.25); color: #ff8a72; }
  #nxc .ico.info { background: rgba(75,149,255,.16); box-shadow: 0 0 0 1.5px rgba(111,168,255,.45), 0 0 30px rgba(47,123,255,.3); color: #7fb4ff; }
  #nxc .ico svg { width: 34px; height: 34px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
  #nxc h2 { margin: 0 0 .5rem; font-size: 1.3rem; letter-spacing: -.01em; } #nxc p { margin: 0 0 1.3rem; color: #a9bce6; font-size: .96rem; }
  #nxc .row { display: grid; gap: .6rem; }
  #nxc button { height: 50px; border-radius: 16px; border: 0; font: inherit; font-weight: 600; font-size: 1rem; cursor: pointer; }
  #nxc .ok { color: #fff; background: linear-gradient(180deg, #ef5a4f, #cf3328); box-shadow: 0 8px 22px rgba(229,72,61,.35); } #nxc .ok.info { background: linear-gradient(180deg, #3b8bff, #1f63e6); box-shadow: 0 8px 22px rgba(47,123,255,.4); }
  #nxc .no { color: #cfe0ff; background: rgba(255,255,255,.07); border: 1px solid rgba(140,170,255,.25); }
  #nxc button:active { transform: scale(.98); } #nxc button:disabled { opacity: .6; }
  `;
  const ICON = { danger: '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16.4v.1"/>', info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 7.6v.1"/>' };
  window.nxConfirm = function ({ title, text, ok = "Confirmer", cancel = "Annuler", danger = true } = {}) {
    return new Promise((resolve) => {
      if (!document.getElementById("nxc-style")) { const st = document.createElement("style"); st.id = "nxc-style"; st.textContent = CSS; document.head.append(st); }
      const prev = document.activeElement, mk = (tag, cls, txt) => { const e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; };
      const overlay = mk("div"); overlay.id = "nxc"; const box = mk("div", "box"); box.setAttribute("role", "alertdialog"); box.setAttribute("aria-modal", "true");
      const ico = mk("div", "ico" + (danger ? "" : " info")); ico.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICON[danger ? "danger" : "info"] + "</svg>";
      const h = mk("h2", "", title), p = mk("p", "", text), row = mk("div", "row"), yes = mk("button", "ok" + (danger ? "" : " info"), ok), no = mk("button", "no", cancel);
      yes.type = no.type = "button"; yes.id = "nxc-ok"; no.id = "nxc-cancel"; row.append(yes, no); box.append(ico, h, p, row); overlay.append(box); document.body.append(overlay);
      const done = (v) => { document.removeEventListener("keydown", key); overlay.remove(); try { prev && prev.focus && prev.focus(); } catch (e) {} resolve(v); };
      const key = (e) => { if (e.key === "Escape") done(false); }; document.addEventListener("keydown", key);
      yes.addEventListener("click", () => done(true)); no.addEventListener("click", () => done(false)); overlay.addEventListener("click", (e) => { if (e.target === overlay) done(false); });
      no.focus();
    });
  };
})();
