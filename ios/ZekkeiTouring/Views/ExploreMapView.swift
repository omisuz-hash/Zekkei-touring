import SwiftUI
import MapKit

/// 周辺の絶景道を地図で探す
struct ExploreMapView: View {
    @EnvironmentObject private var app: AppState
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.2, longitude: 138.5),
                           span: MKCoordinateSpan(latitudeDelta: 1.5, longitudeDelta: 1.5)))
    @State private var roads: [ZekkeiRoad] = []
    @State private var selected: ZekkeiRoad?
    @State private var isLoading = false
    @State private var lastCenter: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selected) {
                UserAnnotation()
                ForEach(roads) { road in
                    MapPolyline(coordinates: road.coordinates)
                        .stroke(color(for: road), lineWidth: app.isUnlocked(road) ? 6 : 4)
                    if let start = road.coordinates.first {
                        Marker(road.name, systemImage: road.isSeed ? "play.rectangle" : "star.fill", coordinate: start)
                            .tint(color(for: road))
                            .tag(road)
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                Task { await load(center: ctx.region.center, span: ctx.region.span) }
            }
            .sheet(item: $selected) { road in
                RoadDetailView(road: road)
                    .presentationDetents([.medium, .large])
            }
            .overlay(alignment: .top) {
                if isLoading { ProgressView().padding(8).background(.thinMaterial, in: Capsule()).padding(.top, 8) }
            }
            .overlay(alignment: .bottomLeading) {
                legend.padding()
            }
            .navigationTitle("絶景道を探す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CreditBadge()
                }
            }
        }
        .onAppear { app.recorder.requestPermission() }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Circle().fill(.red).frame(width: 10, height: 10); Text("絶景度 4.5 以上") }
            HStack { Circle().fill(.orange).frame(width: 10, height: 10); Text("絶景度 3.5 以上") }
            HStack { Circle().fill(.gray).frame(width: 10, height: 10); Text("評価が少ない") }
        }
        .font(.caption2)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(for road: ZekkeiRoad) -> Color {
        guard let s = road.avgScenery, road.ratingCount > 0 else { return .gray }
        if s >= 4.5 { return .red }
        if s >= 3.5 { return .orange }
        return .yellow
    }

    private func load(center: CLLocationCoordinate2D, span: MKCoordinateSpan) async {
        if let last = lastCenter, GeoUtils.distance(last, center) < 2000 { return }
        lastCenter = center
        isLoading = true
        defer { isLoading = false }
        let radius = max(15_000, min(200_000, span.latitudeDelta * 111_000))
        do {
            roads = try await app.backend.nearbyRoads(center: center, radiusMeters: radius)
        } catch {
            app.lastError = error.localizedDescription
        }
    }
}

/// 残りの閲覧枠バッジ
struct CreditBadge: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        Group {
            if app.profile?.plan == .subscriber {
                Label("無制限", systemImage: "infinity")
            } else {
                Label("\(app.creditBalance)", systemImage: "ticket")
            }
        }
        .font(.caption.bold())
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.orange.opacity(0.15), in: Capsule())
    }
}
