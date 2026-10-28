// Version « un seul fichier » de supabase/functions/purge-documents/index.ts, à coller telle quelle dans l'éditeur de fonctions de Supabase.
// Ne pas modifier ici : régénérée à partir des sources.
// ../../../../../../home/user/nooxel-world/supabase/functions/purge-documents/index.ts
import { createClient } from "npm:@supabase/supabase-js@2";

// ../../../../../../home/user/nooxel-world/supabase/functions/_shared/errors.ts
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

// ../../../../../../home/user/nooxel-world/supabase/functions/purge-documents/index.ts
function sameSecret(a, b) {
  if (!a || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
Deno.serve(async (req) => {
  const expected = Deno.env.get("CRON_SECRET") ?? "";
  if (!sameSecret(req.headers.get("x-cron-secret") ?? "", expected)) return json({ ok: false }, 401);
  const admin = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const bucket = admin.storage.from("verification-docs");
  const cands = await admin.rpc("system_purge_candidates");
  if (cands.error) return json({ ok: false, error: cands.error.message }, 500);
  const rows = cands.data ?? [];
  let removed = 0, marked = 0;
  for (let i = 0; i < rows.length; i += 50) {
    const batch = rows.slice(i, i + 50);
    const paths = batch.flatMap((r) => [r.id_doc_path, r.selfie_path]).filter((p) => !!p);
    if (paths.length) {
      const del = await bucket.remove(paths);
      if (del.error) continue;
      removed += paths.length;
    }
    const m = await admin.rpc("system_mark_docs_deleted", { p_ids: batch.map((r) => r.request_id) });
    if (!m.error) marked += Number(m.data ?? 0);
  }
  let orphans = 0;
  const o = await admin.rpc("system_orphan_files");
  if (!o.error && Array.isArray(o.data) && o.data.length) {
    const names = o.data;
    for (let i = 0; i < names.length; i += 50) {
      const del = await bucket.remove(names.slice(i, i + 50));
      if (!del.error) orphans += Math.min(50, names.length - i);
    }
  }
  return json({ ok: true, files_removed: removed, requests_marked: marked, orphan_files_removed: orphans });
});
