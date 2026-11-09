#!/usr/bin/env python3
"""Supabase のデータベースを Mac から操作する（追加インストール不要・Python 標準ライブラリのみ）。

  python3 20260905_db_admin.py check     接続と鍵の確認
  python3 20260905_db_admin.py migrate   supabase/migrations/*.sql を日付順に適用（適用済みは飛ばす）
  python3 20260905_db_admin.py seed      手作業シードと自動収集シード（最新の *_seed_roads_auto.sql）を流し込む
  python3 20260905_db_admin.py stats     道・動画・会員の件数
  python3 20260905_db_admin.py ping      アプリと同じ経路（REST API）で 1 回読む。無料枠の自動停止（7 日間無通信）を避けるため
  python3 20260905_db_admin.py sql "select count(*) from zekkei_roads"   任意の SQL（管理用）
  python3 20260905_db_admin.py auth      ログイン方法（Apple / Google / 匿名）の現在の設定を表示
  python3 20260905_db_admin.py auth-apply   同上を設定する（バックアップ → 適用 → 検証 → 失敗なら自動で戻す）
  python3 20260905_db_admin.py codes --help      招待コードの一覧と使用状況（CSV にも出せる）
  python3 20260905_db_admin.py codes-new --help   招待コードを発行する（配布先ごとに 1 つ）
  python3 20260905_db_admin.py codes-set --help   発行済みのコードの期限を延ばす・停止する

接続情報は ~/.zekkei_supabase（20260905_setup_supabase.sh で作成）から読む。
SQL の実行には Supabase の管理 API（Personal Access Token）を使う。
"""
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(f"環境変数 {name} が未設定です。先に  source ~/.zekkei_supabase  を実行してください。")
    return v


def project_ref() -> str:
    url = env("SUPABASE_URL")
    m = re.match(r"https?://([a-z0-9-]+)\.supabase\.co", url)
    if not m:
        sys.exit(f"SUPABASE_URL の形式が想定と違います: {url}")
    return m.group(1)


def api(method: str, url: str, body: dict | None = None, headers: dict | None = None, timeout: int = 300):
    data = json.dumps(body).encode() if body is not None else None
    # Supabase の管理 API は Python 標準の名乗り（User-Agent）を拒否するため、ツール名を名乗る
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", "Accept": "application/json",
                                          "User-Agent": "zekkei-touring-db-admin/1.0 (+https://github.com/omisuz-hash/Zekkei-touring)",
                                          **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read().decode("utf-8", "ignore")
            return json.loads(text) if text else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode('utf-8', 'ignore')[:600]}")


def run_sql(query: str):
    """管理 API で SQL を実行（複数文可）"""
    ref = project_ref()
    return api("POST", f"https://api.supabase.com/v1/projects/{ref}/database/query",
               {"query": query}, {"Authorization": f"Bearer {env('SUPABASE_ACCESS_TOKEN')}"})


def cmd_check():
    ok = True
    ref = project_ref()
    print(f"プロジェクト: {ref}")
    try:
        r = run_sql("select version() as v, current_user as u")
        print(f"  OK   管理 API（SQL 実行）: {r[0]['u']} / {r[0]['v'][:22]}")
    except Exception as e:
        ok = False
        print(f"  NG   管理 API: {e}\n       Personal Access Token（SUPABASE_ACCESS_TOKEN）が無効か、権限がありません")
    def key_ok(key: str) -> tuple[bool, str]:
        # 表がまだ無い段階でも鍵の有効性だけを確かめる。401/403 なら鍵が無効、それ以外（404 等）は鍵は通っている
        try:
            api("GET", f"{env('SUPABASE_URL')}/rest/v1/zekkei_roads?select=id&limit=1",
                headers={"apikey": key, "Authorization": f"Bearer {key}"})
            return True, "表にアクセスできます"
        except RuntimeError as e:
            msg = str(e)
            if msg.startswith("HTTP 401") or msg.startswith("HTTP 403"):
                return False, msg
            return True, "鍵は有効（表はまだ未作成）" if msg.startswith("HTTP 404") else msg[:80]
    for label, name in (("アプリ用の鍵（Publishable / anon）", "SUPABASE_PUBLISHABLE_KEY"), ("管理用の鍵（Secret / service_role）", "SUPABASE_SECRET_KEY")):
        good, msg = key_ok(env(name))
        ok = ok and good
        print(f"  {'OK' if good else 'NG'}   {label}: {msg}")
    print("結果:", "すべて OK" if ok else "問題あり")
    return ok


