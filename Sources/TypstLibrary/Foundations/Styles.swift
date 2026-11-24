import Foundation
import TypstSyntax
import TypstUtils

/// A sequence of style items.
///
/// Port of `Styles` in `styles.rs` — an ordered list of style entries.
public struct Styles: Sendable, Hashable {
    /// The style entries in application order.
    public private(set) var items: [LazyHash<Style>] = []

    public init() {}

    /// Create from style values.
    public init(_ styles: [Style]) {
        items = styles.map { LazyHash($0) }
    }

    /// Create from pre-hashed style entries.
    init(lazyItems: [LazyHash<Style>]) {
        items = lazyItems
    }

    public var isEmpty: Bool { items.isEmpty }

    /// All entries.
    public var entries: [LazyHash<Style>] { items }

    /// Whether any property for `elem`.`field` exists.
    public func has(_ elem: Element, _ field: UInt8) -> Bool {
        items.contains { style in
            guard case let .property(p) = style.value else { return false }
            return p.elem == elem && p.field == field
        }
    }

    /// Append styles.
    public mutating func append(_ style: Style) {
        items.append(LazyHash(style))
    }

    /// Append a property.
    public mutating func append(_ property: Property) {
        append(.property(property))
    }

    /// Concatenate.
    public static func + (lhs: Styles, rhs: Styles) -> Styles {
        var result = lhs
        result.items.append(contentsOf: rhs.items)
        return result
    }
}

extension Styles {
    /// Add an origin span to all contained properties.
    /// Port of `Styles::spanned`.
    public func spanned(_ span: Span) -> Styles {
        Styles(items.map { $0.value.mapStyleSpanned(span) })
    }

    /// Marks the styles as being allowed to be lifted up to the page level.
    /// Port of `Styles::liftable`.
    public func liftable() -> Styles {
        Styles(items.map { $0.value.mapLiftable() })
    }
}

extension Styles: Repr {
    public func repr() -> String { "styles(..)" }
}

/// A single style item.
///
/// Port of `Style` in `styles.rs`.
public enum Style: Sendable, Hashable {
    /// A set-rule property or constructor argument.
    case property(Property)
    /// A show-rule recipe.
    case recipe(Recipe)
    /// Disables a specific show-rule recipe (regex recipes only upstream).
    case revocation(RecipeIndex)

    /// The span the style was written at.
    public var span: Span {
        switch self {
        case let .property(p): return p.span
        case let .recipe(r): return r.span
        case .revocation: return .detached
        }
    }

    /// The element this style targets, if determinable.
    public var element: Element? {
        switch self {
        case let .property(p): return p.elem
        case let .recipe(r):
            if case let .elem(elem, _) = r.selector { return elem }
            return nil
        case .revocation: return nil
        }
    }

    /// Whether the style may be lifted to page level.
    public var liftable: Bool {
        switch self {
        case let .property(p): return p.liftable
        case .recipe: return true
        case .revocation: return false
        }
    }

    /// Return a copy with property spans set (recipes keep their own).
    func mapStyleSpanned(_ span: Span) -> Style {
        switch self {
        case var .property(p):
            p.span = span
            return .property(p)
        default:
            return self
        }
    }

    /// Return a copy with `liftable` set on properties.
    func mapLiftable() -> Style {
        switch self {
        case var .property(p):
            p.liftable = true
            return .property(p)
        default:
            return self
        }
    }

    /// Whether applied outside any show rule (set during realization).
    public var outside: Bool {
        switch self {
        case let .property(p): return p.outside
        case let .recipe(r): return r.outside
        case .revocation: return false
        }
    }
}

/// A style property: an element field set by a set rule or constructor.
///
/// Port of `Property` in `styles.rs`. Upstream stores the value type-erased
/// in a `Block`; this port stores the `Value` (field casts happen through
/// the element's field descriptors).
public struct Property: Sendable, Hashable {
    /// The element the property belongs to.
    public var elem: Element

