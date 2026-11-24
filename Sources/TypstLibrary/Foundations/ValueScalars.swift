import TypstUtils
import TypstSyntax
import Foundation

/// The `none` value. Port of `NoneValue` in `none.rs`.
public struct NoneValue: Sendable, Hashable {
    public init() {}
}

extension NoneValue: Repr {
    public func repr() -> String { "none" }
}

/// The `auto` value. Port of `AutoValue` in `auto.rs`.
public struct AutoValue: Sendable, Hashable {
    public init() {}
}

extension AutoValue: Repr {
    public func repr() -> String { "auto" }
}

/// `auto` or a custom value. Port of `Smart<T>` in `auto.rs`.
public enum Smart<T> {
    case auto
    case custom(T)

    public var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    public func isCustomAnd(_ f: (T) -> Bool) -> Bool {
        if case let .custom(x) = self { return f(x) }
        return false
    }

    public func custom() -> T? {
        if case let .custom(x) = self { return x }
        return nil
    }

    public func map<U>(_ f: (T) -> U) -> Smart<U> {
        switch self {
        case .auto: return .auto
        case let .custom(x): return .custom(f(x))
        }
    }

    public func mapOr<U>(_ defaultValue: U, _ f: (T) -> U) -> U {
        switch self {
        case .auto: return defaultValue
        case let .custom(x): return f(x)
        }
    }

    /// `self.or(other)` — custom wins, else other.
    public func or(_ other: Smart<T>) -> Smart<T> {
        switch self {
        case let .custom(x): return .custom(x)
        case .auto: return other
        }
    }

    public func orElse(_ f: () -> Smart<T>) -> Smart<T> {
        switch self {
        case let .custom(x): return .custom(x)
        case .auto: return f()
        }
    }

    public func andThen<U>(_ f: (T) -> Smart<U>) -> Smart<U> {
        switch self {
        case .auto: return .auto
        case let .custom(x): return f(x)
        }
    }

    public func unwrapOr(_ defaultValue: T) -> T {
        switch self {
        case .auto: return defaultValue
        case let .custom(x): return x
        }
    }

    public func unwrapOrElse(_ f: () -> T) -> T {
        switch self {
        case .auto: return f()
        case let .custom(x): return x
        }
    }

    public func unwrapOrDefault() -> T where T: DefaultConstructible {
        unwrapOrElse { T.defaultValue }
    }
}

extension Smart {
    /// `Smart<Smart<T>>::flatten`.
    public func flatten<U>() -> Smart<U> where T == Smart<U> {
        switch self {
        case .auto: return .auto
        case let .custom(inner):
            switch inner {
            case .auto: return .auto
            case let .custom(v): return .custom(v)
            }
        }
    }
}

extension Smart: Repr where T: Repr {
    public func repr() -> String {
        switch self {
        case .auto: return "auto"
        case let .custom(v): return v.repr()
        }
    }
}

extension Smart: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .auto: return "Auto"
        case let .custom(v): return "Custom(\(v))"
        }
    }
}

extension Smart: ExpressibleByNilLiteral {
    /// `nil` maps to `.auto` for ergonomic element defaults.
    public init(nilLiteral: ()) { self = .auto }
}

/// A document label (`<name>`). Port of `Label` in `label.rs`.
///
/// Upstream stores a `PicoStr` (compact interned string); the Swift port
/// uses `InternedString`, which provides the same canonical-handle
/// semantics.
public struct Label: Sendable, Hashable {
    /// The interned label name.
    public var name: InternedString

    /// Create a label, returning nil for the empty name (upstream `new`).
    public init?(name: InternedString) {
        guard name.value != "" else { return nil }
        self.name = name
    }

    /// The resolved (string) form of the label.
    public var resolved: String { name.value }

    /// The inner interned string.
    public var inner: InternedString { name }
}

extension Label: Repr {
    public func repr() -> String {
        let resolved = self.resolved
        if TypstSyntax.isValidLabelLiteralId(resolved) {
            return "<\(resolved)>"
        }
        return "label(\(Str(resolved).repr()))"
    }
}

/// A semantic version (`1.2.3`). Port of `Version` in `version.rs`.
public struct Version: Sendable, Hashable {
    /// The version components (major, minor, patch, ...).
    public var components: [UInt32]

    public init(components: [UInt32] = []) {
        self.components = components
    }

