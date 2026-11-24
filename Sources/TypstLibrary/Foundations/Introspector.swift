import Foundation
import TypstSyntax

/// Introspection state for `locate`/`query`/`context`.
///
/// Port of `Introspector` in `introspection/introspector.rs`. The full
/// multi-pass implementation lands with the introspection phase; this is
/// the storage shell the `Engine` already references.
public struct Introspector: Sendable {
    /// Pages discovered so far, in order.
    public private(set) var pages: [Page] = []

    public init() {}

    /// A laid-out page known to the introspector.
    public struct Page: Sendable {
        /// The page's frame number (1-based upstream `Page` numbering is
        /// handled by callers).
        public var number: Int
        /// Elements on the page with their locations.
        public var elements: [LocatedElement] = []

        public init(number: Int) { self.number = number }
    }

    /// An element paired with its unique location.
    public struct LocatedElement: Sendable {
        public var location: Int
        public var content: Content

        public init(location: Int, content: Content) {
            self.location = location
            self.content = content
        }
    }
}
