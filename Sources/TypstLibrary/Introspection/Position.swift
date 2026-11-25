import Foundation
import TypstSyntax
import TypstUtils

/// Physical position in a document, be it paged or HTML.
///
/// Port of `DocumentPosition` in `introspection/position.rs`.
public enum DocumentPosition: Sendable, Hashable {
    /// Position inside of a page (paged documents).
    case paged(PagedPosition)
    /// Position pointing to a node in an HTML DOM tree.
    case html(HtmlPosition)

    /// The `PagedPosition` if this is one.
    public var asPaged: PagedPosition? {
        if case let .paged(p) = self { return p }
        return nil
    }

    /// The `PagedPosition` or the origin of page 1.
    public var asPagedOrDefault: PagedPosition {
        asPaged ?? .origin
    }

    /// The `HtmlPosition` if available.
    public var asHTML: HtmlPosition? {
        if case let .html(h) = self { return h }
        return nil
    }
}

/// A physical position in a paged document.
///
/// Port of `PagedPosition`.
public struct PagedPosition: Sendable, Hashable {
    /// The page, starting at 1.
    public var page: NonZeroUsize
    /// The exact coordinates on the page (from the top left).
    public var point: Point

    public static let origin = PagedPosition(
        page: NonZeroUsize(value: 1), point: .zero)

    public init(page: NonZeroUsize, point: Point) {
        self.page = page
        self.point = point
    }
}

extension PagedPosition: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Dict.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        if case .dict = value { return true }
        return false
    }

    public func intoValue() -> Value {
        var dict = Dict()
        dict.insert("page", page.intoValue())
        dict.insert("x", Length(point.x).intoValue())
        dict.insert("y", Length(point.y).intoValue())
        return .dict(dict)
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .dict(dict) = value else {
            return .failure(error(value))
        }
        var rest = dict
        guard case .success(let pageValue) = rest.take("page"),
              case let .success(page) = NonZeroUsize.fromValue(pageValue),
              case .success(let xValue) = rest.take("x"),
              case .success(let yValue) = rest.take("y"),
              case let .success(x) = Length.fromValue(xValue),
              case let .success(y) = Length.fromValue(yValue),
              case .success = rest.finish(expected: ["page", "x", "y"])
        else { return .failure(error(value)) }
        return .success(PagedPosition(
            page: page, point: Point(x: x.abs, y: y.abs)))
    }
}

/// A position in an HTML tree.
///
/// Port of `HtmlPosition`.
public struct HtmlPosition: Sendable, Hashable {
    /// Indices traversing the tree from the root.
    private var elementPath: [Int]
    /// The precise position inside of the specified element.
    private var inner: InnerHtmlPosition?

    /// A position pointing to a node as a whole.
    public init(element: [Int]) {
        self.elementPath = element
        self.inner = nil
    }

    /// A character offset inside of a text node (in codepoints).
    public func atChar(_ offset: Int) -> HtmlPosition {
        var copy = self
        copy.inner = .character(offset)
        return copy
    }

    /// A point inside of a frame node.
    public func inFrame(_ point: Point) -> HtmlPosition {
        var copy = self
        copy.inner = .frame(point)
        return copy
    }

    /// Extra information for a more precise location.
    public var details: InnerHtmlPosition? { inner }

    /// Indices for traversing the HTML tree to the node.
    public var element: [Int] { elementPath }
}

/// A precise position inside of an HTML node.
///
/// Port of `InnerHtmlPosition`.
public enum InnerHtmlPosition: Sendable, Hashable {
    /// Coordinates within a frame node.
    case frame(Point)
    /// Index of the codepoint within a text node.
    case character(Int)
}
