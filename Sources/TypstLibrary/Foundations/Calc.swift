import Foundation
import TypstSyntax
import TypstUtils

// Port of `foundations/calc.rs` — the `calc` module and its numeric
// helper cast types (`Num`, `DecNum`, `AngleLike`, `ToAbs`).

/// A module with calculation definitions.
public func calcModule() -> Module {
    let scope = Scope()
    scope.defineFunc(calcAbs)
    scope.defineFunc(calcPow)
    scope.defineFunc(calcExp)
    scope.defineFunc(calcSqrt)
    scope.defineFunc(calcRoot)
    scope.defineFunc(calcSin)
    scope.defineFunc(calcCos)
    scope.defineFunc(calcTan)
    scope.defineFunc(calcAsin)
    scope.defineFunc(calcAcos)
    scope.defineFunc(calcAtan)
    scope.defineFunc(calcAtan2)
    scope.defineFunc(calcSinh)
    scope.defineFunc(calcCosh)
    scope.defineFunc(calcTanh)
    scope.defineFunc(calcAsinh)
    scope.defineFunc(calcAcosh)
    scope.defineFunc(calcAtanh)
    scope.defineFunc(calcLog)
    scope.defineFunc(calcLn)
    scope.defineFunc(calcErf)
    scope.defineFunc(calcFact)
    scope.defineFunc(calcPerm)
    scope.defineFunc(calcBinom)
    scope.defineFunc(calcGcd)
    scope.defineFunc(calcLcm)
    scope.defineFunc(calcFloor)
    scope.defineFunc(calcCeil)
    scope.defineFunc(calcTrunc)
    scope.defineFunc(calcFract)
    scope.defineFunc(calcRound)
    scope.defineFunc(calcClamp)
    scope.defineFunc(calcMin)
    scope.defineFunc(calcMax)
    scope.defineFunc(calcEven)
    scope.defineFunc(calcOdd)
    scope.defineFunc(calcRem)
    scope.defineFunc(calcDivEuclid)
    scope.defineFunc(calcRemEuclid)
    scope.defineFunc(calcQuo)
    scope.defineFunc(calcNorm)

    func constant(_ name: String, _ value: Double, _ title: String,
                  _ docs: String, _ since: Since, _ keywords: [String] = []) -> Binding {
        var binding = scope.define(name, .float(value))
        binding.withDocumentation(BindingDocumentation(
            name: name, title: title, docs: docs, since: since, keywords: keywords))
        return binding
    }

    _ = constant("inf", .infinity, "Infinity", """
        Infinity ($+oo$) as a value.

        This is the same value as @float.inf. See the corresponding
        documentation for more details.
        """, .forever)
    _ = constant("pi", .pi, "Pi", """
        Archimedes' constant ($pi$).

        This is the ratio of a circle's circumference to its diameter.
        """, .forever, ["Archimedes"])
    _ = constant("tau", 2 * .pi, "Tau", """
        The circumference of a unit circle ($tau$).

        The constant $tau$ is defined by the relation $tau = 2 pi$.
        """, .version([0, 8, 0]))
    _ = constant("e", 2.718281828459045, "Euler's number", """
        Euler's number ($e$).

        This is the base of the natural logarithm and the exponential function.
        """, .forever)

    return Module(name: Str("calc"), scope: scope)
}

// MARK: - Shared helpers

/// The error message when the result is too large to be represented.
func calcTooLarge() -> StrError { StrError("the result is too large") }

/// Hinted error when mixing decimal and float operands.
func calcCantMixDecimalFloat() -> HintedString {
    HintedString(message: "cannot apply this operation to a decimal and a float",
                 hints: ["if loss of precision is acceptable, explicitly cast the decimal to a float with `float(value)`"])
}

/// `f64::is_normal` — finite, nonzero, non-subnormal.
func isNormalFloat(_ f: Double) -> Bool {
    f.isFinite && abs(f) >= 2.2250738585072014e-308
}

/// `convert_float_to_int` from upstream `int.rs`.
func convertFloatToInt(_ f: Double) -> StrResult<Int64> {
    if f <= Double(Int64.min) - 1.0 || f >= Double(Int64.max) + 1.0 {
        return .failure(StrError("number too large"))
    }
    return .success(Int64(f))
}

/// `i64::checked_pow` for a non-negative exponent.
func checkedPowI64(_ base: Int64, _ exp: UInt64) -> Int64? {
    var result: Int64 = 1
    var b = base
    var e = exp
    while e > 0 {
        if e & 1 == 1 {
            let (p, o1) = result.multipliedReportingOverflow(by: b)
            if o1 { return nil }
            result = p
        }
        e >>= 1
        if e > 0 {
            let (p, o2) = b.multipliedReportingOverflow(by: b)
            if o2 { return nil }
            b = p
        }
    }
    return result
}

/// `i64::checked_abs` — nil on `Int64.min`.
func checkedAbsI64(_ v: Int64) -> Int64? {
    v == Int64.min ? nil : Swift.abs(v)
}

/// `i64::clamp`.
func clampI64(_ v: Int64, _ lo: Int64, _ hi: Int64) -> Int64 {
    Swift.min(Swift.max(v, lo), hi)
}

/// `f64::clamp`.
func clampF64(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    Swift.min(Swift.max(v, lo), hi)
}

/// `i64::div_euclid` — quotient with non-negative remainder.
func divEuclidI64(_ a: Int64, _ b: Int64) -> Int64? {
    let (q, o1) = a.dividedReportingOverflow(by: b)
    if o1 { return nil }
    let (r, o2) = a.remainderReportingOverflow(dividingBy: b)
    if o2 { return nil }
    if r < 0 {
        // `b > 0` → q - 1; `b < 0` → q + 1 (Rust `div_euclid`).
        if b > 0 {
            let (q2, o3) = q.subtractingReportingOverflow(1)
            return o3 ? nil : q2
        } else {
            let (q2, o3) = q.addingReportingOverflow(1)
            return o3 ? nil : q2
        }
    }
    return q
}

