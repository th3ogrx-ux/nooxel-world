// Codes d'erreur levés par les fonctions SQL → statut HTTP + message lisible en français.
const TABLE: Record<string, [number, string]> = {
  not_authenticated: [401, "Connexion requise."],
  forbidden: [403, "Accès refusé."],
  no_profile: [409, "Créez d'abord votre profil professionnel."],
  email_not_confirmed: [403, "Confirmez d'abord votre adresse email."],
  request_pending: [409, "Une demande de vérification est déjà en cours."],
  already_verified: [409, "Votre compte est déjà vérifié."],
  too_many_attempts: [429, "Trop d'essais. Réessayez dans une heure."],
  invalid_siret: [400, "Ce numéro SIRET n'est pas valide (14 chiffres)."],
  siret_blocked: [403, "Ce SIRET ne peut plus être utilisé avec ce compte."],
  siret_already_claimed: [409, "Ce SIRET est déjà associé à un autre compte. Laissez le champ vide pour envoyer la demande sans SIRET."],
  siret_not_found: [404, "Aucune entreprise trouvée avec ce SIRET."],
  siret_inactive: [422, "Cet établissement n'est plus actif."],
  api_unavailable: [502, "Le service de vérification est indisponible. Réessayez plus tard."],
  not_found: [404, "Élément introuvable."],
};

export function mapError(codeOrMessage: string): { status: number; code: string; message: string } {
  const code = Object.keys(TABLE).find((c) => codeOrMessage?.includes(c)) ?? "internal";
  const [status, message] = TABLE[code] ?? [500, "Erreur interne."];
  return { status, code, message };
}

export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
  });
}
