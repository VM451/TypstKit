import Foundation
import TypstUtils

/// Absolute length, stored in "raw" units chosen so all supported units
/// convert to integers. Port of `layout/abs.rs`.
public struct Abs: Numeric, NumericLength, Sendable, Hashable {
    /// The raw scalar value.
    public var raw: Scalar

    public init(raw: Scalar) { self.raw = raw }

    public static let zero = Abs(raw: .zero)
    public static let infinity = Abs(raw: .infinity)

    public init(_ raw: Double) { self.init(raw: Scalar(raw)) }

    public static func withUnit(_ val: Double, _ unit: AbsUnit) -> Abs {
        Abs(raw: Scalar(val * unit.rawScale))
    }

    public static func pt(_ pt: Double) -> Abs { withUnit(pt, .pt) }
    public static func mm(_ mm: Double) -> Abs { withUnit(mm, .mm) }
    public static func cm(_ cm: Double) -> Abs { withUnit(cm, .cm) }
    public static func inches(_ inches: Double) -> Abs { withUnit(inches, .in) }

    public var toRaw: Double { raw.get }
    public var scalar: Scalar { raw }

    public func toUnit(_ unit: AbsUnit) -> Double { toRaw / unit.rawScale }
    public func toPt() -> Double { toUnit(.pt) }
    public func toMm() -> Double { toUnit(.mm) }
    public func toCm() -> Double { toUnit(.cm) }
    public func toInches() -> Double { toUnit(.in) }

    public func abs() -> Abs { Abs(raw: Scalar(toRaw.magnitude)) }
    public func min(_ other: Abs) -> Abs { Abs(raw: Swift.min(raw, other.raw)) }
    public func max(_ other: Abs) -> Abs { Abs(raw: Swift.max(raw, other.raw)) }
    public mutating func setMin(_ other: Abs) { self = min(other) }
    public mutating func setMax(_ other: Abs) { self = max(other) }

    /// Whether `self` is at least `other` (within epsilon).
    public func fits(_ other: Abs) -> Bool { raw + Scalar(AbsUnit.epsilon) >= other.raw }
    public func approxEq(_ other: Abs) -> Bool {
        self == other || Swift.abs((self - other).toRaw) < AbsUnit.epsilon
    }
    public func approxEmpty() -> Bool { toRaw <= AbsUnit.epsilon }
    public func signum() -> Double {
        if toRaw.isNaN { return .nan }
        return toRaw > 0 ? 1 : (toRaw < 0 ? -1 : 0)
    }

    public static var numericZero: Abs { .zero }
    public var isFinite: Bool { raw.isFinite }
}

extension Abs: CustomDebugStringConvertible {
    public var debugDescription: String { "\(toPt())pt" }
}

extension Abs: Repr {
    public func repr() -> String { formatFloatWithUnit(toPt(), unit: "pt") }
}

public func + (lhs: Abs, rhs: Abs) -> Abs { Abs(raw: lhs.raw + rhs.raw) }
public func - (lhs: Abs, rhs: Abs) -> Abs { Abs(raw: lhs.raw - rhs.raw) }
public func * (lhs: Abs, rhs: Double) -> Abs { Abs(raw: lhs.raw * rhs) }
public func * (lhs: Double, rhs: Abs) -> Abs { rhs * lhs }
public func / (lhs: Abs, rhs: Double) -> Abs { Abs(raw: lhs.raw / rhs) }
public func / (lhs: Abs, rhs: Abs) -> Double { lhs.toRaw / rhs.toRaw }
public func % (lhs: Abs, rhs: Abs) -> Abs { Abs(raw: lhs.raw % rhs.raw) }
public prefix func - (x: Abs) -> Abs { Abs(raw: -x.raw) }
public func += (lhs: inout Abs, rhs: Abs) { lhs = lhs + rhs }
public func -= (lhs: inout Abs, rhs: Abs) { lhs = lhs - rhs }
public func *= (lhs: inout Abs, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Abs, rhs: Double) { lhs = lhs / rhs }

/// The unit of an absolute length. Port of `AbsUnit`.
public enum AbsUnit: String, Sendable, Hashable {
    case pt, mm, cm
    /// The Swift case name differs from upstream's `In` to avoid the
    /// keyword; the raw string keeps wire compatibility.
    case `in` = "in"

    static let epsilon = 1e-4

    var rawScale: Double {
        // Chosen so whole numbers in all units are exactly representable.
        switch self {
        case .pt: return 127.0
        case .mm: return 360.0
        case .cm: return 3600.0
        case .in: return 9144.0
        }
    }
}

