import Foundation
import TypstSyntax
import TypstUtils

// Data-loading functions — port of upstream `loading/{read,json,csv}.rs`.
// yaml/toml/cbor/xml deferred pending parser ports.

// MARK: - read

/// `read(path, encoding:)` — port of upstream `read`.
let readFunc = nativeFunc(
    "read",
    since: .forever,
    docs: """
        Reads plain text or data from a file.

        By default, the file will be read as UTF-8 and returned as a \
        string. If you specify `{encoding: none}`, this returns raw bytes \
        instead.
        """,
    params: [
        NativeParamInfo(name: "path", input: PathOrStr.input, required: true),
        NativeParamInfo(
            name: "encoding",
            input: Optional<Encoding>.input,
            defaultValue: { Encoding.utf8.intoValue() },
            positional: false,
            named: true),
    ],
    returns: Readable.output
) { engine, _, args in
    let path: Spanned<PathOrStr, Span> = try args.expectT("path")
    let encodingValue: Value? = try args.namedT("encoding")
    try args.finishT()

    // Upstream: `Option<Encoding>` — absent defaults to utf8, explicit
    // `none` returns raw bytes.
    let encoding: Encoding? = try {
        guard let v = encodingValue else { return .utf8 }
        if case .none = v { return nil }
        return try unwrap(Optional<Encoding>.fromValue(v))
    }()

    let source = Spanned(DataSource.path(path.value), span: path.span)
    let loaded = try load(source, engine.world)
    guard encoding != nil else { return Readable.bytes(loaded.data) }
    return Readable.str(try loadedToStr(loaded))
}

/// File encoding for `read`. Port of upstream's `Encoding` cast enum
/// (`#[derive(Cast)]` — casts as the `"utf8"` string, not a `#[ty]`).
public enum Encoding: Sendable, Hashable {
    case utf8
}

extension Encoding: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Str.input }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case .str(let s) = value else { return false }
        return s.value == "utf8"
    }

    public func intoValue() -> Value { .str(Str("utf8")) }

    public static func error(_ found: Value) -> HintedString {
        HintedString("expected `utf8`")
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard castable(value) else { return .failure(error(value)) }
        return .success(.utf8)
    }
}

// MARK: - json

/// Convert a `JSONSerialization` object to a Typst `Value`.
func jsonToValue(_ any: Any) -> Value {
    switch any {
    case is NSNull:
        return .none
    case let num as NSNumber:
        // CFBoolean check: JSONSerialization emits __NSCFBoolean for
        // true/false on Darwin.
        if CFGetTypeID(num) == CFBooleanGetTypeID() {
            return .bool(num.boolValue)
        }
        let double = num.doubleValue
        if num === kCFBooleanTrue || num === kCFBooleanFalse {
            return .bool(num.boolValue)
        }
        // Integral and in i64 range → int, else float.
        if double.truncatingRemainder(dividingBy: 1) == 0,
           double >= -9.223372036854776e18, double <= 9.223372036854776e18 {
            return .int(Int64(double))
        }
        return .float(double)
    case let str as String:
        return .str(Str(str))
    case let arr as [Any]:
        return .array(ArrayValue(items: arr.map(jsonToValue)))
    case let dict as [String: Any]:
        var d = Dict()
        for (k, v) in dict {
            d.insert(k, jsonToValue(v))
        }
        return .dict(d)
    default:
        return .none
    }
}