    /// The field's id within the element.
    public var field: UInt8

    /// The property's value.
    public var value: Value

    /// The span of the set rule.
    public var span: Span

    /// Whether the property may be lifted to page level.
    public var liftable: Bool

    /// Whether applied outside any show rule.
    public var outside: Bool

    public init(elem: Element, field: UInt8, value: Value, span: Span = .detached,
                liftable: Bool = true, outside: Bool = false) {
        self.elem = elem
        self.field = field
        self.value = value
        self.span = span
        self.liftable = liftable
        self.outside = outside
    }

    /// Whether this property targets `elem`.`field`.
    public func `is`(_ elem: Element, _ field: UInt8) -> Bool {
        self.elem == elem && self.field == field
    }
}

/// A show-rule recipe.
///
/// Port of `Recipe` in `styles.rs`.
public struct Recipe: Sendable, Hashable {
    /// Which elements the recipe applies to (`nil` = eager `show: f`).
    public var selector: Selector?

    /// What to do with matches.
    public var transform: Transformation

    /// Span for error reporting.
    public var span: Span

    /// Whether applied outside any show rule.
    public var outside: Bool

    public init(selector: Selector?, transform: Transformation, span: Span = .detached) {
        self.selector = selector
        self.transform = transform
        self.span = span
        self.outside = false
    }

    /// Apply the recipe to the given content.
    /// Port of `Recipe::apply` in `styles.rs`.
    public func apply(engine: inout Engine, context: Context,
                      content: Content) throws -> Content {
        var result = content
        switch transform {
        case let .content(c):
            result = c
        case let .function(function):
            // This already adds definition site of the show rule to the
            // trace.
            var call = function.callValue(
                engine: &engine, context: context,
                args: Args(span: span, values: [content]),
                span: span)
            // Also add the application site of the show rule to the trace.
            if selector != nil {
                call = call.traced(.show(content.`func`.name ?? content.name), at: span)
            }
            result = try unwrap(call).display
        case let .style(styles):
            result = result.styledWithMap(styles)
        }
        if result.span == .detached {
            result = result.spanned(span)
        }
        return result
    }
}

/// The transformation a recipe performs.
///
/// Port of `Transformation` in `styles.rs`.
public enum Transformation: Sendable, Hashable {
    /// Replace with fixed content.
    case content(Content)
    /// Call a function with the matched content.
    case function(Func)
    /// Apply a style map to the matched content (`show sel: set ..`).
    case style(Styles)
}

/// Index of a recipe within a style list (for revocations).
public struct RecipeIndex: Sendable, Hashable {
    public var index: Int
    public init(_ index: Int) { self.index = index }
}

/// An ordered chain of style lists, innermost first.
///
/// Port of `StyleChain` in `styles.rs`. Instead of Rust lifetimes, slices
/// share the underlying array storage copy-on-write.
/// Reference box for a style chain tail. Upstream stores `&'a StyleChain`
/// links; Swift needs a class to break the recursive value type.
final class StyleChainTail: @unchecked Sendable {
    let chain: StyleChain
    init(_ chain: StyleChain) { self.chain = chain }
}

public struct StyleChain: Sendable {
    /// The first (innermost) link's styles.
    var head: ArraySlice<LazyHash<Style>>

    /// The remaining (outer) links.
    var tail: StyleChainTail?

    /// Identity of the head slice's buffer, used for upstream-style pointer
    /// equality (`StyleChain::eq` compares slice and tail pointers). Two
    /// chains pushed from the same `Styles` storage share a head id; a
    /// copy-on-write mutation yields a fresh id.
    let headID: UInt

    public init(head: ArraySlice<LazyHash<Style>>, tail: StyleChain? = nil) {
        self.head = head
        self.tail = tail.map(StyleChainTail.init)
        self.headID = head.withUnsafeBufferPointer {
            $0.baseAddress.map { UInt(bitPattern: $0) } ?? 0
        }
    }

