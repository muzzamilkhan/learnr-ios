import Testing
import Foundation
@testable import LearnrEngine

/// The expression set, mirroring `scripts/fixtures/expr.ts`: every expression
/// string a template holds, evaluated against five real bound scopes, plus the
/// hand-authored traps.
///
/// **Two halves, and only one of them is generated.** The harvest reaches the
/// language as content actually uses it — 1,453 distinct strings across the
/// shipped corpus. The traps reach what content never does: `^` appears in the
/// 505 templates **not once**, and `ceil`, `trunc`, `sign`, `sqrt` and `isInt`
/// never appear at all.
///
/// **An expression needs a scope, and this needs no engine instrumentation.**
/// `q.vars` *is* the bound scope, already exposed on `GeneratedQuestion`, so
/// five draws supply five real bindings and each expression is seen against
/// several rather than one lucky one.
///
/// ## Why the figure params are sorted
///
/// `expressionsOf` used to harvest a figure's parameters by walking
/// `Object.entries(template.figure)`, which pinned those 127 groups' case order
/// — and so their hashes — to the **JSON key order of the figure literal**: the
/// author's keystroke order in a year file, movable by an edit that changes
/// nothing the engine does. No port can reproduce it, since `FigureSpec.fields`
/// is a dictionary by the time any decoder is done.
///
/// Raised as ledger **L8**, confirmed a defect rather than a decision —
/// `canonicalScope` already sorted each case's *scope* for exactly this reason,
/// and only the *case* order had been left out. Fixed on the oracle's side by
/// `learnr` `19e4a71` (sort the walk) and `6f5ba16` (regenerate), which moved
/// 56 groups and took `expr.json` to `829f572f8fc7`. Fewer than 127 because a
/// literal already written in alphabetical order harvests the same either way.
///
/// This side harvested sorted from the start, so that fix turned on all 127 by
/// re-vendoring alone, with no change here.
struct ExprDigestTests {
    /// How many real scopes each of a template's expressions is evaluated
    /// against.
    static let scopesPerTemplate = 5

