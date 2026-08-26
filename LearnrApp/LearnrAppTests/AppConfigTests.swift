import Testing
import Foundation
@testable import LearnrApp

/// `AppConfig` reads its base URL from Info.plist so a build can be pointed at
/// a local server or at Fly without a code change. These check the fallbacks,
/// because the failure mode is an app that silently talks to the wrong server.
struct AppConfigTests {

    @Test("falls back to localhost when Info.plist carries no URL")
    func fallsBackToLocalhost() {
        // The test bundle has no LearnrAPIBaseURL, so this exercises the
        // fallback exactly as a build with the setting unset would.
        #expect(AppConfig.apiBaseURL.absoluteString.contains("localhost"))
    }

    @Test("an unsubstituted or empty setting does not become a bad URL")
    func rejectsEmptyValue() {
        // XcodeGen writes $(LEARNR_API_BASE_URL) into the plist. If the build
        // setting is unset, that arrives as an empty string - which URL()
        // happily accepts, producing a URL that resolves to nothing.
        #expect(AppConfig.url(from: "") == nil)
        #expect(AppConfig.url(from: "$(LEARNR_API_BASE_URL)") == nil)
        #expect(AppConfig.url(from: "not a url") == nil)
    }

    @Test("a real URL is used as given")
    func acceptsRealURL() {
        #expect(AppConfig.url(from: "https://learnr-api-syd.fly.dev")?.absoluteString
                == "https://learnr-api-syd.fly.dev")
        #expect(AppConfig.url(from: "http://localhost:3001")?.absoluteString
                == "http://localhost:3001")
    }
}
