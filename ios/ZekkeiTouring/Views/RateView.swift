import SwiftUI
import CoreLocation

/// 評価投稿
struct RateView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let ride: RideLog
    let segment: [CLLocationCoordinate2D]

    @State private var name = ""
    @State private var startLabel = ""
    @State private var endLabel = ""
    @State private var prefecture = ""
    @State private var description = ""
    @State private var scores: [RatingAxis: Int] = Dictionary(uniqueKeysWithValues: RatingAxis.allCases.map { ($0, 3) })
    @State private var traffic = 0
    @State private var seasons: Set<String> = []
    @State private var comment = ""
    @State private var videoURL = ""
    @State private var pending: [PendingMedia] = []
    @State private var uploadNote: String?
    @State private var isSubmitting = false
    @State private var overlap: (road: ZekkeiRoad, ratio: Double)?
    @State private var showOverlapChoice = false
    @State private var showSignIn = false
    @State private var done = false

    private let seasonOptions = ["春", "夏", "秋", "冬", "早朝", "夕方"]

    var body: some View {
        Form {
            Section {
                row("道の名前", required: true) { TextField("", text: $name, prompt: Text("例: ビーナスライン").foregroundStyle(ZK.disabled)).font(.system(size: 15, weight: .bold)) }
                row("始点の目印") { TextField("", text: $startLabel, prompt: Text("例: 白樺湖").foregroundStyle(ZK.disabled)) }
                row("終点の目印") { TextField("", text: $endLabel, prompt: Text("例: 美ヶ原高原").foregroundStyle(ZK.disabled)) }
                row("都道府県") { TextField("", text: $prefecture, prompt: Text("例: 長野県").foregroundStyle(ZK.disabled)) }
            }
            Section {
                ForEach(RatingAxis.allCases) { axis in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(axis.title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            Text(axis.caption).font(.system(size: 10)).foregroundStyle(ZK.caption).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        StarPicker(value: Binding(get: { scores[axis] ?? 3 }, set: { scores[axis] = $0 }))
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    CaptionLabel(text: "おすすめの季節・時間帯", size: 10)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(seasonOptions, id: \.self) { s in
                            Chip(text: s, selected: seasons.contains(s))
                                .onTapGesture { if seasons.contains(s) { seasons.remove(s) } else { seasons.insert(s) } }
                        }
                    }
                    Stepper("交通量: \(traffic == 0 ? "未入力" : "\(traffic)/5")", value: $traffic, in: 0...5).font(.system(size: 14)).foregroundStyle(ZK.body)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }
            Section {
                TextField("", text: $comment, prompt: Text("この道の見どころ、注意点など").foregroundStyle(ZK.disabled), axis: .vertical).lineLimit(3...6)
                TextField("", text: $description, prompt: Text("道の紹介（新規登録時のみ・任意）").foregroundStyle(ZK.disabled), axis: .vertical).lineLimit(2...4)
            } header: { CaptionLabel(text: "コメント・紹介文", size: 10) }
            MediaPickerSection(pending: $pending)
            Section {
                TextField("", text: $videoURL, prompt: Text("https://www.youtube.com/watch?v=...").foregroundStyle(ZK.disabled))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { CaptionLabel(text: "紹介動画の URL（任意）", size: 10) }
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting { ProgressView().tint(ZK.primaryButtonText) }
                        Text(isSubmitting && !pending.isEmpty ? "写真・動画を送信中…" : "投稿する")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(height: 54, radius: 16, font: .system(size: 17, weight: .bold)))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Text("投稿 1 件につき閲覧枠が 3 つ増えます。\n区間の形状と評価のみ公開されます")
                    .font(.system(size: 11)).foregroundStyle(ZK.caption).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZK.bg)
        .tint(ZK.accent)
        .navigationTitle("評価を投稿")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() }.foregroundStyle(ZK.accent) } }
        .navigationBarBackButtonHidden(true)
        .confirmationDialog("同じ道が登録済みです", isPresented: $showOverlapChoice, titleVisibility: .visible) {
            Button("既存の「\(overlap?.road.name ?? "")」に評価を追加") { Task { await submit(attachTo: overlap?.road) } }
            Button("別の道として新規登録") { Task { await submit(forceNew: true) } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(String(format: "区間の %.0f%% が「%@」と重なっています。", (overlap?.ratio ?? 0) * 100, overlap?.road.name ?? ""))
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .sheet(isPresented: $done, onDismiss: { dismiss() }) {
            DoneView(balance: app.creditBalance, note: uploadNote)
                .presentationDetents([.medium])
                .presentationBackground(ZK.bg)
        }
        .preferredColorScheme(.dark)
    }

    private func row<Content: View>(_ label: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Text(label).font(.system(size: 15)).foregroundStyle(ZK.body)
                if required { Text("*").foregroundStyle(ZK.accent) }
            }
            .frame(width: 96, alignment: .leading)
            content().foregroundStyle(.white)
        }
        .frame(minHeight: 32)
    }

    private var validatedVideoURL: String? {
        let t = videoURL.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: t), let host = u.host, host.contains("youtube.com") || host.contains("youtu.be") else { return nil }
        return t
    }

    private func submit(attachTo existing: ZekkeiRoad? = nil, forceNew: Bool = false) async {
        guard app.isSignedIn, let userId = app.backend.currentUserId else { showSignIn = true; return }
        isSubmitting = true
        defer { isSubmitting = false }
        let simplified = GeoUtils.simplify(segment)
        let ewkt = GeoUtils.ewkt(simplified)
        do {
            var target = existing
            if target == nil && !forceNew {
                if let match = try await app.backend.findOverlappingRoad(ewkt: ewkt, minRatio: 0.7),
                   let road = try await app.backend.road(id: match.roadId) {
                    overlap = (road, match.overlapRatio)
                    showOverlapChoice = true
                    return
                }
            }
            if target == nil {
                let draft = RoadDraft(
                    createdBy: userId, name: name, description: description.isEmpty ? nil : description,
                    prefecture: prefecture.isEmpty ? nil : prefecture,
                    startLabel: startLabel.isEmpty ? nil : startLabel, endLabel: endLabel.isEmpty ? nil : endLabel,
                    geom: ewkt, lengthM: GeoUtils.length(of: segment), curviness: GeoUtils.curviness(of: segment))
                target = try await app.backend.createRoad(draft)
            }
            guard let road = target else { return }
            let seasonText = seasonOptions.filter { seasons.contains($0) }.joined(separator: "・")
            let rating = RoadRating(
                roadId: road.id, userId: userId, rideLogId: ride.id,
                scenery: scores[.scenery] ?? 3, rideQuality: scores[.rideQuality] ?? 3, winding: scores[.winding] ?? 3,
                restStops: scores[.restStops] ?? 3, parking: scores[.parking] ?? 3,
                traffic: traffic == 0 ? nil : traffic, season: seasonText.isEmpty ? nil : seasonText,
                comment: comment.isEmpty ? nil : comment,
                videoUrl: validatedVideoURL, riddenAt: ride.startedAt)
            try await app.backend.submitRating(rating)
            var failed = 0
            for m in pending {
                do { _ = try await app.backend.publish(m, roadId: road.id, ratingId: rating.id, userId: userId) }
                catch { failed += 1 }
            }
            if failed > 0 { uploadNote = "写真・動画 \(failed) 件の送信に失敗しました" }
            var updated = ride
            updated.publishedRoadIds.append(road.id)
            app.store.save(updated)
            await app.refreshAccount()
            done = true
        } catch {
            app.lastError = error.localizedDescription
        }
    }
}

/// 投稿完了
struct DoneView: View {
    let balance: Int
    let note: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(ZK.tagBg)
                Circle().stroke(ZK.accent, lineWidth: 1.2)
                Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(ZK.highlight)
            }
            .frame(width: 72, height: 72)
            Text("投稿しました").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            CaptionLabel(text: "閲覧枠の残り")
            Text("\(balance)").font(.zkNumber(48)).foregroundStyle(ZK.highlight)
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(ZK.errorText) }
            Button("閉じる") { dismiss() }.buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24).padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZK.bg)
    }
}
