import Foundation
import TypstUtils

/// A 2D point. Port of `layout/point.rs`.
public struct Point: Sendable, Hashable {
    public var x: Abs
    public var y: Abs

    public init(x: Abs, y: Abs) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: .zero, y: .zero)
    public static func new(_ x: Abs, _ y: Abs) -> Point { Point(x: x, y: y) }
    public static func splat(_ value: Abs) -> Point { Point(x: value, y: value) }
    public static func withX(_ x: Abs) -> Point { Point(x: x, y: .zero) }
    public static func withY(_ y: Abs) -> Point { Point(x: .zero, y: y) }

    public func min(_ other: Point) -> Point { Point(x: Swift.min(x, other.x), y: Swift.min(y, other.y)) }
    public func max(_ other: Point) -> Point { Point(x: Swift.max(x, other.x), y: Swift.max(y, other.y)) }
    public func map(_ f: (Abs) -> Abs) -> Point { Point(x: f(x), y: f(y)) }

    /// Euclidean norm (`sqrt` is IEEE-754 deterministic, matching upstream).
    public func hypot() -> Abs {
        let x = self.x.toRaw, y = self.y.toRaw
        return Abs(raw: Scalar((x * x + y * y).squareRoot()))
    }

    /// Unit vector (undefined for zero-length points, like upstream).
    public func normalized() -> Point { self / hypot().toRaw }

    public func rot90ccw() -> Point { Point(x: y, y: -x) }

    public func transform(_ ts: Transform) -> Point {
        Point(
            x: ts.sx.of(self.x) + ts.kx.of(self.y) + ts.tx,
            y: ts.ky.of(self.x) + ts.sy.of(self.y) + ts.ty
        )
    }

    public func transformInf(_ ts: Transform) -> Point {
        Point(
            x: ts.sx.get * self.x + ts.kx.get * self.y + ts.tx,
            y: ts.ky.get * self.x + ts.sy.get * self.y + ts.ty
        )
    }

    public func toSize() -> Size { Size(x: x, y: y) }
}

extension Point: CustomDebugStringConvertible {
    public var debugDescription: String { "Point(\(x), \(y))" }
}

extension Point: Numeric {
    public static var numericZero: Point { .zero }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public func multiplied(by factor: Double) -> Point { self * factor }
    public func added(to other: Point) -> Point { self + other }
}

