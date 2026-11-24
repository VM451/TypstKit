import Foundation
import TypstSyntax
import TypstUtils

// The `datetime` type's associated scope — port of the `#[scope] impl
// Datetime` block in upstream `foundations/datetime.rs`, plus the
// `DisplayPattern`, `Month`, and `TodayOffset` cast types.

// MARK: - Month (upstream `cast! { Month, v: u8 => ... }`)

/// `time::Month` — a calendar month in `1...12`, cast from an integer.
/// Parameter-only type; never stored in a `Value` (no `IntoValue`, like
/// upstream).
struct Month: Sendable, Hashable {
    /// The month number, 1-12.
    var value: Int
}

extension Month: Castable, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { intCastable(value) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        // Two-step cast like upstream: `u8` range check, then
        // `Month::try_from` (1...=12).
        guard case let .int(v) = value else { return .failure(error(value)) }
        guard v >= 0 else {
            return .failure(HintedString("number must be at least zero"))
        }
        guard let u = UInt8(exactly: v) else {
            return .failure(HintedString("number too large"))
        }
        guard (1...12).contains(Int(u)) else {
            return .failure(HintedString("month is invalid"))
        }
        return .success(Month(value: Int(u)))
    }
}

// MARK: - DisplayPattern (upstream `DisplayPattern(Str, OwnedFormatItem)`)

/// A parsed datetime display pattern — the original string plus its
/// compiled `time` format description.
struct DisplayPattern: Sendable {
    /// The pattern source string (what `intoValue` yields).
    var string: Str
    /// The parsed format description.
    var format: TimeFormatItem
}

extension DisplayPattern: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Str.input }
    public static var output: CastInfo { Str.output }
    public static func castable(_ value: Value) -> Bool { Str.castable(value) }

    public func intoValue() -> Value { string.intoValue() }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        let string: Str
        switch Str.fromValue(value) {
        case let .success(s): string = s
        case let .failure(e): return .failure(e)
        }
        do {
            let format = try parseTimeFormatDescription(string.value)
            return .success(DisplayPattern(string: string, format: format))
        } catch let error as TimeFormatParseError {
            return .failure(HintedString(error.typstMessage))
        } catch {
            return .failure(HintedString("\(error)"))
        }
    }
}

// MARK: - TodayOffset (upstream `TodayOffset(Duration)`)

/// The `today` offset: a `Duration`, or an integer interpreted as hours.
struct TodayOffset: Sendable, Hashable {
    var duration: Duration
}

extension TodayOffset: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Duration.input + Int64.input }
    public static var output: CastInfo { Duration.output }
    public static func castable(_ value: Value) -> Bool {
        Duration.castable(value) || Int64.castable(value)
    }

    public func intoValue() -> Value { duration.intoValue() }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        // Arm order like upstream: `Duration` first, then `i64` hours.
        if Duration.castable(value) {
            return Duration.fromValue(value).map { TodayOffset(duration: $0) }
        }
        return Int64.fromValue(value).map {
            TodayOffset(duration: Duration.hours($0))
        }
    }
}

// MARK: - Scope

/// Build the scope containing all `datetime` methods.
func datetimeScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(datetimeToday)
    scope.defineFunc(datetimeDisplay)
    scope.defineFunc(datetimeYear)
    scope.defineFunc(datetimeMonth)
    scope.defineFunc(datetimeWeekday)
    scope.defineFunc(datetimeDay)
    scope.defineFunc(datetimeHour)
    scope.defineFunc(datetimeMinute)
    scope.defineFunc(datetimeSecond)
    scope.defineFunc(datetimeOrdinal)
    return scope
}

/// `datetime` constructor — port of `Datetime::construct`.
let datetimeConstruct = nativeFunc(
    "datetime",
    title: "Datetime",
    since: .version([0, 5, 0]),
    docs: """
        Creates a new datetime.

        You can specify the datetime using a year, month, day, hour, \
        minute, and second.
        """,
    params: [
        NativeParamInfo(name: "year", input: Int32.input,
                        positional: false, named: true),
        NativeParamInfo(name: "month", input: Month.input,
                        positional: false, named: true),
        NativeParamInfo(name: "day", input: UInt8.input,
                        positional: false, named: true),
        NativeParamInfo(name: "hour", input: UInt8.input,
                        positional: false, named: true),
        NativeParamInfo(name: "minute", input: UInt8.input,
                        positional: false, named: true),
        NativeParamInfo(name: "second", input: UInt8.input,
                        positional: false, named: true),
    ],
    returns: Datetime.output
) { _, _, args in
    let year: Int32? = try args.namedT("year")
    let month: Month? = try args.namedT("month")
    let day: UInt8? = try args.namedT("day")
    let hour: UInt8? = try args.namedT("hour")
    let minute: UInt8? = try args.namedT("minute")
    let second: UInt8? = try args.namedT("second")
    try args.finishT()

    // Port of upstream's `format_missing_args`.
    func missingArgs(_ args: [String]) -> String {
        switch args.count {
        case 0: return ""  // unreachable upstream
        case 1: return "the \(args[0]) argument"
        case 2: return "the \(args[0]) and \(args[1]) arguments"
        default:
            return "the \(args.dropLast().joined(separator: ", ")), " +
                "and \(args.last!) arguments"
        }
    }

    let time: TypstTime?
    switch (hour, minute, second) {
    case let (h?, m?, s?):
        guard let t = TypstTime(
            hour: Int(h), minute: Int(m), second: Int(s)
        ) else {
            throw bailHint("time is invalid")
        }
        time = t
    case (nil, nil, nil):
        time = nil
    default:
        var missing: [String] = []
        if hour == nil { missing.append("`hour`") }
        if minute == nil { missing.append("`minute`") }
        if second == nil { missing.append("`second`") }
        throw bailHint(
            "time is incomplete",
            hints: ["add \(missingArgs(missing)) to get a valid time"])
    }

    let date: TypstDate?
    switch (year, month, day) {
    case let (y?, m?, d?):
        guard let dte = TypstDate(
            year: Int(y), month: m.value, day: Int(d)
        ) else {
            throw bailHint("date is invalid")
        }
        date = dte
    case (nil, nil, nil):
        date = nil
    default:
        var missing: [String] = []
        if year == nil { missing.append("`year`") }
        if month == nil { missing.append("`month`") }
        if day == nil { missing.append("`day`") }
        throw bailHint(
            "date is incomplete",
            hints: ["add \(missingArgs(missing)) to get a valid date"])
    }

    switch (date, time) {
    case let (d?, t?):
        return Datetime.datetime(TypstDateTime(date: d, time: t))
    case let (d?, nil):
        return Datetime.date(d)
    case let (nil, t?):
        return Datetime.time(t)
    case (nil, nil):
        throw bailHint(
            "at least one of date or time must be fully specified",
            hints: [
                "add the `hour`, `minute`, and `second` arguments to get a valid time",
                "add the `year`, `month`, and `day` arguments to get a valid date",
            ])
    }
}

