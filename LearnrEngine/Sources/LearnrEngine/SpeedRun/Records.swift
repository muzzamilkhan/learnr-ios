import Foundation

/// A first run is not a record.
///
/// Ported from `src/lib/speedrun/records.ts`. It makes a personal best mean
/// somebody improved, and it stops a child working through the modes from firing
/// twenty-six notifications at their parent in an afternoon. The cost is that
/// the very first run has nothing to celebrate, which is why the result screen
/// has a third thing to say rather than two — "that's your score to beat" is
/// honest where a fanfare would be invented.

/// Which of the three things the result screen says.
public enum ResultTone: String, Sendable, Equatable {
    case first, record, short
}

public enum SpeedRecords {

    public static func isRecord(previousBest: Int?, score: Int) -> Bool {
        guard let previousBest else { return false }
        return score > previousBest
    }

    public static func resultTone(previousBest: Int?, score: Int) -> ResultTone {
        guard let previousBest else { return .first }
        return score > previousBest ? .record : .short
    }
}
