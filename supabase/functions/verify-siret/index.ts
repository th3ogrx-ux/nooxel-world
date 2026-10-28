// Niveau 1 : vérifie un SIRET auprès de l'API publique « Recherche d'entreprises » (gratuite, sans clé).
// POST { siret }  — nécessite d'être connecté. Renvoie { ok, badge, referral_code, company }.
import { createClient } from "npm:@supabase/supabase-js@2";
import { CORS, json, mapError } from "../_shared/errors.ts";
import { isValidSiretFormat, normalizeSiret, parseCompanySearch } from "../_shared/siret.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, code: "method" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const auth = req.headers.get("Authorization") ?? "";
  // 1) Qui appelle ? (jamais confiance à un identifiant envoyé par le navigateur)
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ ok: false, ...mapError("not_authenticated") }, 401);

  let siret = "";
  try { siret = normalizeSiret((await req.json()).siret); } catch { /* corps invalide */ }
  if (!isValidSiretFormat(siret)) return json({ ok: false, ...mapError("invalid_siret") }, 400);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const fail = (c: string) => { const e = mapError(c); return json({ ok: false, code: e.code, message: e.message }, e.status); };

  // 2) Conditions + limite d'essais (la tentative est enregistrée AVANT l'appel à l'API)
  const pre = await admin.rpc("system_siret_precheck", { p_user: user.id, p_siret: siret });
  if (pre.error) return fail(pre.error.message);
  if (pre.data !== "ok") return fail(String(pre.data));

  // 3) API publique
  let lookup;
  try {
    const r = await fetch(`https://recherche-entreprises.api.gouv.fr/search?q=${siret}&page=1&per_page=5`, {
      headers: { Accept: "application/json" }, signal: AbortSignal.timeout(8000),
    });
    if (!r.ok) return fail("api_unavailable");
    lookup = parseCompanySearch(await r.json(), siret);
  } catch { return fail("api_unavailable"); }
  if (!lookup.found) return fail("siret_not_found");
  if (!lookup.active) return fail("siret_inactive");

  // 4) Attribution du niveau 1 (réservée au serveur)
  const done = await admin.rpc("system_set_company_verified", { p_user: user.id, p_siret: siret, p_check: lookup.check });
  if (done.error) return fail(done.error.message);
  return json({ ok: true, badge: "entreprise vérifiée", referral_code: done.data, company: lookup.check.name ?? null });
});
