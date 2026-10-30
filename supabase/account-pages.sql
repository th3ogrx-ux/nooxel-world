-- ============================================================================
-- Nooxel World — PHASE 3 : pages « Compte » (profil utilisateur) et page de commerce enrichie.
-- À coller dans Supabase → SQL Editor → Run, APRÈS videos.sql. Peut être relancé sans danger.
--
-- Ajoute pour un commerce : catégorie, logo, photo de couverture, site web, téléphone public (facultatif, distinct du téléphone
-- de vérification), horaires d'ouverture par jour et fuseau horaire. Tout est VIDE au départ : c'est le commerçant qui renseigne.
-- Ajoute pour un utilisateur : le résumé de son profil, la liste de ses avis et celle des commerces qu'il suit.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Informations d'un commerce
-- ---------------------------------------------------------------------------
create or replace function public.valid_opening_hours(h jsonb)
returns boolean
language plpgsql immutable
as $$
declare k text; slot jsonb; n integer;
begin
  if h is null then return true; end if;
  if jsonb_typeof(h) <> 'object' then return false; end if;
  for k in select jsonb_object_keys(h) loop
    if k not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun') then return false; end if;
    if jsonb_typeof(h -> k) <> 'array' then return false; end if;
    n := jsonb_array_length(h -> k);
    if n > 2 then return false; end if;
    for slot in select * from jsonb_array_elements(h -> k) loop
      if jsonb_typeof(slot) <> 'array' or jsonb_array_length(slot) <> 2 then return false; end if;
      if jsonb_typeof(slot -> 0) <> 'string' or jsonb_typeof(slot -> 1) <> 'string' then return false; end if;
      if (slot ->> 0) !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or (slot ->> 1) !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then return false; end if;
      if (slot ->> 0) >= (slot ->> 1) then return false; end if;
    end loop;
  end loop;
  return true;
end;
$$;

alter table public.merchant_profiles
  add column if not exists category text,
  add column if not exists logo_path text,
  add column if not exists cover_path text,
  add column if not exists website text,
  add column if not exists contact_phone text,
  add column if not exists opening_hours jsonb,
  add column if not exists timezone text not null default 'Europe/Paris';

alter table public.merchant_profiles drop constraint if exists mp_category;
alter table public.merchant_profiles add constraint mp_category check (category is null or category in
  ('restaurant', 'cafe', 'bar', 'boulangerie', 'patisserie', 'boucherie', 'epicerie', 'vetements', 'beaute', 'sante', 'artisan', 'services', 'loisirs', 'hebergement', 'autre'));
alter table public.merchant_profiles drop constraint if exists mp_website;
alter table public.merchant_profiles add constraint mp_website check (website is null or (website ~* '^https://[^\s]+$' and char_length(website) <= 200));
alter table public.merchant_profiles drop constraint if exists mp_contact_phone;
alter table public.merchant_profiles add constraint mp_contact_phone check (contact_phone is null or contact_phone ~ '^\+?[0-9]{8,15}$');
alter table public.merchant_profiles drop constraint if exists mp_logo;
alter table public.merchant_profiles add constraint mp_logo check (logo_path is null or (logo_path like id::text || '/%' and logo_path ~ '^[0-9a-f-]{36}/logo-[0-9a-f-]{36}\.jpg$'));
alter table public.merchant_profiles drop constraint if exists mp_cover;
alter table public.merchant_profiles add constraint mp_cover check (cover_path is null or (cover_path like id::text || '/%' and cover_path ~ '^[0-9a-f-]{36}/cover-[0-9a-f-]{36}\.jpg$'));
alter table public.merchant_profiles drop constraint if exists mp_hours;
alter table public.merchant_profiles add constraint mp_hours check (public.valid_opening_hours(opening_hours));
alter table public.merchant_profiles drop constraint if exists mp_timezone;
alter table public.merchant_profiles add constraint mp_timezone check (timezone in
  ('Europe/Paris', 'America/Martinique', 'America/Cayenne', 'Indian/Reunion', 'Indian/Mayotte', 'Pacific/Noumea', 'Pacific/Tahiti', 'Pacific/Wallis_and_Futuna', 'America/Miquelon'));

grant update (category, logo_path, cover_path, website, contact_phone, opening_hours, timezone) on public.merchant_profiles to authenticated;

-- Les images d'un commerce (logo, couverture) comptent comme « utilisées » : la tâche de nuit ne les efface pas.
create or replace function public.system_orphan_media()
returns setof text
language sql stable security definer set search_path = public, storage
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'merchant-media' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.merchant_posts p where p.image_path = o.name)
     and not exists (select 1 from public.merchant_videos v where v.poster_path = o.name)
     and not exists (select 1 from public.merchant_profiles m where m.logo_path = o.name or m.cover_path = o.name);
