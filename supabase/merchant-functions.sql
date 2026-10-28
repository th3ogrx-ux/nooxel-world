-- ============================================================================
-- Nooxel World — vérification des comptes commerçants
-- ÉTAPE 2 : fonctions serveur (à lancer APRÈS merchant-verification.sql).
-- À coller dans Supabase → SQL Editor → Run. Peut être relancé sans danger.
--
-- Trois familles de fonctions :
--   • Commerçant  : exécutables par un utilisateur connecté, qui ne peut agir que sur SON profil.
--   • Admin       : refusent tout appelant qui n'est pas dans la table `admins` ('forbidden').
--   • Système     : réservées au serveur (clé « service_role »), jamais appelables depuis l'appli.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Mise à jour de la structure du schéma (si l'étape 1 avait déjà été lancée)
-- ---------------------------------------------------------------------------
alter table public.verification_requests drop constraint if exists profile_needs_docs;
alter table public.verification_requests add constraint profile_needs_docs
  check (kind <> 'profile' or status = 'cancelled' or docs_deleted_at is not null
         or (id_doc_path is not null and selfie_path is not null));

-- Un SIRET révoqué ne peut plus être revalidé automatiquement par le compte qui l'a perdu.
create table if not exists public.siret_blocks (
  siret      text not null check (siret ~ '^[0-9]{14}$'),
  owner_id   uuid not null references auth.users(id) on delete cascade,
  reason     text,
  created_at timestamptz not null default now(),
  primary key (siret, owner_id)
);
alter table public.siret_blocks enable row level security;
revoke all on public.siret_blocks from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Outils internes
-- ---------------------------------------------------------------------------
create or replace function public.require_admin()
returns void language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.log_event(
  p_request uuid, p_merchant uuid, p_actor uuid, p_role text, p_action text, p_detail jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public
as $$
  insert into public.verification_events (request_id, merchant_id, actor_id, actor_role, action, detail)
  values (p_request, p_merchant, p_actor, p_role, p_action, coalesce(p_detail, '{}'::jsonb));
$$;

create or replace function public.gen_referral_code()
returns text language plpgsql as $$
declare c text;
begin
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.merchant_profiles where referral_code = c);
  end loop;
  return c;
end;
$$;

-- Trace automatique de la création d'un profil
create or replace function public.on_profile_created()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public.log_event(null, new.id, new.owner_id, 'owner', 'profile_created', jsonb_build_object('name', new.business_name));
  return new;
end;
$$;
drop trigger if exists merchant_profiles_created on public.merchant_profiles;
create trigger merchant_profiles_created after insert on public.merchant_profiles
  for each row execute function public.on_profile_created();

-- ---------------------------------------------------------------------------
-- 2. COMMERÇANT
-- ---------------------------------------------------------------------------

-- Dépôt d'une demande « profil confirmé » (niveau 2) : pièce d'identité + photo déjà envoyées
-- dans le stockage privé, dans le dossier de l'utilisateur.
create or replace function public.submit_profile_confirmation(
  p_social_url text, p_referral_code text, p_id_path text, p_selfie_path text)
returns uuid
language plpgsql security definer set search_path = public, auth, storage
as $$
declare
  v_uid uuid := auth.uid();
  m public.merchant_profiles;
  v_ref uuid;
  v_code text;
  v_req uuid;
  v_prefix text;
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

  v_prefix := v_uid::text || '/';
  if p_id_path is null or p_selfie_path is null or p_id_path = p_selfie_path then raise exception 'documents_required'; end if;
  if left(p_id_path, length(v_prefix)) <> v_prefix or left(p_selfie_path, length(v_prefix)) <> v_prefix then
    raise exception 'invalid_document_path';
  end if;
  if (select count(*) from storage.objects
        where bucket_id = 'verification-docs' and name in (p_id_path, p_selfie_path)) <> 2 then
    raise exception 'documents_not_found';
  end if;

  v_code := nullif(upper(trim(coalesce(p_referral_code, ''))), '');
  if v_code is not null then
    select id into v_ref from public.merchant_profiles
      where referral_code = v_code and verification = 'company_verified' and id <> m.id;
    if v_ref is null then raise exception 'invalid_referral_code'; end if;
  end if;

  insert into public.verification_requests
    (merchant_id, kind, social_url, referral_code_used, referrer_id, id_doc_path, selfie_path, docs_delete_after)
  values
    (m.id, 'profile', nullif(trim(p_social_url), ''), v_code, v_ref, p_id_path, p_selfie_path, now() + interval '90 days')
  returning id into v_req;

  update public.merchant_profiles
     set verification = 'pending',
         social_url = coalesce(nullif(trim(p_social_url), ''), social_url),
         referred_by = v_ref
   where id = m.id;

  perform public.log_event(v_req, m.id, v_uid, 'owner', 'submitted',
    jsonb_build_object('kind', 'profile', 'referral', v_ref is not null, 'social', nullif(trim(p_social_url), '') is not null));
  return v_req;