    /// Start a chain over root styles.
    public static func new(root: Styles) -> StyleChain {
        StyleChain(head: root.items[...], tail: nil)
    }

    /// Push additional styles on top (innermost).
    /// Port of upstream `[LazyHash<Style>]::chain` — an empty style list does
    /// not create a new link.
    public func pushed(_ styles: Styles) -> StyleChain {
        guard !styles.isEmpty else { return self }
        return StyleChain(head: styles.items[...], tail: self)
    }

    /// All properties for `(elem, field)` from innermost to outermost.
    public func properties(_ elem: Element, _ field: UInt8) -> [Property] {
        var result: [Property] = []
        var chain: StyleChain? = self
        while let link = chain {
            // Iterate this link's head in reverse (later = inner).
            for style in link.head.reversed() {
                if case let .property(p) = style.value, p.`is`(elem, field) {
                    result.append(p)
                }
            }
            chain = link.tail?.chain
        }
        return result
    }

    /// Whether a property exists for `(elem, field)`.
    public func has(_ elem: Element, _ field: UInt8) -> Bool {
        !properties(elem, field).isEmpty
    }

    /// Get the innermost value for `(elem, field)`, or `nil`.
    /// Equivalent to `getValue`; kept for upstream API parity.
    public func get(_ elem: Element, _ field: UInt8) -> Value? {
        getValue(elem, field)
    }

    /// Get with explicit ordering: innermost wins.
    public func getValue(_ elem: Element, _ field: UInt8) -> Value? {
        var chain: StyleChain? = self
        while let link = chain {
            for style in link.head.reversed() {
                if case let .property(p) = style.value, p.`is`(elem, field) {
                    return p.value
                }
            }
            chain = link.tail?.chain
        }
        return nil
    }

    /// Get a field value folded across all matching properties.
    /// `fold` combines accumulated value with each property, innermost last.
    public func getFolded<T>(_ elem: Element, _ field: UInt8,
                             fold: (T, Value) -> T?, initial: T) -> T? {
        let props = properties(elem, field)
        guard !props.isEmpty else { return nil }
        var acc = initial
        // Upstream folds from outermost to innermost.
        for p in props.reversed() {
            guard let next = fold(acc, p.value) else { return nil }
            acc = next
        }
        return acc
    }
}

/// A field that can be set via set rules.
///
/// Swift port of upstream's const-generic `Field<E, I>`: identified by the
/// element + field id pair.
public struct FieldRef: Sendable, Hashable {
    public var elem: Element
    public var id: UInt8
    public init(elem: Element, id: UInt8) {
        self.elem = elem; self.id = id
    }
}

/// Resolution of a stored value into its output type.
///
/// Port of `Resolve` in `styles.rs`.
public protocol Resolve {
    associatedtype Output
    func resolve(_ styles: StyleChain) -> Output
}

/// Folding of multiple style values.
///
/// Port of `Fold` in `styles.rs`.
public protocol Fold {
    /// `lhs` is the inner value, `rhs` the outer one.
    static func fold(_ lhs: Self, _ rhs: Self) -> Self
}

extension Bool: Fold {
    /// The inner value wins (upstream `Fold for bool`).
    public static func fold(_ lhs: Bool, _ rhs: Bool) -> Bool { lhs }
}

extension Optional: Fold where Wrapped: Fold {
    /// `(some, some)` folds; an explicit inner `nil` is respected and
    /// otherwise the inner value wins (upstream `Fold for Option<T>`).
    public static func fold(_ lhs: Self, _ rhs: Self) -> Self {
        switch (lhs, rhs) {
        case let (.some(inner), .some(outer)):
            return .some(Wrapped.fold(inner, outer))
        case let (inner, _):
            return inner
        }
    }
}

extension Smart: Fold where T: Fold {
    /// `(custom, custom)` folds; an explicit inner `auto` is respected
    /// (upstream `Fold for Smart<T>`).
    public static func fold(_ lhs: Smart<T>, _ rhs: Smart<T>) -> Smart<T> {
        switch (lhs, rhs) {
        case let (.custom(inner), .custom(outer)):
            return .custom(T.fold(inner, outer))
        case let (inner, _):
            return inner
        }
    }
}

