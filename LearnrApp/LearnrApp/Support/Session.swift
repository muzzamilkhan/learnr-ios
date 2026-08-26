import Foundation
import Observation
import LearnrEngine

/// Who is signed in, and the queue of what they have played.
///
/// One object because the two are the same question in practice: a child is
/// signed in, and everything they answer is held here until it reaches the
/// server.
@MainActor
@Observable
final class Session {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(Account)
    }

    private(set) var state: State = .loading
    private(set) var pendingAttempts = 0

    /// The year level this child plays at.
    ///
    /// A managed child's level is their parent's to set, so this is read from
    /// the server rather than chosen here. Three is the fallback for a child
    /// whose level has never been set or cannot be read - a middle of the range
    /// rather than an end of it, so a wrong guess is wrong by less.
    private(set) var level: YearLevel = .three

    /// Reads the stored level. Best-effort: a failure leaves the fallback.
    func refreshLevel() async {
        guard let play = try? await api.playState(level: level),
              let stored = play.player.selectedLevel,
              let parsed = YearLevel(rawValue: stored)
        else { return }
        level = parsed
    }

    let api: ApiClient
    let queue: SyncQueue
    let library: ContentLibrary

    init(baseURL: URL) {
        let tokens = KeychainTokenStore()
        let store = FileSittingStore(url: Self.queueURL)
        self.api = ApiClient(baseURL: baseURL, tokens: tokens)
        self.queue = SyncQueue(api: api, store: store)
        self.library = ContentLibrary(api: api, store: FilePackStore(directory: Self.packsURL))
    }

    /// Cached content packs. Beside the queue in Application Support, which is
    /// where data the app can rebuild but should not lose belongs.
    private static var packsURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
        return directory.appendingPathComponent("content-packs", isDirectory: true)
    }

    private static var queueURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pending-sittings.json")
    }

    /// Called at launch. A token that no longer resolves signs the child out
    /// rather than leaving them staring at a screen that cannot load.
    func restore() async {
        guard await api.isSignedIn else {
            state = .signedOut
            return
        }

        do {
            state = .signedIn(try await api.me())
            await sync()
        } catch ApiError.unauthorised {
            await api.signOut()
            state = .signedOut
        } catch {
            // Offline at launch is ordinary, not a reason to sign out: the
            // token is still good and play does not need the network.
            state = .signedOut
        }
    }

    func signIn(code: String) async throws {
        _ = try await api.redeem(code: code)
        state = .signedIn(try await api.me())
        await sync()
    }

    func signOut() async {
        await api.signOut()
        state = .signedOut
    }

    /// Best-effort, always. A failed sync costs history, never the question in
    /// front of the child.
    func sync() async {
        _ = await queue.flush()
        pendingAttempts = await queue.pendingAttemptCount
    }

    func refreshPendingCount() async {
        pendingAttempts = await queue.pendingAttemptCount
    }
}
