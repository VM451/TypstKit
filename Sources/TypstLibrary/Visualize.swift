import Foundation
import TypstUtils

/// A color space component set.
///
/// Port of the process-color types in `visualize/color.rs`. Each space
/// stores its components plus alpha; full color-space conversion matrices
/// land with the render pipeline.
public enum ProcessColor: Sendable, Hashable {
    case luma(Luma)
    case rgb(Rgb)
    case cmyk(Cmyk)
    case hsl(Hsl)
    case hsv(Hsv)
    case linearRgb(LinearRgb)
    case oklab(Oklab)
    case oklch(Oklch)
}

/// A color: process or spot.
///
/// Port of `Color` in `visualize/color.rs`.
public enum Color: Sendable, Hashable {
    case process(ProcessColor)
    case spot(SpotColor)

    public static let black = Color.process( .luma(Luma(lightness: 0, alpha: 1)))
    public static let gray = Color.process( .luma(Luma(lightness: 0.6666666, alpha: 1)))
    public static let white = Color.process( .luma(Luma(lightness: 1, alpha: 1)))
    public static let silver = Color.process( .luma(Luma(lightness: 0.8666667, alpha: 1)))
    public static let navy = Color.process( .rgb(Rgb(r: 0, g: 0.121569, b: 0.247059, a: 1)))
    public static let blue = Color.process( .rgb(Rgb(r: 0, g: 0.454902, b: 0.85098, a: 1)))
    public static let aqua = Color.process( .rgb(Rgb(r: 0.4980392, g: 0.858823, b: 1, a: 1)))
    public static let teal = Color.process( .rgb(Rgb(r: 0.223529, g: 0.8, b: 0.8, a: 1)))
    public static let eastern = Color.process( .rgb(Rgb(r: 0.13725, g: 0.615686, b: 0.678431, a: 1)))
    public static let purple = Color.process( .rgb(Rgb(r: 0.694118, g: 0.050980, b: 0.788235, a: 1)))
    public static let fuchsia = Color.process( .rgb(Rgb(r: 0.941177, g: 0.070588, b: 0.745098, a: 1)))
    public static let maroon = Color.process( .rgb(Rgb(r: 0.521569, g: 0.078431, b: 0.294118, a: 1)))
    public static let red = Color.process( .rgb(Rgb(r: 1, g: 0.254902, b: 0.211765, a: 1)))
    public static let orange = Color.process( .rgb(Rgb(r: 1, g: 0.521569, b: 0.105882, a: 1)))
    public static let yellow = Color.process( .rgb(Rgb(r: 1, g: 0.8627451, b: 0, a: 1)))
    public static let olive = Color.process( .rgb(Rgb(r: 0.239216, g: 0.6, b: 0.4392157, a: 1)))
    public static let green = Color.process( .rgb(Rgb(r: 0.1803922, g: 0.8, b: 0.2509804, a: 1)))
    public static let lime = Color.process( .rgb(Rgb(r: 0.0039216, g: 1, b: 0.4392157, a: 1)))
}

/// Grayscale color.
public struct Luma: Sendable, Hashable {
    public var lightness: Double
    public var alpha: Double
    public init(lightness: Double, alpha: Double = 1) {
        self.lightness = lightness; self.alpha = alpha
    }
}

/// sRGB color.
public struct Rgb: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// CMYK color (0-1 components).
public struct Cmyk: Sendable, Hashable {
    public var c: Double
    public var m: Double
    public var y: Double
    public var k: Double
    public var a: Double
    public init(c: Double, m: Double, y: Double, k: Double, a: Double = 1) {
        self.c = c; self.m = m; self.y = y; self.k = k; self.a = a
    }
}

/// HSL color.
public struct Hsl: Sendable, Hashable {
    public var h: Double
    public var s: Double
    public var l: Double
    public var a: Double
    public init(h: Double, s: Double, l: Double, a: Double = 1) {
        self.h = h; self.s = s; self.l = l; self.a = a
    }
}

