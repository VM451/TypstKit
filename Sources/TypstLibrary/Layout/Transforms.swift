import TypstSyntax
import TypstUtils

// MARK: - ScaleAmount

/// To what size something shall be scaled.
///
/// Port of `ScaleAmount` in `layout/transform.rs`.
public enum ScaleAmount: Sendable, Hashable {
    case ratio(Ratio)
    case length(Length)
}

extension ScaleAmount: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([Ratio.input, Length.input])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Ratio.castable(value) || Length.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case .ratio(let ratio): return ratio.intoValue()
        case .length(let length): return length.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Ratio.castable(value) {
            return Ratio.fromValue(value).map { .ratio($0) }
        }
        if Length.castable(value) {
            return Length.fromValue(value).map { .length($0) }
        }
        return .failure(error(value))
    }
}

// MARK: - MoveElem

/// Moves content without affecting layout.
///
/// Port of `MoveElem` in `layout/transform.rs`.
public struct MoveElem: NativeElement {
    public static let info = ElementInfo(
        name: "move",
        title: "Move",
        fields: [
            FieldInfo(id: 0, name: "dx", settable: true),
            FieldInfo(id: 1, name: "dy", settable: true),
            FieldInfo(id: 2, name: "body", required: true),
        ],
        capabilities: []
    )

    /// The horizontal displacement of the content.
    public var dx: Rel<Length> = .zero()
    /// The vertical displacement of the content.
    public var dy: Rel<Length> = .zero()
    /// The content to move.
    public var body: Content = .empty

    public var span: Span = .detached

