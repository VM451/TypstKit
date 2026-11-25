import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/call.rs` — function calls, argument evaluation,
// closures, `eval_closure`, and the `CapturesVisitor`.
// `MathCall`/`MathArgs`/`unparse_math_args` land with EvalMath.swift.

// MARK: - FuncCall

extension TypstSyntax.FuncCall {
    /// Evaluate the function call. Port of `FuncCall::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let span = self.span
        let callee = self.callee()

        try unwrap(vm.engine.route.checkCallDepth().at(span))

        // Try to evaluate as a call to an associated function or field.
        if case let .fieldAccess(access) = callee {
            let targetExpr = access.target()
            let field = access.field()
            let fieldName = field.get()

            var target: Value
            var maybeArgs: TypstLibrary.Args? = nil
            if isMutatingMethod(fieldName) {
                switch try maybeResolveMutating(
                    &vm, target: targetExpr, field: field,
                    args: args(), span: span) {
                case let .resolved(value):
                    return value
                case let .pending(t, a):
                    target = t
                    maybeArgs = a
                }
            } else {
                target = try targetExpr.eval(&vm)
            }

            switch try evalFieldCallee(
                &vm, access: access.node, field: fieldName,
                fieldSpan: field.span, target: target, inMath: false) {
            case let .function(theFunc):
                let callArgs = try evalCallArgs(&vm, maybeArgs: maybeArgs,
                                                 call: self, span: span)
                return try callFunc(&vm, theFunc, callArgs, span)
            case let .method(theFunc, methodTarget):
                var callArgs = try evalCallArgs(&vm, maybeArgs: maybeArgs,
                                                 call: self, span: span)
                // Method calls pass the target as the first argument.
                callArgs.insert(index: 0, span: targetExpr.span,
                                value: methodTarget)
                return try callFunc(&vm, theFunc, callArgs, span)
            case let .nonFunc(_, err):
                throw SourceDiagnostics(err.intoErrorAt(callee.span))
            }
        } else {
            // Function call order: we evaluate the callee before the
            // arguments.
            let funcValue = try callee.eval(&vm)
            let theFunc = try unwrap(funcValue
                .cast(Func.self)
                .mapError { hintIfShadowedStd(vm, callee, $0) }
                .at(callee.span))
            let callArgs = try args().eval(&vm).spanned(span)
            return try callFunc(&vm, theFunc, callArgs, span)
        }
    }
}

/// Call a function.
/// Port of `call_func` in `call.rs` (the `stacker::maybe_grow` wrapper is
/// unnecessary — Swift grows the native stack dynamically).
func callFunc(_ vm: inout Vm, _ theFunc: Func, _ args: TypstLibrary.Args,
                      _ span: Span) throws -> Value {
    let spanned = theFunc.spanned(span)
    return try unwrap(spanned.callValue(
        engine: &vm.engine, context: vm.context, args: args, span: span))
}

/// The result of attempting to resolve a mutating method call.
private enum MutatingResolution {
    /// The mutating method was called; this is the result.
    case resolved(Value)
    /// Not actually mutating — continue as a normal call with the
    /// evaluated target and arguments.
    case pending(Value, TypstLibrary.Args)
}

/// Attempt to resolve a mutating method call by evaluating args and then
/// attempting to access the target mutably.
/// Port of `maybe_resolve_mutating` in `call.rs`.
private func maybeResolveMutating(
    _ vm: inout Vm, target: Expr, field: TypstSyntax.Ident,
    args argsNode: TypstSyntax.Args, span: Span
) throws -> MutatingResolution {
    // We evaluate the arguments first because `access` mutably borrows the
    // VM's state, so we won't be able to call `args.eval` afterwards.
    var args = try argsNode.eval(&vm)
    args = args.spanned(span)

    let lvalue = try access(target, &vm)
    let targetValue = try lvalue.read(&vm)
    let fieldName = field.get()

    // Skip methods that aren't actually mutating for dictionaries.
    if case .dict = targetValue, !isDictMutatingMethod(fieldName) {
        return .pending(targetValue, args)
    }

    // Only arrays and dictionaries have mutable methods.
    if case .array = targetValue {
        do {
            let value = try callMethodMut(lvalue, fieldName, args, &vm,
                                          span: span)
            return .resolved(value)
        } catch let diagnostics as SourceDiagnostics {
            throw SourceDiagnostics(diagnostics.diagnostics.map {
                $0.traced(.call(fieldName), at: span)
            })
        }
    }
    if case .dict = targetValue {
        do {
            let value = try callMethodMut(lvalue, fieldName, args, &vm,
                                          span: span)
            return .resolved(value)
        } catch let diagnostics as SourceDiagnostics {
            throw SourceDiagnostics(diagnostics.diagnostics.map {
                $0.traced(.call(fieldName), at: span)
            })
        }
    }

    return .pending(targetValue, args)
}

