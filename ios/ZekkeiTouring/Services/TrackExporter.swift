import Foundation
import CoreTransferable

/// 走行記録を GPX として書き出す。
/// 他のアプリへ渡す（審査用の見本を送る、別の記録アプリへ移す、手元に控えを残す）ための出口。
/// 軌跡そのものを渡すため、自宅周辺を含む点に注意が要る。利用者が明示的に選んだときだけ作る
enum TrackExporter {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 書き出すファイル名。「20261108-1005_zekkeido.gpx」
    static func fileName(for ride: RideLog) -> String {
        "\(stamp.string(from: ride.startedAt))_zekkeido.gpx"
    }

    static func gpx(for ride: RideLog) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Zekkei-do" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(escaped(title(for: ride)))</name>
            <time>\(iso.string(from: ride.startedAt))</time>
          </metadata>
          <trk>
            <name>\(escaped(title(for: ride)))</name>
            <trkseg>

        """
        for p in ride.points {
            out += "      <trkpt lat=\"\(coord(p.lat))\" lon=\"\(coord(p.lng))\">"
            out += "<ele>\(String(format: "%.1f", p.altitude))</ele>"
            out += "<time>\(iso.string(from: p.timestamp))</time>"
            out += "</trkpt>\n"
        }
        out += """
            </trkseg>
          </trk>
        </gpx>

        """
        return out
    }

    /// 一時領域に書き出し、その場所を返す
    static func write(_ ride: RideLog) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(for: ride))
        try gpx(for: ride).data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private static func title(for ride: RideLog) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日 H:mm"
        return "絶景道 走行記録 \(f.string(from: ride.startedAt))"
    }

    /// GPX は小数 7 桁あれば 1 cm 程度まで表せる
    private static func coord(_ v: Double) -> String { String(format: "%.7f", v) }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// 共有シートへ渡せるようにする。実際の書き出しは、利用者が共有先を選んだ時点で行う
extension RideLog: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: TrackFileTypes.gpx) { ride in
            SentTransferredFile(try TrackExporter.write(ride))
        }
    }
}
