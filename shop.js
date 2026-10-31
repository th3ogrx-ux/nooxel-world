// Outils partagés par commerce.html et fil.html (pages publiques des commerçants).
// Clé publique (anon) : conçue pour être exposée côté navigateur ; chaque droit est vérifié côté serveur.
const sb = window.supabase ? supabase.createClient(
  "https://smjbgjolteovcwkoxcar.supabase.co",
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNtamJnam9sdGVvdmN3a294Y2FyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMxMzM5MzAsImV4cCI6MjEwODcwOTkzMH0.4n1rikyRKt-rVm5FjR4RtTkV8-ip3EbcsNNPy6xCtts"
) : null;
const $ = (id) => document.getElementById(id);
// Construit des éléments sans jamais interpréter du HTML : tout texte passe par textContent.
function el(tag, props, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === "class") e.className = v; else if (k === "text") e.textContent = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v); else e.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) if (kid != null) e.append(kid.nodeType ? kid : document.createTextNode(kid));
  return e;
}
function ago(d) {
  const s = Math.max(0, (Date.now() - new Date(d).getTime()) / 1000);
  if (s < 60) return "à l'instant";
  if (s < 3600) return `il y a ${Math.floor(s / 60)} min`;
  if (s < 86400) return `il y a ${Math.floor(s / 3600)} h`;
  if (s < 7 * 86400) return `il y a ${Math.floor(s / 86400)} j`;
  return new Date(d).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" });
}
// Les vidéos sont lues depuis ce seul endroit : pour passer plus tard à un stockage sans frais de trafic (Cloudflare R2),
// il suffira d'indiquer ici son adresse publique (ex. "https://videos.mon-domaine.com") ; la base ne stocke que des chemins.
const VIDEO_BASE = null;
const videoUrl = (path) => VIDEO_BASE ? VIDEO_BASE.replace(/\/$/, "") + "/" + path : sb.storage.from("merchant-videos").getPublicUrl(path).data.publicUrl;
const imgUrl = (path) => sb.storage.from("merchant-media").getPublicUrl(path).data.publicUrl;
// ---------- Page d'un commerce : catégories, horaires, distance
const CATEGORIES = [["restaurant", "Restaurant"], ["cafe", "Café"], ["bar", "Bar"], ["boulangerie", "Boulangerie"], ["patisserie", "Pâtisserie"], ["boucherie", "Boucherie"],
  ["epicerie", "Épicerie"], ["vetements", "Vêtements"], ["beaute", "Beauté et coiffure"], ["sante", "Santé"], ["artisan", "Artisan"], ["services", "Services"],
  ["loisirs", "Loisirs"], ["hebergement", "Hébergement"], ["autre", "Autre"]];
const catLabel = (v) => { const c = CATEGORIES.find((x) => x[0] === v); return c ? c[1] : ""; };
const DAYS = [["mon", "Lundi"], ["tue", "Mardi"], ["wed", "Mercredi"], ["thu", "Jeudi"], ["fri", "Vendredi"], ["sat", "Samedi"], ["sun", "Dimanche"]];
const TIMEZONES = [["Europe/Paris", "France métropolitaine"], ["America/Martinique", "Martinique, Guadeloupe"], ["America/Cayenne", "Guyane"], ["Indian/Reunion", "La Réunion"],
  ["Indian/Mayotte", "Mayotte"], ["Pacific/Noumea", "Nouvelle-Calédonie"], ["Pacific/Tahiti", "Polynésie française"], ["Pacific/Wallis_and_Futuna", "Wallis-et-Futuna"], ["America/Miquelon", "Saint-Pierre-et-Miquelon"]];
