import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/code.rs` — the `Expr::eval` dispatch and the
// code-expression evaluators (literals, arrays, dicts, blocks,
// field access). Markup/math node evaluators land in EvalMarkup.swift /
// EvalMath.swift; calls/closures/imports in their own files.

/// Evaluate a stream of expressions.
/// Port of `eval_code` in `code.rs`.
func evalCode(_ vm: inout Vm, _ exprs: [Expr],
              _ index: inout Int) throws -> Value {
    let outerFlow = vm.flow
    vm.flow = nil
    var output = Value.none

    evalLoop: while index < exprs.count {
        let expr = exprs[index]
        index += 1
        let span = expr.span
        let value: Value
        switch expr {
        case .setRule(let set):
            let styles = try set.eval(&vm)
            if vm.flow != nil { break evalLoop }
            let tail = try evalCodeTail(&vm, exprs, &index)
            value = .content(tail.display.styledWithMap(styles))
        case .showRule(let show):
            let recipe = try show.eval(&vm)
            if vm.flow != nil { break evalLoop }
            let tail = try evalCodeTail(&vm, exprs, &index)
            value = .content(try tail.display.styledWithRecipe(
                engine: &vm.engine, context: vm.context, recipe: recipe))
        default:
            value = try expr.eval(&vm)
        }

        output = try unwrap(ops_join(output, value).at(span))

        if let event = vm.flow {
            warnForDiscardedContent(engine: vm.engine, event: event,
                                    joined: output)
            break evalLoop
        }
    }

    if outerFlow != nil {
        vm.flow = outerFlow
    }

    return output
}

/// Evaluate the remaining expressions after a set/show rule — the
/// recursive tail call in upstream's `eval_code`.
private func evalCodeTail(_ vm: inout Vm, _ exprs: [Expr],
                          _ index: inout Int) throws -> Value {
    try evalCode(&vm, exprs, &index)
}

extension Code {
    /// Evaluate the code body. Port of `Code::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        var index = 0
        return try evalCode(&vm, exprs(), &index)
    }
}

extension Expr {
    /// Evaluate the expression. Port of `Eval for ast::Expr`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let span = self.span
        let value: Value
        switch self {
        // Literals & identifiers
        case .ident(let v): value = try v.eval(&vm)
        case .none: value = .none
        case .auto: value = .auto
        case .bool(let v): value = try v.eval(&vm)
        case .int(let v): value = try v.eval(&vm)
        case .float(let v): value = try v.eval(&vm)
        case .numeric(let v): value = try v.eval(&vm)
        case .str(let v): value = try v.eval(&vm)
        // Collections & grouping
        case .array(let v): value = .array(try v.eval(&vm))
        case .dict(let v): value = .dict(try v.eval(&vm))
        case .parenthesized(let v): value = try v.eval(&vm)
        // Code structure
        case .codeBlock(let v): value = try v.eval(&vm)
        case .contentBlock(let v): value = .content(try v.eval(&vm))
        case .fieldAccess(let v): value = try v.eval(&vm)
        case .unary(let v): value = try v.eval(&vm)
        case .binary(let v): value = try v.eval(&vm)
        case .letBinding(let v): value = try v.eval(&vm)
        case .destructAssignment(let v): value = try v.eval(&vm)
        case .conditional(let v): value = try v.eval(&vm)
        case .whileLoop(let v): value = try v.eval(&vm)
        case .forLoop(let v): value = try v.eval(&vm)
        case .loopBreak(let v): value = try v.eval(&vm)
        case .loopContinue(let v): value = try v.eval(&vm)
        case .funcReturn(let v): value = try v.eval(&vm)
        // Markup nodes — ported in EvalMarkup.swift.
        case .text(let v): value = .content(try v.eval(&vm))
        case .space(let v): value = .content(try v.eval(&vm))
        case .linebreak(let v): value = .content(try v.eval(&vm))
        case .parbreak(let v): value = .content(try v.eval(&vm))
        case .escape(let v): value = try v.eval(&vm)
        case .shorthand(let v): value = try v.eval(&vm)
        case .smartQuote(let v): value = .content(try v.eval(&vm))
        case .strong(let v): value = .content(try v.eval(&vm))
        case .emph(let v): value = .content(try v.eval(&vm))
        case .raw(let v): value = .content(try v.eval(&vm))
        case .link(let v): value = .content(try v.eval(&vm))
        case .label(let v): value = try v.eval(&vm)
        case .ref(let v): value = .content(try v.eval(&vm))
        case .heading(let v): value = .content(try v.eval(&vm))
        case .listItem(let v): value = .content(try v.eval(&vm))
        case .enumItem(let v): value = .content(try v.eval(&vm))
        case .termItem(let v): value = .content(try v.eval(&vm))
        // Pending ports — throw until their files land.
        case .setRule, .showRule:
            throw evalNotImplemented(span, "set/show rules outside code blocks")
        case .funcCall(let v): value = try v.eval(&vm)
        case .closure(let v): value = try v.eval(&vm)
        case .moduleImport(let v): value = try v.eval(&vm)
        case .moduleInclude(let v): value = .content(try v.eval(&vm))
        case .contextual(let v): value = .content(try v.eval(&vm))
        // Math nodes — ported in EvalMath.swift.
        case .equation(let v): value = .content(try v.eval(&vm))
        case .math(let v): value = .content(try v.eval(&vm))
        case .mathLetter(let v): value = .content(try v.eval(&vm))
        case .mathSymbol(let v): value = .content(try v.eval(&vm))
        case .mathNumber(let v): value = .content(try v.eval(&vm))
        case .mathIdent(let v): value = try v.eval(&vm)
        case .mathFieldAccess(let v): value = try v.eval(&vm)
        case .mathShorthand(let v): value = try v.eval(&vm)
        case .mathAlignPoint(let v): value = .content(try v.eval(&vm))
        case .mathCall(let v): value = try v.eval(&vm)
        case .mathOpening(let v): value = .content(try v.eval(&vm))
        case .mathClosing(let v): value = .content(try v.eval(&vm))
        case .mathDelimited(let v): value = .content(try v.eval(&vm))
        case .mathAttach(let v): value = .content(try v.eval(&vm))
        case .mathPrimes(let v): value = .content(try v.eval(&vm))
        case .mathFrac(let v): value = .content(try v.eval(&vm))
        case .mathRoot(let v): value = .content(try v.eval(&vm))
        // Markup nodes handled above; remaining cases are pending ports.
        default:
            throw evalNotImplemented(span, "expression")
        }

