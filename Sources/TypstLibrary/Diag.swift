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
public struct SourceDiagnostics: Error, Sendable {
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
/// Mirrors `HintedStrResult<T>`.
public typealias HintedStrResult<T> = Result<T, HintedError>

/// A string error with additional hints.
public struct HintedError: Error, Sendable {
    public var message: String
    public var hints: [String]

    public init(_ message: String, hints: [String] = []) {
        self.message = message
        self.hints = hints
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
