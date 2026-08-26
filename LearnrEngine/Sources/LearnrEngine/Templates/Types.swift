import Foundation

/// Question templates, ported from `src/lib/templates/types.ts` in the web app.
///
/// Templates are data: authored outside the app and expanded into concrete
/// questions at runtime. Every numeric field is an *expression string*, not a
/// number, so a bound can depend on a variable bound earlier — which is why
/// `min` and `max` below are `Expr` and not `Double`.
///
/// These decode directly from the content packs the API serves at
/// `GET /content/:subject/:level`, so the `CodingKeys` and the optionality of
/// each field track that JSON rather than what would be tidiest in Swift.

/// An expression string, evaluated against the variables bound so far.
public typealias Expr = String

/// Four is the most options that stay legible and thumb-sized on an iPad.
public let maxChoices = 4

/// A value a `pick` variable can offer: the JSON allows numbers or strings.
public enum PickValue: Equatable, Sendable, Decodable {
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    /// As an expression `Value`, which is what a bound variable becomes.
    var value: Value {
        switch self {
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        }
    }
}

/// A variable the engine binds before rendering the prompt.
///
/// Modelled as an enum with associated values rather than a struct of optionals
/// so that a `pick` cannot carry a `step` and an `int` cannot carry a `from` —
/// the TypeScript union says the same thing, and flattening it here would let
/// the port accept templates the web app would reject.
public enum VarSpec: Sendable, Decodable {
    /// Integer drawn from `[min, max]`. Bounds are expressions, so `max: "x - 1"` works.
    case int(name: String, min: Expr, max: Expr, step: Double?)
    /// Decimal drawn from `[min, max]`, rounded to `decimals` places (default 2).
    case number(name: String, min: Expr, max: Expr, decimals: Int?)
    /// Drawn from a fixed list, optionally weighted.
    case pick(name: String, from: [PickValue], weights: [Double]?)
    /// Derived from variables already bound. Never random.
    case expr(name: String, expr: Expr)

    public var name: String {
        switch self {
        case .int(let name, _, _, _),
             .number(let name, _, _, _),
             .pick(let name, _, _),
             .expr(let name, _):
            return name
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, min, max, step, decimals, from, weights, expr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let kind = try c.decode(String.self, forKey: .kind)

        switch kind {
        case "int":
            self = .int(
                name: name,
                min: try c.decode(Expr.self, forKey: .min),
                max: try c.decode(Expr.self, forKey: .max),
                step: try c.decodeIfPresent(Double.self, forKey: .step)
            )
        case "number":
            self = .number(
                name: name,
                min: try c.decode(Expr.self, forKey: .min),
                max: try c.decode(Expr.self, forKey: .max),
                decimals: try c.decodeIfPresent(Int.self, forKey: .decimals)
            )
        case "pick":
            self = .pick(
                name: name,
                from: try c.decode([PickValue].self, forKey: .from),
                weights: try c.decodeIfPresent([Double].self, forKey: .weights)
            )
        case "expr":
            self = .expr(name: name, expr: try c.decode(Expr.self, forKey: .expr))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown variable kind \(kind.debugDescription)"
            )
        }
    }
}

/// How the child answers.
///
/// `boolean` is true/false — the play screen renders two fixed buttons, so it
/// needs no `choices` of its own.
public enum AnswerType: String, Sendable, Codable {
    case number, text, choice, boolean
}

/// The correct answer, or one of the options offered beside it.
public enum Answer: Equatable, Sendable {
    case number(Double)
    case string(String)
    case boolean(Bool)

    init(_ value: Value) {
        switch value {
        case .number(let n): self = .number(n)
        case .string(let s): self = .string(s)
        case .boolean(let b): self = .boolean(b)
        }
    }

    /// JavaScript's `String(value)` — what de-duplicates choices and what a
    /// child reads. `2.0` becomes `"2"`, not `"2.0"`.
    public var stringValue: String {
        switch self {
        case .number(let n): return JSNumber.toString(n)
        case .string(let s): return s
        case .boolean(let b): return b ? "true" : "false"
        }
    }
}

