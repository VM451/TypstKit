import Foundation
import TypstSyntax
import TypstUtils

/// A function value: native, element constructor, closure, or partial
/// application. Port of `Func` in `func.rs`.
public struct Func: Sendable {
    /// The function kind.
    public indirect enum Inner: Sendable {
        /// A native Rust-implemented function.
        case native(NativeFuncData)
        /// An element constructor.
        case element(Element)
        /// A script closure or context expression.
        case closure(Closure)
        /// A partial application (`func.with(..)`).
        case `with`(With)
    }

    public var inner: Inner
    /// The span where the function value originated.
    public var span: Span

    public init(inner: Inner, span: Span = .detached) {
        self.inner = inner
        self.span = span
    }

    public init(native data: NativeFuncData) {
        self.init(inner: .native(data))
    }

    public init(element: Element) {
        self.init(inner: .element(element))
    }

    public init(closure: Closure) {
        self.init(inner: .closure(closure))
    }
}

/// A partial application. Port of `With`.
public struct With: Sendable {
    public var `func`: Func
    public var args: Args
    public var paramsSpan: Span
}

extension Func {
    /// The function's name, if any.
    public var name: String? {
        switch inner {
        case let .native(data): return data.name
        case let .element(elem): return elem.name
        case let .closure(closure): return closure.name
        case .with: return nil
        }
    }

    /// The function's title-cased name for docs.
    public var title: String? {
        switch inner {
        case let .native(data): return data.title
        case let .element(elem): return elem.title
        case .closure, .with: return nil
        }
    }

    /// When the function was introduced.
    public var since: Since? {
        switch inner {
        case let .native(data): return data.since
        case let .element(elem): return elem.since
        case .closure, .with: return nil
        }
    }

    /// Documentation string.
    public var docs: String? {
        switch inner {
        case let .native(data): return data.docs
        case let .element(elem): return elem.docs
        case .closure, .with: return nil
        }
    }

    /// Whether the function requires a known context.
    public var contextual: Bool? {
        switch inner {
        case let .native(data): return data.contextual
        case .element, .closure, .with: return nil
        }
    }

    /// Parameter info for IDE/tooling.
    public var params: [ParamInfo] {
        switch inner {
        case let .native(data):
            return data.params().map { .native($0) }
        case let .closure(closure):
            return closure.params().map { .closure($0) }
        case .element, .with:
            return []
        }
    }

    /// Find a parameter by name.
    public func param(_ name: String) -> ParamInfo? {
        params.first { $0.name == name }
    }

    /// The return type documentation.
    public var returns: CastInfo? {
        switch inner {
        case let .native(data): return data.returns()
        default: return nil
        }
    }

    /// Search keywords.
    public var keywords: [String] {
        switch inner {
        case let .native(data): return data.keywords
        case let .element(elem): return elem.keywords
        default: return []
        }
    }

    /// Definition site.
    public var defSite: DefSite? {
        switch inner {
        case let .native(data): return data.defSite
        case let .element(elem): return elem.defSite
        default: return nil
        }
    }

    /// The associated scope (static methods), if any.
    public var scope: Scope? {
        switch inner {
        case let .native(data): return data.scope()
        case let .element(elem): return elem.scope
        default: return nil
        }
    }

    /// Look up a field (static method) on the function's scope.
    public func field(_ field: String, guard access: any BindingGuard) -> HintedStrResult<Value> {
        guard let scope, let binding = scope.get(field) else {
            return .failure(HintedString("function does not contain field `\(field)`"))
        }
        return binding.read(access).mapError { $0.cannot("access field `\(field)`") }
    }

    /// The element, if this is an element constructor.
    public var element: Element? {
        if case let .element(elem) = inner { return elem }
        return nil
    }

    /// The native func data, if native.
    public var nativeData: NativeFuncData? {
        if case let .native(data) = inner { return data }
        return nil
    }

