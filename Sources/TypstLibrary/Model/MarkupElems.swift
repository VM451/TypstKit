import Foundation
import TypstSyntax
import TypstUtils

// Port of the markup-facing elements from `typst-library`: text/space,
// text/linebreak, model/par (Parbreak), text/smartquote, model/emph,
// model/strong, model/link, model/reference, model/heading, model/list
// (ListItem), model/enum (EnumItem), model/terms (TermItem).
//
// Field sets cover what markup evaluation and introspection need; the
// remaining settable/style fields land with the model milestone.

// MARK: - Shared types

/// A URL value. Port of `Url` in `model/link.rs`.
public struct Url: Sendable, Hashable {
    /// The underlying string.
    public var inner: Str

    /// Create a URL from a string, checking the maximum length.
    /// Port of `Url::new`.
    public static func new(_ url: Str) -> StrResult<Url> {
        if url.value.count > 8000 {
            return .failure(StrError("URL is too long"))
        } else if url.value.isEmpty {
            return .failure(StrError("URL must not be empty"))
        }
        return .success(Url(url))
    }

    public init(_ inner: Str) { self.inner = inner }

    /// Strip a contact scheme (`mailto:`/`tel:`), returning the remainder.
    /// Port of `Url::strip_contact_scheme`.
    public func stripContactScheme() -> (scheme: String, rest: Str)? {
        for scheme in ["mailto:", "tel:"] where inner.value.hasPrefix(scheme) {
            return (scheme, Str(String(inner.value.dropFirst(scheme.count))))
        }
        return nil
    }
}

/// Where a link can go. Port of `LinkTarget` in `model/link.rs`.
public enum LinkTarget: Sendable, Hashable {
    /// A direct destination.
    case dest(Destination)
    /// A label to resolve through introspection.
    case label(Label)
}

/// A resolved link destination. Port of `Destination` in `model/link.rs`.
public enum Destination: Sendable, Hashable {
    /// An external URL.
    case url(Url)
    /// A location in the document.
    /// (`Destination::Position(PagedPosition)` lands with the layout
    /// milestone — PagedPosition does not exist yet.)
    case location(Location)
}

/// Additional content for a reference. Port of `Supplement` in
/// `model/reference.rs`.
public enum Supplement: Sendable, Hashable {
    /// Literal content.
    case content(Content)
    /// A function producing content when called.
    case function(Func)
}

extension Supplement {
    /// Tries to resolve the supplement into its content.
    /// Port of `Supplement::resolve` in `model/reference.rs`.
    public func resolve(
        engine: inout Engine, styles: StyleChain, args: [Value]
    ) -> SourceResult<Content> {
        switch self {
        case let .content(content):
            return .success(content)
        case let .function(`func`):
            let context = Context(location: nil, styles: styles)
            return `func`.callValue(
                engine: &engine, context: context,
                args: Args(span: .detached, values: args),
                span: `func`.span
            ).map { $0.display }
        }
    }
}

/// The bare-text body for a URL link. Port of `body_from_url`.
func bodyFromUrl(_ url: Url) -> Content {
    if let (_, rest) = url.stripContactScheme() {
        return TextElem.packed(rest.value)
    }
    return TextElem.packed(url.inner.value)
}

// MARK: - Space / breaks

/// A space between words. Port of `SpaceElem` in `text/space.rs`.
public struct SpaceElem: NativeElement {
    public static let info = ElementInfo(
        name: "space",
        capabilities: [.unlabellable]
    )

    /// Whether the space contained a newline.
    public var hadNewline: Bool

    public var span: Span = .detached

    public init(hadNewline: Bool = false) { self.hadNewline = hadNewline }

    /// The shared no-newline space.
    public static let shared = Content(SpaceElem())
    /// The shared newline space.
    public static let sharedWithNewline = Content(SpaceElem(hadNewline: true))

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .bool(hadNewline) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .bool(b) = value else { return }
        hadNewline = b
    }
}

/// A forced line break. Port of `LinebreakElem` in `text/linebreak.rs`.
public struct LinebreakElem: NativeElement {
    public static let info = ElementInfo(
        name: "linebreak",
        title: "Line Break",
        capabilities: []
    )

    /// Whether the break justifies the line.
    public var justify: Bool = false

    public var span: Span = .detached

    public init(justify: Bool = false) { self.justify = justify }

    /// The shared linebreak.
    public static let shared = Content(LinebreakElem())

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .bool(justify) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .bool(b) = value else { return }
        justify = b
    }
}

