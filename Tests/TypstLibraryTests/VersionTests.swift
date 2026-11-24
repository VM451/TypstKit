import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `version` type scope — mirrors
/// assertions from upstream `tests/suite/foundations/version.typ`.
@Suite struct VersionTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func v(_ components: [UInt32]) -> Value {
        .version(Version(components: components))
    }

    private func arrayValue(_ values: [Value]) -> Value {
        .array(ArrayValue(values))
    }

    // MARK: constructor

    @Test func construct() throws {
        // Empty.
        #expect(try eval(versionConstruct, []) == v([]))

        // Plain.
        #expect(try eval(versionConstruct, [.int(1), .int(2)]) == v([1, 2]))
        #expect(try eval(versionAt, [v([1, 2]), .int(0)]) == .int(1))

        // Single array argument (flattened).
        #expect(try eval(versionConstruct, [arrayValue([.int(1), .int(2)])])
                == v([1, 2]))

        // Mixed arguments.
        #expect(try eval(versionConstruct, [
            .int(1),
            arrayValue([.int(2), .int(3)]),
            .int(4),
            arrayValue([.int(5), .int(6)]),
            .int(7),
        ]) == v([1, 2, 3, 4, 5, 6, 7]))
        #expect(try eval(versionAt, [
            try eval(versionConstruct, [
                .int(1),
                arrayValue([.int(2), .int(3)]),
                .int(4),
                arrayValue([.int(5), .int(6)]),
                .int(7),
            ]),
            .int(5),
        ]) == .int(6))
    }

    // MARK: equality (zero-padded)

    @Test func equality() {
        #expect(ops_equal(v([]), v([0])))
        #expect(ops_equal(v([0]), v([0, 0])))
        #expect(ops_equal(v([1, 2]), v([1, 2, 0, 0, 0, 0])))
        #expect(!ops_equal(v([1, 2]), v([1, 2, 1])))
        #expect(ops_compare(v([1, 2]), v([1, 2, 0])) == .success(.orderedSame))
    }

    // MARK: at

    @Test func at() throws {
        #expect(try eval(versionAt, [v([1, 2]), .int(1)]) == .int(2))
        // Non-negative out of bounds → 0.
        #expect(try eval(versionAt, [v([1, 2]), .int(4)]) == .int(0))
        // Negative in bounds.
        #expect(try eval(versionAt, [v([1, 2]), .int(-2)]) == .int(1))
        // Negative out of bounds → error.
        switch harness.call(versionAt, harness.args([v([1, 2]), .int(-3)])) {
        case .failure(let result):
            #expect(result.diagnostics.first?.message
                    == "component index out of bounds (index: -3, len: 2)")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: fields

    @Test func fields() throws {
        let ver = v([1, 2, 3])
        let guard_ = SilentBindingGuard(features: Features())
        #expect(try unwrap(ver.field("major", guard: guard_)) == .int(1))
        #expect(try unwrap(ver.field("minor", guard: guard_)) == .int(2))
        #expect(try unwrap(ver.field("patch", guard: guard_)) == .int(3))
    }
}
