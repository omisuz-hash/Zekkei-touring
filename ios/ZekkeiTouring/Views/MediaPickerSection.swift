import SwiftUI
import PhotosUI

/// 投稿画面の「写真・動画」セクション
struct MediaPickerSection: View {
    @Binding var pending: [PendingMedia]
    @State private var selection: [PhotosPickerItem] = []
    @State private var isProcessing = false
    @State private var message: String?

    private var photoCount: Int { pending.filter { $0.kind == .photo }.count }
    private var videoCount: Int { pending.filter { $0.kind == .video }.count }

    var body: some View {
        Section("写真・動画") {
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pending) { m in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: m.thumbnail)
                                    .resizable().scaledToFill()
                                    .frame(width: 88, height: 88).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .bottomLeading) {
                                        if m.kind == .video {
                                            Label(String(format: "%.0f秒", m.durationS ?? 0), systemImage: "video.fill")
                                                .font(.caption2).padding(4)
                                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                                .foregroundStyle(.white).padding(4)
                                        }
                                    }
                                Button {
                                    pending.removeAll { $0.id == m.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .padding(4)
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            PhotosPicker(selection: $selection,
                         maxSelectionCount: MediaLimits.maxPhotos + MediaLimits.maxVideos,
                         matching: .any(of: [.images, .videos])) {
                HStack {
                    Label("写真・動画を追加", systemImage: "photo.on.rectangle.badge.plus")
                    Spacer()
                    if isProcessing { ProgressView() }
                }
            }
            .disabled(isProcessing)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                Task { await process(items) }
            }

            Text("写真は最大 \(MediaLimits.maxPhotos) 枚（自動で縮小）、動画は \(MediaLimits.maxVideos) 本（\(Int(MediaLimits.maxVideoSeconds)) 秒・720p に自動圧縮）。長い動画は YouTube の URL で紹介できます。")
                .font(.caption).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func process(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        message = nil
        defer {
            isProcessing = false
            selection = []
        }
        var skipped: [String] = []
        for item in items {
            do {
                let media = try await MediaProcessor.process(item)
                if media.kind == .photo && photoCount >= MediaLimits.maxPhotos {
                    skipped.append("写真は \(MediaLimits.maxPhotos) 枚まで"); continue
                }
                if media.kind == .video && videoCount >= MediaLimits.maxVideos {
                    skipped.append("動画は \(MediaLimits.maxVideos) 本まで"); continue
                }
                pending.append(media)
            } catch {
                skipped.append(error.localizedDescription)
            }
        }
        if !skipped.isEmpty {
            message = Array(Set(skipped)).joined(separator: " / ")
        }
    }
}
