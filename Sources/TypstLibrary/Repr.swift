import Foundation
import TypstSyntax
import TypstUtils

/// A trait that defines the `repr` of a Typst value.
///
/// Port of `typst-library/src/foundations/repr.rs`.
public protocol Repr {
    /// Return the debug representation of the value.
    func repr() -> String
}

/// The Unicode minus sign.
public let minusSign = "\u{2212}"

/// Format an integer in a base.
public func formatIntWithBase(_ n: Int64, base: Int64) -> String {
    if n == 0 { return "0" }

    var digits: [UInt8] = []
    var n = n
    let negative = n < 0
    if n > 0 { n = -n }

    while n != 0 {
        let digit = Int(-(n % base))
        let c: Character
        switch digit {
        case 0...9: c = Character(Unicode.Scalar(UInt8(ascii: "0") + UInt8(digit)))
        default: c = Character(Unicode.Scalar(UInt8(ascii: "a") + UInt8(digit - 10)))
        }
        digits.append(contentsOf: String(c).utf8)
        n /= base
    }

    var out = ""
    if negative { out += minusSign }
    return out + String(decoding: digits.reversed(), as: UTF8.self)
}

/// Converts a float to a string representation with a specific precision and
/// a unit, all with a single allocation.
///
/// The returned string is always valid Typst code. As such, it might not be
/// a float literal. For example, it may return `"float.inf"`.
public func formatFloat(
    _ value0: Double,
    precision: UInt8? = nil,
    forceSeparator: Bool = false,
    unit: String = ""
) -> String {
    var value = value0
    if let p = precision {
        value = TypstUtils.roundWithPrecision(value, Int16(p))
    }
    let unitMultiplication = unit.isEmpty ? "" : " * 1"
    if value.isNaN {
        return "float.nan\(unitMultiplication)\(unit)"
    } else if value.isInfinite {
        let sign = value < 0 ? "-" : ""
        return "\(sign)float.inf\(unitMultiplication)\(unit)"
    } else if forceSeparator {
        return "\(value)\(unit)"
    } else {
        return "\(value)\(unit)"
    }
}

/// Converts a float to a string representation with a precision of three
/// decimal places. Intended for larger structures with multiple float
/// components, such as colors.
public func formatFloatComponent(_ value: Double) -> String {
    formatFloat(value, precision: 3, unit: "")
}

/// Converts a float to a string representation with a precision of two
/// decimal places, followed by a unit.
public func formatFloatWithUnit(_ value: Double, unit: String) -> String {
    formatFloat(value, precision: 2, unit: unit)
}

/// Converts a float to a string that can be used to display the float as text.
public func displayFloat(_ value: Double) -> String {
    if value.isNaN {
        return "NaN"
    } else if value.isInfinite {
        let sign = value < 0 ? minusSign : ""
        return "\(sign)∞"
    } else if value < 0 {
        return "\(minusSign)\(abs(value))"
    } else {
        return "\(abs(value))"
    }
}

/// Formats pieces separated with commas and a final "and" or "or".
public func reprSeparatedList(_ pieces: [String], last: String) -> String {
    var buf = ""
    for (i, part) in pieces.enumerated() {
        switch i {
        case 0:
            break
        case 1 where pieces.count == 2:
            buf += " \(last) "
        case let i where i + 1 == pieces.count:
            buf += ", \(last) "
        default:
            buf += ", "
        }
        buf += part
    }
    return buf
}

/// Formats a comma-separated list.
///
/// Tries to format horizontally, but falls back to vertical formatting if
/// the pieces are too long.
public func prettyCommaList(_ pieces: [String], trailingComma: Bool) -> String {
    let maxWidth = 50
    let len = pieces.reduce(0) { $0 + $1.count } + 2 * max(pieces.count - 1, 0)

    var buf = ""
    if len <= maxWidth {
        for (i, piece) in pieces.enumerated() {
            if i > 0 { buf += ", " }
            buf += piece
        }
        if trailingComma { buf += "," }
    } else {
        for piece in pieces {
            buf += piece.trimmingCharacters(in: .whitespaces) + ",\n"
        }
    }
    return buf
}

