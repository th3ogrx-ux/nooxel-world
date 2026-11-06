-- Nooxel World — Statistiques du commerçant (écran « Mes statistiques » des Paramètres)
-- À coller dans Supabase → SQL Editor → Run, APRÈS badge-1000.sql. Peut être relancé sans danger.
--
-- Vie privée : on ne garde que des COMPTEURS par commerce et par jour (« 12 visites de la page le 3 mars »), jamais « qui a vu quoi ».
-- Pour éviter les faux chiffres, une même personne n'est comptée qu'une fois par jour et par élément ; cette liste de contrôle
-- (stat_seen) est effacée au bout de 2 jours. Les visites du propriétaire sur sa propre page ne comptent pas.
-- L'historique commence à la date d'installation : avant, ces mesures n'existaient pas.

create table if not exists public.merchant_stats_daily (
  merchant_id uuid not null references public.merchant_profiles(id) on delete cascade,
  day         date not null,
  metric      text not null check (metric in ('profile_view', 'video_view', 'photo_view', 'search_impression', 'map_impression', 'message_click', 'route_click', 'share_click')),
  item_id     uuid not null default '00000000-0000-0000-0000-000000000000',
  n           integer not null default 0 check (n >= 0),
  primary key (merchant_id, day, metric, item_id)
);
create index if not exists merchant_stats_by_item on public.merchant_stats_daily (item_id) where item_id <> '00000000-0000-0000-0000-000000000000';
alter table public.merchant_stats_daily enable row level security;
revoke all on public.merchant_stats_daily from anon, authenticated;

create table if not exists public.stat_seen (
  user_id     uuid not null references auth.users(id) on delete cascade,
  merchant_id uuid not null references public.merchant_profiles(id) on delete cascade,
  metric      text not null,
  item_id     uuid not null default '00000000-0000-0000-0000-000000000000',
  day         date not null,
  primary key (user_id, merchant_id, metric, item_id, day)
);
create index if not exists stat_seen_by_day on public.stat_seen (day);
alter table public.stat_seen enable row level security;
revoke all on public.stat_seen from anon, authenticated;

