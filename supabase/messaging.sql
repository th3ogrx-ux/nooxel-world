-- Nooxel World — Messagerie (compte personnel ↔ commerce / indépendant)
-- À coller dans Supabase → SQL Editor → Run, APRÈS badge-1000.sql ET comments.sql. Peut être relancé sans danger.
--
-- Règles :
--   • Seule une personne (compte personnel, sans commerce) peut ENTRER en contact avec un commerce / indépendant VÉRIFIÉ ; le commerce répond
--     dans la même conversation. Aucun message entre deux comptes personnels, ni entre deux commerces.
--   • Le commerce peut désactiver les messages (« Autoriser les messages ») : plus aucun envoi (dans les deux sens), l'historique reste lisible.
--   • Limites : 30 messages par heure et par personne (100 pour un commerce), 10 nouvelles conversations par jour et par personne.
--   • Pas d'insulte. Les messages sont effacés avec le compte de la personne ou du commerce (RGPD).

alter table public.merchant_profiles add column if not exists messages_enabled boolean not null default true;

create table if not exists public.conversations (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  merchant_id      uuid not null references public.merchant_profiles(id) on delete cascade,
  created_at       timestamptz not null default now(),
  last_message_at  timestamptz not null default now(),
  user_read_at     timestamptz not null default now(),
  merchant_read_at timestamptz not null default 'epoch',
  user_pinned      boolean not null default false,
  merchant_pinned  boolean not null default false,
  user_cleared_at  timestamptz not null default 'epoch',       -- « Supprimer » : masque l'historique pour cette personne seulement
  merchant_cleared_at timestamptz not null default 'epoch',
  unique (user_id, merchant_id)
);
alter table public.conversations add column if not exists user_pinned boolean not null default false, add column if not exists merchant_pinned boolean not null default false,
  add column if not exists user_cleared_at timestamptz not null default 'epoch', add column if not exists merchant_cleared_at timestamptz not null default 'epoch';
create index if not exists conversations_by_user on public.conversations (user_id, last_message_at desc);
create index if not exists conversations_by_merchant on public.conversations (merchant_id, last_message_at desc);
alter table public.conversations enable row level security;
revoke all on public.conversations from anon, authenticated;

create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_kind     text not null check (sender_kind in ('user', 'merchant')),
  body            text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at      timestamptz not null default now()
);
create index if not exists messages_by_conversation on public.messages (conversation_id, created_at desc);
alter table public.messages enable row level security;
revoke all on public.messages from anon, authenticated;

-- Interrupteur « Autoriser les messages » (commerçant)
create or replace function public.set_messages_enabled(p_enabled boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_enabled is null then raise exception 'invalid_value'; end if;
  update public.merchant_profiles set messages_enabled = p_enabled where owner_id = auth.uid();
  if not found then raise exception 'no_profile'; end if;
end;
$$;

-- Texte d'un message : pas d'insulte ni de texte répétitif (les liens et numéros restent permis : « rappelez-moi au 06… »)
create or replace function public.message_text_issue(p_text text)
returns text
language plpgsql immutable
as $$
declare v text := public.comment_text_issue(p_text);
begin
  if v in ('insult', 'gibberish', 'too_short') then return v; end if;
  return null;
end;
$$;

-- Mes conversations (en tant que personne ET/OU en tant que commerce), la plus récente d'abord
create or replace function public.my_conversations(p_before timestamptz default null, p_limit integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'role', x.role, 'name', x.name, 'avatar_path', x.avatar_path, 'merchant_id', x.merchant_id,
             'last_body', x.last_body, 'last_at', x.last_at, 'last_from_me', x.last_from_me, 'unread', x.unread, 'can_send', x.can_send, 'pinned', x.pinned) order by x.pinned desc, x.last_at desc, x.id)
    from (
      select c.id, 'user'::text as role, m.business_name as name, m.logo_path as avatar_path, m.id as merchant_id,
             lm.body as last_body, c.last_message_at as last_at, lm.sender_kind = 'user' as last_from_me,
             (select count(*) from public.messages ms where ms.conversation_id = c.id and ms.sender_kind = 'merchant' and ms.created_at > c.user_read_at) as unread,
             (m.messages_enabled and m.verification = 'verified') as can_send, c.user_pinned as pinned
        from public.conversations c join public.merchant_profiles m on m.id = c.merchant_id
        left join lateral (select body, sender_kind from public.messages where conversation_id = c.id order by created_at desc limit 1) lm on true
       where c.user_id = auth.uid() and c.last_message_at > c.user_cleared_at and (p_before is null or c.last_message_at < p_before)
      union all
      select c.id, 'merchant', up.pseudo, up.avatar_path, m.id,
             lm.body, c.last_message_at, lm.sender_kind = 'merchant',
             (select count(*) from public.messages ms where ms.conversation_id = c.id and ms.sender_kind = 'user' and ms.created_at > c.merchant_read_at),
             (m.messages_enabled and m.verification = 'verified'), c.merchant_pinned
        from public.conversations c join public.merchant_profiles m on m.id = c.merchant_id and m.owner_id = auth.uid()
        left join public.user_profiles up on up.user_id = c.user_id
        left join lateral (select body, sender_kind from public.messages where conversation_id = c.id order by created_at desc limit 1) lm on true
       where c.last_message_at > c.merchant_cleared_at and (p_before is null or c.last_message_at < p_before)
      order by pinned desc, last_at desc limit least(greatest(coalesce(p_limit, 30), 1), 60)) x), '[]'::jsonb);