def ensure_migrations_table():
    run_sql("create table if not exists public.schema_migrations (name text primary key, applied_at timestamptz not null default now())")
    # 適用履歴は運用者だけが読み書きする表。アプリの鍵からは触れないように閉じる
    # （行レベルの保護を有効にし、方針を 1 つも置かない = 一般の鍵からは 0 件に見える）
    run_sql("alter table public.schema_migrations enable row level security")
    run_sql("revoke all on public.schema_migrations from anon, authenticated")


def cmd_migrate():
    ensure_migrations_table()
    applied = {r["name"] for r in (run_sql("select name from public.schema_migrations") or [])}
    files = sorted(glob.glob(os.path.join(REPO, "supabase", "migrations", "*.sql")))
    n = 0
    for f in files:
        name = os.path.basename(f)
        if name in applied:
            print(f"  済   {name}")
            continue
        sql = open(f, encoding="utf-8").read()
        try:
            run_sql(sql)
            run_sql(f"insert into public.schema_migrations(name) values ('{name}')")
            print(f"  OK   {name}")
            n += 1
        except Exception as e:
            print(f"  NG   {name}: {e}")
            sys.exit("ここで停止しました。エラー文を Claude に貼ってください。")
    print(f"適用 {n} 件（合計 {len(files)} 件）")


def split_statements(sql: str) -> list[str]:
    """自動収集シードを 1 文ずつに分ける。文の終わり（; と改行）の直後に次の文（with / insert）が始まる所で区切る"""
    out = []
    for p in re.split(r";\s*\n(?=(?:with r as|insert into|--))", sql):
        lines = [l for l in p.strip().splitlines()]
        while lines and lines[0].startswith("--"):
            lines.pop(0)
        body = "\n".join(lines).strip().rstrip(";")
        if body:
            out.append(body + ";")
    return out


def cmd_seed():
    ensure_migrations_table()
    applied = {r["name"] for r in (run_sql("select name from public.schema_migrations") or [])}
    # 1. 手作業シード（22 本）。1 回だけ
    manual = sorted(glob.glob(os.path.join(REPO, "supabase", "seed", "*.sql")))
    for f in manual:
        name = "seed:" + os.path.basename(f)
        if name in applied:
            print(f"  済   {os.path.basename(f)}")
            continue
        run_sql(open(f, encoding="utf-8").read())
        run_sql(f"insert into public.schema_migrations(name) values ('{name}')")
        print(f"  OK   {os.path.basename(f)}")
    # 2. 自動収集シード（最新ファイル）。seed_key で重複しないため何度流しても安全
    autos = sorted(glob.glob(os.path.join(REPO, "tools", "seedpipeline", "out", "*_seed_roads_auto.sql")))
    if not autos:
        print("自動収集シードが見つかりません（tools/seedpipeline/out/*_seed_roads_auto.sql）")
        return
    latest = autos[-1]
    sql = open(latest, encoding="utf-8").read()
    stmts = [s for s in split_statements(sql) if "insert into public." in s]
    n_roads = sum(1 for s in stmts if "insert into public.zekkei_roads" in s)
    n_spots = sum(1 for s in stmts if "insert into public.road_spots" in s)
    n_photo = sum(s.count("'commons')") + s.count("'wikipedia')") + s.count("'youtube')") for s in stmts if "insert into public.road_spots" in s)
    print(f"自動収集シード {os.path.basename(latest)}: 道 {n_roads} 本、スポット付きの道 {n_spots} 本（写真付きスポット {n_photo} 件）を流し込みます")
    ok = ng = 0
    batch = 25
    for i in range(0, len(stmts), batch):
        chunk = "\n".join(stmts[i:i + batch])
        try:
            run_sql(chunk)
            ok += len(stmts[i:i + batch])
        except Exception as e:
            # まとめて失敗したら 1 本ずつ流して、悪い 1 本だけ飛ばす
            for s in stmts[i:i + batch]:
                try:
                    run_sql(s); ok += 1
                except Exception as e2:
                    ng += 1
                    m = re.search(r"values \('([^']+)'", s)
                    print(f"  NG   {m.group(1) if m else '?'}: {str(e2)[:120]}")
        print(f"  … {min(i + batch, len(stmts))}/{len(stmts)}", flush=True)
    print(f"完了: 成功 {ok} 文 / 失敗 {ng} 文（道 1 本 = 1 文、スポットのある道はもう 1 文）")