/// Font-relative length in ems. Port of `layout/em.rs`.
public struct Em: Numeric, NumericLength, Sendable, Hashable {
    public var raw: Scalar

    public init(raw: Scalar) { self.raw = raw }
    public init(_ em: Double) { self.init(raw: Scalar(em)) }

    public static let zero = Em(raw: .zero)
    public static let one = Em(raw: .one)

    public static func new(_ em: Double) -> Em { Em(em) }
    public static func fromUnits(_ units: Double, unitsPerEm: Double) -> Em {
        Em(raw: Scalar(units / unitsPerEm))
    }
    public static func fromAbs(_ length: Abs, fontSize: Abs) -> Em {
        let result = length / fontSize
        return result.isFinite ? Em(raw: Scalar(result)) : .zero
    }
    public static func fromLength(_ length: Length, fontSize: Abs) -> Em {
        length.em + fromAbs(length.abs, fontSize: fontSize)
    }

    public var get: Double { raw.get }
    public func abs() -> Em { Em(raw: Scalar(get.magnitude)) }
    /// Resolve against a font size, yielding an absolute length.
    public func at(_ fontSize: Abs) -> Abs {
        let resolved = fontSize * get
        return resolved.isFinite ? resolved : .zero
    }

    public static var numericZero: Em { .zero }
    public var isFinite: Bool { raw.isFinite }
}

extension Em: CustomDebugStringConvertible {
    public var debugDescription: String { "\(get)em" }
}

extension Em: Repr {
    public func repr() -> String { formatFloatWithUnit(get, unit: "em") }
}

public func + (lhs: Em, rhs: Em) -> Em { Em(raw: lhs.raw + rhs.raw) }
public func - (lhs: Em, rhs: Em) -> Em { Em(raw: lhs.raw - rhs.raw) }
public func * (lhs: Em, rhs: Double) -> Em { Em(raw: lhs.raw * rhs) }
public func * (lhs: Double, rhs: Em) -> Em { rhs * lhs }
public func / (lhs: Em, rhs: Double) -> Em { Em(raw: lhs.raw / rhs) }
public func / (lhs: Em, rhs: Em) -> Double { lhs.get / rhs.get }
public prefix func - (x: Em) -> Em { Em(raw: -x.raw) }
public func += (lhs: inout Em, rhs: Em) { lhs = lhs + rhs }
public func -= (lhs: inout Em, rhs: Em) { lhs = lhs - rhs }
public func *= (lhs: inout Em, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Em, rhs: Double) { lhs = lhs / rhs }

/// An angle. Port of `layout/angle.rs`.
public struct Angle: Numeric, Sendable, Hashable {
    public var raw: Scalar

    public init(raw: Scalar) { self.raw = raw }
    public init(_ raw: Double) { self.init(raw: Scalar(raw)) }

    public static let zero = Angle(raw: .zero)

    public static func withUnit(_ val: Double, _ unit: AngleUnit) -> Angle {
        Angle(raw: Scalar(val * unit.rawScale))
    }
    public static func rad(_ rad: Double) -> Angle { withUnit(rad, .rad) }
    public static func deg(_ deg: Double) -> Angle { withUnit(deg, .deg) }
    public static func fromRatio(_ r: Ratio) -> Angle { rad(r.get * 2.0 * .pi) }

    public var toRaw: Double { raw.get }
    public func toUnit(_ unit: AngleUnit) -> Double { toRaw / unit.rawScale }
    /// Normalize into `[0, 2π)` like Rust's `rem_euclid`.
    public func normalized() -> Angle {
        let tau = 2.0 * Double.pi
        var r = toRad().truncatingRemainder(dividingBy: tau)
        if r < 0 { r += tau }
        return Angle(raw: Scalar(r))
    }
    public func abs() -> Angle { Angle(raw: Scalar(toRaw.magnitude)) }

    public func toRad() -> Double { toUnit(.rad) }
    public func toDeg() -> Double { toUnit(.deg) }
    public func sin() -> Double { Foundation.sin(toRad()) }
    public func cos() -> Double { Foundation.cos(toRad()) }
    public func tan() -> Double { Foundation.tan(toRad()) }

    public static func asin(_ x: Double) -> Angle { rad(Foundation.asin(x)) }
    public static func acos(_ x: Double) -> Angle { rad(Foundation.acos(x)) }
    public static func atan(_ x: Double) -> Angle { rad(Foundation.atan(x)) }
    public static func atan2(_ y: Double, _ x: Double) -> Angle { rad(Foundation.atan2(y, x)) }

