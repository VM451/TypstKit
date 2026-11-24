import Foundation
import TypstSyntax
import TypstUtils

// TOML loading — port of upstream `loading/toml.rs` plus a TOML 1.0
// subset parser/serializer. The parser builds a reference-type tree
// (`TomlNode`) to sidestep value-type write-back, then converts to
// `Dict`. Datetimes flow through the `$__toml_private_datetime`
// sentinel + `Datetime.fromTomlDict`, matching upstream's toml-crate
// serde path.

/// TOML parse error with a position.
struct TomlError: Error {
    var line: Int
    var col: Int
    var message: String
}

/// A node in the parsed TOML tree.
indirect enum TomlNode {
    case value(Value)
    case table(TomlTable)
    /// Array of tables (`[[name]]`).
    case arrayOfTables([TomlTable])
}

/// A TOML table — reference type so dotted keys and headers can
/// accumulate entries without rebuilding ancestors.
final class TomlTable {
    /// Ordered entries.
    var items: [(String, TomlNode)] = []

    func get(_ key: String) -> TomlNode? {
        items.last(where: { $0.0 == key })?.1
    }

    func set(_ key: String, _ node: TomlNode) {
        if let idx = items.lastIndex(where: { $0.0 == key }) {
            items[idx].1 = node
        } else {
            items.append((key, node))
        }
    }

    /// Descend into `key`, creating a table if absent. Errors if the
    /// existing node is a non-table.
    func childTable(_ key: String) throws -> TomlTable {
        if let node = get(key) {
            guard case .table(let t) = node else {
                throw TomlError(line: 0, col: 0,
                                message: "`\(key)` is not a table")
            }
            return t
        }
        let t = TomlTable()
        set(key, .table(t))
        return t
    }
}

/// Parse a TOML document into a `Dict`.
func parseTOML(_ text: String) -> Result<Dict, TomlError> {
    var parser = TomlParser(text)
    do {
        let root = TomlTable()
        try parser.parseDocument(root: root)
        return .success(tomlTableToDict(root))
    } catch let e as TomlError {
        return .failure(e)
    } catch {
        return .failure(TomlError(line: 1, col: 1, message: "\(error)"))
    }
}

/// Convert the parsed tree into a `Dict` value.
func tomlTableToDict(_ table: TomlTable) -> Dict {
    var dict = Dict()
    for (key, node) in table.items {
        switch node {
        case .value(let v): dict.insert(key, v)
        case .table(let t): dict.insert(key, .dict(tomlTableToDict(t)))
        case .arrayOfTables(let tables):
            dict.insert(key, .array(ArrayValue(
                items: tables.map { .dict(tomlTableToDict($0)) })))
        }
    }
    return dict
}

struct TomlParser {
    let scalars: [Character]
    var pos = 0
    var line = 1
    var col = 1

    init(_ text: String) { scalars = Array(text) }

    // MARK: - low-level

    func peek(_ ahead: Int = 0) -> Character? {
        pos + ahead < scalars.count ? scalars[pos + ahead] : nil
    }

    func peekStr(_ s: String) -> Bool {
        let chars = Array(s)
        guard pos + chars.count <= scalars.count else { return false }
        for (i, c) in chars.enumerated() where scalars[pos + i] != c {
            return false
        }
        return true
    }

    @discardableResult
    mutating func match(_ c: Character) -> Bool {
        guard peek() == c else { return false }
        advance()
        return true
    }

    /// Match a multi-character literal.
    @discardableResult
    mutating func matchStr(_ s: String) -> Bool {
        guard peekStr(s) else { return false }
        for _ in s { advance() }
        return true
    }

    @discardableResult
    mutating func advance() -> Character? {
        guard pos < scalars.count else { return nil }
        let c = scalars[pos]
        pos += 1
        if c == "\n" { line += 1; col = 1 } else { col += 1 }
        return c
    }

    mutating func error(_ message: String) -> TomlError {
        TomlError(line: line, col: col, message: message)
    }

    mutating func skipInlineWS() {
        while let c = peek(), c == " " || c == "\t" { advance() }
    }