public func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
public func - (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
public func * (lhs: Point, rhs: Double) -> Point { Point(x: lhs.x * rhs, y: lhs.y * rhs) }
public func * (lhs: Double, rhs: Point) -> Point { rhs * lhs }
public func / (lhs: Point, rhs: Double) -> Point { Point(x: lhs.x / rhs, y: lhs.y / rhs) }
public prefix func - (x: Point) -> Point { Point(x: -x.x, y: -x.y) }
public func += (lhs: inout Point, rhs: Point) { lhs = lhs + rhs }
public func -= (lhs: inout Point, rhs: Point) { lhs = lhs - rhs }
public func *= (lhs: inout Point, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Point, rhs: Double) { lhs = lhs / rhs }

/// Generic 2-component vector. Port of `layout/axes.rs` (`Axes<T>`).
/// `Size` is `Axes<Abs>`.
public struct Axes<T> {
    public var x: T
    public var y: T

    public init(x: T, y: T) {
        self.x = x
        self.y = y
    }

    public static func new(_ x: T, _ y: T) -> Axes<T> { Axes(x: x, y: y) }
    public static func splat(_ v: T) -> Axes<T> { Axes(x: v, y: v) }

    public func map<U>(_ f: (T) -> U) -> Axes<U> { Axes<U>(x: f(x), y: f(y)) }
    public func zip<U>(_ other: Axes<U>) -> Axes<(T, U)> { Axes<(T, U)>(x: (x, other.x), y: (y, other.y)) }
    public func zipMap<V, U>(_ other: Axes<V>, _ f: (T, V) -> U) -> Axes<U> {
        Axes<U>(x: f(x, other.x), y: f(y, other.y))
    }
    public func any(_ f: (T) -> Bool) -> Bool { f(x) || f(y) }
    public func all(_ f: (T) -> Bool) -> Bool { f(x) && f(y) }

    public func min(_ other: Axes<T>) -> Axes<T> where T: Comparable {
        Axes(x: Swift.min(x, other.x), y: Swift.min(y, other.y))
    }
    public func max(_ other: Axes<T>) -> Axes<T> where T: Comparable {
        Axes(x: Swift.max(x, other.x), y: Swift.max(y, other.y))
    }
    public func minBySide() -> T where T: Comparable { Swift.min(x, y) }
    public func maxBySide() -> T where T: Comparable { Swift.max(x, y) }

    public subscript(axis: Axis) -> T {
        get {
            switch axis {
            case .x: return x
            case .y: return y
            }
        }
        set {
            switch axis {
            case .x: x = newValue
            case .y: y = newValue
            }
        }
    }
}

/// `Size` is `Axes<Abs>`.
public typealias Size = Axes<Abs>

extension Axes where T == Abs {
    public static let zero = Axes(x: Abs.zero, y: Abs.zero)

    public func fits(_ other: Size) -> Bool { x.fits(other.x) && y.fits(other.y) }
    public func toPoint() -> Point { Point(x: x, y: y) }
    public func aspectRatio() -> Ratio { Ratio(x / y) }
}

extension Axes: Numeric where T == Abs {
    public static var numericZero: Size { .zero }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public func multiplied(by factor: Double) -> Size { self * factor }
    public func added(to other: Size) -> Size { self + other }
}

extension Axes: CustomDebugStringConvertible where T == Abs {
    public var debugDescription: String { "Size(\(x), \(y))" }
}

extension Axes where T == Rel<Abs> {
    /// Resolve each component against the corresponding size axis
    /// (upstream `Axes<Rel<Abs>>::relative_to`).
    public func relativeTo(_ size: Size) -> Size {
        Size(x: x.relativeTo(size.x), y: y.relativeTo(size.y))
    }
}

public func + (lhs: Size, rhs: Size) -> Size { Size(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
public func - (lhs: Size, rhs: Size) -> Size { Size(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
public func * (lhs: Size, rhs: Double) -> Size { Size(x: lhs.x * rhs, y: lhs.y * rhs) }
public func * (lhs: Double, rhs: Size) -> Size { rhs * lhs }
public func / (lhs: Size, rhs: Double) -> Size { Size(x: lhs.x / rhs, y: lhs.y / rhs) }
public prefix func - (x: Size) -> Size { Size(x: -x.x, y: -x.y) }
public func += (lhs: inout Size, rhs: Size) { lhs = lhs + rhs }
public func -= (lhs: inout Size, rhs: Size) { lhs = lhs - rhs }
public func *= (lhs: inout Size, rhs: Double) { lhs = lhs * rhs }
public func /= (lhs: inout Size, rhs: Double) { lhs = lhs / rhs }

/// An axis of a 2D space. Port of `Axis` in `axes.rs`.
public enum Axis: String, Sendable, Hashable {
    case x, y

    public func dir(_ positive: Bool) -> Dir {
        switch (self, positive) {
        case (.x, true): return .ltr
        case (.x, false): return .rtl
        case (.y, true): return .ttb
        case (.y, false): return .btt
        }
    }

    public var other: Axis { self == .x ? .y : .x }
}

/// A direction. Port of `layout/dir.rs`.
public enum Dir: String, Sendable, Hashable {
    case ltr, rtl, ttb, btt

    /// Whether this direction runs in the positive axis direction.
    public var isPositive: Bool {
        switch self {
        case .ltr, .ttb: return true
        case .rtl, .btt: return false
        }
    }

    public var axis: Axis {
        switch self {
        case .ltr, .rtl: return .x
        case .ttb, .btt: return .y
        }
    }

    /// The sign of this direction (+1 or -1).
    public var sign: Int64 {
        switch self {
        case .ltr, .ttb: return 1
        case .rtl, .btt: return -1
        }
    }

    /// The side where this direction starts.
    public var start: Side {
        switch self {
        case .ltr: return .left
        case .rtl: return .right
        case .ttb: return .top
        case .btt: return .bottom
        }
    }

    /// The side where this direction ends.
    public var end: Side {
        switch self {
        case .ltr: return .right
        case .rtl: return .left
        case .ttb: return .bottom
        case .btt: return .top
        }
    }

    /// The opposite direction.
    public var inverted: Dir {
        switch self {
        case .ltr: return .rtl
        case .rtl: return .ltr
        case .ttb: return .btt
        case .btt: return .ttb
        }
    }
}

extension Dir: Repr {
    public func repr() -> String { rawValue }
}

/// A side of a box. Port of `Side` in `sides.rs`.
public enum Side: String, Sendable, Hashable {
    case left, top, right, bottom

    public var inverted: Side {
        switch self {
        case .left: return .right
        case .top: return .bottom
        case .right: return .left
        case .bottom: return .top
        }
    }

    /// The next side clockwise (left → top → right → bottom → left).
    public var nextCw: Side {
        switch self {
        case .left: return .top
        case .top: return .right
        case .right: return .bottom
        case .bottom: return .left
        }
    }

    /// The next side counter-clockwise.
    public var nextCcw: Side {
        switch self {
        case .left: return .bottom
        case .top: return .left
        case .right: return .top
        case .bottom: return .right
        }
    }

    /// The corner where this side starts (going clockwise).
    public var startCorner: Corner {
        switch self {
        case .left: return .bottomLeft
        case .top: return .topLeft
        case .right: return .topRight
        case .bottom: return .bottomRight
        }
    }

    /// The corner where this side ends.
    public var endCorner: Corner { nextCw.startCorner }

    /// The axis perpendicular to this side.
    public var axis: Axis {
        switch self {
        case .left, .right: return .y
        case .top, .bottom: return .x
        }
    }
}

/// Per-side values (left/top/right/bottom). Port of `Sides<T>`.
public struct Sides<T> {
    public var left: T
    public var top: T
    public var right: T
    public var bottom: T

    public init(left: T, top: T, right: T, bottom: T) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public static func new(_ left: T, _ top: T, _ right: T, _ bottom: T) -> Sides<T> {
        Sides(left: left, top: top, right: right, bottom: bottom)
    }
    public static func splat(_ value: T) -> Sides<T> {
        Sides(left: value, top: value, right: value, bottom: value)
    }

    public func map<U>(_ f: (T) -> U) -> Sides<U> {
        Sides<U>(left: f(left), top: f(top), right: f(right), bottom: f(bottom))
    }
    public func zip<U>(_ other: Sides<U>) -> Sides<(T, U)> {
        Sides<(T, U)>(left: (left, other.left), top: (top, other.top),
              right: (right, other.right), bottom: (bottom, other.bottom))
    }
    public var components: [T] { [left, top, right, bottom] }
    public func isUniform() -> Bool where T: Equatable {
        left == top && top == right && right == bottom
    }
    public func mapCorners<U>(_ f: (T, T) -> U) -> Corners<U> {
        Corners(topLeft: f(left, top), topRight: f(top, right),
                bottomRight: f(right, bottom), bottomLeft: f(bottom, left))
    }
    public func sumByAxis() -> Axes<T> where T: Numeric {
        Axes(x: left.added(to: right), y: top.added(to: bottom))
    }

    public subscript(side: Side) -> T {
        get {
            switch side {
            case .left: return left
            case .top: return top
            case .right: return right
            case .bottom: return bottom
            }
        }
        set {
            switch side {
            case .left: left = newValue
            case .top: top = newValue
            case .right: right = newValue
            case .bottom: bottom = newValue
            }
        }
    }
}

extension Sides where T == Rel<Abs> {
    /// Resolve each side against the corresponding size axis.
    public func relativeTo(_ size: Size) -> Sides<Abs> {
        Sides<Abs>(left: left.relativeTo(size.x), top: top.relativeTo(size.y),
              right: right.relativeTo(size.x), bottom: bottom.relativeTo(size.y))
    }
}

extension Sides where T: Numeric {
    public func isZero() -> Bool {
        left.isZero() && top.isZero() && right.isZero() && bottom.isZero()
    }
}

extension Sides where T: OptionalProtocol {
    public func unwrapOrDefault() -> Sides<T.Wrapped> where T.Wrapped: DefaultConstructible {
        map { $0.wrappedValue ?? T.Wrapped.defaultValue }
    }
}

/// Helper protocols to express `Sides<Option<T>>` operations without
/// optional-type constraints Swift can't spell.
public protocol OptionalProtocol {
    associatedtype Wrapped
    var wrappedValue: Wrapped? { get }
}

extension Optional: OptionalProtocol {
    public var wrappedValue: Wrapped? { self }
}

public protocol DefaultConstructible {
    static var defaultValue: Self { get }
}

extension Abs: DefaultConstructible { public static var defaultValue: Abs { .zero } }
extension Em: DefaultConstructible { public static var defaultValue: Em { .zero } }
extension Length: DefaultConstructible { public static var defaultValue: Length { .zero } }
extension Ratio: DefaultConstructible { public static var defaultValue: Ratio { .zero } }
extension Fr: DefaultConstructible { public static var defaultValue: Fr { .zero } }
extension Angle: DefaultConstructible { public static var defaultValue: Angle { .zero } }

/// A corner of a box. Port of `Corner` in `corners.rs`.
public enum Corner: String, Sendable, Hashable {
    case topLeft, topRight, bottomRight, bottomLeft

    public var inverted: Corner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomRight: return .topLeft
        case .bottomLeft: return .topRight
        }
    }
    public var nextCw: Corner {
        switch self {
        case .topLeft: return .topRight
        case .topRight: return .bottomRight
        case .bottomRight: return .bottomLeft
        case .bottomLeft: return .topLeft
        }
    }
    public var nextCcw: Corner {
        switch self {
        case .topLeft: return .bottomLeft
        case .topRight: return .topLeft
        case .bottomRight: return .topRight
        case .bottomLeft: return .bottomRight
        }
    }
    /// The side clockwise-adjacent (top edge for top-left, etc.).
    public var sideCw: Side {
        switch self {
        case .topLeft: return .top
        case .topRight: return .right
        case .bottomRight: return .bottom
        case .bottomLeft: return .left
        }
    }
    public var sideCcw: Side {
        switch self {
        case .topLeft: return .left
        case .topRight: return .top
        case .bottomRight: return .right
        case .bottomLeft: return .bottom
        }
    }
}

/// Per-corner values. Port of `Corners<T>`.
public struct Corners<T> {
    public var topLeft: T
    public var topRight: T
    public var bottomRight: T
    public var bottomLeft: T

    public init(topLeft: T, topRight: T, bottomRight: T, bottomLeft: T) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public static func new(_ tl: T, _ tr: T, _ br: T, _ bl: T) -> Corners<T> {
        Corners(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }
    public static func splat(_ value: T) -> Corners<T> {
        Corners(topLeft: value, topRight: value, bottomRight: value, bottomLeft: value)
    }

    public func map<U>(_ f: (T) -> U) -> Corners<U> {
        Corners<U>(topLeft: f(topLeft), topRight: f(topRight),
                bottomRight: f(bottomRight), bottomLeft: f(bottomLeft))
    }
    public func zip<U>(_ other: Corners<U>) -> Corners<(T, U)> {
        Corners<(T, U)>(topLeft: (topLeft, other.topLeft), topRight: (topRight, other.topRight),
                bottomRight: (bottomRight, other.bottomRight), bottomLeft: (bottomLeft, other.bottomLeft))
    }
    public var components: [T] { [topLeft, topRight, bottomRight, bottomLeft] }
    public func isUniform() -> Bool where T: Equatable {
        topLeft == topRight && topRight == bottomRight && bottomRight == bottomLeft
    }

    public subscript(corner: Corner) -> T {
        get {
            switch corner {
            case .topLeft: return topLeft
            case .topRight: return topRight
            case .bottomRight: return bottomRight
            case .bottomLeft: return bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }
}

extension Corners where T: OptionalProtocol, T.Wrapped: DefaultConstructible {
    public func unwrapOrDefault() -> Corners<T.Wrapped> {
        map { $0.wrappedValue ?? T.Wrapped.defaultValue }
    }
}

/// A 2D affine transform. Port of `Transform` in `transform.rs`.
public struct Transform: Sendable, Hashable {
    public var sx: Ratio
    public var ky: Ratio
    public var kx: Ratio
    public var sy: Ratio
    public var tx: Abs
    public var ty: Abs

    public init(sx: Ratio, ky: Ratio, kx: Ratio, sy: Ratio, tx: Abs, ty: Abs) {
        self.sx = sx
        self.ky = ky
        self.kx = kx
        self.sy = sy
        self.tx = tx
        self.ty = ty
    }

    public static let identity = Transform(sx: .one, ky: .zero, kx: .zero, sy: .one, tx: .zero, ty: .zero)

    public static func translate(_ tx: Abs, _ ty: Abs) -> Transform {
        Transform(sx: .one, ky: .zero, kx: .zero, sy: .one, tx: tx, ty: ty)
    }

    public static func scale(_ sx: Ratio, _ sy: Ratio) -> Transform {
        Transform(sx: sx, ky: .zero, kx: .zero, sy: sy, tx: .zero, ty: .zero)
    }

    public static func scaleAt(_ sx: Ratio, _ sy: Ratio, px: Abs, py: Abs) -> Transform {
        translate(px, py)
            .preConcat(scale(sx, sy))
            .preConcat(translate(-px, -py))
    }

    public static func rotateAt(_ angle: Angle, px: Abs, py: Abs) -> Transform {
        translate(px, py)
            .preConcat(rotate(angle))
            .preConcat(translate(-px, -py))
    }

    public static func rotate(_ angle: Angle) -> Transform {
        let cos = Ratio(angle.cos())
        let sin = Ratio(angle.sin())
        return Transform(sx: cos, ky: sin, kx: -sin, sy: cos, tx: .zero, ty: .zero)
    }

    public static func skew(_ ax: Angle, _ ay: Angle) -> Transform {
        Transform(sx: .one, ky: Ratio(ay.tan()), kx: Ratio(ax.tan()), sy: .one, tx: .zero, ty: .zero)
    }

    public func isIdentity() -> Bool { self == .identity }

    public func isOnlyScale() -> Bool {
        ky.isZero() && kx.isZero() && tx.isZero() && ty.isZero()
    }

    public func isOnlyTranslate() -> Bool {
        sx.isOne() && sy.isOne() && ky.isZero() && kx.isZero()
    }

    public func preConcat(_ prev: Transform) -> Transform {
        Transform(
            sx: sx * prev.sx + kx * prev.ky,
            ky: ky * prev.sx + sy * prev.ky,
            kx: sx * prev.kx + kx * prev.sy,
            sy: ky * prev.kx + sy * prev.sy,
            tx: sx.of(prev.tx) + kx.of(prev.ty) + tx,
            ty: ky.of(prev.tx) + sy.of(prev.ty) + ty
        )
    }

    public func postConcat(_ next: Transform) -> Transform { next.preConcat(self) }

    public func invert() -> Transform? {
        if isIdentity() { return self }

        // Fast path for scale-translate-only transforms.
        if kx.isZero() && ky.isZero() {
            if sx.isZero() || sy.isZero() {
                return .translate(-tx, -ty)
            }
            let invX = 1.0 / sx.get
            let invY = 1.0 / sy.get
            return Transform(
                sx: Ratio(invX), ky: .zero, kx: .zero, sy: Ratio(invY),
                tx: -tx * invX, ty: -ty * invY
            )
        }

        let det = sx * sy - kx * ky
        if abs(det.get) < 1e-12 { return nil }

        let invDet = 1.0 / det.get
        return Transform(
            sx: sx * invDet,
            ky: -ky * invDet,
            kx: -kx * invDet,
            sy: sy * invDet,
            tx: Abs.pt((kx.get * ty.toPt() - sy.get * tx.toPt()) * invDet),
            ty: Abs.pt((ky.get * tx.toPt() - sx.get * ty.toPt()) * invDet)
        )
    }
}

extension Transform: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Transform(sx: \(sx), ky: \(ky), kx: \(kx), sy: \(sy), tx: \(tx), ty: \(ty))"
    }
}


extension Axes: Equatable where T: Equatable {}
extension Axes: @unchecked Sendable {}
extension Axes: Hashable where T: Hashable {}
extension Sides: Equatable where T: Equatable {}
extension Sides: @unchecked Sendable {}
extension Sides: Hashable where T: Hashable {}
extension Corners: Equatable where T: Equatable {}
extension Corners: @unchecked Sendable {}
extension Corners: Hashable where T: Hashable {}

// MARK: - Optional-component casts (upstream `Sides<Option<T>>` / `Corners<Option<T>>`)

/// Element type for the `Sides`/`Corners` optional-component casts.
/// Upstream implements `IntoValue`/`FromValue` for `Sides<Option<T>>` and
/// `Corners<Option<T>>` where `None` means "unspecified"; dict keys fall
/// back through `x`/`y`/`rest` (sides) or the side keys (corners).
public protocol OptionalCast {
    associatedtype Wrapped
    /// The "unspecified" element value.
    static var unspecified: Self { get }
    /// The wrapped value when specified.
    var wrappedComponent: Wrapped? { get }
    init(wrappedComponent: Wrapped?)
}

extension Optional: OptionalCast {
    public static var unspecified: Self { nil }
    public var wrappedComponent: Wrapped? { self }
    public init(wrappedComponent: Wrapped?) { self = wrappedComponent }
}

extension Sides: Castable, IntoValue, FromValue
where T: OptionalCast & Equatable & IntoValue,
      T.Wrapped: Castable & IntoValue & FromValue {

    public static var input: CastInfo {
        .union([.type(Type.of(Dict.self)), T.Wrapped.input])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        if case .dict = value { return true }
        return T.Wrapped.castable(value)
    }

    public func intoValue() -> Value {
        if isUniform(), case .some = left.wrappedComponent {
            return left.intoValue()
        }
        var dict = Dict()
        for (key, component) in [("left", left), ("top", top),
                                  ("right", right), ("bottom", bottom)] {
            if case .some = component.wrappedComponent {
                dict.insert(key, component.intoValue())
            }
        }
        return .dict(dict)
    }

    /// Dict form: `{left, top, right, bottom, x, y, rest}` with the
    /// `x`/`y`/`rest` fallback chain (upstream `Sides<Option<T>>::from_value`).
    static func parseDict(_ dict: inout Dict) throws -> Sides<T> {
        let expectedKeys = ["left", "top", "right", "bottom", "x", "y", "rest"]
        func take(_ key: String) throws -> T.Wrapped? {
            guard case .success(let v) = dict.take(key) else { return nil }
            return try T.Wrapped.fromValue(v).get()
        }
        let rest = try take("rest")
        let x = try take("x") ?? rest
        let y = try take("y") ?? rest
        let left = try take("left") ?? x
        let top = try take("top") ?? y
        let right = try take("right") ?? x
        let bottom = try take("bottom") ?? y
        if case .failure(let e) = dict.finish(expected: expectedKeys) {
            throw HintedString(e.message)
        }
        return Sides(
            left: T(wrappedComponent: left),
            top: T(wrappedComponent: top),
            right: T(wrappedComponent: right),
            bottom: T(wrappedComponent: bottom))
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        let expectedKeys = ["left", "top", "right", "bottom", "x", "y", "rest"]
        if case .dict(var dict) = value {
            if dict.keys.isEmpty {
                return .success(.splat(.unspecified))
            }
            if dict.keys.contains(where: { expectedKeys.contains($0.value) }) {
                do { return .success(try parseDict(&dict)) }
                catch let e as HintedString { return .failure(e) }
                catch { return .failure(HintedString("\(error)")) }
            }
        }

        if T.Wrapped.castable(value) {
            return T.Wrapped.fromValue(value).map { wrapped in
                .splat(T(wrappedComponent: .some(wrapped)))
            }
        }
        if case let .dict(d) = value {
            return .failure(HintedString(
                Dict.unexpectedKeys(d.keys.map(\.value), expected: nil)))
        }
        return .failure(error(value))
    }
}

extension Corners: Castable, IntoValue, FromValue
where T: OptionalCast & Equatable & IntoValue,
      T.Wrapped: Castable & IntoValue & FromValue {

    public static var input: CastInfo {
        .union([.type(Type.of(Dict.self)), T.Wrapped.input])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        if case .dict = value { return true }
        return T.Wrapped.castable(value)
    }

    public func intoValue() -> Value {
        if isUniform(), case .some = topLeft.wrappedComponent {
            return topLeft.intoValue()
        }
        var dict = Dict()
        for (key, component) in [("top-left", topLeft), ("top-right", topRight),
                                  ("bottom-right", bottomRight),
                                  ("bottom-left", bottomLeft)] {
            if case .some = component.wrappedComponent {
                dict.insert(key, component.intoValue())
            }
        }
        return .dict(dict)
    }

    /// Dict form with the `rest` → side → corner fallback chain
    /// (upstream `Corners<Option<T>>::from_value`).
    static func parseDict(_ dict: inout Dict) throws -> Corners<T> {
        let expectedKeys = ["top-left", "top-right", "bottom-right",
                            "bottom-left", "left", "top", "right", "bottom",
                            "rest"]
        func take(_ key: String) throws -> T.Wrapped? {
            guard case .success(let v) = dict.take(key) else { return nil }
            return try T.Wrapped.fromValue(v).get()
        }
        let rest = try take("rest")
        let left = try take("left") ?? rest
        let top = try take("top") ?? rest
        let right = try take("right") ?? rest
        let bottom = try take("bottom") ?? rest
        let topLeft = try take("top-left") ?? top ?? left
        let topRight = try take("top-right") ?? top ?? right
        let bottomRight = try take("bottom-right") ?? bottom ?? right
        let bottomLeft = try take("bottom-left") ?? bottom ?? left
        if case .failure(let e) = dict.finish(expected: expectedKeys) {
            throw HintedString(e.message)
        }
        return Corners(
            topLeft: T(wrappedComponent: topLeft),
            topRight: T(wrappedComponent: topRight),
            bottomRight: T(wrappedComponent: bottomRight),
            bottomLeft: T(wrappedComponent: bottomLeft))
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        let expectedKeys = ["top-left", "top-right", "bottom-right",
                            "bottom-left", "left", "top", "right", "bottom",
                            "rest"]
        if case .dict(var dict) = value {
            if dict.keys.isEmpty {
                return .success(.splat(.unspecified))
            }
            if dict.keys.contains(where: { expectedKeys.contains($0.value) }) {
                do { return .success(try parseDict(&dict)) }
                catch let e as HintedString { return .failure(e) }
                catch { return .failure(HintedString("\(error)")) }
            }
        }

        if T.Wrapped.castable(value) {
            return T.Wrapped.fromValue(value).map { wrapped in
                .splat(T(wrappedComponent: .some(wrapped)))
            }
        }
        if case let .dict(d) = value {
            return .failure(HintedString(
                Dict.unexpectedKeys(d.keys.map(\.value), expected: nil)))
        }
        return .failure(error(value))
    }
}

extension Sides: Fold where T: AlternativeFold {
    /// Component-wise `fold_or` (upstream `Fold for Sides<Option<T>>`).
    public static func fold(_ inner: Sides<T>, _ outer: Sides<T>) -> Sides<T> {
        inner.zip(outer).map { T.foldOr($0.0, $0.1) }
    }
}

extension Corners: Fold where T: AlternativeFold {
    /// Component-wise `fold_or` (upstream `Fold for Corners<Option<T>>`).
    public static func fold(_ inner: Corners<T>, _ outer: Corners<T>) -> Corners<T> {
        inner.zip(outer).map { T.foldOr($0.0, $0.1) }
    }
}

extension Sides: Resolve where T: Resolve {
    public typealias Output = Sides<T.Output>

    public func resolve(_ styles: StyleChain) -> Sides<T.Output> {
        map { $0.resolve(styles) }
    }
}

extension Corners: Resolve where T: Resolve {
    public typealias Output = Corners<T.Output>

    public func resolve(_ styles: StyleChain) -> Corners<T.Output> {
        map { $0.resolve(styles) }
    }
}
