import SwiftUI
import MapKit
import AVKit

/// 道の詳細（未解放 → 解放）
struct RoadDetailView: View {
    @EnvironmentObject private var app: AppState
    @State var road: ZekkeiRoad
    @State private var ratings: [RoadRating] = []
    @State private var media: [RoadMedia] = []
    @State private var videos: [RoadVideo] = []
    @State private var viewing: RoadMedia?
    @State private var showReport = false
    @State private var reportReason = ""
    @State private var showSignIn = false

    private var unlocked: Bool { app.isUnlocked(road) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    routeRow
                    HStack(spacing: 8) {
                        StatTile(caption: "スコア", value: road.overallScore.map { String(format: "%.1f", $0) } ?? "–", note: "\(road.ratingCount) 件", valueColor: ZK.tier1)
                        StatTile(caption: "絶景度", value: road.avgScenery.map { String(format: "%.1f", $0) } ?? "–", note: road.avgScenery.map { $0 >= 4.5 ? "最高評価" : "5 点満点" } ?? "評価待ち")
                        StatTile(caption: "動画", value: "\(videos.count)", note: "YouTube")
                    }
                    if let note = road.geometryNote {
                        Text(note).font(.system(size: 10)).foregroundStyle(ZK.caption)
                    }
                    // 動画は閲覧枠の外（無料側）。YouTube の規約上、視聴に条件を付けない
                    if !videos.isEmpty { videoSection }

                    if unlocked { unlockedContent } else { lockedContent }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { showReport = true } label: { Label("この道を通報", systemImage: "flag") }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.white) }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .alert("通報の理由", isPresented: $showReport) {
                TextField("理由", text: $reportReason)
                Button("送信") { report(targetType: "road", id: road.id) }
                Button("キャンセル", role: .cancel) {}
            }
            .sheet(isPresented: $showSignIn) { SignInView() }
            .sheet(item: $viewing) { m in
                MediaViewer(media: m, url: app.backend.publicURL(bucket: m.bucket, path: m.storagePath))
            }
            .task { videos = (try? await app.backend.videos(for: road.id)) ?? [] }
            .task(id: unlocked) {
                guard unlocked else { return }
                ratings = (try? await app.backend.ratings(for: road.id)) ?? []
                media = (try? await app.backend.media(for: road.id)) ?? []
                if let fresh = try? await app.backend.road(id: road.id) { road = fresh }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 部品

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                CodeTag(code: road.shortCode, fromVideo: road.isFromVideos, muted: road.ratingCount == 0)
                Text(road.isFromVideos ? "動画・編集部登録" : "ライダー投稿").font(.system(size: 10)).foregroundStyle(ZK.caption)
            }
            Text(road.name).font(.system(size: 24, weight: .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Text(road.prefecture ?? "").font(.system(size: 12)).foregroundStyle(ZK.caption)
        }
    }

    private var routeRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                CaptionLabel(text: "始点")
                Text(road.startLabel ?? "–").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Text(road.lengthKmText).font(.system(size: 10)).foregroundStyle(ZK.body)
                HStack(spacing: 0) {
                    Circle().fill(ZK.accent).frame(width: 5, height: 5)
                    Rectangle().fill(ZK.accent).frame(width: 86, height: 1)
                    Circle().fill(ZK.accent).frame(width: 5, height: 5)
                }
                Text(road.curviness.map { String(format: "曲がり %.0f%%", $0 * 100) } ?? " ").font(.system(size: 10)).foregroundStyle(ZK.caption)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                CaptionLabel(text: "終点")
                Text(road.endLabel ?? "–").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .innerGroup(radius: 14, thin: true)
    }

    private var lockedContent: some View {
        VStack(spacing: 10) {
            if app.isSignedIn {
                Button {
                    Task { _ = await app.unlock(road) }
                } label: {
                    HStack(spacing: 8) {
                        Text("閲覧枠を 1 つ使って見る")
                        Text("残り \(app.creditBalance)").fontWeight(.regular).opacity(0.7)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(app.creditBalance <= 0)
                Text("絶景道を投稿すると閲覧枠が増えます。月額プランなら無制限です。")
                    .font(.system(size: 11)).foregroundStyle(ZK.caption).multilineTextAlignment(.center)
                Button("月額プランを見る") {}.font(.system(size: 13, weight: .semibold)).foregroundStyle(ZK.accent)
            } else {
                Button("ログインして見る") { showSignIn = true }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.top, 4)
    }

    private var cautions: [String] {
        guard let d = road.description else { return [] }
        return d.split(separator: "\n").filter { $0.hasPrefix("注意") }
            .flatMap { $0.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: ": ：")).components(separatedBy: CharacterSet(charactersIn: "/、・")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var bodyText: String {
        (road.description ?? "").split(separator: "\n").filter { !$0.hasPrefix("注意") && !$0.hasPrefix("（") }.joined(separator: "\n")
    }

    @ViewBuilder private var unlockedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaptionLabel(text: "ライダーの評価")
            ForEach(RatingAxis.allCases) { axis in
                AxisBar(title: axis.title, value: value(for: axis))
            }
        }
        if !cautions.isEmpty {
            HStack(spacing: 6) {
                ForEach(cautions, id: \.self) { c in CautionTag(text: c, filled: c.contains("閉鎖") || c.contains("通行止")) }
            }
        }
        if !bodyText.isEmpty {
            Text(bodyText).font(.system(size: 13)).lineSpacing(6).foregroundStyle(ZK.body)
        }
        if !media.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                CaptionLabel(text: "写真・動画 \(media.count)")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(media) { m in
                            MediaThumb(media: m, url: app.backend.thumbnailURL(for: m)).onTapGesture { viewing = m }
                        }
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            CaptionLabel(text: "コメント \(ratings.count)")
            if ratings.isEmpty {
                Text("まだコメントはありません").font(.system(size: 13)).foregroundStyle(ZK.caption)
            }
            ForEach(ratings) { r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("ライダー").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        Text(RatingAxis.allCases.map { "\(r.score(for: $0))" }.joined(separator: " · ")).font(.system(size: 12, weight: .semibold)).foregroundStyle(ZK.accent)
                        Spacer()
                        if let s = r.season, !s.isEmpty { Text(s).font(.system(size: 10)).foregroundStyle(ZK.caption) }
                    }
                    if let c = r.comment, !c.isEmpty { Text(c).font(.system(size: 13)).lineSpacing(5).foregroundStyle(ZK.body) }
                }
                .padding(12).innerGroup(radius: 12, thin: true)
                .contextMenu {
                    Button(role: .destructive) { report(targetType: "rating", id: r.id) } label: { Label("この投稿を通報", systemImage: "flag") }
                    Button(role: .destructive) { Task { try? await app.backend.block(userId: r.userId) } } label: { Label("この投稿者をブロック", systemImage: "hand.raised") }
                }
            }
        }
        Button { openNavigation() } label: { Label("Google マップでこの区間へナビ", systemImage: "arrow.triangle.turn.up.right.diamond") }
            .buttonStyle(PrimaryButtonStyle())
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionLabel(text: "この道が登場する動画 \(videos.count)")
            ForEach(videos.prefix(3)) { v in
                if let url = v.playURL { Link(destination: url) { VideoRow(video: v) } }
            }
            if videos.count > 3 {
                NavigationLink {
                    List(videos) { v in
                        if let url = v.playURL { Link(destination: url) { VideoRow(video: v) } }
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain).background(ZK.bg).navigationTitle("動画一覧")
                } label: {
                    Text("すべての動画を見る（\(videos.count)）").font(.system(size: 13, weight: .semibold)).foregroundStyle(ZK.accent)
                }
            }
        }
    }

    private func value(for axis: RatingAxis) -> Double? {
        switch axis {
        case .scenery: return road.avgScenery
        case .rideQuality: return road.avgRideQuality
        case .winding: return road.avgWinding
        case .restStops: return road.avgRestStops
        case .parking: return road.avgParking
        }
    }

    private func report(targetType: String, id: UUID) {
        let reason = reportReason.isEmpty ? "不適切な内容" : reportReason
        Task { try? await app.backend.report(targetType: targetType, targetId: id, reason: reason) }
        reportReason = ""
    }

    private func openNavigation() {
        guard let s = road.coordinates.first, let e = road.coordinates.last else { return }
        let origin = "\(s.latitude),\(s.longitude)", dest = "\(e.latitude),\(e.longitude)"
        if let url = URL(string: "comgooglemaps://?saddr=\(origin)&daddr=\(dest)&directionsmode=driving"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let web = URL(string: "https://www.google.com/maps/dir/?api=1&origin=\(origin)&destination=\(dest)&travelmode=driving") {
            UIApplication.shared.open(web)
        }
    }
}

