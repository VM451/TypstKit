import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the ported `calc` module functions.
/// Mirrors assertions from `tests/suite/foundations/calc.typ` upstream.
@Suite struct CalcTests {
    let harness = FuncHarness()

    private func call(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) -> SourceResult<Value> {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return harness.call(data, args)
    }

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        try harness.unwrap(call(data, values, named: named))
    }

    private func error(_ data: NativeFuncData, _ values: [Value],
                       named: [TypstLibrary.Arg] = []) -> String {
        switch call(data, values, named: named) {
        case .success:
            Issue.record("expected error, got success")
            return ""
        case .failure(let d):
            return d.diagnostics.first?.message ?? ""
        }
    }

    // MARK: abs

    @Test func absValues() throws {
        #expect(try eval(calcAbs, [.int(-3)]) == .int(3))
        #expect(try eval(calcAbs, [.int(3)]) == .int(3))
        #expect(try eval(calcAbs, [.float(-0.0)]) == .float(0.0))
        #expect(try eval(calcAbs, [.float(-3.14)]) == .float(3.14))
        #expect(try eval(calcAbs, [.ratio(Ratio(0.5))]) == .ratio(Ratio(0.5)))
        #expect(try eval(calcAbs, [.ratio(Ratio(-0.25))]) == .ratio(Ratio(0.25)))
        #expect(try eval(calcAbs, [.decimal(Decimal(exactly: "-12402.593295932041")!)])
                == .decimal(Decimal(exactly: "12402.593295932041")!))
    }

    @Test func absTooLarge() {
        #expect(error(calcAbs, [.int(Int64.min)]) == "the result is too large")
    }

    @Test func absBadType() {
        let msg = error(calcAbs, [.str(Str("no number"))])
        #expect(msg.contains("expected"))
    }

    // MARK: rem / div-euclid / rem-euclid / quo

    @Test func remValues() throws {
        #expect(try eval(calcRem, [.int(5), .int(3)]) == .int(2))
        #expect(try eval(calcRem, [.int(5), .int(-3)]) == .int(2))
        #expect(try eval(calcRem, [.float(22.5), .float(10)]) == .float(2.5))
        #expect(try eval(calcRem, [.int(Int64.min), .int(-1)]) == .int(0))
        #expect(try eval(calcRem, [.float(Double(Int64.min)), .float(-1)]) == .float(0))
        #expect(try eval(calcRem, [.decimal(Decimal(exactly: "7")!), .decimal(Decimal(exactly: "-3")!)])
                == .decimal(Decimal(exactly: "1")!))
        #expect(try eval(calcRem, [.decimal(Decimal(exactly: "-7")!), .decimal(Decimal(exactly: "3")!)])
                == .decimal(Decimal(exactly: "-1")!))
    }

    @Test func remDivisorZero() {
        #expect(error(calcRem, [.int(5), .int(0)]) == "divisor must not be zero")
        #expect(error(calcRem, [.float(3), .float(0)]) == "divisor must not be zero")
    }

    @Test func divEuclidValues() throws {
        #expect(try eval(calcDivEuclid, [.int(7), .int(3)]) == .int(2))
        #expect(try eval(calcDivEuclid, [.int(7), .int(-3)]) == .int(-2))
        #expect(try eval(calcDivEuclid, [.int(-7), .int(3)]) == .int(-3))
        #expect(try eval(calcDivEuclid, [.int(-7), .int(-3)]) == .int(3))
        #expect(try eval(calcDivEuclid, [.float(2.5), .float(2)]) == .float(1))
        #expect(try eval(calcDivEuclid, [.decimal(Decimal(exactly: "-7")!), .decimal(Decimal(exactly: "3")!)])
                == .decimal(Decimal(exactly: "-3")!))
        #expect(error(calcDivEuclid, [.int(Int64.min), .int(-1)]) == "the result is too large")
    }

    @Test func remEuclidValues() throws {
        #expect(try eval(calcRemEuclid, [.int(7), .int(3)]) == .int(1))
        #expect(try eval(calcRemEuclid, [.int(7), .int(-3)]) == .int(1))
        #expect(try eval(calcRemEuclid, [.int(-7), .int(3)]) == .int(2))
        #expect(try eval(calcRemEuclid, [.int(-7), .int(-3)]) == .int(2))
        #expect(try eval(calcRemEuclid, [.float(2.5), .float(2)]) == .float(0.5))
    }

    // MARK: gcd / lcm / fact / perm / binom

    @Test func gcdLcm() throws {
        #expect(try eval(calcGcd, [.int(12), .int(18)]) == .int(6))
        #expect(try eval(calcGcd, [.int(-12), .int(18)]) == .int(6))
        #expect(try eval(calcLcm, [.int(4), .int(6)]) == .int(12))
        #expect(try eval(calcLcm, [.int(-4), .int(6)]) == .int(12))
    }

    @Test func combinatorics() throws {
        #expect(try eval(calcFact, [.int(5)]) == .int(120))
        #expect(try eval(calcFact, [.int(0)]) == .int(1))
        #expect(try eval(calcPerm, [.int(5), .int(2)]) == .int(20))
        #expect(try eval(calcPerm, [.int(2), .int(5)]) == .int(0))
        #expect(try eval(calcBinom, [.int(5), .int(2)]) == .int(10))
        #expect(try eval(calcBinom, [.int(5), .int(7)]) == .int(0))
        #expect(error(calcFact, [.int(21)]) == "the result is too large")
    }

    // MARK: floor / ceil / trunc / fract / round

    @Test func rounding() throws {
        #expect(try eval(calcFloor, [.float(3.7)]) == .int(3))
        #expect(try eval(calcFloor, [.float(-3.7)]) == .int(-4))
        #expect(try eval(calcCeil, [.float(3.2)]) == .int(4))
        #expect(try eval(calcTrunc, [.float(-3.7)]) == .int(-3))
        #expect(try eval(calcFract, [.float(3.5)]) == .float(0.5))
        #expect(try eval(calcFract, [.int(5)]) == .int(0))
        #expect(try eval(calcRound, [.float(3.5)]) == .float(4))
        #expect(try eval(calcRound, [.float(2.5)]) == .float(3))
        #expect(try eval(calcRound, [.int(523)],
                        named: [FuncHarness.named("digits", .int(-2))]) == .int(500))
        #expect(try eval(calcRound, [.float(3.1415)],
                        named: [FuncHarness.named("digits", .int(2))]) == .float(3.14))
    }

    // MARK: clamp / min / max / even / odd

    @Test func clampMinMax() throws {
        #expect(try eval(calcClamp, [.int(5), .int(1), .int(10)]) == .int(5))
        #expect(try eval(calcClamp, [.int(-5), .int(1), .int(10)]) == .int(1))
        #expect(try eval(calcClamp, [.int(15), .int(1), .int(10)]) == .int(10))
        #expect(error(calcClamp, [.int(5), .int(10), .int(1)])
                == "max must be greater than or equal to min")
        #expect(try eval(calcMin, [.int(3), .int(1), .int(2)]) == .int(1))
        #expect(try eval(calcMax, [.int(3), .int(1), .int(2)]) == .int(3))
        #expect(error(calcMin, []) == "expected at least one value")
    }

    @Test func parity() throws {
        #expect(try eval(calcEven, [.int(2)]) == .bool(true))
        #expect(try eval(calcOdd, [.int(-1)]) == .bool(true))
        #expect(try eval(calcEven, [.int(-11)]) == .bool(false))
    }

    // MARK: pow / sqrt / exp / root

    @Test func powSqrt() throws {
        #expect(try eval(calcPow, [.int(2), .int(10)]) == .int(1024))
        #expect(try eval(calcPow, [.float(2), .float(0.5)]) == .float(2.0.squareRoot()))
        #expect(error(calcPow, [.int(0), .int(0)]) == "zero to the power of zero is undefined")
        #expect(try eval(calcSqrt, [.float(16)]) == .float(4))
        #expect(error(calcSqrt, [.float(-1)])
                == "cannot take square root of negative number")
        #expect(try eval(calcExp, [.int(1)]) == .float(exp(1)))
        #expect(try eval(calcRoot, [.float(27), .int(3)]) == .float(3))
        #expect(error(calcRoot, [.float(27), .int(0)])
                == "cannot take the 0th root of a number")
    }

    // MARK: trig / log

    @Test func trigLog() throws {
        #expect(try eval(calcSin, [.angle(Angle.deg(90))]) == .float(1))
        #expect(try eval(calcCos, [.angle(Angle.deg(0))]) == .float(1))
        #expect(try eval(calcAsin, [.float(0)]) == .angle(Angle.rad(0)))
        #expect(error(calcAsin, [.float(2)]) == "value must be between -1 and 1")
        #expect(try eval(calcLog, [.float(100)]) == .float(2))
        #expect(try eval(calcLn, [.float(1)]) == .float(0))
        #expect(error(calcLn, [.float(0)]) == "value must be strictly positive")
    }

    // MARK: quo / norm

    @Test func quoNorm() throws {
        #expect(try eval(calcQuo, [.int(7), .int(3)]) == .int(2))
        #expect(try eval(calcQuo, [.int(-7), .int(3)]) == .int(-3))
        #expect(try eval(calcQuo, [.float(7.5), .float(2)]) == .int(3))
        #expect(try eval(calcNorm, [.float(3), .float(4)]) == .float(5))
    }
}
