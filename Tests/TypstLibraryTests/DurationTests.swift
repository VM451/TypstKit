import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `duration` type scope — mirrors
/// assertions from upstream `tests/suite/foundations/duration.typ`.
@Suite struct DurationTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func dur(_ seconds: Double) -> Value { .duration(Duration(seconds: seconds)) }

    /// `duration(...)` via the constructor with named unit args.
    private func construct(
        seconds: Int64 = 0, minutes: Int64 = 0, hours: Int64 = 0,
        days: Int64 = 0, weeks: Int64 = 0
    ) throws -> Value {
        try eval(durationConstruct, [], named: [
            FuncHarness.named("seconds", .int(seconds)),
            FuncHarness.named("minutes", .int(minutes)),
            FuncHarness.named("hours", .int(hours)),
            FuncHarness.named("days", .int(days)),
            FuncHarness.named("weeks", .int(weeks)),
        ])
    }

    // MARK: constructor + unit accessors

    @Test func constructAndAccessors() throws {
        #expect(try construct(hours: 1, weeks: 1)
                == dur(604800 + 3600))
        #expect(try construct(hours: -1, weeks: 1)
                == dur(604800 - 3600))
        #expect(try construct(hours: 23, days: 6)
                == dur(6 * 86400 + 23 * 3600))
        #expect(try construct() == dur(0))

        let d = try construct(minutes: 45, hours: 5)
        #expect(try eval(durationSeconds, [d]) == .float(5 * 3600 + 45 * 60))
        #expect(try eval(durationMinutes, [d]) == .float(345))
        #expect(try eval(durationHours, [d]) == .float(5.75))
        #expect(try eval(durationDays, [d])
                == .float((5 * 3600 + 45 * 60) / 86400))
        #expect(try eval(durationWeeks, [dur(604800)]) == .float(1))
    }

    // MARK: ops (upstream duration.typ)

    @Test func negate() throws {
        #expect(try unwrap(ops_neg(dur(2 * 3600))) == dur(-2 * 3600))
    }

    @Test func addSubtract() throws {
        let oneWeek = try construct(weeks: 1)
        #expect(try unwrap(ops_add(oneWeek, dur(3600)))
                == dur(604800 + 3600))
        #expect(try unwrap(ops_sub(oneWeek, dur(3600)))
                == dur(604800 - 3600))
        // duration(weeks: 1) - duration(hours: 1) == duration(days: 6, hours: 23)
        #expect(try unwrap(ops_sub(dur(604800), dur(3600)))
                == dur(6 * 86400 + 23 * 3600))
    }

    @Test func multiplyDivide() throws {
        #expect(try unwrap(ops_mul(dur(10 * 60), .int(6))) == dur(3600))
        #expect(try unwrap(ops_mul(dur(10 * 60), .int(2))) == dur(20 * 60))
        #expect(try unwrap(ops_mul(dur(10 * 60), .float(2.5))) == dur(25 * 60))
        #expect(try unwrap(ops_div(dur(10 * 60), .float(2))) == dur(5 * 60))
        #expect(try unwrap(ops_div(dur(10 * 60), .float(2.5))) == dur(4 * 60))
        // duration / duration → float
        #expect(try unwrap(ops_div(dur(20 * 60), dur(3600)))
                == .float(1.0 / 3.0))
        #expect(try unwrap(ops_div(dur(20 * 60), dur(10 * 60))) == .float(2))
        #expect(try unwrap(ops_div(dur(20 * 60), dur(8 * 60))) == .float(2.5))
    }

    @Test func compare() throws {
        func ord(_ a: Value, _ b: Value) throws -> ComparisonResult {
            try unwrap(ops_compare(a, b))
        }
        #expect(try ord(dur(20 * 60), dur(10 * 60)) == .orderedDescending)
        #expect(try ord(dur(10 * 60), dur(20 * 60)) == .orderedAscending)
        #expect(try ord(dur(10 * 60), dur(10 * 60)) == .orderedSame)
        #expect(ops_equal(dur(10 * 60), dur(10 * 60)))
        #expect(!ops_equal(dur(10 * 60), dur(20 * 60)))
    }
}
