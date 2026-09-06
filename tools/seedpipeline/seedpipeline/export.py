"""結果の書き出し: Supabase 用 SQL、GeoJSON、レポート"""
import json
from datetime import date
from .geo import ewkt


def q(s) -> str:
    if s is None:
        return "null"
    return "'" + str(s).replace("'", "''") + "'"


def export_sql(store, path: str, min_confidence: float = 0.5, min_mentions: int = 1, min_scenery: float = 2.5) -> int:
    # 景色の示唆が低い道（移動区間として抽出されたもの）は出力しない
    roads = [r for r in store.roads(geo_ok_only=True)
             if (r["confidence"] or 0) >= min_confidence and r["mentions"] >= min_mentions
             and (r["scenery_hint"] is None or r["scenery_hint"] >= min_scenery)]
    lines = [f"-- 自動収集した絶景道シード（{date.today().isoformat()}）。{len(roads)} 本",
             "-- 生成元: tools/seedpipeline。形状は地図 API の経路（geometry_quality = routed）",
             "-- 前提: 20260903_init.sql, 20260904_media.sql, 20260904_road_videos.sql, 20260906_hints.sql 適用済み", ""]
    for r in roads:
        coords = json.loads(r["geom"])
        vids = store.road_videos(r["id"])
        top = vids[0] if vids else None
        desc = (r["summary"] or "").strip()
        if r["cautions"]:
            desc += f"\n注意: {r['cautions']}"
        desc += f"\n（動画 {len(vids)} 本から自動抽出。位置は地図経路による推定）"
        lines.append("with r as (")
        def num(v):
            return "null" if v is None else f"{float(v):.2f}"
        lines.append("  insert into public.zekkei_roads (name, description, prefecture, start_label, end_label, geom, length_m, curviness, is_seed, youtube_url, youtube_channel, source, geometry_quality, seed_key, hint_scenery, hint_winding, hint_surface, hint_rest, hint_parking, mention_count)")
        lines.append(f"  values ({q(r['name'])}, {q(desc)}, {q(r['prefecture'])}, {q(r['start_label'])}, {q(r['end_label'])}, {q(ewkt([tuple(c) for c in coords]))}, "
                     f"{r['length_m']:.0f}, {r['curviness'] or 0:.2f}, true, {q('https://www.youtube.com/watch?v=' + top['video_id']) if top else 'null'}, {q(top['channel']) if top else 'null'}, 'seed_auto', 'routed', {q(r['key'])}, "
                     f"{num(r['scenery_hint'])}, {num(r['winding_hint'])}, {num(r['surface_hint'])}, {num(r['rest_hint'])}, {num(r['parking_hint'])}, {int(r['mentions'] or 0)})")
        lines.append("  on conflict (seed_key) do update set description = excluded.description, hint_scenery = excluded.hint_scenery, hint_winding = excluded.hint_winding, "
                     "hint_surface = excluded.hint_surface, hint_rest = excluded.hint_rest, hint_parking = excluded.hint_parking, mention_count = excluded.mention_count, "
                     "geom = excluded.geom, length_m = excluded.length_m, curviness = excluded.curviness, updated_at = now()")
        lines.append("  returning id)")
        lines.append("insert into public.road_videos (road_id, video_id, url, title, channel, view_count, timestamp_label)")
        lines.append("select r.id, v.video_id, v.url, v.title, v.channel, v.view_count, v.ts from r, (values")
        vals = []
        for v in vids:
            vals.append(f"  ({q(v['video_id'])}, {q('https://www.youtube.com/watch?v=' + v['video_id'])}, {q(v['title'])}, {q(v['channel'])}, {int(v['view_count'] or 0)}, {q(v['timestamp'] or '')})")
        lines.append(",\n".join(vals))
        lines.append(") as v(video_id, url, title, channel, view_count, ts)")
        lines.append("on conflict (road_id, video_id) do nothing;")
        lines.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return len(roads)


def export_geojson(store, path: str) -> int:
    feats = []
    for r in store.roads(statuses=("ok", "suspect")):
        props = {k: r[k] for k in ("id", "name", "prefecture", "start_label", "end_label", "mentions", "confidence", "length_m", "curviness", "summary", "geo_status", "geo_error")}
        # geojson.io で色分けされる（要確認は赤）
        props["stroke"] = "#e53935" if r["geo_status"] == "suspect" else "#1e88e5"
        props["stroke-width"] = 4
        feats.append({"type": "Feature", "geometry": {"type": "LineString", "coordinates": json.loads(r["geom"])}, "properties": props})
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"type": "FeatureCollection", "features": feats}, f, ensure_ascii=False)
    return len(feats)


def export_report(store, path: str) -> None:
    s = store.stats()
    roads = store.roads()
    lines = [f"# シード自動収集レポート（{date.today().isoformat()}）", "",
             "## 集計", ""] + [f"- {k}: {v}" for k, v in sorted(s.items())] + ["", "## 道の一覧（言及数順）", "",
             "| 名前 | 都道府県 | 区間 | 言及 | 確度 | 距離 | 形状 |", "|---|---|---|---|---|---|---|"]
    for r in roads:
        L = f"{(r['length_m'] or 0) / 1000:.1f} km" if r["length_m"] else "-"
        note = f" ({(r['geo_error'] or '')[:50]})" if r['geo_status'] in ('failed', 'suspect') else ""
        lines.append(f"| {r['name']} | {r['prefecture'] or ''} | {r['start_label']} 〜 {r['end_label']} | {r['mentions']} | {r['confidence'] or 0:.2f} | {L} | {r['geo_status']}{note} |")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