public struct ChoiceSpec: Sendable, Decodable {
    /// Total options shown, including the correct one. At most `maxChoices`.
    public let count: Int
    /// Expressions producing plausible wrong answers. Duplicates and values
    /// equal to the correct answer are dropped; the engine tops up from `jitter`.
    public let distractors: [Expr]?
    /// Fallback distractor generator: the answer plus or minus a random offset.
    public let jitter: Jitter?
    /// Declared by the author to suppress a validation check. Carried so a
    /// round-trip preserves it; the engine itself never reads either flag.
    public let rankIsTheQuestion: Bool?
    public let propertyIsTheQuestion: Bool?

    public struct Jitter: Sendable, Decodable {
        public let min: Expr
        public let max: Expr
    }
}

/// Everything it takes to make a question, and nothing about who is being asked.
///
/// The split from `QuestionTemplate` exists because a speed run has no school
/// year and no curriculum topic.
public struct QuestionSpec: Sendable, Decodable {
    /// Prompt with `{expression}` holes, e.g. `"What is {x} + {y}?"`.
    public let prompt: String
    public let vars: [VarSpec]
    /// Boolean expressions every binding must satisfy.
    public let constraints: [Expr]?
    /// Expression producing the correct answer. A boolean result makes it true/false.
    public let answer: Expr
    /// Defaults to what `answer` evaluates to: number, boolean, or otherwise text.
    public let answerType: AnswerType?
    public let choices: ChoiceSpec?
    /// Optional hint, also supports `{expression}` holes.
    public let hint: String?

    /// The diagram the question is about, or shown alongside it.
    ///
    /// Optional and rare — most questions are a sentence with a hole in it, and
    /// this is the escape hatch for the ones that are a picture instead. It
    /// lives on the spec beside `choices` rather than on the template, because
    /// it is a property of the question and not of where it sits in a course.
    public let figure: FigureSpec?

    /// Whether the template carries a figure.
    public var hasFigure: Bool { figure != nil }

    private enum CodingKeys: String, CodingKey {
        case prompt, vars, constraints, answer, answerType, choices, hint, figure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        vars = try c.decode([VarSpec].self, forKey: .vars)
        constraints = try c.decodeIfPresent([Expr].self, forKey: .constraints)
        answer = try c.decode(Expr.self, forKey: .answer)
        answerType = try c.decodeIfPresent(AnswerType.self, forKey: .answerType)
        choices = try c.decodeIfPresent(ChoiceSpec.self, forKey: .choices)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        figure = try c.decodeIfPresent(FigureSpec.self, forKey: .figure)
    }
}

/// A spec placed in a course: who is being asked, and what it practises.
public struct QuestionTemplate: Sendable, Decodable {
    public let id: String
    public let subject: String
    /// What this question practises, e.g. `"counting numbers"`. Topics are
    /// shared across years, so a topic is a tag on the template.
    public let topic: String
    /// The Australian school year this template was written for, as it appears
    /// on the wire: `"K"` or `"1"` through `"6"`.
    public let level: String
    public let tags: [String]?
    public let spec: QuestionSpec

    private enum CodingKeys: String, CodingKey {
        case id, subject, topic, level, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        subject = try c.decode(String.self, forKey: .subject)
        topic = try c.decode(String.self, forKey: .topic)
        level = try c.decode(String.self, forKey: .level)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        // The template *is* the spec, with four extra fields — the TypeScript
        // has `QuestionTemplate extends QuestionSpec`. Decoding the same
        // container twice is what models that without repeating the fields.
        spec = try QuestionSpec(from: decoder)
    }
}

/// A spec expanded, with nothing yet saying who was asked.
public struct GeneratedQuestion: Sendable, Equatable {
    public let prompt: String
    public let answer: Answer
    public let answerType: AnswerType
    /// Only for `choice` questions; true/false renders its own buttons.
    public let choices: [Answer]?
    public let hint: String?
    /// The bound variables, kept for debugging and analytics.
    public let vars: [String: Answer]
    /// Present exactly when the spec carried a figure — resolved from the same
    /// scope and `Rng` as everything else in the question.
    public let figure: Figure?
}

/// A template expanded into something a child can actually be shown.
public struct Question: Sendable, Equatable {
    public let templateId: String
    public let subject: String
    public let topic: String
    public let level: String
    public let question: GeneratedQuestion
}

/// One content pack: every template for one subject at one year level.
public struct ContentPack: Sendable, Decodable {
    public let version: String
    public let subject: String
    public let level: String
    public let templates: [QuestionTemplate]
}