def cmd_stats():
    q = """select
      (select count(*) from public.zekkei_roads) as roads,
      (select count(*) from public.zekkei_roads where source='seed_auto') as roads_auto,
      (select count(*) from public.road_videos) as videos,
      (select count(*) from public.road_spots) as spots,
      (select count(*) from public.road_spots where photo_url is not null) as spots_with_photo,
      (select count(*) from public.road_ratings) as ratings,
      (select count(*) from public.profiles) as users"""
    r = run_sql(q)[0]
    for k, v in r.items():
        print(f"{k}: {v}")


def cmd_ping():
    """アプリと同じ経路（REST API + アプリ用の鍵）で軽く読む。
    管理 API 経由の書き込みは Supabase の「利用実績」に数えられないため、無料枠では
    これが無いと 7 日間無通信と判定され、プロジェクトが自動停止される。"""
    url = f"{env('SUPABASE_URL')}/rest/v1/zekkei_roads?select=id&limit=1"
    key = env("SUPABASE_PUBLISHABLE_KEY")
    try:
        api("GET", url, headers={"apikey": key, "Authorization": f"Bearer {key}"})
        print("OK   REST API に到達しました（利用実績として記録されます）")
        return True
    except Exception as e:
        print(f"NG   REST API に到達できません: {e}")
        return False


AUTH_KEYS = ("external_apple_enabled", "external_apple_client_id", "external_apple_additional_client_ids",
             "external_google_enabled", "external_google_client_id", "external_google_additional_client_ids",
             "external_google_skip_nonce_check", "external_anonymous_users_enabled", "site_url")
BACKUP_DIR = os.path.expanduser("~/.zekkei_backups")


def auth_config() -> dict:
    ref = project_ref()
    return api("GET", f"https://api.supabase.com/v1/projects/{ref}/config/auth",
               None, {"Authorization": f"Bearer {env('SUPABASE_ACCESS_TOKEN')}"}) or {}


def auth_patch(body: dict) -> dict:
    ref = project_ref()
    return api("PATCH", f"https://api.supabase.com/v1/projects/{ref}/config/auth",
               body, {"Authorization": f"Bearer {env('SUPABASE_ACCESS_TOKEN')}"}) or {}


def show_auth(cfg: dict, title: str = "現在の設定"):
    print(f"-- {title} --")
    for k in AUTH_KEYS:
        if k in cfg:
            print(f"  {k}: {cfg[k]!r}")
    unknown = [k for k in AUTH_KEYS if k not in cfg]
    if unknown:
        print(f"  （この Supabase では未提供の項目: {', '.join(unknown)}）")


def cmd_auth():
    show_auth(auth_config())
    print("\n変更するには auth-apply を実行してください。")


