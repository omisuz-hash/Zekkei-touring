import SwiftUI
import MapKit

/// 区間の切り出し
struct TrimView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let ride: RideLog

    @State private var startIndex: Double = 0
    @State private var endIndex: Double = 0
    @State private var cumulative: [Double] = []
    @State private var goRate = false

    private var coords: [CLLocationCoordinate2D] { ride.coordinates }
    private var lower: Int { min(Int(startIndex), Int(endIndex)) }
    private var upper: Int { max(max(Int(startIndex), Int(endIndex)), lower + 1) }
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
            .mapStyle(.hybrid(elevation: .realistic))
            .ignoresSafeArea()

            HStack {
                Button("あとで") { dismiss() }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40).glassPill(radius: 999)
                Spacer()
                Text(String(format: "走行 %.1f km · %@", ride.distanceMeters / 1000, durationText(ride.duration)))
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40).glassPill(radius: 999)
            }
            .padding(.horizontal, 12).padding(.top, 4)

            VStack {
                Spacer()
                card.padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $goRate) { RateView(ride: ride, segment: segment) }
        .onAppear {
            cumulative = GeoUtils.cumulativeDistances(coords)
            let r = GeoUtils.privacyClippedRange(coords, center: app.privacyCenter, radiusMeters: app.privacyRadiusMeters)
            startIndex = Double(r.lowerBound)
            endIndex = Double(max(r.upperBound, r.lowerBound + 1))
        }
        .preferredColorScheme(.dark)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("公開する区間を選ぶ").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                Text("自宅周辺（プライバシーゾーン）は自動で除外されています").font(.system(size: 12)).foregroundStyle(ZK.caption)
            }
            if coords.count > 1 {
                sliderRow("始点", $startIndex, km(cumulative[safe: lower]))
                sliderRow("終点", $endIndex, km(cumulative[safe: upper]))
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
        }
        .glassCard(radius: 22, padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 24).background(ZK.tagBg).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(ZK.accent, lineWidth: 1))
            Slider(value: value, in: 0...Double(max(1, coords.count - 1)), step: 1).tint(.white)
            Text(text).font(.zkNumber(15)).foregroundStyle(.white).frame(width: 64, alignment: .trailing)
        }
    }

    private var region: MKCoordinateRegion {
        let c = GeoUtils.center(of: coords) ?? CLLocationCoordinate2D(latitude: 36, longitude: 138)
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        return MKCoordinateRegion(center: c, span: MKCoordinateSpan(
            latitudeDelta: max(0.02, ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.3),
            longitudeDelta: max(0.02, ((lngs.max() ?? 0) - (lngs.min() ?? 0)) * 1.3)))
    }

    private func km(_ m: Double?) -> String { String(format: "%.1f km", (m ?? 0) / 1000) }
    private func durationText(_ t: TimeInterval) -> String { let s = Int(t); return String(format: "%d:%02d", s / 3600, (s % 3600) / 60) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
