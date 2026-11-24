import Foundation
import TypstSyntax
import TypstUtils

// Curve elements from upstream `visualize/curve.rs` (element definitions;
// `Curve`/`CurveItem` geometry lands with the layout milestone).

/// `CloseMode` itself lives in `Visualize/Curve.swift`.
extension CloseMode: Default {
    public static var `default`: CloseMode { .smooth }
}

extension CloseMode: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union(allCases.map { .value(.str(Str($0.rawValue)), doc: "") })
    }
    public static var output: CastInfo { input }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return CloseMode(rawValue: s.value) != nil
    }
    public func intoValue() -> Value { .str(Str(rawValue)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value, let v = CloseMode(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(v)
    }
}

/// A component of a curve: move, line, quad, cubic, or close.
///
/// Port of `CurveComponent` in `visualize/curve.rs` — stores the packed
/// content like the grid/table child enums.
public enum CurveComponent: Sendable, Hashable {
    case move(Content)
    case line(Content)
    case quad(Content)
    case cubic(Content)
    case close(Content)
}

extension CurveComponent: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Content.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Content.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .move(c): return c.intoValue()
        case let .line(c): return c.intoValue()
        case let .quad(c): return c.intoValue()
        case let .cubic(c): return c.intoValue()
        case let .close(c): return c.intoValue()
        }
    }

    /// Port of `TryFrom<Content> for CurveComponent`: the first matching
    /// curve component element wins.
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .content(content) = value else {
            return .failure(error(value))
        }
        if content.is(CurveMove.self) { return .success(.move(content)) }
        if content.is(CurveLine.self) { return .success(.line(content)) }
        if content.is(CurveQuad.self) { return .success(.quad(content)) }
        if content.is(CurveCubic.self) { return .success(.cubic(content)) }
        if content.is(CurveClose.self) { return .success(.close(content)) }
        return .failure(HintedString("expecting a curve element"))
    }
}

// MARK: - CurveElem

/// A curve consisting of components.
///
/// Port of `CurveElem` in `visualize/curve.rs`.
public struct CurveElem: NativeElement {
    public static let info = ElementInfo(
        name: "curve",
        title: "Curve",
        scope: CurveElem.scope,
        fields: [
            FieldInfo(id: 0, name: "fill", settable: true),
            FieldInfo(id: 1, name: "fill-rule", settable: true),
            FieldInfo(id: 2, name: "stroke", settable: true),
            FieldInfo(id: 3, name: "components"),
        ],
        capabilities: []
    )

    /// How to fill the curve.
    public var fill: Paint? = nil
    /// The drawing rule used to fill the curve.
    public var fillRule: FillRule = .nonZero
    /// How to stroke the curve.
    public var stroke: Smart<Optional<Stroke<Length>>> = .auto
    /// The curve's components.
    public var components: [CurveComponent] = []

    public var span: Span = .detached

    public init(fill: Paint? = nil,
                fillRule: FillRule = .nonZero,
                stroke: Smart<Optional<Stroke<Length>>> = .auto,
                components: [CurveComponent] = []) {
        self.fill = fill
        self.fillRule = fillRule
        self.stroke = stroke
        self.components = components
    }

