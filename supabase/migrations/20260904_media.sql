-- 写真・動画の投稿
-- 方針:
--   * 写真は端末側で長辺 1600px の JPEG に縮小してから保存（1枚 300KB 前後）
--   * 動画は端末側で 720p / 最大 30 秒 / mp4 に圧縮してから保存（1本 10〜20MB 程度）
--   * 長い動画はファイルではなく YouTube の URL で紹介する（配信コスト対策）
--   * 保管先: Supabase Storage のバケット road-photos / road-videos

create table if not exists public.road_media (
  id             uuid primary key default gen_random_uuid(),
  road_id        uuid not null references public.zekkei_roads(id) on delete cascade,
  rating_id      uuid references public.road_ratings(id) on delete set null,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  kind           text not null check (kind in ('photo', 'video')),
  bucket         text not null,
  storage_path   text not null,
  thumbnail_path text,
  width          integer,
  height         integer,
  duration_s     double precision,
  bytes          integer,
  status         text not null default 'published' check (status in ('published', 'hidden', 'removed')),
  created_at     timestamptz not null default now()
);
create index if not exists road_media_road_idx on public.road_media(road_id);
create index if not exists road_media_user_idx on public.road_media(user_id);

-- 評価に紹介動画（YouTube 等）の URL を持たせる
alter table public.road_ratings add column if not exists video_url text;

-- 絶景道側に枚数と代表写真を非正規化
alter table public.zekkei_roads add column if not exists media_count integer not null default 0;
alter table public.zekkei_roads add column if not exists cover_path text;

create or replace function public.refresh_road_media(p_road_id uuid)
returns void language sql security definer as $$
  update public.zekkei_roads r set
    media_count = s.cnt,
    cover_path  = s.cover,
    updated_at  = now()
  from (
    select count(*) cnt,
           (select coalesce(thumbnail_path, storage_path) from public.road_media m2
             where m2.road_id = p_road_id and m2.status = 'published'
             order by (m2.kind = 'photo') desc, m2.created_at asc limit 1) cover
    from public.road_media
    where road_id = p_road_id and status = 'published'
  ) s
  where r.id = p_road_id;
$$;

create or replace function public.trg_road_media_refresh()
returns trigger language plpgsql security definer as $$
begin
  perform public.refresh_road_media(coalesce(new.road_id, old.road_id));
  return null;
end;
$$;
drop trigger if exists road_media_refresh on public.road_media;
create trigger road_media_refresh
after insert or update or delete on public.road_media
for each row execute function public.trg_road_media_refresh();

alter table public.road_media enable row level security;
create policy "media: read published" on public.road_media for select using (status = 'published' or user_id = auth.uid());
create policy "media: insert own"     on public.road_media for insert with check (auth.uid() = user_id);
create policy "media: update own"     on public.road_media for update using (auth.uid() = user_id);
create policy "media: delete own"     on public.road_media for delete using (auth.uid() = user_id);

-- 保管バケット（公開読み取り、書き込みは本人のみ）
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('road-photos', 'road-photos', true, 5242880, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg'];

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('road-videos', 'road-videos', true, 52428800, array['video/mp4', 'video/quicktime'])
on conflict (id) do nothing;

-- ファイルのパスは「<road_id>/<media_id>.<ext>」。書き込みはログイン済み本人のみ
create policy "storage: public read photos" on storage.objects for select using (bucket_id in ('road-photos', 'road-videos'));
create policy "storage: auth upload photos" on storage.objects for insert
  with check (bucket_id in ('road-photos', 'road-videos') and auth.role() = 'authenticated' and owner = auth.uid());
create policy "storage: owner delete" on storage.objects for delete
  using (bucket_id in ('road-photos', 'road-videos') and owner = auth.uid());
