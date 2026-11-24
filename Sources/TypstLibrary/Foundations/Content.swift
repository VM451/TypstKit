import Foundation
import TypstSyntax
import TypstUtils

/// A type-erased element instance.
///
/// Port of upstream's `Packed<dyn NativeElement>`/`RawContent` pair: the
/// element value plus its metadata (span/label/location/lifecycle) lives
/// in `Content`; `PackedElement` carries the type identity and data hash.
public struct PackedElement: Sendable {
    /// The type-erased element value.
    public var element: any NativeElement

    /// The element's type identity.
    public let elem: Element

    /// Cached hash of the element data (excludes content metadata).
    public private(set) var hash: Hash128

    public init<T: NativeElement>(_ element: T) {
        self.element = element
        self.elem = Element(T.self)
        self.hash = hash128(element as any Hashable)
    }

    /// Mutate the element, refreshing its data hash.
    public mutating func mutate<T>(_ body: (inout T) -> Void) where T: NativeElement {
        guard var typed = element as? T else { return }
        body(&typed)
        element = typed
        hash = hash128(typed)
    }
    /// Mutate the type-erased element through an existential, refreshing its
    /// data hash. Used for capability-protocol mutation (e.g. `Synthesize`).
    public mutating func mutateAny(
        _ body: (inout any NativeElement) throws -> Void
    ) throws {
        var typed = element
        try body(&typed)
        element = typed
        hash = hash128(typed)
    }
}

extension PackedElement: Hashable {
    public static func == (a: PackedElement, b: PackedElement) -> Bool {
        a.elem == b.elem && a.element.elementEquals(b.element)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(elem)
        hasher.combine(hash)
    }
}

/// A laid-out document tree node.
///
/// Port of `Content` in `content/mod.rs`. Unlike upstream's manual fat
/// pointer, this is a value type wrapping a `PackedElement` plus metadata.
public struct Content: Sendable {
    /// The packed element.
    public private(set) var packed: PackedElement

    /// The content's span.
    public var span: Span

    /// An optional label.
    public var label: Label?

    /// The element's location in the laid-out output.
    public var location: Location?

    /// Lifecycle bitset: bit 0 = prepared; bit n = guarded against
    /// the n-th show rule recipe (counting from 1).
    public var lifecycle: Set<Int>

    /// Create content from an element.
    public init<T: NativeElement>(_ element: T, span: Span = .detached) {
        packed = PackedElement(element)
        self.span = span
        label = nil
        location = nil
        lifecycle = []
    }

    /// Wrap an existing packed element.
    public init(packed: PackedElement, span: Span = .detached) {
        self.packed = packed
        self.span = span
        label = nil
        location = nil
        lifecycle = []
    }

    /// The empty sequence.
    public static let empty = Content(SequenceElem(children: []))

    /// The element type of this content.
    public var elem: Element { packed.elem }

    /// The function producing this content's element.
    public var `func`: Func { Func(inner: .element(packed.elem)) }

    /// The element's name.
    public var name: String { packed.elem.name }

    /// Attach a span (only if currently detached).
    public func spanned(_ span: Span) -> Content {
        var copy = self
        if copy.span.isDetached { copy.span = span }
        return copy
    }

    /// Attach a label.
    public func labelled(_ label: Label) -> Content {
        var copy = self
        copy.label = label
        return copy
    }

    /// Set the label in place.
    public mutating func setLabel(_ label: Label) { self.label = label }

    /// Assign a location.
    public func located(_ loc: Location) -> Content {
        var copy = self
        copy.location = loc
        return copy
    }

    /// Set the location in place.
    public mutating func setLocation(_ location: Location) { self.location = location }

    /// Whether guarded against the given recipe index.
    public func isGuarded(_ index: RecipeIndex) -> Bool {
        lifecycle.contains(index.index + 1)
    }

    /// Return a copy guarded against the given recipe.
    public func guarded(_ index: RecipeIndex) -> Content {
        var copy = self
        copy.lifecycle.insert(index.index + 1)
        return copy
    }

    /// Whether this content is marked prepared (realization done).
    public var isPrepared: Bool { lifecycle.contains(0) }

