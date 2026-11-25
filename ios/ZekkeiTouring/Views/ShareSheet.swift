import SwiftUI
import UIKit

/// 複数のファイルをまとめて共有するための入れ物。
/// ShareLink は渡すものを先に決めておく必要があるため、
/// 「押してから書き出す」流れにはこちらを使う
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