def cmd_auth_apply():
    """Apple / Google のログインを有効にする。
    Apple は iOS アプリのバンドル ID を、Google は iOS の OAuth クライアント ID を受け付ける。
    Google のクライアント ID は環境変数 GOOGLE_IOS_CLIENT_ID から読み、未設定なら Google は触らない。"""
    bundle_id = os.environ.get("ZEKKEI_BUNDLE_ID", "com.zekkeido.app").strip()
    google_id = os.environ.get("GOOGLE_IOS_CLIENT_ID", "").strip()

    before = auth_config()
    os.makedirs(BACKUP_DIR, mode=0o700, exist_ok=True)
    stamp = __import__("datetime").datetime.now().strftime("%Y%m%d%H%M%S")
    backup = os.path.join(BACKUP_DIR, f"auth_config_{stamp}.json")
    with open(backup, "w", encoding="utf-8") as f:
        json.dump(before, f, ensure_ascii=False, indent=2)
    os.chmod(backup, 0o600)
    print(f"バックアップ: {backup}")
    show_auth(before, "変更前")

    want = {"external_apple_enabled": True, "external_apple_client_id": bundle_id}
    if google_id:
        # iOS の GoogleSignIn は nonce を付けないため、その検証を外す必要がある
        want.update({"external_google_enabled": True, "external_google_client_id": google_id,
                     "external_google_skip_nonce_check": True})
    else:
        print("GOOGLE_IOS_CLIENT_ID が未設定のため、Google は変更しません（Apple のみ設定します）。")
    # この Supabase が受け付けない項目は送らない
    want = {k: v for k, v in want.items() if k in before or k.startswith("external_")}

    print("\n-- これから設定する内容 --")
    for k, v in want.items():
        print(f"  {k}: {before.get(k)!r} → {v!r}")
    if input("\n適用しますか（yes と入力）: ").strip() != "yes":
        print("中止しました。設定は変更していません。")
        return

    try:
        auth_patch(want)
    except RuntimeError as e:
        print(f"適用に失敗しました: {e}")
        print("設定は変更されていません。")
        return

    after = auth_config()
    bad = {k: (v, after.get(k)) for k, v in want.items() if after.get(k) != v}
    if bad:
        print("\n検証に失敗しました。次の項目が反映されていません:")
        for k, (want_v, got) in bad.items():
            print(f"  {k}: 期待 {want_v!r} / 実際 {got!r}")
        print("バックアップの値に戻します。")
        auth_patch({k: before[k] for k in want if k in before})
        show_auth(auth_config(), "戻した結果")
        return
    show_auth(after, "変更後")
    print("\n完了しました。iPhone でアプリを開き直してログインを試してください。")


# ---------------------------------------------------------------
# 招待コード
# ---------------------------------------------------------------
# 紛らわしい字（0/O、1/I/L）を外した英数字。口頭でも伝えられるようにする
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def _sql_str(v) -> str:
    """SQL の文字列リテラルにする（None は null）"""
    if v is None or v == "":
        return "null"
    return "'" + str(v).replace("'", "''") + "'"


def _new_code(prefix: str, length: int = 6) -> str:
    import secrets
    return prefix + "".join(secrets.choice(CODE_ALPHABET) for _ in range(length))


def cmd_codes(argv=()):
    """発行済みの招待コードと使用状況。配布先との対応表を出し直すのにも使う"""
    import argparse, csv, datetime
    ap = argparse.ArgumentParser(prog="codes", description="招待コードの一覧")
    ap.add_argument("--note-like", help="発行時の覚え書きに、この文字を含むものだけ")
    ap.add_argument("--label-like", help="配布先の表記に、この文字を含むものだけ")
    ap.add_argument("--csv", nargs="?", const="", help="CSV に書き出す先（先だけ省くと out/ に日時付きで作る）")
    args = ap.parse_args(list(argv))

    wheres = ["true"]
    if args.note_like:
        wheres.append(f"coalesce(note, '') like {_sql_str('%' + args.note_like + '%')}")
    if args.label_like:
        wheres.append(f"label like {_sql_str('%' + args.label_like + '%')}")
    rows = run_sql(f"""
      select code, label, channel_id, kind, free_days, credits, max_redemptions, redeemed_count,
             to_char(expires_at, 'YYYY-MM-DD') as expires, disabled, coalesce(note, '') as note
        from public.promo_codes where {' and '.join(wheres)}
        order by created_at, code limit 2000
    """) or []
    if not rows:
        print("当てはまる招待コードはありません。")
        return

    def grant_of(r):
        return f"{r['free_days']} 日間無料" if r["kind"] == "free_period" else f"閲覧枠 {r['credits']}"

    used = sum(r["redeemed_count"] for r in rows)
    print(f"招待コード {len(rows)} 件 / 使用のべ {used} 回\n")
    print(f"{'コード':<12} {'使用':>7}  {'内容':<14} {'期限':<11} 配布先")
    for r in rows:
        mark = " (停止)" if r["disabled"] else ""
        print(f"{r['code']:<12} {r['redeemed_count']:>3}/{r['max_redemptions']:<3}  "
              f"{grant_of(r):<14} {r['expires'] or '—':<11} {r['label']}{mark}")

    if args.csv is None:
        return
    out = args.csv or os.path.join(
        HERE, "out", f"{datetime.datetime.now():%Y%m%d-%H%M}_promo_codes.csv")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["コード", "配布先", "チャンネルID", "内容", "使用回数", "使用上限",
                    "有効期限", "停止", "覚え書き"])
        for r in rows:
            w.writerow([r["code"], r["label"], r["channel_id"] or "", grant_of(r),
                        r["redeemed_count"], r["max_redemptions"], r["expires"] or "",
                        "停止" if r["disabled"] else "", r["note"]])
    print(f"\nCSV → {out}")