end;
$$;

-- Annulation par le commerçant (les pièces sont supprimées à la prochaine passe de nettoyage).
create or replace function public.cancel_verification(p_request_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare r public.verification_requests; m public.merchant_profiles;
begin
  select r2.* into r from public.verification_requests r2
    join public.merchant_profiles m2 on m2.id = r2.merchant_id
   where r2.id = p_request_id and m2.owner_id = auth.uid() for update of r2;
  if not found then raise exception 'not_found'; end if;
  if r.status not in ('pending', 'contested') then raise exception 'not_cancellable'; end if;

  update public.verification_requests set status = 'cancelled', docs_delete_after = now() where id = r.id;
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
  if r.decided_at < now() - interval '30 days' then raise exception 'contest_window_closed'; end if;
  if r.docs_deleted_at is not null and r.kind = 'profile' then raise exception 'documents_already_deleted'; end if;
  if char_length(trim(coalesce(p_message, ''))) < 10 then raise exception 'message_too_short'; end if;
  if exists (select 1 from public.verification_requests
              where merchant_id = r.merchant_id and status in ('pending', 'contested')) then
    raise exception 'another_request_open';
  end if;

  update public.verification_requests
     set status = 'contested', contest_message = left(trim(p_message), 2000), contested_at = now(),
         docs_delete_after = greatest(coalesce(docs_delete_after, now()), now() + interval '30 days')
   where id = r.id;
  update public.merchant_profiles set verification = 'pending' where id = r.merchant_id;
  perform public.log_event(r.id, r.merchant_id, auth.uid(), 'owner', 'contested', '{}'::jsonb);
end;
$$;

-- Effacement à la demande : annule les demandes en cours et programme la suppression immédiate des pièces.
create or replace function public.erase_my_documents()
returns integer
language plpgsql security definer set search_path = public
as $$
declare v_n integer := 0; r record;
begin
  for r in
    select q.id, q.merchant_id, q.status from public.verification_requests q
      join public.merchant_profiles m on m.id = q.merchant_id
     where m.owner_id = auth.uid() and q.docs_deleted_at is null
       and (q.id_doc_path is not null or q.selfie_path is not null)
  loop
    update public.verification_requests
       set docs_delete_after = now(),
           status = case when status in ('pending', 'contested') then 'cancelled' else status end
     where id = r.id;
    if r.status in ('pending', 'contested') then
      update public.merchant_profiles set verification = 'none' where id = r.merchant_id and verification = 'pending';
    end if;
    perform public.log_event(r.id, r.merchant_id, auth.uid(), 'owner', 'documents_deleted', jsonb_build_object('requested_by_owner', true));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- Statut visible par l'utilisateur : niveau, demande en cours, motif d'un refus, historique.
-- (Aucune identité d'administrateur n'est exposée.)
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
      'badge', case m.verification when 'company_verified' then 'entreprise vérifiée' when 'profile_confirmed' then 'profil confirmé' end,
      'can_receive_reviews', m.verification in ('company_verified', 'profile_confirmed'),
      'referral_code', m.referral_code,
      'request', (
        select jsonb_build_object(
          'id', q.id, 'kind', q.kind, 'status', q.status, 'created_at', q.created_at,
          'decided_at', q.decided_at, 'decision_reason', q.decision_reason,
          'contested_at', q.contested_at,
          'can_contest', (q.status = 'rejected' and q.contested_at is null
                          and q.decided_at > now() - interval '30 days' and q.docs_deleted_at is null),
          'docs_delete_after', q.docs_delete_after, 'docs_deleted_at', q.docs_deleted_at)
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
-- 3. ADMINISTRATEUR
-- ---------------------------------------------------------------------------

-- File de validation. p_status : 'to_review' (en attente + contestées), 'pending', 'contested',
-- 'approved', 'rejected', 'rejected_final', 'all'.
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
        'social_url', q.social_url, 'siret', q.siret, 'siret_check', q.siret_check,
        'contest_message', q.contest_message, 'contested_at', q.contested_at,
        'decision_reason', q.decision_reason, 'decided_at', q.decided_at,
        'docs_deleted_at', q.docs_deleted_at, 'docs_delete_after', q.docs_delete_after,
        'has_documents', (q.docs_deleted_at is null and q.id_doc_path is not null),
        'merchant', jsonb_build_object('id', m.id, 'business_name', m.business_name,
                                       'description', m.description, 'verification', m.verification),
        'owner_email', u.email, 'email_confirmed', u.email_confirmed_at is not null,
        'referrer', case when q.referrer_id is null then null else jsonb_build_object(
          'business_name', rm.business_name, 'verification', rm.verification) end,
        'previous_requests', (select count(*) from public.verification_requests o
                               where o.merchant_id = q.merchant_id and o.id <> q.id)
      ) as x
      from public.verification_requests q
      join public.merchant_profiles m on m.id = q.merchant_id
      join auth.users u on u.id = m.owner_id
      left join public.merchant_profiles rm on rm.id = q.referrer_id
      where q.kind = 'profile' and (
            (p_status = 'to_review' and q.status in ('pending', 'contested'))
         or (p_status = 'all')
         or (p_status = q.status))
      order by q.created_at asc limit 200) t), '[]'::jsonb);
