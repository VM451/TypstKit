import Foundation
import TypstSyntax

/// Determine details of a type.
///
/// Port of `typst-library/src/foundations/cast.rs`. Type casting works as
/// follows:
/// - `Castable` (Reflect) describes the possible Typst values for a type
///   (for documentation and autocomplete).
/// - `IntoValue` is for conversion from `T -> Value` (infallible).
/// - `FromValue` is for conversion from `Value -> T` (fallible).
///
/// Rust uses a `cast!` proc macro to generate these impls; Swift uses
/// protocol conformances declared on each type (see ARCHITECTURE.md).
public protocol Castable {
    /// Describe what can be cast into this value.
    static var input: CastInfo { get }
    /// Describe what this value can be cast into.
    static var output: CastInfo { get }
    /// Whether the given value can be converted to this type.
    static func castable(_ value: Value) -> Bool
    /// Produce an error message for an unacceptable value type.
    static func error(_ found: Value) -> HintedString
}

extension Castable {
    public static func error(_ found: Value) -> HintedString {
        input.error(found)
    }
}

extension Castable where Self == Value {
    public static var input: CastInfo { .any }
    public static var output: CastInfo { .any }
    public static func castable(_ value: Value) -> Bool { true }
}

/// Cast a Swift type into a Typst `Value`.
public protocol IntoValue {
    func intoValue() -> Value
}

extension IntoValue where Self == Value {
    public func intoValue() -> Value { self }
}

/// Failure types convertible into source diagnostics at a span for
/// `intoResult`. Mirrors the three `IntoResult` impls in upstream `cast.rs`.
public protocol IntoResultFailure {
    func intoResultDiagnostics(at span: Span) -> SourceDiagnostics
}

extension StrError: IntoResultFailure {
    public func intoResultDiagnostics(at span: Span) -> SourceDiagnostics {
        SourceDiagnostics(SourceDiagnostic.error(span, message))
    }
}

extension HintedString: IntoResultFailure {
    public func intoResultDiagnostics(at span: Span) -> SourceDiagnostics {
        SourceDiagnostics(intoErrorAt(span))
    }
}

extension SourceDiagnostics: IntoResultFailure {
    public func intoResultDiagnostics(at span: Span) -> SourceDiagnostics { self }
}

/// Cast a result type into a `SourceResult<Value>`.
///
/// Rust implements `IntoResult` for both plain `T: IntoValue` and the three
/// result aliases; Swift covers the result types via a single conformance
/// keyed on the failure type (Swift forbids multiple conditional
/// conformances of `Result`). Plain values are wrapped by call sites with
/// `.success` or the `intoResultValue` helpers.
public protocol IntoResult {
    func intoResult(span: Span) -> SourceResult<Value>
}

extension Result: IntoResult where Success: IntoValue, Failure: IntoResultFailure {
    public func intoResult(span: Span) -> SourceResult<Value> {
        map { $0.intoValue() }.mapError { $0.intoResultDiagnostics(at: span) }
    }
}

/// Wrap a plain `IntoValue` into a `SourceResult<Value>`.
public func intoResultValue<T: IntoValue>(_ value: T) -> SourceResult<Value> {
    .success(value.intoValue())
}

/// Wrap a `StrResult` into a `SourceResult<Value>` at `span`.
public func intoResultValue<T: IntoValue>(_ result: StrResult<T>, span: Span) -> SourceResult<Value> {
    result.map { $0.intoValue() }.at(span)
}

/// Try to cast a Typst `Value` into a Swift type.
public protocol FromValue: Castable {
    static func fromValue(_ value: Value) -> HintedStrResult<Self>
    /// Cast a spanned value; the span is attached by callers via `.at`.
    /// Mirrors upstream's `Spanned<Value>` cast path.
    static func fromSpannedValue(
        _ spanned: Spanned<Value, Span>
    ) -> HintedStrResult<Self>
}

extension FromValue {
    public static func fromSpannedValue(
        _ spanned: Spanned<Value, Span>
    ) -> HintedStrResult<Self> {
        fromValue(spanned.value)
    }
}

extension FromValue where Self == Value {
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> { .success(value) }
}

/// Describes a possible value for a cast.
public indirect enum CastInfo: Hashable, Sendable {
    /// Any value is okay.
    case any
    /// A specific value, plus short documentation for that value.
    case value(Value, doc: String)
    /// Any value of a type.
    case type(Type)
    /// Multiple alternatives.
    case union([CastInfo])
}