    /// Mark as prepared.
    public mutating func markPrepared() { lifecycle.insert(0) }

    /// Get a field by id without styles.
    public func get(_ id: UInt8, styles: StyleChain? = nil) -> Result<Value, FieldAccessError> {
        if id == 255 {
            if let label { return .success(.label(label)) }
            return .failure(.unknown)
        }
        guard packed.elem.field(id) != nil else { return .failure(.unknown) }
        if let styles {
            // Style-aware read: element's materialized value or style chain.
            if let value = packed.element.field(id) {
                return .success(value)
            }
            if let value = styles.getValue(packed.elem, id) {
                return .success(value)
            }
            return .failure(.unset)
        }
        guard let value = packed.element.field(id) else { return .failure(.unset) }
        return .success(value)
    }

    /// Get a field by name without styles.
    public func getByName(_ name: String) -> Result<Value, FieldAccessError> {
        if name == "label" {
            return label.map { .success(.label($0)) } ?? .failure(.unknown)
        }
        guard let id = packed.elem.fieldID(name) else { return .failure(.unknown) }
        guard let value = packed.element.field(id) else { return .failure(.unset) }
        return .success(value)
    }

    /// Get a field by id, producing the upstream error message.
    public func field(_ id: UInt8) -> StrResult<Value> {
        get(id).mapError { $0.message(self, packed.elem.fieldName(id) ?? "") }
    }

    /// Get a field by name, producing the upstream error message.
    public func fieldByName(_ name: String) -> StrResult<Value> {
        getByName(name).mapError { $0.message(self, name) }
    }

    /// All explicitly-set fields as a dictionary.
    public func fields() -> Dict {
        var dict = Dict()
        for info in packed.elem.info.fields {
            if let value = packed.element.field(info.id) {
                dict.insert(info.name, value)
            }
        }
        return dict
    }

    /// Set a field value on the element in place (used by constructors
    /// and materialization).
    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        var element = packed.element
        try element.setField(id, value)
        packed = PackedElement(element)
    }

    /// Style this content with a single style entry.
    public func styled(_ style: Style) -> Content {
        styledWithMap(Styles([style]))
    }

    /// Style this content with a property.
    public func set<P: SettableProperty>(_ property: P, value: P.FieldType) -> Content {
        styled(.property(Property(
            elem: P.element, field: P.fieldID, value: P.pack(value), span: span)))
    }

    /// Style with a full style map, merging into an existing StyledElem.
    public func styledWithMap(_ styles: Styles) -> Content {
        if styles.isEmpty { return self }
        if var styledElem = packed.element as? StyledElem {
            styledElem.styles = styledElem.styles + styles
            return Content(styledElem, span: span)
                .copyingMetadata(from: self)
        }
        return Content(StyledElem(child: self, styles: styles), span: span)
    }

    /// Apply styles in place.
    public mutating func styleInPlace(_ styles: Styles) {
        self = styledWithMap(styles)
    }

    /// Resolve all fields against styles and store them in place.
    public mutating func materialize(_ styles: StyleChain) {
        for info in packed.elem.info.fields where info.settable {
            if packed.element.field(info.id) == nil,
               let value = styles.getValue(packed.elem, info.id) {
                try? setField(info.id, value)
            }
        }
    }

    /// Whether this content's element is of type `T`.
    public func `is`<T: NativeElement>(_ type: T.Type) -> Bool {
        packed.element is T
    }

    /// Cast to a packed element of type `T`.
    public func to<T: NativeElement>(_ type: T.Type = T.self) -> T? {
        packed.element as? T
    }

    /// Downcast to `Packed<T>`-equivalent: returns the typed element.
    public func packed<T: NativeElement>(_ type: T.Type = T.self) -> T? {
        packed.element as? T
    }

    /// The sequence children, if this is a SequenceElem.
    public var sequenceChildren: [Content]? {
        (packed.element as? SequenceElem)?.children
    }

    /// Concatenate content.
    public static func + (lhs: Content, rhs: Content) -> Content {
        var lhs = lhs
        if var seq = lhs.packed.element as? SequenceElem {
            if let rhsSeq = rhs.packed.element as? SequenceElem {
                seq.children.append(contentsOf: rhsSeq.children)
            } else {
                seq.children.append(rhs)
            }
            lhs.packed = PackedElement(seq)
            return lhs
        }
        if var rhsSeq = rhs.packed.element as? SequenceElem {
            rhsSeq.children.insert(lhs, at: 0)
            var result = rhs
            result.packed = PackedElement(rhsSeq)
            return result
        }
        return Content.sequence([lhs, rhs])
    }

    /// Create sequence content from an iterator.
    public static func sequence<S: Sequence>(_ items: S) -> Content where S.Element == Content {
        let vec = Array(items)
        if vec.isEmpty { return .empty }
        if vec.count == 1 { return vec[0] }
        return Content(SequenceElem(children: vec))
    }

    /// Repeat content `n` times.
    public func `repeat`(times n: Int) -> StrResult<Content> {
        guard n >= 0 else {
            return .failure(StrError("cannot repeat content a negative number of times"))
        }
        if n == 0 { return .success(.empty) }
        if n == 1 { return .success(self) }
        return .success(Content.sequence(Array(repeating: self, count: n)))
    }

    /// Plain text extraction (naive, pre-realization).
    public var plainText: String {
        if let text = packed.element as? TextElem { return text.text.value }
        if let sym = packed.element as? SymbolElem { return sym.text }
        if let seq = packed.element as? SequenceElem {
            return seq.children.map(\.plainText).joined()
        }
        if let styled = packed.element as? StyledElem {
            return styled.child.plainText
        }
        return ""
    }

    /// Copy span/label/location/lifecycle from another content.
    func copyingMetadata(from other: Content) -> Content {
        var copy = self
        copy.span = other.span
        copy.label = other.label
        copy.location = other.location
        copy.lifecycle = other.lifecycle
        return copy
    }
}

