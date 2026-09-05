import SwiftUI
import CoreLocation

/// マイページ
struct ProfileView: View {
    @EnvironmentObject private var app: AppState
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PROFILE").font(.zkCaption(9)).tracking(1.4).foregroundStyle(ZK.accent)
                        Text("マイページ").font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
                    }
                    .padding(.top, 8)

                    // アカウント
                    Button {
                        if !app.isSignedIn { showSignIn = true }
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(ZK.tagBg)
                                Circle().stroke(ZK.accent, lineWidth: 1.2)
                                Text(String((app.profile?.displayName ?? "？").prefix(1))).font(.system(size: 16, weight: .bold)).foregroundStyle(ZK.tier1)
                            }
                            .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.isSignedIn ? (app.profile?.displayName ?? "ライダー") : "ログイン").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                                Text(app.isSignedIn ? (app.profile?.plan == .subscriber ? "月額プラン" : "投稿コース") : "Apple または Google で").font(.system(size: 13)).foregroundStyle(ZK.caption)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(ZK.caption)
                        }
                        .padding(16).innerGroup(radius: 16)
                    }
                    if app.isUsingMock {
                        Text("接続先が未設定のため、テスト用データで動作しています。").font(.system(size: 11)).foregroundStyle(ZK.caption)
                    }

                    // 閲覧枠
                    CaptionLabel(text: "閲覧枠", size: 10)
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                CaptionLabel(text: "残り")
                                if app.profile?.plan == .subscriber {
                                    Image(systemName: "infinity").font(.system(size: 34, weight: .bold)).foregroundStyle(ZK.tier1)
                                } else {
                                    Text("\(app.creditBalance)").font(.zkNumber(40)).foregroundStyle(ZK.tier1)
                                }
                            }
                            Text("道の詳細を 1 本見るごとに 1 つ使います。絶景道を 1 本投稿すると 3 つ増えます。")
                                .font(.system(size: 12)).lineSpacing(5).foregroundStyle(ZK.body)
                        }
                        .padding(16)
                        Divider().overlay(ZK.divider)
                        HStack {
                            Text("月額プランを見る").font(.system(size: 15, weight: .bold)).foregroundStyle(ZK.accent)
                            Text("無制限 · 380 円/月").font(.system(size: 12)).foregroundStyle(ZK.caption)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(ZK.caption)
                        }
                        .padding(16)
                    }
                    .innerGroup(radius: 16)

                    // プライバシーゾーン
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
                                Text("\(Int(app.privacyRadiusMeters).formatted()) m").font(.zkNumber(15)).foregroundStyle(ZK.tier1)
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

                    // サポート（Apple 審査 1.2: 連絡先の公開、通報の説明）
                    CaptionLabel(text: "サポート", size: 10)
                    VStack(spacing: 0) {
                        linkRow("問い合わせ", url: URL(string: "mailto:support@example.com")!)
                        Divider().overlay(ZK.divider)
                        linkRow("利用規約・プライバシーポリシー", url: URL(string: "https://example.com/terms")!)
                        Divider().overlay(ZK.divider)
                        NavigationLink {
                            ScrollView {
                                Text("不適切な投稿は、各投稿の長押しメニューから通報できます。通報は 24 時間以内に確認します。迷惑な投稿者は同じメニューからブロックでき、以後その投稿者の内容は表示されません。")
                                    .font(.system(size: 14)).lineSpacing(6).foregroundStyle(ZK.body).padding(20)
                            }
                            .background(ZK.bg).navigationTitle("通報とブロックについて")
                        } label: {
                            HStack { Text("通報とブロックについて").font(.system(size: 15)).foregroundStyle(.white); Spacer(); Image(systemName: "chevron.right").foregroundStyle(ZK.caption) }
                                .padding(16)
                        }
                    }
                    .innerGroup(radius: 16)

                    if app.isSignedIn {
                        Button("ログアウト") { Task { await app.signOut() } }
                            .font(.system(size: 14)).foregroundStyle(ZK.errorText).frame(maxWidth: .infinity).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(ZK.bg)
            .navigationBarHidden(true)
            .sheet(isPresented: $showSignIn) { SignInView() }
            .refreshable { await app.refreshAccount() }
        }
        .preferredColorScheme(.dark)
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack { Text(title).font(.system(size: 15)).foregroundStyle(.white); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(ZK.caption) }
                .padding(16)
        }
    }
}
