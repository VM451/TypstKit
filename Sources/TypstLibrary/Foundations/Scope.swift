import TypstUtils
import TypstSyntax
import Foundation

/// A feature that must be explicitly enabled. Port of `Feature` in lib.rs.
public enum Feature: String, Sendable, Hashable, CaseIterable {
    case html
    case bundle
    case a11yExtras = "a11y-extras"

    public var displayName: String { rawValue }
}

/// The set of enabled features. Port of `Features` in lib.rs.
public struct Features: Sendable, Hashable {
    public private(set) var enabled: Set<Feature>

    public init(_ enabled: Set<Feature> = []) {
        self.enabled = enabled
    }

    /// All features enabled.
    public static func all() -> Features {
        Features(Set(Feature.allCases))
    }

    /// No features enabled.
    public static func none() -> Features { Features() }

    public mutating func enable(_ feature: Feature) {
        enabled.insert(feature)
    }

    public func isEnabled(_ feature: Feature) -> Bool {
        enabled.contains(feature)
    }
}

/// A group of related standard library definitions. Port of `Category`.
public enum Category: String, Sendable, Hashable, CaseIterable {
    case foundations
    case introspection
    case layout
    case dataLoading = "data-loading"
    case math
    case model
    case symbols
    case text
    case visualize
    case format
    case pdf
    case html
    case svg
    case png
    case bundle

    /// The kebab-case name.
    public var name: String { rawValue }
}

/// Documentation metadata attached to a binding. Port of
/// `BindingDocumentation`.
public struct BindingDocumentation: Sendable, Hashable {
    public let name: String
    public let title: String
    public let docs: String
    public let since: Since?
    public let keywords: [String]
    public let defSite: DefSite?

    public init(
        name: String,
        title: String,
        docs: String,
        since: Since? = nil,
        keywords: [String] = [],
        defSite: DefSite? = nil
    ) {
        self.name = name
        self.title = title
        self.docs = docs
        self.since = since
        self.keywords = keywords
        self.defSite = defSite
    }

    public init(funcData data: NativeFuncData) {
        self.init(
            name: data.name,
            title: data.title,
            docs: data.docs,
            since: data.since,
            keywords: data.keywords,
            defSite: data.defSite
        )
    }

    public init(typeInfo info: TypeInfo) {
        self.init(
            name: info.name,
            title: info.title,
            docs: info.docs,
            since: info.since,
            keywords: info.keywords,
            defSite: info.defSite
        )
    }

    public init(element info: ElementInfo) {
        self.init(
            name: info.name,
            title: info.title,
            docs: info.docs,
            since: info.since,
            keywords: info.keywords,
            defSite: info.defSite
        )
    }
}

/// A deprecation notice attached to a binding. Port of `Deprecation`.
public struct Deprecation: Sendable, Hashable {
    public var message: String
    public var until: String?

    public init(message: String = "item is deprecated", until: String? = nil) {
        self.message = message
        self.until = until
    }

    public func withMessage(_ message: String) -> Deprecation {
        var copy = self
        copy.message = message
        return copy
    }

    public func withUntil(_ version: String) -> Deprecation {
        var copy = self
        copy.until = version
        return copy
    }
}

/// What captured a binding, making it read-only. Port of `Capturer`.
public enum Capturer: String, Sendable, Hashable {
    case function = "function"
    case context = "context expression"
}

/// Receives warnings emitted while accessing bindings. Port of
/// `WarningSink`.
public protocol WarningSink {
    mutating func emit(_ message: HintedString)
}

/// Guards binding access based on enabled features. Port of
/// `BindingGuard`.
public protocol BindingGuard {
    var features: Features { get }
}

/// A binding guard that does nothing. Port of `SilentBindingGuard`.
public struct SilentBindingGuard: BindingGuard {
    public let features: Features

    public init(features: Features) {
        self.features = features
    }
}

/// Error when accessing a feature-gated binding. Port of `FeatureError`.
public struct FeatureError: Error, Sendable, Hashable {
    public let feature: Feature

    public func cannot(_ what: String) -> HintedString {
        HintedString(
            message: "cannot \(what) because the `\(feature.displayName)` feature is not enabled",
            hints: [
                "try enabling the `\(feature.displayName)` feature",
                "see https://typst.app/help/compiler-features for more details",
            ]
        )
    }
}

