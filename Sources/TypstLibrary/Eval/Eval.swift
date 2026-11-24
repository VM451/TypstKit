import Foundation
import TypstSyntax
import TypstUtils

// MARK: - Evaluation entry points (stubs)
//
// The full `typst-eval` port lands across `EvalCode.swift`,
// `EvalCall.swift`, `EvalMarkup.swift`, `EvalMath.swift`,
// `EvalBinding.swift`, `EvalImport.swift`, `EvalRules.swift`,
// `EvalOps.swift`, and `EvalFlow.swift`. Until then, evaluation throws.

extension Expr {
    /// Evaluate the expression. Port of `Eval for ast::Expr`.
    public func eval(_ vm: inout Vm) throws -> Value {
        throw SourceDiagnostics(SourceDiagnostic.error(
            span, "evaluation is not yet implemented"))
    }
}

extension TypstSyntax.Args {
    /// Evaluate the argument list into library `Args`.
    /// Port of `Args::eval` in `call.rs`.
    public func eval(_ vm: inout Vm) throws -> TypstLibrary.Args {
        throw SourceDiagnostics(SourceDiagnostic.error(
            span, "evaluation is not yet implemented"))
    }
}

extension TypstSyntax.FuncCall {
    /// Evaluate the function call. Port of `FuncCall::eval` in `call.rs`.
    public func eval(_ vm: inout Vm) throws -> Value {
        throw SourceDiagnostics(SourceDiagnostic.error(
            span, "evaluation is not yet implemented"))
    }
}
