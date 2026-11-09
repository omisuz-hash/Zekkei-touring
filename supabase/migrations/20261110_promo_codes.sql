-- 招待コード（貢献してくれた動画の投稿者への謝意、および紹介経由の受け入れ）
--
-- 設計の要点
--   * コードは配布先ごとに分ける。使用回数がそのままチャンネル別の送客数になる
--   * 付与は 2 種類。一定期間の閲覧無制限（free_period）と、閲覧枠のまとめ付与（credits）
--   * 使用回数の上限とコード自体の有効期限を必ず持たせる（流出時の被害を限定する）
--   * 同じ人が同じコードを二度使えない

-- ---------------------------------------------------------------
-- 期間付きの閲覧無制限
-- ---------------------------------------------------------------
alter table public.profiles add column if not exists subscriber_until timestamptz;

-- 課金の plan と、期間付きの付与を 1 つの判定にまとめる
create or replace function public.is_subscriber(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(plan = 'subscriber' or subscriber_until > now(), false)
    from public.profiles where id = p_user
$$;

-- 本人の更新で書き換えられない列に subscriber_until を加える。
-- 付与は下の redeem_code（SECURITY DEFINER）だけが行い、その印を取引単位の設定で立てる
create or replace function public.trg_profiles_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and coalesce(current_setting('zekkeido.grant', true), '') <> 'on' then
    new.id              := old.id;
    new.plan            := old.plan;
    new.subscriber_until := old.subscriber_until;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------
-- コードの台帳
-- ---------------------------------------------------------------
create table if not exists public.promo_codes (
  code            text primary key,
  -- 配布先。チャンネル名など、誰に渡したかが後から分かる表記にする
  label           text not null default '',
  channel_id      text,
  kind            text not null check (kind in ('free_period', 'credits')),
  free_days       integer check (free_days between 1 and 1095),
  credits         integer check (credits between 1 and 1000),
  max_redemptions integer not null default 1 check (max_redemptions between 1 and 100000),
  redeemed_count  integer not null default 0,
  expires_at      timestamptz,
  disabled        boolean not null default false,
  note            text,
  created_at      timestamptz not null default now(),
  constraint promo_codes_grant_present check (
    (kind = 'free_period' and free_days is not null) or
    (kind = 'credits' and credits is not null))
);

create table if not exists public.promo_redemptions (
  code        text not null references public.promo_codes(code) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  redeemed_at timestamptz not null default now(),
  primary key (code, user_id)
);
create index if not exists promo_redemptions_code_idx on public.promo_redemptions(code);

-- 台帳そのものは利用者に見せない。使えるかどうかは下の関数の返事だけで分かる
alter table public.promo_codes       enable row level security;
alter table public.promo_redemptions enable row level security;
revoke all on public.promo_codes       from anon, authenticated;
revoke all on public.promo_redemptions from anon, authenticated;
grant select, insert, update, delete on public.promo_codes       to service_role;
grant select, insert, update, delete on public.promo_redemptions to service_role;

-- ---------------------------------------------------------------
-- コードを使う
-- ---------------------------------------------------------------
create or replace function public.redeem_code(p_code text)
returns table (ok boolean, message text, kind text, free_until timestamptz, balance integer)
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  c      public.promo_codes%rowtype;
  v_base timestamptz;
  v_until timestamptz;
begin
  if v_user is null then
    raise exception 'ログインが必要です';
  end if;
  if v_code = '' then
    return query select false, 'コードを入力してください', null::text, null::timestamptz, public.credit_balance(v_user);
    return;
  end if;

  -- 同時に使われても二重に付与しないよう、行を押さえてから判定する
  select * into c from public.promo_codes where code = v_code for update;
  if not found or c.disabled then
    return query select false, 'このコードは使えません', null::text, null::timestamptz, public.credit_balance(v_user);
    return;
  end if;
  if c.expires_at is not null and c.expires_at <= now() then
    return query select false, 'このコードは期限切れです', null::text, null::timestamptz, public.credit_balance(v_user);
    return;
  end if;
  if exists (select 1 from public.promo_redemptions where code = v_code and user_id = v_user) then
    return query select false, 'このコードは使用済みです', null::text, null::timestamptz, public.credit_balance(v_user);
    return;
  end if;
  if c.redeemed_count >= c.max_redemptions then
    return query select false, 'このコードは上限に達しました', null::text, null::timestamptz, public.credit_balance(v_user);
    return;
  end if;

  insert into public.promo_redemptions(code, user_id) values (v_code, v_user);
  update public.promo_codes set redeemed_count = redeemed_count + 1 where code = v_code;

  if c.kind = 'free_period' then
    -- 残っている期間があれば、そこから足す
    select greatest(coalesce(subscriber_until, now()), now()) into v_base
      from public.profiles where id = v_user;
    v_until := v_base + make_interval(days => c.free_days);
    perform set_config('zekkeido.grant', 'on', true);
    update public.profiles set subscriber_until = v_until, updated_at = now() where id = v_user;
    return query select true, c.free_days || ' 日間、絶景道の詳細を枠なしで見られます',
                        c.kind, v_until, public.credit_balance(v_user);
  else
    -- まとめ付与の枠は失効させない（お礼として渡すため）
    insert into public.view_credits(user_id, kind, amount, expires_at)
    values (v_user, 'purchased', c.credits, null);
    return query select true, '閲覧枠が ' || c.credits || ' つ増えました',
                        c.kind, null::timestamptz, public.credit_balance(v_user);
  end if;
end;
$$;

revoke execute on function public.redeem_code(text) from public, anon;
grant   execute on function public.redeem_code(text) to authenticated;
revoke execute on function public.is_subscriber(uuid) from public, anon;
grant   execute on function public.is_subscriber(uuid) to authenticated;

-- ---------------------------------------------------------------
-- 解放の判定を、期間付きの付与にも対応させる
-- ---------------------------------------------------------------
create or replace function public.unlock_road(p_road_id uuid)
returns table (unlocked boolean, balance integer) language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_balance integer;
  v_perpetual integer;
  v_expires timestamptz;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from public.road_unlocks where user_id = v_user and road_id = p_road_id) then
    return query select true, public.credit_balance(v_user);
    return;
  end if;
  if public.is_subscriber(v_user) then
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
