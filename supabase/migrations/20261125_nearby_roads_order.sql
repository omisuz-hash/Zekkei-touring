-- 地図で「定番度」で色を分ける尺度を加えたため、サーバー側で道を絞り込む順序も
-- 尺度に合わせて選べるようにする。
--
-- これまでは件数上限をかけるときの順序が�logp景度（hint_scenery）寄りに固定されていた。
-- そのため、紹介数の多い定番の道が、絶景度の高い無名の道に押し出されて
-- 画面に出てこない場合があった。定番度で塗り分けるときは、紹介数の多い順に拾う。
--
-- 引数を増やすため、いったん drop してから作り直す（create or replace では引数を増やせない）。
drop function if exists public.nearby_roads(double precision, double precision, double precision, integer);

create or replace function public.nearby_roads(
  p_lat double precision,
  p_lng double precision,
  p_radius_m double precision default 30000,
  p_limit integer default 1500,
  p_order text default 'scenery'
)
returns setof public.zekkei_roads language sql security definer stable as $$
  select r.*
  from public.zekkei_roads r
  where r.status = 'published'
    and st_dwithin(r.geom, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
    and not exists (
      select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = r.created_by
    )
  order by
    case when coalesce(p_order, 'scenery') = 'popularity'
      then (r.mention_count + r.rating_count)::double precision
      else null
    end desc nulls last,
    r.rating_count desc,
    coalesce(r.hint_scenery, 0) desc,
    r.mention_count desc
  limit least(greatest(coalesce(p_limit, 1500), 50), 3000);
$$;

grant execute on function public.nearby_roads(double precision, double precision, double precision, integer, text) to anon, authenticated;