/// `datetime.today` — port of `Datetime::today`.
let datetimeToday = nativeFunc(
    "today",
    since: .version([0, 5, 0]),
    docs: "Returns the current date.",
    params: [
        NativeParamInfo(
            name: "offset",
            input: Smart<TodayOffset>.input,
            defaultValue: { .auto },
            positional: false,
            named: true)
    ],
    returns: Datetime.output
) { engine, _, args in
    let offset: Smart<TodayOffset> = try args.namedT("offset") ?? .auto
    try args.finishT()
    let duration = offset.custom()?.duration
    guard let date = engine.world.today(duration) else {
        throw StrError("unable to get the current date")
    }
    return date
}

/// `datetime.display` — port of `Datetime::display`.
let datetimeDisplay = nativeFunc(
    "display",
    since: .version([0, 5, 0]),
    docs: "Displays the datetime in a specified format.",
    params: [
        NativeParamInfo(name: "self", input: Datetime.input, required: true),
        NativeParamInfo(
            name: "pattern",
            input: Smart<DisplayPattern>.input,
            defaultValue: { .auto }),
    ],
    returns: Str.output
) { _, _, args in
    let datetime: Datetime = try args.expectT("self")
    let pattern: Smart<DisplayPattern> = try args.eatT() ?? .auto
    try args.finishT()

    // Default patterns per kind, matching upstream's `pat(...)` calls.
    func defaultPattern(_ source: String) -> TimeFormatItem {
        // These literals are valid by construction (upstream unwraps).
        try! parseTimeFormatDescription(source)
    }

    var date: TypstDate?
    var time: TypstTime?
    switch datetime {
    case let .date(d): (date, time) = (d, nil)
    case let .time(t): (date, time) = (nil, t)
    case let .datetime(dt): (date, time) = (dt.date, dt.time)
    }

    do {
        switch pattern {
        case .auto:
            let source: String
            switch datetime {
            case .date: source = "[year]-[month]-[day]"
            case .time: source = "[hour]:[minute]:[second]"
            case .datetime: source = "[year]-[month]-[day] [hour]:[minute]:[second]"
            }
            return Str(try formatTimeDescription(
                defaultPattern(source), date: date, time: time))
        case let .custom(p):
            return Str(try formatTimeDescription(
                p.format, date: date, time: time))
        }
    } catch let error as TimeFormatFailure {
        throw StrError(error.typstMessage)
    }
}

// MARK: - Field accessors

/// Shared builder for the `Option`-returning datetime accessors.
private func datetimeAccessor(
    _ name: String,
    docs: String,
    value: @escaping @Sendable (Datetime) -> Int64?
) -> NativeFuncData {
    nativeFunc(
        name,
        since: .version([0, 5, 0]),
        docs: docs,
        params: [NativeParamInfo(name: "self", input: Datetime.input, required: true)],
        returns: Optional<Int64>.output
    ) { _, _, args in
        let datetime: Datetime = try args.expectT("self")
        try args.finishT()
        return value(datetime).map { Value.int($0) } ?? .none
    }
}

let datetimeYear = datetimeAccessor(
    "year",
    docs: "The year if it was specified, or `{none}` for times without a date."
) { $0.year.map(Int64.init) }

let datetimeMonth = datetimeAccessor(
    "month",
    docs: "The month if it was specified, or `{none}` for times without a date."
) { $0.month.map(Int64.init) }

let datetimeWeekday = datetimeAccessor(
    "weekday",
    docs: """
        The weekday (counting Monday as 1) or `{none}` for times without \
        a date.
        """
) { $0.weekday.map(Int64.init) }

let datetimeDay = datetimeAccessor(
    "day",
    docs: "The day if it was specified, or `{none}` for times without a date."
) { $0.day.map(Int64.init) }

let datetimeHour = datetimeAccessor(
    "hour",
    docs: "The hour if it was specified, or `{none}` for dates without a time."
) { $0.hour.map(Int64.init) }

let datetimeMinute = datetimeAccessor(
    "minute",
    docs: "The minute if it was specified, or `{none}` for dates without a time."
) { $0.minute.map(Int64.init) }

let datetimeSecond = datetimeAccessor(
    "second",
    docs: "The second if it was specified, or `{none}` for dates without a time."
) { $0.second.map(Int64.init) }

let datetimeOrdinal = datetimeAccessor(
    "ordinal",
    docs: "The ordinal (day of the year), or `{none}` for times without a date."
) { $0.ordinal.map(Int64.init) }
