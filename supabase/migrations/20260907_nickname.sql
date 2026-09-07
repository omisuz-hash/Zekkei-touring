-- 表示名は匿名のニックネームを既定にする（Google の実名・アイコンは取り込まない）
-- 目的: 荒らし対策としてログインは必須にしつつ、投稿は匿名で行えるようにする

alter table public.profiles add column if not exists display_name_set boolean not null default false;

-- 既存の自動生成名（ニックネーム未設定）は匿名名に置き換える
create or replace function public.random_rider_name()
returns text language sql volatile as $$
  select 'ライダー' || lpad((floor(random() * 10000))::int::text, 4, '0');
$$;

update public.profiles
   set display_name = public.random_rider_name(), avatar_url = null
 where display_name_set = false;

-- 新規登録時: 実名・アイコンを取り込まず、匿名のニックネームを割り当てる
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, public.random_rider_name())
  on conflict (id) do nothing;
  insert into public.view_credits(user_id, kind, amount, expires_at)
  values (new.id, 'monthly_free', 3, date_trunc('month', now()) + interval '1 month');
  return new;
end;
$$;

-- ニックネームの更新（長さと中身を検査し、display_name_set を立てる）
create or replace function public.set_display_name(p_name text)
returns text language plpgsql security definer as $$
declare
  v text := btrim(p_name);
begin
  if auth.uid() is null then
    raise exception 'ログインが必要です';
  end if;
  if char_length(v) < 2 or char_length(v) > 20 then
    raise exception 'ニックネームは 2〜20 文字で入力してください';
  end if;
  if v ~* '(https?://|www\.|@[a-z0-9_]{3,})' then
    raise exception 'ニックネームに URL やアカウント名は使用できません';
  end if;
  update public.profiles
     set display_name = v, display_name_set = true, updated_at = now()
   where id = auth.uid();
  return v;
end;
$$;
