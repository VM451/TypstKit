import TypstSyntax
import TypstUtils

// MARK: - Sizing

/// How to size something along an axis.
///
/// Port of `Sizing` in `layout/container.rs`.
public enum Sizing: Sendable, Hashable {
    /// A track that fits its item's contents.
    case auto
    /// A size specified in absolute terms and relative to the parent's size.
    case rel(Rel<Length>)
    /// A size specified as a fraction of the remaining free space.
    case fr(Fr)

    /// Whether this is an automatic sizing.
    public var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    /// Whether this is fractional sizing.
    public var isFractional: Bool {
        if case .fr = self { return true }
        return false
    }

    /// `Smart<Rel>` → `Sizing` (upstream `From<Smart<Rel>>`).
    public init(smartRel: Smart<Rel<Length>>) {
        switch smartRel {
        case .auto: self = .auto
        case .custom(let rel): self = .rel(rel)
        }
    }
}

extension Sizing: Default {
    public static var `default`: Sizing { .auto }
}

extension Sizing: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([.value(.auto, doc: ""), Rel<Length>.input, Fr.input])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        if case .auto = value { return true }
        return Rel<Length>.castable(value) || Fr.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case .auto: return .auto
        case .rel(let rel): return rel.intoValue()
        case .fr(let fr): return fr.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if case .auto = value { return .success(.auto) }
        if Rel<Length>.castable(value) {
            return Rel<Length>.fromValue(value).map { .rel($0) }
        }
        if Fr.castable(value) {
            return Fr.fromValue(value).map { .fr($0) }
        }
        return .failure(error(value))
    }
}

// MARK: - BaselinePos

/// Configuration for a box's baseline.
///
/// `nil` fields mean unspecified and are inherited. Port of `BaselinePos`
/// in `layout/container.rs`.
public struct BaselinePos: Sendable, Hashable {
    /// Baseline's reference position relative to the height of the box's
    /// contents.
    public var at: Smart<VAlignment>?
    /// Amount to shift the baseline by.
    public var shift: Rel<Length>?

    public init(at: Smart<VAlignment>? = nil, shift: Rel<Length>? = nil) {
        self.at = at
        self.shift = shift
    }
}

extension BaselinePos: Default {
    /// Upstream default: `{at: auto, shift: 0pt}` — both fields specified.
    public static var `default`: BaselinePos {
        BaselinePos(at: .auto, shift: Rel<Length>.zero())
    }
}

extension BaselinePos: Fold {
    /// Inner `some` wins per field, otherwise the outer value is kept
    /// (upstream `Fold for BaselinePos`).
    public static func fold(_ inner: Self, _ outer: Self) -> Self {
        BaselinePos(at: inner.at ?? outer.at, shift: inner.shift ?? outer.shift)
    }
}

extension BaselinePos: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([Smart<VAlignment>.input, Rel<Length>.input,
                .type(Type.of(Dict.self))])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        if Smart<VAlignment>.castable(value) || Rel<Length>.castable(value) {
            return true
        }
        if case .dict = value { return true }
        return false
    }

    /// The dict form consumed by `intoValue` (upstream `From<BaselinePos>
    /// for Dict`).
    public func intoDict() -> Dict {
        var dict = Dict()
        if let at { dict.insert("at", at.intoValue()) }
        if let shift { dict.insert("shift", shift.intoValue()) }
        return dict
    }

    public func intoValue() -> Value { .dict(intoDict()) }

    static func parseDict(_ dict: inout Dict) throws -> BaselinePos {
        func take<W: FromValue & IntoValue>(
            _ key: String
        ) throws -> W? {
            guard case .success(let v) = dict.take(key) else { return nil }
            return try W.fromValue(v).get()
        }
        let at: Smart<VAlignment>? = try take("at")
        let shift: Rel<Length>? = try take("shift")
        if case .failure(let e) = dict.finish(expected: ["at", "shift"]) {
            throw HintedString(e.message)
        }
        return BaselinePos(at: at, shift: shift)
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Smart<VAlignment>.castable(value) {
            return Smart<VAlignment>.fromValue(value).map {
                BaselinePos(at: $0, shift: nil)
            }
        }
        if Rel<Length>.castable(value) {
            return Rel<Length>.fromValue(value).map {
                BaselinePos(at: nil, shift: $0)
            }
        }
        if case .dict(var dict) = value {
            do { return .success(try parseDict(&dict)) }
            catch let e as HintedString { return .failure(e) }
            catch { return .failure(HintedString("\(error)")) }
        }
        return .failure(error(value))
    }
}

// MARK: - BlockBody

/// The contents of a block.
///
/// Port of `BlockBody` in `layout/container.rs`. The `SingleLayouter` and
/// `MultiLayouter` callback variants are deferred until `Frame`/`Fragment`
/// land (tracked in `PARITY_TRACKER.md`).
public enum BlockBody: Sendable, Hashable {
    /// The block contains normal content.
    case content(Content)
}

extension BlockBody: Default {
    public static var `default`: BlockBody { .content(.empty) }
}

