-- 関数の実行権限を必要なものだけに絞る
-- （Security Advisor の「Public / Signed-In Users Can Execute SECURITY DEFINER Function」への対応）
-- 方針: アプリが直接呼ぶ 5 つだけを許可し、内部処理（集計・トリガー・付与）は運用側からのみ実行できるようにする。
-- 地図計算の拡張機能（PostGIS）が持つ関数は対象外（除くとアプリが動かなくなるため）。
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind in ('f', 'p')
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke all on function %s from anon, authenticated', r.sig);
  end loop;
end $$;

-- 地図の閲覧はログイン前でも行うため anon にも許可する
grant execute on function public.nearby_roads(double precision, double precision, double precision, integer) to anon, authenticated;
-- 以下は本人確認が要る操作。ログイン済みのみ
grant execute on function public.find_overlapping_road(text, double precision) to authenticated;
grant execute on function public.credit_balance(uuid) to authenticated;
grant execute on function public.unlock_road(uuid) to authenticated;
grant execute on function public.set_display_name(text) to authenticated;