/// A variant of fold for optional values where an inner `nil` means
/// "unspecified" rather than "absent" (upstream `AlternativeFold`).
public protocol AlternativeFold {
    static func foldOr(_ lhs: Self, _ rhs: Self) -> Self
}

extension Optional: AlternativeFold where Wrapped: Fold {
    /// `(some, some)` folds; otherwise whichever side is `some` wins.
    public static func foldOr(_ lhs: Self, _ rhs: Self) -> Self {
        switch (lhs, rhs) {
        case let (.some(inner), .some(outer)):
            return .some(Wrapped.fold(inner, outer))
        case let (inner, outer):
            return inner ?? outer
        }
    }
}


extension Element {
    /// Execute the set rule for the element and return the resulting
    /// style map. Port of `Element::set` in `element.rs`.
    ///
    /// Elements with a custom `setImpl` use it; otherwise settable fields
    /// are parsed generically from named arguments.
    public func set(engine: inout Engine, args: inout Args) throws -> Styles {
        let styles = try setStyles(engine: &engine, args: &args)
        try unwrap(args.finish())
        return styles
    }

    /// The set-rule style map without consuming/finishing the arguments.
    /// Used by element constructors (`text`, `page`) that call `set` and
    /// then parse a body argument, mirroring upstream's `Self::set`.
    func setStyles(engine: inout Engine, args: inout Args) throws -> Styles {
        var styles: Styles
        if let setImpl = info.setImpl {
            styles = try setImpl(&engine, &args)
        } else {
            var collected: [Style] = []
            for field in info.fields where field.settable {
                let named: Value? = try unwrap(args.named(field.name))
                if let value = named {
                    collected.insert(.property(Property(
                        elem: self, field: field.id, value: value)), at: 0)
                }
            }
            styles = Styles(collected)
        }
        return styles
    }
}

extension Content {
    /// Style this content with a recipe, eagerly applying it if possible.
    /// Port of `Content::styled_with_recipe`.
    public func styledWithRecipe(engine: inout Engine, context: Context,
                                 recipe: Recipe) throws -> Content {
        if recipe.selector == nil {
            return try recipe.apply(engine: &engine, context: context,
                                    content: self)
        }
        return styledWithMap(Styles([.recipe(recipe)]))
    }
}


extension Transformation: Castable, FromValue {
    public static var input: CastInfo { Content.input + Func.input }
    public static var output: CastInfo { .any }

    public static func castable(_ value: Value) -> Bool {
        Content.castable(value) || Func.castable(value)
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch Content.fromValue(value) {
        case .success(let content): return .success(.content(content))
        case .failure:
            switch Func.fromValue(value) {
            case .success(let function): return .success(.function(function))
            case .failure: break
            }
        }
        return .failure(HintedString("expected content or function"))
    }

    // `Transformation::Style` has no `IntoValue` upstream (unreachable in
    // the `cast!` macro) — only `FromValue` is needed for show-rule eval.
}

extension ShowableSelector: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        Symbol.input + Str.input + Label.input + Func.input + Regex.input
            + Selector.input
    }
    public static var output: CastInfo { .type(Type.of(Selector.self)) }

    public static func castable(_ value: Value) -> Bool {
        Symbol.castable(value) || Str.castable(value) || Label.castable(value)
            || Func.castable(value) || Regex.castable(value)
            || Selector.castable(value)
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if !castable(value) {
            return .failure(HintedString("expected symbol, string, label, function, regex, or selector"))
        }
        return Selector.fromValue(value).flatMap { selector in
            do {
                try validateShowable(selector, nested: false)
                return .success(ShowableSelector(selector))
            } catch let error as HintedString {
                return .failure(error)
            } catch {
                return .failure(HintedString("\(error)"))
            }
        }
    }

    public func intoValue() -> Value { .dynamic(selector) }
}

