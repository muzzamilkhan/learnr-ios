import Foundation

/// What can be speed-run. Twenty-six modes, enumerated here and never built at
/// runtime.
///
/// Ported from `src/lib/speedrun/modes.ts`. The list is closed because a record
/// is only worth beating if the mode is worth naming. A free "from" and "to"
/// range across the tables would give about sixty modes, most differing from a
/// neighbour by one table: two near-identical numbers, each set once and never
/// approached again.
///
/// Multiplication is the one operation with no difficulty axis, because the
/// times tables *are* how multiplication is drilled — asking for "hard
/// multiplication" when a child came to practise their sevens answers a
/// question nobody asked.

public enum Difficulty: String, Sendable, Equatable, CaseIterable, Codable {
    case easy, moderate, hard
}

/// A single table, a named bundle of them, or the lot.
public enum TableChoice: Sendable, Equatable, Hashable {
    case single(Int)
    case bundle2to5
    case bundle6to9
    case bundle11to12
    case all

    /// The key fragment, which is also how the TypeScript spells it: a number
    /// interpolates as its digits, a bundle as its own name.
    public var key: String {
        switch self {
        case .single(let table): return String(table)
        case .bundle2to5: return "2-5"
        case .bundle6to9: return "6-9"
        case .bundle11to12: return "11-12"
        case .all: return "all"
        }
    }

    /// The tables this choice names.
    public var tables: [Int] {
        switch self {
        case .single(let table): return [table]
        case .bundle2to5: return [2, 3, 4, 5]
        case .bundle6to9: return [6, 7, 8, 9]
        case .bundle11to12: return [11, 12]
        case .all: return Modes.tables
        }
    }
}

public enum Operation: String, Sendable, Equatable, CaseIterable, Codable {
    case add, subtract, multiply, divide, mixed
}

/// One mode. Multiplication carries tables where everything else carries a
/// difficulty — modelled as an enum rather than a struct of optionals so a
/// `multiply` cannot hold a difficulty, exactly as the TypeScript union says.
public enum Mode: Sendable, Equatable, Hashable {
    case graded(Operation, Difficulty)
    case multiply(TableChoice)

    public var op: Operation {
        switch self {
        case .graded(let op, _): return op
        case .multiply: return .multiply
        }
    }

    public var difficulty: Difficulty? {
        switch self {
        case .graded(_, let difficulty): return difficulty
        case .multiply: return nil
        }
    }

    /// The canonical key: "add.easy", "multiply.7", "multiply.2-5".
    public var key: String {
        switch self {
        case .graded(let op, let difficulty): return "\(op.rawValue).\(difficulty.rawValue)"
        case .multiply(let choice): return "multiply.\(choice.key)"
        }
    }
}

public enum Modes {

    /// The subject a speed run belongs to. Every one of the twenty-six modes is
    /// arithmetic, so a run says nothing about English.
    public static let subject = "maths"

    /// Every table there is, for the bundles and for a mixed run to draw from.
    /// 1 is not a drill and 13 is not a table.
    public static let tables = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

    /// The tables offered as a mode of their own — every one except ten.
    ///
    /// Multiplying by ten is a place-value rule rather than a fact to recall: a
    /// child who can write the digit and a nought has the whole table, so ninety
    /// seconds of it measures how fast they can type. It stays in `all`, which
    /// means all of them and would be lying otherwise, and in what a mixed run
    /// draws from, where the easy question among the hard ones is the point.
    public static let singleTables = tables.filter { $0 != 10 }

    public static let tableBundles: [TableChoice] = [
        .bundle2to5, .bundle6to9, .bundle11to12, .all,
    ]

    /// Ordered for display: the operations in `Operation.allCases` order, and
    /// within multiply the singles then the bundles then `all`.
    public static let all: [Mode] =
        Difficulty.allCases.map { .graded(.add, $0) }
        + Difficulty.allCases.map { .graded(.subtract, $0) }
        + singleTables.map { .multiply(.single($0)) }
        + tableBundles.map { .multiply($0) }
        + Difficulty.allCases.map { .graded(.divide, $0) }
        + Difficulty.allCases.map { .graded(.mixed, $0) }

