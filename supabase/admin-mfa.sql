-- ============================================================================
-- Nooxel World — ÉTAPE 4 : double authentification (TOTP) OBLIGATOIRE pour les administrateurs
-- À coller dans Supabase → SQL Editor → Run, APRÈS les deux fichiers précédents. Relançable sans danger.
--
-- Après ce script, un compte administrateur n'a AUCUN pouvoir tant que sa connexion n'est pas passée
-- en « aal2 » (mot de passe + code à 6 chiffres). C'est vérifié ici, dans la base : la page
-- d'administration ne fait que demander le code, elle ne peut pas être contournée.
-- ============================================================================

-- Est administrateur ET connecté avec la double authentification validée.
-- (Utilisé par toutes les fonctions et règles d'accès existantes.)
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
     and coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- « Suis-je dans la liste des administrateurs ? » (sans exiger le second facteur).
-- Sert uniquement à savoir s'il faut proposer la configuration de la double authentification ;
-- chacun ne peut connaître que SA propre situation.
create or replace function public.am_i_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke all on function public.am_i_admin() from public, anon;
grant execute on function public.am_i_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- EN CAS DE TÉLÉPHONE PERDU (à lancer avec VOTRE email) : supprime le facteur, vous pourrez en
-- configurer un nouveau à la prochaine connexion à /admin.
--
--   delete from auth.mfa_factors
--   where user_id = (select id from auth.users where email = 'votre-email@exemple.com');
-- ---------------------------------------------------------------------------
