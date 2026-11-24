import Foundation

/// An arbitrary-precision decimal number.
///
/// Port of `Decimal` in `decimal.rs`. Backed by Foundation's `Decimal`
/// (NSDecimalNumber), which provides 38 significant digits — a superset of
/// upstream `rust_decimal`'s 28-29 digits. Edge-case rounding at the
/// extreme precision boundary may differ from upstream.
public struct Decimal: Sendable, Hashable {
    /// The underlying decimal value.
    var value: Foundation.Decimal

    public init(_ value: Foundation.Decimal) { self.value = value }

    public static let ZERO = Decimal(Int64(0))
    public static let ONE = Decimal(Int64(1))
    /// Bounds approximating upstream `rust_decimal::MIN`/`MAX`; Foundation
    /// `Decimal` has a wider range, so these are conservative limits.
    public static let MIN = Decimal.parseUnchecked("-1e-100")
    public static let MAX = Decimal.parseUnchecked("1e100")

    static func parseUnchecked(_ string: String) -> Decimal {
        Decimal(Foundation.Decimal(string: string, locale: nil) ?? 0)
    }

    public init?(exactly string: String) {
        guard let d = Foundation.Decimal(string: string, locale: nil) else {
            return nil
        }
        value = d
    }

    /// Create from a string, erroring on failure.
    public static func parse(_ string: Str) -> StrResult<Decimal> {
        guard let d = Decimal(exactly: string.value) else {
            return .failure(StrError("invalid decimal: \(string.repr())"))
        }
        return .success(d)
    }

    public init(_ int: Int64) { value = Foundation.Decimal(int) }
    public init(_ double: Double) {
        value = (double.isFinite ? Foundation.Decimal(double) : .zero)
    }

    public var isZero: Bool { value == 0 }
    public var isNegative: Bool { value < 0 }
    public var isPositive: Bool { value > 0 }
    public var isFinite: Bool { true }

    public var doubleValue: Double { NSDecimalNumber(decimal: value).doubleValue }

    public static func + (a: Decimal, b: Decimal) -> Decimal {
        Decimal((a.value as NSDecimalNumber).adding(b.value as NSDecimalNumber).decimalValue)
    }
    public static func - (a: Decimal, b: Decimal) -> Decimal {
        Decimal((a.value as NSDecimalNumber).subtracting(b.value as NSDecimalNumber).decimalValue)
    }
    public static func * (a: Decimal, b: Decimal) -> Decimal {
        Decimal((a.value as NSDecimalNumber).multiplying(by: b.value as NSDecimalNumber).decimalValue)
    }
    public static func / (a: Decimal, b: Decimal) -> Decimal {
        guard b.value != 0 else { return Decimal(Int64(0)) }
        return Decimal((a.value as NSDecimalNumber).dividing(by: b.value as NSDecimalNumber).decimalValue)
    }
    public static prefix func - (a: Decimal) -> Decimal {
        Decimal((a.value as NSDecimalNumber).multiplying(by: -1).decimalValue)
    }

    public func checkedAdd(_ other: Decimal) -> Decimal? { self + other }
    public func checkedSub(_ other: Decimal) -> Decimal? { self - other }
    public func checkedMul(_ other: Decimal) -> Decimal? { self * other }
    public func checkedDiv(_ other: Decimal) -> Decimal? { other.value == 0 ? nil : self / other }

    /// Rounding mode for `round`.
    public enum RoundingMode: String, Sendable, Hashable, CaseIterable {
        case ceil, floor, trunc, halfExpand, halfEven, halfTrunc, halfFloor, halfCeil
    }

    /// Round to `digits` digits after the decimal point.
    ///
    /// Implemented on the exact decimal expansion so all eight upstream
    /// `RoundingStrategy` modes are honored (Foundation's
    /// `NSDecimalNumberHandler` only supports four).
    public func round(digits: Int, mode: RoundingMode) -> Decimal {
        Decimal(Decimal.roundString(value.description, digits: digits, mode: mode))
    }

