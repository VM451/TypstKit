import Foundation
import TypstSyntax
import TypstUtils

// Elements required by the realization subsystem.
//
// Ports of the element structs in upstream `model/{par,list,enum,terms,cite,
// document}.rs` and `layout/{spacing,page,container,align}.rs`, restricted to
// the fields realization consumes. Full field sets, constructors, set rules,
// and scopes land with the layout milestone.

// MARK: - Capability protocols

/// Synthesize fields on an element before show rule application.
///
/// Port of upstream `Synthesize` capability trait.
public protocol SynthesizeCapable: NativeElement {
    /// Prepare the element for show rule application.
    mutating func synthesize(engine: inout Engine, styles: StyleChain) throws
}

/// Defines built-in show set rules for an element.
///
/// Port of upstream `ShowSet` capability trait.
public protocol ShowSetCapable: NativeElement {
    /// Finalize the fully realized form of the element.
    func showSet(styles: StyleChain) -> Styles
}

/// Marker for math elements.
///
/// Port of upstream `Mathy` capability trait.
public protocol MathyCapable: NativeElement {}

// MARK: - List machinery

/// A list item, enum item, or term list item.
///
/// Port of upstream `ListItemLike`.
public protocol ListItemLike: NativeElement {
    /// Apply styles to the item's content fields.
    mutating func applyStyles(_ styles: Styles)
}

/// A list, enum, or term list.
///
/// Port of upstream `ListLike`.
public protocol ListLike: NativeElement {
    /// The kind of list item this list is composed of.
    associatedtype Item: ListItemLike

    /// The item element's `Element` handle.
    static var itemElement: Element { get }

    /// Create this kind of list from its children and tightness.
    static func createList(children: [Item], tight: Bool) -> Self
}

extension ListItem: ListItemLike {
    public mutating func applyStyles(_ styles: Styles) { body.styleInPlace(styles) }
}
extension EnumItem: ListItemLike {
    public mutating func applyStyles(_ styles: Styles) { body.styleInPlace(styles) }
}
extension TermItem: ListItemLike {
    public mutating func applyStyles(_ styles: Styles) {
        term.styleInPlace(styles)
        description.styleInPlace(styles)
    }
}

// MARK: - Spacing

/// Kinds of spacing.
///
/// Port of `Spacing` in `layout/spacing.rs`.
public enum Spacing: Sendable, Hashable {
    /// Spacing specified in absolute terms and relative to the parent's size.
    case rel(Rel<Length>)
    /// Spacing specified as a fraction of the remaining free space.
    case fr(Fr)

    /// Whether this is fractional spacing.
    public var isFractional: Bool {
        if case .fr = self { return true }
        return false
    }
}

/// Spacing (H).
///
/// Port of `HElem` in `layout/spacing.rs`.
public struct HElem: NativeElement {
    public static let info = ElementInfo(
        name: "h",
        title: "Spacing (H)",
        fields: [
            FieldInfo(id: 0, name: "amount", required: true),
            FieldInfo(id: 1, name: "weak", settable: true),
        ],
        capabilities: []
    )

    /// How much spacing to insert.
    public var amount: Spacing

    /// If true, the spacing collapses at the start or end of a flow.
    public var weak: Bool = false

    public var span: Span = .detached

    public init(amount: Spacing) { self.amount = amount }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0:
            switch amount {
            case let .rel(r): return .relative(r)
            case let .fr(f): return .fraction(f)
            }
        case 1: return .bool(weak)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .relative(r)): amount = .rel(r)
        case (0, let .fraction(f)): amount = .fr(f)
        case (1, let .bool(b)): weak = b
        default: break
        }
    }
}

/// Spacing (V).
///
/// Port of `VElem` in `layout/spacing.rs`.
public struct VElem: NativeElement {
    public static let info = ElementInfo(
        name: "v",
        title: "Spacing (V)",
        fields: [
            FieldInfo(id: 0, name: "amount", required: true),
            FieldInfo(id: 1, name: "weak", settable: true),
            FieldInfo(id: 2, name: "attach"),
        ],
        capabilities: []
    )

    /// How much spacing to insert.
    public var amount: Spacing

    /// If true, the spacing collapses at the start or end of a flow.
    public var weak: Bool = false

    /// Whether the spacing collapses if not immediately preceded by a
    /// paragraph.
    public var attach: Bool = false

