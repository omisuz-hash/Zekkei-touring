-- 利用者のアイコン（多くは自分のバイクの写真）と、プロフィール更新の締め直し
--
-- 1. アイコンを置く保管場所を用意する。本人だけが自分のフォルダに置ける。
--    参照は誰でもできる（投稿の横に出すため）。
-- 2. プロフィールの更新ポリシーが全ての列を対象にしていたため、本人が
--    plan を 'subscriber' に書き換えられる状態だった。課金状態と識別子は
--    本人の更新では変えられないようにする。

-- ---------------------------------------------------------------
-- アイコンの保管場所
-- ---------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 3145728, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update
  set public = true, file_size_limit = 3145728,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/heic'];

drop policy if exists "storage: public read avatars" on storage.objects;
create policy "storage: public read avatars" on storage.objects
  for select using (bucket_id = 'avatars');

drop policy if exists "storage: own avatar write" on storage.objects;
create policy "storage: own avatar write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and owner = auth.uid()
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "storage: own avatar update" on storage.objects;
create policy "storage: own avatar update" on storage.objects
  for update to authenticated using (bucket_id = 'avatars' and owner = auth.uid());

drop policy if exists "storage: own avatar delete" on storage.objects;
create policy "storage: own avatar delete" on storage.objects
  for delete to authenticated using (bucket_id = 'avatars' and owner = auth.uid());

-- ---------------------------------------------------------------
-- アイコンの設定（保管場所の中の位置を記録する。null で解除）
-- ---------------------------------------------------------------
create or replace function public.set_avatar_path(p_path text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v text := nullif(btrim(coalesce(p_path, '')), '');
begin
  if auth.uid() is null then
    raise exception 'ログインが必要です';
  end if;
  -- 自分のフォルダの中だけを受け付ける
  if v is not null and v not like auth.uid()::text || '/%' then
    raise exception 'アイコンの保存先が不正です';
  end if;
  update public.profiles set avatar_url = v, updated_at = now() where id = auth.uid();
  return v;
end;
$$;

revoke execute on function public.set_avatar_path(text) from public, anon;
grant execute on function public.set_avatar_path(text) to authenticated;

-- ---------------------------------------------------------------
-- 課金状態と識別子は本人の更新では変えさせない
-- ---------------------------------------------------------------
create or replace function public.trg_profiles_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- 購入の確認はサーバー側（service_role）で行う。利用者の操作では変えられない
  if coalesce(auth.role(), '') <> 'service_role' then
    new.id   := old.id;
    new.plan := old.plan;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard
before update on public.profiles
for each row execute function public.trg_profiles_guard();