end;
$$;

-- Recherche d'un commerçant (pour pouvoir révoquer).
create or replace function public.admin_list_merchants(p_query text default null)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
begin
  perform public.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'business_name', m.business_name, 'siret', m.siret, 'verification', m.verification,
      'verified_at', m.verified_at, 'owner_email', u.email, 'created_at', m.created_at)
      order by m.created_at desc)
    from (select * from public.merchant_profiles mm
           where p_query is null or trim(p_query) = ''
              or mm.business_name ilike '%' || trim(p_query) || '%' or mm.siret = trim(p_query)
              or mm.owner_id in (select id from auth.users where email ilike '%' || trim(p_query) || '%')
           order by mm.created_at desc limit 100) m
    join auth.users u on u.id = m.owner_id), '[]'::jsonb);
end;
$$;

-- Décision sur une demande en attente.
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
    update public.verification_requests
       set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_reason = v_reason,
           docs_delete_after = now() + interval '30 days'
     where id = r.id;
    update public.merchant_profiles
       set verification = case r.kind when 'company' then 'company_verified' else 'profile_confirmed' end,
           verified_at = now()
     where id = m.id;
    perform public.log_event(r.id, m.id, auth.uid(), 'admin', 'approved', jsonb_build_object('kind', r.kind, 'reason', v_reason));
  else
    update public.verification_requests
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_reason = v_reason,
           docs_delete_after = now() + interval '30 days'
     where id = r.id;
    update public.merchant_profiles set verification = 'none' where id = m.id;
    perform public.log_event(r.id, m.id, auth.uid(), 'admin', 'rejected', jsonb_build_object('kind', r.kind, 'reason', v_reason));
  end if;
end;
$$;

