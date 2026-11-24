import TypstUtils

/// How to close a curve.
///
/// Port of `CloseMode` in `visualize/curve.rs`.
public enum CloseMode: String, Sendable, Hashable, CaseIterable {
    /// Closes the curve with a smooth segment that takes into account the
    /// control point opposite the start point.
    case smooth
    /// Closes the curve with a straight line.
    case straight
}

/// A curve consisting of movements, lines, and Bézier segments.
///
/// Port of `Curve` in `visualize/curve.rs`.
public struct Curve: Sendable, Hashable {
    public var items: [CurveItem]

    /// Creates an empty curve.
    public init() { items = [] }
    public init(items: [CurveItem]) { self.items = items }

    /// Creates a curve that describes a rectangle.
    public static func rect(_ size: Size) -> Curve {
        let z = Abs.zero
        var curve = Curve()
        curve.move_(Point(x: z, y: z))
        curve.line(Point(x: size.x, y: z))
        curve.line(Point(x: size.x, y: size.y))
        curve.line(Point(x: z, y: size.y))
        curve.close()
        return curve
    }

    /// Creates a curve that describes an axis-aligned ellipse.
    ///
    /// https://stackoverflow.com/a/2007782
    public static func ellipse(_ size: Size) -> Curve {
        let z = Abs.zero
        let rx = size.x / 2.0
        let ry = size.y / 2.0
        let m = 0.551784
        let mx = m * rx
        let my = m * ry
        func point(_ x: Abs, _ y: Abs) -> Point {
            Point(x: x + rx, y: y + ry)
        }

        var curve = Curve()
        curve.move_(point(-rx, z))
        curve.cubic(point(-rx, -my), point(-mx, -ry), point(z, -ry))
        curve.cubic(point(mx, -ry), point(rx, -my), point(rx, z))
        curve.cubic(point(rx, my), point(mx, ry), point(z, ry))
        curve.cubic(point(-mx, ry), point(-rx, my), point(-rx, z))
        return curve
    }

    /// Push a `move` item.
    public mutating func move_(_ p: Point) {
        items.append(.move(p))
    }

    /// Push a `line` item.
    public mutating func line(_ p: Point) {
        items.append(.line(p))
    }

    /// Push a `cubic` item.
    public mutating func cubic(_ p1: Point, _ p2: Point, _ p3: Point) {
        items.append(.cubic(p1, p2, p3))
    }

    /// Push a `close` item.
    public mutating func close() {
        items.append(.close)
    }

    /// Check if the curve is empty.
    public var isEmpty: Bool { items.isEmpty }

    /// Translate all points in this curve by the given offset.
    public mutating func translate(_ offset: Point) {
        if offset == .zero { return }
        for i in items.indices {
            switch items[i] {
            case var .move(p):
                p += offset
                items[i] = .move(p)
            case var .line(p):
                p += offset
                items[i] = .line(p)
            case var .cubic(p1, p2, p3):
                p1 += offset
                p2 += offset
                p3 += offset
                items[i] = .cubic(p1, p2, p3)
            case .close:
                break
            }
        }
    }

    /// Computes the bounding box of this curve.
    ///
    /// Upstream uses `kurbo`: the fill bbox is exact (curve extrema), the
    /// stroked bbox comes from the stroked outline. The port computes the
    /// exact fill bbox analytically and approximates the stroked bbox by
    /// expanding each segment's bbox by half the stroke thickness (exact
    /// for axis-aligned geometry, conservative for diagonal joins).
    public func bbox(stroke: FixedStroke?) -> Rect {
        var min = Point(x: .infinity, y: .infinity)
        var max = Point(x: -.infinity, y: -.infinity)
        let pad: Abs = stroke.map { 0.5 * $0.thickness } ?? .zero

        func include(_ p: Point) {
            min = min.min(p - Point.splat(pad))
            max = max.max(p + Point.splat(pad))
        }

        var cursor = Point.zero
        var start = Point.zero
        for item in items {
            switch item {
            case let .move(p):
                cursor = p
                start = p
                include(p)
            case let .line(p):
                // Exact: a line's bbox is its endpoints' bbox.
                include(p)
                cursor = p
            case let .cubic(c1, c2, p):
                for q in cubicExtremaPoints(p0: cursor, p1: c1, p2: c2, p3: p) {
                    include(q)
                }
                cursor = p
            case .close:
                include(start)
                cursor = start
            }
        }

        guard min.x.isFinite else {
            return Rect(min: .zero, max: .zero)
        }
        return Rect(min: min, max: max)
    }