        let spanned = value.spanned(span)

        // This satisfies the obligation to call `Vm::trace` for almost all
        // value-producing expressions!
        vm.traceAt(span, spanned)

        return spanned
    }
}

/// Error for evaluator parts not yet ported.
func evalNotImplemented(_ span: Span, _ what: String) -> SourceDiagnostics {
    SourceDiagnostics(SourceDiagnostic.error(
        span, "evaluation of \(what) is not yet implemented"))
}

// MARK: - Literals

extension TypstSyntax.Ident {
    /// Evaluate an identifier. Port of `Ident::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let span = self.span
        return try unwrap(vm.scopes.get(get(), guard: vm.engine
            .bindingGuard()).at(span))
    }
}

extension TypstSyntax.BoolExpr {
    /// Port of `Bool::eval`.
    public func eval(_ vm: inout Vm) throws -> Value { .bool(get()) }
}

extension TypstSyntax.IntExpr {
    /// Port of `Int::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        switch get() {
        case .success(let int): return .int(int)
        case .failure(let err):
            throw SourceDiagnostics(intLiteralError(self, err: err))
        }
    }
}

extension TypstSyntax.FloatExpr {
    /// Port of `Float::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        .float(get())
    }
}

extension TypstSyntax.Numeric {
    /// Port of `Numeric::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        Value.numeric(get())
    }
}

extension TypstSyntax.Str {
    /// Port of `Str::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        .str(TypstLibrary.Str(get()))
    }
}

// MARK: - Collections

