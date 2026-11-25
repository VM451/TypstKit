import Foundation
import TypstSyntax

/// An error or warning in a source or text file.
///
/// Port of `typst-library/src/diag.rs` (`SourceDiagnostic`, `Severity`,
/// `Tracepoint`). Created via `SourceDiagnostic.error` / `.warning`.
public struct SourceDiagnostic: Sendable, Hashable {
    /// Whether the diagnostic is an error or a warning.
    public var severity: Severity
    /// The span of a relevant node in a Typst source file or the relevant
    /// byte range of an external file.
    public var span: DiagSpan
    /// A diagnostic message describing the problem.
    public var message: String
    /// The trace of function calls leading to the problem.
    public var trace: [Spanned<Tracepoint, Span>]
    /// Additional hints to the user. When the span is `nil`, these are
    /// generic hints rendered as a list; when a span is given, the hint
    /// annotates that secondary piece of code.
    public var hints: [Spanned<String, DiagSpan>]

    /// Create a new, bare error.
    public static func error(_ span: DiagSpan, _ message: String) -> SourceDiagnostic {
        SourceDiagnostic(severity: .error, span: span, message: message,
                         trace: [], hints: [])
    }

    /// Create a new, bare error from a source span.
    public static func error(_ span: Span, _ message: String) -> SourceDiagnostic {
        .error(span.diag, message)
    }

    /// Create a new, bare warning.
    public static func warning(_ span: DiagSpan, _ message: String) -> SourceDiagnostic {
        SourceDiagnostic(severity: .warning, span: span, message: message,
                         trace: [], hints: [])
    }

    /// Create a new, bare warning from a source span.
    public static func warning(_ span: Span, _ message: String) -> SourceDiagnostic {
        .warning(span.diag, message)
    }

    /// Add a hint at the diagnostic's own span.
    public mutating func hint(_ hint: String) {
        hints.append(Spanned(hint, span: span))
    }

    /// Add a hint at a custom span.
    public mutating func hint(_ hint: String, at span: DiagSpan) {
        hints.append(Spanned(hint, span: span))
    }

    /// Add a tracepoint at a span.
    public mutating func tracepoint(_ point: Tracepoint, at span: Span) {
        trace.append(Spanned(point, span: span))
    }
}

/// The severity of a `SourceDiagnostic`.
public enum Severity: Sendable, Hashable {
    /// A fatal error.
    case error
    /// A non-fatal warning.
    case warning
}

/// A part of a diagnostic's trace.
public enum Tracepoint: Sendable, Hashable {
    /// A context expression.
    case context
    /// A default show rule application or synthesis.
    case process(String)
    /// A function call.
    case call(String?)
    /// A show rule application.
    case show(String)
    /// A module import.
    case `import`(String)
    /// A module include.
    case `include`(String)
}

extension Tracepoint: CustomStringConvertible {
    public var description: String {
        switch self {
        case .context: return "while evaluating contextual content"
        case .process(let name): return "while processing \(name) element"
        case .call(let name):
            if let name { return "while calling `\(name)`" }
            return "while calling function"
        case .show(let name): return "while showing \(name) element"
        case .`import`(let name): return "while importing `\(name)`"
        case .`include`(let name): return "while including `\(name)`"
        }
    }
}

/// Boxed source diagnostics used as the `Failure` of `SourceResult`.
/// Mirrors upstream's `EcoVec<SourceDiagnostic>` error payload.
public struct SourceDiagnostics: Error, Sendable, Hashable {
    /// The collected diagnostics.
    public var diagnostics: [SourceDiagnostic]

    public init(_ diagnostics: [SourceDiagnostic]) {
        self.diagnostics = diagnostics
    }

    public init(_ diagnostic: SourceDiagnostic) {
        self.diagnostics = [diagnostic]
    }

    /// The first diagnostic, if any.
    public var first: SourceDiagnostic? { diagnostics.first }
}

extension SourceDiagnostics: CustomStringConvertible {
    public var description: String {
        diagnostics.map(\.message).joined(separator: "\n")
    }
}

/// A bare string error used as the `Failure` of `StrResult`.
/// Mirrors upstream's `EcoString` error payload.
public struct StrError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The result of an operation that can produce source diagnostics.
/// Mirrors `SourceResult<T> = Result<T, EcoVec<SourceDiagnostic>>`.
public typealias SourceResult<T> = Result<T, SourceDiagnostics>

/// The result of an operation that can produce a bare error string.
/// Mirrors `StrResult<T> = Result<T, EcoString>`.
public typealias StrResult<T> = Result<T, StrError>

