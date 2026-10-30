// Version « un seul fichier » de supabase/functions/report-ack/index.ts, à coller telle quelle dans l'éditeur de fonctions de Supabase.
// Ne pas modifier ici : régénérée à partir des sources.
// supabase/functions/report-ack/index.ts
import { createClient } from "npm:@supabase/supabase-js@2";

// supabase/functions/_shared/errors.ts
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

// supabase/functions/report-ack/index.ts
var REASONS = {
  false_info: "informations fausses",
  scam: "arnaque",
  inappropriate: "contenu inappropri\xE9",
  other: "autre motif",
  bug: "probl\xE8me de l'application"
};
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, code: "method" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ ok: false, code: "not_authenticated", message: "Connexion requise." }, 401);
  let reportId = "";
  try {
    reportId = String((await req.json()).report_id ?? "");
  } catch {
  }
  if (!/^[0-9a-f-]{36}$/.test(reportId)) return json({ ok: false, code: "invalid_report" }, 400);
  const apiKey = Deno.env.get("BREVO_API_KEY"), sender = Deno.env.get("ACK_SENDER_EMAIL");
  if (!apiKey || !sender) return json({ ok: false, code: "not_configured" }, 503);
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const info = await admin.rpc("system_report_ack_info", { p_report: reportId, p_user: user.id });
  if (info.error || !info.data) return json({ ok: true, sent: false });
  const i = info.data;
  const what = i.kind === "app" ? "votre signalement d'un probl\xE8me dans l'application" : `votre signalement concernant \xAB ${i.target ?? "ce contenu"} \xBB`;
  const text = [
    "Bonjour,",
    "",
    `Nous avons bien re\xE7u ${what} (n\xB0 ${i.ref}, motif : ${REASONS[i.reason] ?? i.reason}).`,
    "Un membre de l'\xE9quipe va l'examiner. Vous n'avez rien d'autre \xE0 faire.",
    "",
    "Pour prot\xE9ger la vie priv\xE9e de chacun, nous ne communiquons pas le d\xE9tail des d\xE9cisions prises.",
    "",
    "L'\xE9quipe Nooxel World"
  ].join("\n");
  let r;
  try {
    r = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ sender: { name: "Nooxel World", email: sender }, to: [{ email: i.email }], subject: `Nooxel World \u2014 votre signalement n\xB0 ${i.ref} a bien \xE9t\xE9 re\xE7u`, textContent: text }),
      signal: AbortSignal.timeout(8e3)
    });
  } catch {
    return json({ ok: false, code: "send_failed" }, 502);
  }
  if (!r.ok) return json({ ok: false, code: "send_failed" }, 502);
  await admin.rpc("system_mark_report_acked", { p_report: reportId });
  return json({ ok: true, sent: true });
});