/// HSV color.
public struct Hsv: Sendable, Hashable {
    public var h: Double
    public var s: Double
    public var v: Double
    public var a: Double
    public init(h: Double, s: Double, v: Double, a: Double = 1) {
        self.h = h; self.s = s; self.v = v; self.a = a
    }
}

/// Linear sRGB color.
public struct LinearRgb: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// Oklab color.
public struct Oklab: Sendable, Hashable {
    public var l: Double
    public var a: Double
    public var b: Double
    public var alpha: Double
    public init(l: Double, a: Double, b: Double, alpha: Double = 1) {
        self.l = l; self.a = a; self.b = b; self.alpha = alpha
    }
}

/// Oklch color.
public struct Oklch: Sendable, Hashable {
    public var l: Double
    public var c: Double
    public var h: Double
    public var alpha: Double
    public init(l: Double, c: Double, h: Double, alpha: Double = 1) {
        self.l = l; self.c = c; self.h = h; self.alpha = alpha
    }
}

/// A spot (named separation) color.
public struct SpotColor: Sendable, Hashable {
    /// The colorant name.
    public var name: String
    /// Alternate space fallback.
    public var alternate: ProcessColor
    /// Tint value 0-1.
    public var tint: Double
    /// Alpha.
    public var alpha: Double

    public init(name: String, alternate: ProcessColor, tint: Double, alpha: Double = 1) {
        self.name = name
        self.alternate = alternate
        self.tint = tint
        self.alpha = alpha
    }
}

/// A paint: solid color, gradient, or tiling.
///
/// Port of `Paint` in `visualize/paint.rs`.
public enum Paint: Sendable, Hashable {
    case solid(Color)
    case gradient(Gradient)
    case tiling(Tiling)
}

/// A gradient transition between color stops.
///
/// Port of `Gradient` in `visualize/gradient.rs` (structural subset).
public enum Gradient: Sendable, Hashable {
    case linear(LinearGradient)
    case radial(RadialGradient)
    case conic(ConicGradient)
}

/// A single gradient stop: color + offset.
public struct GradientStop: Sendable, Hashable {
    public var color: Color
    /// Offset 0-1, or `nil` for auto-spacing.
    public var offset: Ratio?
    /// Hint position for mid-point interpolation.
    public var hint: Ratio?

    public init(color: Color, offset: Ratio? = nil, hint: Ratio? = nil) {
        self.color = color
        self.offset = offset
        self.hint = hint
    }
}

/// Gradient color space.
public enum ColorSpace: String, Sendable, Hashable, CaseIterable {
    case srgb, linear, oklab, oklch, hsl, hsv
}

/// Relative placement of a gradient.
public enum RelativeTo: String, Sendable, Hashable, CaseIterable {
    case parent, cell
}

/// Shared gradient fields.
public protocol GradientKind {
    var stops: [GradientStop] { get set }
    var space: Smart<ColorSpace> { get set }
    var relative: Smart<RelativeTo> { get set }
}

/// A linear gradient.
public struct LinearGradient: GradientKind, Sendable, Hashable {
    public var stops: [GradientStop]
    public var space: Smart<ColorSpace>
    public var relative: Smart<RelativeTo>
    public var direction: Dir

    public init(stops: [GradientStop], space: Smart<ColorSpace> = .auto,
                relative: Smart<RelativeTo> = .auto, direction: Dir = .ltr) {
        self.stops = stops
        self.space = space
        self.relative = relative
        self.direction = direction
    }
}

/// A radial gradient.
public struct RadialGradient: GradientKind, Sendable, Hashable {
    public var stops: [GradientStop]
    public var space: Smart<ColorSpace>
    public var relative: Smart<RelativeTo>
    public var center: Point
    public var radius: Rel<Length>
    public var focalCenter: Point?
    public var focalRadius: Rel<Length>?

