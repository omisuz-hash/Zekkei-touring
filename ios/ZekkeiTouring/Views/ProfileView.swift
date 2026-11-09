import SwiftUI
import PhotosUI
import UIKit
import CoreLocation

/// マイページ
struct ProfileView: View {
    @State private var avatarItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @EnvironmentObject private var app: AppState
    @State private var navDetail: ZekkeiRoad.RouteDetail = .stored
    @State private var showSignIn = false
    @State private var showNickname = false
    @State private var showRegion = false
    @State private var showDeleteConfirm = false
    @State private var showRedeem = false
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
                            AvatarView(path: app.profile?.avatarUrl,
                                       name: app.profile?.displayName ?? "？", size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.isSignedIn ? (app.profile?.displayName ?? "ライダー") : "ログイン").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                                Text(planCaption).font(.system(size: 13)).foregroundStyle(ZK.caption)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(ZK.caption)
                        }
                        .padding(16).innerGroup(radius: 16)
                    }
                    if app.isSignedIn {
                        // 多くの人は自分のバイクの写真を目印にする
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            HStack(spacing: 10) {
                                AvatarView(path: app.profile?.avatarUrl,
                                           name: app.profile?.displayName ?? "？", size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("アイコン").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                    Text(avatarNote).font(.system(size: 12)).foregroundStyle(ZK.caption)
                                }
                                Spacer()
                                if isUploadingAvatar { ProgressView().tint(.white).scaleEffect(0.7) }
                                else { Image(systemName: "chevron.right").foregroundStyle(ZK.caption) }
                            }
                            .padding(14).innerGroup(radius: 14)
                        }
                        .disabled(isUploadingAvatar)
                        .onChange(of: avatarItem) { _, item in
                            guard let item else { return }
                            Task { await uploadAvatar(item) }
                        }
                        if app.profile?.avatarUrl?.isEmpty == false {
                            Button("アイコンを外す") { Task { await clearAvatar() } }
                                .font(.system(size: 12)).foregroundStyle(ZK.errorText)
                        }
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
                    // Google マップは経由地を「立ち寄り先」として扱い、着くたびに案内が
                    // いったん終わる。音声だけを頼りに走る人のために数を選べるようにする
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond").font(.system(size: 14)).foregroundStyle(ZK.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("ナビに渡す経由地").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                Text(navDetail.note).font(.system(size: 12)).foregroundStyle(ZK.caption)
                            }
                            Spacer(minLength: 0)
                        }
                        Picker("", selection: $navDetail) {
                            ForEach(ZekkeiRoad.RouteDetail.allCases) { d in
                                Text(d.title).tag(d)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: navDetail) { _, v in ZekkeiRoad.RouteDetail.stored = v }
                    }
                    .padding(14).innerGroup(radius: 14)
                    if app.isUsingMock {
                        Text("接続先が未設定のため、テスト用データで動作しています。").font(.system(size: 11)).foregroundStyle(ZK.caption)
                    }

                    // 閲覧枠
                    CaptionLabel(text: "閲覧枠", size: 10)
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                CaptionLabel(text: "残り")
                                if app.profile?.hasUnlimitedViewing == true {
                                    Image(systemName: "infinity").font(.system(size: 34, weight: .bold)).foregroundStyle(ZK.highlight)
                                } else {
                                    Text("\(app.creditBalance)").font(.zkNumber(40)).foregroundStyle(ZK.highlight)
                                }
                            }
                            Text(creditNote)
                                .font(.system(size: 12)).lineSpacing(5).foregroundStyle(ZK.body)
                        }
                        .padding(16)
                        Divider().overlay(ZK.divider)
                        // 月額プランはベータ公開の後。押せそうに見せない
                        HStack {
                            Text("月額プラン").font(.system(size: 15, weight: .bold)).foregroundStyle(ZK.disabled)
                            Text("無制限 · 380 円/月（予定）").font(.system(size: 12)).foregroundStyle(ZK.caption)
                            Spacer()
                            Text("準備中").font(.system(size: 11, weight: .semibold)).foregroundStyle(ZK.caption)
                        }
                        .padding(16)
                        Divider().overlay(ZK.divider)
                        Button { if app.isSignedIn { showRedeem = true } else { showSignIn = true } } label: {
                            HStack {
                                Text("招待コードを使う").font(.system(size: 15)).foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(ZK.caption)
                            }
                            .padding(16)
                        }
                    }
                    .innerGroup(radius: 16)

                    PrivacyZoneCard()

                    // サポート（Apple 審査 1.2: 連絡先の公開、通報の説明）
                    CaptionLabel(text: "サポート", size: 10)
                    VStack(spacing: 0) {
                        linkRow("問い合わせ", url: AppLinks.support)
                        Divider().overlay(ZK.divider)
                        linkRow("利用規約・プライバシーポリシー", url: AppLinks.terms)
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
            .sheet(isPresented: $showRedeem) { RedeemCodeView().environmentObject(app) }
            // 走行記録は端末にしか無く、ログインしていなくても使える。
            // アカウントを消したときに道連れにするかは、利用者に選ばせる
            .confirmationDialog("アカウントを削除しますか", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("アカウントだけ削除（走行記録は端末に残す）", role: .destructive) {
                    deleteAccount(alsoLocalRides: false)
                }
                Button("アカウントと、この端末の走行記録を削除", role: .destructive) {
                    deleteAccount(alsoLocalRides: true)
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("サーバー側のプロフィール・評価・投稿した写真・閲覧枠を削除します。"
                     + "公開済みの絶景道そのものは、他の方が見られる状態のまま残り、あなたとの結び付けだけが外れます。"
                     + "この操作は取り消せません。\n\n"
                     + "走行記録 \(app.store.rides.count) 件はこの端末にだけ保存されています。"
                     + "端末を手放す予定があるときは、合わせて削除してください。")
            }
            .refreshable { await app.refreshAccount() }
        }
        .preferredColorScheme(.dark)
    }

    private func deleteAccount(alsoLocalRides: Bool) {
        isDeleting = true
        Task {
            _ = await app.deleteAccount(alsoLocalRides: alsoLocalRides)
            isDeleting = false
        }
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack { Text(title).font(.system(size: 15)).foregroundStyle(.white); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(ZK.caption) }
                .padding(16)
        }
    }
}