/// `i64::rem_euclid` — least non-negative remainder.
func remEuclidI64(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o1) = a.remainderReportingOverflow(dividingBy: b)
    if o1 { return nil }
    if r < 0 {
        guard let mag = checkedAbsI64(b) else { return nil }
        let (r2, o3) = r.addingReportingOverflow(mag)
        return o3 ? nil : r2
    }
    return r
}

/// `f64::div_euclid`.
func divEuclidF64(_ a: Double, _ b: Double) -> Double {
    let r = remEuclidF64(a, b)
    return (a - r) / b
}

/// `f64::rem_euclid`.
func remEuclidF64(_ a: Double, _ b: Double) -> Double {
    let r = a.truncatingRemainder(dividingBy: b)
    return r < 0 ? r + abs(b) : r
}

/// Saturating `i64 -> i16`/`i64 -> i32` conversions (`saturating_as`).
func saturatingI16(_ v: Int64) -> Int16 {
    Int16(truncatingIfNeeded: Swift.min(Swift.max(v, Int64(Int16.min)), Int64(Int16.max)))
}
func saturatingI32(_ v: Int64) -> Int32 {
    Int32(truncatingIfNeeded: Swift.min(Swift.max(v, Int64(Int32.min)), Int64(Int32.max)))
}

// MARK: - abs

/// Calculates the absolute value of a numeric value.
let calcAbs = nativeFunc(
    "abs", title: "Absolute", since: .forever,
    docs: "Calculates the absolute value of a numeric value.",
    params: [NativeParamInfo(name: "value", input: ToAbs.input, required: true)],
    returns: .any
) { _, _, args in
    let value: ToAbs = try args.expectT("value")
    try args.finishT()
    return value.value
}

/// A value of which the absolute value can be taken.
/// Port of `ToAbs` in calc.rs.
struct ToAbs: Sendable, Hashable {
    let value: Value
}

extension ToAbs: Castable, IntoValue, FromValue {
    static var input: CastInfo {
        .union([Int64.input, Double.input, Length.input, Angle.input,
                Ratio.input, Fr.input, Decimal.input])
    }
    static var output: CastInfo { .any }
    static func castable(_ value: Value) -> Bool {
        switch value {
        case .int, .float, .length, .angle, .ratio, .fraction, .decimal:
            return true
        default:
            return false
        }
    }
    static func error(_ value: Value) -> HintedString {
        input.error(value)
    }
    func intoValue() -> Value { value }
    static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .int(let v):
            // `i64::MIN` — magnitude too large (upstream `too_large`).
            guard v != Int64.min else {
                return .failure(HintedString(calcTooLarge().message))
            }
            return .success(ToAbs(value: v < 0 ? .int(-v) : value))
        case .float(let v):
            return .success(ToAbs(value: .float(Swift.abs(v))))
        case .length(let v):
            guard let t = v.tryAbs() else {
                return .failure(HintedString("cannot take absolute value of this length"))
            }
            return .success(ToAbs(value: .length(t)))
        case .angle(let v):
            return .success(ToAbs(value: .angle(v.abs())))
        case .ratio(let v):
            return .success(ToAbs(value: .ratio(v.abs())))
        case .fraction(let v):
            return .success(ToAbs(value: .fraction(v.abs())))
        case .decimal(let v):
            return .success(ToAbs(value: .decimal(v.abs())))
        default:
            return .failure(error(value))
        }
    }
}

// MARK: - pow / exp / sqrt / root

/// Raises a value to some exponent.
let calcPow = nativeFunc(
    "pow", title: "Power", since: .forever,
    docs: "Raises a value to some exponent.",
    params: [
        NativeParamInfo(name: "base", input: DecNum.input, required: true),
        NativeParamInfo(name: "exponent", input: Spanned<Num, Span>.input, required: true),
    ],
    returns: DecNum.output
) { _, _, args in
    let span = args.span
    let base: DecNum = try args.expectT("base")
    let exponent: Spanned<Num, Span> = try args.expectT("exponent")
    try args.finishT()

    if case .int(let i) = exponent.value, Int32(exactly: i) == nil {
        throw SourceDiagnostics(SourceDiagnostic.error(exponent.span, "exponent is too large"))
    }
    if case .float(let f) = exponent.value, !isNormalFloat(f) && f != 0.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(
            exponent.span, "exponent may not be infinite, subnormal, or NaN"))
    }
    if exponent.value.floatValue == 0.0 && base.isZero {
        throw SourceDiagnostics(SourceDiagnostic.error(span, "zero to the power of zero is undefined"))
    }

    switch (base, exponent.value) {
    case (.int(let a), .int(let b)) where b >= 0:
        guard let r = checkedPowI64(a, UInt64(b)) else {
            throw StrError(calcTooLarge().message)
        }
        return DecNum.int(r)
    case (.decimal(let a), .int(let b)):
        guard let r = a.checkedPowi(b) else {
            throw StrError(calcTooLarge().message)
        }
        return DecNum.decimal(r)
    default:
        guard let a = base.floatValue else {
            throw calcCantMixDecimalFloat()
        }
        let b = exponent.value.floatValue
        let result: Double
        if a == 2.718281828459045 {
            result = exp(b)
        } else if a == 2.0 {
            result = exp2(b)
        } else if case .int(let bi) = exponent.value {
            result = Scalar(a).powi(Int32(bi)).get
        } else {
            result = pow(a, b)
        }
        if result.isNaN {
            throw SourceDiagnostics(SourceDiagnostic.error(span, "the result is not a real number"))
        }
        return DecNum.float(result)
    }
}