def cmd_codes_new(argv):
    """配布先ごとに 1 つずつ招待コードを発行し、CSV に残す"""
    import argparse, csv, datetime
    ap = argparse.ArgumentParser(prog="codes-new", description="招待コードを発行する")
    ap.add_argument("--from-csv", help="配布先の一覧。seedpipeline の contributors が出す CSV を想定")
    ap.add_argument("--label", help="配布先を 1 つだけ指定する（--from-csv の代わり）")
    ap.add_argument("--limit", type=int, default=30, help="--from-csv のとき、上位何件に出すか")
    ap.add_argument("--kind", choices=["free_period", "credits"], default="free_period")
    ap.add_argument("--days", type=int, default=365, help="free_period のとき、無料にする日数")
    ap.add_argument("--credits", type=int, default=30, help="credits のとき、付与する閲覧枠の数")
    ap.add_argument("--max", type=int, default=1, help="1 つのコードを使える回数の上限")
    ap.add_argument("--expires", help="コード自体の有効期限 YYYY-MM-DD（既定は 180 日後）")
    ap.add_argument("--prefix", default="ZD", help="コードの頭に付ける文字")
    ap.add_argument("--note", default="", help="控えとして残す覚え書き")
    ap.add_argument("--out", help="発行結果の CSV。既定は out/<日付>_promo_codes.csv")
    args = ap.parse_args(argv)

    targets = []
    if args.from_csv:
        with open(args.from_csv, encoding="utf-8-sig") as f:
            for row in list(csv.DictReader(f))[:args.limit]:
                targets.append((row.get("チャンネル名") or row.get("label") or "",
                                row.get("チャンネルID") or row.get("channel_id") or ""))
    elif args.label:
        targets.append((args.label, ""))
    else:
        sys.exit("--from-csv か --label のどちらかを指定してください。")
    targets = [(name.strip(), cid.strip()) for name, cid in targets if name.strip()]
    if not targets:
        sys.exit("配布先が 1 件もありません。")

    expires = args.expires or (datetime.date.today() + datetime.timedelta(days=180)).isoformat()
    grant = f"{args.days} 日間の閲覧無制限" if args.kind == "free_period" else f"閲覧枠 {args.credits} つ"
    print(f"配布先 {len(targets)} 件に、{grant} のコードを発行します。")
    print(f"  1 コードあたりの使用上限: {args.max} 回 / コードの有効期限: {expires}")
    for name, _ in targets[:10]:
        print(f"    - {name}")
    if len(targets) > 10:
        print(f"    … ほか {len(targets) - 10} 件")
    if input("\n発行しますか（yes と入力）: ").strip() != "yes":
        print("中止しました。")
        return

    issued = []
    values = []
    for name, cid in targets:
        code = _new_code(args.prefix)
        issued.append((code, name, cid))
        values.append("({}, {}, {}, {}, {}, {}, {}, {}, {})".format(
            _sql_str(code), _sql_str(name), _sql_str(cid), _sql_str(args.kind),
            args.days if args.kind == "free_period" else "null",
            args.credits if args.kind == "credits" else "null",
            args.max, _sql_str(expires), _sql_str(args.note)))
    run_sql("insert into public.promo_codes"
            "(code, label, channel_id, kind, free_days, credits, max_redemptions, expires_at, note) values "
            + ",".join(values))

    # 同じ日に 2 回発行しても前の対応表を消さないよう、時刻まで入れる
    out = args.out or os.path.join(
        HERE, "out", f"{datetime.datetime.now():%Y%m%d-%H%M}_promo_codes.csv")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["コード", "配布先", "チャンネルID", "内容", "使用上限", "有効期限"])
        for code, name, cid in issued:
            w.writerow([code, name, cid, grant, args.max, expires])
    print(f"発行しました: {len(issued)} 件\nCSV → {out}")
    print("※ この CSV が配布先との対応表になります。無くすと誰のコードか分からなくなります。")


