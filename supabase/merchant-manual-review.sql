-- ============================================================================
-- Nooxel World — vérification des commerçants, ÉTAPE 3 : validation manuelle SANS pièce d'identité.
-- À coller dans Supabase → SQL Editor → Run, APRÈS merchant-verification.sql, merchant-functions.sql
-- et admin-mfa.sql. Peut être relancé sans danger.
--
-- Ce qui change :
--   • Le commerçant fournit : téléphone, lien Instagram/Facebook/TikTok, SIRET (facultatif), code de
--     parrainage (facultatif). Plus de pièce d'identité ni de selfie.
--   • TOUTE demande est examinée à la main par un administrateur, même avec un SIRET valide
--     (un SIRET est public : il ne prouve pas que le demandeur en est le titulaire).
--   • Un seul badge : « professionnel vérifié ».
--   • Le numéro de téléphone n'est PAS vérifié par SMS (service payant) : il est affiché comme tel.
--   • Données personnelles : le téléphone et le lien de la demande sont effacés 30 jours après un refus,
--     tout de suite après une annulation ; conservés seulement si la demande est approuvée.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Structure
-- ---------------------------------------------------------------------------
alter table public.verification_requests add column if not exists phone text;

alter table public.verification_requests drop constraint if exists verification_requests_kind_check;
alter table public.verification_requests add constraint verification_requests_kind_check
  check (kind in ('company', 'profile', 'pro'));          -- 'pro' = nouvelle demande ; les autres restent pour l'historique

alter table public.verification_requests drop constraint if exists vr_phone_format;
alter table public.verification_requests add constraint vr_phone_format
  check (phone is null or phone ~ '^\+?[0-9]{8,15}$');

-- Un seul niveau de vérification : 'verified'.
alter table public.merchant_profiles drop constraint if exists merchant_profiles_verification_check;
update public.merchant_profiles set verification = 'verified'
 where verification in ('company_verified', 'profile_confirmed');
alter table public.merchant_profiles add constraint merchant_profiles_verification_check
  check (verification in ('none', 'pending', 'verified'));
update public.merchant_profiles set referral_code = public.gen_referral_code()
 where verification = 'verified' and referral_code is null;

-- Résultat du contrôle SIRET (écrit uniquement par la fonction serveur, jamais par le navigateur).
create table if not exists public.siret_checks (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  siret      text not null check (siret ~ '^[0-9]{14}$'),
  result     jsonb not null,
  checked_at timestamptz not null default now()
);
alter table public.siret_checks enable row level security;
revoke all on public.siret_checks from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Fin de la collecte de pièces d'identité
-- ---------------------------------------------------------------------------
drop policy if exists vdocs_owner_insert on storage.objects;          -- plus aucun nouveau dépôt
drop function if exists public.submit_profile_confirmation(text, text, text, text);
drop function if exists public.erase_my_documents();
drop function if exists public.admin_authorize_document_access(uuid, text);
-- Les demandes de l'ancien système encore ouvertes sont annulées (le commerçant peut redéposer une demande),
-- et leurs pièces sont supprimées par le nettoyage quotidien existant.
do $$
declare r record;
begin
  for r in select id, merchant_id from public.verification_requests
            where kind = 'profile' and status in ('pending', 'contested') for update
  loop
    update public.verification_requests set status = 'cancelled' where id = r.id;
    update public.merchant_profiles set verification = 'none' where id = r.merchant_id and verification = 'pending';
    perform public.log_event(r.id, r.merchant_id, null, 'system', 'cancelled', jsonb_build_object('reason', 'new_verification_process'));
  end loop;
end $$;
update public.verification_requests set docs_delete_after = now()
 where docs_deleted_at is null and (id_doc_path is not null or selfie_path is not null);

-- ---------------------------------------------------------------------------
-- 3. Vitrine publique : un seul badge
-- ---------------------------------------------------------------------------
create or replace view public.public_merchants as
select
  id,
  business_name,
  description,
  case verification when 'verified' then 'professionnel vérifié' else null end as badge,
  verification = 'verified' as can_receive_reviews,
  case verification when 'verified' then 1 else 0 end as visibility_rank,
  case when verification = 'verified' then social_url end as social_url
from public.merchant_profiles;
grant select on public.public_merchants to anon, authenticated;