/// Escape a string as a JSON string literal (serde_json rules: only
/// `"`, `\`, and control characters are escaped; non-ASCII stays raw).
func jsonEscape(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

/// Format a float like serde_json/ryu: shortest round-trip, integral
/// floats keep `.0`, non-finite → `null`.
func jsonFloat(_ f: Double) -> String {
    guard f.isFinite else { return "null" }
    var s = String(f)
    // Normalize exponent: "1e+300" → "1e300", "1e-05" → "1e-5".
    if let eIdx = s.firstIndex(of: "e") {
        var mantissa = String(s[..<eIdx])
        var exp = String(s[s.index(after: eIdx)...])
        if exp.hasPrefix("+") { exp.removeFirst() }
        while exp.hasPrefix("0"), exp.count > 1 { exp.removeFirst() }
        if exp.hasPrefix("-0"), exp.count > 2 { exp.removeFirst() }
        s = mantissa + "e" + exp
        _ = mantissa
    }
    return s
}

/// Encode a `Value` as JSON text. Port of upstream's `Serialize for
/// Value` routed through `serde_json::to_string[_pretty]`: dict keys
/// sort byte-wise (serde_json `Map` is a `BTreeMap`), non-serializable
/// values fall back to `repr()`.
func encodeJSON(_ value: Value, pretty: Bool) -> String {
    func enc(_ v: Value, _ indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let childPad = String(repeating: " ", count: indent + 2)
        switch v {
        case .none: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return "\(i)"
        case .float(let f): return jsonFloat(f)
        case .str(let s): return jsonEscape(s.value)
        case .bytes(let b): return jsonEscape(b.repr())
        case .symbol(let s): return jsonEscape(s.get)
        case .array(let a):
            if a.items.isEmpty { return "[]" }
            if !pretty { return "[" + a.items.map { enc($0, 0) }.joined(separator: ",") + "]" }
            let inner = a.items.map { childPad + enc($0, indent + 2) }
                .joined(separator: ",\n")
            return "[\n" + inner + "\n" + pad + "]"
        case .dict(let d):
            if d.isEmpty { return "{}" }
            // serde_json::Map orders keys byte-wise.
            let pairs = d.sorted { $0.key.value.utf8.lexicographicallyPrecedes($1.key.value.utf8) }
            if !pretty {
                return "{" + pairs.map {
                    jsonEscape($0.key.value) + ":" + enc($0.value, 0)
                }.joined(separator: ",") + "}"
            }
            let inner = pairs.map {
                childPad + jsonEscape($0.key.value) + ": " + enc($0.value, indent + 2)
            }.joined(separator: ",\n")
            return "{\n" + inner + "\n" + pad + "}"
        case .content(let c):
            // {"func": name, ...fields} like upstream.
            var pairs: [(String, Value)] = [("func", .str(Str(c.elem.name)))]
            for (k, v) in c.fields() {
                pairs.append((k.value, v))
            }
            let sorted = pairs.sorted {
                $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
            }
            if !pretty {
                return "{" + sorted.map {
                    jsonEscape($0.0) + ":" + enc($0.1, 0)
                }.joined(separator: ",") + "}"
            }
            let inner = sorted.map {
                childPad + jsonEscape($0.0) + ": " + enc($0.1, indent + 2)
            }.joined(separator: ",\n")
            return "{\n" + inner + "\n" + pad + "}"
        default:
            return jsonEscape(v.repr())
        }
    }
    return enc(value, 0)
}

/// `json(source)` — port of upstream `json`.
let jsonFunc = nativeFunc(
    "json",
    title: "JSON",
    since: .forever,
    docs: "Reads structured data from a JSON file.",
    params: [
        NativeParamInfo(name: "source", input: DataSource.input, required: true),
    ],
    returns: Value.output,
    scope: {
        let scope = Scope()
        scope.defineFunc(jsonEncode)
        return scope
    }
) { engine, _, args in
    let source: Spanned<DataSource, Span> = try args.expectT("source")
    try args.finishT()
    let loaded = try load(source, engine.world)
    let raw = loaded.data.storage
    // UTF-8 BOM → friendly error.
    if raw.starts(with: [0xEF, 0xBB, 0xBF]) {
        var diag = LoadError.text(
            ReportTextPos.lineCol(.oneBased(1, 1)),
            "failed to parse JSON",
            "unexpected Byte Order Mark").within(loaded)
        diag.hint("JSON requires UTF-8 without a BOM")
        throw SourceDiagnostics([diag])
    }
    guard let text = String(bytes: raw, encoding: .utf8) else {
        throw SourceDiagnostics([LoadError.binary(
            "failed to parse JSON", "file is not valid UTF-8").within(loaded)])
    }
    do {
        let obj = try JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [])
        return jsonToValue(obj)
    } catch {
        throw SourceDiagnostics([LoadError.binary(
            "failed to parse JSON", "\(error.localizedDescription)")
            .within(loaded)])
    }
}

