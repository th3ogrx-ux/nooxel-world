-- Nooxel World — Fermeture exceptionnelle / vacances + filtre de l'onglet Vidéos
-- À coller dans Supabase → SQL Editor → Run, APRÈS account-pages.sql et likes.sql. Peut être relancé sans danger.

-- 1. Fermeture exceptionnelle (dates de début et de fin, ou « jusqu'à nouvel ordre »)
alter table public.merchant_profiles
  add column if not exists closure_from date,
  add column if not exists closure_until date,
  add column if not exists closure_indefinite boolean not null default false;

alter table public.merchant_profiles drop constraint if exists mp_closure_check;
alter table public.merchant_profiles add constraint mp_closure_check check (
  (closure_indefinite = false and closure_from is null and closure_until is null)
  or (closure_indefinite = true and closure_until is null)
  or (closure_indefinite = false and closure_from is not null and closure_until is not null
      and closure_from <= closure_until and closure_until - closure_from <= 365));

grant update (closure_from, closure_until, closure_indefinite) on public.merchant_profiles to authenticated;

-- 2. Fiche publique : ajoute « closure » (seulement si en cours ou à venir)
create or replace function public.get_merchant_page(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare m public.merchant_profiles; v_today date; v_closure jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where id = p_id;
  if not found or (m.verification <> 'verified' and m.owner_id <> auth.uid()) then raise exception 'not_found'; end if;
  v_today := (now() at time zone coalesce(m.timezone, 'Europe/Paris'))::date;
  if m.closure_indefinite then
    v_closure := jsonb_build_object('indefinite', true, 'from', null, 'until', null, 'active', true);
  elsif m.closure_until is not null and m.closure_until >= v_today then
    v_closure := jsonb_build_object('indefinite', false, 'from', m.closure_from, 'until', m.closure_until, 'active', m.closure_from <= v_today);
  end if;
  return jsonb_build_object(
    'id', m.id, 'business_name', m.business_name, 'description', m.description,
    'verified', m.verification = 'verified', 'badge', case when m.verification = 'verified' then 'professionnel vérifié' end,
    'social_url', case when m.verification = 'verified' then m.social_url end,
    'kind', m.profile_kind,
    'address', m.address, 'lat', coalesce(m.lat, m.zone_lat), 'lng', coalesce(m.lng, m.zone_lng),
    'zone_label', m.zone_label, 'zone_radius_km', m.zone_radius_km,
    'category', m.category, 'logo_path', m.logo_path, 'cover_path', m.cover_path, 'website', m.website,
    'contact_phone', m.contact_phone, 'opening_hours', m.opening_hours, 'timezone', m.timezone,
    'closure', v_closure,
    'follower_count', m.follower_count,
    'posts_count', (select count(*) from public.merchant_posts p where p.merchant_id = m.id),
    'review_count', m.review_count,
    'rating_avg', case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end,
    'is_owner', m.owner_id = auth.uid(),
    'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = m.id));
end;
$$;

-- 3. Fil de vidéos filtrable : p_kind = null (tout), 'mobile' (indépendants) ou 'shop' (boutiques)
drop function if exists public.video_feed(timestamptz, integer);
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
             'is_owner', x.owner_id = auth.uid())
             order by x.created_at desc, x.id desc)
    from (select v.*, m.business_name, m.logo_path, m.profile_kind, m.lat, m.lng, m.zone_lat, m.zone_lng, m.review_count, m.rating_sum, m.owner_id
            from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id and m.verification = 'verified'
           where (p_before is null or v.created_at < p_before) and (p_kind is null or m.profile_kind = p_kind)
           order by v.created_at desc, v.id desc limit least(greatest(coalesce(p_limit, 8), 1), 20)) x), '[]'::jsonb);
end;
$$;
revoke all on function public.video_feed(timestamptz, integer, text) from public, anon, authenticated;
grant execute on function public.video_feed(timestamptz, integer, text) to authenticated;