-- Décision sur une contestation. Si plusieurs administrateurs existent, ce doit être un AUTRE
-- que celui qui a refusé (regard neuf). p_approve = true : la contestation est acceptée.
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
    update public.verification_requests
       set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_reason = v_reason,
           docs_delete_after = now() + interval '7 days'
     where id = r.id;
    update public.merchant_profiles
       set verification = case r.kind when 'company' then 'company_verified' else 'profile_confirmed' end,
           verified_at = now()
     where id = m.id;
    perform public.log_event(r.id, m.id, auth.uid(), 'admin', 'contest_upheld', jsonb_build_object('reason', v_reason));
  else
    update public.verification_requests
       set status = 'rejected_final', decided_by = auth.uid(), decided_at = now(), decision_reason = v_reason,
           docs_delete_after = now() + interval '7 days'
     where id = r.id;
    update public.merchant_profiles set verification = 'none' where id = m.id;
    perform public.log_event(r.id, m.id, auth.uid(), 'admin', 'contest_dismissed', jsonb_build_object('reason', v_reason));
  end if;
end;
$$;

-- Autorise (et journalise) la consultation d'une pièce. Renvoie le chemin du fichier ; c'est la
-- fonction serveur « admin-document-url » qui crée ensuite le lien de 60 secondes.
create or replace function public.admin_authorize_document_access(p_request_id uuid, p_which text)
returns text
language plpgsql security definer set search_path = public
as $$
declare r public.verification_requests; v_path text;
begin
  perform public.require_admin();
  if p_which not in ('id', 'selfie') then raise exception 'invalid_document'; end if;
  select * into r from public.verification_requests where id = p_request_id;
  if not found then raise exception 'not_found'; end if;
  if r.docs_deleted_at is not null then raise exception 'documents_deleted'; end if;
  v_path := case p_which when 'id' then r.id_doc_path else r.selfie_path end;
  if v_path is null then raise exception 'documents_deleted'; end if;
  perform public.log_event(r.id, r.merchant_id, auth.uid(), 'admin', 'document_viewed', jsonb_build_object('which', p_which));
  return v_path;
end;
$$;

-- RÉVOCATION : retire le badge, libère le SIRET (pour son vrai propriétaire), supprime le code de
-- parrainage, annule les demandes ouvertes, et empêche le compte révoqué de revalider ce SIRET
-- automatiquement. Tout est journalisé.
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
  if m.verification not in ('company_verified', 'profile_confirmed') then raise exception 'nothing_to_revoke'; end if;

  if m.siret is not null then
    insert into public.siret_blocks (siret, owner_id, reason) values (m.siret, m.owner_id, v_reason)
    on conflict do nothing;
  end if;
  update public.verification_requests
     set status = 'cancelled', docs_delete_after = now()
   where merchant_id = m.id and status in ('pending', 'contested');
  update public.merchant_profiles
     set verification = 'none', verified_at = null, siret = null, referral_code = null
   where id = m.id;
  perform public.log_event(null, m.id, auth.uid(), 'admin', 'revoked',
    jsonb_build_object('previous', m.verification, 'siret', m.siret, 'reason', v_reason));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. SYSTÈME (clé service_role uniquement : fonctions serveur et tâche planifiée)
-- ---------------------------------------------------------------------------

-- Avant d'appeler l'API entreprises : vérifie les conditions et limite les essais (5 par heure).
-- Renvoie 'ok', ou 'siret_blocked' / 'siret_already_claimed' SANS lever d'erreur : une erreur
-- annulerait l'enregistrement de la tentative, et un fraudeur pourrait alors tester des SIRET sans limite.
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
  if m.verification = 'company_verified' then raise exception 'already_verified'; end if;
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

