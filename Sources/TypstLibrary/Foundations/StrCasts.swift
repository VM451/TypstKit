import Foundation
import TypstUtils

// Cast conformances for the `str` module helper types — the Swift
// equivalent of the `cast!` blocks in upstream `str.rs`.

// MARK: - Optional values

/// `Option<T>` casts: `none` casts to `nil`, everything else delegates.
extension Optional: Castable, IntoValue, FromValue
    where Wrapped: Castable & IntoValue & FromValue {

    public static var input: CastInfo { .union([NoneValue.input, Wrapped.input]) }
    public static var output: CastInfo { .union([NoneValue.output, Wrapped.output]) }

    public static func castable(_ value: Value) -> Bool {
        if case .none = value { return true }
        return Wrapped.castable(value)
    }

    public static func error(_ found: Value) -> HintedString {
        Wrapped.error(found)
    }

    public func intoValue() -> Value {
        switch self {
        case .none: return .none
        case .some(let v): return v.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if case .none = value { return .success(nil) }
        return Wrapped.fromValue(value).map { $0 as Self }
    }
}

// MARK: - char (single Unicode scalar)

extension Unicode.Scalar: Castable, IntoValue, FromValue {
    /// Typst `char` — a single Unicode scalar value.
    public static var input: CastInfo { Str.input }
    public static var output: CastInfo { Str.output }

    public static func castable(_ value: Value) -> Bool {
        guard case .str(let s) = value else { return false }
        return s.value.unicodeScalars.count == 1
    }

    public static func error(_ found: Value) -> HintedString {
        HintedString("expected exactly one character")
    }

    public func intoValue() -> Value { .str(Str(String(self))) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .str(let s) = value else {
            return .failure(HintedString(
                "expected string, found \(value.type)"))
        }
        guard s.value.unicodeScalars.count == 1,
              let first = s.value.unicodeScalars.first else {
            return .failure(HintedString("expected exactly one character"))
        }
        return .success(first)
    }
}

// MARK: - UInt32 (upstream `u32` casts)

extension UInt32: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { intCastable(value) }
    public func intoValue() -> Value { .int(Int64(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        // Upstream `unsigned_int!` (u32): range errors in `from_value`.
        guard case let .int(v) = value else { return .failure(error(value)) }
        guard v >= 0 else {
            return .failure(HintedString("number must be at least zero"))
        }
        guard let u = UInt32(exactly: v) else {
            return .failure(HintedString("number too large"))
        }
        return .success(u)
    }
}

// MARK: - Regex (stored as a dynamic value, like upstream `Value::Dyn`)

extension Regex: DynamicValue {}

// MARK: - StrPattern

extension StrPattern: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .union([Str.input, Regex.input]) }
    public static var output: CastInfo { .union([Str.output, Regex.output]) }

    public static func castable(_ value: Value) -> Bool {
        Str.castable(value) || Regex.castable(value)
    }

    public static func error(_ found: Value) -> HintedString {
        input.error(found)
    }

    public func intoValue() -> Value {
        switch self {
        case .str(let s): return s.intoValue()
        case .regex(let r): return r.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Str.castable(value) {
            return Str.fromValue(value).map { .str($0) }
        }
        if Regex.castable(value) {
            return Regex.fromValue(value).map { .regex($0) }
        }
        return .failure(error(value))
    }
}

// MARK: - StrSide

extension StrSide: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Alignment.self)) }
    public static var output: CastInfo { .type(Type.of(Alignment.self)) }

    public static func castable(_ value: Value) -> Bool {
        Alignment.castable(value)
    }

    public static func error(_ found: Value) -> HintedString {
        input.error(found)
    }

    public func intoValue() -> Value {
        switch self {
        case .start: return Alignment.start.intoValue()
        case .end: return Alignment.end.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch Alignment.fromValue(value) {
        case .success(let alignment):
            if alignment == .start { return .success(.start) }
            if alignment == .end { return .success(.end) }
            return .failure(HintedString("expected either `start` or `end`"))
        case .failure(let error):
            return .failure(error)
        }
    }
}

// MARK: - Replacement

extension Replacement: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .union([Str.input, Func.input]) }
    public static var output: CastInfo { .union([Str.output, Func.output]) }

    public static func castable(_ value: Value) -> Bool {
        Str.castable(value) || Func.castable(value)
    }

    public static func error(_ found: Value) -> HintedString {
        input.error(found)
    }

    public func intoValue() -> Value {
        switch self {
        case .str(let s): return s.intoValue()
        case .function(let f): return f.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Str.castable(value) {
            return Str.fromValue(value).map { .str($0) }
        }
        if Func.castable(value) {
            return Func.fromValue(value).map { .function($0) }
        }
        return .failure(error(value))
    }
}

// MARK: - UnicodeNormalForm

extension UnicodeNormalForm: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { .type(Type.of(Str.self)) }

    public static func castable(_ value: Value) -> Bool {
        guard case .str(let s) = value else { return false }
        return UnicodeNormalForm(rawValue: s.value) != nil
    }

    public static func error(_ found: Value) -> HintedString {
        HintedString("expected \"nfc\", \"nfd\", \"nfkc\", or \"nfkd\"")
    }

    public func intoValue() -> Value { .str(Str(rawValue)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .str(let s) = value,
              let form = UnicodeNormalForm(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(form)
    }
}

// MARK: - ToStr (the `str()` constructor's value parameter)

extension ToStr: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([Str.input, Int64.input, Double.input, Decimal.input,
                Version.input, Bytes.input, Label.input, Type.input])
    }
    public static var output: CastInfo { .any }

    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .str, .int, .float, .decimal, .version, .bytes, .label, .type:
            return true
        default:
            return false
        }
    }

    public static func error(_ found: Value) -> HintedString {
        input.error(found)
    }

    public func intoValue() -> Value {
        switch self {
        case .str(let s): return s.intoValue()
        case .int(let i): return i.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .str(let s): return .success(.str(s))
        case .int(let i): return .success(.int(i))
        case .float(let f): return .success(.str(Str(displayFloat(f))))
        case .decimal(let d): return .success(.str(Str(d.repr())))
        case .version(let v): return .success(.str(Str(v.description)))
        case .bytes(let b):
            switch b.toStr() {
            case .success(let s): return .success(.str(s))
            case .failure: return .failure(HintedString("bytes are not valid UTF-8"))
            }
        case .label(let l): return .success(.str(Str(l.resolved)))
        case .type(let t): return .success(.str(Str(t.longName)))
        default:
            return .failure(error(value))
        }
    }
}

// MARK: - Base (integer stringification radix)

extension Base: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Int64.input }
    public static var output: CastInfo { Int64.output }

    public static func castable(_ value: Value) -> Bool {
        if case .int = value { return true }
        return false
    }

    public static func error(_ found: Value) -> HintedString {
        input.error(found)
    }

    public func intoValue() -> Value { .int(value) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .int(let v) = value else {
            return .failure(error(value))
        }
        return .success(.user(v))
    }
}
