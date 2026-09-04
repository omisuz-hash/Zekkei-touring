import Foundation
import CoreLocation

/// サーバー側の窓口。実装は Supabase 版と、審査・プレビュー用のモック版
protocol Backend: AnyObject {
    var currentUserId: UUID? { get }

    func restoreSession() async
    func signInWithGoogle(idToken: String, accessToken: String?) async throws
    func signInWithApple(idToken: String, nonce: String) async throws
    func signOut() async throws

    func profile() async throws -> Profile?
    func updatePrivacyZone(center: CLLocationCoordinate2D?, radiusMeters: Int) async throws

    func nearbyRoads(center: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [ZekkeiRoad]
    func road(id: UUID) async throws -> ZekkeiRoad?
    func findOverlappingRoad(ewkt: String, minRatio: Double) async throws -> OverlapMatch?
    func createRoad(_ draft: RoadDraft) async throws -> ZekkeiRoad
    func submitRating(_ rating: RoadRating) async throws
    func ratings(for roadId: UUID) async throws -> [RoadRating]

    func creditBalance() async throws -> Int
    func unlockedRoadIds() async throws -> Set<UUID>
    func unlockRoad(_ roadId: UUID) async throws -> UnlockResult

    func report(targetType: String, targetId: UUID, reason: String) async throws
    func block(userId: UUID) async throws

    // 写真・動画
    func uploadMedia(data: Data, bucket: String, path: String, contentType: String) async throws
    func publicURL(bucket: String, path: String) -> URL?
    func createMedia(_ media: RoadMedia) async throws
    func media(for roadId: UUID) async throws -> [RoadMedia]
}

extension Backend {
    /// 圧縮済みの添付を保存し、台帳に登録する。パスは <road_id>/<media_id>.<ext>
    func publish(_ pending: PendingMedia, roadId: UUID, ratingId: UUID?, userId: UUID) async throws -> RoadMedia {
        let path = "\(roadId.uuidString)/\(pending.id.uuidString).\(pending.kind.fileExtension)"
        try await uploadMedia(data: pending.data, bucket: pending.kind.bucket, path: path, contentType: pending.kind.contentType)
        var thumbPath: String? = nil
        if let t = pending.thumbnailData {
            thumbPath = "\(roadId.uuidString)/\(pending.id.uuidString)_thumb.jpg"
            try await uploadMedia(data: t, bucket: MediaKind.photo.bucket, path: thumbPath!, contentType: "image/jpeg")
        }
        let row = RoadMedia(id: pending.id, roadId: roadId, ratingId: ratingId, userId: userId, kind: pending.kind,
                            bucket: pending.kind.bucket, storagePath: path, thumbnailPath: thumbPath,
                            width: pending.width, height: pending.height, durationS: pending.durationS, bytes: pending.data.count)
        try await createMedia(row)
        return row
    }

    /// サムネイル優先の表示用 URL
    func thumbnailURL(for media: RoadMedia) -> URL? {
        if let t = media.thumbnailPath { return publicURL(bucket: MediaKind.photo.bucket, path: t) }
        return publicURL(bucket: media.bucket, path: media.storagePath)
    }
}

enum BackendError: LocalizedError {
    case notSignedIn
    case notConfigured
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "ログインが必要です"
        case .notConfigured: return "接続先が設定されていません（Info.plist の SupabaseURL）"
        case .server(let m): return m
        }
    }
}

/// モック。プレビューと、サーバー未設定時の動作確認用
final class MockBackend: Backend {
    var currentUserId: UUID? = nil
    private var roads: [ZekkeiRoad] = MockBackend.sampleRoads
    private var ratingsByRoad: [UUID: [RoadRating]] = [:]
    private var balance = 3
    private var unlocked: Set<UUID> = []

    func restoreSession() async {}
    func signInWithGoogle(idToken: String, accessToken: String?) async throws { currentUserId = UUID() }
    func signInWithApple(idToken: String, nonce: String) async throws { currentUserId = UUID() }
    func signOut() async throws { currentUserId = nil }

    func profile() async throws -> Profile? {
        guard let id = currentUserId else { return nil }
        return Profile(id: id, displayName: "テストライダー", avatarUrl: nil, plan: .contributor)
    }
    func updatePrivacyZone(center: CLLocationCoordinate2D?, radiusMeters: Int) async throws {}

