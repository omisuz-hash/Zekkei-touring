import SwiftUI
import MapKit

/// 記録（屋外・グローブ操作）
struct RecordView: View {
    @EnvironmentObject private var app: AppState
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var finishedRide: RideLog?
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var recorder: RideRecorder { app.recorder }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Map(position: $position) {
                    UserAnnotation()
                    if recorder.points.count > 1 {
                        MapPolyline(coordinates: recorder.points.map(\.coordinate)).stroke(ZK.tier1.opacity(0.35), lineWidth: 12)
                        MapPolyline(coordinates: recorder.points.map(\.coordinate)).stroke(ZK.tier1, lineWidth: 4)
                    }
                }
                .mapStyle(.hybrid(elevation: .realistic))
                .mapControls { MapUserLocationButton(); MapCompass() }
                .ignoresSafeArea()

                // GPS 状態ピル
                Text(recorder.lastLocation == nil ? "GPS を待機中" : "GPS 良好 · 現在地を追従中")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 36).glassPill(radius: 999)
                    .padding(.top, 8)

                VStack {
                    Spacer()
                    card.padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(item: $finishedRide) { ride in TrimView(ride: ride) }
            .onReceive(timer) { tick = $0 }
        }
        .preferredColorScheme(.dark)
    }

    private var card: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                StatTile(caption: "距離", value: String(format: "%.1f", recorder.distanceMeters / 1000), unit: "km", valueSize: 30)
                StatTile(caption: "時間", value: timeText(recorder.state == .idle ? 0 : recorder.elapsed), valueSize: 30)
                VStack(alignment: .leading, spacing: 4) {
                    CaptionLabel(text: "状態")
                    HStack(spacing: 6) {
                        StatusDot(color: stateColor, pulse: recorder.state == .recording).id(recorder.state)
                        Text(stateText).font(.system(size: 16, weight: .bold)).foregroundStyle(stateColor)
                    }
                    .frame(height: 36)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .innerGroup(radius: 12, thin: true)
            }
            if recorder.state == .idle {
                Button("記録を開始") {
                    recorder.requestPermission()
                    recorder.start()
                }
                .buttonStyle(PrimaryButtonStyle(height: 76, radius: 18, font: .system(size: 22, weight: .bold)))
            } else {
                Button("記録を終了") {
                    if let ride = recorder.stop() {
                        app.store.save(ride)
                        finishedRide = ride
                    }
                }
                .buttonStyle(DangerButtonStyle(height: 76, radius: 18, font: .system(size: 22, weight: .bold)))
            }
            Text("記録は端末内に保存され、あなたが切り出した区間だけが公開されます")
                .font(.system(size: 11)).foregroundStyle(ZK.caption).multilineTextAlignment(.center)
            if recorder.authorization == .authorizedWhenInUse || recorder.authorization == .denied {
                HStack(spacing: 4) {
                    Text(recorder.authorization == .denied ? "位置情報が許可されていません。" : "画面を閉じても記録を続けるには、位置情報の「常に許可」が必要です。")
                        .font(.system(size: 12)).foregroundStyle(ZK.body)
                    Button("設定を開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(ZK.tier1)
                }
                .padding(12)
                .background(ZK.tagBg).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZK.accent.opacity(0.4), lineWidth: 1))
            }
        }
        .glassCard(radius: 22, padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
    }

    private var stateText: String {
        switch recorder.state {
        case .idle: return "停止中"
        case .recording: return "記録中"
        case .paused: return "一時停止"
        }
    }
    private var stateColor: Color {
        switch recorder.state {
        case .idle: return ZK.caption
        case .recording: return ZK.tier1
        case .paused: return ZK.paused
        }
    }
    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 走行記録一覧
struct RidesListView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("RIDES").font(.zkCaption(9)).tracking(1.4).foregroundStyle(ZK.accent)
                            Text("走行記録").font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
                        }
                        Spacer()
                        Text(String(format: "%d 件 · %.1f km", app.store.rides.count, app.store.rides.reduce(0) { $0 + $1.distanceMeters } / 1000))
                            .font(.system(size: 11)).foregroundStyle(ZK.caption)
                    }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                }
                if app.store.rides.isEmpty {
                    Text("走行記録はまだありません。「記録」タブから走行を記録すると、ここから絶景道を切り出せます。")
                        .font(.system(size: 13)).foregroundStyle(ZK.caption).listRowBackground(Color.clear)
                }
                ForEach(app.store.rides) { ride in
                    NavigationLink(value: ride) { RideRow(ride: ride) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowSeparator(.hidden)
                }
                .onDelete { idx in idx.map { app.store.rides[$0] }.forEach { app.store.delete($0) } }
                if !app.store.rides.isEmpty {
                    Text("左にスワイプで削除").font(.system(size: 12)).foregroundStyle(ZK.disabled).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ZK.bg)
            .navigationBarHidden(true)
            .navigationDestination(for: RideLog.self) { ride in TrimView(ride: ride) }
        }
        .preferredColorScheme(.dark)
    }
}

/// 走行記録の行（軌跡のスケッチ・日付・距離・投稿状況）
struct RideRow: View {
    let ride: RideLog
    var body: some View {
        HStack(spacing: 12) {
            TrackSketch(coordinates: ride.coordinates, color: ride.publishedRoadIds.isEmpty ? ZK.tier3 : ZK.tier1)
                .frame(width: 56, height: 56)
                .background(Color(hex: 0x171C1A)).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ride.startedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    Text(ride.startedAt.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))).font(.system(size: 11)).foregroundStyle(ZK.caption)
                }
                Text(String(format: "%.1f km · %@", ride.distanceMeters / 1000, durationText(ride.duration))).font(.system(size: 12)).foregroundStyle(ZK.caption)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ride.publishedRoadIds.isEmpty ? "—" : "✓").font(.system(size: 18, weight: .bold)).foregroundStyle(ride.publishedRoadIds.isEmpty ? ZK.caption : ZK.tier1)
                Text(ride.publishedRoadIds.isEmpty ? "未投稿" : "投稿 \(ride.publishedRoadIds.count)").font(.system(size: 10)).foregroundStyle(ZK.caption)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .innerGroup(radius: 16)
    }
    private func durationText(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }
}

/// 軌跡を小さく描く
struct TrackSketch: View {
    let coordinates: [CLLocationCoordinate2D]
    var color: Color = ZK.tier1
    var body: some View {
        Canvas { ctx, size in
            guard coordinates.count > 1 else { return }
            let lats = coordinates.map(\.latitude), lngs = coordinates.map(\.longitude)
            guard let minLat = lats.min(), let maxLat = lats.max(), let minLng = lngs.min(), let maxLng = lngs.max() else { return }
            let pad: CGFloat = 8
            let w = size.width - pad * 2, h = size.height - pad * 2
            let sx = maxLng > minLng ? w / CGFloat(maxLng - minLng) : 1
            let sy = maxLat > minLat ? h / CGFloat(maxLat - minLat) : 1
            let s = min(sx, sy)
            let drawW = CGFloat(maxLng - minLng) * s, drawH = CGFloat(maxLat - minLat) * s
            let ox = pad + (w - drawW) / 2, oy = pad + (h - drawH) / 2
            var path = Path()
            let step = max(1, coordinates.count / 60)
            for (i, c) in coordinates.enumerated() where i % step == 0 || i == coordinates.count - 1 {
                let p = CGPoint(x: ox + CGFloat(c.longitude - minLng) * s, y: oy + drawH - CGFloat(c.latitude - minLat) * s)
                if path.isEmpty { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}