    /// Call the function and cast the result.
    @discardableResult
    public func call<T: FromValue>(
        engine: inout Engine,
        context: Context,
        args: Args,
        span: Span
    ) -> SourceResult<T> {
        callValue(engine: &engine, context: context, args: args, span: span)
            .flatMap { T.fromValue($0).at(span) }
    }

    /// Call the function, returning the raw value.
    @discardableResult
    public func callValue(
        engine: inout Engine,
        context: Context,
        args: Args,
        span: Span
    ) -> SourceResult<Value> {
        callImpl(engine: &engine, context: context, args: args)
            .traced(.call(name), at: span)
    }

    func callImpl(
        engine: inout Engine,
        context: Context,
        args: Args
    ) -> SourceResult<Value> {
        switch inner {
        case let .native(data):
            var args = args
            switch data.function(&engine, context, &args) {
            case let .failure(diags): return .failure(diags)
            case let .success(value): return args.finish().map { value }
            }
        case let .element(elem):
            var args = args
            let content: Content
            do {
                content = try elem.construct(engine: &engine, args: &args)
            } catch let error as HintedString {
                return .failure(SourceDiagnostics(error.intoErrorAt(args.span)))
            } catch {
                return .failure(SourceDiagnostics(SourceDiagnostic.error(
                    args.span, "\(error)")))
            }
            return args.finish().map { .content(content) }
        case let .closure(closure):
            guard let eval = engine.library.routines.evalClosure else {
                return .failure(SourceDiagnostics(SourceDiagnostic.error(
                    Span.detached, "cannot evaluate closure: eval routines not installed")))
            }
            return eval(self, closure, &engine, context, args)
        case let .with(with):
            var combined = with.args
            combined.items.append(contentsOf: args.items)
            return with.func.callImpl(engine: &engine, context: context, args: combined)
        }
    }

    /// The span of the function value.
    public var funcSpan: Span { span }

    /// The span of the parameter list (for closures/with).
    public var paramsSpan: Span {
        switch inner {
        case .native, .element: return Span.detached
        case let .closure(closure): return closure.paramsSpan
        case let .with(with): return with.paramsSpan
        }
    }

    /// Return a copy with a span, if currently detached.
    public func spanned(_ span: Span) -> Func {
        var copy = self
        if copy.span.isDetached { copy.span = span }
        return copy
    }

    /// Partial application: `func.with(..args)`.
    public func with(_ args: Args) -> Func {
        Func(
            inner: .with(With(
                func: self,
                args: args,
                paramsSpan: paramsSpan
            )),
            span: span
        )
    }

    /// `func.where(fields)` — element selector constructor.
    public func where_(
        _ args: Args
    ) -> StrResult<Selector> {
        var args = args
        let fields = args.toNamed
        args.items.removeAll { $0.name != nil }

        guard let elem = element else {
            return .failure(StrError(
                "`where()` can only be called on element functions"
            ))
        }

        var fieldPairs: [(UInt8, Value)] = []
        for (key, value) in fields {
            guard let id = elem.fieldId(key.value) else {
                return .failure(StrError(
                    "element `\(elem.name)` does not have field `\(key)`"
                ))
            }
            fieldPairs.append((id, value))
        }
        return .success(elem.where_(fields: fieldPairs))
    }
}

extension Func: CustomDebugStringConvertible {
    public var debugDescription: String { "Func(\(name ?? ".."))" }
}

extension Func: Repr {
    public func repr() -> String {
        switch inner {
        case let .native(data): return data.name
        case let .element(elem): return elem.name
        case let .closure(closure): return closure.name ?? "(..) => .."
        case .with: return "(..) => .."
        }
    }
}

extension Func: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch inner {
        case let .native(data): hasher.combine(ObjectIdentifier(data))
        case let .element(elem): hasher.combine(elem)
        case let .closure(closure): hasher.combine(closure)
        case let .with(with): hasher.combine(with)
        }
        hasher.combine(span)
    }

    public static func == (lhs: Func, rhs: Func) -> Bool {
        lhs.inner == rhs.inner
    }
}

