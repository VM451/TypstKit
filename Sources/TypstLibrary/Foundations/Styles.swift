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

    /// Apply the recipe to content. Requires an engine for function calls —
    /// returns the content directly for content transforms.
    public func apply(to content: Content) -> HintedStrResult<Content> {
        switch transform {
        case let .content(c): return .success(c)
        case .function:
            return .failure(HintedString("cannot apply function recipe without engine"))
        }
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

    public init(head: ArraySlice<LazyHash<Style>>, tail: StyleChain? = nil) {
        self.head = head
        self.tail = tail.map(StyleChainTail.init)
    }

    /// Start a chain over root styles.
    public static func new(root: Styles) -> StyleChain {
        StyleChain(head: root.items[...], tail: nil)
    }

    /// Push additional styles on top (innermost).
    public func pushed(_ styles: Styles) -> StyleChain {
        StyleChain(head: styles.items[...], tail: self)
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
    static func fold(_ lhs: Self, _ rhs: Self) -> Self
}

extension Fold {
    /// Default: outer value wins is NOT the semantics; provide concrete impls.
}
