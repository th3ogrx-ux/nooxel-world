-- ============================================================================
-- Nooxel World — PHASE 3 : écran « Configurez votre profil » (pseudo obligatoire + photo de profil facultative).
-- À coller dans Supabase → SQL Editor → Run, APRÈS notifications.sql. Peut être relancé sans danger.
--
-- Photo de profil : envoyée dans le stockage « avatars » (dossier = identifiant de la personne), recadrée en carré et réduite
-- dans le navigateur (ce qui retire aussi les métadonnées, position GPS comprise). 1 Mo au plus, JPEG seulement.
-- Seule la personne peut envoyer ou supprimer SA photo. Elle n'est affichée que sur sa propre page Compte pour l'instant.
-- RGPD : photo remplacée ou compte supprimé → le fichier est effacé la nuit suivante (tâche « purge-documents »).
-- ============================================================================

alter table public.user_profiles add column if not exists avatar_path text;
alter table public.user_profiles drop constraint if exists up_avatar;
alter table public.user_profiles add constraint up_avatar check (
  avatar_path is null or (avatar_path like user_id::text || '/%' and avatar_path ~ '^[0-9a-f-]{36}/avatar-[0-9a-f-]{36}\.jpg$'));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists av_owner_insert on storage.objects;
create policy av_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists av_owner_delete on storage.objects;
create policy av_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists av_owner_select on storage.objects;
create policy av_owner_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Enregistrer (ou retirer, avec NULL) SA photo. Renvoie l'ancien chemin : le navigateur supprime l'ancien fichier.
create or replace function public.set_avatar(p_path text)
returns text
language plpgsql security definer set search_path = public, storage
as $$
declare v_old text;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.user_profiles where user_id = auth.uid()) then raise exception 'pseudo_required'; end if;
  if p_path is not null then
    if left(p_path, 37) <> auth.uid()::text || '/' or p_path !~ '^[0-9a-f-]{36}/avatar-[0-9a-f-]{36}\.jpg$' then raise exception 'invalid_file'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'avatars' and name = p_path) then raise exception 'file_not_found'; end if;
  end if;
  select avatar_path into v_old from public.user_profiles where user_id = auth.uid() for update;
  update public.user_profiles set avatar_path = p_path where user_id = auth.uid();
  return v_old;
end;
$$;

-- Résumé du profil (même fonction qu'avant, avec la photo en plus)
create or replace function public.my_profile_summary()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare v_reviews integer; v_follow integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select count(*) into v_reviews from public.reviews where user_id = auth.uid() and status = 'published';
  select count(*) into v_follow from public.follows f join public.merchant_profiles m on m.id = f.merchant_id
   where f.user_id = auth.uid() and m.verification = 'verified';
  return jsonb_build_object(
    'pseudo', (select pseudo from public.user_profiles where user_id = auth.uid()),
    'avatar_path', (select avatar_path from public.user_profiles where user_id = auth.uid()),
    'reviews_count', v_reviews, 'following_count', v_follow, 'points', 0,
    'active_contributor', v_reviews >= 3,
    'member_since', (select created_at from auth.users where id = auth.uid()),
    'can_change_pseudo', coalesce((select pseudo_changed_at <= now() - interval '30 days' from public.user_profiles where user_id = auth.uid()), true));
end;
$$;

-- Photos sans profil (remplacées, ou compte supprimé), plus d'un jour : listées pour être effacées par la tâche de nuit.
create or replace function public.system_orphan_avatars()
returns setof text
language sql stable security definer set search_path = public, storage
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'avatars' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.user_profiles p where p.avatar_path = o.name);
$$;

revoke all on function public.set_avatar(text), public.my_profile_summary(), public.system_orphan_avatars() from public, anon, authenticated;
grant execute on function public.set_avatar(text), public.my_profile_summary() to authenticated;
grant execute on function public.system_orphan_avatars() to service_role;