/// Validate that a selector can be used with `show`.
/// Port of the `validate` closure in `ShowableSelector::from_value`.
private func validateShowable(_ selector: Selector,
                              nested: Bool) throws {
    switch selector {
    case .elem, .label:
        break
    case .regex where !nested:
        break
    case let .or(list), let .and(list):
        for sel in list {
            try validateShowable(sel, nested: true)
        }
    case .regex, .location, .can, .before, .after:
        throw HintedString("this selector cannot be used with show")
    case .within:
        throw HintedString("this selector cannot currently be used with show")
            .withHint("support for this is planned for the future")
    }
}

// MARK: - StyleChain realization support

extension Style {
    /// The property, if this is a property style.
    public var property: Property? {
        if case let .property(p) = self { return p }
        return nil
    }

    /// The recipe, if this is a recipe style.
    public var recipe: Recipe? {
        if case let .recipe(r) = self { return r }
        return nil
    }
}

extension Styles {
    /// Iterate over the contained styles.
    /// Port of upstream `Styles::iter`.
    public func iter() -> [Style] { items.map(\.value) }

    /// Apply outer styles. Like `StyleChain.chain`, but in-place.
    /// Port of upstream `Styles::apply`.
    public mutating func apply(_ outer: Styles) {
        var merged = outer
        merged.items.append(contentsOf: items)
        self = merged
    }

    /// Marks the styles as having been applied outside of any show rule.
    /// Port of upstream `Styles::outside`.
    public func outside() -> Styles {
        var copy = self
        for i in copy.items.indices {
            switch copy.items[i].value {
            case var .property(p):
                p.outside = true
                copy.items[i] = LazyHash(.property(p))
            case var .recipe(r):
                r.outside = true
                copy.items[i] = LazyHash(.recipe(r))
            case .revocation:
                break
            }
        }
        return copy
    }
}

extension StyleChain {
    /// An empty style chain.
    /// Port of upstream `StyleChain::default`.
    public init() {
        self.init(head: [][...], tail: nil)
    }

    /// Iterate over the entries of the chain, innermost position first.
    /// Port of upstream `StyleChain::entries`.
    public func entries() -> [LazyHash<Style>] {
        var result: [LazyHash<Style>] = []
        var link: StyleChain? = self
        while let l = link {
            result.append(contentsOf: l.head.reversed())
            link = l.tail?.chain
        }
        return result
    }

    /// Iterate over the links of the chain, innermost first.
    /// Port of upstream `StyleChain::links`.
    public func links() -> [[LazyHash<Style>]] {
        var result: [[LazyHash<Style>]] = []
        var link: StyleChain? = self
        while let l = link {
            result.append(Array(l.head))
            link = l.tail?.chain
        }
        return result
    }

    /// Iterate over the recipes in the chain.
    /// Port of upstream `StyleChain::recipes`.
    public func recipes() -> [Recipe] {
        entries().compactMap { entry in
            if case let .recipe(r) = entry.value { return r }
            return nil
        }
    }

    /// Make the given styles the first (innermost) link of this chain.
    /// Port of upstream `StyleChain::chain` for `Styles`.
    public func chain(_ local: Styles) -> StyleChain {
        local.isEmpty ? self : pushed(local)
    }

    /// Build owned styles from the suffix (all links beyond the `len`) of the
    /// chain.
    /// Port of upstream `StyleChain::suffix`.
    public func suffix(_ len: Int) -> Styles {
        let all = links()
        let take = max(all.count - len, 0)
        var items: [LazyHash<Style>] = []
        for link in all.prefix(take) {
            items.append(contentsOf: link.reversed())
        }
        items.reverse()
        return Styles(lazyItems: items)
    }

    /// Remove the last (innermost) link from the chain.
    /// Port of upstream `StyleChain::pop`.
    public mutating func pop() {
        self = tail?.chain ?? StyleChain()
    }

