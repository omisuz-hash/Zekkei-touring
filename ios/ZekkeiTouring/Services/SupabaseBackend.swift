import Foundation
import CoreLocation
import Supabase

/// Supabase 版の窓口。接続先は Info.plist（SupabaseURL / SupabaseAnonKey）から読む
final class SupabaseBackend: Backend {
    let client: SupabaseClient

    init?(bundle: Bundle = .main) {
        guard let urlString = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              let url = URL(string: urlString),
              urlString.contains("supabase.co"), !urlString.contains("REPLACE"),
              let key = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !key.isEmpty, key != "REPLACE" else {
            return nil
        }
        client = SupabaseClient(supabaseURL: url, supabaseKey: key)
    }

    var currentUserId: UUID? { client.auth.currentUser?.id }

    private func requireUser() throws -> UUID {
        guard let id = currentUserId else { throw BackendError.notSignedIn }
        return id
    }

    // MARK: 認証

    func restoreSession() async {
        _ = try? await client.auth.session
    }

    func signInWithGoogle(idToken: String, accessToken: String?) async throws {
        try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .google, idToken: idToken, accessToken: accessToken))
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
    }

    func signInAsGuest() async throws {
        try await client.auth.signInAnonymously()
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    // MARK: 会員

    func profile() async throws -> Profile? {
        guard let id = currentUserId else { return nil }
        let rows: [Profile] = try await client.from("profiles").select().eq("id", value: id.uuidString).execute().value
        return rows.first
    }

    private struct PrivacyUpdate: Encodable {
        let privacy_center: String?
        let privacy_radius_m: Int
    }

    func updatePrivacyZone(center: CLLocationCoordinate2D?, radiusMeters: Int) async throws {
        let id = try requireUser()
        let wkt = center.map { String(format: "SRID=4326;POINT(%.6f %.6f)", $0.longitude, $0.latitude) }
        try await client.from("profiles")
            .update(PrivacyUpdate(privacy_center: wkt, privacy_radius_m: radiusMeters))
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: 絶景道

    func nearbyRoads(center: CLLocationCoordinate2D, radiusMeters: Double) async throws -> [ZekkeiRoad] {
        try await client.rpc("nearby_roads", params: [
            "p_lat": center.latitude,
            "p_lng": center.longitude,
            "p_radius_m": radiusMeters,
        ]).execute().value
    }

    func road(id: UUID) async throws -> ZekkeiRoad? {
        let rows: [ZekkeiRoad] = try await client.from("zekkei_roads").select().eq("id", value: id.uuidString).execute().value
        return rows.first
    }

    private struct OverlapParams: Encodable {
        let p_wkt: String
        let p_min_ratio: Double
    }

    func findOverlappingRoad(ewkt: String, minRatio: Double) async throws -> OverlapMatch? {
        // 関数は SRID 指定なしの WKT を受け取る
        let wkt = ewkt.replacingOccurrences(of: "SRID=4326;", with: "")
        let rows: [OverlapMatch] = try await client.rpc("find_overlapping_road", params: OverlapParams(p_wkt: wkt, p_min_ratio: minRatio)).execute().value
        return rows.first { $0.overlapRatio >= minRatio }
    }

    func createRoad(_ draft: RoadDraft) async throws -> ZekkeiRoad {
        try await client.from("zekkei_roads").insert(draft).select().single().execute().value
    }

    func submitRating(_ rating: RoadRating) async throws {
        try await client.from("road_ratings").insert(rating).execute()
    }

    func ratings(for roadId: UUID) async throws -> [RoadRating] {
        try await client.from("road_ratings").select()
            .eq("road_id", value: roadId.uuidString)
            .eq("status", value: "published")
            .order("created_at", ascending: false)
            .execute().value
    }

    func videos(for roadId: UUID) async throws -> [RoadVideo] {
        try await client.from("road_videos").select()
            .eq("road_id", value: roadId.uuidString)
            .order("view_count", ascending: false)
            .execute().value
    }

    // MARK: 閲覧枠

    func creditBalance() async throws -> Int {
        let id = try requireUser()
        return try await client.rpc("credit_balance", params: ["p_user_id": id.uuidString]).execute().value
    }

    private struct UnlockRow: Decodable {
        let road_id: UUID
    }

    func unlockedRoadIds() async throws -> Set<UUID> {
        let id = try requireUser()
        let rows: [UnlockRow] = try await client.from("road_unlocks").select("road_id").eq("user_id", value: id.uuidString).execute().value
        return Set(rows.map(\.road_id))
    }

    func unlockRoad(_ roadId: UUID) async throws -> UnlockResult {
        _ = try requireUser()
        let rows: [UnlockResult] = try await client.rpc("unlock_road", params: ["p_road_id": roadId.uuidString]).execute().value
        guard let r = rows.first else { throw BackendError.server("unlock_road returned no rows") }
        return r
    }

    // MARK: 通報・ブロック

    private struct ReportRow: Encodable {
        let reporter_id: UUID
        let target_type: String
        let target_id: UUID
        let reason: String
    }

    func report(targetType: String, targetId: UUID, reason: String) async throws {
        let id = try requireUser()
        try await client.from("reports").insert(ReportRow(reporter_id: id, target_type: targetType, target_id: targetId, reason: reason)).execute()
    }

    // MARK: 写真・動画

    func uploadMedia(data: Data, bucket: String, path: String, contentType: String) async throws {
        _ = try requireUser()
        _ = try await client.storage.from(bucket).upload(path, data: data, options: FileOptions(contentType: contentType))
    }

    func publicURL(bucket: String, path: String) -> URL? {
        try? client.storage.from(bucket).getPublicURL(path: path)
    }

    func createMedia(_ media: RoadMedia) async throws {
        try await client.from("road_media").insert(media).execute()
    }

    func media(for roadId: UUID) async throws -> [RoadMedia] {
        try await client.from("road_media").select()
            .eq("road_id", value: roadId.uuidString)
            .eq("status", value: "published")
            .order("created_at", ascending: false)
            .execute().value
    }

    private struct BlockRow: Encodable {
        let blocker_id: UUID
        let blocked_id: UUID
    }

    func block(userId: UUID) async throws {
        let id = try requireUser()
        try await client.from("blocks").insert(BlockRow(blocker_id: id, blocked_id: userId)).execute()
    }
}
