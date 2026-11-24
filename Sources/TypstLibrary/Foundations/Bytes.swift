import Foundation

/// A sequence of bytes.
///
/// Port of `Bytes` in `bytes.rs`.
public struct Bytes: Sendable, Hashable {
    /// The underlying byte storage.
    public var storage: [UInt8]

    public init() { storage = [] }

    /// Create bytes from any collection of bytes.
    public init<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        storage = Array(bytes)
    }

    public init(_ bytes: [UInt8]) { storage = bytes }

    /// Create bytes from a string's UTF-8 encoding.
    public init(string: String) { storage = Array(string.utf8) }

    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }
    public var len: Int { storage.count }

    /// The bytes as a slice.
    public var slice: [UInt8] { storage }

    /// Interpret as UTF-8 string.
    public func toStr() -> StrResult<Str> {
        guard let s = String(bytes: storage, encoding: .utf8) else {
            return .failure(StrError("byte sequence is not valid UTF-8"))
        }
        return .success(Str(s))
    }

    /// The byte at `index`, or an error.
    public func at(_ index: Int) -> StrResult<UInt8> {
        var i = index
        if i < 0 { i += storage.count }
        guard i >= 0, i < storage.count else {
            return .failure(StrError("byte index out of bounds (index: \(index), len: \(storage.count))"))
        }
        return .success(storage[i])
    }

    /// A sub-slice by byte range (clamped).
    public func sliceRange(_ range: Range<Int>) -> Bytes {
        let lo = Swift.max(0, Swift.min(range.lowerBound, storage.count))
        let hi = Swift.max(lo, Swift.min(range.upperBound, storage.count))
        return Bytes(Array(storage[lo..<hi]))
    }

    public func contains(_ byte: UInt8) -> Bool { storage.contains(byte) }
}

extension Bytes: CustomDebugStringConvertible {
    public var debugDescription: String { "Bytes(\(storage.count))" }
}

extension Bytes: Repr {
    public func repr() -> String { "bytes(\(storage.count))" }
}