    public init(stops: [GradientStop], space: Smart<ColorSpace> = .auto,
                relative: Smart<RelativeTo> = .auto, center: Point = Point(x: .zero, y: .zero),
                radius: Rel<Length> = Rel<Length>.one(), focalCenter: Point? = nil,
                focalRadius: Rel<Length>? = nil) {
        self.stops = stops
        self.space = space
        self.relative = relative
        self.center = center
        self.radius = radius
        self.focalCenter = focalCenter
        self.focalRadius = focalRadius
    }
}

/// A conic gradient.
public struct ConicGradient: GradientKind, Sendable, Hashable {
    public var stops: [GradientStop]
    public var space: Smart<ColorSpace>
    public var relative: Smart<RelativeTo>
    public var center: Point
    public var angle: Angle

    public init(stops: [GradientStop], space: Smart<ColorSpace> = .auto,
                relative: Smart<RelativeTo> = .auto, center: Point = Point(x: .zero, y: .zero),
                angle: Angle = .zero) {
        self.stops = stops
        self.space = space
        self.relative = relative
        self.center = center
        self.angle = angle
    }
}

/// A repeating tile pattern.
///
/// Port of `Tiling` in `visualize/tiling.rs` (structural subset).
public struct Tiling: Sendable, Hashable {
    /// The tiled content.
    public var content: Content

    /// The tile size.
    public var size: Axes<Rel<Length>>

    /// Whether the tile repeats in x/y.
    public var repeatX: Bool
    public var repeatY: Bool

    /// Relative placement.
    public var relative: Smart<RelativeTo>

    /// Transform applied to the tile.
    public var transform: Transform

    public init(content: Content, size: Axes<Rel<Length>>,
                repeatX: Bool = true, repeatY: Bool = true,
                relative: Smart<RelativeTo> = .auto, transform: Transform = .identity) {
        self.content = content
        self.size = size
        self.repeatX = repeatX
        self.repeatY = repeatY
        self.relative = relative
        self.transform = transform
    }
}

/// A line cap style.
public enum LineCap: String, Sendable, Hashable, CaseIterable {
    case butt, round, square
}

/// A line join style.
public enum LineJoin: String, Sendable, Hashable, CaseIterable {
    case miter, round, bevel
}

/// A dash pattern.
///
/// Port of `DashPattern` in `visualize/stroke.rs`. `T` is the phase type;
/// `DT` is the dash-array element type (`DashLength<T>` before resolution,
/// `Abs` after).
public struct DashPattern<T: Numeric, DT> {
    /// The dash array.
    public var array: [DT]
    /// The dash phase (offset).
    public var phase: T

    public init(array: [DT], phase: T) {
        self.array = array
        self.phase = phase
    }
}

/// The length of a dash in a line dash pattern.
///
/// Port of `DashLength` in `visualize/stroke.rs`.
public enum DashLength<T: Numeric> {
    /// A length equal to the line width (the `"dot"` dash).
    case lineWidth
    /// An explicit length.
    case length(T)

    /// Resolve `lineWidth` entries against the stroke's thickness
    /// (upstream `DashLength::finish`).
    public func finish(_ lineWidth: T) -> T {
        switch self {
        case .lineWidth: return lineWidth
        case let .length(l): return l
        }
    }

    /// Map the contained length with `f` (upstream `Stroke::map` helper).
    public func map<U: Numeric>(_ f: (T) -> U) -> DashLength<U> {
        switch self {
        case .lineWidth: return .lineWidth
        case let .length(l): return .length(f(l))
        }
    }
}

extension DashLength: IntoValue where T: IntoValue {
    public func intoValue() -> Value {
        switch self {
        case .lineWidth: return .str(Str("dot"))
        case let .length(l): return l.intoValue()
        }
    }
}

extension DashLength: Resolve where T == Length {
    public typealias Output = DashLength<Abs>

    public func resolve(_ styles: StyleChain) -> DashLength<Abs> {
        switch self {
        case .lineWidth: return .lineWidth
        case let .length(l): return .length(l.resolve(styles))
        }
    }
}

extension DashPattern: Resolve where T == Length, DT == DashLength<Length> {
    public typealias Output = DashPattern<Abs, DashLength<Abs>>