/// Error when writing to a binding. Port of `BindingError`.
public enum BindingError: Error, Sendable, Hashable {
    case captured(Capturer)
    case feature(FeatureError)

    public func cannot(_ what: String) -> HintedString {
        switch self {
        case let .captured(capturer):
            HintedString(
                "variables from outside the \(capturer.rawValue) are read-only and cannot be modified"
            )
        case let .feature(error):
            error.cannot(what)
        }
    }
}

/// Result helper matching upstream `BindingAccess::or_cannot`.
public protocol BindingAccessResult {
    associatedtype Value
    func orCannot(_ what: String) -> HintedStrResult<Value>
}

extension Result where Success == Value, Failure == BindingError {
    public func orCannot(_ what: String) -> HintedStrResult<Value> {
        mapError { $0.cannot(what) }
    }
}

extension Result where Success == Value, Failure == FeatureError {
    public func orCannot(_ what: String) -> HintedStrResult<Value> {
        mapError { $0.cannot(what) }
    }
}

/// A named value in a scope with access metadata. Port of `Binding`.
public struct Binding: Sendable {
    /// The bound value.
    public internal(set) var value: Value
    /// Whether the binding was captured by a function/context.
    var kind: BindingKind
    /// The span where the binding was defined.
    public let span: Span
    /// Whether feature/deprecation checks apply.
    var checkAccess: Bool
    /// Optional documentation/access metadata.
    var info: BindingInfo?

    enum BindingKind: Sendable {
        case normal
        case captured(Capturer)
    }

    struct BindingInfo: Sendable {
        var category: Category?
        var feature: Feature?
        var deprecation: Deprecation?
        var documentation: BindingDocumentation?

        var hasCheckedAccess: Bool {
            feature != nil || deprecation != nil
        }
    }

    public init(value: Value, span: Span) {
        self.value = value
        self.kind = .normal
        self.span = span
        self.checkAccess = false
        self.info = nil
    }

    /// A binding not associated with any source location.
    public static func detached(_ value: Value) -> Binding {
        Binding(value: value, span: .detached)
    }

    @discardableResult
    public mutating func withCategory(_ category: Category) -> Binding {
        ensureInfo()
        info?.category = category
        return self
    }

    @discardableResult
    public mutating func withFeature(_ feature: Feature) -> Binding {
        ensureInfo()
        info?.feature = feature
        checkAccess = info?.hasCheckedAccess ?? false
        return self
    }

    @discardableResult
    public mutating func withDeprecation(_ deprecation: Deprecation) -> Binding {
        ensureInfo()
        info?.deprecation = deprecation
        checkAccess = info?.hasCheckedAccess ?? false
        return self
    }

    @discardableResult
    public mutating func withDocumentation(_ documentation: BindingDocumentation) -> Binding {
        ensureInfo()
        info?.documentation = documentation
        return self
    }

    mutating func ensureInfo() {
        if info == nil { info = BindingInfo() }
    }

    /// Read the bound value, checking feature gates and emitting deprecation
    /// warnings through the guard.
    public func read(_ access: any BindingGuard) -> Result<Value, FeatureError> {
        if checkAccess {
            return checkAccess(access).map { value }
        }
        return .success(value)
    }

    /// Write the bound value, checking access.
    public mutating func write(_ access: any BindingGuard) -> Result<Value, BindingError> {
        if checkAccess {
            if case let .failure(error) = checkAccess(access) {
                return .failure(.feature(error))
            }
        }
        if case let .captured(capturer) = kind {
            return .failure(.captured(capturer))
        }
        return .success(value)
    }

    func checkAccess(_ access: any BindingGuard) -> Result<Void, FeatureError> {
        guard let info else { return .success(()) }
        if let feature = info.feature, !access.features.isEnabled(feature) {
            return .failure(FeatureError(feature: feature))
        }
        // Deprecation warnings are emitted by callers via `deprecation`.
        return .success(())
    }

    /// Mark the binding as captured (read-only outside its scope).
    public func capture(_ capturer: Capturer) -> Binding {
        var copy = self
        copy.kind = .captured(capturer)
        return copy
    }

    public var category: Category? { info?.category }
    public var feature: Feature? { info?.feature }
    public var deprecation: Deprecation? { info?.deprecation }
    public var isDocumented: Bool { info?.documentation != nil }
    public var name: String? { info?.documentation?.name }
    public var title: String? { info?.documentation?.title }
    public var docs: String? { info?.documentation?.docs }
    public var since: Since? { info?.documentation?.since }
    public var keywords: [String] { info?.documentation?.keywords ?? [] }
    public var defSite: DefSite? { info?.documentation?.defSite }
}

