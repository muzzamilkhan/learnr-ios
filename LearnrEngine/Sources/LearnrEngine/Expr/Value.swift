import Foundation

/// A value the expression language can produce: number, string or boolean.
///
/// Numbers are `Double` throughout, exactly as JavaScript's are — there is no
/// integer type in this language. `isInt(2^70)` is true because any double with
/// no fractional part is an "integer" here.
public enum Value: Equatable, Sendable {
    case number(Double)
    case string(String)
    case boolean(Bool)

    /// JavaScript truthiness. `""` is falsy but `"0"` is **truthy**, which is
    /// the trap: a template writing `x ? a : b` over a string variable behaves
    /// differently from the same expression over a number.
    var truthy: Bool {
        switch self {
        case .boolean(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        }
    }

    /// The name JavaScript's `typeof` would give, used verbatim in error
    /// messages so they match the web app's.
    var typeName: String {
        switch self {
        case .number: return "number"
        case .string: return "string"
        case .boolean: return "boolean"
        }
    }

    /// JavaScript's `String(value)`.
    ///
    /// This is not cosmetic: it is what renders into every prompt a child
    /// reads, and what de-duplicates multiple-choice options. `2.0` must
    /// become "2", not "2.0", or the web app and the app disagree about the
    /// text of a question.
    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .boolean(let b): return b ? "true" : "false"
        case .number(let n): return JSNumber.toString(n)
        }
    }
}

public enum ExprError: Error, CustomStringConvertible, Equatable {
    case unexpectedCharacter(String, Int)
    case unterminatedString(Int)
    case unexpectedEnd(String)
    case unexpectedToken(String, Int, String)
    case expected(String, Int, String)
    case unknownVariable(String)
    case unknownFunction(String)
    case variableWrongType(String)
    case operatorNeedsNumbers(String, String)
    case functionNeedsNumbers(name: String, got: String, argument: Int)
    case emptyReduce(String)

    public var description: String {
        switch self {
        case .unexpectedCharacter(let c, let pos):
            return "Unexpected character \(jsonQuote(c)) at position \(pos)"
        case .unterminatedString(let pos):
            return "Unterminated string starting at position \(pos)"
        case .unexpectedEnd(let src):
            return "Unexpected end of expression at position \(src.count) in \(jsonQuote(src))"
        case .unexpectedToken(let v, let pos, let src):
            return "Unexpected token \(jsonQuote(v)) at position \(pos) in \(jsonQuote(src))"
        case .expected(let v, let pos, let src):
            return "Expected \(jsonQuote(v)) at position \(pos) in \(jsonQuote(src))"
        case .unknownVariable(let name): return "Unknown variable: \(name)"
        case .unknownFunction(let name): return "Unknown function: \(name)"
        case .variableWrongType(let name):
            return "Variable \(name) is not a number, string or boolean"
        case .operatorNeedsNumbers(let op, let got):
            return "Operator \(op) expects numbers, got \(got)"
        case .functionNeedsNumbers(let name, let got, let argument):
            return "\(name)() expects numbers, got \(got) at argument \(argument)"
        case .emptyReduce(let name):
            return "\(name): Reduce of empty array with no initial value"
        }
    }
}

func jsonQuote(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}