    public var span: Span = .detached

    public init(amount: Spacing) { self.amount = amount }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0:
            switch amount {
            case let .rel(r): return .relative(r)
            case let .fr(f): return .fraction(f)
            }
        case 1: return .bool(weak)
        case 2: return .bool(attach)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .relative(r)): amount = .rel(r)
        case (0, let .fraction(f)): amount = .fr(f)
        case (1, let .bool(b)): weak = b
        case (2, let .bool(b)): attach = b
        default: break
        }
    }
}

// MARK: - Paragraph

/// Linebreak behaviour for a paragraph.
///
/// Port of `Linebreaks` in `model/par.rs`.
public enum Linebreaks: String, Sendable, Hashable {
    case simple
    case optimized
}

/// A paragraph.
///
/// Port of `ParElem` in `model/par.rs` (field subset used by realization).
public struct ParElem: NativeElement {
    public static let info = ElementInfo(
        name: "par",
        title: "Paragraph",
        fields: [
            FieldInfo(id: 0, name: "leading", settable: true),
            FieldInfo(id: 1, name: "spacing", settable: true),
            FieldInfo(id: 2, name: "justify", settable: true),
            FieldInfo(id: 3, name: "linebreaks", settable: true),
            FieldInfo(id: 4, name: "hanging-indent", settable: true),
            FieldInfo(id: 5, name: "body", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// The spacing between lines.
    public var leading: Length = Length(Em(0.65))

    /// The spacing between paragraphs.
    public var spacing: Length = Length(Em(1.2))

    /// Whether to justify the text.
    public var justify: Bool = false

    /// How to choose linebreaks.
    public var linebreaks: Smart<Linebreaks> = .auto

    /// Hanging indent.
    public var hangingIndent: Length = Length.zero

    /// The paragraph's body.
    public var body: Content

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .length(leading)
        case 1: return .length(spacing)
        case 2: return .bool(justify)
        case 3:
            if case let .custom(l) = linebreaks { return .str(Str(l.rawValue)) }
            return .auto
        case 4: return .length(hangingIndent)
        case 5: return .content(body)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .length(l)): leading = l
        case (1, let .length(l)): spacing = l
        case (2, let .bool(b)): justify = b
        case (4, let .length(l)): hangingIndent = l
        case (5, let .content(c)): body = c
        default: break
        }
    }
}

// MARK: - Page

/// Page break behaviour.
///
/// Port of `Parity` in `layout/page.rs`.
public enum Parity: String, Sendable, Hashable {
    case even
    case odd
}

/// A page break.
///
/// Port of `PagebreakElem` in `layout/page.rs`.
public struct PagebreakElem: NativeElement {
    public static let info = ElementInfo(
        name: "pagebreak",
        title: "Page Break",
        fields: [
            FieldInfo(id: 0, name: "weak", settable: true),
            FieldInfo(id: 1, name: "to"),
            FieldInfo(id: 2, name: "boundary"),
        ],
        capabilities: []
    )

    /// Whether the pagebreak is weak.
    public var weak: Bool = false

    /// Whether to break to an even/odd page.
    public var to: Parity?

    /// Whether this is a "boundary" pagebreak.
    public var boundary: Bool = false

    public var span: Span = .detached

    public init(weak: Bool = false, to: Parity? = nil, boundary: Bool = false) {
        self.weak = weak
        self.to = to
        self.boundary = boundary
    }

    /// A shared weak pagebreak.
    /// Port of upstream `PagebreakElem::shared_weak`.
    public static let sharedWeak = Content(PagebreakElem(weak: true))

    /// A shared boundary pagebreak.
    /// Port of upstream `PagebreakElem::shared_boundary`.
    public static let sharedBoundary = Content(PagebreakElem(boundary: true))

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(weak)
        case 1: return to.map { .str(Str($0.rawValue)) } ?? .none
        case 2: return .bool(boundary)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .bool(b)): weak = b
        case (2, let .bool(b)): boundary = b
        default: break
        }
    }
}

/// A page.
///
/// Port of `PageElem` in `layout/page.rs` (field subset — full page
/// configuration lands with the layout milestone).
public struct PageElem: NativeElement {
    public static let info = ElementInfo(
        name: "page",
        title: "Page",
        fields: [
            FieldInfo(id: 0, name: "body", required: true),
        ],
        capabilities: [.locatable]
    )