end;
$$;

create or replace function public.unread_messages_count()
returns integer
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then return 0; end if;
  return (select count(*)::int from public.messages ms join public.conversations c on c.id = ms.conversation_id
           left join public.merchant_profiles m on m.id = c.merchant_id
          where (c.user_id = auth.uid() and ms.sender_kind = 'merchant' and ms.created_at > c.user_read_at)
             or (m.owner_id = auth.uid() and ms.sender_kind = 'user' and ms.created_at > c.merchant_read_at));
end;
$$;

-- Conversation déjà ouverte avec un commerce (pour le bouton « Message »)
create or replace function public.conversation_for_merchant(p_merchant uuid)
returns uuid
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return (select id from public.conversations where user_id = auth.uid() and merchant_id = p_merchant);
end;
$$;

-- Ouvrir une conversation : renvoie l'historique et la marque comme lue
create or replace function public.open_conversation(p_conversation uuid, p_limit integer default 100)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare c public.conversations; m public.merchant_profiles; v_role text; v_name text; v_avatar text;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.conversations where id = p_conversation;
  if not found then raise exception 'not_found'; end if;
  select * into m from public.merchant_profiles where id = c.merchant_id;
  if c.user_id = auth.uid() then v_role := 'user'; v_name := m.business_name; v_avatar := m.logo_path;
  elsif m.owner_id = auth.uid() then v_role := 'merchant'; select pseudo, avatar_path into v_name, v_avatar from public.user_profiles where user_id = c.user_id;
  else raise exception 'not_found'; end if;
  if v_role = 'user' then update public.conversations set user_read_at = now() where id = c.id; else update public.conversations set merchant_read_at = now() where id = c.id; end if;
  update public.notifications set read_at = now() where user_id = auth.uid() and kind = 'message' and ref_id = c.id and read_at is null;
  return jsonb_build_object('id', c.id, 'role', v_role, 'name', coalesce(v_name, 'Utilisateur'), 'avatar_path', v_avatar, 'merchant_id', m.id,
    'user_pseudo', case when v_role = 'merchant' then v_name end,
    'can_send', m.messages_enabled and m.verification = 'verified',
    'messages', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'body', x.body, 'created_at', x.created_at, 'mine', x.sender_kind = v_role) order by x.created_at, x.id)
        from (select * from public.messages where conversation_id = c.id and created_at > case when v_role = 'user' then c.user_cleared_at else c.merchant_cleared_at end order by created_at desc, id desc limit least(greatest(coalesce(p_limit, 100), 1), 200)) x), '[]'::jsonb));
end;
$$;

-- Première prise de contact : une personne écrit à un commerce vérifié (crée la conversation si besoin)
create or replace function public.start_message(p_merchant uuid, p_body text)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); m public.merchant_profiles; c public.conversations; v_body text := btrim(coalesce(p_body, '')); v_issue text; msg public.messages;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from auth.users where id = v_uid and email_confirmed_at is not null) then raise exception 'email_not_confirmed'; end if;
  if exists (select 1 from public.merchant_profiles where owner_id = v_uid) then raise exception 'merchants_cannot_start'; end if;
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

