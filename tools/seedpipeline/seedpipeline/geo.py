"""住所→座標（ジオコーディング）と、始点〜終点の道路形状（ルーティング）。
google: Geocoding API + Routes API（課金登録が必要。無料枠あり）
osm:    Nominatim + OSRM（無料・キー不要。1 秒 1 リクエストの礼儀を守る。精度と可用性は劣る）
"""
import math
import re
import time
from datetime import datetime, timedelta, timezone
from .http import request, HTTPError

JST = timezone(timedelta(hours=9))


def daytime_departure() -> str:
    """経路計算の出発時刻。夜間通行止め・冬季閉鎖で迂回させないため、
    5〜10 月のうち直近の土曜 10:00（JST）を使う"""
    now = datetime.now(JST)
    d = now
    if not (5 <= now.month <= 10):
        d = datetime(now.year + (1 if now.month > 10 else 0), 5, 1, tzinfo=JST)
    d = d + timedelta(days=(5 - d.weekday()) % 7 or 7)  # 次の土曜
    d = d.replace(hour=10, minute=0, second=0, microsecond=0)
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clean_label(label: str) -> tuple[str, str]:
    """「青山交差点（相模原市）」→ ("青山交差点", "相模原市")。括弧内が市区町村ならそれを返す"""
    label = (label or "").strip()
    m = re.search(r"[（(]([^）)]*)[）)]", label)
    inner = m.group(1).strip() if m else ""
    base = re.sub(r"[（(][^）)]*[）)]", "", label).strip()
    muni = inner if re.search(r"(市|区|町|村)$", inner) else ""
    return base or label, muni

JP_BOUNDS = (122.0, 24.0, 154.0, 46.0)


def in_japan(lng: float, lat: float) -> bool:
    return JP_BOUNDS[0] < lng < JP_BOUNDS[2] and JP_BOUNDS[1] < lat < JP_BOUNDS[3]


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    (lng1, lat1), (lng2, lat2) = a, b
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lng2 - lng1)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