    /// Resolve all lengths (upstream `Resolve for DashPattern`).
    public func resolve(_ styles: StyleChain) -> DashPattern<Abs, DashLength<Abs>> {
        DashPattern<Abs, DashLength<Abs>>(
            array: array.map { $0.resolve(styles) },
            phase: phase.resolve(styles)
        )
    }
}

extension DashPattern where T == Length, DT == DashLength<Length> {
    /// Create a length-based dash entry from an absolute length
    /// (upstream `From<Abs> for DashLength`).
    static func absEntry(_ abs: Abs) -> DashLength<Length> {
        .length(Length(abs: abs, em: .zero))
    }

    /// The named dash patterns (upstream preset table in `stroke.rs`).
    /// Returns `nil` for unknown names; `"solid"` yields an empty pattern.
    public static func preset(_ name: String) -> DashPattern<Length, DashLength<Length>>? {
        func pattern(_ array: [DashLength<Length>]) -> DashPattern<Length, DashLength<Length>> {
            DashPattern(array: array, phase: .zero)
        }
        switch name {
        case "solid": return pattern([])
        case "dotted": return pattern([.lineWidth, absEntry(.pt(2.0))])
        case "densely-dotted": return pattern([.lineWidth, absEntry(.pt(1.0))])
        case "loosely-dotted": return pattern([.lineWidth, absEntry(.pt(4.0))])
        case "dashed": return pattern([absEntry(.pt(3.0)), absEntry(.pt(3.0))])
        case "densely-dashed": return pattern([absEntry(.pt(3.0)), absEntry(.pt(2.0))])
        case "loosely-dashed": return pattern([absEntry(.pt(3.0)), absEntry(.pt(6.0))])
        case "dash-dotted":
            return pattern([absEntry(.pt(3.0)), absEntry(.pt(2.0)),
                            .lineWidth, absEntry(.pt(2.0))])
        case "densely-dash-dotted":
            return pattern([absEntry(.pt(3.0)), absEntry(.pt(1.0)),
                            .lineWidth, absEntry(.pt(1.0))])
        case "loosely-dash-dotted":
            return pattern([absEntry(.pt(3.0)), absEntry(.pt(4.0)),
                            .lineWidth, absEntry(.pt(4.0))])
        default: return nil
        }
    }
}

/// A stroke (pen) description.
///
/// Port of `Stroke<T>` in `visualize/stroke.rs`. `T` is the length type:
/// `Length` for the unresolved (style-chain) form, `Abs` after
/// `resolve(styles)`.
public struct Stroke<T: Numeric & Hashable> {
    /// The stroke's paint.
    public var paint: Smart<Paint>

    /// The stroke's thickness.
    public var thickness: Smart<T>

    /// The line cap.
    public var cap: Smart<LineCap>

    /// The line join.
    public var join: Smart<LineJoin>

    /// The dash pattern.
    public var dash: Smart<DashPattern<T, DashLength<T>>?>

    /// The miter limit.
    public var miterLimit: Smart<Ratio>

    public init(paint: Smart<Paint> = .auto,
                thickness: Smart<T> = .auto,
                cap: Smart<LineCap> = .auto,
                join: Smart<LineJoin> = .auto,
                dash: Smart<DashPattern<T, DashLength<T>>?> = .auto,
                miterLimit: Smart<Ratio> = .auto) {
        self.paint = paint
        self.thickness = thickness
        self.cap = cap
        self.join = join
        self.dash = dash
        self.miterLimit = miterLimit
    }

    /// Join with an outer stroke, preferring this stroke's custom fields
    /// (upstream `Stroke::or`).
    public func or(_ outer: Stroke<T>) -> Stroke<T> {
        Stroke(
            paint: paint.or(outer.paint),
            thickness: thickness.or(outer.thickness),
            cap: cap.or(outer.cap),
            join: join.or(outer.join),
            dash: dash.or(outer.dash),
            miterLimit: miterLimit.or(outer.miterLimit)
        )
    }

