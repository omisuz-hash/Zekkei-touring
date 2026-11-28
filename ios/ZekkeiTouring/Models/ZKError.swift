import Foundation

/// サーバーや通信のエラーを、利用者に読める日本語に言い換える。
/// 英語のまま出すと、何をすればよいか分からず問い合わせにもつながらない
enum ZKError {
    static func humanized(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("statement timeout") || s.contains("canceling statement") {
            return "地図の読み込みに時間がかかりすぎました。地図を少し拡大してから、もう一度お試しください。"
        }
        if s.contains("not connected to the internet") || s.contains("offline")
            || s.contains("network connection was lost") {
            return "通信できませんでした。電波の届く場所で、もう一度お試しください。"
        }
        if s.contains("timed out") || s.contains("timeout") {
            return "通信に時間がかかりすぎました。もう一度お試しください。"
        }
        if s.isEmpty { return "うまくいきませんでした。もう一度お試しください。" }
        return raw
    }
}
