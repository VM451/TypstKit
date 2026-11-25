import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `datetime` type scope — mirrors
/// assertions from upstream `tests/suite/foundations/datetime.typ`.
@Suite struct DatetimeTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func dt(_ y: Int, _ m: Int, _ d: Int,
                    _ h: Int? = nil, _ min: Int? = nil, _ s: Int? = nil) -> Value {
        var named: [TypstLibrary.Arg] = [
            FuncHarness.named("year", .int(Int64(y))),
            FuncHarness.named("month", .int(Int64(m))),
            FuncHarness.named("day", .int(Int64(d))),
        ]
        if let h { named.append(FuncHarness.named("hour", .int(Int64(h)))) }
        if let min { named.append(FuncHarness.named("minute", .int(Int64(min)))) }
        if let s { named.append(FuncHarness.named("second", .int(Int64(s)))) }
        return try! eval(datetimeConstruct, [], named: named)
    }

    /// `datetime(hour:minute:second:)` via the constructor.
    private func tt(_ h: Int, _ m: Int, _ sec: Int) -> Value {
        try! eval(datetimeConstruct, [], named: [
            FuncHarness.named("hour", .int(Int64(h))),
            FuncHarness.named("minute", .int(Int64(m))),
            FuncHarness.named("second", .int(Int64(sec))),
        ])
    }

    private func d(_ y: Int, _ m: Int, _ day: Int) -> Value {
        .datetime(.date(TypstDate(year: y, month: m, day: day)!))
    }

    private func tm(_ h: Int, _ m: Int, _ s: Int) -> Value {
        .datetime(.time(TypstTime(hour: h, minute: m, second: s)!))
    }

    /// A full datetime `Value`.
    private func dtv(_ y: Int, _ m: Int, _ day: Int,
                     _ h: Int, _ min: Int, _ s: Int) -> Value {
        .datetime(.datetime(TypstDateTime(
            date: TypstDate(year: y, month: m, day: day)!,
            time: TypstTime(hour: h, minute: min, second: s)!)))
    }

    // MARK: constructor

    @Test func constructEmpty() {
        switch harness.call(datetimeConstruct, harness.args([])) {
        case .failure(let result):
            let diag = result.diagnostics.first
            #expect(diag?.message == "at least one of date or time must be fully specified")
            #expect(diag?.hints.map { $0.value }.contains(
                "add the `hour`, `minute`, and `second` arguments to get a valid time") == true)
            #expect(diag?.hints.map { $0.value }.contains(
                "add the `year`, `month`, and `day` arguments to get a valid date") == true)
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func constructTimeInvalid() {
        let args = harness.args([])
        var a = args
        a.items = [
            FuncHarness.named("hour", .int(25)),
            FuncHarness.named("minute", .int(0)),
            FuncHarness.named("second", .int(0)),
        ]
        switch harness.call(datetimeConstruct, a) {
        case .failure(let result):
            #expect(result.diagnostics.first?.message == "time is invalid")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func constructDateInvalid() {
        var a = harness.args([])
        a.items = [
            FuncHarness.named("year", .int(2000)),
            FuncHarness.named("month", .int(2)),
            FuncHarness.named("day", .int(30)),
        ]
        switch harness.call(datetimeConstruct, a) {
        case .failure(let result):
            #expect(result.diagnostics.first?.message == "date is invalid")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func constructIncomplete() {
        var a = harness.args([])
        a.items = [FuncHarness.named("hour", .int(14))]
        switch harness.call(datetimeConstruct, a) {
        case .failure(let result):
            let diag = result.diagnostics.first
            #expect(diag?.message == "time is incomplete")
            #expect(diag?.hints.map { $0.value }.contains(
                "add the `minute` and `second` arguments to get a valid time") == true)
        case .success:
            Issue.record("expected error")
        }

        var b = harness.args([])
        b.items = [FuncHarness.named("month", .int(5))]
        switch harness.call(datetimeConstruct, b) {
        case .failure(let result):
            let diag = result.diagnostics.first
            #expect(diag?.message == "date is incomplete")
            #expect(diag?.hints.map { $0.value }.contains(
                "add the `year` and `day` arguments to get a valid date") == true)
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func constructKinds() throws {
        #expect(dt(2023, 4, 29) == d(2023, 4, 29))
        #expect(tt(14, 26, 50) == tm(14, 26, 50))
        #expect(dt(2023, 4, 29, 14, 26, 50) == dtv(2023, 4, 29, 14, 26, 50))
    }

    // MARK: display

    @Test func display() throws {
        #expect(try eval(datetimeDisplay, [dt(2023, 4, 29)]) == .str(Str("2023-04-29")))
        #expect(try eval(datetimeDisplay, [dt(2023, 4, 29), .str(Str("[year]"))])
                == .str(Str("2023")))
        #expect(try eval(datetimeDisplay, [dt(2023, 4, 29),
                .str(Str("[year repr:last_two]"))]) == .str(Str("23")))
        #expect(try eval(datetimeDisplay, [dt(2023, 4, 29),
                .str(Str("[year] [month repr:long] [day] [week_number] [weekday]"))])
                == .str(Str("2023 April 29 17 Saturday")))
        #expect(try eval(datetimeDisplay, [tm(14, 26, 50)]) == .str(Str("14:26:50")))
        #expect(try eval(datetimeDisplay, [tm(14, 26, 50), .str(Str("[hour]"))])
                == .str(Str("14")))
        #expect(try eval(datetimeDisplay, [tm(14, 26, 50),
                .str(Str("[hour repr:12 padding:none]"))]) == .str(Str("2")))
        #expect(try eval(datetimeDisplay, [tm(14, 26, 50),
                .str(Str("[hour], [minute], [second]"))]) == .str(Str("14, 26, 50")))
        #expect(try eval(datetimeDisplay, [dt(2023, 4, 29, 14, 26, 50)])
                == .str(Str("2023-04-29 14:26:50")))
    }

    @Test func displayErrors() {
        // `pattern` is positional upstream.
        let a = harness.args([
            .datetime(.date(TypstDate(year: 2023, month: 4, day: 29)!)),
            .str(Str("[year")),
        ])
        switch harness.call(datetimeDisplay, a) {
        case .failure(let result):
            #expect(result.diagnostics.first?.message
                    == "missing closing bracket for bracket at index 0")
        case .success:
            Issue.record("expected error")
        }

        let bad = harness.args([
            .datetime(.date(TypstDate(year: 2023, month: 4, day: 29)!)),
            .str(Str("[nothing]")),
        ])
        switch harness.call(datetimeDisplay, bad) {
        case .failure(let result):
            #expect(result.diagnostics.first?.message
                    == "invalid component name 'nothing' at index 1")
        case .success:
            Issue.record("expected error")
        }

        let insufficient = harness.args([
            .datetime(.date(TypstDate(year: 2023, month: 4, day: 29)!)),
            .str(Str("[hour]")),
        ])
        switch harness.call(datetimeDisplay, insufficient) {
        case .failure(let result):
            #expect(result.diagnostics.first?.message
                    == "failed to format datetime (insufficient information)")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: today

    @Test func today() throws {
        #expect(try eval(datetimeToday, []) == d(1970, 1, 1))
        #expect(try eval(datetimeToday, [],
                        named: [FuncHarness.named("offset", .auto)]) == d(1970, 1, 1))
        #expect(try eval(datetimeToday, [],
                        named: [FuncHarness.named("offset", .int(2))]) == d(1970, 1, 1))
        #expect(try eval(datetimeToday, [],
                        named: [FuncHarness.named("offset", .int(14))]) == d(1970, 1, 2))
        #expect(try eval(datetimeToday, [],
                        named: [FuncHarness.named("offset", .int(-14))]) == d(1969, 12, 31))
        #expect(try eval(datetimeToday, [], named: [FuncHarness.named(
            "offset", .duration(Duration(seconds: 5 * 3600 + 45 * 60)))])
                == d(1970, 1, 1))
    }

    @Test func todayOffsetInvalid() {
        for offset: Value in [.int(24), .duration(Duration.days(-2))] {
            switch harness.call(datetimeToday, {
                var a = harness.args([])
                a.items.append(FuncHarness.named("offset", offset))
                return a
            }()) {
            case .failure(let result):
                #expect(result.diagnostics.first?.message
                        == "unable to get the current date")
            case .success:
                Issue.record("expected error")
            }
        }
    }

    // MARK: accessors

    @Test func accessors() throws {
        let full = dt(2023, 4, 29, 14, 26, 50)
        #expect(try eval(datetimeYear, [full]) == .int(2023))
        #expect(try eval(datetimeMonth, [full]) == .int(4))
        #expect(try eval(datetimeWeekday, [full]) == .int(6))
        #expect(try eval(datetimeDay, [full]) == .int(29))
        #expect(try eval(datetimeHour, [full]) == .int(14))
        #expect(try eval(datetimeMinute, [full]) == .int(26))
        #expect(try eval(datetimeSecond, [full]) == .int(50))
        #expect(try eval(datetimeOrdinal, [full]) == .int(119))

        let dateOnly = dt(2023, 4, 29)
        #expect(try eval(datetimeHour, [dateOnly]) == .none)
        #expect(try eval(datetimeMinute, [dateOnly]) == .none)
        #expect(try eval(datetimeSecond, [dateOnly]) == .none)
        #expect(try eval(datetimeYear, [tm(1, 2, 3)]) == .none)
    }

    @Test func ordinal() throws {
        #expect(try eval(datetimeOrdinal, [dt(2000, 1, 1)]) == .int(1))
        #expect(try eval(datetimeOrdinal, [dt(2000, 3, 1)]) == .int(31 + 29 + 1))
        #expect(try eval(datetimeOrdinal, [dt(2000, 12, 31)]) == .int(366))
        #expect(try eval(datetimeOrdinal, [dt(2001, 3, 1)]) == .int(31 + 28 + 1))
        #expect(try eval(datetimeOrdinal, [dt(2001, 12, 31)]) == .int(365))
    }

    // MARK: duration arithmetic (upstream duration.typ coverage)

    private func dur(_ seconds: Double) -> Value { .duration(Duration(seconds: seconds)) }
    private func add(_ a: Value, _ b: Value) throws -> Value {
        try unwrap(ops_add(a, b))
    }
    private func sub(_ a: Value, _ b: Value) throws -> Value {
        try unwrap(ops_sub(a, b))
    }

    @Test func addSubtractDates() throws {
        let day1 = dt(2000, 1, 1)
        #expect(try add(day1, dur(2 * 604800)) == dt(2000, 1, 15))
        #expect(try add(day1, dur(3 * 86400)) == dt(2000, 1, 4))
        #expect(try add(day1, dur(604800 + 3 * 86400)) == dt(2000, 1, 11))
        #expect(try add(dt(2000, 2, 1), dur(-86400)) == dt(2000, 1, 31))
        #expect(try add(dt(2000, 2, 1), dur(-3 * 86400)) == dt(2000, 1, 29))
        #expect(try add(dt(2000, 2, 1), dur(-604800)) == dt(2000, 1, 25))
        #expect(try add(day1, dur(-86400)) == dt(1999, 12, 31))
        #expect(try add(day1, dur(604800 - 7 * 86400)) == dt(2000, 1, 1))
        #expect(try sub(dt(2000, 2, 1), dur(86400)) == dt(2000, 1, 31))
        #expect(try sub(dt(2000, 2, 1), dur(3 * 86400)) == dt(2000, 1, 29))
        #expect(try sub(dt(2000, 2, 1), dur(604800)) == dt(2000, 1, 25))
        #expect(try sub(day1, dur(86400)) == dt(1999, 12, 31))
        #expect(try add(dt(2000, 1, 31), dur(86400)) == dt(2000, 2, 1))
        #expect(try add(dt(2000, 12, 31), dur(86400)) == dt(2001, 1, 1))
    }

    @Test func addSubtractTimes() throws {
        let noon = tm(12, 0, 0)
        #expect(try add(noon, dur(0)) == tm(12, 0, 0))
        #expect(try add(noon, dur(2 * 3600)) == tm(14, 0, 0))
        #expect(try add(noon, dur(10 * 60)) == tm(12, 10, 0))
        #expect(try add(noon, dur(30)) == tm(12, 0, 30))
        #expect(try add(noon, dur(-2 * 3600)) == tm(10, 0, 0))
        #expect(try sub(noon, dur(2 * 3600)) == tm(10, 0, 0))
        #expect(try add(noon, dur(-10 * 60)) == tm(11, 50, 0))
        #expect(try sub(noon, dur(10 * 60)) == tm(11, 50, 0))
        #expect(try add(noon, dur(-30)) == tm(11, 59, 30))
        #expect(try sub(noon, dur(30)) == tm(11, 59, 30))
        #expect(try add(noon, dur(3600 + 13 * 60 + 13)) == tm(13, 13, 13))
    }

    @Test func addSubtractDateTimes() throws {
        let start = dtv(2000, 1, 1, 12, 0, 0)
        let expected = dtv(2000, 1, 10, 23, 9, 50)
        #expect(try add(start, dur(604800 + 3 * 86400 - 13 * 3600 + 10 * 60 - 10))
                == expected)
        #expect(try sub(try add(start, dur(604800 + 3 * 86400 + 10 * 60)),
                        dur(13 * 3600 + 10))
                == expected)
    }

    @Test func datePromotion() throws {
        // Date + sub-day duration promotes to datetime; midnight collapses.
        #expect(try add(dt(2030, 5, 25), dur(6 * 3600 + 30 * 60 + 19))
                == dtv(2030, 5, 25, 6, 30, 19))
        #expect(try sub(dt(2030, 5, 26), dur(24 * 3600)) == dt(2030, 5, 25))
    }

    @Test func subtractDatetimes() throws {
        #expect(try sub(tm(14, 0, 0), tm(12, 0, 0))
                == dur(2 * 3600))
        #expect(try sub(dt(2000, 2, 1), dt(2000, 1, 1))
                == dur(31 * 86400))
        #expect(try sub(dt(2000, 1, 15), dt(2000, 1, 1))
                == dur(14 * 86400))
    }
}
