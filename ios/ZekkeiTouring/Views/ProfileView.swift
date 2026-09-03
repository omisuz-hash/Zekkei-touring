import SwiftUI
import CoreLocation

/// マイページ。ログイン、プラン、閲覧枠、プライバシーゾーン、連絡先
struct ProfileView: View {
    @EnvironmentObject private var app: AppState
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            List {
                Section("アカウント") {
                    if app.isSignedIn {
                        LabeledContent("名前", value: app.profile?.displayName ?? "")
                        LabeledContent("コース", value: app.profile?.plan == .subscriber ? "月額プラン（閲覧無制限）" : "投稿コース")
                        Button("ログアウト", role: .destructive) { Task { await app.signOut() } }
                    } else {
                        Button("ログイン") { showSignIn = true }
                    }
                    if app.isUsingMock {
                        Text("接続先が未設定のため、テスト用データで動作しています。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("閲覧枠") {
                    if app.profile?.plan == .subscriber {
                        Label("閲覧無制限", systemImage: "infinity")
                    } else {
                        LabeledContent("残り", value: "\(app.creditBalance) 件")
                        Text("毎月 3 件の無料枠に加え、絶景道を 1 件投稿するごとに 3 件が加わります（月末まで有効）。")
                            .font(.caption).foregroundStyle(.secondary)
                        // 課金（StoreKit 2 / RevenueCat）は公開フェーズで実装する
                        Button("月額プランを見る（準備中）") {}
                            .disabled(true)
                    }
                }

                Section("プライバシーゾーン") {
                    Text("自宅などの周辺を設定すると、走行記録からの切り出し時にその範囲が自動で除外されます。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let c = app.privacyCenter {
                        LabeledContent("中心", value: String(format: "%.4f, %.4f", c.latitude, c.longitude))
                    } else {
                        Text("未設定").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("半径")
                        Slider(value: $app.privacyRadiusMeters, in: 300...3000, step: 100)
                        Text("\(Int(app.privacyRadiusMeters)) m").frame(width: 64, alignment: .trailing)
                    }
                    Button("現在地を中心に設定") {
                        if let l = app.recorder.lastLocation?.coordinate {
                            app.privacyCenter = l
                        } else {
                            app.recorder.requestPermission()
                            app.lastError = "現在地をまだ取得できていません。少し待ってからもう一度お試しください。"
                        }
                    }
                    if app.privacyCenter != nil {
                        Button("解除", role: .destructive) { app.privacyCenter = nil }
                    }
                }

                Section("サポート") {
                    Link("お問い合わせ", destination: URL(string: "mailto:support@example.com")!)
                    Link("利用規約・プライバシーポリシー", destination: URL(string: "https://example.com/terms")!)
                    Text("不適切な投稿は各投稿のメニューから通報できます。24 時間以内に確認します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("マイページ")
            .sheet(isPresented: $showSignIn) { SignInView() }
            .refreshable { await app.refreshAccount() }
        }
    }
}
