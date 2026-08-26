import Foundation

struct Token: Equatable {
    enum Kind: Equatable { case number, string, ident, op, punc, eof }
    let kind: Kind
    let value: String
    let pos: Int
}

/// Operators, longest-prefix first. The order is load-bearing: the JavaScript
/// picks the first entry that matches at the cursor, so `!=` must precede `!`
/// or `a!=b` would tokenize as `!` followed by an unrecognised `=`.
private let operators = [
    "&&", "||", "==", "!=", "<=", ">=", "<", ">",
    "+", "-", "*", "/", "%", "^", "!", "?", ":",
]

func tokenize(_ src: String) throws -> [Token] {
    let chars = Array(src)
    var tokens: [Token] = []
    var i = 0

    func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
    func isIdentStart(_ c: Character) -> Bool { c == "_" || c.isLetter && c.isASCII }
    func isIdentPart(_ c: Character) -> Bool { isIdentStart(c) || isDigit(c) }

    while i < chars.count {
        let c = chars[i]

        // JS `\s`: not just ASCII spaces. A non-breaking space in an authored
        // template is whitespace to the web app, so it must be here too.
        if c.isWhitespace { i += 1; continue }

        // digits* ('.' digits*)? - no exponent, no hex. `1e3` is a number
        // followed by an identifier, which the parser then rejects.
        if isDigit(c) || (c == "." && i + 1 < chars.count && isDigit(chars[i + 1])) {
            let start = i
            while i < chars.count && isDigit(chars[i]) { i += 1 }
            if i < chars.count && chars[i] == "." {
                i += 1
                while i < chars.count && isDigit(chars[i]) { i += 1 }
            }
            tokens.append(Token(kind: .number, value: String(chars[start..<i]), pos: start))
            continue
        }

        if c == "\"" || c == "'" {
            let start = i
            let quote = c
            i += 1
            var value = ""
            while i < chars.count && chars[i] != quote {
                // The only escape is "the next character, literally". `\n` is
                // the letter n, not a newline.
                if chars[i] == "\\" && i + 1 < chars.count {
                    value.append(chars[i + 1])
                    i += 2
                } else {
                    value.append(chars[i])
                    i += 1
                }
            }
            if i >= chars.count { throw ExprError.unterminatedString(start) }
            i += 1
            tokens.append(Token(kind: .string, value: value, pos: start))
            continue
        }

        if isIdentStart(c) {
            let start = i
            while i < chars.count && isIdentPart(chars[i]) { i += 1 }
            tokens.append(Token(kind: .ident, value: String(chars[start..<i]), pos: start))
            continue
        }

        if c == "(" || c == ")" || c == "," {
            tokens.append(Token(kind: .punc, value: String(c), pos: i))
            i += 1
            continue
        }

        let rest = String(chars[i...])
        if let op = operators.first(where: { rest.hasPrefix($0) }) {
            tokens.append(Token(kind: .op, value: op, pos: i))
            i += op.count
            continue
        }

        throw ExprError.unexpectedCharacter(String(c), i)
    }

    tokens.append(Token(kind: .eof, value: "", pos: chars.count))
    return tokens
}
