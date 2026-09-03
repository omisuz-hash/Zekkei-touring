import Foundation
import CoreLocation
import Combine

/// アプリ全体の状態。ログイン、閲覧枠、走行記録、設定をまとめて持つ
@MainActor
final class AppState: ObservableObject {
    let backend: Backend
    let recorder = RideRecorder()
    let store = RideStore()

    @Published var isSignedIn = false
    @Published var profile: Profile?
    @Published var creditBalance = 0
    @Published var unlockedRoadIds: Set<UUID> = []
    @Published var lastError: String?

    private var cancellables: Set<AnyCancellable> = []

    /// プライバシーゾーン（自宅など）。端末内に保存し、切り出し時の既定除外に使う
    @Published var privacyCenter: CLLocationCoordinate2D? {
        didSet { persistPrivacy() }
    }
    @Published var privacyRadiusMeters: Double = 1000 {
        didSet { persistPrivacy() }
    }

    /// 接続先が未設定の場合はモックで動く（開発初期・プレビュー用）
    var isUsingMock: Bool { backend is MockBackend }

    init(backend: Backend? = nil) {
        self.backend = backend ?? SupabaseBackend() ?? MockBackend()
        let d = UserDefaults.standard
        if d.object(forKey: "privacy.lat") != nil {
            privacyCenter = CLLocationCoordinate2D(latitude: d.double(forKey: "privacy.lat"), longitude: d.double(forKey: "privacy.lng"))
        }
        let r = d.double(forKey: "privacy.radius")
        if r > 0 { privacyRadiusMeters = r }
        // 記録・保存の変化を画面に伝える（入れ子の ObservableObject は自動では伝わらない）
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    func bootstrap() async {
        await backend.restoreSession()
        await refreshAccount()
    }

    func refreshAccount() async {
        isSignedIn = backend.currentUserId != nil
        guard isSignedIn else {
            profile = nil
            creditBalance = 0
            unlockedRoadIds = []
            return
        }
        do {
            profile = try await backend.profile()
            creditBalance = try await backend.creditBalance()
            unlockedRoadIds = try await backend.unlockedRoadIds()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        try? await backend.signOut()
        await refreshAccount()
    }

    func isUnlocked(_ road: ZekkeiRoad) -> Bool {
        profile?.plan == .subscriber || unlockedRoadIds.contains(road.id)
    }

    /// 閲覧枠を消費して絶景道を解放する。成功したら true
    func unlock(_ road: ZekkeiRoad) async -> Bool {
        guard isSignedIn else { lastError = BackendError.notSignedIn.localizedDescription; return false }
        do {
            let result = try await backend.unlockRoad(road.id)
            creditBalance = result.balance
            if result.unlocked { unlockedRoadIds.insert(road.id) }
            return result.unlocked
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func persistPrivacy() {
        let d = UserDefaults.standard
        if let c = privacyCenter {
            d.set(c.latitude, forKey: "privacy.lat")
            d.set(c.longitude, forKey: "privacy.lng")
        } else {
            d.removeObject(forKey: "privacy.lat")
            d.removeObject(forKey: "privacy.lng")
        }
        d.set(privacyRadiusMeters, forKey: "privacy.radius")
    }
}
