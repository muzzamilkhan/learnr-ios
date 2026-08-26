import SwiftUI
import LearnrEngine

@main
struct LearnrApp: App {
    @State private var session = Session(baseURL: AppConfig.apiBaseURL)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.restore() }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back to the app is the most likely moment for the
                    // network to have returned, so it is when to try again.
                    if phase == .active {
                        Task { await session.sync() }
                    }
                }
        }
    }
}

enum AppConfig {
    /// Overridable so a device can point at a machine on the LAN without a
    /// rebuild. Defaults to the simulator's view of a local server.
    static var apiBaseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "LearnrAPIBaseURL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:3001")!
    }
}