/// A paragraph break. Port of `ParbreakElem` in `model/par.rs`.
public struct ParbreakElem: NativeElement {
    public static let info = ElementInfo(
        name: "parbreak",
        title: "Paragraph Break",
        capabilities: [.unlabellable]
    )

    public var span: Span = .detached

    public init() {}

    /// The shared parbreak.
    public static let shared = Content(ParbreakElem())

    public func field(_ id: UInt8) -> Value? { nil }
    public mutating func setField(_ id: UInt8, _ value: Value) throws {}
}

// MARK: - Smart quote

/// A smart quote. Port of `SmartQuoteElem` in `text/smartquote.rs`.
/// (The `quotes` dictionary field is deferred to the text milestone.)
public struct SmartQuoteElem: NativeElement {
    public static let info = ElementInfo(
        name: "smartquote",
        fields: [
            FieldInfo(id: 0, name: "double"),
            FieldInfo(id: 1, name: "enabled"),
            FieldInfo(id: 2, name: "alternative"),
        ],
        capabilities: []
    )

    /// Whether this is a double quote.
    public var double: Bool

    /// Whether smart quotes are enabled.
    public var enabled: Bool = true

    /// Whether this is an alternative quote.
    public var alternative: Bool = false

    public var span: Span = .detached

    public init(double: Bool = false) { self.double = double }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(double)
        case 1: return .bool(enabled)
        case 2: return .bool(alternative)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .bool(b)): double = b
        case (1, let .bool(b)): enabled = b
        case (2, let .bool(b)): alternative = b
        default: break
        }
    }
}

// MARK: - Emphasis

/// Emphasized content. Port of `EmphElem` in `model/emph.rs`.
public struct EmphElem: NativeElement {
    public static let info = ElementInfo(
        name: "emph",
        title: "Emphasis",
        keywords: ["italic"],
        fields: [FieldInfo(id: 0, name: "body", required: true)],
        capabilities: [.locatable, .tagged]
    )

    /// The emphasized body.
    public var body: Content

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .content(body) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .content(c) = value else { return }
        body = c
    }
}

/// Strongly emphasized content. Port of `StrongElem` in `model/strong.rs`.
public struct StrongElem: NativeElement {
    public static let info = ElementInfo(
        name: "strong",
        title: "Strong Emphasis",
        keywords: ["bold", "weight"],
        fields: [
            FieldInfo(id: 0, name: "delta"),
            FieldInfo(id: 1, name: "body", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// The delta to apply on the font weight.
    public var delta: Int64 = 300

    /// The strong body.
    public var body: Content

    public var span: Span = .detached

    public init(body: Content, delta: Int64 = 300) {
        self.body = body
        self.delta = delta
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    /// Create with a body (upstream `StrongElem::new`).
    public static func new(_ body: Content) -> StrongElem {
        StrongElem(body: body)
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .int(delta)
        case 1: return .content(body)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .int(d)): delta = d
        case (1, let .content(c)): body = c
        default: break
        }
    }
}

// MARK: - Link

/// A link to a URL, label, or position. Port of `LinkElem` in
/// `model/link.rs`.
public struct LinkElem: NativeElement {
    public static let info = ElementInfo(
        name: "link",
        fields: [
            FieldInfo(id: 0, name: "dest", required: true),
            FieldInfo(id: 1, name: "body", required: true),
        ],
        capabilities: [.locatable]
    )

    /// The link target.
    public var dest: LinkTarget

    /// The linked content.
    public var body: Content

    public var span: Span = .detached

    public init(dest: LinkTarget, body: Content) {
        self.dest = dest
        self.body = body
    }

    /// Create a link element from a URL with its bare text.
    /// Port of `LinkElem::from_url`.
    public static func fromUrl(_ url: Url) -> LinkElem {
        LinkElem(dest: .dest(.url(url)), body: bodyFromUrl(url))
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0:
            switch dest {
            case let .dest(.url(url)): return .str(url.inner)
            case .dest: return nil
            case let .label(label): return .label(label)
            }
        case 1: return .content(body)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, let .content(c)): body = c
        default: break
        }
    }
}

// MARK: - Reference