/// A scope mapping names to bindings. Port of `Scope`.
public final class Scope: @unchecked Sendable {
    /// Ordered map of name → binding.
    var map: [String: Binding] = [:]
    /// Order of insertion for deterministic iteration.
    var order: [String] = []
    var deduplicate: Bool
    var category: Category?

    public init() {
        self.deduplicate = false
    }

    /// A scope that panics on duplicate definitions (debug builds).
    public static func deduplicating() -> Scope {
        let scope = Scope()
        scope.deduplicate = true
        return scope
    }

    public func startCategory(_ category: Category) {
        self.category = category
    }

    public func resetCategory() {
        category = nil
    }

    /// Define a native function in this scope.
    @discardableResult
    public func defineFunc(_ data: NativeFuncData) -> Binding {
        var binding = Binding.detached(Value.function(Func(native: data)))
        binding.withDocumentation(BindingDocumentation(funcData: data))
        if let category { binding.withCategory(category) }
        return bind(data.name, binding: binding)
    }

    /// Define a type in this scope.
    @discardableResult
    public func defineType<T: NativeType>(_ type: T.Type = T.self) -> Binding {
        let ty = Type(T.typeInfo)
        var binding = Binding.detached(Value.type(ty))
        binding.withDocumentation(BindingDocumentation(typeInfo: T.typeInfo))
        if let category { binding.withCategory(category) }
        return bind(T.typeInfo.name, binding: binding)
    }

    /// Define an element function in this scope.
    @discardableResult
    public func defineElement(_ info: ElementInfo) -> Binding {
        let elem = Element(info: info)
        var binding = Binding.detached(Value.function(Func(element: elem)))
        binding.withDocumentation(BindingDocumentation(element: info))
        if let category { binding.withCategory(category) }
        return bind(info.name, binding: binding)
    }

    /// Define a plain value.
    @discardableResult
    public func define(_ name: String, _ value: Value) -> Binding {
        var binding = Binding.detached(value)
        if let category { binding.withCategory(category) }
        return bind(name, binding: binding)
    }

    /// Bind a name, replacing any existing binding.
    @discardableResult
    public func bind(_ name: String, binding: Binding) -> Binding {
        if deduplicate && map[name] != nil {
            fatalError("duplicate definition: \(name)")
        }
        if map[name] == nil { order.append(name) }
        map[name] = binding
        return binding
    }

    public func get(_ name: String) -> Binding? {
        map[name]
    }

    /// Mutate an existing binding in place.
    public func update(_ name: String, _ body: (inout Binding) -> Void) {
        guard var binding = map[name] else { return }
        body(&binding)
        map[name] = binding
    }

    /// All bindings in insertion order.
    public var bindings: [(String, Binding)] {
        order.compactMap { name in map[name].map { (name, $0) } }
    }

    public var count: Int { map.count }
}

/// Scopes on the evaluation stack. Port of `Scopes`.
///
/// Layout matches upstream: a dedicated `top` scope (innermost), a stack
/// of entered scopes, and an immutable `base` (global library) scope.
public struct Scopes {
    /// The innermost scope.
    public var top: Scope
    /// Entered scopes, innermost last.
    public private(set) var stack: [Scope] = []
    /// The base library scope (read-only for mutations).
    public let base: Scope?

    public init(base: Scope?) {
        self.base = base
        self.top = Scope()
    }

    /// Enter a new scope.
    public mutating func enter() {
        stack.append(top)
        top = Scope()
    }

    /// Push an existing scope as the new innermost scope.
    /// Port of upstream `Scopes::scopes.push`.
    public mutating func push(_ scope: Scope) {
        stack.append(top)
        top = scope
    }

    /// Exit the topmost scope.
    public mutating func exit() {
        precondition(!stack.isEmpty, "no pushed scope")
        top = stack.removeLast()
    }

    /// Look up a variable through all scopes.
    public func get(_ name: String, guard access: any BindingGuard) -> HintedStrResult<Value> {
        for scope in [top] + stack.reversed() {
            if let binding = scope.get(name) {
                return readBinding(binding, name: name, access: access)
            }
        }
        if let base, let binding = base.get(name) {
            return readBinding(binding, name: name, access: access)
        }
        return .failure(unknownVariable(name))
    }