/// Evaluate the call's argument list, or reuse args resolved during
/// mutating-method detection.
private func evalCallArgs(
    _ vm: inout Vm, maybeArgs: TypstLibrary.Args?,
    call: TypstSyntax.FuncCall, span: Span
) throws -> TypstLibrary.Args {
    if let maybeArgs { return maybeArgs }
    return try call.args().eval(&vm).spanned(span)
}

/// The kind of callee in a field-access function call.
/// Port of `FieldCallee` in `call.rs`.
enum FieldCallee {
    /// A method on a type or on content, with the target value to be added
    /// as the first argument of the call.
    case method(Func, Value)
    /// A plain function to call.
    case function(Func)
    /// The field access doesn't actually produce a function. This will
    /// error in code, but not in math.
    case nonFunc(Value, HintedString)
}

/// Evaluate a field-access callee, prioritizing associated functions of the
/// value's type, "methods", over fields on the specific value.
/// Port of `eval_field_callee` in `call.rs`.
func evalFieldCallee(
    _ vm: inout Vm, access: SyntaxNode, field: String, fieldSpan: Span,
    target: Value, inMath: Bool
) throws -> FieldCallee {
    let guard_ = vm.engine.bindingGuard()
    var isMethodCall = false
    let calleeValue: Value

    switch target {
    case .symbol, .type, .module:
        // These types are allowed to use field call syntax on non-methods.
        calleeValue = try unwrap(target.field(field, guard: guard_)
            .at(fieldSpan))
    case .function(let theFunc):
        // Functions can also use field call syntax on non-methods, but not
        // for settable fields accessed from context.
        switch target.field(field, guard: guard_) {
        case .success(let value):
            calleeValue = value
        case .failure(let err):
            if let element = theFunc.element,
               let accessor = element.settableFieldAccessor(field) {
                let styles = try unwrap(vm.context.requireStyles()
                    .at(fieldSpan))
                let value = accessor(styles)
                throw disallowedFieldCallError(
                    calleeValue: value, access: access, field: field,
                    target: target, inMath: inMath)
            }
            throw SourceDiagnostics(err.intoErrorAt(fieldSpan))
        }
    default:
        if let method = target.type.scope().get(field) {
            isMethodCall = true
            let ty = target.type.shortName
            calleeValue = try unwrap(method
                .read(guard_)
                .orCannot("call method `\(field)` on \(ty)")
                .at(fieldSpan))
        } else if case let .content(content) = target,
                  let method = content.elem.scope?.get(field) {
            isMethodCall = true
            calleeValue = try unwrap(method
                .read(guard_)
                .orCannot("call method `\(field)` on content")
                .at(fieldSpan))
        } else {
            // Otherwise we are not allowed to call the field and produce
            // an error.
            switch target.field(field, guard: guard_) {
            // The field does exist.
            case .success(let value):
                throw disallowedFieldCallError(
                    calleeValue: value, access: access, field: field,
                    target: target, inMath: inMath)
            // The field does not exist. We don't try as hard on the error
            // here to avoid assuming the user's intent.
            case .failure:
                let (kind, name) = elementOrTypeWithName(target)
                throw SourceDiagnostics(SourceDiagnostic.error(
                    access.span,
                    "\(kind) \(name) has no method `\(field)`"))
            }
        }
    }

    vm.traceAt(access.span, calleeValue)

    switch calleeValue.cast(Func.self) {
    case .success(let f):
        return isMethodCall ? .method(f, target) : .function(f)
    case .failure(let err):
        return .nonFunc(calleeValue, err)
    }
}

