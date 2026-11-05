-- Nooxel World — Profil privé/public, profil public d'un utilisateur, signalement de profil, suppression d'avis par l'admin
-- À coller dans Supabase → SQL Editor → Run, APRÈS reports.sql, account-edit.sql et closure-and-video-filter.sql. Peut être relancé sans danger.

-- 1. Profil privé / public (public par défaut : rien ne change pour les comptes existants)
alter table public.user_profiles add column if not exists is_private boolean not null default false;

create or replace function public.set_profile_privacy(p_private boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_private is null then raise exception 'invalid_value'; end if;
  if exists (select 1 from public.merchant_profiles where owner_id = auth.uid()) then raise exception 'merchant_account'; end if;
  update public.user_profiles set is_private = p_private where user_id = auth.uid();
  if not found then raise exception 'profile_missing'; end if;
end;
$$;

-- 2. « Mon profil » : ajoute is_private
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
    'is_private', coalesce((select is_private from public.user_profiles where user_id = auth.uid()), false),
    'needs_setup', v_pseudo is null and v_created >= coalesce((select value::timestamptz from public.app_flags where key = 'profile_setup_since'), 'infinity'::timestamptz),
    'reviews_count', v_reviews, 'following_count', v_follow, 'points', 0,
    'active_contributor', v_reviews >= 3,
    'member_since', v_created,
    'can_change_pseudo', coalesce((select pseudo_changed_at <= now() - interval '30 days' from public.user_profiles where user_id = auth.uid()), true),
    'pseudo_change_after', (select pseudo_changed_at + interval '30 days' from public.user_profiles where user_id = auth.uid()));
end;
$$;

-- 3. Profil public d'un autre utilisateur (par pseudo). Privé : seuls le pseudo et la photo sont visibles.
create or replace function public.get_user_page(p_pseudo text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare u public.user_profiles; v_self boolean; v_visible boolean; v_reviews integer; v_follow integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into u from public.user_profiles where lower(pseudo) = lower(coalesce(p_pseudo, ''));
  if not found then raise exception 'not_found'; end if;
  v_self := u.user_id = auth.uid(); v_visible := v_self or not u.is_private;
  if v_visible then
    select count(*) into v_reviews from public.reviews r join public.merchant_profiles m on m.id = r.merchant_id
     where r.user_id = u.user_id and r.status = 'published' and m.verification = 'verified';
    select count(*) into v_follow from public.follows f join public.merchant_profiles m on m.id = f.merchant_id
     where f.user_id = u.user_id and m.verification = 'verified';
  end if;
  return jsonb_build_object('pseudo', u.pseudo, 'avatar_path', u.avatar_path, 'is_self', v_self, 'is_private', u.is_private and not v_self,
    'reviews_count', v_reviews, 'following_count', v_follow, 'active_contributor', case when v_visible then v_reviews >= 3 end);
end;
$$;

create or replace function public.user_reviews(p_pseudo text, p_before timestamptz default null, p_limit integer default 10)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare u public.user_profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into u from public.user_profiles where lower(pseudo) = lower(coalesce(p_pseudo, ''));
  if not found then raise exception 'not_found'; end if;
  if u.is_private and u.user_id <> auth.uid() then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'rating', x.rating, 'body', x.body, 'created_at', x.created_at,
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'category', x.category, 'logo_path', x.logo_path,
             'rating_avg', x.rating_avg) order by x.created_at desc, x.id desc)
    from (select r.id, r.rating, r.body, r.created_at, r.merchant_id, m.business_name, m.category, m.logo_path,
                 case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end as rating_avg
            from public.reviews r join public.merchant_profiles m on m.id = r.merchant_id
           where r.user_id = u.user_id and r.status = 'published' and m.verification = 'verified'
             and (p_before is null or r.created_at < p_before)
           order by r.created_at desc, r.id desc limit least(greatest(coalesce(p_limit, 10), 1), 30)) x), '[]'::jsonb);
end;
$$;

