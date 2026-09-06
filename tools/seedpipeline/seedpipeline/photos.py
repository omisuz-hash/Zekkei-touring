"""スポットの代表写真: Wikimedia Commons（自由ライセンス）から、地点の近くで最も「それらしい」写真を選ぶ"""
import re
import time

from .http import request

COMMONS = "https://commons.wikimedia.org/w/api.php"
JAWIKI = "https://ja.wikipedia.org/w/api.php"
UA = "zekkei-touring-seedpipeline/1.0 (https://github.com/omisuz-hash/zekkei-touring)"
BAD_WORDS = ("map", "地図", "sign", "標識", "看板", "案内", "plan", "図", "logo", "icon", "diagram", ".svg", ".png", ".gif", "toilet", "トイレ", "menu", "メニュー")
_last = 0.0


def _pace(min_interval: float = 0.5):
    global _last
    wait = _last + min_interval - time.time()
    if wait > 0:
        time.sleep(wait)
    _last = time.time()


def _tokens(name: str) -> list[str]:
    """名前を照合用の断片に。「大観山 パノラマ台」→ ["大観山", "パノラマ台"] と、2 文字以上の部分文字列"""
    parts = [p for p in re.split(r"[\s　・()（）]+", name) if len(p) >= 2]
    return parts or [name]


def _strip_html(s: str) -> str:
    return re.sub(r"<[^>]+>", "", s or "").strip()


def find_wikipedia_image(name: str, lat: float, lng: float, max_dist_m: float = 3000) -> dict | None:
    """日本語 Wikipedia でその名前の記事を探し、記事の代表画像を返す。記事に座標があれば地点から 3 km 以内のものだけ採用"""
    _pace()
    res = request(JAWIKI, params={"action": "query", "format": "json", "generator": "search", "gsrsearch": name, "gsrlimit": 3,
                                  "prop": "pageimages|coordinates", "piprop": "thumbnail|name", "pithumbsize": 640},
                  headers={"User-Agent": UA}, timeout=30)
    toks = _tokens(name)
    for p in sorted(res.get("query", {}).get("pages", {}).values(), key=lambda p: p.get("index", 99)):
        title = p.get("title", "")
        if not any(t in title for t in toks):
            continue
        thumb = (p.get("thumbnail") or {}).get("source")
        if not thumb or any(w in thumb.lower() for w in BAD_WORDS):
            continue
        co = (p.get("coordinates") or [None])[0]
        if co:
            from .geo import haversine_m
            if haversine_m((lng, lat), (co["lon"], co["lat"])) > max_dist_m:
                continue
        return {"url": thumb, "credit": "Wikipedia", "title": title}
    return None


def find_commons_photo(lat: float, lng: float, name: str, radius_m: int = 500) -> dict | None:
    """返り値: {url, credit, title} または None"""
    _pace()
    res = request(COMMONS, params={"action": "query", "format": "json", "list": "geosearch", "gscoord": f"{lat}|{lng}",
                                   "gsradius": radius_m, "gsnamespace": 6, "gslimit": 30}, headers={"User-Agent": UA}, timeout=30)
    hits = res.get("query", {}).get("geosearch", [])
    if not hits:
        return None
    ids = [str(h["pageid"]) for h in hits]
    _pace()
    info = request(COMMONS, params={"action": "query", "format": "json", "prop": "imageinfo", "iiprop": "url|extmetadata|size",
                                    "iiurlwidth": 640, "iiextmetadatafilter": "LicenseShortName|Artist", "pageids": "|".join(ids)},
                   headers={"User-Agent": UA}, timeout=30)
    pages = info.get("query", {}).get("pages", {})
    dist = {str(h["pageid"]): h.get("dist", 0) for h in hits}
    toks = _tokens(name)
    best, best_score = None, -1e9
    for pid, p in pages.items():
        ii = (p.get("imageinfo") or [None])[0]
        if not ii or not ii.get("thumburl"):
            continue
        title = p.get("title", "")
        low = title.lower()
        if any(w in low for w in BAD_WORDS):
            continue
        w, h = ii.get("width", 0), ii.get("height", 0)
        if w < 640 or h < 400:
            continue
        score = 0.0
        score += 3.0 * sum(1 for t in toks if t.lower() in low)
        score += 1.0 if w > h else -0.5                  # 横長を優先
        score += min(w, 3000) / 3000                       # 解像度
        score -= dist.get(pid, 0) / 500                    # 近いほど良い
        if score > best_score:
            best_score, best = score, (ii, title)
    if not best:
        return None
    ii, title = best
    md = ii.get("extmetadata", {})
    artist = _strip_html(md.get("Artist", {}).get("value", ""))[:80]
    lic = md.get("LicenseShortName", {}).get("value", "")
    url = ii["thumburl"].split("?")[0]
    credit = " / ".join(x for x in (artist, lic, "Wikimedia Commons") if x)
    return {"url": url, "credit": credit, "title": title}
