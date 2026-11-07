/* Commentaires des vidéos et des publications : feuille qui monte du bas (comme la maquette).
   Utilisation : openComments({ kind: "video" | "post", id, count, onCount(n) })
   Dépend de shop.js (el, sb, icon, avatarUrl, silhouette, reviewBadge, fr). */
(function () {
  const CSS = `
  #cm-overlay { position: fixed; inset: 0; z-index: 60; background: rgba(0,0,0,.55); display: flex; align-items: flex-end; justify-content: center; }
  #cm-sheet { width: 100%; max-width: 560px; height: min(82vh, 760px); display: flex; flex-direction: column; background: #061333; color: #e8efff; border-radius: 30px 30px 0 0; border-top: 1px solid rgba(120,160,255,.22); box-shadow: 0 -12px 50px rgba(0,0,0,.55); font: 16px/1.45 system-ui, -apple-system, sans-serif; animation: cm-up .25s ease-out; }
  @keyframes cm-up { from { transform: translateY(40px); opacity: 0; } to { transform: none; opacity: 1; } }
  #cm-sheet .grab { width: 54px; height: 5px; border-radius: 999px; background: #6f7fb3; margin: .7rem auto .2rem; flex: none; }
  #cm-sheet header { display: flex; align-items: center; justify-content: space-between; padding: .6rem 1.2rem .8rem; border-bottom: 1px solid rgba(120,160,255,.18); flex: none; }
  #cm-sheet header h2 { margin: 0; font-size: 1.45rem; font-weight: 700; } #cm-sheet header h2 span { font-weight: 400; color: #b8c7e8; }
  #cm-sheet header button { border: 0; background: none; color: #fff; width: 44px; height: 44px; display: grid; place-items: center; cursor: pointer; }
  #cm-sheet header svg { width: 26px; height: 26px; stroke: currentColor; stroke-width: 2.2; fill: none; stroke-linecap: round; }
  #cm-list { flex: 1; overflow-y: auto; padding: .4rem 1.2rem; overscroll-behavior: contain; }
  .cm { display: flex; gap: .8rem; padding: .85rem 0; }
  .cm .av { width: 52px; height: 52px; border-radius: 50%; object-fit: cover; flex: none; background: #14285a; } .cm .av.silhouette { display: inline-flex; }
  .cm .main { flex: 1; min-width: 0; }
  .cm .l1 { display: flex; align-items: center; gap: .3rem; flex-wrap: wrap; } .cm .l1 b { font-size: 1.05rem; } .cm .l1 .t { margin-left: auto; color: #8ea3d0; font-size: .95rem; }
  .cm .rbadge { margin-left: .2rem; font-size: .78rem; padding: .12rem .6rem .12rem .45rem; }
  .cm .txt { margin: .15rem 0 .1rem; font-size: 1.05rem; overflow-wrap: anywhere; white-space: pre-wrap; }
  .cm .acts { display: flex; gap: 1rem; align-items: center; } .cm .acts button { border: 0; background: none; color: #7f95c9; font: inherit; font-size: .95rem; padding: .25rem 0; cursor: pointer; display: inline-flex; align-items: center; gap: .4rem; } .cm .acts svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
  .cm .acts .del { color: #ff7a7a; }
  .cm .lk { display: flex; flex-direction: column; align-items: center; gap: .1rem; width: 52px; flex: none; border: 0; background: none; color: #e8efff; font: inherit; font-size: 1rem; cursor: pointer; padding: .1rem 0 0; }
  .cm .lk svg { width: 30px; height: 30px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; } .cm .lk.liked svg { fill: #ff5a7a; stroke: #ff5a7a; }
  .cm.cm-reply { margin-left: 1.1rem; padding-left: .9rem; position: relative; } .cm.cm-reply::before { content: ""; position: absolute; left: 0; top: 1.1rem; width: 2px; height: 2.6rem; background: rgba(120,160,255,.45); }
  .cm.cm-reply .av { width: 44px; height: 44px; }
  #cm-more { display: block; margin: .6rem auto 1rem; border: 1px solid rgba(120,160,255,.35); background: none; color: #9db4e8; border-radius: 999px; padding: .5rem 1.2rem; font: inherit; cursor: pointer; }
  #cm-empty { text-align: center; color: #8ea3d0; padding: 2.5rem 1rem; }
  #cm-replying { display: flex; align-items: center; justify-content: space-between; padding: .4rem 1.2rem; font-size: .88rem; color: #9db4e8; background: rgba(75,149,255,.1); flex: none; } #cm-replying button { border: 0; background: none; color: #9db4e8; font-size: 1.1rem; cursor: pointer; }
  #cm-compose { display: flex; align-items: center; gap: .7rem; padding: .8rem 1.1rem calc(.8rem + env(safe-area-inset-bottom, 0px)); border-top: 1px solid rgba(120,160,255,.18); flex: none; }
  #cm-compose .av { width: 46px; height: 46px; border-radius: 50%; object-fit: cover; flex: none; background: #14285a; }
  #cm-input { flex: 1; min-width: 0; height: 52px; border-radius: 999px; border: 1.5px solid rgba(120,160,255,.35); background: transparent; color: #e8efff; font: inherit; font-size: 16px; padding: 0 1.2rem; outline: none; } #cm-input::placeholder { color: #8ea3d0; } #cm-input:focus { border-color: #4b95ff; }
  #cm-send { width: 54px; height: 54px; border-radius: 50%; border: 0; background: #2a56b8; color: #fff; display: grid; place-items: center; cursor: pointer; flex: none; } #cm-send:disabled { opacity: .5; } #cm-send svg { width: 26px; height: 26px; fill: #fff; stroke: none; }
  #cm-err { color: #ff8a72; font-size: .85rem; padding: 0 1.2rem .3rem; min-height: 0; }
  `;
  const MSG = { comment_contains_link: "Les liens et numéros de téléphone ne sont pas autorisés dans un commentaire.", comment_insult: "Ce commentaire contient un mot interdit. Restez respectueux.",
    comment_gibberish: "Ce commentaire n'a pas l'air d'un vrai message.", comment_empty: "Écrivez quelque chose avant d'envoyer.", comment_too_long: "Commentaire trop long (500 caractères maximum).",
    too_many_comments: "Vous commentez trop vite : réessayez dans un moment.", email_not_confirmed: "Confirmez d'abord votre adresse email.", pseudo_required: "Choisissez d'abord un pseudo dans votre profil.",
    not_found: "Ce contenu n'existe plus.", comments_disabled: "Les commentaires sont désactivés pour cette publication.", too_many_likes: "Trop de ♥ pour le moment. Réessayez plus tard." };
  const errMsg = (e) => { const m = String(e && e.message || e || ""), k = Object.keys(MSG).find((c) => m.includes(c)); return k ? MSG[k] : "Envoi impossible pour le moment. Réessayez dans un instant."; };
  const short = (d) => { const s = Math.max(0, (Date.now() - new Date(d).getTime()) / 1000); if (s < 60) return "à l'instant"; if (s < 3600) return Math.floor(s / 60) + " min"; if (s < 86400) return Math.floor(s / 3600) + "h"; if (s < 604800) return Math.floor(s / 86400) + "j"; return Math.floor(s / 604800) + " sem"; };
  const SEND = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2.5 11.2 21 3.3c.8-.3 1.5.4 1.2 1.2l-7.9 18.5c-.4.9-1.7.8-2-.1l-2.3-6.6-6.6-2.3c-.9-.3-1-1.6-.1-1.8z"/></svg>';
  const X = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 5l14 14M19 5L5 19"/></svg>';
  let myAvatar;      // undefined = pas encore chargé ; null = aucune photo

  window.openComments = async function (opts) {
    const { kind, id } = opts; let total = Number(opts.count || 0), before = null, replyTo = null, sending = false, done = false;
    if (!document.getElementById("cm-style")) { const st = document.createElement("style"); st.id = "cm-style"; st.textContent = CSS; document.head.append(st); }
    const old = document.getElementById("cm-overlay"); if (old) old.remove();
    const avatar = (path, cls) => path ? el("img", { class: cls, src: avatarUrl(path), alt: "", loading: "lazy" }) : (() => { const s = silhouette(50); s.className += " " + cls; s.style.width = s.style.height = ""; return s; })();
    const title = el("h2", {}, "Commentaires ", el("span", { id: "cm-count", text: `(${total})` }));
    const list = el("div", { id: "cm-list" }), more = el("button", { id: "cm-more", type: "button", class: "hidden", text: "Voir plus de commentaires" });
    const err = el("div", { id: "cm-err", role: "alert" });
    const input = el("input", { id: "cm-input", type: "text", maxlength: 500, placeholder: "Ajouter un commentaire…", autocomplete: "off", enterkeyhint: "send" });
    const send = el("button", { id: "cm-send", type: "button", "aria-label": "Envoyer" }); send.innerHTML = SEND;
    const replying = el("div", { id: "cm-replying", class: "hidden" });
    const meSlot = el("span", {});
    const close = el("button", { type: "button", id: "cm-close", "aria-label": "Fermer" }); close.innerHTML = X;
    const sheet = el("div", { id: "cm-sheet", role: "dialog", "aria-modal": "true", "aria-label": "Commentaires" },
      el("div", { class: "grab" }), el("header", {}, title, close), list, replying, err, el("div", { id: "cm-compose" }, meSlot, input, send));
    const overlay = el("div", { id: "cm-overlay" }, sheet); document.body.append(overlay);
    const shut = () => { overlay.remove(); document.removeEventListener("keydown", onKey); };
    const onKey = (e) => { if (e.key === "Escape") shut(); }; document.addEventListener("keydown", onKey);
    overlay.addEventListener("click", (e) => { if (e.target === overlay) shut(); }); close.addEventListener("click", shut);
    const setTotal = (n) => { total = Math.max(0, n); $("cm-count").textContent = `(${total})`; if (opts.onCount) opts.onCount(total); };

    function row(c, isReply, parent) {
      const heart = el("button", { class: "lk" + (c.liked ? " liked" : ""), type: "button", "data-like": c.id, "aria-pressed": String(!!c.liked), "aria-label": "J'aime" }, icon("heart"), el("span", { class: "n", text: String(c.like_count) }));
      heart.addEventListener("click", async () => {
        const was = heart.classList.contains("liked"); heart.classList.toggle("liked", !was); heart.querySelector(".n").textContent = String(c.like_count + (was ? -1 : 1));
        const { data, error } = await sb.rpc(was ? "unlike_comment" : "like_comment", { p_comment: c.id });
        if (error) { heart.classList.toggle("liked", was); heart.querySelector(".n").textContent = String(c.like_count); err.textContent = errMsg(error); return; }
        c.like_count = data; c.liked = !was; heart.querySelector(".n").textContent = String(data); heart.setAttribute("aria-pressed", String(!was));
      });
      const acts = el("div", { class: "acts" }, el("button", { type: "button", "data-reply": c.id, onclick: () => startReply(isReply ? parent : c, c) }, replyIcon(), "Répondre"));
      const box = el("div", { class: "cm" + (isReply ? " cm-reply" : ""), "data-comment": c.id }, avatar(c.avatar_path, "av"),
        el("div", { class: "main" }, el("div", { class: "l1" }, el("b", { text: c.pseudo || "Utilisateur" }), c.badge ? reviewBadge(c.badge) : null, el("span", { class: "t", text: short(c.created_at) })),
          el("div", { class: "txt", text: c.body }), acts), heart);
      if (c.can_delete) acts.append(el("button", { class: "del", type: "button", "data-del": c.id, text: "Supprimer", onclick: async () => {
        if (!confirm("Supprimer ce commentaire ?")) return; const { error } = await sb.rpc("delete_comment", { p_comment: c.id }); if (error) { err.textContent = errMsg(error); return; }
        const gone = 1 + (isReply ? 0 : box.parentElement.querySelectorAll(`[data-parent="${c.id}"]`).length); box.parentElement.querySelectorAll(`[data-parent="${c.id}"]`).forEach((r) => r.remove()); box.remove(); setTotal(total - gone);
        if (!list.querySelector(".cm")) list.replaceChildren(empty());
      } }));
      return box;
    }
    const replyIcon = () => { const s = document.createElement("span"); s.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 14 4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 6 6v3"/></svg>'; return s.firstChild; };
    const empty = () => el("p", { id: "cm-empty", text: "Aucun commentaire pour le moment. Soyez le premier !" });
    function startReply(parent, target) {
      replyTo = parent; replying.classList.remove("hidden"); replying.replaceChildren(el("span", { text: "Réponse à " + (target.pseudo || "Utilisateur") }), el("button", { type: "button", "aria-label": "Annuler la réponse", text: "✕", onclick: stopReply }));
      input.placeholder = "Répondre à " + (target.pseudo || "Utilisateur") + "…"; input.focus();
    }
    function stopReply() { replyTo = null; replying.classList.add("hidden"); input.placeholder = "Ajouter un commentaire…"; }
    function addToList(c, atTop) {
      const group = el("div", { class: "cm-group", "data-group": c.id }); const r = row(c, false); group.append(r);
      for (const x of c.replies || []) { const rr = row(x, true, c); rr.dataset.parent = c.id; group.append(rr); }
      if (atTop) list.prepend(group); else list.append(group);
    }
    async function load() {
      const { data, error } = await sb.rpc("list_comments", { p_kind: kind, p_item: id, p_before: before, p_limit: 20 });
      if (error) { list.replaceChildren(el("p", { id: "cm-empty", text: errMsg(error) })); return; }
      if (!before) { list.replaceChildren(); setTotal(data.total); }
      for (const c of data.items) addToList(c, false);
      if (data.items.length) before = data.items[data.items.length - 1].created_at;
      more.classList.toggle("hidden", data.items.length < 20);
      if (!list.querySelector(".cm")) list.replaceChildren(empty()); else list.append(more);
    }
    more.addEventListener("click", () => { more.remove(); load(); });
    async function submit() {
      if (sending) return; const body = input.value.trim(); err.textContent = ""; if (!body) return;
      sending = true; send.disabled = true;
      const { data, error } = await sb.rpc("add_comment", { p_kind: kind, p_item: id, p_body: body, p_parent: replyTo ? replyTo.id : null });
      sending = false; send.disabled = false;
      if (error) { err.textContent = errMsg(error); return; }
      input.value = ""; const emptyEl = list.querySelector("#cm-empty"); if (emptyEl) emptyEl.remove();
      if (replyTo) { const g = list.querySelector(`[data-group="${replyTo.id}"]`); const rr = row(data, true, replyTo); rr.dataset.parent = replyTo.id; if (g) g.append(rr); }
      else { addToList({ ...data, replies: [] }, true); list.scrollTop = 0; }
      stopReply(); setTotal(total + 1);
    }
    send.addEventListener("click", submit); input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); submit(); } });
    // avatar de la personne connectée
    (async () => { if (myAvatar === undefined) { try { const { data } = await sb.rpc("my_profile_summary"); myAvatar = (data && data.avatar_path) || null; } catch (e) { myAvatar = null; } } meSlot.replaceWith(avatar(myAvatar, "av")); })();
    await load();
  };
})();
