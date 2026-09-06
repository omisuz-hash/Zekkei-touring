-- 周辺の絶景道: 日本全体を引いて見たときにも道が出るよう、上限を 1,500 本に広げ、目立つ道から返す
create or replace function public.nearby_roads(p_lat double precision, p_lng double precision, p_radius_m double precision default 30000)
returns setof public.zekkei_roads language sql security definer stable as $$
  select r.*
  from public.zekkei_roads r
  where r.status = 'published'
    and st_dwithin(r.geom, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
    and not exists (
      select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = r.created_by
    )
  order by r.rating_count desc, coalesce(r.hint_scenery, 0) desc, r.mention_count desc
  limit 1500;
$$;
