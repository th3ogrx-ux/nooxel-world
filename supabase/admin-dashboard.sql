-- Nooxel World — Tableau de bord administrateur (statistiques, classements, listes utilisateurs et avis)
-- À coller dans Supabase → SQL Editor → Run, APRÈS profile-privacy-reports.sql. Peut être relancé sans danger.
--
-- Vie privée : le suivi d'activité ne garde que « quel compte, quel jour » (aucune heure, aucun appareil, aucune adresse IP),
-- uniquement pour compter les personnes actives. Effacé avec le compte, et au bout de 400 jours.
-- L'historique des connexions commence à la date d'installation : avant, il n'existait nulle part (les inscriptions, elles, sont connues depuis le début).

-- 1. Activité quotidienne (un compte = une ligne par jour)
create table if not exists public.user_activity (
  user_id uuid not null references auth.users(id) on delete cascade,
  day     date not null,
  primary key (user_id, day)
);
create index if not exists user_activity_by_day on public.user_activity (day);
alter table public.user_activity enable row level security;
revoke all on public.user_activity from anon, authenticated;

create or replace function public.log_activity()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.user_activity (user_id, day) values (auth.uid(), (now() at time zone 'Europe/Paris')::date) on conflict do nothing;
end;
$$;

create or replace function public.purge_old_activity()
returns void
language sql security definer set search_path = public
as $$ delete from public.user_activity where day < (now() at time zone 'Europe/Paris')::date - 400; $$;

-- 2. Tableau de bord : chiffres clés, séries par jour (365 jours), classements
create or replace function public.admin_dashboard()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare v_today date := (now() at time zone 'Europe/Paris')::date; v_from date; v_series jsonb; v_base jsonb; v_tot jsonb;
begin
  perform public.require_admin();
  v_from := v_today - 364;
  select jsonb_agg(jsonb_build_object('day', d::date,
      'personal', (select count(*) from auth.users u where (u.created_at at time zone 'Europe/Paris')::date = d::date
                     and not exists (select 1 from public.merchant_profiles m where m.owner_id = u.id)),
      'merchants', (select count(*) from public.merchant_profiles m where (m.created_at at time zone 'Europe/Paris')::date = d::date),
      'active', (select count(*) from public.user_activity a where a.day = d::date)) order by d)
    into v_series from generate_series(v_from, v_today, interval '1 day') d;
  v_base := jsonb_build_object(
    'personal', (select count(*) from auth.users u where (u.created_at at time zone 'Europe/Paris')::date < v_from and not exists (select 1 from public.merchant_profiles m where m.owner_id = u.id)),
    'merchants', (select count(*) from public.merchant_profiles m where (m.created_at at time zone 'Europe/Paris')::date < v_from));
  v_tot := jsonb_build_object(
    'users', (select count(*) from auth.users),
    'merchants', (select count(*) from public.merchant_profiles),
    'verified_merchants', (select count(*) from public.merchant_profiles where verification = 'verified'),
    'personal', (select count(*) from auth.users u where not exists (select 1 from public.merchant_profiles m where m.owner_id = u.id)),
    'logins_today', (select count(*) from auth.users where (last_sign_in_at at time zone 'Europe/Paris')::date = v_today),
    'active_today', (select count(*) from public.user_activity where day = v_today),
    'active_7d', (select count(distinct user_id) from public.user_activity where day > v_today - 7),
    'new_7d', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'pending_requests', (select count(*) from public.verification_requests where status in ('pending', 'contested')),
    'open_reports', (select count(*) from public.reports where status = 'open'),
    'activity_since', (select min(day) from public.user_activity));
  return jsonb_build_object('today', v_today, 'totals', v_tot, 'base', v_base, 'series', v_series,
    'top_videos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'caption', x.caption, 'poster_path', x.poster_path, 'like_count', x.like_count,
         'merchant_id', x.merchant_id, 'business_name', x.business_name) order by x.like_count desc, x.created_at desc)
       from (select v.*, m.business_name from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id and m.verification = 'verified'
              order by v.like_count desc, v.created_at desc limit 8) x), '[]'::jsonb),
    'top_followed', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'business_name', x.business_name, 'logo_path', x.logo_path, 'follower_count', x.follower_count,
         'rating_avg', case when x.review_count > 0 then round(x.rating_sum::numeric / x.review_count, 1) end, 'review_count', x.review_count) order by x.follower_count desc, x.business_name)
       from (select * from public.merchant_profiles where verification = 'verified' order by follower_count desc, business_name limit 8) x), '[]'::jsonb),
    'top_rated', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'business_name', x.business_name, 'logo_path', x.logo_path, 'follower_count', x.follower_count,
         'rating_avg', round(x.rating_sum::numeric / x.review_count, 1), 'review_count', x.review_count) order by x.rating_sum::numeric / x.review_count desc, x.review_count desc)
       from (select * from public.merchant_profiles where verification = 'verified' and review_count >= 3
              order by rating_sum::numeric / review_count desc, review_count desc limit 8) x), '[]'::jsonb));
