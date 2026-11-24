import Foundation
import TypstSyntax
import TypstUtils

// The `int` type's associated scope — port of the `#[scope] impl i64`
// block in upstream `foundations/int.rs`.

/// A value convertible to an integer in the `int()` constructor.
/// Port of upstream's `ToInt` cast enum.
enum ToInt: Sendable, Hashable {
    case int(Int64)
    case str(Str)
}

extension ToInt: Castable, IntoValue, FromValue {
    static var input: CastInfo {
        Int64.input + Bool.input + Double.input + Decimal.input + Str.input
    }
    static var output: CastInfo { input }

    static func castable(_ value: Value) -> Bool {
        switch value {
        case .int, .bool, .float, .decimal, .str: return true
        default: return false
        }
    }

    func intoValue() -> Value {
        switch self {
        case .int(let n): return .int(n)
        case .str(let s): return .str(s)
        }
    }

    static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .int(let n): return .success(.int(n))
        case .bool(let b): return .success(.int(b ? 1 : 0))
        case .float(let f):
            switch convertFloatToInt(f) {
            case .success(let n): return .success(.int(n))
            case .failure(let e): return .failure(HintedString(e.message))
            }
        case .decimal(let d):
            // `i64::try_from(Decimal)` — truncates toward zero, errors
            // when out of range ("number too large").
            switch decimalToInt64Exact(d) {
            case .success(let n): return .success(.int(n))
            case .failure(let e): return .failure(e)
            }
        case .str(let s): return .success(.str(s))
        default: return .failure(error(value))
        }
    }
}

/// Exact `Decimal -> i64` conversion matching upstream
/// `i64::try_from(Decimal)`: truncation toward zero, "number too large"
/// on overflow. Works on the decimal's canonical string so huge precise
/// values don't lose accuracy through `Double`.
private func decimalToInt64Exact(_ d: Decimal) -> HintedStrResult<Int64> {
    // `NSDecimalNumber.stringValue` yields the full-precision decimal
    // (possibly exponent form like "1.5E+3").
    let s = NSDecimalNumber(decimal: d.value).stringValue
    guard let n = parseDecimalStringToInt64(s) else {
        return .failure(HintedString("number too large"))
    }
    return .success(n)
}

/// Parse a decimal string (`[-]digits[.digits][eE[+-]digits]`) into i64,
/// truncating toward zero. Returns nil on overflow or malformed input.
private func parseDecimalStringToInt64(_ s: String) -> Int64? {
    var text = s.lowercased()
    var negative = false
    if text.hasPrefix("-") {
        negative = true
        text.removeFirst()
    } else if text.hasPrefix("+") {
        text.removeFirst()
    }

    // Split mantissa and exponent.
    var exponent = 0
    if let eIdx = text.firstIndex(where: { $0 == "e" }) {
        let expStr = String(text[text.index(after: eIdx)...])
        guard let e = Int(expStr) else { return nil }
        exponent = e
        text = String(text[..<eIdx])
    }

    // Collect digits and fraction length.
    var digits = ""
    var fracLen = 0
    var seenDot = false
    var seenDigit = false
    for ch in text {
        if ch == "." {
            if seenDot { return nil }
            seenDot = true
        } else if ch.isNumber {
            seenDigit = true
            digits.append(ch)
            if seenDot { fracLen += 1 }
        } else {
            return nil
        }
    }
    guard seenDigit else { return nil }

    // Effective decimal exponent: value = digits * 10^(exponent - fracLen).
    var scale = exponent - fracLen
    // Truncate toward zero: drop `scale` fractional digits when negative.
    var magDigits = digits
    while scale < 0 && !magDigits.isEmpty {
        magDigits.removeLast()
        scale += 1
    }
    // Positive scale multiplies — accumulate with overflow checks.
    var result: UInt64 = 0
    let limit: UInt64 = negative
        ? UInt64(Int64.min.magnitude) : UInt64(Int64.max)
    for ch in magDigits {
        guard let d = ch.wholeNumberValue else { return nil }
        let (m1, o1) = result.multipliedReportingOverflow(by: 10)
        let (m2, o2) = m1.addingReportingOverflow(UInt64(d))
        if o1 || o2 { return nil }
        result = m2
    }
    // Apply positive scale (powers of ten) with overflow check.
    while scale > 0 {
        let (m, o) = result.multipliedReportingOverflow(by: 10)
        if o || m > limit { return nil }
        result = m
        scale -= 1
    }
    guard result <= limit else { return nil }
    if negative {
        return Int64(bitPattern: 0 &- result)
    }
    return Int64(result)
}

