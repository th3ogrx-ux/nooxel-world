/* Écran « Nouvelle publication » (photos en carrousel pour le fil, vidéo pour l'onglet Vidéos).
   Utilisation : nxPublish("photo" | "video", merchantId) : ouvre l'écran de choix, puis l'écran de publication. Nécessite shop.js (sb, el). */
(() => {
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
    image: '<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="1.6"/><path d="M21 16l-5-5-8 8"/>',
    video: '<rect x="3" y="6" width="13" height="12" rx="3"/><path d="M16 10.5l5-3v9l-5-3z"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    x: '<path d="M6 6l12 12M18 6L6 18"/>'
  };
  const ico = (n, s) => { const t = document.createElement("template"); t.innerHTML = `<svg class="pi" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"${s ? ` style="width:${s}px;height:${s}px"` : ""}>${SVG[n]}</svg>`; return t.content.firstChild; };
  const CATS = [["nouveaute", "Nouveauté"], ["promotion", "Promotion"], ["evenement", "Événement"], ["coulisses", "Coulisses"]];
  const MAX_PHOTOS = 10, RATIO = 0.8;      // 4 : 5 (portrait), comme les carrousels habituels
  const PERR = { too_many_posts: "Limite atteinte : 20 publications par jour.", too_many_videos: "Vous avez déjà 20 vidéos : supprimez-en une avant d'en publier une autre.", too_many_videos_today: "Limite atteinte : 5 vidéos par jour.",
    not_verified: "Votre commerce doit d'abord être vérifié.", invalid_body: "Votre description est trop longue (2 000 caractères au maximum).", caption_too_long: "Votre description est trop longue (300 caractères au maximum).",
    file_not_found: "L'envoi du fichier a échoué. Réessayez.", image_not_found: "L'envoi d'une photo a échoué. Réessayez.", too_many_images: "10 photos au maximum par publication.", invalid_image: "Une des photos n'est pas valide. Réessayez." };
  const perr = (e) => { const m = String(e && e.message || e || ""), k = Object.keys(PERR).find((c) => m.includes(c)); return k ? PERR[k] : "Publication impossible pour le moment. Réessayez dans un instant."; };
  const mmss = (n) => `${Math.floor(n / 60)}:${String(Math.round(n % 60)).padStart(2, "0")}`;
  const CSS = `
  #pub { position: fixed; inset: 0; z-index: 60; display: flex; flex-direction: column; background: radial-gradient(120% 70% at 50% 0%, #0a1a45 0%, #050b20 60%); color: #fff; font: 16px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif; padding-top: env(safe-area-inset-top, 0px); }
  #pub * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  #pub .ph { flex: none; display: grid; grid-template-columns: 56px 1fr 96px; align-items: center; gap: .4rem; padding: .7rem 1rem .6rem .6rem; }
  #pub .ph h2 { margin: 0; text-align: center; font-size: 1.12rem; font-weight: 650; letter-spacing: -.01em; color: #fff; }
  #pub .pback { width: 44px; height: 44px; border: 0; background: none; color: #fff; display: grid; place-items: center; cursor: pointer; border-radius: 50%; }
  #pub .pback .pi { width: 26px; height: 26px; }
  #pub .pgo { border: 0; border-radius: 12px; padding: .62rem 1rem; background: #0b6bff; color: #fff; font: inherit; font-weight: 650; cursor: pointer; min-width: 84px; justify-self: end; }
  #pub .pgo:disabled { opacity: .6; cursor: default; }
  #pub .pbody { flex: 1; overflow-y: auto; padding: .3rem 1rem calc(1.6rem + env(safe-area-inset-bottom, 0px)); display: flex; flex-direction: column; gap: .9rem; max-width: 560px; width: 100%; margin: 0 auto; }
  #pub .pstart { flex: 1; justify-content: center; align-items: center; text-align: center; gap: 1.1rem; }
  #pub .pdrop { width: 100%; border: 1.5px dashed rgba(140,170,255,.38); border-radius: 26px; padding: 2.2rem 1.4rem; background: rgba(24,42,100,.22); display: flex; flex-direction: column; align-items: center; gap: .9rem; transition: background .15s, border-color .15s; }
  #pub .pdrop.over { background: rgba(47,123,255,.2); border-color: #4b95ff; }
  #pub .pbadge { width: 84px; height: 84px; border-radius: 50%; display: grid; place-items: center; background: linear-gradient(160deg, rgba(59,139,255,.5), rgba(20,50,140,.55)); box-shadow: 0 10px 34px rgba(11,107,255,.35), inset 0 1px 0 rgba(255,255,255,.22); }
  #pub .pbadge .pi { width: 40px; height: 40px; }
  #pub .pdrop h3 { margin: .1rem 0 0; font-size: 1.3rem; letter-spacing: -.01em; }
  #pub .pdrop p { margin: 0; color: #a9bce6; max-width: 30ch; }
  #pub .pchoose { width: 100%; max-width: 320px; display: inline-flex; align-items: center; justify-content: center; gap: .6rem; border: 0; border-radius: 16px; padding: .95rem 1.2rem; background: linear-gradient(180deg, #3b8bff, #1f63e6); box-shadow: 0 8px 22px rgba(47,123,255,.4); color: #fff; font: inherit; font-weight: 650; font-size: 1.05rem; cursor: pointer; }
  #pub .pchoose .pi { width: 22px; height: 22px; }
  #pub .pcrop { position: relative; width: min(100%, calc(56vh * 0.8)); aspect-ratio: 4 / 5; align-self: center; overflow: hidden; border-radius: 18px; background: #0a1330; border: 1px solid rgba(140,170,255,.14); touch-action: none; cursor: grab; user-select: none; -webkit-user-select: none; }
  #pub .pcrop:active { cursor: grabbing; }
  #pub .pcrop img { position: absolute; left: 0; top: 0; max-width: none; transform-origin: 0 0; pointer-events: none; -webkit-user-drag: none; will-change: transform; }
  #pub .pcount { position: absolute; top: 9px; right: 9px; padding: .12rem .55rem; border-radius: 999px; background: rgba(5,9,22,.62); font-size: .82rem; font-weight: 600; font-variant-numeric: tabular-nums; pointer-events: none; }
  #pub .phint { margin: -.3rem 0 0; text-align: center; color: #7f94c4; font-size: .85rem; }
  #pub .pstrip { display: flex; gap: .55rem; overflow-x: auto; padding: .35rem .15rem; align-self: stretch; scrollbar-width: none; }
  #pub .pstrip::-webkit-scrollbar { display: none; }
  #pub .pth { position: relative; flex: none; width: 58px; height: 72px; border-radius: 12px; border: 2px solid transparent; padding: 0; background: #0a1330; cursor: pointer; }
  #pub .pth.on { border-color: #4b95ff; }
  #pub .pth img { width: 100%; height: 100%; object-fit: cover; border-radius: 10px; display: block; }
  #pub .pth .pdel { position: absolute; top: -7px; right: -7px; width: 22px; height: 22px; border-radius: 50%; border: 0; background: #0b1535; border: 1px solid rgba(160,190,255,.5); color: #fff; display: grid; place-items: center; padding: 0; cursor: pointer; }
  #pub .pth .pdel .pi { width: 12px; height: 12px; }
  #pub .padd { flex: none; width: 58px; height: 72px; border-radius: 12px; border: 1.5px dashed rgba(140,170,255,.45); background: rgba(24,42,100,.25); color: #cfe0ff; display: grid; place-items: center; cursor: pointer; padding: 0; }
  #pub .padd .pi { width: 24px; height: 24px; }
  #pub .pmedia { position: relative; align-self: center; border-radius: 18px; }
  #pub .pmedia.video { height: min(52vh, 440px); aspect-ratio: 9 / 16; max-width: 62%; background: #0a1330; }
  #pub .pmedia.video video { display: block; width: 100%; height: 100%; object-fit: cover; border-radius: 18px; background: #0a1330; }
  #pub .pplay { position: absolute; left: 50%; top: 50%; width: 64px; height: 64px; margin: -32px 0 0 -32px; border: 0; border-radius: 50%; background: rgba(8,14,32,.6); color: #fff; display: grid; place-items: center; cursor: pointer; }
  #pub .pplay::before { content: ""; border-style: solid; border-width: 11px 0 11px 18px; border-color: transparent transparent transparent #fff; margin-left: 4px; }
  #pub .pplay.off { display: none; }
  #pub .pdur { position: absolute; right: 8px; bottom: 8px; padding: .12rem .5rem; border-radius: 8px; background: rgba(5,9,22,.72); font-size: .85rem; font-variant-numeric: tabular-nums; pointer-events: none; }
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
  #pub .perr { margin: 0; color: #ff8a80; } #pub .perr:empty { display: none; }
  @media (prefers-reduced-motion: reduce) { #pub .psw, #pub .psw::after, #pub .pdrop { transition: none; } }`;

  const OPT = {};
  const warn = (m) => { const t = el("p", { id: "pub-warn", role: "alert", style: "position:fixed;left:50%;transform:translateX(-50%);bottom:calc(7rem + env(safe-area-inset-bottom,0px));z-index:70;max-width:min(92vw,420px);margin:0;padding:.7rem 1rem;border-radius:14px;background:#0b1535;border:1px solid rgba(140,170,255,.25);color:#fff;font:15px/1.4 system-ui,sans-serif;text-align:center", text: m }); document.body.append(t); setTimeout(() => t.remove(), 4500); };
  const loadImg = (url) => new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => no(new Error("Impossible de lire cette image.")); i.src = url; });
  const videoLength = (f) => new Promise((r) => { const v = document.createElement("video"), u = URL.createObjectURL(f); v.preload = "metadata"; v.muted = true; v.src = u;
    const done = (d) => { URL.revokeObjectURL(u); r(d); }; v.onloadedmetadata = () => done(v.duration); v.onerror = () => done(NaN); setTimeout(() => done(NaN), 6000); });

  // Zone de recadrage d'une photo : zone 4:5, glisser pour déplacer, pincer / molette / double-clic pour zoomer. Les calculs se font en pixels de la photo.
  const cropBox = (p) => { const wide = p.nw / p.nh > RATIO, ch = (wide ? p.nh : p.nw / RATIO) / p.z, cw = ch * RATIO; return { cw, ch }; };
  const clampC = (p) => { const { cw, ch } = cropBox(p); p.cx = Math.min(Math.max(p.cx, cw / 2 / p.nw), 1 - cw / 2 / p.nw); p.cy = Math.min(Math.max(p.cy, ch / 2 / p.nh), 1 - ch / 2 / p.nh); };
  async function renderCrop(p) {
    clampC(p); const { cw, ch } = cropBox(p), W = 1080, H = 1350, c = document.createElement("canvas"); c.width = W; c.height = H;
    c.getContext("2d").drawImage(p.img, p.cx * p.nw - cw / 2, p.cy * p.nh - ch / 2, cw, ch, 0, 0, W, H);
    for (const q of [0.85, 0.75, 0.6, 0.5]) { const b = await new Promise((r) => c.toBlob(r, "image/jpeg", q)); if (b && b.size <= 1.8e6) return b; }
    throw new Error("Image trop lourde même réduite.");
  }
  async function thumbJpeg(f) {      // miniature de vidéo choisie : 480 px de large (≈ 30 Ko)
    if (f.size > 30e6) throw new Error("Cette image est trop lourde.");
    const src = await createImageBitmap(f, { imageOrientation: "from-image" }), k = Math.min(1, 480 / src.width), c = document.createElement("canvas");
    c.width = Math.round(src.width * k); c.height = Math.round(src.height * k); c.getContext("2d").drawImage(src, 0, 0, c.width, c.height);
    const b = await new Promise((r) => c.toBlob(r, "image/jpeg", 0.75)); if (!b) throw new Error("Image illisible."); return b;
  }

  function openPublish(kind, merchantId) {
    if (document.getElementById("pub")) return;
    if (!document.getElementById("pub-css")) { const st = document.createElement("style"); st.id = "pub-css"; st.textContent = CSS; document.head.append(st); }
    const isVideo = kind === "video", urls = [], mk = (f) => { const u = URL.createObjectURL(f); urls.push(u); return u; };
    const st = { hide: false, off: false, cat: "nouveaute", thumb: null, file: null, photos: [], cur: 0 };
    const root = el("div", { id: "pub", role: "dialog", "aria-modal": "true", "aria-label": "Nouvelle publication" });
    document.body.append(root); document.body.classList.add("noscroll");
    const close = () => { urls.forEach((u) => URL.revokeObjectURL(u)); root.remove(); document.body.classList.remove("noscroll"); };
    const back = el("button", { class: "pback", id: "pub-back", type: "button", "aria-label": "Retour" }, ico("back"));
    const go = el("button", { class: "pgo", id: "pub-go", type: "button", text: "Publier" });
    const bar = (right) => el("div", { class: "ph" }, back, el("h2", { text: "Nouvelle publication" }), right || el("span"));
    back.addEventListener("click", () => { if (!go.disabled) close(); });
    const input = el("input", { type: "file", id: "pub-file", hidden: true, accept: isVideo ? "video/*" : "image/*" }); if (!isVideo) input.multiple = true;
    root.append(input);

    // ---- écran 1 : choisir
    function showStart() {
      const choose = el("button", { class: "pchoose", id: "pub-choose", type: "button" }, ico("image"), el("span", { text: "Choisir dans ma galerie" }));
      choose.firstChild.replaceWith(ico(isVideo ? "video" : "image"));
      choose.addEventListener("click", () => input.click());
      const zone = el("div", { class: "pdrop", id: "pub-drop" }, el("span", { class: "pbadge" }, ico(isVideo ? "video" : "image")),
        el("h3", { text: isVideo ? "Ajoutez votre vidéo" : "Ajoutez vos photos" }),
        el("p", { text: isVideo ? "30 secondes au maximum, au format vertical de préférence." : `Jusqu'à ${MAX_PHOTOS} photos : elles défilent comme un carrousel.` }), choose);
      ["dragenter", "dragover"].forEach((ev) => zone.addEventListener(ev, (e) => { e.preventDefault(); zone.classList.add("over"); }));
      ["dragleave", "drop"].forEach((ev) => zone.addEventListener(ev, (e) => { e.preventDefault(); zone.classList.remove("over"); }));
      zone.addEventListener("drop", (e) => { if (e.dataTransfer && e.dataTransfer.files.length) picked([...e.dataTransfer.files]); });
      root.replaceChildren(bar(), el("div", { class: "pbody pstart" }, zone), input);
    }
    input.addEventListener("change", () => { const fs = [...(input.files || [])]; input.value = ""; if (fs.length) picked(fs); });
    async function picked(files) {
      if (isVideo) {
        const f = files.find((x) => x.type.startsWith("video/")) || files[0];
        if (!f || !(f.type.startsWith("video/") || /\.(mp4|mov|webm|m4v)$/i.test(f.name))) { warn("Choisissez une vidéo."); return; }
        const d = await videoLength(f);
        if (isFinite(d) && d > MAX_VIDEO_S + 0.5) { warn(`Cette vidéo dure ${Math.round(d)} s : 30 secondes au maximum. Raccourcissez-la puis réessayez.`); return; }
        st.file = f; showVideo(); return;
      }
      const imgs = files.filter((x) => x.type.startsWith("image/")); if (!imgs.length) { warn("Choisissez des photos (images)."); return; }
      const room = MAX_PHOTOS - st.photos.length; if (imgs.length > room) warn(`${MAX_PHOTOS} photos au maximum : seules les ${room} premières sont ajoutées.`);
      for (const f of imgs.slice(0, room)) { try { const url = mk(f), img = await loadImg(url); st.photos.push({ file: f, url, img, nw: img.naturalWidth, nh: img.naturalHeight, z: 1, cx: .5, cy: .5 }); } catch (e) { warn("Une photo n'a pas pu être lue."); } }
      if (!st.photos.length) return;
      if (!root.querySelector("#pub-crop")) showPhotos(); else { st.cur = st.photos.length - 1; paintPhotos(); }
    }

    // ---- éléments communs de l'écran 2
    const err = el("p", { class: "perr", id: "pub-err", role: "alert" });
    const desc = el("textarea", { id: "pub-desc", maxlength: isVideo ? 300 : 2000, placeholder: "Ajouter une description…", "aria-label": "Description" });
    const sw = (id, ic, label, key) => { const b = el("button", { class: "prow", id, type: "button", role: "switch", "aria-checked": String(st[key]) }, ico(ic), el("span", { class: "pt", text: label }), el("span", { class: "psw" }));
      b.addEventListener("click", () => { st[key] = !st[key]; b.setAttribute("aria-checked", String(st[key])); }); return b; };
    const options = () => {
      const sel = el("select", { id: "pub-cat", "aria-label": "Catégorie" }, ...CATS.map(([v, t]) => el("option", { value: v, text: t }))); sel.value = st.cat;
      const pv = el("span", { class: "pv", text: CATS.find((c) => c[0] === st.cat)[1] });
      sel.addEventListener("change", () => { st.cat = sel.value; pv.textContent = CATS.find((c) => c[0] === sel.value)[1]; });
      const chev = ico("chev", 20); chev.classList.add("c");
      return [desc, el("div", { class: "rows" }, sw("pub-hide", "eyeoff", "Masquer le nombre de likes", "hide"), sw("pub-off", "comment", "Désactiver les commentaires", "off")),
        el("div", { class: "rows" }, el("label", { class: "prow pcat", id: "pub-cat-row" }, ico("tag"), el("span", { class: "pt", text: "Catégorie" }), pv, chev, sel))];
    };

    // ---- écran 2 (photos) : recadrage + carrousel
    let frame, count, strip, imgEl;
    function showPhotos() {
      imgEl = el("img", { id: "pub-img", alt: "Photo à publier", draggable: false });
      count = el("span", { class: "pcount", id: "pub-count" });
      frame = el("div", { class: "pcrop", id: "pub-crop" }, imgEl, count);
      strip = el("div", { class: "pstrip", id: "pub-strip" });
      root.replaceChildren(bar(go), el("div", { class: "pbody" }, frame, el("p", { class: "phint", text: "Faites glisser pour déplacer, pincez pour zoomer." }), strip, ...options(), err), input);
      bindCrop(); paintPhotos();
    }
    const layout = (p) => { const fw = frame.clientWidth, fh = frame.clientHeight; if (!fw || !fh) return; clampC(p); const { cw } = cropBox(p), s = fw / cw;
      imgEl.style.width = p.nw * s + "px"; imgEl.style.height = p.nh * s + "px"; imgEl.style.transform = `translate(${fw / 2 - p.cx * p.nw * s}px, ${fh / 2 - p.cy * p.nh * s}px)`; };
    function paintPhotos() {
      st.cur = Math.min(st.cur, st.photos.length - 1); const p = st.photos[st.cur];
      imgEl.src = p.url; layout(p); requestAnimationFrame(() => layout(p));
      count.textContent = `${st.cur + 1}/${st.photos.length}`; count.hidden = st.photos.length < 2;
      strip.replaceChildren(...st.photos.map((q, i) => { const b = el("div", { class: "pth" + (i === st.cur ? " on" : ""), "data-i": String(i), role: "button", tabindex: "0", "aria-label": `Photo ${i + 1}` }, el("img", { src: q.url, alt: "" }));
          b.addEventListener("click", () => { st.cur = i; paintPhotos(); });
          if (st.photos.length > 1) { const d = el("button", { class: "pdel", type: "button", "aria-label": `Retirer la photo ${i + 1}` }, ico("x")); d.addEventListener("click", (e) => { e.stopPropagation(); st.photos.splice(i, 1); if (st.cur >= i && st.cur > 0) st.cur--; paintPhotos(); }); b.append(d); }
          return b; }),
        ...(st.photos.length < MAX_PHOTOS ? [(() => { const a = el("button", { class: "padd", id: "pub-more", type: "button", "aria-label": "Ajouter des photos" }, ico("plus")); a.addEventListener("click", () => input.click()); return a; })()] : []));
    }
    function bindCrop() {
      const ptrs = new Map(); let start = null;
      const cur = () => st.photos[st.cur];
      const zoomTo = (p, z) => { p.z = Math.min(5, Math.max(1, z)); layout(p); };
      frame.addEventListener("pointerdown", (e) => { frame.setPointerCapture(e.pointerId); ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY }); const p = cur();
        start = ptrs.size === 2 ? { d: dist(), z: p.z } : null; });
      const dist = () => { const [a, b] = [...ptrs.values()]; return Math.hypot(a.x - b.x, a.y - b.y); };
      frame.addEventListener("pointermove", (e) => {
        if (!ptrs.has(e.pointerId)) return; const prev = ptrs.get(e.pointerId), p = cur(); ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
        if (ptrs.size === 2 && start) { zoomTo(p, start.z * dist() / Math.max(1, start.d)); return; }
        if (ptrs.size === 1) { const { cw } = cropBox(p), k = cw / frame.clientWidth; p.cx -= (e.clientX - prev.x) * k / p.nw; p.cy -= (e.clientY - prev.y) * k / p.nh; layout(p); }
      });
      const up = (e) => { ptrs.delete(e.pointerId); start = null; }; frame.addEventListener("pointerup", up); frame.addEventListener("pointercancel", up);
      frame.addEventListener("wheel", (e) => { e.preventDefault(); const p = cur(); zoomTo(p, p.z * Math.exp(-e.deltaY * 0.0022)); }, { passive: false });
      frame.addEventListener("dblclick", () => { const p = cur(); if (p.z > 1.01) { p.z = 1; p.cx = .5; p.cy = .5; } else p.z = 2; layout(p); });
    }

    // ---- écran 2 (vidéo)
    function showVideo() {
      const vid = el("video", { id: "pub-video", playsinline: "", "webkit-playsinline": "", loop: "", muted: "", preload: "auto", disablepictureinpicture: "" }); vid.muted = true; vid.playsInline = true; vid.src = mk(st.file) + "#t=0.1";
      const play = el("button", { class: "pplay", id: "pub-play", type: "button", "aria-label": "Lire la vidéo" }), dur = el("span", { class: "pdur", id: "pub-dur" });
      const tog = () => { if (vid.paused) { vid.play().then(() => play.classList.add("off")).catch(() => { err.textContent = "Cette vidéo ne peut pas être lue dans l'aperçu. Essayez un autre fichier (MP4 de préférence)."; }); } else { vid.pause(); play.classList.remove("off"); } };
      play.addEventListener("click", tog); vid.addEventListener("click", tog);
      vid.addEventListener("loadedmetadata", () => { if (isFinite(vid.duration)) dur.textContent = mmss(vid.duration); });
      vid.addEventListener("error", () => { err.textContent = "Impossible de lire cette vidéo. Essayez un autre fichier (MP4 de préférence)."; });
      st.vid = vid;
      const media = el("div", { class: "pmedia video", id: "pub-media" }, vid, play, dur);
      const pick = el("input", { type: "file", accept: "image/*", hidden: true, id: "pub-thumb-file" });
      const tb = el("button", { class: "prow pthumb", id: "pub-thumb", type: "button" }, ico("image"), el("span", { text: "Choisir une miniature" }));
      tb.addEventListener("click", () => pick.click());
      pick.addEventListener("change", () => { const f = pick.files && pick.files[0]; if (!f) return; if (!f.type.startsWith("image/")) { err.textContent = "Choisissez une image pour la miniature."; return; }
        err.textContent = ""; st.thumb = f; vid.pause(); play.classList.remove("off"); vid.poster = mk(f); });
      root.replaceChildren(bar(go), el("div", { class: "pbody" }, media, ...options(), el("div", { class: "rows" }, tb), pick, err), input);
    }

    // ---- publier
    go.addEventListener("click", async () => {
      err.textContent = ""; go.disabled = true; go.textContent = "Envoi…"; const made = [];
      try {
        const opts = { p_hide_likes: st.hide, p_comments_disabled: st.off, p_category: st.cat };
        if (!isVideo) {
          const paths = [], n = st.photos.length;
          for (let i = 0; i < n; i++) {
            go.textContent = n > 1 ? `Envoi ${i + 1}/${n}` : "Envoi…";
            const blob = await renderCrop(st.photos[i]), path = `${merchantId}/${crypto.randomUUID()}.jpg`; made.push(["merchant-media", path]);
            const up = await sb.storage.from("merchant-media").upload(path, blob, { contentType: "image/jpeg", upsert: false }); if (up.error) throw up.error; paths.push(path);
          }
          const r = await sb.rpc("create_post", { p_body: desc.value, p_image_path: paths[0], p_extra_paths: paths.slice(1), ...opts }); if (r.error) throw r.error;
        } else {
          go.textContent = "Préparation…";
          const out = await optimizeVideo(st.file, (p) => { go.textContent = `${Math.round(p * 100)} %`; });
          if (out.blob.size > MAX_VIDEO_BYTES) throw new Error("too_big");
          go.textContent = "Envoi…";
          const poster = st.thumb ? await thumbJpeg(st.thumb) : out.poster;
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
    showStart();
  }

  // Point d'entrée : ouvre l'écran de choix (photos ou vidéo), puis « Nouvelle publication ».
  window.nxPublish = function (kind, merchantId, onDone) { OPT.onDone = onDone || null; openPublish(kind === "video" ? "video" : "photo", merchantId); };
})();
