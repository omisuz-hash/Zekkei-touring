"""各段階の実行。run で全段階を順に回す"""
import json
import time
import traceback
from .config import Config
from .store import Store
from .youtube import YouTube, QuotaExceeded, parse_chapters, looks_like_touring
from .gemini import Gemini
from .geo import make_geo, build_geometry, GeoError, CachedGeo
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
            self._geo = CachedGeo(make_geo(self.cfg.geo_provider, self.cfg.google_geocoding_api_key, self.cfg.google_routes_api_key), self.store)
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
            for ch in self.store.channels_to_crawl(limit=self.cfg.channels_per_run):
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
        self.rate_limited = False
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
                    try:
                        self.store.upsert_road(road_key(r), r, v["id"])
                        n_roads += 1
                    except Exception as e:  # 1 本の道の不良データで全体を止めない
                        log(f"  道の保存に失敗（スキップ）: {str(r.get('name'))[:30]} - {e}")
                self.store.set_status(v["id"], status, f"{len(roads)} roads", res)
                self.store.bump_channel(v["channel_id"], v["channel"], bool(roads))
                log(f"抽出 {v['title'][:40]} → {len(roads)} 本")
            except HTTPError as e:
                if e.status == 429:
                    log("Gemini の利用枠に達したため抽出を中断します")
                    self.rate_limited = True
                    break
                if e.status == 404 and "model" in e.body.lower():
                    log(f"Gemini のモデル {self.cfg.gemini_model} が使えません。GEMINI_MODEL で別のモデルを指定してください: {e.body[:200]}")
                    break
                self.store.set_status(v["id"], "failed", str(e)[:200])
                log(f"失敗 {v['id']}: {e}")
        return n_roads

    # 4. 形状づけ ---------------------------------------------------------
    def georeference(self, limit: int | None = None) -> int:
        ok = 0
        for r in self.store.roads_pending_geo(limit or self.cfg.max_geo_per_run):
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

    # 4c. スポット: 展望台・飲食店・道の駅などを道の近くに位置付ける ----------
    def spots(self, limit: int | None = None) -> int:
        from .spots import build_spots
        n = 0
        for r in self.store.roads_pending_spots(limit or self.cfg.max_spots_per_run):
            try:
                sps = build_spots(self.geo, r)
            except Exception as e:  # 1 本の失敗で止めない
                log(f"スポット NG: {r['name']} ({e})")
                sps = []
            self.store.save_spots(r["id"], sps)
            n += len(sps)
            if sps:
                log(f"スポット {r['name']}: " + "、".join(f"{s['name']}({s['kind']})" for s in sps))
            self.store.add_quota(geo_calls=getattr(self.geo, "calls", 0))
            self.geo.calls = 0
        return n

    def retry_spots(self) -> int:
        return self.store.reset_spots()

    # 4b. 修復: 座標にできなかった道を、Gemini の一般知識で言い直して再試行 ----------
    def repair(self, limit: int = 100) -> int:
        if not self.llm:
            return 0
        n = 0
        for r in self.store.roads_to_repair(limit):
            try:
                fix = self.llm.refine_road(r["name"], r["prefecture"] or "", r["road_number"] or "", r["start_label"], r["end_label"])
                self.store.add_quota(gemini_calls=1)
            except HTTPError as e:
                if e.status == 429:
                    log("Gemini の利用枠に達したため修復を中断します")
                    break
                self.store.mark_repair_attempted(r["id"])
                continue
            if not fix.get("known") or not fix.get("start_label") or not fix.get("end_label"):
                self.store.mark_repair_attempted(r["id"])
                continue
            self.store.apply_repair(r["id"], fix)
            n += 1
            log(f"修復候補: {r['name']} → {fix['start_label']}（{fix.get('start_municipality','')}）〜 {fix['end_label']}（{fix.get('end_municipality','')}）")
        return n

    # 5. 統合 ------------------------------------------------------------
    def dedupe(self) -> int:
        roads = self.store.roads(geo_ok_only=True)
        for r in roads:
            r["_coords"] = [tuple(c) for c in json.loads(r["geom"])]
        pairs = find_duplicates(roads)
        seen = set()
        n = 0
        for keep, drop, ratio, take_drop_geom in pairs:
            if drop in seen or keep in seen:
                continue
            self.store.merge_roads(keep, drop, take_drop_geom)
            seen.add(drop)
            n += 1
            log(f"統合: {drop} → {keep}（重なり {ratio:.0%}{'・長い方の形状を採用' if take_drop_geom else ''}）")
        return n

    def retry_geo(self, include_ok: bool = False) -> int:
        return self.store.reset_geo(("failed", "suspect", "ok") if include_ok else ("failed", "suspect"))

    def reset_roads(self) -> int:
        return self.store.reset_roads()

    def retry_failed(self) -> int:
        cur = self.store.db.execute("update videos set status='fetched', reason=null where status='failed'")
        self.store.db.commit()
        return cur.rowcount

    def _stage(self, title, fn):
        log(f"== {title} ==")
        try:
            return fn() or 0
        except SystemExit as e:
            log(f"{title} をスキップ: {e}")
        except Exception:
            log(f"{title} で予期しないエラー。次の段階に進みます。\n{traceback.format_exc()}")
        return 0

    def run(self, until_empty: bool = False, max_rounds: int = 40):
        """各段階を順に実行。until_empty なら、処理するものが無くなるか API の枠に当たるまで繰り返す"""
        self._stage("発見", self.discover)
        for i in range(max_rounds if until_empty else 1):
            fetched = self._stage("取得", self.fetch)
            extracted = self._stage("抽出", self.extract)
            geo = self._stage("形状", self.georeference)
            if self._stage("修復", self.repair):
                geo += self._stage("形状（修復後）", self.georeference)
            if not until_empty:
                break
            pending = self.store.stats()
            remaining = pending.get("videos_discovered", 0) + pending.get("videos_fetched", 0) + pending.get("roads_pending", 0)
            log(f"-- round {i + 1}: 取得 {fetched} / 抽出 {extracted} 本の道 / 形状 {geo} / 残り {remaining}")
            if getattr(self, "rate_limited", False):
                log("Gemini の利用枠待ち: 5 分後に再開します")
                time.sleep(300)
                continue
            if remaining == 0 or (fetched == 0 and extracted == 0 and geo == 0):
                break
        self._stage("統合", self.dedupe)
        self._stage("スポット", self.spots)
        log("== 集計 ==")
        for k, v in sorted(self.store.stats().items()):
            log(f"  {k}: {v}")
