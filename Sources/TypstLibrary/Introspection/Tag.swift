import Foundation
import TypstSyntax
import TypstUtils

/// Marks the start or end of a locatable element.
///
/// Port of `Tag` in `introspection/tag.rs`.
public enum Tag: Sendable, Hashable {
    /// The stored element starts here.
    ///
    /// Content placed in a tag **must** have a `Location` or there will be
    /// panics.
    case start(Content, TagFlags)
    /// The element with the given location and key hash ends here.
    case end(Location, Hash128, TagFlags)

    /// Access the location of the tag.
    public var location: Location {
        switch self {
        case let .start(elem, _): return elem.location!
        case let .end(loc, _, _): return loc
        }
    }
}

/// Flags for a tag.
///
/// Port of `TagFlags` in `introspection/tag.rs`.
public struct TagFlags: Sendable, Hashable {
    /// Whether the element will be inserted into the `Introspector`.
    /// Either because it is locatable, has been labelled, or a location has
    /// been manually set.
    public var introspectable: Bool
    /// Whether the element is tagged.
    public var tagged: Bool

    public init(introspectable: Bool, tagged: Bool) {
        self.introspectable = introspectable
        self.tagged = tagged
    }

    public var any: Bool { introspectable || tagged }
}

/// Holds a tag for a locatable element that was realized.
///
/// The `TagElem` is handled by all layouters. The held element becomes
/// available for introspection in the next compiler iteration.
///
/// Port of `TagElem` in `introspection/tag.rs`.
public struct TagElem: NativeElement {
    public static let info = ElementInfo(
        name: "tag",
        capabilities: []
    )

    /// The introspectable element.
    public var tag: Tag

    public var span: Span = .detached

    public init(tag: Tag) { self.tag = tag }

    /// Creates a tag element and directly packs it into type-erased content.
    public static func packed(_ tag: Tag) -> Content {
        var content = Content(TagElem(tag: tag))
        // We can skip preparation for the `TagElem`.
        content.markPrepared()
        return content
    }

    public func field(_ id: UInt8) -> Value? { nil }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {}

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        throw HintedString("cannot be constructed manually")
    }
}
