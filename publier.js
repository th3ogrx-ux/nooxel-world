/* Écran « Nouvelle publication » (photo pour le fil, vidéo pour l'onglet Vidéos).
   Utilisation : nxPublish("photo" | "video", merchantId) : ouvre le choix du fichier puis l'écran. Nécessite shop.js (sb, el). */
(() => {
  async function shrink(file) {                         // ≤ 1080 px, JPEG : léger à envoyer et à afficher ; retire aussi les métadonnées (GPS…)
    if (!file || !file.type.startsWith("image/")) throw new Error("Choisissez une photo (image).");
    if (file.size > 30e6) throw new Error("Cette image est trop lourde.");
    let src;
    try { src = await createImageBitmap(file, { imageOrientation: "from-image" }); }
    catch { src = await new Promise((ok, no) => { const u = URL.createObjectURL(file), i = new Image(); i.onload = () => ok(i); i.onerror = () => no(new Error("Impossible de lire cette image.")); i.src = u; }); }
    const w = src.width || src.naturalWidth, h = src.height || src.naturalHeight, k = Math.min(1, 1080 / Math.max(w, h));
    const c = document.createElement("canvas"); c.width = Math.round(w * k); c.height = Math.round(h * k);
    c.getContext("2d").drawImage(src, 0, 0, c.width, c.height);
    for (const q of [0.82, 0.7, 0.55]) { const b = await new Promise((r) => c.toBlob(r, "image/jpeg", q)); if (b && b.size <= 1.8e6) return b; }
    throw new Error("Image trop lourde même réduite.");
  }
  // ---- vidéos courtes : réduites dans le navigateur (480p, ~1 Mo pour 10 s) avant l'envoi, pour ménager les forfaits mobiles
  const MAX_VIDEO_S = 30, MAX_VIDEO_BYTES = 5.9 * 1024 * 1024, SMALL_ENOUGH = 3.5 * 1024 * 1024;
  const waitFor = (el, ok, no = "error") => new Promise((res, rej) => { el.addEventListener(ok, () => res(), { once: true }); el.addEventListener(no, () => rej(new Error("unreadable")), { once: true }); });
  function recorderType() {
    if (!window.MediaRecorder) return null;
    return ["video/mp4;codecs=avc1.42E01E,mp4a.40.2", "video/mp4", "video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm"].find((t) => MediaRecorder.isTypeSupported(t)) || null;
  }
  // Renvoie { blob, ext, duration, poster }. force = true : réencode même un petit fichier.
  async function optimizeVideo(file, onProgress, force = false) {
    const url = URL.createObjectURL(file), v = document.createElement("video");
    v.muted = true; v.playsInline = true; v.preload = "auto"; v.src = url;
    try {
      await waitFor(v, "loadedmetadata");
      if (v.duration === Infinity) {      // vidéos enregistrées par un navigateur : durée absente du fichier, on la fait calculer
        v.currentTime = 1e7; await Promise.race([waitFor(v, "timeupdate"), new Promise((r) => setTimeout(r, 4000))]);
        v.currentTime = 0; await waitFor(v, "seeked").catch(() => {});
      }
      const dur = v.duration;
      if (!isFinite(dur) || dur < 1) throw new Error("unreadable");
      if (dur > MAX_VIDEO_S + 0.5) { const e = new Error("too_long"); e.seconds = Math.round(dur); throw e; }
      // vignette : une image de la vidéo (petite, ~30 Ko)
      v.currentTime = Math.min(0.5, dur / 2); await waitFor(v, "seeked");
      const pk = Math.min(1, 480 / v.videoWidth), pc = document.createElement("canvas"); pc.width = Math.round(v.videoWidth * pk); pc.height = Math.round(v.videoHeight * pk);
      pc.getContext("2d").drawImage(v, 0, 0, pc.width, pc.height);
      const poster = await new Promise((r) => pc.toBlob(r, "image/jpeg", 0.72));
      const ext0 = /mp4/.test(file.type) ? "mp4" : /webm/.test(file.type) ? "webm" : null;
      if (!force && ext0 && file.size <= SMALL_ENOUGH) return { blob: file, ext: ext0, duration: Math.max(1, Math.round(dur)), poster, type: file.type.split(";")[0] };
      const type = recorderType(); if (!type) throw new Error("unsupported");
      const k = Math.min(1, 854 / Math.max(v.videoWidth, v.videoHeight), 480 / Math.min(v.videoWidth, v.videoHeight));
      const w = Math.max(2, Math.round(v.videoWidth * k / 2) * 2), h = Math.max(2, Math.round(v.videoHeight * k / 2) * 2);
      const cv = document.createElement("canvas"); cv.width = w; cv.height = h; const ctx = cv.getContext("2d");
      const stream = cv.captureStream(24); let ac = null;
      try { ac = new (window.AudioContext || window.webkitAudioContext)(); const src = ac.createMediaElementSource(v), dest = ac.createMediaStreamDestination(); src.connect(dest); dest.stream.getAudioTracks().forEach((t) => stream.addTrack(t)); v.muted = false; } catch (e) { ac = null; }
      const rec = new MediaRecorder(stream, { mimeType: type, videoBitsPerSecond: 900000, audioBitsPerSecond: 64000 }), chunks = [];
      rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
      const stopped = new Promise((r) => { rec.onstop = r; });
      v.currentTime = 0; await waitFor(v, "seeked").catch(() => {});
      rec.start(500); await v.play();
      let raf; const draw = () => { ctx.drawImage(v, 0, 0, w, h); onProgress && onProgress(Math.min(1, v.currentTime / dur)); raf = requestAnimationFrame(draw); }; draw();
      await Promise.race([waitFor(v, "ended"), new Promise((r) => setTimeout(r, (dur + 6) * 1000))]);
      cancelAnimationFrame(raf); rec.stop(); await stopped; if (ac) ac.close().catch(() => {});
      const blob = new Blob(chunks, { type: type.split(";")[0] });
      return { blob, ext: /mp4/.test(type) ? "mp4" : "webm", duration: Math.max(1, Math.round(dur)), poster, type: type.split(";")[0] };
    } finally { URL.revokeObjectURL(url); v.removeAttribute("src"); }
  }

  // ---- écran « Nouvelle publication »
  const SVG = {
    eyeoff: '<path d="M3 3l18 18"/><path d="M10.6 5.1A10.6 10.6 0 0 1 12 5c5 0 8.6 3.6 10 7a12.6 12.6 0 0 1-3.2 4.4M6.5 6.6A12.6 12.6 0 0 0 2 12c1.4 3.4 5 7 10 7 1.5 0 2.9-.3 4.1-.9"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
    comment: '<path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 9 9 0 0 1-3.6-.8L3 21l1.9-5.2A8.4 8.4 0 0 1 3 11.5 8.6 8.6 0 0 1 12 3a8.6 8.6 0 0 1 9 8.5z"/>',
    tag: '<path d="M3 12.2V4a1 1 0 0 1 1-1h8.2a1 1 0 0 1 .7.3l7.8 7.8a1 1 0 0 1 0 1.4l-8.2 8.2a1 1 0 0 1-1.4 0L3.3 12.9a1 1 0 0 1-.3-.7z"/><circle cx="7.6" cy="7.6" r="1.3"/>',
    chev: '<path d="M6 9l6 6 6-6"/>',
    back: '<path d="M15 5l-7 7 7 7"/>',
    image: '<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="1.6"/><path d="M21 16l-5-5-8 8"/>'
  };
  const ico = (n, s) => { const t = document.createElement("template"); t.innerHTML = `<svg class="pi" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"${s ? ` style="width:${s}px;height:${s}px"` : ""}>${SVG[n]}</svg>`; return t.content.firstChild; };
  const CATS = [["nouveaute", "Nouveauté"], ["promotion", "Promotion"], ["evenement", "Événement"], ["coulisses", "Coulisses"]];
  const PERR = { too_many_posts: "Limite atteinte : 20 publications par jour.", too_many_videos: "Vous avez déjà 20 vidéos : supprimez-en une avant d'en publier une autre.", too_many_videos_today: "Limite atteinte : 5 vidéos par jour.",
    not_verified: "Votre commerce doit d'abord être vérifié.", invalid_body: "Votre description est trop longue (2 000 caractères au maximum).", caption_too_long: "Votre description est trop longue (300 caractères au maximum).",
    file_not_found: "L'envoi du fichier a échoué. Réessayez.", image_not_found: "L'envoi de la photo a échoué. Réessayez." };
  const perr = (e) => { const m = String(e && e.message || e || ""), k = Object.keys(PERR).find((c) => m.includes(c)); return k ? PERR[k] : "Publication impossible pour le moment. Réessayez dans un instant."; };
  const mmss = (n) => `${Math.floor(n / 60)}:${String(Math.round(n % 60)).padStart(2, "0")}`;
  const CSS = `
  #pub { position: fixed; inset: 0; z-index: 60; display: flex; flex-direction: column; background: radial-gradient(120% 70% at 50% 0%, #0a1a45 0%, #050b20 60%); color: #fff; font: 16px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif; padding-top: env(safe-area-inset-top, 0px); }
  #pub * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  #pub .ph { flex: none; display: grid; grid-template-columns: 56px 1fr auto; align-items: center; gap: .4rem; padding: .7rem 1rem .6rem .6rem; }
  #pub .ph h2 { margin: 0; text-align: center; font-size: 1.12rem; font-weight: 650; letter-spacing: -.01em; color: #fff; }
  #pub .pback { width: 44px; height: 44px; border: 0; background: none; color: #fff; display: grid; place-items: center; cursor: pointer; border-radius: 50%; }
  #pub .pback .pi { width: 26px; height: 26px; }
  #pub .pgo { border: 0; border-radius: 12px; padding: .62rem 1rem; background: #0b6bff; color: #fff; font: inherit; font-weight: 650; cursor: pointer; min-width: 84px; }
  #pub .pgo:disabled { opacity: .6; cursor: default; }
  #pub .pbody { flex: 1; overflow-y: auto; padding: .3rem 1rem calc(1.6rem + env(safe-area-inset-bottom, 0px)); display: flex; flex-direction: column; gap: .9rem; max-width: 560px; width: 100%; margin: 0 auto; }
  #pub .pmedia { position: relative; border-radius: 18px; overflow: hidden; background: #0a1330; align-self: center; border: 1px solid rgba(140,170,255,.14); }
  #pub .pmedia.photo { width: 100%; }
  #pub .pmedia.photo img { display: block; width: 100%; max-height: 52vh; object-fit: cover; }
  #pub .pmedia.video { height: min(52vh, 440px); aspect-ratio: 9 / 16; max-width: 62%; }
  #pub .pmedia.video video { width: 100%; height: 100%; object-fit: cover; display: block; }
  #pub .pplay { position: absolute; left: 50%; top: 50%; width: 64px; height: 64px; margin: -32px 0 0 -32px; border: 0; border-radius: 50%; background: rgba(8,14,32,.55); color: #fff; display: grid; place-items: center; cursor: pointer; backdrop-filter: blur(4px); }
  #pub .pplay::before { content: ""; border-style: solid; border-width: 11px 0 11px 18px; border-color: transparent transparent transparent #fff; margin-left: 4px; }
  #pub .pplay.off { display: none; }
  #pub .pdur { position: absolute; right: 8px; bottom: 8px; padding: .12rem .5rem; border-radius: 8px; background: rgba(5,9,22,.72); font-size: .85rem; font-variant-numeric: tabular-nums; }
  #pub textarea { width: 100%; min-height: 84px; resize: none; padding: .95rem 1rem; border-radius: 16px; border: 1px solid rgba(140,170,255,.16); background: rgba(24,42,100,.28); color: #fff; font: inherit; }
  #pub textarea::placeholder { color: #7186b5; }
  #pub textarea:focus { outline: none; border-color: #4b95ff; box-shadow: 0 0 0 3px rgba(47,123,255,.25); }
  #pub .rows { display: flex; flex-direction: column; gap: 2px; }
  #pub .prow { position: relative; display: flex; align-items: center; gap: .85rem; min-height: 58px; padding: .5rem 1rem; border: 1px solid rgba(140,170,255,.14); background: rgba(24,42,100,.28); color: #fff; font: inherit; text-align: left; width: 100%; }
  #pub .rows .prow:first-child { border-radius: 16px 16px 6px 6px; } #pub .rows .prow:last-child { border-radius: 6px 6px 16px 16px; } #pub .rows .prow:only-child { border-radius: 16px; }
  #pub .prow .pi { width: 24px; height: 24px; flex: none; color: #e8efff; }
  #pub .prow .pt { flex: 1; min-width: 0; }
  #pub .psw { position: relative; flex: none; width: 52px; height: 30px; border-radius: 15px; background: rgba(120,140,190,.28); transition: background .15s; }
  #pub .psw::after { content: ""; position: absolute; left: 3px; top: 3px; width: 24px; height: 24px; border-radius: 50%; background: #fff; transition: transform .15s; }
  #pub .prow[aria-checked="true"] .psw { background: #0b6bff; } #pub .prow[aria-checked="true"] .psw::after { transform: translateX(22px); }
  #pub button.prow { cursor: pointer; }
  #pub .pcat { cursor: pointer; border-radius: 16px; } #pub .pcat .pv { color: #9fb2dd; } #pub .pcat .pi.c { width: 20px; height: 20px; color: #9fb2dd; }
  #pub .pcat select { position: absolute; inset: 0; width: 100%; height: 100%; opacity: 0; cursor: pointer; font-size: 16px; }
  #pub .pthumb { justify-content: center; border-radius: 16px; background: rgba(40,80,190,.32); cursor: pointer; }
  #pub .perr { margin: 0; color: #ff8a80; min-height: 0; } #pub .perr:empty { display: none; }
  @media (prefers-reduced-motion: reduce) { #pub .psw, #pub .psw::after { transition: none; } }`;

  function open(kind, file, merchantId) {
    if (document.getElementById("pub")) return;
    if (!document.getElementById("pub-css")) { const st = document.createElement("style"); st.id = "pub-css"; st.textContent = CSS; document.head.append(st); }
    const isVideo = kind === "video", urls = [], mk = (f) => { const u = URL.createObjectURL(f); urls.push(u); return u; };
    const state = { hide: false, off: false, cat: "nouveaute", thumb: null, dur: 0 };
    const err = el("p", { class: "perr", id: "pub-err", role: "alert" });
    const go = el("button", { class: "pgo", id: "pub-go", type: "button", text: "Publier" });
    const back = el("button", { class: "pback", id: "pub-back", type: "button", "aria-label": "Retour" }, ico("back"));
    const desc = el("textarea", { id: "pub-desc", maxlength: isVideo ? 300 : 2000, placeholder: "Ajouter une description…", "aria-label": "Description" });
    let media;
    if (isVideo) {
      const vid = el("video", { id: "pub-video", playsinline: true, muted: true, loop: true, preload: "metadata" }); vid.muted = true; vid.src = mk(file) + "#t=0.1";
      const play = el("button", { class: "pplay", id: "pub-play", type: "button", "aria-label": "Lire la vidéo" }), dur = el("span", { class: "pdur", id: "pub-dur" });
      const tog = () => { if (vid.paused) { vid.play().catch(() => {}); play.classList.add("off"); } else { vid.pause(); play.classList.remove("off"); } };
      play.addEventListener("click", tog); vid.addEventListener("click", tog);
      vid.addEventListener("loadedmetadata", () => { if (isFinite(vid.duration)) { state.dur = vid.duration; dur.textContent = mmss(vid.duration); } });
      media = el("div", { class: "pmedia video", id: "pub-media" }, vid, play, dur); state.vid = vid;
    } else media = el("div", { class: "pmedia photo", id: "pub-media" }, el("img", { id: "pub-img", src: mk(file), alt: "Photo à publier" }));
    const sw = (id, ic, label, key) => { const b = el("button", { class: "prow", id, type: "button", role: "switch", "aria-checked": "false" }, ico(ic), el("span", { class: "pt", text: label }), el("span", { class: "psw" }));
      b.addEventListener("click", () => { state[key] = !state[key]; b.setAttribute("aria-checked", String(state[key])); }); return b; };
    const sel = el("select", { id: "pub-cat", "aria-label": "Catégorie" }, ...CATS.map(([v, t]) => el("option", { value: v, text: t }))), pv = el("span", { class: "pv", text: CATS[0][1] });
    sel.addEventListener("change", () => { state.cat = sel.value; pv.textContent = CATS.find((c) => c[0] === sel.value)[1]; });
    const catRow = el("label", { class: "prow pcat", id: "pub-cat-row" }, ico("tag"), el("span", { class: "pt", text: "Catégorie" }), pv, ico("chev", 20), sel); catRow.querySelector(".pi:last-of-type").classList.add("c");
    const body = el("div", { class: "pbody" }, media, desc,
      el("div", { class: "rows" }, sw("pub-hide", "eyeoff", "Masquer le nombre de likes", "hide"), sw("pub-off", "comment", "Désactiver les commentaires", "off")),
      el("div", { class: "rows" }, catRow));
    if (isVideo) {
      const pick = el("input", { type: "file", accept: "image/*", hidden: true, id: "pub-thumb-file" });
      const tb = el("button", { class: "prow pthumb", id: "pub-thumb", type: "button" }, ico("image"), el("span", { text: "Choisir une miniature" }));
      tb.addEventListener("click", () => pick.click());
      pick.addEventListener("change", () => { const f = pick.files && pick.files[0]; if (!f) return; if (!f.type.startsWith("image/")) { err.textContent = "Choisissez une image pour la miniature."; return; }
        err.textContent = ""; state.thumb = f; state.vid.poster = mk(f); state.vid.removeAttribute("src"); state.vid.load(); state.vid.src = mk(file); });
      body.append(el("div", { class: "rows" }, tb), pick);
    }
    body.insertBefore(err, null);
    const root = el("div", { id: "pub", role: "dialog", "aria-modal": "true", "aria-label": "Nouvelle publication" }, el("div", { class: "ph" }, back, el("h2", { text: "Nouvelle publication" }), go), body);
    document.body.append(root); document.body.classList.add("noscroll");
    const close = () => { urls.forEach((u) => URL.revokeObjectURL(u)); root.remove(); document.body.classList.remove("noscroll"); };
    back.addEventListener("click", () => { if (!go.disabled) close(); });
    go.addEventListener("click", async () => {
      err.textContent = ""; go.disabled = true; go.textContent = "Envoi…"; const made = [];
      try {
        const opts = { p_hide_likes: state.hide, p_comments_disabled: state.off, p_category: state.cat };
        if (!isVideo) {
          const blob = await shrink(file), path = `${merchantId}/${crypto.randomUUID()}.jpg`; made.push(["merchant-media", path]);
          const up = await sb.storage.from("merchant-media").upload(path, blob, { contentType: "image/jpeg", upsert: false }); if (up.error) throw up.error;
          const r = await sb.rpc("create_post", { p_body: desc.value, p_image_path: path, ...opts }); if (r.error) throw r.error;
        } else {
          go.textContent = "Préparation…";
          const out = await optimizeVideo(file, (p) => { go.textContent = `${Math.round(p * 100)} %`; });
          if (out.blob.size > MAX_VIDEO_BYTES) throw new Error("too_big");
          go.textContent = "Envoi…";
          const poster = state.thumb ? await thumbJpeg(state.thumb) : out.poster;
          const id = crypto.randomUUID(), base = `${merchantId}/${id}`, vp = `${base}.${out.ext}`, pp = `${base}.jpg`;
          made.push(["merchant-videos", vp], ["merchant-media", pp]);
          let up = await sb.storage.from("merchant-videos").upload(vp, out.blob, { contentType: out.type, upsert: false }); if (up.error) throw up.error;
          up = await sb.storage.from("merchant-media").upload(pp, poster, { contentType: "image/jpeg", upsert: false }); if (up.error) throw up.error;
          const r = await sb.rpc("create_video", { p_caption: desc.value, p_video_path: vp, p_poster_path: pp, p_duration: out.duration, ...opts }); if (r.error) throw r.error;
        }
        close(); if (OPT.onDone) OPT.onDone(); else location.reload();
      } catch (e) {
        for (const [b, p] of made) { try { await sb.storage.from(b).remove([p]); } catch (x) {} }
        const m = String(e && e.message || e);
        err.textContent = m === "too_long" ? `Cette vidéo dure ${e.seconds} s : 30 secondes au maximum. Raccourcissez-la puis réessayez.`
          : m === "too_big" ? "Cette vidéo reste trop lourde (6 Mo maximum) même après réduction : raccourcissez-la."
          : m === "unsupported" ? "Ce navigateur ne sait pas réduire les vidéos. Essayez avec Chrome, ou une vidéo déjà légère (moins de 3 Mo)."
          : m === "unreadable" ? "Impossible de lire cette vidéo. Essayez un autre fichier (MP4 de préférence)."
          : e instanceof Error && !m.includes("_") && !/^[a-z]+$/.test(m) ? m : perr(e);
        go.disabled = false; go.textContent = "Publier";
      }
    });
  }

  // Miniature choisie : image réduite à 480 px de large (≈ 30 Ko)
  async function thumbJpeg(f) {
    if (f.size > 30e6) throw new Error("Cette image est trop lourde.");
    const src = await createImageBitmap(f, { imageOrientation: "from-image" }), k = Math.min(1, 480 / src.width), c = document.createElement("canvas");
    c.width = Math.round(src.width * k); c.height = Math.round(src.height * k); c.getContext("2d").drawImage(src, 0, 0, c.width, c.height);
    const b = await new Promise((r) => c.toBlob(r, "image/jpeg", 0.75)); if (!b) throw new Error("Image illisible."); return b;
  }

  // Point d'entrée : ouvre le sélecteur de fichier (geste de l'utilisateur), vérifie la durée d'une vidéo, puis ouvre l'écran.
  const OPT = {};
  const warn = (m) => { const t = el("p", { id: "pub-warn", role: "alert", style: "position:fixed;left:50%;transform:translateX(-50%);bottom:calc(7rem + env(safe-area-inset-bottom,0px));z-index:70;max-width:min(92vw,420px);margin:0;padding:.7rem 1rem;border-radius:14px;background:#0b1535;border:1px solid rgba(140,170,255,.25);color:#fff;font:15px/1.4 system-ui,sans-serif;text-align:center", text: m }); document.body.append(t); setTimeout(() => t.remove(), 4500); };
  window.nxPublish = function (kind, merchantId, onDone) {
    OPT.onDone = onDone || null;
    const inp = document.createElement("input"); inp.type = "file"; inp.accept = kind === "video" ? "video/*" : "image/*"; inp.hidden = true; document.body.append(inp);
    inp.addEventListener("change", async () => {
      const f = inp.files && inp.files[0]; inp.remove(); if (!f) return;
      if (kind === "video") {
        const v = document.createElement("video"), u = URL.createObjectURL(f); v.preload = "metadata"; v.muted = true; v.src = u;
        const d = await new Promise((r) => { v.onloadedmetadata = () => r(v.duration); v.onerror = () => r(NaN); setTimeout(() => r(NaN), 6000); });
        URL.revokeObjectURL(u);
        if (isFinite(d) && d > MAX_VIDEO_S + 0.5) { warn(`Cette vidéo dure ${Math.round(d)} s : 30 secondes au maximum. Raccourcissez-la puis réessayez.`); return; }
      } else if (!f.type.startsWith("image/")) { warn("Choisissez une photo (image)."); return; }
      open(kind, f, merchantId);
    });
    inp.addEventListener("cancel", () => inp.remove());
    inp.click();
  };
})();
