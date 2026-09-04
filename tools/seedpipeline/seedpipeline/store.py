"""SQLite に進捗と結果を保存する。何度実行しても続きから再開できる"""
import json
import os
import sqlite3
from datetime import date

SCHEMA = """
create table if not exists videos (
  id text primary key, title text, channel text, channel_id text, published_at text,
  duration_s integer, view_count integer, comment_count integer, tags text, description text, thumbnail text,
  chapters text, comments text,
  status text not null default 'discovered',   -- discovered / fetched / extracted / video_analyzed / skipped / failed
  reason text, source text, extracted text, updated_at text
);
create table if not exists roads (
  id integer primary key autoincrement,
  key text unique,           -- 統合用キー（正規化した名前 + 都道府県）
  name text, road_number text, prefecture text, start_label text, end_label text, via_labels text,
  summary text, cautions text, season text,
  scenery_hint real, winding_hint real, surface_hint real, rest_hint real, parking_hint real,
  confidence real, mentions integer default 0,
  start_municipality text, end_municipality text, approx_length_km real,
  geom text, length_m real, curviness real, geo_status text default 'pending', geo_error text,  -- pending / ok / suspect / failed
  created_at text, updated_at text
);
create table if not exists road_videos (
  road_id integer, video_id text, timestamp text, evidence text, confidence real,
  primary key (road_id, video_id)
);
create table if not exists channels (
  id text primary key, title text, crawled integer default 0, hits integer default 0, videos integer default 0
);
create table if not exists quota (day text primary key, youtube_units integer default 0, gemini_calls integer default 0,
  video_analyses integer default 0, geo_calls integer default 0);
create table if not exists searches (keyword text, page integer, done integer default 0, primary key (keyword, page));
"""


