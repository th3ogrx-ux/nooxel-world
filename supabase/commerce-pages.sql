-- ============================================================================
-- Nooxel World — PHASE 2, ÉTAPE 1 : pages commerçants (posts, abonnés, fil d'actualité, recherche, carte).
-- À coller dans Supabase → SQL Editor → Run, APRÈS merchant-manual-review.sql. Peut être relancé sans danger.
--
-- Règles :
--   • Seuls les commerçants VÉRIFIÉS ont une page visible et peuvent publier.
--   • Le navigateur ne peut ni écrire ni compter lui-même : posts, abonnements et compteurs passent par des
--     fonctions serveur qui vérifient l'identité de l'appelant (auth.uid()).
--   • Tout est réservé aux comptes connectés (aucun accès anonyme).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Profil : adresse du commerce + position sur la carte + compteur d'abonnés
-- ---------------------------------------------------------------------------
alter table public.merchant_profiles
  add column if not exists address text,
  add column if not exists lat double precision,
  add column if not exists lng double precision,
  add column if not exists follower_count integer not null default 0;

alter table public.merchant_profiles drop constraint if exists mp_address_len;
alter table public.merchant_profiles add constraint mp_address_len check (address is null or char_length(address) <= 200);
alter table public.merchant_profiles drop constraint if exists mp_geo_range;
alter table public.merchant_profiles add constraint mp_geo_range
  check ((lat is null) = (lng is null) and (lat is null or (lat between -90 and 90 and lng between -180 and 180)));
alter table public.merchant_profiles drop constraint if exists mp_followers_nonneg;
alter table public.merchant_profiles add constraint mp_followers_nonneg check (follower_count >= 0);

-- Le propriétaire peut modifier son adresse et sa position ; JAMAIS le compteur d'abonnés.
grant update (address, lat, lng) on public.merchant_profiles to authenticated;
create index if not exists mp_geo_idx on public.merchant_profiles (lat, lng) where verification = 'verified' and lat is not null;

-- La vitrine ne montre plus que les commerçants vérifiés, et seulement aux comptes connectés.
create or replace view public.public_merchants as
select
  id,
  business_name,
  description,
  case verification when 'verified' then 'professionnel vérifié' else null end as badge,
  verification = 'verified' as can_receive_reviews,
  case verification when 'verified' then 1 else 0 end as visibility_rank,
  case when verification = 'verified' then social_url end as social_url,
  address, lat, lng, follower_count
from public.merchant_profiles
where verification = 'verified';
revoke all on public.public_merchants from anon;
grant select on public.public_merchants to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Posts, abonnements
-- ---------------------------------------------------------------------------
create table if not exists public.merchant_posts (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchant_profiles(id) on delete cascade,
  body        text not null check (char_length(btrim(body)) between 1 and 2000),
  image_path  text check (image_path is null or image_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(webp|jpg)$'),
  created_at  timestamptz not null default now()
);
create index if not exists posts_by_merchant on public.merchant_posts (merchant_id, created_at desc);
create unique index if not exists posts_unique_image on public.merchant_posts (image_path) where image_path is not null;
alter table public.merchant_posts enable row level security;
revoke all on public.merchant_posts from anon, authenticated;     -- aucune lecture ni écriture directe : tout passe par les fonctions

create table if not exists public.follows (
  user_id     uuid not null references auth.users(id) on delete cascade,
  merchant_id uuid not null references public.merchant_profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, merchant_id)
);
create index if not exists follows_by_merchant on public.follows (merchant_id);
alter table public.follows enable row level security;
revoke all on public.follows from anon, authenticated;

-- Compteur d'abonnés tenu à jour par la base (jamais par le navigateur), y compris à la suppression d'un compte.
create or replace function public.follows_count_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.merchant_profiles set follower_count = follower_count + 1 where id = new.merchant_id;
  else
    update public.merchant_profiles set follower_count = greatest(follower_count - 1, 0) where id = old.merchant_id;
  end if;
  return null;
end;
$$;
drop trigger if exists follows_count on public.follows;
create trigger follows_count after insert or delete on public.follows
  for each row execute function public.follows_count_sync();

-- ---------------------------------------------------------------------------
-- 3. Stockage des photos de posts (public en lecture : ce sont des publications publiques)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('merchant-media', 'merchant-media', true, 2097152, array['image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- « Ce dossier est-il l'identifiant d'un commerce vérifié dont je suis le propriétaire ? »
create or replace function public.owns_verified_folder(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.merchant_profiles
                  where id::text = p_folder and owner_id = auth.uid() and verification = 'verified');
$$;
create or replace function public.owns_folder(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.merchant_profiles where id::text = p_folder and owner_id = auth.uid());
$$;
revoke all on function public.owns_verified_folder(text), public.owns_folder(text) from public, anon;
grant execute on function public.owns_verified_folder(text), public.owns_folder(text) to authenticated;

drop policy if exists mm_owner_insert on storage.objects;
create policy mm_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'merchant-media' and public.owns_verified_folder((storage.foldername(name))[1]));
drop policy if exists mm_owner_delete on storage.objects;
create policy mm_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'merchant-media' and public.owns_folder((storage.foldername(name))[1]));
drop policy if exists mm_owner_select on storage.objects;
create policy mm_owner_select on storage.objects for select to authenticated
  using (bucket_id = 'merchant-media' and public.owns_folder((storage.foldername(name))[1]));

-- ---------------------------------------------------------------------------
-- 4. FONCTIONS (comptes connectés uniquement)
-- ---------------------------------------------------------------------------

-- Publier : propriétaire d'un commerce vérifié, photo (facultative) déjà envoyée dans SON dossier, 20 posts par jour au plus.
create or replace function public.create_post(p_body text, p_image_path text default null)
returns uuid
language plpgsql security definer set search_path = public, storage
as $$
declare m public.merchant_profiles; v_id uuid; v_body text := btrim(coalesce(p_body, '')); v_img text := nullif(btrim(coalesce(p_image_path, '')), '');
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where owner_id = auth.uid() for update;
  if not found then raise exception 'no_profile'; end if;
  if m.verification <> 'verified' then raise exception 'not_verified'; end if;
  if char_length(v_body) < 1 or char_length(v_body) > 2000 then raise exception 'invalid_body'; end if;
  if (select count(*) from public.merchant_posts where merchant_id = m.id and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'too_many_posts';
  end if;
  if v_img is not null then
    if left(v_img, 37) <> m.id::text || '/' then raise exception 'invalid_image'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'merchant-media' and name = v_img) then raise exception 'image_not_found'; end if;
  end if;
  insert into public.merchant_posts (merchant_id, body, image_path) values (m.id, v_body, v_img) returning id into v_id;
  return v_id;
end;
$$;

-- Supprimer SON post (le navigateur supprime ensuite le fichier de la photo).
create or replace function public.delete_post(p_post uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare v_img text;
begin
  delete from public.merchant_posts p using public.merchant_profiles m
   where p.id = p_post and m.id = p.merchant_id and m.owner_id = auth.uid()
  returning p.image_path into v_img;
  if not found then raise exception 'not_found'; end if;
  return v_img;
end;
$$;

create or replace function public.follow_merchant(p_merchant uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
declare m public.merchant_profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where id = p_merchant and verification = 'verified';
  if not found then raise exception 'not_found'; end if;
  if m.owner_id = auth.uid() then raise exception 'cannot_follow_self'; end if;
  insert into public.follows (user_id, merchant_id) values (auth.uid(), p_merchant) on conflict do nothing;
  return (select follower_count from public.merchant_profiles where id = p_merchant);
end;
$$;

create or replace function public.unfollow_merchant(p_merchant uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.follows where user_id = auth.uid() and merchant_id = p_merchant;
  return coalesce((select follower_count from public.merchant_profiles where id = p_merchant), 0);
end;
$$;

-- Fiche d'une page : visible si le commerce est vérifié, ou si c'est la sienne (aperçu).
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
    'address', m.address, 'lat', m.lat, 'lng', m.lng, 'follower_count', m.follower_count,
    'is_owner', m.owner_id = auth.uid(),
    'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = m.id));
end;
$$;

-- Posts d'une page, du plus récent au plus ancien, par pages (p_before = date du dernier post déjà reçu).
create or replace function public.list_merchant_posts(p_merchant uuid, p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'body', x.body, 'image_path', x.image_path, 'created_at', x.created_at)
                     order by x.created_at desc, x.id desc)
    from (select p.* from public.merchant_posts p join public.merchant_profiles m on m.id = p.merchant_id
           where p.merchant_id = p_merchant and (m.verification = 'verified' or m.owner_id = auth.uid())
             and (p_before is null or p.created_at < p_before)
           order by p.created_at desc, p.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- Fil d'actualité : posts des commerces suivis (et encore vérifiés), du plus récent au plus ancien.
create or replace function public.my_feed(p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'body', x.body, 'image_path', x.image_path, 'created_at', x.created_at,
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'badge', 'professionnel vérifié')
             order by x.created_at desc, x.id desc)
    from (select p.*, m.business_name from public.follows f
            join public.merchant_posts p on p.merchant_id = f.merchant_id
            join public.merchant_profiles m on m.id = p.merchant_id and m.verification = 'verified'
           where f.user_id = auth.uid() and (p_before is null or p.created_at < p_before)
           order by p.created_at desc, p.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- Recherche d'un commerce par nom (comptes connectés ; commerces vérifiés uniquement).
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
             'lat', x.lat, 'lng', x.lng, 'follower_count', x.follower_count) order by x.follower_count desc, x.business_name)
    from (select * from public.merchant_profiles
           where verification = 'verified' and business_name ilike '%' || v_q || '%'
           order by follower_count desc, business_name limit least(greatest(coalesce(p_limit, 6), 1), 20)) x), '[]'::jsonb);
