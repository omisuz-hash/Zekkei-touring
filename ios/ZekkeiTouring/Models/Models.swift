import Foundation
import CoreLocation

// MARK: - 位置の基本型

/// 緯度経度。CLLocationCoordinate2D は Codable でないため、保存・通信用にこちらを使う
struct GeoPoint: Codable, Hashable {
    var lat: Double
    var lng: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }

    init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }

    init(_ c: CLLocationCoordinate2D) {
        self.lat = c.latitude
        self.lng = c.longitude
    }
}

/// 走行記録の1点
struct TrackPoint: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var lat: Double
    var lng: Double
    var altitude: Double
    var speedMps: Double
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }

    init(location: CLLocation) {
        lat = location.coordinate.latitude
        lng = location.coordinate.longitude
        altitude = location.altitude
        speedMps = max(0, location.speed)
        timestamp = location.timestamp
    }

    init(lat: Double, lng: Double, altitude: Double = 0, speedMps: Double = 0, timestamp: Date = Date()) {
        self.lat = lat
        self.lng = lng
        self.altitude = altitude
        self.speedMps = speedMps
        self.timestamp = timestamp
    }
}

// MARK: - 走行記録（端末内・非公開）

struct RideLog: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date?
    var points: [TrackPoint]
    /// 切り出し済みで投稿した絶景道の ID
    var publishedRoadIds: [UUID] = []

    var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }
    var distanceMeters: Double { GeoUtils.length(of: coordinates) }
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

// MARK: - 絶景道（公開）

/// PostGIS が返す GeoJSON の LineString
struct GeoJSONLineString: Codable, Hashable {
    var type: String = "LineString"
    /// [lng, lat] の順（GeoJSON 仕様）
    var coordinates: [[Double]]

    var points: [CLLocationCoordinate2D] {
        coordinates.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }
}

struct ZekkeiRoad: Codable, Identifiable, Hashable {
    var id: UUID
    var createdBy: UUID?
    var name: String
    var description: String?
    var prefecture: String?
    var startLabel: String?
    var endLabel: String?
    var geojson: GeoJSONLineString
    var lengthM: Double
    var curviness: Double?
    var isSeed: Bool
    var youtubeUrl: String?
    var youtubeChannel: String?
    var ratingCount: Int
    var avgScenery: Double?
    var avgRideQuality: Double?
    var avgWinding: Double?
    var avgRestStops: Double?
    var avgParking: Double?
    var mediaCount: Int?
    var coverPath: String?

    var coordinates: [CLLocationCoordinate2D] { geojson.points }
    var lengthKmText: String { String(format: "%.1f km", lengthM / 1000) }

    /// 総合スコア（絶景度を重視した加重平均）
    var overallScore: Double? {
        guard let s = avgScenery else { return nil }
        let others = [avgRideQuality, avgWinding, avgRestStops, avgParking].compactMap { $0 }
        let othersAvg = others.isEmpty ? s : others.reduce(0, +) / Double(others.count)
        return s * 0.6 + othersAvg * 0.4
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdBy = "created_by"
        case name, description, prefecture
        case startLabel = "start_label"
        case endLabel = "end_label"
        case geojson
        case lengthM = "length_m"
        case curviness
        case isSeed = "is_seed"
        case youtubeUrl = "youtube_url"
        case youtubeChannel = "youtube_channel"
        case ratingCount = "rating_count"
        case avgScenery = "avg_scenery"
        case avgRideQuality = "avg_ride_quality"
        case avgWinding = "avg_winding"
        case avgRestStops = "avg_rest_stops"
        case avgParking = "avg_parking"
        case mediaCount = "media_count"
        case coverPath = "cover_path"
    }
}

/// 新規投稿用（サーバー側で ID・集計が付く）
struct RoadDraft: Codable {
    var createdBy: UUID
    var name: String
    var description: String?
    var prefecture: String?
    var startLabel: String?
    var endLabel: String?
    /// EWKT 文字列。例: SRID=4326;LINESTRING(139.7 35.6, 139.8 35.7)
    var geom: String
    var lengthM: Double
    var curviness: Double?

    enum CodingKeys: String, CodingKey {
        case createdBy = "created_by"
        case name, description, prefecture
        case startLabel = "start_label"
        case endLabel = "end_label"
        case geom
        case lengthM = "length_m"
        case curviness
    }
}

// MARK: - 評価

enum RatingAxis: String, CaseIterable, Identifiable {
    case scenery, rideQuality, winding, restStops, parking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scenery: return "絶景度"
        case .rideQuality: return "走りやすさ"
        case .winding: return "ワインディング度"
        case .restStops: return "休憩所"
        case .parking: return "絶景スポットの駐車"
        }
    }

    var caption: String {
        switch self {
        case .scenery: return "景色の良さ・開放感"
        case .rideQuality: return "路面の良さ・道幅"
        case .winding: return "カーブの多さ・楽しさ"
        case .restStops: return "道の駅・売店・トイレの有無"
        case .parking: return "景色の良い場所でバイクを停められるか"
        }
    }

    var symbol: String {
        switch self {
        case .scenery: return "mountain.2"
        case .rideQuality: return "road.lanes"
        case .winding: return "point.topleft.down.to.point.bottomright.curvepath"
        case .restStops: return "cup.and.saucer"
        case .parking: return "parkingsign"
        }
    }
}

struct RoadRating: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var roadId: UUID
    var userId: UUID
    var rideLogId: UUID?
    var scenery: Int
    var rideQuality: Int
    var winding: Int
    var restStops: Int
    var parking: Int
    var traffic: Int?
    var season: String?
    var comment: String?
    var photoPaths: [String] = []
    /// 紹介動画（YouTube 等）の URL
    var videoUrl: String?
    var riddenAt: Date?
    var createdAt: Date?

    func score(for axis: RatingAxis) -> Int {
        switch axis {
        case .scenery: return scenery
        case .rideQuality: return rideQuality
        case .winding: return winding
        case .restStops: return restStops
        case .parking: return parking
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case roadId = "road_id"
        case userId = "user_id"
        case rideLogId = "ride_log_id"
        case scenery
        case rideQuality = "ride_quality"
        case winding
        case restStops = "rest_stops"
        case parking, traffic, season, comment
        case photoPaths = "photo_paths"
        case videoUrl = "video_url"
        case riddenAt = "ridden_at"
        case createdAt = "created_at"
    }
}

// MARK: - 閲覧枠・会員

enum Plan: String, Codable {
    case contributor  // 投稿コース: 無料枠 + 投稿特典枠
    case subscriber   // サブスクコース: 閲覧無制限
}

struct Profile: Codable, Identifiable {
    var id: UUID
    var displayName: String
    var avatarUrl: String?
    var plan: Plan

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case plan
    }
}

struct UnlockResult: Codable {
    var unlocked: Bool
    var balance: Int
}

struct OverlapMatch: Codable {
    var roadId: UUID
    var overlapRatio: Double

    enum CodingKeys: String, CodingKey {
        case roadId = "road_id"
        case overlapRatio = "overlap_ratio"
    }
}
