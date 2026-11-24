import Foundation
import TypstSyntax

/// An insertion-ordered map from strings to values. Port of `Dict` in
/// `dict.rs` (upstream uses `IndexMap`; the Swift port stores parallel
/// key/value arrays plus a lookup index with identical semantics:
/// `insert` replaces in place, removal preserves order).
public struct Dict: Sendable {
    /// Ordered keys.
    public private(set) var keys: [Str]
    /// Values parallel to `keys`.
    public private(set) var values: [Value]
    /// Lookup from key string to position.
    var index: [String: Int]

    public init() {
        keys = []
        values = []
        index = [:]
    }

    public init(_ pairs: [(String, Value)]) {
        self.init()
        for (key, value) in pairs {
            insert(key, value)
        }
    }

    public init(_ pairs: [(Str, Value)]) {
        self.init()
        for (key, value) in pairs {
            insert(key, value)
        }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    /// Whether the dictionary contains `key`.
    public func contains(_ key: String) -> Bool {
        index[key] != nil
    }

    /// Get a value by key.
    public func get(_ key: String) -> Value? {
        index[key].map { values[$0] }
    }

    /// Get a value, or error `missing_key`.
    public func at(_ key: String) -> StrResult<Value> {
        if let value = get(key) { return .success(value) }
        return .failure(StrError("dictionary does not contain key \(Str(key).repr())"))
    }

    /// Insert or replace a value (position preserved on replace,
    /// matching `IndexMap::insert`).
    @discardableResult
    public mutating func insert(_ key: String, _ value: Value) -> Value? {
        insert(Str(key), value)
    }

    /// Insert or replace with a `Str` key.
    @discardableResult
    public mutating func insert(_ key: Str, _ value: Value) -> Value? {
        if let i = index[key.value] {
            let old = values[i]
            values[i] = value
            return old
        }
        index[key.value] = keys.count
        keys.append(key)
        values.append(value)
        return nil
    }

    /// Remove a key, preserving order of remaining entries.
    @discardableResult
    public mutating func remove(_ key: String) -> Value? {
        remove(Str(key))
    }

    /// Remove with a `Str` key.
    @discardableResult
    public mutating func remove(_ key: Str) -> Value? {
        guard let i = index.removeValue(forKey: key.value) else { return nil }
        // Rebuild index for shifted positions.
        keys.remove(at: i)
        let removed = values.remove(at: i)
        for j in i..<keys.count {
            index[keys[j].value] = j
        }
        return removed
    }

    /// Remove a key or return the default/error.
    public mutating func take(_ key: String, default defaultValue: Value? = nil) -> StrResult<Value> {
        if let value = remove(key) { return .success(value) }
        if let defaultValue { return .success(defaultValue) }
        return .failure(StrError("dictionary does not contain key \(Str(key).repr())"))
    }

    /// Remove or error.
    public mutating func remove(_ key: Str, default defaultValue: Value? = nil) -> StrResult<Value> {
        take(key.value, default: defaultValue)
    }

    /// Position of a key, for mutable access.
    public func position(of key: String) -> Int? {
        index[key]
    }

    /// Mutate a value in place.
    public mutating func update(_ key: String, _ body: (inout Value) -> Void) {
        guard let i = index[key] else { return }
        body(&values[i])
    }

    /// All key/value pairs in order.
    public var pairs: [(key: Str, value: Value)] {
        zip(keys, values).map { ($0, $1) }
    }

    /// `keys()` → array of key strings.
    public var keyArray: ArrayValue {
        ArrayValue(items: keys.map { .str($0) })
    }

    /// `values()` → array of values.
    public var valueArray: ArrayValue {
        ArrayValue(items: values)
    }

    /// `pairs()` → array of `(key, value)` arrays.
    public var pairArray: ArrayValue {
        ArrayValue(items: pairs.map { pair in
            .array(ArrayValue(items: [.str(pair.key), pair.value]))
        })
    }

    /// `at(key, default:)`.
    public func at(_ key: Str, default defaultValue: Value? = nil) -> StrResult<Value> {
        if let value = get(key.value) { return .success(value) }
        if let defaultValue { return .success(defaultValue) }
        return .failure(StrError("no value for key \(key.repr()) and no default value was specified"))
    }

    /// `insert(key, value)` — the `#[func]` signature.
    public mutating func insertFunc(_ key: Str, _ value: Value) {
        insert(key, value)
    }

    /// Check for unexpected keys after argument consumption.
    public func finish(expected: [String]) -> StrResult<()> {
        if keys.isEmpty { return .success(()) }
        return .failure(StrError(Self.unexpectedKeys(
            Array(keys.map(\.value)), expected: expected.isEmpty ? nil : expected
        )))
    }

    /// Format the "unexpected keys" error.
    public static func unexpectedKeys(_ unexpected: [String], expected: [String]?) -> String {
        func formatAsList(_ arr: [String]) -> String {
            reprSeparatedList(arr.map { "\"\($0)\"" }, last: "and")
        }
        var msg = unexpected.count == 1 ? "unexpected key " : "unexpected keys "
        msg += formatAsList(unexpected)
        if let expected {
            msg += ", valid keys are " + formatAsList(expected)
        }
        return msg
    }
}

extension Dict: Equatable {
    /// Dictionaries compare as maps (order-insensitive), matching
    /// `IndexMap`'s `PartialEq`.
    public static func == (lhs: Dict, rhs: Dict) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, value) in lhs.pairs {
            guard let other = rhs.get(key.value), other == value else { return false }
        }
        return true
    }
}

extension Dict: Hashable {
    /// Order-insensitive hash consistent with `==`.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for (key, value) in pairs.sorted(by: { $0.key.value < $1.key.value }) {
            hasher.combine(key)
            hasher.combine(value)
        }
    }
}

extension Dict: CustomDebugStringConvertible {
    public var debugDescription: String { "\(pairs)" }
}

extension Dict: Repr {
    public func repr() -> String {
        if keys.isEmpty { return "(:)" }
        let body = pairs.map { "\($0.key.repr()): \($0.value.repr())" }
            .joined(separator: ", ")
        return "(\(body))"
    }
}

extension Dict: Sequence {
    public struct Iterator: IteratorProtocol {
        var index = 0
        let pairs: [(key: Str, value: Value)]

        public mutating func next() -> (key: Str, value: Value)? {
            guard index < pairs.count else { return nil }
            defer { index += 1 }
            return pairs[index]
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(pairs: pairs)
    }
}

extension Dict {
    /// Merge two dictionaries (upstream `Dict + Dict`): `rhs` entries
    /// overwrite `lhs` entries with the same key; existing keys keep
    /// their position, new keys append.
    public func merged(with rhs: Dict) -> Dict {
        var result = self
        for (key, value) in rhs.pairs {
            result.insert(key, value)
        }
        return result
    }

    /// Concatenate two dictionaries.
    public static func + (lhs: Dict, rhs: Dict) -> Dict {
        lhs.merged(with: rhs)
    }
}
