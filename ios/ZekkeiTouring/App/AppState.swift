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
    /// 取り込み結果の知らせ（他アプリから共有されたときに出す）
    @Published var lastNotice: String?

    private var cancellables: Set<AnyCancellable> = []

    /// 初期表示の地域。端末内に保存する（ログイン不要で使えるようにするため）
    @Published var homeRegion: Region = .kanto {
        didSet { UserDefaults.standard.set(homeRegion.rawValue, forKey: "home.region") }
    }
    /// 一度でも地域を選んだか（初回だけ選択を促す）
    @Published var homeRegionChosen = false {
        didSet { UserDefaults.standard.set(homeRegionChosen, forKey: "home.regionChosen") }
    }

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
        if let raw = d.string(forKey: "home.region"), let reg = Region(rawValue: raw) { homeRegion = reg }
        homeRegionChosen = d.bool(forKey: "home.regionChosen")
        // 記録・保存の変化を画面に伝える（入れ子の ObservableObject は自動では伝わらない）
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    /// 地域を未設定のまま現在地が取れた場合、一番近い地域を初期値にする（確定ではなく既定値）
    func suggestRegionFromLocation() {
        guard !homeRegionChosen, let l = recorder.lastLocation else { return }
        homeRegion = Region.nearest(to: l.coordinate)
    }

    /// 他のアプリから共有された走行記録のファイルを取り込む
    func importTrackFile(_ url: URL) {
        do {
            let rides = try TrackImporter.rides(from: url)
            rides.forEach { store.save($0) }
            lastNotice = "\(rides.count) 件の走行記録を取り込みました。「走行記録」タブから区間を切り出せます。"
                + (privacyCenter == nil ? "\n\n取り込んだ記録には自宅の出発・到着が含まれている場合があります。「走行記録」タブの案内から、自宅の周辺を伏せる設定ができます。" : "")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// アカウントを削除する。成功したら true
    func deleteAccount() async -> Bool {
        do {
            try await backend.deleteAccount()
            profile = nil
            isSignedIn = false
            creditBalance = 0
            unlockedRoadIds = []
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func bootstrap() async {
        await backend.restoreSession()
        await refreshAccount()
    }

    /// ニックネームを変更する。成功したら true
    func updateNickname(_ name: String) async -> Bool {
        do {
            let v = try await backend.setDisplayName(name)
            profile?.displayName = v
            profile?.displayNameSet = true
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
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
