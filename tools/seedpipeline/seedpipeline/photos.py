"""スポットの代表写真: Wikimedia Commons（自由ライセンス）から、地点の近くで最も「それらしい」写真を選ぶ"""
import re
import time

from .http import request

COMMONS = "https://commons.wikimedia.org/w/api.php"
UA = "zekkei-touring-seedpipeline/1.0 (https://github.com/omisuz-hash/zekkei-touring)"
BAD_WORDS = ("map", "地図", "sign", "標識", "看板", "案内", "plan", "図", "logo", "icon", "diagram", ".svg", ".png", ".gif", "toilet", "トイレ", "menu", "メニュー")
_last = 0.0


def _pace(min_interval: float = 0.25):
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