extension CastInfo: Comparable {
    public static func < (lhs: CastInfo, rhs: CastInfo) -> Bool {
        func rank(_ info: CastInfo) -> Int {
            switch info {
            case .any: return 0
            case .value: return 1
            case .type: return 2
            case .union: return 3
            }
        }
        let (a, b) = (rank(lhs), rank(rhs))
        if a != b { return a < b }
        return "\(lhs)" < "\(rhs)"
    }
}

extension CastInfo: CustomStringConvertible {
    public var description: String {
        switch self {
        case .any: return "any"
        case let .value(v, doc): return "\(v.repr()) (\(doc))"
        case let .type(t): return "\(t)"
        case let .union(u): return u.map(\.description).joined(separator: " | ")
        }
    }
}

extension CastInfo {
    /// Produce an error message describing what was expected and what was
    /// found.
    public func error(_ found: Value) -> HintedString {
        var matchingType = false
        var parts: [String] = []

        walk { info in
            switch info {
            case .any:
                parts.append("anything")
            case let .value(value, _):
                parts.append(value.repr())
                if value.type == found.type { matchingType = true }
            case let .type(ty):
                parts.append("\(ty)")
            case .union:
                break
            }
        }

        var msg = "expected "
        if parts.isEmpty { msg += " nothing" }
        msg += reprSeparatedList(parts, last: "or")

        if !matchingType {
            msg += ", found \(found.type)"
        }

        var result = HintedString(msg)

        if case let .int(i) = found, !matchingType,
           parts.contains("length")
        {
            result.hint("a length needs a unit - did you mean \(i)pt?")
        } else if case let .str(s) = found, !matchingType,
                  parts.contains("label")
        {
            if TypstSyntax.isValidLabelLiteralId(s.string) {
                result.hint("use `<\(s.string)>` or `label(\(s.repr()))` to create a label")
            } else {
                result.hint("use `label(\(s.repr()))` to create a label")
            }
        } else if case .decimal = found, !matchingType,
                  parts.contains("float")
        {
            result.hint(
                "if loss of precision is acceptable, explicitly cast the " +
                "decimal to a float with `float(value)`"
            )
        }

        return result
    }

    /// Walk all contained non-union infos.
    public func walk(_ f: (CastInfo) -> Void) {
        func inner(_ info: CastInfo) {
            if case let .union(infos) = info {
                for child in infos { inner(child) }
            } else {
                f(info)
            }
        }
        inner(self)
    }

    /// Union of two cast infos, deduplicated, preserving order.
    public static func + (lhs: CastInfo, rhs: CastInfo) -> CastInfo {
        switch (lhs, rhs) {
        case let (.union(l), .union(r)):
            var out = l
            for cast in r where !out.contains(cast) { out.append(cast) }
            return .union(out)
        case let (.union(l), r):
            var out = l
            if !out.contains(r) { out.append(r) }
            return .union(out)
        case let (l, .union(r)):
            var out = r
            if !out.contains(l) { out.insert(l, at: 0) }
            return .union(out)
        case (let l, let r):
            return .union([l, r])
        }
    }
}

/// An uninhabitable type.
public enum Never: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .union([]) }
    public static var output: CastInfo { .union([]) }
    public static func castable(_ value: Value) -> Bool { false }
    public func intoValue() -> Value { fatalError("Never has no values") }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        .failure(error(value))
    }
}

/// A type that contains a user-visible source portion and something that is
/// derived from it, but not user-visible (port of `Derived<S, D>`).
public struct Derived<S: Castable & IntoValue & Hashable & Sendable,
                    D: Hashable & Sendable>: Castable, IntoValue, Hashable, Sendable {
    public var source: S
    public var derived: D

    public init(source: S, derived: D) {
        self.source = source
        self.derived = derived
    }

    public static var input: CastInfo { S.input }
    public static var output: CastInfo { S.output }
    public static func castable(_ value: Value) -> Bool { S.castable(value) }
    public static func error(_ found: Value) -> HintedString { S.error(found) }

    public func intoValue() -> Value { source.intoValue() }
}


/// `Value` is trivially castable to and from itself.
extension Value: Castable, IntoValue, FromValue {}
