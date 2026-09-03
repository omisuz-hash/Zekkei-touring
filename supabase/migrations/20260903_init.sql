-- 絶景道（Zekkei-do）初期スキーマ
-- 対象: Supabase (PostgreSQL + PostGIS)
-- 方針:
--   * 走行記録(ride_logs)は本人のみ閲覧可（自宅周辺を含むため公開しない）
--   * 絶景道(zekkei_roads)は切り出した区間のみを公開
--   * 評価(road_ratings)は絶景道に紐づき、集計値は zekkei_roads に非正規化して保持
--   * 閲覧枠(view_credits)は台帳方式。購入枠は失効しない、投稿特典枠は月次リセット

create extension if not exists postgis;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------
-- 会員
-- ---------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text not null default '',
  avatar_url    text,
  plan          text not null default 'contributor' check (plan in ('contributor', 'subscriber')),
  -- プライバシーゾーン: 自宅等の中心点と半径(m)。走行記録の切り出し時に自動で除外する
  privacy_center geography(Point, 4326),
  privacy_radius_m integer not null default 1000,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- 走行記録（非公開）
-- ---------------------------------------------------------------
create table if not exists public.ride_logs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  started_at    timestamptz not null,
  ended_at      timestamptz,
  distance_m    double precision not null default 0,
  track         geography(LineString, 4326),
  -- 端末側で記録した生データ（緯度経度・高度・速度・時刻）の圧縮JSON
  raw_points    jsonb,
  created_at    timestamptz not null default now()
);
create index if not exists ride_logs_user_idx on public.ride_logs(user_id);

