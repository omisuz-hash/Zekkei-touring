-- 自分が投稿した絶景道は、閲覧枠を使わずに見られるようにする
--
-- 評価を投稿しても、その道の詳細（評価の内訳・立ち寄りスポット・ナビ・自分が
-- 上げた写真や動画）を見るには閲覧枠を 1 つ消費する必要があった。
-- 自分の貢献を確かめるのに枠を使わせるのは筋が通らないため、投稿と同時に
-- その道を解放済みにする。枠は消費しない。

create or replace function public.trg_grant_contribution_credit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.view_credits(user_id, kind, amount, expires_at, ref_road_id)
  values (new.user_id, 'contribution', 3, date_trunc('month', now()) + interval '1 month', new.road_id);
  -- 投稿した本人は、その道を枠なしで見られる
  insert into public.road_unlocks(user_id, road_id)
  values (new.user_id, new.road_id)
  on conflict do nothing;
  return new;
end;
$$;

-- すでに投稿済みの道にも遡って適用する
insert into public.road_unlocks(user_id, road_id)
select distinct user_id, road_id from public.road_ratings where status = 'published'
on conflict do nothing;
