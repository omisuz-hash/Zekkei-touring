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

    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景: 暗い地図調のグラデーションと、光る 1 本の絶景道
            LinearGradient(colors: [Color(hex: 0x1B2A20), ZK.mapBase, ZK.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            GlowRoad().ignoresSafeArea()
            LinearGradient(colors: [.clear, ZK.bg.opacity(0.9), ZK.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZK.primaryButtonText)
                        RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ZK.accent, lineWidth: 1.2)
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 24, weight: .bold)).foregroundStyle(ZK.tier1)
                    }
                    .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ZEKKEI-DO").font(.zkCaption(9)).tracking(1.5).foregroundStyle(ZK.accent)
                        Text("絶景道").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                    }
                }
                Text("走って気持ちのいい道を、\nライダー同士で共有する道の口コミ地図")
                    .font(.system(size: 14)).lineSpacing(7).foregroundStyle(ZK.body)
                Text("収集するのは名前とメールアドレスのみです").font(.system(size: 11)).foregroundStyle(ZK.caption)

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

                if app.isUsingMock {
                    Button("テスト用: ログインしたことにする") {
                        Task {
                            try? await app.backend.signInWithGoogle(idToken: "mock", accessToken: nil)
                            await app.refreshAccount()
                            dismiss()
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(ZK.accent)
                }
                HStack(spacing: 0) {
                    Text("続けることで ").foregroundStyle(ZK.caption)
                    Link("利用規約", destination: URL(string: "https://example.com/terms")!).foregroundStyle(ZK.accent)
                    Text(" と ").foregroundStyle(ZK.caption)
                    Link("プライバシーポリシー", destination: URL(string: "https://example.com/privacy")!).foregroundStyle(ZK.accent)
                    Text(" に同意したものとみなします").foregroundStyle(ZK.caption)
                }
                .font(.system(size: 11)).frame(maxWidth: .infinity)
                if isBusy { ProgressView().tint(.white).frame(maxWidth: .infinity) }
            }
            .padding(.horizontal, 24).padding(.bottom, 32)
        }
        .preferredColorScheme(.dark)
    }

    private func signInWithGoogle() async {
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
            app.lastError = error.localizedDescription
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
                app.lastError = error.localizedDescription
            }
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

/// 背景の光る道
struct GlowRoad: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: -20, y: size.height * 0.5))
            p.addCurve(to: CGPoint(x: size.width * 0.55, y: size.height * 0.33),
                       control1: CGPoint(x: size.width * 0.2, y: size.height * 0.5),
                       control2: CGPoint(x: size.width * 0.35, y: size.height * 0.3))
            p.addCurve(to: CGPoint(x: size.width + 20, y: size.height * 0.15),
                       control1: CGPoint(x: size.width * 0.75, y: size.height * 0.36),
                       control2: CGPoint(x: size.width * 0.9, y: size.height * 0.2))
            ctx.stroke(p, with: .color(ZK.tier1.opacity(0.35)), style: StrokeStyle(lineWidth: 18, lineCap: .round))
            ctx.stroke(p, with: .color(ZK.tier1), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
    }
}
