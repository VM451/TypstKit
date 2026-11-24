import Foundation

/// A calendar date (year, month, day) without time or timezone.
public struct TypstDate: Sendable, Hashable, Comparable {
    public var year: Int
    public var month: Int   // 1-12
    public var day: Int     // 1-31

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        guard day <= Self.daysInMonth(year: year, month: month) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    public var daysSinceEpoch: Int {
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

    /// Display with a pattern like "[year]-[month]-[day] [hour]:[minute]".
    /// Supports [year] [month] [day] [hour] [minute] [second] [weekday] [ordinal].
    public func display(_ pattern: String) -> String {
        var out = ""
        var i = pattern.startIndex
        while i < pattern.endIndex {
            if pattern[i] == "[" {
                if let close = pattern[i...].firstIndex(of: "]") {
                    let key = String(pattern[pattern.index(after: i)..<close])
                    out += componentString(key) ?? "[\(key)]"
                    i = pattern.index(after: close)
                    continue
                }
            }
            out.append(pattern[i])
            i = pattern.index(after: i)
        }
        return out
    }

    func componentString(_ key: String) -> String? {
        func pad(_ v: Int?, _ width: Int) -> String? {
            v.map { String(format: "%0\(width)d", $0) }
        }
        switch key {
        case "year": return year.map(String.init)
        case "month": return pad(month, 2)
        case "day": return pad(day, 2)
        case "hour": return pad(hour, 2)
        case "minute": return pad(minute, 2)
        case "second": return pad(second, 2)
        case "weekday": return weekday.map { ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][$0] }
        case "ordinal": return ordinal.map(String.init)
        default: return nil
        }
    }

    /// Display using a named pattern.
    public func displayNamed(_ name: String) -> StrResult<String> {
        switch name {
        case "year": return .success(display("[year]"))
        case "month": return .success(display("[month]"))
        case "day": return .success(display("[day]"))
        case "hour": return .success(display("[hour]"))
        case "minute": return .success(display("[minute]"))
        case "second": return .success(display("[second]"))
        case "weekday": return .success(display("[weekday]"))
        case "ordinal": return .success(display("[ordinal]"))
        default: return .failure(StrError("unknown datetime display pattern: \(name.typstRepr)"))
        }
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
    public func adding(_ duration: Duration) -> StrResult<Datetime> {
        let secs = duration.seconds
        switch self {
        case let .time(t):
            let total = t.secondsSinceMidnight + secs
            let dayDelta = Int((total / 86400).rounded(.down))
            let sod = total - Double(dayDelta) * 86400
            guard sod >= 0, let nt = TypstTime(
                hour: Int(sod / 3600),
                minute: Int((sod.truncatingRemainder(dividingBy: 3600)) / 60),
                second: Int(sod.truncatingRemainder(dividingBy: 60)),
                nanosecond: Int((sod.truncatingRemainder(dividingBy: 1)) * 1e9)
            ) else { return .failure(StrError("time out of range")) }
            return .success(.time(nt))
        case let .date(d):
            guard let nd = dateByAddingDays(d, days: Int((secs / 86400).rounded(.towardZero))) else {
                return .failure(StrError("date out of range"))
            }
            return .success(.date(nd))
        case let .datetime(dt):
            // Promote to day math on the date part.
            let dayDelta = Int((secs / 86400).rounded(.towardZero))
            let rem = secs - Double(dayDelta) * 86400
            guard let nd = dateByAddingDays(dt.date, days: dayDelta),
                  let nt = timeByAddingSeconds(dt.time, seconds: rem) else {
                return .failure(StrError("datetime out of range"))
            }
            return .success(.datetime(TypstDateTime(date: nd, time: nt)))
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

    private func dateByAddingDays(_ d: TypstDate, days: Int) -> TypstDate? {
        TypstDate(daysSinceEpoch: d.daysSinceEpoch + days)
    }

    private func timeByAddingSeconds(_ t: TypstTime, seconds: Double) -> TypstTime? {
        let total = t.secondsSinceMidnight + seconds
        guard total >= 0, total < 86400 else { return nil }
        return TypstTime(
            hour: Int(total / 3600),
            minute: Int(total.truncatingRemainder(dividingBy: 3600) / 60),
            second: Int(total.truncatingRemainder(dividingBy: 60)),
            nanosecond: Int(total.truncatingRemainder(dividingBy: 1) * 1e9)
        )
    }
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