/// Produce an error for calls to fields that do exist, but are not allowed
/// to be called with field-access syntax.
/// Port of `disallowed_field_call_error` in `call.rs`.
func disallowedFieldCallError(
    calleeValue: Value, access: SyntaxNode, field: String,
    target: Value, inMath: Bool
) -> SourceDiagnostics {
    let isDict: Bool
    let isNamed: Bool
    switch target {
    case .dict: isDict = true; isNamed = false
    case .arguments: isDict = false; isNamed = true
    default: isDict = false; isNamed = false
    }

    var error: SourceDiagnostic
    if isDict {
        error = SourceDiagnostic.error(
            access.span, "cannot directly call dictionary keys as functions")
    } else if isNamed {
        error = SourceDiagnostic.error(
            access.span,
            "cannot directly call named argument fields as functions")
    } else {
        let (kind, name) = elementOrTypeWithName(target)
        error = SourceDiagnostic.error(
            access.span, "`\(field)` is not a valid method for \(kind) `\(name)`")
    }

    if case .success = calleeValue.cast(Func.self) {
        error.hint(
            "to call the stored function, "
            + (inMath ? "use code mode and " : "")
            + "wrap the field access in parentheses: `"
            + (inMath ? "#" : "")
            + "(\(access.fullText()))(..)`")
    } else if inMath {
        error.hint("try adding a space before the parentheses")
    } else {
        error.hint(
            "to access the `\(field)` "
            + (isDict ? "key" : isNamed ? "argument" : "field")
            + ", remove the function arguments: `\(access.fullText())`")
    }

    if isDict {
        error.hint(
            "dictionary keys cannot be used with method syntax as keys could conflict "
            + "with built-in method names")
    } else if isNamed {
        error.hint(
            "named arguments cannot be used with method syntax as argument names could "
            + "conflict with built-in method names")
    }

    return SourceDiagnostics(error)
}

/// If the value is content, the string "element" and the name of its
/// element function, or the string "type" and the name of the value's
/// type.
/// Port of `element_or_type_with_name` in `call.rs`.
func elementOrTypeWithName(_ value: Value) -> (String, String) {
    if case let .content(content) = value {
        return ("element", content.elem.name)
    }
    return ("type", value.type.longName)
}

// MARK: - Args

extension TypstSyntax.Args {
    /// Evaluate the argument list into library `Args`.
    /// Port of `Args::eval` in `call.rs`.
    public func eval(_ vm: inout Vm) throws -> TypstLibrary.Args {
        var items: [Arg] = []
        items.reserveCapacity(self.items().count)

        for arg in self.items() {
            let span = arg.span
            switch arg {
            case .pos(let expr):
                items.append(Arg(
                    span: span, name: nil,
                    value: Spanned(try expr.eval(&vm), span: expr.span)))
            case .named(let named):
                let expr = named.expr()
                items.append(Arg(
                    span: span, name: Str(named.name().get()),
                    value: Spanned(try expr.eval(&vm), span: expr.span)))
            case .spread(let spread):
                let spreadSpan = spread.span
                switch try spread.expr().eval(&vm) {
                case .none:
                    break
                case let .array(array):
                    for value in array.items {
                        items.append(Arg(
                            span: span, name: nil,
                            value: Spanned(value, span: spreadSpan)))
                    }
                case let .dict(dict):
                    for pair in dict.pairs {
                        items.append(Arg(
                            span: span, name: pair.key,
                            value: Spanned(pair.value, span: spreadSpan)))
                    }
                case let .arguments(args):
                    items.append(contentsOf: args.items)
                case let value:
                    throw SourceDiagnostics(SourceDiagnostic.error(
                        spreadSpan, "cannot spread \(value.type)"))
                }
            }
        }

        // We do *not* use the `self.span` here because we want the
        // callsite span to be one level higher (the whole function call).
        return TypstLibrary.Args(span: .detached, items: items)
    }
}

// MARK: - Closure

extension TypstSyntax.Closure {
    /// Evaluate the closure expression. Port of `Closure::eval` in
    /// `call.rs`.
    public func eval(_ vm: inout Vm) throws -> Value {
        // Evaluate default values of named parameters.
        var defaults: [Value] = []
        for param in params().items() {
            if case let .named(named) = param {
                defaults.append(try named.expr().eval(&vm))
            }
        }

        // Collect captured variables.
        var visitor = CapturesVisitor(scopes: vm.scopes,
                                      capturer: .function)
        visitor.visit(node)
        let captured = visitor.finish()

        // Define the closure.
        let closure = Closure(
            node: .closure(node),
            defaults: defaults,
            captured: captured,
            numPosParams: params().items().filter {
                if case .pos = $0 { return true }
                return false
            }.count,
            paramsSpan: params().span)

        return .function(Func(closure: closure).spanned(span))
    }
}

