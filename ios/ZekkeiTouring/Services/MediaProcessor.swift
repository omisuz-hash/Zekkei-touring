import Foundation
import UIKit
import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 写真ライブラリから選んだ動画をファイルとして受け取るための型
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}

enum MediaProcessorError: LocalizedError {
    case unsupported
    case exportFailed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported: return "この形式のファイルは添付できません"
        case .exportFailed: return "動画の圧縮に失敗しました"
        case .tooLarge: return "動画が大きすぎます（圧縮後 50MB まで）"
        }
    }
}

/// 写真の縮小と動画の圧縮。通信量と保管費用を抑えるため、端末側で行う
enum MediaProcessor {
    static func process(_ item: PhotosPickerItem) async throws -> PendingMedia {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        if isVideo {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else { throw MediaProcessorError.unsupported }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return try await video(at: movie.url)
        } else {
            guard let data = try await item.loadTransferable(type: Data.self), let media = photo(from: data) else {
                throw MediaProcessorError.unsupported
            }
            return media
        }
    }

    /// 長辺 1600px の JPEG に縮小
    static func photo(from data: Data) -> PendingMedia? {
        guard let image = UIImage(data: data) else { return nil }
        let resized = resize(image, maxEdge: MediaLimits.maxPhotoEdge)
        guard let jpeg = resized.jpegData(compressionQuality: MediaLimits.photoJPEGQuality) else { return nil }
        let thumb = resize(resized, maxEdge: 400)
        return PendingMedia(kind: .photo, data: jpeg, thumbnail: thumb, thumbnailData: nil,
                            width: Int(resized.size.width), height: Int(resized.size.height), durationS: nil)
    }

    /// 720p・最大 30 秒の mp4 に圧縮し、サムネイルを作る
    static func video(at url: URL) async throws -> PendingMedia {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let clipped = min(duration, MediaLimits.maxVideoSeconds)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw MediaProcessorError.exportFailed
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: clipped, preferredTimescale: 600))
        await export.export()
        guard export.status == .completed else { throw MediaProcessorError.exportFailed }
        defer { try? FileManager.default.removeItem(at: out) }

        let data = try Data(contentsOf: out)
        guard data.count <= MediaLimits.maxVideoBytes else { throw MediaProcessorError.tooLarge }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        let (cg, _) = try await generator.image(at: CMTime(seconds: min(1, clipped / 2), preferredTimescale: 600))
        let thumb = UIImage(cgImage: cg)
        let thumbData = thumb.jpegData(compressionQuality: 0.7)

        return PendingMedia(kind: .video, data: data, thumbnail: thumb, thumbnailData: thumbData,
                            width: cg.width, height: cg.height, durationS: clipped)
    }

    private static func resize(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
