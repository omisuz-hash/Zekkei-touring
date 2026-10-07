import Foundation
import CoreLocation
import MapKit

/// 地域。初期表示の場所を決めるためだけに使う。
/// 地図を動かせば地域をまたいで道を見られる仕様は変えない（境界で表示が切れることはない）
enum Region: String, CaseIterable, Identifiable, Codable {
    case hokkaido, tohoku, kanto, koshinetsu, hokuriku, tokai, kansai, chugoku, shikoku, kyushu

    var id: String { rawValue }

    var name: String {
        switch self {
        case .hokkaido: return "北海道"
        case .tohoku: return "東北"
        case .kanto: return "関東"
        case .koshinetsu: return "甲信越"
        case .hokuriku: return "北陸"
        case .tokai: return "東海"
        case .kansai: return "関西"
        case .chugoku: return "中国"
        case .shikoku: return "四国"
        case .kyushu: return "九州・沖縄"
        }
    }

    /// 含まれる都道府県（説明と、現在地からの判定に使う）
    var prefectures: [String] {
        switch self {
        case .hokkaido: return ["北海道"]
        case .tohoku: return ["青森県", "岩手県", "宮城県", "秋田県", "山形県", "福島県"]
        case .kanto: return ["茨城県", "栃木県", "群馬県", "埼玉県", "千葉県", "東京都", "神奈川県"]
        case .koshinetsu: return ["山梨県", "長野県", "新潟県"]
        case .hokuriku: return ["富山県", "石川県", "福井県"]
        case .tokai: return ["岐阜県", "静岡県", "愛知県", "三重県"]
        case .kansai: return ["滋賀県", "京都府", "大阪府", "兵庫県", "奈良県", "和歌山県"]
        case .chugoku: return ["鳥取県", "島根県", "岡山県", "広島県", "山口県"]
        case .shikoku: return ["徳島県", "香川県", "愛媛県", "高知県"]
        case .kyushu: return ["福岡県", "佐賀県", "長崎県", "熊本県", "大分県", "宮崎県", "鹿児島県", "沖縄県"]
        }
    }

    /// 初期表示の中心と広さ
    var center: CLLocationCoordinate2D {
        switch self {
        case .hokkaido: return .init(latitude: 43.3, longitude: 142.5)
        case .tohoku: return .init(latitude: 39.3, longitude: 140.6)
        case .kanto: return .init(latitude: 36.0, longitude: 139.4)
        case .koshinetsu: return .init(latitude: 36.6, longitude: 138.4)
        case .hokuriku: return .init(latitude: 36.5, longitude: 136.8)
        case .tokai: return .init(latitude: 35.1, longitude: 137.4)
        case .kansai: return .init(latitude: 34.6, longitude: 135.5)
        case .chugoku: return .init(latitude: 34.8, longitude: 132.8)
        case .shikoku: return .init(latitude: 33.8, longitude: 133.5)
        case .kyushu: return .init(latitude: 32.3, longitude: 130.8)
        }
    }

    var spanDegrees: Double {
        switch self {
        case .hokkaido: return 4.2
        case .tohoku: return 3.6
        case .kanto: return 2.2
        case .koshinetsu: return 2.6
        case .hokuriku: return 2.0
        case .tokai: return 2.2
        case .kansai: return 2.2
        case .chugoku: return 2.4
        case .shikoku: return 1.8
        case .kyushu: return 4.0
        }
    }

    var mapRegion: MKCoordinateRegion {
        MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees))
    }

    /// 端末に保存されている既定の地域（画面の初期値を組み立てる時点で使う）
    static var stored: Region {
        Region(rawValue: UserDefaults.standard.string(forKey: "home.region") ?? "") ?? .kanto
    }

    /// 現在地から、一番近い中心の地域を選ぶ（都道府県の判定が要らないので権限だけで済む）
    static func nearest(to c: CLLocationCoordinate2D) -> Region {
        allCases.min { GeoUtils.distance($0.center, c) < GeoUtils.distance($1.center, c) } ?? .kanto
    }
}
