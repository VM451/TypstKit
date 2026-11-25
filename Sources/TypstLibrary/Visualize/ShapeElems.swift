import Foundation
import TypstSyntax
import TypstUtils

// Shape elements from upstream `visualize/{shape,line,polygon}.rs`.
// `measure` implementations stay deferred with the layout milestone.

// MARK: - Shared helpers

/// The default `inset` shared by the shape elements
/// (`Sides::splat(Some(Abs::pt(5.0).into()))` upstream).
public let shapeInset: Sides<Optional<Rel<Length>>> =
    .splat(.some(Rel<Length>(Length(Abs.pt(5.0)))))

/// Parse the `size`/`radius` external + `width`/`height` `#[parse]` pair
/// shared by `square` and `circle` (upstream `shape.rs`).
private func parseWidthHeight(
    _ args: inout Args,
    sizeName: String,
    diameter: Bool
) throws -> (Smart<Rel<Length>>, Sizing) {
    let size: Smart<Length>? = try args.namedT(sizeName)
    if let size {
        let rel = size.map { diameter ? 2.0 * Rel<Length>($0) : Rel<Length>($0) }
        return (rel, Sizing(smartRel: rel))
    }
    return (
        try args.namedT("width") ?? .auto,
        try args.namedT("height") ?? .auto
    )
}

// MARK: - RectElem

/// A rectangle with optional content.
///
/// Port of `RectElem` in `visualize/shape.rs`.
public struct RectElem: NativeElement {
    public static let info = ElementInfo(
        name: "rect",
        title: "Rectangle",
        fields: [
            FieldInfo(id: 0, name: "width", settable: true),
            FieldInfo(id: 1, name: "height", settable: true),
            FieldInfo(id: 2, name: "fill", settable: true),
            FieldInfo(id: 3, name: "stroke", settable: true),
            FieldInfo(id: 4, name: "radius", settable: true),
            FieldInfo(id: 5, name: "inset", settable: true),
            FieldInfo(id: 6, name: "outset", settable: true),
            FieldInfo(id: 7, name: "body"),
        ],
        capabilities: []
    )

    /// The rectangle's width, relative to its parent container.
    public var width: Smart<Rel<Length>> = .auto
    /// The rectangle's height, relative to its parent container.
    public var height: Sizing = .auto
    /// How to fill the rectangle.
    public var fill: Paint? = nil
    /// How to stroke the rectangle.
    public var stroke: Smart<Sides<Optional<Optional<Stroke<Length>>>>> = .auto
    /// How much to round the rectangle's corners.
    public var radius: Corners<Optional<Rel<Length>>> = .splat(nil)
    /// How much to pad the rectangle's content.
    public var inset: Sides<Optional<Rel<Length>>> = shapeInset
    /// How much to expand the rectangle's size without affecting layout.
    public var outset: Sides<Optional<Rel<Length>>> = .splat(nil)
    /// The content to place into the rectangle.
    public var body: Content? = nil

    public var span: Span = .detached