create or replace function public.merchant_can_receive_reviews(m uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce((select verification = 'verified' from public.merchant_profiles where id = m), false);
$$;

-- ---------------------------------------------------------------------------
-- 4. COMMERÇANT
-- ---------------------------------------------------------------------------

-- Dépôt de la demande. Le SIRET, s'il est fourni, doit avoir été contrôlé par le serveur dans les 2 dernières heures.
create or replace function public.submit_pro_request(
  p_phone text, p_social_url text, p_siret text, p_referral_code text)
returns uuid
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
  m public.merchant_profiles;
  v_phone text; v_social text; v_siret text; v_check jsonb;
  v_code text; v_ref uuid; v_req uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;

  select * into m from public.merchant_profiles where owner_id = v_uid for update;
  if not found then raise exception 'no_profile'; end if;
  if not exists (select 1 from auth.users where id = v_uid and email_confirmed_at is not null) then
    raise exception 'email_not_confirmed';
  end if;
  if m.verification <> 'none' then raise exception 'not_eligible'; end if;
  if (select count(*) from public.verification_requests
        where merchant_id = m.id and created_at > now() - interval '30 days') >= 3 then
    raise exception 'too_many_requests';
  end if;

  v_phone := regexp_replace(coalesce(p_phone, ''), '[\s.\-()]', '', 'g');
  if v_phone like '00%' then v_phone := '+' || substr(v_phone, 3); end if;
  if v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'invalid_phone'; end if;

  v_social := trim(coalesce(p_social_url, ''));
  if v_social !~* '^https://([a-z0-9-]+\.)?(instagram\.com|facebook\.com|tiktok\.com)/[^\s]+$' then
    raise exception 'invalid_social_url';
  end if;

  v_siret := regexp_replace(coalesce(p_siret, ''), '\s', '', 'g');
  if v_siret <> '' then
    if v_siret !~ '^[0-9]{14}$' then raise exception 'invalid_siret'; end if;
    select result into v_check from public.siret_checks
     where user_id = v_uid and siret = v_siret and checked_at > now() - interval '2 hours';
    if v_check is null then raise exception 'siret_not_checked'; end if;
  else
    v_siret := null;
  end if;

  v_code := nullif(upper(trim(coalesce(p_referral_code, ''))), '');
  if v_code is not null then
    select id into v_ref from public.merchant_profiles
     where referral_code = v_code and verification = 'verified' and id <> m.id;
    if v_ref is null then raise exception 'invalid_referral_code'; end if;
  end if;

  insert into public.verification_requests
    (merchant_id, kind, phone, social_url, siret, siret_check, referral_code_used, referrer_id)
  values (m.id, 'pro', v_phone, v_social, v_siret, v_check, v_code, v_ref)
  returning id into v_req;

  update public.merchant_profiles
     set verification = 'pending', social_url = v_social, referred_by = v_ref
   where id = m.id;
  delete from public.siret_checks where user_id = v_uid;

  perform public.log_event(v_req, m.id, v_uid, 'owner', 'submitted',
    jsonb_build_object('kind', 'pro', 'siret', v_siret is not null, 'referral', v_ref is not null));
  return v_req;
end;
$$;

-- Annulation par le commerçant : les données de la demande sont effacées tout de suite.
create or replace function public.cancel_verification(p_request_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare r public.verification_requests;
begin
  select r2.* into r from public.verification_requests r2
    join public.merchant_profiles m2 on m2.id = r2.merchant_id
   where r2.id = p_request_id and m2.owner_id = auth.uid() for update of r2;
  if not found then raise exception 'not_found'; end if;
  if r.status not in ('pending', 'contested') then raise exception 'not_cancellable'; end if;

  update public.verification_requests
     set status = 'cancelled', phone = null, social_url = null,
         docs_delete_after = case when id_doc_path is not null then now() end
   where id = r.id;
  update public.merchant_profiles set verification = 'none' where id = r.merchant_id and verification = 'pending';
  perform public.log_event(r.id, r.merchant_id, auth.uid(), 'owner', 'cancelled', '{}'::jsonb);
end;
$$;

-- Contestation d'un refus : une seule fois, dans les 30 jours.
create or replace function public.contest_verification(p_request_id uuid, p_message text)
returns void
language plpgsql security definer set search_path = public
as $$
declare r public.verification_requests;
begin
  select r2.* into r from public.verification_requests r2
    join public.merchant_profiles m2 on m2.id = r2.merchant_id
   where r2.id = p_request_id and m2.owner_id = auth.uid() for update of r2;
  if not found then raise exception 'not_found'; end if;
  if r.status <> 'rejected' or r.contested_at is not null then raise exception 'not_contestable'; end if;
  if r.decided_at < now() - interval '30 days' or r.phone is null then raise exception 'contest_window_closed'; end if;
  if char_length(trim(coalesce(p_message, ''))) < 10 then raise exception 'message_too_short'; end if;
  if exists (select 1 from public.verification_requests
              where merchant_id = r.merchant_id and status in ('pending', 'contested')) then
    raise exception 'another_request_open';
  end if;

  update public.verification_requests
     set status = 'contested', contest_message = left(trim(p_message), 2000), contested_at = now()
   where id = r.id;
  update public.merchant_profiles set verification = 'pending' where id = r.merchant_id;
  perform public.log_event(r.id, r.merchant_id, auth.uid(), 'owner', 'contested', '{}'::jsonb);
end;
$$;

-- Statut visible par l'utilisateur (aucune identité d'administrateur n'est exposée, pas de numéro complet).
create or replace function public.my_verification_status()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce((
    select jsonb_build_object(
      'has_profile', true,
      'merchant_id', m.id,
      'business_name', m.business_name,
      'verification', m.verification,
      'badge', case m.verification when 'verified' then 'professionnel vérifié' end,
      'can_receive_reviews', m.verification = 'verified',
      'referral_code', m.referral_code,
      'request', (
        select jsonb_build_object(
          'id', q.id, 'kind', q.kind, 'status', q.status, 'created_at', q.created_at,
          'decided_at', q.decided_at, 'decision_reason', q.decision_reason,
          'contested_at', q.contested_at,
          'can_contest', (q.status = 'rejected' and q.contested_at is null
                          and q.decided_at > now() - interval '30 days' and q.phone is not null),
          'social_url', q.social_url, 'has_siret', q.siret is not null,
          'company_name', q.siret_check ->> 'name',
          'phone_end', case when q.phone is null then null else right(q.phone, 2) end)
        from public.verification_requests q where q.merchant_id = m.id order by q.created_at desc limit 1),
      'history', (
        select coalesce(jsonb_agg(jsonb_build_object('action', e.action, 'at', e.created_at, 'by', e.actor_role)
                                  order by e.created_at desc, e.id desc), '[]'::jsonb)
        from (select * from public.verification_events where merchant_id = m.id
               order by created_at desc, id desc limit 30) e))
    from public.merchant_profiles m where m.owner_id = auth.uid()
  ), jsonb_build_object('has_profile', false));
$$;

-- ---------------------------------------------------------------------------
-- 5. ADMINISTRATEUR
-- ---------------------------------------------------------------------------

-- File de validation (mêmes valeurs de filtre qu'avant).
create or replace function public.admin_list_requests(p_status text default 'to_review')
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
begin
  perform public.require_admin();
  return coalesce((
    select jsonb_agg(x order by x->>'created_at') from (
      select jsonb_build_object(
        'id', q.id, 'kind', q.kind, 'status', q.status, 'created_at', q.created_at,
        'phone', q.phone, 'phone_verified', false,
        'social_url', q.social_url, 'siret', q.siret, 'siret_check', q.siret_check,
        'contest_message', q.contest_message, 'contested_at', q.contested_at,
        'decision_reason', q.decision_reason, 'decided_at', q.decided_at,
        'merchant', jsonb_build_object('id', m.id, 'business_name', m.business_name,
                                       'description', m.description, 'verification', m.verification),
        'owner_email', u.email, 'email_confirmed', u.email_confirmed_at is not null,
        'account_created_at', u.created_at,
        'referrer', case when q.referrer_id is null then null else jsonb_build_object(
          'business_name', rm.business_name, 'verification', rm.verification) end,
        'previous_requests', (select count(*) from public.verification_requests o
                               where o.merchant_id = q.merchant_id and o.id <> q.id)
      ) as x
      from public.verification_requests q
      join public.merchant_profiles m on m.id = q.merchant_id
      join auth.users u on u.id = m.owner_id
      left join public.merchant_profiles rm on rm.id = q.referrer_id
      where q.kind <> 'company' and (
            (p_status = 'to_review' and q.status in ('pending', 'contested'))
         or (p_status = 'all')
         or (p_status = q.status))
      order by q.created_at asc limit 200) t), '[]'::jsonb);
end;
$$;

-- Décision sur une demande en attente. L'approbation attribue le SIRET (s'il est libre) et le code de parrainage.
create or replace function public.admin_decide(p_request_id uuid, p_approve boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare r public.verification_requests; m public.merchant_profiles; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform public.require_admin();
  select * into r from public.verification_requests where id = p_request_id for update;
  if not found then raise exception 'not_found'; end if;
  if r.status <> 'pending' then raise exception 'not_pending'; end if;
  select * into m from public.merchant_profiles where id = r.merchant_id for update;
  if m.owner_id = auth.uid() then raise exception 'cannot_review_own_request'; end if;
  if not p_approve and char_length(coalesce(v_reason, '')) < 5 then raise exception 'reason_required'; end if;

  if p_approve then
    if r.siret is not null and exists (select 1 from public.siret_blocks where siret = r.siret and owner_id = m.owner_id) then
      raise exception 'siret_blocked';
    end if;
    begin
      update public.merchant_profiles
         set verification = 'verified', verified_at = now(), siret = coalesce(r.siret, siret),
             referral_code = coalesce(referral_code, public.gen_referral_code())
       where id = m.id;
    exception when unique_violation then
      raise exception 'siret_already_claimed';
    end;
    update public.verification_requests
       set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_reason = v_reason
     where id = r.id;
    perform public.log_event(r.id, m.id, auth.uid(), 'admin', 'approved', jsonb_build_object('kind', r.kind, 'reason', v_reason));
  else
    update public.verification_requests
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_reason = v_reason
     where id = r.id;
    update public.merchant_profiles set verification = 'none' where id = m.id;
    perform public.log_event(r.id, m.id, auth.uid(), 'admin', 'rejected', jsonb_build_object('kind', r.kind, 'reason', v_reason));
  end if;
end;
$$;

-- Décision sur une contestation (un AUTRE administrateur s'il y en a plusieurs).
create or replace function public.admin_decide_contest(p_request_id uuid, p_approve boolean, p_reason text)
returns void
language plpgsql security definer set search_path = public
as $$
declare r public.verification_requests; m public.merchant_profiles; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform public.require_admin();
  select * into r from public.verification_requests where id = p_request_id for update;
  if not found then raise exception 'not_found'; end if;
  if r.status <> 'contested' then raise exception 'not_contested'; end if;
  select * into m from public.merchant_profiles where id = r.merchant_id for update;
  if m.owner_id = auth.uid() then raise exception 'cannot_review_own_request'; end if;
  if r.decided_by = auth.uid() and (select count(*) from public.admins) > 1 then
    raise exception 'another_admin_must_review';
  end if;
  if char_length(coalesce(v_reason, '')) < 5 then raise exception 'reason_required'; end if;

  if p_approve then
    if r.siret is not null and exists (select 1 from public.siret_blocks where siret = r.siret and owner_id = m.owner_id) then
      raise exception 'siret_blocked';
    end if;
    begin
      update public.merchant_profiles
         set verification = 'verified', verified_at = now(), siret = coalesce(r.siret, siret),
             referral_code = coalesce(referral_code, public.gen_referral_code())
       where id = m.id;
    exception when unique_violation then
      raise exception 'siret_already_claimed';
    end;
    update public.verification_requests
       set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_reason = v_reason
     where id = r.id;
    perform public.log_event(r.id, m.id, auth.uid(), 'admin', 'contest_upheld', jsonb_build_object('reason', v_reason));
  else
    update public.verification_requests
       set status = 'rejected_final', decided_by = auth.uid(), decided_at = now(), decision_reason = v_reason
     where id = r.id;
    update public.merchant_profiles set verification = 'none' where id = m.id;
    perform public.log_event(r.id, m.id, auth.uid(), 'admin', 'contest_dismissed', jsonb_build_object('reason', v_reason));
  end if;
end;
$$;

-- Révocation : même comportement qu'avant, pour l'unique niveau 'verified'.
create or replace function public.admin_revoke(p_merchant_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public
as $$
declare m public.merchant_profiles; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform public.require_admin();
  if char_length(coalesce(v_reason, '')) < 5 then raise exception 'reason_required'; end if;
  select * into m from public.merchant_profiles where id = p_merchant_id for update;
  if not found then raise exception 'not_found'; end if;
  if m.verification <> 'verified' then raise exception 'nothing_to_revoke'; end if;

  if m.siret is not null then
    insert into public.siret_blocks (siret, owner_id, reason) values (m.siret, m.owner_id, v_reason)
    on conflict do nothing;
  end if;
  update public.verification_requests
     set status = 'cancelled', phone = null
   where merchant_id = m.id and status in ('pending', 'contested');
  update public.merchant_profiles
     set verification = 'none', verified_at = null, siret = null, referral_code = null
   where id = m.id;
  perform public.log_event(null, m.id, auth.uid(), 'admin', 'revoked',
    jsonb_build_object('previous', m.verification, 'siret', m.siret, 'reason', v_reason));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. SYSTÈME (clé service_role uniquement)
-- ---------------------------------------------------------------------------

-- Avant d'appeler l'API entreprises : conditions + limite de 5 essais par heure.
create or replace function public.system_siret_precheck(p_user uuid, p_siret text)
returns text
language plpgsql security definer set search_path = public, auth
as $$
declare m public.merchant_profiles;
begin
  if p_siret !~ '^[0-9]{14}$' then raise exception 'invalid_siret'; end if;
  select * into m from public.merchant_profiles where owner_id = p_user for update;
  if not found then raise exception 'no_profile'; end if;
  if not exists (select 1 from auth.users where id = p_user and email_confirmed_at is not null) then
    raise exception 'email_not_confirmed';
  end if;
  if m.verification = 'pending' then raise exception 'request_pending'; end if;
  if m.verification = 'verified' then raise exception 'already_verified'; end if;
  if (select count(*) from public.verification_events
        where merchant_id = m.id and action = 'siret_checked' and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'too_many_attempts';
  end if;
  perform public.log_event(null, m.id, p_user, 'owner', 'siret_checked', jsonb_build_object('last4', right(p_siret, 4)));
  if exists (select 1 from public.siret_blocks where siret = p_siret and owner_id = p_user) then
    return 'siret_blocked';
  end if;
  if exists (select 1 from public.merchant_profiles where siret = p_siret and id <> m.id) then
    return 'siret_already_claimed';
  end if;
  return 'ok';
end;
$$;

-- Garde le résultat du contrôle SIRET pour la demande. N'ATTRIBUE AUCUN badge (même nom qu'avant :
-- l'ancienne version déjà déployée de la fonction serveur continue donc de fonctionner).
create or replace function public.system_set_company_verified(p_user uuid, p_siret text, p_check jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.merchant_profiles where owner_id = p_user) then raise exception 'no_profile'; end if;
  insert into public.siret_checks (user_id, siret, result, checked_at)
  values (p_user, p_siret, p_check, now())
  on conflict (user_id) do update set siret = excluded.siret, result = excluded.result, checked_at = excluded.checked_at;
  return 'recorded';
end;
$$;

-- Effacement des données personnelles des demandes closes (tâche planifiée, tous les jours) :
-- téléphone et lien social 30 jours après un refus ; les demandes approuvées sont conservées.
create or replace function public.purge_request_personal_data()
returns integer
language plpgsql security definer set search_path = public
as $$
declare v_n integer;
begin
  update public.verification_requests
     set phone = null, social_url = null
   where (phone is not null or social_url is not null)
     and ((status in ('rejected', 'rejected_final') and decided_at < now() - interval '30 days')
          or (status = 'cancelled' and created_at < now() - interval '1 day'));
  get diagnostics v_n = row_count;
  delete from public.siret_checks where checked_at < now() - interval '1 day';
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Droits d'exécution
-- ---------------------------------------------------------------------------
revoke all on function public.submit_pro_request(text, text, text, text),
                       public.purge_request_personal_data() from public, anon, authenticated;
grant execute on function public.submit_pro_request(text, text, text, text) to authenticated;
grant execute on function public.purge_request_personal_data() to service_role;

-- Tâche planifiée quotidienne (pg_cron, déjà activé pour le nettoyage des anciennes pièces).
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('purge-request-personal-data', '29 3 * * *', 'select public.purge_request_personal_data();');
  end if;
end $$;