/// The error kinds produced by Rust's `from_str_radix`, mapped to
/// upstream's `parse_str_error` messages.
private enum IntParseError: Error {
    case empty
    case invalidDigit
    case posOverflow
    case negOverflow
    case other
}

/// Parse `s` (no sign) as a magnitude in `radix`, matching Rust's
/// `u64::from_str_radix`/`i64::from_str_radix` digit rules (0-9, a-z,
/// A-Z) including the optional leading `+`.
/// Digit value for Typst's radix parsing: 0-9 then a-z/A-Z (radix ≤ 36).
/// Rust's `char::to_digit` — `Character.hexDigitValue` only covers 0-9a-f.
private func radixDigit(_ ch: Character) -> Int? {
    guard let ascii = ch.asciiValue else { return nil }
    switch ascii {
    case 48...57: return Int(ascii - 48)          // 0-9
    case 97...122: return Int(ascii - 97) + 10    // a-z
    case 65...90: return Int(ascii - 65) + 10     // A-Z
    default: return nil
    }
}

private func parseMagnitude(
    _ s: String, radix: Int, limit: UInt64, negative: Bool = false
) -> Result<UInt64, IntParseError> {
    var digits = s[...]
    if digits.first == "+" { digits = digits.dropFirst() }
    if digits.isEmpty { return .failure(.empty) }

    var result: UInt64 = 0
    for ch in digits {
        guard let digit = radixDigit(ch), digit < radix else {
            return .failure(.invalidDigit)
        }
        let (m1, o1) = result.multipliedReportingOverflow(by: UInt64(radix))
        let (m2, o2) = m1.addingReportingOverflow(UInt64(digit))
        if o1 || o2 || m2 > limit {
            return .failure(negative ? .negOverflow : .posOverflow)
        }
        result = m2
    }
    return .success(result)
}

/// `int(..)` — port of `i64::construct`.
let intConstruct = nativeFunc(
    "int",
    title: "Integer",
    since: .forever,
    docs: "Converts a value to an integer.",
    params: [
        NativeParamInfo(
            name: "value",
            input: ToInt.input,
            positional: true,
            required: true),
        NativeParamInfo(
            name: "base",
            input: Base.input,
            defaultValue: { .int(10) },
            positional: false,
            named: true),
    ],
    returns: Int64.output
) { _, _, args in
    let value: Spanned<ToInt, Span> = try args.expectT("value")
    let baseArg: Spanned<Base, Span>? = try args.namedT("base")
    try args.finishT()

    // Upstream default: `Base::Default` at a detached span.
    let base = baseArg ?? Spanned(Base.default, span: .detached)

    switch value.value {
    case .int(let n):
        if case .user = base.value {
            throw bailSpan(base.span, "base is only supported for strings")
        }
        return n
    case .str(let s):
        let baseValue = base.value.value
        guard (2...36).contains(baseValue) else {
            throw bailSpan(base.span, "base must be between 2 and 36")
        }
        let radix = Int(baseValue)

        // Strip a leading `-` or U+2212 minus sign; the magnitude is then
        // parsed as u64 so that `int.min` is representable.
        var text = s.value
        var negative = false
        if text.hasPrefix("-") || text.hasPrefix(minusSign) {
            negative = true
            text = String(text.dropFirst())
        }

        if negative {
            switch parseMagnitude(text, radix: radix,
                                  limit: UInt64(Int64.min.magnitude),
                                  negative: true) {
            case .success(let mag):
                // `wrapping_neg` on the i64 bit pattern.
                return Int64(bitPattern: (0 as UInt64) &- mag)
            case .failure(let kind):
                throw intParseError(kind, base: baseValue,
                                    span: value.span)
            }
        } else {
            switch parseMagnitude(text, radix: radix,
                                  limit: UInt64(Int64.max)) {
            case .success(let mag):
                return Int64(mag)
            case .failure(let kind):
                throw intParseError(kind, base: baseValue,
                                    span: value.span)
            }
        }
    }
}

