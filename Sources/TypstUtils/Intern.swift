import Foundation

/// A process-wide string interner, the Swift counterpart of typst-utils'
/// `Interned`/`EcoString` interning used pervasively for identifiers,
/// field names, and symbol names.
///
/// Interned strings are cheap to copy (a `UInt64` handle), compare, and
/// hash, and guarantee pointer-free `Sendable` values.
public struct InternedString: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Index into the global table; 0 is never valid.
    public let raw: UInt64

    init(raw: UInt64) {
        self.raw = raw
    }

    /// The interned string.
    public var value: String { InternPool.shared.string(for: raw) }

    public var description: String { value }

    public static func == (a: InternedString, b: InternedString) -> Bool {
        a.raw == b.raw
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(raw)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = InternedString.intern(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension InternedString {
    /// Intern `string`, returning the canonical handle.
    public static func intern(_ string: String) -> InternedString {
        InternPool.shared.intern(string)
    }

    /// Expressible-by-string-literal convenience for tests and constants.
    public init(stringLiteral value: String) {
        self = InternedString.intern(value)
    }
}

extension InternedString: ExpressibleByStringLiteral {}

/// The backing store for `InternedString`. A lock-guarded table is used
/// rather than an actor so that interning stays synchronous on hot paths;
/// the critical section is a dictionary lookup.
final class InternPool: @unchecked Sendable {
    static let shared = InternPool()

    private let lock = NSLock()
    private var table: [String: UInt64] = [:]
    private var values: [String] = []

    private init() {}

    func intern(_ string: String) -> InternedString {
        lock.lock()
        defer { lock.unlock() }
        if let existing = table[string] {
            return InternedString(raw: existing)
        }
        let raw = UInt64(values.count + 1)
        table[string] = raw
        values.append(string)
        return InternedString(raw: raw)
    }

    func string(for raw: UInt64) -> String {
        guard raw > 0 else { return "" }
        lock.lock()
        defer { lock.unlock() }
        let index = Int(raw) - 1
        return index < values.count ? values[index] : ""
    }
}