/// Raises a value to some exponent of $e$.
let calcExp = nativeFunc(
    "exp", title: "Exponential", since: .version([0, 5, 0]),
    docs: "Raises a value to some exponent of $e$.",
    params: [NativeParamInfo(name: "exponent", input: Spanned<Num, Span>.input, required: true)],
    returns: Double.output
) { _, _, args in
    let span = args.span
    let exponent: Spanned<Num, Span> = try args.expectT("exponent")
    try args.finishT()

    if case .int(let i) = exponent.value, Int32(exactly: i) == nil {
        throw SourceDiagnostics(SourceDiagnostic.error(exponent.span, "exponent is too large"))
    }
    if case .float(let f) = exponent.value, !isNormalFloat(f) && f != 0.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(
            exponent.span, "exponent may not be infinite, subnormal, or NaN"))
    }

    let result = exp(exponent.value.floatValue)
    if result.isNaN {
        throw SourceDiagnostics(SourceDiagnostic.error(span, "the result is not a real number"))
    }
    return result
}

/// Calculates the square root of a number.
let calcSqrt = nativeFunc(
    "sqrt", title: "Square Root", since: .forever,
    docs: "Calculates the square root of a number.",
    params: [NativeParamInfo(name: "value", input: Spanned<Num, Span>.input, required: true)],
    returns: Double.output
) { _, _, args in
    let value: Spanned<Num, Span> = try args.expectT("value")
    try args.finishT()
    if value.value.floatValue < 0.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(value.span, "cannot take square root of negative number"))
    }
    return value.value.floatValue.squareRoot()
}

/// Calculates the real $n$th root of a number.
let calcRoot = nativeFunc(
    "root", since: .version([0, 11, 0]),
    docs: "Calculates the real nth root of a number.",
    params: [
        NativeParamInfo(name: "radicand", input: Double.input, required: true),
        NativeParamInfo(name: "index", input: Spanned<Int64, Span>.input, required: true),
    ],
    returns: Double.output
) { _, _, args in
    let radicand: Double = try args.expectT("radicand")
    let index: Spanned<Int64, Span> = try args.expectT("index")
    try args.finishT()

    if index.value == 0 {
        throw SourceDiagnostics(SourceDiagnostic.error(index.span, "cannot take the 0th root of a number"))
    } else if radicand < 0.0 {
        if index.value % 2 == 0 {
            throw SourceDiagnostics(SourceDiagnostic.error(
                index.span, "negative numbers do not have a real nth root when n is even"))
        }
        return -pow(-radicand, 1.0 / Double(index.value))
    }
    return pow(radicand, 1.0 / Double(index.value))
}

// MARK: - Trigonometry

/// sin/cos/tan dispatch on `AngleLike`.
private func trig(_ angle: AngleLike, _ f: (Double) -> Double) -> Double {
    switch angle {
    case .angle(let a): return f(a.toRad())
    case .int(let n): return f(Double(n))
    case .float(let n): return f(n)
    }
}

/// A value that can be passed to a trigonometric function.
enum AngleLike: Sendable, Hashable {
    case int(Int64)
    case float(Double)
    case angle(Angle)
}

extension AngleLike: Castable, FromValue {
    static var input: CastInfo {
        .union([Int64.input, Double.input, Angle.input])
    }
    static var output: CastInfo { .any }
    static func castable(_ value: Value) -> Bool {
        switch value {
        case .int, .float, .angle: return true
        default: return false
        }
    }
    static func error(_ value: Value) -> HintedString {
        input.error(value)
    }
    static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .int(let v): return .success(.int(v))
        case .float(let v): return .success(.float(v))
        case .angle(let v): return .success(.angle(v))
        default: return .failure(error(value))
        }
    }
}

let calcSin = nativeFunc(
    "sin", title: "Sine", since: .forever,
    docs: "Calculates the sine of an angle.",
    params: [NativeParamInfo(name: "angle", input: AngleLike.input, required: true)],
    returns: Double.output
) { _, _, args in
    let angle: AngleLike = try args.expectT("angle")
    try args.finishT()
    return trig(angle, sin)
}

let calcCos = nativeFunc(
    "cos", title: "Cosine", since: .forever,
    docs: "Calculates the cosine of an angle.",
    params: [NativeParamInfo(name: "angle", input: AngleLike.input, required: true)],
    returns: Double.output
) { _, _, args in
    let angle: AngleLike = try args.expectT("angle")
    try args.finishT()
    return trig(angle, cos)
}

let calcTan = nativeFunc(
    "tan", title: "Tangent", since: .forever,
    docs: "Calculates the tangent of an angle.",
    params: [NativeParamInfo(name: "angle", input: AngleLike.input, required: true)],
    returns: Double.output
) { _, _, args in
    let angle: AngleLike = try args.expectT("angle")
    try args.finishT()
    return trig(angle, tan)
}

/// Shared [-1, 1] range check for inverse trig.
private func checkUnitInterval(_ value: Spanned<Num, Span>) throws {
    let v = value.value.floatValue
    if v < -1.0 || v > 1.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(value.span, "value must be between -1 and 1"))
    }
}

let calcAsin = nativeFunc(
    "asin", title: "Arcsine", since: .forever,
    docs: "Calculates the arcsine of a number.",
    params: [NativeParamInfo(name: "value", input: Spanned<Num, Span>.input, required: true)],
    returns: Angle.output
) { _, _, args in
    let value: Spanned<Num, Span> = try args.expectT("value")
    try args.finishT()
    try checkUnitInterval(value)
    return Angle.rad(asin(value.value.floatValue))
}

let calcAcos = nativeFunc(
    "acos", title: "Arccosine", since: .forever,
    docs: "Calculates the arccosine of a number.",
    params: [NativeParamInfo(name: "value", input: Spanned<Num, Span>.input, required: true)],
    returns: Angle.output
) { _, _, args in
    let value: Spanned<Num, Span> = try args.expectT("value")
    try args.finishT()
    try checkUnitInterval(value)
    return Angle.rad(acos(value.value.floatValue))
}

let calcAtan = nativeFunc(
    "atan", title: "Arctangent", since: .forever,
    docs: "Calculates the arctangent of a number.",
    params: [NativeParamInfo(name: "value", input: Num.input, required: true)],
    returns: Angle.output
) { _, _, args in
    let value: Num = try args.expectT("value")
    try args.finishT()
    return Angle.rad(atan(value.floatValue))
}

