import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/flow.rs` — conditionals, loops, and the
// break/continue/return flow events (FlowEvent itself lives in
// EvalCore.swift).

/// The maximum number of loop iterations.
private let maxIterations = 10_000

extension FlowEvent {
    /// The span of the event.
    public var span: Span {
        switch self {
        case let .break(span), let .continue(span), let .return(span, _, _):
            return span
        }
    }
}

/// Set the conditional flag on a pending return event.
/// Port of the "mark the return as conditional" blocks in flow.rs.
func markReturnConditional(_ vm: inout Vm) {
    guard case let .return(span, value, _)? = vm.flow else { return }
    vm.flow = .return(span, value, true)
}

/// Whether a pattern is a plain binding (normal or placeholder), which
/// upstream allows for string/bytes iteration.
private func isSimplePattern(_ pattern: Pattern) -> Bool {
    switch pattern {
    case .normal, .placeholder: return true
    default: return false
    }
}

extension TypstSyntax.Conditional {
    /// Evaluate the conditional. Port of `Conditional::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let condition = self.condition()
        let output: Value
        if try unwrap(Bool.fromValue(try condition.eval(&vm))
            .at(condition.span)) {
            output = try ifBody().eval(&vm)
        } else if let elseBody = elseBody() {
            output = try elseBody.eval(&vm)
        } else {
            output = .none
        }

        markReturnConditional(&vm)
        return output
    }
}

extension TypstSyntax.WhileLoop {
    /// Evaluate the while loop. Port of `WhileLoop::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let outerFlow = vm.flow
        vm.flow = nil
        var output = Value.none
        var i = 0

        let condition = self.condition()
        let body = self.body()

        loop: while try unwrap(Bool.fromValue(try condition.eval(&vm))
            .at(condition.span)) {
            if i == 0 && isInvariant(condition.node)
                && !canDiverge(body.node) {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    condition.span, "condition is always true"))
            } else if i >= maxIterations {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    span, "loop seems to be infinite"))
            }

            let value = try body.eval(&vm)
            output = try unwrap(ops_join(output, value).at(body.span))

            switch vm.flow {
            case .break?:
                vm.flow = nil
                break loop
            case .continue?:
                vm.flow = nil
            case .return?:
                break loop
            case nil:
                break
            }

            i += 1
        }

        if outerFlow != nil { vm.flow = outerFlow }
        markReturnConditional(&vm)
        return output
    }
}

extension TypstSyntax.ForLoop {
    /// Evaluate the for loop. Port of `ForLoop::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let outerFlow = vm.flow
        vm.flow = nil
        var output = Value.none

        let pattern = self.pattern()
        let iterableExpr = self.iterable()
        let iterable = try iterableExpr.eval(&vm)
        let iterableType = iterable.type

        // Materialize the iterable (upstream iterates lazily; Swift
        // collections are eager value types).
        var items: [Value] = []
        switch iterable {
        case .array(let array):
            items = array.items
        case .dict(let dict):
            items = dict.pairs.map { pair in
                .array(ArrayValue(items: [.str(pair.key), pair.value]))
            }
        case .str(let str) where isSimplePattern(pattern):
            // Grapheme clusters — Swift `Character` is the extended
            // grapheme cluster, matching `unicode_segmentation`.
            items = str.value.map { .str(Str(String($0))) }
        case .bytes(let bytes) where isSimplePattern(pattern):
            items = bytes.storage.map { .int(Int64($0)) }
        case .str, .bytes:
            throw SourceDiagnostics(SourceDiagnostic.error(
                pattern.span, "cannot destructure values of \(iterableType)"))
        default:
            throw SourceDiagnostics(SourceDiagnostic.error(
                iterableExpr.span, "cannot loop over \(iterableType)"))
        }

        vm.scopes.enter()
        defer { vm.scopes.exit() }

        let body = self.body()
        loop: for value in items {
            try destructure(&vm, pattern: pattern, value: value)

            let bodyValue = try body.eval(&vm)
            output = try unwrap(ops_join(output, bodyValue).at(body.span))

            switch vm.flow {
            case .break?:
                vm.flow = nil
                break loop
            case .continue?:
                vm.flow = nil
            case .return?:
                break loop
            case nil:
                break
            }
        }

        if outerFlow != nil { vm.flow = outerFlow }
        markReturnConditional(&vm)
        return output
    }
}

extension TypstSyntax.LoopBreak {
    /// Evaluate `break`. Port of `LoopBreak::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        if vm.flow == nil {
            vm.flow = .break(span)
        }
        return .none
    }
}

extension TypstSyntax.LoopContinue {
    /// Evaluate `continue`. Port of `LoopContinue::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        if vm.flow == nil {
            vm.flow = .continue(span)
        }
        return .none
    }
}

extension TypstSyntax.FuncReturn {
    /// Evaluate `return`. Port of `FuncReturn::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let value = try body().map { try $0.eval(&vm) }
        if vm.flow == nil {
            vm.flow = .return(span, value, false)
        }
        return .none
    }
}

/// Whether the expression always evaluates to the same value.
/// Port of `is_invariant` — operates on the untyped syntax node.
func isInvariant(_ node: SyntaxNode) -> Bool {
    if let expr = node.cast(Expr.self) {
        switch expr {
        case .ident, .mathIdent:
            return false
        case .fieldAccess(let access):
            return isInvariant(access.target().node)
        case .funcCall(let call):
            return isInvariant(call.callee().node)
                && isInvariant(call.args().node)
        default:
            break
        }
    }
    return node.children.allSatisfy(isInvariant)
}

/// Whether the expression contains a break or return.
/// Port of `can_diverge`.
func canDiverge(_ node: SyntaxNode) -> Bool {
    if node.kind == .loopBreak || node.kind == .funcReturn {
        return true
    }
    return node.children.contains { canDiverge($0) }
}
