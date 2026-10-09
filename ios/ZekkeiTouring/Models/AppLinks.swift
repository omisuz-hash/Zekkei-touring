import Foundation

/// 外部に出すリンク。公開先は tidalworks.jp（ページの用意ができるまでは未公開でも、参照先はここに集約する）
enum AppLinks {
    static let site = "https://tidalworks.jp/zekkeido"
    static var terms: URL { URL(string: "\(site)/terms")! }
    static var privacy: URL { URL(string: "\(site)/privacy")! }
    static var support: URL { URL(string: "mailto:support@tidalworks.jp")! }
}
