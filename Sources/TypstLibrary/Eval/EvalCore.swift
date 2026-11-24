import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/vm.rs`, `flow.rs` (FlowEvent), `access.rs`,
// and `methods.rs`. Rust's `&mut Value` lvalue model is expressed as
// `LValue`, a path resolved against the scope stack with read/write-back.

/// A virtual machine.
///
/// Port of `Vm` in `vm.rs`.
public struct Vm {
    /// The underlying virtual typesetter.
    public var engine: Engine
    /// A control flow event that is currently happening.
    public var flow: FlowEvent?
    /// The stack of scopes.
    public var scopes: Scopes
    /// A span currently under inspection (tracing mode).
    public var inspected: Span?
    /// Contextual data.
    public var context: Context

    public init(engine: Engine, context: Context, scopes: Scopes,
                inspected: Span?) {
        self.engine = engine
        self.context = context
        self.flow = nil
        self.scopes = scopes
        self.inspected = inspected
    }

    /// Bind a value to an identifier (creates a `Binding` with the
    /// identifier's span).
    public mutating func define(_ ident: TypstSyntax.Ident, _ value: Value) {
        bind(ident, Binding(value: value, span: ident.span))
    }

    /// Insert a binding into the current (top) scope.
    public mutating func bind(_ ident: TypstSyntax.Ident, _ binding: Binding) {
        let name = ident.get()
        if let value = try? scopes.get(name, guard: SilentBindingGuard(
            features: engine.world.library.value.features)).get() {
            traceAt(ident.span, value)
        }

        // This will become an error in the parser if `is` becomes a
        // keyword (upstream warning).
        if name == "is" {
            var diagnostic = SourceDiagnostic.warning(
                ident.span,
                "`is` will likely become a keyword in future versions and will not be allowed as an identifier")
            diagnostic.hint("rename this variable to avoid future errors")
            diagnostic.hint("try `is_` instead")
            engine.sink.warn(diagnostic)
        }

        scopes.top.bind(name, binding: binding)
    }

    /// Call `trace` for a value only if we're inspecting its span.
    public mutating func traceAt(_ span: Span, _ value: Value) {
        if inspected == span { trace(span, value) }
    }

    /// Trace a value (IDE tooltips/hover).
    public mutating func trace(_ span: Span, _ value: Value) {
        engine.traced.push(EvalTracepoint(span: span, value: value))
    }
}

/// Provide a hint if the callee is a shadowed standard library function.
/// Port of `hint_if_shadowed_std` in `vm.rs`.
func hintIfShadowedStd(_ vm: Vm, _ callee: Expr,
                       _ err: HintedString) -> HintedString {
    guard case let .ident(ident) = callee else { return err }
    let name = ident.get()
    if vm.scopes.checkStdShadowed(name) {
        return err.withHint("use `std.\(name)` to access the shadowed standard library function")
    }
    return err
}

/// A control flow event that occurred during evaluation.
/// Port of `FlowEvent` in `flow.rs`.
public enum FlowEvent: Sendable {
    /// Stop iteration in a loop.
    case `break`(Span)
    /// Skip the remainder of the current iteration.
    case `continue`(Span)
    /// Stop execution of a function early, optionally returning a value.
    /// The final flag marks a conditional return.
    case `return`(Span, Value?, Bool)

    /// An error stating that this control flow is forbidden.
    public func forbidden() -> SourceDiagnostics {
        switch self {
        case let .break(span):
            return SourceDiagnostics(SourceDiagnostic.error(
                span, "cannot break outside of loop"))
        case let .continue(span):
            return SourceDiagnostics(SourceDiagnostic.error(
                span, "cannot continue outside of loop"))
        case let .return(span, _, _):
            return SourceDiagnostics(SourceDiagnostic.error(
                span, "cannot return outside of function"))
        }
    }
}

// MARK: - Binding guards

/// A [`BindingGuard`] that emits warnings to the engine's sink.
/// Port of `NormalBindingGuard` in `scope.rs`.
public struct NormalBindingGuard: BindingGuard {
    public let features: Features
    public init(features: Features) { self.features = features }
}

extension Engine {
    /// Create a struct implementing `BindingGuard`.
    /// Port of `Engine::binding_guard`.
    public func bindingGuard() -> NormalBindingGuard {
        NormalBindingGuard(features: library.features)
    }
}

extension World {
    /// A silent binding guard built from the world's library features.
    /// Port of `WorldBindingExt::silent_binding_guard`.
    public func silentBindingGuard() -> SilentBindingGuard {
        SilentBindingGuard(features: library.value.features)
    }
}

// MARK: - LValue (mutable access paths)

/// A mutable access path into evaluated state — the Swift analogue of
/// upstream's `&mut Value` returned by `Access::access`.
public indirect enum LValue {
    /// A scope variable (`ident`).
    case variable(String, Span)
    /// A dictionary field (`dict.field`); `span` is the field-access
    /// expression span (for `at_mut` errors), `targetSpan` the target's
    /// span (for `access_dict` errors).
    case dictField(LValue, String, Span, Span)
    /// An accessor-method slot (`arr.first()`, `arr.at(i)`,
    /// `dict.at(k)`); `args` are already evaluated and spanned.
    case methodSlot(LValue, String, Args, Span)
}

extension LValue {
    /// Read the current value at this path.
    public func read(_ vm: inout Vm) throws -> Value {
        switch self {
        case let .variable(name, span):
            return try unwrap(vm.scopes.get(name, guard: vm.engine
                .bindingGuard()).at(span))
        case let .dictField(parent, key, span, _):
            let value = try parent.read(&vm)
            guard case .dict(let dict) = value else {
                throw dictAccessError(parent: parent, vm: &vm)
            }
            return try unwrap(dict.at(key).at(span))
        case let .methodSlot(parent, method, args, span):
            var value = try parent.read(&vm)
            return try readMethodSlot(&value, method: method, args: args,
                                      span: span)
        }
    }

    /// Write `newValue` at this path.
    public func write(_ vm: inout Vm, _ newValue: Value) throws {
        switch self {
        case let .variable(name, span):
            _ = try unwrap(vm.scopes.getMut(name, span: span,
                guard: vm.engine.bindingGuard()) { $0 = newValue })
        case let .dictField(parent, key, span, targetSpan):
            var parentValue = try parent.read(&vm)
            guard case .dict(var dict) = parentValue else {
                throw dictAccessErrorAt(parent: parent, vm: &vm,
                                        span: targetSpan)
            }
            guard dict.contains(key) else {
                throw StrError("dictionary does not contain key \(Str(key).repr())")
                    .atDiagnostics(span)
            }
            dict.update(key) { $0 = newValue }
            parentValue = .dict(dict)
            try parent.write(&vm, parentValue)
        case let .methodSlot(parent, method, args, span):
            var parentValue = try parent.read(&vm)
            try writeMethodSlot(&parentValue, method: method, args: args,
                                span: span) { $0 = newValue }
            try parent.write(&vm, parentValue)
        }
    }

    /// Mutate the value at this path in place.
    public func mutate<T>(_ vm: inout Vm,
                          _ body: (inout Value) throws -> T) throws -> T {
        switch self {
        case let .variable(name, span):
            return try unwrap(vm.scopes.getMut(name, span: span,
                guard: vm.engine.bindingGuard(), body))
        case let .dictField(parent, key, span, targetSpan):
            var parentValue = try parent.read(&vm)
            guard case .dict(var dict) = parentValue else {
                throw dictAccessErrorAt(parent: parent, vm: &vm,
                                        span: targetSpan)
            }
            guard dict.contains(key) else {
                throw StrError("dictionary does not contain key \(Str(key).repr())")
                    .atDiagnostics(span)
            }
            var thrown: (any Error)?
            var result: T?
            dict.update(key) { slot in
                do { result = try body(&slot) }
                catch { thrown = error }
            }
            if let thrown { throw thrown }
            parentValue = .dict(dict)
            try parent.write(&vm, parentValue)
            return result!
        case let .methodSlot(parent, method, args, span):
            var parentValue = try parent.read(&vm)
            let result = try mutateMethodSlot(&parentValue, method: method,
                                              args: args, span: span, body)
            try parent.write(&vm, parentValue)
            return result
        }
    }
}

/// The `access_dict` error for a non-dict parent value.
/// Port of `access_dict` in `access.rs` — errors are spanned at the
/// field-access *target*.
private func dictAccessErrorAt(parent: LValue, vm: inout Vm,
                               span: Span) -> any Error {
    guard let value = try? parent.read(&vm) else {
        return HintedString("cannot mutate a temporary value")
    }
    let ty = value.type
    switch value {
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

private func dictAccessError(parent: LValue, vm: inout Vm) -> any Error {
    dictAccessErrorAt(parent: parent, vm: &vm, span: Span.detached)
}

/// Which collection slot an accessor method addresses.
private enum MethodSlot {
    case arrayIndex(Int)
    case dictIndex(Int)
}

/// Resolve the accessor-method slot inside `value` (array index or dict
/// position) for `method`, consuming `args`. Port of the slot selection
/// in `call_method_access` in `methods.rs`.
private func resolveMethodSlot(_ value: inout Value, method: String,
                               args: inout Args, span: Span) throws -> MethodSlot {
    switch value {
    case .array(var array):
        let index: Int
        switch method {
        case "first": index = try unwrap(array.firstMutIndex().at(span))
        case "last": index = try unwrap(array.lastMutIndex().at(span))
        case "at":
            let i: Int64 = try unwrap(args.expect("index"))
            index = try unwrap(array.atMutIndex(i).at(span))
        default:
            throw callMethodAccessMissing(value.type, method, span)
        }
        return .arrayIndex(index)
    case .dict(let dict):
        guard method == "at" else {
            throw callMethodAccessMissing(value.type, method, span)
        }
        let key: Str = try unwrap(args.expect("key"))
        guard let index = dict.position(of: key.value) else {
            throw StrError("dictionary does not contain key \(key.repr())")
                .atDiagnostics(span)
        }
        return .dictIndex(index)
    default:
        throw callMethodAccessMissing(value.type, method, span)
    }
}

/// Read an accessor-method slot (`first`/`last`/`at`) out of a value.
/// Port of `call_method_access` in `methods.rs` (read side).
private func readMethodSlot(_ value: inout Value, method: String,
                            args: Args, span: Span) throws -> Value {
    var args = args
    let slot = try resolveMethodSlot(&value, method: method,
                                     args: &args, span: span)
    try unwrap(args.finish())
    switch (value, slot) {
    case (.array(let array), .arrayIndex(let index)):
        return array.items[index]
    case (.dict(let dict), .dictIndex(let index)):
        return dict.values[index]
    default:
        fatalError("unreachable")
    }
}

/// Write through an accessor-method slot.
private func writeMethodSlot(_ value: inout Value, method: String,
                             args: Args, span: Span,
                             _ body: (inout Value) throws -> Void) throws {
    var args = args
    let slot = try resolveMethodSlot(&value, method: method,
                                     args: &args, span: span)
    try unwrap(args.finish())
    switch (value, slot) {
    case (.array(var array), .arrayIndex(let index)):
        try body(&array.items[index])
        value = .array(array)
    case (.dict(var dict), .dictIndex(let index)):
        let key = dict.keys[index].value
        var thrown: (any Error)?
        dict.update(key) { v in
            do { try body(&v) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        value = .dict(dict)
    default:
        fatalError("unreachable")
    }
}

/// Mutate through an accessor-method slot, returning the body's result.
private func mutateMethodSlot<T>(_ value: inout Value, method: String,
                                 args: Args, span: Span,
                                 _ body: (inout Value) throws -> T) throws -> T {
    var args = args
    let slot = try resolveMethodSlot(&value, method: method,
                                     args: &args, span: span)
    try unwrap(args.finish())
    switch (value, slot) {
    case (.array(var array), .arrayIndex(let index)):
        let result = try body(&array.items[index])
        value = .array(array)
        return result
    case (.dict(var dict), .dictIndex(let index)):
        let key = dict.keys[index].value
        var thrown: (any Error)?
        var result: T?
        dict.update(key) { v in
            do { result = try body(&v) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        value = .dict(dict)
        return result!
    default:
        fatalError("unreachable")
    }
}

/// The `temp_or_missing` error for `call_method_access`.
private func callMethodAccessMissing(_ ty: Type, _ method: String,
                                     _ span: Span) -> SourceDiagnostics {
    if ty.scope().get(method) != nil {
        return SourceDiagnostics(SourceDiagnostic.error(
            span, "cannot mutate a temporary value"))
    }
    return SourceDiagnostics(SourceDiagnostic.error(
        span, missingMethodMessage(ty, method)))
}

/// `type {ty} has no method `{method}``.
func missingMethodMessage(_ ty: Type, _ method: String) -> String {
    "type \(ty) has no method `\(method)`"
}

// MARK: - Access (lvalue resolution)

/// Resolve an expression to a mutable access path.
/// Port of `Access for ast::Expr` in `access.rs`.
func access(_ expr: Expr, _ vm: inout Vm) throws -> LValue {
    switch expr {
    case .ident(let ident):
        return try accessIdent(ident, &vm)
    case .parenthesized(let p):
        return try access(p.expr(), &vm)
    case .fieldAccess(let fieldAccess):
        return try accessFieldAccess(fieldAccess, &vm)
    case .funcCall(let call):
        return try accessFuncCall(call, &vm)
    default:
        _ = try expr.eval(&vm)
        throw SourceDiagnostics(SourceDiagnostic.error(
            expr.span, "cannot mutate a temporary value"))
    }
}

func accessIdent(_ ident: TypstSyntax.Ident, _ vm: inout Vm) throws -> LValue {
    let span = ident.span
    let name = ident.get()
    if vm.inspected == span,
       let value = try? vm.scopes.get(name, guard: vm.engine.world
           .silentBindingGuard()).get() {
        vm.trace(span, value)
    }
    return .variable(name, span)
}

func accessFieldAccess(_ fieldAccess: TypstSyntax.FieldAccess,
                       _ vm: inout Vm) throws -> LValue {
    // `dict.field` — the target must evaluate to a dict (checked lazily
    // in LValue, matching upstream's `access_dict` error at target span).
    let target = fieldAccess.target()
    let parent = try access(target, &vm)
    return .dictField(parent, fieldAccess.field().get(),
                      fieldAccess.span, target.span)
}

func accessFuncCall(_ call: TypstSyntax.FuncCall,
                    _ vm: inout Vm) throws -> LValue {
    if case let .fieldAccess(fieldAccess) = call.callee(),
       isAccessorMethod(fieldAccess.field().get()) {
        let method = fieldAccess.field()
        let span = call.span
        var args = try call.args().eval(&vm)
        args = args.spanned(span)
        let parent = try access(fieldAccess.target(), &vm)
        return .methodSlot(parent, method.get(), args, span)
    }
    _ = try call.eval(&vm)
    throw SourceDiagnostics(SourceDiagnostic.error(
        call.span, "cannot mutate a temporary value"))
}

/// Whether a specific method is mutating.
func isMutatingMethod(_ method: String) -> Bool {
    ["push", "pop", "insert", "remove"].contains(method)
}

/// Whether a method is dict-mutating only.
func isDictMutatingMethod(_ method: String) -> Bool {
    ["insert", "remove"].contains(method)
}

/// Whether a specific method is an accessor (returns a mutable slot).
func isAccessorMethod(_ method: String) -> Bool {
    ["first", "last", "at"].contains(method)
}

/// Call a mutating method on the value at `lvalue`.
/// Port of `call_method_mut` in `methods.rs`.
func callMethodMut(_ lvalue: LValue, _ method: String, _ args: Args,
                   _ vm: inout Vm, span: Span) throws -> Value {
    var output = Value.none
    var args = args
    try lvalue.mutate(&vm) { value in
        let ty = value.type
        switch value {
        case .array(var array):
            switch method {
            case "push":
                let v: Value = try unwrap(args.expect("value"))
                array.push(v)
            case "pop":
                output = try unwrap(array.pop().at(span))
            case "insert":
                let i: Int64 = try unwrap(args.expect("index"))
                let v: Value = try unwrap(args.expect("value"))
                try unwrap(array.insert(i, v).at(span))
            case "remove":
                let i: Int64 = try unwrap(args.expect("index"))
                let d: Value? = try unwrap(args.named("default"))
                output = try unwrap(array.removeDefault(i, default: d)
                    .at(span))
            default:
                throw missingMethod(ty, method, span)
            }
            value = .array(array)
        case .dict(var dict):
            switch method {
            case "insert":
                let k: Str = try unwrap(args.expect("key"))
                let v: Value = try unwrap(args.expect("value"))
                dict.insert(k, v)
            case "remove":
                let k: Str = try unwrap(args.expect("key"))
                let d: Value? = try unwrap(args.named("default"))
                output = try unwrap(dict.remove(k, default: d).at(span))
            default:
                throw missingMethod(ty, method, span)
            }
            value = .dict(dict)
        default:
            throw missingMethod(ty, method, span)
        }
        try unwrap(args.finish())
    }
    return output
}

/// The `missing` error for `call_method_mut`.
private func missingMethod(_ ty: Type, _ method: String,
                           _ span: Span) -> SourceDiagnostics {
    SourceDiagnostics(SourceDiagnostic.error(
        span, missingMethodMessage(ty, method)))
}

/// `array.remove(index, default:)` — upstream `Array::remove` takes an
/// optional default for out-of-bounds indices.
extension ArrayValue {
    func removeDefault(_ index: Int64, default defaultValue: Value?) -> StrResult<Value> {
        guard index >= 0, index < Int64(items.count) else {
            if let defaultValue { return .success(defaultValue) }
            return .failure(StrError("array index out of bounds (index: \(index), len: \(items.count))"))
        }
        var copy = self
        return copy.remove(index)
    }
}
