import Foundation

/// アプリの版。画面に出すためと、問い合わせを受けたときの確認に使う
enum AppVersion {
    /// 表示用の版（1.0.1 など）
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
    /// ビルド番号（配布時に日時から自動で付く）
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }
    /// 「バージョン 1.0.1 (202611251338)」
    static var display: String { "バージョン \(marketing) (\(build))" }
}
