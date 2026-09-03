import SwiftUI
import MapKit

/// 走行記録から「ここからここまで」を切り出して絶景道にする
struct TrimView: View {
    @EnvironmentObject private var app: AppState
    let ride: RideLog

    @State private var startIndex: Double = 0
    @State private var endIndex: Double = 0
    @State private var cumulative: [Double] = []
    @State private var goRate = false

    private var coords: [CLLocationCoordinate2D] { ride.coordinates }
    private var lower: Int { Int(startIndex) }
    private var upper: Int { max(Int(endIndex), lower + 1) }
    private var segment: [CLLocationCoordinate2D] {
        guard coords.count > 1, upper < coords.count else { return [] }
        return Array(coords[lower...upper])
    }
    private var segmentLengthM: Double {
        guard cumulative.count > upper else { return 0 }
        return cumulative[upper] - cumulative[lower]
    }

    var body: some View {
        VStack(spacing: 0) {
            Map(initialPosition: .region(region)) {
                if coords.count > 1 {
                    MapPolyline(coordinates: coords).stroke(.gray.opacity(0.6), lineWidth: 3)
                }
                if segment.count > 1 {
                    MapPolyline(coordinates: segment).stroke(.orange, lineWidth: 6)
                    Marker("開始", systemImage: "flag", coordinate: segment.first!).tint(.green)
                    Marker("終了", systemImage: "flag.checkered", coordinate: segment.last!).tint(.red)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("公開する区間を選ぶ").font(.headline)
                Text("自宅周辺（プライバシーゾーン）は自動で除外されています。スライダーで始点と終点を調整してください。")
                    .font(.caption).foregroundStyle(.secondary)
                if coords.count > 1 {
                    HStack {
                        Text("始点").frame(width: 36)
                        Slider(value: $startIndex, in: 0...Double(coords.count - 2), step: 1)
                            .onChange(of: startIndex) { _, v in if v >= endIndex { endIndex = min(Double(coords.count - 1), v + 1) } }
                        Text(km(cumulative[safe: lower])).frame(width: 64, alignment: .trailing)
                    }
                    HStack {
                        Text("終点").frame(width: 36)
                        Slider(value: $endIndex, in: 1...Double(coords.count - 1), step: 1)
                            .onChange(of: endIndex) { _, v in if v <= startIndex { startIndex = max(0, v - 1) } }
                        Text(km(cumulative[safe: upper])).frame(width: 64, alignment: .trailing)
                    }
                    HStack {
                        Label(String(format: "%.1f km", segmentLengthM / 1000), systemImage: "ruler")
                        Spacer()
                        Label(String(format: "曲がり %.0f%%", GeoUtils.curviness(of: segment) * 100), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .font(.subheadline)
                }
                Button {
                    goRate = true
                } label: {
                    Text("この区間を絶景道として評価する").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
                .disabled(segment.count < 2 || segmentLengthM < 500)
                if segmentLengthM < 500 && segment.count >= 2 {
                    Text("500 m 以上の区間を選んでください").font(.caption).foregroundStyle(.red)
                }
            }
            .padding()
            .background(.regularMaterial)
        }
        .navigationTitle("区間の切り出し")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $goRate) {
            RateView(ride: ride, segment: segment)
        }
        .onAppear {
            cumulative = GeoUtils.cumulativeDistances(coords)
            let r = GeoUtils.privacyClippedRange(coords, center: app.privacyCenter, radiusMeters: app.privacyRadiusMeters)
            startIndex = Double(r.lowerBound)
            endIndex = Double(max(r.upperBound, r.lowerBound + 1))
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
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