end;
$$;

-- Commerces visibles dans la zone affichée de la carte.
create or replace function public.merchants_in_view(p_south double precision, p_west double precision, p_north double precision, p_east double precision)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_north - p_south > 5 or abs(p_east - p_west) > 8 then return '[]'::jsonb; end if;     -- zone trop vaste : on n'affiche rien
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'business_name', x.business_name, 'lat', x.lat, 'lng', x.lng))
    from (select id, business_name, lat, lng from public.merchant_profiles
           where verification = 'verified' and lat between p_south and p_north
             and case when p_west <= p_east then lng between p_west and p_east else (lng >= p_west or lng <= p_east) end
           order by follower_count desc limit 150) x), '[]'::jsonb);
end;
$$;

-- Photos de posts sans publication depuis plus d'un jour (compte ou post supprimé, envoi abandonné) : la tâche
-- quotidienne « purge-documents » les supprime vraiment du stockage (droit à l'effacement).
create or replace function public.system_orphan_media()
returns setof text
language sql stable security definer set search_path = public, storage
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'merchant-media' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.merchant_posts p where p.image_path = o.name);
$$;
revoke all on function public.system_orphan_media() from public, anon, authenticated;
grant execute on function public.system_orphan_media() to service_role;

-- ---------------------------------------------------------------------------
-- 5. Droits d'exécution : connectés uniquement
-- ---------------------------------------------------------------------------
revoke all on function
  public.follows_count_sync(),
  public.create_post(text, text), public.delete_post(uuid), public.follow_merchant(uuid), public.unfollow_merchant(uuid),
  public.get_merchant_page(uuid), public.list_merchant_posts(uuid, timestamptz, integer), public.my_feed(timestamptz, integer),
  public.search_merchants(text, integer), public.merchants_in_view(double precision, double precision, double precision, double precision)
from public, anon, authenticated;
grant execute on function
  public.create_post(text, text), public.delete_post(uuid), public.follow_merchant(uuid), public.unfollow_merchant(uuid),
  public.get_merchant_page(uuid), public.list_merchant_posts(uuid, timestamptz, integer), public.my_feed(timestamptz, integer),
  public.search_merchants(text, integer), public.merchants_in_view(double precision, double precision, double precision, double precision)
to authenticated;
