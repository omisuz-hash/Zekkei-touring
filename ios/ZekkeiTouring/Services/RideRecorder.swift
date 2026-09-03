import Foundation
import CoreLocation
import Combine

/// 走行記録（GPS ロガー）。発車から降車までをバックグラウンドでも記録する
@MainActor
final class RideRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case paused   // 停車が続いた場合の自動一時停止
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastLocation: CLLocation?

    /// この距離未満の移動は同一地点とみなして記録しない（停車中のノイズ対策）
    var minimumStepMeters: Double = 5
    /// 停車がこの時間続くと自動で一時停止
    var autoPauseAfter: TimeInterval = 5 * 60
    /// 水平精度がこの値より悪い点は捨てる
    var maxHorizontalAccuracy: Double = 40

    private let manager = CLLocationManager()
    private var lastMovementAt: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        authorization = manager.authorizationStatus
    }

    var distanceMeters: Double { GeoUtils.length(of: points.map(\.coordinate)) }
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// 権限の要求。まず「使用中」を求め、記録開始時に「常に」へ引き上げる（Apple 推奨の順序）
    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func start() {
        guard state == .idle else { return }
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        points = []
        startedAt = Date()
        lastMovementAt = Date()
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        state = .recording
    }

    /// 記録を終了し、走行記録を返す
    func stop() -> RideLog? {
        guard state != .idle, let startedAt else { return nil }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        state = .idle
        let log = RideLog(startedAt: startedAt, endedAt: Date(), points: points)
        self.startedAt = nil
        return log.points.count > 1 ? log : nil
    }

    func resume() {
        guard state == .paused else { return }
        state = .recording
        lastMovementAt = Date()
    }

    private func append(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxHorizontalAccuracy else { return }
        lastLocation = location
        if let last = points.last {
            let step = GeoUtils.distance(last.coordinate, location.coordinate)
            if step < minimumStepMeters {
                // 停車中。自動一時停止の判定のみ行う
                if let moved = lastMovementAt, Date().timeIntervalSince(moved) > autoPauseAfter, state == .recording {
                    state = .paused
                }
                return
            }
        }
        lastMovementAt = Date()
        if state == .paused { state = .recording }
        points.append(TrackPoint(location: location))
    }
}

extension RideRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for l in locations { self.append(l) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 一時的な失敗は無視して記録を続ける
    }
}
