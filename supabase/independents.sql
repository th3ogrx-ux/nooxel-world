-- ============================================================================
-- Nooxel World — PHASE 2, ÉTAPE 2 : indépendants et commerces itinérants (sans boutique fixe).
-- À coller dans Supabase → SQL Editor → Run, APRÈS commerce-pages.sql. Peut être relancé sans danger.
--
-- Règles :
--   • Un profil « mobile » n'a PAS d'adresse : il a une zone d'intervention (point approximatif + rayon).
--   • Le point est arrondi par la base elle-même (~1 km) : même un navigateur modifié ne peut pas enregistrer
--     une position précise (adresse personnelle). Rayon : de 2 à 100 km.
--   • Planning de passage (food trucks, marchés…) : lieu + créneau, géré par le commerçant lui-même ;
--     les créneaux terminés depuis plus de 7 jours sont effacés automatiquement.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Type de profil et zone d'intervention
-- ---------------------------------------------------------------------------
alter table public.merchant_profiles
  add column if not exists profile_kind text not null default 'shop',
  add column if not exists zone_label text,
  add column if not exists zone_lat double precision,
  add column if not exists zone_lng double precision,
  add column if not exists zone_radius_km integer;

alter table public.merchant_profiles drop constraint if exists mp_kind_check;
alter table public.merchant_profiles add constraint mp_kind_check check (profile_kind in ('shop', 'mobile'));
alter table public.merchant_profiles drop constraint if exists mp_zone_label_len;
alter table public.merchant_profiles add constraint mp_zone_label_len check (zone_label is null or char_length(zone_label) between 2 and 100);
alter table public.merchant_profiles drop constraint if exists mp_zone_range;
alter table public.merchant_profiles add constraint mp_zone_range check (
  (zone_lat is null) = (zone_lng is null) and (zone_lat is null) = (zone_radius_km is null)
  and (zone_lat is null or (zone_lat between -90 and 90 and zone_lng between -180 and 180 and zone_radius_km between 2 and 100)));
-- une boutique a une adresse, un indépendant une zone : jamais les deux
alter table public.merchant_profiles drop constraint if exists mp_kind_fields;
alter table public.merchant_profiles add constraint mp_kind_fields check (
  (profile_kind = 'shop' and zone_lat is null and zone_label is null)
  or (profile_kind = 'mobile' and address is null and lat is null));

-- Position de la zone arrondie à 0,01° (~1 km) PAR LA BASE.
create or replace function public.round_zone()
returns trigger language plpgsql as $$
begin
  if new.zone_lat is not null then
    new.zone_lat := round(new.zone_lat::numeric, 2)::double precision;
    new.zone_lng := round(new.zone_lng::numeric, 2)::double precision;
  end if;
  return new;
end;
$$;
drop trigger if exists merchant_profiles_round_zone on public.merchant_profiles;
create trigger merchant_profiles_round_zone before insert or update on public.merchant_profiles
  for each row execute function public.round_zone();

grant insert (profile_kind) on public.merchant_profiles to authenticated;
grant update (profile_kind, zone_label, zone_lat, zone_lng, zone_radius_km) on public.merchant_profiles to authenticated;
create index if not exists mp_zone_idx on public.merchant_profiles (zone_lat, zone_lng) where verification = 'verified' and zone_lat is not null;

create or replace view public.public_merchants as
select
  id,
  business_name,
  description,
  case verification when 'verified' then 'professionnel vérifié' else null end as badge,
  verification = 'verified' as can_receive_reviews,
  case verification when 'verified' then 1 else 0 end as visibility_rank,
  case when verification = 'verified' then social_url end as social_url,
  address, lat, lng, follower_count,
  profile_kind, zone_label, zone_lat, zone_lng, zone_radius_km
from public.merchant_profiles
where verification = 'verified';
revoke all on public.public_merchants from anon;
grant select on public.public_merchants to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Planning de passage
-- ---------------------------------------------------------------------------
create table if not exists public.merchant_schedule (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchant_profiles(id) on delete cascade,
  place       text not null check (char_length(btrim(place)) between 2 and 120),
  lat         double precision,
  lng         double precision,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  note        text check (note is null or char_length(note) <= 200),
  created_at  timestamptz not null default now(),
  constraint sched_order check (ends_at > starts_at and ends_at - starts_at <= interval '24 hours'),
  constraint sched_geo check ((lat is null) = (lng is null) and (lat is null or (lat between -90 and 90 and lng between -180 and 180)))
);
create index if not exists sched_by_merchant on public.merchant_schedule (merchant_id, starts_at);
alter table public.merchant_schedule enable row level security;
revoke all on public.merchant_schedule from anon, authenticated;

