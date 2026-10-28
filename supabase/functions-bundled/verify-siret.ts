// Version « un seul fichier » de supabase/functions/verify-siret/index.ts, à coller telle quelle dans l'éditeur de fonctions de Supabase.
// Ne pas modifier ici : régénérée à partir des sources.
import { createClient } from "npm:@supabase/supabase-js@2";

var TABLE = {
  not_authenticated: [401, "Connexion requise."],
  forbidden: [403, "Accès refusé."],
  no_profile: [409, "Créez d'abord votre profil professionnel."],
  email_not_confirmed: [403, "Confirmez d'abord votre adresse email."],
  request_pending: [409, "Une demande de vérification est déjà en cours."],
  already_verified: [409, "Votre entreprise est déjà vérifiée."],
  too_many_attempts: [429, "Trop d'essais. Réessayez dans une heure."],
  invalid_siret: [400, "Ce numéro SIRET n'est pas valide (14 chiffres)."],
  siret_blocked: [403, "Ce SIRET ne peut pas être vérifié automatiquement. Utilisez la vérification manuelle."],
  siret_already_claimed: [409, "Ce SIRET est déjà associé à un autre compte. Si c'est le vôtre, contactez-nous ou utilisez la vérification manuelle."],
  siret_not_found: [404, "Aucune entreprise trouvée avec ce SIRET."],
  siret_inactive: [422, "Cet établissement n'est plus actif."],
  api_unavailable: [502, "Le service de vérification est indisponible. Réessayez plus tard."],
  not_found: [404, "Élément introuvable."],
  invalid_document: [400, "Document invalide."],
  documents_deleted: [410, "Les pièces ont déjà été supprimées."]
};
function mapError(codeOrMessage) {
  const code = Object.keys(TABLE).find((c) => codeOrMessage?.includes(c)) ?? "internal";
  const [status, message] = TABLE[code] ?? [500, "Erreur interne."];
  return { status, code, message };
}
var CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
function json(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store", ...extra }
  });
}

function normalizeSiret(input) {
  return String(input ?? "").replace(/[\s.-]/g, "");
}
function isValidSiretFormat(siret) {
  if (!/^[0-9]{14}$/.test(siret)) return false;
  let sum = 0;
  for (let i = 0; i < 14; i++) {
    let d = Number(siret[13 - i]);
    if (i % 2 === 1) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
  }
  if (sum % 10 === 0) return true;
  if (siret.startsWith("356000000")) {
    return [...siret].reduce((s, d) => s + Number(d), 0) % 5 === 0;
  }
  return false;
}
function parseCompanySearch(json2, siret) {
  const results = Array.isArray(json2?.results) ? json2.results : [];
  for (const unit of results) {
    const candidates = [unit?.siege, ...Array.isArray(unit?.matching_etablissements) ? unit.matching_etablissements : []];
    const etab = candidates.find((e) => e && String(e.siret) === siret);
    if (!etab) continue;
    const unitActive = (unit.etat_administratif ?? "A") === "A";
    const etabActive = (etab.etat_administratif ?? "A") === "A";
    return {
      found: true,
      active: unitActive && etabActive,
      check: {
        source: "recherche-entreprises.api.gouv.fr",
        checked_at: (/* @__PURE__ */ new Date()).toISOString(),
        siren: unit.siren ?? null,
        name: unit.nom_complet ?? unit.nom_raison_sociale ?? null,
        unit_state: unit.etat_administratif ?? null,
        establishment_state: etab.etat_administratif ?? null,
        activity: etab.activite_principale ?? unit.activite_principale ?? null,
        city: etab.libelle_commune ?? null,
        postal_code: etab.code_postal ?? null
      }
    };
  }
  return { found: false };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, code: "method" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const auth = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ ok: false, ...mapError("not_authenticated") }, 401);
  let siret = "";
  try {
    siret = normalizeSiret((await req.json()).siret);
  } catch {
  }
  if (!isValidSiretFormat(siret)) return json({ ok: false, ...mapError("invalid_siret") }, 400);
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const fail = (c) => {
    const e = mapError(c);
    return json({ ok: false, code: e.code, message: e.message }, e.status);
  };
  const pre = await admin.rpc("system_siret_precheck", { p_user: user.id, p_siret: siret });
  if (pre.error) return fail(pre.error.message);
  if (pre.data !== "ok") return fail(String(pre.data));
  let lookup;
  try {
    const r = await fetch(`https://recherche-entreprises.api.gouv.fr/search?q=${siret}&page=1&per_page=5`, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(8e3)
    });
    if (!r.ok) return fail("api_unavailable");
    lookup = parseCompanySearch(await r.json(), siret);
  } catch {
    return fail("api_unavailable");
  }
  if (!lookup.found) return fail("siret_not_found");
  if (!lookup.active) return fail("siret_inactive");
  const done = await admin.rpc("system_set_company_verified", { p_user: user.id, p_siret: siret, p_check: lookup.check });
  if (done.error) return fail(done.error.message);
  return json({ ok: true, badge: "entreprise vérifiée", referral_code: done.data, company: lookup.check.name ?? null });
});
