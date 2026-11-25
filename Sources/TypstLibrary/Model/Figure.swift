import TypstSyntax

/// A figure with an optional caption.
///
/// Port of `FigureElem` in `model/figure.rs`. `Refable`/`Outlinable`/
/// `LocalName` live in `Model/Outline.swift` and `Count` in
/// `Introspection/Counter.swift`. `Synthesize` is deferred with the
/// realization milestone (`Locale`, `query_first_naive`), as is the
/// synthesized `locale` field.
public struct FigureElem: NativeElement {
    public static let info = ElementInfo(
        name: "figure",
        title: "Figure",
        scope: FigureElem.captionScope,
        fields: [
            FieldInfo(id: 0, name: "body", required: true),
            FieldInfo(id: 1, name: "alt", settable: true),
            FieldInfo(id: 2, name: "placement", settable: true),
            FieldInfo(id: 3, name: "scope", settable: true),
            FieldInfo(id: 4, name: "caption", settable: true),
            FieldInfo(id: 5, name: "kind", settable: true),
            FieldInfo(id: 6, name: "supplement", settable: true),
            FieldInfo(id: 7, name: "numbering", settable: true),
            FieldInfo(id: 8, name: "gap", settable: true),
            FieldInfo(id: 9, name: "outlined", settable: true),
            FieldInfo(id: 10, name: "counter"),
        ],
        capabilities: [.locatable, .tagged, .counted]
    )

    /// The content of the figure.
    public var body: Content

    /// An alternative description of the figure.
    public var alt: Str? = nil

    /// The figure's placement on the page.
    public var placement: Smart<VAlignment>? = nil

    /// Relative to which containing scope the figure is placed.
    public var scope: PlacementScope = .column

    /// The figure's caption (wrapped in `FigureCaption` like upstream's
    /// `Packed<FigureCaption>` cast).
    public var caption: FigureCaption? = nil

    /// The kind of figure this is.
    public var kind: Smart<FigureKind> = .auto

    /// The figure's supplement.
    public var supplement: Smart<Supplement?> = .auto

    /// How to number the figure.
    public var numbering: Numbering? =
        .pattern(NumberingPattern(pieces: [("", .arabic)], suffix: ""))

    /// The vertical gap between the body and caption.
    public var gap: Length = Length(Em(0.65))

    /// Whether the figure should appear in an outline of figures.
    public var outlined: Bool = true

    /// Convenience field to get access to the counter for this figure
    /// (`#[synthesized]` upstream — populated once synthesis lands).
    public var counter: Counter? = nil

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    /// Retrieves the separator which will appear between the number and
    /// body (upstream `resolve_separator`). The locale-aware
    /// `local_separator_in` fallback needs `Lang` (deferred); until then it
    /// resolves to the English default upstream uses for unmatched
    /// languages.
    public func resolveSeparator(styles: StyleChain) -> Content {
        if let caption { return caption.resolveSeparator(styles: styles) }
        return TextElem.packed(": ")
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .content(body)
        case 1: return alt.map { .str($0) } ?? .none
        case 2:
            guard let placement else { return .none }
            if placement.isAuto { return .auto }
            return placement.custom()?.intoValue() ?? .none
        case 3: return scope.intoValue()
        case 4: return caption.map { .content(Content($0)) } ?? .none
        case 5:
            if kind.isAuto { return .auto }
            return kind.custom().map { $0.intoValue() } ?? .none
        case 6:
            switch supplement {
            case .auto: return .auto
            case let .custom(s?):
                switch s {
                case let .content(c): return .content(c)
                case let .function(f): return .function(f)
                }
            case .custom(nil): return .none
            }
        case 7: return numbering?.intoValue() ?? .none
        case 8: return .length(gap)
        case 9: return .bool(outlined)
        case 10: return counter?.intoValue() ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, .none): alt = nil
        case (1, let .str(s)): alt = s
        case (2, .none): placement = nil
        case (2, .auto): placement = .auto
        case (2, let v):
            let va = try VAlignment.fromValue(v).get()
            placement = .custom(va)
        case (3, let v): scope = try PlacementScope.fromValue(v).get()
        case (4, .none): caption = nil
        case (4, let v):
            caption = try FigureCaption.fromValue(v).get()
        case (5, .auto): kind = .auto
        case (5, let v): kind = .custom(try FigureKind.fromValue(v).get())
        case (6, .auto): supplement = .auto
        case (6, .none): supplement = .custom(nil)
        case (6, let v):
            supplement = .custom(try Supplement?.fromValue(v).get())
        case (7, .none): numbering = nil
        case (7, let v): numbering = try Numbering.fromValue(v).get()
        case (8, let .length(l)): gap = l
        case (9, let .bool(b)): outlined = b
        default: break
        }
    }
}