    mutating func skipWS() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                advance()
            } else { break }
        }
    }

    mutating func skipComment() {
        while let c = peek(), c != "\n" { advance() }
    }

    /// Skip ws + optional `#` comment(s).
    mutating func skipWSComment() {
        while true {
            skipWS()
            if match("#") { skipComment() } else { return }
        }
    }

    // MARK: - document

    /// Parse the whole document into `root`.
    mutating func parseDocument(root: TomlTable) throws {
        /// Current table context: path of keys from root, plus whether
        /// the last step is an array-of-tables element.
        var current: TomlTable? = root

        while pos < scalars.count {
            skipWSComment()
            guard pos < scalars.count else { break }
            if peek() == "[" {
                advance()
                let isArray = match("[")
                let path = try parseKeyPath()
                skipInlineWS()
                if isArray {
                    guard match("]"), match("]") else {
                        throw error("expected `]]`")
                    }
                } else {
                    guard match("]") else { throw error("expected `]`") }
                }
                skipInlineWS()
                if let c = peek(), c != "#", c != "\n", c != "\r" {
                    throw error("expected newline after table header")
                }
                current = try tableForHeader(root: root, path: path,
                                             isArray: isArray)
            } else {
                guard let table = current else {
                    throw error("key-value pair before any table")
                }
                let (keyPath, value) = try parseKeyValue()
                try insertKeyValue(table, keyPath: keyPath, value: value)
            }
        }
    }

    /// Resolve a `[a.b]` / `[[a.b]]` header to its table, creating
    /// intermediate tables as needed.
    mutating func tableForHeader(root: TomlTable, path: [String],
                                 isArray: Bool) throws -> TomlTable {
        guard !path.isEmpty else { return root }
        var node = root
        for (i, key) in path.enumerated() {
            let last = i == path.count - 1
            if last && isArray {
                // [[a.b]] — ensure array-of-tables, append new element.
                if let existing = node.get(key) {
                    guard case .arrayOfTables(let arr) = existing else {
                        throw error("`\(key)` is not an array of tables")
                    }
                    let t = TomlTable()
                    var updated = arr
                    updated.append(t)
                    node.set(key, .arrayOfTables(updated))
                    return t
                }
                let t = TomlTable()
                node.set(key, .arrayOfTables([t]))
                return t
            }
            if last {
                // [a.b] — plain table; must not already be a value.
                if let existing = node.get(key) {
                    if case .table = existing { return try node.childTable(key) }
                    throw error("`\(key)` is already defined")
                }
                let t = TomlTable()
                node.set(key, .table(t))
                return t
            }
            // Intermediate: must be/become a table (or array-of-tables'
            // last element for `[[a]].b` — rare; treat as table).
            node = try node.childTable(key)
        }
        return node
    }

    /// Insert `keyPath = value` into `table`, nesting dotted keys.
    mutating func insertKeyValue(_ table: TomlTable, keyPath: [String],
                                 value: Value) throws {
        guard let first = keyPath.first else { return }
        if keyPath.count == 1 {
            // Duplicate key → error (TOML forbends redefining).
            if let existing = table.get(first) {
                // Merging only allowed when both are tables (inline
                // tables can't be extended, but [table] headers can
                // re-open — handled by header path, not here).
                if case .table = existing, case .dict = value {
                    // Inline-table value into existing table: merge.
                    if case .table(let t) = existing,
                       case .dict(let d) = value {
                        for (k, v) in d { try insertKeyValue(t, keyPath: [k.value], value: v) }
                        return
                    }
                }
                throw error("duplicate key `\(first)`")
            }
            table.set(first, .value(value))
            return
        }
        let child = try table.childTable(first)
        try insertKeyValue(child, keyPath: Array(keyPath.dropFirst()), value: value)
    }

    // MARK: - keys

    mutating func parseKeyPath() throws -> [String] {
        var keys: [String] = []
        while true {
            keys.append(try parseKey())
            skipInlineWS()
            guard match(".") else { break }
            skipInlineWS()
        }
        return keys
    }

    mutating func parseKey() throws -> String {
        skipInlineWS()
        guard let c = peek() else { throw error("expected key") }
        if c == "\"" {
            guard match("\"") else { throw error("expected string") }
            var out = ""
            while let ch = peek(), ch != "\"" {
                if ch == "\\" {
                    advance()
                    out += try parseBasicEscape()
                } else {
                    out.append(advance()!)
                }
            }
            guard match("\"") else { throw error("unterminated string") }
            return out
        }
        if c == "'" {
            guard match("'") else { throw error("expected literal string") }
            var out = ""
            while let ch = peek(), ch != "'" {
                out.append(advance()!)
            }
            guard match("'") else { throw error("unterminated literal string") }
            return out
        }
        var key = ""
        while let ch = peek() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                key.append(advance()!)
            } else { break }
        }
        guard !key.isEmpty else { throw error("expected key") }
        return key
    }

    // MARK: - key-value pairs

    mutating func parseKeyValue() throws -> (keyPath: [String], value: Value) {
        let path = try parseKeyPath()
        skipInlineWS()
        guard match("=") else { throw error("expected `=`") }
        skipInlineWS()
        let value = try parseValue()
        skipInlineWS()
        if let c = peek(), c != "#", c != "\n", c != "\r" {
            throw error("expected newline or comment after value")
        }
        return (path, value)
    }

    // MARK: - values

    mutating func parseValue() throws -> Value {
        skipInlineWS()
        guard let c = peek() else { throw error("expected value") }
        switch c {
        case "\"": return try parseString()
        case "'": return .str(Str(try parseLiteralString()))
        case "[": return try parseArray()
        case "{": return try parseInlineTable()
        default: return try parseScalar()
        }
    }

    /// Read a bare scalar token (number/bool/datetime).
    mutating func parseScalar() throws -> Value {
        var token = ""
        while let c = peek() {
            if c == " " {
                // TOML allows a space as the date/time separator in
                // datetimes — keep it only when the token so far is a
                // date and a digit follows.
                if looksLikeDateToken(token),
                   let next = peek(1), next.isNumber {
                    token.append(advance()!)
                    continue
                }
                break
            }
            if c == "\t" || c == "\n" || c == "\r"
                || c == "#" || c == "," || c == "]" || c == "}" {
                break
            }
            token.append(advance()!)
        }
        return try scalarToValue(token)
    }

    /// Whether `token` currently looks like `YYYY-MM-DD` (date part of
    /// a space-separated datetime).
    func looksLikeDateToken(_ token: String) -> Bool {
        let p = token.split(separator: "-", omittingEmptySubsequences: false)
        return p.count == 3 && p[0].count == 4 && p[1].count == 2
            && p[2].count == 2
            && p.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    mutating func scalarToValue(_ token: String) throws -> Value {
        switch token.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        if let dt = parseTomlDateTime(token) { return dt }
        if let int = parseTomlInt(token) { return .int(int) }
        if token.contains(".") || token.contains("e") || token.contains("E") {
            guard let f = parseTomlFloat(token) else {
                throw error("invalid float `\(token)`")
            }
            return .float(f)
        }
        if token.allSatisfy({ $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }) {
            throw error("number too large to fit in target type")
        }
        throw error("invalid value `\(token)`")
    }

    // MARK: - numbers

    func parseTomlInt(_ token: String) -> Int64? {
        var t = token
        var negative = false
        if t.hasPrefix("+") { t.removeFirst() }
        else if t.hasPrefix("-") { negative = true; t.removeFirst() }
        let digits = t.replacingOccurrences(of: "_", with: "")
        let value: UInt64
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            guard let v = UInt64(digits.dropFirst(2), radix: 16) else { return nil }
            value = v
        } else if digits.hasPrefix("0o") || digits.hasPrefix("0O") {
            guard let v = UInt64(digits.dropFirst(2), radix: 8) else { return nil }
            value = v
        } else if digits.hasPrefix("0b") || digits.hasPrefix("0B") {
            guard let v = UInt64(digits.dropFirst(2), radix: 2) else { return nil }
            value = v
        } else {
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  let v = UInt64(digits) else { return nil }
            value = v
        }
        if negative {
            guard value <= UInt64(Int64.max) + 1 else { return nil }
            if value == UInt64(Int64.max) + 1 { return Int64.min }
            return -Int64(value)
        }
        guard value <= UInt64(Int64.max) else { return nil }
        return Int64(value)
    }

    func parseTomlFloat(_ token: String) -> Double? {
        var t = token.replacingOccurrences(of: "_", with: "")
        if t.hasPrefix("+") { t.removeFirst() }
        guard !t.isEmpty else { return nil }
        return Double(t)
    }

    // MARK: - datetime

    /// Returns the sentinel-dict `Value` for a TOML datetime token.
    func parseTomlDateTime(_ token: String) -> Value? {
        // Shapes: offset/local datetime (date [Tt ] time [offset]),
        // local date, local time.
        guard let normalized = normalizeTomlDateTime(token) else { return nil }
        var d = Dict()
        d.insert("$__toml_private_datetime", .str(Str(normalized)))
        if let dt = Datetime.fromTomlDict(d) { return .datetime(dt) }
        return .dict(d)
    }

    /// Validate + normalize a TOML temporal token; nil if not temporal.
    func normalizeTomlDateTime(_ token: String) -> String? {
        func validHMS(_ s: String) -> Bool {
            var t = s
            if let dot = t.firstIndex(of: ".") {
                let frac = t[t.index(after: dot)...]
                guard !frac.isEmpty, frac.allSatisfy(\.isNumber) else { return false }
                t = String(t[..<dot])
            }
            let p = t.split(separator: ":", omittingEmptySubsequences: false)
            return p.count == 3
                && p.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isNumber) }
        }
        func looksLikeDate(_ s: String) -> Bool {
            let p = s.split(separator: "-", omittingEmptySubsequences: false)
            return p.count == 3 && p[0].count == 4 && p[1].count == 2
                && p[2].count == 2
                && p.allSatisfy { $0.allSatisfy(\.isNumber) }
        }

        // Local time alone: HH:MM:SS(.f)?
        if !token.contains("-"), token.contains(":"), validHMS(token) {
            return token
        }
        // Local date alone.
        if looksLikeDate(token), !token.contains(":") {
            return token
        }
        // Datetime: date + separator + time [+ offset].
        for sep in ["T", "t", " "] {
            guard let range = token.range(of: sep) else { continue }
            let datePart = String(token[..<range.lowerBound])
            var rest = String(token[range.upperBound...])
            guard looksLikeDate(datePart) else { return nil }
            var offset = ""
            if rest.hasSuffix("Z") || rest.hasSuffix("z") {
                offset = "Z"
                rest.removeLast()
            } else {
                // Offset sign is the last '+'/'-' after the time's ':'.
                if let idx = rest.lastIndex(of: "+") ?? rest.lastIndex(of: "-") {
                    let candidate = String(rest[idx...])
                    let ohms = candidate.dropFirst()
                        .split(separator: ":", omittingEmptySubsequences: false)
                    if ohms.count == 2,
                       ohms.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }) {
                        offset = candidate
                        rest = String(rest[..<idx])
                    }
                }
            }
            guard validHMS(rest) else { return nil }
            return datePart + "T" + rest + offset
        }
        return nil
    }

    // MARK: - strings

    mutating func parseString() throws -> Value {
        if matchStr("\"\"\"") { return .str(Str(try parseMultiLineBasic())) }
        guard match("\"") else { throw error("expected string") }
        var out = ""
        while let c = peek(), c != "\"" {
            if c == "\n" { throw error("unterminated string") }
            if c == "\\" {
                advance()
                out += try parseBasicEscape()
            } else {
                out.append(advance()!)
            }
        }
        guard match("\"") else { throw error("unterminated string") }
        return .str(Str(out))
    }

    mutating func parseLiteralString() throws -> String {
        if matchStr("'''") { return try parseMultiLineLiteral() }
        guard match("'") else { throw error("expected literal string") }
        var out = ""
        while let c = peek(), c != "'" {
            if c == "\n" { throw error("unterminated literal string") }
            out.append(advance()!)
        }
        guard match("'") else { throw error("unterminated literal string") }
        return out
    }

    mutating func parseMultiLineBasic() throws -> String {
        // A newline immediately after opening """ is trimmed.
        if matchStr("\r\n") {} else if matchStr("\n") {} else if matchStr("\r") {}
        var out = ""
        while pos < scalars.count {
            if peekStr("\"\"\"") {
                advance(); advance(); advance()
                if match("\"") { out.append("\""); continue }
                if match("\"") { out.append("\"\""); continue }
                return out
            }
            if match("\\") {
                // Line-ending backslash trims ws + newline.
                if let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
                    while let w = peek(),
                          w == " " || w == "\t" || w == "\n" || w == "\r" {
                        advance()
                    }
                    continue
                }
                out += try parseBasicEscape()
            } else {
                out.append(advance()!)
            }
        }
        throw error("unterminated multi-line string")
    }

    mutating func parseMultiLineLiteral() throws -> String {
        if matchStr("\r\n") {} else if matchStr("\n") {} else if matchStr("\r") {}
        var out = ""
        while pos < scalars.count {
            if peekStr("'''") {
                advance(); advance(); advance()
                if match("'") { out.append("'"); continue }
                if match("'") { out.append("''"); continue }
                return out
            }
            out.append(advance()!)
        }
        throw error("unterminated multi-line literal string")
    }

    mutating func parseBasicEscape() throws -> String {
        guard let c = peek() else { throw error("unterminated escape") }
        switch c {
        case "b": advance(); return "\u{08}"
        case "t": advance(); return "\t"
        case "n": advance(); return "\n"
        case "f": advance(); return "\u{0C}"
        case "r": advance(); return "\r"
        case "\"": advance(); return "\""
        case "\\": advance(); return "\\"
        case "u", "U":
            let digits = c == "u" ? 4 : 8
            advance()
            let hex = try readHex(digits: digits)
            guard let cp = UInt32(hex, radix: 16),
                  let scalar = Unicode.Scalar(cp) else {
                throw error("invalid unicode escape")
            }
            return String(scalar)
        default:
            throw error("invalid escape sequence '\\\(c)'")
        }
    }

    mutating func readHex(digits: Int) throws -> String {
        var out = ""
        for _ in 0..<digits {
            guard let c = peek(), c.isHexDigit else {
                throw error("expected \(digits) hex digits")
            }
            out.append(advance()!)
        }
        return out
    }

    // MARK: - arrays & inline tables

    mutating func parseArray() throws -> Value {
        guard match("[") else { throw error("expected `[`") }
        var items: [Value] = []
        var needValue = true
        while true {
            skipWSComment()
            if match("]") { break }
            if !needValue {
                guard match(",") else { throw error("expected `,`") }
                skipWSComment()
                if match("]") { break }
            }
            needValue = false
            items.append(try parseValue())
        }
        return .array(ArrayValue(items: items))
    }

    mutating func parseInlineTable() throws -> Value {
        guard match("{") else { throw error("expected `{`") }
        // Build via TomlTable for nested dotted keys.
        let table = TomlTable()
        var first = true
        while true {
            skipInlineWS()
            if match("}") { break }
            if !first {
                guard match(",") else { throw error("expected `,`") }
                skipInlineWS()
                if match("}") { break }
            }
            first = false
            let path = try parseKeyPath()
            skipInlineWS()
            guard match("=") else { throw error("expected `=`") }
            skipInlineWS()
            let value = try parseValue()
            try insertKeyValue(table, keyPath: path, value: value)
        }
        skipInlineWS()
        return .dict(tomlTableToDict(table))
    }
}

