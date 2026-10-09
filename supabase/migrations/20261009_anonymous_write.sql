-- 匿名ログイン（ゲスト）からの書き込みを止める
-- 方針: 閲覧は匿名のまま、投稿・評価・写真・通報は正規のログイン（Apple / Google）を求める。
--       荒らし対策のためログインは要求するが、表示は匿名のニックネームのまま、という設計は変えない。
create or replace function public.is_real_user()
returns boolean language sql stable security invoker as $$
  select auth.uid() is not null
     and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false;
$$;
alter function public.is_real_user() set search_path = public, pg_temp;
grant execute on function public.is_real_user() to anon, authenticated, service_role;

-- 追加のみを制限する表（閲覧の条件は変えない）
do $$
declare t record;
begin
  for t in
    select * from (values
      ('zekkei_roads', 'roads: insert own',   'created_by'),
      ('road_ratings', 'ratings: insert own', 'user_id'),
      ('road_media',   'media: insert own',   'user_id'),
      ('reports',      'reports: insert own', 'reporter_id')
    ) as v(tbl, pol, col)
  loop
    execute format('drop policy if exists %I on public.%I', t.pol, t.tbl);
    execute format(
      'create policy %I on public.%I for insert with check (auth.uid() = %I and public.is_real_user())',
      t.pol, t.tbl, t.col);
  end loop;
end $$;

-- 走行記録は 1 つの方針で全操作を覆っているため、作り直して書き込み条件だけ足す
-- （閲覧は従来どおり本人のみ。自宅周辺を含むため公開しない方針は変えない）
drop policy if exists "ride_logs: self only" on public.ride_logs;
create policy "ride_logs: self only" on public.ride_logs
  for all using (auth.uid() = user_id)
  with check (auth.uid() = user_id and public.is_real_user());