    func nearbyRoads(center: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [ZekkeiRoad] { roads }
    func road(id: UUID) async throws -> ZekkeiRoad? { roads.first { $0.id == id } }
    func findOverlappingRoad(ewkt: String, minRatio: Double) async throws -> OverlapMatch? { nil }

    func createRoad(_ draft: RoadDraft) async throws -> ZekkeiRoad {
        let coords = Self.parseEWKT(draft.geom)
        let road = ZekkeiRoad(
            id: UUID(), createdBy: draft.createdBy, name: draft.name, description: draft.description,
            prefecture: draft.prefecture, startLabel: draft.startLabel, endLabel: draft.endLabel,
            geojson: GeoJSONLineString(coordinates: coords.map { [$0.longitude, $0.latitude] }),
            lengthM: draft.lengthM, curviness: draft.curviness, isSeed: false,
            youtubeUrl: nil, youtubeChannel: nil, ratingCount: 0,
            avgScenery: nil, avgRideQuality: nil, avgWinding: nil, avgRestStops: nil, avgParking: nil)
        roads.append(road)
        return road
    }

    func submitRating(_ rating: RoadRating) async throws {
        ratingsByRoad[rating.roadId, default: []].append(rating)
        balance += 3
        if let i = roads.firstIndex(where: { $0.id == rating.roadId }) {
            let all = ratingsByRoad[rating.roadId] ?? []
            func avg(_ f: (RoadRating) -> Int) -> Double { Double(all.map(f).reduce(0, +)) / Double(all.count) }
            roads[i].ratingCount = all.count
            roads[i].avgScenery = avg { $0.scenery }
            roads[i].avgRideQuality = avg { $0.rideQuality }
            roads[i].avgWinding = avg { $0.winding }
            roads[i].avgRestStops = avg { $0.restStops }
            roads[i].avgParking = avg { $0.parking }
        }
    }

    func ratings(for roadId: UUID) async throws -> [RoadRating] { ratingsByRoad[roadId] ?? [] }
    func creditBalance() async throws -> Int { balance }
    func unlockedRoadIds() async throws -> Set<UUID> { unlocked }

    func unlockRoad(_ roadId: UUID) async throws -> UnlockResult {
        if unlocked.contains(roadId) { return UnlockResult(unlocked: true, balance: balance) }
        guard balance > 0 else { return UnlockResult(unlocked: false, balance: balance) }
        balance -= 1
        unlocked.insert(roadId)
        return UnlockResult(unlocked: true, balance: balance)
    }

    func report(targetType: String, targetId: UUID, reason: String) async throws {}
    func block(userId: UUID) async throws {}

    // 添付は端末の一時フォルダに保存して、その場所を URL として返す
    private var mediaByRoad: [UUID: [RoadMedia]] = [:]
    private let mediaDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mock-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func uploadMedia(data: Data, bucket: String, path: String, contentType: String) async throws {
        let url = mediaDir.appendingPathComponent(bucket).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func publicURL(bucket: String, path: String) -> URL? {
        mediaDir.appendingPathComponent(bucket).appendingPathComponent(path)
    }
    func createMedia(_ media: RoadMedia) async throws {
        mediaByRoad[media.roadId, default: []].append(media)
        if let i = roads.firstIndex(where: { $0.id == media.roadId }) {
            roads[i].mediaCount = mediaByRoad[media.roadId]?.count
        }
    }
    func media(for roadId: UUID) async throws -> [RoadMedia] { mediaByRoad[roadId] ?? [] }

    private static func parseEWKT(_ s: String) -> [CLLocationCoordinate2D] {
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return [] }
        return s[s.index(after: open)..<close].split(separator: ",").compactMap { pair in
            let nums = pair.trimmingCharacters(in: .whitespaces).split(separator: " ").compactMap { Double($0) }
            guard nums.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: nums[1], longitude: nums[0])
        }
    }

    static let sampleRoads: [ZekkeiRoad] = [
        ZekkeiRoad(
            id: UUID(), createdBy: nil, name: "ビーナスライン（白樺湖〜美ヶ原）", description: "高原を抜ける定番の絶景ロード",
            prefecture: "長野県", startLabel: "白樺湖", endLabel: "美ヶ原高原美術館",
            geojson: GeoJSONLineString(coordinates: [[138.2050, 36.1120], [138.1700, 36.1400], [138.1200, 36.1800], [138.1000, 36.2300]]),
            lengthM: 38_000, curviness: 0.55, isSeed: true, youtubeUrl: nil, youtubeChannel: nil,
            ratingCount: 12, avgScenery: 4.8, avgRideQuality: 4.2, avgWinding: 4.0, avgRestStops: 4.5, avgParking: 4.6),
        ZekkeiRoad(
            id: UUID(), createdBy: nil, name: "県道沿いの田園ロード（サンプル）", description: "知られていないが、のどかで景色の良い道",
            prefecture: "群馬県", startLabel: "集落入口", endLabel: "峠の展望所",
            geojson: GeoJSONLineString(coordinates: [[138.9000, 36.5000], [138.9200, 36.5150], [138.9350, 36.5300]]),
            lengthM: 6_500, curviness: 0.35, isSeed: true, youtubeUrl: nil, youtubeChannel: nil,
            ratingCount: 3, avgScenery: 4.3, avgRideQuality: 3.5, avgWinding: 2.7, avgRestStops: 2.0, avgParking: 3.3),
    ]
}
