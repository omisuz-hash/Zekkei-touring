import Foundation

/// 走行記録の端末内保存（JSON）。自宅周辺を含むため、サーバーには送らない
@MainActor
final class RideStore: ObservableObject {
    @Published private(set) var rides: [RideLog] = []

    private let directory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("rides", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        rides = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(RideLog.self, from: $0) } }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ ride: RideLog) {
        let url = directory.appendingPathComponent("\(ride.id.uuidString).json")
        if let data = try? encoder.encode(ride) {
            try? data.write(to: url, options: .atomic)
        }
        if let i = rides.firstIndex(where: { $0.id == ride.id }) {
            rides[i] = ride
        } else {
            rides.insert(ride, at: 0)
            rides.sort { $0.startedAt > $1.startedAt }
        }
    }

    func delete(_ ride: RideLog) {
        let url = directory.appendingPathComponent("\(ride.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        rides.removeAll { $0.id == ride.id }
    }
}
