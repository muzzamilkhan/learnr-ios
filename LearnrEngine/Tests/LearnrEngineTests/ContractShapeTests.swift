import Testing
import Foundation
@testable import LearnrEngine

/// What the hand-written half of `Models.swift` promises about the generated
/// half.
///
/// Almost every wire type is now an alias for a generated one (`L1`), so it
/// cannot drift from the contract - the compiler regenerates it on each build.
/// `YearLevel` is the deliberate exception: it stays hand-written because the
/// generated enum spells its cases `_3`, carries neither `label` nor
/// `schoolOrder`, and exists twice - once for what the server sends and once
/// for what it accepts.
///
/// That exception is the only place a contract change can pass the compiler and
/// still be wrong, so it is the one place that needs a test. A year added,
/// removed or respelled in the document reddens here, at a name, rather than on
/// a device as a decode that returns nil.
@Suite
struct ContractShapeTests {

    @Test("YearLevel is exactly the contract's, case for case")
    func matchesTheContract() {
        let ours = Set(YearLevel.allCases.map(\.rawValue))
        let theirs = Set(Components.Schemas.YearLevel.allCases.map(\.rawValue))

        // Both directions on purpose. A missing case is a level that fails to
        // decode; an extra one is a level the app can offer and the server will
        // reject.
        #expect(ours == theirs)
    }

    @Test("the read and write enums agree, so `input` cannot lose a level")
    func readAndWriteAgree() {
        // The contract declares two - `YearLevel` for responses and
        // `YearLevelInput` for request bodies. `YearLevel.input` force-unwraps
        // across them, which is safe exactly as long as this holds.
        let read = Set(Components.Schemas.YearLevel.allCases.map(\.rawValue))
        let write = Set(Components.Schemas.YearLevelInput.allCases.map(\.rawValue))

        #expect(read == write)
    }

    @Test("every level converts to its write form")
    func everyLevelConverts() {
        // `input` is the force-unwrap the two tests above justify. This is the
        // one that would actually trap, so it runs the whole set rather than
        // trusting the argument.
        for level in YearLevel.allCases {
            #expect(level.input.rawValue == level.rawValue)
        }
    }

    @Test("schoolOrder holds every level, K first")
    func schoolOrderIsComplete() {
        // The product ordering, which the contract does not carry: it lists `K`
        // last. A level added to the enum and forgotten here would simply not
        // appear in a picker.
        #expect(Set(YearLevel.schoolOrder) == Set(YearLevel.allCases))
        #expect(YearLevel.schoolOrder.count == YearLevel.allCases.count)
        #expect(YearLevel.schoolOrder.first == .k)
        #expect(YearLevel.schoolOrder.dropFirst().map(\.rawValue) == ["1", "2", "3", "4", "5", "6"])
    }

    @Test("an unread account is not a managed child")
    func unreadIsNotAManagedChild() {
        // `role` is an `allOf`-wrapped `$ref` and reads through `value1`
        // (`L24`). The affirmative must come from the server: a launch that
        // could not reach it knows a child is signed in and does not know they
        // are managed.
        #expect(!Account.unread.isManagedChild)

        let child = Account(id: "c", role: .init(value1: .child), parentId: "p")
        #expect(child.isManagedChild)

        // A child with no parent is not managed, and a parent is not a child.
        #expect(!Account(id: "c", role: .init(value1: .child)).isManagedChild)
        #expect(!Account(id: "p", role: .init(value1: .parent), parentId: "p").isManagedChild)

        // A null role decodes to nil rather than throwing - the whole point of
        // dropping the six from `required`.
        #expect(!Account(id: "c", role: nil, parentId: "p").isManagedChild)
    }

    @Test("the six nullable refs decode from a real null")
    func nullableRefsDecodeFromNull() throws {
        // The `L24` blocker, pinned. These are `allOf`-wrapped `$ref`s that sat
        // in `required` until `376908e`, which made the generator emit them
        // non-optional so a null threw. `PlayerState.target` and
        // `SpeedOutcome.standing` are null on the ordinary path - a child with
        // no target set, a run that placed nowhere - so this is the case that
        // would have shipped broken rather than an edge.
        let player = try ApiCoding.decoder().decode(
            PlayerState.self,
            from: Data(#"{"selectedLevel":"3","streak":{"days":0,"lastDay":null},"stars":0,"target":null,"targetDay":null}"#.utf8))
        #expect(player.target == nil)

        let outcome = try ApiCoding.decoder().decode(
            SpeedOutcome.self,
            from: Data(#"{"previousBest":null,"best":4,"isRecord":true,"standing":null}"#.utf8))
        #expect(outcome.standing == nil)

        let account = try ApiCoding.decoder().decode(
            Account.self,
            from: Data(#"{"id":"c","role":null,"parentId":null,"name":null,"avatar":null,"image":null,"photo":null}"#.utf8))
        #expect(account.role == nil)
        #expect(account.avatar == nil)
    }
}