let calcAtan2 = nativeFunc(
    "atan2", title: "Four-quadrant Arctangent", since: .version([0, 3, 0]),
    docs: "Calculates the four-quadrant arctangent of a coordinate.",
    params: [
        NativeParamInfo(name: "x", input: Num.input, required: true),
        NativeParamInfo(name: "y", input: Num.input, required: true),
    ],
    returns: Angle.output
) { _, _, args in
    let x: Num = try args.expectT("x")
    let y: Num = try args.expectT("y")
    try args.finishT()
    return Angle.rad(atan2(y.floatValue, x.floatValue))
}

// MARK: - Hyperbolic

let calcSinh = nativeFunc(
    "sinh", title: "Hyperbolic Sine", since: .forever,
    docs: "Calculates the hyperbolic sine of a hyperbolic angle.",
    params: [NativeParamInfo(name: "value", input: Double.input, required: true)],
    returns: Double.output
) { _, _, args in
    let value: Double = try args.expectT("value")
    try args.finishT()
    return sinh(value)
}

let calcCosh = nativeFunc(
    "cosh", title: "Hyperbolic Cosine", since: .forever,
    docs: "Calculates the hyperbolic cosine of a hyperbolic angle.",
    params: [NativeParamInfo(name: "value", input: Double.input, required: true)],
    returns: Double.output
) { _, _, args in
    let value: Double = try args.expectT("value")
    try args.finishT()
    return cosh(value)
}

let calcTanh = nativeFunc(
    "tanh", title: "Hyperbolic Tangent", since: .forever,
    docs: "Calculates the hyperbolic tangent of a hyperbolic angle.",
    params: [NativeParamInfo(name: "value", input: Double.input, required: true)],
    returns: Double.output
) { _, _, args in
    let value: Double = try args.expectT("value")
    try args.finishT()
    return tanh(value)
}

let calcAsinh = nativeFunc(
    "asinh", title: "Inverse Hyperbolic Sine", since: .version([0, 15, 0]),
    docs: "Calculates the inverse hyperbolic sine of a number.",
    params: [NativeParamInfo(name: "value", input: Double.input, required: true)],
    returns: Double.output
) { _, _, args in
    let value: Double = try args.expectT("value")
    try args.finishT()
    return asinh(value)
}

let calcAcosh = nativeFunc(
    "acosh", title: "Inverse Hyperbolic Cosine", since: .version([0, 15, 0]),
    docs: "Calculates the inverse hyperbolic cosine of a number.",
    params: [NativeParamInfo(name: "value", input: Spanned<Double, Span>.input, required: true)],
    returns: Double.output
) { _, _, args in
    let value: Spanned<Double, Span> = try args.expectT("value")
    try args.finishT()
    if value.value < 1.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(value.span, "value must be greater than or equal to 1"))
    }
    return acosh(value.value)
}

let calcAtanh = nativeFunc(
    "atanh", title: "Inverse Hyperbolic Tangent", since: .version([0, 15, 0]),
    docs: "Calculates the inverse hyperbolic tangent of a number.",
    params: [NativeParamInfo(name: "value", input: Spanned<Double, Span>.input, required: true)],
    returns: Double.output
) { _, _, args in
    let value: Spanned<Double, Span> = try args.expectT("value")
    try args.finishT()
    if value.value <= -1.0 || value.value >= 1.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(value.span, "value must be between -1 and 1 (exclusive)"))
    }
    return atanh(value.value)
}

// MARK: - Logarithm

let calcLog = nativeFunc(
    "log", title: "Logarithm", since: .forever,
    docs: "Calculates the logarithm of a number.",
    params: [
        NativeParamInfo(name: "value", input: Spanned<Num, Span>.input, required: true),
        NativeParamInfo(name: "base", input: Spanned<Double, Span>.input,
                        defaultValue: { .float(10.0) }),
    ],
    returns: Double.output
) { _, _, args in
    let span = args.span
    let value: Spanned<Num, Span> = try args.expectT("value")
    let base: Spanned<Double, Span> = try args.namedT("base") ?? .detached(10.0)
    try args.finishT()

    let number = value.value.floatValue
    if number <= 0.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(value.span, "value must be strictly positive"))
    }
    if !isNormalFloat(base.value) {
        throw SourceDiagnostics(SourceDiagnostic.error(
            base.span, "base may not be zero, NaN, infinite, or subnormal"))
    }

    let result: Double
    if base.value == 2.718281828459045 {
        result = log(number)
    } else if base.value == 2.0 {
        result = log2(number)
    } else if base.value == 10.0 {
        result = log10(number)
    } else {
        result = log(number) / log(base.value)
    }
    if result.isInfinite || result.isNaN {
        throw SourceDiagnostics(SourceDiagnostic.error(span, "the result is not a real number"))
    }
    return result
}

let calcLn = nativeFunc(
    "ln", title: "Natural Logarithm", since: .version([0, 5, 0]),
    docs: "Calculates the natural logarithm of a number.",
    params: [NativeParamInfo(name: "value", input: Spanned<Num, Span>.input, required: true)],
    returns: Double.output
) { _, _, args in
    let span = args.span
    let value: Spanned<Num, Span> = try args.expectT("value")
    try args.finishT()

    let number = value.value.floatValue
    if number <= 0.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(value.span, "value must be strictly positive"))
    }
    let result = log(number)
    if result.isInfinite {
        throw SourceDiagnostics(SourceDiagnostic.error(span, "result close to -inf"))
    }
    return result
}

let calcErf = nativeFunc(
    "erf", title: "Error Function", since: .version([0, 15, 0]),
    docs: "Applies the error function to a number.",
    params: [NativeParamInfo(name: "value", input: Double.input, required: true)],
    returns: Double.output
) { _, _, args in
    let value: Double = try args.expectT("value")
    try args.finishT()
    return erf(value)
}

// MARK: - Integer functions