extension FigureElem: ShowSetCapable {
    /// Port of `ShowSet for Packed<FigureElem>` — unbreakable, centered.
    public func showSet(styles: StyleChain) -> Styles {
        func prop(_ elem: Element, _ field: UInt8, _ value: Value) -> Style {
            .property(Property(elem: elem, field: field, value: value))
        }
        return Styles([
            prop(Element(BlockElem.self), 2, .bool(false)),
            prop(Element(AlignElem.self), 0, Alignment.center.intoValue()),
        ])
    }
}

/// An element that can be auto-detected in a figure. Port of the
/// `Figurable` marker trait in `model/figure.rs`.
public protocol Figurable {}

extension TableElem: Figurable {}
extension RawElem: Figurable {}

/// The `kind` parameter of a `FigureElem`. Port of `FigureKind` in
/// `model/figure.rs`.
public enum FigureKind: Sendable, Hashable {
    /// The kind is an element function.
    case elem(Element)
    /// The kind is a name.
    case name(Str)
}

extension FigureKind: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([.type(Type.of(Func.self)), .type(Type.of(Str.self))])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Element.castable(value) || Str.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .elem(e): return e.intoValue()
        case let .name(n): return n.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Element.castable(value),
           let e = try? Element.fromValue(value).get() {
            return .success(.elem(e))
        }
        return Str.fromValue(value).map { .name($0) }
    }
}

/// The caption of a figure. Port of `FigureCaption` in `model/figure.rs`.
/// `realize` and `synthesize` are deferred with the introspection
/// milestone; the synthesized `kind`/`supplement`/`numbering`/
/// `figure_location` fields and the `counter` field are stored but only
/// populated once synthesis lands.
public struct FigureCaption: NativeElement {
    public static let info = ElementInfo(
        name: "caption",
        title: "Figure Caption",
        fields: [
            FieldInfo(id: 0, name: "position", settable: true),
            FieldInfo(id: 1, name: "separator", settable: true),
            FieldInfo(id: 2, name: "body", required: true),
            FieldInfo(id: 3, name: "kind"),
            FieldInfo(id: 4, name: "supplement"),
            FieldInfo(id: 5, name: "numbering"),
            FieldInfo(id: 6, name: "figure-location"),
            FieldInfo(id: 7, name: "counter"),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// The caption's position in the figure.
    public var position: OuterVAlignment = .bottom

    /// The separator which will appear between the number and body.
    public var separator: Smart<Content> = .auto

    /// The caption's body.
    public var body: Content

    /// The figure's kind (synthesized).
    public var kind: FigureKind? = nil

    /// The figure's supplement (synthesized).
    public var supplement: Content? = nil

    /// How to number the figure (synthesized).
    public var numbering: Numbering? = nil

    /// The figure's location (synthesized, internal upstream).
    public var figureLocation: Location? = nil

    /// The figure's counter (synthesized upstream).
    public var counter: Counter? = nil

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    /// Retrieves the locale separator. Port of
    /// `FigureCaption::local_separator_in` — the language-dependent
    /// default separator table.
    public func resolveSeparator(styles: StyleChain) -> Content {
        if case let .custom(c) = separator { return c }
        let lang = Locale.getIn(styles).lang
        let sep: String
        if lang == .CHINESE { sep = "\u{2003}" }
        else if lang == .FRENCH { sep = ".\u{a0}\u{2013} " }
        else if lang == .RUSSIAN { sep = ". " }
        else { sep = ": " }
        return TextElem.packed(sep)
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return position.intoValue()
        case 1:
            if separator.isAuto { return .auto }
            return separator.custom().map { .content($0) } ?? .none
        case 2: return .content(body)
        case 3: return kind?.intoValue() ?? .none
        case 4: return supplement.map { .content($0) } ?? .none
        case 5: return numbering?.intoValue() ?? .none
        case 6: return .none // Location has no Value representation
        case 7: return counter?.intoValue() ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let v): position = try OuterVAlignment.fromValue(v).get()
        case (1, .auto): separator = .auto
        case (1, let .content(c)): separator = .custom(c)
        case (2, let .content(c)): body = c
        default: break
        }
    }
}

extension FigureCaption: Castable, IntoValue, FromValue {
    /// Port of `cast! { FigureCaption, v: Content => v.unpack::<Self>()
    /// .unwrap_or_else(Self::new) }` — any content becomes a caption body.
    public static var input: CastInfo { .type(Type.of(Content.self)) }
    public static var output: CastInfo { .type(Type.of(Content.self)) }

    public static func castable(_ value: Value) -> Bool {
        Content.castable(value)
    }

    public func intoValue() -> Value { .content(Content(self)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .content(c) = value else { return .failure(error(value)) }
        if let caption = c.packed(FigureCaption.self) {
            return .success(caption)
        }
        return .success(FigureCaption(body: c))
    }
}