class Store:
    def __init__(self, path: str):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        # 既存 DB への列追加（あれば無視）
        cols = {r[1] for r in self.db.execute("pragma table_info(roads)")}
        for col, typ in (("start_municipality", "text"), ("end_municipality", "text"), ("approx_length_km", "real")):
            if col not in cols:
                self.db.execute(f"alter table roads add column {col} {typ}")
        self.db.commit()

    # --- quota
    def quota(self) -> dict:
        d = date.today().isoformat()
        self.db.execute("insert or ignore into quota(day) values (?)", (d,))
        self.db.commit()
        return dict(self.db.execute("select * from quota where day=?", (d,)).fetchone())

    def add_quota(self, **kw):
        d = date.today().isoformat()
        for k, v in kw.items():
            self.db.execute(f"update quota set {k}={k}+? where day=?", (v, d))
        self.db.commit()

    # --- videos
    def add_discovered(self, items: list[dict], source: str) -> int:
        n = 0
        for it in items:
            cur = self.db.execute("insert or ignore into videos(id,title,channel,channel_id,published_at,source,status,updated_at) values (?,?,?,?,?,?, 'discovered', datetime('now'))",
                                  (it["id"], it.get("title", ""), it.get("channel", ""), it.get("channel_id", ""), it.get("published_at", ""), source))
            n += cur.rowcount
        self.db.commit()
        return n

    def videos_by_status(self, status: str, limit: int) -> list[dict]:
        return [dict(r) for r in self.db.execute("select * from videos where status=? order by view_count desc, id limit ?", (status, limit))]

    def save_video(self, v: dict, status: str, reason: str | None = None):
        self.db.execute("""update videos set title=?, channel=?, channel_id=?, published_at=?, duration_s=?, view_count=?, comment_count=?,
            tags=?, description=?, thumbnail=?, chapters=?, comments=?, status=?, reason=?, updated_at=datetime('now') where id=?""",
                        (v.get("title"), v.get("channel"), v.get("channel_id"), v.get("published_at"), v.get("duration_s"), v.get("view_count"),
                         v.get("comment_count"), json.dumps(v.get("tags", []), ensure_ascii=False), v.get("description"), v.get("thumbnail"),
                         json.dumps(v.get("chapters", []), ensure_ascii=False), json.dumps(v.get("comments", []), ensure_ascii=False),
                         status, reason, v["id"]))
        self.db.commit()

    def set_status(self, video_id: str, status: str, reason: str | None = None, extracted: dict | None = None):
        self.db.execute("update videos set status=?, reason=?, extracted=coalesce(?, extracted), updated_at=datetime('now') where id=?",
                        (status, reason, json.dumps(extracted, ensure_ascii=False) if extracted is not None else None, video_id))
        self.db.commit()

    def video(self, video_id: str) -> dict | None:
        r = self.db.execute("select * from videos where id=?", (video_id,)).fetchone()
        return dict(r) if r else None

    # --- searches
    def search_done(self, keyword: str, page: int) -> bool:
        r = self.db.execute("select done from searches where keyword=? and page=?", (keyword, page)).fetchone()
        return bool(r and r["done"])

    def mark_search(self, keyword: str, page: int):
        self.db.execute("insert or replace into searches(keyword,page,done) values (?,?,1)", (keyword, page))
        self.db.commit()

    # --- channels
    def bump_channel(self, channel_id: str, title: str, hit: bool):
        self.db.execute("insert or ignore into channels(id,title) values (?,?)", (channel_id, title))
        self.db.execute("update channels set videos=videos+1, hits=hits+? where id=?", (1 if hit else 0, channel_id))
        self.db.commit()

    def channels_to_crawl(self, min_hits: int = 2, limit: int = 5) -> list[dict]:
        return [dict(r) for r in self.db.execute("select * from channels where crawled=0 and hits>=? order by hits desc limit ?", (min_hits, limit))]

    def mark_channel_crawled(self, channel_id: str):
        self.db.execute("update channels set crawled=1 where id=?", (channel_id,))
        self.db.commit()

    # --- roads
    def upsert_road(self, key: str, road: dict, video_id: str) -> int:
        r = self.db.execute("select * from roads where key=?", (key,)).fetchone()
        hints = ["scenery_hint", "winding_hint", "surface_hint", "rest_hint", "parking_hint"]
        if r is None:
            self.db.execute("""insert into roads(key,name,road_number,prefecture,start_label,end_label,via_labels,summary,cautions,season,
                scenery_hint,winding_hint,surface_hint,rest_hint,parking_hint,confidence,mentions,
                start_municipality,end_municipality,approx_length_km,created_at,updated_at)
                values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?,?,datetime('now'),datetime('now'))""",
                            (key, road["name"], road.get("road_number", ""), road.get("prefecture", ""), road["start_label"], road["end_label"],
                             json.dumps(road.get("via_labels", []), ensure_ascii=False), road.get("summary", ""), road.get("cautions", ""),
                             road.get("season", ""), *[road.get(h) for h in hints], road.get("confidence", 0),
                             road.get("start_municipality", ""), road.get("end_municipality", ""), road.get("approx_length_km") or None))
            road_id = self.db.execute("select id from roads where key=?", (key,)).fetchone()["id"]
        else:
            road_id = r["id"]
            n = r["mentions"]
            # 示唆値は言及数で加重平均。要約は長い方を残す
            sets, vals = [], []
            for h in hints:
                if road.get(h) is not None:
                    old = r[h]
                    new = road[h] if old is None else (old * n + road[h]) / (n + 1)
                    sets.append(f"{h}=?"); vals.append(new)
            if len(road.get("summary", "") or "") > len(r["summary"] or ""):
                sets.append("summary=?"); vals.append(road["summary"])
            if road.get("cautions") and road["cautions"] not in (r["cautions"] or ""):
                sets.append("cautions=?"); vals.append(((r["cautions"] or "") + " / " + road["cautions"]).strip(" /"))
            sets.append("confidence=max(confidence,?)"); vals.append(road.get("confidence", 0))
            # 市町村・概算距離は未設定なら補う
            for col in ("start_municipality", "end_municipality"):
                if road.get(col) and not r[col]:
                    sets.append(f"{col}=?"); vals.append(road[col])
            if road.get("approx_length_km") and not r["approx_length_km"]:
                sets.append("approx_length_km=?"); vals.append(road["approx_length_km"])
            self.db.execute(f"update roads set {', '.join(sets)}, updated_at=datetime('now') where id=?", (*vals, road_id))
        cur = self.db.execute("insert or ignore into road_videos(road_id,video_id,timestamp,evidence,confidence) values (?,?,?,?,?)",
                              (road_id, video_id, road.get("timestamp", ""), road.get("evidence", ""), road.get("confidence", 0)))
        if cur.rowcount:
            self.db.execute("update roads set mentions=mentions+1 where id=?", (road_id,))
        self.db.commit()
        return road_id

    def roads_pending_geo(self, limit: int) -> list[dict]:
        return [dict(r) for r in self.db.execute("select * from roads where geo_status='pending' order by mentions desc, confidence desc limit ?", (limit,))]

    def save_geo(self, road_id: int, geom: list | None, length_m: float | None, curv: float | None, error: str | None, suspect: str | None = None):
        status = "failed" if not geom else ("suspect" if suspect else "ok")
        self.db.execute("update roads set geom=?, length_m=?, curviness=?, geo_status=?, geo_error=?, updated_at=datetime('now') where id=?",
                        (json.dumps(geom) if geom else None, length_m, curv, status, error or suspect, road_id))
        self.db.commit()

    def roads(self, geo_ok_only: bool = False, statuses: tuple[str, ...] | None = None) -> list[dict]:
        if statuses is None:
            statuses = ("ok",) if geo_ok_only else ("pending", "ok", "suspect", "failed")
        ph = ",".join("?" * len(statuses))
        q = f"select * from roads where geo_status in ({ph}) order by mentions desc, confidence desc"
        return [dict(r) for r in self.db.execute(q, statuses)]

    def reset_geo(self, statuses: tuple[str, ...] = ("failed", "suspect")) -> int:
        ph = ",".join("?" * len(statuses))
        cur = self.db.execute(f"update roads set geo_status='pending', geom=null, geo_error=null where geo_status in ({ph})", statuses)
        self.db.commit()
        return cur.rowcount

    def reset_roads(self) -> int:
        n = self.db.execute("select count(*) from roads").fetchone()[0]
        self.db.execute("delete from road_videos")
        self.db.execute("delete from roads")
        self.db.execute("update channels set hits=0, videos=0")
        self.db.execute("update videos set status='fetched', reason=null, extracted=null where status in ('extracted','video_analyzed','failed')")
        self.db.commit()
        return n

    def road_videos(self, road_id: int) -> list[dict]:
        return [dict(r) for r in self.db.execute("""select rv.*, v.title, v.channel, v.view_count from road_videos rv join videos v on v.id=rv.video_id
            where rv.road_id=? order by v.view_count desc""", (road_id,))]

    def merge_roads(self, keep_id: int, drop_id: int):
        self.db.execute("insert or ignore into road_videos(road_id,video_id,timestamp,evidence,confidence) select ?,video_id,timestamp,evidence,confidence from road_videos where road_id=?", (keep_id, drop_id))
        self.db.execute("delete from road_videos where road_id=?", (drop_id,))
        self.db.execute("update roads set mentions=(select count(*) from road_videos where road_id=?) where id=?", (keep_id, keep_id))
        self.db.execute("delete from roads where id=?", (drop_id,))
        self.db.commit()

    def stats(self) -> dict:
        s = {}
        for r in self.db.execute("select status, count(*) c from videos group by status"):
            s[f"videos_{r['status']}"] = r["c"]
        for r in self.db.execute("select geo_status, count(*) c from roads group by geo_status"):
            s[f"roads_{r['geo_status']}"] = r["c"]
        s["roads_total"] = self.db.execute("select count(*) from roads").fetchone()[0]
        s["channels"] = self.db.execute("select count(*) from channels").fetchone()[0]
        return s
