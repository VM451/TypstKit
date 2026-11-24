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
    /// Bounds matching upstream `rust_decimal::MIN`/`MAX`
    /// (±79228162514264337593543950335).
    public static let MIN = Decimal.parseUnchecked("-79228162514264337593543950335")
    public static let MAX = Decimal.parseUnchecked("79228162514264337593543950335")

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
        guard isValidLiteral(string.value),
              let d = Decimal(exactly: string.value) else {
            return .failure(StrError("invalid decimal: \(string.repr())"))
        }
        return .success(d)
    }

    /// Whether `s` is a valid `rust_decimal::from_str_exact` literal:
    /// `[+-]? ( digits [. digits?]? | . digits ) ( [eE] [+-]? digits )?`
    /// with at most 29 significant digits and 28 fractional digits.
    public static func isValidLiteral(_ s: String) -> Bool {
        var t = s[...]
        if t.first == "+" || t.first == "-" { t = t.dropFirst() }

        var mantissa = t
        if let eIdx = t.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let exp = t[t.index(after: eIdx)...]
            mantissa = t[..<eIdx]
            var expDigits = exp[...]
            if expDigits.first == "+" || expDigits.first == "-" {
                expDigits = expDigits.dropFirst()
            }
            guard !expDigits.isEmpty,
                  expDigits.allSatisfy(\.isNumber),
                  let expVal = Int64(String(expDigits)),
                  Swift.abs(expVal) <= 9999
            else { return false }
        }

        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let intPart = parts.first.map(String.init) ?? ""
        let fracPart = parts.count == 2 ? String(parts[1]) : ""
        guard intPart.allSatisfy(\.isNumber),
              fracPart.allSatisfy(\.isNumber),
              !intPart.isEmpty || !fracPart.isEmpty
        else { return false }
        // rust_decimal's 96-bit mantissa holds ~28-29 significant digits.
        let significant = (intPart + fracPart).drop(while: { $0 == "0" })
        return significant.count <= 29 && fracPart.count <= 28
    }

    public init(_ int: Int64) { value = Foundation.Decimal(int) }
    /// Lossy convenience init: non-finite or unrepresentable doubles map
    /// to zero. Prefer `fromDoubleExact` where failure should be an error.
    public init(_ double: Double) {
        value = Decimal.fromDoubleExact(double)?.value ?? .zero
    }

    /// `rust_decimal::from_f64_retain`: the exact decimal expansion of the
    /// binary double, rounded to 28 significant digits (rust_decimal's
    /// 96-bit mantissa precision). Returns `nil` when the value cannot be
    /// represented (non-finite, magnitude beyond ~7.9e28, or scale beyond
    /// 28 fractional digits).
    ///
    /// Note: rust_decimal's last-digit rounding can differ by 1 ulp from
    /// correct decimal rounding at the 28th significant digit.
    public static func fromDoubleExact(_ f: Double) -> Decimal? {
        guard f.isFinite, Swift.abs(f) < 7.93e28 else { return nil }
        if f == 0 { return Decimal(Int64(0)) }

        // `%.1074g` prints the exact decimal expansion of any f64.
        // (The `locale:` overload zero-pads instead of computing exact
        // digits — do not use it here.)
        var t = String(format: "%.1074g", f)
        var negative = false
        if t.hasPrefix("-") {
            negative = true
            t.removeFirst()
        } else if t.hasPrefix("+") {
            t.removeFirst()
        }

        var expN = 0
        if let eIdx = t.firstIndex(of: "e") {
            expN = Int(t[t.index(after: eIdx)...]) ?? 0
            t = String(t[..<eIdx])
        }

        let dotIdx = t.firstIndex(of: ".")
        let intPart = dotIdx.map { String(t[..<$0]) } ?? t
        let fracPart = dotIdx.map { String(t[t.index(after: $0)...]) } ?? ""
        // value = Int(digits) * 10^k0
        let k0 = expN - fracPart.count
        let allDigits = (intPart + fracPart)[...].drop(while: { $0 == "0" })
        guard !allDigits.isEmpty else { return Decimal(Int64(0)) }

        // Round the significant digits to 28, half away from zero.
        var sig = Array(allDigits)
        var dropped = 0
        if sig.count > 28 {
            dropped = sig.count - 28
            var kept = Array(sig.prefix(28))
            if sig[28] >= "5" {
                var i = kept.count - 1
                while i >= 0, kept[i] == "9" {
                    kept[i] = "0"
                    i -= 1
                }
                if i < 0 {
                    // 999…9 + 1 → 1000…0 (still 28 digits).
                    kept[0] = "1"
                } else {
                    kept[i] = Character(Unicode.Scalar(
                        Int(String(kept[i]))! + 1)!)
                }
            }
            sig = kept
        }

        // value ≈ Int(sig) * 10^(k0 + dropped). Normalize trailing zeros
        // into the exponent for the minimal scale.
        var k = k0 + dropped
        while sig.count > 1, sig.last == "0" {
            sig.removeLast()
            k += 1
        }
        // rust_decimal's scale is capped at 28 fractional digits.
        guard k >= -28 else { return nil }
        let out = sig.count
        let body = String(sig)

        var text = negative ? "-" : ""
        let pointPos = out + k  // digits before the decimal point
        if pointPos <= 0 {
            text += "0." + String(repeating: "0", count: -pointPos) + body
        } else if pointPos >= out {
            text += body + String(repeating: "0", count: pointPos - out)
        } else {
            text += String(body.prefix(pointPos)) + "."
                + String(body.suffix(out - pointPos))
        }

        guard let d = Decimal(exactly: text) else { return nil }
        return d
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
