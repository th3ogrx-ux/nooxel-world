-- ============================================================================
-- Nooxel World — PHASE 2, ÉTAPE 3 : avis fiables (pseudo public, note + texte, réponse du commerçant).
-- À coller dans Supabase → SQL Editor → Run, APRÈS independents.sql. Peut être relancé sans danger.
--
-- Règles imposées PAR LA BASE (pas seulement par la page) :
--   • Un compte = UN avis par commerce (contrainte unique) ; on peut le modifier ou le supprimer, pas le multiplier.
--   • Avis refusé avant publication s'il est trop court, ne contient que des insultes, contient un lien /
--     email / numéro de téléphone, ou n'est qu'un texte répété. Le message explique pourquoi.
--   • Pas d'avis sur sa propre page, ni sur un commerce non vérifié, ni avec un email non confirmé,
--     ni avec un compte créé depuis moins d'une heure ; 5 nouveaux avis par jour au maximum.
--   • Seul le propriétaire du commerce peut répondre (une réponse par avis, publique).
--   • « Preuve de passage » : simple case déclarative pour l'instant, affichée comme telle (non vérifiée).
--   • Le pseudo public est affiché à la place de l'email (jamais l'email).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Pseudo public
-- ---------------------------------------------------------------------------
create table if not exists public.user_profiles (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  pseudo            text not null check (pseudo ~ '^[A-Za-z0-9][A-Za-z0-9._-]{2,19}$'),
  pseudo_changed_at timestamptz not null default now(),
  created_at        timestamptz not null default now()
);
create unique index if not exists user_profiles_pseudo_ci on public.user_profiles (lower(pseudo));
alter table public.user_profiles enable row level security;
revoke all on public.user_profiles from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Avis
-- ---------------------------------------------------------------------------
alter table public.merchant_profiles
  add column if not exists review_count integer not null default 0,
  add column if not exists rating_sum integer not null default 0;
alter table public.merchant_profiles drop constraint if exists mp_reviews_nonneg;
alter table public.merchant_profiles add constraint mp_reviews_nonneg check (review_count >= 0 and rating_sum >= 0);

