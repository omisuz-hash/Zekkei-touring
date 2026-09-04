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


# 通称で呼ばれる道は 1 本あたりこの距離を超えることはまれ。超えたら「要確認」に落とす
MAX_PLAUSIBLE_M = 120_000


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

    straight = haversine_m(points[0], points[-1])
    if straight < 300:
        raise GeoError("始点と終点が近すぎます（同一地点の可能性）")
    if straight > 250_000:
        raise GeoError("始点と終点が離れすぎています（250km 超）")
    # 経由地が始点〜終点の範囲から大きく外れていれば捨てる（誤認の経由地で大回りするのを防ぐ）
    if len(points) > 2:
        span = max(straight, 5_000) * 1.5
        points = [points[0]] + [p for p in points[1:-1] if haversine_m(points[0], p) < span and haversine_m(points[-1], p) < span] + [points[-1]]

    approx = float(road.get("approx_length_km") or 0)

    def plausibility(L: float) -> str | None:
        if approx > 0:
            ratio = (L / 1000) / approx
            if ratio > 2.5 or ratio < 0.4:
                return f"距離が想定と合いません（経路 {L / 1000:.0f} km / 想定 {approx:.0f} km）"
        return None

    line = geo.route(points)
    L = length_m(line)
    # 経由地が誤認で大回りしている場合は、始点・終点だけで引き直した方が想定距離に近いことがある
    if len(points) > 2 and plausibility(L):
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
            "start": points[0], "end": points[-1], "suspect": suspect}
