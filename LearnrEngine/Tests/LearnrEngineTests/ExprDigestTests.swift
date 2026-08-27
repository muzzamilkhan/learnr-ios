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
/// ## What is verified here, and what is not
///
/// **The 127 figure-bearing templates are skipped, and cannot be verified until
/// the oracle changes.** `expressionsOf` harvests a figure's parameters by
/// walking `Object.entries(template.figure)`, so those groups' case order — and
/// therefore their hashes — is pinned to the **JSON key order of the figure
/// object**, which is the author's keystroke order in a year file. Swift cannot
/// reproduce it: a `Codable` `FigureSpec` has declared property order and
/// `JSONSerialization` is unordered, so `FigureSpec.fields` is a dictionary by
/// the time any port sees it.
///
/// Raised as ledger **L8** and confirmed there as a defect rather than a
/// decision — `canonicalScope` sorts each case's scope for exactly this reason
/// and says so, and only the *case* order was left unsorted. The fix is
/// web-side: sort the figure params inside the walk. This file harvests
/// **sorted**, which is what the fix will make correct, so when it lands only
/// the vendored digests change and no Swift does.
///
/// Until then: 378 figure-free groups plus `traps` are verified, and the
/// remaining 127 are counted and reported rather than silently passed.
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

    @Test("the figure-free expression groups reproduce the oracle's digest")
    func exprDigestsMatch() throws {
        let oracle = Fixtures.digest(set: "expr")
        var checked = 0
        var skipped = 0

        for template in Fixtures.templates {
            // See the type's note: the oracle's harvest order for these is
            // unreproducible until L8 lands.
            if template.spec.hasFigure {
                skipped += 1
                continue
            }

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

        #expect(checked == 378, "expected the 378 figure-free templates, hashed \(checked)")
        #expect(skipped == 127, "expected 127 figure-bearing templates skipped, skipped \(skipped)")
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
