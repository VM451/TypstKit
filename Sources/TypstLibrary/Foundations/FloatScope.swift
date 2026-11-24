import Foundation
import TypstSyntax
import TypstUtils

// The `float` type's associated scope — port of the `#[scope] impl f64`
// block in upstream `foundations/float.rs`.

/// A value convertible to a float in the `float()` constructor.
/// Port of upstream's `ToFloat` cast.
enum ToFloat: Sendable, Hashable {
    case float(Double)

    /// The wrapped float (single-case enum).
    var floatValue: Double {
        guard case .float(let f) = self else { fatalError("unreachable") }
        return f
    }
}

extension ToFloat: Castable, IntoValue, FromValue {
    static var input: CastInfo {
        Double.input + Bool.input + Int64.input + Decimal.input
            + Ratio.input + Str.input
    }
    static var output: CastInfo { input }

    static func castable(_ value: Value) -> Bool {
        switch value {
        case .float, .int, .bool, .decimal, .ratio, .str: return true
        default: return false
        }
    }

    func intoValue() -> Value { .float(floatValue) }

    static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .float(let f): return .success(.float(f))
        case .int(let n): return .success(.float(Double(n)))
        case .bool(let b): return .success(.float(b ? 1.0 : 0.0))
        case .decimal(let d): return .success(.float(d.doubleValue))
        case .ratio(let r): return .success(.float(r.get))
        case .str(let s):
            // Upstream replaces U+2212 with ASCII `-` before parsing.
            let text = s.value.replacingOccurrences(of: minusSign, with: "-")
            guard let f = Double(text) else {
                return .failure(HintedString("invalid float: \(s.repr())"))
            }
            return .success(.float(f))
        default: return .failure(error(value))
        }
    }
}

/// `float(..)` — port of `f64::construct`.
let floatConstruct = nativeFunc(
    "float",
    title: "Float",
    since: .forever,
    docs: "Converts a value to a float.",
    params: [
        NativeParamInfo(
            name: "value",
            input: ToFloat.input,
            positional: true,
            required: true),
    ],
    returns: Double.output
) { _, _, args in
    let value: ToFloat = try args.expectT("value")
    try args.finishT()
    return value.floatValue
}

/// `float.is-nan` — port of `f64::is_nan`.
let floatIsNan = nativeFunc(
    "is-nan",
    title: "Is NaN",
    since: .version([0, 11, 0]),
    docs: """
        Checks if a float is not a number.

        In IEEE 754, more than one bit pattern represents a NaN. This \
        function returns `{true}` if the float is any of those bit \
        patterns.
        """,
    params: [
        NativeParamInfo(name: "self", input: Double.input, required: true)
    ],
    returns: Bool.output
) { _, _, args in
    let n: Double = try args.expectT("self")
    try args.finishT()
    return n.isNaN
}

/// `float.is-infinite` — port of `f64::is_infinite`.
let floatIsInfinite = nativeFunc(
    "is-infinite",
    since: .version([0, 11, 0]),
    docs: """
        Checks if a float is infinite.

        Floats can represent positive infinity and negative infinity. \
        This function returns `{true}` if the float is an infinity.
        """,
    params: [
        NativeParamInfo(name: "self", input: Double.input, required: true)
    ],
    returns: Bool.output
) { _, _, args in
    let n: Double = try args.expectT("self")
    try args.finishT()
    return n.isInfinite
}

/// `float.signum` — port of `f64::signum`.
let floatSignum = nativeFunc(
    "signum",
    since: .version([0, 11, 0]),
    docs: """
        Calculates the sign of a floating point number.

        - If the number is positive (including `{+0.0}`), returns `{1.0}`.
        - If the number is negative (including `{-0.0}`), returns `{-1.0}`.
        - If the number is NaN, returns @float.nan.
        """,
    params: [
        NativeParamInfo(name: "self", input: Double.input, required: true)
    ],
    returns: Double.output
) { _, _, args in
    let n: Double = try args.expectT("self")
    try args.finishT()
    // Rust `f64::signum`: NaN → NaN, otherwise ±1.0 by sign bit
    // (+0.0 → 1.0, -0.0 → -1.0).
    if n.isNaN { return Double.nan }
    return n.sign == .minus ? -1.0 : 1.0
}