// Jour et heure « maintenant » dans le fuseau du commerce (et non celui du visiteur).
function nowIn(tz, at = new Date()) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(at).map((x) => [x.type, x.value]));
  return { day: DAYS[["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(p.weekday)][0], time: `${p.hour}:${p.minute}` };
}
// → null si le commerçant n'a rien indiqué ; sinon { open, text } (« Ouvert · ferme à 19:00 », « Fermé · ouvre à 14:00 », « Fermé aujourd'hui »).
function openStatus(hours, tz, at = new Date()) {
  if (!hours || !Object.keys(hours).length) return null;
  const { day, time } = nowIn(tz || "Europe/Paris", at), slots = hours[day] || [];
  const cur = slots.find((s) => s[0] <= time && time < s[1]);
  if (cur) return { open: true, text: `Ouvert · ferme à ${cur[1]}` };
  const next = slots.find((s) => s[0] > time);
  return { open: false, text: next ? `Fermé · ouvre à ${next[0]}` : "Fermé aujourd'hui" };
}
function distKm(a, b) {
  const r = (x) => x * Math.PI / 180, dLat = r(b.lat - a.lat), dLng = r(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(r(a.lat)) * Math.cos(r(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 12742 * Math.asin(Math.sqrt(h));
}
const fmtKm = (k) => k < 1 ? `${Math.max(1, Math.round(k * 10)) * 100} m` : (k < 10 ? k.toFixed(1).replace(".", ",") : String(Math.round(k))) + " km";
// Position du visiteur SEULEMENT si l'autorisation a déjà été donnée : on ne la redemande jamais ici.
async function geoIfGranted() {
  try {
    if (!navigator.geolocation || !navigator.permissions) return null;
    const st = await navigator.permissions.query({ name: "geolocation" }); if (st.state !== "granted") return null;
    return await new Promise((ok) => navigator.geolocation.getCurrentPosition((p) => ok({ lat: p.coords.latitude, lng: p.coords.longitude }), () => ok(null), { maximumAge: 300000, timeout: 6000 }));
  } catch (e) { return null; }
}
// Photo de profil par défaut : petit bonhomme gris (contenu fixe, aucune donnée venant d'un utilisateur).
function silhouette(size) {
  const w = document.createElement("span"); w.className = "silhouette"; w.style.width = w.style.height = size + "px";
  w.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="9" r="4"/><path d="M4 21a8 8 0 0 1 16 0z"/></svg>';
  return w;
}
// Logo rond d'un commerce, ou son initiale s'il n'en a pas.
function logoBadge(path, name, size) {
  const box = el("span", { class: "logo", style: `width:${size}px;height:${size}px;font-size:${Math.round(size * .42)}px` });
  if (path) box.append(el("img", { src: imgUrl(path), alt: "", loading: "lazy", decoding: "async" })); else box.textContent = (name || "?").trim().charAt(0).toUpperCase();
  return box;
}
// Icônes en traits fins (contenu fixe du code, aucune donnée d'utilisateur).
const ICONS = {
  back: '<path d="M15 5l-7 7 7 7"/>', more: '<circle cx="5" cy="12" r="1.6" fill="currentColor"/><circle cx="12" cy="12" r="1.6" fill="currentColor"/><circle cx="19" cy="12" r="1.6" fill="currentColor"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
  route: '<path d="M3 11l19-9-9 19-2-8-8-2z"/>', phone: '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.127.96.361 1.903.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.907.339 1.85.573 2.81.7A2 2 0 0 1 22 16.92z"/>',
  pin: '<path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/><circle cx="12" cy="10" r="3"/>', clock: '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
  globe: '<circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  news: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h4"/>', heart: '<path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"/>',
  star: '<path d="M12 3l2.7 5.9 6.3.7-4.7 4.3 1.3 6.3L12 17l-5.6 3.2 1.3-6.3L3 9.6l6.3-.7z"/>', briefcase: '<rect x="3" y="7" width="18" height="13" rx="2"/><path d="M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2M3 13h18"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>', bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4"/>', lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3M12 15v2"/>',
  alert: '<path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18v.01"/>', help: '<circle cx="12" cy="12" r="10"/><path d="M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 .9-1 1.7M12 17v.01"/>',
  download: '<path d="M12 4v11M7 11l5 5 5-5M5 20h14"/>',
  doc: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h6"/>', shield: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M12 9v4M12 16v.01"/>',
  logout: '<path d="M9 4H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h4"/><path d="M16 8l4 4-4 4M20 12H9"/>', trash: '<path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v6M14 11v6"/>', chev: '<path d="M9 5l7 7-7 7"/>',
  pencil: '<path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>',
};
function icon(name, size) {
  const t = document.createElement("template");
  t.innerHTML = `<svg class="i" viewBox="0 0 24 24" aria-hidden="true"${size ? ` style="width:${size}px;height:${size}px"` : ""}>${ICONS[name]}</svg>`;
  return t.content.firstChild;
}
function verifiedMark() {
  const t = document.createElement("template");
  t.innerHTML = '<svg class="vcheck" viewBox="0 0 24 24" role="img" aria-label="Professionnel vérifié"><title>Professionnel vérifié</title><circle cx="12" cy="12" r="11" fill="#1a6bff"/><path d="M7 12.5l3.2 3.2L17 9" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  return t.content.firstChild;
}
// 2400 → « 2,4 k » ; 142 → « 142 »
const compact = (n) => n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(".", ",").replace(/,0$/, "") + " k" : String(n);
const hhmm = (t) => t.replace(":", "h");
const dateFr = (d) => new Date(d).toLocaleDateString("fr-FR", { day: "numeric", month: "short", year: "numeric" });
const rateStr = (v) => Number(v).toFixed(1).replace(".", ",");

// Recadre au centre une photo choisie, la réduit en JPEG w×h : léger à envoyer, et retire aussi les métadonnées (position GPS…).
async function cropJpeg(file, w, h, maxBytes = 900000) {
  if (!file || !file.type.startsWith("image/")) throw new Error("Choisissez une photo (image).");
  if (file.size > 30e6) throw new Error("Cette image est trop lourde.");
  let src;
  try { src = await createImageBitmap(file, { imageOrientation: "from-image" }); }
  catch { src = await new Promise((ok, no) => { const u = URL.createObjectURL(file), i = new Image(); i.onload = () => ok(i); i.onerror = () => no(new Error("Impossible de lire cette image.")); i.src = u; }); }
  const sw = src.width || src.naturalWidth, sh = src.height || src.naturalHeight, k = Math.max(w / sw, h / sh);
  const c = document.createElement("canvas"); c.width = w; c.height = h;
  c.getContext("2d").drawImage(src, (w - sw * k) / 2, (h - sh * k) / 2, sw * k, sh * k);
  for (const q of [0.85, 0.72, 0.58]) { const b = await new Promise((r) => c.toBlob(r, "image/jpeg", q)); if (b && b.size <= maxBytes) return b; }
  throw new Error("Image trop lourde même réduite.");
}
const avatarUrl = (path) => sb.storage.from("avatars").getPublicUrl(path).data.publicUrl;
// Écran « Configurez votre profil » : imposé aux NOUVEAUX comptes (needs_setup) tant qu'ils n'ont pas de pseudo. Renvoie true si on a été redirigé.
async function gateProfile() {
  try {
    const { data } = await sb.rpc("my_profile_summary");
    if (data && data.needs_setup) { location.replace("configurer-profil.html?next=" + encodeURIComponent(location.pathname.split("/").pop() + location.search)); return true; }
  } catch (e) {}
  return false;
}
// Une publication : photo (chargée à la demande, dimensions réservées) + texte + date.
function postCard(p, withShop) {
  return el("article", { class: "post", "data-post": p.id },
    withShop ? el("a", { class: "post-shop", href: "commerce.html?id=" + encodeURIComponent(p.merchant_id), text: p.business_name }) : null,
    p.image_path ? el("img", { src: imgUrl(p.image_path), alt: "Photo publiée" + (p.business_name ? " par " + p.business_name : ""), loading: "lazy", decoding: "async", width: 1080, height: 810 }) : null,
    el("p", { class: "post-body", text: p.body }),
    el("p", { class: "post-date", text: ago(p.created_at) }));
}
const ERR = { not_found: "Cette page n'existe pas ou n'est plus disponible.", not_authenticated: "Connectez-vous pour continuer.", cannot_follow_self: "Vous ne pouvez pas suivre votre propre page." };
const fr = (e) => { const m = String(e && e.message || e || ""); const k = Object.keys(ERR).find((c) => m.includes(c)); return k ? ERR[k] : "Une erreur est survenue. Réessayez dans un instant."; };
async function currentSession() { if (!sb) return null; const { data } = await sb.auth.getSession(); return data && data.session; }

// ---------- Signalement (page de commerce, avis, problème de l'application)
const REPORT_REASONS = {
  content: [["false_info", "Informations fausses"], ["scam", "Arnaque"], ["inappropriate", "Contenu inapproprié"], ["other", "Autre"]],
  app: [["bug", "Un bug : quelque chose ne marche pas"], ["other", "Autre problème"]],
};
const REPORT_ERR = {
  details_required: "Décrivez le problème en quelques mots (10 caractères minimum).",
  already_reported: "Vous avez déjà signalé cet élément : notre équipe l'examine.",
  too_many_reports: "Vous avez atteint la limite de 10 signalements par jour.",
  own_page: "Vous ne pouvez pas signaler votre propre page.",
  own_review: "Vous ne pouvez pas signaler votre propre avis.",
  email_not_confirmed: "Confirmez d'abord votre adresse email.",
  not_found: "Cet élément n'existe plus.",
  invalid_reason: "Choisissez un motif.",
};
// Formulaire : kind = "merchant" | "review" | "app". onDone() est appelé après l'accusé de réception affiché.
function reportForm({ kind, merchant = null, review = null, title, page = null, onDone }) {
  const reasons = REPORT_REASONS[kind === "app" ? "app" : "content"];
  const err = el("p", { class: "err", id: "rp-err" });
  const details = el("textarea", { id: "rp-details", maxlength: 1000, placeholder: kind === "app" ? "Que s'est-il passé ? Sur quel écran ? Quel téléphone ?" : "Précisez si vous le souhaitez (obligatoire pour « Autre »)" });
  const send = el("button", { class: "btn", id: "rp-send", type: "button", text: "Envoyer le signalement" });
  const box = el("div", { id: "report-form" }, el("h2", { text: title }),
    el("fieldset", { class: "kinds" }, el("legend", { text: "Motif" }),
      ...reasons.map(([v, label], i) => el("label", { class: "check" }, el("input", { type: "radio", name: "rp-reason", value: v, checked: i === 0 }), el("span", { text: label })))),
    el("label", {}, "Détails", details), err, send,
    onDone ? el("button", { class: "btn ghost", id: "rp-cancel", type: "button", style: "margin-left:.5rem", text: "Annuler", onclick: () => onDone(false) }) : null);
  send.addEventListener("click", async () => {
    err.textContent = ""; send.disabled = true;
    const reason = box.querySelector("input[name=rp-reason]:checked").value;
    const { data, error } = await sb.rpc("submit_report", { p_kind: kind, p_merchant: merchant, p_review: review, p_reason: reason, p_details: details.value, p_page: kind === "app" ? (page || null) : null });
    if (error) { const k = Object.keys(REPORT_ERR).find((c) => String(error.message).includes(c)); err.textContent = k ? REPORT_ERR[k] : "Envoi impossible pour le moment. Réessayez dans un instant."; send.disabled = false; return; }
    const note = el("p", { id: "rp-mail", class: "hint" });
    box.replaceChildren(el("h2", { text: "Signalement reçu" }),
      el("p", { id: "rp-ref", text: `Merci. Votre signalement n° ${data.ref} a bien été reçu. Notre équipe va l'examiner.` }), note,
      el("button", { class: "btn", id: "rp-close", type: "button", text: "Fermer", onclick: () => onDone ? onDone(true) : history.back() }));
    sb.functions.invoke("report-ack", { body: { report_id: data.id } }).then((r) => { if (r && r.data && r.data.sent) note.textContent = "Un accusé de réception vient d'être envoyé à votre adresse email."; }, () => {});
  });
  return box;
}
function openReportDialog(opts) {
  let dlg = document.getElementById("report-dialog"); if (dlg) dlg.remove();
  dlg = el("dialog", { id: "report-dialog", "aria-label": "Signaler" }); const card = el("div", { class: "card" });
  card.append(reportForm({ ...opts, onDone: () => dlg.close() })); dlg.append(card);
  dlg.addEventListener("click", (e) => { if (e.target === dlg) dlg.close(); });
  document.body.append(dlg); dlg.showModal();
}
