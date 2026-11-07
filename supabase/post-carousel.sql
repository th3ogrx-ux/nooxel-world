-- Nooxel World — Carrousel de photos (plusieurs photos dans une même publication)
-- À coller dans Supabase → SQL Editor → Run, APRÈS publish-options.sql. Peut être relancé sans danger.
--
-- Une publication garde sa photo principale (image_path) et peut recevoir jusqu'à 9 photos de plus (extra_images).
-- Le fil et la page du commerce reçoivent la liste complète dans « images ». Les photos en plus sont protégées de la purge de nuit
-- et apparaissent dans l'export des données personnelles.

alter table public.merchant_posts add column if not exists extra_images text[] not null default '{}';
alter table public.merchant_posts drop constraint if exists posts_extra_images_ok;
alter table public.merchant_posts add constraint posts_extra_images_ok check (cardinality(extra_images) <= 9 and (image_path is not null or cardinality(extra_images) = 0));

drop function if exists public.create_post(text, text, boolean, boolean, text);
create or replace function public.create_post(p_body text, p_image_path text default null, p_hide_likes boolean default false, p_comments_disabled boolean default false, p_category text default 'nouveaute', p_extra_paths text[] default '{}')
returns uuid
language plpgsql security definer set search_path = public, storage
as $$
declare m public.merchant_profiles; v_id uuid; v_body text := btrim(coalesce(p_body, '')); v_img text := nullif(btrim(coalesce(p_image_path, '')), ''); v_extra text[] := coalesce(p_extra_paths, '{}'); x text;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where owner_id = auth.uid() for update;
  if not found then raise exception 'no_profile'; end if;
  if m.verification <> 'verified' then raise exception 'not_verified'; end if;
  if char_length(v_body) > 2000 or (char_length(v_body) < 1 and v_img is null) then raise exception 'invalid_body'; end if;
  if coalesce(p_category, 'nouveaute') not in ('nouveaute', 'promotion', 'evenement', 'coulisses') then raise exception 'invalid_category'; end if;
  if (select count(*) from public.merchant_posts where merchant_id = m.id and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'too_many_posts';
  end if;
  if cardinality(v_extra) > 9 or (v_img is null and cardinality(v_extra) > 0) then raise exception 'too_many_images'; end if;
  if cardinality(v_extra) <> (select count(distinct e) from unnest(v_extra) e) or v_img = any(v_extra) then raise exception 'invalid_image'; end if;
  foreach x in array (case when v_img is null then '{}'::text[] else array_prepend(v_img, v_extra) end) loop
    if left(x, 37) <> m.id::text || '/' or x !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$' then raise exception 'invalid_image'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'merchant-media' and name = x) then raise exception 'image_not_found'; end if;
  end loop;
  insert into public.merchant_posts (merchant_id, body, image_path, extra_images, hide_likes, comments_disabled, category)
  values (m.id, v_body, v_img, v_extra, coalesce(p_hide_likes, false), coalesce(p_comments_disabled, false), coalesce(p_category, 'nouveaute')) returning id into v_id;
  return v_id;
end;
$$;

-- Fichiers orphelins : les photos en plus d'une publication, les vignettes, les logos et les couvertures ne sont jamais effacés tant qu'ils servent
create or replace function public.system_orphan_media()
returns setof text
language sql stable security definer set search_path = public, storage
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'merchant-media' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.merchant_posts p where p.image_path = o.name or o.name = any(p.extra_images))
     and not exists (select 1 from public.merchant_videos v where v.poster_path = o.name)
     and not exists (select 1 from public.merchant_profiles m where m.logo_path = o.name or m.cover_path = o.name);
$$;
revoke all on function public.system_orphan_media() from public, anon, authenticated;
grant execute on function public.system_orphan_media() to service_role;

-- Fil d'actualité et page du commerce : renvoient la liste des photos
create or replace function public.feed_mix(p_seen uuid[] default '{}', p_followed integer default 5, p_discover integer default 3)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_f integer := least(greatest(coalesce(p_followed, 5), 0), 10);
  v_d integer := least(greatest(coalesce(p_discover, 3), 0), 10);
  v_seen uuid[] := coalesce(p_seen, '{}');
  ids_f uuid[]; ids_d uuid[]; ids_x uuid[]; v_gap integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if cardinality(v_seen) > 500 then v_seen := v_seen[1:500]; end if;
  select coalesce(array_agg(id order by created_at desc, id desc), '{}') into ids_f from (
    select p.id, p.created_at from public.merchant_posts p
      join public.follows f on f.merchant_id = p.merchant_id and f.user_id = v_uid
      join public.merchant_profiles m on m.id = p.merchant_id and m.verification = 'verified'
     where not (p.id = any(v_seen))
     order by p.created_at desc, p.id desc limit v_f) x;
  select coalesce(array_agg(id), '{}') into ids_d from (
    select p.id from public.merchant_posts p
      join public.merchant_profiles m on m.id = p.merchant_id and m.verification = 'verified' and m.owner_id <> v_uid
     where not (p.id = any(v_seen))
       and not exists (select 1 from public.follows f where f.user_id = v_uid and f.merchant_id = p.merchant_id)
     order by (p.created_at > now() - interval '60 days') desc, random() limit v_d + (v_f - cardinality(ids_f))) x;
  v_gap := v_d + (v_f - cardinality(ids_f)) - cardinality(ids_d);      -- pas assez de suggestions : on complète avec des publications de commerces suivis
  ids_x := '{}';
  if v_gap > 0 then
    select coalesce(array_agg(id order by created_at desc, id desc), '{}') into ids_x from (
      select p.id, p.created_at from public.merchant_posts p
        join public.follows f on f.merchant_id = p.merchant_id and f.user_id = v_uid
        join public.merchant_profiles m on m.id = p.merchant_id and m.verification = 'verified'
       where not (p.id = any(v_seen)) and not (p.id = any(ids_f))
       order by p.created_at desc, p.id desc limit v_gap) x;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'body', p.body, 'image_path', p.image_path, 'images', case when p.image_path is null then '[]'::jsonb else jsonb_build_array(p.image_path) || to_jsonb(p.extra_images) end, 'created_at', p.created_at,
             'merchant_id', p.merchant_id, 'business_name', m.business_name, 'logo_path', m.logo_path,
             'has_badge', m.follower_count >= public.badge_threshold(), 'like_count', p.like_count, 'comment_count', p.comment_count, 'hide_likes', p.hide_likes, 'comments_disabled', p.comments_disabled,
             'liked', exists (select 1 from public.post_likes l where l.post_id = p.id and l.user_id = v_uid),
             'discover', p.id = any(ids_d)) order by o.ord)
    from unnest(ids_f || ids_d || ids_x) with ordinality as o(id, ord)
    join public.merchant_posts p on p.id = o.id join public.merchant_profiles m on m.id = p.merchant_id), '[]'::jsonb);