end;
$$;

-- 3. Utilisateurs (recherche par email ou pseudo)
create or replace function public.admin_list_users(p_query text default null)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare q text := nullif(btrim(coalesce(p_query, '')), '');
begin
  perform public.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'email', x.email, 'pseudo', x.pseudo, 'created_at', x.created_at, 'last_sign_in_at', x.last_sign_in_at,
             'is_private', x.is_private, 'is_merchant', x.is_merchant, 'reviews', x.reviews) order by x.created_at desc)
    from (select u.id, u.email, up.pseudo, u.created_at, u.last_sign_in_at, coalesce(up.is_private, false) as is_private,
                 exists (select 1 from public.merchant_profiles m where m.owner_id = u.id) as is_merchant,
                 (select count(*) from public.reviews r where r.user_id = u.id) as reviews
            from auth.users u left join public.user_profiles up on up.user_id = u.id
           where q is null or u.email ilike '%' || replace(replace(q, '%', ''), '_', '') || '%' or up.pseudo ilike '%' || replace(replace(q, '%', ''), '_', '') || '%'
           order by u.created_at desc limit 100) x), '[]'::jsonb);
end;
$$;

-- 4. Avis : liste (recherche, filtre) et masquage / remise en ligne
create or replace function public.admin_list_reviews(p_query text default null, p_status text default 'all')
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare q text := nullif(btrim(coalesce(p_query, '')), '');
begin
  perform public.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'rating', x.rating, 'body', x.body, 'status', x.status, 'created_at', x.created_at,
             'pseudo', x.pseudo, 'merchant_id', x.merchant_id, 'business_name', x.business_name, 'reports', x.reports) order by x.created_at desc)
    from (select r.id, r.rating, r.body, r.status, r.created_at, up.pseudo, r.merchant_id, m.business_name,
                 (select count(*) from public.reports p where p.review_id = r.id) as reports
            from public.reviews r join public.merchant_profiles m on m.id = r.merchant_id left join public.user_profiles up on up.user_id = r.user_id
           where (p_status = 'all' or r.status = p_status)
             and (q is null or r.body ilike '%' || replace(replace(q, '%', ''), '_', '') || '%' or m.business_name ilike '%' || replace(replace(q, '%', ''), '_', '') || '%' or up.pseudo ilike '%' || replace(replace(q, '%', ''), '_', '') || '%')
           order by r.created_at desc limit 100) x), '[]'::jsonb);
end;
$$;

create or replace function public.admin_set_review_status(p_review uuid, p_status text, p_note text default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_admin();
  if p_status not in ('hidden', 'published') then raise exception 'invalid_outcome'; end if;
  if p_status = 'hidden' and char_length(btrim(coalesce(p_note, ''))) < 5 then raise exception 'reason_required'; end if;
  update public.reviews set status = p_status where id = p_review;
  if not found then raise exception 'not_found'; end if;
end;
$$;

-- 5. Droits + nettoyage quotidien
revoke all on function public.log_activity(), public.purge_old_activity(), public.admin_dashboard(), public.admin_list_users(text),
  public.admin_list_reviews(text, text), public.admin_set_review_status(uuid, text, text) from public, anon, authenticated;
grant execute on function public.log_activity(), public.admin_dashboard(), public.admin_list_users(text),
  public.admin_list_reviews(text, text), public.admin_set_review_status(uuid, text, text) to authenticated;
grant execute on function public.purge_old_activity() to service_role;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('purge-old-activity', '53 3 * * *', 'select public.purge_old_activity();');
  end if;
end $$;
