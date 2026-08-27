import Foundation
import Testing
@testable import LearnrEngine

/// One committed digest file: a set name and one twelve-character hash per
/// group, where a group is a template id or a scenario name.
///
/// Every digest file has this shape — the corpus years, the expression set,
/// grading and profile folding alike — so this reads one format rather than
/// four. That uniformity is deliberate on the oracle's side (`DigestSet` in
/// `scripts/fixtures/digests.ts`) precisely so a Swift client needs one decoder.
struct DigestFile: Decodable {
    /// A hash of the file's own body, without itself. Content-addressed, like
    /// the content packs — so "a deliberate engine change bumps the version"
    /// happens by construction and there is nothing to forget.
    let version: String
    let set: String
    /// How many draws produced each group's cases, where the set draws at a
    /// fixed count. Absent for the sets that do not — the profile scenarios.
    let draws: Int?
    /// Group name to twelve hex characters.
    let groups: [String: String]
}

/// The manifest over every set, and the staleness gate for the whole vendored
/// copy.
struct DigestManifest: Decodable {
    struct Entry: Decodable {
        let set: String
        let groups: Int
        let version: String
    }

    /// A hash over the per-file versions. **This is what names a stale vendored
    /// copy.** The oracle's spec asks that a stale copy identify itself rather
    /// than passing quietly against an engine that has moved on; here that is
    /// the version sitting in the diff of a vendoring commit, plus
    /// `DigestTests.manifestCoversEveryVendoredFile`, which fails a half-updated
    /// copy rather than letting the untouched sets go on passing.
    let version: String
    let sets: [Entry]
}

/// Loading the vendored oracle and the vendored packs.
enum Fixtures {
    /// Vendored from `learnr/fixtures/digests` by `tools/vendor-digests.ts`.
    static func digest(set: String) -> DigestFile {
        let url = Bundle.module.url(forResource: "Digests/\(set)", withExtension: "json")!
        return try! JSONDecoder().decode(DigestFile.self, from: Data(contentsOf: url))
    }

    static let manifest: DigestManifest = {
        let url = Bundle.module.url(forResource: "Digests/manifest", withExtension: "json")!
        return try! JSONDecoder().decode(DigestManifest.self, from: Data(contentsOf: url))
    }()

    /// The 505 shipped templates, from the vendored content packs — the same
    /// artifact the API serves and the same one the oracle hashed.
    ///
    /// Ordered by pack and then by the order the pack declares, which is the
    /// order `allTemplates` produces on the other side. Nothing here depends on
    /// that order — every set is keyed by template id — but preserving it keeps
    /// a failure list readable in the order a person would look for it.
    static let packs: [ContentPack] = {
        Fixtures.manifest.sets
            .filter { $0.set.contains(".") }
            .compactMap { entry in
                guard let url = Bundle.module.url(forResource: "Packs/\(entry.set)", withExtension: "json")
                else { return nil }
                return try? JSONDecoder().decode(ContentPack.self, from: Data(contentsOf: url))
            }
    }()

    static let templates: [QuestionTemplate] = packs.flatMap(\.templates)

    /// **The seed string is contract, not an implementation detail**, because
    /// `createRng` hashes the string itself. It differs deliberately from how a
    /// live session seeds a draw (`sessionSeed:drawNumber`): a fixture needs a
    /// seed stable across regeneration and independent of any session.
    static func seed(_ templateId: String, _ draw: Int) -> String { "\(templateId):\(draw)" }
}
