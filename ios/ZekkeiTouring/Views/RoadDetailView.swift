import SwiftUI
import MapKit

/// 絶景道の詳細。閲覧枠を使うまでは概要のみ表示
struct RoadDetailView: View {
    @EnvironmentObject private var app: AppState
    @State var road: ZekkeiRoad
    @State private var ratings: [RoadRating] = []
    @State private var showReport = false
    @State private var reportReason = ""
    @State private var showSignIn = false

    private var unlocked: Bool { app.isUnlocked(road) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Map(initialPosition: .region(region)) {
                        MapPolyline(coordinates: road.coordinates).stroke(.orange, lineWidth: 5)
                    }
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets())
                    .allowsHitTesting(false)
                }

                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(road.name).font(.headline)
                            Text([road.prefecture, road.startLabel.map { "\($0) 〜 \(road.endLabel ?? "")" }].compactMap { $0 }.joined(separator: " / "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack {
                            Text(road.overallScore.map { String(format: "%.1f", $0) } ?? "-").font(.title.bold())
                            Text("\(road.ratingCount)件").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("距離", value: road.lengthKmText)
                    if let c = road.curviness {
                        LabeledContent("曲がり具合（推定）", value: String(format: "%.0f%%", c * 100))
                    }
                    if road.isSeed {
                        Label("動画・編集部から登録された道", systemImage: "play.rectangle").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if unlocked {
                    Section("ライダーの評価") {
                        ForEach(RatingAxis.allCases) { axis in
                            ScoreBar(axis: axis, value: value(for: axis))
                        }
                    }
                    if let d = road.description, !d.isEmpty {
                        Section("紹介") { Text(d) }
                    }
                    if let y = road.youtubeUrl, let url = URL(string: y) {
                        Section("動画") {
                            Link(destination: url) {
                                Label(road.youtubeChannel ?? "YouTube で見る", systemImage: "play.rectangle.fill")
                            }
                        }
                    }
                    Section("コメント") {
                        if ratings.isEmpty {
                            Text("まだコメントはありません").foregroundStyle(.secondary)
                        }
                        ForEach(ratings) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    ForEach(RatingAxis.allCases) { axis in
                                        Label("\(r.score(for: axis))", systemImage: axis.symbol).font(.caption2)
                                    }
                                }
                                if let c = r.comment, !c.isEmpty { Text(c).font(.subheadline) }
                                if let s = r.season, !s.isEmpty { Text("おすすめ: \(s)").font(.caption).foregroundStyle(.secondary) }
                            }
                            .contextMenu {
                                Button(role: .destructive) { report(targetType: "rating", id: r.id) } label: { Label("この投稿を通報", systemImage: "flag") }
                                Button(role: .destructive) { Task { try? await app.backend.block(userId: r.userId) } } label: { Label("この投稿者をブロック", systemImage: "hand.raised") }
                            }
                        }
                    }
                    Section {
                        Button { openNavigation() } label: { Label("Google マップでこの区間へナビ", systemImage: "arrow.triangle.turn.up.right.diamond") }
                    }
                } else {
                    Section {
                        VStack(spacing: 10) {
                            Text("評価の内訳・コメント・動画を見るには閲覧枠を使います")
                                .font(.subheadline).multilineTextAlignment(.center)
                            if app.isSignedIn {
                                Button {
                                    Task { _ = await app.unlock(road) }
                                } label: {
                                    Text("閲覧枠を1つ使って見る（残り \(app.creditBalance)）")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent).tint(.orange)
                                .disabled(app.creditBalance <= 0)
                                if app.creditBalance <= 0 {
                                    Text("絶景道を投稿すると閲覧枠が増えます。月額プランなら無制限です。")
                                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                }
                            } else {
                                Button("ログインして見る") { showSignIn = true }
                                    .buttonStyle(.borderedProminent).tint(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("絶景道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { showReport = true } label: { Label("この道を通報", systemImage: "flag") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("通報の理由", isPresented: $showReport) {
                TextField("理由", text: $reportReason)
                Button("送信") { report(targetType: "road", id: road.id) }
                Button("キャンセル", role: .cancel) {}
            }
            .sheet(isPresented: $showSignIn) { SignInView() }
            .task(id: unlocked) {
                guard unlocked else { return }
                ratings = (try? await app.backend.ratings(for: road.id)) ?? []
                if let fresh = try? await app.backend.road(id: road.id) { road = fresh }
            }
        }
    }

    private var region: MKCoordinateRegion {
        let c = GeoUtils.center(of: road.coordinates) ?? CLLocationCoordinate2D(latitude: 36, longitude: 138)
        let lats = road.coordinates.map(\.latitude), lngs = road.coordinates.map(\.longitude)
        let span = MKCoordinateSpan(latitudeDelta: max(0.02, ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.4),
                                    longitudeDelta: max(0.02, ((lngs.max() ?? 0) - (lngs.min() ?? 0)) * 1.4))
        return MKCoordinateRegion(center: c, span: span)
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
        if let app = URL(string: "comgooglemaps://?saddr=\(origin)&daddr=\(dest)&directionsmode=driving"),
           UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else if let web = URL(string: "https://www.google.com/maps/dir/?api=1&origin=\(origin)&destination=\(dest)&travelmode=driving") {
            UIApplication.shared.open(web)
        }
    }
}
