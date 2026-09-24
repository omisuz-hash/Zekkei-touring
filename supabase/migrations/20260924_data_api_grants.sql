-- 2026-10-30 の Supabase 仕様変更への備え
-- それ以降に作られた public スキーマの表は、明示的に権限を与えないとアプリから見えなくなる。
-- 既存の表は影響を受けないが、プロジェクトを作り直した場合に同じ状態を再現できるよう、
-- ここで全ての表の権限を明示しておく。行ごとの出し分けは従来どおり RLS が担う。
do $$
declare t text;
begin
  -- ログイン前でも読める表（地図の閲覧に必要）
  foreach t in array array['zekkei_roads', 'road_videos', 'road_spots', 'road_media', 'road_ratings', 'profiles']
  loop
    execute format('grant select on public.%I to anon', t);
  end loop;

  -- ログイン済みが読み書きする表
  foreach t in array array['zekkei_roads', 'road_videos', 'road_spots', 'road_media', 'road_ratings', 'profiles',
                           'ride_logs', 'view_credits', 'road_unlocks', 'reports', 'blocks']
  loop
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;

-- 注意: public.schema_migrations は運用専用のため、ここでは権限を与えない（意図的）
