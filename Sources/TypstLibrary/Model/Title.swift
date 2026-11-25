import TypstSyntax

/// A document title.
///
/// Port of `TitleElem` in `model/title.rs`. `resolveBody` needs
/// `DocumentElem.title` style-chain resolution with `Lang`-free string
/// storage — implemented against the ported `DocumentElem.title` field.
public struct TitleElem: NativeElement {
    public static let info = ElementInfo(
        name: "title",
        title: "Title",
        fields: [
            FieldInfo(id: 0, name: "body", settable: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// The content of the title. When `auto`, defaults to the document
    /// title set via `set document(title: [..])`.
    public var body: Smart<Content> = .auto

    public var span: Span = .detached

    /// Resolve the body against the style chain (upstream `resolve_body`).
    /// Falls back to `document.title`; errors when neither is set.
    public func resolveBody(styles: StyleChain) -> HintedStrResult<Content> {
        switch body {
        case let .custom(b): return .success(b)
        case .auto:
            // `DocumentElem.title` is field 0 upstream; resolved via the
            // style chain's stored value.
            guard let value = styles.get(Element(DocumentElem.self), 0),
                  case let .content(c) = value else {
                return .failure(HintedString(
                    message: "document title was not set",
                    hints: [
                        "set the title with `set document(title: [...])`",
                        "or provide an explicit body with `title[..]`",
                    ]))
            }
            return .success(c)
        }
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0:
            if body.isAuto { return .auto }
            return body.custom().map { .content($0) } ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, .auto): body = .auto
        case (0, let .content(c)): body = .custom(c)
        default: break
        }
    }
}

extension TitleElem: ShowSetCapable {
    /// Port of `ShowSet for Packed<TitleElem>` — large bold text with
    /// generous spacing that sticks to the top of the page.
    public func showSet(styles: StyleChain) -> Styles {
        func prop(_ elem: Element, _ field: UInt8, _ value: Value) -> Style {
            .property(Property(elem: elem, field: field, value: value))
        }
        func spacing(_ em: Double) -> Value {
            Smart<Spacing>.custom(.rel(
                Rel<Length>(Length(Em(em))))).intoValue()
        }
        return Styles([
            prop(Element(TextElem.self), TextElem.sizeFieldID,
                 TextSize(Length(Em(1.7))).intoValue()),
            prop(Element(TextElem.self), TextElem.weightFieldID,
                 FontWeight.bold.intoValue()),
            prop(Element(BlockElem.self), 8, spacing(1.125)),
            prop(Element(BlockElem.self), 9, spacing(0.75)),
            prop(Element(BlockElem.self), 11, .bool(true)),
        ])
    }
}
