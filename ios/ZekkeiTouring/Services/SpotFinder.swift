import Foundation
import MapKit

/// 道の周辺スポットを Apple の地図データから補う（無料・キー不要）。
/// 動画から取れたスポットが少ない道でも、展望台と道の駅くらいは出せるようにする
enum SpotFinder {
    static let queries: [(String, String)] = [("展望台", "viewpoint"), ("道の駅", "rest")]

    static func nearby(road: ZekkeiRoad, excluding existing: [RoadSpot], maxDistanceM: Double = 1200, limit: Int = 6) async -> [RoadSpot] {
        let coords = road.coordinates
        guard coords.count >= 2 else { return [] }
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.05, (lats.max()! - lats.min()!) * 1.3), longitudeDelta: max(0.05, (lngs.max()! - lngs.min()!) * 1.3)))
        var names = Set(existing.map { normalize($0.name) })
        var out: [RoadSpot] = []
        for (q, kind) in queries {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.region = region
            req.resultTypes = .pointOfInterest
            guard let res = try? await MKLocalSearch(request: req).start() else { continue }
            for item in res.mapItems {
                guard let name = item.name, !names.contains(normalize(name)) else { continue }
                let c = item.placemark.coordinate
                let d = coords.map { GeoUtils.distance($0, c) }.min() ?? .infinity
                guard d <= maxDistanceM else { continue }
                names.insert(normalize(name))
                out.append(RoadSpot(id: UUID(), roadId: road.id, name: name, kind: kind, lat: c.latitude, lng: c.longitude, note: nil, source: "apple", videoId: nil))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "").lowercased()
    }
}
