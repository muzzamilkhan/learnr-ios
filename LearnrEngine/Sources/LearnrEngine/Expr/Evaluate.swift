import Foundation

public typealias Scope = [String: Value]

/// Euclid on the absolute values, matching the TypeScript's `gcd2`. Always
/// non-negative, and terminates on non-integers because the remainder shrinks.
private func gcd2(_ a: Double, _ b: Double) -> Double {
    var x = abs(a)
    var y = abs(b)
    while y != 0 && !y.isNaN {
        let t = y
        y = x.truncatingRemainder(dividingBy: y)
        x = t
    }
    return x
}

/// The function table.
///
/// Every argument must be a number - the TypeScript wraps each entry in a
/// `numeric()` helper that throws otherwise, with a 1-based argument index in
/// the message. Arity is *not* checked anywhere, so the odd cases below
/// (`min()` is Infinity, `abs()` is NaN) are reproduced rather than fixed:
/// content was authored against them.
enum Functions {
    static let names: Set<String> = [
        "abs", "min", "max", "floor", "ceil", "round", "trunc", "sign",
        "sqrt", "pow", "mod", "gcd", "lcm", "isInt", "isEven", "isOdd",
    ]

    static func call(_ name: String, _ args: [Value]) throws -> Value {
        var nums: [Double] = []
        nums.reserveCapacity(args.count)
        for (index, arg) in args.enumerated() {
            guard case .number(let n) = arg else {
                throw ExprError.functionNeedsNumbers(
                    name: name, got: arg.typeName, argument: index + 1)
            }
            nums.append(n)
        }

        // `undefined` in JS becomes NaN through every Math function, which is
        // what a missing argument produces.
        func arg(_ i: Int) -> Double { i < nums.count ? nums[i] : Double.nan }

        switch name {
        case "abs":   return .number(abs(arg(0)))
        case "sqrt":  return .number(arg(0).squareRoot())
        case "floor": return .number(arg(0).rounded(.down))
        case "ceil":  return .number(arg(0).rounded(.up))
        case "trunc": return .number(arg(0).rounded(.towardZero))
        case "round": return .number(JSNumber.round(arg(0)))
        case "sign":  return .number(JSNumber.sign(arg(0)))
        case "pow":   return .number(JSNumber.pow(arg(0), arg(1)))

        case "min", "max":
            // Math.min() is +Infinity and Math.max() is -Infinity, and any NaN
            // argument poisons the result - unlike Swift's min/max, which
            // would quietly ignore it.
            let identity = name == "min" ? Double.infinity : -Double.infinity
            if nums.isEmpty { return .number(identity) }
            if nums.contains(where: { $0.isNaN }) { return .number(.nan) }
            return .number(name == "min" ? nums.min()! : nums.max()!)

        case "mod":
            // Floored modulo: the sign follows the divisor, so mod(-7, 3) is 2
            // where the `%` operator gives -1. Written as the double
            // remainder the TypeScript uses, because that also settles the
            // sign of a zero result.
            let a = arg(0), b = arg(1)
            let r = a.truncatingRemainder(dividingBy: b)
            return .number((r + b).truncatingRemainder(dividingBy: b))

        case "gcd":
            guard !nums.isEmpty else { throw ExprError.emptyReduce("gcd") }
            // reduce with no initial value: a single argument comes back
            // untouched, so gcd(-12) is -12 rather than 12.
            return .number(nums.dropFirst().reduce(nums[0], gcd2))

        case "lcm":
            guard !nums.isEmpty else { throw ExprError.emptyReduce("lcm") }
            return .number(nums.dropFirst().reduce(nums[0]) { a, b in
                abs(a * b) / gcd2(a, b)
            })

        case "isInt":
            let n = arg(0)
            return .boolean(n.isFinite && n == n.rounded(.towardZero))
        case "isEven":
            return .boolean(arg(0).truncatingRemainder(dividingBy: 2) == 0)
        case "isOdd":
            // The abs() is why isOdd(-3) is true. Note isEven and isOdd are
            // both false for a non-integer, so they are not complements.
            return .boolean(abs(arg(0).truncatingRemainder(dividingBy: 2)) == 1)

        default:
            throw ExprError.unknownFunction(name)
        }
    }
}

private func requireNumber(_ value: Value, _ op: String) throws -> Double {
    guard case .number(let n) = value else {
        throw ExprError.operatorNeedsNumbers(op, value.typeName)
    }
    return n
}

