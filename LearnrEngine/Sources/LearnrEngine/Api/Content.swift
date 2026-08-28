import Foundation

/// The result of a conditional GET.
///
/// `notModified` is not an error and not an empty result: it says the caller's
/// cached copy is current, which is the best answer the server can give and the
/// reason the ETag was sent. Modelling it as a case rather than an optional
/// keeps a caller from confusing "unchanged" with "nothing there".
public enum Fetched<Value: Decodable>: Sendable where Value: Sendable {
    /// The decoded value, its ETag, and the bytes it was decoded from. The
    /// bytes ride along because the pack cache stores what arrived rather than
    /// a re-encoding of it — see `CachedPack`.
    case fetched(Value, etag: String?, data: Data)
    case notModified

    public var value: Value? {
        if case .fetched(let value, _, _) = self { return value }
        return nil
    }

    public var etag: String? {
        if case .fetched(_, let etag, _) = self { return etag }
        return nil
    }

    public var data: Data? {
        if case .fetched(_, _, let data) = self { return data }
        return nil
    }
}

// MARK: - Manifest

/// What can be played, and the ETag of each level's pack.
///
/// Small enough to fetch on every launch — that is the point of it. Without the
/// manifest a device would have to download every pack to find out whether the
/// one it cached is stale.
public struct ContentManifest: Codable, Sendable, Equatable {
    public let version: String
    public let subjects: [ManifestSubject]

    /// The entry for one subject at one level, or nil if the server does not
    /// carry it.
    public func entry(subject: String, level: YearLevel) -> ManifestLevel? {
        subjects.first { $0.subject == subject }?
            .levels.first { $0.level == level }
    }
}

public struct ManifestSubject: Codable, Sendable, Equatable {
    public let subject: String
    public let levels: [ManifestLevel]
}

public struct ManifestLevel: Codable, Sendable, Equatable {
    public let level: YearLevel
    public let topics: [String]
    public let templateCount: Int
    /// The pack's ETag, so a device can tell a stale cache from a current one
    /// without fetching the pack itself.
    public let etag: String
}

// MARK: - The cache

/// A content pack as cached on disk, with the ETag it arrived under.
///
/// The pack is kept as **the raw JSON bytes the server sent**, not as a
/// re-encoded `ContentPack`. The template tree is decode-only by design — five
/// hand-written decoders, several of them lossy on purpose (`FigureSpec` drops
/// a non-string field rather than rejecting it) — so re-encoding it would mean
/// writing five encoders whose only job is to round-trip exactly, and a bug in
/// any of them would corrupt a cached pack silently. Storing what arrived
/// sidesteps the question: the bytes decode the same way on the second launch
/// as they did on the first, because they *are* the same bytes.
public struct CachedPack: Sendable, Equatable {
    /// Exactly what the server sent.
    public let data: Data
    public let subject: String
    public let level: YearLevel
    public let etag: String?
    /// When it was written, so a caller can tell a fresh cache from an ancient
    /// one without a network call. Milliseconds since the epoch.
    public let storedAt: Int

    public init(data: Data, subject: String, level: YearLevel, etag: String?, storedAt: Int) {
        self.data = data
        self.subject = subject
        self.level = level
        self.etag = etag
        self.storedAt = storedAt
    }

    /// The decoded pack, or nil if the cached bytes will not parse — which can
    /// only happen if the file was truncated or the format moved under it.
    public var pack: ContentPack? {
        try? JSONDecoder().decode(ContentPack.self, from: data)
    }
}

/// The sidecar written beside a cached pack: everything about it except the
/// bytes, which live in their own file so the pack is never re-encoded.
private struct PackMeta: Codable {
    let subject: String
    let level: YearLevel
    let etag: String?
    let storedAt: Int
}

/// Where content packs live between launches.
///
/// A protocol so tests can hold packs in memory, mirroring `SittingStore`.
public protocol PackStore: Sendable {
    func load(subject: String, level: YearLevel) -> CachedPack?
    func save(_ cached: CachedPack)
}

/// A file-backed pack cache.
///
/// One pair of files per subject and level rather than one file holding
/// everything: a child plays one level, so loading their pack should not mean
/// parsing six others, and a partial write can only ever cost the one pack.
public struct FilePackStore: PackStore {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// `maths-3.json` and `maths-3.meta.json`. The level is a fixed vocabulary
    /// and the subject comes from the manifest, so neither can contain a path
    /// separator — but the subject is still a server-supplied string, so it is
    /// filtered rather than trusted.
    func name(subject: String, level: YearLevel) -> String {
        let safe = subject.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(safe)-\(level.rawValue)"
    }

    public func load(subject: String, level: YearLevel) -> CachedPack? {
        let base = name(subject: subject, level: level)
        guard
            let data = try? Data(contentsOf: directory.appendingPathComponent("\(base).json")),
            let metaData = try? Data(
                contentsOf: directory.appendingPathComponent("\(base).meta.json")),
            let meta = try? JSONDecoder().decode(PackMeta.self, from: metaData)
        else { return nil }

        return CachedPack(
            data: data, subject: meta.subject, level: meta.level,
            etag: meta.etag, storedAt: meta.storedAt)
    }

