-- 立ち寄りスポットの代表写真（Wikimedia Commons の自由ライセンス写真、または紹介動画のサムネイル）
alter table public.road_spots add column if not exists photo_url text;
alter table public.road_spots add column if not exists photo_credit text;   -- 撮影者と ライセンス（表示義務）
alter table public.road_spots add column if not exists photo_source text;   -- commons / youtube / user
