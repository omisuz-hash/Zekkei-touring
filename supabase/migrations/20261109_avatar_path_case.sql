-- アイコンの保存先の照合を、英字の大小で弾かないようにする
--
-- iPhone 側が作る識別子は英大文字、データベース側の識別子は英小文字で表される。
-- 置き場所を「自分のフォルダか」で照合する際に、この差だけで拒否されていた。
-- （アイコンの登録で「new row violates row-level security policy」が出ていた原因）
-- iPhone 側も小文字で送るように直したが、過去の版からの書き込みも通るよう
-- ここでは大小を無視して照合する。

drop policy if exists "storage: own avatar write" on storage.objects;
create policy "storage: own avatar write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars'
              and lower((storage.foldername(name))[1]) = lower(auth.uid()::text));

create or replace function public.set_avatar_path(p_path text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v text := nullif(btrim(coalesce(p_path, '')), '');
begin
  if auth.uid() is null then
    raise exception 'ログインが必要です';
  end if;
  -- 自分のフォルダの中だけを受け付ける（英字の大小は問わない）
  if v is not null and lower(v) not like lower(auth.uid()::text) || '/%' then
    raise exception 'アイコンの保存先が不正です';
  end if;
  update public.profiles set avatar_url = v, updated_at = now() where id = auth.uid();
  return v;
end;
$$;

revoke execute on function public.set_avatar_path(text) from public, anon;
grant execute on function public.set_avatar_path(text) to authenticated;
