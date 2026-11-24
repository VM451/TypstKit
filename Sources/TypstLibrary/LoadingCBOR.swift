import Foundation
import TypstSyntax
import TypstUtils

// CBOR loading — port of upstream `loading/cbor.rs` plus a CBOR codec
// matching ciborium's serde data model (major types 0-7, tags rejected,
// recursion-limited).

/// CBOR decode error with a position hint.
struct CborError: Error {
    var message: String
}

/// Decode CBOR bytes into a Typst `Value`.
/// Port of `ciborium::from_reader` + `Deserialize for Value`.
func decodeCBOR(_ bytes: [UInt8]) -> Result<Value, CborError> {
    var decoder = CborDecoder(bytes: bytes)
    do {
        let value = try decoder.decodeValue(depth: 0)
        guard decoder.pos == bytes.count else {
            return .failure(CborError(message: "trailing bytes after CBOR value"))
        }
        return .success(value)
    } catch let e as CborError {
        return .failure(e)
    } catch {
        return .failure(CborError(message: "syntax error"))
    }
}

struct CborDecoder {
    let bytes: [UInt8]
    var pos = 0
    static let maxDepth = 128

    mutating func byte() throws -> UInt8 {
        guard pos < bytes.count else { throw CborError(message: "unexpected end of input") }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard pos + n <= bytes.count else {
            throw CborError(message: "unexpected end of input")
        }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }

    /// Read the initial byte: returns (majorType, additionalInfo).
    mutating func head() throws -> (UInt8, UInt64) {
        let b = try byte()
        let major = b >> 5
        let info = UInt64(b & 0x1F)
        return (major, info)
    }

    /// Convert a decoded length to Int, bounding by remaining input.
    func boundedLength(len: UInt64) throws -> Int {
        guard len <= UInt64(bytes.count - pos), len <= UInt64(Int.max) else {
            throw CborError(message: "length exceeds input")
        }
        return Int(len)
    }

    /// Read an unsigned argument from additional info.
    mutating func argument(_ info: UInt64) throws -> UInt64 {
        switch info {
        case 0...23: return info
        case 24: return UInt64(try byte())
        case 25: return UInt64(try take(2).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        })
        case 26: return UInt64(try take(4).withUnsafeBytes {
            UInt64($0.load(as: UInt32.self).bigEndian)
        })
        case 27: return try take(8).withUnsafeBytes {
            $0.load(as: UInt64.self).bigEndian
        }
        default:
            throw CborError(message: "reserved additional information")
        }
    }

    mutating func decodeValue(depth: Int) throws -> Value {
        guard depth <= Self.maxDepth else {
            throw CborError(message: "recursion limit exceeded")
        }
        let (major, info) = try head()
        switch major {
        case 0: // unsigned int
            let n = try argument(info)
            if n <= UInt64(Int64.max) { return .int(Int64(n)) }
            return .float(Double(n))
        case 1: // negative int: -1 - n
            let n = try argument(info)
            if n <= UInt64(Int64.max) { return .int(-1 - Int64(n)) }
            return .float(-1.0 - Double(n))
        case 2: // byte string
            let len = try argument(info)
            return .bytes(Bytes(try take(boundedLength(len: len))))
        case 3: // text string
            let len = try argument(info)
            let data = try take(boundedLength(len: len))
            guard let s = String(bytes: data, encoding: .utf8) else {
                throw CborError(message: "invalid UTF-8 in text string")
            }
            return .str(Str(s))
        case 4: // array
            let len = try argument(info)
            var items: [Value] = []
            items.reserveCapacity(Int(min(len, 1_000_000)))
            for _ in 0..<len {
                items.append(try decodeValue(depth: depth + 1))
            }
            return .array(ArrayValue(items: items))
        case 5: // map
            let len = try argument(info)
            var dict = Dict()
            for _ in 0..<len {
                let key = try decodeValue(depth: depth + 1)
                let value = try decodeValue(depth: depth + 1)
                guard case .str(let k) = key else {
                    throw CborError(message: "map key must be a string")
                }
                dict.insert(k.value, value)
            }
            // TOML datetime sentinel (upstream `Datetime::from_toml_dict`
            // runs for every map decode).
            if let dt = Datetime.fromTomlDict(dict) {
                return .datetime(dt)
            }
            return .dict(dict)
        case 6: // tag — unsupported
            _ = try argument(info)
            throw CborError(message: "tags are not supported")
        case 7: // simple/float — additional info per RFC 8949 §3.3
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22, 23: return .none // null / undefined
            case 24: // simple value in next byte
                _ = try byte()
                return .none
            case 25: // float16
                let bits = try take(2).withUnsafeBytes {
                    $0.load(as: UInt16.self).bigEndian
                }
                return .float(halfToDouble(bits))
            case 26: // float32
                let bits = try take(4).withUnsafeBytes {
                    $0.load(as: UInt32.self).bigEndian
                }
                return .float(Double(Float(bitPattern: bits)))
            case 27: // float64
                let bits = try take(8).withUnsafeBytes {
                    $0.load(as: UInt64.self).bigEndian
                }
                return .float(Double(bitPattern: bits))
            case 31: // break — only valid inside indefinite containers
                throw CborError(message: "unexpected break")
            default: // 0-19 unassigned simple, 28-30 unassigned
                throw CborError(message: "reserved simple value")
            }
        default:
            throw CborError(message: "syntax error")
        }
    }
}

