import SwiftUI
import AuthenticationServices
import CryptoKit
import Security
import GoogleSignIn

/// ログイン。Google と Apple の両方を提供する（Apple 審査ガイドライン 4.8）
struct SignInView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var nonce = ""
    @State private var isBusy = false

    /// 規約への同意表記。リンクを含む 1 つの文にして、狭い画面でも自然に折り返す
    private static var termsNotice: AttributedString {
        var text = AttributedString("続けることで 利用規約 と プライバシーポリシー に同意したものとみなします")
        for (word, url) in [("利用規約", AppLinks.terms), ("プライバシーポリシー", AppLinks.privacy)] {
            if let range = text.range(of: word) {
                text[range].link = url
                text[range].foregroundColor = ZK.accent
            }
        }
        return text
    }

    var body: some View {
        ZStack {
            // 背景: 暗い地図調のグラデーション。絵はアプリのしるしに任せる
            LinearGradient(colors: [Color(hex: 0x1B2A20), ZK.mapBase, ZK.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            RadialGradient(colors: [ZK.accent.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.32), startRadius: 8, endRadius: 320).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 16)
                // アプリのしるし。iOS のホーム画面と同じ角丸で出す
                Image("AppMark")
                    .resizable().scaledToFill()
                    .frame(width: 148, height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 33, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 33, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
                    .accessibilityLabel("絶景道")
                Text("ZEKKEI-DO").font(.zkCaption(10)).tracking(2.2).foregroundStyle(ZK.accent)
                    .padding(.top, 22)
                Text("走って気持ちのいい道を、\nライダー同士で共有する道の口コミ地図")
                    .font(.system(size: 14)).lineSpacing(7).foregroundStyle(ZK.body)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                Text("収集するのは名前とメールアドレスのみです")
                    .font(.system(size: 11)).foregroundStyle(ZK.caption)
                    .padding(.top, 8)
                Spacer(minLength: 24)

                SignInWithAppleButton(.signIn) { request in
                    nonce = Self.randomNonce()
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Self.sha256(nonce)
                } onCompletion: { result in
                    Task { await handleApple(result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 12)

                Button {
                    Task { await signInWithGoogle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "g.circle.fill").font(.system(size: 18))
                        Text("Google でログイン").font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ZK.chipBorder, lineWidth: 1))
                }

                #if DEBUG
                // 開発ビルドのみ: Apple/Google の設定前でも動作確認できるゲストログイン
                Button("開発用: ゲストとして試す") {
                    Task {
                        do {
                            try await app.backend.signInAsGuest()
                            await app.refreshAccount()
                            dismiss()
                        } catch {
                            app.lastError = "ゲストログインに失敗しました。Supabase の Authentication → Sign In / Providers で「Anonymous sign-ins」を有効にしてください。\n" + error.localizedDescription
                        }
                    }
                }
                .font(.system(size: 12)).foregroundStyle(ZK.accent).frame(maxWidth: .infinity).padding(.top, 12)
                #endif
                // 横 1 行に収まらない端末があるため、折り返せる 1 つの文として組む
                Text(Self.termsNotice)
                    .font(.system(size: 11)).foregroundStyle(ZK.caption)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                if isBusy { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 10) }
            }
            .padding(.horizontal, 24).padding(.bottom, 32)
        }
        .preferredColorScheme(.dark)
    }

    private func signInWithGoogle() async {
        // クライアント ID が無いまま呼ぶと GoogleSignIn が異常終了するため、先に止める
        guard GIDSignIn.sharedInstance.configuration != nil else {
            app.lastError = "このビルドでは Google ログインを利用できません（クライアント ID が未設定です）。Apple でサインインをお使いください。"
            return
        }
        guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: root)
            guard let idToken = result.user.idToken?.tokenString else { throw BackendError.server("Google の ID トークンを取得できませんでした") }
            try await app.backend.signInWithGoogle(idToken: idToken, accessToken: result.user.accessToken.tokenString)
            await app.refreshAccount()
            dismiss()
        } catch {
            show(error)
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code != .canceled { app.lastError = e.localizedDescription }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken, let idToken = String(data: tokenData, encoding: .utf8) else {
                app.lastError = "Apple の ID トークンを取得できませんでした"
                return
            }
            isBusy = true
            defer { isBusy = false }
            do {
                try await app.backend.signInWithApple(idToken: idToken, nonce: nonce)
                await app.refreshAccount()
                dismiss()
            } catch {
                show(error)
            }
        }
    }

    /// 接続先の設定もれは英語のまま出ると原因が分からないため、言い換えて示す
    private func show(_ error: Error) {
        let m = error.localizedDescription
        if m.contains("is not enabled") {
            app.lastError = "ログイン方法がサーバー側で有効になっていません（Supabase の Authentication → Providers で有効化が必要です）。\n" + m
        } else {
            app.lastError = m
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
