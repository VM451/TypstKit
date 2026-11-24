import Foundation
import TypstSyntax
import TypstUtils

// The `decimal` type's associated scope — port of the `#[scope] impl Decimal`
// block in upstream `foundations/decimal.rs`.

/// A value convertible to a decimal in the `decimal()` constructor.
/// Port of upstream's `ToDecimal` cast.
enum ToDecimal: Sendable, Hashable {
    case decimal(Decimal)
    case str(Str)
    case int(Int64)
    case float(Double)

    /// The wrapped decimal.
    var decimalValue: Decimal {
        switch self {
        case .decimal(let d): return d
        case .str(let s):
            // Unreachable: strings are resolved in the constructor.
            return Decimal(exactly: s.value.replacingOccurrences(
                of: minusSign, with: "-")) ?? .ZERO
        case .int(let n): return Decimal(n)
        case .float(let f): return Decimal(f)
        }
    }
}

extension ToDecimal: Castable, IntoValue, FromValue {
    static var input: CastInfo {
        Decimal.input + Str.input + Int64.input + Bool.input + Double.input
    }
    static var output: CastInfo { Decimal.output }

    static func castable(_ value: Value) -> Bool {
        switch value {
        case .decimal, .str, .int, .bool, .float: return true
        default: return false
        }
    }

    func intoValue() -> Value { .decimal(decimalValue) }

    static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .decimal(let d): return .success(.decimal(d))
        case .str(let s): return .success(.str(s))
        case .int(let n): return .success(.int(n))
        case .bool(let b): return .success(.int(b ? 1 : 0))
        case .float(let f): return .success(.float(f))
        default: return .failure(error(value))
        }
    }
}

/// `decimal(..)` — port of `Decimal::construct`.
let decimalConstruct = nativeFunc(
    "decimal",
    title: "Decimal",
    since: .version([0, 12, 0]),
    docs: """
        Converts a value to a decimal.

        It is recommended to use a string to construct the decimal number, \
        or an integer (if desired). The string must contain a number in the \
        format `{"3.14159"}` (or `{"-3.141519"}` for negative numbers). \
        While this constructor can be used with floats to cast them to \
        `decimal`, doing so is *discouraged* as *this cast is inherently \
        imprecise.* Floats that are NaN or infinite cannot be cast to \
        decimals and will raise an error.
        """,
    params: [
        NativeParamInfo(
            name: "value",
            input: ToDecimal.input,
            positional: true,
            required: true),
    ],
    returns: Decimal.output
) { _, _, args in
    let value: Spanned<ToDecimal, Span> = try args.expectT("value")
    try args.finishT()

    switch value.value {
    case .str(let s):
        // Upstream replaces U+2212 with ASCII `-` before parsing.
        let text = s.value.replacingOccurrences(of: minusSign, with: "-")
        guard Decimal.isValidLiteral(text),
              let d = Decimal(exactly: text) else {
            throw bailSpan(value.span, "invalid decimal: \(s.value)")
        }
        return d
    case .int(let n):
        return Decimal(n)
    case .float(let f):
        // Upstream `rust_decimal::from_f64_retain` keeps the exact binary
        // expansion rounded to 28 significant digits.
        guard let d = Decimal.fromDoubleExact(f) else {
            throw bailSpan(
                value.span,
                "float is not a valid decimal: \(formatFloat(f, forceSeparator: true))")
        }
        return d
    case .decimal(let d):
        return d
    }
}

// MARK: - Methods

/// Shared builder for `self`-only decimal methods.
private func decimalMethod(
    _ name: String,
    since: Since,
    body: @escaping @Sendable (Decimal) throws -> Decimal
) -> NativeFuncData {
    nativeFunc(
        name,
        since: since,
        params: [
            NativeParamInfo(name: "self", input: Decimal.input, required: true)
        ],
        returns: Decimal.output
    ) { _, _, args in
        let selfValue: Decimal = try args.expectT("self")
        try args.finishT()
        return try body(selfValue)
    }
}

/// `decimal.is-integer()` — port of `Decimal::is_integer`.
let decimalIsInteger = nativeFunc(
    "is-integer",
    since: .version([0, 12, 0]),
    params: [
        NativeParamInfo(name: "self", input: Decimal.input, required: true)
    ],
    returns: Bool.output
) { _, _, args in
    let selfValue: Decimal = try args.expectT("self")
    try args.finishT()
    return selfValue.isInteger
}

/// `decimal.abs()` — port of `Decimal::abs`.
let decimalAbs = decimalMethod("abs", since: .version([0, 12, 0])) {
    $0.abs()
}

/// `decimal.floor()` — port of `Decimal::floor`.
let decimalFloor = decimalMethod("floor", since: .version([0, 12, 0])) {
    $0.floor()
}

/// `decimal.ceil()` — port of `Decimal::ceil`.
let decimalCeil = decimalMethod("ceil", since: .version([0, 12, 0])) {
    $0.ceil()
}

/// `decimal.trunc()` — port of `Decimal::trunc`.
let decimalTrunc = decimalMethod("trunc", since: .version([0, 12, 0])) {
    $0.trunc()
}

/// `decimal.fract()` — port of `Decimal::fract`.
let decimalFract = decimalMethod("fract", since: .version([0, 12, 0])) {
    $0.fract()
}

/// `decimal.round(digits:)` — port of `Decimal::round`.
let decimalRound = nativeFunc(
    "round",
    since: .version([0, 12, 0]),
    params: [
        NativeParamInfo(name: "self", input: Decimal.input, required: true),
        NativeParamInfo(name: "digits", input: Int32.input, required: true),
    ],
    returns: Optional<Decimal>.output
) { _, _, args in
    let selfValue: Decimal = try args.expectT("self")
    let digits: Int32 = try args.expectT("digits")
    try args.finishT()
    return selfValue.round(digits: Int(digits))
}

/// Build the scope containing all `decimal` methods.
func decimalScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(decimalConstruct)
    scope.defineFunc(decimalIsInteger)
    scope.defineFunc(decimalAbs)
    scope.defineFunc(decimalFloor)
    scope.defineFunc(decimalCeil)
    scope.defineFunc(decimalTrunc)
    scope.defineFunc(decimalFract)
    scope.defineFunc(decimalRound)
    return scope
}
