-- Nooxel World — Commentaires sur les vidéos et les publications (photos) des commerces
-- À coller dans Supabase → SQL Editor → Run, APRÈS likes.sql et review-badges.sql. Peut être relancé sans danger.
--
-- Règles :
--   • Tout compte connecté (email confirmé, pseudo choisi) peut commenter une vidéo ou une publication d'un commerce vérifié.
--   • 1 à 500 caractères ; pas de lien ni de numéro de téléphone ; pas d'insulte ; au plus 30 commentaires par heure et par compte.
--   • Réponses : un seul niveau (on répond à un commentaire, pas à une réponse).
--   • ♥ sur un commentaire (un par personne). Compteurs tenus à jour par la base.
--   • Peuvent supprimer un commentaire : son auteur et le commerçant propriétaire de la vidéo / publication (ses réponses partent avec lui).
--   • Le badge de progression (Contributeur / Expert local / Top Expert) s'affiche à côté du pseudo, sauf si le profil est privé.

create table if not exists public.comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid references public.merchant_posts(id) on delete cascade,
  video_id   uuid references public.merchant_videos(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  parent_id  uuid references public.comments(id) on delete cascade,
  body       text not null check (char_length(btrim(body)) between 1 and 500),
  like_count integer not null default 0 check (like_count >= 0),
  created_at timestamptz not null default now(),
  check ((post_id is not null)::int + (video_id is not null)::int = 1)
);
create index if not exists comments_by_post on public.comments (post_id, created_at desc) where parent_id is null;
create index if not exists comments_by_video on public.comments (video_id, created_at desc) where parent_id is null;
create index if not exists comments_by_parent on public.comments (parent_id, created_at);
create index if not exists comments_by_user on public.comments (user_id, created_at desc);
alter table public.comments enable row level security;
revoke all on public.comments from anon, authenticated;

create table if not exists public.comment_likes (
  user_id    uuid not null references auth.users(id) on delete cascade,
  comment_id uuid not null references public.comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, comment_id)
);
alter table public.comment_likes enable row level security;
revoke all on public.comment_likes from anon, authenticated;

alter table public.merchant_posts add column if not exists comment_count integer not null default 0;
alter table public.merchant_videos add column if not exists comment_count integer not null default 0;

-- Compteurs (réponses comprises)
create or replace function public.comments_count_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.comments := case when tg_op = 'INSERT' then new else old end; d integer := case when tg_op = 'INSERT' then 1 else -1 end;
begin
  if r.post_id is not null then update public.merchant_posts set comment_count = greatest(comment_count + d, 0) where id = r.post_id;
  else update public.merchant_videos set comment_count = greatest(comment_count + d, 0) where id = r.video_id; end if;
  return null;
end $$;
drop trigger if exists comments_count on public.comments;
create trigger comments_count after insert or delete on public.comments for each row execute function public.comments_count_sync();

create or replace function public.comment_likes_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update public.comments set like_count = like_count + 1 where id = new.comment_id;
  else update public.comments set like_count = greatest(like_count - 1, 0) where id = old.comment_id; end if;
  return null;
end $$;
drop trigger if exists comment_likes_count on public.comment_likes;
create trigger comment_likes_count after insert or delete on public.comment_likes for each row execute function public.comment_likes_sync();

-- Filtre : pas de lien / numéro, pas d'insulte, pas de texte répétitif
create or replace function public.comment_text_issue(p_text text)
returns text
language plpgsql immutable
as $$
declare t text := public.normalize_fr(btrim(coalesce(p_text, '')));
begin
  if t = '' then return 'too_short'; end if;
  if t ~ '(https?://|www\.|@[a-z0-9._-]+\.[a-z]{2,}|[a-z0-9]\.(com|fr|net|org|io)(/|\s|$))' or t ~ '(\d[ .-]?){9,}' then return 'contains_link'; end if;
  if t ~ '(.)\1{9,}' then return 'gibberish'; end if;
  if exists (select 1 from regexp_split_to_table(t, '[^a-z]+') w where w <> '' and (w = any (public.insult_words()) or regexp_replace(w, 's$', '') = any (public.insult_words()))) then return 'insult'; end if;
  return null;
end;
$$;

