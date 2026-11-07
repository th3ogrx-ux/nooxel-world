-- Nooxel World — Écran « Nouvelle publication » (photo pour le fil, vidéo pour l'onglet Vidéos)
-- À coller dans Supabase → SQL Editor → Run, APRÈS comments.sql ET feed-algo.sql. Peut être relancé sans danger.
--
-- Ajoute aux photos et aux vidéos : « Masquer le nombre de likes », « Désactiver les commentaires » et une catégorie
-- (Nouveauté, Promotion, Événement, Coulisses : simplement enregistrée, rien n'est affiché). Une photo peut maintenant être publiée sans texte.

alter table public.merchant_posts  add column if not exists hide_likes boolean not null default false;
alter table public.merchant_posts  add column if not exists comments_disabled boolean not null default false;
alter table public.merchant_posts  add column if not exists category text not null default 'nouveaute';
alter table public.merchant_videos add column if not exists hide_likes boolean not null default false;
alter table public.merchant_videos add column if not exists comments_disabled boolean not null default false;
alter table public.merchant_videos add column if not exists category text not null default 'nouveaute';
alter table public.merchant_posts  drop constraint if exists posts_category_ok;
alter table public.merchant_posts  add constraint posts_category_ok check (category in ('nouveaute', 'promotion', 'evenement', 'coulisses'));
alter table public.merchant_videos drop constraint if exists videos_category_ok;
alter table public.merchant_videos add constraint videos_category_ok check (category in ('nouveaute', 'promotion', 'evenement', 'coulisses'));

-- Le texte d'une publication devient facultatif quand elle contient une photo
alter table public.merchant_posts drop constraint if exists merchant_posts_body_check;
alter table public.merchant_posts drop constraint if exists posts_content_ok;
alter table public.merchant_posts add constraint posts_content_ok check (char_length(btrim(body)) <= 2000 and (char_length(btrim(body)) >= 1 or image_path is not null));

drop function if exists public.create_post(text, text);
create or replace function public.create_post(p_body text, p_image_path text default null, p_hide_likes boolean default false, p_comments_disabled boolean default false, p_category text default 'nouveaute')
returns uuid
language plpgsql security definer set search_path = public, storage
as $$
declare m public.merchant_profiles; v_id uuid; v_body text := btrim(coalesce(p_body, '')); v_img text := nullif(btrim(coalesce(p_image_path, '')), '');
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
  if v_img is not null then
    if left(v_img, 37) <> m.id::text || '/' then raise exception 'invalid_image'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'merchant-media' and name = v_img) then raise exception 'image_not_found'; end if;
  end if;
  insert into public.merchant_posts (merchant_id, body, image_path, hide_likes, comments_disabled, category)
  values (m.id, v_body, v_img, coalesce(p_hide_likes, false), coalesce(p_comments_disabled, false), coalesce(p_category, 'nouveaute')) returning id into v_id;
  return v_id;
end;
$$;

drop function if exists public.create_video(text, text, text, integer);
create or replace function public.create_video(p_caption text, p_video_path text, p_poster_path text, p_duration integer, p_hide_likes boolean default false, p_comments_disabled boolean default false, p_category text default 'nouveaute')
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
  if coalesce(p_category, 'nouveaute') not in ('nouveaute', 'promotion', 'evenement', 'coulisses') then raise exception 'invalid_category'; end if;
  if p_video_path is null or p_poster_path is null or left(p_video_path, 37) <> m.id::text || '/' or left(p_poster_path, 37) <> m.id::text || '/' then
    raise exception 'invalid_file';
  end if;
  if (select count(*) from public.merchant_videos where merchant_id = m.id) >= 20 then raise exception 'too_many_videos'; end if;
  if (select count(*) from public.merchant_videos where merchant_id = m.id and created_at > now() - interval '24 hours') >= 5 then raise exception 'too_many_videos_today'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'merchant-videos' and name = p_video_path)
     or not exists (select 1 from storage.objects where bucket_id = 'merchant-media' and name = p_poster_path) then
    raise exception 'file_not_found';
  end if;
  insert into public.merchant_videos (merchant_id, caption, video_path, poster_path, duration_s, hide_likes, comments_disabled, category)
  values (m.id, v_cap, p_video_path, p_poster_path, p_duration, coalesce(p_hide_likes, false), coalesce(p_comments_disabled, false), coalesce(p_category, 'nouveaute')) returning id into v_id;
  return v_id;
end;
$$;