/// The routine installed as `routines.evalClosure`.
/// Port of `eval_closure` in `call.rs`.
public func evalClosureImpl(
    _ theFunc: Func, _ closure: Closure, _ engine: inout Engine,
    _ context: Context, _ args: Args
) -> SourceResult<Value> {
    do {
        return .success(try evalClosureBody(
            theFunc, closure, &engine, context, args))
    } catch let diagnostics as SourceDiagnostics {
        return .failure(diagnostics)
    } catch {
        return .failure(SourceDiagnostics(SourceDiagnostic.error(
            Span.detached, "\(error)")))
    }
}

/// The throwing body of `eval_closure`.
private func evalClosureBody(
    _ theFunc: Func, _ closure: Closure, _ engine: inout Engine,
    _ context: Context, _ args: Args
) throws -> Value {
    let name: String?
    let params: Params?
    let body: Expr
    switch closure.node {
    case let .closure(node):
        guard let astClosure = node.cast(TypstSyntax.Closure.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                Span.detached, "closure node is not a closure"))
        }
        name = astClosure.name()?.get()
        params = astClosure.params()
        body = astClosure.body()
    case let .context(node):
        guard let expr = node.cast(Expr.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                Span.detached, "context node is not an expression"))
        }
        name = nil
        params = nil
        body = expr
    }

    // Don't leak the scopes from the call site. Instead, we use the scope
    // of captured variables we collected earlier.
    var scopes = Scopes(base: nil)
    scopes.top = closure.captured

    // Prepare the engine. The route is extended locally (upstream builds a
    // fresh `Engine` with `Route::extend`); shared state (sink, traced,
    // introspector) flows through reference semantics.
    var localEngine = engine
    localEngine.route = localEngine.route.extend()

    // Prepare VM.
    var vm = Vm(engine: localEngine, context: context, scopes: scopes,
                inspected: nil)

    // Provide the closure itself for recursive calls.
    if let name {
        vm.define(name, .function(theFunc))
    }

    var args = args
    let numPosArgs = args.remaining
    let sinkSize = numPosArgs >= closure.numPosParams
        ? numPosArgs - closure.numPosParams : nil

    var sink: TypstSyntax.Ident? = nil
    var sinkPosValues: [Arg]? = nil
    var defaults = closure.defaults.makeIterator()
    for param in params?.items() ?? [] {
        switch param {
        case let .pos(pattern):
            if case let .normal(.ident(ident)) = pattern {
                vm.define(ident, try unwrap(args.expect(ident.get())))
            } else {
                try destructure(&vm, pattern: pattern,
                                value: try unwrap(args.expect("pattern parameter")))
            }
        case let .spread(spread):
            sink = spread.sinkIdent()
            if let sinkSize {
                sinkPosValues = try unwrap(args.consume(sinkSize))
            }
        case let .named(named):
            let paramName = named.name()
            let defaultValue = defaults.next() ?? Value.none
            let value = try unwrap(args.named(paramName.get())) ?? defaultValue
            vm.define(paramName, value)
        }
    }

    if sink != nil {
        // Remaining args are captured regardless of whether the sink is
        // named.
        var remainingArgs = args.take()
        if let sinkName = sink {
            if let sinkPosValues {
                remainingArgs.items.append(contentsOf: sinkPosValues)
            }
            vm.define(sinkName, .arguments(remainingArgs))
        }
    }

    // Ensure all arguments have been used.
    try unwrap(args.finish())

    // Handle control flow.
    let output = try body.eval(&vm)
    switch vm.flow {
    case .return(_, .some(let explicit), _):
        return explicit
    case .return(_, nil, _), .none:
        break
    case let .some(flow):
        throw flow.forbidden()
    }

    return output
}

// MARK: - CapturesVisitor

