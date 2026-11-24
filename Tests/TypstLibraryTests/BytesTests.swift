import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `bytes` type scope — mirrors
/// assertions from upstream `tests/suite/foundations/bytes.typ`.
@Suite struct BytesTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func i(_ v: Int64) -> Value { .int(v) }
    private func s(_ v: String) -> Value { .str(Str(v)) }
    private func by(_ v: [UInt8]) -> Value { .bytes(Bytes(v)) }

    // MARK: constructor

    @Test func construct() throws {
        // `value` is required — `bytes()` is an error (checked below).
        // bytes(string) → UTF-8
        #expect(try eval(bytesConstruct, [s("hello")]) == by(Array("hello".utf8)))
        #expect(try eval(bytesConstruct, [s("héllo")]) == by(Array("héllo".utf8)))
        // bytes(array of ints 0-255)
        #expect(try eval(bytesConstruct, [.array(ArrayValue([i(104), i(105)]))])
            == by([104, 105]))
        // bytes(bytes) → identity
        #expect(try eval(bytesConstruct, [by([1, 2, 3])]) == by([1, 2, 3]))
    }

    @Test func constructErrors() {
        // Out-of-range byte value.
        switch harness.call(bytesConstruct,
                            harness.args([.array(ArrayValue([i(1), i(300)]))])) {
        case .failure(let r):
            #expect(r.diagnostics.first != nil)
        case .success:
            Issue.record("expected error")
        }
        // Wrong type.
        switch harness.call(bytesConstruct, harness.args([i(5)])) {
        case .failure:
            break
        case .success:
            Issue.record("expected error")
        }
        // Missing argument.
        switch harness.call(bytesConstruct, harness.args([])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                .contains("missing argument") == true)
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: len / at / slice

    @Test func len() throws {
        #expect(try eval(bytesLen, [by([])]) == i(0))
        #expect(try eval(bytesLen, [by([1, 2, 3, 4])]) == i(4))
    }

    @Test func at() throws {
        let b = by([72, 101, 108, 108, 111]) // "Hello"
        #expect(try eval(bytesAt, [b, i(0)]) == i(72))
        #expect(try eval(bytesAt, [b, i(4)]) == i(111))
        #expect(try eval(bytesAt, [b, i(-1)]) == i(111))
        #expect(try eval(bytesAt, [b, i(1)],
                         named: [FuncHarness.named("default", i(0))]) == i(101))
        #expect(try eval(bytesAt, [b, i(99)],
                         named: [FuncHarness.named("default", i(0))]) == i(0))
    }

    @Test func atOutOfBounds() {
        switch harness.call(bytesAt,
                            harness.args([by([1, 2]), i(5)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "byte index out of bounds (index: 5, len: 2) and no default value was specified")
        case .success:
            Issue.record("expected error")
        }
        switch harness.call(bytesAt,
                            harness.args([by([1, 2]), i(-3)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "byte index out of bounds (index: -3, len: 2) and no default value was specified")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func slice() throws {
        let b = by(Array("0123456789".utf8))
        #expect(try eval(bytesSlice, [b, i(2)]) == by(Array("23456789".utf8)))
        #expect(try eval(bytesSlice, [b, i(2), i(5)]) == by(Array("234".utf8)))
        #expect(try eval(bytesSlice, [b, i(4)],
                         named: [FuncHarness.named("count", i(3))])
            == by(Array("456".utf8)))
        #expect(try eval(bytesSlice, [b, i(-3)]) == by(Array("789".utf8)))
        // `end` and `count` mutually exclusive.
        switch harness.call(bytesSlice,
                            harness.args([b, i(0), i(1)])
                                .appendingNamed("count", i(2))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "`end` and `count` are mutually exclusive")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func sliceOutOfBounds() {
        let b = by(Array("0123456789".utf8))
        switch harness.call(bytesSlice,
                            harness.args([b, i(9)]).appendingNamed("count", i(3))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "byte index out of bounds (index: 12, len: 10)")
        case .success:
            Issue.record("expected error")
        }
    }
}

private extension TypstLibrary.Args {
    func appendingNamed(_ name: String, _ value: Value) -> TypstLibrary.Args {
        var copy = self
        copy.items.append(FuncHarness.named(name, value))
        return copy
    }
}
