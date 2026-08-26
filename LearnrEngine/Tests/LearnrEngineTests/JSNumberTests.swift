import Testing
import Foundation
@testable import LearnrEngine

/// Every expectation here was produced by running `String(x)` in node, not by
/// reasoning about the spec.
struct JSNumberTests {

    @Test("toString lays numbers out the way JavaScript does")
    func toStringMatchesJS() {
        let cases: [(Double, String)] = [
            (2, "2"),                       // not "2.0" - the one that would
            (3, "3"),                       // corrupt every rendered prompt
            (0.1 + 0.2, "0.30000000000000004"),
            (1.0 / 3.0, "0.3333333333333333"),
            (-0.0, "0"),                    // JS prints negative zero as "0"
            (1e20, "100000000000000000000"),
            (1e21, "1e+21"),                // the threshold where JS switches
            (1e-6, "0.000001"),
            (1e-7, "1e-7"),                 // no zero-padded exponent
            (1e-10, "1e-10"),
            (1.5, "1.5"),
            (100, "100"),
            (0.5, "0.5"),
            (-2.5, "-2.5"),
            (-1.5, "-1.5"),
            (123.456, "123.456"),
            (Foundation.pow(2, 70), "1.1805916207174113e+21"),
            (0, "0"),
        ]
        for (input, expected) in cases {
            #expect(JSNumber.toString(input) == expected,
                    "toString(\(input)) gave \(JSNumber.toString(input)), want \(expected)")
        }
    }

    @Test("toString names the non-finite values as JavaScript does")
    func nonFinite() {
        #expect(JSNumber.toString(.nan) == "NaN")
        #expect(JSNumber.toString(.infinity) == "Infinity")
        #expect(JSNumber.toString(-.infinity) == "-Infinity")
    }

    @Test("round breaks ties toward +Infinity, unlike Swift's rounded()")
    func roundIsHalfUp() {
        #expect(JSNumber.round(2.5) == 3)
        #expect(JSNumber.round(3.5) == 4)
        #expect(JSNumber.round(0.5) == 1)
        // These four are where Swift's own rounded() would disagree.
        #expect(JSNumber.round(-2.5) == -2)
        #expect(JSNumber.round(-1.5) == -1)
        #expect(JSNumber.round(-0.5) == 0)   // -0, and -0 == 0
        #expect((-2.5).rounded() == -3)      // proving the divergence is real
    }

    @Test("round leaves ordinary values alone")
    func roundOrdinary() {
        #expect(JSNumber.round(2.4) == 2)
        #expect(JSNumber.round(-2.4) == -2)
        #expect(JSNumber.round(2.6) == 3)
        #expect(JSNumber.round(-2.6) == -3)
        #expect(JSNumber.round(0) == 0)
    }

    @Test("sign returns a signed double and keeps NaN")
    func signSemantics() {
        #expect(JSNumber.sign(-3) == -1)
        #expect(JSNumber.sign(4) == 1)
        #expect(JSNumber.sign(0) == 0)
        #expect(JSNumber.sign(.nan).isNaN)
    }

    @Test("pow follows JavaScript at NaN, not C")
    func powAtNaN() {
        #expect(JSNumber.pow(.nan, 0).isNaN)    // C pow would give 1
        #expect(JSNumber.pow(1, .nan).isNaN)    // C pow would give 1
        #expect(JSNumber.pow(0, 0) == 1)
        #expect(JSNumber.pow(2, -1) == 0.5)
        #expect(JSNumber.pow(2, 10) == 1024)
    }
}