create or replace function public.add_schedule_slot(
  p_place text, p_lat double precision, p_lng double precision, p_starts timestamptz, p_ends timestamptz, p_note text default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare m public.merchant_profiles; v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where owner_id = auth.uid() for update;
  if not found then raise exception 'no_profile'; end if;
  if m.verification <> 'verified' then raise exception 'not_verified'; end if;
  if m.profile_kind <> 'mobile' then raise exception 'not_mobile'; end if;
  if char_length(btrim(coalesce(p_place, ''))) < 2 or char_length(btrim(p_place)) > 120 then raise exception 'invalid_place'; end if;
  if p_starts is null or p_ends is null or p_ends <= p_starts or p_ends - p_starts > interval '24 hours' then raise exception 'invalid_slot'; end if;
  if p_starts < now() - interval '1 hour' or p_starts > now() + interval '90 days' then raise exception 'slot_out_of_range'; end if;
  if (select count(*) from public.merchant_schedule where merchant_id = m.id and ends_at >= now()) >= 30 then raise exception 'too_many_slots'; end if;
  insert into public.merchant_schedule (merchant_id, place, lat, lng, starts_at, ends_at, note)
  values (m.id, btrim(p_place), p_lat, p_lng, p_starts, p_ends, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.delete_schedule_slot(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.merchant_schedule s using public.merchant_profiles m
   where s.id = p_id and m.id = s.merchant_id and m.owner_id = auth.uid();
  if not found then raise exception 'not_found'; end if;
end;
$$;

-- Passages en cours ou à venir (les plus proches d'abord).
create or replace function public.list_schedule(p_merchant uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'place', x.place, 'lat', x.lat, 'lng', x.lng,
             'starts_at', x.starts_at, 'ends_at', x.ends_at, 'note', x.note, 'now', x.starts_at <= now() and x.ends_at >= now())
             order by x.starts_at, x.id)
    from (select s.* from public.merchant_schedule s join public.merchant_profiles m on m.id = s.merchant_id
           where s.merchant_id = p_merchant and s.ends_at >= now() and (m.verification = 'verified' or m.owner_id = auth.uid())
           order by s.starts_at, s.id limit 30) x), '[]'::jsonb);
end;
$$;

-- Nettoyage quotidien : créneaux terminés depuis plus de 7 jours.
create or replace function public.purge_old_schedule()
returns integer
language plpgsql security definer set search_path = public
as $$
declare v_n integer;
begin
  delete from public.merchant_schedule where ends_at < now() - interval '7 days';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Fonctions mises à jour (page, recherche, carte)
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
    'follower_count', m.follower_count,
    'is_owner', m.owner_id = auth.uid(),
    'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = m.id));
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
             'kind', x.profile_kind, 'zone_label', x.zone_label, 'zone_radius_km', x.zone_radius_km)
             order by x.follower_count desc, x.business_name)
    from (select * from public.merchant_profiles
           where verification = 'verified' and business_name ilike '%' || v_q || '%'
           order by follower_count desc, business_name limit least(greatest(coalesce(p_limit, 6), 1), 20)) x), '[]'::jsonb);
end;
$$;

create or replace function public.merchants_in_view(p_south double precision, p_west double precision, p_north double precision, p_east double precision)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_north - p_south > 5 or abs(p_east - p_west) > 8 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'business_name', x.business_name, 'lat', x.plat, 'lng', x.plng,
             'address', x.address, 'kind', x.profile_kind, 'zone_label', x.zone_label, 'zone_radius_km', x.zone_radius_km))
    from (select id, business_name, address, profile_kind, zone_label, zone_radius_km,
                 coalesce(lat, zone_lat) as plat, coalesce(lng, zone_lng) as plng, follower_count
            from public.merchant_profiles
           where verification = 'verified' and coalesce(lat, zone_lat) between p_south and p_north
             and case when p_west <= p_east then coalesce(lng, zone_lng) between p_west and p_east
                      else (coalesce(lng, zone_lng) >= p_west or coalesce(lng, zone_lng) <= p_east) end
           order by follower_count desc limit 150) x), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Droits d'exécution
-- ---------------------------------------------------------------------------
revoke all on function public.round_zone(),
  public.add_schedule_slot(text, double precision, double precision, timestamptz, timestamptz, text),
  public.delete_schedule_slot(uuid), public.list_schedule(uuid), public.purge_old_schedule()
from public, anon, authenticated;
grant execute on function
  public.add_schedule_slot(text, double precision, double precision, timestamptz, timestamptz, text),
  public.delete_schedule_slot(uuid), public.list_schedule(uuid)
to authenticated;
grant execute on function public.purge_old_schedule() to service_role;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('purge-old-schedule', '41 3 * * *', 'select public.purge_old_schedule();');
  end if;
end $$;
