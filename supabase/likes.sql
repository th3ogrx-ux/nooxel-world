-- ============================================================================
-- Nooxel World — PHASE 3 : « J'aime » (♥) sur les publications et les vidéos, et fil de vidéos.
-- À coller dans Supabase → SQL Editor → Run, APRÈS profile-setup.sql. Peut être relancé sans danger.
--
-- • Un ♥ par personne et par élément ; personne ne voit qui a aimé (seul le nombre est public).
-- • 300 ♥ par 24 h et par personne au plus (anti-abus). Seuls les commerces VÉRIFIÉS peuvent être aimés.
-- • RGPD : les ♥ d'un compte supprimé disparaissent avec lui (et le compteur redescend).
-- • « video_feed » : toutes les vidéos des commerces vérifiés, de la plus récente à la plus ancienne.
-- ============================================================================

alter table public.merchant_posts add column if not exists like_count integer not null default 0;
alter table public.merchant_videos add column if not exists like_count integer not null default 0;
alter table public.merchant_posts drop constraint if exists posts_like_count_nonneg;
alter table public.merchant_posts add constraint posts_like_count_nonneg check (like_count >= 0);
alter table public.merchant_videos drop constraint if exists videos_like_count_nonneg;
alter table public.merchant_videos add constraint videos_like_count_nonneg check (like_count >= 0);

create table if not exists public.post_likes (
  user_id    uuid not null references auth.users(id) on delete cascade,
  post_id    uuid not null references public.merchant_posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);
