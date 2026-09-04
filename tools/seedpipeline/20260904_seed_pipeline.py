#!/usr/bin/env python3
"""絶景道シード自動収集パイプライン（CLI）

  YOUTUBE_API_KEY=... GEMINI_API_KEY=... GOOGLE_MAPS_API_KEY=... python3 20260904_seed_pipeline.py run
  python3 20260904_seed_pipeline.py export        # out/ に SQL・GeoJSON・レポートを出力
  python3 20260904_seed_pipeline.py stats
  python3 20260904_seed_pipeline.py discover --keywords "絶景 ツーリング" --pages 1
  python3 20260904_seed_pipeline.py import-json ../youtube/out/20260904_youtube_videos.json   # 取得済みデータの取り込み
  python3 20260904_seed_pipeline.py models        # 使える Gemini モデル一覧
  python3 20260904_seed_pipeline.py selftest      # API を使わない動作確認

段階: discover（検索）→ fetch（概要欄・コメント取得）→ extract（Gemini で道を抽出）→ georeference（地図 API で形状）→ dedupe（重複統合）→ export
すべて SQLite（out/seedpipeline.sqlite）に保存され、何度実行しても続きから再開する。
"""
import argparse
import json
import os
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))

from seedpipeline.config import Config
from seedpipeline.pipeline import Pipeline, log
from seedpipeline.export import export_sql, export_geojson, export_report
from seedpipeline.youtube import parse_chapters


def cmd_import_json(p: Pipeline, path: str) -> int:
    """tools/youtube の取得結果（YouTube API 消費なし）を fetched 状態で取り込む"""
    with open(path, encoding="utf-8") as f:
        videos = json.load(f)
    n = 0
    for v in videos:
        v.setdefault("channel_id", "")
        v["chapters"] = v.get("chapters") or parse_chapters(v.get("description", ""))
        v["comments"] = [{"author": c.get("author", ""), "text": c.get("text", ""), "likes": c.get("likes", 0),
                          "replies": [r.get("text", "") if isinstance(r, dict) else r for r in c.get("replies", [])]}
                         for c in v.get("comments", []) if c.get("road_related", True)]
        p.store.add_discovered([{"id": v["id"], "title": v.get("title", ""), "channel": v.get("channel", ""), "channel_id": v["channel_id"]}], "import")
        p.store.save_video(v, "fetched")
        n += 1
    return n


def cmd_export(p: Pipeline, out_dir: str, min_conf: float):
    stamp = date.today().strftime("%Y%m%d")
    os.makedirs(out_dir, exist_ok=True)
    sql = os.path.join(out_dir, f"{stamp}_seed_roads_auto.sql")
    gj = os.path.join(out_dir, f"{stamp}_roads_auto.geojson")
    rep = os.path.join(out_dir, f"{stamp}_seed_report.md")
    n1 = export_sql(p.store, sql, min_confidence=min_conf)
    n2 = export_geojson(p.store, gj)
    export_report(p.store, rep)
    log(f"SQL {n1} 本 → {sql}")
    log(f"GeoJSON {n2} 本 → {gj}（https://geojson.io に貼ると地図で確認できる）")
    log(f"レポート → {rep}")


def cmd_check(cfg: Config) -> bool:
    """4 つのキーを最小限の呼び出しで検証する（YouTube 1 ユニット、他は各 1 回）"""
    from seedpipeline.youtube import YouTube
    from seedpipeline.gemini import Gemini
    from seedpipeline.geo import GoogleGeo
    from seedpipeline.http import HTTPError
    ok = True

    def report(name, fn):
        nonlocal ok
        try:
            r = fn()
            print(f"  OK   {name}: {r}")
        except HTTPError as e:
            ok = False
            hint = ""
            if e.status == 403 and ("not been used" in e.body or "disabled" in e.body):
                hint = "（API が有効化されていません）"
            elif e.status in (400, 403):
                hint = "（キーが無効か、API の制限に含まれていません）"
            print(f"  NG   {name}: HTTP {e.status} {hint}\n       {e.body[:200]}")
        except Exception as e:
            ok = False
            print(f"  NG   {name}: {e}")

    print("キーの検証:")
    if cfg.youtube_api_key:
        report("YouTube Data API", lambda: YouTube(cfg.youtube_api_key, 100).videos(["dQw4w9WgXcQ"])[0]["title"][:30])
    else:
        ok = False; print("  NG   YouTube: YOUTUBE_API_KEY 未設定")
    if cfg.gemini_api_key:
        def gem():
            g = Gemini(cfg.gemini_api_key, cfg.gemini_model)
            try:
                return f"モデル {cfg.gemini_model} 応答: {g.ping()}"
            except HTTPError as e:
                models = [m for m in g.list_models() if "flash" in m or "pro" in m]
                raise RuntimeError(f"モデル {cfg.gemini_model} が使えません（HTTP {e.status}）。GEMINI_MODEL で指定できる候補: {', '.join(models[:10])}")
        report("Gemini API", gem)
    else:
        ok = False; print("  NG   Gemini: GEMINI_API_KEY 未設定")
    if cfg.geo_provider == "google":
        geo = GoogleGeo(cfg.google_geocoding_api_key, cfg.google_routes_api_key)
        report("Geocoding API", lambda: geo.geocode("白樺湖", "長野県"))
        report("Routes API", lambda: f"{len(geo.route([(138.157, 36.109), (138.138, 36.223)]))} 点の経路")
    else:
        print("  --   地図: OpenStreetMap（無料）を使用")
    print("結果:", "すべて OK" if ok else "問題あり")
    return ok