-- Envoyer dans une conversation existante (la personne ou le commerce)
create or replace function public.send_in_conversation(p_conversation uuid, p_body text)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); c public.conversations; m public.merchant_profiles; v_role text; v_body text := btrim(coalesce(p_body, '')); v_issue text; msg public.messages; v_lim integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.conversations where id = p_conversation;
  if not found then raise exception 'not_found'; end if;
  select * into m from public.merchant_profiles where id = c.merchant_id;
  if c.user_id = v_uid then v_role := 'user'; elsif m.owner_id = v_uid then v_role := 'merchant'; else raise exception 'not_found'; end if;
  if m.verification <> 'verified' or not m.messages_enabled then raise exception 'messages_disabled'; end if;
  if char_length(v_body) < 1 then raise exception 'message_empty'; end if;
  if char_length(v_body) > 2000 then raise exception 'message_too_long'; end if;
  v_issue := public.message_text_issue(v_body); if v_issue is not null then raise exception 'message_%', v_issue; end if;
  v_lim := case when v_role = 'user' then 30 else 100 end;
  if v_role = 'user' then
    if (select count(*) from public.messages ms join public.conversations cc on cc.id = ms.conversation_id where cc.user_id = v_uid and ms.sender_kind = 'user' and ms.created_at > now() - interval '1 hour') >= v_lim then raise exception 'too_many_messages'; end if;
  else
    if (select count(*) from public.messages ms join public.conversations cc on cc.id = ms.conversation_id where cc.merchant_id = m.id and ms.sender_kind = 'merchant' and ms.created_at > now() - interval '1 hour') >= v_lim then raise exception 'too_many_messages'; end if;
  end if;
  insert into public.messages (conversation_id, sender_kind, body) values (c.id, v_role, v_body) returning * into msg;
  if v_role = 'user' then update public.conversations set last_message_at = msg.created_at, user_read_at = msg.created_at where id = c.id;
  else update public.conversations set last_message_at = msg.created_at, merchant_read_at = msg.created_at where id = c.id; end if;
  return jsonb_build_object('id', msg.id, 'body', msg.body, 'created_at', msg.created_at, 'mine', true);
end;
$$;

