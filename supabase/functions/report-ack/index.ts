// Accusé de réception par email d'un signalement (gratuit : API d'envoi de Brevo, 300 emails par jour).
// POST { report_id } — réservé à la personne qui a signalé. Ne contient jamais le détail du signalement.
// Secrets à créer dans Supabase → Edge Functions → Secrets : BREVO_API_KEY et ACK_SENDER_EMAIL (expéditeur validé chez Brevo).
import { createClient } from "npm:@supabase/supabase-js@2";
import { CORS, json } from "../_shared/errors.ts";

const REASONS: Record<string, string> = {
  false_info: "informations fausses", scam: "arnaque", inappropriate: "contenu inapproprié", other: "autre motif", bug: "problème de l'application",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, code: "method" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ ok: false, code: "not_authenticated", message: "Connexion requise." }, 401);

  let reportId = "";
  try { reportId = String((await req.json()).report_id ?? ""); } catch { /* corps invalide */ }
  if (!/^[0-9a-f-]{36}$/.test(reportId)) return json({ ok: false, code: "invalid_report" }, 400);

  const apiKey = Deno.env.get("BREVO_API_KEY"), sender = Deno.env.get("ACK_SENDER_EMAIL");
  if (!apiKey || !sender) return json({ ok: false, code: "not_configured" }, 503);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const info = await admin.rpc("system_report_ack_info", { p_report: reportId, p_user: user.id });
  if (info.error || !info.data) return json({ ok: true, sent: false });         // pas le vôtre, ou déjà envoyé : rien à faire
  const i = info.data as { email: string; ref: number; kind: string; reason: string; target: string | null };

  const what = i.kind === "app" ? "votre signalement d'un problème dans l'application" : `votre signalement concernant « ${i.target ?? "ce contenu"} »`;
  const text = [
    "Bonjour,", "",
    `Nous avons bien reçu ${what} (n° ${i.ref}, motif : ${REASONS[i.reason] ?? i.reason}).`,
    "Un membre de l'équipe va l'examiner. Vous n'avez rien d'autre à faire.", "",
    "Pour protéger la vie privée de chacun, nous ne communiquons pas le détail des décisions prises.", "",
    "L'équipe Nooxel World",
  ].join("\n");

  let r: Response;
  try {
    r = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST", headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ sender: { name: "Nooxel World", email: sender }, to: [{ email: i.email }], subject: `Nooxel World — votre signalement n° ${i.ref} a bien été reçu`, textContent: text }),
      signal: AbortSignal.timeout(8000),
    });
  } catch { return json({ ok: false, code: "send_failed" }, 502); }
  if (!r.ok) return json({ ok: false, code: "send_failed" }, 502);

  await admin.rpc("system_mark_report_acked", { p_report: reportId });
  return json({ ok: true, sent: true });
});