/// A visitor that determines which variables to capture for a closure.
/// Port of `CapturesVisitor` in `call.rs`.
struct CapturesVisitor {
    /// The external scopes at closure creation (nil for IDE analysis).
    var external: Scopes?
    /// Internal bindings introduced within the visited subtree.
    var internalScopes = Scopes(base: nil)
    /// The collected captures.
    var captures = Scope()
    /// What kind of entity is capturing.
    var capturer: Capturer

    init(scopes: Scopes?, capturer: Capturer) {
        self.external = scopes
        self.capturer = capturer
    }

    /// Return the scope of captured variables.
    func finish() -> Scope { captures }

    /// Visit any node and collect all captured variables.
    mutating func visit(_ node: SyntaxNode) {
        if let expr = node.cast(Expr.self) {
            switch expr {
            // Every identifier is a potential variable that we need to
            // capture. Identifiers that shouldn't count as captures because
            // they actually bind a new name are handled below.
            case .ident(let ident):
                capture(ident.get()) { $0.getBinding($1) }
                return
            case .mathIdent(let ident):
                capture(ident.get()) { $0.getBindingInMath($1) }
                return

            // Code and content blocks create a scope.
            case .codeBlock, .contentBlock:
                internalScopes.enter()
                for child in node.children { visit(child) }
                internalScopes.exit()
                return

            // Don't capture the field of a field access.
            case let .fieldAccess(access):
                visit(access.target().node)
                return
            case let .mathFieldAccess(access):
                visit(access.target().node)
                return

            // A closure contains parameter bindings, which are bound before
            // the body is evaluated. Care must be taken so that the default
            // values of named parameters cannot access previous parameter
            // bindings.
            case let .closure(expr):
                for param in expr.params().items() {
                    if case let .named(named) = param {
                        visit(named.expr().node)
                    }
                }

                internalScopes.enter()
                if let name = expr.name() {
                    bind(name)
                }
                for param in expr.params().items() {
                    switch param {
                    case let .pos(pattern):
                        for ident in pattern.bindings() { bind(ident) }
                    case let .named(named):
                        bind(named.name())
                    case let .spread(spread):
                        if let ident = spread.sinkIdent() { bind(ident) }
                    }
                }
                visit(expr.body().node)
                internalScopes.exit()
                return

            // A let expression contains a binding, but that binding is only
            // active after the body is evaluated.
            case let .letBinding(expr):
                if let initExpr = expr.initExpr() {
                    visit(initExpr.node)
                }
                for ident in expr.kind().bindings() { bind(ident) }
                return

            // A for loop contains one or two bindings in its pattern. These
            // are active after the iterable is evaluated but before the body
            // is evaluated.
            case let .forLoop(expr):
                visit(expr.iterable().node)
                internalScopes.enter()
                for ident in expr.pattern().bindings() { bind(ident) }
                visit(expr.body().node)
                internalScopes.exit()
                return

            // An import contains items, but these are active only after the
            // path is evaluated.
            case let .moduleImport(expr):
                visit(expr.source().node)
                if case let .items(items)? = expr.imports() {
                    for item in items.items() { bind(item.boundName()) }
                }
                return

            default:
                break
            }
        }

        // Never capture the name part of a named pair.
        if let named = node.cast(Named.self) {
            visit(named.expr().node)
            return
        }

        // Everything else is traversed from left to right.
        for child in node.children { visit(child) }
    }

    /// Bind a new internal variable.
    mutating func bind(_ ident: TypstSyntax.Ident) {
        // The concrete value does not matter as we only use the scoping
        // mechanism of `Scopes`, not the values themselves.
        internalScopes.top.bind(ident.get(),
                          binding: .detached(.none))
    }

    /// Capture a variable if it isn't internal.
    mutating func capture(
        _ name: String,
        getBinding: (Scopes, String) -> HintedStrResult<Binding>
    ) {
        if case .success = internalScopes.getBinding(name) { return }

        // If the variable has already been captured, there is no need to
        // look it up again, since the external scopes don't change.
        if captures.get(name) != nil { return }

        let binding: Binding
        if let external {
            switch getBinding(external, name) {
            case .success(let found): binding = found.capture(capturer)
            case .failure: return
            }
        } else {
            // The external scopes are only `nil` when we are doing IDE
            // capture analysis, in which case the concrete value doesn't
            // matter.
            binding = .detached(.none)
        }

        captures.bind(name, binding: binding)
    }
}