extension Func.Inner: Equatable {
    public static func == (lhs: Func.Inner, rhs: Func.Inner) -> Bool {
        switch (lhs, rhs) {
        case let (.native(a), .native(b)): return a === b
        case let (.element(a), .element(b)): return a == b
        case let (.closure(a), .closure(b)): return a == b
        case let (.with(a), .with(b)): return a == b
        default: return false
        }
    }
}

extension With: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(`func`)
        hasher.combine(args)
        hasher.combine(paramsSpan)
    }
}

/// Details about a function parameter. Port of `ParamInfo`.
public enum ParamInfo: Sendable {
    case native(NativeParamInfo)
    case closure(Spanned<ClosureParamInfo, Span>)
    case plugin

    public var native: NativeParamInfo? {
        if case let .native(info) = self { return info }
        return nil
    }

    public var name: String? {
        switch self {
        case let .native(info): return info.name
        case let .closure(info):
            switch info.value {
            case let .pos(name): return name
            case let .sink(name): return name
            case let .named(name, _): return name
            }
        case .plugin: return nil
        }
    }

    public var defaultValue: Value? {
        switch self {
        case let .native(info): return info.defaultValue?()
        case let .closure(info):
            if case let .named(_, defaultValue) = info.value { return defaultValue }
            return nil
        case .plugin: return nil
        }
    }

    public var positional: Bool {
        switch self {
        case let .native(info): return info.positional
        case let .closure(info):
            switch info.value {
            case .pos, .sink: return true
            case .named: return false
            }
        case .plugin: return true
        }
    }

    public var named: Bool {
        switch self {
        case let .native(info): return info.named
        case let .closure(info):
            if case .named = info.value { return true }
            return false
        case .plugin: return false
        }
    }

    public var variadic: Bool {
        switch self {
        case let .native(info): return info.variadic
        case let .closure(info):
            if case .sink = info.value { return true }
            return false
        case .plugin: return true
        }
    }

    public var required: Bool {
        switch self {
        case let .native(info): return info.required
        case let .closure(info):
            if case .pos = info.value { return true }
            return false
        case .plugin: return false
        }
    }

    public var settable: Bool {
        switch self {
        case let .native(info): return info.settable
        default: return false
        }
    }
}

/// A native function's implementation signature.
public typealias NativeFuncSignature =
    @Sendable (inout Engine, Context, inout Args) -> SourceResult<Value>

/// Metadata for a native function. Port of `NativeFuncData`.
///
/// Upstream stores `&'static NativeFuncData`; the Swift port uses a class so
/// identity (`===`) provides the same equality semantics.
public final class NativeFuncData: @unchecked Sendable {
    /// The function implementation.
    public let function: NativeFuncSignature
    /// The function name.
    public let name: String
    /// Title-cased name.
    public let title: String
    /// When introduced.
    public let since: Since?
    /// Documentation.
    public let docs: String
    /// Definition site.
    public let defSite: DefSite?
    /// Keywords.
    public let keywords: [String]
    /// Whether the function needs a known context.
    public let contextual: Bool
    /// Lazily built associated scope.
    public let scopeBuilder: () -> Scope
    /// Lazily built parameter info.
    public let paramsBuilder: () -> [NativeParamInfo]
    /// Lazily built return type info.
    public let returnsBuilder: () -> CastInfo

    private var scopeStorage: Scope?
    private var paramsStorage: [NativeParamInfo]?
    private var returnsStorage: CastInfo?
    private let lock = NSLock()

    public init(
        name: String,
        title: String? = nil,
        since: Since? = nil,
        docs: String = "",
        defSite: DefSite? = nil,
        keywords: [String] = [],
        contextual: Bool = false,
        function: @escaping NativeFuncSignature,
        scope: @escaping () -> Scope = { Scope() },
        params: @escaping () -> [NativeParamInfo] = { [] },
        returns: @escaping () -> CastInfo = { .any }
    ) {
        self.name = name
        self.title = title ?? name.prefix(1).uppercased() + name.dropFirst()
        self.since = since
        self.docs = docs
        self.defSite = defSite
        self.keywords = keywords
        self.contextual = contextual
        self.function = function
        self.scopeBuilder = scope
        self.paramsBuilder = params
        self.returnsBuilder = returns
    }

