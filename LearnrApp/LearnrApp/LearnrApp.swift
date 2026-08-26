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
    /// Where the API lives.
    ///
    /// Read from Info.plist so a build can be pointed at a local server or at
    /// Fly without touching code. Defaults to the simulator's view of a local
    /// server; a build running on a device needs the deployed https URL, since
    /// App Transport Security refuses plain HTTP.
    static var apiBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "LearnrAPIBaseURL") as? String
        return url(from: raw) ?? URL(string: "http://localhost:3001")!
    }

    /// Rejects the values a misconfigured build actually produces, rather than
    /// trusting `URL(string:)` - which accepts an empty string and an
    /// unsubstituted `$(VAR)` alike, yielding a URL that quietly resolves to
    /// nothing and an app that cannot say why it will not sign in.
    static func url(from raw: String?) -> URL? {
        guard let raw else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }

        return url
    }
}
