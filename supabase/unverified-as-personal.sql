-- Nooxel World — Tant que le commerce n'est pas vérifié, le compte garde toutes les fonctions d'un compte personnel
-- À coller dans Supabase → SQL Editor → Run, APRÈS les 6 fichiers précédents (badge-1000 … feed-algo). Peut être relancé sans danger.
--
-- Avant : dès qu'un profil de commerce était créé (même pas vérifié), le compte perdait le badge d'avis, le réglage « profil privé »
-- et la possibilité d'écrire à un commerce. Maintenant seul un commerce VÉRIFIÉ est traité comme un compte professionnel.

create or replace function public.review_badge_level(p_user uuid)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare n integer; v_avg numeric; v_hidden integer;
begin
  if exists (select 1 from public.merchant_profiles where owner_id = p_user and verification = 'verified') then return null; end if;
  select count(*), coalesce(avg(char_length(btrim(body))), 0) into n, v_avg from public.reviews where user_id = p_user and status = 'published';
  if n >= 50 then
    select count(*) into v_hidden from public.reviews where user_id = p_user and status = 'hidden';
    if v_avg >= 60 and v_hidden <= 2 then return 'top_expert'; end if;
  end if;
  if n >= 20 then return 'local_expert'; end if;
  if n >= 5 then return 'contributor'; end if;
  return null;
end;
$$;

create or replace function public.my_review_badge()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare n integer; v_avg numeric; v_hidden integer; v_level text; v_next text; v_at integer; v_ok boolean;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if exists (select 1 from public.merchant_profiles where owner_id = auth.uid() and verification = 'verified') then return jsonb_build_object('applies', false); end if;
  select count(*), coalesce(avg(char_length(btrim(body))), 0) into n, v_avg from public.reviews where user_id = auth.uid() and status = 'published';
  select count(*) into v_hidden from public.reviews where user_id = auth.uid() and status = 'hidden';
  v_ok := v_avg >= 60 and v_hidden <= 2;
  v_level := public.review_badge_level(auth.uid());
  if v_level is null then v_next := 'contributor'; v_at := 5;
  elsif v_level = 'contributor' then v_next := 'local_expert'; v_at := 20;
  elsif v_level = 'local_expert' then v_next := 'top_expert'; v_at := 50;
  end if;
  return jsonb_build_object('applies', true, 'count', n, 'level', v_level, 'next_level', v_next, 'next_at', v_at,
    'quality_ok', v_ok, 'avg_len', round(v_avg), 'hidden', v_hidden);
end;
$$;

create or replace function public.start_message(p_merchant uuid, p_body text)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); m public.merchant_profiles; c public.conversations; v_body text := btrim(coalesce(p_body, '')); v_issue text; msg public.messages;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from auth.users where id = v_uid and email_confirmed_at is not null) then raise exception 'email_not_confirmed'; end if;
  if exists (select 1 from public.merchant_profiles where owner_id = v_uid and verification = 'verified') then raise exception 'merchants_cannot_start'; end if;
  select * into m from public.merchant_profiles where id = p_merchant;
  if not found or m.verification <> 'verified' then raise exception 'not_found'; end if;
  if not m.messages_enabled then raise exception 'messages_disabled'; end if;
  if char_length(v_body) < 1 then raise exception 'message_empty'; end if;
  if char_length(v_body) > 2000 then raise exception 'message_too_long'; end if;
  v_issue := public.message_text_issue(v_body); if v_issue is not null then raise exception 'message_%', v_issue; end if;
  if (select count(*) from public.messages ms join public.conversations cc on cc.id = ms.conversation_id where cc.user_id = v_uid and ms.sender_kind = 'user' and ms.created_at > now() - interval '1 hour') >= 30 then raise exception 'too_many_messages'; end if;
  select * into c from public.conversations where user_id = v_uid and merchant_id = p_merchant;
  if not found then
    if (select count(*) from public.conversations where user_id = v_uid and created_at > now() - interval '1 day') >= 10 then raise exception 'too_many_conversations'; end if;
    insert into public.conversations (user_id, merchant_id) values (v_uid, p_merchant) returning * into c;
  end if;
  insert into public.messages (conversation_id, sender_kind, body) values (c.id, 'user', v_body) returning * into msg;
  update public.conversations set last_message_at = msg.created_at, user_read_at = msg.created_at where id = c.id;
  return jsonb_build_object('conversation_id', c.id, 'message', jsonb_build_object('id', msg.id, 'body', msg.body, 'created_at', msg.created_at, 'mine', true));
end;
$$;

create or replace function public.get_merchant_page(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare m public.merchant_profiles; v_today date; v_closure jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where id = p_id;
  if not found or (m.verification <> 'verified' and m.owner_id <> auth.uid()) then raise exception 'not_found'; end if;
  v_today := (now() at time zone coalesce(m.timezone, 'Europe/Paris'))::date;
  if m.closure_indefinite then
    v_closure := jsonb_build_object('indefinite', true, 'from', null, 'until', null, 'active', true);
  elsif m.closure_until is not null and m.closure_until >= v_today then
    v_closure := jsonb_build_object('indefinite', false, 'from', m.closure_from, 'until', m.closure_until, 'active', m.closure_from <= v_today);
  end if;
  return jsonb_build_object(
    'id', m.id, 'business_name', m.business_name, 'description', m.description,
    'verified', m.verification = 'verified', 'badge', case when m.follower_count >= public.badge_threshold() then 'compte certifié' end, 'has_badge', m.follower_count >= public.badge_threshold(), 'badge_threshold', public.badge_threshold(),
    'social_url', case when m.verification = 'verified' then m.social_url end,
    'kind', m.profile_kind,
    'address', m.address, 'lat', coalesce(m.lat, m.zone_lat), 'lng', coalesce(m.lng, m.zone_lng),
    'zone_label', m.zone_label, 'zone_radius_km', m.zone_radius_km,
    'category', m.category, 'logo_path', m.logo_path, 'cover_path', m.cover_path, 'website', m.website,
    'contact_phone', m.contact_phone, 'opening_hours', m.opening_hours, 'timezone', m.timezone,
    'closure', v_closure,
    'messages_enabled', m.messages_enabled,
    'can_message', m.verification = 'verified' and m.messages_enabled and m.owner_id <> auth.uid() and not exists (select 1 from public.merchant_profiles me where me.owner_id = auth.uid() and me.verification = 'verified'),
    'follower_count', m.follower_count,
    'posts_count', (select count(*) from public.merchant_posts p where p.merchant_id = m.id),
    'review_count', m.review_count,
    'rating_avg', case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end,
    'is_owner', m.owner_id = auth.uid(),
    'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = m.id));
end;
$$;

create or replace function public.set_profile_privacy(p_private boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_private is null then raise exception 'invalid_value'; end if;
  if exists (select 1 from public.merchant_profiles where owner_id = auth.uid() and verification = 'verified') then raise exception 'merchant_account'; end if;
  update public.user_profiles set is_private = p_private where user_id = auth.uid();
  if not found then raise exception 'profile_missing'; end if;
end;
$$;

revoke all on function public.review_badge_level(uuid), public.my_review_badge(), public.start_message(uuid, text), public.get_merchant_page(uuid), public.set_profile_privacy(boolean) from public, anon, authenticated;
grant execute on function public.my_review_badge(), public.start_message(uuid, text), public.get_merchant_page(uuid), public.set_profile_privacy(boolean) to authenticated;
