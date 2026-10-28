// Version « un seul fichier » de supabase/functions/admin-document-url/index.ts, à coller telle quelle dans l'éditeur de fonctions de Supabase.
// Ne pas modifier ici : régénérée à partir des sources.
// ../../../../../../home/user/nooxel-world/supabase/functions/admin-document-url/index.ts
import { createClient } from "npm:@supabase/supabase-js@2";

// ../../../../../../home/user/nooxel-world/supabase/functions/_shared/errors.ts
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

// ../../../../../../home/user/nooxel-world/supabase/functions/admin-document-url/index.ts
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, code: "method" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } }
  });
  let body = {};
  try {
    body = await req.json();
  } catch {
  }
  const { data: path, error } = await userClient.rpc("admin_authorize_document_access", {
    p_request_id: body.request_id,
    p_which: body.which
  });
  if (error) {
    const e = mapError(error.message);
    return json({ ok: false, code: e.code, message: e.message }, e.status);
  }
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const signed = await admin.storage.from("verification-docs").createSignedUrl(path, 60);
  if (signed.error || !signed.data) return json({ ok: false, code: "not_found", message: "Fichier introuvable." }, 404);
  return json({ ok: true, url: signed.data.signedUrl, expires_in: 60 });
});
