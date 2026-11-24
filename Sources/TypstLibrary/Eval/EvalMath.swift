import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/math.rs` plus the math-call section of
// `call.rs` (`eval_math_call`, `unparse_math_args`, `MathArgs::eval`).

/// Evaluate an expression and convert the result to content for display
/// inside math. Port of the `ExprExt::eval_display` helper in `math.rs`.
private func evalDisplay(_ expr: Expr, _ vm: inout Vm) throws -> Content {
    try expr.eval(&vm).display.spanned(expr.span)
}

// MARK: - Equation / Math container

extension Equation {
    /// Port of `Equation::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let body = try self.body().eval(&vm)
        return EquationElem(body: body).withBlock(block()).pack()
    }
}

extension Math {
    /// Port of `Math::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        var seq: [Content] = []
        seq.reserveCapacity(exprs().count)
        for expr in exprs() {
            seq.append(try evalDisplay(expr, &vm))
        }
        return Content.sequence(seq)
    }
}

// MARK: - Leaf math nodes

extension MathLetter {
    /// Port of `MathLetter::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        SymbolElem.packed(get())
    }
}

extension MathSymbol {
    /// Port of `MathSymbol::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        SymbolElem.packed(get())
    }
}

extension MathNumber {
    /// Port of `MathNumber::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        TextElem.packed(get())
    }
}

extension MathIdent {
    /// Port of `MathIdent::eval` — resolves through the math scope.
    public func eval(_ vm: inout Vm) throws -> Value {
        let span = self.span
        return try unwrap(vm.scopes.getInMath(get(),
            guard: vm.engine.bindingGuard()).at(span))
    }
}

extension MathFieldAccess {
    /// Port of `MathFieldAccess::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let target = try self.target().eval(&vm)
        let field = self.field()
        return try accessField(vm: &vm, target: target,
                               field: field.get(), fieldSpan: field.span)
    }
}

extension MathAccess {
    /// Port of `MathAccess::eval` — evaluates to a `Value` (unlike most
    /// math nodes which produce `Content`).
    public func eval(_ vm: inout Vm) throws -> Value {
        let value: Value
        switch self {
        case .mathIdent(let ident):
            value = try ident.eval(&vm)
        case .mathFieldAccess(let access):
            value = try access.eval(&vm)
        }
        // We need to call `traceAt` for the value because we did not
        // evaluate via `Expr::eval`.
        vm.traceAt(self.span, value)
        return value
    }
}

extension MathShorthand {
    /// Port of `MathShorthand::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        .symbol(Symbol.runtimeChar(String(get()).first!))
    }
}

// MARK: - Structured math nodes

extension MathAlignPoint {
    /// Port of `MathAlignPoint::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        AlignPointElem.shared
    }
}

extension MathOpening {
    /// Port of `MathOpening::eval` — mainly used for an unpaired
    /// delimiter like `$ ( $`.
    public func eval(_ vm: inout Vm) throws -> Content {
        SymbolElem.packed(String(get()))
    }
}

extension MathClosing {
    /// Port of `MathClosing::eval` — mainly used for an unpaired
    /// delimiter like `$ ) $`.
    public func eval(_ vm: inout Vm) throws -> Content {
        SymbolElem.packed(String(get()))
    }
}

extension MathDelimited {
    /// Port of `MathDelimited::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let openNode = self.open()
        let open = try openNode.eval(&vm).spanned(openNode.span)
        let body = try self.body().eval(&vm)
        let closeNode = self.close()
        let close = try closeNode.eval(&vm).spanned(closeNode.span)
        return LrElem(body: open + body + close).pack()
    }
}

extension MathAttach {
    /// Port of `MathAttach::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let base = try evalDisplay(self.base(), &vm)
        var elem = AttachElem(base: base)

        if let expr = self.top() {
            elem.t = try evalDisplay(expr, &vm)
        }

        // Always attach primes in scripts style (not limits style),
        // i.e. at the top-right corner.
        if let primes = self.primes() {
            elem.tr = try primes.eval(&vm)
        }

        if let expr = self.bottom() {
            elem.b = try evalDisplay(expr, &vm)
        }

        return elem.pack()
    }
}

extension MathPrimes {
    /// Port of `MathPrimes::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        PrimesElem(count: count()).pack()
    }
}