    public func quadrant() -> Quadrant {
        let angle = toDeg().truncatingRemainder(dividingBy: 360.0)
        // Rust rem_euclid — adjust negatives into [0, 360).
        let euclid = angle < 0 ? angle + 360.0 : angle
        if euclid <= 90 { return .first }
        if euclid <= 180 { return .second }
        if euclid <= 270 { return .third }
        return .fourth
    }

    public static var numericZero: Angle { .zero }
    public var isFinite: Bool { raw.isFinite }
}

extension Angle: CustomDebugStringConvertible {
    public var debugDescription: String { "\(toDeg())deg" }
}

extension Angle: Repr {
    public func repr() -> String { formatFloatWithUnit(toDeg(), unit: "deg") }
}

public func + (lhs: Angle, rhs: Angle) -> Angle { Angle(raw: lhs.raw + rhs.raw) }
public func - (lhs: Angle, rhs: Angle) -> Angle { Angle(raw: lhs.raw - rhs.raw) }
public func * (lhs: Angle, rhs: Double) -> Angle { Angle(raw: lhs.raw * rhs) }
public func * (lhs: Double, rhs: Angle) -> Angle { rhs * lhs }
public func / (lhs: Angle, rhs: Angle) -> Double { lhs.toRaw / rhs.toRaw }
public func / (lhs: Angle, rhs: Double) -> Angle { Angle(raw: lhs.raw / rhs) }
public prefix func - (x: Angle) -> Angle { Angle(raw: -x.raw) }
public func += (lhs: inout Angle, rhs: Angle) { lhs = lhs + rhs }
public func -= (lhs: inout Angle, rhs: Angle) { lhs = lhs - rhs }
public func *= (lhs: inout Angle, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Angle, rhs: Double) { lhs = lhs / rhs }

/// The unit of an angle. Port of `AngleUnit`.
public enum AngleUnit: Sendable, Hashable {
    case rad, deg

    var rawScale: Double {
        switch self {
        case .rad: return 1.0
        case .deg: return .pi / 180.0
        }
    }
}

/// A quadrant of the unit circle. Port of `Quadrant`.
public enum Quadrant: String, Sendable, Hashable {
    case first, second, third, fourth
}

/// A fraction (`fr`), used for flexible sizing. Port of `layout/fr.rs`.
public struct Fr: Numeric, Sendable, Hashable {
    public var raw: Scalar

    public init(raw: Scalar) { self.raw = raw }
    public init(_ ratio: Double) { self.init(raw: Scalar(ratio)) }

    public static let zero = Fr(raw: .zero)
    public static let one = Fr(raw: .one)
    public static func new(_ ratio: Double) -> Fr { Fr(ratio) }

    public var get: Double { raw.get }
    public func abs() -> Fr { Fr(raw: Scalar(get.magnitude)) }

    /// The absolute share of `remaining` this fraction gets out of `total`.
    public func share(_ total: Fr, remaining: Abs) -> Abs {
        let ratio = self / total
        if ratio.isFinite && remaining.isFinite {
            return ratio * Swift.max(remaining, .zero)
        }
        return .zero
    }

    public static var numericZero: Fr { .zero }
    public var isFinite: Bool { raw.isFinite }
}

extension Fr: CustomDebugStringConvertible {
    public var debugDescription: String { "\(get)fr" }
}

extension Fr: Repr {
    public func repr() -> String { formatFloatWithUnit(get, unit: "fr") }
}

public func + (lhs: Fr, rhs: Fr) -> Fr { Fr(raw: lhs.raw + rhs.raw) }
public func - (lhs: Fr, rhs: Fr) -> Fr { Fr(raw: lhs.raw - rhs.raw) }
public func * (lhs: Fr, rhs: Double) -> Fr { Fr(raw: lhs.raw * rhs) }
public func * (lhs: Double, rhs: Fr) -> Fr { rhs * lhs }
public func / (lhs: Fr, rhs: Fr) -> Double { lhs.get / rhs.get }
public func / (lhs: Fr, rhs: Double) -> Fr { Fr(raw: lhs.raw / rhs) }
public prefix func - (x: Fr) -> Fr { Fr(raw: -x.raw) }
public func += (lhs: inout Fr, rhs: Fr) { lhs = lhs + rhs }
public func -= (lhs: inout Fr, rhs: Fr) { lhs = lhs - rhs }
public func *= (lhs: inout Fr, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Fr, rhs: Double) { lhs = lhs / rhs }