    /// The page's body.
    public var body: Content

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .content(body) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .content(c) = value else { return }
        body = c
    }
}

// MARK: - Containers

/// A box.
///
/// Port of `BoxElem` in `layout/container.rs` (field subset).
public struct BoxElem: NativeElement {
    public static let info = ElementInfo(
        name: "box",
        title: "Box",
        fields: [
            FieldInfo(id: 0, name: "body"),
        ],
        capabilities: []
    )

    /// The box's body.
    public var body: Content?

    public var span: Span = .detached

    public init(body: Content? = nil) { self.body = body }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? body.map { .content($0) } ?? .none : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0 else { return }
        if case let .content(c) = value { body = c }
        if case .none = value { body = nil }
    }
}

/// Callback storage for inline layout.
///
/// Port of `callbacks::InlineCallback` — the closure is boxed so the element
/// stays `Hashable` (upstream uses a plain fn pointer).
public final class InlineCallbackBox: @unchecked Sendable {
    public let call: @Sendable (Content, inout Engine, Locator, StyleChain, Size)
        -> SourceResult<[InlineItem]>
    public init(_ call: @escaping @Sendable (Content, inout Engine, Locator,
                                             StyleChain, Size)
        -> SourceResult<[InlineItem]>) {
        self.call = call
    }
}

/// A callback that is invoked with the regions to produce arbitrary inline
/// items.
///
/// Port of `callbacks::InlineCallback` in `layout/container.rs`.
public struct InlineCallback: Sendable, Hashable {
    /// The captured element the callback was created from.
    public var captured: Content
    /// The boxed callback.
    public var box: InlineCallbackBox

    public init(captured: Content, box: InlineCallbackBox) {
        self.captured = captured
        self.box = box
    }

    public static func == (a: InlineCallback, b: InlineCallback) -> Bool {
        a.captured == b.captured && a.box === b.box
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(captured)
        hasher.combine(ObjectIdentifier(box))
    }
}

/// Layouted items suitable for placing in a paragraph.
///
/// Port of `InlineItem` in `layout/container.rs` — populated as the layout
/// milestone lands.
public enum InlineItem: Sendable, Hashable {
    /// Absolute spacing between other items, and whether it is weak.
    case space(Abs, Bool)
    /// A frame.
    case frame(Content)
    /// A text item.
    case text(Str)
    /// A tag.
    case tag(Tag)
}

/// An inline-level item with a custom layouter.
///
/// Port of `InlineElem` in `layout/container.rs`.
public struct InlineElem: NativeElement {
    public static let info = ElementInfo(
        name: "inline",
        capabilities: []
    )

    /// A callback that is invoked with the regions to produce arbitrary inline
    /// items.
    public var body: InlineCallback

    public var span: Span = .detached

    public init(body: InlineCallback) { self.body = body }

    /// Create an inline-level item with a custom layouter.
    public static func layouter(
        captured: Content,
        callback: @escaping @Sendable (Content, inout Engine, Locator,
                                       StyleChain, Size) -> SourceResult<[InlineItem]>
    ) -> InlineElem {
        InlineElem(body: InlineCallback(
            captured: captured, box: InlineCallbackBox(callback)))
    }

    public func field(_ id: UInt8) -> Value? { nil }
    public mutating func setField(_ id: UInt8, _ value: Value) throws {}

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        throw HintedString("cannot be constructed manually")
    }
}

// MARK: - Alignment

/// Alignment of content.
///
/// Port of `AlignElem` in `layout/align.rs`.
public struct AlignElem: NativeElement {
    public static let info = ElementInfo(
        name: "align",
        title: "Alignment",
        fields: [
            FieldInfo(id: 0, name: "alignment", settable: true),
            FieldInfo(id: 1, name: "body", required: true),
        ],
        capabilities: [],
        // `alignment` is `#[positional]` upstream, so the generated `Set`
        // impl consumes it via `args.find`, not `args.named`.
        setImpl: { _, args in
            var collected: [Style] = []
            if let value: Alignment = try args.findT() {
                collected.append(.property(Property(
                    elem: Element(AlignElem.self), field: 0,
                    value: value.intoValue())))
            }
            return Styles(collected)
        }
    )

    /// The alignment.
    public var alignment: Alignment

