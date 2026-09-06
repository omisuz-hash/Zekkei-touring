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
create table if not exists spots (
  road_id integer, name text, kind text, lng real, lat real, note text, video_id text,
  primary key (road_id, name)
);
create table if not exists channels (
  id text primary key, title text, crawled integer default 0, hits integer default 0, videos integer default 0
);
create table if not exists quota (day text primary key, youtube_units integer default 0, gemini_calls integer default 0,
  video_analyses integer default 0, geo_calls integer default 0);
create table if not exists searches (keyword text, page integer, done integer default 0, primary key (keyword, page));
create table if not exists geocache (q text primary key, lng real, lat real, pref text, addr text, created_at text);
"""


SPOT_KINDS = ("viewpoint", "food", "rest", "pass", "onsen", "other")


def _num(v, lo: float, hi: float, as_int: bool = False):
    """LLM の出力を安全な数値に丸める（巨大な整数や文字列が来ても DB を壊さない）"""
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    if x != x:  # NaN
        return None
    x = max(lo, min(hi, x))
    return int(round(x)) if as_int else x


def clean_road(road: dict) -> dict:
    r = dict(road)
    for h in ("scenery_hint", "winding_hint", "surface_hint", "rest_hint", "parking_hint"):
        r[h] = _num(r.get(h), 1, 5, as_int=True)
    r["confidence"] = _num(r.get("confidence"), 0, 1) or 0.0
    r["approx_length_km"] = _num(r.get("approx_length_km"), 0, 2000)
    for k in ("name", "road_number", "prefecture", "start_label", "end_label", "start_municipality", "end_municipality",
              "summary", "cautions", "season", "timestamp", "evidence"):
        v = r.get(k)
        r[k] = (str(v).strip()[:500] if v is not None else "")
    r["via_labels"] = [str(v).strip()[:100] for v in (r.get("via_labels") or []) if v][:6]
    spots = []
    for sp in (r.get("spots") or [])[:8]:
        if not isinstance(sp, dict) or not sp.get("name"):
            continue
        kind = str(sp.get("kind") or "other").strip()
        spots.append({"name": str(sp["name"]).strip()[:100], "kind": kind if kind in SPOT_KINDS else "other",
                      "municipality": str(sp.get("municipality") or "").strip()[:50], "note": str(sp.get("note") or "").strip()[:200]})
    r["spots"] = spots
    return r


class Store:
    def __init__(self, path: str):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        # 既存 DB への列追加（あれば無視）
        cols = {r[1] for r in self.db.execute("pragma table_info(roads)")}
        for col, typ in (("start_municipality", "text"), ("end_municipality", "text"), ("approx_length_km", "real"), ("repair_attempts", "integer default 0"),
                         ("spots", "text"), ("spots_status", "text default 'pending'")):
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
        road = clean_road(road)
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
            self._merge_spots(road_id, road.get("spots", []), video_id, [])
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
            self._merge_spots(road_id, road.get("spots", []), video_id, json.loads(r["spots"] or "[]") if "spots" in r.keys() else [])
        cur = self.db.execute("insert or ignore into road_videos(road_id,video_id,timestamp,evidence,confidence) values (?,?,?,?,?)",
                              (road_id, video_id, road.get("timestamp", ""), road.get("evidence", ""), road.get("confidence", 0)))
        if cur.rowcount:
            self.db.execute("update roads set mentions=mentions+1 where id=?", (road_id,))
        self.db.commit()
        return road_id

    def _merge_spots(self, road_id: int, new: list[dict], video_id: str, old: list[dict]):
        """動画ごとのスポット候補を道に貯める（名前で重複排除）。増えたら位置付けをやり直す"""
        if not new:
            return
        names = {s["name"] for s in old}
        added = False
        for sp in new:
            if sp["name"] in names:
                continue
            old.append({**sp, "video_id": video_id})
            names.add(sp["name"])
            added = True
        if added:
            self.db.execute("update roads set spots=?, spots_status='pending' where id=?", (json.dumps(old, ensure_ascii=False), road_id))

    # --- spots
    def roads_pending_spots(self, limit: int) -> list[dict]:
        return [dict(r) for r in self.db.execute(
            "select * from roads where geo_status='ok' and coalesce(spots_status,'pending')='pending' order by mentions desc, confidence desc limit ?", (limit,))]

    def save_spots(self, road_id: int, spots: list[dict]):
        self.db.execute("delete from spots where road_id=?", (road_id,))
        for sp in spots:
            self.db.execute("insert or ignore into spots(road_id,name,kind,lng,lat,note,video_id) values (?,?,?,?,?,?,?)",
                            (road_id, sp["name"], sp["kind"], sp["lng"], sp["lat"], sp.get("note", ""), sp.get("video_id", "")))
        self.db.execute("update roads set spots_status='done' where id=?", (road_id,))
        self.db.commit()

    def road_spots(self, road_id: int) -> list[dict]:
        return [dict(r) for r in self.db.execute("select * from spots where road_id=? order by kind, name", (road_id,))]

    def reset_spots(self) -> int:
        cur = self.db.execute("update roads set spots_status='pending' where geo_status='ok'")
        self.db.commit()
        return cur.rowcount

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

    def roads_to_repair(self, limit: int, min_mentions: int = 2) -> list[dict]:
        return [dict(r) for r in self.db.execute(
            """select * from roads where geo_status in ('failed','suspect') and coalesce(repair_attempts,0)=0
               and mentions>=? and coalesce(confidence,0)>=0.5 order by mentions desc limit ?""", (min_mentions, limit))]

    def apply_repair(self, road_id: int, fix: dict):
        self.db.execute("""update roads set start_label=?, start_municipality=?, end_label=?, end_municipality=?, via_labels=?,
            approx_length_km=coalesce(?, approx_length_km), prefecture=case when ?<>'' then ? else prefecture end,
            repair_attempts=coalesce(repair_attempts,0)+1, geo_status='pending', geom=null, geo_error=null, updated_at=datetime('now') where id=?""",
                        (fix["start_label"], fix.get("start_municipality", ""), fix["end_label"], fix.get("end_municipality", ""),
                         json.dumps(fix.get("via_labels", []), ensure_ascii=False), fix.get("approx_length_km"),
                         fix.get("prefecture", "") or "", fix.get("prefecture", "") or "", road_id))
        self.db.commit()

    def mark_repair_attempted(self, road_id: int):
        self.db.execute("update roads set repair_attempts=coalesce(repair_attempts,0)+1 where id=?", (road_id,))
        self.db.commit()

    def merge_roads(self, keep_id: int, drop_id: int, take_drop_geometry: bool = False):
        if take_drop_geometry:
            self.db.execute("""update roads set geom=(select geom from roads where id=?), length_m=(select length_m from roads where id=?),
                curviness=(select curviness from roads where id=?), start_label=(select start_label from roads where id=?),
                end_label=(select end_label from roads where id=?) where id=?""", (drop_id, drop_id, drop_id, drop_id, drop_id, keep_id))
        self._merge_rest(keep_id, drop_id)

    def reset_geo(self, statuses: tuple[str, ...] = ("failed", "suspect", "ok")) -> int:
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

    def _merge_rest(self, keep_id: int, drop_id: int):
        self.db.execute("insert or ignore into road_videos(road_id,video_id,timestamp,evidence,confidence) select ?,video_id,timestamp,evidence,confidence from road_videos where road_id=?", (keep_id, drop_id))
        self.db.execute("insert or ignore into spots(road_id,name,kind,lng,lat,note,video_id) select ?,name,kind,lng,lat,note,video_id from spots where road_id=?", (keep_id, drop_id))
        self.db.execute("delete from spots where road_id=?", (drop_id,))
        self.db.execute("delete from road_videos where road_id=?", (drop_id,))
        self.db.execute("update roads set mentions=(select count(*) from road_videos where road_id=?) where id=?", (keep_id, keep_id))
        self.db.execute("delete from roads where id=?", (drop_id,))
        self.db.commit()

    def geocache_get(self, q: str):
        r = self.db.execute("select lng, lat, pref, addr from geocache where q=?", (q,)).fetchone()
        return (r["lng"], r["lat"], r["pref"], r["addr"]) if r else None

    def geocache_put(self, q: str, lng, lat, pref, addr):
        self.db.execute("insert or replace into geocache(q,lng,lat,pref,addr,created_at) values (?,?,?,?,?,datetime('now'))", (q, lng, lat, pref, addr))
        self.db.commit()

    def stats(self) -> dict:
        s = {}
        for r in self.db.execute("select status, count(*) c from videos group by status"):
            s[f"videos_{r['status']}"] = r["c"]
        for r in self.db.execute("select geo_status, count(*) c from roads group by geo_status"):
            s[f"roads_{r['geo_status']}"] = r["c"]
        s["roads_total"] = self.db.execute("select count(*) from roads").fetchone()[0]
        s["spots_total"] = self.db.execute("select count(*) from spots").fetchone()[0]
        s["roads_spots_pending"] = self.db.execute("select count(*) from roads where geo_status='ok' and coalesce(spots_status,'pending')='pending'").fetchone()[0]
        s["channels"] = self.db.execute("select count(*) from channels").fetchone()[0]
        return s
