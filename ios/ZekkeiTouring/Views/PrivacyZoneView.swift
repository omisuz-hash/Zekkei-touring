import SwiftUI

/// プライバシーゾーン（自宅など伏せたい場所）の設定。マイページと取り込み時の案内で共用する
struct PrivacyZoneCard: View {
    @EnvironmentObject private var app: AppState

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
                HStack {
                    Button("現在地を中心に設定") {
                        if let l = app.recorder.lastLocation?.coordinate {
                            app.privacyCenter = l
                        } else {
                            app.recorder.requestPermission()
                            app.lastError = "現在地をまだ取得できていません。少し待ってからもう一度お試しください。"
                        }
                    }
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(ZK.accent)
                    Spacer()
                    if app.privacyCenter != nil {
                        Button("解除") { app.privacyCenter = nil }.font(.system(size: 13)).foregroundStyle(ZK.errorText)
                    }
                }
                .padding(16)
            }
            .innerGroup(radius: 16)
            Text("この範囲内の走行軌跡は、切り出し時に自動で除外されます").font(.system(size: 12)).foregroundStyle(ZK.caption)
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