// MARK: - toml()

/// `toml(source)` — port of upstream `toml`.
let tomlFunc = nativeFunc(
    "toml",
    title: "TOML",
    since: .version([0, 3, 0]),
    docs: "Reads structured data from a TOML file.",
    params: [
        NativeParamInfo(name: "source", input: DataSource.input, required: true),
    ],
    returns: Dict.output,
    scope: {
        let scope = Scope()
        scope.defineFunc(tomlEncode)
        return scope
    }
) { engine, _, args in
    let source: Spanned<DataSource, Span> = try args.expectT("source")
    try args.finishT()
    let loaded = try load(source, engine.world)
    let text = try loadedToStr(loaded)
    switch parseTOML(text.value) {
    case .success(let d): return d
    case .failure(let e):
        throw SourceDiagnostics([LoadError.text(
            ReportTextPos.lineCol(.oneBased(e.line, e.col)),
            "failed to parse TOML", e.message).within(loaded)])
    }
}

/// `toml.encode(value, pretty:)` — port of upstream `toml.encode`.
/// Only dictionaries are suitable (TOML documents are tables).
let tomlEncode = nativeFunc(
    "encode",
    title: "Encode TOML",
    since: .version([0, 8, 0]),
    docs: "Encodes structured data into a TOML string.",
    params: [
        NativeParamInfo(name: "value", input: Dict.input, required: true),
        NativeParamInfo(
            name: "pretty",
            input: Bool.input,
            defaultValue: { .bool(true) },
            positional: false,
            named: true),
    ],
    returns: Str.output
) { _, _, args in
    let value: Spanned<Dict, Span> = try args.expectT("value")
    let pretty: Bool = try args.namedT("pretty") ?? true
    try args.finishT()
    return Str(encodeTOML(value.value, pretty: pretty))
}

