import Testing
import Foundation
@testable import LearnrEngine

/// The vectors come from running the real `src/lib/expr` under tsx. Where a
/// case below looks surprising, the surprise is the TypeScript's and this port
/// is required to reproduce it.
struct ExprTests {

    struct Vector: Decodable {
        let src: String
        let scope: [String: JSONValue]
        let value: JSONValue?
        let type: String?
        let str: String?
        let error: String?
    }

    /// Just enough of a JSON value to carry a scope entry or an expected result.
    enum JSONValue: Decodable, Equatable {
        case number(Double), string(String), boolean(Bool)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .boolean(b); return }
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            self = .string(try c.decode(String.self))
        }

        var asValue: Value {
            switch self {
            case .number(let d): return .number(d)
            case .string(let s): return .string(s)
            case .boolean(let b): return .boolean(b)
            }
        }
    }

    static let vectors: [Vector] = {
        let url = Bundle.module.url(forResource: "Vectors/expr-vectors", withExtension: "json")!
        return try! JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }()

    @Test("every vector from the TypeScript evaluator reproduces exactly")
    func matchesOracle() throws {
        var checked = 0

        for vector in Self.vectors {
            let scope = vector.scope.mapValues(\.asValue)

            if vector.error != nil {
                #expect(throws: (any Error).self, "\(vector.src) should throw") {
                    try evaluate(vector.src, scope)
                }
                checked += 1
                continue
            }

            let actual = try evaluate(vector.src, scope)

            // The generator stringifies non-finite numbers, since JSON has no
            // way to carry Infinity or NaN.
            if case .string(let s) = vector.value!, s == "Infinity" || s == "-Infinity" || s == "NaN" {
                guard case .number(let n) = actual else {
                    Issue.record("\(vector.src): expected a number, got \(actual)")
                    continue
                }
                switch s {
                case "Infinity":  #expect(n == .infinity, "\(vector.src)")
                case "-Infinity": #expect(n == -.infinity, "\(vector.src)")
                default:          #expect(n.isNaN, "\(vector.src)")
                }
                checked += 1
                continue
            }

            #expect(actual == vector.value!.asValue,
                    "\(vector.src) gave \(actual), want \(vector.value!)")

            // The rendered form matters as much as the value: this is the text
            // that reaches a child inside a prompt.
            if let expectedString = vector.str {
                #expect(actual.stringValue == expectedString,
                        "\(vector.src) rendered \(actual.stringValue), want \(expectedString)")
            }
            checked += 1
        }

        #expect(checked == Self.vectors.count)
        #expect(checked >= 80, "the vector file looks truncated")
    }

    // The cases below duplicate vectors deliberately: each is a place where a
    // reasonable Swift implementation diverges, and a named test says why far
    // better than a row in a JSON file.

    @Test("unary minus binds tighter than * but looser than ^")
    func unaryBindingPower() throws {
        #expect(try evaluate("-2 ^ 2") == .number(-4))   // not 4
        #expect(try evaluate("- - 3") == .number(3))
        #expect(try evaluate("2 ^ -1") == .number(0.5))
    }

    @Test("^ is right associative")
    func exponentAssociativity() throws {
        #expect(try evaluate("2 ^ 3 ^ 2") == .number(512))
        #expect(try evaluate("(2 ^ 3) ^ 2") == .number(64))
    }

    @Test("&& and || yield booleans, not the operand")
    func logicalOperatorsReturnBooleans() throws {
        #expect(try evaluate("1 && 2") == .boolean(true))
        #expect(try evaluate("x || y", ["x": .number(0), "y": .number(5)]) == .boolean(true))
        #expect(try evaluate("true && 0") == .boolean(false))
    }

    @Test("&& and || short-circuit, so a bad right side is never reached")
    func shortCircuit() throws {
        #expect(try evaluate("false && missing") == .boolean(false))
        #expect(try evaluate("true || missing") == .boolean(true))
        #expect(throws: (any Error).self) { try evaluate("true && missing") }
    }

    @Test("equality is strict; there is no coercion")
    func strictEquality() throws {
        #expect(try evaluate("'2' == 2") == .boolean(false))
        #expect(try evaluate("1 == true") == .boolean(false))
        #expect(try evaluate("2 == 2.0") == .boolean(true))
    }

    @Test("relational operators refuse strings rather than comparing them")
    func relationalNeedsNumbers() throws {
        #expect(throws: (any Error).self) { try evaluate("'a' < 'b'") }
        #expect(throws: (any Error).self) { try evaluate("true < false") }
    }

    @Test("% is remainder but mod() is floored modulo")
    func remainderVersusModulo() throws {
        #expect(try evaluate("-7 % 3") == .number(-1))
        #expect(try evaluate("mod(-7, 3)") == .number(2))
        #expect(try evaluate("7 % -3") == .number(1))
        #expect(try evaluate("mod(7, -3)") == .number(-2))
    }

    @Test("\"0\" is truthy even though 0 is not")
    func stringTruthiness() throws {
        #expect(try evaluate("!x", ["x": .string("0")]) == .boolean(false))
        #expect(try evaluate("!x", ["x": .number(0)]) == .boolean(true))
        #expect(try evaluate("!x", ["x": .string("")]) == .boolean(true))
    }

    @Test("division by zero is a value, not an error")
    func divisionByZero() throws {
        guard case .number(let inf) = try evaluate("3 / 0") else { Issue.record("not a number"); return }
        #expect(inf == .infinity)
        guard case .number(let nan) = try evaluate("0 / 0") else { Issue.record("not a number"); return }
        #expect(nan.isNaN)
    }

    @Test("the scope cannot reach anything it was not given")
    func noPrototypeEscape() throws {
        for name in ["constructor", "__proto__", "toString", "process", "hasOwnProperty"] {
            #expect(throws: (any Error).self, "\(name) should not resolve") {
                try evaluate(name, ["x": .number(1)])
            }
        }
        #expect(throws: (any Error).self) { try evaluate("constructor(1)") }
    }

    @Test("malformed input throws rather than guessing")
    func malformedInput() throws {
        for src in ["1 +", "(1 + 2", "1 2", "", "1 = 2", "x +* y", "'unterminated", "+5"] {
            #expect(throws: (any Error).self, "\(src.debugDescription) should throw") {
                try evaluate(src, ["x": .number(1), "y": .number(2)])
            }
        }
    }

    @Test("a parse error names the source it failed in")
    func parseErrorCarriesSource() {
        do {
            _ = try evaluate("x +* y")
            Issue.record("should have thrown")
        } catch {
            #expect("\(error)".contains("x +* y"))
        }
    }

    @Test("compile parses once and reuses the tree")
    func compileReusesTree() throws {
        let fn = try compile("x + y")
        #expect(try fn(["x": .number(1), "y": .number(2)]) == .number(3))
        #expect(try fn(["x": .number(10), "y": .number(20)]) == .number(30))
    }

    @Test("ternaries nest to the right")
    func ternaryNesting() throws {
        #expect(try evaluate("1 ? 2 : 3 ? 4 : 5") == .number(2))
        #expect(try evaluate("1 ? 2 ? 3 : 4 : 5") == .number(3))
        #expect(try evaluate("0 ? 2 : 3 ? 4 : 5") == .number(4))
    }
}