/// A reference to a labelled element. Port of `RefElem` in
/// `model/reference.rs`.
public struct RefElem: NativeElement {
    public static let info = ElementInfo(
        name: "ref",
        title: "Reference",
        fields: [
            FieldInfo(id: 0, name: "target", required: true),
            FieldInfo(id: 1, name: "supplement"),
            FieldInfo(id: 2, name: "form"),
            FieldInfo(id: 3, name: "citation"),
        ],
        capabilities: [.locatable, .tagged, .unlabellable]
    )

    /// The referenced label.
    public var target: Label

    /// Additional content shown with the reference.
    /// Upstream: `LooselySpanned<Smart<Option<Supplement>>>`.
    public var supplement: Spanned<Smart<Supplement?>, Span> =
        Spanned(.auto, span: .detached)

    /// The form of the reference.
    public var form: RefForm = .normal

    /// The citation synthesized from this reference, if it turned out
    /// to be one (internal, ghost — never set through fields).
    public var citation: CiteElem?

    public var span: Span = .detached

    public init(target: Label) { self.target = target }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .label(target)
        case 1:
            switch supplement.value {
            case .auto: return .auto
            case let .custom(s?):
                switch s {
                case let .content(c): return .content(c)
                case let .function(f): return .function(f)
                }
            case .custom(nil): return .none
            }
        case 2: return form.intoValue()
        case 3: return citation.map { .content(Content($0)) }
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 1:
            supplement = Spanned(.custom(supplementValue(from: value)),
                                 span: supplement.span)
        case 2:
            if case let .success(f) = RefForm.fromValue(value) { form = f }
        default: break
        }
    }

    /// Convert a `Value` to `Supplement?` for `setField`.
    private func supplementValue(from value: Value) -> Supplement? {
        switch value {
        case .none: return nil
        case let .content(c): return .content(c)
        case let .function(f): return .function(f)
        default: return nil
        }
    }
}

// MARK: - Heading

/// A heading. Port of `HeadingElem` in `model/heading.rs`.
public struct HeadingElem: NativeElement {
    public static let info = ElementInfo(
        name: "heading",
        title: "Heading",
        fields: [
            FieldInfo(id: 0, name: "level"),
            FieldInfo(id: 1, name: "depth"),
            FieldInfo(id: 2, name: "offset"),
            FieldInfo(id: 3, name: "numbering", settable: true),
            FieldInfo(id: 4, name: "numbers"),
            FieldInfo(id: 5, name: "supplement"),
            FieldInfo(id: 6, name: "outlined"),
            FieldInfo(id: 7, name: "bookmarked"),
            FieldInfo(id: 8, name: "hanging-indent"),
            FieldInfo(id: 9, name: "body", required: true),
        ],
        capabilities: [.locatable, .counted, .tagged]
    )

    /// The absolute nesting depth of the heading, starting from one. If
    /// `auto`, computed from `offset + depth`.
    public var level: Smart<Int> = .auto

    /// The relative depth of the heading.
    public var depth: Int = 1

    /// An additional offset for the heading's depth.
    public var offset: Int = 0

    /// The heading's numbering.
    public var numbering: Numbering? = nil

    /// The numbers of the heading (internal).
    public var numbers: Str = Str("")

    /// Additional content for a reference to the heading.
    public var supplement: Spanned<Smart<Supplement?>, Span> =
        Spanned(.auto, span: .detached)

    /// Whether the heading should appear in the outline.
    public var outlined: Bool = true

    /// Whether the heading should be bookmarked in PDF export.
    public var bookmarked: Smart<Bool> = .auto

    /// The hanging indent of the heading.
    public var hangingIndent: Smart<Length> = .auto

    /// The heading's body.
    public var body: Content

    public var span: Span = .detached

    /// Create with a body (upstream `HeadingElem::new`).
    public init(body: Content) { self.body = body }

    /// Set the depth (upstream `with_depth`).
    public func withDepth(_ depth: Int) -> HeadingElem {
        var copy = self
        copy.depth = depth
        return copy
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return level.isAuto ? .auto : .int(Int64(level.custom() ?? 1))
        case 1: return .int(Int64(depth))
        case 2: return .int(Int64(offset))
        case 3: return numbering?.intoValue() ?? .none
        case 4: return .str(numbers)
        case 5:
            switch supplement.value {
            case .auto: return .auto
            case let .custom(s?):
                switch s {
                case let .content(c): return .content(c)
                case let .function(f): return .function(f)
                }
            case .custom(nil): return .none
            }
        case 6: return .bool(outlined)
        case 7:
            return bookmarked.isAuto ? .auto : .bool(bookmarked.custom() ?? false)
        case 8:
            return hangingIndent.isAuto
                ? .auto : .length(hangingIndent.custom() ?? .zero)
        case 9: return .content(body)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, let .int(d)): depth = Int(d)
        case (2, let .int(o)): offset = Int(o)
        case (3, .none): numbering = nil
        case (3, let v): numbering = try Numbering.fromValue(v).get()
        case (6, let .bool(b)): outlined = b
        case (9, let .content(c)): body = c
        default: break
        }
    }
}