create table if not exists public.reviews (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchant_profiles(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  rating      smallint not null check (rating between 1 and 5),
  body        text not null check (char_length(btrim(body)) between 20 and 2000),
  visited     boolean not null default false,
  status      text not null default 'published' check (status in ('published', 'hidden')),
  reply_body  text check (reply_body is null or char_length(btrim(reply_body)) between 5 and 1000),
  reply_at    timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint one_review_per_user_and_merchant unique (merchant_id, user_id)
);
create index if not exists reviews_by_merchant on public.reviews (merchant_id, created_at desc) where status = 'published';
create index if not exists reviews_by_user on public.reviews (user_id, created_at desc);
alter table public.reviews enable row level security;
revoke all on public.reviews from anon, authenticated;

-- Moyenne et nombre d'avis tenus à jour par la base.
create or replace function public.reviews_stats_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare dc integer := 0; ds integer := 0;
begin
  if tg_op in ('UPDATE', 'DELETE') and old.status = 'published' then dc := dc - 1; ds := ds - old.rating; end if;
  if tg_op in ('INSERT', 'UPDATE') and new.status = 'published' then dc := dc + 1; ds := ds + new.rating; end if;
  if dc <> 0 or ds <> 0 then
    update public.merchant_profiles
       set review_count = greatest(review_count + dc, 0), rating_sum = greatest(rating_sum + ds, 0)
     where id = coalesce(new.merchant_id, old.merchant_id);
  end if;
  return null;
end;
$$;
drop trigger if exists reviews_stats on public.reviews;
create trigger reviews_stats after insert or update or delete on public.reviews
  for each row execute function public.reviews_stats_sync();

-- ---------------------------------------------------------------------------
-- 3. Filtre automatique (texte d'avis, de réponse, pseudo)
-- ---------------------------------------------------------------------------
create or replace function public.normalize_fr(p text)
returns text language sql immutable as $$
  select lower(translate(coalesce(p, ''), 'àâäáãåéèêëíìîïóòôöõúùûüçñœæÀÂÄÁÃÅÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÇÑŒÆ', 'aaaaaaeeeeiiiiooooouuuucnoaAAAAAAEEEEIIIIOOOOOUUUUCNOA'));
$$;

-- Liste de gros mots (formes normalisées, sans accent). Elle réduit les abus, elle ne les supprime pas :
-- le bouton « Signaler » complète le dispositif.
create or replace function public.insult_words()
returns text[] language sql immutable as $$
  select array['con','conne','connard','connasse','conard','connerie','salaud','salop','salope','saloperie','pute','putain','merde',
    'merdique','encule','enculer','enculee','batard','bastard','fdp','ntm','tg','pd','pede','ordure','abruti','debile','crevard',
    'cretin','imbecile','idiot','bouffon','charogne','trouduc','petasse','racaille','gouine','tapette','nique','niquer','foutre','chier'];
$$;

-- Renvoie NULL si le texte est acceptable, sinon le motif du refus.
create or replace function public.review_text_issue(p_text text, p_min_chars integer default 20)
returns text
language plpgsql immutable
as $$
declare
  t text := public.normalize_fr(btrim(coalesce(p_text, '')));
  letters text := regexp_replace(t, '[^a-z]', '', 'g');
  good integer;
begin
  if char_length(btrim(coalesce(p_text, ''))) < p_min_chars or char_length(letters) < least(p_min_chars, 12) then return 'too_short'; end if;
  if t ~ '(https?://|www\.|@[a-z0-9._-]+\.[a-z]{2,}|[a-z0-9]\.(com|fr|net|org|io)(/|\s|$))' or t ~ '(\d[ .-]?){9,}' then return 'contains_link'; end if;
  if t ~ '(.)\1{7,}' or (select count(distinct c) from regexp_split_to_table(letters, '') c) < 5 then return 'gibberish'; end if;
  select coalesce(sum(char_length(w)), 0) into good
    from regexp_split_to_table(t, '[^a-z]+') w
   where w <> '' and not (regexp_replace(w, 's$', '') = any (public.insult_words()) or w = any (public.insult_words()));
  if good < least(p_min_chars, 12) then return 'only_insults'; end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Fonctions (comptes connectés uniquement)
-- ---------------------------------------------------------------------------
create or replace function public.set_pseudo(p_pseudo text)
returns text
language plpgsql security definer set search_path = public
as $$
declare v text := btrim(coalesce(p_pseudo, '')); cur public.user_profiles; n text := public.normalize_fr(btrim(coalesce(p_pseudo, ''))); w text;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if v !~ '^[A-Za-z0-9][A-Za-z0-9._-]{2,19}$' then raise exception 'invalid_pseudo'; end if;
  if n = any (array['admin','administrateur','nooxel','nooxelworld','support','moderation','moderateur','officiel','equipe','null','undefined']) then raise exception 'reserved_pseudo'; end if;
  foreach w in array public.insult_words() loop
    if (char_length(w) >= 4 and position(w in n) > 0) or n = w then raise exception 'bad_pseudo'; end if;
  end loop;
  select * into cur from public.user_profiles where user_id = auth.uid() for update;
  if found then
    if lower(cur.pseudo) = lower(v) then
      update public.user_profiles set pseudo = v where user_id = auth.uid();    -- seule la casse change
      return v;
    end if;
    if cur.pseudo_changed_at > now() - interval '30 days' then raise exception 'pseudo_change_too_soon'; end if;
  end if;
  begin
    insert into public.user_profiles (user_id, pseudo) values (auth.uid(), v)
    on conflict (user_id) do update set pseudo = excluded.pseudo, pseudo_changed_at = now();
  exception when unique_violation then
    raise exception 'pseudo_taken';
  end;
  return v;
end;
$$;

-- Ce que la page d'avis doit savoir : mon pseudo, mon avis éventuel, ai-je le droit d'en écrire un ?
create or replace function public.my_review_context(p_merchant uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare m public.merchant_profiles; u auth.users; v_reason text; rv public.reviews;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where id = p_merchant;
  if not found then raise exception 'not_found'; end if;
  select * into u from auth.users where id = auth.uid();
  select * into rv from public.reviews where merchant_id = p_merchant and user_id = auth.uid();
  v_reason := case
    when m.owner_id = auth.uid() then 'own_page'
    when m.verification <> 'verified' then 'not_verified'
    when u.email_confirmed_at is null then 'email_not_confirmed'
    when u.created_at > now() - interval '1 hour' and not found then 'account_too_new'
  end;
  return jsonb_build_object(
    'pseudo', (select pseudo from public.user_profiles where user_id = auth.uid()),
    'can_review', v_reason is null, 'reason', v_reason,
    'review', case when rv.id is null then null else jsonb_build_object('id', rv.id, 'rating', rv.rating, 'body', rv.body, 'visited', rv.visited, 'created_at', rv.created_at) end);
end;
$$;

-- Publier (ou modifier) MON avis sur un commerce : un seul par compte.
create or replace function public.submit_review(p_merchant uuid, p_rating integer, p_body text, p_visited boolean default false)
returns uuid
language plpgsql security definer set search_path = public, auth
as $$
declare m public.merchant_profiles; u auth.users; v_issue text; v_id uuid; v_exists boolean;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where id = p_merchant;
  if not found or m.verification <> 'verified' then raise exception 'not_found'; end if;
  if m.owner_id = auth.uid() then raise exception 'own_page'; end if;
  select * into u from auth.users where id = auth.uid();
  if u.email_confirmed_at is null then raise exception 'email_not_confirmed'; end if;
  if not exists (select 1 from public.user_profiles where user_id = auth.uid()) then raise exception 'pseudo_required'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'invalid_rating'; end if;
  v_issue := public.review_text_issue(p_body, 20);
  if v_issue is not null then raise exception 'review_%', v_issue; end if;

  select true into v_exists from public.reviews where merchant_id = p_merchant and user_id = auth.uid();
  if v_exists then
    update public.reviews
       set rating = p_rating, body = btrim(p_body), visited = coalesce(p_visited, false), updated_at = now()
     where merchant_id = p_merchant and user_id = auth.uid()
    returning id into v_id;
    return v_id;
  end if;
  if u.created_at > now() - interval '1 hour' then raise exception 'account_too_new'; end if;
  if (select count(*) from public.reviews where user_id = auth.uid() and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'too_many_reviews';
  end if;
  insert into public.reviews (merchant_id, user_id, rating, body, visited)
  values (p_merchant, auth.uid(), p_rating, btrim(p_body), coalesce(p_visited, false))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.delete_my_review(p_merchant uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.reviews where merchant_id = p_merchant and user_id = auth.uid();
  if not found then raise exception 'not_found'; end if;
end;
$$;

-- Avis d'une page, du plus récent au plus ancien. Le pseudo remplace l'identité ; jamais d'email.
create or replace function public.list_reviews(p_merchant uuid, p_before timestamptz default null, p_limit integer default 10)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'rating', x.rating, 'body', x.body, 'visited', x.visited,
             'created_at', x.created_at, 'pseudo', x.pseudo, 'mine', x.user_id = auth.uid(),
             'reply', case when x.reply_body is null then null else jsonb_build_object('body', x.reply_body, 'at', x.reply_at) end)
             order by x.created_at desc, x.id desc)
    from (select r.*, up.pseudo from public.reviews r
            join public.merchant_profiles m on m.id = r.merchant_id
            left join public.user_profiles up on up.user_id = r.user_id
           where r.merchant_id = p_merchant and (m.verification = 'verified' or m.owner_id = auth.uid())
             and r.status = 'published' and (p_before is null or r.created_at < p_before)
           order by r.created_at desc, r.id desc limit least(greatest(coalesce(p_limit, 10), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- Réponse publique du commerçant (une par avis, modifiable).
create or replace function public.reply_to_review(p_review uuid, p_text text)
returns void
language plpgsql security definer set search_path = public
as $$
declare rv public.reviews; v_issue text;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select r.* into rv from public.reviews r join public.merchant_profiles m on m.id = r.merchant_id
   where r.id = p_review and m.owner_id = auth.uid() and m.verification = 'verified' for update of r;
  if not found then raise exception 'not_found'; end if;
  v_issue := public.review_text_issue(p_text, 5);
  if v_issue is not null then raise exception 'reply_%', v_issue; end if;
  update public.reviews set reply_body = btrim(p_text), reply_at = now() where id = rv.id;
end;
$$;

create or replace function public.delete_reply(p_review uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.reviews r set reply_body = null, reply_at = null
    from public.merchant_profiles m
   where r.id = p_review and m.id = r.merchant_id and m.owner_id = auth.uid();
  if not found then raise exception 'not_found'; end if;
end;
$$;

-- La fiche d'une page indique maintenant la note moyenne et le nombre d'avis.
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
    'review_count', m.review_count,
    'rating_avg', case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end,
    'is_owner', m.owner_id = auth.uid(),
    'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = m.id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Droits d'exécution
-- ---------------------------------------------------------------------------
revoke all on function
  public.reviews_stats_sync(), public.normalize_fr(text), public.insult_words(), public.review_text_issue(text, integer),
  public.set_pseudo(text), public.my_review_context(uuid), public.submit_review(uuid, integer, text, boolean),
  public.delete_my_review(uuid), public.list_reviews(uuid, timestamptz, integer),
  public.reply_to_review(uuid, text), public.delete_reply(uuid)
from public, anon, authenticated;
grant execute on function
  public.set_pseudo(text), public.my_review_context(uuid), public.submit_review(uuid, integer, text, boolean),
  public.delete_my_review(uuid), public.list_reviews(uuid, timestamptz, integer),
  public.reply_to_review(uuid, text), public.delete_reply(uuid)
to authenticated;
