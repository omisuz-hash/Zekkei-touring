import Foundation
import CoreLocation

/// 地理計算のユーティリティ。外部ライブラリに依存しない
enum GeoUtils {
    static let earthRadiusM: Double = 6_371_000

    /// 2点間距離（m）
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    /// 折れ線の総延長（m）
    static func length(of coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count { total += distance(coords[i - 1], coords[i]) }
        return total
    }

    /// 各点までの累積距離（m）
    static func cumulativeDistances(_ coords: [CLLocationCoordinate2D]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(coords.count)
        var acc = 0.0
        for (i, c) in coords.enumerated() {
            if i > 0 { acc += distance(coords[i - 1], c) }
            out.append(acc)
        }
        return out
    }

    /// 方位（度）
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLng) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLng)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 曲がり具合の推定値 0...1。1km あたりの方位変化量の合計を基に正規化
    static func curviness(of coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 2 else { return 0 }
        let len = length(of: coords)
        guard len > 100 else { return 0 }
        var turning = 0.0
        var prevBearing = bearing(coords[0], coords[1])
        for i in 2..<coords.count {
            let b = bearing(coords[i - 1], coords[i])
            var d = abs(b - prevBearing)
            if d > 180 { d = 360 - d }
            turning += d
            prevBearing = b
        }
        let degPerKm = turning / (len / 1000)
        // 経験則: 700 度/km を上限として 0...1 に丸める
        return min(1, degPerKm / 700)
    }

    /// Douglas-Peucker による間引き。通信量を抑える
    static func simplify(_ coords: [CLLocationCoordinate2D], toleranceMeters: Double = 8) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }
        var keep = [Bool](repeating: false, count: coords.count)
        keep[0] = true
        keep[coords.count - 1] = true
        var stack: [(Int, Int)] = [(0, coords.count - 1)]
        while let pair = stack.popLast() {
            let (s, e) = pair
            guard e - s > 1 else { continue }
            var maxD = 0.0
            var idx = s
            for i in (s + 1)..<e {
                let d = perpendicularDistance(coords[i], from: coords[s], to: coords[e])
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > toleranceMeters {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return coords.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    private static func perpendicularDistance(_ p: CLLocationCoordinate2D, from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        // 小領域では平面近似で十分
        let scale = cos(a.latitude * .pi / 180)
        let ax = a.longitude * scale, ay = a.latitude
        let bx = b.longitude * scale, by = b.latitude
        let px = p.longitude * scale, py = p.latitude
        let dx = bx - ax, dy = by - ay
        if dx == 0 && dy == 0 { return distance(p, a) }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        let proj = CLLocationCoordinate2D(latitude: ay + t * dy, longitude: (ax + t * dx) / scale)
        return distance(p, proj)
    }

    /// プライバシーゾーン（中心と半径）に入っている先頭・末尾の点を除外した範囲を返す
    static func privacyClippedRange(_ coords: [CLLocationCoordinate2D], center: CLLocationCoordinate2D?, radiusMeters: Double) -> ClosedRange<Int> {
        guard coords.count > 1 else { return 0...max(0, coords.count - 1) }
        guard let center else { return 0...(coords.count - 1) }
        var start = 0
        while start < coords.count - 1 && distance(coords[start], center) < radiusMeters { start += 1 }
        var end = coords.count - 1
        while end > start && distance(coords[end], center) < radiusMeters { end -= 1 }
        return start...end
    }

    /// PostGIS に渡す EWKT 文字列
    static func ewkt(_ coords: [CLLocationCoordinate2D]) -> String {
        let body = coords.map { String(format: "%.6f %.6f", $0.longitude, $0.latitude) }.joined(separator: ", ")
        return "SRID=4326;LINESTRING(\(body))"
    }

    /// 座標列の外接矩形の中心
    static func center(of coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard let first = coords.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        return CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
    }
}