// MARK: - List items

/// A bullet list item. Port of `ListItem` in `model/list.rs`.
public struct ListItem: NativeElement {
    public static let info = ElementInfo(
        name: "item",
        title: "Bullet List Item",
        fields: [FieldInfo(id: 0, name: "body", required: true)],
        capabilities: [.tagged]
    )

    /// The item's body.
    public var body: Content

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .content(body) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .content(c) = value else { return }
        body = c
    }
}

/// A numbered list item. Port of `EnumItem` in `model/enum.rs`.
public struct EnumItem: NativeElement {
    public static let info = ElementInfo(
        name: "item",
        title: "Numbered List Item",
        fields: [
            FieldInfo(id: 0, name: "number"),
            FieldInfo(id: 1, name: "body", required: true),
        ],
        capabilities: [.tagged]
    )

    /// The item's number.
    public var number: Smart<UInt64> = .auto

    /// The item's body.
    public var body: Content

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0:
            return number.isAuto ? .auto : .int(Int64(number.custom() ?? 0))
        case 1: return .content(body)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, let .content(c)): body = c
        default: break
        }
    }
}

/// A term list item. Port of `TermItem` in `model/terms.rs`.
public struct TermItem: NativeElement {
    public static let info = ElementInfo(
        name: "item",
        title: "Term List Item",
        fields: [
            FieldInfo(id: 0, name: "term", required: true),
            FieldInfo(id: 1, name: "description", required: true),
        ],
        capabilities: [.tagged]
    )

    /// The term described by the list item.
    public var term: Content

    /// The description of the term.
    public var description: Content

    public var span: Span = .detached

    public init(term: Content, description: Content) {
        self.term = term
        self.description = description
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .content(term)
        case 1: return .content(description)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .content(c)): term = c
        case (1, let .content(c)): description = c
        default: break
        }
    }
}

// MARK: - Internal link elements

/// A temporary dispatch element for raw links that bypass `LinkElem` in
/// paged export and route to `LinkElem` in HTML. Port of `DirectLinkElem`
/// in `model/link.rs`. Construct-only internally; manual construction
/// bails upstream-faithfully.
public struct DirectLinkElem: NativeElement {
    public static let info = ElementInfo(
        name: "direct-link",
        title: "Direct Link",
        fields: [
            FieldInfo(id: 0, name: "loc", required: true),
            FieldInfo(id: 1, name: "body", required: true),
            FieldInfo(id: 2, name: "alt", required: true),
        ],
        capabilities: []
    )

    /// The link target location.
    public var loc: Location
    /// The linked content.
    public var body: Content
    /// Alternative text for accessibility.
    public var alt: Str?

    public var span: Span = .detached

    public init(loc: Location, body: Content, alt: Str? = nil) {
        self.loc = loc
        self.body = body
        self.alt = alt
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return nil // Location has no Value representation
        case 1: return .content(body)
        case 2: return alt.map { .str($0) }
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, let .content(c)): body = c
        case (2, let .str(s)): alt = s
        case (2, .none): alt = nil
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        throw HintedString("cannot be constructed manually")
    }
}

/// Wraps all content that is linked to a destination. Port of
/// `LinkMarker` in `model/link.rs`. Construct-only internally.
public struct LinkMarker: NativeElement {
    public static let info = ElementInfo(
        name: "link-marker",
        title: "Link Marker",
        fields: [
            FieldInfo(id: 0, name: "body", required: true),
            FieldInfo(id: 1, name: "alt", required: true),
        ],
        capabilities: [.tagged]
    )

    /// The content.
    public var body: Content
    /// Alternative text for accessibility.
    public var alt: Str?

    public var span: Span = .detached

    public init(body: Content, alt: Str? = nil) {
        self.body = body
        self.alt = alt
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .content(body)
        case 1: return alt.map { .str($0) }
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .content(c)): body = c
        case (1, let .str(s)): alt = s
        case (1, .none): alt = nil
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        throw HintedString("cannot be constructed manually")
    }
}
