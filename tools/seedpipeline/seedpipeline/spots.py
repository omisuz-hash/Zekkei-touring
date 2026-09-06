"""立ち寄りスポット: 動画で言及された展望台・飲食店・道の駅・峠・温泉を、道の近くに位置付ける"""
import json

from .geo import clean_label, haversine_m

KIND_WORDS = (
    ("viewpoint", ("展望", "ビュー", "見晴", "眺望", "絶景ポイント", "パノラマ", "view")),
    ("onsen", ("温泉", "湯", "スパ")),
    ("rest", ("道の駅", "サービスエリア", "パーキング", "ＳＡ", "ＰＡ", "SA", "PA", "売店", "休憩", "ドライブイン", "コンビニ")),
    ("food", ("食堂", "そば", "蕎麦", "うどん", "ラーメン", "カフェ", "cafe", "café", "レストラン", "カレー", "定食", "焼き", "寿司", "丼", "ソフトクリーム", "パン", "喫茶", "飯", "ジェラート", "牧場")),
    ("pass", ("峠", "パス", "トンネル")),
)
MAX_DIST_M = 3000  # 道からこれ以上離れた地点はその道のスポットとみなさない


def classify(name: str) -> str:
    n = name.lower()
    for kind, words in KIND_WORDS:
        if any(w.lower() in n for w in words):
            return kind
    return "other"


def _nearest_m(pt: tuple[float, float], coords: list[tuple[float, float]]) -> float:
    return min(haversine_m(pt, c) for c in coords)


def build_spots(geo, road: dict) -> list[dict]:
    """経由地（via_labels）と動画で言及されたスポット（spots）を座標にし、道から 3 km 以内のものを返す"""
    coords = [tuple(c) for c in json.loads(road["geom"])]
    pref = (road.get("prefecture") or "").replace("・", "/").replace("、", "/").split("/")[0]
    cands: list[dict] = []
    seen = set()
    for sp in json.loads(road.get("spots") or "[]"):
        if sp.get("name") and sp["name"] not in seen:
            cands.append(sp); seen.add(sp["name"])
    for v in json.loads(road.get("via_labels") or "[]"):
        if v and v not in seen and v not in (road.get("start_label"), road.get("end_label")):
            cands.append({"name": v, "kind": classify(v), "municipality": "", "note": ""}); seen.add(v)
    out = []
    for sp in cands[:10]:
        label, inner_muni = clean_label(sp["name"])
        muni = sp.get("municipality") or inner_muni
        pt = None
        for m in ([muni, ""] if muni else [""]):
            r = geo.geocode(label, pref, m)
            if r:
                pt = (r[0], r[1]); break
        if not pt:
            continue
        if _nearest_m(pt, coords) > MAX_DIST_M:
            continue
        kind = sp.get("kind") or "other"
        if kind == "other":
            kind = classify(label)
        out.append({"name": label[:100], "kind": kind, "lng": pt[0], "lat": pt[1],
                    "note": (sp.get("note") or "")[:200], "video_id": sp.get("video_id", "")})
    return out
