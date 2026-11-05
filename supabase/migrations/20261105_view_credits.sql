-- 閲覧枠が負の値になる不具合の修正
--
-- 原因は台帳の作りに 2 つの抜けがあったこと。
--   1. 付与（monthly_free / contribution）は月末で失効するのに、消費（spend）は
--      失効しない設定で記録していた。月をまたぐと付与だけが消え、消費だけが残る。
--      10 月に 3 枠を使い切った利用者は、11 月 1 日に残り -3 になる。
--   2. 月次の無料枠を配る grant_monthly_free_credits() を呼ぶ仕組みが無かった。
--      登録時の 1 回しか配られないため、翌月以降は枠が増えない。
--
-- 対処
--   1. 消費にも、その月の付与と同じ失効日を持たせる。月が替われば付与と消費が
--      対になって台帳から外れ、残りは 0 に戻る。購入枠（失効しない）を使った消費は
--      失効させない。
--   2. 残枠を読むときに、その月の無料枠がまだなら自動で配る。定期実行の仕組みに
--      頼らずに済む。
--   3. 念のため、表示する残枠は 0 を下回らないようにする。

-- ---------------------------------------------------------------
-- その月の無料枠をまだ配っていなければ配る
-- ---------------------------------------------------------------
create or replace function public.ensure_monthly_credit(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user_id is null then
    return;
  end if;
  if not exists (
    select 1 from public.view_credits
    where user_id = p_user_id and kind = 'monthly_free'
      and created_at >= date_trunc('month', now())
  ) and exists (select 1 from public.profiles where id = p_user_id) then
    insert into public.view_credits(user_id, kind, amount, expires_at)
    values (p_user_id, 'monthly_free', 3, date_trunc('month', now()) + interval '1 month');
  end if;
end;
$$;

-- ---------------------------------------------------------------
-- 残枠の算出。負の値は返さない
-- ---------------------------------------------------------------
create or replace function public.credit_balance(p_user_id uuid)
returns integer language sql security definer stable set search_path = public as $$
  select greatest(0, coalesce(sum(amount), 0))::integer
  from public.view_credits
  where user_id = p_user_id
    and (expires_at is null or expires_at > now());
$$;

-- ---------------------------------------------------------------
-- 本人の残枠。読むついでにその月の無料枠を配る
-- ---------------------------------------------------------------
create or replace function public.my_credit_balance()
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    return 0;
  end if;
  perform public.ensure_monthly_credit(v_user);
  return public.credit_balance(v_user);
end;
$$;

-- ---------------------------------------------------------------
-- 解放。消費にも失効日を持たせる
-- ---------------------------------------------------------------
create or replace function public.unlock_road(p_road_id uuid)
returns table (unlocked boolean, balance integer) language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_plan text;
  v_balance integer;
  v_perpetual integer;   -- 失効しない枠（購入分）の残り
  v_expires timestamptz;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.road_unlocks where user_id = v_user and road_id = p_road_id) then
    return query select true, public.credit_balance(v_user);
    return;
  end if;
  select plan into v_plan from public.profiles where id = v_user;
  if v_plan = 'subscriber' then
    insert into public.road_unlocks(user_id, road_id) values (v_user, p_road_id) on conflict do nothing;
    return query select true, public.credit_balance(v_user);
    return;
  end if;

  perform public.ensure_monthly_credit(v_user);
  v_balance := public.credit_balance(v_user);
  if v_balance <= 0 then
    return query select false, v_balance;
    return;
  end if;

  -- 失効しない枠が残っていればそちらから使い、その消費も失効させない。
  -- そうでなければ今月の付与を使うので、消費も今月末で失効させる
  select coalesce(sum(amount), 0)::integer into v_perpetual
  from public.view_credits
  where user_id = v_user and expires_at is null;
  v_expires := case when v_perpetual > 0 then null
                    else date_trunc('month', now()) + interval '1 month' end;

  insert into public.view_credits(user_id, kind, amount, expires_at, ref_road_id)
  values (v_user, 'spend', -1, v_expires, p_road_id);
  insert into public.road_unlocks(user_id, road_id) values (v_user, p_road_id) on conflict do nothing;
  return query select true, public.credit_balance(v_user);
end;
$$;

-- ---------------------------------------------------------------
-- 既存データの手当て: 失効日の無い消費のうち、失効する付与を使ったものに
-- 失効日を入れ直す。これで過去の月の消費が残り続けなくなる
-- ---------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select user_id from public.view_credits where kind = 'spend' and expires_at is null group by user_id
  loop
    -- その利用者が購入枠を持っていなければ、消費は全て失効する付与に対するもの
    if not exists (select 1 from public.view_credits
                   where user_id = r.user_id and kind = 'purchased') then
      update public.view_credits
         set expires_at = date_trunc('month', created_at) + interval '1 month'
       where user_id = r.user_id and kind = 'spend' and expires_at is null;
    end if;
  end loop;
end $$;

-- 実行権限（既定で PUBLIC に付くものを外し、ログイン済みにだけ許す）
revoke execute on function public.ensure_monthly_credit(uuid) from public, anon, authenticated;
revoke execute on function public.my_credit_balance() from public, anon;
revoke execute on function public.credit_balance(uuid) from public, anon;
revoke execute on function public.unlock_road(uuid) from public, anon;
grant execute on function public.my_credit_balance() to authenticated;
grant execute on function public.credit_balance(uuid) to authenticated;
grant execute on function public.unlock_road(uuid) to authenticated;