    /// The aligned content.
    public var body: Content

    public var span: Span = .detached

    public init(alignment: Alignment, body: Content) {
        self.alignment = alignment
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0:
            switch alignment {
            case let .h(h): return .str(Str(h.rawValue))
            case let .v(v): return .str(Str(v.rawValue))
            case let .both(h, v): return .str(Str("\(h.rawValue + v.rawValue)"))
            }
        case 1: return .content(body)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 1, case let .content(c) = value else { return }
        body = c
    }
}

// MARK: - Lists

/// A bullet list.
///
/// Port of `ListElem` in `model/list.rs` (field subset used by realization).
public struct ListElem: NativeElement, ListLike {
    public typealias Item = ListItem

    public static let info = ElementInfo(
        name: "list",
        title: "Bullet List",
        scope: ListElem.itemScope,
        fields: [
            FieldInfo(id: 0, name: "tight"),
            FieldInfo(id: 1, name: "indent", settable: true),
            FieldInfo(id: 2, name: "body-indent", settable: true),
            FieldInfo(id: 3, name: "spacing", settable: true),
            FieldInfo(id: 4, name: "marker-align", settable: true),
            FieldInfo(id: 5, name: "children", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// Whether the list is tight (no paragraph spacing between items).
    public var tight: Bool = false

    /// The list's indentation.
    public var indent: Length = Length(Em(1.5))

    /// The list's body indentation.
    public var bodyIndent: Length = Length(Em(1.5))

    /// The spacing between items.
    public var spacing: Smart<Length> = .auto

    /// How the markers are aligned.
    public var markerAlign: Alignment = .h(.end)

    /// The list's children.
    public var children: [ListItem]

    public var span: Span = .detached

    public init(children: [ListItem]) { self.children = children }

    public static var itemElement: Element { Element(ListItem.self) }

    public static func createList(children: [ListItem], tight: Bool) -> ListElem {
        var elem = ListElem(children: children)
        elem.tight = tight
        return elem
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(tight)
        case 1: return .length(indent)
        case 2: return .length(bodyIndent)
        case 3:
            if case let .custom(l) = spacing { return .length(l) }
            return .auto
        case 4:
            switch markerAlign {
            case let .h(h): return .str(Str(h.rawValue))
            case let .v(v): return .str(Str(v.rawValue))
            case let .both(h, v): return .str(Str("\(h.rawValue + v.rawValue)"))
            }
        case 5:
            return .array(ArrayValue(children.map { .content(Content($0)) }))
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .bool(b)): tight = b
        case (1, let .length(l)): indent = l
        case (2, let .length(l)): bodyIndent = l
        case (3, .auto): spacing = .auto
        case (3, let .length(l)): spacing = .custom(l)
        case (5, let .array(a)):
            children = a.items.compactMap {
                if case let .content(c) = $0, let item = c.packed(ListItem.self) {
                    return item
                }
                return nil
            }
        default: break
        }
    }
}

/// A numbered list.
///
/// Port of `EnumElem` in `model/enum.rs` (field subset used by realization).
public struct EnumElem: NativeElement, ListLike {
    public typealias Item = EnumItem