-- ---------------------------------------------------------------
-- 絶景道（公開）
-- ---------------------------------------------------------------
create table if not exists public.zekkei_roads (
  id              uuid primary key default gen_random_uuid(),
  created_by      uuid references public.profiles(id) on delete set null,
  name            text not null,
  description     text,
  prefecture      text,
  start_label     text,
  end_label       text,
  -- 道路に補正済みの区間形状
  geom            geography(LineString, 4326) not null,
  length_m        double precision not null,
  -- アプリが読みやすい形式(GeoJSON)を自動生成して保持
  geojson         jsonb generated always as (st_asgeojson(geom)::jsonb) stored,
  -- 曲がり具合の推定値（0-1）。端末側で軌跡の方位変化から算出
  curviness       double precision,
  -- 運営が動画等から投入したシードデータか
  is_seed         boolean not null default false,
  youtube_url     text,
  youtube_channel text,
  -- 集計（トリガーで更新）
  rating_count    integer not null default 0,
  avg_scenery     numeric(3,2),
  avg_ride_quality numeric(3,2),
  avg_winding     numeric(3,2),
  avg_rest_stops  numeric(3,2),
  avg_parking     numeric(3,2),
  status          text not null default 'published' check (status in ('published', 'hidden', 'removed')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists zekkei_roads_geom_idx on public.zekkei_roads using gist (geom);
create index if not exists zekkei_roads_status_idx on public.zekkei_roads(status);

-- ---------------------------------------------------------------
-- 評価
-- ---------------------------------------------------------------
create table if not exists public.road_ratings (
  id            uuid primary key default gen_random_uuid(),
  road_id       uuid not null references public.zekkei_roads(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  ride_log_id   uuid references public.ride_logs(id) on delete set null,
  scenery       smallint not null check (scenery between 1 and 5),
  ride_quality  smallint not null check (ride_quality between 1 and 5),
  winding       smallint not null check (winding between 1 and 5),
  rest_stops    smallint not null check (rest_stops between 1 and 5),
  parking       smallint not null check (parking between 1 and 5),
  traffic       smallint check (traffic between 1 and 5),
  season        text,
  comment       text,
  photo_paths   text[] not null default '{}',
  ridden_at     timestamptz,
  status        text not null default 'published' check (status in ('published', 'hidden', 'removed')),
  created_at    timestamptz not null default now(),
  -- 同一走行記録から同じ道への二重評価を防ぐ
  unique (road_id, user_id, ride_log_id)
);
create index if not exists road_ratings_road_idx on public.road_ratings(road_id);
create index if not exists road_ratings_user_idx on public.road_ratings(user_id);

-- 集計更新トリガー
create or replace function public.refresh_road_aggregates(p_road_id uuid)
returns void language sql security definer as $$
  update public.zekkei_roads r set
    rating_count     = s.cnt,
    avg_scenery      = s.scenery,
    avg_ride_quality = s.ride_quality,
    avg_winding      = s.winding,
    avg_rest_stops   = s.rest_stops,
    avg_parking      = s.parking,
    updated_at       = now()
  from (
    select count(*) cnt,
           round(avg(scenery)::numeric, 2)      scenery,
           round(avg(ride_quality)::numeric, 2) ride_quality,
           round(avg(winding)::numeric, 2)      winding,
           round(avg(rest_stops)::numeric, 2)   rest_stops,
           round(avg(parking)::numeric, 2)      parking
    from public.road_ratings
    where road_id = p_road_id and status = 'published'
  ) s
  where r.id = p_road_id;
$$;

create or replace function public.trg_road_ratings_aggregate()
returns trigger language plpgsql security definer as $$
begin
  perform public.refresh_road_aggregates(coalesce(new.road_id, old.road_id));
  return null;
end;
$$;

drop trigger if exists road_ratings_aggregate on public.road_ratings;
create trigger road_ratings_aggregate
after insert or update or delete on public.road_ratings
for each row execute function public.trg_road_ratings_aggregate();

-- ---------------------------------------------------------------
-- 閲覧枠（台帳）
-- ---------------------------------------------------------------
-- kind:
--   monthly_free : 毎月付与される無料枠（月末失効）
--   contribution : 投稿特典枠（月末失効）
--   purchased    : 購入枠（失効しない。Apple審査 3.1.1）
--   spend        : 消費（負数）
create table if not exists public.view_credits (
  id          bigserial primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null check (kind in ('monthly_free', 'contribution', 'purchased', 'spend')),
  amount      integer not null,
  expires_at  timestamptz,
  ref_road_id uuid references public.zekkei_roads(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists view_credits_user_idx on public.view_credits(user_id);

-- 閲覧済みの絶景道（一度解放した道は再度枠を消費しない）
create table if not exists public.road_unlocks (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  road_id    uuid not null references public.zekkei_roads(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, road_id)
);

-- 残枠の算出
create or replace function public.credit_balance(p_user_id uuid)
returns integer language sql security definer stable as $$
  select coalesce(sum(amount), 0)::integer
  from public.view_credits
  where user_id = p_user_id
    and (expires_at is null or expires_at > now());
$$;

-- 絶景道を解放する。サブスク会員は枠を消費しない
create or replace function public.unlock_road(p_road_id uuid)
returns table (unlocked boolean, balance integer) language plpgsql security definer as $$
declare
  v_user uuid := auth.uid();
  v_plan text;
  v_balance integer;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.road_unlocks where user_id = v_user and road_id = p_road_id) then
    return query select true, public.credit_balance(v_user);
    return;
  end if;
  select plan into v_plan from public.profiles where id = v_user;
  if v_plan = 'subscriber' then
    insert into public.road_unlocks(user_id, road_id) values (v_user, p_road_id) on conflict do nothing;
    return query select true, public.credit_balance(v_user);
    return;
  end if;
  v_balance := public.credit_balance(v_user);
  if v_balance <= 0 then
    return query select false, v_balance;
    return;
  end if;
  insert into public.view_credits(user_id, kind, amount, ref_road_id) values (v_user, 'spend', -1, p_road_id);
  insert into public.road_unlocks(user_id, road_id) values (v_user, p_road_id) on conflict do nothing;
  return query select true, public.credit_balance(v_user);
end;
$$;

-- 投稿特典: 絶景道1件の評価投稿につき 3 枠（月末失効）
create or replace function public.trg_grant_contribution_credit()
returns trigger language plpgsql security definer as $$
begin
  insert into public.view_credits(user_id, kind, amount, expires_at, ref_road_id)
  values (new.user_id, 'contribution', 3, date_trunc('month', now()) + interval '1 month', new.road_id);
  return new;
end;
$$;
drop trigger if exists road_ratings_grant_credit on public.road_ratings;
create trigger road_ratings_grant_credit
after insert on public.road_ratings
for each row execute function public.trg_grant_contribution_credit();

-- 月次無料枠: 3 枠。月初に呼び出す（Supabase の pg_cron などで実行）
create or replace function public.grant_monthly_free_credits()
returns void language sql security definer as $$
  insert into public.view_credits(user_id, kind, amount, expires_at)
  select id, 'monthly_free', 3, date_trunc('month', now()) + interval '1 month'
  from public.profiles
  where not exists (
    select 1 from public.view_credits v
    where v.user_id = profiles.id and v.kind = 'monthly_free'
      and v.created_at >= date_trunc('month', now())
  );
$$;

-- ---------------------------------------------------------------
-- 通報・ブロック（Apple審査 1.2）
-- ---------------------------------------------------------------
create table if not exists public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (target_type in ('road', 'rating', 'user')),
  target_id   uuid not null,
  reason      text not null,
  status      text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  created_at  timestamptz not null default now()
);

create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

-- ---------------------------------------------------------------
-- 空間検索
-- ---------------------------------------------------------------
-- 周辺の絶景道（半径 m）
create or replace function public.nearby_roads(p_lat double precision, p_lng double precision, p_radius_m double precision default 30000)
returns setof public.zekkei_roads language sql security definer stable as $$
  select r.*
  from public.zekkei_roads r
  where r.status = 'published'
    and st_dwithin(r.geom, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
    and not exists (
      select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = r.created_by
    )
  order by r.rating_count desc
  limit 200;
$$;

-- 重なり判定: 投稿しようとしている区間(WKT)が既存の絶景道とどれだけ重なるか
-- 既存道の周囲 40m の帯に入っている長さ / 投稿区間の長さ を overlap_ratio として返す
create or replace function public.find_overlapping_road(p_wkt text, p_min_ratio double precision default 0.7)
returns table (road_id uuid, overlap_ratio double precision) language sql security definer stable as $$
  with cand as (
    select st_geogfromtext(p_wkt) as g
  )
  select r.id,
         st_length(st_intersection(cand.g::geometry, st_buffer(r.geom, 40)::geometry)::geography) / nullif(st_length(cand.g), 0) as ratio
  from public.zekkei_roads r, cand
  where r.status = 'published'
    and st_dwithin(r.geom, cand.g, 40)
  order by ratio desc
  limit 1
$$;

-- ---------------------------------------------------------------
-- 行レベルセキュリティ（本人以外は触れない鍵）
-- ---------------------------------------------------------------
alter table public.profiles     enable row level security;
alter table public.ride_logs    enable row level security;
alter table public.zekkei_roads enable row level security;
alter table public.road_ratings enable row level security;
alter table public.view_credits enable row level security;
alter table public.road_unlocks enable row level security;
alter table public.reports      enable row level security;
alter table public.blocks       enable row level security;

create policy "profiles: read all"   on public.profiles for select using (true);
create policy "profiles: self write" on public.profiles for insert with check (auth.uid() = id);
create policy "profiles: self update" on public.profiles for update using (auth.uid() = id);

create policy "ride_logs: self only" on public.ride_logs for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "roads: read published" on public.zekkei_roads for select using (status = 'published' or created_by = auth.uid());
create policy "roads: insert own"     on public.zekkei_roads for insert with check (auth.uid() = created_by);
create policy "roads: update own"     on public.zekkei_roads for update using (auth.uid() = created_by);

create policy "ratings: read published" on public.road_ratings for select using (status = 'published' or user_id = auth.uid());
create policy "ratings: insert own"     on public.road_ratings for insert with check (auth.uid() = user_id);
create policy "ratings: update own"     on public.road_ratings for update using (auth.uid() = user_id);
create policy "ratings: delete own"     on public.road_ratings for delete using (auth.uid() = user_id);

create policy "credits: read own"  on public.view_credits for select using (auth.uid() = user_id);
create policy "unlocks: read own"  on public.road_unlocks for select using (auth.uid() = user_id);

create policy "reports: insert own" on public.reports for insert with check (auth.uid() = reporter_id);
create policy "reports: read own"   on public.reports for select using (auth.uid() = reporter_id);

create policy "blocks: self manage" on public.blocks for all using (auth.uid() = blocker_id) with check (auth.uid() = blocker_id);

-- 新規会員登録時にプロフィール行を自動作成
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles(id, display_name, avatar_url)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', ''),
          new.raw_user_meta_data->>'avatar_url')
  on conflict (id) do nothing;
  -- 初回の無料枠
  insert into public.view_credits(user_id, kind, amount, expires_at)
  values (new.id, 'monthly_free', 3, date_trunc('month', now()) + interval '1 month');
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- 写真保管バケット
insert into storage.buckets (id, name, public) values ('road-photos', 'road-photos', true)
on conflict (id) do nothing;
