import SwiftUI
import MapKit
import CoreLocation

/// プライバシーゾーン（自宅など伏せたい場所）の設定。マイページと取り込み時の案内で共用する
struct PrivacyZoneCard: View {
    @AppStorage(MapLook.key) private var mapLookRaw = MapLook.hybrid.rawValue
    private var mapLook: MapLook { MapLook(rawValue: mapLookRaw) ?? .hybrid }

    @EnvironmentObject private var app: AppState
    @State private var isLocating = false
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionLabel(text: "プライバシーゾーン", size: 10)
            VStack(spacing: 0) {
                HStack {
                    Text("中心").font(.system(size: 15)).foregroundStyle(.white)
                    Spacer()
                    Text(app.privacyCenter == nil ? "未設定" : "自宅（設定済み）").font(.system(size: 15)).foregroundStyle(ZK.caption)
                }
                .padding(16)
                Divider().overlay(ZK.divider)
                VStack(spacing: 8) {
                    HStack {
                        Text("半径").font(.system(size: 15)).foregroundStyle(.white)
                        Spacer()
                        Text("\(Int(app.privacyRadiusMeters).formatted()) m").font(.zkNumber(15)).foregroundStyle(ZK.highlight)
                    }
                    Slider(value: $app.privacyRadiusMeters, in: 300...3000, step: 100).tint(.white)
                    HStack {
                        Text("300 m").font(.system(size: 11)).foregroundStyle(ZK.caption)
                        Spacer()
                        Text("3,000 m").font(.system(size: 11)).foregroundStyle(ZK.caption)
                    }
                }
                .padding(16)
                Divider().overlay(ZK.divider)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button(isLocating ? "取得中…" : "現在地を中心に設定") { setFromCurrentLocation() }
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(isLocating ? ZK.caption : ZK.accent)
                            .disabled(isLocating)
                        if isLocating { ProgressView().tint(.white).scaleEffect(0.7) }
                        Spacer()
                        if app.privacyCenter != nil {
                            Button("解除") { app.privacyCenter = nil }.font(.system(size: 13)).foregroundStyle(ZK.errorText)
                        }
                    }
                    // 自宅から離れた場所にいても設定できるようにする
                    Button { showPicker = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "map").font(.system(size: 13))
                            Text("地図から選ぶ").font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(ZK.accent)
                    }
                }
                .padding(16)
            }
            .innerGroup(radius: 16)
            Text("この範囲内の走行軌跡は、切り出し時に自動で除外されます").font(.system(size: 12)).foregroundStyle(ZK.caption)
        }
        .sheet(isPresented: $showPicker) {
            PrivacyZonePickerView(start: app.privacyCenter ?? app.recorder.lastLocation?.coordinate ?? Region.stored.center)
                .environmentObject(app)
        }
    }

    /// 走行を記録していないときは位置が流れてこないため、1 度だけ取りに行く
    private func setFromCurrentLocation() {
        isLocating = true
        Task {
            let fix = await app.recorder.currentLocation()
            isLocating = false
            switch fix {
            case .success(let l):
                app.privacyCenter = l.coordinate
            case .needsPermission:
                app.lastError = "位置情報の利用を許可してから、もう一度お試しください。"
            case .denied:
                app.lastError = "位置情報の利用が許可されていません。iPhone の「設定」→「絶景道」→「位置情報」から許可してください。"
            case .timedOut:
                app.lastError = "現在地を取得できませんでした。屋外や窓際で、もう一度お試しください。"
            }
        }
    }
}

/// 取り込み後などに単独で出す設定画面
struct PrivacyZoneSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ZK.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            CaptionLabel(text: "PRIVACY")
                            Text("自宅の周辺を伏せる").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                            Text("走行の記録には自宅の出発・到着が含まれます。中心と半径を決めておくと、その範囲の軌跡は区間の切り出し時に自動で除かれ、公開されません。設定は端末内にのみ保存されます。")
                                .font(.system(size: 13)).lineSpacing(4).foregroundStyle(ZK.body)
                        }
                        PrivacyZoneCard()
                        Button { dismiss() } label: { Text(app.privacyCenter == nil ? "設定せずに進む" : "完了") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(20)
                }
            }
            .navigationTitle("")
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

/// 未設定のときだけ出す注意書き
struct PrivacyZoneNotice: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "house.slash").font(.system(size: 15)).foregroundStyle(ZK.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("自宅の周辺を伏せる設定が未設定です").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Text("設定しておくと、切り出し時にその範囲が自動で除かれます").font(.system(size: 11)).foregroundStyle(ZK.caption)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(ZK.caption)
            }
            .padding(14)
            .background(ZK.tagBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ZK.accent.opacity(0.6), lineWidth: 1))
        }
    }
}


/// 地図を動かして、伏せたい場所の中心を決める。自宅から離れていても設定できる
struct PrivacyZonePickerView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var radius: Double = 1000

    init(start: CLLocationCoordinate2D) {
        _center = State(initialValue: start)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: start, span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04))))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                MapCircle(center: center, radius: radius)
                    .foregroundStyle(Color.white.opacity(0.12))
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .zkMapStyle(mapLook, elevation: .flat)
            .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
            .ignoresSafeArea()

            // 画面の中心が、選んでいる地点
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .thin)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            HStack {
                Button("キャンセル") { dismiss() }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40).glassPill(radius: 999)
                Spacer()
                Text("地図を動かして中心を合わせる")
                    .font(.system(size: 12)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 40).glassPill(radius: 999)
            }
            .padding(.horizontal, 12).padding(.top, 10)

            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("半径").font(.system(size: 14)).foregroundStyle(.white)
                        Spacer()
                        Text("\(Int(radius).formatted()) m").font(.zkNumber(15)).foregroundStyle(ZK.highlight)
                    }
                    Slider(value: $radius, in: 300...3000, step: 100).tint(.white)
                    Button("ここを中心にする") {
                        app.privacyCenter = center
                        app.privacyRadiusMeters = radius
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .glassCard(radius: 22, padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .onAppear { radius = app.privacyRadiusMeters }
        .preferredColorScheme(.dark)
    }
}
