import Foundation

/// The last account `GET /me` returned, kept so a launch that cannot reach the
/// server still knows who is signed in.
///
/// A child's token is good for a hundred years and only the server can say it
/// has stopped being (`SESSION_LIFETIME_MS`, ledger `L17`), so a launch with no
/// network is not a launch with no child - it is a launch that could not read.
/// Without something cached, `Session.restore()` has an account-shaped hole to
/// fill and the only state it can name is `.signedOut`, which puts a child on
/// the code-entry screen asking for a code only a parent can issue.
///
/// What is cached is small and not secret: an id, a name, an avatar. The token
/// stays in the Keychain, where a long-lived secret belongs; this is beside the
/// sync queue and the content packs, with the rest of what the app can rebuild
/// but should not lose.
public protocol AccountCache: Sendable {
    func read() -> Account?
    func write(_ account: Account?)
}

/// Keeps nothing. The default where a cache would only get in the way - tests
/// that are not about the cache, and previews.
public struct NoAccountCache: AccountCache {
    public init() {}
    public func read() -> Account? { nil }
    public func write(_ account: Account?) {}
}

/// One small JSON file, written atomically.
///
/// Every failure is swallowed on purpose. A cache that cannot be read is a
/// cache miss, and a cache that cannot be written is a launch that will have to
/// ask the server again - neither is worth failing a sign-in over, and this
/// sits on the launch path.
public struct FileAccountCache: AccountCache {
    let url: URL

    public init(url: URL) { self.url = url }

    public func read() -> Account? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    /// Writing nil clears the file: a signed-out device must not leave the last
    /// child's name on disk for the next one to be greeted by.
    public func write(_ account: Account?) {
        guard let account else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(account) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
