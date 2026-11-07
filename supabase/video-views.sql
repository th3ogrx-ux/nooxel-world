-- Nooxel World — Nombre de vues d'une vidéo, visible uniquement par le créateur du compte
-- À coller dans Supabase → SQL Editor → Run, APRÈS merchant-stats.sql. Peut être relancé sans danger.

create or replace function public.list_merchant_videos(p_merchant uuid, p_before timestamptz default null, p_limit integer default 12)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'caption', x.caption, 'video_path', x.video_path, 'poster_path', x.poster_path,
             'duration_s', x.duration_s, 'created_at', x.created_at,
             'like_count', x.like_count, 'liked', exists (select 1 from public.video_likes l where l.video_id = x.id and l.user_id = auth.uid()),
             'view_count', case when x.owner_id = auth.uid() then coalesce((select sum(s.n) from public.merchant_stats_daily s where s.item_id = x.id and s.metric = 'video_view'), 0)::bigint end)
             order by x.created_at desc, x.id desc)
    from (select v.*, m.owner_id from public.merchant_videos v join public.merchant_profiles m on m.id = v.merchant_id
           where v.merchant_id = p_merchant and (m.verification = 'verified' or m.owner_id = auth.uid())
             and (p_before is null or v.created_at < p_before)
           order by v.created_at desc, v.id desc limit least(greatest(coalesce(p_limit, 12), 1), 30)) x), '[]'::jsonb);
end;
$$;

revoke all on function public.list_merchant_videos(uuid, timestamptz, integer) from public, anon, authenticated;
grant execute on function public.list_merchant_videos(uuid, timestamptz, integer) to authenticated;
