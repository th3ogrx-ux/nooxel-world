-- ============================================================================
-- Nooxel World — vérification des comptes commerçants
-- ÉTAPE 1 : schéma de données, sécurité (RLS), journal d'audit, stockage privé.
-- À coller dans Supabase → SQL Editor → Run. Peut être relancé sans danger.
--
-- Principe de sécurité : le navigateur n'écrit JAMAIS directement le statut de
-- vérification, les justificatifs, ni le journal. Il ne peut que créer / modifier
-- les champs « texte » de SON profil. Tout le reste passera par des fonctions
-- serveur (étape 2) qui vérifient l'identité de l'appelant.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Administrateurs
--    Aucune règle d'accès : personne ne peut lire ni écrire cette table depuis
--    l'application. On y ajoute un admin à la main (voir tout en bas).
-- ---------------------------------------------------------------------------
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Profils commerçants (compte professionnel)
--    Niveau 3 = 'none' (créable sans justificatif)
--    En attente = 'pending'
--    Niveau 1  = 'company_verified'  → badge « entreprise vérifiée »
--    Niveau 2  = 'profile_confirmed' → badge « profil confirmé »
-- ---------------------------------------------------------------------------
create table if not exists public.merchant_profiles (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null unique references auth.users(id) on delete cascade,
  business_name text not null check (char_length(business_name) between 2 and 120),
  description   text check (char_length(description) <= 1000),
  social_url    text check (social_url ~* '^https://([a-z0-9-]+\.)?(instagram\.com|facebook\.com|tiktok\.com)/[^\s]*$'),
  -- renseignés UNIQUEMENT par le serveur :
  siret         text unique check (siret ~ '^[0-9]{14}$'),
  verification  text not null default 'none'
                check (verification in ('none', 'pending', 'company_verified', 'profile_confirmed')),
  verified_at   timestamptz,
  referral_code text unique,
  referred_by   uuid references public.merchant_profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
drop trigger if exists merchant_profiles_touch on public.merchant_profiles;
create trigger merchant_profiles_touch before update on public.merchant_profiles
  for each row execute function public.touch_updated_at();

alter table public.merchant_profiles enable row level security;

-- Droits au niveau des colonnes : le navigateur ne peut écrire QUE ces champs.
revoke all on public.merchant_profiles from anon, authenticated;
grant select, delete on public.merchant_profiles to authenticated;
grant insert (owner_id, business_name, description, social_url) on public.merchant_profiles to authenticated;
grant update (business_name, description, social_url) on public.merchant_profiles to authenticated;

drop policy if exists mp_select on public.merchant_profiles;
create policy mp_select on public.merchant_profiles for select to authenticated
  using (owner_id = auth.uid() or public.is_admin());

drop policy if exists mp_insert on public.merchant_profiles;
create policy mp_insert on public.merchant_profiles for insert to authenticated
  with check (owner_id = auth.uid());

drop policy if exists mp_update on public.merchant_profiles;
create policy mp_update on public.merchant_profiles for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists mp_delete on public.merchant_profiles;
create policy mp_delete on public.merchant_profiles for delete to authenticated
  using (owner_id = auth.uid());

-- Vue publique : uniquement ce qui peut être montré à tout le monde (aucun identifiant de compte,
-- pas de SIRET, pas de lien de réseau social tant que non vérifié).
create or replace view public.public_merchants as
select
  id,
  business_name,
  description,
  case verification
    when 'company_verified'  then 'entreprise vérifiée'
    when 'profile_confirmed' then 'profil confirmé'
    else null
  end as badge,
  verification in ('company_verified', 'profile_confirmed') as can_receive_reviews,
  case verification when 'company_verified' then 2 when 'profile_confirmed' then 1 else 0 end as visibility_rank,
  case when verification in ('company_verified', 'profile_confirmed') then social_url end as social_url
from public.merchant_profiles;
grant select on public.public_merchants to anon, authenticated;

-- Pour la future table d'avis : « pas d'avis tant que non vérifié ».
create or replace function public.merchant_can_receive_reviews(m uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce((select verification in ('company_verified', 'profile_confirmed')
                   from public.merchant_profiles where id = m), false);
$$;
grant execute on function public.merchant_can_receive_reviews(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Demandes de vérification
--    Le navigateur ne peut PAS écrire ici directement (aucun droit d'écriture) :
--    tout passera par des fonctions serveur (étape 2).
-- ---------------------------------------------------------------------------
create table if not exists public.verification_requests (
  id                uuid primary key default gen_random_uuid(),
  merchant_id       uuid not null references public.merchant_profiles(id) on delete cascade,
  kind              text not null check (kind in ('company', 'profile')),
  status            text not null default 'pending'
                    check (status in ('pending', 'approved', 'rejected', 'contested', 'rejected_final', 'cancelled')),
  -- données soumises
  siret             text check (siret ~ '^[0-9]{14}$'),
  siret_check       jsonb,                     -- réponse de l'API entreprises (écrite par le serveur)
  social_url        text,
  referral_code_used text,
  referrer_id       uuid references public.merchant_profiles(id) on delete set null,
  id_doc_path       text,                      -- chemin dans le stockage PRIVÉ
  selfie_path       text,
  -- décision
  decided_by        uuid references auth.users(id) on delete set null,
  decided_at        timestamptz,
  decision_reason   text check (char_length(decision_reason) <= 1000),
  -- contestation (une seule par demande)
  contest_message   text check (char_length(contest_message) <= 2000),
  contested_at      timestamptz,
  -- RGPD : suppression programmée des pièces
  docs_delete_after timestamptz,
  docs_deleted_at   timestamptz,
  created_at        timestamptz not null default now(),
  -- une demande « profil » doit contenir la pièce et la photo
  constraint profile_needs_docs check (kind <> 'profile' or status = 'cancelled' or docs_deleted_at is not null or (id_doc_path is not null and selfie_path is not null)),
  -- une demande « entreprise » doit contenir un SIRET
  constraint company_needs_siret check (kind <> 'company' or siret is not null)
);
-- une seule demande ouverte à la fois par commerçant
create unique index if not exists one_open_request_per_merchant
  on public.verification_requests (merchant_id) where status in ('pending', 'contested');
create index if not exists vr_docs_to_purge
  on public.verification_requests (docs_delete_after) where docs_deleted_at is null and docs_delete_after is not null;

alter table public.verification_requests enable row level security;
revoke all on public.verification_requests from anon, authenticated;
grant select on public.verification_requests to authenticated;

drop policy if exists vr_select on public.verification_requests;
create policy vr_select on public.verification_requests for select to authenticated
  using (
    public.is_admin()
    or exists (select 1 from public.merchant_profiles m where m.id = merchant_id and m.owner_id = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- 4. Journal d'audit : horodaté, jamais modifiable ni supprimable
-- ---------------------------------------------------------------------------
create table if not exists public.verification_events (
  id          bigint generated always as identity primary key,
  request_id  uuid references public.verification_requests(id) on delete set null,
  merchant_id uuid references public.merchant_profiles(id) on delete set null,
  actor_id    uuid references auth.users(id) on delete set null,
  actor_role  text not null check (actor_role in ('owner', 'admin', 'system')),
  action      text not null check (action in (
                'profile_created', 'siret_checked', 'submitted', 'cancelled', 'approved', 'rejected',
                'contested', 'contest_upheld', 'contest_dismissed', 'document_viewed',
                'documents_deleted', 'revoked')),
  detail      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- Immuable : on refuse toute suppression et toute modification, SAUF la mise à NULL
-- des liens quand un compte est supprimé (droit à l'effacement), qui est une opération technique.
create or replace function public.events_are_immutable()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'verification_events est en ajout seul';
  end if;
  if new.id is distinct from old.id or new.actor_role is distinct from old.actor_role
     or new.action is distinct from old.action or new.detail is distinct from old.detail
     or new.created_at is distinct from old.created_at then
    raise exception 'verification_events est en ajout seul';
  end if;
  return new;
end;
$$;
drop trigger if exists events_immutable on public.verification_events;
create trigger events_immutable before update or delete on public.verification_events
  for each row execute function public.events_are_immutable();

alter table public.verification_events enable row level security;
revoke all on public.verification_events from anon, authenticated;
grant select on public.verification_events to authenticated;

drop policy if exists ve_select on public.verification_events;
create policy ve_select on public.verification_events for select to authenticated
  using (
    public.is_admin()
    or exists (select 1 from public.merchant_profiles m where m.id = merchant_id and m.owner_id = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- 5. Stockage PRIVÉ des justificatifs
--    - un utilisateur peut déposer, voir et supprimer SES fichiers (dossier = son identifiant).
--      (La lecture de son propre dossier est nécessaire pour pouvoir les supprimer : droit à l'effacement.)
--    - aucun autre utilisateur, ni aucun administrateur, ne peut les lire depuis l'application :
--      seul le serveur (Edge Function, étape 2) génère un lien de 60 secondes pour un
--      administrateur, en le journalisant ("document_viewed").
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verification-docs', 'verification-docs', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists vdocs_owner_insert on storage.objects;
create policy vdocs_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists vdocs_owner_select on storage.objects;
create policy vdocs_owner_select on storage.objects for select to authenticated
  using (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists vdocs_owner_delete on storage.objects;
create policy vdocs_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------------
-- 6. Vous donner les droits d'administrateur (À FAIRE UNE FOIS, avec VOTRE email) :
--
--    insert into public.admins (user_id)
--    select id from auth.users where email = 'votre-email@exemple.com';
-- ---------------------------------------------------------------------------
