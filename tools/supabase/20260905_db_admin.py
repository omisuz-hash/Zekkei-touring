#!/usr/bin/env python3
"""Supabase のデータベースを Mac から操作する（追加インストール不要・Python 標準ライブラリのみ）。

  python3 20260905_db_admin.py check     接続と鍵の確認
  python3 20260905_db_admin.py migrate   supabase/migrations/*.sql を日付順に適用（適用済みは飛ばす）
  python3 20260905_db_admin.py seed      手作業シードと自動収集シード（最新の *_seed_roads_auto.sql）を流し込む
  python3 20260905_db_admin.py stats     道・動画・会員の件数
  python3 20260905_db_admin.py sql "select count(*) from zekkei_roads"   任意の SQL（管理用）

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


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__); return
    cmd = sys.argv[1]
    if cmd == "check":
        sys.exit(0 if cmd_check() else 1)
    elif cmd == "migrate":
        cmd_migrate()
    elif cmd == "seed":
        cmd_seed()
    elif cmd == "stats":
        cmd_stats()
    elif cmd == "sql":
        print(json.dumps(run_sql(sys.argv[2]), ensure_ascii=False, indent=2))
    else:
        sys.exit(f"不明なコマンド: {cmd}")


if __name__ == "__main__":
    main()