    public func save(_ cached: CachedPack) {
        let base = name(subject: cached.subject, level: cached.level)
        let meta = PackMeta(
            subject: cached.subject, level: cached.level,
            etag: cached.etag, storedAt: cached.storedAt)
        guard let metaData = try? JSONEncoder().encode(meta) else { return }

        // Atomic, like the sitting store, and the bytes go down *before* the
        // sidecar: `load` needs both, so a crash between the two writes leaves
        // a pack with no meta, which reads as no cache rather than as a pack
        // with the wrong ETag. Claiming a stale ETag is the worse failure - it
        // would make the server answer 304 for a pack the device does not have.
        try? cached.data.write(
            to: directory.appendingPathComponent("\(base).json"), options: .atomic)
        try? metaData.write(
            to: directory.appendingPathComponent("\(base).meta.json"), options: .atomic)
    }
}

// MARK: - The library

/// Where the play screen gets its templates.
///
/// The rule is that **a cached pack always wins over a failed fetch**. A child
/// on a school-run connection has the same right to a question as one on wifi,
/// and the sync queue already assumes they will get one. So the network is
/// consulted for freshness, never for permission: every path that cannot reach
/// the server falls back to what is on disk, and only a device that has never
/// once fetched this level has nothing to offer.
public actor ContentLibrary {
    private let api: ApiClient
    private let store: any PackStore
    private let now: @Sendable () -> Int

    public init(
        api: ApiClient,
        store: any PackStore,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.api = api
        self.store = store
        self.now = now
    }

    public enum LibraryError: Error, Equatable {
        /// Nothing cached and nothing reachable. The only state in which the
        /// play screen genuinely cannot deal a question.
        case unavailable(subject: String, level: YearLevel)
    }

    /// The templates for one subject and level, from the cache or the network.
    ///
    /// The order is deliberate: read the cache first, then revalidate. A cached
    /// pack is returned even when the revalidation fails, and the *only* time
    /// this throws is when there is no cache and the fetch failed too.
    public func pack(subject: String = "maths", level: YearLevel) async throws -> ContentPack {
        let cached = store.load(subject: subject, level: level)

        do {
            let result = try await api.contentPack(
                subject: subject, level: level, ifNoneMatch: cached?.etag)

            switch result {
            case .notModified:
                // The server has confirmed the cache. If it said 304 we must
                // have sent an ETag, so a cache exists — but this is written as
                // a fallback rather than a force-unwrap, because a server that
                // 304s an unconditional request should not crash a child's app.
                if let pack = cached?.pack { return pack }
            case .fetched(let pack, let etag, let data):
                store.save(CachedPack(
                    data: data, subject: subject, level: level,
                    etag: etag, storedAt: now()))
                return pack
            }
        } catch {
            // Offline, unauthorised, a 500 — none of them are a reason to
            // refuse a child a question they already have the templates for.
        }

        // A cache that will not decode is no cache: the bytes were truncated or
        // the format moved, and either way there is nothing to play from.
        guard let pack = cached?.pack else {
            throw LibraryError.unavailable(subject: subject, level: level)
        }
        return pack
    }

    /// What is already on disk, without touching the network.
    ///
    /// For the launch path: a child who opens the app offline should see a
    /// question rather than a spinner waiting on a request that will time out.
    public func cachedPack(subject: String = "maths", level: YearLevel) -> ContentPack? {
        store.load(subject: subject, level: level)?.pack
    }

    /// The pack to start a sitting from. **Cache first, and never blocking.**
    ///
    /// This is the refresh cadence decided under ledger `L15`: content is
    /// revalidated by `refresh(subject:level:)` on the home screen, not in
    /// front of the child's first question. `pack(subject:level:)` revalidates
    /// on every call, which put a conditional GET between a child and playing -
    /// and `URLSession`'s default timeout is sixty seconds, so a school-run
    /// connection that neither succeeds nor fails quickly could hold a child on
    /// a spinner for a minute before falling back to a pack that was on disk
    /// the whole time.
    ///
    /// The trade is deliberate: a sitting may start on content up to one launch
    /// old. That is the right way round, because a pack is a set of question
    /// templates rather than a child's data - a day-old template still asks a
    /// correct question, while a minute of spinner costs the sitting itself.
    ///
    /// Cache-first is not cache-only: a device that has never fetched this
    /// level has nothing to read, so it falls through to the network and throws
    /// only if that fails too.
    public func packForPlay(subject: String = "maths", level: YearLevel) async throws -> ContentPack {
        if let cached = store.load(subject: subject, level: level)?.pack { return cached }
        return try await pack(subject: subject, level: level)
    }

    /// Brings one level's cached pack up to date, if the manifest says it has
    /// moved. Best-effort and silent: called off the play path.
    ///
    /// The manifest carries every level's ETag, so this is one small request
    /// for a device that is already current - which is the common case, and the
    /// reason the cadence is gated on it rather than revalidating each pack
    /// directly. Only a level whose ETag actually differs is downloaded.
    ///
    /// A failure at any step leaves the cache exactly as it was. A refresh is
    /// an optimisation, and a child who cannot reach the server keeps playing
    /// from what they have.
    public func refresh(subject: String = "maths", level: YearLevel) async {
        guard let manifest = await manifest(),
              let entry = manifest.entry(subject: subject, level: level)
        else { return }

        // Nothing cached is not "unchanged" - there is nothing to compare and
        // everything to fetch.
        let cached = store.load(subject: subject, level: level)
        guard cached?.etag != entry.etag else { return }

        // `pack` does the conditional GET, the decode and the write. Sending
        // the cached ETag still matters: the manifest can move for a reason
        // that leaves this level's bytes identical, and a 304 then costs
        // nothing.
        _ = try? await pack(subject: subject, level: level)
    }

    /// The catalogue, when it can be had. Never throws: a caller uses this to
    /// decide what to offer, and "I could not ask" is answered by offering what
    /// is already cached.
    public func manifest() async -> ContentManifest? {
        try? await api.contentManifest().value
    }
}
