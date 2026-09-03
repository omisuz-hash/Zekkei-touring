import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        TabView {
            ExploreMapView()
                .tabItem { Label("探す", systemImage: "map") }
            RecordView()
                .tabItem { Label("記録", systemImage: "record.circle") }
            RidesListView()
                .tabItem { Label("走行記録", systemImage: "list.bullet.rectangle") }
            ProfileView()
                .tabItem { Label("マイページ", systemImage: "person.crop.circle") }
        }
        .alert("エラー", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("OK") { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
    }
}

/// 5段階の星入力
struct StarPicker: View {
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= value ? "star.fill" : "star")
                    .foregroundStyle(i <= value ? Color.orange : Color.secondary)
                    .font(.title3)
                    .onTapGesture { value = i }
            }
        }
    }
}

/// 平均点の表示
struct ScoreBar: View {
    let axis: RatingAxis
    let value: Double?
    var body: some View {
        HStack {
            Label(axis.title, systemImage: axis.symbol)
                .frame(width: 180, alignment: .leading)
            if let v = value {
                ProgressView(value: v, total: 5).tint(.orange)
                Text(String(format: "%.1f", v)).monospacedDigit().frame(width: 36, alignment: .trailing)
            } else {
                Text("評価なし").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.subheadline)
    }
}

#Preview {
    RootTabView().environmentObject(AppState(backend: MockBackend()))
}
