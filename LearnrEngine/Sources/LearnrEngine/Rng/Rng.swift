import Foundation

/// Deterministic PRNG, ported from `src/lib/rng.ts` in the web app.
///
/// This is the single most drift-prone file in the port: the whole content
/// pipeline is seeded, so one wrong bit here and *every* question differs from
/// the web app's. It is written to match the JavaScript exactly rather than
/// idiomatically, and `RngTests` checks it against vectors generated from the
/// TypeScript source itself.
///
/// The JavaScript relies on `Math.imul` and `>>> 0` for wrapping unsigned
/// 32-bit arithmetic. Swift's `UInt32` with `&*` and `&+` is the same thing,
/// which is why the port is mechanical.
public struct Rng {
    private var state: UInt32

    public init(seed: String) {
        self.state = Rng.hashSeed(seed)
    }

    /// FNV-1a over UTF-16 code units.
    ///
    /// The JavaScript uses `charCodeAt`, which yields UTF-16 code units, not
    /// Unicode scalars and not bytes. Seeds in practice are UUIDs and strings
    /// like `"\(seed):\(draw)"`, so they are ASCII and the distinction never
    /// bites - but it is written the JS way so that it cannot bite later.
    static func hashSeed(_ seed: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for unit in seed.utf16 {
            h ^= UInt32(unit)
            h = h &* 16777619
        }
        return h
    }

    /// mulberry32. Float in [0, 1).
    public mutating func next() -> Double {
        state = state &+ 0x6d2b79f5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        let result = t ^ (t >> 14)

        // 4294967296 is 2^32: the JS divides by it to land in [0, 1).
        return Double(result) / 4294967296.0
    }

    /// Integer in [min, max], inclusive at both ends.
    public mutating func int(_ min: Int, _ max: Int) -> Int {
        precondition(max >= min, "Invalid range: min \(min) is greater than max \(max)")
        return min + Int(floor(next() * Double(max - min + 1)))
    }

    /// One item, uniformly. Traps on an empty list, as the JS throws.
    public mutating func pick<T>(_ items: [T]) -> T {
        precondition(!items.isEmpty, "Cannot pick from an empty list")
        return items[int(0, items.count - 1)]
    }
}
