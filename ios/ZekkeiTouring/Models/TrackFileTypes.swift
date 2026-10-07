import Foundation
import UniformTypeIdentifiers

/// 取り込めるファイルの種類。GPX と TCX は独自の型のため、ここで定義する
enum TrackFileTypes {
    static let gpx = UTType(exportedAs: "com.topografix.gpx", conformingTo: .xml)
    static let tcx = UTType(exportedAs: "com.garmin.tcx", conformingTo: .xml)
    static var all: [UTType] { [gpx, tcx, .xml, UTType(filenameExtension: "kml") ?? .xml] }
}