    /// Upstream `#[scope] impl CurveElem` — nested component elements.
    static var scope: Scope {
        let scope = Scope()
        scope.define("move", .function(Func(element: Element(CurveMove.self))))
        scope.define("line", .function(Func(element: Element(CurveLine.self))))
        scope.define("quad", .function(Func(element: Element(CurveQuad.self))))
        scope.define("cubic", .function(Func(element: Element(CurveCubic.self))))
        scope.define("close", .function(Func(element: Element(CurveClose.self))))
        return scope
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return fill?.intoValue() ?? .none
        case 1: return fillRule.intoValue()
        case 2: return stroke.intoValue()
        case 3: return .array(ArrayValue(items: components.map { $0.intoValue() }))
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
        var elem = CurveElem(
            fill: try args.namedT("fill"),
            fillRule: try args.namedT("fill-rule") ?? .nonZero,
            stroke: try args.namedT("stroke") ?? .auto,
            components: try args.allT()
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - Curve components

/// Moves the pen to a point. Port of `CurveMove` (`curve.move`).
public struct CurveMove: NativeElement {
    public static let info = ElementInfo(
        name: "move",
        title: "Curve Move",
        fields: [
            FieldInfo(id: 0, name: "start", required: true),
            FieldInfo(id: 1, name: "relative", settable: true),
        ],
        capabilities: []
    )

    /// The point to move to.
    public var start: Axes<Rel<Length>>
    /// Whether `start` is relative to the previous point.
    public var relative: Bool = false

    public var span: Span = .detached

    public init(start: Axes<Rel<Length>>, relative: Bool = false) {
        self.start = start
        self.relative = relative
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return start.intoValue()
        case 1: return .bool(relative)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 1, case .bool(let b) = value { relative = b }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = CurveMove(
            start: try args.expectT("start"),
            relative: try args.namedT("relative") ?? false
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Draws a line to a point. Port of `CurveLine` (`curve.line`).
public struct CurveLine: NativeElement {
    public static let info = ElementInfo(
        name: "line",
        title: "Curve Line",
        fields: [
            FieldInfo(id: 0, name: "end", required: true),
            FieldInfo(id: 1, name: "relative", settable: true),
        ],
        capabilities: []
    )

    /// The point to draw to.
    public var end: Axes<Rel<Length>>
    /// Whether `end` is relative to the previous point.
    public var relative: Bool = false

    public var span: Span = .detached

    public init(end: Axes<Rel<Length>>, relative: Bool = false) {
        self.end = end
        self.relative = relative
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return end.intoValue()
        case 1: return .bool(relative)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 1, case .bool(let b) = value { relative = b }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = CurveLine(
            end: try args.expectT("end"),
            relative: try args.namedT("relative") ?? false
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Draws a quadratic Bézier segment. Port of `CurveQuad` (`curve.quad`).
public struct CurveQuad: NativeElement {
    public static let info = ElementInfo(
        name: "quad",
        title: "Curve Quadratic Segment",
        fields: [
            FieldInfo(id: 0, name: "control", required: true),
            FieldInfo(id: 1, name: "end", required: true),
            FieldInfo(id: 2, name: "relative", settable: true),
        ],
        capabilities: []
    )

    /// The control point (`auto` reflects the previous control point).
    public var control: Smart<Optional<Axes<Rel<Length>>>>
    /// The end point.
    public var end: Axes<Rel<Length>>
    /// Whether the points are relative to the previous point.
    public var relative: Bool = false

    public var span: Span = .detached

    public init(control: Smart<Optional<Axes<Rel<Length>>>>,
                end: Axes<Rel<Length>>,
                relative: Bool = false) {
        self.control = control
        self.end = end
        self.relative = relative
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return control.intoValue()
        case 1: return end.intoValue()
        case 2: return .bool(relative)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 2, case .bool(let b) = value { relative = b }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = CurveQuad(
            control: try args.expectT("control"),
            end: try args.expectT("end"),
            relative: try args.namedT("relative") ?? false
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Draws a cubic Bézier segment. Port of `CurveCubic` (`curve.cubic`).
public struct CurveCubic: NativeElement {
    public static let info = ElementInfo(
        name: "cubic",
        title: "Curve Cubic Segment",
        fields: [
            FieldInfo(id: 0, name: "control-start", required: true),
            FieldInfo(id: 1, name: "control-end", required: true),
            FieldInfo(id: 2, name: "end", required: true),
            FieldInfo(id: 3, name: "relative", settable: true),
        ],
        capabilities: []
    )

    /// The first control point (`none` reflects the previous control point).
    public var controlStart: Smart<Axes<Rel<Length>>>?
    /// The second control point.
    public var controlEnd: Axes<Rel<Length>>?
    /// The end point.
    public var end: Axes<Rel<Length>>
    /// Whether the points are relative to the previous point.
    public var relative: Bool = false

    public var span: Span = .detached

    public init(controlStart: Smart<Axes<Rel<Length>>>?,
                controlEnd: Axes<Rel<Length>>?,
                end: Axes<Rel<Length>>,
                relative: Bool = false) {
        self.controlStart = controlStart
        self.controlEnd = controlEnd
        self.end = end
        self.relative = relative
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return controlStart?.intoValue() ?? .none
        case 1: return controlEnd?.intoValue() ?? .none
        case 2: return end.intoValue()
        case 3: return .bool(relative)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 3, case .bool(let b) = value { relative = b }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = CurveCubic(
            controlStart: try args.expectT("control-start"),
            controlEnd: try args.expectT("control-end"),
            end: try args.expectT("end"),
            relative: try args.namedT("relative") ?? false
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Closes the curve. Port of `CurveClose` (`curve.close`).
public struct CurveClose: NativeElement {
    public static let info = ElementInfo(
        name: "close",
        title: "Curve Close",
        fields: [
            FieldInfo(id: 0, name: "mode", settable: true),
        ],
        capabilities: []
    )

    /// How the curve is closed.
    public var mode: CloseMode = .smooth

    public var span: Span = .detached

    public init(mode: CloseMode = .smooth) {
        self.mode = mode
    }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? mode.intoValue() : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 0 { mode = try CloseMode.fromValue(value).get() }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = CurveClose(mode: try args.namedT("mode") ?? .smooth)
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}
