import SwiftUI

/// 自分が付けた評価を、あとから直す
///
/// 直せるのは点数・季節・コメントのみ。道の名前や区間の形は、ほかの人の評価も
/// 載る共有の情報なので、ここでは触らない（取り消しは道の詳細の ⋯ から）
struct EditRatingView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let rating: RoadRating
    /// 保存後、呼び出し元に一覧を取り直させる
    var onSaved: () -> Void

    @State private var scores: [RatingAxis: Int]
    @State private var traffic: Int
    @State private var seasons: Set<String>
    @State private var comment: String
    @State private var isSaving = false

    private let seasonOptions = ["春", "夏", "秋", "冬", "早朝", "夕方"]

    init(rating: RoadRating, onSaved: @escaping () -> Void) {
        self.rating = rating
        self.onSaved = onSaved
        _scores = State(initialValue: Dictionary(uniqueKeysWithValues: RatingAxis.allCases.map { ($0, rating.score(for: $0)) }))
        _traffic = State(initialValue: rating.traffic ?? 0)
        _seasons = State(initialValue: Set((rating.season ?? "")
            .split(separator: "・").map(String.init).filter { !$0.isEmpty }))
        _comment = State(initialValue: rating.comment ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RatingAxis.allCases) { axis in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(axis.title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                Text(axis.caption).font(.system(size: 10)).foregroundStyle(ZK.caption).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            StarPicker(value: Binding(get: { scores[axis] ?? 3 }, set: { scores[axis] = $0 }))
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        CaptionLabel(text: "おすすめの季節・時間帯", size: 10)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(seasonOptions, id: \.self) { s in
                                Chip(text: s, selected: seasons.contains(s))
                                    .onTapGesture { if seasons.contains(s) { seasons.remove(s) } else { seasons.insert(s) } }
                            }
                        }
                        Stepper("交通量: \(traffic == 0 ? "未入力" : "\(traffic)/5")", value: $traffic, in: 0...5)
                            .font(.system(size: 14)).foregroundStyle(ZK.body)
                    }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                }
                Section {
                    TextField("", text: $comment,
                              prompt: Text("この道の見どころ、注意点など").foregroundStyle(ZK.disabled),
                              axis: .vertical)
                        .lineLimit(3...6)
                } header: { CaptionLabel(text: "コメント", size: 10) }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving { ProgressView().tint(ZK.primaryButtonText) }
                            Text("保存する")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 54, radius: 16, font: .system(size: 17, weight: .bold)))
                    .disabled(isSaving)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    Text("写真・動画の差し替えは、道の詳細の ⋯ から追加・取り消しができます")
                        .font(.system(size: 11)).foregroundStyle(ZK.caption)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZK.bg)
            .tint(ZK.accent)
            .navigationTitle("評価を直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }.foregroundStyle(ZK.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let seasonText = seasonOptions.filter { seasons.contains($0) }.joined(separator: "・")
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit = RatingEdit(scenery: scores[.scenery] ?? 3,
                              rideQuality: scores[.rideQuality] ?? 3,
                              winding: scores[.winding] ?? 3,
                              restStops: scores[.restStops] ?? 3,
                              parking: scores[.parking] ?? 3,
                              traffic: traffic == 0 ? nil : traffic,
                              season: seasonText.isEmpty ? nil : seasonText,
                              comment: text.isEmpty ? nil : text)
        do {
            try await app.backend.updateRating(id: rating.id, edit: edit)
            onSaved()
            dismiss()
        } catch {
            app.lastError = error.localizedDescription
        }
    }
}
