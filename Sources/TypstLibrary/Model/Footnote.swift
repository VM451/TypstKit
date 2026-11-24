import TypstSyntax

/// A footnote.
///
/// Port of `FootnoteElem` in `model/footnote.rs`. The `realize`,
/// `declarationLocation`, and `Count` machinery is deferred with the
/// introspection milestone (`Counter`, `QueryLabelIntrospection`).
public struct FootnoteElem: NativeElement {
    public static let info = ElementInfo(
        name: "footnote",
        title: "Footnote",
        scope: FootnoteElem.entryScope,
        fields: [
            FieldInfo(id: 0, name: "numbering", settable: true),
            FieldInfo(id: 1, name: "body", required: true),
        ],
        capabilities: [.locatable, .tagged, .counted]
    )

    /// How to number footnotes.
    public var numbering: Numbering =
        .pattern(NumberingPattern(pieces: [("", .arabic)], suffix: ""))

    /// The content to put into the footnote, or a label referencing another
    /// footnote.
    public var body: FootnoteBody

    public var span: Span = .detached

    public init(body: FootnoteBody) { self.body = body }

    /// Create with content (upstream `with_content`).
    public static func withContent(_ content: Content) -> FootnoteElem {
        FootnoteElem(body: .content(content))
    }

    /// Create referencing a label (upstream `with_label`).
    public static func withLabel(_ label: Label) -> FootnoteElem {
        FootnoteElem(body: .reference(label))
    }

    /// Clone referencing a label (upstream `into_ref`).
    public func intoRef(_ label: Label) -> FootnoteElem {
        var copy = self
        copy.body = .reference(label)
        return copy
    }

    /// Whether this footnote references another footnote.
    public func isRef() -> Bool {
        if case .reference = body { return true }
        return false
    }

    /// The body content if this footnote is not a reference.
    public func bodyContent() -> Content? {
        if case let .content(c) = body { return c }
        return nil
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return numbering.intoValue()
        case 1: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let v): numbering = try Numbering.fromValue(v).get()
        case (1, let v): body = try FootnoteBody.fromValue(v).get()
        default: break
        }
    }
}

/// The body of a footnote: either content or a label referencing another
/// footnote. Port of `FootnoteBody` in `model/footnote.rs`.
public enum FootnoteBody: Sendable, Hashable {
    case content(Content)
    case reference(Label)
}

extension FootnoteBody: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([.type(Type.of(Content.self)), .type(Type.of(Label.self))])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Content.castable(value) || Label.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .content(c): return c.intoValue()
        case let .reference(l): return l.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .content(c): return .success(.content(c))
        case let .label(l): return .success(.reference(l))
        default: return .failure(error(value))
        }
    }
}

/// An entry in a footnote list.
///
/// Port of `FootnoteEntry` in `model/footnote.rs`. `realize` is deferred
/// with the introspection milestone.
public struct FootnoteEntry: NativeElement {
    public static let info = ElementInfo(
        name: "entry",
        title: "Footnote Entry",
        fields: [
            FieldInfo(id: 0, name: "note", required: true),
            FieldInfo(id: 1, name: "separator", settable: true),
            FieldInfo(id: 2, name: "clearance", settable: true),
            FieldInfo(id: 3, name: "gap", settable: true),
            FieldInfo(id: 4, name: "indent", settable: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// The footnote for this entry.
    public var note: Content

    /// The separator between the document body and the footnote listing.
    public var separator: Content = Content(LineElem(
        length: Rel<Length>(Ratio(0.3)),
        stroke: Stroke<Length>(thickness: .custom(Length(Em(0.05))))))

    /// The amount of clearance between the document body and the separator.
    public var clearance: Length = Length(Em(1.0))

    /// The gap between footnote entries.
    public var gap: Length = Length(Em(0.5))

    /// The indent of each footnote entry.
    public var indent: Length = Length(Em(1.0))

    public var span: Span = .detached

    public init(note: Content) { self.note = note }

    /// The packed footnote element, if `note` holds one.
    public var noteElem: FootnoteElem? { note.packed(FootnoteElem.self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .content(note)
        case 1: return .content(separator)
        case 2: return .length(clearance)
        case 3: return .length(gap)
        case 4: return .length(indent)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .content(c)): note = c
        case (1, let .content(c)): separator = c
        case (2, let .length(l)): clearance = l
        case (3, let .length(l)): gap = l
        case (4, let .length(l)): indent = l
        default: break
        }
    }
}

extension FootnoteEntry: ShowSetCapable {
    /// Port of `ShowSet for Packed<FootnoteEntry>` — tighter leading and
    /// smaller text inside footnote listings.
    public func showSet(styles: StyleChain) -> Styles {
        func prop(_ elem: Element, _ field: UInt8, _ value: Value) -> Style {
            .property(Property(elem: elem, field: field, value: value))
        }
        return Styles([
            prop(Element(ParElem.self), 0, Length(Em(0.5)).intoValue()),
            prop(Element(TextElem.self), 3,
                 TextSize(Length(Em(0.85))).intoValue()),
        ])
    }
}

/// In HTML export, this is inserted at the end of the body to display
/// footnotes. Port of `FootnoteContainer` in `model/footnote.rs`.
public struct FootnoteContainer: NativeElement {
    public static let info = ElementInfo(
        name: "footnote-container",
        title: "Footnote Container",
        capabilities: [.locatable]
    )

    public var span: Span = .detached

    /// The globally shared footnote container element.
    public static let shared = Content(FootnoteContainer())

    public func field(_ id: UInt8) -> Value? { nil }
    public mutating func setField(_ id: UInt8, _ value: Value) throws {}
}

/// Inserted by the HTML footnote rule to indicate the presence of the
/// default footnote rule. Port of `FootnoteMarker` in `model/footnote.rs`.
public struct FootnoteMarker: NativeElement {
    public static let info = ElementInfo(
        name: "footnote-marker",
        title: "Footnote Marker",
        capabilities: [.locatable]
    )

    public var span: Span = .detached

    public func field(_ id: UInt8) -> Value? { nil }
    public mutating func setField(_ id: UInt8, _ value: Value) throws {}
}