/// `fact_impl` — product of `start...end`, nil on overflow.
private func factImpl(_ start: UInt64, _ end: UInt64) -> Int64? {
    if end + 1 < start { return 0 }
    var count: UInt64 = 1
    for i in stride(from: Swift.max(1, start), through: end, by: 1) {
        let (p, o) = count.multipliedReportingOverflow(by: i)
        if o { return nil }
        count = p
    }
    return Int64(exactly: count)
}

/// `binom_impl`.
private func binomImpl(_ n: UInt64, _ k: UInt64) -> Int64? {
    if k > n { return 0 }
    let realK = Swift.min(n - k, k)
    if realK == 0 { return 1 }
    var result: UInt64 = 1
    for i in 0..<realK {
        let (p, o1) = result.multipliedReportingOverflow(by: n - i)
        if o1 { return nil }
        let (q, o2) = p.dividedReportingOverflow(by: i + 1)
        if o2 { return nil }
        result = q
    }
    return Int64(exactly: result)
}

let calcFact = nativeFunc(
    "fact", title: "Factorial", since: .version([0, 3, 0]),
    docs: "Calculates the factorial of a number.",
    params: [NativeParamInfo(name: "number", input: UInt64.input, required: true)],
    returns: Int64.output
) { _, _, args in
    let number: UInt64 = try args.expectT("number")
    try args.finishT()
    guard let r = factImpl(1, number) else { throw calcTooLarge() }
    return r
}

let calcPerm = nativeFunc(
    "perm", title: "Permutation", since: .version([0, 3, 0]),
    docs: "Calculates a permutation.",
    params: [
        NativeParamInfo(name: "base", input: UInt64.input, required: true),
        NativeParamInfo(name: "numbers", input: UInt64.input, required: true),
    ],
    returns: Int64.output
) { _, _, args in
    let base: UInt64 = try args.expectT("base")
    let numbers: UInt64 = try args.expectT("numbers")
    try args.finishT()
    if base < numbers { return Int64(0) }
    guard let r = factImpl(base - numbers + 1, base) else { throw calcTooLarge() }
    return r
}

let calcBinom = nativeFunc(
    "binom", title: "Binomial", since: .version([0, 3, 0]),
    docs: "Calculates a binomial coefficient.",
    params: [
        NativeParamInfo(name: "n", input: UInt64.input, required: true),
        NativeParamInfo(name: "k", input: UInt64.input, required: true),
    ],
    returns: Int64.output
) { _, _, args in
    let n: UInt64 = try args.expectT("n")
    let k: UInt64 = try args.expectT("k")
    try args.finishT()
    guard let r = binomImpl(n, k) else { throw calcTooLarge() }
    return r
}

/// Shared gcd helper (throws StrError on overflow, matching upstream).
private func gcdI64(_ a: Int64, _ b: Int64) throws -> Int64 {
    var (a, b) = (a, b)
    while b != 0 {
        let (r, o) = a.remainderReportingOverflow(dividingBy: b)
        if o { throw calcTooLarge() }
        let temp = b
        b = r
        a = temp
    }
    guard let r = checkedAbsI64(a) else { throw calcTooLarge() }
    return r
}

let calcGcd = nativeFunc(
    "gcd", title: "Greatest Common Divisor", since: .version([0, 3, 0]),
    docs: "Calculates the greatest common divisor of two integers.",
    params: [
        NativeParamInfo(name: "a", input: Int64.input, required: true),
        NativeParamInfo(name: "b", input: Int64.input, required: true),
    ],
    returns: Int64.output
) { _, _, args in
    let a: Int64 = try args.expectT("a")
    let b: Int64 = try args.expectT("b")
    try args.finishT()
    return try gcdI64(a, b)
}

let calcLcm = nativeFunc(
    "lcm", title: "Least Common Multiple", since: .version([0, 3, 0]),
    docs: "Calculates the least common multiple of two integers.",
    params: [
        NativeParamInfo(name: "a", input: Int64.input, required: true),
        NativeParamInfo(name: "b", input: Int64.input, required: true),
    ],
    returns: Int64.output
) { _, _, args in
    let a: Int64 = try args.expectT("a")
    let b: Int64 = try args.expectT("b")
    try args.finishT()
    if a == b {
        guard let r = checkedAbsI64(a) else { throw calcTooLarge() }
        return r
    }
    let g = try gcdI64(a, b)
    let (q, o1) = a.dividedReportingOverflow(by: g)
    let (p, o2) = q.multipliedReportingOverflow(by: b)
    guard !o1, !o2, let r = checkedAbsI64(p) else {
        throw calcTooLarge()
    }
    return r
}

// MARK: - Rounding

let calcFloor = nativeFunc(
    "floor", since: .forever,
    docs: "Rounds a number down to the nearest integer.",
    params: [NativeParamInfo(name: "value", input: DecNum.input, required: true)],
    returns: Int64.output
) { _, _, args in
    let value: DecNum = try args.expectT("value")
    try args.finishT()
    switch value {
    case .int(let n): return n
    case .float(let n):
        return try unwrap(convertFloatToInt(n.rounded(.down)))
    case .decimal(let n):
        return try decimalToInt64(n.floor())
    }
}

let calcCeil = nativeFunc(
    "ceil", since: .forever,
    docs: "Rounds a number up to the nearest integer.",
    params: [NativeParamInfo(name: "value", input: DecNum.input, required: true)],
    returns: Int64.output
) { _, _, args in
    let value: DecNum = try args.expectT("value")
    try args.finishT()
    switch value {
    case .int(let n): return n
    case .float(let n):
        return try unwrap(convertFloatToInt(n.rounded(.up)))
    case .decimal(let n):
        return try decimalToInt64(n.ceil())
    }
}

let calcTrunc = nativeFunc(
    "trunc", title: "Truncate", since: .version([0, 3, 0]),
    docs: "Returns the integer part of a number.",
    params: [NativeParamInfo(name: "value", input: DecNum.input, required: true)],
    returns: Int64.output
) { _, _, args in
    let value: DecNum = try args.expectT("value")
    try args.finishT()
    switch value {
    case .int(let n): return n
    case .float(let n):
        return try unwrap(convertFloatToInt(n.rounded(.towardZero)))
    case .decimal(let n):
        return try decimalToInt64(n.trunc())
    }
}

