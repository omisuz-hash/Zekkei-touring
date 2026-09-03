import SwiftUI
import MapKit

/// 走行記録（発車〜降車）
struct RecordView: View {
    @EnvironmentObject private var app: AppState
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var finishedRide: RideLog?

    private var recorder: RideRecorder { app.recorder }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $position) {
                    UserAnnotation()
                    if recorder.points.count > 1 {
                        MapPolyline(coordinates: recorder.points.map(\.coordinate)).stroke(.blue, lineWidth: 4)
                    }
                }
                .mapControls { MapUserLocationButton() }

                VStack(spacing: 12) {
                    HStack(spacing: 24) {
                        stat("距離", String(format: "%.1f km", recorder.distanceMeters / 1000))
                        stat("時間", timeText(recorder.elapsed))
                        stat("状態", stateText)
                    }
                    if recorder.authorization == .denied || recorder.authorization == .restricted {
                        Text("位置情報が許可されていません。設定アプリから許可してください。")
                            .font(.caption).foregroundStyle(.red)
                    } else if recorder.authorization == .authorizedWhenInUse {
                        Text("画面を閉じても記録を続けるには「常に許可」が必要です。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        if recorder.state == .idle {
                            recorder.requestPermission()
                            recorder.start()
                        } else {
                            if let ride = recorder.stop() {
                                app.store.save(ride)
                                finishedRide = ride
                            }
                        }
                    } label: {
                        Label(recorder.state == .idle ? "記録を開始" : "記録を終了", systemImage: recorder.state == .idle ? "record.circle" : "stop.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.state == .idle ? .orange : .red)
                    Text("記録は端末内に保存され、あなたが切り出した区間だけが公開されます。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("走行を記録")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $finishedRide) { ride in
                TrimView(ride: ride)
            }
        }
    }

    private var stateText: String {
        switch recorder.state {
        case .idle: return "停止中"
        case .recording: return "記録中"
        case .paused: return "一時停止"
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }
}

/// 端末内の走行記録一覧
struct RidesListView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            List {
                if app.store.rides.isEmpty {
                    Text("走行記録はまだありません。「記録」タブから走行を記録すると、ここから絶景道を切り出せます。")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.store.rides) { ride in
                    NavigationLink(value: ride) {
                        VStack(alignment: .leading) {
                            Text(ride.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(String(format: "%.1f km / %d 点 / 投稿 %d 件", ride.distanceMeters / 1000, ride.points.count, ride.publishedRoadIds.count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { app.store.rides[$0] }.forEach { app.store.delete($0) } }
            }
            .navigationTitle("走行記録")
            .navigationDestination(for: RideLog.self) { ride in TrimView(ride: ride) }
        }
    }
}
