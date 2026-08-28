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

    /// The last account the server gave us, for a launch that cannot reach it.
    private let accounts: any AccountCache

    init(baseURL: URL) {
        let tokens = KeychainTokenStore()
        let store = FileSittingStore(url: Self.queueURL)
        self.api = ApiClient(baseURL: baseURL, tokens: tokens)
        self.queue = SyncQueue(api: api, store: store)
        self.library = ContentLibrary(api: api, store: FilePackStore(directory: Self.packsURL))
        self.accounts = FileAccountCache(url: Self.accountURL)
    }

    /// For tests: the same object wired to whatever they need to drive.
    init(api: ApiClient, queue: SyncQueue, library: ContentLibrary,
         accounts: any AccountCache = NoAccountCache()) {
        self.api = api
        self.queue = queue
        self.library = library
        self.accounts = accounts
    }

    /// Cached content packs. Beside the queue in Application Support, which is
    /// where data the app can rebuild but should not lose belongs.
    private static var packsURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
        return directory.appendingPathComponent("content-packs", isDirectory: true)
    }

    /// Beside the queue: what the app can rebuild from the server but should
    /// not lose while the server is out of reach.
    private static var accountURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("account.json")
    }

    private static var queueURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pending-sittings.json")
    }

    /// Called at launch.
    ///
    /// **Only a 401 signs a child out** (ledger `L17`). That is the one answer
    /// that means the token is dead, and it can only come from a server that
    /// actually replied. Everything else - no network, DNS, a timeout, a 5xx,
    /// the 503 `GET /me` declares for a failed account read - means *could not
    /// read*, which is a different thing from *not signed in* and must not be
    /// treated as one.
    ///
    /// The costs are wildly asymmetric, which is why this is a rule rather than
    /// a preference. A child's only way back in is a four-character code that
    /// lasts an hour and only a parent can issue, so a wrong sign-out is not an
    /// annoyance - it is being locked out of a maths app mid-term, needing to
    /// find a grown-up, which is the exact friction the login code exists to
    /// remove. Against that, staying signed in through an outage that later
    /// turns out to be a real 401 costs one sign-out, deferred to the next
    /// launch that reaches the server. Nothing is lost by waiting: a session
    /// has a hundred-year life and does not expire on a schedule, and the one
    /// thing that does kill a token - a parent removing the child - arrives as
    /// a 401 the moment the device is next online.
    func restore() async {
        guard await api.isSignedIn else {
            state = .signedOut
            return
        }

        do {
            let account = try await api.me()
            accounts.write(account)
            state = .signedIn(account)
            await sync()
        } catch ApiError.unauthorised {
            // The server answered, and it said this token is no longer anyone.
            await api.signOut()
            accounts.write(nil)
            state = .signedOut
        } catch {
            // Could not read. The token is still good and play does not need
            // the network - the packs are cached and the queue keeps what is
            // answered - so the child carries on under the account we last saw.
            //
            // Falling back to `.signedOut` here is what stranded them: it asks
            // for a code to fix a problem the code has nothing to do with.
            state = .signedIn(accounts.read() ?? Account.unread)
            await sync()
        }
    }

    func signIn(code: String) async throws {
        _ = try await api.redeem(code: code)
        let account = try await api.me()
        // Cached here as well as in `restore()`, so the very next launch
        // survives a flat network rather than having to reach the server once
        // more before it knows who this is.
        accounts.write(account)
        state = .signedIn(account)
        await sync()
    }

    func signOut() async {
        await api.signOut()
        // Forget the name with the token: the next child to use this device
        // must not be greeted as the last one.
        accounts.write(nil)
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