    public init(width: Smart<Rel<Length>> = .auto,
                height: Sizing = .auto,
                fill: Paint? = nil,
                stroke: Smart<Sides<Optional<Optional<Stroke<Length>>>>> = .auto,
                radius: Corners<Optional<Rel<Length>>> = .splat(nil),
                inset: Sides<Optional<Rel<Length>>> = shapeInset,
                outset: Sides<Optional<Rel<Length>>> = .splat(nil),
                body: Content? = nil) {
        self.width = width
        self.height = height
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        self.inset = inset
        self.outset = outset
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return width.intoValue()
        case 1: return height.intoValue()
        case 2: return fill?.intoValue()
        case 3: return stroke.intoValue()
        case 4: return radius.intoValue()
        case 5: return inset.intoValue()
        case 6: return outset.intoValue()
        case 7: return body?.intoValue() ?? Value.none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: width = try Smart<Rel<Length>>.fromValue(value).get()
        case 1: height = try Sizing.fromValue(value).get()
        case 2:
            if case .none = value { fill = nil }
            else { fill = try Paint.fromValue(value).get() }
        case 3: stroke = try Smart<Sides<Optional<Optional<Stroke<Length>>>>>
            .fromValue(value).get()
        case 4: radius = try Corners<Optional<Rel<Length>>>.fromValue(value).get()
        case 5: inset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 6: outset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 7:
            if case .content(let c) = value { body = c }
            if case .none = value { body = nil }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = RectElem(
            width: try args.namedT("width") ?? .auto,
            height: try args.namedT("height") ?? .auto,
            fill: try args.namedT("fill"),
            stroke: try args.namedT("stroke") ?? .auto,
            radius: try args.namedT("radius") ?? .splat(nil),
            inset: try args.namedT("inset") ?? shapeInset,
            outset: try args.namedT("outset") ?? .splat(nil),
            body: try args.findT()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - SquareElem

/// A square with optional content.
///
/// Port of `SquareElem` in `visualize/shape.rs`.
public struct SquareElem: NativeElement {
    public static let info = ElementInfo(
        name: "square",
        title: "Square",
        fields: [
            FieldInfo(id: 0, name: "width", settable: true),
            FieldInfo(id: 1, name: "height", settable: true),
            FieldInfo(id: 2, name: "fill", settable: true),
            FieldInfo(id: 3, name: "stroke", settable: true),
            FieldInfo(id: 4, name: "radius", settable: true),
            FieldInfo(id: 5, name: "inset", settable: true),
            FieldInfo(id: 6, name: "outset", settable: true),
            FieldInfo(id: 7, name: "body"),
        ],
        capabilities: []
    )

    /// The square's width.
    public var width: Smart<Rel<Length>> = .auto
    /// The square's height.
    public var height: Sizing = .auto
    /// How to fill the square.
    public var fill: Paint? = nil
    /// How to stroke the square.
    public var stroke: Smart<Sides<Optional<Optional<Stroke<Length>>>>> = .auto
    /// How much to round the square's corners.
    public var radius: Corners<Optional<Rel<Length>>> = .splat(nil)
    /// How much to pad the square's content.
    public var inset: Sides<Optional<Rel<Length>>> = shapeInset
    /// How much to expand the square's size without affecting layout.
    public var outset: Sides<Optional<Rel<Length>>> = .splat(nil)
    /// The content to place into the square.
    public var body: Content? = nil

    public var span: Span = .detached

    public init(width: Smart<Rel<Length>> = .auto,
                height: Sizing = .auto,
                fill: Paint? = nil,
                stroke: Smart<Sides<Optional<Optional<Stroke<Length>>>>> = .auto,
                radius: Corners<Optional<Rel<Length>>> = .splat(nil),
                inset: Sides<Optional<Rel<Length>>> = shapeInset,
                outset: Sides<Optional<Rel<Length>>> = .splat(nil),
                body: Content? = nil) {
        self.width = width
        self.height = height
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        self.inset = inset
        self.outset = outset
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return width.intoValue()
        case 1: return height.intoValue()
        case 2: return fill?.intoValue()
        case 3: return stroke.intoValue()
        case 4: return radius.intoValue()
        case 5: return inset.intoValue()
        case 6: return outset.intoValue()
        case 7: return body?.intoValue() ?? Value.none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: width = try Smart<Rel<Length>>.fromValue(value).get()
        case 1: height = try Sizing.fromValue(value).get()
        case 2:
            if case .none = value { fill = nil }
            else { fill = try Paint.fromValue(value).get() }
        case 3: stroke = try Smart<Sides<Optional<Optional<Stroke<Length>>>>>
            .fromValue(value).get()
        case 4: radius = try Corners<Optional<Rel<Length>>>.fromValue(value).get()
        case 5: inset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 6: outset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 7:
            if case .content(let c) = value { body = c }
            if case .none = value { body = nil }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        let (width, height) = try parseWidthHeight(&args, sizeName: "size", diameter: false)
        var elem = SquareElem(
            width: width,
            height: height,
            fill: try args.namedT("fill"),
            stroke: try args.namedT("stroke") ?? .auto,
            radius: try args.namedT("radius") ?? .splat(nil),
            inset: try args.namedT("inset") ?? shapeInset,
            outset: try args.namedT("outset") ?? .splat(nil),
            body: try args.findT()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - EllipseElem

/// An ellipse with optional content.
///
/// Port of `EllipseElem` in `visualize/shape.rs`.
public struct EllipseElem: NativeElement {
    public static let info = ElementInfo(
        name: "ellipse",
        title: "Ellipse",
        fields: [
            FieldInfo(id: 0, name: "width", settable: true),
            FieldInfo(id: 1, name: "height", settable: true),
            FieldInfo(id: 2, name: "fill", settable: true),
            FieldInfo(id: 3, name: "stroke", settable: true),
            FieldInfo(id: 4, name: "inset", settable: true),
            FieldInfo(id: 5, name: "outset", settable: true),
            FieldInfo(id: 6, name: "body"),
        ],
        capabilities: []
    )

    /// The ellipse's width, relative to its parent container.
    public var width: Smart<Rel<Length>> = .auto
    /// The ellipse's height, relative to its parent container.
    public var height: Sizing = .auto
    /// How to fill the ellipse.
    public var fill: Paint? = nil
    /// How to stroke the ellipse.
    public var stroke: Smart<Optional<Stroke<Length>>> = .auto
    /// How much to pad the ellipse's content.
    public var inset: Sides<Optional<Rel<Length>>> = shapeInset
    /// How much to expand the ellipse's size without affecting layout.
    public var outset: Sides<Optional<Rel<Length>>> = .splat(nil)
    /// The content to place into the ellipse.
    public var body: Content? = nil

    public var span: Span = .detached

    public init(width: Smart<Rel<Length>> = .auto,
                height: Sizing = .auto,
                fill: Paint? = nil,
                stroke: Smart<Optional<Stroke<Length>>> = .auto,
                inset: Sides<Optional<Rel<Length>>> = shapeInset,
                outset: Sides<Optional<Rel<Length>>> = .splat(nil),
                body: Content? = nil) {
        self.width = width
        self.height = height
        self.fill = fill
        self.stroke = stroke
        self.inset = inset
        self.outset = outset
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return width.intoValue()
        case 1: return height.intoValue()
        case 2: return fill?.intoValue()
        case 3: return stroke.intoValue()
        case 4: return inset.intoValue()
        case 5: return outset.intoValue()
        case 6: return body?.intoValue() ?? Value.none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: width = try Smart<Rel<Length>>.fromValue(value).get()
        case 1: height = try Sizing.fromValue(value).get()
        case 2:
            if case .none = value { fill = nil }
            else { fill = try Paint.fromValue(value).get() }
        case 3: stroke = try Smart<Optional<Stroke<Length>>>.fromValue(value).get()
        case 4: inset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 5: outset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 6:
            if case .content(let c) = value { body = c }
            if case .none = value { body = nil }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = EllipseElem(
            width: try args.namedT("width") ?? .auto,
            height: try args.namedT("height") ?? .auto,
            fill: try args.namedT("fill"),
            stroke: try args.namedT("stroke") ?? .auto,
            inset: try args.namedT("inset") ?? shapeInset,
            outset: try args.namedT("outset") ?? .splat(nil),
            body: try args.findT()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - CircleElem

/// A circle with optional content.
///
/// Port of `CircleElem` in `visualize/shape.rs`.
public struct CircleElem: NativeElement {
    public static let info = ElementInfo(
        name: "circle",
        title: "Circle",
        fields: [
            FieldInfo(id: 0, name: "width", settable: true),
            FieldInfo(id: 1, name: "height", settable: true),
            FieldInfo(id: 2, name: "fill", settable: true),
            FieldInfo(id: 3, name: "stroke", settable: true),
            FieldInfo(id: 4, name: "inset", settable: true),
            FieldInfo(id: 5, name: "outset", settable: true),
            FieldInfo(id: 6, name: "body"),
        ],
        capabilities: []
    )

    /// The circle's width.
    public var width: Smart<Rel<Length>> = .auto
    /// The circle's height.
    public var height: Sizing = .auto
    /// How to fill the circle.
    public var fill: Paint? = nil
    /// How to stroke the circle.
    public var stroke: Smart<Optional<Stroke<Length>>> = .auto
    /// How much to pad the circle's content.
    public var inset: Sides<Optional<Rel<Length>>> = shapeInset
    /// How much to expand the circle's size without affecting layout.
    public var outset: Sides<Optional<Rel<Length>>> = .splat(nil)
    /// The content to place into the circle.
    public var body: Content? = nil

    public var span: Span = .detached

    public init(width: Smart<Rel<Length>> = .auto,
                height: Sizing = .auto,
                fill: Paint? = nil,
                stroke: Smart<Optional<Stroke<Length>>> = .auto,
                inset: Sides<Optional<Rel<Length>>> = shapeInset,
                outset: Sides<Optional<Rel<Length>>> = .splat(nil),
                body: Content? = nil) {
        self.width = width
        self.height = height
        self.fill = fill
        self.stroke = stroke
        self.inset = inset
        self.outset = outset
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return width.intoValue()
        case 1: return height.intoValue()
        case 2: return fill?.intoValue()
        case 3: return stroke.intoValue()
        case 4: return inset.intoValue()
        case 5: return outset.intoValue()
        case 6: return body?.intoValue() ?? Value.none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: width = try Smart<Rel<Length>>.fromValue(value).get()
        case 1: height = try Sizing.fromValue(value).get()
        case 2:
            if case .none = value { fill = nil }
            else { fill = try Paint.fromValue(value).get() }
        case 3: stroke = try Smart<Optional<Stroke<Length>>>.fromValue(value).get()
        case 4: inset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 5: outset = try Sides<Optional<Rel<Length>>>.fromValue(value).get()
        case 6:
            if case .content(let c) = value { body = c }
            if case .none = value { body = nil }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        let (width, height) = try parseWidthHeight(&args, sizeName: "radius", diameter: true)
        var elem = CircleElem(
            width: width,
            height: height,
            fill: try args.namedT("fill"),
            stroke: try args.namedT("stroke") ?? .auto,
            inset: try args.namedT("inset") ?? shapeInset,
            outset: try args.namedT("outset") ?? .splat(nil),
            body: try args.findT()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - LineElem

/// A line from one point to another.
///
/// Port of `LineElem` in `visualize/line.rs`.
public struct LineElem: NativeElement {
    public static let info = ElementInfo(
        name: "line",
        title: "Line",
        fields: [
            FieldInfo(id: 0, name: "start", settable: true),
            FieldInfo(id: 1, name: "end", settable: true),
            FieldInfo(id: 2, name: "length", settable: true),
            FieldInfo(id: 3, name: "angle", settable: true),
            FieldInfo(id: 4, name: "stroke", settable: true),
        ],
        capabilities: []
    )

    /// The line's starting point.
    public var start: Axes<Rel<Length>> = .default
    /// The line's end point. If omitted, derived from `length` + `angle`.
    public var end: Axes<Rel<Length>>? = nil
    /// The line's length (used when `end` is omitted).
    public var length: Rel<Length> = Rel<Length>(Length(Abs.pt(30.0)))
    /// The line's angle (used when `end` is omitted).
    public var angle: Angle = .zero
    /// How to stroke the line.
    public var stroke: Stroke<Length> = Stroke()

    public var span: Span = .detached

    public init(start: Axes<Rel<Length>> = .default,
                end: Axes<Rel<Length>>? = nil,
                length: Rel<Length> = Rel<Length>(Length(Abs.pt(30.0))),
                angle: Angle = .zero,
                stroke: Stroke<Length> = Stroke()) {
        self.start = start
        self.end = end
        self.length = length
        self.angle = angle
        self.stroke = stroke
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return start.intoValue()
        case 1: return end?.intoValue() ?? Value.none
        case 2: return length.intoValue()
        case 3: return angle.intoValue()
        case 4: return stroke.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: start = try Axes<Rel<Length>>.fromValue(value).get()
        case 1:
            if case .none = value { end = nil }
            else { end = try Axes<Rel<Length>>.fromValue(value).get() }
        case 2: length = try Rel<Length>.fromValue(value).get()
        case 3: angle = try Angle.fromValue(value).get()
        case 4: stroke = try Stroke<Length>.fromValue(value).get()
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = LineElem(
            start: try args.namedT("start") ?? .default,
            end: try args.namedT("end"),
            length: try args.namedT("length") ?? Rel<Length>(Length(Abs.pt(30.0))),
            angle: try args.namedT("angle") ?? .zero,
            stroke: try args.namedT("stroke") ?? Stroke()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - PolygonElem

/// A closed polygon.
///
/// Port of `PolygonElem` in `visualize/polygon.rs`.
public struct PolygonElem: NativeElement {
    public static let info = ElementInfo(
        name: "polygon",
        title: "Polygon",
        scope: PolygonElem.scope,
        fields: [
            FieldInfo(id: 0, name: "fill", settable: true),
            FieldInfo(id: 1, name: "fill-rule", settable: true),
            FieldInfo(id: 2, name: "stroke", settable: true),
            FieldInfo(id: 3, name: "vertices"),
        ],
        capabilities: []
    )

    /// How to fill the polygon.
    public var fill: Paint? = nil
    /// The drawing rule used to fill the polygon.
    public var fillRule: FillRule = .nonZero
    /// How to stroke the polygon.
    public var stroke: Smart<Optional<Stroke<Length>>> = .auto
    /// The polygon's corner points.
    public var vertices: [Axes<Rel<Length>>] = []

    public var span: Span = .detached

    public init(fill: Paint? = nil,
                fillRule: FillRule = .nonZero,
                stroke: Smart<Optional<Stroke<Length>>> = .auto,
                vertices: [Axes<Rel<Length>>] = []) {
        self.fill = fill
        self.fillRule = fillRule
        self.stroke = stroke
        self.vertices = vertices
    }

    /// Upstream `#[scope] impl PolygonElem` — the `regular` constructor.
    static var scope: Scope {
        let scope = Scope()
        scope.defineFunc(polygonRegular)
        return scope
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return fill?.intoValue()
        case 1: return fillRule.intoValue()
        case 2: return stroke.intoValue()
        case 3: return .array(ArrayValue(items: vertices.map { $0.intoValue() }))
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0:
            if case .none = value { fill = nil }
            else { fill = try Paint.fromValue(value).get() }
        case 1: fillRule = try FillRule.fromValue(value).get()
        case 2: stroke = try Smart<Optional<Stroke<Length>>>.fromValue(value).get()
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = PolygonElem(
            fill: try args.namedT("fill"),
            fillRule: try args.namedT("fill-rule") ?? .nonZero,
            stroke: try args.namedT("stroke") ?? .auto,
            vertices: try args.allT()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// `polygon.regular` — a regular polygon with `vertices` corners.
///
/// Port of `PolygonElem::regular` in `visualize/polygon.rs`.
private let polygonRegular = nativeFunc(
    "regular",
    title: "Regular Polygon",
    since: .version([0, 8, 0]),
    params: []
) { _, _, args in
    let fill: Paint?? = try args.namedOpt("fill")
    let stroke: Smart<Optional<Stroke<Length>>>? = try args.namedOpt("stroke")
    let size: Length = try args.namedT("size") ?? Length(Em.one)
    let vertices: UInt64 = try args.namedT("vertices") ?? 3

    let radius = size / 2.0
    let angle: (Double) -> Angle = { i in
        let offset = Angle.rad(.pi * (1.0 / 2.0 - 1.0 / Double(vertices)))
        let rotation = Angle.fromRatio(Ratio.new(i / Double(vertices)))
        return offset + rotation
    }

    var minX = radius
    var minY = radius
    for v in 0...vertices {
        let vx = radius * angle(Double(v)).cos() + radius
        let vy = radius * angle(Double(v)).sin() + radius
        minX = Swift.min(minX, vx)
        minY = Swift.min(minY, vy)
    }

    var points: [Axes<Rel<Length>>] = []
    for v in 0...vertices {
        let x = radius * angle(Double(v)).cos() + radius - minX
        let y = radius * angle(Double(v)).sin() + radius - minY
        points.append(Axes<Length>(x: x, y: y).map { Rel<Length>($0) })
    }

    var elem = PolygonElem(vertices: points)
    if let fill { elem.fill = fill }
    if let stroke { elem.stroke = stroke }
    elem.span = args.span
    return Content(elem)
}