// MARK: - TOML encoder

/// Escape a string as a TOML basic string.
func tomlEscape(_ s: String) -> String {
    var out = "\""
    for c in s {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1,
               scalar.value < 0x20 || scalar.value == 0x7F {
                out += String(format: "\\u%04X", scalar.value)
            } else {
                out.append(c)
            }
        }
    }
    return out + "\""
}

/// Format a scalar value as a TOML value literal.
func tomlScalar(_ value: Value) -> String {
    switch value {
    case .none: return "" // shouldn't appear at top level
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return "\(i)"
    case .float(let f):
        if f.isNaN { return "nan" }
        if f == .infinity { return "inf" }
        if f == -.infinity { return "-inf" }
        var s = String(f)
        // TOML requires a decimal point or exponent for floats.
        if !s.contains(".") && !s.contains("e") && !s.contains("E") {
            s += ".0"
        }
        return s
    case .str(let s): return tomlEscape(s.value)
    case .bytes(let b):
        return tomlEscape(b.repr())
    case .symbol(let s): return tomlEscape(s.get)
    case .array(let a):
        return "[" + a.items.map(tomlInlineValue).joined(separator: ", ") + "]"
    case .dict(let d):
        return tomlInlineTable(d)
    case .content(let c):
        return tomlEscape(c.repr())
    default:
        return tomlEscape(value.repr())
    }
}

