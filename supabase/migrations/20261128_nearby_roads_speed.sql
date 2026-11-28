-- 全国表示で「canceling statement due to statement timeout」が出る件への対応。
--
-- 原因は三つ重なっている。
--   1. 自動収集で道が増え続けており、並べ替えの対象が大きくなった
--   2. 20261125 の対応で並べ替えの先頭に case 式を置いたため、索引が使えなくなった
--   3. 全国表示では半径 1,200km の距離計算を道の数だけ行っており、
--      しかもその範囲は実質的に日本全体のため、絞り込みの効果がない
--
-- 対応として、並べ替えを尺度ごとの分岐に書き換えて索引を使えるようにし、
-- 半径が日本全体を覆う場合は距離計算そのものを省く。

-- 並べ替えを支える索引。公開中の道だけを対象にする
create index if not exists zekkei_roads_order_scenery_idx
  on public.zekkei_roads (rating_count desc, coalesce(hint_scenery, 0) desc, mention_count desc)
  where status = 'published';

create index if not exists zekkei_roads_order_popularity_idx
  on public.zekkei_roads (((mention_count + rating_count)) desc, coalesce(hint_scenery, 0) desc)
  where status = 'published';

drop function if exists public.nearby_roads(double precision, double precision, double precision, integer, text);

create or replace function public.nearby_roads(
  p_lat double precision,
  p_lng double precision,
  p_radius_m double precision default 30000,
  p_limit integer default 1500,
  p_order text default 'scenery'
)
returns setof public.zekkei_roads
language plpgsql security definer stable as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 1500), 50), 3000);
  v_radius double precision := coalesce(p_radius_m, 30000);
  v_point geography := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  -- これ以上の半径は、どこを中心にしても日本全体がほぼ入る。
  -- 距離で絞っても結果が変わらないため、計算を省く
  v_whole_country constant double precision := 1000000;
  v_popular boolean := coalesce(p_order, 'scenery') = 'popularity';
begin
  if v_popular and v_radius >= v_whole_country then
    return query
      select r.* from public.zekkei_roads r
      where r.status = 'published'
        and not exists (select 1 from public.blocks b
                        where b.blocker_id = auth.uid() and b.blocked_id = r.created_by)
      order by (r.mention_count + r.rating_count) desc, coalesce(r.hint_scenery, 0) desc
      limit v_limit;

  elsif v_popular then
    return query
      select r.* from public.zekkei_roads r
      where r.status = 'published'
        and st_dwithin(r.geom, v_point, v_radius)
        and not exists (select 1 from public.blocks b
                        where b.blocker_id = auth.uid() and b.blocked_id = r.created_by)
      order by (r.mention_count + r.rating_count) desc, coalesce(r.hint_scenery, 0) desc
      limit v_limit;

  elsif v_radius >= v_whole_country then
    return query
      select r.* from public.zekkei_roads r
      where r.status = 'published'
        and not exists (select 1 from public.blocks b
                        where b.blocker_id = auth.uid() and b.blocked_id = r.created_by)
      order by r.rating_count desc, coalesce(r.hint_scenery, 0) desc, r.mention_count desc
      limit v_limit;

  else
    return query
      select r.* from public.zekkei_roads r
      where r.status = 'published'
        and st_dwithin(r.geom, v_point, v_radius)
        and not exists (select 1 from public.blocks b
                        where b.blocker_id = auth.uid() and b.blocked_id = r.created_by)
      order by r.rating_count desc, coalesce(r.hint_scenery, 0) desc, r.mention_count desc
      limit v_limit;
  end if;
end;
$$;

grant execute on function public.nearby_roads(double precision, double precision, double precision, integer, text) to anon, authenticated;

analyze public.zekkei_roads;
