import SwiftUI
import MapKit

/// 区間の切り出し
struct TrimView: View {
    @AppStorage(MapLook.key) private var mapLookRaw = MapLook.hybrid.rawValue
    private var mapLook: MapLook { MapLook(rawValue: mapLookRaw) ?? .hybrid }

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let ride: RideLog

    // 位置は「走り始めてから何 km か」で持つ。点の番号で持つと、記録の密度
    // （5m ごと）に左右されて長い走行ほど動かしづらくなる
    @State private var startKm: Double = 0
    @State private var endKm: Double = 0
    @State private var cumulative: [Double] = []
    @State private var goRate = false

    /// 微調整の 1 段階
    private static let stepKm = 0.05

    private var coords: [CLLocationCoordinate2D] { ride.coordinates }
    private var totalKm: Double { (cumulative.last ?? 0) / 1000 }

    /// 走り始めてからの距離に最も近い点の番号
    private func index(forKm km: Double) -> Int {
        guard cumulative.count > 1 else { return 0 }
        let target = km * 1000
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private var lower: Int { min(index(forKm: startKm), index(forKm: endKm)) }
    private var upper: Int {
        let u = max(index(forKm: startKm), index(forKm: endKm))
        return min(max(u, lower + 1), max(coords.count - 1, 0))
    }
    private var segment: [CLLocationCoordinate2D] {
        guard coords.count > 1, upper < coords.count else { return [] }
        return Array(coords[lower...upper])
    }
    private var segmentLengthM: Double {
        guard cumulative.count > upper else { return 0 }
        return cumulative[upper] - cumulative[lower]
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(initialPosition: .region(region)) {
                if coords.count > 1 {
                    MapPolyline(coordinates: coords).stroke(ZK.caption, lineWidth: 4)
                }
                if segment.count > 1 {
                    MapPolyline(coordinates: segment).stroke(ZK.highlight.opacity(0.35), lineWidth: 16)
                    MapPolyline(coordinates: segment).stroke(ZK.highlight, lineWidth: 6)
                }
                if let c = app.privacyCenter {
                    MapCircle(center: c, radius: app.privacyRadiusMeters)
                        .foregroundStyle(Color.white.opacity(0.07))
                        .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Annotation("プライバシーゾーン · 自動除外", coordinate: c) { EmptyView() }
                }
            }
            .zkMapStyle(mapLook)
            .ignoresSafeArea()

            HStack(spacing: 8) {
                Button("あとで") { dismiss() }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40).glassPill(radius: 999)
                // GPX で書き出す。他の記録アプリへ移すときや、控えを残すときに使う。
                // 軌跡そのものを渡すため、自宅周辺を含む点は共有先を選ぶ時点で利用者が判断する
                ShareLink(item: ride, preview: SharePreview(TrackExporter.fileName(for: ride))) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).glassPill(radius: 999)
                }
                .accessibilityLabel("この走行記録を GPX で書き出す")
                Spacer()
                Text(String(format: "走行 %.1f km · %@", ride.distanceMeters / 1000, durationText(ride.duration)))
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40).glassPill(radius: 999)
            }
            .padding(.horizontal, 12).padding(.top, 4)

            VStack {
                Spacer()
                // この走行から投稿した絶景道。どこへ投稿したのか後から辿れるようにする
                if !ride.publishedRoadIds.isEmpty {
                    publishedRoads.padding(.horizontal, 10).padding(.bottom, 6)
                }
                card.padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $goRate) { RateView(ride: ride, segment: segment) }
        .onAppear {
            cumulative = GeoUtils.cumulativeDistances(coords)
            let r = GeoUtils.privacyClippedRange(coords, center: app.privacyCenter, radiusMeters: app.privacyRadiusMeters)
            startKm = (cumulative[safe: r.lowerBound] ?? 0) / 1000
            endKm = (cumulative[safe: r.upperBound] ?? cumulative.last ?? 0) / 1000
        }
        .preferredColorScheme(.dark)
    }

    @State private var posted: [ZekkeiRoad] = []

    private var publishedRoads: some View {
        VStack(alignment: .leading, spacing: 6) {
            CaptionLabel(text: "この走行から投稿した絶景道 \(ride.publishedRoadIds.count)")
            ForEach(posted) { r in
                NavigationLink { RoadDetailView(road: r).environmentObject(app) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 13)).foregroundStyle(ZK.highlight)
                        Text(r.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(r.ratingCount > 0 ? "評価 \(r.ratingCount)" : "反映待ち")
                            .font(.system(size: 11)).foregroundStyle(ZK.caption)
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(ZK.caption)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        .glassCard(radius: 18, padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .task(id: ride.publishedRoadIds) {
            var out: [ZekkeiRoad] = []
            for id in ride.publishedRoadIds {
                if let r = try? await app.backend.road(id: id) { out.append(r) }
            }
            posted = out
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("公開する区間を選ぶ").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                if app.privacyCenter != nil {
                    Text("自宅周辺（プライバシーゾーン）は自動で除外されています").font(.system(size: 12)).foregroundStyle(ZK.caption)
                } else {
                    Text("自宅周辺を伏せる設定は未設定です。設定しておくと、この画面で自動的に除かれます")
                        .font(.system(size: 12)).foregroundStyle(ZK.errorText)
                }
            }
            if coords.count > 1 {
                sliderRow("始点", $startKm)
                sliderRow("終点", $endKm)
                HStack(spacing: 8) {
                    StatTile(caption: "選択区間", value: String(format: "%.1f", segmentLengthM / 1000), unit: "km", valueColor: ZK.highlight, valueSize: 24)
                    StatTile(caption: "曲がり具合", value: String(format: "%.0f", GeoUtils.curviness(of: segment) * 100), unit: "%", valueSize: 24)
                }
            }
            Button("この区間を絶景道として評価する") { goRate = true }
                .buttonStyle(PrimaryButtonStyle(height: 56, radius: 16, font: .system(size: 16, weight: .bold)))
                .disabled(segment.count < 2 || segmentLengthM < 500)
            if segmentLengthM < 500 && segment.count >= 2 {
                Text("500 m 以上の区間を選ぶと投稿できます").font(.system(size: 12)).foregroundStyle(ZK.errorText)
            }
            // 自宅からの移動区間まで含めたまま投稿されるのを防ぐ
            if segmentLengthM > 30_000 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(ZK.errorText).padding(.top, 2)
                    Text("\(Int(segmentLengthM / 1000)) km は 1 本の絶景道としては長めです。"
                         + "出発地からの移動区間が入っていないか確かめ、見どころのある区間に絞ることを勧めます。")
                        .font(.system(size: 11)).lineSpacing(3).foregroundStyle(ZK.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .glassCard(radius: 22, padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 24).background(ZK.tagBg).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(ZK.accent, lineWidth: 1))
            Slider(value: value, in: 0...max(Self.stepKm, totalKm), step: Self.stepKm).tint(.white)
            // 長い走行では指先の 1 ミリが数百 m に相当するため、50 m ずつの微調整を添える
            nudge("minus") { value.wrappedValue = max(0, value.wrappedValue - Self.stepKm) }
            nudge("plus") { value.wrappedValue = min(totalKm, value.wrappedValue + Self.stepKm) }
            Text(String(format: "%.2f km", value.wrappedValue))
                .font(.zkNumber(14)).foregroundStyle(.white).frame(width: 66, alignment: .trailing)
        }
    }

    private func nudge(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(ZK.tagBg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ZK.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var region: MKCoordinateRegion {
        let c = GeoUtils.center(of: coords) ?? CLLocationCoordinate2D(latitude: 36, longitude: 138)
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        return MKCoordinateRegion(center: c, span: MKCoordinateSpan(
            latitudeDelta: max(0.02, ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.3),
            longitudeDelta: max(0.02, ((lngs.max() ?? 0) - (lngs.min() ?? 0)) * 1.3)))
    }

    private func durationText(_ t: TimeInterval) -> String { let s = Int(t); return String(format: "%d:%02d", s / 3600, (s % 3600) / 60) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
