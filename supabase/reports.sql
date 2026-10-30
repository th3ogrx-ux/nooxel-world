-- ============================================================================
-- Nooxel World — PHASE 2, ÉTAPE 4 : signalements (page de commerce, avis, problème dans l'application).
-- À coller dans Supabase → SQL Editor → Run, APRÈS reviews.sql. Peut être relancé sans danger.
--
-- Règles :
--   • Tout compte connecté (email confirmé) peut signaler ; personne d'autre ne voit un signalement, sauf
--     l'administrateur (avec la double authentification). Le commerçant ne sait jamais qui l'a signalé.
--   • 10 signalements par 24 h et par compte ; un même élément ne peut pas être resignalé tant que le
--     précédent signalement du même compte est ouvert.
--   • Chaque traitement (résolu / sans suite) garde l'administrateur, la date et la note : trace permanente.
--   • RGPD : si le compte du signalant est supprimé, son identité disparaît du signalement (le contenu reste
--     pour la modération) ; les signalements traités sont effacés au bout d'un an.
-- ============================================================================

create table if not exists public.reports (
  id           uuid primary key default gen_random_uuid(),
  ref          bigint generated always as identity unique,                 -- numéro lisible, donné à la personne
  reporter_id  uuid references auth.users(id) on delete set null,
  kind         text not null check (kind in ('merchant', 'review', 'app')),
  merchant_id  uuid references public.merchant_profiles(id) on delete set null,
  review_id    uuid references public.reviews(id) on delete set null,
  target_label text check (target_label is null or char_length(target_label) <= 200),   -- nom du commerce / pseudo au moment du signalement
  reason       text not null check (reason in ('false_info', 'scam', 'inappropriate', 'other', 'bug')),
  details      text check (details is null or char_length(details) <= 1000),
  page         text check (page is null or char_length(page) <= 200),
  status       text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  handled_by   uuid references auth.users(id) on delete set null,
  handled_at   timestamptz,
  handled_note text check (handled_note is null or char_length(handled_note) <= 1000),
  ack_sent_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists reports_by_status on public.reports (status, created_at);
create index if not exists reports_by_reporter on public.reports (reporter_id, created_at desc);
alter table public.reports enable row level security;
revoke all on public.reports from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Signaler
-- ---------------------------------------------------------------------------
create or replace function public.submit_report(
  p_kind text, p_merchant uuid, p_review uuid, p_reason text, p_details text default null, p_page text default null)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid(); v_details text := nullif(btrim(coalesce(p_details, '')), '');
  m public.merchant_profiles; rv public.reviews; v_label text; v_merchant uuid; v_id uuid; v_ref bigint;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from auth.users where id = v_uid and email_confirmed_at is not null) then raise exception 'email_not_confirmed'; end if;
  if p_kind not in ('merchant', 'review', 'app') then raise exception 'invalid_kind'; end if;
  if (p_kind = 'app' and p_reason not in ('bug', 'other')) or (p_kind <> 'app' and p_reason not in ('false_info', 'scam', 'inappropriate', 'other')) then
    raise exception 'invalid_reason';
  end if;
  if v_details is not null and char_length(v_details) > 1000 then raise exception 'details_too_long'; end if;
  if (p_reason = 'other' or p_kind = 'app') and char_length(coalesce(v_details, '')) < 10 then raise exception 'details_required'; end if;
  if (select count(*) from public.reports where reporter_id = v_uid and created_at > now() - interval '24 hours') >= 10 then raise exception 'too_many_reports'; end if;

  if p_kind = 'merchant' then
    select * into m from public.merchant_profiles where id = p_merchant and verification = 'verified';
    if not found then raise exception 'not_found'; end if;
    if m.owner_id = v_uid then raise exception 'own_page'; end if;
    v_merchant := m.id; v_label := m.business_name;
  elsif p_kind = 'review' then
    select r.* into rv from public.reviews r join public.merchant_profiles mm on mm.id = r.merchant_id
     where r.id = p_review and r.status = 'published' and mm.verification in ('verified');
    if not found then raise exception 'not_found'; end if;
    if rv.user_id = v_uid then raise exception 'own_review'; end if;
    v_merchant := rv.merchant_id; v_label := coalesce((select pseudo from public.user_profiles where user_id = rv.user_id), 'Utilisateur');
  end if;

  if p_kind <> 'app' and exists (select 1 from public.reports
       where reporter_id = v_uid and status = 'open' and kind = p_kind
         and ((p_kind = 'merchant' and merchant_id = v_merchant) or (p_kind = 'review' and review_id = p_review))) then
    raise exception 'already_reported';
  end if;

  insert into public.reports (reporter_id, kind, merchant_id, review_id, target_label, reason, details, page)
  values (v_uid, p_kind, v_merchant, case when p_kind = 'review' then p_review end, v_label, p_reason, v_details, left(btrim(coalesce(p_page, '')), 200))
  returning id, ref into v_id, v_ref;
  return jsonb_build_object('id', v_id, 'ref', v_ref);
end;
$$;

-- ---------------------------------------------------------------------------
-- Back-office (administrateur + double authentification)
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_reports(p_status text default 'open')
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
begin
  perform public.require_admin();
  return coalesce((
    select jsonb_agg(x order by x->>'created_at') from (
      select jsonb_build_object(
        'id', q.id, 'ref', q.ref, 'kind', q.kind, 'reason', q.reason, 'details', q.details, 'page', q.page,
        'status', q.status, 'created_at', q.created_at, 'handled_at', q.handled_at, 'handled_note', q.handled_note,
        'reporter_email', u.email, 'target_label', q.target_label,
        'merchant_id', q.merchant_id, 'merchant_name', m.business_name, 'merchant_verification', m.verification,
        'review', case when rv.id is null then null else jsonb_build_object('id', rv.id, 'rating', rv.rating, 'body', rv.body, 'status', rv.status,
                   'pseudo', (select pseudo from public.user_profiles where user_id = rv.user_id)) end,
        'reports_on_same_target', (select count(*) from public.reports o where o.id <> q.id and o.kind = q.kind
             and ((q.kind = 'merchant' and o.merchant_id = q.merchant_id) or (q.kind = 'review' and o.review_id = q.review_id)))
      ) as x
      from public.reports q
      left join auth.users u on u.id = q.reporter_id
      left join public.merchant_profiles m on m.id = q.merchant_id
      left join public.reviews rv on rv.id = q.review_id
      where p_status = 'all' or q.status = p_status
      order by q.created_at asc limit 200) t), '[]'::jsonb);
end;
$$;

-- Traiter : « resolved » (une suite a été donnée) ou « dismissed » (sans suite). Note obligatoire.
-- p_hide_review = true : l'avis signalé est aussitôt masqué (la note moyenne se met à jour).
create or replace function public.admin_handle_report(p_id uuid, p_outcome text, p_note text, p_hide_review boolean default false)
returns void
language plpgsql security definer set search_path = public
as $$
declare r public.reports; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.require_admin();
  if p_outcome not in ('resolved', 'dismissed') then raise exception 'invalid_outcome'; end if;
  if char_length(coalesce(v_note, '')) < 5 then raise exception 'reason_required'; end if;
  select * into r from public.reports where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if r.status <> 'open' then raise exception 'not_open'; end if;
  if p_hide_review then
    if r.review_id is null then raise exception 'no_review'; end if;
    update public.reviews set status = 'hidden' where id = r.review_id;
  end if;
  update public.reports set status = p_outcome, handled_by = auth.uid(), handled_at = now(), handled_note = v_note where id = r.id;
end;
$$;

-- Remettre un avis masqué en ligne (erreur de modération).
create or replace function public.admin_restore_review(p_review uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_admin();
  update public.reviews set status = 'published' where id = p_review and status = 'hidden';
  if not found then raise exception 'not_found'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Accusé de réception par email (fonction serveur « report-ack », clé service_role uniquement)
-- ---------------------------------------------------------------------------
create or replace function public.system_report_ack_info(p_report uuid, p_user uuid)
returns jsonb
language sql stable security definer set search_path = public, auth
as $$
  select jsonb_build_object('email', u.email, 'ref', q.ref, 'kind', q.kind, 'reason', q.reason, 'target', q.target_label)
    from public.reports q join auth.users u on u.id = q.reporter_id
   where q.id = p_report and q.reporter_id = p_user and q.ack_sent_at is null;
$$;
create or replace function public.system_mark_report_acked(p_report uuid)
returns void language sql security definer set search_path = public as $$
  update public.reports set ack_sent_at = now() where id = p_report and ack_sent_at is null;
$$;

-- Nettoyage : signalements traités depuis plus d'un an.
create or replace function public.purge_old_reports()
returns integer
language plpgsql security definer set search_path = public
as $$
declare v_n integer;
begin
  delete from public.reports where status <> 'open' and handled_at < now() - interval '365 days';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function
  public.submit_report(text, uuid, uuid, text, text, text), public.admin_list_reports(text),
  public.admin_handle_report(uuid, text, text, boolean), public.admin_restore_review(uuid),
  public.system_report_ack_info(uuid, uuid), public.system_mark_report_acked(uuid), public.purge_old_reports()
from public, anon, authenticated;
grant execute on function
  public.submit_report(text, uuid, uuid, text, text, text), public.admin_list_reports(text),
  public.admin_handle_report(uuid, text, text, boolean), public.admin_restore_review(uuid)
to authenticated;
grant execute on function public.system_report_ack_info(uuid, uuid), public.system_mark_report_acked(uuid), public.purge_old_reports() to service_role;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('purge-old-reports', '53 3 * * *', 'select public.purge_old_reports();');
  end if;
end $$;