/// Encode a value that may appear inside an array/inline-table.
func tomlInlineValue(_ value: Value) -> String {
    tomlScalar(value)
}

/// Encode a dict as a TOML inline table `{k = v, ...}`.
func tomlInlineTable(_ dict: Dict) -> String {
    let inner = dict.map { "\($0.key.value) = \(tomlInlineValue($0.value))" }
        .joined(separator: ", ")
    return "{ \(inner) }"
}

/// Encode a `Dict` as a TOML document. Port of
/// `toml::to_string[_pretty]` — scalar keys first, then `[table]`
/// sections; arrays of tables as `[[name]]`.
func encodeTOML(_ dict: Dict, pretty: Bool) -> String {
    var out = ""
    var sections: [(path: [String], table: Dict, isArray: Bool)] = []
    collectTOMLSections(dict, path: [], into: &sections)

    // Top-level scalars/arrays.
    for (key, value) in dict {
        if isTOMLTable(value) { continue }
        out += "\(key.value) = \(tomlScalar(value))\n"
    }

    // Sections.
    for section in sections {
        let header = section.path.map(tomlEscapeBare).joined(separator: ".")
        out += section.isArray ? "[[\(header)]]\n" : "[\(header)]\n"
        for (key, value) in section.table {
            if isTOMLTable(value) { continue }
            out += "\(tomlEscapeBare(key.value)) = \(tomlScalar(value))\n"
        }
        out += "\n"
    }
    _ = pretty // pretty vs compact differ only in array layout upstream;
    // this encoder emits inline arrays for both.
    return out
}