    public init(dx: Rel<Length> = .zero(), dy: Rel<Length> = .zero(),
                body: Content) {
        self.dx = dx
        self.dy = dy
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return dx.intoValue()
        case 1: return dy.intoValue()
        case 2: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, .relative(let r)): dx = r
        case (1, .relative(let r)): dy = r
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = MoveElem(
            dx: try args.namedT("dx") ?? .zero(),
            dy: try args.namedT("dy") ?? .zero(),
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - RotateElem

/// Rotates content without affecting layout.
///
/// Port of `RotateElem` in `layout/transform.rs`.
public struct RotateElem: NativeElement {
    public static let info = ElementInfo(
        name: "rotate",
        title: "Rotate",
        fields: [
            FieldInfo(id: 0, name: "angle", settable: true),
            FieldInfo(id: 1, name: "origin", settable: true),
            FieldInfo(id: 2, name: "reflow", settable: true),
            FieldInfo(id: 3, name: "body", required: true),
        ],
        capabilities: []
    )

    /// The rotation angle.
    public var angle: Angle = .zero
    /// The origin of the rotation.
    public var origin: Alignment = .both(.center, .horizon)
    /// Whether the rotation impacts the layout.
    public var reflow: Bool = false
    /// The content to rotate.
    public var body: Content = .empty

    public var span: Span = .detached

    public init(angle: Angle = .zero,
                origin: Alignment = .both(.center, .horizon),
                reflow: Bool = false,
                body: Content) {
        self.angle = angle
        self.origin = origin
        self.reflow = reflow
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return angle.intoValue()
        case 1: return origin.intoValue()
        case 2: return .bool(reflow)
        case 3: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, .angle(let a)): angle = a
        case (1, let v) where Alignment.castable(v):
            origin = try Alignment.fromValue(v).get()
        case (2, .bool(let b)): reflow = b
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = RotateElem(
            angle: try args.findT() ?? .zero,
            origin: try args.namedT("origin") ?? .both(.center, .horizon),
            reflow: try args.namedT("reflow") ?? false,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - ScaleElem

/// Scales content.
///
/// Port of `ScaleElem` in `layout/transform.rs`.
public struct ScaleElem: NativeElement {
    public static let info = ElementInfo(
        name: "scale",
        title: "Scale",
        fields: [
            FieldInfo(id: 0, name: "x", settable: true),
            FieldInfo(id: 1, name: "y", settable: true),
            FieldInfo(id: 2, name: "origin", settable: true),
            FieldInfo(id: 3, name: "reflow", settable: true),
            FieldInfo(id: 4, name: "body", required: true),
        ],
        capabilities: []
    )

    /// The horizontal scaling factor.
    public var x: Smart<ScaleAmount> = .custom(.ratio(.one))
    /// The vertical scaling factor.
    public var y: Smart<ScaleAmount> = .custom(.ratio(.one))
    /// The origin of the transformation.
    public var origin: Alignment = .both(.center, .horizon)
    /// Whether the scaling impacts the layout.
    public var reflow: Bool = false
    /// The content to scale.
    public var body: Content = .empty

    public var span: Span = .detached

    /// The default factor: 100% on both axes (upstream
    /// `Smart::Custom(ScaleAmount::Ratio(Ratio::one()))`).
    public static let defaultFactor: Smart<ScaleAmount> = .custom(.ratio(.one))

    public init(x: Smart<ScaleAmount> = defaultFactor,
                y: Smart<ScaleAmount> = defaultFactor,
                origin: Alignment = .both(.center, .horizon),
                reflow: Bool = false,
                body: Content) {
        self.x = x
        self.y = y
        self.origin = origin
        self.reflow = reflow
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return x.intoValue()
        case 1: return y.intoValue()
        case 2: return origin.intoValue()
        case 3: return .bool(reflow)
        case 4: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: x = try Smart<ScaleAmount>.fromValue(value).get()
        case 1: y = try Smart<ScaleAmount>.fromValue(value).get()
        case 2:
            if Alignment.castable(value) {
                origin = try Alignment.fromValue(value).get()
            }
        case 3:
            if case .bool(let b) = value { reflow = b }
        default: break
        }
    }

    /// Custom construct: the external `factor` positional feeds `x`/`y`
    /// (upstream `#[external]` + `#[parse]` — `all` is found once and
    /// shared by both axes).
    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        let all: Smart<ScaleAmount>? = try args.findT()
        var elem = ScaleElem(
            x: (try args.namedT("x") ?? all) ?? defaultFactor,
            y: (try args.namedT("y") ?? all) ?? defaultFactor,
            origin: try args.namedT("origin") ?? .both(.center, .horizon),
            reflow: try args.namedT("reflow") ?? false,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

// MARK: - SkewElem

/// Skews content.
///
/// Port of `SkewElem` in `layout/transform.rs`.
public struct SkewElem: NativeElement {
    public static let info = ElementInfo(
        name: "skew",
        title: "Skew",
        fields: [
            FieldInfo(id: 0, name: "ax", settable: true),
            FieldInfo(id: 1, name: "ay", settable: true),
            FieldInfo(id: 2, name: "origin", settable: true),
            FieldInfo(id: 3, name: "reflow", settable: true),
            FieldInfo(id: 4, name: "body", required: true),
        ],
        capabilities: []
    )

    /// The horizontal skewing angle.
    public var ax: Angle = .zero
    /// The vertical skewing angle.
    public var ay: Angle = .zero
    /// The origin of the skew transformation.
    public var origin: Alignment = .both(.center, .horizon)
    /// Whether the skew transformation impacts the layout.
    public var reflow: Bool = false
    /// The content to skew.
    public var body: Content = .empty

    public var span: Span = .detached

    public init(ax: Angle = .zero, ay: Angle = .zero,
                origin: Alignment = .both(.center, .horizon),
                reflow: Bool = false,
                body: Content) {
        self.ax = ax
        self.ay = ay
        self.origin = origin
        self.reflow = reflow
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return ax.intoValue()
        case 1: return ay.intoValue()
        case 2: return origin.intoValue()
        case 3: return .bool(reflow)
        case 4: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0:
            if case .angle(let a) = value { ax = a }
        case 1:
            if case .angle(let a) = value { ay = a }
        case 2:
            if Alignment.castable(value) {
                origin = try Alignment.fromValue(value).get()
            }
        case 3:
            if case .bool(let b) = value { reflow = b }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = SkewElem(
            ax: try args.namedT("ax") ?? .zero,
            ay: try args.namedT("ay") ?? .zero,
            origin: try args.namedT("origin") ?? .both(.center, .horizon),
            reflow: try args.namedT("reflow") ?? false,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}