/// Upstream `parse_str_error` — errors are reported at the value's span.
private func intParseError(
    _ kind: IntParseError, base: Int64, span: Span
) -> SourceDiagnostics {
    switch kind {
    case .empty:
        return bailSpan(span, "string must not be empty")
    case .invalidDigit:
        if base == 10 {
            return bailSpan(span, "string contains invalid digits")
        }
        return bailSpan(
            span, "string contains invalid digits for a base \(base) integer")
    case .posOverflow:
        return bailSpan(span, "integer value is too large", hints: [
            "value does not fit into a signed 64-bit integer",
            "try using a floating point number",
        ])
    case .negOverflow:
        return bailSpan(span, "integer value is too small", hints: [
            "value does not fit into a signed 64-bit integer",
            "try using a floating point number",
        ])
    case .other:
        return bailSpan(span, "invalid integer")
    }
}

/// `int.signum` — port of `i64::signum`.
let intSignum = nativeFunc(
    "signum",
    since: .version([0, 11, 0]),
    docs: """
        Calculates the sign of an integer.

        - If the number is positive, returns `{1}`.
        - If the number is negative, returns `{-1}`.
        - If the number is zero, returns `{0}`.
        """,
    params: [
        NativeParamInfo(name: "self", input: Int64.input, required: true)
    ],
    returns: Int64.output
) { _, _, args in
    let n: Int64 = try args.expectT("self")
    try args.finishT()
    return n.signum()
}

/// `int.bit-not` — port of `i64::bit_not`.
let intBitNot = nativeFunc(
    "bit-not",
    title: "Bitwise NOT",
    since: .version([0, 11, 0]),
    docs: """
        Calculates the bitwise NOT of an integer.

        For the purposes of this function, the operand is treated as a \
        signed integer of 64 bits.
        """,
    params: [
        NativeParamInfo(name: "self", input: Int64.input, required: true)
    ],
    returns: Int64.output
) { _, _, args in
    let n: Int64 = try args.expectT("self")
    try args.finishT()
    return ~n
}

/// Shared param list for the binary bitwise ops.
private func bitOpParams() -> [NativeParamInfo] {
    [
        NativeParamInfo(name: "self", input: Int64.input, required: true),
        NativeParamInfo(name: "rhs", input: Int64.input, required: true),
    ]
}

/// `int.bit-and` — port of `i64::bit_and`.
let intBitAnd = nativeFunc(
    "bit-and",
    title: "Bitwise AND",
    since: .version([0, 11, 0]),
    docs: """
        Calculates the bitwise AND between two integers.

        For the purposes of this function, the operands are treated as \
        signed integers of 64 bits.
        """,
    params: bitOpParams(),
    returns: Int64.output
) { _, _, args in
    let lhs: Int64 = try args.expectT("self")
    let rhs: Int64 = try args.expectT("rhs")
    try args.finishT()
    return lhs & rhs
}

/// `int.bit-or` — port of `i64::bit_or`.
let intBitOr = nativeFunc(
    "bit-or",
    title: "Bitwise OR",
    since: .version([0, 11, 0]),
    docs: """
        Calculates the bitwise OR between two integers.

        For the purposes of this function, the operands are treated as \
        signed integers of 64 bits.
        """,
    params: bitOpParams(),
    returns: Int64.output
) { _, _, args in
    let lhs: Int64 = try args.expectT("self")
    let rhs: Int64 = try args.expectT("rhs")
    try args.finishT()
    return lhs | rhs
}

