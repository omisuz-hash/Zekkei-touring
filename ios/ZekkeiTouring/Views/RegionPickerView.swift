import SwiftUI

/// よく走る地域の設定。アプリを開いたときに最初に映す場所を決めるだけで、
/// 地図を動かせば地域をまたいで道を見られる
struct RegionPickerView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// 初回の案内として出すときは true
    var isOnboarding = false
    @State private var picked: Region = .kanto

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ZStack {
                ZK.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            CaptionLabel(text: "HOME REGION")
                            Text("よく走る地域").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                            Text("アプリを開いたときに、この地域の絶景道を先に表示します。地図を動かせば他の地域も見られます。あとから変更できます。")
                                .font(.system(size: 13)).lineSpacing(4).foregroundStyle(ZK.body)
                        }

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(Region.allCases) { r in
                                Button { picked = r } label: { card(r) }
                            }
                        }

                        Button {
                            app.homeRegion = picked
                            app.homeRegionChosen = true
                            dismiss()
                        } label: {
                            Text(isOnboarding ? "\(picked.name)から始める" : "この地域にする")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 4)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("")
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("閉じる") { dismiss() }.foregroundStyle(ZK.caption)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            app.suggestRegionFromLocation()
            picked = app.homeRegion
        }
    }

    private func card(_ r: Region) -> some View {
        let on = picked == r
        return VStack(alignment: .leading, spacing: 4) {
            Text(r.name).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            Text(r.prefectures.prefix(3).joined(separator: "・") + (r.prefectures.count > 3 ? " ほか" : ""))
                .font(.system(size: 10)).foregroundStyle(ZK.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(on ? ZK.tagBg : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? ZK.accent : ZK.chipBorder, lineWidth: on ? 1.4 : 1))
    }
}
