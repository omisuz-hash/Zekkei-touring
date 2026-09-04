"""住所→座標（ジオコーディング）と、始点〜終点の道路形状（ルーティング）。
google: Geocoding API + Routes API（課金登録が必要。無料枠あり）
osm:    Nominatim + OSRM（無料・キー不要。1 秒 1 リクエストの礼儀を守る。精度と可用性は劣る）
"""
import math
import time
from .http import request, HTTPError

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
    def __init__(self, api_key: str):
        self.key = api_key
        self.calls = 0

    def geocode(self, label: str, prefecture: str) -> tuple[float, float] | None:
        q = f"{prefecture} {label}".strip()
        data = request("https://maps.googleapis.com/maps/api/geocode/json",
                       params={"address": q, "region": "jp", "language": "ja", "components": "country:JP", "key": self.key})
        self.calls += 1
        if data.get("status") != "OK":
            return None
        loc = data["results"][0]["geometry"]["location"]
        lng, lat = loc["lng"], loc["lat"]
        return (lng, lat) if in_japan(lng, lat) else None

    def route(self, points: list[tuple[float, float]]) -> list[tuple[float, float]]:
        def wp(p):
            return {"location": {"latLng": {"latitude": p[1], "longitude": p[0]}}}
        body = {"origin": wp(points[0]), "destination": wp(points[-1]), "travelMode": "DRIVE",
                "routingPreference": "TRAFFIC_UNAWARE", "routeModifiers": {"avoidHighways": True},
                "polylineQuality": "HIGH_QUALITY", "languageCode": "ja", "regionCode": "JP"}
        if len(points) > 2:
            body["intermediates"] = [wp(p) for p in points[1:-1]]
        data = request("https://routes.googleapis.com/directions/v2:computeRoutes", method="POST", body=body,
                       headers={"X-Goog-Api-Key": self.key, "X-Goog-FieldMask": "routes.polyline.encodedPolyline,routes.distanceMeters"})
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

    def geocode(self, label: str, prefecture: str) -> tuple[float, float] | None:
        self._pace()
        data = request("https://nominatim.openstreetmap.org/search",
                       params={"q": f"{prefecture} {label}".strip(), "format": "json", "countrycodes": "jp", "limit": 1, "accept-language": "ja"},
                       headers={"User-Agent": "zekkei-touring-seedpipeline/1.0 (research; contact via repo)"})
        self.calls += 1
        if not data:
            return None
        lng, lat = float(data[0]["lon"]), float(data[0]["lat"])
        return (lng, lat) if in_japan(lng, lat) else None

    def route(self, points: list[tuple[float, float]]) -> list[tuple[float, float]]:
        self._pace()
        coords = ";".join(f"{lng},{lat}" for lng, lat in points)
        data = request(f"https://router.project-osrm.org/route/v1/driving/{coords}",
                       params={"overview": "full", "geometries": "polyline"})
        self.calls += 1
        if data.get("code") != "Ok" or not data.get("routes"):
            raise GeoError("経路が見つかりません")
        return decode_polyline(data["routes"][0]["geometry"])


def make_geo(provider: str, google_key: str):
    if provider == "google":
        if not google_key:
            raise SystemExit("GEO_PROVIDER=google には GOOGLE_MAPS_API_KEY が必要です")
        return GoogleGeo(google_key)
    return OSMGeo()


def build_geometry(geo, road: dict) -> dict:
    """始点・経由地・終点を座標にし、道路に沿った形状を取る。妥当性チェック付き"""
    pref = road.get("prefecture", "")
    labels = [road["start_label"]] + [v for v in road.get("via_labels", [])[:4] if v] + [road["end_label"]]
    points = []
    for lb in labels:
        p = geo.geocode(lb, pref)
        if p:
            points.append(p)
        elif lb in (road["start_label"], road["end_label"]):
            raise GeoError(f"座標にできません: {lb}")
    if len(points) < 2:
        raise GeoError("始点と終点が必要です")
    straight = haversine_m(points[0], points[-1])
    if straight < 300:
        raise GeoError("始点と終点が近すぎます（同一地点の可能性）")
    if straight > 250_000:
        raise GeoError("始点と終点が離れすぎています（250km 超）")
    line = geo.route(points)
    L = length_m(line)
    if L < 500 or L > 300_000:
        raise GeoError(f"経路長が範囲外です: {L:.0f} m")
    if L > straight * 4 and len(points) == 2:
        raise GeoError("経路が遠回りすぎます（地点の誤認の可能性）")
    line = simplify(line, 15)
    return {"coords": line, "length_m": L, "curviness": curviness(line), "straight_m": straight,
            "start": points[0], "end": points[-1]}
