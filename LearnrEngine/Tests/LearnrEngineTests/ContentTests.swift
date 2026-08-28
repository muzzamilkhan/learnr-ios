import Testing
import Foundation
@testable import LearnrEngine

/// The content library, against a stubbed server.
///
/// The property under test throughout is the one the play screen depends on:
/// **a cached pack always wins over a failed fetch**. A child on a school-run
/// connection has the same right to a question as one on wifi.
struct ContentTests {

    /// A pack store held in memory, so a test can see exactly what was written.
    final class MemoryPackStore: PackStore, @unchecked Sendable {
        private let lock = NSLock()
        private var packs: [String: CachedPack] = [:]
        private(set) var saves = 0

        func load(subject: String, level: YearLevel) -> CachedPack? {
            lock.withLock { packs["\(subject)-\(level.rawValue)"] }
        }

        func save(_ cached: CachedPack) {
            lock.withLock {
                packs["\(cached.subject)-\(cached.level.rawValue)"] = cached
                saves += 1
            }
        }

        func seed(_ cached: CachedPack) {
            lock.withLock { packs["\(cached.subject)-\(cached.level.rawValue)"] = cached }
        }
    }

    /// A minimal pack, as the server would send it.
    static func packJSON(version: String, templateId: String = "t1") -> Data {
        Data("""
        {
          "version": "\(version)",
          "subject": "maths",
          "level": "3",
          "templates": [
            {
              "id": "\(templateId)",
              "subject": "maths",
              "topic": "addition",
              "level": "3",
              "prompt": "What is {x} + {y}?",
              "vars": [
                { "name": "x", "kind": "int", "min": "1", "max": "9" },
                { "name": "y", "kind": "int", "min": "1", "max": "9" }
              ],
              "answer": "x + y"
            }
          ]
        }
        """.utf8)
    }

    static let manifestJSON = Data("""
    {
      "version": "v1",
      "subjects": [
        {
          "subject": "maths",
          "levels": [
            { "level": "3", "topics": ["addition"], "templateCount": 1, "etag": "abc" }
          ]
        }
      ]
    }
    """.utf8)

    /// Builds a library over its own stubbed session.
    ///
    /// `StubProtocol.session` registers the handler under a per-session key, so
    /// these tests cannot answer another suite's requests or be answered by
    /// one - which is exactly what happened when they shared a global handler.
    static func library(
        store: MemoryPackStore,
        handler: @escaping @Sendable (URLRequest) -> (Int, Data, [String: String])
    ) -> ContentLibrary {
        let api = ApiClient(
            baseURL: URL(string: "https://example.test")!,
            tokens: MemoryTokenStore("token"),
            session: StubProtocol.session(handler))
        return ContentLibrary(api: api, store: store, now: { 1_000 })
    }

    @Test("a fetched pack is cached with its ETag")
    func fetchCaches() async throws {
        let store = MemoryPackStore()
        let library = Self.library(store: store) { _ in
            (200, Self.packJSON(version: "v1"), ["ETag": "\"abc\""])
        }

        let pack = try await library.pack(level: .three)
        #expect(pack.templates.count == 1)

        let cached = store.load(subject: "maths", level: .three)
        #expect(cached?.etag == "\"abc\"")
        #expect(cached?.storedAt == 1_000)
        // The bytes are what arrived, not a re-encoding.
        #expect(cached?.data == Self.packJSON(version: "v1"))
    }

    @Test("a 304 returns the cached pack and does not rewrite it")
    func notModifiedUsesCache() async throws {
        let store = MemoryPackStore()
        store.seed(CachedPack(
            data: Self.packJSON(version: "cached", templateId: "from-cache"),
            subject: "maths", level: .three, etag: "\"abc\"", storedAt: 1))

        let sentEtag = Sent()
        let library = Self.library(store: store) { request in
            sentEtag.value = request.value(forHTTPHeaderField: "If-None-Match")
            return (304, Data(), [:])
        }

        let pack = try await library.pack(level: .three)
        #expect(pack.templates.first?.id == "from-cache")
        // The stored ETag was offered, which is the whole point of caching it.
        #expect(sentEtag.value == "\"abc\"")
        #expect(store.saves == 0, "a 304 has nothing new to write")
    }

    @Test("a cached pack survives a failed fetch")
    func cacheWinsOverFailure() async throws {
        let store = MemoryPackStore()
        store.seed(CachedPack(
            data: Self.packJSON(version: "cached", templateId: "offline"),
            subject: "maths", level: .three, etag: nil, storedAt: 1))

        // Every failure a device actually meets: offline, a server error, and
        // an expired token. None of them may cost a child their question.
        for status in [500, 503, 401] {
            let library = Self.library(store: store) { _ in (status, Data(), [:]) }
            let pack = try await library.pack(level: .three)
            #expect(pack.templates.first?.id == "offline", "status \(status)")
        }
    }