extension BlockBody: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Content.input }
    public static var output: CastInfo { Content.output }

    public static func castable(_ value: Value) -> Bool {
        Content.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case .content(let content): return content.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        Content.fromValue(value).map { .content($0) }
    }
}

// MARK: - BoxElem

/// An inline-level container.
///
/// Port of `BoxElem` in `layout/container.rs`.
public struct BoxElem: NativeElement {
    public static let info = ElementInfo(
        name: "box",
        title: "Box",
        fields: [
            FieldInfo(id: 0, name: "width", settable: true),
            FieldInfo(id: 1, name: "height", settable: true),
            FieldInfo(id: 2, name: "baseline", settable: true),
            FieldInfo(id: 3, name: "fill", settable: true),
            FieldInfo(id: 4, name: "stroke", settable: true),
            FieldInfo(id: 5, name: "radius", settable: true),
            FieldInfo(id: 6, name: "inset", settable: true),
            FieldInfo(id: 7, name: "outset", settable: true),
            FieldInfo(id: 8, name: "clip", settable: true),
            FieldInfo(id: 9, name: "body"),
        ],
        capabilities: []
    )

    /// The width of the box.
    public var width: Sizing = .auto
    /// The height of the box.
    public var height: Smart<Rel<Length>> = .auto
    /// The vertical position of the box's baseline.
    public var baseline: BaselinePos = .default
    /// The box's background color.
    public var fill: Paint? = nil
    /// The box's border color.
    public var stroke: Sides<Optional<Optional<Stroke<Length>>>> = .splat(nil)
    /// How much to round the box's corners.
    public var radius: Corners<Optional<Rel<Length>>> = .splat(nil)
    /// How much to pad the box's content.
    public var inset: Sides<Optional<Rel<Length>>> = .splat(nil)
    /// How much to expand the box's size without affecting the layout.
    public var outset: Sides<Optional<Rel<Length>>> = .splat(nil)
    /// Whether to clip the content inside the box.
    public var clip: Bool = false
    /// The contents of the box.
    public var body: Content? = nil

    public var span: Span = .detached

