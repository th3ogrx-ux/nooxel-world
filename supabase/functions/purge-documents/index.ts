// Tâche planifiée (1 fois par jour) : supprime réellement les pièces dont l'échéance est passée,
// ainsi que les fichiers orphelins. Protégée par un secret : x-cron-secret.
import { createClient } from "npm:@supabase/supabase-js@2";
import { json } from "../_shared/errors.ts";

function sameSecret(a: string, b: string): boolean {      // comparaison à temps constant
  if (!a || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("CRON_SECRET") ?? "";
  if (!sameSecret(req.headers.get("x-cron-secret") ?? "", expected)) return json({ ok: false }, 401);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const bucket = admin.storage.from("verification-docs");

  const cands = await admin.rpc("system_purge_candidates");
  if (cands.error) return json({ ok: false, error: cands.error.message }, 500);
  const rows = (cands.data ?? []) as { request_id: string; id_doc_path: string | null; selfie_path: string | null }[];

  let removed = 0, marked = 0;
  for (let i = 0; i < rows.length; i += 50) {
    const batch = rows.slice(i, i + 50);
    const paths = batch.flatMap((r) => [r.id_doc_path, r.selfie_path]).filter((p): p is string => !!p);
    if (paths.length) {
      const del = await bucket.remove(paths);
      if (del.error) continue;                          // on réessaiera demain ; rien n'est marqué supprimé
      removed += paths.length;
    }
    const m = await admin.rpc("system_mark_docs_deleted", { p_ids: batch.map((r) => r.request_id) });
    if (!m.error) marked += Number(m.data ?? 0);
  }

  // fichiers sans demande associée (envois abandonnés, comptes supprimés)
  let orphans = 0;
  const o = await admin.rpc("system_orphan_files");
  if (!o.error && Array.isArray(o.data) && o.data.length) {
    const names = o.data as string[];
    for (let i = 0; i < names.length; i += 50) {
      const del = await bucket.remove(names.slice(i, i + 50));
      if (!del.error) orphans += Math.min(50, names.length - i);
    }
  }

  // photos de posts sans publication (suppression d'un compte ou d'un post, envoi abandonné) : droit à l'effacement
  let media = 0;
  const mm = await admin.rpc("system_orphan_media");
  if (!mm.error && Array.isArray(mm.data) && mm.data.length) {
    const mediaBucket = admin.storage.from("merchant-media"), names = mm.data as string[];
    for (let i = 0; i < names.length; i += 50) {
      const del = await mediaBucket.remove(names.slice(i, i + 50));
      if (!del.error) media += Math.min(50, names.length - i);
    }
  }

  // vidéos sans publication (vidéo ou compte supprimé, envoi abandonné)
  let videos = 0;
  const vv = await admin.rpc("system_orphan_videos");
  if (!vv.error && Array.isArray(vv.data) && vv.data.length) {
    const videoBucket = admin.storage.from("merchant-videos"), names = vv.data as string[];
    for (let i = 0; i < names.length; i += 50) {
      const del = await videoBucket.remove(names.slice(i, i + 50));
      if (!del.error) videos += Math.min(50, names.length - i);
    }
  }
  return json({ ok: true, files_removed: removed, requests_marked: marked, orphan_files_removed: orphans, orphan_media_removed: media, orphan_videos_removed: videos });
});