extension Content: DefaultConstructible {
    public static var defaultValue: Content { .empty }
}

extension Content {
    /// Whether the packed element is math-compatible.
    /// Port of upstream's `Mathy` capability check.
    public var isMathy: Bool { packed.element is any MathyCapable }

    /// Whether the packed element synthesizes fields.
    /// Port of upstream's `Synthesize` capability check.
    public var isSynthesizing: Bool { packed.element is any SynthesizeCapable }

    /// Whether the packed element defines show-set rules.
    /// Port of upstream's `ShowSet` capability check.
    public var isShowSettable: Bool { packed.element is any ShowSetCapable }

    /// Run `Synthesize::synthesize` on the packed element if it conforms.
    public mutating func synthesizeElement(engine: inout Engine,
                                           styles: StyleChain) throws {
        try packed.mutateAny { element in
            guard var synth = element as? any SynthesizeCapable else { return }
            try synth.synthesize(engine: &engine, styles: styles)
            element = synth as any NativeElement
        }
    }

    /// Run `Synthesize::synthesize`, discarding errors (pre-synthesis).
    public mutating func trySynthesizeElement(engine: inout Engine,
                                              styles: StyleChain) {
        try? synthesizeElement(engine: &engine, styles: styles)
    }

    /// The `ShowSet` styles for the packed element, if it conforms.
    public func showSetStyles(styles: StyleChain) -> Styles? {
        (packed.element as? any ShowSetCapable)?.showSet(styles: styles)
    }
}

extension Content: Hashable {
    public static func == (a: Content, b: Content) -> Bool {
        a.packed == b.packed && a.label == b.label && a.location == b.location
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(packed)
        hasher.combine(label)
        hasher.combine(location)
    }
}

extension Content: CustomDebugStringConvertible {
    public var debugDescription: String { "Content(\(name))" }
}

extension Content: Repr {
    public func repr() -> String {
        switch packed.element {
        case let seq as SequenceElem:
            if seq.children.isEmpty { return "[]" }
            return "sequence" + prettyArrayLike(seq.children.map { $0.repr() }, trailingComma: false)
        case let styled as StyledElem:
            return "styled(child: \(styled.child.repr()), ..)"
        default:
            let fields = packed.elem.info.fields.compactMap { info -> String? in
                packed.element.field(info.id).map { "\(info.name): \($0.repr())" }
            }
            if fields.isEmpty { return name }
            return "\(name)" + prettyArrayLike(fields.map { $0 }, trailingComma: false)
        }
    }
}

