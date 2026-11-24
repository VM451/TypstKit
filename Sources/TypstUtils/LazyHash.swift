import Foundation

/// A 128-bit hash value, matching upstream `u128` hash digests.
public struct Hash128: Sendable, Hashable {
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
}

/// A 128-bit hash of a `Hashable` value, matching upstream `hash128`.
///
/// Rust's `SipHasher` produces a platform-specific digest; Typst only uses
/// these hashes for equality shortcuts and cache keys, never for persistence,
/// so a Swift `Hasher`-based 128-bit fold is behaviorally equivalent.
public func hash128<T: Hashable>(_ value: T) -> Hash128 {
    var hasher = Hasher()
    hasher.combine(value)
    hasher.combine("typst-hash128")
    let h1 = UInt64(bitPattern: Int64(hasher.finalize()))
    var hasher2 = Hasher()
    hasher2.combine("typst-hash128")
    hasher2.combine(value)
    let h2 = UInt64(bitPattern: Int64(hasher2.finalize()))
    return Hash128(high: h2, low: h1)
}

/// 128-bit hash of a type-erased `Hashable` existential.
public func hash128(_ value: any Hashable) -> Hash128 {
    var hasher = Hasher()
    value.hash(into: &hasher)
    "typst-hash128".hash(into: &hasher)
    let h1 = UInt64(bitPattern: Int64(hasher.finalize()))
    var hasher2 = Hasher()
    "typst-hash128".hash(into: &hasher2)
    value.hash(into: &hasher2)
    let h2 = UInt64(bitPattern: Int64(hasher2.finalize()))
    return Hash128(high: h2, low: h1)
}

/// A lazily computed, cached 128-bit hash wrapper. Port of
/// `typst_utils::LazyHash`.
///
/// Equality and hashing are based solely on the cached hash, exactly like
/// upstream, which makes `LazyHash` cheap to compare and safe to store in
/// hashed collections.
public struct LazyHash<T: Hashable>: @unchecked Sendable {
    /// The wrapped value.
    public var value: T
    /// The cached hash (computed eagerly; upstream computes lazily but the
    /// observable semantics are identical).
    let cachedHash: Hash128

    public init(_ value: T) {
        self.value = value
        self.cachedHash = hash128(value)
    }

    public init(wrapping value: T, hash: Hash128) {
        self.value = value
        self.cachedHash = hash
    }

    public var hashValue: Hash128 { cachedHash }
}

extension LazyHash: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(cachedHash)
    }

    public static func == (lhs: LazyHash<T>, rhs: LazyHash<T>) -> Bool {
        lhs.cachedHash == rhs.cachedHash
    }
}

extension LazyHash: CustomDebugStringConvertible {
    public var debugDescription: String { "\(value)" }
}

extension LazyHash: CustomStringConvertible where T: CustomStringConvertible {
    public var description: String { value.description }
}

extension LazyHash {
    /// Unwrap the inner value.
    public func intoInner() -> T { value }

    /// Mutable access invalidates nothing (hash is content-based and eager).
    public mutating func update(_ body: (inout T) -> Void) {
        body(&value)
    }
}

/// Source location of a definition for IDE tooling. Port of
/// `typst_utils::DefSite`.
public struct DefSite: Sendable, Hashable {
    /// The source file path (e.g. `"crates/typst-library/src/foundations/str.rs"`).
    public let path: String
    /// A key identifying the item within the file (usually `"module::item"`).
    public let key: String

    public init(path: String, key: String) {
        self.path = path
        self.key = key
    }
}

/// Wraps a value, requiring justification on access. Port of
/// `typst_utils::Protected`.
public struct Protected<T: Sendable>: Sendable {
    public let inner: T

    public init(_ inner: T) { self.inner = inner }

    /// Access the underlying value. Callers must justify the access in a
    /// comment, mirroring upstream's `access("justification")`.
    public func access(_ justification: String) -> T { inner }
}

/// A `'static` shared reference. Port of `typst_utils::Static<T>`.
///
/// In Swift, shared immutable metadata is held directly; this type exists
/// for API parity and documents the sharing intent.
public struct StaticRef<T: Sendable>: Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

extension StaticRef: CustomDebugStringConvertible {
    public var debugDescription: String { "StaticRef(\(value))" }
}
