import Foundation

/// A calendar date (year, month, day) without time or timezone.
public struct TypstDate: Sendable, Hashable, Comparable {
    public var year: Int
    public var month: Int   // 1-12
    public var day: Int     // 1-31

    public init?(year: Int, month: Int, day: Int) {
        // `time::Date` is bounded to ±9999 years (no `large-dates` feature).
        guard year >= -9999, year <= 9999 else { return nil }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        guard day <= Self.daysInMonth(year: year, month: month) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    public var daysSinceEpoch: Int {
        Self.daysFromCivil(year, month, day)
    }

    /// Days from civil date — works for any year (unlike `init?`, which
    /// enforces the `time::Date` ±9999 bound).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        var y = year, m = month
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    init(daysSinceEpoch z: Int) {
        let zz = z + 719468
        let era = (zz >= 0 ? zz : zz - 146096) / 146097
        let doe = zz - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        day = doy - (153 * mp + 2) / 5 + 1
        month = mp + (mp < 10 ? 3 : -9)
        year = y + (month <= 2 ? 1 : 0)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 0
        }
    }

    static func isLeap(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }

    /// Day of week: 1 = Monday ... 7 = Sunday (ISO).
    public var weekday: Int {
        let d = (daysSinceEpoch + 3) % 7  // 1970-01-01 was Thursday (4)
        return ((d + 7) % 7) + 1
    }

    /// Day of year, 1-based.
    public var ordinal: Int {
        var n = day
        var m = 1
        while m < month { n += Self.daysInMonth(year: year, month: m); m += 1 }
        return n
    }