-- Élément commentable : renvoie le commerce (vérifié, ou propriétaire = moi)
create or replace function public.comment_target(p_kind text, p_item uuid)
returns public.merchant_profiles
language plpgsql stable security definer set search_path = public
as $$
declare m public.merchant_profiles;
begin
  if p_kind = 'post' then select mm.* into m from public.merchant_posts p join public.merchant_profiles mm on mm.id = p.merchant_id where p.id = p_item;
  elsif p_kind = 'video' then select mm.* into m from public.merchant_videos v join public.merchant_profiles mm on mm.id = v.merchant_id where v.id = p_item;
  else raise exception 'invalid_kind'; end if;
  if not found or (m.verification <> 'verified' and m.owner_id <> auth.uid()) then raise exception 'not_found'; end if;
  return m;
end;
$$;

-- Un commentaire mis en forme pour l'écran
create or replace function public.comment_json(p_id uuid, p_owner uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object('id', c.id, 'body', c.body, 'created_at', c.created_at, 'like_count', c.like_count,
    'liked', exists (select 1 from public.comment_likes l where l.comment_id = c.id and l.user_id = auth.uid()),
    'pseudo', up.pseudo, 'avatar_path', up.avatar_path,
    'badge', case when coalesce(up.is_private, false) then null else public.review_badge_level(c.user_id) end,
    'mine', c.user_id = auth.uid(), 'can_delete', c.user_id = auth.uid() or p_owner = auth.uid(), 'parent_id', c.parent_id)
  from public.comments c left join public.user_profiles up on up.user_id = c.user_id where c.id = p_id;
$$;

-- Liste : commentaires (du plus récent au plus ancien) avec leurs réponses (du plus ancien au plus récent)
create or replace function public.list_comments(p_kind text, p_item uuid, p_before timestamptz default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare m public.merchant_profiles; v_total integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  m := public.comment_target(p_kind, p_item);
  select case when p_kind = 'post' then (select comment_count from public.merchant_posts where id = p_item) else (select comment_count from public.merchant_videos where id = p_item) end into v_total;
  return jsonb_build_object('total', coalesce(v_total, 0), 'items', coalesce((
    select jsonb_agg(public.comment_json(c.id, m.owner_id) || jsonb_build_object('replies', coalesce((
             select jsonb_agg(public.comment_json(r.id, m.owner_id) order by r.created_at, r.id) from public.comments r where r.parent_id = c.id), '[]'::jsonb))
           order by c.created_at desc, c.id desc)
    from (select * from public.comments cc
           where cc.parent_id is null and ((p_kind = 'post' and cc.post_id = p_item) or (p_kind = 'video' and cc.video_id = p_item))
             and (p_before is null or cc.created_at < p_before)
           order by cc.created_at desc, cc.id desc limit least(greatest(coalesce(p_limit, 20), 1), 50)) c), '[]'::jsonb));
end;
$$;

create or replace function public.add_comment(p_kind text, p_item uuid, p_body text, p_parent uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare v_uid uuid := auth.uid(); m public.merchant_profiles; v_body text := btrim(coalesce(p_body, '')); v_issue text; par public.comments; c public.comments;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from auth.users where id = v_uid and email_confirmed_at is not null) then raise exception 'email_not_confirmed'; end if;
  if not exists (select 1 from public.user_profiles where user_id = v_uid and pseudo is not null) then raise exception 'pseudo_required'; end if;
  m := public.comment_target(p_kind, p_item);
  if m.verification <> 'verified' then raise exception 'not_found'; end if;
  if char_length(v_body) < 1 then raise exception 'comment_empty'; end if;
  if char_length(v_body) > 500 then raise exception 'comment_too_long'; end if;
  v_issue := public.comment_text_issue(v_body); if v_issue is not null then raise exception 'comment_%', v_issue; end if;
  if (select count(*) from public.comments where user_id = v_uid and created_at > now() - interval '1 hour') >= 30 then raise exception 'too_many_comments'; end if;
  if p_parent is not null then
    select * into par from public.comments where id = p_parent;
    if not found or par.parent_id is not null or not ((p_kind = 'post' and par.post_id = p_item) or (p_kind = 'video' and par.video_id = p_item)) then raise exception 'not_found'; end if;
  end if;
  insert into public.comments (post_id, video_id, user_id, parent_id, body)
  values (case when p_kind = 'post' then p_item end, case when p_kind = 'video' then p_item end, v_uid, p_parent, v_body) returning * into c;
  return public.comment_json(c.id, m.owner_id);
end;
$$;

create or replace function public.delete_comment(p_comment uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare c public.comments; v_owner uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.comments where id = p_comment;
  if not found then raise exception 'not_found'; end if;
  select mm.owner_id into v_owner from public.merchant_profiles mm
    where mm.id = coalesce((select merchant_id from public.merchant_posts where id = c.post_id), (select merchant_id from public.merchant_videos where id = c.video_id));
  if c.user_id <> auth.uid() and v_owner is distinct from auth.uid() then raise exception 'forbidden' using errcode = '42501'; end if;
  delete from public.comments where id = p_comment;
end;
$$;

create or replace function public.like_comment(p_comment uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if (select count(*) from public.comment_likes where user_id = auth.uid() and created_at > now() - interval '1 hour') >= 200 then raise exception 'too_many_likes'; end if;
  if not exists (select 1 from public.comments c where c.id = p_comment and (c.post_id is not null and exists (select 1 from public.merchant_posts p join public.merchant_profiles m on m.id = p.merchant_id where p.id = c.post_id and m.verification = 'verified')
      or c.video_id is not null and exists (select 1 from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id where v.id = c.video_id and m.verification = 'verified'))) then raise exception 'not_found'; end if;
  insert into public.comment_likes (user_id, comment_id) values (auth.uid(), p_comment) on conflict do nothing;
  select like_count into n from public.comments where id = p_comment; return n;
end;
$$;

create or replace function public.unlike_comment(p_comment uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.comment_likes where user_id = auth.uid() and comment_id = p_comment;
  select like_count into n from public.comments where id = p_comment; return coalesce(n, 0);
end;
$$;

-- Fil de vidéos : ajoute le nombre de commentaires
create or replace function public.video_feed(p_before timestamptz default null, p_limit integer default 8, p_kind text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_kind is not null and p_kind not in ('shop', 'mobile') then raise exception 'invalid_filter' using errcode = '22023'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'caption', x.caption, 'video_path', x.video_path, 'poster_path', x.poster_path,
             'duration_s', x.duration_s, 'created_at', x.created_at, 'like_count', x.like_count,
             'liked', exists (select 1 from public.video_likes l where l.video_id = x.id and l.user_id = auth.uid()),
             'merchant_id', x.merchant_id, 'business_name', x.business_name, 'logo_path', x.logo_path, 'kind', x.profile_kind,
             'lat', coalesce(x.lat, x.zone_lat), 'lng', coalesce(x.lng, x.zone_lng),
             'review_count', x.review_count, 'rating_avg', case when x.review_count > 0 then round(x.rating_sum::numeric / x.review_count, 1) end,
             'is_following', exists (select 1 from public.follows f where f.user_id = auth.uid() and f.merchant_id = x.merchant_id),
             'is_owner', x.owner_id = auth.uid(), 'comment_count', x.comment_count)
             order by x.created_at desc, x.id desc)
    from (select v.*, m.business_name, m.logo_path, m.profile_kind, m.lat, m.lng, m.zone_lat, m.zone_lng, m.review_count, m.rating_sum, m.owner_id
            from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id and m.verification = 'verified'
           where (p_before is null or v.created_at < p_before) and (p_kind is null or m.profile_kind = p_kind)
           order by v.created_at desc, v.id desc limit least(greatest(coalesce(p_limit, 8), 1), 20)) x), '[]'::jsonb);
end;
$$;

revoke all on function public.comments_count_sync(), public.comment_likes_sync(), public.comment_text_issue(text), public.comment_target(text, uuid), public.comment_json(uuid, uuid),
  public.list_comments(text, uuid, timestamptz, integer), public.add_comment(text, uuid, text, uuid), public.delete_comment(uuid), public.like_comment(uuid), public.unlike_comment(uuid) from public, anon, authenticated;
grant execute on function public.list_comments(text, uuid, timestamptz, integer), public.add_comment(text, uuid, text, uuid), public.delete_comment(uuid), public.like_comment(uuid), public.unlike_comment(uuid) to authenticated;
revoke all on function public.video_feed(timestamptz, integer, text) from public, anon, authenticated;
grant execute on function public.video_feed(timestamptz, integer, text) to authenticated;
