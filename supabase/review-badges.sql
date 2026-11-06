-- Nooxel World — Badges de progression des utilisateurs (selon le nombre d'avis laissés)
-- À coller dans Supabase → SQL Editor → Run, APRÈS profile-privacy-reports.sql. Peut être relancé sans danger.
--
-- Paliers (comptes personnels uniquement ; un compte commerce / indépendant n'a pas de badge d'avis) :
--   • 0 à 4 avis publiés   : « Nouveau membre » (aucun badge affiché)
--   • 5 avis ou plus       : Contributeur
--   • 20 avis ou plus      : Expert local
--   • 50 avis ou plus      : Top Expert, À CONDITION d'une qualité minimale : avis détaillés (moyenne d'au moins 60 caractères)
--                            et au plus 2 avis masqués par la modération. Sinon le compte reste « Expert local ».
-- Le niveau est calculé à chaque affichage à partir des avis réellement publiés : il monte (ou redescend) tout seul.
-- Un profil privé n'affiche aucun badge aux autres.

create or replace function public.review_badge_level(p_user uuid)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare n integer; v_avg numeric; v_hidden integer;
begin
  if exists (select 1 from public.merchant_profiles where owner_id = p_user) then return null; end if;
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

-- Ma progression (pour l'indicateur « 12/20 avis pour débloquer Expert local »)
create or replace function public.my_review_badge()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare n integer; v_avg numeric; v_hidden integer; v_level text; v_next text; v_at integer; v_ok boolean;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if exists (select 1 from public.merchant_profiles where owner_id = auth.uid()) then return jsonb_build_object('applies', false); end if;
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

-- Liste des avis d'un commerce : ajoute le badge à côté du pseudo
create or replace function public.list_reviews(p_merchant uuid, p_before timestamptz default null, p_limit integer default 10)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'rating', x.rating, 'body', x.body, 'visited', x.visited,
             'created_at', x.created_at, 'pseudo', x.pseudo, 'mine', x.user_id = auth.uid(),
             'badge', case when x.is_private then null else public.review_badge_level(x.user_id) end,
             'reply', case when x.reply_body is null then null else jsonb_build_object('body', x.reply_body, 'at', x.reply_at) end)
             order by x.created_at desc, x.id desc)
    from (select r.*, up.pseudo, coalesce(up.is_private, false) as is_private from public.reviews r
            join public.merchant_profiles m on m.id = r.merchant_id
            left join public.user_profiles up on up.user_id = r.user_id
           where r.merchant_id = p_merchant and (m.verification = 'verified' or m.owner_id = auth.uid())
             and r.status = 'published' and (p_before is null or r.created_at < p_before)
           order by r.created_at desc, r.id desc limit least(greatest(coalesce(p_limit, 10), 1), 30)) x), '[]'::jsonb);
end;
$$;

-- Profil public d'un utilisateur : badge (aucun si le profil est privé)
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
    'reviews_count', v_reviews, 'following_count', v_follow, 'badge', case when v_visible then public.review_badge_level(u.user_id) end);
end;
$$;

revoke all on function public.review_badge_level(uuid), public.my_review_badge(), public.list_reviews(uuid, timestamptz, integer), public.get_user_page(text) from public, anon, authenticated;
grant execute on function public.my_review_badge(), public.list_reviews(uuid, timestamptz, integer), public.get_user_page(text) to authenticated;