    public static func < (a: TypstDate, b: TypstDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// A time of day without date or timezone.
public struct TypstTime: Sendable, Hashable, Comparable {
    public var hour: Int     // 0-23
    public var minute: Int   // 0-59
    public var second: Int   // 0-59
    public var nanosecond: Int // 0-999_999_999

    public init?(hour: Int, minute: Int, second: Int, nanosecond: Int = 0) {
        guard (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(second), (0..<1_000_000_000).contains(nanosecond)
        else { return nil }
        self.hour = hour; self.minute = minute; self.second = second; self.nanosecond = nanosecond
    }

    var secondsSinceMidnight: Double {
        Double(hour * 3600 + minute * 60 + second) + Double(nanosecond) / 1e9
    }

    public static func < (a: TypstTime, b: TypstTime) -> Bool {
        a.secondsSinceMidnight < b.secondsSinceMidnight
    }
}

/// A naive date+time combination.
public struct TypstDateTime: Sendable, Hashable, Comparable {
    public var date: TypstDate
    public var time: TypstTime

    public static func < (a: TypstDateTime, b: TypstDateTime) -> Bool {
        (a.date, a.time) < (b.date, b.time)
    }
}

/// A datetime value: date, time, or both.
///
/// Port of `Datetime` in `datetime.rs`.
public enum Datetime: Sendable, Hashable {
    case date(TypstDate)
    case time(TypstTime)
    case datetime(TypstDateTime)

    public static func fromYMD(_ year: Int, _ month: Int, _ day: Int) -> Datetime? {
        TypstDate(year: year, month: month, day: day).map { .date($0) }
    }

    public static func fromHMS(_ hour: Int, _ minute: Int, _ second: Int) -> Datetime? {
        TypstTime(hour: hour, minute: minute, second: second).map { .time($0) }
    }

    public static func fromYMDHMS(_ year: Int, _ month: Int, _ day: Int,
                                  _ hour: Int, _ minute: Int, _ second: Int) -> Datetime? {
        guard let d = TypstDate(year: year, month: month, day: day),
              let t = TypstTime(hour: hour, minute: minute, second: second)
        else { return nil }
        return .datetime(TypstDateTime(date: d, time: t))
    }

    /// Which kind of variant this is.
    public var kind: String {
        switch self {
        case .date: return "date"
        case .time: return "time"
        case .datetime: return "datetime"
        }
    }

    public var year: Int? {
        switch self { case let .date(d): return d.year
                      case let .datetime(dt): return dt.date.year
                      case .time: return nil }
    }
    public var month: Int? {
        switch self { case let .date(d): return d.month
                      case let .datetime(dt): return dt.date.month
                      case .time: return nil }
    }
    public var day: Int? {
        switch self { case let .date(d): return d.day
                      case let .datetime(dt): return dt.date.day
                      case .time: return nil }
    }
    public var weekday: Int? {
        switch self { case let .date(d): return d.weekday
                      case let .datetime(dt): return dt.date.weekday
                      case .time: return nil }
    }
    public var ordinal: Int? {
        switch self { case let .date(d): return d.ordinal
                      case let .datetime(dt): return dt.date.ordinal
                      case .time: return nil }
    }
    public var hour: Int? {
        switch self { case let .time(t): return t.hour
                      case let .datetime(dt): return dt.time.hour
                      case .date: return nil }
    }
    public var minute: Int? {
        switch self { case let .time(t): return t.minute
                      case let .datetime(dt): return dt.time.minute
                      case .date: return nil }
    }
    public var second: Int? {
        switch self { case let .time(t): return t.second
                      case let .datetime(dt): return dt.time.second
                      case .date: return nil }
    }

    /// Three-way comparison (only same-kind pairs are comparable,
    /// matching upstream `PartialOrd for Datetime`).
    /// Returns `nil` for mixed kinds.
    public func partialCmpDatetime(_ other: Datetime) -> ComparisonResult? {
        func ord<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        switch (self, other) {
        case let (.date(a), .date(b)): return ord(a, b)
        case let (.time(a), .time(b)): return ord(a, b)
        case let (.datetime(a), .datetime(b)): return ord(a, b)
        default: return nil
        }
    }
}

extension Datetime {
    /// Add a duration.
    ///
    /// Port of `Add<Duration> for Datetime`: date-only values promote to
    /// `datetime` when the result has a non-midnight time and collapse back
    /// at midnight; times wrap modulo 24 hours.
    public func adding(_ duration: Duration) -> StrResult<Datetime> {
        let offset = duration.seconds
        switch self {
        case let .time(t):
            // `time::Time + Duration` wraps modulo 24h.
            let sod = floorMod(t.secondsSinceMidnight + offset, 86400)
            guard let nt = timeFromSecondsOfDay(sod) else {
                return .failure(StrError("time out of range"))
            }
            return .success(.time(nt))
        case .date, .datetime:
            // `PrimitiveDateTime ± Duration` on the combined instant.
            let base: Double
            switch self {
            case let .date(d):
                base = Double(d.daysSinceEpoch) * 86400
            case let .datetime(dt):
                base = Double(dt.date.daysSinceEpoch) * 86400
                    + dt.time.secondsSinceMidnight
            case .time:
                fatalError("unreachable")
            }
            let total = base + offset
            var dayIndex = (total / 86400).rounded(.down)
            var sod = total - dayIndex * 86400
            if sod >= 86400 { sod -= 86400; dayIndex += 1 }
            guard let days = Int(exactly: dayIndex) else {
                return .failure(StrError("date out of range"))
            }
            let date = TypstDate(daysSinceEpoch: days)
            // Upstream `PrimitiveDateTime` arithmetic panics outside the
            // `time::Date` range (±9999 years); surface it as an error.
            guard date.year >= -9999, date.year <= 9999 else {
                return .failure(StrError("date out of range"))
            }
            guard let time = timeFromSecondsOfDay(sod) else {
                return .failure(StrError("time out of range"))
            }
            if case .date = self, sod == 0 {
                return .success(.date(date))
            }
            return .success(.datetime(TypstDateTime(date: date, time: time)))
        }
    }

    /// Subtract a duration.
    public func subtracting(_ duration: Duration) -> StrResult<Datetime> {
        adding(Duration(seconds: -duration.seconds))
    }

    /// Subtract another datetime, yielding a duration.
    public func subtracting(_ other: Datetime) -> StrResult<Duration> {
        switch (self, other) {
        case let (.time(a), .time(b)):
            return .success(Duration(seconds: a.secondsSinceMidnight - b.secondsSinceMidnight))
        case let (.date(a), .date(b)):
            return .success(Duration(seconds: Double(a.daysSinceEpoch - b.daysSinceEpoch) * 86400))
        case let (.datetime(a), .datetime(b)):
            let da = a.date.daysSinceEpoch - b.date.daysSinceEpoch
            let ta = a.time.secondsSinceMidnight - b.time.secondsSinceMidnight
            return .success(Duration(seconds: Double(da) * 86400 + ta))
        default:
            return .failure(StrError("cannot subtract \(other.kind) from \(kind)"))
        }
    }

}

/// Euclidean modulo for `Double` (`x - m * floor(x / m)`).
private func floorMod(_ x: Double, _ m: Double) -> Double {
    x - m * (x / m).rounded(.down)
}

/// Split seconds-since-midnight into a `TypstTime`, rounding to
/// nanoseconds. `sod` must be in `[0, 86400)`.
private func timeFromSecondsOfDay(_ sod: Double) -> TypstTime? {
    guard sod.isFinite, sod >= 0, sod < 86400 else { return nil }
    // Work in integer nanoseconds — `sod * 1e9` stays exact for any
    // representable input below ~9e15.
    let totalNanos = Int64((sod * 1e9).rounded())
    let secs = totalNanos / 1_000_000_000
    let nanos = Int(totalNanos % 1_000_000_000)
    guard secs < 86_400 else { return nil }
    return TypstTime(
        hour: Int(secs / 3600),
        minute: Int((secs / 60) % 60),
        second: Int(secs % 60),
        nanosecond: nanos)
}

extension Datetime: Comparable {
    public static func < (a: Datetime, b: Datetime) -> Bool {
        switch (a, b) {
        case let (.date(x), .date(y)): return x < y
        case let (.time(x), .time(y)): return x < y
        case let (.datetime(x), .datetime(y)): return x < y
        case let (.datetime(x), .date(y)):
            return TypstDateTime(date: y, time: TypstTime(hour: 0, minute: 0, second: 0)!) < x
        case let (.date(x), .datetime(y)):
            return x < y.date
        case let (.datetime(x), .time(y)):
            return TypstDateTime(date: x.date, time: y) < x
        case let (.time(x), .datetime(y)):
            return x < y.time
        default: return false
        }
    }
}

extension Datetime: Repr {
    public func repr() -> String {
        switch self {
        case let .date(d):
            return "datetime(year: \(d.year), month: \(d.month), day: \(d.day))"
        case let .time(t):
            return "datetime(hour: \(t.hour), minute: \(t.minute), second: \(t.second))"
        case let .datetime(dt):
            let d = dt.date, t = dt.time
            return "datetime(year: \(d.year), month: \(d.month), day: \(d.day), " +
                "hour: \(t.hour), minute: \(t.minute), second: \(t.second))"
        }
    }
}

extension Datetime: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

// MARK: - WorldTime (port of `typst_kit::datetime::Time`)

/// The current date and time source for `World::today`.
///
/// Port of `Time`/`TimeInner` in `typst-kit/src/datetime.rs`: either a
/// fixed instant (reproducible builds) or the system clock (memoized).
public struct WorldTime: Sendable {
    private enum Inner: Sendable {
        /// A fixed UTC instant.
        case fixed(Date)
        /// The system clock, memoized like upstream's `OnceLock`.
        case system(SystemClock)
    }

    /// Memoized system time (upstream `OnceLock<DateTime<Utc>>`).
    private final class SystemClock: @unchecked Sendable {
        private var cached: Date?
        private let lock = NSLock()

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }
            let now = Date()
            cached = now
            return now
        }

        func reset() {
            lock.lock()
            cached = nil
            lock.unlock()
        }
    }

    private let inner: Inner

    private init(_ inner: Inner) { self.inner = inner }

    /// Use a predefined fixed date and time. Errors if `datetime` is
    /// time-only, like upstream `Time::fixed`.
    public static func fixed(_ datetime: Datetime) -> StrResult<WorldTime> {
        let date: TypstDate
        var sod = 0.0
        switch datetime {
        case let .date(d):
            date = d
        case let .datetime(dt):
            date = dt.date
            sod = dt.time.secondsSinceMidnight
        case .time:
            return .failure(StrError("fixed datetime must specify a date"))
        }
        guard date.year >= -9999, date.year <= 9999 else {
            return .failure(StrError("provided fixed date is invalid"))
        }
        let instant = Double(date.daysSinceEpoch) * 86400 + sod
        return .success(WorldTime(.fixed(Date(timeIntervalSince1970: instant))))
    }

    /// Use a fixed unix timestamp (e.g. `SOURCE_DATE_EPOCH`).
    ///
    /// Errors outside chrono's `DateTime` range (years ±262143).
    public static func fixedTimestamp(_ timestamp: Int64) -> StrResult<WorldTime> {
        // `DateTime::from_timestamp` accepts NaiveDateTime's full range
        // (years -262144...=262143); bound by the corresponding instants.
        let minDay = TypstDate.daysFromCivil(-262144, 1, 1)
        let maxDay = TypstDate.daysFromCivil(262143, 12, 31)
        guard timestamp >= Int64(minDay) * 86400,
              timestamp <= Int64(maxDay) * 86400 + 86_399
        else {
            return .failure(StrError("timestamp is out of range"))
        }
        return .success(WorldTime(.fixed(
            Date(timeIntervalSince1970: Double(timestamp)))))
    }

    /// Rely on the system clock.
    public static func system() -> WorldTime {
        WorldTime(.system(SystemClock()))
    }

    /// The current date, optionally shifted by a UTC offset.
    ///
    /// Returns only the date (like upstream). `nil` when the offset is
    /// non-finite or outside the ±24h range `FixedOffset` accepts.
    public func today(_ offset: Duration?) -> Datetime? {
        // UTC seconds of "now", plus the offset the date is read in when
        // no explicit offset is given (local time for the system clock,
        // UTC for a fixed instant).
        let utcSeconds: Double
        var displayOffset = 0.0
        switch inner {
        case let .fixed(date):
            utcSeconds = date.timeIntervalSince1970
        case let .system(clock):
            let now = clock.now()
            utcSeconds = now.timeIntervalSince1970
            if offset == nil {
                displayOffset = Double(
                    TimeZone.current.secondsFromGMT(for: now))
            }
        }

        var seconds = utcSeconds + displayOffset
        if let offset {
            // `offset.seconds().trunc()` then i32 range + `east_opt`
            // (|offset| < 24h strictly).
            let raw = offset.seconds.rounded(.towardZero)
            guard raw.isFinite,
                  raw >= Double(Int32.min), raw <= Double(Int32.max)
            else { return nil }
            let shifted = Int32(raw)
            guard abs(shifted) < 86_400 else { return nil }
            seconds += Double(shifted)
        }

        let days = (seconds / 86400).rounded(.down)
        guard let dayIndex = Int(exactly: days) else { return nil }
        return .date(TypstDate(daysSinceEpoch: dayIndex))
    }

    /// Reset the memoized system time (between compilations).
    public func reset() {
        if case let .system(clock) = inner { clock.reset() }
    }
}

// MARK: - TOML datetime sentinel

extension Datetime {
    /// Rebuild a datetime from a single-key dict carrying the TOML
    /// serde sentinel `$__toml_private_datetime`. Port of upstream
    /// `Datetime::from_toml_dict` — invoked by every map decode path
    /// (toml, and transitively yaml/cbor when a crafted map appears).
    public static func fromTomlDict(_ dict: Dict) -> Datetime? {
        guard dict.count == 1,
              case .str(let s)? = dict.get("$__toml_private_datetime")
        else { return nil }
        let text = s.value

        // [year]-[month]-[day]T[hour]:[minute]:[second]Z — the `Z` is a
        // literal in upstream's format_description (naive datetime).
        if let d = parseISODateTime(text, utcSuffix: true) {
            return fromYMDHMS(d.0, d.1, d.2, d.3, d.4, d.5)
        }
        if let d = parseISODateTime(text, utcSuffix: false) {
            return fromYMDHMS(d.0, d.1, d.2, d.3, d.4, d.5)
        }
        if let d = parseISODate(text) {
            return fromYMD(d.0, d.1, d.2)
        }
        if let t = parseISOTime(text) {
            return fromHMS(t.0, t.1, t.2)
        }
        return nil
    }

    /// Strict `YYYY-MM-DDTHH:MM:SS` (+ optional literal `Z`).
    static func parseISODateTime(_ s: String, utcSuffix: Bool) -> (Int, Int, Int, Int, Int, Int)? {
        var t = s
        if utcSuffix {
            guard t.hasSuffix("Z") else { return nil }
            t.removeLast()
        } else if t.hasSuffix("Z") {
            return nil
        }
        let parts = t.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let ymd = parseISODate(String(parts[0])),
              let hms = parseISOTime(String(parts[1]))
        else { return nil }
        return (ymd.0, ymd.1, ymd.2, hms.0, hms.1, hms.2)
    }

    /// Strict `YYYY-MM-DD`.
    static func parseISODate(_ s: String) -> (Int, Int, Int)? {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2])
        else { return nil }
        return (y, m, d)
    }

    /// Strict `HH:MM:SS`.
    static func parseISOTime(_ s: String) -> (Int, Int, Int)? {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 2, p[1].count == 2, p[2].count == 2,
              let h = Int(p[0]), let m = Int(p[1]), let sec = Int(p[2])
        else { return nil }
        return (h, m, sec)
    }
}
