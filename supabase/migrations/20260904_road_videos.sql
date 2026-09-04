-- 1 本の絶景道に複数の動画を紐づける。自動収集のシード管理用の列も追加
create table if not exists public.road_videos (
  id              bigserial primary key,
  road_id         uuid not null references public.zekkei_roads(id) on delete cascade,
  video_id        text not null,
  url             text not null,
  title           text,
  channel         text,
  view_count      integer,
  timestamp_label text,           -- 動画内でこの道が登場する時刻（例: 15:14）
  created_at      timestamptz not null default now(),
  unique (road_id, video_id)
);
create index if not exists road_videos_road_idx on public.road_videos(road_id);

alter table public.zekkei_roads add column if not exists source text not null default 'user'
  check (source in ('user', 'seed_manual', 'seed_auto'));
alter table public.zekkei_roads add column if not exists geometry_quality text not null default 'gps'
  check (geometry_quality in ('gps', 'routed', 'approx'));
-- 自動収集の再実行で同じ道を二重登録しないためのキー
alter table public.zekkei_roads add column if not exists seed_key text unique;

update public.zekkei_roads set source = 'seed_manual', geometry_quality = 'approx' where is_seed and source = 'user';

alter table public.road_videos enable row level security;
create policy "road_videos: read all" on public.road_videos for select using (true);