    /// Map the contained lengths with `f` (upstream `Stroke::map`).
    public func map<U: Numeric & Hashable>(_ f: @escaping (T) -> U) -> Stroke<U> {
        Stroke<U>(
            paint: paint,
            thickness: thickness.map(f),
            cap: cap,
            join: join,
            dash: dash.map { dash in
                dash.map { pattern in
                    DashPattern<U, DashLength<U>>(
                        array: pattern.array.map { $0.map(f) },
                        phase: f(pattern.phase)
                    )
                }
            },
            miterLimit: miterLimit
        )
    }
}

extension Stroke where T == Length {
    /// Create from a paint + thickness pair (the `color + length` op).
    public init(color: Color, thickness: Length) {
        self.init(paint: .custom(.solid(color)), thickness: .custom(thickness))
    }

    public init(gradient: Gradient, thickness: Length) {
        self.init(paint: .custom(.gradient(gradient)), thickness: .custom(thickness))
    }

    public init(tiling: Tiling, thickness: Length) {
        self.init(paint: .custom(.tiling(tiling)), thickness: .custom(thickness))
    }
}

extension Stroke where T == Length {
    /// Resolve all lengths against the style chain
    /// (upstream `Resolve for Stroke` → `Stroke<Abs>`).
    public func resolve(_ styles: StyleChain) -> Stroke<Abs> {
        Stroke<Abs>(
            paint: paint,
            thickness: thickness.resolve(styles),
            cap: cap,
            join: join,
            dash: dash.resolve(styles),
            miterLimit: miterLimit
        )
    }
}

extension Stroke: Fold where T: Fold {
    /// Fold two stroke values field-wise (upstream `Fold for Stroke`).
    /// `inner` is the inner style value, `outer` the outer one.
    public static func fold(_ inner: Stroke<T>, _ outer: Stroke<T>) -> Stroke<T> {
        inner.or(outer)
    }
}

extension Stroke where T == Abs {
    /// Unpack the stroke, filling missing fields from the `default`
    /// (upstream `Stroke<Abs>::unwrap_or`).
    public func unwrapOr(_ `default`: FixedStroke) -> FixedStroke {
        let thickness = thickness.custom() ?? `default`.thickness
        let dash: DashPattern<Abs, Abs>? = dash.mapOr(`default`.dash) { pattern in
            pattern.map { resolved in
                DashPattern<Abs, Abs>(
                    array: resolved.array.map { $0.finish(thickness) },
                    phase: resolved.phase
                )
            }
        }
        return FixedStroke(
            paint: paint.custom() ?? `default`.paint,
            thickness: thickness,
            cap: cap.custom() ?? `default`.cap,
            join: join.custom() ?? `default`.join,
            dash: dash,
            miterLimit: miterLimit.custom() ?? `default`.miterLimit
        )
    }

    /// Unpack the stroke, filling missing fields with the default values.
    public func unwrapOrDefault() -> FixedStroke {
        unwrapOr(FixedStroke())
    }
}

/// A fully specified stroke of a geometric shape.
///
/// Port of `FixedStroke` in `visualize/stroke.rs`.
public struct FixedStroke: Sendable, Hashable {
    /// The stroke's paint.
    public var paint: Paint
    /// The stroke's thickness.
    public var thickness: Abs
    /// The stroke's line cap.
    public var cap: LineCap
    /// The stroke's line join.
    public var join: LineJoin
    /// The stroke's line dash pattern (resolved to absolute lengths).
    public var dash: DashPattern<Abs, Abs>?
    /// The miter limit. Defaults to 4.0, same as `tiny-skia`.
    public var miterLimit: Ratio

    public init(paint: Paint, thickness: Abs, cap: LineCap, join: LineJoin,
                dash: DashPattern<Abs, Abs>?, miterLimit: Ratio) {
        self.paint = paint
        self.thickness = thickness
        self.cap = cap
        self.join = join
        self.dash = dash
        self.miterLimit = miterLimit
    }

    /// Create a stroke from a paint and a thickness
    /// (upstream `FixedStroke::from_pair`).
    public static func fromPair(paint: Paint, thickness: Abs) -> FixedStroke {
        var stroke = FixedStroke()
        stroke.paint = paint
        stroke.thickness = thickness
        return stroke
    }