/// `float.from-bytes` — port of `f64::from_bytes`.
let floatFromBytes = nativeFunc(
    "from-bytes",
    since: .version([0, 12, 0]),
    docs: """
        Interprets bytes as a float.

        The bytes must have a length of either 4 or 8 and are interpreted \
        in IEEE 754's binary32 (single-precision) or binary64 \
        (double-precision) format depending on the length.
        """,
    params: [
        NativeParamInfo(name: "bytes", input: Bytes.input, required: true),
        NativeParamInfo(
            name: "endian",
            input: Endianness.input,
            defaultValue: { .str(Str("little")) },
            positional: false,
            named: true),
    ],
    returns: Double.output
) { _, _, args in
    let bytes: Bytes = try args.expectT("bytes")
    let endian: Endianness = try args.namedT("endian") ?? .little
    try args.finishT()

    let src = Array(bytes.storage)
    switch src.count {
    case 8:
        var bits: UInt64 = 0
        if endian == .little {
            for (i, b) in src.enumerated() { bits |= UInt64(b) << (8 * i) }
        } else {
            for b in src { bits = (bits << 8) | UInt64(b) }
        }
        return Double(bitPattern: bits)
    case 4:
        var bits: UInt32 = 0
        if endian == .little {
            for (i, b) in src.enumerated() { bits |= UInt32(b) << (8 * i) }
        } else {
            for b in src { bits = (bits << 8) | UInt32(b) }
        }
        return Double(Float(bitPattern: bits))
    default:
        throw StrError("bytes must have a length of 4 or 8")
    }
}

/// `float.to-bytes` — port of `f64::to_bytes`.
let floatToBytes = nativeFunc(
    "to-bytes",
    since: .version([0, 12, 0]),
    docs: """
        Converts a float to bytes.

        The size must be either 4 or 8, producing the IEEE 754 binary32 \
        (single-precision) or binary64 (double-precision) representation.
        """,
    params: [
        NativeParamInfo(name: "self", input: Double.input, required: true),
        NativeParamInfo(
            name: "endian",
            input: Endianness.input,
            defaultValue: { .str(Str("little")) },
            positional: false,
            named: true),
        NativeParamInfo(
            name: "size",
            input: UInt32.input,
            defaultValue: { .int(8) },
            positional: false,
            named: true),
    ],
    returns: Bytes.output
) { _, _, args in
    let n: Double = try args.expectT("self")
    let endian: Endianness = try args.namedT("endian") ?? .little
    let size: UInt32 = try args.namedT("size") ?? 8
    try args.finishT()

    switch size {
    case 8:
        let bits = n.bitPattern
        var out = [UInt8](repeating: 0, count: 8)
        if endian == .little {
            for i in 0..<8 { out[i] = UInt8(truncatingIfNeeded: bits >> (8 * i)) }
        } else {
            for i in 0..<8 { out[i] = UInt8(truncatingIfNeeded: bits >> (8 * (7 - i))) }
        }
        return Bytes(out)
    case 4:
        let bits = Float(n).bitPattern
        var out = [UInt8](repeating: 0, count: 4)
        if endian == .little {
            for i in 0..<4 { out[i] = UInt8(truncatingIfNeeded: bits >> (8 * i)) }
        } else {
            for i in 0..<4 { out[i] = UInt8(truncatingIfNeeded: bits >> (8 * (3 - i))) }
        }
        return Bytes(out)
    default:
        throw StrError("size must be either 4 or 8")
    }
}

/// Build the scope containing all `float` methods.
func floatScope() -> Scope {
    let scope = Scope()
    scope.define("inf", .float(Double.infinity))
    scope.define("nan", .float(Double.nan))
    scope.defineFunc(floatConstruct)
    scope.defineFunc(floatIsNan)
    scope.defineFunc(floatIsInfinite)
    scope.defineFunc(floatSignum)
    scope.defineFunc(floatFromBytes)
    scope.defineFunc(floatToBytes)
    return scope
}