    /// When this curve is interpreted as a clip mask, would it contain
    /// `point`? (upstream `Curve::contains` — winding-number test on the
    /// flattened path).
    public func contains(_ fillRule: FillRule, needle: Point) -> Bool {
        let windings = windingNumber(at: needle)
        switch fillRule {
        case .nonZero: return windings != 0
        case .evenOdd: return windings % 2 != 0
        }
    }

    /// When this curve is stroked with `stroke`, would the stroke contain
    /// `point`?
    ///
    /// Upstream delegates to `kurbo::stroke` (accounts for caps, joins,
    /// miter limits and dash patterns). The port approximates with the
    /// minimum distance to the flattened path compared against half the
    /// stroke thickness — exact for round joins/caps, conservative for
    /// mitered acute angles, and dash patterns are not applied.
    public func strokeContains(_ stroke: FixedStroke, needle: Point) -> Bool {
        let limit = 0.5 * stroke.thickness
        var best = Double.infinity
        for (a, b) in flattenedSegments() {
            best = min(best, distanceToSegment(needle, a, b))
        }
        return best <= limit.toRaw
    }

    // MARK: - Path flattening & winding

    /// Flatten the curve into line segments (cubic subdivision).
    /// Returns `(start, end)` point pairs in order.
    func flattenedSegments(tolerance: Double = 0.01) -> [(Point, Point)] {
        var segments: [(Point, Point)] = []
        var cursor = Point.zero
        var start = Point.zero
        for item in items {
            switch item {
            case let .move(p):
                cursor = p
                start = p
            case let .line(p):
                segments.append((cursor, p))
                cursor = p
            case let .cubic(c1, c2, p):
                flattenCubic(p0: cursor, p1: c1, p2: c2, p3: p,
                             tolerance: tolerance, into: &segments)
                cursor = p
            case .close:
                segments.append((cursor, start))
                cursor = start
            }
        }
        return segments
    }

    /// The winding number of `point` w.r.t. the flattened path.
    func windingNumber(at point: Point) -> Int {
        var winding = 0
        let px = point.x.toRaw, py = point.y.toRaw
        for (a, b) in flattenedSegments() {
            let x1 = a.x.toRaw, y1 = a.y.toRaw
            let x2 = b.x.toRaw, y2 = b.y.toRaw
            if y1 <= py {
                if y2 > py && isLeft(x1, y1, x2, y2, px, py) > 0 { winding += 1 }
            } else if y2 <= py && isLeft(x1, y1, x2, y2, px, py) < 0 {
                winding -= 1
            }
        }
        return winding
    }

