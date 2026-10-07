import Foundation
import CoreLocation

/// 他のアプリが書き出した走行記録を読み込む。
/// GPX（ほぼ全てのツーリング・サイクリング系アプリが対応）と、KML（Google マップ系）に対応する。
enum TrackImporter {
    enum ImportError: LocalizedError {
        case unsupported(String)
        case noPoints
        case tooFar

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "この形式には対応していません（.\(ext)）。GPX か KML で書き出してください。"
            case .noPoints: return "位置の記録が見つかりませんでした。走行の軌跡を含むファイルを選んでください。"
            case .tooFar: return "日本の範囲から外れた座標が含まれています。ファイルを確認してください。"
            }
        }
    }

    static let supportedExtensions = ["gpx", "kml", "tcx"]

    /// ファイルを読み込んで走行記録に変換する。1 ファイルに複数の軌跡があれば分けて返す
    static func rides(from url: URL) throws -> [RideLog] {
        let ext = url.pathExtension.lowercased()
        // 「ファイル」アプリや他アプリから渡される URL は保護されているため、明示的に開く
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)

        let tracks: [[TrackPoint]]
        switch ext {
        case "gpx", "tcx": tracks = GPXParser.parse(data)   // TCX も trkpt 相当の構造を拾う
        case "kml":        tracks = KMLParser.parse(data)
        default:           throw ImportError.unsupported(ext)
        }

        let rides = tracks
            .map { clean($0) }
            .filter { $0.count >= 10 }
            .map { pts in RideLog(startedAt: pts.first!.timestamp, endedAt: pts.last!.timestamp, points: pts) }
        guard !rides.isEmpty else { throw ImportError.noPoints }
        return rides
    }

    /// 同一地点の重複と、明らかな異常値を取り除く
    private static func clean(_ points: [TrackPoint]) -> [TrackPoint] {
        var out: [TrackPoint] = []
        for p in points {
            guard p.lat.isFinite, p.lng.isFinite, abs(p.lat) <= 90, abs(p.lng) <= 180 else { continue }
            if let last = out.last, GeoUtils.distance(last.coordinate, p.coordinate) < 3 { continue }
            out.append(p)
        }
        return out
    }
}

// MARK: - GPX

/// GPX の軌跡（trk / trkseg / trkpt）とルート（rte / rtept）を読む
private final class GPXParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> [[TrackPoint]] {
        let p = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        p.flushSegment()
        return p.tracks
    }

    private var tracks: [[TrackPoint]] = []
    private var segment: [TrackPoint] = []
    private var lat: Double?
    private var lng: Double?
    private var ele: Double?
    private var time: Date?
    private var text = ""
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    fileprivate func flushSegment() {
        if segment.count >= 2 { tracks.append(segment) }
        segment = []
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        text = ""
        let tag = name.lowercased()
        switch tag {
        case "trkseg":
            flushSegment()
        case "trk", "rte":
            flushSegment()
        case "trkpt", "rtept":
            lat = a["lat"].flatMap(Double.init)
            lng = a["lon"].flatMap(Double.init)
            ele = nil
            time = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let tag = name.lowercased()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tag {
        case "ele", "altitudemeters":
            ele = Double(body)
        case "time":
            time = GPXParser.iso.date(from: body) ?? GPXParser.isoPlain.date(from: body)
        case "latitudedegrees":   // TCX
            lat = Double(body)
        case "longitudedegrees":  // TCX
            lng = Double(body)
        case "trkpt", "rtept", "trackpoint":
            if let la = lat, let ln = lng {
                segment.append(TrackPoint(lat: la, lng: ln, altitude: ele ?? 0, speedMps: 0,
                                          timestamp: time ?? Date(timeIntervalSince1970: 0)))
            }
            lat = nil; lng = nil
        case "trkseg", "trk", "rte", "track":
            flushSegment()
        default:
            break
        }
        text = ""
    }
}

// MARK: - KML

/// KML の LineString（Google マップ・Google Earth の書き出し）を読む
private final class KMLParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> [[TrackPoint]] {
        let p = KMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.tracks
    }

    private var tracks: [[TrackPoint]] = []
    private var text = ""
    private var inCoordinates = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        inCoordinates = name.lowercased() == "coordinates"
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { if inCoordinates { text += s } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name.lowercased() == "coordinates" else { return }
        // 「経度,緯度[,標高]」を空白区切りで並べた形式
        var pts: [TrackPoint] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            let v = token.split(separator: ",").compactMap { Double($0) }
            guard v.count >= 2 else { continue }
            pts.append(TrackPoint(lat: v[1], lng: v[0], altitude: v.count > 2 ? v[2] : 0, speedMps: 0,
                                  timestamp: Date(timeIntervalSince1970: 0)))
        }
        if pts.count >= 2 { tracks.append(pts) }
        inCoordinates = false
        text = ""
    }
}
