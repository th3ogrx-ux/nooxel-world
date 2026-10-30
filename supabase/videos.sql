-- ============================================================================
-- Nooxel World — PHASE 2, ÉTAPE 5 : vidéos courtes (« Reels ») sur la page d'un commerce.
-- À coller dans Supabase → SQL Editor → Run, APRÈS reports.sql. Peut être relancé sans danger.
--
-- Limites (pour rester dans l'offre gratuite et ménager les forfaits mobiles) :
--   • 30 secondes au plus, fichier de 6 Mo au plus (la page réduit la vidéo en 480p avant l'envoi),
--     20 vidéos par commerce, 5 nouvelles vidéos par 24 h.
--   • Seuls les commerces VÉRIFIÉS publient. Le navigateur n'écrit jamais directement : tout passe par des fonctions.
--   • Une vignette (photo) accompagne chaque vidéo : la grille s'affiche sans télécharger aucune vidéo.
--   • Les fichiers sans publication (vidéo supprimée, compte supprimé) sont effacés chaque nuit (droit à l'effacement).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Stockage des vidéos (lecture publique, écriture réservée au propriétaire d'un commerce vérifié)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('merchant-videos', 'merchant-videos', true, 6291456, array['video/mp4', 'video/webm'])
on conflict (id) do update
  set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists mv_owner_insert on storage.objects;
create policy mv_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'merchant-videos' and public.owns_verified_folder((storage.foldername(name))[1]));
drop policy if exists mv_owner_delete on storage.objects;
create policy mv_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'merchant-videos' and public.owns_folder((storage.foldername(name))[1]));
drop policy if exists mv_owner_select on storage.objects;
create policy mv_owner_select on storage.objects for select to authenticated
  using (bucket_id = 'merchant-videos' and public.owns_folder((storage.foldername(name))[1]));

-- ---------------------------------------------------------------------------
-- 2. Table des vidéos
-- ---------------------------------------------------------------------------
create table if not exists public.merchant_videos (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchant_profiles(id) on delete cascade,
  caption     text check (caption is null or char_length(caption) <= 300),
  video_path  text not null check (video_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(mp4|webm)$'),
  poster_path text not null check (poster_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$'),
  duration_s  smallint not null check (duration_s between 1 and 30),
  created_at  timestamptz not null default now()
);
create index if not exists videos_by_merchant on public.merchant_videos (merchant_id, created_at desc);
create unique index if not exists videos_unique_file on public.merchant_videos (video_path);
create unique index if not exists videos_unique_poster on public.merchant_videos (poster_path);
alter table public.merchant_videos enable row level security;
revoke all on public.merchant_videos from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Fonctions
-- ---------------------------------------------------------------------------
create or replace function public.create_video(p_caption text, p_video_path text, p_poster_path text, p_duration integer)
returns uuid
language plpgsql security definer set search_path = public, storage
as $$
declare m public.merchant_profiles; v_id uuid; v_cap text := nullif(btrim(coalesce(p_caption, '')), '');
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where owner_id = auth.uid() for update;
  if not found then raise exception 'no_profile'; end if;
  if m.verification <> 'verified' then raise exception 'not_verified'; end if;
  if p_duration is null or p_duration < 1 or p_duration > 30 then raise exception 'invalid_duration'; end if;
  if v_cap is not null and char_length(v_cap) > 300 then raise exception 'caption_too_long'; end if;
  if p_video_path is null or p_poster_path is null or left(p_video_path, 37) <> m.id::text || '/' or left(p_poster_path, 37) <> m.id::text || '/' then
    raise exception 'invalid_file';
  end if;
  if (select count(*) from public.merchant_videos where merchant_id = m.id) >= 20 then raise exception 'too_many_videos'; end if;
  if (select count(*) from public.merchant_videos where merchant_id = m.id and created_at > now() - interval '24 hours') >= 5 then raise exception 'too_many_videos_today'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'merchant-videos' and name = p_video_path)
     or not exists (select 1 from storage.objects where bucket_id = 'merchant-media' and name = p_poster_path) then
    raise exception 'file_not_found';
  end if;
  insert into public.merchant_videos (merchant_id, caption, video_path, poster_path, duration_s)
  values (m.id, v_cap, p_video_path, p_poster_path, p_duration) returning id into v_id;
  return v_id;
end;
$$;

-- Supprimer SA vidéo : renvoie les chemins des deux fichiers (le navigateur les supprime ensuite ; la tâche de nuit rattrape tout oubli).
create or replace function public.delete_video(p_video uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_video text; v_poster text;
begin
  delete from public.merchant_videos v using public.merchant_profiles m
   where v.id = p_video and m.id = v.merchant_id and m.owner_id = auth.uid()
  returning v.video_path, v.poster_path into v_video, v_poster;
  if not found then raise exception 'not_found'; end if;
  return jsonb_build_object('video_path', v_video, 'poster_path', v_poster);
end;
$$;

-- Vidéos d'une page, de la plus récente à la plus ancienne, par pages (p_before = date de la dernière reçue).
create or replace function public.list_merchant_videos(p_merchant uuid, p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'caption', x.caption, 'video_path', x.video_path, 'poster_path', x.poster_path,
             'duration_s', x.duration_s, 'created_at', x.created_at) order by x.created_at desc, x.id desc)
    from (select v.* from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id
           where v.merchant_id = p_merchant and (m.verification = 'verified' or m.owner_id = auth.uid())
             and (p_before is null or v.created_at < p_before)
           order by v.created_at desc, v.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Nettoyage des fichiers orphelins (tâche de nuit « purge-documents »)
-- ---------------------------------------------------------------------------
-- Les vignettes appartiennent désormais aussi aux vidéos : elles ne sont plus considérées comme orphelines.
create or replace function public.system_orphan_media()
returns setof text
language sql stable security definer set search_path = public, storage
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'merchant-media' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.merchant_posts p where p.image_path = o.name)
     and not exists (select 1 from public.merchant_videos v where v.poster_path = o.name);
$$;

create or replace function public.system_orphan_videos()
returns setof text
language sql stable security definer set search_path = public, storage
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'merchant-videos' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.merchant_videos v where v.video_path = o.name);
$$;

revoke all on function
  public.create_video(text, text, text, integer), public.delete_video(uuid), public.list_merchant_videos(uuid, timestamptz, integer),
  public.system_orphan_media(), public.system_orphan_videos()
from public, anon, authenticated;
grant execute on function public.create_video(text, text, text, integer), public.delete_video(uuid), public.list_merchant_videos(uuid, timestamptz, integer) to authenticated;
grant execute on function public.system_orphan_media(), public.system_orphan_videos() to service_role;
