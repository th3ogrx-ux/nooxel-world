-- Nooxel World — Algorithme du fil d'actualité
-- À coller dans Supabase → SQL Editor → Run, APRÈS badge-1000.sql. Peut être relancé sans danger.
--
-- Chaque « paquet » du fil contient :
--   1. jusqu'à 5 publications de commerces que la personne SUIT, tirées au hasard parmi les plus récentes (30 derniers jours d'abord) ;
--   2. puis 3 publications « suggestion » tirées au hasard parmi les autres commerces vérifiés (60 derniers jours d'abord).
-- Si la personne suit peu de commerces, les places libres sont remplies avec des suggestions. Une publication déjà montrée
-- (liste p_seen envoyée par l'application) n'est jamais remontrée dans la même visite. Seuls les commerces vérifiés apparaissent.

create or replace function public.feed_mix(p_seen uuid[] default '{}', p_followed integer default 5, p_discover integer default 3)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_f integer := least(greatest(coalesce(p_followed, 5), 0), 10);
  v_d integer := least(greatest(coalesce(p_discover, 3), 0), 10);
  v_seen uuid[] := coalesce(p_seen, '{}');
  ids_f uuid[]; ids_d uuid[];
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if cardinality(v_seen) > 500 then v_seen := v_seen[1:500]; end if;
  select coalesce(array_agg(id), '{}') into ids_f from (
    select p.id from public.merchant_posts p
      join public.follows f on f.merchant_id = p.merchant_id and f.user_id = v_uid
      join public.merchant_profiles m on m.id = p.merchant_id and m.verification = 'verified'
     where not (p.id = any(v_seen))
     order by (p.created_at > now() - interval '30 days') desc, random() limit v_f) x;
  select coalesce(array_agg(id), '{}') into ids_d from (
    select p.id from public.merchant_posts p
      join public.merchant_profiles m on m.id = p.merchant_id and m.verification = 'verified' and m.owner_id <> v_uid
     where not (p.id = any(v_seen))
       and not exists (select 1 from public.follows f where f.user_id = v_uid and f.merchant_id = p.merchant_id)
     order by (p.created_at > now() - interval '60 days') desc, random() limit v_d + (v_f - cardinality(ids_f))) x;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'body', p.body, 'image_path', p.image_path, 'created_at', p.created_at,
             'merchant_id', p.merchant_id, 'business_name', m.business_name, 'logo_path', m.logo_path,
             'has_badge', m.follower_count >= public.badge_threshold(), 'like_count', p.like_count,
             'liked', exists (select 1 from public.post_likes l where l.post_id = p.id and l.user_id = v_uid),
             'discover', p.id = any(ids_d)) order by o.ord)
    from unnest(ids_f || ids_d) with ordinality as o(id, ord)
    join public.merchant_posts p on p.id = o.id join public.merchant_profiles m on m.id = p.merchant_id), '[]'::jsonb);
end;
$$;

revoke all on function public.feed_mix(uuid[], integer, integer) from public, anon, authenticated;
grant execute on function public.feed_mix(uuid[], integer, integer) to authenticated;