/// `json.encode(value, pretty:)` — port of upstream `json.encode`.
let jsonEncode = nativeFunc(
    "encode",
    title: "Encode JSON",
    since: .version([0, 8, 0]),
    docs: "Encodes structured data into a JSON string.",
    params: [
        NativeParamInfo(name: "value", input: Value.input, required: true),
        NativeParamInfo(
            name: "pretty",
            input: Bool.input,
            defaultValue: { .bool(true) },
            positional: false,
            named: true),
    ],
    returns: Str.output
) { _, _, args in
    let value: Spanned<Value, Span> = try args.expectT("value")
    let pretty: Bool = try args.namedT("pretty") ?? true
    try args.finishT()
    return Str(encodeJSON(value.value, pretty: pretty))
}

// MARK: - csv

/// CSV field delimiter. Port of upstream's `Delimiter` cast.
public struct CsvDelimiter: Sendable, Hashable {
    public var char: Character
    public init(_ char: Character) { self.char = char }
}

extension CsvDelimiter: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Str.input }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case .str(let s) = value else { return false }
        return s.value.unicodeScalars.count == 1
            && s.value.unicodeScalars.first!.isASCII
    }

    public func intoValue() -> Value { .str(Str(String(char))) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .str(let s) = value,
              let scalar = s.value.unicodeScalars.first,
              s.value.unicodeScalars.count == 1
        else { return .failure(error(value)) }
        guard scalar.isASCII else {
            return .failure(HintedString("delimiter must be an ASCII character"))
        }
        return .success(CsvDelimiter(Character(scalar)))
    }
}

/// CSV row representation. Port of upstream's `RowType`.
public enum CsvRowType: Sendable, Hashable {
    case array
    case dict
}

extension CsvRowType: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .type(Type.of(ArrayValue.self)) + .type(Type.of(Dict.self))
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case .type(let t) = value else { return false }
        return t == Type.of(ArrayValue.self) || t == Type.of(Dict.self)
    }

    public func intoValue() -> Value {
        switch self {
        case .array: return .type(Type.of(ArrayValue.self))
        case .dict: return .type(Type.of(Dict.self))
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .type(let t) = value else { return .failure(error(value)) }
        if t == Type.of(ArrayValue.self) { return .success(.array) }
        if t == Type.of(Dict.self) { return .success(.dict) }
        return .failure(HintedString("expected `array` or `dictionary`"))
    }
}

/// A parsed CSV record with the byte offset of its first field.
struct CsvRecord {
    var fields: [String]
    var byteOffset: Int
}

/// Minimal CSV parser matching rust-csv defaults (quoted fields,
/// `""` escapes, `\r\n`/`\n` endings, rigid field counts).
/// Returns records plus a `LoadError` on failure.
func parseCSV(_ bytes: [UInt8], delimiter: UInt8) -> Result<[CsvRecord], LoadError> {
    // rust-csv validates UTF-8 itself.
    guard utf8ValidUpTo(bytes) == nil else {
        return .failure(LoadError.binary("failed to parse CSV",
                                         "file is not valid UTF-8"))
    }
    let text = String(decoding: bytes, as: UTF8.self)
    var records: [CsvRecord] = []
    var fields: [String] = []
    var field = ""
    var recordStart = 0
    let scalars = Array(text)
    var i = 0

    func endField() {
        fields.append(field)
        field = ""
    }
    func endRecord() {
        endField()
        records.append(CsvRecord(fields: fields, byteOffset: recordStart))
        fields = []
    }

    while i < scalars.count {
        let c = scalars[i]
        if c == "\"" {
            // Quoted field — only special at field start.
            if field.isEmpty {
                i += 1
                while i < scalars.count {
                    if scalars[i] == "\"" {
                        if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                            field.append("\"")
                            i += 2
                        } else {
                            i += 1
                            break
                        }
                    } else {
                        field.append(scalars[i])
                        i += 1
                    }
                }
                continue
            }
            field.append(c)
            i += 1
            continue
        }
        if String(c).utf8.first == delimiter {
            endField()
            i += 1
            continue
        }
        if c == "\n" || c == "\r" {
            if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
                i += 1
            }
            endRecord()
            i += 1
            recordStart = i
            continue
        }
        field.append(c)
        i += 1
    }
    if !field.isEmpty || !fields.isEmpty {
        endRecord()
    }
    return .success(records)
}

