import Foundation

/// Numeric types that can be zero and checked for finiteness.
///
/// Port of `Numeric`/`NumericLength` in `typst-utils/src/numeric.rs`.
/// Swift cannot express the full Rust trait bound set (`Neg`/`Add`/etc.
/// with `Self` outputs) as protocol requirements, so conforming types
/// implement the arithmetic operators directly; this protocol only
/// carries the shared predicates.
public protocol Numeric: Equatable {
    static var numericZero: Self { get }
    var isFinite: Bool { get }
    /// `self * factor` — needed by generic resolvers like `Ratio.of`.
    func multiplied(by factor: Double) -> Self
    /// `self + other`.
    func added(to other: Self) -> Self
}

extension Numeric {
    public func isZero() -> Bool { self == Self.numericZero }
}

/// Marker for numeric types that also represent lengths (em/abs based).
public protocol NumericLength: Numeric {}