create index if not exists post_likes_by_post on public.post_likes (post_id);
create table if not exists public.video_likes (
  user_id    uuid not null references auth.users(id) on delete cascade,
  video_id   uuid not null references public.merchant_videos(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);
create index if not exists video_likes_by_video on public.video_likes (video_id);
alter table public.post_likes enable row level security;
alter table public.video_likes enable row level security;
revoke all on public.post_likes, public.video_likes from anon, authenticated;

-- Compteurs tenus à jour par la base (jamais par le navigateur)
create or replace function public.post_likes_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update public.merchant_posts set like_count = like_count + 1 where id = new.post_id;
  else update public.merchant_posts set like_count = greatest(like_count - 1, 0) where id = old.post_id; end if;
  return null;
end $$;
drop trigger if exists post_likes_count on public.post_likes;
create trigger post_likes_count after insert or delete on public.post_likes for each row execute function public.post_likes_sync();
create or replace function public.video_likes_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update public.merchant_videos set like_count = like_count + 1 where id = new.video_id;
  else update public.merchant_videos set like_count = greatest(like_count - 1, 0) where id = old.video_id; end if;
  return null;
end $$;
drop trigger if exists video_likes_count on public.video_likes;
create trigger video_likes_count after insert or delete on public.video_likes for each row execute function public.video_likes_sync();

-- ---------------------------------------------------------------------------
-- ♥ / retirer le ♥ (renvoient le nouveau nombre)
-- ---------------------------------------------------------------------------
create or replace function public.like_post(p_post uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.merchant_posts p join public.merchant_profiles m on m.id = p.merchant_id where p.id = p_post and m.verification = 'verified') then raise exception 'not_found'; end if;
  if not exists (select 1 from public.post_likes where user_id = auth.uid() and post_id = p_post) then
    if (select count(*) from public.post_likes where user_id = auth.uid() and created_at > now() - interval '24 hours')
     + (select count(*) from public.video_likes where user_id = auth.uid() and created_at > now() - interval '24 hours') >= 300 then raise exception 'too_many_likes'; end if;
    insert into public.post_likes (user_id, post_id) values (auth.uid(), p_post) on conflict do nothing;
  end if;
  return (select like_count from public.merchant_posts where id = p_post);
end;
$$;
create or replace function public.unlike_post(p_post uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.post_likes where user_id = auth.uid() and post_id = p_post;
  return coalesce((select like_count from public.merchant_posts where id = p_post), 0);
end;
$$;
create or replace function public.like_video(p_video uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id where v.id = p_video and m.verification = 'verified') then raise exception 'not_found'; end if;
  if not exists (select 1 from public.video_likes where user_id = auth.uid() and video_id = p_video) then
    if (select count(*) from public.post_likes where user_id = auth.uid() and created_at > now() - interval '24 hours')
     + (select count(*) from public.video_likes where user_id = auth.uid() and created_at > now() - interval '24 hours') >= 300 then raise exception 'too_many_likes'; end if;
    insert into public.video_likes (user_id, video_id) values (auth.uid(), p_video) on conflict do nothing;
  end if;
  return (select like_count from public.merchant_videos where id = p_video);
end;
$$;
create or replace function public.unlike_video(p_video uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.video_likes where user_id = auth.uid() and video_id = p_video;
  return coalesce((select like_count from public.merchant_videos where id = p_video), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- Listes : on ajoute le nombre de ♥ et « ai-je aimé ? »
-- ---------------------------------------------------------------------------
create or replace function public.list_merchant_posts(p_merchant uuid, p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'body', x.body, 'image_path', x.image_path, 'created_at', x.created_at,
             'like_count', x.like_count, 'liked', exists (select 1 from public.post_likes l where l.post_id = x.id and l.user_id = auth.uid()))
             order by x.created_at desc, x.id desc)
    from (select p.* from public.merchant_posts p join public.merchant_profiles m on m.id = p.merchant_id
           where p.merchant_id = p_merchant and (m.verification = 'verified' or m.owner_id = auth.uid())
             and (p_before is null or p.created_at < p_before)
           order by p.created_at desc, p.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

create or replace function public.my_feed(p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'body', x.body, 'image_path', x.image_path, 'created_at', x.created_at,
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'logo_path', x.logo_path, 'badge', 'professionnel vérifié',
             'like_count', x.like_count, 'liked', exists (select 1 from public.post_likes l where l.post_id = x.id and l.user_id = auth.uid()))
             order by x.created_at desc, x.id desc)
    from (select p.*, m.business_name, m.logo_path from public.follows f
            join public.merchant_posts p on p.merchant_id = f.merchant_id
            join public.merchant_profiles m on m.id = p.merchant_id and m.verification = 'verified'
           where f.user_id = auth.uid() and (p_before is null or p.created_at < p_before)
           order by p.created_at desc, p.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

create or replace function public.list_merchant_videos(p_merchant uuid, p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'caption', x.caption, 'video_path', x.video_path, 'poster_path', x.poster_path,
             'duration_s', x.duration_s, 'created_at', x.created_at,
             'like_count', x.like_count, 'liked', exists (select 1 from public.video_likes l where l.video_id = x.id and l.user_id = auth.uid()))
             order by x.created_at desc, x.id desc)
    from (select v.* from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id
           where v.merchant_id = p_merchant and (m.verification = 'verified' or m.owner_id = auth.uid())
             and (p_before is null or v.created_at < p_before)
           order by v.created_at desc, v.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- Fil de vidéos : toutes les vidéos des commerces vérifiés, avec le commerce (nom, logo, note, position pour « À x km »)
create or replace function public.video_feed(p_before timestamptz default null, p_limit integer default 8)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'caption', x.caption, 'video_path', x.video_path, 'poster_path', x.poster_path,
             'duration_s', x.duration_s, 'created_at', x.created_at, 'like_count', x.like_count,
             'liked', exists (select 1 from public.video_likes l where l.video_id = x.id and l.user_id = auth.uid()),
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'logo_path', x.logo_path, 'kind', x.profile_kind,
             'lat', coalesce(x.lat, x.zone_lat), 'lng', coalesce(x.lng, x.zone_lng),
             'review_count', x.review_count, 'rating_avg', case when x.review_count > 0 then round(x.rating_sum::numeric / x.review_count, 1) end,
             'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = x.merchant_id),
             'is_owner', x.owner_id = auth.uid())
             order by x.created_at desc, x.id desc)
    from (select v.*, m.business_name, m.logo_path, m.profile_kind, m.lat, m.lng, m.zone_lat, m.zone_lng, m.review_count, m.rating_sum, m.owner_id
            from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id and m.verification = 'verified'
           where p_before is null or v.created_at < p_before
           order by v.created_at desc, v.id desc limit least(greatest(coalesce(p_limit, 8), 1), 20)) x), '[]'::jsonb);
end;
$$;

revoke all on function public.post_likes_sync(), public.video_likes_sync(), public.like_post(uuid), public.unlike_post(uuid), public.like_video(uuid), public.unlike_video(uuid),
  public.list_merchant_posts(uuid, timestamptz, integer), public.my_feed(timestamptz, integer), public.list_merchant_videos(uuid, timestamptz, integer),
  public.video_feed(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.like_post(uuid), public.unlike_post(uuid), public.like_video(uuid), public.unlike_video(uuid),
  public.list_merchant_posts(uuid, timestamptz, integer), public.my_feed(timestamptz, integer), public.list_merchant_videos(uuid, timestamptz, integer),
  public.video_feed(timestamptz, integer) to authenticated;