    /// Determine the shared trunk of a collection of style chains.
    /// Port of upstream `StyleChain::trunk`.
    public static func trunk<S: Sequence>(_ iter: S) -> StyleChain?
    where S.Element == StyleChain {
        var iter = iter.makeIterator()
        guard var trunk = iter.next() else { return nil }
        var depth = trunk.links().count

        while var chain = iter.next() {
            let len = chain.links().count
            if len < depth {
                for _ in 0..<(depth - len) { trunk.pop() }
                depth = len
            } else if len > depth {
                for _ in 0..<(len - depth) { chain.pop() }
            }

            while depth > 0 && chain != trunk {
                trunk.pop()
                chain.pop()
                depth -= 1
            }
        }

        return trunk
    }

    /// Determines the shared trunk of a list of elements.
    /// This will ignore styles for tags (conceptually, they just don't exist).
    /// Port of upstream `StyleChain::trunk_from_pairs`.
    public static func trunkFromPairs(_ pairs: [(Content, StyleChain)]) -> StyleChain? {
        trunk(pairs.filter { !$0.0.is(TagElem.self) }.map(\.1))
    }
}

extension StyleChain: Equatable {
    /// Port of upstream `StyleChain::eq` — pointer equality of the head slice
    /// and tail link. Value-equal chains built through separate `chain` calls
    /// may compare unequal (as upstream's allocation identity would), which is
    /// the conservative direction for `trunk`/`suffix` computations.
    public static func == (a: StyleChain, b: StyleChain) -> Bool {
        a.headID == b.headID && a.tail === b.tail
    }
}

// MARK: - Native show rules

/// The show rule for a native element.
///
/// Port of `NativeShowRule` in `foundations/styles.rs`.
public struct NativeShowRule: Sendable {
    /// The element to which this rule applies.
    public let elem: Element
    /// Applies the rule to content. Must only be called with content of the
    /// appropriate type.
    public let apply: @Sendable (Content, inout Engine, StyleChain) -> SourceResult<Content>

    public init(
        _ f: @escaping @Sendable (Content, inout Engine, StyleChain) -> SourceResult<Content>,
        elem: Element
    ) {
        self.elem = elem
        self.apply = f
    }
}

/// Holds native show rules.
///
/// Port of `NativeRuleMap` in `foundations/styles.rs`.
public final class NativeRuleMap: @unchecked Sendable {
    private var rules: [RuleKey: NativeShowRule] = [:]

    private struct RuleKey: Hashable {
        var elem: Element
        var target: Target
    }

    public init() {}

    /// Registers a rule for a target.
    ///
    /// Port of upstream `NativeRuleMap::register`.
    public func register(
        elem: Element,
        target: Target,
        _ f: @escaping @Sendable (Content, inout Engine, StyleChain) -> SourceResult<Content>
    ) {
        let rule = NativeShowRule(f, elem: elem)
        rules[RuleKey(elem: elem, target: target)] = rule
    }

    /// Retrieves the rule that applies to the `content` on the current
    /// `target`.
    ///
    /// Port of upstream `NativeRuleMap::get`.
    public func get(target: Target, content: Content) -> NativeShowRule? {
        rules[RuleKey(elem: content.elem, target: target)]
    }
}

extension Array: Fold {
    /// Outer items first, then inner appended (upstream `Fold for Vec<T>`).
    public static func fold(_ inner: [Element], _ outer: [Element]) -> [Element] {
        outer + inner
    }
}

extension Spanned: Fold where T: Fold, S == Span {
    /// Fold the values; the inner span wins unless it is detached
    /// (upstream `Spanned::fold` — `self.span.or(outer.span)`).
    public static func fold(
        _ inner: Spanned<T, Span>, _ outer: Spanned<T, Span>
    ) -> Spanned<T, Span> {
        Spanned(
            T.fold(inner.value, outer.value),
            span: inner.span.or(outer.span)
        )
    }
}