/// 動画の 1 行（96×54 サムネイル・タイトル・チャンネル・登場時刻）
struct VideoRow: View {
    let video: RoadVideo
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: video.thumbnailURL) { phase in
                if case .success(let img) = phase { img.resizable().scaledToFill() } else { Color.white.opacity(0.06) }
            }
            .frame(width: 96, height: 54).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title ?? "動画").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 6) {
                    if let c = video.channel { Text(c).font(.system(size: 11)).foregroundStyle(ZK.caption).lineLimit(1) }
                    if let t = video.timestampLabel, !t.isEmpty {
                        Text(t).font(.system(size: 10, weight: .semibold)).foregroundStyle(ZK.accent)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(ZK.caption)
        }
        .padding(8).innerGroup(radius: 10, thin: true)
    }
}

/// 一覧用のサムネイル
struct MediaThumb: View {
    let media: RoadMedia
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            case .failure: Image(systemName: "photo").foregroundStyle(ZK.caption)
            default: ProgressView().tint(.white)
            }
        }
        .frame(width: 104, height: 104).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            if media.kind == .video {
                Label(media.durationS.map { String(format: "%.0f:%02.0f", ($0 / 60).rounded(.down), $0.truncatingRemainder(dividingBy: 60)) } ?? "", systemImage: "play.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(4)
            }
        }
    }
}

/// 全画面表示。写真は拡大、動画は再生
struct MediaViewer: View {
    let media: RoadMedia
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if media.kind == .video, let url {
                    VideoPlayer(player: AVPlayer(url: url))
                } else {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase { img.resizable().scaledToFit() } else { ProgressView().tint(.white) }
                    }
                }
            }
            .background(.black)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