extension TypstSyntax.ArrayExpr {
    /// Port of `Array::eval`.
    public func eval(_ vm: inout Vm) throws -> ArrayValue {
        var items = self.items()[...]
        var vec: [Value] = []
        vec.reserveCapacity(items.count)

        // We raise an error when one of the array items is the spread of a
        // dictionary. If _all_ of the array items are spreads of dictionaries,
        // the user probably wanted to write `(: ..dict_a, ..dict_b)` instead
        // to create a dictionary, not an array.
        var allDictSpreads = true

        while let item = items.popFirst() {
            switch item {
            case .pos(let expr):
                allDictSpreads = false
                vec.append(try expr.eval(&vm))
            case .spread(let spread):
                let spreadValue = try spread.expr().eval(&vm)
                switch spreadValue {
                case .none:
                    break
                case .array(let array):
                    allDictSpreads = false
                    vec.append(contentsOf: array.items)
                case .dict:
                    // Lookahead: remaining items must all be dict spreads.
                    let restAreDictSpreads = items.allSatisfy { item in
                        guard case .spread(let s) = item else { return false }
                        guard let v = try? s.expr().eval(&vm),
                              case .dict = v else { return false }
                        return true
                    }
                    if allDictSpreads && restAreDictSpreads {
                        var fixed = node.fullText()
                        if let range = fixed.range(of: "(") {
                            fixed.replaceSubrange(range, with: "(: ")
                        }
                        var diagnostic = SourceDiagnostic.error(
                            spread.span, "cannot spread \(spreadValue.type) into array")
                        diagnostic.hint("add a colon to create a dictionary instead: `\(fixed)`")
                        throw SourceDiagnostics(diagnostic)
                    }
                    throw SourceDiagnostics(SourceDiagnostic.error(
                        spread.span, "cannot spread \(spreadValue.type) into array"))
                default:
                    throw SourceDiagnostics(SourceDiagnostic.error(
                        spread.span, "cannot spread \(spreadValue.type) into array"))
                }
            }
        }

        return ArrayValue(items: vec)
    }
}

extension TypstSyntax.Dict {
    /// Port of `Dict::eval`.
    public func eval(_ vm: inout Vm) throws -> TypstLibrary.Dict {
        var map = TypstLibrary.Dict()
        var invalidKeys: [SourceDiagnostic] = []

        for item in items() {
            switch item {
            case .named(let named):
                let name = named.name()
                let value = try named.expr().eval(&vm)
                map.insert(name.get(), value)
            case .keyed(let keyed):
                let rawKey = keyed.key()
                let keyValue = try rawKey.eval(&vm)
                let key: Str
                switch Str.fromValue(keyValue) {
                case .success(let k): key = k
                case .failure(let error):
                    invalidKeys.append(error.atDiagnostics(rawKey.span)
                        .diagnostics[0])
                    key = Str()
                }
                let value = try keyed.expr().eval(&vm)
                map.insert(key, value)
            case .spread(let spread):
                let spreadValue = try spread.expr().eval(&vm)
                switch spreadValue {
                case .none:
                    break
                case .dict(let dict):
                    for (k, v) in dict.pairs { map.insert(k, v) }
                default:
                    throw SourceDiagnostics(SourceDiagnostic.error(
                        spread.span,
                        "cannot spread \(spreadValue.type) into dictionary"))
                }
            }
        }

        if !invalidKeys.isEmpty {
            throw SourceDiagnostics(invalidKeys)
        }

        return map
    }
}

// MARK: - Blocks & field access

extension TypstSyntax.CodeBlock {
    /// Port of `CodeBlock::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        vm.scopes.enter()
        let output = try body().eval(&vm)
        vm.scopes.exit()
        return output
    }
}

extension TypstSyntax.ContentBlock {
    /// Port of `ContentBlock::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        vm.scopes.enter()
        let content = try evalMarkup(&vm, body())
        vm.scopes.exit()
        return content
    }
}

extension TypstSyntax.Parenthesized {
    /// Port of `Parenthesized::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        try expr().eval(&vm)
    }
}

extension TypstSyntax.FieldAccess {
    /// Port of `FieldAccess::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let target = try self.target().eval(&vm)
        let field = self.field()
        return try accessField(vm: &vm, target: target,
                               field: field.get(), fieldSpan: field.span)
    }
}

/// Access a field on a target value.
/// Port of `access_field` in `code.rs`.
func accessField(vm: inout Vm, target: Value, field: String,
                 fieldSpan: Span) throws -> Value {
    let err: HintedString
    switch target.field(field, guard: vm.engine.bindingGuard()) {
    case .success(let value):
        return value
    case .failure(let e):
        err = e
    }

    // Missing fields may actually be present if they are settable parameters
    // on elements accessed with context, e.g. `block.stroke`.
    if case let .function(function) = target,
       let element = function.element,
       let fieldID = element.info.fieldID(field),
       let info = element.info.fields.first(where: { $0.id == fieldID }),
       info.settable {
        let styles = try unwrap(vm.context.requireStyles().at(fieldSpan))
        // Field accessors resolve through the style chain.
        if let value = styles.getValue(element, fieldID) {
            return value
        }
    }

    throw err.atDiagnostics(fieldSpan)
}

// MARK: - Flow warnings & literal errors