/// A ratio (`%`), stored as a fraction of one. Port of `layout/ratio.rs`.
public struct Ratio: Numeric, Sendable, Hashable {
    public var raw: Scalar

    public init(raw: Scalar) { self.raw = raw }
    public init(_ ratio: Double) { self.init(raw: Scalar(ratio)) }

    public static let zero = Ratio(raw: .zero)
    public static let one = Ratio(raw: .one)
    public static func new(_ ratio: Double) -> Ratio { Ratio(ratio) }

    public var get: Double { raw.get }
    public var scalar: Scalar { raw }
    public func isZero() -> Bool { raw == Scalar.zero }
    public func isOne() -> Bool { raw == Scalar.one }
    public func abs() -> Ratio { Ratio(raw: Scalar(get.magnitude)) }
    public func recip() -> Ratio { Ratio(raw: Scalar(1.0 / get)) }

    /// Resolve the ratio against a whole amount.
    public func of<T: Numeric>(_ whole: T) -> T {
        let resolved = whole.multiplied(by: get)
        return resolved.isFinite ? resolved : T.numericZero
    }

    public static var numericZero: Ratio { .zero }
    public var isFinite: Bool { raw.isFinite }
}

extension Ratio: CustomDebugStringConvertible {
    public var debugDescription: String { "\(get * 100)%" }
}

extension Ratio: Repr {
    public func repr() -> String { formatFloatWithUnit(get * 100.0, unit: "%") }
}

public func + (lhs: Ratio, rhs: Ratio) -> Ratio { Ratio(raw: lhs.raw + rhs.raw) }
public func - (lhs: Ratio, rhs: Ratio) -> Ratio { Ratio(raw: lhs.raw - rhs.raw) }
public func * (lhs: Ratio, rhs: Ratio) -> Ratio { Ratio(raw: lhs.raw * rhs.raw) }
public func * (lhs: Ratio, rhs: Double) -> Ratio { Ratio(raw: lhs.raw * rhs) }
public func * (lhs: Double, rhs: Ratio) -> Ratio { rhs * lhs }
public func / (lhs: Ratio, rhs: Ratio) -> Double { lhs.get / rhs.get }
public func / (lhs: Ratio, rhs: Double) -> Ratio { Ratio(raw: lhs.raw / rhs) }
public func / (lhs: Double, rhs: Ratio) -> Ratio { Ratio(raw: Scalar(lhs / rhs.get)) }
public prefix func - (x: Ratio) -> Ratio { Ratio(raw: -x.raw) }
public func += (lhs: inout Ratio, rhs: Ratio) { lhs = lhs + rhs }
public func -= (lhs: inout Ratio, rhs: Ratio) { lhs = lhs - rhs }
public func *= (lhs: inout Ratio, rhs: Ratio) { lhs = lhs * rhs }
public func *= (lhs: inout Ratio, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Ratio, rhs: Double) { lhs = lhs / rhs }

/// A length with absolute and em components. Port of `layout/length.rs`.
public struct Length: Numeric, NumericLength, Sendable, Hashable {
    public var abs: Abs
    public var em: Em

    public init(abs: Abs, em: Em) {
        self.abs = abs
        self.em = em
    }

    public static let zero = Length(abs: .zero, em: .zero)

    /// The length if at most one component is non-zero (made positive).
    public func tryAbs() -> Length? {
        (abs.isZero() || em.isZero())
            ? Length(abs: abs.abs(), em: em.abs()) : nil
    }

    /// Ratio of the two lengths if they share a single non-zero component.
    public func tryDiv(_ other: Length) -> Double? {
        if abs.isZero() && other.abs.isZero() {
            return em / other.em
        } else if em.isZero() && other.em.isZero() {
            return abs / other.abs
        }
        return nil
    }

    /// Resolve the em component against a font size.
    public func at(_ fontSize: Abs) -> Abs {
        abs + em.at(fontSize)
    }

    public static var numericZero: Length { .zero }
    public var isFinite: Bool { abs.isFinite && em.isFinite }
}

extension Length: Comparable {
    /// Upstream implements only `PartialOrd` (em/abs mixed lengths are
    /// unordered); Swift's `Comparable` can't express that, so comparisons
    /// of mixed lengths return false rather than trapping.
    public static func < (lhs: Length, rhs: Length) -> Bool {
        if lhs.em.isZero() && rhs.em.isZero() {
            return lhs.abs < rhs.abs
        } else if lhs.abs.isZero() && rhs.abs.isZero() {
            return lhs.em < rhs.em
        }
        return false
    }
}