/// Whether a value serializes as a TOML table section.
func isTOMLTable(_ value: Value) -> Bool {
    switch value {
    case .dict: return true
    case .array(let a):
        return a.items.contains { if case .dict = $0 { return true }; return false }
            && !a.items.isEmpty
    default: return false
    }
}

/// Quote a bare key when needed.
func tomlEscapeBare(_ key: String) -> String {
    if !key.isEmpty,
       key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
       !(key.first?.isNumber ?? true) {
        return key
    }
    return tomlEscape(key)
}

/// Collect nested tables/array-of-tables as sections.
func collectTOMLSections(_ dict: Dict, path: [String],
                          into sections: inout [(path: [String], table: Dict, isArray: Bool)]) {
    for (key, value) in dict {
        let childPath = path + [key.value]
        switch value {
        case .dict(let d):
            sections.append((childPath, d, false))
            collectTOMLSections(d, path: childPath, into: &sections)
        case .array(let a) where !a.items.isEmpty
                && a.items.allSatisfy({ if case .dict = $0 { return true }; return false }):
            // Array of tables → [[path]] per element.
            for (i, item) in a.items.enumerated() {
                if case .dict(let d) = item {
                    sections.append((childPath, d, true))
                    collectTOMLSections(d, path: childPath, into: &sections)
                }
                _ = i
            }
        default:
            break
        }
    }
}
