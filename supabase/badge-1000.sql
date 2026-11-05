-- Nooxel World — Règles de visibilité, de publication et de badge (comptes commerce et indépendant)
-- À coller dans Supabase → SQL Editor → Run, APRÈS closure-and-video-filter.sql et admin-dashboard.sql. Peut être relancé sans danger.
--
-- Règles (comptes commerce / indépendant ; les comptes personnels ne sont pas concernés) :
--   • Sans vérification (SIRET contrôlé puis validé, ou validation manuelle) : rien n'est publiable, le compte est invisible
--     (carte, recherche, fils, vidéos, suggestions) et reste accessible à son seul propriétaire. [déjà imposé par la base : inchangé]
--   • Vérification validée : visible partout et publication possible, SANS badge.
--   • Badge : uniquement à partir de 1000 abonnés. Il ne donne ni visibilité ni droit de publier : la vérification reste obligatoire.

create or replace function public.badge_threshold()
returns integer
language sql immutable
as $$ select 1000; $$;

-- Page publique d'un commerce : le badge dépend des abonnés, la vérification reste exposée séparément ('verified')
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
    'verified', m.verification = 'verified', 'badge', case when m.follower_count >= public.badge_threshold() then 'compte certifié' end, 'has_badge', m.follower_count >= public.badge_threshold(), 'badge_threshold', public.badge_threshold(),
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

-- Vitrine publique (carte, recherche) : seuls les comptes vérifiés y figurent ; le badge dépend des abonnés
create or replace view public.public_merchants as
select
  id,
  business_name,
  description,
  case when follower_count >= public.badge_threshold() then 'compte certifié' else null end as badge,
  verification = 'verified' as can_receive_reviews,
  case verification when 'verified' then 1 else 0 end as visibility_rank,
  case when verification = 'verified' then social_url end as social_url,
  address, lat, lng, follower_count,
  profile_kind, zone_label, zone_lat, zone_lng, zone_radius_km
from public.merchant_profiles
where verification = 'verified';

-- Fil d'actualité : le badge n'apparaît que pour les comptes à 1000 abonnés
create or replace function public.my_feed(p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'body', x.body, 'image_path', x.image_path, 'created_at', x.created_at,
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'logo_path', x.logo_path,
             'has_badge', x.follower_count >= public.badge_threshold(),
             'like_count', x.like_count, 'liked', exists (select 1 from public.post_likes l where l.post_id = x.id and l.user_id = auth.uid()))
             order by x.created_at desc, x.id desc)
    from (select p.*, m.business_name, m.logo_path, m.follower_count from public.follows f
            join public.merchant_posts p on p.merchant_id = f.merchant_id
            join public.merchant_profiles m on m.id = p.merchant_id and m.verification = 'verified'
           where f.user_id = auth.uid() and (p_before is null or p.created_at < p_before)
           order by p.created_at desc, p.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- Back-office : statut de vérification, abonnés et badge de chaque compte commerce / indépendant
create or replace function public.admin_list_merchants(p_query text default null)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
begin
  perform public.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'business_name', m.business_name, 'siret', m.siret, 'verification', m.verification,
      'verified_at', m.verified_at, 'owner_email', u.email, 'created_at', m.created_at, 'kind', m.profile_kind,
      'follower_count', m.follower_count, 'badge_threshold', public.badge_threshold(),
      'badge_reached', m.follower_count >= public.badge_threshold(),
      'visible', m.verification = 'verified')
      order by m.created_at desc)
    from (select * from public.merchant_profiles mm
           where p_query is null or trim(p_query) = ''
              or mm.business_name ilike '%' || trim(p_query) || '%' or mm.siret = trim(p_query)
              or mm.owner_id in (select id from auth.users where email ilike '%' || trim(p_query) || '%')
           order by mm.created_at desc limit 200) m
    join auth.users u on u.id = m.owner_id), '[]'::jsonb);
end;
$$;

revoke all on function public.badge_threshold(), public.get_merchant_page(uuid), public.my_feed(timestamptz, integer), public.admin_list_merchants(text) from public, anon, authenticated;
grant execute on function public.badge_threshold(), public.get_merchant_page(uuid), public.my_feed(timestamptz, integer), public.admin_list_merchants(text) to authenticated;
