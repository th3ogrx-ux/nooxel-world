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