/// `csv(source, delimiter:, row-type:)` — port of upstream `csv`.
let csvFunc = nativeFunc(
    "csv",
    title: "CSV",
    since: .forever,
    docs: "Reads structured data from a CSV file.",
    params: [
        NativeParamInfo(name: "source", input: DataSource.input, required: true),
        NativeParamInfo(
            name: "delimiter",
            input: CsvDelimiter.input,
            defaultValue: { .str(Str(",")) },
            positional: false,
            named: true),
        NativeParamInfo(
            name: "row-type",
            input: CsvRowType.input,
            defaultValue: { CsvRowType.array.intoValue() },
            positional: false,
            named: true),
    ],
    returns: ArrayValue.output
) { engine, _, args in
    let source: Spanned<DataSource, Span> = try args.expectT("source")
    let delimiter: CsvDelimiter = try args.namedT("delimiter") ?? CsvDelimiter(",")
    let rowType: CsvRowType = try args.namedT("row-type") ?? .array
    try args.finishT()

    let loaded = try load(source, engine.world)
    let delimScalar = delimiter.char.unicodeScalars.first!
    let delimByte = UInt8(delimScalar.value)

    let records: [CsvRecord]
    switch parseCSV(loaded.data.storage, delimiter: delimByte) {
    case .success(let r): records = r
    case .failure(let e):
        throw SourceDiagnostics([e.within(loaded)])
    }

    var array = ArrayValue()
    var headers: [String]? = nil
    var startIdx = 0
    if rowType == .dict {
        guard let first = records.first else { return array }
        headers = first.fields
        startIdx = 1
    }
    // Rigid field-count check (rust-csv `flexible = false`). Lines count
    // from 1, or 2 when a header row is consumed.
    let expected = headers?.count ?? records.first?.fields.count
    let lineOffset = rowType == .dict ? 2 : 1
    for (idx, rec) in records.enumerated() {
        guard let expected, rec.fields.count != expected else { continue }
        let line = idx + lineOffset
        throw SourceDiagnostics([LoadError.text(
            ReportTextPos.lineCol(.oneBased(line, 1)),
            "failed to parse CSV",
            "found \(rec.fields.count) instead of \(expected) fields in line \(line)")
            .within(loaded)])
    }
    for rec in records[startIdx...] {
        let item: Value
        if let headers {
            var dict = Dict()
            for (idx, key) in headers.enumerated() {
                if idx < rec.fields.count {
                    dict.insert(key, .str(Str(rec.fields[idx])))
                }
            }
            item = .dict(dict)
        } else {
            item = .array(ArrayValue(items: rec.fields.map { .str(Str($0)) }))
        }
        array.items.append(item)
    }
    return array
}

/// Build the global data-loading scope entries.
func defineDataLoading(into global: Scope) {
    global.defineFunc(readFunc)
    global.defineFunc(csvFunc)
    global.defineFunc(jsonFunc)
    global.defineFunc(xmlFunc)
    global.defineFunc(cborFunc)
    global.defineFunc(tomlFunc)
    global.defineFunc(yamlFunc)
}
