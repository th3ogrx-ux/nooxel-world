-- ============================================================================
-- Nooxel World — ADMINISTRATION : le code à 6 chiffres n'est plus demandé à chaque connexion.
-- À coller dans Supabase → SQL Editor → Run. Peut être relancé sans danger.
--
-- Avant : un administrateur n'avait AUCUN pouvoir sans la double authentification (aal2).
-- Maintenant : être dans la liste des administrateurs suffit (mot de passe seul).
-- Pour remettre la double authentification obligatoire : relancer le fichier admin-mfa.sql.
-- ============================================================================
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