def decode_polyline(s: str) -> list[tuple[float, float]]:
    """Google/OSRM の polyline5 を [(lng, lat)] に復号"""
    coords, index, lat, lng = [], 0, 0, 0
    while index < len(s):
        for is_lat in (True, False):
            shift = result = 0
            while True:
                b = ord(s[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            d = ~(result >> 1) if result & 1 else result >> 1
            if is_lat:
                lat += d
            else:
                lng += d
        coords.append((lng / 1e5, lat / 1e5))
    return coords


def simplify(coords: list[tuple[float, float]], tolerance_m: float = 15) -> list[tuple[float, float]]:
    """Douglas-Peucker。DB に入れる点数を抑える"""
    if len(coords) <= 2:
        return coords
    keep = [False] * len(coords)
    keep[0] = keep[-1] = True
    stack = [(0, len(coords) - 1)]
    while stack:
        s, e = stack.pop()
        if e - s < 2:
            continue
        scale = math.cos(math.radians(coords[s][1]))
        ax, ay = coords[s][0] * scale, coords[s][1]
        bx, by = coords[e][0] * scale, coords[e][1]
        dx, dy = bx - ax, by - ay
        best, idx = 0.0, s
        for i in range(s + 1, e):
            px, py = coords[i][0] * scale, coords[i][1]
            t = 0 if dx == 0 and dy == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
            qx, qy = ax + t * dx, ay + t * dy
            d = haversine_m((px / scale, py), (qx / scale, qy))
            if d > best:
                best, idx = d, i
        if best > tolerance_m:
            keep[idx] = True
            stack += [(s, idx), (idx, e)]
    return [c for c, k in zip(coords, keep) if k]


def length_m(coords: list[tuple[float, float]]) -> float:
    return sum(haversine_m(coords[i - 1], coords[i]) for i in range(1, len(coords)))


def curviness(coords: list[tuple[float, float]]) -> float:
    if len(coords) < 3:
        return 0.0
    L = length_m(coords)
    if L < 100:
        return 0.0
    def bearing(a, b):
        p1, p2 = math.radians(a[1]), math.radians(b[1])
        dl = math.radians(b[0] - a[0])
        y = math.sin(dl) * math.cos(p2)
        x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
        return (math.degrees(math.atan2(y, x)) + 360) % 360
    turn, prev = 0.0, bearing(coords[0], coords[1])
    for i in range(2, len(coords)):
        b = bearing(coords[i - 1], coords[i])
        d = abs(b - prev)
        turn += 360 - d if d > 180 else d
        prev = b
    return min(1.0, (turn / (L / 1000)) / 700)


# ---- 形の重なりを測る道具 ------------------------------------------------
# 形状は直線区間の点を間引いて保存しているため、頂点同士の距離で測ると
# 直線が長い道（オロロンライン、エサヌカ線など）で重なりを取りこぼす。
# 点を等間隔に打ち直し、相手は線分として扱う。
CELL_DEG = 0.01  # 緯度経度 0.01 度 ≒ 1.1 km。候補を絞る粗い格子の一辺


def cell_of(p: tuple[float, float]) -> tuple[int, int]:
    return (int(p[0] / CELL_DEG), int(p[1] / CELL_DEG))


def point_to_segment_m(p: tuple[float, float], a: tuple[float, float], b: tuple[float, float]) -> float:
    """点 p と線分 ab の距離。緯度に応じて経度を縮めた平面で近似する"""
    scale = math.cos(math.radians(p[1]))
    px, py = p[0] * scale, p[1]
    ax, ay = a[0] * scale, a[1]
    bx, by = b[0] * scale, b[1]
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return haversine_m(p, a)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return haversine_m(p, ((ax + t * dx) / scale, ay + t * dy))


def resample(coords: list[tuple[float, float]], step_m: float = 100.0) -> list[tuple[float, float]]:
    """点列を一定間隔で打ち直す"""
    if len(coords) < 2:
        return list(coords)
    out = [coords[0]]
    carry = 0.0
    for i in range(1, len(coords)):
        a, b = coords[i - 1], coords[i]
        d = haversine_m(a, b)
        if d == 0:
            continue
        t = step_m - carry
        while t < d:
            f = t / d
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
            t += step_m
        carry = (carry + d) % step_m
    out.append(coords[-1])
    return out


def segment_index(coords: list[tuple[float, float]]) -> dict[tuple[int, int], list]:
    """点列を線分に分け、粗い格子に登録する。重なり判定の総当たりを避けるため"""
    grid: dict[tuple[int, int], list] = {}
    for i in range(1, len(coords)):
        a, b = coords[i - 1], coords[i]
        n = max(1, int(max(abs(b[0] - a[0]), abs(b[1] - a[1])) / (CELL_DEG / 2)) + 1)
        last = None
        for k in range(n + 1):
            f = k / n
            c = cell_of((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
            if c != last:
                grid.setdefault(c, []).append((a, b))
                last = c
    return grid


def overlap_ratio(samples: list[tuple[float, float]], grid: dict, tol_m: float = 120.0) -> float:
    """打ち直した点列 samples のうち、grid に入れた線に tol_m 以内で沿う割合"""
    if not samples or not grid:
        return 0.0
    hit = 0
    for p in samples:
        cx, cy = cell_of(p)
        near = False
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for a, b in grid.get((cx + dx, cy + dy), ()):
                    if point_to_segment_m(p, a, b) < tol_m:
                        near = True
                        break
                if near:
                    break
            if near:
                break
        if near:
            hit += 1
    return hit / len(samples)


def line_overlap(a: list[tuple[float, float]], b: list[tuple[float, float]], tol_m: float = 120.0) -> float:
    """a の線のうち b の線に沿う割合。組を 1 回だけ比べるときに使う"""
    return overlap_ratio(resample(a), segment_index(b), tol_m)


def ewkt(coords: list[tuple[float, float]]) -> str:
    return "SRID=4326;LINESTRING(" + ", ".join(f"{lng:.6f} {lat:.6f}" for lng, lat in coords) + ")"


class GeoError(Exception):
    pass


class GoogleGeo:
    def __init__(self, geocoding_key: str, routes_key: str | None = None):
        self.key = geocoding_key
        self.routes_key = routes_key or geocoding_key
        self.calls = 0

    def geocode(self, label: str, prefecture: str, municipality: str = "") -> tuple[float, float, str] | None:
        """(lng, lat, 都道府県名) を返す。都道府県名は結果から読み取ったもの"""
        q = f"{prefecture}{municipality} {label}".strip()
        data = request("https://maps.googleapis.com/maps/api/geocode/json",
                       params={"address": q, "region": "jp", "language": "ja", "components": "country:JP", "key": self.key})
        self.calls += 1
        if data.get("status") != "OK":
            return None
        res = data["results"][0]
        loc = res["geometry"]["location"]
        lng, lat = loc["lng"], loc["lat"]
        pref = next((c["long_name"] for c in res.get("address_components", []) if "administrative_area_level_1" in c.get("types", [])), "")
        self.last_address = res.get("formatted_address", "")
        return (lng, lat, pref) if in_japan(lng, lat) else None

    def route(self, points: list[tuple[float, float]]) -> list[tuple[float, float]]:
        def wp(p):
            return {"location": {"latLng": {"latitude": p[1], "longitude": p[0]}}}
        # 出発時刻を昼間に固定すると、夜間通行止めの道（奥多摩周遊道路など）を迂回せずに通る
        body = {"origin": wp(points[0]), "destination": wp(points[-1]), "travelMode": "DRIVE",
                "routingPreference": "TRAFFIC_AWARE", "departureTime": daytime_departure(),
                "routeModifiers": {"avoidHighways": True},
                "polylineQuality": "HIGH_QUALITY", "languageCode": "ja", "regionCode": "JP"}
        if len(points) > 2:
            body["intermediates"] = [wp(p) for p in points[1:-1]]
        data = request("https://routes.googleapis.com/directions/v2:computeRoutes", method="POST", body=body,
                       headers={"X-Goog-Api-Key": self.routes_key, "X-Goog-FieldMask": "routes.polyline.encodedPolyline,routes.distanceMeters"})
        self.calls += 1
        routes = data.get("routes") or []
        if not routes:
            raise GeoError("経路が見つかりません")
        return decode_polyline(routes[0]["polyline"]["encodedPolyline"])


class OSMGeo:
    """無料の代替。Nominatim は 1 req/s、OSRM デモサーバーは商用利用不可のため試用・個人用途に限る"""
    def __init__(self):
        self.calls = 0
        self._last = 0.0

    def _pace(self):
        wait = 1.1 - (time.time() - self._last)
        if wait > 0:
            time.sleep(wait)
        self._last = time.time()

    def geocode(self, label: str, prefecture: str, municipality: str = "") -> tuple[float, float, str] | None:
        self._pace()
        data = request("https://nominatim.openstreetmap.org/search",
                       params={"q": f"{prefecture}{municipality} {label}".strip(), "format": "json", "countrycodes": "jp", "limit": 1,
                               "accept-language": "ja", "addressdetails": 1},
                       headers={"User-Agent": "zekkei-touring-seedpipeline/1.0 (research; contact via repo)"})
        self.calls += 1
        if not data:
            return None
        lng, lat = float(data[0]["lon"]), float(data[0]["lat"])
        addr = data[0].get("address", {})
        pref = addr.get("province") or addr.get("state") or ""
        self.last_address = data[0].get("display_name", "")
        return (lng, lat, pref) if in_japan(lng, lat) else None

    def route(self, points: list[tuple[float, float]]) -> list[tuple[float, float]]:
        self._pace()
        coords = ";".join(f"{lng},{lat}" for lng, lat in points)
        data = request(f"https://router.project-osrm.org/route/v1/driving/{coords}",
                       params={"overview": "full", "geometries": "polyline"})
        self.calls += 1
        if data.get("code") != "Ok" or not data.get("routes"):
            raise GeoError("経路が見つかりません")
        return decode_polyline(data["routes"][0]["geometry"])


class CachedGeo:
    """同じ地名（道の駅、峠など）を何度も座標にしないためのキャッシュ。地図 API の呼び出し数を減らす"""
    def __init__(self, inner, store):
        self.inner = inner
        self.store = store
        self.last_address = ""

    @property
    def calls(self):
        return self.inner.calls

    @calls.setter
    def calls(self, v):
        self.inner.calls = v

    def geocode(self, label: str, prefecture: str, municipality: str = ""):
        q = f"{type(self.inner).__name__}|{prefecture}{municipality} {label}".strip()
        hit = self.store.geocache_get(q)
        if hit:
            lng, lat, pref, addr = hit
            self.last_address = addr or ""
            return (lng, lat, pref) if lng is not None else None
        r = self.inner.geocode(label, prefecture, municipality)
        self.last_address = getattr(self.inner, "last_address", "") or ""
        if r:
            self.store.geocache_put(q, r[0], r[1], r[2], self.last_address)
        else:
            self.store.geocache_put(q, None, None, "", "")
        return r

    def route(self, points):
        return self.inner.route(points)


def make_geo(provider: str, geocoding_key: str, routes_key: str | None = None):
    if provider == "google":
        if not geocoding_key or not (routes_key or geocoding_key):
            raise SystemExit("GEO_PROVIDER=google には GOOGLE_MAPS_API_KEY（または GOOGLE_GEOCODING_API_KEY と GOOGLE_ROUTES_API_KEY）が必要です")
        return GoogleGeo(geocoding_key, routes_key)
    return OSMGeo()


def _pref_core(p: str) -> str:
    p = (p or "").strip()
    for suf in ("県", "府", "都"):
        p = p.replace(suf, "")
    return p.replace("北海道", "北海") if p == "北海道" else p


# 始点に戻ってくる道を示す語。地点名が同じ場合と合わせて、周回・往復の判断に使う
LOOP_WORDS = ("周遊", "周回", "環状", "一周", "外周", "ぐるり", "循環")


def one_way_of_out_and_back(line: list[tuple[float, float]]) -> list[tuple[float, float]] | None:
    """始点に戻る経路のうち、往路と復路が同じ道をたどるもの（行き止まりの林道など）は
    折り返し地点までの片道を返す。別の道を通って戻る周回路なら None"""
    if len(line) < 6:
        return None
    far = max(range(len(line)), key=lambda i: haversine_m(line[0], line[i]))
    if far < 2 or far > len(line) - 3:
        return None
    out, back = line[:far + 1], line[far:]
    a, b = overlap_ratio(resample(out), segment_index(back)), overlap_ratio(resample(back), segment_index(out))
    return out if min(a, b) >= 0.7 else None


# 通称で呼ばれる道は 1 本あたりこの距離を超えることはまれ。超えたら「要確認」に落とす
MAX_PLAUSIBLE_M = 200_000


def build_geometry(geo, road: dict) -> dict:
    """始点・経由地・終点を座標にし、道路に沿った形状を取る。
    返り値の suspect に理由が入っていれば「形状は取れたが要確認」"""
    pref = road.get("prefecture", "") or ""
    # 「神奈川県・山梨県」のように複数ある場合は先頭を代表にし、照合は全てで行う
    prefs = [p for p in pref.replace("・", "/").replace("、", "/").split("/") if p]
    pref_main = prefs[0] if prefs else ""

    def geocode_checked(label: str, municipality: str, required: bool):
        label, inner_muni = clean_label(label)
        municipality = municipality or inner_muni
        for muni in ([municipality, ""] if municipality else [""]):
            r = geo.geocode(label, pref_main, muni)
            if not r:
                continue
            lng, lat, got_pref = r
            addr = getattr(geo, "last_address", "") or ""
            pref_ok = not prefs or not got_pref or _pref_core(got_pref) in [_pref_core(p) for p in prefs]
            # 都道府県が違っても、指定した市区町村が住所に含まれていれば採用（県境をまたぐ道の対策）
            muni_ok = bool(municipality) and municipality in addr
            if not (pref_ok or muni_ok):
                continue
            return (lng, lat)
        if required:
            raise GeoError(f"座標にできません（都道府県不一致または未検出）: {label}")
        return None

    points = []
    start = geocode_checked(road["start_label"], road.get("start_municipality", ""), True)
    points.append(start)
    for v in road.get("via_labels", [])[:4]:
        if v:
            p = geocode_checked(v, "", False)
            if p:
                points.append(p)
    end = geocode_checked(road["end_label"], road.get("end_municipality", ""), True)
    points.append(end)

    approx = float(road.get("approx_length_km") or 0)
    straight = haversine_m(points[0], points[-1])
    # 始点と終点がほぼ同じ座標になる道には、周回路・行き止まりの往復と、地点名の取り違えが混ざる。
    # 地点名が同じか名前が周回を示すものだけを形状づけに進め、残りは取り違えとして修復に回す
    closed = False
    if straight < 300:
        sl, _ = clean_label(road["start_label"])
        el, _ = clean_label(road["end_label"])
        same_ends = re.sub(r"\s+", "", sl) == re.sub(r"\s+", "", el)
        if not (same_ends or any(w in (road.get("name") or "") for w in LOOP_WORDS)):
            raise GeoError("始点と終点が同じ座標になりました（地点名の取り違えの可能性）")
        if len(points) < 3:
            raise GeoError("周回・往復の道ですが、途中の地点がないため形を引けません")
        closed = True
    if straight > 250_000:
        raise GeoError("始点と終点が離れすぎています（250km 超）")
    # 経由地が始点〜終点の範囲から大きく外れていれば捨てる（誤認の経由地で大回りするのを防ぐ）
    if len(points) > 2 and not closed:
        span = max(straight, 5_000) * 1.5
        points = [points[0]] + [p for p in points[1:-1] if haversine_m(points[0], p) < span and haversine_m(points[-1], p) < span] + [points[-1]]
    elif len(points) > 2 and closed and approx > 0:
        # 周回・往復では始点から遠い経由地こそ正しい（折り返し地点・対岸）。
        # 想定距離は片道・一周のどちらを指すか分からないため、明らかな外れだけを捨てる
        radius = approx * 1000 * 1.5
        points = [points[0]] + [p for p in points[1:-1] if haversine_m(points[0], p) < radius] + [points[-1]]
        if len(points) < 3:
            raise GeoError("周回・往復の道ですが、途中の地点がないため形を引けません")

    def plausibility(L: float) -> str | None:
        if approx > 0:
            ratio = (L / 1000) / approx
            if ratio > 2.5 or ratio < 0.4:
                return f"距離が想定と合いません（経路 {L / 1000:.0f} km / 想定 {approx:.0f} km）"
        return None

    line = geo.route(points)
    L = length_m(line)
    if closed:
        # 行って戻るだけの道（行き止まりの林道など）は、折り返し地点までの片道を形状とする
        one_way = one_way_of_out_and_back(line)
        if one_way:
            line, L = one_way, length_m(one_way)
    # 経由地が誤認で大回りしている場合は、始点・終点だけで引き直した方が想定距離に近いことがある
    if len(points) > 2 and not closed and plausibility(L):
        alt = geo.route([points[0], points[-1]])
        La = length_m(alt)
        if approx > 0 and abs(La / 1000 - approx) < abs(L / 1000 - approx):
            line, L = alt, La
    if L < 500 or L > 300_000:
        raise GeoError(f"経路長が範囲外です: {L:.0f} m")
    if L > straight * 4 and len(points) == 2:
        raise GeoError("経路が遠回りすぎます（地点の誤認の可能性）")
    line = simplify(line, 15)

    suspect = plausibility(L)
    if L > MAX_PLAUSIBLE_M and not (approx > 0 and (L / 1000) / approx <= 1.5):
        suspect = f"1 本の道として長すぎます（{L / 1000:.0f} km）"
    return {"coords": line, "length_m": L, "curviness": curviness(line), "straight_m": straight,
            "start": line[0], "end": line[-1], "closed": closed, "suspect": suspect}