extension MathFrac {
    /// Port of `MathFrac::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let numExpr = self.num()
        let num = try evalDisplay(numExpr, &vm)
        let denomExpr = self.denom()
        let denom = try evalDisplay(denomExpr, &vm)

        let numDepar: Bool
        if case let .math(math) = numExpr {
            numDepar = math.wasDeparenthesized()
        } else {
            numDepar = false
        }
        let denomDepar: Bool
        if case let .math(math) = denomExpr {
            denomDepar = math.wasDeparenthesized()
        } else {
            denomDepar = false
        }

        return FracElem(num: num, denom: denom)
            .withNumDeparenthesized(numDepar)
            .withDenomDeparenthesized(denomDepar)
            .pack()
    }
}

extension MathRoot {
    /// Port of `MathRoot::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        // Use `TextElem` to match `MathNumber` above.
        let index = self.index().map { TextElem.packed("\($0)") }
        let radicand = try evalDisplay(self.radicand(), &vm)
        return RootElem(radicand: radicand).withIndex(index).pack()
    }
}

// MARK: - Math calls

extension MathCall {
    /// Port of `MathCall::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        try evalMathCall(&vm, self)
    }
}

/// Evaluate a function call in math.
/// Port of `eval_math_call` in `call.rs`.
private func evalMathCall(_ vm: inout Vm, _ mathCall: MathCall) throws -> Value {
    let span = mathCall.span
    let callee = mathCall.callee()
    var targetSpan = Span.detached

    try unwrap(vm.engine.route.checkCallDepth().at(span))

    let mathCallResult: FieldCallee
    switch callee {
    case .mathIdent(let ident):
        let calleeValue = try ident.eval(&vm)
        // We need to call `traceAt` for the callee manually because we did
        // not evaluate via `Expr::eval`.
        vm.traceAt(ident.span, calleeValue)
        switch calleeValue.cast(Func.self) {
        case .success(let f): mathCallResult = .function(f)
        case .failure(let err): mathCallResult = .nonFunc(calleeValue, err)
        }
    case .mathFieldAccess(let access):
        let targetExpr = access.target()
        targetSpan = targetExpr.span
        let field = access.field()
        let target = try targetExpr.eval(&vm)
        if isMutatingMethod(field.get()),
           case .array = target {
            // FUTURE: This is probably worth allowing once we nail down
            // mutable method semantics. Mutable methods have always
            // produced an error in math because `Access` was never
            // implemented for `MathIdent`, so this explicit error is just
            // nicer.
            var error = SourceDiagnostic.error(
                span, "cannot call mutating methods in math")
            error.hint("try using code mode to call the method: `#\(mathCall.node.fullText())`")
            throw SourceDiagnostics(error)
        }
        mathCallResult = try evalFieldCallee(
            &vm, access: access.node, field: field.get(),
            fieldSpan: field.span, target: target, inMath: true)
    }

    let argsNode = mathCall.args()
    switch mathCallResult {
    case .function(let f):
        let args = try argsNode.eval(&vm).spanned(span)
        return try callFunc(&vm, f, args, span)
    case .method(let f, let target):
        var args = try argsNode.eval(&vm).spanned(span)
        // Method calls pass the target as the first argument.
        args.insert(index: 0, span: targetSpan, value: target)
        return try callFunc(&vm, f, args, span)
    case .nonFunc(let calleeValue, _):
        let parens = try unparseMathArgs(&vm, argsNode, callee: callee)
        return .content(calleeValue.display.spanned(callee.span) + parens)
    }
}