extension Length: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch (abs.isZero(), em.isZero()) {
        case (false, false): return "\(abs) + \(em)"
        case (true, false): return em.debugDescription
        default: return abs.debugDescription
        }
    }
}

extension Length: Repr {
    public func repr() -> String {
        switch (abs.isZero(), em.isZero()) {
        case (false, false): return "\(abs.repr()) + \(em.repr())"
        case (true, false): return em.repr()
        default: return abs.repr()
        }
    }
}

extension Length: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self.init(abs: Abs(value), em: .zero) }
}

public func + (lhs: Length, rhs: Length) -> Length {
    Length(abs: lhs.abs + rhs.abs, em: lhs.em + rhs.em)
}
public func - (lhs: Length, rhs: Length) -> Length {
    Length(abs: lhs.abs - rhs.abs, em: lhs.em - rhs.em)
}
public func * (lhs: Length, rhs: Double) -> Length {
    Length(abs: lhs.abs * rhs, em: lhs.em * rhs)
}
public func * (lhs: Double, rhs: Length) -> Length { rhs * lhs }
public func / (lhs: Length, rhs: Double) -> Length {
    Length(abs: lhs.abs / rhs, em: lhs.em / rhs)
}
public prefix func - (x: Length) -> Length { Length(abs: -x.abs, em: -x.em) }
public func += (lhs: inout Length, rhs: Length) { lhs = lhs + rhs }
public func -= (lhs: inout Length, rhs: Length) { lhs = lhs - rhs }
public func *= (lhs: inout Length, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Length, rhs: Double) { lhs = lhs / rhs }

extension Length {
    public init(_ abs: Abs) { self.init(abs: abs, em: .zero) }
    public init(_ em: Em) { self.init(abs: .zero, em: em) }
}

/// A length relative to a whole (`ratio + abs`). Port of `layout/rel.rs`.
public struct Rel<T: NumericLength> {
    public var rel: Ratio
    public var abs: T

    public init(rel: Ratio, abs: T) {
        self.rel = rel
        self.abs = abs
    }

    public static func zero() -> Rel<T> { Rel(rel: .zero, abs: T.numericZero) }
    public static func one() -> Rel<T> { Rel(rel: .one, abs: T.numericZero) }

    public func isZero() -> Bool { rel.isZero() && abs == T.numericZero }
    public func isOne() -> Bool { rel.isOne() && abs == T.numericZero }

    /// Resolve the ratio against `whole` and add the absolute part.
    public func relativeTo(_ whole: T) -> T {
        rel.of(whole).added(to: abs)
    }

    public func map<U: NumericLength>(_ f: (T) -> U) -> Rel<U> {
        Rel<U>(rel: rel, abs: f(abs))
    }
}

extension Rel: CustomDebugStringConvertible where T: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch (rel.isZero(), abs == T.numericZero) {
        case (false, false): return "\(rel) + \(abs)"
        case (false, true): return rel.debugDescription
        case (true, _): return abs.debugDescription
        }
    }
}

extension Rel: Repr where T: Repr {
    public func repr() -> String { "\(rel.repr()) + \(abs.repr())" }
}

extension Rel: Numeric where T: Numeric {
    public static var numericZero: Rel<T> { .zero() }
    public var isFinite: Bool { rel.isFinite && abs.isFinite }
    public func multiplied(by factor: Double) -> Rel<T> { self * factor }
    public func added(to other: Rel<T>) -> Rel<T> { self + other }
}

extension Rel: Comparable where T: Comparable {
    public static func < (lhs: Rel<T>, rhs: Rel<T>) -> Bool {
        if lhs.rel.isZero() && rhs.rel.isZero() {
            return lhs.abs < rhs.abs
        } else if lhs.abs == T.numericZero && rhs.abs == T.numericZero {
            return lhs.rel < rhs.rel
        }
        return false
    }
}

extension Rel where T == Length {
    /// Ratio of two relative lengths if they share a single non-zero part.
    public func tryDiv(_ other: Rel<Length>) -> Double? {
        if rel.isZero() && other.rel.isZero() {
            return abs.tryDiv(other.abs)
        } else if abs.isZero() && other.abs.isZero() {
            return rel / other.rel
        }
        return nil
    }
}

