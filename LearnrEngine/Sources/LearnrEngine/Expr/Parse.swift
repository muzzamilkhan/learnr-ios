import Foundation

public indirect enum Node: Equatable {
    case num(Double)
    case str(String)
    case bool(Bool)
    case variable(String)
    case unary(op: String, operand: Node)
    case binary(op: String, left: Node, right: Node)
    case ternary(test: Node, then: Node, other: Node)
    case call(name: String, args: [Node])
}

/// Binding power per binary operator. Higher binds tighter.
///
/// Doubled from the TypeScript's 1-7 so that unary's 6.5 can stay an integer:
/// there it is written as a literal 6.5, sitting between `*` (6) and `^` (7).
/// Keeping it representable is what makes `-2 ^ 2` evaluate to -4 rather
/// than 4, which is the behaviour the content was authored against.
private let binaryPrecedence: [String: Int] = [
    "||": 2,
    "&&": 4,
    "==": 6, "!=": 6,
    "<": 8, "<=": 8, ">": 8, ">=": 8,
    "+": 10, "-": 10,
    "*": 12, "/": 12, "%": 12,
    "^": 14,
]

/// Unary binds tighter than everything except `^`.
private let unaryPrecedence = 13

private let rightAssociative: Set<String> = ["^"]

public func parse(_ src: String) throws -> Node {
    let tokens = try tokenize(src)
    var i = 0

    func peek() -> Token { tokens[i] }
    func advance() -> Token { defer { i += 1 }; return tokens[i] }

    func expect(_ value: String) throws -> Token {
        let token = peek()
        if token.value != value || token.kind == .eof {
            throw ExprError.expected(value, token.pos, src)
        }
        return advance()
    }

    func parsePrimary() throws -> Node {
        let token = peek()

        switch token.kind {
        case .eof:
            throw ExprError.unexpectedEnd(src)

        case .number:
            _ = advance()
            return .num(Double(token.value) ?? 0)

        case .string:
            _ = advance()
            return .str(token.value)

        case .ident:
            _ = advance()
            // A call is an identifier immediately followed by `(`.
            if peek().kind == .punc && peek().value == "(" {
                _ = advance()
                var args: [Node] = []
                if !(peek().kind == .punc && peek().value == ")") {
                    while true {
                        args.append(try parseExpression(0))
                        if peek().kind == .punc && peek().value == "," { _ = advance(); continue }
                        break
                    }
                }
                _ = try expect(")")
                return .call(name: token.value, args: args)
            }
            // `true` and `false` are keywords only when not called. `true(1)`
            // parses as a call and fails later as an unknown function, which
            // is what the web app does.
            if token.value == "true" { return .bool(true) }
            if token.value == "false" { return .bool(false) }
            return .variable(token.value)

        case .op:
            // There is no unary `+`.
            if token.value == "-" || token.value == "!" {
                _ = advance()
                return .unary(op: token.value, operand: try parseExpression(unaryPrecedence))
            }
            throw ExprError.unexpectedToken(token.value, token.pos, src)

        case .punc:
            if token.value == "(" {
                _ = advance()
                let inner = try parseExpression(0)
                _ = try expect(")")
                return inner
            }
            throw ExprError.unexpectedToken(token.value, token.pos, src)
        }
    }

    func parseExpression(_ minPrecedence: Int) throws -> Node {
        var left = try parsePrimary()

        while true {
            let token = peek()

            // The ternary is not a precedence level: it is only recognised at
            // the top of an expression, inside parentheses, in a call
            // argument, or in another ternary's branch. So `1 + a ? b : c`
            // groups as `(1 + a) ? b : c`.
            if token.kind == .op && token.value == "?" && minPrecedence <= 0 {
                _ = advance()
                let then = try parseExpression(0)
                _ = try expect(":")
                let other = try parseExpression(0)
                left = .ternary(test: left, then: then, other: other)
                continue
            }

            guard token.kind == .op,
                  let precedence = binaryPrecedence[token.value],
                  precedence >= minPrecedence
            else { break }

            _ = advance()
            let nextMin = rightAssociative.contains(token.value) ? precedence : precedence + 1
            let right = try parseExpression(nextMin)
            left = .binary(op: token.value, left: left, right: right)
        }

        return left
    }

    let node = try parseExpression(0)

    // Anything left over is an error: `1 2` does not parse.
    let trailing = peek()
    if trailing.kind != .eof {
        throw ExprError.unexpectedToken(trailing.value, trailing.pos, src)
    }

    return node
}
