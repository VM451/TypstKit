import Foundation
import TypstSyntax
import TypstUtils

// Text decoration elements from upstream `text/deco.rs` plus the
// `TopEdge`/`BottomEdge` types from `text/mod.rs`.

// MARK: - Edge types

/// Metrics that describe the top edge of text.
/// Port of `TopEdgeMetric` in `text/mod.rs`.
public enum TopEdgeMetric: String, Sendable, Hashable, CaseIterable {
    /// The font's ascender, which typically exceeds the height of all glyphs.
    case ascender
    /// The approximate height of uppercase letters.
    case capHeight = "cap-height"
    /// The approximate height of non-ascending lowercase letters.
    case xHeight = "x-height"
    /// The baseline on which the letters rest.
    case baseline
    /// The top edge of the glyph's bounding box.
    case bounds
}

extension TopEdgeMetric: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union(allCases.map { .value(.str(Str($0.rawValue)), doc: "") })
    }
    public static var output: CastInfo { input }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return TopEdgeMetric(rawValue: s.value) != nil
    }
    public func intoValue() -> Value { .str(Str(rawValue)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value,
              let v = TopEdgeMetric(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(v)
    }
}

/// Metrics that describe the bottom edge of text.
/// Port of `BottomEdgeMetric` in `text/mod.rs`.
public enum BottomEdgeMetric: String, Sendable, Hashable, CaseIterable {
    /// The baseline on which the letters rest.
    case baseline
    /// The bottom edge of descenders.
    case descender
    /// The bottom edge of the glyph's bounding box.
    case bounds
}

extension BottomEdgeMetric: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union(allCases.map { .value(.str(Str($0.rawValue)), doc: "") })
    }
    public static var output: CastInfo { input }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return BottomEdgeMetric(rawValue: s.value) != nil
    }
    public func intoValue() -> Value { .str(Str(rawValue)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value,
              let v = BottomEdgeMetric(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(v)
    }
}

/// The top edge of a highlight.
/// Port of `TopEdge` in `text/mod.rs`.
public enum TopEdge: Sendable, Hashable {
    /// An edge specified via font metrics or bounding box.
    case metric(TopEdgeMetric)
    /// An edge specified as a length.
    case length(Length)
}

extension TopEdge: Castable, IntoValue, FromValue {
    public static var input: CastInfo { TopEdgeMetric.input + Length.input }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        TopEdgeMetric.castable(value) || Length.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .metric(m): return m.intoValue()
        case let .length(l): return l.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if TopEdgeMetric.castable(value) {
            return TopEdgeMetric.fromValue(value).map { .metric($0) }
        }
        return Length.fromValue(value).map { .length($0) }
    }
}

/// The bottom edge of a highlight.
/// Port of `BottomEdge` in `text/mod.rs`.
public enum BottomEdge: Sendable, Hashable {
    /// An edge specified via font metrics or bounding box.
    case metric(BottomEdgeMetric)
    /// An edge specified as a length.
    case length(Length)
}

extension BottomEdge: Castable, IntoValue, FromValue {
    public static var input: CastInfo { BottomEdgeMetric.input + Length.input }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        BottomEdgeMetric.castable(value) || Length.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .metric(m): return m.intoValue()
        case let .length(l): return l.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if BottomEdgeMetric.castable(value) {
            return BottomEdgeMetric.fromValue(value).map { .metric($0) }
        }
        return Length.fromValue(value).map { .length($0) }
    }
}

// MARK: - Decoration elements

