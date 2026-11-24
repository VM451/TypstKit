/// A rectangle in 2D.
///
/// Port of `Rect` in `layout/rect.rs`.
public struct Rect: Sendable, Hashable {
    /// The top left corner (minimum coordinate).
    public var min: Point
    /// The bottom right corner (maximum coordinate).
    public var max: Point

    /// Create a new rectangle from the minimum/maximum coordinate.
    public init(min: Point, max: Point) {
        self.min = min
        self.max = max
    }

    /// Create a new rectangle from the position and size.
    public init(pos: Point, size: Size) {
        self.init(min: pos, max: pos + size.toPoint())
    }

    /// Compute the size of the rectangle.
    public var size: Size {
        Size(x: max.x - min.x, y: max.y - min.y)
    }
}
