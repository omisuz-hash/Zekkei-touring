-- アプリ内からのアカウント削除（Apple ガイドライン 5.1.1(v) の必須要件）
-- 方針:
--   * 本人に属する情報（プロフィール・走行記録・評価・写真・閲覧枠・通報・ブロック）は消す
--   * 公開済みの絶景道そのものは残し、投稿者の結び付けだけを外す（他の利用者が閲覧枠を使って見た情報を
--     一方的に失わせないため）。この扱いは削除前の確認画面で明示する
create or replace function public.delete_account()
returns void language plpgsql security definer as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'ログインが必要です';
  end if;

  -- 公開した絶景道は残し、投稿者との結び付けのみ外す
  update public.zekkei_roads set created_by = null where created_by = uid;

  -- 本人の情報を消す（road_media・road_ratings は profiles への参照で連鎖削除されるが、明示しておく）
  delete from public.road_media   where user_id = uid;
  delete from public.road_ratings where user_id = uid;
  delete from public.ride_logs    where user_id = uid;
  delete from public.view_credits where user_id = uid;
  delete from public.road_unlocks where user_id = uid;
  delete from public.reports      where reporter_id = uid;
  delete from public.blocks       where blocker_id = uid or blocked_id = uid;
  delete from public.profiles     where id = uid;

  -- 認証そのものを削除（profiles は auth.users の連鎖削除対象でもある）
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
