import Foundation
import TypstSyntax

// MARK: - Throwing result unwrapping
//
// Upstream `#[func]` bodies use `?` on `SourceResult`/`StrResult`/
// `HintedStrResult`. Swift's `Result` is not `throws`, so native function
// bodies in this port are written with `throws` and the `nativeFunc`
// wrapper converts thrown errors back into `SourceResult` failures.

/// Unwrap a `SourceResult`, throwing the diagnostics on failure.
func unwrap<T>(_ result: SourceResult<T>) throws -> T {
    switch result {
    case .success(let value): return value
    case .failure(let diagnostics): throw diagnostics
    }
}

/// Unwrap a `StrResult`, throwing the error string on failure.
func unwrap<T>(_ result: StrResult<T>) throws -> T {
    switch result {
    case .success(let value): return value
    case .failure(let error): throw error
    }
}

/// Unwrap a `HintedStrResult`, throwing the hinted error on failure.
func unwrap<T>(_ result: HintedStrResult<T>) throws -> T {
    switch result {
    case .success(let value): return value
    case .failure(let error): throw error
    }
}

// MARK: - Throwing Args consumption

extension Args {
    /// `eat` that throws on cast failure.
    public mutating func eatT<T: FromValue>() throws -> T? {
        try unwrap(self.eat())
    }

    /// `consume` that throws on failure.
    public mutating func consumeT(_ n: Int) throws -> [Arg] {
        try unwrap(self.consume(n))
    }

    /// `expect` that throws on failure.
    public mutating func expectT<T: FromValue>(_ what: String) throws -> T {
        try unwrap(self.expect(what))
    }

    /// `find` that throws on failure.
    public mutating func findT<T: FromValue>() throws -> T? {
        try unwrap(self.find())
    }

    /// `all` that throws on failure.
    public mutating func allT<T: FromValue>() throws -> [T] {
        try unwrap(self.all())
    }

    /// `named` that throws on failure.
    public mutating func namedT<T: FromValue>(_ name: String) throws -> T? {
        try unwrap(self.named(name))
    }

    /// `namedOrFind` that throws on failure.
    public mutating func namedOrFindT<T: FromValue>(_ name: String) throws -> T? {
        try unwrap(self.namedOrFind(name))
    }

    /// `finish` that throws on leftover arguments.
    public func finishT() throws {
        try unwrap(self.finish())
    }

    /// `field` that throws the bare error.
    public func fieldT(_ field: String) throws -> Value {
        try unwrap(self.field(field))
    }
}

// MARK: - Error helpers
//
// Upstream `bail!(span, "...")` / `bail!("...")` inside `#[func]` bodies.

/// A `SourceDiagnostics` error at a span (upstream `bail!(span, msg)`).
func bailSpan(_ span: Span, _ message: String) -> SourceDiagnostics {
    SourceDiagnostics(SourceDiagnostic.error(span, message))
}

/// A `SourceDiagnostics` error at a span with hints.
func bailSpan(_ span: Span, _ message: String, hints: [String]) -> SourceDiagnostics {
    var diagnostic = SourceDiagnostic.error(span, message)
    for hint in hints { diagnostic.hint(hint) }
    return SourceDiagnostics(diagnostic)
}

/// A `HintedString` error (upstream `bail!("...")` / `HintedString`).
func bailHint(_ message: String) -> HintedString { HintedString(message) }

/// A `HintedString` error with hints.
func bailHint(_ message: String, hints: [String]) -> HintedString {
    HintedString(message: message, hints: hints)
}

/// Convert a thrown error into a `SourceResult` failure at the call span.
func sourceFailure<T>(_ error: any Error, span: Span) -> SourceResult<T> {
    if let diagnostics = error as? SourceDiagnostics {
        return .failure(diagnostics)
    }
    if let hinted = error as? HintedString {
        var diagnostic = SourceDiagnostic.error(span, hinted.message)
        for hint in hinted.hints { diagnostic.hint(hint) }
        return .failure(SourceDiagnostics(diagnostic))
    }
    if let str = error as? StrError {
        return .failure(SourceDiagnostics(SourceDiagnostic.error(span, str.message)))
    }
    return .failure(SourceDiagnostics(
        SourceDiagnostic.error(span, "\(error)")
    ))
}

// MARK: - Native function builder

/// Build `NativeFuncData` from a throwing Swift body.
///
/// Convenience for functions returning a specific `IntoValue` type.
func nativeFunc<T: IntoValue & Castable>(
    _ name: String,
    title: String? = nil,
    since: Since? = nil,
    docs: String = "",
    keywords: [String] = [],
    contextual: Bool = false,
    params: [NativeParamInfo] = [],
    returns: CastInfo? = nil,
    scope: @escaping @Sendable () -> Scope = { Scope() },
    function body: @escaping @Sendable (inout Engine, Context, inout Args) throws -> T
) -> NativeFuncData {
    let resolvedReturns = returns ?? T.output
    return NativeFuncData(
        name: name,
        title: title,
        since: since,
        docs: docs,
        keywords: keywords,
        contextual: contextual,
        function: { engine, context, args in
            do {
                return .success(try body(&engine, context, &args).intoValue())
            } catch {
                return sourceFailure(error, span: args.span)
            }
        },
        scope: scope,
        params: { params },
        returns: { resolvedReturns }
    )
}