let calcFract = nativeFunc(
    "fract", title: "Fractional", since: .version([0, 3, 0]),
    docs: "Returns the fractional part of a number.",
    params: [NativeParamInfo(name: "value", input: DecNum.input, required: true)],
    returns: DecNum.output
) { _, _, args in
    let value: DecNum = try args.expectT("value")
    try args.finishT()
    switch value {
    case .int: return DecNum.int(0)
    case .float(let n): return DecNum.float(n - n.rounded(.towardZero))
    case .decimal(let n): return DecNum.decimal(n.fract())
    }
}

/// Convert an integral `Decimal` to `i64`, erroring when out of range.
private func decimalToInt64(_ d: Decimal) throws -> Int64 {
    // `Decimal.description` of an integral value has no fraction.
    guard let i = Int64(d.value.description) else {
        // May be in exponent form — go through double with range check.
        return try unwrap(convertFloatToInt(d.doubleValue))
    }
    return i
}

let calcRound = nativeFunc(
    "round", since: .forever,
    docs: "Rounds a number to the nearest integer.",
    params: [
        NativeParamInfo(name: "value", input: DecNum.input, required: true),
        NativeParamInfo(name: "digits", input: Int64.input,
                        defaultValue: { .int(0) }),
    ],
    returns: DecNum.output
) { _, _, args in
    let value: DecNum = try args.expectT("value")
    let digits: Int64 = try args.namedT("digits") ?? 0
    try args.finishT()
    let d16 = saturatingI16(digits)
    switch value {
    case .int(let n):
        guard let r = roundIntWithPrecision(n, d16) else { throw calcTooLarge() }
        return DecNum.int(r)
    case .float(let n):
        return DecNum.float(roundWithPrecision(n, d16))
    case .decimal(let n):
        guard let r = n.round(digits: Int(saturatingI32(digits))) else {
            throw calcTooLarge()
        }
        return DecNum.decimal(r)
    }
}

// MARK: - clamp / min / max

let calcClamp = nativeFunc(
    "clamp", since: .forever,
    docs: "Clamps a number between a minimum and maximum value.",
    params: [
        NativeParamInfo(name: "value", input: DecNum.input, required: true),
        NativeParamInfo(name: "min", input: DecNum.input, required: true),
        NativeParamInfo(name: "max", input: Spanned<DecNum, Span>.input, required: true),
    ],
    returns: DecNum.output
) { _, _, args in
    let value: DecNum = try args.expectT("value")
    let min: DecNum = try args.expectT("min")
    let max: Spanned<DecNum, Span> = try args.expectT("max")
    try args.finishT()

    // Ignore incompatible decimal/float mixes — `apply3` errors below.
    let maxLessThanMin = min.apply2(
        max.value,
        int: { _, max in max < min.intComponent },
        float: { _, max in max < min.floatComponent },
        decimal: { _, max in max < min.decimalComponent }
    ) ?? false
    if maxLessThanMin {
        throw SourceDiagnostics(SourceDiagnostic.error(max.span, "max must be greater than or equal to min"))
    }

    guard let result = value.apply3(
        min, max.value,
        int: { clampI64($0, $1, $2) },
        float: { clampF64($0, $1, $2) },
        decimal: { Decimal.clamp($0, $1, $2) }
    ) else {
        throw calcCantMixDecimalFloat()
    }
    return result
}

/// Find the minimum or maximum of a sequence of values.
private func calcMinMax(_ span: Span, _ values: [Spanned<Value, Span>],
                        _ goal: ComparisonResult) throws -> Value {
    guard var extremum = values.first?.value else {
        throw SourceDiagnostics(SourceDiagnostic.error(span, "expected at least one value"))
    }
    for v in values.dropFirst() {
        let ordering: ComparisonResult
        switch ops_compare(v.value, extremum) {
        case .success(let o): ordering = o
        case .failure(let e):
            throw SourceDiagnostics(SourceDiagnostic.error(v.span, e.message))
        }
        if ordering == goal { extremum = v.value }
    }
    return extremum
}

let calcMin = nativeFunc(
    "min", title: "Minimum", since: .forever,
    docs: "Determines the minimum of a sequence of values.",
    params: [NativeParamInfo(name: "values", input: .any, variadic: true)],
    returns: .any
) { _, _, args in
    let span = args.span
    let values: [Spanned<Value, Span>] = try args.allT()
    try args.finishT()
    return try calcMinMax(span, values, .orderedAscending)
}

let calcMax = nativeFunc(
    "max", title: "Maximum", since: .forever,
    docs: "Determines the maximum of a sequence of values.",
    params: [NativeParamInfo(name: "values", input: .any, variadic: true)],
    returns: .any
) { _, _, args in
    let span = args.span
    let values: [Spanned<Value, Span>] = try args.allT()
    try args.finishT()
    return try calcMinMax(span, values, .orderedDescending)
}

// MARK: - Parity

let calcEven = nativeFunc(
    "even", since: .forever,
    docs: "Determines whether an integer is even.",
    params: [NativeParamInfo(name: "value", input: Int64.input, required: true)],
    returns: Bool.output
) { _, _, args in
    let value: Int64 = try args.expectT("value")
    try args.finishT()
    return value % 2 == 0
}

let calcOdd = nativeFunc(
    "odd", since: .forever,
    docs: "Determines whether an integer is odd.",
    params: [NativeParamInfo(name: "value", input: Int64.input, required: true)],
    returns: Bool.output
) { _, _, args in
    let value: Int64 = try args.expectT("value")
    try args.finishT()
    return value % 2 != 0
}

// MARK: - Remainder / division