create or replace function public.user_following(p_pseudo text, p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare u public.user_profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into u from public.user_profiles where lower(pseudo) = lower(coalesce(p_pseudo, ''));
  if not found then raise exception 'not_found'; end if;
  if u.is_private and u.user_id <> auth.uid() then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('merchant_id', x.merchant_id, 'business_name', x.business_name, 'category', x.category,
             'logo_path', x.logo_path, 'cover_path', x.cover_path, 'rating_avg', x.rating_avg, 'review_count', x.review_count,
             'followed_at', x.followed_at) order by x.followed_at desc, x.merchant_id)
    from (select f.merchant_id, f.created_at as followed_at, m.business_name, m.category, m.logo_path, m.cover_path, m.review_count,
                 case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end as rating_avg
            from public.follows f join public.merchant_profiles m on m.id = f.merchant_id
           where f.user_id = u.user_id and m.verification = 'verified' and (p_before is null or f.created_at < p_before)
           order by f.created_at desc, f.merchant_id limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- 4. Signalements : nouveau type « profil d'utilisateur » et nouveau motif « faux compte »
alter table public.reports add column if not exists target_user uuid references auth.users(id) on delete set null;
alter table public.reports drop constraint if exists reports_kind_check;
alter table public.reports add constraint reports_kind_check check (kind in ('merchant', 'review', 'app', 'user'));
alter table public.reports drop constraint if exists reports_reason_check;
alter table public.reports add constraint reports_reason_check check (reason in ('false_info', 'fake_account', 'scam', 'inappropriate', 'other', 'bug'));

-- (la fonction existante accepte aussi « faux compte » pour une page de commerce)
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
  if (p_kind = 'app' and p_reason not in ('bug', 'other')) or (p_kind <> 'app' and p_reason not in ('false_info', 'fake_account', 'scam', 'inappropriate', 'other')) then
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

create or replace function public.submit_user_report(p_pseudo text, p_reason text, p_details text default null)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); v_details text := nullif(btrim(coalesce(p_details, '')), ''); u public.user_profiles; v_id uuid; v_ref bigint;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from auth.users where id = v_uid and email_confirmed_at is not null) then raise exception 'email_not_confirmed'; end if;
  if p_reason not in ('fake_account', 'scam', 'inappropriate', 'other') then raise exception 'invalid_reason'; end if;
  if v_details is not null and char_length(v_details) > 1000 then raise exception 'details_too_long'; end if;
  if p_reason = 'other' and char_length(coalesce(v_details, '')) < 10 then raise exception 'details_required'; end if;
  if (select count(*) from public.reports where reporter_id = v_uid and created_at > now() - interval '24 hours') >= 10 then raise exception 'too_many_reports'; end if;
  select * into u from public.user_profiles where lower(pseudo) = lower(coalesce(p_pseudo, ''));
  if not found then raise exception 'not_found'; end if;
  if u.user_id = v_uid then raise exception 'own_profile'; end if;
  if exists (select 1 from public.reports where reporter_id = v_uid and status = 'open' and kind = 'user' and target_user = u.user_id) then raise exception 'already_reported'; end if;
  insert into public.reports (reporter_id, kind, target_user, target_label, reason, details)
  values (v_uid, 'user', u.user_id, u.pseudo, p_reason, v_details) returning id, ref into v_id, v_ref;
  return jsonb_build_object('id', v_id, 'ref', v_ref);
end;
$$;

-- 5. Back-office : liste des signalements (ajoute les profils d'utilisateurs)
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
        'reported_user', case when q.kind = 'user' then jsonb_build_object('pseudo', coalesce(tp.pseudo, q.target_label), 'email', tu.email, 'exists', tu.id is not null) end,
        'review', case when rv.id is null then null else jsonb_build_object('id', rv.id, 'rating', rv.rating, 'body', rv.body, 'status', rv.status,
                   'pseudo', (select pseudo from public.user_profiles where user_id = rv.user_id)) end,
        'reports_on_same_target', (select count(*) from public.reports o where o.id <> q.id and o.kind = q.kind
             and ((q.kind = 'merchant' and o.merchant_id = q.merchant_id) or (q.kind = 'review' and o.review_id = q.review_id)
               or (q.kind = 'user' and o.target_user = q.target_user)))
      ) as x
      from public.reports q
      left join auth.users u on u.id = q.reporter_id
      left join auth.users tu on tu.id = q.target_user
      left join public.user_profiles tp on tp.user_id = q.target_user
      left join public.merchant_profiles m on m.id = q.merchant_id
      left join public.reviews rv on rv.id = q.review_id
      where p_status = 'all' or q.status = p_status
      order by q.created_at asc limit 200) t), '[]'::jsonb);
end;
$$;

-- 6. Back-office : supprimer définitivement un faux avis (la note moyenne se met à jour ; les signalements ouverts sur cet avis sont clos)
create or replace function public.admin_delete_review(p_review uuid, p_note text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.require_admin();
  if char_length(coalesce(v_note, '')) < 5 then raise exception 'reason_required'; end if;
  if not exists (select 1 from public.reviews where id = p_review) then raise exception 'not_found'; end if;
  update public.reports set status = 'resolved', handled_by = auth.uid(), handled_at = now(), handled_note = 'Avis supprimé. ' || v_note
   where review_id = p_review and status = 'open';
  delete from public.reviews where id = p_review;
end;
$$;

-- 7. Droits d'exécution
revoke all on function public.set_profile_privacy(boolean), public.my_profile_summary(), public.get_user_page(text),
  public.user_reviews(text, timestamptz, integer), public.user_following(text, timestamptz, integer), public.submit_report(text, uuid, uuid, text, text, text),
  public.submit_user_report(text, text, text), public.admin_list_reports(text), public.admin_delete_review(uuid, text) from public, anon, authenticated;
grant execute on function public.set_profile_privacy(boolean), public.my_profile_summary(), public.get_user_page(text),
  public.user_reviews(text, timestamptz, integer), public.user_following(text, timestamptz, integer), public.submit_report(text, uuid, uuid, text, text, text),
  public.submit_user_report(text, text, text), public.admin_list_reports(text), public.admin_delete_review(uuid, text) to authenticated;
