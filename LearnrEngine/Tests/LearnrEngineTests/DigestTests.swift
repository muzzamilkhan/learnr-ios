import Testing
import Foundation
@testable import LearnrEngine

/// **The conformance gate.** The TypeScript engine is the oracle, the digests
/// are the contract, and this is the enforcement on the Swift side.
///
/// `learnr` commits one twelve-character hash per template, computed over the
/// canonical form of what its engine produced. This recomputes those hashes
/// from what *this* engine produces and compares. Drift stops being something
/// caught in review and becomes a failing test on whichever side moved.
///
/// **A digest failure names one template and nothing finer.** That is acceptable
/// only because the oracle can be asked for the detail: every failure here
/// prints the exact `npm run fixtures:emit <templateId>` that dumps the hundred
/// cases to read. Going from "this template differs" to "this field of this
/// draw differs" is one command in the sibling clone.
///
/// **Regenerating is not the fix for a red build.** The vendored digests define
/// what correct means; when one moves, the question is which engine moved and
/// whether it was meant to. Refreshing them is its own commit that says why —
/// `tools/vendor-digests.ts`, and the same rule the oracle keeps on its side.
struct DigestTests {
    /// The command that turns a red group into something readable.
    private func emitHint(_ set: String, _ group: String) -> String {
        "run `npm run fixtures:emit \(group)` in ../learnr to read the cases"
    }

    // MARK: - The gate on the vendored copy itself

    /// A half-updated vendor is the failure mode this catches: some sets
    /// refreshed and others not, where the untouched ones go on passing against
    /// hashes nobody checked. The manifest names every set and its version, so
    /// holding the files to it makes an incomplete copy fail loudly.
    @Test("the manifest covers every vendored file, at the version it names")
    func manifestCoversEveryVendoredFile() {
        #expect(!Fixtures.manifest.version.isEmpty)
        #expect(Fixtures.manifest.sets.count == 17)

        for entry in Fixtures.manifest.sets {
            let file = Fixtures.digest(set: entry.set)
            #expect(file.set == entry.set, "\(entry.set): the file names a different set")
            #expect(
                file.version == entry.version,
                "\(entry.set): vendored at \(file.version), manifest says \(entry.version) — the copy is half-updated, re-run tools/vendor-digests.ts"
            )
            #expect(
                file.groups.count == entry.groups,
                "\(entry.set): \(file.groups.count) groups vendored, manifest says \(entry.groups)"
            )
        }
    }

    /// The packs and the digests are vendored together and have to describe the
    /// same content: a template the oracle hashed but this repo does not carry
    /// would silently go unverified, which is exactly the hole the oracle's spec
    /// asks CI to close.
    @Test("every template the corpus hashes is present in the vendored packs")
    func vendoredPacksCoverTheCorpus() {
        let ids = Set(Fixtures.templates.map(\.id))
        #expect(ids.count == 507, "expected the 507 shipped templates, got \(ids.count)")

        for pack in Fixtures.packs {
            let digest = Fixtures.digest(set: "\(pack.subject).\(pack.level)")
            for group in digest.groups.keys {
                #expect(ids.contains(group), "\(group) is hashed by the oracle but not vendored here")
            }
        }
    }

    // MARK: - The corpus: 507 templates, 100 draws each

    /// Every shipped template drawn a hundred times on the seed the contract
    /// names, hashed, and compared against the oracle.
    ///
    /// This is the whole claim of the port in one test: that a question
    /// generated on the device is the question the web app would have asked.
    /// 50,500 cases, and the digest is exact — no tolerance, because both
    /// engines walk the same expression tree over IEEE 754 doubles and
    /// `String()` of each is identical once JavaScript number rendering is
    /// right. `EPSILON` belongs to grading, where it is the thing under test.
    @Test("every corpus set reproduces the oracle's digest, template for template")
    func corpusDigestsMatch() throws {
        var checked = 0

        for pack in Fixtures.packs {
            let set = "\(pack.subject).\(pack.level)"
            let oracle = Fixtures.digest(set: set)
            let draws = oracle.draws ?? 100

            for template in pack.templates {
                var cases: [String] = []
                for draw in 0..<draws {
                    var rng = Rng(seed: Fixtures.seed(template.id, draw))
                    let question = try generateQuestion(template, &rng).question
                    cases.append(try Canonical.canonicalise(Canonical.question(question)))
                }

                #expect(
                    Canonical.digest(cases) == oracle.groups[template.id],
                    "\(template.id) diverged from the oracle — \(emitHint(set, template.id))"
                )
                checked += 1
            }
        }

        #expect(checked == 507, "expected 507 templates, hashed \(checked)")
    }
}
