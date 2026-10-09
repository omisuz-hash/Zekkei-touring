import SwiftUI
import CoreLocation

/// マイページ
struct ProfileView: View {
    @EnvironmentObject private var app: AppState
    @State private var showSignIn = false
    @State private var showNickname = false
    @State private var showRegion = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

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
                                Text(String((app.profile?.displayName ?? "？").prefix(1))).font(.system(size: 16, weight: .bold)).foregroundStyle(ZK.highlight)
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
                    if app.isSignedIn {
                        Button { showNickname = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.text.rectangle").font(.system(size: 14)).foregroundStyle(ZK.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ニックネーム").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                    Text(app.profile?.needsNickname == true ? "未設定（仮の名前で表示中）" : (app.profile?.displayName ?? ""))
                                        .font(.system(size: 12)).foregroundStyle(app.profile?.needsNickname == true ? ZK.accent : ZK.caption)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(ZK.caption)
                            }
                            .padding(14).innerGroup(radius: 14)
                        }
                        Text("投稿に表示されるのはニックネームだけです。本名やメールアドレスは公開されません。")
                            .font(.system(size: 11)).foregroundStyle(ZK.caption)
                    }
                    Button { showRegion = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "map").font(.system(size: 14)).foregroundStyle(ZK.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("よく走る地域").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                Text("\(app.homeRegion.name)（アプリを開いたときの表示）").font(.system(size: 12)).foregroundStyle(ZK.caption)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(ZK.caption)
                        }
                        .padding(14).innerGroup(radius: 14)
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
                                    Image(systemName: "infinity").font(.system(size: 34, weight: .bold)).foregroundStyle(ZK.highlight)
                                } else {
                                    Text("\(app.creditBalance)").font(.zkNumber(40)).foregroundStyle(ZK.highlight)
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

                    PrivacyZoneCard()

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
                        Button(isDeleting ? "削除中…" : "アカウントを削除") { showDeleteConfirm = true }
                            .font(.system(size: 13)).foregroundStyle(ZK.caption).frame(maxWidth: .infinity).padding(.top, 4)
                            .disabled(isDeleting)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(ZK.bg)
            .navigationBarHidden(true)
            .sheet(isPresented: $showSignIn) { SignInView() }
            .sheet(isPresented: $showNickname) { NicknameView() }
            .sheet(isPresented: $showRegion) { RegionPickerView() }
            .alert("アカウントを削除しますか", isPresented: $showDeleteConfirm) {
                Button("削除する", role: .destructive) {
                    isDeleting = true
                    Task { _ = await app.deleteAccount(); isDeleting = false }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("プロフィール・走行記録・評価・投稿した写真・閲覧枠を削除します。公開済みの絶景道そのものは、他の方が見られる状態のまま残り、あなたとの結び付けだけが外れます。この操作は取り消せません。")
            }
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