/// `int.bit-xor` — port of `i64::bit_xor`.
let intBitXor = nativeFunc(
    "bit-xor",
    title: "Bitwise XOR",
    since: .version([0, 11, 0]),
    docs: """
        Calculates the bitwise XOR between two integers.

        For the purposes of this function, the operands are treated as \
        signed integers of 64 bits.
        """,
    params: bitOpParams(),
    returns: Int64.output
) { _, _, args in
    let lhs: Int64 = try args.expectT("self")
    let rhs: Int64 = try args.expectT("rhs")
    try args.finishT()
    return lhs ^ rhs
}

/// `int.bit-lshift` — port of `i64::bit_lshift`.
let intBitLshift = nativeFunc(
    "bit-lshift",
    title: "Bitwise Left Shift",
    since: .version([0, 11, 0]),
    docs: """
        Shifts the operand's bits to the left by the specified amount.

        For the purposes of this function, the operand is treated as a \
        signed integer of 64 bits. An error will occur if the result is \
        too large to fit in a 64-bit integer.
        """,
    params: [
        NativeParamInfo(name: "self", input: Int64.input, required: true),
        NativeParamInfo(name: "shift", input: UInt32.input, required: true),
    ],
    returns: Int64.output
) { _, _, args in
    let n: Int64 = try args.expectT("self")
    let shift: UInt32 = try args.expectT("shift")
    try args.finishT()
    // Upstream `checked_shl`: fails only when shift >= 64.
    guard shift < 64 else {
        throw StrError("the result is too large")
    }
    return n &<< Int(shift)
}

/// `int.bit-rshift` — port of `i64::bit_rshift`.
let intBitRshift = nativeFunc(
    "bit-rshift",
    title: "Bitwise Right Shift",
    since: .version([0, 11, 0]),
    docs: """
        Shifts the operand's bits to the right by the specified amount. \
        Performs an arithmetic shift by default (extends the sign bit to \
        the left, such that negative numbers stay negative), but that can \
        be changed by the `logical` parameter.

        For the purposes of this function, the operand is treated as a \
        signed integer of 64 bits.
        """,
    params: [
        NativeParamInfo(name: "self", input: Int64.input, required: true),
        NativeParamInfo(name: "shift", input: UInt32.input, required: true),
        NativeParamInfo(
            name: "logical",
            input: Bool.input,
            defaultValue: { .bool(false) },
            positional: false,
            named: true),
    ],
    returns: Int64.output
) { _, _, args in
    let n: Int64 = try args.expectT("self")
    let shift: UInt32 = try args.expectT("shift")
    let logical: Bool = try args.namedT("logical") ?? false
    try args.finishT()

    if logical {
        if shift >= 64 {
            return Int64(0)
        }
        // Reinterpret bits as unsigned for a logical shift.
        return Int64(bitPattern: UInt64(bitPattern: n) >> shift)
    }
    // Arithmetic shift saturates at -1/0 for excessive shifts.
    return n >> Int64(min(shift, 63))
}

