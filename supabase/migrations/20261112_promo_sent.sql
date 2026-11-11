-- 招待コードを「いつ誰に送ったか」を台帳に残す
--
-- 送付先の一覧と、発行したコードの一覧が別のファイルに分かれており、
-- 突き合わせを手作業で行っていた。送った記録も手元にしか残らない。
-- コードの台帳に送付日を持たせ、1 つの表で追えるようにする。

alter table public.promo_codes add column if not exists sent_at timestamptz;
comment on column public.promo_codes.sent_at is '配布先へ案内を送った日時。未送付は null';
