import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `decimal` scope — mirrors portable
/// assertions from upstream `tests/suite/foundations/decimal.typ` plus the
/// `round` cases from upstream's `decimal.rs` unit tests.
@Suite struct DecimalTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func d(_ v: String) -> Value {
        .decimal(Decimal(exactly: v)!)
    }
    private func i(_ v: Int64) -> Value { .int(v) }
    private func s(_ v: String) -> Value { .str(Str(v)) }
    private func named(_ name: String, _ value: Value) -> TypstLibrary.Arg {
        FuncHarness.named(name, value)
    }

    @Test func decimalConstructValues() throws {
        #expect(try eval(decimalConstruct, [i(10)]) == d("10.0"))
        #expect(try eval(decimalConstruct, [s("-7654.321")]) == d("-7654.321"))
        #expect(try eval(decimalConstruct, [s("\u{2212}7654.321")])
            == d("-7654.321"))
        // float -> decimal keeps the exact binary expansion rounded to
        // 28 significant digits. Upstream's rust_decimal can differ by
        // 1 ulp in the last digit (it produces ...34707 here).
        #expect(try eval(decimalConstruct, [f(3.141592653)])
            == d("3.141592653000000012752934708"))
        #expect(try eval(decimalConstruct, [f(-3.141592653)])
            == d("-3.141592653000000012752934708"))
        // Exact powers of two have short expansions.
        #expect(try eval(decimalConstruct, [f(0.5)]) == d("0.5"))
        #expect(try eval(decimalConstruct, [f(1e20)]) == d("100000000000000000000"))
        #expect(try eval(decimalConstruct, [d("3")]) == d("3.0"))
        #expect(try eval(decimalConstruct, [.bool(true)]) == d("1.0"))
        // int.min edge: Decimal(i64) path.
        #expect(try eval(decimalConstruct, [i(Int64.min)])
            == .decimal(Decimal(Int64.min)))
    }

    private func f(_ v: Double) -> Value { .float(v) }

    @Test func decimalConstructErrors() {
        // bad string
        switch harness.call(decimalConstruct, harness.args([s("1.2.3")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "invalid decimal: 1.2.3")
        case .success:
            Issue.record("expected error")
        }
        // non-finite floats
        for v in [Double.infinity, -Double.infinity, Double.nan] {
            let result = harness.call(decimalConstruct, harness.args([f(v)]))
            switch result {
            case .failure(let r):
                #expect(r.diagnostics.first?.message.hasPrefix(
                    "float is not a valid decimal:") == true)
            case .success(let val):
                Issue.record("expected error, got \(val)")
            }
        }
        // bad type
        switch harness.call(decimalConstruct,
                            harness.args([.type(Type.of(Int64.self))])) {
        case .failure:
            break
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: methods

    @Test func decimalMethods() throws {
        #expect(try eval(decimalIsInteger, [d("3.0")]) == .bool(true))
        #expect(try eval(decimalIsInteger, [d("3.5")]) == .bool(false))
        #expect(try eval(decimalAbs, [d("-3.5")]) == d("3.5"))
        #expect(try eval(decimalAbs, [d("3.5")]) == d("3.5"))
        #expect(try eval(decimalFloor, [d("3.7")]) == d("3"))
        #expect(try eval(decimalFloor, [d("-3.7")]) == d("-4"))
        #expect(try eval(decimalCeil, [d("3.2")]) == d("4"))
        #expect(try eval(decimalCeil, [d("-3.2")]) == d("-3"))
        #expect(try eval(decimalTrunc, [d("3.9")]) == d("3"))
        #expect(try eval(decimalTrunc, [d("-3.9")]) == d("-3"))
        #expect(try eval(decimalFract, [d("3.25")]) == d("0.25"))
        #expect(try eval(decimalFract, [d("-3.25")]) == d("-0.25"))
    }

    @Test func decimalRoundMethod() throws {
        // Upstream `test_decimal_positive_round` cases.
        func round(_ v: String, _ digits: Int32) throws -> Value {
            try eval(decimalRound, [d(v), .int(Int64(digits))])
        }
        #expect(try round("312.55553", 0) == d("313.00000"))
        #expect(try round("312.55553", 3) == d("312.556"))
        #expect(try round("312.5555300000", 3) == d("312.556"))
        #expect(try round("-312.55553", 3) == d("-312.556"))
        #expect(try round("312.55553", 28) == d("312.55553"))
        #expect(try round("312.55553", 2341) == d("312.55553"))
        // Upstream `test_decimal_negative_round` cases.
        #expect(try round("4596.55553", -1) == d("4600"))
        #expect(try round("4596.555530000000", -1) == d("4600"))
        #expect(try round("-4596.55553", -3) == d("-5000"))
        #expect(try round("4596.55553", -28) == d("0"))
        #expect(try round("-4596.55553", -2341) == d("0"))
    }
}
