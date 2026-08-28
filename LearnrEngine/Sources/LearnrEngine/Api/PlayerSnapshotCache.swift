import Foundation

/// What the home screen knows about a child between sittings.
///
/// Stars and a streak are earned inside a sitting and banked by the server, and
/// until this existed they were visible only in the moment they happened - the
/// sitting summary and the speed-run result. The screen a child actually lands
/// on knew none of it, so yesterday's work was invisible without playing again.
///
/// It is a snapshot rather than a running total on purpose: the server owns the
/// star ledger, `PlaySession` deliberately carries neither figure, and a home
/// screen one launch behind is the right freshness for a between-times view.
public struct PlayerSnapshot: Codable, Sendable, Equatable {
    public let stars: Int
    public let streakDays: Int
    /// The level this child plays at, cached with the figures because an
    /// offline launch needs it to refresh the right content pack.
    public let level: String?

    public init(stars: Int, streakDays: Int, level: String?) {
        self.stars = stars
        self.streakDays = streakDays
        self.level = level
    }

    /// A count that starts at nought is a scoreboard, not a judgement - and
    /// hiding it would make the first star appear from nowhere.
    public var showsStars: Bool { true }

    /// A streak of nought is not shown. "0 days" is a scold, and a child who
    /// has just broken a streak does not need it named on the screen they land
    /// on; the way back is to play, which is the button beneath it.
    public var showsStreak: Bool { streakDays > 0 }
}

/// The last figures `GET /play/state` returned, kept so a launch that cannot
/// reach the server still has something true to show.
///
/// Beside the account, the queue and the packs, for the same reason as all
/// three: a child kept signed in through an outage (ledger `L17`) can reach
/// this screen with no network, and it should not go blank when they do.
public protocol PlayerSnapshotCache: Sendable {
    func read() -> PlayerSnapshot?
    func write(_ snapshot: PlayerSnapshot?)
}

/// Keeps nothing. The default where a cache would only get in the way - tests
/// that are not about the cache, and previews.
public struct NoPlayerSnapshotCache: PlayerSnapshotCache {
    public init() {}
    public func read() -> PlayerSnapshot? { nil }
    public func write(_ snapshot: PlayerSnapshot?) {}
}

/// One small JSON file, written atomically.
///
/// Every failure is swallowed, as with the account beside it: a cache that
/// cannot be read is a cache miss, and one that cannot be written is a launch
/// that will ask the server again. Neither is worth failing a launch over.
public struct FilePlayerSnapshotCache: PlayerSnapshotCache {
    let url: URL

    public init(url: URL) { self.url = url }

    public func read() -> PlayerSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlayerSnapshot.self, from: data)
    }

    /// Writing nil clears the file: a signed-out device must not leave the last
    /// child's stars on disk for the next one to be greeted by.
    public func write(_ snapshot: PlayerSnapshot?) {
        guard let snapshot else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