    public static let info = ElementInfo(
        name: "enum",
        title: "Numbered List",
        scope: EnumElem.itemScope,
        fields: [
            FieldInfo(id: 0, name: "tight"),
            FieldInfo(id: 1, name: "start", settable: true),
            FieldInfo(id: 2, name: "full", settable: true),
            FieldInfo(id: 3, name: "reversed", settable: true),
            FieldInfo(id: 4, name: "indent", settable: true),
            FieldInfo(id: 5, name: "body-indent", settable: true),
            FieldInfo(id: 6, name: "spacing", settable: true),
            FieldInfo(id: 7, name: "number-align", settable: true),
            FieldInfo(id: 8, name: "children", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// Whether the list is tight.
    public var tight: Bool = true

    /// The start number.
    public var start: Smart<UInt64> = .auto

    /// Whether to show full numbering (e.g. `1.1` instead of `1.`).
    public var full: Bool = false

    /// Whether the list is reversed.
    public var reversed: Bool = false

    /// The indent of each item.
    public var indent: Length = Length(Em(1.5))

    /// Additional indent of the item's body.
    public var bodyIndent: Length = Length(Em(0.5))

    /// The spacing between items.
    public var spacing: Smart<Length> = .auto

    /// The alignment of the numbers.
    public var numberAlign: Alignment = .h(.end)

    /// The list's children.
    public var children: [EnumItem]

    public var span: Span = .detached

    public init(children: [EnumItem]) { self.children = children }

    public static var itemElement: Element { Element(EnumItem.self) }

    public static func createList(children: [EnumItem], tight: Bool) -> EnumElem {
        var elem = EnumElem(children: children)
        elem.tight = tight
        return elem
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(tight)
        case 1:
            if case let .custom(n) = start { return .int(Int64(n)) }
            return .auto
        case 2: return .bool(full)
        case 3: return .bool(reversed)
        case 4: return .length(indent)
        case 5: return .length(bodyIndent)
        case 6:
            if case let .custom(l) = spacing { return .length(l) }
            return .auto
        case 7:
            switch numberAlign {
            case let .h(h): return .str(Str(h.rawValue))
            case let .v(v): return .str(Str(v.rawValue))
            case let .both(h, v): return .str(Str("\(h.rawValue + v.rawValue)"))
            }
        case 8:
            return .array(ArrayValue(children.map { .content(Content($0)) }))
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .bool(b)): tight = b
        case (1, let .int(n)): start = .custom(UInt64(clamping: n))
        case (2, let .bool(b)): full = b
        case (3, let .bool(b)): reversed = b
        case (4, let .length(l)): indent = l
        case (5, let .length(l)): bodyIndent = l
        case (6, .auto): spacing = .auto
        case (6, let .length(l)): spacing = .custom(l)
        case (8, let .array(a)):
            children = a.items.compactMap {
                if case let .content(c) = $0, let item = c.packed(EnumItem.self) {
                    return item
                }
                return nil
            }
        default: break
        }
    }
}

/// A term list.
///
/// Port of `TermsElem` in `model/terms.rs` (field subset used by
/// realization).
public struct TermsElem: NativeElement, ListLike {
    public typealias Item = TermItem

    public static let info = ElementInfo(
        name: "terms",
        title: "Term List",
        scope: TermsElem.itemScope,
        fields: [
            FieldInfo(id: 0, name: "tight"),
            FieldInfo(id: 1, name: "separator"),
            FieldInfo(id: 2, name: "indent", settable: true),
            FieldInfo(id: 3, name: "hanging-indent", settable: true),
            FieldInfo(id: 4, name: "spacing", settable: true),
            FieldInfo(id: 5, name: "children", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// Whether the list is tight.
    public var tight: Bool = true

    /// The separator between term and description.
    public var separator: Content = {
        var h = HElem(amount: .rel(Rel(rel: .zero, abs: Length(Em(0.6)))))
        h.weak = true
        return Content(h)
    }()

    /// The indent of each item.
    public var indent: Length = .zero

    /// The hanging indent of each item's description.
    public var hangingIndent: Length = Length(Em(2.0))

    /// The spacing between items.
    public var spacing: Smart<Length> = .auto

    /// The list's children.
    public var children: [TermItem]

    public var span: Span = .detached

    public init(children: [TermItem]) { self.children = children }

    public static var itemElement: Element { Element(TermItem.self) }

    public static func createList(children: [TermItem], tight: Bool) -> TermsElem {
        var elem = TermsElem(children: children)
        elem.tight = tight
        return elem
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(tight)
        case 1: return .content(separator)
        case 2: return .length(indent)
        case 3: return .length(hangingIndent)
        case 4:
            if case let .custom(l) = spacing { return .length(l) }
            return .auto
        case 5:
            return .array(ArrayValue(children.map { .content(Content($0)) }))
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .bool(b)): tight = b
        case (1, let .content(c)): separator = c
        case (2, let .length(l)): indent = l
        case (3, let .length(l)): hangingIndent = l
        case (4, .auto): spacing = .auto
        case (4, let .length(l)): spacing = .custom(l)
        case (5, let .array(a)):
            children = a.items.compactMap {
                if case let .content(c) = $0, let item = c.packed(TermItem.self) {
                    return item
                }
                return nil
            }
        default: break
        }
    }
}

// MARK: - Citations

/// How to display a citation.
///
/// Port of `CitationForm` in `model/cite.rs`.
public enum CitationForm: String, Sendable, Hashable {
    case normal
    case prose
    case full
    case author
    case year
}

/// A citation.
///
/// Port of `CiteElem` in `model/cite.rs` (field subset used by realization).
public struct CiteElem: NativeElement {
    public static let info = ElementInfo(
        name: "cite",
        title: "Citation",
        fields: [
            FieldInfo(id: 0, name: "key", required: true),
            FieldInfo(id: 1, name: "supplement"),
            FieldInfo(id: 2, name: "form"),
        ],
        capabilities: [.locatable]
    )

