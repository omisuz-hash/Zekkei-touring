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
        VStack(spacing: 20) {
            Image(systemName: "mountain.2.fill").font(.system(size: 48)).foregroundStyle(.orange)
            Text("絶景道").font(.largeTitle.bold())
            Text("ログインすると、絶景道の投稿と閲覧枠の利用ができます。\n収集するのは名前とメールアドレスのみです。")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)

            SignInWithAppleButton(.signIn) { request in
                nonce = Self.randomNonce()
                request.requestedScopes = [.fullName, .email]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                Task { await handleApple(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)

            Button {
                Task { await signInWithGoogle() }
            } label: {
                Label("Google でログイン", systemImage: "g.circle.fill")
                    .frame(maxWidth: .infinity).frame(height: 40)
            }
            .buttonStyle(.bordered)

            if app.isUsingMock {
                Button("テスト用: ログインしたことにする") {
                    Task {
                        try? await app.backend.signInWithGoogle(idToken: "mock", accessToken: nil)
                        await app.refreshAccount()
                        dismiss()
                    }
                }
                .font(.caption)
            }
            if isBusy { ProgressView() }
            Spacer()
        }
        .padding(24)
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
