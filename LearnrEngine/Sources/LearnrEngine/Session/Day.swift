import Foundation

/// Which day a moment falls in, in the child's terms.
///
/// Ported from `src/lib/day.ts`. Everything that counts days — mastery on
/// separate days, a play streak, the report's buckets — has to agree on where a
/// day starts, and it is never the server's midnight. An evening's practice in
/// Sydney is that evening, not the next morning UTC, so the offset the answer
/// was given at travels with it.
public enum Day {

    public static let dayMs = 24 * 60 * 60 * 1000

    /// Whole days since the epoch, shifted into the caller's local time.
    ///
    /// The floor is the trap. JavaScript's `Math.floor` rounds towards −∞, and
    /// so does Swift's `floor` — but integer division in Swift truncates
    /// towards zero, so `(-1) / 86_400_000` is `0` where this must be `-1`.
    /// Written through `Double` and `floor` for that reason, and pinned by the
    /// three negative vectors. This is the same negative-half divergence as
    /// `round(-2.5)` and the arc sweep, in a third place.
    public static func localDay(_ at: Int, _ offsetMinutes: Int = 0) -> Int {
        Int(floor(Double(at + offsetMinutes * 60_000) / Double(dayMs)))
    }

    /// Fourteen hours, the widest a real timezone is from UTC, taken
    /// symmetrically so the bound is a day either way rather than a table of
    /// which offsets exist.
    static let offsetLimit = 14 * 60

    /// The boundary normaliser for an offset.
    ///
    /// An offset is the one part of a day question the device cannot work out
    /// for itself, and a day number computed from it is *stored* on the server.
    /// One absurd value written once would sit in the future and quietly refuse
    /// every real day after it — a child's stars gone with nothing on any screen
    /// to say why. So it is bounded here, in the one place.
    ///
    /// Non-integers are refused, matching `Number.isInteger`.
    public static func parseOffsetMinutes(_ value: Double) -> Int? {
        guard value.rounded() == value, value.isFinite else { return nil }
        let minutes = Int(value)
        return minutes < -offsetLimit || minutes > offsetLimit ? nil : minutes
    }
}