$$;

-- ---------------------------------------------------------------------------
-- 2. Fiche d'un commerce (page publique) : ajoute les nouvelles informations
-- ---------------------------------------------------------------------------
create or replace function public.get_merchant_page(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare m public.merchant_profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where id = p_id;
  if not found or (m.verification <> 'verified' and m.owner_id <> auth.uid()) then raise exception 'not_found'; end if;
  return jsonb_build_object(
    'id', m.id, 'business_name', m.business_name, 'description', m.description,
    'verified', m.verification = 'verified', 'badge', case when m.verification = 'verified' then 'professionnel vérifié' end,
    'social_url', case when m.verification = 'verified' then m.social_url end,
    'kind', m.profile_kind,
    'address', m.address, 'lat', coalesce(m.lat, m.zone_lat), 'lng', coalesce(m.lng, m.zone_lng),
    'zone_label', m.zone_label, 'zone_radius_km', m.zone_radius_km,
    'category', m.category, 'logo_path', m.logo_path, 'cover_path', m.cover_path, 'website', m.website,
    'contact_phone', m.contact_phone, 'opening_hours', m.opening_hours, 'timezone', m.timezone,
    'follower_count', m.follower_count,
    'posts_count', (select count(*) from public.merchant_posts p where p.merchant_id = m.id),
    'review_count', m.review_count,
    'rating_avg', case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end,
    'is_owner', m.owner_id = auth.uid(),
    'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = m.id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Profil utilisateur : résumé, mes avis, mes commerces suivis
-- ---------------------------------------------------------------------------
create or replace function public.my_profile_summary()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare v_reviews integer; v_follow integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select count(*) into v_reviews from public.reviews where user_id = auth.uid() and status = 'published';
  select count(*) into v_follow from public.follows f join public.merchant_profiles m on m.id = f.merchant_id
   where f.user_id = auth.uid() and m.verification = 'verified';
  return jsonb_build_object(
    'pseudo', (select pseudo from public.user_profiles where user_id = auth.uid()),
    'reviews_count', v_reviews, 'following_count', v_follow, 'points', 0,
    'active_contributor', v_reviews >= 3,
    'member_since', (select created_at from auth.users where id = auth.uid()),
    'can_change_pseudo', coalesce((select pseudo_changed_at <= now() - interval '30 days' from public.user_profiles where user_id = auth.uid()), true));
end;
$$;

create or replace function public.my_reviews(p_before timestamptz default null, p_limit integer default 10)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'rating', x.rating, 'body', x.body, 'created_at', x.created_at,
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'category', x.category, 'logo_path', x.logo_path,
             'rating_avg', x.rating_avg) order by x.created_at desc, x.id desc)
    from (select r.id, r.rating, r.body, r.created_at, r.merchant_id, m.business_name, m.category, m.logo_path,
                 case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end as rating_avg
            from public.reviews r join public.merchant_profiles m on m.id = r.merchant_id
           where r.user_id = auth.uid() and r.status = 'published' and m.verification = 'verified'
             and (p_before is null or r.created_at < p_before)
           order by r.created_at desc, r.id desc limit least(greatest(coalesce(p_limit, 10), 1), 30)) x), '[]'::jsonb);
end;
$$;

create or replace function public.my_following(p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('merchant_id', x.merchant_id, 'business_name', x.business_name, 'category', x.category,
             'logo_path', x.logo_path, 'cover_path', x.cover_path, 'rating_avg', x.rating_avg, 'review_count', x.review_count,
             'followed_at', x.followed_at) order by x.followed_at desc, x.merchant_id)
    from (select f.merchant_id, f.created_at as followed_at, m.business_name, m.category, m.logo_path, m.cover_path, m.review_count,
                 case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end as rating_avg
            from public.follows f join public.merchant_profiles m on m.id = f.merchant_id
           where f.user_id = auth.uid() and m.verification = 'verified' and (p_before is null or f.created_at < p_before)
           order by f.created_at desc, f.merchant_id limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Droits d'exécution
-- ---------------------------------------------------------------------------
revoke all on function public.valid_opening_hours(jsonb), public.my_profile_summary(), public.my_reviews(timestamptz, integer),
  public.my_following(timestamptz, integer), public.system_orphan_media() from public, anon, authenticated;
-- La règle des horaires est vérifiée au nom de la personne qui enregistre : elle doit pouvoir l'appeler (elle ne fait que vérifier un texte).
grant execute on function public.valid_opening_hours(jsonb) to authenticated;
grant execute on function public.my_profile_summary(), public.my_reviews(timestamptz, integer), public.my_following(timestamptz, integer) to authenticated;
grant execute on function public.system_orphan_media() to service_role;