    public func scope() -> Scope {
        lock.lock()
        defer { lock.unlock() }
        if let scopeStorage { return scopeStorage }
        let s = scopeBuilder()
        scopeStorage = s
        return s
    }

    public func params() -> [NativeParamInfo] {
        lock.lock()
        defer { lock.unlock() }
        if let paramsStorage { return paramsStorage }
        let p = paramsBuilder()
        paramsStorage = p
        return p
    }

    public func returns() -> CastInfo {
        lock.lock()
        defer { lock.unlock() }
        if let returnsStorage { return returnsStorage }
        let r = returnsBuilder()
        returnsStorage = r
        return r
    }
}

/// Parameter metadata for a native function. Port of `NativeParamInfo`.
public struct NativeParamInfo: Sendable {
    public let name: String
    public let docs: String
    public let defSite: DefSite?
    /// The accepted input types.
    public let input: CastInfo
    /// Default value provider.
    public let defaultValue: (@Sendable () -> Value)?
    public let positional: Bool
    public let named: Bool
    public let variadic: Bool
    public let required: Bool
    public let settable: Bool

    public init(
        name: String,
        docs: String = "",
        defSite: DefSite? = nil,
        input: CastInfo = .any,
        defaultValue: (@Sendable () -> Value)? = nil,
        positional: Bool = true,
        named: Bool = false,
        variadic: Bool = false,
        required: Bool = false,
        settable: Bool = false
    ) {
        self.name = name
        self.docs = docs
        self.defSite = defSite
        self.input = input
        self.defaultValue = defaultValue
        self.positional = positional
        self.named = named
        self.variadic = variadic
        self.required = required
        self.settable = settable
    }
}

/// A script closure or context expression. Port of `Closure`.
public struct Closure: Sendable, Hashable {
    /// The closure AST node (or context expression node).
    public enum Node: Sendable, Hashable {
        case closure(SyntaxNode)
        case context(SyntaxNode)
    }

    public var node: Node
    /// Default values for named parameters.
    public var defaults: [Value]
    /// Captured scope.
    public var captured: Scope
    /// Number of positional parameters.
    public var numPosParams: Int
    /// Span of the parameter list.
    public var paramsSpan: Span

    public init(
        node: Node,
        defaults: [Value] = [],
        captured: Scope,
        numPosParams: Int,
        paramsSpan: Span
    ) {
        self.node = node
        self.defaults = defaults
        self.captured = captured
        self.numPosParams = numPosParams
        self.paramsSpan = paramsSpan
    }

    /// The closure's name, if named.
    public var name: String? {
        guard case let .closure(node) = node,
              let closure = node.cast(TypstSyntax.Closure.self)
        else { return nil }
        return closure.name()?.get()
    }

    /// Parameter info for IDE/tooling.
    public func params() -> [Spanned<ClosureParamInfo, Span>] {
        guard case let .closure(node) = node,
              let astClosure = node.cast(TypstSyntax.Closure.self)
        else { return [] }

        var defaults = self.defaults.makeIterator()
        return astClosure.params().items().map { param in
            let info: ClosureParamInfo
            switch param {
            case let .pos(pattern):
                if case let .normal(.ident(ident)) = pattern {
                    info = .pos(name: ident.get())
                } else {
                    info = .pos(name: nil)
                }
            case let .spread(spread):
                info = .sink(name: spread.sinkIdent()?.get())
            case let .named(named):
                info = .named(
                    name: named.name().get(),
                    defaultValue: defaults.next() ?? .none
                )
            }
            return Spanned(info, span: param.span)
        }
    }
}

/// Closure parameter details. Port of `ClosureParamInfo`.
public enum ClosureParamInfo: Sendable, Hashable {
    case pos(name: String?)
    case sink(name: String?)
    case named(name: String, defaultValue: Value)
}
