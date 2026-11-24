import Foundation

/// Rounds `value` to `precision` decimal digits.
///
/// Port of `round_with_precision`/`round_int_with_precision` in
/// `typst-utils/src/round.rs`.

/// The number of mantissa digits in an `f64` (Rust's
/// `f64::MANTISSA_DIGITS`).
private let mantissaDigits = 53
/// `f64::DIGITS` — decimal digits of precision.
private let floatDigits = 15
/// `f64::MAX_10_EXP`.
private let max10Exp = 308

/// `10^x` for integral `x`.
private func exp10(_ x: Int) -> Double {
    pow(10.0, Double(x))
}

public func roundWithPrecision(_ value: Double, _ precision: Int16) -> Double {
    // Don't attempt to round the float if that wouldn't have any effect.
    // This includes infinite or NaN values, as well as integer values
    // with a filled mantissa (which can't have a fractional part).
    // Rounding with a precision larger than the amount of digits that can
    // be effectively represented would also be a no-op.
    if value.isInfinite
        || value.isNaN
        || (precision >= 0 && abs(value) >= Double(Int64(1) << mantissaDigits))
        || precision >= Int16(floatDigits)
    {
        return value
    }
    // Floats cannot have more than this amount of base-10 integer digits.
    if precision < -Int16(max10Exp) {
        // Multiply by zero to ensure sign is kept.
        return value * 0.0
    }
    if precision > 0 {
        let offset = exp10(Int(precision))
        precondition((value * offset).isFinite, "\(value) * \(offset) is not finite!")
        return (value * offset).rounded() / offset
    } else {
        // Divide instead of multiplying by a negative exponent.
        let offset = exp10(Int(-precision))
        return (value / offset).rounded() * offset
    }
}

public func roundIntWithPrecision(_ value: Int64, _ precision: Int16) -> Int64? {
    if precision >= 0 {
        return value
    }

    let digits = UInt32(-precision)
    guard let tenToDigits = pow10i64(digits - 1) else {
        // Larger than any possible amount of integer digits.
        return 0
    }

    // Divide by 10^(digits - 1), keeping the first removed digit for
    // rounding purposes.
    let truncated = value / tenToDigits
    if truncated == 0 {
        return 0
    }

    let rem = truncated % 10
    let rounded: Int64
    if abs(rem) >= 5 {
        // Round away from zero; may overflow for MAX/MIN with -1.
        let (sum, overflow) = truncated.addingReportingOverflow(
            (truncated >= 0 ? 1 : -1) * (10 - abs(rem))
        )
        guard !overflow else { return nil }
        rounded = sum
    } else {
        rounded = truncated - rem
    }

    // Multiply back by 10^(digits - 1); may overflow.
    let (product, overflow) = rounded.multipliedReportingOverflow(by: tenToDigits)
    return overflow ? nil : product
}

/// `10^exp` as `Int64`, or nil on overflow.
private func pow10i64(_ exp: UInt32) -> Int64? {
    var result: Int64 = 1
    for _ in 0..<exp {
        let (next, overflow) = result.multipliedReportingOverflow(by: 10)
        if overflow { return nil }
        result = next
    }
    return result
}
