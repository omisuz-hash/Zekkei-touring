import SwiftUI

/// 走行記録が無くても、この道に写真・動画を後から追加する画面
/// （昔のツーリングの写真を後日あげる用途を想定）
struct AddMediaView: View {
    let road: ZekkeiRoad
    /// 追加できたものを親に返す
    var onDone: ([RoadMedia]) -> Void

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pending: [PendingMedia] = []
    @State private var isSending = false
    @State private var progress = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(road.name).font(.system(size: 17, weight: .bold))
                        Text("この道の写真・動画として公開されます。走行の記録がなくても投稿できます。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                MediaPickerSection(pending: $pending)
                Section {
                    Text("写真は長辺 1600px、動画は 720p・最大 30 秒に縮小して送信します。位置情報は写真から取り除かれます。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("写真・動画を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }.disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? (progress.isEmpty ? "送信中…" : progress) : "投稿する") {
                        Task { await send() }
                    }
                    .disabled(pending.isEmpty || isSending)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func send() async {
        guard let userId = app.backend.currentUserId, !pending.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        var added: [RoadMedia] = []
        for (i, m) in pending.enumerated() {
            progress = "送信中 \(i + 1)/\(pending.count)"
            do {
                added.append(try await app.backend.publish(m, roadId: road.id, ratingId: nil, userId: userId))
            } catch {
                app.lastError = error.localizedDescription
                break
            }
        }
        if !added.isEmpty { onDone(added) }
        if added.count == pending.count { dismiss() } else { pending.removeFirst(added.count) }
    }
}
