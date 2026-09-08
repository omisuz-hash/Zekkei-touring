-- 前回の取り消しが効かなかった点の修正
-- Postgres では関数の作成時に「全員（PUBLIC）」へ実行権限が自動で付く。anon / authenticated は
-- その「全員」に含まれるため、両者からの取り消しだけでは実行できてしまう。ここで PUBLIC からも外す。
-- 補足: トリガーとして動く関数は、作成時に権限を確認する仕組みのため、実行時に影響はない。
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
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- アプリが実際に呼ぶ 5 つだけを許可し直す
grant execute on function public.nearby_roads(double precision, double precision, double precision, integer) to anon, authenticated;
grant execute on function public.find_overlapping_road(text, double precision) to authenticated;
grant execute on function public.credit_balance(uuid) to authenticated;
grant execute on function public.unlock_road(uuid) to authenticated;
grant execute on function public.set_display_name(text) to authenticated;

-- 運用側（管理用の鍵）からは従来どおり全て実行できるようにしておく
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
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;