-- Après un contrôle réussi : passe le profil au niveau 1 et crée son code de parrainage.
create or replace function public.system_set_company_verified(p_user uuid, p_siret text, p_check jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
declare m public.merchant_profiles; v_req uuid; v_code text;
begin
  select * into m from public.merchant_profiles where owner_id = p_user for update;
  if not found then raise exception 'no_profile'; end if;
  if exists (select 1 from public.siret_blocks where siret = p_siret and owner_id = p_user) then raise exception 'siret_blocked'; end if;
  begin
    insert into public.verification_requests (merchant_id, kind, status, siret, siret_check, decided_at, decision_reason)
    values (m.id, 'company', 'approved', p_siret, p_check, now(), 'Vérification automatique du SIRET')
    returning id into v_req;
    v_code := coalesce(m.referral_code, public.gen_referral_code());
    update public.merchant_profiles
       set siret = p_siret, verification = 'company_verified', verified_at = now(), referral_code = v_code
     where id = m.id;
  exception when unique_violation then
    raise exception 'siret_already_claimed';
  end;
  perform public.log_event(v_req, m.id, p_user, 'system', 'approved',
    jsonb_build_object('kind', 'company', 'source', 'recherche-entreprises.api.gouv.fr', 'last4', right(p_siret, 4)));
  return v_code;
end;
$$;

-- Demandes dont les pièces doivent être supprimées (échéance atteinte).
create or replace function public.system_purge_candidates()
returns table (request_id uuid, id_doc_path text, selfie_path text)
language sql stable security definer set search_path = public
as $$
  select id, id_doc_path, selfie_path from public.verification_requests
   where docs_deleted_at is null and docs_delete_after is not null and docs_delete_after <= now()
     and (id_doc_path is not null or selfie_path is not null);
$$;

-- Marque les pièces comme supprimées (après suppression réelle des fichiers). Une demande restée
-- « en attente » au-delà de 90 jours est annulée.
create or replace function public.system_mark_docs_deleted(p_ids uuid[])
returns integer
language plpgsql security definer set search_path = public
as $$
declare r record; v_n integer := 0;
begin
  for r in select id, merchant_id, status from public.verification_requests
            where id = any(p_ids) and docs_deleted_at is null for update
  loop
    update public.verification_requests
       set docs_deleted_at = now(), id_doc_path = null, selfie_path = null,
           status = case when status in ('pending', 'contested') then 'cancelled' else status end
     where id = r.id;
    if r.status in ('pending', 'contested') then
      update public.merchant_profiles set verification = 'none' where id = r.merchant_id and verification = 'pending';
    end if;
    perform public.log_event(r.id, r.merchant_id, null, 'system', 'documents_deleted', jsonb_build_object('reason', 'retention'));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- Fichiers sans demande associée depuis plus d'un jour (téléversement abandonné, compte supprimé…).
create or replace function public.system_orphan_files()
returns setof text
language sql stable security definer set search_path = public, storage
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'verification-docs' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.verification_requests q where q.id_doc_path = o.name or q.selfie_path = o.name);
$$;

-- ---------------------------------------------------------------------------
-- 5. DROITS D'EXÉCUTION (par défaut Postgres autorise tout le monde : on referme tout)
-- ---------------------------------------------------------------------------
revoke all on function
  public.require_admin(), public.gen_referral_code(),
  public.log_event(uuid, uuid, uuid, text, text, jsonb),
  public.on_profile_created(),
  public.submit_profile_confirmation(text, text, text, text), public.cancel_verification(uuid),
  public.contest_verification(uuid, text), public.erase_my_documents(), public.my_verification_status(),
  public.admin_list_requests(text), public.admin_list_merchants(text), public.admin_decide(uuid, boolean, text),
  public.admin_decide_contest(uuid, boolean, text), public.admin_authorize_document_access(uuid, text),
  public.admin_revoke(uuid, text),
  public.system_siret_precheck(uuid, text), public.system_set_company_verified(uuid, text, jsonb),
  public.system_purge_candidates(), public.system_mark_docs_deleted(uuid[]), public.system_orphan_files()
from public, anon, authenticated;

grant execute on function
  public.submit_profile_confirmation(text, text, text, text), public.cancel_verification(uuid),
  public.contest_verification(uuid, text), public.erase_my_documents(), public.my_verification_status(),
  public.admin_list_requests(text), public.admin_list_merchants(text), public.admin_decide(uuid, boolean, text),
  public.admin_decide_contest(uuid, boolean, text), public.admin_authorize_document_access(uuid, text),
  public.admin_revoke(uuid, text)
to authenticated;

grant execute on function
  public.system_siret_precheck(uuid, text), public.system_set_company_verified(uuid, text, jsonb),
  public.system_purge_candidates(), public.system_mark_docs_deleted(uuid[]), public.system_orphan_files()
to service_role;
