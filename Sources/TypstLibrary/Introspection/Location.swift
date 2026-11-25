import Foundation
import TypstSyntax
import TypstUtils

/// A unique location of content in the document. Port of `Location` in
/// `introspection/location.rs`.
///
/// Upstream wraps a `u128` hash; the Swift port uses `Hash128`.
public struct Location: Sendable, Hashable {
    /// The underlying hash.
    public let hash: Hash128

    public init(hash: Hash128) {
        self.hash = hash
    }

    /// A derived location for the `n`-th variant (e.g. disambiguation).
    public func variant(_ n: Int) -> Location {
        var hasher = Hasher()
        hasher.combine(hash)
        hasher.combine(n)
        hasher.combine("typst-location-variant")
        let h1 = UInt64(bitPattern: Int64(hasher.finalize()))
        var hasher2 = Hasher()
        hasher2.combine("typst-location-variant")
        hasher2.combine(hash)
        hasher2.combine(n)
        let h2 = UInt64(bitPattern: Int64(hasher2.finalize()))
        return Location(hash: Hash128(high: h2, low: h1))
    }
}

/// Key for location-keyed lookups. Port of `LocationKey`.
public struct LocationKey: Sendable, Hashable {
    public let hash: Hash128

    public init(location: Location) {
        self.hash = location.hash
    }
}

extension Location: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

extension Location: Repr {
    public func repr() -> String { "location(..)" }
}

extension Location: NativeType {
    public static let typeInfo = TypeInfo(name: "location", longName: "location",
        title: "Location", since: .forever,
        scope: { locationScope() })
}

/// Locations are `#[ty]` values stored as `Value.dynamic`.
extension Location: DynamicValue {}