/// Error when accessing a content field.
public enum FieldAccessError: Sendable, Hashable, Error {
    case unknown
    case unset

    /// The upstream error message.
    public func message(_ content: Content, _ field: String) -> StrError {
        let elemName = content.elem.name
        switch self {
        case .unknown:
            return StrError("\(elemName) does not have field \(field.typstRepr)")
        case .unset:
            return StrError("field \(field.typstRepr) in \(elemName) is not known at this point")
        }
    }

    /// The `at` error without a default value.
    public func messageNoDefault(_ content: Content, _ field: String) -> StrError {
        StrError(message(content, field).message + " and no default was specified")
    }
}

// MARK: - Element infrastructure

/// Metadata describing an element type.
///
/// Swift port of upstream's `ContentVtable` + `ElementInfo`: all element
/// behavior that upstream stores as function pointers lives here as data
/// plus protocol requirements on `NativeElement`.
public final class ElementInfo: @unchecked Sendable {
    /// The element's name (e.g. "text", "heading").
    public let name: String

    /// Human-readable title.
    public let title: String

    /// Documentation.
    public let docs: String

    /// Search keywords.
    public let keywords: [String]

    /// Version since which the element exists.
    public let since: Since?

    /// Definition site for IDE tooling.
    public let defSite: DefSite?

    /// The element's associated scope (e.g. `text` has sub-definitions).
    public let scope: Scope?

    /// Constructor parameter info.
    public let params: [NativeParamInfo]

    /// The element's fields in id order.
    public let fields: [FieldInfo]

    /// Capabilities (locatable, labelled, counted, etc.).
    public let capabilities: Capabilities

    /// Field name → id lookup.
    public let fieldIDs: [String: UInt8]

    /// Function implementing this element's constructor/set behavior.
    /// Receives args, returns the styles produced by a set rule.
    public let setImpl: (@Sendable (inout Engine, inout Args) throws -> Styles)?

    public init(name: String, title: String = "", docs: String = "",
                keywords: [String] = [], since: Since? = nil,
                defSite: DefSite? = nil,
                scope: Scope? = nil, params: [NativeParamInfo] = [],
                fields: [FieldInfo] = [], capabilities: Capabilities = [],
                setImpl: (@Sendable (inout Engine, inout Args) throws -> Styles)? = nil) {
        self.name = name
        self.title = title
        self.docs = docs
        self.keywords = keywords
        self.since = since
        self.defSite = defSite
        self.scope = scope
        self.params = params
        self.fields = fields
        self.capabilities = capabilities
        self.setImpl = setImpl
        var map: [String: UInt8] = [:]
        for f in fields { map[f.name] = f.id }
        self.fieldIDs = map
    }

    /// Look up a field id by name.
    public func fieldID(_ name: String) -> UInt8? { fieldIDs[name] }

    /// Look up field info by name.
    public func field(named name: String) -> FieldInfo? {
        fields.first { $0.name == name }
    }

    /// Look up field name by id.
    public func fieldName(_ id: UInt8) -> String? {
        fields.first { $0.id == id }?.name
    }
}

/// Element capabilities bitset.
public struct Capabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Can be located/introspected.
    public static let locatable = Capabilities(rawValue: 1 << 0)
    /// Can carry a label.
    public static let labelled = Capabilities(rawValue: 1 << 1)
    /// Participates in counting.
    public static let counted = Capabilities(rawValue: 1 << 2)
    /// Can be queried.
    public static let queriable = Capabilities(rawValue: 1 << 3)
    /// Appears in tagged PDF output.
    public static let tagged = Capabilities(rawValue: 1 << 4)
    /// Cannot be labelled (upstream `Unlabellable` marker).
    public static let unlabellable = Capabilities(rawValue: 1 << 5)
}

/// A field's metadata.
public struct FieldInfo: Sendable, Hashable {
    public var id: UInt8
    public var name: String
    public var docs: String
    /// Whether required at construction.
    public var required: Bool
    /// Whether settable via set rules.
    public var settable: Bool
    /// Whether the field has a default (i.e. optional at construction).
    public var hasDefault: Bool

