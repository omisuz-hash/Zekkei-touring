-- 動画から推定した示唆値（ライダー評価が付くまでの暫定スコア）と、動画での言及数
alter table public.zekkei_roads add column if not exists hint_scenery numeric(3,2);
alter table public.zekkei_roads add column if not exists hint_winding numeric(3,2);
alter table public.zekkei_roads add column if not exists hint_surface numeric(3,2);
alter table public.zekkei_roads add column if not exists hint_rest numeric(3,2);
alter table public.zekkei_roads add column if not exists hint_parking numeric(3,2);
alter table public.zekkei_roads add column if not exists mention_count integer not null default 0;
create index if not exists zekkei_roads_hint_scenery_idx on public.zekkei_roads(hint_scenery desc nulls last);