end;
$$;

create or replace function public.list_merchant_posts(p_merchant uuid, p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'body', x.body, 'image_path', x.image_path, 'images', case when x.image_path is null then '[]'::jsonb else jsonb_build_array(x.image_path) || to_jsonb(x.extra_images) end, 'created_at', x.created_at,
             'like_count', x.like_count, 'liked', exists (select 1 from public.post_likes l where l.post_id = x.id and l.user_id = auth.uid()))
             order by x.created_at desc, x.id desc)
    from (select p.* from public.merchant_posts p join public.merchant_profiles m on m.id = p.merchant_id
           where p.merchant_id = p_merchant and (m.verification = 'verified' or m.owner_id = auth.uid())
             and (p_before is null or p.created_at < p_before)
           order by p.created_at desc, p.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- Export des données personnelles : inclut les photos en plus
create or replace function public.export_my_data()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); m public.merchant_profiles;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where owner_id = v_uid;
  return jsonb_build_object(
    'exporte_le', now(),
    'compte', (select jsonb_build_object('email', u.email, 'cree_le', u.created_at, 'email_confirme_le', u.email_confirmed_at) from auth.users u where u.id = v_uid),
    'profil', (select jsonb_build_object('pseudo', p.pseudo, 'prenom', p.first_name, 'photo', p.avatar_path, 'cree_le', p.created_at) from public.user_profiles p where p.user_id = v_uid),
    'avis', coalesce((select jsonb_agg(jsonb_build_object('commerce', mm.business_name, 'note', r.rating, 'texte', r.body, 'j_y_suis_alle', r.visited, 'statut', r.status, 'date', r.created_at) order by r.created_at)
                        from public.reviews r join public.merchant_profiles mm on mm.id = r.merchant_id where r.user_id = v_uid), '[]'::jsonb),
    'commerces_suivis', coalesce((select jsonb_agg(jsonb_build_object('commerce', mm.business_name, 'depuis', f.created_at) order by f.created_at)
                        from public.follows f join public.merchant_profiles mm on mm.id = f.merchant_id where f.user_id = v_uid), '[]'::jsonb),
    'coeurs_publications', (select count(*) from public.post_likes where user_id = v_uid),
    'coeurs_videos', (select count(*) from public.video_likes where user_id = v_uid),
    'notifications', coalesce((select jsonb_agg(jsonb_build_object('type', n.kind, 'date', n.created_at, 'lue', n.read_at is not null) order by n.created_at)
                        from public.notifications n where n.user_id = v_uid), '[]'::jsonb),
    'signalements_envoyes', coalesce((select jsonb_agg(jsonb_build_object('numero', q.ref, 'type', q.kind, 'motif', q.reason, 'details', q.details, 'statut', q.status, 'date', q.created_at) order by q.created_at)
                        from public.reports q where q.reporter_id = v_uid), '[]'::jsonb),
    'commerce', case when m.id is null then null else jsonb_build_object('nom', m.business_name, 'description', m.description, 'adresse', m.address,
                        'verification', m.verification, 'categorie', m.category, 'site', m.website, 'telephone_public', m.contact_phone, 'horaires', m.opening_hours,
                        'publications', coalesce((select jsonb_agg(jsonb_build_object('texte', p.body, 'photo', p.image_path, 'photos_supplementaires', to_jsonb(p.extra_images), 'date', p.created_at) order by p.created_at) from public.merchant_posts p where p.merchant_id = m.id), '[]'::jsonb),
                        'videos', coalesce((select jsonb_agg(jsonb_build_object('legende', v.caption, 'duree_s', v.duration_s, 'date', v.created_at) order by v.created_at) from public.merchant_videos v where v.merchant_id = m.id), '[]'::jsonb)) end);
end;
$$;

revoke all on function public.create_post(text, text, boolean, boolean, text, text[]), public.feed_mix(uuid[], integer, integer),
  public.list_merchant_posts(uuid, timestamptz, integer), public.export_my_data() from public, anon, authenticated;
grant execute on function public.create_post(text, text, boolean, boolean, text, text[]), public.feed_mix(uuid[], integer, integer),
  public.list_merchant_posts(uuid, timestamptz, integer), public.export_my_data() to authenticated;
