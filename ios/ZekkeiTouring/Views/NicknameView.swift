import SwiftUI

/// ニックネームの設定・変更。ログインは必要だが、表示は匿名で通せるようにする
struct NicknameView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { trimmed.count >= 2 && trimmed.count <= 20 }

    var body: some View {
        NavigationStack {
            ZStack {
                ZK.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        CaptionLabel(text: "NICKNAME")
                        Text("アプリでの表示名").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        Text("投稿や評価にはこの名前だけが表示されます。本名やアカウントは公開されません。")
                            .font(.system(size: 13)).lineSpacing(4).foregroundStyle(ZK.body)
                    }

                    HStack(spacing: 10) {
                        TextField("", text: $name, prompt: Text("例: 峠ねこ").foregroundStyle(ZK.caption))
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.done).focused($focused)
                            .onSubmit { Task { await save() } }
                        Text("\(trimmed.count)/20").font(.zkNumber(12)).foregroundStyle(trimmed.count > 20 ? ZK.danger : ZK.caption)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    .innerGroup(radius: 14)

                    Text("2〜20 文字。URL やアカウント名は使用できません。あとから変更できます。")
                        .font(.system(size: 11)).foregroundStyle(ZK.caption)

                    Button {
                        Task { await save() }
                    } label: {
                        Text(isSaving ? "保存中…" : "この名前にする")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid || isSaving)

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("あとで") { dismiss() }.foregroundStyle(ZK.caption)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let p = app.profile, p.displayNameSet == true { name = p.displayName }
            focused = true
        }
    }

    private func save() async {
        guard isValid, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        if await app.updateNickname(trimmed) { dismiss() }
    }
}
