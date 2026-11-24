import Foundation

/// A floating point number that is never NaN and has a total order.
///
/// Port of `typst-utils/src/scalar.rs`. `NaN` inputs are mapped to `0.0`
/// at construction, which makes `Equatable`/`Comparable`/`Hashable`
/// total. Hashing uses the bit pattern like upstream (so `0.0` and `-0.0`
/// compare equal but hash differently, matching Rust semantics).
public struct Scalar: Sendable, Hashable {
    /// The wrapped value; guaranteed non-NaN.
    public private(set) var raw: Double

    public static let zero = Scalar(0.0)
    public static let one = Scalar(1.0)
    public static let infinity = Scalar(Double.infinity)

    /// Create a scalar, mapping NaN to zero.
    public init(_ x: Double) {
        raw = x.isNaN ? 0.0 : x
    }

    /// The wrapped `f64`.
    public var get: Double { raw }

    public func sqrt() -> Scalar { Scalar(raw.squareRoot()) }

    /// `self^b` for integer `b`, ported from LLVM's `powidf2` like upstream.
    public func powi(_ b0: Int32) -> Scalar {
        var b = b0
        var a = raw
        let recip = b < 0
        var r = 1.0
        while true {
            if (b & 1) != 0 { r *= a }
            b /= 2
            if b == 0 { break }
            a *= a
        }
        if recip { r = 1.0 / r }
        return Scalar(r)
    }
}

extension Scalar: Numeric {
    public static var numericZero: Scalar { .zero }
    public var isFinite: Bool { raw.isFinite }
    public func multiplied(by factor: Double) -> Scalar { self * factor }
    public func added(to other: Scalar) -> Scalar { self + other }
}

extension Scalar: CustomDebugStringConvertible {
    public var debugDescription: String { "\(raw)" }
}

extension Scalar: CustomStringConvertible {
    public var description: String { "\(raw)" }
}

extension Scalar: Comparable {
    public static func < (lhs: Scalar, rhs: Scalar) -> Bool {
        precondition(!lhs.raw.isNaN && !rhs.raw.isNaN, "float is NaN")
        return lhs.raw < rhs.raw
    }
}

extension Scalar: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self.init(value) }
}

public func + (lhs: Scalar, rhs: Scalar) -> Scalar { Scalar(lhs.raw + rhs.raw) }
public func + (lhs: Scalar, rhs: Double) -> Scalar { Scalar(lhs.raw + rhs) }
public func + (lhs: Double, rhs: Scalar) -> Scalar { Scalar(lhs + rhs.raw) }
public func - (lhs: Scalar, rhs: Scalar) -> Scalar { Scalar(lhs.raw - rhs.raw) }
public func - (lhs: Scalar, rhs: Double) -> Scalar { Scalar(lhs.raw - rhs) }
public func - (lhs: Double, rhs: Scalar) -> Scalar { Scalar(lhs - rhs.raw) }
public func * (lhs: Scalar, rhs: Scalar) -> Scalar { Scalar(lhs.raw * rhs.raw) }
public func * (lhs: Scalar, rhs: Double) -> Scalar { Scalar(lhs.raw * rhs) }
public func * (lhs: Double, rhs: Scalar) -> Scalar { Scalar(lhs * rhs.raw) }
public func / (lhs: Scalar, rhs: Scalar) -> Scalar { Scalar(lhs.raw / rhs.raw) }
public func / (lhs: Scalar, rhs: Double) -> Scalar { Scalar(lhs.raw / rhs) }
public func / (lhs: Double, rhs: Scalar) -> Scalar { Scalar(lhs / rhs.raw) }
public func % (lhs: Scalar, rhs: Scalar) -> Scalar { Scalar(lhs.raw.truncatingRemainder(dividingBy: rhs.raw)) }
public func % (lhs: Scalar, rhs: Double) -> Scalar { Scalar(lhs.raw.truncatingRemainder(dividingBy: rhs)) }
public func % (lhs: Double, rhs: Scalar) -> Scalar { Scalar(lhs.truncatingRemainder(dividingBy: rhs.raw)) }
public prefix func - (x: Scalar) -> Scalar { Scalar(-x.raw) }

public func += (lhs: inout Scalar, rhs: Scalar) { lhs = lhs + rhs }
public func += (lhs: inout Scalar, rhs: Double) { lhs = lhs + rhs }
public func -= (lhs: inout Scalar, rhs: Scalar) { lhs = lhs - rhs }
public func -= (lhs: inout Scalar, rhs: Double) { lhs = lhs - rhs }
public func *= (lhs: inout Scalar, rhs: Scalar) { lhs = lhs * rhs }
public func *= (lhs: inout Scalar, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Scalar, rhs: Scalar) { lhs = lhs / rhs }
public func /= (lhs: inout Scalar, rhs: Double) { lhs = lhs / rhs }
public func %= (lhs: inout Scalar, rhs: Scalar) { lhs = lhs % rhs }
public func %= (lhs: inout Scalar, rhs: Double) { lhs = lhs % rhs }
