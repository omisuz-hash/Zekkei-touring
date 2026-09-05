import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var app: AppState

    init() {
        // タブバー: 半透明ダーク（デザイン v2）
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundColor = UIColor(red: 14 / 255, green: 17 / 255, blue: 20 / 255, alpha: 0.9)
        tab.shadowColor = UIColor.white.withAlphaComponent(0.06)
        let inactive = UIColor(red: 110 / 255, green: 124 / 255, blue: 133 / 255, alpha: 1)
        tab.stackedLayoutAppearance.normal.iconColor = inactive
        tab.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: inactive, .font: UIFont.systemFont(ofSize: 10, weight: .medium)]
        tab.stackedLayoutAppearance.selected.iconColor = .white
        tab.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 10, weight: .medium)]
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = UIColor(red: 11 / 255, green: 14 / 255, blue: 17 / 255, alpha: 0.9)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some View {
        TabView {
            ExploreMapView()
                .tabItem { Label("探す", systemImage: "map") }
            RecordView()
                .tabItem { Label("記録", systemImage: "record.circle") }
            RidesListView()
                .tabItem { Label("走行記録", systemImage: "list.bullet") }
            ProfileView()
                .tabItem { Label("マイページ", systemImage: "person") }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .alert("エラー", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("OK") { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
    }
}

#Preview {
    RootTabView().environmentObject(AppState(backend: MockBackend()))
}
