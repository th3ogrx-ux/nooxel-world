-- ============================================================================
-- Nooxel World — PHASE 3 : 37 métiers (une icône par métier sur la carte), catégories élargies.
-- À coller dans Supabase → SQL Editor → Run, APRÈS account-edit.sql. Peut être relancé sans danger.
-- Les anciennes catégories (pâtisserie, santé, artisan, services, loisirs, hébergement) restent valables.
-- La carte et la recherche renvoient désormais la catégorie de chaque commerce, pour dessiner la bonne icône.
-- ============================================================================
alter table public.merchant_profiles drop constraint if exists mp_category;
alter table public.merchant_profiles add constraint mp_category check (category is null or category in (
  'restaurant', 'cafe', 'bar', 'boulangerie', 'fleuriste', 'boucherie', 'epicerie', 'coiffeur', 'beaute', 'barbier', 'pharmacie', 'opticien',
  'sport_salle', 'coach', 'vetements', 'chaussures', 'bijouterie', 'librairie', 'magasin_sport', 'animalerie', 'garage', 'lavage_auto',
  'plombier', 'electricien', 'menuisier', 'peintre', 'photographe', 'professeur', 'traiteur', 'hotel', 'immobilier', 'avocat',
  'veterinaire', 'dentiste', 'medecin', 'kine', 'autre',
  'patisserie', 'sante', 'artisan', 'services', 'loisirs', 'hebergement'));

create or replace function public.merchants_in_view(p_south double precision, p_west double precision, p_north double precision, p_east double precision)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_north - p_south > 5 or abs(p_east - p_west) > 8 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'business_name', x.business_name, 'lat', x.plat, 'lng', x.plng,
             'address', x.address, 'kind', x.profile_kind, 'zone_label', x.zone_label, 'zone_radius_km', x.zone_radius_km, 'category', x.category))
    from (select id, business_name, address, profile_kind, zone_label, zone_radius_km, category,
                 coalesce(lat, zone_lat) as plat, coalesce(lng, zone_lng) as plng, follower_count
            from public.merchant_profiles
           where verification = 'verified' and coalesce(lat, zone_lat) between p_south and p_north
             and case when p_west <= p_east then coalesce(lng, zone_lng) between p_west and p_east
                      else (coalesce(lng, zone_lng) >= p_west or coalesce(lng, zone_lng) <= p_east) end
           order by follower_count desc limit 150) x), '[]'::jsonb);
end;
$$;

create or replace function public.search_merchants(p_query text, p_limit integer default 6)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_q text := btrim(coalesce(p_query, ''));
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if char_length(v_q) < 2 then return '[]'::jsonb; end if;
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'business_name', x.business_name, 'address', x.address,
             'lat', coalesce(x.lat, x.zone_lat), 'lng', coalesce(x.lng, x.zone_lng), 'follower_count', x.follower_count,
             'kind', x.profile_kind, 'zone_label', x.zone_label, 'zone_radius_km', x.zone_radius_km, 'category', x.category)
             order by x.follower_count desc, x.business_name)
    from (select * from public.merchant_profiles
           where verification = 'verified' and business_name ilike '%' || v_q || '%'
           order by follower_count desc, business_name limit least(greatest(coalesce(p_limit, 6), 1), 20)) x), '[]'::jsonb);
end;
$$;

revoke all on function public.merchants_in_view(double precision, double precision, double precision, double precision), public.search_merchants(text, integer) from public, anon, authenticated;
grant execute on function public.merchants_in_view(double precision, double precision, double precision, double precision), public.search_merchants(text, integer) to authenticated;
