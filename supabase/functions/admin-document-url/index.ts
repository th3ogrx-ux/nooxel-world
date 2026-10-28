// Donne à un ADMINISTRATEUR un lien de 60 secondes vers une pièce. La consultation est journalisée.
// POST { request_id, which: "id" | "selfie" }
import { createClient } from "npm:@supabase/supabase-js@2";
import { CORS, json, mapError } from "../_shared/errors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, code: "method" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  let body: any = {};
  try { body = await req.json(); } catch { /* vide */ }

  // La fonction SQL vérifie « est administrateur ? » avec l'identité de l'appelant ET écrit la trace.
  const { data: path, error } = await userClient.rpc("admin_authorize_document_access", {
    p_request_id: body.request_id, p_which: body.which,
  });
  if (error) { const e = mapError(error.message); return json({ ok: false, code: e.code, message: e.message }, e.status); }

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const signed = await admin.storage.from("verification-docs").createSignedUrl(path as string, 60);
  if (signed.error || !signed.data) return json({ ok: false, code: "not_found", message: "Fichier introuvable." }, 404);
  return json({ ok: true, url: signed.data.signedUrl, expires_in: 60 });
});
