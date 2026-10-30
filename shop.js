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
const imgUrl = (path) => sb.storage.from("merchant-media").getPublicUrl(path).data.publicUrl;
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
