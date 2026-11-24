import Foundation
import TypstSyntax
import TypstUtils

// Cast types shared by the collection type scopes — ports of the
// parameter-only `cast!` types in upstream `array.rs` and `bytes.rs`,
// plus the `NonZero*` casts from `int.rs`.

// MARK: - ToArray (upstream `ToArray` in array.rs)

/// A value that can be cast to an array: arrays pass through, bytes
/// become one integer per byte, and versions become their components.
struct ToArray: Sendable {
    var array: ArrayValue
}

extension ToArray: Castable, FromValue {
    public static var input: CastInfo {
        .union([
            ArrayValue.input,
            Bytes.input,
            Version.input,
        ])
    }
    public static var output: CastInfo { ArrayValue.output }

    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .array, .bytes, .version: return true
        default: return false
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .array(array):
            return .success(ToArray(array: array))
        case let .bytes(bytes):
            return .success(ToArray(array: ArrayValue(
                items: bytes.storage.map { .int(Int64($0)) })))
        case let .version(version):
            return .success(ToArray(array: ArrayValue(
                items: version.components.map { .int(Int64($0)) })))
        default:
            return .failure(error(value))
        }
    }
}

// MARK: - ToBytes (upstream `ToBytes` in bytes.rs)

/// A value that can be cast to bytes: strings encode as UTF-8, arrays of
/// integers in `0...255` map directly, bytes pass through.
struct ToBytes: Sendable {
    var bytes: Bytes
}

extension ToBytes: Castable, FromValue {
    public static var input: CastInfo {
        .union([Str.input, ArrayValue.input, Bytes.input])
    }
    public static var output: CastInfo { Bytes.output }

    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .str, .array, .bytes: return true
        default: return false
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .str(string):
            return .success(ToBytes(bytes: Bytes(string: string.value)))
        case let .bytes(bytes):
            return .success(ToBytes(bytes: bytes))
        case let .array(array):
            var out: [UInt8] = []
            out.reserveCapacity(array.items.count)
            for item in array.items {
                guard case let .int(byte) = item else {
                    return .failure(error(item))
                }
                guard (0...255).contains(byte) else {
                    return .failure(HintedString(
                        "number must be between 0 and 255"))
                }
                out.append(UInt8(byte))
            }
            return .success(ToBytes(bytes: Bytes(out)))
        default:
            return .failure(error(value))
        }
    }
}

// MARK: - NonZeroI64 (upstream `cast! { NonZeroI64, .. }` in int.rs)

/// A non-zero `i64` — parameter-only type for `range(step:)`.
struct NonZeroI64: Sendable, Hashable {
    var value: Int64
}

extension NonZeroI64: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { intCastable(value) }

    public func intoValue() -> Value { .int(value) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .int(v) = value else { return .failure(error(value)) }
        guard v != 0 else {
            return .failure(HintedString("number must not be zero"))
        }
        return .success(NonZeroI64(value: v))
    }
}

// MARK: - NonZeroUsize (upstream `cast! { NonZeroUsize, .. }` in int.rs)

/// A positive `usize` — parameter-only type for `chunks`/`windows`.
public struct NonZeroUsize: Sendable, Hashable {
    public var value: Int

    public init(value: Int) { self.value = value }
}

extension NonZeroUsize: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { intCastable(value) }

    public func intoValue() -> Value { .int(Int64(value)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .int(v) = value else { return .failure(error(value)) }
        guard v > 0 else {
            return .failure(HintedString("number must be positive"))
        }
        guard let size = Int(exactly: v) else {
            return .failure(HintedString("number too large"))
        }
        return .success(NonZeroUsize(value: size))
    }
}


// MARK: - NonZeroU32 (upstream `cast! { NonZeroU32, .. }` in int.rs)

/// A positive `u32`.
public struct NonZeroU32: Sendable, Hashable {
    public var value: UInt32

    public init(value: UInt32) { self.value = value }
}

extension NonZeroU32: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { intCastable(value) }

    public func intoValue() -> Value { .int(Int64(value)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .int(v) = value, v > 0, v <= Int64(UInt32.max) else {
            return .failure(HintedString("number must be a positive 32-bit integer"))
        }
        return .success(NonZeroU32(value: UInt32(v)))
    }
}

// MARK: - Endianness (upstream `#[derive(Cast)] enum Endianness` in int.rs)

/// Byte order for integer/float byte conversions.
enum Endianness: String, Sendable, Hashable, CaseIterable {
    case big
    case little
}

extension Endianness: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([.value(.str("big"), doc: "big-endian"),
                .value(.str("little"), doc: "little-endian")])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return Endianness(rawValue: s.value) != nil
    }

    public func intoValue() -> Value { .str(Str(rawValue)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value,
              let endian = Endianness(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(endian)
    }
}
