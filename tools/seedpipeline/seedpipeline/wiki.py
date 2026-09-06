"""沿線の名所: 日本語 Wikipedia の「座標付き記事」を道の周辺から集め、立ち寄りスポットにする（無料）"""
import json
import re

from .http import request
from .geo import haversine_m
from .photos import UA, _pace, BAD_WORDS

JAWIKI = "https://ja.wikipedia.org/w/api.php"

# 記事名に含まれていれば採用する言葉と、その種類
KIND_WORDS = (
    ("rest", ("道の駅",)),
    ("onsen", ("温泉",)),
    ("food", ("茶屋", "食堂", "ドライブイン", "レストラン", "カフェ", "そば", "蕎麦", "うどん", "ソフトクリーム", "ほうとう")),
    ("pass", ("峠", "隧道", "トンネル")),
    ("other", ("神社", "寺", "城", "史跡", "遺跡", "古墳", "美術館", "博物館", "記念館", "ロープウェイ", "スカイライン", "有料道路", "林道")),
    ("viewpoint", ("展望", "ビュー", "見晴", "眺望", "パノラマ", "岬", "高原", "湿原", "滝", "湖", "池", "渓谷", "峡", "海岸", "灯台", "牧場", "花畑", "公園", "ダム", "棚田", "鍾乳洞", "洞窟", "大橋", "吊橋")),
)
# 含まれていたら除外（駅・学校・行政区など）
EXCLUDE = ("駅", "学校", "小学校", "中学校", "高校", "高等学校", "大学", "村", "町", "市", "区", "郡", "郵便局", "警察", "消防", "病院", "放送", "テレビ",
           "組合", "信用", "銀行", "バス", "インターチェンジ", "ジャンクション", "スマートIC", "住宅", "コースター", "支援", "図書館", "会社", "株式会社",
           "FM", "CATV", "開発", "ショッピング", "モール", "工業", "工場", "事務所", "庁", "役場", "変電", "発電", "鉄道", "線", "自動車道", "国道", "県道", "府道", "都道",
           "地区", "字", "団地", "スタジアム", "競技場", "ゴルフ", "空港", "港", "選挙", "事件", "事故", "祭", "一覧")
# 「山」は道の近くの峰だけ（遠い山頂を拾わない）
MOUNTAIN = ("山", "岳", "峰")


def classify(title: str) -> str | None:
    t = title.split(" (")[0]
    if t.startswith("道の駅"):
        return "rest"
    if any(w in t for w in EXCLUDE):
        return None
    for kind, words in KIND_WORDS:
        if any(w in t for w in words):
            return kind
    if any(t.endswith(m) for m in MOUNTAIN):
        return "mountain"
    return None


def _nearest_m(pt, coords):
    return min(haversine_m(pt, c) for c in coords)


def spots_along(road: dict, max_dist_m: float = 1000, max_spots: int = 8) -> list[dict]:
    """道の外接矩形内の記事を取り、道から max_dist_m 以内で種類が分かるものを近い順に返す"""
    coords = [tuple(c) for c in json.loads(road["geom"])]
    lngs = [c[0] for c in coords]; lats = [c[1] for c in coords]
    m = 0.012  # 約 1.2 km の余白
    bbox = f"{max(lats) + m}|{min(lngs) - m}|{min(lats) - m}|{max(lngs) + m}"
    _pace()
    res = request(JAWIKI, params={"action": "query", "format": "json", "list": "geosearch", "gsbbox": bbox, "gslimit": 500, "gsnamespace": 0},
                  headers={"User-Agent": UA}, timeout=30)
    cands = []
    seen = set()
    for g in res.get("query", {}).get("geosearch", []):
        title = g["title"]
        kind = classify(title)
        if not kind:
            continue
        d = _nearest_m((g["lon"], g["lat"]), coords)
        if kind == "mountain":
            if d > 400:
                continue
            kind = "viewpoint"
        elif d > max_dist_m:
            continue
        name = re.sub(r"\s*\([^)]*\)$", "", title).strip()
        if name in seen or name in (road.get("start_label"), road.get("end_label")):
            continue
        seen.add(name)
        cands.append({"pageid": g["pageid"], "name": name[:100], "kind": kind, "lng": g["lon"], "lat": g["lat"], "dist": d, "wiki_title": title})
    cands.sort(key=lambda c: c["dist"])
    cands = cands[:max_spots]
    # 記事の代表画像と冒頭 1 文
    for i in range(0, len(cands), 20):
        chunk = cands[i:i + 20]
        _pace()
        info = request(JAWIKI, params={"action": "query", "format": "json", "pageids": "|".join(str(c["pageid"]) for c in chunk),
                                       "prop": "pageimages|extracts", "piprop": "thumbnail", "pithumbsize": 640,
                                       "exintro": 1, "explaintext": 1, "exsentences": 1, "exlimit": 20},
                       headers={"User-Agent": UA}, timeout=30)
        pages = info.get("query", {}).get("pages", {})
        for c in chunk:
            p = pages.get(str(c["pageid"]), {})
            thumb = (p.get("thumbnail") or {}).get("source")
            if thumb and not any(w in thumb.lower() for w in BAD_WORDS):
                c["photo_url"] = thumb.split("?")[0]
            note = (p.get("extract") or "").strip().replace("\n", " ")
            c["note"] = note[:120]
    return cands