-- Commentaires : refusés quand le commerçant les a désactivés
create or replace function public.add_comment(p_kind text, p_item uuid, p_body text, p_parent uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); m public.merchant_profiles; v_body text := btrim(coalesce(p_body, '')); v_issue text; par public.comments; c public.comments;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from auth.users where id = v_uid and email_confirmed_at is not null) then raise exception 'email_not_confirmed'; end if;
  if not exists (select 1 from public.user_profiles where user_id = v_uid and pseudo is not null) then raise exception 'pseudo_required'; end if;
  m := public.comment_target(p_kind, p_item);
  if m.verification <> 'verified' then raise exception 'not_found'; end if;
  if (p_kind = 'post' and exists (select 1 from public.merchant_posts where id = p_item and comments_disabled))
     or (p_kind = 'video' and exists (select 1 from public.merchant_videos where id = p_item and comments_disabled)) then raise exception 'comments_disabled'; end if;
  if char_length(v_body) < 1 then raise exception 'comment_empty'; end if;
  if char_length(v_body) > 500 then raise exception 'comment_too_long'; end if;
  v_issue := public.comment_text_issue(v_body); if v_issue is not null then raise exception 'comment_%', v_issue; end if;
  if (select count(*) from public.comments where user_id = v_uid and created_at > now() - interval '1 hour') >= 30 then raise exception 'too_many_comments'; end if;
  if p_parent is not null then
    select * into par from public.comments where id = p_parent;
    if not found or par.parent_id is not null or not ((p_kind = 'post' and par.post_id = p_item) or (p_kind = 'video' and par.video_id = p_item)) then raise exception 'not_found'; end if;
  end if;
  insert into public.comments (post_id, video_id, user_id, parent_id, body)
  values (case when p_kind = 'post' then p_item end, case when p_kind = 'video' then p_item end, v_uid, p_parent, v_body) returning * into c;
  return public.comment_json(c.id, m.owner_id);
end;
$$;

-- Fil d'actualité et fil de vidéos : renvoient aussi les deux options
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
    select jsonb_agg(jsonb_build_object('id', p.id, 'body', p.body, 'image_path', p.image_path, 'created_at', p.created_at,
             'merchant_id', p.merchant_id, 'business_name', m.business_name, 'logo_path', m.logo_path,
             'has_badge', m.follower_count >= public.badge_threshold(), 'like_count', p.like_count, 'comment_count', p.comment_count, 'hide_likes', p.hide_likes, 'comments_disabled', p.comments_disabled,
             'liked', exists (select 1 from public.post_likes l where l.post_id = p.id and l.user_id = v_uid),
             'discover', p.id = any(ids_d)) order by o.ord)
    from unnest(ids_f || ids_d || ids_x) with ordinality as o(id, ord)
    join public.merchant_posts p on p.id = o.id join public.merchant_profiles m on m.id = p.merchant_id), '[]'::jsonb);
end;
$$;

create or replace function public.video_feed(p_before timestamptz default null, p_limit integer default 8, p_kind text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_kind is not null and p_kind not in ('shop', 'mobile') then raise exception 'invalid_filter' using errcode = '22023'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'caption', x.caption, 'video_path', x.video_path, 'poster_path', x.poster_path,
             'duration_s', x.duration_s, 'created_at', x.created_at, 'like_count', x.like_count,
             'liked', exists (select 1 from public.video_likes l where l.video_id = x.id and l.user_id = auth.uid()),
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'logo_path', x.logo_path, 'kind', x.profile_kind,
             'lat', coalesce(x.lat, x.zone_lat), 'lng', coalesce(x.lng, x.zone_lng),
             'review_count', x.review_count, 'rating_avg', case when x.review_count > 0 then round(x.rating_sum::numeric / x.review_count, 1) end,
             'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = x.merchant_id),
             'is_owner', x.owner_id = auth.uid(), 'comment_count', x.comment_count,
             'hide_likes', x.hide_likes, 'comments_disabled', x.comments_disabled)
             order by x.created_at desc, x.id desc)
    from (select v.*, m.business_name, m.logo_path, m.profile_kind, m.lat, m.lng, m.zone_lat, m.zone_lng, m.review_count, m.rating_sum, m.owner_id
            from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id and m.verification = 'verified'
           where (p_before is null or v.created_at < p_before) and (p_kind is null or m.profile_kind = p_kind)
           order by v.created_at desc, v.id desc limit least(greatest(coalesce(p_limit, 8), 1), 20)) x), '[]'::jsonb);
end;
$$;

revoke all on function public.create_post(text, text, boolean, boolean, text), public.create_video(text, text, text, integer, boolean, boolean, text),
  public.add_comment(text, uuid, text, uuid), public.feed_mix(uuid[], integer, integer), public.video_feed(timestamptz, integer, text) from public, anon, authenticated;
grant execute on function public.create_post(text, text, boolean, boolean, text), public.create_video(text, text, text, integer, boolean, boolean, text),
  public.add_comment(text, uuid, text, uuid), public.feed_mix(uuid[], integer, integer), public.video_feed(timestamptz, integer, text) to authenticated;