func evaluate(_ node: Node, _ scope: Scope) throws -> Value {
    switch node {
    case .num(let v):  return .number(v)
    case .str(let v):  return .string(v)
    case .bool(let v): return .boolean(v)

    case .variable(let name):
        // Dictionary lookup is own-keys-only, which is the point: in the
        // TypeScript this is `Object.hasOwn` against a null-prototype table so
        // that `constructor` and `__proto__` resolve to nothing.
        guard let value = scope[name] else { throw ExprError.unknownVariable(name) }
        return value

    case .unary(let op, let operand):
        let value = try evaluate(operand, scope)
        if op == "!" { return .boolean(!value.truthy) }
        return .number(-(try requireNumber(value, "-")))

    case .ternary(let test, let then, let other):
        return try evaluate(test, scope).truthy
            ? try evaluate(then, scope)
            : try evaluate(other, scope)

    case .call(let name, let args):
        // The unknown-function check happens before the arguments are
        // evaluated, so `frobnicate(unknownVar)` reports the function.
        guard Functions.names.contains(name) else { throw ExprError.unknownFunction(name) }
        return try Functions.call(name, try args.map { try evaluate($0, scope) })

    case .binary(let op, let left, let right):
        // These two short-circuit, and they return a Bool rather than the
        // operand - the opposite of JavaScript's own `&&`/`||`. So `a || b` is
        // not a way to write a default value in this language.
        if op == "&&" {
            return .boolean(try evaluate(left, scope).truthy && (try evaluate(right, scope).truthy))
        }
        if op == "||" {
            return .boolean(try evaluate(left, scope).truthy || (try evaluate(right, scope).truthy))
        }

        let l = try evaluate(left, scope)
        let r = try evaluate(right, scope)

        switch op {
        case "==": return .boolean(strictEquals(l, r))
        case "!=": return .boolean(!strictEquals(l, r))

        case "+":
            // Either side being a string makes this concatenation, using the
            // JS rendering of the other side. Otherwise both must be numbers:
            // `true + false` throws here, though JavaScript itself would say 1.
            if case .string = l { return .string(l.stringValue + r.stringValue) }
            if case .string = r { return .string(l.stringValue + r.stringValue) }
            return .number(try requireNumber(l, "+") + (try requireNumber(r, "+")))

        case "-": return .number(try requireNumber(l, "-") - (try requireNumber(r, "-")))
        case "*": return .number(try requireNumber(l, "*") * (try requireNumber(r, "*")))
        case "/": return .number(try requireNumber(l, "/") / (try requireNumber(r, "/")))
        case "%":
            // Remainder, sign of the dividend. The `mod()` function is the
            // other one.
            return .number(try requireNumber(l, "%")
                .truncatingRemainder(dividingBy: try requireNumber(r, "%")))
        case "^": return .number(JSNumber.pow(try requireNumber(l, "^"),
                                              try requireNumber(r, "^")))

        // Relational operators are numbers-only and throw on strings, which is
        // a deliberate divergence from JavaScript's own coercion.
        case "<":  return .boolean(try requireNumber(l, "<") < (try requireNumber(r, "<")))
        case "<=": return .boolean(try requireNumber(l, "<=") <= (try requireNumber(r, "<=")))
        case ">":  return .boolean(try requireNumber(l, ">") > (try requireNumber(r, ">")))
        case ">=": return .boolean(try requireNumber(l, ">=") >= (try requireNumber(r, ">=")))

        default: throw ExprError.unknownVariable(op)
        }
    }
}

/// JavaScript `===`: no coercion at all, so `'2' == 2` is false. NaN is not
/// equal to itself, which Double's own `==` already gives us.
private func strictEquals(_ a: Value, _ b: Value) -> Bool {
    switch (a, b) {
    case (.number(let x), .number(let y)): return x == y
    case (.string(let x), .string(let y)): return x == y
    case (.boolean(let x), .boolean(let y)): return x == y
    default: return false
    }
}

// MARK: - Public API

public func evaluate(_ src: String, _ scope: Scope = [:]) throws -> Value {
    try evaluate(try parse(src), scope)
}

public func evaluateCondition(_ src: String, _ scope: Scope = [:]) throws -> Bool {
    try evaluate(src, scope).truthy
}

/// Parse once, evaluate many times. Parse errors surface here; evaluation
/// errors surface per call.
public func compile(_ src: String) throws -> (Scope) throws -> Value {
    let node = try parse(src)
    return { scope in try evaluate(node, scope) }
}
