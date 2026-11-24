import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/ops.rs` — unary/binary operators and
// assignment operations.

extension TypstSyntax.Unary {
    /// Evaluate the unary operation. Port of `Unary::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let expr = self.expr()
        let value: Value
        do {
            value = try expr.eval(&vm)
        } catch {
            if let err = overflowingIntNegationError(self, expr: expr) {
                throw err
            }
            throw error
        }
        let result: HintedStrResult<Value>
        switch op() {
        case .pos: result = ops_pos(value)
        case .neg: result = ops_neg(value)
        case .not: result = ops_not(value)
        }
        return try unwrap(result.at(span))
    }
}

extension TypstSyntax.Binary {
    /// Evaluate the binary operation. Port of `Binary::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        switch op() {
        case .add: return try applyBinary(self, &vm, ops_add)
        case .sub: return try applyBinary(self, &vm, ops_sub)
        case .mul: return try applyBinary(self, &vm, ops_mul)
        case .div: return try applyBinary(self, &vm, ops_div)
        case .and: return try applyBinary(self, &vm, ops_and)
        case .or: return try applyBinary(self, &vm, ops_or)
        case .eq: return try applyBinary(self, &vm, ops_eq)
        case .neq: return try applyBinary(self, &vm, ops_neq)
        case .lt: return try applyBinary(self, &vm, ops_lt)
        case .leq: return try applyBinary(self, &vm, ops_leq)
        case .gt: return try applyBinary(self, &vm, ops_gt)
        case .geq: return try applyBinary(self, &vm, ops_geq)
        case .in:
            return try applyBinaryWith(self, &vm) { guard_, a, b in
                ops_in(guard_, a, b, negate: false)
            }
        case .notIn:
            return try applyBinaryWith(self, &vm) { guard_, a, b in
                ops_in(guard_, a, b, negate: true)
            }
        case .assign:
            return try applyAssignment(self, &vm) { _, b in .success(b) }
        case .addAssign:
            return try applyAssignment(self, &vm, ops_add)
        case .subAssign:
            return try applyAssignment(self, &vm, ops_sub)
        case .mulAssign:
            return try applyAssignment(self, &vm, ops_mul)
        case .divAssign:
            return try applyAssignment(self, &vm, ops_div)
        }
    }
}

/// Apply a basic binary operation.
private func applyBinary(
    _ binary: TypstSyntax.Binary, _ vm: inout Vm,
    _ op: (Value, Value) -> HintedStrResult<Value>
) throws -> Value {
    let lhs = try binary.lhs().eval(&vm)

    // Short-circuit boolean operations.
    if (binary.op() == .and && lhs == .bool(false))
        || (binary.op() == .or && lhs == .bool(true)) {
        return lhs
    }

    let rhs = try binary.rhs().eval(&vm)
    return try unwrap(op(lhs, rhs).at(binary.span))
}

/// Apply a basic binary operation with a `BindingGuard`.
private func applyBinaryWith(
    _ binary: TypstSyntax.Binary, _ vm: inout Vm,
    _ op: (NormalBindingGuard, Value, Value) -> HintedStrResult<Value>
) throws -> Value {
    let lhs = try binary.lhs().eval(&vm)
    let rhs = try binary.rhs().eval(&vm)
    return try unwrap(op(vm.engine.bindingGuard(), lhs, rhs)
        .at(binary.span))
}

/// Apply an assignment operation.
private func applyAssignment(
    _ binary: TypstSyntax.Binary, _ vm: inout Vm,
    _ op: (Value, Value) -> HintedStrResult<Value>
) throws -> Value {
    let rhs = try binary.rhs().eval(&vm)
    let lhsExpr = binary.lhs()

    // An assignment to a dictionary field is different from a normal access
    // since it can create the field instead of just modifying it.
    if binary.op() == .assign,
       case let .fieldAccess(fieldAccess) = lhsExpr {
        // `access_dict` + insert — port of the dict-assign shortcut.
        let target = try fieldAccess.target().eval(&vm)
        let field = fieldAccess.field()
        guard case .dict(var dict) = target else {
            throw dictFieldAssignError(target: target,
                                       span: fieldAccess.target().span)
        }
        dict.insert(field.get(), rhs)
        // Write the dict back through the target's lvalue.
        let parent = try access(fieldAccess.target(), &vm)
        try parent.write(&vm, .dict(dict))
        return .none
    }

    let location = try access(lhsExpr, &vm)
    let lhsValue = try location.read(&vm)
    let newValue = try unwrap(op(lhsValue, rhs).at(binary.span))
    try location.write(&vm, newValue)
    return .none
}

/// Error for `dict.field = v` where the target isn't a dict — mirrors
/// `access_dict`'s non-dict arm but for the assign shortcut.
private func dictFieldAssignError(target: Value, span: Span) -> any Error {
    let ty = target.type
    switch target {
    case .symbol, .content, .module, .function, .arguments:
        return SourceDiagnostics(SourceDiagnostic.error(
            span, "cannot mutate fields on \(ty)"))
    default:
        if fieldsOn(ty).isEmpty {
            return SourceDiagnostics(SourceDiagnostic.error(
                span, "\(ty) does not have accessible fields"))
        }
        var diagnostic = SourceDiagnostic.error(
            span, "fields on \(ty) are not yet mutable")
        diagnostic.hint("try creating a new \(ty) with the updated field value instead")
        return SourceDiagnostics(diagnostic)
    }
}

/// Error for an overflowing positive integer that was negated.
/// Port of `overflowing_int_negation_error`.
private func overflowingIntNegationError(
    _ unary: TypstSyntax.Unary, expr: Expr
) -> (any Error)? {
    guard unary.op() == .neg,
          case let .int(int) = expr,
          case let .failure(literalError) = int.get(),
          case .posOverflow(let base, let maxPlusOne) = literalError
    else { return nil }

    if maxPlusOne {
        var diagnostic = SourceDiagnostic.error(
            unary.span, "cannot write minimum integer manually")
        diagnostic.hint("Typst integers are always initially positive")
        diagnostic.hint("2^63 does not fit into a signed 64-bit integer")
        diagnostic.hint("try writing `int.min`")
        return SourceDiagnostics(diagnostic)
    } else {
        var diagnostic = SourceDiagnostic.error(
            unary.span, "integer value is too small")
        diagnostic.hint("value does not fit into a signed 64-bit integer")
        if base == nil {
            diagnostic.hint(
                "a floating point number could approximately represent this value")
            diagnostic.hint(
                "you can use a floating point number by appending a dot: `\(expr.node.leafText).`")
        }
        return SourceDiagnostics(diagnostic)
    }
}