    /// Every expression string a template holds, deduplicated and in a stable
    /// order.
    ///
    /// **Order is contract**, and it is the order `expressionsOf` visits its
    /// sources in: answer, constraints, var bounds, `expr` vars, prompt holes,
    /// hint holes, distractors, then jitter. Deduplicated in **first-insertion
    /// order**, matching the TypeScript's `[...new Set(found)]` — Swift has no
    /// ordered set, so this is a deliberate ordered dedupe.
    ///
    /// Figure parameters are deliberately absent; see the type's note on L8.
    static func expressions(of template: QuestionTemplate) -> [String] {
        var found: [String] = []
        func add(_ expr: String?) {
            if let expr, !expr.isEmpty { found.append(expr) }
        }

        let spec = template.spec
        add(spec.answer)
        for constraint in spec.constraints ?? [] { add(constraint) }

        for v in spec.vars {
            switch v {
            case .int(_, let min, let max, _):
                add(min)
                add(max)
            case .number(_, let min, let max, _):
                add(min)
                add(max)
            case .expr(_, let expr):
                add(expr)
            case .pick:
                // `pick` holds values, not expressions — the TypeScript's walk
                // reaches neither `from` nor `weights`.
                break
            }
        }

        for text in [spec.prompt, spec.hint] {
            for hole in holes(in: text ?? "") { add(hole) }
        }

        for distractor in spec.choices?.distractors ?? [] { add(distractor) }

        // A figure's parameters are expressions too, evaluated against this same
        // bound scope by `buildFigure`.
        //
        // **Sorted by field name**, which is what `19e4a71` made the oracle do.
        // It used to walk `Object.entries`, pinning these groups to the JSON key
        // order of the figure literal — the author's keystroke order in a year
        // file, which no port can reproduce and which a no-op edit could move.
        // Ledger L8; `canonical.ts` exports `byName` so the two sites cannot
        // sort differently.
        if let figure = spec.figure {
            for field in figure.fields.keys.sorted() { add(figure.fields[field]) }
        }

        // The `jitter` bounds, used when authored distractors run short. No
        // shipped template carries one today, so this collects nothing yet; it
        // is here so the first one to use it is covered rather than silently
        // uncovered.
        if let jitter = spec.choices?.jitter {
            add(jitter.min)
            add(jitter.max)
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// The contents of every `{...}` hole, matching the TypeScript's
    /// `/\{([^}]*)\}/g` — non-greedy by construction, since `[^}]*` cannot
    /// cross a closing brace.
    static func holes(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            out.append(String(rest[afterOpen..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    /// A bound scope, as `Value` — what `evaluate` takes. `q.vars` is `Answer`,
    /// and the two are the same three cases.
    static func scope(from vars: [String: Answer]) -> Scope {
        vars.mapValues { answer in
            switch answer {
            case .number(let n): return Value.number(n)
            case .string(let s): return Value.string(s)
            case .boolean(let b): return Value.boolean(b)
            }
        }
    }

    /// **An expression that throws records the throw rather than being
    /// skipped.** A port that fails to throw where the oracle does has diverged
    /// just as surely as one returning a different number — which is why the
    /// Swift error messages mirror the TypeScript's text exactly.
    static func evaluated(_ expr: String, _ scope: Scope) -> String {
        do {
            return try evaluate(expr, scope).stringValue
        } catch let error as ExprError {
            return "throws: \(error.description)"
        } catch {
            return "throws: \(error)"
        }
    }

    @Test("every expression group reproduces the oracle's digest")
    func exprDigestsMatch() throws {
        let oracle = Fixtures.digest(set: "expr")
        var checked = 0
        var withFigure = 0

        for template in Fixtures.templates {
            if template.spec.hasFigure { withFigure += 1 }

            let expressions = Self.expressions(of: template)
            if expressions.isEmpty { continue }

            var cases: [String] = []
            for draw in 0..<Self.scopesPerTemplate {
                var rng = Rng(seed: Fixtures.seed(template.id, draw))
                let scope = Self.scope(from: try generateQuestion(template, &rng).question.vars)
                for expr in expressions {
                    cases.append(try Canonical.canonicalise(
                        [(name: "expr", value: expr)]
                            + Canonical.scopeOfValues("scope", scope)
                            + [(name: "value", value: Self.evaluated(expr, scope))]
                    ))
                }
            }

            #expect(
                Canonical.digest(cases) == oracle.groups[template.id],
                "\(template.id) evaluates differently from the oracle"
            )
            checked += 1
        }

        #expect(checked == 507, "expected all 507 templates, hashed \(checked)")
        // The figure-bearing ones were the 127 that L8 blocked, and are 129
        // since the two `timeline` templates landed with the twelfth kind
        // (L21). Counted rather than assumed, so that the day one is added or
        // removed this says so instead of the coverage quietly changing.
        #expect(withFigure == 129, "expected 129 figure-bearing templates, saw \(withFigure)")
    }

    /// **The half that asserts rather than records.** Everywhere else the
    /// TypeScript is the oracle and a digest proves agreement, so a bug there
    /// would be reproduced here and both engines would stay green. These are
    /// the cases where idiomatic Swift silently diverges, and harvesting cannot
    /// reach them.
    @Test("the hand-authored traps reproduce the oracle's digest")
    func trapsDigestMatches() throws {
        let cases = try ExprTraps.all.map { trap in
            try Canonical.canonicalise(
                [(name: "expr", value: trap.expr)]
                    + Canonical.scope("scope", trap.scope)
                    + [(name: "value", value: trap.expect.stringValue)]
            )
        }

        #expect(
            Canonical.digest(cases) == Fixtures.digest(set: "expr").groups["traps"],
            "the trap list diverges from the oracle — a transcription slip, or a real disagreement"
        )
    }

    /// The traps assert against **this** engine too, which is the whole point
    /// of them being hand-written. When a human's expectation and the engine
    /// disagree, somebody decides which is wrong — rather than regenerating.
    @Test("the engine agrees with every hand-written expectation")
    func engineAgreesWithTraps() throws {
        for trap in ExprTraps.all {
            let got = Self.evaluated(trap.expr, Self.scope(from: trap.scope))
            #expect(
                got == trap.expect.stringValue,
                "\(trap.expr) — a human wrote \(trap.expect.stringValue), the engine says \(got)"
            )
        }
    }
}
