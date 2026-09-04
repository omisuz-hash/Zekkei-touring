import Foundation
import UIKit

enum MediaKind: String, Codable {
    case photo, video

    var bucket: String { self == .photo ? "road-photos" : "road-videos" }
    var contentType: String { self == .photo ? "image/jpeg" : "video/mp4" }
    var fileExtension: String { self == .photo ? "jpg" : "mp4" }
}

/// サーバーに保存済みの写真・動画
struct RoadMedia: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var roadId: UUID
    var ratingId: UUID?
    var userId: UUID
    var kind: MediaKind
    var bucket: String
    var storagePath: String
    var thumbnailPath: String?
    var width: Int?
    var height: Int?
    var durationS: Double?
    var bytes: Int?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case roadId = "road_id"
        case ratingId = "rating_id"
        case userId = "user_id"
        case kind, bucket
        case storagePath = "storage_path"
        case thumbnailPath = "thumbnail_path"
        case width, height
        case durationS = "duration_s"
        case bytes
        case createdAt = "created_at"
    }
}

/// 投稿前に端末内で圧縮済みの添付
struct PendingMedia: Identifiable {
    let id = UUID()
    let kind: MediaKind
    /// 圧縮済みの本体（JPEG または mp4）
    let data: Data
    let thumbnail: UIImage
    /// 動画のサムネイル JPEG。写真は nil（本体をそのまま使う）
    let thumbnailData: Data?
    let width: Int
    let height: Int
    let durationS: Double?
}

/// 投稿の上限。Apple 審査と配信コストの両面から控えめに設定
enum MediaLimits {
    static let maxPhotos = 5
    static let maxVideos = 1
    static let maxPhotoEdge: CGFloat = 1600
    static let photoJPEGQuality: CGFloat = 0.72
    static let maxVideoSeconds: Double = 30
    static let maxVideoBytes = 50 * 1024 * 1024
}