    public init(id: UInt8, name: String, docs: String = "",
                required: Bool = false, settable: Bool = false,
                hasDefault: Bool = true) {
        self.id = id
        self.name = name
        self.docs = docs
        self.required = required
        self.settable = settable
        self.hasDefault = hasDefault
    }
}

/// A settable element property — Swift equivalent of upstream's
/// `SettableProperty<I>` marker trait used by `Content.set` and
/// `StyleChain.get`.
public protocol SettableProperty {
    associatedtype FieldType
    /// The element this property belongs to.
    static var element: Element { get }
    /// The field id.
    static var fieldID: UInt8 { get }
    /// Pack a typed value into a `Value` for storage.
    static func pack(_ value: FieldType) -> Value
    /// Unpack a `Value` into the field type.
    static func unpack(_ value: Value) -> FieldType?
}

/// The `Element` type identity — a lightweight handle to an element type,
/// equivalent to upstream's `Element` (vtable pointer).
public struct Element: Sendable, Hashable {
    /// Unique identity of the element type.
    public let id: ObjectIdentifier

    /// The element's metadata.
    public let info: ElementInfo

    /// Constructor vtable entry (nil for info-only handles).
    let constructImpl: (@Sendable (inout Engine, inout Args) throws -> Content)?

    public init<T: NativeElement>(_ type: T.Type) {
        id = ObjectIdentifier(T.self)
        info = T.info
        constructImpl = { engine, args in
            try T.construct(engine: &engine, args: &args)
        }
    }

    /// Create an element handle from info (internal registration).
    init(info: ElementInfo) {
        self.info = info
        self.id = ObjectIdentifier(info)
        constructImpl = nil
    }

    public static func == (a: Element, b: Element) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var name: String { info.name }
    public var title: String { info.title }
    public var docs: String { info.docs }
    public var since: Since? { info.since }

    /// Look up field info by id (nil when the element has no such field).
    public func field(_ id: UInt8) -> FieldInfo? {
        info.fields.first { $0.id == id }
    }
    public var keywords: [String] { info.keywords }
    public var defSite: DefSite? { info.defSite }
    public var scope: Scope? { info.scope }
    public var params: [NativeParamInfo] { info.params }

    /// Construct an instance of this element from call arguments.
    public func construct(engine: inout Engine, args: inout Args) throws -> Content {
        guard let constructImpl else {
            throw HintedString("\(name) cannot be constructed directly")
        }
        return try constructImpl(&engine, &args)
    }

    /// Look up a field id by name (upstream `field_id`).
    public func fieldId(_ name: String) -> UInt8? { info.fieldID(name) }

    /// Look up a field id by name.
    public func fieldID(_ name: String) -> UInt8? { info.fieldID(name) }

    /// Look up field name by id.
    public func fieldName(_ id: UInt8) -> String? { info.fieldName(id) }

    /// The style chain accessor for a settable field of the element.
    /// Returns `nil` if the field is unknown or is not settable.
    /// Port of `Element::settable_field_accessor`.
    ///
    /// NOTE: upstream's `get_from_styles` vtable entries embed per-field
    /// default resolution. The port's `FieldInfo` does not yet carry default
    /// values, so unset fields yield `.none`; elements with non-`none`
    /// defaults need `FieldInfo` extended when the element model lands.
    public func settableFieldAccessor(_ name: String) -> ((StyleChain) -> Value)? {
        guard let id = fieldID(name), let info = field(id), info.settable
        else { return nil }
        return { chain in chain.get(self, id) ?? .none }
    }

    /// Whether the element has the capability.
    public func can(_ capability: Capabilities) -> Bool {
        info.capabilities.contains(capability)
    }

    /// Whether the element can be located/introspected.
    /// Port of upstream `Element::is_locatable`.
    public var isLocatable: Bool { can(.locatable) }

    /// Whether the element is tagged in PDF files.
    /// Port of upstream `Element::is_tagged`.
    public var isTagged: Bool { can(.tagged) }

    /// Whether the element is excluded from queries.
    /// Upstream keeps a dedicated vtable flag; the port maps it to the
    /// absence of the `queriable` capability.
    public var isUnqueriable: Bool { !can(.queriable) }

