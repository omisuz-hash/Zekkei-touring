import SwiftUI
import CoreLocation

/// 切り出した区間に名前と評価を付けて投稿する
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
    @State private var season = ""
    @State private var comment = ""
    @State private var isSubmitting = false
    @State private var overlap: (road: ZekkeiRoad, ratio: Double)?
    @State private var showOverlapChoice = false
    @State private var showSignIn = false
    @State private var done = false

    private let seasons = ["", "春", "夏", "秋", "冬", "早朝", "夕方"]

    var body: some View {
        Form {
            Section("道の名前") {
                TextField("例: 〇〇県道123号 △△〜□□", text: $name)
                TextField("始点の目印（任意）", text: $startLabel)
                TextField("終点の目印（任意）", text: $endLabel)
                TextField("都道府県（任意）", text: $prefecture)
            }
            Section("評価") {
                ForEach(RatingAxis.allCases) { axis in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(axis.title, systemImage: axis.symbol)
                        Text(axis.caption).font(.caption).foregroundStyle(.secondary)
                        StarPicker(value: Binding(get: { scores[axis] ?? 3 }, set: { scores[axis] = $0 }))
                    }
                    .padding(.vertical, 2)
                }
                Picker("おすすめの季節・時間帯", selection: $season) {
                    ForEach(seasons, id: \.self) { Text($0.isEmpty ? "指定なし" : $0) }
                }
                Stepper("交通量: \(traffic == 0 ? "未入力" : "\(traffic)/5")", value: $traffic, in: 0...5)
            }
            Section("コメント・紹介文") {
                TextField("この道の見どころ、注意点など", text: $comment, axis: .vertical).lineLimit(3...6)
                TextField("道の紹介（新規登録時のみ・任意）", text: $description, axis: .vertical).lineLimit(2...4)
            }
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if isSubmitting { ProgressView() }
                        Text("投稿する").frame(maxWidth: .infinity)
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                Text("投稿1件につき閲覧枠が 3 つ増えます。区間の形状と評価のみ公開され、走行記録全体は公開されません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("絶景道を投稿")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("同じ道が登録済みです", isPresented: $showOverlapChoice, titleVisibility: .visible) {
            Button("既存の「\(overlap?.road.name ?? "")」に評価を追加") { Task { await submit(attachTo: overlap?.road) } }
            Button("別の道として新規登録") { Task { await submit(forceNew: true) } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(String(format: "区間の %.0f%% が既存の道と重なっています。", (overlap?.ratio ?? 0) * 100))
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .alert("投稿しました", isPresented: $done) {
            Button("OK") { dismiss() }
        } message: {
            Text("閲覧枠の残り: \(app.creditBalance)")
        }
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
            let rating = RoadRating(
                roadId: road.id, userId: userId, rideLogId: ride.id,
                scenery: scores[.scenery] ?? 3, rideQuality: scores[.rideQuality] ?? 3, winding: scores[.winding] ?? 3,
                restStops: scores[.restStops] ?? 3, parking: scores[.parking] ?? 3,
                traffic: traffic == 0 ? nil : traffic, season: season.isEmpty ? nil : season,
                comment: comment.isEmpty ? nil : comment, riddenAt: ride.startedAt)
            try await app.backend.submitRating(rating)
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
