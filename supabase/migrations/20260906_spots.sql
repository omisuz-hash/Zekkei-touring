-- 立ち寄りスポット（展望台・飲食店・道の駅・峠・温泉）と、縮尺に応じた取得件数の指定
create table if not exists public.road_spots (
  id uuid primary key default gen_random_uuid(),
  road_id uuid not null references public.zekkei_roads(id) on delete cascade,
  name text not null,
  kind text not null default 'other' check (kind in ('viewpoint','food','rest','pass','onsen','other')),
  lat double precision not null,
  lng double precision not null,
  note text,
  source text not null default 'seed_auto',   -- seed_auto: 動画から自動抽出 / user: 投稿者
  video_id text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (road_id, name)
);
create index if not exists road_spots_road_idx on public.road_spots(road_id);

alter table public.road_spots enable row level security;
drop policy if exists "road_spots: read all" on public.road_spots;
create policy "road_spots: read all" on public.road_spots for select using (true);
drop policy if exists "road_spots: insert own" on public.road_spots;
create policy "road_spots: insert own" on public.road_spots for insert with check (auth.uid() = created_by);
drop policy if exists "road_spots: delete own" on public.road_spots;
create policy "road_spots: delete own" on public.road_spots for delete using (auth.uid() = created_by);

-- 周辺の絶景道: 縮尺に応じて件数上限を変えられるように p_limit を追加
drop function if exists public.nearby_roads(double precision, double precision, double precision);
create or replace function public.nearby_roads(p_lat double precision, p_lng double precision, p_radius_m double precision default 30000, p_limit integer default 1500)
returns setof public.zekkei_roads language sql security definer stable as $$
  select r.*
  from public.zekkei_roads r
  where r.status = 'published'
    and st_dwithin(r.geom, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
    and not exists (
      select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = r.created_by
    )
  order by r.rating_count desc, coalesce(r.hint_scenery, 0) desc, r.mention_count desc
  limit least(greatest(coalesce(p_limit, 1500), 50), 3000);
$$;
