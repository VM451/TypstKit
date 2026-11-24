import Foundation
import TypstSyntax
import TypstUtils

/// A locator assigns unique locations to elements during realization and
/// layout. See the type-level docs in upstream `locator.rs`.
///
/// Port of `Locator` in `introspection/locator.rs`. Upstream's comemo
/// `Tracked` links are replaced by direct `LocatorLink` references.
public struct Locator: Sendable {
    /// A local hash that incorporates all layers since the last memoization
    /// boundary.
    var local: Hash128
    /// A pointer to an outer cached locator, which contributes the information
    /// for all the layers beyond the memoization boundary on-demand.
    var outer: LocatorLink?

    /// Create a new root-level locator.
    public static func root() -> Locator {
        Locator(local: Hash128(high: 0, low: 0), outer: nil)
    }

    /// Creates a new synthetic locator.
    ///
    /// This can be used to create a new dependent layout based on an element.
    /// This is used for layouting footnote entries based on the location
    /// of the associated footnote.
    public static func synthesize(location: Location) -> Locator {
        Locator(local: location.hash, outer: nil)
    }

    /// Creates a new locator that points to the given link.
    public init(link: LocatorLink) {
        self.local = Hash128(high: 0, low: 0)
        self.outer = link
    }

    init(local: Hash128, outer: LocatorLink?) {
        self.local = local
        self.outer = outer
    }

    /// Returns a type that can be used to generate `Locator`s for multiple
    /// child elements. See the type-level docs for more details.
    public func split() -> SplitLocator {
        SplitLocator(local: local, outer: outer, disambiguators: [:])
    }

    /// Creates a copy of this locator for measurement or relayout of the same
    /// content.
    public func relayout() -> Locator { self }

    /// Resolves the locator based on its local and the outer information.
    func resolve() -> Resolved {
        guard let outer else { return .hash(local) }
        switch outer.resolve() {
        case let .hash(outerHash):
            return .hash(hash128(LocatorPairHash(local: local, outer: outerHash)))
        case let .measure(base, span):
            return .measure(base: base, span: span)
        }
    }
}

/// Hashable pair used for combining locator hashes (Swift tuples aren't
/// `Hashable`).
private struct LocatorPairHash: Hashable {
    var local: Hash128
    var outer: Hash128
}

/// Hashable triple for sub-locator hashes.
private struct LocatorTripleHash: Hashable {
    var key: Hash128
    var disambiguator: Int
    var local: Hash128
}

/// The fully resolved value of a locator.
enum Resolved: Sendable {
    /// The full hash, incorporating the local and all outer information.
    case hash(Hash128)
    /// Indicates that the locator is in measurement mode, with the given base
    /// location.
    case measure(base: Location, span: Span)
}

/// A locator can be linked to this type to only access information across the
/// memoization boundary on-demand.
///
/// Port of `LocatorLink` in `introspection/locator.rs`.
public final class LocatorLink: @unchecked Sendable {
    private enum Kind {
        /// An outer `Locator`.
        case outer(Locator)
        /// A link which indicates that we are in measurement mode.
        case measure(Location, Span)
    }

    private let kind: Kind
    private var cached: Resolved?

    private init(_ kind: Kind) { self.kind = kind }

    /// Create a locator link.
    public static func new(_ outer: Locator) -> LocatorLink {
        LocatorLink(.outer(outer))
    }

    /// Creates a link that puts any linked downstream locator into measurement
    /// mode.
    public static func measure(base: Location, span: Span) -> LocatorLink {
        LocatorLink(.measure(base, span))
    }

    /// Resolve the link. The result is cached in this link.
    func resolve() -> Resolved {
        if let cached { return cached }
        let resolved: Resolved
        switch kind {
        case let .outer(outer): resolved = outer.resolve()
        case let .measure(base, span): resolved = .measure(base: base, span: span)
        }
        cached = resolved
        return resolved
    }
}

/// A type that generates unique sublocators.
///
/// Port of `SplitLocator` in `introspection/locator.rs`. A class because it
/// carries mutable disambiguation state through realization.
public final class SplitLocator: @unchecked Sendable {
    /// A local hash that incorporates all layers since the last memoization
    /// boundary.
    let local: Hash128
    /// A pointer to an outer cached locator.
    let outer: LocatorLink?
    /// Simply counts up the number of times we've seen each local hash.
    var disambiguators: [Hash128: Int] = [:]

    init(local: Hash128, outer: LocatorLink?, disambiguators: [Hash128: Int]) {
        self.local = local
        self.outer = outer
        self.disambiguators = disambiguators
    }

    /// Produces a sublocator for a subtree keyed by `key`.
    public func next<K: Hashable>(_ key: K) -> Locator {
        nextInner(hash128(key))
    }

    /// Produces a sublocator for a subtree.
    func nextInner(_ key: Hash128) -> Locator {
        // Produce a locator disambiguator, for elements with the same key
        // within this `SplitLocator`.
        let disambiguator = disambiguators[key, default: 0]
        disambiguators[key] = disambiguator + 1

        // Combine the key, disambiguator and local hash into a sub-local hash.
        let local = hash128(LocatorTripleHash(
            key: key, disambiguator: disambiguator, local: self.local))

        return Locator(local: local, outer: outer)
    }

    /// Produces a unique location for an element.
    public func nextLocation(_ engine: inout Engine, key: Hash128,
                             elemSpan: Span) -> Location {
        switch nextInner(key).resolve() {
        case let .hash(hash):
            return Location(hash: hash)
        case let .measure(base, _):
            // If we aren't able to find a matching element in the document,
            // default to the base location. Introspection-backed measurement
            // resolution lands with the introspection milestone.
            return engine.measureLocation?(key, base, elemSpan) ?? base
        }
    }
}
