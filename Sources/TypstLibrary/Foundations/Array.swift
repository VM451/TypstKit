import Foundation
import TypstSyntax

/// A sequence of values. Port of `Array` in `array.rs`.
///
/// Named `ArrayValue` to avoid colliding with Swift's `Array`.
public struct ArrayValue: Sendable {
    /// The backing storage.
    public var items: [Value]

    public init() {
        items = []
    }

    public init(_ items: [Value]) {
        self.items = items
    }

    public init(items: [Value]) {
        self.items = items
    }

    public static func withCapacity(_ capacity: Int) -> ArrayValue {
        ArrayValue(items: [])
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    public var first: Value? { items.first }
    public var last: Value? { items.last }

    /// Mutable access to the first element (returns index for mutation).
    public mutating func firstMutIndex() -> StrResult<Int> {
        guard !items.isEmpty else {
            return .failure(StrError("array is empty"))
        }
        return .success(0)
    }

    /// Mutable access to the last element (returns index for mutation).
    public mutating func lastMutIndex() -> StrResult<Int> {
        guard !items.isEmpty else {
            return .failure(StrError("array is empty"))
        }
        return .success(items.count - 1)
    }

    /// Resolve an index (negative wraps) and return the element.
    /// Errors when out of bounds.
    public func at(_ index: Int64) -> StrResult<Value> {
        guard let i = locate(index) else {
            return .failure(StrError("array index out of bounds (index: \(index), len: \(items.count))"))
        }
        return .success(items[i])
    }

    /// Resolve an index to a mutable position, or error.
    public mutating func atMutIndex(_ index: Int64) -> StrResult<Int> {
        guard let i = locate(index) else {
            return .failure(StrError("array index out of bounds (index: \(index), len: \(items.count))"))
        }
        return .success(i)
    }

    /// Resolve an index to a 0-based position; `endOK` also accepts `len`.
    func locate(_ index: Int64, endOK: Bool = false) -> Int? {
        var i = index
        if i < 0 { i = Int64(items.count) + i }
        guard i >= 0 else { return nil }
        let limit = items.count + (endOK ? 1 : 0)
        guard let idx = Int(exactly: i), idx < limit else { return nil }
        return idx
    }

    /// Repeat the array `n` times (shallow).
    public func `repeat`(_ n: Int) -> StrResult<ArrayValue> {
        if n < 0 || (n > 0 && items.count > Int.max / n) {
            return .failure(StrError("cannot repeat this array \(n) times"))
        }
        var result: [Value] = []
        result.reserveCapacity(items.count * n)
        for _ in 0..<n { result.append(contentsOf: items) }
        return .success(ArrayValue(items: result))
    }

    public subscript(index: Int) -> Value {
        get { items[index] }
        set { items[index] = newValue }
    }
}

extension ArrayValue: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { items.count }
}

extension ArrayValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Value...) {
        self.init(items: elements)
    }
}

extension ArrayValue: Equatable {
    public static func == (lhs: ArrayValue, rhs: ArrayValue) -> Bool {
        lhs.items == rhs.items
    }
}

extension ArrayValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(items)
    }
}

extension ArrayValue: CustomDebugStringConvertible {
    public var debugDescription: String { "\(items)" }
}

extension ArrayValue: Repr {
    public func repr() -> String {
        canonicalRepr
    }
}

extension ArrayValue {
    /// The canonical repr: `()` for empty, `(a, b)` otherwise,
    /// `(a,)` for a single element.
    public var canonicalRepr: String {
        if items.isEmpty { return "()" }
        let body = items.map { $0.repr() }.joined(separator: ", ")
        return items.count == 1 ? "(\(body),)" : "(\(body))"
    }
}

extension ArrayValue {
    /// `len`
    public var len: Int { items.count }

    /// `first(default:)`
    public func first(default defaultValue: Value? = nil) -> StrResult<Value> {
        if let first { return .success(first) }
        if let defaultValue { return .success(defaultValue) }
        return .failure(StrError("array is empty"))
    }

    /// `last(default:)`
    public func last(default defaultValue: Value? = nil) -> StrResult<Value> {
        if let last { return .success(last) }
        if let defaultValue { return .success(defaultValue) }
        return .failure(StrError("array is empty"))
    }

    /// `push(value)`
    public mutating func push(_ value: Value) {
        items.append(value)
    }

    /// `pop()`
    public mutating func pop() -> StrResult<Value> {
        guard let last = items.popLast() else {
            return .failure(StrError("array is empty"))
        }
        return .success(last)
    }

    /// `insert(index, value)`
    public mutating func insert(_ index: Int64, _ value: Value) -> StrResult<()> {
        // Upstream allows index == len for append-at-end.
        var i = index
        if i < 0 { i = Int64(items.count) + i }
        guard i >= 0, let idx = Int(exactly: i), idx <= items.count else {
            return .failure(StrError("array index out of bounds (index: \(index), len: \(items.count))"))
        }
        items.insert(value, at: idx)
        return .success(())
    }

    /// `remove(index)`
    public mutating func remove(_ index: Int64) -> StrResult<Value> {
        guard let i = locate(index) else {
            return .failure(StrError("array index out of bounds (index: \(index), len: \(items.count))"))
        }
        return .success(items.remove(at: i))
    }

    /// `slice(start, end?, count?)` — indices must be in bounds
    /// (`len` allowed for `end`), matching upstream `locate(.., true)`.
    public func slice(start: Int64, end: Int64? = nil, count: Int64? = nil) -> StrResult<ArrayValue> {
        if end != nil && count != nil {
            return .failure(StrError("`end` and `count` are mutually exclusive"))
        }
        guard let s = locate(start, endOK: true) else {
            return .failure(StrError("array index out of bounds (index: \(start), len: \(items.count))"))
        }
        let endIndex = end ?? count.map { Int64(s) + $0 }
        guard let e0 = locate(endIndex ?? Int64(items.count), endOK: true) else {
            let bad = endIndex ?? Int64(items.count)
            return .failure(StrError("array index out of bounds (index: \(bad), len: \(items.count))"))
        }
        let e = Swift.max(e0, s)
        return .success(ArrayValue(items: Array(items[s..<e])))
    }

    /// `contains(value)`
    public func contains(_ value: Value) -> Bool {
        items.contains { $0 == value }
    }
}

extension ArrayValue {
    /// Concatenate two arrays (upstream `Array + Array`).
    public static func + (lhs: ArrayValue, rhs: ArrayValue) -> ArrayValue {
        ArrayValue(lhs.items + rhs.items)
    }
}
