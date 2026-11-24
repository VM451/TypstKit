import Foundation
import TypstSyntax
import TypstUtils

// Quote machinery from upstream `model/quote.rs`.

/// A type that accumulates depth when folded.
///
/// Port of `Depth` in `foundations/styles.rs` — used by the ghost
/// `depth` fields on `quote` and `list`.
public struct Depth: Sendable, Hashable {
    public var value: Int

    public init(_ value: Int = 0) { self.value = value }
}

extension Depth: Default {
    public static var `default`: Depth { Depth(0) }
}

extension Depth: Fold {
    /// Depths add when folded (upstream `Fold for Depth`).
    public static func fold(_ inner: Depth, _ outer: Depth) -> Depth {
        Depth(outer.value + inner.value)
    }
}

/// A quote's attribution: inline content or a bibliography label.
///
/// Port of `Attribution` in `model/quote.rs`.
public enum Attribution: Sendable, Hashable {
    case content(Content)
    case label(Label)
}

extension Attribution: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Content.input + Label.input }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Content.castable(value) || Label.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .content(c): return c.intoValue()
        case let .label(l): return l.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Content.castable(value), case .success(let c) = Content.fromValue(value) {
            return .success(.content(c))
        }
        return Label.fromValue(value).map { .label($0) }
    }
}

extension Attribution {
    /// Port of `Attribution::realize` — em-dash, space, then content or a
    /// prose-form citation.
    public func realize(span: Span) -> Content {
        let tail: Content
        switch self {
        case let .content(content):
            tail = content
        case let .label(label):
            var cite = CiteElem(key: label)
            cite.form = .prose
            cite.span = span
            tail = Content(cite)
        }
        return Content.sequence([
            TextElem.packed("—"),
            SpaceElem.shared,
            tail,
        ])
    }
}

/// A quotation.
///
/// Port of `QuoteElem` in `model/quote.rs`. `quoted(_:)` stays deferred —
/// it needs the `SmartQuotes` locale tables from `text/smartquote.rs`.
public struct QuoteElem: NativeElement {
    public static let info = ElementInfo(
        name: "quote",
        title: "Quote",
        fields: [
            FieldInfo(id: 0, name: "block", settable: true),
            FieldInfo(id: 1, name: "quotes", settable: true),
            FieldInfo(id: 2, name: "attribution", settable: true),
            FieldInfo(id: 3, name: "body", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// Whether the quote is displayed as a separate block.
    public var block: Bool = false
    /// Whether to add quotation marks.
    public var quotes: Smart<Bool> = .auto
    /// The quote's attribution.
    public var attribution: Attribution? = nil
    /// The quoted content.
    public var body: Content
    /// Nesting depth (upstream `#[internal] #[fold] #[ghost]` field —
    /// synthesized during realization, not a constructor argument).
    public var depth: Depth = .default

    public var span: Span = .detached

    public init(block: Bool = false,
                quotes: Smart<Bool> = .auto,
                attribution: Attribution? = nil,
                body: Content) {
        self.block = block
        self.quotes = quotes
        self.attribution = attribution
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(block)
        case 1: return quotes.intoValue()
        case 2: return attribution?.intoValue() ?? .none
        case 3: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0:
            if case .bool(let b) = value { block = b }
        case 1: quotes = try Smart<Bool>.fromValue(value).get()
        case 2:
            if case .none = value { attribution = nil }
            else { attribution = try Attribution.fromValue(value).get() }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = QuoteElem(
            block: try args.namedT("block") ?? false,
            quotes: try args.namedT("quotes") ?? .auto,
            attribution: try args.namedT("attribution"),
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

extension QuoteElem: ShowSetCapable {
    /// Port of `ShowSet for Packed<QuoteElem>` — block quotes get padding
    /// and spacing.
    public func showSet(styles: StyleChain) -> Styles {
        // Upstream `self.block.get(styles)` resolves the `Settable<bool>`
        // field: own value if set at construction, else the style chain.
        // This port stores plain values, so union the two sources — the
        // only divergence is an explicit `block: false` construct arg
        // overriding a `set quote(block: true)` rule.
        let styled = styles.get(Element(QuoteElem.self), 0)
            .flatMap { if case .bool(let b) = $0 { return b }; return nil } ?? false
        guard block || styled else { return Styles() }
        func prop(_ elem: Element, _ field: UInt8, _ value: Value) -> Style {
            .property(Property(elem: elem, field: field, value: value))
        }
        let pad = Element(PadElem.self)
        let blockElem = Element(BlockElem.self)
        return Styles([
            prop(pad, 0, Rel<Length>(Length(Em(1.0))).intoValue()),
            prop(pad, 2, Rel<Length>(Length(Em(1.0))).intoValue()),
            prop(blockElem, 8, Smart<Spacing>.custom(.rel(
                Rel<Length>(Length(Em(2.4))))).intoValue()),
            prop(blockElem, 9, Smart<Spacing>.custom(.rel(
                Rel<Length>(Length(Em(1.8))))).intoValue()),
        ])
    }
}
