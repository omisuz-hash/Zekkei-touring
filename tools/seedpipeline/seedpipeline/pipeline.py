"""各段階の実行。run で全段階を順に回す"""
import json
import time
from .config import Config
from .store import Store
from .youtube import YouTube, QuotaExceeded, parse_chapters, looks_like_touring
from .gemini import Gemini
from .geo import make_geo, build_geometry, GeoError
from .merge import road_key, find_duplicates
from .http import HTTPError


def log(msg: str):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


class Pipeline:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.store = Store(cfg.db_path)
        quota = self.store.quota()
        self.yt = YouTube(cfg.youtube_api_key, cfg.youtube_daily_budget, quota["youtube_units"]) if cfg.youtube_api_key else None
        self.llm = Gemini(cfg.gemini_api_key, cfg.gemini_model) if cfg.gemini_api_key else None
        self._geo = None

    @property
    def geo(self):
        if self._geo is None:
            self._geo = make_geo(self.cfg.geo_provider, self.cfg.google_geocoding_api_key, self.cfg.google_routes_api_key)
        return self._geo

    def _spend_yt(self):
        # YouTube クライアントの累計を SQLite に同期
        q = self.store.quota()
        delta = self.yt.used - q["youtube_units"]
        if delta > 0:
            self.store.add_quota(youtube_units=delta)

    # 1. 発見 ------------------------------------------------------------
    def discover(self, keywords: list[str] | None = None, pages: int | None = None) -> int:
        self.cfg.require("youtube_api_key")
        kws = keywords or self.cfg.search_keywords
        pages = pages or self.cfg.search_pages_per_keyword
        found = 0
        try:
            for kw in kws:
                token = None
                for page in range(1, pages + 1):
                    if self.store.search_done(kw, page):
                        continue
                    items, token = self.yt.search(kw, token)
                    n = self.store.add_discovered(items, f"search:{kw}")
                    self.store.mark_search(kw, page)
                    self._spend_yt()
                    found += n
                    log(f"検索「{kw}」p{page}: {len(items)} 件（新規 {n}）")
                    if not token:
                        break
            # 当たりの多いチャンネルは投稿一覧を直接たどる（検索の 1/100 のコスト）
            for ch in self.store.channels_to_crawl():
                pl = self.yt.channel_uploads_playlist(ch["id"])
                if pl:
                    ids = self.yt.playlist_video_ids(pl, 200)
                    n = self.store.add_discovered([{"id": i, "channel_id": ch["id"], "channel": ch["title"]} for i in ids], f"channel:{ch['title']}")
                    found += n
                    log(f"チャンネル「{ch['title']}」: {len(ids)} 本（新規 {n}）")
                self.store.mark_channel_crawled(ch["id"])
                self._spend_yt()
        except QuotaExceeded as e:
            log(f"停止: {e}")
        return found

    # 2. 取得 ------------------------------------------------------------
    def fetch(self, limit: int | None = None) -> int:
        self.cfg.require("youtube_api_key")
        limit = limit or self.cfg.max_videos_per_run
        pending = self.store.videos_by_status("discovered", limit)
        done = 0
        try:
            for i in range(0, len(pending), 50):
                batch = pending[i:i + 50]
                details = {v["id"]: v for v in self.yt.videos([v["id"] for v in batch])}
                for v in batch:
                    d = details.get(v["id"])
                    if not d:
                        self.store.set_status(v["id"], "skipped", "取得不可")
                        continue
                    if not (self.cfg.min_duration_s <= d["duration_s"] <= self.cfg.max_duration_s):
                        self.store.save_video(d, "skipped", "長さが対象外")
                        continue
                    if not looks_like_touring(d):
                        self.store.save_video(d, "skipped", "ツーリング動画でない（タイトル判定）")
                        continue
                    d["chapters"] = parse_chapters(d["description"])
                    d["comments"] = self.yt.comments(d["id"], 60) if d["comment_count"] else []
                    self.store.save_video(d, "fetched")
                    done += 1
                self._spend_yt()
                log(f"取得 {done} 本 / 使用ユニット {self.yt.used}")
        except QuotaExceeded as e:
            log(f"停止: {e}")
        return done

    # 3. 抽出 ------------------------------------------------------------
    def extract(self, limit: int | None = None, video_analyses: int | None = None) -> int:
        self.cfg.require("gemini_api_key")
        limit = limit or self.cfg.max_videos_per_run
        max_va = self.cfg.max_video_analyses_per_run if video_analyses is None else video_analyses
        used_va = self.store.quota()["video_analyses"]
        n_roads = 0
        for v in self.store.videos_by_status("fetched", limit):
            v["chapters"] = json.loads(v["chapters"] or "[]")
            v["tags"] = json.loads(v["tags"] or "[]")
            comments = json.loads(v["comments"] or "[]")
            try:
                res = self.llm.extract_from_text(v, comments)
                self.store.add_quota(gemini_calls=1)
                roads = [r for r in res.get("roads", []) if r.get("name") and r.get("start_label") and r.get("end_label")]
                status = "extracted"
                # 概要欄が薄く道が取れなかったツーリング動画は、映像を見て補う
                if res.get("is_touring_ride", True) and not roads and used_va < max_va and len(v.get("description") or "") < 800:
                    log(f"  映像解析: {v['title'][:40]}")
                    res = self.llm.extract_from_video(f"https://www.youtube.com/watch?v={v['id']}", v)
                    used_va += 1
                    self.store.add_quota(gemini_calls=1, video_analyses=1)
                    roads = [r for r in res.get("roads", []) if r.get("name") and r.get("start_label") and r.get("end_label")]
                    status = "video_analyzed"
                if not res.get("is_touring_ride", True) and not roads:
                    self.store.set_status(v["id"], "skipped", "ツーリング動画でない（LLM 判定）", res)
                    self.store.bump_channel(v["channel_id"], v["channel"], False)
                    continue
                for r in roads:
                    r.setdefault("prefecture", (res.get("prefectures") or [""])[0])
                    self.store.upsert_road(road_key(r), r, v["id"])
                    n_roads += 1
                self.store.set_status(v["id"], status, f"{len(roads)} roads", res)
                self.store.bump_channel(v["channel_id"], v["channel"], bool(roads))
                log(f"抽出 {v['title'][:40]} → {len(roads)} 本")
            except HTTPError as e:
                if e.status == 429:
                    log("Gemini の利用枠に達したため抽出を中断します")
                    break
                if e.status == 404 and "model" in e.body.lower():
                    log(f"Gemini のモデル {self.cfg.gemini_model} が使えません。GEMINI_MODEL で別のモデルを指定してください: {e.body[:200]}")
                    break
                self.store.set_status(v["id"], "failed", str(e)[:200])
                log(f"失敗 {v['id']}: {e}")
        return n_roads

    # 4. 形状づけ ---------------------------------------------------------
    def georeference(self, limit: int = 200) -> int:
        ok = 0
        for r in self.store.roads_pending_geo(limit):
            r["via_labels"] = json.loads(r["via_labels"] or "[]")
            try:
                g = build_geometry(self.geo, r)
                self.store.save_geo(r["id"], g["coords"], g["length_m"], g["curviness"], None, g.get("suspect"))
                if g.get("suspect"):
                    log(f"形状 要確認: {r['name']} {g['length_m'] / 1000:.1f} km ({g['suspect']})")
                else:
                    ok += 1
                    log(f"形状 OK: {r['name']} {g['length_m'] / 1000:.1f} km")
            except (GeoError, HTTPError) as e:
                self.store.save_geo(r["id"], None, None, None, str(e)[:200])
                log(f"形状 NG: {r['name']} ({e})")
            self.store.add_quota(geo_calls=getattr(self.geo, "calls", 0))
            self.geo.calls = 0
        return ok

    # 5. 統合 ------------------------------------------------------------
    def dedupe(self) -> int:
        roads = self.store.roads(geo_ok_only=True)
        for r in roads:
            r["_coords"] = [tuple(c) for c in json.loads(r["geom"])]
        pairs = find_duplicates(roads)
        seen = set()
        n = 0
        for keep, drop, ratio in pairs:
            if drop in seen or keep in seen:
                continue
            self.store.merge_roads(keep, drop)
            seen.add(drop)
            n += 1
            log(f"統合: {drop} → {keep}（重なり {ratio:.0%}）")
        return n

    def retry_geo(self) -> int:
        return self.store.reset_geo()

    def reset_roads(self) -> int:
        return self.store.reset_roads()

    def retry_failed(self) -> int:
        cur = self.store.db.execute("update videos set status='fetched', reason=null where status='failed'")
        self.store.db.commit()
        return cur.rowcount

    def run(self):
        log("== 発見 ==");   self.discover()
        log("== 取得 ==");   self.fetch()
        log("== 抽出 ==");   self.extract()
        log("== 形状 ==");   self.georeference()
        log("== 統合 ==");   self.dedupe()
        log("== 集計 ==")
        for k, v in sorted(self.store.stats().items()):
            log(f"  {k}: {v}")
