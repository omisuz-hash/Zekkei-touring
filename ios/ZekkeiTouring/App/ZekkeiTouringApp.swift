import SwiftUI
import GoogleSignIn

@main
struct ZekkeiTouringApp: App {
    @StateObject private var app = AppState()

    init() {
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String, !clientID.hasPrefix("REPLACE") {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(app)
                .task { await app.bootstrap() }
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