/// The result of an operation that can produce a hinted string error.
/// Mirrors `HintedStrResult<T> = Result<T, HintedString>`.
public typealias HintedStrResult<T> = Result<T, HintedString>

/// A string message with hints.
///
/// Port of `HintedString` in `diag.rs`. Internally a vector whose first
/// element is the message and the rest are hints.
public struct HintedString: Error, Sendable, Hashable, CustomStringConvertible {
    /// The message followed by the hints.
    private var parts: [String]

    /// Creates a new hinted string with the given message.
    public init(_ message: String) {
        parts = [message]
    }

    /// Creates a new hinted string with a message and hints.
    public init(message: String, hints: [String]) {
        parts = [message] + hints
    }

    /// A diagnostic message describing the problem.
    public var message: String { parts[0] }

    /// Additional hints to the user.
    public var hints: [String] { Array(parts.dropFirst()) }

    /// The full parts vector (message first, then hints).
    public var allParts: [String] { parts }

    /// Adds a single hint.
    public mutating func hint(_ hint: String) {
        parts.append(hint)
    }

    /// Adds a single hint, returning self.
    public func withHint(_ hint: String) -> HintedString {
        var copy = self
        copy.hint(hint)
        return copy
    }

    /// Adds user-facing hints.
    public func withHints(_ hints: [String]) -> HintedString {
        var copy = self
        copy.parts.append(contentsOf: hints)
        return copy
    }

    /// Convert this hinted string into a spanned error.
    public func intoErrorAt(_ span: Span) -> SourceDiagnostic {
        var diag = SourceDiagnostic.error(span, message)
        for h in hints { diag.hint(h, at: span.diag) }
        return diag
    }

    /// Convert this hinted string into a spanned warning.
    public func intoWarningAt(_ span: Span) -> SourceDiagnostic {
        var diag = SourceDiagnostic.warning(span, message)
        for h in hints { diag.hint(h, at: span.diag) }
        return diag
    }

    public var description: String { parts.joined(separator: "\n") }
}

extension HintedString: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

/// Failure types convertible into source diagnostics at a span.
/// Swift cannot express upstream's per-`Result`-alias trait impls, so the
/// conversion lives on the failure type instead.
public protocol AtFailure {
    func atDiagnostics(_ span: Span) -> SourceDiagnostics
}

extension StrError: AtFailure {
    public func atDiagnostics(_ span: Span) -> SourceDiagnostics {
        SourceDiagnostics(SourceDiagnostic.error(span, message))
    }
}

extension HintedString: AtFailure {
    public func atDiagnostics(_ span: Span) -> SourceDiagnostics {
        SourceDiagnostics(intoErrorAt(span))
    }
}

/// Convert a `StrResult` or `HintedStrResult` to a `SourceResult` by adding
/// span information. Port of the `At` trait in `diag.rs`.
public protocol AtResult {
    associatedtype Success
    func at(_ span: Span) -> SourceResult<Success>
}

extension Result: AtResult where Failure: AtFailure {
    public func at(_ span: Span) -> SourceResult<Success> {
        mapError { $0.atDiagnostics(span) }
    }
}

/// Failure types that can be enriched with a hint.
public protocol HintConvertible {
    func asHintedString() -> HintedString
}

extension StrError: HintConvertible {
    public func asHintedString() -> HintedString { HintedString(message) }
}

extension HintedString: HintConvertible {
    public func asHintedString() -> HintedString { self }
}

/// Enrich a `StrResult` or `HintedStrResult` with a hint.
/// Port of the `Hint` trait in `diag.rs`.
public protocol HintResult {
    associatedtype Success
    func hint(_ hint: String) -> HintedStrResult<Success>
}

extension Result: HintResult where Failure: HintConvertible {
    public func hint(_ hint: String) -> HintedStrResult<Success> {
        mapError { $0.asHintedString().withHint(hint) }
    }
}

extension Result where Failure == SourceDiagnostics {
    /// Attach a tracepoint to every diagnostic whose span lies outside
    /// `span`.
    public func traced(_ point: Tracepoint, at span: Span) -> SourceResult<Success> {
        mapError { diags in
            SourceDiagnostics(diags.diagnostics.map { $0.traced(point, at: span) })
        }
    }
}

extension SourceDiagnostic {
    /// Attach a tracepoint to every diagnostic in the result whose span
    /// lies outside `span`.
    public func traced(_ point: Tracepoint, at span: Span) -> SourceDiagnostic {
        var copy = self
        if copy.span.isDetached || copy.span.id != span.id {
            copy.tracepoint(point, at: span)
        }
        return copy
    }
}