/// Shared divisor-zero check + `DecNum.apply2` plumbing for rem/div funcs.
private func divOp(
    _ dividend: DecNum, _ divisor: Spanned<DecNum, Span>, span: Span,
    int: (Int64, Int64) -> DecNum?,
    float: (Double, Double) -> DecNum?,
    decimal: (Decimal, Decimal) -> DecNum?
) throws -> DecNum {
    if divisor.value.isZero {
        throw SourceDiagnostics(SourceDiagnostic.error(divisor.span, "divisor must not be zero"))
    }
    guard let result = dividend.apply2(
        divisor.value, int: int, float: float, decimal: decimal
    ) else {
        throw calcCantMixDecimalFloat()
    }
    guard let result else {
        throw SourceDiagnostics(SourceDiagnostic.error(span, "dividend too small compared to divisor"))
    }
    return result
}

let calcRem = nativeFunc(
    "rem", title: "Remainder", since: .version([0, 3, 0]),
    docs: "Calculates the remainder of two numbers (signed modulo).",
    keywords: ["modulo", "modulus"],
    params: [
        NativeParamInfo(name: "dividend", input: DecNum.input, required: true),
        NativeParamInfo(name: "divisor", input: Spanned<DecNum, Span>.input, required: true),
    ],
    returns: DecNum.output
) { _, _, args in
    let span = args.span
    let dividend: DecNum = try args.expectT("dividend")
    let divisor: Spanned<DecNum, Span> = try args.expectT("divisor")
    try args.finishT()
    return try divOp(dividend, divisor, span: span,
        int: { a, b in
            // `i64::MIN % -1` is mathematically zero.
            let (r, o) = a.remainderReportingOverflow(dividingBy: b)
            return DecNum.int(o ? 0 : r)
        },
        float: { DecNum.float($0.truncatingRemainder(dividingBy: $1)) },
        decimal: { a, b in b.value == 0 ? nil : a.checkedRem(b).map { DecNum.decimal($0) } }
    )
}

let calcDivEuclid = nativeFunc(
    "div-euclid", title: "Euclidean Division", since: .version([0, 10, 0]),
    docs: "Performs euclidean division of two numbers.",
    params: [
        NativeParamInfo(name: "dividend", input: DecNum.input, required: true),
        NativeParamInfo(name: "divisor", input: Spanned<DecNum, Span>.input, required: true),
    ],
    returns: DecNum.output
) { _, _, args in
    let dividend: DecNum = try args.expectT("dividend")
    let divisor: Spanned<DecNum, Span> = try args.expectT("divisor")
    try args.finishT()
    if divisor.value.isZero {
        throw SourceDiagnostics(SourceDiagnostic.error(divisor.span, "divisor must not be zero"))
    }
    let result = dividend.apply2(
        divisor.value,
        int: { a, b in divEuclidI64(a, b).map { DecNum.int($0) } },
        float: { DecNum.float(divEuclidF64($0, $1)) },
        decimal: { a, b in a.checkedDivEuclid(b).map { DecNum.decimal($0) } }
    )
    guard let outer = result else { throw calcCantMixDecimalFloat() }
    guard let divided = outer else {
        throw StrError(calcTooLarge().message)
    }
    return divided
}

let calcRemEuclid = nativeFunc(
    "rem-euclid", title: "Euclidean Remainder", since: .version([0, 10, 0]),
    docs: "Calculates the least nonnegative remainder of a division.",
    keywords: ["modulo", "modulus"],
    params: [
        NativeParamInfo(name: "dividend", input: DecNum.input, required: true),
        NativeParamInfo(name: "divisor", input: Spanned<DecNum, Span>.input, required: true),
    ],
    returns: DecNum.output
) { _, _, args in
    let span = args.span
    let dividend: DecNum = try args.expectT("dividend")
    let divisor: Spanned<DecNum, Span> = try args.expectT("divisor")
    try args.finishT()
    return try divOp(dividend, divisor, span: span,
        int: { a, b in
            let (r, o) = a.remainderReportingOverflow(dividingBy: b)
            if o { return .int(0) }
            if r < 0 {
                let (mag, _) = abs(b).addingReportingOverflow(0)
                let (r2, o2) = r.addingReportingOverflow(mag)
                return DecNum.int(o2 ? 0 : r2)
            }
            return DecNum.int(r)
        },
        float: { DecNum.float(remEuclidF64($0, $1)) },
        decimal: { a, b in a.checkedRemEuclid(b).map { DecNum.decimal($0) } }
    )
}

let calcQuo = nativeFunc(
    "quo", title: "Quotient", since: .version([0, 3, 0]),
    docs: "Calculates the quotient (floored division) of two numbers.",
    params: [
        NativeParamInfo(name: "dividend", input: DecNum.input, required: true),
        NativeParamInfo(name: "divisor", input: Spanned<DecNum, Span>.input, required: true),
    ],
    returns: Int64.output
) { _, _, args in
    let dividend: DecNum = try args.expectT("dividend")
    let divisor: Spanned<DecNum, Span> = try args.expectT("divisor")
    try args.finishT()
    if divisor.value.isZero {
        throw SourceDiagnostics(SourceDiagnostic.error(divisor.span, "divisor must not be zero"))
    }

    let dividedResult = dividend.apply2(
        divisor.value,
        int: { a, b -> DecNum? in
            let (q, o0) = a.dividedReportingOverflow(by: b)
            let (r, o) = a.remainderReportingOverflow(dividingBy: b)
            if o0 || o { return nil }
            // Round towards negative infinity if the fraction is negative.
            if (a < 0) != (b < 0) && r != 0 {
                let (q2, o2) = q.subtractingReportingOverflow(1)
                return o2 ? nil : DecNum.int(q2)
            }
            return DecNum.int(q)
        },
        float: { DecNum.float($0 / $1) },
        decimal: { a, b in a.checkedDiv(b).map { DecNum.decimal($0) } }
    )
    guard let outer = dividedResult else { throw calcCantMixDecimalFloat() }
    guard let divided = outer else {
        throw StrError(calcTooLarge().message)
    }

    // floor the divided result to i64.
    switch divided {
    case .int(let n): return n
    case .float(let n):
        return try unwrap(convertFloatToInt(n.rounded(.down)))
    case .decimal(let n):
        return try decimalToInt64(n.floor())
    }
}

// MARK: - p-norm

