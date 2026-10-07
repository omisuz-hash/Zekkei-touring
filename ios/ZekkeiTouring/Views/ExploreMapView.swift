import SwiftUI
import MapKit

/// 探す: 衛星調ダーク地図に絶景道を重ねる
struct ExploreMapView: View {
    @EnvironmentObject private var app: AppState
    /// 初期位置は既定の地域。表示後は地図の移動に従う
    @State private var position: MapCameraPosition = .region(Region.stored.mapRegion)
    @State private var showRegionPicker = false
    /// 最初の 1 回は「その地域の代表的な 30 本」だけを出す（初見で見やすくするため）
    @State private var isFirstLoad = true
    @State private var roads: [ZekkeiRoad] = []
    /// 地図側の選択（ホバーや再読込で変わりうる）
    @State private var mapSelection: ZekkeiRoad?
    /// 詳細シートに出す道。開いている間は地図側の選択が変わっても保持する
    @State private var selected: ZekkeiRoad?
    @State private var isLoading = false
    @State private var lastCenter: CLLocationCoordinate2D?
    @State private var lastSpanLat: Double = 0
    @State private var currentRegion: MKCoordinateRegion?
    @State private var query = ""
    @State private var spanLat: Double = 1.5
    @State private var didSetInitialRegion = false
    @FocusState private var searchFocused: Bool

    /// 全部の道にタグを出す。目立つ道ほど後に描いて、重なったときに上に来るようにする
    private var taggedRoads: [ZekkeiRoad] {
        roads.sorted { $0.prominence < $1.prominence }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position, selection: $mapSelection) {
                UserAnnotation()
                ForEach(taggedRoads) { road in
                    let color = ZK.color(for: road)
                    let level = road.tagLevel
                    // 外側グロー → 本線 → 中央ハイライト（絶景度 4.5 以上）
                    if level >= 1 {
                        MapPolyline(coordinates: road.coordinates).stroke(color.opacity(0.35), lineWidth: level >= 2 ? 16 : 12)
                    }
                    MapPolyline(coordinates: road.coordinates).stroke(color, lineWidth: lineWidth(road))
                    if level >= 2 {
                        MapPolyline(coordinates: road.coordinates).stroke(Color.white.opacity(0.7), lineWidth: 1.2)
                    }
                }
                ForEach(taggedRoads) { road in
                    if let start = road.coordinates.first {
                        Annotation(road.name, coordinate: start, anchor: .bottomLeading) {
                            CodeTag(code: road.shortCode, fromVideo: road.isFromVideos, muted: road.displayScenery == nil, level: road.tagLevel)
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
                currentRegion = ctx.region
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

            // 左下: 凡例 / 右下: 拡大・縮小・現在地
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        regionChip
                        legend
                    }
                    Spacer()
                    VStack(spacing: 0) {
                        Button { zoom(by: 0.5) } label: {
                            Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 40)
                        }
                        Rectangle().fill(ZK.border).frame(width: 24, height: 1)
                        Button { zoom(by: 2) } label: {
                            Image(systemName: "minus").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 40)
                        }
                    }
                    .glassPill(radius: 14)
                    .padding(.trailing, 8)
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
        .onChange(of: mapSelection) { _, new in
            if let r = new, selected == nil { selected = r }
        }
        .sheet(item: $selected, onDismiss: { mapSelection = nil }) { road in
            RoadDetailView(road: road)
                .presentationDetents([.fraction(0.62), .large])
                .presentationBackground(Color(hex: 0x14181C).opacity(0.96))
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            app.recorder.requestPermission()
            // 保存値と食い違う場合だけ合わせる（通常は初期値のまま）
            if !didSetInitialRegion {
                didSetInitialRegion = true
                if app.homeRegion != Region.stored { position = .region(app.homeRegion.mapRegion) }
            }
        }
        .sheet(isPresented: $showRegionPicker, onDismiss: { resetToHomeRegion() }) {
            RegionPickerView(isOnboarding: !app.homeRegionChosen)
                .interactiveDismissDisabled(!app.homeRegionChosen)
        }
        .task {
            // 初回起動時は地域の選択を促す（現在地が取れていれば近い地域を初期値に）
            if !app.homeRegionChosen { showRegionPicker = true }
        }
    }

    /// 地域を選び直したら、その地域の代表的な 30 本に戻す
    private func resetToHomeRegion() {
        isFirstLoad = true
        lastCenter = nil
        lastSpanLat = 0
        withAnimation(.easeInOut(duration: 0.35)) { position = .region(app.homeRegion.mapRegion) }
    }

    /// 既定の地域を示すボタン。タップで変更できる
    private var regionChip: some View {
        Button { showRegionPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 11, weight: .semibold))
                Text(app.homeRegion.name).font(.system(size: 12, weight: .bold))
                if isFirstLoad { Text("代表の道").font(.system(size: 10)).foregroundStyle(ZK.caption) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 34)
            .glassPill(radius: 999)
        }
    }

    private func lineWidth(_ road: ZekkeiRoad) -> CGFloat {
        let base: CGFloat = road.tagLevel >= 2 ? 5 : (road.tagLevel == 1 ? 4 : 3)
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

    /// 拡大・縮小（factor < 1 で拡大、> 1 で縮小）。日本全体〜数 km の範囲に収める
    private func zoom(by factor: Double) {
        guard let r = currentRegion else { return }
        let lat = min(12, max(0.02, r.span.latitudeDelta * factor))
        let lng = min(12, max(0.02, r.span.longitudeDelta * factor))
        withAnimation(.easeInOut(duration: 0.25)) {
            position = .region(MKCoordinateRegion(center: r.center, span: MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lng)))
        }
    }

    private func load(center: CLLocationCoordinate2D, span: MKCoordinateSpan) async {
        // 中心が動いたとき、または縮尺が 2 割以上変わったときだけ読み直す
        let spanChanged = lastSpanLat == 0 || abs(span.latitudeDelta - lastSpanLat) / lastSpanLat > 0.2
        if let last = lastCenter, GeoUtils.distance(last, center) < 2000, !spanChanged { return }
        lastCenter = center
        lastSpanLat = span.latitudeDelta
        isLoading = true
        defer { isLoading = false }
        // 画面の対角線の半分ほどを取得半径に。上限は日本全体が入る 1,200 km
        let radius = max(15_000, min(1_200_000, span.latitudeDelta * 111_000 * 0.9))
        // 初回は既定の地域の代表的な 30 本だけ。以降は縮尺に応じて増やす
        // （日本全体＝ズーム 5 相当で 150 本、拡大するほど 2 次曲線で増やし、10 段階で 1,500 本）
        let limit: Int
        if isFirstLoad {
            limit = 30
            isFirstLoad = false
        } else {
            let zoom = log2(360 / max(span.longitudeDelta, 0.0001))
            let t = min(1, max(0, (zoom - 5) / 10))
            limit = Int(150 + 1350 * t * t)
        }
        do {
            roads = try await app.backend.nearbyRoads(center: center, radiusMeters: radius, limit: limit)
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
