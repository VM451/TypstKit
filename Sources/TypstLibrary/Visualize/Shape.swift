/// A fill rule for curve drawing.
///
/// Port of `FillRule` in `visualize/shape.rs`.
public enum FillRule: String, Sendable, Hashable, CaseIterable {
    /// "Inside" is computed by a non-zero sum of signed edge crossings.
    case nonZero = "non-zero"
    /// "Inside" is computed by an odd number of edge crossings.
    case evenOdd = "even-odd"
}

/// A geometric shape with optional fill and stroke.
///
/// Port of `Shape` in `visualize/shape.rs`.
public struct Shape: Sendable, Hashable {
    /// The shape's geometry.
    public var geometry: Geometry
    /// The shape's background fill.
    public var fill: Paint?
    /// The shape's fill rule.
    public var fillRule: FillRule
    /// The shape's border stroke.
    public var stroke: FixedStroke?

    public init(geometry: Geometry, fill: Paint?, fillRule: FillRule,
                stroke: FixedStroke?) {
        self.geometry = geometry
        self.fill = fill
        self.fillRule = fillRule
        self.stroke = stroke
    }

    /// The bounding box of the shape,
    /// optionally taking the stroke into account.
    public func bbox(includeStroke: Bool) -> Rect {
        geometry.bbox(stroke: includeStroke ? stroke : nil)
    }
}

/// A shape's geometry.
///
/// Port of `Geometry` in `visualize/shape.rs`.
public enum Geometry: Sendable, Hashable {
    /// A line to a point (relative to its position).
    case line(Point)
    /// A rectangle with its origin in the top-left corner.
    case rect(Size)
    /// A curve consisting of movements, lines, and Bézier segments.
    case curve(Curve)

    /// Fill the geometry without a stroke.
    public func filled(_ fill: Paint) -> Shape {
        Shape(geometry: self, fill: fill, fillRule: .nonZero, stroke: nil)
    }

    /// Stroke the geometry without a fill.
    public func stroked(_ stroke: FixedStroke) -> Shape {
        Shape(geometry: self, fill: nil, fillRule: .nonZero, stroke: stroke)
    }

    /// Set the geometry's background fill and stroke.
    public func filledAndStroked(_ fill: Paint, _ stroke: FixedStroke) -> Shape {
        Shape(geometry: self, fill: fill, fillRule: .nonZero, stroke: stroke)
    }

    /// The bounding box of the geometry,
    /// optionally taking the stroke width of the shape into account.
    public func bbox(stroke: FixedStroke?) -> Rect {
        switch self {
        case let .line(end):
            if let stroke {
                return bboxOfStrokedLine(end: end, stroke: stroke)
            }
            return Rect(min: end.min(.zero), max: end.max(.zero))
        case let .rect(size):
            let min = size.toPoint().min(.zero)
            let strokeWidth = stroke?.thickness ?? .zero
            return Rect(
                pos: min.map { $0 - 0.5 * strokeWidth },
                size: size.map { $0.abs() + strokeWidth }
            )
        case let .curve(curve):
            return curve.bbox(stroke: stroke)
        }
    }
}

/// The bounding box of a line including the stroke.
///
/// Upstream delegates to `kurbo::stroke`; the port computes the analytic
/// equivalent for a single segment (capsule/rectangle depending on cap).
private func bboxOfStrokedLine(end: Point, stroke: FixedStroke) -> Rect {
    let half = 0.5 * stroke.thickness
    switch stroke.cap {
    case .round:
        // Capsule: segment bbox expanded by the radius on all sides.
        return Rect(
            min: end.min(.zero) - Point.splat(half),
            max: end.max(.zero) + Point.splat(half)
        )
    case .butt, .square:
        // Rectangle around the segment; square caps additionally extend
        // half the thickness along the segment direction at both ends.
        let len = end.hypot()
        var a = Point.zero
        var b = end
        if stroke.cap == .square, len > .zero {
            let dir = end / len.toRaw
            a = a - dir * half.toRaw
            b = b + dir * half.toRaw
        }
        // Perpendicular offset of half the thickness.
        let perp = Point(x: -end.y, y: end.x)
        let pl = perp.hypot()
        var min = a.min(b)
        var max = a.max(b)
        if pl > .zero {
            let n = perp / pl.toRaw * half.toRaw
            for p in [a + n, a - n, b + n, b - n] {
                min = min.min(p)
                max = max.max(p)
            }
        }
        return Rect(min: min, max: max)
    }
}
