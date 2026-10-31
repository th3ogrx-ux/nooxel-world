-- ============================================================================
-- Nooxel World — l'écran « Configurez votre profil » n'est imposé qu'aux NOUVEAUX comptes.
-- À coller dans Supabase → SQL Editor → Run, APRÈS profile-setup.sql. Peut être relancé sans danger.
--
-- Règle : un compte créé APRÈS le moment où ce script est exécuté, et qui n'a pas encore de pseudo, voit l'écran dès sa
-- première connexion (juste après la confirmation de l'email), avant tout le reste. Les comptes plus anciens ne sont jamais
-- forcés : ils peuvent choisir leur pseudo depuis Compte ou au moment de donner un avis.
-- ============================================================================

create table if not exists public.app_flags (
  key   text primary key,
  value text not null
);
alter table public.app_flags enable row level security;
revoke all on public.app_flags from anon, authenticated;
insert into public.app_flags (key, value) values ('profile_setup_since', now()::text) on conflict (key) do nothing;

create or replace function public.my_profile_summary()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare v_reviews integer; v_follow integer; v_pseudo text; v_created timestamptz;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select count(*) into v_reviews from public.reviews where user_id = auth.uid() and status = 'published';
  select count(*) into v_follow from public.follows f join public.merchant_profiles m on m.id = f.merchant_id
   where f.user_id = auth.uid() and m.verification = 'verified';
  select pseudo into v_pseudo from public.user_profiles where user_id = auth.uid();
  select created_at into v_created from auth.users where id = auth.uid();
  return jsonb_build_object(
    'pseudo', v_pseudo,
    'avatar_path', (select avatar_path from public.user_profiles where user_id = auth.uid()),
    'needs_setup', v_pseudo is null and v_created >= coalesce((select value::timestamptz from public.app_flags where key = 'profile_setup_since'), 'infinity'::timestamptz),
    'reviews_count', v_reviews, 'following_count', v_follow, 'points', 0,
    'active_contributor', v_reviews >= 3,
    'member_since', v_created,
    'can_change_pseudo', coalesce((select pseudo_changed_at <= now() - interval '30 days' from public.user_profiles where user_id = auth.uid()), true));
end;
$$;

revoke all on function public.my_profile_summary() from public, anon, authenticated;
grant execute on function public.my_profile_summary() to authenticated;
