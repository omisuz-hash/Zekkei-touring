-- 関数の参照先スキーマを固定する（Supabase の Security Advisor の警告「function_search_path_mutable」への対応）
-- 目的: 権限を借りて動く関数（security definer）が、呼び出し側の設定で別のスキーマの同名関数を
--       掴まされることを防ぐ。関数の中身は変えず、参照先だけを public に固定する。
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and not exists (                      -- 拡張機能（PostGIS 等）が持つ関数は対象外
         select 1 from pg_depend d
          where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s set search_path = public, pg_temp', r.sig);
  end loop;
end $$;