/// IEEE 754 half-precision → Double.
func halfToDouble(_ bits: UInt16) -> Double {
    let sign = (bits & 0x8000) != 0 ? -1.0 : 1.0
    let exp = Int((bits >> 10) & 0x1F)
    let frac = Double(bits & 0x03FF)
    if exp == 0 {
        return sign * frac * pow(2.0, -24.0) // subnormal
    }
    if exp == 31 {
        return frac == 0 ? sign * .infinity : .nan
    }
    return sign * (1.0 + frac / 1024.0) * pow(2.0, Double(exp - 15))
}

/// Encode a `Value` as CBOR bytes.
/// Port of `ciborium::into_writer(&value)` via `Serialize for Value`.
func encodeCBOR(_ value: Value) -> [UInt8] {
    var out: [UInt8] = []
    writeCBOR(&out, value)
    return out
}

func writeCBORHead(_ out: inout [UInt8], major: UInt8, arg: UInt64) {
    if arg < 24 {
        out.append((major << 5) | UInt8(arg))
    } else if arg <= 0xFF {
        out.append((major << 5) | 24)
        out.append(UInt8(arg))
    } else if arg <= 0xFFFF {
        out.append((major << 5) | 25)
        out.append(UInt8(arg >> 8))
        out.append(UInt8(arg & 0xFF))
    } else if arg <= 0xFFFF_FFFF {
        out.append((major << 5) | 26)
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8((arg >> UInt64(shift)) & 0xFF))
        }
    } else {
        out.append((major << 5) | 27)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((arg >> UInt64(shift)) & 0xFF))
        }
    }
}

func writeCBOR(_ out: inout [UInt8], _ value: Value) {
    switch value {
    case .none:
        out.append(0xF6) // null
    case .bool(let b):
        out.append(b ? 0xF5 : 0xF4)
    case .int(let i):
        if i >= 0 {
            writeCBORHead(&out, major: 0, arg: UInt64(i))
        } else {
            // -1 - n representation.
            writeCBORHead(&out, major: 1, arg: UInt64(-1 - i))
        }
    case .float(let f):
        out.append(0xFB) // float64
        out.append(contentsOf: f.bitPattern.bigEndianBytes)
    case .str(let s):
        let data = Array(s.value.utf8)
        writeCBORHead(&out, major: 3, arg: UInt64(data.count))
        out.append(contentsOf: data)
    case .bytes(let b):
        writeCBORHead(&out, major: 2, arg: UInt64(b.storage.count))
        out.append(contentsOf: b.storage)
    case .symbol(let s):
        let data = Array(s.get.utf8)
        writeCBORHead(&out, major: 3, arg: UInt64(data.count))
        out.append(contentsOf: data)
    case .array(let a):
        writeCBORHead(&out, major: 4, arg: UInt64(a.items.count))
        for item in a.items { writeCBOR(&out, item) }
    case .dict(let d):
        writeCBORHead(&out, major: 5, arg: UInt64(d.count))
        for (k, v) in d {
            writeCBORHead(&out, major: 3, arg: UInt64(k.value.utf8.count))
            out.append(contentsOf: k.value.utf8)
            writeCBOR(&out, v)
        }
    case .content(let c):
        // Map describing the content (same shape as JSON).
        var pairs: [(String, Value)] = [("func", .str(Str(c.elem.name)))]
        for (k, v) in c.fields() { pairs.append((k.value, v)) }
        writeCBORHead(&out, major: 5, arg: UInt64(pairs.count))
        for (k, v) in pairs {
            writeCBORHead(&out, major: 3, arg: UInt64(k.utf8.count))
            out.append(contentsOf: k.utf8)
            writeCBOR(&out, v)
        }
    default:
        // Other types serialize as text via repr().
        let data = Array(value.repr().utf8)
        writeCBORHead(&out, major: 3, arg: UInt64(data.count))
        out.append(contentsOf: data)
    }
}

extension FixedWidthInteger {
    /// Big-endian byte representation.
    var bigEndianBytes: [UInt8] {
        var v = self.bigEndian
        return withUnsafeBytes(of: &v) { Array($0) }
    }
}

/// `cbor(source)` — port of upstream `cbor`.
let cborFunc = nativeFunc(
    "cbor",
    title: "CBOR",
    since: .version([0, 8, 0]),
    docs: "Reads structured data from a CBOR file.",
    params: [
        NativeParamInfo(name: "source", input: DataSource.input, required: true),
    ],
    returns: Value.output,
    scope: {
        let scope = Scope()
        scope.defineFunc(cborEncode)
        return scope
    }
) { engine, _, args in
    let source: Spanned<DataSource, Span> = try args.expectT("source")
    try args.finishT()
    let loaded = try load(source, engine.world)
    switch decodeCBOR(loaded.data.storage) {
    case .success(let v): return v
    case .failure(let e):
        throw SourceDiagnostics([LoadError.binary(
            "failed to parse CBOR", e.message).within(loaded)])
    }
}

/// `cbor.encode(value)` — port of upstream `cbor.encode`.
let cborEncode = nativeFunc(
    "encode",
    title: "Encode CBOR",
    since: .version([0, 8, 0]),
    docs: "Encodes structured data into CBOR bytes.",
    params: [
        NativeParamInfo(name: "value", input: Value.input, required: true),
    ],
    returns: Bytes.output
) { _, _, args in
    let value: Spanned<Value, Span> = try args.expectT("value")
    try args.finishT()
    return Bytes(encodeCBOR(value.value))
}