-- Épingler / désépingler une conversation (pour soi seulement, 5 au maximum) : les épinglées restent en haut de la liste
create or replace function public.pin_conversation(p_conversation uuid, p_pinned boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare c public.conversations; m public.merchant_profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.conversations where id = p_conversation;
  if not found then raise exception 'not_found'; end if;
  select * into m from public.merchant_profiles where id = c.merchant_id;
  if c.user_id = auth.uid() then
    if coalesce(p_pinned, false) and not c.user_pinned and (select count(*) from public.conversations where user_id = auth.uid() and user_pinned) >= 5 then raise exception 'too_many_pins'; end if;
    update public.conversations set user_pinned = coalesce(p_pinned, false) where id = c.id;
  elsif m.owner_id = auth.uid() then
    if coalesce(p_pinned, false) and not c.merchant_pinned and (select count(*) from public.conversations cc where cc.merchant_id = m.id and cc.merchant_pinned) >= 5 then raise exception 'too_many_pins'; end if;
    update public.conversations set merchant_pinned = coalesce(p_pinned, false) where id = c.id;
  else raise exception 'not_found'; end if;
end;
$$;

-- Supprimer une conversation : elle disparaît de MA liste (l'autre personne la garde). Si un nouveau message arrive, elle réapparaît
-- avec seulement les nouveaux messages. Quand les deux côtés l'ont supprimée, elle est effacée pour de bon.
create or replace function public.delete_conversation(p_conversation uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare c public.conversations; m public.merchant_profiles; v_now timestamptz := clock_timestamp();
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.conversations where id = p_conversation;
  if not found then raise exception 'not_found'; end if;
  select * into m from public.merchant_profiles where id = c.merchant_id;
  if c.user_id = auth.uid() then update public.conversations set user_cleared_at = v_now, user_read_at = v_now, user_pinned = false where id = c.id;
  elsif m.owner_id = auth.uid() then update public.conversations set merchant_cleared_at = v_now, merchant_read_at = v_now, merchant_pinned = false where id = c.id;
  else raise exception 'not_found'; end if;
  update public.notifications set read_at = v_now where user_id = auth.uid() and kind = 'message' and ref_id = c.id and read_at is null;
  delete from public.conversations where id = c.id and user_cleared_at >= last_message_at and merchant_cleared_at >= last_message_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- Notification « Nouveau message » (une seule par conversation tant qu'elle n'est pas lue)
-- ---------------------------------------------------------------------------
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check check (kind in ('follow', 'review', 'reply', 'post', 'report_done', 'verified', 'message'));

create or replace function public.notify_on_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare c public.conversations; m public.merchant_profiles; v_to uuid; v_from uuid;
begin
  select * into c from public.conversations where id = new.conversation_id;
  select * into m from public.merchant_profiles where id = c.merchant_id;
  if new.sender_kind = 'user' then v_to := m.owner_id; v_from := c.user_id; else v_to := c.user_id; v_from := m.owner_id; end if;
  update public.notifications set snippet = left(btrim(new.body), 80), created_at = new.created_at
   where user_id = v_to and kind = 'message' and ref_id = c.id and read_at is null;
  if not found then
    insert into public.notifications (user_id, kind, actor_id, merchant_id, ref_id, snippet) values (v_to, 'message', v_from, m.id, c.id, left(btrim(new.body), 80));
  end if;
  return new;
end $$;
drop trigger if exists notify_message on public.messages;
create trigger notify_message after insert on public.messages for each row execute function public.notify_on_message();

-- Liste des notifications : ajoute les messages
create or replace function public.my_notifications(p_before timestamptz default null, p_limit integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'created_at', x.created_at, 'read', x.read_at is not null,
             'name', x.name, 'merchant_id', x.merchant_id, 'snippet', x.snippet, 'rating', x.rating, 'ref_id', case when x.kind = 'message' then x.ref_id end, 'from_merchant', x.from_merchant) order by x.created_at desc, x.id desc)
    from (select n.id, n.kind, n.created_at, n.read_at, n.merchant_id, n.snippet, n.rating, n.ref_id,
                 (n.kind = 'message' and not exists (select 1 from public.conversations cv where cv.id = n.ref_id and cv.user_id = n.actor_id)) as from_merchant,
                 case when n.kind in ('follow', 'review') then coalesce((select pseudo from public.user_profiles where user_id = n.actor_id), 'Un utilisateur')
                      when n.kind in ('reply', 'post') then (select business_name from public.merchant_profiles where id = n.merchant_id)
                      when n.kind = 'message' then case when exists (select 1 from public.conversations cv where cv.id = n.ref_id and cv.user_id = n.actor_id)
                           then coalesce((select pseudo from public.user_profiles where user_id = n.actor_id), 'Un utilisateur') else (select business_name from public.merchant_profiles where id = n.merchant_id) end end as name
            from public.notifications n
           where n.user_id = auth.uid() and (p_before is null or n.created_at < p_before)
           order by n.created_at desc, n.id desc limit least(greatest(coalesce(p_limit, 30), 1), 50)) x), '[]'::jsonb);
end;
$$;
revoke all on function public.my_notifications(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.my_notifications(timestamptz, integer) to authenticated;

-- Page publique d'un commerce : ajoute messages_enabled et can_message
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
    'can_message', m.verification = 'verified' and m.messages_enabled and m.owner_id <> auth.uid() and not exists (select 1 from public.merchant_profiles me where me.owner_id = auth.uid()),
    'follower_count', m.follower_count,
    'posts_count', (select count(*) from public.merchant_posts p where p.merchant_id = m.id),
    'review_count', m.review_count,
    'rating_avg', case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end,
    'is_owner', m.owner_id = auth.uid(),
    'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = m.id));
end;
$$;

revoke all on function public.set_messages_enabled(boolean), public.message_text_issue(text), public.my_conversations(timestamptz, integer), public.unread_messages_count(),
  public.conversation_for_merchant(uuid), public.open_conversation(uuid, integer), public.start_message(uuid, text), public.send_in_conversation(uuid, text),
  public.pin_conversation(uuid, boolean), public.delete_conversation(uuid), public.get_merchant_page(uuid) from public, anon, authenticated;
grant execute on function public.set_messages_enabled(boolean), public.my_conversations(timestamptz, integer), public.unread_messages_count(),
  public.conversation_for_merchant(uuid), public.open_conversation(uuid, integer), public.start_message(uuid, text), public.send_in_conversation(uuid, text),
  public.pin_conversation(uuid, boolean), public.delete_conversation(uuid), public.get_merchant_page(uuid) to authenticated;