/// `int.from-bytes` — port of `i64::from_bytes`.
let intFromBytes = nativeFunc(
    "from-bytes",
    since: .version([0, 12, 0]),
    docs: """
        Converts bytes to an integer.

        The bytes must be of length at most 8 so that the result fits \
        into a 64-bit signed integer.
        """,
    params: [
        NativeParamInfo(name: "bytes", input: Bytes.input, required: true),
        NativeParamInfo(
            name: "endian",
            input: Endianness.input,
            defaultValue: { .str(Str("little")) },
            positional: false,
            named: true),
        NativeParamInfo(
            name: "signed",
            input: Bool.input,
            defaultValue: { .bool(true) },
            positional: false,
            named: true),
    ],
    returns: Int64.output
) { _, _, args in
    let bytes: Bytes = try args.expectT("bytes")
    let endian: Endianness = try args.namedT("endian") ?? .little
    let signed: Bool = try args.namedT("signed") ?? true
    try args.finishT()

    let len = bytes.count
    if len == 0 { return Int64(0) }
    if len > 8 {
        throw StrError("too many bytes to convert to a 64 bit number")
    }

    // `decimal` holds the part of the buffer filled with input bytes;
    // `rest` stays zero or is filled with 0xFF for negative numbers.
    var buf = [UInt8](repeating: 0, count: 8)
    let src = Array(bytes.storage)
    if endian == .big {
        buf.replaceSubrange((8 - len)..<8, with: src)
    } else {
        buf.replaceSubrange(0..<len, with: src)
    }

    // Sign extension when the most significant bit is set.
    if signed {
        let msb = endian == .big ? buf[8 - len] : buf[len - 1]
        if msb & 0x80 != 0 {
            if endian == .big {
                buf.replaceSubrange(0..<(8 - len), with: repeatElement(0xFF, count: 8 - len))
            } else {
                buf.replaceSubrange(len..<8, with: repeatElement(0xFF, count: 8 - len))
            }
        }
    }

    var bits: UInt64 = 0
    for b in buf { bits = (bits << 8) | UInt64(b) }
    return Int64(bitPattern: endian == .big ? bits : bits.byteSwapped)
}

/// `int.to-bytes` — port of `i64::to_bytes`.
let intToBytes = nativeFunc(
    "to-bytes",
    since: .version([0, 12, 0]),
    docs: """
        Converts an integer to bytes.

        The size in bytes of the resulting bytes must be at least zero. \
        If the integer is too large to fit in the specified size, the \
        conversion will truncate the remaining bytes based on the \
        endianness.
        """,
    params: [
        NativeParamInfo(name: "self", input: Int64.input, required: true),
        NativeParamInfo(
            name: "endian",
            input: Endianness.input,
            defaultValue: { .str(Str("little")) },
            positional: false,
            named: true),
        NativeParamInfo(
            name: "size",
            input: UInt64.input,
            defaultValue: { .int(8) },
            positional: false,
            named: true),
    ],
    returns: Bytes.output
) { _, _, args in
    let n: Int64 = try args.expectT("self")
    let endian: Endianness = try args.namedT("endian") ?? .little
    let size = Int(clamping: try args.namedT("size") ?? 8)
    try args.finishT()

    let bits = UInt64(bitPattern: n)
    var out = [UInt8](repeating: 0, count: size)
    let byteCount = min(size, 8)
    if endian == .big {
        // Keep the `byteCount` least-significant bytes, big-endian order
        // (upstream copies the rightmost bytes of `to_be_bytes`).
        for i in 0..<byteCount {
            out[size - byteCount + i] =
                UInt8(truncatingIfNeeded: bits >> (8 * (byteCount - 1 - i)))
        }
    } else {
        // Keep the `byteCount` least-significant bytes, little-endian
        // order (upstream copies the leftmost bytes of `to_le_bytes`).
        for i in 0..<byteCount {
            out[i] = UInt8(truncatingIfNeeded: bits >> (8 * i))
        }
    }
    return Bytes(out)
}

/// Build the scope containing all `int` methods.
func intScope() -> Scope {
    let scope = Scope()
    scope.define("max", .int(Int64.max))
    scope.define("min", .int(Int64.min))
    scope.defineFunc(intConstruct)
    scope.defineFunc(intSignum)
    scope.defineFunc(intBitNot)
    scope.defineFunc(intBitAnd)
    scope.defineFunc(intBitOr)
    scope.defineFunc(intBitXor)
    scope.defineFunc(intBitLshift)
    scope.defineFunc(intBitRshift)
    scope.defineFunc(intFromBytes)
    scope.defineFunc(intToBytes)
    return scope
}