    /// Built once from `all` rather than assembled from the parts of a key, so a
    /// key is only ever a mode this module actually enumerated — the same
    /// defence the expression language's variable tables use against
    /// `__proto__`, and a dictionary lookup is never a property access.
    private static let byKey: [String: Mode] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// The boundary normaliser: one place that decides a key from storage is
    /// real, so no caller has to know what the twenty-six are.
    ///
    /// A retired key — `multiply.10`, `multiply.10-12` — comes back nil and its
    /// stored record simply stops appearing.
    public static func parseMode(_ key: String) -> Mode? { byKey[key] }

    public static func parseOperation(_ op: String) -> Operation? { Operation(rawValue: op) }

    public static func modesFor(_ op: Operation) -> [Mode] { all.filter { $0.op == op } }

    /// What the chip says: "7x", "6x to 9x", "All tables", "Easy".
    public static func modeLabel(_ mode: Mode) -> String {
        switch mode {
        case .multiply(.all): return "All tables"
        case .multiply(.single(let table)): return "\(table)x"
        case .multiply(let choice):
            // A bundle keeps both ends in the same notation — "2x to 5x", not
            // "Tables 2-5" — so it reads as a run of the chips above it.
            let parts = choice.key.split(separator: "-")
            return "\(parts[0])x to \(parts[1])x"
        case .graded(_, let difficulty):
            return difficulty.rawValue.prefix(1).uppercased() + difficulty.rawValue.dropFirst()
        }
    }

    /// Each drillable table's place on the ramp: by position, so the missing ten
    /// leaves no gap between nine and eleven.
    private static let ramp: [Int: Double] = Dictionary(
        uniqueKeysWithValues: singleTables.enumerated().map {
            ($0.element, Double($0.offset) / Double(singleTables.count - 1))
        })

    /// Where a mode sits on the one difficulty ramp, 0 (easiest) to 1 (hardest).
    ///
    /// A bundle takes the mean of the tables it draws from, which puts `2-5`
    /// near the green end, `11-12` near the purple one and `all` in the middle
    /// — where it belongs, since a run of everything is not the hardest run, it
    /// is the mixed one. Ten is skipped in that mean for the reason it is not a
    /// mode: it is not a fact being recalled.
    public static func modeHardness(_ mode: Mode) -> Double {
        guard case .multiply(let choice) = mode else {
            switch mode.difficulty! {
            case .easy: return 0
            case .moderate: return 0.5
            case .hard: return 1
            }
        }

        let places = choice.tables.compactMap { ramp[$0] }
        guard !places.isEmpty else { return 0.5 }
        return places.reduce(0, +) / Double(places.count)
    }

    /// One times table, rather than a bundle of them or anything else.
    public static func isSingleTable(_ mode: Mode) -> Bool {
        if case .multiply(.single) = mode { return true }
        return false
    }

    /// What a card, a heading or a button says. The verb, not the noun.
    public static func operationLabel(_ op: Operation) -> String {
        switch op {
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .multiply: return "Multiply"
        case .divide: return "Divide"
        case .mixed: return "Mixed"
        }
    }

    /// The same operation as a *noun*, for prose rather than for a control: "a
    /// personal best in easy addition" is a sentence, and "in easy add" is not.
    public static func operationNoun(_ op: Operation) -> String {
        switch op {
        case .add: return "addition"
        case .subtract: return "subtraction"
        case .multiply: return "multiplication"
        case .divide: return "division"
        case .mixed: return "mixed questions"
        }
    }

    /// The sign on the card. Note "−" is U+2212, not a hyphen.
    public static func operationGlyph(_ op: Operation) -> String {
        switch op {
        case .add: return "+"
        case .subtract: return "−"
        case .multiply: return "×"
        case .divide: return "÷"
        case .mixed: return "?"
        }
    }
}