    public init(width: Sizing = .auto,
                height: Smart<Rel<Length>> = .auto,
                baseline: BaselinePos = .default,
                fill: Paint? = nil,
                stroke: Sides<Optional<Optional<Stroke<Length>>>> = .splat(nil),
                radius: Corners<Optional<Rel<Length>>> = .splat(nil),
                inset: Sides<Optional<Rel<Length>>> = .splat(nil),
                outset: Sides<Optional<Rel<Length>>> = .splat(nil),
                clip: Bool = false,
                body: Content? = nil) {
        self.width = width
        self.height = height
        self.baseline = baseline
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        self.inset = inset
        self.outset = outset
        self.clip = clip
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return width.intoValue()
        case 1: return height.intoValue()
        case 2: return baseline.intoValue()
        case 3: return fill?.intoValue() ?? .none
        case 4: return stroke.intoValue()
        case 5: return radius.intoValue()
        case 6: return inset.intoValue()
        case 7: return outset.intoValue()
        case 8: return .bool(clip)
        case 9: return body?.intoValue() ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: width = try Sizing.fromValue(value).get()
        case 1: height = try Smart<Rel<Length>>.fromValue(value).get()
        case 2: baseline = try BaselinePos.fromValue(value).get()
        case 3:
            if case .none = value { fill = nil }
            else { fill = try Paint.fromValue(value).get() }
        case 4: stroke = try Sides<Optional<Optional<Stroke<Length>>>>
            .fromValue(value).get()
        case 5: radius = try Corners<Optional<Rel<Length>>>.fromValue(value).get()
        case 6: inset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 7: outset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 8:
            if case .bool(let b) = value { clip = b }
        case 9:
            if case .content(let c) = value { body = c }
            if case .none = value { body = nil }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = BoxElem(
            width: try args.namedT("width") ?? .auto,
            height: try args.namedT("height") ?? .auto,
            baseline: try args.namedT("baseline") ?? .default,
            fill: try args.namedT("fill"),
            stroke: try args.namedT("stroke") ?? .splat(nil),
            radius: try args.namedT("radius") ?? .splat(nil),
            inset: try args.namedT("inset") ?? .splat(nil),
            outset: try args.namedT("outset") ?? .splat(nil),
            clip: try args.namedT("clip") ?? false,
            body: try args.findT()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - BlockElem

/// A block-level container.
///
/// Port of `BlockElem` in `layout/container.rs`.
public struct BlockElem: NativeElement {
    public static let info = ElementInfo(
        name: "block",
        title: "Block-level container",
        fields: [
            FieldInfo(id: 0, name: "width", settable: true),
            FieldInfo(id: 1, name: "height", settable: true),
            FieldInfo(id: 2, name: "breakable", settable: true),
            FieldInfo(id: 3, name: "fill", settable: true),
            FieldInfo(id: 4, name: "stroke", settable: true),
            FieldInfo(id: 5, name: "radius", settable: true),
            FieldInfo(id: 6, name: "inset", settable: true),
            FieldInfo(id: 7, name: "outset", settable: true),
            FieldInfo(id: 8, name: "above", settable: true),
            FieldInfo(id: 9, name: "below", settable: true),
            FieldInfo(id: 10, name: "clip", settable: true),
            FieldInfo(id: 11, name: "sticky", settable: true),
            FieldInfo(id: 12, name: "body"),
        ],
        capabilities: []
    )

    /// The block's width.
    public var width: Smart<Rel<Length>> = .auto
    /// The block's height.
    public var height: Sizing = .auto
    /// Whether the block can be broken and continue on the next page.
    public var breakable: Bool = true
    /// The block's background color.
    public var fill: Paint? = nil
    /// The block's border color.
    public var stroke: Sides<Optional<Optional<Stroke<Length>>>> = .splat(nil)
    /// How much to round the block's corners.
    public var radius: Corners<Optional<Rel<Length>>> = .splat(nil)
    /// How much to pad the block's content.
    public var inset: Sides<Optional<Rel<Length>>> = .splat(nil)
    /// How much to expand the block's size without affecting the layout.
    public var outset: Sides<Optional<Rel<Length>>> = .splat(nil)
    /// The spacing between this block and its predecessor.
    public var above: Smart<Spacing> = .auto
    /// The spacing between this block and its successor.
    public var below: Smart<Spacing> = .auto
    /// Whether to clip the content inside the block.
    public var clip: Bool = false
    /// Whether this block must stick to the following one.
    public var sticky: Bool = false
    /// The contents of the block.
    public var body: BlockBody? = nil

    public var span: Span = .detached

    public init(width: Smart<Rel<Length>> = .auto,
                height: Sizing = .auto,
                breakable: Bool = true,
                fill: Paint? = nil,
                stroke: Sides<Optional<Optional<Stroke<Length>>>> = .splat(nil),
                radius: Corners<Optional<Rel<Length>>> = .splat(nil),
                inset: Sides<Optional<Rel<Length>>> = .splat(nil),
                outset: Sides<Optional<Rel<Length>>> = .splat(nil),
                above: Smart<Spacing> = .auto,
                below: Smart<Spacing> = .auto,
                clip: Bool = false,
                sticky: Bool = false,
                body: BlockBody? = nil) {
        self.width = width
        self.height = height
        self.breakable = breakable
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        self.inset = inset
        self.outset = outset
        self.above = above
        self.below = below
        self.clip = clip
        self.sticky = sticky
        self.body = body
    }

    /// Creates a new block element with a normal content body, packed into
    /// type-erased content (upstream `BlockElem::packed`).
    public static func packed(_ body: Content) -> Content {
        Content(BlockElem(body: .content(body)))
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return width.intoValue()
        case 1: return height.intoValue()
        case 2: return .bool(breakable)
        case 3: return fill?.intoValue() ?? .none
        case 4: return stroke.intoValue()
        case 5: return radius.intoValue()
        case 6: return inset.intoValue()
        case 7: return outset.intoValue()
        case 8: return above.intoValue()
        case 9: return below.intoValue()
        case 10: return .bool(clip)
        case 11: return .bool(sticky)
        case 12: return body?.intoValue() ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: width = try Smart<Rel<Length>>.fromValue(value).get()
        case 1: height = try Sizing.fromValue(value).get()
        case 2:
            if case .bool(let b) = value { breakable = b }
        case 3:
            if case .none = value { fill = nil }
            else { fill = try Paint.fromValue(value).get() }
        case 4: stroke = try Sides<Optional<Optional<Stroke<Length>>>>
            .fromValue(value).get()
        case 5: radius = try Corners<Optional<Rel<Length>>>.fromValue(value).get()
        case 6: inset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 7: outset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 8: above = try Smart<Spacing>.fromValue(value).get()
        case 9: below = try Smart<Spacing>.fromValue(value).get()
        case 10:
            if case .bool(let b) = value { clip = b }
        case 11:
            if case .bool(let b) = value { sticky = b }
        case 12: body = try BlockBody.fromValue(value).get()
        default: break
        }
    }

    /// Custom construct: `spacing` is an external field feeding `above`/
    /// `below` defaults (upstream `#[external]` + `#[parse]` blocks).
    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        let spacing: Smart<Spacing>? = try args.namedT("spacing")
        var elem = BlockElem(
            width: try args.namedT("width") ?? .auto,
            height: try args.namedT("height") ?? .auto,
            breakable: try args.namedT("breakable") ?? true,
            fill: try args.namedT("fill"),
            stroke: try args.namedT("stroke") ?? .splat(nil),
            radius: try args.namedT("radius") ?? .splat(nil),
            inset: try args.namedT("inset") ?? .splat(nil),
            outset: try args.namedT("outset") ?? .splat(nil),
            above: (try args.namedT("above") ?? spacing) ?? .auto,
            below: (try args.namedT("below") ?? spacing) ?? .auto,
            clip: try args.namedT("clip") ?? false,
            sticky: try args.namedT("sticky") ?? false,
            body: try args.findT()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}
