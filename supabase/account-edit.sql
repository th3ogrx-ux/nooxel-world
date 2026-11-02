-- ============================================================================
-- Nooxel World — PHASE 3 : écrans « Mon compte », « Modifier mon profil » et « Mes avis laissés ».
-- À coller dans Supabase → SQL Editor → Run, APRÈS likes.sql. Peut être relancé sans danger.
--
-- • Prénom (facultatif) : visible de vous seul pour l'instant (jamais affiché aux autres).
-- • « Télécharger mes données » : un fichier avec tout ce que l'application garde sur vous (droit à la portabilité, RGPD).
-- • Mes avis : on renvoie aussi « j'y suis allé » pour pouvoir modifier un avis sans perdre cette mention.
-- ============================================================================

alter table public.user_profiles add column if not exists first_name text;
alter table public.user_profiles drop constraint if exists up_first_name;
alter table public.user_profiles add constraint up_first_name check (first_name is null or (char_length(first_name) between 1 and 40 and first_name ~ '^[[:alpha:]][[:alpha:] ''’.-]*$'));

create or replace function public.set_first_name(p_name text)
returns text
language plpgsql security definer set search_path = public
as $$
declare v text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.user_profiles where user_id = auth.uid()) then raise exception 'pseudo_required'; end if;
  if v is not null and (char_length(v) > 40 or v !~ '^[[:alpha:]][[:alpha:] ''’.-]*$') then raise exception 'invalid_first_name'; end if;
  update public.user_profiles set first_name = v where user_id = auth.uid();
  return v;
end;
$$;

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
    'first_name', (select first_name from public.user_profiles where user_id = auth.uid()),
    'avatar_path', (select avatar_path from public.user_profiles where user_id = auth.uid()),
    'needs_setup', v_pseudo is null and v_created >= coalesce((select value::timestamptz from public.app_flags where key = 'profile_setup_since'), 'infinity'::timestamptz),
    'reviews_count', v_reviews, 'following_count', v_follow, 'points', 0,
    'active_contributor', v_reviews >= 3,
    'member_since', v_created,
    'can_change_pseudo', coalesce((select pseudo_changed_at <= now() - interval '30 days' from public.user_profiles where user_id = auth.uid()), true),
    'pseudo_change_after', (select pseudo_changed_at + interval '30 days' from public.user_profiles where user_id = auth.uid()));
end;
$$;

create or replace function public.my_reviews(p_before timestamptz default null, p_limit integer default 10)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'rating', x.rating, 'body', x.body, 'visited', x.visited, 'created_at', x.created_at,
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'category', x.category, 'logo_path', x.logo_path,
             'rating_avg', x.rating_avg) order by x.created_at desc, x.id desc)
    from (select r.id, r.rating, r.body, r.visited, r.created_at, r.merchant_id, m.business_name, m.category, m.logo_path,
                 case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end as rating_avg
            from public.reviews r join public.merchant_profiles m on m.id = r.merchant_id
           where r.user_id = auth.uid() and r.status = 'published' and m.verification = 'verified'
             and (p_before is null or r.created_at < p_before)
           order by r.created_at desc, r.id desc limit least(greatest(coalesce(p_limit, 10), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- « Télécharger mes données » : tout ce que l'application garde sur la personne connectée (et rien sur les autres).
create or replace function public.export_my_data()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); m public.merchant_profiles;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where owner_id = v_uid;
  return jsonb_build_object(
    'exporte_le', now(),
    'compte', (select jsonb_build_object('email', u.email, 'cree_le', u.created_at, 'email_confirme_le', u.email_confirmed_at) from auth.users u where u.id = v_uid),
    'profil', (select jsonb_build_object('pseudo', p.pseudo, 'prenom', p.first_name, 'photo', p.avatar_path, 'cree_le', p.created_at) from public.user_profiles p where p.user_id = v_uid),
    'avis', coalesce((select jsonb_agg(jsonb_build_object('commerce', mm.business_name, 'note', r.rating, 'texte', r.body, 'j_y_suis_alle', r.visited, 'statut', r.status, 'date', r.created_at) order by r.created_at)
                        from public.reviews r join public.merchant_profiles mm on mm.id = r.merchant_id where r.user_id = v_uid), '[]'::jsonb),
    'commerces_suivis', coalesce((select jsonb_agg(jsonb_build_object('commerce', mm.business_name, 'depuis', f.created_at) order by f.created_at)
                        from public.follows f join public.merchant_profiles mm on mm.id = f.merchant_id where f.user_id = v_uid), '[]'::jsonb),
    'coeurs_publications', (select count(*) from public.post_likes where user_id = v_uid),
    'coeurs_videos', (select count(*) from public.video_likes where user_id = v_uid),
    'notifications', coalesce((select jsonb_agg(jsonb_build_object('type', n.kind, 'date', n.created_at, 'lue', n.read_at is not null) order by n.created_at)
                        from public.notifications n where n.user_id = v_uid), '[]'::jsonb),
    'signalements_envoyes', coalesce((select jsonb_agg(jsonb_build_object('numero', q.ref, 'type', q.kind, 'motif', q.reason, 'details', q.details, 'statut', q.status, 'date', q.created_at) order by q.created_at)
                        from public.reports q where q.reporter_id = v_uid), '[]'::jsonb),
    'commerce', case when m.id is null then null else jsonb_build_object('nom', m.business_name, 'description', m.description, 'adresse', m.address,
                        'verification', m.verification, 'categorie', m.category, 'site', m.website, 'telephone_public', m.contact_phone, 'horaires', m.opening_hours,
                        'publications', coalesce((select jsonb_agg(jsonb_build_object('texte', p.body, 'photo', p.image_path, 'date', p.created_at) order by p.created_at) from public.merchant_posts p where p.merchant_id = m.id), '[]'::jsonb),
                        'videos', coalesce((select jsonb_agg(jsonb_build_object('legende', v.caption, 'duree_s', v.duration_s, 'date', v.created_at) order by v.created_at) from public.merchant_videos v where v.merchant_id = m.id), '[]'::jsonb)) end);
end;
$$;

revoke all on function public.set_first_name(text), public.my_profile_summary(), public.my_reviews(timestamptz, integer), public.export_my_data() from public, anon, authenticated;
grant execute on function public.set_first_name(text), public.my_profile_summary(), public.my_reviews(timestamptz, integer), public.export_my_data() to authenticated;