    /// The cited work's label.
    public var key: Label

    /// Additional content to display alongside the citation.
    public var supplement: Content?

    /// The citation's display form.
    public var form: CitationForm?

    public var span: Span = .detached

    public init(key: Label) { self.key = key }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .label(key)
        case 1: return supplement.map { .content($0) } ?? .none
        case 2: return form.map { .str(Str($0.rawValue)) } ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, let .content(c)): supplement = c
        case (1, .none): supplement = nil
        case (2, let .str(s)):
            form = CitationForm(rawValue: s.value)
        case (2, .none): form = nil
        default: break
        }
    }
}

/// A group of consecutive citations.
///
/// Port of `CiteGroup` in `model/cite.rs`.
public struct CiteGroup: NativeElement {
    public static let info = ElementInfo(
        name: "cite-group",
        fields: [
            FieldInfo(id: 0, name: "children", required: true),
        ],
        capabilities: [.locatable]
    )

    /// The grouped citations.
    public var children: [Content]

    public var span: Span = .detached

    public init(children: [Content]) { self.children = children }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .array(ArrayValue(children.map { .content($0) })) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .array(a) = value else { return }
        children = a.items.compactMap {
            if case let .content(c) = $0 { return c }
            return nil
        }
    }
}

// MARK: - Document

/// Supported export formats for bundle documents.
///
/// Port of `DocumentFormat` in `model/document.rs` — the `Paged` payload
/// (`PagedFormat`) is simplified to a flag until the format milestone lands.
public enum DocumentFormat: Sendable, Hashable {
    /// One of the page formats.
    case paged
    /// The document format of the web.
    case html
}

/// A document.
///
/// Port of `DocumentElem` in `model/document.rs` (field subset used by
/// realization and `DocumentInfo`).
public struct DocumentElem: NativeElement {
    public static let info = ElementInfo(
        name: "document",
        title: "Document",
        fields: [
            FieldInfo(id: 0, name: "title"),
            FieldInfo(id: 1, name: "author"),
            FieldInfo(id: 2, name: "description"),
            FieldInfo(id: 3, name: "keywords"),
            FieldInfo(id: 4, name: "date"),
            FieldInfo(id: 5, name: "body", required: true),
            FieldInfo(id: 6, name: "format"),
        ],
        capabilities: [.locatable]
    )

    /// The document's title.
    public var title: Content?

    /// The document's author(s).
    public var author: [Str] = []

    /// The document's description.
    public var description: Content?

    /// The document's keywords.
    public var keywords: [Str] = []

    /// The document's creation date.
    public var date: Smart<Datetime?> = .auto

    /// The document's body.
    public var body: Content

    /// The document's export format.
    public var format: Smart<DocumentFormat> = .auto

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return title.map { .content($0) } ?? .none
        case 1: return .array(ArrayValue(author.map { .str($0) }))
        case 2: return description.map { .content($0) } ?? .none
        case 3: return .array(ArrayValue(keywords.map { .str($0) }))
        case 4:
            switch date {
            case .auto: return .auto
            case let .custom(d): return d.map { .datetime($0) } ?? .none
            }
        case 5: return .content(body)
        case 6:
            switch format {
            case .auto: return .auto
            case let .custom(f):
                return .str(Str(f == .html ? "html" : "paged"))
            }
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .content(c)): title = c
        case (1, let .array(a)):
            author = a.items.compactMap {
                if case let .str(s) = $0 { return s }
                return nil
            }
        case (2, let .content(c)): description = c
        case (3, let .array(a)):
            keywords = a.items.compactMap {
                if case let .str(s) = $0 { return s }
                return nil
            }
        case (5, let .content(c)): body = c
        case (6, .auto): format = .auto
        case (6, let .str(s)):
            format = .custom(s.value == "html" ? .html : .paged)
        default: break
        }
    }
}
