import SwiftUI
import MapKit

/// 探す: 衛星調ダーク地図に絶景道を重ねる
struct ExploreMapView: View {
    @EnvironmentObject private var app: AppState
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.2, longitude: 138.5),
                           span: MKCoordinateSpan(latitudeDelta: 1.5, longitudeDelta: 1.5)))
    @State private var roads: [ZekkeiRoad] = []
    @State private var selected: ZekkeiRoad?
    @State private var isLoading = false
    @State private var lastCenter: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var spanLat: Double = 1.5
    @FocusState private var searchFocused: Bool

    /// 広域ではタグを絞る（密集を防ぐ）。拡大するほど多く出す
    private var taggedRoads: [ZekkeiRoad] {
        let limit: Int
        switch spanLat {
        case ..<0.25: limit = 200
        case ..<0.6: limit = 40
        case ..<1.2: limit = 15
        default: limit = 6
        }
        return Array(roads.sorted { ($0.ratingCount, $0.avgScenery ?? 0) > ($1.ratingCount, $1.avgScenery ?? 0) }.prefix(limit))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position, selection: $selected) {
                UserAnnotation()
                ForEach(roads) { road in
                    let color = ZK.tier(scenery: road.avgScenery, count: road.ratingCount)
                    let strong = (road.avgScenery ?? 0) >= 3.5 && road.ratingCount > 0
                    // 外側グロー → 本線 → 中央ハイライト（絶景度 4.5 以上）
                    if strong {
                        MapPolyline(coordinates: road.coordinates).stroke(color.opacity(0.35), lineWidth: (road.avgScenery ?? 0) >= 4.5 ? 16 : 12)
                    }
                    MapPolyline(coordinates: road.coordinates).stroke(color, lineWidth: lineWidth(road))
                    if (road.avgScenery ?? 0) >= 4.5 && road.ratingCount > 0 {
                        MapPolyline(coordinates: road.coordinates).stroke(Color.white.opacity(0.7), lineWidth: 1.2)
                    }
                }
                ForEach(taggedRoads) { road in
                    if let start = road.coordinates.first {
                        Annotation(road.name, coordinate: start, anchor: .bottomLeading) {
                            CodeTag(code: road.shortCode, fromVideo: road.isFromVideos, muted: road.ratingCount == 0)
                                .onTapGesture { selected = road }
                        }
                        .tag(road)
                        .annotationTitles(.hidden)
                    }
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                spanLat = ctx.region.span.latitudeDelta
                Task { await load(center: ctx.region.center, span: ctx.region.span) }
            }
            .ignoresSafeArea()

            // 上部: 検索バー + 閲覧枠
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ZK.caption)
                    TextField("", text: $query, prompt: Text("地名・道名で探す").foregroundStyle(ZK.caption))
                        .font(.system(size: 15)).foregroundStyle(.white)
                        .submitLabel(.search).focused($searchFocused)
                        .onSubmit { Task { await search() } }
                    if !query.isEmpty {
                        Button { query = ""; searchFocused = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ZK.caption) }
                    }
                }
                .padding(.horizontal, 14).frame(height: 44)
                .glassPill(radius: 14)
                CreditBadge()
            }
            .padding(.horizontal, 12).padding(.top, 8)

            // 左下: 凡例 / 右下: 現在地
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    legend
                    Spacer()
                    Button {
                        app.recorder.requestPermission()
                        withAnimation { position = .userLocation(fallback: .automatic) }
                    } label: {
                        Image(systemName: "location").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).glassPill(radius: 14)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            if isLoading {
                ProgressView().tint(.white).padding(8).glassPill(radius: 999).padding(.top, 60)
            }
        }
        .sheet(item: $selected) { road in
            RoadDetailView(road: road)
                .presentationDetents([.medium, .large])
                .presentationBackground(Color(hex: 0x14181C).opacity(0.96))
                .presentationDragIndicator(.visible)
        }
        .onAppear { app.recorder.requestPermission() }
    }

    private func lineWidth(_ road: ZekkeiRoad) -> CGFloat {
        let base: CGFloat = (road.avgScenery ?? 0) >= 4.5 && road.ratingCount > 0 ? 5 : ((road.avgScenery ?? 0) >= 3.5 && road.ratingCount > 0 ? 4 : 3.5)
        return app.isUnlocked(road) ? base + 1.5 : base
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            CaptionLabel(text: "絶景度", size: 8)
            legendRow(ZK.tier1, "4.5 以上")
            legendRow(ZK.tier2, "3.5 以上")
            legendRow(ZK.tier3, "評価が少ない")
        }
        .padding(12).glassPill(radius: 14)
    }

    private func legendRow(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(c).frame(width: 18, height: 3)
            Text(t).font(.system(size: 11)).foregroundStyle(ZK.body)
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchFocused = false
        // 読み込み済みの道名に一致すれば、その道へ
        if let hit = roads.first(where: { $0.name.localizedCaseInsensitiveContains(q) }), let c = GeoUtils.center(of: hit.coordinates) {
            withAnimation { position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))) }
            selected = hit
            return
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.5, longitude: 138), span: MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20))
        if let item = try? await MKLocalSearch(request: req).start().mapItems.first {
            withAnimation { position = .region(MKCoordinateRegion(center: item.placemark.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))) }
        }
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

/// 閲覧枠バッジ（縦積み: キャプション / 数値）
struct CreditBadge: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        VStack(spacing: 1) {
            CaptionLabel(text: "閲覧枠", size: 8)
            if app.profile?.plan == .subscriber {
                Image(systemName: "infinity").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(app.creditBalance)").font(.zkNumber(17)).foregroundStyle(.white)
            }
        }
        .frame(width: 56, height: 44).glassPill(radius: 14)
    }
}
