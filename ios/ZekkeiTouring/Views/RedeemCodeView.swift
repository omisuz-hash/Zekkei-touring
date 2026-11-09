import SwiftUI

/// 招待コードを使う。
/// 動画でこのアプリのデータの元になった道を紹介してくれた方へのお礼と、
/// その方からの紹介で入ってきた方の受け入れに使う
struct RedeemCodeView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isBusy = false
    @State private var result: RedeemResult?

    private var cleaned: String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("お持ちの招待コードを入力してください。")
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(ZK.body)

                    TextField("", text: $code, prompt: Text("例: ZDAB23CD").foregroundStyle(ZK.disabled))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 14)
                        .innerGroup(radius: 14)

                    if let r = result {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: r.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.ok ? ZK.highlight : ZK.errorText)
                            Text(r.message).font(.system(size: 13)).lineSpacing(4)
                                .foregroundStyle(r.ok ? ZK.body : ZK.errorText)
                        }
                        .padding(14).innerGroup(radius: 12, thin: true)
                    }

                    Button {
                        Task { await redeem() }
                    } label: {
                        HStack(spacing: 8) {
                            if isBusy { ProgressView().tint(ZK.primaryButtonText) }
                            Text("使う")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 54, radius: 16, font: .system(size: 17, weight: .bold)))
                    .disabled(cleaned.count < 4 || isBusy)

                    Text("コードには使用回数と有効期限があります。期限を過ぎたものや、上限に達したものは使えません。")
                        .font(.system(size: 11)).lineSpacing(4).foregroundStyle(ZK.caption)
                }
                .padding(20)
            }
            .background(ZK.bg)
            .navigationTitle("招待コード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(result?.ok == true ? "閉じる" : "キャンセル") { dismiss() }.foregroundStyle(ZK.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func redeem() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let r = try await app.backend.redeemCode(cleaned)
            result = r
            if r.ok { await app.refreshAccount() }
        } catch {
            app.lastError = error.localizedDescription
        }
    }
}