    /// Look up a variable in math mode. Currently aliases `get`; upstream
    /// resolves through `base.math` and emits the math-flavored
    /// unknown-variable diagnostic — lands with the math scope milestone.
    public func getInMath(_ name: String, guard access: any BindingGuard) -> HintedStrResult<Value> {
        get(name, guard: access)
    }

    /// Look up a binding in math mode. Currently aliases `getBinding`;
    /// upstream resolves through `base.math` and emits the math-flavored
    /// unknown-variable diagnostic — lands with the math scope milestone.
    public func getBindingInMath(_ name: String) -> HintedStrResult<Binding> {
        getBinding(name)
    }

    /// Look up a binding itself.
    public func getBinding(_ name: String) -> HintedStrResult<Binding> {
        for scope in [top] + stack.reversed() {
            if let binding = scope.get(name) { return .success(binding) }
        }
        if let base, let binding = base.get(name) { return .success(binding) }
        return .failure(unknownVariable(name))
    }

    /// Whether a name resolves to a standard-library definition.
    /// Matches upstream `check_std_shadowed`: only the base scope counts.
    public func checkStdShadowed(_ name: String) -> Bool {
        base?.get(name) != nil
    }

    func readBinding(
        _ binding: Binding,
        name: String,
        access: any BindingGuard
    ) -> HintedStrResult<Value> {
        binding.read(access).mapError { $0.cannot("access variable `\(name)`") }
    }

    /// Access a binding's value mutably (read-modify-write), searching
    /// `top` then entered scopes. The base scope is immutable — upstream
    /// reports `cannot mutate a constant` / `unknown variable`.
    public mutating func getMut<T>(
        _ name: String,
        span _: Span,
        guard access: any BindingGuard,
        _ body: (inout Value) throws -> T
    ) -> HintedStrResult<T> {
        for scope in [top] + stack.reversed() {
            if scope.get(name) != nil {
                var result: HintedStrResult<T>?
                scope.update(name) { binding in
                    switch binding.write(access) {
                    case .failure(let error):
                        result = .failure(error.cannot("access variable `\(name)`"))
                    case .success:
                        do {
                            result = .success(try body(&binding.value))
                        } catch let error as HintedString {
                            result = .failure(error)
                        } catch {
                            result = .failure(HintedString("\(error)"))
                        }
                    }
                }
                if let result { return result }
            }
        }
        if base?.get(name) != nil {
            return .failure(cannotMutateConstant(name))
        }
        if name == "std" {
            return .failure(cannotMutateConstant(name))
        }
        return .failure(unknownVariable(name))
    }
}

/// Error for mutating a standard-library binding.
func cannotMutateConstant(_ name: String) -> HintedString {
    HintedString("cannot mutate a constant")
        .withHint("`\(name)` is a standard library definition")
}

func unknownVariable(_ name: String) -> HintedString {
    var res = HintedString("unknown variable `\(name)`")
    if name.contains("-") {
        let dashes = name.filter { $0 == "-" }.count
        res.hint(
            "if you meant to use subtraction, try adding spaces around the minus sign"
                + (dashes > 1 ? "s" : "")
                + ": `\(name.replacingOccurrences(of: "-", with: " - "))`"
        )
    }
    return res
}

/// The math-mode unknown-variable diagnostic. Port of
/// `unknown_variable_math`.
public func unknownVariableMath(_ name: String, inGlobal: Bool) -> HintedString {
    var res = HintedString("unknown variable `\(name)`")
    if ["none", "auto", "false", "true"].contains(name) {
        res.hint("if you meant to use a literal, try adding a hash before it: `#\(name)`")
    } else if inGlobal {
        res.hint("`\(name)` is not available directly in math, but is in the standard library")
        res.hint("to access `\(name)` in code mode you can add a hash: `#\(name)`")
        res.hint("or access `\(name)` in math mode by using the `std` module: `std.\(name)`")
    } else {
        let spaced = name.map { " \($0)" }.dropFirst().joined()
        res.hint("if you meant to display multiple letters as is, try adding spaces between each letter: `\(spaced)`")
        res.hint("or if you meant to display this as text, try placing it in quotes: `\"\(name)\"`")
    }
    return res
}