    /// Exact bbox of a cubic Bézier segment: endpoints plus points where
    /// the derivative vanishes (upstream kurbo's `PathSeg::bounding_box`).
    private func cubicExtremaPoints(p0: Point, p1: Point, p2: Point,
                                    p3: Point) -> [Point] {
        func roots(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double)
            -> [Double]
        {
            // B'(t) = 3(1-t)²(p1-p0) + 6(1-t)t(p2-p1) + 3t²(p3-p2)
            //       = at² + bt + c
            let a = -p0 + 3 * p1 - 3 * p2 + p3
            let b = 2 * (p0 - 2 * p1 + p2)
            let c = p1 - p0
            if abs(a) < 1e-12 {
                if abs(b) < 1e-12 { return [] }
                let t = -c / b
                return (t > 0 && t < 1) ? [t] : []
            }
            let disc = b * b - 4 * a * c
            guard disc >= 0 else { return [] }
            let s = disc.squareRoot()
            return [-b + s, -b - s]
                .map { ($0 / (2 * a)) }
                .filter { $0 > 0 && $0 < 1 }
        }

        func eval(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double,
                  _ t: Double) -> Double {
            let u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p1
                + 3 * u * t * t * p2 + t * t * t * p3
        }

        var points = [p0, p3]
        let ts = Set(roots(p0.x.toRaw, p1.x.toRaw, p2.x.toRaw, p3.x.toRaw)
            + roots(p0.y.toRaw, p1.y.toRaw, p2.y.toRaw, p3.y.toRaw))
        for t in ts {
            points.append(Point(
                x: Abs(raw: Scalar(eval(p0.x.toRaw, p1.x.toRaw, p2.x.toRaw,
                                       p3.x.toRaw, t))),
                y: Abs(raw: Scalar(eval(p0.y.toRaw, p1.y.toRaw, p2.y.toRaw,
                                       p3.y.toRaw, t)))
            ))
        }
        return points
    }
}

/// An item in a curve.
///
/// Port of `CurveItem` in `visualize/curve.rs`.
public enum CurveItem: Sendable, Hashable {
    case move(Point)
    case line(Point)
    case cubic(Point, Point, Point)
    case close
}

// MARK: - Curve math helpers

/// `isLeft` test for winding computation.
private func isLeft(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                    _ px: Double, _ py: Double) -> Double {
    (x2 - x1) * (py - y1) - (px - x1) * (y2 - y1)
}

/// Distance from `p` to segment `a`–`b`.
private func distanceToSegment(_ p: Point, _ a: Point, _ b: Point) -> Double {
    let px = p.x.toRaw, py = p.y.toRaw
    let ax = a.x.toRaw, ay = a.y.toRaw
    let bx = b.x.toRaw, by = b.y.toRaw
    let dx = bx - ax, dy = by - ay
    let lenSq = dx * dx + dy * dy
    var t = lenSq > 0 ? ((px - ax) * dx + (py - ay) * dy) / lenSq : 0
    t = max(0, min(1, t))
    let cx = ax + t * dx, cy = ay + t * dy
    return ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
}

/// Recursively flatten a cubic Bézier into line segments (de Casteljau
/// subdivision until the control polygon is within `tolerance` of the
/// chord).
private func flattenCubic(p0: Point, p1: Point, p2: Point, p3: Point,
                          tolerance: Double,
                          into segments: inout [(Point, Point)]) {
    // Flatness: max distance of interior control points from the chord.
    let d1 = pointLineDistance(p1, p0, p3)
    let d2 = pointLineDistance(p2, p0, p3)
    if max(d1, d2) <= tolerance {
        segments.append((p0, p3))
        return
    }
    // de Casteljau split at t = 0.5.
    let m01 = midpoint(p0, p1)
    let m12 = midpoint(p1, p2)
    let m23 = midpoint(p2, p3)
    let m012 = midpoint(m01, m12)
    let m123 = midpoint(m12, m23)
    let m0123 = midpoint(m012, m123)
    flattenCubic(p0: p0, p1: m01, p2: m012, p3: m0123,
                 tolerance: tolerance, into: &segments)
    flattenCubic(p0: m0123, p1: m123, p2: m23, p3: p3,
                 tolerance: tolerance, into: &segments)
}

private func midpoint(_ a: Point, _ b: Point) -> Point {
    (a + b) * 0.5
}

/// Distance from `p` to the infinite line through `a`–`b`.
private func pointLineDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
    let px = p.x.toRaw, py = p.y.toRaw
    let ax = a.x.toRaw, ay = a.y.toRaw
    let bx = b.x.toRaw, by = b.y.toRaw
    let dx = bx - ax, dy = by - ay
    let len = (dx * dx + dy * dy).squareRoot()
    if len == 0 { return ((px - ax) * (px - ax) + (py - ay) * (py - ay)).squareRoot() }
    return abs(dy * px - dx * py + bx * ay - by * ax) / len
}