    /// The selector matching all instances of this element.
    public func select() -> Selector { .elem(self, fields: nil) }

    /// A selector matching this element with field constraints.
    public func whereFields(_ fields: [(UInt8, Value)]) -> Selector {
        .elem(self, fields: fields)
    }

    /// `elem.where_(fields)` — upstream spelling used by `Func.where`.
    public func where_(fields: [(UInt8, Value)]) -> Selector {
        whereFields(fields)
    }

    /// The element's function value.
    public var function: Func { Func(inner: .element(self)) }
}

/// A native (Rust-side) element.
///
/// Port of `NativeElement` in `element.rs`. Elements are value types;
/// field storage is via the `field`/`setField` requirements keyed by the
/// field ids declared in `ElementInfo.fields`.
public protocol NativeElement: Sendable, Hashable {
    /// The element's static metadata.
    static var info: ElementInfo { get }

    /// The element's span (stored on the element for constructor use;
    /// Content.span mirrors it).
    var span: Span { get set }

    /// Read a field by id. Returns `nil` when unset.
    func field(_ id: UInt8) -> Value?

    /// Set a field by id, validating the value's type.
    mutating func setField(_ id: UInt8, _ value: Value) throws

    /// Construct an element from call arguments into content.
    /// Default implementation rejects construction.
    static func construct(engine: inout Engine, args: inout Args) throws -> Content
}

extension NativeElement {
    /// Default: elements without constructors cannot be called.
    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        throw HintedString("\(Self.info.name) cannot be constructed directly")
    }

    /// Element equality across the type-erased boundary.
    public func elementEquals(_ other: any NativeElement) -> Bool {
        guard let typed = other as? Self else { return false }
        return self == typed
    }
}

// MARK: - Core elements

/// A sequence of content.
///
/// Port of `SequenceElem`.
public struct SequenceElem: NativeElement {
    public static let info = ElementInfo(
        name: "sequence",
        capabilities: []
    )

    /// The children.
    public var children: [Content]

    public var span: Span = .detached

    public init(children: [Content] = []) { self.children = children }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .array(ArrayValue(children.map { .content($0) })) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .array(a) = value else { return }
        children = a.items.compactMap { if case let .content(c) = $0 { return c }; return nil }
    }
}

/// Content alongside styles.
///
/// Port of `StyledElem`.
public struct StyledElem: NativeElement {
    public static let info = ElementInfo(
        name: "styled",
        capabilities: []
    )

    /// The styled content.
    public var child: Content

    /// The styles applied.
    public var styles: Styles

    public var span: Span = .detached

    public init(child: Content, styles: Styles) {
        self.child = child
        self.styles = styles
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .content(child)
        case 1: return .styles(styles)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .content(c)): child = c
        case (1, let .styles(s)): styles = s
        default: break
        }
    }
}

/// Plain text.
///
/// Port of `TextElem` (subset — full field set lands with text layout).
public struct TextElem: NativeElement {
    public static let info = ElementInfo(
        name: "text",
        title: "Text",
        docs: "Text with shared styling.",
        
        fields: [
            FieldInfo(id: 0, name: "text", required: true, settable: false, hasDefault: false),
            FieldInfo(id: 1, name: "lang", settable: true),
            FieldInfo(id: 2, name: "region", settable: true),
            FieldInfo(id: 3, name: "size", settable: true),
        ],
        capabilities: [.locatable, .labelled, .counted, .queriable, .tagged]
    )

    /// Field id of the `size` field (upstream `TextElem::size`).
    public static let sizeFieldID: UInt8 = 3

    /// The text.
    public var text: Str

    /// The text's language.
    ///
    /// Upstream uses `Smart<Lang>` (`text/lang.rs`); stores the raw tag as a
    /// string until the language module lands.
    public var lang: Smart<Str> = .auto

    /// The text's region.
    ///
    /// Upstream uses `Smart<Option<Region>>`; stores the raw tag as a string.
    public var region: Smart<Str> = .auto

    /// The text size (upstream `TextSize`, default 11pt, folded across set
    /// rules by multiplication of the linear functions).
    public var size: TextSize = .default

    public var span: Span = .detached

    public init(_ text: Str) { self.text = text }

