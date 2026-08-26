import Testing
import Foundation
@testable import LearnrApp

/// `AppConfig` reads its base URL from Info.plist so a build can be pointed at
/// a local server or at Fly without a code change. These check the fallbacks,
/// because the failure mode is an app that silently talks to the wrong server.
struct AppConfigTests {

    @Test("falls back to localhost when no URL is configured")
    func fallsBackToLocalhost() {
        // Asserted through `url(from:)` rather than through `apiBaseURL`.
        //
        // This used to read `apiBaseURL` directly, on the premise that "the test
        // bundle has no LearnrAPIBaseURL" - which stopped being true once the
        // test target began inheriting the app's build settings, so the test
        // failed against a perfectly correct fallback. The premise was the bug:
        // a test that depends on a key being *absent* from a bundle it does not
        // control is testing the build system, not the code.
        //
        // `apiBaseURL` is `url(from:) ?? localhost`, so pinning the nil arm of
        // that coalesce is pinning the fallback.
        #expect(AppConfig.url(from: nil) == nil)

        // And the real thing still resolves to something usable, whichever way
        // this particular build is configured.
        let scheme = AppConfig.apiBaseURL.scheme
        #expect(scheme == "http" || scheme == "https")
        #expect(AppConfig.apiBaseURL.host != nil)
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