    /// Three-way comparison, matching upstream `Ord` on the component list
    /// (lexicographic; a shorter list that is a prefix compares smaller).
    public func cmp(_ other: Version) -> ComparisonResult {
        for (a, b) in zip(components, other.components) where a != b {
            return a < b ? .orderedAscending : .orderedDescending
        }
        if components.count != other.components.count {
            return components.count < other.components.count
                ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// The named components addressable from Typst.
    public static let componentNames: [String] = ["major", "minor", "patch"]

    /// Get a named component (`major`/`minor`/`patch`) as an integer.
    /// Only components actually present are addressable (upstream zips the
    /// component list with the names).
    public func component(_ name: String) -> StrResult<Int64> {
        for (i, s) in Self.componentNames.enumerated() {
            if i >= components.count { break }
            if s == name {
                return .success(Int64(components[i]))
            }
        }
        return .failure(StrError("unknown version component"))
    }

    /// Get the component at `index`, supporting negative indices.
    public func at(_ index0: Int64) -> StrResult<Int64> {
        var index = index0
        if index < 0 {
            let len = Int64(components.count)
            let pos = len + index
            guard pos >= 0 else {
                return .failure(StrError(
                    "component index out of bounds (index: \(index0), len: \(components.count))"
                ))
            }
            index = pos
        }
        guard index >= 0, let i = Int(exactly: index), i < components.count else {
            return .success(0)
        }
        return .success(Int64(components[i]))
    }

    public mutating func push(_ component: UInt32) {
        components.append(component)
    }
}

extension Version: Comparable {
    /// Versions compare component-wise, missing components read as zero.
    public static func < (lhs: Version, rhs: Version) -> Bool {
        let maxLen = max(lhs.components.count, rhs.components.count)
        for i in 0..<maxLen {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}

extension Version: CustomStringConvertible {
    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}

extension Version: Repr {
    public func repr() -> String {
        let parts = components.map { "\($0)" }
        return "version\(prettyArrayLike(parts, trailingComma: false))"
    }
}

/// Version components accepted by the `version()` constructor.
/// Port of `VersionComponents`.
public enum VersionComponents: Sendable, Hashable {
    case single(UInt32)
    case multiple([UInt32])
}

/// The version a feature was introduced in. Port of `Since`.
public enum Since: Sendable, Hashable {
    case forever
    case version([UInt32])
    case unreleased
}

/// A span of time. Port of `Duration` in `duration.rs`.
///
/// Upstream wraps `time::Duration` (exact integer seconds + nanos); the
/// Swift port stores seconds as `Double`, which is exact for the
/// integer-second inputs Typst produces and matches all observable
/// semantics (ops, repr, decompose).
public struct Duration: Sendable, Hashable {
    /// Seconds (may be fractional).
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public var isZero: Bool { seconds == 0 }

    /// Decompose into `[weeks, days, hours, minutes, seconds]` whole units.
    /// The final component is whole seconds, matching upstream.
    public func decompose() -> [Int64] {
        var tmp = seconds
        let weeks = Int64((tmp / 604800).rounded(.towardZero))
        tmp -= Double(weeks) * 604800
        let days = Int64((tmp / 86400).rounded(.towardZero))
        tmp -= Double(days) * 86400
        let hours = Int64((tmp / 3600).rounded(.towardZero))
        tmp -= Double(hours) * 3600
        let minutes = Int64((tmp / 60).rounded(.towardZero))
        tmp -= Double(minutes) * 60
        let secs = Int64(tmp.rounded(.towardZero))
        return [weeks, days, hours, minutes, secs]
    }
}

extension Duration: Comparable {
    public static func < (lhs: Duration, rhs: Duration) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

extension Duration: CustomDebugStringConvertible {
    public var debugDescription: String { "\(seconds)s" }
}

extension Duration: Repr {
    public func repr() -> String {
        let parts = decompose()
        let names = ["weeks", "days", "hours", "minutes", "seconds"]
        var vec: [String] = []
        for (name, value) in zip(names, parts) where value != 0 {
            vec.append("\(name): \(value)")
        }
        return "duration\(prettyArrayLike(vec, trailingComma: false))"
    }
}

extension Duration {
    public static func seconds(_ s: Int64) -> Duration { Duration(seconds: Double(s)) }
    public static func minutes(_ m: Int64) -> Duration { Duration(seconds: Double(m) * 60) }
    public static func hours(_ h: Int64) -> Duration { Duration(seconds: Double(h) * 3600) }
    public static func days(_ d: Int64) -> Duration { Duration(seconds: Double(d) * 86400) }
    public static func weeks(_ w: Int64) -> Duration { Duration(seconds: Double(w) * 604800) }

    public var secondsValue: Double { seconds }
    public var minutesValue: Double { seconds / 60 }
    public var hoursValue: Double { seconds / 3600 }
    public var daysValue: Double { seconds / 86400 }
    public var weeksValue: Double { seconds / 604800 }
}

public func + (lhs: Duration, rhs: Duration) -> Duration { Duration(seconds: lhs.seconds + rhs.seconds) }
public func - (lhs: Duration, rhs: Duration) -> Duration { Duration(seconds: lhs.seconds - rhs.seconds) }
public prefix func - (x: Duration) -> Duration { Duration(seconds: -x.seconds) }
public func * (lhs: Duration, rhs: Double) -> Duration { Duration(seconds: lhs.seconds * rhs) }
public func * (lhs: Double, rhs: Duration) -> Duration { rhs * lhs }
public func / (lhs: Duration, rhs: Double) -> Duration { Duration(seconds: lhs.seconds / rhs) }
public func / (lhs: Duration, rhs: Duration) -> Double { lhs.seconds / rhs.seconds }


extension Smart: Equatable where T: Equatable {}
extension Smart: @unchecked Sendable {}
extension Smart: Hashable where T: Hashable {}
