-- ============================================================================
-- Nooxel World — PHASE 3 : vraies notifications (remplacent les données de test).
-- À coller dans Supabase → SQL Editor → Run, APRÈS account-pages.sql. Peut être relancé sans danger.
--
-- Qui reçoit quoi :
--   • follow       → le commerçant, quand quelqu'un s'abonne à sa page (une seule fois par personne)
--   • review       → le commerçant, quand un avis est publié sur sa page
--   • reply        → l'auteur d'un avis, quand le commerçant lui répond
--   • post         → les abonnés d'un commerce, quand il publie (2 000 abonnés au plus par publication)
--   • report_done  → la personne qui a signalé quelque chose, quand l'équipe a traité son signalement
--   • verified     → le commerçant, quand son profil professionnel est vérifié
-- Le navigateur ne lit ni n'écrit jamais la table directement : tout passe par trois fonctions, réservées au propriétaire.
-- RGPD : tout disparaît avec le compte (destinataire ou auteur). Lues > 60 jours ou toutes > 180 jours : effacées chaque nuit.
-- ============================================================================

create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('follow', 'review', 'reply', 'post', 'report_done', 'verified')),
  actor_id    uuid references auth.users(id) on delete cascade,
  merchant_id uuid references public.merchant_profiles(id) on delete cascade,
  ref_id      uuid,
  snippet     text check (snippet is null or char_length(snippet) <= 120),
  rating      smallint check (rating is null or rating between 1 and 5),
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index if not exists notifications_by_user on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread on public.notifications (user_id) where read_at is null;
create unique index if not exists notifications_one_follow on public.notifications (user_id, actor_id, merchant_id) where kind = 'follow';
alter table public.notifications enable row level security;
revoke all on public.notifications from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Création automatique (déclencheurs : le navigateur ne peut pas en fabriquer)
-- ---------------------------------------------------------------------------
create or replace function public.notify_on_follow() returns trigger
language plpgsql security definer set search_path = public as $$
declare m public.merchant_profiles;
begin
  select * into m from public.merchant_profiles where id = new.merchant_id;
  if found and m.owner_id <> new.user_id then
    insert into public.notifications (user_id, kind, actor_id, merchant_id) values (m.owner_id, 'follow', new.user_id, m.id) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists notify_follow on public.follows;
create trigger notify_follow after insert on public.follows for each row execute function public.notify_on_follow();

create or replace function public.notify_on_review() returns trigger
language plpgsql security definer set search_path = public as $$
declare m public.merchant_profiles;
begin
  if new.status = 'published' then
    select * into m from public.merchant_profiles where id = new.merchant_id;
    if found and m.owner_id <> new.user_id then
      insert into public.notifications (user_id, kind, actor_id, merchant_id, ref_id, snippet, rating)
      values (m.owner_id, 'review', new.user_id, m.id, new.id, left(btrim(new.body), 80), new.rating);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists notify_review on public.reviews;
create trigger notify_review after insert on public.reviews for each row execute function public.notify_on_review();

create or replace function public.notify_on_reply() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.reply_body is not null and new.reply_body is distinct from old.reply_body and new.status = 'published' then
    insert into public.notifications (user_id, kind, merchant_id, ref_id, snippet) values (new.user_id, 'reply', new.merchant_id, new.id, left(btrim(new.reply_body), 80));
  end if;
  return new;
end $$;
drop trigger if exists notify_reply on public.reviews;
create trigger notify_reply after update of reply_body on public.reviews for each row execute function public.notify_on_reply();

create or replace function public.notify_on_post() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, kind, merchant_id, ref_id, snippet)
  select f.user_id, 'post', new.merchant_id, new.id, left(btrim(new.body), 80)
    from public.follows f where f.merchant_id = new.merchant_id order by f.created_at desc limit 2000;
  return new;
end $$;
drop trigger if exists notify_post on public.merchant_posts;
create trigger notify_post after insert on public.merchant_posts for each row execute function public.notify_on_post();

create or replace function public.notify_on_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'open' and new.status in ('resolved', 'dismissed') and new.reporter_id is not null then
    insert into public.notifications (user_id, kind, ref_id) values (new.reporter_id, 'report_done', new.id);
  end if;
  return new;
end $$;
drop trigger if exists notify_report on public.reports;
create trigger notify_report after update of status on public.reports for each row execute function public.notify_on_report();

create or replace function public.notify_on_verified() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.verification = 'verified' and old.verification is distinct from 'verified' then
    insert into public.notifications (user_id, kind, merchant_id) values (new.owner_id, 'verified', new.id);
  end if;
  return new;
end $$;
drop trigger if exists notify_verified on public.merchant_profiles;
create trigger notify_verified after update of verification on public.merchant_profiles for each row execute function public.notify_on_verified();

-- ---------------------------------------------------------------------------
-- Lecture (propriétaire seulement)
-- ---------------------------------------------------------------------------
create or replace function public.my_notifications(p_before timestamptz default null, p_limit integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'created_at', x.created_at, 'read', x.read_at is not null,
             'name', x.name, 'merchant_id', x.merchant_id, 'snippet', x.snippet, 'rating', x.rating) order by x.created_at desc, x.id desc)
    from (select n.id, n.kind, n.created_at, n.read_at, n.merchant_id, n.snippet, n.rating,
                 case when n.kind in ('follow', 'review') then coalesce((select pseudo from public.user_profiles where user_id = n.actor_id), 'Un utilisateur')
                      when n.kind in ('reply', 'post') then (select business_name from public.merchant_profiles where id = n.merchant_id) end as name
            from public.notifications n
           where n.user_id = auth.uid() and (p_before is null or n.created_at < p_before)
           order by n.created_at desc, n.id desc limit least(greatest(coalesce(p_limit, 30), 1), 50)) x), '[]'::jsonb);
end;
$$;

create or replace function public.my_unread_count()
returns integer
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then return 0; end if;
  return (select count(*) from public.notifications where user_id = auth.uid() and read_at is null);
end;
$$;

-- p_ids vide ou absent = tout marquer comme lu
create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer
language plpgsql security definer set search_path = public
as $$
declare v_n integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  update public.notifications set read_at = now() where user_id = auth.uid() and read_at is null and (p_ids is null or id = any (p_ids));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.purge_old_notifications()
returns integer
language plpgsql security definer set search_path = public
as $$
declare v_n integer;
begin
  delete from public.notifications where (read_at is not null and read_at < now() - interval '60 days') or created_at < now() - interval '180 days';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.notify_on_follow(), public.notify_on_review(), public.notify_on_reply(), public.notify_on_post(), public.notify_on_report(), public.notify_on_verified(),
  public.my_notifications(timestamptz, integer), public.my_unread_count(), public.mark_notifications_read(uuid[]), public.purge_old_notifications() from public, anon, authenticated;
grant execute on function public.my_notifications(timestamptz, integer), public.my_unread_count(), public.mark_notifications_read(uuid[]) to authenticated;
grant execute on function public.purge_old_notifications() to service_role;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('purge-old-notifications', '47 3 * * *', 'select public.purge_old_notifications();');
  end if;
end $$;