    /// Pack into content.
    public static func packed(_ text: String) -> Content {
        Content(TextElem(Str(text)))
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .str(text)
        case 1:
            if case let .custom(l) = lang { return .str(l) }
            return .auto
        case 2:
            if case let .custom(r) = region { return .str(r) }
            return .auto
        case 3: return .length(size.inner)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .str(s)): text = s
        case (1, .auto): lang = .auto
        case (1, let .str(s)): lang = .custom(s)
        case (2, .auto): region = .auto
        case (2, let .str(s)): region = .custom(s)
        case (3, let .length(l)):
            guard case .success(let ts) = TextSize.fromValue(.length(l))
            else { break }
            size = ts
        default: break
        }
    }
}

/// A symbol's resolved text.
///
/// Port of `SymbolElem`.
public struct SymbolElem: NativeElement {
    public static let info = ElementInfo(
        name: "symbol",
        capabilities: []
    )

    /// The symbol's resolved text.
    public var text: String

    public var span: Span = .detached

    public init(_ text: String) { self.text = text }

    /// Pack into content.
    public static func packed(_ text: String) -> Content {
        Content(SymbolElem(text))
    }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .str(Str(text)) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .str(s) = value else { return }
        text = s.value
    }
}

/// The content of a raw block.
///
/// Port of `RawContent` in `text/raw.rs`.
public enum RawContentValue: Sendable {
    /// From a string.
    case text(Str)
    /// From lines of text with spans.
    case lines([(Str, Span)])

    /// The text content.
    public var text: Str {
        switch self {
        case let .text(t): return t
        case let .lines(lines):
            return Str(lines.map(\.0.value).joined(separator: "\n"))
        }
    }
}

extension RawContentValue: Hashable {
    public static func == (a: RawContentValue, b: RawContentValue) -> Bool {
        switch (a, b) {
        case let (.text(x), .text(y)): return x == y
        case let (.lines(x), .lines(y)):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .text(t):
            hasher.combine(0); hasher.combine(t)
        case let .lines(ls):
            hasher.combine(1); hasher.combine(ls.count)
            for (t, span) in ls {
                hasher.combine(t); hasher.combine(span)
            }
        }
    }
}

/// Raw text with optional syntax highlighting.
///
/// Port of `RawElem` (subset — highlighting/syntaxes land later).
public struct RawElem: NativeElement {
    public static let info = ElementInfo(
        name: "raw",
        title: "Raw Text / Code",
        docs: "Raw text with optional syntax highlighting.",
        
        fields: [
            FieldInfo(id: 0, name: "text", required: true, settable: false, hasDefault: false),
            FieldInfo(id: 1, name: "block", settable: true),
            FieldInfo(id: 2, name: "lang", settable: true),
            FieldInfo(id: 3, name: "theme", settable: true),
            FieldInfo(id: 4, name: "tab-size", settable: true),
            FieldInfo(id: 5, name: "syntaxes", settable: true),
        ],
        capabilities: [.locatable, .labelled, .counted, .queriable, .tagged]
    )

    /// The raw text.
    public var text: RawContentValue

    /// Whether displayed as a block.
    public var block: Bool = false

    /// The language for highlighting.
    public var lang: Str? = nil

    /// The theme.
    public var theme: Str? = nil

    /// Tab size.
    public var tabSize: Int? = nil

    /// Custom syntaxes.
    public var syntaxes: Value? = nil

    public var span: Span = .detached

    public init(_ text: RawContentValue, lang: Str? = nil, block: Bool = false) {
        self.text = text
        self.lang = lang
        self.block = block
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .str(text.text)
        case 1: return .bool(block)
        case 2: return lang.map { .str($0) }
        case 3: return theme.map { .str($0) }
        case 4: return tabSize.map { .int(Int64($0)) }
        case 5: return syntaxes
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, let .bool(b)): block = b
        case (2, let .str(s)): lang = s
        case (2, .none): lang = nil
        case (3, let .str(s)): theme = s
        case (3, .none): theme = nil
        case (4, let .int(i)): tabSize = Int(i)
        case (4, .none): tabSize = nil
        case (5, let v): syntaxes = v
        default: break
        }
    }
}


