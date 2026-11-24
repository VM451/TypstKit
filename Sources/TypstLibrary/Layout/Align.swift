import Foundation

/// Horizontal alignment. Port of `HAlignment` in `align.rs`.
public enum HAlignment: String, Sendable, Hashable {
    case start, left, center, right, end

    public var inverted: HAlignment {
        switch self {
        case .start: return .end
        case .left: return .right
        case .center: return .center
        case .right: return .left
        case .end: return .start
        }
    }
}

extension HAlignment: Default {
    public static var `default`: HAlignment { .start }
}

extension HAlignment: Repr {
    public func repr() -> String { rawValue }
}

/// Vertical alignment. Port of `VAlignment`.
public enum VAlignment: String, Sendable, Hashable {
    case top, horizon, bottom

    public var inverted: VAlignment {
        switch self {
        case .top: return .bottom
        case .horizon: return .horizon
        case .bottom: return .top
        }
    }

    /// The position of the alignment within `extent`.
    public func position(_ extent: Abs) -> Abs {
        switch self {
        case .top: return .zero
        case .horizon: return extent / 2.0
        case .bottom: return extent
        }
    }
}

extension VAlignment: Default {
    public static var `default`: VAlignment { .top }
}

extension VAlignment: Repr {
    public func repr() -> String { rawValue }
}

/// Outer (page-relative) horizontal alignment. Port of `OuterHAlignment`.
public enum OuterHAlignment: String, Sendable, Hashable {
    case start, left, right, end
}

extension OuterHAlignment: Default {
    public static var `default`: OuterHAlignment { .start }
}

/// Outer (page-relative) vertical alignment. Port of `OuterVAlignment`.
public enum OuterVAlignment: String, Sendable, Hashable {
    case top, bottom
}

extension OuterVAlignment: Default {
    public static var `default`: OuterVAlignment { .top }
}

/// A fixed (direction-resolved) alignment. Port of `FixedAlignment`.
public enum FixedAlignment: Int, Sendable, Hashable {
    case start, center, end

    /// The position of the alignment within `extent`.
    public func position(_ extent: Abs) -> Abs {
        switch self {
        case .start: return .zero
        case .center: return extent / 2.0
        case .end: return extent
        }
    }

    public var inverted: FixedAlignment {
        switch self {
        case .start: return .end
        case .center: return .center
        case .end: return .start
        }
    }
}

/// Resolves a direction-dependent alignment to a `FixedAlignment`.
/// Port of `FixAlignment`.
public protocol FixAlignment {
    func fix(_ dir: Dir) -> FixedAlignment
}

extension HAlignment: FixAlignment {
    public func fix(_ dir: Dir) -> FixedAlignment {
        switch (self, dir.isPositive) {
        case (.start, true), (.end, false): return .start
        case (.left, _): return .start
        case (.center, _): return .center
        case (.right, _): return .end
        case (.end, true), (.start, false): return .end
        }
    }
}

extension OuterHAlignment: FixAlignment {
    public func fix(_ dir: Dir) -> FixedAlignment {
        switch (self, dir.isPositive) {
        case (.start, true), (.end, false): return .start
        case (.left, _): return .start
        case (.right, _): return .end
        case (.end, true), (.start, false): return .end
        }
    }
}

extension VAlignment: FixAlignment {
    /// Vertical alignment does not depend on text direction.
    public func fix(_ dir: Dir) -> FixedAlignment {
        switch self {
        case .top: return .start
        case .horizon: return .center
        case .bottom: return .end
        }
    }
}

extension OuterVAlignment: FixAlignment {
    public func fix(_ dir: Dir) -> FixedAlignment {
        switch self {
        case .top: return .start
        case .bottom: return .end
        }
    }
}

extension FixedAlignment: FixAlignment {
    public func fix(_ dir: Dir) -> FixedAlignment { self }
}

extension FixedAlignment {
    public init(_ side: Side) {
        switch side {
        case .left, .top: self = .start
        case .right, .bottom: self = .end
        }
    }
}

/// A 1D or 2D alignment. Port of `Alignment` in `align.rs`.
public enum Alignment: Sendable, Hashable {
    case h(HAlignment)
    case v(VAlignment)
    case both(HAlignment, VAlignment)

    public static let start = Alignment.h(.start)
    public static let end = Alignment.h(.end)
    public static let left = Alignment.h(.left)
    public static let center = Alignment.h(.center)
    public static let right = Alignment.h(.right)
    public static let top = Alignment.v(.top)
    public static let horizon = Alignment.v(.horizon)
    public static let bottom = Alignment.v(.bottom)