    @Test("no cache and no network is the one unplayable state")
    func nothingAnywhere() async {
        let store = MemoryPackStore()
        let library = Self.library(store: store) { _ in (503, Data(), [:]) }

        await #expect(throws: ContentLibrary.LibraryError.unavailable(
            subject: "maths", level: .three)) {
            try await library.pack(level: .three)
        }
    }

    @Test("a cache that will not decode is treated as no cache")
    func corruptCacheIsNoCache() async {
        let store = MemoryPackStore()
        // Truncated bytes, as a crash mid-write would leave.
        store.seed(CachedPack(
            data: Data("{\"version\":".utf8),
            subject: "maths", level: .three, etag: nil, storedAt: 1))

        let library = Self.library(store: store) { _ in (503, Data(), [:]) }
        await #expect(throws: ContentLibrary.LibraryError.self) {
            try await library.pack(level: .three)
        }
    }

    @Test("a newer pack replaces the cached one")
    func refetchReplaces() async throws {
        let store = MemoryPackStore()
        store.seed(CachedPack(
            data: Self.packJSON(version: "old", templateId: "old"),
            subject: "maths", level: .three, etag: "\"old\"", storedAt: 1))

        let library = Self.library(store: store) { _ in
            (200, Self.packJSON(version: "new", templateId: "new"), ["ETag": "\"new\""])
        }

        let pack = try await library.pack(level: .three)
        #expect(pack.templates.first?.id == "new")
        #expect(store.load(subject: "maths", level: .three)?.etag == "\"new\"")
    }

    @Test("the manifest decodes and finds a level")
    func manifestDecodes() async throws {
        let store = MemoryPackStore()
        let library = Self.library(store: store) { _ in (200, Self.manifestJSON, [:]) }

        let manifest = await library.manifest()
        #expect(manifest?.version == "v1")
        #expect(manifest?.entry(subject: "maths", level: .three)?.etag == "abc")
        #expect(manifest?.entry(subject: "maths", level: .six) == nil)
        #expect(manifest?.entry(subject: "english", level: .three) == nil)
    }

    @Test("a failed manifest is nil rather than a throw")
    func manifestNeverThrows() async {
        let store = MemoryPackStore()
        let library = Self.library(store: store) { _ in (503, Data(), [:]) }
        #expect(await library.manifest() == nil)
    }

    @Test("cachedPack reads disk without touching the network")
    func cachedPackIsOffline() async {
        let store = MemoryPackStore()
        store.seed(CachedPack(
            data: Self.packJSON(version: "v", templateId: "disk"),
            subject: "maths", level: .three, etag: nil, storedAt: 1))

        let library = Self.library(store: store) { _ in
            Issue.record("cachedPack must not make a request")
            return (500, Data(), [:])
        }

        #expect(await library.cachedPack(level: .three)?.templates.first?.id == "disk")
        #expect(await library.cachedPack(level: .four) == nil)
    }

    @Test("the file store round-trips a pack through disk")
    func fileStoreRoundTrips() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("packs-\(UUID().uuidString)")
        let store = FilePackStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.load(subject: "maths", level: .three) == nil)

        let data = Self.packJSON(version: "v1", templateId: "round-trip")
        store.save(CachedPack(
            data: data, subject: "maths", level: .three, etag: "\"e\"", storedAt: 42))

        let loaded = store.load(subject: "maths", level: .three)
        #expect(loaded?.data == data)
        #expect(loaded?.etag == "\"e\"")
        #expect(loaded?.storedAt == 42)
        #expect(loaded?.pack?.templates.first?.id == "round-trip")
        // A different level is a different file.
        #expect(store.load(subject: "maths", level: .four) == nil)
    }

    @Test("a subject cannot escape the cache directory")
    func subjectIsFiltered() {
        let store = FilePackStore(directory: URL(fileURLWithPath: "/tmp/packs"))
        // The subject reaches this from the manifest, so it is server-supplied.
        // Filtered rather than trusted: a traversal must not become a path.
        #expect(store.name(subject: "../../etc/passwd", level: .three) == "etcpasswd-3")
        #expect(store.name(subject: "maths", level: .k) == "maths-K")
    }


    // MARK: Refresh cadence (L15)

    /// A counter for how many times each path was asked for.
    final class Hits: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func record(_ path: String) { lock.withLock { counts[path, default: 0] += 1 } }
        func count(_ path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    }

    @Test("play reads the cache and never waits on the network")
    func playIsCacheFirst() async throws {
        let store = MemoryPackStore()
        store.seed(CachedPack(
            data: Self.packJSON(version: "cached"), subject: "maths",
            level: .three, etag: "\"abc\"", storedAt: 1))

        let hits = Hits()
        let library = Self.library(store: store) { request in
            hits.record(request.url?.path ?? "")
            return (200, Self.packJSON(version: "fresh"), ["ETag": "\"zzz\""])
        }

        let pack = try await library.packForPlay(level: .three)

        // The cached bytes, and no request at all. This is the whole point of
        // L15: a child's first question must not wait on a round trip that a
        // flaky connection can hold open for the default sixty seconds.
        #expect(pack.version == "cached")
        #expect(hits.count("/content/maths/3") == 0)
    }

    @Test("play falls back to the network when nothing is cached")
    func playFetchesOnAColdCache() async throws {
        let store = MemoryPackStore()
        let hits = Hits()
        let library = Self.library(store: store) { request in
            hits.record(request.url?.path ?? "")
            return (200, Self.packJSON(version: "fresh"), ["ETag": "\"zzz\""])
        }

        // A device that has never played this level has nothing to read, so
        // here the network is the only option - cache-first is not
        // cache-only.
        let pack = try await library.packForPlay(level: .three)
        #expect(pack.version == "fresh")
        #expect(hits.count("/content/maths/3") == 1)
        // And it is cached on the way through, so the next sitting is instant.
        #expect(store.load(subject: "maths", level: .three)?.etag == "\"zzz\"")
    }

    @Test("a refresh fetches the pack when the manifest's ETag has moved")
    func refreshFollowsTheManifest() async throws {
        let store = MemoryPackStore()
        store.seed(CachedPack(
            data: Self.packJSON(version: "old"), subject: "maths",
            level: .three, etag: "\"stale\"", storedAt: 1))

        let hits = Hits()
        let library = Self.library(store: store) { request in
            let path = request.url?.path ?? ""
            hits.record(path)
            if path.hasSuffix("/manifest") { return (200, Self.manifestJSON, [:]) }
            return (200, Self.packJSON(version: "new"), ["ETag": "\"abc\""])
        }

        await library.refresh(subject: "maths", level: .three)

        // The manifest says "abc" and the cache holds "stale", so the pack is
        // worth fetching.
        #expect(hits.count("/content/manifest") == 1)
        #expect(hits.count("/content/maths/3") == 1)
        #expect(store.load(subject: "maths", level: .three)?.pack?.version == "new")
    }

    @Test("a refresh fetches nothing when the manifest's ETag matches")
    func refreshSkipsWhenUnchanged() async throws {
        let store = MemoryPackStore()
        // The manifest above says this level's ETag is "abc"; so does the
        // cache. There is nothing to download and no request worth making.
        store.seed(CachedPack(
            data: Self.packJSON(version: "current"), subject: "maths",
            level: .three, etag: "abc", storedAt: 1))

        let hits = Hits()
        let library = Self.library(store: store) { request in
            let path = request.url?.path ?? ""
            hits.record(path)
            if path.hasSuffix("/manifest") { return (200, Self.manifestJSON, [:]) }
            return (200, Self.packJSON(version: "new"), ["ETag": "abc"])
        }

        await library.refresh(subject: "maths", level: .three)

        #expect(hits.count("/content/manifest") == 1)
        // The manifest is the whole cost of a launch that is already current.
        #expect(hits.count("/content/maths/3") == 0)
        #expect(store.load(subject: "maths", level: .three)?.pack?.version == "current")
    }

    @Test("a refresh fetches when nothing is cached at all")
    func refreshFillsAColdCache() async throws {
        let store = MemoryPackStore()
        let hits = Hits()
        let library = Self.library(store: store) { request in
            let path = request.url?.path ?? ""
            hits.record(path)
            if path.hasSuffix("/manifest") { return (200, Self.manifestJSON, [:]) }
            return (200, Self.packJSON(version: "new"), ["ETag": "abc"])
        }

        await library.refresh(subject: "maths", level: .three)

        // No cache is not "unchanged": there is nothing to compare and
        // everything to fetch.
        #expect(hits.count("/content/maths/3") == 1)
        #expect(store.load(subject: "maths", level: .three)?.pack?.version == "new")
    }

    @Test("a refresh that cannot reach the server changes nothing")
    func refreshIsBestEffort() async throws {
        let store = MemoryPackStore()
        store.seed(CachedPack(
            data: Self.packJSON(version: "cached"), subject: "maths",
            level: .three, etag: "\"abc\"", storedAt: 1))

        let library = Self.library(store: store) { _ in
            (503, Data(#"{"error":"nope"}"#.utf8), [:])
        }

        // Never throws and never clears: a refresh is an optimisation, and a
        // failed one leaves the child exactly as playable as before.
        await library.refresh(subject: "maths", level: .three)

        #expect(store.load(subject: "maths", level: .three)?.pack?.version == "cached")
        #expect(store.saves == 0)
    }

    @Test("a refresh for a level the manifest does not carry fetches nothing")
    func refreshIgnoresAnUnknownLevel() async throws {
        let store = MemoryPackStore()
        let hits = Hits()
        let library = Self.library(store: store) { request in
            let path = request.url?.path ?? ""
            hits.record(path)
            if path.hasSuffix("/manifest") { return (200, Self.manifestJSON, [:]) }
            return (200, Self.packJSON(version: "new"), ["ETag": "abc"])
        }

        // The manifest carries maths/3 and nothing else. A level the server
        // does not serve is not a level worth guessing at.
        await library.refresh(subject: "maths", level: .six)

        #expect(hits.count("/content/maths/6") == 0)
        #expect(store.load(subject: "maths", level: .six) == nil)
    }

    /// A box for a value written inside a stub handler.
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