/// Underlines text.
///
/// Port of `UnderlineElem` in `text/deco.rs`.
public struct UnderlineElem: NativeElement {
    public static let info = ElementInfo(
        name: "underline",
        title: "Underline",
        fields: [
            FieldInfo(id: 0, name: "stroke", settable: true),
            FieldInfo(id: 1, name: "offset", settable: true),
            FieldInfo(id: 2, name: "extent", settable: true),
            FieldInfo(id: 3, name: "evade", settable: true),
            FieldInfo(id: 4, name: "background", settable: true),
            FieldInfo(id: 5, name: "body", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// How to stroke the underline.
    public var stroke: Smart<Stroke<Length>> = .auto
    /// The underline's offset.
    public var offset: Smart<Length> = .auto
    /// The underline's extent.
    public var extent: Length = .zero
    /// Whether the underline evades glyphs.
    public var evade: Bool = true
    /// Whether the line is in the background.
    public var background: Bool = false
    /// The content to underline.
    public var body: Content

    public var span: Span = .detached

    public init(stroke: Smart<Stroke<Length>> = .auto,
                offset: Smart<Length> = .auto,
                extent: Length = .zero,
                evade: Bool = true,
                background: Bool = false,
                body: Content) {
        self.stroke = stroke
        self.offset = offset
        self.extent = extent
        self.evade = evade
        self.background = background
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return stroke.intoValue()
        case 1: return offset.intoValue()
        case 2: return extent.intoValue()
        case 3: return .bool(evade)
        case 4: return .bool(background)
        case 5: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: stroke = try Smart<Stroke<Length>>.fromValue(value).get()
        case 1: offset = try Smart<Length>.fromValue(value).get()
        case 2: extent = try Length.fromValue(value).get()
        case 3:
            if case .bool(let b) = value { evade = b }
        case 4:
            if case .bool(let b) = value { background = b }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = UnderlineElem(
            stroke: try args.namedT("stroke") ?? .auto,
            offset: try args.namedT("offset") ?? .auto,
            extent: try args.namedT("extent") ?? .zero,
            evade: try args.namedT("evade") ?? true,
            background: try args.namedT("background") ?? false,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Overlines text.
///
/// Port of `OverlineElem` in `text/deco.rs`.
public struct OverlineElem: NativeElement {
    public static let info = ElementInfo(
        name: "overline",
        title: "Overline",
        fields: [
            FieldInfo(id: 0, name: "stroke", settable: true),
            FieldInfo(id: 1, name: "offset", settable: true),
            FieldInfo(id: 2, name: "extent", settable: true),
            FieldInfo(id: 3, name: "evade", settable: true),
            FieldInfo(id: 4, name: "background", settable: true),
            FieldInfo(id: 5, name: "body", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// How to stroke the overline.
    public var stroke: Smart<Stroke<Length>> = .auto
    /// The overline's offset.
    public var offset: Smart<Length> = .auto
    /// The overline's extent.
    public var extent: Length = .zero
    /// Whether the overline evades glyphs.
    public var evade: Bool = true
    /// Whether the line is in the background.
    public var background: Bool = false
    /// The content to overline.
    public var body: Content

    public var span: Span = .detached

    public init(stroke: Smart<Stroke<Length>> = .auto,
                offset: Smart<Length> = .auto,
                extent: Length = .zero,
                evade: Bool = true,
                background: Bool = false,
                body: Content) {
        self.stroke = stroke
        self.offset = offset
        self.extent = extent
        self.evade = evade
        self.background = background
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return stroke.intoValue()
        case 1: return offset.intoValue()
        case 2: return extent.intoValue()
        case 3: return .bool(evade)
        case 4: return .bool(background)
        case 5: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: stroke = try Smart<Stroke<Length>>.fromValue(value).get()
        case 1: offset = try Smart<Length>.fromValue(value).get()
        case 2: extent = try Length.fromValue(value).get()
        case 3:
            if case .bool(let b) = value { evade = b }
        case 4:
            if case .bool(let b) = value { background = b }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = OverlineElem(
            stroke: try args.namedT("stroke") ?? .auto,
            offset: try args.namedT("offset") ?? .auto,
            extent: try args.namedT("extent") ?? .zero,
            evade: try args.namedT("evade") ?? true,
            background: try args.namedT("background") ?? false,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Strikes through text.
///
/// Port of `StrikeElem` in `text/deco.rs`.
public struct StrikeElem: NativeElement {
    public static let info = ElementInfo(
        name: "strike",
        title: "Strikethrough",
        fields: [
            FieldInfo(id: 0, name: "stroke", settable: true),
            FieldInfo(id: 1, name: "offset", settable: true),
            FieldInfo(id: 2, name: "extent", settable: true),
            FieldInfo(id: 3, name: "background", settable: true),
            FieldInfo(id: 4, name: "body", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// How to stroke the strikethrough.
    public var stroke: Smart<Stroke<Length>> = .auto
    /// The strikethrough's offset.
    public var offset: Smart<Length> = .auto
    /// The strikethrough's extent.
    public var extent: Length = .zero
    /// Whether the line is in the background.
    public var background: Bool = false
    /// The content to strike through.
    public var body: Content

    public var span: Span = .detached

    public init(stroke: Smart<Stroke<Length>> = .auto,
                offset: Smart<Length> = .auto,
                extent: Length = .zero,
                background: Bool = false,
                body: Content) {
        self.stroke = stroke
        self.offset = offset
        self.extent = extent
        self.background = background
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return stroke.intoValue()
        case 1: return offset.intoValue()
        case 2: return extent.intoValue()
        case 3: return .bool(background)
        case 4: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: stroke = try Smart<Stroke<Length>>.fromValue(value).get()
        case 1: offset = try Smart<Length>.fromValue(value).get()
        case 2: extent = try Length.fromValue(value).get()
        case 3:
            if case .bool(let b) = value { background = b }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = StrikeElem(
            stroke: try args.namedT("stroke") ?? .auto,
            offset: try args.namedT("offset") ?? .auto,
            extent: try args.namedT("extent") ?? .zero,
            background: try args.namedT("background") ?? false,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Highlights text.
///
/// Port of `HighlightElem` in `text/deco.rs`.
public struct HighlightElem: NativeElement {
    /// The default highlight color (`Color::from_u8(0xFF, 0xFD, 0x11, 0xA1)`).
    public static let defaultFill: Paint = .solid(Color.process(
        .rgb(Rgb(r: 1.0, g: 253.0 / 255.0, b: 17.0 / 255.0, a: 161.0 / 255.0))))

    public static let info = ElementInfo(
        name: "highlight",
        title: "Highlight",
        fields: [
            FieldInfo(id: 0, name: "fill", settable: true),
            FieldInfo(id: 1, name: "stroke", settable: true),
            FieldInfo(id: 2, name: "top-edge", settable: true),
            FieldInfo(id: 3, name: "bottom-edge", settable: true),
            FieldInfo(id: 4, name: "extent", settable: true),
            FieldInfo(id: 5, name: "radius", settable: true),
            FieldInfo(id: 6, name: "body", required: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// How to fill the highlight.
    public var fill: Paint? = HighlightElem.defaultFill
    /// How to stroke the highlight.
    public var stroke: Sides<Optional<Optional<Stroke<Length>>>> = .splat(nil)
    /// The highlight's top edge.
    public var topEdge: TopEdge = .metric(.ascender)
    /// The highlight's bottom edge.
    public var bottomEdge: BottomEdge = .metric(.descender)
    /// The highlight's extent.
    public var extent: Length = .zero
    /// How much to round the highlight's corners.
    public var radius: Corners<Optional<Rel<Length>>> = .splat(nil)
    /// The content to highlight.
    public var body: Content

    public var span: Span = .detached

    public init(fill: Paint? = HighlightElem.defaultFill,
                stroke: Sides<Optional<Optional<Stroke<Length>>>> = .splat(nil),
                topEdge: TopEdge = .metric(.ascender),
                bottomEdge: BottomEdge = .metric(.descender),
                extent: Length = .zero,
                radius: Corners<Optional<Rel<Length>>> = .splat(nil),
                body: Content) {
        self.fill = fill
        self.stroke = stroke
        self.topEdge = topEdge
        self.bottomEdge = bottomEdge
        self.extent = extent
        self.radius = radius
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return fill?.intoValue()
        case 1: return stroke.intoValue()
        case 2: return topEdge.intoValue()
        case 3: return bottomEdge.intoValue()
        case 4: return extent.intoValue()
        case 5: return radius.intoValue()
        case 6: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0:
            if case .none = value { fill = nil }
            else { fill = try Paint.fromValue(value).get() }
        case 1: stroke = try Sides<Optional<Optional<Stroke<Length>>>>
            .fromValue(value).get()
        case 2: topEdge = try TopEdge.fromValue(value).get()
        case 3: bottomEdge = try BottomEdge.fromValue(value).get()
        case 4: extent = try Length.fromValue(value).get()
        case 5: radius = try Corners<Optional<Rel<Length>>>.fromValue(value).get()
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = HighlightElem(
            fill: try args.namedT("fill") ?? HighlightElem.defaultFill,
            stroke: try args.namedT("stroke") ?? .splat(nil),
            topEdge: try args.namedT("top-edge") ?? .metric(.ascender),
            bottomEdge: try args.namedT("bottom-edge") ?? .metric(.descender),
            extent: try args.namedT("extent") ?? .zero,
            radius: try args.namedT("radius") ?? .splat(nil),
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}