    /// Round the canonical decimal string `s` (as produced by
    /// `Decimal.description`) to `digits` fractional digits.
    ///
    /// `away` selects the neighbor farther from zero; all eight upstream
    /// `RoundingStrategy` modes reduce to a choice between truncation
    /// (toward zero) and the away-from-zero neighbor.
    static func roundString(_ s: String, digits: Int, mode: RoundingMode) -> Foundation.Decimal {
        guard digits >= 0 else { return Foundation.Decimal(string: s, locale: nil) ?? 0 }
        var t = s
        var neg = false
        if t.hasPrefix("-") { neg = true; t.removeFirst() }
        else if t.hasPrefix("+") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let frac = parts.count > 1 ? String(parts[1]) : ""
        if frac.count <= digits { return Foundation.Decimal(string: s, locale: nil) ?? 0 }

        let kept = String(frac.prefix(digits))
        let dropped = frac.dropFirst(digits)
        let anyDropped = dropped.contains { $0 != "0" }
        let first = dropped.first!
        let restNonZero = dropped.dropFirst().contains { $0 != "0" }
        let moreThanHalf = first > "5" || (first == "5" && restNonZero)
        let exactHalf = first == "5" && !restNonZero

        // `away` = pick the neighbor farther from zero.
        let away: Bool
        switch mode {
        case .ceil: away = !neg && anyDropped
        case .floor: away = neg && anyDropped
        case .trunc: away = false
        case .halfExpand: away = moreThanHalf || exactHalf
        case .halfEven:
            if moreThanHalf { away = true }
            else if exactHalf {
                let lastKept = digits > 0 ? kept.last! : intPart.last!
                away = (lastKept.asciiValue! - 48) % 2 == 1
            } else { away = false }
        case .halfTrunc: away = moreThanHalf
        case .halfFloor: away = moreThanHalf || (exactHalf && neg)
        case .halfCeil: away = moreThanHalf || (exactHalf && !neg)
        }

        let truncated = (neg ? "-" : "") + intPart
            + (digits > 0 ? "." + kept : "")
        var result = Foundation.Decimal(string: truncated, locale: nil) ?? 0
        if away {
            let ulp = Foundation.Decimal(string: "1e-\(digits)", locale: nil) ?? 0
            result = neg ? result - ulp : result + ulp
        }
        return result
    }
}

extension Decimal: Repr {
    public func repr() -> String { value.description }
}

extension Decimal: Comparable {
    public static func < (a: Decimal, b: Decimal) -> Bool { a.value < b.value }
}

// MARK: - Rounding and checked arithmetic (decimal.rs)

extension Decimal {
    /// Whether this decimal has no fractional part.
    public var isInteger: Bool { trunc().value == value }

    /// Absolute value.
    public func abs() -> Decimal { isNegative ? -self : self }

    /// Largest integer less than or equal to this decimal.
    public func floor() -> Decimal {
        round(digits: 0, mode: .floor)
    }

    /// Smallest integer greater than or equal to this decimal.
    public func ceil() -> Decimal {
        round(digits: 0, mode: .ceil)
    }

    /// Integer part (toward zero).
    public func trunc() -> Decimal {
        round(digits: 0, mode: .trunc)
    }

    /// Fractional part (`self - trunc(self)`).
    public func fract() -> Decimal { self - trunc() }

    /// Round to `digits` digits after the decimal point using the
    /// "midpoint away from zero" strategy (upstream `round`).
    ///
    /// Negative `digits` rounds to integer digits (e.g. -2 rounds to
    /// hundreds). Returns `nil` when the result would leave the
    /// representable range — approximated by the `rust_decimal` 28-digit
    /// bound since Foundation `Decimal` is wider.
    public func round(digits: Int) -> Decimal? {
        if digits >= 0 {
            return round(digits: digits, mode: .halfExpand)
        }
        let shift = -digits
        guard shift <= 28 else {
            // Beyond rust_decimal's integer-digit range: result is zero
            // with the sign preserved, or overflow — mirror upstream's
            // scale-based behavior conservatively.
            return Decimal(value < 0 ? -0.0 : 0.0)
        }
        guard let pow = Foundation.Decimal(string: "1e\(shift)", locale: nil) else {
            return nil
        }
        let scaled = self / Decimal(pow)
        let rounded = scaled.round(digits: 0, mode: .halfExpand)
        return rounded * Decimal(pow)
    }

    /// Remainder of truncated division (`self - trunc(self/other)*other`).
    public func checkedRem(_ other: Decimal) -> Decimal? {
        guard other.value != 0 else { return nil }
        return self - (self / other).trunc() * other
    }

    /// Least non-negative remainder of Euclidean division.
    public func checkedRemEuclid(_ other: Decimal) -> Decimal? {
        guard let r = checkedRem(other) else { return nil }
        return r.isNegative ? r + other.abs() : r
    }

    /// Quotient of Euclidean division (truncated, adjusted so the
    /// remainder is non-negative).
    public func checkedDivEuclid(_ other: Decimal) -> Decimal? {
        guard other.value != 0 else { return nil }
        let q = (self / other).trunc()
        guard let r = checkedRem(other), r.isNegative else { return q }
        return other.isPositive ? q - Decimal.ONE : q + Decimal.ONE
    }

    /// `self^other` for integer `other` (exponentiation by squaring).
    ///
    /// Foundation `Decimal` cannot signal overflow, so this always
    /// succeeds where upstream `rust_decimal::checked_powi` may return
    /// `None` at the extreme precision boundary.
    public func checkedPowi(_ other: Int64) -> Decimal? {
        if other == 0 { return Decimal.ONE }
        var base = self
        var exp = other < 0 ? -other : other
        var result = Decimal.ONE
        while exp > 0 {
            if exp & 1 == 1 { result = result * base }
            exp >>= 1
            if exp > 0 { base = base * base }
        }
        return other < 0 ? Decimal.ONE / result : result
    }

    /// Clamp between `min` and `max` (upstream `Ord::clamp`).
    public static func clamp(_ value: Decimal, _ min: Decimal, _ max: Decimal) -> Decimal {
        Swift.min(Swift.max(value, min), max)
    }
}