/// Formats an array-like construct.
///
/// Tries to format horizontally, but falls back to vertical formatting if
/// the pieces are too long.
public func prettyArrayLike(_ parts: [String], trailingComma: Bool) -> String {
    let list = prettyCommaList(parts, trailingComma: trailingComma)
    var buf = "("
    if list.contains("\n") {
        buf += "\n"
        for (i, line) in list.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { buf += "\n" }
            buf += "  " + line
        }
        buf += "\n"
    } else {
        buf += list
    }
    buf += ")"
    return buf
}

// MARK: - Primitive `Repr` conformances and float formatting
// (port of `repr.rs` float helpers)

/// Rust `{:?}` formatting for `f64`: shortest round-trip digits, always a
/// decimal separator for integral values, scientific notation with a bare
/// exponent (`1e300`, `1.5e-7`) outside the plain-decimal range.
func rustDebugFloat(_ value: Double) -> String {
    if value == 0 {
        return value.sign == .minus ? "-0.0" : "0.0"
    }
    var s = "\(value)"
    if let eIdx = s.firstIndex(of: "e") {
        // Normalize exponent: strip '+', strip leading zeros.
        var mantissa = String(s[..<eIdx])
        var exp = String(s[s.index(after: eIdx)...])
        if exp.hasPrefix("+") { exp.removeFirst() }
        while exp.hasPrefix("0"), exp.count > 1 { exp.removeFirst() }
        if !mantissa.contains(".") { mantissa += ".0" }
        // Rust Debug drops ".0" before 'e'? No: 1e300 -> "1e300".
        if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
        return "\(mantissa)e\(exp)"
    }
    if !s.contains(".") { s += ".0" }
    return s
}

/// Rust `{}` formatting for `f64`: never uses scientific notation.
func rustDisplayFloat(_ value: Double) -> String {
    let s = "\(value)"
    guard let eIdx = s.firstIndex(of: "e") else {
        return s
    }
    // Expand "d.ddde±X" into plain decimal.
    var mantissa = String(s[..<eIdx])
    var exp = Int(s[s.index(after: eIdx)...]) ?? 0
    var neg = false
    if mantissa.hasPrefix("-") { neg = true; mantissa.removeFirst() }
    let dotIdx = mantissa.firstIndex(of: ".")
    let intDigits = dotIdx.map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
    let fracDigits = dotIdx.map { d in mantissa.distance(from: mantissa.index(after: d), to: mantissa.endIndex) } ?? 0
    let digits = mantissa.filter { $0 != "." }
    // Position of decimal point after applying exponent.
    let pointPos = intDigits + exp
    var out: String
    if pointPos <= 0 {
        out = "0." + String(repeating: "0", count: -pointPos) + digits
    } else if pointPos >= digits.count {
        out = digits + String(repeating: "0", count: pointPos - digits.count)
    } else {
        let idx = mantissa.index(mantissa.startIndex, offsetBy: pointPos)
        out = String(mantissa[..<idx]) + "." + String(mantissa[idx...]).filter { $0 != "." }
        // digits includes the dot? No — digits filtered '.' out; rebuild carefully:
        out = String(digits.prefix(pointPos)) + "." + String(digits.suffix(digits.count - pointPos))
    }
    // Trim trailing zeros in fraction, then trailing dot.
    if out.contains(".") {
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
    }
    return (neg ? "-" : "") + out
}

/// Port of `repr::format_float`.
public func formatFloat(
    _ value: Double,
    precision: Int? = nil,
    forceSeparator: Bool,
    unit: String = ""
) -> String {
    var v = value
    if let p = precision {
        v = TypstUtils.roundWithPrecision(v, Int16(p))
    }
    let unitMultiplication = unit.isEmpty ? "" : " * 1"
    if v.isNaN {
        return "float.nan\(unitMultiplication)\(unit)"
    } else if v.isInfinite {
        return "\(v < 0 ? "-" : "")float.inf\(unitMultiplication)\(unit)"
    } else if forceSeparator {
        return "\(rustDebugFloat(v))\(unit)"
    } else {
        return "\(rustDisplayFloat(v))\(unit)"
    }
}
extension Bool: Repr {
    public func repr() -> String { self ? "true" : "false" }
}

extension Int64: Repr {
    public func repr() -> String { "\(self)" }
}

extension Int: Repr {
    public func repr() -> String { "\(self)" }
}

extension Double: Repr {
    public func repr() -> String { formatFloat(self, forceSeparator: true) }
}