extension MathArgs {
    /// Evaluate math arguments, separating named/positional args and
    /// grouping two-dimensional (semicolon-separated) args into arrays.
    /// Port of `MathArgs::eval` in `call.rs`.
    public func eval(_ vm: inout Vm) throws -> TypstLibrary.Args {
        // Math args need to fully separate named/pos to handle
        // two-dimensional args correctly, for example:
        // `mat(a, delim:"[", b; c, d)`.
        var named: [Arg] = []
        var pos: [Arg] = []
        var twoDimStart: Int? = nil

        /// Optimize two-dimensional args by using `pos` as the sole
        /// container while iterating and only group into an array when we
        /// encounter a semicolon.
        func drainIntoArray(_ pos: inout [Arg], _ start: Int, _ span: Span) {
            let array = ArrayValue(pos[start...].map { $0.value.value })
            pos.removeSubrange(start...)
            pos.append(Arg(
                span: span, name: nil,
                value: Spanned(.array(array), span: span)))
        }

        for mathArg in argItems() {
            let arg = mathArg.arg
            let span = arg.span
            switch arg {
            case .pos(let expr):
                pos.append(Arg(
                    span: span, name: nil,
                    value: Spanned(try expr.eval(&vm), span: expr.span)))
            case .named(let namedArg):
                let expr = namedArg.expr()
                named.append(Arg(
                    span: span, name: Str(namedArg.name().get()),
                    value: Spanned(try expr.eval(&vm), span: expr.span)))
            case .spread(let spread):
                switch try spread.expr().eval(&vm) {
                case .none:
                    break
                case let .array(array):
                    for value in array.items {
                        pos.append(Arg(
                            span: span, name: nil,
                            value: Spanned(value, span: span)))
                    }
                case let .dict(dict):
                    for pair in dict.pairs {
                        named.append(Arg(
                            span: span, name: pair.key,
                            value: Spanned(pair.value, span: span)))
                    }
                case let .arguments(args):
                    for item in args.items {
                        if item.name == nil {
                            pos.append(item)
                        } else {
                            named.append(item)
                        }
                    }
                case let value:
                    throw SourceDiagnostics(SourceDiagnostic.error(
                        spread.span, "cannot spread \(value.type)"))
                }
            }
            if mathArg.endsInSemicolon {
                let start = twoDimStart ?? 0
                // There's not really a better span to use :/
                drainIntoArray(&pos, start, self.span)
                twoDimStart = pos.count
            }
        }

        if let start = twoDimStart, start != pos.count {
            drainIntoArray(&pos, start, self.span)
        }

        named.append(contentsOf: pos)
        return TypstLibrary.Args(span: .detached, items: named)
    }
}

/// For non-functions in math, we evaluate the arguments and punctuation
/// as content and wrap in an `LrElem`.
/// Port of `unparse_math_args` in `call.rs`.
private func unparseMathArgs(_ vm: inout Vm, _ args: MathArgs,
                             callee: MathAccess) throws -> Content {
    var body: [Content] = []
    var errors: [SourceDiagnostic] = []
    let calleeText = callee.node.fullText()

    for item in args.contentItems() {
        switch item {
        case .space(let space):
            body.append(try space.eval(&vm).spanned(space.span))
        case .comma(let c, let node),
             .semicolon(let c, let node),
             .leftParen(let c, let node),
             .rightParen(let c, let node):
            body.append(SymbolElem.packed(String(c)).spanned(node.span))
        case .arg(.pos(let expr)):
            // We use `Value::display` to convert argument expressions into
            // content instead of `Content::fromValue`. This makes it so we
            // don't error on `$sin(#1)$` because we don't error on `$#1$`.
            body.append(try expr.eval(&vm).display.spanned(expr.span))
        case .arg(.named(let named)):
            let name = calleeText
            var fixed = named.node.fullText()
            if let range = fixed.range(of: ":") {
                fixed.replaceSubrange(range, with: "\\:")
            }
            var error = SourceDiagnostic.error(
                named.span,
                "named-argument syntax can only be used with functions")
            error.hint("`\(name)` is not a function", at: callee.span.diag)
            error.hint("to render the colon as text, escape it: `\(fixed)`")
            errors.append(error)
        case .arg(.spread(let spread)):
            let name = calleeText
            var fixed = spread.node.fullText()
            if let range = fixed.range(of: "..") {
                fixed.replaceSubrange(range, with: ".. ")
            }
            var error = SourceDiagnostic.error(
                spread.span,
                "spread-argument syntax can only be used with functions")
            error.hint("`\(name)` is not a function", at: callee.span.diag)
            error.hint("to render the dots as text, add a space: `\(fixed)`")
            errors.append(error)
        }
    }

    if !errors.isEmpty {
        throw SourceDiagnostics(errors)
    }

    return LrElem(body: Content(SequenceElem(children: body)))
        .pack()
        .spanned(args.span)
}