-- Enregistre des événements (par lots). Ne renvoie jamais d'erreur : une statistique ne doit jamais gêner l'application.
create or replace function public.track_events(p_events jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  e jsonb; v_uid uuid := auth.uid(); v_day date := (now() at time zone 'Europe/Paris')::date;
  v_m uuid; v_metric text; v_item uuid; v_zero uuid := '00000000-0000-0000-0000-000000000000'; v_n integer := 0; v_new integer;
begin
  if v_uid is null or p_events is null or jsonb_typeof(p_events) <> 'array' then return; end if;
  if (select count(*) from public.stat_seen where user_id = v_uid and day = v_day) >= 3000 then return; end if;
  for e in select * from jsonb_array_elements(p_events) loop
    v_n := v_n + 1; exit when v_n > 60;
    begin
      v_m := (e->>'merchant')::uuid; v_metric := e->>'metric'; v_item := coalesce(nullif(e->>'item', '')::uuid, v_zero);
    exception when others then continue;
    end;
    if v_metric not in ('profile_view', 'video_view', 'photo_view', 'search_impression', 'map_impression', 'message_click', 'route_click', 'share_click') then continue; end if;
    if not exists (select 1 from public.merchant_profiles where id = v_m and verification = 'verified' and owner_id <> v_uid) then continue; end if;
    if v_metric = 'video_view' and not exists (select 1 from public.merchant_videos where id = v_item and merchant_id = v_m) then continue; end if;
    if v_metric = 'photo_view' and not exists (select 1 from public.merchant_posts where id = v_item and merchant_id = v_m and image_path is not null) then continue; end if;
    if v_metric not in ('video_view', 'photo_view') then v_item := v_zero; end if;
    insert into public.stat_seen (user_id, merchant_id, metric, item_id, day) values (v_uid, v_m, v_metric, v_item, v_day) on conflict do nothing;
    get diagnostics v_new = row_count;
    if v_new = 1 then
      insert into public.merchant_stats_daily (merchant_id, day, metric, item_id, n) values (v_m, v_day, v_metric, v_item, 1)
      on conflict (merchant_id, day, metric, item_id) do update set n = public.merchant_stats_daily.n + 1;
    end if;
  end loop;
end;
$$;

create or replace function public.purge_old_stat_seen()
returns void
language sql security definer set search_path = public
as $$ delete from public.stat_seen where day < (now() at time zone 'Europe/Paris')::date - 2; $$;

-- Tableau de bord du commerçant connecté (commerce vérifié uniquement) : série de 365 jours + détail par vidéo / photo
create or replace function public.my_stats()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare m public.merchant_profiles; v_today date := (now() at time zone 'Europe/Paris')::date; v_from date; v_zero uuid := '00000000-0000-0000-0000-000000000000';
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.merchant_profiles where owner_id = auth.uid();
  if not found then raise exception 'not_found'; end if;
  if m.verification <> 'verified' then raise exception 'not_verified'; end if;
  v_from := v_today - 364;
  return jsonb_build_object(
    'today', v_today,
    'merchant', jsonb_build_object('follower_count', m.follower_count, 'review_count', m.review_count,
       'rating_avg', case when m.review_count > 0 then round(m.rating_sum::numeric / m.review_count, 1) end, 'badge_threshold', public.badge_threshold()),
    'tracking_since', (select min(day) from public.merchant_stats_daily where merchant_id = m.id),
    'series', (
      select jsonb_agg(jsonb_build_object('day', d.day,
          'profile_view', coalesce(s.profile_view, 0), 'video_view', coalesce(s.video_view, 0), 'photo_view', coalesce(s.photo_view, 0),
          'search_impression', coalesce(s.search_impression, 0), 'map_impression', coalesce(s.map_impression, 0),
          'message_click', coalesce(s.message_click, 0), 'route_click', coalesce(s.route_click, 0), 'share_click', coalesce(s.share_click, 0),
          'new_followers', coalesce(f.n, 0), 'reviews', coalesce(r.n, 0), 'rating_sum', coalesce(r.sum, 0), 'likes', coalesce(l.n, 0)) order by d.day)
        from (select g::date as day from generate_series(v_from, v_today, interval '1 day') g) d
        left join (select day,
              sum(n) filter (where metric = 'profile_view') as profile_view, sum(n) filter (where metric = 'video_view') as video_view,
              sum(n) filter (where metric = 'photo_view') as photo_view, sum(n) filter (where metric = 'search_impression') as search_impression,
              sum(n) filter (where metric = 'map_impression') as map_impression, sum(n) filter (where metric = 'message_click') as message_click,
              sum(n) filter (where metric = 'route_click') as route_click, sum(n) filter (where metric = 'share_click') as share_click
            from public.merchant_stats_daily where merchant_id = m.id and day >= v_from group by day) s on s.day = d.day
        left join (select (created_at at time zone 'Europe/Paris')::date as day, count(*) as n from public.follows where merchant_id = m.id group by 1) f on f.day = d.day
        left join (select (created_at at time zone 'Europe/Paris')::date as day, count(*) as n, sum(rating) as sum from public.reviews where merchant_id = m.id and status = 'published' group by 1) r on r.day = d.day
        left join (select day, sum(n) as n from (
              select (pl.created_at at time zone 'Europe/Paris')::date as day, count(*) as n from public.post_likes pl join public.merchant_posts p on p.id = pl.post_id where p.merchant_id = m.id group by 1
              union all
              select (vl.created_at at time zone 'Europe/Paris')::date, count(*) from public.video_likes vl join public.merchant_videos v on v.id = vl.video_id where v.merchant_id = m.id group by 1) u group by day) l on l.day = d.day),
    'videos', coalesce((select jsonb_agg(x order by (x->>'views')::int desc, x->>'created_at' desc) from (
        select jsonb_build_object('id', v.id, 'caption', v.caption, 'poster_path', v.poster_path, 'like_count', v.like_count, 'created_at', v.created_at,
                 'views', coalesce((select sum(n) from public.merchant_stats_daily s where s.merchant_id = m.id and s.metric = 'video_view' and s.item_id = v.id), 0)) as x
          from public.merchant_videos v where v.merchant_id = m.id order by v.created_at desc limit 30) t), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(x order by (x->>'views')::int desc, x->>'created_at' desc) from (
        select jsonb_build_object('id', p.id, 'body', left(p.body, 80), 'image_path', p.image_path, 'like_count', p.like_count, 'created_at', p.created_at,
                 'views', coalesce((select sum(n) from public.merchant_stats_daily s where s.merchant_id = m.id and s.metric = 'photo_view' and s.item_id = p.id), 0)) as x
          from public.merchant_posts p where p.merchant_id = m.id and p.image_path is not null order by p.created_at desc limit 30) t), '[]'::jsonb));
end;
$$;

revoke all on function public.track_events(jsonb), public.purge_old_stat_seen(), public.my_stats() from public, anon, authenticated;
grant execute on function public.track_events(jsonb), public.my_stats() to authenticated;
grant execute on function public.purge_old_stat_seen() to service_role;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('purge-stat-seen', '57 3 * * *', 'select public.purge_old_stat_seen();');
  end if;
end $$;
