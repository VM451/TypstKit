import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/lib.rs` — the public evaluation entry points:
// `eval` (source file → module) and `eval_string` (string → value).

/// Convert a syntax-tree diagnostic into a source diagnostic.
/// Port of the `Into<SourceDiagnostic>` impl for `SyntaxDiagnostic`.
extension SourceDiagnostic {
    public init(_ diagnostic: SyntaxDiagnostic) {
        self.init(
            severity: diagnostic.isError ? .error : .warning,
            span: diagnostic.span,
            message: diagnostic.message,
            trace: [],
            hints: diagnostic.hints)
    }
}

/// Evaluate a source file and return the resulting module.
/// Port of `eval` in `lib.rs`.
public func evalModule(_ engine: Engine, _ source: Source) throws -> Module {
    // Prevent cyclic evaluation.
    let id = source.id
    precondition(!engine.route.contains(id),
                 "Tried to cyclicly evaluate \(id.vpath)")

    // Prepare the engine with an extended route carrying this file's id.
    var inner = engine
    inner.route = engine.route.extend().withId(id)

    // Prepare VM.
    let root = source.root
    let inspected = root.span.id.flatMap { inner.traced.get($0) }
    var vm = Vm(
        engine: inner,
        context: Context(),
        scopes: Scopes(base: inner.library.scope),
        inspected: inspected)

    // Check for errors or warnings in the syntax tree before evaluating it.
    // However, if we're inspecting a span, we keep going with evaluation
    // regardless of syntax errors.
    let (errors, warnings) = root.errorsAndWarnings()
    for warning in warnings {
        vm.engine.sink.warn(SourceDiagnostic(warning))
    }
    if !errors.isEmpty && vm.inspected == nil {
        // We _could_ also return the warnings here with the errors, but we
        // want to only use the sink for warnings for consistency.
        throw SourceDiagnostics(errors.map { SourceDiagnostic($0) })
    }

    // Evaluate the module.
    guard let markup = root.cast(Markup.self) else {
        throw SourceDiagnostics(SourceDiagnostic.error(
            root.span, "file does not contain markup"))
    }
    let output = try markup.eval(&vm)

    // Handle control flow.
    if let flow = vm.flow {
        throw flow.forbidden()
    }

    // Assemble the module.
    let name = id.vpath.fileStem ?? ""
    return Module(
        name: Str(name), scope: vm.scopes.top, fileId: id, content: output)
}

/// How source spans are assigned when evaluating a string.
/// Port of `SpanMode` in `routines.rs`.
public enum SpanMode {
    /// All syntax nodes receive the same span.
    case uniform(Span)
    /// Spans are mapped into a real source file.
    case mapped(id: FileId, mapper: RangeMapper, mapperErrorSpan: Span)
}

/// Evaluate a string in the given syntax `mode` and return the resulting
/// value. Port of `eval_string` in `lib.rs`.
public func evalString(
    world: World,
    library: LazyHash<Library>,
    sink: Sink,
    introspector: Introspector,
    context: Context,
    string: String,
    spans: SpanMode,
    mode: SyntaxMode,
    scope: Scope
) throws -> Value {
    var root: SyntaxNode
    switch mode {
    case .code: root = parseCode(string)
    case .markup: root = parse(string)
    case .math: root = parseMath(string)
    }

    switch spans {
    case .uniform(let span) where span.isDetached:
        break
    case .uniform(let span):
        root.synthesize(span)
    case .mapped(let id, let mapper, let mapperErrorSpan):
        do {
            try root.synthesizeMapped(id: id, mapper: mapper)
        } catch {
            throw SourceDiagnostics(SourceDiagnostic.error(
                mapperErrorSpan, "\(error)"))
        }
    }

    // Check for errors or warnings in the syntax tree before evaluating it.
    let (errors, warnings) = root.errorsAndWarnings()
    for warning in warnings {
        sink.warn(SourceDiagnostic(warning))
    }
    if !errors.isEmpty {
        // We _could_ also return the warnings here with the errors, but we
        // want to only use the sink for warnings for consistency.
        throw SourceDiagnostics(errors.map { SourceDiagnostic($0) })
    }

    // Prepare the engine.
    let traced = Traced()
    var engine = Engine(world: world)
    engine.introspector = introspector
    engine.traced = traced
    engine.sink = sink
    engine.route = Route()

    // Prepare VM.
    let inspected = root.span.id.flatMap { traced.get($0) }
    var vm = Vm(
        engine: engine, context: context,
        scopes: Scopes(base: library.value.scope), inspected: inspected)
    vm.scopes.push(scope)

    // Evaluate the code.
    let output: Value
    switch mode {
    case .code:
        guard let code = root.cast(Code.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                root.span, "expected code"))
        }
        output = try code.eval(&vm)
    case .markup:
        guard let markup = root.cast(Markup.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                root.span, "expected markup"))
        }
        output = .content(try markup.eval(&vm))
    case .math:
        guard let math = root.cast(Math.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                root.span, "expected math"))
        }
        output = .content(
            EquationElem(body: try math.eval(&vm))
                .withBlock(false)
                .pack()
                .spanned(root.span))
    }

    // Handle control flow.
    if let flow = vm.flow {
        throw flow.forbidden()
    }

    return output
}