    /// The default stroke (upstream `Default for FixedStroke`).
    public init() {
        self.init(
            paint: .solid(.black),
            thickness: .pt(1.0),
            cap: .butt,
            join: .miter,
            dash: nil,
            miterLimit: Ratio(4.0)
        )
    }
}

// MARK: - Value integration

extension Color: CustomDebugStringConvertible {
    public var debugDescription: String { "Color" }
}

extension Paint: CustomDebugStringConvertible {
    public var debugDescription: String { "Paint" }
}

extension Gradient: CustomDebugStringConvertible {
    public var debugDescription: String { "Gradient" }
}

extension Tiling: CustomDebugStringConvertible {
    public var debugDescription: String { "Tiling" }
}

extension Color: Repr {
    public func repr() -> String {
        switch self {
        case let .process(p): return p.repr()
        case let .spot(s): return "\(s.name.typstRepr)"
        }
    }
}

extension ProcessColor: Repr {
    public func repr() -> String {
        switch self {
        case let .luma(c): return "luma(\(c.lightness*100)%)"
        case let .rgb(c): return "rgb(\(Int((c.r*255).rounded())), \(Int((c.g*255).rounded())), \(Int((c.b*255).rounded())))"
        case let .cmyk(c): return "cmyk(\(c.c*100)%, \(c.m*100)%, \(c.y*100)%, \(c.k*100)%)"
        case let .hsl(c): return "hsl(\(c.h), \(c.s*100)%, \(c.l*100)%)"
        case let .hsv(c): return "hsv(\(c.h), \(c.s*100)%, \(c.v*100)%)"
        case let .linearRgb(c): return "linear-rgb(\(c.r), \(c.g), \(c.b))"
        case let .oklab(c): return "oklab(\(c.l), \(c.a), \(c.b))"
        case let .oklch(c): return "oklch(\(c.l), \(c.c), \(c.h))"
        }
    }
}

extension Paint: Repr {
    public func repr() -> String {
        switch self {
        case let .solid(c): return c.repr()
        case .gradient: return "gradient(..)"
        case .tiling: return "tiling(..)"
        }
    }
}

extension Gradient: Repr {
    public func repr() -> String { "gradient(..)" }
}

extension Tiling: Repr {
    public func repr() -> String { "tiling(..)" }
}

extension Stroke: Repr {
    public func repr() -> String { "stroke(..)" }
}

extension Stroke: CustomDebugStringConvertible {
    public var debugDescription: String { "Stroke" }
}

extension Color: DynamicBounds {
    public static var typeInfo: TypeInfo { TypeInfo(name: "color", longName: "color", title: "Color", since: .forever) }
}

extension Gradient: DynamicBounds {
    public static var typeInfo: TypeInfo { TypeInfo(name: "gradient", longName: "gradient", title: "Gradient", since: .version([0, 9, 0])) }
}

extension Tiling: DynamicBounds {
    public static var typeInfo: TypeInfo { TypeInfo(name: "tiling", longName: "tiling", title: "Tiling", since: .version([0, 13, 0]), keywords: ["pattern"]) }
}

extension Stroke: NativeType {
    public static var typeInfo: TypeInfo { TypeInfo(name: "stroke", title: "Stroke") }
}

extension Stroke: DynamicBounds {}

extension Paint: DynamicBounds {
    public static var typeInfo: TypeInfo { TypeInfo(name: "paint", title: "Paint") }
}


extension DashLength: Equatable where T: Equatable {}
extension DashLength: @unchecked Sendable {}
extension DashLength: Hashable where T: Hashable {}

extension DashPattern: Equatable where T: Equatable, DT: Equatable {}
extension DashPattern: @unchecked Sendable {}
extension DashPattern: Hashable where T: Hashable, DT: Hashable {}

extension Stroke: Equatable {}
extension Stroke: @unchecked Sendable {}
extension Stroke: Hashable {}