let calcNorm = nativeFunc(
    "norm", title: "𝑝-Norm", since: .version([0, 13, 0]),
    docs: "Calculates the p-norm of a sequence of values.",
    params: [
        NativeParamInfo(name: "p", input: Spanned<Double, Span>.input,
                        defaultValue: { .float(2.0) }),
        NativeParamInfo(name: "values", input: Double.input, variadic: true),
    ],
    returns: Double.output
) { _, _, args in
    let p: Spanned<Double, Span> = try args.namedT("p") ?? .detached(2.0)
    let values: [Double] = try args.allT()
    try args.finishT()

    if p.value <= 0.0 {
        throw SourceDiagnostics(SourceDiagnostic.error(p.span, "p must be greater than zero"))
    }

    let absValues = values.map { Swift.abs($0) }
    let maxValue = absValues.max() ?? 0.0

    if p.value.isInfinite {
        return maxValue
    } else if maxValue == 0.0 {
        return 0.0
    }
    let sum = absValues.map { pow($0 / maxValue, p.value) }.reduce(0, +)
    return maxValue * pow(sum, 1.0 / p.value)
}

// MARK: - Num / DecNum

/// A value which can be passed to functions that work with integers and floats.
enum Num: Sendable, Hashable {
    case int(Int64)
    case float(Double)

    var floatValue: Double {
        switch self {
        case .int(let v): return Double(v)
        case .float(let v): return v
        }
    }
}

extension Num: Castable, IntoValue, FromValue {
    static var input: CastInfo { .union([Int64.input, Double.input]) }
    static var output: CastInfo { .union([Int64.output, Double.output]) }
    static func castable(_ value: Value) -> Bool {
        switch value {
        case .int, .float: return true
        default: return false
        }
    }
    static func error(_ value: Value) -> HintedString {
        input.error(value)
    }
    func intoValue() -> Value {
        switch self {
        case .int(let v): return .int(v)
        case .float(let v): return .float(v)
        }
    }
    static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .int(let v): return .success(.int(v))
        case .float(let v): return .success(.float(v))
        default: return .failure(error(value))
        }
    }
}

/// A value which can be passed to functions that work with integers, floats,
/// and decimals.
enum DecNum: Sendable, Hashable {
    case int(Int64)
    case float(Double)
    case decimal(Decimal)

    /// Whether this number is equivalent to zero.
    var isZero: Bool {
        switch self {
        case .int(let i): return i == 0
        case .float(let f): return f == 0.0
        case .decimal(let d): return d.isZero
        }
    }

    /// If this `DecNum` holds an integer or float, returns a float.
    var floatValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .float(let f): return f
        case .decimal: return nil
        }
    }

    /// Raw int component (only meaningful when both operands are ints —
    /// used by `clamp`'s mixed-type pre-check).
    var intComponent: Int64 {
        if case .int(let i) = self { return i }
        return 0
    }
    var floatComponent: Double {
        floatValue ?? 0
    }
    var decimalComponent: Decimal {
        decimalValue ?? Decimal(Int64(0))
    }

    /// If this `DecNum` holds an integer or decimal, returns a decimal.
    var decimalValue: Decimal? {
        switch self {
        case .int(let i): return Decimal(i)
        case .float: return nil
        case .decimal(let d): return d
        }
    }

    /// Tries to apply a function to two decimal or numeric arguments.
    /// Fails with `nil` if one is a float and the other is a decimal.
    func apply2<T>(
        _ other: DecNum,
        int: (Int64, Int64) -> T,
        float: (Double, Double) -> T,
        decimal: (Decimal, Decimal) -> T
    ) -> T? {
        switch (self, other) {
        case (.int(let a), .int(let b)): return int(a, b)
        case (.decimal(let a), .decimal(let b)): return decimal(a, b)
        case (.decimal(let a), .int(let b)): return decimal(a, Decimal(b))
        case (.int(let a), .decimal(let b)): return decimal(Decimal(a), b)
        default:
            guard let a = floatValue, let b = other.floatValue else { return nil }
            return float(a, b)
        }
    }

    /// Tries to apply a function to three decimal or numeric arguments.
    func apply3(
        _ other: DecNum, _ third: DecNum,
        int: (Int64, Int64, Int64) -> Int64,
        float: (Double, Double, Double) -> Double,
        decimal: (Decimal, Decimal, Decimal) -> Decimal
    ) -> DecNum? {
        switch (self, other, third) {
        case (.int(let a), .int(let b), .int(let c)):
            return .int(int(a, b, c))
        case (.decimal(let a), let b, let c):
            guard let bd = b.decimalValue, let cd = c.decimalValue else { return nil }
            return .decimal(decimal(a, bd, cd))
        case (let a, .decimal(let b), let c):
            guard let ad = a.decimalValue, let cd = c.decimalValue else { return nil }
            return .decimal(decimal(ad, b, cd))
        case (let a, let b, .decimal(let c)):
            guard let ad = a.decimalValue, let bd = b.decimalValue else { return nil }
            return .decimal(decimal(ad, bd, c))
        default:
            guard let a = floatValue, let b = other.floatValue,
                  let c = third.floatValue else { return nil }
            return .float(float(a, b, c))
        }
    }
}

extension DecNum: Castable, IntoValue, FromValue {
    static var input: CastInfo {
        .union([Int64.input, Double.input, Decimal.input])
    }
    static var output: CastInfo {
        .union([Int64.output, Double.output, Decimal.output])
    }
    static func castable(_ value: Value) -> Bool {
        switch value {
        case .int, .float, .decimal: return true
        default: return false
        }
    }
    static func error(_ value: Value) -> HintedString {
        input.error(value)
    }
    func intoValue() -> Value {
        switch self {
        case .int(let v): return .int(v)
        case .float(let v): return .float(v)
        case .decimal(let v): return .decimal(v)
        }
    }
    static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .int(let v): return .success(.int(v))
        case .float(let v): return .success(.float(v))
        case .decimal(let v): return .success(.decimal(v))
        default: return .failure(error(value))
        }
    }
}