/// Emits a warning when we discard content while returning unconditionally.
/// Port of `warn_for_discarded_content` — the state/counter query hint is
/// deferred until introspection elements land.
func warnForDiscardedContent(engine: Engine, event: FlowEvent,
                             joined: Value) {
    guard case let .return(_, .some, false) = event,
          case .content = joined else { return }

    var diagnostic = SourceDiagnostic.warning(
        event.span,
        "this return unconditionally discards the content before it")
    diagnostic.hint("try omitting the `return` to automatically join all values")
    engine.sink.warn(diagnostic)
}

/// Evaluation error for an integer literal.
/// Port of `int_literal_error`.
func intLiteralError(_ int: TypstSyntax.IntExpr,
                     err: IntLiteralError) -> SourceDiagnostic {
    let span = int.span
    switch err {
    case .posOverflow(let base, _):
        var diagnostic = SourceDiagnostic.error(
            span, "integer value is too large")
        diagnostic.hint("value does not fit into a signed 64-bit integer")
        if base == nil {
            diagnostic.hint(
                "a floating point number could approximately represent this value")
            diagnostic.hint(
                "you can use a floating point number by appending a dot: `\(int.node.leafText).`")
        }
        return diagnostic
    case .invalidDigit(let base, let digits):
        let (range, badDigits) = findBadDigits(base: base, digits: digits)
        // Offset by two to skip the leading `0b`/`0o`/`0x`.
        let hintSpan = DiagSpan(span: span, subRange: SubRange(
            range.lowerBound + 2, range.upperBound + 2))
        let theDigitsAreInvalid: String
        switch badDigits.count {
        case 1:
            theDigitsAreInvalid = "the digit `\(badDigits[0])` is invalid"
        case 2:
            theDigitsAreInvalid = "the digits `\(badDigits[0])` and `\(badDigits[1])` are invalid"
        default:
            let list = badDigits.dropLast().map { "`\($0)`, " }.joined()
            theDigitsAreInvalid = "the digits \(list)and `\(badDigits.last!)` are invalid"
        }
        var diagnostic = SourceDiagnostic.error(
            span,
            "integer contains digits that are not valid for a\(base == .octal ? "n" : "") \(base.name) number")
        diagnostic.hint(theDigitsAreInvalid, at: hintSpan)
        let allowed: String
        switch base {
        case .hex: allowed = "0-9, a-f, A-F"
        case .octal: allowed = "0-7"
        case .binary: allowed = "0-1"
        }
        diagnostic.hint("\(base.name) numbers only allow digits \(allowed)")
        return diagnostic
    }
}

/// Find invalid digits for a non-decimal integer.
/// Port of `find_bad_digits` — returns the sub-range of the digits and
/// the invalid digit characters.
func findBadDigits(base: NonDecimalBase,
                   digits: String) -> (Range<Int>, [Character]) {
    let scalars: [Unicode.Scalar] = digits.unicodeScalars.map { $0 }
    func inRange(_ c: Unicode.Scalar, _ lo: Unicode.Scalar, _ hi: Unicode.Scalar) -> Bool {
        c.value >= lo.value && c.value <= hi.value
    }
    func isBad(_ c: Unicode.Scalar) -> Bool {
        switch base {
        case .hex: return inRange(c, "g", "z") || inRange(c, "G", "Z")
        case .octal: return inRange(c, "8", "9")
        case .binary: return inRange(c, "2", "9")
        }
    }

    var indices: [Int] = []
    var seen = Set<Unicode.Scalar>()
    for (i, scalar) in scalars.enumerated() where isBad(scalar) && seen.insert(scalar).inserted {
        indices.append(i)
    }
    guard let first = indices.first, let last = indices.last else {
        return (digits.count..<digits.count, [])
    }
    return (first..<(last + 1), indices.map { Character(scalars[$0]) })
}


/// Evaluate markup into content. Port of `eval_markup` entry —
/// the stream evaluator lives in `EvalMarkup.swift`.
func evalMarkup(_ vm: inout Vm, _ markup: Markup) throws -> Content {
    try markup.eval(&vm)
}

extension Contextual {
    /// Evaluate a context expression into deferred contextual content.
    /// Port of `Contextual::eval` in `code.rs`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let body = self.body()

        // Collect captured variables.
        var visitor = CapturesVisitor(scopes: vm.scopes, capturer: .context)
        visitor.visit(body.node)
        let captured = visitor.finish()

        // Define the closure.
        let closure = Closure(
            node: .context(body.node),
            defaults: [],
            captured: captured,
            numPosParams: 0,
            paramsSpan: .detached)

        let theFunc = Func(closure: closure).spanned(body.span)
        return ContextElem(func: theFunc).pack().spanned(body.span)
    }
}
