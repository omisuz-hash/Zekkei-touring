-- 自分の投稿を取り消せるようにする
--
-- 投稿後に、区間の切り出しを誤った（自宅や別荘からの移動区間まで含めてしまった等）
-- ことに気づいても、消す手段が無かった。zekkei_roads には削除のポリシーが無く、
-- 本人であっても自分が作った道を消せない状態だった。
--
-- 消せるのは次の範囲に限る。
--   * 自分が付けた評価と、自分が上げた写真・動画
--   * 自分が作った道で、かつ他の人の評価がまだ付いていないもの
-- 他の人の評価が付いた道は、共有の情報になっているため残す。

create or replace function public.delete_my_contribution(p_road_id uuid)
returns table (road_deleted boolean) language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_deleted integer := 0;
begin
  if v_user is null then
    raise exception 'ログインが必要です';
  end if;

  delete from public.road_media   where road_id = p_road_id and user_id = v_user;
  -- 評価を消すと、集計のトリガーが道のスコアと件数を戻す
  delete from public.road_ratings where road_id = p_road_id and user_id = v_user;

  -- 自分が作った道で、他の人の評価も残っていなければ道ごと消す
  with gone as (
    delete from public.zekkei_roads r
     where r.id = p_road_id
       and r.created_by = v_user
       and not exists (select 1 from public.road_ratings x where x.road_id = r.id)
    returning 1
  )
  select count(*) into v_deleted from gone;

  return query select v_deleted > 0;
end;
$$;

revoke execute on function public.delete_my_contribution(uuid) from public, anon;
grant execute on function public.delete_my_contribution(uuid) to authenticated;