def cmd_selftest():
    from seedpipeline.geo import decode_polyline, simplify, length_m, curviness, ewkt
    from seedpipeline.merge import road_key, normalize_name, overlap_ratio
    from seedpipeline.store import Store
    line = decode_polyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    assert len(line) == 3 and abs(line[0][1] - 38.5) < 1e-6, line
    assert normalize_name("国道 411 号線 大菩薩ライン") == normalize_name("国道411号大菩薩ライン")
    assert road_key({"name": "ビーナスライン（白樺湖〜美ヶ原）", "prefecture": "長野県"}) == road_key({"name": "ビーナスライン", "prefecture": "長野県"})
    assert road_key({"name": "国道152号", "road_number": "国道152号", "prefecture": "長野県"}) == "num:国道152号:長野"
    a = [(138.157, 36.109), (138.196, 36.103), (138.185, 36.119)]
    assert overlap_ratio(a, a) == 1.0
    assert length_m(a) > 5000 and 0 <= curviness(a) <= 1
    assert ewkt(a).startswith("SRID=4326;LINESTRING(138.157000 36.109000")
    st = Store(":memory:")
    st.add_discovered([{"id": "v1", "title": "t", "channel": "c", "channel_id": "ch"}], "test")
    st.save_video({"id": "v1", "title": "t", "channel": "c", "channel_id": "ch", "view_count": 10}, "fetched")
    rid = st.upsert_road("name:test", {"name": "test", "start_label": "a", "end_label": "b", "scenery_hint": 4, "confidence": 0.8}, "v1")
    st.add_discovered([{"id": "v2", "title": "t2", "channel": "c", "channel_id": "ch"}], "test")
    st.save_video({"id": "v2", "title": "t2", "channel": "c", "channel_id": "ch", "view_count": 5}, "fetched")
    rid2 = st.upsert_road("name:test", {"name": "test", "start_label": "a", "end_label": "b", "scenery_hint": 2, "confidence": 0.6}, "v2")
    r = st.roads()[0]
    assert rid == rid2 and r["mentions"] == 2 and abs(r["scenery_hint"] - 3.0) < 1e-9 and r["confidence"] == 0.8, r
    st.save_geo(rid, [list(c) for c in a], 5000, 0.3, None)
    assert st.roads(geo_ok_only=True)[0]["geo_status"] == "ok"
    tmp = "out/_selftest.sql"
    os.makedirs("out", exist_ok=True)
    assert export_sql(st, tmp) == 1
    assert "insert into public.zekkei_roads" in open(tmp, encoding="utf-8").read()
    os.remove(tmp)
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description="絶景道シード自動収集")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run", help="全段階を実行")
    d = sub.add_parser("discover", help="検索で動画を集める")
    d.add_argument("--keywords", nargs="*")
    d.add_argument("--pages", type=int)
    f = sub.add_parser("fetch", help="概要欄・コメントを取得"); f.add_argument("--limit", type=int)
    e = sub.add_parser("extract", help="Gemini で道を抽出"); e.add_argument("--limit", type=int); e.add_argument("--video-analyses", type=int)
    g = sub.add_parser("georeference", help="地図 API で形状を付ける"); g.add_argument("--limit", type=int, default=200)
    sub.add_parser("dedupe", help="重複統合")
    x = sub.add_parser("export", help="SQL / GeoJSON / レポートを出力"); x.add_argument("--out", default="out"); x.add_argument("--min-confidence", type=float, default=0.5)
    sub.add_parser("stats")
    i = sub.add_parser("import-json", help="tools/youtube の取得結果を取り込む"); i.add_argument("path")
    sub.add_parser("models", help="使える Gemini モデル")
    sub.add_parser("selftest")
    sub.add_parser("check", help="4 つのキーを検証")
    sub.add_parser("retry-failed", help="失敗した動画を再度抽出対象に戻す")
    sub.add_parser("retry-geo", help="形状が失敗・要確認の道をやり直す")
    sub.add_parser("reset-roads", help="抽出結果を全て消して抽出からやり直す（動画の取得結果は残る）")
    args = ap.parse_args()

    if args.cmd == "selftest":
        return cmd_selftest()
    cfg = Config()
    if args.cmd == "check":
        return sys.exit(0 if cmd_check(cfg) else 1)
    p = Pipeline(cfg)
    if args.cmd == "run":
        p.run(); cmd_export(p, "out", 0.5)
    elif args.cmd == "discover":
        log(f"新規 {p.discover(args.keywords, args.pages)} 本")
    elif args.cmd == "fetch":
        log(f"取得 {p.fetch(args.limit)} 本")
    elif args.cmd == "extract":
        log(f"抽出 {p.extract(args.limit, args.video_analyses)} 本の道")
    elif args.cmd == "georeference":
        log(f"形状 OK {p.georeference(args.limit)} 本")
    elif args.cmd == "dedupe":
        log(f"統合 {p.dedupe()} 組")
    elif args.cmd == "export":
        cmd_export(p, args.out, args.min_confidence)
    elif args.cmd == "stats":
        for k, v in sorted(p.store.stats().items()):
            print(f"{k}: {v}")
        print("quota:", p.store.quota())
    elif args.cmd == "retry-geo":
        log(f"{p.retry_geo()} 本の形状をやり直し対象にしました")
    elif args.cmd == "reset-roads":
        log(f"{p.reset_roads()} 本の道を消し、動画を抽出前に戻しました")
    elif args.cmd == "retry-failed":
        log(f"{p.retry_failed()} 本を抽出対象に戻しました")
    elif args.cmd == "import-json":
        log(f"取り込み {cmd_import_json(p, args.path)} 本")
    elif args.cmd == "models":
        cfg.require("gemini_api_key")
        print("\n".join(p.llm.list_models()))


if __name__ == "__main__":
    main()