extension ProfileView {
    /// アカウント欄の肩書き
    var planCaption: String {
        guard app.isSignedIn else { return "Apple または Google で" }
        if app.profile?.plan == .subscriber { return "月額プラン" }
        if let until = app.profile?.subscriberUntil, until > Date() {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "y年M月d日"
            return "無料期間中 · \(f.string(from: until)) まで"
        }
        return "投稿コース"
    }

    /// 閲覧枠の説明
    var creditNote: String {
        if app.profile?.plan == .subscriber { return "月額プランのため、枠を使わずに全ての詳細を見られます。" }
        if let until = app.profile?.subscriberUntil, until > Date() {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "y年M月d日"
            return "招待コードの無料期間中です。\(f.string(from: until)) までは枠を使わずに見られます。"
        }
        return "道の詳細を 1 本見るごとに 1 つ使います。絶景道を 1 本投稿すると 3 つ増えます。"
    }

    var avatarNote: String {
        app.profile?.avatarUrl?.isEmpty == false ? "写真を選び直せます" : "自分のバイクの写真などを目印に"
    }

    func uploadAvatar(_ item: PhotosPickerItem) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false; avatarItem = nil }
        guard let uid = app.backend.currentUserId else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let jpeg = Self.squareJPEG(from: data, side: 512) else {
                app.lastError = "写真を読み込めませんでした。別の写真をお試しください。"
                return
            }
            let path = "\(uid.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
            try await app.backend.uploadMedia(data: jpeg, bucket: "avatars", path: path, contentType: "image/jpeg")
            try await app.backend.setAvatarPath(path)
            await app.refreshAccount()
        } catch {
            app.lastError = error.localizedDescription
        }
    }

    /// アイコン用に中央を正方形に切り、一辺 side 画素の JPEG にする。
    /// iPhone の写真はそのままだと数 MB あり、形式も HEIC のことが多いため、必ず変換してから送る
    static func squareJPEG(from data: Data, side: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let edge = min(w, h)
        let scale = side / edge
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: -(w - edge) / 2 * scale, y: -(h - edge) / 2 * scale,
                                  width: w * scale, height: h * scale))
        }
        return out.jpegData(compressionQuality: 0.85)
    }

    func clearAvatar() async {
        do {
            try await app.backend.setAvatarPath(nil)
            await app.refreshAccount()
        } catch {
            app.lastError = error.localizedDescription
        }
    }
}

/// 利用者のアイコン。未設定ならニックネームの頭文字を出す
struct AvatarView: View {
    @EnvironmentObject private var app: AppState
    let path: String?
    let name: String
    var size: CGFloat = 56

    private var url: URL? {
        guard let path, !path.isEmpty else { return nil }
        return app.backend.publicURL(bucket: "avatars", path: path)
    }

    var body: some View {
        ZStack {
            Circle().fill(ZK.tagBg)
            Circle().stroke(ZK.accent, lineWidth: 1.2)
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Text(initial).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(ZK.highlight)
                    }
                }
                .frame(width: size, height: size).clipShape(Circle())
            } else {
                Text(initial).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(ZK.highlight)
            }
        }
        .frame(width: size, height: size)
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1))
    }
}