extension Rel {
    public init(_ abs: T) { self.init(rel: .zero, abs: abs) }
    public init(_ rel: Ratio) { self.init(rel: rel, abs: T.numericZero) }
}

extension Rel where T == Length {
    /// `Rel<Length>` from a pure absolute length (upstream `From<Abs>`).
    public init(_ abs: Abs) { self.init(rel: .zero, abs: Length(abs)) }
    /// `Rel<Length>` from a pure em length (upstream `From<Em>`).
    public init(_ em: Em) { self.init(rel: .zero, abs: Length(em)) }
}

public func + <T: NumericLength>(lhs: Rel<T>, rhs: Rel<T>) -> Rel<T> {
    Rel(rel: lhs.rel + rhs.rel, abs: lhs.abs.added(to: rhs.abs))
}
public func + <T: NumericLength>(lhs: Rel<T>, rhs: T) -> Rel<T> {
    lhs + Rel(rhs)
}
public func + <T: NumericLength>(lhs: Rel<T>, rhs: Ratio) -> Rel<T> {
    lhs + Rel(rel: rhs, abs: T.numericZero)
}
public func + <T: NumericLength>(lhs: Ratio, rhs: T) -> Rel<T> {
    Rel(rel: lhs, abs: T.numericZero) + Rel(rhs)
}
public func - <T: NumericLength>(lhs: Rel<T>, rhs: Rel<T>) -> Rel<T> {
    lhs + (-rhs)
}
public func - <T: NumericLength>(lhs: Rel<T>, rhs: T) -> Rel<T> {
    lhs - Rel(rhs)
}
public func * <T: NumericLength>(lhs: Rel<T>, rhs: Double) -> Rel<T> {
    Rel(rel: lhs.rel * rhs, abs: lhs.abs.multiplied(by: rhs))
}
public func * <T: NumericLength>(lhs: Double, rhs: Rel<T>) -> Rel<T> { rhs * lhs }
public func / <T: NumericLength>(lhs: Rel<T>, rhs: Double) -> Rel<T> {
    Rel(rel: lhs.rel / rhs, abs: lhs.abs.multiplied(by: 1.0 / rhs))
}
public prefix func - <T: NumericLength>(x: Rel<T>) -> Rel<T> {
    Rel(rel: -x.rel, abs: x.abs.multiplied(by: -1.0))
}
public func += <T: NumericLength>(lhs: inout Rel<T>, rhs: Rel<T>) {
    lhs = lhs + rhs
}
public func -= <T: NumericLength>(lhs: inout Rel<T>, rhs: Rel<T>) {
    lhs = lhs - rhs
}
public func *= <T: NumericLength>(lhs: inout Rel<T>, rhs: Double) {
    lhs = lhs * rhs
}
public func /= <T: NumericLength>(lhs: inout Rel<T>, rhs: Double) {
    lhs = lhs / rhs
}

// MARK: - Numeric arithmetic + ordering conformances

extension Abs: Comparable {
    public static func < (lhs: Abs, rhs: Abs) -> Bool { lhs.raw < rhs.raw }
    public func multiplied(by factor: Double) -> Abs { self * factor }
    public func added(to other: Abs) -> Abs { self + other }
}

extension Em: Comparable {
    public static func < (lhs: Em, rhs: Em) -> Bool { lhs.raw < rhs.raw }
    public func multiplied(by factor: Double) -> Em { self * factor }
    public func added(to other: Em) -> Em { self + other }
}

extension Angle: Comparable {
    public static func < (lhs: Angle, rhs: Angle) -> Bool { lhs.raw < rhs.raw }
    public func multiplied(by factor: Double) -> Angle { self * factor }
    public func added(to other: Angle) -> Angle { self + other }
}

extension Fr: Comparable {
    public static func < (lhs: Fr, rhs: Fr) -> Bool { lhs.raw < rhs.raw }
    public func multiplied(by factor: Double) -> Fr { self * factor }
    public func added(to other: Fr) -> Fr { self + other }
}

extension Ratio: Comparable {
    public static func < (lhs: Ratio, rhs: Ratio) -> Bool { lhs.raw < rhs.raw }
    public func multiplied(by factor: Double) -> Ratio { self * factor }
    public func added(to other: Ratio) -> Ratio { self + other }
}

extension Length {
    public func multiplied(by factor: Double) -> Length { self * factor }
    public func added(to other: Length) -> Length { self + other }
}


extension Rel: @unchecked Sendable {}
extension Rel: Hashable where T: Hashable {}