    public var horizontal: HAlignment? {
        switch self {
        case let .h(h), let .both(h, _): return h
        case .v: return nil
        }
    }

    public var vertical: VAlignment? {
        switch self {
        case let .v(v), let .both(_, v): return v
        case .h: return nil
        }
    }

    /// Resolve start/end against a text direction.
    public func fix(_ textDir: Dir) -> Axes<FixedAlignment> {
        Axes(
            x: (horizontal ?? .start).fix(textDir),
            y: (vertical ?? .top).fix(textDir)
        )
    }

    /// The axis this alignment constrains, if purely 1D.
    public var axis: Axis? {
        switch self {
        case .h: return .x
        case .v: return .y
        case .both: return nil
        }
    }

    /// The opposite alignment.
    public var inverted: Alignment {
        switch self {
        case let .h(h): return .h(h.inverted)
        case let .v(v): return .v(v.inverted)
        case let .both(h, v): return .both(h.inverted, v.inverted)
        }
    }
}

extension Alignment: Default {
    /// `HAlignment::default() + VAlignment::default()` = `Both(start, top)`.
    public static var `default`: Alignment { .both(.start, .top) }
}

extension Alignment: Repr {
    public func repr() -> String {
        switch self {
        case let .h(h): return h.repr()
        case let .v(v): return v.repr()
        case let .both(h, v): return "\(h.repr()) + \(v.repr())"
        }
    }
}

/// Combine two alignments into a 2D alignment (upstream `Add`).
/// Returns an error string for invalid combinations, mirroring upstream's
/// `StrResult` return.
public func + (lhs: Alignment, rhs: Alignment) -> StrResult<Alignment> {
    switch (lhs, rhs) {
    case let (.h(h), .v(v)), let (.v(v), .h(h)):
        return .success(.both(h, v))
    case (.h, .h):
        return .failure(StrError("cannot add two horizontal alignments"))
    case (.v, .v):
        return .failure(StrError("cannot add two vertical alignments"))
    case (.h, .both), (.both, .h):
        return .failure(StrError("cannot add a horizontal and a 2D alignment"))
    case (.v, .both), (.both, .v):
        return .failure(StrError("cannot add a vertical and a 2D alignment"))
    case (.both, .both):
        return .failure(StrError("cannot add two 2D alignments"))
    }
}

extension Alignment {
    /// Fold inner alignment with outer (upstream `Fold for Alignment`).
    public func folded(with outer: Alignment) -> Alignment {
        switch (self, outer) {
        case let (.h(h), .v(v)), let (.h(h), .both(_, v)):
            return .both(h, v)
        case let (.v(v), .h(h)), let (.v(v), .both(h, _)):
            return .both(h, v)
        default:
            return self
        }
    }
}

extension Alignment {
    public init(_ side: Side) {
        switch side {
        case .left: self = .left
        case .top: self = .top
        case .right: self = .right
        case .bottom: self = .bottom
        }
    }
}

/// `HAlignment + VAlignment -> Alignment::Both` (infallible, upstream `Add`).
public func + (lhs: HAlignment, rhs: VAlignment) -> Alignment { .both(lhs, rhs) }

/// `VAlignment + HAlignment -> Alignment::Both`.
public func + (lhs: VAlignment, rhs: HAlignment) -> Alignment { .both(rhs, lhs) }

extension HAlignment {
    public init?(_ align: Alignment) {
        guard case let .h(h) = align else { return nil }
        self = h
    }
}

extension VAlignment {
    public init?(_ align: Alignment) {
        guard case let .v(v) = align else { return nil }
        self = v
    }
}

/// A generic 1D-or-2D alignment over arbitrary alignment types.
/// Port of `SpecificAlignment<H, V>`.
public enum SpecificAlignment<H, V> {
    case h(H)
    case v(V)
    case both(H, V)

    public var horizontal: H? {
        switch self {
        case let .h(h), let .both(h, _): return h
        case .v: return nil
        }
    }

    public var vertical: V? {
        switch self {
        case let .v(v), let .both(_, v): return v
        case .h: return nil
        }
    }

    public func fix(_ textDir: Dir) -> Axes<FixedAlignment>
    where H: FixAlignment & Default, V: FixAlignment & Default {
        Axes(
            x: (horizontal ?? H.default).fix(textDir),
            y: (vertical ?? V.default).fix(textDir)
        )
    }
}


extension SpecificAlignment: Equatable where H: Equatable, V: Equatable {}
extension SpecificAlignment: @unchecked Sendable {}
extension SpecificAlignment: Hashable where H: Hashable, V: Hashable {}
