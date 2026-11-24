/// A single region to layout into.
///
/// Port of `Region` in `layout/regions.rs`.
public struct Region: Sendable, Hashable {
    /// The size of the region.
    public var size: Size
    /// Whether elements should expand to fill the regions instead of
    /// shrinking to fit the content.
    public var expand: Axes<Bool>

    /// Create a new region.
    public init(size: Size, expand: Axes<Bool>) {
        self.size = size
        self.expand = expand
    }
}

/// A sequence of regions to layout into.
///
/// A *region* is a contiguous rectangular space in which elements can be
/// laid out. All regions within a `Regions` value have the same width,
/// namely `size.x`. This means that it is not currently possible to, for
/// instance, have content wrap to the side of a floating element.
///
/// Port of `Regions` in `layout/regions.rs`. Upstream borrows the backlog
/// slice; the port owns it as an `ArraySlice` (cheap value semantics,
/// `popFirst` is O(1)).
public struct Regions: Sendable, Hashable {
    /// The remaining size of the first region.
    public var size: Size
    /// Whether elements should expand to fill the regions instead of
    /// shrinking to fit the content.
    public var expand: Axes<Bool>
    /// The full height of the region for relative sizing.
    public var full: Abs
    /// The height of followup regions. The width is the same for all
    /// regions.
    public var backlog: ArraySlice<Abs>
    /// The height of the final region that is repeated once the backlog is
    /// drained. The width is the same for all regions.
    public var last: Abs?

    /// Create a new sequence of same-size regions that repeats indefinitely.
    public static func `repeat`(size: Size, expand: Axes<Bool>) -> Regions {
        Regions(size: size, expand: expand, full: size.y,
                backlog: [], last: size.y)
    }

    /// Create regions from a single region.
    public init(region: Region) {
        self.init(size: region.size, expand: region.expand,
                  full: region.size.y, backlog: [], last: nil)
    }

    private init(size: Size, expand: Axes<Bool>, full: Abs,
                 backlog: ArraySlice<Abs>, last: Abs?) {
        self.size = size
        self.expand = expand
        self.full = full
        self.backlog = backlog
        self.last = last
    }

    /// The base size, which doesn't take into account that the regions is
    /// already partially used up.
    ///
    /// This is also used for relative sizing.
    public var base: Size {
        Size(x: size.x, y: full)
    }

    /// Create new regions where all sizes are mapped with `f`.
    ///
    /// Note that since all regions must have the same width, the width
    /// returned by `f` is ignored for the backlog and the final region.
    public func map(_ f: (Size) -> Size) -> Regions {
        let x = size.x
        return Regions(
            size: f(size),
            expand: expand,
            full: f(Size(x: x, y: full)).y,
            backlog: backlog.map { f(Size(x: x, y: $0)).y }[...],
            last: last.map { f(Size(x: x, y: $0)).y }
        )
    }

    /// Whether the first region is full and a region break is called for.
    public func isFull() -> Bool {
        Abs.zero.fits(size.y) && mayProgress()
    }

    /// Whether a region break is permitted.
    public func mayBreak() -> Bool {
        !backlog.isEmpty || last != nil
    }

    /// Whether calling `next()` may improve a situation where there is a
    /// lack of space.
    public func mayProgress() -> Bool {
        !backlog.isEmpty || (last.map { size.y != $0 } ?? false)
    }

    /// Advance to the next region if there is any.
    public mutating func next() {
        var height: Abs?
        if let first = backlog.popFirst() {
            height = first
        } else {
            height = last
        }
        if let height {
            size.y = height
            full = height
        }
    }
}

/// Iterator over the sizes of the first and all following regions,
/// equivalently to what would be produced by calling `next()` repeatedly
/// until all regions are exhausted. May be infinite.
public struct RegionsIterator: IteratorProtocol {
    private var regions: Regions

    init(_ regions: Regions) { self.regions = regions }

    public mutating func next() -> Size? {
        let size = regions.size
        regions.next()
        return size
    }
}

extension Regions {
    /// An iterator over region sizes (see `RegionsIterator`).
    public func makeIterator() -> RegionsIterator {
        RegionsIterator(self)
    }
}
