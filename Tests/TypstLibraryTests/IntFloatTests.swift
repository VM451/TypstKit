import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `int` and `float` type scopes —
/// mirrors portable assertions from upstream
/// `tests/suite/foundations/{int,float}.typ`.
@Suite struct IntFloatTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func i(_ v: Int64) -> Value { .int(v) }
    private func f(_ v: Double) -> Value { .float(v) }
    private func s(_ v: String) -> Value { .str(Str(v)) }
    private func b(_ v: [UInt8]) -> Value { .bytes(Bytes(v)) }
    private func named(_ name: String, _ value: Value) -> TypstLibrary.Arg {
        FuncHarness.named(name, value)
    }

    // MARK: int constructor

    @Test func intConstructValues() throws {
        #expect(try eval(intConstruct, [.bool(false)]) == i(0))
        #expect(try eval(intConstruct, [.bool(true)]) == i(1))
        #expect(try eval(intConstruct, [i(10)]) == i(10))
        #expect(try eval(intConstruct, [s("0")]) == i(0))
        #expect(try eval(intConstruct, [s("+150")]) == i(150))
        #expect(try eval(intConstruct, [s("-834")]) == i(-834))
        #expect(try eval(intConstruct, [s("beef")],
                         named: [named("base", i(16))]) == i(48879))
        #expect(try eval(intConstruct, [s("-cAfFe")],
                         named: [named("base", i(16))]) == i(-831486))
        #expect(try eval(intConstruct, [s("10")],
                         named: [named("base", i(2))]) == i(2))
        #expect(try eval(intConstruct, [s("644")],
                         named: [named("base", i(8))]) == i(420))
        // U+2212 minus sign parses like `-`.
        #expect(try eval(intConstruct, [s("\u{2212}79")]) == i(-79))
        #expect(try eval(intConstruct, [s("9223372036854775807")]) == i(Int64.max))
        #expect(try eval(intConstruct, [s("-9223372036854775808")]) == i(Int64.min))
        #expect(try eval(intConstruct, [s("7FFFFFFFFFFFFFFF")],
                         named: [named("base", i(16))]) == i(Int64.max))
        #expect(try eval(intConstruct, [s("-8000000000000000")],
                         named: [named("base", i(16))]) == i(Int64.min))
        // float/decimal truncate toward zero.
        #expect(try eval(intConstruct, [f(10.0 / 3.0)]) == i(3))
        #expect(try eval(intConstruct, [f(-58.34)]) == i(-58))
        #expect(try eval(intConstruct,
                         [.decimal(Decimal(exactly: "92492.193848921")!)]) == i(92492))
        #expect(try eval(intConstruct,
                         [.decimal(Decimal(exactly: "-224.342211")!)]) == i(-224))
    }

    @Test func intConstructErrors() {
        // bad type
        switch harness.call(intConstruct, harness.args([Value.length(Length(abs: Abs(10), em: .zero))])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message.contains("expected") == true)
        case .success:
            Issue.record("expected error")
        }
        // empty string
        for base in [nil, i(16)] as [Value?] {
            var args = harness.args([s("")])
            if let base { args.items.append(named("base", base)) }
            switch harness.call(intConstruct, args) {
            case .failure(let r):
                #expect(r.diagnostics.first?.message == "string must not be empty")
            case .success:
                Issue.record("expected error")
            }
        }
        // invalid digits, base 10 and base 3
        switch harness.call(intConstruct, harness.args([s("nope")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "string contains invalid digits")
        case .success:
            Issue.record("expected error")
        }
        switch harness.call(intConstruct,
                            harness.args([s("123")]).withNamed("base", i(3))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "string contains invalid digits for a base 3 integer")
        case .success:
            Issue.record("expected error")
        }
        // base with non-string
        switch harness.call(intConstruct,
                            harness.args([i(40)]).withNamed("base", i(16))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "base is only supported for strings")
        case .success:
            Issue.record("expected error")
        }
        // base out of range
        for badBase in [i(1), i(42)] {
            switch harness.call(intConstruct,
                                harness.args([s("0")]).withNamed("base", badBase)) {
            case .failure(let r):
                #expect(r.diagnostics.first?.message
                    == "base must be between 2 and 36")
            case .success:
                Issue.record("expected error")
            }
        }
        // overflow
        switch harness.call(intConstruct, harness.args([s("9223372036854775808")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "integer value is too large")
            #expect(r.diagnostics.first?.hints.count == 2)
        case .success:
            Issue.record("expected error")
        }
        // underflow below int.min
        switch harness.call(intConstruct, harness.args([s("-9223372036854775809")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "integer value is too small")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func intScopeConstants() throws {
        #expect(try eval(intConstruct, [i(Int64.max)]) == i(Int64.max))
        #expect(intScope().get("max")?.value == i(Int64.max))
        #expect(intScope().get("min")?.value == i(Int64.min))
    }

    // MARK: int bitwise ops

    @Test func intBitOps() throws {
        #expect(try eval(intSignum, [i(5)]) == i(1))
        #expect(try eval(intSignum, [i(-5)]) == i(-1))
        #expect(try eval(intSignum, [i(0)]) == i(0))
        #expect(try eval(intBitNot, [i(4)]) == i(-5))
        #expect(try eval(intBitNot, [i(-1)]) == i(0))
        #expect(try eval(intBitAnd, [i(128), i(192)]) == i(128))
        #expect(try eval(intBitOr, [i(64), i(32)]) == i(96))
        #expect(try eval(intBitXor, [i(64), i(96)]) == i(32))
        #expect(try eval(intBitLshift, [i(33), i(2)]) == i(132))
        #expect(try eval(intBitLshift, [i(-1), i(3)]) == i(-8))
        #expect(try eval(intBitRshift, [i(64), i(2)]) == i(16))
        #expect(try eval(intBitRshift, [i(-8), i(2)]) == i(-2))
        #expect(try eval(intBitRshift, [i(-8), i(2)],
                         named: [named("logical", .bool(true))])
            == i(4611686018427387902))
        // Excessive shifts saturate.
        #expect(try eval(intBitRshift, [i(-8), i(100)]) == i(-1))
        #expect(try eval(intBitRshift, [i(-8), i(100)],
                         named: [named("logical", .bool(true))]) == i(0))
        #expect(try eval(intBitRshift, [i(8), i(100)]) == i(0))
        // lshift >= 64 errors.
        switch harness.call(intBitLshift, harness.args([i(1), i(64)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "the result is too large")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: int bytes

    @Test func intBytes() throws {
        // from-bytes
        #expect(try eval(intFromBytes, [b([])]) == i(0))
        #expect(try eval(intFromBytes, [b([1, 0, 0, 0, 0, 0, 0, 0])]) == i(1))
        #expect(try eval(intFromBytes, [b([1, 0, 0, 0, 0, 0, 0, 0])],
                         named: [named("endian", s("big")),
                                 named("signed", .bool(true))])
            == i(72057594037927936))
        #expect(try eval(intFromBytes, [b([255])],
                         named: [named("endian", s("big")),
                                 named("signed", .bool(true))]) == i(-1))
        #expect(try eval(intFromBytes, [b([255])],
                         named: [named("endian", s("big")),
                                 named("signed", .bool(false))]) == i(255))
        // roundtrip through to-bytes with size 5.
        let neg = try eval(intToBytes, [i(-1000)],
                           named: [named("endian", s("big")),
                                   named("size", .int(5))])
        #expect(try eval(intFromBytes, [neg],
                         named: [named("endian", s("big")),
                                 named("signed", .bool(true))]) == i(-1000))
        let pos = try eval(intToBytes, [i(1000)],
                           named: [named("endian", s("little")),
                                   named("size", .int(5))])
        #expect(try eval(intFromBytes, [pos],
                         named: [named("endian", s("little")),
                                 named("signed", .bool(false))]) == i(1000))
        // to-bytes defaults: 8 bytes little-endian.
        #expect(try eval(intToBytes, [i(1)])
            == b([1, 0, 0, 0, 0, 0, 0, 0]))
        #expect(try eval(intToBytes, [i(1)],
                         named: [named("endian", s("big"))])
            == b([0, 0, 0, 0, 0, 0, 0, 1]))
        // size 0 → empty.
        #expect(try eval(intToBytes, [i(1)],
                         named: [named("size", .int(0))]) == b([]))
        // from-bytes > 8 errors.
        switch harness.call(intFromBytes,
                            harness.args([b([UInt8](repeating: 0, count: 16))])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "too many bytes to convert to a 64 bit number")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: float constructor

    @Test func floatConstructValues() throws {
        #expect(try eval(floatConstruct, [i(10)]) == f(10.0))
        #expect(try eval(floatConstruct, [.bool(true)]) == f(1.0))
        #expect(try eval(floatConstruct, [s("31.4e-1")]) == f(3.14))
        #expect(try eval(floatConstruct, [s("31.4e\u{2212}1")]) == f(3.14))
        #expect(try eval(floatConstruct, [s("-7654.321")]) == f(-7654.321))
        #expect(try eval(floatConstruct, [s("\u{2212}7654.321")]) == f(-7654.321))
        #expect(try eval(floatConstruct,
                         [.decimal(Decimal(exactly: "4.89")!)]) == f(4.89))
        #expect(try eval(floatConstruct,
                         [.decimal(Decimal(exactly: "3.1234567891234567891234567891")!)])
            == f(3.123456789123457))
        #expect(try eval(floatConstruct,
                         [.ratio(Ratio(0.15))]) == f(0.15))
    }

    @Test func floatConstructErrors() {
        // invalid float string
        switch harness.call(floatConstruct, harness.args([s("1.2.3")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "invalid float: \"1.2.3\"")
        case .success:
            Issue.record("expected error")
        }
        // bad type
        switch harness.call(floatConstruct, harness.args([.type(Type.of(Int64.self))])) {
        case .failure:
            break
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: float methods

    @Test func floatMethods() throws {
        #expect(try eval(floatIsNan, [f(.nan)]) == .bool(true))
        #expect(try eval(floatIsNan, [f(10.0)]) == .bool(false))
        #expect(try eval(floatIsNan, [f(.infinity)]) == .bool(false))
        #expect(try eval(floatIsInfinite, [f(.infinity)]) == .bool(true))
        #expect(try eval(floatIsInfinite, [f(-.infinity)]) == .bool(true))
        #expect(try eval(floatIsInfinite, [f(.nan)]) == .bool(false))
        #expect(try eval(floatSignum, [f(0.0)]) == f(1.0))
        #expect(try eval(floatSignum, [f(1.0)]) == f(1.0))
        #expect(try eval(floatSignum, [f(-1.0)]) == f(-1.0))
        #expect(try eval(floatSignum, [f(.infinity)]) == f(1.0))
        #expect(try eval(floatSignum, [f(-.infinity)]) == f(-1.0))
        // NaN signum → NaN (compare via is-nan).
        let nanSignum = try eval(floatSignum, [f(.nan)])
        guard case .float(let v) = nanSignum else {
            Issue.record("expected float")
            return
        }
        #expect(v.isNaN)
        // -0.0 signum → -1.0
        #expect(try eval(floatSignum, [f(-0.0)]) == f(-1.0))
    }

    @Test func floatBytes() throws {
        // from-bytes: 1.0 little/big endian, f64 and f32.
        #expect(try eval(floatFromBytes,
                         [b([0, 0, 0, 0, 0, 0, 240, 63])]) == f(1.0))
        #expect(try eval(floatFromBytes,
                         [b([63, 240, 0, 0, 0, 0, 0, 0])],
                          named: [named("endian", s("big"))]) == f(1.0))
        #expect(try eval(floatFromBytes, [b([0, 0, 32, 64])]) == f(2.5))
        #expect(try eval(floatFromBytes,
                         [b([64, 32, 0, 0])],
                          named: [named("endian", s("big"))]) == f(2.5))
        // to-bytes roundtrips.
        #expect(try eval(floatToBytes, [f(1.0)])
            == b([0, 0, 0, 0, 0, 0, 240, 63]))
        #expect(try eval(floatToBytes, [f(1.0)],
                         named: [named("endian", s("big"))])
            == b([63, 240, 0, 0, 0, 0, 0, 0]))
        #expect(try eval(floatToBytes, [f(2.5)],
                         named: [named("size", .int(4))])
            == b([0, 0, 32, 64]))
        #expect(try eval(floatToBytes, [f(2.5)],
                         named: [named("size", .int(4)),
                                 named("endian", s("big"))])
            == b([64, 32, 0, 0]))
        // bad length
        switch harness.call(floatFromBytes,
                            harness.args([b([0, 0, 0, 0, 0, 0, 0, 1, 0])])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "bytes must have a length of 4 or 8")
        case .success:
            Issue.record("expected error")
        }
        // bad size
        switch harness.call(floatToBytes,
                            harness.args([f(1.0)]).withNamed("size", .int(3))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "size must be either 4 or 8")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func floatScopeConstants() {
        #expect(floatScope().get("inf")?.value == f(.infinity))
        guard case .float(let nan) = floatScope().get("nan")?.value else {
            Issue.record("expected float")
            return
        }
        #expect(nan.isNaN)
    }
}

private extension TypstLibrary.Args {
    func withNamed(_ name: String, _ value: Value) -> TypstLibrary.Args {
        var copy = self
        copy.items.append(FuncHarness.named(name, value))
        return copy
    }
}