def cmd_codes_set(argv):
    """発行済みのコードをまとめて直す。期限の延長と、停止・再開に使う"""
    import argparse
    ap = argparse.ArgumentParser(prog="codes-set", description="発行済みの招待コードを直す")
    ap.add_argument("--code", help="1 つだけ指定する")
    ap.add_argument("--note-like", help="発行時の覚え書き（--note）に、この文字を含むものを対象にする")
    ap.add_argument("--label-like", help="配布先の表記に、この文字を含むものを対象にする")
    ap.add_argument("--all", action="store_true", help="停止していないコード全てを対象にする")
    ap.add_argument("--expires", help="コードの有効期限を YYYY-MM-DD に差し替える")
    ap.add_argument("--max", type=int, help="使用回数の上限を差し替える")
    ap.add_argument("--disable", action="store_true", help="停止する（以後は使えなくなる）")
    ap.add_argument("--enable", action="store_true", help="停止を解除する")
    args = ap.parse_args(argv)

    wheres = []
    if args.code:
        wheres.append(f"code = {_sql_str(args.code.upper())}")
    if args.note_like:
        wheres.append(f"coalesce(note, '') like {_sql_str('%' + args.note_like + '%')}")
    if args.label_like:
        wheres.append(f"label like {_sql_str('%' + args.label_like + '%')}")
    if not wheres:
        if not args.all:
            sys.exit("対象を指定してください（--code / --note-like / --label-like / --all）。")
        wheres.append("not disabled")
    where = " and ".join(wheres)

    sets = []
    if args.expires:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.expires):
            sys.exit("--expires は YYYY-MM-DD の形で指定してください。")
        sets.append(f"expires_at = {_sql_str(args.expires)}::timestamptz")
    if args.max is not None:
        sets.append(f"max_redemptions = {int(args.max)}")
    if args.disable:
        sets.append("disabled = true")
    if args.enable:
        sets.append("disabled = false")
    if not sets:
        sys.exit("変更内容を指定してください（--expires / --max / --disable / --enable）。")

    rows = run_sql(f"""
      select code, label, redeemed_count, max_redemptions,
             to_char(expires_at, 'YYYY-MM-DD') as expires, disabled
        from public.promo_codes where {where} order by created_at
    """) or []
    if not rows:
        print("対象のコードがありません。")
        return
    print(f"対象 {len(rows)} 件:")
    for r in rows[:12]:
        print(f"  {r['code']}  使用 {r['redeemed_count']}/{r['max_redemptions']}  "
              f"期限 {r['expires'] or '—'}  {r['label']}")
    if len(rows) > 12:
        print(f"  … ほか {len(rows) - 12} 件")
    print("\n-- これから変更する内容 --")
    for x in sets:
        print(f"  {x}")
    if input("\n適用しますか（yes と入力）: ").strip() != "yes":
        print("中止しました。変更していません。")
        return
    run_sql(f"update public.promo_codes set {', '.join(sets)} where {where}")
    print(f"{len(rows)} 件を変更しました。")


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__); return
    cmd = sys.argv[1]
    try:
        run(cmd)
    except RuntimeError as e:
        if str(e).startswith("HTTP 401"):
            sys.exit("管理用トークン（Personal Access Token）が無効です。失効したか、取り消された可能性があります。\n"
                     "対処: https://supabase.com/dashboard/account/tokens で新しく作成し、次を実行してください。\n"
                     "  ./20260905_setup_supabase.sh --token-only")
        sys.exit(f"失敗しました: {e}")


def run(cmd: str):
    if cmd == "check":
        sys.exit(0 if cmd_check() else 1)
    elif cmd == "migrate":
        cmd_migrate()
    elif cmd == "seed":
        cmd_seed()
    elif cmd == "stats":
        cmd_stats()
    elif cmd == "ping":
        sys.exit(0 if cmd_ping() else 1)
    elif cmd == "auth":
        cmd_auth()
    elif cmd == "auth-apply":
        cmd_auth_apply()
    elif cmd == "codes":
        cmd_codes(sys.argv[2:])
    elif cmd == "codes-new":
        cmd_codes_new(sys.argv[2:])
    elif cmd == "codes-set":
        cmd_codes_set(sys.argv[2:])
    elif cmd == "sql":
        print(json.dumps(run_sql(sys.argv[2]), ensure_ascii=False, indent=2))
    else:
        sys.exit(f"不明なコマンド: {cmd}")


if __name__ == "__main__":
    main()
